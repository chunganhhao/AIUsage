import XCTest
@testable import QuotaBackend

final class CursorProviderTests: XCTestCase {
    private let provider = CursorProvider()

    override func setUp() {
        super.setUp()
        StubURLProtocol.install(hosts: ["cursor.com", "cursor.sh"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    // MARK: - Legacy plans (must not change)

    /// The old 500-request plan reads /api/usage and never triggers the unified-plan RPCs.
    func testLegacyRequestPlanIsUnchangedAndSkipsUnifiedRequests() async throws {
        StubURLProtocol.respond(Self.usageSummary, body: """
        {"billingCycleStart":"2026-10-01T00:00:00.000Z","billingCycleEnd":"2026-11-01T00:00:00.000Z",
         "membershipType":"pro","individualUsage":{"plan":{"enabled":true,"used":0,"limit":0}}}
        """)
        StubURLProtocol.respond(Self.authMe, body: #"{"sub":"user_123","email":"dev@example.com","name":"Dev"}"#)
        StubURLProtocol.respond(Self.requestUsage, body: #"{"gpt-4":{"numRequests":120,"numRequestsTotal":120,"maxRequestUsage":500}}"#)
        StubURLProtocol.respond(CursorProvider.planInfoURL, body: #"{"planInfo":{"planName":"Pro"}}"#)

        let usage = try await provider.fetchUsage(with: cookieCredential())

        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 24, accuracy: 0.001)
        XCTAssertEqual(usage.accountPlan, "Pro")
        XCTAssertNil(usage.extra["cursorPlanKind"])
        XCTAssertEqual(Set(StubURLProtocol.requestedURLs),
                       [Self.usageSummary, Self.authMe, Self.requestUsage, CursorProvider.planInfoURL])

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["Main Plan"])
        XCTAssertEqual(summary.remainingPercent ?? -1, 76, accuracy: 0.001)
    }

    func testLegacyUsageBasedPlanKeepsItsThreeWindows() {
        let usage = provider.parseResponse(
            summary: Self.json("""
            {"billingCycleEnd":"2026-11-01T00:00:00.000Z","membershipType":"pro",
             "individualUsage":{"plan":{"used":1200,"limit":2000,"autoPercentUsed":28.6,"apiPercentUsed":42.35,"totalPercentUsed":30.8},
                                "onDemand":{"used":150}}}
            """),
            userInfo: ["sub": "user_123"],
            requestUsage: nil,
            source: SourceInfo(mode: "manual", type: "pasted-cookie")
        )
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 30.8, accuracy: 0.001)
        XCTAssertEqual(usage.secondary?.usedPercent ?? -1, 28.6, accuracy: 0.001)
        XCTAssertEqual(usage.tertiary?.usedPercent ?? -1, 42.35, accuracy: 0.001)
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["Main Plan", "Auto / Composer", "Named Models"])
    }

    /// Some enterprise seats have no `plan`; they must not read as "0% used".
    func testEnterpriseSeatWithoutPlanUsesOverallOrStaysUnknown() {
        XCTAssertEqual(CursorProvider.legacyPlanPercent(["overall": ["used": 3000, "limit": 10000]]) ?? -1, 30, accuracy: 0.001)
        XCTAssertNil(CursorProvider.legacyPlanPercent(["overall": ["used": 3000, "limit": NSNull()]]))
        XCTAssertNil(CursorProvider.legacyPlanPercent([:]))
        // An existing plan keeps the old rule, including the zero fallback.
        XCTAssertEqual(CursorProvider.legacyPlanPercent(["plan": ["used": 0, "limit": 0]]), 0)

        let usage = provider.parseResponse(
            summary: Self.json(#"{"membershipType":"enterprise","individualUsage":{"onDemand":{"used":0}}}"#),
            userInfo: nil,
            requestUsage: nil,
            source: SourceInfo(mode: "manual", type: "pasted-cookie")
        )
        XCTAssertNil(usage.primary)
        XCTAssertNil(UsageNormalizer.normalize(provider: provider, usage: usage).remainingPercent)
    }

    // MARK: - Unified plan

    func testUnifiedPlanReadsWeeklyPoolFromCurrentPeriodUsage() async throws {
        respondUnifiedBasics()
        StubURLProtocol.respond(CursorProvider.planInfoURL, body: """
        {"isMerged":true,"planInfo":{"planName":"Premium","includedUsagePeriod":"INCLUDED_USAGE_PERIOD_WEEKLY",
          "includedUsageResetsAt":"1792800000000"}}
        """)
        StubURLProtocol.respond(CursorProvider.currentPeriodUsageURL, body: #"{"planUsage":{"autoPercentUsed":5,"totalPercentUsed":13.09}}"#)
        StubURLProtocol.respond(CursorProvider.prepaidBillingURL, body: #"{"availableCents":"2500"}"#)

        let usage = try await provider.fetchUsage(with: cookieCredential())

        XCTAssertEqual(usage.extra["cursorPlanKind"]?.value as? String, "unified")
        XCTAssertEqual(usage.accountPlan, "Premium")
        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 13.09, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.resetAt, SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: 1_792_800_000)))
        XCTAssertNil(usage.secondary)
        XCTAssertNil(usage.tertiary)

        let rpc = try XCTUnwrap(StubURLProtocol.lastRequest(to: CursorProvider.currentPeriodUsageURL))
        XCTAssertEqual(rpc.method, "POST")
        XCTAssertEqual(rpc.headers["Authorization"], "Bearer \(Self.accessToken)")
        XCTAssertEqual(rpc.headers["Connect-Protocol-Version"], "1")
        XCTAssertEqual(StubURLProtocol.lastRequest(to: CursorProvider.planInfoURL)?.headers["Origin"], "https://cursor.com")
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(CursorProvider.sandUsageURL))

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["Included Usage"])
        XCTAssertEqual(summary.remainingPercent ?? -1, 86.91, accuracy: 0.001)
        XCTAssertEqual(summary.headline.secondary, "included usage this week")
        XCTAssertEqual(summary.metrics.first { $0.label == "Prepaid Balance" }?.value, UsageNormalizer.formatCurrency(25))
    }

