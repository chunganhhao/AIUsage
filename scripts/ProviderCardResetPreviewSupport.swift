import SwiftUI
import Combine
import QuotaBackend

// 仅用于独立 renderer。所有系统边界均为内存 stub；不扫描、不轮询、不读用户存储。
// ProviderCard / MultiWindowQuotaView / ProviderIconView / GatewayChrome 按正式源码编译。
@MainActor enum FixtureResetEnvironment {
    static var coordinator: CodexResetCreditsCoordinator!
    static var credentialIDs: [String: String] = [:]
}

final class AppSettings: ObservableObject {
    static let shared = AppSettings() // 独立内存配置，不读取 UserDefaults。
    var backendMode = "local"
    enum IndicatorStyle { case bar, ring, segments }
    enum IndicatorMetric { case remaining, used }
    var menuBarPinnedQuotaAccountIds: Set<String> {
        get { [] }
        set {}
    }
    var quotaIndicatorStyle: IndicatorStyle { .bar }
    var quotaIndicatorMetric: IndicatorMetric { .remaining }
    static let cnyPerUSD = 7.0
}
enum DefaultsKey { static let displayCurrency = "fixture-unused-currency" }

@MainActor final class AppState: ObservableObject {
    enum Section { case subscriptionGateway }
    var language: String { fixtureLanguage }
    func presentMainWindow(section: Section) { preconditionFailure("Fixture navigation disabled") }
    func hideAccount(_ account: ProviderAccountEntry) { preconditionFailure("Fixture writes disabled") }
    func deleteAccount(_ account: ProviderAccountEntry) { preconditionFailure("Fixture writes disabled") }
    func updateAccountNote(for account: ProviderAccountEntry, note: String) { preconditionFailure("Fixture writes disabled") }
}

@MainActor final class ProviderRefreshCoordinator: ObservableObject {
    func refreshCodexAccountAfterReset(credentialId: String, identity: CodexAccountIdentity) async -> Bool {
        preconditionFailure("Fixture account refresh disabled")
    }
    func isRefreshInProgress(for provider: ProviderData) -> Bool { false }
    func accountRefreshDate(for provider: ProviderData) -> Date? { provider.fetchedAt.flatMap(SharedFormatters.parseISO8601) }
    func refreshProviderCardNow(_ provider: ProviderData) async { preconditionFailure("Fixture refresh disabled") }
    func credentialID(for provider: ProviderData) -> String? { FixtureResetEnvironment.credentialIDs[provider.id] }
}

@MainActor final class ProviderActivationManager: ObservableObject {
    enum Result { case success(String), failure(String) }
    var activationResult: Result?
    static var remoteViewOnlyLabel: String { L("View only", "只读") }
    func canActivateProvider(_ id: String) -> Bool { false }
    func canSwitch(to entry: ProviderAccountEntry) -> Bool { false }
    func isRemoteViewOnly(_ entry: ProviderAccountEntry) -> Bool { entry.id == "fixture-remote" }
    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool { false }
    func activateAccount(entry: ProviderAccountEntry) throws { preconditionFailure("Fixture activation disabled") }
}

struct CLIProxyAccountSyncCandidate {
    enum Compatibility { case compatible }
    let compatibility: Compatibility = .compatible
}
@MainActor final class CLIProxyGatewayManager: ObservableObject {
    static let shared = CLIProxyGatewayManager() // 内存 mock，不是生产 manager。
    struct Runtime {
        struct State { let isRunning = false }
        let state = State()
    }
    let runtime = Runtime()
    func syncCandidate(providerId: String, label: String, credentialId: String) -> CLIProxyAccountSyncCandidate? { nil }
    func syncAccount(_ candidate: CLIProxyAccountSyncCandidate) async { preconditionFailure("Fixture sync disabled") }
    func isSynced(_ candidate: CLIProxyAccountSyncCandidate) -> Bool { false }
}
@MainActor final class CLIProxyGatewayNavigation {
    static let shared = CLIProxyGatewayNavigation()
    func showAccounts() { preconditionFailure("Fixture navigation disabled") }
}
struct ProviderDetailView: View {
    let provider: ProviderData
    let titleOverride: String?
    let subtitleOverride: String?
    let accountDisplayOverride: String?
    let accountEntry: ProviderAccountEntry?
    var body: some View { EmptyView() }
}
struct AccountNoteEditorView: View {
    let providerTitle: String
    let accountLabel: String
    let note: String?
    let onSave: (String) -> Void
    var body: some View { EmptyView() }
}
struct ClaudeSubscriptionAccountActions: View {
    let directory: String
    let needsReconnect: Bool
    var body: some View { EmptyView() }
}
struct SubscriptionAccountDestructiveMenuItems: View {
    let onHide: () -> Void
    let onRequestDelete: () -> Void
    var body: some View { EmptyView() }
}
extension View {
    func subscriptionAccountDeleteConfirmation(isPresented: Binding<Bool>, action: @escaping () -> Void) -> some View { self }
}
enum SensitiveDataRedactor {
    static func redactedMessage(for error: Error) -> String { "Fixture action disabled" }
}

// RefreshableTimeView 保持正式实现，仅时钟源无 timer。
final class GlobalTimeManager: ObservableObject {
    static let shared = GlobalTimeManager()
    @Published var currentTime = Date()
    func startIfNeeded() {}
    func stopIfNeeded() {}
}

// Coordinator 的默认闭包仅需类型匹配；renderer 始终显式注入 scratch 凭据。
final class AccountCredentialStore {
    static let shared = AccountCredentialStore()
    func loadCredential(providerId: String, credentialId: String) -> AccountCredential? {
        preconditionFailure("Fixture must use injected scratch credentials")
    }
}
@MainActor var fixtureLanguage = "en"
@MainActor func L(_ english: String, _ chinese: String) -> String { fixtureLanguage == "zh" ? chinese : english }
