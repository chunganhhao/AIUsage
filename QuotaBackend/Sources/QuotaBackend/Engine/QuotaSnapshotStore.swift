import Darwin
import Foundation

public enum QuotaSnapshotStoreError: Error, LocalizedError, Sendable {
    case unsafePath(String)

    public var errorDescription: String? {
        switch self {
        case .unsafePath(let path):
            return "Refused unsafe symlink or non-owned quota snapshot path: \(path)"
        }
    }
}

public enum QuotaSnapshotIdentity: Hashable, Sendable {
    case codexNative(accountId: String, userId: String)
    case codexCredentialFallback(id: String)
    case antigravityEmail(email: String, projectId: String?)
    case antigravityCredentialFallback(id: String)
    case accountFallback(providerId: String, accountKey: String)

    /// Deterministic, collision-free canonical key using base64url segments.
    /// Never uses Swift `Hasher`.
    public var storageKey: String {
        switch self {
        case let .codexNative(accountId, userId):
            return "v1:codex:native:\(Self.b64u(accountId)):\(Self.b64u(userId))"
        case let .codexCredentialFallback(id):
            return "v1:codex:cred:\(Self.b64u(id))"
        case let .antigravityEmail(email, projectId):
            let normalizedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let projectId = projectId?.trimmingCharacters(in: .whitespacesAndNewlines), !projectId.isEmpty {
                return "v1:agy:email:\(Self.b64u(normalizedEmail)):proj:\(Self.b64u(projectId))"
            }
            return "v1:agy:email:\(Self.b64u(normalizedEmail))"
        case let .antigravityCredentialFallback(id):
            return "v1:agy:cred:\(Self.b64u(id))"
        case let .accountFallback(providerId, accountKey):
            return "v1:other:\(Self.b64u(providerId.lowercased())):\(Self.b64u(accountKey))"
        }
    }

