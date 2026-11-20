import Foundation
import Combine
import os.log
import QuotaBackend

internal let providerRefreshLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderRefresh")

struct AccountCheckError: Equatable {
    let message: String
    let errorCode: String?
    let failedAt: Date
}

// MARK: - ProviderRefreshCoordinator
// Owns provider snapshot refresh, dashboard fetch, localization of fetched data, and account-registry reconciliation.

final class ProviderRefreshCoordinator: ObservableObject {
    static let shared = ProviderRefreshCoordinator()

    @Published var providers: [ProviderData] = [] {
        didSet { syncWeeklyResetPriorities() }
    }
    @Published var overview: DashboardOverview?
    @Published var isLoading = true
    /// 是否完成过首次全量刷新。用于区分「首次加载中（还没拿到任何网络数据）」与
    /// 「确实没有数据」——前者不应展示「凭证过期/没有账号」这类吓人的空态。
    @Published private(set) var hasCompletedInitialLoad = false
    @Published private(set) var didHydrateDiskSnapshots = false
    @Published var errorMessage: String?
    @Published var lastRefreshTime: Date?
    @Published var isRefreshingAllProviders = false
    private var pendingRefreshAfterCurrent = false
    @Published private(set) var refreshingProviderIDs: Set<String> = []
    @Published private(set) var refreshingAccountIDs: Set<String> = []
    @Published var providerRefreshTimes: [String: Date] = [:]
    @Published var accountRefreshTimes: [String: Date] = [:]
    @Published var accountLastCheckErrors: [String: AccountCheckError] = [:]
    private var deletedCredentialKeysThisSession: Set<String> = []

    var codexResetRefreshFence = CodexResetRefreshFence()

    let engine = ProviderEngine()
    private var refreshTimer: Timer?
    private var claudeCodeRefreshTimer: Timer?
    private var callAnalyticsSyncTimer: Timer?
    private var warmupTimer: Timer?
    private var weeklyResetSyncTask: Task<Void, Never>?
    private let weeklyResetWorker = WeeklyResetPriorityWorker()
    private var isCodexFullHistoryRefreshInProgress = false

    /// Used by toolbar / menu bar "Refresh All" buttons to decide between the
    /// spinner and the affordance. Intentionally narrow: single-provider or
    /// single-account refreshes can run for several minutes (Codex archive
    /// import has a 300s timeout), so they must NOT lock out the global
    /// "Refresh All" affordance. Callers that need a stricter "any refresh in
    /// progress" check should compose `refreshingProviderIDs` and
    /// `refreshingAccountIDs` explicitly at the call site.
    var isAnyRefreshInProgress: Bool {
        isLoading || isRefreshingAllProviders
    }

    let settings = AppSettings.shared
    let accountStore = AccountStore.shared

    var discoveryFailureBackoff: [String: Date] = [:]
    let discoveryFailureCooldown: TimeInterval = 5 * 60

    var selectedProviderIds: () -> Set<String> = { [] }
    var providerCatalogIds: () -> [String] = { [] }
    var ensureProviderSelected: (String) -> Void = { _ in }
    var providerTitleForId: (String) -> String = { $0 }

