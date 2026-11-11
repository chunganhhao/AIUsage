import SwiftUI
import Combine
import AppKit
import QuotaBackend

// MARK: - Codex Local Environment Summary

struct CodexLocalEnvironmentSummary: Equatable, Sendable {
    var isAppInstalled: Bool
    var isAppRunning: Bool
    var appVersion: String?
    var agentsRulesPath: String
    var configTomlPath: String
    var authJsonPath: String
    var model: String?
    var reasoningEffort: String?
    var serviceTier: String?
    var sandboxMode: String?
    var approvalPolicy: String?
    var mcpServerCount: Int
    var skillCount: Int
    var workspaceCount: Int
    var localSessionCount: Int

    static let empty = CodexLocalEnvironmentSummary(
        isAppInstalled: false,
        isAppRunning: false,
        appVersion: nil,
        agentsRulesPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex/AGENTS.md"),
        configTomlPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex/config.toml"),
        authJsonPath: (NSHomeDirectory() as NSString).appendingPathComponent(".codex/auth.json"),
        model: nil,
        reasoningEffort: nil,
        serviceTier: nil,
        sandboxMode: nil,
        approvalPolicy: nil,
        mcpServerCount: 0,
        skillCount: 0,
        workspaceCount: 0,
        localSessionCount: 0
    )

    static func inspectAsync(homeDirectory: String = NSHomeDirectory()) async -> CodexLocalEnvironmentSummary {
        let running = await MainActor.run {
            NSWorkspace.shared.runningApplications.contains { app in
                let bundleId = app.bundleIdentifier?.lowercased() ?? ""
                let name = app.localizedName?.lowercased() ?? ""
                return bundleId == "com.openai.codex" || name == "codex"
            }
        }
        return await Task.detached(priority: .utility) {
            inspectSync(homeDirectory: homeDirectory, isAppRunning: running)
        }.value
    }

