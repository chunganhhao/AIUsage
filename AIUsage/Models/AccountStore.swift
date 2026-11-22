import Foundation
import Combine
import QuotaBackend
import os.log

// MARK: - AccountStore
// Persists multi-provider account registry (SecureAccountVault), normalizes against
// AccountCredentialStore, deduplicates, and reconciles with live ProviderData snapshots.

final class AccountStore: ObservableObject {
    static let shared = AccountStore()

    @Published var accountRegistry: [StoredProviderAccount] = [] {
        didSet { accountRegistryRevision &+= 1 }
    }

    /// Base provider ids in UI/catalog order; must match `AppState.providerCatalogItems`.
    var providerCatalogOrder: [String] = []
    private(set) var accountRegistryRevision: UInt64 = 0

    private init() {
        accountRegistry = SecureAccountVault.shared.loadAccounts()
    }

    /// Call once at app launch after `AppState` can supply catalog order (before refresh).
    func bootstrapFromDisk(providerCatalogOrder: [String]) {
        self.providerCatalogOrder = providerCatalogOrder
        bootstrapCredentialIndexFromRegistry()
        normalizePersistedState()
    }

    func updateProviderCatalogOrder(_ ids: [String]) {
        providerCatalogOrder = ids
    }

    // MARK: - Public account API

