import Foundation
import Network
import SQLite3
import QuotaBackend

@main
struct AccountIdentityRegression {
    static var assertions = 0

    static func check(_ condition: @autoclosure () -> Bool, _ message: String, line: UInt = #line) {
        assertions += 1
        guard condition() else { fatalError("\(message) (line \(line))") }
    }

    static func credential(_ id: String, workspace: String = "business-1", user: String = "member-a", email: String = "a@example.invalid", path: String? = nil) -> AccountCredential {
        AccountCredential(id: id, providerId: "codex", accountLabel: email, authMethod: .authFile,
                          credential: path ?? "/tmp/identity-fixtures/\(id)/auth.json", metadata: [
                            "accountId": workspace, "workspaceUserId": user, "accountEmail": email,
                            "sourcePath": "/tmp/shared-codex/auth.json", "accountPlan": "business"
                          ])
    }

    static func live(_ credential: AccountCredential, failed: Bool = false) throws -> ProviderData {
        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.usageAccountId = credential.metadata["accountId"]
        usage.accountEmail = credential.metadata["accountEmail"]
        usage.accountPlan = "Business"
        usage.extra["userId"] = AnyCodable(credential.metadata["workspaceUserId"] ?? "")
        var summary = UsageNormalizer.normalize(provider: CodexProvider(), usage: usage)
        summary.id = "codex:cred:\(credential.id)"
        summary.sourceFilePath = credential.credential
        if failed { summary.status = "error"; summary.errorCode = "refresh_token_expired" }
        return try JSONDecoder().decode(ProviderData.self, from: JSONEncoder().encode(summary))
    }

    static func entry(_ provider: ProviderData, store: AccountStore) -> ProviderAccountEntry {
        ProviderAccountEntry(id: provider.id, providerId: "codex", providerTitle: "Codex", providerSubtitle: nil,
                             liveProvider: provider, storedAccount: store.accountRegistry.first {
            AccountIdentityPolicy.matchesLive(stored: $0, provider: provider)
        })
    }