    func testUnifiedPlanFallsBackToSandUsageWhenCurrentPeriodFails() async throws {
        respondUnifiedBasics()
        StubURLProtocol.respond(CursorProvider.planInfoURL, body: #"{"isMerged":true}"#)
        StubURLProtocol.respond(CursorProvider.currentPeriodUsageURL, status: 401, body: "{}")
        StubURLProtocol.respond(CursorProvider.sandUsageURL, body: """
        {"usagePercent":40,"isUnified":true,"nextResetTimestampUtc":"2026-10-27T00:00:00Z"}
        """)

        let usage = try await provider.fetchUsage(with: cookieCredential())

        XCTAssertEqual(usage.primary?.usedPercent ?? -1, 40, accuracy: 0.001)
        XCTAssertEqual(usage.primary?.resetAt, "2026-10-27T00:00:00Z")
        XCTAssertNil(usage.extra["prepaid.availableUsd"])
    }

    /// Plan info unavailable: the sand status alone can identify a unified plan.
    func testSandStatusIdentifiesUnifiedPlanWithoutPlanInfo() async throws {
        respondUnifiedBasics()
        StubURLProtocol.respond(CursorProvider.sandUsageURL, body: #"{"usagePercent":12.5,"isUnified":true}"#)
        StubURLProtocol.respond(CursorProvider.currentPeriodUsageURL, body: #"{"planUsage":{}}"#)

        let usage = try await provider.fetchUsage(with: cookieCredential())

        XCTAssertEqual(usage.extra["cursorPlanKind"]?.value as? String, "unified")
        // proto3 omits a zero totalPercentUsed: an explicit current-period 0 wins over sand.
        XCTAssertEqual(usage.primary?.usedPercent, 0)
    }

    func testUnifiedPlanWithoutAnyPercentStaysUnknown() async throws {
        respondUnifiedBasics()
        StubURLProtocol.respond(CursorProvider.planInfoURL, body: #"{"isMerged":true}"#)

        let usage = try await provider.fetchUsage(with: cookieCredential())

        XCTAssertEqual(usage.extra["cursorPlanKind"]?.value as? String, "unified")
        XCTAssertNil(usage.primary)
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertTrue(summary.windows.isEmpty)
        XCTAssertNil(summary.remainingPercent)
    }

    func testUnifiedIncludedPercentPriority() {
        let sand = CursorProvider.SandStatus(usedPercent: 40, isUnified: true, resetsAt: nil)
        XCTAssertEqual(CursorProvider.unifiedIncludedPercent(periodPercent: 0, sand: sand, summaryPercent: 9, period: .monthly), 0)
        XCTAssertEqual(CursorProvider.unifiedIncludedPercent(periodPercent: nil, sand: sand, summaryPercent: 9, period: .monthly), 40)
        XCTAssertEqual(CursorProvider.unifiedIncludedPercent(periodPercent: nil, sand: nil, summaryPercent: 9, period: .monthly), 9)
        XCTAssertNil(CursorProvider.unifiedIncludedPercent(periodPercent: nil, sand: nil, summaryPercent: 9, period: .weekly))
        XCTAssertNil(CursorProvider.unifiedIncludedPercent(periodPercent: nil, sand: nil, summaryPercent: 9, period: nil))
    }

    func testAccessTokenFromCookieHeader() {
        XCTAssertEqual(CursorProvider.accessToken(fromCookieHeader: Self.cookie), Self.accessToken)
        XCTAssertEqual(CursorProvider.accessToken(fromCookieHeader: "WorkosCursorSessionToken=user_123::\(Self.accessToken)"), Self.accessToken)
        XCTAssertEqual(CursorProvider.accessToken(fromCookieHeader: "foo=bar; \(Self.cookie); baz=qux"), Self.accessToken)
        XCTAssertNil(CursorProvider.accessToken(fromCookieHeader: "__Secure-next-auth.session-token=abc"))
        XCTAssertNil(CursorProvider.accessToken(fromCookieHeader: "WorkosCursorSessionToken=user_123%3A%3Anot-a-jwt"))
    }

    // MARK: - Fixtures

    private static let usageSummary = "https://cursor.com/api/usage-summary"
    private static let authMe = "https://cursor.com/api/auth/me"
    private static let requestUsage = "https://cursor.com/api/usage?user=user_123"
    private static let accessToken = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhdXRoMHx1c2VyXzEyMyJ9.c2ln"
    private static let cookie = "WorkosCursorSessionToken=user_123%3A%3A\(accessToken)"

    private func respondUnifiedBasics() {
        StubURLProtocol.respond(Self.usageSummary, body: """
        {"billingCycleEnd":"2026-11-01T00:00:00.000Z","membershipType":"pro",
         "individualUsage":{"plan":{"used":0,"limit":0,"totalPercentUsed":0}}}
        """)
        StubURLProtocol.respond(Self.authMe, body: #"{"sub":"user_123","email":"dev@example.com"}"#)
    }

    private func cookieCredential() -> AccountCredential {
        AccountCredential(providerId: "cursor", authMethod: .cookie, credential: Self.cookie)
    }

    private static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
}
