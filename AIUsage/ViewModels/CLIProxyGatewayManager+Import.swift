import Foundation

// MARK: - Safe Auth Import Center (execution layer)
// 多文件导入的编排：读取并限制文件 → 本地识别（CLIProxyAuthImportInspector）→
// 采集 CPA 现有文件的哈希/身份 → 规划（CLIProxyAuthImportPlanner）→ 逐文件
// 上传并记录逐项结果 → 整批完成后统一刷新账号池、模型目录与分发状态。
// 识别与规划的纯逻辑在 Models/CLIProxyAuthImportPlanner.swift。

@MainActor
extension CLIProxyGatewayManager {
    /// Reads the selected files, recognizes them locally, gathers existing CPA
    /// state, and publishes a preview session. Nothing is uploaded yet.
    func prepareAuthImport(from urls: [URL], mode: CLIProxyAuthImportSession.Mode) async {
        guard CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild else {
            lastError = CLIProxyCapabilityMatrix.subscriptionsUnavailableMessage
            authImportSession = nil
            return
        }
        guard !isImportingAuthFiles, let client = managementClient() else { return }
        isImportingAuthFiles = true
        lastError = nil
        defer { isImportingAuthFiles = false }

        guard !urls.isEmpty else { return }
        guard urls.count <= CLIProxyAuthImportPlanner.maxBatchCount else {
            lastError = L(
                "Select at most \(CLIProxyAuthImportPlanner.maxBatchCount) files per import batch.",
                "每批最多导入 \(CLIProxyAuthImportPlanner.maxBatchCount) 个文件。"
            )
            return
        }

        let enabledPluginProviderIDs = Set(
            providerPlugins.filter(\.effectiveEnabled).map { $0.providerID.lowercased() }
        )

        var totalBytes = 0
        var inspected: [(fileName: String, result: Result<CLIProxyAuthImportInspection, CLIProxyAuthImportInspectionFailure>)] = []
        var readFailures: [(fileName: String, message: String)] = []
        for url in urls {
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            let fileName = url.lastPathComponent
            do {
                let data = try Self.readImportableAuthFile(at: url)
                totalBytes += data.count
                guard totalBytes <= CLIProxyAuthImportPlanner.maxBatchBytes else {
                    lastError = L(
                        "The batch exceeds the \(CLIProxyAuthImportPlanner.maxBatchBytes / 1_048_576) MB total import limit.",
                        "整批文件超过 \(CLIProxyAuthImportPlanner.maxBatchBytes / 1_048_576) MB 总大小限制。"
                    )
                    return
                }
                inspected.append((
                    fileName,
                    CLIProxyAuthImportInspector.inspect(
                        fileName: fileName,
                        data: data,
                        enabledPluginProviderIDs: enabledPluginProviderIDs
                    )
                ))
            } catch {
                readFailures.append((fileName, error.localizedDescription))
            }
        }

        let relevantProviderTypes = Set(inspected.compactMap { entry -> String? in
            guard case .success(let inspection) = entry.result else { return nil }
            return inspection.providerType
        })
        let existing = await collectExistingFiles(
            relevantProviderTypes: relevantProviderTypes,
            using: client
        )

        var items = CLIProxyAuthImportPlanner
            .plan(inspected: inspected, existing: existing)
            .map { planned in
                CLIProxyAuthImportSession.Item(
                    id: planned.id,
                    fileName: planned.fileName,
                    inspection: planned.inspection,
                    action: planned.action
                )
            }
        for (index, failure) in readFailures.enumerated() {
            items.append(CLIProxyAuthImportSession.Item(
                id: "read-failure-\(index)-\(failure.fileName.lowercased())",
                fileName: failure.fileName,
                inspection: nil,
                action: .blocked(reason: failure.message)
            ))
        }
        authImportSession = CLIProxyAuthImportSession(mode: mode, phase: .preview, items: items)
    }

    func setImportConflictChoice(itemID: String, choice: CLIProxyAuthImportConflictChoice) {
        guard var session = authImportSession, session.phase == .preview,
              let index = session.items.firstIndex(where: { $0.id == itemID }),
              case .confirmReplace = session.items[index].action else { return }
        session.items[index].conflictChoice = choice
        authImportSession = session
    }

    /// Uploads the planned files one by one and records a per-item outcome.
    /// A single refresh of the account pool, model catalog, and distribution
    /// state runs after the whole batch.
    func executeAuthImport() async {
        guard CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild else {
            lastError = CLIProxyCapabilityMatrix.subscriptionsUnavailableMessage
            authImportSession = nil
            return
        }
        guard var session = authImportSession, session.phase == .preview,
              !isImportingAuthFiles, let client = managementClient() else { return }
        isImportingAuthFiles = true
        session.phase = .executing
        authImportSession = session
        defer { isImportingAuthFiles = false }

        for index in session.items.indices {
            session.items[index].outcome = await performImport(
                item: session.items[index],
                using: client
            )
            authImportSession = session
        }

        await finalizeImportBatch(session: &session, using: client)
    }

    /// Retries only items whose upload failed; everything else keeps its outcome.
    func retryFailedAuthImports() async {
        guard CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild else {
            lastError = CLIProxyCapabilityMatrix.subscriptionsUnavailableMessage
            authImportSession = nil
            return
        }
        guard var session = authImportSession, session.phase == .completed,
              session.failedCount > 0,
              !isImportingAuthFiles, let client = managementClient() else { return }
        isImportingAuthFiles = true
        session.phase = .executing
        authImportSession = session
        defer { isImportingAuthFiles = false }

        for index in session.items.indices {
            guard case .uploadFailed = session.items[index].outcome else { continue }
            session.items[index].outcome = await performImport(
                item: session.items[index],
                using: client
            )
            authImportSession = session
        }

        await finalizeImportBatch(session: &session, using: client)
    }

