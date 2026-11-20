import AppKit
import SwiftUI

private struct GatewayModelProviderGroup: Identifiable {
    let id: String
    let totalCount: Int
    let models: [CLIProxyModelCatalogEntry]
}

private func gatewayModelProviderTitle(_ providerID: String) -> String {
    switch providerID {
    case "openai": L("OpenAI", "OpenAI")
    case "claude": L("Anthropic", "Anthropic")
    case "gemini": L("Google", "Google")
    case "xai": L("xAI", "xAI")
    case "kimi": L("Kimi", "Kimi")
    case "minimax": L("MiniMax", "MiniMax")
    default: L("Custom / other", "自定义 / 其他")
    }
}

private func gatewayModelProviderSortOrder(_ providerID: String) -> Int {
    switch providerID {
    case "openai": 0
    case "claude": 1
    case "gemini": 2
    case "xai": 3
    case "kimi": 4
    case "minimax": 5
    default: 9
    }
}

private func gatewayModelAPIDetail(_ modelProtocol: CLIProxyModelProtocol) -> String {
    switch modelProtocol {
    case .openAI:
        L("Use this route ID with OpenAI-compatible clients. Available endpoints depend on the model and CPA route.",
          "此路由 ID 用于 OpenAI 兼容客户端；实际可用端点取决于模型与 CPA 路由。")
    case .anthropic:
        L("Use with Anthropic Messages clients. CPA may require a compatibility route ID.",
          "用于 Anthropic Messages 客户端；CPA 可能要求使用兼容路由 ID。")
    case .gemini:
        L("Use with Gemini native REST or Google GenAI clients.",
          "用于 Gemini 原生 REST 或 Google GenAI 客户端。")
    }
}

