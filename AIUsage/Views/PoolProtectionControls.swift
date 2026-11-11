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
                Toggle(pool == "claude" ? "Claude / GPT Pool" : "\(pool.capitalized) Pool", isOn: Binding(
                    get: { pools.contains(pool) }, set: { enabled in
                        do {
                            try AntigravityPoolProtectionSettings.setPool(pool, enabled: enabled, homeDirectory: home.path)
                            failure = nil
                        } catch { failure = error.localizedDescription }
                        pools = AntigravityPoolProtectionSettings.enabledPools(homeDirectory: home.path)
                    }))
                .accessibilityIdentifier("agy-pool-\(pool)")
            }
            Text("Pool selection takes effect only when Antigravity protection is enabled. Other platforms are never changed.")
                .font(.caption).foregroundStyle(.secondary)
            if let failure { Text(failure).font(.caption).foregroundStyle(.red) }
        }.onAppear { pools = AntigravityPoolProtectionSettings.enabledPools(homeDirectory: home.path) }
    }
}

struct RTKVersionsView: View {
    var store = RTKVersionStore()
    @State private var versions: [RTKVersionStore.Version] = []
    @State private var failure: String?
    @State private var deletion: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("RTK — Versions & rollback").font(.headline)
                Spacer()
                Button("Refresh") { reload() }
            }
            Text("Activates the RTK binary behind token-saver-rtk; keeps the wrapper and fallback intact. Homebrew owns deletion of Cellar versions.")
                .font(.caption).foregroundStyle(.secondary)
            if versions.isEmpty { Text("No installed RTK versions found.").foregroundStyle(.secondary) }
            ForEach(versions) { version in
                HStack {
                    Image(systemName: version.isActive ? "checkmark.seal.fill" : "shippingbox")
                        .foregroundStyle(version.isActive ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(version.version.hasPrefix("v") ? version.version : "v\(version.version)")
                        Text(version.installedAt.formatted()).font(.caption2).foregroundStyle(.secondary)
                    }
                    if version.isActive { Text("Active").foregroundStyle(.green) }
                    Spacer()
                    if !version.isActive {
                        Button("Activate") { perform { try store.activate(version.id) } }
                        Button(role: .destructive) { deletion = version.id } label: { Image(systemName: "trash") }
                            .disabled(!version.isManaged).help("Only inactive AIUsage-managed versions can be deleted here.")
                    }
                }
            }
            if let failure { Text(failure).foregroundStyle(.red).font(.caption) }
        }.onAppear { reload() }
        .confirmationDialog("Delete this RTK version?", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } })) {
            Button("Delete", role: .destructive) {
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
