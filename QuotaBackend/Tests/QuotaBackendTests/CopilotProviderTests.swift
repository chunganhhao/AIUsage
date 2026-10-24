import XCTest
@testable import QuotaBackend

final class CopilotProviderTests: XCTestCase {
    private let provider = CopilotProvider()

    /// Annual plans stay on premium requests until they expire: unchanged labels and math.
    func testLegacyPremiumRequestsKeepTheirLabel() {
        let usage = make("""
        {"login":"octo","copilot_plan":"individual","access_type_sku":"monthly_subscriber","quota_reset_date_utc":"2026-11-01T00:00:00Z",
         "quota_snapshots":{
           "premium_interactions":{"entitlement":300,"remaining":120,"quota_remaining":120.0,"percent_remaining":40,"unlimited":false},
           "chat":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true},
           "completions":{"entitlement":0,"remaining":0,"percent_remaining":100,"unlimited":true}}}
        """)

        XCTAssertEqual(usage.extra["premiumUnit"]?.value as? String, "requests")
        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 40, accuracy: 0.001)

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["Premium", "Chat", "Completions"])
        XCTAssertEqual(summary.windows.first?.value, "120 left")
        XCTAssertEqual(summary.windows[1].value, "Unlimited")
        XCTAssertEqual(summary.remainingPercent ?? -1, 40, accuracy: 0.001)
    }

    /// Since 2026-06 the same snapshot holds AI Credits; the fractional quota_remaining matches GitHub's panel.
    func testTokenBasedBillingShowsAICredits() {
        let usage = make("""
        {"login":"octo","copilot_plan":"individual","quota_reset_date":"2026-11-01",
         "quota_snapshots":{"premium_interactions":{"entitlement":1500,"remaining":1200,"quota_remaining":1200.5,
           "credits_used":299,"percent_remaining":80,"has_quota":true,"token_based_billing":true,"unlimited":false}}}
        """)

        XCTAssertEqual(usage.extra["premiumUnit"]?.value as? String, "credits")
        XCTAssertEqual(usage.extra["premiumCreditsUsed"]?.value as? Double, 299)
        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 1200.5 / 1500 * 100, accuracy: 0.0001)
        XCTAssertEqual(usage.accountPlan, "Pro")

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.first?.label, "AI Credits")
        XCTAssertEqual(summary.windows.first?.value, "1,200 left")
    }

    /// Over the allowance, remaining goes negative: show the overage instead of "-740 left".
    func testOverageShowsHowFarOver() {
        let usage = make("""
        {"login":"octo","copilot_plan":"business","access_type_sku":"copilot_business_seat","token_based_billing":true,
         "quota_snapshots":{"premium_interactions":{"entitlement":3000,"remaining":-740,"quota_remaining":-739.5,
           "credits_used":3739,"percent_remaining":0,"has_quota":false,"unlimited":false}}}
        """)

        XCTAssertEqual(usage.extra["premiumUnit"]?.value as? String, "credits")
        XCTAssertEqual(usage.primary?.remainingPercent, 0)
        XCTAssertEqual(usage.accountPlan, "Business")

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.first?.value, "740 over")
        XCTAssertEqual(summary.status, "critical")
    }

    func testPercentFallsBackWhenQuotaRemainingIsMissing() {
        let usage = make("""
        {"copilot_plan":"individual","quota_snapshots":{"premium_interactions":
          {"entitlement":300,"remaining":30,"percent_remaining":10,"unlimited":false}}}
        """)
        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 10, accuracy: 0.001)
    }

    private func make(_ text: String) -> ProviderUsage {
        let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return provider.makeUsage(payload: payload, email: "octo@example.com", source: SourceInfo(mode: "manual", type: "manual-token"))
    }
}