    func clearAuthImportSession() {
        authImportSession = nil
    }

    // MARK: - Internal helpers

    private func performImport(
        item: CLIProxyAuthImportSession.Item,
        using client: CLIProxyManagementClient
    ) async -> CLIProxyAuthImportItemOutcome {
        switch item.action {
        case .blocked(let reason):
            return .blocked(reason: reason)
        case .blockedManagedCopy(let existingName):
            return .blocked(reason: L(
                "\(existingName) is an AIUsage-managed copy; plain import never overwrites it.",
                "\(existingName) 是 AIUsage 托管副本，普通导入不能覆盖它。"
            ))
        case .requiresPlugin(let hint):
            return .requiresPlugin(hint)
        case .skipDuplicate:
            return .skippedDuplicate
        case .confirmReplace(let existingName):
            guard item.conflictChoice == .replaceExisting else { return .keptExisting }
            guard let inspection = item.inspection else {
                return .uploadFailed(message: L("The recognized payload is unavailable.", "识别结果不可用。"))
            }
            if CLIProxyCapabilityMatrix.isDisallowedCPAProvider(inspection.providerType) {
                return .blocked(reason: CLIProxyAuthImportInspectionFailure.disallowedProvider(type: inspection.providerType).message)
            }
            do {
                try await client.uploadAuthFile(data: inspection.payload, name: existingName)
                return .replacedExisting(name: existingName)
            } catch {
                return .uploadFailed(message: error.localizedDescription)
            }
        case .upload(let name, let renamedFrom):
            guard let inspection = item.inspection else {
                return .uploadFailed(message: L("The recognized payload is unavailable.", "识别结果不可用。"))
            }
            if CLIProxyCapabilityMatrix.isDisallowedCPAProvider(inspection.providerType) {
                return .blocked(reason: CLIProxyAuthImportInspectionFailure.disallowedProvider(type: inspection.providerType).message)
            }
            do {
                try await client.uploadAuthFile(data: inspection.payload, name: name)
                return renamedFrom == nil ? .imported(name: name) : .renamedImported(name: name)
            } catch {
                return .uploadFailed(message: error.localizedDescription)
            }
        }
    }

    private func finalizeImportBatch(
        session: inout CLIProxyAuthImportSession,
        using client: CLIProxyManagementClient
    ) async {
        do {
            let refreshed = try await loadAuthPool(using: client)
            authFiles = refreshed
            let names = Set(refreshed.map { $0.name.lowercased() })
            for index in session.items.indices {
                guard let uploadedName = uploadedFileName(session.items[index].outcome) else { continue }
                if !names.contains(uploadedName.lowercased()) {
                    session.items[index].outcome = .verificationPending(name: uploadedName)
                }
            }
            await refreshModelCatalogAndDistribution(using: client)
        } catch {
            // Uploads already succeeded; do not tell the user to re-import.
            for index in session.items.indices {
                guard let uploadedName = uploadedFileName(session.items[index].outcome) else { continue }
                session.items[index].outcome = .verificationPending(name: uploadedName)
            }
            if lastError == nil { lastError = error.localizedDescription }
        }
        session.phase = .completed
        authImportSession = session
    }

    private func uploadedFileName(_ outcome: CLIProxyAuthImportItemOutcome?) -> String? {
        switch outcome {
        case .imported(let name), .renamedImported(let name), .replacedExisting(let name):
            return name
        default:
            return nil
        }
    }

    /// Downloads only same-provider CPA files (bounded) so the planner can run
    /// content- and identity-level deduplication. Download failures degrade to
    /// name-only conflict handling; they never enable overwrites.
    private func collectExistingFiles(
        relevantProviderTypes: Set<String>,
        using client: CLIProxyManagementClient
    ) async -> [CLIProxyAuthImportExistingFile] {
        let maxDownloads = 40
        var downloadsUsed = 0
        var results: [CLIProxyAuthImportExistingFile] = []
        let files = (try? await client.listAuthFiles()) ?? authFiles

        for file in files where !file.runtimeOnly {
            let providerType = CLIProxyCapabilityMatrix.normalizedAuthType(file.provider ?? file.type)
            var isManaged = file.name.lowercased().hasPrefix("aiusage-")
            var canonicalHash: String?
            var identityKey: String?

            let isRelevant = providerType.map { relevantProviderTypes.contains($0) } ?? false
            if isRelevant, downloadsUsed < maxDownloads {
                downloadsUsed += 1
                if let data = try? await client.downloadAuthFile(name: file.name) {
                    canonicalHash = try? CLIProxyJSONFingerprint.hash(data, requireObject: true)
                    if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       object["aiusage_credential_id"] != nil {
                        isManaged = true
                    }
                    if let providerType,
                       ["codex", "antigravity", "gemini", "gemini-cli"].contains(providerType),
                       let identity = try? CLIProxyAccountIdentity.parse(data: data, providerHint: providerType),
                       identity.canAutomaticallyMerge {
                        identityKey = identity.key
                    }
                }
            }
            results.append(CLIProxyAuthImportExistingFile(
                name: file.name,
                providerType: providerType,
                canonicalHash: canonicalHash,
                identityKey: identityKey,
                isManagedCopy: isManaged
            ))
        }
        return results
    }
}