    private static func b64u(_ raw: String) -> String {
        Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct PersistedQuotaSnapshot: Codable, Sendable {
    public var storageKey: String
    public var providerId: String
    public var credentialId: String?
    public var accountId: String?
    public var workspaceUserId: String?
    public var projectId: String?
    public var accountLabel: String?
    public var membershipLabel: String?
    public var workspaceLabel: String?
    public var name: String
    public var label: String
    public var description: String
    public var category: String
    public var channel: String?
    public var status: String
    public var statusLabel: String
    public var themeAccent: String
    public var themeGlow: String
    public var sourceLabel: String
    public var sourceType: String
    public var fetchedAt: String
    public var remainingPercent: Double?
    public var nextResetAt: String?
    public var nextResetLabel: String?
    public var headline: HeadlineInfo
    public var windows: [WindowInfo]
    public var metrics: [MetricInfo]
    public var models: [ModelInfo]?
    public var spotlight: String
    public var codexResetCreditsAvailableCount: Int?
    public var transport: String?

    public func toProviderResult(credentialIdOverride: String? = nil) -> ProviderResult {
        let resolvedCredentialId = credentialIdOverride ?? credentialId
        let uniqueId: String
        if let resolvedCredentialId = resolvedCredentialId?.trimmingCharacters(in: .whitespacesAndNewlines),
           !resolvedCredentialId.isEmpty {
            uniqueId = "\(providerId):cred:\(resolvedCredentialId)"
        } else {
            let acct = accountId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "default"
            uniqueId = "\(providerId):auto:\(acct)"
        }

        let summary = ProviderSummary(
            id: uniqueId,
            providerId: providerId,
            accountId: accountId,
            name: name,
            label: label,
            description: description,
            category: category,
            channel: channel,
            status: status,
            statusLabel: statusLabel,
            theme: ThemeInfo(accent: themeAccent, glow: themeGlow),
            sourceLabel: sourceLabel,
            sourceType: sourceType,
            fetchedAt: fetchedAt,
            accountLabel: accountLabel,
            membershipLabel: membershipLabel,
            workspaceLabel: workspaceLabel,
            workspaceUserId: workspaceUserId,
            remainingPercent: remainingPercent,
            nextResetAt: nextResetAt,
            nextResetLabel: nextResetLabel,
            headline: headline,
            metrics: metrics,
            windows: windows,
            costSummary: nil,
            models: models,
            spotlight: spotlight,
            unpricedModels: nil,
            raw: nil,
            sourceFilePath: nil,
            codexResetCreditsAvailableCount: codexResetCreditsAvailableCount,
            errorCode: nil
        )

        var usage: ProviderUsage?
        if let transport = transport?.trimmingCharacters(in: .whitespacesAndNewlines), !transport.isEmpty {
            var synthetic = ProviderUsage(provider: providerId, label: label)
            synthetic.fetchedAt = fetchedAt
            synthetic.usageAccountId = accountId
            synthetic.accountEmail = accountLabel
            synthetic.extra["transport"] = AnyCodable(transport)
            usage = synthetic
        }

        return ProviderResult(
            id: uniqueId,
            providerId: providerId,
            accountId: accountId,
            ok: true,
            usage: usage,
            summary: summary,
            error: nil
        )
    }
}

public struct QuotaSnapshotDocument: Codable, Sendable {
    public var version: Int
    public var snapshots: [String: PersistedQuotaSnapshot]

    public init(version: Int = 1, snapshots: [String: PersistedQuotaSnapshot] = [:]) {
        self.version = version
        self.snapshots = snapshots
    }
}

public struct QuotaSnapshotWindowInput: Sendable, Equatable {
    public let label: String
    public let remainingPercent: Double?
    public let resetAt: String?

    public init(label: String, remainingPercent: Double?, resetAt: String?) {
        self.label = label
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
    }
}

public enum QuotaSnapshotHealthStatus: Sendable, Equatable {
    case fresh
    case pastReset(earliestResetAt: Date)
    case weeklyDepleted(resetAt: Date)

    public var isWeeklyDepleted: Bool {
        if case .weeklyDepleted = self { return true }
        return false
    }

    public var isPastReset: Bool {
        if case .pastReset = self { return true }
        return false
    }
}

public enum QuotaSnapshotHealth {
    public static func isWeeklyWindowLabel(_ label: String) -> Bool {
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return lower.contains("weekly")
            || lower.contains("7d")
            || lower == "week"
            || lower.contains("week window")
    }

    public static func assess(windows: [WindowInfo], now: Date = Date()) -> QuotaSnapshotHealthStatus {
        let inputs = windows.map {
            QuotaSnapshotWindowInput(label: $0.label, remainingPercent: $0.remainingPercent, resetAt: $0.resetAt)
        }
        return assess(windows: inputs, now: now)
    }

    public static func assess(windows: [QuotaSnapshotWindowInput], now: Date = Date()) -> QuotaSnapshotHealthStatus {
        var earliestPastReset: Date?
        for window in windows {
            guard let resetAtRaw = window.resetAt,
                  let resetAt = SharedFormatters.parseISO8601(resetAtRaw) else {
                continue
            }
            if isWeeklyWindowLabel(window.label),
               let remaining = window.remainingPercent,
               remaining <= 0,
               now < resetAt {
                return .weeklyDepleted(resetAt: resetAt)
            }
            if now >= resetAt {
                if let existing = earliestPastReset {
                    if resetAt < existing { earliestPastReset = resetAt }
                } else {
                    earliestPastReset = resetAt
                }
            }
        }
        if let earliestPastReset {
            return .pastReset(earliestResetAt: earliestPastReset)
        }
        return .fresh
    }
}

public struct QuotaSnapshotBestNextCandidate: Sendable, Equatable {
    public let id: String
    public let providerId: String
    public let label: String
    public let remainingPercent: Double
    public let fetchedAt: Date?
    public let health: QuotaSnapshotHealthStatus

    public init(
        id: String,
        providerId: String,
        label: String,
        remainingPercent: Double,
        fetchedAt: Date?,
        health: QuotaSnapshotHealthStatus
    ) {
        self.id = id
        self.providerId = providerId
        self.label = label
        self.remainingPercent = remainingPercent
        self.fetchedAt = fetchedAt
        self.health = health
    }
}

public enum QuotaSnapshotAdvisor {
    public struct CandidateInput: Sendable {
        public let id: String
        public let providerId: String
        public let label: String
        public let remainingPercent: Double?
        public let fetchedAt: Date?
        public let isActive: Bool
        public let isTerminalSuspended: Bool
        public let windows: [QuotaSnapshotWindowInput]

        public init(
            id: String,
            providerId: String,
            label: String,
            remainingPercent: Double?,
            fetchedAt: Date?,
            isActive: Bool,
            isTerminalSuspended: Bool,
            windows: [QuotaSnapshotWindowInput]
        ) {
            self.id = id
            self.providerId = providerId
            self.label = label
            self.remainingPercent = remainingPercent
            self.fetchedAt = fetchedAt
            self.isActive = isActive
            self.isTerminalSuspended = isTerminalSuspended
            self.windows = windows
        }
    }

    /// Read-only ranking of dormant accounts from cached snapshots. Never triggers
    /// network calls, account switching, or credential writes.
    public static func bestNextCandidate(
        from inputs: [CandidateInput],
        now: Date = Date()
    ) -> QuotaSnapshotBestNextCandidate? {
        let ranked = inputs.compactMap { input -> QuotaSnapshotBestNextCandidate? in
            guard !input.isActive,
                  !input.isTerminalSuspended else {
                return nil
            }
            let health = QuotaSnapshotHealth.assess(windows: input.windows, now: now)
            guard !health.isWeeklyDepleted else { return nil }
            let remaining = input.remainingPercent ?? input.windows.compactMap(\.remainingPercent).min() ?? 0
            // Accounts depleted at 0% are only usable if a cached window has already passed reset.
            guard remaining > 0 || health.isPastReset else { return nil }
            return QuotaSnapshotBestNextCandidate(
                id: input.id,
                providerId: input.providerId,
                label: input.label,
                remainingPercent: remaining,
                fetchedAt: input.fetchedAt,
                health: health
            )
        }

        return ranked.max { lhs, rhs in
            if lhs.remainingPercent != rhs.remainingPercent {
                return lhs.remainingPercent < rhs.remainingPercent
            }
            let lhsTime = lhs.fetchedAt ?? .distantPast
            let rhsTime = rhs.fetchedAt ?? .distantPast
            if lhsTime != rhsTime {
                return lhsTime < rhsTime
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedDescending
        }
    }
}

public final class QuotaSnapshotStore: @unchecked Sendable {
    public static let supportedProviders: Set<String> = ["antigravity", "codex"]
    public static let defaultStore = QuotaSnapshotStore.store(homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path)

    public let fileURL: URL
    public let lockURL: URL
    private let processLock = NSLock()

    public init(fileURL: URL, lockURL: URL? = nil) {
        self.fileURL = fileURL
        self.lockURL = lockURL ?? fileURL.deletingLastPathComponent().appendingPathComponent("quota-snapshots.lock", isDirectory: false)
    }

    public static func store(homeDirectory: String) -> QuotaSnapshotStore {
        let directory = URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("AIUsage", isDirectory: true)
        return QuotaSnapshotStore(
            fileURL: directory.appendingPathComponent("quota-snapshots.json", isDirectory: false),
            lockURL: directory.appendingPathComponent("quota-snapshots.lock", isDirectory: false)
        )
    }

    public func loadDocument() -> QuotaSnapshotDocument {
        processLock.lock()
        defer { processLock.unlock() }
        return (try? withFileLock(createIfMissing: false) { loadDocumentUnsafe() }) ?? QuotaSnapshotDocument()
    }

    @discardableResult
    public func save(result: ProviderResult, credential: AccountCredential? = nil) -> Bool {
        guard result.ok,
              (result.usage?.extra["snapshotState"]?.value as? String) != "pending",
              let summary = result.summary,
              Self.supportedProviders.contains(result.providerId.lowercased()) else {
            return false
        }
        guard let fetchedAt = normalizedFetchedAt(summary: summary, usage: result.usage) else {
            return false
        }
        let primaryIdentity = Self.identity(from: result, credential: credential)
        let primaryKey = primaryIdentity.storageKey
        let snapshot = makePersistedSnapshot(
            storageKey: primaryKey,
            result: result,
            summary: summary,
            credential: credential,
            fetchedAt: fetchedAt
        )

        let incomingDate = SharedFormatters.parseISO8601(fetchedAt)

        processLock.lock()
        defer { processLock.unlock() }
        do {
            var didWrite = false
            try withFileLock(createIfMissing: true) {
                var doc = loadDocumentUnsafe()
                if let existing = doc.snapshots[primaryKey],
                   let existingDate = SharedFormatters.parseISO8601(existing.fetchedAt),
                   let incomingDate,
                   incomingDate < existingDate {
                    return
                }
                // Upgrade fallback key for the exact same credential without touching peer workspaces.
                let obsoleteKeys = Self.obsoleteAliasKeys(for: result, credential: credential, keeping: primaryKey)
                for obsoleteKey in obsoleteKeys {
                    if let existing = doc.snapshots[obsoleteKey],
                       existing.credentialId == nil || existing.credentialId == snapshot.credentialId {
                        if let existingDate = SharedFormatters.parseISO8601(existing.fetchedAt),
                           let incomingDate,
                           incomingDate < existingDate {
                            return
                        }
                        doc.snapshots.removeValue(forKey: obsoleteKey)
                    }
                }
                doc.snapshots[primaryKey] = snapshot
                try saveDocumentUnsafe(doc)
                didWrite = true
            }
            return didWrite
        } catch {
            return false
        }
    }

    public func snapshot(for credential: AccountCredential) -> PersistedQuotaSnapshot? {
        let doc = loadDocument()
        return Self.matchingSnapshot(in: doc, for: credential)
    }

    public func nativeCodexSnapshot(accountId: String, userId: String) -> PersistedQuotaSnapshot? {
        let doc = loadDocument()
        let key = QuotaSnapshotIdentity.codexNative(accountId: accountId, userId: userId).storageKey
        return doc.snapshots[key]
    }

    public func removeSnapshots(for credential: AccountCredential) {
        let candidateKeys = Self.allCandidateKeys(for: credential)
        let credId = credential.id
        let providerLower = credential.providerId.lowercased()
        let credEmail = Self.antigravityEmail(from: credential)
        let credProject = Self.antigravityProjectId(from: credential)

        processLock.lock()
        defer { processLock.unlock() }
        try? withFileLock(createIfMissing: false) {
            var doc = loadDocumentUnsafe()
            var changed = false
            for key in candidateKeys where doc.snapshots.removeValue(forKey: key) != nil {
                changed = true
            }
            for (key, snap) in doc.snapshots where snap.providerId.lowercased() == providerLower {
                let sameCred = snap.credentialId == credId
                let sameAgyEmailWithoutProject = providerLower == "antigravity"
                    && credProject == nil
                    && credEmail != nil
                    && snap.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == credEmail
                    && (snap.credentialId == nil || snap.credentialId == credId)
                if sameCred || sameAgyEmailWithoutProject {
                    doc.snapshots.removeValue(forKey: key)
                    changed = true
                }
            }
            if changed {
                try saveDocumentUnsafe(doc)
            }
        }
    }

    public func removeSnapshots(
        providerId: String,
        storageKeys: Set<String> = [],
        credentialIds: Set<String> = [],
        accountIds: Set<String> = [],
        emails: Set<String> = []
    ) {
        let normalizedProvider = providerId.lowercased()
        let normalizedEmails = Set(emails.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty })
        let normalizedAccounts = Set(accountIds.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        let hasSpecificIdentity = !storageKeys.isEmpty || !credentialIds.isEmpty
        guard hasSpecificIdentity || !normalizedEmails.isEmpty || !normalizedAccounts.isEmpty else { return }

        processLock.lock()
        defer { processLock.unlock() }
        try? withFileLock(createIfMissing: false) {
            var doc = loadDocumentUnsafe()
            var changed = false
            for (key, snap) in doc.snapshots where snap.providerId.lowercased() == normalizedProvider {
                let keyMatch = storageKeys.contains(snap.storageKey) || storageKeys.contains(key)
                let credMatch = snap.credentialId.map { credentialIds.contains($0) } ?? false
                let fallbackMatch: Bool
                if !hasSpecificIdentity {
                    let acctMatch = snap.accountId.map { normalizedAccounts.contains($0) } ?? false
                    let emailMatch = snap.accountLabel
                        .map { normalizedEmails.contains($0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) }
                        ?? false
                    fallbackMatch = acctMatch || emailMatch
                } else {
                    fallbackMatch = false
                }
                if keyMatch || credMatch || fallbackMatch {
                    doc.snapshots.removeValue(forKey: key)
                    changed = true
                }
            }
            if changed {
                try saveDocumentUnsafe(doc)
            }
        }
    }

    public static func canonicalStorageKey(for credential: AccountCredential) -> String? {
        let providerLower = credential.providerId.lowercased()
        if providerLower == "codex" {
            let identity = CodexAccountIdentity(credential: credential)
            if let accountId = identity.accountId, let userId = identity.userId {
                return QuotaSnapshotIdentity.codexNative(accountId: accountId, userId: userId).storageKey
            }
            return nil
        }
        if providerLower == "antigravity" {
            guard let email = antigravityEmail(from: credential) else { return nil }
            let projectId = antigravityProjectId(from: credential)
            return QuotaSnapshotIdentity.antigravityEmail(email: email, projectId: projectId).storageKey
        }
        return nil
    }

    // MARK: - Identity Mapping

    public static func identity(from result: ProviderResult, credential: AccountCredential? = nil) -> QuotaSnapshotIdentity {
        let providerId = result.providerId.lowercased()
        let summary = result.summary

        if providerId == "codex" {
            let fromResult = CodexAccountIdentity(
                accountId: summary?.accountId ?? result.resultAccountId,
                userId: summary?.workspaceUserId,
                email: summary?.accountLabel
            )
            let fromCred = credential.map { CodexAccountIdentity(credential: $0) }
            let accountId = fromResult.accountId ?? fromCred?.accountId
            let userId = fromResult.userId ?? fromCred?.userId
            if let accountId = accountId?.trimmingCharacters(in: .whitespacesAndNewlines), !accountId.isEmpty,
               let userId = userId?.trimmingCharacters(in: .whitespacesAndNewlines), !userId.isEmpty {
                return .codexNative(accountId: accountId, userId: userId)
            }
            if let credential {
                return .codexCredentialFallback(id: credential.id)
            }
            if let accountKey = (summary?.accountId ?? result.resultAccountId ?? summary?.accountLabel ?? result.id).nilIfEmptyTrimmed {
                return .accountFallback(providerId: providerId, accountKey: accountKey)
            }
            return .codexCredentialFallback(id: result.id)
        }

        if providerId == "antigravity" {
            let email = (
                summary?.accountLabel
                ?? result.usage?.accountEmail
                ?? (credential.flatMap { antigravityEmail(from: $0) })
            )?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

            let extraProject = normalizedProjectId(result.usage?.extra["projectId"]?.value as? String)
            let metricProject = normalizedProjectId(
                summary?.metrics.first(where: { $0.label == "Project" })?.value
            )
            let credProject = credential.flatMap { antigravityProjectId(from: $0) }
            let projectId = extraProject ?? metricProject ?? credProject

            if let email, !email.isEmpty {
                return .antigravityEmail(email: email, projectId: projectId)
            }
            if let credential {
                return .antigravityCredentialFallback(id: credential.id)
            }
            return .antigravityCredentialFallback(id: result.id)
        }

        let key = summary?.accountId ?? result.resultAccountId ?? credential?.id ?? result.id
        return .accountFallback(providerId: providerId, accountKey: key)
    }

    public static func matchingSnapshot(
        in document: QuotaSnapshotDocument,
        for credential: AccountCredential
    ) -> PersistedQuotaSnapshot? {
        let providerLower = credential.providerId.lowercased()
        if providerLower == "codex" {
            let identity = CodexAccountIdentity(credential: credential)
            if let accountId = identity.accountId, let userId = identity.userId {
                let primaryKey = QuotaSnapshotIdentity.codexNative(accountId: accountId, userId: userId).storageKey
                if let hit = document.snapshots[primaryKey] { return hit }
                // Do not leak another Codex identity's snapshot if the credential's native claims exist.
                return nil
            }
            let fallbackKey = QuotaSnapshotIdentity.codexCredentialFallback(id: credential.id).storageKey
            if let hit = document.snapshots[fallbackKey] { return hit }
            return document.snapshots.values.first { snap in
                snap.providerId.lowercased() == "codex"
                    && snap.credentialId == credential.id
                    && (identity.accountId == nil || snap.accountId == nil || snap.accountId == identity.accountId)
            }
        }

        if providerLower == "antigravity" {
            let email = antigravityEmail(from: credential)
            let projectId = antigravityProjectId(from: credential)
            if let email {
                let exactKey = QuotaSnapshotIdentity.antigravityEmail(email: email, projectId: projectId).storageKey
                if let hit = document.snapshots[exactKey] { return hit }

                if projectId == nil {
                    // Credential lacked project_id metadata: match only snapshots with the same email.
                    let emailMatches = document.snapshots.values.filter {
                        $0.providerId.lowercased() == "antigravity"
                            && $0.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
                    }
                    if let byCred = emailMatches.first(where: { $0.credentialId == credential.id }) {
                        return byCred
                    }
                    if emailMatches.count == 1 {
                        return emailMatches.first
                    }
                }
                // Never cross-match a different email or explicit projectId by credentialId alone.
                return nil
            }
            let fallbackKey = QuotaSnapshotIdentity.antigravityCredentialFallback(id: credential.id).storageKey
            if let hit = document.snapshots[fallbackKey] { return hit }
            return document.snapshots.values.first {
                $0.providerId.lowercased() == "antigravity" && $0.credentialId == credential.id
            }
        }

        return nil
    }

    private static func allCandidateKeys(for credential: AccountCredential) -> [String] {
        var keys: [String] = []
        let providerLower = credential.providerId.lowercased()
        if providerLower == "codex" {
            let identity = CodexAccountIdentity(credential: credential)
            if let accountId = identity.accountId, let userId = identity.userId {
                keys.append(QuotaSnapshotIdentity.codexNative(accountId: accountId, userId: userId).storageKey)
            }
            keys.append(QuotaSnapshotIdentity.codexCredentialFallback(id: credential.id).storageKey)
        } else if providerLower == "antigravity" {
            if let email = antigravityEmail(from: credential) {
                let projectId = antigravityProjectId(from: credential)
                keys.append(QuotaSnapshotIdentity.antigravityEmail(email: email, projectId: projectId).storageKey)
                if projectId == nil {
                    keys.append(QuotaSnapshotIdentity.antigravityEmail(email: email, projectId: nil).storageKey)
                }
            }
            keys.append(QuotaSnapshotIdentity.antigravityCredentialFallback(id: credential.id).storageKey)
        }
        return keys
    }

    private static func obsoleteAliasKeys(
        for result: ProviderResult,
        credential: AccountCredential?,
        keeping primaryKey: String
    ) -> [String] {
        var aliases: [String] = []
        let providerLower = result.providerId.lowercased()
        if let credential {
            if providerLower == "codex" {
                aliases.append(QuotaSnapshotIdentity.codexCredentialFallback(id: credential.id).storageKey)
            } else if providerLower == "antigravity" {
                aliases.append(QuotaSnapshotIdentity.antigravityCredentialFallback(id: credential.id).storageKey)
                if let email = antigravityEmail(from: credential) ?? result.summary?.accountLabel {
                    let emailOnlyKey = QuotaSnapshotIdentity.antigravityEmail(email: email, projectId: nil).storageKey
                    if emailOnlyKey != primaryKey {
                        aliases.append(emailOnlyKey)
                    }
                }
            }
        }
        return aliases.filter { $0 != primaryKey }
    }

    private static func antigravityEmail(from credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile {
            let expanded = NSString(string: credential.credential).expandingTildeInPath
            if let data = FileManager.default.contents(atPath: expanded),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !email.isEmpty {
                return email
            }
        }
        return credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfEmptyTrimmed
    }

    private static func normalizedProjectId(_ raw: String?) -> String? {
        guard let trimmed = raw?.nilIfEmptyTrimmed else { return nil }
        let lower = trimmed.lowercased()
        if lower == "unknown" || lower == "aicode-consumers" {
            return nil
        }
        return trimmed
    }

    private static func antigravityProjectId(from credential: AccountCredential) -> String? {
        if credential.authMethod == .authFile {
            let expanded = NSString(string: credential.credential).expandingTildeInPath
            if let data = FileManager.default.contents(atPath: expanded),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let projectId = normalizedProjectId(json["project_id"] as? String) {
                return projectId
            }
        }
        return normalizedProjectId(credential.metadata["projectId"])
            ?? normalizedProjectId(credential.metadata["project_id"])
    }

    // MARK: - Snapshot Extraction (Non-Secret Whitelist)

    private func normalizedFetchedAt(summary: ProviderSummary, usage: ProviderUsage?) -> String? {
        if let rawFetchedAt = summary.fetchedAt?.nilIfEmptyTrimmed,
           SharedFormatters.parseISO8601(rawFetchedAt) != nil {
            return rawFetchedAt
        }
        if let usageFetchedAt = usage?.fetchedAt.nilIfEmptyTrimmed,
           SharedFormatters.parseISO8601(usageFetchedAt) != nil {
            return usageFetchedAt
        }
        return nil
    }

    private func makePersistedSnapshot(
        storageKey: String,
        result: ProviderResult,
        summary: ProviderSummary,
        credential: AccountCredential?,
        fetchedAt: String
    ) -> PersistedQuotaSnapshot {
        let projectId = Self.normalizedProjectId(result.usage?.extra["projectId"]?.value as? String)
            ?? Self.normalizedProjectId(summary.metrics.first(where: { $0.label == "Project" })?.value)
            ?? credential.flatMap { Self.antigravityProjectId(from: $0) }
        let transport = (result.usage?.extra["transport"]?.value as? String)?.nilIfEmptyTrimmed

        // Strip any metric whose label looks credential/secret-adjacent as defense-in-depth.
        let safeMetrics = summary.metrics.filter { metric in
            let lower = metric.label.lowercased()
            return !lower.contains("token") && !lower.contains("secret") && !lower.contains("key") && !lower.contains("cookie")
        }

        return PersistedQuotaSnapshot(
            storageKey: storageKey,
            providerId: summary.providerId,
            credentialId: credential?.id,
            accountId: summary.accountId ?? result.resultAccountId,
            workspaceUserId: summary.workspaceUserId,
            projectId: projectId,
            accountLabel: summary.accountLabel,
            membershipLabel: summary.membershipLabel,
            workspaceLabel: summary.workspaceLabel,
            name: summary.name,
            label: summary.label,
            description: summary.description,
            category: summary.category,
            channel: summary.channel,
            status: summary.status,
            statusLabel: summary.statusLabel,
            themeAccent: summary.theme.accent,
            themeGlow: summary.theme.glow,
            sourceLabel: summary.sourceLabel,
            sourceType: summary.sourceType,
            fetchedAt: fetchedAt,
            remainingPercent: summary.remainingPercent,
            nextResetAt: summary.nextResetAt,
            nextResetLabel: summary.nextResetLabel,
            headline: summary.headline,
            windows: summary.windows,
            metrics: safeMetrics,
            models: summary.models,
            spotlight: summary.spotlight,
            codexResetCreditsAvailableCount: summary.codexResetCreditsAvailableCount,
            transport: transport
        )
    }

    // MARK: - Locked Atomic File I/O

    private func loadDocumentUnsafe() -> QuotaSnapshotDocument {
        guard !isSymlink(fileURL.path),
              FileManager.default.fileExists(atPath: fileURL.path) else {
            return QuotaSnapshotDocument()
        }
        guard isRegularOwnedFile(fileURL.path) else {
            return QuotaSnapshotDocument()
        }
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else {
            return QuotaSnapshotDocument()
        }
        do {
            let decoded = try JSONDecoder().decode(QuotaSnapshotDocument.self, from: data)
            guard decoded.version == 1 else {
                return QuotaSnapshotDocument()
            }
            return decoded
        } catch {
            return QuotaSnapshotDocument()
        }
    }

    private func saveDocumentUnsafe(_ doc: QuotaSnapshotDocument) throws {
        try ensureSafeDirectory()
        if isSymlink(fileURL.path) {
            throw QuotaSnapshotStoreError.unsafePath(fileURL.path)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(doc)
        try data.write(to: fileURL, options: .atomic)
        _ = chmod(fileURL.path, 0o600)
    }

    private func withFileLock<T>(createIfMissing: Bool, _ body: () throws -> T) throws -> T {
        let dir = fileURL.deletingLastPathComponent()
        if !createIfMissing && !FileManager.default.fileExists(atPath: dir.path) {
            return try body()
        }
        try ensureSafeDirectory()
        if isSymlink(lockURL.path) || isSymlink(fileURL.path) {
            throw QuotaSnapshotStoreError.unsafePath(lockURL.path)
        }
        let fd = open(lockURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        guard flock(fd, LOCK_EX) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var statBuf = stat()
        if fstat(fd, &statBuf) == 0 {
            if (statBuf.st_mode & S_IFMT) != S_IFREG || statBuf.st_uid != geteuid() {
                throw QuotaSnapshotStoreError.unsafePath(lockURL.path)
            }
        }
        _ = chmod(lockURL.path, 0o600)
        return try body()
    }

    private func ensureSafeDirectory() throws {
        let dir = fileURL.deletingLastPathComponent()
        if isSymlink(dir.path) {
            throw QuotaSnapshotStoreError.unsafePath(dir.path)
        }
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        if isSymlink(dir.path) {
            throw QuotaSnapshotStoreError.unsafePath(dir.path)
        }
        var statBuf = stat()
        if lstat(dir.path, &statBuf) == 0 {
            if (statBuf.st_mode & S_IFMT) != S_IFDIR || statBuf.st_uid != geteuid() {
                throw QuotaSnapshotStoreError.unsafePath(dir.path)
            }
        }
        _ = chmod(dir.path, 0o700)
    }

    private func isSymlink(_ path: String) -> Bool {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFLNK
    }

    private func isRegularOwnedFile(_ path: String) -> Bool {
        var statBuf = stat()
        guard lstat(path, &statBuf) == 0 else { return false }
        return (statBuf.st_mode & S_IFMT) == S_IFREG && statBuf.st_uid == geteuid()
    }
}

private extension String {
    var nilIfEmptyTrimmed: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