struct SubscriptionGatewayOverviewView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var showAddAccount: Bool
    @ObservedObject private var navigation = CLIProxyGatewayNavigation.shared
    @State private var modelQuery = ""
    @State private var showAllModels = false
    @State private var selectedModel: CLIProxyModelCatalogEntry?

    private let modelColumns = [GridItem(.adaptive(minimum: 220), spacing: 8)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                errorBanners

                GatewayStatCapsuleRow(items: overviewStatItems)

                if manager.isInstalled {
                    compactServiceBar
                }

                nextStepCard
                modelCatalogCard
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .sheet(item: $selectedModel) { entry in
            GatewayModelDetailSheet(entry: entry)
        }
        .task(id: runtime.state.isRunning) {
            guard runtime.state.isRunning else { return }
            await manager.refreshAvailableModels()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    return
                }
                await manager.refreshAvailableModels()
            }
        }
    }

    private var overviewStatItems: [GatewayStatCapsuleRow.Item] {
        [
            .init(
                id: "accounts",
                value: "\(readyAccountCount)/\(manager.authFiles.count)",
                title: L("Accounts", "账号"),
                systemImage: "person.2.fill",
                tint: .indigo
            ),
            .init(
                id: "models",
                value: "\(manager.modelCatalog.count)",
                title: L("Models", "模型"),
                systemImage: "square.stack.3d.up.fill",
                tint: .purple
            ),
            .init(
                id: "apps",
                value: "\(connectedApplicationCount)/\(ProxyTarget.localProxyTargets.count)",
                title: L("Connected apps", "已接入"),
                systemImage: "arrow.triangle.branch",
                tint: .blue
            ),
            .init(
                id: "version",
                value: manager.currentVersion.map { "v\($0)" } ?? "—",
                title: manager.hasUpdate
                    ? L("Update available", "有更新")
                    : L("CPA version", "CPA 版本"),
                systemImage: manager.hasUpdate ? "arrow.down.circle.fill" : "checkmark.seal.fill",
                tint: manager.hasUpdate ? .orange : .green
            ),
        ]
    }

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError {
            GatewayErrorBanner(message: error)
        }
        if case .failed(let error) = runtime.state {
            GatewayErrorBanner(message: error)
        }
    }

    @ViewBuilder
    private var nextStepCard: some View {
        if !manager.isInstalled {
            onboardingCard(
                icon: "square.and.arrow.down.fill",
                tint: .blue,
                title: L("Install the managed CPA runtime", "安装托管的 CPA 运行时"),
                detail: L(
                    "Install and update CPA inside AIUsage, with independent rollback copies.",
                    "直接在 AIUsage 内安装、更新 CPA，并保留独立的回退版本。"
                ),
                actionTitle: L("Install latest CPA", "安装最新版 CPA")
            ) { Task { await manager.installOrUpdateLatest() } }
        } else if runtime.state.isRunning, manager.authFiles.isEmpty {
            onboardingCard(
                icon: "person.badge.plus",
                tint: .indigo,
                title: L("Add your first upstream", "添加第一个上游"),
                detail: CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                    ? L(
                        "Use CPA OAuth, an official plugin, a compatible AIUsage account, an API key, or a migrated auth file.",
                        "可通过 CPA OAuth、官方插件、兼容的 AIUsage 账号、API Key 或迁移认证文件添加上游。"
                    )
                    : L(
                        "Configure an official OpenAI-compatible API-key upstream. CPA subscription accounts are unavailable in this build.",
                        "请配置官方 OpenAI 兼容 API Key 上游；当前构建不提供 CPA 订阅账号接入。"
                    ),
                actionTitle: L("Add upstream", "添加上游")
            ) {
                navigation.showAccounts(openAddAccount: true)
                showAddAccount = true
            }
        } else if runtime.state.isRunning, connectedTargets.isEmpty {
            onboardingCard(
                icon: "arrow.triangle.branch",
                tint: .purple,
                title: L("Connect the gateway to your apps", "把网关接入应用"),
                detail: L(
                    "Your CPA account pool is ready. Choose which AIUsage proxies should receive the managed gateway node.",
                    "CPA 账号池已经就绪，接下来选择要接收托管网关节点的 AIUsage 代理。"
                ),
                actionTitle: L("Choose apps", "选择接入应用")
            ) { navigation.selectedSection = .connections }
        }
    }

    private func onboardingCard(
        icon: String,
        tint: Color,
        title: String,
        detail: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button(actionTitle, action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(manager.operation.isBusy || runtime.state.isTransitioning)
        }
        .padding(12)
        .background(tint.opacity(0.07), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.14), lineWidth: 1)
        )
    }

    private var modelCatalogCard: some View {
        GatewayCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Available models", "可用模型")).font(.headline)
                        Text(modelCatalogDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    GatewayStatusPill(
                        text: runtime.state.isRunning
                            ? L("\(manager.modelCatalog.count) models", "\(manager.modelCatalog.count) 个模型")
                            : L("Offline", "未运行"),
                        color: runtime.state.isRunning ? .green : .secondary,
                        systemImage: runtime.state.isRunning ? "dot.radiowaves.left.and.right" : "circle"
                    )
                    Button {
                        Task { await manager.refreshAvailableModels() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!runtime.state.isRunning || manager.isRefreshingModels)
                    .help(L("Refresh model catalog", "刷新模型目录"))
                    .accessibilityLabel(L("Refresh model catalog", "刷新模型目录"))
                }

                if manager.modelCatalog.count > 8 || !normalizedModelQuery.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        TextField(L("Search models", "搜索模型"), text: $modelQuery)
                            .textFieldStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel(L("Search live models", "搜索实时模型"))
                }

                if let error = manager.modelCatalogError, runtime.state.isRunning {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(L("Model refresh failed: \(error)", "模型刷新失败：\(error)"))
                            .textSelection(.enabled)
                    }
                    .font(.caption)
                    .foregroundStyle(.orange)
                } else if !manager.unavailableModelProtocols.isEmpty, runtime.state.isRunning {
                    HStack(spacing: 8) {
                        Image(systemName: "info.circle")
                        Text(L(
                            "Partial catalog: \(unavailableProtocolNames) could not be read.",
                            "目录不完整：暂时无法读取 \(unavailableProtocolNames)。"
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } else if !runtime.state.isRunning && !manager.modelCatalog.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "clock.arrow.circlepath")
                        Text(L(
                            "CPA is offline; showing the last successful catalog.",
                            "CPA 当前未运行，下面显示上次成功读取的目录。"
                        ))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                if !runtime.state.isRunning && manager.modelCatalog.isEmpty {
                    compactModelEmptyState(
                        icon: "play.circle",
                        text: L("Start CPA to load its current model catalog.", "启动 CPA 后即可载入当前模型目录。")
                    )
                } else if manager.isRefreshingModels && manager.modelCatalog.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading models…", "正在载入模型…"))
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                } else if filteredModels.isEmpty {
                    compactModelEmptyState(
                        icon: modelQuery.isEmpty ? "square.stack.3d.up.slash" : "magnifyingglass",
                        text: modelQuery.isEmpty
                            ? L("CPA reported no models.", "CPA 当前未上报模型。")
                            : L("No model matches this search.", "没有匹配的模型。")
                    )
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(visibleModelGroups) { group in
                            VStack(alignment: .leading, spacing: 9) {
                                HStack(spacing: 8) {
                                    GatewayProviderIcon(providerID: group.id, size: 24)
                                    Text(gatewayModelProviderTitle(group.id))
                                        .font(.subheadline.weight(.semibold))
                                    Text(L("\(group.totalCount) models", "\(group.totalCount) 个模型"))
                                        .font(.caption2.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.055), in: Capsule())
                                }
                                LazyVGrid(columns: modelColumns, alignment: .leading, spacing: 9) {
                                    ForEach(group.models) { model in
                                        modelRow(model)
                                    }
                                }
                            }
                        }
                    }
                    if hasCollapsedModelOverflow && normalizedModelQuery.isEmpty {
                        Button(showAllModels
                               ? L("Show fewer", "收起")
                               : L(
                                    "Show all \(filteredModels.count) models",
                                    "查看全部 \(filteredModels.count) 个模型"
                               )) {
                            showAllModels.toggle()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private func modelRow(_ entry: CLIProxyModelCatalogEntry) -> some View {
        let model = entry.model
        return Button {
            selectedModel = entry
        } label: {
            HStack(spacing: 8) {
                GatewayProviderIcon(providerID: entry.providerID, size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName?.nilIfBlank ?? model.id)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(model.id)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.quaternary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(L("Copy canonical model ID", "复制规范模型 ID")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.id, forType: .string)
            }
            Button(L("Show API-specific IDs", "查看各 API 专用 ID")) {
                selectedModel = entry
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(L("Shows the model IDs required by each compatible API.", "查看每种兼容 API 所需的模型 ID。"))
    }

    private func compactModelEmptyState(icon: String, text: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: icon).foregroundStyle(.secondary)
            Text(text)
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
    }

    private var compactServiceBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(runtime.state.isRunning ? Color.green : (runtime.hasUnconfirmedListener ? Color.orange : Color.secondary.opacity(0.45)))
                .frame(width: 8, height: 8)
            Text(
                runtime.state.isRunning
                    ? L("CPA running", "CPA 运行中")
                    : (runtime.hasUnconfirmedListener ? L("CPA stop unconfirmed", "CPA 停止未确认") : L("CPA stopped", "CPA 已停止"))
            )
                .font(.caption.weight(.semibold))
            Text(runtime.baseURL.absoluteString)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            if runtime.settings.allowLANAccess {
                GatewayQuietBadge(text: L("LAN", "局域网"), tint: .orange)
            }
            Spacer(minLength: 8)
            Button {
                Task {
                    if runtime.state.isRunning || runtime.hasUnconfirmedListener {
                        await runtime.stop()
                    } else {
                        await runtime.start()
                        if runtime.state.isRunning { await manager.refreshAccounts() }
                    }
                }
            } label: {
                Label(
                    runtime.state.isRunning
                        ? L("Stop", "停止")
                        : (runtime.hasUnconfirmedListener ? L("Verify Stop", "验证停止") : L("Start", "启动")),
                    systemImage: (runtime.state.isRunning || runtime.hasUnconfirmedListener) ? "stop.fill" : "play.fill"
                )
                .font(.caption.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(runtime.state.isTransitioning || !manager.isInstalled)

            Button {
                Task { await manager.refreshAccounts() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(!runtime.state.isRunning || manager.isManagingAccounts)
            .help(L("Refresh", "刷新"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(serviceDetail)
    }

    private var readyAccountCount: Int {
        manager.authFiles.filter { !$0.disabled && !$0.unavailable && !$0.gatewayNeedsAttention }.count
    }

    private var connectedTargets: Set<ProxyTarget> {
        manager.currentDistributionTargets
    }

    private var filteredModels: [CLIProxyModelCatalogEntry] {
        let query = normalizedModelQuery
        let models = manager.modelCatalog.filter { entry in
            guard !query.isEmpty else { return true }
            let model = entry.model
            let routeIDs = entry.routeIDs.values.flatMap { $0 }
            return ([
                model.id,
                model.displayName ?? "",
                model.ownedBy ?? "",
                model.type ?? "",
                gatewayModelProviderTitle(entry.providerID),
                protocolNames(entry.protocols)
            ] + routeIDs)
                .joined(separator: " ")
                .lowercased()
                .contains(query)
        }
        return models.sorted { lhs, rhs in
            let lhsProvider = gatewayModelProviderSortOrder(lhs.providerID)
            let rhsProvider = gatewayModelProviderSortOrder(rhs.providerID)
            if lhsProvider != rhsProvider { return lhsProvider < rhsProvider }
            let lhsTitle = lhs.model.displayName?.nilIfBlank ?? lhs.model.id
            let rhsTitle = rhs.model.displayName?.nilIfBlank ?? rhs.model.id
            return lhsTitle.localizedStandardCompare(rhsTitle) == .orderedAscending
        }
    }

    private var visibleModelGroups: [GatewayModelProviderGroup] {
        Dictionary(grouping: filteredModels, by: \.providerID)
            .map { providerID, models in
                let visible = showAllModels || !normalizedModelQuery.isEmpty
                    ? models
                    : Array(models.prefix(4))
                return GatewayModelProviderGroup(
                    id: providerID,
                    totalCount: models.count,
                    models: visible
                )
            }
            .sorted {
                let lhsOrder = gatewayModelProviderSortOrder($0.id)
                let rhsOrder = gatewayModelProviderSortOrder($1.id)
                if lhsOrder != rhsOrder { return lhsOrder < rhsOrder }
                return gatewayModelProviderTitle($0.id)
                    .localizedStandardCompare(gatewayModelProviderTitle($1.id)) == .orderedAscending
            }
    }

    private var hasCollapsedModelOverflow: Bool {
        Dictionary(grouping: filteredModels, by: \.providerID)
            .values
            .contains { $0.count > 4 }
    }

    private var normalizedModelQuery: String {
        modelQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var connectedApplicationCount: Int {
        connectedTargets.intersection(Set(ProxyTarget.localProxyTargets)).count
    }

    private var modelCatalogDetail: String {
        guard let updatedAt = manager.modelCatalogUpdatedAt else {
            return L("Auto-refreshes from CPA while this page is open", "页面打开时自动从 CPA 刷新")
        }
        return L(
            "Updated at \(updatedAt.formatted(date: .omitted, time: .shortened)) · refreshes every 30s",
            "更新于 \(updatedAt.formatted(date: .omitted, time: .shortened)) · 每 30 秒刷新"
        )
    }

    private func protocolNames(_ protocols: Set<CLIProxyModelProtocol>) -> String {
        protocols.sorted { $0.sortOrder < $1.sortOrder }.map(\.title).joined(separator: " · ")
    }

    private var unavailableProtocolNames: String {
        protocolNames(manager.unavailableModelProtocols)
    }

    private var serviceDetail: String {
        let access = runtime.settings.allowLANAccess
            ? L("This Mac and local network", "本机与局域网")
            : L("This Mac only", "仅限本机")
        if case .running(let pid) = runtime.state {
            return "\(access) · PID \(pid)"
        }
        return L(
            "\(access) · port \(runtime.settings.normalized.port)",
            "\(access) · 端口 \(runtime.settings.normalized.port)"
        )
    }
}

private struct GatewayModelDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: CLIProxyModelCatalogEntry

    private var sortedProtocols: [CLIProxyModelProtocol] {
        entry.protocols.sorted { $0.sortOrder < $1.sortOrder }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 13) {
                GatewayProviderIcon(providerID: entry.providerID, size: 42)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.model.displayName?.nilIfBlank ?? entry.model.id)
                        .font(.title3.weight(.semibold))
                    Text(gatewayModelProviderTitle(entry.providerID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Close", "关闭"))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .foregroundStyle(Color.accentColor)
                        Text(L(
                            "CPA can expose one logical model under different route IDs. Choose the ID below that matches the API format used by your client.",
                            "CPA 可能会为同一个逻辑模型提供不同的路由 ID。请按客户端实际使用的 API 格式选择下方对应 ID。"
                        ))
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                    .padding(13)
                    .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 11))

                    GatewayCopyField(
                        label: L("Canonical model ID", "规范模型 ID"),
                        value: entry.model.id
                    )

                    ForEach(sortedProtocols) { modelProtocol in
                        GatewayCard(padding: 14) {
                            VStack(alignment: .leading, spacing: 11) {
                                HStack(spacing: 8) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .foregroundStyle(Color.accentColor)
                                    Text(modelProtocol.title).font(.headline)
                                    Spacer()
                                    GatewayStatusPill(
                                        text: L("Available", "可用"),
                                        color: .green,
                                        systemImage: "checkmark.circle.fill"
                                    )
                                }
                                Text(gatewayModelAPIDetail(modelProtocol))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)

                                let models = entry.models(for: modelProtocol)
                                ForEach(Array(models.enumerated()), id: \.element.id) { index, model in
                                    GatewayCopyField(
                                        label: models.count == 1
                                            ? L("Model ID for this API", "该 API 使用的模型 ID")
                                            : L("Model ID \(index + 1)", "模型 ID \(index + 1)"),
                                        value: model.id,
                                        wraps: true
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: 560, idealWidth: 640, maxWidth: 700,
               minHeight: 460, idealHeight: 570, maxHeight: 680)
    }
}