    private init() {
        // 复制给内置 CPA 的 Codex 账号与订阅监控共用一条 refresh_token 链，刷新时要一起读写。
        if CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
           let cliProxyPaths = try? CLIProxyPaths() {
            CodexLinkedCredentialCopies.registerDirectory(cliProxyPaths.authDirectory)
        }
        setupAutoRefresh()
        setupClaudeCodeAutoRefresh()
        setupCallAnalyticsAutoSync()
        EnvironmentOverrideModel.shared.scan()
        WarmupController.shared.providerSnapshot = { [weak self] in self?.providers ?? [] }
        WarmupController.shared.autoRefreshIntervalSeconds = { [weak self] in self?.settings.autoRefreshInterval ?? 300 }
        WarmupController.shared.onWarmupDispatched = { [weak self] in self?.refreshAllProviders(automatic: true) }
        warmupTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            guard let self, self.settings.backendMode == "local" else { return }
            WarmupController.shared.tick(providers: self.providers)
        }
    }

    func configure(
        selectedProviderIds: @escaping () -> Set<String>,
        providerCatalogIds: @escaping () -> [String],
        ensureProviderSelected: @escaping (String) -> Void,
        providerTitleForId: @escaping (String) -> String
    ) {
        self.selectedProviderIds = selectedProviderIds
        self.providerCatalogIds = providerCatalogIds
        self.ensureProviderSelected = ensureProviderSelected
        self.providerTitleForId = providerTitleForId
    }

    private func syncWeeklyResetPriorities() {
        weeklyResetSyncTask?.cancel()
        guard CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
              settings.backendMode == "local" else { return }
        weeklyResetSyncTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            // CPA runs exclusively for Codex (Go & Free); exclude Antigravity/other providers.
            let observations = self.providers.flatMap { provider -> [WeeklyResetPriority.Observation] in
                guard provider.baseProviderId.lowercased() == "codex",
                      let email = provider.accountLabel else { return [] }
                return provider.windows.compactMap { window in
                    guard QuotaBurnRate.windowDuration(label: window.label) == 7 * 86400, let reset = window.resetAt,
                          let date = SharedFormatters.parseISO8601(reset) else { return nil }
                    return .init(provider: provider.baseProviderId, email: email, reset: date, accountID: provider.accountId)
                }
            }
            do {
                let paths = try CLIProxyPaths()
                try await self.weeklyResetWorker.sync(authDirectory: paths.authDirectory, policyURL: paths.stateURL, observations: observations)
            } catch is CancellationError { }
            catch { if !Task.isCancelled, self.errorMessage == nil { self.errorMessage = error.localizedDescription } }
        }
    }

    // MARK: - Timers

    func setupAutoRefresh() {
        refreshTimer?.invalidate()
        let normalized = AppSettings.normalizedAutoRefreshInterval(settings.autoRefreshInterval)
        if settings.autoRefreshInterval != normalized {
            settings.autoRefreshInterval = normalized
        }

        if settings.autoRefreshInterval > 0 {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.autoRefreshInterval) * Double.random(in: 0.85...1.25), repeats: false) { [weak self] _ in
                self?.refreshAllProviders(automatic: true)
            }
        }
    }

    func setupClaudeCodeAutoRefresh() {
        claudeCodeRefreshTimer?.invalidate()
        let normalized = AppSettings.normalizedClaudeCodeRefreshInterval(settings.claudeCodeRefreshInterval)
        if settings.claudeCodeRefreshInterval != normalized {
            settings.claudeCodeRefreshInterval = normalized
        }

        if settings.claudeCodeRefreshInterval > 0 {
            claudeCodeRefreshTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.claudeCodeRefreshInterval), repeats: true) { [weak self] _ in
                self?.refreshLocalTokenStatsOnly()
            }
        }
    }

    func setupCallAnalyticsAutoSync() {
        callAnalyticsSyncTimer?.invalidate()
        let normalized = AppSettings.normalizedAutoRefreshInterval(settings.autoRefreshInterval)
        if settings.autoRefreshInterval != normalized {
            settings.autoRefreshInterval = normalized
        }

        if settings.autoRefreshInterval > 0 {
            callAnalyticsSyncTimer = Timer.scheduledTimer(withTimeInterval: TimeInterval(settings.autoRefreshInterval), repeats: true) { [weak self] _ in
                self?.syncCallAnalytics()
            }
        }
    }

    private func syncCallAnalytics() {
        Task {
            await CallAnalyticsEngine.shared.syncToday()
        }
    }

    // MARK: - Public refresh API

    func refreshAllProviders(automatic: Bool = false) {
        Task { @MainActor in
            if isRefreshingAllProviders {
                if !automatic { pendingRefreshAfterCurrent = true }
                return
            }
            isRefreshingAllProviders = true
            defer { isRefreshingAllProviders = false; setupAutoRefresh() }
            var useRecentResults = automatic
            var isAutomatic = automatic
            repeat {
                pendingRefreshAfterCurrent = false
                _ = await fetchDashboard(useRecentResults: useRecentResults, automatic: isAutomatic)
                useRecentResults = false
                isAutomatic = false
            } while pendingRefreshAfterCurrent
        }
    }

    func refreshLocalTokenStatsOnly() {
        Task { @MainActor in
            // Claude（及 Codex 代理轨）统计读取代理用量永久归档；先把待写入的脏日期
            // 入档落盘（异步等待后台写盘完成），确保引擎随后读到的归档反映最新请求。
            await ProxyViewModel.shared.flushPersistenceAsync()
            // Fan-out so a slow `codex-cost` (300s archive timeout) cannot
            // hold up Claude's refresh. Each call goes through
            // `refreshingProviderIDs` so concurrent refreshes of the same
            // provider still deduplicate inside `refreshProviderNow`.
            let active = ["claude", "codex-cost", "opencode", "antigravity-cost"].filter(selectedProviderIds().contains)
            await withTaskGroup(of: Void.self) { group in
                for providerId in active {
                    group.addTask { @MainActor [weak self] in
                        await self?.refreshProviderNow(providerId)
                    }
                }
            }
            checkClaudeDailyThreshold()
        }
    }

    func refreshCodexCostFullHistoryIfNeeded() {
        Task { @MainActor in
            let providerId = "codex-cost"

            // Front-load the cheap guards so we don't flip the in-progress
            // flag for refreshes that would have bailed anyway. The flag now
            // only covers the actual async work that competes with itself.
            guard settings.backendMode == "local",
                  selectedProviderIds().contains(providerId),
                  !refreshingProviderIDs.contains(providerId),
                  let provider = ProviderRegistry.provider(for: providerId) as? CodexCostProvider,
                  !isCodexFullHistoryRefreshInProgress else {
                return
            }

            isCodexFullHistoryRefreshInProgress = true
            defer { isCodexFullHistoryRefreshInProgress = false }

            guard await provider.needsFullHistoryImport() else { return }
            await provider.requestFullHistoryImport()
            await refreshProviderNow(providerId)
        }
    }

    func refreshProvider(_ providerId: String) {
        Task { @MainActor in
            await refreshProviderNow(providerId)
        }
    }

    func refreshProviderCard(_ provider: ProviderData) {
        Task {
            await refreshProviderCardNow(provider)
        }
    }

    @MainActor
    func refreshProviderCardNow(_ provider: ProviderData) async {
        if let credentialId = credentialID(for: provider) {
            await refreshAccountNow(credentialId: credentialId, providerId: provider.baseProviderId)
        } else {
            await refreshProviderNow(provider.baseProviderId)
        }
    }

    func refreshAccount(credentialId: String, providerId: String) {
        Task {
            await refreshAccountNow(credentialId: credentialId, providerId: providerId)
        }
    }

    @MainActor
    func refreshProviderNow(_ providerId: String) async {
        guard selectedProviderIds().contains(providerId),
              !refreshingProviderIDs.contains(providerId) else { return }
        refreshingProviderIDs.insert(providerId)
        defer { refreshingProviderIDs.remove(providerId) }
        errorMessage = nil
        let result = await fetchSingleProvider(providerId)
        completeProviderRefresh(providerId: providerId, result: result)
        errorMessage = result.userMessage
    }

    @MainActor
    func refreshAccountNow(credentialId: String, providerId: String) async {
        guard selectedProviderIds().contains(providerId) else { return }
        let refreshKey = accountRefreshKey(providerId: providerId, credentialId: credentialId)
        guard !refreshingAccountIDs.contains(refreshKey) else { return }
        refreshingAccountIDs.insert(refreshKey)
        defer { refreshingAccountIDs.remove(refreshKey) }
        errorMessage = nil
        let result = await fetchAccountByCredential(
            credentialId: credentialId,
            providerId: providerId
        )
        completeAccountRefresh(refreshKey: refreshKey, result: result)
        errorMessage = result.userMessage
    }

    /// 消费结果回读必须发起新请求；不走会跳过 in-flight 的手动刷新入口，也不回退到整个 provider。
    @MainActor
    func refreshCodexAccountAfterReset(credentialId: String, identity: CodexAccountIdentity) async -> Bool {
        guard settings.backendMode == "local", let key = identity.nativeKey,
              let credential = AccountCredentialStore.shared.loadCredential(providerId: "codex", credentialId: credentialId),
              CodexAccountIdentity(credential: credential).nativeKey == key else { return false }
        codexResetRefreshFence.invalidate(key)
        defer { codexResetRefreshFence.invalidate(key) }
        let result = await fetchAccountByCredential(credentialId: credentialId, providerId: "codex", expectedCodexIdentity: key)
        completeAccountRefresh(refreshKey: accountRefreshKey(providerId: "codex", credentialId: credentialId), result: result)
        return result.shouldUpdateTimestamps
    }

    @MainActor
    func fetchSingleProvider(_ providerId: String) async -> ProviderRefreshResult {
        guard selectedProviderIds().contains(providerId) else {
            return .failure()
        }
        if settings.backendMode == "local" {
            return await fetchSingleProviderLocal(providerId)
        } else {
            return await fetchSingleProviderRemote(providerId)
        }
    }

    @MainActor
    @discardableResult
    func fetchDashboard(useRecentResults: Bool = false, automatic: Bool = false) async -> ProviderRefreshResult {
        let isInitialLoad = providers.isEmpty && overview == nil
        if isInitialLoad { isLoading = true }
        errorMessage = nil

        guard !selectedProviderIds().isEmpty else {
            providers = []
            overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                summaries: [],
                generatedAt: SharedFormatters.iso8601String(from: Date())
            )), language: language)
            isLoading = false
            hasCompletedInitialLoad = true
            return .emptySuccess()
        }

        let result: ProviderRefreshResult
        if settings.backendMode == "local" {
            result = await fetchDashboardLocal(useRecentResults: useRecentResults, automatic: automatic)
        } else {
            result = await fetchDashboardRemote(showMessageOnFailure: providers.isEmpty)
        }

        completeGlobalRefresh(result)
        errorMessage = result.userMessage
        isLoading = false
        hasCompletedInitialLoad = true
        return result
    }

    nonisolated static func shouldSkipImmediateProviderRefresh(for providerId: String) -> Bool {
        switch providerId.lowercased() {
        case "codex", "antigravity", "gemini", "gemini-cli", "cursor":
            return true
        default:
            return false
        }
    }

    @MainActor
    func syncExcludedAccountsToEngine() async {
        let filters = accountStore.excludedEngineAccountFilters()
        await engine.setExcludedAccounts(
            credentialIDs: filters.credentialIDs,
            codexNativeKeys: filters.codexNativeKeys
        )
    }

    @discardableResult
    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String
    ) throws -> String {
        deletedCredentialKeysThisSession.remove(accountRefreshKey(providerId: credential.providerId, credentialId: credential.id))
        let result = try accountStore.registerAuthenticatedCredential(
            credential,
            usage: usage,
            note: note,
            providerDisplayTitle: providerDisplayTitle,
            insertImmediateProviderData: { [weak self] providerId, credentialId, accountLabel, usage in
                self?.insertImmediateProviderData(
                    providerId: providerId,
                    credentialId: credentialId,
                    accountLabel: accountLabel,
                    usage: usage
                )
            },
            ensureProviderSelected: ensureProviderSelected
        )
        Task { @MainActor [weak self] in
            await self?.syncExcludedAccountsToEngine()
        }
        return result
    }

    func insertImmediateProviderData(
        providerId: String,
        credentialId: String,
        accountLabel: String?,
        usage: ProviderUsage
    ) {
        guard let providerFetcher = ProviderRegistry.provider(for: providerId) else { return }

        var summary = UsageNormalizer.normalize(provider: providerFetcher, usage: usage)
        summary.id = "\(providerId):cred:\(credentialId)"
        summary.providerId = providerId
        summary.accountId = usage.usageAccountId
        if summary.accountLabel?.nilIfBlank == nil {
            summary.accountLabel = accountLabel
        }

        let providerData = localizeProviderData(convertSummary(summary), language: settings.language)

        let isPendingMetadata = (usage.extra["snapshotState"]?.value as? String) == "pending"

        // 用户首次连接时，旧的「未连接」占位（`not_logged_in` / `missing_token`）必须随凭证写入立刻清掉。
        // 否则 fetchSingleProvider 完成前 UI 会渲染「占位 ghost + 真卡片」两张，连接成功后看到「多出一张空卡」。
        providers.removeAll { $0.baseProviderId == providerId && $0.needsCredentialConnection }

        if let index = providers.firstIndex(where: { $0.id == providerData.id }) {
            let existing = providers[index]
            let hasCachedQuota = !existing.windows.isEmpty
                || existing.remainingPercent != nil
                || existing.fetchedAt?.nilIfBlank != nil
            if !(isPendingMetadata && hasCachedQuota) {
                providers[index] = providerData
            }
        } else {
            providers.append(providerData)
            providers = providers.sorted(by: providerSort)
        }
        guard !isPendingMetadata else { return }
        clearAccountCheckError(for: providerData, credentialId: credentialId)
        if let fetchedDate = resolvedFetchedDate(for: providerData) {
            markAccountRefreshed(providerData, at: fetchedDate)
        }
        if QuotaSnapshotStore.supportedProviders.contains(providerId.lowercased()) {
            Task { [weak self] in
                guard let self,
                      let credential = AccountCredentialStore.shared.loadCredential(providerId: providerId, credentialId: credentialId) else {
                    return
                }
                await self.syncExcludedAccountsToEngine()
                await self.engine.persistAuthenticatedSnapshot(
                    providerId: providerId,
                    usage: usage,
                    credential: credential
                )
            }
        }
    }

    @MainActor
    func hydrateFromDiskCacheIfNeeded() async {
        guard !didHydrateDiskSnapshots else { return }
        didHydrateDiskSnapshots = true
        guard settings.backendMode == "local" else { return }

        let ids = Array(Set(selectedProviderIDList()).intersection(QuotaSnapshotStore.supportedProviders))
        guard !ids.isEmpty else { return }

        await syncExcludedAccountsToEngine()
        let snapshot = await engine.cachedDashboard(ids: ids, spawnBackgroundRefresh: false)
        let language = self.language
        let batch = await Task.detached { [self] in
            localizedDashboard(from: snapshot, language: language)
        }.value

        let hydrated = batch.providers.filter { entry in
            entry.ok && entry.provider.errorCode != "unavailable" && entry.provider.errorCode != "refresh_pending"
        }.map(\.provider)

        let cleanSummaries = snapshot.providers
            .filter { $0.ok && $0.summary?.errorCode != "unavailable" && $0.summary?.errorCode != "refresh_pending" }
            .compactMap(\.summary)
        let computedOverview = UsageNormalizer.createDashboardOverview(
            summaries: cleanSummaries,
            generatedAt: snapshot.generatedAt
        )
        let hydratedOverview = localizeOverview(convertOverview(computedOverview), language: language)

        guard !hydrated.isEmpty else {
            if overview == nil {
                overview = hydratedOverview
            }
            return
        }

        var merged = providers
        for candidate in hydrated {
            if let idx = merged.firstIndex(where: { $0.id == candidate.id }) {
                if merged[idx].status == .error && candidate.status != .error {
                    merged[idx] = candidate
                }
            } else if !isProviderHidden(candidate) {
                merged.append(candidate)
            }
            if let acquiredAt = resolvedFetchedDate(for: candidate) {
                markAccountRefreshed(candidate, at: acquiredAt)
            }
        }
        providers = merged.sorted(by: providerSort)
        overview = hydratedOverview
        for providerId in Set(hydrated.map(\.baseProviderId)) {
            if let latest = hydrated
                .filter({ $0.baseProviderId == providerId })
                .compactMap(resolvedFetchedDate(for:))
                .max() {
                providerRefreshTimes[providerId] = max(providerRefreshTimes[providerId] ?? .distantPast, latest)
            }
        }
    }

    @MainActor
    func markInitialLoadCompletedFromCache() {
        if overview == nil {
            overview = localizeOverview(
                convertOverview(
                    UsageNormalizer.createDashboardOverview(
                        summaries: [],
                        generatedAt: SharedFormatters.iso8601String(from: Date())
                    )
                ),
                language: language
            )
        }
        isLoading = false
        hasCompletedInitialLoad = true
    }

    struct SnapshotPurgeTarget {
        let entryId: String
        let providerId: String
        let liveProviderId: String?
        let storageKeys: Set<String>
        let credentialIds: Set<String>
        let fallbackAccountIds: Set<String>
        let fallbackEmails: Set<String>
    }

    func snapshotPurgeTarget(
        for entry: ProviderAccountEntry,
        matchedCredentials: [AccountCredential]
    ) -> SnapshotPurgeTarget {
        var credIds: Set<String> = []
        var storageKeys: Set<String> = []
        var acctIds: Set<String> = []
        var emails: Set<String> = []

        if let credId = entry.storedAccount?.credentialId?.nilIfBlank {
            credIds.insert(credId)
        }
        if let live = entry.liveProvider, let liveCredId = credentialID(for: live)?.nilIfBlank {
            credIds.insert(liveCredId)
        }
        for credential in matchedCredentials {
            credIds.insert(credential.id)
            if let key = QuotaSnapshotStore.canonicalStorageKey(for: credential) {
                storageKeys.insert(key)
            }
        }
        if let live = entry.liveProvider {
            if entry.providerId.lowercased() == "codex",
               let acct = live.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank,
               let userId = live.workspaceUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank {
                storageKeys.insert(QuotaSnapshotIdentity.codexNative(accountId: acct, userId: userId).storageKey)
            } else if entry.providerId.lowercased() == "antigravity",
                      let email = live.accountLabel?.nilIfBlank {
                let rawProject = live.metrics.first(where: { $0.label == "Project" })?.value.nilIfBlank
                let projectId = rawProject.flatMap {
                    let lower = $0.lowercased()
                    return (lower == "unknown" || lower == "aicode-consumers") ? nil : $0
                }
                if projectId != nil {
                    storageKeys.insert(QuotaSnapshotIdentity.antigravityEmail(email: email, projectId: projectId).storageKey)
                }
            }
            if let acct = live.accountId?.nilIfBlank { acctIds.insert(acct) }
            if let label = live.accountLabel?.nilIfBlank { emails.insert(label) }
        }
        if let stored = entry.storedAccount {
            if entry.providerId.lowercased() == "codex",
               let acct = stored.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank,
               let userId = stored.workspaceUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank {
                storageKeys.insert(QuotaSnapshotIdentity.codexNative(accountId: acct, userId: userId).storageKey)
            }
            if let storedAcctId = stored.accountId?.nilIfBlank { acctIds.insert(storedAcctId) }
            if let storedEmail = stored.email.nilIfBlank { emails.insert(storedEmail) }
        }

        let hasSpecificIdentity = !credIds.isEmpty || !storageKeys.isEmpty
        return SnapshotPurgeTarget(
            entryId: entry.id,
            providerId: entry.providerId,
            liveProviderId: entry.liveProvider?.id,
            storageKeys: storageKeys,
            credentialIds: credIds,
            fallbackAccountIds: hasSpecificIdentity ? [] : acctIds,
            fallbackEmails: hasSpecificIdentity ? [] : emails
        )
    }

    @MainActor
    func purgePersistedSnapshots(for deletedEntries: [ProviderAccountEntry]) async {
        let targets = deletedEntries.map {
            snapshotPurgeTarget(for: $0, matchedCredentials: [])
        }
        await purgePersistedSnapshots(targets: targets)
    }

    @MainActor
    func purgePersistedSnapshots(targets: [SnapshotPurgeTarget]) async {
        for target in targets {
            for credId in target.credentialIds {
                let key = accountRefreshKey(providerId: target.providerId, credentialId: credId)
                deletedCredentialKeysThisSession.insert(key)
                accountRefreshTimes.removeValue(forKey: key)
                accountLastCheckErrors.removeValue(forKey: key)
            }
            if let liveProviderId = target.liveProviderId {
                accountLastCheckErrors.removeValue(forKey: liveProviderId)
                accountRefreshTimes.removeValue(forKey: accountRefreshKey(providerId: target.providerId, providerDataId: liveProviderId))
            }
            await engine.purgePersistedSnapshots(
                providerId: target.providerId,
                storageKeys: target.storageKeys,
                credentialIds: target.credentialIds,
                accountIds: target.fallbackAccountIds,
                emails: target.fallbackEmails
            )
        }
    }

    func removeProviders(matchingBaseProviderIds removed: Set<String>) {
        providers.removeAll { removed.contains($0.baseProviderId) }
    }

    func removeProviders(matchingBaseProviderId providerId: String) {
        providers.removeAll { $0.baseProviderId == providerId }
    }

    /// Drop in-memory live rows for a deleted/hidden account so the UI updates before the next refresh.
    func removeLiveProviders(matching entry: ProviderAccountEntry) {
        if let live = entry.liveProvider {
            let identity = liveProviderIdentity(live)
            providers.removeAll {
                if live.baseProviderId == "codex" {
                    return $0.baseProviderId == "codex" && AccountIdentityPolicy.codexLiveAccountsMatch($0, live)
                }
                return $0.id == live.id || liveProviderIdentity($0) == identity
            }
            return
        }

        providers.removeAll { provider in
            guard provider.baseProviderId == entry.providerId else { return false }
            if let stored = entry.storedAccount {
                return accountStore.matchesStoredWithLive(stored, provider: provider)
            }
            return false
        }
    }

    func removeLiveProviders(matching entries: [ProviderAccountEntry]) {
        for entry in entries {
            removeLiveProviders(matching: entry)
        }
    }

    func reapplyVisibleSortedProviders() {
        providers = visibleProviders(from: providers).sorted(by: providerSort)
    }

    func buildProviderEntries(
        providerId: String,
        providerTitle: String,
        providerSubtitle: String?,
        liveProviders: [ProviderData],
        storedAccounts: [StoredProviderAccount]
    ) -> [ProviderAccountEntry] {
        var remainingLive = liveProviders
        var entries: [ProviderAccountEntry] = []
        var codexOwners: [String: String] = [:]
        if providerId == "codex" {
            // 与刷新协调使用同一归属规则，旧记录不能抢走原生身份完整的另一张卡片。
            for live in liveProviders {
                if let owner = AccountIdentityPolicy.bestStoredAccountIndex(
                    in: storedAccounts, for: live, excluding: [], allowUnseenCredentialFallback: false
                ) {
                    codexOwners[live.id] = storedAccounts[owner].id
                }
            }
        }

        for stored in storedAccounts {
            let matches = remainingLive.filter { live in
                if providerId == "codex" {
                    return codexOwners[live.id] == stored.id
                }
                return accountStore.matchesStoredWithLive(stored, provider: live)
            }

            if let preferredLive = preferredLiveProvider(among: matches, storedAccount: stored) {
                let consumedIDs = Set(matches.map(\.id))
                remainingLive.removeAll { consumedIDs.contains($0.id) }
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: preferredLive,
                        storedAccount: stored
                    )
                )
            } else {
                entries.append(
                    ProviderAccountEntry(
                        id: stored.id,
                        providerId: providerId,
                        providerTitle: providerTitle,
                        providerSubtitle: providerSubtitle,
                        liveProvider: nil,
                        storedAccount: stored
                    )
                )
            }
        }

        let unmatchedLive = Dictionary(grouping: remainingLive, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }

        for live in unmatchedLive {
            entries.append(
                ProviderAccountEntry(
                    id: live.id,
                    providerId: providerId,
                    providerTitle: providerTitle,
                    providerSubtitle: providerSubtitle,
                    liveProvider: live,
                    storedAccount: nil
                )
            )
        }

        return entries
    }

    func providerRefreshDate(for providerId: String) -> Date? {
        if let refreshedAt = providerRefreshTimes[providerId] {
            return refreshedAt
        }

        return providers
            .filter { $0.baseProviderId == providerId }
            .compactMap { accountRefreshDate(for: $0) }
            .max()
    }

    func isCredentialStillRegistered(providerId: String, credentialId: String) -> Bool {
        let key = accountRefreshKey(providerId: providerId, credentialId: credentialId)
        if deletedCredentialKeysThisSession.contains(key) {
            return false
        }
        return AccountCredentialStore.shared.loadCredential(providerId: providerId, credentialId: credentialId) != nil
    }

    func resolvedFetchedDate(for provider: ProviderData) -> Date? {
        guard let fetchedAt = provider.fetchedAt else { return nil }
        return parseISO8601(fetchedAt)
    }

    func accountRefreshDate(for provider: ProviderData) -> Date? {
        // Card fetchedAt is authoritative when present so shared email/account aliases
        // cannot make an older peer workspace look freshly checked.
        if let fetchedDate = resolvedFetchedDate(for: provider) {
            return fetchedDate
        }
        for key in accountRefreshKeys(for: provider) {
            if let refreshedAt = accountRefreshTimes[key] {
                return refreshedAt
            }
        }
        return nil
    }

    func isLastKnownErrorPreservable(_ provider: ProviderData) -> Bool {
        provider.status != .error
            && !provider.needsCredentialConnection
            && (!provider.windows.isEmpty || provider.remainingPercent != nil || provider.fetchedAt != nil)
    }

    func isTerminalStopFailure(_ provider: ProviderData) -> Bool {
        guard provider.status == .error else { return false }
        let terminalCodes: Set<String> = ["tos_violation", "account_disabled", "unsupported_client", "not_logged_in"]
        return terminalCodes.contains(provider.errorCode ?? "")
    }

    func accountCheckErrorKeys(for provider: ProviderData, credentialId: String? = nil) -> [String] {
        var keys = [provider.id]
        if let resolvedCredId = (credentialId ?? credentialID(for: provider))?.nilIfBlank {
            let credKey = accountRefreshKey(providerId: provider.baseProviderId, credentialId: resolvedCredId)
            if !keys.contains(credKey) {
                keys.append(credKey)
            }
        }
        return keys
    }

    func recordAccountCheckError(
        for provider: ProviderData,
        credentialId: String? = nil,
        message: String,
        errorCode: String?
    ) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = AccountCheckError(message: trimmed, errorCode: errorCode, failedAt: Date())
        for key in accountCheckErrorKeys(for: provider, credentialId: credentialId) {
            accountLastCheckErrors[key] = entry
        }
    }

    func clearAccountCheckError(for provider: ProviderData, credentialId: String? = nil) {
        for key in accountCheckErrorKeys(for: provider, credentialId: credentialId) {
            accountLastCheckErrors.removeValue(forKey: key)
        }
    }

    func lastCheckError(for provider: ProviderData) -> AccountCheckError? {
        for key in accountCheckErrorKeys(for: provider) {
            if let entry = accountLastCheckErrors[key] {
                return entry
            }
        }
        return nil
    }

    func isProviderRefreshInFlight(_ providerId: String) -> Bool {
        isRefreshingAllProviders || refreshingProviderIDs.contains(providerId)
    }

    func isRefreshInProgress(for provider: ProviderData) -> Bool {
        if isRefreshingAllProviders || refreshingProviderIDs.contains(provider.baseProviderId) {
            return true
        }

        return accountRefreshKeys(for: provider).contains { refreshingAccountIDs.contains($0) }
    }
}
