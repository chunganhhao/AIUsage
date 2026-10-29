import Foundation
import QuotaBackend

// 系统存储使用 AccountIdentityRegressionSupport；注册表提交运行正式 AccountStore。
final class AppSettings {
    static let shared = AppSettings()
    var backendMode = "local"
    var remoteBaseURL = "fixture://offline"
}

// 只在提取的 worker 返回计算结果前暂停，不替换注册表协调或提交逻辑。
@MainActor final class FixtureRegistryGate {
    static let shared = FixtureRegistryGate()
    var sourceToHold: String?
    var continuation: CheckedContinuation<Void, Never>?
    var batches: [[ProviderData]] = []
    func pause(_ providers: [ProviderData]) async {
        batches.append(providers)
        guard let sourceToHold, providers.contains(where: { $0.sourceFilePath == sourceToHold }) else { return }
        self.sourceToHold = nil
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
@MainActor final class FixtureEngine {
    var requested: [String] = []
    var fetch: ((String) async -> ProviderResult?)!
    var multi: (() async -> [ProviderResult]?) = { nil }
    var single: (() async -> ProviderResult?) = { nil }
    var all: (() async -> DashboardSnapshot)!
    func fetchForCredential(providerId: String, credentialId: String) async -> ProviderResult? {
        requested.append(credentialId)
        return await fetch(credentialId)
    }
    func fetchMultiAccountProvider(id: String) async -> [ProviderResult]? { await multi() }
    func fetchSingle(id: String) async -> ProviderResult? { await single() }
    func fetchAll(ids: [String]) async -> DashboardSnapshot { await all() }
}
@MainActor final class APIService {
    static let shared = APIService()
    var results: (() async -> [ProviderWrapper])!
    var dashboard: (() async -> DashboardResponse)!
    func updateBaseURL(_ url: String) {}
    func fetchProviderResults(_ providerId: String) async throws -> [ProviderWrapper] { await results() }
    func fetchDashboard(providerIds: [String]) async throws -> DashboardResponse { await dashboard() }
}
@MainActor final class ProviderRefreshCoordinator {
    var providers: [ProviderData] = []
    var codexResetRefreshFence = CodexResetRefreshFence()
    let settings = AppSettings.shared
    let accountStore = AccountStore.shared
    let engine = FixtureEngine()
    var language = "zh"
    var overview: DashboardOverview?
    var refreshingAccountIDs: Set<String> = []
    nonisolated func localizedDynamicText(_ text: String, _ language: String) -> String { text }
    func providerSort(_ a: ProviderData, _ b: ProviderData) -> Bool { a.id < b.id }
    func isProviderHidden(_ provider: ProviderData) -> Bool { false }
    func currentProviderMatchingRefresh(_ provider: ProviderData) -> ProviderData? { providers.first { $0.id == provider.id } }
    func accountRefreshKey(providerId: String, credentialId: String) -> String { "\(providerId):\(credentialId)" }
    func completeAccountRefresh(refreshKey: String, result: ProviderRefreshResult) {}
    // 不扫描真实账号；fixture 每个原生身份只提供一个候选结果。
    func syncUnifiedManagedAccounts(for providerIds: [String]) async {}
    func stabilizedBulkRefreshProviders(_ incoming: [ProviderData], preservingExistingFor: String? = nil) -> [ProviderData] { incoming }
    func visibleProviders(from providers: [ProviderData]) -> [ProviderData] { providers }
    func timestampableProviders(for providers: [ProviderData]) -> [ProviderData] { providers }
    func selectedProviderIDList() -> [String] { ["codex"] }
    func sendErrorNotification(_ message: String) {}
}
@MainActor var fixtureLanguage = "en"
@MainActor func L(_ english: String, _ chinese: String) -> String { fixtureLanguage == "zh" ? chinese : english }
