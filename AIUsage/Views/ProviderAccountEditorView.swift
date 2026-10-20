import AppKit
import SwiftUI
import QuotaBackend

/// 连接订阅账号：先识别本机已有的登录，一键接入；没有时再按各服务商自己的方式登录。
/// 流程与 Claude 订阅一致：检测 → 确认 → 连接 → 显示首批额度，全程不打开终端。
struct ProviderAccountEditorView: View {
    let providerId: String

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var refreshCoordinator: ProviderRefreshCoordinator
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var colorScheme
    @StateObject var codexLogin = CodexLoginCoordinator()
    @StateObject var geminiLogin = GeminiLoginCoordinator()
    @StateObject var antigravityLogin = AntigravityLoginCoordinator()
    @StateObject var copilotLogin = CopilotLoginCoordinator()
    @StateObject var kiroLogin = KiroLoginCoordinator()

    enum Step: Equatable {
        case detecting
        /// 检测完成：展示本机会话，或该服务商的登录方式 / Key 输入。
        case ready
        /// 浏览器 / 设备码登录进行中。
        case signingIn
        /// 已打开服务商应用（Kiro），等待用户在应用里完成登录。
        case waitingForApp
        case connecting
        case connected(ConnectedAccount)
    }

    struct DetectedSession: Identifiable, Equatable {
        let candidate: ProviderAuthCandidate
        let isConnected: Bool
        var id: String { candidate.id }
    }

    struct ConnectedAccount: Equatable {
        let resultId: String?
        let title: String
        let plan: String?
    }

    struct FooterAction: Identifiable {
        let id: String
        let title: String
        var isDisabled = false
        let perform: () -> Void
    }

    @State var step: Step = .detecting
    @State var detected: [DetectedSession] = []
    /// 连接失败过的本机会话不再作为默认操作，避免反复点到同一个失效登录。
    @State var failedCandidateIds: Set<String> = []
    @State var errorMessage: String?
    @State var codexExecutable: String?
    @State var appInstalled = false
    @State var showKeyEntry = false
    @State var apiKey = ""
    @State var apiRegion: ProviderAPIRegion = .auto
    @State var showWebLogin = false
    @State var showBatchImport = false
    @State var appWatchTask: Task<Void, Never>?

    var providerTitle: String {
        appState.providerCatalogItem(for: providerId)?.title(for: appState.language) ?? providerId
    }

    var authPlan: ProviderAuthPlan {
        ProviderAuthManager.plan(for: providerId)
    }

    var accent: Color {
        MenuBarColors.accent(for: providerId)
    }

    var supportsBatchImport: Bool {
        BatchAuthFileScanner.authFileProviderIds.contains(providerId)
    }

    var body: some View {
        if providerId == "claude-subscription" {
            ClaudeSubscriptionConnectionView()
        } else {
            connectFlow
        }
    }

