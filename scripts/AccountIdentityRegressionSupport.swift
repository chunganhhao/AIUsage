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

final class SecureAccountVault {
    static let shared = SecureAccountVault()
    var accounts: [StoredProviderAccount] = []
    func loadAccounts() -> [StoredProviderAccount] { accounts }
    func saveAccounts(_ accounts: [StoredProviderAccount]) throws { self.accounts = accounts }
}

enum ProviderManagedImportStore {
    static var cleanupInvocations = 0
    static func reuseManagedImportIfPossible(existingCredential: AccountCredential, incomingCredential: inout AccountCredential) {}
    static func cleanupOrphanedManagedImports(referencedBy credentials: [AccountCredential]) {
        cleanupInvocations += 1
    }
}

enum ProviderAuthManager {}
