import SwiftUI
import QuotaBackend

struct CodexPoolProtectionControls: View {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var enabled = false
    @State private var threshold = 3.0
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Codex Pool Protection (opt-in)", isOn: Binding(get: { enabled }, set: { save($0, threshold) }))
                .toggleStyle(.switch)
                .tint(.accentColor)
                .accessibilityIdentifier("codex-pool-protection")
            Picker("Pause threshold", selection: Binding(get: { threshold }, set: { save(enabled, $0) })) {
                ForEach([1.0, 3.0, 5.0], id: \.self) { Text("\(Int($0))%").tag($0) }
            }.pickerStyle(.menu)
            Text("Off by default. Only Codex credentials are affected. Turning off restores breaker-owned pauses, never manually paused accounts.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.onAppear { reload() }
    }
    private func reload() {
        enabled = CodexPoolProtectionSettings.isEnabled(homeDirectory: home.path)
        threshold = CodexPoolProtectionSettings.threshold(homeDirectory: home.path)
    }
    private func save(_ enabled: Bool, _ threshold: Double) {
        do {
            try CodexPoolProtectionSettings.setEnabled(enabled, threshold: threshold, homeDirectory: home.path)
            failure = nil
        } catch { failure = error.localizedDescription }
        reload()
    }
}

struct AntigravityPerPoolControls: View {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var pools = Set<String>()
    @State private var failure: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(AntigravityPoolProtectionSettings.pools, id: \.self) { pool in
                Toggle(Self.poolTitle(for: pool), isOn: Binding(
                    get: { pools.contains(pool) }, set: { enabled in
                        do {
                            try AntigravityPoolProtectionSettings.setPool(pool, enabled: enabled, homeDirectory: home.path)
                            failure = nil
                        } catch { failure = error.localizedDescription }
                        pools = AntigravityPoolProtectionSettings.enabledPools(homeDirectory: home.path)
                    }))
                .accessibilityIdentifier("agy-pool-\(pool)")
            }
            Text(L("Pool selection takes effect only when Antigravity protection is enabled. Other platforms are never changed.", "分池选择仅在启用 Antigravity 保护时生效，其他平台不受影响。"))
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.onAppear { pools = AntigravityPoolProtectionSettings.enabledPools(homeDirectory: home.path) }
    }

    private static func poolTitle(for pool: String) -> String {
        switch pool {
        case "gemini":
            return L("Gemini Pool (Flash 3.8 / Hydrogen 4)", "Gemini 池 (Flash 3.8 / Hydrogen 4)")
        case "claude":
            return L("Claude / GPT Pool", "Claude / GPT 池")
        case "argon":
            return L("Argon / Carbon Pool (Gemini 4 Argon / Carbon)", "Argon / Carbon 池 (Gemini 4 Argon / Carbon)")
        default:
            return "\(pool.capitalized) Pool"
        }
    }
}

struct RTKVersionsView: View {
    var store = RTKVersionStore()
    @State private var versions: [RTKVersionStore.Version] = []
    @State private var failure: String?
    @State private var deletion: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(L("RTK — Versions & rollback", "RTK — 版本与回退"))
                        .font(.headline)
                    Spacer(minLength: 8)
                    if let active = versions.first(where: \.isActive) {
                        GatewayQuietBadge(text: active.version.hasPrefix("v") ? active.version : "v\(active.version)", tint: .green)
                    }
                    Button(L("Refresh", "刷新")) { reload() }
                }
                Text(L("Activates the RTK binary behind token-saver-rtk; keeps the wrapper and fallback intact. Homebrew owns deletion of Cellar versions.", "切换 token-saver-rtk 背后的 RTK 二进制版本；保持封装脚本和回退逻辑不变。Cellar 中的版本由 Homebrew 管理删除。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            Divider().opacity(0.35)

            if versions.isEmpty {
                Text(L("No installed RTK versions found.", "未发现已安装的 RTK 版本。"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 72)
            } else {
                VStack(spacing: 0) {
                    ForEach(versions) { version in
                        HStack(spacing: 10) {
                            Image(systemName: version.isActive ? "checkmark.seal.fill" : "shippingbox")
                                .foregroundStyle(version.isActive ? .green : .secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(version.version.hasPrefix("v") ? version.version : "v\(version.version)")
                                    .font(.subheadline.weight(.semibold).monospacedDigit())
                                Text(version.installedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if version.isActive {
                                GatewayQuietBadge(text: L("Active", "当前"), tint: .green)
                            }
                            Spacer(minLength: 8)
                            if !version.isActive {
                                Button(L("Activate", "启用")) { perform { try store.activate(version.id) } }
                                Button(role: .destructive) { deletion = version.id } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(!version.isManaged)
                                .help(L("Only inactive AIUsage-managed versions can be deleted here.", "仅可在此删除非当前启用且由 AIUsage 托管的版本。"))
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        if version.id != versions.last?.id {
                            Divider().opacity(0.35).padding(.leading, 44)
                        }
                    }
                }
            }
            if let failure {
                Text(failure)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
        .onAppear { reload() }
        .confirmationDialog(L("Delete this RTK version?", "确定删除此 RTK 版本？"), isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button(L("Delete", "删除"), role: .destructive) {
                if let deletion { perform { try store.delete(deletion) } }
                deletion = nil
            }
        }
    }
    private func reload() { perform { versions = try store.versions() } }
    private func perform(_ action: () throws -> Void) {
        do { try action(); versions = try store.versions(); failure = nil }
        catch { failure = error.localizedDescription }
    }
}

// Native disclosure semantics with one keyboard-focusable, full-width hit target.
struct FullRowDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                configuration.isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(configuration.isExpanded ? "Expanded" : "Collapsed")
            if configuration.isExpanded { configuration.content }
        }
    }
}
