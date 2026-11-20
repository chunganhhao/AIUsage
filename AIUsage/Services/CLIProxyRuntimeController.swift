import Combine
import Darwin
import Foundation
import os.log
import QuotaBackend

private let cliProxyRuntimeLog = Logger(subsystem: "com.aiusage.desktop", category: "CLIProxyRuntime")

@MainActor
final class CLIProxyRuntimeController: ObservableObject {
    static let shared: CLIProxyRuntimeController = {
        do { return try CLIProxyRuntimeController(paths: CLIProxyPaths()) }
        catch { preconditionFailure("CLIProxyAPI runtime storage is unavailable: \(error.localizedDescription)") }
    }()

    @Published private(set) var state: CLIProxyRuntimeState = .stopped {
        didSet {
            updateActivityAssertion()
        }
    }
    @Published private(set) var recentLogs: [String] = []
    /// 客户端密钥曾变更且用户尚未重新复制/确认时为 true。
    @Published private(set) var clientKeyNeedsRecopy = false
    @Published private(set) var isLifecycleBusy = false
    @Published var settings: CLIProxyGatewaySettings {
        didSet {
            guard !isLoadingSettings else { return }
            // Preserve the original bound endpoint before any direct settings edit
            // changes the configured port/bindHost out from under an active or transitioning listener.
            if unconfirmedFence == nil,
               boundListenerEndpoint == nil,
               state.isRunning || state.isTransitioning || process != nil || adoptedPID != nil {
                let oldNormalized = oldValue.normalized
                let runningPID: Int32? = {
                    if case .running(let pid) = state { return pid }
                    return nil
                }()
                boundListenerEndpoint = ListenerEndpoint(
                    pid: process?.processIdentifier ?? adoptedPID ?? runningPID,
                    port: oldNormalized.port,
                    bindHost: oldNormalized.bindHost
                )
            }
            do { try configStore.saveSettings(settings) }
            catch { state = .failed(error.localizedDescription) }
        }
    }

    private static let clientKeyFingerprintDefaultsKey = "cliproxy.gateway.client-key-fingerprint.v1"
    private static let clientKeyAcknowledgedDefaultsKey = "cliproxy.gateway.client-key-ack.v1"

    nonisolated static let currentIsolationProfile = "api-key-only-v1"
    // shortcut: hold the bundled sidecar until a verified binary rejects file/OAuth auth on every load.
    nonisolated static let managedRuntimeAvailable = false
    nonisolated static let managedRuntimeHoldMessage = "Managed CPA is paused for account safety. Native account monitoring and separate API-key routes are unaffected."

    #if AIUSAGE_CPA_ISOLATION_FIXTURE
    var allowIsolatedFixtureLaunch = false
    #endif

    private var canLaunchManagedRuntime: Bool {
        #if AIUSAGE_CPA_ISOLATION_FIXTURE
        if allowIsolatedFixtureLaunch { return true }
        #endif
        return Self.managedRuntimeAvailable
    }

    private struct PIDRecord: Codable {
        let pid: Int32
        let binaryPath: String
        let configPath: String
        let configSHA256: String?
        let port: Int?
        let bindHost: String?
        let isolationProfile: String?
        let runtimeAuthDir: String?
        let workingDirectory: String?

        init(
            pid: Int32,
            binaryPath: String,
            configPath: String,
            configSHA256: String?,
            port: Int?,
            bindHost: String?,
            isolationProfile: String? = nil,
            runtimeAuthDir: String? = nil,
            workingDirectory: String? = nil
        ) {
            self.pid = pid
            self.binaryPath = binaryPath
            self.configPath = configPath
            self.configSHA256 = configSHA256
            self.port = port
            self.bindHost = bindHost
            self.isolationProfile = isolationProfile
            self.runtimeAuthDir = runtimeAuthDir
            self.workingDirectory = workingDirectory
        }
    }

    private struct ListenerEndpoint: Codable, Equatable {
        var pid: Int32?
        let port: Int
        let bindHost: String
    }

    private enum UnconfirmedFence: Equatable {
        case endpoint(ListenerEndpoint)
        case sharedLiveSibling(pid: Int32, port: Int?, bindHost: String?)
        case unreadableRecord(path: String)
    }

    private enum PersistedFenceReadResult: Equatable {
        case missing
        case valid(ListenerEndpoint)
        case unreadable
    }

    private enum PersistedFenceMutationResult: Equatable {
        case applied
        case unreadable
        case mismatched(ListenerEndpoint)
        case ioFailure(String)
    }

    private var unconfirmedEndpoint: ListenerEndpoint? {
        if case .endpoint(let endpoint) = unconfirmedFence { return endpoint }
        return nil
    }

    var hasUnconfirmedListener: Bool { unconfirmedFence != nil }

    var unconfirmedListenerMessage: String? {
        guard let unconfirmedFence else { return nil }
        switch unconfirmedFence {
        case .endpoint(let endpoint):
            if let pid = endpoint.pid {
                return "Containment unconfirmed: previous CPA listener pid=\(pid) on port \(endpoint.port) must be stopped and verified before continuing."
            }
            return "Containment unconfirmed: original CPA listener port \(endpoint.port) remains occupied and must be released before continuing."
        case .sharedLiveSibling(let pid, let port, _):
            let portSuffix = port.map { " on port \($0)" } ?? ""
            return "Containment unconfirmed: live sibling AIUsage instance owns CPA listener pid=\(pid)\(portSuffix); stop it before changing or replacing the shared runtime."
        case .unreadableRecord(let path):
            return "Containment unconfirmed: unresolved CPA stop marker at \(path) is unreadable and the original listener endpoint is unknown. Stop any running CPA process and remove the corrupt marker only after verifying no old CPA listener remains active."
        }
    }

    private let paths: CLIProxyPaths
    private let binaryStore: CLIProxyBinaryStore
    private let configStore: CLIProxyConfigStore
    private let secretStore: CLIProxySecretStore
    private let clientKeyStore: CLIProxyClientKeyStore
    private var cachedSecrets: CLIProxySecrets?
    private var process: Process?
    private var adoptedPID: Int32?
    private var boundListenerEndpoint: ListenerEndpoint?
    private var unconfirmedFence: UnconfirmedFence?
    private var shouldBeRunning = false
    private var restartAttempts = 0
    private var isLoadingSettings = true
    private var lifecycleWaiters: [CheckedContinuation<Void, Never>] = []
    private var autoRecoveryTask: Task<Void, Never>?
    private var isInsideActivationTransaction = false
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var pendingProcessLogs: [String] = []
    private var logFlushTask: Task<Void, Never>?
    private var sharedRuntimeLockDepth = 0
    private var runningActivity: NSObjectProtocol?

