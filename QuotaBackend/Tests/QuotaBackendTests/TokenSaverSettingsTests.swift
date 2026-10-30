import XCTest
@testable import QuotaBackend

final class TokenSaverSettingsTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    func testDefaultsAndScopeCannotBeDisabled() throws {
        let home = try temporaryHome()
        XCTAssertEqual(try TokenSaverSettingsStore.load(home: home), TokenSaverSettings())
        let value = try JSONDecoder().decode(TokenSaverSettings.self, from: Data("{\"codingOnlyScope\":false}".utf8))
        XCTAssertTrue(value.codingOnlyScope)
        XCTAssertFalse(value.cavemanEnabled)
    }
    func testRoundTripAndExactRuleRestoration() throws {
        let home = try temporaryHome()
        let original = Data("# User instructions\nKeep this exact.\n\n".utf8)
        let codex = TokenSaverAgentRules.rulePaths(home: home)[2]
        try TokenSaverSettingsStore.replace(codex, data: original)
        var value = TokenSaverSettings()
        value.rtkEnabled = true
        value.cavemanMode = .ultra
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertEqual(try TokenSaverSettingsStore.load(home: home), value)
        for url in TokenSaverAgentRules.rulePaths(home: home) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(text.contains("run_command"))
            XCTAssertTrue(text.contains("RonC"))
            XCTAssertTrue(text.contains("Zalo"))
        }
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: TokenSaverSettingsStore.settingsURL(home: home).path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        value.rtkEnabled = false
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertEqual(try Data(contentsOf: codex), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TokenSaverAgentRules.rulePaths(home: home)[0].path))
    }
    func testForeignManagedBlockAndCorruptionFailWithoutChanges() throws {
        let home = try temporaryHome()
        let codex = TokenSaverAgentRules.rulePaths(home: home)[2]
        let original = Data("<!-- AIUsage Token Saver BEGIN -->\nUser-owned edited block".utf8)
        try TokenSaverSettingsStore.replace(codex, data: original)
        var value = TokenSaverSettings(); value.rtkEnabled = true
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertEqual(try Data(contentsOf: codex), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: TokenSaverAgentRules.rulePaths(home: home)[0].path))
        let settings = TokenSaverSettingsStore.settingsURL(home: home)
        try TokenSaverSettingsStore.replace(settings, data: Data("invalid".utf8))
        XCTAssertThrowsError(try TokenSaverSettingsStore.load(home: home))
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertEqual(try Data(contentsOf: settings), Data("invalid".utf8))
    }
    func testEditedOwnedRulesAreNotOverwritten() throws {
        let home = try temporaryHome()
        var value = TokenSaverSettings(); value.rtkEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let url = TokenSaverAgentRules.rulePaths(home: home)[1]
        let edited = try String(contentsOf: url, encoding: .utf8).replacingOccurrences(of: "stdlib", with: "stdlib2") + "custom"
        // Change content inside ownership block rather than unrelated trailing text.
        let changed = edited.replacingOccurrences(of: "run_command", with: "custom_command")
        try Data(changed.utf8).write(to: url)
        value.rtkEnabled = false
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), changed)
        XCTAssertTrue(try TokenSaverSettingsStore.load(home: home).rtkEnabled)
    }
    func testCavemanModesAndPonytailApplyWithoutRTK() throws {
        let home = try temporaryHome()
        var value = TokenSaverSettings()
        value.cavemanEnabled = true
        value.ponytailEnabled = true
        for mode in TokenSaverSettings.CavemanMode.allCases {
            value.cavemanMode = mode
            try TokenSaverSettingsStore.save(value, home: home)
            for path in TokenSaverAgentRules.rulePaths(home: home) {
                let rule = try String(contentsOf: path, encoding: .utf8)
                XCTAssertTrue(rule.contains("Caveman active mode: " + mode.rawValue))
                XCTAssertTrue(rule.contains("Ponytail"))
                XCTAssertTrue(rule.contains("Zalo"))
                XCTAssertFalse(rule.contains("rtk git"))
            }
        }
        try TokenSaverSettingsStore.save(.init(), home: home)
        for path in TokenSaverAgentRules.rulePaths(home: home) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        }
    }
    func testManagedWrapperIsExecutableAndRestored() throws {
        let home = try temporaryHome()
        var value = TokenSaverSettings(); value.rtkEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let wrapper = TokenSaverSettingsStore.settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("bin/token-saver-rtk")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: wrapper.path))
        let process = Process()
        process.executableURL = wrapper
        process.arguments = ["/usr/bin/printf", "%s", "original tool output"]
        // No RTK on PATH: original command runs once, without any rewrites.
        process.environment = ["PATH": "/usr/bin:/bin"]
        let pipe = Pipe(); process.standardOutput = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertEqual(String(data: output, encoding: .utf8), "original tool output")
        value.rtkEnabled = false
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wrapper.path))
    }
    func testSymlinkedParentRejected() throws {
        let home = try temporaryHome(), other = try temporaryHome()
        try FileManager.default.createSymbolicLink(at: home.appendingPathComponent(".codex"), withDestinationURL: other)
        var value = TokenSaverSettings(); value.rtkEnabled = true
        XCTAssertThrowsError(try TokenSaverSettingsStore.save(value, home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("AGENTS.md").path))
    }
    func testCompactPolicyBoundsUpstreamTextAndPreservesProvenance() throws {
        let home = try temporaryHome()
        let store = TokenSaverReleaseStore(root: home.appendingPathComponent("Library/Application Support/AIUsage/Rules"))
        let commit = String(repeating: "a", count: 40)
        let prose = Data(("name: fixture\n" + String(repeating: "VERBOSE_UPSTREAM_DO_NOT_INLINE\n", count: 1800)).utf8)
        for tool in [TokenSaverReleaseTool.caveman, .ponytail] {
            try store.stage(.init(tool: tool, version: "v1", commit: commit, isRelease: true), markdown: prose)
        }
        var value = TokenSaverSettings(); value.rtkEnabled = true; value.cavemanEnabled = true; value.ponytailEnabled = true
        for mode in TokenSaverSettings.CavemanMode.allCases {
            value.cavemanMode = mode
            try TokenSaverSettingsStore.save(value, home: home)
            let block = try String(contentsOf: TokenSaverAgentRules.rulePaths(home: home)[2], encoding: .utf8)
            XCTAssertTrue(block.utf8.count < 2400)
            XCTAssertFalse(block.contains("VERBOSE_UPSTREAM_DO_NOT_INLINE"))
            XCTAssertTrue(block.contains(commit))
            XCTAssertTrue(block.contains("not injected"))
            XCTAssertTrue(block.contains("signed history"))
            XCTAssertTrue(block.contains("accessibility"))
            XCTAssertTrue(block.contains("diagnostics"))
            XCTAssertTrue(block.contains("all other non-coding"))
        }
        XCTAssertEqual(try store.staged(.ponytail)?.markdown, prose)
    }
    func testLegacyOwnedLedgerMigratesAndRestoresUserInstructions() throws {
        let home = try temporaryHome(), codex = TokenSaverAgentRules.rulePaths(home: home)[2]
        let ledger = TokenSaverSettingsStore.settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt")
        let legacy = "<!-- AIUsage Token Saver BEGIN -->\n" + String(repeating: "old full upstream prose\n", count: 500) + "<!-- AIUsage Token Saver END -->"
        try TokenSaverSettingsStore.replace(ledger, data: Data(legacy.utf8))
        try TokenSaverSettingsStore.replace(codex, data: Data(("# Keep user instructions\n" + legacy).utf8))
        var value = TokenSaverSettings(); value.ponytailEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertFalse(try String(contentsOf: codex, encoding: .utf8).contains("old full upstream prose"))
        try TokenSaverSettingsStore.save(.init(), home: home)
        XCTAssertEqual(try String(contentsOf: codex, encoding: .utf8), "# Keep user instructions")
    }
    func testHermesExportIsExplicitAndDoesNotTouchOtherProfiles() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        let config = root.appendingPathComponent("config.yaml")
        let bot = home.appendingPathComponent(".hermes/profiles/bot-huy/workspace/HERMES.md")
        let global = home.appendingPathComponent("HERMES.md")
        try TokenSaverSettingsStore.replace(bot, data: Data("Keep bot exact".utf8))
        try TokenSaverSettingsStore.replace(global, data: Data("Keep global exact".utf8))
        var value = TokenSaverSettings(); value.rtkEnabled = true; value.cavemanEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        try TokenSaverSettingsStore.replace(config, data: Data("terminal: fixture-only\n".utf8))
        let target = try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("RTK:"))
        XCTAssertEqual(try String(contentsOf: bot, encoding: .utf8), "Keep bot exact")
        XCTAssertEqual(try String(contentsOf: global, encoding: .utf8), "Keep global exact")
        XCTAssertEqual(try String(contentsOf: config, encoding: .utf8), "terminal: fixture-only\n")
        value.cavemanMode = .ultra
        try TokenSaverSettingsStore.save(value, home: home)
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertTrue(try String(contentsOf: target, encoding: .utf8).contains("Caveman active mode: ultra"))
        try TokenSaverSettingsStore.save(.init(), home: home)
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testHermesExportAdoptsExactManualSnapshotButRejectsEditsAndLinks() throws {
        let home = try temporaryHome(), other = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(root.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        var value = TokenSaverSettings(); value.ponytailEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let target = root.appendingPathComponent("workspace/HERMES.md")
        let ledger = TokenSaverSettingsStore.settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt")
        try TokenSaverSettingsStore.replace(target, data: Data(contentsOf: ledger) + Data("\n".utf8))
        try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
        let edited = try Data(contentsOf: target) + Data("user changes".utf8)
        try TokenSaverSettingsStore.replace(target, data: edited)
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        XCTAssertEqual(try Data(contentsOf: target), edited)
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: other.appendingPathComponent("HERMES.md"))
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.appendingPathComponent("HERMES.md").path))
    }
    func testHermesExportRequiresManagedExecutableWrapper() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(root.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        var value = TokenSaverSettings(); value.rtkEnabled = true
        try TokenSaverSettingsStore.save(value, home: home)
        let wrapper = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        try FileManager.default.removeItem(at: wrapper)
        XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace/HERMES.md").path))
    }
    func testHermesExportRejectsCorruptMatchingOwnershipLedger() throws {
        let home = try temporaryHome()
        let root = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        try TokenSaverSettingsStore.replace(root.appendingPathComponent("config.yaml"), data: Data("fixture".utf8))
        let target = root.appendingPathComponent("workspace/HERMES.md")
        let state = root.appendingPathComponent(".aiusage-token-saver-owned.txt")
        for corrupt in [Data("user instructions without ownership markers".utf8), Data([0xff, 0xfe])] {
            try TokenSaverSettingsStore.replace(target, data: corrupt)
            try TokenSaverSettingsStore.replace(state, data: corrupt)
            XCTAssertThrowsError(try TokenSaverSettingsStore.exportHermesTestProfile(home: home))
            XCTAssertEqual(try Data(contentsOf: target), corrupt)
        }
    }
}
