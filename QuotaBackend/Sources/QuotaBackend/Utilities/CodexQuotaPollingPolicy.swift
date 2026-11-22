import Foundation

public enum CodexQuotaPollingMode: String, Sendable, CaseIterable {
    case activeOnly = "active_only"
}

/// Passive Codex polling policy. Only the single active Desktop native identity
/// (`accountId + userId` from `~/.codex/auth.json`) may poll automatically;
/// dormant credentials stay cache-only unless explicitly checked by the user.
public enum CodexQuotaPollingPolicy {
    public static func pollingMode() -> CodexQuotaPollingMode {
        .activeOnly
    }

    public static func nativeAuthFileURL(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("auth.json", isDirectory: false)
    }

    /// Reads ONLY `~/.codex/auth.json` (never `CODEX_AUTH_FILE`, `CODEX_AUTH_DIR`,
    /// email, or `AuthImports` mtime). Returns `nil` when absent, malformed,
    /// missing `accountId + userId`, API-key-only, or holding conflicting claims.
    public static func activeNativeIdentity(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> CodexAccountIdentity? {
        verifiedNativeIdentity(atPath: nativeAuthFileURL(homeDirectory: homeDirectory).path)
    }

    public static func verifiedNativeIdentity(atPath path: String) -> CodexAccountIdentity? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let apiKey = (json["OPENAI_API_KEY"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !apiKey.isEmpty {
            return nil
        }

        if hasConflictingTokenGroups(in: json) {
            return nil
        }

        let identity = CodexAccountIdentity(authJSON: json)
        guard identity.nativeKey != nil else {
            return nil
        }
        return identity
    }

    public static func credentialIdentity(for credential: AccountCredential) -> CodexAccountIdentity? {
        guard credential.providerId.lowercased() == "codex",
              credential.authMethod == .authFile else {
            return nil
        }
        guard let fileIdentity = verifiedNativeIdentity(atPath: credential.credential) else {
            return nil
        }
        let metadataIdentity = CodexAccountIdentity(credential: credential)
        guard !fileIdentity.conflicts(with: metadataIdentity) else {
            return nil
        }
        return fileIdentity
    }

    public static func credentialMatchesActiveIdentity(
        _ credential: AccountCredential,
        activeIdentity: CodexAccountIdentity
    ) -> Bool {
        guard let activeKey = activeIdentity.nativeKey,
              let credentialKey = credentialIdentity(for: credential)?.nativeKey else {
            return false
        }
        return credentialKey == activeKey
    }

    public static func authFileMatchesActiveIdentity(
        atPath path: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> Bool {
        guard let activeKey = activeNativeIdentity(homeDirectory: homeDirectory)?.nativeKey,
              let candidateKey = verifiedNativeIdentity(atPath: path)?.nativeKey else {
            return false
        }
        return candidateKey == activeKey
    }

    private static func hasConflictingTokenGroups(in json: [String: Any]) -> Bool {
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        let flatAccess = nonEmptyString(json["access_token"] ?? json["accessToken"])
        let flatId = nonEmptyString(json["id_token"] ?? json["idToken"])
        let nestedAccess = nonEmptyString(tokens["access_token"] ?? tokens["accessToken"])
        let nestedId = nonEmptyString(tokens["id_token"] ?? tokens["idToken"])

        let hasFlat = flatAccess != nil || flatId != nil
        let hasNested = nestedAccess != nil || nestedId != nil
        guard hasFlat && hasNested else { return false }

        let (flatAccessId, nestedAccessId) = CodexAccountIdentity.tokenPairIdentities(flatAccess, nestedAccess)
        if flatAccessId.conflicts(with: nestedAccessId) {
            return true
        }
        let (flatIdIdentity, nestedIdIdentity) = CodexAccountIdentity.tokenPairIdentities(flatId, nestedId)
        if flatIdIdentity.conflicts(with: nestedIdIdentity) {
            return true
        }
        let flatAcct = nonEmptyString(json["account_id"] ?? json["accountId"] ?? json["chatgpt_account_id"])?.lowercased()
        let nestedAcct = nonEmptyString(tokens["account_id"] ?? tokens["accountId"])?.lowercased()
        if let flatAcct, let nestedAcct, flatAcct != nestedAcct {
            return true
        }
        return false
    }

    private static func nonEmptyString(_ raw: Any?) -> String? {
        guard let value = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
