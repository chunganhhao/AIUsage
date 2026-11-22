import SwiftUI
import Combine
import QuotaBackend

struct BurnRateBadge: View {
    let windows: [QuotaWindow]
    private var estimate: QuotaBurnRate? {
        windows.compactMap { QuotaBurnRate.estimate(remainingPercent: $0.remainingPercent, resetAt: $0.resetAt, label: $0.label) }
            .max { $0.multiplier < $1.multiplier }
    }
    var body: some View {
        if let estimate {
            Text(estimate.exhaustionAfter.map { "🔥 \(String(format: "%.1f", estimate.multiplier))× · ~\(max(1, Int($0 / 60))) min left" } ?? "🟢 Steady")
                .font(.caption2).foregroundStyle(estimate.isAtRisk ? .orange : .secondary)
                .help("Window-average estimate assuming unchanged demand, not a guarantee. Unknown or expired windows are not predicted.")
        }
    }
}

@MainActor
final class EnvironmentOverrideModel: ObservableObject {
    static let shared = EnvironmentOverrideModel()
    let home: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    @Published var findings: [EnvironmentOverrideDetector.Finding] = []
    @Published var error: String?
    @Published var undo: EnvironmentOverrideDetector.Undo?
    func scan() {
        do { findings = try EnvironmentOverrideDetector.scan(home: home, inherited: home == FileManager.default.homeDirectoryForCurrentUser ? ProcessInfo.processInfo.environment : [:]); error = nil }
        catch { self.error = error.localizedDescription }
    }
    func remove(_ finding: EnvironmentOverrideDetector.Finding) {
        do { undo = try EnvironmentOverrideDetector.remove(finding); scan() }
        catch { self.error = error.localizedDescription }
    }
    func restore() {
        do { try undo?.restore(); undo = nil; scan() }
        catch { self.error = error.localizedDescription }
    }
}

struct EnvironmentOverrideBanner: View {
    let provider: String
    @ObservedObject private var model = EnvironmentOverrideModel.shared
    @State private var showing = false
    private var relevant: Bool {
        model.findings.contains { item in
            provider == "codex" ? item.key.hasPrefix("OPENAI_") || item.key == "CODEX_HOME" :
                provider == "antigravity" ? item.key.hasPrefix("GEMINI_") || item.key.hasPrefix("GOOGLE_") :
                provider.hasPrefix("claude") && (item.key.hasPrefix("ANTHROPIC_") || item.key == "CLAUDE_CONFIG_DIR")
        }
    }
    var body: some View {
        if relevant {
            Button { showing = true } label: { Label("Possible environment override", systemImage: "exclamationmark.triangle") }
                .buttonStyle(.link).font(.caption).foregroundStyle(.orange)
                .sheet(isPresented: $showing) { EnvironmentOverrideView(model: model).padding(20).frame(width: 650, height: 460) }
        }
    }
}

struct EnvironmentOverrideView: View {
    @StateObject private var model: EnvironmentOverrideModel
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, model: EnvironmentOverrideModel? = nil) {
        _model = StateObject(wrappedValue: model ?? EnvironmentOverrideModel(home: home))
    }
    @State private var pending: EnvironmentOverrideDetector.Finding?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Environment Overrides").font(.headline)
                Spacer()
                Button("Rescan") { model.scan() }
                Button("Undo last removal") { model.restore() }.disabled(model.undo == nil)
            }
            Text("Static candidates, not proof of an active override. Values stay hidden. Shell files are never executed; inherited/launchd settings need manual review and an app restart after editing.")
                .font(.caption).foregroundStyle(.secondary)
            if model.findings.isEmpty { Text("No candidates found in the inspected files/environment.").foregroundStyle(.secondary) }
            ScrollView {
                ForEach(model.findings) { item in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(item.key).font(.system(.caption, design: .monospaced))
                            Text((item.file?.path ?? "Inherited app environment") + (item.line.map { ":\($0)" } ?? ""))
                                .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        if let file = item.file { Button("Open") { NSWorkspace.shared.open(file) } }
                        if item.canRemove { Button("Remove") { pending = item } }
                    }.padding(.vertical, 4)
                }
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.red) }
        }.onAppear { model.scan() }
        .confirmationDialog("Remove this environment override?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Remove", role: .destructive) { if let pending { model.remove(pending) }; pending = nil }
        }
    }
}

