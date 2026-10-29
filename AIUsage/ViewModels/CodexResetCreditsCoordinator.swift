import Foundation
import Combine
import QuotaBackend

@MainActor
final class CodexResetCreditsCoordinator: ObservableObject {
    struct Target: Sendable {
        let identity: CodexAccountIdentity
        let credentialID: String?
        let label: String
        let isLocal: Bool
        var key: String { (isLocal ? "local:" : "remote:") + (identity.nativeKey ?? "read-only:\(label)") }
    }
    struct State {
        var list: CodexResetCredits?
        var listFetchedAt: Date?
        var listCountIsAuthoritative = false
        var isLoading = false
        var isConsuming = false
        var isRefreshing = false
        var listFailed = false
        var outcome: CodexResetConsumeOutcome?
        var errorCode: String?
        var refreshFailed = false
        var refreshedAfterError = false
        var countInvalidatedAt: Date?
        var redeemedCreditIDs: Set<String> = []
    }
    static let shared = CodexResetCreditsCoordinator()
    @Published private var states: [String: State] = [:]
    private let operations: CodexResetCreditsOperations
    private let loadCredential: (String) -> AccountCredential?
    private let isLocal: () -> Bool
    private let now: () -> Date

    init(
        operations: CodexResetCreditsOperations? = nil,
        loadCredential: @escaping (String) -> AccountCredential? = {
            AccountCredentialStore.shared.loadCredential(providerId: "codex", credentialId: $0)
        },
        isLocal: @escaping () -> Bool = { AppSettings.shared.backendMode == "local" },
        now: @escaping () -> Date = Date.init
    ) {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AIUsage/CodexResetCredits", isDirectory: true)
        self.operations = operations ?? CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("pending.json"))
        self.loadCredential = loadCredential
        self.isLocal = isLocal
        self.now = now
    }

    func state(for target: Target) -> State { states[target.key] ?? State() }

    func availableCount(for target: Target, summaryCount: Int?, summaryFetchedAt: String?) -> Int? {
        let cached = state(for: target)
        if let invalidatedAt = cached.countInvalidatedAt {
            // 回读失败时不能把消费前的数量重新当作当前数量。
            guard let summaryDate = summaryFetchedAt.flatMap(SharedFormatters.parseISO8601),
                  summaryDate > invalidatedAt else { return nil }
            return summaryCount
        }
        guard cached.listCountIsAuthoritative else { return summaryCount }
        if let summaryDate = summaryFetchedAt.flatMap(SharedFormatters.parseISO8601),
           let listDate = cached.listFetchedAt, summaryDate > listDate {
            return summaryCount
        }
        return cached.list?.availableCount ?? summaryCount
    }

    func canConsume(_ card: CodexResetCredit, for target: Target) -> Bool {
        canOperate(target) && !state(for: target).redeemedCreditIDs.contains(card.id) && card.canConsume(at: now())
    }

    func canOperate(_ target: Target) -> Bool {
        target.isLocal && isLocal() && target.identity.nativeKey != nil && target.credentialID != nil
    }

    private func credential(for target: Target) throws -> AccountCredential {
        guard canOperate(target), let id = target.credentialID, let credential = loadCredential(id),
              credential.authMethod == .authFile,
              CodexAccountIdentity(credential: credential).nativeKey == target.identity.nativeKey else {
            throw ProviderError("reset_read_only", "A matching local Codex OAuth account is required.")
        }
        return credential
    }

    func load(_ target: Target) async {
        guard canOperate(target), !state(for: target).isLoading, !state(for: target).isConsuming, !state(for: target).isRefreshing else { return }
        states[target.key, default: State()].isLoading = true
        defer { states[target.key, default: State()].isLoading = false }
        await loadDetails(target)
    }

    private func loadDetails(_ target: Target) async {
        do {
            let list = try await operations.list(credential: credential(for: target), identity: target.identity)
            states[target.key, default: State()].list = list
            states[target.key, default: State()].listFetchedAt = now()
            states[target.key, default: State()].listCountIsAuthoritative = true
            states[target.key, default: State()].countInvalidatedAt = nil
            states[target.key, default: State()].listFailed = false
            // 明细刷新不能证明未知提交成功，但可清除已经恢复的读取/校验错误。
            if state(for: target).errorCode != "reset_ambiguous" {
                states[target.key, default: State()].errorCode = nil
            }
        } catch {
            states[target.key, default: State()].listFailed = true
        }
    }

    func retryRefresh(_ target: Target, refresh: () async -> Bool) async {
        guard canOperate(target), !state(for: target).isLoading, !state(for: target).isConsuming, !state(for: target).isRefreshing else { return }
        states[target.key, default: State()].isRefreshing = true
        defer { states[target.key, default: State()].isRefreshing = false }
        let refreshed = await refresh()
        states[target.key, default: State()].refreshFailed = !refreshed
        if refreshed {
            states[target.key, default: State()].listCountIsAuthoritative = false
            states[target.key, default: State()].countInvalidatedAt = nil
            states[target.key, default: State()].refreshedAfterError = true
        }
        // 此刷新持有忙状态，直接读取明细，避免被公共 load 的防重入检查拦住。
        await loadDetails(target)
    }

    /// 只有原生确认框的明确确认调用此方法；关闭/取消没有网络副作用。
    func confirm(_ card: CodexResetCredit, for target: Target, refresh: @escaping () async -> Bool) async {
        guard canOperate(target), !state(for: target).isLoading, !state(for: target).isConsuming, !state(for: target).isRefreshing else { return }
        guard canConsume(card, for: target) else { return }
        states[target.key, default: State()].isConsuming = true
        states[target.key, default: State()].outcome = nil
        states[target.key, default: State()].errorCode = nil
        states[target.key, default: State()].refreshFailed = false
        states[target.key, default: State()].refreshedAfterError = false
        defer { states[target.key, default: State()].isConsuming = false }
        do {
            let outcome = try await operations.consume(credential: credential(for: target), identity: target.identity, creditID: card.id)
            states[target.key, default: State()].outcome = outcome
            if outcome.code == .reset || outcome.code == .alreadyRedeemed {
                states[target.key, default: State()].redeemedCreditIDs.insert(card.id)
            }
            states[target.key, default: State()].countInvalidatedAt = now()
            states[target.key, default: State()].listCountIsAuthoritative = false
            let refreshed = await refresh()
            states[target.key, default: State()].refreshFailed = !refreshed
            // usage 时间只有秒精度；刷新成功后旧明细数量失效，卡片行仍保留。
            if refreshed { states[target.key, default: State()].countInvalidatedAt = nil }
            await loadDetails(target)
        } catch {
            let code = (error as? ProviderError)?.code ?? "reset_unavailable"
            states[target.key, default: State()].errorCode = code
            if code == "reset_ambiguous" {
                states[target.key, default: State()].countInvalidatedAt = now()
                states[target.key, default: State()].listCountIsAuthoritative = false
            }
        }
    }
}
