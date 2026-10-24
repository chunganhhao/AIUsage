import XCTest
@testable import QuotaBackend

/// Fixtures follow publicly reported responses (MiniMax-M2 #99, ClaudeBar #359, Kilo #6215); not verified live.
final class MiniMaxProviderTests: XCTestCase {
    private let provider = MiniMaxProvider()

    override func setUp() {
        super.setUp()
        StubURLProtocol.install(hosts: ["minimaxi.com", "minimax.io"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    func testTokenPlanPercentagesWinOverZeroCounts() async throws {
        StubURLProtocol.respond(Self.chinaTokenPlan, body: Self.remains(general: """
        "current_interval_total_count":0,"current_interval_usage_count":0,"current_interval_remaining_percent":85,
        "current_weekly_total_count":0,"current_weekly_usage_count":0,"current_weekly_remaining_percent":60
        """))

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(usage.primary?.remainingPercent, 85)
        XCTAssertEqual(usage.secondary?.remainingPercent, 60)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [Self.chinaTokenPlan])
    }

    /// `usage_count` is the remaining count: 1200 of 1500 left means 20% used, not 80%.
    func testCountOnlyResponsesTreatUsageCountAsRemaining() async throws {
        StubURLProtocol.respond(Self.chinaTokenPlan, body: Self.remains(general: """
        "current_interval_total_count":1500,"current_interval_usage_count":1200,
        "current_weekly_total_count":15000,"current_weekly_usage_count":3000
        """))

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 80, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 20, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.remaining, 1200)
        XCTAssertEqual(usage.secondary?.remainingPercent ?? -1, 20, accuracy: 0.001)
    }

    func testPercentWinsWhenBothCountsAndPercentArePresent() async throws {
        StubURLProtocol.respond(Self.chinaTokenPlan, body: Self.remains(general: """
        "current_interval_total_count":100,"current_interval_usage_count":90,"current_interval_remaining_percent":30
        """))

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(usage.primary?.remainingPercent, 30)
        XCTAssertNil(usage.secondary)
    }

    /// An inactive token plan answers `model_remains: null`; the older coding_plan endpoint is tried next.
    func testInactiveTokenPlanFallsBackToCodingPlanInTheSameRegion() async throws {
        StubURLProtocol.respond(Self.chinaTokenPlan, body: #"{"model_remains":null,"base_resp":{"status_code":0,"status_msg":"success"}}"#)
        StubURLProtocol.respond(Self.chinaCodingPlan, body: Self.remains(general: """
        "current_interval_total_count":600,"current_interval_usage_count":300
        """))

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(StubURLProtocol.requestedURLs, [Self.chinaTokenPlan, Self.chinaCodingPlan])
        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(usage.extra[ProviderAPIRegion.metadataKey]?.value as? String, "china")
    }

    func testInactivePlanEverywhereReportsInactive() async {
        let inactive = #"{"model_remains":null,"base_resp":{"status_code":0}}"#
        StubURLProtocol.respond(Self.chinaTokenPlan, body: inactive)
        StubURLProtocol.respond(Self.chinaCodingPlan, body: inactive)

        do {
            _ = try await provider.fetchUsage(with: credential(region: .china))
            XCTFail("Expected an inactive-plan error")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "empty_usage")
        } catch {
            XCTFail("Unexpected error \(error)")
        }
        // An explicit region never crosses over to the other region's hosts.
        XCTAssertTrue(StubURLProtocol.requestedURLs.allSatisfy { $0.contains("minimaxi.com") })
    }

    func testRegionCandidates() {
        let endpoints = MiniMaxProvider.usageEndpoints
        XCTAssertEqual(ProviderAPIRegion.auto.candidates(endpoints, chinaContains: ["minimaxi.com"], internationalContains: ["minimax.io"]), endpoints)
        XCTAssertEqual(ProviderAPIRegion.international.candidates(endpoints, chinaContains: ["minimaxi.com"], internationalContains: ["minimax.io"]),
                       [Self.intlTokenPlan, "https://api.minimax.io/v1/api/openplatform/coding_plan/remains"])
    }

    // MARK: - Fixtures

    private static let chinaTokenPlan = "https://api.minimaxi.com/v1/token_plan/remains"
    private static let intlTokenPlan = "https://api.minimax.io/v1/token_plan/remains"
    private static let chinaCodingPlan = "https://api.minimaxi.com/v1/api/openplatform/coding_plan/remains"

    private static func remains(general fields: String) -> String {
        """
        {"model_remains":[{"model_name":"general","end_time":1792000000000,"weekly_end_time":1792500000000,\(fields)},
                          {"model_name":"video","current_interval_remaining_percent":100}],
         "base_resp":{"status_code":0,"status_msg":"success"}}
        """
    }

    private func credential(region: ProviderAPIRegion) -> AccountCredential {
        AccountCredential(
            providerId: "minimax",
            authMethod: .apiKey,
            credential: "sk-cp-test",
            metadata: [ProviderAPIRegion.metadataKey: region.rawValue]
        )
    }
}
