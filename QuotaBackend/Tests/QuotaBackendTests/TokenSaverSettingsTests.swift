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
}
