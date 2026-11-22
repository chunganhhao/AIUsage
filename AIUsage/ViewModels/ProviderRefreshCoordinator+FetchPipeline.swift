import Foundation
import QuotaBackend

extension ProviderRefreshCoordinator {
    // MARK: - Fetch pipeline

    @MainActor
    func fetchAccountByCredential(
        credentialId: String,
        providerId: String,
        expectedCodexIdentity: String? = nil
    ) async -> ProviderRefreshResult {
        guard settings.backendMode == "local" else {
            return .ignored()
        }
        await syncExcludedAccountsToEngine()
        let resetGeneration = codexResetRefreshFence.token
        guard let result = await engine.fetchForCredential(providerId: providerId, credentialId: credentialId),
              result.summary != nil else {
            return .ignored()
        }
        // convert + localize 在后台执行器完成（Task.detached），主线程只拿回结果。
        let language = self.language
        let convertedBatch = await Task.detached { [self] in
            localizedProviderResults(from: [result], language: language)
        }.value
        guard let converted = convertedBatch.first?.provider else {
            return .ignored()
        }
        guard isCredentialStillRegistered(providerId: providerId, credentialId: credentialId) else {
            return .ignored()
        }
        let identity = codexResetIdentity(converted)
        guard expectedCodexIdentity == nil || expectedCodexIdentity == identity else { return .ignored() }
        guard settings.backendMode == "local", identity.map({ codexResetRefreshFence.accepts(resetGeneration, identity: $0) }) != false else { return .ignored() }
        await reconcileResetProtectedAccountRegistry([converted], since: resetGeneration)
        guard settings.backendMode == "local", identity.map({ codexResetRefreshFence.accepts(resetGeneration, identity: $0) }) != false else { return .ignored() }
        guard isCredentialStillRegistered(providerId: providerId, credentialId: credentialId) else {
            return .ignored()
        }

        let currentVisibleIds = Set(selectedProviderIDList())
        guard currentVisibleIds.contains(converted.baseProviderId),
              !visibleProviders(from: [converted]).isEmpty else {
            let pruned = visibleProviders(from: providers)
                .filter { currentVisibleIds.contains($0.baseProviderId) }
            if pruned.count != providers.count {
                providers = pruned
            }
            if let existingOverview = overview {
                overview = recomputedOverview(
                    for: providers,
                    baseOverview: existingOverview,
                    generatedAt: existingOverview.generatedAt,
                    language: language
                )
            }
            return .ignored()
        }

        let existingIndex = providers.firstIndex(where: { $0.id == converted.id })
            ?? providers.firstIndex(where: { $0.baseProviderId == providerId && $0.id.contains(credentialId) })

        if result.ok {
            clearAccountCheckError(for: converted, credentialId: credentialId)
            if let existingIndex {
                providers[existingIndex] = converted
            } else {
                providers.append(converted)
                providers = providers.sorted(by: providerSort)
            }
            if let existingOverview = overview {
                overview = recomputedOverview(
                    for: providers,
                    baseOverview: existingOverview,
                    generatedAt: existingOverview.generatedAt,
                    language: language
                )
            }
            guard let refreshedProvider = currentProviderMatchingRefresh(converted) else {
                return .failure()
            }
            let acquiredAt = resolvedFetchedDate(for: refreshedProvider)
                ?? ((providerId == "antigravity" || providerId == "codex") ? nil : Date())
            return .success(refreshedProviders: [refreshedProvider], at: acquiredAt)
        }

        if let existingIndex,
           isLastKnownErrorPreservable(providers[existingIndex]),
           !isTerminalStopFailure(converted) {
            recordAccountCheckError(
                for: providers[existingIndex],
                credentialId: credentialId,
                message: result.error ?? converted.headline.primary,
                errorCode: result.summary?.errorCode
            )
            return .failure(userMessage: result.error)
        }

        clearAccountCheckError(for: converted, credentialId: credentialId)
        if let existingIndex {
            providers[existingIndex] = converted
        } else {
            providers.append(converted)
            providers = providers.sorted(by: providerSort)
        }
        if let existingOverview = overview {
            overview = recomputedOverview(
                for: providers,
                baseOverview: existingOverview,
                generatedAt: existingOverview.generatedAt,
                language: language
            )
        }
        return .failure()
    }

