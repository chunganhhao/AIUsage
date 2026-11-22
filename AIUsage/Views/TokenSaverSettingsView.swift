import SwiftUI
import Combine
import QuotaBackend

struct TokenSaverStatusBadge: View {
    enum Tone { case active, warning, danger, neutral }
    let text: String
    let tone: Tone
    var id: String = "token-saver-status-badge"

    private var color: Color {
        switch tone {
        case .active: return .green
        case .warning: return .orange
        case .danger: return .red
        case .neutral: return .secondary
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tone == .neutral ? Color.secondary : color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule()
                .fill(color.opacity(tone == .neutral ? 0.10 : 0.14))
                .overlay(
                    Capsule()
                        .strokeBorder(color.opacity(tone == .neutral ? 0.18 : 0.30), lineWidth: 0.75)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(text)
        .accessibilityIdentifier(id)
    }
}

/// Settings view hosting Token Saver toggles, RTK versions, and update checks.
struct TokenSaverSettingsPane: View {
    let home: URL
    let rtk: TokenSaverReleaseRTK
    @StateObject private var tokenSaverReleases: TokenSaverReleaseManager

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        rtk: TokenSaverReleaseRTK = .init(),
        releases: TokenSaverReleaseManager? = nil
    ) {
        self.home = home
        self.rtk = rtk
        _tokenSaverReleases = StateObject(wrappedValue: releases ?? TokenSaverReleaseManager())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            TokenSaverRuntimeSection(home: home, rtk: rtk)
            GatewayCard(padding: 0) { RTKVersionsView(store: RTKVersionStore(home: home)) }
            TokenSaverUpdatesSection(manager: tokenSaverReleases)
        }
    }
}

