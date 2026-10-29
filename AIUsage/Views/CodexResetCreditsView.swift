import SwiftUI
import QuotaBackend

/// 积分余额独立于配额百分比与重置卡，不额外发送请求。
struct CodexCreditsBalanceView: View {
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "creditcard")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(L("Credit balance", "积分余额"))
                .font(.caption)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .foregroundStyle(AppContent.secondary(colorScheme))
        .padding(.horizontal, 8)
        .frame(height: 22)
        .accessibilityElement(children: .combine)
        .help(L("Codex credits are separate from reset cards and included quota limits.", "Codex 积分独立于重置卡和套餐额度。"))
    }
}

/// 将重置卡状态观察限制在 Codex 入口，避免其他订阅卡片跟随更新。
struct CodexResetCreditsControl: View {
    let target: CodexResetCreditsCoordinator.Target
    let knownCount: Int?
    let summaryFetchedAt: String?
    let refreshUsage: () async -> Bool
    @ObservedObject private var coordinator = CodexResetCreditsCoordinator.shared
    @State private var showingDetails = false

    var body: some View {
        CodexResetCreditsEntry(count: coordinator.availableCount(for: target, summaryCount: knownCount, summaryFetchedAt: summaryFetchedAt)) {
            showingDetails = true
        }
        .popover(isPresented: $showingDetails) {
            CodexResetCreditsView(target: target, knownCount: knownCount, summaryFetchedAt: summaryFetchedAt,
                                  refreshUsage: refreshUsage, coordinator: coordinator)
        }
        .contextMenu {
            Button(L("View / use reset cards…", "查看 / 使用重置卡…")) { showingDetails = true }
        }
    }
}

/// 账号卡片与真实渲染 fixture 共用的紧凑入口；不读取明细、不触发消费。
struct CodexResetCreditsEntry: View {
    let count: Int?
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    private var hasCards: Bool { (count ?? 0) > 0 }
    private var countText: String { count.map(String.init) ?? "—" }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: "ticket")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(hasCards ? Color.indigo : AppContent.secondary(colorScheme))
                Text(L("Reset cards", "重置卡"))
                    .font(.caption.weight(.medium))
                Spacer(minLength: 8)
                Text(countText)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(hasCards ? Color.indigo.opacity(0.12) : AppSurface.chip(colorScheme), in: Capsule())
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(AppContent.tertiary(colorScheme))
            }
            .foregroundStyle(AppContent.secondary(colorScheme))
            .padding(.horizontal, 8)
            .frame(height: hasCards ? 26 : 22)
            .background((hasCards ? Color.indigo : Color.primary).opacity(isHovered ? 0.10 : (hasCards ? 0.065 : 0)),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(L("View Codex reset cards", "查看 Codex 重置卡") + " " + (count.map(String.init) ?? L("count unknown", "数量未知")))
        .help(L("View reset cards and expiration dates", "查看重置卡及到期时间"))
    }
}

struct CodexResetCreditsView: View {
    let target: CodexResetCreditsCoordinator.Target
    let knownCount: Int?
    var summaryFetchedAt: String? = nil
    let refreshUsage: () async -> Bool
    @ObservedObject var coordinator: CodexResetCreditsCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @State private var selectedCard: CodexResetCredit?
    @State private var showingConfirmation = false
    @State private var hoveredCreditID: String?

