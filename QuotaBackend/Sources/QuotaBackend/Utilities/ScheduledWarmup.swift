import Foundation

public struct WarmupSettings: Codable, Sendable, Equatable {
    public struct Target: Codable, Identifiable, Sendable, Equatable {
        public enum Provider: String, Codable, Sendable { case codex, claude }
        public let provider: Provider
        public let directory: String
        public let email: String
        public let accountID: String?
        public var canonicalDirectory: String {
            guard let pointer = realpath(directory, nil) else { return URL(fileURLWithPath: directory).standardizedFileURL.path }
            defer { free(pointer) }; return String(cString: pointer)
        }
        public var id: String { "\(provider.rawValue):\(canonicalDirectory):\(email.lowercased()):\(accountID ?? "native")" }
        public init(provider: Provider, directory: String, email: String, accountID: String? = nil) { self.provider = provider; self.directory = directory; self.email = email; self.accountID = accountID }
    }
    public var enabled = false
    public var hour = 7
    public var minute = 0
    public var targets: [Target] = []
    public init() {}
    static func file(_ home: URL) -> URL { home.appendingPathComponent("Library/Application Support/AIUsage/warmup.json") }
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> Self {
        let file = file(home)
        guard FileManager.default.fileExists(atPath: file.path) else { return Self() }
        let value = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
        try value.validate()
        return value
    }
    private func validate() throws {
        guard (0...23).contains(hour), (0...59).contains(minute), targets.count <= 20,
              Set(targets.map(\.id)).count == targets.count,
              targets.allSatisfy({ $0.directory.hasPrefix("/") && !$0.email.isEmpty }) else { throw AgentMCPStore.Failure.invalid("Invalid warmup time or account directory/email.") }
    }
    public func save(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        try validate()
        let file = Self.file(home)
        try TokenSaverSettingsStore.rejectSymlinks(file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// App-running scheduler, not a launchd job. Never retries an ambiguous/failed inference.
public actor ScheduledWarmup {
    public struct Observation: Sendable {
        public let targetID: String
        public let fetchedAt: Date
        public let activeUntil: Date?
        public init(targetID: String, fetchedAt: Date, activeUntil: Date?) { self.targetID = targetID; self.fetchedAt = fetchedAt; self.activeUntil = activeUntil }
    }
    public static func observation(targetID: String, fetchedAt: String?, remainingPercent: Double?, resetAt: String?) -> Observation? {
        guard let fetchedAt, let fetched = SharedFormatters.parseISO8601(fetchedAt), let remainingPercent,
              remainingPercent.isFinite, (0...100).contains(remainingPercent) else { return nil }
        if let resetAt {
            guard let reset = SharedFormatters.parseISO8601(resetAt) else { return nil }
            return .init(targetID: targetID, fetchedAt: fetched, activeUntil: reset)
        }
        guard remainingPercent == 100 else { return nil }
        return .init(targetID: targetID, fetchedAt: fetched, activeUntil: nil)
    }
    private struct State: Codable {
        var day: String
        var due: Date
        var schedule: String?
        var attempted: Set<String>
    }
    private let home: URL
    private var running = false
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    public func tick(observations: [Observation], now: Date = Date(), calendar: Calendar = .current,
                     jitter: Int = Int.random(in: 300...900) * (Bool.random() ? 1 : -1),
                     spacing: @Sendable () -> UInt64 = { UInt64.random(in: 30...90) },
                     runner: @Sendable (WarmupSettings.Target) async throws -> Void) async throws {
        guard !running else { return }
        let settings = try WarmupSettings.load(home: home)
        guard settings.enabled, !settings.targets.isEmpty else { return }
        running = true; defer { running = false }
        let lockURL = home.appendingPathComponent("Library/Application Support/AIUsage/warmup.lock")
        try TokenSaverSettingsStore.rejectSymlinks(lockURL)
        let lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw AgentMCPStore.Failure.invalid("Cannot acquire warmup dispatch lock.") }
        defer { close(lockFD) }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { return }
        defer { _ = flock(lockFD, LOCK_UN) }

        let day = String(calendar.startOfDay(for: now).timeIntervalSince1970)
        let stateFile = home.appendingPathComponent("Library/Application Support/AIUsage/warmup-attempts.json")
        var state: State
        let signature = "\(settings.hour):\(settings.minute)"
        let due = calendar.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: now)!.addingTimeInterval(TimeInterval(max(-900, min(900, jitter))))
        if FileManager.default.fileExists(atPath: stateFile.path) {
            // Corrupt/unreadable uncertainty fences fail closed, never reset into another paid attempt.
            let saved = try JSONDecoder().decode(State.self, from: Data(contentsOf: stateFile))
            if saved.day == day || (saved.due >= calendar.startOfDay(for: now) && now.timeIntervalSince(saved.due) <= 1800) {
                state = saved
                if saved.schedule != signature { state.due = due; state.schedule = signature; try persist(state, file: stateFile) }
            } else { state = State(day: day, due: due, schedule: signature, attempted: []); try persist(state, file: stateFile) }
        } else {
            state = State(day: day, due: due, schedule: signature, attempted: [])
            try persist(state, file: stateFile)
        }
        guard now >= state.due, now.timeIntervalSince(state.due) <= 1800 else { return }
        let dispatchStarted = Date()
        var launched = false
        for target in settings.targets where !state.attempted.contains(target.id) {
            guard let observation = observations.first(where: { $0.targetID == target.id }),
                  now.timeIntervalSince(observation.fetchedAt) >= 0, now.timeIntervalSince(observation.fetchedAt) <= 600 else { continue }
            if let active = observation.activeUntil, active > now {
                state.attempted.insert(target.id); try persist(state, file: stateFile); continue
            }
            if launched { try await Task.sleep(nanoseconds: max(30, min(90, spacing())) * 1_000_000_000) }
            try Task.checkCancellation()
            let current = try WarmupSettings.load(home: home)
            guard current.enabled, current.targets.contains(target), current.hour == settings.hour, current.minute == settings.minute else { return }
            let dispatchNow = now.addingTimeInterval(Date().timeIntervalSince(dispatchStarted))
            guard dispatchNow.timeIntervalSince(observation.fetchedAt) <= 600 else { continue }
            // Durable uncertainty fence BEFORE dispatch. Restart must never replay a paid request.
            state.attempted.insert(target.id); try persist(state, file: stateFile)
            launched = true
            try await runner(target)
        }
    }
    private func persist(_ state: State, file: URL) throws {
        try TokenSaverSettingsStore.rejectSymlinks(file)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Bounded official CLI subprocess. No shell, no stdout/token logging, no automatic retry.
public enum OfficialWarmupProcess {
    public struct CodexIdentity: Sendable { public let email: String; public let accountID: String }
    public static func codexIdentity(directory: String) throws -> CodexIdentity {
        let file = URL(fileURLWithPath: directory).appendingPathComponent("auth.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        guard json?["OPENAI_API_KEY"] as? String == nil,
              let tokens = json?["tokens"] as? [String: Any], let token = tokens["id_token"] as? String else { throw AgentMCPStore.Failure.invalid("Warmup requires an official Codex subscription login, not an API key.") }
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw AgentMCPStore.Failure.invalid("Cannot identify Codex account.") }
        var base = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base += String(repeating: "=", count: (4 - base.count % 4) % 4)
        guard let data = Data(base64Encoded: base), let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any], let email = claims["email"] as? String else { throw AgentMCPStore.Failure.invalid("Cannot identify Codex account.") }
        guard let accountID = tokens["account_id"] as? String, !accountID.isEmpty else { throw AgentMCPStore.Failure.invalid("Cannot identify Codex workspace. Warmup skipped.") }
        return CodexIdentity(email: email, accountID: accountID)
    }
    public static func run(target: WarmupSettings.Target, executable: String, environment: [String: String]) async throws {
        var env = environment
        for key in EnvironmentOverrideDetector.keys { env.removeValue(forKey: key) }
        let arguments: [String]
        if target.provider == .codex {
            let identity = try codexIdentity(directory: target.directory)
            guard identity.email.lowercased() == target.email.lowercased(), identity.accountID == target.accountID else { throw AgentMCPStore.Failure.invalid("Codex account changed; warmup skipped.") }
            env["CODEX_HOME"] = target.directory
            arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "mcp_servers={}", "-c", "features.shell_tool=false", "Reply with OK only. Do not use any tools."]
        } else {
            env = ClaudeSubscriptionLaunch.environment(env, configDirectory: target.directory)
            arguments = ["-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--max-turns", "1", "Reply with OK only."]
        }
        let worker = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments; process.environment = env
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-warmup-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temporary) }
            process.currentDirectoryURL = temporary
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in }
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning {
                if Task.isCancelled || Date() >= deadline {
                    process.terminate()
                    for _ in 0..<10 { if !process.isRunning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw AgentMCPStore.Failure.invalid("Warmup timed out/cancelled. Not retried; check the official CLI.")
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard process.terminationStatus == 0 else { throw AgentMCPStore.Failure.invalid("Official CLI warmup failed. Not retried; check CLI login/version.") }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
