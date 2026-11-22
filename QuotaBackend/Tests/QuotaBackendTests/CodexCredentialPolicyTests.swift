import Foundation
import XCTest
@testable import QuotaBackend

final class CodexCredentialPolicyTests: XCTestCase {
    func testWorkspaceIdentityUsesAccountAndUserNotPlan() {
        XCTAssertTrue(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: "member-1",
            rhsAccountID: " WORKSPACE-1 ",
            rhsUserID: "MEMBER-1"
        ))
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: "member-1",
            rhsAccountID: "workspace-1",
            rhsUserID: "member-2"
        ))
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: "member-1",
            rhsAccountID: "workspace-2",
            rhsUserID: "member-1"
        ))
    }

    func testWorkspaceIdentityRequiresUserOnBothSides() {
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: nil,
            rhsAccountID: "workspace-1",
            rhsUserID: "member-1"
        ))
        XCTAssertFalse(CodexCredentialPolicy.belongsToSameWorkspace(
            lhsAccountID: "workspace-1",
            lhsUserID: nil,
            rhsAccountID: "workspace-1",
            rhsUserID: nil
        ))
    }

    func testRefreshFailureSeparatesRotationExpiryAndGenericInvalidGrant() {
        let reused = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"refresh token already used"}"#.utf8)
        )
        let expired = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"refresh token expired"}"#.utf8)
        )
        let rotated = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant","error_description":"refresh token has been rotated"}"#.utf8)
        )
        let invalid = CodexCredentialPolicy.refreshFailure(
            statusCode: 400,
            data: Data(#"{"error":"invalid_grant"}"#.utf8)
        )

        XCTAssertEqual(reused.code, "refresh_token_reused")
        XCTAssertEqual(rotated.code, "refresh_token_reused")
        XCTAssertEqual(expired.code, "refresh_token_expired")
        XCTAssertEqual(invalid.code, "refresh_token_invalid")
    }

    func testRefreshFailureSeparatesRateLimitAndServerFailure() {
        XCTAssertEqual(
            CodexCredentialPolicy.refreshFailure(statusCode: 429, data: Data()).code,
            "oauth_rate_limited"
        )
        XCTAssertEqual(
            CodexCredentialPolicy.refreshFailure(statusCode: 503, data: Data()).code,
            "oauth_server_error"
        )
    }

    func testRefreshTransportFailureSeparatesTimeoutAndOffline() {
        XCTAssertEqual(
            CodexCredentialPolicy.refreshTransportFailure(URLError(.timedOut)).code,
            "oauth_network_timeout"
        )
        XCTAssertEqual(
            CodexCredentialPolicy.refreshTransportFailure(URLError(.notConnectedToInternet)).code,
            "oauth_network_unavailable"
        )
    }

    func testFlushLiveAuthToManagedCopiesHealsOutgoingAndLinkedCPAPreservingForeignAndInvalid() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codex-flush-\(UUID().uuidString)")
        let cpaDir = dir.appendingPathComponent("cpa", isDirectory: true)
        try fm.createDirectory(at: cpaDir, withIntermediateDirectories: true)
        CodexLinkedCredentialCopies.resetForTesting()
        CodexLinkedCredentialCopies.registerDirectory(cpaDir)
        defer {
            CodexLinkedCredentialCopies.resetForTesting()
            try? fm.removeItem(at: dir)
        }

        func jwt(user: String, account: String, iat: Int) throws -> String {
            let payload: [String: Any] = [
                "iat": iat,
                "exp": iat + 86_400,
                "email": "\(user)@example.invalid",
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": account,
                    "chatgpt_user_id": user
                ]
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            let b64 = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "e30.\(b64).sig"
        }

        func nativeAuth(user: String, account: String, refresh: String, iat: Int, lastRefresh: String) throws -> Data {
            let tok = try jwt(user: user, account: account, iat: iat)
            return try JSONSerialization.data(withJSONObject: [
                "auth_mode": "chatgpt",
                "last_refresh": lastRefresh,
                "tokens": [
                    "account_id": account,
                    "access_token": tok,
                    "refresh_token": refresh,
                    "id_token": tok
                ]
            ], options: [.sortedKeys])
        }

        let now = Int(Date().timeIntervalSince1970)
        let outManagedURL = dir.appendingPathComponent("managed-out.json")
        let outCPAURL = cpaDir.appendingPathComponent("aiusage-codex-out.json")
        let inManagedURL = dir.appendingPathComponent("managed-in.json")
        let badBaselineURL = dir.appendingPathComponent("managed-bad.json")
        let liveAuthURL = dir.appendingPathComponent("auth.json")
        let liveBakURL = dir.appendingPathComponent("auth.json.bak")

        try nativeAuth(user: "user-out", account: "acct-out", refresh: "rt-out-stale", iat: now - 300, lastRefresh: "2026-11-12T00:00:00Z")
            .write(to: outManagedURL)
        let staleFlatTok = try jwt(user: "user-out", account: "acct-out", iat: now - 400)
        try JSONSerialization.data(withJSONObject: [
            "type": "codex",
            "email": "user-out@example.invalid",
            "aiusage_credential_id": "cred-out",
            "account_id": "acct-out",
            "access_token": staleFlatTok,
            "refresh_token": "rt-out-cpa-stale",
            "id_token": staleFlatTok,
            "expired": "2020-01-01T00:00:00Z",
            "last_refresh": "2026-11-11T00:00:00Z",
            "tokens": [
                "account_id": "acct-out",
                "access_token": staleFlatTok,
                "refresh_token": "rt-out-cpa-stale",
                "id_token": staleFlatTok
            ]
        ], options: [.sortedKeys]).write(to: outCPAURL)

        let inInitial = try nativeAuth(user: "user-in", account: "acct-in", refresh: "rt-in", iat: now - 10, lastRefresh: "2026-11-12T05:00:00Z")
        try inInitial.write(to: inManagedURL)

        // Conflicting baseline must remain untouched (fail-closed).
        let badFlat = try jwt(user: "user-out", account: "acct-out", iat: now - 500)
        let badNested = try jwt(user: "user-other", account: "acct-out", iat: now - 50)
        let badBytes = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "access_token": badFlat,
            "refresh_token": "rt-bad-flat",
            "id_token": badFlat,
            "account_id": "acct-out",
            "tokens": [
                "access_token": badNested,
                "refresh_token": "rt-bad-nested",
                "id_token": badNested,
                "account_id": "acct-out"
            ]
        ], options: [.sortedKeys])
        try badBytes.write(to: badBaselineURL)

        // Live auth.json has already been overwritten or holds incoming while .bak still holds freshest outgoing.
        try inInitial.write(to: liveAuthURL)
        try nativeAuth(user: "user-out", account: "acct-out", refresh: "rt-out-fresh", iat: now, lastRefresh: "2026-11-12T06:00:00Z")
            .write(to: liveBakURL)

        let outCred = AccountCredential(
            id: "cred-out",
            providerId: "codex",
            authMethod: .authFile,
            credential: outManagedURL.path,
            metadata: ["accountId": "acct-out", "workspaceUserId": "user-out"]
        )
        let inCred = AccountCredential(
            id: "cred-in",
            providerId: "codex",
            authMethod: .authFile,
            credential: inManagedURL.path,
            metadata: ["accountId": "acct-in", "workspaceUserId": "user-in"]
        )
        let badCred = AccountCredential(
            id: "cred-bad",
            providerId: "codex",
            authMethod: .authFile,
            credential: badBaselineURL.path,
            metadata: ["accountId": "acct-out", "workspaceUserId": "user-out"]
        )

        let written = CodexCredentialPolicy.flushLiveAuthToManagedCopies(
            candidatePaths: [liveAuthURL.path, liveBakURL.path],
            excludingIdentity: CodexAccountIdentity(credential: inCred),
            loadCredentials: { [outCred, inCred, badCred] },
            fm: fm
        )
        XCTAssertEqual(written, 2)

        let healedManaged = try JSONSerialization.jsonObject(with: Data(contentsOf: outManagedURL)) as! [String: Any]
        XCTAssertEqual((healedManaged["tokens"] as? [String: Any])?["refresh_token"] as? String, "rt-out-fresh")

        let healedCPA = try JSONSerialization.jsonObject(with: Data(contentsOf: outCPAURL)) as! [String: Any]
        XCTAssertEqual(healedCPA["type"] as? String, "codex")
        XCTAssertEqual(healedCPA["aiusage_credential_id"] as? String, "cred-out")
        XCTAssertEqual(healedCPA["refresh_token"] as? String, "rt-out-fresh")
        XCTAssertEqual((healedCPA["tokens"] as? [String: Any])?["refresh_token"] as? String, "rt-out-fresh")
        let expectedExpired = SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: Double(now + 86_400)))
        XCTAssertEqual(healedCPA["expired"] as? String, expectedExpired)
        XCTAssertFalse(try CodexProvider().loadCredentials(from: outCPAURL.path).needsRefresh)

        XCTAssertEqual(try Data(contentsOf: inManagedURL), inInitial)
        XCTAssertEqual(try Data(contentsOf: badBaselineURL), badBytes)
    }

    func testEphemeralTemporaryAuthPathRejectsLoginTempDirs() {
        let loginTemp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-codex-login-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("auth.json")
            .path
        XCTAssertTrue(AccountCredentialStore.isEphemeralTemporaryAuthPath(loginTemp))
        XCTAssertNil(AccountCredentialStore.persistentSourcePath(from: loginTemp))
        XCTAssertTrue(AccountCredentialStore.isEphemeralTemporaryAuthPath("/tmp/aiusage-codex-login-123/auth.json"))
        XCTAssertFalse(AccountCredentialStore.isEphemeralTemporaryAuthPath("~/.codex/auth.json"))
        XCTAssertEqual(AccountCredentialStore.persistentSourcePath(from: "~/.codex/auth.json"), "~/.codex/auth.json")
    }
}
