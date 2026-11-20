import Foundation
import SwiftUI
import QuotaBackend

// MARK: - Subscription Account List Models
// 订阅账号页的状态筛选与派生计数（仿 GatewayAccountListModels）。
// 与卡片/行 UI 解耦，ProvidersView 只做编排。

enum SubscriptionAccountFilter: String, CaseIterable, Hashable {
    case all
    case ready
    case attention
    case offline
    case needsConnection

    var title: String {
        switch self {
        case .all: L("All", "全部")
        case .ready: L("Online", "在线")
        case .attention: L("Attention", "需处理")
        case .offline: L("Offline", "离线")
        case .needsConnection: L("Not connected", "未连接")
        }
    }
}

enum SubscriptionAccountBucket: Equatable {
    case ready
    case attention
    case offline
    case needsConnection
    case loading
}

enum SubscriptionAccountListLogic {
    static func isAccountLoading(
        _ entry: ProviderAccountEntry,
        hasCompletedInitialLoad: Bool,
        isProviderRefreshInFlight: (String) -> Bool
    ) -> Bool {
        !hasCompletedInitialLoad || isProviderRefreshInFlight(entry.providerId)
    }

    static func bucket(
        for entry: ProviderAccountEntry,
        isLoading: Bool
    ) -> SubscriptionAccountBucket {
        if let live = entry.liveProvider {
            if live.needsCredentialConnection {
                return .needsConnection
            }
            switch live.status {
            case .error:
                // 仅凭据/抓取失败需要用户动手；额度 watch/critical 仍算在线。
                return .attention
            case .critical, .watch, .healthy, .idle, .tracking:
                return .ready
            }
        }
        if isLoading {
            return .loading
        }
        return .offline
    }

    /// 额度告警（少/用尽）：卡片上已展示，不算「需处理」。
    static func hasQuotaAlert(_ entry: ProviderAccountEntry) -> Bool {
        guard let live = entry.liveProvider, !live.needsCredentialConnection else { return false }
        switch live.status {
        case .watch, .critical: return true
        case .healthy, .idle, .tracking, .error: return false
        }
    }

    static func matches(
        entry: ProviderAccountEntry,
        filter: SubscriptionAccountFilter,
        isLoading: Bool
    ) -> Bool {
        let bucket = bucket(for: entry, isLoading: isLoading)
        switch filter {
        case .all:
            return true
        case .ready:
            return bucket == .ready
        case .attention:
            return bucket == .attention
        case .offline:
            return bucket == .offline
        case .needsConnection:
            return bucket == .needsConnection
        }
    }

    static func allEntries(in groups: [ProviderAccountGroup]) -> [ProviderAccountEntry] {
        groups.flatMap(\.accounts)
    }

    static func count(
        _ filter: SubscriptionAccountFilter,
        in entries: [ProviderAccountEntry],
        isLoading: (ProviderAccountEntry) -> Bool
    ) -> Int {
        switch filter {
        case .all:
            return entries.count
        case .ready, .attention, .offline, .needsConnection:
            return entries.filter { matches(entry: $0, filter: filter, isLoading: isLoading($0)) }.count
        }
    }

    static func filteredGroups(
        groups: [ProviderAccountGroup],
        query: String,
        providerFilter: String,
        statusFilter: SubscriptionAccountFilter,
        isLoading: (ProviderAccountEntry) -> Bool
    ) -> [ProviderAccountGroup] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return groups.compactMap { group -> ProviderAccountGroup? in
            guard providerFilter == "all" || group.providerId == providerFilter else { return nil }

            if group.accounts.isEmpty {
                guard statusFilter == .all else { return nil }
                let matchesGroup = normalizedQuery.isEmpty
                    || group.title.localizedCaseInsensitiveContains(normalizedQuery)
                return matchesGroup ? group : nil
            }

            let filteredAccounts = group.accounts.filter { account in
                let matchesSearch = normalizedQuery.isEmpty
                    || group.title.localizedCaseInsensitiveContains(normalizedQuery)
                    || (account.accountEmail?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                    || (account.accountDisplayName?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                    || (account.accountNote?.localizedCaseInsensitiveContains(normalizedQuery) ?? false)
                guard matchesSearch else { return false }
                return matches(entry: account, filter: statusFilter, isLoading: isLoading(account))
            }

            if filteredAccounts.isEmpty {
                guard statusFilter == .all else { return nil }
                let matchesGroup = normalizedQuery.isEmpty
                    || group.title.localizedCaseInsensitiveContains(normalizedQuery)
                guard matchesGroup else { return nil }
                return ProviderAccountGroup(
                    id: group.id,
                    providerId: group.providerId,
                    title: group.title,
                    subtitle: group.subtitle,
                    channel: group.channel,
                    isScanningEnabled: group.isScanningEnabled,
                    accounts: []
                )
            }

            return ProviderAccountGroup(
                id: group.id,
                providerId: group.providerId,
                title: group.title,
                subtitle: group.subtitle,
                channel: group.channel,
                isScanningEnabled: group.isScanningEnabled,
                accounts: filteredAccounts
            )
        }
    }
}

extension Array where Element == ProviderAccountEntry {
    func bestNextQuotaCandidate(
        isActive: (ProviderAccountEntry) -> Bool,
        now: Date = Date()
    ) -> QuotaSnapshotBestNextCandidate? {
        let inputs: [QuotaSnapshotAdvisor.CandidateInput] = compactMap { entry in
            guard let live = entry.liveProvider, live.status != .error else { return nil }
            let windows = live.windows.map {
                QuotaSnapshotWindowInput(label: $0.label, remainingPercent: $0.remainingPercent, resetAt: $0.resetAt)
            }
            let fetchedAt = live.fetchedAt.flatMap { SharedFormatters.parseISO8601($0) }
            return QuotaSnapshotAdvisor.CandidateInput(
                id: entry.id,
                providerId: entry.providerId,
                label: entry.accountPrimaryLabel,
                remainingPercent: live.remainingPercent,
                fetchedAt: fetchedAt,
                isActive: isActive(entry),
                isTerminalSuspended: live.errorCode == "tos_violation" || live.errorCode == "account_disabled",
                windows: windows
            )
        }
        return QuotaSnapshotAdvisor.bestNextCandidate(from: inputs, now: now)
    }
}
