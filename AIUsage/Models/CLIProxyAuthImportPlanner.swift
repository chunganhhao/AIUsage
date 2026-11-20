import CryptoKit
import Foundation

// MARK: - CPA Auth Import Pipeline (pure logic)
// 安全导入中心的识别与规划层：读取顶层 type、按允许名单识别 Provider、
// 展开原始 Codex auth.json、剥离 AIUsage 托管标记，然后与 CPA 现有文件做
// 内容级（规范化 SHA-256）与身份级（Codex/Antigravity 原生身份）去重规划。
// 本文件不做任何磁盘或网络 I/O，便于回归验证；执行层在
// CLIProxyGatewayManager+Import.swift。

// MARK: - Inspection

/// A locally recognized, upload-ready auth payload.
nonisolated struct CLIProxyAuthImportInspection: Equatable, Sendable {
    let sourceFileName: String
    /// Canonicalized JSON that would be uploaded (post conversion, marker stripped).
    let payload: Data
    let canonicalHash: String
    /// Normalized CPA auth `type` (e.g. `codex`, `antigravity`, `gemini-cli`).
    let providerType: String
    /// Non-secret display identity (masked email, workspace/project short ID).
    let maskedIdentity: String?
    let projectSummary: String?
    let byteCount: Int
    /// The file was a raw Codex CLI auth.json and was expanded into CPA schema.
    let convertedFromCodexCLI: Bool
    /// An `aiusage_credential_id` ownership marker was removed. Manual imports
    /// must never masquerade as AIUsage-managed copies.
    let strippedManagedMarker: Bool
    /// Strong provider-native identity, only for verified parsers (Codex/Antigravity/Gemini).
    let identityKey: String?
    /// The provider type requires a CPA plugin that is not currently enabled.
    let missingPluginHint: String?
}

nonisolated enum CLIProxyAuthImportInspectionFailure: Error, Equatable, Sendable {
    case notJSONObject
    case typeProviderConflict(type: String, provider: String)
    case unknownType(String)
    case missingType
    case missingCredentialMaterial(type: String)
    case suspendedAccount(type: String)
    case disallowedProvider(type: String)
    case disallowedCodexPlan(reason: String)
    case disallowedRetryOverride(reason: String)
    case looksLikeAPIKeyConfig
    case looksLikeServiceAccount

    var message: String {
        switch self {
        case .notJSONObject:
            L("The file is not a JSON object.", "文件不是 JSON 对象。")
        case .typeProviderConflict(let type, let provider):
            L("The file declares conflicting identifiers: type \"\(type)\" vs provider \"\(provider)\".",
              "文件的 type（\(type)）与 provider（\(provider)）互相冲突。")
        case .unknownType(let type):
            L("Unknown provider type \"\(type)\". Unrecognized credentials are blocked by default.",
              "无法识别的 Provider 类型“\(type)”。未知凭据默认阻止导入。")
        case .missingType:
            L("No provider type was found and the structure does not match a known credential.",
              "文件缺少 Provider 类型，且结构不符合任何已知凭据格式。")
        case .missingCredentialMaterial(let type):
            L("The \(type) credential is missing its required token fields.",
              "该 \(type) 凭据缺少必需的 Token 字段。")
        case .suspendedAccount(let type):
            L("This \(type) account is suspended or disabled and cannot be imported into CPA.",
              "该 \(type) 账号已被封禁或停用，无法导入到 CPA。")
        case .disallowedProvider(let type):
            L("Provider \"\(type)\" consumer OAuth credentials cannot be imported into CPA under the current release policy.",
              "根据当前发布策略，无法将“\(type)”消费者 OAuth 凭据导入 CPA。")
        case .disallowedCodexPlan(let reason):
            L("Codex account cannot be imported into CPA: \(reason)",
              "Codex 账号无法导入 CPA：\(reason)")
        case .disallowedRetryOverride(let reason):
            L("Auth file violates zero-retry/cooling policy: \(reason)",
              "认证文件违反零重试/冷却保护策略：\(reason)")
        case .looksLikeAPIKeyConfig:
            L("This looks like an API-key configuration file, not a CPA auth file. Use the API upstream form instead.",
              "这看起来是 API Key 配置文件，不是 CPA 认证文件。请改用“API 上游”入口配置。")
        case .looksLikeServiceAccount:
            L("This is a Google service-account key, not a CPA auth file. Typed Vertex import is planned for a later release.",
              "这是 Google 服务账号密钥，不是 CPA 认证文件。类型化的 Vertex 导入将在后续版本提供。")
        }
    }
}