    private var connectFlow: some View {
        VStack(alignment: .leading, spacing: 20) {
            header
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .animation(.easeInOut(duration: 0.2), value: step)
            footer
        }
        .padding(24)
        .frame(width: 480)
        .appPageChrome(colorScheme)
        .interactiveDismissDisabled(step == .connecting)
        .task { await detect() }
        .onDisappear { teardown() }
        .onReceive(codexLogin.$phase) { handleLoginPhase($0, from: "codex") }
        .onReceive(geminiLogin.$phase) { handleLoginPhase($0, from: "gemini") }
        .onReceive(antigravityLogin.$phase) { handleLoginPhase($0, from: "antigravity") }
        .onReceive(copilotLogin.$phase) { handleLoginPhase($0, from: "copilot") }
        .onReceive(kiroLogin.$phase) { handleLoginPhase($0, from: "kiro") }
        .sheet(isPresented: $showWebLogin) {
            if let loginURL = ProviderLoginURLs.loginURL(for: providerId) {
                WebLoginView(
                    providerId: providerId,
                    loginURL: loginURL,
                    cookieDomains: ProviderLoginURLs.cookieDomains(for: providerId),
                    cookieNames: ProviderLoginURLs.cookieNames(for: providerId),
                    onComplete: { cookie in
                        Task { await importEmbeddedWebSession(cookie: cookie) }
                    }
                )
                .environmentObject(appState)
            }
        }
        .sheet(isPresented: $showBatchImport, onDismiss: { detected = discoverSessions() }) {
            BatchImportView(providerId: providerId)
                .environmentObject(appState)
                .environmentObject(refreshCoordinator)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ProviderIconView(providerId, size: 36)
            VStack(alignment: .leading, spacing: 3) {
                Text(L("Connect \(providerTitle)", "连接 \(providerTitle)")).font(.title3.bold())
                Text(authPlan.summary)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch step {
        case .detecting:
            ConnectProgressRow(text: L("Looking for \(providerTitle) on this Mac…", "正在查找本机的 \(providerTitle) 登录…"))
        case .ready:
            readyContent
        case .signingIn:
            activeLoginCard
        case .waitingForApp:
            ConnectWaitingRow(text: waitingForAppText)
        case .connecting:
            ConnectProgressRow(text: L("Connecting…", "正在连接…"))
        case .connected(let account):
            connectedContent(account)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            secondaryActionsView
            Spacer()
            footerButtons
        }
    }

    @ViewBuilder
    private var secondaryActionsView: some View {
        let actions = secondaryActions
        if let first = actions.first {
            Button(first.title, action: first.perform)
                .buttonStyle(.link)
        }
        if actions.count > 1 {
            Menu {
                ForEach(actions.dropFirst()) { action in
                    Button(action.title, action: action.perform)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More ways to connect", "更多连接方式"))
        }
    }

    @ViewBuilder
    private var footerButtons: some View {
        switch step {
        case .detecting:
            Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
        case .ready:
            Button(L("Cancel", "取消")) { dismiss() }.keyboardShortcut(.cancelAction)
            if let primary = readyPrimaryAction {
                Button(primary.title, action: primary.perform)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(primary.isDisabled)
            }
        case .signingIn:
            if case .failed = activeLoginPhase {
                Button(L("Back", "返回")) { cancelSignIn() }.keyboardShortcut(.cancelAction)
                Button(L("Try Again", "重试")) { retrySignIn() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            } else {
                Button(L("Cancel", "取消")) { cancelSignIn() }.keyboardShortcut(.cancelAction)
            }
        case .waitingForApp:
            Button(L("Cancel", "取消")) { cancelSignIn() }.keyboardShortcut(.cancelAction)
        case .connecting:
            Button(L("Cancel", "取消")) { dismiss() }.disabled(true)
        case .connected:
            Button(L("Done", "完成")) { dismiss() }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
        }
    }

    // MARK: - Footer Actions

    /// 未连接、且没失败过的本机会话；恰好一个时由页脚主按钮直接连接。
    var connectableSessions: [DetectedSession] {
        detected.filter { !$0.isConnected && !failedCandidateIds.contains($0.id) }
    }

    var readyPrimaryAction: FooterAction? {
        let connectable = connectableSessions
        if authPlan.method == .apiKey, showKeyEntry || connectable.isEmpty {
            return FooterAction(
                id: "connect-key",
                title: L("Connect", "连接"),
                isDisabled: apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                perform: connectAPIKey
            )
        }
        if connectable.count == 1, let session = connectable.first {
            return FooterAction(id: "connect", title: L("Connect", "连接")) {
                Task { await connect(session.candidate) }
            }
        }
        if connectable.count > 1 { return nil }

        switch authPlan.method {
        case .codexCLI where codexExecutable == nil, .manual:
            return FooterAction(id: "detect", title: L("Check Again", "重新检测")) { Task { await detect() } }
        case .kiro where !appInstalled:
            return FooterAction(id: "builder-id", title: L("Sign in with AWS Builder ID", "使用 AWS Builder ID 登录"), perform: startBuilderIDSignIn)
        default:
            return FooterAction(id: "sign-in", title: authPlan.signInTitle, perform: startSignIn)
        }
    }

    var secondaryActions: [FooterAction] {
        switch step {
        case .ready:
            var actions: [FooterAction] = []
            // 主按钮在连接本机会话时，新登录退为次要入口（与 Claude 的「添加其他账号…」一致）。
            let primaryConnectsSession = !connectableSessions.isEmpty
            switch authPlan.method {
            case .codexCLI:
                if codexExecutable == nil {
                    actions.append(FooterAction(id: "install", title: L("Install Codex CLI", "安装 Codex CLI"), perform: openDownloadPage))
                } else if primaryConnectsSession {
                    actions.append(signInAnotherAction)
                }
            case .googleOAuth, .githubDevice, .embeddedWeb:
                if primaryConnectsSession { actions.append(signInAnotherAction) }
            case .kiro:
                if appInstalled {
                    if primaryConnectsSession {
                        actions.append(FooterAction(id: "kiro-app", title: L("Sign in another account in Kiro…", "在 Kiro 中登录其他账号…"), perform: openAppAndWatch))
                    }
                    actions.append(FooterAction(id: "builder-id", title: L("Use an AWS Builder ID instead…", "改用 AWS Builder ID 登录…"), perform: startBuilderIDSignIn))
                } else {
                    if primaryConnectsSession {
                        actions.append(FooterAction(id: "builder-id", title: L("Use an AWS Builder ID instead…", "改用 AWS Builder ID 登录…"), perform: startBuilderIDSignIn))
                    }
                    actions.append(FooterAction(id: "download", title: L("Get Kiro", "下载 Kiro"), perform: openDownloadPage))
                }
            case .apiKey:
                if primaryConnectsSession, !showKeyEntry {
                    actions.append(FooterAction(id: "manual-key", title: L("Enter a key manually…", "手动输入 Key…")) { showKeyEntry = true })
                }
            case .manual:
                break
            }
            if supportsBatchImport {
                actions.append(FooterAction(id: "batch", title: L("Batch import from folder…", "从文件夹批量导入…")) { showBatchImport = true })
            }
            return actions
        case .connected:
            return [FooterAction(id: "another", title: L("Add another account…", "添加其他账号…")) { Task { await detect() } }]
        default:
            return []
        }
    }

    private var signInAnotherAction: FooterAction {
        FooterAction(id: "sign-in-another", title: L("Sign in with another account…", "使用其他账号登录…"), perform: startSignIn)
    }

    private var waitingForAppText: String {
        L("Sign in to the Kiro app with any method. AIUsage connects automatically as soon as you're signed in.",
          "在 Kiro 应用中用任意方式登录，完成后 AIUsage 会自动接入。")
    }
}