struct AgentConfigToolsView: View {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    let platform: AgentMCPStore.Platform
    @State private var servers: [AgentMCPStore.Item] = []
    @State private var skills: [AgentConfigProfiles.Skill] = []
    @State private var profiles: [AgentConfigProfiles.Profile] = []
    @State private var profileName = "Coding"
    @State private var pasted = ""
    @State private var preview: [AgentMCPStore.Server] = []
    @State private var error: String?
    @State private var confirmImport = false
    @State private var checkingKeychain = false
    @State private var keychainNotice: String?
    private var store: AgentMCPStore { .init(home: home, platform: platform) }
    private var sets: AgentConfigProfiles { .init(mcp: store) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Config Sets: MCP & Skills").font(.headline)
                Spacer()
                Button("Refresh health") { reload() }
            }
            Text("\(platform.rawValue.capitalized) only. Static health checks never execute MCP commands. Saved sets contain names/on-off flags, not keys. Restart the agent to reload configuration.")
                .font(.caption).foregroundStyle(.secondary)
            if store.isConfigReadOnly {
                Label("Linked MCP config — Read-only. Edit the shared source file to change servers.", systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("mcp-config-read-only")
            }
            HStack {
                TextField("Coding / RonC Media / Minimal", text: $profileName)
                Button("Save current set") { perform { try sets.saveCurrent(name: profileName) } }
            }
            ForEach(profiles) { profile in
                HStack { Text(profile.name); Spacer(); Button("Apply set") { perform { try sets.apply(profile) } }.disabled(store.isConfigReadOnly) }
            }
            ForEach(servers) { item in
                HStack {
                    Toggle(item.name, isOn: Binding(get: { item.enabled }, set: { enabled in perform { try store.setEnabled(item.name, enabled: enabled) } }))
                        .disabled(store.isConfigReadOnly)
                    if let health = item.health { Text(health).font(.caption).foregroundStyle(.orange) }
                    if item.canAuthorizeKeychain {
                        Button("Check Keychain access…") {
                            checkingKeychain = true
                            Task {
                                defer { checkingKeychain = false }
                                do {
                                    try await store.verifyKeychainAccess(name: item.name)
                                    reload(); keychainNotice = "Keychain reader access checked. No MCP command was started."
                                } catch { self.error = error.localizedDescription }
                            }
                        }.disabled(checkingKeychain || store.isConfigReadOnly)
                    }
                }
            }
            ForEach(skills) { skill in
                HStack {
                    Toggle("Skill · \(skill.name)", isOn: Binding(get: { skill.enabled }, set: { enabled in perform { try sets.setSkill(skill.name, enabled: enabled) } }))
                    if skill.broken {
                        Text("Broken symlink").font(.caption).foregroundStyle(.orange)
                        Button("Repair…") { repair(skill.name) }
                    }
                }
            }
            DisclosureGroup("Paste MCP Importer") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste stdio mcpServers JSON or simple Codex TOML tables. Import does not run a server. Review commands first; they can execute when the agent next starts. Env values are kept in Keychain and loaded by a private launcher. macOS may require your permission for its reader. Use Check Keychain access in the foreground before starting an agent; AIUsage never silently broadens trusted-app access.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextEditor(text: $pasted).font(.system(.caption, design: .monospaced)).frame(height: 100)
                        .onChange(of: pasted) { preview = [] }
                    HStack {
                        Button("Preview") {
                            do { preview = try AgentMCPStore.parse(pasted); error = nil }
                            catch { preview = []; self.error = error.localizedDescription }
                        }
                        Text(preview.map(\.name).joined(separator: ", ")).font(.caption)
                        Spacer()
                        Button("Import to \(platform.rawValue.capitalized)") { confirmImport = true }.disabled(preview.isEmpty || store.isConfigReadOnly)
                    }
                }
            }
            .disclosureGroupStyle(FullRowDisclosureStyle())
            if let keychainNotice { Text(keychainNotice).font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
        }.onAppear { reload() }
        .confirmationDialog("Import reviewed MCP commands? They may execute the next time this agent starts.", isPresented: $confirmImport) {
            Button("Import") { perform { try store.importServers(preview); pasted = ""; preview = [] } }
        }
    }
    private func repair(_ name: String) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { perform { try sets.repairSkill(name, target: url) } }
    }
    private func reload() {
        var failures: [String] = []
        servers = []; skills = []; profiles = []
        do { servers = try store.items(path: aiusageDefaultCLIPath()) }
        catch { failures.append("MCP: " + error.localizedDescription) }
        do { skills = try sets.skills() }
        catch { failures.append("Skills: " + error.localizedDescription) }
        do { profiles = try sets.profiles() }
        catch { failures.append("Config sets: " + error.localizedDescription) }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }
    private func perform(_ action: () throws -> Void) {
        do { try action(); reload() } catch { self.error = error.localizedDescription }
    }
}

