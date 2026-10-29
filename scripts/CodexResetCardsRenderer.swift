import SwiftUI
import AppKit
@testable import QuotaBackend

@main
struct CodexResetCardsRenderer {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        guard let scratchPath = ProcessInfo.processInfo.environment["TMPDIR"], !scratchPath.isEmpty else {
            preconditionFailure("Set TMPDIR to the fixture scratch directory")
        }
        let scratch = URL(fileURLWithPath: scratchPath, isDirectory: true).standardizedFileURL
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).standardizedFileURL
        precondition(output.path.hasPrefix(scratch.path + "/"), "Fixture output must stay in scratch")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let directory = scratch.appendingPathComponent("reset-ui-fixture-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        StubURLProtocol.install(hosts: ["chatgpt.com"])
        defer { StubURLProtocol.uninstall(); try? FileManager.default.removeItem(at: directory) }

        // 品牌图取自仓库资源，真实 ProviderIconView 不需要生产 bundle 或凭据。
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let assetDirectory = root.appendingPathComponent("AIUsage/Resources/Assets.xcassets/ProviderIcons/codex.imageset")
        if let asset = try FileManager.default.contentsOfDirectory(at: assetDirectory, includingPropertiesForKeys: nil).first(where: { ["png", "pdf", "jpg"].contains($0.pathExtension) }),
           let icon = NSImage(contentsOf: asset) { icon.setName("codex") }

        let now = Date()
        let endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
        let appState = AppState()
        let refresh = ProviderRefreshCoordinator()
        let activation = ProviderActivationManager()
        let settings = AppSettings.shared
        var manifest: [[String: Any]] = []

        for (language, scheme) in [("zh", ColorScheme.dark), ("en", ColorScheme.light)] {
            fixtureLanguage = language
            let credentials = try (0..<3).map { index -> AccountCredential in
                let claims = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": ["chatgpt_account_id": "fixture-\(index)", "chatgpt_user_id": "fixture-user-\(index)"]])
                    .base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                let authURL = directory.appendingPathComponent("auth-\(index).json")
                try JSONSerialization.data(withJSONObject: ["last_refresh": SharedFormatters.iso8601String(from: now),
                    "tokens": ["account_id": "fixture-\(index)", "access_token": "fixture", "id_token": "e30.\(claims).test"]]).write(to: authURL)
                return AccountCredential(id: "fixture-credential-\(index)", providerId: "codex", authMethod: .authFile, credential: authURL.path,
                                         metadata: ["accountId": "fixture-\(index)", "workspaceUserId": "fixture-user-\(index)"])
            }
            let coordinator = CodexResetCreditsCoordinator(operations: .init(journalURL: directory.appendingPathComponent("pending-\(language).json")),
                loadCredential: { id in credentials.first { $0.id == id } }, isLocal: { true })
            FixtureResetEnvironment.coordinator = coordinator
            let labels = [L("Studio account", "创作账号"), L("Personal account", "个人账号"), L("Backup account", "备用账号")]
            let targets = credentials.enumerated().map { index, credential in
                CodexResetCreditsCoordinator.Target(identity: CodexAccountIdentity(credential: credential), credentialID: credential.id,
                    label: labels[index] + " · " + L("Studio workspace", "创作工作区"), isLocal: true)
            }
            let details = try detailsJSON(now: now)
            StubURLProtocol.respond(endpoint, body: details)
            await coordinator.load(targets[0])
            StubURLProtocol.respond(endpoint, body: #"{"available_count":0,"credits":[]}"#)
            await coordinator.load(targets[1])
            // 未知状态通过实际失败路径形成，刷新控件与提示均来自正式视图。
            StubURLProtocol.respond(endpoint, status: 503, body: "{}")
            await coordinator.load(targets[2])
            StubURLProtocol.respond(endpoint) { request in
                let account = request.headers.first { $0.key.lowercased() == "chatgpt-account-id" }?.value
                if account == "fixture-0" { return (200, details) }
                if account == "fixture-1" { return (200, #"{"available_count":0,"credits":[]}"#) }
                return (503, "{}")
            }
            let providers = (0..<3).map { index in
                provider(index: index, credential: credentials[index], label: labels[index], count: [8, 0, nil][index], now: now)
            }
            FixtureResetEnvironment.credentialIDs = Dictionary(uniqueKeysWithValues: zip(providers.map(\.id), credentials.map(\.id)))
            let remote = CodexResetCreditsCoordinator.Target(identity: .init(accountId: "fixture-remote", userId: "fixture-remote-user"),
                credentialID: nil, label: L("archive.design.and.research@example.invalid · Shared archive workspace with a long account name", "设计与研究联合归档账号@example.invalid · 跨团队协作归档工作区的完整账号名称"), isLocal: false)

            let main = FixtureShowcase(providers: providers, target: targets[0], coordinator: coordinator, scheme: scheme)
                .environmentObject(appState).environmentObject(refresh).environmentObject(activation).environmentObject(settings)
            let mainSize = try await render(main, scheme: scheme, width: 830, to: output.appendingPathComponent("reset-cards-\(language)-\(scheme == .dark ? "dark" : "light").png"))
            let states = FixtureStates(empty: targets[1], unknown: targets[2], remote: remote,
                                       coordinator: coordinator, scheme: scheme)
            let stateSize = try await render(states, scheme: scheme, width: 1314, to: output.appendingPathComponent("reset-cards-states-\(language)-\(scheme == .dark ? "dark" : "light").png"))
            let menu = FixtureMenuBar(providers: providers, scheme: scheme)
                .environmentObject(appState).environmentObject(refresh).environmentObject(activation)
            _ = try await render(menu, scheme: scheme, width: 420,
                to: output.appendingPathComponent("menu-bar-codex-\(language)-\(scheme == .dark ? "dark" : "light").png"))
            let subscription = CodexSubscriptionSection(entries: providers.map { ProviderAccountEntry(id: $0.id, providerId: "codex", providerTitle: "Codex", providerSubtitle: nil, liveProvider: $0, storedAccount: nil) })
                .padding(20).frame(width: 680).background(AppSurface.page(scheme))
                .environmentObject(appState).environmentObject(refresh)
            _ = try await render(subscription, scheme: scheme, width: 680,
                to: output.appendingPathComponent("codex-account-list-\(language)-\(scheme == .dark ? "dark" : "light").png"))
            let balanceTargets = [
                APIKeyBalanceTarget(baseURL: "https://balance.fixture/v1", apiKey: "fixture")!,
                APIKeyBalanceTarget(baseURL: "https://openrouter.ai/api/v1", apiKey: "fixture")!,
                APIKeyBalanceTarget(baseURL: "https://unsupported.fixture/v1", apiKey: "fixture")!,
                APIKeyBalanceTarget(baseURL: "https://denied.fixture/v1", apiKey: "fixture")!
            ]
            StubURLProtocol.respond("https://balance.fixture/api/usage/token/", body: #"{"code":true,"data":{"object":"token_usage","total_available":2500000,"unlimited_quota":false,"user_quota":{"total_available":7500000}}}"#)
            StubURLProtocol.respond("https://balance.fixture/api/status", body: #"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"USD"}}"#)
            StubURLProtocol.respond("https://openrouter.ai/api/v1/key", body: #"{"data":{"limit":null,"limit_remaining":null}}"#)
            StubURLProtocol.respond("https://denied.fixture/api/usage/token/", status: 403, body: "{}")
            for target in balanceTargets { await NodeBalanceStore.shared.refresh(target, force: true) }
            let balances = FixtureNodeBalances(targets: balanceTargets, scheme: scheme)
            _ = try await render(balances, scheme: scheme, width: 680,
                to: output.appendingPathComponent("node-balance-states-\(language)-\(scheme == .dark ? "dark" : "light").png"))
            let creditStates = FixtureCreditStates(scheme: scheme)
            _ = try await render(creditStates, scheme: scheme, width: 680,
                to: output.appendingPathComponent("codex-credit-states-\(language)-\(scheme == .dark ? "dark" : "light").png"))
            manifest.append(["language": language, "mainPoints": [mainSize.width, mainSize.height], "statesPoints": [stateSize.width, stateSize.height]])
        }
        precondition(!StubURLProtocol.requests.contains { $0.method != "GET" }, "Renderer permits GET fixtures only; zero POST")
        try JSONSerialization.data(withJSONObject: ["rendered": manifest, "requests": StubURLProtocol.requests.count, "postCount": 0,
            "nativeProviderCard": true, "sharedEntry": true, "polling": false, "userCredentialReads": false,
            "fixtureNow": SharedFormatters.iso8601String(from: now)], options: [.prettyPrinted, .sortedKeys])
            .write(to: output.appendingPathComponent("render-manifest.json"))
        print("PASS: actual ProviderCard + MultiWindowQuotaView + shared CodexResetCreditsEntry + CodexResetCreditsView; Chinese/dark and English/light; zero POST; no polling or user credential reads")
    }

    @MainActor static func detailsJSON(now: Date) throws -> String {
        func card(_ id: String, title: String, expires: Any, type: String = "codex_rate_limits") -> [String: Any] {
            ["id": id, "reset_type": type, "status": "available", "expires_at": expires, "title": title]
        }
        let credits = [
            card("soon", title: L("Codex quota reset", "Codex 额度重置"), expires: SharedFormatters.iso8601String(from: now.addingTimeInterval(2 * 86_400))),
            card("later", title: L("Codex quota reset", "Codex 额度重置"), expires: SharedFormatters.iso8601String(from: now.addingTimeInterval(30 * 86_400))),
            card("unlimited", title: L("Codex quota reset", "Codex 额度重置"), expires: NSNull()),
            card("unknown", title: L("Reset card · type unconfirmed", "重置卡 · 类型待确认"), expires: "invalid", type: "future_kind")
        ]
        return String(data: try JSONSerialization.data(withJSONObject: ["available_count": 8, "credits": credits]), encoding: .utf8)!
    }

    @MainActor static func provider(index: Int, credential: AccountCredential, label: String, count: Int?, now: Date) -> ProviderData {
        ProviderData(id: "fixture-provider-\(index)", providerId: "codex", accountId: "fixture-\(index)", name: "Codex", label: label,
            description: "", category: "quota", channel: "cli", status: .healthy, statusLabel: "Healthy",
            theme: .init(accent: "indigo", glow: ""), sourceLabel: "", sourceType: "fixture", fetchedAt: SharedFormatters.iso8601String(from: now),
            accountLabel: label, membershipLabel: "Plus", workspaceLabel: nil, workspaceUserId: "fixture-user-\(index)",
            headline: .init(eyebrow: "", primary: "", secondary: "", supporting: ""),
            metrics: [.init(label: L("Credits", "积分"), value: [L("1234.6 credits", "1234.6 积分"), L("0 credits", "0 积分"), L("Unlimited", "无限")][index], note: nil)],
            windows: [
                .init(label: "5-hour", remainingPercent: [28, 82, 63][index], usedPercent: nil, value: "", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(4 * 3_600))),
                .init(label: "Weekly", remainingPercent: [64, 91, 76][index], usedPercent: nil, value: "", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(4 * 86_400)))
            ], remainingPercent: 28, nextResetAt: nil, nextResetLabel: nil, spotlight: nil, models: nil, costSummary: nil,
            sourceFilePath: credential.credential, codexResetCreditsAvailableCount: count)
    }

    @MainActor static func render<V: View>(_ root: V, scheme: ColorScheme, width: CGFloat, to url: URL) async throws -> CGSize {
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.setFrameSize(NSSize(width: width, height: 1))
        // 不 orderFront、不启动 App；按 SwiftUI 的真实内容高度截取离屏 NSHostingView。
        let height = ceil(hosting.fittingSize.height)
        precondition(height > 100 && height < 1400, "Unexpected fixture height: \(height)")
        let size = NSSize(width: width, height: height)
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { fatalError("No fixture bitmap") }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("No fixture PNG") }
        try png.write(to: url)
        window.contentView = nil
        return size
    }
}

private struct FixtureShowcase: View {
    let providers: [ProviderData]
    let target: CodexResetCreditsCoordinator.Target
    let coordinator: CodexResetCreditsCoordinator
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("Subscription monitor", "订阅监控")).font(.system(size: 20, weight: .semibold))
                Spacer()
                Text("AIUsage").font(.system(size: 12, weight: .medium)).foregroundStyle(AppContent.secondary(scheme))
            }
            HStack(alignment: .top, spacing: 26) {
                VStack(spacing: 12) {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, provider in
                        ProviderCard(provider: provider, footerAccountLabelOverride: [L("Studio workspace", "创作工作区"), L("Personal workspace", "个人空间"), L("Backup workspace", "备用空间")][index])
                    }
                }
                .frame(width: 346)
                VStack(alignment: .leading, spacing: 12) {
                    CodexResetCreditsView(target: target, knownCount: 8, refreshUsage: { true }, coordinator: coordinator)
                        .fixturePanel(scheme)
                    Label(L("Review expiry dates. Confirm before use.", "查看到期时间，确认后再使用。"), systemImage: "checkmark.shield")
                        .font(.caption).foregroundStyle(AppContent.secondary(scheme)).padding(.leading, 10)
                }
                .padding(.top, 92)
            }
            Text(L("SwiftUI preview · Sample accounts", "SwiftUI 预览 · 示例账号"))
                .font(.caption2).foregroundStyle(AppContent.secondary(scheme))
        }
        .padding(24)
        .frame(width: 830)
        .foregroundStyle(AppContent.primary(scheme))
        .background(AppSurface.page(scheme))
    }
}

