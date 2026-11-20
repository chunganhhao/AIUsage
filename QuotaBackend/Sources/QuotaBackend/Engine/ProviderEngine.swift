import Foundation
import os.log

private let engineLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderEngine")

// MARK: - Provider Engine
// Orchestrates concurrent fetching of all providers and normalization.
// Supports multi-account providers that return results for each account in parallel.

public actor ProviderEngine {
    static let timeoutSeconds: Double = 15
    static let codexCostTimeoutSeconds: Double = 300
    // Droid 抓取需要按序探测多个域名（必要时还要 WorkOS 刷新后重试一轮），单个 15s 预算
    // 经常不够用、被整体超时打断后表现为「不可用」。给它一个更宽裕但仍有上限的预算，
    // 正常情况首个请求即返回、远用不到这个上限，只在网络退化时作为兜底天花板。
    static let droidTimeoutSeconds: Double = 45
    // OpenCode 首次全量导入要复制整库并扫描全部 message 行，大库时 15s 不够；
    // 之后的窗口扫描通常毫秒级，远用不到这个上限。
    static let openCodeTimeoutSeconds: Double = 60

    private struct AutomaticFlightKey: Hashable, Sendable {
        let providerId: String
        let excludedNativeKeys: Set<String>
    }

    private struct CredentialFlightKey: Hashable, Sendable {
        let key: String
        let version: Int
        let localOnly: Bool
    }

    private struct AntigravityTrickleRecord: Sendable {
        var lastCheckedAt: Date
        var backoffUntil: Date?
        var isTerminalStop: Bool = false
        var version: Int
    }

    private static let antigravityAccountCooldownSeconds: TimeInterval = 15 * 60
    private static let antigravityRemoteMinSpacingSeconds: TimeInterval = 3 * 60
    private static let antigravityErrorBackoffSeconds: TimeInterval = 30 * 60
    private static let antigravityPermanentStopCodes: Set<String> = [
        "tos_violation", "account_disabled", "unsupported_client"
    ]

    private static let terminalErrorCodes: Set<String> = [
        "tos_violation", "unsupported_client", "account_disabled", "forbidden", "rate_limited", "invalid_proxy", "local_only_unavailable"
    ]

    private var credentialFlights: [CredentialFlightKey: SingleFlight<ProviderResult>] = [:]
    private var credentialLaneTails: [String: Task<ProviderResult, Never>] = [:]
    private var recentCredentials: [String: (Date, ProviderResult, Int)] = [:]
    private var lastCredentialResults: [String: (ProviderResult, Int)] = [:]
    private var lastNativeCodexResults: [String: ProviderResult] = [:]
    private var antigravityTrickleByKey: [String: AntigravityTrickleRecord] = [:]
    private var lastAntigravityRemoteCheckAt: Date?
    private var antigravityRemoteSlotInFlight = false
    private var cachedProviders: [String: (Date, [ProviderResult])] = [:]
    private var dashboardTasks: [String: Task<Void, Never>] = [:]
    private var didHydratePersistedSnapshots = false
    private var excludedCredentialIDs: Set<String> = []
    private var excludedCodexNativeKeys: Set<String> = []

    private static let cacheOnlyDashboardProviders: Set<String> = ["antigravity", "codex"]

    private let credentialStore: AccountCredentialStore
    private let providersOverride: [any ProviderFetcher]?
    private let snapshotStore: QuotaSnapshotStore?
    private let nowProvider: @Sendable () -> Date

    public init(
        credentialStore: AccountCredentialStore = .shared,
        providersOverride: [any ProviderFetcher]? = nil,
        homeDirectory: String? = nil,
        snapshotStore: QuotaSnapshotStore? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.credentialStore = credentialStore
        self.providersOverride = providersOverride
        if let snapshotStore {
            self.snapshotStore = snapshotStore
        } else if let homeDirectory {
            self.snapshotStore = QuotaSnapshotStore.store(homeDirectory: homeDirectory)
        } else if let inferredHome = providersOverride?.compactMap({
            ($0 as? AntigravityProvider)?.homeDirectory ?? ($0 as? CodexProvider)?.homeDirectory
        }).first {
            self.snapshotStore = QuotaSnapshotStore.store(homeDirectory: inferredHome)
        } else if credentialStore === AccountCredentialStore.shared && providersOverride == nil {
            self.snapshotStore = QuotaSnapshotStore.defaultStore
        } else {
            self.snapshotStore = nil
        }
        self.nowProvider = now
    }

    public func setExcludedAccounts(credentialIDs: Set<String>, codexNativeKeys: Set<String> = []) {
        let normalizedCredentialIDs = Set(
            credentialIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        let normalizedCodexKeys = Set(
            codexNativeKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        excludedCredentialIDs = normalizedCredentialIDs
        excludedCodexNativeKeys = normalizedCodexKeys

        for (providerId, entry) in cachedProviders {
            let filtered = entry.1.filter { result in
                if let credId = extractCredentialId(from: result.id)?.lowercased(),
                   normalizedCredentialIDs.contains(credId) {
                    return false
                }
                if providerId == "codex",
                   let nativeKey = codexIdentity(for: result).nativeKey?.lowercased(),
                   normalizedCodexKeys.contains(nativeKey) {
                    return false
                }
                return true
            }
            if filtered.isEmpty {
                cachedProviders.removeValue(forKey: providerId)
            } else {
                cachedProviders[providerId] = (entry.0, filtered)
            }
        }

        if !normalizedCodexKeys.isEmpty {
            lastNativeCodexResults = lastNativeCodexResults.filter { key, _ in
                !normalizedCodexKeys.contains(key.lowercased())
            }
        }
    }

    private func isCredentialExcluded(_ credential: AccountCredential) -> Bool {
        if excludedCredentialIDs.contains(credential.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
            return true
        }
        if credential.providerId.lowercased() == "codex",
           let nativeKey = CodexAccountIdentity(credential: credential).nativeKey?.lowercased(),
           excludedCodexNativeKeys.contains(nativeKey) {
            return true
        }
        return false
    }

    private func isCodexNativeKeyExcluded(_ nativeKey: String?) -> Bool {
        guard let nativeKey = nativeKey?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !nativeKey.isEmpty else {
            return false
        }
        return excludedCodexNativeKeys.contains(nativeKey)
    }

    public func hydratePersistedSnapshotsIfNeeded() {
        guard !didHydratePersistedSnapshots, let snapshotStore else { return }
        didHydratePersistedSnapshots = true

        let doc = snapshotStore.loadDocument()
        guard !doc.snapshots.isEmpty else { return }

        for providerId in QuotaSnapshotStore.supportedProviders {
            let allCreds = credentialStore.loadCredentials(for: providerId)
            let creds = allCreds.filter { !isCredentialExcluded($0) }
            var hydratedResults: [ProviderResult] = []
            var hydratedTimestamps: [Date] = []

            for cred in creds {
                let key = "\(providerId):\(cred.id)"
                let version = credentialVersion(for: cred)
                if let provider = resolvedProvider(for: providerId),
                   let suspension = localSuspensionFailure(provider: provider, credential: cred) {
                    lastCredentialResults[key] = (suspension, version)
                    hydratedResults.append(suspension)
                    continue
                }
                if lastCredentialResults[key] == nil,
                   let snap = QuotaSnapshotStore.matchingSnapshot(in: doc, for: cred) {
                    var hydrated = snap.toProviderResult(credentialIdOverride: cred.id)
                    var summary = hydrated.summary
                    summary?.sourceFilePath = credentialSourceFilePath(for: cred)
                    hydrated.summary = summary
                    lastCredentialResults[key] = (hydrated, version)
                    hydratedResults.append(hydrated)
                    if let fetchedAt = summary?.fetchedAt.flatMap(SharedFormatters.parseISO8601) {
                        hydratedTimestamps.append(fetchedAt)
                    }
                }
            }

            if providerId == "codex" {
                let codexHome = resolvedProvider(for: "codex").map { codexHomeDirectory(for: $0) }
                    ?? FileManager.default.homeDirectoryForCurrentUser.path
                if let activeIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome),
                   let accountId = activeIdentity.accountId,
                   let userId = activeIdentity.userId,
                   let nativeKey = activeIdentity.nativeKey,
                   !isCodexNativeKeyExcluded(nativeKey),
                   lastNativeCodexResults[nativeKey] == nil,
                   let nativeSnap = doc.snapshots[QuotaSnapshotIdentity.codexNative(accountId: accountId, userId: userId).storageKey] {
                    let nativeResult = nativeSnap.toProviderResult(credentialIdOverride: nil)
                    lastNativeCodexResults[nativeKey] = nativeResult
                    let vaultCoversNative = allCreds.contains {
                        CodexQuotaPollingPolicy.credentialMatchesActiveIdentity($0, activeIdentity: activeIdentity)
                    }
                    if !vaultCoversNative {
                        hydratedResults.append(nativeResult)
                        if let fetchedAt = nativeResult.summary?.fetchedAt.flatMap(SharedFormatters.parseISO8601) {
                            hydratedTimestamps.append(fetchedAt)
                        }
                    }
                }
            }

            if cachedProviders[providerId] == nil && !hydratedResults.isEmpty {
                cachedProviders[providerId] = (hydratedTimestamps.max() ?? nowProvider(), hydratedResults)
            }
        }
    }

    public func persistAuthenticatedSnapshot(providerId: String, usage: ProviderUsage, credential: AccountCredential) {
        guard (usage.extra["snapshotState"]?.value as? String) != "pending" else { return }
        guard QuotaSnapshotStore.supportedProviders.contains(providerId.lowercased()),
              let provider = resolvedProvider(for: providerId) else { return }
        let uniqueId = "\(providerId):cred:\(credential.id)"
        var normalizedUsage = usage
        if normalizedUsage.usageAccountId?.nilIfBlank == nil {
            normalizedUsage.usageAccountId = resolveAccountIdFromCredential(credential) ?? credential.accountLabel ?? credential.id
        }
        var summary = UsageNormalizer.normalize(provider: provider, usage: normalizedUsage)
        summary.id = uniqueId
        summary.providerId = providerId
        summary.accountId = normalizedUsage.usageAccountId
        summary.accountLabel = summary.accountLabel ?? normalizedUsage.accountEmail ?? credential.accountLabel
        summary.sourceFilePath = credentialSourceFilePath(for: credential)
        let result = ProviderResult(
            id: uniqueId,
            providerId: providerId,
            accountId: summary.accountId,
            ok: true,
            usage: normalizedUsage,
            summary: summary
        )
        let key = "\(providerId):\(credential.id)"
        let version = credentialVersion(for: credential)
        lastCredentialResults[key] = (result, version)
        recordCachedCredentialProjection(providerId: providerId, result: result)
        _ = snapshotStore?.save(result: result, credential: credential)
    }

    public func purgePersistedSnapshots(
        providerId: String,
        storageKeys: Set<String> = [],
        credentialIds: Set<String> = [],
        accountIds: Set<String> = [],
        emails: Set<String> = []
    ) {
        let normalizedProvider = providerId.lowercased()
        let normalizedEmails = Set(emails.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let hasSpecificIdentity = !storageKeys.isEmpty || !credentialIds.isEmpty

        for credId in credentialIds {
            let key = "\(providerId):\(credId)"
            recentCredentials.removeValue(forKey: key)
            lastCredentialResults.removeValue(forKey: key)
            if normalizedProvider == "antigravity" {
                antigravityTrickleByKey.removeValue(forKey: key)
            }
        }

        if let existing = cachedProviders[providerId] {
            let filtered = existing.1.filter { result in
                if let credId = extractCredentialId(from: result.id), credentialIds.contains(credId) {
                    return false
                }
                if storageKeys.contains(QuotaSnapshotStore.identity(from: result).storageKey) {
                    return false
                }
                if !hasSpecificIdentity {
                    if let acct = result.resultAccountId ?? result.summary?.accountId, accountIds.contains(acct) {
                        return false
                    }
                    if let label = result.summary?.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                       normalizedEmails.contains(label) {
                        return false
                    }
                }
                return true
            }
            if filtered.isEmpty {
                cachedProviders.removeValue(forKey: providerId)
            } else {
                cachedProviders[providerId] = (existing.0, filtered)
            }
        }

        if normalizedProvider == "codex" {
            lastNativeCodexResults = lastNativeCodexResults.filter { _, result in
                if storageKeys.contains(QuotaSnapshotStore.identity(from: result).storageKey) {
                    return false
                }
                if !hasSpecificIdentity {
                    if let acct = result.resultAccountId ?? result.summary?.accountId, accountIds.contains(acct) {
                        return false
                    }
                    if let label = result.summary?.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                       normalizedEmails.contains(label) {
                        return false
                    }
                }
                return true
            }
        }

        snapshotStore?.removeSnapshots(
            providerId: providerId,
            storageKeys: storageKeys,
            credentialIds: credentialIds,
            accountIds: hasSpecificIdentity ? [] : accountIds,
            emails: hasSpecificIdentity ? [] : normalizedEmails
        )
    }

    private func resolvedProviders(for ids: [String]? = nil) -> [any ProviderFetcher] {
        if let providersOverride {
            guard let ids else { return providersOverride }
            let wanted = Set(ids)
            return providersOverride.filter { wanted.contains($0.id) }
        }
        return ids.map { ProviderRegistry.providers(for: $0) } ?? ProviderRegistry.allProviders()
    }

    private func resolvedProvider(for id: String) -> (any ProviderFetcher)? {
        if let providersOverride {
            return providersOverride.first { $0.id == id }
        }
        return ProviderRegistry.provider(for: id)
    }

    /// HTTP reads never wait behind a multi-account poll. Cold reads remain
    /// projection-only by default and return terminal `unavailable` on miss
    /// (zero upstream HTTP / OAuth calls).
    public func cachedDashboard(ids: [String]? = nil, spawnBackgroundRefresh: Bool = false) -> DashboardSnapshot {
        hydratePersistedSnapshotsIfNeeded()
        let providers = resolvedProviders(for: ids)
        var results: [ProviderResult] = []
        var timestamps: [Date] = []
        for provider in providers {
            if Self.cacheOnlyDashboardProviders.contains(provider.id) {
                let projected = cachedProjectionResults(for: provider)
                if !projected.isEmpty {
                    results += projected
                    if let cachedDate = cachedProviders[provider.id]?.0 {
                        timestamps.append(cachedDate)
                    }
                } else {
                    let error = ProviderError("unavailable", "No cached quota snapshot available yet.")
                    results.append(ProviderResult(
                        id: provider.id,
                        providerId: provider.id,
                        ok: false,
                        summary: UsageNormalizer.errorSummary(provider: provider, error: error),
                        error: error.localizedDescription
                    ))
                }
                continue
            }

            let cached = cachedProviders[provider.id]
            if spawnBackgroundRefresh,
               cached == nil || nowProvider().timeIntervalSince(cached!.0) >= 90 {
                if dashboardTasks[provider.id] == nil {
                    dashboardTasks[provider.id] = Task {
                        let fetched = await self.fetchAllResults(
                            for: provider,
                            useRecentResults: true,
                            backgroundAutomatic: true,
                            limitAntigravityPool: true,
                            enforceCodexActiveOnly: true
                        )
                        self.cachedProviders[provider.id] = (self.nowProvider(), fetched)
                        self.dashboardTasks[provider.id] = nil
                    }
                }
            }
            if let cached {
                results += cached.1
                timestamps.append(cached.0)
            } else if spawnBackgroundRefresh {
                let error = ProviderError("refresh_pending", "Initial quota refresh is in progress. Read the dashboard again shortly.")
                results.append(ProviderResult(id: provider.id, providerId: provider.id, ok: false,
                    summary: UsageNormalizer.errorSummary(provider: provider, error: error), error: error.localizedDescription))
            } else {
                let error = ProviderError("unavailable", "No cached quota snapshot available yet.")
                results.append(ProviderResult(id: provider.id, providerId: provider.id, ok: false,
                    summary: UsageNormalizer.errorSummary(provider: provider, error: error), error: error.localizedDescription))
            }
        }
        let date = timestamps.min() ?? nowProvider()
        let generated = SharedFormatters.iso8601String(from: date)
        return DashboardSnapshot(generatedAt: generated,
            overview: UsageNormalizer.createDashboardOverview(summaries: results.compactMap(\.summary), generatedAt: generated), providers: results)
    }

    private func cachedProjectionResults(for provider: any ProviderFetcher) -> [ProviderResult] {
        let currentCredentials = (provider as? CredentialAcceptingProvider).map { cp in
            credentialStore.loadCredentials(for: provider.id)
                .filter { cp.supportedAuthMethods.contains($0.authMethod) && !isCredentialExcluded($0) }
        } ?? []

        var projectedById: [String: ProviderResult] = [:]
        var orderedIds: [String] = []

        if let cached = cachedProviders[provider.id]?.1 {
            let validCredentialIDs = Set(currentCredentials.map(\.id))
            for entry in cached {
                if let credId = extractCredentialId(from: entry.id), !validCredentialIDs.contains(credId) {
                    continue
                }
                if provider.id == "codex",
                   isCodexNativeKeyExcluded(codexIdentity(for: entry).nativeKey) {
                    continue
                }
                projectedById[entry.id] = entry
                orderedIds.append(entry.id)
            }
        }

        for credential in currentCredentials {
            let key = "\(provider.id):\(credential.id)"
            let version = credentialVersion(for: credential)
            if let suspension = localSuspensionFailure(provider: provider, credential: credential) {
                if projectedById[suspension.id] == nil { orderedIds.append(suspension.id) }
                projectedById[suspension.id] = suspension
            } else if let preserved = preservedCredentialResult(key: key, version: version, useRecentResults: true) {
                if projectedById[preserved.id] == nil { orderedIds.append(preserved.id) }
                projectedById[preserved.id] = preserved
            }
        }

        if provider.id == "codex" {
            let codexHome = codexHomeDirectory(for: provider)
            let allCodexCredentials = credentialStore.loadCredentials(for: "codex")
            if let activeIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome),
               let activeKey = activeIdentity.nativeKey,
               !isCodexNativeKeyExcluded(activeKey),
               !allCodexCredentials.contains(where: {
                   CodexQuotaPollingPolicy.credentialMatchesActiveIdentity($0, activeIdentity: activeIdentity) && isCredentialExcluded($0)
               }),
               let nativeResult = lastNativeCodexResults[activeKey],
               !orderedIds.contains(where: { codexResultsShareIdentity(projectedById[$0]!, nativeResult) }) {
                projectedById[nativeResult.id] = nativeResult
                orderedIds.append(nativeResult.id)
            }
        }

        return orderedIds.compactMap { projectedById[$0] }
    }

    private func recordCachedProjection(providerId: String, results: [ProviderResult]) {
        guard Self.cacheOnlyDashboardProviders.contains(providerId) else { return }
        if results.isEmpty {
            cachedProviders.removeValue(forKey: providerId)
        } else {
            cachedProviders[providerId] = (nowProvider(), results)
        }
    }

    private func recordCachedCredentialProjection(providerId: String, result: ProviderResult) {
        guard Self.cacheOnlyDashboardProviders.contains(providerId) else { return }
        var existing = cachedProviders[providerId]?.1 ?? []
        if let idx = existing.firstIndex(where: { $0.id == result.id }) {
            existing[idx] = result
        } else {
            existing.append(result)
        }
        cachedProviders[providerId] = (nowProvider(), existing)
    }

    // MARK: - Fetch All

    public func fetchAll(
        ids: [String]? = nil,
        useRecentResults: Bool = false,
        backgroundAutomatic: Bool = false,
        forceAntigravityLocalOnly: Bool = false
    ) async -> DashboardSnapshot {
        let providers = resolvedProviders(for: ids)
        let generatedAt = SharedFormatters.iso8601String(from: nowProvider())

        let results: [ProviderResult] = await withTaskGroup(of: [ProviderResult].self) { group in
            for provider in providers {
                group.addTask {
                    await self.fetchAllResults(
                        for: provider,
                        useRecentResults: useRecentResults,
                        backgroundAutomatic: backgroundAutomatic,
                        limitAntigravityPool: true,
                        enforceCodexActiveOnly: true,
                        forceAntigravityLocalOnly: forceAntigravityLocalOnly
                    )
                }
            }
            var collected: [ProviderResult] = []
            for await batch in group {
                collected.append(contentsOf: batch)
            }
            // Restore original ordering: group by providerId, maintain order within groups
            let providerOrder = providers.map(\.id)
            return collected.sorted { lhs, rhs in
                let lhsIdx = providerOrder.firstIndex(of: lhs.providerId) ?? Int.max
                let rhsIdx = providerOrder.firstIndex(of: rhs.providerId) ?? Int.max
                if lhsIdx != rhsIdx { return lhsIdx < rhsIdx }
                return lhs.id < rhs.id
            }
        }

        let summaries = results.compactMap { $0.summary }
        let overview = UsageNormalizer.createDashboardOverview(summaries: summaries, generatedAt: generatedAt)

        return DashboardSnapshot(generatedAt: generatedAt, overview: overview, providers: results)
    }

    // MARK: - Fetch Single

    public func cachedSingle(id: String) -> ProviderResult? {
        guard let provider = resolvedProvider(for: id) else { return nil }
        hydratePersistedSnapshotsIfNeeded()
        if id == "codex" {
            return cachedCodexActiveResult(for: provider)
        }
        if Self.cacheOnlyDashboardProviders.contains(id) {
            if let projected = cachedProjectionResults(for: provider).first {
                return projected
            }
            let error = ProviderError("unavailable", "No cached quota snapshot available yet.")
            return ProviderResult(
                id: "\(id):auto:default",
                providerId: id,
                ok: false,
                summary: UsageNormalizer.errorSummary(provider: provider, error: error),
                error: error.localizedDescription
            )
        }
        if let cached = cachedProviders[id]?.1.first {
            return cached
        }
        let error = ProviderError("unavailable", "No cached quota snapshot available yet.")
        return ProviderResult(
            id: "\(id):auto:default",
            providerId: id,
            ok: false,
            summary: UsageNormalizer.errorSummary(provider: provider, error: error),
            error: error.localizedDescription
        )
    }

    public func fetchSingle(id: String) async -> ProviderResult? {
        guard let provider = resolvedProvider(for: id) else { return nil }
        if id == "codex" {
            return cachedCodexActiveResult(for: provider)
        }
        return await fetchOne(provider: provider)
    }

    private func cachedCodexActiveResult(for provider: any ProviderFetcher) -> ProviderResult {
        hydratePersistedSnapshotsIfNeeded()
        let codexHome = codexHomeDirectory(for: provider)
        if let activeIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome),
           let activeKey = activeIdentity.nativeKey,
           !isCodexNativeKeyExcluded(activeKey) {
            let credentials = credentialStore.loadCredentials(for: "codex")
            let matchingAll = credentials.filter { CodexQuotaPollingPolicy.credentialMatchesActiveIdentity($0, activeIdentity: activeIdentity) }
            if !matchingAll.contains(where: { isCredentialExcluded($0) }) {
                for credential in matchingAll where !isCredentialExcluded(credential) {
                    let key = "codex:\(credential.id)"
                    let version = credentialVersion(for: credential)
                    if let preserved = preservedCredentialResult(key: key, version: version, useRecentResults: true) {
                        return preserved
                    }
                }
                if let nativeResult = lastNativeCodexResults[activeKey] {
                    return nativeResult
                }
                if let cached = cachedProviders["codex"]?.1.first(where: {
                    codexIdentity(for: $0).nativeKey == activeKey
                }) {
                    return cached
                }
            }
        }
        let error = ProviderError("unavailable", "No cached Codex snapshot available for the active account.")
        return ProviderResult(
            id: "codex:auto:default",
            providerId: "codex",
            ok: false,
            summary: UsageNormalizer.errorSummary(provider: provider, error: error),
            error: error.localizedDescription
        )
    }

    // MARK: - Fetch Single Account (for multi-account providers)

    public func fetchMultiAccountProvider(id: String) async -> [ProviderResult]? {
        guard let provider = resolvedProvider(for: id) else { return nil }
        return await fetchAllResults(
            for: provider,
            limitAntigravityPool: true,
            enforceCodexActiveOnly: true
        )
    }

    // MARK: - Fetch For Specific Credential

    private func isCredentialEligibleForDispatch(providerId: String, credential: AccountCredential) -> Bool {
        !isCredentialExcluded(credential)
            && credentialStore.loadCredential(providerId: providerId, credentialId: credential.id) != nil
    }

    public func fetchForCredential(providerId: String, credentialId: String) async -> ProviderResult? {
        guard let provider = resolvedProvider(for: providerId),
              let credentialProvider = provider as? any CredentialAcceptingProvider,
              let credential = credentialStore.loadCredential(
                providerId: providerId,
                credentialId: credentialId
              ),
              isCredentialEligibleForDispatch(providerId: providerId, credential: credential) else { return nil }
        if providerId == "antigravity" {
            let result = await fetchWithCredential(
                provider: provider,
                credentialProvider: credentialProvider,
                credential: credential,
                localOnly: true
            )
            let stillRegistered = isCredentialEligibleForDispatch(providerId: providerId, credential: credential)
            guard stillRegistered, result.summary?.errorCode != "account_paused" else {
                return nil
            }
            if result.summary?.errorCode == "local_only_unavailable" {
                let key = "\(providerId):\(credential.id)"
                let version = credentialVersion(for: credential)
                return preservedCredentialResult(
                    providerId: providerId,
                    credential: credential,
                    key: key,
                    version: version,
                    useRecentResults: true
                )
            }
            if result.ok || Self.antigravityPermanentStopCodes.contains(result.summary?.errorCode ?? "") {
                recordCachedCredentialProjection(providerId: providerId, result: result)
            }
            return result
        }
        let result = await fetchWithCredential(provider: provider, credentialProvider: credentialProvider, credential: credential)
        let stillRegistered = isCredentialEligibleForDispatch(providerId: providerId, credential: credential)
        guard stillRegistered, result.summary?.errorCode != "account_paused" else {
            return nil
        }
        if result.ok || Self.antigravityPermanentStopCodes.contains(result.summary?.errorCode ?? "") {
            recordCachedCredentialProjection(providerId: providerId, result: result)
        }
        return result
    }

    // MARK: - Internal: Single Account Fetch

    func fetchAllResults(
        for provider: any ProviderFetcher,
        useRecentResults: Bool = false,
        backgroundAutomatic: Bool = false,
        limitAntigravityPool: Bool = false,
        enforceCodexActiveOnly: Bool = false,
        forceAntigravityLocalOnly: Bool = false
    ) async -> [ProviderResult] {
        hydratePersistedSnapshotsIfNeeded()
        let isMultiAccount = provider is MultiAccountProviderFetcher
        let isCodexActiveOnly = provider.id == "codex" && (backgroundAutomatic || enforceCodexActiveOnly)
        let hasAnySupportedCredentials: Bool
        if let credentialProvider = provider as? CredentialAcceptingProvider {
            let creds = credentialStore.loadCredentials(for: provider.id)
            hasAnySupportedCredentials = creds.contains { credentialProvider.supportedAuthMethods.contains($0.authMethod) }
        } else {
            hasAnySupportedCredentials = false
        }

        if hasAnySupportedCredentials && !isMultiAccount {
            let results = await fetchCredentialBackedResults(
                for: provider,
                useRecentResults: useRecentResults,
                backgroundAutomatic: backgroundAutomatic,
                limitAntigravityPool: limitAntigravityPool,
                enforceCodexActiveOnly: enforceCodexActiveOnly,
                forceAntigravityLocalOnly: forceAntigravityLocalOnly
            )
            return results
        }

        if hasAnySupportedCredentials && isMultiAccount {
            // Credential fetches must finish before auto-scan. Running both at
            // once lets two Codex OAuth refreshes burn the same refresh_token;
            // the failed branch then keeps stale quota in the UI.
            let resolvedCredentialResults = await fetchCredentialBackedResults(
                for: provider,
                useRecentResults: useRecentResults,
                backgroundAutomatic: backgroundAutomatic,
                limitAntigravityPool: limitAntigravityPool,
                enforceCodexActiveOnly: enforceCodexActiveOnly,
                forceAntigravityLocalOnly: forceAntigravityLocalOnly
            )
            if provider.id == "antigravity", backgroundAutomatic || limitAntigravityPool {
                recordCachedProjection(providerId: provider.id, results: resolvedCredentialResults)
                return resolvedCredentialResults
            }
            if isCodexActiveOnly {
                let merged = await mergeCodexActiveOnlyAutomaticIfNeeded(
                    provider: provider,
                    credentialBackedResults: resolvedCredentialResults
                )
                recordCachedProjection(providerId: provider.id, results: merged)
                return merged
            }
            let credentialIdentityKeys = Set(
                resolvedCredentialResults.flatMap { identityKeys(for: $0, providerId: provider.id) }
            )
            let excludedNativeKeys = Set(resolvedCredentialResults.filter(\.ok).compactMap { result in
                CodexAccountIdentity(accountId: result.summary?.accountId, userId: result.summary?.workspaceUserId).nativeKey
            }).union(excludedCodexNativeKeys)
            let filteredAutomaticResults = (await fetchAutomaticResults(for: provider, useRecentResults: useRecentResults,
                                                                         excludingNativeKeys: excludedNativeKeys)).filter { result in
                if provider.id == "codex" {
                    return !resolvedCredentialResults.contains {
                        ($0.ok || !result.ok) && codexResultsShareIdentity($0, result)
                    }
                }
                return identityKeys(for: result, providerId: provider.id).isDisjoint(with: credentialIdentityKeys)
            }
            let merged = mergeResults(
                automatic: filteredAutomaticResults,
                credentialBacked: resolvedCredentialResults,
                provider: provider
            )
            return merged.isEmpty ? [await fetchOne(provider: provider)] : merged
        }

        if isCodexActiveOnly {
            let results = await mergeCodexActiveOnlyAutomaticIfNeeded(
                provider: provider,
                credentialBackedResults: []
            )
            recordCachedProjection(providerId: provider.id, results: results)
            return results
        }

        return await fetchAutomaticResults(
            for: provider,
            useRecentResults: useRecentResults,
            excludingNativeKeys: excludedCodexNativeKeys
        )
    }

    private var automaticFlights: [AutomaticFlightKey: SingleFlight<[ProviderResult]>] = [:]
    private var recentAutomatic: [AutomaticFlightKey: (Date, [ProviderResult])] = [:]
    private func fetchAutomaticResults(for provider: any ProviderFetcher, useRecentResults: Bool = false,
                                       excludingNativeKeys: Set<String> = []) async -> [ProviderResult] {
        if provider.id == "codex" {
            let cacheKey = AutomaticFlightKey(providerId: provider.id, excludedNativeKeys: excludingNativeKeys)
            recentAutomatic = recentAutomatic.filter { Date().timeIntervalSince($0.value.0) < 90 }
            if useRecentResults, let recent = recentAutomatic[cacheKey] { return recent.1 }
            guard !Task.isCancelled else { return [] }
            switch reserveFlight(
                in: &automaticFlights, key: cacheKey,
                work: { await self.fetchMultiAccount(provider: provider as! MultiAccountProviderFetcher, excludingNativeKeys: excludingNativeKeys) },
                onFinish: { finished, results in
                    await self.completeAutomaticFlight(key: cacheKey, excludedNativeKeys: excludingNativeKeys, flight: finished, results: results)
                }
            ) {
            case .completed(let results): return results
            case .wait(let flight, let waiterID): return await flight.wait(waiterID: waiterID) { [] }
            }
        }
        if let multiProvider = provider as? MultiAccountProviderFetcher {
            return await fetchMultiAccount(provider: multiProvider)
        }
        return [await fetchOne(provider: provider)]
    }

    private func completeAutomaticFlight(
        key: AutomaticFlightKey,
        excludedNativeKeys: Set<String>,
        flight: SingleFlight<[ProviderResult]>,
        results: [ProviderResult]
    ) {
        if automaticFlights[key] === flight { automaticFlights[key] = nil }
        recentAutomatic = recentAutomatic.filter { Date().timeIntervalSince($0.value.0) < 90 }
        guard !flight.isCancelledResult else { return }
        let cacheable = !results.isEmpty ? results.allSatisfy(\.ok) : !excludedNativeKeys.isEmpty
        if cacheable { recentAutomatic[key] = (Date(), results) }
    }

    private func fetchOne(provider: any ProviderFetcher) async -> ProviderResult {
        let start = Date()
        do {
            let usage = try await withTimeout(seconds: Self.timeoutSeconds(for: provider)) {
                try await provider.fetchUsage()
            }
            let elapsed = Date().timeIntervalSince(start)
            engineLog.debug("✓ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms")
            let autoId = "\(provider.id):auto:\(usage.usageAccountId ?? "default")"
            var summary = UsageNormalizer.normalize(provider: provider, usage: usage)
            summary.id = autoId
            return ProviderResult(id: autoId, providerId: provider.id, accountId: usage.usageAccountId, ok: true, usage: usage, summary: summary)
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            let redactedError = SensitiveDataRedactor.redactedDescription(for: error)
            engineLog.warning("✗ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms - \(redactedError)")
            let autoId = "\(provider.id):auto:default"
            var summary = UsageNormalizer.errorSummary(provider: provider, error: error)
            summary.id = autoId
            return ProviderResult(id: autoId, providerId: provider.id, ok: false, summary: summary, error: redactedError)
        }
    }

    private static func timeoutSeconds(for provider: any ProviderFetcher) -> Double {
        switch provider.id {
        case "codex-cost", "claude": return codexCostTimeoutSeconds
        case "droid": return droidTimeoutSeconds
        case "opencode": return openCodeTimeoutSeconds
        default: return timeoutSeconds
        }
    }

    // MARK: - Internal: Multi-Account Fetch

    private func codexHomeDirectory(for provider: any ProviderFetcher) -> String {
        (provider as? CodexProvider)?.homeDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
    }

    private func antigravityPollingMode(for provider: any ProviderFetcher) -> AntigravityQuotaPollingMode {
        let home = (provider as? AntigravityProvider)?.homeDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        return AntigravityPoolProtectionSettings.pollingMode(homeDirectory: home)
    }

    private func mergeCodexActiveOnlyAutomaticIfNeeded(
        provider: any ProviderFetcher,
        credentialBackedResults: [ProviderResult]
    ) async -> [ProviderResult] {
        let codexHome = codexHomeDirectory(for: provider)
        guard let activeIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome),
              let activeKey = activeIdentity.nativeKey else {
            if credentialBackedResults.isEmpty && credentialStore.loadCredentials(for: provider.id).isEmpty {
                let error = ProviderError("not_logged_in", "No active Codex native account found in ~/.codex/auth.json.")
                return [ProviderResult(
                    id: provider.id,
                    providerId: provider.id,
                    ok: false,
                    summary: UsageNormalizer.errorSummary(provider: provider, error: error),
                    error: error.localizedDescription
                )]
            }
            return credentialBackedResults
        }

        if isCodexNativeKeyExcluded(activeKey) {
            return credentialBackedResults
        }

        let vaultAlreadyCoversActive = credentialStore
            .loadCredentials(for: provider.id)
            .contains { CodexQuotaPollingPolicy.credentialMatchesActiveIdentity($0, activeIdentity: activeIdentity) }
            || credentialBackedResults.contains { codexIdentity(for: $0).nativeKey == activeKey }
        if vaultAlreadyCoversActive {
            return credentialBackedResults
        }

        guard let codex = provider as? CodexProvider,
              let fetchResult = await codex.fetchNativeActiveAccount(expectedNativeKey: activeKey),
              CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome)?.nativeKey == activeKey,
              !isCodexNativeKeyExcluded(activeKey) else {
            return credentialBackedResults
        }

        let liveResult = providerResult(from: fetchResult, provider: provider)
        if liveResult.ok {
            lastNativeCodexResults[activeKey] = liveResult
            _ = snapshotStore?.save(result: liveResult, credential: nil)
        }
        return mergeResults(
            automatic: [liveResult],
            credentialBacked: credentialBackedResults,
            provider: provider
        )
    }

    private func credentialVersion(credentialPath: String, contents: Data?) -> Int {
        var fingerprint = Hasher()
        fingerprint.combine(credentialPath)
        fingerprint.combine(contents)
        return fingerprint.finalize()
    }

    private func credentialVersion(for credential: AccountCredential) -> Int {
        let contents = credential.authMethod == .authFile
            ? FileManager.default.contents(atPath: NSString(string: credential.credential).expandingTildeInPath)
            : nil
        return credentialVersion(credentialPath: credential.credential, contents: contents)
    }

    private func normalizedCredentialEmail(for credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile {
            let path = NSString(string: credential.credential).expandingTildeInPath
            if let data = FileManager.default.contents(atPath: path),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !email.isEmpty {
                return email
            }
        }
        return credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    private static func parsedResultTimestamp(_ result: ProviderResult) -> Date? {
        if let raw = result.summary?.fetchedAt ?? result.usage?.fetchedAt,
           let parsed = SharedFormatters.parseISO8601(raw) {
            return parsed
        }
        return nil
    }

    private static func isTerminalErrorResult(_ result: ProviderResult) -> Bool {
        let code = result.summary?.errorCode ?? ""
        if antigravityPermanentStopCodes.contains(code) {
            return true
        }
        return !result.ok && !code.isEmpty && code != "local_only_unavailable"
    }

    private func preservedCredentialResult(
        providerId: String? = nil,
        credential: AccountCredential? = nil,
        key: String,
        version: Int,
        useRecentResults: Bool
    ) -> ProviderResult? {
        if let providerId, let credential {
            guard isCredentialEligibleForDispatch(providerId: providerId, credential: credential) else {
                return nil
            }
        }
        let now = nowProvider()
        let recentMatch: ProviderResult? = {
            guard let recent = recentCredentials[key], recent.2 == version else { return nil }
            if useRecentResults && now.timeIntervalSince(recent.0) < 90 {
                return recent.1
            }
            return recent.1
        }()
        let preservedMatch: ProviderResult? = {
            guard let preserved = lastCredentialResults[key], preserved.1 == version else { return nil }
            return preserved.0
        }()
        let memoryCandidate: ProviderResult? = {
            switch (recentMatch, preservedMatch) {
            case let (r?, p?):
                if Self.isTerminalErrorResult(p) { return p }
                if Self.isTerminalErrorResult(r) { return r }
                if let rDate = Self.parsedResultTimestamp(r),
                   let pDate = Self.parsedResultTimestamp(p) {
                    return rDate >= pDate ? r : p
                }
                return p
            case let (r?, nil):
                return r
            case let (nil, p?):
                return p
            case (nil, nil):
                return nil
            }
        }()

        if let memoryCandidate, Self.isTerminalErrorResult(memoryCandidate) {
            return memoryCandidate
        }

        if !useRecentResults || providerId == "antigravity",
           let providerId,
           let credential,
           let doc = snapshotStore?.loadDocument(),
           let snap = QuotaSnapshotStore.matchingSnapshot(in: doc, for: credential) {
            let diskDate = SharedFormatters.parseISO8601(snap.fetchedAt)
            if let memoryCandidate,
               let memoryDate = Self.parsedResultTimestamp(memoryCandidate) {
                guard let diskDate, diskDate >= memoryDate else {
                    return memoryCandidate
                }
            }
            var hydrated = snap.toProviderResult(credentialIdOverride: credential.id)
            var summary = hydrated.summary
            summary?.sourceFilePath = credentialSourceFilePath(for: credential)
            hydrated.summary = summary
            lastCredentialResults[key] = (hydrated, version)
            recordCachedCredentialProjection(providerId: providerId, result: hydrated)
            return hydrated
        }
        if useRecentResults,
           let recent = recentCredentials[key],
           recent.2 == version,
           now.timeIntervalSince(recent.0) < 90 {
            return recent.1
        }
        if let preserved = lastCredentialResults[key], preserved.1 == version {
            return preserved.0
        }
        return nil
    }

    private func selectRandomDueAntigravityDormantID(
        candidates: [(credential: AccountCredential, key: String, version: Int)],
        enforceGlobalSpacing: Bool,
        now: Date
    ) -> String? {
        let hasActiveRemoteFlight = credentialFlights.contains {
            $0.key.key.hasPrefix("antigravity:") && !$0.key.localOnly
        }
        guard !candidates.isEmpty, !antigravityRemoteSlotInFlight, !hasActiveRemoteFlight else { return nil }
        if enforceGlobalSpacing,
           let lastRemote = lastAntigravityRemoteCheckAt,
           now.timeIntervalSince(lastRemote) < Self.antigravityRemoteMinSpacingSeconds {
            return nil
        }

        let due = candidates.filter { item in
            guard let record = antigravityTrickleByKey[item.key], record.version == item.version else {
                return true
            }
            if record.isTerminalStop {
                return false
            }
            if let backoffUntil = record.backoffUntil, now < backoffUntil {
                return false
            }
            return now.timeIntervalSince(record.lastCheckedAt) >= Self.antigravityAccountCooldownSeconds
        }
        guard !due.isEmpty else { return nil }

        let unchecked = due.filter {
            guard let record = antigravityTrickleByKey[$0.key] else { return true }
            return record.version != $0.version
        }
        if let chosen = unchecked.shuffled().first {
            return chosen.credential.id
        }
        return due.shuffled().first?.credential.id
    }

    func fetchCredentialBackedResults(
        for provider: any ProviderFetcher,
        useRecentResults: Bool = false,
        backgroundAutomatic: Bool = false,
        limitAntigravityPool: Bool = false,
        enforceCodexActiveOnly: Bool = false,
        forceAntigravityLocalOnly: Bool = false
    ) async -> [ProviderResult] {
        hydratePersistedSnapshotsIfNeeded()
        guard let credentialProvider = provider as? CredentialAcceptingProvider else {
            return []
        }

        let credentials = credentialStore
            .loadCredentials(for: provider.id)
            .filter { credentialProvider.supportedAuthMethods.contains($0.authMethod) && !isCredentialExcluded($0) }

        guard !credentials.isEmpty else { return [] }

        if provider.id == "antigravity" || provider.id == "codex" {
            let isAntigravityPoolManaged = provider.id == "antigravity" && (backgroundAutomatic || limitAntigravityPool)
            let isCodexActiveOnly = provider.id == "codex" && (backgroundAutomatic || enforceCodexActiveOnly)

            if isCodexActiveOnly {
                let codexHome = codexHomeDirectory(for: provider)
                let activeIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome)
                let activeNativePath = AccountCredentialStore.normalizedAuthFilePath(
                    CodexQuotaPollingPolicy.nativeAuthFileURL(homeDirectory: codexHome).path
                )
                let matchingActiveCredential: AccountCredential?
                if let activeIdentity {
                    let matches = credentials.filter {
                        CodexQuotaPollingPolicy.credentialMatchesActiveIdentity($0, activeIdentity: activeIdentity)
                    }
                    matchingActiveCredential = matches.first(where: {
                        AccountCredentialStore.normalizedAuthFilePath($0.credential) == activeNativePath
                    }) ?? matches.first
                } else {
                    matchingActiveCredential = nil
                }

                var results: [ProviderResult] = []
                for credential in credentials {
                    guard !Task.isCancelled else { break }
                    let key = "\(provider.id):\(credential.id)"
                    let version = credentialVersion(for: credential)
                    if let activeCredential = matchingActiveCredential,
                       activeCredential.id == credential.id,
                       let activeIdentity,
                       let activeKey = activeIdentity.nativeKey,
                       CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome)?.nativeKey == activeKey,
                       CodexQuotaPollingPolicy.credentialMatchesActiveIdentity(activeCredential, activeIdentity: activeIdentity) {
                        let result = await fetchWithCredential(
                            provider: provider,
                            credentialProvider: credentialProvider,
                            credential: activeCredential,
                            useRecentResults: useRecentResults,
                            expectedCodexNativeKey: activeKey,
                            codexHomeDirectory: codexHome
                        )
                        // Drop stale response if ~/.codex/auth.json switched away mid-flight.
                        if CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHome)?.nativeKey != activeKey {
                            if isCredentialEligibleForDispatch(providerId: provider.id, credential: activeCredential),
                               let preserved = preservedCredentialResult(key: key, version: version, useRecentResults: useRecentResults) {
                                results.append(preserved)
                            }
                        } else if result.summary?.errorCode != "account_paused",
                                  isCredentialEligibleForDispatch(providerId: provider.id, credential: activeCredential) {
                            results.append(result)
                        }
                    } else if isCredentialEligibleForDispatch(providerId: provider.id, credential: credential),
                              let preserved = preservedCredentialResult(key: key, version: version, useRecentResults: useRecentResults) {
                        results.append(preserved)
                    }
                }
                return results
            }

            let pollingMode = forceAntigravityLocalOnly ? .localOnly : antigravityPollingMode(for: provider)
            let localActiveEmail: String?
            if isAntigravityPoolManaged,
               let reader = (provider as? AntigravityProvider)?.effectiveLocalQuotaReader {
                localActiveEmail = await reader.probeActiveEmail()?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            } else {
                localActiveEmail = nil
            }

            let shuffledCredentials = credentials.shuffled()
            if isAntigravityPoolManaged {
                var localAndImmediateById: [String: ProviderResult] = [:]
                var activeLocalCredentials: [AccountCredential] = []
                var dormantCredentials: [AccountCredential] = []

                for credential in shuffledCredentials {
                    let key = "\(provider.id):\(credential.id)"
                    let version = credentialVersion(for: credential)
                    if let terminal = recentCredentials[key], terminal.2 == version, terminal.1.summary?.errorCode == "tos_violation" {
                        localAndImmediateById[credential.id] = terminal.1
                        continue
                    }
                    if let suspensionFailure = localSuspensionFailure(provider: provider, credential: credential) {
                        localAndImmediateById[credential.id] = suspensionFailure
                        continue
                    }
                    let isActiveLocal = localActiveEmail != nil && normalizedCredentialEmail(for: credential) == localActiveEmail
                    if isActiveLocal {
                        activeLocalCredentials.append(credential)
                    } else {
                        dormantCredentials.append(credential)
                    }
                }

                for credential in activeLocalCredentials {
                    guard !Task.isCancelled,
                          isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else { continue }
                    let key = "\(provider.id):\(credential.id)"
                    let version = credentialVersion(for: credential)
                    let result = await fetchWithCredential(
                        provider: provider,
                        credentialProvider: credentialProvider,
                        credential: credential,
                        useRecentResults: useRecentResults,
                        localOnly: true
                    )
                    guard result.summary?.errorCode != "account_paused" else { continue }
                    if result.summary?.errorCode == "local_only_unavailable" {
                        if let preserved = preservedCredentialResult(
                            providerId: provider.id,
                            credential: credential,
                            key: key,
                            version: version,
                            useRecentResults: useRecentResults
                        ) {
                            localAndImmediateById[credential.id] = preserved
                        }
                    } else {
                        localAndImmediateById[credential.id] = result
                    }
                }

                // Recompute dormant candidates synchronously after local awaits and reserve the remote
                // slot before any await so concurrent ticks cannot bypass the 180s global spacing.
                let dormantCandidates: [(credential: AccountCredential, key: String, version: Int)] = dormantCredentials.compactMap { credential in
                    guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else { return nil }
                    let key = "\(provider.id):\(credential.id)"
                    let version = credentialVersion(for: credential)
                    if let terminal = recentCredentials[key], terminal.2 == version, terminal.1.summary?.errorCode == "tos_violation" {
                        localAndImmediateById[credential.id] = terminal.1
                        return nil
                    }
                    if let suspensionFailure = localSuspensionFailure(provider: provider, credential: credential) {
                        localAndImmediateById[credential.id] = suspensionFailure
                        return nil
                    }
                    return (credential, key, version)
                }

                // Policy compliance: dormant Antigravity accounts never poll remotely.
                _ = pollingMode
                let allowRemoteDormant = false
                let dispatchNow = nowProvider()
                let chosenDormantID = allowRemoteDormant
                    ? selectRandomDueAntigravityDormantID(
                        candidates: dormantCandidates,
                        enforceGlobalSpacing: true,
                        now: dispatchNow
                    )
                    : nil

                var chosenRemoteResultById: [String: ProviderResult] = [:]
                if let chosenDormantID,
                   let chosenItem = dormantCandidates.first(where: { $0.credential.id == chosenDormantID }),
                   isCredentialEligibleForDispatch(providerId: provider.id, credential: chosenItem.credential) {
                    antigravityRemoteSlotInFlight = true
                    lastAntigravityRemoteCheckAt = dispatchNow
                    antigravityTrickleByKey[chosenItem.key] = AntigravityTrickleRecord(
                        lastCheckedAt: dispatchNow,
                        backoffUntil: nil,
                        isTerminalStop: false,
                        version: chosenItem.version
                    )
                    let result = await fetchWithCredential(
                        provider: provider,
                        credentialProvider: credentialProvider,
                        credential: chosenItem.credential,
                        useRecentResults: useRecentResults
                    )
                    antigravityRemoteSlotInFlight = false
                    if result.summary?.errorCode != "account_paused" {
                        chosenRemoteResultById[chosenItem.credential.id] = result
                    }
                }

                var results: [ProviderResult] = []
                for credential in shuffledCredentials {
                    if let entry = localAndImmediateById[credential.id] ?? chosenRemoteResultById[credential.id] {
                        results.append(entry)
                        continue
                    }
                    guard !Task.isCancelled,
                          isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else { continue }
                    let key = "\(provider.id):\(credential.id)"
                    let version = credentialVersion(for: credential)
                    if let preserved = preservedCredentialResult(
                        providerId: provider.id,
                        credential: credential,
                        key: key,
                        version: version,
                        useRecentResults: useRecentResults
                    ) {
                        results.append(preserved)
                    }
                }
                return results
            }

            var results: [ProviderResult] = []
            for credential in shuffledCredentials {
                guard !Task.isCancelled else { break }
                guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else { continue }
                let result = await fetchWithCredential(
                    provider: provider,
                    credentialProvider: credentialProvider,
                    credential: credential,
                    useRecentResults: useRecentResults
                )
                if result.summary?.errorCode != "account_paused" {
                    results.append(result)
                }
            }
            return results
        }
        return await withTaskGroup(of: ProviderResult?.self) { group in
            for credential in credentials {
                group.addTask {
                    let result = await self.fetchWithCredential(provider: provider, credentialProvider: credentialProvider, credential: credential,
                                                              useRecentResults: useRecentResults)
                    return result.summary?.errorCode == "account_paused" ? nil : result
                }
            }
            var results: [ProviderResult] = []
            for await result in group {
                if let result { results.append(result) }
            }
            return results
        }
    }

    private func localSuspensionFailure(provider: any ProviderFetcher, credential: AccountCredential) -> ProviderResult? {
        guard provider.id == "antigravity" else { return nil }
        let data = FileManager.default.contents(atPath: NSString(string: credential.credential).expandingTildeInPath)
        let suspension = data.flatMap { AntigravityAccountProtection.suspension(in: $0) }
        guard let error = suspension ?? (credential.metadata["tosSuspended"] == "true"
            ? ProviderError("tos_violation", "Antigravity account is suspended; re-authenticate to recheck.") : nil) else {
            return nil
        }
        return credentialFailure(provider: provider, credential: credential, error: error)
    }

    private func fetchWithCredential(
        provider: any ProviderFetcher,
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential,
        useRecentResults: Bool = false,
        localOnly: Bool = false,
        expectedCodexNativeKey: String? = nil,
        codexHomeDirectory: String? = nil
    ) async -> ProviderResult {
        let key = "\(provider.id):\(credential.id)"
        let version = credentialVersion(for: credential)
        let flightKey = CredentialFlightKey(key: key, version: version, localOnly: localOnly)
        guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else {
            return credentialFailure(
                provider: provider,
                credential: credential,
                error: ProviderError("account_paused", "Account was paused or removed before dispatch.")
            )
        }
        if let terminal = recentCredentials[key], terminal.2 == version, terminal.1.summary?.errorCode == "tos_violation" { return terminal.1 }
        if let suspensionFailure = localSuspensionFailure(provider: provider, credential: credential) { return suspensionFailure }
        if useRecentResults, let recent = recentCredentials[key], recent.2 == version, nowProvider().timeIntervalSince(recent.0) < 90 { return recent.1 }
        let cancelledFallback = credentialFailure(provider: provider, credential: credential, error: CancellationError())
        guard !Task.isCancelled else { return cancelledFallback }
        let sensitive = (provider.id == "antigravity" && !localOnly) || provider.id == "codex"
        let previous = sensitive ? credentialLaneTails[provider.id] : nil
        let writeRecorder = CredentialWriteRecorder()
        switch reserveFlight(
            in: &credentialFlights, key: flightKey,
            work: {
                if let previous {
                    _ = await previous.value
                    do { try await Task.sleep(for: .milliseconds(Int.random(in: 800...2500))) }
                    catch { return await self.credentialFailure(provider: provider, credential: credential, error: error) }
                }
                guard !Task.isCancelled else { return cancelledFallback }
                guard await self.isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else {
                    return await self.credentialFailure(
                        provider: provider,
                        credential: credential,
                        error: ProviderError("account_paused", "Account was paused or removed before dispatch.")
                    )
                }
                if !localOnly, let suspended = await self.localSuspensionFailure(provider: provider, credential: credential) {
                    return suspended
                }
                if let expectedCodexNativeKey, let codexHomeDirectory {
                    let activeStillMatches = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHomeDirectory)?.nativeKey == expectedCodexNativeKey
                        && CodexQuotaPollingPolicy.credentialIdentity(for: credential)?.nativeKey == expectedCodexNativeKey
                    guard activeStillMatches else {
                        return await self.credentialFailure(
                            provider: provider,
                            credential: credential,
                            error: ProviderError("codex_active_switched", "Active Codex account changed before dispatch.")
                        )
                    }
                }
                return await CredentialWriteRecorder.$current.withValue(writeRecorder) {
                    await self.performFetchWithCredential(
                        provider: provider,
                        credentialProvider: credentialProvider,
                        credential: credential,
                        localOnly: localOnly
                    )
                }
            },
            onCreate: { if sensitive { self.credentialLaneTails[provider.id] = $0.task } },
            onFinish: { finished, result in
                await self.completeCredentialFlight(
                    key: key,
                    flightKey: flightKey,
                    providerId: provider.id,
                    credential: credential,
                    preVersion: version,
                    writtenData: writeRecorder.data(for: credential.credential),
                    expectedCodexNativeKey: expectedCodexNativeKey,
                    codexHomeDirectory: codexHomeDirectory,
                    flight: finished,
                    result: result
                )
            }
        ) {
        case .completed(let result): return result
        case .wait(let flight, let waiterID): return await flight.wait(waiterID: waiterID) { cancelledFallback }
        }
    }

    private func recordAntigravityRemoteOutcome(
        key: String,
        version: Int,
        result: ProviderResult,
        at now: Date
    ) {
        let isLoopback = (result.usage?.extra["transport"]?.value as? String) == "loopback_rpc"
        if !isLoopback {
            lastAntigravityRemoteCheckAt = max(lastAntigravityRemoteCheckAt ?? .distantPast, now)
        }
        let errorCode = result.summary?.errorCode
        let isTerminal = errorCode.map { Self.antigravityPermanentStopCodes.contains($0) } ?? false
        let shouldBackoff = !result.ok && !isTerminal
        antigravityTrickleByKey[key] = AntigravityTrickleRecord(
            lastCheckedAt: now,
            backoffUntil: shouldBackoff ? now.addingTimeInterval(Self.antigravityErrorBackoffSeconds) : nil,
            isTerminalStop: isTerminal,
            version: version
        )
    }

    private func completeCredentialFlight(
        key: String,
        flightKey: CredentialFlightKey,
        providerId: String,
        credential: AccountCredential,
        preVersion: Int,
        writtenData: Data?,
        expectedCodexNativeKey: String? = nil,
        codexHomeDirectory: String? = nil,
        flight: SingleFlight<ProviderResult>,
        result: ProviderResult
    ) {
        if credentialFlights[flightKey] === flight { credentialFlights[flightKey] = nil }
        let staleCodexSwitch: Bool
        if let expectedCodexNativeKey, let codexHomeDirectory {
            staleCodexSwitch = CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: codexHomeDirectory)?.nativeKey != expectedCodexNativeKey
        } else {
            staleCodexSwitch = false
        }
        if !flight.isCancelledResult,
           !staleCodexSwitch,
           result.summary?.errorCode != "local_only_unavailable",
           result.summary?.errorCode != "codex_active_switched",
           result.summary?.errorCode != "account_paused" {
            // Only advance cached file version using bytes this request itself wrote under CAS;
            // external replacements keep preVersion so the next read sees a cache miss.
            let storedVersion = writtenData.map {
                credentialVersion(credentialPath: credential.credential, contents: $0)
            } ?? preVersion
            let now = nowProvider()
            if providerId == "antigravity" && !flightKey.localOnly {
                recordAntigravityRemoteOutcome(key: key, version: storedVersion, result: result, at: now)
            }
            let code = result.summary?.errorCode
            let credentialStillRegistered = credentialStore.loadCredential(providerId: providerId, credentialId: credential.id) != nil
                && !isCredentialExcluded(credential)
            if result.ok && credentialStillRegistered {
                recentCredentials[key] = (now, result, storedVersion)
                lastCredentialResults[key] = (result, storedVersion)
                if QuotaSnapshotStore.supportedProviders.contains(providerId.lowercased()) {
                    _ = snapshotStore?.save(result: result, credential: credential)
                }
            } else if code == "tos_violation" {
                recentCredentials[key] = (now, result, storedVersion)
                lastCredentialResults[key] = (result, storedVersion)
            } else if providerId == "antigravity",
                      let code, Self.antigravityPermanentStopCodes.contains(code),
                      credentialStillRegistered {
                lastCredentialResults[key] = (result, storedVersion)
            }
        }
        // Bound stale entries when credentials are removed from the vault.
        let currentIDs = Set(credentialStore.loadCredentials(for: providerId).map { "\(providerId):\($0.id)" })
        let now = nowProvider()
        recentCredentials = recentCredentials.filter {
            ($0.value.1.summary?.errorCode == "tos_violation" && (currentIDs.contains($0.key) || !$0.key.hasPrefix(providerId + ":")))
                || now.timeIntervalSince($0.value.0) < 90
        }
        lastCredentialResults = lastCredentialResults.filter {
            currentIDs.contains($0.key) || !$0.key.hasPrefix(providerId + ":")
        }
        if providerId == "antigravity" {
            antigravityTrickleByKey = antigravityTrickleByKey.filter { currentIDs.contains($0.key) }
        }
    }

    private enum FlightReservation<Value: Sendable> { case completed(Value), wait(SingleFlight<Value>, UUID) }
    private func reserveFlight<Key: Hashable, Value: Sendable>(
        in storage: inout [Key: SingleFlight<Value>],
        key: Key,
        work: @escaping @Sendable () async -> Value,
        onCreate: ((SingleFlight<Value>) -> Void)? = nil,
        onFinish: @escaping @Sendable (SingleFlight<Value>, Value) async -> Void
    ) -> FlightReservation<Value> {
        if let existing = storage[key] {
            switch existing.reserveWaiter() {
            case .completed(let value): return .completed(value)
            case .reserved(let id): return .wait(existing, id)
            case .unavailable: break
            }
        }
        let created = SingleFlight(work: work, onFinish: onFinish)
        storage[key] = created
        onCreate?(created)
        switch created.reserveWaiter() {
        case .completed(let value): return .completed(value)
        case .reserved(let id): return .wait(created, id)
        case .unavailable: preconditionFailure("New single-flight cannot be unavailable before reservation")
        }
    }

    private func performFetchWithCredential(
        provider: any ProviderFetcher,
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential,
        localOnly: Bool = false
    ) async -> ProviderResult {
        let label = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let fallbackAccountId = resolveAccountIdFromCredential(credential) ?? label ?? credential.id
        let uniqueId = "\(provider.id):cred:\(credential.id)"

        guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else {
            return credentialFailure(
                provider: provider,
                credential: credential,
                error: ProviderError("account_paused", "Account was paused or removed before dispatch.")
            )
        }
        do {
            let usage = try await performCredentialFetch(
                credentialProvider: credentialProvider,
                credential: credential,
                label: label,
                fallbackAccountId: fallbackAccountId,
                localOnly: localOnly
            )
            return buildCredentialSuccess(provider: provider, usage: usage, credential: credential, uniqueId: uniqueId, label: label)
        } catch {
            let redactedError = SensitiveDataRedactor.redactedDescription(for: error)
            engineLog.warning("\(provider.id) credential-backed fetch failed: \(redactedError)")
            guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else {
                return credentialFailure(
                    provider: provider,
                    credential: credential,
                    error: ProviderError("account_paused", "Account was paused or removed before retry.")
                )
            }
            if !localOnly,
               !(error is CancellationError),
               !Self.terminalErrorCodes.contains((error as? ProviderError)?.code ?? ""),
               let refreshed = await refreshFromSourceAndRetry(
                provider: provider, credentialProvider: credentialProvider, credential: credential,
                uniqueId: uniqueId, label: label, fallbackAccountId: fallbackAccountId
            ) {
                return refreshed
            }

            return credentialFailure(provider: provider, credential: credential, error: error)
        }
    }

    private func credentialFailure(provider: any ProviderFetcher, credential: AccountCredential, error: Error) -> ProviderResult {
        let label = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let fallbackAccountId = resolveAccountIdFromCredential(credential) ?? label ?? credential.id
        let uniqueId = "\(provider.id):cred:\(credential.id)"
        let redactedError = SensitiveDataRedactor.redactedDescription(for: error)
        var summary = UsageNormalizer.errorSummary(provider: provider, error: error)
        summary.id = uniqueId
        summary.providerId = provider.id
        summary.accountId = fallbackAccountId
        summary.accountLabel = label
        if provider.id == "codex" {
            summary.accountLabel = CodexAccountIdentity(credential: credential).email ?? label
            summary.workspaceUserId = CodexAccountIdentity(credential: credential).userId
        }
        summary.sourceFilePath = credentialSourceFilePath(for: credential)

        return ProviderResult(
            id: uniqueId,
            providerId: provider.id,
            accountId: fallbackAccountId,
            ok: false,
            summary: summary,
            error: redactedError
        )
    }

    private func performCredentialFetch(
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential,
        label: String?,
        fallbackAccountId: String,
        localOnly: Bool = false
    ) async throws -> ProviderUsage {
        var usage: ProviderUsage
        if localOnly, let antigravityProvider = credentialProvider as? AntigravityProvider {
            usage = try await withTimeout(seconds: Self.timeoutSeconds(for: credentialProvider)) {
                try await antigravityProvider.fetchUsage(with: credential, localOnly: true)
            }
        } else if credentialProvider is CodexProvider {
            usage = try await credentialProvider.fetchUsage(with: credential)
        } else {
            usage = try await withTimeout(seconds: Self.timeoutSeconds(for: credentialProvider)) {
                try await credentialProvider.fetchUsage(with: credential)
            }
        }
        if credentialProvider.id != "claude-subscription", usage.accountEmail?.nilIfBlank == nil { usage.accountEmail = label }
        if usage.accountName?.nilIfBlank == nil { usage.accountName = label }
        if usage.usageAccountId?.nilIfBlank == nil { usage.usageAccountId = fallbackAccountId }
        usage.extra["credentialId"] = AnyCodable(credential.id)
        return usage
    }

    private func buildCredentialSuccess(
        provider: any ProviderFetcher,
        usage: ProviderUsage,
        credential: AccountCredential,
        uniqueId: String,
        label: String?
    ) -> ProviderResult {
        credentialStore.updateLastUsed(credential, codexIdentity: provider.id == "codex"
            ? CodexAccountIdentity(accountId: usage.usageAccountId, userId: usage.extra["userId"]?.value as? String, email: usage.accountEmail)
            : nil)

        var summary = UsageNormalizer.normalize(provider: provider, usage: usage)
        summary.id = uniqueId
        summary.providerId = provider.id
        summary.accountId = usage.usageAccountId
        if summary.accountLabel?.nilIfBlank == nil {
            summary.accountLabel = label
        }
        // Multi-workspace identity anchor: ensure the credential-backed summary
        // carries the same sourceFilePath the automatic scan would produce, so
        // the two branches converge on one identityKey in mergeResults. Without
        // this, Codex would show the same workspace twice (one auto, one cred).
        if summary.sourceFilePath?.nilIfBlank == nil {
            summary.sourceFilePath = credentialSourceFilePath(for: credential)
        }

        return ProviderResult(
            id: uniqueId,
            providerId: provider.id,
            accountId: usage.usageAccountId,
            ok: true,
            usage: usage,
            summary: summary
        )
    }

    private func refreshFromSourceAndRetry(
        provider: any ProviderFetcher,
        credentialProvider: any CredentialAcceptingProvider,
        credential: AccountCredential,
        uniqueId: String,
        label: String?,
        fallbackAccountId: String
    ) async -> ProviderResult? {
        guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else { return nil }
        guard credential.authMethod == .authFile else { return nil }
        guard provider.id != "codex", provider.id != "gemini", provider.id != "kiro" else { return nil }
        let sourcePath = credential.metadata["sourcePath"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !sourcePath.isEmpty else { return nil }

        let sourceExpanded = NSString(string: sourcePath).expandingTildeInPath
        let credentialPath = NSString(string: credential.credential).expandingTildeInPath

        guard sourceExpanded != credentialPath,
              FileManager.default.fileExists(atPath: sourceExpanded),
              let sourceData = FileManager.default.contents(atPath: sourceExpanded) else {
            return nil
        }
        let copiedData = FileManager.default.contents(atPath: credentialPath)
        guard sourceData != copiedData else { return nil }

        guard isCredentialEligibleForDispatch(providerId: provider.id, credential: credential) else { return nil }
        let destinationURL = URL(fileURLWithPath: credentialPath)
        do {
            try sourceData.write(to: destinationURL, options: .atomic)
            CredentialWriteRecorder.current?.record(url: destinationURL, data: sourceData)
        } catch {
            return nil
        }

        do {
            let usage = try await performCredentialFetch(
                credentialProvider: credentialProvider, credential: credential,
                label: label, fallbackAccountId: fallbackAccountId
            )
            return buildCredentialSuccess(
                provider: provider, usage: usage, credential: credential,
                uniqueId: uniqueId, label: label
            )
        } catch let error as ProviderError where Self.terminalErrorCodes.contains(error.code) {
            return credentialFailure(provider: provider, credential: credential, error: error)
        } catch {
            return nil
        }
    }

    private func resolveAccountIdFromCredential(_ credential: AccountCredential) -> String? {
        if let metadataId = credential.metadata["accountId"]?.nilIfBlank {
            return metadataId
        }
        guard credential.authMethod == .authFile else { return nil }
        let path = NSString(string: credential.credential).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let tokens = json["tokens"] as? [String: Any] ?? [:]
        return (tokens["account_id"] as? String)?.nilIfBlank
            ?? (tokens["accountId"] as? String)?.nilIfBlank
            ?? (json["account_id"] as? String)?.nilIfBlank
            ?? (json["accountId"] as? String)?.nilIfBlank
    }

    /// Resolve the on-disk auth file path a credential points to, if any.
    /// Used so multi-workspace providers (Codex) can surface the same
    /// sourceFilePath on credential-backed and automatic-scan results, letting
    /// mergeResults dedupe them. Returns nil for non-authFile credentials.
    private func credentialSourceFilePath(for credential: AccountCredential) -> String? {
        guard credential.authMethod == .authFile else { return nil }
        // Codex 原始路径可被后续登录复用；监控绑定实际托管副本，不绑定共享入口。
        if credential.providerId == "codex" { return credential.credential.nilIfBlank }
        if let original = credential.metadata["sourcePath"]?.nilIfBlank {
            return original
        }
        return credential.credential.nilIfBlank
    }

    private func fetchMultiAccount(provider: MultiAccountProviderFetcher, excludingNativeKeys: Set<String> = []) async -> [ProviderResult] {
        let start = Date()
        let accountResults: [AccountFetchResult]
        if let codex = provider as? CodexProvider {
            accountResults = await codex.fetchAllAccounts(excludingNativeKeys: excludingNativeKeys)
        } else {
            accountResults = await withTimeout(seconds: Self.timeoutSeconds * 2) { await provider.fetchAllAccounts() } ?? []
        }

        if provider.id == "codex", !excludingNativeKeys.isEmpty, accountResults.isEmpty { return [] }
        if accountResults.isEmpty {
            let elapsed = Date().timeIntervalSince(start)
            engineLog.debug("✗ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms - no auto-discovered accounts")
            let summary = UsageNormalizer.errorSummary(
                provider: provider,
                error: ProviderError("not_logged_in", "No accounts found for \(provider.displayName)")
            )
            return [ProviderResult(id: provider.id, ok: false, summary: summary, error: "No accounts found")]
        }

        let elapsed = Date().timeIntervalSince(start)
        engineLog.debug("✓ \(provider.id): \(String(format: "%.0f", elapsed * 1000))ms [\(accountResults.count) accounts]")

        let results = accountResults.map { providerResult(from: $0, provider: provider) }

        let deduplicated = mergeResults(
            automatic: results,
            credentialBacked: [],
            provider: provider
        )

        if deduplicated.count != results.count {
            engineLog.debug("\(provider.id): deduplicated \(results.count - deduplicated.count) duplicate account result(s)")
        }

        return deduplicated
    }

    private func providerResult(from fetchResult: AccountFetchResult, provider: any ProviderFetcher) -> ProviderResult {
        let acctId = fetchResult.accountId
        let uniqueId: String
        if let path = fetchResult.sourceFilePath?.nilIfBlank {
            let normalized = AccountCredentialStore.normalizedAuthFilePath(path)
            uniqueId = "\(provider.id):auto:\(acctId):path:\(normalized)"
        } else {
            uniqueId = "\(provider.id):auto:\(acctId)"
        }
        switch fetchResult.result {
        case .success(let rawUsage):
            var usage = rawUsage
            let effectiveId = usage.usageAccountId?.nilIfBlank ?? acctId
            usage.usageAccountId = effectiveId
            var summary = UsageNormalizer.normalize(provider: provider, usage: usage)
            summary.id = uniqueId
            summary.providerId = provider.id
            summary.accountId = effectiveId
            summary.sourceFilePath = fetchResult.sourceFilePath ?? usage.source?.roots?.first
            return ProviderResult(
                id: uniqueId,
                providerId: provider.id,
                accountId: effectiveId,
                ok: true,
                usage: usage,
                summary: summary
            )
        case .failure(let error):
            var summary = UsageNormalizer.errorSummary(provider: provider, error: error)
            summary.id = uniqueId
            summary.providerId = provider.id
            summary.accountId = acctId
            summary.sourceFilePath = fetchResult.sourceFilePath
            summary.workspaceUserId = fetchResult.workspaceUserId
            if let label = fetchResult.accountLabel {
                summary.accountLabel = label
            }
            return ProviderResult(
                id: uniqueId,
                providerId: provider.id,
                accountId: acctId,
                ok: false,
                summary: summary,
                error: SensitiveDataRedactor.redactedDescription(for: error)
            )
        }
    }

    func mergeResults(
        automatic: [ProviderResult],
        credentialBacked: [ProviderResult],
        provider: any ProviderFetcher
    ) -> [ProviderResult] {
        var mergedByKey: [String: ProviderResult] = [:]
        var orderedKeys: [String] = []
        let shouldDropGenericAutomaticError = !credentialBacked.isEmpty

        for result in automatic + credentialBacked {
            if shouldDropGenericAutomaticError && isGenericAvailabilityError(result, providerId: provider.id) {
                continue
            }

            let key = identityKey(for: result, providerId: provider.id)
            if let existing = mergedByKey[key] {
                if shouldPrefer(result, over: existing) {
                    mergedByKey[key] = result
                }
            } else {
                mergedByKey[key] = result
                orderedKeys.append(key)
            }
        }

        let autoIdentityKeys = Set(automatic.map { identityKey(for: $0, providerId: provider.id) })

        return orderedKeys.compactMap { key -> ProviderResult? in
            guard let result = mergedByKey[key] else { return nil }
            if result.ok { return result }
            // 另一个成员仍正常，不代表这个成员的失败凭据可以从列表消失。
            if provider.id == "codex" { return result }
            guard result.id.contains(":cred:"), !autoIdentityKeys.isEmpty else { return result }
            let credKey = identityKey(for: result, providerId: provider.id)
            if autoIdentityKeys.contains(credKey) { return result }
            let msg = (result.error ?? "").lowercased()
            if msg.contains("unauthorized") || msg.contains("invalid or expired")
                || msg.contains("not_logged_in") || msg.contains("missing_token") {
                return nil
            }
            return result
        }
    }

    private func identityKeys(for result: ProviderResult, providerId: String) -> Set<String> {
        var keys: Set<String> = [identityKey(for: result, providerId: providerId)]
        if let path = result.summary?.sourceFilePath?.nilIfBlank {
            keys.insert("\(providerId):path:\(AccountCredentialStore.normalizedAuthFilePath(path))")
        }
        if let credentialId = extractCredentialId(from: result.id) {
            keys.insert("\(providerId):cred:\(credentialId)")
        }
        return keys
    }

    private func identityKey(for result: ProviderResult, providerId: String) -> String {
        // Multi-workspace: Codex native identity is accountId + userId (same as
        // AccountCredentialStore). Path-first incorrectly keeps AuthImports copies
        // of ~/.codex/auth.json as a second card. Fall back to path / cred only
        // when native components are incomplete.
        if AccountCredentialStore.isMultiWorkspace(providerId) {
            if providerId.lowercased() == "codex" {
                let identity = codexIdentity(for: result)
                let fallback: String
                if let credentialId = extractCredentialId(from: result.id) {
                    fallback = "cred:\(credentialId)"
                } else if let path = result.summary?.sourceFilePath?.nilIfBlank {
                    fallback = "path:\(AccountCredentialStore.normalizedAuthFilePath(path))"
                } else {
                    fallback = "result:\(result.id)"
                }
                return identity.key(fallback: fallback)
            }

            if let path = result.summary?.sourceFilePath?.nilIfBlank {
                let normalized = AccountCredentialStore.normalizedAuthFilePath(path)
                return "\(providerId):path:\(normalized)"
            }
            if let credentialId = extractCredentialId(from: result.id) {
                return "\(providerId):cred:\(credentialId)"
            }
            return "\(providerId):generic:\(result.id)"
        }

        if let accountId = normalizedIdentity(result.resultAccountId)
            ?? normalizedIdentity(result.summary?.accountId)
            ?? normalizedIdentity(result.usage?.usageAccountId) {
            return "\(providerId):id:\(accountId)"
        }

        if let label = normalizedIdentity(result.summary?.accountLabel)
            ?? normalizedIdentity(result.usage?.accountEmail)
            ?? normalizedIdentity(result.usage?.accountLogin)
            ?? normalizedIdentity(result.usage?.accountName) {
            return "\(providerId):label:\(label)"
        }

        return "\(providerId):generic:\(result.id)"
    }

    private func codexIdentity(for result: ProviderResult) -> CodexAccountIdentity {
        CodexAccountIdentity(
            accountId: result.resultAccountId ?? result.summary?.accountId ?? result.usage?.usageAccountId,
            userId: result.summary?.workspaceUserId ?? result.usage?.extra["userId"]?.value as? String,
            email: result.usage?.accountEmail ?? result.summary?.accountLabel
        )
    }

    func codexResultsShareIdentity(_ lhs: ProviderResult, _ rhs: ProviderResult) -> Bool {
        let left = codexIdentity(for: lhs)
        let right = codexIdentity(for: rhs)
        guard !left.conflicts(with: right) else { return false }
        if left.matches(right) { return true }
        if let lhsCredential = extractCredentialId(from: lhs.id),
           let rhsCredential = extractCredentialId(from: rhs.id) {
            return lhsCredential == rhsCredential
        }
        guard let lhsPath = lhs.summary?.sourceFilePath, let rhsPath = rhs.summary?.sourceFilePath else { return false }
        return AccountCredentialStore.normalizedAuthFilePath(lhsPath) == AccountCredentialStore.normalizedAuthFilePath(rhsPath)
    }

    private func extractCredentialId(from resultId: String) -> String? {
        guard let range = resultId.range(of: ":cred:") else { return nil }
        return String(resultId[range.upperBound...]).nilIfBlank
    }

    private func normalizedIdentity(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfBlank
    }

    private func isPlaceholderIdentity(_ value: String?) -> Bool {
        let norm = normalizedIdentity(value)
        return norm == nil || norm == "default"
    }

    private func isGenericAvailabilityError(_ result: ProviderResult, providerId: String) -> Bool {
        guard !result.ok,
              result.providerId == providerId,
              isPlaceholderIdentity(result.resultAccountId),
              isPlaceholderIdentity(result.summary?.accountId),
              normalizedIdentity(result.summary?.accountLabel) == nil,
              normalizedIdentity(result.usage?.accountEmail) == nil else {
            return false
        }

        let message = (result.error ?? result.summary?.headline.secondary ?? "").lowercased()
        return message.contains("no accounts found")
            || message.contains("not logged in")
            || message.contains("not_logged_in")
            || message.contains("no valid")
    }

    private func shouldPrefer(_ candidate: ProviderResult, over existing: ProviderResult) -> Bool {
        if candidate.ok != existing.ok {
            return candidate.ok
        }

        let candidateScore = detailScore(for: candidate)
        let existingScore = detailScore(for: existing)
        if candidateScore != existingScore {
            return candidateScore > existingScore
        }

        return candidate.id < existing.id
    }

    private func detailScore(for result: ProviderResult) -> Int {
        var score = 0
        if normalizedIdentity(result.resultAccountId) != nil || normalizedIdentity(result.summary?.accountId) != nil {
            score += 2
        }
        if normalizedIdentity(result.summary?.accountLabel) != nil
            || normalizedIdentity(result.usage?.accountEmail) != nil
            || normalizedIdentity(result.usage?.accountName) != nil {
            score += 1
        }
        return score
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Timeout Helpers

func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ProviderError("timeout", "Operation timed out after \(Int(seconds))s")
        }
        guard let result = try await group.next() else {
            group.cancelAll()
            throw ProviderError("timeout", "Operation ended without a result.")
        }
        group.cancelAll()
        return result
    }
}

