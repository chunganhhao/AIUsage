import SwiftUI

// MARK: - CPA Account Detail Sheet
// 可读优先：头图身份 + 备注展示、模型列表、折叠技术信息。
// 备注默认不是编辑态；点「编辑」才进入输入。

struct CLIProxyAccountDetailSheet: View {
    let file: CLIProxyAuthFile
    @ObservedObject var manager: CLIProxyGatewayManager
    @Binding var pendingDeletion: CLIProxyAuthFile?
    @Environment(\.dismiss) private var dismiss

    @State private var draftNote: String
    @State private var draftPriority: Int
    @State private var isEditingNote = false
    @State private var showAllModels = false
    @State private var showTechnical = false
    @State private var operationError: String?
    @State private var isUpdating = false
    @State private var isLoadingModels = false
    @State private var isCheckingConnectivity = false
    @State private var connectivityMessage: String?

    init(
        file: CLIProxyAuthFile,
        manager: CLIProxyGatewayManager,
        pendingDeletion: Binding<CLIProxyAuthFile?>
    ) {
        self.file = file
        self.manager = manager
        self._pendingDeletion = pendingDeletion
        self._draftNote = State(initialValue: GatewayAccountNote.visible(file.note) ?? "")
        self._draftPriority = State(initialValue: file.priority ?? 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let operationError { GatewayErrorBanner(message: operationError) }

                    statusStrip
                    if let connectivityMessage {
                        Label(connectivityMessage, systemImage: "network")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !currentFile.runtimeOnly {
                        noteCard
                    }

                    modelsCard

                    DisclosureGroup(isExpanded: $showTechnical) {
                        VStack(alignment: .leading, spacing: 10) {
                            detailRow(L("Provider", "提供商"), currentFile.displayProvider)
                            detailRow(L("Source", "来源"), currentFile.gatewaySourceTitle)
                            detailRow(L("Auth file", "认证文件"), currentFile.name)
                            if let plan = currentIdentity?.resolvedPlanDisplayName {
                                detailRow(L("Plan", "套餐"), plan)
                            }
                            if let accountID = currentIdentity?.accountID {
                                detailRow(L("Workspace ID", "工作区 ID"), accountID)
                            }
                            if let projectID = currentIdentity?.projectID ?? currentFile.projectID {
                                detailRow(L("Project", "项目"), projectID)
                            }
                            if let refreshed = currentFile.lastRefresh {
                                detailRow(
                                    L("Last refresh", "上次刷新"),
                                    refreshed.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                            if let nextRetry = currentFile.nextRetryAfter {
                                detailRow(
                                    L("Next retry", "下次重试"),
                                    nextRetry.formatted(date: .abbreviated, time: .shortened)
                                )
                            }
                            if !currentFile.runtimeOnly {
                                HStack {
                                    Text(L("Priority", "优先级"))
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                    Stepper(value: $draftPriority, in: -100...100) {
                                        Text("\(draftPriority)")
                                            .monospacedDigit()
                                            .frame(width: 36, alignment: .trailing)
                                    }
                                }
                                if draftPriority != (currentFile.priority ?? 0) {
                                    Button(L("Save priority", "保存优先级")) {
                                        saveMetadata(
                                            note: GatewayAccountNote.visible(currentFile.note) ?? "",
                                            priority: draftPriority
                                        )
                                    }
                                    .buttonStyle(.borderless)
                                }
                            }
                        }
                        .padding(.top, 8)
                    } label: {
                        Text(L("Technical details", "技术详情"))
                            .font(.subheadline.weight(.semibold))
                    }

                    actionBar
                }
                .padding(20)
            }
        }
        .frame(minWidth: 520, idealWidth: 580, maxWidth: 620,
               minHeight: 420, idealHeight: 520, maxHeight: 640)
        .task { loadModels(force: false) }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 13) {
            GatewayProviderIcon(providerID: currentFile.gatewayProviderID, size: 46)
            VStack(alignment: .leading, spacing: 4) {
                Text(currentFile.displayLabel)
                    .font(.title3.weight(.bold))
                    .lineLimit(2)
                Text(gatewayAccountIdentitySubtitle(
                    providerID: currentFile.gatewayProviderID,
                    identity: currentIdentity
                ))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let note = currentFile.gatewayVisibleNote, !isEditingNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Button(L("Done", "完成")) { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }

    private var statusStrip: some View {
        HStack(spacing: 10) {
            compactStat(
                "\(currentFile.success)",
                L("OK", "成功"),
                .green
            )
            compactStat(
                "\(currentFile.failed)",
                L("Fail", "失败"),
                currentFile.failed > 0 ? .orange : .secondary
            )
            compactStat(
                modelsReadyLabel,
                L("Models", "模型"),
                .indigo
            )
            Spacer(minLength: 0)
            statusChip
        }
    }

    private var modelsReadyLabel: String {
        if isLoadingModels { return "…" }
        if manager.authFileModelErrors[currentFile.name] != nil { return "—" }
        return "\(models.count)"
    }

    private var statusChip: some View {
        let paused = currentFile.disabled
        let cooling = !paused && (
            currentFile.unavailable
                || (currentFile.nextRetryAfter.map { $0 > Date() } ?? false)
        )
        let text: String
        let tint: Color
        if paused {
            text = L("Paused", "已停用"); tint = .secondary
        } else if cooling {
            text = L("Cooling", "冷却中"); tint = .orange
        } else {
            switch manager.connectivityState(for: currentFile) {
            case .checking:
                text = L("Checking", "检测中"); tint = .blue
            case .connected:
                text = L("Connected", "已连通"); tint = .green
            case .failed:
                text = L("Connection issue", "连通异常"); tint = .orange
            case .unsupported:
                text = L("Catalog only", "仅模型目录"); tint = .secondary
            case nil:
                text = L("Not checked", "尚未检测"); tint = .secondary
            }
        }
        return GatewayQuietBadge(text: text, tint: tint)
    }

    private var noteCard: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("Note", "备注"))
                        .font(.headline)
                    Spacer()
                    if isEditingNote {
                        Button(L("Cancel", "取消")) {
                            draftNote = GatewayAccountNote.visible(currentFile.note) ?? ""
                            isEditingNote = false
                        }
                        .buttonStyle(.borderless)
                        Button(L("Save", "保存")) {
                            saveMetadata(note: draftNote, priority: currentFile.priority ?? draftPriority)
                            isEditingNote = false
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(isUpdating || manager.isManagingAccounts)
                    } else {
                        Button(L("Edit", "编辑")) {
                            draftNote = GatewayAccountNote.visible(currentFile.note) ?? ""
                            isEditingNote = true
                        }
                        .buttonStyle(.borderless)
                    }
                }

                if isEditingNote {
                    TextField(L("Add a short note", "写一句备注"), text: $draftNote)
                        .textFieldStyle(.roundedBorder)
                } else if let note = currentFile.gatewayVisibleNote {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    Text(L("No note yet", "暂无备注"))
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private var modelsCard: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Model catalog", "模型目录"))
                        .font(.headline)
                    Spacer()
                    Button {
                        loadModels(force: true)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("Refresh account models", "刷新账号模型"))
                }

                if let modelError = manager.authFileModelErrors[currentFile.name] {
                    GatewayErrorBanner(message: modelError)
                } else if isLoadingModels {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading…", "加载中…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if models.isEmpty {
                    Text(L("No models are listed for this account.", "该账号的模型目录为空。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(visibleModels.enumerated()), id: \.element.id) { index, model in
                            HStack {
                                Image(systemName: "cube")
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(model.displayName ?? model.id)
                                        .font(.callout.weight(.medium))
                                    if model.displayName != nil {
                                        Text(model.id)
                                            .font(.caption.monospaced())
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            if index < visibleModels.count - 1 { Divider() }
                        }
                    }
                    if models.count > 8 {
                        Button(
                            showAllModels
                                ? L("Show less", "收起")
                                : L("Show all \(models.count)", "显示全部 \(models.count) 个")
                        ) {
                            showAllModels.toggle()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                isCheckingConnectivity = true
                connectivityMessage = nil
                Task {
                    let result = await manager.testAccountConnectivity(for: currentFile)
                    connectivityMessage = result.detail
                    isCheckingConnectivity = false
                }
            } label: {
                Label(
                    isCheckingConnectivity ? L("Checking…", "检测中…") : L("Check connectivity", "检测连通性"),
                    systemImage: "network"
                )
            }
            .disabled(isCheckingConnectivity || manager.isManagingAccounts)
            .help(L("Uses an upstream account endpoint; no model inference is run", "访问上游账号接口，不发起模型推理"))

            Button(currentFile.disabled ? L("Enable", "启用") : L("Pause", "停用")) {
                isUpdating = true
                operationError = nil
                Task {
                    await manager.setAuthFile(currentFile, disabled: !currentFile.disabled)
                    operationError = manager.lastError
                    isUpdating = false
                }
            }
            .disabled(isUpdating || manager.isManagingAccounts)
            Spacer()
            Button(L("Remove from CPA", "从 CPA 删除"), role: .destructive) {
                dismiss()
                pendingDeletion = currentFile
            }
        }
    }

    private func compactStat(_ value: String, _ title: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(tint)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 18) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)
            Text(value)
                .font(.callout)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var currentFile: CLIProxyAuthFile {
        manager.authFiles.first { $0.name == file.name } ?? file
    }

    private var currentIdentity: CLIProxyAccountIdentity? { manager.accountIdentity(for: currentFile) }
    private var models: [CLIProxyModel] { manager.models(for: currentFile) }
    private var visibleModels: [CLIProxyModel] { showAllModels ? models : Array(models.prefix(8)) }

    private func saveMetadata(note: String, priority: Int) {
        isUpdating = true
        operationError = nil
        Task {
            await manager.updateAuthFile(currentFile, note: note, priority: priority)
            operationError = manager.lastError
            isUpdating = false
        }
    }

    private func loadModels(force: Bool) {
        isLoadingModels = true
        Task {
            await manager.loadModels(for: currentFile, force: force)
            isLoadingModels = false
        }
    }
}