/// Separate observer prevents unrelated form drafts from being replaced.
struct TokenSaverRuntimeSection: View {
    @StateObject private var saver: TokenSaverSettingsController
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, rtk: TokenSaverReleaseRTK = .init()) {
        _saver = StateObject(wrappedValue: TokenSaverSettingsController(home: home, rtk: rtk))
    }

    var body: some View {
        GatewayCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Label(L("Token Saver & Context Optimization", "Token Saver 与上下文优化"), systemImage: "bolt.fill")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    let count = saver.settings.enabledToolCount
                    TokenSaverStatusBadge(
                        text: count > 0 ? L("Enabled \(count)/3", "已启用 \(count)/3", "Đã bật \(count)/3") : L("Off", "已关闭"),
                        tone: count > 0 ? .active : .neutral,
                        id: "token-saver-header-badge"
                    )
                }
                .padding(14)
                Divider()
                row(L("RTK — Compress Terminal Output", "RTK — 压缩终端输出"), detail: L("CLI wrapper: filters supported git, rg, ls and pytest output when explicitly invoked. Uses the selected RTK version, otherwise PATH. No aliases or automatic interception; savings vary.", "CLI 包装器：仅在显式调用时过滤 git、rg、ls、pytest 的受支持输出。优先使用选定的 RTK 版本，否则使用 PATH；不设置别名、不自动拦截，节省量因场景而异。"), key: \.rtkEnabled, id: "token-saver-rtk")
                Divider()
                row(L("Caveman — Concise Replies", "Caveman — 精简回复"), detail: L("Adds compact coding-only instructions to agent Markdown files. No full upstream repository is injected. Keeps code exact; no request/response rewriting.", "在代理 Markdown 文件中加入精简的编程指令，不注入完整上游仓库。保持代码精确，不重写请求或响应。"), key: \.cavemanEnabled, id: "token-saver-caveman")
                Picker(L("Caveman mode", "Caveman 模式"), selection: Binding(
                    get: { saver.settings.cavemanMode },
                    set: { mode in saver.mutate { $0.cavemanMode = mode } }
                )) {
                    ForEach(TokenSaverSettings.CavemanMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .padding(.horizontal, 14).padding(.bottom, 12)
                .disabled(!saver.settings.cavemanEnabled)
                .accessibilityIdentifier("token-saver-caveman-mode")
                Divider()
                row(L("Ponytail — Minimal Code (YAGNI)", "Ponytail — 极简代码 (YAGNI)"), detail: L("Adds compact YAGNI, reuse and stdlib-first rules to agent Markdown. No project dependencies are installed.", "在代理 Markdown 文件中加入 YAGNI、优先复用和标准库优先的精简规则，不安装项目依赖。"), key: \.ponytailEnabled, id: "token-saver-ponytail")
                Divider()
                onboardingChecklist.padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Saves lightweight instruction files for supported coding agents (Antigravity, Claude Code, Codex, OpenCode, and Hermes ~/.hermes/SOUL.md); AIUsage does not install or launch those agents. A new coding session is required. Custom profiles in ~/.hermes/profiles/* remain untouched.", "为受支持的编程代理（Antigravity、Claude Code、Codex、OpenCode 与 Hermes ~/.hermes/SOUL.md）保存轻量指令文件；AIUsage 不会安装或启动这些代理。更改后需开启新的编程会话。~/.hermes/profiles/* 中的自定义配置保持不变。"))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        Button(L("Reapply compact rules", "重新应用精简规则")) { saver.reapply() }
                            .accessibilityIdentifier("token-saver-reapply")
                        if saver.lastSaveSucceeded, saver.error == nil {
                            TokenSaverStatusBadge(
                                text: L("Saved — new session required", "已保存 — 需开启新会话"),
                                tone: .active,
                                id: "token-saver-saved-badge"
                            )
                        }
                    }
                    Text(L("Start a new coding session after enabling or updating rules so your agent reloads instructions. RTK must be installed on the agent's PATH.", "启用或更新规则后请开启新的编程会话以重新加载指令。RTK 必须安装在代理的 PATH 中。"))
                        .font(.caption).foregroundStyle(.secondary)
                    if let notice = saver.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("token-saver-notice")
                    }
                    if let error = saver.localizedError {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("token-saver-error")
                    }
                }.padding(14)
            }
        }
        .task {
            await saver.performInitialCheckIfNeeded()
        }
    }

    private func harnessLabel(_ harness: TokenSaverOnboarding.Harness) -> String {
        switch harness {
        case .codex, .claude, .antigravity, .openCode: return harness.rawValue
        case .hermes: return L("Hermes (~/.hermes/SOUL.md)", "Hermes（~/.hermes/SOUL.md）")
        }
    }

    private func wrapperGuidance(_ setup: TokenSaverOnboarding.Snapshot) -> String {
        if !saver.settings.rtkEnabled {
            return L("RTK switch is off above (optional if using only Caveman or Ponytail). Turn on Compress tool output (RTK) only if you want command-output compression.", "上方 RTK 开关处于关闭状态（若仅使用 Caveman 或 Ponytail 则无需开启）。仅在需要压缩命令输出时开启 RTK。")
        }
        if setup.wrapperReady {
            return L("Managed wrapper matches; optional diagnostic below checks terminal PATH resolution only (not proof of prompt loading).", "托管包装器匹配；下方可选诊断仅检查终端 PATH 解析（不能证明提示词已加载）。")
        }
        return L("Managed wrapper missing or modified. Click Reapply compact rules below to restore it.", "托管包装器缺失或已修改。请点击下方“重新应用精简规则”以恢复。")
    }

    private func rulesGuidance(_ rules: TokenSaverOnboarding.RulesState) -> String {
        switch rules {
        case .current:
            return L("Rule file matches on disk. Start a new session; optional diagnostic below requests agent self-report (and RTK --version when RTK is enabled), which is not proof of automatic prompt loading.", "磁盘上的规则文件已匹配。请开始新会话；下方可选诊断仅获取代理自述（启用 RTK 时含 --version 检查），不能证明提示词已自动加载。")
        case .off:
            return L("Next step: turn on at least one tool switch above (RTK, Caveman or Ponytail) to write managed rules.", "下一步：请先在上方开启至少一项工具开关（RTK、Caveman 或 Ponytail）以写入托管规则。")
        case .missing:
            return L("Next step: click Reapply compact rules below to create the managed rule file.", "下一步：请点击下方“重新应用精简规则”以创建托管规则文件。")
        case .stale:
            return L("Next step: click Reapply compact rules below to update the rule file.", "下一步：请点击下方“重新应用精简规则”以更新规则文件。")
        case .unreadable:
            return L("Next step: resolve external edits, symlinks or corrupted JSON before reapplying.", "下一步：请先处理外部修改、符号链接或损坏的 JSON，然后再重新应用。")
        case .unsupported:
            return L("No automatic rule file exists for this harness; connecting an external proxy alone does not load Token Saver rules.", "此代理无自动规则文件；仅连接外部代理不会加载 Token Saver 规则。")
        }
    }

    @ViewBuilder
    private var rulesBadge: some View {
        switch saver.onboarding?.rules {
        case .current:
            TokenSaverStatusBadge(text: L("Rules current", "规则已最新"), tone: .active, id: "token-saver-rules-badge")
        case .off:
            TokenSaverStatusBadge(text: L("Off", "已关闭"), tone: .neutral, id: "token-saver-rules-badge")
        case .missing:
            TokenSaverStatusBadge(text: L("Rules missing", "规则缺失"), tone: .warning, id: "token-saver-rules-badge")
        case .stale:
            TokenSaverStatusBadge(text: L("Rules out of date", "规则需更新"), tone: .warning, id: "token-saver-rules-badge")
        case .unreadable:
            TokenSaverStatusBadge(text: L("Unreadable", "无法读取"), tone: .danger, id: "token-saver-rules-badge")
        case .unsupported:
            TokenSaverStatusBadge(text: L("Unsupported", "不支持"), tone: .neutral, id: "token-saver-rules-badge")
        case nil:
            TokenSaverStatusBadge(
                text: saver.isRefreshingRules ? L("Checking…", "检查中…") : L("Not checked", "未检查"),
                tone: .neutral,
                id: "token-saver-rules-badge"
            )
        }
    }

    private var onboardingChecklist: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Setup & verification (after enabling tools above)", "设置与验证（在上方启用工具后检查）")).font(.subheadline.weight(.semibold))
            Picker(L("1. Coding harness", "1. 编程代理"), selection: Binding(
                get: { saver.harness }, set: { saver.selectHarness($0) }
            )) {
                ForEach(TokenSaverOnboarding.Harness.allCases, id: \.self) { harness in
                    Text(harnessLabel(harness)).tag(harness)
                }
            }
            .accessibilityIdentifier("token-saver-harness")
            if let url = saver.harness.rulesURL(home: saver.home) {
                Text(url.path).font(.caption2.monospaced()).textSelection(.enabled)
            }
            Text(saver.localizedRTKStatus)
                .font(.caption).accessibilityIdentifier("token-saver-setup-rtk")
            if let setup = saver.onboarding {
                Text(wrapperGuidance(setup))
                    .font(.caption2).foregroundStyle(.secondary)
                if saver.settings.rtkEnabled, !saver.installationStatus.hasPrefix("Homebrew ") {
                    HStack(spacing: 8) {
                        Text(L("Next step: install RTK with Homebrew in Terminal (`brew install rtk`), then check again.", "下一步：在终端通过 Homebrew 安装 RTK（`brew install rtk`），然后重新检查。"))
                            .font(.caption2).foregroundStyle(.orange)
                        Button(saver.copiedBrewCommand ? L("✓ Copied!", "✓ 已复制！") : L("Copy: brew install rtk", "复制：brew install rtk")) {
                            _ = saver.copyBrewInstallCommand()
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("token-saver-copy-brew-install")
                    }
                }
            }
            HStack(spacing: 8) {
                Text(saver.localizedRulesStatus)
                    .font(.caption).accessibilityIdentifier("token-saver-setup-rules")
                rulesBadge
            }
            if let setup = saver.onboarding {
                Text(rulesGuidance(setup.rules))
                    .font(.caption2).foregroundStyle(setup.rules == .current ? Color.secondary : Color.orange)
            }
            Text(L("Agent prompt: not verified. A matching file is not proof a new session loaded it.", "代理提示词：未验证。文件匹配不代表新会话已加载。"))
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("token-saver-setup-prompt")
            Text(saver.localizedHistoryStatus)
                .font(.caption).accessibilityIdentifier("token-saver-setup-history")
            Text(L("Supplemental Mac-wide count only — not evidence for this harness/session or equal-quality token savings. Diagnostic uses --version when RTK is enabled so it will not inflate this counter.", "仅作全机历史补充计数——不能证明所选代理/会话已调用或节省 Token。启用 RTK 时诊断仅运行 --version，不会虚增此计数。"))
                .font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button(saver.isCheckingSetup ? L("Checking…", "检查中…") : L("Check setup (offline)", "离线检查设置")) {
                    Task { await saver.checkOnboarding() }
                }
                .disabled(saver.isCheckingSetup)
                .accessibilityIdentifier("token-saver-setup-check")
                Button(saver.copiedDiagnostic ? L("✓ Copied!", "✓ 已复制！") : L("Copy optional agent diagnostic", "复制可选代理诊断提示词")) {
                    _ = saver.copyDiagnostic()
                }
                .disabled(saver.isRefreshingRules || saver.onboarding?.agentCommands == nil)
                .accessibilityIdentifier("token-saver-setup-copy")
            }
            if saver.harness == .hermes {
                Text(L("Global Hermes (~/.hermes/SOUL.md) is updated automatically when tools above change. Custom profiles in ~/.hermes/profiles/* stay isolated and are never modified.", "全局 Hermes（~/.hermes/SOUL.md）会在上方开关更改时自动更新。~/.hermes/profiles/* 中的自定义配置完全隔离，绝不会被修改。"))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = saver.localizedSetupError { Text(error).font(.caption).foregroundStyle(.orange) }
        }
    }

    private func row(_ title: String, detail: String, key: WritableKeyPath<TokenSaverSettings, Bool>, id: String) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle(title, isOn: Binding(
                get: { saver.settings[keyPath: key] },
                set: { enabled in saver.mutate { $0[keyPath: key] = enabled } }
            ))
            .labelsHidden().toggleStyle(SwitchToggleStyle(tint: .purple)).controlSize(.small).tint(.purple)
            .accessibilityIdentifier(id)
        }.padding(14)
    }
}

/// Agent-side instructions only. No request middleware or runtime changes.
#if canImport(AppKit)
import AppKit
#endif

@MainActor
final class TokenSaverSettingsController: ObservableObject {
    @Published private(set) var settings = TokenSaverSettings()
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var lastSaveSucceeded = false
    @Published private(set) var harness = TokenSaverOnboarding.Harness.codex
    @Published private(set) var onboarding: TokenSaverOnboarding.Snapshot?
    @Published private(set) var isCheckingSetup = false
    @Published private(set) var isRefreshingRules = false
    @Published private(set) var installationStatus = "not checked; install RTK separately"
    @Published private(set) var setupError: String?
    @Published private(set) var copiedDiagnostic = false
    @Published private(set) var copiedBrewCommand = false

    let home: URL
    private let rtk: TokenSaverReleaseRTK
    private let copyToClipboard: (String) -> Bool
    private let copyFeedbackDurationNanoseconds: UInt64
    private let controllerID = UUID()
    private var settingsObserver: NSObjectProtocol?
    private var inspectionGeneration: UInt64 = 0
    private var inspectionTask: Task<Void, Never>?
    private var brewGeneration: UInt64 = 0
    private var cachedHistoryRecords: Int64?
    private var hasScannedHistory = false
    private var hasStartedInitialCheck = false
    private var diagnosticCopyResetTask: Task<Void, Never>?
    private var brewCopyResetTask: Task<Void, Never>?

    nonisolated static func defaultCopyToClipboard(_ text: String) -> Bool {
        #if canImport(AppKit)
        let pb = NSPasteboard.general
        pb.clearContents()
        return pb.setString(text, forType: .string)
        #else
        return false
        #endif
    }

    init(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        rtk: TokenSaverReleaseRTK = .init(),
        copyFeedbackDurationNanoseconds: UInt64 = 1_500_000_000,
        copyToClipboard: @escaping (String) -> Bool = TokenSaverSettingsController.defaultCopyToClipboard
    ) {
        self.home = home
        self.rtk = rtk
        self.copyFeedbackDurationNanoseconds = copyFeedbackDurationNanoseconds
        self.copyToClipboard = copyToClipboard
        do { settings = try TokenSaverSettingsStore.load(home: home) }
        catch { self.error = error.localizedDescription }
        let expectedHome = TokenSaverSettingsStore.canonicalHomePath(home)
        let ownOrigin = controllerID.uuidString
        settingsObserver = NotificationCenter.default.addObserver(
            forName: .tokenSaverSettingsDidChange,
            object: nil,
            queue: nil
        ) { [weak self] note in
            guard let noteHome = note.userInfo?["home"] as? String, noteHome == expectedHome else { return }
            if let origin = note.userInfo?["origin"] as? String, origin == ownOrigin { return }
            Task { @MainActor [weak self] in
                self?.reloadFromExternalNotification()
            }
        }
    }

    deinit {
        if let settingsObserver {
            NotificationCenter.default.removeObserver(settingsObserver)
        }
        inspectionTask?.cancel()
        diagnosticCopyResetTask?.cancel()
        brewCopyResetTask?.cancel()
    }

    private static func savedNoticeText() -> String {
        L("Saved. Start a new coding session to reload instructions.", "已保存。请开启新的编程会话以重新加载指令。")
    }

    func reloadFromExternalNotification() {
        onboarding = nil
        do {
            settings = try TokenSaverSettingsStore.load(home: home)
            error = nil
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        } catch {
            self.error = error.localizedDescription
            self.notice = nil
            self.lastSaveSucceeded = false
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        }
    }

    func mutate(_ transform: (inout TokenSaverSettings) -> Void) {
        onboarding = nil
        notice = nil
        do {
            let updated = try TokenSaverSettingsStore.update(home: home, origin: controllerID) { current in
                transform(&current)
            }
            settings = updated
            error = nil
            lastSaveSucceeded = true
            notice = Self.savedNoticeText()
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        } catch {
            self.error = error.localizedDescription
            self.lastSaveSucceeded = false
            if let persisted = try? TokenSaverSettingsStore.load(home: home) {
                self.settings = persisted
            }
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        }
    }

    func reapply() {
        mutate { _ in }
    }

    func apply(_ value: TokenSaverSettings) {
        onboarding = nil
        notice = nil
        do {
            try TokenSaverSettingsStore.save(value, home: home, origin: controllerID)
            settings = value
            error = nil
            lastSaveSucceeded = true
            notice = Self.savedNoticeText()
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        } catch {
            self.error = error.localizedDescription
            self.lastSaveSucceeded = false
            if let persisted = try? TokenSaverSettingsStore.load(home: home) {
                self.settings = persisted
            }
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        }
    }

    func syncHermesTestProfile() {
        onboarding = nil
        notice = nil
        do {
            let target = try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
            error = nil
            lastSaveSucceeded = true
            notice = FileManager.default.fileExists(atPath: target.path)
                ? L("Hermes test rules synchronized. Start a new coding session in token-saver-test's workspace. Sync again after settings changes; bot/default profiles were not modified.", "Hermes 测试规则已同步。请在 token-saver-test 的工作区开启新的编程会话。更改设置后请重新同步；未修改机器人或默认配置。")
                : L("Owned Hermes test rules removed. All tools are off; bot/default profiles were not modified.", "已移除托管的 Hermes 测试规则。所有工具均已关闭；未修改机器人或默认配置。")
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        } catch {
            self.error = error.localizedDescription
            self.lastSaveSucceeded = false
            scheduleRulesRefresh(includeHistory: !hasScannedHistory)
        }
    }

    func selectHarness(_ value: TokenSaverOnboarding.Harness) {
        harness = value
        onboarding = nil
        setupError = nil
        notice = nil
        scheduleRulesRefresh(includeHistory: !hasScannedHistory)
    }

    private func scheduleRulesRefresh(includeHistory: Bool) {
        inspectionGeneration &+= 1
        let gen = inspectionGeneration
        let home = self.home
        let harness = self.harness
        let shouldScanHistory = includeHistory || !hasScannedHistory
        let cached = cachedHistoryRecords
        isRefreshingRules = true
        inspectionTask?.cancel()
        inspectionTask = Task { @MainActor [weak self] in
            let snap = await Task.detached {
                TokenSaverOnboarding.inspect(
                    home: home,
                    harness: harness,
                    includeHistory: shouldScanHistory,
                    cachedHistoryRecords: cached
                )
            }.value
            guard let self, self.inspectionGeneration == gen else { return }
            if shouldScanHistory {
                self.cachedHistoryRecords = snap.historyRecords
                self.hasScannedHistory = true
            }
            self.onboarding = snap
            self.isRefreshingRules = false
        }
    }

    func waitForPendingInspection() async {
        await inspectionTask?.value
    }

    func performInitialCheckIfNeeded() async {
        guard !hasStartedInitialCheck else { return }
        hasStartedInitialCheck = true
        await checkOnboarding()
    }

    @discardableResult
    func copyDiagnostic() -> Bool {
        guard !isRefreshingRules, let commands = onboarding?.agentCommands, copyToClipboard(commands) else {
            copiedDiagnostic = false
            return false
        }
        copiedDiagnostic = true
        let duration = copyFeedbackDurationNanoseconds
        diagnosticCopyResetTask?.cancel()
        diagnosticCopyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            self?.copiedDiagnostic = false
        }
        return true
    }

    @discardableResult
    func copyBrewInstallCommand() -> Bool {
        guard copyToClipboard("brew install rtk") else {
            copiedBrewCommand = false
            return false
        }
        copiedBrewCommand = true
        let duration = copyFeedbackDurationNanoseconds
        brewCopyResetTask?.cancel()
        brewCopyResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: duration)
            guard !Task.isCancelled else { return }
            self?.copiedBrewCommand = false
        }
        return true
    }

    var localizedRTKStatus: String {
        switch installationStatus {
        case "not checked; install RTK separately":
            return L("2. RTK: not checked; install RTK separately", "2. RTK：未检查；需单独安装 RTK")
        case "checking Homebrew; agent PATH is not verified":
            return L("2. RTK: checking Homebrew; agent PATH is not verified", "2. RTK：正在检查 Homebrew；代理 PATH 未验证")
        case "not installed in Homebrew; other installations/PATH not verified":
            return L("2. RTK: not installed in Homebrew; other installations/PATH not verified", "2. RTK：Homebrew 未安装；其他安装方式或 PATH 未验证")
        case "not verified":
            return L("2. RTK: not verified", "2. RTK：未验证")
        default:
            let prefix = installationStatus.components(separatedBy: ";").first ?? installationStatus
            return L("2. RTK: \(installationStatus)", "2. RTK：\(prefix)；代理 PATH 未验证", "2. RTK: \(installationStatus)")
        }
    }
    var localizedRulesStatus: String {
        guard let rules = onboarding?.rules else { return L("3. Managed rules: not checked", "3. 托管规则：未检查") }
        switch rules {
        case .current: return L("3. Managed rules: current", "3. 托管规则：当前匹配")
        case .missing: return L("3. Managed rules: missing", "3. 托管规则：缺失")
        case .stale: return L("3. Managed rules: stale", "3. 托管规则：已过期")
        case .off: return L("3. Managed rules: off", "3. 托管规则：已关闭")
        case .unreadable: return L("3. Managed rules: unreadable", "3. 托管规则：无法读取")
        case .unsupported: return L("3. Managed rules: unsupported", "3. 托管规则：不受支持")
        }
    }
    var historyStatus: String {
        guard let onboarding else { return "4. RTK execution evidence: not checked" }
        guard let count = onboarding.historyRecords else { return "4. Default RTK history: unavailable / not verified" }
        return count == 0 ? "4. Default RTK history: 0 records; no execution evidence"
            : "4. Default RTK history: \(count) records (all harnesses)"
    }
    var localizedHistoryStatus: String {
        guard let onboarding else { return L("4. RTK execution evidence: not checked", "4. RTK 执行证据：未检查") }
        guard let count = onboarding.historyRecords else {
            return L("4. Default RTK history: unavailable / not verified", "4. 默认 RTK 历史记录：不可用 / 未验证")
        }
        return count == 0
            ? L("4. Default RTK history: 0 records; no execution evidence", "4. 默认 RTK 历史记录：0 条记录；无执行证据")
            : L("4. Default RTK history: \(count) records (all harnesses)", "4. 默认 RTK 历史记录：\(count) 条记录（涵盖所有代理）", "4. Lịch sử RTK mặc định: \(count) bản ghi (mọi harness)")
    }
    var localizedError: String? { error.map(Self.localizeErrorText) }
    var localizedSetupError: String? { setupError.map(Self.localizeErrorText) }
    private static func localizeErrorText(_ text: String) -> String {
        switch text {
        case "Token Saver rule was edited externally. Preserve it and resolve the AIUsage managed block before retrying.":
            return L(text, "Token Saver 规则已被外部编辑。请保留修改并处理 AIUsage 托管块后再重试。")
        case "Token Saver will not replace symlinked settings or rules.":
            return L(text, "Token Saver 不会替换符号链接的设置或规则。")
        case "Create the dedicated Hermes token-saver-test profile first. No bot or default profile is modified.":
            return L(text, "请先创建专用的 Hermes token-saver-test 配置。不会修改机器人或默认配置。")
        case "Enable RTK in AIUsage first; the managed executable wrapper is required before exporting Hermes test rules.":
            return L(text, "请先在 AIUsage 中启用 RTK；导出 Hermes 测试规则前需要托管的可执行包装器。")
        case "Trusted Homebrew not found at /opt/homebrew/bin/brew or /usr/local/bin/brew. Install/update RTK externally.":
            return L(text, "在 /opt/homebrew/bin/brew 或 /usr/local/bin/brew 未找到可信 Homebrew。请从外部安装/更新 RTK。")
        case "RTK is not installed in Homebrew. AIUsage will not install it.":
            return L(text, "Homebrew 中未安装 RTK。AIUsage 不会自动安装。")
        case "Homebrew installed-version response was not recognized.":
            return L(text, "无法识别 Homebrew 已安装版本响应。")
        case "Homebrew exceeded the 180-second or 128 KiB output limit. Check its external status before retrying.":
            return L(text, "Homebrew 超过 180 秒或 128 KiB 输出限制。请检查外部状态后重试。")
        default:
            return text
        }
    }
    func checkOnboarding() async {
        guard !isCheckingSetup else { return }
        hasStartedInitialCheck = true
        isCheckingSetup = true
        setupError = nil
        notice = nil
        onboarding = nil
        installationStatus = "checking Homebrew; agent PATH is not verified"
        scheduleRulesRefresh(includeHistory: true)
        brewGeneration &+= 1
        let currentBrewGen = brewGeneration
        defer { isCheckingSetup = false }
        do {
            if let version = try await rtk.installedVersion() {
                if currentBrewGen == brewGeneration {
                    installationStatus = "Homebrew \(version); agent PATH is not verified"
                }
            } else if currentBrewGen == brewGeneration {
                installationStatus = "not installed in Homebrew; other installations/PATH not verified"
            }
        } catch {
            if currentBrewGen == brewGeneration {
                installationStatus = "not verified"
                setupError = error.localizedDescription
            }
        }
        await waitForPendingInspection()
    }
}

// MARK: - Token Saver updates section

struct TokenSaverUpdatesSection: View {
    @ObservedObject private var manager: TokenSaverReleaseManager
    @State private var pendingInstall: TokenSaverReleaseTool?
    @State private var showRTKSetup = false
    private let onOpenRuntime: (() -> Void)?

    @MainActor
    init(manager: TokenSaverReleaseManager, onOpenRuntime: (() -> Void)? = nil) {
        self.manager = manager
        self.onOpenRuntime = onOpenRuntime
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Token Saver updates", "Token Saver 更新")).font(.title3.weight(.semibold))
            Label(L("1. Install RTK (Homebrew) → 2. Enable tools in Token Saver → 3. Optional: check RTK updates", "1. 安装 RTK (Homebrew) → 2. 在 Token 节省页启用工具 → 3. 可选：检查 RTK 更新"), systemImage: "list.number")
                .font(.subheadline.weight(.medium))
            Text(L("Caveman and Ponytail use built-in compact rules directly in AIUsage — no reference downloads or updates are needed. RTK requires installing the binary via Homebrew. Reload a new coding session after changes. No downloaded scripts are executed.",
                   "Caveman 和 Ponytail 直接使用 AIUsage 内置精简规则——无需下载或更新参考文档。RTK 需通过 Homebrew 安装二进制文件。更改后请开启新的编程会话。不会执行下载的脚本。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let onOpenRuntime {
                Button(action: onOpenRuntime) {
                    Label(L("Open Token Saver to enable tools", "打开 Token 节省页以启用工具"), systemImage: "bolt.fill")
                }.accessibilityIdentifier("token-saver-open-runtime")
            }
            if let retry = manager.retryAfter {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    releaseToolsSection(coolingDown: retry > context.date, retry: retry)
                }
            } else {
                releaseToolsSection(coolingDown: false, retry: nil)
            }
        }
        .sheet(isPresented: $showRTKSetup) { rtkSetup }
        .alert(L("Upgrade RTK with Homebrew?", "通过 Homebrew 更新 RTK？"), isPresented: Binding(
            get: { pendingInstall == .rtk }, set: { if !$0 { pendingInstall = nil } }
        )) {
            Button(L("Run brew upgrade rtk", "运行 brew upgrade rtk")) {
                pendingInstall = nil
                Task { await manager.updateRTK() }
            }
            Button(L("Cancel", "取消"), role: .cancel) { pendingInstall = nil }
        } message: {
            Text(L("Runs only brew upgrade rtk using trusted Homebrew. RTK must already be installed. Homebrew may update RTK and required dependencies outside AIUsage storage. No brew install or downloaded shell installer is run.", "仅通过可信 Homebrew 运行 brew upgrade rtk。RTK 必须已安装。Homebrew 可能在 AIUsage 存储之外更新 RTK 及必要依赖；不会运行 brew install 或下载的 Shell 安装器。"))
        }
    }

    @ViewBuilder
    private func releaseToolsSection(coolingDown: Bool, retry: Date?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let retry, coolingDown {
                Label {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("GitHub checks paused", "GitHub 检查已暂停")).fontWeight(.semibold)
                        Text(L("Try again after \(retry.formatted(date: .abbreviated, time: .standard)) (local time). Checks resume then; nothing retries automatically. This shared GitHub API limit is not your AI quota.",
                               "请在本地时间 \(retry.formatted(date: .abbreviated, time: .standard)) 后重试。届时可再次检查，不会自动重试。此共享 GitHub API 限制不是 AI 配额。",
                               "Hãy thử lại sau \(retry.formatted(date: .abbreviated, time: .standard)) (giờ địa phương). Hệ thống chỉ kiểm tra lại sau mốc này và không tự thử lại. Giới hạn GitHub API dùng chung này không phải hạn mức AI của bạn."))
                    }
                } icon: { Image(systemName: "clock.badge.exclamationmark") }
                .font(.caption).padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("token-saver-cooldown")
            }
            ForEach(TokenSaverReleaseTool.allCases) { tool in
                toolRow(tool, coolingDown: coolingDown)
            }
        }
    }

    private func toolRow(_ tool: TokenSaverReleaseTool, coolingDown: Bool) -> some View {
        let status = manager.statuses[tool] ?? .init()
        return GatewayCard(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(tool.title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Link(L("View source & docs ↗", "查看源码和文档 ↗"), destination: tool.upstreamURL).font(.caption)
                }
                Text(toolSummary(tool)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if tool == .rtk {
                    HStack(alignment: .top, spacing: 16) {
                        versionLabel(L("Installed version", "已安装版本"),
                                     status.installedBinaryVersion ?? (status.binaryInspected ? L("Not installed in Homebrew", "Homebrew 未安装") : L("Unknown · not inspected", "未知 · 未检测")))
                        versionLabel(L("Latest (GitHub)", "最新（GitHub）"), status.latest?.version ?? L("Not checked", "未检查"))
                    }
                    if let notice = status.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                    if let error = status.error, !coolingDown {
                        Text(error).font(.caption).foregroundStyle(.red).accessibilityIdentifier("token-saver-\(tool.rawValue)-error")
                    }
                    Label(actionHint(tool, status: status, coolingDown: coolingDown), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("token-saver-\(tool.rawValue)-guidance")
                    HStack {
                        if status.isBusy { ProgressView().controlSize(.small) }
                        if let checked = status.checkedAt {
                            Text(checked.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(L("How to install…", "如何安装…")) { showRTKSetup = true }
                            .accessibilityIdentifier("token-saver-rtk-setup")
                        Button(status.isBusy ? L("Working…", "处理中…") : L("Check versions", "检查版本")) { Task { await manager.check(tool) } }
                            .disabled(status.isBusy || coolingDown).help(L("Look up GitHub versions; RTK also reads its Homebrew version. Nothing is installed.", "查询 GitHub 版本；RTK 同时读取 Homebrew 版本。不会安装任何内容。")).accessibilityIdentifier("token-saver-\(tool.rawValue)-check")
                        Button(L("Update RTK", "更新 RTK")) { pendingInstall = tool }
                            .disabled(status.isBusy || status.latest == nil || !status.brewAvailable || status.installedBinaryVersion == nil)
                            .accessibilityIdentifier("token-saver-\(tool.rawValue)-update")
                    }
                } else {
                    versionLabel(L("Policy source", "策略来源"),
                                 L("Built-in compact rules · Enable in Token Saver", "内置精简规则 · 在 Token 节省页启用"))
                    Label(L("Included directly in AIUsage. No reference download is needed — enable in Token Saver and start a new coding session.", "已直接内置于 AIUsage，无需下载参考文档——在 Token 节省页启用并开启新的编程会话即可。"), systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("token-saver-\(tool.rawValue)-guidance")
                }
            }
        }
        .accessibilityIdentifier("token-saver-\(tool.rawValue)-release")
    }

    private func toolSummary(_ tool: TokenSaverReleaseTool) -> String {
        switch tool {
        case .rtk: return L("Command-line tool that compresses coding command output. Requires RTK on your coding agent’s PATH; AIUsage does not intercept commands.", "压缩编程命令输出的命令行工具。需在编程代理的 PATH 中安装 RTK；AIUsage 不会拦截命令。")
        case .caveman: return L("Instruction rules for shorter coding explanations, without rewriting your code or API traffic.", "通过指令规则缩短编程说明，不重写代码或 API 流量。")
        case .ponytail: return L("Instruction rules that favor reuse, standard libraries and minimal, verified code.", "优先复用、标准库和最少且经过验证的代码的指令规则。")
        }
    }

    private func actionHint(_ tool: TokenSaverReleaseTool, status: TokenSaverReleaseManager.Status, coolingDown: Bool) -> String {
        if status.isBusy { return L("Operation in progress. Please wait.", "操作进行中，请稍候。") }
        if tool == .rtk && !status.brewAvailable { return L("Homebrew unavailable. Open How to install for setup options; version checks still work.", "Homebrew 不可用。打开“如何安装”查看设置选项；仍可检查最新版本。") }
        if tool == .rtk && status.binaryInspected && status.installedBinaryVersion == nil { return L("Update unavailable: install RTK with Homebrew first, then Check versions. Other installations are not managed here.", "暂不能更新：先通过 Homebrew 安装 RTK，再检查版本。此处不管理其他安装方式。") }
        if coolingDown { return L("GitHub checks and rule downloads are paused until the local time shown above.", "GitHub 检查和规则下载已暂停至上方显示的本地时间。") }
        if status.latest == nil { return L("Start with Check versions to unlock downloads. This does not enable the tool.", "先检查版本以解锁下载。此操作不会启用工具。") }
        if tool == .rtk { return L("Update RTK runs brew upgrade rtk after confirmation. Homebrew may lag behind GitHub. Then enable RTK in Token Saver and start a new coding session.", "确认后通过 brew upgrade rtk 更新。Homebrew 版本可能落后于 GitHub。之后在 Token 节省页启用 RTK 并开始新的编程会话。") }
        if status.isCurrent && status.error == nil { return L("Latest checked reference saved. Compact built-in policy is separate; enable it in Token Saver and start a new coding session. No further download needed.", "已保存最新检查的参考文档。精简内置策略单独生效；请在 Token 节省页启用并开始新会话，无需再次下载。") }
        return L("Download reference asks for confirmation; it does not inject full upstream text. Compact built-in policies work without downloads. Enable tools in Token Saver and start a new coding session.", "下载参考文档需要确认，不会注入完整上游文本。精简内置策略无需下载即可使用。请在 Token 节省页启用工具并开始新会话。")
    }

    private var rtkSetup: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(L("Set up RTK", "设置 RTK"), systemImage: "terminal").font(.title2.weight(.semibold))
            Text(L("AIUsage does not install Homebrew or run downloaded installers. Review and run the command yourself in Terminal. Installing RTK alone does not enable AIUsage’s coding rules.", "AIUsage 不会安装 Homebrew 或执行下载的安装器。请自行审核并在终端运行命令。仅安装 RTK 不会启用 AIUsage 编程规则。"))
                .fixedSize(horizontal: false, vertical: true)
            Link(L("1. Install Homebrew if needed, then restart AIUsage ↗", "1. 如需安装 Homebrew，安装后重启 AIUsage ↗"), destination: URL(string: "https://brew.sh")!)
            Text(L("2. Install RTK in Terminal", "2. 在终端安装 RTK")).fontWeight(.semibold)
            Text("brew install rtk").font(.body.monospaced()).textSelection(.enabled)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
            Text(L("3. Verify rtk --version in your coding agent’s terminal. Return here and Check versions to detect the Homebrew installation. Enable Compress tool output (RTK) in Token Saver, then start a new coding session.", "3. 在编程代理的终端验证 rtk --version。返回此处检查版本以识别 Homebrew 安装。在 Token 节省页启用 RTK 压缩工具输出，然后开始新的编程会话。"))
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Already installed another way? Keep that setup and update it externally. AIUsage only manages upgrades for the Homebrew rtk package; it does not install hooks or change your PATH.", "已通过其他方式安装？可保留现有设置并自行更新。AIUsage 仅管理 Homebrew rtk 软件包的更新，不会安装钩子或修改 PATH。"))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Link(L("RTK installation docs ↗", "RTK 安装文档 ↗"), destination: TokenSaverReleaseTool.rtk.upstreamURL)
                Spacer()
                Button(L("Done", "完成")) { showRTKSetup = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 530)
        .accessibilityIdentifier("token-saver-rtk-setup-guide")
    }

    private func versionLabel(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit()).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