    @MainActor
    func syncUnifiedManagedAccounts(for providerIds: [String]) async {
        guard settings.backendMode == "local" else { return }

        let uniqueProviderIDs = Array(Set(providerIds)).sorted()
        guard !uniqueProviderIDs.isEmpty else { return }

        for providerId in uniqueProviderIDs {
            await Task.yield()
            let candidates = ProviderAuthManager.unmanagedCandidates(for: providerId)
            guard !candidates.isEmpty else { continue }

            for candidate in candidates {
                let expectedCodexKey: String?
                if providerId == "codex" {
                    guard candidate.authMethod == .authFile,
                          let activeIdentity = CodexQuotaPollingPolicy.activeNativeIdentity(),
                          let activeKey = activeIdentity.nativeKey,
                          let candidateIdentity = CodexQuotaPollingPolicy.verifiedNativeIdentity(atPath: candidate.credentialValue),
                          candidateIdentity.nativeKey == activeKey else {
                        continue
                    }
                    expectedCodexKey = activeKey
                } else {
                    expectedCodexKey = nil
                }
                let backoffKey = discoveryBackoffKey(for: candidate)
                if let retryAfter = discoveryFailureBackoff[backoffKey], retryAfter > Date() {
                    continue
                }

                if shouldSuppressAutoManagedCandidate(candidate, providerId: providerId) {
                    discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                    continue
                }

                if let expectedCodexKey,
                   CodexQuotaPollingPolicy.activeNativeIdentity()?.nativeKey != expectedCodexKey {
                    continue
                }

                do {
                    let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(
                        candidate,
                        localOnly: true,
                        allowLocalMetadataFallback: providerId != "antigravity"
                    )
                    if let expectedCodexKey {
                        let currentActiveKey = CodexQuotaPollingPolicy.activeNativeIdentity()?.nativeKey
                        let credentialKey = CodexQuotaPollingPolicy.credentialIdentity(for: credential)?.nativeKey
                        if currentActiveKey != expectedCodexKey || credentialKey != expectedCodexKey {
                            if candidate.shouldCopyFile,
                               credential.authMethod == .authFile,
                               credential.credential != candidate.sourcePath {
                                try? FileManager.default.removeItem(atPath: credential.credential)
                            }
                            continue
                        }
                    }
                    if shouldSuppressAutoManagedAccount(
                        providerId: providerId,
                        usage: usage,
                        credential: credential
                    ) {
                        if candidate.shouldCopyFile,
                           credential.authMethod == .authFile,
                           credential.credential != candidate.sourcePath {
                            try? FileManager.default.removeItem(atPath: credential.credential)
                        }
                        discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                        continue
                    }

                    try registerAuthenticatedCredential(
                        credential,
                        usage: usage,
                        note: nil,
                        providerDisplayTitle: providerTitleForId(providerId)
                    )
                    discoveryFailureBackoff.removeValue(forKey: backoffKey)
                } catch let error as ProviderError where error.code == "local_only_unavailable" {
                    // Antigravity automatic discovery never sends Google HTTPS when IDE loopback is unavailable.
                    continue
                } catch {
                    discoveryFailureBackoff[backoffKey] = Date().addingTimeInterval(discoveryFailureCooldown)
                }
            }
        }
    }

    func discoveryBackoffKey(for candidate: ProviderAuthCandidate) -> String {
        [
            candidate.providerId,
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            candidate.title.lowercased()
        ].joined(separator: "|")
    }

