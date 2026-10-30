import Foundation
import Combine
import QuotaBackend

private func check(_ value: Bool) { precondition(value) }

@main struct ControllerRegression {
    @MainActor static func main() throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: home) }
        let profile = home.appendingPathComponent(".hermes/profiles/token-saver-test")
        let config = profile.appendingPathComponent("config.yaml")
        let target = profile.appendingPathComponent("workspace/HERMES.md")
        let bot = home.appendingPathComponent(".hermes/profiles/bot-huy/workspace/HERMES.md")
        try fm.createDirectory(at: bot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep bot exact".utf8).write(to: bot)
        let controller = TokenSaverSettingsController(home: home)
        var value = TokenSaverSettings()
        value.rtkEnabled = true; value.cavemanEnabled = true; value.ponytailEnabled = true
        controller.apply(value)
        check(controller.settings == value && controller.error == nil)
        check(controller.notice?.contains("sync Hermes test rules separately") == true)
        print("PASS controller applies compact settings and reports separate Hermes sync")

        controller.syncHermesTestProfile()
        check(controller.error?.contains("Create the dedicated Hermes") == true && controller.notice == nil)
        check(!fm.fileExists(atPath: target.path))
        print("PASS missing profile produces error without creating a profile")

        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data("fixture config untouched".utf8).write(to: config)
        controller.syncHermesTestProfile()
        check(controller.error == nil && controller.notice?.contains("synchronized") == true)
        let text = try String(contentsOf: target, encoding: .utf8)
        check(text.contains("RTK:") && text.contains("Ponytail:") && text.utf8.count < 2400)
        check(try String(contentsOf: config, encoding: .utf8) == "fixture config untouched")
        check(try String(contentsOf: bot, encoding: .utf8) == "keep bot exact")
        print("PASS explicit sync exports compact rules and preserves bot/config")

        value.cavemanMode = .ultra
        controller.apply(value)
        check(controller.notice?.contains("synchronized") == false)
        check(try String(contentsOf: target, encoding: .utf8) == text)
        controller.syncHermesTestProfile()
        check(try String(contentsOf: target, encoding: .utf8).contains("Caveman active mode: ultra"))
        print("PASS settings changes invalidate sync success until explicit resync")

        let owned = try Data(contentsOf: target)
        let edited = owned + Data("user edit".utf8)
        try edited.write(to: target)
        controller.syncHermesTestProfile()
        check(controller.error != nil && controller.notice == nil)
        check(try Data(contentsOf: target) == edited)
        print("PASS external edits stay untouched and stale success is cleared")

        try owned.write(to: target)
        controller.apply(.init())
        controller.syncHermesTestProfile()
        check(controller.error == nil && controller.notice?.contains("removed") == true)
        check(!fm.fileExists(atPath: target.path))
        check(try String(contentsOf: bot, encoding: .utf8) == "keep bot exact")
        print("PASS all-off clears only owned Hermes rules")

        try Data("not json".utf8).write(to: TokenSaverSettingsStore.settingsURL(home: home))
        let corrupt = TokenSaverSettingsController(home: home)
        check(corrupt.error != nil)
        corrupt.syncHermesTestProfile()
        check(corrupt.error != nil && corrupt.notice == nil)
        check(!fm.fileExists(atPath: target.path))
        print("PASS corrupt settings fail closed without export")
        print("Token Saver native controller: 7 checks passed")
    }
}
