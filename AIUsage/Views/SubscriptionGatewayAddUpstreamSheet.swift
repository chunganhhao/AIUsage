import AppKit
import SwiftUI

// MARK: - Add Upstream Wizard
// “添加上游”向导：按凭据来源划分五个分区 —— CPA 核心 OAuth、官方 Provider
// 插件、从 AIUsage 接入（仅显示可同步账号）、API 上游、高级迁移（认证文件
// 导入）。角色划分由 CLIProxyCapabilityMatrix 驱动，不根据应用名称猜测。

enum GatewayUpstreamSection: String, CaseIterable, Identifiable {
    case oauth
    case plugins
    case aiusage
    case apiKey
    case migration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .oauth: L("Subscription sign-in", "订阅账号登录")
        case .plugins: L("Official plugins", "官方插件")
        case .aiusage: L("From AIUsage", "从 AIUsage 接入")
        case .apiKey: L("API upstreams", "API 上游")
        case .migration: L("Advanced migration", "高级迁移")
        }
    }

    var systemImage: String {
        switch self {
        case .oauth: "person.crop.circle.badge.checkmark"
        case .plugins: "puzzlepiece.extension"
        case .aiusage: "arrow.right.circle"
        case .apiKey: "key.horizontal"
        case .migration: "square.and.arrow.down.on.square"
        }
    }
}

private enum GatewayImportEntry: Identifiable {
    case general
    case codexAuthJSON

    var id: String {
        switch self {
        case .general: "general"
        case .codexAuthJSON: "codex"
        }
    }

    var mode: CLIProxyAuthImportSession.Mode {
        switch self {
        case .general: .general
        case .codexAuthJSON: .codexAuthJSON
        }
    }
}

