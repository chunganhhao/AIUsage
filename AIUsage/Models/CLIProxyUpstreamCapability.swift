import CryptoKit
import Foundation

// MARK: - CPA Upstream Capability Matrix
// 单一事实来源：判断一个 AIUsage 订阅账号相对 CPA 网关的角色。
// 能力由已验证的适配器与 CPA 内置 OAuth 路由决定，而不是根据应用名称或
// 账号是否存在进行猜测；未知 Provider 一律视为“不能作为 CPA 上游”。

/// The role an AIUsage-monitored provider can play for the CPA gateway.
nonisolated enum CLIProxyUpstreamCapability: Equatable, Sendable {
    /// AIUsage holds a credential that a verified adapter can copy into CPA.
    case syncableFromAIUsage
    /// CPA supports this provider through its built-in OAuth, but AIUsage
    /// credentials cannot be copied; the user must authorize inside CPA.
    case requiresCPAOAuth(CLIProxyOAuthProvider)
    /// CPA supports this provider only through an official provider plugin.
    case requiresPlugin(pluginHint: String)
    /// The provider is a downstream client or monitoring-only account and can
    /// never become a CPA upstream. It must not appear as a candidate.
    case notAnUpstream
}

nonisolated enum CodexPlanVerification: Equatable, Sendable {
    case verified(String)
    case missing
    case stale(String)
    case mismatched(String)
    case conflicting([String])
    case disallowed(String)

    var verifiedPlan: String? {
        if case let .verified(plan) = self { return plan }
        return nil
    }

    var rejectionReason: String? {
        switch self {
        case .verified:
            return nil
        case .missing:
            return "Codex account plan cannot be verified (missing validated token-bound ChatGPT plan assertion; only ChatGPT Go and ChatGPT Free accounts are allowed in CPA)"
        case let .stale(reason):
            return "Codex account plan evidence is stale (\(reason)); refusing CPA access"
        case let .mismatched(reason):
            return "Codex account plan evidence does not match the dispatched credential identity (\(reason)); refusing CPA access"
        case let .conflicting(plans):
            return "Codex account has conflicting ChatGPT plans (\(plans.joined(separator: ", "))); refusing CPA access"
        case let .disallowed(plan):
            return "Codex plan '\(plan)' is blocked by CPA policy (only ChatGPT Go and ChatGPT Free accounts are allowed)"
        }
    }
}

