import Foundation
import QuotaBackend

enum ProviderAuthManager {
    static func plan(for providerId: String) -> ProviderAuthPlan {
        switch providerId {
        case "codex":
            return ProviderAuthPlan(
                method: .codexCLI,
                summary: L("Sign in with ChatGPT through the official Codex CLI. Your 5-hour and weekly limits appear right after.",
                           "通过官方 Codex CLI 用 ChatGPT 账号登录，连接后立即显示 5 小时与每周额度。"),
                signInTitle: L("Sign in with ChatGPT", "使用 ChatGPT 登录"),
                signedOutTitle: L("Codex isn't signed in on this Mac", "本机 Codex 尚未登录"),
                signedOutDetail: L("Sign in with your ChatGPT account in the browser and AIUsage connects it automatically.",
                                   "在浏览器中登录 ChatGPT 账号，完成后 AIUsage 自动接入。"),
                downloadURL: URL(string: "https://developers.openai.com/codex/cli")
            )
        case "gemini":
            return ProviderAuthPlan(
                method: .googleOAuth,
                summary: L("Sign in with a Google account that has a Gemini Code Assist Standard or Enterprise license. AIUsage receives the authorization itself — no terminal needed.",
                           "使用拥有 Gemini Code Assist Standard / Enterprise 许可的 Google 账号登录，AIUsage 直接接收授权，无需终端。"),
                signInTitle: L("Sign in with Google", "使用 Google 登录"),
                signedOutTitle: L("Gemini CLI isn't signed in on this Mac", "本机 Gemini CLI 尚未登录"),
                signedOutDetail: L("Approve your Google account in the browser and AIUsage connects it automatically.",
                                   "在浏览器中授权 Google 账号，完成后自动接入。"),
                notice: ProviderAuthPlan.Notice(
                    title: L("Personal Google accounts no longer work", "个人 Google 账号已无法使用"),
                    detail: L("Google stopped Gemini CLI for free, Google AI Pro and Ultra accounts on June 18, 2026. Only Gemini Code Assist Standard or Enterprise licenses can connect — connect personal accounts through Antigravity instead.",
                              "Google 已于 2026 年 6 月 18 日停止为免费、Google AI Pro 与 Ultra 账号提供 Gemini CLI，只有 Gemini Code Assist Standard / Enterprise 许可仍可连接。个人账号请改为连接 Antigravity。")
                )
            )
        case "antigravity":
            return ProviderAuthPlan(
                method: .googleOAuth,
                summary: L("Sign in with Google to see Antigravity's per-model quotas.",
                           "使用 Google 账号登录，按模型查看 Antigravity 额度。"),
                signInTitle: L("Sign in with Google", "使用 Google 登录"),
                signedOutTitle: L("Antigravity isn't signed in on this Mac", "本机 Antigravity 尚未登录"),
                signedOutDetail: L("Approve your Google account in the browser — Antigravity doesn't need to be installed.",
                                   "在浏览器中授权 Google 账号即可，无需安装 Antigravity。")
            )
        case "copilot":
            return ProviderAuthPlan(
                method: .githubDevice,
                summary: L("Authorize with GitHub to see Copilot entitlements and premium requests.",
                           "使用 GitHub 授权，查看 Copilot 权益与高级请求额度。"),
                signInTitle: L("Sign in with GitHub", "使用 GitHub 登录"),
                signedOutTitle: L("GitHub CLI isn't signed in on this Mac", "本机 GitHub CLI 尚未登录"),
                signedOutDetail: L("AIUsage copies a one-time code and opens GitHub — paste it there to approve. No gh CLI needed.",
                                   "AIUsage 会复制一次性验证码并打开 GitHub，粘贴确认即可，无需安装 gh。")
            )
        case "kiro":
            return ProviderAuthPlan(
                method: .kiro,
                summary: L("Connect the account signed in to the Kiro app — Google, GitHub, Builder ID and organization logins all work.",
                           "连接 Kiro 应用当前登录的账号，Google、GitHub、Builder ID 与组织账号均可。"),
                signInTitle: L("Sign In in Kiro", "在 Kiro 中登录"),
                signedOutTitle: L("Kiro isn't signed in on this Mac", "本机 Kiro 尚未登录"),
                signedOutDetail: L("Sign in to the Kiro app with any method and AIUsage connects it automatically. You can also authorize an AWS Builder ID directly.",
                                   "在 Kiro 应用中用任意方式登录，AIUsage 会自动接入；也可以直接授权 AWS Builder ID。"),
                appBundleIdentifier: "dev.kiro.desktop",
                downloadURL: URL(string: "https://kiro.dev/downloads/")
            )
        case "cursor":
            return ProviderAuthPlan(
                method: .embeddedWeb,
                summary: L("Connect the account signed in to the Cursor app, or sign in to cursor.com inside AIUsage.",
                           "连接 Cursor 应用当前登录的账号，或在 AIUsage 内登录 cursor.com。"),
                signInTitle: L("Sign In to Cursor", "登录 Cursor"),
                signedOutTitle: L("Cursor isn't signed in on this Mac", "本机 Cursor 尚未登录"),
                signedOutDetail: L("Sign in to cursor.com in AIUsage's built-in browser and the account connects automatically.",
                                   "在 AIUsage 内置浏览器中登录 cursor.com，完成后自动接入。")
            )
        case "warp":
            return ProviderAuthPlan(
                method: .apiKey,
                summary: L("Paste a personal Warp API key (wk-…) to track your credits through Warp's official API, including bonus credits.",
                           "粘贴 Warp 个人 API Key（wk-…），通过 Warp 官方接口追踪积分，含奖励积分。"),
                signInTitle: L("Connect", "连接"),
                signedOutTitle: L("No Warp API key found", "未找到 Warp API Key"),
                signedOutDetail: ""
            )
        case "kimi":
            return ProviderAuthPlan(
                method: .apiKey,
                summary: L("Keys from the Kimi Code CLI or your AIUsage API providers are detected automatically, or paste one from the Kimi Code Console. Shows the same weekly usage and rate-limit windows as /usage.",
                           "自动检测 Kimi Code CLI 与 AIUsage API 提供商里的 Key，也可以粘贴控制台创建的 Key。显示与 /usage 一致的本周用量和频控窗口。"),
                signInTitle: L("Connect", "连接"),
                signedOutTitle: L("No Kimi Code key found", "未找到 Kimi Code Key"),
                signedOutDetail: ""
            )
        case "minimax":
            return ProviderAuthPlan(
                method: .apiKey,
                summary: L("Paste a Token Plan Subscription Key (sk-cp-…) to track the 5-hour rolling and weekly windows. Subscription keys already in your AIUsage API providers are detected automatically.",
                           "粘贴 Token Plan 订阅 Key（sk-cp-…），同时追踪 5 小时滚动与每周额度。AIUsage API 提供商里已有的订阅 Key 会自动检测。"),
                signInTitle: L("Connect", "连接"),
                signedOutTitle: L("No MiniMax Subscription Key found", "未找到 MiniMax 订阅 Key"),
                signedOutDetail: ""
            )
        case "droid":
            return ProviderAuthPlan(
                method: .apiKey,
                summary: L("Paste a Factory API key (fk-…). It's the most stable way to read Droid usage; keys in your shell profile are detected automatically.",
                           "粘贴 Factory API Key（fk-…），这是读取 Droid 用量最稳定的方式；shell 配置里的 Key 会自动检测。"),
                signInTitle: L("Connect", "连接"),
                signedOutTitle: L("No Factory API key found", "未找到 Factory API Key"),
                signedOutDetail: ""
            )
        default:
            return ProviderAuthPlan(
                method: .manual,
                summary: L("Finish the provider's own sign-in first, then AIUsage can connect and monitor that account.",
                           "先完成服务商自己的登录，之后 AIUsage 才能连接并监控这个账号。"),
                signInTitle: L("Check Again", "重新检测"),
                signedOutTitle: L("No sign-in found on this Mac", "本机未检测到登录"),
                signedOutDetail: L("Sign in with the provider's app or CLI, then check again.",
                                   "在服务商的应用或 CLI 中登录后，点击重新检测。")
            )
        }
    }

