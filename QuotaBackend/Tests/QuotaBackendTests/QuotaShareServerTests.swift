import XCTest
import Network
@testable import QuotaBackend

final class QuotaShareServerTests: XCTestCase {
    private let token = "aiu-test-token"

    // MARK: - Peer policy

    func testPeerPolicyAllowsLoopbackOnlyOnPlaintextAndPrivateCGNATWithTLS() {
        let loopbackAllowed = ["127.0.0.1", "::1", "::ffff:127.0.0.1"]
        let tlsOnlyRemote = ["100.67.230.7", "100.64.0.1", "100.127.255.254", "fd7a:115c:a1e0::1234", "::ffff:100.79.99.84",
                             "10.1.2.3", "172.16.0.9", "172.31.255.1", "192.168.1.20", "169.254.3.4", "fe80::1"]
        let rejected = ["8.8.8.8", "100.63.255.255", "100.128.0.1", "172.32.0.1", "11.0.0.1",
                        "2001:4860:4860::8888", "::ffff:8.8.8.8"]

        // Plaintext default allows loopback ONLY; shared CGNAT/VPN (100.64.0.0/10) and RFC1918 LAN require TLS.
        for raw in loopbackAllowed {
            XCTAssertTrue(QuotaShareServer.isAllowedPeer(NWEndpoint.Host(raw)), raw)
            XCTAssertTrue(QuotaShareServer.isAllowedPeer(NWEndpoint.Host(raw), allowPrivateLAN: true), raw)
        }
        for raw in tlsOnlyRemote {
            XCTAssertFalse(QuotaShareServer.isAllowedPeer(NWEndpoint.Host(raw)), raw)
            XCTAssertTrue(QuotaShareServer.isAllowedPeer(NWEndpoint.Host(raw), allowPrivateLAN: true), raw)
        }
        for raw in rejected {
            XCTAssertFalse(QuotaShareServer.isAllowedPeer(NWEndpoint.Host(raw)), raw)
            XCTAssertFalse(QuotaShareServer.isAllowedPeer(NWEndpoint.Host(raw), allowPrivateLAN: true), raw)
        }
    }

    // MARK: - Request parsing

    func testRequestHeadWaitsForCompleteHeaderAndParsesQuery() throws {
        XCTAssertNil(QuotaShareServer.RequestHead.parse(Data("GET /api/dashboard HTTP/1.1\r\nHost: x".utf8)))

        let raw = "get /api/dashboard?ids=codex,kimi HTTP/1.1\r\nHost: mini:4318\r\nAuthorization:  Bearer abc \r\n\r\n"
        let head = try XCTUnwrap(QuotaShareServer.RequestHead.parse(Data(raw.utf8)))
        XCTAssertEqual(head.method, "GET")
        XCTAssertEqual(head.path, "/api/dashboard")
        XCTAssertEqual(head.query["ids"], "codex,kimi")
        XCTAssertEqual(head.headers["authorization"], "Bearer abc")
    }

    // MARK: - Routing (no network)

    func testDashboardRequiresBearerTokenAndPassesProviderFilter() throws {
        let recorder = IdsRecorder()
        let server = QuotaShareServer(port: 0, token: token) { ids in
            recorder.record(ids)
            return Data("{\"providers\":[]}".utf8)
        }

        let missing = server.response(for: head("GET", "/api/dashboard", headers: [:]))
        XCTAssertEqual(missing.status, 401)

        let wrong = server.response(for: head("GET", "/api/dashboard", headers: ["authorization": "Bearer nope"]))
        XCTAssertEqual(wrong.status, 401)

        let wrongScheme = server.response(for: head("GET", "/api/dashboard", headers: ["authorization": token]))
        XCTAssertEqual(wrongScheme.status, 401)
        XCTAssertTrue(recorder.calls.isEmpty, "unauthorized requests must not read the snapshot")

        let ok = server.response(for: head(
            "GET", "/api/dashboard",
            query: ["ids": "codex, kimi,,"],
            headers: ["authorization": "bearer \(token)"]
        ))
        XCTAssertEqual(ok.status, 200)
        XCTAssertEqual(String(data: ok.body, encoding: .utf8), "{\"providers\":[]}")
        XCTAssertEqual(recorder.calls, [["codex", "kimi"]])

        _ = server.response(for: head("GET", "/api/dashboard", headers: ["authorization": "Bearer \(token)"]))
        XCTAssertEqual(recorder.calls.last, .some(nil))
    }