nonisolated enum CLIProxyCapabilityMatrix {
    /// Providers blocked from CPA gateway execution, OAuth, sync, and import under release policy.
    /// CPA subscription accounts are strictly locked to Codex (`ChatGPT Go` / `ChatGPT Free`) only.
    static let defaultDisallowedProviderIDs: Set<String> = [
        "antigravity", "claude", "anthropic",
        "kimi", "xai", "grok", "gemini", "gemini-cli", "vertex",
        "qwen", "iflow"
    ]

    /// Provider types CPA can persist as auth files. Anything outside this
    /// list (only Codex Go/Free) is blocked on import and runtime execution.
    static let importableAuthTypes: Set<String> = ["codex"]

    /// Direct CPA sidecar OAuth sign-in is disabled under the ChatGPT Go/Free restriction
    /// because the running sidecar would admit the new session before AIUsage can verify its plan.
    static let allowedOAuthProviderIDs: Set<String> = []

    /// Normalized ChatGPT plan types permitted for Codex CPA accounts.
    static let allowedCodexPlanTypes: Set<String> = ["go", "free"]

    /// Immutable trusted issuer public keys for offline cryptographic verification of Codex JWS tokens.
    /// Empty in this build so parsed/unauthenticated tokens and CPA subscription paths fail closed.
    static let defaultTrustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = []

    /// Whether this build ships trusted issuer keys capable of verifying CPA subscription tokens offline.
    static let subscriptionsEnabledInThisBuild: Bool = !defaultTrustedCodexIssuerKeys.isEmpty

    static let subscriptionsUnavailableMessage =
        "CPA subscription accounts are unavailable in this build. Use native Codex in AIUsage or configure an official OpenAI-compatible API-key upstream instead."

    static func directOAuthRejectionReason(
        for rawProviderID: String?,
        disallowedProviderIDs: Set<String> = defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = allowedCodexPlanTypes,
        allowedOAuthProviders: Set<String> = allowedOAuthProviderIDs
    ) -> String? {
        if !subscriptionsEnabledInThisBuild {
            return subscriptionsUnavailableMessage
        }
        if isDisallowedCPAProvider(rawProviderID, disallowedProviderIDs: disallowedProviderIDs) {
            return "Direct \(rawProviderID ?? "unknown") consumer OAuth is disabled in CPA Gateway."
        }
        let normalized = normalizedProviderIDs(from: [rawProviderID]).first
            ?? (rawProviderID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
        if !allowedCodexPlans.isEmpty || !allowedOAuthProviders.contains(normalized) {
            return "Direct CPA OAuth sign-in is disabled under the ChatGPT Go/Free restriction because the sidecar cannot verify plan eligibility before adding the account to the active routing pool. Sign in via AIUsage Subscriptions or import a verified Codex Go/Free auth file instead."
        }
        return nil
    }

    static func capability(forAIUsageProvider providerId: String) -> CLIProxyUpstreamCapability {
        guard subscriptionsEnabledInThisBuild else {
            return .notAnUpstream
        }
        let normalized = normalizedProviderIDs(from: [providerId]).first ?? providerId.lowercased()
        switch normalized {
        case "codex":
            return .syncableFromAIUsage
        default:
            return .notAnUpstream
        }
    }

    /// Rejects per-credential metadata overrides (`request_retry` / `request-retry` > 0 or
    /// `disable_cooling` / `disable-cooling` enabled) that bypass CPA's global `request-retry: 0`
    /// fail-closed policy at admission or disk-scan time.
    static func disallowedPerCredentialRetryOverrideReason(in object: [String: Any]) -> String? {
        let metadata = object["metadata"] as? [String: Any]
        let nested = (object["tokens"] as? [String: Any]) ?? (object["token"] as? [String: Any])
        let containers: [[String: Any]] = [object, metadata, nested].compactMap { $0 }

        func parseRetryInt(_ raw: Any) -> Int? {
            if raw is NSNull { return nil }
            if let num = raw as? NSNumber {
                // Reject booleans masquerading as numbers in JSON.
                if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
                return num.intValue
            }
            if let str = raw as? String {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty { return nil }
                return Int(trimmed)
            }
            return nil
        }

        func parseCoolingBool(_ raw: Any) -> Bool? {
            if raw is NSNull { return nil }
            if let num = raw as? NSNumber {
                if CFGetTypeID(num) == CFBooleanGetTypeID() {
                    return num.boolValue
                }
                return num.doubleValue != 0
            }
            if let str = raw as? String {
                switch str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                case "":
                    return nil
                case "true", "1", "yes", "on":
                    return true
                case "false", "0", "no", "off":
                    return false
                default:
                    return nil
                }
            }
            return nil
        }

        for container in containers {
            for retryKey in ["request_retry", "request-retry"] {
                guard let raw = container[retryKey], !(raw is NSNull) else { continue }
                if let str = raw as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                guard let retryValue = parseRetryInt(raw) else {
                    return "auth file contains unparseable per-credential retry override '\(retryKey)'"
                }
                if retryValue > 0 {
                    return "auth file overrides global zero retry policy ('\(retryKey)'=\(retryValue))"
                }
            }
            for coolingKey in ["disable_cooling", "disable-cooling"] {
                guard let raw = container[coolingKey], !(raw is NSNull) else { continue }
                if let str = raw as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    continue
                }
                guard let coolingDisabled = parseCoolingBool(raw) else {
                    return "auth file contains unparseable per-credential cooling override '\(coolingKey)'"
                }
                if coolingDisabled {
                    return "auth file disables quota cooldown protection ('\(coolingKey)'=true)"
                }
            }
        }
        return nil
    }

    static func normalizedAuthType(_ value: String?) -> String? {
        guard let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        switch normalized {
        case "chatgpt", "openai": return "codex"
        case "google-antigravity": return "antigravity"
        default: return normalized
        }
    }

    static func normalizedProviderIDs(from rawValues: [String?]) -> [String] {
        rawValues.compactMap { raw -> String? in
            guard let authNormalized = normalizedAuthType(raw) else { return nil }
            return authNormalized == "gemini-cli" ? "gemini" : authNormalized
        }
    }

    static func normalizedDisallowedProviderIDs(_ rawIDs: Set<String>) -> Set<String> {
        Set(normalizedProviderIDs(from: rawIDs.map(Optional.some)))
    }

    static func isDisallowedCPAProvider(
        _ rawProviderID: String?,
        disallowedProviderIDs: Set<String> = defaultDisallowedProviderIDs
    ) -> Bool {
        guard let provider = normalizedProviderIDs(from: [rawProviderID]).first else { return false }
        if normalizedDisallowedProviderIDs(disallowedProviderIDs).contains(provider) {
            return true
        }
        if disallowedProviderIDs == defaultDisallowedProviderIDs && provider != "codex" {
            return true
        }
        return false
    }

    static func disallowedProviderRejectionReason(
        rawProviders: [String?],
        disallowedProviderIDs: Set<String> = defaultDisallowedProviderIDs,
        sourceContext: String = "provider/type"
    ) -> String? {
        let disallowed = normalizedDisallowedProviderIDs(disallowedProviderIDs)
        guard !disallowed.isEmpty else { return nil }
        let providers = normalizedProviderIDs(from: rawProviders)
        if providers.isEmpty {
            return "\(sourceContext) is unknown or missing"
        }
        if let match = providers.first(where: { disallowed.contains($0) }) {
            return "provider '\(match)' is disallowed"
        }
        if disallowedProviderIDs == defaultDisallowedProviderIDs,
           let nonCodex = providers.first(where: { $0 != "codex" }) {
            return "provider '\(nonCodex)' is disallowed (Codex ChatGPT Go/Free only)"
        }
        return nil
    }

    static func normalizeCodexPlanType(_ raw: String?) -> String? {
        guard var normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !normalized.isEmpty else { return nil }
        for prefix in ["chatgpt ", "chatgpt_", "chatgpt-"] {
            if normalized.hasPrefix(prefix) {
                normalized = String(normalized.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return normalized.isEmpty ? nil : normalized
    }

    private struct TokenPrincipal: Equatable {
        let accountId: String?
        let userId: String?
        let email: String?
        let issuedAt: Double?
        let expiresAt: Double?
        let notBefore: Double?
        let hasInternalConflict: Bool
    }

    private static func trimmedString(_ raw: Any?) -> String? {
        if let str = raw as? String {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func normalizedIdentityString(_ raw: Any?) -> String? {
        trimmedString(raw)?.lowercased()
    }

    private static func numericEpoch(_ raw: Any?) -> Double? {
        if let num = raw as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
            let val = num.doubleValue
            return val.isFinite ? val : nil
        }
        if let str = trimmedString(raw), let val = Double(str), val.isFinite {
            return val
        }
        return nil
    }

    private static func extractTokenPrincipal(from claims: [String: Any]) -> TokenPrincipal {
        let authClaims = claims["https://api.openai.com/auth"] as? [String: Any]
        let profileClaims = claims["https://api.openai.com/profile"] as? [String: Any]

        func distinctValues(_ candidates: [Any?]) -> [String] {
            var result: [String] = []
            for candidate in candidates {
                guard let norm = normalizedIdentityString(candidate) else { continue }
                if !result.contains(norm) { result.append(norm) }
            }
            return result
        }

        let accounts = distinctValues([
            authClaims?["chatgpt_account_id"],
            claims["chatgpt_account_id"],
            claims["https://api.openai.com/auth.chatgpt_account_id"],
            claims["https://api.openai.com/auth/chatgpt_account_id"],
            authClaims?["account_id"],
            claims["account_id"]
        ])
        let chatGPTUsers = distinctValues([
            authClaims?["chatgpt_user_id"],
            claims["chatgpt_user_id"],
            claims["https://api.openai.com/auth.chatgpt_user_id"],
            claims["https://api.openai.com/auth/chatgpt_user_id"]
        ])
        let genericUsers = distinctValues([
            authClaims?["user_id"],
            claims["user_id"]
        ])
        let subjects = distinctValues([claims["sub"]])
        let emails = distinctValues([
            claims["email"],
            profileClaims?["email"],
            authClaims?["email"]
        ])

        let userValues = !chatGPTUsers.isEmpty ? chatGPTUsers : (!genericUsers.isEmpty ? genericUsers : subjects)
        let hasConflict = accounts.count > 1
            || chatGPTUsers.count > 1
            || genericUsers.count > 1
            || subjects.count > 1
            || emails.count > 1
            || (!chatGPTUsers.isEmpty && !genericUsers.isEmpty && Set(chatGPTUsers) != Set(genericUsers))

        return TokenPrincipal(
            accountId: accounts.first,
            userId: userValues.first,
            email: emails.first,
            issuedAt: numericEpoch(claims["iat"]),
            expiresAt: numericEpoch(claims["exp"]),
            notBefore: numericEpoch(claims["nbf"]),
            hasInternalConflict: hasConflict
        )
    }

    private static func extractTokenPlans(from claims: [String: Any]) -> Set<String> {
        var plans = Set<String>()
        func record(_ raw: Any?) {
            if let str = trimmedString(raw), let normalized = normalizeCodexPlanType(str) {
                plans.insert(normalized)
            }
        }
        record(claims["chatgpt_plan_type"])
        record(claims["plan_type"])
        record(claims["https://api.openai.com/auth.chatgpt_plan_type"])
        record(claims["https://api.openai.com/auth/chatgpt_plan_type"])
        record(claims["https://api.openai.com/auth.plan_type"])
        if let authClaims = claims["https://api.openai.com/auth"] as? [String: Any] {
            record(authClaims["chatgpt_plan_type"])
            record(authClaims["plan_type"])
        }
        return plans
    }

    static func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func codexPlanVerification(
        fromJSONObject object: [String: Any],
        metadata: [String: String] = [:],
        allowedPlans: Set<String> = allowedCodexPlanTypes,
        trustedKeys: [CLIProxyTrustedJWSKey] = defaultTrustedCodexIssuerKeys,
        now: Date = Date()
    ) -> CodexPlanVerification {
        // Never trust parsed token claims without at least one configured trusted issuer public key.
        guard !trustedKeys.isEmpty else {
            return .missing
        }

        var hintPlans = Set<String>()
        func recordHint(_ raw: Any?) {
            if let str = trimmedString(raw), let normalized = normalizeCodexPlanType(str) {
                hintPlans.insert(normalized)
            }
        }

        recordHint(object["plan_type"])
        recordHint(object["chatgpt_plan_type"])

        let tokensDict = object["tokens"] as? [String: Any]
        let tokenDict = object["token"] as? [String: Any]
        if let tokensDict, let tokenDict,
           NSDictionary(dictionary: tokensDict) != NSDictionary(dictionary: tokenDict) {
            return .mismatched("conflicting nested tokens and token containers")
        }
        let nested = tokensDict ?? tokenDict
        if let nested {
            recordHint(nested["plan_type"])
            recordHint(nested["chatgpt_plan_type"])
        }

        for metaKey in ["plan_type", "chatgpt_plan_type", "accountPlan", "plan"] {
            recordHint(metadata[metaKey])
        }

        // Verify flat vs nested consistency for dispatched token and identity fields.
        for tokenKey in ["access_token", "refresh_token", "id_token"] {
            if let flatVal = trimmedString(object[tokenKey]),
               let nestedVal = trimmedString(nested?[tokenKey]),
               flatVal != nestedVal {
                return .mismatched("flat and nested '\(tokenKey)' values do not match")
            }
        }
        for idKey in [
            "account_id", "chatgpt_account_id", "chatgpt_user_id", "user_id", "sub", "email",
            "aiusage_verified_account_id", "aiusage_verified_user_id", "aiusage_verified_access_token_sha256"
        ] {
            if let flatVal = normalizedIdentityString(object[idKey]),
               let nestedVal = normalizedIdentityString(nested?[idKey]),
               flatVal != nestedVal {
                return .mismatched("flat and nested '\(idKey)' values do not match")
            }
        }

        guard let accessToken = trimmedString(object["access_token"]) ?? trimmedString(nested?["access_token"]),
              let refreshToken = trimmedString(object["refresh_token"]) ?? trimmedString(nested?["refresh_token"]),
              !accessToken.isEmpty,
              !refreshToken.isEmpty else {
            return .missing
        }

        // The dispatched access_token must be an ES256 JWS cryptographically signed by a trusted issuer key.
        guard let accessJWS = CLIProxyAccountIdentity.verifyAuthenticatedJWS(accessToken, trustedKeys: trustedKeys) else {
            return .missing
        }
        let accessPrincipal = extractTokenPrincipal(from: accessJWS.claims)
        if accessPrincipal.hasInternalConflict {
            return .mismatched("dispatched access_token has conflicting internal principal claims")
        }
        guard let principalAccountId = accessPrincipal.accountId,
              let principalUserId = accessPrincipal.userId else {
            return .missing
        }

        // Expiry (exp) and issued-at (iat) are mandatory; never admit undated tokens.
        guard let accessExp = accessPrincipal.expiresAt,
              let accessIat = accessPrincipal.issuedAt else {
            return .missing
        }
        guard accessIat < accessExp else {
            return .mismatched("dispatched access_token has invalid iat/exp bounds")
        }
        let nowEpoch = now.timeIntervalSince1970
        if accessExp <= nowEpoch {
            return .stale("dispatched access_token is expired")
        }
        if accessIat > nowEpoch + 60 {
            return .stale("dispatched access_token issued-at timestamp is not yet valid")
        }
        if let nbf = accessPrincipal.notBefore, nbf > nowEpoch + 60 {
            return .stale("dispatched access_token is not yet valid")
        }

        var verifiedTokenPlans = extractTokenPlans(from: accessJWS.claims)
        var principalEmail = accessPrincipal.email

        if let rawIdToken = trimmedString(object["id_token"]) ?? trimmedString(nested?["id_token"]) {
            guard let idJWS = CLIProxyAccountIdentity.verifyAuthenticatedJWS(rawIdToken, trustedKeys: trustedKeys) else {
                return .missing
            }
            let idPrincipal = extractTokenPrincipal(from: idJWS.claims)
            if idPrincipal.hasInternalConflict {
                return .mismatched("id_token has conflicting internal principal claims")
            }
            guard let idAccountId = idPrincipal.accountId,
                  let idUserId = idPrincipal.userId else {
                return .mismatched("id_token is missing account or user principal binding")
            }
            guard idAccountId == principalAccountId, idUserId == principalUserId else {
                return .mismatched("id_token principal (\(idAccountId)/\(idUserId)) does not match dispatched access_token principal (\(principalAccountId)/\(principalUserId))")
            }
            if let accessEmail = principalEmail, let idEmail = idPrincipal.email, accessEmail != idEmail {
                return .mismatched("id_token email does not match dispatched access_token email")
            }
            principalEmail = principalEmail ?? idPrincipal.email

            guard let idExp = idPrincipal.expiresAt,
                  let idIat = idPrincipal.issuedAt else {
                return .missing
            }
            guard idIat < idExp else {
                return .mismatched("id_token has invalid iat/exp bounds")
            }
            if idExp <= nowEpoch {
                return .stale("id_token plan assertion is expired")
            }
            if idIat > nowEpoch + 60 {
                return .stale("id_token issued-at timestamp is not yet valid")
            }
            if let nbf = idPrincipal.notBefore, nbf > nowEpoch + 60 {
                return .stale("id_token plan assertion is not yet valid")
            }
            let idPlans = extractTokenPlans(from: idJWS.claims)
            if verifiedTokenPlans.isEmpty,
               !idPlans.isEmpty,
               idIat + 60 < accessIat {
                return .stale("id_token plan assertion is older than rotated access_token")
            }
            verifiedTokenPlans.formUnion(idPlans)
        }

        // Enforce post-refresh principal and token-rotation binding against stamped admission markers.
        let stampedAccountIDs = [
            object["aiusage_verified_account_id"],
            nested?["aiusage_verified_account_id"]
        ].compactMap(normalizedIdentityString)
        if stampedAccountIDs.contains(where: { $0 != principalAccountId }) {
            return .mismatched("Codex credential account_id changed after verification/refresh")
        }
        let stampedUserIDs = [
            object["aiusage_verified_user_id"],
            nested?["aiusage_verified_user_id"]
        ].compactMap(normalizedIdentityString)
        if stampedUserIDs.contains(where: { $0 != principalUserId }) {
            return .mismatched("Codex credential user_id changed after verification/refresh")
        }
        let stampedAccessHashes = [
            object["aiusage_verified_access_token_sha256"],
            nested?["aiusage_verified_access_token_sha256"]
        ].compactMap(normalizedIdentityString)
        if !stampedAccessHashes.isEmpty {
            let currentHash = sha256Hex(accessToken)
            if stampedAccessHashes.contains(where: { $0 != currentHash }) {
                return .stale("dispatched access_token rotated since last verified plan proof")
            }
        }

        // Verify explicit JSON & metadata identity fields match the token principal.
        let explicitAccountCandidates = [
            object["account_id"], object["chatgpt_account_id"],
            nested?["account_id"], nested?["chatgpt_account_id"],
            metadata["accountId"], metadata["workspaceId"]
        ].compactMap(normalizedIdentityString)
        if explicitAccountCandidates.contains(where: { $0 != principalAccountId }) {
            return .mismatched("credential or metadata account_id does not match token principal")
        }

        let explicitUserCandidates = [
            object["chatgpt_user_id"], object["user_id"], object["sub"],
            nested?["chatgpt_user_id"], nested?["user_id"], nested?["sub"],
            metadata["userId"], metadata["workspaceUserId"]
        ].compactMap(normalizedIdentityString)
        if explicitUserCandidates.contains(where: { $0 != principalUserId }) {
            return .mismatched("credential or metadata user_id does not match token principal")
        }

        let explicitEmailCandidates = [
            object["email"], nested?["email"], metadata["accountEmail"]
        ].compactMap(normalizedIdentityString).filter { $0.contains("@") }
        if let principalEmail, explicitEmailCandidates.contains(where: { $0 != principalEmail }) {
            return .mismatched("credential or metadata email does not match token principal")
        }
        if Set(explicitEmailCandidates).count > 1 {
            return .mismatched("conflicting email values across credential and metadata")
        }

        let combinedPlans = verifiedTokenPlans.union(hintPlans)
        if combinedPlans.count > 1 {
            return .conflicting(combinedPlans.sorted())
        }
        // Hints (metadata or bare JSON plan_type) never qualify without token-bound proof.
        guard !verifiedTokenPlans.isEmpty, let plan = verifiedTokenPlans.first else {
            return .missing
        }
        guard allowedPlans.contains(plan) else {
            return .disallowed(plan)
        }
        return .verified(plan)
    }

    static func codexPlanVerification(
        fromAuthData data: Data,
        metadata: [String: String] = [:],
        allowedPlans: Set<String> = allowedCodexPlanTypes,
        trustedKeys: [CLIProxyTrustedJWSKey] = defaultTrustedCodexIssuerKeys,
        now: Date = Date()
    ) -> CodexPlanVerification {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .missing
        }
        return codexPlanVerification(
            fromJSONObject: object,
            metadata: metadata,
            allowedPlans: allowedPlans,
            trustedKeys: trustedKeys,
            now: now
        )
    }

    static func verifiedCodexPlanType(
        fromAuthData data: Data,
        metadata: [String: String] = [:],
        allowedPlans: Set<String> = allowedCodexPlanTypes,
        trustedKeys: [CLIProxyTrustedJWSKey] = defaultTrustedCodexIssuerKeys,
        now: Date = Date()
    ) -> String? {
        codexPlanVerification(
            fromAuthData: data,
            metadata: metadata,
            allowedPlans: allowedPlans,
            trustedKeys: trustedKeys,
            now: now
        ).verifiedPlan
    }

    static func codexPlanRejectionReason(
        fromAuthData data: Data,
        metadata: [String: String] = [:],
        allowedPlans: Set<String> = allowedCodexPlanTypes,
        trustedKeys: [CLIProxyTrustedJWSKey] = defaultTrustedCodexIssuerKeys,
        now: Date = Date()
    ) -> String? {
        codexPlanVerification(
            fromAuthData: data,
            metadata: metadata,
            allowedPlans: allowedPlans,
            trustedKeys: trustedKeys,
            now: now
        ).rejectionReason
    }
}

/// A provider the user monitors in AIUsage that cannot be credential-copied,
/// but has a legitimate CPA path (independent OAuth or an official plugin).
nonisolated struct CLIProxyUpstreamAuthHint: Identifiable, Equatable, Sendable {
    let providerId: String
    let capability: CLIProxyUpstreamCapability
    let accountCount: Int

    var id: String { providerId }
}