    static func makeCodexCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let json = loadJSONObject(at: path)
        let tokens = json?["tokens"] as? [String: Any]
        let email = jwtEmail(from: stringValue(tokens?["id_token"]))
            ?? jwtEmail(from: stringValue(json?["id_token"]))
            ?? stringValue(json?["email"])
        let fingerprint: String?
        if let json {
            fingerprint = codexSessionFingerprint(from: json)
        } else {
            fingerprint = nil
        }

        return ProviderAuthCandidate(
            id: "codex-oauth:\(path)",
            providerId: "codex",
            sourceIdentifier: "codex-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Codex ChatGPT Login",
            subtitle: "Fresh login",
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func makeAntigravityCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let json = loadJSONObject(at: path)
        let email = stringValue(json?["email"])
            ?? jwtEmail(from: stringValue(json?["id_token"]))
            ?? jwtEmail(from: stringValue(json?["access_token"]))
        let fingerprint: String?
        if let json {
            fingerprint = sessionFingerprint(from: json)
        } else {
            fingerprint = nil
        }

        return ProviderAuthCandidate(
            id: "antigravity-oauth:\(path)",
            providerId: "antigravity",
            sourceIdentifier: "antigravity-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Antigravity Login",
            subtitle: "From CPA",
            detail: authFileURL.lastPathComponent,
            modifiedAt: Date(),
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func makeGeminiCandidate(authFileURL: URL) -> ProviderAuthCandidate {
        let path = authFileURL.path
        let data = try? Data(contentsOf: authFileURL, options: .mappedIfSafe)
        let email = data.flatMap { CLIProxyGeminiCredentialBridge.accountEmail(from: $0) }
        let json = loadJSONObject(at: path)
        let fingerprint = json.flatMap {
            sessionFingerprint(from: $0, preferredKeys: ["email"])
        } ?? email.flatMap { normalizedHandle($0) }

        return ProviderAuthCandidate(
            id: "gemini-oauth:\(path)",
            providerId: "gemini",
            sourceIdentifier: "gemini-oauth:\(path)",
            sessionFingerprint: fingerprint,
            title: email ?? "Gemini CLI Login",
            subtitle: "From CPA",
            detail: authFileURL.lastPathComponent,
            modifiedAt: (try? authFileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate,
            authMethod: .authFile,
            credentialValue: path,
            sourcePath: path,
            shouldCopyFile: true,
            identityScope: .sharedSource
        )
    }

    static func discoverCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let rawCandidates: [ProviderAuthCandidate]

        switch providerId {
        case "codex":
            rawCandidates = codexCandidates()
        case "cursor":
            rawCandidates = cursorCandidates()
        case "copilot":
            rawCandidates = copilotCandidates()
        case "antigravity":
            rawCandidates = antigravityCandidates()
        case "kimi":
            rawCandidates = kimiCandidates()
        case "kiro":
            rawCandidates = kiroCandidates()
        case "gemini":
            rawCandidates = geminiCandidates()
        case "droid":
            rawCandidates = droidCandidates()
        default:
            // minimax 没有本地 CLI 配置可扫描；AIUsage 已保存的 Key 见 savedAPIKeyCandidates（仅连接弹窗使用）。
            rawCandidates = []
        }

        return rawCandidates.sorted {
            if $0.modifiedAt != $1.modifiedAt {
                return ($0.modifiedAt ?? .distantPast) > ($1.modifiedAt ?? .distantPast)
            }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    static func unmanagedCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let monitored = monitoredSessions(for: providerId)
        return discoverCandidates(for: providerId).filter { !isCandidateManaged($0, monitored: monitored) }
    }

    static func monitoredSessions(for providerId: String) -> ProviderMonitoredSessionIndex {
        let credentials = AccountCredentialStore.shared.loadCredentials(for: providerId)
        return ProviderMonitoredSessionIndex(
            sourceIdentifiers: Set(credentials.compactMap { credential in
                guard sourceIdentifierIsStableIdentity(for: credential) else { return nil }
                return credential.metadata["sourceIdentifier"]
                    ?? credential.metadata["sourcePath"]
                    ?? authFileSourceIdentifier(for: credential.credential, authMethod: credential.authMethod)
            }),
            sessionFingerprints: Set(credentials.compactMap { credential in
                if providerId == "codex" {
                    return CodexAccountIdentity(credential: credential).key
                        ?? credential.metadata["sessionFingerprint"].flatMap { $0.hasPrefix("codex:") ? $0 : nil }
                }
                return normalizedHandle(credential.metadata["sessionFingerprint"])
            }),
            accountHandles: Set(credentials.compactMap { credential in
                normalizedHandle(
                    credential.metadata["accountHandle"]
                        ?? credential.metadata["accountEmail"]
                        ?? credential.accountLabel
                )
            })
        )
    }

    static func authenticateCandidate(_ candidate: ProviderAuthCandidate) async throws -> (AccountCredential, ProviderUsage) {
        var copiedPath: String?
        do {
            let credentialValue: String
            if candidate.authMethod == .authFile, candidate.shouldCopyFile, let sourcePath = candidate.sourcePath {
                copiedPath = try copyImportedAuthFile(
                    providerId: candidate.providerId,
                    sourcePath: sourcePath,
                    suggestedName: candidate.title
                )
                credentialValue = copiedPath ?? sourcePath
            } else {
                credentialValue = candidate.credentialValue
            }

            let storedSourcePath = candidate.sourcePath ?? ""

            let credential = AccountCredential(
                providerId: candidate.providerId,
                accountLabel: candidate.title.nilIfBlank,
                authMethod: candidate.authMethod,
                credential: credentialValue,
                metadata: [
                    "sourceIdentifier": candidate.sourceIdentifier,
                    "sourcePath": storedSourcePath,
                    "importedAt": SharedFormatters.iso8601String(from: Date()),
                    "sessionFingerprint": candidate.sessionFingerprint ?? "",
                    "identityScope": candidate.identityScope.rawValue
                ]
            )

            let usage = try await validate(credential: credential)
            return (credential, usage)
        } catch {
            if let copiedPath {
                try? FileManager.default.removeItem(atPath: copiedPath)
            }
            throw error
        }
    }

    static func authenticateManualCredential(
        providerId: String,
        authMethod: AuthMethod,
        value: String,
        suggestedLabel: String? = nil,
        apiRegion: ProviderAPIRegion = .auto
    ) async throws -> (AccountCredential, ProviderUsage) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderError("missing_credential", "Credential value is empty.")
        }

        var metadata: [String: String] = [
            "sourceIdentifier": "manual:\(authMethod.rawValue):\(UUID().uuidString)",
            "importedAt": SharedFormatters.iso8601String(from: Date()),
            "identityScope": ProviderAuthCandidate.IdentityScope.sharedSource.rawValue
        ]
        if apiRegion != .auto {
            metadata[ProviderAPIRegion.metadataKey] = apiRegion.rawValue
        }
        // 与本地发现的 Key 候选同一指纹：之后再打开连接弹窗时，同一个 Key 会显示为「已在同步」。
        if authMethod == .apiKey {
            metadata["sessionFingerprint"] = tokenFingerprint(trimmed)
        }

        var credential = AccountCredential(
            providerId: providerId,
            accountLabel: suggestedLabel?.nilIfBlank,
            authMethod: authMethod,
            credential: trimmed,
            metadata: metadata
        )
        let usage = try await validate(credential: credential)
        // 自动探测成功后把实际命中区域写回，后续刷新直打对应端点。
        if let resolved = (usage.extra[ProviderAPIRegion.metadataKey]?.value as? String)?.nilIfBlank {
            credential.metadata[ProviderAPIRegion.metadataKey] = resolved
        }
        return (credential, usage)
    }

    // MARK: - Validation

    private static func validate(credential: AccountCredential) async throws -> ProviderUsage {
        guard let provider = ProviderRegistry.provider(for: credential.providerId) as? any CredentialAcceptingProvider else {
            throw ProviderError("unsupported_provider", "\(credential.providerId) does not accept imported credentials.")
        }
        return try await provider.fetchUsage(with: credential)
    }

    // MARK: - Import Persistence

    private static func copyImportedAuthFile(
        providerId: String,
        sourcePath: String,
        suggestedName: String
    ) throws -> String {
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let directory = try managedImportDirectory(for: providerId)
        let stem = sanitizedFilenameStem(suggestedName)
        let filename = "\(stem)-\(DateFormat.string(from: Date(), format: "yyyyMMdd-HHmmss")).json"
        let destinationURL = directory.appendingPathComponent(filename)

        let data: Data
        let normalizedProviderID = CLIProxyCredentialAdapter.normalizedProviderID(providerId)
        if providerId == "droid",
           let normalizedData = DroidProvider.managedSessionData(from: sourcePath) {
            data = normalizedData
        } else if normalizedProviderID == "gemini" {
            data = try CLIProxyGeminiCredentialBridge.makeNativePayload(
                from: Data(contentsOf: sourceURL, options: .mappedIfSafe)
            )
        } else {
            data = try Data(contentsOf: sourceURL)
        }
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL.path
    }

    private static func managedImportDirectory(for providerId: String) throws -> URL {
        let directory = try ProviderManagedImportStore.managedImportsRootDirectory()
            .appendingPathComponent(providerId, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
