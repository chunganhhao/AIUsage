import XCTest
@testable import QuotaBackend

final class CodexProviderParsingTests: XCTestCase {
    private let provider = CodexProvider()

    // MARK: - Plan names / workspace types (openai/codex protocol/src/{auth,account}.rs)

    func testPlanDisplayNamesFollowOfficialCodexNaming() {
        let expected: [String: String] = [
            "free": "Free", "go": "Go", "plus": "Plus",
            "pro": "Pro (More)", "prolite": "Pro", "promax": "Pro (Max)",
            "team": "Business", "self_serve_business_prolite": "Business",
            "self_serve_business_usage_based": "Business", "business": "Business",
            "ent26": "Enterprise", "enterprise": "Enterprise", "hc": "Enterprise",
            "enterprise_cbp_automation": "Enterprise", "enterprise_cbp_usage_based": "Enterprise",
            "edu": "Edu", "education": "Edu", "edu_plus": "Edu Plus", "edu_pro": "Edu Pro",
            "sci": "Academic Researchers", "sci_plus": "Academic Researchers Plus",
            "k12": "k12"
        ]
        for (raw, name) in expected {
            XCTAssertEqual(CodexProvider.planDisplayName(forRaw: raw), name, raw)
        }
        XCTAssertNil(CodexProvider.planDisplayName(forRaw: "  "))
    }

    func testWorkspaceTypeAcceptsRawValuesAndDisplayNames() {
        let expected: [String: String] = [
            "plus": "Personal", "pro": "Personal", "prolite": "Personal", "promax": "Personal",
            "Pro (More)": "Personal", "Pro (Max)": "Personal",
            "team": "Business", "self_serve_business_prolite": "Business", "Business": "Business",
            "ent26": "Enterprise", "enterprise_cbp_automation": "Enterprise", "Enterprise": "Enterprise",
            "edu_plus": "Edu", "Edu Pro": "Edu", "sci": "Edu", "Academic Researchers Plus": "Edu"
        ]
        for (plan, type) in expected {
            XCTAssertEqual(CodexProvider.workspaceType(fromPlan: plan), type, plan)
        }
        XCTAssertEqual(CodexProvider.workspaceType(fromPlan: nil), "Personal")
    }

    func testLimitDisplayName() {
        XCTAssertEqual(CodexProvider.limitDisplayName("gpt-5.3-codex-spark"), "GPT-5.3-Codex-Spark")
        XCTAssertEqual(CodexProvider.limitDisplayName("codex_other"), "Codex Other")
        XCTAssertEqual(CodexProvider.limitDisplayName("GPT-5.3-Codex-Spark"), "GPT-5.3-Codex-Spark")
        XCTAssertEqual(CodexProvider.limitDisplayName(""), "Model")
    }

    // MARK: - wham/usage payloads