    private var state: CodexResetCreditsCoordinator.State { coordinator.state(for: target) }
    private var busy: Bool { state.isLoading || state.isConsuming || state.isRefreshing }
    private var canOperate: Bool { coordinator.canOperate(target) }
    private var availableCount: Int? {
        coordinator.availableCount(for: target, summaryCount: knownCount, summaryFetchedAt: summaryFetchedAt)
    }
    private var countText: String {
        availableCount.map { L("\($0) available", "\($0) 张可用") } ?? L("Count unknown", "数量未知")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(L("Card details", "卡片明细"))
                        .font(.caption.weight(.semibold))
                    Spacer(minLength: 4)
                    if let list = state.list {
                        Text(L("\(list.credits.count) shown", "显示 \(list.credits.count) 张明细"))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppContent.secondary(colorScheme))
                    }
                    if busy { ProgressView().controlSize(.mini).frame(width: 16, height: 16) }
                    Button { Task { await coordinator.load(target) } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .disabled(busy || !canOperate)
                    .help(L("Refresh card details only", "仅刷新卡片明细"))
                    .accessibilityLabel(L("Refresh card details", "刷新卡片明细"))
                }
                if let list = state.list, !list.credits.isEmpty {
                    creditList(list.sortedCredits)
                } else {
                    emptyState
                }
            }
            if state.listFailed {
                messageRow("exclamationmark.arrow.circlepath", state.list == nil
                    ? L("Could not load card details. Try refreshing.", "暂时无法读取明细，请刷新重试。")
                    : L("Details could not be refreshed. Last known data is shown.", "明细刷新失败，保留上次数据。"), tint: .orange)
            }
            if let message = feedback {
                messageRow(feedbackIsSuccess ? "checkmark.circle" : "exclamationmark.circle", message,
                           tint: feedbackIsSuccess ? .green : .orange)
            }
            footer
        }
        .padding(16)
        .frame(width: 410)
        .foregroundStyle(AppContent.primary(colorScheme))
        .background(AppSurface.page(colorScheme))
        .task { await coordinator.load(target) }
        .alert(L("Use this reset card?", "确认使用这张重置卡？"), isPresented: $showingConfirmation) {
            Button(L("Cancel", "取消"), role: .cancel) { selectedCard = nil }
            Button(L("Confirm use", "确认使用")) {
                guard let card = selectedCard else { return }
                selectedCard = nil
                Task { await coordinator.confirm(card, for: target, refresh: refreshUsage) }
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                Image(systemName: "ticket")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.indigo)
                    .frame(width: 28, height: 28)
                    .background(Color.indigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text(L("Reset cards", "重置卡"))
                    .font(.system(size: 15, weight: .semibold))
                Spacer(minLength: 8)
                GatewayQuietBadge(text: countText)
            }
            HStack(spacing: 6) {
                Text(target.label)
                    .font(.caption)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(target.label)
                if !canOperate { GatewayQuietBadge(text: L("View only", "只读")) }
            }
        }
    }

    private func creditList(_ cards: [CodexResetCredit]) -> some View {
        // 每行 56pt；短列表随内容收缩，超过上限才需要滚动。
        ScrollView {
            VStack(spacing: 0) {
                ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                    creditRow(card)
                    if index < cards.count - 1 {
                        Rectangle().fill(AppStroke.subtle(colorScheme)).frame(height: 1).padding(.leading, 40).padding(.trailing, 11)
                    }
                }
            }
        }
        .frame(height: min(CGFloat(cards.count * 56 + max(0, cards.count - 1)), 260))
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AppStroke.subtle(colorScheme), lineWidth: 1))
    }

    private func creditRow(_ card: CodexResetCredit) -> some View {
        let redeemed = state.redeemedCreditIDs.contains(card.id)
        let usable = coordinator.canConsume(card, for: target)
        let title = card.title?.nilIfBlank ?? L("Codex quota reset", "Codex 额度重置")
        return HStack(spacing: 9) {
            Image(systemName: "ticket")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(usable ? Color.indigo : AppContent.secondary(colorScheme))
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(usable ? AppContent.primary(colorScheme) : AppContent.secondary(colorScheme))
                    .lineLimit(1)
                    .help(title)
                Text(expiration(card) + (redeemed ? L(" · Used", " · 已使用") : (!card.canConsume(at: Date()) && (card.hasExplicitUnlimitedExpiry || card.expirationDate != nil) ? L(" · Unavailable", " · 不可使用") : "")))
                    .font(.system(size: 10))
                    .foregroundStyle(usable && expiringSoon(card) ? expiryWarningColor : AppContent.secondary(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Button(redeemed ? L("Used", "已使用") : L("Use", "使用")) { selectedCard = card; showingConfirmation = true }
                .buttonStyle(CodexResetActionButtonStyle())
                .disabled(busy || !canOperate || !usable)
        }
        .padding(.horizontal, 11)
        .frame(height: 56)
        .background(Color.indigo.opacity(hoveredCreditID == card.id ? 0.04 : 0))
        .onHover { hoveredCreditID = $0 ? card.id : nil }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: !canOperate ? "lock" : "ticket")
                .font(.system(size: 13))
                .foregroundStyle(AppContent.secondary(colorScheme))
                .frame(width: 20)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text(emptyTitle).font(.system(size: 12, weight: .medium))
                Text(emptyDetail)
                    .font(.caption2)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppSurface.card(colorScheme), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var emptyTitle: String {
        if state.isLoading { return L("Loading cards…", "正在读取卡片…") }
        if availableCount == 0 { return L("No reset cards available", "暂无可用重置卡") }
        if availableCount == nil { return L("Card count is unknown", "重置卡数量未知") }
        return L("No card details yet", "暂无卡片明细")
    }

    private var emptyDetail: String {
        if !canOperate {
            return target.isLocal
                ? L("Connect this account locally to view and use cards.", "在本机连接此账号后，可查看明细并使用。")
                : L("Remote account. Connect locally to view and use cards.", "远程账号，仅供查看；在本机连接后可操作。")
        }
        if state.isLoading { return L("Checking this account's available cards.", "正在核对此账号的可用卡片。") }
        if availableCount == 0 { return L("New cards will appear here when available.", "获得新卡后会显示在这里。") }
        return L("Refresh card details to check availability.", "刷新明细，查看可用卡片。")
    }

    private var footer: some View {
        VStack(spacing: 10) {
            Rectangle().fill(AppStroke.subtle(colorScheme)).frame(height: 1)
            HStack(spacing: 8) {
                Text(L("Only affects this account", "仅作用于此账号"))
                    .font(.caption2)
                    .foregroundStyle(AppContent.secondary(colorScheme))
                Spacer(minLength: 4)
                Button(L("Refresh account", "刷新此账号")) {
                    Task { await coordinator.retryRefresh(target, refresh: refreshUsage) }
                }
                .buttonStyle(CodexResetActionButtonStyle(accented: false))
                .disabled(busy || !canOperate)
                .help(L("Refresh this account's quota and reset cards", "刷新此账号的配额和重置卡"))
            }
        }
    }

    private func messageRow(_ icon: String, _ text: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon).frame(width: 14)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption)
        .foregroundStyle(tint)
    }

    private var confirmationMessage: String {
        let expiry = selectedCard.map { expiration($0) } ?? ""
        let scope = L("Resets this account's Codex quota windows only.", "仅重置此账号的 Codex 配额窗口。")
        return [target.label, expiry, scope].joined(separator: "\n")
    }

    private func expiration(_ card: CodexResetCredit) -> String {
        if card.hasExplicitUnlimitedExpiry { return L("Does not expire", "无到期限制") }
        guard let date = card.expirationDate else { return L("Expiry unknown · Unavailable", "到期时间未知 · 不可使用") }
        return L("Expires ", "到期 ") + date.formatted(
            Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: L("en_US", "zh_CN")))
        )
    }

    private func expiringSoon(_ card: CodexResetCredit) -> Bool {
        guard let date = card.expirationDate else { return false }
        return date > Date() && date.timeIntervalSinceNow < 7 * 86_400
    }

    private var expiryWarningColor: Color {
        colorScheme == .dark ? .orange : Color(red: 0.64, green: 0.29, blue: 0.025)
    }

    private var feedbackIsSuccess: Bool { state.errorCode == nil && state.outcome?.code == .reset && !state.refreshFailed }

    private var feedback: String? {
        if let code = state.errorCode {
            switch code {
            case "reset_ambiguous":
                return state.refreshedAfterError
                    ? L("Account data refreshed. The previous reset result is still unconfirmed; check quota and card details.", "账号数据已刷新；上次重置结果仍待确认，请核对配额和卡片明细。")
                    : L("Result unconfirmed. Refresh this account to check quota and card details.", "结果待确认，请刷新此账号，核对配额和卡片明细。")
            case "reset_card_unavailable": return L("This card is no longer available. Refresh details.", "此卡已不可使用，请刷新明细。")
            case "reset_journal_failed": return L("Could not save the operation record. No card was submitted.", "无法保存操作记录，未提交卡片。")
            default: return L("Could not submit. Check this account's local connection and refresh details.", "无法提交，请检查此账号的本地连接并刷新明细。")
            }
        }
        guard let outcome = state.outcome else {
            return state.refreshFailed ? L("Account refresh failed. Try again below.", "账号刷新失败，请在下方重试。") : nil
        }
        let result: String
        switch outcome.code {
        case .reset: result = L("Reset succeeded.", "重置成功。")
        case .nothingToReset: result = L("Nothing to reset right now.", "当前无须重置。")
        case .noCredit: result = L("No available credit for this card.", "此卡无可用重置额度。")
        case .alreadyRedeemed: result = L("This card was already used.", "此卡已使用。")
        }
        return result + (state.refreshFailed ? L(" Account refresh failed; retry below.", " 账号刷新失败，可在下方重试。") : "")
    }
}

private struct CodexResetActionButtonStyle: ButtonStyle {
    var accented = true
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(isEnabled && accented ? Color.indigo : AppContent.secondary(colorScheme))
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(isEnabled && accented ? Color.indigo.opacity(configuration.isPressed ? 0.22 : 0.10) : AppSurface.chip(colorScheme),
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