private struct FixtureStates: View {
    let empty: CodexResetCreditsCoordinator.Target
    let unknown: CodexResetCreditsCoordinator.Target
    let remote: CodexResetCreditsCoordinator.Target
    let coordinator: CodexResetCreditsCoordinator
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("Reset cards · Other states", "重置卡 · 其他状态")).font(.system(size: 18, weight: .semibold))
            HStack(alignment: .top, spacing: 18) {
                CodexResetCreditsView(target: empty, knownCount: 0, refreshUsage: { true }, coordinator: coordinator).fixturePanel(scheme)
                CodexResetCreditsView(target: unknown, knownCount: nil, refreshUsage: { true }, coordinator: coordinator).fixturePanel(scheme)
                CodexResetCreditsView(target: remote, knownCount: 3, refreshUsage: { true }, coordinator: coordinator).fixturePanel(scheme)
            }
            Text(L("SwiftUI preview · Zero / unknown / remote / long account", "SwiftUI 预览 · 零张 / 未知 / 远程只读 / 长账号"))
                .font(.caption2).foregroundStyle(AppContent.secondary(scheme))
        }
        .padding(24)
        .frame(width: 1314)
        .foregroundStyle(AppContent.primary(scheme))
        .background(AppSurface.page(scheme))
    }
}