    private func updateActivityAssertion() {
        if state.isRunning {
            if runningActivity == nil {
                runningActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "CLIProxyAPI Gateway 24/7"
                )
            }
        } else {
            if let activity = runningActivity {
                ProcessInfo.processInfo.endActivity(activity)
                runningActivity = nil
            }
        }
    }

    private var pidURL: URL { paths.root.appendingPathComponent("runtime.pid.json") }
    private var unconfirmedListenerURL: URL { paths.root.appendingPathComponent("runtime.unconfirmed.json") }
    private var sharedRuntimeLockURL: URL { paths.root.appendingPathComponent("runtime.fence.lock") }
    var baseURL: URL { URL(string: "http://127.0.0.1:\(settings.normalized.port)")! }
    var detectedLANBaseURLs: [URL] {
        detectedLANBaseURLs(port: settings.normalized.port)
    }
    func detectedLANBaseURLs(port: Int) -> [URL] {
        Self.activePrivateIPv4Addresses().compactMap {
            URL(string: "http://\($0):\(port)")
        }
    }
    var lanBaseURLs: [URL] {
        guard settings.normalized.allowLANAccess else { return [] }
        return detectedLANBaseURLs
    }
    var clientAPIKey: String? { cachedSecrets?.clientAPIKey }
    var managementKey: String? { cachedSecrets?.managementKey }

    /// Credential for clients of the CPA process that is actually running.
    /// Prefer this bundle's Keychain key when the loaded config contains it;
    /// otherwise use the managed key from that config. Production and Debug
    /// intentionally use separate Keychain vaults but can observe one shared
    /// CPA runtime, so the Keychain value alone is not authoritative here.
    var managedProviderClientAPIKey: String? {
        let configured: [String]?
        do {
            configured = try configStore.runtimeClientAPIKeys()
        } catch {
            // An unfamiliar shared config must not be overwritten from this
            // bundle's isolated Keychain. Leave the provider unchanged until
            // the runtime config can be read without guessing.
            return nil
        }
        guard let configured else { return cachedSecrets?.clientAPIKey }
        guard !configured.isEmpty else { return nil }
        if let managed = CLIProxyManagedAPIKeyNamespace.ownedKey(
            in: configured,
            preferred: cachedSecrets?.clientAPIKey
        ) { return managed }
        // Never redistribute an arbitrary external key merely because it is
        // first in a shared CPA config. Without a recognizable AIUsage-owned
        // credential there is no safe automatic repair target.
        return nil
    }

    /// 用于 UI 展示的短指纹（末 4 位），避免整钥暴露。
    var clientAPIKeyFingerprint: String? {
        guard let key = cachedSecrets?.clientAPIKey, key.count >= 4 else { return nil }
        return String(key.suffix(4))
    }

    func acknowledgeClientKeyCopied() {
        guard let fingerprint = Self.fingerprint(for: cachedSecrets?.clientAPIKey) else { return }
        UserDefaults.standard.set(fingerprint, forKey: Self.clientKeyAcknowledgedDefaultsKey)
        clientKeyNeedsRecopy = false
    }

    init(
        paths: CLIProxyPaths,
        binaryStore: CLIProxyBinaryStore? = nil,
        configStore: CLIProxyConfigStore? = nil,
        secretStore: CLIProxySecretStore = CLIProxySecretStore()
    ) throws {
        let resolvedConfigStore = configStore ?? CLIProxyConfigStore(paths: paths)
        self.paths = paths
        self.binaryStore = binaryStore ?? CLIProxyBinaryStore(paths: paths)
        self.configStore = resolvedConfigStore
        self.secretStore = secretStore
        self.clientKeyStore = CLIProxyClientKeyStore(secretStore: secretStore)
        let loaded = resolvedConfigStore.loadSettingsWithMigrationState()
        self.settings = loaded.settings
        self.cachedSecrets = secretStore.load()
        try paths.prepare()
        if loaded.migratedFromLegacyV1 {
            try? resolvedConfigStore.saveSettings(loaded.settings)
        }
        reapOwnedOrphanIfNeeded()
        reapStaleManagedListenerIfNeeded(port: settings.normalized.port)
        restorePersistedListenerFenceIfNeeded()
        isLoadingSettings = false
        refreshClientKeyRotationState()
    }

    func loadClientKeyEntries() throws -> [CLIProxyClientKeyEntry] {
        guard canLaunchManagedRuntime else { return [] }
        return try clientKeyStore.loadEntries()
    }

    /// 密钥变更后重写 config；若 CPA 在跑则重启，并确认进程回到 running。
    /// Keychain 侧已由调用方先写入；此处失败会抛错，避免 UI 把「未生效」当成成功。
    func applyClientKeyChanges() async throws {
        guard canLaunchManagedRuntime else { throw CLIProxyGatewayError.process(Self.managedRuntimeHoldMessage) }
        if isLifecycleBusy || state.isTransitioning {
            throw CLIProxyGatewayError.process(
                "CPA runtime is currently transitioning; wait for it to settle before applying client keys."
            )
        }
        try withSharedRuntimeFenceLock {
            if let fence = unresolvedListenerFenceMessageLocked(
                forTargetPort: nil,
                targetHost: nil,
                allowSamePortAdoption: false
            ) {
                state = .failed(fence)
                appendLog("[AIUsage] \(fence)")
                throw CLIProxyGatewayError.process(fence)
            }
            _ = try writeManagedConfiguration()
        }
        guard state.isRunning else { return }
        await restart()
        switch state {
        case .running:
            return
        case .failed(let message):
            throw CLIProxyGatewayError.process(
                "Client keys were saved, but CPA failed to restart: \(message)"
            )
        case .stopped, .starting, .stopping:
            throw CLIProxyGatewayError.process(
                "Client keys were saved, but CPA is not running after restart."
            )
        }
    }

    private func withLifecycleLock<T>(_ operation: () async throws -> T) async rethrows -> T {
        while isLifecycleBusy {
            await withCheckedContinuation { continuation in
                lifecycleWaiters.append(continuation)
            }
        }
        isLifecycleBusy = true
        defer { releaseLifecycleLock() }
        return try await operation()
    }

    private func releaseLifecycleLock() {
        isLifecycleBusy = false
        if !lifecycleWaiters.isEmpty {
            let next = lifecycleWaiters.removeFirst()
            next.resume()
        }
    }

    func start(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) async {
        guard !isLifecycleBusy, !state.isRunning, !state.isTransitioning else { return }
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        await withLifecycleLock {
            guard !state.isRunning, !state.isTransitioning else { return }
            let normalized = settings.normalized
            if let message = unresolvedListenerFenceMessage(
                forTargetPort: normalized.port,
                targetHost: normalized.bindHost,
                allowSamePortAdoption: canLaunchManagedRuntime,
                portAvailableCheck: portAvailableCheck,
                ownershipEvaluator: ownershipEvaluator
            ) {
                state = .failed(message)
                appendLog("[AIUsage] \(message)")
                return
            }
            shouldBeRunning = true
            restartAttempts = 0
            await startOnce(
                portAvailableCheck: portAvailableCheck,
                ownershipEvaluator: ownershipEvaluator
            )
        }
    }

    func startIfConfigured() async {
        guard settings.autoStart else { return }
        await start()
    }

    @discardableResult
    func stop(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil,
        isAliveCheck: ((Int32) -> Bool)? = nil,
        pidTerminator: ((Int32) -> Void)? = nil
    ) async -> Bool {
        shouldBeRunning = false
        restartAttempts = 0
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        return await withLifecycleLock {
            await stopOwnedProcess(
                portAvailableCheck: portAvailableCheck,
                ownershipEvaluator: ownershipEvaluator,
                isAliveCheck: isAliveCheck,
                pidTerminator: pidTerminator
            )
        }
    }

    func restart() async {
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        await withLifecycleLock {
            shouldBeRunning = true
            restartAttempts = 0
            guard await stopOwnedProcess() else { return }
            await startOnce()
        }
    }

    /// 返回 true 表示本次应用触发了 CPA 进程重启。
    @discardableResult
    func applySettings(_ value: CLIProxyGatewaySettings) async -> Bool {
        let previous = settings.normalized
        let next = value.normalized
        settings = next
        let needsProcessRestart = state.isRunning && previous.requiresCPAProcessRestart(comparedTo: next)
        if needsProcessRestart {
            await restart()
            return true
        }
        if state.isRunning, !isLifecycleBusy, previous != next {
            // 仅应用侧字段变化：重写 config 以便下次启动一致，不打断进程。
            _ = try? writeManagedConfiguration(settings: next)
        }
        return false
    }

    /// Persist and stabilize the managed config before `current` can move to a
    /// different binary version. This is required even while CPA is stopped:
    /// cleanup may otherwise delete an old version directory that still owns a
    /// relative plugin directory before the next launch can migrate it.
    private func stabilizeConfigurationBeforeActivation() throws {
        if !isInsideActivationTransaction {
            if isLifecycleBusy || state.isTransitioning {
                throw CLIProxyGatewayError.process(
                    "CPA runtime is currently transitioning; wait for it to settle before changing configuration."
                )
            }
        }
        try withSharedRuntimeFenceLock {
            if let fence = unresolvedListenerFenceMessageLocked(
                forTargetPort: nil,
                targetHost: nil,
                allowSamePortAdoption: false
            ) {
                if isInsideActivationTransaction {
                    state = .failed(fence)
                    appendLog("[AIUsage] \(fence)")
                }
                throw CLIProxyGatewayError.process(fence)
            }
            _ = try writeManagedConfiguration()
        }
    }

    @discardableResult
    func performVersionActivation(
        version: String,
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil,
        isAliveCheck: ((Int32) -> Bool)? = nil,
        pidTerminator: ((Int32) -> Void)? = nil,
        switchVersion: () async throws -> Void,
        rollbackVersion: () async throws -> Void
    ) async throws -> Bool {
        guard canLaunchManagedRuntime else { throw CLIProxyGatewayError.process(Self.managedRuntimeHoldMessage) }
        if isLifecycleBusy || state.isTransitioning {
            throw CLIProxyGatewayError.process(
                "CPA runtime is currently transitioning; wait for it to settle before activating version \(version)."
            )
        }
        if let fence = unresolvedListenerFenceMessage(
            forTargetPort: nil,
            targetHost: nil,
            allowSamePortAdoption: false,
            portAvailableCheck: portAvailableCheck,
            ownershipEvaluator: ownershipEvaluator
        ) {
            state = .failed(fence)
            appendLog("[AIUsage] \(fence)")
            throw CLIProxyGatewayError.process(fence)
        }

        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil

        isLifecycleBusy = true
        isInsideActivationTransaction = true
        defer {
            isInsideActivationTransaction = false
            releaseLifecycleLock()
        }

        let wasRunning = state.isRunning
        if wasRunning || process != nil || adoptedPID != nil || boundListenerEndpoint != nil {
            shouldBeRunning = false
            restartAttempts = 0
            let stopped = await stopOwnedProcess(
                portAvailableCheck: portAvailableCheck,
                ownershipEvaluator: ownershipEvaluator,
                isAliveCheck: isAliveCheck,
                pidTerminator: pidTerminator
            )
            guard stopped else {
                let reason: String
                if case .failed(let message) = state {
                    reason = message
                } else {
                    reason = "CPA listener stop could not be confirmed before activating version \(version)."
                }
                throw CLIProxyGatewayError.process(reason)
            }
        }

        if let postStopFence = unresolvedListenerFenceMessage(
            forTargetPort: nil,
            targetHost: nil,
            allowSamePortAdoption: false,
            portAvailableCheck: portAvailableCheck,
            ownershipEvaluator: ownershipEvaluator
        ) {
            state = .failed(postStopFence)
            appendLog("[AIUsage] \(postStopFence)")
            throw CLIProxyGatewayError.process(postStopFence)
        }
        guard !state.isRunning, !state.isTransitioning, !hasUnconfirmedListener else {
            throw CLIProxyGatewayError.process(
                "CPA runtime is not confirmed stopped before activating version \(version)."
            )
        }

        var switchCommitted = false
        do {
            try stabilizeConfigurationBeforeActivation()
            try await switchVersion()
            switchCommitted = true
            if let postSwitchFence = try withSharedRuntimeFenceLock({
                unresolvedListenerFenceMessageLocked(
                    forTargetPort: nil,
                    targetHost: nil,
                    allowSamePortAdoption: false,
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                )
            }) {
                state = .failed(postSwitchFence)
                appendLog("[AIUsage] \(postSwitchFence)")
                throw CLIProxyGatewayError.process(postSwitchFence)
            }
            if wasRunning {
                shouldBeRunning = true
                restartAttempts = 0
                await startOnce(
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                )
                if case .failed(let reason) = state {
                    throw CLIProxyGatewayError.process(reason)
                }
                guard state.isRunning else {
                    throw CLIProxyGatewayError.process(
                        "CPA did not return to running after activating version \(version)."
                    )
                }
            }
            return wasRunning
        } catch {
            let canRollback: Bool = (try? withSharedRuntimeFenceLock {
                if let fence = unresolvedListenerFenceMessageLocked(
                    forTargetPort: nil,
                    targetHost: nil,
                    allowSamePortAdoption: false,
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                ) {
                    state = .failed(fence)
                    appendLog("[AIUsage] \(fence)")
                    return false
                }
                return !hasUnconfirmedListener
            }) ?? false
            if switchCommitted && canRollback {
                do {
                    try await rollbackVersion()
                    if wasRunning {
                        shouldBeRunning = true
                        restartAttempts = 0
                        await startOnce(
                            portAvailableCheck: portAvailableCheck,
                            ownershipEvaluator: ownershipEvaluator
                        )
                    }
                } catch let rollbackError {
                    let message = rollbackError.localizedDescription
                    state = .failed(message)
                    appendLog("[AIUsage] Rollback skipped: \(message)")
                }
            }
            throw error
        }
    }

    func stopSynchronouslyForTermination(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil,
        isAliveCheck: ((Int32) -> Bool)? = nil
    ) {
        shouldBeRunning = false
        autoRecoveryTask?.cancel()
        autoRecoveryTask = nil
        finishPendingProcessLogs()
        if let process, process.isRunning {
            process.terminationHandler = nil
            process.terminate()
            let deadline = Date().addingTimeInterval(1.5)
            while process.isRunning, Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            }
            if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
            self.process = nil
        }
        try? withSharedRuntimeFenceLock {
            let persistedRead = readUnconfirmedListenerFile()
            let preserveUnreadableMarker: Bool = {
                if persistedRead == .unreadable { return true }
                if case .unreadableRecord = unconfirmedFence { return true }
                return false
            }()
            let cachedUnconfirmed = unconfirmedEndpoint
            let diskUnconfirmed: ListenerEndpoint? = {
                if case .valid(let ep) = persistedRead { return ep }
                return nil
            }()
            let persistedMatchesCached: Bool = {
                guard let diskUnconfirmed, let cachedUnconfirmed else { return true }
                return Self.persistedRecordMatchesVerifiedEndpoint(diskUnconfirmed, verified: cachedUnconfirmed)
            }()
            let checkedUnconfirmed = cachedUnconfirmed ?? diskUnconfirmed
            let oldUnconfirmedPort = checkedUnconfirmed?.port ?? boundListenerEndpoint?.port
            self.process = nil
            self.adoptedPID = nil
            self.boundListenerEndpoint = nil
            self.unconfirmedFence = nil
            // Xcode 强杀 / 未挂上 Process 句柄时，仍按 pid 文件 + 端口回收本机托管 CPA。
            reapOwnedOrphanIfNeeded(ownershipEvaluator: ownershipEvaluator)
            reapStaleManagedListenerIfNeeded(port: settings.normalized.port, ownershipEvaluator: ownershipEvaluator)
            if let oldUnconfirmedPort, oldUnconfirmedPort != settings.normalized.port {
                reapStaleManagedListenerIfNeeded(port: oldUnconfirmedPort, ownershipEvaluator: ownershipEvaluator)
            }
            if preserveUnreadableMarker {
                // Never erase or substitute an unreadable marker with the current configured port across quit.
            } else if !persistedMatchesCached {
                // Preserve a newer valid shared stop record on disk when this controller only cached an older endpoint.
            } else if let endpoint = checkedUnconfirmed {
                let checkPort = portAvailableCheck ?? { port, host in Self.isListenerPortFree(port, bindHost: host) }
                let portStillBusy = !checkPort(endpoint.port, endpoint.bindHost)
                let pidStillAlive = Self.isEndpointPIDStillActive(
                    endpoint.pid,
                    paths: paths,
                    pidURL: pidURL,
                    portStillBusy: portStillBusy,
                    ownershipEvaluator: ownershipEvaluator,
                    isAliveCheck: isAliveCheck
                )
                if pidStillAlive || portStillBusy {
                    let retained = ListenerEndpoint(
                        pid: pidStillAlive ? endpoint.pid : nil,
                        port: endpoint.port,
                        bindHost: endpoint.bindHost
                    )
                    _ = writeUnconfirmedListenerRecord(retained, replacing: endpoint)
                } else {
                    _ = clearUnconfirmedListenerRecord(matching: endpoint)
                }
            }
        }
        state = .stopped
    }

    func runningPortOwner() -> ProxyPortArbiter.Owner? {
        guard state.isRunning else { return nil }
        return ProxyPortArbiter.Owner(
            id: "cliproxyapi-gateway",
            ports: [settings.normalized.port],
            track: "CLIProxyAPI",
            label: L("CPA Gateway", "CPA 网关")
        )
    }

    nonisolated struct AdoptedListenerVerification: Equatable, Sendable {
        let isSafeToAdopt: Bool
        let pid: Int32
        let reason: String?
        let configSHA256: String?

        init(
            isSafeToAdopt: Bool,
            pid: Int32,
            reason: String?,
            configSHA256: String? = nil
        ) {
            self.isSafeToAdopt = isSafeToAdopt
            self.pid = pid
            self.reason = reason
            self.configSHA256 = configSHA256
        }
    }

    nonisolated enum PIDOwnership: Equatable, Sendable {
        case notAlive
        case owned(pid: Int32)
        case liveSibling(pid: Int32)
        case unowned(pid: Int32, reason: String)
    }

    nonisolated private static let ephemeralLoopbackSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    /// Builds a strict allowlisted environment for the CPA child process so ambient
    /// parent variables (`HOME_JWT`, `PGSTORE_*`, `GITSTORE_*`, `OBJECTSTORE_*`,
    /// `DEPLOY`, `WRITABLE_PATH`, `MANAGEMENT_PASSWORD`, `HTTP_PROXY`, etc.) never
    /// redirect CPA away from AIUsage's controlled runtime configuration and empty auth dir.
    nonisolated static func buildIsolatedChildEnvironment(
        paths: CLIProxyPaths,
        parentEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": paths.runtimeWorkingDirectory.path,
            "TMPDIR": paths.runtimeTempDirectory.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8"
        ]
        if let tz = parentEnvironment["TZ"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !tz.isEmpty {
            env["TZ"] = tz
        }
        return env
    }

    /// Fail closed unless CPA's isolated runtime auth and working directories exist as real
    /// non-symlink directories containing zero entries (including dotfiles such as `.env` or
    /// hidden auth JSON files). Legacy credentials in `paths.authDirectory` are never read,
    /// edited, or deleted.
    nonisolated static func verifyIsolatedAPIOnlyRuntimeDirectories(
        paths: CLIProxyPaths,
        fileManager: FileManager = .default
    ) throws {
        try paths.prepare(fileManager: fileManager)
        for directory in [
            paths.root,
            paths.isolatedAuthDirectory,
            paths.runtimeWorkingDirectory,
            paths.runtimeTempDirectory
        ] {
            var st = stat()
            guard lstat(directory.standardizedFileURL.path, &st) == 0,
                  (st.st_mode & S_IFMT) == S_IFDIR else {
                throw CLIProxyGatewayError.configuration(
                    "Refusing to start CPA: runtime path '\(directory.lastPathComponent)' is missing or not a real directory."
                )
            }
        }
        for emptyRequired in [paths.isolatedAuthDirectory, paths.runtimeWorkingDirectory] {
            let contents = try fileManager.contentsOfDirectory(
                at: emptyRequired.standardizedFileURL,
                includingPropertiesForKeys: nil,
                options: []
            )
            guard contents.isEmpty else {
                let sample = contents.prefix(3).map(\.lastPathComponent).sorted().joined(separator: ", ")
                throw CLIProxyGatewayError.configuration(
                    "Refusing to start CPA: isolated '\(emptyRequired.lastPathComponent)' is not empty (\(sample)); remove unexpected files without touching legacy credentials in auth/."
                )
            }
        }
    }

    /// Validates a managed `aiusage-*.json` auth file in `authDirectory`, returning a human-readable
    /// rejection reason if ownership/provider markers are invalid, credential is excluded, Antigravity is suspended,
    /// per-credential retry/cooling overrides violate policy, or Codex account plan is outside `allowedCodexPlans`.
    nonisolated static func managedAuthRejectionReason(
        named name: String,
        in authDirectory: URL,
        excludedCredentialIDs: Set<String> = [],
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys,
        allowLocalDisabledFlag: Bool = false
    ) -> String? {
        guard (try? CLIProxyManagementClient.validateAuthFileName(name)) != nil else {
            return "invalid auth filename"
        }
        let standardDir = authDirectory.standardizedFileURL
        let fileURL = standardDir.appendingPathComponent(name).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == standardDir else {
            return "path outside auth directory"
        }
        var st = stat()
        guard lstat(fileURL.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: fileURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "unreadable or missing managed auth file"
        }

        let tokens = (object["tokens"] as? [String: Any]) ?? (object["token"] as? [String: Any])
        let rawCredID = ((object["aiusage_credential_id"] as? String)
            ?? (tokens?["aiusage_credential_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !rawCredID.isEmpty else {
            return "missing aiusage_credential_id marker"
        }
        let normalizedExcluded = Set(
            excludedCredentialIDs
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                .filter { !$0.isEmpty }
        )
        if normalizedExcluded.contains(rawCredID) {
            return "credential is paused or deleted"
        }

        let diskProviders = CLIProxyCapabilityMatrix.normalizedProviderIDs(from: [
            object["type"] as? String,
            object["provider"] as? String
        ])
        guard !diskProviders.isEmpty else {
            return "missing provider/type marker"
        }
        if let reason = CLIProxyCapabilityMatrix.disallowedProviderRejectionReason(
            rawProviders: [object["type"] as? String, object["provider"] as? String],
            disallowedProviderIDs: disallowedProviderIDs,
            sourceContext: "provider/type"
        ) {
            return reason
        }
        if let overrideReason = CLIProxyCapabilityMatrix.disallowedPerCredentialRetryOverrideReason(in: object) {
            return overrideReason
        }

        if diskProviders.contains("antigravity"),
           let suspension = AntigravityAccountProtection.suspension(in: data) {
            if !allowLocalDisabledFlag || suspension.code == "tos_violation" {
                return suspension.message
            }
        }
        if diskProviders.contains("codex"), !allowedCodexPlans.isEmpty,
           let planRejection = CLIProxyCapabilityMatrix.codexPlanVerification(
               fromJSONObject: object,
               allowedPlans: allowedCodexPlans,
               trustedKeys: trustedCodexIssuerKeys
           ).rejectionReason {
            return planRejection
        }
        return nil
    }

    nonisolated private static func runtimeIdentityConflictReason(
        file: CLIProxyAuthFile,
        diskData: Data,
        providerHint: String?
    ) -> String? {
        guard let diskIdentity = try? CLIProxyAccountIdentity.parse(data: diskData, providerHint: providerHint) else {
            return "auth file on disk lacks a parseable account identity"
        }
        if let runtimeAccount = file.account?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !runtimeAccount.isEmpty,
           let diskAccount = diskIdentity.accountID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !diskAccount.isEmpty,
           runtimeAccount != diskAccount {
            return "runtime account identity does not match auth file on disk"
        }
        if let runtimeEmail = file.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           runtimeEmail.contains("@"),
           let diskEmail = diskIdentity.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           diskEmail.contains("@"),
           runtimeEmail != diskEmail {
            return "runtime email does not match auth file on disk"
        }
        return nil
    }

    nonisolated static func reEnableRejectionReason(
        for file: CLIProxyAuthFile,
        in authDirectory: URL,
        excludedCredentialIDs: Set<String>,
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys,
        allowLocalDisabledFlag: Bool = true
    ) -> String? {
        guard !file.isOpenAICompatibleRuntime else { return nil }
        if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild && trustedCodexIssuerKeys.isEmpty {
            return CLIProxyCapabilityMatrix.subscriptionsUnavailableMessage
        }
        if let reason = CLIProxyCapabilityMatrix.disallowedProviderRejectionReason(
            rawProviders: [file.provider, file.type],
            disallowedProviderIDs: disallowedProviderIDs,
            sourceContext: "provider/type"
        ) {
            return reason
        }
        if file.name.lowercased().hasPrefix("aiusage-") {
            if file.runtimeOnly {
                return "managed auth file cannot be runtime-only"
            }
            if let managedReason = managedAuthRejectionReason(
                named: file.name,
                in: authDirectory,
                excludedCredentialIDs: excludedCredentialIDs,
                disallowedProviderIDs: disallowedProviderIDs,
                allowedCodexPlans: allowedCodexPlans,
                trustedCodexIssuerKeys: trustedCodexIssuerKeys,
                allowLocalDisabledFlag: allowLocalDisabledFlag
            ) {
                return managedReason
            }
            let diskURL = authDirectory.standardizedFileURL.appendingPathComponent(file.name).standardizedFileURL
            let providerHint = CLIProxyCapabilityMatrix.normalizedProviderIDs(from: [file.provider, file.type]).first
            if let diskData = try? Data(contentsOf: diskURL),
               let conflict = runtimeIdentityConflictReason(file: file, diskData: diskData, providerHint: providerHint) {
                return conflict
            }
            return nil
        }
        let runtimeProviders = CLIProxyCapabilityMatrix.normalizedProviderIDs(from: [file.provider, file.type])
        if file.runtimeOnly {
            if runtimeProviders.contains("codex"), !allowedCodexPlans.isEmpty {
                return "runtime-only Codex account plan cannot be verified on disk (only ChatGPT Go and ChatGPT Free accounts are allowed)"
            }
            return "runtime-only auth file cannot be verified on disk"
        }
        guard (try? CLIProxyManagementClient.validateAuthFileName(file.name)) != nil else {
            return "invalid auth filename"
        }
        let standardDir = authDirectory.standardizedFileURL
        let fileURL = standardDir.appendingPathComponent(file.name).standardizedFileURL
        guard fileURL.deletingLastPathComponent() == standardDir else {
            return "path outside auth directory"
        }
        var st = stat()
        guard lstat(fileURL.path, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              let data = try? Data(contentsOf: fileURL),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return "unreadable or missing external auth file"
        }
        let diskProviders = CLIProxyCapabilityMatrix.normalizedProviderIDs(from: [
            object["provider"] as? String,
            object["type"] as? String
        ])
        guard !diskProviders.isEmpty else {
            return "missing provider/type marker on disk"
        }
        if !runtimeProviders.isEmpty, Set(runtimeProviders).isDisjoint(with: diskProviders) {
            return "runtime provider/type does not match auth file on disk"
        }
        if let reason = CLIProxyCapabilityMatrix.disallowedProviderRejectionReason(
            rawProviders: [object["provider"] as? String, object["type"] as? String],
            disallowedProviderIDs: disallowedProviderIDs,
            sourceContext: "provider/type on disk"
        ) {
            return reason
        }
        if let overrideReason = CLIProxyCapabilityMatrix.disallowedPerCredentialRetryOverrideReason(in: object) {
            return overrideReason
        }
        if diskProviders.contains("antigravity"),
           let suspension = AntigravityAccountProtection.suspension(in: data),
           (!allowLocalDisabledFlag || suspension.code == "tos_violation") {
            return suspension.message
        }
        if (diskProviders.contains("codex") || runtimeProviders.contains("codex")),
           !allowedCodexPlans.isEmpty,
           let planRejection = CLIProxyCapabilityMatrix.codexPlanVerification(
               fromJSONObject: object,
               allowedPlans: allowedCodexPlans,
               trustedKeys: trustedCodexIssuerKeys
           ).rejectionReason {
            return planRejection
        }
        if let conflict = runtimeIdentityConflictReason(file: file, diskData: data, providerHint: diskProviders.first) {
            return conflict
        }
        return nil
    }

    /// Recursively scans `authDirectory` (matching upstream CPA's `filepath.WalkDir` behavior)
    /// for `.json` auth files before launch, rejecting symlinks, disabling blocked/excluded
    /// managed `aiusage-*` files atomically (`0o600`), and failing closed on enabled disallowed,
    /// retry-overriding, or unverified external files.
    @discardableResult
    nonisolated static func sanitizeManagedAuthDirectory(
        authDirectory: URL,
        excludedCredentialIDs: Set<String>,
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys
    ) throws -> [String] {
        let standardDir = authDirectory.standardizedFileURL
        var rootStat = stat()
        if lstat(standardDir.path, &rootStat) != 0 {
            return []
        }
        guard (rootStat.st_mode & S_IFMT) == S_IFDIR else {
            throw CLIProxyGatewayError.configuration("Refusing to start CPA: auth directory is not a regular directory")
        }

        let basePathPrefix = standardDir.path.hasSuffix("/") ? standardDir.path : standardDir.path + "/"
        var pendingDirs: [URL] = [standardDir]
        var visitedDirIDs = Set<String>()
        var pendingDisables: [(relativeName: String, url: URL, object: [String: Any], reason: String)] = []

        while !pendingDirs.isEmpty {
            let currentDir = pendingDirs.removeFirst()
            var dirStat = stat()
            guard lstat(currentDir.path, &dirStat) == 0,
                  (dirStat.st_mode & S_IFMT) == S_IFDIR else {
                throw CLIProxyGatewayError.configuration(
                    "Refusing to start CPA: subdirectory '\(currentDir.lastPathComponent)' is not a regular directory"
                )
            }
            let dirID = "\(dirStat.st_dev):\(dirStat.st_ino)"
            guard visitedDirIDs.insert(dirID).inserted else { continue }

            let contents: [URL]
            do {
                // Do not skip hidden dotfiles: upstream CLIProxyAPI loads `.json` entries without `.skipsHiddenFiles`.
                contents = try FileManager.default.contentsOfDirectory(
                    at: currentDir,
                    includingPropertiesForKeys: nil,
                    options: []
                )
            } catch {
                throw CLIProxyGatewayError.configuration("Refusing to start CPA: unable to inspect auth directory (\(error.localizedDescription))")
            }

            for url in contents.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let name = url.lastPathComponent
                let standardEntry = url.standardizedFileURL
                guard standardEntry.deletingLastPathComponent() == currentDir else {
                    throw CLIProxyGatewayError.configuration("Refusing to start CPA: path outside auth directory (\(name))")
                }
                var entryStat = stat()
                guard lstat(standardEntry.path, &entryStat) == 0 else {
                    throw CLIProxyGatewayError.configuration("Refusing to start CPA: unreadable entry \(name)")
                }
                let entryType = entryStat.st_mode & S_IFMT
                if entryType == S_IFLNK {
                    throw CLIProxyGatewayError.configuration("Refusing to start CPA: symbolic link in auth directory (\(name))")
                }
                if entryType == S_IFDIR {
                    pendingDirs.append(standardEntry)
                    continue
                }
                guard name.lowercased().hasSuffix(".json") else {
                    continue
                }
                guard entryType == S_IFREG,
                      let data = try? Data(contentsOf: standardEntry),
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    throw CLIProxyGatewayError.configuration("Refusing to start CPA: unverified or unreadable auth file \(name)")
                }
                let relativeName = standardEntry.path.hasPrefix(basePathPrefix)
                    ? String(standardEntry.path.dropFirst(basePathPrefix.count))
                    : name

                guard object["disabled"] as? Bool != true else {
                    continue
                }

                if name.lowercased().hasPrefix("aiusage-") {
                    if let reason = managedAuthRejectionReason(
                        named: name,
                        in: currentDir,
                        excludedCredentialIDs: excludedCredentialIDs,
                        disallowedProviderIDs: disallowedProviderIDs,
                        allowedCodexPlans: allowedCodexPlans,
                        trustedCodexIssuerKeys: trustedCodexIssuerKeys,
                        allowLocalDisabledFlag: false
                    ) {
                        pendingDisables.append((relativeName: relativeName, url: standardEntry, object: object, reason: reason))
                    }
                } else if let externalReason = CLIProxyCapabilityMatrix.disallowedProviderRejectionReason(
                    rawProviders: [object["provider"] as? String, object["type"] as? String],
                    disallowedProviderIDs: disallowedProviderIDs,
                    sourceContext: "enabled external auth file \(relativeName) provider"
                ) {
                    throw CLIProxyGatewayError.configuration(
                        "Refusing to start CPA: enabled external auth file \(relativeName) rejected (\(externalReason))"
                    )
                } else if let overrideReason = CLIProxyCapabilityMatrix.disallowedPerCredentialRetryOverrideReason(in: object) {
                    throw CLIProxyGatewayError.configuration(
                        "Refusing to start CPA: enabled external auth file \(relativeName) rejected (\(overrideReason))"
                    )
                } else {
                    let externalProviders = CLIProxyCapabilityMatrix.normalizedProviderIDs(from: [
                        object["provider"] as? String,
                        object["type"] as? String
                    ])
                    guard !externalProviders.isEmpty else {
                        throw CLIProxyGatewayError.configuration(
                            "Refusing to start CPA: enabled external auth file \(relativeName) rejected (missing provider/type)"
                        )
                    }
                    if externalProviders.contains("codex"),
                       !allowedCodexPlans.isEmpty,
                       let planRejection = CLIProxyCapabilityMatrix.codexPlanVerification(
                           fromJSONObject: object,
                           allowedPlans: allowedCodexPlans,
                           trustedKeys: trustedCodexIssuerKeys
                       ).rejectionReason {
                        throw CLIProxyGatewayError.configuration(
                            "Refusing to start CPA: enabled external auth file \(relativeName) rejected (\(planRejection))"
                        )
                    }
                }
            }
        }

        var disabledFiles: [String] = []
        for item in pendingDisables {
            var object = item.object
            object["disabled"] = true
            do {
                let updated = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
                try updated.write(to: item.url, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: item.url.path)
                let verifiedData = try Data(contentsOf: item.url)
                let verifiedObject = (try? JSONSerialization.jsonObject(with: verifiedData)) as? [String: Any]
                let attrs = try FileManager.default.attributesOfItem(atPath: item.url.path)
                let mode = ((attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
                guard verifiedObject?["disabled"] as? Bool == true, mode == 0o600 else {
                    throw CLIProxyGatewayError.configuration(
                        "Failed to verify disabled state and 0600 permissions on disk for CPA auth file \(item.relativeName)"
                    )
                }
                disabledFiles.append(item.relativeName)
            } catch {
                throw CLIProxyGatewayError.configuration(
                    "Failed to disable blocked CPA auth file \(item.relativeName) (\(item.reason)): \(error.localizedDescription)"
                )
            }
        }
        return disabledFiles.sorted()
    }

    /// Verifies isolation and prepares configuration before launching CPA.
    /// In API-key-only builds (`subscriptionsEnabledInThisBuild == false` without test keys),
    /// validates empty `isolatedAuthDirectory` + `runtimeWorkingDirectory` while preserving
    /// legacy `paths.authDirectory` completely untouched outside runtime loaders.
    func prepareInventoryAndLaunch<T>(
        settings normalized: CLIProxyGatewaySettings,
        excludedCredentialIDs: Set<String>,
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys,
        configWriter: (CLIProxyGatewaySettings) throws -> CLIProxySecrets,
        launchProcess: (CLIProxySecrets) throws -> T
    ) throws -> (sanitizedFiles: [String], launched: T) {
        let sanitizedFiles: [String]
        if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild && trustedCodexIssuerKeys.isEmpty {
            try Self.verifyIsolatedAPIOnlyRuntimeDirectories(paths: paths)
            sanitizedFiles = []
        } else {
            sanitizedFiles = try Self.sanitizeManagedAuthDirectory(
                authDirectory: paths.authDirectory,
                excludedCredentialIDs: excludedCredentialIDs,
                disallowedProviderIDs: disallowedProviderIDs,
                allowedCodexPlans: allowedCodexPlans,
                trustedCodexIssuerKeys: trustedCodexIssuerKeys
            )
        }
        let secrets = try configWriter(normalized)
        let launched = try launchProcess(secrets)
        return (sanitizedFiles, launched)
    }

    /// Verifies that an already-listening local process is an AIUsage-managed CPA
    /// instance whose startup config hash, effective policy settings, live
    /// management inventory, and managed auth eligibility all match current requirements.
    func canAdoptRunningListener(
        settings normalized: CLIProxyGatewaySettings,
        secrets: CLIProxySecrets?,
        clientAPIKeys: [String]?,
        listeningPIDs: [Int32],
        excludedCredentialIDs: Set<String> = [],
        disallowedProviderIDs: Set<String> = CLIProxyCapabilityMatrix.defaultDisallowedProviderIDs,
        allowedCodexPlans: Set<String> = CLIProxyCapabilityMatrix.allowedCodexPlanTypes,
        trustedCodexIssuerKeys: [CLIProxyTrustedJWSKey] = CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys,
        processVerifier: ((Int32) -> Bool)? = nil,
        session: URLSession? = nil
    ) async -> AdoptedListenerVerification {
        guard canLaunchManagedRuntime else {
            return AdoptedListenerVerification(isSafeToAdopt: false, pid: 0, reason: Self.managedRuntimeHoldMessage)
        }
        let probeSession = session ?? Self.ephemeralLoopbackSession
        let probeBaseURL = URL(string: "http://127.0.0.1:\(normalized.port)")!
        let endpoint = probeBaseURL.appendingPathComponent("healthz")
        var request = URLRequest(url: endpoint, timeoutInterval: 1.0)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (_, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return AdoptedListenerVerification(isSafeToAdopt: false, pid: 0, reason: "Existing listener failed health check")
        }

        let candidatePID = listeningPIDs.first ?? 0
        guard !listeningPIDs.isEmpty else {
            return AdoptedListenerVerification(
                isSafeToAdopt: false,
                pid: 0,
                reason: "Running listener PID on port \(normalized.port) could not be verified"
            )
        }
        let verifier = processVerifier ?? { [paths] pid in Self.isManagedCPAListenerProcess(pid, paths: paths) }
        guard listeningPIDs.allSatisfy(verifier) else {
            return AdoptedListenerVerification(
                isSafeToAdopt: false,
                pid: candidatePID,
                reason: "Listener on port \(normalized.port) is not a verified AIUsage-managed CPA process"
            )
        }

        guard let secrets,
              configStore.runtimeConfigMatches(settings: normalized, secrets: secrets, clientAPIKeys: clientAPIKeys) else {
            return AdoptedListenerVerification(
                isSafeToAdopt: false,
                pid: candidatePID,
                reason: "Running CPA listener configuration does not match current gateway safety policy"
            )
        }

        guard let currentDigest = configStore.runtimeConfigSHA256(),
              let pidData = FileManager.default.contents(atPath: pidURL.path),
              let record = try? JSONDecoder().decode(PIDRecord.self, from: pidData),
              listeningPIDs.contains(record.pid),
              record.configPath == paths.configURL.path,
              let launchedDigest = record.configSHA256,
              launchedDigest == currentDigest else {
            return AdoptedListenerVerification(
                isSafeToAdopt: false,
                pid: candidatePID,
                reason: "Running CPA listener startup config digest is missing or stale relative to current config"
            )
        }

        let expectsIsolatedProfile = !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
            && trustedCodexIssuerKeys.isEmpty
        if expectsIsolatedProfile {
            guard record.isolationProfile == Self.currentIsolationProfile,
                  record.runtimeAuthDir == paths.isolatedAuthDirectory.path,
                  record.workingDirectory == paths.runtimeWorkingDirectory.path else {
                return AdoptedListenerVerification(
                    isSafeToAdopt: false,
                    pid: candidatePID,
                    reason: "Running CPA listener isolation profile or runtime auth/working directory cannot be verified"
                )
            }
            do {
                try Self.verifyIsolatedAPIOnlyRuntimeDirectories(paths: paths)
            } catch {
                return AdoptedListenerVerification(
                    isSafeToAdopt: false,
                    pid: candidatePID,
                    reason: error.localizedDescription
                )
            }
        }

        let client = CLIProxyManagementClient(
            baseURL: probeBaseURL,
            managementKey: secrets.managementKey,
            clientAPIKey: secrets.clientAPIKey,
            session: probeSession
        )
        let activeAuthDirectory = expectsIsolatedProfile ? paths.isolatedAuthDirectory : paths.authDirectory
        do {
            let files = try await client.listAuthFiles()
            if expectsIsolatedProfile,
               let unexpected = files.first(where: { !$0.isOpenAICompatibleRuntime }) {
                return AdoptedListenerVerification(
                    isSafeToAdopt: false,
                    pid: candidatePID,
                    reason: "Running API-key-only CPA listener contains non-API auth entry \(unexpected.name)"
                )
            }
            for file in files where !file.disabled && !file.isOpenAICompatibleRuntime {
                if let blockedReason = Self.reEnableRejectionReason(
                    for: file,
                    in: activeAuthDirectory,
                    excludedCredentialIDs: excludedCredentialIDs,
                    disallowedProviderIDs: disallowedProviderIDs,
                    allowedCodexPlans: allowedCodexPlans,
                    trustedCodexIssuerKeys: trustedCodexIssuerKeys,
                    allowLocalDisabledFlag: false
                ) {
                    return AdoptedListenerVerification(
                        isSafeToAdopt: false,
                        pid: candidatePID,
                        reason: "Running CPA listener contains blocked inventory row \(file.name): \(blockedReason)"
                    )
                }
            }
            return AdoptedListenerVerification(
                isSafeToAdopt: true,
                pid: record.pid,
                reason: nil,
                configSHA256: launchedDigest
            )
        } catch {
            return AdoptedListenerVerification(
                isSafeToAdopt: false,
                pid: candidatePID,
                reason: "Running CPA listener management inventory check failed: \(error.localizedDescription)"
            )
        }
    }

    nonisolated private static func isManagedCPAListenerProcess(_ pid: Int32, paths: CLIProxyPaths) -> Bool {
        guard pid > 1 else { return false }
        let path = processPath(pid) ?? ""
        let command = processCommand(pid)
        let looksLikeCPA = path.localizedCaseInsensitiveContains("cliproxy")
            || path.localizedCaseInsensitiveContains("CLIProxyAPI")
            || (path as NSString).lastPathComponent.localizedCaseInsensitiveContains("cliproxy")
        return looksLikeCPA && (command.contains(paths.configURL.path) || path.hasPrefix(paths.versionsDirectory.path + "/"))
    }

    private func startOnce(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) async {
        guard canLaunchManagedRuntime else {
            shouldBeRunning = false
            state = .failed(Self.managedRuntimeHoldMessage)
            return
        }
        let normalized = settings.normalized
        let preFlightFence = unresolvedListenerFenceMessage(
            forTargetPort: normalized.port,
            targetHost: normalized.bindHost,
            allowSamePortAdoption: true,
            portAvailableCheck: portAvailableCheck,
            ownershipEvaluator: ownershipEvaluator
        )
        if let message = preFlightFence {
            state = .failed(message)
            appendLog("[AIUsage] \(message)")
            return
        }
        state = .starting
        var launchedProcess: Process?
        do {
            guard let binaryURL = try await binaryStore.currentBinaryURL() else {
                throw CLIProxyGatewayError.notInstalled
            }
            if let postBinaryFence = try withSharedRuntimeFenceLock({
                unresolvedListenerFenceMessageLocked(
                    forTargetPort: normalized.port,
                    targetHost: normalized.bindHost,
                    allowSamePortAdoption: true,
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                )
            }) {
                throw CLIProxyGatewayError.process(postBinaryFence)
            }
            let excludedCredentialIDs = AccountStore.shared.excludedEngineAccountFilters().credentialIDs
            let checkPort = portAvailableCheck ?? { port, host in Self.isListenerPortFree(port, bindHost: host) }

            // Health-First: adopt an existing listener only after verifying CPA identity,
            // current policy config match, startup config digest, and compliant live inventory.
            if !checkPort(normalized.port, normalized.bindHost) {
                let existingPIDs = Self.pidsListening(on: normalized.port)
                let secrets = secretStore.load()
                let clientKeys = secrets.map { (try? clientKeyStore.enabledKeysForRuntime()) ?? [$0.clientAPIKey] }
                let preAdoptConfigDigest = configStore.runtimeConfigSHA256()
                let preAdoptPIDRecord: PIDRecord? = FileManager.default.contents(atPath: pidURL.path)
                    .flatMap { try? JSONDecoder().decode(PIDRecord.self, from: $0) }
                let verification = await canAdoptRunningListener(
                    settings: normalized,
                    secrets: secrets,
                    clientAPIKeys: clientKeys,
                    listeningPIDs: existingPIDs,
                    excludedCredentialIDs: excludedCredentialIDs
                )
                if verification.isSafeToAdopt {
                    try withSharedRuntimeFenceLock {
                        if let postAdoptionFence = unresolvedListenerFenceMessageLocked(
                            forTargetPort: normalized.port,
                            targetHost: normalized.bindHost,
                            allowSamePortAdoption: true,
                            portAvailableCheck: portAvailableCheck,
                            ownershipEvaluator: ownershipEvaluator
                        ) {
                            throw CLIProxyGatewayError.process(postAdoptionFence)
                        }
                        guard verification.pid > 1,
                              let pidData = FileManager.default.contents(atPath: pidURL.path),
                              let pidRecord = try? JSONDecoder().decode(PIDRecord.self, from: pidData),
                              pidRecord.configPath == paths.configURL.path else {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA PID record is missing or invalid during adoption commit for pid=\(verification.pid)."
                            )
                        }
                        guard pidRecord.pid == verification.pid else {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA listener PID on port \(normalized.port) changed from \(verification.pid) to \(pidRecord.pid) before adoption commit."
                            )
                        }
                        if let recordedPort = pidRecord.port, recordedPort != normalized.port {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA PID record port changed to \(recordedPort) (expected \(normalized.port)) before adoption commit."
                            )
                        }
                        if let recordedHost = pidRecord.bindHost, recordedHost != normalized.bindHost {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA PID record host changed to \(recordedHost) (expected \(normalized.bindHost)) before adoption commit."
                            )
                        }
                        guard let recordedDigest = pidRecord.configSHA256, !recordedDigest.isEmpty else {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA PID record config digest is missing during adoption commit."
                            )
                        }
                        if let expectedDigest = verification.configSHA256 ?? preAdoptPIDRecord?.configSHA256,
                           recordedDigest != expectedDigest {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA PID record config digest changed before adoption commit."
                            )
                        }
                        let currentConfigDigest = configStore.runtimeConfigSHA256()
                        if preAdoptConfigDigest != nil {
                            guard let currentConfigDigest, recordedDigest == currentConfigDigest else {
                                throw CLIProxyGatewayError.process(
                                    "Containment unconfirmed: running CPA config digest no longer matches current runtime configuration at adoption commit."
                                )
                            }
                        } else if let currentConfigDigest, recordedDigest != currentConfigDigest {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: running CPA config digest no longer matches current runtime configuration at adoption commit."
                            )
                        }
                        guard !checkPort(normalized.port, normalized.bindHost) else {
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: CPA listener port \(normalized.port) is no longer occupied at adoption commit."
                            )
                        }
                        if let ownershipEvaluator {
                            switch ownershipEvaluator(verification.pid) {
                            case .owned(let ownedPID) where ownedPID == verification.pid:
                                break
                            case .liveSibling(let siblingPID) where siblingPID == verification.pid:
                                break
                            case .notAlive, .unowned, .owned, .liveSibling:
                                throw CLIProxyGatewayError.process(
                                    "Containment unconfirmed: candidate CPA listener pid=\(verification.pid) is no longer an active verified owner on port \(normalized.port)."
                                )
                            }
                        } else if existingPIDs.contains(verification.pid) {
                            switch Self.pidOwnership(pid: verification.pid, paths: paths, pidURL: pidURL) {
                            case .owned(let ownedPID) where ownedPID == verification.pid:
                                break
                            case .liveSibling(let siblingPID) where siblingPID == verification.pid:
                                break
                            case .notAlive, .unowned, .owned, .liveSibling:
                                throw CLIProxyGatewayError.process(
                                    "Containment unconfirmed: candidate CPA listener pid=\(verification.pid) is no longer an active verified owner on port \(normalized.port)."
                                )
                            }
                        }
                        if existingPIDs.contains(verification.pid) {
                            let currentListeningPIDs = Self.pidsListening(on: normalized.port)
                            guard currentListeningPIDs.contains(verification.pid) else {
                                throw CLIProxyGatewayError.process(
                                    "Containment unconfirmed: candidate CPA listener pid=\(verification.pid) no longer owns port \(normalized.port)."
                                )
                            }
                        }
                        let adoptedEndpoint = ListenerEndpoint(
                            pid: verification.pid,
                            port: normalized.port,
                            bindHost: normalized.bindHost
                        )
                        switch clearUnconfirmedListenerRecordUnlocked(matching: adoptedEndpoint) {
                        case .applied:
                            break
                        case .unreadable:
                            unconfirmedFence = .unreadableRecord(path: unconfirmedListenerURL.path)
                            throw CLIProxyGatewayError.process(
                                unconfirmedListenerMessage
                                    ?? "Containment unconfirmed: unresolved CPA stop marker is unreadable and the original listener endpoint is unknown."
                            )
                        case .mismatched(let currentPersisted):
                            adoptedPID = currentPersisted.pid
                            boundListenerEndpoint = currentPersisted
                            unconfirmedFence = .endpoint(currentPersisted)
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: shared CPA stop record changed to \(currentPersisted.bindHost):\(currentPersisted.port); verify that the active listener on that endpoint stopped."
                            )
                        case .ioFailure(let reason):
                            throw CLIProxyGatewayError.process(
                                "Containment unconfirmed: failed to update shared CPA stop record (\(reason))."
                            )
                        }
                        cliProxyRuntimeLog.notice("CPA Gateway listener verified healthy and policy-matched on port \(normalized.port, privacy: .public); adopting pid=\(verification.pid, privacy: .public).")
                        self.process = nil
                        self.adoptedPID = verification.pid
                        self.boundListenerEndpoint = adoptedEndpoint
                        self.unconfirmedFence = nil
                        restartAttempts = 0
                        state = .running(pid: verification.pid)
                    }
                    return
                }
                if let reason = verification.reason {
                    cliProxyRuntimeLog.warning("Refusing unverified CPA listener adoption on port \(normalized.port, privacy: .public): \(reason, privacy: .public)")
                }
            }

            var launchSecrets: CLIProxySecrets?
            let process = try withSharedRuntimeFenceLock { () -> Process in
                if let launchFence = unresolvedListenerFenceMessageLocked(
                    forTargetPort: normalized.port,
                    targetHost: normalized.bindHost,
                    allowSamePortAdoption: false,
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                ) {
                    throw CLIProxyGatewayError.process(launchFence)
                }

                // Debug 重编译 / 上次强退后，外部 CPA 可能仍占端口；启动前再收一次本机托管孤儿。
                reapOwnedOrphanIfNeeded(ownershipEvaluator: ownershipEvaluator)
                reapStaleManagedListenerIfNeeded(port: normalized.port, ownershipEvaluator: ownershipEvaluator)
                if portAvailableCheck == nil {
                    waitUntilPortFree(normalized.port, bindHost: normalized.bindHost)
                }

                if let conflict = ProxyPortArbiter.conflict(
                    forPorts: [normalized.port],
                    excluding: "cliproxyapi-gateway"
                ) {
                    throw CLIProxyGatewayError.portInUse(
                        conflict.port,
                        "\(conflict.track) / \(conflict.label)"
                    )
                }
                guard checkPort(normalized.port, normalized.bindHost) else {
                    throw CLIProxyGatewayError.portInUse(normalized.port, "another local process")
                }

                let prepared = try prepareInventoryAndLaunch(
                    settings: normalized,
                    excludedCredentialIDs: excludedCredentialIDs,
                    configWriter: {
                        let writtenSecrets = try writeManagedConfiguration(settings: $0)
                        launchSecrets = writtenSecrets
                        return writtenSecrets
                    },
                    launchProcess: { secrets in
                        let process = Process()
                        process.executableURL = binaryURL
                        process.arguments = ["-config", paths.configURL.path]
                        process.currentDirectoryURL = paths.runtimeWorkingDirectory
                        process.environment = Self.buildIsolatedChildEnvironment(paths: paths)

                        let output = Pipe()
                        let errors = Pipe()
                        stdoutPipe = output
                        stderrPipe = errors
                        process.standardOutput = output
                        process.standardError = errors
                        attachLogReader(output.fileHandleForReading, secrets: secrets)
                        attachLogReader(errors.fileHandleForReading, secrets: secrets)

                        try process.run()
                        launchedProcess = process
                        return process
                    }
                )
                if !prepared.sanitizedFiles.isEmpty {
                    cliProxyRuntimeLog.notice("Disabled blocked/excluded managed CPA auth file(s) prior to launch: \(prepared.sanitizedFiles.joined(separator: ", "), privacy: .public)")
                }
                let process = prepared.launched
                self.process = process
                self.adoptedPID = nil
                let launchedEndpoint = ListenerEndpoint(
                    pid: process.processIdentifier,
                    port: normalized.port,
                    bindHost: normalized.bindHost
                )
                self.boundListenerEndpoint = launchedEndpoint
                self.unconfirmedFence = nil
                _ = clearUnconfirmedListenerRecordUnlocked(matching: launchedEndpoint)
                try writePIDRecord(
                    process: process,
                    binaryURL: binaryURL,
                    port: normalized.port,
                    bindHost: normalized.bindHost
                )
                return process
            }
            try await waitUntilHealthy(process: process)
            guard process.isRunning else {
                throw CLIProxyGatewayError.process("process exited after the health check")
            }
            if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild {
                guard let secrets = launchSecrets ?? cachedSecrets else {
                    throw CLIProxyGatewayError.process("Containment unconfirmed: CPA runtime secrets unavailable for post-start auth verification.")
                }
                let client = CLIProxyManagementClient(
                    baseURL: baseURL,
                    managementKey: secrets.managementKey,
                    clientAPIKey: secrets.clientAPIKey,
                    session: Self.ephemeralLoopbackSession
                )
                let runtimeFiles: [CLIProxyAuthFile]
                do {
                    runtimeFiles = try await client.listAuthFiles()
                } catch {
                    throw CLIProxyGatewayError.process(
                        "Containment unconfirmed: failed to verify CPA auth inventory on loopback startup (\(error.localizedDescription))."
                    )
                }
                if let disallowedRow = runtimeFiles.first(where: { !$0.isOpenAICompatibleRuntime }) {
                    throw CLIProxyGatewayError.process(
                        "Containment unconfirmed: API-key-only CPA runtime loaded non-API auth entry '\(disallowedRow.name)'; aborting launch."
                    )
                }
            }
            process.terminationHandler = { [weak self, weak process] _ in
                Task { @MainActor [weak self, weak process] in
                    guard let self, self.process === process else { return }
                    self.handleUnexpectedExit(status: process?.terminationStatus ?? -1)
                }
            }
            restartAttempts = 0
            state = .running(pid: process.processIdentifier)
        } catch {
            let activeLaunch = self.process ?? launchedProcess
            if let activeLaunch, activeLaunch.isRunning {
                activeLaunch.terminationHandler = nil
                activeLaunch.terminate()
                let deadline = Date().addingTimeInterval(1.5)
                while activeLaunch.isRunning, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                if activeLaunch.isRunning {
                    Self.terminatePid(activeLaunch.processIdentifier)
                }
            }
            let pidStillAlive = activeLaunch?.isRunning ?? false
            self.adoptedPID = nil
            if pidStillAlive, let activeLaunch {
                self.process = activeLaunch
                let endpoint = ListenerEndpoint(
                    pid: activeLaunch.processIdentifier,
                    port: normalized.port,
                    bindHost: normalized.bindHost
                )
                self.boundListenerEndpoint = endpoint
                self.unconfirmedFence = .endpoint(endpoint)
                _ = writeUnconfirmedListenerRecord(endpoint, replacing: endpoint)
            } else {
                self.process = nil
                if !hasUnconfirmedListener {
                    self.boundListenerEndpoint = nil
                }
                if activeLaunch != nil {
                    try? withSharedRuntimeFenceLock {
                        clearPIDRecord(ownershipEvaluator: ownershipEvaluator)
                    }
                }
            }
            state = .failed(error.localizedDescription)
            appendLog("[AIUsage] \(error.localizedDescription)")
        }
    }

    nonisolated static func pidOwnership(pid: Int32, paths: CLIProxyPaths, pidURL: URL) -> PIDOwnership {
        guard pid > 1 else { return .unowned(pid: pid, reason: "invalid PID") }
        guard Darwin.kill(pid, 0) == 0 else { return .notAlive }
        guard isManagedCPAListenerProcess(pid, paths: paths) else {
            return .unowned(pid: pid, reason: "listener is not a verified AIUsage-managed CPA binary/config")
        }
        guard let parent = parentPID(pid) else {
            return .unowned(pid: pid, reason: "parent PID could not be verified")
        }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        if parent > 1 && parent != currentPID {
            return .liveSibling(pid: pid)
        }
        if parent == currentPID {
            return .owned(pid: pid)
        }
        guard let pidData = FileManager.default.contents(atPath: pidURL.path),
              let record = try? JSONDecoder().decode(PIDRecord.self, from: pidData),
              record.pid == pid,
              record.configPath == paths.configURL.path else {
            return .unowned(pid: pid, reason: "orphan PID does not match AIUsage runtime PID record")
        }
        return .owned(pid: pid)
    }

    @discardableResult
    private func stopOwnedProcess(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil,
        isAliveCheck: ((Int32) -> Bool)? = nil,
        pidTerminator: ((Int32) -> Void)? = nil
    ) async -> Bool {
        let initialPersistedRead = readUnconfirmedListenerFile()
        switch initialPersistedRead {
        case .unreadable:
            self.unconfirmedFence = .unreadableRecord(path: unconfirmedListenerURL.path)
        case .valid(let persisted):
            if case .unreadableRecord = self.unconfirmedFence {
                self.unconfirmedFence = nil
            }
            if self.unconfirmedFence == nil,
               self.boundListenerEndpoint == nil,
               self.adoptedPID == nil,
               self.process == nil {
                self.unconfirmedFence = .endpoint(persisted)
                self.boundListenerEndpoint = persisted
                self.adoptedPID = persisted.pid
            }
        case .missing:
            if case .unreadableRecord = self.unconfirmedFence {
                self.unconfirmedFence = nil
            }
        }
        let normalized = settings.normalized
        let runningStatePID: Int32? = {
            if case .running(let pid) = state { return pid }
            return nil
        }()
        let endpoint = unconfirmedEndpoint ?? boundListenerEndpoint ?? ListenerEndpoint(
            pid: self.process?.processIdentifier ?? self.adoptedPID ?? runningStatePID,
            port: normalized.port,
            bindHost: normalized.bindHost
        )
        let targetPort = endpoint.port
        let targetHost = endpoint.bindHost
        let checkPort = portAvailableCheck ?? { port, host in Self.isListenerPortFree(port, bindHost: host) }

        func waitForPortRelease() async -> Bool {
            let maxAttempts = portAvailableCheck == nil ? 40 : 1
            for attempt in 0..<maxAttempts {
                if checkPort(targetPort, targetHost) { return true }
                if attempt + 1 < maxAttempts {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            return false
        }

        func failUnreadableRecord() -> Bool {
            self.unconfirmedFence = .unreadableRecord(path: unconfirmedListenerURL.path)
            let msg = self.unconfirmedListenerMessage
                ?? "Containment unconfirmed: unresolved CPA stop marker is unreadable and the original listener endpoint is unknown."
            self.state = .failed(msg)
            self.appendLog("[AIUsage] \(msg)")
            return false
        }

        func failSharedLiveSibling(_ owner: (pid: Int32, port: Int?, bindHost: String?)) -> Bool {
            self.adoptedPID = owner.pid
            if let ownerPort = owner.port {
                let ownerEndpoint = ListenerEndpoint(
                    pid: owner.pid,
                    port: ownerPort,
                    bindHost: owner.bindHost ?? "127.0.0.1"
                )
                switch self.writeUnconfirmedListenerRecord(ownerEndpoint, replacing: ownerEndpoint) {
                case .unreadable:
                    return failUnreadableRecord()
                case .mismatched(let currentPersisted):
                    self.boundListenerEndpoint = currentPersisted
                    self.unconfirmedFence = .endpoint(currentPersisted)
                case .applied, .ioFailure:
                    self.boundListenerEndpoint = ownerEndpoint
                    self.unconfirmedFence = .endpoint(ownerEndpoint)
                }
                let msg = "Containment unconfirmed: live sibling AIUsage instance owns CPA listener pid=\(owner.pid) on port \(ownerPort); stop it before changing or replacing the shared runtime."
                self.state = .failed(msg)
                self.appendLog("[AIUsage] \(msg)")
                return false
            }
            self.unconfirmedFence = .sharedLiveSibling(pid: owner.pid, port: nil, bindHost: nil)
            let msg = self.unconfirmedListenerMessage
                ?? "Containment unconfirmed: live sibling AIUsage instance owns CPA listener pid=\(owner.pid); stop it before changing or replacing the shared runtime."
            self.state = .failed(msg)
            self.appendLog("[AIUsage] \(msg)")
            return false
        }

        func failChangedSharedRecord(_ currentPersisted: ListenerEndpoint) -> Bool {
            self.process = nil
            self.adoptedPID = currentPersisted.pid
            self.boundListenerEndpoint = currentPersisted
            self.unconfirmedFence = .endpoint(currentPersisted)
            let msg = "Containment unconfirmed: shared CPA stop record changed to \(currentPersisted.bindHost):\(currentPersisted.port); verify that the active listener on that endpoint stopped."
            self.state = .failed(msg)
            self.appendLog("[AIUsage] \(msg)")
            return false
        }

        func failUnconfirmed(pid: Int32?, message: String) -> Bool {
            if self.readUnconfirmedListenerFile() == .unreadable {
                return failUnreadableRecord()
            }
            if case .sharedLiveSibling(_, nil, _) = self.unconfirmedFence, let pid {
                self.adoptedPID = pid
                self.unconfirmedFence = .sharedLiveSibling(pid: pid, port: nil, bindHost: nil)
                self.state = .failed(message)
                self.appendLog("[AIUsage] \(message)")
                return false
            }
            let preserved = ListenerEndpoint(pid: pid, port: targetPort, bindHost: targetHost)
            switch self.writeUnconfirmedListenerRecord(preserved, replacing: endpoint) {
            case .unreadable:
                return failUnreadableRecord()
            case .mismatched(let currentPersisted):
                return failChangedSharedRecord(currentPersisted)
            case .applied, .ioFailure:
                self.adoptedPID = pid
                self.boundListenerEndpoint = preserved
                self.unconfirmedFence = .endpoint(preserved)
                self.state = .failed(message)
                self.appendLog("[AIUsage] \(message)")
                return false
            }
        }

        func confirmStopped(verifiedEndpoint: ListenerEndpoint?) -> Bool {
            let outcome: Bool? = try? self.withSharedRuntimeFenceLock {
                switch self.readUnconfirmedListenerFile() {
                case .unreadable:
                    return failUnreadableRecord()
                case .valid(let currentPersisted):
                    guard let verifiedEndpoint,
                          Self.persistedRecordMatchesVerifiedEndpoint(currentPersisted, verified: verifiedEndpoint) else {
                        return failChangedSharedRecord(currentPersisted)
                    }
                case .missing:
                    break
                }
                if let sharedOwner = self.liveSharedRuntimeOwner(ownershipEvaluator: ownershipEvaluator) {
                    return failSharedLiveSibling(sharedOwner)
                }
                switch self.clearUnconfirmedListenerRecordUnlocked(matching: verifiedEndpoint) {
                case .applied:
                    break
                case .unreadable:
                    return failUnreadableRecord()
                case .mismatched(let currentPersisted):
                    return failChangedSharedRecord(currentPersisted)
                case .ioFailure(let reason):
                    let msg = "Containment unconfirmed: failed to remove shared CPA stop record (\(reason))."
                    self.state = .failed(msg)
                    self.appendLog("[AIUsage] \(msg)")
                    return false
                }
                self.process = nil
                self.adoptedPID = nil
                self.boundListenerEndpoint = nil
                self.unconfirmedFence = nil
                self.clearPIDRecord(ownershipEvaluator: ownershipEvaluator)
                self.state = .stopped
                return true
            }
            if let outcome {
                return outcome
            }
            let msg = "Containment unconfirmed: unable to acquire cross-process CPA runtime fence lock."
            self.state = .failed(msg)
            self.appendLog("[AIUsage] \(msg)")
            return false
        }

        if let process = self.process {
            let pid = process.processIdentifier
            state = .stopping
            process.terminationHandler = nil
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(30)
                while process.isRunning, Date() < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if process.isRunning {
                    if let pidTerminator { pidTerminator(pid) }
                    else { Darwin.kill(pid, SIGKILL) }
                    let killDeadline = Date().addingTimeInterval(1)
                    while process.isRunning, Date() < killDeadline {
                        try? await Task.sleep(for: .milliseconds(20))
                    }
                }
            }
            let stillRunning = process.isRunning || (isAliveCheck?(pid) ?? false)
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
            stdoutPipe = nil
            stderrPipe = nil
            if !process.isRunning {
                self.process = nil
            }
            finishPendingProcessLogs()
            let portFree = await waitForPortRelease()
            guard !stillRunning, portFree else {
                let msg = "Containment unconfirmed: owned CPA process pid=\(pid) or port \(targetPort) did not stop cleanly."
                return failUnconfirmed(pid: stillRunning ? pid : nil, message: msg)
            }
            return confirmStopped(verifiedEndpoint: endpoint)
        }

        if initialPersistedRead == .unreadable {
            finishPendingProcessLogs()
            return failUnreadableRecord()
        }

        if let targetPID = self.adoptedPID ?? runningStatePID ?? unconfirmedEndpoint?.pid {
            state = .stopping
            let evaluate = ownershipEvaluator ?? { [paths, pidURL] pid in
                Self.pidOwnership(pid: pid, paths: paths, pidURL: pidURL)
            }
            switch evaluate(targetPID) {
            case .notAlive:
                finishPendingProcessLogs()
                if await waitForPortRelease() {
                    return confirmStopped(verifiedEndpoint: endpoint)
                }
                let msg = "Containment unconfirmed: port \(targetPort) remains in use after adopted CPA pid=\(targetPID) exited."
                return failUnconfirmed(pid: nil, message: msg)
            case .owned(let ownedPID):
                let terminate = pidTerminator ?? { Self.terminatePid($0) }
                terminate(ownedPID)
                let aliveCheck = isAliveCheck ?? { Darwin.kill($0, 0) == 0 }
                let stillAlive = aliveCheck(ownedPID)
                let portFree = await waitForPortRelease()
                finishPendingProcessLogs()
                if !stillAlive, portFree {
                    return confirmStopped(verifiedEndpoint: endpoint)
                }
                let msg = "Containment unconfirmed: owned adopted CPA listener pid=\(ownedPID) could not be confirmed stopped on port \(targetPort)."
                return failUnconfirmed(pid: stillAlive ? ownedPID : nil, message: msg)
            case .liveSibling(let siblingPID):
                // Never kill or erase the PID record of a live sibling AIUsage instance.
                finishPendingProcessLogs()
                if unconfirmedEndpoint == nil,
                   boundListenerEndpoint == nil,
                   let sharedOwner = liveSharedRuntimeOwner(ownershipEvaluator: ownershipEvaluator) {
                    return failSharedLiveSibling(sharedOwner)
                }
                let msg = "Containment unconfirmed: CPA listener pid=\(siblingPID) is owned by another live AIUsage process and was left untouched."
                return failUnconfirmed(pid: siblingPID, message: msg)
            case .unowned(let unownedPID, let reason):
                finishPendingProcessLogs()
                let msg = "Containment unconfirmed: cannot safely stop adopted listener pid=\(unownedPID) (\(reason))."
                return failUnconfirmed(pid: unownedPID, message: msg)
            }
        }

        finishPendingProcessLogs()
        if let sharedOwner = liveSharedRuntimeOwner(ownershipEvaluator: ownershipEvaluator) {
            return failSharedLiveSibling(sharedOwner)
        }
        switch self.unconfirmedFence {
        case .unreadableRecord:
            return failUnreadableRecord()
        case .sharedLiveSibling(let siblingPID, let siblingPort, let siblingHost):
            let evaluate = ownershipEvaluator ?? { [paths, pidURL] pid in
                Self.pidOwnership(pid: pid, paths: paths, pidURL: pidURL)
            }
            if case .liveSibling = evaluate(siblingPID) {
                return failSharedLiveSibling((pid: siblingPID, port: siblingPort, bindHost: siblingHost))
            }
            if let siblingPort, !checkPort(siblingPort, siblingHost ?? "127.0.0.1") {
                return failUnconfirmed(
                    pid: nil,
                    message: "Containment unconfirmed: original CPA listener port \(siblingPort) remains occupied."
                )
            }
            let verifiedSibling = siblingPort.map {
                ListenerEndpoint(pid: siblingPID, port: $0, bindHost: siblingHost ?? "127.0.0.1")
            }
            return confirmStopped(verifiedEndpoint: verifiedSibling)
        case .endpoint(let unconfirmed):
            if await waitForPortRelease() {
                return confirmStopped(verifiedEndpoint: unconfirmed)
            }
            let msg = "Containment unconfirmed: original CPA listener port \(unconfirmed.port) remains occupied."
            return failUnconfirmed(pid: unconfirmed.pid, message: msg)
        case nil:
            if !canLaunchManagedRuntime {
                guard await waitForPortRelease() else {
                    return failUnconfirmed(
                        pid: nil,
                        message: "Containment unconfirmed: CPA port \(targetPort) is in use without a verified owner."
                    )
                }
                return confirmStopped(verifiedEndpoint: endpoint)
            }
            if case .failed = state {
                if await waitForPortRelease() {
                    return confirmStopped(verifiedEndpoint: endpoint)
                }
                return false
            }
            return confirmStopped(verifiedEndpoint: nil)
        }
    }

    private func writeManagedConfiguration(
        settings value: CLIProxyGatewaySettings? = nil
    ) throws -> CLIProxySecrets {
        let secrets = try secretStore.loadOrCreate()
        cachedSecrets = secrets
        let clientKeys = (try? clientKeyStore.enabledKeysForRuntime()) ?? [secrets.clientAPIKey]
        try configStore.writeRuntimeConfig(
            settings: (value ?? settings).normalized,
            secrets: secrets,
            clientAPIKeys: clientKeys
        )
        refreshClientKeyRotationState()
        return secrets
    }

    private func refreshClientKeyRotationState() {
        guard let currentKey = cachedSecrets?.clientAPIKey,
              let fingerprint = Self.fingerprint(for: currentKey) else {
            clientKeyNeedsRecopy = false
            return
        }
        let defaults = UserDefaults.standard
        let previous = defaults.string(forKey: Self.clientKeyFingerprintDefaultsKey)
        let acknowledged = defaults.string(forKey: Self.clientKeyAcknowledgedDefaultsKey)
        let externalDrift = Self.detectExternalClientKeyDrift(expectedKey: currentKey)
        if let previous, previous != fingerprint {
            // Keychain 被清空/重建后会生成新钥；旧客户端仍用旧钥会 401。
            clientKeyNeedsRecopy = acknowledged != fingerprint || externalDrift
        } else if acknowledged == nil {
            defaults.set(fingerprint, forKey: Self.clientKeyAcknowledgedDefaultsKey)
            // 首次也能检出 Hermes 等外部客户端仍持旧钥。
            clientKeyNeedsRecopy = externalDrift
        } else {
            clientKeyNeedsRecopy = acknowledged != fingerprint || externalDrift
        }
        defaults.set(fingerprint, forKey: Self.clientKeyFingerprintDefaultsKey)
    }

    private static func fingerprint(for key: String?) -> String? {
        guard let key, !key.isEmpty else { return nil }
        return "\(key.count):\(key.suffix(8))"
    }

    /// 只读探测常见本地客户端是否仍指向本机 CPA 却持有旧 client key。
    private static func detectExternalClientKeyDrift(expectedKey: String) -> Bool {
        let hermesRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes")
        let envURL = hermesRoot.appendingPathComponent(".env")
        let configURL = hermesRoot.appendingPathComponent("config.yaml")
        guard let text = try? String(contentsOf: envURL, encoding: .utf8) else { return false }

        let envPointsToCPA = text.contains("14420")
            || text.contains("CLIPROXY")
            || text.contains("cliproxy")
        let configPointsToCPA: Bool = {
            guard let config = try? String(contentsOf: configURL, encoding: .utf8) else { return false }
            return config.contains("127.0.0.1:14420") || config.contains("localhost:14420")
        }()
        guard envPointsToCPA || configPointsToCPA else { return false }

        guard let match = text.range(
            of: #"OPENAI_API_KEY=(cpa-client-[A-Za-z0-9_-]+)"#,
            options: .regularExpression
        ) else {
            return false
        }
        let line = String(text[match])
        let key = line.replacingOccurrences(of: "OPENAI_API_KEY=", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return !key.isEmpty && key != expectedKey
    }

    private func handleUnexpectedExit(status: Int32) {
        process = nil
        boundListenerEndpoint = nil
        clearPIDRecord()
        guard shouldBeRunning else {
            state = .stopped
            return
        }
        appendLog("[AIUsage] CPA exited unexpectedly (status \(status)).")
        autoRecoveryTask?.cancel()
        if restartAttempts < 5 {
            restartAttempts += 1
            let attemptDelay = Double(restartAttempts) * 2.0
            state = .starting
            autoRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(attemptDelay))
                guard !Task.isCancelled, let self else { return }
                self.autoRecoveryTask = nil
                await self.withLifecycleLock {
                    guard !Task.isCancelled, self.shouldBeRunning, !self.state.isRunning else { return }
                    await self.startOnce()
                }
            }
        } else {
            state = .failed("CLIProxyAPI exited repeatedly; scheduling auto-recovery in 30s.")
            autoRecoveryTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, let self else { return }
                self.autoRecoveryTask = nil
                await self.withLifecycleLock {
                    guard !Task.isCancelled, self.shouldBeRunning, !self.state.isRunning else { return }
                    self.appendLog("[AIUsage] Attempting auto-recovery for CPA Gateway...")
                    self.restartAttempts = 0
                    await self.startOnce()
                }
            }
        }
    }

    private func waitUntilHealthy(process: Process) async throws {
        let endpoint = baseURL.appendingPathComponent("healthz")
        let deadline = Date().addingTimeInterval(12)
        var lastError = "health endpoint did not become ready"
        while Date() < deadline, process.isRunning {
            var request = URLRequest(url: endpoint, timeoutInterval: 0.8)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch { lastError = error.localizedDescription }
            try await Task.sleep(for: .milliseconds(200))
        }
        if !process.isRunning { lastError = "process exited with status \(process.terminationStatus)" }
        throw CLIProxyGatewayError.process(lastError)
    }

    private func attachLogReader(_ handle: FileHandle, secrets: CLIProxySecrets) {
        handle.readabilityHandler = { [weak self] file in
            let data = file.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let redacted = Self.redactLog(text, secrets: secrets)
            let lines = redacted.split(whereSeparator: \.isNewline).map(String.init)
            guard !lines.isEmpty else { return }
            Task { @MainActor [weak self] in
                self?.enqueueProcessLogs(lines)
            }
        }
    }

    nonisolated private static func redactLog(_ text: String, secrets: CLIProxySecrets) -> String {
        var redacted = text
            .replacingOccurrences(of: secrets.managementKey, with: "[REDACTED]")
            .replacingOccurrences(of: secrets.clientAPIKey, with: "[REDACTED]")
        let patterns = [
            #"(?i)(\bBearer\s+)[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|api[_-]?key|oauth[_-]?code|device[_-]?code|user[_-]?code)\b[\"']?\s*[:=]\s*[\"']?)[^\"'\s,;}]{4,}"#,
            #"(?im)(\b(?:authorization|cookie|set-cookie)\s*:\s*)[^\r\n]+"#
        ]
        for pattern in patterns {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(redacted.startIndex..., in: redacted)
            redacted = expression.stringByReplacingMatches(
                in: redacted,
                range: range,
                withTemplate: "$1[REDACTED]"
            )
        }
        return redacted
    }

    /// CPA can emit several lines per request. Publish them in short batches so
    /// views observing runtime state are not invalidated once for every stdout
    /// line while the gateway is busy.
    private func enqueueProcessLogs(_ lines: [String]) {
        pendingProcessLogs.append(contentsOf: lines.filter { !$0.isEmpty })
        guard !pendingProcessLogs.isEmpty, logFlushTask == nil else { return }
        logFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.flushProcessLogs()
        }
    }

    private func flushProcessLogs() {
        logFlushTask = nil
        guard !pendingProcessLogs.isEmpty else { return }
        recentLogs.append(contentsOf: pendingProcessLogs)
        pendingProcessLogs.removeAll(keepingCapacity: true)
        if recentLogs.count > 200 { recentLogs.removeFirst(recentLogs.count - 200) }
    }

    private func finishPendingProcessLogs() {
        logFlushTask?.cancel()
        logFlushTask = nil
        flushProcessLogs()
    }

    private func appendLog(_ line: String) {
        guard !line.isEmpty else { return }
        recentLogs.append(line)
        if recentLogs.count > 200 { recentLogs.removeFirst(recentLogs.count - 200) }
    }

    private func writePIDRecord(process: Process, binaryURL: URL, port: Int, bindHost: String) throws {
        let record = PIDRecord(
            pid: process.processIdentifier,
            binaryPath: binaryURL.resolvingSymlinksInPath().path,
            configPath: paths.configURL.path,
            configSHA256: configStore.runtimeConfigSHA256(),
            port: port,
            bindHost: bindHost,
            isolationProfile: Self.currentIsolationProfile,
            runtimeAuthDir: CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                ? paths.authDirectory.path
                : paths.isolatedAuthDirectory.path,
            workingDirectory: paths.runtimeWorkingDirectory.path
        )
        let data = try JSONEncoder().encode(record)
        try data.write(to: pidURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidURL.path)
    }

    nonisolated private static func persistedRecordMatchesVerifiedEndpoint(
        _ persisted: ListenerEndpoint,
        verified: ListenerEndpoint
    ) -> Bool {
        persisted.port == verified.port
            && persisted.bindHost == verified.bindHost
            && (persisted.pid == verified.pid || persisted.pid == nil)
    }

    private func withSharedRuntimeFenceLock<T>(_ body: () throws -> T) throws -> T {
        if sharedRuntimeLockDepth > 0 {
            return try body()
        }
        try FileManager.default.createDirectory(at: paths.root, withIntermediateDirectories: true)
        let lockPath = sharedRuntimeLockURL.path
        var st = stat()
        if lstat(lockPath, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw CLIProxyGatewayError.process(
                "Containment unconfirmed: shared CPA fence lock path is not a regular file (\(lockPath))."
            )
        }
        var fd: Int32 = -1
        while true {
            fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK, S_IRUSR | S_IWUSR)
            if fd >= 0 { break }
            if errno == EINTR { continue }
            throw CLIProxyGatewayError.process(
                "Containment unconfirmed: failed to open and lock shared CPA fence (\(String(cString: strerror(errno))))."
            )
        }
        defer { Darwin.close(fd) }
        _ = Darwin.fchmod(fd, S_IRUSR | S_IWUSR)
        sharedRuntimeLockDepth += 1
        defer { sharedRuntimeLockDepth -= 1 }
        return try body()
    }

    @discardableResult
    private func writeUnconfirmedListenerRecordUnlocked(
        _ endpoint: ListenerEndpoint,
        replacing verifiedEndpoint: ListenerEndpoint? = nil
    ) -> PersistedFenceMutationResult {
        switch readUnconfirmedListenerFile() {
        case .unreadable:
            return .unreadable
        case .valid(let currentPersisted):
            guard let verifiedEndpoint,
                  Self.persistedRecordMatchesVerifiedEndpoint(currentPersisted, verified: verifiedEndpoint) else {
                return .mismatched(currentPersisted)
            }
            if currentPersisted == endpoint {
                return .applied
            }
        case .missing:
            break
        }
        do {
            let data = try JSONEncoder().encode(endpoint)
            try data.write(to: unconfirmedListenerURL, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: unconfirmedListenerURL.path
            )
            return .applied
        } catch {
            cliProxyRuntimeLog.error(
                "Failed to persist unconfirmed CPA listener fence: \(error.localizedDescription, privacy: .public)"
            )
            return .ioFailure(error.localizedDescription)
        }
    }

    @discardableResult
    private func writeUnconfirmedListenerRecord(
        _ endpoint: ListenerEndpoint,
        replacing verifiedEndpoint: ListenerEndpoint? = nil
    ) -> PersistedFenceMutationResult {
        do {
            return try withSharedRuntimeFenceLock {
                writeUnconfirmedListenerRecordUnlocked(endpoint, replacing: verifiedEndpoint)
            }
        } catch {
            return .ioFailure(error.localizedDescription)
        }
    }

    private func readUnconfirmedListenerFile() -> PersistedFenceReadResult {
        guard FileManager.default.fileExists(atPath: unconfirmedListenerURL.path) else { return .missing }
        guard let data = FileManager.default.contents(atPath: unconfirmedListenerURL.path),
              let decoded = try? JSONDecoder().decode(ListenerEndpoint.self, from: data),
              (1...65_535).contains(decoded.port),
              !decoded.bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .unreadable
        }
        return .valid(decoded)
    }

    @discardableResult
    private func clearUnconfirmedListenerRecordUnlocked(
        matching verifiedEndpoint: ListenerEndpoint? = nil
    ) -> PersistedFenceMutationResult {
        switch readUnconfirmedListenerFile() {
        case .missing:
            return .applied
        case .unreadable:
            return .unreadable
        case .valid(let currentPersisted):
            if let verifiedEndpoint,
               !Self.persistedRecordMatchesVerifiedEndpoint(currentPersisted, verified: verifiedEndpoint) {
                return .mismatched(currentPersisted)
            }
        }
        do {
            if FileManager.default.fileExists(atPath: unconfirmedListenerURL.path) {
                try FileManager.default.removeItem(at: unconfirmedListenerURL)
            }
            return .applied
        } catch {
            return .ioFailure(error.localizedDescription)
        }
    }

    @discardableResult
    private func clearUnconfirmedListenerRecord(
        matching verifiedEndpoint: ListenerEndpoint? = nil
    ) -> PersistedFenceMutationResult {
        do {
            return try withSharedRuntimeFenceLock {
                clearUnconfirmedListenerRecordUnlocked(matching: verifiedEndpoint)
            }
        } catch {
            return .ioFailure(error.localizedDescription)
        }
    }

    nonisolated private static func isEndpointPIDStillActive(
        _ pid: Int32?,
        paths: CLIProxyPaths,
        pidURL: URL,
        portStillBusy: Bool,
        ownershipEvaluator: ((Int32) -> PIDOwnership)?,
        isAliveCheck: ((Int32) -> Bool)?
    ) -> Bool {
        guard let pid, pid > 1 else { return false }
        if let ownershipEvaluator {
            switch ownershipEvaluator(pid) {
            case .liveSibling, .owned:
                return true
            case .unowned:
                return portStillBusy
            case .notAlive:
                return false
            }
        }
        if let isAliveCheck {
            return isAliveCheck(pid)
        }
        switch Self.pidOwnership(pid: pid, paths: paths, pidURL: pidURL) {
        case .liveSibling, .owned:
            return true
        case .unowned:
            return portStillBusy
        case .notAlive:
            return false
        }
    }

    func restorePersistedListenerFenceIfNeeded(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil,
        isAliveCheck: ((Int32) -> Bool)? = nil
    ) {
        do {
            try withSharedRuntimeFenceLock {
                restorePersistedListenerFenceIfNeededLocked(
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator,
                    isAliveCheck: isAliveCheck
                )
            }
        } catch {
            let msg = error.localizedDescription
            state = .failed(msg)
            appendLog("[AIUsage] \(msg)")
        }
    }

    private func restorePersistedListenerFenceIfNeededLocked(
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil,
        isAliveCheck: ((Int32) -> Bool)? = nil
    ) {
        switch readUnconfirmedListenerFile() {
        case .missing:
            if case .unreadableRecord = unconfirmedFence {
                unconfirmedFence = nil
            }
            return
        case .unreadable:
            unconfirmedFence = .unreadableRecord(path: unconfirmedListenerURL.path)
            if let message = unconfirmedListenerMessage {
                state = .failed(message)
                appendLog("[AIUsage] \(message)")
            }
            return
        case .valid(let persisted):
            if persisted.port != settings.normalized.port {
                reapStaleManagedListenerIfNeeded(port: persisted.port, ownershipEvaluator: ownershipEvaluator)
            }
            let checkPort = portAvailableCheck ?? { port, host in Self.isListenerPortFree(port, bindHost: host) }
            let portStillBusy = !checkPort(persisted.port, persisted.bindHost)
            let pidStillActive = Self.isEndpointPIDStillActive(
                persisted.pid,
                paths: paths,
                pidURL: pidURL,
                portStillBusy: portStillBusy,
                ownershipEvaluator: ownershipEvaluator,
                isAliveCheck: isAliveCheck
            )
            guard pidStillActive || portStillBusy else {
                switch clearUnconfirmedListenerRecordUnlocked(matching: persisted) {
                case .applied:
                    clearPIDRecord(ownershipEvaluator: ownershipEvaluator)
                    if unconfirmedFence == .endpoint(persisted) {
                        unconfirmedFence = nil
                        boundListenerEndpoint = nil
                        adoptedPID = nil
                    }
                case .unreadable:
                    unconfirmedFence = .unreadableRecord(path: unconfirmedListenerURL.path)
                    if let message = unconfirmedListenerMessage {
                        state = .failed(message)
                        appendLog("[AIUsage] \(message)")
                    }
                case .mismatched(let currentPersisted):
                    adoptedPID = currentPersisted.pid
                    boundListenerEndpoint = currentPersisted
                    unconfirmedFence = .endpoint(currentPersisted)
                    if let message = unconfirmedListenerMessage {
                        state = .failed(message)
                        appendLog("[AIUsage] \(message)")
                    }
                case .ioFailure(let reason):
                    adoptedPID = persisted.pid
                    boundListenerEndpoint = persisted
                    unconfirmedFence = .endpoint(persisted)
                    let msg = "Containment unconfirmed: failed to clear shared CPA stop record (\(reason))."
                    state = .failed(msg)
                    appendLog("[AIUsage] \(msg)")
                }
                return
            }
            let restored = ListenerEndpoint(
                pid: pidStillActive ? persisted.pid : nil,
                port: persisted.port,
                bindHost: persisted.bindHost
            )
            adoptedPID = restored.pid
            boundListenerEndpoint = restored
            unconfirmedFence = .endpoint(restored)
            if restored != persisted {
                _ = writeUnconfirmedListenerRecordUnlocked(restored, replacing: persisted)
            }
            if let message = unconfirmedListenerMessage {
                state = .failed(message)
                appendLog("[AIUsage] \(message)")
            }
        }
    }

    private func liveSharedRuntimeOwner(
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) -> (pid: Int32, port: Int?, bindHost: String?)? {
        guard let data = FileManager.default.contents(atPath: pidURL.path),
              let record = try? JSONDecoder().decode(PIDRecord.self, from: data),
              record.configPath == paths.configURL.path,
              record.pid > 1 else {
            return nil
        }
        let evaluate = ownershipEvaluator ?? { [paths, pidURL] pid in
            Self.pidOwnership(pid: pid, paths: paths, pidURL: pidURL)
        }
        guard case .liveSibling(let siblingPID) = evaluate(record.pid) else { return nil }
        return (pid: siblingPID, port: record.port, bindHost: record.bindHost)
    }

    private func liveSharedRuntimeOwnerMessage(
        forTargetPort targetPort: Int?,
        targetHost: String?,
        allowSamePortAdoption: Bool,
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) -> String? {
        guard let owner = liveSharedRuntimeOwner(ownershipEvaluator: ownershipEvaluator) else {
            return nil
        }
        if allowSamePortAdoption, let targetPort, let targetHost {
            let checkPort = portAvailableCheck ?? { port, host in Self.isListenerPortFree(port, bindHost: host) }
            if let recordedPort = owner.port {
                if recordedPort == targetPort {
                    return nil
                }
            } else if !checkPort(targetPort, targetHost) {
                return nil
            }
        }
        let portSuffix = owner.port.map { " on port \($0)" } ?? ""
        return "Containment unconfirmed: live sibling AIUsage instance owns CPA listener pid=\(owner.pid)\(portSuffix); stop it before changing or replacing the shared runtime."
    }

    private func unresolvedListenerFenceMessage(
        forTargetPort targetPort: Int?,
        targetHost: String?,
        allowSamePortAdoption: Bool,
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) -> String? {
        do {
            return try withSharedRuntimeFenceLock {
                unresolvedListenerFenceMessageLocked(
                    forTargetPort: targetPort,
                    targetHost: targetHost,
                    allowSamePortAdoption: allowSamePortAdoption,
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                )
            }
        } catch {
            return error.localizedDescription
        }
    }

    private func unresolvedListenerFenceMessageLocked(
        forTargetPort targetPort: Int?,
        targetHost: String?,
        allowSamePortAdoption: Bool,
        portAvailableCheck: ((Int, String) -> Bool)? = nil,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) -> String? {
        switch readUnconfirmedListenerFile() {
        case .unreadable:
            unconfirmedFence = .unreadableRecord(path: unconfirmedListenerURL.path)
            return unconfirmedListenerMessage
        case .valid(let persisted):
            if unconfirmedFence == nil || unconfirmedEndpoint != persisted {
                restorePersistedListenerFenceIfNeededLocked(
                    portAvailableCheck: portAvailableCheck,
                    ownershipEvaluator: ownershipEvaluator
                )
            }
            if let message = unconfirmedListenerMessage {
                return message
            }
        case .missing:
            if case .unreadableRecord = unconfirmedFence {
                unconfirmedFence = nil
            }
        }
        if let message = unconfirmedListenerMessage {
            return message
        }
        return liveSharedRuntimeOwnerMessage(
            forTargetPort: targetPort,
            targetHost: targetHost,
            allowSamePortAdoption: allowSamePortAdoption,
            portAvailableCheck: portAvailableCheck,
            ownershipEvaluator: ownershipEvaluator
        )
    }

    private func clearPIDRecord(ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil) {
        // Production and Debug builds share the CPA runtime directory. Never
        // erase the live owner's record merely because this bundle has no
        // local `Process` handle for it.
        if let data = FileManager.default.contents(atPath: pidURL.path),
           let record = try? JSONDecoder().decode(PIDRecord.self, from: data),
           record.pid > 1 {
            if let ownershipEvaluator {
                switch ownershipEvaluator(record.pid) {
                case .liveSibling, .unowned:
                    return
                case .owned, .notAlive:
                    break
                }
            } else if Darwin.kill(record.pid, 0) == 0 {
                guard let parent = Self.parentPID(record.pid) else {
                    // Inspection failure is not proof of staleness. Preserve the
                    // only ownership record for a live process.
                    return
                }
                if parent > 1, parent != ProcessInfo.processInfo.processIdentifier {
                    return
                }
            }
        }
        try? FileManager.default.removeItem(at: pidURL)
    }

    private func reapOwnedOrphanIfNeeded(ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil) {
        guard let data = FileManager.default.contents(atPath: pidURL.path),
              let record = try? JSONDecoder().decode(PIDRecord.self, from: data) else {
            clearPIDRecord()
            return
        }
        guard record.pid > 1, Darwin.kill(record.pid, 0) == 0 else {
            clearPIDRecord()
            return
        }
        if let ownershipEvaluator {
            switch ownershipEvaluator(record.pid) {
            case .owned:
                break
            case .notAlive:
                clearPIDRecord()
                return
            case .liveSibling, .unowned:
                return
            }
        } else {
            let currentPID = ProcessInfo.processInfo.processIdentifier
            guard let parent = Self.parentPID(record.pid),
                  parent == 1 || parent == currentPID else {
                // A live production/Debug sibling owns this CPA. It is not an
                // orphan and its PID record must remain intact.
                return
            }
        }
        defer { clearPIDRecord() }

        let matchesConfig = record.configPath == paths.configURL.path
            || Self.processCommand(record.pid).contains(paths.configURL.path)
        let binaryPath = Self.processPath(record.pid)
        let matchesBinary = binaryPath == record.binaryPath
            || (binaryPath?.hasPrefix(paths.versionsDirectory.path + "/") == true)
            || record.binaryPath.hasPrefix(paths.versionsDirectory.path + "/")
        // 放宽匹配：pid 文件存在且仍是我们的 versions 二进制 / 仍带本机 config，即回收。
        // （Xcode 强杀后 binary 路径偶发解析不一致，过严会导致端口孤儿留下。）
        guard matchesConfig || matchesBinary else { return }

        cliProxyRuntimeLog.notice("Reaping CPA orphan from pid file pid=\(record.pid, privacy: .public)")
        Self.terminatePid(record.pid)
    }

    /// 按监听端口回收「带本机 -config」的 CLIProxyAPI，覆盖 pid 文件丢失的情况。
    private func reapStaleManagedListenerIfNeeded(
        port: Int,
        ownershipEvaluator: ((Int32) -> PIDOwnership)? = nil
    ) {
        guard (1...65_535).contains(port) else { return }
        let configPath = paths.configURL.path
        let candidates = Self.pidsListening(on: port).filter { pid in
            pid > 1 && pid != ProcessInfo.processInfo.processIdentifier
        }
        for pid in candidates {
            if let ownershipEvaluator {
                guard case .owned = ownershipEvaluator(pid) else { continue }
            } else {
                let currentPID = ProcessInfo.processInfo.processIdentifier
                guard let parent = Self.parentPID(pid),
                      parent == 1 || parent == currentPID else { continue }
            }
            let command = Self.processCommand(pid)
            let path = Self.processPath(pid) ?? ""
            let looksLikeCPA = path.localizedCaseInsensitiveContains("cliproxy")
                || path.localizedCaseInsensitiveContains("CLIProxyAPI")
                || (path as NSString).lastPathComponent.localizedCaseInsensitiveContains("cliproxy")
            let usesOurConfig = command.contains(configPath)
            let underOurVersions = path.hasPrefix(paths.versionsDirectory.path + "/")
            guard looksLikeCPA, usesOurConfig || underOurVersions else { continue }
            cliProxyRuntimeLog.notice(
                "Reaping stale CPA listener on port \(port, privacy: .public) pid=\(pid, privacy: .public)"
            )
            Self.terminatePid(pid)
        }
    }

    private func waitUntilPortFree(_ port: Int, bindHost: String, attempts: Int = 20) {
        for _ in 0..<attempts {
            if Self.isListenerPortFree(port, bindHost: bindHost) { return }
            usleep(100_000)
        }
    }

    nonisolated private static func terminatePid(_ pid: Int32) {
        Darwin.kill(pid, SIGTERM)
        for _ in 0..<15 where Darwin.kill(pid, 0) == 0 {
            usleep(100_000)
        }
        if Darwin.kill(pid, 0) == 0 {
            Darwin.kill(pid, SIGKILL)
            for _ in 0..<10 where Darwin.kill(pid, 0) == 0 {
                usleep(50_000)
            }
        }
    }

    private static func pidsListening(on port: Int) -> [Int32] {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        let pipe = Pipe()
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output
            .components(separatedBy: .whitespacesAndNewlines)
            .compactMap { Int32($0) }
    }

    nonisolated private static func processPath(_ pid: Int32) -> String? {
        // Equivalent to PROC_PIDPATHINFO_MAXSIZE (4 * MAXPATHLEN); the macro is not imported by Swift.
        var buffer = [CChar](repeating: 0, count: 4 * 1_024)
        let count = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard count > 0 else { return nil }
        return String(cString: buffer)
    }

    nonisolated private static func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let actual = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected)
        guard actual == expected else { return nil }
        return Int32(info.pbi_ppid)
    }

    nonisolated private static func processCommand(_ pid: Int32) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", "\(pid)", "-o", "command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return "" }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func isListenerPortFree(_ port: Int, bindHost: String) -> Bool {
        guard isIPv4PortAvailable(port, bindHost: bindHost) else { return false }
        return pidsListening(on: port).isEmpty
    }

    private static func isIPv4PortAvailable(_ port: Int, bindHost: String) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr = in_addr(s_addr: inet_addr(bindHost))
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private static func activePrivateIPv4Addresses() -> [String] {
        var firstAddress: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&firstAddress) == 0, let firstAddress else { return [] }
        defer { freeifaddrs(firstAddress) }

        var candidates: [(interface: String, address: String)] = []
        for pointer in sequence(first: firstAddress, next: { $0.pointee.ifa_next }) {
            let interface = pointer.pointee
            guard let socketAddress = interface.ifa_addr,
                  socketAddress.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = Int32(interface.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress,
                socklen_t(socketAddress.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let address = String(cString: host)
            guard isLocalNetworkIPv4(address) else { continue }
            candidates.append((String(cString: interface.ifa_name), address))
        }

        let preferredInterfaces = ["en0", "en1"]
        return candidates
            .sorted { lhs, rhs in
                let left = preferredInterfaces.firstIndex(of: lhs.interface) ?? preferredInterfaces.count
                let right = preferredInterfaces.firstIndex(of: rhs.interface) ?? preferredInterfaces.count
                return left == right ? lhs.interface < rhs.interface : left < right
            }
            .reduce(into: [String]()) { addresses, candidate in
                if !addresses.contains(candidate.address) { addresses.append(candidate.address) }
            }
    }

    private static func isLocalNetworkIPv4(_ address: String) -> Bool {
        let parts = address.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        if parts[0] == 10 { return true }
        if parts[0] == 172, (16...31).contains(parts[1]) { return true }
        if parts[0] == 192, parts[1] == 168 { return true }
        // RFC 6598 shared address space is commonly used by VPN/tailnet
        // interfaces. Keep it as an explicit candidate instead of pretending
        // every listed address belongs to a physical LAN.
        if parts[0] == 100, (64...127).contains(parts[1]) { return true }
        return false
    }
}
