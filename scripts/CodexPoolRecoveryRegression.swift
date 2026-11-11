import Foundation
@testable import QuotaBackend

@main struct CodexPoolRecoveryRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        guard try value() else { throw NSError(domain: message, code: 1) }
    }
    static func main() async throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("home")
        let auth = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth/aiusage-codex-recovery.json")
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        let claims: [String: Any] = ["exp": Date().timeIntervalSince1970 + 86400,
            "iat": Date().timeIntervalSince1970, "email": "recovery@example.test",
            "https://api.openai.com/auth": ["chatgpt_account_id": "recovery-workspace", "chatgpt_user_id": "recovery-user"]]
        let encoded = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "=", with: "").replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        let initial: [String: Any] = ["type": "codex", "email": "recovery@example.test", "account_id": "recovery-workspace",
            "user_id": "recovery-user", "access_token": "e30." + encoded + ".fixture", "disabled": false,
            "last_refresh": SharedFormatters.iso8601String(from: Date())]
        func save(_ json: [String: Any]) throws { try JSONSerialization.data(withJSONObject: json).write(to: auth) }
        func read() throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: auth)) as! [String: Any] }
        func paused() throws -> Bool { let json = try read(); return json["disabled"] as? Bool == true && json["circuit_breaker_tripped"] as? Bool == true }
        func windows(_ primary: Double?, _ secondary: Double?, monthly: Double? = nil) -> [String: Any] {
            var rate: [String: Any] = [:]
            if let primary { rate["primary_window"] = ["used_percent": 100 - primary, "limit_window_seconds": 18000] }
            if let secondary { rate["secondary_window"] = ["used_percent": 100 - secondary, "limit_window_seconds": 604800] }
            var response: [String: Any] = ["rate_limit": rate]
            if let monthly { response["spend_control"] = ["individual_limit": ["used_percent": 100 - monthly]] }
            return response
        }
        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
        defer { StubURLProtocol.uninstall() }
        let endpoint = "https://chatgpt.com/backend-api/wham/usage"
        let credential = AccountCredential(providerId: "codex", accountLabel: "recovery@example.test", authMethod: .authFile,
            credential: auth.path, metadata: ["accountId": "recovery-workspace", "userId": "recovery-user"])
        let provider = CodexProvider(homeDirectory: home.path)
        func fetch(_ response: [String: Any]) async throws -> ProviderUsage {
            let body = String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self)
            StubURLProtocol.respond(endpoint, body: body)
            return try await provider.fetchUsage(with: credential)
        }
        func expectDeferred(_ response: [String: Any]) async throws {
            let before = try Data(contentsOf: auth)
            let usage = try await fetch(response)
            try check(try paused(), "unknown quota must keep account paused")
            try check(usage.extra["circuitBreakerTripped"]?.value as? Bool == true, "deferred recovery reports actual paused state")
            try check(usage.extra["circuitBreakerError"]?.value as? String != nil, "deferred recovery explains missing evidence")
            try check(try Data(contentsOf: auth) == before, "deferred recovery leaves credential bytes unchanged")
        }
        try save(initial)
        try CodexPoolProtectionSettings.setEnabled(true, threshold: 3, homeDirectory: home.path)
        _ = try await fetch(windows(99, 1))
        try check(try paused(), "known low weekly quota trips")
        try check(try read()["circuit_breaker_blocked_windows"] as? [String] == ["rate-limit-seconds:604800.0"], "trip records stable weekly key")
        try await expectDeferred([:])
        try await expectDeferred(windows(99, nil))
        _ = try await fetch(windows(99, 99))
        try check(try !paused(), "fresh healthy blocking window permits recovery")
        try check(try read()["circuit_breaker_blocked_windows"] == nil, "recovery clears structured blocker metadata")

        _ = try await fetch(windows(99, 1))
        let healthyFiveHourInSecondary: [String: Any] = ["rate_limit": ["secondary_window": ["used_percent": 0, "limit_window_seconds": 18000]]]
        try await expectDeferred(healthyFiveHourInSecondary)
        let healthyWeeklyInPrimary: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 0, "limit_window_seconds": 604800]]]
        _ = try await fetch(healthyWeeklyInPrimary)
        try check(try !paused(), "same weekly duration can recover after moving to primary slot")
        let unknownLow: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 99]]]
        let unknownHealthy: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 0]]]
        _ = try await fetch(unknownLow)
        try check(try paused(), "known low without duration still pauses")
        try await expectDeferred(unknownHealthy)
        try CodexPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        try CodexPoolProtectionSettings.setEnabled(true, homeDirectory: home.path)
        _ = try await fetch(windows(1, 1))
        try check(try read()["circuit_breaker_blocked_windows"] as? [String] == ["rate-limit-seconds:18000.0", "rate-limit-seconds:604800.0"], "all depleted windows recorded, not only reason label")
        try await expectDeferred(windows(nil, 99))
        _ = try await fetch(windows(99, 99))
        try check(try !paused(), "all original blocking windows known healthy recover")

        _ = try await fetch(windows(99, 99, monthly: 1))
        try check(try paused(), "status-affecting monthly credit limit trips")
        try check(try read()["circuit_breaker_blocked_windows"] as? [String] == ["monthly-credit-limit"], "monthly uses stable key, not localized label")
        try await expectDeferred(windows(99, 99))
        _ = try await fetch(windows(1, 99))
        try check(try read()["circuit_breaker_blocked_windows"] as? [String] == ["monthly-credit-limit", "rate-limit-seconds:18000.0"], "newly depleted window does not erase previously missing blocker")
        try await expectDeferred(windows(99, 99))
        _ = try await fetch(windows(99, 99, monthly: 99))
        try check(try !paused(), "monthly plus primary fresh recovery")

        _ = try await fetch(windows(99, 3))
        try check(try paused(), "threshold equality trips")
        _ = try await fetch(windows(99, 3.01))
        try check(try !paused(), "recovery uses configured threshold without flooring")
        var manual = initial; manual["disabled"] = true
        try save(manual); let manualBytes = try Data(contentsOf: auth)
        _ = try await fetch(windows(1, 1))
        try check(try Data(contentsOf: auth) == manualBytes, "manual pause is never claimed by breaker")

        var legacy = initial; legacy["disabled"] = true; legacy["circuit_breaker_tripped"] = true
        try save(legacy)
        try await expectDeferred(windows(99, 99, monthly: 99))
        _ = try await fetch(windows(99, 1))
        try check(try (read()["circuit_breaker_blocked_windows"] as? [String])?.contains("legacy-unknown") == true, "observing a new low quota cannot invent legacy recovery evidence")
        try await expectDeferred(windows(99, 99, monthly: 99))
        try CodexPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        try check(try !paused() && read()["circuit_breaker_blocked_windows"] == nil, "explicit Off restores legacy breaker pause and clears metadata")

        var structured = legacy; structured["circuit_breaker_blocked_windows"] = ["rate-limit-seconds:604800.0"]
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            try save(structured)
            let outcome = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [auth], shouldTrip: false,
                reason: "fixture", quotaRemaining: ["rate-limit-seconds:604800.0": invalid], threshold: 3)
            try check(try paused() && outcome?.tripped == true && outcome?.error != nil, "nonfinite quota never proves recovery")
        }
        try check(StubURLProtocol.requestedURLs.allSatisfy { $0 == endpoint }, "only intercepted quota reads, no OAuth or paid inference")
        print("Codex pool recovery: \(checks) checks PASS (production provider, temporary auth, no paid requests)")
    }
}
