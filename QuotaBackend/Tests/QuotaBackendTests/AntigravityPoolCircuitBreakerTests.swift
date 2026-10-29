import XCTest
@testable import QuotaBackend

final class AntigravityPoolCircuitBreakerTests: XCTestCase {
    private let ids = ["gemini-3.8-flash-high", "gemini-4-argon-medium", "claude-opus-5-5-high", "gpt-oss-120b-medium"]

    private func credential() -> [String: Any] {
        ["type": "antigravity", "access_token": "fixture-token", "disabled": false, "aiusage_credential_id": "fixture",
         "antigravity_capability_hints": ["model_ids": ids, "project_id": "fixture-project",
                                          "endpoint": "https://daily-cloudcode-pa.googleapis.com"]]
    }

    private func quota(_ id: String, _ percent: Double) -> AntigravityProvider.ModelQuota {
        .init(id: id, label: id, remainingPercent: percent, resetAt: nil, providerLabel: nil)
    }

    private func update(_ json: [String: Any], _ models: [AntigravityProvider.ModelQuota], global: [String] = []) throws -> [String: Any] {
        let result = try AntigravityPoolCircuitBreaker.updatedCredential(json, models: models, global: global)
        return try XCTUnwrap(result)
    }

    func testScreenshotBlocksClaudeAndArgonButKeepsGeminiAndAccountActive() throws {
        let input = credential()
        let result = try update(input, [quota("gemini-weekly", 99), quota("gemini-5h", 98),
                                        quota("3p-weekly", 29), quota("3p-5h", 0), quota("gemini-argon-wtu-weekly", 0)])
        XCTAssertEqual(result["disabled"] as? Bool, false)
        XCTAssertEqual(result["excluded_models"] as? [String], [ids[1], ids[2], ids[3]].sorted())
        XCTAssertEqual(result["circuit_breaker_pools"] as? [String], ["argon", "claude"])
        XCTAssertTrue(NSDictionary(dictionary: result["antigravity_capability_hints"] as! [String: Any])
            .isEqual(to: input["antigravity_capability_hints"] as! [String: Any]))
    }

    func testIndependentRecoveryAndExactFloatThresholds() throws {
        let input = try update(credential(), [quota("gemini-weekly", 3.1614915), quota("3p-5h", 5), quota("gemini-argon-wtu-weekly", 3)])
        XCTAssertEqual(input["circuit_breaker_pools"] as? [String], ["argon", "claude"])
        let recoveredClaude = try update(input, [quota("3p-5h", 5.00001)])
        XCTAssertEqual(recoveredClaude["circuit_breaker_pools"] as? [String], ["argon"])
        let result = try update(recoveredClaude, [quota("gemini-argon-wtu-weekly", 3.00001)])
        XCTAssertNil(result["excluded_models"])
        XCTAssertNil(result["aiusage_pool_breaker"])
        let weeklyTrip = try update(result, [quota("gemini-weekly", 3.0)])
        XCTAssertEqual(weeklyTrip["excluded_models"] as? [String], [ids[0]])
    }

    func testDoesNotRecoverWeeklyBlockFromOnlyHealthyFiveHourWindow() throws {
        let blocked = try update(credential(), [quota("gemini-weekly", 0), quota("gemini-5h", 0)])
        let partial = try update(blocked, [quota("gemini-5h", 99)])
        XCTAssertEqual(partial["circuit_breaker_pools"] as? [String], ["gemini"])
        let recovered = try update(partial, [quota("gemini-weekly", 99)])
        XCTAssertNil(recovered["excluded_models"])
    }

    func testPreservesUserExclusionsAndRestoresInheritance() throws {
        var manual = credential()
        manual["excluded_models"] = [ids[2], "custom-model"]
        let blocked = try update(manual, [quota("3p-5h", 0)], global: ["global-ignored-because-account-overrides"])
        XCTAssertFalse((blocked["excluded_models"] as! [String]).contains("global-ignored-because-account-overrides"))
        let recovered = try update(blocked, [quota("3p-5h", 100)])
        XCTAssertEqual(recovered["excluded_models"] as? [String], [ids[2], "custom-model"])
        let inherited = try update(credential(), [quota("3p-5h", 0)], global: ["gemini-2.5-*"])
        XCTAssertTrue((inherited["excluded_models"] as! [String]).contains("gemini-2.5-*"))
        let changedGlobal = try update(inherited, [quota("3p-5h", 0)], global: ["gemini-3-*"])
        XCTAssertFalse((changedGlobal["excluded_models"] as! [String]).contains("gemini-2.5-*"))
        XCTAssertTrue((changedGlobal["excluded_models"] as! [String]).contains("gemini-3-*"))
        XCTAssertNil(try update(changedGlobal, [quota("3p-5h", 100)])["excluded_models"])
    }