nonisolated enum CLIProxyAuthImportInspector {
    /// Recognizes one JSON payload entirely locally. `enabledPluginProviderIDs`
    /// lists plugin providers of the running CPA build whose auth files may be
    /// imported; plugin types outside that set are flagged as needing a plugin.
    static func inspect(
        fileName: String,
        data: Data,
        enabledPluginProviderIDs: Set<String>,
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys
    ) -> Result<CLIProxyAuthImportInspection, CLIProxyAuthImportInspectionFailure> {
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return .failure(.notJSONObject)
        }

        let declaredType = CLIProxyCapabilityMatrix.normalizedAuthType(string(object["type"]))
        let declaredProvider = CLIProxyCapabilityMatrix.normalizedAuthType(string(object["provider"]))
        if let declaredType, let declaredProvider, declaredType != declaredProvider {
            return .failure(.typeProviderConflict(type: declaredType, provider: declaredProvider))
        }

        if (string(object["type"]) ?? "").lowercased() == "service_account"
            || (object["private_key"] != nil && object["client_email"] != nil && declaredType == nil) {
            return .failure(.looksLikeServiceAccount)
        }
        if object["api-keys"] != nil || object["openai-compatibility"] != nil
            || (object["base-url"] != nil && object["api-key"] != nil && declaredType == nil) {
            return .failure(.looksLikeAPIKeyConfig)
        }

        var convertedFromCodexCLI = false
        var resolvedType = declaredType ?? declaredProvider
        if resolvedType == nil {
            guard looksLikeRawCodexAuthJSON(object) else {
                return .failure(.missingType)
            }
            object = expandRawCodexAuthJSON(object)
            resolvedType = "codex"
            convertedFromCodexCLI = true
        } else if resolvedType == "codex" {
            // A declared Codex file may still carry the raw nested layout.
            if looksLikeRawCodexAuthJSON(object), object["access_token"] == nil {
                object = expandRawCodexAuthJSON(object)
                convertedFromCodexCLI = true
            }
        }

        guard let providerType = resolvedType else { return .failure(.missingType) }

        let normalizedPluginIDs = Set(enabledPluginProviderIDs.map { $0.lowercased() })
        var missingPluginHint: String?
        if providerType == "antigravity" {
            let reason = (object["circuit_breaker_reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if object["tos_suspended"] as? Bool == true
                || object["tos_violation"] as? Bool == true
                || object["disabled"] as? Bool == true
                || reason == "TOS_VIOLATION" {
                return .failure(.suspendedAccount(type: providerType))
            }
        }
        if CLIProxyCapabilityMatrix.isDisallowedCPAProvider(providerType, disallowedProviderIDs: disallowedProviderIDs) {
            return .failure(.disallowedProvider(type: providerType))
        }
        if !CLIProxyCapabilityMatrix.importableAuthTypes.contains(providerType),
           !normalizedPluginIDs.contains(providerType) {
            return .failure(.unknownType(providerType))
        }
        if ["gemini", "gemini-cli"].contains(providerType),
           !normalizedPluginIDs.contains("gemini-cli"), !normalizedPluginIDs.contains("gemini") {
            missingPluginHint = "gemini-cli"
        }

        guard hasCredentialMaterial(object) else {
            return .failure(.missingCredentialMaterial(type: providerType))
        }

        if let overrideRejection = CLIProxyCapabilityMatrix.disallowedPerCredentialRetryOverrideReason(in: object) {
            return .failure(.disallowedRetryOverride(reason: overrideRejection))
        }

        if providerType == "codex" && !allowedCodexPlans.isEmpty {
            if let planRejection = CLIProxyCapabilityMatrix.codexPlanVerification(
                fromJSONObject: object,
                allowedPlans: allowedCodexPlans,
                trustedKeys: trustedCodexIssuerKeys
            ).rejectionReason {
                return .failure(.disallowedCodexPlan(reason: planRejection))
            }
        }

        var strippedManagedMarker = false
        if object["aiusage_credential_id"] != nil {
            object["aiusage_credential_id"] = nil
            strippedManagedMarker = true
        }
        if var tokens = object["tokens"] as? [String: Any], tokens["aiusage_credential_id"] != nil {
            tokens["aiusage_credential_id"] = nil
            object["tokens"] = tokens
            strippedManagedMarker = true
        }
        object["type"] = providerType

        guard JSONSerialization.isValidJSONObject(object),
              let payload = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return .failure(.notJSONObject)
        }
        let hash = SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()

        var identityKey: String?
        if ["codex", "antigravity", "gemini", "gemini-cli"].contains(providerType),
           let identity = try? CLIProxyAccountIdentity.parse(data: payload, providerHint: providerType),
           identity.canAutomaticallyMerge {
            identityKey = identity.key
        }

        return .success(CLIProxyAuthImportInspection(
            sourceFileName: fileName,
            payload: payload,
            canonicalHash: hash,
            providerType: providerType,
            maskedIdentity: maskedIdentity(from: object),
            projectSummary: projectSummary(from: object),
            byteCount: payload.count,
            convertedFromCodexCLI: convertedFromCodexCLI,
            strippedManagedMarker: strippedManagedMarker,
            identityKey: identityKey,
            missingPluginHint: missingPluginHint
        ))
    }

    // MARK: Internal helpers

    private static func looksLikeRawCodexAuthJSON(_ object: [String: Any]) -> Bool {
        guard let tokens = object["tokens"] as? [String: Any] else { return false }
        let access = string(tokens["access_token"]) ?? ""
        let refresh = string(tokens["refresh_token"]) ?? ""
        return !access.isEmpty && !refresh.isEmpty
    }

    private static func expandRawCodexAuthJSON(_ object: [String: Any]) -> [String: Any] {
        var result = object
        if let tokens = object["tokens"] as? [String: Any] {
            for key in ["id_token", "access_token", "refresh_token", "account_id"] {
                if result[key] == nil, let value = tokens[key] { result[key] = value }
            }
        }
        result["type"] = "codex"
        result["OPENAI_API_KEY"] = nil
        return result
    }

    private static func hasCredentialMaterial(_ object: [String: Any]) -> Bool {
        let credentialKeys = [
            "access_token", "refresh_token", "id_token",
            "api_key", "token", "private_key", "session_token"
        ]
        for key in credentialKeys {
            if let value = string(object[key]), !value.isEmpty { return true }
        }
        if let tokens = object["tokens"] as? [String: Any] {
            for key in credentialKeys {
                if let value = string(tokens[key]), !value.isEmpty { return true }
            }
        }
        return false
    }

    private static func maskedIdentity(from object: [String: Any]) -> String? {
        if let email = string(object["email"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !email.isEmpty {
            return maskEmail(email)
        }
        if let label = string(object["label"])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !label.isEmpty {
            return label
        }
        return nil
    }

    private static func projectSummary(from object: [String: Any]) -> String? {
        if let project = string(object["project_id"]) ?? string(object["projectId"]),
           !project.isEmpty {
            return L("Project \(shortIdentifier(project))", "项目 \(shortIdentifier(project))")
        }
        if let account = string(object["account_id"]) ?? string(object["chatgpt_account_id"]),
           !account.isEmpty {
            return L("Workspace \(shortIdentifier(account))", "工作区 \(shortIdentifier(account))")
        }
        return nil
    }

    private static func maskEmail(_ email: String) -> String {
        guard let atIndex = email.firstIndex(of: "@"), atIndex != email.startIndex else {
            let prefix = email.prefix(2)
            return "\(prefix)•••"
        }
        let local = email[..<atIndex]
        let domain = email[email.index(after: atIndex)...]
        let visible = local.prefix(2)
        return "\(visible)•••@\(domain)"
    }

    private static func shortIdentifier(_ value: String) -> String {
        guard value.count > 14 else { return value }
        return "\(value.prefix(7))…\(value.suffix(5))"
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() {
            return value.stringValue
        }
        return nil
    }
}

// MARK: - Planning

/// A CPA-side file description gathered before planning. Hash and identity are
/// optional because downloads can fail; missing data degrades to name-only
/// conflict handling and never enables a destructive action.
nonisolated struct CLIProxyAuthImportExistingFile: Equatable, Sendable {
    let name: String
    let providerType: String?
    let canonicalHash: String?
    let identityKey: String?
    let isManagedCopy: Bool
}

nonisolated enum CLIProxyAuthImportAction: Equatable, Sendable {
    /// Upload as a new file. `renamedFrom` is set when the preferred name collided.
    case upload(name: String, renamedFrom: String?)
    /// Byte-identical content already exists in CPA; skip silently.
    case skipDuplicate(existingName: String)
    /// Same strong native identity but different credentials or settings.
    /// Requires an explicit per-item decision; default keeps the existing file.
    case confirmReplace(existingName: String)
    /// The matching file is an AIUsage-managed copy; plain import never overwrites it.
    case blockedManagedCopy(existingName: String)
    /// A required provider plugin is not installed or enabled.
    case requiresPlugin(String)
    case blocked(reason: String)
}

/// How the user resolved a `confirmReplace` conflict.
nonisolated enum CLIProxyAuthImportConflictChoice: Equatable, Sendable {
    case keepExisting
    case replaceExisting
}

nonisolated struct CLIProxyAuthImportPlannedItem: Equatable, Sendable, Identifiable {
    let id: String
    let fileName: String
    let inspection: CLIProxyAuthImportInspection?
    let action: CLIProxyAuthImportAction
}

nonisolated enum CLIProxyAuthImportPlanner {
    static let maxBatchCount = 20
    static let maxBatchBytes = 20 * 1_048_576

    /// Produces one action per inspected file. Conservative by design:
    /// content-identical files are skipped, identity conflicts require per-item
    /// confirmation, managed copies are never overwritten, and duplicate
    /// identities inside one batch are blocked instead of guessed.
    static func plan(
        inspected: [(fileName: String, result: Result<CLIProxyAuthImportInspection, CLIProxyAuthImportInspectionFailure>)],
        existing: [CLIProxyAuthImportExistingFile]
    ) -> [CLIProxyAuthImportPlannedItem] {
        let existingHashes = Dictionary(
            existing.compactMap { file in file.canonicalHash.map { ($0, file.name) } },
            uniquingKeysWith: { first, _ in first }
        )
        let existingIdentities = Dictionary(
            existing.compactMap { file in file.identityKey.map { ($0, file) } },
            uniquingKeysWith: { first, _ in first }
        )
        var reservedNames = Set(existing.map { $0.name.lowercased() })
        var seenBatchHashes: [String: String] = [:]
        var seenBatchIdentities: [String: String] = [:]
        var items: [CLIProxyAuthImportPlannedItem] = []

        for (index, entry) in inspected.enumerated() {
            let itemID = "import-\(index)-\(entry.fileName.lowercased())"
            switch entry.result {
            case .failure(let failure):
                items.append(CLIProxyAuthImportPlannedItem(
                    id: itemID,
                    fileName: entry.fileName,
                    inspection: nil,
                    action: .blocked(reason: failure.message)
                ))
            case .success(let inspection):
                let action = planAction(
                    inspection: inspection,
                    existingHashes: existingHashes,
                    existingIdentities: existingIdentities,
                    reservedNames: &reservedNames,
                    seenBatchHashes: &seenBatchHashes,
                    seenBatchIdentities: &seenBatchIdentities
                )
                items.append(CLIProxyAuthImportPlannedItem(
                    id: itemID,
                    fileName: entry.fileName,
                    inspection: inspection,
                    action: action
                ))
            }
        }
        return items
    }

    private static func planAction(
        inspection: CLIProxyAuthImportInspection,
        existingHashes: [String: String],
        existingIdentities: [String: CLIProxyAuthImportExistingFile],
        reservedNames: inout Set<String>,
        seenBatchHashes: inout [String: String],
        seenBatchIdentities: inout [String: String]
    ) -> CLIProxyAuthImportAction {
        if let pluginHint = inspection.missingPluginHint {
            return .requiresPlugin(pluginHint)
        }
        if let duplicateName = seenBatchHashes[inspection.canonicalHash] {
            return .skipDuplicate(existingName: duplicateName)
        }
        if let existingName = existingHashes[inspection.canonicalHash] {
            seenBatchHashes[inspection.canonicalHash] = existingName
            return .skipDuplicate(existingName: existingName)
        }
        if let identityKey = inspection.identityKey {
            if let batchName = seenBatchIdentities[identityKey] {
                return .blocked(reason: L(
                    "The batch contains multiple different credentials for the same account (\(batchName)). Pick one file manually.",
                    "批次内同一账号出现多份不同凭据（与 \(batchName) 冲突），请手动挑选一份导入。"
                ))
            }
            if let existingFile = existingIdentities[identityKey] {
                seenBatchHashes[inspection.canonicalHash] = existingFile.name
                seenBatchIdentities[identityKey] = inspection.sourceFileName
                return existingFile.isManagedCopy
                    ? .blockedManagedCopy(existingName: existingFile.name)
                    : .confirmReplace(existingName: existingFile.name)
            }
            seenBatchIdentities[identityKey] = inspection.sourceFileName
        }

        let preferred = sanitizedImportFileName(inspection.sourceFileName)
        let unique = uniqueFileName(preferred: preferred, reserved: reservedNames)
        reservedNames.insert(unique.lowercased())
        seenBatchHashes[inspection.canonicalHash] = unique
        return .upload(name: unique, renamedFrom: unique == preferred ? nil : preferred)
    }

    /// Manual imports never claim the `aiusage-` managed namespace; a foreign
    /// export that carries the prefix is renamed so ownership stays provable.
    static func sanitizedImportFileName(_ preferred: String) -> String {
        var clean = URL(fileURLWithPath: preferred).lastPathComponent
            .replacingOccurrences(of: "\\", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        clean = String(clean.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) ? Character("-") : Character($0)
        })
        if clean.isEmpty { clean = "auth.json" }
        if URL(fileURLWithPath: clean).pathExtension.caseInsensitiveCompare("json") != .orderedSame {
            clean += ".json"
        }
        if clean.lowercased().hasPrefix("aiusage-") {
            clean = "imported-" + clean
        }
        var stem = String(clean.dropLast(5))
        while stem.utf8.count > 220 { stem.removeLast() }
        if stem.isEmpty { stem = "auth" }
        return stem + ".json"
    }

    static func uniqueFileName(preferred: String, reserved: Set<String>) -> String {
        guard reserved.contains(preferred.lowercased()) else { return preferred }
        let stem = String(preferred.dropLast(5))
        for suffix in 2...9_999 {
            let candidate = "\(stem)-\(suffix).json"
            if !reserved.contains(candidate.lowercased()) { return candidate }
        }
        return "auth-\(UUID().uuidString).json"
    }
}

// MARK: - Import session state

/// UI-facing state for one multi-file import run. Payloads live only in this
/// in-memory session; nothing is persisted between runs.
nonisolated struct CLIProxyAuthImportSession: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case preview
        case executing
        case completed
    }

    enum Mode: Equatable, Sendable {
        /// Any CPA-compatible auth JSON (advanced migration).
        case general
        /// Dedicated Codex auth.json conversion entry.
        case codexAuthJSON
    }

    struct Item: Identifiable, Equatable, Sendable {
        let id: String
        let fileName: String
        let inspection: CLIProxyAuthImportInspection?
        let action: CLIProxyAuthImportAction
        var conflictChoice: CLIProxyAuthImportConflictChoice = .keepExisting
        var outcome: CLIProxyAuthImportItemOutcome?
    }

    let mode: Mode
    var phase: Phase
    var items: [Item]

    var actionableCount: Int {
        items.filter { item in
            switch item.action {
            case .upload: true
            case .confirmReplace: item.conflictChoice == .replaceExisting
            default: false
            }
        }.count
    }

    var failedCount: Int {
        items.filter {
            if case .uploadFailed = $0.outcome { return true }
            return false
        }.count
    }
}

// MARK: - Execution results

nonisolated enum CLIProxyAuthImportItemOutcome: Equatable, Sendable {
    case imported(name: String)
    case renamedImported(name: String)
    case replacedExisting(name: String)
    case skippedDuplicate
    case keptExisting
    case blocked(reason: String)
    case requiresPlugin(String)
    case uploadFailed(message: String)
    /// The upload succeeded, but the post-import verification read failed.
    /// The user must not re-import; a later refresh resolves it.
    case verificationPending(name: String)
}
