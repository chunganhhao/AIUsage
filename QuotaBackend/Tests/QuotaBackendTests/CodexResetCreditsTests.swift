import XCTest
@testable import QuotaBackend

final class CodexResetCreditsTests: XCTestCase {
    private let endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private var directory: URL!
    private let identity = CodexAccountIdentity(accountId: "workspace-fixture", userId: "user-fixture")

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        try? FileManager.default.removeItem(at: directory)
    }

    private func credential(user: String = "user-fixture") throws -> AccountCredential {
        let claims: [String: Any] = ["https://api.openai.com/auth": ["chatgpt_user_id": user, "chatgpt_account_id": "workspace-fixture"]]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let path = directory.appendingPathComponent("\(user).json")
        try JSONSerialization.data(withJSONObject: ["last_refresh": SharedFormatters.iso8601String(from: Date()),
            "tokens": ["account_id": "workspace-fixture", "access_token": "fixture-access", "id_token": "e30.\(payload).fixture"]]).write(to: path)
        return AccountCredential(providerId: "codex", authMethod: .authFile, credential: path.path,
                                 metadata: ["accountId": "workspace-fixture", "workspaceUserId": user])
    }

    private func list(_ cards: String, count: Int = 8) -> String {
        "{\"available_count\":\(count),\"credits\":[\(cards)]}"
    }
    private func card(_ id: String = "chosen", expiry: String = "\"2099-01-02T03:04:05Z\"", status: String = "available", type: String = "codex_rate_limits") -> String {
        "{\"id\":\"\(id)\",\"reset_type\":\"\(type)\",\"status\":\"\(status)\",\"granted_at\":\"2026-01-01T00:00:00Z\",\"expires_at\":\(expiry)}"
    }

    func testDetailUsesSelectedOAuthAndServerTotal() async throws {
        StubURLProtocol.respond(endpoint, body: list([card("unlimited", expiry: "null"), card("soon")].joined(separator: ",")))
        let result = try await CodexProvider(homeDirectory: directory.path).fetchResetCredits(with: credential(), identity: identity)
        XCTAssertEqual(result.availableCount, 8)
        XCTAssertEqual(result.sortedCredits.map(\.id), ["soon", "unlimited"])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.headers["Authorization"], "Bearer fixture-access")
        XCTAssertEqual(request.headers.first { $0.key.lowercased() == "chatgpt-account-id" }?.value, "workspace-fixture")
        XCTAssertEqual(request.headers["Cache-Control"], "no-cache, no-store, max-age=0")
        XCTAssertEqual(request.headers["User-Agent"], "codex-cli")
    }
    func testConsumeValidatesLatestCardAndPostsExplicitIDs() async throws {
        StubURLProtocol.respond(endpoint, body: list(card()))
        StubURLProtocol.respond(endpoint + "/consume", body: "{\"code\":\"reset\",\"windows_reset\":2}")
        let operations = CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("pending.json"))
        let outcome = try await operations.consume(credential: credential(), identity: identity, creditID: "chosen")
        XCTAssertEqual(outcome.code, .reset)
        XCTAssertEqual(outcome.windowsReset, 2)
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["GET", "POST"])
        let body = try XCTUnwrap(StubURLProtocol.requests.last?.jsonBody)
        XCTAssertEqual(body["credit_id"] as? String, "chosen")
        XCTAssertNotNil((body["redeem_request_id"] as? String).flatMap(UUID.init(uuidString:)))
    }

    func testInvalidExpiredMissingUnknownOrChangedAccountNeverPosts() async throws {
        let own = try credential()
        let wrong = try credential(user: "other")
        let operations = CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("pending.json"))
        for payload in [card(expiry: "\"bad\""), card(expiry: "\"2000-01-01T00:00:00Z\""),
                        card(status: "redeeming"), card(type: "future_type"), card(status: "future_state"), ""] {
            StubURLProtocol.respond(endpoint, body: list(payload))
            do {
                _ = try await operations.consume(credential: own, identity: identity, creditID: "chosen")
                XCTFail("Invalid card must not be submitted")
            } catch {}
        }
        do {
            _ = try await operations.consume(credential: wrong, identity: identity, creditID: "chosen")
            XCTFail("Different user must be rejected")
        } catch {}
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.method == "POST" })
        let missingExpiry = card().replacingOccurrences(of: ",\"expires_at\":\"2099-01-02T03:04:05Z\"", with: "")
        let decoded = try JSONDecoder().decode(CodexResetCredit.self, from: Data(missingExpiry.utf8))
        XCTAssertFalse(decoded.hasExplicitUnlimitedExpiry)
        XCTAssertFalse(decoded.canConsume(at: Date()))
    }

    func testAmbiguousRetryAfterRestartReusesIDAndNeverRetriesPOSTAutomatically() async throws {
        let own = try credential()
        let journal = directory.appendingPathComponent("pending.json")
        StubURLProtocol.respond(endpoint, body: list(card()))
        // 不可信错误正文不得出现在错误中。
        StubURLProtocol.respond(endpoint + "/consume", status: 401, body: "secret-fixture")
        let first = CodexResetCreditsOperations(journalURL: journal)
        do {
            _ = try await first.consume(credential: own, identity: identity, creditID: "chosen")
            XCTFail("Outcome must be ambiguous")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.code, "reset_ambiguous")
            XCTAssertFalse(error.localizedDescription.contains("secret-fixture"))
        }
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.method == "POST" }.count, 1)
        let firstID = StubURLProtocol.requests.last?.jsonBody?["redeem_request_id"] as? String
        let restarted = CodexResetCreditsOperations(journalURL: journal)
        StubURLProtocol.respond(endpoint + "/consume", body: "{\"code\":\"already_redeemed\"}")
        let outcome = try await restarted.consume(credential: own, identity: identity, creditID: "chosen")
        XCTAssertEqual(outcome.code, .alreadyRedeemed)
        XCTAssertEqual(StubURLProtocol.requests.last?.jsonBody?["redeem_request_id"] as? String, firstID)
        XCTAssertFalse(String(decoding: try Data(contentsOf: journal), as: UTF8.self).contains("fixture-access"))
    }

    func testAllDefiniteOutcomesEndAttemptAndCancelledTaskMakesNoPOST() async throws {
        let own = try credential()
        let operations = CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("pending.json"))
        StubURLProtocol.respond(endpoint, body: list(card()))
        var ids: Set<String> = []
        for code in ["reset", "nothing_to_reset", "no_credit", "already_redeemed"] {
            StubURLProtocol.respond(endpoint + "/consume", body: "{\"code\":\"\(code)\"}")
            let outcome = try await operations.consume(credential: own, identity: identity, creditID: "chosen")
            XCTAssertEqual(outcome.code.rawValue, code)
            ids.insert(try XCTUnwrap(StubURLProtocol.requests.last?.jsonBody?["redeem_request_id"] as? String))
        }
        XCTAssertEqual(ids.count, 4)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await operations.consume(credential: own, identity: identity, creditID: "chosen")
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled confirmation must not submit") } catch {}
        XCTAssertEqual(StubURLProtocol.requests.filter { $0.method == "POST" }.count, 4)
    }

    func testInvalidExpiryNeverSortsAheadOfKnownExpiry() throws {
        let payload = list([card("unknown", expiry: "\"invalid\""), card("soon"), card("unlimited", expiry: "null")].joined(separator: ","))
        let decoded = try JSONDecoder().decode(CodexResetCredits.self, from: Data(payload.utf8))
        XCTAssertEqual(decoded.sortedCredits.map(\.id), ["soon", "unknown", "unlimited"])
    }

    func testConcurrentSameAccountDedupAndDifferentUserIsolation() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetGateProtocol.self]
        let session = URLSession(configuration: config)
        QuotaHTTP.sessionOverride = session
        defer { session.invalidateAndCancel(); ResetGateProtocol.clear() }
        let held = expectation(description: "A read suspended")
        let release = ResetGateProtocol.holdFirstGET { held.fulfill() }
        let operations = CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("pending.json"))
        let own = try credential()
        let other = try credential(user: "other")
        let first = Task { try await operations.consume(credential: own, identity: identity, creditID: "chosen") }
        await fulfillment(of: [held], timeout: 3)
        do {
            _ = try await operations.consume(credential: own, identity: identity, creditID: "chosen")
            XCTFail("Same account must be busy before await")
        } catch { XCTAssertEqual((error as? ProviderError)?.code, "reset_busy") }
        let second = try await operations.consume(credential: other,
            identity: CodexAccountIdentity(accountId: "workspace-fixture", userId: "other"), creditID: "chosen")
        XCTAssertEqual(second.code, .reset)
        release()
        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome.code, .reset)
        XCTAssertEqual(ResetGateProtocol.postCount, 2)
    }

    func testTimeoutKeepsPersistedRequestIDWithoutAutomaticPOSTRetry() async throws {
        let own = try credential()
        let journal = directory.appendingPathComponent("pending.json")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResetTimeoutProtocol.self]
        let session = URLSession(configuration: config)
        QuotaHTTP.sessionOverride = session
        ResetTimeoutProtocol.reset()
        defer { session.invalidateAndCancel() }
        let operations = CodexResetCreditsOperations(journalURL: journal)
        do {
            _ = try await operations.consume(credential: own, identity: identity, creditID: "chosen")
            XCTFail("Timeout is ambiguous")
        } catch { XCTAssertEqual((error as? ProviderError)?.code, "reset_ambiguous") }
        XCTAssertEqual(ResetTimeoutProtocol.postCount, 1)
        let saved = try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: journal))
        let pendingID = try XCTUnwrap(saved.values.first)
        StubURLProtocol.install(hosts: ["chatgpt.com"])
        StubURLProtocol.respond(endpoint, body: list(card()))
        StubURLProtocol.respond(endpoint + "/consume", body: "{\"code\":\"already_redeemed\"}")
        let restarted = CodexResetCreditsOperations(journalURL: journal)
        _ = try await restarted.consume(credential: own, identity: identity, creditID: "chosen")
        XCTAssertEqual(StubURLProtocol.requests.last?.jsonBody?["redeem_request_id"] as? String, pendingID.uuidString)
    }

}