    func testManualPauseIsNeverReenabledIncludingAfterPartialTrip() throws {
        var input = credential()
        input["disabled"] = true
        XCTAssertNil(try AntigravityPoolCircuitBreaker.updatedCredential(input, models: [quota("3p-5h", 99)], global: []))
        var partial = try update(credential(), [quota("3p-5h", 0)])
        partial["disabled"] = true
        XCTAssertNil(try AntigravityPoolCircuitBreaker.updatedCredential(partial, models: [quota("3p-5h", 99)], global: []))
    }

    func testLegacyWholeAccountPauseMigratesOnlyWhenPoolProtectionCanBeApplied() throws {
        var input = credential()
        input["disabled"] = true
        input["circuit_breaker_tripped"] = true
        XCTAssertThrowsError(try update(input, [quota("3p-5h", 0)]))
        XCTAssertEqual(try update(input, [quota("gemini-weekly", 99), quota("gemini-5h", 99), quota("3p-5h", 0)])["disabled"] as? Bool, false)
        input.removeValue(forKey: "antigravity_capability_hints")
        XCTAssertThrowsError(try update(input, [quota("3p-5h", 0)]))
        XCTAssertEqual(input["disabled"] as? Bool, true)
    }

    func testLegacyMigrationNeedsAllHealthyCoreWindowsOrBlockedPoolEvidence() throws {
        var input = credential()
        input["disabled"] = true
        input["circuit_breaker_tripped"] = true
        let healthy = [quota("gemini-weekly", 99), quota("gemini-5h", 99), quota("3p-weekly", 99), quota("3p-5h", 99)]
        for missing in healthy.indices {
            XCTAssertThrowsError(try update(input, healthy.enumerated().filter { $0.offset != missing }.map(\.element)))
        }
        XCTAssertThrowsError(try update(input, [quota("gemini-5h", 99), quota("3p-5h", 99)]))
        XCTAssertEqual(try update(input, healthy)["disabled"] as? Bool, false)
        XCTAssertEqual(try update(input, [quota("gemini-weekly", 0), quota("3p-5h", 0)])["disabled"] as? Bool, false)
    }

