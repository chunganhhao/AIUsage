import Foundation
import Combine
import QuotaBackend

var testUseChinese = false
func L(_ en: String, _ zh: String) -> String { testUseChinese ? zh : en }
private func check(_ value: Bool) { precondition(value) }

@main struct ControllerRegression {
    @MainActor static func main() async throws {
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
        check(controller.notice?.contains("Start a new coding session") == true)
        print("PASS controller applies compact settings and reports session reload notice")

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
        let setupHome = home.appendingPathComponent("setup with 'quote")
        let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { _, args in
            precondition(args == ["list", "--versions", "rtk"], "Onboarding must not install, upgrade or contact GitHub")
            return .init(status: 0, text: "rtk 1.1.0")
        }
        let setup = TokenSaverSettingsController(home: setupHome, rtk: rtk)
        setup.apply(value)
        await setup.checkOnboarding()
        check(!setup.isCheckingSetup && setup.setupError == nil)
        check(setup.installationStatus.contains("Homebrew 1.1.0") && setup.installationStatus.contains("PATH is not verified"))
        check(setup.onboarding?.rules == .current && setup.onboarding?.wrapperReady == true)
        check(setup.historyStatus.contains("unavailable / not verified"))
        check(setup.onboarding?.agentCommands?.contains("'\"'\"'quote/") == true)
        check(setup.onboarding?.agentCommands?.contains("without reading") == true)
        check(setup.onboarding?.agentCommands?.contains("not proof of automatic prompt loading") == true)
        check(setup.onboarding?.agentCommands?.contains("rg -n") == false)
        // Verify Chinese localization of diagnostic rows, notices and errors (F3)
        testUseChinese = true
        check(setup.localizedRTKStatus.contains("2. RTK：Homebrew 1.1.0；代理 PATH 未验证"))
        check(setup.localizedRulesStatus == "3. 托管规则：当前匹配")
        check(setup.localizedHistoryStatus == "4. 默认 RTK 历史记录：不可用 / 未验证")
        testUseChinese = false
        // Verify Caveman-only and Ponytail-only configurations enable diagnostic copy without RTK/wrapper (F1)
        var cavemanOnly = TokenSaverSettings(); cavemanOnly.cavemanEnabled = true
        setup.apply(cavemanOnly)
        await setup.checkOnboarding()
        check(setup.onboarding?.rules == .current && setup.onboarding?.wrapperReady == false)
        check(setup.onboarding?.agentCommands != nil && setup.onboarding?.agentCommands?.contains("--version") == false)
        var ponytailOnly = TokenSaverSettings(); ponytailOnly.ponytailEnabled = true
        setup.apply(ponytailOnly)
        await setup.checkOnboarding()
        check(setup.onboarding?.rules == .current && setup.onboarding?.wrapperReady == false)
        check(setup.onboarding?.agentCommands != nil && setup.onboarding?.agentCommands?.contains("--version") == false)
        setup.selectHarness(.hermes)
        check(setup.onboarding == nil)
        await setup.checkOnboarding()
        check(setup.onboarding?.rules == .current && setup.onboarding?.agentCommands != nil)
        setup.selectHarness(.codex)
        setup.apply(.init())
        check(setup.onboarding == nil)
        await setup.checkOnboarding()
        check(setup.onboarding?.rules == .off && setup.onboarding?.agentCommands == nil)
        let missing = TokenSaverSettingsController(home: setupHome, rtk: .init(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { _, _ in
            .init(status: 1, text: "")
        })
        await missing.checkOnboarding()
        check(missing.installationStatus.contains("not installed in Homebrew"))
        testUseChinese = true
        check(missing.localizedRTKStatus.contains("Homebrew 未安装"))
        check(missing.localizedRulesStatus == "3. 托管规则：已关闭")
        testUseChinese = false
        let unavailable = TokenSaverSettingsController(home: setupHome, rtk: .init(brewURL: nil))
        await unavailable.checkOnboarding()
        check(unavailable.setupError != nil && unavailable.installationStatus == "not verified")
        testUseChinese = true
        check(unavailable.localizedRTKStatus == "2. RTK：未验证")
        check(unavailable.localizedSetupError?.contains("未找到可信 Homebrew") == true)
        testUseChinese = false
        check(unavailable.onboarding?.rules == .off && !unavailable.isCheckingSetup)
        print("PASS onboarding is read-only, scoped, invalidated and honest across installed/missing/unavailable/unsupported states")
        print("Token Saver native controller: 8 checks passed")
    }
}
