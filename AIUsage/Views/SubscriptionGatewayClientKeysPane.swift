import AppKit
import QuotaBackend
import SwiftUI

// MARK: - CPA 客户端密钥中心
// 默认钥 + 自定义钥（备注 / 启停 / 删除 / 复制）；变更后重写 config 并在运行中重启 CPA。

struct SubscriptionGatewayClientKeysPane: View {
    @ObservedObject var runtime: CLIProxyRuntimeController

    @State private var entries: [CLIProxyClientKeyEntry] = []
    @State private var loadError: String?
    @State private var actionError: String?
    @State private var isBusy = false
    @State private var showAddSheet = false
    @State private var pendingDelete: CLIProxyClientKeyEntry?
    @State private var flashCopiedID: String?

    var body: some View {
        if CLIProxyRuntimeController.managedRuntimeAvailable {
            clientKeyControls
        } else {
            GatewayErrorBanner(message: L("CPA client key management is disabled while the runtime is paused.", "托管 CPA 暂停期间无法更改客户端密钥。"))
        }
    }

    private var clientKeyControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Client API keys", "客户端密钥"))
                        .font(.title3.weight(.semibold))
                    Text(L(
                        "Keys that can call the local CPA inference API.",
                        "用于调用本机 CPA 推理接口的密钥。"
                    ))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label(L("Add key", "新增密钥"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy || !runtime.state.isRunning && runtime.clientAPIKey == nil)
            }

            if runtime.state.isRunning {
                Label(
                    L("Changes apply by rewriting config and restarting CPA.", "保存后会重写配置并重启 CPA。"),
                    systemImage: "arrow.triangle.2.circlepath"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            if let loadError { GatewayErrorBanner(message: loadError) }
            if let actionError { GatewayErrorBanner(message: actionError) }

            if entries.isEmpty {
                GatewayCard {
                    Text(L("No keys loaded yet. Start CPA once to create the default key.", "尚未加载密钥。先启动一次 CPA 以生成默认密钥。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                GatewayCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { Divider().padding(.leading, 14) }
                            keyRow(entry)
                        }
                    }
                }
            }
        }
        .task { await reload() }
        .sheet(isPresented: $showAddSheet) {
            AddClientKeySheet { label, key in
                await addKey(label: label, key: key)
            }
        }
        .alert(
            L("Delete this key?", "删除此密钥？"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            presenting: pendingDelete
        ) { entry in
            Button(L("Delete", "删除"), role: .destructive) {
                Task { await deleteKey(entry) }
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(L(
                "Clients using …\(entry.fingerprint) will stop working after apply.",
                "使用 …\(entry.fingerprint) 的客户端将在应用后失效。"
            ))
        }
    }

    private func keyRow(_ entry: CLIProxyClientKeyEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(entry.displayTitle)
                        .font(.subheadline.weight(.semibold))
                    if entry.isManagedDefault {
                        GatewayQuietBadge(text: L("Default", "默认"), tint: .blue)
                    }
                    if !entry.enabled {
                        GatewayQuietBadge(text: L("Off", "停用"), tint: .secondary)
                    }
                }
                Text("…\(entry.fingerprint)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                copy(entry)
            } label: {
                Image(systemName: flashCopiedID == entry.id ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(L("Copy", "复制"))

            if !entry.isManagedDefault {
                Toggle("", isOn: Binding(
                    get: { entry.enabled },
                    set: { enabled in Task { await setEnabled(entry, enabled: enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isBusy)

                Button(role: .destructive) {
                    pendingDelete = entry
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(isBusy)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func reload() async {
        do {
            entries = try runtime.loadClientKeyEntries()
            loadError = nil
        } catch {
            loadError = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    private func addKey(label: String, key: String?) async {
        guard CLIProxyRuntimeController.managedRuntimeAvailable else { return }
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            let store = CLIProxyClientKeyStore()
            _ = try store.addKey(label: label, key: key)
            try await runtime.applyClientKeyChanges()
            entries = try runtime.loadClientKeyEntries()
            showAddSheet = false
        } catch {
            actionError = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    private func setEnabled(_ entry: CLIProxyClientKeyEntry, enabled: Bool) async {
        guard CLIProxyRuntimeController.managedRuntimeAvailable else { return }
        isBusy = true
        actionError = nil
        defer { isBusy = false }
        do {
            let store = CLIProxyClientKeyStore()
            try store.updateEntry(id: entry.id, enabled: enabled)
            try await runtime.applyClientKeyChanges()
            entries = try runtime.loadClientKeyEntries()
        } catch {
            actionError = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    private func deleteKey(_ entry: CLIProxyClientKeyEntry) async {
        guard CLIProxyRuntimeController.managedRuntimeAvailable else { return }
        isBusy = true
        actionError = nil
        defer {
            isBusy = false
            pendingDelete = nil
        }
        do {
            let store = CLIProxyClientKeyStore()
            try store.deleteEntry(id: entry.id)
            try await runtime.applyClientKeyChanges()
            entries = try runtime.loadClientKeyEntries()
        } catch {
            actionError = SensitiveDataRedactor.redactedMessage(for: error)
        }
    }

    private func copy(_ entry: CLIProxyClientKeyEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.key, forType: .string)
        if entry.isManagedDefault {
            runtime.acknowledgeClientKeyCopied()
        }
        flashCopiedID = entry.id
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            if flashCopiedID == entry.id { flashCopiedID = nil }
        }
    }
}

private struct AddClientKeySheet: View {
    let onSubmit: (String, String?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var customKey = ""
    @State private var generateNew = true
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Add client key", "新增客户端密钥"))
                .font(.headline)
            TextField(L("Note (optional)", "备注（可选）"), text: $label)
                .textFieldStyle(.roundedBorder)
            Toggle(L("Generate a new key", "自动生成新密钥"), isOn: $generateNew)
            if !generateNew {
                SecureField(L("Paste API key", "粘贴 API 密钥"), text: $customKey)
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Spacer()
                Button(L("Cancel", "取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(L("Add", "添加")) {
                    isSaving = true
                    Task {
                        await onSubmit(
                            label,
                            generateNew ? nil : customKey
                        )
                        isSaving = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSaving || (!generateNew && customKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
