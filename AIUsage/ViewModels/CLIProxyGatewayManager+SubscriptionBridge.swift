import Foundation
import os
import QuotaBackend

// MARK: - CPA → 订阅账号桥接
// 把 CPA auth 池中的账号添加到「订阅账号」。Codex 按工作区 + 用户判断是否已存在。
// 不反向删除 CPA 副本。

private let subscriptionBridgeLog = Logger(
    subsystem: "com.aiusage.desktop",
    category: "CLIProxySubscriptionBridge"
)

extension CLIProxyAccountIdentity {
    /// Codex 与主卡片共用一套方案名（含 prolite / promax / ent26 等新值）；其他服务商沿用通用映射。
    var resolvedPlanDisplayName: String? {
        guard let planType else { return nil }
        if providerID.lowercased() == "codex" {
            return CodexProvider.planDisplayName(forRaw: planType)
        }
        return planDisplayName
    }
}

enum CLIProxySubscriptionAddOutcome: Equatable {
    case added(displayName: String)
    case alreadyPresent(displayName: String)
    case unsupported(providerID: String)
    case failed(String)
}

@MainActor
extension CLIProxyGatewayManager {
    /// 将单个 CPA auth 文件加入订阅账号；已存在则不去重写入。
    func addAuthFileToSubscriptionAccounts(_ file: CLIProxyAuthFile) async -> CLIProxySubscriptionAddOutcome {
        let gatewayProviderID = file.gatewayProviderID.lowercased()
        guard !file.runtimeOnly,
              Self.subscriptionImportableProviderIDs.contains(gatewayProviderID),
              let providerID = Self.subscriptionProviderID(for: gatewayProviderID) else {
            return .unsupported(providerID: file.gatewayProviderID)
        }

        guard let path = file.path, !path.isEmpty,
              FileManager.default.isReadableFile(atPath: path) else {
            return .failed(L("The CPA auth file is missing or unreadable.", "CPA 认证文件不存在或无法读取。"))
        }
        let authURL = URL(fileURLWithPath: path)
        if let sourceData = try? Data(contentsOf: authURL, options: .mappedIfSafe),
           let planRejection = CLIProxyCapabilityMatrix.codexPlanRejectionReason(fromAuthData: sourceData) {
            return .failed(planRejection)
        }

        let candidate: ProviderAuthCandidate
        switch providerID {
        case "codex":
            candidate = ProviderAuthManager.makeCodexCandidate(authFileURL: authURL)
        default:
            return .unsupported(providerID: file.gatewayProviderID)
        }

        let label = displayLabel(for: candidate, authURL: authURL, providerID: providerID)
        // 用户显式点「添加到订阅」时：永久删除墓碑应可复活，不能挡。
        // 自动 backfill 仍尊重墓碑，避免删了又自动回来。
        if subscriptionAlreadyContains(
            candidate: candidate,
            providerID: providerID,
            respectPermanentRemoval: false
        ) {
            return .alreadyPresent(displayName: label)
        }

        do {
            let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(
                candidate,
                localOnly: true,
                allowLocalMetadataFallback: true
            )
            try AppState.shared.registerAuthenticatedCredential(credential, usage: usage, note: nil)
            if !ProviderRefreshCoordinator.shouldSkipImmediateProviderRefresh(for: providerID) {
                _ = await ProviderRefreshCoordinator.shared.fetchSingleProvider(providerID)
            }
            subscriptionBridgeLog.notice(
                "Added CPA auth to subscription accounts provider=\(providerID, privacy: .public) label=\(label, privacy: .public)"
            )
            return .added(displayName: label)
        } catch {
            let message = SensitiveDataRedactor.redactedMessage(for: error)
            subscriptionBridgeLog.error("Add CPA auth to subscription failed: \(message, privacy: .public)")
            return .failed(message)
        }
    }

