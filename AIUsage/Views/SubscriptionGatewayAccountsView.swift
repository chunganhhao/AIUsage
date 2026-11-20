import AppKit
import Foundation
import SwiftUI

// MARK: - CPA Account Center
// 账号中心只展示已经真实存在于 CPA 的上游。尚未同步的 AIUsage 账号走顶部
// 「可从 AIUsage 接入」入口。列表行 UI 见 GatewayAccountRow；筛选/计数见 GatewayAccountListLogic。

struct SubscriptionGatewayAccountsView: View {
    @ObservedObject var manager: CLIProxyGatewayManager
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var showAddAccount: Bool
    @Binding var pendingDeletion: CLIProxyAuthFile?

    @State private var query = ""
    @State private var filter: GatewayAccountFilter = .all
    @State private var selectedDetail: CLIProxyAuthFile?
    @State private var pendingForceSync: CLIProxyAccountSyncCandidate?
    @State private var upstreamSection: GatewayUpstreamSection = CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild ? .oauth : .apiKey
    @State private var subscriptionFlash: AppFlash?
    @State private var expandedAccountFamilies: Set<String> = []
    @State private var collapsedAccountFamilies: Set<String> = []
    @State private var isCheckingAllConnectivity = false

    var body: some View {
        let modelCounts = GatewayAccountListLogic.modelCountsByAuthFileName(manager: manager)
        let modelErrors = GatewayAccountListLogic.modelErrorNames(manager: manager)
        let connectivity = GatewayAccountListLogic.connectivityByAuthFileName(manager: manager)
        let groups = GatewayAccountListLogic.filteredGroups(
            authFiles: manager.authFiles,
            query: query,
            filter: filter,
            connectivityByAuthFileName: connectivity
        )
        let linkedCandidates = GatewayAccountListLogic.linkedCandidateByAuthFileName(manager: manager)

        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                errorBanners
                GatewaySectionTitle(
                    title: L("Account center", "账号中心"),
                    subtitle: L(
                        "Accounts managed by CPA.",
                        "由 CPA 管理的账号。"
                    ),
                    actionTitle: L("Add Account", "添加账号"),
                    actionSystemImage: "plus",
                    action: {
                        showAddAccount = true
                    }
                ) {
                    HStack(spacing: 4) {
                        GatewayHeaderIconButton(
                            systemImage: "waveform.path.ecg",
                            help: L(
                                "Check upstream connectivity · no model inference",
                                "检测上游连通性 · 不发起模型推理"
                            ),
                            isBusy: isCheckingAllConnectivity,
                            isDisabled: !runtime.state.isRunning || manager.isManagingAccounts
                        ) {
                            Task { await testAllConnectivity() }
                        }
                        GatewayHeaderIconButton(
                            systemImage: "arrow.clockwise",
                            help: L("Refresh account list", "刷新账号列表"),
                            isBusy: manager.isManagingAccounts,
                            isDisabled: !runtime.state.isRunning
                        ) {
                            Task { await manager.refreshAccounts() }
                        }
                    }
                }

                summaryRow(connectivity: connectivity)
                if unsyncedCandidateCount > 0 { aiusageEntryCard }
                searchField

                if !runtime.state.isRunning {
                    serviceStoppedState
                } else if groups.isEmpty {
                    emptyState
                } else {
                    ForEach(groups) { group in
                        providerGroup(
                            group,
                            linkedCandidates: linkedCandidates,
                            modelCounts: modelCounts,
                            modelErrors: modelErrors,
                            connectivity: connectivity
                        )
                    }
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .appFlashOverlay(subscriptionFlash)
        .sheet(isPresented: $showAddAccount) {
            CLIProxyAddUpstreamSheet(
                manager: manager,
                runtime: runtime,
                section: $upstreamSection
            )
        }
        .sheet(item: $selectedDetail) { file in
            CLIProxyAccountDetailSheet(
                file: file,
                manager: manager,
                pendingDeletion: $pendingDeletion
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

    // MARK: - Banners & Summary

    @ViewBuilder
    private var errorBanners: some View {
        if let error = manager.lastError { GatewayErrorBanner(message: error) }
        if let error = manager.syncManifestError, error != manager.lastError {
            GatewayErrorBanner(message: error)
        }
        if case .failed(let error) = runtime.state { GatewayErrorBanner(message: error) }
        if manager.authDeduplicationConflictCount > 0 { deduplicationConflictBanner }
        if runtime.clientKeyNeedsRecopy { clientKeyRotationHint }
    }

    private var clientKeyRotationHint: some View {
        GatewayCard {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "key.horizontal.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Update external clients with the new CPA key", "请用新的 CPA 密钥更新外部客户端"))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        "Old client keys fail with 401 before account failover can run. Open Connections to copy the current key (fingerprint …\(runtime.clientAPIKeyFingerprint ?? "????")).",
                        "旧客户端密钥会在账号故障转移之前就 401。打开「接入」页复制当前密钥（指纹 …\(runtime.clientAPIKeyFingerprint ?? "????")）。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var deduplicationConflictBanner: some View {
        GatewayCard {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "exclamationmark.shield.fill")
                    .foregroundStyle(.orange)
                    .font(.title3)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Managed account conflicts were kept", "托管账号冲突已保留"))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        "CPA account conflicts or failed safety checks were found for \(manager.authDeduplicationConflictCount) native account identities. AIUsage kept every unverified account and did not overwrite it.",
                        "发现 \(manager.authDeduplicationConflictCount) 组从订阅迁入的 CPA 账号存在冲突或未通过安全复核。AIUsage 已保留这些账号，没有自动删除或覆盖。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func summaryRow(
        connectivity: [String: CLIProxyAccountConnectivityState]
    ) -> some View {
        let accounts = GatewayAccountListLogic.accountFamilies(in: manager.authFiles)
        let attention = GatewayAccountListLogic.attentionAccountCount(
            in: manager.authFiles,
            deduplicationConflicts: manager.authDeduplicationConflictCount,
            hasSyncManifestError: manager.syncManifestError != nil,
            connectivityByAuthFileName: connectivity
        )
        let cooling = GatewayAccountListLogic.coolingAccountCount(in: manager.authFiles)
        let paused = GatewayAccountListLogic.pausedAccountCount(in: manager.authFiles)
        return GatewayStatCapsuleRow(
            items: [
                .init(
                    id: "all",
                    value: "\(accounts.count)",
                    title: L("in CPA", "CPA 账号"),
                    systemImage: "person.2.fill",
                    tint: .indigo
                ),
                .init(
                    id: "ready",
                    value: "\(GatewayAccountListLogic.connectedAccountCount(in: manager.authFiles, connectivityByAuthFileName: connectivity))",
                    title: L("connected", "已连通"),
                    systemImage: "antenna.radiowaves.left.and.right",
                    tint: .blue
                ),
                .init(
                    id: "cooling",
                    value: "\(cooling)",
                    title: L("limited", "暂时受限"),
                    systemImage: "thermometer.medium",
                    tint: .orange
                ),
                .init(
                    id: "paused",
                    value: "\(paused)",
                    title: L("paused", "已停用"),
                    systemImage: "pause.circle.fill",
                    tint: .secondary
                ),
                .init(
                    id: "attention",
                    value: "\(attention)",
                    title: L("need attention", "需要处理"),
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                ),
                .init(
                    id: "fromAIUsage",
                    value: "\(GatewayAccountListLogic.managedAccountCount(in: manager.authFiles))",
                    title: L("from Subscription", "来自订阅"),
                    systemImage: "arrow.right.circle.fill",
                    tint: .blue
                ),
            ],
            selectedId: filter.rawValue,
            onSelect: { id in
                // 顶部胶囊即筛选；再点同一项回到全部。下方不再重复一排筛选项。
                withAnimation(.easeInOut(duration: 0.15)) {
                    if filter.rawValue == id {
                        filter = .all
                    } else if let next = GatewayAccountFilter(rawValue: id) {
                        filter = next
                    }
                }
            }
        )
    }

    private var aiusageEntryCard: some View {
        Button {
            upstreamSection = .aiusage
            showAddAccount = true
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                Text(L(
                    "\(unsyncedCandidateCount) AIUsage account(s) can be connected to CPA",
                    "可从 AIUsage 接入 \(unsyncedCandidateCount) 个账号"
                ))
                .font(.subheadline.weight(.semibold))
                Spacer()
                Text(L("Connect", "去接入"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.blue)
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 15)
            .padding(.vertical, 12)
            .background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.blue.opacity(0.14)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L(
            "Connect \(unsyncedCandidateCount) AIUsage accounts to CPA",
            "可从 AIUsage 接入 \(unsyncedCandidateCount) 个账号"
        ))
    }

    // MARK: - Search
    // 筛选由顶部统计胶囊承担；此处只保留搜索。

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(L("Search accounts", "搜索账号"), text: $query)
                .textFieldStyle(.plain)
                .accessibilityLabel(L("Search gateway accounts", "搜索网关账号"))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(L("Clear search", "清除搜索"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.045), in: Capsule())
    }

    // MARK: - Groups & Rows

    private func providerGroup(
        _ group: GatewayAccountGroup,
        linkedCandidates: [String: CLIProxyAccountSyncCandidate],
        modelCounts: [String: Int],
        modelErrors: Set<String>,
        connectivity: [String: CLIProxyAccountConnectivityState]
    ) -> some View {
        let families = GatewayAccountListLogic.accountFamilies(in: group)
        return GatewayCard(padding: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    GatewayProviderIcon(providerID: group.providerID, size: 26)
                    Text(gatewayProviderDisplayName(group.providerID))
                        .font(.subheadline.weight(.semibold))
                    Text(L(
                        families.count == 1 ? "1 account" : "\(families.count) accounts",
                        "\(families.count) 个账号"
                    ))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.055), in: Capsule())
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider()

                ForEach(Array(families.enumerated()), id: \.element.id) { familyIndex, family in
                    if familyIndex > 0 { Divider() }
                    if family.showsProjectHierarchy {
                        let isExpanded = isFamilyExpanded(family)
                        GatewayAccountFamilyRow(
                            family: family,
                            identity: family.primaryFile.flatMap { manager.accountIdentity(for: $0) },
                            linkedCandidate: family.primaryFile.flatMap {
                                linkedCandidates[$0.name.lowercased()]
                            },
                            connectivityByFileName: connectivity,
                            isExpanded: isExpanded,
                            isBusy: manager.isManagingAccounts,
                            onToggleExpansion: { toggleFamilyExpansion(family) },
                            onSetEnabled: { enabled in
                                Task { await setFamily(family, enabled: enabled) }
                            },
                            onOpenDetail: {
                                selectedDetail = family.primaryFile
                            },
                            onCheckConnectivity: {
                                Task { await testConnectivity(family) }
                            },
                            onRequestSync: requestSync,
                            onAddToSubscription: {
                                guard let primaryFile = family.primaryFile else { return }
                                Task { await addToSubscription(primaryFile) }
                            },
                            showsAddToSubscription: family.primaryFile.map(canAddToSubscription) ?? false
                        )
                        if isExpanded {
                            Divider().padding(.leading, 58)
                            ForEach(Array(family.files.enumerated()), id: \.element.id) { index, file in
                                accountRow(
                                    file,
                                    presentation: file.runtimeOnly ? .project : .loginDetails,
                                    linkedCandidates: linkedCandidates,
                                    modelCounts: modelCounts,
                                    modelErrors: modelErrors,
                                    connectivity: connectivity
                                )
                                if index < family.files.count - 1 {
                                    Divider().padding(.leading, 92)
                                }
                            }
                        }
                    } else if let file = family.primaryFile {
                        accountRow(
                            file,
                            presentation: .account,
                            linkedCandidates: linkedCandidates,
                            modelCounts: modelCounts,
                            modelErrors: modelErrors,
                            connectivity: connectivity
                        )
                    }
                }
            }
        }
    }

    private func isFamilyExpanded(_ family: GatewayAccountFamily) -> Bool {
        let isFocused = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || filter != .all
        if isFocused { return true }
        if collapsedAccountFamilies.contains(family.id) { return false }
        return expandedAccountFamilies.contains(family.id)
    }

    private func toggleFamilyExpansion(_ family: GatewayAccountFamily) {
        withAnimation(.easeInOut(duration: 0.18)) {
            if isFamilyExpanded(family) {
                expandedAccountFamilies.remove(family.id)
                collapsedAccountFamilies.insert(family.id)
            } else {
                collapsedAccountFamilies.remove(family.id)
                expandedAccountFamilies.insert(family.id)
            }
        }
    }

    private func setFamily(_ family: GatewayAccountFamily, enabled: Bool) async {
        await manager.setAuthFiles(family.files, disabled: !enabled)
    }

    private func accountRow(
        _ file: CLIProxyAuthFile,
        presentation: GatewayAccountRowPresentation,
        linkedCandidates: [String: CLIProxyAccountSyncCandidate],
        modelCounts: [String: Int],
        modelErrors: Set<String>,
        connectivity: [String: CLIProxyAccountConnectivityState]
    ) -> some View {
        let key = file.name.lowercased()
        let failed = modelErrors.contains(key)
        return GatewayAccountRow(
            file: file,
            identity: manager.accountIdentity(for: file),
            linkedCandidate: linkedCandidates[key],
            isBusy: manager.isManagingAccounts,
            modelCount: failed ? nil : modelCounts[key],
            modelLoadFailed: failed,
            connectivityState: connectivity[key],
            presentation: presentation,
            onOpenDetail: { selectedDetail = file },
            onRequestSync: requestSync,
            onCheckConnectivity: {
                Task { await testConnectivity(file) }
            },
            onSetEnabled: { enabled in
                Task {
                    await manager.setAuthFile(file, disabled: !enabled)
                    if enabled {
                        await manager.loadModels(for: file, force: true)
                    }
                }
            },
            onAddToSubscription: {
                Task { await addToSubscription(file) }
            },
            onDelete: { pendingDeletion = file },
            showsAddToSubscription: presentation == .account && canAddToSubscription(file)
        )
    }

    private func canAddToSubscription(_ file: CLIProxyAuthFile) -> Bool {
        !file.runtimeOnly && ["codex", "antigravity", "gemini", "gemini-cli"]
            .contains(file.gatewayProviderID.lowercased())
    }

    private func requestSync(_ candidate: CLIProxyAccountSyncCandidate) {
        pendingForceSync = candidate
    }

    private func testConnectivity(_ file: CLIProxyAuthFile) async {
        let result = await manager.testAccountConnectivity(for: file)
        switch result.state {
        case .connected:
            subscriptionFlash = .success(L(
                "\(file.displayLabel) · connected · no model inference",
                "\(file.displayLabel) · 已连通 · 未发起模型推理"
            ))
        case .unsupported:
            subscriptionFlash = .info("\(file.displayLabel) · \(result.detail)")
        case .failed:
            subscriptionFlash = .error(L(
                "\(file.displayLabel) connection issue · \(result.detail)",
                "\(file.displayLabel) 连通异常 · \(result.detail)"
            ))
        case .checking:
            break
        }
    }

    private func testConnectivity(_ family: GatewayAccountFamily) async {
        let targets = family.loginFiles.isEmpty ? family.files : family.loginFiles
        let results = await manager.testFamilyAccountConnectivity(targets)
        let connected = results.filter { $0.state.isConnected }.count
        let failed = results.filter { $0.state.needsAttention }.count
        if connected > 0, failed == 0 {
            subscriptionFlash = .success(L(
                "\(family.accountLabel) · connected · no model inference",
                "\(family.accountLabel) · 已连通 · 未发起模型推理"
            ))
        } else if connected == 0, failed == 0 {
            subscriptionFlash = .info(L(
                "\(family.accountLabel) · catalog only; upstream check is unavailable",
                "\(family.accountLabel) · 仅提供模型目录，暂不支持上游检测"
            ))
        } else {
            subscriptionFlash = .error(L(
                "\(family.accountLabel) · \(failed) connectivity check(s) failed",
                "\(family.accountLabel) · \(failed) 项连通检测失败"
            ))
        }
    }

    private func testAllConnectivity() async {
        guard !isCheckingAllConnectivity else { return }
        isCheckingAllConnectivity = true
        defer { isCheckingAllConnectivity = false }
        let results = await manager.testAllAccountConnectivity()
        let connected = results.filter { $0.state.isConnected }.count
        let failed = results.filter { $0.state.needsAttention }.count
        if results.isEmpty {
            subscriptionFlash = .info(L(
                "No account supports an inference-free upstream check.",
                "当前没有可在不发起模型推理的情况下进行上游检测的账号。"
            ))
        } else if failed == 0 {
            subscriptionFlash = .success(L(
                "\(connected) account(s) connected · no model inference",
                "\(connected) 个账号已连通 · 未发起模型推理"
            ))
        } else {
            subscriptionFlash = .error(L(
                "\(connected) connected · \(failed) need attention",
                "\(connected) 个已连通 · \(failed) 个需处理"
            ))
        }
    }

    private func addToSubscription(_ file: CLIProxyAuthFile) async {
        let outcome = await CLIProxyGatewayManager.shared.addAuthFileToSubscriptionAccounts(file)
        let flash: AppFlash
        switch outcome {
        case .added(let name):
            flash = .success(L(
                "Added to Subscription Accounts · \(name)",
                "已加入订阅账号 · \(name)"
            ))
        case .alreadyPresent(let name):
            flash = .info(L(
                "Already in Subscription Accounts · \(name)",
                "订阅账号中已有 · \(name)"
            ))
        case .unsupported:
            flash = .info(L(
                "This provider can’t be added from CPA yet.",
                "该服务商暂不支持从 CPA 添加。"
            ))
        case .failed(let message):
            flash = .error(message)
        }
        await MainActor.run {
            AppFlashPresenter.present(flash, into: $subscriptionFlash)
        }
    }

    // MARK: - Empty / Stopped

    private var serviceStoppedState: some View {
        GatewayCard {
            VStack(spacing: 14) {
                Image(systemName: "power.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.secondary)
                Text(manager.isInstalled
                     ? L("Start CPA to view and manage accounts", "启动 CPA 后即可查看和管理账号")
                     : L("Install CPA to add and manage accounts", "安装 CPA 后即可添加和管理账号"))
                    .font(.headline)
                Text(L(
                    manager.isInstalled
                        ? "Your AIUsage subscription accounts are not changed when CPA is stopped."
                        : "AIUsage downloads and verifies the official macOS runtime before it is started.",
                    manager.isInstalled
                        ? "CPA 停止时，AIUsage 中的订阅账号不会受到影响。"
                        : "AIUsage 会先下载并校验官方 macOS 运行时，再启动服务。"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                Button(manager.isInstalled ? L("Start CPA", "启动 CPA") : L("Install latest CPA", "安装最新版 CPA")) {
                    beginAccountPrerequisite()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.operation.isBusy || runtime.state.isTransitioning)
                if manager.operation.isBusy || runtime.state.isTransitioning {
                    ProgressView().controlSize(.small)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private var emptyState: some View {
        GatewayCard {
            VStack(spacing: 14) {
                Image(systemName: query.isEmpty ? "person.2.badge.plus" : "magnifyingglass")
                    .font(.system(size: 34))
                    .foregroundStyle(.indigo)
                Text(query.isEmpty
                     ? L("No accounts yet", "还没有账号")
                     : L("No matching accounts", "没有匹配的账号"))
                    .font(.headline)
                Text(query.isEmpty
                     ? (CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                        ? L("Add an account with web sign-in, an official plugin, a Subscription account, an API key, or an account file.", "可通过网页登录、官方插件、订阅账号、API Key 或账号文件添加。")
                        : L("CPA subscription accounts are unavailable in this build. Add an official OpenAI-compatible API-key upstream instead.", "当前构建已停用 CPA 订阅账号；请改为配置官方 OpenAI 兼容 API Key 上游。"))
                     : L("Try a different search or status filter.", "请尝试其他搜索词或状态筛选。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if query.isEmpty {
                    Button(L("Add Account", "添加账号")) {
                        upstreamSection = CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild ? .oauth : .apiKey
                        showAddAccount = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220)
        }
    }

    private var unsyncedCandidateCount: Int {
        GatewayAccountListLogic.unsyncedCandidateCount(manager: manager)
    }

    private func beginAccountPrerequisite() {
        Task {
            if !manager.isInstalled { await manager.installOrUpdateLatest() }
            guard manager.isInstalled else { return }
            await runtime.start()
            if runtime.state.isRunning { await manager.refreshAccounts() }
        }
    }
}