struct CLIProxyAddUpstreamSheet: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var section: GatewayUpstreamSection
    @Environment(\.dismiss) private var dismiss

    @State private var showCustomProvider = false
    @State private var importEntry: GatewayImportEntry?
    @State private var pendingForceSync: CLIProxyAccountSyncCandidate?

    private let providerColumns = [GridItem(.adaptive(minimum: 175), spacing: 11)]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            sectionPicker
            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if !runtime.state.isRunning { stoppedBanner }
                    if manager.oauthFlowState.isActive { oauthProgressCard }
                    else { oauthOutcomeCard }
                    if let error = manager.lastError, !oauthFlowStateContainsError {
                        GatewayErrorBanner(message: error)
                    }

                    if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild {
                        apiKeyOnlyNoticeBanner
                        apiKeySection
                    } else {
                        switch section {
                        case .oauth: oauthSection
                        case .plugins: pluginSection
                        case .aiusage: aiusageSection
                        case .apiKey: apiKeySection
                        case .migration: migrationSection
                        }
                    }
                }
                .padding(22)
            }
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: 800,
               minHeight: 500, idealHeight: 640, maxHeight: 720)
        .interactiveDismissDisabled(manager.oauthFlowState.isActive)
        .task {
            if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild {
                section = .apiKey
            } else if runtime.state.isRunning {
                await manager.refreshProviderPlugins(includeStore: true)
            }
        }
        .sheet(isPresented: $showCustomProvider) {
            CLIProxyCustomProviderSheet(manager: manager)
        }
        .sheet(item: $importEntry) { entry in
            SubscriptionGatewayImportSheet(
                manager: manager,
                runtime: runtime,
                mode: entry.mode
            )
        }
        .alert(
            L("Update CPA login from Subscription?", "用订阅账号更新 CPA 登录材料？"),
            isPresented: Binding(
                get: { pendingForceSync != nil },
                set: { if !$0 { pendingForceSync = nil } }
            ),
            presenting: pendingForceSync
        ) { candidate in
            Button(L("Update", "更新"), role: .destructive) {
                Task { await manager.syncAccount(candidate, forceOverwriteCPA: true) }
                pendingForceSync = nil
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingForceSync = nil }
        } message: { candidate in
            Text(L(
                "This overwrites the CPA login material for \(candidate.label) with the current Subscription account. The Subscription credential itself is unchanged.",
                "会用当前订阅账号覆盖 \(candidate.label) 在 CPA 中的登录材料；订阅侧凭据本身不变。"
            ))
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(spacing: 13) {
            ProviderIconView("cliproxyapi", size: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Add an upstream", "添加上游")).font(.title2.weight(.bold))
                Text(CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                     ? L(
                        "Choose how the upstream reaches CPA: sign-in, plugin, AIUsage copy, API key, or file migration.",
                        "选择上游进入 CPA 的方式：登录、插件、AIUsage 副本、API Key 或文件迁移。"
                     )
                     : L(
                        "This build runs CPA in API-key-only mode for official OpenAI-compatible upstreams.",
                        "当前构建以仅 API Key 模式运行 CPA，仅支持官方 OpenAI 兼容上游。"
                     ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("Done", "完成")) { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(manager.oauthFlowState.isActive)
                .help(manager.oauthFlowState.isActive
                      ? L("Cancel the active sign-in before closing.", "请先取消正在进行的登录。")
                      : L("Close", "关闭"))
        }
        .padding(22)
    }

    private var visibleSections: [GatewayUpstreamSection] {
        CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
            ? GatewayUpstreamSection.allCases
            : [.apiKey]
    }

    private var apiKeyOnlyNoticeBanner: some View {
        GatewayCard {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("CPA subscription accounts unavailable in this build", "当前构建不提供 CPA 订阅账号接入"))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        "Consumer subscription sign-in, sync, plugins, and auth-file migration are disabled here. Native Codex monitoring in AIUsage and official OpenAI-compatible API-key upstreams below remain available separately.",
                        "消费者订阅登录、同步、插件与认证文件迁移在此构建中已停用；AIUsage 原生 Codex 与下方官方 OpenAI 兼容 API Key 上游仍可独立使用。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var sectionPicker: some View {
        HStack(spacing: 4) {
            ForEach(visibleSections) { candidate in
                Button {
                    section = candidate
                } label: {
                    Label(candidate.title, systemImage: candidate.systemImage)
                        .font(.subheadline.weight(section == candidate ? .semibold : .medium))
                        .foregroundStyle(section == candidate ? Color.accentColor : Color.secondary)
                        .padding(.horizontal, 11)
                        .frame(minHeight: 32)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(section == candidate ? Color.accentColor.opacity(0.11) : .clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(section == candidate ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }

    // MARK: - Core OAuth

    private var allowedOAuthProviders: [CLIProxyOAuthProvider] {
        CLIProxyOAuthProvider.allCases.filter {
            CLIProxyCapabilityMatrix.directOAuthRejectionReason(for: $0.rawValue) == nil
        }
    }

    private var oauthSection: some View {
        addSection(
            title: L("Sign in with a subscription account", "订阅账号登录"),
            subtitle: L(
                "Direct CPA sidecar OAuth sign-in is disabled so unverified accounts cannot enter the active routing pool before ChatGPT Go/Free plan verification. Connect your Codex account in AIUsage Subscriptions or import a verified Codex Go/Free auth file.",
                "为防止未经校验的账号在套餐验证前进入活动路由池，已禁用 CPA 直接 OAuth 登录。请先在 AIUsage「订阅监测」中登录 Codex，或在「高级迁移」中导入已验证的 ChatGPT Go / ChatGPT Free 认证文件。"
            )
        ) {
            if allowedOAuthProviders.isEmpty {
                HStack(spacing: 10) {
                    Button(L("Connect from AIUsage", "从 AIUsage 接入")) {
                        section = .aiusage
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button(L("Import Codex Auth File", "导入 Codex 认证文件")) {
                        section = .migration
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.vertical, 4)
            } else {
                LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 11) {
                    ForEach(allowedOAuthProviders) { provider in
                        oauthProviderCard(provider)
                    }
                }
            }
        }
    }

    private func oauthProviderCard(_ provider: CLIProxyOAuthProvider) -> some View {
        Button {
            Task { await manager.beginOAuth(provider) }
        } label: {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    GatewayProviderIcon(providerID: provider.gatewayProviderID, size: 42)
                    Spacer()
                    GatewayStatusPill(
                        text: L("Core OAuth", "核心 OAuth"),
                        color: .blue,
                        systemImage: nil
                    )
                }
                Text(provider.gatewayDisplayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(provider.gatewaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
        }
        .buttonStyle(.plain)
        .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
    }

    // MARK: - Official plugins

    private var pluginSection: some View {
        addSection(
            title: L("Official provider plugins", "官方 Provider 插件"),
            subtitle: L(
                "Read live from the installed CPA build and its official plugin store; nothing here is a hard-coded promise. Installing a plugin enables CPA plugins and restarts the local service. Sign-in appears only after the plugin is installed and enabled.",
                "此列表实时来自当前 CPA 构建及其官方插件商店，并非硬编码承诺。安装插件会启用 CPA 插件并重启本地服务；只有插件安装并启用后才会出现登录入口。"
            )
        ) {
            VStack(alignment: .leading, spacing: 11) {
                if let pluginError = manager.pluginError {
                    GatewayErrorBanner(message: pluginError)
                }
                if !runtime.state.isRunning {
                    Text(L(
                        "Start CPA to read its plugin capabilities.",
                        "启动 CPA 后才能读取插件能力。"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                } else if manager.isManagingPlugins && manager.providerPluginStore.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading provider capabilities from CPA…", "正在从 CPA 载入提供商能力…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                } else if manager.providerPluginStore.isEmpty && unlistedProviderPlugins.isEmpty {
                    Text(L(
                        "The installed CPA build reported no provider plugins.",
                        "当前 CPA 构建没有上报可用的 Provider 插件。"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
                } else {
                    LazyVGrid(columns: providerColumns, alignment: .leading, spacing: 11) {
                        ForEach(manager.providerPluginStore) { entry in
                            pluginStoreCard(entry)
                        }
                        ForEach(unlistedProviderPlugins) { plugin in
                            installedPluginCard(plugin)
                        }
                    }
                }
            }
        }
    }

    private func pluginStoreCard(_ entry: CLIProxyPluginStoreEntry) -> some View {
        let plugin = manager.providerPlugins.first { $0.id == entry.id }
        let isReady = plugin?.effectiveEnabled == true && plugin?.supportsOAuth == true
        let repositoryURL: URL? = URL(string: entry.repository).flatMap { url -> URL? in
            guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
            return url
        }
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                GatewayProviderIcon(providerID: plugin?.providerID ?? entry.id, size: 42)
                Spacer()
                GatewayStatusPill(
                    text: entry.installed
                        ? (isReady ? L("Plugin ready", "插件可用") : L("Installed, disabled", "已安装未启用"))
                        : L("Official plugin · not installed", "官方插件 · 尚未安装"),
                    color: isReady ? .purple : .secondary,
                    systemImage: isReady ? "puzzlepiece.extension.fill" : "puzzlepiece.extension"
                )
            }
            Text(entry.name).font(.subheadline.weight(.semibold))
            Text(entry.description)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(spacing: 6) {
                if !entry.author.isEmpty { Text(entry.author) }
                if !entry.sourceID.isEmpty { Text("· \(entry.sourceID)") }
                if let repositoryURL {
                    Text("·")
                    Link(L("Source", "源码"), destination: repositoryURL)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            HStack {
                Text("v\(entry.installedVersion?.nilIfBlank ?? entry.version)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                if isReady, let plugin {
                    Button(L("Sign In", "登录")) { Task { await manager.beginPluginOAuth(plugin) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if let plugin, entry.installed {
                    Button(L("Enable", "启用")) { Task { await manager.setProviderPlugin(plugin, enabled: true) } }
                        .controlSize(.small)
                } else {
                    Button(entry.updateAvailable
                           ? L("Update", "更新")
                           : L("Install & Enable", "安装并启用")) {
                        Task { await manager.installProviderPlugin(entry) }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
        .disabled(manager.isManagingPlugins || manager.isManagingAccounts)
    }

    private func installedPluginCard(_ plugin: CLIProxyPlugin) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                GatewayProviderIcon(providerID: plugin.providerID, size: 42)
                Spacer()
                GatewayStatusPill(
                    text: plugin.effectiveEnabled ? L("Plugin ready", "插件可用") : L("Disabled", "未启用"),
                    color: plugin.effectiveEnabled ? .purple : .secondary,
                    systemImage: "puzzlepiece.extension.fill"
                )
            }
            Text(plugin.displayName).font(.subheadline.weight(.semibold))
            Text(L("Dynamically registered by the installed CPA runtime.", "由当前 CPA 运行时动态注册。"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack {
                Spacer()
                if plugin.effectiveEnabled {
                    Button(L("Sign In", "登录")) { Task { await manager.beginPluginOAuth(plugin) } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else {
                    Button(L("Enable", "启用")) { Task { await manager.setProviderPlugin(plugin, enabled: true) } }
                        .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.primary.opacity(0.06)))
        .disabled(manager.isManagingPlugins || manager.isManagingAccounts)
    }

    private var unlistedProviderPlugins: [CLIProxyPlugin] {
        let storeIDs = Set(manager.providerPluginStore.map(\.id))
        return manager.providerPlugins.filter { !storeIDs.contains($0.id) }
    }

    // MARK: - From AIUsage

    private var aiusageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            addSection(
                title: L("Connect an existing AIUsage account", "接入现有 AIUsage 账号"),
                subtitle: L(
                    "Only eligible Codex accounts (ChatGPT Go / ChatGPT Free) with a verified conversion adapter appear here. Login material is written into CPA; the Subscription account itself is unchanged.",
                    "此处仅显示通过校验的 Codex（ChatGPT Go / ChatGPT Free）账号。会把登录材料写入 CPA；订阅账号本身不变。"
                )
            ) {
                if manager.syncCandidates.isEmpty {
                    Text(L(
                        "No directly syncable accounts were found.",
                        "当前没有可直接同步的账号。"
                    ))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.syncCandidates.enumerated()), id: \.element.id) { index, candidate in
                            syncCandidateRow(candidate)
                            if index < manager.syncCandidates.count - 1 { Divider() }
                        }
                    }
                }
            }

            if !manager.upstreamAuthHints.isEmpty {
                addSection(
                    title: L("Requires independent CPA authorization", "需要在 CPA 中独立授权"),
                    subtitle: L(
                        "CPA supports these providers, but their AIUsage credentials cannot be copied. Authorize them separately inside CPA.",
                        "CPA 支持这些服务，但它们的 AIUsage 凭据无法复制，需要在 CPA 中单独完成授权。"
                    )
                ) {
                    VStack(spacing: 0) {
                        ForEach(Array(manager.upstreamAuthHints.enumerated()), id: \.element.id) { index, hint in
                            upstreamHintRow(hint)
                            if index < manager.upstreamAuthHints.count - 1 { Divider() }
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                Text(L(
                    "Some AIUsage accounts are monitoring-only (for example Cursor or GitHub Copilot) and cannot become CPA upstreams, so they are not listed here.",
                    "部分 AIUsage 账号仅用于额度监控（如 Cursor、GitHub Copilot），不能转换为 CPA 上游，因此不会显示在这里。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func syncCandidateRow(_ candidate: CLIProxyAccountSyncCandidate) -> some View {
        HStack(spacing: 12) {
            GatewayProviderIcon(providerID: candidate.providerId, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(candidate.label).font(.subheadline.weight(.semibold))
                if let identitySummary = gatewayNativeIdentitySummary(candidate.accountIdentity) {
                    Text("\(gatewayProviderDisplayName(candidate.providerId)) · \(identitySummary)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text(gatewayProviderDisplayName(candidate.providerId))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            syncCandidateTrailing(candidate)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func syncCandidateTrailing(_ candidate: CLIProxyAccountSyncCandidate) -> some View {
        switch candidate.compatibility {
        case .compatible:
            if manager.isSynced(candidate) {
                syncedCandidateControls(candidate)
            } else {
                Button(L("Sync to CPA", "同步到 CPA")) {
                    Task { await manager.syncAccount(candidate) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
            }
        case .credentialMissing:
            GatewayStatusPill(
                text: L("AIUsage credential unavailable", "AIUsage 凭据不可用"),
                color: .orange,
                systemImage: "exclamationmark.triangle.fill"
            )
            Button(L("Fix in Subscription Accounts", "前往订阅账号修复")) {
                dismiss()
                AppState.shared.presentMainWindow(section: .providerAccounts)
            }
            .buttonStyle(.borderless)
        case .credentialInvalid:
            GatewayStatusPill(
                text: L("Re-login required", "需要重新登录"),
                color: .orange,
                systemImage: "person.crop.circle.badge.exclamationmark"
            )
            Button(L("Open Subscription Accounts", "打开订阅账号")) {
                dismiss()
                AppState.shared.presentMainWindow(section: .providerAccounts)
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private func syncedCandidateControls(_ candidate: CLIProxyAccountSyncCandidate) -> some View {
        GatewayStatusPill(
            text: L("In CPA", "已在 CPA"),
            color: .green,
            systemImage: "checkmark.circle.fill"
        )
        Button(L("Update from Subscription", "从订阅更新")) {
            pendingForceSync = candidate
        }
        .buttonStyle(.borderless)
        .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
    }

    private func upstreamHintRow(_ hint: CLIProxyUpstreamAuthHint) -> some View {
        HStack(spacing: 12) {
            GatewayProviderIcon(providerID: hint.providerId, size: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(gatewayProviderDisplayName(hint.providerId))
                    .font(.subheadline.weight(.semibold))
                Text(hintDetail(hint))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            switch hint.capability {
            case .requiresCPAOAuth(let provider):
                Button(L("Authorize in CPA", "在 CPA 中授权")) {
                    Task { await manager.beginOAuth(provider) }
                }
                .controlSize(.small)
                .disabled(!runtime.state.isRunning || manager.isManagingAccounts || manager.oauthFlowState.isActive)
            case .requiresPlugin:
                Button(L("Open Plugins", "查看插件")) { section = .plugins }
                    .controlSize(.small)
            case .syncableFromAIUsage, .notAnUpstream:
                EmptyView()
            }
        }
        .padding(.vertical, 10)
    }

    private func hintDetail(_ hint: CLIProxyUpstreamAuthHint) -> String {
        switch hint.capability {
        case .requiresCPAOAuth:
            L(
                "\(hint.accountCount) AIUsage account(s) monitored · credentials cannot be copied; CPA needs its own authorization.",
                "AIUsage 监控了 \(hint.accountCount) 个账号 · 凭据无法复制，CPA 需要独立授权。"
            )
        case .requiresPlugin(let pluginHint):
            L(
                "Available after installing the official \(pluginHint) provider plugin.",
                "安装官方 \(pluginHint) Provider 插件后可用。"
            )
        case .syncableFromAIUsage, .notAnUpstream:
            ""
        }
    }

    // MARK: - API upstreams

    private var apiKeySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            addSection(
                title: L("OpenAI-compatible upstream", "OpenAI 兼容上游"),
                subtitle: L(
                    "Bring an OpenAI-compatible API key into the same CPA routing pool. The key is sent only to the loopback Management API and is never displayed again.",
                    "将 OpenAI 兼容 API Key 加入同一个 CPA 路由池。密钥只发送到本机 Management API，之后不会再次显示。"
                )
            ) {
                HStack(spacing: 13) {
                    Image(systemName: "key.horizontal.fill")
                        .font(.title2)
                        .foregroundStyle(.teal)
                        .frame(width: 42, height: 42)
                        .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("OpenAI-compatible provider", "OpenAI 兼容提供商")).font(.subheadline.weight(.semibold))
                        Text(L("Name, base URL, API key, model IDs, prefix, and priority.", "配置名称、Base URL、API Key、模型 ID、前缀和优先级。"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Configure…", "配置…")) { showCustomProvider = true }
                        .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
                }
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "hourglass").foregroundStyle(.secondary)
                Text(L(
                    "Typed editors for CPA's dedicated Gemini / Claude / Codex / Vertex API-key and service-account upstreams are planned for a later release. Their schemas differ per provider, so AIUsage does not fake a generic form here.",
                    "CPA 专用的 Gemini / Claude / Codex / Vertex API Key 与 Service Account 上游的类型化编辑器将在后续版本提供。它们的写入格式各不相同，AIUsage 不会在此伪装一个通用表单。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Advanced migration

    private var migrationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            addSection(
                title: L("Import CPA auth files (advanced migration)", "导入 CPA 认证文件（高级迁移）"),
                subtitle: L(
                    "For auth JSON exported from another CPA or a compatible manager. A plain application auth.json may not work directly; every file is recognized, previewed, and deduplicated before upload.",
                    "用于导入从另一套 CPA 或兼容管理工具导出的认证 JSON。普通应用的 auth.json 不一定可以直接使用；每个文件都会先识别、预览并去重，然后才上传。"
                )
            ) {
                HStack(spacing: 13) {
                    Image(systemName: "square.and.arrow.down.on.square.fill")
                        .font(.title2)
                        .foregroundStyle(.indigo)
                        .frame(width: 42, height: 42)
                        .background(Color.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Batch import auth JSON", "批量导入认证 JSON")).font(.subheadline.weight(.semibold))
                        Text(L(
                            "Multiple files · local recognition · preview · duplicate and conflict planning · per-file results.",
                            "支持多文件 · 本地识别 · 导入预览 · 重复与冲突规划 · 逐项结果。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Open Importer…", "打开导入…")) { importEntry = .general }
                        .disabled(!runtime.state.isRunning || manager.isImportingAuthFiles)
                }
            }

            addSection(
                title: L("Import a Codex auth.json", "导入 Codex auth.json"),
                subtitle: L(
                    "Converts a raw Codex CLI auth.json into CPA's schema: nested tokens are expanded, the CPA type is added, and the workspace identity is compared against existing CPA accounts. Never edit token JSON by hand.",
                    "把原始 Codex CLI auth.json 转换为 CPA 格式：自动展开嵌套 Token、补充 CPA type，并与现有 CPA 账号比较工作区身份。请不要手工编辑 Token JSON。"
                )
            ) {
                HStack(spacing: 13) {
                    GatewayProviderIcon(providerID: "codex", size: 42)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(L("Convert & import auth.json", "转换并导入 auth.json")).font(.subheadline.weight(.semibold))
                        Text(L(
                            "Usually found at ~/.codex/auth.json on another machine.",
                            "通常位于另一台电脑的 ~/.codex/auth.json。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Choose File…", "选择文件…")) { importEntry = .codexAuthJSON }
                        .disabled(!runtime.state.isRunning || manager.isImportingAuthFiles)
                }
            }
        }
    }

    // MARK: - Shared cards

    private var stoppedBanner: some View {
        HStack(spacing: 13) {
            Image(systemName: "power.circle.fill").font(.title2).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(manager.isInstalled
                     ? L("CPA must be running to add an upstream", "添加上游前需要启动 CPA")
                     : L("Install CPA before adding an upstream", "添加上游前需要安装 CPA"))
                    .font(.subheadline.weight(.semibold))
                Text(manager.isInstalled
                     ? L("The service remains local to this Mac.", "服务仍只在本机运行。")
                     : L("AIUsage verifies the official macOS runtime before starting it.", "AIUsage 会先校验官方 macOS 运行时，再启动服务。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(manager.isInstalled ? L("Start CPA", "启动 CPA") : L("Install CPA", "安装 CPA")) {
                Task {
                    if !manager.isInstalled { await manager.installOrUpdateLatest() }
                    guard manager.isInstalled else { return }
                    await runtime.start()
                    if runtime.state.isRunning { await manager.refreshAccounts() }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(manager.operation.isBusy || runtime.state.isTransitioning)
        }
        .padding(15)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.orange.opacity(0.16)))
    }

    private var oauthProgressCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 13) {
                if let provider = manager.oauthProvider {
                    GatewayProviderIcon(providerID: provider.gatewayProviderID, size: 42)
                } else if let plugin = manager.oauthPlugin {
                    GatewayProviderIcon(providerID: plugin.providerID, size: 42)
                }
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Waiting for authorization", "等待授权"))
                        .font(.subheadline.weight(.semibold))
                    Text(manager.oauthStatusMessage ?? L("Complete sign-in in the browser.", "请在浏览器中完成登录。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let url = manager.oauthSession?.url {
                    Button(L("Open Browser", "打开浏览器")) { NSWorkspace.shared.open(url) }
                        .buttonStyle(.borderless)
                }
                Button(L("Cancel", "取消"), role: .cancel) {
                    Task { await manager.cancelOAuth() }
                }
                .disabled(!manager.oauthFlowState.isActive)
            }
            if let code = manager.oauthSession?.userCode, !code.isEmpty {
                GatewayCopyField(label: L("Device code", "设备码"), value: code)
            }
        }
        .padding(15)
        .background(Color.blue.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(Color.blue.opacity(0.16)))
    }

    @ViewBuilder
    private var oauthOutcomeCard: some View {
        switch manager.oauthFlowState {
        case .succeeded(let provider):
            oauthOutcome(
                title: L("\(provider.gatewayDisplayName) connected", "\(provider.gatewayDisplayName) 已接入"),
                detail: L("The account is now available in the CPA pool.", "该账号现在已加入 CPA 账号池。"),
                color: .green,
                icon: "checkmark.circle.fill"
            )
        case .pluginSucceeded(let name):
            oauthOutcome(
                title: L("\(name) connected", "\(name) 已接入"),
                detail: L("The plugin account is now available in the CPA pool.", "插件账号现在已加入 CPA 账号池。"),
                color: .green,
                icon: "checkmark.circle.fill"
            )
        case .failed(_, let message), .pluginFailed(_, let message):
            oauthOutcome(
                title: L("Sign-in failed", "登录失败"),
                detail: message,
                color: .orange,
                icon: "exclamationmark.triangle.fill"
            )
        case .cancelled:
            oauthOutcome(
                title: L("Sign-in cancelled", "登录已取消"),
                detail: L("No CPA account was changed.", "CPA 账号没有发生变化。"),
                color: .secondary,
                icon: "xmark.circle"
            )
        default:
            EmptyView()
        }
    }

    private func oauthOutcome(title: String, detail: String, color: Color, icon: String) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer()
        }
        .padding(15)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(color.opacity(0.16)))
        .accessibilityElement(children: .combine)
    }

    private var oauthFlowStateContainsError: Bool {
        switch manager.oauthFlowState {
        case .failed, .pluginFailed: true
        default: false
        }
    }

    private func addSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
        }
        .padding(18)
        .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.055)))
    }
}

// MARK: - OpenAI-compatible upstream form

struct CLIProxyCustomProviderSheet: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var baseURL = ""
    @State private var apiKey = ""
    @State private var modelText = ""
    @State private var prefix = ""
    @State private var priority = 0
    @State private var isSaving = false
    @State private var formError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                Image(systemName: "key.horizontal.fill")
                    .font(.title2)
                    .foregroundStyle(.teal)
                    .frame(width: 44, height: 44)
                    .background(Color.teal.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("OpenAI-compatible upstream", "OpenAI 兼容上游")).font(.title3.weight(.bold))
                    Text(L("Add an API-key provider to CPA's routing pool.", "将 API Key 提供商加入 CPA 路由池。"))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(20)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    if let formError { GatewayErrorBanner(message: formError) }

                    formField(
                        title: L("Provider name", "提供商名称"),
                        detail: L("A unique local name, for example My Team Gateway.", "唯一的本地名称，例如“团队网关”。")
                    ) {
                        TextField(L("My Provider", "我的提供商"), text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    formField(
                        title: "Base URL",
                        detail: L("Full HTTP(S) endpoint, usually ending in /v1.", "完整 HTTP(S) 端点，通常以 /v1 结尾。")
                    ) {
                        TextField("https://api.example.com/v1", text: $baseURL)
                            .textFieldStyle(.roundedBorder)
                    }

                    formField(
                        title: "API Key",
                        detail: L("Sent only to CPA's loopback Management API. AIUsage does not add it to logs or the sync manifest.", "只发送到 CPA 本机 Management API；AIUsage 不会把它写入日志或同步清单。")
                    ) {
                        SecureField("sk-…", text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                    }

                    formField(
                        title: L("Upstream model IDs", "上游模型 ID"),
                        detail: L("Separate multiple models with commas or new lines.", "多个模型可用逗号或换行分隔。")
                    ) {
                        TextEditor(text: $modelText)
                            .font(.system(.callout, design: .monospaced))
                            .frame(minHeight: 82)
                            .padding(7)
                            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.09)))
                    }

                    HStack(alignment: .top, spacing: 16) {
                        formField(
                            title: L("Optional model prefix", "可选模型前缀"),
                            detail: L("Namespaces models when providers overlap.", "模型重名时用于命名空间隔离。")
                        ) {
                            TextField("team-a", text: $prefix).textFieldStyle(.roundedBorder)
                        }
                        formField(
                            title: L("Priority", "优先级"),
                            detail: L("Higher values are preferred.", "数值越高，选择优先级越高。")
                        ) {
                            Stepper(value: $priority, in: -100...100) {
                                Text("\(priority)").monospacedDigit().frame(width: 40, alignment: .trailing)
                            }
                        }
                        .frame(width: 170)
                    }

                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(.green)
                        Text(L(
                            "AIUsage first reads the current CPA provider list, rejects duplicate names, then appends this provider without replacing existing entries.",
                            "AIUsage 会先读取 CPA 当前提供商列表并拒绝重复名称，再追加此提供商，不会覆盖已有配置。"
                        ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
                .padding(20)
            }

            Divider()
            HStack {
                if isSaving { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Add Provider", "添加提供商")) { save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canSave || isSaving)
            }
            .padding(16)
        }
        .frame(minWidth: 540, idealWidth: 620, maxWidth: 650,
               minHeight: 460, idealHeight: 600, maxHeight: 670)
    }

    private func formField<Content: View>(
        title: String,
        detail: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(detail).font(.caption).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelIDs: [String] {
        modelText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !modelIDs.isEmpty
    }

    private func save() {
        isSaving = true
        formError = nil
        Task {
            await manager.addOpenAICompatibleProvider(
                name: name,
                baseURL: baseURL,
                apiKey: apiKey,
                modelIDs: modelIDs,
                prefix: prefix,
                priority: priority
            )
            isSaving = false
            if let error = manager.lastError { formError = error }
            else {
                apiKey = ""
                dismiss()
            }
        }
    }
}
