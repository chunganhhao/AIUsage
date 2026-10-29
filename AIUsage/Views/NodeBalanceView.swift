import SwiftUI
import QuotaBackend

/// API 提供商及三个产品的节点共用一份内存状态；不持久化 Key 或余额。
@MainActor
final class NodeBalanceStore: ObservableObject {
    static let shared = NodeBalanceStore()
    @Published private(set) var results: [String: APIKeyBalanceSnapshot] = [:]
    @Published private(set) var loading: Set<String> = []
    private let service = APIKeyBalanceService()

    func refresh(_ target: APIKeyBalanceTarget, force: Bool = false) async {
        guard !loading.contains(target.cacheKey) else { return }
        loading.insert(target.cacheKey)
        defer { loading.remove(target.cacheKey) }
        results[target.cacheKey] = await service.fetch(target, force: force)
    }
}

/// 不支持、尚未查询及失败均不保留空行；失败原因收进右键菜单。
struct NodeBalanceLine: View {
    let target: APIKeyBalanceTarget?
    @ObservedObject private var store = NodeBalanceStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let target, let result = store.results[target.cacheKey], result.status == .available {
                HStack(spacing: 8) {
                    ForEach(Array(result.amounts.enumerated()), id: \.offset) { _, amount in
                        Label(NodeBalancePresentation.text(amount), systemImage: amount.scope == .account ? "creditcard" : "key")
                    }
                    if store.loading.contains(target.cacheKey) { ProgressView().controlSize(.mini) }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .help(L("Balance checked: ", "额度查询时间：") + result.checkedAt.formatted(date: .abbreviated, time: .shortened)
                      + L(". Key limits are separate from account balance.", "。Key 限额不代表账号余额。"))
            }
        }
        .task(id: target?.cacheKey) {
            guard let target else { return }
            await store.refresh(target)
        }
    }
}

struct NodeBalanceMenu: View {
    let target: APIKeyBalanceTarget?
    @ObservedObject private var store = NodeBalanceStore.shared

    var body: some View {
        if let target {
            Button {
                Task { await store.refresh(target, force: true) }
            } label: {
                Label(L("Refresh key balance", "刷新 Key 额度"), systemImage: "creditcard")
            }
            .disabled(!target.supportsLookup || store.loading.contains(target.cacheKey))
            if let status = store.results[target.cacheKey]?.status, status != .available {
                Text(NodeBalancePresentation.status(status))
            }
            Divider()
        }
    }
}

enum NodeBalancePresentation {
    static func text(_ amount: APIKeyBalanceAmount) -> String {
        if amount.uncapped { return L("Key uncapped", "Key 未设限") }
        guard let value = amount.remaining else { return "" }
        let label = amount.scope == .account ? L("Balance ", "账号余额 ") : L("Key limit left ", "Key 限额剩余 ")
        let number = value.formatted(.number.precision(.fractionLength(0...2)))
        switch amount.currency {
        case "USD": return label + "$" + number
        case "CNY": return label + "¥" + number
        default: return label + number + L(" quota units", " 额度单位")
        }
    }

    static func status(_ status: APIKeyBalanceSnapshot.Status) -> String {
        switch status {
        case .available: return ""
        case .unsupported: return L("This provider has no supported key balance endpoint", "此提供商暂无支持的 Key 额度接口")
        case .unauthorized: return L("Balance query not authorized; check key permissions", "无权查询额度，请检查 Key 权限")
        case .rateLimited: return L("Balance query rate limited; retry later", "额度查询受到限流，请稍后重试")
        case .failed: return L("Balance unavailable; refresh to retry", "额度暂不可用，可刷新重试")
        }
    }
}
