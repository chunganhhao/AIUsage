import Foundation
@testable import QuotaBackend

@main
struct PoolCircuitBreakerRegression {
    static var checks = 0
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw NSError(domain: message, code: 1) }
        checks += 1
    }

    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let auth = root.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("current").path, withDestinationPath: "versions/v8.0.43")
        try Data("host: 127.0.0.1\n".utf8).write(to: root.appendingPathComponent("config.yaml"))
        let ids = ["gemini-3.8-flash-high", "gemini-4-argon-medium", "claude-opus-5-5-high", "gpt-oss-120b-medium"]
        let initial: [String: Any] = ["type": "antigravity", "email": "fixture@example.invalid", "access_token": "fixture-token",
            "disabled": false, "proxy_url": "http://127.0.0.1:1", "project_id": "fixture-project",
            "antigravity_capability_hints": ["model_ids": ids, "project_id": "fixture-project", "endpoint": "https://daily-cloudcode-pa.googleapis.com"]]
        func q(_ id: String, _ value: Double) -> AntigravityProvider.ModelQuota {
            .init(id: id, label: id, remainingPercent: value, resetAt: nil, providerLabel: nil)
        }
        func updated(_ input: [String: Any], _ quotas: [AntigravityProvider.ModelQuota], _ global: [String] = []) throws -> [String: Any] {
            guard let result = try AntigravityPoolCircuitBreaker.updatedCredential(input, models: quotas, global: global) else {
                throw NSError(domain: "Unexpected skipped credential", code: 1)
            }
            return result
        }
        func excluded(_ input: [String: Any]) -> [String] { input["excluded_models"] as? [String] ?? [] }
        func expectFailure(_ body: () throws -> Void) throws {
            do { try body() } catch { checks += 1; return }
            throw NSError(domain: "Expected fail-closed error", code: 1)
        }
        let screenshot = [q("gemini-weekly", 99), q("gemini-5h", 98), q("3p-weekly", 29), q("3p-5h", 0), q("gemini-argon-wtu-weekly", 0)]
        let blocked = try updated(initial, screenshot)
        try check(excluded(blocked) == [ids[1], ids[2], ids[3]].sorted(), "Screenshot: isolate pools")
        try check(blocked["disabled"] as? Bool == false, "Keep account enabled")
        try check(NSDictionary(dictionary: blocked["antigravity_capability_hints"] as! [String: Any]).isEqual(to: initial["antigravity_capability_hints"] as! [String: Any]), "Never destroy hints")
        let argonOnly = try updated(blocked, [q("3p-5h", 5.000001)])
        try check(excluded(argonOnly) == [ids[1]], "Independent recovery")
        let recovered = try updated(argonOnly, [q("gemini-argon-wtu-weekly", 3.000001)])
        try check(recovered["excluded_models"] == nil, "Restore global inheritance")
        try check(recovered["aiusage_pool_breaker"] == nil, "Remove owned state")
        try check(excluded(try updated(initial, [q("gemini-weekly", 3.16149)])).isEmpty, "Do not floor threshold")
        try check(excluded(try updated(initial, [q("gemini-weekly", 3)]) ) == [ids[0]], "Exact weekly boundary")
        try check(excluded(try updated(initial, [q("3p-5h", 5)]) ) == [ids[2], ids[3]].sorted(), "Exact 5h boundary")
        try check(excluded(try updated(initial, [q("gemini-argon-wtu-weekly", 3)])) == [ids[1]], "Argon-only trip")
        let allBlocked = try updated(initial, [q("gemini-weekly", 0), q("3p-weekly", 0), q("gemini-argon-wtu-weekly", 0)])
        try check(excluded(allBlocked) == ids.sorted() && allBlocked["disabled"] as? Bool == false, "All pools use model exclusions, never whole-account disable")
        let missing = try updated(try updated(initial, [q("gemini-weekly", 0), q("gemini-5h", 0)]), [q("gemini-5h", 99)])
        try check(excluded(missing) == [ids[0]], "Missing weekly window cannot recover")
        var manual = blocked; manual["disabled"] = true
        try check(try AntigravityPoolCircuitBreaker.updatedCredential(manual, models: [q("3p-5h", 99)], global: []) == nil, "Respect manual pause")
        var legacy = initial; legacy["disabled"] = true; legacy["circuit_breaker_tripped"] = true
        try check(try updated(legacy, screenshot)["disabled"] as? Bool == false, "Migrate legacy breaker pause")
        try expectFailure { _ = try updated(legacy, [q("3p-5h", 99)]) }
        let healthy = [q("gemini-weekly", 99), q("gemini-5h", 99), q("3p-weekly", 99), q("3p-5h", 99)]
        for missingIndex in healthy.indices {
            try expectFailure { _ = try updated(legacy, healthy.enumerated().filter { $0.offset != missingIndex }.map(\.element)) }
        }
        try expectFailure { _ = try updated(legacy, [q("gemini-5h", 99), q("3p-5h", 99)]) }
        try check(try updated(legacy, healthy)["disabled"] as? Bool == false, "Migrate only with complete healthy windows")
        try check(try updated(legacy, [q("gemini-weekly", 0), q("3p-5h", 0)])["disabled"] as? Bool == false, "Missing windows safe if their pool stays blocked")
        legacy.removeValue(forKey: "antigravity_capability_hints")
        try expectFailure { _ = try updated(legacy, screenshot) }
        var user = initial; user["excluded_models"] = [ids[2], "manual-model"]
        try check(try updated(try updated(user, [q("3p-5h", 0)], ["ignored-global"]), [q("3p-5h", 99)])["excluded_models"] as? [String] == [ids[2], "manual-model"], "Preserve original user policy")
        let global = try updated(initial, [q("3p-5h", 0)], ["old-global"])
        try check(excluded(global).contains("old-global"), "Preserve inherited policy during trip")
        let nextGlobal = try updated(global, [q("3p-5h", 0)], ["new-global"])
        try check(excluded(nextGlobal).contains("new-global") && !excluded(nextGlobal).contains("old-global"), "Refresh inherited policy")
        var blanks = initial; blanks["excluded_models"] = ["", "  ", "\n"]
        let blankBlocked = try updated(blanks, [q("3p-5h", 0)], ["gemini-2.5-pro"])
        try check(excluded(blankBlocked).contains("gemini-2.5-pro"), "Whitespace baseline inherits global exclusions")
        try check(try updated(blankBlocked, [q("3p-5h", 99)])["excluded_models"] as? [String] == ["", "  ", "\n"], "Restore raw whitespace baseline")
        var conflict = blocked; conflict["excluded_models"] = ["manual-edit"]
        try expectFailure { _ = try updated(conflict, screenshot) }
        try check(try AntigravityPoolCircuitBreaker.globalExclusions("'excluded-models' :\n  'antigravity':\n    - 'gemini-2.5-*' # comment\n") == ["gemini-2.5-*"], "Read quoted YAML policy")
        let indentedGlobal = try AntigravityPoolCircuitBreaker.globalExclusions("  oauth-excluded-models:\n    antigravity:\n      - gemini-2.5-pro\n")
        try check(indentedGlobal == ["gemini-2.5-pro"], "Read uniformly indented YAML root")
        try check(excluded(try updated(initial, [q("3p-5h", 0)], indentedGlobal)).contains("gemini-2.5-pro"), "Indented policy survives overlay")
        try check(try AntigravityPoolCircuitBreaker.globalExclusions(#""oauth-\u0065xcluded-models":"# + "\n  antigravity:\n    - gemini-2.5-pro\n") == ["gemini-2.5-pro"], "Decode escaped exclusion key")
        try check(try AntigravityPoolCircuitBreaker.globalExclusions("oauth-excluded-models:\n  antigravity:\n    - old\nexcluded-models: {}\n").isEmpty, "V8 policy takes precedence")
        for invalid in ["excluded-models: {antigravity: [claude-*]}", "excluded-models:\n  antigravity: *rules", "<<: *defaults"] {
            try expectFailure { _ = try AntigravityPoolCircuitBreaker.globalExclusions(invalid) }
        }
        for prefix in ["%YAML 1.1\n---\n", "--- # unsupported marker comment\n", "&root\n", "!!map\n"] {
            try expectFailure { _ = try AntigravityPoolCircuitBreaker.globalExclusions(prefix + "  oauth-excluded-models:\n    antigravity:\n      - gemini-2.5-pro\n") }
        }
        try expectFailure { _ = try AntigravityPoolCircuitBreaker.globalExclusions(#"{"oauth-excluded-models":{"antigravity":["gemini-2.5-pro"]}}"#) }
        try check(try AntigravityPoolCircuitBreaker.globalExclusions("\u{FEFF}oauth-excluded-models:\n  antigravity:\n    - gemini-2.5-pro\n") == ["gemini-2.5-pro"], "Read BOM-prefixed policy")
        let a = auth.appendingPathComponent("aiusage-antigravity-a.json")
        let b = auth.appendingPathComponent("aiusage-antigravity-b.json")
        let data = try JSONSerialization.data(withJSONObject: initial, options: [.sortedKeys])
        try data.write(to: a); try data.write(to: b)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: a.path)
        let off = try AntigravityPoolCircuitBreaker.sync(targets: [a], models: screenshot, runtime: root)
        try check(off == nil && Data(contentsOf: a) == data, "Default off is a byte-identical no-op")
        try Data(#"{"enabled":true}"#.utf8).write(to: root.appendingPathComponent("pool-protection.json"))
        _ = try AntigravityPoolCircuitBreaker.sync(targets: [a], models: screenshot, runtime: root)
        try check(try Data(contentsOf: b) == data, "Other account untouched")
        let once = try Data(contentsOf: a)
        _ = try AntigravityPoolCircuitBreaker.sync(targets: [a], models: screenshot, runtime: root)
        try check(try Data(contentsOf: a) == once, "Idempotent poll")
        let permissions = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? Int
        try check(permissions == 0o600, "Preserve credential file permissions")
        try expectFailure { _ = try AntigravityPoolCircuitBreaker.sync(targets: [root.appendingPathComponent("missing")], models: screenshot, runtime: root) }
        // Generated through production code for the optional isolated CPA hot-reload proof.
        try data.write(to: root.appendingPathComponent("before.json"))
        try once.write(to: root.appendingPathComponent("blocked.json"))
        try JSONSerialization.data(withJSONObject: recovered).write(to: root.appendingPathComponent("recovered.json"))
        let codex = auth.appendingPathComponent("codex.json")
        try JSONSerialization.data(withJSONObject: ["disabled": false, "type": "codex"]).write(to: codex)
        _ = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [codex], shouldTrip: true, reason: "fixture")
        let codexTrip = try JSONSerialization.jsonObject(with: Data(contentsOf: codex)) as! [String: Any]
        try check(codexTrip["disabled"] as? Bool == true, "Codex whole-account breaker unchanged")
        _ = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [codex], shouldTrip: false, reason: "fixture")
        let codexRecovered = try JSONSerialization.jsonObject(with: Data(contentsOf: codex)) as! [String: Any]
        try check(codexRecovered["disabled"] as? Bool == false, "Codex recovery unchanged")
        // Do not expose the Codex fixture to the Antigravity routing integration.
        try FileManager.default.removeItem(at: codex)
        // End-to-end backend path: AuthImports -> grouped quota -> CPA credential -> normalizer.
        let home = root.appendingPathComponent("fixture-home")
        let runtime = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI")
        try FileManager.default.createDirectory(at: runtime.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: runtime.appendingPathComponent("current").path, withDestinationPath: "versions/v8.0.43")
        try Data("host: 127.0.0.1\n".utf8).write(to: runtime.appendingPathComponent("config.yaml"))
        let destination = runtime.appendingPathComponent("auth/aiusage-antigravity-fixture.json")
        try data.write(to: destination)
        let imports = home.appendingPathComponent("AuthImports")
        try FileManager.default.createDirectory(at: imports, withIntermediateDirectories: true)
        let source = imports.appendingPathComponent("fixture.json")
        try data.write(to: source)
        StubURLProtocol.install(hosts: ["googleapis.com"])
        defer { StubURLProtocol.uninstall() }
        StubURLProtocol.respond(AntigravityProvider.loadCodeAssistURL, body: "{}")
        StubURLProtocol.respond(AntigravityProvider.quotaSummaryURLs[0], body: #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.99}]},{"displayName":"Claude and GPT models","buckets":[{"bucketId":"3p-5h","window":"5h","resetTime":"2026-10-26T00:00:00Z"}]},{"displayName":"Gemini 4 Argon","buckets":[{"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.0,"resetTime":"2026-10-26T00:00:00Z"}]}]}"#)
        let provider = AntigravityProvider(homeDirectory: home.path)
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("current"))
        try FileManager.default.createSymbolicLink(atPath: runtime.appendingPathComponent("current").path, withDestinationPath: "versions/v7.2.67")
        let offUsage = try await provider.fetchUsage(with: .init(providerId: "antigravity", authMethod: .authFile, credential: source.path))
        try check(offUsage.extra["circuitBreakerError"] == nil, "Default off never warns on old CPA")
        try check(try Data(contentsOf: destination) == data, "Default off provider leaves credential byte-identical")
        try expectFailure { try AntigravityPoolProtectionSettings.setEnabled(true, homeDirectory: home.path) }
        try FileManager.default.removeItem(at: runtime.appendingPathComponent("current"))
        try FileManager.default.createSymbolicLink(atPath: runtime.appendingPathComponent("current").path, withDestinationPath: "versions/v8.0.43")
        try AntigravityPoolProtectionSettings.setEnabled(true, homeDirectory: home.path)
        let usage = try await provider.fetchUsage(with: .init(providerId: "antigravity", authMethod: .authFile, credential: source.path))
        try check(usage.extra["circuitBreakerPartialTripped"]?.value as? Bool == true, "Provider propagates partial state")
        let payload = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        try check(excluded(payload) == [ids[1], ids[2], ids[3]].sorted(), "AuthImports matches CPA account")
        try check(try Data(contentsOf: source) == data, "Do not alter imported credential")
        let summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        try check(summary.statusLabel == "Pools Paused: argon, claude", "Normalizer reports exact pools")
        try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        let disabled = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        try check(disabled["excluded_models"] == nil && disabled["aiusage_pool_breaker"] == nil, "Disable restores original inheritance")
        let afterOff = try Data(contentsOf: destination)
        try check(try AntigravityPoolCircuitBreaker.sync(targets: [destination], models: screenshot, runtime: runtime) == nil, "Stale fetch cannot reapply after opt-out")
        try check(try Data(contentsOf: destination) == afterOff, "Opt-out remains byte-identical after stale fetch")
        // Opt-in boundary and shared-writer checks run without XCTest/Xcode.
        let setting = runtime.appendingPathComponent("pool-protection.json")
        try Data("{malformed".utf8).write(to: setting)
        try check(!AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path), "Malformed setting defaults off")
        try check(try AntigravityPoolCircuitBreaker.sync(targets: [destination], models: screenshot, runtime: runtime) == nil, "Malformed setting cannot mutate credentials")
        try AntigravityPoolProtectionSettings.setEnabled(true, homeDirectory: home.path)
        try check(try FileManager.default.attributesOfItem(atPath: setting.path)[.posixPermissions] as? Int == 0o600, "Setting is owner-only")
        var manualBaseline = initial; manualBaseline["excluded_models"] = ["manual-model"]
        try JSONSerialization.data(withJSONObject: manualBaseline).write(to: destination)
        _ = try AntigravityPoolCircuitBreaker.sync(targets: [destination], models: screenshot, runtime: runtime)
        try AntigravityCredentialFile.update(destination) { current in
            var next = current; next["disabled"] = true; next["refresh_token"] = "rotated-fixture"; return next
        }
        try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        let cleaned = try JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as! [String: Any]
        try check(cleaned["excluded_models"] as? [String] == ["manual-model"], "Cleanup restores explicit manual exclusions")
        try check(cleaned["disabled"] as? Bool == true && cleaned["refresh_token"] as? String == "rotated-fixture", "Cleanup preserves manual pause and fresh token")
        try AntigravityPoolProtectionSettings.setEnabled(true, homeDirectory: home.path)
        try JSONSerialization.data(withJSONObject: conflict).write(to: destination)
        let conflicting = try Data(contentsOf: destination)
        try expectFailure { try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path) }
        try check(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path), "Cleanup conflict keeps setting enabled")
        try check(try Data(contentsOf: destination) == conflicting, "Cleanup conflict preserves external exclusions")
        let external = try JSONSerialization.data(withJSONObject: ["type": "antigravity", "refresh_token": "newer-fixture"])
        try expectFailure {
            try AntigravityCredentialFile.update(destination) { current in
                try external.write(to: destination, options: .atomic)
                var stale = current; stale["test-overlay"] = true; return stale
            }
        }
        try check(try Data(contentsOf: destination) == external, "Shared writer refuses intervening external replacement")
        // Upgrade from automatic protection: no setting, but persisted exclusions.
        let migrationHome = root.appendingPathComponent("migration-home")
        let migrationRuntime = AntigravityPoolProtectionSettings.runtime(migrationHome.path)
        let migrationAuth = migrationRuntime.appendingPathComponent("auth")
        try FileManager.default.createDirectory(at: migrationAuth, withIntermediateDirectories: true)
        let migrationFile = migrationAuth.appendingPathComponent("antigravity-old.json")
        let migrationSetting = migrationRuntime.appendingPathComponent("pool-protection.json")
        var inherited = blocked
        inherited["disabled"] = true
        inherited["refresh_token"] = "fresh-migration-token"
        let inheritedData = try JSONSerialization.data(withJSONObject: inherited)
        try inheritedData.write(to: migrationFile)
        try check(try AntigravityPoolProtectionSettings.hasResidualProtection(homeDirectory: migrationHome.path), "Upgrade attention detects owned exclusions without setting")
        try check(!AntigravityPoolProtectionSettings.isEnabled(homeDirectory: migrationHome.path), "Upgrade never auto-enables protection")
        try check(try Data(contentsOf: migrationFile) == inheritedData && !FileManager.default.fileExists(atPath: migrationSetting.path), "Attention read performs no credential or setting writes")
        try AntigravityPoolProtectionSettings.restorePreviousExclusions(homeDirectory: migrationHome.path)
        let restoredMigration = try JSONSerialization.jsonObject(with: Data(contentsOf: migrationFile)) as! [String: Any]
        try check(restoredMigration["excluded_models"] == nil && restoredMigration["aiusage_pool_breaker"] == nil, "Explicit Restore works with absent setting")
        try check(restoredMigration["disabled"] as? Bool == true && restoredMigration["refresh_token"] as? String == "fresh-migration-token", "Upgrade Restore preserves pause and token")
        try check(try !AntigravityPoolProtectionSettings.hasResidualProtection(homeDirectory: migrationHome.path) && !FileManager.default.fileExists(atPath: migrationSetting.path), "Restore clears attention without creating opt-in")
        try JSONSerialization.data(withJSONObject: conflict).write(to: migrationFile)
        let migrationConflict = try Data(contentsOf: migrationFile)
        try expectFailure { try AntigravityPoolProtectionSettings.restorePreviousExclusions(homeDirectory: migrationHome.path) }
        try check(try Data(contentsOf: migrationFile) == migrationConflict, "Explicit Restore refuses external exclusion conflict unchanged")
        for badBaseline: Any in ["invalid", 7, ["not": "a-list"]] {
            var invalid = blocked
            var state = invalid["aiusage_pool_breaker"] as! [String: Any]
            state["original_excluded_models"] = badBaseline
            invalid["aiusage_pool_breaker"] = state
            let invalidData = try JSONSerialization.data(withJSONObject: invalid)
            try invalidData.write(to: migrationFile)
            try expectFailure { try AntigravityPoolProtectionSettings.restorePreviousExclusions(homeDirectory: migrationHome.path) }
            try check(try Data(contentsOf: migrationFile) == invalidData, "Restore rejects invalid baseline unchanged")
        }
        try Data("{malformed".utf8).write(to: migrationFile)
        try expectFailure { _ = try AntigravityPoolProtectionSettings.hasResidualProtection(homeDirectory: migrationHome.path) }
        try check(try Data(contentsOf: migrationFile) == Data("{malformed".utf8), "Malformed attention check remains read-only")
        try FileManager.default.removeItem(at: migrationFile)
        try check(try !AntigravityPoolProtectionSettings.hasResidualProtection(homeDirectory: migrationHome.path), "Clean migration reports no residual protection")

        // Real provider flow, with every HTTP response intercepted by StubURLProtocol.
        let tokenHome = root.appendingPathComponent("token-home")
        try FileManager.default.createDirectory(at: tokenHome, withIntermediateDirectories: true)
        let tokenFile = tokenHome.appendingPathComponent("antigravity.json")
        var expired = initial
        expired["access_token"] = "token-A"
        expired["refresh_token"] = "refresh-fixture"
        expired["expired"] = "2020-01-01T00:00:00Z"
        let expiredData = try JSONSerialization.data(withJSONObject: expired)
        let envKeys = ["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID", "AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_SECRET"]
        let savedEnvironment = envKeys.map { ProcessInfo.processInfo.environment[$0] }
        for key in envKeys { setenv(key, "offline-fixture", 1) }
        defer {
            for (key, value) in zip(envKeys, savedEnvironment) {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }
        let healthyBody = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.99}]}]}"#
        StubURLProtocol.respond(AntigravityProvider.quotaSummaryURLs[0]) { request in
            let token = request.headers.first { $0.key.lowercased() == "authorization" }?.value
            return token == "Bearer token-B" ? (401, "{}") : (200, healthyBody)
        }
        for externalWrite in [false, true] {
            try expiredData.write(to: tokenFile)
            var refreshes = 0
            StubURLProtocol.respond(AntigravityProvider.oauthRefreshURL) { _ in
                refreshes += 1
                if refreshes == 2 && externalWrite {
                    var external = expired
                    external["access_token"] = "external-token"
                    external["refresh_token"] = "external-refresh"
                    external["manual-field"] = "preserved"
                    try! JSONSerialization.data(withJSONObject: external).write(to: tokenFile, options: .atomic)
                }
                return (200, refreshes == 1
                    ? #"{"access_token":"token-B","expires_in":3600}"#
                    : #"{"access_token":"token-C","expires_in":3600}"#)
            }
            let tokenProvider = AntigravityProvider(homeDirectory: tokenHome.path)
            _ = try await tokenProvider.fetchUsage(with: .init(providerId: "antigravity", authMethod: .authFile, credential: tokenFile.path))
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: tokenFile)) as! [String: Any]
            try check(refreshes == 2, "Expired A refreshes B then retries unauthorized B with C")
            if externalWrite {
                try check(saved["access_token"] as? String == "external-token" && saved["refresh_token"] as? String == "external-refresh", "Retry persistence preserves external token replacement")
                try check(saved["manual-field"] as? String == "preserved", "Retry persistence preserves external metadata")
            } else {
                try check(saved["access_token"] as? String == "token-C", "Second successful refresh commits C after its own B write")
                try check(saved["project_id"] as? String == "fixture-project", "Two refreshes preserve unrelated credential metadata")
            }
        }
        print("Pool circuit breaker: \(checks) checks passed (production backend, temporary credentials only)")
    }
}
