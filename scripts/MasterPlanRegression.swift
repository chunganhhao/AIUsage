import Foundation
@testable import QuotaBackend

private var assertions = 0
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw AgentMCPStore.Failure.invalid("Assertion failed: \(message)") }
}
private func checkExternalPriorityWarning(_ operation: () throws -> Void) throws {
    var message: String?
    do { try operation() } catch { message = error.localizedDescription }
    try check(message?.contains("excluded from weekly routing") == true, "external override is not silently excluded")
    try check(message?.contains("can change relative account order") == true, "warning explains Off ordering risk")
}
private func write(_ value: String, _ file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: file)
}
private func object(_ file: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
private final class Vault {
    var values: [String: String] = [:]
    var service: MCPSecretVault { .init(put: { self.values[$0] = $1 }, get: { self.values[$0] }, delete: { self.values.removeValue(forKey: $0) }) }
}
private actor Attempts {
    var ids: [String] = []
    func add(_ value: String) { ids.append(value) }
    func count() -> Int { ids.count }
}

@main struct MasterPlanRegression {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("aiusage-master-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await analytics(root.appendingPathComponent("analytics"))
        try poolProtection(root.appendingPathComponent("pools"))
        try rtk(root.appendingPathComponent("rtk"))
        try env(root.appendingPathComponent("env"))
        try mcp(root.appendingPathComponent("mcp"))
        try priority(root.appendingPathComponent("priority"))
        try burnRate()
        try await warmup(root.appendingPathComponent("warmup"))
        try await reviewRegressions(root.appendingPathComponent("review"))
        print("Master plan regression: \(assertions) assertions passed; temporary homes, fake vault, no paid requests")
    }
    static func analytics(_ home: URL) async throws {
        let actual = home.appendingPathComponent("archive")
        let sessions = home.appendingPathComponent(".codex/sessions")
        try write(#"{"timestamp":"2026-11-10T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}"# + "\n", actual.appendingPathComponent("day/session.jsonl"))
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: actual)
        let source = CodexCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        try check(source.collect(cutoff: nil).status.filesScanned == 1, "Codex follows root symlink")
        try check(source.collect(cutoff: nil).status.eventCount > 0, "Codex parses linked history")
        let transcript = home.appendingPathComponent(".gemini/antigravity/brain/demo/.system_generated/logs/transcript.jsonl")
        let row = #"{"step_index":1,"created_at":"2026-11-10T03:00:00Z","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"\"/skills/demo/SKILL.md\""}},{"name":"call_mcp_tool","args":{"ServerName":"\"docs\"","ToolName":"\"search\""}}]}"#
        try write(row + "\n" + row + "\n", transcript)
        let agy = AntigravityCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!).collect()
        try check(agy.entries.first(where: { $0.kind == .skill })?.count == 1, "AGY explicit skill reads deduplicated")
        try check(agy.entries.first(where: { $0.kind == .mcp })?.name == "docs/search", "AGY MCP server mapping")
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        _ = archive.freeze(computed: [:], todayKey: "2026-11-11", completedFullHistory: true)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let recovered = await engine.computeSnapshot(rangeKey: "all", cutoff: nil)
        try check(recovered.entries.contains(where: { $0.source == .codex }), "poisoned empty import self-recovers")
        let rescanned = await engine.computeSnapshot(rangeKey: "all", cutoff: nil, rescan: true)
        try check(rescanned.entries.filter { $0.source == .codex }.map(\.count) == recovered.entries.filter { $0.source == .codex }.map(\.count), "rescan idempotent")
    }
    static func poolProtection(_ home: URL) throws {
        let auth = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
        let owned = auth.appendingPathComponent("codex-owned.json")
        let manual = auth.appendingPathComponent("codex-manual.json")
        let agy = auth.appendingPathComponent("agy.json")
        try write(#"{"type":"codex","disabled":true,"circuit_breaker_tripped":true}"#, owned)
        try write(#"{"type":"codex","disabled":true}"#, manual)
        try write(#"{"type":"antigravity","disabled":true,"circuit_breaker_tripped":true}"#, agy)
        try check(!CodexPoolProtectionSettings.isEnabled(homeDirectory: home.path), "Codex default off")
        try CodexPoolProtectionSettings.setEnabled(false, threshold: 1, homeDirectory: home.path)
        try check(try object(owned)["disabled"] as? Bool == false, "turn off restores owned Codex pauses")
        try check(try object(manual)["disabled"] as? Bool == true, "manual Codex pause preserved")
        try check(try object(agy)["disabled"] as? Bool == true, "Codex never modifies AGY")
        try CodexPoolProtectionSettings.setEnabled(true, threshold: 5, homeDirectory: home.path)
        try check(CodexPoolProtectionSettings.threshold(homeDirectory: home.path) == 5, "Codex configurable threshold")
        let input: [String: Any] = ["type": "antigravity", "antigravity_capability_hints": ["model_ids": ["gemini-pro", "claude-sonnet", "gemini-4-argon"]]]
        let models = [AntigravityProvider.ModelQuota(id: "gemini-pro", label: "Gemini · Weekly", remainingPercent: 1, resetAt: nil, providerLabel: nil), AntigravityProvider.ModelQuota(id: "claude-sonnet", label: "Claude + GPT · Weekly", remainingPercent: 1, resetAt: nil, providerLabel: nil)]
        let result = try AntigravityPoolCircuitBreaker.updatedCredential(input, models: models, global: [], enabledPools: ["gemini"])!
        try check(result["excluded_models"] as? [String] == ["gemini-pro"], "only enabled pool blocks")
        let cleared = try AntigravityPoolCircuitBreaker.updatedCredential(result, models: [], global: [], enabledPools: [])!
        try check(cleared["excluded_models"] == nil, "deselect restores without fresh quota")
    }
    static func rtk(_ home: URL) throws {
        let old = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        let binary = home.appendingPathComponent("Library/Application Support/AIUsage/RTK/versions/1.2.0/bin/rtk")
        try write("#!/bin/sh\nprintf selected-version\\n\n", binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try write(TokenSaverAgentRules.legacyRTKWrapper, old)
        let store = RTKVersionStore(home: home, cellarRoots: [])
        try check(try store.versions().count == 1, "RTK discovers managed versions")
        try store.activate(try store.versions().first!.id)
        try check(try store.versions().first?.isActive == true, "RTK current selected")
        try check(try String(contentsOf: old, encoding: .utf8) == TokenSaverAgentRules.rtkWrapper, "old wrapper migrated")
        var rejected = false
        do { try store.delete(binary.path) } catch { rejected = true }
        try check(rejected, "active RTK deletion rejected")
    }
    static func env(_ home: URL) throws {
        let file = home.appendingPathComponent(".zshrc")
        let original = "# keep\nexport OPENAI_API_KEY='fake-key'\nexport GEMINI_API_KEY=x; echo keep\n"
        try write(original, file)
        let findings = try EnvironmentOverrideDetector.scan(home: home, inherited: [:])
        try check(findings.count == 2, "env detects candidates without printing values")
        try check(findings.first { $0.key == "OPENAI_API_KEY" }?.canRemove == true, "simple env editable")
        try check(findings.first { $0.key == "GEMINI_API_KEY" }?.canRemove == false, "compound shell never removed")
        let undo = try EnvironmentOverrideDetector.remove(findings.first { $0.key == "OPENAI_API_KEY" }!)
        try check(!(try String(contentsOf: file, encoding: .utf8)).contains("fake-key"), "remove only exact assignment")
        try undo.restore()
        try check(try String(contentsOf: file, encoding: .utf8) == original, "Undo exact restore")
        try write("# concurrent edit", file)
        var rejected = false
        do { try undo.restore() } catch { rejected = true }
        try check(rejected, "Undo respects later edits")

        let uncertainShells = [
            "arguments=(\nOPENAI_API_KEY=fixture\n)\n",
            "for item in\nOPENAI_API_KEY=literal\ndo\n: \"$item\"\ndone\n",
            "select item in\nOPENAI_API_KEY=literal\ndo\nbreak\ndone\n",
            "cat <<'PAYLOAD'\nexport OPENAI_API_KEY=template-key\nPAYLOAD\n",
            "cat <<'PAYLOAD'\nexport OPENAI_API_KEY=template-key\nPAYLOAD\nexport GEMINI_API_KEY=actual-key\n",
            "text='literal\nexport OPENAI_API_KEY=template-key\n'\n",
            "text=word#'literal\nexport OPENAI_API_KEY=template-key\n'\n",
            "text=\"literal\nexport OPENAI_API_KEY=template-key\n\"\n",
            "printf '%s' \\\nexport OPENAI_API_KEY=template-key\n"
        ]
        for uncertain in uncertainShells {
            try write(uncertain, file)
            let inspected = try EnvironmentOverrideDetector.scan(home: home, inherited: [:])
            try check(!inspected.isEmpty && inspected.allSatisfy { !$0.canRemove }, "uncertain shell context is manual-only")
            var refused = false
            do { _ = try EnvironmentOverrideDetector.remove(inspected.first!) } catch { refused = true }
            try check(refused && String(contentsOf: file, encoding: .utf8) == uncertain, "heredoc, quoted payload and continuation stay byte-identical")
        }
        try write("# user's note\nif true; then\nexport OPENAI_API_KEY='simple-value'\nfi\n", file)
        let simpleBranch = try EnvironmentOverrideDetector.scan(home: home, inherited: [:])
        try check(simpleBranch.first?.canRemove == true, "ordinary comments and single-line quoted branch assignment remain editable")
    }
    static func mcp(_ home: URL) throws {
        let vault = Vault()
        for platform in AgentMCPStore.Platform.allCases {
            let store = AgentMCPStore(home: home, platform: platform, vault: vault.service)
            let server = AgentMCPStore.Server(name: "demo", command: "/usr/bin/env", args: ["/tmp/demo"], env: ["KEY": "secret-fixture"])
            try store.importServers([server])
            try check(try store.items().count == 1, "import \(platform)")
            let text = try String(contentsOf: store.configURL, encoding: .utf8)
            try check(!text.contains("secret-fixture"), "env secret absent from config")
            if platform == .codex { try check(!text.contains(#"\/"#), "TOML has no JSON slash escapes") }
            try store.setEnabled("demo", enabled: false)
            try check(try store.items().first?.enabled == false, "disable \(platform)")
            try store.setEnabled("demo", enabled: true)
            try check(try store.items().first?.enabled == true, "enable \(platform)")
            var duplicate = false
            do { try store.importServers([server]) } catch { duplicate = true }
            try check(duplicate, "never overwrite existing MCP")
        }
        let codex = AgentMCPStore(home: home, platform: .codex, vault: vault.service)
        try write("# preserve\n[mcp_servers.demo]\ncommand = \"/usr/bin/env\"\nenabled = false\n[mcp_servers.demo.http_headers]\nX-Test = \"header\"\n[features]\nkeep = true\n", codex.configURL)
        try check(try codex.items().map(\.name) == ["demo"], "MCP subtables grouped under parent")
        try codex.setEnabled("demo", enabled: true)
        let changed = try String(contentsOf: codex.configURL, encoding: .utf8)
        try check(changed.contains("X-Test = \"header\"") && changed.contains("keep = true"), "toggle preserves headers and unrelated config")
        try check(try codex.items().first?.enabled == true, "native disabled table can enable")
        let parsed = try AgentMCPStore.parse("[mcp_servers.docs]\ncommand = '/usr/bin/env'\nargs = [\"a\"]\n[mcp_servers.docs.env]\nKEY = 'value'\n")
        try check(parsed.first?.env["KEY"] == "value", "paste TOML env")
        let jsonStore = AgentMCPStore(home: home, platform: .antigravity, vault: vault.service)
        try jsonStore.setEnabled("demo", enabled: false)
        let index = home.appendingPathComponent("Library/Application Support/AIUsage/AgentConfig/antigravity-disabled.json")
        let backup = index.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: backup)
        let before = try Data(contentsOf: jsonStore.configURL)
        var failed = false
        do { try jsonStore.setEnabled("demo", enabled: true) } catch { failed = true }
        try check(failed && (try Data(contentsOf: jsonStore.configURL)) == before, "MCP metadata failure never leaves untracked enable")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        let unhealthy = AgentMCPStore(home: home, platform: .claude, vault: vault.service)
        try unhealthy.importServers([.init(name: "missing", command: "/nonexistent/mcp", env: ["API_KEY": ""])])
        try check(try unhealthy.items().first(where: { $0.name == "missing" })?.health == "Command not found", "health inspects wrapped command")
        try unhealthy.importServers([.init(name: "missing-key", command: "/usr/bin/true", env: ["API_KEY": ""])])
        try check(try unhealthy.items().first(where: { $0.name == "missing-key" })?.health == "Missing Key", "health checks Keychain env")
        let profiles = AgentConfigProfiles(mcp: codex)
        try write("---\nname: sample\n---\n", codex.skillsURL.appendingPathComponent("sample/SKILL.md"))
        try profiles.saveCurrent(name: "Coding")
        try profiles.setSkill("sample", enabled: false)
        try check(try profiles.skills().first?.enabled == false, "disable skill without deletion")
        try profiles.apply(try profiles.profiles().first!)
        try check(try profiles.skills().first?.enabled == true, "apply restores skill")
        try profiles.setSkill("sample", enabled: false)
        try write("duplicate", codex.skillsURL.appendingPathComponent("sample/SKILL.md"))
        var collision = false
        do { try profiles.saveCurrent(name: "Collision") } catch { collision = true }
        try check(collision, "duplicate skill gives error not trap")
    }
    static func priority(_ home: URL) throws {
        let a = home.appendingPathComponent("a.json"); let b = home.appendingPathComponent("b.json")
        try write(#"{"type":"codex","email":"same@example.test","account_id":"workspace-a","priority":2}"#, a)
        try write(#"{"type":"codex","email":"same@example.test","account_id":"workspace-b","priority":2}"#, b)
        let now = Date()
        try WeeklyResetPriority.sync(authDirectory: home, enabled: true, observations: [
            .init(provider: "codex", email: "same@example.test", reset: now.addingTimeInterval(100), accountID: "workspace-a"),
            .init(provider: "codex", email: "same@example.test", reset: now.addingTimeInterval(1000), accountID: "workspace-b")], now: now)
        try check((try object(a)["priority"] as! Int) > (try object(b)["priority"] as! Int), "weekly routing honors workspace identity")
        try WeeklyResetPriority.sync(authDirectory: home, enabled: false, observations: [])
        try check(try object(a)["priority"] as? Int == 2 && object(b)["priority"] as? Int == 2, "switch away restores user tier")
    }
    static func burnRate() throws {
        let now = Date(); let parser = ISO8601DateFormatter()
        let risk = QuotaBurnRate.estimate(remainingPercent: 10, resetAt: parser.string(from: now.addingTimeInterval(4 * 3600)), label: "5h Window", now: now)
        try check(risk?.isAtRisk == true, "fast burn predicts exhaustion")
        try check((risk?.multiplier ?? 0) > 4, "burn multiplier uses elapsed fraction")
        try check(QuotaBurnRate.estimate(remainingPercent: 95, resetAt: parser.string(from: now.addingTimeInterval(3600)), label: "5h Window", now: now)?.isAtRisk == false, "slow burn steady")
        try check(QuotaBurnRate.estimate(remainingPercent: 10, resetAt: nil, label: "Unknown", now: now) == nil, "unknown duration not invented")
    }
    static func warmup(_ home: URL) async throws {
        var settings = WarmupSettings(); settings.enabled = true
        let now = Date(); let calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
        settings.hour = calendar.component(.hour, from: now); settings.minute = calendar.component(.minute, from: now)
        let stamp = ISO8601DateFormatter().string(from: now)
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 50, resetAt: "invalid") == nil, "malformed reset is unknown, never inactive")
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 50, resetAt: nil) == nil, "missing reset on used window is unknown")
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 100, resetAt: nil) != nil, "fresh full inactive window accepted")
        let target = WarmupSettings.Target(provider: .codex, directory: "/fixture/.codex", email: "fixture@example.test")
        settings.targets = [target]; try settings.save(home: home)
        let attempts = Attempts(); let scheduler = ScheduledWarmup(home: home)
        try await scheduler.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: nil)], now: now, calendar: calendar, jitter: 0) { target in await attempts.add(target.id) }
        let count = await attempts.count(); try check(count == 1, "scheduled warmup dispatches via injected runner")
        let restarted = ScheduledWarmup(home: home)
        try await restarted.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: nil)], now: now, calendar: calendar, jitter: 0) { target in await attempts.add(target.id) }
        let second = await attempts.count(); try check(second == 1, "warmup restart never replays claimed request")
        let parallelHome = home.appendingPathComponent("parallel")
        try settings.save(home: parallelHome)
        let first = ScheduledWarmup(home: parallelHome); let other = ScheduledWarmup(home: parallelHome)
        let parallel = Attempts()
        let observation = ScheduledWarmup.Observation(targetID: target.id, fetchedAt: now, activeUntil: nil)
        async let one: Void = first.tick(observations: [observation], now: now, calendar: calendar, jitter: 0) { target in
            await parallel.add(target.id); try await Task.sleep(nanoseconds: 10_000_000)
        }
        async let two: Void = other.tick(observations: [observation], now: now, calendar: calendar, jitter: 0) { target in await parallel.add(target.id) }
        _ = try await (one, two)
        let parallelCount = await parallel.count(); try check(parallelCount == 1, "warmup cross-instance flock prevents duplicate dispatch")
        var aliases = settings
        aliases.targets = [target, .init(provider: target.provider, directory: target.directory + "/", email: target.email)]
        var aliasRejected = false
        do { try aliases.save(home: home.appendingPathComponent("aliases")) } catch { aliasRejected = true }
        try check(aliasRejected, "warmup rejects equivalent native directory aliases")
        let activeHome = home.appendingPathComponent("active")
        try settings.save(home: activeHome)
        let active = ScheduledWarmup(home: activeHome)
        try await active.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: now.addingTimeInterval(3600))], now: now, calendar: calendar, jitter: 0) { target in await parallel.add(target.id) }
        let activeCount = await parallel.count(); try check(activeCount == 1, "active 5h window never dispatched")
        let corrupt = activeHome.appendingPathComponent("Library/Application Support/AIUsage/warmup-attempts.json")
        try write("corrupt", corrupt)
        var corruptFailed = false
        do { try await active.tick(observations: [observation], now: now, calendar: calendar, jitter: 0) { target in await parallel.add(target.id) } } catch { corruptFailed = true }
        try check(corruptFailed, "corrupt uncertainty fence fails closed")

    }
    static func reviewRegressions(_ home: URL) async throws {
        let absent = home.appendingPathComponent("absent-codex")
        let engine = CallAnalyticsEngine(homeDirectory: absent.path, timeZone: .current, environment: [:])
        _ = await engine.computeSnapshot(rangeKey: "today", cutoff: Calendar.current.startOfDay(for: Date()))
        let archive = CallAnalyticsArchiveStore(homeDirectory: absent.path)
        try check(archive.fullHistoryImported, "absent Codex completes empty import rather than permanent full rescans")
        let archiveFile = CallAnalyticsArchiveStore.fileURL(homeDirectory: absent.path)
        let original = try Data(contentsOf: archiveFile)
        _ = await engine.computeSnapshot(rangeKey: "today", cutoff: Calendar.current.startOfDay(for: Date()))
        try check(try Data(contentsOf: archiveFile) == original, "second absent-source tick does not rewrite archive")

        let brain = home.appendingPathComponent(".gemini/antigravity/brain")
        let recent = brain.appendingPathComponent("recent/.system_generated/logs/transcript.jsonl")
        let old = brain.appendingPathComponent("old/.system_generated/logs/transcript.jsonl")
        let stamp = SharedFormatters.iso8601String(from: Date())
        let row = "{\"step_index\":1,\"created_at\":\"\(stamp)\",\"tool_calls\":[{\"name\":\"read_file\",\"args\":{\"Path\":\"/skills/new-skill/SKILL.md\"}},{\"name\":\"mcp_my_server_search\",\"args\":{}}]}"
        try write(row + "\n", recent); try write(row + "\n", old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        let source = AntigravityCallEventSource(homeDirectory: home.path, timeZone: .current)
        let today = Calendar.current.startOfDay(for: Date())
        let result = source.collect(cutoff: today, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1 && result.status.filesScanned == 1, "cutoff avoids old AGY transcript bytes")
        try check(result.entries.contains { $0.kind == .skill && $0.name == "new-skill" }, "new read_file Path skill schema")
        try check(result.entries.contains { $0.kind == .mcp && $0.server == "my_server" && $0.name == "my_server/search" }, "eager MCP uses longest configured server prefix")
        _ = source.collect(cutoff: today, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 0, "unchanged recent transcripts are cached")
        _ = source.collect(knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1, "all-history range backfills uncached old transcript")
        _ = source.collect(knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 0, "all-history refresh does not reread unchanged bytes")
        _ = source.collect(cutoff: today, rescan: true, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1, "explicit Rescan bypasses cache without bypassing selected range")
        try write(row + "\n\n", recent)
        _ = source.collect(cutoff: today, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1, "changed transcript is reparsed")
        let reclassified = source.collect(cutoff: today, knownMCPServers: [])
        try check(source.lastFilesRead == 1 && !reclassified.entries.contains { $0.kind == .mcp }, "inventory change invalidates eager-MCP classification cache")

        // Sanitized real export schema: each argument value is independently JSON encoded.
        let encodedRow = #"{"step_index":2,"created_at":"2026-11-11T03:56:29Z","tool_calls":[{"name":"read_file","args":{"Path":"\"/skills/quoted skill/SKILL.md\""}},{"name":"call_mcp_tool","args":{"ServerName":"\"engram\"","ToolName":"\"mem_search\""}}]}"#
        try write(encodedRow + "\n", recent)
        let encoded = source.collect(rescan: true)
        try check(encoded.entries.contains { $0.kind == .skill && $0.name == "quoted skill" }, "real-export JSON-encoded Path counts skill")
        try check(encoded.entries.contains { $0.kind == .mcp && $0.name == "engram/mem_search" && $0.server == "engram" }, "real-export MCP names have no JSON quotes")

        let shell = home.appendingPathComponent(".bash_profile")
        try write("if true; then\nexport OPENAI_API_KEY='fixture'\nfi\n", shell)
        let finding = try EnvironmentOverrideDetector.scan(home: home, inherited: [:]).first { $0.file == shell }!
        let undo = try EnvironmentOverrideDetector.remove(finding)
        for executable in ["/bin/bash", "/bin/zsh"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["-n", shell.path]
            process.terminationHandler = { _ in }; try process.run(); process.waitUntilExit()
            try check(process.terminationStatus == 0, "removing sole branch assignment keeps shell syntax valid")
        }
        try undo.restore()
        try check(try String(contentsOf: shell, encoding: .utf8).contains("export OPENAI_API_KEY"), "branch removal Undo restores original assignment")

        let vault = Vault(); let store = AgentMCPStore(home: home, platform: .codex, vault: vault.service)
        try write("[mcp_servers.remote]\nurl = \"https://mcp.example.test/service\"\n[mcp_servers.local]\ncommand = \"/usr/bin/true\"\ncwd = \"/tmp\"\nenv_vars = [\"PATH\"]\n", store.configURL)
        let items = try store.items()
        try check(items.first { $0.name == "remote" }?.health == nil, "valid remote MCP is not judged by stdio-only importer")
        try check(items.first { $0.name == "local" }?.health == nil, "advanced stdio fields do not cause false health warning")
        try store.importServers([.init(name: "keychain", command: "/usr/bin/true", env: ["KEY": "fixture-only"])])
        try check(try store.items().first { $0.name == "keychain" }?.canAuthorizeKeychain == true, "managed env launcher exposes explicit foreground authorization check")
        let readers = Attempts()
        try await store.verifyKeychainAccess(name: "keychain") { args in
            guard args.count == 6, args[0] == "find-generic-password", args[2] == MCPSecretVault.service, args[5] == "-w" else { throw AgentMCPStore.Failure.invalid("Unsafe reader arguments") }
            await readers.add(args[4])
        }
        let readerCount = await readers.count()
        try check(readerCount == 1, "Keychain check calls only injected reader, never MCP command")

        let good = home.appendingPathComponent("auth/a.json"); let other = home.appendingPathComponent("auth/b.json")
        let broken = home.appendingPathComponent("auth/directory.json")
        try write(#"{"type":"codex","disabled":false}"#, good); try write(#"{"type":"codex","disabled":false}"#, other)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let outcome = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [good, broken, other], shouldTrip: true, reason: "fixture")
        try check(try object(good)["disabled"] as? Bool == true && object(other)["disabled"] as? Bool == true, "Codex protection continues after one target fails")
        try check(outcome?.tripped == true && outcome?.error != nil, "partial protection reports error rather than nil/full success")
        let failed = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [broken], shouldTrip: true, reason: "fixture")
        try check(failed?.tripped == false && failed?.error != nil, "total protection failure is visible and does not claim paused")

        try check(failed?.error?.contains("could not update any target") == true, "total failure never implies partial protection")
        try check(outcome?.error?.contains("updated only part") == true, "partial protection message stays distinct")

        let cpaAuth = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
        let workspaceA = cpaAuth.appendingPathComponent("aiusage-codex-a.json")
        let workspaceB = cpaAuth.appendingPathComponent("aiusage-codex-b.json")
        try write(#"{"type":"codex","email":"shared@example.test","account_id":"workspace-a","user_id":"user-a"}"#, workspaceA)
        try write(#"{"type":"codex","email":"shared@example.test","account_id":"workspace-b","user_id":"user-a"}"#, workspaceB)
        let targets = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(providerPrefix: "codex", email: "shared@example.test", currentFileURL: workspaceA, homeDirectory: home.path)
        try check(targets == [workspaceA], "same-email breaker targeting respects Codex workspace identity")
        _ = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: targets, shouldTrip: true, reason: "fixture workspace A")
        try check(try object(workspaceA)["disabled"] as? Bool == true && object(workspaceB)["disabled"] == nil, "depleted workspace never disables healthy sibling workspace")
        let unknown = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(providerPrefix: "codex", email: "shared@example.test", currentFileURL: nil, homeDirectory: home.path)
        try check(unknown.isEmpty, "Codex breaker refuses email-only identity")
        let staleSource = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(providerPrefix: "codex", email: "shared@example.test", currentFileURL: workspaceA, homeDirectory: home.path,
            codexIdentity: .init(accountId: "workspace-b", userId: "user-a", email: "shared@example.test"))
        try check(!staleSource.contains(workspaceA), "explicit fetched identity guards current path reused by another workspace")

        try write(#"{"type":"codex","email":"shared@example.test","account_id":"workspace-replaced","user_id":"user-a"}"#, workspaceA)
        let replaced = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: targets, shouldTrip: true, reason: "stale snapshot",
            codexIdentity: .init(accountId: "workspace-a", userId: "user-a", email: "shared@example.test"))
        try check(try object(workspaceA)["disabled"] == nil && replaced?.error != nil, "protection rejects account switched after target discovery")

        let claude = WeeklyResetPriority.Observation(provider: "claude-subscription", email: "fixture", reset: Date().addingTimeInterval(100))
        try check(claude.provider == "claude", "Claude subscription provider maps to CPA auth type")
        let claudeA = home.appendingPathComponent("claude-auth/a.json"); let claudeB = home.appendingPathComponent("claude-auth/b.json")
        try write(#"{"type":"claude","email":"fixture"}"#, claudeA); try write(#"{"type":"claude","email":"later"}"#, claudeB)
        try WeeklyResetPriority.sync(authDirectory: claudeA.deletingLastPathComponent(), enabled: true, observations: [claude,
            .init(provider: "claude-subscription", email: "later", reset: Date().addingTimeInterval(1000))])
        try check((try object(claudeA)["priority"] as! Int) > (try object(claudeB)["priority"] as! Int), "Claude observations reach real CPA priority ordering")

        let edited = claudeA
        var editedJSON = try object(edited); editedJSON["priority"] = 7
        try JSONSerialization.data(withJSONObject: editedJSON).write(to: edited)
        try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(edited)["priority"] as? Int == 7 && object(edited)["aiusage_weekly_priority"] == nil, "disabling preserves external priority and relinquishes stale marker")
        try check(try object(claudeB)["priority"] == nil && object(claudeB)["aiusage_weekly_priority"] == nil, "external edit does not prevent other account cleanup")
        try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: true, observations: [claude])
        for value in [500, 1500, -1500, 9] {
            editedJSON = try object(edited); editedJSON["priority"] = value
            try JSONSerialization.data(withJSONObject: editedJSON).write(to: edited)
            for _ in 0..<3 {
                try checkExternalPriorityWarning {
                    try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: true, observations: [claude])
                }
                try check(try object(edited)["priority"] as? Int == value, "repeated sync never rescales external effective priority \(value)")
            }
            try check(try object(claudeB)["aiusage_weekly_priority"] != nil, "external override does not block other accounts")
        }
        try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(edited)["priority"] as? Int == 9 && object(edited)["aiusage_weekly_priority"] == nil, "Off retains external override and clears ownership fence")
        let orderA = home.appendingPathComponent("effective-order/a.json")
        let orderB = home.appendingPathComponent("effective-order/b.json")
        try write(#"{"type":"claude","email":"fixture"}"#, orderA)
        try write(#"{"type":"claude","email":"later"}"#, orderB)
        let orderObservations = [claude, WeeklyResetPriority.Observation(provider: "claude", email: "later", reset: Date().addingTimeInterval(1000))]
        try WeeklyResetPriority.sync(authDirectory: orderA.deletingLastPathComponent(), enabled: true, observations: orderObservations)
        try check(try object(orderA)["priority"] as? Int == 999 && object(orderB)["priority"] as? Int == 998, "review repro starts with effective priorities 999 and 998")
        var effective = try object(orderA); effective["priority"] = 500
        let effectiveBytes = try JSONSerialization.data(withJSONObject: effective)
        try effectiveBytes.write(to: orderA)
        for _ in 0..<3 {
            try write(#"{"type":"claude","email":"later"}"#, orderB)
            try checkExternalPriorityWarning {
                try WeeklyResetPriority.sync(authDirectory: orderA.deletingLastPathComponent(), enabled: true, observations: orderObservations)
            }
            try check(try object(orderA)["priority"] as? Int == 500 && object(orderB)["priority"] as? Int == 998, "manual 500 remains below peer 998 on repeated refresh")
            try check(try Data(contentsOf: orderA) == effectiveBytes, "external override is byte-for-byte untouched while enabled")
        }
        try WeeklyResetPriority.sync(authDirectory: orderA.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(orderA)["priority"] as? Int == 500 && object(orderA)["aiusage_weekly_priority"] == nil, "Off preserves manual effective priority and clears marker without throwing")
        try check(try object(orderB)["priority"] == nil && object(orderB)["aiusage_weekly_priority"] == nil, "Off restores managed peer; relative order may change as warned")
        let tiered = home.appendingPathComponent("large-tier/a.json")
        try write(#"{"type":"claude","email":"fixture","priority":2000}"#, tiered)
        try WeeklyResetPriority.sync(authDirectory: tiered.deletingLastPathComponent(), enabled: true, observations: [claude])
        try check(try object(tiered)["priority"] as? Int == 2_000_999, "legitimate large original tier is not guessed to be an overlay")
        try WeeklyResetPriority.sync(authDirectory: tiered.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(tiered)["priority"] as? Int == 2000, "large original priority restored exactly")

        try check(QuotaBurnRate.windowDuration(label: "Gemini · Weekly") == 7 * 86400 && QuotaBurnRate.windowDuration(label: "每周窗口") == 7 * 86400, "weekly classification covers EN and ZH")
        try check(QuotaBurnRate.windowDuration(label: "5 小时") == 5 * 3600, "five-hour classification covers localized labels")
        try check(SharedFormatters.parseISO8601("2026-11-11T07:00:00.123Z") != nil, "shared parser retains fractional reset precision")
        let policy = home.appendingPathComponent("state.json")
        try write(#"{"version":1,"settings":{"routingStrategy":"round-robin"}}"#, policy)
        let snapshot = try Data(contentsOf: good)
        try await WeeklyResetPriorityWorker().sync(authDirectory: good.deletingLastPathComponent(), policyURL: policy, observations: [claude])
        try check(try Data(contentsOf: good) == snapshot, "background worker rechecks Off policy inside credential lock")
    }

}
