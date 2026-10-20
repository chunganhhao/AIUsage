import AppKit
import SwiftUI
import QuotaBackend

extension ProviderAccountEditorView {

    // MARK: - Detection

    func detect() async {
        errorMessage = nil
        failedCandidateIds = []
        showKeyEntry = false
        step = .detecting
        appInstalled = authPlan.appBundleIdentifier
            .flatMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) } != nil
        if authPlan.method == .codexCLI {
            // 解析 CLI 要跑一次登录 shell，放到后台，弹窗先显示「正在查找」。
            codexExecutable = await Task.detached(priority: .userInitiated) { aiusageCodexExecutable() }.value
        } else {
            await Task.yield()
        }
        detected = discoverSessions()
        step = .ready
    }

    /// 本机已有的登录，未连接的排在前面；已在同步的也列出来，而不是悄悄隐藏。
    func discoverSessions() -> [DetectedSession] {
        let monitored = ProviderAuthManager.monitoredSessions(for: providerId)
        let candidates = ProviderAuthManager.deduplicated(
            ProviderAuthManager.discoverCandidates(for: providerId)
                + ProviderAuthManager.savedAPIKeyCandidates(for: providerId)
        )
        let sessions = candidates.map {
            DetectedSession(candidate: $0, isConnected: ProviderAuthManager.isCandidateManaged($0, monitored: monitored))
        }
        return sessions.filter { !$0.isConnected } + sessions.filter(\.isConnected)
    }

    // MARK: - Sign-In

    func startSignIn() {
        errorMessage = nil
        switch authPlan.method {
        case .codexCLI:
            guard let codexExecutable else {
                Task { await detect() }
                return
            }
            step = .signingIn
            codexLogin.start(executable: codexExecutable)
        case .googleOAuth:
            step = .signingIn
            if providerId == "gemini" {
                geminiLogin.start()
            } else {
                antigravityLogin.start()
            }
        case .githubDevice:
            step = .signingIn
            copilotLogin.start()
        case .kiro:
            if appInstalled {
                openAppAndWatch()
            } else {
                startBuilderIDSignIn()
            }
        case .embeddedWeb:
            showWebLogin = true
        case .apiKey:
            showKeyEntry = true
        case .manual:
            Task { await detect() }
        }
    }

    func startBuilderIDSignIn() {
        errorMessage = nil
        step = .signingIn
        kiroLogin.start()
    }

    func retrySignIn() {
        // Kiro 的浏览器登录只有 Builder ID 设备码一种；应用内登录走 waitingForApp。
        if providerId == "kiro" {
            startBuilderIDSignIn()
        } else {
            startSignIn()
        }
    }

    func cancelSignIn() {
        cancelLogins()
        appWatchTask?.cancel()
        appWatchTask = nil
        errorMessage = nil
        detected = discoverSessions()
        step = .ready
    }

    func openDownloadPage() {
        if let url = authPlan.downloadURL {
            NSWorkspace.shared.open(url)
        }
    }

    func handleLoginPhase(_ phase: LoginPhase, from coordinatorProvider: String) {
        guard coordinatorProvider == providerId, step == .signingIn, phase == .succeeded else { return }
        // 失败态留在登录卡片里展示，页脚提供「重试」。
        Task { await completeSignIn() }
    }

    private func completeSignIn() async {
        switch providerId {
        case "codex": await handleCodexLoginSuccess()
        case "gemini": await handleGeminiLoginSuccess()
        case "antigravity": await handleAntigravityLoginSuccess()
        case "copilot": await handleCopilotLoginSuccess()
        case "kiro": await handleKiroLoginSuccess()
        default: break
        }
    }

    // MARK: - Desktop App Sign-In (Kiro / Warp)

    /// 打开服务商应用并等待其中完成登录：Kiro 的 Google / GitHub 等登录只能在应用里完成，
    /// Warp 本身就是额度来源。新的本机会话一出现就自动接入。
    func openAppAndWatch() {
        guard let bundleIdentifier = authPlan.appBundleIdentifier,
              let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) else {
            openDownloadPage()
            return
        }
        errorMessage = nil
        NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        step = .waitingForApp

        let baseline = Set(detected.map { candidateSignature($0.candidate) })
        appWatchTask?.cancel()
        appWatchTask = Task {
            for _ in 0..<90 {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { return }
                let fresh = discoverSessions().first {
                    !$0.isConnected && !baseline.contains(candidateSignature($0.candidate))
                }
                if let fresh {
                    // connect 失败时会取消 appWatchTask；先解除引用，避免取消正在执行的自己。
                    appWatchTask = nil
                    await connect(fresh.candidate)
                    return
                }
            }
            guard !Task.isCancelled else { return }
            appWatchTask = nil
            errorMessage = L("No new sign-in detected yet. Finish signing in, then try again.",
                             "还没有检测到新的登录。完成登录后再试一次。")
            detected = discoverSessions()
            step = .ready
        }
    }

    private func candidateSignature(_ candidate: ProviderAuthCandidate) -> String {
        [
            candidate.sourceIdentifier,
            candidate.sessionFingerprint ?? "",
            String(Int(candidate.modifiedAt?.timeIntervalSince1970 ?? 0))
        ].joined(separator: "|")
    }

    // MARK: - Connecting

    func connect(_ candidate: ProviderAuthCandidate) async {
        await importCandidate(candidate)
    }

    func importCandidate(_ candidate: ProviderAuthCandidate) async {
        appWatchTask?.cancel()
        appWatchTask = nil
        errorMessage = nil
        step = .connecting
        do {
            let (credential, usage) = try await ProviderAuthManager.authenticateCandidate(candidate)
            let resultId = try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
            finishConnection(resultId: resultId, usage: usage, fallbackTitle: candidate.title)
        } catch {
            failedCandidateIds.insert(candidate.id)
            var message = localizedErrorMessage(error)
            if candidate.id == "cursor:desktop-app" {
                message += " " + L("You can sign in to Cursor inside AIUsage instead.", "可以改为在 AIUsage 中登录 Cursor。")
            }
            fail(message)
        }
    }

    func connectAPIKey() {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let region = providerId == "droid" ? ProviderAPIRegion.auto : apiRegion
        errorMessage = nil
        step = .connecting
        Task {
            do {
                let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                    providerId: providerId,
                    authMethod: .apiKey,
                    value: key,
                    suggestedLabel: nil,
                    apiRegion: region
                )
                let resultId = try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
                apiKey = ""
                showKeyEntry = false
                finishConnection(resultId: resultId, usage: usage, fallbackTitle: providerTitle)
            } catch {
                showKeyEntry = true
                fail(localizedErrorMessage(error))
            }
        }
    }

    func importEmbeddedWebSession(cookie: String) async {
        let authMethod: AuthMethod = providerId == "cursor" ? .webSession : .cookie
        errorMessage = nil
        step = .connecting
        do {
            let (credential, usage) = try await ProviderAuthManager.authenticateManualCredential(
                providerId: providerId,
                authMethod: authMethod,
                value: cookie,
                suggestedLabel: nil
            )
            let resultId = try appState.registerAuthenticatedCredential(credential, usage: usage, note: nil)
            finishConnection(resultId: resultId, usage: usage, fallbackTitle: providerTitle)
        } catch {
            fail(localizedErrorMessage(error))
        }
    }

    private func finishConnection(resultId: String?, usage: ProviderUsage, fallbackTitle: String, refreshProvider: Bool = true) {
        let title = usage.accountEmail?.nilIfBlank
            ?? usage.accountLogin?.nilIfBlank.map { "@\($0)" }
            ?? usage.accountName?.nilIfBlank
            ?? fallbackTitle
        failedCandidateIds = []
        withAnimation {
            step = .connected(ConnectedAccount(resultId: resultId, title: title, plan: usage.accountPlan?.nilIfBlank))
        }
        // 账号写入时已插入首批额度；其余服务商在后台补一次完整刷新，弹窗里的额度随之更新。
        if refreshProvider, !shouldSkipImmediateProviderRefresh(for: providerId) {
            Task { _ = await refreshCoordinator.fetchSingleProvider(providerId) }
        }
    }

    /// 服务商返回的英文错误与仪表盘共用同一张中文对照表。
    private func localizedErrorMessage(_ error: Error) -> String {
        refreshCoordinator.localizedDynamicText(SensitiveDataRedactor.redactedMessage(for: error), appState.language)
    }

    private func fail(_ message: String) {
        cancelLogins()
        appWatchTask?.cancel()
        appWatchTask = nil
        errorMessage = message
        detected = discoverSessions()
        step = .ready
    }

    private func shouldSkipImmediateProviderRefresh(for providerId: String) -> Bool {
        providerId == "codex"
            || providerId == "gemini"
            || providerId == "cursor"
    }

    private func cancelLogins() {
        codexLogin.cancel()
        geminiLogin.cancel()
        antigravityLogin.cancel()
        copilotLogin.cancel()
        kiroLogin.cancel()
    }

    func teardown() {
        appWatchTask?.cancel()
        appWatchTask = nil
        cancelLogins()
    }

    // MARK: - Sign-In Completion

    private func handleCodexLoginSuccess() async {
        if let authFileURL = codexLogin.importedAuthFileURL {
            let discoveredCandidates = ProviderAuthManager.discoverCandidates(for: "codex")
            let candidate = discoveredCandidates.first(where: { $0.sourcePath == authFileURL.path })
                ?? ProviderAuthManager.makeCodexCandidate(authFileURL: authFileURL)
            await importCandidate(candidate)
            codexLogin.discardImportedSession()
            return
        }

        let discoveredCandidates = ProviderAuthManager.discoverCandidates(for: providerId)
        guard let candidate = preferredCodexCandidate(
            from: discoveredCandidates,
            preferredPath: NSString(string: "~/.codex/auth.json").expandingTildeInPath,
            startedAt: codexLogin.startedAt
        ) else {
            fail(L("Login succeeded in the browser, but AIUsage could not find the new Codex session yet.",
                   "网页登录已经成功，但 AIUsage 暂时还没有找到新的 Codex 会话。"))
            return
        }
        await importCandidate(candidate)
    }

    private func handleGeminiLoginSuccess() async {
        guard let authFileURL = geminiLogin.importedAuthFileURL else {
            fail(L("Google sign-in succeeded, but AIUsage could not find the Gemini auth file.",
                   "Google 登录已经成功，但 AIUsage 没有找到 Gemini 的认证文件。"))
            return
        }

        let candidate = ProviderAuthCandidate(
            id: "gemini-oauth:\(authFileURL.path)",
            providerId: "gemini",
            sourceIdentifier: "gemini-oauth:\(authFileURL.path)",
            sessionFingerprint: nil,
            title: geminiLogin.accountEmail ?? "Gemini CLI Google Login",
            subtitle: L("Fresh Google login", "新的 Google 登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(candidate)
        geminiLogin.discardImportedSession()
    }

    private func handleAntigravityLoginSuccess() async {
        guard let authFileURL = antigravityLogin.importedAuthFileURL else {
            fail(L("Google sign-in succeeded, but AIUsage could not find the Antigravity auth file.",
                   "Google 登录已经成功，但 AIUsage 没有找到 Antigravity 的认证文件。"))
            return
        }

        let candidate = ProviderAuthCandidate(
            id: "antigravity-oauth:\(authFileURL.path)",
            providerId: "antigravity",
            sourceIdentifier: "antigravity-oauth:\(antigravityLogin.accountEmail?.lowercased() ?? authFileURL.path)",
            sessionFingerprint: nil,
            title: antigravityLogin.accountEmail ?? "Antigravity Google Login",
            subtitle: L("Fresh Google login", "新的 Google 登录"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(candidate)
        antigravityLogin.discardImportedSession()
    }

    private func handleKiroLoginSuccess() async {
        guard let authFileURL = kiroLogin.importedAuthFileURL else {
            fail(L("Kiro sign-in succeeded, but AIUsage could not find the auth file.",
                   "Kiro 登录已成功，但 AIUsage 没有找到认证文件。"))
            return
        }

        let email = kiroLogin.accountEmail
        let sourceId = "kiro-device-flow:\(email?.lowercased() ?? authFileURL.path)"
        let candidate = ProviderAuthCandidate(
            id: "kiro:\(sourceId)",
            providerId: "kiro",
            sourceIdentifier: sourceId,
            sessionFingerprint: nil,
            title: email ?? "Kiro Login",
            subtitle: L("AWS Builder ID", "AWS Builder ID"),
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: authFileURL.path,
            sourcePath: authFileURL.path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )

        await importCandidate(candidate)
        kiroLogin.discardImportedSession()
    }

    private func handleCopilotLoginSuccess() async {
        guard let token = copilotLogin.githubToken, !token.isEmpty else {
            fail(L("GitHub sign-in succeeded, but AIUsage did not receive a token.",
                   "GitHub 登录已成功，但 AIUsage 未收到 token。"))
            return
        }

        let login = copilotLogin.accountLogin
        let email = copilotLogin.accountEmail
        let label = login.map { "@\($0)" } ?? email ?? "GitHub Copilot"
        let sourceId = "gh-device-flow:\(login?.lowercased() ?? email?.lowercased() ?? "default")"

        let candidate = ProviderAuthCandidate(
            id: "copilot:\(sourceId)",
            providerId: "copilot",
            sourceIdentifier: sourceId,
            sessionFingerprint: ProviderAuthManager.tokenFingerprint(token),
            title: label,
            subtitle: L("GitHub Device Flow", "GitHub 设备流登录"),
            detail: email ?? login ?? "",
            modifiedAt: Date(),
            authMethod: .token,
            credentialValue: token,
            sourcePath: nil,
            shouldCopyFile: false,
            identityScope: .accountScoped
        )

        await importCandidate(candidate)
    }

    private func preferredCodexCandidate(
        from candidates: [ProviderAuthCandidate],
        preferredPath: String,
        startedAt: Date?
    ) -> ProviderAuthCandidate? {
        let filteredByTime: [ProviderAuthCandidate]
        if let startedAt {
            let threshold = startedAt.addingTimeInterval(-1)
            let fresh = candidates.filter { ($0.modifiedAt ?? .distantPast) >= threshold }
            filteredByTime = fresh.isEmpty ? candidates : fresh
        } else {
            filteredByTime = candidates
        }

        return filteredByTime.first(where: { $0.sourcePath == preferredPath })
            ?? filteredByTime.sorted { ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast) }.first
    }
}
