import CryptoKit
import Foundation

public struct WarmupSettings: Codable, Sendable, Equatable {
    public struct Target: Codable, Identifiable, Sendable, Equatable {
        public enum Provider: String, Codable, Sendable { case codex, claude }
        public let provider: Provider
        public let directory: String
        public let email: String
        public let accountID: String?
        public var canonicalDirectory: String { Self.canonicalPath(directory) }
        public var canonicalTargetPath: String {
            let targetPath = provider == .codex ? OfficialWarmupProcess.codexAuthFile(directory: directory).path : directory
            return Self.canonicalPath(targetPath)
        }
        public var normalizedEmail: String {
            email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        public var normalizedAccountID: String? {
            guard let raw = accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else { return nil }
            return raw
        }
        public func matchesSubscriptionAccount(of other: Target) -> Bool {
            guard provider == other.provider else { return false }
            if id == other.id || canonicalTargetPath == other.canonicalTargetPath { return true }
            if provider == .codex, normalizedEmail == other.normalizedEmail {
                guard let lhsAccount = normalizedAccountID, let rhsAccount = other.normalizedAccountID else { return true }
                return lhsAccount == rhsAccount
            }
            return false
        }
        private static func canonicalPath(_ rawPath: String) -> String {
            var current = URL(fileURLWithPath: rawPath).standardizedFileURL
            var tail: [String] = []
            while true {
                if let pointer = realpath(current.path, nil) {
                    defer { free(pointer) }
                    var resolved = URL(fileURLWithPath: String(cString: pointer))
                    for component in tail.reversed() {
                        resolved.appendPathComponent(component)
                    }
                    return resolved.path
                }
                let parent = current.deletingLastPathComponent()
                if parent.path == current.path { break }
                tail.append(current.lastPathComponent)
                current = parent
            }
            return URL(fileURLWithPath: rawPath).standardizedFileURL.path
        }
        public var id: String { "\(provider.rawValue):\(canonicalDirectory):\(email.lowercased()):\(accountID ?? "native")" }
        public init(provider: Provider, directory: String, email: String, accountID: String? = nil) { self.provider = provider; self.directory = directory; self.email = email; self.accountID = accountID }
    }
    public var enabled = false
    public var hour = 7
    public var minute = 0
    public var targets: [Target] = []
    public var autoChainReset = true
    public init() {}
    enum CodingKeys: String, CodingKey { case enabled, hour, minute, targets, autoChainReset }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        hour = try container.decodeIfPresent(Int.self, forKey: .hour) ?? 7
        minute = try container.decodeIfPresent(Int.self, forKey: .minute) ?? 0
        targets = try container.decodeIfPresent([Target].self, forKey: .targets) ?? []
        autoChainReset = try container.decodeIfPresent(Bool.self, forKey: .autoChainReset) ?? true
    }
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
        for index in targets.indices {
            if targets[..<index].contains(where: { $0.matchesSubscriptionAccount(of: targets[index]) }) {
                throw AgentMCPStore.Failure.invalid("Duplicate warmup account or workspace is already listed.")
            }
        }
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
    public struct WindowSample: Sendable {
        public let label: String
        public let remainingPercent: Double?
        public let resetAt: String?
        public init(label: String, remainingPercent: Double?, resetAt: String?) {
            self.label = label
            self.remainingPercent = remainingPercent
            self.resetAt = resetAt
        }
    }
    public static func isMainFiveHourWindowLabel(_ label: String) -> Bool {
        !label.contains("·") && QuotaBurnRate.windowDuration(label: label) == 5 * 3600
    }
    public static func isMainBlockingAllowanceWindowLabel(_ label: String) -> Bool {
        guard !label.contains("·") else { return false }
        if QuotaBurnRate.windowDuration(label: label) == 7 * 86400 { return true }
        let lower = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return [
            "monthly credit limit",
            "monthly window",
            "1 month",
            "月度积分上限",
            "1 个月",
            "giới hạn tín dụng tháng",
            "cửa sổ 1 tháng",
            "1 tháng"
        ].contains(lower)
    }
    public static func observation(targetID: String, fetchedAt: String?, windows: [WindowSample]) -> Observation? {
        guard let fiveHour = windows.first(where: { isMainFiveHourWindowLabel($0.label) }),
              let base = observation(targetID: targetID, fetchedAt: fetchedAt, remainingPercent: fiveHour.remainingPercent, resetAt: fiveHour.resetAt) else { return nil }
        var blockingUntil = base.activeUntil
        for window in windows where isMainBlockingAllowanceWindowLabel(window.label) {
            guard let remaining = window.remainingPercent, remaining.isFinite, (0...100).contains(remaining) else { return nil }
            if remaining <= 0 {
                guard let resetAt = window.resetAt,
                      let reset = SharedFormatters.parseISO8601(resetAt),
                      reset > base.fetchedAt else { return nil }
                if let current = blockingUntil {
                    if reset > current { blockingUntil = reset }
                } else {
                    blockingUntil = reset
                }
            }
        }
        return Observation(targetID: base.targetID, fetchedAt: base.fetchedAt, activeUntil: blockingUntil)
    }
    public static func observation(targetID: String, fetchedAt: String?, remainingPercent: Double?, resetAt: String?) -> Observation? {
        guard let fetchedAt, let fetched = SharedFormatters.parseISO8601(fetchedAt), let remainingPercent,
              remainingPercent.isFinite, (0...100).contains(remainingPercent) else { return nil }
        if let resetAt {
            guard let reset = SharedFormatters.parseISO8601(resetAt) else { return nil }
            // OpenAI wham/usage returns reset_after_seconds=18000 even when the 5h window is unstarted.
            if remainingPercent == 100, reset.timeIntervalSince(fetched) >= 5 * 3600 - 90 {
                return .init(targetID: targetID, fetchedAt: fetched, activeUntil: nil)
            }
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
        var windowEndsAt: [String: Date]?
        var nextChainDueAt: [String: Date]?
        var lastDispatchAt: Date?
    }
    private let home: URL
    private var running = false
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }
    public func tick(observations: [Observation],
                     liveObservation: (@Sendable (WarmupSettings.Target) async -> Observation?)? = nil,
                     preflight: (@Sendable (WarmupSettings.Target) async throws -> Void)? = nil,
                     now: Date = Date(), calendar: Calendar = .current,
                     jitter: Int = Int.random(in: 300...900) * (Bool.random() ? 1 : -1),
                     spacing: @Sendable () -> UInt64 = { UInt64.random(in: 60...180) },
                     postResetDelay: @Sendable () -> Int = { Int.random(in: 300...1200) },
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
            } else {
                state = State(day: day, due: due, schedule: signature, attempted: [],
                              windowEndsAt: saved.windowEndsAt, nextChainDueAt: saved.nextChainDueAt, lastDispatchAt: saved.lastDispatchAt)
                try persist(state, file: stateFile)
            }
        } else {
            state = State(day: day, due: due, schedule: signature, attempted: [], windowEndsAt: [:], nextChainDueAt: [:], lastDispatchAt: nil)
            try persist(state, file: stateFile)
        }
        let inDailyWindow = now >= state.due && now.timeIntervalSince(state.due) <= 1800
        guard inDailyWindow || settings.autoChainReset else { return }

        var windowEnds = state.windowEndsAt ?? [:]
        var chainDue = state.nextChainDueAt ?? [:]
        var stateDirty = false
        let dispatchStarted = Date()
        var launched = false
        var firstError: Error?
        let orderedTargets = jitter == 0 ? settings.targets : settings.targets.shuffled()
        for target in orderedTargets {
            let checkNow = now.addingTimeInterval(Date().timeIntervalSince(dispatchStarted))
            let resolved: Observation?
            if let liveObservation { resolved = await liveObservation(target) } else { resolved = observations.first(where: { $0.targetID == target.id }) }
            guard let observation = resolved,
                  checkNow.timeIntervalSince(observation.fetchedAt) >= 0, checkNow.timeIntervalSince(observation.fetchedAt) <= 600 else { continue }
            if let active = observation.activeUntil, active > checkNow {
                if windowEnds[target.id] != active { windowEnds[target.id] = active; stateDirty = true }
                if settings.autoChainReset, (chainDue[target.id] ?? .distantPast) <= active {
                    chainDue[target.id] = active.addingTimeInterval(TimeInterval(max(0, postResetDelay())))
                    stateDirty = true
                }
                if state.attempted.insert(target.id).inserted { stateDirty = true }
                continue
            }
            if let trackedEnd = windowEnds[target.id], trackedEnd > checkNow {
                if settings.autoChainReset, (chainDue[target.id] ?? .distantPast) <= trackedEnd {
                    chainDue[target.id] = trackedEnd.addingTimeInterval(TimeInterval(max(0, postResetDelay())))
                    stateDirty = true
                }
                continue
            }
            if let finishedEnd = windowEnds.removeValue(forKey: target.id) {
                stateDirty = true
                if settings.autoChainReset, chainDue[target.id] == nil {
                    chainDue[target.id] = max(checkNow, finishedEnd).addingTimeInterval(TimeInterval(max(0, postResetDelay())))
                }
            }
            if inDailyWindow && !state.attempted.contains(target.id) {
                if let dueAt = chainDue[target.id], checkNow < dueAt { continue }
            } else if settings.autoChainReset {
                if let dueAt = chainDue[target.id] {
                    guard checkNow >= dueAt else { continue }
                } else {
                    let dueAt = checkNow.addingTimeInterval(TimeInterval(max(0, postResetDelay())))
                    chainDue[target.id] = dueAt
                    stateDirty = true
                    if checkNow < dueAt { continue }
                }
            } else {
                continue
            }
            if stateDirty {
                state.windowEndsAt = windowEnds; state.nextChainDueAt = chainDue; stateDirty = false
                try persist(state, file: stateFile)
            }
            if launched {
                try await Task.sleep(nanoseconds: max(60, min(180, spacing())) * 1_000_000_000)
            } else if let last = state.lastDispatchAt {
                let elapsed = checkNow.timeIntervalSince(last)
                if elapsed >= 0 && elapsed < 60 {
                    let remaining = min(90, max(1, UInt64(ceil(60 - elapsed))))
                    try await Task.sleep(nanoseconds: remaining * 1_000_000_000)
                }
            }
            try Task.checkCancellation()
            let current = try WarmupSettings.load(home: home)
            guard current.enabled, current.targets.contains(target), current.hour == settings.hour, current.minute == settings.minute,
                  current.autoChainReset == settings.autoChainReset else { return }
            let dispatchNow = now.addingTimeInterval(Date().timeIntervalSince(dispatchStarted))
            let latestObs: Observation?
            if let liveObservation { latestObs = await liveObservation(target) } else { latestObs = observation }
            guard let latestObs,
                  dispatchNow.timeIntervalSince(latestObs.fetchedAt) >= 0,
                  dispatchNow.timeIntervalSince(latestObs.fetchedAt) <= 600,
                  latestObs.activeUntil.map({ $0 <= dispatchNow }) ?? true else { continue }
            if let preflight {
                do {
                    try await preflight(target)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    if firstError == nil { firstError = error }
                    continue
                }
            }
            // Durable uncertainty fence BEFORE dispatch. Restart must never replay a paid request.
            let priorState = state
            let priorWindowEnds = windowEnds
            let priorChainDue = chainDue
            let priorLaunched = launched
            state.attempted.insert(target.id)
            let cycleEnd = dispatchNow.addingTimeInterval(5 * 3600)
            windowEnds[target.id] = cycleEnd
            chainDue[target.id] = cycleEnd.addingTimeInterval(TimeInterval(max(0, postResetDelay())))
            state.windowEndsAt = windowEnds
            state.nextChainDueAt = chainDue
            state.lastDispatchAt = dispatchNow
            stateDirty = false
            try persist(state, file: stateFile)
            launched = true
            do {
                try await runner(target)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as OfficialWarmupProcess.PreSpawnFailure {
                state = priorState
                windowEnds = priorWindowEnds
                chainDue = priorChainDue
                launched = priorLaunched
                try persist(state, file: stateFile)
                if firstError == nil { firstError = error }
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if stateDirty {
            state.windowEndsAt = windowEnds
            state.nextChainDueAt = chainDue
            try persist(state, file: stateFile)
        }
        if let firstError { throw firstError }
    }
    private func persist(_ state: State, file: URL) throws {
        try TokenSaverSettingsStore.rejectSymlinks(file)
        try JSONEncoder().encode(state).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// Bounded official CLI subprocess. No shell, no stdout/token logging, no automatic retry.
public enum OfficialWarmupProcess {
    public static let prompts = [
        "Reply with OK only. Do not use any tools.",
        "Reply with READY only. Do not use any tools.",
        "Reply with YES only. Do not use any tools.",
        "Reply with PONG only. Do not use any tools.",
        "Reply with ACK only. Do not use any tools."
    ]
    public static let scrubbedEnvironmentKeys: Set<String> = EnvironmentOverrideDetector.keys.union(["CODEX_API_KEY"])
    public struct CodexIdentity: Sendable { public let email: String; public let accountID: String }
    public struct PreSpawnFailure: LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
    public struct RecoveryRequiredFailure: LocalizedError, Sendable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
    public static func codexAuthFile(directory: String) -> URL {
        let url = URL(fileURLWithPath: directory)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? url.appendingPathComponent("auth.json") : url
        }
        return url.pathExtension.lowercased() == "json" ? url : url.appendingPathComponent("auth.json")
    }
    public static func codexIdentity(directory: String) throws -> CodexIdentity {
        let file = codexAuthFile(directory: directory)
        try TokenSaverSettingsStore.rejectSymlinks(file)
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] else {
            throw AgentMCPStore.Failure.invalid("Cannot identify Codex account.")
        }
        return try validatedCodexIdentity(from: try parsedCodexIdentity(from: json))
    }
    public static func preflight(target: WarmupSettings.Target) throws {
        if target.provider == .codex {
            let sourceFile = codexAuthFile(directory: target.directory)
            try TokenSaverSettingsStore.rejectSymlinks(sourceFile)
            let data = try Data(contentsOf: sourceFile)
            let baseline = try validatedCodexBaseline(from: data, target: target)
            let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(
                managedNativeData: data,
                managedSourceData: data,
                expectedIdentity: baseline.authIdentity,
                candidatePaths: []
            )
            guard reconciled.isValidBaseline else {
                throw AgentMCPStore.Failure.invalid("Codex credential baseline is invalid; warmup skipped.")
            }
        } else {
            try TokenSaverSettingsStore.rejectSymlinks(URL(fileURLWithPath: target.directory))
        }
    }
    public static func run(target: WarmupSettings.Target, executable: String, environment: [String: String]) async throws {
        var env = environment
        for key in scrubbedEnvironmentKeys { env.removeValue(forKey: key) }
        let temporary: URL
        let workdir: URL
        do {
            temporary = FileManager.default.temporaryDirectory.appendingPathComponent("aiusage-warmup-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            workdir = temporary.appendingPathComponent("workdir")
            try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw PreSpawnFailure(error.localizedDescription)
        }
        var preserveStagedDirectory = false
        defer { if !preserveStagedDirectory { try? FileManager.default.removeItem(at: temporary) } }

        if target.provider == .codex {
            let sourceFile = codexAuthFile(directory: target.directory)
            let lockKey: String
            do {
                try TokenSaverSettingsStore.rejectSymlinks(sourceFile)
                let initialData = try Data(contentsOf: sourceFile)
                let initialBaseline = try validatedCodexBaseline(from: initialData, target: target)
                let initialRefresh = codexRefreshToken(from: initialBaseline.json)
                lockKey = CodexOAuthRefreshSerializer.lockKey(
                    accountId: initialBaseline.authIdentity.accountId ?? target.accountID,
                    userId: initialBaseline.authIdentity.userId,
                    refreshToken: initialRefresh,
                    path: sourceFile.path
                )
            } catch let error as PreSpawnFailure {
                throw error
            } catch {
                throw PreSpawnFailure(error.localizedDescription)
            }
            let capturedEnv = env
            let (shouldPreserve, result) = try await CodexOAuthRefreshSerializer.shared.run(key: lockKey) { () -> (Bool, Result<Void, Error>) in
                let homeURL = codexEnclosingHome(for: sourceFile)
                let importBoundary = managedAuthImportBoundary(for: sourceFile, homeURL: homeURL)
                let stagedAuth: URL
                let stagedBaselineData: Data
                let expectedIdentity: CodexAccountIdentity
                let ownerCredentialID: String?
                let arguments: [String]
                let runEnv: [String: String]
                do {
                    try TokenSaverSettingsStore.rejectSymlinks(sourceFile)
                    let originalData = try Data(contentsOf: sourceFile)
                    let baseline = try validatedCodexBaseline(from: originalData, target: target)
                    expectedIdentity = baseline.authIdentity
                    ownerCredentialID = codexCredentialID(sourceFile: sourceFile, json: baseline.json)
                    let peerPaths = codexSameIdentityPaths(
                        sourceFile: sourceFile,
                        credentialID: ownerCredentialID,
                        expectedIdentity: expectedIdentity,
                        boundary: importBoundary,
                        homeURL: homeURL,
                        forHealing: false
                    )
                    let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(
                        managedNativeData: originalData,
                        managedSourceData: originalData,
                        expectedIdentity: expectedIdentity,
                        candidatePaths: peerPaths
                    )
                    guard reconciled.isValidBaseline else {
                        throw AgentMCPStore.Failure.invalid("Codex credential baseline is invalid; warmup skipped.")
                    }
                    let codexHome = temporary.appendingPathComponent("codex-home")
                    try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    stagedAuth = codexHome.appendingPathComponent("auth.json")
                    stagedBaselineData = reconciled.nativeData
                    try stagedBaselineData.write(to: stagedAuth, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: stagedAuth.path)

                    var nextEnv = capturedEnv
                    nextEnv["CODEX_HOME"] = codexHome.path
                    runEnv = nextEnv
                    let prompt = prompts.randomElement() ?? prompts[0]
                    arguments = ["exec", "--ignore-user-config", "--ignore-rules", "--ephemeral", "--skip-git-repo-check", "--sandbox", "read-only", "-c", "mcp_servers={}", "-c", "features.shell_tool=false", prompt]
                } catch let error as PreSpawnFailure {
                    throw error
                } catch {
                    throw PreSpawnFailure(error.localizedDescription)
                }

                let outcome = await executeSubprocess(executable: executable, arguments: arguments, environment: runEnv, workdir: workdir)
                let postRunDestinations = [sourceFile.path] + codexSameIdentityPaths(
                    sourceFile: sourceFile,
                    credentialID: ownerCredentialID,
                    expectedIdentity: expectedIdentity,
                    boundary: importBoundary,
                    homeURL: homeURL,
                    forHealing: true
                )
                let healedDurably = healStagedCodexAuth(
                    stagedAuth: stagedAuth,
                    stagedBaselineData: stagedBaselineData,
                    destinations: postRunDestinations,
                    expectedIdentity: expectedIdentity,
                    boundary: importBoundary,
                    homeURL: homeURL
                )
                return (!healedDurably, outcome)
            }
            if shouldPreserve {
                preserveStagedDirectory = true
                throw RecoveryRequiredFailure("Codex warmup rotated credentials, but no durable credential file could be updated. Recovery data was saved to a protected recovery folder; restore or reconnect the account before the next warmup.")
            }
            try result.get()
            return
        }

        let settingsOverride: String
        do {
            settingsOverride = try ClaudeSubscriptionLaunch.settingsOverride()
        } catch {
            throw PreSpawnFailure(error.localizedDescription)
        }
        let claudeEnv = ClaudeSubscriptionLaunch.environment(env, configDirectory: target.directory)
        let claudeArgs = ["--settings", settingsOverride, "-p", "--safe-mode", "--tools", "", "--strict-mcp-config", "--mcp-config", "{\"mcpServers\":{}}", "--no-session-persistence", "--max-turns", "1", "Reply with OK only."]
        let result = await executeSubprocess(executable: executable, arguments: claudeArgs, environment: claudeEnv, workdir: workdir)
        try result.get()
    }
    private static func executeSubprocess(executable: String, arguments: [String], environment: [String: String], workdir: URL) async -> Result<Void, Error> {
        let worker = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments; process.environment = environment
            process.currentDirectoryURL = workdir
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
            process.terminationHandler = { _ in }
            do {
                try process.run()
            } catch {
                throw PreSpawnFailure(error.localizedDescription)
            }
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
        return await withTaskCancellationHandler { await worker.result } onCancel: { worker.cancel() }
    }
    private static func parsedCodexIdentity(from json: [String: Any]) throws -> CodexAccountIdentity {
        if let apiKey = json["OPENAI_API_KEY"] as? String, !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw AgentMCPStore.Failure.invalid("Warmup requires an official Codex subscription login, not an API key.")
        }
        return CodexAccountIdentity(authJSON: json)
    }
    private static func validatedCodexIdentity(from parsed: CodexAccountIdentity) throws -> CodexIdentity {
        guard let email = parsed.email, !email.isEmpty else {
            throw AgentMCPStore.Failure.invalid("Warmup requires an official Codex subscription login, not an API key.")
        }
        guard let accountID = parsed.accountId, !accountID.isEmpty else {
            throw AgentMCPStore.Failure.invalid("Cannot identify Codex workspace. Warmup skipped.")
        }
        return CodexIdentity(email: email, accountID: accountID)
    }
    private static func validatedCodexBaseline(from data: Data, target: WarmupSettings.Target) throws -> (identity: CodexIdentity, authIdentity: CodexAccountIdentity, json: [String: Any]) {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AgentMCPStore.Failure.invalid("Cannot identify Codex account.")
        }
        let authIdentity = try parsedCodexIdentity(from: json)
        let identity = try validatedCodexIdentity(from: authIdentity)
        guard identity.email.lowercased() == target.email.lowercased(),
              let expectedAccountID = target.accountID,
              identity.accountID.lowercased() == expectedAccountID.lowercased() else {
            throw AgentMCPStore.Failure.invalid("Codex account changed; warmup skipped.")
        }
        return (identity, authIdentity, json)
    }
    private static func codexTokenField(_ keys: [String], from json: [String: Any]) -> String? {
        let tokens = json["tokens"] as? [String: Any]
        for key in keys {
            if let raw = (json[key] ?? tokens?[key]) as? String {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }
    private static func codexRefreshToken(from json: [String: Any]) -> String? {
        codexTokenField(["refresh_token", "refreshToken"], from: json)
    }
    private static func codexAccessToken(from json: [String: Any]) -> String? {
        codexTokenField(["access_token", "accessToken"], from: json)
    }
    private static func codexCredentialID(sourceFile: URL, json: [String: Any]) -> String? {
        let tokens = json["tokens"] as? [String: Any]
        let ownerID = ((json["aiusage_credential_id"] ?? tokens?["aiusage_credential_id"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let ownerID, !ownerID.isEmpty { return ownerID }
        let stem = sourceFile.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        return stem.isEmpty ? nil : stem
    }
    private static func codexEnclosingHome(for sourceFile: URL) -> URL {
        let standardized = sourceFile.resolvingSymlinksInPath().standardizedFileURL
        if standardized.deletingLastPathComponent().lastPathComponent == ".codex" {
            return standardized.deletingLastPathComponent().deletingLastPathComponent()
        }
        if let range = standardized.path.range(of: "/Library/Application Support/AIUsage/") {
            return URL(fileURLWithPath: String(standardized.path[..<range.lowerBound]))
        }
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        if standardized.path.hasPrefix(realHome.path + "/") {
            return realHome
        }
        return standardized.deletingLastPathComponent()
    }
    private static func managedAuthImportBoundary(for sourceFile: URL, homeURL: URL) -> ManagedAuthImportBoundary {
        let appSupport = homeURL.appendingPathComponent("Library/Application Support", isDirectory: true)
        if let mainBundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           mainBundleID == ManagedAuthImportBoundary.productionBundleIdentifier || mainBundleID.hasPrefix(ManagedAuthImportBoundary.productionBundleIdentifier + ".") {
            return ManagedAuthImportBoundary(bundleIdentifier: mainBundleID, applicationSupportDirectory: appSupport)
        }
        if let sourceBundleID = inferredBundleIdentifier(fromManagedSourceFile: sourceFile, applicationSupportDirectory: appSupport) {
            return ManagedAuthImportBoundary(bundleIdentifier: sourceBundleID, applicationSupportDirectory: appSupport)
        }
        return ManagedAuthImportBoundary(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            applicationSupportDirectory: appSupport
        )
    }
    private static func inferredBundleIdentifier(fromManagedSourceFile sourceFile: URL, applicationSupportDirectory: URL) -> String? {
        let aiUsagePath = applicationSupportDirectory
            .appendingPathComponent("AIUsage", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        let sourcePath = sourceFile.resolvingSymlinksInPath().standardizedFileURL.path
        guard sourcePath.hasPrefix(aiUsagePath + "/") else { return nil }
        let relative = sourcePath.dropFirst(aiUsagePath.count + 1)
        guard let rootName = relative.split(separator: "/", maxSplits: 1).first.map(String.init) else { return nil }
        if rootName == "AuthImports" {
            return ManagedAuthImportBoundary.productionBundleIdentifier
        }
        if rootName.hasPrefix("AuthImports-") {
            let suffix = String(rootName.dropFirst("AuthImports-".count))
            return suffix.isEmpty ? nil : suffix
        }
        return nil
    }
    private static func isManagedImportPath(_ rawPath: String, homeURL: URL) -> Bool {
        let expanded = NSString(string: rawPath).expandingTildeInPath
        let canonical = URL(fileURLWithPath: expanded).resolvingSymlinksInPath().standardizedFileURL.path
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        let homes = homeURL == realHome ? [homeURL] : [homeURL, realHome]
        for home in homes {
            let prefix = home
                .appendingPathComponent("Library/Application Support/AIUsage/AuthImports", isDirectory: false)
                .resolvingSymlinksInPath()
                .standardizedFileURL
                .path
            if canonical == prefix || canonical.hasPrefix(prefix + "/") || canonical.hasPrefix(prefix + "-") {
                return true
            }
        }
        return false
    }
    private static func codexSameIdentityPaths(
        sourceFile: URL,
        credentialID: String?,
        expectedIdentity: CodexAccountIdentity,
        boundary: ManagedAuthImportBoundary,
        homeURL: URL,
        forHealing: Bool
    ) -> [String] {
        let fm = FileManager.default
        var candidates = [
            homeURL.appendingPathComponent(".codex/auth.json").path,
            homeURL.appendingPathComponent(".codex/auth.json.bak").path,
            sourceFile.path + ".bak"
        ]
        let managedRoots = forHealing ? [boundary.activeRootURL] : boundary.readableRootURLs
        let healingExcludedRecoveryPrefix = boundary.activeRootURL
            .appendingPathComponent("warmup-recovery", isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        for dir in managedRoots {
            guard (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  (try? dir.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  let enumerator = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else { continue }
            for case let fileURL as URL in enumerator {
                if (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator.skipDescendants()
                    continue
                }
                if forHealing {
                    let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
                    if canonical == healingExcludedRecoveryPrefix || canonical.hasPrefix(healingExcludedRecoveryPrefix + "/") {
                        enumerator.skipDescendants()
                        continue
                    }
                }
                if fileURL.pathExtension.lowercased() == "json",
                   (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                    candidates.append(fileURL.path)
                }
            }
        }
        let realHome = fm.homeDirectoryForCurrentUser.resolvingSymlinksInPath().standardizedFileURL
        if homeURL == realHome {
            for cred in AccountCredentialStore.shared.loadCredentials(for: "codex") where cred.authMethod == .authFile {
                candidates.append(cred.credential)
                if let src = cred.metadata["sourcePath"], !src.isEmpty { candidates.append(src) }
            }
        }
        if let credentialID, !credentialID.isEmpty {
            candidates.append(contentsOf: CodexLinkedCredentialCopies.paths(
                forCredentialId: credentialID,
                nativeIdentityKey: expectedIdentity.nativeKey
            ))
        }
        let normalizedSource = AccountCredentialStore.normalizedAuthFilePath(sourceFile.path)
        var seen = Set<String>()
        var result: [String] = []
        for raw in candidates {
            let expanded = NSString(string: raw).expandingTildeInPath
            if isManagedImportPath(expanded, homeURL: homeURL) {
                let permitted = forHealing
                    ? (boundary.writableManagedPath(expanded) != nil)
                    : (boundary.readableManagedPath(expanded) != nil)
                guard permitted else { continue }
            }
            let normalized = AccountCredentialStore.normalizedAuthFilePath(expanded)
            guard !normalized.isEmpty,
                  normalized != normalizedSource,
                  seen.insert(normalized).inserted else { continue }
            let url = URL(fileURLWithPath: expanded)
            guard fm.fileExists(atPath: url.path),
                  (try? TokenSaverSettingsStore.rejectSymlinks(url)) != nil else { continue }
            result.append(expanded)
        }
        return result
    }
    @discardableResult
    private static func healStagedCodexAuth(
        stagedAuth: URL,
        stagedBaselineData: Data,
        destinations: [String],
        expectedIdentity: CodexAccountIdentity,
        boundary: ManagedAuthImportBoundary,
        homeURL: URL
    ) -> Bool {
        guard FileManager.default.fileExists(atPath: stagedAuth.path) else { return true }
        let rotationCheck = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: stagedBaselineData,
            managedSourceData: stagedBaselineData,
            expectedIdentity: expectedIdentity,
            candidatePaths: [stagedAuth.path]
        )
        let didRotate = rotationCheck.isValidBaseline && rotationCheck.adoptedLiveCandidate
        let rotatedAccess = didRotate ? codexAccessToken(from: rotationCheck.nativeJSON) : nil
        let rotatedRefresh = didRotate ? codexRefreshToken(from: rotationCheck.nativeJSON) : nil

        var durableSaves = 0
        for path in destinations {
            if isManagedImportPath(path, homeURL: homeURL) {
                guard boundary.writableManagedPath(path) != nil else { continue }
            }
            let destURL = URL(fileURLWithPath: path)
            guard (try? TokenSaverSettingsStore.rejectSymlinks(destURL)) != nil,
                  let currentData = try? Data(contentsOf: destURL),
                  let destJSON = (try? JSONSerialization.jsonObject(with: currentData)) as? [String: Any] else { continue }
            let destIdentity = CodexAccountIdentity(authJSON: destJSON)
            guard CodexCredentialPolicy.identitiesMatchExactly(expectedIdentity, destIdentity) else { continue }
            let healed = CodexCredentialPolicy.reconcileSameIdentityAuthData(
                managedNativeData: currentData,
                managedSourceData: currentData,
                expectedIdentity: expectedIdentity,
                candidatePaths: [stagedAuth.path]
            )
            if healed.isValidBaseline,
               healed.adoptedLiveCandidate,
               let healedData = healed.healedManagedData,
               healedData != currentData,
               (try? Data(contentsOf: destURL)) == currentData {
                do {
                    try healedData.write(to: destURL, options: .atomic)
                    try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destURL.path)
                    if (try? Data(contentsOf: destURL)) == healedData {
                        durableSaves += 1
                    }
                } catch {
                    continue
                }
            } else if didRotate,
                      healed.isValidBaseline,
                      !healed.adoptedLiveCandidate,
                      codexRefreshToken(from: destJSON) == rotatedRefresh,
                      codexAccessToken(from: destJSON) == rotatedAccess {
                durableSaves += 1
            }
        }
        if didRotate {
            if durableSaves == 0 {
                persistWarmupRecoveryCopy(
                    data: rotationCheck.healedManagedData ?? rotationCheck.nativeData,
                    expectedIdentity: expectedIdentity,
                    boundary: boundary
                )
            } else {
                clearWarmupRecoveryCopy(expectedIdentity: expectedIdentity, boundary: boundary)
            }
        }
        return !didRotate || durableSaves > 0
    }
    private static func warmupRecoveryFile(expectedIdentity: CodexAccountIdentity, boundary: ManagedAuthImportBoundary) -> URL? {
        guard let key = expectedIdentity.nativeKey ?? expectedIdentity.key else { return nil }
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return boundary.activeRootURL
            .appendingPathComponent("warmup-recovery", isDirectory: true)
            .appendingPathComponent("\(digest).json")
    }
    private static func persistWarmupRecoveryCopy(
        data: Data,
        expectedIdentity: CodexAccountIdentity,
        boundary: ManagedAuthImportBoundary
    ) {
        guard !data.isEmpty,
              let recoveryFile = warmupRecoveryFile(expectedIdentity: expectedIdentity, boundary: boundary),
              boundary.writableManagedPath(recoveryFile.path) != nil,
              (try? TokenSaverSettingsStore.rejectSymlinks(recoveryFile)) != nil else { return }
        let fm = FileManager.default
        let recoveryDir = recoveryFile.deletingLastPathComponent()
        do {
            try fm.createDirectory(at: recoveryDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: recoveryDir.path)
            if let existingData = try? Data(contentsOf: recoveryFile),
               let existingJSON = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any] {
                let existingIdentity = CodexAccountIdentity(authJSON: existingJSON)
                guard CodexCredentialPolicy.identitiesMatchExactly(expectedIdentity, existingIdentity) else { return }
            }
            try data.write(to: recoveryFile, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryFile.path)
        } catch {
            return
        }
    }
    private static func clearWarmupRecoveryCopy(expectedIdentity: CodexAccountIdentity, boundary: ManagedAuthImportBoundary) {
        guard let recoveryFile = warmupRecoveryFile(expectedIdentity: expectedIdentity, boundary: boundary),
              boundary.writableManagedPath(recoveryFile.path) != nil,
              FileManager.default.fileExists(atPath: recoveryFile.path),
              (try? TokenSaverSettingsStore.rejectSymlinks(recoveryFile)) != nil,
              let existingData = try? Data(contentsOf: recoveryFile),
              let existingJSON = (try? JSONSerialization.jsonObject(with: existingData)) as? [String: Any],
              CodexCredentialPolicy.identitiesMatchExactly(expectedIdentity, CodexAccountIdentity(authJSON: existingJSON)) else { return }
        try? FileManager.default.removeItem(at: recoveryFile)
    }
}
