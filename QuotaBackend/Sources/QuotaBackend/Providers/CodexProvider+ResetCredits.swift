import Foundation

extension CodexProvider {
    static let resetCreditsURL = URL(string: "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")!

    public func fetchResetCredits(with credential: AccountCredential, identity: CodexAccountIdentity) async throws -> CodexResetCredits {
        try await resetCreditsContext(with: credential, identity: identity).list
    }

    func resetCreditsContext(with credential: AccountCredential, identity: CodexAccountIdentity) async throws -> (creds: Credentials, list: CodexResetCredits) {
        guard credential.providerId == "codex", credential.authMethod == .authFile, identity.nativeKey != nil else {
            throw ProviderError("reset_read_only", "A local Codex OAuth account is required.")
        }
        return try await withCredential(credential) { creds, _ in
            try validateResetIdentity(creds, identity: identity)
            let request = resetRequest(creds: creds, url: Self.resetCreditsURL)
            let (data, response) = try await QuotaHTTP.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ProviderError("reset_list_failed", "Unable to read reset cards.") }
            if [401, 403].contains(http.statusCode) { throw ProviderError("unauthorized", "Codex authentication is required.") }
            guard (200..<300).contains(http.statusCode),
                  let list = try? JSONDecoder().decode(CodexResetCredits.self, from: data), list.availableCount >= 0 else {
                throw ProviderError("reset_list_failed", "Unable to read reset cards.")
            }
            return (creds, list)
        }
    }

    func validateResetIdentity(_ creds: Credentials, identity: CodexAccountIdentity) throws {
        guard !creds.isApiKeyMode, let key = identity.nativeKey,
              CodexAccountIdentity(accountId: creds.accountId, userId: creds.jwtUserId).nativeKey == key else {
            throw ProviderError("account_mismatch", "The selected Codex account changed. Reconnect this account.")
        }
    }

    func resetRequest(creds: Credentials, url: URL) -> URLRequest {
        var request = QuotaHTTP.request(url: url, timeout: timeoutSeconds)
        request.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(creds.accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }
    func submitResetCredit(creds: Credentials, creditID: String, requestID: UUID) async throws -> CodexResetConsumeOutcome {
        var request = resetRequest(creds: creds, url: Self.resetCreditsURL.appendingPathComponent("consume"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(ConsumeBody(credit_id: creditID, redeem_request_id: requestID))
        do {
            let (data, response) = try await QuotaHTTP.data(for: request, allowRedirects: false)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let outcome = try? JSONDecoder().decode(CodexResetConsumeOutcome.self, from: data) else {
                throw ProviderError("reset_ambiguous", "Reset submission outcome is unknown. Refresh this account to verify.")
            }
            return outcome
        } catch {
            // 不回显服务端正文、URL 或底层错误；不做认证重放、换地址或换卡重试。
            throw ProviderError("reset_ambiguous", "Reset submission outcome is unknown. Refresh this account to verify.")
        }
    }

    private struct ConsumeBody: Encodable {
        let credit_id: String
        let redeem_request_id: UUID
    }

}