    func normalizedAccountLookupValue(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func shouldSuppressAutoManagedCandidate(
        _ candidate: ProviderAuthCandidate,
        providerId: String
    ) -> Bool {
        var normalizedEmail = normalizedAccountLookupValue(candidate.title)
        var normalizedAccountId: String?
        var workspaceUserId: String?
        let sourceFilePath = candidate.sourcePath?.nilIfBlank
            ?? (candidate.authMethod == .authFile ? candidate.credentialValue.nilIfBlank : nil)

        if candidate.authMethod == .authFile,
           let path = sourceFilePath,
           let json = ProviderAuthManager.loadJSONObject(at: path) {
            if providerId == "codex" {
                let identity = CodexAccountIdentity(authJSON: json)
                normalizedEmail = normalizedAccountLookupValue(identity.email) ?? normalizedEmail
                normalizedAccountId = normalizedAccountLookupValue(identity.accountId)
                workspaceUserId = identity.userId
            } else {
                normalizedEmail = normalizedAccountLookupValue(json["email"] as? String) ?? normalizedEmail
                normalizedAccountId = normalizedAccountLookupValue(
                    (json["account_id"] as? String)
                        ?? (json["accountId"] as? String)
                        ?? (json["project_id"] as? String)
                        ?? (json["projectId"] as? String)
                )
            }
        }

        return accountStore.hasHiddenRegistryMatch(
            providerId: providerId,
            normalizedEmail: normalizedEmail,
            normalizedAccountId: normalizedAccountId,
            sourceFilePath: sourceFilePath,
            workspaceUserId: workspaceUserId
        )
    }

    func shouldSuppressAutoManagedAccount(
        providerId: String,
        usage: ProviderUsage,
        credential: AccountCredential? = nil
    ) -> Bool {
        let normalizedEmail = normalizedAccountLookupValue(
            usage.accountEmail?.nilIfBlank
                ?? usage.accountLogin?.nilIfBlank
                ?? usage.accountName?.nilIfBlank
        )
        let normalizedAccountId = normalizedAccountLookupValue(
            usage.usageAccountId?.nilIfBlank
                ?? usage.accountLogin?.nilIfBlank
        )
        let sourceFilePath = credential.flatMap(AccountIdentityPolicy.credentialAuthFilePath)

        return accountStore.hasHiddenRegistryMatch(
            providerId: providerId,
            normalizedEmail: normalizedEmail,
            normalizedAccountId: normalizedAccountId,
            sourceFilePath: sourceFilePath,
            workspaceUserId: usage.extra["userId"]?.value as? String
        )
    }

    @MainActor
    func fetchSingleProviderLocal(_ providerId: String) async -> ProviderRefreshResult {
        let resetGeneration = codexResetRefreshFence.token
        let refreshedAt = Date()
        await syncExcludedAccountsToEngine()
        await syncUnifiedManagedAccounts(for: [providerId])
        await syncExcludedAccountsToEngine()
        let language = self.language

        if let results = await engine.fetchMultiAccountProvider(id: providerId) {
            // convert + localize 在后台执行器完成（Task.detached），主线程只拿回结果。
            let convertedResults = await Task.detached { [self] in
                localizedProviderResults(from: results, language: language)
            }.value
            guard selectedProviderIDList().contains(providerId) else {
                replaceProviderEntries(for: providerId, with: [])
                return .ignored()
            }
            let stabilizedResults = stabilizedBulkRefreshProviders(
                convertedResults.map(\.provider),
                preservingExistingFor: providerId
            )
            await reconcileResetProtectedAccountRegistry(stabilizedResults, since: resetGeneration)
            guard selectedProviderIDList().contains(providerId) else {
                replaceProviderEntries(for: providerId, with: [])
                return .ignored()
            }
            let visible = visibleProviders(from: preserveCodexResetUpdates(stabilizedResults, since: resetGeneration, providerId: providerId))
            replaceProviderEntries(for: providerId, with: visible)
            guard !visible.isEmpty else {
                return .ignored()
            }
            let timestampable = timestampableProviders(
                for: convertedResults.filter(\.ok).map(\.provider)
            )
            let latestAcquiredAt = timestampable.compactMap(resolvedFetchedDate(for:)).max()
                ?? ((providerId == "antigravity" || providerId == "codex") ? nil : refreshedAt)
            return .classified(
                totalResults: results.count,
                refreshedProviders: timestampable,
                at: latestAcquiredAt
            )
        } else if let result = await engine.fetchSingle(id: providerId),
                  result.summary != nil {
            let convertedResults = await Task.detached { [self] in
                localizedProviderResults(from: [result], language: language)
            }.value
            guard let converted = convertedResults.first?.provider else { return .ignored() }
            guard selectedProviderIDList().contains(providerId),
                  !visibleProviders(from: [converted]).isEmpty else {
                let remainingVisible = selectedProviderIDList().contains(providerId)
                    ? visibleProviders(from: providers.filter { $0.baseProviderId == providerId })
                    : []
                replaceProviderEntries(for: providerId, with: remainingVisible)
                return .ignored()
            }
            if !result.ok,
               let existing = providers.first(where: { $0.baseProviderId == providerId && isLastKnownErrorPreservable($0) }),
               !isTerminalStopFailure(converted) {
                recordAccountCheckError(
                    for: existing,
                    credentialId: credentialID(for: existing),
                    message: result.error ?? converted.headline.primary,
                    errorCode: result.summary?.errorCode
                )
                return .failure(userMessage: result.error)
            }
            if result.ok {
                clearAccountCheckError(for: converted, credentialId: credentialID(for: converted))
            }
            await reconcileResetProtectedAccountRegistry([converted], since: resetGeneration)
            guard selectedProviderIDList().contains(providerId),
                  !visibleProviders(from: [converted]).isEmpty else {
                let remainingVisible = selectedProviderIDList().contains(providerId)
                    ? visibleProviders(from: providers.filter { $0.baseProviderId == providerId })
                    : []
                replaceProviderEntries(for: providerId, with: remainingVisible)
                return .ignored()
            }
            replaceProviderEntries(for: providerId, with: visibleProviders(from: preserveCodexResetUpdates([converted], since: resetGeneration, providerId: providerId)))
            let timestampable = result.ok ? timestampableProviders(for: [converted]) : []
            let latestAcquiredAt = timestampable.compactMap(resolvedFetchedDate(for:)).max()
                ?? ((providerId == "antigravity" || providerId == "codex") ? nil : refreshedAt)
            return .classified(
                totalResults: 1,
                refreshedProviders: timestampable,
                at: latestAcquiredAt
            )
        }
        return .ignored()
    }

    @MainActor
    func fetchSingleProviderRemote(_ providerId: String) async -> ProviderRefreshResult {
        let resetGeneration = codexResetRefreshFence.token
        let refreshedAt = Date()
        APIService.shared.updateBaseURL(settings.remoteBaseURL)
        do {
            let results = try await APIService.shared.fetchProviderResults(providerId)
            // 主线程仅重组为 Sendable 元组（无正则），本地化在后台执行器完成。
            let language = self.language
            let remoteItems = results.map { (provider: $0.summary, ok: $0.ok) }
            let localizedProviders = await Task.detached { [self] in
                localizedProviderList(remoteItems, language: language)
            }.value
            guard selectedProviderIDList().contains(providerId) else {
                replaceProviderEntries(for: providerId, with: [])
                return .ignored()
            }
            await reconcileResetProtectedAccountRegistry(localizedProviders.map(\.provider), since: resetGeneration)
            guard selectedProviderIDList().contains(providerId) else {
                replaceProviderEntries(for: providerId, with: [])
                return .ignored()
            }
            let visible = visibleProviders(from: preserveCodexResetUpdates(localizedProviders.map(\.provider), since: resetGeneration, providerId: providerId))
            replaceProviderEntries(for: providerId, with: visible)
            guard !visible.isEmpty else {
                return .ignored()
            }
            return .classified(
                totalResults: results.count,
                refreshedProviders: timestampableProviders(
                    for: localizedProviders.filter(\.ok).map(\.provider)
                ),
                at: refreshedAt
            )
        } catch {
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            sendErrorNotification("Remote refresh failed for \(providerId): \(redactedError)")
            guard selectedProviderIDList().contains(providerId) else {
                return .ignored()
            }
            return .failure(
                userMessage: !providers.contains(where: { $0.baseProviderId == providerId })
                    ? redactedError
                    : nil
            )
        }
    }

    @MainActor
    func fetchDashboardLocal(useRecentResults: Bool = false, automatic: Bool = false) async -> ProviderRefreshResult {
        let requestedIds = selectedProviderIDList()
        guard !requestedIds.isEmpty else {
            providers = []
            overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                summaries: [],
                generatedAt: SharedFormatters.iso8601String(from: Date())
            )), language: language)
            return .emptySuccess()
        }
        let requestedIdSet = Set(requestedIds)
        let resetGeneration = codexResetRefreshFence.token
        let refreshedAt = Date()
        await syncExcludedAccountsToEngine()
        await syncUnifiedManagedAccounts(for: requestedIds)
        await syncExcludedAccountsToEngine()

        let snapshot = await engine.fetchAll(
            ids: requestedIds,
            useRecentResults: useRecentResults,
            backgroundAutomatic: automatic
        )
        // 整批 convert + localize（含 overview）在后台执行器完成，主线程只做赋值与 UI 协调。
        let language = self.language
        let batch = await Task.detached { [self] in
            localizedDashboard(from: snapshot, language: language)
        }.value
        let localizedProviders = batch.providers
        // Antigravity never batch-polls all dormant accounts; keep existing cards when not returned in this tick.
        let stabilizedProviders = stabilizedBulkRefreshProviders(
            localizedProviders.map(\.provider),
            includingExistingFor: ["antigravity"]
        )
        await reconcileResetProtectedAccountRegistry(stabilizedProviders, since: resetGeneration)
        let currentVisibleIds = Set(selectedProviderIDList())
        guard !currentVisibleIds.isEmpty else {
            providers = []
            overview = recomputedOverview(
                for: [],
                baseOverview: nil,
                generatedAt: SharedFormatters.iso8601String(from: Date()),
                language: language
            )
            return .emptySuccess()
        }
        let coveredVisibleIds = currentVisibleIds.intersection(requestedIdSet)
        guard !coveredVisibleIds.isEmpty else {
            let pruned = visibleProviders(from: providers)
                .filter { currentVisibleIds.contains($0.baseProviderId) }
            if pruned.count != providers.count {
                providers = pruned
                if let existingOverview = overview {
                    overview = recomputedOverview(
                        for: pruned,
                        baseOverview: existingOverview,
                        generatedAt: existingOverview.generatedAt,
                        language: language
                    )
                }
            }
            return .ignored(status: .success)
        }
        let uncoveredVisibleExisting = visibleProviders(from: providers)
            .filter { currentVisibleIds.contains($0.baseProviderId) && !coveredVisibleIds.contains($0.baseProviderId) }
        let coveredUpdates = visibleProviders(from: preserveCodexResetUpdates(stabilizedProviders, since: resetGeneration))
            .filter { coveredVisibleIds.contains($0.baseProviderId) }
        let finalProviders = (uncoveredVisibleExisting + coveredUpdates).sorted(by: providerSort)
        providers = finalProviders
        let coveredRowIDs = Set(coveredUpdates.map(\.id))
        let uncoveredRowIDs = Set(uncoveredVisibleExisting.map(\.id))
        let preservedUncoveredAlerts = (overview?.alerts ?? []).filter { uncoveredRowIDs.contains($0.providerId) }
        let mergedBaseOverview = preservedUncoveredAlerts.isEmpty
            ? batch.overview
            : DashboardOverview(
                generatedAt: batch.overview.generatedAt,
                activeProviders: batch.overview.activeProviders,
                attentionProviders: batch.overview.attentionProviders,
                criticalProviders: batch.overview.criticalProviders,
                resetSoonProviders: batch.overview.resetSoonProviders,
                localCostMonthUsd: batch.overview.localCostMonthUsd,
                localWeekTokens: batch.overview.localWeekTokens,
                stats: batch.overview.stats,
                alerts: batch.overview.alerts + preservedUncoveredAlerts
            )
        overview = recomputedOverview(
            for: finalProviders,
            baseOverview: mergedBaseOverview,
            generatedAt: batch.overview.generatedAt,
            language: language
        )
        let refreshedBatch = localizedProviders
            .filter {
                $0.ok && coveredVisibleIds.contains($0.provider.baseProviderId)
                    && coveredRowIDs.contains($0.provider.id)
                    && acceptsCodexResetRefresh($0.provider, since: resetGeneration)
            }
            .map(\.provider)
        let latestAcquiredAt = refreshedBatch.compactMap(resolvedFetchedDate(for:)).max()
            ?? (refreshedBatch.allSatisfy { $0.baseProviderId == "antigravity" || $0.baseProviderId == "codex" } ? nil : refreshedAt)
        return .classified(
            totalResults: snapshot.providers.count,
            refreshedProviders: refreshedBatch,
            at: latestAcquiredAt,
            shouldUpdateErrorBanner: currentVisibleIds.isSubset(of: requestedIdSet)
        )
    }

    @MainActor
    func fetchDashboardRemote(showMessageOnFailure: Bool) async -> ProviderRefreshResult {
        let requestedIds = selectedProviderIDList()
        guard !requestedIds.isEmpty else {
            providers = []
            overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                summaries: [],
                generatedAt: SharedFormatters.iso8601String(from: Date())
            )), language: language)
            return .emptySuccess()
        }
        var lastAttemptedIds = Set(requestedIds)
        let resetGeneration = codexResetRefreshFence.token
        let refreshedAt = Date()
        APIService.shared.updateBaseURL(settings.remoteBaseURL)
        do {
            var dashboard = try await APIService.shared.fetchDashboard(providerIds: requestedIds)
            // Cold HTTP reads are immediate; follow pending data even when the
            // user's auto-refresh timer is Off. This polls the cache, not Google.
            for _ in 0..<180 {
                guard dashboard.providers.contains(where: { $0.summary.errorCode == "refresh_pending" }) else { break }
                try await Task.sleep(for: .seconds(2))
                let followUpIds = selectedProviderIDList()
                guard !followUpIds.isEmpty else {
                    providers = []
                    overview = localizeOverview(convertOverview(UsageNormalizer.createDashboardOverview(
                        summaries: [],
                        generatedAt: SharedFormatters.iso8601String(from: Date())
                    )), language: language)
                    return .emptySuccess()
                }
                lastAttemptedIds = Set(followUpIds)
                dashboard = try await APIService.shared.fetchDashboard(providerIds: followUpIds)
            }
            // 主线程仅重组为 Sendable 元组（无正则）；providers + overview 本地化在后台执行器完成。
            let language = self.language
            let remoteItems = dashboard.providers.map { (provider: $0.summary, ok: $0.ok) }
            let remoteOverview = dashboard.overview
            let batch = await Task.detached { [self] in
                localizedRemoteDashboard(remoteItems, overview: remoteOverview, language: language)
            }.value
            let localizedProviders = batch.providers
            let stabilizedProviders = stabilizedBulkRefreshProviders(localizedProviders.map(\.provider))
            await reconcileResetProtectedAccountRegistry(stabilizedProviders, since: resetGeneration)
            let currentVisibleIds = Set(selectedProviderIDList())
            guard !currentVisibleIds.isEmpty else {
                providers = []
                overview = recomputedOverview(
                    for: [],
                    baseOverview: nil,
                    generatedAt: SharedFormatters.iso8601String(from: Date()),
                    language: language
                )
                return .emptySuccess()
            }
            let coveredVisibleIds = currentVisibleIds.intersection(lastAttemptedIds)
            guard !coveredVisibleIds.isEmpty else {
                let pruned = visibleProviders(from: providers)
                    .filter { currentVisibleIds.contains($0.baseProviderId) }
                if pruned.count != providers.count {
                    providers = pruned
                    if let existingOverview = overview {
                        overview = recomputedOverview(
                            for: pruned,
                            baseOverview: existingOverview,
                            generatedAt: existingOverview.generatedAt,
                            language: language
                        )
                    }
                }
                return .ignored(status: .success)
            }
            let uncoveredVisibleExisting = visibleProviders(from: providers)
                .filter { currentVisibleIds.contains($0.baseProviderId) && !coveredVisibleIds.contains($0.baseProviderId) }
            let coveredUpdates = visibleProviders(from: preserveCodexResetUpdates(stabilizedProviders, since: resetGeneration))
                .filter { coveredVisibleIds.contains($0.baseProviderId) }
            let finalProviders = (uncoveredVisibleExisting + coveredUpdates).sorted(by: providerSort)
            providers = finalProviders
            let coveredRowIDs = Set(coveredUpdates.map(\.id))
            let uncoveredRowIDs = Set(uncoveredVisibleExisting.map(\.id))
            let preservedUncoveredAlerts = (overview?.alerts ?? []).filter { uncoveredRowIDs.contains($0.providerId) }
            let mergedBaseOverview = preservedUncoveredAlerts.isEmpty
                ? batch.overview
                : DashboardOverview(
                    generatedAt: batch.overview.generatedAt,
                    activeProviders: batch.overview.activeProviders,
                    attentionProviders: batch.overview.attentionProviders,
                    criticalProviders: batch.overview.criticalProviders,
                    resetSoonProviders: batch.overview.resetSoonProviders,
                    localCostMonthUsd: batch.overview.localCostMonthUsd,
                    localWeekTokens: batch.overview.localWeekTokens,
                    stats: batch.overview.stats,
                    alerts: batch.overview.alerts + preservedUncoveredAlerts
                )
            overview = recomputedOverview(
                for: finalProviders,
                baseOverview: mergedBaseOverview,
                generatedAt: batch.overview.generatedAt,
                language: language
            )
            return .classified(
                totalResults: dashboard.providers.count,
                refreshedProviders: localizedProviders
                    .filter {
                        $0.ok && coveredVisibleIds.contains($0.provider.baseProviderId)
                            && coveredRowIDs.contains($0.provider.id)
                            && acceptsCodexResetRefresh($0.provider, since: resetGeneration)
                    }
                    .map(\.provider),
                at: refreshedAt,
                shouldUpdateErrorBanner: currentVisibleIds.isSubset(of: lastAttemptedIds)
            )
        } catch {
            let currentVisibleIds = Set(selectedProviderIDList())
            let coveredVisibleIds = currentVisibleIds.intersection(lastAttemptedIds)
            guard !coveredVisibleIds.isEmpty else {
                return .ignored()
            }
            let shouldPublishFailure = showMessageOnFailure
                && !providers.contains(where: { coveredVisibleIds.contains($0.baseProviderId) })
            return .failure(
                userMessage: shouldPublishFailure
                    ? SensitiveDataRedactor.redactedMessage(for: error)
                    : nil,
                shouldUpdateErrorBanner: shouldPublishFailure || currentVisibleIds.isSubset(of: lastAttemptedIds)
            )
        }
    }

    func codexResetIdentity(_ provider: ProviderData) -> String? {
        guard provider.baseProviderId == "codex" else { return nil }
        return CodexAccountIdentity(accountId: provider.accountId, userId: provider.workspaceUserId).nativeKey
    }

    func acceptsCodexResetRefresh(_ provider: ProviderData, since token: Int) -> Bool {
        codexResetIdentity(provider).map { codexResetRefreshFence.accepts(token, identity: $0) } ?? true
    }

    @MainActor
    func reconcileResetProtectedAccountRegistry(_ incoming: [ProviderData], since token: Int) async {
        let isValid: @MainActor (ProviderData) -> Bool = { provider in
            self.acceptsCodexResetRefresh(provider, since: token)
        }
        let accepted = incoming.filter(isValid)
        guard !accepted.isEmpty else { return }
        await accountStore.reconcileAccountRegistry(with: accepted, isValid: isValid)
    }

    func preserveCodexResetUpdates(_ incoming: [ProviderData], since token: Int, providerId: String? = nil) -> [ProviderData] {
        guard providerId == nil || providerId == "codex" else { return incoming }
        let protected = providers.filter {
            guard let key = codexResetIdentity($0) else { return false }
            return !codexResetRefreshFence.accepts(token, identity: key)
        }
        let keys = Set(protected.compactMap(codexResetIdentity))
        return (incoming.filter { codexResetIdentity($0).map { !keys.contains($0) } ?? true } + protected).sorted(by: providerSort)
    }

    func selectedProviderIDList() -> [String] {
        let selected = selectedProviderIds()
        let hidden = settings.hiddenSidebarSections
        return providerCatalogIds().filter {
            selected.contains($0) && !AgentVisibility.isProviderHidden($0, hidden: hidden)
        }
    }

    func replaceProviderEntries(for providerId: String, with replacements: [ProviderData]) {
        let currentVisibleIds = Set(selectedProviderIDList())
        let acceptedReplacements = currentVisibleIds.contains(providerId)
            ? visibleProviders(from: replacements)
            : []
        providers = visibleProviders(
            from: providers.filter { $0.baseProviderId != providerId && currentVisibleIds.contains($0.baseProviderId) }
                + acceptedReplacements
        ).sorted(by: providerSort)
        if let existingOverview = overview {
            overview = recomputedOverview(
                for: providers,
                baseOverview: existingOverview,
                generatedAt: existingOverview.generatedAt,
                language: language
            )
        }
    }

    func completeGlobalRefresh(_ result: ProviderRefreshResult) {
        guard result.shouldUpdateTimestamps else {
            return
        }

        let currentProviders = timestampableProviders(for: result.refreshedProviders)
        guard !currentProviders.isEmpty else { return }

        var latestTimestamp: Date?
        for provider in currentProviders {
            guard let acquiredAt = resolvedTimestamp(for: provider, fallback: result.refreshedAt) else {
                continue
            }
            markAccountRefreshed(provider, at: acquiredAt)
            latestTimestamp = max(latestTimestamp ?? .distantPast, acquiredAt)
        }
        if let latestTimestamp {
            lastRefreshTime = max(lastRefreshTime ?? .distantPast, latestTimestamp)
        }
        for providerId in Set(currentProviders.map(\.baseProviderId)) {
            let providerLatest = currentProviders
                .filter { $0.baseProviderId == providerId }
                .compactMap { resolvedTimestamp(for: $0, fallback: result.refreshedAt) }
                .max()
            if let providerLatest {
                providerRefreshTimes[providerId] = max(providerRefreshTimes[providerId] ?? .distantPast, providerLatest)
            }
        }
    }

    func completeProviderRefresh(providerId: String, result: ProviderRefreshResult) {
        guard result.shouldUpdateTimestamps else {
            return
        }

        let currentProviders = timestampableProviders(for: result.refreshedProviders)
            .filter { $0.baseProviderId == providerId }
        guard !currentProviders.isEmpty else { return }

        var providerLatest: Date?
        for provider in currentProviders {
            guard let acquiredAt = resolvedTimestamp(for: provider, fallback: result.refreshedAt) else {
                continue
            }
            markAccountRefreshed(provider, at: acquiredAt)
            providerLatest = max(providerLatest ?? .distantPast, acquiredAt)
        }
        if let providerLatest {
            providerRefreshTimes[providerId] = max(providerRefreshTimes[providerId] ?? .distantPast, providerLatest)
        }
    }

    func completeAccountRefresh(refreshKey: String, result: ProviderRefreshResult) {
        guard result.shouldUpdateTimestamps else {
            return
        }

        var latestForKey: Date?
        for provider in result.refreshedProviders {
            guard let acquiredAt = resolvedTimestamp(for: provider, fallback: result.refreshedAt) else {
                continue
            }
            markAccountRefreshed(provider, at: acquiredAt)
            latestForKey = max(latestForKey ?? .distantPast, acquiredAt)
        }
        if let latestForKey {
            accountRefreshTimes[refreshKey] = max(accountRefreshTimes[refreshKey] ?? .distantPast, latestForKey)
        }
    }

    func resolvedTimestamp(for provider: ProviderData, fallback: Date?) -> Date? {
        if let fetchedDate = resolvedFetchedDate(for: provider) {
            return fetchedDate
        }
        if provider.baseProviderId == "antigravity" || provider.baseProviderId == "codex" {
            return nil
        }
        return fallback
    }

    func markAccountRefreshed(_ provider: ProviderData, at refreshedAt: Date) {
        for key in accountRefreshKeys(for: provider) {
            accountRefreshTimes[key] = max(accountRefreshTimes[key] ?? .distantPast, refreshedAt)
        }
    }

    func accountRefreshKeys(for provider: ProviderData) -> [String] {
        var keys: [String] = []

        func append(_ key: String?) {
            guard let key, !keys.contains(key) else { return }
            keys.append(key)
        }

        if let credentialId = credentialID(for: provider)?.nilIfBlank {
            append(accountRefreshKey(providerId: provider.baseProviderId, credentialId: credentialId))
        }

        if let storedAccount = accountStore.accountRegistry.first(where: {
            !$0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        }) {
            append(accountRefreshKey(providerId: provider.baseProviderId, storedAccountId: storedAccount.id))
        }

        if QuotaBackend.AccountCredentialStore.isMultiWorkspace(provider.baseProviderId) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: liveProviderIdentity(provider)))
            append(accountRefreshKey(providerId: provider.baseProviderId, providerDataId: provider.id))
            return keys
        }

        if let normalizedAccountId = normalizedAccountLookupValue(provider.accountId) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: "account:\(normalizedAccountId)"))
        }

        if let normalizedLabel = normalizedAccountLookupValue(provider.accountLabel ?? provider.label) {
            append(accountRefreshKey(providerId: provider.baseProviderId, identity: "label:\(normalizedLabel)"))
        }

        append(accountRefreshKey(providerId: provider.baseProviderId, providerDataId: provider.id))
        return keys
    }

    func accountRefreshKey(providerId: String, credentialId: String) -> String {
        "\(providerId):cred:\(credentialId.lowercased())"
    }

    func accountRefreshKey(providerId: String, storedAccountId: String) -> String {
        "\(providerId):stored:\(storedAccountId.lowercased())"
    }

    func accountRefreshKey(providerId: String, identity: String) -> String {
        "\(providerId):identity:\(identity.lowercased())"
    }

    func accountRefreshKey(providerId: String, providerDataId: String) -> String {
        "\(providerId):live:\(providerDataId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    func timestampableProviders(for refreshedProviders: [ProviderData]) -> [ProviderData] {
        providers.filter { provider in
            refreshedProviders.contains { refreshed in
                providerMatchesRefresh(provider, refreshed: refreshed)
            }
        }
    }

    func currentProviderMatchingRefresh(_ refreshedProvider: ProviderData) -> ProviderData? {
        providers.first { provider in
            providerMatchesRefresh(provider, refreshed: refreshedProvider)
        }
    }

    func providerMatchesRefresh(_ current: ProviderData, refreshed: ProviderData) -> Bool {
        guard current.baseProviderId == refreshed.baseProviderId else { return false }
        if current.baseProviderId == "codex" {
            return AccountIdentityPolicy.codexLiveAccountsMatch(current, refreshed)
        }

        if current.id.caseInsensitiveCompare(refreshed.id) == .orderedSame {
            return true
        }

        if let currentCredential = credentialID(for: current)?.lowercased().nilIfBlank,
           let refreshedCredential = credentialID(for: refreshed)?.lowercased().nilIfBlank {
            return currentCredential == refreshedCredential
        }

        if QuotaBackend.AccountCredentialStore.isMultiWorkspace(current.baseProviderId) {
            if let currentPath = current.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
               let refreshedPath = refreshed.sourceFilePath?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
                return QuotaBackend.AccountCredentialStore.normalizedAuthFilePath(currentPath)
                    == QuotaBackend.AccountCredentialStore.normalizedAuthFilePath(refreshedPath)
            }
            return false
        }

        if let currentAccountId = normalizedAccountLookupValue(current.accountId),
           let refreshedAccountId = normalizedAccountLookupValue(refreshed.accountId),
           currentAccountId == refreshedAccountId {
            return true
        }

        if let currentLabel = normalizedAccountLookupValue(current.accountLabel ?? current.label),
           let refreshedLabel = normalizedAccountLookupValue(refreshed.accountLabel ?? refreshed.label),
           currentLabel == refreshedLabel {
            return true
        }

        return false
    }

    func stabilizedBulkRefreshProviders(
        _ incomingProviders: [ProviderData],
        preservingExistingFor targetProviderId: String? = nil,
        includingExistingFor skippedProviderIDs: Set<String> = []
    ) -> [ProviderData] {
        let groupedIncoming = Dictionary(grouping: incomingProviders, by: \.baseProviderId)
        let providerIDs = targetProviderId.map { [$0] }
            ?? Array(Set(incomingProviders.map(\.baseProviderId)).union(skippedProviderIDs))

        var stabilized: [ProviderData] = []
        for providerId in providerIDs {
            let incoming = groupedIncoming[providerId] ?? []
            stabilized.append(contentsOf: stabilizedBulkRefreshProviders(for: providerId, incoming: incoming))
        }

        return deduplicatedProvidersByID(stabilized).sorted(by: providerSort)
    }

    func stabilizedBulkRefreshProviders(
        for providerId: String,
        incoming: [ProviderData]
    ) -> [ProviderData] {
        let storedAccounts = accountStore.accountRegistry.filter { $0.providerId == providerId && !$0.isHidden }
        guard !storedAccounts.isEmpty else {
            return deduplicatedProvidersByID(incoming)
        }

        let existingProviders = providers.filter { $0.baseProviderId == providerId }
        var remainingIncoming = incoming
        var selected: [ProviderData] = []

        for storedAccount in storedAccounts {
            let incomingMatches = remainingIncoming.filter { accountStore.matchesStoredWithLive(storedAccount, provider: $0) }
            let existingMatches = existingProviders.filter { accountStore.matchesStoredWithLive(storedAccount, provider: $0) }

            let incomingBest = preferredLiveProvider(among: incomingMatches, storedAccount: storedAccount)
            let existingBest = preferredLiveProvider(among: existingMatches, storedAccount: storedAccount)
            if let chosen = preferredBulkRefreshProvider(incoming: incomingBest, existing: existingBest) {
                selected.append(chosen)
            }

            if !incomingMatches.isEmpty {
                let consumedIDs = Set(incomingMatches.map(\.id))
                remainingIncoming.removeAll { consumedIDs.contains($0.id) }
            }
        }

        let unmatchedIncoming = Dictionary(grouping: remainingIncoming, by: liveProviderIdentity(_:))
            .values
            .compactMap { preferredLiveProvider(among: Array($0), storedAccount: nil) }
            .filter { candidate in
                // Drop generic "not connected" placeholders once a healthy live exists for this provider.
                guard candidate.needsCredentialConnection else { return true }
                let hasHealthyLive = selected.contains {
                    $0.status != .error && !$0.needsCredentialConnection
                }
                if hasHealthyLive { return false }
                // Path-less auto placeholders (e.g. codex:auto:default) are not real accounts.
                if candidate.sourceFilePath == nil,
                   candidate.id.localizedCaseInsensitiveContains(":auto:") {
                    return false
                }
                return true
            }

        selected.append(contentsOf: unmatchedIncoming)
        return deduplicatedProvidersByID(selected)
    }

    func preferredBulkRefreshProvider(
        incoming: ProviderData?,
        existing: ProviderData?
    ) -> ProviderData? {
        guard let incoming else { return existing }
        if incoming.status != .error {
            if let existingError = lastCheckError(for: incoming) {
                let incomingFetched = resolvedFetchedDate(for: incoming)
                let existingFetched = existing.flatMap(resolvedFetchedDate(for:))
                let failedSecond = Date(timeIntervalSince1970: floor(existingError.failedAt.timeIntervalSince1970))
                let isNewAcquisition = incomingFetched.map { fetched in
                    if let existingFetched, fetched <= existingFetched {
                        return false
                    }
                    // `fetchedAt` is formatted via `SharedFormatters.iso8601` (whole seconds), so compare against floored second.
                    return fetched >= failedSecond
                } ?? false
                if isNewAcquisition {
                    clearAccountCheckError(for: incoming, credentialId: credentialID(for: incoming))
                }
            }
            return incoming
        }
        if (incoming.baseProviderId == "antigravity" || incoming.baseProviderId == "codex"),
           let existing,
           isLastKnownErrorPreservable(existing),
           !isTerminalStopFailure(incoming) {
            recordAccountCheckError(
                for: existing,
                credentialId: credentialID(for: existing),
                message: incoming.headline.supporting.nilIfBlank ?? incoming.headline.primary,
                errorCode: incoming.errorCode
            )
            return existing
        }
        clearAccountCheckError(for: incoming, credentialId: credentialID(for: incoming))
        return incoming
    }

    func deduplicatedProvidersByID(_ providers: [ProviderData]) -> [ProviderData] {
        var seen = Set<String>()
        var deduplicated: [ProviderData] = []

        for provider in providers where seen.insert(provider.id).inserted {
            deduplicated.append(provider)
        }

        return deduplicated
    }

    func providerSort(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool {
        let providerOrder = providerCatalogIds()
        let lhsProviderIndex = providerOrder.firstIndex(of: lhs.baseProviderId) ?? Int.max
        let rhsProviderIndex = providerOrder.firstIndex(of: rhs.baseProviderId) ?? Int.max

        if lhsProviderIndex != rhsProviderIndex {
            return lhsProviderIndex < rhsProviderIndex
        }

        let lhsIdentity = (lhs.accountLabel ?? lhs.accountId ?? lhs.id).lowercased()
        let rhsIdentity = (rhs.accountLabel ?? rhs.accountId ?? rhs.id).lowercased()
        return lhsIdentity.localizedCaseInsensitiveCompare(rhsIdentity) == .orderedAscending
    }

    func extractCredentialId(from providerDataId: String) -> String? {
        guard let range = providerDataId.range(of: ":cred:") else { return nil }
        return String(providerDataId[range.upperBound...]).nilIfBlank
    }

    func credentialID(for provider: ProviderData) -> String? {
        if let direct = extractCredentialId(from: provider.id) {
            return direct
        }

        return accountStore.accountRegistry.first(where: {
            !$0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        })?.credentialId?.nilIfBlank
    }

    func visibleProviders(from providers: [ProviderData]) -> [ProviderData] {
        let hiddenSections = settings.hiddenSidebarSections
        return providers.filter {
            !isProviderHidden($0) && !AgentVisibility.isProviderHidden($0.baseProviderId, hidden: hiddenSections)
        }
    }

    func isProviderHidden(_ provider: ProviderData) -> Bool {
        let hasHiddenMatch = accountStore.accountRegistry.contains {
            $0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        }
        guard hasHiddenMatch else { return false }
        let hasVisibleMatch = accountStore.accountRegistry.contains {
            !$0.isHidden && accountStore.matchesStoredWithLive($0, provider: provider)
        }
        return !hasVisibleMatch
    }

    func normalizedLiveAccountID(for provider: ProviderData) -> String? {
        provider.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func normalizedAccountIdentifier(for provider: ProviderData) -> String? {
        guard let raw = provider.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    func liveProviderIdentity(_ provider: ProviderData) -> String {
        AccountIdentityPolicy.liveIdentityKey(for: provider)
    }

    func preferredLiveProvider(
        among candidates: [ProviderData],
        storedAccount: StoredProviderAccount?
    ) -> ProviderData? {
        candidates.max { lhs, rhs in
            let lhsScore = liveProviderScore(lhs, storedAccount: storedAccount)
            let rhsScore = liveProviderScore(rhs, storedAccount: storedAccount)
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return providerSort(lhs, rhs)
        }
    }

    func liveProviderScore(
        _ provider: ProviderData,
        storedAccount: StoredProviderAccount?
    ) -> Int {
        var score = 0

        if provider.status != .error {
            score += 80
        }
        if provider.accountId?.nilIfBlank != nil {
            score += 20
        }
        if provider.accountLabel?.nilIfBlank != nil {
            score += 20
        }
        if provider.membershipLabel?.nilIfBlank != nil {
            score += 10
        }
        if provider.remainingPercent != nil {
            score += 5
        }
        score += min(provider.metrics.count, 3) * 2
        score += min(provider.windows.count, 3) * 3

        if provider.id.contains(":cred:") {
            score += 8
        }
        if provider.id.contains(":auto:") {
            score += 4
        }

        guard let storedAccount else { return score }

        let liveID = provider.id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if let credentialId = storedAccount.credentialId?.nilIfBlank,
           extractCredentialId(from: provider.id) == credentialId {
            score += 400
        }

        if let storedResultId = storedAccount.normalizedProviderResultId {
            if storedResultId == liveID {
                score += 300
            } else if liveID.hasPrefix(storedResultId + ":") || storedResultId.hasPrefix(liveID + ":") {
                score += 240
            }
        }

        if let storedAccountId = storedAccount.normalizedAccountId,
           let liveAccountId = normalizedLiveAccountID(for: provider),
           storedAccountId == liveAccountId {
            score += 160
        }

        if storedAccount.normalizedEmail == normalizedAccountIdentifier(for: provider) {
            score += 120
        }

        return score
    }
}
