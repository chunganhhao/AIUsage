import SwiftUI
import QuotaBackend

// MARK: - Provider Section
// 菜单栏中一个服务商分组（标题行 + 该组所有账号行）。

struct MenuBarProviderSection: View {
    let group: ProviderAccountGroup
    /// Codex 代理是否有节点正在生效：由 MenuBarView 统一观察后下传至账号行。
    let codexProxyActive: Bool
    /// Codex 全局统一代理是否启用：由 MenuBarView 统一观察 GlobalProxyManager 后下传。
    let codexGlobalProxyManaged: Bool
    @Binding var activationMessage: String?
    @Binding var activationSuccess: Bool
    var onRequestRestartConfirmation: ((ProviderAccountEntry) -> Void)? = nil
    @EnvironmentObject var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var accentColor: Color {
        MenuBarColors.accent(for: group.providerId)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionHeader
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 4)

            ForEach(group.accounts) { entry in
                MenuBarAccountRow(
                    entry: entry,
                    providerId: group.providerId,
                    accentColor: accentColor,
                    codexProxyActive: codexProxyActive,
                    codexGlobalProxyManaged: codexGlobalProxyManaged,
                    activationMessage: $activationMessage,
                    activationSuccess: $activationSuccess,
                    onRequestRestartConfirmation: onRequestRestartConfirmation
                )
                .environmentObject(appState)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.04 : 0.025))
        )
        .padding(.vertical, 2)
    }

    private var sectionHeader: some View {
        HStack(spacing: 8) {
            ProviderIconView(group.providerId, size: 16)

            Text(group.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary)

            if group.accounts.count > 1 {
                Text("\(group.accounts.count)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            if let channel = group.channel {
                Text(channel.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

// MARK: - Multi-Window Quota Bar

struct MenuBarQuotaBar: View {
    let window: QuotaWindow
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    private var isUnlimited: Bool {
        window.remainingPercent == nil
    }

    private var percent: Double {
        min(max(window.displayRemainingPercent, 0), 100)
    }

    private var barColor: Color {
        isUnlimited ? Color.secondary.opacity(0.55) : MenuBarHelpers.quotaColor(percent)
    }

    private var trackColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.06)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(window.label)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 2)

                if isUnlimited {
                    Image(systemName: "infinity")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(barColor)
                } else {
                    Text("\(Int(percent))%")
                        .font(.system(size: 8, weight: .bold, design: .rounded))
                        .foregroundStyle(barColor)
                }
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(trackColor)
                RoundedRectangle(cornerRadius: 2)
                    .fill(barColor)
                    .scaleEffect(x: isUnlimited ? 1 : max(percent / 100, 0.001), y: 1, anchor: .leading)
            }
            .frame(height: 4)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 2))

            resetLine
        }
    }

    // 额度刷新倒计时：每分钟自适应刷新，按紧急度（<1h 红 / <6h 橙）染色。
    @ViewBuilder
    private var resetLine: some View {
        if window.resetAt != nil {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let resetText = QuotaResetFormatter.compactText(
                    resetAt: window.resetAt,
                    language: appState.language,
                    now: context.date
                ) {
                    HStack(spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 7, weight: .semibold))
                        Text(resetText)
                            .font(.system(size: 8, weight: .medium, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(QuotaResetFormatter.highlightColor(
                        resetAt: window.resetAt,
                        now: context.date
                    ))
                }
            }
        }
    }
}