    /// 启动时：把 AuthImports/codex 中尚未出现在订阅列表的账号补回（跳过永久删除）。
    func backfillSubscriptionAccountsFromAuthImportsIfNeeded() async {
        // Off 模式下启动不进行后台扫描或 OpenAI token/OAuth 校验；仅激活原生身份才允许校验。
        guard AppSettings.shared.autoRefreshInterval != 0 else { return }
        guard CodexQuotaPollingPolicy.activeNativeIdentity() != nil else { return }
        let roots = ProviderManagedImportStore.readableImportRoots().map {
            $0.appendingPathComponent("codex", isDirectory: true)
        }
        var didAdd = false
        var seenPaths = Set<String>()
        for root in roots {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            for url in files where url.pathExtension.lowercased() == "json" {
                guard AppSettings.shared.autoRefreshInterval != 0,
                      let expectedIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(),
                      let expectedKey = expectedIdentity.nativeKey else {
                    return
                }
                let path = url.standardizedFileURL.path
                guard seenPaths.insert(path).inserted else { continue }
                guard let candidateIdentity = CodexQuotaPollingPolicy.verifiedNativeIdentity(atPath: path),
                      candidateIdentity.nativeKey == expectedKey else {
                    continue
                }
                let candidate = ProviderAuthManager.makeCodexCandidate(
                    authFileURL: url,
                    shouldCopyFile: !ProviderManagedImportStore.isWritableManagedImportPath(path)
                )
                if subscriptionAlreadyContains(
                    candidate: candidate,
                    providerID: "codex",
                    respectPermanentRemoval: true
                ) {
                    continue
                }
                guard CodexQuotaPollingPolicy.activeNativeIdentity()?.nativeKey == expectedKey else {
                    continue
                }
                do {
                    let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(
                        candidate,
                        localOnly: true,
                        allowLocalMetadataFallback: true
                    )
                    let currentActiveKey = CodexQuotaPollingPolicy.activeNativeIdentity()?.nativeKey
                    let credentialKey = CodexQuotaPollingPolicy.credentialIdentity(for: credential)?.nativeKey
                    guard currentActiveKey == expectedKey, credentialKey == expectedKey else {
                        if candidate.shouldCopyFile,
                           credential.authMethod == .authFile,
                           credential.credential != candidate.sourcePath {
                            try? FileManager.default.removeItem(atPath: credential.credential)
                        }
                        continue
                    }
                    try AppState.shared.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                    didAdd = true
                    subscriptionBridgeLog.notice(
                        "Backfilled AuthImports Codex into subscription: \(candidate.title, privacy: .public)"
                    )
                } catch {
                    subscriptionBridgeLog.error(
                        "AuthImports backfill skipped: \(SensitiveDataRedactor.redactedMessage(for: error), privacy: .public)"
                    )
                }
            }
        }
        _ = didAdd
    }

    private static let subscriptionImportableProviderIDs: Set<String> = ["codex"]

    private static func subscriptionProviderID(for gatewayProviderID: String) -> String? {
        switch gatewayProviderID.lowercased() {
        case "codex": return "codex"
        default: return nil
        }
    }

    private func displayLabel(
        for candidate: ProviderAuthCandidate,
        authURL: URL,
        providerID: String
    ) -> String {
        let base = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerID == "codex",
              let data = try? Data(contentsOf: authURL),
              let identity = try? CLIProxyAccountIdentity.parse(data: data, providerHint: "codex"),
              let plan = identity.resolvedPlanDisplayName else {
            return base.isEmpty ? candidate.title : base
        }
        if base.isEmpty { return "\(plan) · Codex" }
        return "\(base) · \(plan)"
    }

