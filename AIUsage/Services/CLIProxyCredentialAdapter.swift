import Foundation

nonisolated enum CLIProxyCredentialAdapter {
    static let supportedProviderIDs: Set<String> = ["codex"]
    private static let legacyAdapterProviderIDs: Set<String> = ["codex", "antigravity", "gemini"]

    static func convert(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        metadata: [String: String],
        sourceData: Data,
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys
    ) throws -> Data {
        let normalizedProviderID = normalizedProviderID(providerId)
        guard legacyAdapterProviderIDs.contains(normalizedProviderID) else {
            throw CLIProxyGatewayError.unsupportedAccount("no verified adapter for \(providerId)")
        }
        let normalizedDisallowed = CLIProxyCapabilityMatrix.normalizedDisallowedProviderIDs(disallowedProviderIDs)
        if normalizedProviderID == "gemini" {
            guard !normalizedDisallowed.contains(normalizedProviderID) else {
                throw CLIProxyGatewayError.unsupportedAccount(
                    "\(normalizedProviderID) consumer OAuth credentials cannot be synced to CPA under current release policy."
                )
            }
            return try CLIProxyGeminiCredentialBridge.makeCPAPayload(
                sourceData: sourceData,
                credentialID: credentialId,
                accountLabel: accountLabel,
                metadata: metadata
            )
        }
        guard var object = try JSONSerialization.jsonObject(with: sourceData) as? [String: Any] else {
            throw CLIProxyGatewayError.invalidResponse("credential file is not a JSON object")
        }
        switch normalizedProviderID {
        case "codex":
            if let tokens = object["tokens"] as? [String: Any] {
                for key in ["id_token", "access_token", "refresh_token", "account_id"] {
                    if object[key] == nil, let value = tokens[key] { object[key] = value }
                }
            }
            object["type"] = "codex"
        case "antigravity":
            let reason = (object["circuit_breaker_reason"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if object["tos_suspended"] as? Bool == true
                || object["tos_violation"] as? Bool == true
                || object["disabled"] as? Bool == true
                || reason == "TOS_VIOLATION" {
                throw CLIProxyGatewayError.unsupportedAccount(
                    "Antigravity account is suspended or disabled and cannot be synced to CPA."
                )
            }
            object["type"] = "antigravity"
        default:
            throw CLIProxyGatewayError.unsupportedAccount("no verified adapter for \(providerId)")
        }

        guard !normalizedDisallowed.contains(normalizedProviderID) else {
            throw CLIProxyGatewayError.unsupportedAccount(
                "\(normalizedProviderID) consumer OAuth credentials cannot be synced to CPA under current release policy."
            )
        }

        if let overrideRejection = CLIProxyCapabilityMatrix.disallowedPerCredentialRetryOverrideReason(in: object) {
            throw CLIProxyGatewayError.unsupportedAccount(overrideRejection)
        }
        for key in ["request_retry", "request-retry", "disable_cooling", "disable-cooling"] {
            object.removeValue(forKey: key)
        }
        if var nestedMeta = object["metadata"] as? [String: Any] {
            for key in ["request_retry", "request-retry", "disable_cooling", "disable-cooling"] {
                nestedMeta.removeValue(forKey: key)
            }
            object["metadata"] = nestedMeta
        }

        if normalizedProviderID == "codex" && !allowedCodexPlans.isEmpty {
            let planVerification = CLIProxyCapabilityMatrix.codexPlanVerification(
                fromJSONObject: object,
                metadata: metadata,
                allowedPlans: allowedCodexPlans,
                trustedKeys: trustedCodexIssuerKeys
            )
            if let rejection = planVerification.rejectionReason {
                throw CLIProxyGatewayError.unsupportedAccount(rejection)
            }
            if let verifiedPlan = planVerification.verifiedPlan {
                object["chatgpt_plan_type"] = verifiedPlan
            }
        }

        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty,
              let refreshToken = object["refresh_token"] as? String, !refreshToken.isEmpty else {
            throw CLIProxyGatewayError.unsupportedAccount(
                "the auth file does not contain a reusable access/refresh token pair"
            )
        }
        object["email"] = object["email"] ?? metadata["accountEmail"] ?? accountLabel
        // 不写入系统备注；备注留给用户在账号详情里自行填写。
        if let note = object["note"] as? String {
            let normalized = note.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if normalized == "synced from aiusage" || normalized == "来自 aiusage 的同步副本" {
                object.removeValue(forKey: "note")
            }
        }
        object["aiusage_credential_id"] = credentialId
        if normalizedProviderID == "codex" {
            let unverifiedData = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            let identity = try CLIProxyAccountIdentity.parse(data: unverifiedData, providerHint: "codex")
            if !allowedCodexPlans.isEmpty {
                guard let accountID = identity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !accountID.isEmpty,
                      let userID = identity.userID?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !userID.isEmpty else {
                    throw CLIProxyGatewayError.unsupportedAccount(
                        "Codex credential is missing bound account/user identity markers."
                    )
                }
                object["aiusage_verified_account_id"] = accountID
                object["aiusage_verified_user_id"] = userID
                object["aiusage_verified_access_token_sha256"] = CLIProxyCapabilityMatrix.sha256Hex(accessToken)
            }
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    static func normalizedProviderID(_ providerID: String) -> String {
        switch providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "gemini-cli": return "gemini"
        case "google-antigravity": return "antigravity"
        default: return providerID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
    }
}
