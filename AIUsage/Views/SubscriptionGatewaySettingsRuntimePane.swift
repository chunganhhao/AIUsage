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
                                "Fill first drains an available account. Round robin spreads requests. Earliest Weekly Reset uses refreshed weekly reset times within your existing priority tiers; unknown resets come last.",
                                "优先用满：耗尽可用账号。轮询：分散请求。最早每周重置优先：在原有优先级内优先使用即将周重置的账号，未知重置时间排后。"
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
                            if CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild {
                                compactToggle(L("Official plugins", "官方插件"), isOn: $draftSettings.enablePlugins)
                            } else {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(L("Official plugins", "官方插件"))
                                            .font(.subheadline.weight(.medium))
                                        Text(L(
                                            "Disabled in API-key-only build",
                                            "仅 API Key 构建已强制禁用"
                                        ))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 12)
                                    Toggle("", isOn: .constant(false))
                                        .labelsHidden()
                                        .toggleStyle(SwitchToggleStyle(tint: .purple))
                                        .controlSize(.small)
                                        .disabled(true)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 11)
                            }
                        }
                    }

                    DisclosureGroup("Agent tools: Warmup, Config Sets & Environment") {
                        AgentToolsSettingsView(home: tokenSaverHome)
                    }
                    .disclosureGroupStyle(FullRowDisclosureStyle())
                    .accessibilityIdentifier("gateway-agent-tools")

                    DisclosureGroup(isExpanded: $showAdvanced) {
                        VStack(spacing: 0) {
                            advancedNumberRow(
                                title: L("max-retry-credentials", "max-retry-credentials"),
                                subtitle: L(
                                    "Locked to 1 (zero credential failover enforced)",
                                    "已锁定为 1（强制禁止跨账号重试）"
                                ),
                                value: .constant(1),
                                range: 1...1,
                                placeholder: "1"
                            )
                            .disabled(true)
                            rowDivider
                            advancedNumberRow(
                                title: L("request-retry", "request-retry"),
                                subtitle: L(
                                    "Locked to 0 (no automatic cooldown retry rounds)",
                                    "已锁定为 0（禁止自动重试）"
                                ),
                                value: .constant(0),
                                range: 0...0,
                                placeholder: "0"
                            )
                            .disabled(true)
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
                    .disclosureGroupStyle(FullRowDisclosureStyle())
                    .padding(.horizontal, 4)
                    .padding(.bottom, 28)
                }
            }

            if hasUnappliedChanges {
                stickyApplyBar
            }
        }
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
        Picker(L("Strategy", "策略"), selection: $draftSettings.routingStrategy) {
            Text(L("Round robin", "轮询")).tag(CLIProxyRoutingStrategy.roundRobin)
            Text(L("Fill first", "优先用满")).tag(CLIProxyRoutingStrategy.fillFirst)
            Text(L("Weekly reset first", "每周重置优先")).tag(CLIProxyRoutingStrategy.earliestWeeklyReset)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("gateway-routing-strategy")
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

// Pool settings apply independently of the Runtime draft/apply lifecycle.
struct SubscriptionGatewaySettingsProtectionPane: View {
    var tokenSaverHome: URL = FileManager.default.homeDirectoryForCurrentUser
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Pool Protection", "账号池保护")).font(.title3.weight(.semibold))
            GatewayCard { CodexPoolProtectionControls(home: tokenSaverHome) }
        }
    }
}