    /// - Parameter respectPermanentRemoval: `true` 用于自动补回（尊重用户删除）；
    ///   用户手动「添加到订阅」传 `false`，以便复活墓碑、接入同邮箱另一 workspace。
    private func subscriptionAlreadyContains(
        candidate: ProviderAuthCandidate,
        providerID: String,
        respectPermanentRemoval: Bool
    ) -> Bool {
        let registry = AppState.shared.accountStore.accountRegistry
            .filter { $0.providerId.lowercased() == providerID }
        let path = candidate.sourcePath?.lowercased()
        let multiWorkspace = AccountCredentialStore.isMultiWorkspace(providerID)

        let credentials = AccountCredentialStore.shared.loadAllCredentials()
            .filter { $0.providerId.lowercased() == providerID }
        let credentialByID = Dictionary(uniqueKeysWithValues: credentials.map { ($0.id, $0) })

        if providerID == "codex" {
            guard let path = candidate.sourcePath,
                  let json = ProviderAuthManager.loadJSONObject(at: path) else { return false }
            return AccountIdentityPolicy.codexSubscriptionAlreadyContains(
                identity: CodexAccountIdentity(authJSON: json), sourcePath: path,
                registry: registry, credentialLookup: credentialByID,
                respectRemoval: respectPermanentRemoval
            )
        }

        let candidateEmail = candidate.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let candidateFingerprint = candidate.sessionFingerprint?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let fileAccountId = codexWorkspaceAccountId(at: candidate.sourcePath)
        let fileProjectId = antigravityProjectId(at: candidate.sourcePath)

        if respectPermanentRemoval {
            if let path, registry.contains(where: {
                ($0.isPermanentlyRemoved || $0.isHidden) && ($0.sourceFilePath?.lowercased() == path)
            }) {
                return true
            }
        }

        for account in registry where respectPermanentRemoval || (!account.isHidden && !account.isPermanentlyRemoved) {
            if let fingerprint = candidateFingerprint,
               let credID = account.credentialId,
               let cred = credentialByID[credID],
               let existing = cred.metadata["sessionFingerprint"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
               existing == fingerprint {
                return true
            }
            if providerID == "antigravity" {
                let storedProject = (credentialByID[account.credentialId ?? ""]?
                    .metadata["projectId"] ?? account.accountId)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if let fileProjectId,
                   let existingProject = storedProject,
                   !existingProject.isEmpty,
                   existingProject == fileProjectId,
                   !candidateEmail.isEmpty,
                   account.normalizedEmail == candidateEmail {
                    return true
                }
                if fileProjectId == nil,
                   let path,
                   let credID = account.credentialId,
                   let cred = credentialByID[credID],
                   AccountCredentialStore.normalizedAuthFilePath(cred.credential)
                    == AccountCredentialStore.normalizedAuthFilePath(path) {
                    return true
                }
                continue
            }
            if let fileAccountId, let accountId = account.normalizedAccountId, fileAccountId == accountId {
                return true
            }
            if fileAccountId == nil,
               !multiWorkspace,
               !candidateEmail.isEmpty,
               account.normalizedEmail == candidateEmail {
                return true
            }
        }

        if let path {
            let normalizedPath = AccountCredentialStore.normalizedAuthFilePath(path)
            for cred in credentials {
                if AccountCredentialStore.normalizedAuthFilePath(cred.credential) == normalizedPath {
                    return true
                }
            }
        }
        return false
    }

    private func codexWorkspaceAccountId(at path: String?) -> String? {
        guard let path,
              let json = ProviderAuthManager.loadJSONObject(at: path) else { return nil }
        if let accountId = (json["account_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           !accountId.isEmpty {
            return accountId
        }
        // CPA/CLI 文件偶发只有 JWT；与 sessionFingerprint 同源。
        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let identity = try? CLIProxyAccountIdentity.parse(data: data, providerHint: "codex"),
           let accountId = identity.accountID?.lowercased(),
           !accountId.isEmpty {
            return accountId
        }
        return nil
    }

    private func antigravityProjectId(at path: String?) -> String? {
        guard let path,
              let json = ProviderAuthManager.loadJSONObject(at: path),
              let projectId = (json["project_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
              !projectId.isEmpty else { return nil }
        return projectId
    }
}