@MainActor
final class WarmupController: ObservableObject {
    static let shared = WarmupController()
    @Published var status: String?
    private let scheduler = ScheduledWarmup()
    var providerSnapshot: () -> [ProviderData] = { [] }
    var autoRefreshIntervalSeconds: () -> Int = { 300 }
    var onWarmupDispatched: () -> Void = {}
    private var isTicking = false
    private var didDispatchInCurrentTick = false
    func tick(providers: [ProviderData]) {
        Task {
            guard !isTicking else { return }
            isTicking = true
            didDispatchInCurrentTick = false
            defer { isTicking = false }
            do {
                let settings = try WarmupSettings.load()
                guard settings.enabled else { return }
                let observations = settings.targets.compactMap { observation($0, providers: providers) }
                @Sendable func resolvedExecutable(for targetProvider: WarmupSettings.Target.Provider) async throws -> String {
                    let executable = await Task.detached { targetProvider == .codex ? aiusageCodexExecutable() : aiusageResolvedExecutable(named: "claude") }.value
                    guard let executable else { throw OfficialWarmupProcess.PreSpawnFailure("Official CLI not found; warmup skipped.") }
                    return executable
                }
                try await scheduler.tick(
                    observations: observations,
                    liveObservation: { [weak self] target in
                        await self?.currentObservation(for: target, fallback: providers)
                    },
                    preflight: { target in
                        let executable = try await resolvedExecutable(for: target.provider)
                        if target.provider == .claude {
                            let identity = try await ClaudeSubscriptionManager.authStatus(directory: target.directory, executable: executable)
                            guard identity.isSubscription, identity.email?.lowercased() == target.email.lowercased() else {
                                throw AgentMCPStore.Failure.invalid("Claude subscription identity changed; warmup skipped.")
                            }
                        } else {
                            try OfficialWarmupProcess.preflight(target: target)
                        }
                    }
                ) { target in
                    var env = ProcessInfo.processInfo.environment; env["PATH"] = aiusageDefaultCLIPath()
                    do {
                        let executable = try await resolvedExecutable(for: target.provider)
                        try await OfficialWarmupProcess.run(target: target, executable: executable, environment: env)
                        await MainActor.run { self.didDispatchInCurrentTick = true }
                    } catch let error as OfficialWarmupProcess.PreSpawnFailure {
                        throw error
                    } catch {
                        await MainActor.run { self.didDispatchInCurrentTick = true }
                        throw error
                    }
                }
                if didDispatchInCurrentTick { onWarmupDispatched() }
                status = "Schedule checked. Active/unknown windows are skipped; each paid attempt is fenced against replay."
            } catch {
                if didDispatchInCurrentTick { onWarmupDispatched() }
                status = error.localizedDescription
            }
        }
    }
    private func currentObservation(for target: WarmupSettings.Target, fallback: [ProviderData]) -> ScheduledWarmup.Observation? {
        let liveProviders = providerSnapshot()
        return observation(target, providers: liveProviders.isEmpty ? fallback : liveProviders)
    }
    private func observation(_ target: WarmupSettings.Target, providers: [ProviderData]) -> ScheduledWarmup.Observation? {
        let id = target.provider == .claude ? "claude-subscription" : "codex"
        let canonicalTarget = (target.provider == .codex
            ? OfficialWarmupProcess.codexAuthFile(directory: target.directory)
            : URL(fileURLWithPath: target.directory)).resolvingSymlinksInPath().path
        let expectedCodexAccountID = target.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if target.provider == .codex {
            guard let expectedCodexAccountID, !expectedCodexAccountID.isEmpty else { return nil }
            let liveDefault = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex/auth.json").resolvingSymlinksInPath().path
            if (canonicalTarget == liveDefault || canonicalTarget.hasSuffix("/.codex/auth.json")),
               FileManager.default.fileExists(atPath: canonicalTarget) {
                guard let diskIdentity = try? OfficialWarmupProcess.codexIdentity(directory: canonicalTarget),
                      diskIdentity.email.lowercased() == target.email.lowercased(),
                      diskIdentity.accountID.lowercased() == expectedCodexAccountID else { return nil }
            }
        }
        let matchingCandidates = providers.filter {
            guard $0.baseProviderId == id && $0.accountLabel?.lowercased() == target.email.lowercased() else { return false }
            if target.provider == .codex {
                guard let expectedCodexAccountID,
                      let liveID = $0.accountId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      liveID == expectedCodexAccountID else { return false }
            }
            return true
        }
        func canonicalSource(for item: ProviderData) -> String? {
            item.sourceFilePath.map {
                (target.provider == .codex ? OfficialWarmupProcess.codexAuthFile(directory: $0) : URL(fileURLWithPath: $0)).resolvingSymlinksInPath().path
            }
        }
        let provider = matchingCandidates.first(where: { canonicalSource(for: $0) == canonicalTarget })
            ?? (target.provider == .codex ? matchingCandidates.first : nil)
        guard let provider else { return nil }
        return ScheduledWarmup.observation(
            targetID: target.id,
            fetchedAt: provider.fetchedAt,
            windows: provider.windows.map { .init(label: $0.label, remainingPercent: $0.remainingPercent, resetAt: $0.resetAt) }
        )
    }

}