private final class ResetGateProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var held: ResetGateProtocol?
    private static var onHold: (() -> Void)?
    private static var posts = 0
    static var postCount: Int { lock.withLock { posts } }
    static func holdFirstGET(_ callback: @escaping () -> Void) -> () -> Void {
        lock.withLock { onHold = callback; posts = 0 }
        return { let value = lock.withLock { () -> ResetGateProtocol? in defer { held = nil }; return held }; value?.reply() }
    }
    static func clear() { lock.withLock { held = nil; onHold = nil; posts = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let callback = Self.lock.withLock { () -> (() -> Void)? in
            if request.httpMethod == "POST" { Self.posts += 1 }
            if request.httpMethod != "POST", let callback = Self.onHold {
                Self.onHold = nil; Self.held = self; return callback
            }
            return nil
        }
        if let callback { callback() } else { reply() }
    }
    func reply() {
        let json = request.httpMethod == "POST" ? "{\"code\":\"reset\"}" : "{\"available_count\":1,\"credits\":[{\"id\":\"chosen\",\"reset_type\":\"codex_rate_limits\",\"status\":\"available\",\"expires_at\":null}]}"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(json.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}


private final class ResetTimeoutProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var posts = 0
    static var postCount: Int { lock.withLock { posts } }
    static func reset() { lock.withLock { posts = 0 } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" {
            Self.lock.withLock { Self.posts += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
        } else {
            let body = #"{"available_count":1,"credits":[{"id":"chosen","reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
