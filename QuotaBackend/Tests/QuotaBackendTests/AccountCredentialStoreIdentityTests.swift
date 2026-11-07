import Foundation
import XCTest
@testable import QuotaBackend

final class AccountCredentialStoreIdentityTests: XCTestCase {
    private func credential(
        id: String,
        providerId: String = "codex",
        path: String,
        metadata: [String: String] = [:]
    ) -> AccountCredential {
        AccountCredential(
            id: id,
            providerId: providerId,
            authMethod: .authFile,
            credential: path,
            metadata: metadata
        )
    }

    func testCanonicalIdentityKeyNormalizesNativeIdentityMetadata() {
        let value = credential(
            id: "copy-a",
            path: "/tmp/copy-a/auth.json",
            metadata: [
                "accountId": " User-123 ",
                "accountPlan": " Plus ",
                "userId": " Member-456 ",
            ]
        )

        XCTAssertEqual(
            AccountCredentialStore.canonicalIdentityKey(for: value),
            "codex:account:user-123:user:member-456"
        )
    }

    func testCompleteNativeIdentityMergesAcrossDifferentImportedPaths() {
        let first = credential(
            id: "copy-a",
            path: "/tmp/import-a/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "personal",
                "workspaceUserId": "member-456",
            ]
        )
        let second = credential(
            id: "copy-b",
            path: "/tmp/import-b/auth.json",
            metadata: [
                "accountId": "USER-123",
                "accountPlan": "PERSONAL",
                "userId": "MEMBER-456",
            ]
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))

        let result = AccountCredentialStore.shared.canonicalizationResult(for: [first, second])
        XCTAssertEqual(result.canonical.count, 1)
        XCTAssertEqual(result.remappedIDs.count, 1)
    }

    func testIncompleteNativeIdentityDoesNotMergeAcrossDifferentImportedPaths() {
        let incomplete = credential(
            id: "incomplete",
            path: "/tmp/import-a/auth.json",
            metadata: ["accountId": "user-123"]
        )
        let complete = credential(
            id: "complete",
            path: "/tmp/import-b/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "personal",
                "workspaceUserId": "member-456",
            ]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(incomplete, complete))

        let result = AccountCredentialStore.shared.canonicalizationResult(for: [incomplete, complete])
        XCTAssertEqual(result.canonical.count, 2)
        XCTAssertTrue(result.remappedIDs.isEmpty)
    }

    func testDifferentNativeAccountIDsNeverMergeEvenWhenPathMatches() {
        let first = credential(
            id: "account-a",
            path: "/tmp/shared/auth.json",
            metadata: ["accountId": "user-a"]
        )
        let second = credential(
            id: "account-b",
            path: "/tmp/shared/auth.json",
            metadata: ["accountId": "user-b"]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [first, second]).canonical.count,
            2
        )
    }

    func testWorkspaceAndPlanChangesDoNotSplitSameAccountAndUser() {
        let plus = credential(
            id: "plus",
            path: "/tmp/plus/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "personal",
                "accountPlan": "plus",
                "workspaceUserId": "member-456",
            ]
        )
        let business = credential(
            id: "business",
            path: "/tmp/business/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "team",
                "accountPlan": "business",
                "workspaceUserId": "member-456",
            ]
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(plus, business))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [plus, business]).canonical.count,
            1
        )
    }

    func testExplicitUserConflictKeepsAccountsSeparate() {
        let first = credential(
            id: "member-a",
            path: "/tmp/member-conflict/auth.json",
            metadata: [
                "accountId": "workspace-123",
                "workspaceType": "team",
                "workspaceUserId": "member-a",
            ]
        )
        let second = credential(
            id: "member-b",
            path: "/tmp/member-conflict/./auth.json",
            metadata: [
                "accountId": "workspace-123",
                "workspaceType": "team",
                "userId": "member-b",
            ]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
    }

    func testMissingNativeIdentityFallsBackToNormalizedAuthPath() {
        let first = credential(
            id: "legacy-a",
            path: "/tmp/aiusage-credential-dedup/../aiusage-credential-dedup/auth.json"
        )
        let second = credential(
            id: "legacy-b",
            path: "/tmp/aiusage-credential-dedup/auth.json"
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [first, second]).canonical.count,
            1
        )
    }

    func testNativeAndLegacyCopiesMergeOnlyWhenTheirAuthPathMatches() {
        let native = credential(
            id: "native",
            path: "/tmp/shared-copy/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "personal",
                "workspaceUserId": "member-456",
            ]
        )
        let sameLegacyPath = credential(
            id: "legacy-same",
            path: "/tmp/shared-copy/./auth.json"
        )
        let differentLegacyPath = credential(
            id: "legacy-other",
            path: "/tmp/other-copy/auth.json"
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(native, sameLegacyPath))
        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(native, differentLegacyPath))
    }

    func testIncompleteCopiesMergeWhenNormalizedAuthPathMatches() {
        let first = credential(
            id: "partial-a",
            path: "/tmp/partial-copy/auth.json",
            metadata: ["accountId": "user-123"]
        )
        let second = credential(
            id: "partial-b",
            path: "/tmp/partial-copy/./auth.json",
            metadata: ["accountId": "USER-123", "workspaceType": "personal"]
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [first, second]).canonical.count,
            1
        )
    }

    func testIncompleteCopiesIgnoreWorkspaceChangesOnSamePath() {
        let personal = credential(
            id: "partial-personal",
            path: "/tmp/partial-conflict/auth.json",
            metadata: ["accountId": "user-123", "workspaceType": "personal"]
        )
        let team = credential(
            id: "partial-team",
            path: "/tmp/partial-conflict/./auth.json",
            metadata: ["accountId": "user-123", "workspaceType": "team"]
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(personal, team))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [personal, team]).canonical.count,
            1
        )
    }

    func testIncompleteCopiesWithKnownUserConflictDoNotMergeOnSamePath() {
        let first = credential(
            id: "partial-user-a",
            path: "/tmp/partial-user-conflict/auth.json",
            metadata: ["workspaceUserId": "member-a"]
        )
        let second = credential(
            id: "partial-user-b",
            path: "/tmp/partial-user-conflict/./auth.json",
            metadata: ["userId": "member-b"]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [first, second]).canonical.count,
            2
        )
    }

    func testIncompleteRecordDoesNotJoinCompleteIdentityAcrossDifferentPath() {
        let plus = credential(
            id: "plus",
            path: "/tmp/plus/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "personal",
                "workspaceUserId": "member-456",
            ]
        )
        let incomplete = credential(
            id: "incomplete",
            path: "/tmp/incomplete/auth.json",
            metadata: ["accountId": "user-123"]
        )
        let team = credential(
            id: "team",
            path: "/tmp/team/auth.json",
            metadata: [
                "accountId": "user-123",
                "workspaceType": "team",
                "workspaceUserId": "member-456",
            ]
        )

        let result = AccountCredentialStore.shared.canonicalizationResult(
            for: [incomplete, team, plus]
        )

        XCTAssertEqual(result.canonical.count, 2)
        XCTAssertEqual(result.remappedIDs.count, 1)
    }

    func testAntigravityCanonicalIdentityKeyNormalizesProjectAndEmail() {
        let value = credential(
            id: "gravity-a",
            providerId: "antigravity",
            path: "/tmp/gravity-a/auth.json",
            metadata: [
                "projectId": " Project-Alpha ",
                "accountEmail": " USER@Example.com ",
            ]
        )

        XCTAssertEqual(
            AccountCredentialStore.canonicalIdentityKey(for: value),
            "antigravity:project:project-alpha:email:user@example.com"
        )
        XCTAssertTrue(AccountCredentialStore.isMultiWorkspace("antigravity"))
    }

    func testAntigravitySameProjectAndEmailMergeAcrossDifferentPaths() {
        let first = credential(
            id: "gravity-a",
            providerId: "antigravity",
            path: "/tmp/gravity-a/auth.json",
            metadata: ["projectId": "project-alpha", "accountEmail": "user@example.com"]
        )
        let second = credential(
            id: "gravity-b",
            providerId: "antigravity",
            path: "/tmp/gravity-b/auth.json",
            metadata: ["project_id": "PROJECT-ALPHA", "accountHandle": "USER@example.com"]
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [first, second]).canonical.count,
            1
        )
    }

    func testAntigravitySameEmailDifferentProjectsNeverMergeEvenOnSamePath() {
        let first = credential(
            id: "gravity-project-a",
            providerId: "antigravity",
            path: "/tmp/gravity-shared/auth.json",
            metadata: ["projectId": "project-alpha", "accountEmail": "user@example.com"]
        )
        let second = credential(
            id: "gravity-project-b",
            providerId: "antigravity",
            path: "/tmp/gravity-shared/./auth.json",
            metadata: ["projectId": "project-beta", "accountEmail": "user@example.com"]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [first, second]).canonical.count,
            2
        )
    }

    func testAntigravitySameProjectDifferentEmailsNeverMergeEvenOnSamePath() {
        let first = credential(
            id: "gravity-user-a",
            providerId: "antigravity",
            path: "/tmp/gravity-user-shared/auth.json",
            metadata: ["projectId": "project-alpha", "accountEmail": "a@example.com"]
        )
        let second = credential(
            id: "gravity-user-b",
            providerId: "antigravity",
            path: "/tmp/gravity-user-shared/./auth.json",
            metadata: ["projectId": "project-alpha", "accountEmail": "b@example.com"]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
    }

    func testAntigravityIncompleteIdentityDoesNotMergeAcrossDifferentPaths() {
        let projectOnly = credential(
            id: "gravity-project-only",
            providerId: "antigravity",
            path: "/tmp/gravity-project-only/auth.json",
            metadata: ["projectId": "project-alpha"]
        )
        let complete = credential(
            id: "gravity-complete",
            providerId: "antigravity",
            path: "/tmp/gravity-complete/auth.json",
            metadata: ["projectId": "project-alpha", "accountEmail": "user@example.com"]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(projectOnly, complete))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [projectOnly, complete]).canonical.count,
            2
        )
    }

    func testAntigravityIncompleteIdentityMergesOnSameNormalizedPath() {
        let emailOnly = credential(
            id: "gravity-email-only",
            providerId: "antigravity",
            path: "/tmp/gravity-incomplete/auth.json",
            metadata: ["accountEmail": "user@example.com"]
        )
        let projectAndEmail = credential(
            id: "gravity-complete",
            providerId: "antigravity",
            path: "/tmp/gravity-incomplete/./auth.json",
            metadata: ["projectId": "project-alpha", "accountEmail": "USER@example.com"]
        )

        XCTAssertTrue(AccountCredentialStore.credentialsShareCanonicalIdentity(emailOnly, projectAndEmail))
        XCTAssertEqual(
            AccountCredentialStore.shared.canonicalizationResult(for: [emailOnly, projectAndEmail]).canonical.count,
            1
        )
    }

    func testAntigravityIncompleteProjectConflictDoesNotMergeOnSamePath() {
        let first = credential(
            id: "gravity-incomplete-a",
            providerId: "antigravity",
            path: "/tmp/gravity-incomplete-conflict/auth.json",
            metadata: ["projectId": "project-alpha"]
        )
        let second = credential(
            id: "gravity-incomplete-b",
            providerId: "antigravity",
            path: "/tmp/gravity-incomplete-conflict/./auth.json",
            metadata: ["projectId": "project-beta"]
        )

        XCTAssertFalse(AccountCredentialStore.credentialsShareCanonicalIdentity(first, second))
    }

    func testStagedDeduplicationPlanComputesRemapWithoutMutatingCredentials() {
        let first = credential(
            id: "codex-copy-a",
            path: "/tmp/staged-a/auth.json",
            metadata: ["accountId": "account-123", "workspaceUserId": "user-456"]
        )
        let second = credential(
            id: "codex-copy-b",
            path: "/tmp/staged-b/auth.json",
            metadata: ["accountId": "ACCOUNT-123", "userId": "USER-456"]
        )

        let plan = AccountCredentialStore.shared.makeCredentialDeduplicationPlan(
            for: [first, second],
            providerId: "codex"
        )

        XCTAssertEqual(plan.providerId, "codex")
        XCTAssertEqual(plan.remappedCredentialIDs.count, 1)
        XCTAssertEqual(Set(plan.remappedCredentialIDs.keys).count, 1)
        XCTAssertEqual(Set(plan.remappedCredentialIDs.values).count, 1)
        XCTAssertTrue(
            AccountCredentialStore.shared.credentialDeduplicationPlan(
                plan,
                isValidFor: [first, second]
            )
        )
    }

    func testStagedDeduplicationPlanRejectsChangedCanonicalization() {
        let first = credential(
            id: "codex-copy-a",
            path: "/tmp/stale-a/auth.json",
            metadata: ["accountId": "account-123", "workspaceUserId": "user-456"]
        )
        let second = credential(
            id: "codex-copy-b",
            path: "/tmp/stale-b/auth.json",
            metadata: ["accountId": "account-123", "workspaceUserId": "user-456"]
        )
        let plan = AccountCredentialStore.shared.makeCredentialDeduplicationPlan(
            for: [first, second],
            providerId: "codex"
        )
        let changedSecond = credential(
            id: "codex-copy-b",
            path: "/tmp/stale-b/auth.json",
            metadata: ["accountId": "account-123", "workspaceUserId": "different-user"]
        )

        XCTAssertFalse(
            AccountCredentialStore.shared.credentialDeduplicationPlan(
                plan,
                isValidFor: [first, changedSecond]
            )
        )
    }

    func testDeleteCredentialPreservesCacheAndStorageWhenWriteFails() throws {
        var persistedData: Data?
        var shouldFailWrite = false
        let makeStore: () -> AccountCredentialStore = {
            AccountCredentialStore(
                readVaultData: { persistedData },
                writeVaultData: { data in
                    if shouldFailWrite {
                        throw CredentialStoreError.keychainWriteFailed(-25291)
                    }
                    persistedData = data
                }
            )
        }

        let store = makeStore()
        let credA = credential(
            id: "codex-a",
            providerId: "codex",
            path: "/tmp/codex-a/auth.json",
            metadata: ["accountId": "acct-a", "workspaceUserId": "user-a"]
        )
        let credB = credential(
            id: "gravity-b",
            providerId: "antigravity",
            path: "/tmp/gravity-b/auth.json",
            metadata: ["projectId": "proj-b", "accountEmail": "b@example.com"]
        )

        try store.saveCredential(credA)
        try store.saveCredential(credB)

        shouldFailWrite = true
        XCTAssertThrowsError(try store.deleteCredential(credA))
        XCTAssertNotNil(store.loadCredential(providerId: "codex", credentialId: "codex-a"))
        XCTAssertEqual(store.loadAllCredentials().map(\.id), ["gravity-b", "codex-a"])

        let reloadedAfterFailure = makeStore()
        XCTAssertNotNil(reloadedAfterFailure.loadCredential(providerId: "codex", credentialId: "codex-a"))
        XCTAssertNotNil(reloadedAfterFailure.loadCredential(providerId: "antigravity", credentialId: "gravity-b"))

        shouldFailWrite = false
        try store.deleteCredential(credA)
        XCTAssertNil(store.loadCredential(providerId: "codex", credentialId: "codex-a"))
        XCTAssertNotNil(store.loadCredential(providerId: "antigravity", credentialId: "gravity-b"))

        let reloadedAfterSuccess = makeStore()
        XCTAssertNil(reloadedAfterSuccess.loadCredential(providerId: "codex", credentialId: "codex-a"))
        XCTAssertNotNil(reloadedAfterSuccess.loadCredential(providerId: "antigravity", credentialId: "gravity-b"))
    }

    func testDeleteCredentialsForProviderPreservesCacheOnFailureAndIsolatesProviders() throws {
        var persistedData: Data?
        var shouldFailWrite = false
        let makeStore: () -> AccountCredentialStore = {
            AccountCredentialStore(
                readVaultData: { persistedData },
                writeVaultData: { data in
                    if shouldFailWrite {
                        throw CredentialStoreError.keychainWriteFailed(-25291)
                    }
                    persistedData = data
                }
            )
        }

        let store = makeStore()
        let codex1 = credential(
            id: "codex-1",
            providerId: "codex",
            path: "/tmp/codex-1/auth.json",
            metadata: ["accountId": "acct-1", "workspaceUserId": "user-1"]
        )
        let codex2 = credential(
            id: "codex-2",
            providerId: "codex",
            path: "/tmp/codex-2/auth.json",
            metadata: ["accountId": "acct-2", "workspaceUserId": "user-2"]
        )
        let agy = credential(
            id: "gravity-1",
            providerId: "antigravity",
            path: "/tmp/gravity-1/auth.json",
            metadata: ["projectId": "proj-1", "accountEmail": "agy@example.com"]
        )

        try store.saveCredential(codex1)
        try store.saveCredential(codex2)
        try store.saveCredential(agy)

        shouldFailWrite = true
        XCTAssertThrowsError(try store.deleteCredentials([codex1, codex2]))
        XCTAssertEqual(store.loadCredentials(for: "codex").count, 2)
        XCTAssertEqual(makeStore().loadCredentials(for: "codex").count, 2)

        XCTAssertThrowsError(try store.deleteCredentials(for: "CODEX"))
        XCTAssertEqual(store.loadCredentials(for: "codex").count, 2)
        XCTAssertEqual(store.loadCredentials(for: "antigravity").count, 1)

        shouldFailWrite = false
        try store.deleteCredentials([codex1, codex2])
        XCTAssertTrue(store.loadCredentials(for: "codex").isEmpty)
        try store.saveCredential(codex1)
        try store.deleteCredentials(for: "CODEX")
        XCTAssertTrue(store.loadCredentials(for: "codex").isEmpty)
        XCTAssertEqual(store.loadCredentials(for: "antigravity").map(\.id), ["gravity-1"])

        let reloaded = makeStore()
        XCTAssertTrue(reloaded.loadCredentials(for: "codex").isEmpty)
        XCTAssertEqual(reloaded.loadCredentials(for: "antigravity").map(\.id), ["gravity-1"])
    }
}
