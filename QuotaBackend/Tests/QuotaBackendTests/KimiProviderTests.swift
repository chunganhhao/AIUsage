import XCTest
@testable import QuotaBackend

/// The ratio-pool fixtures follow CodexBar's KimiModels (2026-10); not verified live.
final class KimiProviderTests: XCTestCase {
    private let provider = KimiProvider()

    override func setUp() {
        super.setUp()
        StubURLProtocol.install(hosts: ["kimi.com", "kimi.ai", "moonshot.ai"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    func testRatioPoolsOnlyResponseIsReadInsteadOfFailing() async throws {
        StubURLProtocol.respond(Self.china, body: """
        {"usages":{"limit_5h":{"used_ratio":0.25,"reset_time":"2026-10-20T15:00:00Z"},
                   "limit_7d":{"used_ratio":0.6,"reset_time":"2026-10-25T00:00:00Z"},
                   "limit_month_total":{"used_ratio":1.3,"reset_time":"2026-11-01T00:00:00Z"}},
         "user":{"membership":{"level":"LEVEL_BASIC"}},"version":"GOODS_VERSION_V1"}
        """)

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 75, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.remainingPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(usage.tertiary?.remainingPercent, 0)
        XCTAssertEqual(usage.primary?.resetAt, SharedFormatters.iso8601String(from: SharedFormatters.parseISO8601("2026-10-20T15:00:00Z")!))
        XCTAssertEqual(usage.extra["tertiaryLabel"]?.value as? String, "Monthly Window")
        XCTAssertEqual(usage.accountPlan, "Moderato")

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["5h Window", "Weekly Window", "Monthly Window"])
    }

    func testLegacyCountResponseIsUnchanged() async throws {
        StubURLProtocol.respond(Self.china, body: """
        {"usage":{"limit":"2048","used":"214","remaining":"1834","resetTime":"2026-10-25T00:00:00Z"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},
                    "detail":{"limit":"200","used":"139","remaining":"61","resetTime":"2026-10-20T13:33:02Z"}}]}
        """)

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 69.5, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 214.0 / 2048 * 100, accuracy: 0.001)
        XCTAssertNil(usage.tertiary)
        XCTAssertEqual(usage.extra["primaryLabel"]?.value as? String, "5h Window")
        XCTAssertEqual(usage.extra["secondaryLabel"]?.value as? String, "Weekly Window")
    }

    /// Ratio pools win for the windows they provide; legacy fields fill the rest.
    func testRatioPoolsTakePrecedenceOverLegacyFields() async throws {
        StubURLProtocol.respond(Self.china, body: """
        {"usage":{"limit":"2048","used":"1024"},
         "limits":[{"window":{"duration":300,"timeUnit":"TIME_UNIT_MINUTE"},"detail":{"limit":"200","used":"20"}}],
         "usages":{"limit_5h":{"used_ratio":0.9}}}
        """)

        let usage = try await provider.fetchUsage(with: credential(region: .china))

        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 90, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 50, accuracy: 0.001)
    }

    func testInternationalRegionUsesKimiAIBeforeMoonshot() async throws {
        StubURLProtocol.respond(Self.international, status: 401, body: "{}")
        StubURLProtocol.respond(Self.moonshot, status: 404, body: "{}")

        do {
            _ = try await provider.fetchUsage(with: credential(region: .international))
            XCTFail("Expected a credential error")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "invalid_credentials")
            XCTAssertTrue(error.message.contains("api.kimi.ai"))
        }
        XCTAssertEqual(StubURLProtocol.requestedURLs, [Self.international, Self.moonshot])
    }

    func testMembershipLevels() {
        func plan(_ level: String, version: String? = nil) -> String? {
            var root: [String: Any] = ["user": ["membership": ["level": level]]]
            if let version { root["version"] = version }
            return KimiProvider.resolveMembershipPlan(root)
        }
        XCTAssertEqual(plan("LEVEL_FREE"), "Adagio")
        XCTAssertEqual(plan("LEVEL_TRIAL"), "Andante")
        XCTAssertEqual(plan("LEVEL_INTERMEDIATE"), "Allegretto")
        XCTAssertEqual(plan("LEVEL_ADVANCED", version: "GOODS_VERSION_V1"), "Allegro")
        XCTAssertEqual(plan("LEVEL_ADVANCED", version: "GOODS_VERSION_V2"), "LEVEL_ADVANCED")
        XCTAssertNil(plan("LEVEL_UNSPECIFIED"))
        XCTAssertNil(KimiProvider.resolveMembershipPlan([:]))
    }

    // MARK: - Fixtures

    private static let china = "https://api.kimi.com/coding/v1/usages"
    private static let international = "https://api.kimi.ai/coding/v1/usages"
    private static let moonshot = "https://api.moonshot.ai/v1/usages"

    private func credential(region: ProviderAPIRegion) -> AccountCredential {
        AccountCredential(
            providerId: "kimi",
            authMethod: .apiKey,
            credential: "sk-kimi-test",
            metadata: [ProviderAPIRegion.metadataKey: region.rawValue]
        )
    }
}