struct WarmupSettingsView: View {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var settings = WarmupSettings()
    @State private var provider = WarmupSettings.Target.Provider.codex
    @State private var directory = NSHomeDirectory() + "/.codex"
    @State private var email = ""
    @State private var error: String?
    @State private var confirmEnable = false
    @ObservedObject private var controller = WarmupController.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Scheduled 5h-Window Warmup").font(.headline)
            Text("Off by default. Sends one varied lightweight prompt through the official CLI (isolated temporary CODEX_HOME for Codex) to each eligible subscription account while AIUsage is running. Consumes quota. Daily jitter ±5–15 min, post-reset random delay 5–20 min, and 60–180 sec spacing smooth bursts; skips active, exhausted weekly/monthly, or unknown windows. These safeguards do not guarantee provider ToS compliance.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Enable scheduled paid requests", isOn: Binding(get: { settings.enabled }, set: { value in
                if value { confirmEnable = true } else { settings.enabled = false; save() }
            }))
            Toggle("Auto-chain after 5h reset (random 5–20m delay & 1–3m cooldown)", isOn: Binding(get: { settings.autoChainReset }, set: { settings.autoChainReset = $0; save() }))
            if settings.enabled && (controller.autoRefreshIntervalSeconds() == 0 || controller.autoRefreshIntervalSeconds() > 600) {
                Text("Quota auto-refresh is disabled or above 10 minutes; warmup skips snapshots older than 10 minutes.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Stepper("Hour: \(settings.hour)", value: $settings.hour, in: 0...23)
                Stepper("Minute: \(settings.minute)", value: $settings.minute, in: 0...59)
                Button("Save time") { save() }
            }
            ForEach(settings.targets) { target in
                HStack {
                    Text("\(target.provider.rawValue) · \(target.email)").font(.caption)
                    Spacer()
                    Button("Remove") { settings.targets.removeAll { $0.id == target.id }; save() }
                }
            }
            HStack {
                Button("Sync connected Codex accounts") { syncConnectedCodexAccounts() }
                Spacer()
            }
            HStack {
                Picker("CLI", selection: $provider) { Text("Codex").tag(WarmupSettings.Target.Provider.codex); Text("Claude").tag(WarmupSettings.Target.Provider.claude) }.frame(width: 150)
                TextField("Native config directory", text: $directory)
            }
            HStack {
                TextField("Expected signed-in email", text: $email)
                Button("Add account") {
                    do {
                        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        var accountID: String?
                        if provider == .codex {
                            let identity = try OfficialWarmupProcess.codexIdentity(directory: directory)
                            guard identity.email.lowercased() == address.lowercased() else { throw AgentMCPStore.Failure.invalid("Expected email does not match the signed-in Codex account.") }
                            accountID = identity.accountID
                        }
                        let candidate = WarmupSettings.Target(provider: provider, directory: directory, email: address, accountID: accountID)
                        guard !settings.targets.contains(where: { $0.matchesSubscriptionAccount(of: candidate) }) else {
                            throw AgentMCPStore.Failure.invalid("Duplicate warmup account or workspace is already listed.")
                        }
                        settings.targets.append(candidate)
                        save()
                    } catch { self.error = error.localizedDescription }
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let status = controller.status { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.onAppear { do { settings = try WarmupSettings.load(home: home) } catch { self.error = error.localizedDescription } }
        .confirmationDialog("Allow scheduled prompts to consume quota on the listed accounts?", isPresented: $confirmEnable) {
            Button("Enable scheduled requests") { settings.enabled = true; save() }
        }
    }
    private func syncConnectedCodexAccounts() {
        var added = 0
        var skippedUnsupported = 0
        let codexProviders = controller.providerSnapshot()
            .filter { $0.baseProviderId == "codex" }
            .sorted { lhs, rhs in
                let lhsManaged = lhs.sourceFilePath?.contains("AuthImports") ?? false
                let rhsManaged = rhs.sourceFilePath?.contains("AuthImports") ?? false
                return lhsManaged && !rhsManaged
            }
        for item in codexProviders {
            guard settings.targets.count < 20,
                  let path = item.sourceFilePath, !path.isEmpty,
                  let identity = try? OfficialWarmupProcess.codexIdentity(directory: path) else { continue }
            if !item.windows.isEmpty && !item.windows.contains(where: { ScheduledWarmup.isMainFiveHourWindowLabel($0.label) }) {
                skippedUnsupported += 1
                continue
            }
            let candidate = WarmupSettings.Target(provider: .codex, directory: path, email: identity.email, accountID: identity.accountID)
            let alreadyListed = settings.targets.contains { existing in
                existing.matchesSubscriptionAccount(of: candidate)
            }
            if !alreadyListed {
                settings.targets.append(candidate)
                added += 1
            }
        }
        if added > 0 {
            save()
            if error == nil {
                let skippedNote = skippedUnsupported > 0 ? " Skipped \(skippedUnsupported) account(s) without a 5h window." : ""
                controller.status = "Synced \(added) connected Codex account(s).\(skippedNote)"
            }
        } else if skippedUnsupported > 0 {
            controller.status = "Skipped \(skippedUnsupported) connected Codex account(s) without a 5h window (not applicable to this plan)."
        } else {
            controller.status = "No new connected Codex subscription accounts found."
        }
    }
    private func save() {
        do { try settings.save(home: home); error = nil }
        catch { self.error = error.localizedDescription; settings = (try? WarmupSettings.load(home: home)) ?? WarmupSettings() }
    }
}

struct AgentToolsSettingsView: View {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    @State private var platform = AgentMCPStore.Platform.codex
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            GatewayCard { WarmupSettingsView(home: home) }
            GatewayCard { EnvironmentOverrideView(home: home).frame(maxHeight: 260) }
            GatewayCard {
                VStack(alignment: .leading) {
                    Picker("Agent", selection: $platform) { ForEach(AgentMCPStore.Platform.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                    AgentConfigToolsView(home: home, platform: platform).id(platform)
                }
            }
        }
    }
}