private extension View {
    func fixturePanel(_ scheme: ColorScheme) -> some View {
        clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AppStroke.card(scheme), lineWidth: 1))
            .shadow(color: AppShadow.floatingPanel(scheme).opacity(0.35), radius: 12, x: 0, y: 5)
    }
}

private struct FixtureMenuBar: View {
    let providers: [ProviderData]
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Menu bar · Codex accounts", "菜单栏 · Codex 账号")).font(.headline)
            ForEach(providers) { provider in
                MenuBarAccountRow(
                    entry: .init(id: provider.id, providerId: "codex", providerTitle: "Codex", providerSubtitle: nil,
                                 liveProvider: provider, storedAccount: nil),
                    providerId: "codex", accentColor: .indigo,
                    codexProxyActive: false, codexGlobalProxyManaged: false,
                    activationMessage: .constant(nil), activationSuccess: .constant(false))
            }
            Text(L("Right-click an account to use its earliest-expiring reset card.", "右键账号可使用最早到期的重置卡。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 420)
        .background(AppSurface.page(scheme))
    }
}

private struct FixtureNodeBalances: View {
    let targets: [APIKeyBalanceTarget]
    let scheme: ColorScheme
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L("Node balance · Shared component", "节点额度 · 共用组件")).font(.headline)
            ForEach(Array(targets.enumerated()), id: \.offset) { index, target in
                VStack(alignment: .leading, spacing: 3) {
                    Text([L("Supported gateway", "支持查询的网关"), L("Uncapped key", "Key 未设限"),
                          L("Unsupported provider", "不支持查询的提供商"), L("Permission denied", "无查询权限")][index])
                        .font(.system(size: 13, weight: .semibold))
                    Text(target.rootURL.host ?? "").font(.caption).foregroundStyle(.secondary)
                    NodeBalanceLine(target: target)
                }
            }
            Text(L("Unsupported and failed queries leave no balance row. Refresh and status are in the context menu.",
                   "不支持或查询失败时不保留余额行；刷新与状态位于右键菜单。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24).frame(width: 680).background(AppSurface.page(scheme))
    }
}

private struct FixtureCreditStates: View {
    let scheme: ColorScheme
    private let values: [String?] = ["1234.6 credits", "0 credits", "Available", "No available credits", nil, "Unlimited"]
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Codex credits · Explicit states", "Codex 积分 · 状态区分")).font(.headline)
            ForEach(values.indices, id: \.self) { index in
                CodexCreditsBalanceView(value: values[index])
            }
        }
        .padding(24).frame(width: 680).background(AppSurface.page(scheme))
    }
}
