import SwiftUI
import QuotaBackend

// MARK: - Menu Bar View (Main Container)
// Redesigned popover inspired by Quotio: status header, summary stats, multi-window quota bars, cost card, action footer.
// 轨道切换器 / 费用追踪 / 账号行 / 共享工具分别拆到 MenuBarView+*.swift、MenuBar*.swift。

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject var proxyVM = ProxyViewModel.shared
    @ObservedObject var openCodeStore = OpenCodeNodeStore.shared
    // 三条全局代理轨道各自独立观察：菜单栏切换器、Codex 账号行托管态都需要按轨实时反映。
    @ObservedObject var globalCodex = GlobalProxyManager.codex
    @ObservedObject var globalClaude = GlobalProxyManager.claude
    @ObservedObject var globalOpenCode = GlobalProxyManager.opencode
    @ObservedObject private var settings = AppSettings.shared
    @State private var activationMessage: String?
    @State private var activationSuccess = true
    // 当前展开的轨道面板（自定义内嵌覆盖层，取代原生 Menu 下拉）。nil = 全部收起。
    @State var openPanelTrack: GlobalProxyTrack?
    @State var pendingRestartPrompt: MenuBarRestartPrompt?
    @State var isConfirmingRestart = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                menuBarHeader
                Divider()
                controlDeck
                Divider()
                TokenSaverMenuBarSection(onOpenSettings: openTokenSaverSettings)
                Divider()
                quotaSection
                costTrackingSection
                MenuBarRecentSessionsSection { openMainWindow(section: .sessions) }
                Divider()
                menuBarFooter
            }
            if let track = openPanelTrack, isMenuBarTrackVisible(track) {
                trackPanelOverlay(track: track)
            }
            if let prompt = pendingRestartPrompt {
                restartConfirmationOverlay(prompt: prompt)
            }
        }
        .frame(width: 420)
        .background(VisualEffectBlur())
    }

    // 轨道顺序与侧边栏一致：Codex → OpenCode → Claude Code。被侧边栏隐藏的 agent 同步隐藏其切换器。
    private var controlDeck: some View {
        let hidden = settings.hiddenSidebarSections
        return HStack(spacing: 0) {
            compactAccountsBadge
                .frame(maxWidth: .infinity)
            if AgentVisibility.isVisible(.codex, hidden: hidden) {
                proxyTrackSwitcher(family: .codex)
                    .frame(maxWidth: .infinity)
            }
            if AgentVisibility.isVisible(.opencode, hidden: hidden) {
                openCodeTrackSwitcher()
                    .frame(maxWidth: .infinity)
            }
            if AgentVisibility.isVisible(.claude, hidden: hidden) {
                proxyTrackSwitcher(family: .claude)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var overallStatus: OverallHealthStatus {
        let hidden = settings.hiddenSidebarSections
        let groups = visibleQuotaProviderGroups
        let providers = refreshCoordinator.providers.filter {
            !AgentVisibility.isProviderHidden($0.baseProviderId, hidden: hidden)
        }
        let hasCritical = providers.contains { $0.status == .error }
        let hasWarning = providers.contains { ($0.remainingPercent ?? 100) < 35 }
        if hasCritical { return .critical }
        if hasWarning { return .warning }
        if groups.isEmpty && !refreshCoordinator.isLoading { return .idle }
        return .healthy
    }

    private var menuBarHeader: some View {
        HStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 24, height: 24)
                    .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("AIUsage")
                            .font(.system(size: 14, weight: .bold, design: .rounded))

                        Circle()
                            .fill(overallStatus.color)
                            .frame(width: 7, height: 7)
                    }

                    if let lastRefresh = refreshCoordinator.lastRefreshTime {
                        RefreshableTimeView(
                            date: lastRefresh,
                            language: appState.language,
                            font: .system(size: 10),
                            foregroundStyle: .secondary
                        )
                    } else {
                        Text(L("Not refreshed yet", "尚未刷新"))
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            Button {
                refreshCoordinator.refreshAllProviders()
            } label: {
                Group {
                    if refreshCoordinator.isAnyRefreshInProgress {
                        SmallProgressView().frame(width: 14, height: 14)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .medium))
                    }
                }
                .frame(width: 28, height: 28)
                .background(Color.primary.opacity(0.06))
                .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(refreshCoordinator.isAnyRefreshInProgress)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Compact Badges

    private var compactAccountsBadge: some View {
        let groups = visibleQuotaProviderGroups
        let totalAccounts = groups.reduce(0) { $0 + $1.accounts.count }
        let connectedAccounts = groups.reduce(0) { $0 + $1.connectedCount }

        let iconColor: Color = connectedAccounts == totalAccounts && totalAccounts > 0
            ? Color(red: 0.15, green: 0.78, blue: 0.40)
            : connectedAccounts > 0 ? .orange : .secondary

        return HStack(spacing: 4) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(iconColor)
            Text("\(connectedAccounts)/\(totalAccounts)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(connectedAccounts > 0 ? .primary : .secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
    }

    private var quotaProviderGroups: [ProviderAccountGroup] { visibleQuotaProviderGroups }

    private var visibleQuotaProviderGroups: [ProviderAccountGroup] {
        let hidden = settings.hiddenSidebarSections
        return appState.providerAccountGroups.filter { group in
            !AgentVisibility.isProviderHidden(group.providerId, hidden: hidden)
                && group.accounts.contains {
                    AgentVisibility.isQuotaAccount(
                        providerId: group.providerId,
                        category: $0.liveProvider?.category
                    )
                }
        }
    }

    private func isMenuBarTrackVisible(_ track: GlobalProxyTrack) -> Bool {
        let hidden = settings.hiddenSidebarSections
        switch track {
        case .codex: return AgentVisibility.isVisible(.codex, hidden: hidden)
        case .opencode: return AgentVisibility.isVisible(.opencode, hidden: hidden)
        case .claude, .desktop, .science: return AgentVisibility.isVisible(.claude, hidden: hidden)
        }
    }

    // MARK: - Content

    /// 账号额度区（可折叠，状态记住）。收起时只留标题行与「最低剩余」摘要。
    private var quotaSection: some View {
        VStack(spacing: 0) {
            if !quotaProviderGroups.isEmpty {
                MenuBarCollapsibleHeader(
                    title: L("Account Quota", "账号额度", "Hạn mức tài khoản"),
                    isExpanded: $settings.menuBarUsageExpanded,
                    collapsedSummary: quotaCollapsedSummary?.text,
                    summaryColor: quotaCollapsedSummary?.color ?? .secondary
                )
            }
            if settings.menuBarUsageExpanded || quotaProviderGroups.isEmpty {
                menuBarContent
            }
        }
    }

    /// 收起时的摘要：可见服务里剩余额度最低的一项。
    private var quotaCollapsedSummary: (text: String, color: Color)? {
        let hidden = settings.hiddenSidebarSections
        let lowest = refreshCoordinator.providers
            .filter {
                !AgentVisibility.isProviderHidden($0.baseProviderId, hidden: hidden)
                    && AgentVisibility.isQuotaAccount(providerId: $0.baseProviderId, category: $0.category)
            }
            .compactMap(\.remainingPercent)
            .min()
        guard let lowest else { return nil }
        let percent = Int(lowest.rounded())
        return (L("Lowest \(percent)% left", "最低剩余 \(percent)%", "Thấp nhất còn \(percent)%"), MenuBarHelpers.quotaColor(lowest))
    }

    private var menuBarContent: some View {
        Group {
            if refreshCoordinator.isLoading && refreshCoordinator.providers.isEmpty {
                VStack(spacing: 12) {
                    SmallProgressView().frame(width: 20, height: 20)
                    Text(L("Loading...", "加载中..."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if quotaProviderGroups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text(L("No providers", "暂无服务"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(quotaProviderGroups) { group in
                            MenuBarProviderSection(
                                group: group,
                                codexProxyActive: proxyVM.activatedId(isCodex: true) != nil,
                                codexGlobalProxyManaged: globalCodex.isEnabled,
                                activationMessage: $activationMessage,
                                activationSuccess: $activationSuccess,
                                onRequestRestartConfirmation: { entry in
                                    presentRestartConfirmation(for: entry)
                                }
                            )
                            .environmentObject(appState)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .frame(maxHeight: 600)
                .overlay(alignment: .bottom) {
                    if let message = activationMessage {
                        activationToast(message: message, success: activationSuccess)
                    }
                }
            }
        }
    }

    func presentRestartConfirmation(for entry: ProviderAccountEntry) {
        guard entry.providerId == "codex" || entry.providerId == "antigravity" else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            openPanelTrack = nil
            pendingRestartPrompt = MenuBarRestartPrompt(entry: entry)
        }
    }

    private func confirmAndRestartApp(for prompt: MenuBarRestartPrompt) {
        guard !isConfirmingRestart else { return }
        isConfirmingRestart = true
        Task { @MainActor in
            let ok: Bool
            var restartFailure: String?
            if prompt.providerId == "codex" {
                do {
                    try await ProviderActivationManager.shared.restartCodexApp(fallbackEntry: prompt.entry)
                    ok = true
                } catch {
                    ok = false
                    restartFailure = error.localizedDescription
                }
            } else {
                ok = await ProviderActivationManager.shared.restartAntigravityApp(fallbackEntry: prompt.entry)
            }
            isConfirmingRestart = false
            withAnimation(.easeInOut(duration: 0.2)) {
                pendingRestartPrompt = nil
                activationSuccess = ok
                if ok {
                    activationMessage = L(
                        "\(prompt.appDisplayName) restarted with \(prompt.accountLabel)",
                        "\(prompt.appDisplayName) 已使用 \(prompt.accountLabel) 重启"
                    )
                } else {
                    activationMessage = restartFailure ?? L(
                        "Could not restart \(prompt.appDisplayName) automatically. Please reopen it manually.",
                        "无法自动重启 \(prompt.appDisplayName)，请手动重新打开。"
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func restartConfirmationOverlay(prompt: MenuBarRestartPrompt) -> some View {
        let accent = MenuBarColors.accent(for: prompt.providerId)
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.32))
                .contentShape(Rectangle())
                .onTapGesture {
                    guard !isConfirmingRestart else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        pendingRestartPrompt = nil
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    ZStack(alignment: .bottomTrailing) {
                        ProviderIconView(prompt.providerId, size: 28)
                            .frame(width: 38, height: 38)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(accent.opacity(0.14))
                            )
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(accent)
                            .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
                            .offset(x: 3, y: 3)
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            prompt.providerId == "codex"
                                ? L("Restart Codex to Switch Account?", "需要重启 Codex 以切换账号")
                                : L("Restart Antigravity to Switch Account?", "需要重启 Antigravity 以切换账号")
                        )
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.primary)

                        HStack(spacing: 5) {
                            Circle()
                                .fill(.green)
                                .frame(width: 6, height: 6)
                            Text(prompt.accountLabel)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: 0)
                }

                Text(
                    prompt.providerId == "codex"
                        ? L(
                            "Credentials for \"\(prompt.accountLabel)\" are now active. Please confirm to restart Codex so the selected account takes effect immediately.",
                            "账号“\(prompt.accountLabel)”已设为当前激活。请确认重启 Codex 客户端，使所选账号立即生效。"
                        )
                        : L(
                            "Credentials for \"\(prompt.accountLabel)\" are now active. Please confirm to restart Antigravity.app so the selected account takes effect immediately.",
                            "账号“\(prompt.accountLabel)”已设为当前激活。请确认重启 Antigravity.app，使所选账号立即生效。"
                        )
                )
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            pendingRestartPrompt = nil
                        }
                    } label: {
                        Text(L("Later", "稍后手动重启"))
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.primary.opacity(0.08))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConfirmingRestart)

                    Button {
                        confirmAndRestartApp(for: prompt)
                    } label: {
                        HStack(spacing: 5) {
                            if isConfirmingRestart {
                                SmallProgressView().frame(width: 12, height: 12)
                            } else {
                                Image(systemName: "arrow.clockwise.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            Text(
                                isConfirmingRestart
                                    ? L("Restarting…", "正在重启…")
                                    : (prompt.providerId == "codex"
                                        ? L("Restart Codex", "确认并重启 Codex")
                                        : L("Restart Antigravity", "确认并重启 AGY"))
                            )
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(accent)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(isConfirmingRestart)
                }
            }
            .padding(16)
            .frame(width: 344)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(accent.opacity(0.35), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.32), radius: 20, y: 8)
            .transition(.scale(scale: 0.95).combined(with: .opacity))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .zIndex(20)
    }

    private func activationToast(message: String, success: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(success ? .green : .red)
                .font(.system(size: 12))
            Text(message)
                .font(.system(size: 11))
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
        .padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task(id: message) {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) {
                if activationMessage == message {
                    activationMessage = nil
                }
            }
        }
    }

    // MARK: - Footer

    private var menuBarFooter: some View {
        HStack(spacing: 6) {
            footerButton(L("Open AIUsage", "打开 AIUsage"), shortcut: "⌘O") {
                openMainWindow(section: .dashboard)
            }

            Spacer()

            footerButton(L("Refresh", "刷新"), shortcut: "⌘R") {
                refreshCoordinator.refreshAllProviders()
            }

            footerButton(L("Quit", "退出"), shortcut: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func footerButton(_ title: String, shortcut: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                Text(shortcut)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.04))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }

    private func openTokenSaverSettings() {
        CLIProxyGatewayNavigation.shared.showSettings(destination: .tokenSaver)
        openMainWindow(section: .subscriptionGateway)
    }

    private func openMainWindow(section: AppSection) {
        if let appDelegate = NSApp.delegate as? AppDelegate {
            appDelegate.revealMainWindow(section: section)
        } else {
            appState.presentMainWindow(section: section)
        }
    }

    func formatCostCompact(_ usd: Double) -> String { MenuBarHelpers.formatCostCompact(usd) }
}

// MARK: - Token Saver Menu Bar Quick Controls

struct TokenSaverMenuBarSection: View {
    @StateObject private var saver: TokenSaverSettingsController
    private let onOpenSettings: () -> Void

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        rtk: TokenSaverReleaseRTK = .init(),
        onOpenSettings: @escaping () -> Void
    ) {
        _saver = StateObject(wrappedValue: TokenSaverSettingsController(home: home, rtk: rtk))
        self.onOpenSettings = onOpenSettings
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.purple)
                Text(L("Token Saver", "Token 节省"))
                    .font(.system(size: 11, weight: .semibold))
                let count = saver.settings.enabledToolCount
                TokenSaverStatusBadge(
                    text: count > 0 ? L("Enabled \(count)/3", "已启用 \(count)/3") : L("Off", "已关闭"),
                    tone: count > 0 ? .active : .neutral,
                    id: "menubar-token-saver-badge"
                )
                Spacer(minLength: 4)
                Button(action: onOpenSettings) {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 10, weight: .semibold))
                        Text(L("Settings", "设置"))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.05), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Open Token Saver settings", "打开 Token 节省设置"))
                .accessibilityIdentifier("menubar-token-saver-open-settings")
            }

            HStack(spacing: 6) {
                toolPill(
                    title: "RTK",
                    isOn: saver.settings.rtkEnabled,
                    id: "menubar-token-saver-rtk"
                ) {
                    saver.mutate { $0.rtkEnabled.toggle() }
                }

                toolPill(
                    title: "Caveman",
                    isOn: saver.settings.cavemanEnabled,
                    id: "menubar-token-saver-caveman"
                ) {
                    saver.mutate { $0.cavemanEnabled.toggle() }
                }

                Menu {
                    ForEach(TokenSaverSettings.CavemanMode.allCases, id: \.self) { mode in
                        Button {
                            saver.mutate { $0.cavemanMode = mode }
                        } label: {
                            HStack {
                                Text(mode.rawValue.capitalized)
                                if saver.settings.cavemanMode == mode {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    Text(saver.settings.cavemanMode.rawValue.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!saver.settings.cavemanEnabled)
                .accessibilityLabel(L("Caveman mode", "Caveman 模式"))
                .accessibilityValue(saver.settings.cavemanMode.rawValue.capitalized)
                .accessibilityIdentifier("menubar-token-saver-caveman-mode")

                toolPill(
                    title: "Ponytail",
                    isOn: saver.settings.ponytailEnabled,
                    id: "menubar-token-saver-ponytail"
                ) {
                    saver.mutate { $0.ponytailEnabled.toggle() }
                }

                Spacer(minLength: 0)
            }

            if let error = saver.localizedError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menubar-token-saver-error")
            } else if let notice = saver.notice {
                Text(notice)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menubar-token-saver-notice")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("menubar-token-saver-section")
    }

    private func toolPill(title: String, isOn: Bool, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isOn ? Color.green : Color.secondary)
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isOn ? Color.primary : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3.5)
            .background(
                Capsule()
                    .fill(isOn ? Color.green.opacity(0.14) : Color.primary.opacity(0.05))
                    .overlay(
                        Capsule()
                            .strokeBorder(isOn ? Color.green.opacity(0.35) : Color.primary.opacity(0.10), lineWidth: 0.75)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? L("On", "已开启") : L("Off", "已关闭"))
        .accessibilityIdentifier(id)
    }
}

// MARK: - Overall Health Status

private enum OverallHealthStatus {
    case healthy, warning, critical, idle

    var color: Color {
        switch self {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .idle: return .gray
        }
    }
}

struct MenuBarRestartPrompt: Identifiable, Equatable {
    let entry: ProviderAccountEntry

    var id: String { "\(entry.providerId):\(entry.id)" }
    var providerId: String { entry.providerId }

    static func == (lhs: MenuBarRestartPrompt, rhs: MenuBarRestartPrompt) -> Bool {
        lhs.id == rhs.id && lhs.accountLabel == rhs.accountLabel
    }

    var accountLabel: String {
        if let email = entry.accountEmail?.nilIfBlank { return email }
        if let name = entry.accountDisplayName?.nilIfBlank { return name }
        return entry.accountPrimaryLabel
    }

    var appDisplayName: String {
        providerId == "codex" ? "Codex" : "Antigravity.app"
    }
}

#Preview {
    MenuBarView()
        .environmentObject(AppState.shared)
        .environmentObject(ProviderRefreshCoordinator.shared)
        .environmentObject(ProviderActivationManager.shared)
}