func withTimeout<T: Sendable>(seconds: Double, operation: @escaping @Sendable () async -> T) async -> T? {
    await withTaskGroup(of: T?.self) { group in
        group.addTask { await operation() }
        group.addTask {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            return nil
        }
        if let result = await group.next() ?? nil {
            group.cancelAll()
            return result
        }
        group.cancelAll()
        return nil
    }
}

/// Decouples individual caller cancellation from shared single-flight tasks;
/// the underlying task is cancelled only when every waiter has cancelled.
private final class SingleFlight<Value: Sendable>: @unchecked Sendable {
    enum Reservation { case completed(Value), reserved(UUID), unavailable }

    private let lock = NSLock()
    let task: Task<Value, Never>
    private var waiters: [UUID: CheckedContinuation<Value, Never>] = [:]
    private var activeWaiters: Set<UUID> = []
    private var cancelledWaiters: Set<UUID> = []
    private var completedValue: Value?
    private var invalidated = false

    var isCancelledResult: Bool {
        lock.lock(); defer { lock.unlock() }
        return invalidated || task.isCancelled
    }

    init(work: @escaping @Sendable () async -> Value,
         onFinish: @escaping @Sendable (SingleFlight<Value>, Value) async -> Void) {
        let task = Task { await work() }
        self.task = task
        Task {
            let value = await task.value
            // Commit actor cache/state before resuming any waiters.
            await onFinish(self, value)
            self.finish(value)
        }
    }

