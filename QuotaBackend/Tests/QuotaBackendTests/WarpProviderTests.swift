import XCTest
@testable import QuotaBackend

/// Request shape and fixtures follow CodexBar's WarpUsageFetcher (2026-10); not verified live.
final class WarpProviderTests: XCTestCase {
    private let provider = WarpProvider()

    override func setUp() {
        super.setUp()
        StubURLProtocol.install(hosts: ["warp.dev"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    func testAPIKeyRequestMatchesOfficialClientShape() async throws {
        StubURLProtocol.respond(WarpProvider.graphQLURL, body: Self.response(limit: 1500, used: 600, extraUser: ""))

        let usage = try await provider.fetchUsage(with: credential())

        let request = try XCTUnwrap(StubURLProtocol.lastRequest(to: WarpProvider.graphQLURL))
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["User-Agent"], "Warp/1.0")
        XCTAssertEqual(request.headers["Authorization"], "Bearer wk-test-key")
        XCTAssertEqual(request.headers["x-warp-client-id"], "warp-app")
        XCTAssertEqual(request.jsonBody?["operationName"] as? String, "GetRequestLimitInfo")
        XCTAssertNotNil((request.jsonBody?["variables"] as? [String: Any])?["requestContext"])

        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 60, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.resetAt, SharedFormatters.iso8601String(from: SharedFormatters.parseISO8601("2026-11-01T00:00:00Z")!))
        XCTAssertEqual(usage.extra["requestsRemaining"]?.value as? Int, 900)
        XCTAssertNil(usage.extra["bonusCreditsRemaining"])
        XCTAssertEqual(usage.usageAccountId, "warp-\(KimiProvider.stableFingerprint("wk-test-key"))")
        XCTAssertEqual(usage.source?.type, "warp-api")

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["Credits"])
        XCTAssertEqual(summary.headline.eyebrow, "Warp API")
        XCTAssertFalse(summary.metrics.contains { $0.label == "Assistant Pool" })
    }

    func testBonusGrantsCombineUserAndWorkspaceLevels() async throws {
        StubURLProtocol.respond(WarpProvider.graphQLURL, body: Self.response(limit: 150, used: 150, extraUser: """
        ,"bonusGrants":[{"requestCreditsGranted":100,"requestCreditsRemaining":40,"expiration":"2026-12-01T00:00:00Z"}],
         "workspaces":[{"bonusGrantsInfo":{"grants":[{"requestCreditsGranted":"500","requestCreditsRemaining":"250"}]}}]
        """))

        let usage = try await provider.fetchUsage(with: credential())

        XCTAssertEqual(usage.primary?.remainingPercent, 0)
        XCTAssertEqual(usage.extra["bonusCreditsRemaining"]?.value as? Int, 290)
        XCTAssertEqual(usage.extra["bonusCreditsTotal"]?.value as? Int, 600)
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.headline.supporting, "290 bonus credits remain")
    }

    func testUnlimitedPlan() throws {
        let usage = try provider.parseGraphQLResponse(Self.json("""
        {"data":{"user":{"__typename":"UserOutput","user":{"requestLimitInfo":
          {"isUnlimited":true,"requestLimit":0,"requestsUsedSinceLastRefresh":12}}}}}
        """))
        XCTAssertEqual(usage.primary?.unlimited, true)
        XCTAssertEqual(usage.primary?.remainingPercent, 100)
        XCTAssertEqual(usage.extra["isUnlimited"]?.value as? Bool, true)
    }

    func testGraphQLErrorsAndRejectedKeysSurfaceAsErrors() async {
        XCTAssertThrowsError(try provider.parseGraphQLResponse(Self.json(#"{"errors":[{"message":"Unauthenticated"}]}"#))) { error in
            XCTAssertEqual((error as? ProviderError)?.message, "Unauthenticated")
        }
        XCTAssertThrowsError(try provider.parseGraphQLResponse(Self.json(#"{"data":{"user":{"__typename":"UserFacingError"}}}"#)))

        StubURLProtocol.respond(WarpProvider.graphQLURL, status: 401, body: "{}")
        do {
            _ = try await provider.fetchUsage(with: credential())
            XCTFail("Expected invalid credentials")
        } catch {
            XCTAssertEqual((error as? ProviderError)?.code, "invalid_credentials")
        }
    }

    // MARK: - Fixtures

    private static func response(limit: Int, used: Int, extraUser: String) -> String {
        """
        {"data":{"user":{"__typename":"UserOutput","user":{
          "requestLimitInfo":{"isUnlimited":false,"nextRefreshTime":"2026-11-01T00:00:00Z",
                              "requestLimit":\(limit),"requestsUsedSinceLastRefresh":\(used)}\(extraUser)}}}}
        """
    }

    private static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func credential() -> AccountCredential {
        AccountCredential(providerId: "warp", authMethod: .apiKey, credential: "wk-test-key")
    }
}
