import Foundation
import XCTest
@testable import QuotaBackend

/// 订阅监控的托管副本和复制给 CPA 的副本共用一条只能用一次的 refresh_token 链。
/// 这里只用虚拟 JWT、临时目录和 StubURLProtocol，不触碰真实账号。
final class CodexLinkedCredentialCopiesTests: XCTestCase {
    private static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    private static let oauthURL = "https://auth.openai.com/oauth/token"
    private let credentialId = "CRED-1"
    private let day: TimeInterval = 86_400
    private var directory: URL!
    private var cpaDirectory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("codex-linked-\(UUID().uuidString)")
        cpaDirectory = directory.appendingPathComponent("cpa-auth", isDirectory: true)
        try FileManager.default.createDirectory(at: cpaDirectory, withIntermediateDirectories: true)
        CodexLinkedCredentialCopies.resetForTesting()
        CodexLinkedCredentialCopies.registerDirectory(cpaDirectory)
        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
        StubURLProtocol.respond(Self.usageURL, body: #"{"plan_type":"team"}"#)
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        CodexLinkedCredentialCopies.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Fixtures

    private func jwt(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "e30.\(data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")).test"
    }

    private func claims(user: String) -> [String: Any] {
        ["chatgpt_account_id": "business-1", "chatgpt_user_id": user, "chatgpt_plan_type": "team"]
    }

    private func accessToken(_ name: String, issuedDaysAgo: Double, user: String = "member-a") throws -> String {
        let iat = (Date().timeIntervalSince1970 - issuedDaysAgo * day).rounded()
        return try jwt(["jti": name, "iat": iat, "exp": iat + 10 * day, "https://api.openai.com/auth": claims(user: user)])
    }

    private func idToken(user: String = "member-a") throws -> String {
        try jwt(["email": "\(user)@example.invalid", "https://api.openai.com/auth": claims(user: user)])
    }

    private func iso(daysAgo: Double) -> String {
        SharedFormatters.iso8601String(from: Date().addingTimeInterval(-daysAgo * day))
    }

    /// 订阅监控的托管副本（Codex 原生格式）。
    private func writeOwnCopy(access: String, refresh: String, refreshedDaysAgo: Double) throws -> URL {
        let url = directory.appendingPathComponent("own.json")
        try JSONSerialization.data(withJSONObject: [
            "OPENAI_API_KEY": NSNull(),
            "auth_mode": "chatgpt",
            "last_refresh": iso(daysAgo: refreshedDaysAgo),
            "tokens": ["account_id": "business-1", "access_token": access, "refresh_token": refresh,
                       "id_token": try idToken()]
        ]).write(to: url)
        return url
    }

    /// 复制给 CPA 的副本：顶层字段 + 复制时带过去的嵌套 tokens + 归属标记。
    @discardableResult
    private func writeCPACopy(
        flat: (access: String, refresh: String),
        nested: (access: String, refresh: String),
        owner: String = "CRED-1",
        user: String = "member-a",
        name: String = "aiusage-codex-test.json"
    ) throws -> URL {
        let url = cpaDirectory.appendingPathComponent(name)
        let exp = (try JSONSerialization.jsonObject(with: Data(base64URL: String(flat.access.split(separator: ".")[1]))!)
            as! [String: Any])["exp"] as! Double
        try JSONSerialization.data(withJSONObject: [
            "type": "codex",
            "email": "\(user)@example.invalid",
            "aiusage_credential_id": owner,
            "account_id": "business-1",
            "access_token": flat.access,
            "refresh_token": flat.refresh,
            "id_token": try idToken(user: user),
            "expired": SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: exp)),
            "last_refresh": iso(daysAgo: 0),
            "tokens": ["account_id": "business-1", "access_token": nested.access, "refresh_token": nested.refresh,
                       "id_token": try idToken(user: user)]
        ]).write(to: url)
        return url
    }

    private func credential(for url: URL) -> AccountCredential {
        AccountCredential(id: credentialId, providerId: "codex", authMethod: .authFile, credential: url.path,
                          metadata: ["accountId": "business-1", "workspaceUserId": "member-a"])
    }

    private func json(at url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    private func oauthResponse(access: String, refresh: String) throws -> (status: Int, body: String) {
        let body = try JSONSerialization.data(withJSONObject: [
            "access_token": access, "refresh_token": refresh, "id_token": try idToken()
        ])
        return (200, String(decoding: body, as: UTF8.self))
    }

    private var oauthRequests: [StubURLProtocol.RecordedRequest] {
        StubURLProtocol.requests.filter { $0.url == Self.oauthURL }
    }

    private var usageAuthorizations: [String?] {
        StubURLProtocol.requests.filter { $0.url == Self.usageURL }.map { $0.headers["Authorization"] }
    }

    // MARK: - Tests

    func testDiscoveryMatchesOwnershipMarkerOnly() throws {
        let rootMarker = cpaDirectory.appendingPathComponent("a.json")
        let nestedMarker = cpaDirectory.appendingPathComponent("b.json")
        try Data(#"{"aiusage_credential_id":"cred-1"}"#.utf8).write(to: rootMarker)
        try Data(#"{"tokens":{"aiusage_credential_id":"CRED-1"}}"#.utf8).write(to: nestedMarker)
        try Data(#"{"aiusage_credential_id":"cred-2"}"#.utf8).write(to: cpaDirectory.appendingPathComponent("c.json"))
        try Data(#"{"aiusage_credential_id":"cred-1"}"#.utf8).write(to: cpaDirectory.appendingPathComponent("d.txt"))

        XCTAssertEqual(CodexLinkedCredentialCopies.paths(forCredentialId: " cred-1 "), [rootMarker.path, nestedMarker.path])
        XCTAssertEqual(CodexLinkedCredentialCopies.paths(forCredentialId: ""), [])
    }

    /// CPA 已经轮换过 token（只改写顶层字段）：监控必须直接采用，不能再拿已作废的旧 refresh_token 去刷新。
    func testAdoptsNewerCPACopyInsteadOfReusingRotatedRefreshToken() async throws {
        let stale = try accessToken("A0", issuedDaysAgo: 9)
        let rotated = try accessToken("A1", issuedDaysAgo: 3)
        let own = try writeOwnCopy(access: stale, refresh: "R0", refreshedDaysAgo: 9)
        try writeCPACopy(flat: (rotated, "R1"), nested: (stale, "R0"))
        StubURLProtocol.respond(Self.oauthURL, status: 400, body: #"{"error":"refresh_token_reused"}"#)

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertTrue(oauthRequests.isEmpty, "A rotated-out refresh token must never be replayed")
        XCTAssertEqual(usageAuthorizations, ["Bearer \(rotated)"])
        let adopted = try CodexProvider().loadCredentials(from: own.path)
        XCTAssertEqual(adopted.accessToken, rotated)
        XCTAssertEqual(adopted.refreshToken, "R1")
        XCTAssertFalse(adopted.needsRefresh, "last_refresh must follow the adopted token's issue time")
    }

    /// 监控自己刷新后写回 CPA 副本：顶层、嵌套、expired 都要更新，标记字段保留。
    func testOwnRefreshIsWrittenThroughToCPACopy() async throws {
        let stale = try accessToken("A0", issuedDaysAgo: 9)
        let fresh = try accessToken("A1", issuedDaysAgo: 0)
        let own = try writeOwnCopy(access: stale, refresh: "R0", refreshedDaysAgo: 9)
        let cpa = try writeCPACopy(flat: (stale, "R0"), nested: (stale, "R0"))
        StubURLProtocol.respond(Self.oauthURL, handler: { _ in (try? self.oauthResponse(access: fresh, refresh: "R1")) ?? (500, "{}") })

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertEqual(oauthRequests.count, 1)
        XCTAssertEqual(oauthRequests.first?.jsonBody?["refresh_token"] as? String, "R0")
        XCTAssertEqual(usageAuthorizations, ["Bearer \(fresh)"])
        XCTAssertEqual(try CodexProvider().loadCredentials(from: own.path).accessToken, fresh)

        let copy = try json(at: cpa)
        let nested = copy["tokens"] as? [String: Any]
        XCTAssertEqual(copy["access_token"] as? String, fresh)
        XCTAssertEqual(copy["refresh_token"] as? String, "R1")
        XCTAssertEqual(nested?["access_token"] as? String, fresh)
        XCTAssertEqual(nested?["refresh_token"] as? String, "R1")
        XCTAssertEqual(copy["aiusage_credential_id"] as? String, credentialId)
        XCTAssertEqual(copy["type"] as? String, "codex")
        let expired = (copy["expired"] as? String).flatMap(SharedFormatters.parseISO8601)
        XCTAssertGreaterThan(expired?.timeIntervalSinceNow ?? 0, 9 * day, "expired must describe the new token")
    }

    /// 旧版本留下的分叉：监控的 token 更新、CPA 副本还停在已作废的旧 token。不用等下次刷新就补齐。
    func testStaleCPACopyIsHealedWithoutWaitingForNextRefresh() async throws {
        let stale = try accessToken("A0", issuedDaysAgo: 9)
        let fresh = try accessToken("A1", issuedDaysAgo: 1)
        let own = try writeOwnCopy(access: fresh, refresh: "R1", refreshedDaysAgo: 1)
        let cpa = try writeCPACopy(flat: (stale, "R0"), nested: (stale, "R0"))

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertTrue(oauthRequests.isEmpty)
        XCTAssertEqual(usageAuthorizations, ["Bearer \(fresh)"])
        let healed = try CodexProvider().loadCredentials(from: cpa.path)
        XCTAssertEqual(healed.accessToken, fresh)
        XCTAssertEqual(healed.refreshToken, "R1")
        XCTAssertEqual((try json(at: cpa)["tokens"] as? [String: Any])?["refresh_token"] as? String, "R1")
    }

    /// CPA 在监控 token 有效期中途轮换：下一次取用量就改用新 token，监控副本同步更新。
    func testNewerCPACopyIsAdoptedBeforeOwnCopyNeedsRefresh() async throws {
        let older = try accessToken("A0", issuedDaysAgo: 5)
        let rotated = try accessToken("A1", issuedDaysAgo: 1)
        let own = try writeOwnCopy(access: older, refresh: "R0", refreshedDaysAgo: 5)
        try writeCPACopy(flat: (rotated, "R1"), nested: (older, "R0"))

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertTrue(oauthRequests.isEmpty)
        XCTAssertEqual(usageAuthorizations, ["Bearer \(rotated)"])
        XCTAssertEqual(try CodexProvider().loadCredentials(from: own.path).refreshToken, "R1")
    }

    /// 刷新请求期间 CPA 恰好用同一个 refresh_token 换到了新 token：采用它，而不是报「请重新登录」。
    func testRefreshRaceWithCPAAdoptsTheWinnerInsteadOfFailing() async throws {
        let stale = try accessToken("A0", issuedDaysAgo: 9)
        let winner = try accessToken("A1", issuedDaysAgo: 0)
        let own = try writeOwnCopy(access: stale, refresh: "R0", refreshedDaysAgo: 9)
        try writeCPACopy(flat: (stale, "R0"), nested: (stale, "R0"))
        StubURLProtocol.respond(Self.oauthURL, handler: { _ in
            _ = try? self.writeCPACopy(flat: (winner, "R1"), nested: (stale, "R0"))
            return (400, #"{"error":"refresh_token_reused"}"#)
        })

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertEqual(oauthRequests.count, 1)
        XCTAssertEqual(usageAuthorizations, ["Bearer \(winner)"])
        XCTAssertEqual(try CodexProvider().loadCredentials(from: own.path).refreshToken, "R1")
    }

    /// 上游提前作废了还没到期的 access token：401 后必须真的刷新，不能把同一个 token 原样返回。
    func testRejectedButUnexpiredAccessTokenTriggersRealRefresh() async throws {
        let revoked = try accessToken("A0", issuedDaysAgo: 1)
        let fresh = try accessToken("A1", issuedDaysAgo: 0)
        let own = try writeOwnCopy(access: revoked, refresh: "R0", refreshedDaysAgo: 1)
        StubURLProtocol.respond(Self.oauthURL, handler: { _ in (try? self.oauthResponse(access: fresh, refresh: "R1")) ?? (500, "{}") })
        StubURLProtocol.respond(Self.usageURL, handler: { request in
            request.headers["Authorization"] == "Bearer \(fresh)" ? (200, #"{"plan_type":"team"}"#) : (401, "{}")
        })

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertEqual(oauthRequests.count, 1)
        XCTAssertEqual(usageAuthorizations, ["Bearer \(revoked)", "Bearer \(fresh)"])
        XCTAssertEqual(try CodexProvider().loadCredentials(from: own.path).accessToken, fresh)
    }

    /// 带同一归属标记但已换成另一位成员的 CPA 文件：既不采用，也不写入。
    func testLinkedCopyOfAnotherMemberIsNeverAdoptedOrWritten() async throws {
        let stale = try accessToken("A0", issuedDaysAgo: 9)
        let fresh = try accessToken("A1", issuedDaysAgo: 0)
        let otherMember = try accessToken("B1", issuedDaysAgo: 1, user: "member-b")
        let own = try writeOwnCopy(access: stale, refresh: "R0", refreshedDaysAgo: 9)
        let cpa = try writeCPACopy(flat: (otherMember, "RB"), nested: (otherMember, "RB"), user: "member-b")
        let cpaBefore = try Data(contentsOf: cpa)
        StubURLProtocol.respond(Self.oauthURL, handler: { _ in (try? self.oauthResponse(access: fresh, refresh: "R1")) ?? (500, "{}") })

        _ = try await CodexProvider(homeDirectory: directory.path).fetchUsage(with: credential(for: own))

        XCTAssertEqual(oauthRequests.first?.jsonBody?["refresh_token"] as? String, "R0")
        XCTAssertEqual(usageAuthorizations, ["Bearer \(fresh)"])
        XCTAssertEqual(try Data(contentsOf: cpa), cpaBefore)
    }

    /// 只有顶层字段被 CPA 更新时，读取要取签发时间更新的那组，而不是固定优先嵌套 tokens。
    func testLoaderPrefersTheNewerTokenGroupWithinOneFile() throws {
        let stale = try accessToken("A0", issuedDaysAgo: 9)
        let rotated = try accessToken("A1", issuedDaysAgo: 2)
        let cpa = try writeCPACopy(flat: (rotated, "R1"), nested: (stale, "R0"))
        let loaded = try CodexProvider().loadCredentials(from: cpa.path)
        XCTAssertEqual(loaded.accessToken, rotated)
        XCTAssertEqual(loaded.refreshToken, "R1")

        let nestedNewer = try writeCPACopy(flat: (stale, "R0"), nested: (rotated, "R1"), name: "nested.json")
        XCTAssertEqual(try CodexProvider().loadCredentials(from: nestedNewer.path).refreshToken, "R1")
    }
}

private extension Data {
    init?(base64URL value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        self.init(base64Encoded: base64)
    }
}