    nonisolated static func inspectSync(homeDirectory: String, isAppRunning: Bool) -> CodexLocalEnvironmentSummary {
        let fm = FileManager.default
        let codexDir = (homeDirectory as NSString).appendingPathComponent(".codex")
        let agentsRulesPath = (codexDir as NSString).appendingPathComponent("AGENTS.md")
        let configTomlPath = (codexDir as NSString).appendingPathComponent("config.toml")
        let authJsonPath = (codexDir as NSString).appendingPathComponent("auth.json")
        let globalStatePath = (codexDir as NSString).appendingPathComponent(".codex-global-state.json")

        let appCandidates = [
            "/Applications/Codex.app",
            (homeDirectory as NSString).appendingPathComponent("Applications/Codex.app"),
            "/Applications/ChatGPT.app",
            (homeDirectory as NSString).appendingPathComponent("Applications/ChatGPT.app")
        ]
        let installedAppPath = appCandidates.first { path in
            guard fm.fileExists(atPath: path) else { return false }
            if path.hasSuffix("/Codex.app") { return true }
            return Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier == "com.openai.codex"
        }
        var appVersion: String?
        if let installedAppPath {
            let plistPath = (installedAppPath as NSString).appendingPathComponent("Contents/Info.plist")
            if let dict = NSDictionary(contentsOfFile: plistPath) as? [String: Any] {
                appVersion = (dict["CFBundleShortVersionString"] as? String)
                    ?? (dict["CFBundleVersion"] as? String)
            }
        }

        var model: String?
        var reasoningEffort: String?
        var serviceTier: String?
        var sandboxMode: String?
        var approvalPolicy: String?
        var mcpServerNames = Set<String>()
        var workspacePaths = Set<String>()

        if let toml = try? String(contentsOfFile: configTomlPath, encoding: .utf8) {
            var inTopLevel = true
            for rawLine in toml.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.isEmpty || line.hasPrefix("#") { continue }
                if line.hasPrefix("[") && line.hasSuffix("]") {
                    inTopLevel = false
                    let section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                    if section.hasPrefix("mcp_servers.") {
                        let rest = String(section.dropFirst("mcp_servers.".count))
                        let serverName = rest.components(separatedBy: ".").first?
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) ?? ""
                        if !serverName.isEmpty {
                            mcpServerNames.insert(serverName)
                        }
                    } else if section.hasPrefix("projects.") {
                        let rest = String(section.dropFirst("projects.".count))
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
                        let normalized = normalizeWorkspacePath(rest)
                        if !normalized.isEmpty {
                            workspacePaths.insert(normalized)
                        }
                    }
                    continue
                }
                guard inTopLevel, let eqIdx = line.firstIndex(of: "=") else { continue }
                let key = line[..<eqIdx].trimmingCharacters(in: .whitespaces)
                var val = line[line.index(after: eqIdx)...].trimmingCharacters(in: .whitespaces)
                if let commentIdx = val.firstIndex(of: "#") {
                    val = val[..<commentIdx].trimmingCharacters(in: .whitespaces)
                }
                val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                guard !val.isEmpty else { continue }
                switch key {
                case "model": model = val
                case "model_reasoning_effort": reasoningEffort = val
                case "service_tier": serviceTier = val
                case "sandbox_mode": sandboxMode = val
                case "approval_policy": approvalPolicy = val
                default: break
                }
            }
        }

        if let stateData = fm.contents(atPath: globalStatePath),
           let stateObj = (try? JSONSerialization.jsonObject(with: stateData)) as? [String: Any] {
            for key in ["active-workspace-roots", "saved-workspace-roots"] {
                if let roots = stateObj[key] as? [String] {
                    for root in roots {
                        let normalized = normalizeWorkspacePath(root)
                        if !normalized.isEmpty {
                            workspacePaths.insert(normalized)
                        }
                    }
                }
            }
        }

        var skillNames = Set<String>()
        let skillRoots = [
            (codexDir as NSString).appendingPathComponent("skills"),
            (homeDirectory as NSString).appendingPathComponent(".agents/skills")
        ]
        for root in skillRoots {
            if let items = try? fm.contentsOfDirectory(atPath: root) {
                for item in items where !item.hasPrefix(".") {
                    skillNames.insert(item)
                }
            }
        }

        var sessionCount = 0
        let sessionIndexPath = (codexDir as NSString).appendingPathComponent("session_index.jsonl")
        if let indexContent = try? String(contentsOfFile: sessionIndexPath, encoding: .utf8) {
            sessionCount = indexContent.split(whereSeparator: \.isNewline).count
        }
        if sessionCount == 0 {
            let sessionsDir = (codexDir as NSString).appendingPathComponent("sessions")
            if let enumerator = fm.enumerator(atPath: sessionsDir) {
                while let rel = enumerator.nextObject() as? String {
                    if rel.hasSuffix(".jsonl") || rel.hasSuffix(".jsonl.zst") {
                        sessionCount += 1
                    }
                }
            }
        }

        return CodexLocalEnvironmentSummary(
            isAppInstalled: installedAppPath != nil,
            isAppRunning: isAppRunning,
            appVersion: appVersion,
            agentsRulesPath: agentsRulesPath,
            configTomlPath: configTomlPath,
            authJsonPath: authJsonPath,
            model: model,
            reasoningEffort: reasoningEffort,
            serviceTier: serviceTier,
            sandboxMode: sandboxMode,
            approvalPolicy: approvalPolicy,
            mcpServerCount: mcpServerNames.count,
            skillCount: skillNames.count,
            workspaceCount: workspacePaths.count,
            localSessionCount: sessionCount
        )
    }

    private nonisolated static func normalizeWorkspacePath(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL {
            return (url.path as NSString).standardizingPath
        }
        return (trimmed as NSString).standardizingPath
    }
}

// MARK: - Codex Local Management View
// Dedicated sidebar management hub for Local Codex (Desktop & CLI), mirroring AntigravityManagementView:
//   1. Action Bar: AGENTS.md & config.toml editors, Restart Codex, Refresh Quotas, + Add Account
//   2. 6 Summary Stat Cards: Accounts, Active Account, Active Min Quota, Today Tokens, Total Tokens, Local Sessions
//   3. Codex Runtime & Workspace Protection Card (with live model, reasoning, service tier, sandbox, workspace & route tags)
//   4. Token Saver & Codex Customization Card (RTK, Caveman, Ponytail, AGENTS.md, MCP & Skills counters)
//   5. Account List with drag-and-drop reorder & 1-click Switch Account / Restart Codex

