// Exact manager flows with fake app/auth boundaries; real switcher storage tests use a temporary home.
import CryptoKit
import Foundation
import SQLite3
import AppKit
import SwiftUI
import PDFKit
import os.log
import QuotaBackend

func L(_ en: String, _ zh: String, _ vi: String? = nil) -> String { en }
extension String { var nilIfBlank: String? { isEmpty ? nil : self } }
private let providerActivationLog = Logger(subsystem: "local.aiusage.safe-switch", category: "fixture")
struct EntryAccount { var email: String?; var displayName: String?; var sourceFilePath: String?; var accountLabel: String? }
struct ProviderAccountEntry {
    var providerId: String
    var accountPrimaryLabel = "target@example.invalid"
    var accountEmail: String? = "target@example.invalid"
    var accountDisplayName: String? = "Target"
    var storedAccount: EntryAccount? = nil
    var liveProvider: EntryAccount? = nil
}
final class Settings { func t(_ en: String, _ zh: String) -> String { en } }
final class AccountCredentialStore {
    static let shared = AccountCredentialStore()
    func loadCredentials(for: String) -> [AccountCredential] { [] }
    static func normalizedAuthFilePath(_ path: String) -> String { path.lowercased() }
}
final class FakeApplication {
    let bundle: String
    init(_ bundle: String) { self.bundle = bundle }
    var isTerminated: Bool { !Boundary.running.contains(bundle) }
    func terminate() -> Bool {
        Boundary.events.append("quit")
        if Boundary.refuseQuit { return false }
        Boundary.running.remove(bundle); return true
    }
}
enum FixtureRunningApplication {
    static func runningApplications(withBundleIdentifier bundle: String) -> [FakeApplication] {
        Boundary.running.contains(bundle) ? [FakeApplication(bundle)] : []
    }
}
final class FixtureAlert {
    enum Response { case alertFirstButtonReturn, cancel }
    var messageText = "", informativeText = ""
    func addButton(withTitle: String) {}
    func runModal() -> Response { Boundary.events.append("confirm"); return Boundary.confirm ? .alertFirstButtonReturn : .cancel }
}
final class FixtureWorkspace {
    static let shared = FixtureWorkspace()
    final class OpenConfiguration { var activates = false }
    func openApplication(at: URL, configuration: OpenConfiguration) async throws { Boundary.events.append("open") }
}
enum Boundary {
    static var running: Set<String> = []
    static var events: [String] = []
    static var confirm = false, refuseQuit = false, externalCLI = false, externalHub = false, keyring = false
    static var authPath = "", offMain = false
    static func reset(provider: String, running: Bool = true, confirm: Bool = false) {
        self.running = running ? [provider == "codex" ? "com.openai.codex" : "com.google.antigravity"] : []
        events = []; self.confirm = confirm; refuseQuit = false; externalCLI = false; externalHub = false; keyring = false; offMain = false
    }
}
enum FakeAGYSwitcher {
    typealias RestartTargetCandidate = AntigravityAccountSwitcher.RestartTargetCandidate
    static func hasExternalHubProcess() -> Bool { Boundary.externalHub }
    static func switchAccount(authFileURL: URL, fallbackEmail: String?, fallbackName: String?, managedAuthPaths: [String]) throws -> AntigravitySwitchedIdentity {
        Boundary.offMain = !Thread.isMainThread
        Boundary.events.append("mutate")
        Thread.sleep(forTimeInterval: 0.05)
        return .init(email: fallbackEmail!, name: fallbackName!, sourceFilePath: authFileURL.path)
    }
    @MainActor static func restartAntigravityApp(reapplyBeforeRelaunch: (() async throws -> Void)?) async -> Bool {
        await AntigravityAccountSwitcher.restartAntigravityApp(
            homeDirectory: "/tmp/not-real-home", appExists: { _ in true },
            isTargetRunning: { Boundary.running.contains("com.google.antigravity") },
            requestTerminate: { FakeApplication("com.google.antigravity").terminate() },
            isLanguageServerRunning: { false }, terminateLanguageServer: {},
            relaunchApp: { _ in Boundary.events.append("open"); return true },
            reapplyBeforeRelaunch: reapplyBeforeRelaunch
        )
    }
}
final class ProviderActivationManager: ObservableObject {
    enum ActivationResult { case success(String), failure(String) }
    enum CodexActivationResult { case success(String), failure(String) }
    var activationResult: ActivationResult?, codexActivationResult: CodexActivationResult?
    var confirmingSwitchProviderId: String?
    var isCodexRestarting = false, isAntigravityRestarting = false, isAntigravitySwitching = false
    var codexGlobalStateReconcileTask: Task<Void, Never>?, antigravityDetectionTask: Task<Void, Never>?
    var antigravitySwitchGeneration: UInt64 = 0
    var lastActivatedAntigravityTarget: AntigravityAccountSwitcher.RestartTargetCandidate?
    @Published var activeProviderAccountIds: [String: String] = [:]
    let settings = Settings()
    static let codexBundleIdentifier = "com.openai.codex"
    static let externalCodexWarning = "Restart external terminal / daemon"
    static func codexUsesKeyring() -> Bool { Boundary.keyring }
    static func verifiedCodexAppBundlePaths() -> Set<String> { [] }
    static func hasExternalCodexProcess(verifiedBundlePaths: Set<String> = []) -> Bool { Boundary.externalCLI }
    static func resolveInstalledCodexAppURL() -> URL? { URL(fileURLWithPath: "/tmp/fake.app") }
    static func isCodexChildHelperRunning(appBundlePath: String) -> Bool { false }
    static func terminateOrphanedCodexChildHelpers(appBundlePath: String) {}
    func isRemoteViewOnly(_ entry: ProviderAccountEntry) -> Bool { false }
    func isSwitchingDisabled(for id: String) -> Bool { confirmingSwitchProviderId == id || (id == "codex" ? isCodexRestarting : isAntigravityRestarting || isAntigravitySwitching) }
    func resolveManagedSource(entry: ProviderAccountEntry) -> String? { Boundary.authPath }
    func persistActiveIds() {}
    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        precondition(!Boundary.running.contains("com.openai.codex")); Boundary.events.append("mutate")
        activeProviderAccountIds["codex"] = entry.accountEmail
    }
    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool { activeProviderAccountIds[entry.providerId] != nil }
    func deactivateAccount(entry: ProviderAccountEntry) { activeProviderAccountIds[entry.providerId] = nil }
    func activateGeminiAccount(entry: ProviderAccountEntry) throws { Boundary.events.append("mutate") }
    func reapplyCodexAccountForRestart(fallbackEntry: ProviderAccountEntry?) async throws { Boundary.events.append("reapply") }
    // PRODUCTION_AGY_REAPPLY
        // PRODUCTION_ACTIVATE
    // PRODUCTION_CODEX_RESTART
    // PRODUCTION_AGY_RESTART
    // PRODUCTION_AGY_ACTIVATE
    // PRODUCTION_CODEX_WRITE_BOUNDARY
}
enum ProductionCodexStorageParser {
    // PRODUCTION_CODEX_KEYRING
}
@MainActor final class ProductionCoordinatorFlowFixture {
    struct AccountCheckError: Equatable { let message: String; let errorCode: String?; let failedAt: Date }
    struct ProviderData: Identifiable {
        struct Headline { var primary = ""; var supporting = "" }
        let id: String
        let baseProviderId: String
        let accountId: String?
        let status: Status
        let needsCredentialConnection: Bool
        let sourceFilePath: String?
        let headline = Headline()
        let errorCode: String? = nil
        let fetchedAt: String? = nil
        enum Status { case healthy, error }
    }
    struct StoredAccount { let providerId: String; let isHidden: Bool }
    final class Store {
        var accountRegistry: [StoredAccount] = []
        func matchesStoredWithLive(_ stored: StoredAccount, provider: ProviderData) -> Bool {
            stored.providerId == provider.baseProviderId
        }
    }
    let accountStore = Store()
    var providers: [ProviderData] = []
    var isRefreshingAllProviders = false
    var pendingRefreshAfterCurrent = false
    var calls: [(useRecent: Bool, automatic: Bool)] = []
    var pauseFirstFetch: CheckedContinuation<Void, Never>?
    var firstFetchStarted: CheckedContinuation<Void, Never>?
    func setupAutoRefresh() {}
    func fetchDashboard(useRecentResults: Bool = false, automatic: Bool = false) async -> Int {
        calls.append((useRecentResults, automatic))
        if calls.count == 1 {
            firstFetchStarted?.resume()
            firstFetchStarted = nil
            await withCheckedContinuation { pauseFirstFetch = $0 }
        }
        return 0
    }
    func preferredLiveProvider(among list: [ProviderData], storedAccount: StoredAccount?) -> ProviderData? { list.first }
    func liveProviderIdentity(_ provider: ProviderData) -> String { provider.id }
    func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool { lhs.id < rhs.id }
    func credentialID(for provider: ProviderData) -> String? { nil }
    func resolvedFetchedDate(for provider: ProviderData) -> Date? { nil }
    func lastCheckError(for provider: ProviderData) -> AccountCheckError? { nil }
    func isLastKnownErrorPreservable(_ provider: ProviderData) -> Bool { provider.status != .error }
    func isTerminalStopFailure(_ provider: ProviderData) -> Bool { false }
    func clearAccountCheckError(for provider: ProviderData, credentialId: String? = nil) {}
    func recordAccountCheckError(for provider: ProviderData, credentialId: String? = nil, message: String, errorCode: String?) {}
    // PRODUCTION_COORDINATOR_FLOW
}
struct NativeToggleFixture: View {
    @ObservedObject var activation: ProviderActivationManager
    let entry = ProviderAccountEntry(providerId: "codex")
    var onAccountSwitched: (() -> Void)? = nil
    var onShowStatus: ((String, Bool) -> Void)? = nil
    var isActive: Bool { activation.isActiveAccount(entry) }
    var body: some View {
        VStack {
            Toggle("", isOn: activationBinding)
                .toggleStyle(.switch)
                .accessibilityLabel("Safe account switch")
            Text(isActive ? "Active target" : "Original account")
        }.padding().frame(width: 300, height: 100)
    }
    var activationBinding: Binding<Bool> {
        // PRODUCTION_BINDING
    }
    // PRODUCTION_ROW_ACTIVATION
}
@main struct SafeSwitchRegression {
    @MainActor static var assertions = 0
    @MainActor static func check(_ value: @autoclosure () -> Bool, _ message: String) { assertions += 1; precondition(value(), message) }
    @MainActor static func main() async throws {
        let fixtureBase = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TokenSaverSettingsStore.resolvedTemporaryDirectory()
        try FileManager.default.createDirectory(at: fixtureBase, withIntermediateDirectories: true)
        let home = fixtureBase.appendingPathComponent("aiusage-safe-switch-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        Boundary.authPath = home.appendingPathComponent("target.json").path
        try Data("{}".utf8).write(to: URL(fileURLWithPath: Boundary.authPath))
        let manager = ProviderActivationManager()
        for provider in ["codex"] {
            Boundary.reset(provider: provider)
            let cancelled = try await manager.activateAccount(entry: .init(providerId: provider))
            check(!cancelled && Boundary.events == ["confirm"], "Cancel mutated auth or quit app")
            Boundary.reset(provider: provider, confirm: true)
            let switched = try await manager.activateAccount(entry: .init(providerId: provider))
            check(switched && Boundary.events == ["confirm", "quit", "mutate", "open"], "Wrong close-before-write order: \(Boundary.events)")
            if provider == "antigravity" { check(Boundary.offMain, "Keychain mutation ran on main thread") }
            Boundary.reset(provider: provider, running: false)
            let direct = try await manager.activateAccount(entry: .init(providerId: provider))
            check(direct && Boundary.events == ["mutate"], "Stopped app should switch without prompt or reopen")
            Boundary.reset(provider: provider, confirm: true); Boundary.refuseQuit = true
            do { _ = try await manager.activateAccount(entry: .init(providerId: provider)); fatalError("Quit refusal must fail") }
            catch {
                check(!Boundary.events.contains("mutate") && !Boundary.events.contains("open"), "Quit refusal wrote credentials")
                if case .failure(let msg) = manager.activationResult {
                    check(msg.contains("did not accept the quit request"), "Missing activation failure message on quit refusal: \(msg)")
                } else {
                    fatalError("Missing activationResult failure on quit refusal")
                }
                if case .failure(let codexMsg) = manager.codexActivationResult {
                    check(codexMsg.contains("did not accept the quit request"), "Missing codexActivationResult failure message on quit refusal: \(codexMsg)")
                } else {
                    fatalError("Missing codexActivationResult failure message on quit refusal")
                }
            }
        }
        Boundary.reset(provider: "codex"); Boundary.keyring = true
        do { _ = try await manager.activateAccount(entry: .init(providerId: "codex")); fatalError("keyring must block file-only switch") }
        catch { check(Boundary.events.isEmpty, "Keyring block mutated files") }
        // Production Codex storage parser must block both "keyring" and "auto" while allowing "file" or missing config.
        let missingCodexCfg = home.appendingPathComponent("missing-codex.toml")
        check(!ProductionCodexStorageParser.codexUsesKeyring(configPath: missingCodexCfg.path), "Missing config.toml must not block")
        let codexCfg = home.appendingPathComponent("codex-config.toml")
        for (body, expected, label) in [
            ("cli_auth_credentials_store = \"auto\"\n", true, "double-quoted auto"),
            ("cli_auth_credentials_store = 'auto' # comment\n", true, "single-quoted auto with comment"),
            ("cli_auth_credentials_store = \"keyring\"\n", true, "explicit keyring"),
            ("# cli_auth_credentials_store = \"auto\"\ncli_auth_credentials_store = \"file\"\n", false, "commented auto + file"),
            ("model = \"gpt-5\"\n", false, "omitted store key")
        ] {
            try Data(body.utf8).write(to: codexCfg)
            check(ProductionCodexStorageParser.codexUsesKeyring(configPath: codexCfg.path) == expected, "Codex storage guard mismatch for \(label)")
        }
        // Antigravity switching & Keychain reapply are permanently disabled fail-closed across every entry point.
        Boundary.reset(provider: "antigravity", confirm: true)
        do { _ = try await manager.activateAccount(entry: .init(providerId: "antigravity")); fatalError("Antigravity switching must fail closed") }
        catch let error as ProviderError {
            check(error.code == "antigravity_switch_disabled" && Boundary.events.isEmpty, "Disabled AGY switch must fail closed with zero prompts/mutations")
        }
        do { try await manager.activateAntigravityAccount(entry: .init(providerId: "antigravity")); fatalError("activateAntigravityAccount must fail closed") }
        catch let error as ProviderError {
            check(error.code == "antigravity_switch_disabled" && Boundary.events.isEmpty, "Direct activateAntigravityAccount must fail closed")
        }
        do { try await manager.reapplyAntigravityAccountForRestart(fallbackEntry: .init(providerId: "antigravity")); fatalError("reapplyAntigravityAccountForRestart must fail closed") }
        catch let error as ProviderError {
            check(error.code == "antigravity_switch_disabled" && Boundary.events.isEmpty, "reapplyAntigravityAccountForRestart must fail closed")
        }
        let blockedSwitchRestart = await manager.restartAntigravityApp(switchingTo: .init(providerId: "antigravity"))
        check(!blockedSwitchRestart && Boundary.events.isEmpty, "restartAntigravityApp(switchingTo:) must refuse before quitting or mutating")
        Boundary.reset(provider: "antigravity", confirm: true)
        let plainRestart = await manager.restartAntigravityApp()
        check(plainRestart && Boundary.events == ["quit", "open"], "restartAntigravityApp() must only quit & reopen IDE without reapply/mutate")
        Boundary.reset(provider: "codex", running: false); Boundary.externalCLI = true
        let declinedCLI = try await manager.activateAccount(entry: .init(providerId: "codex"))
        check(!declinedCLI && Boundary.events == ["confirm"], "External daemon warning should precede writes")
        // Production Codex CLI ps parser ignores ChatGPT/Codex app helpers and custom .app paths, catching only external CLI binaries.
        let psCommSample = """
          58097 ChatGPT
          58117 Codex (Aperitif)
          58165 codex
          58530 codex
          59001 Python
          notapid codex
        """
        check(ProductionCodexStorageParser.extractCodexPIDs(fromPsCommOutput: psCommSample) == ["58165", "58530"],
              "extractCodexPIDs must select exact codex basename PIDs only")
        let bundledOnlyArgs = """
        /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex -c features.code_mode_host=true app-server
        /Applications/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server
        /Users/test/Desktop Apps/Custom.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex exec-server
        /Users/john-doe/Desktop Apps/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server
        """
        let allowedBundles: Set<String> = [
            "/Applications/ChatGPT.app",
            "/Applications/Codex.app",
            "/Users/test/Desktop Apps/Custom.app",
            "/Users/john-doe/Desktop Apps/ChatGPT.app"
        ]
        check(!ProductionCodexStorageParser.hasExternalCodexCommandLines(bundledOnlyArgs, verifiedBundlePaths: allowedBundles),
              "Bundled ChatGPT.app / Codex.app CLI helpers must not be flagged as external Codex CLI")
        check(ProductionCodexStorageParser.isBundledCodexExecutablePath(
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            verifiedBundlePaths: ["/Applications/ChatGPT.app"]
        ), "[§11.3] Verified Codex bundle executable path positive control")
        check(ProductionCodexStorageParser.hasExternalCodexCommandLines(bundledOnlyArgs, verifiedBundlePaths: []),
              "[§11.3] Empty verified bundle set must treat all codex command lines as external CLI")
        check(!ProductionCodexStorageParser.isBundledCodexExecutablePath(
            "/Applications/SomeOther.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            verifiedBundlePaths: []
        ), "[§11.3] Empty verified bundle set must not exempt unrelated .app bundle-shaped executable path")
        check(!ProductionCodexStorageParser.isBundledCodexExecutablePath(
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            verifiedBundlePaths: []
        ), "[§11.3] Empty verified bundle set must fail safe even for default ChatGPT.app path when provenance unavailable")
        for externalCmd in [
            "/opt/homebrew/bin/codex",
            "/opt/homebrew/bin/codex -C /Applications/ChatGPT.app/Contents/Resources",
            "/opt/homebrew/bin/codex /Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
            "/Users/apple/.local/lib/node_modules/@openai/codex-darwin-arm64/vendor/aarch64-apple-darwin/codex/codex",
            "codex --model gpt-5"
        ] {
            check(ProductionCodexStorageParser.hasExternalCodexCommandLines(externalCmd, verifiedBundlePaths: allowedBundles),
                  "External Codex CLI binary (even with bundled app arguments) must be detected: \(externalCmd)")
        }
        // [§9.4] Verified bundle enforcement & fail-closed unreadable args output
        let verifiedBundles: Set<String> = ["/Applications/ChatGPT.app"]
        check(!ProductionCodexStorageParser.hasExternalCodexCommandLines(
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server",
            expectedCount: 1,
            verifiedBundlePaths: verifiedBundles
        ), "[§9.4] Genuine helper inside verified ChatGPT.app bundle must not trigger external warning")
        check(ProductionCodexStorageParser.hasExternalCodexCommandLines(
            "/tmp/Fake.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex app-server",
            expectedCount: 1,
            verifiedBundlePaths: verifiedBundles
        ), "[§9.4] Helper outside verified bundles must be treated as external CLI")
        check(ProductionCodexStorageParser.hasExternalCodexCommandLines("", expectedCount: 1, verifiedBundlePaths: verifiedBundles),
              "[§9.4] Unreadable or missing command line for live codex PID must fail safe with external warning")
        // [§13.2] verifiedCodexAppBundlePaths & resolveInstalledCodexAppURL must verify CFBundleIdentifier == com.openai.codex
        let bundleRoot = home.appendingPathComponent("codex-bundle-producer-\(UUID().uuidString)")
        let sysApps = bundleRoot.appendingPathComponent("Applications")
        let wrongCodexApp = sysApps.appendingPathComponent("Codex.app")
        let wrongPlistDir = wrongCodexApp.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: wrongPlistDir, withIntermediateDirectories: true)
        func writeInfoPlist(bundleID: String, to dir: URL) throws {
            let data = try PropertyListSerialization.data(
                fromPropertyList: ["CFBundleIdentifier": bundleID, "CFBundleName": "Codex"],
                format: .xml,
                options: 0
            )
            try data.write(to: dir.appendingPathComponent("Info.plist"))
        }
        try writeInfoPlist(bundleID: "org.example.wrapper", to: wrongPlistDir)
        let wrongResolved = ProductionCodexStorageParser.resolveInstalledCodexAppURL(
            homeDirectory: bundleRoot.path,
            systemApplicationsDirectory: sysApps.path,
            runningBundleURLs: [],
            workspaceBundleURL: { nil }
        )
        let wrongVerifiedSet = ProductionCodexStorageParser.verifiedCodexAppBundlePaths(
            homeDirectory: bundleRoot.path,
            systemApplicationsDirectory: sysApps.path,
            runningBundleURLs: [],
            workspaceBundleURL: { nil }
        )
        let wrongRegisteredSet = ProductionCodexStorageParser.verifiedCodexAppBundlePaths(
            homeDirectory: bundleRoot.path,
            systemApplicationsDirectory: sysApps.path,
            runningBundleURLs: [],
            workspaceBundleURL: { wrongCodexApp }
        )
        let wrongHelperPath = wrongCodexApp.path + "/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
        let wrongHelperURL = URL(fileURLWithPath: wrongHelperPath)
        try FileManager.default.createDirectory(at: wrongHelperURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: wrongHelperURL)
        check(wrongResolved == nil && wrongVerifiedSet.isEmpty && wrongRegisteredSet.isEmpty,
              "[§13.2] Bundle named Codex.app with wrong CFBundleIdentifier must never enter verified set")
        check(!ProductionCodexStorageParser.isBundledCodexExecutablePath(wrongHelperPath, verifiedBundlePaths: wrongVerifiedSet)
                && ProductionCodexStorageParser.hasExternalCodexCommandLines(wrongHelperPath + " app-server", verifiedBundlePaths: wrongVerifiedSet),
              "[§13.2] Helper under wrong-ID Codex.app must stay flagged as external CLI")

        try writeInfoPlist(bundleID: "com.openai.codex", to: wrongPlistDir)
        let knownResolved = ProductionCodexStorageParser.resolveInstalledCodexAppURL(
            homeDirectory: bundleRoot.path,
            systemApplicationsDirectory: sysApps.path,
            runningBundleURLs: [],
            workspaceBundleURL: { nil }
        )
        let knownVerifiedSet = ProductionCodexStorageParser.verifiedCodexAppBundlePaths(
            homeDirectory: bundleRoot.path,
            systemApplicationsDirectory: sysApps.path,
            runningBundleURLs: [],
            workspaceBundleURL: { nil }
        )
        check(knownResolved?.standardizedFileURL.path == wrongCodexApp.standardizedFileURL.path
                && !knownVerifiedSet.isEmpty,
              "[§13.2] Bundle with com.openai.codex CFBundleIdentifier enters verified set")
        check(ProductionCodexStorageParser.isBundledCodexExecutablePath(wrongHelperPath, verifiedBundlePaths: knownVerifiedSet)
                && !ProductionCodexStorageParser.isBundledCodexExecutablePath(
                    "/tmp/Unrelated.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                    verifiedBundlePaths: knownVerifiedSet
                ),
              "[§13.2] Verified com.openai.codex helper is accepted while unrelated .app stays rejected")
        // Native SwiftUI Toggle uses the production Binding setter and activation callback.
        _ = NSApplication.shared
        let nativeManager = ProviderActivationManager()
        let nativeView = NativeToggleFixture(activation: nativeManager)
        let host = NSHostingView(rootView: nativeView)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 300, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded(); window.displayIfNeeded(); window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        Boundary.reset(provider: "codex")
        nativeView.activationBinding.wrappedValue = true
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let cancelledText = PDFDocument(data: host.dataWithPDF(inside: host.bounds))?.string ?? ""
        check(!nativeManager.isActiveAccount(.init(providerId: "codex")) && Boundary.events == ["confirm"] && cancelledText.contains("Original account"), "Native Cancel changed active account")
        Boundary.reset(provider: "codex", confirm: true)
        nativeView.activationBinding.wrappedValue = true
        try await Task.sleep(for: .milliseconds(150))
        host.layoutSubtreeIfNeeded()
        let switchedText = PDFDocument(data: host.dataWithPDF(inside: host.bounds))?.string ?? ""
        check(nativeManager.isActiveAccount(.init(providerId: "codex")) && Boundary.events == ["confirm", "quit", "mutate", "open"] && switchedText.contains("Active target"), "Native confirmation did not safely commit active pill")
        window.orderOut(nil)
        // Real command runner with a harmless executable simulates a >5s permission dialog.
        let start = Date()
        let prompt = Task.detached { AntigravityAccountSwitcher.runSecurityCommand(arguments: ["5.2"], securityPath: "/bin/sleep") }
        try await Task.sleep(for: .milliseconds(50))
        check(Date().timeIntervalSince(start) < 1, "Main actor blocked by permission wait")
        let result = await prompt.value
        check(result?.exitCode == 0 && Date().timeIntervalSince(start) >= 5.0, "Prompt was killed at legacy 5s timeout")
        // Real managed-copy backfill: preserve unrelated metadata, reject foreign email/stale tokens.
        let outgoing = home.appendingPathComponent("outgoing.json")
        let foreign = home.appendingPathComponent("foreign.json")
        func write(_ url: URL, email: String, expiry: Date) throws {
            let data = try JSONSerialization.data(withJSONObject: ["email": email, "proxy_url": "http://127.0.0.1:1234", "disabled": true, "token": ["access_token": "old", "refresh_token": "old-rt", "expiry": ISO8601DateFormatter().string(from: expiry)]])
            try data.write(to: url)
        }
        try write(outgoing, email: "outgoing@example.invalid", expiry: Date().addingTimeInterval(-100))
        try write(foreign, email: "foreign@example.invalid", expiry: Date().addingTimeInterval(-100))
        let foreignBefore = try Data(contentsOf: foreign)
        let flatOutgoing = home.appendingPathComponent("flat-outgoing.json")
        try Data(try JSONSerialization.data(withJSONObject: [
            "email": "outgoing@example.invalid",
            "access_token": "old",
            "refresh_token": "old-rt",
            "expired": ISO8601DateFormatter().string(from: Date().addingTimeInterval(-100))
        ])).write(to: flatOutgoing)
        let live = try JSONSerialization.data(withJSONObject: [
            "email": "outgoing@example.invalid",
            "id_token": "live-jwt-id-token",
            "token": ["access_token": "new", "refresh_token": "new-rt", "expiry": ISO8601DateFormatter().string(from: Date().addingTimeInterval(3600))]
        ])
        let secret = AntigravityAccountSwitcher.encodeKeyringSecret(live)
        try AntigravityAccountSwitcher.flushLiveKeyringToManagedCopies(secret: secret, managedAuthPaths: [outgoing.path, flatOutgoing.path, foreign.path], homeDirectory: home.path)
        let updated = try JSONSerialization.jsonObject(with: Data(contentsOf: outgoing)) as! [String: Any]
        check((updated["token"] as? [String: Any])?["refresh_token"] as? String == "new-rt"
              && updated["id_token"] as? String == "live-jwt-id-token", "Outgoing rotated refresh/id_token lost")
        let updatedFlat = try JSONSerialization.jsonObject(with: Data(contentsOf: flatOutgoing)) as! [String: Any]
        check(updatedFlat["refresh_token"] as? String == "new-rt"
              && updatedFlat["id_token"] as? String == "live-jwt-id-token", "Flat auth JSON backfill dropped id_token or refresh_token")
        check(updated["disabled"] as? Bool == true && updated["proxy_url"] as? String == "http://127.0.0.1:1234", "Backfill destroyed protection/proxy metadata")
        let foreignAfter = try Data(contentsOf: foreign)
        check(foreignAfter == foreignBefore, "Foreign email backfilled")
        let newer = try Data(contentsOf: outgoing)
        let stale = try JSONSerialization.data(withJSONObject: ["email": "outgoing@example.invalid", "token": ["access_token": "stale", "refresh_token": "stale-rt", "expiry": "2001-01-01T00:00:00Z"]])
        try AntigravityAccountSwitcher.flushLiveKeyringToManagedCopies(secret: AntigravityAccountSwitcher.encodeKeyringSecret(stale), managedAuthPaths: [outgoing.path], homeDirectory: home.path)
        let afterStale = try Data(contentsOf: outgoing)
        check(afterStale == newer, "Stale Keychain token overwrote newer managed copy")
        // A corrupt existing backup must abort and restore the primary database.
        let dbURL = URL(fileURLWithPath: AntigravityAccountSwitcher.primaryDBPath(homeDirectory: home.path))
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        check(sqlite3_open(dbURL.path, &db) == SQLITE_OK, "Could not create isolated DB")
        check(sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value TEXT); INSERT INTO ItemTable VALUES ('antigravityAuthStatus', '{\"email\":\"outgoing@example.invalid\"}');", nil, nil, nil) == SQLITE_OK, "Could not seed isolated DB")
        sqlite3_close(db)
        let originalDB = try Data(contentsOf: dbURL)
        let backupURL = URL(fileURLWithPath: dbURL.path + ".backup")
        let corruptBackup = Data("not a SQLite database".utf8)
        try corruptBackup.write(to: backupURL)
        let targetData = try JSONSerialization.data(withJSONObject: ["email": "target@example.invalid", "access_token": "target-access", "refresh_token": "target-refresh", "expired": "2099-01-01T00:00:00Z"])
        try targetData.write(to: URL(fileURLWithPath: Boundary.authPath))
        do {
            _ = try AntigravityAccountSwitcher.switchAccount(authFileURL: URL(fileURLWithPath: Boundary.authPath), homeDirectory: home.path)
            fatalError("Corrupt backup injection should fail")
        } catch {
            let primaryAfter = try Data(contentsOf: dbURL)
            let backupAfter = try Data(contentsOf: backupURL)
            check(primaryAfter == originalDB && backupAfter == corruptBackup, "Backup injection failure left partial DB switch")
        }
        // Production coordinator queued manual refresh must reset automatic=false, and Switch-Safe bulk stabilization must retain existing AGY cards.
        let coordFix = ProductionCoordinatorFlowFixture()
        coordFix.accountStore.accountRegistry = [.init(providerId: "antigravity", isHidden: false)]
        let existingAGY = ProductionCoordinatorFlowFixture.ProviderData(
            id: "antigravity:cred:1", baseProviderId: "antigravity", accountId: "1", status: .healthy, needsCredentialConnection: false, sourceFilePath: nil
        )
        coordFix.providers = [existingAGY]
        let retained = coordFix.stabilizedBulkRefreshProviders([], includingExistingFor: ["antigravity"])
        check(retained.map(\.id) == ["antigravity:cred:1"], "Switch-Safe stabilizedBulkRefreshProviders dropped existing AGY card on empty incoming")
        let dropped = coordFix.stabilizedBulkRefreshProviders([], includingExistingFor: [])
        check(dropped.isEmpty, "Without includingExistingFor, empty incoming keeps empty slice")

        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            coordFix.firstFetchStarted = started
            coordFix.refreshAllProviders(automatic: true)
        }
        coordFix.refreshAllProviders(automatic: false)
        for _ in 0..<20 where !coordFix.pendingRefreshAfterCurrent { await Task.yield() }
        check(coordFix.pendingRefreshAfterCurrent, "Manual refresh during auto tick did not queue follow-up")
        coordFix.pauseFirstFetch?.resume()
        coordFix.pauseFirstFetch = nil
        for _ in 0..<50 {
            if coordFix.calls.count == 2 && !coordFix.isRefreshingAllProviders { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        check(coordFix.calls.count == 2
              && coordFix.calls[0] == (true, true)
              && coordFix.calls[1] == (false, false),
              "Queued manual follow-up refresh kept automatic=true: \(coordFix.calls)")

        // [§47] Native Codex switch/restart write boundary: reject archive dir/auth/bak before restore/write & preserve ordinary switch/restart
        do {
            let codexSwitchHome = home.appendingPathComponent("codex-write-boundary-\(UUID().uuidString)")
            let fm = FileManager.default
            let archiveDir = codexSwitchHome.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth", isDirectory: true)
            let archiveNested = archiveDir.appendingPathComponent("nested", isDirectory: true)
            let ordinaryDir = codexSwitchHome.appendingPathComponent(".codex", isDirectory: true)
            try fm.createDirectory(at: archiveNested, withIntermediateDirectories: true)
            try fm.createDirectory(at: ordinaryDir, withIntermediateDirectories: true)

            func codexJWT(account: String, user: String, jti: String) throws -> String {
                let payload: [String: Any] = [
                    "jti": jti, "iat": 1_760_000_000, "exp": 2_000_000_000,
                    "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user]
                ]
                let b64 = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).base64EncodedString()
                    .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                return "e30.\(b64).fixture"
            }
            func codexNativeAuthData(account: String, user: String, jti: String) throws -> Data {
                let tok = try codexJWT(account: account, user: user, jti: jti)
                return try JSONSerialization.data(withJSONObject: [
                    "auth_mode": "chatgpt",
                    "tokens": ["account_id": account, "id_token": tok, "access_token": tok, "refresh_token": "rt-\(jti)"],
                    "last_refresh": "2026-11-20T12:00:00Z"
                ], options: [.sortedKeys])
            }
            func recursiveManifest(at root: URL) throws -> [String] {
                let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
                var entries: [String] = []
                for case let item as URL in enumerator {
                    let vals = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    let rel = item.resolvingSymlinksInPath().standardizedFileURL.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
                    if vals.isSymbolicLink == true {
                        let dest = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                        entries.append("L:\(rel)->\(dest)")
                        enumerator.skipDescendants()
                    } else if vals.isRegularFile == true {
                        let d = try Data(contentsOf: item)
                        let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
                        entries.append("F:\(rel):\(d.count):\(sha)")
                    }
                }
                return entries.sorted()
            }

            let archiveSeed = archiveDir.appendingPathComponent("aiusage-codex-1.json")
            let archiveStale = archiveNested.appendingPathComponent("stale.json")
            let archiveLock = archiveDir.appendingPathComponent("preexisting.lock")
            try codexNativeAuthData(account: "ws-a", user: "u-a", jti: "arch-1").write(to: archiveSeed)
            try codexNativeAuthData(account: "ws-b", user: "u-b", jti: "arch-2").write(to: archiveStale)
            try Data("keep-lock".utf8).write(to: archiveLock)
            let manifestBefore = try recursiveManifest(at: archiveDir)

            let symlinkDir = codexSwitchHome.appendingPathComponent("alias-codex-dir")
            try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: archiveDir)
            let symlinkTargetParent = codexSwitchHome.appendingPathComponent("codex-file-alias", isDirectory: true)
            let symlinkBakParent = codexSwitchHome.appendingPathComponent("codex-bak-alias", isDirectory: true)
            try fm.createDirectory(at: symlinkTargetParent, withIntermediateDirectories: true)
            try fm.createDirectory(at: symlinkBakParent, withIntermediateDirectories: true)
            let symlinkAuthTarget = symlinkTargetParent.appendingPathComponent("auth.json")
            let symlinkBakDirTarget = symlinkBakParent.appendingPathComponent("auth.json")
            try fm.createSymbolicLink(at: symlinkAuthTarget, withDestinationURL: archiveSeed)
            try fm.createSymbolicLink(at: symlinkBakParent.appendingPathComponent("auth.json.bak"), withDestinationURL: archiveStale)

            let accountAData = try codexNativeAuthData(account: "ws-a", user: "u-a", jti: "acct-a")
            let accountBData = try codexNativeAuthData(account: "ws-b", user: "u-b", jti: "acct-b1")
            let accountBRefreshedData = try codexNativeAuthData(account: "ws-b", user: "u-b", jti: "acct-b2")

            for (dir, target) in [
                (archiveDir.path, archiveSeed.path),
                (symlinkDir.path, symlinkDir.appendingPathComponent("auth.json").path),
                (symlinkTargetParent.path, symlinkAuthTarget.path),
                (symlinkBakParent.path, symlinkBakDirTarget.path)
            ] {
                var didRestore = false
                var preCheckCode: String?
                do {
                    try ProviderActivationManager.validateNativeCodexWriteTargets(
                        targetDir: dir,
                        targetPath: target,
                        homeDirectory: codexSwitchHome.path
                    )
                    didRestore = true
                } catch let err as ProviderError {
                    preCheckCode = err.code
                }
                check(preCheckCode == "read_only_archive" && !didRestore,
                      "[§47] native archive destination guard must reject \(target) before restore")

                var writeCode: String?
                do {
                    try manager.writeAuthFileWithBackup(
                        targetDir: dir,
                        targetPath: target,
                        data: accountBData,
                        fm: fm,
                        homeDirectory: codexSwitchHome.path
                    )
                } catch let err as ProviderError {
                    writeCode = err.code
                }
                check(writeCode == "read_only_archive",
                      "[§47] writeAuthFileWithBackup must reject archive-backed destination/backup \(target)")
            }

            // Positive ordinary switch & restart reapply outside the archive
            let ordinaryAuth = ordinaryDir.appendingPathComponent("auth.json")
            let ordinaryBak = ordinaryDir.appendingPathComponent("auth.json.bak")
            try accountAData.write(to: ordinaryAuth)
            try ProviderActivationManager.validateNativeCodexWriteTargets(
                targetDir: ordinaryDir.path,
                targetPath: ordinaryAuth.path,
                homeDirectory: codexSwitchHome.path
            )
            try manager.writeAuthFileWithBackup(
                targetDir: ordinaryDir.path,
                targetPath: ordinaryAuth.path,
                data: accountBData,
                fm: fm,
                homeDirectory: codexSwitchHome.path
            )
            check(fm.contents(atPath: ordinaryAuth.path) == accountBData
                  && fm.contents(atPath: ordinaryBak.path) == accountAData,
                  "[§47] ordinary Codex switch must write target auth.json and preserve outgoing auth.json.bak")

            try ProviderActivationManager.validateNativeCodexWriteTargets(
                targetDir: ordinaryDir.path,
                targetPath: ordinaryAuth.path,
                homeDirectory: codexSwitchHome.path
            )
            try manager.writeAuthFileWithBackup(
                targetDir: ordinaryDir.path,
                targetPath: ordinaryAuth.path,
                data: accountBRefreshedData,
                fm: fm,
                homeDirectory: codexSwitchHome.path
            )
            check(fm.contents(atPath: ordinaryAuth.path) == accountBRefreshedData
                  && fm.contents(atPath: ordinaryBak.path) == accountAData,
                  "[§47] ordinary Codex restart reapply must update auth.json while preserving foreign outgoing auth.json.bak")

            let manifestAfter = try recursiveManifest(at: archiveDir)
            check(manifestAfter == manifestBefore && fm.fileExists(atPath: archiveLock.path),
                  "[§47] archive manifest & preexisting.lock must remain unchanged across native guard tests and ordinary switch/restart")
        }

        print("Safe switch regression: \(assertions) assertions PASS")
    }
}