    func testPlusPayloadWithoutExtrasKeepsTheTwoWindows() throws {
        let usage = parse("""
        {"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":40,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1792000000},
          "secondary_window":{"used_percent":10,"limit_window_seconds":604800,"reset_after_seconds":86400,"reset_at":1792500000}}}
        """)

        XCTAssertEqual(usage.accountPlan, "Plus")
        XCTAssertEqual(usage.primary?.label, "5h Window")
        XCTAssertEqual(usage.secondary?.label, "Weekly Window")
        XCTAssertNil(usage.tertiary)
        XCTAssertNil(usage.extra["extraWindows"])
        XCTAssertNil(usage.extra["credits"])

        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["5h Window", "Weekly Window"])
        XCTAssertEqual(summary.remainingPercent, 60)
        XCTAssertEqual(summary.headline.eyebrow, "Plan · Plus")
    }

    /// Model-specific limits are listed after the main windows but never drive the account status.
    func testAdditionalRateLimitsAreListedButDoNotAffectStatus() throws {
        let usage = parse("""
        {"plan_type":"pro","rate_limit":{"allowed":true,"limit_reached":false,
          "primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600,"reset_at":1792000000},
          "secondary_window":{"used_percent":30,"limit_window_seconds":604800,"reset_after_seconds":86400,"reset_at":1792500000}},
         "additional_rate_limits":[{"limit_name":"gpt-5.3-codex-spark","metered_feature":"codex_spark",
          "rate_limit":{"allowed":false,"limit_reached":true,
            "primary_window":{"used_percent":100,"limit_window_seconds":18000,"reset_after_seconds":600,"reset_at":1792000000},
            "secondary_window":{"used_percent":55,"limit_window_seconds":604800,"reset_after_seconds":86400,"reset_at":1792500000}}}]}
        """)

        XCTAssertEqual(usage.accountPlan, "Pro (More)")
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), [
            "5h Window", "Weekly Window", "GPT-5.3-Codex-Spark · 5h", "GPT-5.3-Codex-Spark · Weekly"
        ])
        XCTAssertEqual(summary.windows[2].remainingPercent, 0)
        XCTAssertEqual(summary.remainingPercent, 70)
        XCTAssertEqual(summary.status, "healthy")
        XCTAssertEqual(summary.headline.eyebrow, "Plan · Pro (More)")
    }

    /// Usage-based workspaces have no rate-limit windows; the monthly credit limit is their real cap.
    func testSpendControlLimitDrivesStatusForUsageBasedWorkspaces() throws {
        let usage = parse("""
        {"plan_type":"self_serve_business_usage_based",
         "credits":{"has_credits":true,"unlimited":false,"balance":"1234.6"},
         "spend_control":{"reached":false,"individual_limit":{"source":"workspace","limit":"5000","used":"4500",
           "remaining":"500","used_percent":90,"remaining_percent":10,"reset_after_seconds":86400,"reset_at":1793000000}}}
        """)

        XCTAssertEqual(usage.accountPlan, "Business")
        XCTAssertNil(usage.primary)
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        XCTAssertEqual(summary.windows.map(\.label), ["Monthly Credit Limit"])
        XCTAssertEqual(summary.remainingPercent, 10)
        XCTAssertEqual(summary.status, "critical")
        XCTAssertEqual(summary.workspaceLabel, "Business")
        XCTAssertEqual(summary.metrics.first { $0.label == "Credits" }?.value, "1235 credits")
    }

    func testCreditsDisplay() {
        let unlimited = parse(#"{"plan_type":"enterprise","credits":{"has_credits":false,"unlimited":true}}"#)
        XCTAssertEqual(unlimited.extra["credits"]?.value as? String, "Unlimited")

        let hidden = parse(#"{"plan_type":"plus","credits":{"has_credits":true,"unlimited":false}}"#)
        XCTAssertEqual(hidden.extra["credits"]?.value as? String, "Available")

        let none = parse(#"{"plan_type":"plus","credits":{"has_credits":false,"unlimited":false,"balance":"0"}}"#)
        XCTAssertNil(none.extra["credits"])
    }

    /// The official schema dropped `code_review_rate_limit`, but older payloads still carry it.
    func testLegacyCodeReviewLimitStillParses() {
        let usage = parse("""
        {"plan_type":"plus","code_review_rate_limit":{"primary_window":
          {"used_percent":5,"limit_window_seconds":604800,"reset_after_seconds":100,"reset_at":1792500000}}}
        """)
        XCTAssertEqual(usage.tertiary?.remainingPercent, 95)
    }

    /// Extra windows survive an AnyCodable encode/decode round trip (integers decode as Int).
    func testExtraWindowsSurviveCodableRoundTrip() throws {
        let usage = parse("""
        {"plan_type":"pro","additional_rate_limits":[{"limit_name":"codex_other","metered_feature":"codex_other",
          "rate_limit":{"allowed":true,"limit_reached":false,
            "primary_window":{"used_percent":25,"limit_window_seconds":18000,"reset_after_seconds":60,"reset_at":1792000000}}}]}
        """)
        let decoded = try JSONDecoder().decode(ProviderUsage.self, from: JSONEncoder().encode(usage))
        let summary = UsageNormalizer.normalize(provider: provider, usage: decoded)
        XCTAssertEqual(summary.windows.map(\.label), ["Codex Other · 5h"])
        XCTAssertEqual(summary.windows.first?.remainingPercent, 75)
    }

    private func parse(_ text: String) -> ProviderUsage {
        let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
        return provider.parseResponse(
            json,
            accountId: "acct-1",
            source: SourceInfo(mode: "oauth", type: "codex-auth-json"),
            fallbackEmail: "user@example.com"
        )
    }
}