struct CodexLocalManagementView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var refreshCoordinator: ProviderRefreshCoordinator
    @ObservedObject private var activation = ProviderActivationManager.shared
    @ObservedObject private var proxyVM = ProxyViewModel.shared
    @ObservedObject private var globalProxy = GlobalProxyManager.codex
    @Environment(\.colorScheme) private var colorScheme

    @StateObject private var tokenSaver = TokenSaverSettingsController()
    @State private var envSummary = CodexLocalEnvironmentSummary.empty
    @State private var environmentRefreshTask: Task<Void, Never>?

    @State private var showingAddAccount = false
    @State private var showingConfigTomlEditor = false
    @State private var showingAgentsRulesEditor = false
    @State private var isRestartingCodex = false
    @State private var statusBannerMessage: String?
    @State private var statusBannerIsError = false

    static let brand = CodexSubscriptionSection.codexBrand

    private var codexEntries: [ProviderAccountEntry] {
        appState.providerAccountGroups.first { $0.providerId == "codex" }?.accounts ?? []
    }

    private var costProvider: ProviderData? {
        refreshCoordinator.providers.first { $0.baseProviderId == "codex-cost" }
    }

    private var isProxyActive: Bool {
        proxyVM.activatedId(isCodex: true) != nil || globalProxy.isEnabled
    }

    private var activeEntry: ProviderAccountEntry? {
        guard !isProxyActive else { return nil }
        return codexEntries.first { activation.isActiveAccount($0) }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                actionBar
                if let banner = statusBannerMessage {
                    statusBanner(banner, isError: statusBannerIsError)
                }
                summaryStrip
                runtimeProtectionCard
                GatewayCard { CodexPoolProtectionControls() }
                tokenSaverCard
                GatewayCard { WarmupSettingsView() }
                GatewayCard { AgentConfigToolsView(platform: .codex) }
                CodexSubscriptionSection(
                    entries: codexEntries,
                    isAppInstalled: envSummary.isAppInstalled || activation.isCodexAppInstalled,
                    isRestarting: isRestartingCodex || activation.isCodexRestarting,
                    onAddAccount: { showingAddAccount = true },
                    onRestartApp: { restartCodex() },
                    onAccountSwitched: {
                        refreshEnvironment()
                    },
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
            ProviderAccountEditorView(providerId: "codex")
                .environmentObject(appState)
                .environmentObject(refreshCoordinator)
        }
        .sheet(isPresented: $showingConfigTomlEditor, onDismiss: {
            refreshEnvironment()
        }) {
            CodexConfigEditorView()
        }
        .sheet(isPresented: $showingAgentsRulesEditor) {
            CodexAgentsRulesEditorSheet(path: envSummary.agentsRulesPath) {
                tokenSaver.reloadFromExternalNotification()
                refreshEnvironment()
            }
        }
    }

    private func reloadState() {
        if tokenSaver.harness != .codex {
            tokenSaver.selectHarness(.codex)
        }
        refreshEnvironment()
    }

    private func refreshEnvironment() {
        environmentRefreshTask?.cancel()
        environmentRefreshTask = Task {
            let summary = await CodexLocalEnvironmentSummary.inspectAsync()
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                envSummary = summary
            }
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                agentsRulesFileButton
                configTomlFileButton
                restartCodexButton

                Spacer(minLength: 16)

                refreshQuotasButton
                addAccountButton
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    agentsRulesFileButton
                    configTomlFileButton
                    restartCodexButton
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

    private var agentsRulesFileButton: some View {
        actionBarButton(
            title: "AGENTS.md",
            icon: "doc.text.magnifyingglass",
            role: .file,
            help: L("Open ~/.codex/AGENTS.md global instructions.", "打开 ~/.codex/AGENTS.md 全局指令文件。")
        ) {
            showingAgentsRulesEditor = true
        }
    }

    private var configTomlFileButton: some View {
        actionBarButton(
            title: "config.toml",
            icon: "slider.horizontal.3",
            role: .file,
            help: L("Open the live ~/.codex/config.toml configuration file.", "打开 ~/.codex/config.toml 实时配置文件。")
        ) {
            showingConfigTomlEditor = true
        }
    }

    private var restartCodexButton: some View {
        let busy = isRestartingCodex || activation.isCodexRestarting
        let installed = envSummary.isAppInstalled || activation.isCodexAppInstalled
        return actionBarButton(
            title: busy
                ? L("Restarting…", "正在重启…")
                : L("Restart Codex", "重启 Codex"),
            icon: busy ? nil : "arrow.clockwise.circle.fill",
            role: .secondary,
            help: L(
                "Gracefully quit and reopen Codex.app while preserving active workspace roots and applying the active account.",
                "平滑退出并重新打开 Codex.app，保留工作区项目并应用当前激活账号。"
            )
        ) {
            restartCodex()
        }
        .disabled(busy || !installed)
    }

    private var refreshQuotasButton: some View {
        let refreshing = refreshCoordinator.isProviderRefreshInFlight("codex")
        return actionBarButton(
            title: refreshing ? L("Refreshing…", "刷新中…") : L("Refresh Quotas", "刷新配额"),
            icon: refreshing ? nil : "arrow.triangle.2.circlepath",
            role: .secondary,
            help: L("Refresh quota windows and credits for all Codex accounts.", "刷新所有 Codex 账号的配额窗口与积分余额。")
        ) {
            refreshCoordinator.refreshProvider("codex")
            refreshCoordinator.refreshProvider("codex-cost")
            refreshEnvironment()
        }
        .disabled(refreshing)
    }

    private var addAccountButton: some View {
        actionBarButton(
            title: L("Add Account", "添加账号"),
            icon: "plus.circle.fill",
            role: .primary,
            help: L("Connect an OpenAI Codex account via OAuth or auth.json.", "通过 OAuth 或 auth.json 添加 OpenAI Codex 账号。")
        ) {
            showingAddAccount = true
        }
    }

    private func restartCodex() {
        guard !isRestartingCodex, !activation.isCodexRestarting else { return }
        isRestartingCodex = true
        Task { @MainActor in
            let fallbackEntry = self.activeEntry
            let ok = await activation.restartCodexApp(fallbackEntry: fallbackEntry)
            isRestartingCodex = false
            refreshEnvironment()
            withAnimation(.easeInOut(duration: 0.2)) {
                statusBannerIsError = !ok
                statusBannerMessage = ok
                    ? L("Codex.app restarted with the active account.", "Codex.app 已使用当前激活账号重启。")
                    : L("Could not restart Codex.app automatically. Please reopen it manually.", "无法自动重启 Codex.app，请手动重新打开。")
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
        let busy = isRestartingCodex || activation.isCodexRestarting
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(tint)
            Text(message)
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
            Spacer()
            if !isError && (envSummary.isAppInstalled || activation.isCodexAppInstalled) {
                Button(busy ? L("Restarting…", "正在重启…") : L("Restart Codex Now", "立即重启 Codex")) {
                    restartCodex()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .disabled(busy)
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

    // MARK: - 6 Summary Stat Cards (Aligned with Antigravity)

    private var summaryStrip: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
            summaryCell(
                icon: "person.2.fill",
                title: L("Accounts", "账号数"),
                value: "\(codexEntries.count)",
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
                icon: "bubble.left.and.text.bubble.right.fill",
                title: L("Local Sessions", "本地会话数"),
                value: "\(envSummary.localSessionCount)",
                tint: .indigo
            )
        }
    }

    private var activeAccountShortLabel: String {
        if isProxyActive {
            return L("Proxy Mode", "代理模式")
        }
        if let active = activeEntry {
            let label = active.accountPrimaryLabel
            return label.components(separatedBy: "@").first ?? label
        }
        return L("None", "未激活")
    }

    private var activeMinQuotaLabel: String {
        let target = activeEntry ?? codexEntries.first
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

    // MARK: - Codex Runtime & Workspace Protection Card (Metric & Config Tags)

    private var runtimeProtectionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "shield.lefthalf.filled.badge.checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.purple)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L("Runtime & Workspace Protection", "运行时配置与工作区保护"))
                            .font(.subheadline.weight(.semibold))
                        TokenSaverStatusBadge(
                            text: L("Workspace Guard ON", "工作区保护已开启"),
                            tone: .active,
                            id: "codex-workspace-guard-badge"
                        )
                        TokenSaverStatusBadge(
                            text: isProxyActive
                                ? L("Proxy Route", "代理路由生效")
                                : L("Direct OAuth", "OAuth 直连生效"),
                            tone: isProxyActive ? .warning : .active,
                            id: "codex-route-mode-badge"
                        )
                    }
                    Text(L(
                        "Preserves active & saved workspace roots in .codex-global-state.json and [projects] in config.toml across account switches and app restarts.",
                        "在切换账号与重启客户端期间，自动保护 .codex-global-state.json 中的打开项目与 config.toml 中的受信任工作区配置不丢失。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Button(L("Edit config.toml", "编辑 config.toml")) {
                    showingConfigTomlEditor = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    metricTag(
                        icon: "cpu",
                        label: L("Model", "模型"),
                        value: envSummary.model ?? "—",
                        tint: Self.brand
                    )
                    metricTag(
                        icon: "brain",
                        label: L("Reasoning", "推理强度"),
                        value: envSummary.reasoningEffort?.uppercased() ?? "—",
                        tint: .purple
                    )
                    if let tier = envSummary.serviceTier, !tier.isEmpty {
                        metricTag(
                            icon: "bolt.horizontal.circle",
                            label: L("Tier", "服务层"),
                            value: tier.uppercased(),
                            tint: .orange
                        )
                    }
                    metricTag(
                        icon: "lock.shield",
                        label: L("Sandbox", "沙盒"),
                        value: envSummary.sandboxMode ?? "—",
                        tint: envSummary.sandboxMode == "danger-full-access"
                            ? .orange
                            : (envSummary.sandboxMode == nil ? .secondary : .green)
                    )
                    metricTag(
                        icon: "checkmark.circle",
                        label: L("Approval", "审批策略"),
                        value: envSummary.approvalPolicy ?? "—",
                        tint: .teal
                    )
                    metricTag(
                        icon: "folder.badge.gearshape",
                        label: L("Workspaces", "受保护项目"),
                        value: "\(envSummary.workspaceCount)",
                        tint: .indigo
                    )
                }
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

    private func metricTag(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
            Text("\(label):")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(tint)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(Capsule().fill(tint.opacity(0.11)))
        .overlay(Capsule().stroke(tint.opacity(0.24), lineWidth: 0.5))
    }

    // MARK: - Token Saver & Codex Customization Card

    private var tokenSaverCard: some View {
        let codexSnapshot = tokenSaver.onboarding
        let enabledCount = tokenSaver.settings.enabledToolCount

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "bolt.shield.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Self.brand)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(L("Token Saver & Codex Customization", "Token 节省与 Codex 环境配置"))
                            .font(.subheadline.weight(.semibold))
                        TokenSaverStatusBadge(
                            text: enabledCount > 0
                                ? L("Enabled \(enabledCount)/3", "已启用 \(enabledCount)/3")
                                : L("Off", "已关闭"),
                            tone: enabledCount > 0 ? .active : .neutral,
                            id: "codex-token-saver-badge"
                        )
                    }
                    Text(L(
                        "Manages RTK command compression, Caveman concise responses, and Ponytail minimal-code rules in ~/.codex/AGENTS.md.",
                        "管理 ~/.codex/AGENTS.md 中的 RTK 命令输出压缩、Caveman 精简回复与 Ponytail 极简代码规则。"
                    ))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                Spacer()

                if tokenSaver.lastSaveSucceeded, tokenSaver.error == nil {
                    TokenSaverStatusBadge(
                        text: L("Saved — new session required", "已保存 — 需开启新会话"),
                        tone: .active,
                        id: "codex-token-saver-saved-badge"
                    )
                }

                Button(L("Reapply Rules", "重新写入规则")) {
                    tokenSaver.reapply()
                    refreshEnvironment()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityIdentifier("codex-token-saver-reapply")
            }

            Divider()

            HStack(spacing: 16) {
                Toggle(isOn: Binding(
                    get: { tokenSaver.settings.rtkEnabled },
                    set: { val in tokenSaver.mutate { $0.rtkEnabled = val } }
                )) {
                    Text("RTK — CLI Wrapper")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Toggle(isOn: Binding(
                    get: { tokenSaver.settings.cavemanEnabled },
                    set: { val in tokenSaver.mutate { $0.cavemanEnabled = val } }
                )) {
                    Text("Caveman — Concise Replies")
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
                    Text("Ponytail — Minimal Code")
                        .font(.caption.weight(.semibold))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()
            }

            HStack(spacing: 8) {
                envPill(
                    icon: "doc.badge.gearshape",
                    text: codexRulesStatusText(codexSnapshot?.rules)
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
                        ? "Codex.app \(envSummary.appVersion.map { "v\($0)" } ?? "") · \(envSummary.isAppRunning ? L("Running", "运行中") : L("Stopped", "未运行"))"
                        : L("Codex.app Not Found", "未检测到 Codex.app")
                )
                Spacer()
            }

            if let notice = tokenSaver.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("codex-token-saver-notice")
            }

            if let error = tokenSaver.localizedError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("codex-token-saver-error")
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

    private func codexRulesStatusText(_ state: TokenSaverOnboarding.RulesState?) -> String {
        switch state {
        case .current: return L("AGENTS.md: Synced", "AGENTS.md: 已同步")
        case .stale: return L("AGENTS.md: Needs Reapply", "AGENTS.md: 待更新")
        case .missing: return L("AGENTS.md: Missing", "AGENTS.md: 未创建")
        case .off: return L("AGENTS.md: Rules Off", "AGENTS.md: 已关闭")
        default: return "AGENTS.md"
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

// MARK: - Codex AGENTS.md Editor Sheet

private struct CodexAgentsRulesEditorSheet: View {
    let path: String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AGENTS.md")
                        .font(.headline.weight(.bold))
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Reveal in Finder", "在访达中显示")) {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) {
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
            if let data = FileManager.default.contents(atPath: path),
               let content = String(data: data, encoding: .utf8) {
                text = content
            } else {
                text = ""
            }
        }
    }

    private func saveFile() {
        do {
            let url = URL(fileURLWithPath: path)
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
