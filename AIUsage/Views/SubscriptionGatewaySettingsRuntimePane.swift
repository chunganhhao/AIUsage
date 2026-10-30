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
                    TokenSaverRuntimeSection(home: tokenSaverHome)

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


/// Separate observer prevents unrelated runtime form drafts from being replaced.
struct TokenSaverRuntimeSection: View {
    @StateObject private var saver: TokenSaverSettingsController
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        _saver = StateObject(wrappedValue: TokenSaverSettingsController(home: home))
    }

    var body: some View {
        GatewayCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Label("Token Saver & Context Optimization", systemImage: "bolt.fill")
                    .font(.subheadline.weight(.semibold))
                    .padding(14)
                Divider()
                row("Compress tool output (RTK)", detail: "Managed coding rules for Antigravity, Claude Code, Codex and OpenCode. Requires RTK on the agent's PATH; no shell aliases or automatic interception.", key: \.rtkEnabled, id: "token-saver-rtk")
                Divider()
                row("Compress LLM output (Caveman)", detail: "Coding-only concise instructions. Keeps code exact; no request or response rewriting.", key: \.cavemanEnabled, id: "token-saver-caveman")
                Picker("Caveman mode", selection: Binding(
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
                .disabled(!saver.settings.cavemanEnabled)
                .accessibilityIdentifier("token-saver-caveman-mode")
                Divider()
                row("Lazy senior dev (Ponytail)", detail: "Coding-only YAGNI, reuse, stdlib-first and minimal verified code.", key: \.ponytailEnabled, id: "token-saver-ponytail")
                Divider()
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Apply to Coding Agents only").font(.subheadline.weight(.medium))
                        Text("Always on. Agent rules apply only to coding work; RonC scripts, lyrics and Zalo/customer-care work are excluded. CPA traffic is never modified.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Toggle("Apply to Coding Agents only", isOn: .constant(true))
                        .labelsHidden().toggleStyle(SwitchToggleStyle(tint: .indigo)).controlSize(.small).tint(.indigo).disabled(true)
                        .accessibilityIdentifier("token-saver-coding-only")
                }.padding(14)
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("Compact policies are saved for Antigravity, Claude Code, Codex and OpenCode. Full downloaded skills stay separate as references. Instructions do not guarantee model compliance or token savings.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Reapply compact rules") { saver.apply(saver.settings) }
                        .accessibilityIdentifier("token-saver-reapply")
                    Text("Hermes test integration is explicit: create token-saver-test first, then sync its workspace rules below. Sync again after changing settings; all three off removes only owned test rules. Bot/default profiles and connections are never changed.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Sync Hermes test profile") { saver.syncHermesTestProfile() }
                        .accessibilityIdentifier("token-saver-hermes-sync")
                    Text("Start a new coding session to reload instructions. RTK must be installed separately on the agent's PATH.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let notice = saver.notice {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("token-saver-notice")
                    }
                    if let error = saver.error {
                        Text(error).font(.caption).foregroundStyle(.red)
                            .accessibilityIdentifier("token-saver-error")
                    }
                }.padding(14)
            }
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
    private let home: URL

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
        do { settings = try TokenSaverSettingsStore.load(home: home) }
        catch { self.error = error.localizedDescription }
    }
    func apply(_ value: TokenSaverSettings) {
        notice = nil
        do {
            try TokenSaverSettingsStore.save(value, home: home)
            settings = value
            error = nil
            notice = "Agent settings saved. Start a new coding session; sync Hermes test rules separately if needed."
        } catch { self.error = error.localizedDescription }
    }
    func syncHermesTestProfile() {
        notice = nil
        do {
            let target = try TokenSaverSettingsStore.exportHermesTestProfile(home: home)
            error = nil
            notice = FileManager.default.fileExists(atPath: target.path)
                ? "Hermes test rules synchronized. Start a new coding session in token-saver-test's workspace. Sync again after settings changes; bot/default profiles were not modified."
                : "Owned Hermes test rules removed. All tools are off; bot/default profiles were not modified."
        } catch { self.error = error.localizedDescription }
    }
}
