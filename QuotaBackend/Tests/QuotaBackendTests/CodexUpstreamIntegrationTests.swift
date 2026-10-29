import XCTest
@testable import QuotaBackend

/// Reset-card reads must use the private credential policy, not upstream's older token selection.
final class CodexUpstreamIntegrationTests: XCTestCase {
    private var directory: URL!
    private let identity = CodexAccountIdentity(accountId: "integration-workspace", userId: "member-a")
    private let endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private let oauth = "https://auth.openai.com/oauth/token"
    private let list = #"{"available_count":1,"credits":[{"id":"chosen","reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CodexLinkedCredentialCopies.resetForTesting()
        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        CodexLinkedCredentialCopies.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
    }

    private func token(_ name: String, issuedAt: Int, user: String = "member-a") throws -> String {
        let payload: [String: Any] = [
            "jti": name, "iat": issuedAt, "exp": Int(Date().timeIntervalSince1970) + 864_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "integration-workspace", "chatgpt_user_id": user]
        ]
        return try jwt(payload)
    }

    private func jwt(_ payload: [String: Any]) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).fixture"
    }

    private func write(_ name: String, access: String, refresh: String? = nil, nested: [String: Any]? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var json: [String: Any] = ["access_token": access, "last_refresh": SharedFormatters.iso8601String(from: Date())]
        if let refresh { json["refresh_token"] = refresh }
        if let nested { json["tokens"] = nested }
        try JSONSerialization.data(withJSONObject: json, options: .sortedKeys).write(to: url)
        return url
    }

    private func credential(_ url: URL, source: URL? = nil) -> AccountCredential {
        var metadata = ["accountId": "integration-workspace", "workspaceUserId": "member-a"]
        if let source { metadata["sourcePath"] = source.path }
        return AccountCredential(providerId: "codex", authMethod: .authFile, credential: url.path, metadata: metadata)
    }

    func testResetListFallsBackToSameSecondAlternateAndHealsOnlyAfterSuccess() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let rejected = try token("flat-rejected", issuedAt: now)
        let accepted = try token("nested-winner", issuedAt: now)
        let own = try write("own.json", access: rejected, refresh: "flat-refresh",
                            nested: ["access_token": accepted, "refresh_token": "nested-refresh"])
        let before = try Data(contentsOf: own)
        StubURLProtocol.respond(endpoint, handler: { request in
            // A speculative candidate must not overwrite either chain before the GET validates it.
            XCTAssertEqual(try? Data(contentsOf: own), before)
            return request.headers["Authorization"] == "Bearer \(accepted)" ? (200, self.list) : (401, "{}")
        })
        let result = try await CodexProvider(homeDirectory: directory.path).fetchResetCredits(with: credential(own), identity: identity)
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.headers["Authorization"] }, ["Bearer \(rejected)", "Bearer \(accepted)"])
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(oauth))
        let healed = try CodexProvider(homeDirectory: directory.path).loadCredentials(from: own.path)
        XCTAssertEqual(healed.accessToken, accepted)
        XCTAssertEqual(healed.refreshToken, "nested-refresh")
    }

    func testConsumeAdoptsNewerSourceWithoutReplayingRotatedRefreshToken() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let stale = try token("old", issuedAt: now - 100)
        let fresh = try token("new", issuedAt: now)
        let own = try write("own.json", access: stale, refresh: "rotated-out")
        let source = try write("source.json", access: fresh, refresh: "current")
        StubURLProtocol.respond(endpoint, body: list)
        StubURLProtocol.respond(endpoint + "/consume", body: #"{"code":"reset","windows_reset":2}"#)
        let operations = CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("journal.json"),
                                                    provider: CodexProvider(homeDirectory: directory.path))
        let result = try await operations.consume(credential: credential(own, source: source), identity: identity, creditID: "chosen")
        XCTAssertEqual(result.code, .reset)
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["GET", "POST"])
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.headers["Authorization"] == "Bearer \(fresh)" })
        XCTAssertEqual(try CodexProvider(homeDirectory: directory.path).loadCredentials(from: own.path).refreshToken, "current")
    }

    func testFailedSourceReadNeverOverwritesManagedCopy() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let old = try token("own", issuedAt: now - 100)
        let sourceToken = try token("source", issuedAt: now)
        let own = try write("own.json", access: old)
        let source = try write("source.json", access: sourceToken)
        let before = try Data(contentsOf: own)
        StubURLProtocol.respond(endpoint, handler: { request in
            request.headers["Authorization"] == "Bearer \(old)" ? (401, "{}") : (500, "{}")
        })
        do {
            _ = try await CodexProvider(homeDirectory: directory.path).fetchResetCredits(with: credential(own, source: source), identity: identity)
            XCTFail("Failed recovery read must propagate")
        } catch { XCTAssertEqual((error as? ProviderError)?.code, "reset_list_failed") }
        XCTAssertEqual(try Data(contentsOf: own), before)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testResetRejectsInternalJWTIdentityConflictBeforeAnyRequest() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let own = try write("own.json", access: token("access", issuedAt: now))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        json["id_token"] = try token("id", issuedAt: now, user: "member-b")
        try JSONSerialization.data(withJSONObject: json).write(to: own)
        let provider = CodexProvider(homeDirectory: directory.path)
        let creds = try provider.loadCredentials(from: own.path)
        XCTAssertTrue(creds.hasInternalIdentityConflict)
        XCTAssertThrowsError(try provider.validateResetIdentity(creds, identity: identity))
        do {
            _ = try await provider.fetchResetCredits(with: credential(own), identity: identity)
            XCTFail("Conflicting identity must not read reset cards")
        } catch { XCTAssertEqual((error as? ProviderError)?.code, "account_mismatch") }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testResetCountsRejectBooleansFractionsAndNegativeValues() throws {
        let provider = CodexProvider(homeDirectory: directory.path)
        for raw in ["true", "false", "-1", "1.5", "null", "\"3\""] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\"rate_limit_reset_credits\":{\"available_count\":\(raw)}}".utf8)) as? [String: Any])
            let usage = provider.parseResponse(json, accountId: "integration-workspace", source: SourceInfo(mode: "manual", type: "fixture"), fallbackEmail: nil)
            XCTAssertNil(usage.codexResetCreditsAvailableCount, raw)
        }
    }

    func testUsageStillTripsMonthlyCircuitBreakerWhileResetReadDoesNotChangeIt() async throws {
        let folder = "Library/Application Support/AIUsage/CLIProxyAPI/auth"
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(folder), withIntermediateDirectories: true)
        let own = try write(folder + "/aiusage-codex-fixture.json", access: token("monthly", issuedAt: Int(Date().timeIntervalSince1970)))
        let provider = CodexProvider(homeDirectory: directory.path)
        StubURLProtocol.respond(endpoint, body: list)
        let before = try Data(contentsOf: own)
        _ = try await provider.fetchResetCredits(with: credential(own), identity: identity)
        XCTAssertEqual(try Data(contentsOf: own), before, "Reset-card reads must not recover or trip the quota breaker")
        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage", body: #"{"plan_type":"self_serve_business_usage_based","spend_control":{"individual_limit":{"limit":"1000","used":"980","used_percent":98}}}"#)
        let usage = try await provider.fetchUsage(with: credential(own))
        XCTAssertEqual(usage.extra["circuitBreakerTripped"]?.value as? Bool, true)
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        XCTAssertEqual(persisted["disabled"] as? Bool, true)
        XCTAssertEqual(persisted["circuit_breaker_tripped"] as? Bool, true)
        XCTAssertTrue((persisted["circuit_breaker_reason"] as? String)?.contains("Monthly") == true)
    }

    func testNativeUserAndLegacySubjectUseSeparateNamespacesInEitherDirection() throws {
        let native = try token("native", issuedAt: Int(Date().timeIntervalSince1970))
        let legacy = try jwt(["sub": "auth0-legacy"])
        for (access, id) in [(native, legacy), (legacy, native)] {
            let selected = CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]])
            XCTAssertEqual(selected.nativeKey, identity.nativeKey)
            let pair = CodexAccountIdentity.tokenPairIdentities(access, id)
            XCTAssertFalse(pair.access.conflicts(with: pair.id))
        }
        // External candidate identities still use subject fallback and strict conflict checks.
        XCTAssertEqual(CodexAccountIdentity.tokenIdentity(legacy).userId, "auth0-legacy")
        XCTAssertTrue(CodexAccountIdentity.tokenIdentity(native).conflicts(with: CodexAccountIdentity.tokenIdentity(legacy)))
    }

    func testExplicitNativeUserAndAccountMismatchesStillRejectTokenPair() throws {
        let native = try token("native", issuedAt: Int(Date().timeIntervalSince1970))
        let otherUser = try token("other-user", issuedAt: Int(Date().timeIntervalSince1970), user: "member-b")
        let otherAccount = try jwt(["sub": "auth0-legacy", "https://api.openai.com/auth": ["chatgpt_account_id": "different-workspace"]])
        for other in [otherUser, otherAccount] {
            for (access, id) in [(native, other), (other, native)] {
                let selected = CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]])
                XCTAssertNil(selected.nativeKey)
                let pair = CodexAccountIdentity.tokenPairIdentities(access, id)
                XCTAssertTrue(pair.access.conflicts(with: pair.id))
            }
        }
    }

    func testSameNativeIdentityIgnoresChangedEmailButUnknownUserKeepsEmailGuard() throws {
        let auth = ["chatgpt_account_id": "integration-workspace", "chatgpt_user_id": "member-a"]
        let access = try jwt(["email": "old@example.invalid", "https://api.openai.com/auth": auth])
        let id = try jwt(["email": "new@example.invalid", "https://api.openai.com/auth": auth])
        XCTAssertEqual(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]]).nativeKey, identity.nativeKey)
        XCTAssertTrue(CodexAccountIdentity.tokenIdentity(access).matches(CodexAccountIdentity.tokenIdentity(id)))
        let legacy = try jwt(["sub": "legacy", "email": "new@example.invalid"])
        let pair = CodexAccountIdentity.tokenPairIdentities(access, legacy)
        XCTAssertTrue(pair.access.conflicts(with: pair.id), "Without two native IDs, different emails must still fail closed")
        XCTAssertNil(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": legacy]]).nativeKey)
    }

    func testPureSubjectFallbackMismatchStillRejectsAndMatchingSubjectIsLastResort() throws {
        let access = try jwt(["sub": "legacy-a", "email": "same@example.invalid"])
        let id = try jwt(["sub": "legacy-b", "email": "same@example.invalid"])
        let pair = CodexAccountIdentity.tokenPairIdentities(access, id)
        XCTAssertTrue(pair.access.conflicts(with: pair.id))
        XCTAssertNil(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]]).userId)
        XCTAssertEqual(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": access]]).userId, "legacy-a")
        let own = try write("fallback-subjects.json", access: access)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        json["id_token"] = id
        try JSONSerialization.data(withJSONObject: json).write(to: own)
        XCTAssertTrue(try CodexProvider(homeDirectory: directory.path).loadCredentials(from: own.path).hasInternalIdentityConflict)
    }

    func testResetAndAutomaticUsageAcceptNativeAccessWithLegacyIDSubject() async throws {
        let own = try write("own.json", access: token("native", issuedAt: Int(Date().timeIntervalSince1970)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        json["id_token"] = try jwt(["sub": "auth0-legacy"])
        try JSONSerialization.data(withJSONObject: json).write(to: own)
        let provider = CodexProvider(homeDirectory: directory.path)
        let creds = try provider.loadCredentials(from: own.path)
        XCTAssertFalse(creds.hasInternalIdentityConflict)
        XCTAssertEqual(creds.jwtUserId, "member-a")
        StubURLProtocol.respond(endpoint, body: list)
        _ = try await provider.fetchResetCredits(with: credential(own), identity: identity)
        let authFolder = directory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: authFolder, withIntermediateDirectories: true)
        try Data(contentsOf: own).write(to: authFolder.appendingPathComponent("auth.json"))
        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage", body: #"{"plan_type":"plus"}"#)
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.extra["userId"]?.value as? String, "member-a")
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(oauth))
    }

    func testOAuthPairNamespaceFixRetainsCrossAccountAndNativeUserGuards() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let provider = CodexProvider(homeDirectory: directory.path)
        let valid = try token("new", issuedAt: now)
        let legacy = try jwt(["sub": "auth0-legacy"])
        let otherAccount = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "other-workspace", "chatgpt_user_id": "member-a"]])
        let otherUser = try token("other", issuedAt: now, user: "member-b")
        for (index, responseTokens) in [(valid, legacy), (otherAccount, legacy), (otherUser, legacy),
                                         (valid, otherUser), (valid, otherAccount)].enumerated() {
            let own = try write("refresh-\(index).json", access: token("old-\(index)", issuedAt: now - 100), refresh: "old-refresh")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
            json["last_refresh"] = "2020-01-01T00:00:00Z"
            json["id_token"] = legacy
            try JSONSerialization.data(withJSONObject: json).write(to: own)
            let before = try Data(contentsOf: own)
            let response = try JSONSerialization.data(withJSONObject: ["access_token": responseTokens.0, "id_token": responseTokens.1, "refresh_token": "new-refresh"])
            StubURLProtocol.respond(oauth, body: String(decoding: response, as: UTF8.self))
            let creds = try provider.loadCredentials(from: own.path)
            do {
                let refreshed = try await provider.performSerializedRefresh(creds, fallbackRefreshToken: "old-refresh", persistTo: [own.path])
                XCTAssertEqual(index, 0, "Cross-account/member refresh must not succeed")
                XCTAssertEqual(refreshed.jwtUserId, "member-a")
                XCTAssertEqual(try provider.loadCredentials(from: own.path).accessToken, valid)
            } catch {
                XCTAssertNotEqual(index, 0, "Native access plus legacy ID subject must refresh successfully")
                XCTAssertEqual((error as? ProviderError)?.code, "account_mismatch")
                XCTAssertEqual(try Data(contentsOf: own), before)
            }
        }
    }
}