    func testDashboardReportsLoadingHostAndUnknownRoutes() {
        let server = QuotaShareServer(port: 0, token: token) { _ in nil }
        let auth = ["authorization": "Bearer \(token)"]

        XCTAssertEqual(server.response(for: head("GET", "/api/dashboard", headers: auth)).status, 503)
        XCTAssertEqual(server.response(for: head("POST", "/api/dashboard", headers: auth)).status, 405)
        XCTAssertEqual(server.response(for: head("GET", "/api/provider/codex", headers: auth)).status, 404)
        XCTAssertEqual(server.response(for: head("GET", "/v1/messages", headers: auth)).status, 404)
        XCTAssertEqual(server.response(for: head("GET", "/health", headers: [:])).status, 200)
    }

    func testConstantTimeEqualsRejectsEmptyAndLengthMismatch() {
        XCTAssertTrue(QuotaShareServer.constantTimeEquals(Array("abc".utf8), Array("abc".utf8)))
        XCTAssertFalse(QuotaShareServer.constantTimeEquals(Array("abd".utf8), Array("abc".utf8)))
        XCTAssertFalse(QuotaShareServer.constantTimeEquals(Array("ab".utf8), Array("abc".utf8)))
        XCTAssertFalse(QuotaShareServer.constantTimeEquals([], []))
    }

    // MARK: - Live listener

    func testLiveListenerServesSnapshotOverHTTP() async throws {
        let server = QuotaShareServer(port: 0, token: token) { _ in
            Data("{\"generatedAt\":\"now\",\"providers\":[]}".utf8)
        }
        let running = expectation(description: "listener ready")
        let stateBox = StateBox()
        server.start { state in
            stateBox.append(state)
            if case .running = state { running.fulfill() }
        }
        await fulfillment(of: [running], timeout: 5)
        defer { server.stop() }
        let port = try XCTUnwrap(server.boundPort)

        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)

        let health = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((health.1 as? HTTPURLResponse)?.statusCode, 200)

        let dashboardURL = URL(string: "http://127.0.0.1:\(port)/api/dashboard?ids=codex")!
        let unauthorized = try await session.data(from: dashboardURL)
        XCTAssertEqual((unauthorized.1 as? HTTPURLResponse)?.statusCode, 401)

        var request = URLRequest(url: dashboardURL)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let authorized = try await session.data(for: request)
        XCTAssertEqual((authorized.1 as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: authorized.0, encoding: .utf8), "{\"generatedAt\":\"now\",\"providers\":[]}")
    }

    func testSecondListenerOnSamePortReportsPortInUse() async throws {
        let first = QuotaShareServer(port: 0, token: token) { _ in nil }
        let firstRunning = expectation(description: "first ready")
        first.start { state in
            if case .running = state { firstRunning.fulfill() }
        }
        await fulfillment(of: [firstRunning], timeout: 5)
        defer { first.stop() }
        let port = try XCTUnwrap(first.boundPort)

        let second = QuotaShareServer(port: port, token: token) { _ in nil }
        let secondFailed = expectation(description: "second failed")
        let failure = StateBox()
        second.start { state in
            if case .failed = state {
                failure.append(state)
                secondFailed.fulfill()
            }
        }
        await fulfillment(of: [secondFailed], timeout: 5)
        second.stop()
        guard case .failed(_, let portInUse)? = failure.states.first else {
            return XCTFail("expected a failed state")
        }
        XCTAssertTrue(portInUse)
    }

    // MARK: - Helpers

    private func head(
        _ method: String,
        _ path: String,
        query: [String: String] = [:],
        headers: [String: String]
    ) -> QuotaShareServer.RequestHead {
        QuotaShareServer.RequestHead(method: method, path: path, query: query, headers: headers)
    }
}

private final class IdsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]?] = []
    var calls: [[String]?] { lock.withLock { storage } }
    func record(_ ids: [String]?) { lock.withLock { storage.append(ids) } }
}

private final class StateBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [QuotaShareServer.State] = []
    var states: [QuotaShareServer.State] { lock.withLock { storage } }
    func append(_ state: QuotaShareServer.State) { lock.withLock { storage.append(state) } }
}
