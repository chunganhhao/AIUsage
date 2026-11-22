import AppKit
import Darwin
import Foundation
import Combine
import QuotaBackend
import os.log

private let providerActivationLog = Logger(subsystem: "com.aiusage.desktop", category: "ProviderActivation")

extension Notification.Name {
    /// Codex 订阅账号即将激活（写 ~/.codex/auth.json）。Codex 代理监听此通知后自动停用，
    /// 还原 config.toml，避免 ~/.codex 下的 auth.json 与 config.toml 冲突、用量统计串台。
    static let codexSubscriptionAccountActivating = Notification.Name("com.aiusage.codexSubscriptionAccountActivating")
}

// MARK: - Provider Account Activation
// Manages CLI auth file switching for Codex and Gemini: detection from disk,
// activation from managed/proxy sources, format normalization, and UserDefaults persistence.

final class ProviderActivationManager: ObservableObject {
    static let shared = ProviderActivationManager()

    static let activatableProviders: Set<String> = ["codex", "gemini"]

    @Published var activeProviderAccountIds: [String: String] = {
        guard let data = UserDefaults.standard.data(forKey: DefaultsKey.activeProviderAccountIds) else {
            if let legacyCodex = UserDefaults.standard.string(forKey: DefaultsKey.activeCodexAccountId) {
                return ["codex": legacyCodex]
            }
            return [:]
        }

        var ids: [String: String]
        do {
            ids = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            providerActivationLog.error("Failed to decode persisted active provider ids: \(String(describing: error), privacy: .public)")
            if let legacyCodex = UserDefaults.standard.string(forKey: DefaultsKey.activeCodexAccountId) {
                return ["codex": legacyCodex]
            }
            return [:]
        }

        let staleKeys = ids.keys.filter { !activatableProviders.contains($0) }
        if !staleKeys.isEmpty {
            staleKeys.forEach { ids.removeValue(forKey: $0) }
            if let cleaned = try? JSONEncoder().encode(ids) {
                UserDefaults.standard.set(cleaned, forKey: DefaultsKey.activeProviderAccountIds)
            }
        }
        return ids
    }()

    @Published var activationResult: ActivationResult?
    @Published var codexActivationResult: CodexActivationResult?
    @Published var isAntigravityRestarting = false
    @Published var isAntigravitySwitching = false
    @Published var isCodexRestarting = false

    struct CodexRestartTargetCandidate: Equatable, Sendable {
        let activeKey: String?
        let authFileURL: URL
        let expectedIdentity: CodexAccountIdentity
        let email: String?
        let accountId: String?
    }

    private var confirmingSwitchProviderId: String?
    private var antigravityDetectionTask: Task<Void, Never>?
    private var codexGlobalStateReconcileTask: Task<Void, Never>?
    private var lastActivatedAntigravityTarget: AntigravityAccountSwitcher.RestartTargetCandidate?
    private var antigravitySwitchGeneration: UInt64 = 0
    private var lastActivatedCodexTarget: CodexRestartTargetCandidate?
    private var codexSwitchGeneration: UInt64 = 0

    let accountStore = AccountStore.shared
    let settings = AppSettings.shared

    var activeCodexAccountId: String? {
        get { activeProviderAccountIds["codex"] }
        set {
            activeProviderAccountIds["codex"] = newValue
            persistActiveIds()
        }
    }

    enum CodexActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    enum ActivationResult: Equatable {
        case success(String)
        case failure(String)
    }

    private init() {
        if CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
           let cliProxyPaths = try? CLIProxyPaths() {
            CodexLinkedCredentialCopies.registerDirectory(cliProxyPaths.authDirectory)
        }
    }

    private func persistActiveIds() {
        do {
            let data = try JSONEncoder().encode(activeProviderAccountIds)
            UserDefaults.standard.set(data, forKey: DefaultsKey.activeProviderAccountIds)
        } catch {
            providerActivationLog.error("Failed to persist active provider ids: \(String(describing: error), privacy: .public)")
        }
    }

    func canActivateProvider(_ providerId: String) -> Bool {
        Self.activatableProviders.contains(providerId)
    }

    static var remoteViewOnlyLabel: String { L("From remote · view only", "来自远程 · 仅查看") }

    /// 本机是否存有该账号可写入的认证文件——切换就是把它写进 ~/.codex 或 ~/.gemini。
    func hasLocalAuthSource(for entry: ProviderAccountEntry) -> Bool {
        resolveManagedSource(entry: entry) != nil
    }

    /// 远程后端模式下本机没有凭据的账号：只有远程共享的额度快照，界面标注「来自远程 · 仅查看」、不提供切换。
    /// 本地模式维持原行为（缺凭据时点切换会提示重新连接）。
    func isRemoteViewOnly(_ entry: ProviderAccountEntry) -> Bool {
        settings.backendMode == "remote"
            && canActivateProvider(entry.providerId)
            && !hasLocalAuthSource(for: entry)
    }

    func isSwitchingDisabled(for providerId: String) -> Bool {
        if confirmingSwitchProviderId == providerId { return true }
        switch providerId {
        case "antigravity":
            return isAntigravityRestarting || isAntigravitySwitching
        case "codex":
            return isCodexRestarting
        default:
            return false
        }
    }

    /// 各处「切换 / 激活」入口的统一判定。
    func canSwitch(to entry: ProviderAccountEntry) -> Bool {
        canActivateProvider(entry.providerId)
            && !isRemoteViewOnly(entry)
            && !isSwitchingDisabled(for: entry.providerId)
    }

    /// 互斥：Codex 代理接管 ~/.codex/config.toml 时调用，把当前 Codex 订阅账号标记为未激活，
    /// 保证账号轨道与代理轨道在 UI 与用量统计上互斥（不改动 auth.json 内容）。
    func markCodexSubscriptionInactiveForProxy() {
        codexSwitchGeneration &+= 1
        lastActivatedCodexTarget = nil
        guard activeProviderAccountIds["codex"] != nil else { return }
        activeProviderAccountIds["codex"] = nil
        persistActiveIds()
        providerActivationLog.info("Codex subscription account marked inactive due to proxy activation")
    }

