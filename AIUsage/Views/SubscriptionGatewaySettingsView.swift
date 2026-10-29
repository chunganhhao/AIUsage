import SwiftUI
import Combine
import QuotaBackend

// MARK: - CPA Settings Categories

private enum GatewaySettingsCategory: String, CaseIterable, Identifiable {
    case runtime
    case keys
    case updates
    case versions
    case diagnostics

    var id: String { rawValue }

    var title: String {
        switch self {
        case .runtime: return L("Runtime", "运行")
        case .keys: return L("API Keys", "密钥")
        case .updates: return L("Updates", "更新")
        case .versions: return L("Versions", "版本")
        case .diagnostics: return L("Diagnostics", "诊断")
        }
    }

    var icon: String {
        switch self {
        case .runtime: return "gearshape"
        case .keys: return "key.fill"
        case .updates: return "arrow.down.circle"
        case .versions: return "shippingbox"
        case .diagnostics: return "stethoscope"
        }
    }

    var color: Color {
        switch self {
        case .runtime: return .gray
        case .keys: return .indigo
        case .updates: return .blue
        case .versions: return .orange
        case .diagnostics: return .teal
        }
    }
}

// MARK: - Settings View

struct SubscriptionGatewaySettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @ObservedObject private var navigation = CLIProxyGatewayNavigation.shared
    @Binding var draftSettings: CLIProxyGatewaySettings
    @Binding var pendingVersionDeletion: CLIProxyInstalledVersion?

    @State private var selectedCategory: GatewaySettingsCategory = .runtime
    @State private var showLANConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            settingsSidebar
            Divider()
            settingsDetail
        }
        .onAppear { consumeSettingsDestination() }
        .onChange(of: navigation.settingsDestination) { _, _ in
            consumeSettingsDestination()
        }
        .alert(L("Enable Local Network Access?", "开启局域网访问？"), isPresented: $showLANConfirmation) {
            Button(L("Enable and Apply", "开启并应用"), role: .destructive) {
                applySettings()
            }
            Button(L("Cancel", "取消"), role: .cancel) {
                draftSettings.allowLANAccess = runtime.settings.allowLANAccess
            }
        } message: {
            Text(L(
                "CPA will listen on all IPv4 interfaces over HTTP. Keep keys private; use only on trusted networks.",
                "CPA 将通过 HTTP 监听所有 IPv4 接口。请妥善保管密钥，仅在可信网络中开启。"
            ))
        }
    }

    private func consumeSettingsDestination() {
        guard let destination = navigation.settingsDestination,
              let category = GatewaySettingsCategory(rawValue: destination.rawValue) else { return }
        selectedCategory = category
        navigation.settingsDestination = nil
    }

    // MARK: - Sidebar

    private var settingsSidebar: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(GatewaySettingsCategory.allCases) { category in
                    categoryRow(category)
                }
            }
            .padding(10)
        }
        .frame(width: 168)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppSurface.sidebar(colorScheme))
    }

    private func categoryRow(_ category: GatewaySettingsCategory) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                selectedCategory = category
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: category.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(selectedCategory == category ? .white : category.color)
                    .frame(width: 20)
                Text(category.title)
                    .font(.system(size: 13, weight: selectedCategory == category ? .semibold : .regular))
                    .foregroundStyle(selectedCategory == category ? .white : .primary)
                Spacer(minLength: 0)
                if category == .runtime, hasUnappliedChanges {
                    Circle()
                        .fill(selectedCategory == category ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                } else if category == .updates, manager.hasUpdate {
                    Circle()
                        .fill(selectedCategory == category ? Color.white.opacity(0.9) : Color.orange)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selectedCategory == category ? Color.accentColor : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Detail

    @ViewBuilder
    private var settingsDetail: some View {
        switch selectedCategory {
        case .runtime:
            VStack(alignment: .leading, spacing: 12) {
                errorBanners
                SubscriptionGatewaySettingsRuntimePane(
                    runtime: runtime,
                    draftSettings: $draftSettings,
                    onApply: requestApplySettings
                )
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(.horizontal, 22)
            .padding(.top, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .keys:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    errorBanners
                    SubscriptionGatewayClientKeysPane(runtime: runtime)
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        case .updates, .versions, .diagnostics:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    errorBanners
                    switch selectedCategory {
                    case .updates:
                        updatesSection
                        TokenSaverUpdatesSection()
                    case .versions: versionsSection
                    case .diagnostics: diagnosticsSection
                    default: EmptyView()
                    }
                }
                .padding(22)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
    }

    // Runtime / Keys panes live in dedicated files.

    // MARK: - Updates

    private var updatesSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Updates", "更新")) {
                updateStatusPill
            }

            GatewayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 10) {
                        versionChip(
                            title: L("Installed", "已装"),
                            value: manager.currentVersion.map { "v\($0)" } ?? "—"
                        )
                        versionChip(
                            title: L("Latest", "最新"),
                            value: manager.latestRelease.map { "v\($0.version)" } ?? "—"
                        )
                    }

                    if manager.operation.isBusy {
                        ProgressView(operationLabel)
                    }

                    HStack {
                        if let checkedAt = manager.lastCheckedAt {
                            Text(checkedAt.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("Check", "检查")) {
                            Task { await manager.checkForUpdates(force: true) }
                        }
                        .disabled(manager.operation.isBusy)
                        Button(primaryUpdateActionTitle) {
                            Task { await manager.installOrUpdateLatest() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            manager.operation.isBusy
                                || (manager.latestRelease != nil && !manager.hasUpdate && manager.isInstalled)
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var updateStatusPill: some View {
        if manager.hasUpdate {
            GatewayQuietBadge(text: L("Update available", "有更新"), tint: .orange)
        } else if manager.isInstalled, manager.latestRelease != nil {
            GatewayQuietBadge(text: L("Up to date", "已最新"), tint: .green)
        } else if manager.isInstalled {
            GatewayQuietBadge(text: L("Not checked", "未检查"), tint: .secondary)
        }
    }

    // MARK: - Versions

    private var versionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Versions & rollback", "版本与回退"))

            GatewayCard(padding: 4) {
                if manager.installedVersions.isEmpty {
                    Text(L("No CPA versions installed.", "尚未安装 CPA。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 72)
                } else {
                    VStack(spacing: 0) {
                        ForEach(manager.installedVersions) { version in
                            HStack(spacing: 10) {
                                Image(systemName: version.isCurrent ? "checkmark.seal.fill" : "shippingbox")
                                    .foregroundStyle(version.isCurrent ? .green : .secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("v\(version.version)")
                                        .font(.subheadline.weight(.semibold).monospacedDigit())
                                    Text(version.installedAt.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                if version.isCurrent {
                                    GatewayQuietBadge(text: L("Active", "当前"), tint: .green)
                                }
                                Spacer(minLength: 8)
                                if !version.isCurrent {
                                    Button(L("Activate", "切换")) {
                                        Task { await manager.activate(version) }
                                    }
                                    Button(role: .destructive) {
                                        pendingVersionDeletion = version
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .buttonStyle(.borderless)
                                    .help(L("Delete", "删除"))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            if version.id != manager.installedVersions.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeader(title: L("Diagnostics", "诊断"))

            GatewayCard(padding: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    ScrollView {
                        Text(runtime.recentLogs.isEmpty
                             ? L("No logs yet.", "暂无日志。")
                             : runtime.recentLogs.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .topLeading)
                            .padding(10)
                    }
                    .frame(maxHeight: 280)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )

                    HStack {
                        Button {
                            manager.revealStorage()
                        } label: {
                            Label(L("Managed files", "托管文件"), systemImage: "folder")
                        }
                        Spacer()
                        Link(
                            L("Repository", "仓库"),
                            destination: URL(string: "https://github.com/router-for-me/CLIProxyAPI")!
                        )
                        .font(.caption)
                        Button(L("Notices", "许可")) {
                            manager.openThirdPartyNotices()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
        }
    }

    // MARK: - Shared chrome

    private func sectionHeader<Trailing: View>(
        title: String,
        @ViewBuilder trailing: () -> Trailing = { EmptyView() }
    ) -> some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            trailing()
        }
    }

    private func settingsRow<Trailing: View>(
        title: String,
        detail: String,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func versionChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private var hasUnappliedChanges: Bool {
        draftSettings.normalized != runtime.settings.normalized
    }

    private func requestApplySettings() {
        if draftSettings.allowLANAccess, !runtime.settings.allowLANAccess {
            showLANConfirmation = true
        } else {
            applySettings()
        }
    }

    private func applySettings() {
        Task {
            await runtime.applySettings(draftSettings)
            draftSettings = runtime.settings
            if runtime.state.isRunning { await manager.refreshAccounts() }
        }
    }

    private var primaryUpdateActionTitle: String {
        if !manager.isInstalled { return L("Install", "安装") }
        if manager.latestRelease == nil { return L("Check & Update", "检查并更新") }
        if manager.hasUpdate { return L("Update", "更新") }
        return L("Up to date", "已最新")
    }

    private var operationLabel: String {
        switch manager.operation {
        case .idle: ""
        case .checking: L("Checking…", "检查中…")
        case .downloading(let version): L("Downloading v\(version)…", "下载 v\(version)…")
        case .verifying(let version): L("Verifying v\(version)…", "校验 v\(version)…")
        case .installing(let version): L("Installing v\(version)…", "安装 v\(version)…")
        case .activating(let version): L("Activating v\(version)…", "切换到 v\(version)…")
        }
    }
}

// MARK: - Token Saver updates section

struct TokenSaverUpdatesSection: View {
    @StateObject private var manager: TokenSaverReleaseManager
    @State private var pendingInstall: TokenSaverReleaseTool?

    @MainActor
    init(manager: TokenSaverReleaseManager? = nil) {
        _manager = StateObject(wrappedValue: manager ?? TokenSaverReleaseManager())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Token Saver updates", "Token Saver 更新")).font(.title3.weight(.semibold))
            Text(L("Downloaded/staged rules are not active. Downloads reapply enabled tools to managed instruction files; a new coding session reload is required. Disabled tools remain staged only. RTK Check reads its Homebrew installed version. Saving rules can change enabled tools’ managed instruction files, but never runs downloaded scripts.",
                   "已下载/暂存的规则尚未启用；下载会将已启用的规则写入托管指令文件；需重新加载新的编程会话。未启用的工具仅暂存。RTK 检查会读取 Homebrew 已安装版本。保存规则可能修改已启用工具的托管指令文件，但不会执行下载的脚本。"))
                .font(.caption).foregroundStyle(.secondary)
            ForEach(TokenSaverReleaseTool.allCases) { tool in
                toolRow(tool)
            }
        }
        .alert(pendingInstall == .rtk ? L("Upgrade RTK with Homebrew?", "通过 Homebrew 更新 RTK？") : L("Save rules and reapply enabled tools?", "保存规则并重新应用已启用工具？"), isPresented: Binding(
            get: { pendingInstall != nil }, set: { if !$0 { pendingInstall = nil } }
        )) {
            if let tool = pendingInstall {
                Button(tool == .rtk ? L("Run brew upgrade rtk", "运行 brew upgrade rtk") : L("Save & Reapply", "保存并重新应用")) {
                    pendingInstall = nil
                    Task {
                        if tool == .rtk { await manager.updateRTK() }
                        else { await manager.stage(tool) }
                    }
                }
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingInstall = nil }
        } message: {
            if pendingInstall == .rtk {
                Text(L("Runs only brew upgrade rtk using trusted Homebrew. RTK must already be installed. Homebrew may update RTK and required dependencies outside AIUsage storage. No brew install or downloaded shell installer is run.", "仅通过可信 Homebrew 运行 brew upgrade rtk。RTK 必须已安装。Homebrew 可能在 AIUsage 存储之外更新 RTK 及必要依赖；不会运行 brew install 或下载的 Shell 安装器。"))
            } else {
            Text(L("Downloads upstream SKILL.md pinned to the checked commit into AIUsage managed storage. Git blob integrity is checked, not publisher authenticity. Enabled tools are reapplied to managed instruction files. Reload a new coding session; no scripts are executed.",
                   "从已检查的提交下载 SKILL.md 到 AIUsage 托管存储，校验 Git 内容完整性（非发布者身份认证），并将启用的工具重新写入托管指令文件。需重新加载新的编程会话；不会执行脚本。"))
            }
        }
    }

    private func toolRow(_ tool: TokenSaverReleaseTool) -> some View {
        let status = manager.statuses[tool] ?? .init()
        return GatewayCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tool.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Link(L("Upstream / manual install", "上游 / 手动安装"), destination: tool.upstreamURL).font(.caption)
                }
                HStack(alignment: .top, spacing: 16) {
                    versionLabel(tool.skillPath != nil ? L("Downloaded/staged rules", "已下载/暂存规则") : L("Installed version", "已安装版本"),
                                 status.staged?.version ?? (tool.skillPath != nil ? L("Not staged", "未暂存") : (status.installedBinaryVersion ?? (status.binaryInspected ? L("Not installed in Homebrew", "Homebrew 未安装") : L("Unknown · not inspected", "未知 · 未检测")))))
                    versionLabel(L("Latest (GitHub)", "最新（GitHub）"), status.latest?.version ?? L("Not checked", "未检查"))
                }
                if let staged = status.staged {
                    Text("\(L("Staged commit", "暂存提交")): \(staged.commit.prefix(12))").font(.caption2).foregroundStyle(.secondary)
                }
                if let notice = status.notice {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                }
                if let error = status.error {
                    Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("token-saver-\(tool.rawValue)-error")
                }
                if tool.skillPath == nil {
                    Text(L("Check reads brew list --versions rtk. Update requires confirmation and an existing Homebrew RTK installation. Other external installations are unknown; use the upstream link.",
                           "检查读取 brew list --versions rtk。更新需确认且 Homebrew 已安装 RTK。其他外部安装版本未知，请使用上游链接。"))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if status.isBusy { ProgressView().controlSize(.small) }
                    if let checked = status.checkedAt {
                        Text(checked.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L("Check", "检查")) { Task { await manager.check(tool) } }
                        .disabled(status.isBusy).accessibilityIdentifier("token-saver-\(tool.rawValue)-check")
                    Button(tool.skillPath == nil ? L("Update RTK", "更新 RTK") : (status.staged == nil ? L("Download rules", "下载规则") : L("Update staged rules", "更新暂存规则"))) { pendingInstall = tool }
                        .disabled(status.isBusy || status.latest == nil || (tool == .rtk ? (!status.brewAvailable || status.installedBinaryVersion == nil) : (status.isCurrent && status.error == nil)))
                        .accessibilityIdentifier("token-saver-\(tool.rawValue)-update")
                }
            }
        }
        .accessibilityIdentifier("token-saver-\(tool.rawValue)-release")
    }

    private func versionLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