    @MainActor static func main() async throws {
        let store = AccountStore.shared
        let fingerprintA = ProviderAuthManager.codexSessionFingerprint(from: ["account_id": "business-1", "chatgpt_user_id": "a", "email": "same@example.invalid"])!
        let fingerprintB = ProviderAuthManager.codexSessionFingerprint(from: ["account_id": "business-1", "chatgpt_user_id": "b", "email": "same@example.invalid"])!
        let fingerprintC = ProviderAuthManager.codexSessionFingerprint(from: ["account_id": "business-2", "chatgpt_user_id": "a", "email": "same@example.invalid"])!
        check(Set([fingerprintA, fingerprintB, fingerprintC]).count == 3, "自动发现指纹区分用户及空间")
        let monitored = ProviderMonitoredSessionIndex(sourceIdentifiers: ["shared-path"], sessionFingerprints: [fingerprintA], accountHandles: ["same@example.invalid"])
        func candidate(_ fingerprint: String) -> ProviderAuthCandidate {
            ProviderAuthCandidate(id: "test", providerId: "codex", sourceIdentifier: "shared-path", sessionFingerprint: fingerprint,
                title: "same@example.invalid", subtitle: nil, detail: "", modifiedAt: nil, authMethod: .authFile,
                credentialValue: "/tmp/auth.json", sourcePath: "/tmp/auth.json", shouldCopyFile: true, identityScope: .sharedSource)
        }
        check(ProviderAuthManager.isCandidateManaged(candidate(fingerprintA), monitored: monitored), "自动发现跳过已监控的同一身份")
        check(!ProviderAuthManager.isCandidateManaged(candidate(fingerprintB), monitored: monitored), "相同邮箱和路径不能抑制新成员")
        check(!ProviderAuthManager.isCandidateManaged(candidate(fingerprintC), monitored: monitored), "相同邮箱和路径不能抑制新空间")
        check(!ProviderAuthManager.isCandidateManaged(candidate("business-1"), monitored: monitored), "旧版空间指纹不得视为完整身份")
        let a = credential("a")
        let b = credential("b", user: "member-b", email: "b@example.invalid")
        let c = credential("c", workspace: "business-2")
        let p = credential("personal", workspace: "personal-a")
        for value in [a, b, c, p] {
            try AccountCredentialStore.shared.saveCredential(value)
            check(store.saveAccount(providerId: "codex", email: value.accountLabel!, displayName: "同名空间",
                                    accountId: value.metadata["accountId"], credentialId: value.id,
                                    ensureProviderSelected: { _ in }), "保存成功")
        }
        check(store.accountRegistry.count == 4, "同空间成员/同邮箱多空间必须各自保存")
        check(Set(store.accountRegistry.compactMap(\.credentialId)).count == 4, "凭据不能被替换")
        let liveA = try live(a), liveB = try live(b), liveC = try live(c), liveP = try live(p)
        check(liveA.workspaceUserId == "member-a", "用户 ID 必须跨服务 JSON 传到 UI")
        check(Set([liveA, liveB, liveC, liveP].map(AccountIdentityPolicy.liveIdentityKey(for:))).count == 4, "UI 分组必须独立")
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(liveA, liveB), "单卡刷新不可匹配其他成员")
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(liveA, liveC), "单卡刷新不可按邮箱跨空间匹配")
        for order in [[liveA, liveB, liveC, liveP], [liveP, liveC, liveB, liveA]] {
            await store.reconcileAccountRegistry(with: order)
            check(store.accountRegistry.count == 4, "刷新顺序不可影响账号数量")
            for provider in order {
                check(store.accountRegistry.filter { AccountIdentityPolicy.matchesLive(stored: $0, provider: provider) }.count == 1, "每条 live 只匹配一条存储")
            }
        }
        let failedA = try live(a, failed: true)
        await store.reconcileAccountRegistry(with: [failedA, liveB, liveC, liveP])
        check(store.accountRegistry.count == 4, "某成员失败不丢失账号")
        check(store.matchingCredentials(for: entry(liveA, store: store)).map(\.id) == ["a"], "凭据查找只命中当前成员")
        check(store.matchingStoredAccountIndices(for: entry(liveA, store: store)).count == 1, "隐藏删除只能选中当前成员")

        store.hideAccount(entry(liveA, store: store), onPostRegistryChange: {})
        check(store.hiddenAccounts().count == 1, "只隐藏指定成员")
        check(!store.hasHiddenRegistryMatch(providerId: "codex", normalizedEmail: b.accountLabel,
                                            normalizedAccountId: "business-1", sourceFilePath: b.credential,
                                            workspaceUserId: "member-b"), "隐藏 A 不抑制 B")
        await store.reconcileAccountRegistry(with: [liveA, liveB, liveC, liveP])
        check(store.hiddenAccounts().count == 1, "自动刷新不可取消隐藏")
        let hidden = store.hiddenAccounts()[0]
        check(hidden.workspaceUserId == "member-a", "隐藏记录保留成员身份")
        store.restoreAccount(hidden.id, onRestored: { _ in })
        check(store.hiddenAccounts().isEmpty, "恢复指定成员")

        store.deleteAccount(entry(liveA, store: store), onPostRegistryDelete: {})
        check(AccountCredentialStore.shared.loadCredentials(for: "codex").map(\.id).sorted() == ["b", "c", "personal"], "删除 A 不可删除 B/C")
        check(store.accountRegistry.filter(\.isPermanentlyRemoved).count == 1, "仅 A 留下删除记录")
        check(store.accountRegistry.filter { !$0.isHidden }.count == 3, "其他三个账号继续监控")
        await store.reconcileAccountRegistry(with: [liveA, liveB, liveC, liveP])
        check(store.accountRegistry.filter { !$0.isHidden }.count == 3, "删除前发出的旧请求不能复活 A")
        try AccountCredentialStore.shared.saveCredential(a)
        check(store.saveAccount(providerId: "codex", email: a.accountLabel!, displayName: nil, accountId: "business-1",
                                credentialId: "a", ensureProviderSelected: { _ in }), "重新添加 A")
        check(store.accountRegistry.count == 4 && !store.accountRegistry.contains(where: \.isHidden), "重新添加只复活 A、不重复")

        let onlyA = store.accountRegistry.filter { $0.credentialId == "a" }
        let lookup = Dictionary(uniqueKeysWithValues: [a, b, c].map { ($0.id, $0) })
        check(AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: a), sourcePath: a.credential,
                registry: onlyA, credentialLookup: lookup, respectRemoval: false), "CPA 相同账号重复添加应跳过")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: b), sourcePath: a.credential,
                registry: onlyA, credentialLookup: lookup, respectRemoval: false), "CPA 同空间其他成员不能被已存在判定挡住")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: c), sourcePath: a.credential,
                registry: onlyA, credentialLookup: lookup, respectRemoval: false), "CPA 同邮箱其他空间不能被挡住")
        var removedA = onlyA[0]
        removedA.isHidden = true
        removedA.isPermanentlyRemoved = true
        check(AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: a), sourcePath: a.credential,
                registry: [removedA], credentialLookup: lookup, respectRemoval: true), "自动补回尊重 A 的删除记录")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: b), sourcePath: a.credential,
                registry: [removedA], credentialLookup: lookup, respectRemoval: true), "A 的删除记录不能阻挡 B 的补回")
        check(!AccountIdentityPolicy.codexSubscriptionAlreadyContains(identity: CodexAccountIdentity(credential: a), sourcePath: a.credential,
                registry: [removedA], credentialLookup: lookup, respectRemoval: false), "显式添加允许复活 A")

        let sharedA = credential("path-a", path: "/tmp/same/auth.json")
        let sharedB = credential("path-b", user: "member-b", email: "b@example.invalid", path: "/tmp/same/auth.json")
        let sharedC = credential("path-c", workspace: "business-2", path: "/tmp/same/auth.json")
        let sharedLiveA = try live(sharedA), sharedLiveB = try live(sharedB), sharedLiveC = try live(sharedC)
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(sharedLiveA, sharedLiveB), "共享路径不能覆盖用户冲突")
        check(!AccountIdentityPolicy.codexLiveAccountsMatch(sharedLiveA, sharedLiveC), "共享路径不能覆盖工作区冲突")

        let encoded = try JSONEncoder().encode(store.accountRegistry)
        let restored = try JSONDecoder().decode([StoredProviderAccount].self, from: encoded)
        check(restored == store.accountRegistry, "持久化往返保留所有身份字段")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [[String: Any]]
        for index in legacy.indices { legacy[index].removeValue(forKey: "workspaceUserId") }
        store.accountRegistry = try JSONDecoder().decode([StoredProviderAccount].self, from: JSONSerialization.data(withJSONObject: legacy))
        _ = store.normalizeAccountRegistryAgainstCredentials()
        check(store.accountRegistry.count == 4 && store.accountRegistry.allSatisfy { $0.workspaceUserId != nil }, "旧数据从对应凭据补全身份")
        await store.reconcileAccountRegistry(with: [liveA, liveB, liveC, liveP])
        check(store.accountRegistry.count == 4, "旧数据升级后不合并、不重复")

        var usage = ProviderUsage(provider: "codex", label: "Codex")
        usage.usageAccountId = "business-1"
        usage.accountEmail = "a@example.invalid"
        usage.accountPlan = "Pro"
        usage.extra["userId"] = AnyCodable("member-a")
        try store.registerAuthenticatedCredential(credential("a-new"), usage: usage, note: nil, providerDisplayTitle: "Codex",
            insertImmediateProviderData: { _, _, _, _ in }, ensureProviderSelected: { _ in })
        check(store.accountRegistry.count == 4, "重复登录/套餐变化不创建重复账号")
        check(AccountCredentialStore.shared.credentials.count == 4, "同身份重新登录复用原凭据")
        check(store.accountRegistry.contains { $0.credentialId == "b" && $0.email == "b@example.invalid" }, "A 重新登录不能修改 B")
        let legacyIndex = store.accountRegistry.firstIndex { $0.credentialId == "b" }!
        store.accountRegistry[legacyIndex].accountId = "member-b"
        store.accountRegistry[legacyIndex].workspaceUserId = "old-subject-b"
        await store.reconcileAccountRegistry(with: [liveB])
        check(store.accountRegistry.count == 4, "旧版错误字段更新不能产生重复卡片")
        check(store.accountRegistry[legacyIndex].accountId == "business-1"
              && store.accountRegistry[legacyIndex].workspaceUserId == "member-b", "用已验证凭据修复旧注册表身份")
        var didCallPostDeleteOnFailure = false
        AccountCredentialStore.shared.shouldFailDelete = true
        store.deleteAccount(entry(liveB, store: store), onPostRegistryDelete: { didCallPostDeleteOnFailure = true })
        AccountCredentialStore.shared.shouldFailDelete = false
        check(!didCallPostDeleteOnFailure, "凭据删除失败时不触发删除成功回调")
        check(AccountCredentialStore.shared.credentials.contains(where: { $0.id == "b" }), "凭据删除失败时保留存储凭据")
        check(store.accountRegistry.contains(where: { $0.credentialId == "b" && !$0.isHidden }), "凭据删除失败时保留注册表账号")

        // R1: 批量删除部分失败时，回调与返回值仅包含真正删除成功的账号（C），保留失败账号（B）且不清理托管文件。
        ProviderManagedImportStore.cleanupInvocations = 0
        AccountCredentialStore.shared.failedDeleteIDs = ["b"]
        var callbackDeletedIDs: [String] = []
        let returnedDeleted = store.deleteAccounts([entry(liveB, store: store), entry(liveC, store: store)]) { deletedEntries in
            callbackDeletedIDs = deletedEntries.map(\.id)
        }
        AccountCredentialStore.shared.failedDeleteIDs = []
        check(callbackDeletedIDs == [liveC.id] && returnedDeleted.map(\.id) == [liveC.id],
              "R1: 批量删除部分成功时仅向回调和返回值传递成功删除的账号 C")
        check(store.accountRegistry.contains(where: { $0.credentialId == "b" && !$0.isHidden }),
              "R1: 批量删除中失败的账号 B 仍在可见注册表中")
        check(AccountCredentialStore.shared.credentials.contains(where: { $0.id == "b" }),
              "R1: 批量删除中失败的凭据 B 仍保留在存储中")
        check(!AccountCredentialStore.shared.credentials.contains(where: { $0.id == "c" }),
              "R1: 批量删除中成功的凭据 C 已被移除")
        check(ProviderManagedImportStore.cleanupInvocations == 0,
              "R1: 存在未删除成功的凭据时不触发托管导入清理")

        let remainingDeleted = store.deleteAccounts([entry(liveB, store: store)]) { deletedEntries in
            callbackDeletedIDs = deletedEntries.map(\.id)
        }
        check(callbackDeletedIDs == [liveB.id] && remainingDeleted.map(\.id) == [liveB.id],
              "R1: 重试删除 B 成功后回调仅传递 B")
        check(ProviderManagedImportStore.cleanupInvocations == 1,
              "R1: 全部请求凭据删除成功后正常清理托管导入")
        check(Set(store.accountRegistry.filter { !$0.isHidden }.compactMap(\.credentialId)) == ["a", "personal"], "批量删除仅移除选中的成员与空间")
        check(Set(AccountCredentialStore.shared.credentials.map(\.id)) == ["a", "personal"], "批量删除保留未选中凭据")

        // R4: 单个账号关联多条凭据时，即使底层持久化在删除失败后也无法写入（persistent write failure），单次原子批量删除也不会丢失第一条凭据。
        let aDuplicate = credential("a-dup")
        try AccountCredentialStore.shared.saveCredential(aDuplicate)
        let entryA = entry(liveA, store: store)
        check(store.matchingCredentials(for: entryA).map(\.id).sorted() == ["a", "a-dup"],
              "R4: 账号 A 同时匹配两条凭据（a 与 a-dup）")
        AccountCredentialStore.shared.failedDeleteIDs = ["a-dup"]
        AccountCredentialStore.shared.failSavesAfterDeleteFailure = true
        var didCallR4Callback = false
        let r4FailedDeleted = store.deleteAccounts([entryA]) { _ in
            didCallR4Callback = true
        }
        check(r4FailedDeleted.isEmpty && !didCallR4Callback,
              "R4: 多凭据账号在持久化写入失败时整体报未删除且不触发回调")
        check(AccountCredentialStore.shared.credentials.filter { ["a", "a-dup"].contains($0.id) }.map(\.id).sorted() == ["a", "a-dup"],
              "R4: 持久化持续失败时不会因部分删除而丢失第一条凭据 a")
        check(store.accountRegistry.contains(where: { $0.credentialId == "a" && !$0.isHidden }),
              "R4: 失败后账号 A 仍保持可见")
        AccountCredentialStore.shared.failedDeleteIDs = []
        AccountCredentialStore.shared.failSavesAfterDeleteFailure = false
        AccountCredentialStore.shared.writeFailureActive = false
        try AccountCredentialStore.shared.deleteCredentials([aDuplicate])
        check(Set(AccountCredentialStore.shared.credentials.map(\.id)) == ["a", "personal"],
              "R4: 恢复写入后可单次清理测试副本凭据")

        // 相同邮箱的残缺历史数据不能通过兜底分支抢占另一个明确的成员。
        var oldA = onlyA[0]
        oldA.credentialId = nil
        oldA.workspaceUserId = nil
        let sameEmailB = StoredProviderAccount(id: "same-email-b", providerId: "codex", email: oldA.email,
            displayName: nil, note: nil, accountId: "business-1", providerResultId: "codex:saved-member-b",
            credentialId: nil, createdAt: oldA.createdAt, lastSeenAt: nil,
            sourceFilePath: "/tmp/legacy-b/auth.json", workspaceUserId: "member-b")
        var memberB = credential("ambiguous-b", user: "member-b")
        memberB.metadata["accountEmail"] = oldA.email
        let memberBLive = try live(memberB)
        check(AccountIdentityPolicy.bestStoredAccountIndex(in: [oldA, sameEmailB], for: memberBLive,
                excluding: [], allowUnseenCredentialFallback: false) == 1, "完整原生身份优先于旧邮箱关联，卡片顺序不影响归属")
        check(AccountIdentityPolicy.bestStoredAccountIndex(in: [oldA, sameEmailB], for: memberBLive,
                excluding: [sameEmailB.id], allowUnseenCredentialFallback: false) == nil, "已消费的精确身份不能退到其他历史记录")
        var incompleteJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(memberBLive)) as! [String: Any]
        incompleteJSON.removeValue(forKey: "workspaceUserId")
        incompleteJSON["id"] = "codex:legacy-ambiguous"
        incompleteJSON["sourceFilePath"] = "/tmp/ambiguous/auth.json"
        let incompleteLive = try JSONDecoder().decode(ProviderData.self, from: JSONSerialization.data(withJSONObject: incompleteJSON))
        let completeA = onlyA[0]
        store.accountRegistry = [completeA, sameEmailB]
        check(AccountIdentityPolicy.bestStoredAccountIndex(in: store.accountRegistry, for: incompleteLive,
                excluding: [], allowUnseenCredentialFallback: false) == nil, "残缺结果存在多个候选时不猜测归属")
        await store.reconcileAccountRegistry(with: [incompleteLive])
        check(store.accountRegistry[0] == completeA && store.accountRegistry[1] == sameEmailB, "协调兜底不能绕过歧义检查覆盖任何成员")

        // Claude 的名称不是身份；相同名称的两个目录必须分别登记。
        var claudeLive: [ProviderData] = []
        for suffix in ["personal", "work"] {
            let profile = ClaudeSubscriptionProfile(configDirectory: "/tmp/claude-identity-fixture/\(suffix)", name: "同名配置")
            let reference = AccountCredential(providerId: "claude-subscription", accountLabel: profile.name,
                authMethod: .auto, credential: profile.configDirectory,
                metadata: ["sourceKind": "claude-cli-profile", "accountId": profile.id])
            var usage = ProviderUsage(provider: "claude-subscription", label: "Claude", accountId: profile.id)
            usage.accountName = profile.name
            usage.extra["profileDirectory"] = AnyCodable(profile.configDirectory)
            usage.extra["snapshotState"] = AnyCodable("waiting")
            try store.registerAuthenticatedCredential(reference, usage: usage, note: nil, providerDisplayTitle: "Claude",
                insertImmediateProviderData: { _, id, _, usage in
                    var summary = UsageNormalizer.normalize(provider: ClaudeSubscriptionProvider(), usage: usage)
                    summary.id = "claude-subscription:cred:\(id)"
                    if let value = try? JSONDecoder().decode(ProviderData.self, from: JSONEncoder().encode(summary)) { claudeLive.append(value) }
                }, ensureProviderSelected: { _ in })
        }
        check(store.accountRegistry.filter { $0.providerId == "claude-subscription" }.count == 2, "Claude 同名目录不合并")
        check(AccountCredentialStore.shared.loadCredentials(for: "claude-subscription").count == 2, "Claude 两个目录引用不替换")
        check(Set(claudeLive.map(AccountIdentityPolicy.liveIdentityKey(for:))).count == 2, "Claude 刷新结果独立归属")
        await store.reconcileAccountRegistry(with: claudeLive)
        check(store.accountRegistry.filter { $0.providerId == "claude-subscription" }.count == 2, "Claude 协调后无重复或合并")
        check(store.accountRegistry.filter { $0.providerId == "claude-subscription" }.allSatisfy { $0.sourceFilePath != nil }, "Claude 保存配置目录引用")
        check(claudeLive.allSatisfy { $0.remainingPercent == nil && $0.membershipLabel == nil }, "Claude 待样本不显示假额度或套餐")

        // FIX-02: Verify production QuotaBackend.AccountCredentialStore fault injection on delete.
        try testProductionCredentialStoreFaultInjection()

        // FIX-03 & FIX-04: Verify AntigravityLoginCoordinator PKCE S256, callback hardening, and session isolation.
        try await testAntigravityOAuthPKCEAndCallbackHardening()

        // AGY Switcher: Verify state.vscdb protobuf/JSON account switching, field preservation, snapshot recovery, and restart lifecycle.
        await testAntigravityAccountSwitcher()

        print("PASS: \(assertions) account identity & OAuth assertions (production save/reconcile/hide/delete/OAuth, isolated storage)")
    }

    static func testProductionCredentialStoreFaultInjection() throws {
        var persistedVaultData: Data?
        var shouldFailWrite = false
        let makeVaultStore: () -> QuotaBackend.AccountCredentialStore = {
            QuotaBackend.AccountCredentialStore(
                readVaultData: { persistedVaultData },
                writeVaultData: { data in
                    if shouldFailWrite {
                        throw CredentialStoreError.keychainWriteFailed(-25291)
                    }
                    persistedVaultData = data
                }
            )
        }

        let vaultStore = makeVaultStore()
        let codex1 = AccountCredential(
            id: "vault-codex-1",
            providerId: "codex",
            accountLabel: "c1@example.com",
            authMethod: .authFile,
            credential: "/tmp/vault-c1/auth.json",
            metadata: ["accountId": "acct-1", "workspaceUserId": "user-1"]
        )
        let codex2 = AccountCredential(
            id: "vault-codex-2",
            providerId: "codex",
            accountLabel: "c2@example.com",
            authMethod: .authFile,
            credential: "/tmp/vault-c2/auth.json",
            metadata: ["accountId": "acct-2", "workspaceUserId": "user-2"]
        )
        let agy1 = AccountCredential(
            id: "vault-agy-1",
            providerId: "antigravity",
            accountLabel: "agy1@example.com",
            authMethod: .authFile,
            credential: "/tmp/vault-agy1/auth.json",
            metadata: ["projectId": "proj-1", "accountEmail": "agy1@example.com"]
        )
        try vaultStore.saveCredential(codex1)
        try vaultStore.saveCredential(codex2)
        try vaultStore.saveCredential(agy1)

        shouldFailWrite = true
        var didThrowSingle = false
        do {
            try vaultStore.deleteCredential(codex1)
        } catch {
            didThrowSingle = true
        }
        check(didThrowSingle, "FIX-02: deleteCredential throws when vault persistence fails")
        check(vaultStore.loadCredential(providerId: "codex", credentialId: "vault-codex-1") != nil,
              "FIX-02: in-memory cache retains credential when single delete write fails")
        check(makeVaultStore().loadCredential(providerId: "codex", credentialId: "vault-codex-1") != nil,
              "FIX-02: persistent storage retains credential when single delete write fails")

        var didThrowBatch = false
        do {
            try vaultStore.deleteCredentials([codex1, codex2])
        } catch {
            didThrowBatch = true
        }
        check(didThrowBatch, "R4: deleteCredentials([codex1, codex2]) throws when vault persistence fails")
        check(vaultStore.loadCredentials(for: "codex").map(\.id).sorted() == ["vault-codex-1", "vault-codex-2"],
              "R4: in-memory cache retains all batch credentials when single-write batch delete fails")
        check(makeVaultStore().loadCredentials(for: "codex").map(\.id).sorted() == ["vault-codex-1", "vault-codex-2"],
              "R4: persistent storage retains all batch credentials when single-write batch delete fails")

        var didThrowProvider = false
        do {
            try vaultStore.deleteCredentials(for: "CODEX")
        } catch {
            didThrowProvider = true
        }
        check(didThrowProvider, "FIX-02: deleteCredentials(for:) throws when vault persistence fails")
        check(vaultStore.loadCredentials(for: "codex").count == 2,
              "FIX-02: in-memory cache retains provider credentials when provider delete write fails")
        check(vaultStore.loadCredentials(for: "antigravity").count == 1,
              "FIX-02: other provider credentials remain untouched on failed provider delete")

        shouldFailWrite = false
        try vaultStore.deleteCredentials([codex1, codex2])
        check(vaultStore.loadCredentials(for: "codex").isEmpty,
              "R4: deleteCredentials([codex1, codex2]) removes all batch credentials in one write")
        try vaultStore.saveCredential(codex1)
        try vaultStore.deleteCredentials(for: "CODEX")
        check(vaultStore.loadCredentials(for: "codex").isEmpty,
              "FIX-02: deleteCredentials(for:) removes target provider after successful write")
        check(vaultStore.loadCredentials(for: "antigravity").map(\.id) == ["vault-agy-1"],
              "FIX-02: deleteCredentials(for:) preserves other providers")
        let reloaded = makeVaultStore()
        check(reloaded.loadCredentials(for: "codex").isEmpty && reloaded.loadCredentials(for: "antigravity").map(\.id) == ["vault-agy-1"],
              "FIX-02: reloaded store matches persisted deletion")
    }

    @MainActor
    static func testAntigravityOAuthPKCEAndCallbackHardening() async throws {
        // RFC 7636 Appendix B known-answer vector
        let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let rfcChallenge = AntigravityLoginCoordinator.pkceCodeChallenge(for: rfcVerifier)
        check(rfcChallenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
              "FIX-03: RFC 7636 S256 known-answer vector matches")

        let expectedRedirect = URL(string: "http://127.0.0.1:54321/oauth2callback")!
        let authURL = AntigravityLoginCoordinator.makeAuthURL(
            clientId: "client-id-1",
            redirectURL: expectedRedirect,
            stateToken: "state-123",
            codeChallenge: rfcChallenge
        )!
        let authItems = URLComponents(url: authURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(AntigravityLoginCoordinator.queryParameter("code_challenge", in: authItems) == .single(rfcChallenge),
              "FIX-03: authorization URL includes code_challenge")
        check(AntigravityLoginCoordinator.queryParameter("code_challenge_method", in: authItems) == .single("S256"),
              "FIX-03: authorization URL includes code_challenge_method=S256")
        check(AntigravityLoginCoordinator.queryParameter("state", in: authItems) == .single("state-123"),
              "FIX-03: authorization URL preserves state")

        let tokenReq = AntigravityLoginCoordinator.makeTokenRequest(
            clientId: "client-id-1",
            clientSecret: "secret-1",
            code: "auth-code-xyz",
            redirectURL: expectedRedirect,
            codeVerifier: rfcVerifier
        )
        let bodyString = String(data: tokenReq.httpBody ?? Data(), encoding: .utf8) ?? ""
        let bodyItems = URLComponents(string: "http://127.0.0.1?\(bodyString)")?.queryItems ?? []
        check(AntigravityLoginCoordinator.queryParameter("code_verifier", in: bodyItems) == .single(rfcVerifier),
              "FIX-03: token exchange POST body includes code_verifier")
        check(AntigravityLoginCoordinator.queryParameter("client_secret", in: bodyItems) == .single("secret-1"),
              "FIX-03: token exchange POST body preserves client_secret")

        // FIX-04: Origin-form GET with matching Host/port succeeds
        let validOriginGET = "GET /oauth2callback?code=CODE1&state=STATE1 HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        let parsedValid = AntigravityLoginCoordinator.parseCallbackRequest(validOriginGET, expectedRedirectURL: expectedRedirect)
        check(parsedValid != nil && AntigravityLoginCoordinator.isSuccessfulCallbackURL(parsedValid!, expectedRedirectURL: expectedRedirect),
              "FIX-04: valid origin-form GET with Host port is accepted")

        // FIX-04: Substring host, substring path, wrong method, wrong port are rejected
        let badHost = "GET http://localhost.example.invalid:54321/oauth2callback?code=1&state=2 HTTP/1.1\r\nHost: localhost.example.invalid:54321\r\n\r\n"
        check(AntigravityLoginCoordinator.parseCallbackRequest(badHost, expectedRedirectURL: expectedRedirect) == nil,
              "FIX-04: substring host is rejected")
        let badPath = "GET /prefix/oauth2callback?code=1&state=2 HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        check(AntigravityLoginCoordinator.parseCallbackRequest(badPath, expectedRedirectURL: expectedRedirect) == nil,
              "FIX-04: non-exact callback path is rejected")
        let badMethod = "POST /oauth2callback?code=1&state=2 HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        check(AntigravityLoginCoordinator.parseCallbackRequest(badMethod, expectedRedirectURL: expectedRedirect) == nil,
              "FIX-04: non-GET method is rejected")
        let badPort = "GET /oauth2callback?code=1&state=2 HTTP/1.1\r\nHost: 127.0.0.1:9999\r\n\r\n"
        check(AntigravityLoginCoordinator.parseCallbackRequest(badPort, expectedRedirectURL: expectedRedirect) == nil,
              "FIX-04: mismatched Host port is rejected")

        // FIX-03 & FIX-04: Session lifecycle, state-first error handling, and single-flight token exchange
        final class VerifierRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var values: [String] = []
            func append(_ value: String) {
                lock.lock()
                defer { lock.unlock() }
                values.append(value)
            }
        }
        let capturedTokenVerifiers = VerifierRecorder()
        let coordinator = AntigravityLoginCoordinator(
            dataLoader: { request in
                if request.url == AntigravityLoginCoordinator.tokenURL {
                    let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                    let items = URLComponents(string: "http://127.0.0.1?\(body)")?.queryItems ?? []
                    if case .single(let v) = AntigravityLoginCoordinator.queryParameter("code_verifier", in: items) {
                        capturedTokenVerifiers.append(v)
                    }
                    let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data(#"{"access_token":"mock-access","refresh_token":"mock-refresh","expires_in":3600}"#.utf8), resp)
                }
                let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data(#"{"email":"agy-user@example.com"}"#.utf8), resp)
            },
            oauthConfigurationProvider: {
                .init(clientId: "test-client-id", clientSecret: "test-client-secret")
            },
            openBrowserHandler: { _ in }
        )

        coordinator.activateSessionForTesting(port: 54321)
        let firstAuthURL = coordinator.authURL!
        let firstQuery = URLComponents(url: firstAuthURL, resolvingAgainstBaseURL: false)!.queryItems!
        guard case .single(let firstState) = AntigravityLoginCoordinator.queryParameter("state", in: firstQuery),
              case .single(let firstChallenge) = AntigravityLoginCoordinator.queryParameter("code_challenge", in: firstQuery) else {
            fatalError("Missing state or code_challenge on first session")
        }

        // Unauthenticated OAuth error callback (wrong/missing state) must NOT abort active waitingForBrowser session
        let forgedErrorReq = "GET /oauth2callback?error=access_denied&state=wrong-state HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        let forgedResp = await coordinator.processRawHTTPRequest(forgedErrorReq)
        check(forgedResp.statusLine.contains("400"), "FIX-04: forged error callback without valid state returns 400")
        check(coordinator.phase == .waitingForBrowser, "FIX-04: forged error callback does not abort active session")
        check(capturedTokenVerifiers.values.isEmpty, "FIX-04: forged callback never triggers token exchange")

        // Duplicate state parameter is rejected without tearing down the active session
        let dupStateReq = "GET /oauth2callback?code=c1&state=\(firstState)&state=evil HTTP/1.1\r\nHost: 127.0.0.1:54321\r\n\r\n"
        _ = await coordinator.processRawHTTPRequest(dupStateReq)
        check(coordinator.phase == .waitingForBrowser, "FIX-04: duplicate state parameter rejected without aborting session")

        // Start a second session and verify distinct PKCE challenge + old callback rejection
        coordinator.activateSessionForTesting(port: 54322)
        let secondAuthURL = coordinator.authURL!
        let secondQuery = URLComponents(url: secondAuthURL, resolvingAgainstBaseURL: false)!.queryItems!
        guard case .single(let secondState) = AntigravityLoginCoordinator.queryParameter("state", in: secondQuery),
              case .single(let secondChallenge) = AntigravityLoginCoordinator.queryParameter("code_challenge", in: secondQuery) else {
            fatalError("Missing state or code_challenge on second session")
        }
        check(firstChallenge != secondChallenge && firstState != secondState,
              "FIX-03: distinct sessions generate distinct PKCE challenges and states")

        let staleSessionCallback = "GET /oauth2callback?code=ValidCode&state=\(firstState) HTTP/1.1\r\nHost: 127.0.0.1:54322\r\n\r\n"
        _ = await coordinator.processRawHTTPRequest(staleSessionCallback)
        check(coordinator.phase == .waitingForBrowser && capturedTokenVerifiers.values.isEmpty,
              "FIX-03/04: callback with previous session's state is rejected on new session")

        // Valid callback on second session succeeds and sends matching PKCE verifier
        let validSecondCallback = "GET /oauth2callback?code=ValidCode2&state=\(secondState) HTTP/1.1\r\nHost: 127.0.0.1:54322\r\n\r\n"
        let okResp = await coordinator.processRawHTTPRequest(validSecondCallback)
        check(okResp.statusLine == "HTTP/1.1 200 OK" && coordinator.phase == .succeeded,
              "FIX-03/04: valid origin-form callback completes login")
        check(capturedTokenVerifiers.values.count == 1 && AntigravityLoginCoordinator.pkceCodeChallenge(for: capturedTokenVerifiers.values[0]) == secondChallenge,
              "FIX-03: token exchange sent the exact PKCE code_verifier matching session 2's code_challenge")

        // Duplicate replay of the same callback does not trigger a second token exchange
        let replayResp = await coordinator.processRawHTTPRequest(validSecondCallback)
        check(replayResp.statusLine.contains("400") && capturedTokenVerifiers.values.count == 1,
              "FIX-04: replayed callback after completion is rejected without duplicate token exchange")

        coordinator.discardImportedSession()

        // R3: Loopback listener setup fails closed instead of falling back to wildcard (.any)
        var didThrowLoopbackSetup = false
        do {
            _ = try AntigravityLoginCoordinator.makeLoopbackListener(maxAttempts: 2, portAllocator: { nil })
        } catch {
            didThrowLoopbackSetup = true
        }
        check(didThrowLoopbackSetup, "R3: makeLoopbackListener fails closed when loopback port allocation fails")

        let failingListenerCoordinator = AntigravityLoginCoordinator(
            dataLoader: { _ in fatalError("Should not load network on listener setup failure") },
            oauthConfigurationProvider: {
                .init(clientId: "test-client-id", clientSecret: "test-client-secret")
            },
            openBrowserHandler: { _ in },
            listenerFactory: {
                try AntigravityLoginCoordinator.makeLoopbackListener(maxAttempts: 1, portAllocator: { nil })
            }
        )
        failingListenerCoordinator.start()
        if case .failed = failingListenerCoordinator.phase {
            check(failingListenerCoordinator.authURL == nil, "R3: coordinator does not publish authURL when loopback listener fails closed")
        } else {
            fatalError("R3: expected coordinator phase to be .failed when loopback listener setup fails")
        }

        // R2: Real local NWListener/NWConnection transport test with split TCP headers and truncated EOF
        coordinator.start()
        for _ in 0..<100 {
            if coordinator.phase == .waitingForBrowser { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        check(coordinator.phase == .waitingForBrowser, "R2: real loopback listener reaches waitingForBrowser state")
        let liveItems = URLComponents(url: coordinator.authURL!, resolvingAgainstBaseURL: false)!.queryItems!
        guard case .single(let tcpState) = AntigravityLoginCoordinator.queryParameter("state", in: liveItems),
              case .single(let tcpChallenge) = AntigravityLoginCoordinator.queryParameter("code_challenge", in: liveItems),
              case .single(let tcpRedirect) = AntigravityLoginCoordinator.queryParameter("redirect_uri", in: liveItems),
              let tcpPort = URL(string: tcpRedirect)?.port else {
            fatalError("R2: missing callback endpoint parameters")
        }

        // R2a: Truncated request (EOF before \r\n\r\n) returns HTTP 400 and keeps session alive
        let truncatedPrefix = "GET /oauth2callback?code=TruncatedCode&state=\(tcpState) HTTP/1.1\r\nHost: 127."
        let truncatedConnection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(tcpPort))!, using: .tcp)
        let truncatedResponse: String = await withCheckedContinuation { continuation in
            truncatedConnection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                truncatedConnection.stateUpdateHandler = nil
                truncatedConnection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    continuation.resume(returning: String(data: data ?? Data(), encoding: .utf8) ?? "")
                }
                truncatedConnection.send(
                    content: Data(truncatedPrefix.utf8),
                    contentContext: .finalMessage,
                    isComplete: true,
                    completion: .contentProcessed { _ in }
                )
            }
            truncatedConnection.start(queue: DispatchQueue.global())
        }
        truncatedConnection.cancel()
        check(truncatedResponse.hasPrefix("HTTP/1.1 400"), "R2: truncated EOF header returns HTTP 400")
        check(coordinator.phase == .waitingForBrowser, "R2: truncated EOF header does not abort waitingForBrowser session")

        // R2b: Valid callback split across multiple TCP segments reassembles and succeeds with HTTP 200
        let splitPart1 = "GET /oauth2callback?code=FragmentedCode&state=\(tcpState) HTTP/1.1\r\nHost: 127."
        let splitPart2 = "0.0.1:\(tcpPort)\r\nUser-Agent: SplitTest/1.0\r\n\r\n"
        let splitConnection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(tcpPort))!, using: .tcp)
        let splitResponse: String = await withCheckedContinuation { continuation in
            splitConnection.stateUpdateHandler = { state in
                guard case .ready = state else { return }
                splitConnection.stateUpdateHandler = nil
                splitConnection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { data, _, _, _ in
                    continuation.resume(returning: String(data: data ?? Data(), encoding: .utf8) ?? "")
                }
                splitConnection.send(content: Data(splitPart1.utf8), completion: .contentProcessed { _ in
                    DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(40)) {
                        splitConnection.send(content: Data(splitPart2.utf8), completion: .contentProcessed { _ in })
                    }
                })
            }
            splitConnection.start(queue: DispatchQueue.global())
        }
        splitConnection.cancel()
        check(splitResponse.hasPrefix("HTTP/1.1 200 OK"), "R2: split TCP header request succeeds with HTTP 200 OK after reassembly")
        check(coordinator.phase == .succeeded, "R2: coordinator reaches .succeeded after split TCP callback")
        check(capturedTokenVerifiers.values.count == 2 && AntigravityLoginCoordinator.pkceCodeChallenge(for: capturedTokenVerifiers.values[1]) == tcpChallenge,
              "R2: split TCP callback exchanges token with matching PKCE code_verifier")

        coordinator.discardImportedSession()
    }

    @MainActor
    static func testAntigravityAccountSwitcher() async {
        let fm = FileManager.default
        let tempHome = fm.temporaryDirectory.appendingPathComponent("agy-switcher-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: tempHome) }

        let dbDir = tempHome.appendingPathComponent("Library/Application Support/Antigravity/User/globalStorage", isDirectory: true)
        try! fm.createDirectory(at: dbDir, withIntermediateDirectories: true)
        let dbPath = dbDir.appendingPathComponent("state.vscdb").path

        var db: OpaquePointer?
        check(sqlite3_open(dbPath, &db) == SQLITE_OK, "AGY Switcher: create isolated temp state.vscdb")
        _ = sqlite3_exec(db, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value TEXT);", nil, nil, nil)

        // Seed Account 1 in state.vscdb with Field 19 in jetskiStateSync and Field 33 in userStatusProtoBinaryBase64
        let initialOAuthInfo = AntigravityAccountSwitcher.ProtobufCodec.createOAuthTokenInfo(
            accessToken: "ya29.acc1_initial_token",
            refreshToken: "1//0g_acc1_initial_refresh_token_secret_value",
            expirySeconds: 1_800_000_000,
            includeZeroNanos: false
        )
        var initialJetski = AntigravityAccountSwitcher.ProtobufCodec.encodeLenDelimField(6, payload: initialOAuthInfo)
        let field19Marker = Data("preserved-field-19-agent-prefs".utf8)
        initialJetski.append(AntigravityAccountSwitcher.ProtobufCodec.encodeLenDelimField(19, payload: field19Marker))

        var initialUserStatus = AntigravityAccountSwitcher.ProtobufCodec.encodeStringField(3, value: "acc1")
        initialUserStatus.append(AntigravityAccountSwitcher.ProtobufCodec.encodeStringField(7, value: "acc1@gmail.com"))
        let field33Marker = Data("preserved-field-33-tier-metadata".utf8)
        initialUserStatus.append(AntigravityAccountSwitcher.ProtobufCodec.encodeLenDelimField(33, payload: field33Marker))

        let initialAuthStatus: [String: Any] = [
            "name": "acc1",
            "email": "acc1@gmail.com",
            "apiKey": "ya29.acc1_initial_token",
            "userStatusProtoBinaryBase64": initialUserStatus.base64EncodedString()
        ]
        let initialAuthStatusStr = String(data: try! JSONSerialization.data(withJSONObject: initialAuthStatus), encoding: .utf8)!

        let insertSQL = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?);"
        func put(_ k: String, _ v: String) {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil)
            sqlite3_bind_text(stmt, 1, (k as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (v as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
        put("antigravityAuthStatus", initialAuthStatusStr)
        put("jetskiStateSync.agentManagerInitState", initialJetski.base64EncodedString())
        sqlite3_close(db)

        // 1. Verify initial detection & refresh token extraction from jetskiStateSync
        let detected1 = AntigravityAccountSwitcher.detectActiveAccount(homeDirectory: tempHome.path)
        check(detected1?.email == "acc1@gmail.com", "AGY Switcher: detects initial active email from state.vscdb")
        let extractedRefresh1 = AntigravityAccountSwitcher.extractRefreshToken(homeDirectory: tempHome.path)
        check(extractedRefresh1 == "1//0g_acc1_initial_refresh_token_secret_value",
              "AGY Switcher: extracts refresh_token from jetskiStateSync.agentManagerInitState")

        // 2. Write Account 2 auth file and switch to Account 2
        let acc2File = tempHome.appendingPathComponent("acc2.json")
        let acc2JSON: [String: Any] = [
            "access_token": "ya29.acc2_switched_token",
            "refresh_token": "1//0g_acc2_switched_refresh_token_secret_value",
            "email": "acc2@gmail.com",
            "expired": "2030-01-01T00:00:00Z",
            "token_type": "Bearer"
        ]
        try! JSONSerialization.data(withJSONObject: acc2JSON).write(to: acc2File)

        let switched2 = try! AntigravityAccountSwitcher.switchAccount(
            authFileURL: acc2File,
            fallbackEmail: "acc2@gmail.com",
            fallbackName: "Account Two",
            homeDirectory: tempHome.path
        )
        check(switched2.email == "acc2@gmail.com", "AGY Switcher: switchAccount returns switched email")

        let detected2 = AntigravityAccountSwitcher.detectActiveAccount(homeDirectory: tempHome.path)
        check(detected2?.email == "acc2@gmail.com", "AGY Switcher: state.vscdb now reports acc2@gmail.com as active")
        let extractedRefresh2 = AntigravityAccountSwitcher.extractRefreshToken(homeDirectory: tempHome.path)
        check(extractedRefresh2 == "1//0g_acc2_switched_refresh_token_secret_value",
              "AGY Switcher: state.vscdb now contains Account 2 refresh_token")

        // Verify Field 19 in jetskiStateSync and Field 33 in userStatusProtoBinaryBase64 were preserved
        var verifyDB: OpaquePointer?
        sqlite3_open_v2(dbPath, &verifyDB, SQLITE_OPEN_READONLY, nil)
        func get(_ k: String) -> String? {
            var stmt: OpaquePointer?
            sqlite3_prepare_v2(verifyDB, "SELECT value FROM ItemTable WHERE key = ?", -1, &stmt, nil)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, (k as NSString).utf8String, -1, nil)
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        }
        let jetskiAfter = Data(base64Encoded: get("jetskiStateSync.agentManagerInitState") ?? "") ?? Data()
        check(jetskiAfter.range(of: field19Marker) != nil,
              "AGY Switcher: preserves Field 19 preferences in jetskiStateSync.agentManagerInitState across switch")
        check(get("antigravityOnboarding") == "true",
              "AGY Switcher: sets antigravityOnboarding = true on switch")
        sqlite3_close(verifyDB)

        // 3. Switch back to Account 1 using an IDE-imported auth file without refresh_token (recovers from snapshot)
        let acc1File = tempHome.appendingPathComponent("acc1_ide.json")
        let acc1JSON: [String: Any] = [
            "access_token": "ya29.acc1_ide_token",
            "email": "acc1@gmail.com",
            "expired": "2000-01-01T00:00:00Z"
        ]
        try! JSONSerialization.data(withJSONObject: acc1JSON).write(to: acc1File)
        _ = try! AntigravityAccountSwitcher.switchAccount(
            authFileURL: acc1File,
            fallbackEmail: "acc1@gmail.com",
            homeDirectory: tempHome.path
        )
        check(AntigravityAccountSwitcher.detectActiveAccount(homeDirectory: tempHome.path)?.email == "acc1@gmail.com",
              "AGY Switcher: switches back to acc1@gmail.com")
        check(AntigravityAccountSwitcher.extractRefreshToken(homeDirectory: tempHome.path) == "1//0g_acc1_initial_refresh_token_secret_value",
              "AGY Switcher: recovers Account 1 refresh_token from snapshot when IDE import lacks refresh_token")

        // 4. [P2] First-activation refresh token recovery from current DB (when no prior snapshot exists)
        let firstSwitchHome = fm.temporaryDirectory.appendingPathComponent("agy-first-switch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: firstSwitchHome) }
        let firstDBPath = AntigravityAccountSwitcher.primaryDBPath(homeDirectory: firstSwitchHome.path)
        try! fm.createDirectory(at: URL(fileURLWithPath: firstDBPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        var firstDB: OpaquePointer?
        check(sqlite3_open(firstDBPath, &firstDB) == SQLITE_OK, "AGY P2: open fresh state.vscdb for first-activation test")
        _ = sqlite3_exec(firstDB, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value TEXT);", nil, nil, nil)
        let firstStatus = #"{"email":"a@example.com","apiKey":"ya29.initial_a"}"#
        let firstProto = AntigravityAccountSwitcher.ProtobufCodec.updateJetskiAgentManagerState(
            existingBase64: nil,
            accessToken: "ya29.initial_a",
            refreshToken: "1//existing_refresh_token_123456789",
            expirySeconds: 2_000_000_000
        )
        _ = sqlite3_exec(firstDB, "INSERT INTO ItemTable VALUES ('antigravityAuthStatus', '\(firstStatus)');", nil, nil, nil)
        _ = sqlite3_exec(firstDB, "INSERT INTO ItemTable VALUES ('jetskiStateSync.agentManagerInitState', '\(firstProto)');", nil, nil, nil)
        sqlite3_close(firstDB)

        let refreshlessA = firstSwitchHome.appendingPathComponent("refreshless_a.json")
        try! Data(#"{"email":"a@example.com","access_token":"ya29.new_access_a"}"#.utf8).write(to: refreshlessA)
        _ = try! AntigravityAccountSwitcher.switchAccount(authFileURL: refreshlessA, homeDirectory: firstSwitchHome.path)
        check(AntigravityAccountSwitcher.extractRefreshToken(homeDirectory: firstSwitchHome.path) == "1//existing_refresh_token_123456789",
              "AGY P2: first activation of refreshless active account preserves live DB refresh_token")
        let backfilledA = (try? JSONSerialization.jsonObject(with: Data(contentsOf: refreshlessA))) as? [String: Any]
        check(backfilledA?["refresh_token"] as? String == "1//existing_refresh_token_123456789",
              "AGY P2: first activation backfills recovered refresh_token into credential file")

        // Reject completely unrecoverable refreshless switch without clobbering active account
        let refreshlessUnrecoverable = firstSwitchHome.appendingPathComponent("unrecoverable_c.json")
        try! Data(#"{"email":"c@example.com","access_token":"ya29.no_refresh_c"}"#.utf8).write(to: refreshlessUnrecoverable)
        var rejectedUnrecoverable = false
        do {
            _ = try AntigravityAccountSwitcher.switchAccount(authFileURL: refreshlessUnrecoverable, homeDirectory: firstSwitchHome.path)
        } catch AntigravitySwitchError.missingRefreshToken {
            rejectedUnrecoverable = true
        } catch {}
        check(rejectedUnrecoverable, "AGY P2: rejects unrecoverable refreshless credential with missingRefreshToken")
        check(AntigravityAccountSwitcher.detectActiveAccount(homeDirectory: firstSwitchHome.path)?.email == "a@example.com",
              "AGY P2: rejecting unrecoverable refreshless switch leaves active DB account untouched")

        // 5. [P1] Cross-account fallback isolation (primary DB is a@example.com without refresh token; standalone & secondary DB are b@example.com)
        let crossHome = fm.temporaryDirectory.appendingPathComponent("agy-cross-account-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: crossHome) }
        let crossPrimaryPath = AntigravityAccountSwitcher.primaryDBPath(homeDirectory: crossHome.path)
        try! fm.createDirectory(at: URL(fileURLWithPath: crossPrimaryPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        var crossDB: OpaquePointer?
        _ = sqlite3_open(crossPrimaryPath, &crossDB)
        _ = sqlite3_exec(crossDB, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value TEXT);", nil, nil, nil)
        _ = sqlite3_exec(crossDB, #"INSERT INTO ItemTable VALUES ('antigravityAuthStatus', '{"email":"a@example.com","apiKey":"ya29.a_only"}');"#, nil, nil, nil)
        sqlite3_close(crossDB)

        let secondaryDBPath = "\(crossHome.path)/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb"
        try! fm.createDirectory(at: URL(fileURLWithPath: secondaryDBPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        var secDB: OpaquePointer?
        _ = sqlite3_open(secondaryDBPath, &secDB)
        _ = sqlite3_exec(secDB, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value TEXT);", nil, nil, nil)
        let bProto = AntigravityAccountSwitcher.ProtobufCodec.updateJetskiAgentManagerState(
            existingBase64: nil,
            accessToken: "ya29.b_access",
            refreshToken: "1//account_b_secondary_db_refresh",
            expirySeconds: 2_000_000_000
        )
        _ = sqlite3_exec(secDB, #"INSERT INTO ItemTable VALUES ('antigravityAuthStatus', '{"email":"b@example.com","apiKey":"ya29.b_access"}');"#, nil, nil, nil)
        _ = sqlite3_exec(secDB, "INSERT INTO ItemTable VALUES ('jetskiStateSync.agentManagerInitState', '\(bProto)');", nil, nil, nil)
        sqlite3_close(secDB)

        let standaloneFile = crossHome.appendingPathComponent(".gemini/jetski-standalone-oauth-token")
        try! fm.createDirectory(at: standaloneFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! JSONSerialization.data(withJSONObject: [
            "email": "b@example.com",
            "token": ["refresh_token": "1//account_b_standalone_refresh"]
        ]).write(to: standaloneFile)

        check(AntigravityAccountSwitcher.extractRefreshToken(homeDirectory: crossHome.path) == nil,
              "AGY P1: extractRefreshToken rejects secondary DB and standalone refresh tokens belonging to a different account")
        let candidatePayload = AntigravityAccountSwitcher.discoverIDECandidatePayload(homeDirectory: crossHome.path)
        check(candidatePayload?.email == "a@example.com" && candidatePayload?.refreshToken == nil,
              "AGY P1: discoverIDECandidatePayload binds identity to primary DB and omits mismatched fallback refresh token")

        // When standalone file matches primary account a@example.com, fallback is accepted
        try! JSONSerialization.data(withJSONObject: [
            "email": "a@example.com",
            "token": ["refresh_token": "1//account_a_matching_standalone_refresh"]
        ]).write(to: standaloneFile)
        check(AntigravityAccountSwitcher.extractRefreshToken(homeDirectory: crossHome.path) == "1//account_a_matching_standalone_refresh",
              "AGY P1: extractRefreshToken accepts standalone fallback when email matches primary account")

        // 6. [P2] Malformed Protobuf lengths, varint overflow, and out-of-range field numbers
        let maxLenBytes = Data([0x0a] + Array(repeating: UInt8(0xff), count: 9) + [0x01])
        check(AntigravityAccountSwitcher.ProtobufCodec.removeFields(maxLenBytes, fieldNumbers: [6]) == nil,
              "AGY P2: removeFields rejects UInt64.max length-delimited field without integer trap")
        let overflowVarintBytes = Data(Array(repeating: UInt8(0xff), count: 9) + [0x7f])
        check(AntigravityAccountSwitcher.ProtobufCodec.readVarint(overflowVarintBytes, offset: 0) == nil,
              "AGY P2: readVarint rejects 10th byte > 0x01 overflow")
        let zeroFieldTag = Data([0x02, 0x01, 0x41]) // fieldNumber = 0, wireType = 2
        check(AntigravityAccountSwitcher.ProtobufCodec.removeFields(zeroFieldTag, fieldNumbers: [1]) == nil,
              "AGY P2: decodeTag rejects protobuf field number 0")

        // 7. [P2] restartAntigravityApp lifecycle: quit refusal, timeout while old process runs, and normal quit/reopen
        var relaunchCount = 0
        let refusedResult = await AntigravityAccountSwitcher.restartAntigravityApp(
            homeDirectory: tempHome.path,
            timeoutSeconds: 0.05,
            pollIntervalMilliseconds: 10,
            appExists: { $0 == "/Applications/Antigravity.app" },
            isTargetRunning: { true },
            requestTerminate: { false },
            relaunchApp: { _ in relaunchCount += 1; return true }
        )
        check(!refusedResult && relaunchCount == 0,
              "AGY P2 Restart: returns false and does not call openApplication when terminate() is refused")

        let timeoutStillRunningResult = await AntigravityAccountSwitcher.restartAntigravityApp(
            homeDirectory: tempHome.path,
            timeoutSeconds: 0.04,
            pollIntervalMilliseconds: 10,
            appExists: { $0 == "/Applications/Antigravity.app" },
            isTargetRunning: { true },
            requestTerminate: { true },
            relaunchApp: { _ in relaunchCount += 1; return true }
        )
        check(!timeoutStillRunningResult && relaunchCount == 0,
              "AGY P2 Restart: returns false and does not call openApplication when old process still runs after timeout")

        var simulatedRunning = true
        var relaunchedURL: URL?
        let normalRestartResult = await AntigravityAccountSwitcher.restartAntigravityApp(
            homeDirectory: tempHome.path,
            timeoutSeconds: 0.1,
            pollIntervalMilliseconds: 10,
            appExists: { $0 == "\(tempHome.path)/Applications/Antigravity.app" },
            isTargetRunning: { simulatedRunning },
            requestTerminate: {
                simulatedRunning = false
                return true
            },
            relaunchApp: { url in
                relaunchedURL = url
                relaunchCount += 1
                return true
            }
        )
        check(normalRestartResult && relaunchCount == 1 && relaunchedURL?.path == "\(tempHome.path)/Applications/Antigravity.app",
              "AGY P2 Restart: returns true and relaunches app only after old process terminates")

        // 8. Antigravity 2.0 (v2.29.0) app_storage.json active account detection & switching
        let agy2Home = fm.temporaryDirectory.appendingPathComponent("agy2-app-storage-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: agy2Home) }

        let staleDBPath = AntigravityAccountSwitcher.primaryDBPath(homeDirectory: agy2Home.path)
        try! fm.createDirectory(at: URL(fileURLWithPath: staleDBPath).deletingLastPathComponent(), withIntermediateDirectories: true)
        var staleDB: OpaquePointer?
        _ = sqlite3_open(staleDBPath, &staleDB)
        _ = sqlite3_exec(staleDB, "CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value TEXT);", nil, nil, nil)
        _ = sqlite3_exec(staleDB, #"INSERT INTO ItemTable VALUES ('antigravityAuthStatus', '{"email":"chunganhhao@gmail.com","apiKey":"ya29.stale"}');"#, nil, nil, nil)
        sqlite3_close(staleDB)
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_770_117_163)], ofItemAtPath: staleDBPath)

        let appStoragePath = AntigravityAccountSwitcher.appStoragePath(homeDirectory: agy2Home.path)
        let initialAppStorage: [String: Any] = [
            "agy.onboarding.lastLoginUsername": "chungduccc@gmail.com",
            "agy.onboarding.lastLoginIsGcpTos": "false",
            "lastCreatedProjectId": "keep-this-project-id"
        ]
        try! JSONSerialization.data(withJSONObject: initialAppStorage).write(to: URL(fileURLWithPath: appStoragePath))
        try! fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_794_038_000)], ofItemAtPath: appStoragePath)

        let detectedAGY2 = AntigravityAccountSwitcher.detectActiveAccount(homeDirectory: agy2Home.path)
        check(detectedAGY2?.email == "chungduccc@gmail.com",
              "AGY 2.0: detectActiveAccount prefers newer app_storage.json over stale legacy state.vscdb")
        check(AntigravityAccountSwitcher.activeStorageDisplayPath(homeDirectory: agy2Home.path) == "~/Library/Application Support/Antigravity/app_storage.json",
              "AGY 2.0: activeStorageDisplayPath reports app_storage.json when newer than state.vscdb")

        // Switch account in Antigravity 2.0 environment without state.vscdb (only app_storage.json + standalone token)
        try! fm.removeItem(atPath: staleDBPath)
        let agy2StandalonePath = AntigravityAccountSwitcher.standaloneTokenPath(homeDirectory: agy2Home.path)
        try! fm.createDirectory(at: URL(fileURLWithPath: agy2StandalonePath).deletingLastPathComponent(), withIntermediateDirectories: true)
        try! Data(#"{"token":{"access_token":"ya29.old","refresh_token":"1//old"},"id_token_email":"chungduccc@gmail.com"}"#.utf8)
            .write(to: URL(fileURLWithPath: agy2StandalonePath))

        let switchedAGY2Auth = agy2Home.appendingPathComponent("next_account.json")
        try! JSONSerialization.data(withJSONObject: [
            "access_token": "ya29.next_token",
            "refresh_token": "1//next_refresh_token",
            "email": "chunganhduc123@gmail.com",
            "project_id": "proj-123"
        ]).write(to: switchedAGY2Auth)

        let switchedAGY2 = try! AntigravityAccountSwitcher.switchAccount(
            authFileURL: switchedAGY2Auth,
            homeDirectory: agy2Home.path
        )
        check(switchedAGY2.email == "chunganhduc123@gmail.com",
              "AGY 2.0: switchAccount succeeds when only app_storage.json exists without legacy state.vscdb")
        check(AntigravityAccountSwitcher.detectActiveAccount(homeDirectory: agy2Home.path)?.email == "chunganhduc123@gmail.com",
              "AGY 2.0: detectActiveAccount returns newly switched account from app_storage.json / standalone token")

        let updatedAppStorage = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: appStoragePath)))) as? [String: Any]
        check(updatedAppStorage?["agy.onboarding.lastLoginUsername"] as? String == "chunganhduc123@gmail.com"
                && updatedAppStorage?["lastCreatedProjectId"] as? String == "keep-this-project-id",
              "AGY 2.0: switchAccount updates agy.onboarding.lastLoginUsername and preserves existing keys in app_storage.json")

        let updatedStandalone = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: agy2StandalonePath)))) as? [String: Any]
        check(updatedStandalone?["id_token_email"] as? String == "chunganhduc123@gmail.com"
                && updatedStandalone?["project_id"] as? String == "proj-123",
              "AGY 2.0: switchAccount writes StoredToken schema (id_token_email & project_id) to jetski-standalone-oauth-token")
    }
}
