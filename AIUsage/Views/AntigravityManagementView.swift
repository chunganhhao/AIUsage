import SwiftUI
import Combine
import AppKit
import QuotaBackend

// MARK: - Antigravity Subscription Order Store
// Persists custom drag-and-drop ordering of Antigravity accounts in UserDefaults,
// mirroring CodexSubscriptionOrderStore.

@MainActor
final class AntigravitySubscriptionOrderStore: ObservableObject {
    static let shared = AntigravitySubscriptionOrderStore()

    @Published private(set) var order: [String]
    private let key = "antigravitySubscriptionOrder"

    private init() {
        order = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func ordered(_ entries: [ProviderAccountEntry]) -> [ProviderAccountEntry] {
        guard !order.isEmpty else { return entries }
        let rank = Dictionary(order.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { a, _ in a })
        return entries.enumerated().sorted { lhs, rhs in
            switch (rank[lhs.element.id], rank[rhs.element.id]) {
            case let (l?, r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    func reorder(_ displayedIds: [String]) {
        let extra = order.filter { !displayedIds.contains($0) }
        order = displayedIds + extra
        UserDefaults.standard.set(order, forKey: key)
    }
}

// MARK: - Antigravity Management View
// Dedicated sidebar management hub for Google Antigravity (AGY), aligned with CodexProxyManagementView:
//   1. Action Bar: GEMINI.md & mcp_config.json editors, Restart AGY, Refresh Quotas, + Add Account
//   2. 6 Summary Stat Cards: Accounts, Active Account, Active Min Quota, Today Tokens, All-Time Tokens, Brain Sessions
//   3. Smart Pool Protection & TOS-Safe Mode Card
//   4. Token Saver & AGY Customization Card (RTK, Caveman, Ponytail, MCP & Skills counters)
//   5. Account List with drag-and-drop reorder & 1-click Switch Account toggle (state.vscdb + ~/.gemini sync)

struct AntigravityManagementView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject private var activation = ProviderActivationManager.shared
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var tokenSaver = TokenSaverSettingsController()
    @State private var envSummary = AntigravityAccountSwitcher.inspectEnvironment()
    @State private var poolProtectionEnabled = AntigravityPoolProtectionSettings.isEnabled()
    @State private var poolProtectionResidual = false
    @State private var poolProtectionError: String?

    @State private var showingAddAccount = false
    @State private var editingConfigFile: AntigravityEditableFile?
    @State private var isRestartingAGY = false
    @State private var statusBannerMessage: String?
    @State private var statusBannerIsError = false

    static let brand = Color(red: 0.20, green: 0.75, blue: 0.95)

    private var antigravityEntries: [ProviderAccountEntry] {
        appState.providerAccountGroups.first { $0.providerId == "antigravity" }?.accounts ?? []
    }

    private var costProvider: ProviderData? {
        refreshCoordinator.providers.first { $0.baseProviderId == "antigravity-cost" }
    }

    private var activeEntry: ProviderAccountEntry? {
        antigravityEntries.first { activation.isActiveAccount($0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                actionBar
                if let banner = statusBannerMessage {
                    statusBanner(banner, isError: statusBannerIsError)
                }
                summaryStrip
                poolProtectionCard
                tokenSaverCard
                AntigravitySubscriptionSection(
                    entries: antigravityEntries,
                    isAppInstalled: envSummary.isAppInstalled,
                    onAddAccount: { showingAddAccount = true },
                    onRestartApp: { restartAntigravity() },
                    onShowStatus: { message, isError in
                        withAnimation(.easeInOut(duration: 0.2)) {
                            statusBannerMessage = message
                            statusBannerIsError = isError
                        }
                    }
                )
            }
            .padding(20)
        }
        .appPageChrome(colorScheme)
        .onAppear {
            reloadState()
        }
        .task {
            await tokenSaver.performInitialCheckIfNeeded()
        }
        .sheet(isPresented: $showingAddAccount) {
            ProviderAccountEditorView(providerId: "antigravity")
                .environmentObject(appState)
                .environmentObject(refreshCoordinator)
        }
        .sheet(item: $editingConfigFile) { file in
            AntigravityConfigFileEditorSheet(file: file) {
                envSummary = AntigravityAccountSwitcher.inspectEnvironment()
            }
        }
    }

    private func reloadState() {
        if tokenSaver.harness != .antigravity {
            tokenSaver.selectHarness(.antigravity)
        }
        envSummary = AntigravityAccountSwitcher.inspectEnvironment()
        activation.detectActiveAntigravityAccount()
        poolProtectionEnabled = AntigravityPoolProtectionSettings.isEnabled()
        do {
            poolProtectionResidual = try AntigravityPoolProtectionSettings.hasResidualProtection()
            poolProtectionError = nil
        } catch {
            poolProtectionError = error.localizedDescription
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                geminiRulesFileButton
                mcpConfigFileButton
                restartAGYButton

                Spacer(minLength: 16)

                refreshQuotasButton
                addAccountButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    geminiRulesFileButton
                    mcpConfigFileButton
                    restartAGYButton
                    Spacer(minLength: 0)
                }
                HStack(spacing: 10) {
                    refreshQuotasButton
                    Spacer(minLength: 8)
                    addAccountButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AppSurface.card(colorScheme).opacity(colorScheme == .dark ? 0.78 : 1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private var geminiRulesFileButton: some View {
        actionBarButton(
            title: "GEMINI.md",
            icon: "doc.text.magnifyingglass",
            role: .file,
            help: L("Open ~/.gemini/GEMINI.md global instructions.", "打开 ~/.gemini/GEMINI.md 全局指令文件。")
        ) {
            editingConfigFile = .geminiRules(path: envSummary.geminiRulesPath)
        }
    }

    private var mcpConfigFileButton: some View {
        actionBarButton(
            title: "mcp_config.json",
            icon: "server.rack",
            role: .file,
            help: L("Open Antigravity MCP server configuration.", "打开 Antigravity MCP 服务器配置文件。")
        ) {
            editingConfigFile = .mcpConfig(path: envSummary.mcpConfigPath)
        }
    }

    private var restartAGYButton: some View {
        actionBarButton(
            title: isRestartingAGY
                ? L("Restarting…", "正在重启…")
                : L("Restart AGY", "重启 AGY"),
            icon: isRestartingAGY ? nil : "arrow.clockwise.circle.fill",
            role: .secondary,
            help: L(
                "Gracefully quit and reopen Antigravity.app to load the newly switched account.",
                "平滑退出并重新打开 Antigravity.app 以加载新切换的账号。"
            )
        ) {
            restartAntigravity()
        }
        .disabled(isRestartingAGY || !envSummary.isAppInstalled)
    }

    private var refreshQuotasButton: some View {
        let refreshing = refreshCoordinator.isProviderRefreshInFlight("antigravity")
        return actionBarButton(
            title: refreshing ? L("Refreshing…", "刷新中…") : L("Refresh Quotas", "刷新配额"),
            icon: refreshing ? nil : "arrow.triangle.2.circlepath",
            role: .secondary,
            help: L("Refresh quota windows for all Antigravity accounts.", "刷新所有 Antigravity 账号的配额窗口。")
        ) {
            refreshCoordinator.refreshProvider("antigravity")
            refreshCoordinator.refreshProvider("antigravity-cost")
        }
        .disabled(refreshing)
    }

    private var addAccountButton: some View {
        actionBarButton(
            title: L("Add Account", "添加账号"),
            icon: "plus.circle.fill",
            role: .primary,
            help: L("Connect a Google Antigravity account via OAuth, IDE session, or auth file.", "通过 Google OAuth、IDE 会话或认证文件添加 Antigravity 账号。")
        ) {
            showingAddAccount = true
        }
    }

    private func restartAntigravity() {
        guard !isRestartingAGY else { return }
        isRestartingAGY = true
        Task { @MainActor in
            let ok = await AntigravityAccountSwitcher.restartAntigravityApp()
            isRestartingAGY = false
            envSummary = AntigravityAccountSwitcher.inspectEnvironment()
            withAnimation(.easeInOut(duration: 0.2)) {
                statusBannerIsError = !ok
                statusBannerMessage = ok
                    ? L("Antigravity.app restarted with the active account.", "Antigravity.app 已使用当前激活账号重启。")
                    : L("Could not restart Antigravity.app automatically. Please reopen it manually.", "无法自动重启 Antigravity.app，请手动重新打开。")
            }
        }
    }

    private enum ActionButtonRole {
        case secondary
        case file
        case primary
    }

    private func actionBarButton(
        title: String,
        icon: String?,
        role: ActionButtonRole,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 14)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 14)
                }
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(role == .primary ? Color.white : (role == .file ? Self.brand : Color.primary))
            .padding(.horizontal, 11)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        role == .primary
                            ? Color.accentColor
                            : (role == .file
                                ? Self.brand.opacity(colorScheme == .dark ? 0.18 : 0.10)
                                : (colorScheme == .dark ? Color.white.opacity(0.075) : Color.primary.opacity(0.045)))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(
                        role == .primary
                            ? Color.white.opacity(0.16)
                            : (role == .file ? Self.brand.opacity(0.28) : Color.primary.opacity(0.09)),
                        lineWidth: 0.5
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func statusBanner(_ message: String, isError: Bool) -> some View {
        let tint: Color = isError ? .red : .green
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            if !isError && envSummary.isAppInstalled {
                Button(L("Restart AGY Now", "立即重启 AGY")) {
                    restartAntigravity()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    statusBannerMessage = nil
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(tint.opacity(0.28), lineWidth: 1)
        )
    }

    // MARK: - 6 Summary Stat Cards

    private var summaryStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            summaryCell(
                icon: "person.2.fill",
                title: L("Accounts", "账号数"),
                value: "\(antigravityEntries.count)",
                tint: Self.brand
            )
            summaryCell(
                icon: "checkmark.seal.fill",
                title: L("Active Account", "当前激活"),
                value: activeAccountShortLabel,
                tint: .green
            )
            summaryCell(
                icon: "gauge.with.dots.needle.67percent",
                title: L("Active Min Quota", "当前最低配额"),
                value: activeMinQuotaLabel,
                tint: .purple
            )
            summaryCell(
                icon: "bolt.fill",
                title: L("Today Tokens", "今日 Tokens"),
                value: todayTokensLabel,
                tint: .orange
            )
            summaryCell(
                icon: "chart.bar.fill",
                title: L("Total Tokens", "累计 Tokens"),
                value: overallTokensLabel,
                tint: .pink
            )
            summaryCell(
                icon: "brain.head.profile",
                title: L("Brain Sessions", "本地会话数"),
                value: "\(envSummary.brainSessionCount)",
                tint: .indigo
            )
        }
    }

    private var activeAccountShortLabel: String {
        if let active = activeEntry {
            let label = active.accountPrimaryLabel
            return label.components(separatedBy: "@").first ?? label
        }
        if let detected = AntigravityAccountSwitcher.detectActiveAccount()?.email {
            return detected.components(separatedBy: "@").first ?? detected
        }
        return L("None", "未激活")
    }

    private var activeMinQuotaLabel: String {
        let target = activeEntry ?? antigravityEntries.first
        guard let windows = target?.liveProvider?.windows, !windows.isEmpty else {
            if let pct = target?.liveProvider?.remainingPercent {
                return "\(Int(pct.rounded()))%"
            }
            return "—"
        }
        let values = windows.compactMap(\.remainingPercent)
        guard let minVal = values.min() else { return "—" }
        return "\(Int(minVal.rounded()))%"
    }

    private var todayTokensLabel: String {
        guard let tokens = costProvider?.costSummary?.today?.tokens else { return "0" }
        return formatCompactNumber(Double(tokens))
    }

    private var overallTokensLabel: String {
        if let tokens = costProvider?.costSummary?.overall?.tokens {
            return formatCompactNumber(Double(tokens))
        }
        if let monthTokens = costProvider?.costSummary?.month?.tokens {
            return formatCompactNumber(Double(monthTokens))
        }
        return "0"
    }

    private func summaryCell(icon: String, title: String, value: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(Circle().fill(tint.opacity(0.12)))

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    // MARK: - Smart Pool Protection & TOS-Safe Mode Card

    private var poolProtectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L("Smart Pool Protection & TOS Safety", "智能分池保护与账号安全策略"))
                            .font(.subheadline.weight(.semibold))
                        poolProtectionBadge
                        tosSafeBadge
                    }
                    Text(L(
                        "Isolates depleted Claude, Gemini Pro/Flash or Argon pools without locking the whole account. TOS-safe defaults keep project-switching and credit flags disabled.",
                        "当 Claude、Gemini Pro/Flash 或 Argon 单个模型池耗尽时仅隔离该池，不停用整号；默认关闭跨项目切换与积分实验标志以保护账号安全。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: Binding(
                    get: { poolProtectionEnabled },
                    set: { enabled in
                        do {
                            try AntigravityPoolProtectionSettings.setEnabled(enabled)
                            reloadState()
                        } catch {
                            poolProtectionEnabled = AntigravityPoolProtectionSettings.isEnabled()
                            poolProtectionResidual = (try? AntigravityPoolProtectionSettings.hasResidualProtection()) ?? poolProtectionResidual
                            poolProtectionError = error.localizedDescription
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(.purple)
            }

            if !poolProtectionEnabled && poolProtectionResidual {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(L("Previous pool protection exclusions remain on disk.", "磁盘上仍保留有之前的分池排除规则。"))
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Button(L("Restore Exclusions", "清理残留规则")) {
                        do {
                            try AntigravityPoolProtectionSettings.restorePreviousExclusions()
                            reloadState()
                        } catch {
                            poolProtectionError = error.localizedDescription
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }

            if let poolProtectionError {
                Text(poolProtectionError)
                    .font(.caption2)
                    .foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var poolProtectionBadge: some View {
        if poolProtectionError != nil {
            TokenSaverStatusBadge(text: L("Issue", "异常"), tone: .danger, id: "agy-pool-protection-badge")
        } else if poolProtectionEnabled {
            TokenSaverStatusBadge(text: L("Pool Breaker ON", "分池保护已开启"), tone: .active, id: "agy-pool-protection-badge")
        } else if poolProtectionResidual {
            TokenSaverStatusBadge(text: L("Off · Residual", "已关 · 有残留"), tone: .warning, id: "agy-pool-protection-badge")
        } else {
            TokenSaverStatusBadge(text: L("Pool Breaker OFF", "分池保护关闭"), tone: .neutral, id: "agy-pool-protection-badge")
        }
    }

    private var tosSafeBadge: some View {
        TokenSaverStatusBadge(
            text: L("TOS-Safe Defaults", "防封安全策略已锁"),
            tone: .active,
            id: "agy-tos-safe-badge"
        )
    }

    // MARK: - Token Saver & AGY Customization Card

    private var tokenSaverCard: some View {
        let agySnapshot = tokenSaver.onboarding
        let enabledCount = tokenSaver.settings.enabledToolCount

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.brand)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L("Token Saver & AGY Customization", "Token 节省与 AGY 环境配置"))
                            .font(.subheadline.weight(.semibold))
                        TokenSaverStatusBadge(
                            text: enabledCount > 0
                                ? L("Enabled \(enabledCount)/3", "已启用 \(enabledCount)/3")
                                : L("Off", "已关闭"),
                            tone: enabledCount > 0 ? .active : .neutral,
                            id: "agy-token-saver-badge"
                        )
                    }
                    Text(L(
                        "Manages RTK command compression, Caveman concise responses, and Ponytail minimal-code rules in ~/.gemini/GEMINI.md.",
                        "管理 ~/.gemini/GEMINI.md 中的 RTK 命令输出压缩、Caveman 精简回复与 Ponytail 极简代码规则。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L("Reapply Rules", "重新写入规则")) {
                    tokenSaver.reapply()
                    envSummary = AntigravityAccountSwitcher.inspectEnvironment()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { tokenSaver.settings.rtkEnabled },
                    set: { val in tokenSaver.mutate { $0.rtkEnabled = val } }
                )) {
                    Text("RTK CLI")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Toggle(isOn: Binding(
                    get: { tokenSaver.settings.cavemanEnabled },
                    set: { val in tokenSaver.mutate { $0.cavemanEnabled = val } }
                )) {
                    Text("Caveman")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Picker("", selection: Binding(
                    get: { tokenSaver.settings.cavemanMode },
                    set: { mode in tokenSaver.mutate { $0.cavemanMode = mode } }
                )) {
                    ForEach(TokenSaverSettings.CavemanMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
                .disabled(!tokenSaver.settings.cavemanEnabled)

                Toggle(isOn: Binding(
                    get: { tokenSaver.settings.ponytailEnabled },
                    set: { val in tokenSaver.mutate { $0.ponytailEnabled = val } }
                )) {
                    Text("Ponytail")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()
            }

            HStack(spacing: 8) {
                envPill(
                    icon: "doc.badge.gearshape",
                    text: agyRulesStatusText(agySnapshot?.rules)
                )
                envPill(
                    icon: "server.rack",
                    text: L("MCP Servers: \(envSummary.mcpServerCount)", "MCP 服务: \(envSummary.mcpServerCount)")
                )
                envPill(
                    icon: "sparkles.rectangle.stack",
                    text: L("Skills: \(envSummary.skillCount)", "技能数: \(envSummary.skillCount)")
                )
                envPill(
                    icon: "macwindow",
                    text: envSummary.isAppInstalled
                        ? "Antigravity.app \(envSummary.appVersion.map { "v\($0)" } ?? "") · \(envSummary.isAppRunning ? L("Running", "运行中") : L("Stopped", "未运行"))"
                        : L("Antigravity.app Not Found", "未检测到 Antigravity.app")
                )
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
    }

    private func agyRulesStatusText(_ state: TokenSaverOnboarding.RulesState?) -> String {
        switch state {
        case .current: return L("GEMINI.md: Synced", "GEMINI.md: 已同步")
        case .stale: return L("GEMINI.md: Needs Reapply", "GEMINI.md: 待更新")
        case .missing: return L("GEMINI.md: Missing", "GEMINI.md: 未创建")
        case .off: return L("GEMINI.md: Rules Off", "GEMINI.md: 已关闭")
        default: return "GEMINI.md"
        }
    }

    private func envPill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(Color.primary.opacity(0.05)))
    }
}

// MARK: - Antigravity Account List Section (Unified Switcher)

struct AntigravitySubscriptionSection: View {
    let entries: [ProviderAccountEntry]
    let isAppInstalled: Bool
    let onAddAccount: () -> Void
    let onRestartApp: () -> Void
    let onShowStatus: (String, Bool) -> Void

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject private var activation = ProviderActivationManager.shared
    @ObservedObject private var orderStore = AntigravitySubscriptionOrderStore.shared
    @Environment(\.colorScheme) private var colorScheme

    @State private var draggingId: String?
    @State private var dragTranslation: CGFloat = 0
    @State private var rowHeights: [String: CGFloat] = [:]
    @State private var editingNoteEntry: ProviderAccountEntry?
    @State private var pendingDeleteEntry: ProviderAccountEntry?

    private let rowSpacing: CGFloat = 8
    private let fallbackRowHeight: CGFloat = 68
    private static let antigravityBrand = AntigravityManagementView.brand

    var body: some View {
        let ordered = orderStore.ordered(entries)
        let ids = ordered.map(\.id)
        let srcIdx = draggingId.flatMap { ids.firstIndex(of: $0) }
        let target = srcIdx.map { computeTarget(ids: ids, srcIdx: $0, translation: dragTranslation) }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProviderIconView("antigravity", size: 16)
                Text(L("Account List", "账号列表"))
                    .font(.headline.weight(.bold))
                if !ordered.isEmpty {
                    Text("\(ordered.count)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.primary.opacity(0.06)))
                }
                Spacer()
                Text(AntigravityAccountSwitcher.activeStorageDisplayPath())
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if ordered.isEmpty {
                emptyAccountList
            } else {
                LazyVStack(spacing: rowSpacing) {
                    ForEach(Array(ordered.enumerated()), id: \.element.id) { index, entry in
                        let isDragging = draggingId == entry.id
                        subscriptionRow(entry)
                            .background {
                                if draggingId != nil {
                                    rowHeightReader(for: entry.id)
                                }
                            }
                            .offset(y: rowOffset(index: index, id: entry.id, srcIdx: srcIdx, target: target))
                            .scaleEffect(isDragging ? 1.02 : 1, anchor: .center)
                            .shadow(color: .black.opacity(isDragging ? 0.22 : 0),
                                    radius: isDragging ? 9 : 0, y: isDragging ? 5 : 0)
                            .zIndex(isDragging ? 1 : 0)
                            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.82), value: target)
                            .animation(.interactiveSpring(response: 0.30, dampingFraction: 0.85), value: draggingId)
                    }
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18)
                .fill(AppSurface.card(colorScheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18)
                .stroke(AppStroke.card(colorScheme), lineWidth: 1)
        )
        .onPreferenceChange(AntigravityRowHeightKey.self) { heights in
            guard draggingId != nil, rowHeights != heights else { return }
            rowHeights = heights
        }
        .onChange(of: draggingId) { _, id in
            if id == nil, !rowHeights.isEmpty {
                rowHeights.removeAll()
            }
        }
        .sheet(item: $editingNoteEntry) { entry in
            AccountNoteEditorView(
                providerTitle: entry.providerTitle,
                accountLabel: entry.accountPrimaryLabel,
                note: entry.accountNote
            ) { updatedNote in
                appState.updateAccountNote(for: entry, note: updatedNote)
            }
            .environmentObject(appState)
        }
        .alert(
            L("Remove Account?", "确认移除账号？"),
            isPresented: Binding(
                get: { pendingDeleteEntry != nil },
                set: { if !$0 { pendingDeleteEntry = nil } }
            ),
            presenting: pendingDeleteEntry
        ) { entry in
            Button(L("Remove", "移除"), role: .destructive) {
                appState.deleteAccount(entry)
                pendingDeleteEntry = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                pendingDeleteEntry = nil
            }
        } message: { entry in
            Text(L(
                "Remove \"\(entry.accountPrimaryLabel)\" from AIUsage? Local Antigravity IDE sessions will not be deleted.",
                "从 AIUsage 移除“\(entry.accountPrimaryLabel)”？不会删除本地 Antigravity IDE 会话。"
            ))
        }
    }

    private var emptyAccountList: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(L("No Antigravity accounts connected yet", "尚未连接 Antigravity 账号"))
                .font(.subheadline.weight(.semibold))
            Text(L(
                "Add multiple Google Antigravity accounts here to monitor 5-hour / weekly model pools and switch accounts in 1 click without signing in through the browser again.",
                "在此添加多个 Google Antigravity 账号，即可监控 5 小时/每周模型池配额，并一键切换账号，无需再次打开浏览器登录。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)

            Button {
                onAddAccount()
            } label: {
                Label(L("Connect Antigravity Account", "连接 Antigravity 账号"), systemImage: "plus.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private func rowHeightReader(for id: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: AntigravityRowHeightKey.self, value: [id: geo.size.height])
        }
    }

    // MARK: - Reorder Geometry

    private func stride(of id: String) -> CGFloat {
        (rowHeights[id] ?? fallbackRowHeight) + rowSpacing
    }

    private func baseCenters(ids: [String]) -> [CGFloat] {
        var centers: [CGFloat] = []
        var top: CGFloat = 0
        for id in ids {
            let h = (rowHeights[id] ?? fallbackRowHeight)
            centers.append(top + h / 2)
            top += h + rowSpacing
        }
        return centers
    }

    private func computeTarget(ids: [String], srcIdx: Int, translation: CGFloat) -> Int {
        guard !ids.isEmpty else { return srcIdx }
        let centers = baseCenters(ids: ids)
        let draggedCenter = centers[srcIdx] + translation
        var t = srcIdx
        while t < ids.count - 1 && draggedCenter > centers[t + 1] { t += 1 }
        while t > 0 && draggedCenter < centers[t - 1] { t -= 1 }
        return t
    }

    private func rowOffset(index: Int, id: String, srcIdx: Int?, target: Int?) -> CGFloat {
        if id == draggingId { return dragTranslation }
        guard let srcIdx, let target, let dragId = draggingId else { return 0 }
        let step = stride(of: dragId)
        if target > srcIdx, index > srcIdx, index <= target { return -step }
        if target < srcIdx, index >= target, index < srcIdx { return step }
        return 0
    }

    private func dragGesture(for entry: ProviderAccountEntry) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                if draggingId != entry.id { draggingId = entry.id }
                dragTranslation = value.translation.height
            }
            .onEnded { _ in commitDrag() }
    }

    private func commitDrag() {
        defer {
            draggingId = nil
            dragTranslation = 0
        }
        guard let id = draggingId else { return }
        let ids = orderStore.ordered(entries).map(\.id)
        guard let srcIdx = ids.firstIndex(of: id) else { return }
        let target = computeTarget(ids: ids, srcIdx: srcIdx, translation: dragTranslation)
        guard target != srcIdx else { return }
        var newOrder = ids
        newOrder.remove(at: srcIdx)
        newOrder.insert(id, at: min(max(target, 0), newOrder.count))
        withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.85)) {
            orderStore.reorder(newOrder)
        }
    }

    // MARK: - Row Subviews

    @ViewBuilder
    private func planBadge(_ label: String) -> some View {
        let tint = membershipBadgeTint(for: label)
        Text(label)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .overlay(Capsule().stroke(tint.opacity(0.30), lineWidth: 1))
    }

    private func noteRow(_ entry: ProviderAccountEntry) -> some View {
        Button {
            editingNoteEntry = entry
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "pencil")
                    .font(.system(size: 9))
                if let note = entry.accountNote?.nilIfBlank {
                    Text(note)
                        .lineLimit(1)
                        .truncationMode(.tail)
                } else {
                    Text(L("Add note", "添加备注"))
                        .italic()
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Edit note", "编辑备注"))
    }

    @ViewBuilder
    private func usageWindowPills(_ entry: ProviderAccountEntry) -> some View {
        let windows = entry.liveProvider?.windows ?? []
        if !windows.isEmpty {
            FlowLayoutPills(windows: Array(windows.prefix(6)), renderPill: { usagePill($0) })
                .padding(.top, 1)
        }
    }

    private func usagePill(_ window: QuotaWindow) -> some View {
        let shortLabel = window.label.replacingOccurrences(of: " Window", with: "")
        let remaining = window.remainingPercent
        let tint: Color = {
            guard let remaining else { return .secondary }
            if remaining > 50 { return .green }
            if remaining > 20 { return .orange }
            return .red
        }()
        return HStack(spacing: 3) {
            Text(shortLabel)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            if let remaining {
                Text("\(Int(remaining.rounded()))%")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
            } else {
                Image(systemName: "infinity")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(tint.opacity(0.12)))
        .help("\(window.label): \(window.value)\(window.note.nilIfBlank.map { " · \($0)" } ?? "")")
    }

    private func partiallyDepletedPoolLabel(for provider: ProviderData?) -> String? {
        guard let windows = provider?.windows, windows.count > 1 else { return nil }
        let depleted = windows.filter { ($0.remainingPercent ?? 100) <= 0 }
        let available = windows.filter { ($0.remainingPercent ?? 0) > 0 }
        guard let firstDepleted = depleted.first, !available.isEmpty else { return nil }
        return firstDepleted.label.replacingOccurrences(of: " Window", with: "")
    }

    @ViewBuilder
    private func subscriptionRow(_ entry: ProviderAccountEntry) -> some View {
        let isActive = activation.isActiveAccount(entry)
        let trippedPool = partiallyDepletedPoolLabel(for: entry.liveProvider)
        let partialTripped = trippedPool != nil

        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(draggingId == entry.id ? .primary : .tertiary)
                .frame(width: 22, height: 30)
                .contentShape(Rectangle())
                .help(L("Drag to reorder", "拖动可排序"))
                .onHover { hovering in
                    if hovering { NSCursor.openHand.push() } else { NSCursor.pop() }
                }
                .gesture(dragGesture(for: entry))

            ProviderIconView("antigravity", size: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.accountPrimaryLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let plan = entry.liveProvider?.membershipLabel?.nilIfBlank {
                        planBadge(plan)
                    }
                    if isActive {
                        Text(L("IDE Active", "当前生效"))
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Self.antigravityBrand)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Self.antigravityBrand.opacity(0.14)))
                    }
                    if partialTripped {
                        Text(trippedPool.map { L("Pool Protected: \($0)", "池保护: \($0)") } ?? L("Pool Protected", "分池保护中"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.orange)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1.5)
                            .background(Capsule().fill(Color.orange.opacity(0.14)))
                    }
                }
                noteRow(entry)
                usageWindowPills(entry)
            }

            Spacer(minLength: 8)

            if activation.isRemoteViewOnly(entry) {
                GatewayQuietBadge(text: ProviderActivationManager.remoteViewOnlyLabel)
            } else {
                Toggle("", isOn: Binding(
                    get: { isActive },
                    set: { newValue in
                        if newValue {
                            do {
                                try activation.activateAccount(entry: entry)
                                onShowStatus(
                                    L(
                                        "Switched to \(entry.accountPrimaryLabel). Quit & reopen Antigravity.app to use this account.",
                                        "已切换到 \(entry.accountPrimaryLabel)。退出并重新打开 Antigravity.app 即可生效。"
                                    ),
                                    false
                                )
                            } catch {
                                onShowStatus(error.localizedDescription, true)
                            }
                        } else {
                            activation.deactivateAccount(entry: entry)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(ProxyActivationToggleStyle(brandColor: Self.antigravityBrand, isBusy: false))
                .help(L(
                    "Switch Antigravity account in state.vscdb without signing in via browser.",
                    "直接写入 state.vscdb 切换 Antigravity 账号，无需再次打开浏览器登录。"
                ))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isActive ? Self.antigravityBrand.opacity(0.12) : Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isActive ? Self.antigravityBrand.opacity(0.50) : Color.primary.opacity(0.06), lineWidth: 1)
        )
        .contextMenu {
            if !activation.isRemoteViewOnly(entry) {
                Button {
                    do {
                        try activation.activateAccount(entry: entry)
                        onShowStatus(
                            L(
                                "Switched to \(entry.accountPrimaryLabel). Quit & reopen Antigravity.app to use this account.",
                                "已切换到 \(entry.accountPrimaryLabel)。退出并重新打开 Antigravity.app 即可生效。"
                            ),
                            false
                        )
                    } catch {
                        onShowStatus(error.localizedDescription, true)
                    }
                } label: {
                    Label(L("Switch to This Account", "切换到此账号"), systemImage: "arrow.left.arrow.right.circle")
                }

                if isAppInstalled {
                    Button {
                        do {
                            try activation.activateAccount(entry: entry)
                            onRestartApp()
                        } catch {
                            onShowStatus(error.localizedDescription, true)
                        }
                    } label: {
                        Label(L("Switch & Restart Antigravity", "切换并重启 Antigravity"), systemImage: "arrow.clockwise.circle")
                    }
                }
                Divider()
            }

            if let provider = entry.liveProvider {
                Button {
                    Task { await refreshCoordinator.refreshProviderCardNow(provider) }
                } label: {
                    Label(L("Refresh Quota", "刷新配额"), systemImage: "arrow.clockwise")
                }
            }

            Button {
                editingNoteEntry = entry
            } label: {
                Label(L("Edit Note", "编辑备注"), systemImage: "pencil")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.accountPrimaryLabel, forType: .string)
            } label: {
                Label(L("Copy Account Email", "复制账号邮箱"), systemImage: "doc.on.doc")
            }

            Divider()

            Button(role: .destructive) {
                pendingDeleteEntry = entry
            } label: {
                Label(L("Remove Account", "移除账号"), systemImage: "trash")
            }
        }
    }
}

private struct FlowLayoutPills<PillView: View>: View {
    let windows: [QuotaWindow]
    let renderPill: (QuotaWindow) -> PillView

    var body: some View {
        HStack(spacing: 6) {
            ForEach(windows) { window in
                renderPill(window)
            }
        }
    }
}

private struct AntigravityRowHeightKey: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Antigravity Config File Editor Sheet (GEMINI.md / mcp_config.json)

enum AntigravityEditableFile: Identifiable {
    case geminiRules(path: String)
    case mcpConfig(path: String)

    var id: String {
        switch self {
        case .geminiRules(let path): return "gemini:\(path)"
        case .mcpConfig(let path): return "mcp:\(path)"
        }
    }

    var path: String {
        switch self {
        case .geminiRules(let path), .mcpConfig(let path): return path
        }
    }

    var title: String {
        switch self {
        case .geminiRules: return "GEMINI.md"
        case .mcpConfig: return "mcp_config.json"
        }
    }

    var isJSON: Bool {
        switch self {
        case .geminiRules: return false
        case .mcpConfig: return true
        }
    }
}

private struct AntigravityConfigFileEditorSheet: View {
    let file: AntigravityEditableFile
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.title)
                        .font(.headline.weight(.bold))
                    Text(file.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Reveal in Finder", "在访达中显示")) {
                    let url = URL(fileURLWithPath: file.path)
                    if FileManager.default.fileExists(atPath: file.path) {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            TextEditor(text: $text)
                .font(.system(size: 12, design: .monospaced))
                .frame(minWidth: 620, minHeight: 380)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.12), lineWidth: 1)
                )

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(L("Cancel", "取消"), role: .cancel) {
                    dismiss()
                }
                Spacer()
                Button(L("Save", "保存")) {
                    saveFile()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onAppear {
            loadFile()
        }
    }

    private func loadFile() {
        if let data = FileManager.default.contents(atPath: file.path),
           let content = String(data: data, encoding: .utf8) {
            text = content
        } else {
            text = file.isJSON ? "{\n  \"mcpServers\": {}\n}\n" : ""
        }
    }

    private func saveFile() {
        if file.isJSON {
            guard let data = text.data(using: .utf8),
                  (try? JSONSerialization.jsonObject(with: data)) is [String: Any] else {
                errorMessage = L("Invalid JSON object. Please fix syntax errors before saving.", "JSON 格式无效，请修正语法错误后再保存。")
                return
            }
        }

        do {
            let url = URL(fileURLWithPath: file.path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: url, options: .atomic)
            onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
