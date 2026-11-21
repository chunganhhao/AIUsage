import Foundation
import QuotaBackend

// 仅替换系统边界。账号保存、匹配、协调、隐藏、删除均编译并运行正式源码。
// 不访问 Keychain、不扫描用户目录、不启动主 App。
final class AccountCredentialStore {
    static let shared = AccountCredentialStore()
    static var multiWorkspaceProviders: Set<String> { QuotaBackend.AccountCredentialStore.multiWorkspaceProviders }
    static func isMultiWorkspace(_ id: String) -> Bool { QuotaBackend.AccountCredentialStore.isMultiWorkspace(id) }
    static func normalizedAuthFilePath(_ path: String) -> String { QuotaBackend.AccountCredentialStore.normalizedAuthFilePath(path) }
    static func isEphemeralTemporaryAuthPath(_ path: String) -> Bool { QuotaBackend.AccountCredentialStore.isEphemeralTemporaryAuthPath(path) }
    static func persistentSourcePath(from path: String?) -> String? { QuotaBackend.AccountCredentialStore.persistentSourcePath(from: path) }
    static func credentialsShareCanonicalIdentity(_ a: AccountCredential, _ b: AccountCredential) -> Bool {
        QuotaBackend.AccountCredentialStore.credentialsShareCanonicalIdentity(a, b)
    }
    struct Plan {
        let remappedCredentialIDs: [String: String] = [:]
        var isEmpty: Bool { true }
    }
    var credentials: [AccountCredential] = []
    var shouldFailDelete = false
    var failSavesAfterDeleteFailure = false
    var writeFailureActive = false
    var failedDeleteIDs: Set<String> = []
    func loadCredentials(for id: String) -> [AccountCredential] { credentials.filter { $0.providerId == id } }
    func loadAllCredentials() -> [AccountCredential] { credentials }
    func loadCredential(providerId: String, credentialId: String) -> AccountCredential? {
        credentials.first { $0.providerId == providerId && $0.id == credentialId }
    }
    func saveCredential(_ credential: AccountCredential) throws {
        if writeFailureActive {
            throw CredentialStoreError.keychainWriteFailed(-25291)
        }
        credentials.removeAll { $0.id == credential.id }
        credentials.append(credential)
    }
    func deleteCredential(_ credential: AccountCredential) throws {
        try deleteCredentials([credential])
    }
    func deleteCredentials(_ credentialsToRemove: [AccountCredential]) throws {
        guard !credentialsToRemove.isEmpty else { return }
        if shouldFailDelete || writeFailureActive || credentialsToRemove.contains(where: { failedDeleteIDs.contains($0.id) }) {
            if failSavesAfterDeleteFailure { writeFailureActive = true }
            throw CredentialStoreError.keychainWriteFailed(-25291)
        }
        let idsToRemove = Set(credentialsToRemove.map(\.id))
        credentials.removeAll { idsToRemove.contains($0.id) }
    }
    func planCredentialDeduplication(for id: String? = nil) -> Plan { Plan() }
    func commitCredentialDeduplication(_ plan: Plan) -> Bool { true }
    func bootstrapCredentialIndex(references: [AccountCredentialReference]) {}
}

final class SecureAccountVault: @unchecked Sendable {
    static let shared = SecureAccountVault()
    private static let auxiliaryKey = "providerAccounts.registry"

    typealias BeforeAcquireHook = @Sendable ([StoredProviderAccount], UInt64) throws -> Void
    typealias PhysicalWriteHook = @Sendable (Data, [StoredProviderAccount]) throws -> Void
    typealias AfterReleaseHook = @Sendable ([StoredProviderAccount], UInt64, AccountRegistrySaveOutcome) throws -> Void

    private struct DecodedVaultEnvelope: Decodable {
        let auxiliary: [String: Data]?
    }

    private let hookLock = NSLock()
    private var inMemoryVaultData: Data?
    private var backingFileURL: URL?
    private var suppressPhysicalWriteHook = false
    private var beforeAcquireLockHook: BeforeAcquireHook?
    private var onPhysicalWriteHook: PhysicalWriteHook?
    private var afterReleaseLockHook: AfterReleaseHook?
    private lazy var credentialStore: QuotaBackend.AccountCredentialStore = makeStore()

    var accounts: [StoredProviderAccount] {
        get { loadAccounts() }
        set {
            let newStore = makeStore()
            hookLock.withLock {
                if let url = backingFileURL {
                    try? FileManager.default.removeItem(at: url)
                } else {
                    inMemoryVaultData = nil
                }
                credentialStore = newStore
                suppressPhysicalWriteHook = true
            }
            defer { hookLock.withLock { suppressPhysicalWriteHook = false } }
            if !newValue.isEmpty, let encoded = try? JSONEncoder().encode(newValue) {
                try? newStore.saveAuxiliaryData(encoded, forKey: Self.auxiliaryKey)
            }
        }
    }