    @discardableResult
    func saveAccount(
        providerId: String,
        email: String,
        displayName: String?,
        note: String? = nil,
        accountId: String? = nil,
        credentialId: String? = nil,
        providerResultId: String? = nil,
        sourceFilePath: String? = nil,
        ensureProviderSelected: (String) -> Void
    ) -> Bool {
        let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty else { return false }

        let now = SharedFormatters.iso8601String(from: Date())
        let credentialSnapshot = credentialId.flatMap {
            credentialAccountSnapshot(providerId: providerId, credentialId: $0)
        }
        let effectiveEmail = credentialSnapshot?.accountHandle ?? normalizedEmail
        let normalizedLookup = effectiveEmail.lowercased()
        let normalizedAccountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialSnapshot?.normalizedAccountId
        let normalizedProviderResultId = providerResultId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            ?? credentialId.map { "\(providerId):cred:\($0)".lowercased() }
        let effectiveDisplayName = displayName?.nilIfBlank ?? credentialSnapshot?.displayName
        let requiresCredentialBoundIdentity = AccountIdentityPolicy.isMultiWorkspace(providerId)
        let isAntigravity = providerId == "antigravity"
        let incomingCredential = credentialId.flatMap {
            AccountCredentialStore.shared.loadCredential(providerId: providerId, credentialId: $0)
        }
        let resolvedSourcePath = sourceFilePath?.nilIfBlank
            ?? incomingCredential.flatMap(AccountIdentityPolicy.credentialAuthFilePath)
        let incomingIdentity = CodexAccountIdentity(
            accountId: normalizedAccountId, userId: credentialSnapshot?.workspaceUserId, email: effectiveEmail
        )
        let antigravityCredentialsById: [String: AccountCredential] = {
            guard isAntigravity else { return [:] }
            return Dictionary(
                AccountCredentialStore.shared.loadCredentials(for: providerId).map {
                    ($0.id.lowercased(), $0)
                },
                uniquingKeysWith: { first, _ in first }
            )
        }()
        let incomingProjectId: String? = {
            guard isAntigravity else { return nil }
            if let normalizedAccountId, !normalizedAccountId.contains("@") {
                return normalizedAccountId
            }
            return incomingCredential.flatMap(AccountIdentityPolicy.antigravityProjectId)
        }()
        func antigravityProjectId(for row: StoredProviderAccount) -> String? {
            if let rowAccountId = row.normalizedAccountId, !rowAccountId.contains("@") {
                return rowAccountId
            }
            guard let referencedCredId = row.credentialId?.nilIfBlank
                ?? row.providerResultId.flatMap(AccountIdentityPolicy.extractCredentialId),
                let cred = antigravityCredentialsById[referencedCredId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] else {
                return nil
            }
            return AccountIdentityPolicy.antigravityProjectId(for: cred)
        }
        func antigravityProjectsCompatible(with row: StoredProviderAccount) -> Bool {
            guard let incomingProjectId,
                  let existingProjectId = antigravityProjectId(for: row) else {
                return true
            }
            return existingProjectId == incomingProjectId
        }

        let exactMatchIndex = accountRegistry.firstIndex(where: {
            guard $0.providerId == providerId else { return false }
            if providerId == "codex" {
                let storedIdentity = AccountIdentityPolicy.codexIdentity(for: $0)
                guard !storedIdentity.conflicts(with: incomingIdentity) else { return false }
                if storedIdentity.matches(incomingIdentity) { return true }
                if let credentialId, let storedId = $0.credentialId { return credentialId == storedId }
                return AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, resolvedSourcePath)
            }
            if let credentialId, $0.credentialId == credentialId { return true }
            if let normalizedProviderResultId, $0.normalizedProviderResultId == normalizedProviderResultId { return true }
            if requiresCredentialBoundIdentity {
                // Same auth-file path = same Codex/Antigravity workspace (scan vs credential).
                if let resolvedSourcePath,
                   AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, resolvedSourcePath) {
                    return true
                }
                // CPA→订阅会 copy 到 AuthImports；墓碑常记着 CPA 原路径，用 metadata.sourcePath 对齐。
                if let metaSource = incomingCredential?.metadata["sourcePath"],
                   AccountIdentityPolicy.sourceFilePathsMatch($0.sourceFilePath, metaSource) {
                    return true
                }
                return false
            }
            if let normalizedAccountId, $0.normalizedAccountId == normalizedAccountId { return true }
            if let normalizedAccountId, let storedAccountId = $0.normalizedAccountId,
               storedAccountId != normalizedAccountId {
                return false
            }
            return $0.normalizedEmail == normalizedLookup
        })
        let matchedIndex: Int? = exactMatchIndex ?? {
            guard isAntigravity else { return nil }
            return accountRegistry.firstIndex(where: {
                guard $0.providerId == providerId,
                      !$0.isPermanentlyRemoved,
                      $0.normalizedEmail == normalizedLookup,
                      antigravityProjectsCompatible(with: $0) else { return false }
                let referencedCredId = $0.credentialId?.nilIfBlank
                    ?? $0.providerResultId.flatMap(AccountIdentityPolicy.extractCredentialId)
                guard let referencedCredId else { return true }
                return antigravityCredentialsById[referencedCredId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] == nil
            })
        }()

        let targetRecordId: String
        if let index = matchedIndex {
            let existing = accountRegistry[index]
            targetRecordId = existing.id
            let updatedAccountId = isAntigravity
                ? (incomingProjectId ?? antigravityProjectId(for: existing) ?? normalizedAccountId ?? existing.accountId)
                : (normalizedAccountId ?? existing.accountId)
            accountRegistry[index] = StoredProviderAccount(
                id: existing.id,
                providerId: existing.providerId,
                email: effectiveEmail,
                displayName: effectiveDisplayName ?? existing.displayName,
                note: note?.nilIfBlank ?? existing.note,
                accountId: updatedAccountId,
                providerResultId: normalizedProviderResultId ?? existing.providerResultId,
                credentialId: credentialId ?? existing.credentialId,
                createdAt: existing.createdAt,
                lastSeenAt: maxTimestampString(now, existing.lastSeenAt, credentialSnapshot?.validatedAt),
                isHidden: false,
                isPermanentlyRemoved: false,
                sourceFilePath: resolvedSourcePath ?? existing.sourceFilePath,
                workspaceUserId: credentialSnapshot?.workspaceUserId ?? existing.workspaceUserId
            )
        } else {
            let createdId = UUID().uuidString
            targetRecordId = createdId
            let appendedAccountId = isAntigravity
                ? (incomingProjectId ?? normalizedAccountId)
                : normalizedAccountId
            accountRegistry.append(
                StoredProviderAccount(
                    id: createdId,
                    providerId: providerId,
                    email: effectiveEmail,
                    displayName: effectiveDisplayName,
                    note: note?.nilIfBlank,
                    accountId: appendedAccountId,
                    providerResultId: normalizedProviderResultId,
                    credentialId: credentialId,
                    createdAt: now,
                    lastSeenAt: maxTimestampString(now, credentialSnapshot?.validatedAt),
                    isHidden: false,
                    isPermanentlyRemoved: false,
                    sourceFilePath: resolvedSourcePath,
                    workspaceUserId: credentialSnapshot?.workspaceUserId
                )
            )
        }

        if isAntigravity {
            let normalizedCredentialId = credentialId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
            accountRegistry.removeAll { row in
                guard row.id != targetRecordId,
                      row.providerId == providerId,
                      row.isHidden,
                      !row.isPermanentlyRemoved,
                      row.normalizedEmail == normalizedLookup,
                      antigravityProjectsCompatible(with: row) else { return false }
                let referencedCredId = (row.credentialId?.nilIfBlank
                    ?? row.providerResultId.flatMap(AccountIdentityPolicy.extractCredentialId))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let referencedCredId, !referencedCredId.isEmpty else { return true }
                if let normalizedCredentialId, referencedCredId.lowercased() == normalizedCredentialId {
                    return true
                }
                return antigravityCredentialsById[referencedCredId.lowercased()] == nil
            }
        }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        ensureProviderSelected(providerId)
        return persistAccountRegistry()
    }

    private static func mergedCredentialMetadata(
        existing: [String: String],
        incoming: [String: String]
    ) -> [String: String] {
        var merged = existing
        if let existingSource = merged["sourcePath"],
           AccountCredentialStore.isEphemeralTemporaryAuthPath(existingSource) {
            merged["sourcePath"] = ""
        }
        incoming.forEach { key, value in
            if key == "sourcePath", value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return
            }
            merged[key] = value
        }
        return merged
    }

    /// 返回该账号在仪表盘中的 provider result id（`<providerId>:cred:<credentialId>`）。
    @discardableResult
    func registerAuthenticatedCredential(
        _ credential: AccountCredential,
        usage: ProviderUsage,
        note: String?,
        providerDisplayTitle: String,
        insertImmediateProviderData: (_ providerId: String, _ credentialId: String, _ accountLabel: String?, _ usage: ProviderUsage) -> Void,
        ensureProviderSelected: (String) -> Void
    ) throws -> String {
        let providerId = credential.providerId
        let accountHandle: String = {
            if let v = usage.accountEmail?.nilIfBlank { return v }
            if let v = usage.accountLogin?.nilIfBlank { return v }
            if let v = usage.accountName?.nilIfBlank { return v }
            if let v = credential.accountLabel?.nilIfBlank { return v }
            if let v = usage.usageAccountId?.nilIfBlank { return v }
            return "\(providerDisplayTitle) Account"
        }()
        let displayName: String? = usage.accountName?.nilIfBlank
            ?? credential.accountLabel?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank
        // Codex / Antigravity：accountId 必须是 workspace/project 原生 id。
        // accountLogin 常是 user-xxx，写进 registry 会把墓碑和去重搞乱（Free/Business 互挡）。
        let accountId: String? = {
            if providerId == "antigravity" {
                return (usage.extra["projectId"]?.value as? String)?.nilIfBlank
                    ?? usage.usageAccountId?.nilIfBlank.flatMap { $0.contains("@") ? nil : $0 }
            }
            if let usageAccountId = usage.usageAccountId?.nilIfBlank {
                return usageAccountId
            }
            if AccountIdentityPolicy.isMultiWorkspace(providerId) {
                return nil
            }
            return usage.accountLogin?.nilIfBlank
        }()

        var enrichedCredential = credential
        let validatedAt = SharedFormatters.iso8601String(from: Date())
        enrichedCredential.metadata["accountHandle"] = accountHandle
        enrichedCredential.metadata["lastValidatedAt"] = validatedAt
        if let accountEmail = usage.accountEmail?.nilIfBlank {
            enrichedCredential.metadata["accountEmail"] = accountEmail
        }
        if let displayName {
            enrichedCredential.metadata["displayName"] = displayName
        }
        if let accountId {
            enrichedCredential.metadata["accountId"] = accountId
        }
        if let accountPlan = usage.accountPlan?.nilIfBlank {
            enrichedCredential.metadata["accountPlan"] = accountPlan
        }
        if let workspaceType = (usage.extra["workspaceType"]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata["workspaceType"] = workspaceType
        }
        if let workspaceUserId = (usage.extra["userId"]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata["workspaceUserId"] = workspaceUserId
        }
        if providerId == "antigravity",
           let projectId = (usage.extra["projectId"]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata["projectId"] = projectId
        }
        if let apiRegion = (usage.extra[ProviderAPIRegion.metadataKey]?.value as? String)?.nilIfBlank {
            enrichedCredential.metadata[ProviderAPIRegion.metadataKey] = apiRegion
        }
        enrichedCredential.lastUsedAt = validatedAt

        if let existingCredential = existingAuthenticatedCredential(
            incomingCredential: enrichedCredential,
            providerId: providerId,
            accountHandle: accountHandle,
            accountId: accountId,
            sessionFingerprint: enrichedCredential.metadata["sessionFingerprint"],
            sourceIdentifier: enrichedCredential.metadata["sourceIdentifier"],
            sourceIdentifierIsStable: enrichedCredential.metadata["identityScope"]
                == ProviderAuthCandidate.IdentityScope.accountScoped.rawValue
        ) {
            let mergedMetadata = Self.mergedCredentialMetadata(
                existing: existingCredential.metadata,
                incoming: enrichedCredential.metadata
            )
            enrichedCredential = AccountCredential(
                id: existingCredential.id,
                providerId: existingCredential.providerId,
                accountLabel: enrichedCredential.accountLabel ?? existingCredential.accountLabel,
                authMethod: enrichedCredential.authMethod,
                credential: enrichedCredential.credential,
                metadata: mergedMetadata
            )
            enrichedCredential.lastUsedAt = validatedAt
            ProviderManagedImportStore.reuseManagedImportIfPossible(
                existingCredential: existingCredential,
                incomingCredential: &enrichedCredential
            )
        }

        let resolvedAccountId = AccountIdentityPolicy.preferredAccountId(for: enrichedCredential) ?? accountId
        if providerId == "antigravity" {
            if let resolvedAccountId {
                enrichedCredential.metadata["accountId"] = resolvedAccountId
            } else if enrichedCredential.metadata["accountId"]?.contains("@") == true {
                enrichedCredential.metadata.removeValue(forKey: "accountId")
            }
        }

        let credentialStore = AccountCredentialStore.shared
        try credentialStore.saveCredential(enrichedCredential)
        let deduplicationPlan = credentialStore.planCredentialDeduplication(for: providerId)
        let credentialRemapping = deduplicationPlan.remappedCredentialIDs
        if !credentialRemapping.isEmpty {
            applyCredentialRemapping(credentialRemapping)
            if let remappedID = credentialRemapping[enrichedCredential.id] {
                let canonicalCredential = credentialStore
                    .loadCredentials(for: providerId)
                    .first(where: { $0.id == remappedID })
                var rewrittenCanonicalCredential = AccountCredential(
                    id: remappedID,
                    providerId: enrichedCredential.providerId,
                    accountLabel: enrichedCredential.accountLabel,
                    authMethod: enrichedCredential.authMethod,
                    credential: enrichedCredential.credential,
                    metadata: canonicalCredential.map {
                        Self.mergedCredentialMetadata(existing: $0.metadata, incoming: enrichedCredential.metadata)
                    } ?? enrichedCredential.metadata
                )
                rewrittenCanonicalCredential.lastUsedAt = validatedAt
                if let canonicalCredential {
                    ProviderManagedImportStore.reuseManagedImportIfPossible(
                        existingCredential: canonicalCredential,
                        incomingCredential: &rewrittenCanonicalCredential
                    )
                }
                try credentialStore.saveCredential(rewrittenCanonicalCredential)
                enrichedCredential = rewrittenCanonicalCredential
            }
        }

        let registryPersisted = saveAccount(
            providerId: providerId,
            email: accountHandle,
            displayName: displayName,
            note: note,
            accountId: AccountIdentityPolicy.preferredAccountId(for: enrichedCredential) ?? resolvedAccountId,
            credentialId: enrichedCredential.id,
            providerResultId: "\(providerId):cred:\(enrichedCredential.id)",
            sourceFilePath: AccountIdentityPolicy.credentialAuthFilePath(enrichedCredential),
            ensureProviderSelected: ensureProviderSelected
        )

        if registryPersisted,
           !deduplicationPlan.isEmpty,
           !credentialStore.commitCredentialDeduplication(deduplicationPlan) {
            accountPersistenceLog.error("Credential deduplication commit deferred because the staged plan changed or the vault write failed.")
        }

        insertImmediateProviderData(
            providerId,
            enrichedCredential.id,
            enrichedCredential.accountLabel ?? accountHandle,
            usage
        )
        return "\(providerId):cred:\(enrichedCredential.id)"
    }

    func updateAccountNote(
        for entry: ProviderAccountEntry,
        note: String?,
        onProviderActivated: (String) -> Void
    ) {
        let now = SharedFormatters.iso8601String(from: Date())

        if let index = bestStoredAccountIndex(for: entry) {
            accountRegistry[index].note = note?.nilIfBlank
            accountRegistry[index].isHidden = false
            accountRegistry[index].providerResultId = entry.liveProvider?.id ?? accountRegistry[index].providerResultId
            accountRegistry[index].accountId = entry.liveProvider?.accountId ?? accountRegistry[index].accountId
            accountRegistry[index].lastSeenAt = entry.liveProvider == nil ? accountRegistry[index].lastSeenAt : now
        } else if let created = makeStoredAccount(
            from: entry,
            note: note?.nilIfBlank,
            isHidden: false,
            lastSeenAt: entry.liveProvider == nil ? nil : now
        ) {
            accountRegistry.append(created)
        } else {
            return
        }

        onProviderActivated(entry.providerId)
        persistAccountRegistry()
    }

    func restoreAccount(_ storedAccountId: String, onRestored: (String) -> Void) {
        guard let index = accountRegistry.firstIndex(where: { $0.id == storedAccountId }) else { return }
        let providerId = accountRegistry[index].providerId
        accountRegistry[index].isHidden = false
        accountRegistry[index].isPermanentlyRemoved = false
        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()
        onRestored(providerId)
    }

    func excludedEngineAccountFilters() -> (credentialIDs: Set<String>, codexNativeKeys: Set<String>) {
        var credentialIDs = Set<String>()
        var codexNativeKeys = Set<String>()
        var visibleCredentialIDs = Set<String>()
        var visibleCodexNativeKeys = Set<String>()
        for account in accountRegistry {
            let isExcluded = account.isHidden || account.isPermanentlyRemoved
            let targetCredIDs = [
                account.credentialId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                account.providerResultId.flatMap(AccountIdentityPolicy.extractCredentialId)?
                    .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            ].compactMap { $0 }.filter { !$0.isEmpty }
            if isExcluded {
                credentialIDs.formUnion(targetCredIDs)
            } else {
                visibleCredentialIDs.formUnion(targetCredIDs)
            }
            if account.providerId == "codex",
               let nativeKey = AccountIdentityPolicy.codexIdentity(for: account).nativeKey?.lowercased() {
                if isExcluded {
                    codexNativeKeys.insert(nativeKey)
                } else {
                    visibleCodexNativeKeys.insert(nativeKey)
                }
            }
        }
        credentialIDs.subtract(visibleCredentialIDs)
        codexNativeKeys.subtract(visibleCodexNativeKeys)
        return (credentialIDs, codexNativeKeys)
    }

    func hideAccount(
        _ entry: ProviderAccountEntry,
        onPostRegistryChange: () -> Void
    ) {
        hideAccounts([entry], onPostRegistryChange: onPostRegistryChange)
    }

    /// Soft-hide multiple accounts with a single registry persist.
    func hideAccounts(
        _ entries: [ProviderAccountEntry],
        onPostRegistryChange: () -> Void
    ) {
        guard !entries.isEmpty else { return }

        for entry in entries {
            applyHideMutation(entry)
        }

        // Soft-hide keeps Keychain credentials; only suppress dashboard listing.
        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        persistAccountRegistry()
        onPostRegistryChange()
    }

    private func applyHideMutation(_ entry: ProviderAccountEntry) {
        let matchingIndices = matchingStoredAccountIndices(for: entry)
        let preservedCredentialId = entry.storedAccount?.credentialId?.nilIfBlank
            ?? entry.liveProvider.flatMap { AccountIdentityPolicy.extractCredentialId(from: $0.id) }
        if !matchingIndices.isEmpty {
            for index in matchingIndices {
                var updated = accountRegistry[index]
                updated.note = nil
                updated.credentialId = preservedCredentialId ?? updated.credentialId
                updated.providerResultId = entry.liveProvider?.id ?? updated.providerResultId
                updated.accountId = entry.liveProvider?.accountId ?? updated.accountId
                updated.workspaceUserId = entry.liveProvider?.workspaceUserId ?? updated.workspaceUserId
                updated.sourceFilePath = entry.liveProvider?.sourceFilePath
                    ?? entry.storedAccount?.sourceFilePath
                    ?? updated.sourceFilePath
                updated.isHidden = true
                updated.isPermanentlyRemoved = false
                updated.lastSeenAt = maxTimestampString(
                    SharedFormatters.iso8601String(from: Date()),
                    updated.lastSeenAt
                )
                accountRegistry[index] = updated
            }
        } else if let hiddenEntry = makeStoredAccount(
            from: entry,
            note: nil,
            isHidden: true,
            lastSeenAt: SharedFormatters.iso8601String(from: Date())
        ) {
            accountRegistry.append(hiddenEntry)
        }
    }

    /// Permanent delete: remove linked Keychain credentials and suppress rediscovery.
    /// Multi-workspace providers (Codex) can come back from ~/.codex or AuthImports unless
    /// a permanently-removed tombstone remains — those are hidden from the Hidden Accounts UI.
    @discardableResult
    func deleteAccount(
        _ entry: ProviderAccountEntry,
        onPostRegistryDelete: () -> Void = {}
    ) -> Bool {
        !deleteAccounts([entry], onPostRegistryDelete: { _ in onPostRegistryDelete() }).isEmpty
    }

    @_disfavoredOverload
    @discardableResult
    func deleteAccounts(
        _ entries: [ProviderAccountEntry],
        onPostRegistryDelete: () -> Void
    ) -> [ProviderAccountEntry] {
        deleteAccounts(entries) { _ in
            onPostRegistryDelete()
        }
    }

    @discardableResult
    func deleteAccounts(
        _ entries: [ProviderAccountEntry],
        onPostRegistryDelete: ([ProviderAccountEntry]) -> Void = { _ in }
    ) -> [ProviderAccountEntry] {
        guard !entries.isEmpty else { return [] }

        var allCredentialsDeleted = true
        var deletedEntries: [ProviderAccountEntry] = []
        var deletedCredentials: [AccountCredential] = []

        for entry in entries {
            let matchedCredentials = matchingCredentialsImpl(for: entry)
            do {
                try AccountCredentialStore.shared.deleteCredentials(matchedCredentials)
            } catch {
                accountPersistenceLog.error(
                    "Failed to delete credentials for \(entry.providerId, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                allCredentialsDeleted = false
                continue
            }
            deletedEntries.append(entry)
            deletedCredentials.append(contentsOf: matchedCredentials)

            let matchingIndices = matchingStoredAccountIndices(for: entry)
            for index in matchingIndices.sorted(by: >) {
                accountRegistry.remove(at: index)
            }

            if let tombstone = makeStoredAccount(
                from: entry,
                note: nil,
                isHidden: true,
                lastSeenAt: SharedFormatters.iso8601String(from: Date()),
                isPermanentlyRemoved: true
            ) {
                accountRegistry.append(tombstone)
            }
        }

        guard !deletedEntries.isEmpty else { return [] }

        _ = normalizeAccountRegistryAgainstCredentials()
        deduplicateAccountRegistry()
        let registryPersisted = persistAccountRegistry()

        onPostRegistryDelete(deletedEntries)

        if registryPersisted, allCredentialsDeleted {
            cleanupManagedCredentialArtifacts(forDeletedCredentials: deletedCredentials)
        }

        return deletedEntries
    }

    func accountNote(for provider: ProviderData) -> String? {
        accountRegistry.first(where: { !$0.isHidden && storedAccountMatchesLive($0, provider: provider) })?.note?.nilIfBlank
    }

    /// Credentials that plausibly belong to this account entry (used for CLI path resolution, etc.).
    func matchingCredentials(for entry: ProviderAccountEntry) -> [AccountCredential] {
        matchingCredentialsImpl(for: entry)
    }

    func hiddenAccounts() -> [StoredProviderAccount] {
        let providerOrder = providerCatalogOrder
        return accountRegistry
            .filter { $0.isHidden && !$0.isPermanentlyRemoved }
            .sorted {
                if $0.providerId != $1.providerId {
                    let lhsIndex = providerOrder.firstIndex(of: $0.providerId) ?? Int.max
                    let rhsIndex = providerOrder.firstIndex(of: $1.providerId) ?? Int.max
                    return lhsIndex < rhsIndex
                }
                return $0.preferredLabel.localizedCaseInsensitiveCompare($1.preferredLabel) == .orderedAscending
            }
    }

    @MainActor
    func reconcileAccountRegistry(
        with providers: [ProviderData],
        isValid: @MainActor (ProviderData) -> Bool = { _ in true }
    ) async {
        let providerOrder = providerCatalogOrder
        var baselineRegistry = accountRegistry
        var baselineRevision = accountRegistryRevision
        var attempts = 0

        while attempts < 2 {
            attempts += 1
            let validProviders = providers.filter(isValid)
            guard providers.isEmpty || !validProviders.isEmpty else { return }
            let result = await AccountRegistryRefreshWorker.shared.reconcile(
                currentRegistry: baselineRegistry,
                providers: validProviders,
                providerCatalogOrder: providerOrder
            )

            // worker 挂起期间可能发生账号重置；提交前复核，重算时只保留仍有效的行。
            if !validProviders.allSatisfy(isValid)
                || accountRegistryRevision != baselineRevision || accountRegistry != baselineRegistry {
                baselineRegistry = accountRegistry
                baselineRevision = accountRegistryRevision
                continue
            }

            if result.accounts != accountRegistry {
                accountRegistry = result.accounts
            }

            if result.didChange {
                let revision = accountRegistryRevision
                Task.detached(priority: .utility) {
                    await AccountRegistryRefreshWorker.shared.schedulePersist(
                        result.accounts,
                        revision: revision
                    )
                }
            }
            return
        }

        accountPersistenceLog.warning(
            "Skipped applying background account reconciliation because local registry changed concurrently"
        )
    }

    func hasHiddenRegistryMatch(
        providerId: String,
        normalizedEmail: String?,
        normalizedAccountId: String?,
        sourceFilePath: String? = nil,
        workspaceUserId: String? = nil
    ) -> Bool {
        accountRegistry.contains { stored in
            guard stored.providerId == providerId, stored.isHidden else { return false }
            if providerId == "codex" {
                let saved = AccountIdentityPolicy.codexIdentity(for: stored)
                let incoming = CodexAccountIdentity(accountId: normalizedAccountId, userId: workspaceUserId, email: normalizedEmail)
                guard !saved.conflicts(with: incoming) else { return false }
                return saved.matches(incoming)
                    || AccountIdentityPolicy.sourceFilePathsMatch(stored.sourceFilePath, sourceFilePath)
            }
            if AccountIdentityPolicy.isMultiWorkspace(providerId) {
                if AccountIdentityPolicy.sourceFilePathsMatch(stored.sourceFilePath, sourceFilePath) {
                    return true
                }
                if let normalizedEmail, stored.normalizedEmail == normalizedEmail {
                    if let normalizedAccountId, let storedAccountId = stored.normalizedAccountId,
                       storedAccountId != stored.normalizedEmail,
                       normalizedAccountId != normalizedEmail {
                        return storedAccountId == normalizedAccountId
                    }
                    return true
                }
                return false
            }
            if let normalizedAccountId,
               stored.normalizedAccountId == normalizedAccountId {
                return true
            }
            if let normalizedEmail,
               stored.normalizedEmail == normalizedEmail {
                return true
            }
            return false
        }
    }

    /// Whether `stored` refers to the same logical account as live `provider` data.
    func matchesStoredWithLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool {
        storedAccountMatchesLive(stored, provider: provider)
    }
}