    func reserveWaiter() -> Reservation {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { return .unavailable }
        if let completedValue { return .completed(completedValue) }
        let id = UUID()
        activeWaiters.insert(id)
        return .reserved(id)
    }

    func wait(waiterID: UUID, onCancelledValue: @escaping @Sendable () -> Value) async -> Value {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                if let completedValue {
                    activeWaiters.remove(waiterID)
                    lock.unlock()
                    continuation.resume(returning: completedValue)
                    return
                }
                if cancelledWaiters.remove(waiterID) != nil || Task.isCancelled {
                    let hadActive = activeWaiters.remove(waiterID) != nil
                    let cancelTask = hadActive && activeWaiters.isEmpty
                    if cancelTask { invalidated = true }
                    lock.unlock()
                    if cancelTask { task.cancel() }
                    continuation.resume(returning: onCancelledValue())
                    return
                }
                waiters[waiterID] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            guard completedValue == nil else { lock.unlock(); return }
            let hadActive = activeWaiters.remove(waiterID) != nil
            let continuation = waiters.removeValue(forKey: waiterID)
            if continuation == nil && hadActive { cancelledWaiters.insert(waiterID) }
            let cancelTask = hadActive && activeWaiters.isEmpty
            if cancelTask { invalidated = true }
            lock.unlock()
            if cancelTask { task.cancel() }
            continuation?.resume(returning: onCancelledValue())
        }
    }

    private func finish(_ value: Value) {
        lock.lock()
        guard completedValue == nil else { lock.unlock(); return }
        completedValue = value
        let pending = waiters
        waiters.removeAll()
        activeWaiters.removeAll()
        cancelledWaiters.removeAll()
        lock.unlock()
        for continuation in pending.values { continuation.resume(returning: value) }
    }
}
