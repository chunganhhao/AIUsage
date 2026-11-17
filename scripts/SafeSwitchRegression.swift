// Exact manager flows with fake app/auth boundaries; real switcher storage tests use a temporary home.
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
    static func hasExternalCodexProcess() -> Bool { Boundary.externalCLI }
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
}
enum ProductionCodexStorageParser {
    // PRODUCTION_CODEX_KEYRING
}
@MainActor final class ProductionCoordinatorFlowFixture {
    struct ProviderData: Identifiable {
        let id: String
        let baseProviderId: String
        let accountId: String?
        let status: Status
        let needsCredentialConnection: Bool
        let sourceFilePath: String?
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
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-safe-switch-\(UUID())")
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
            catch { check(!Boundary.events.contains("mutate") && !Boundary.events.contains("open"), "Quit refusal wrote credentials") }
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
        print("Safe switch regression: \(assertions) assertions PASS")
    }
}