    func testIndentedAndEscapedGlobalPoliciesAndBlankBaselinePreserveInheritance() throws {
        let policy = try AntigravityPoolCircuitBreaker.globalExclusions("  oauth-excluded-models:\n    antigravity:\n      - gemini-2.5-pro\n")
        XCTAssertEqual(policy, ["gemini-2.5-pro"])
        XCTAssertEqual(try AntigravityPoolCircuitBreaker.globalExclusions(#""oauth-\u0065xcluded-models":"# + "\n  antigravity:\n    - gemini-2.5-pro\n"), policy)
        var input = credential()
        input["excluded_models"] = ["", "  "]
        let result = try update(input, [quota("3p-5h", 0)], global: policy)
        XCTAssertTrue((result["excluded_models"] as! [String]).contains("gemini-2.5-pro"))
        XCTAssertEqual(try update(result, [quota("3p-5h", 99)])["excluded_models"] as? [String], ["", "  "])
    }

    func testExternalEditsAndInvalidPolicyFailWithoutChangingCredential() throws {
        var blocked = try update(credential(), [quota("3p-5h", 0)])
        blocked["excluded_models"] = ["manual-new-exclusion"]
        XCTAssertThrowsError(try update(blocked, [quota("3p-5h", 99)]))
        var malformed = credential()
        malformed["excluded_models"] = "claude-*"
        XCTAssertThrowsError(try update(malformed, [quota("3p-5h", 0)]))
    }

    func testGlobalPolicyReaderPreservesV8PriorityAndRejectsUnsupportedYAML() throws {
        let config = """
        oauth-excluded-models:
          antigravity:
            - 'legacy-*'
        excluded-models:
          antigravity:
            - "gemini-2.5-*" # preserve me
            - custom-model
          codex:
            - gpt-5
        """
        XCTAssertEqual(try AntigravityPoolCircuitBreaker.globalExclusions(config), ["gemini-2.5-*", "custom-model"])
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.globalExclusions("oauth-excluded-models: {antigravity: [claude-*]}"))
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.globalExclusions("excluded-models:\n  antigravity: *rules"))
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.globalExclusions("<<: *defaults"))
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.globalExclusions("%YAML 1.1\n---\n  oauth-excluded-models:\n    antigravity:\n      - gemini-2.5-pro\n"))
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.globalExclusions("--- # unsupported marker\n  oauth-excluded-models:\n    antigravity:\n      - gemini-2.5-pro\n"))
        XCTAssertEqual(try AntigravityPoolCircuitBreaker.globalExclusions("\u{FEFF}oauth-excluded-models:\n  antigravity:\n    - gemini-2.5-pro\n"), ["gemini-2.5-pro"])
    }

    private func runtime() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pool-breaker-\(UUID())")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: directory.appendingPathComponent("current").path, withDestinationPath: "versions/v8.0.43")
        try Data("host: 127.0.0.1\n".utf8).write(to: directory.appendingPathComponent("config.yaml"))
        try Data(#"{"enabled":true}"#.utf8).write(to: directory.appendingPathComponent("pool-protection.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func testDiskSyncIsIdempotentAndAccountIsolatedAndReportsWriteFailures() throws {
        let root = try runtime()
        let a = root.appendingPathComponent("auth/a.json")
        let b = root.appendingPathComponent("auth/b.json")
        let data = try JSONSerialization.data(withJSONObject: credential())
        try data.write(to: a); try data.write(to: b)
        let outcome = try AntigravityPoolCircuitBreaker.sync(targets: [a], models: [quota("3p-5h", 0)], runtime: root)
        XCTAssertEqual(outcome?.blockedPools, ["claude"])
        XCTAssertEqual(try Data(contentsOf: b), data)
        let first = try Data(contentsOf: a)
        _ = try AntigravityPoolCircuitBreaker.sync(targets: [a], models: [quota("3p-5h", 0)], runtime: root)
        XCTAssertEqual(try Data(contentsOf: a), first)
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.sync(targets: [root.appendingPathComponent("missing")], models: [quota("3p-5h", 0)], runtime: root))
        try FileManager.default.removeItem(at: root.appendingPathComponent("current"))
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("current").path, withDestinationPath: "versions/v7.2.67")
        XCTAssertThrowsError(try AntigravityPoolCircuitBreaker.sync(targets: [b], models: [quota("3p-5h", 0)], runtime: root))
        XCTAssertEqual(try Data(contentsOf: b), data)
    }

    func testExplicitCredentialIdentityDoesNotMatchAnotherAccountWithSameEmail() throws {
        let root = try runtime()
        let auth = root.appendingPathComponent("auth")
        let a = auth.appendingPathComponent("a.json"), b = auth.appendingPathComponent("b.json")
        var first = credential(); first["email"] = "shared@example.invalid"
        var second = first; second["aiusage_credential_id"] = "another-credential"
        let source = try JSONSerialization.data(withJSONObject: first)
        try source.write(to: a)
        try JSONSerialization.data(withJSONObject: second).write(to: b)
        let targets = try AntigravityPoolCircuitBreaker.targets(runtime: root, source: root.appendingPathComponent("AuthImports/fixture.json"), credentialID: "fixture", sourceData: source)
        XCTAssertEqual(targets.map { $0.resolvingSymlinksInPath() }, [a.resolvingSymlinksInPath()])
    }

    func testDefaultOffDoesNotInspectUnsupportedCPAOrChangeCredentials() throws {
        let root = try runtime()
        try FileManager.default.removeItem(at: root.appendingPathComponent("pool-protection.json"))
        try FileManager.default.removeItem(at: root.appendingPathComponent("current"))
        let file = root.appendingPathComponent("auth/a.json")
        let data = try JSONSerialization.data(withJSONObject: credential())
        try data.write(to: file)
        XCTAssertNil(try AntigravityPoolCircuitBreaker.sync(targets: [file], models: [quota("3p-5h", 0)], runtime: root))
        XCTAssertEqual(try Data(contentsOf: file), data)
        try Data("{malformed".utf8).write(to: root.appendingPathComponent("pool-protection.json"))
        XCTAssertNil(try AntigravityPoolCircuitBreaker.sync(targets: [file], models: [quota("3p-5h", 0)], runtime: root))
    }

    func testOptInToggleRestoresOnlyOwnedExclusionsAndDoesNotReapplyAfterOff() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pool-toggle-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = AntigravityPoolProtectionSettings.runtime(home.path)
        XCTAssertFalse(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
        XCTAssertThrowsError(try AntigravityPoolProtectionSettings.setEnabled(true, homeDirectory: home.path))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("current").path, withDestinationPath: "versions/v8.0.43")
        try Data("host: 127.0.0.1\n".utf8).write(to: root.appendingPathComponent("config.yaml"))
        try AntigravityPoolProtectionSettings.setEnabled(true, homeDirectory: home.path)
        XCTAssertTrue(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
        let file = root.appendingPathComponent("auth/a.json")
        var original = credential(); original["excluded_models"] = ["manual-model"]
        try JSONSerialization.data(withJSONObject: original).write(to: file)
        _ = try AntigravityPoolCircuitBreaker.sync(targets: [file], models: [quota("3p-5h", 0)], runtime: root)
        // A manual pause and a fresh token must survive cleanup.
        try AntigravityCredentialFile.update(file) { current in
            var next = current; next["disabled"] = true; next["refresh_token"] = "rotated-fixture"; return next
        }
        try Data("{unrelated-malformed".utf8).write(to: root.appendingPathComponent("auth/unrelated.json"))
        try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        XCTAssertFalse(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
        let result = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(result["excluded_models"] as? [String], ["manual-model"])
        XCTAssertEqual(result["disabled"] as? Bool, true)
        XCTAssertEqual(result["refresh_token"] as? String, "rotated-fixture")
        XCTAssertNil(result["aiusage_pool_breaker"])
        let off = try Data(contentsOf: file)
        XCTAssertNil(try AntigravityPoolCircuitBreaker.sync(targets: [file], models: [quota("3p-5h", 0)], runtime: root))
        XCTAssertEqual(try Data(contentsOf: file), off)
    }

    func testCleanupRefusesExternalExclusionEditAndKeepsOptInOn() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pool-conflict-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = AntigravityPoolProtectionSettings.runtime(home.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try Data(#"{"enabled":true}"#.utf8).write(to: root.appendingPathComponent("pool-protection.json"))
        let file = root.appendingPathComponent("auth/a.json")
        var blocked = try update(credential(), [quota("3p-5h", 0)])
        blocked["excluded_models"] = ["external-edit"]
        let data = try JSONSerialization.data(withJSONObject: blocked)
        try data.write(to: file)
        XCTAssertThrowsError(try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path))
        XCTAssertTrue(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
        XCTAssertEqual(try Data(contentsOf: file), data)
    }

    func testSharedWriterReadsFreshMetadataAndRefusesInterveningExternalWrite() throws {
        let root = try runtime(); let file = root.appendingPathComponent("auth/a.json")
        var latest = credential(); latest["refresh_token"] = "rotated-fixture"
        try JSONSerialization.data(withJSONObject: latest).write(to: file)
        try AntigravityCredentialFile.update(file) { current in
            XCTAssertEqual(current["refresh_token"] as? String, "rotated-fixture")
            var next = current; next["test-overlay"] = true; return next
        }
        let external = try JSONSerialization.data(withJSONObject: ["type": "antigravity", "refresh_token": "newer-fixture"])
        XCTAssertThrowsError(try AntigravityCredentialFile.update(file) { current in
            try external.write(to: file, options: .atomic)
            var stale = current; stale["test-overlay"] = false; return stale
        })
        XCTAssertEqual(try Data(contentsOf: file), external)
    }

    func testUnreadableCredentialKeepsProtectionEnabledUntilCleanupCanRetry() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pool-unreadable-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = AntigravityPoolProtectionSettings.runtime(home.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try Data(#"{"enabled":true}"#.utf8).write(to: root.appendingPathComponent("pool-protection.json"))
        let file = root.appendingPathComponent("auth/a.json")
        let blocked = try update(credential(), [quota("3p-5h", 0)])
        let before = try JSONSerialization.data(withJSONObject: blocked)
        try before.write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path) }

        XCTAssertThrowsError(try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path))
        XCTAssertTrue(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertEqual(try Data(contentsOf: file), before)

        try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        XCTAssertFalse(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
        let cleaned = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(cleaned["excluded_models"])
        XCTAssertNil(cleaned["aiusage_pool_breaker"])
    }

    func testDisablingRetriesCleanupWhenSettingAlreadySaysOff() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pool-stranded-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        let root = AntigravityPoolProtectionSettings.runtime(home.path)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("auth"), withIntermediateDirectories: true)
        try Data(#"{"enabled":false}"#.utf8).write(to: root.appendingPathComponent("pool-protection.json"))
        let file = root.appendingPathComponent("auth/a.json")
        var original = credential()
        original["excluded_models"] = ["manual-model"]
        let blocked = try update(original, [quota("3p-5h", 0)])
        try JSONSerialization.data(withJSONObject: blocked).write(to: file)

        try AntigravityPoolProtectionSettings.setEnabled(false, homeDirectory: home.path)
        let cleaned = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(cleaned["excluded_models"] as? [String], ["manual-model"])
        XCTAssertNil(cleaned["aiusage_pool_breaker"])
        XCTAssertFalse(AntigravityPoolProtectionSettings.isEnabled(homeDirectory: home.path))
    }

}
