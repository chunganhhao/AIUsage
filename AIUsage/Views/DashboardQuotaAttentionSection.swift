import SwiftUI
import QuotaBackend

// MARK: - Dashboard Quota Attention
// 首页额度告警摘要：紧凑行 + 管理入口。不渲染 ProviderCard，管理去「订阅账号」页。

struct DashboardQuotaAttentionSection: View {
    let entries: [ProviderAccountEntry]
    let isLoading: (ProviderAccountEntry) -> Bool
    let onOpenSubscriptions: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private static let maxVisibleRows = 5

    private var attentionEntries: [ProviderAccountEntry] {
        entries
            .filter { entry in
                // 首页仍汇总额度告警；订阅页「需处理」不含额度（见 SubscriptionAccountListLogic）。
                if SubscriptionAccountListLogic.hasQuotaAlert(entry) { return true }
                let bucket = SubscriptionAccountListLogic.bucket(for: entry, isLoading: isLoading(entry))
                switch bucket {
                case .attention, .needsConnection:
                    return true
                case .offline:
                    if entry.providerId == "antigravity",
                       entry.storedAccount?.credentialId != nil {
                        return false
                    }
                    return true
                case .ready, .loading:
                    return false
                }
            }
            .sorted { lhs, rhs in
                let l = attentionSortScore(lhs)
                let r = attentionSortScore(rhs)
                if l != r { return l > r }
                return (lhs.accountEmail ?? lhs.id) < (rhs.accountEmail ?? rhs.id)
            }
    }

    private var visibleEntries: [ProviderAccountEntry] {
        Array(attentionEntries.prefix(Self.maxVisibleRows))
    }

    private var overflowCount: Int {
        max(0, attentionEntries.count - Self.maxVisibleRows)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L("Needs attention", "需要关注", key: "dashboard.quota_attention"))
                    .font(.headline)
                if !attentionEntries.isEmpty {
                    Text("\(attentionEntries.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }
                Spacer(minLength: 0)
            }

            if attentionEntries.isEmpty {
                emptyState
            } else {
                VStack(spacing: 4) {
                    ForEach(visibleEntries) { entry in
                        DashboardQuotaAttentionRow(entry: entry, onTap: onOpenSubscriptions)
                    }
                }

                if overflowCount > 0 {
                    Button(action: onOpenSubscriptions) {
                        HStack {
                            Text(L(
                                "\(overflowCount) more need attention",
                                "还有 \(overflowCount) 个需要关注"
                            ))
                            .font(.caption.weight(.semibold))
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
            }

            DashboardManageAccountsBanner(
                totalCount: entries.count,
                attentionCount: attentionEntries.count,
                onManage: onOpenSubscriptions
            )
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(L("All account quotas look healthy", "全部账号额度正常"))
                .font(.subheadline)
                .foregroundStyle(AppContent.secondary(colorScheme))
            Spacer(minLength: 0)
            Button(L("Manage accounts", "管理账号"), action: onOpenSubscriptions)
                .buttonStyle(.borderless)
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(AppSurface.row(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func attentionSortScore(_ entry: ProviderAccountEntry) -> Int {
        if let status = entry.liveProvider?.status {
            switch status {
            case .critical: return 5
            case .watch: return 4
            case .error: return 3
            case .healthy, .idle, .tracking: break
            }
        }
        let bucket = SubscriptionAccountListLogic.bucket(for: entry, isLoading: isLoading(entry))
        switch bucket {
        case .attention: return 3
        case .needsConnection: return 2
        case .offline: return 1
        case .ready, .loading: return 0
        }
    }
}

// MARK: - Row

struct DashboardQuotaAttentionRow: View {
    let entry: ProviderAccountEntry
    let onTap: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private var bucket: SubscriptionAccountBucket {
        SubscriptionAccountListLogic.bucket(for: entry, isLoading: false)
    }

    private var statusText: String {
        if SubscriptionAccountListLogic.hasQuotaAlert(entry),
           let label = entry.liveProvider?.statusLabel.nilIfBlank {
            return localizedDashboardStatus(label)
        }
        switch bucket {
        case .needsConnection:
            return L("Not connected", "未连接")
        case .offline:
            return L("Offline", "离线")
        case .attention:
            if let label = entry.liveProvider?.statusLabel.nilIfBlank {
                return localizedDashboardStatus(label)
            }
            return L("Attention", "需处理")
        case .ready, .loading:
            return L("Attention", "需处理")
        }
    }

    private var statusTint: Color {
        switch bucket {
        case .needsConnection: return .blue
        case .offline: return .secondary
        case .attention:
            return entry.liveProvider?.statusColor ?? .orange
        case .ready, .loading: return .orange
        }
    }

    private var remainingText: String? {
        guard let remaining = entry.liveProvider?.remainingPercent else { return nil }
        let rounded = (remaining * 10).rounded() / 10
        if abs(rounded.rounded() - rounded) < 0.05 {
            return "\(Int(rounded.rounded()))%"
        }
        return String(format: "%.1f%%", rounded)
    }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                ProviderIconView(entry.providerId, size: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .frame(width: 20, height: 20)

                Text(entry.providerTitle)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AppContent.primary(colorScheme))
                    .lineLimit(1)

                if let email = entry.footerAccountLabel ?? entry.accountEmail {
                    Text(email)
                        .font(.caption)
                        .foregroundStyle(AppContent.secondary(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 6)

                if let remainingText {
                    Text(remainingText)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(statusTint)
                }

                GatewayQuietBadge(text: statusText, tint: statusTint)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(AppSurface.row(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.providerTitle), \(statusText)")
    }

    private func localizedDashboardStatus(_ label: String) -> String {
        switch label {
        case "Healthy": return L("Healthy", "正常")
        case "Watch": return L("Watch", "偏低")
        case "Critical": return L("Critical", "告急")
        case "Error": return L("Error", "错误")
        case "Tracking": return L("Tracking", "追踪中")
        case "Idle": return L("Idle", "空闲")
        default: return label
        }
    }
}