    var committedRevision: UInt64? {
        currentStore().committedAuxiliaryRevision(forKey: Self.auxiliaryKey)
    }

    func configureTestHooks(
        backingFileURL: URL? = nil,
        resetStore: Bool = false,
        beforeAcquireLock: BeforeAcquireHook? = nil,
        onPhysicalWrite: PhysicalWriteHook? = nil,
        afterReleaseLock: AfterReleaseHook? = nil
    ) {
        let shouldRebuildStore = hookLock.withLock {
            let urlChanged = self.backingFileURL != backingFileURL
            self.backingFileURL = backingFileURL
            self.beforeAcquireLockHook = beforeAcquireLock
            self.onPhysicalWriteHook = onPhysicalWrite
            self.afterReleaseLockHook = afterReleaseLock
            if resetStore {
                self.inMemoryVaultData = nil
            }
            return urlChanged || resetStore
        }
        if shouldRebuildStore {
            let rebuilt = makeStore()
            hookLock.withLock {
                self.credentialStore = rebuilt
            }
        }
    }

    func loadAccounts() -> [StoredProviderAccount] {
        guard let data = currentStore().loadAuxiliaryData(forKey: Self.auxiliaryKey) else {
            return []
        }
        return decodeAccounts(data)
    }

    @discardableResult
    func saveAccounts(_ accounts: [StoredProviderAccount], revision: UInt64 = 0) throws -> AccountRegistrySaveOutcome {
        let data = try JSONEncoder().encode(accounts)
        let beforeHook = hookLock.withLock { beforeAcquireLockHook }
        try beforeHook?(accounts, revision)

        let outcome: AccountRegistrySaveOutcome
        switch try currentStore().saveAuxiliaryData(data, forKey: Self.auxiliaryKey, revision: revision) {
        case .committed:
            outcome = .committed
        case .superseded(let committedRevision, let committedData):
            outcome = .superseded(
                committedRevision: committedRevision,
                committedAccounts: committedData.map { decodeAccounts($0) }
            )
        }

        let afterHook = hookLock.withLock { afterReleaseLockHook }
        try afterHook?(accounts, revision, outcome)
        return outcome
    }

    private func currentStore() -> QuotaBackend.AccountCredentialStore {
        hookLock.withLock { credentialStore }
    }

    private func makeStore() -> QuotaBackend.AccountCredentialStore {
        QuotaBackend.AccountCredentialStore(
            readVaultData: { [weak self] in
                guard let self else { return nil }
                let (url, memData) = self.hookLock.withLock { (self.backingFileURL, self.inMemoryVaultData) }
                if let url {
                    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
                    return try Data(contentsOf: url)
                }
                return memData
            },
            writeVaultData: { [weak self] data in
                guard let self else { return }
                let (url, hook, suppressed) = self.hookLock.withLock {
                    (self.backingFileURL, self.onPhysicalWriteHook, self.suppressPhysicalWriteHook)
                }
                if !suppressed, let hook {
                    let decoded = self.decodeAccountsFromVaultData(data)
                    try hook(data, decoded)
                }
                if let url {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else {
                    self.hookLock.withLock { self.inMemoryVaultData = data }
                }
            }
        )
    }

    private func decodeAccountsFromVaultData(_ data: Data) -> [StoredProviderAccount] {
        guard let envelope = try? JSONDecoder().decode(DecodedVaultEnvelope.self, from: data),
              let auxData = envelope.auxiliary?[Self.auxiliaryKey] else {
            return []
        }
        return decodeAccounts(auxData)
    }

    private func decodeAccounts(_ data: Data) -> [StoredProviderAccount] {
        (try? JSONDecoder().decode([StoredProviderAccount].self, from: data)) ?? []
    }
}

enum ProviderManagedImportStore {
    static var cleanupInvocations = 0
    static var deletedCleanupCredentialIDs: [String] = []
    static func reuseManagedImportIfPossible(existingCredential: AccountCredential, incomingCredential: inout AccountCredential) {}
    static func cleanupOrphanedManagedImports(referencedBy credentials: [AccountCredential]) {
        cleanupInvocations += 1
    }
    static func cleanupManagedImports(
        forDeletedCredentials deletedCredentials: [AccountCredential],
        referencedBy remainingCredentials: [AccountCredential]
    ) {
        cleanupInvocations += 1
        deletedCleanupCredentialIDs.append(contentsOf: deletedCredentials.map(\.id))
    }
}

enum ProviderAuthManager {}
