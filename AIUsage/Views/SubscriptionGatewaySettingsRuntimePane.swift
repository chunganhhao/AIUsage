import SwiftUI
import QuotaBackend
import Combine
import Foundation

// MARK: - CPA Runtime 设置
// 主界面：常规 / 选号策略 / 网络。
// 高级：对齐 CPA config.example 的 request-retry / max-retry-interval / max-retry-credentials。
// 订阅与 CPA 账号池彼此独立，不在此做隐藏联动。

struct SubscriptionGatewaySettingsRuntimePane: View {
    @ObservedObject var runtime: CLIProxyRuntimeController
    @Binding var draftSettings: CLIProxyGatewaySettings
    let onApply: () -> Void
    var tokenSaverHome: URL = FileManager.default.homeDirectoryForCurrentUser
    var tokenSaverRTK: TokenSaverReleaseRTK = .init()

    @State private var showAdvanced = false
    @State private var poolProtectionEnabled = false
    @State private var poolProtectionError: String?
    @State private var poolProtectionResidual = false

    private var hasUnappliedChanges: Bool {
        draftSettings.normalized != runtime.settings.normalized
    }

    private var needsRestart: Bool {
        draftSettings.requiresCPAProcessRestart(comparedTo: runtime.settings)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    poolProtectionSection

                    GatewayCard(padding: 0) {
                        VStack(spacing: 0) {
                            groupLabel(L("General", "常规"))
                            compactToggle(L("Launch with app", "随应用启动"), isOn: $draftSettings.autoStart)
                            rowDivider
                            compactPortRow
                            rowDivider
                            compactToggle(L("LAN access", "局域网访问"), isOn: $draftSettings.allowLANAccess)
                            if draftSettings.allowLANAccess {
                                lanHint.padding(.horizontal, 14).padding(.bottom, 12)
                            }
                        }
                    }

                    GatewayCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            groupLabel(L("Account picking", "账号选择"))
                            compactPickerRow
                            Text(L(
                                "Fill first keeps using one available account until it cools down, then moves on. Round robin spreads requests.",
                                "优先用满：一直打同一个可用号，额度冷却后再换下一个。轮询：请求分散到各账号。"
                            ))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 12)
                        }
                    }

                    GatewayCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            groupLabel(L("Model catalog", "模型目录"))
                            compactToggle(
                                L("Auto refresh model catalog", "自动刷新模型目录"),
                                isOn: $draftSettings.accountModelProbeEnabled
                            )
                            if draftSettings.accountModelProbeEnabled {
                                rowDivider
                                advancedNumberRow(
                                    title: L("Every (sec)", "每隔（秒）"),
                                    subtitle: L(
                                        "Updates cooling flags and local model lists; does not verify OAuth",
                                        "更新冷却标记与本地模型目录，不验证 OAuth"
                                    ),
                                    value: $draftSettings.accountModelProbeIntervalSeconds,
                                    range: 15...3600,
                                    placeholder: "60"
                                )
                            } else {
                                Text(L(
                                    "Refresh the account list manually when you need updated model data.",
                                    "需要更新模型数据时，请在账号页手动刷新列表。"
                                ))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 14)
                                .padding(.bottom, 12)
                            }
                        }
                    }

                    GatewayCard(padding: 0) {
                        VStack(spacing: 0) {
                            groupLabel(L("Network", "网络"))
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L("Upstream proxy", "上游代理"))
                                    .font(.subheadline.weight(.medium))
                                TextField("http://127.0.0.1:7890", text: $draftSettings.proxyURL)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.callout.monospaced())
                            }
                            .padding(14)
                            rowDivider
                            compactToggle(L("Official plugins", "官方插件"), isOn: $draftSettings.enablePlugins)
                        }
                    }

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(spacing: 0) {
                            advancedNumberRow(
                                title: L("max-retry-credentials", "max-retry-credentials"),
                                subtitle: L(
                                    "Max accounts to try in one round · 0 = all",
                                    "一轮里最多试几个账号 · 0 = 全部可用"
                                ),
                                value: $draftSettings.maxRetryCredentials,
                                range: 0...64,
                                placeholder: "0"
                            )
                            rowDivider
                            advancedNumberRow(
                                title: L("request-retry", "request-retry"),
                                subtitle: L(
                                    "Max cooldown-wait rounds after accounts are busy",
                                    "账号都忙时，最多再等几轮冷却后重试"
                                ),
                                value: $draftSettings.requestRetry,
                                range: 0...10,
                                placeholder: "3"
                            )
                            rowDivider
                            advancedNumberRow(
                                title: L("max-retry-interval", "max-retry-interval"),
                                subtitle: L(
                                    "Max seconds for each cooldown wait · not total request time",
                                    "每一次等冷却最多几秒 · 不是整次请求总时长"
                                ),
                                value: $draftSettings.maxRetryInterval,
                                range: 1...300,
                                placeholder: "30"
                            )
                        }
                    } label: {
                        Text(L("Advanced", "高级"))
                            .font(.subheadline.weight(.semibold))
                    }
                    .padding(.horizontal, 4)
                    .padding(.bottom, 28)
                }
            }

            if hasUnappliedChanges {
                stickyApplyBar
            }
        }
    }

    private var poolProtectionSection: some View {
        GatewayCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(L("Antigravity pool protection (opt-in)", "Antigravity 分池保护（主动开启）"))
                        .font(.subheadline.weight(.medium))
                    Spacer(minLength: 12)
                    Toggle("", isOn: Binding(
                        get: { poolProtectionEnabled },
                        set: { enabled in
                            do {
                                try AntigravityPoolProtectionSettings.setEnabled(enabled, homeDirectory: tokenSaverHome.path)
                                poolProtectionEnabled = enabled
                                poolProtectionError = nil
                            } catch {
                                poolProtectionError = L("Could not update protection. Check the CPA version, model exclusions and file permissions.", "无法更新保护设置，请检查 CPA 版本、模型排除规则和文件权限。")
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(SwitchToggleStyle(tint: .purple))
                    .controlSize(.small)
                    .tint(.purple)
                    .accessibilityLabel(L("Antigravity pool protection (opt-in)", "Antigravity 分池保护（主动开启）"))
                    .accessibilityIdentifier("antigravity-pool-protection")
                }
                Text(L("Off by default. Requires CPA 8.0.43+. Writes model exclusions for depleted Gemini, Claude/GPT or Argon pools, without disabling other pools. Turning off restores only unchanged protection-owned exclusions. Codex and gateway routing policy are not modified.", "默认关闭，需要 CPA 8.0.43 或更新版本。对耗尽的 Gemini、Claude/GPT 或 Argon 池写入模型排除规则，不停用其他池。关闭时仅恢复未被外部修改的保护规则，不修改 Codex 或网关路由策略。"))
                    .font(.caption).foregroundStyle(.secondary)
                if !poolProtectionEnabled, poolProtectionResidual {
                    Text(L("Off—previous protection exclusions remain", "已关闭，但之前的保护排除规则仍然存在"))
                        .font(.caption).foregroundStyle(.orange)
                        .accessibilityIdentifier("pool-protection-residual")
                    Button(L("Restore previous exclusions", "恢复之前的排除规则")) {
                        do {
                            try AntigravityPoolProtectionSettings.restorePreviousExclusions(homeDirectory: tokenSaverHome.path)
                            reloadPoolProtectionState()
                        } catch {
                            poolProtectionError = error.localizedDescription
                        }
                    }
                    .accessibilityIdentifier("pool-protection-restore")
                }
                if let poolProtectionError { Text(poolProtectionError).font(.caption).foregroundStyle(.red) }
            }
        }
        .onAppear { reloadPoolProtectionState() }
    }

    private func reloadPoolProtectionState() {
        poolProtectionEnabled = AntigravityPoolProtectionSettings.isEnabled(homeDirectory: tokenSaverHome.path)
        do {
            poolProtectionResidual = try AntigravityPoolProtectionSettings.hasResidualProtection(homeDirectory: tokenSaverHome.path)
            poolProtectionError = nil
        } catch { poolProtectionError = error.localizedDescription }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(L("Runtime", "运行"))
                .font(.title3.weight(.semibold))
            if hasUnappliedChanges {
                GatewayQuietBadge(
                    text: needsRestart ? L("Restart needed", "需重启") : L("Unsaved", "未保存"),
                    tint: .orange
                )
            }
            Spacer()
        }
    }

    private var stickyApplyBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 12) {
                Button(L("Reset", "还原")) { draftSettings = runtime.settings }
                    .buttonStyle(.borderless)
                Spacer()
                if needsRestart, runtime.state.isRunning {
                    Text(L("CPA will restart", "将重启 CPA"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Button(action: onApply) {
                    Label(
                        applyButtonTitle,
                        systemImage: needsRestart && runtime.state.isRunning
                            ? "arrow.triangle.2.circlepath"
                            : "checkmark"
                    )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(runtime.state.isTransitioning)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.bar)
        }
    }

    private var applyButtonTitle: String {
        if needsRestart, runtime.state.isRunning {
            return L("Apply & Restart", "应用并重启")
        }
        return L("Apply", "应用")
    }

    private var compactPortRow: some View {
        HStack {
            Text(L("Port", "端口"))
                .font(.subheadline.weight(.medium))
            Spacer()
            TextField(
                "14420",
                value: $draftSettings.port,
                format: IntegerFormatStyle<Int>.number.grouping(.never)
            )
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 88)
            .font(.body.monospacedDigit())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private var compactPickerRow: some View {
        HStack {
            Text(L("Strategy", "策略"))
                .font(.subheadline.weight(.medium))
            Spacer()
            Picker("", selection: $draftSettings.routingStrategy) {
                Text(L("Round robin", "轮询")).tag(CLIProxyRoutingStrategy.roundRobin)
                Text(L("Fill first", "优先用满")).tag(CLIProxyRoutingStrategy.fillFirst)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(maxWidth: 220)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func compactToggle(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 12)
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(SwitchToggleStyle(tint: .purple))
                .controlSize(.small)
                .tint(.purple)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func advancedNumberRow(
        title: String,
        subtitle: String,
        value: Binding<Int>,
        range: ClosedRange<Int>,
        placeholder: String
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.medium).monospaced())
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            TextField(
                placeholder,
                value: value,
                format: IntegerFormatStyle<Int>.number.grouping(.never)
            )
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 72)
            .font(.body.monospacedDigit())
            .onChange(of: value.wrappedValue) { _, newValue in
                value.wrappedValue = min(max(newValue, range.lowerBound), range.upperBound)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var rowDivider: some View {
        Divider().padding(.leading, 14)
    }

    private var lanHint: some View {
        let addresses = runtime.detectedLANBaseURLs(port: draftSettings.normalized.port)
        return VStack(alignment: .leading, spacing: 3) {
            if addresses.isEmpty {
                Text(L("No private IPv4 detected.", "未检测到私有 IPv4。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(addresses, id: \.absoluteString) { address in
                    Text(address.absoluteString)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                }
            }
        }
    }
}


/// Dedicated pane for Token Saver & Context Optimization.
struct SubscriptionGatewaySettingsTokenSaverPane: View {
    var home: URL = FileManager.default.homeDirectoryForCurrentUser
    var rtk: TokenSaverReleaseRTK = .init()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Text(L("Token Saver", "Token 节省"))
                    .font(.title3.weight(.semibold))
                Spacer()
            }
            TokenSaverRuntimeSection(home: home, rtk: rtk)
        }
    }
}

/// Separate observer prevents unrelated runtime form drafts from being replaced.
struct TokenSaverRuntimeSection: View {
    @StateObject private var saver: TokenSaverSettingsController
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, rtk: TokenSaverReleaseRTK = .init()) {
        _saver = StateObject(wrappedValue: TokenSaverSettingsController(home: home, rtk: rtk))
    }

    var body: some View {
        GatewayCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Label(L("Token Saver & Context Optimization", "Token Saver 与上下文优化"), systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(14)
                Divider()
                row(L("Compress tool output (RTK)", "压缩工具输出 (RTK)"), detail: L("Managed coding rules for Antigravity, Claude Code, Codex, OpenCode and Hermes (~/.hermes/SOUL.md). Custom Hermes profiles in ~/.hermes/profiles/* stay isolated. Requires RTK on the agent's PATH; no shell aliases or automatic interception.", "针对 Antigravity、Claude Code、Codex、OpenCode 和 Hermes（~/.hermes/SOUL.md）的托管编程规则。~/.hermes/profiles/* 中的自定义配置保持隔离。需在代理 PATH 中安装 RTK；无 Shell 别名或自动拦截。"), key: \.rtkEnabled, id: "token-saver-rtk")
                Divider()
                row(L("Compress LLM output (Caveman)", "压缩模型输出 (Caveman)"), detail: L("Built-in coding-only concise instructions (works immediately without downloading references). Keeps code exact; no request or response rewriting.", "内置仅限编程的精简输出指令（无需下载参考文档即可直接生效）。保持代码精确，不重写请求或响应。"), key: \.cavemanEnabled, id: "token-saver-caveman")
                Picker(L("Caveman mode", "Caveman 模式"), selection: Binding(
                    get: { saver.settings.cavemanMode },
                    set: { mode in update { $0.cavemanMode = mode } }
                )) {
                    ForEach(TokenSaverSettings.CavemanMode.allCases, id: \.self) { mode in
                        Text(mode.rawValue.capitalized).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 240)
                .padding(.horizontal, 14).padding(.bottom, 12)
                .disabled(!saver.settings.cavemanEnabled || saver.isCheckingSetup)
                .accessibilityIdentifier("token-saver-caveman-mode")
                Divider()
                row(L("Lazy senior dev (Ponytail)", "极简资深开发 (Ponytail)"), detail: L("Built-in coding-only YAGNI, reuse, stdlib-first and minimal verified code (works immediately without downloading references).", "内置仅限编程的 YAGNI、优先复用、标准库优先及最少验证代码规则（无需下载参考文档即可直接生效）。"), key: \.ponytailEnabled, id: "token-saver-ponytail")
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Apply to Coding Agents only", "仅应用于编程代理")).font(.subheadline.weight(.medium))
                        Text(L("Always on. Agent rules apply only to coding tasks; creative writing, scriptwriting, lyrics and customer-care chat are excluded. CPA traffic is never modified.", "始终开启。代理规则仅适用于编程任务；排除创意写作、剧本、歌词及客服聊天，绝不修改 CPA 流量。"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle(L("Apply to Coding Agents only", "仅应用于编程代理"), isOn: .constant(true))
                        .labelsHidden().toggleStyle(SwitchToggleStyle(tint: .indigo)).controlSize(.small).tint(.indigo).disabled(true)
                        .accessibilityIdentifier("token-saver-coding-only")
                }.padding(14)
                Divider()
                onboardingChecklist.padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Compact policies are saved automatically for Antigravity, Claude Code, Codex, OpenCode and Hermes (~/.hermes/SOUL.md) when switches above change. Custom profiles in ~/.hermes/profiles/* stay isolated and are never modified. Full downloaded skills in Updates stay separate as references. Instructions do not guarantee model compliance or token savings.", "上方开关更改时会自动为 Antigravity、Claude Code、Codex、OpenCode 和 Hermes（~/.hermes/SOUL.md）保存精简策略。~/.hermes/profiles/* 中的自定义配置完全隔离，绝不修改。“更新”页下载的完整技能仅作为独立参考文档保留。指令不能保证模型绝对遵守或必然节省 Token。"))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(L("Reapply compact rules", "重新应用精简规则")) { saver.apply(saver.settings) }
                        .disabled(saver.isCheckingSetup)
                        .accessibilityIdentifier("token-saver-reapply")
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
            return L("No automatic rule file exists for this harness; connecting to CLIProxy alone does not load Token Saver rules.", "此代理无自动规则文件；仅连接 CLIProxy 不会加载 Token Saver 规则。")
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
            .disabled(saver.isCheckingSetup)
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
                        Button(L("Copy: brew install rtk", "复制：brew install rtk")) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install rtk", forType: .string)
                        }
                        .controlSize(.small)
                        .accessibilityIdentifier("token-saver-copy-brew-install")
                    }
                }
            }
            Text(saver.localizedRulesStatus)
                .font(.caption).accessibilityIdentifier("token-saver-setup-rules")
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
                Button(L("Copy optional agent diagnostic", "复制可选代理诊断提示词")) {
                    if let commands = saver.onboarding?.agentCommands {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(commands, forType: .string)
                    }
                }
                .disabled(saver.onboarding?.agentCommands == nil || saver.isCheckingSetup)
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
                set: { enabled in update { $0[keyPath: key] = enabled } }
            ))
            .labelsHidden().toggleStyle(SwitchToggleStyle(tint: .purple)).controlSize(.small).tint(.purple)
            .accessibilityIdentifier(id)
            .disabled(saver.isCheckingSetup)
        }.padding(14)
    }
    private func update(_ change: (inout TokenSaverSettings) -> Void) {
        var value = saver.settings
        change(&value)
        saver.apply(value)
    }
}


/// Agent-side instructions only. No request middleware or CPA runtime changes.
@MainActor
final class TokenSaverSettingsController: ObservableObject {
    @Published private(set) var settings = TokenSaverSettings()
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published private(set) var harness = TokenSaverOnboarding.Harness.codex
    @Published private(set) var onboarding: TokenSaverOnboarding.Snapshot?
    @Published private(set) var isCheckingSetup = false
    @Published private(set) var installationStatus = "not checked; install RTK separately"
    @Published private(set) var setupError: String?
    let home: URL
    private let rtk: TokenSaverReleaseRTK

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser, rtk: TokenSaverReleaseRTK = .init()) {
        self.home = home
        self.rtk = rtk
        do { settings = try TokenSaverSettingsStore.load(home: home) }
        catch { self.error = error.localizedDescription }
    }
    func apply(_ value: TokenSaverSettings) {
        guard !isCheckingSetup else { return }
        onboarding = nil
        notice = nil
        do {
            try TokenSaverSettingsStore.save(value, home: home)
            settings = value
            error = nil
            notice = L("Agent settings saved (including ~/.hermes/SOUL.md; custom profiles in ~/.hermes/profiles/* stay isolated). Start a new coding session to reload instructions.", "代理设置已保存（含 ~/.hermes/SOUL.md；~/.hermes/profiles/* 中的自定义配置保持隔离）。请开始新的编程会话以重新加载指令。")
        } catch { self.error = error.localizedDescription }
    }
    func syncHermesTestProfile() {
        guard !isCheckingSetup else { return }
        onboarding = nil
        notice = nil
        do {
            let target = try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
            error = nil
            notice = FileManager.default.fileExists(atPath: target.path)
                ? L("Hermes test rules synchronized. Start a new coding session in token-saver-test's workspace. Sync again after settings changes; bot/default profiles were not modified.", "Hermes 测试规则已同步。请在 token-saver-test 的工作区开启新的编程会话。更改设置后请重新同步；未修改机器人或默认配置。")
                : L("Owned Hermes test rules removed. All tools are off; bot/default profiles were not modified.", "已移除托管的 Hermes 测试规则。所有工具均已关闭；未修改机器人或默认配置。")
        } catch { self.error = error.localizedDescription }
    }
    func selectHarness(_ value: TokenSaverOnboarding.Harness) {
        guard !isCheckingSetup else { return }
        harness = value
        onboarding = nil
        setupError = nil
        notice = nil
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
            return L("2. RTK: \(installationStatus)", "2. RTK：\(prefix)；代理 PATH 未验证")
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
            : L("4. Default RTK history: \(count) records (all harnesses)", "4. 默认 RTK 历史记录：\(count) 条记录（涵盖所有代理）")
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
        isCheckingSetup = true
        setupError = nil
        notice = nil
        onboarding = nil
        installationStatus = "checking Homebrew; agent PATH is not verified"
        defer { isCheckingSetup = false }
        do {
            if let version = try await rtk.installedVersion() {
                installationStatus = "Homebrew \(version); agent PATH is not verified"
            } else { installationStatus = "not installed in Homebrew; other installations/PATH not verified" }
        } catch {
            installationStatus = "not verified"
            setupError = error.localizedDescription
        }
        let home = self.home, harness = self.harness
        onboarding = await Task.detached { TokenSaverOnboarding.inspect(home: home, harness: harness) }.value
    }
}
