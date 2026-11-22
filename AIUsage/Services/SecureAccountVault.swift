import Foundation
import os.log
import QuotaBackend

private let vaultLog = Logger(subsystem: "com.aiusage.desktop", category: "SecureAccountVault")

/// Stores the provider account registry as an auxiliary blob inside the single
/// credential vault item owned by `AccountCredentialStore` (so the whole app keeps
/// exactly one keychain item and at most one "Always Allow" prompt). Migration
/// from any older standalone keychain item is handled once by `LegacyKeychainCutover`;
/// this type only ever reads/writes the unified vault's auxiliary blob.
final class SecureAccountVault: @unchecked Sendable {
    nonisolated static let shared = SecureAccountVault()

    /// Key under which the registry blob lives inside the unified vault item.
    private static let auxiliaryKey = "providerAccounts.registry"

    private let credentialStore: QuotaBackend.AccountCredentialStore

    init(credentialStore: QuotaBackend.AccountCredentialStore = .shared) {
        self.credentialStore = credentialStore
    }

    // MARK: - Public API

    nonisolated var committedRevision: UInt64? {
        credentialStore.committedAuxiliaryRevision(forKey: Self.auxiliaryKey)
    }

    nonisolated func loadAccounts() -> [StoredProviderAccount] {
        guard let data = credentialStore.loadAuxiliaryData(forKey: Self.auxiliaryKey) else {
            return []
        }
        return decodeAccounts(data)
    }

    @discardableResult
    nonisolated func saveAccounts(
        _ accounts: [StoredProviderAccount],
        revision: UInt64
    ) throws -> AccountRegistrySaveOutcome {
        let data = try JSONEncoder().encode(accounts)
        switch try credentialStore.saveAuxiliaryData(
            data,
            forKey: Self.auxiliaryKey,
            revision: revision
        ) {
        case .committed:
            return .committed
        case .superseded(let committedRevision, let committedData):
            return .superseded(
                committedRevision: committedRevision,
                committedAccounts: committedData.map { decodeAccounts($0) }
            )
        }
    }

    // MARK: - Helpers

    private func decodeAccounts(_ data: Data) -> [StoredProviderAccount] {
        do {
            return try JSONDecoder().decode([StoredProviderAccount].self, from: data)
        } catch {
            vaultLog.error("Account registry decode failed: \(String(describing: error), privacy: .public)")
            return []
        }
    }
}