    @MainActor
    @discardableResult
    func activateAccount(entry: ProviderAccountEntry) async throws -> Bool {
        if entry.providerId == "antigravity" {
            let msg = settings.t(
                "Antigravity IDE account switching is disabled to protect your Google account from TOS bans. Switch accounts inside Antigravity IDE directly.",
                "为防止触发 Google 账号封禁，已禁用 Antigravity 账号切换。请在 Antigravity IDE 内直接切换账号。"
            )
            activationResult = .failure(msg)
            throw ProviderError("antigravity_switch_disabled", msg)
        }
        if isRemoteViewOnly(entry) {
            let msg = settings.t(
                "This account comes from the remote device and is view-only here.",
                "该账号来自远程，只能查看额度，不能在本机切换。"
            )
            activationResult = .failure(msg)
            if entry.providerId == "codex" { codexActivationResult = .failure(msg) }
            throw ProviderError("remote_view_only", msg)
        }
        if isSwitchingDisabled(for: entry.providerId) {
            let msg = settings.t(
                "Codex is currently restarting. Please wait for it to finish.",
                "Codex 正在重启，请等待完成后再切换。"
            )
            if entry.providerId == "codex" {
                codexActivationResult = .failure(msg)
            }
            activationResult = .failure(msg)
            throw ProviderError("restart_in_progress", msg)
        }
        confirmingSwitchProviderId = entry.providerId
        defer { confirmingSwitchProviderId = nil }
        let bundleID = entry.providerId == "codex" ? Self.codexBundleIdentifier : nil
        let isRunning = bundleID.map {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0).contains { !$0.isTerminated }
        } ?? false
        if entry.providerId == "codex", Self.codexUsesKeyring() {
            throw ProviderError("codex_keyring_storage", L(
                "Codex uses keychain/auto credential storage. Set cli_auth_credentials_store = \"file\" and sign in again before switching files.",
                "Codex 当前使用钥匙串/自动凭据存储。请先设置 cli_auth_credentials_store = \"file\" 并重新登录。",
                "Codex đang dùng lưu trữ Keychain hoặc auto. Đặt cli_auth_credentials_store = \"file\" rồi đăng nhập lại trước khi chuyển bằng tệp."
            ))
        }
        let verifiedBundles: Set<String> = entry.providerId == "codex" ? Self.verifiedCodexAppBundlePaths() : []
        let externalCLI = entry.providerId == "codex" ? await Task.detached {
            Self.hasExternalCodexProcess(verifiedBundlePaths: verifiedBundles)
        }.value : false
        if isRunning || externalCLI {
            let alert = NSAlert()
            alert.messageText = isRunning
                ? L("Switch & Restart?", "切换并重启？", "Chuyển và khởi động lại?")
                : L("External Codex CLI is running", "外部 Codex CLI 正在运行", "Codex CLI bên ngoài đang chạy")
            alert.informativeText = L(
                "Switch to \(entry.accountPrimaryLabel). The app must quit before credentials are changed.",
                "切换到 \(entry.accountPrimaryLabel)。更改凭据前必须退出应用。",
                "Chuyển sang \(entry.accountPrimaryLabel). Ứng dụng phải thoát trước khi thay thông tin đăng nhập."
            ) + (externalCLI ? "\n" + Self.externalCodexWarning : "")
            alert.addButton(withTitle: isRunning ? L("Switch & Restart", "切换并重启", "Chuyển và khởi động lại") : L("Switch", "切换", "Chuyển"))
            alert.addButton(withTitle: L("Cancel", "取消", "Hủy"))
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
        }
        try Task.checkCancellation()
        switch entry.providerId {
        case "codex":
            if isRunning {
                do {
                    try await restartCodexApp(switchingTo: entry)
                } catch {
                    let msg = SensitiveDataRedactor.redactedMessage(for: error)
                    activationResult = .failure(msg)
                    codexActivationResult = .failure(msg)
                    throw error
                }
            } else {
                try activateCodexAccount(entry: entry)
            }
        case "gemini":
            try activateGeminiAccount(entry: entry)
        default:
            break
        }
        if externalCLI {
            activationResult = .success(Self.externalCodexWarning)
            codexActivationResult = .success(Self.externalCodexWarning)
        }
        return true
    }

    private static var externalCodexWarning: String {
        L("External Codex CLI/daemon may still use the previous account. Restart that terminal or daemon; AIUsage does not stop unrelated sessions.",
          "外部 Codex CLI/守护进程可能仍使用旧账号。请重启对应终端或守护进程；AIUsage 不会停止无关会话。",
          "Codex CLI/daemon bên ngoài có thể vẫn dùng tài khoản cũ. Khởi động lại terminal hoặc daemon đó; AIUsage không dừng phiên khác.")
    }

    static func codexUsesKeyring(configPath: String = "~/.codex/config.toml") -> Bool {
        let path = NSString(string: configPath).expandingTildeInPath
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return codexConfigUsesKeyring(text)
    }

    static func codexConfigUsesKeyring(_ configText: String) -> Bool {
        configText.range(
            of: #"(?m)^\s*cli_auth_credentials_store\s*=\s*["'](?:keyring|auto)["']\s*(?:#.*)?$"#,
            options: .regularExpression
        ) != nil
    }

    nonisolated static func readBundleIdentifier(at bundleURL: URL) -> String? {
        let infoPlistURL = bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Info.plist", isDirectory: false)
        guard let data = try? Data(contentsOf: infoPlistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let bundleID = (plist["CFBundleIdentifier"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return nil
        }
        return bundleID
    }

    nonisolated static func isVerifiedCodexBundleURL(_ bundleURL: URL) -> Bool {
        readBundleIdentifier(at: bundleURL) == codexBundleIdentifier
    }

    static func verifiedCodexAppBundlePaths(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        systemApplicationsDirectory: String = "/Applications",
        runningBundleURLs: [URL]? = nil,
        workspaceBundleURL: (() -> URL?)? = nil
    ) -> Set<String> {
        var paths = Set<String>()
        func insertVerified(_ url: URL?) {
            guard let url else { return }
            let standardized = url.standardizedFileURL
            let resolved = url.resolvingSymlinksInPath()
            guard isVerifiedCodexBundleURL(resolved) || isVerifiedCodexBundleURL(standardized) else {
                return
            }
            paths.insert(standardized.path)
            paths.insert(resolved.path)
        }
        let activeRunningURLs = runningBundleURLs ?? NSRunningApplication
            .runningApplications(withBundleIdentifier: codexBundleIdentifier)
            .filter { !$0.isTerminated }
            .compactMap(\.bundleURL)
        for url in activeRunningURLs {
            insertVerified(url)
        }
        insertVerified(resolveInstalledCodexAppURL(
            homeDirectory: homeDirectory,
            systemApplicationsDirectory: systemApplicationsDirectory,
            runningBundleURLs: activeRunningURLs,
            workspaceBundleURL: workspaceBundleURL
        ))
        return paths
    }

    nonisolated static func extractCodexPIDs(fromPsCommOutput output: String) -> [String] {
        output.split(separator: "\n").compactMap { rawLine in
            let parts = rawLine.split(whereSeparator: \.isWhitespace)
            guard parts.count == 2, parts[1] == "codex", Int(parts[0]) != nil else { return nil }
            return String(parts[0])
        }
    }

    nonisolated static func isBundledCodexExecutablePath(
        _ rawPath: String,
        verifiedBundlePaths: Set<String> = []
    ) -> Bool {
        // shortcut: requires verified local com.openai.codex bundle provenance; treat unknown/relocated unverified bundles as external CLI
        guard !verifiedBundlePaths.isEmpty else { return false }
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return false }
        let standardized = URL(fileURLWithPath: trimmed).standardizedFileURL.path
        guard (standardized as NSString).lastPathComponent == "codex" else { return false }

        return verifiedBundlePaths.contains { rawBundle in
            let trimmedBundle = rawBundle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmedBundle.hasPrefix("/") else { return false }
            let bundle = URL(fileURLWithPath: trimmedBundle).standardizedFileURL.path
            guard bundle.hasSuffix(".app") else { return false }
            return standardized.hasPrefix(bundle + "/Contents/Resources/codex-cli/")
                || standardized == bundle + "/Contents/MacOS/codex"
                || standardized.hasPrefix(bundle + "/Contents/Helpers/")
        }
    }

    nonisolated static func isBundledCodexAppCommandLine(
        _ rawLine: Substring,
        verifiedBundlePaths: Set<String> = []
    ) -> Bool {
        guard !verifiedBundlePaths.isEmpty else { return false }
        let trimmed = rawLine.drop(while: \.isWhitespace)
        guard let execRange = trimmed.range(
            of: #"^(/[^\r\n]+?\.app/Contents/(?:Resources/codex-cli/(?:CodexCLI\.app/Contents/MacOS/)?codex|Helpers/[^\r\n]+?/codex|MacOS/codex))(?=\s|$)"#,
            options: .regularExpression
        ) else {
            return false
        }
        let candidateExec = String(trimmed[execRange])
        let firstToken = String(trimmed.prefix(while: { !$0.isWhitespace }))
        if firstToken != candidateExec {
            if firstToken == "codex"
                || firstToken.hasSuffix("/codex")
                || candidateExec.contains("/codex ")
                || candidateExec.contains(" /")
                || candidateExec.contains(" -")
                || candidateExec.contains(" ~") {
                return false
            }
        }
        return isBundledCodexExecutablePath(candidateExec, verifiedBundlePaths: verifiedBundlePaths)
    }

    nonisolated static func hasExternalCodexCommandLines(
        _ output: String,
        expectedCount: Int? = nil,
        verifiedBundlePaths: Set<String> = []
    ) -> Bool {
        let lines = output.split(separator: "\n").compactMap { rawLine -> Substring? in
            let trimmed = rawLine.drop(while: \.isWhitespace)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let expectedCount, expectedCount > 0, lines.count < expectedCount {
            return true
        }
        return lines.contains { !isBundledCodexAppCommandLine($0, verifiedBundlePaths: verifiedBundlePaths) }
    }

    private nonisolated static func resolveProcessExecutablePath(pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * 1024)
        let length = Darwin.proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private nonisolated static func runPsOutput(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.terminationHandler = { _ in }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated static func hasExternalCodexProcess(
        verifiedBundlePaths: Set<String> = []
    ) -> Bool {
        guard let commOutput = runPsOutput(["-acxo", "pid=,comm="]) else { return true }
        let pids = extractCodexPIDs(fromPsCommOutput: commOutput)
        guard !pids.isEmpty else { return false }
        guard !verifiedBundlePaths.isEmpty else { return true }

        for pidStr in pids {
            guard let pid = Int32(pidStr) else { return true }
            if let execPath = resolveProcessExecutablePath(pid: pid) {
                if !isBundledCodexExecutablePath(execPath, verifiedBundlePaths: verifiedBundlePaths) {
                    return true
                }
                continue
            }
            if Darwin.kill(pid, 0) != 0 && errno == ESRCH {
                continue
            }
            guard let argsOutput = runPsOutput(["-ww", "-o", "args=", "-p", pidStr]),
                  !hasExternalCodexCommandLines(
                    argsOutput,
                    expectedCount: 1,
                    verifiedBundlePaths: verifiedBundlePaths
                  ) else {
                return true
            }
        }
        return false
    }

    /// 用户主动停用某账号（清除该 provider 的「当前激活」标记，不改动 auth.json 内容）。
    /// 与节点开关「关」对齐：关掉后该 provider 无激活账号（账号轨道与代理轨道仍互斥）。
    func deactivateAccount(entry: ProviderAccountEntry) {
        guard !isSwitchingDisabled(for: entry.providerId) else { return }
        guard isActiveAccount(entry) else { return }
        if entry.providerId == "antigravity" {
            antigravitySwitchGeneration &+= 1
            lastActivatedAntigravityTarget = nil
        } else if entry.providerId == "codex" {
            codexSwitchGeneration &+= 1
            lastActivatedCodexTarget = nil
        }
        activeProviderAccountIds[entry.providerId] = nil
        persistActiveIds()
        providerActivationLog.info("Deactivated \(entry.providerId, privacy: .public) account by user toggle")
    }

    func isActiveAccount(_ entry: ProviderAccountEntry) -> Bool {
        guard let activeId = activeProviderAccountIds[entry.providerId]?.lowercased() else { return false }

        if entry.providerId == "codex" {
            let identity = entry.liveProvider.map { AccountIdentityPolicy.codexIdentity(for: $0) }
                ?? entry.storedAccount.map { AccountIdentityPolicy.codexIdentity(for: $0) }
            return identity?.key != nil && identity?.key == activeId
        }

        if entry.providerId == "antigravity" {
            if let entryPath = entry.storedAccount?.sourceFilePath ?? entry.liveProvider?.sourceFilePath,
               AccountCredentialStore.normalizedAuthFilePath(entryPath) == activeId {
                return true
            }
            if !activeId.contains("/"),
               let email = entry.accountEmail?.lowercased().nilIfBlank,
               email == activeId {
                return true
            }
            return false
        }

        if AccountIdentityPolicy.isMultiWorkspace(entry.providerId) {
            let entryPath = entry.storedAccount?.sourceFilePath ?? entry.liveProvider?.sourceFilePath
            guard let entryPath else { return false }
            return AccountCredentialStore.normalizedAuthFilePath(entryPath) == activeId
        }

        let entryAccountId = (entry.storedAccount?.accountId ?? entry.liveProvider?.accountId)?.lowercased().nilIfBlank
        if let entryAccountId, entryAccountId == activeId {
            return true
        }

        let email = entry.accountEmail?.lowercased().nilIfBlank
        return email != nil && email == activeId
    }

    func isActiveCodexAccount(_ entry: ProviderAccountEntry) -> Bool {
        isActiveAccount(entry)
    }

    // MARK: Codex activation

    func activateCodexAccount(entry: ProviderAccountEntry) throws {
        guard !Self.codexUsesKeyring() else {
            throw ProviderError("codex_keyring_storage", "Codex uses keyring storage. File-only switching is disabled.")
        }
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier).contains(where: { !$0.isTerminated }) else {
            throw ProviderError("codex_still_running", "Quit Codex before changing its credentials.")
        }
        let fm = FileManager.default
        let codexDir = NSString(string: "~/.codex").expandingTildeInPath
        let targetPath = "\(codexDir)/auth.json"
        try Self.validateNativeCodexWriteTargets(targetDir: codexDir, targetPath: targetPath)

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel
        let accountId = entry.storedAccount?.accountId
            ?? entry.liveProvider?.accountId

        let resolved = resolveManagedSource(entry: entry)
        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToCodexNativeFormat(sourceData)
        let nativeJSON = try JSONSerialization.jsonObject(with: nativeData) as? [String: Any] ?? [:]
        let nativeIdentity = CodexAccountIdentity(authJSON: nativeJSON)
        let expectedIdentity = entry.liveProvider.map { AccountIdentityPolicy.codexIdentity(for: $0) }
            ?? entry.storedAccount.map { AccountIdentityPolicy.codexIdentity(for: $0) }
        guard let expectedIdentity, expectedIdentity.matches(nativeIdentity) else {
            throw ProviderError("account_mismatch", settings.t(
                "The auth file no longer belongs to this account. Reconnect it before switching.",
                "认证文件已不属于此账号，请重新连接后再切换。"
            ))
        }

        let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: nativeData,
            managedSourceData: sourceData,
            expectedIdentity: expectedIdentity,
            candidatePaths: [targetPath, "\(targetPath).bak"],
            fm: fm
        )
        guard reconciled.isValidBaseline,
              expectedIdentity.matches(reconciled.identity) else {
            let msg = settings.t(
                "The auth file no longer belongs to this account. Reconnect it before switching.",
                "认证文件已不属于此账号，请重新连接后再切换。"
            )
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("account_mismatch", msg)
        }
        let effectiveData = reconciled.nativeData
        let effectiveJSON = reconciled.nativeJSON
        let effectiveIdentity = reconciled.identity

        let targetOwnerHash = CodexAccountIdentity.rendererOwnerHash(fromAuthJSON: effectiveJSON)
        let knownOwnerHashes = allKnownCodexOwnerHashes(excluding: targetOwnerHash)

        // 目标账号验证完成后再解除代理接管，避免坏文件让当前可用路由先被停掉。
        // 停进程走通知（异步），但文件必须在写账号之前同步归位，否则异步 restore 会覆盖新账号。
        // 先完成 config.toml 与 auth.json 写入，成功后才更新 .codex-global-state.json，避免切换失败时污染 renderer 状态。
        try Self.validateNativeCodexWriteTargets(targetDir: codexDir, targetPath: targetPath)
        NotificationCenter.default.post(name: .codexSubscriptionAccountActivating, object: nil)
        try CodexConfigManager.shared.restore()
        CodexCredentialPolicy.flushLiveAuthToManagedCopies(
            candidatePaths: [targetPath, "\(targetPath).bak"],
            excludingIdentity: reconciled.identity,
            loadCredentials: { AccountCredentialStore.shared.loadCredentials(for: "codex") },
            fm: fm
        )
        try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: effectiveData, fm: fm)
        let managedURL = URL(fileURLWithPath: resolved)
        if reconciled.adoptedLiveCandidate,
           let healedManagedData = reconciled.healedManagedData,
           !CodexCredentialPolicy.isLegacyCPAArchivePath(managedURL.path),
           managedURL.standardizedFileURL.path != URL(fileURLWithPath: targetPath).standardizedFileURL.path,
           fm.contents(atPath: resolved) == sourceData {
            try? healedManagedData.write(to: managedURL, options: .atomic)
        }

        let isCodexRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")
            .contains { !$0.isTerminated }
        let syncOutcome = CodexGlobalStateSync.syncWorkspaceProjects(
            codexDir: codexDir,
            targetOwnerHash: targetOwnerHash,
            additionalOwnerHashes: knownOwnerHashes,
            transitionOwner: !isCodexRunning
        )

        codexSwitchGeneration &+= 1
        lastActivatedCodexTarget = CodexRestartTargetCandidate(
            activeKey: effectiveIdentity.key,
            authFileURL: managedURL,
            expectedIdentity: expectedIdentity,
            email: email ?? effectiveIdentity.email,
            accountId: accountId ?? effectiveIdentity.accountId
        )

        scheduleCodexGlobalStateReconciliation(
            codexDir: codexDir,
            targetOwnerHash: targetOwnerHash,
            additionalOwnerHashes: knownOwnerHashes,
            syncOutcome: syncOutcome
        )

        activeProviderAccountIds["codex"] = effectiveIdentity.key
        persistActiveIds()

        let label = email ?? accountId ?? "Codex"
        let msg = settings.t(
            "Switched to \(label)",
            "已切换到 \(label)"
        )
        activationResult = .success(msg)
        codexActivationResult = .success(msg)
    }

    nonisolated static let codexBundleIdentifier = "com.openai.codex"

    var isCodexAppInstalled: Bool {
        Self.resolveInstalledCodexAppURL() != nil
    }

    static func resolveInstalledCodexAppURL(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        systemApplicationsDirectory: String = "/Applications",
        runningBundleURLs: [URL]? = nil,
        workspaceBundleURL: (() -> URL?)? = nil
    ) -> URL? {
        let activeRunningURLs = runningBundleURLs ?? NSRunningApplication
            .runningApplications(withBundleIdentifier: codexBundleIdentifier)
            .filter { !$0.isTerminated }
            .compactMap(\.bundleURL)
        if let runningURL = activeRunningURLs.first(where: { isVerifiedCodexBundleURL($0) }) {
            return runningURL
        }
        let registeredURL: URL? = if let workspaceBundleURL {
            workspaceBundleURL()
        } else {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: codexBundleIdentifier)
        }
        if let registeredURL, isVerifiedCodexBundleURL(registeredURL) {
            return registeredURL
        }
        let fm = FileManager.default
        let candidatePaths = [
            "\(systemApplicationsDirectory)/Codex.app",
            "\(homeDirectory)/Applications/Codex.app",
            "\(systemApplicationsDirectory)/ChatGPT.app",
            "\(homeDirectory)/Applications/ChatGPT.app"
        ]
        for path in candidatePaths where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            if isVerifiedCodexBundleURL(url) {
                return url
            }
        }
        return nil
    }

    static func selectCodexRestartTarget(
        lastActivated: CodexRestartTargetCandidate?,
        currentActiveKey: String?,
        fallback: CodexRestartTargetCandidate?,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> CodexRestartTargetCandidate? {
        let normalizedCurrentKey = currentActiveKey?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let hasCurrentKey = normalizedCurrentKey?.isEmpty == false

        if let lastActivated, fileExists(lastActivated.authFileURL.path) {
            let lastKey = lastActivated.activeKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !hasCurrentKey || (lastKey?.isEmpty == false && lastKey == normalizedCurrentKey) {
                return lastActivated
            }
        }

        if let fallback, fileExists(fallback.authFileURL.path) {
            let fallbackKey = fallback.activeKey?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if !hasCurrentKey
                || (fallbackKey?.isEmpty == false && fallbackKey == normalizedCurrentKey)
                || lastActivated == nil {
                return fallback
            }
        }

        if let lastActivated, fileExists(lastActivated.authFileURL.path) {
            return lastActivated
        }
        return nil
    }

    func reapplyCodexAccountForRestart(fallbackEntry: ProviderAccountEntry?) async throws {
        let hasTarget = await MainActor.run {
            self.activeProviderAccountIds["codex"] != nil || self.lastActivatedCodexTarget != nil
        }
        guard hasTarget else { return }
        guard !Self.codexUsesKeyring() else {
            throw ProviderError("codex_keyring_storage", "Codex uses keychain/auto credential storage. File-only switching is disabled.")
        }
        let fm = FileManager.default
        let fallbackCandidate: CodexRestartTargetCandidate? = {
            guard let fallbackEntry,
                  fallbackEntry.providerId == "codex",
                  !isRemoteViewOnly(fallbackEntry),
                  hasLocalAuthSource(for: fallbackEntry),
                  let resolved = resolveManagedSource(entry: fallbackEntry),
                  fm.fileExists(atPath: resolved),
                  let expectedIdentity = fallbackEntry.liveProvider.map({ AccountIdentityPolicy.codexIdentity(for: $0) })
                      ?? fallbackEntry.storedAccount.map({ AccountIdentityPolicy.codexIdentity(for: $0) }) else {
                return nil
            }
            let email = fallbackEntry.accountEmail
                ?? fallbackEntry.storedAccount?.email
                ?? fallbackEntry.liveProvider?.accountLabel
            let accountId = fallbackEntry.storedAccount?.accountId
                ?? fallbackEntry.liveProvider?.accountId
            return CodexRestartTargetCandidate(
                activeKey: expectedIdentity.key,
                authFileURL: URL(fileURLWithPath: resolved),
                expectedIdentity: expectedIdentity,
                email: email,
                accountId: accountId
            )
        }()

        for _ in 0..<3 {
            let (genBefore, selected) = await MainActor.run { () -> (UInt64, CodexRestartTargetCandidate?) in
                guard self.activeProviderAccountIds["codex"] != nil || self.lastActivatedCodexTarget != nil else {
                    return (self.codexSwitchGeneration, nil)
                }
                let candidate = Self.selectCodexRestartTarget(
                    lastActivated: self.lastActivatedCodexTarget,
                    currentActiveKey: self.activeProviderAccountIds["codex"],
                    fallback: fallbackCandidate,
                    fileExists: { FileManager.default.fileExists(atPath: $0) }
                )
                return (self.codexSwitchGeneration, candidate)
            }
            guard let selected else { return }

            let sourceData = try Data(contentsOf: selected.authFileURL)
            let nativeData = try convertToCodexNativeFormat(sourceData)
            let nativeJSON = try JSONSerialization.jsonObject(with: nativeData) as? [String: Any] ?? [:]
            let nativeIdentity = CodexAccountIdentity(authJSON: nativeJSON)
            guard selected.expectedIdentity.matches(nativeIdentity) else {
                throw ProviderError("account_mismatch", settings.t(
                    "The auth file no longer belongs to this account. Reconnect it before switching.",
                    "认证文件已不属于此账号，请重新连接后再切换。"
                ))
            }

            let codexDir = NSString(string: "~/.codex").expandingTildeInPath
            let targetPath = "\(codexDir)/auth.json"
            try Self.validateNativeCodexWriteTargets(targetDir: codexDir, targetPath: targetPath)
            let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(
                managedNativeData: nativeData,
                managedSourceData: sourceData,
                expectedIdentity: selected.expectedIdentity,
                candidatePaths: [targetPath, "\(targetPath).bak"],
                fm: fm
            )
            guard reconciled.isValidBaseline,
                  selected.expectedIdentity.matches(reconciled.identity) else {
                throw ProviderError("account_mismatch", settings.t(
                    "The auth file no longer belongs to this account. Reconnect it before switching.",
                    "认证文件已不属于此账号，请重新连接后再切换。"
                ))
            }
            let effectiveData = reconciled.nativeData
            let effectiveJSON = reconciled.nativeJSON

            let targetOwnerHash = CodexAccountIdentity.rendererOwnerHash(fromAuthJSON: effectiveJSON)
            let knownOwnerHashes = await MainActor.run { self.allKnownCodexOwnerHashes(excluding: targetOwnerHash) }

            let genMid = await MainActor.run { self.codexSwitchGeneration }
            if genMid != genBefore { continue }

            try Self.validateNativeCodexWriteTargets(targetDir: codexDir, targetPath: targetPath)
            try CodexConfigManager.shared.restore()
            try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: effectiveData, fm: fm)
            if reconciled.adoptedLiveCandidate,
               let healedManagedData = reconciled.healedManagedData,
               !CodexCredentialPolicy.isLegacyCPAArchivePath(selected.authFileURL.path),
               selected.authFileURL.standardizedFileURL.path != URL(fileURLWithPath: targetPath).standardizedFileURL.path,
               fm.contents(atPath: selected.authFileURL.path) == sourceData {
                try? healedManagedData.write(to: selected.authFileURL, options: .atomic)
            }
            _ = CodexGlobalStateSync.syncWorkspaceProjects(
                codexDir: codexDir,
                targetOwnerHash: targetOwnerHash,
                additionalOwnerHashes: knownOwnerHashes,
                transitionOwner: true
            )

            let genAfter = await MainActor.run { self.codexSwitchGeneration }
            if genAfter == genBefore {
                let effectiveIdentity = reconciled.identity
                await MainActor.run {
                    self.lastActivatedCodexTarget = CodexRestartTargetCandidate(
                        activeKey: effectiveIdentity.key ?? selected.activeKey,
                        authFileURL: selected.authFileURL,
                        expectedIdentity: selected.expectedIdentity,
                        email: effectiveIdentity.email ?? selected.email,
                        accountId: effectiveIdentity.accountId ?? selected.accountId
                    )
                }
                return
            }
        }
    }

    private static func isCodexChildHelperRunning(appBundlePath: String) -> Bool {
        let pgrepPath = "/usr/bin/pgrep"
        guard FileManager.default.isExecutableFile(atPath: pgrepPath) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pgrepPath)
        process.arguments = ["-f", "\(appBundlePath)/Contents/Resources/codex-cli/"]
        process.terminationHandler = { _ in }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Darwin.usleep(5_000)
        }
        if process.isRunning {
            process.terminate()
            return false
        }
        return process.terminationStatus == 0
    }

    private static func terminateOrphanedCodexChildHelpers(appBundlePath: String) {
        let pkillPath = "/usr/bin/pkill"
        guard FileManager.default.isExecutableFile(atPath: pkillPath) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pkillPath)
        process.arguments = ["-TERM", "-f", "\(appBundlePath)/Contents/Resources/codex-cli/"]
        process.terminationHandler = { _ in }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try? process.run()
        let deadline = Date().addingTimeInterval(0.5)
        while process.isRunning && Date() < deadline {
            Darwin.usleep(5_000)
        }
        if process.isRunning {
            process.terminate()
        }
    }

    @MainActor
    func restartCodexApp(
        fallbackEntry: ProviderAccountEntry? = nil,
        switchingTo: ProviderAccountEntry? = nil,
        // shortcut: 20s graceful quit cap covers CUA PIP + SQLite/external-drive flush, upgrade to KVO + progress UI if needed
        timeoutSeconds: TimeInterval = 20.0,
        pollIntervalMilliseconds: Int = 150
    ) async throws {
        let startedAt = Date()
        func phase(_ stage: String) {
            providerActivationLog.info("Codex restart phase=\(stage, privacy: .public)")
        }
        func failure(_ stage: String, _ en: String, _ zh: String, underlying: Error? = nil) -> ProviderError {
            let elapsed = Date().timeIntervalSince(startedAt)
            // Only numeric OS codes are logged; auth errors can contain credential material.
            let systemCode = underlying.map { ($0 as NSError).code } ?? 0
            providerActivationLog.error("Codex restart failed phase=\(stage, privacy: .public) elapsed=\(elapsed, privacy: .public)s systemCode=\(systemCode, privacy: .public)")
            return ProviderError("codex_restart_" + stage, settings.t(en, zh))
        }
        guard !isCodexRestarting else {
            throw failure("busy", "Codex restart is already in progress.", "Codex 正在重启，请等待完成。")
        }
        isCodexRestarting = true
        defer { isCodexRestarting = false }

        codexGlobalStateReconcileTask?.cancel()
        codexGlobalStateReconcileTask = nil

        phase("resolve_app")
        guard let appURL = Self.resolveInstalledCodexAppURL() else {
            throw failure("resolve_app", "Could not locate the installed Codex app.", "找不到已安装的 Codex 应用。")
        }

        let checkRunning: () -> Bool = {
            NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
                .contains { !$0.isTerminated }
        }

        if checkRunning() {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
                .filter { !$0.isTerminated }
            phase("request_quit")
            let accepted = apps.allSatisfy { $0.terminate() }
            guard accepted else {
                throw failure("request_quit", "Codex did not accept the quit request. Check it for an open dialog or unfinished action.", "Codex 未接受退出请求，请检查是否有对话框或未完成的操作。")
            }
            phase("wait_for_quit")

            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline && checkRunning() {
                try? await Task.sleep(for: .milliseconds(pollIntervalMilliseconds))
            }
            guard !checkRunning() else {
                throw failure("wait_for_quit", "Timed out waiting for Codex to quit. It may still be closing; no new instance was opened.", "等待 Codex 退出超时。它可能仍在关闭，尚未启动新实例。")
            }
        }

        phase("wait_for_helpers")
        let appBundlePath = appURL.path
        let pollNs = UInt64(max(10, pollIntervalMilliseconds)) * 1_000_000
        let helperWaitSeconds = min(2.0, max(0.05, timeoutSeconds * 0.15))
        let helperPostTermSeconds = min(3.0, max(0.05, timeoutSeconds * 0.2))
        let helpersExited = await Task.detached(priority: .userInitiated) { () -> Bool in
            let waitDeadline = Date().addingTimeInterval(helperWaitSeconds)
            while Date() < waitDeadline && Self.isCodexChildHelperRunning(appBundlePath: appBundlePath) {
                try? await Task.sleep(nanoseconds: pollNs)
            }
            if Self.isCodexChildHelperRunning(appBundlePath: appBundlePath) {
                Self.terminateOrphanedCodexChildHelpers(appBundlePath: appBundlePath)
                let postTermDeadline = Date().addingTimeInterval(helperPostTermSeconds)
                while Date() < postTermDeadline && Self.isCodexChildHelperRunning(appBundlePath: appBundlePath) {
                    try? await Task.sleep(nanoseconds: pollNs)
                }
            }
            return !Self.isCodexChildHelperRunning(appBundlePath: appBundlePath)
        }.value
        guard helpersExited else {
            throw failure("wait_for_helpers", "Codex quit, but its CLI helpers have not exited. Relaunch was stopped to protect account state.", "Codex 已退出，但 CLI 辅助进程尚未结束。为保护账号状态，已停止重新启动。")
        }

        phase("reapply_account")
        do {
            if let switchingTo {
                try activateCodexAccount(entry: switchingTo)
            } else {
                try await reapplyCodexAccountForRestart(fallbackEntry: fallbackEntry)
            }
        } catch {
            throw failure("reapply_account", "Codex quit, but the selected account could not be reapplied safely. Reconnect or select the account again before retrying.", "Codex 已退出，但无法安全重新应用所选账号。请重新连接或选择账号后重试。", underlying: error)
        }

        phase("launch_app")
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            phase("completed")
        } catch {
            throw failure("launch_app", "Account preparation completed, but macOS could not reopen Codex. Try opening the app manually.", "账号准备完成，但 macOS 无法重新打开 Codex。请尝试手动打开应用。", underlying: error)
        }
    }

    @MainActor
    func restartAntigravityApp(fallbackEntry: ProviderAccountEntry? = nil, switchingTo: ProviderAccountEntry? = nil) async -> Bool {
        guard switchingTo == nil else {
            let msg = settings.t(
                "Antigravity IDE account switching is disabled to protect your Google account from TOS bans. Switch accounts inside Antigravity IDE directly.",
                "为防止触发 Google 账号封禁，已禁用 Antigravity 账号切换。请在 Antigravity IDE 内直接切换账号。"
            )
            activationResult = .failure(msg)
            return false
        }
        guard !isAntigravityRestarting else { return false }
        isAntigravityRestarting = true
        defer { isAntigravityRestarting = false }

        return await AntigravityAccountSwitcher.restartAntigravityApp(reapplyBeforeRelaunch: nil)
    }

    private func allKnownCodexOwnerHashes(excluding excludedHash: String? = nil) -> Set<String> {
        let fm = FileManager.default
        let codexDir = NSString(string: "~/.codex").expandingTildeInPath
        var candidatePaths: Set<String> = [
            "\(codexDir)/auth.json",
            "\(codexDir)/auth.json.bak"
        ]
        for account in accountStore.accountRegistry where account.providerId == "codex" {
            if let path = account.sourceFilePath?.nilIfBlank {
                candidatePaths.insert(NSString(string: path).expandingTildeInPath)
            }
        }
        for credential in AccountCredentialStore.shared.loadCredentials(for: "codex") {
            if credential.authMethod == .authFile, let path = credential.credential.nilIfBlank {
                candidatePaths.insert(NSString(string: path).expandingTildeInPath)
            }
            if let path = credential.metadata["sourcePath"]?.nilIfBlank {
                candidatePaths.insert(NSString(string: path).expandingTildeInPath)
            }
        }

        var hashes: Set<String> = []
        for path in candidatePaths where fm.fileExists(atPath: path) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hash = CodexAccountIdentity.rendererOwnerHash(fromAuthJSON: json) else {
                continue
            }
            hashes.insert(hash)
        }
        if let excludedHash {
            hashes.remove(excludedHash)
        }
        return hashes
    }

    private func scheduleCodexGlobalStateReconciliation(
        codexDir: String,
        targetOwnerHash: String?,
        additionalOwnerHashes: Set<String>,
        syncOutcome: CodexGlobalStateSync.SyncOutcome
    ) {
        codexGlobalStateReconcileTask?.cancel()
        codexGlobalStateReconcileTask = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }

            // Non-destructive follow-up sync: preserves local-projects on disk if a live Codex file watcher
            // mutated .codex-global-state.json, without terminating Codex Desktop behind the user's back.
            // Process termination + owner transition + relaunch happens only when the user confirms Restart Codex.
            _ = await CodexGlobalStateSync.reconcileRunningCodexDesktop(
                codexDir: codexDir,
                targetOwnerHash: targetOwnerHash,
                additionalOwnerHashes: additionalOwnerHashes,
                syncOutcome: syncOutcome,
                isCodexRunning: {
                    await MainActor.run {
                        NSRunningApplication.runningApplications(withBundleIdentifier: Self.codexBundleIdentifier)
                            .contains { !$0.isTerminated }
                    }
                },
                requestTerminate: { false },
                relaunchCodex: { }
            )
        }
    }

    // MARK: Gemini activation

    func activateGeminiAccount(entry: ProviderAccountEntry) throws {
        let fm = FileManager.default
        let geminiDir = NSString(string: "~/.gemini").expandingTildeInPath
        let oauthCredsPath = "\(geminiDir)/oauth_creds.json"
        let googleAccountsPath = "\(geminiDir)/google_accounts.json"

        let email = entry.accountEmail
            ?? entry.storedAccount?.email
            ?? entry.liveProvider?.accountLabel

        let resolved = resolveManagedSource(entry: entry)

        guard let resolved, fm.fileExists(atPath: resolved) else {
            let msg = settings.t("Auth file not found for this account.", "找不到该账号的认证文件")
            activationResult = .failure(msg)
            throw ProviderError("source_not_found", msg)
        }

        let sourceData = try Data(contentsOf: URL(fileURLWithPath: resolved))
        let nativeData = try convertToGeminiNativeFormat(sourceData)

        try writeAuthFileWithBackup(targetDir: geminiDir, targetPath: oauthCredsPath, data: nativeData, fm: fm)

        if let email {
            try updateGeminiActiveAccount(googleAccountsPath: googleAccountsPath, email: email, fm: fm)
        }

        activeProviderAccountIds["gemini"] = email
        persistActiveIds()

        let label = email ?? "Account"
        let msg = settings.t("Switched to \(label)", "已切换到 \(label)")
        activationResult = .success(msg)
    }

    private func convertToGeminiNativeFormat(_ data: Data) throws -> Data {
        try GeminiCredentialBridge.makeNativePayload(from: data)
    }

    private func updateGeminiActiveAccount(googleAccountsPath: String, email: String, fm: FileManager) throws {
        var accounts: [String: Any]
        if let data = fm.contents(atPath: googleAccountsPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            accounts = json
        } else {
            accounts = [:]
        }

        let previousActive = accounts["active"] as? String
        var oldList = (accounts["old"] as? [String]) ?? []

        if let previousActive, previousActive != email, !oldList.contains(previousActive) {
            oldList.append(previousActive)
        }
        oldList.removeAll { $0 == email }

        accounts["active"] = email
        accounts["old"] = oldList

        let data = try JSONSerialization.data(withJSONObject: accounts, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: googleAccountsPath), options: .atomic)
    }

    // MARK: Antigravity activation

    @MainActor
    func activateAntigravityAccount(entry: ProviderAccountEntry) async throws {
        let msg = settings.t(
            "Antigravity IDE account switching is disabled to protect your Google account from TOS bans. Switch accounts inside Antigravity IDE directly.",
            "为防止触发 Google 账号封禁，已禁用 Antigravity 账号切换。请在 Antigravity IDE 内直接切换账号。"
        )
        activationResult = .failure(msg)
        throw ProviderError("antigravity_switch_disabled", msg)
    }

    func reapplyAntigravityAccountForRestart(fallbackEntry: ProviderAccountEntry?) async throws {
        let msg = settings.t(
            "Antigravity IDE account switching is disabled to protect your Google account from TOS bans. Switch accounts inside Antigravity IDE directly.",
            "为防止触发 Google 账号封禁，已禁用 Antigravity 账号切换。请在 Antigravity IDE 内直接切换账号。"
        )
        activationResult = .failure(msg)
        throw ProviderError("antigravity_switch_disabled", msg)
    }

    // MARK: Codex format conversion

    private func convertToCodexNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return data
        }

        var native: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": json["account_id"] ?? "",
                "id_token": json["id_token"] ?? ""
            ] as [String: Any],
            "last_refresh": json["last_refresh"] ?? SharedFormatters.iso8601String(from: Date())
        ]
        if let email = json["email"] as? String, !email.isEmpty {
            native["email"] = email
        }
        native["OPENAI_API_KEY"] = NSNull()

        return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
    }

    // MARK: Shared helpers

    static func validateNativeCodexWriteTargets(
        targetDir: String,
        targetPath: String,
        homeDirectory: String? = nil
    ) throws {
        for candidate in [targetDir, targetPath, "\(targetPath).bak"] {
            if CodexCredentialPolicy.isLegacyCPAArchivePath(candidate, homeDirectory: homeDirectory) {
                throw ProviderError(
                    "read_only_archive",
                    "Legacy CPA archive credentials are read-only while managed CPA is paused."
                )
            }
        }
    }

    func writeAuthFileWithBackup(targetDir: String, targetPath: String, data: Data, fm: FileManager, homeDirectory: String? = nil) throws {
        try Self.validateNativeCodexWriteTargets(targetDir: targetDir, targetPath: targetPath, homeDirectory: homeDirectory)
        if !fm.fileExists(atPath: targetDir) {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        let backupPath = "\(targetPath).bak"
        let existingTargetData = fm.contents(atPath: targetPath)
        let shouldUpdateBackup: Bool = {
            guard fm.fileExists(atPath: targetPath) else { return false }
            guard fm.fileExists(atPath: backupPath),
                  let incomingJSON = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let targetData = existingTargetData,
                  let targetJSON = try? JSONSerialization.jsonObject(with: targetData) as? [String: Any],
                  let backupData = fm.contents(atPath: backupPath),
                  let backupJSON = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any] else {
                return true
            }
            let incomingIdentity = CodexAccountIdentity(authJSON: incomingJSON)
            let targetIdentity = CodexAccountIdentity(authJSON: targetJSON)
            let backupIdentity = CodexAccountIdentity(authJSON: backupJSON)
            guard incomingIdentity.key != nil, targetIdentity.key != nil, backupIdentity.key != nil else {
                return true
            }
            // Keep an existing foreign outgoing backup intact when re-writing the active account (e.g., Restart Codex).
            return !CodexCredentialPolicy.identitiesMatchExactly(incomingIdentity, targetIdentity)
                || CodexCredentialPolicy.identitiesMatchExactly(incomingIdentity, backupIdentity)
        }()
        if shouldUpdateBackup {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: targetPath, toPath: backupPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            // Restore only the pre-write target snapshot; never overwrite target with a preserved foreign .bak.
            if let existingTargetData, fm.contents(atPath: targetPath) != existingTargetData {
                try? existingTargetData.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
            }
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            let msg = settings.t("Switch failed: \(redactedError)", "切换失败：\(redactedError)")
            activationResult = .failure(msg)
            throw error
        }
    }

    private func resolveManagedSource(entry: ProviderAccountEntry) -> String? {
        let fm = FileManager.default

        let credentials = accountStore.matchingCredentials(for: entry)
        if let credential = credentials.first {
            let candidatePaths: [String?] = [
                credential.authMethod == .authFile ? credential.credential : nil,
                credential.metadata["sourcePath"]
            ]
            for p in candidatePaths.compactMap({ $0?.nilIfBlank }) {
                let expanded = NSString(string: p).expandingTildeInPath
                if fm.fileExists(atPath: expanded) { return expanded }
            }
        }

        return nil
    }

    // MARK: Detection

    private func applyDetectedActiveId(_ detectedId: String?, for providerId: String, reason: String) {
        let normalizedDetectedId = detectedId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        let previousDetectedId = activeProviderAccountIds[providerId]

        if let normalizedDetectedId {
            guard normalizedDetectedId != previousDetectedId else { return }
            activeProviderAccountIds[providerId] = normalizedDetectedId
            persistActiveIds()
            return
        }

        guard previousDetectedId != nil else { return }
        activeProviderAccountIds.removeValue(forKey: providerId)
        persistActiveIds()
        providerActivationLog.info("Cleared active \(providerId, privacy: .public) account detection: \(reason, privacy: .public)")
    }

    private func jwtEmailFromToken(_ token: String?) -> String? {
        guard let token, token.contains(".") else { return nil }
        let segments = token.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        guard let decoded = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let email = claims["email"] as? String else {
            return nil
        }
        return email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank
    }

    func detectActiveCodexAccount() {
        let authPath = NSString(string: "~/.codex/auth.json").expandingTildeInPath
        guard let authJSON = Self.loadJSON(atPath: authPath) else {
            lastActivatedCodexTarget = nil
            applyDetectedActiveId(nil, for: "codex", reason: "auth file unavailable")
            return
        }
        // 以磁盘中当前的完整身份检测，既能识别外部登录切换，也不会被同邮箱或同路径误导。
        let identity = CodexAccountIdentity(authJSON: authJSON)
        if let targetKey = lastActivatedCodexTarget?.activeKey?.lowercased(),
           targetKey != identity.key?.lowercased() {
            lastActivatedCodexTarget = nil
        }
        let matches = accountStore.accountRegistry.filter {
            $0.providerId == "codex" && !$0.isHidden
                && AccountIdentityPolicy.codexIdentity(for: $0).matches(identity)
        }
        applyDetectedActiveId(
            matches.isEmpty ? nil : identity.key,
            for: "codex",
            reason: "matched workspace and user"
        )
    }

    private static func loadJSON(atPath path: String) -> [String: Any]? {
        let expanded = NSString(string: path).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expanded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func detectActiveGeminiAccount() {
        let googleAccountsPath = NSString(string: "~/.gemini/google_accounts.json").expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: googleAccountsPath) else {
            applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json missing")
            return
        }

        let json: [String: Any]
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json root object is not a dictionary")
                return
            }
            json = object
        } catch {
            providerActivationLog.error("Failed to decode Gemini google_accounts.json: \(String(describing: error), privacy: .public)")
            applyDetectedActiveId(nil, for: "gemini", reason: "google_accounts.json contains invalid JSON")
            return
        }

        let active = (json["active"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank
        applyDetectedActiveId(active, for: "gemini", reason: "google_accounts.json has no active account")
    }

    func applyDetectedAntigravityEmail(_ rawEmail: String?) {
        guard let email = rawEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().nilIfBlank else {
            lastActivatedAntigravityTarget = nil
            applyDetectedActiveId(nil, for: "antigravity", reason: "Antigravity credential store has no active account")
            return
        }

        if let targetEmail = lastActivatedAntigravityTarget?.email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           targetEmail != email {
            lastActivatedAntigravityTarget = nil
        }

        let matches = accountStore.accountRegistry.filter {
            $0.providerId == "antigravity"
                && !$0.isHidden
                && !$0.isPermanentlyRemoved
                && $0.email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == email
        }

        if let currentActive = activeProviderAccountIds["antigravity"]?.lowercased(),
           matches.contains(where: {
               guard let path = $0.sourceFilePath else { return false }
               return AccountCredentialStore.normalizedAuthFilePath(path) == currentActive
           }) {
            return
        }

        if matches.count == 1, let matchedPath = matches.first?.sourceFilePath,
           let normalizedPath = AccountCredentialStore.normalizedAuthFilePath(matchedPath).nilIfBlank {
            applyDetectedActiveId(normalizedPath, for: "antigravity", reason: "matched Antigravity credential store email to stored sourceFilePath")
        } else if matches.count > 1 {
            // Same-email imports do not identify which credential file is active.
            applyDetectedActiveId(nil, for: "antigravity", reason: "Antigravity email has multiple stored credentials")
        } else {
            applyDetectedActiveId(email, for: "antigravity", reason: "matched Antigravity credential store email")
        }
    }

    func detectActiveAntigravityAccount() {
        antigravityDetectionTask?.cancel()
        antigravityDetectionTask = Task { [weak self] in
            let detected = await Task.detached(priority: .utility) {
                AntigravityAccountSwitcher.detectActiveAccount()
            }.value
            guard let self, !Task.isCancelled else { return }
            let validEmail = (detected != nil && (detected?.hasAccessToken == true || detected?.hasRefreshToken == true))
                ? detected?.email
                : nil
            self.applyDetectedAntigravityEmail(validEmail)
        }
    }

}
