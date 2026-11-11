// OS/auth seams are fake. Flow, both callers and banner are extracted from production.
import Foundation
import SwiftUI
import AppKit
import os.log
import QuotaBackend

private let providerActivationLog = Logger(subsystem: "local.aiusage.restart-fixture", category: "ProviderActivation")
struct ProviderAccountEntry {}
final class Settings {
    var chinese = false
    func t(_ en: String, _ zh: String) -> String { chinese ? zh : en }
}
func L(_ en: String, _ zh: String) -> String { en }
struct MenuBarRestartPrompt {
    var providerId = "codex"
    let entry = ProviderAccountEntry()
    let appDisplayName = "Codex"
    let accountLabel = "Fixture account"
}
// No real process is queried, terminated or launched by these types.
final class FakeApplication {
    var isTerminated: Bool { !Boundary.running }
    func terminate() -> Bool { Boundary.quitRequested = true; if Boundary.quitAccepted && !Boundary.stuck { Boundary.running = false }; return Boundary.quitAccepted }
}
enum NSRunningApplication {
    static func runningApplications(withBundleIdentifier: String) -> [FakeApplication] { Boundary.running ? [FakeApplication()] : [] }
}
final class NSWorkspace {
    static let shared = NSWorkspace()
    class OpenConfiguration { var activates = false }
    func openApplication(at: URL, configuration: OpenConfiguration) async throws {
        if Boundary.launchFails { throw NSError(domain: "fixture-secret-domain", code: 42, userInfo: [NSLocalizedDescriptionKey: "fixture-secret-token"]) }
        Boundary.opened = true
    }
}
enum Boundary {
    static var installed = true, running = true, quitAccepted = true, stuck = false, helpers = false
    static var reapplyFails = false, launchFails = false, quitRequested = false, reapplied = false, opened = false
    static func reset() {
        installed = true; running = true; quitAccepted = true; stuck = false; helpers = false
        reapplyFails = false; launchFails = false; quitRequested = false; reapplied = false; opened = false
    }
}
final class ProviderActivationManager: ObservableObject {
    static let shared = ProviderActivationManager()
    let settings = Settings()
    @Published var isCodexRestarting = false
    var isCodexAppInstalled: Bool { Boundary.installed }
    var codexGlobalStateReconcileTask: Task<Void, Never>?
    static let codexBundleIdentifier = "fixture-only"
    static func resolveInstalledCodexAppURL() -> URL? { Boundary.installed ? URL(fileURLWithPath: "/tmp/fixture-only.app") : nil }
    static func isCodexChildHelperRunning(appBundlePath: String) -> Bool { Boundary.helpers }
    static func terminateOrphanedCodexChildHelpers(appBundlePath: String) {}
    func reapplyCodexAccountForRestart(fallbackEntry: ProviderAccountEntry?) async throws {
        Boundary.reapplied = true
        if Boundary.reapplyFails { throw NSError(domain: "fixture-secret-domain", code: 41, userInfo: [NSLocalizedDescriptionKey: "fixture-secret-token"]) }
    }
    func restartAntigravityApp(fallbackEntry: ProviderAccountEntry?) async -> Bool { false }
    // PRODUCTION_FLOW
}
@MainActor final class LocalCaller {
    let activation = ProviderActivationManager.shared
    var activeEntry: ProviderAccountEntry? = ProviderAccountEntry()
    var isRestartingCodex = false
    var statusBannerIsError = false
    var statusBannerMessage: String?
    var refreshCount = 0
    func refreshEnvironment() { refreshCount += 1 }
    // PRODUCTION_LOCAL
}
@MainActor final class MenuCaller {
    var isConfirmingRestart = false
    var pendingRestartPrompt: MenuBarRestartPrompt?
    var activationSuccess = false
    var activationMessage: String?
    // PRODUCTION_MENU
}
struct DiagnosticBanner: View {
    let message: String
    @State var statusBannerMessage: String?
    let isRestartingCodex = false
    @ObservedObject var activation = ProviderActivationManager.shared
    struct EnvironmentSummary { let isAppInstalled = true }
    let envSummary = EnvironmentSummary()
    let colorScheme = ColorScheme.dark
    func restartCodex() {}
    var body: some View { statusBanner(message, isError: true).padding().frame(width: 950) }
    // PRODUCTION_BANNER
}
@main struct Regression {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        assertions += 1; precondition(value(), message)
    }
    @MainActor static func verify(_ output: URL) async {
        let manager = ProviderActivationManager.shared
        for stage in ["resolve_app", "request_quit", "wait_for_quit", "wait_for_helpers", "reapply_account", "launch_app", "busy"] {
            Boundary.reset()
            switch stage {
            case "resolve_app": Boundary.installed = false
            case "request_quit": Boundary.quitAccepted = false
            case "wait_for_quit": Boundary.stuck = true
            case "wait_for_helpers": Boundary.helpers = true
            case "reapply_account": Boundary.reapplyFails = true
            case "launch_app": Boundary.launchFails = true
            default: manager.isCodexRestarting = true
            }
            for chinese in [false, true] {
                manager.settings.chinese = chinese
                do {
                    try await manager.restartCodexApp(timeoutSeconds: 0.02, pollIntervalMilliseconds: 10)
                    fatalError("missing failure for \(stage)")
                } catch let error as ProviderError {
                    check(error.code == "codex_restart_" + stage, "wrong phase")
                    check(!error.localizedDescription.contains("fixture-secret"), "secret escaped")
                    check(error.message.contains(chinese ? "Codex" : "Codex") || stage == "launch_app", "missing explanation")
                } catch { fatalError("wrong error type: \(error)") }
                check(manager.isCodexRestarting == (stage == "busy"), "busy lifecycle changed")
                check(!Boundary.opened, "unsafe relaunch after failure")
            }
            manager.isCodexRestarting = false
        }
        manager.settings.chinese = false
        for running in [true, false] {
            Boundary.reset(); Boundary.running = running
            do { try await manager.restartCodexApp() } catch { fatalError("success control failed") }
            check(Boundary.opened && Boundary.reapplied && !manager.isCodexRestarting, "success path changed")
            check(Boundary.quitRequested == running, "quit requested for absent app")
        }
        // Execute both exact production UI callbacks, not a rewritten error mapper.
        for fails in [true, false] {
            Boundary.reset(); Boundary.installed = !fails
            let local = LocalCaller(); local.restartCodex()
            for _ in 0..<200 where local.isRestartingCodex { try? await Task.sleep(nanoseconds: 10_000_000) }
            check(!local.isRestartingCodex && local.refreshCount == 1, "Local caller stuck")
            check(local.statusBannerIsError == fails, "Local caller error styling")
            check(local.statusBannerMessage?.contains("codex_restart_resolve_app") == fails, "Local caller lost phase")
            Boundary.reset(); Boundary.installed = !fails
            let menu = MenuCaller(); menu.pendingRestartPrompt = .init(); menu.confirmAndRestartApp(for: .init())
            for _ in 0..<200 where menu.isConfirmingRestart { try? await Task.sleep(nanoseconds: 10_000_000) }
            check(!menu.isConfirmingRestart && menu.pendingRestartPrompt == nil, "Menu caller stuck")
            check(menu.activationSuccess == !fails, "Menu caller success state")
            check(menu.activationMessage?.contains("codex_restart_resolve_app") == fails, "Menu caller lost phase")
        }
        Boundary.reset(); Boundary.reapplyFails = true
        let local = LocalCaller(); local.restartCodex()
        for _ in 0..<200 where local.isRestartingCodex { try? await Task.sleep(nanoseconds: 10_000_000) }
        let message = local.statusBannerMessage!
        check(message.contains("codex_restart_reapply_account"), "missing native banner phase")
        let host = NSHostingView(rootView: DiagnosticBanner(message: message))
        host.frame = CGRect(x: 0, y: 0, width: 950, height: 140)
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try! bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent("restart-failure-banner.png"))
        print("PASS: \(assertions) restart diagnostics assertions; exact flow, Local/Menu callbacks and native SwiftUI banner; fake OS/auth only")
    }
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        if CommandLine.arguments.contains("--verify") {
            Task { await verify(URL(fileURLWithPath: CommandLine.arguments.last!)); app.terminate(nil) }
        } else {
            let message = ProviderError("codex_restart_reapply_account", "Codex quit, but the selected account could not be reapplied safely. Reconnect or select the account again before retrying.").localizedDescription
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 950, height: 160), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "AIUsage Restart Diagnostics — Isolated Fixture"
            window.contentView = NSHostingView(rootView: DiagnosticBanner(message: message))
            window.center(); window.makeKeyAndOrderFront(nil)
            app.activate(ignoringOtherApps: true)
        }
        app.run()
    }
}
