import Foundation
import QuotaBackend
import SQLite3

extension ProviderAuthManager {
    // MARK: - Candidate Discovery

    internal static func codexCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        let defaultURL = URL(fileURLWithPath: expand("~/.codex/auth.json"))
        // API Key 模式（OPENAI_API_KEY）没有 ChatGPT 订阅额度，不作为可连接的账号。
        if FileManager.default.fileExists(atPath: defaultURL.path),
           let json = loadJSONObject(at: defaultURL.path),
           stringValue(json["OPENAI_API_KEY"]) == nil {
            let idToken = stringValue((json["tokens"] as? [String: Any])?["id_token"])
            let email = jwtEmail(from: idToken) ?? stringValue(json["email"])
            candidates.append(
                ProviderAuthCandidate(
                    id: "codex:\(canonicalPath(defaultURL.path))",
                    providerId: "codex",
                    sourceIdentifier: "file:\(canonicalPath(defaultURL.path))",
                    sessionFingerprint: codexSessionFingerprint(from: json),
                    title: email ?? "ChatGPT account",
                    subtitle: L("Signed in to Codex on this Mac", "本机 Codex 当前登录的账号"),
                    detail: compactDetail(parts: [displayPath(defaultURL.path), formattedDate(modificationDate(for: defaultURL))]),
                    modifiedAt: modificationDate(for: defaultURL),
                    authMethod: .authFile,
                    credentialValue: defaultURL.path,
                    sourcePath: defaultURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource,
                    plan: CodexProvider.planDisplayName(forRaw: jwtAuthClaim("chatgpt_plan_type", from: idToken))
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func copilotCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        if let session = currentGitHubCLISession() {
            candidates.append(
                ProviderAuthCandidate(
                    id: "copilot:\(session.sourceIdentifier)",
                    providerId: "copilot",
                    sourceIdentifier: session.sourceIdentifier,
                    sessionFingerprint: session.sessionFingerprint,
                    title: session.label,
                    subtitle: L("Signed in to GitHub CLI (gh)", "GitHub CLI（gh）当前登录的账号"),
                    detail: session.detail,
                    modifiedAt: nil,
                    authMethod: .token,
                    credentialValue: session.token,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .accountScoped
                )
            )
        }

        return deduplicated(candidates)
    }

    internal static func antigravityCandidates(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> [ProviderAuthCandidate] {
        guard let payload = AntigravityAccountSwitcher.discoverIDECandidatePayload(homeDirectory: homeDirectory) else {
            return []
        }

        let email = payload.email
        let name = payload.name
        let title = email ?? name ?? "Antigravity IDE session"
        let sourceId = "antigravity-ide:\(email?.lowercased() ?? "default")"

        let fileManager = FileManager.default
        let sessionDir = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-antigravity-import-\(sourceId.hashValue)", isDirectory: true)
        try? fileManager.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        let authFileURL = sessionDir.appendingPathComponent("antigravity_ide_creds.json")

        var authJSON: [String: Any] = [
            "access_token": payload.accessToken,
            "token_type": "Bearer",
            "expired": "2000-01-01T00:00:00Z"
        ]
        if let email { authJSON["email"] = email }
        if let refreshToken = payload.refreshToken, !refreshToken.isEmpty {
            authJSON["refresh_token"] = refreshToken
        }

        guard let data = try? JSONSerialization.data(withJSONObject: authJSON, options: [.prettyPrinted, .sortedKeys]),
              let _ = try? data.write(to: authFileURL, options: .atomic) else {
            return []
        }

        let dbURL = URL(fileURLWithPath: payload.databasePath)
        let modifiedAt = modificationDate(for: dbURL)

        return [
            ProviderAuthCandidate(
                id: "antigravity:\(sourceId)",
                providerId: "antigravity",
                sourceIdentifier: sourceId,
                sessionFingerprint: normalizedHandle(email),
                title: title,
                subtitle: L("Signed in to the Antigravity app", "Antigravity 应用当前登录的账号"),
                detail: compactDetail(parts: [email, formattedDate(modifiedAt)].compactMap { $0 }),
                modifiedAt: modifiedAt,
                authMethod: .authFile,
                credentialValue: authFileURL.path,
                sourcePath: authFileURL.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        ]
    }

    private static let kiroFingerprintKeys = ["email", "userId", "accountEmail", "profile_arn", "profileArn"]

    internal static func kiroCandidates() -> [ProviderAuthCandidate] {
        var candidates: [ProviderAuthCandidate] = []

        let ideURL = URL(fileURLWithPath: expand("~/.aws/sso/cache/kiro-auth-token.json"))
        if FileManager.default.fileExists(atPath: ideURL.path),
           let json = loadJSONObject(at: ideURL.path) {
            let method = kiroLoginMethodName(stringValue(json["provider"]))
            candidates.append(
                ProviderAuthCandidate(
                    id: "kiro:\(canonicalPath(ideURL.path))",
                    providerId: "kiro",
                    sourceIdentifier: "file:\(canonicalPath(ideURL.path))",
                    sessionFingerprint: sessionFingerprint(from: json, preferredKeys: kiroFingerprintKeys),
                    title: stringValue(json["email"]) ?? method.map { "Kiro · \($0)" } ?? "Kiro",
                    subtitle: L("Signed in to the Kiro app", "Kiro 应用当前登录的账号"),
                    detail: compactDetail(parts: [displayPath(ideURL.path), formattedDate(modificationDate(for: ideURL))]),
                    modifiedAt: modificationDate(for: ideURL),
                    authMethod: .authFile,
                    credentialValue: ideURL.path,
                    sourcePath: ideURL.path,
                    shouldCopyFile: true,
                    identityScope: .sharedSource
                )
            )
        }

        return deduplicated(candidates)
    }

    private static func kiroLoginMethodName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw.lowercased() {
        case "google": return "Google"
        case "github": return "GitHub"
        case "builderid": return "Builder ID"
        case "enterprise", "idc": return "IAM Identity Center"
        default: return raw
        }
    }

    internal static func kimiCandidates() -> [ProviderAuthCandidate] {
        let localCandidates = KimiProvider.discoverLocalCredentials().map { local -> ProviderAuthCandidate in
            let fingerprint = tokenFingerprint(local.apiKey)
            let modifiedAt = modificationDate(for: URL(fileURLWithPath: local.sourcePath))
            return ProviderAuthCandidate(
                id: "kimi:\(fingerprint)",
                providerId: "kimi",
                sourceIdentifier: "kimi-config:\(fingerprint)",
                sessionFingerprint: fingerprint,
                title: "Kimi Code",
                subtitle: "Kimi Code CLI · \(displayPath(local.sourcePath))",
                detail: compactDetail(parts: [maskedSecret(local.apiKey), formattedDate(modifiedAt)]),
                modifiedAt: modifiedAt,
                authMethod: .apiKey,
                credentialValue: local.apiKey,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        }
        return deduplicated(localCandidates)
    }

    /// AIUsage「API 提供商」里已保存的订阅 Key 同样能读取额度，省去再去控制台复制一次。
    /// 这些只作为连接弹窗里的建议，不进入 discoverCandidates——刷新时的自动接入不会悄悄把它们加成账号。
    @MainActor
    static func savedAPIKeyCandidates(for providerId: String) -> [ProviderAuthCandidate] {
        let isSubscriptionKey: (APIProvider, String) -> Bool
        switch providerId {
        case "kimi":
            isSubscriptionKey = { provider, key in
                key.hasPrefix("sk-kimi") || provider.baseURL.lowercased().contains("kimi.com/coding")
            }
        case "minimax":
            // MiniMax 只认 Token Plan 订阅 Key（sk-cp-…），按量付费 Key 读不到额度。
            isSubscriptionKey = { _, key in key.hasPrefix("sk-cp-") }
        default:
            return []
        }
        return APIProviderStore.shared.providers.compactMap { provider in
            let key = provider.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, isSubscriptionKey(provider, key) else { return nil }
            let fingerprint = tokenFingerprint(key)
            return ProviderAuthCandidate(
                id: "\(providerId):api-provider:\(fingerprint)",
                providerId: providerId,
                sourceIdentifier: "api-provider-key:\(fingerprint)",
                sessionFingerprint: fingerprint,
                title: provider.name.nilIfBlank ?? maskedSecret(key),
                subtitle: L("Saved in AIUsage API providers", "AIUsage API 提供商中保存的 Key"),
                detail: compactDetail(parts: [maskedSecret(key), provider.baseURL.nilIfBlank]),
                modifiedAt: provider.lastUsedAt,
                authMethod: .apiKey,
                credentialValue: key,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        }
    }

    private static func maskedSecret(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 10 else { return "••••" }
        return "\(trimmed.prefix(6))…\(trimmed.suffix(4))"
    }

    internal static func geminiCandidates() -> [ProviderAuthCandidate] {
        let oauthURL = URL(fileURLWithPath: expand("~/.gemini/oauth_creds.json"))
        guard FileManager.default.fileExists(atPath: oauthURL.path),
              let json = loadJSONObject(at: oauthURL.path) else {
            return []
        }

        let email = stringValue(json["email"])
            ?? jwtEmail(from: stringValue(json["id_token"]))
            ?? geminiActiveAccountEmail()
            ?? "Google account"
        return [
            ProviderAuthCandidate(
                id: "gemini:\(canonicalPath(oauthURL.path))",
                providerId: "gemini",
                sourceIdentifier: "file:\(canonicalPath(oauthURL.path))",
                sessionFingerprint: sessionFingerprint(from: json, preferredKeys: ["email"]),
                title: email,
                subtitle: L("Signed in to Gemini CLI", "Gemini CLI 当前登录的账号"),
                detail: compactDetail(parts: [displayPath(oauthURL.path), formattedDate(modificationDate(for: oauthURL))]),
                modifiedAt: modificationDate(for: oauthURL),
                authMethod: .authFile,
                credentialValue: oauthURL.path,
                sourcePath: oauthURL.path,
                shouldCopyFile: true,
                identityScope: .sharedSource
            )
        ]
    }

    /// 旧版 oauth_creds.json 不含邮箱；Gemini CLI 另把当前账号记在 google_accounts.json 的 active 字段。
    private static func geminiActiveAccountEmail() -> String? {
        stringValue(loadJSONObject(at: expand("~/.gemini/google_accounts.json"))?["active"])
    }

    /// Droid 仅保留官方 API Key（fk-…）方式：浏览器 Cookie / auth.v2.file 刷新令牌那套
    /// 既脆弱（频繁「不可用」）、浏览器登录又常失效（Login state invalid/expired），所以这里
    /// 只发现 FACTORY_API_KEY 候选，连接面板也只暴露粘贴 Key 一条路径——最稳、最安全。
    /// 注意：后端仍保留 authFile/cookie 的处理，以兼容历史已存凭证，只是不再主动发现。
    internal static func droidCandidates() -> [ProviderAuthCandidate] {
        deduplicated(factoryAPIKeyCandidates())
    }

    /// 发现官方 FACTORY_API_KEY（fk-…）。CLI 文档建议把它写进 shell profile（~/.zshrc 等）或
    /// 作为环境变量，因此这里扫描环境变量与常见 profile 文件，作为 .apiKey 候选呈现。
    /// 注意：GUI 应用通常不继承交互式 shell 的环境变量，所以多数情况下要靠 profile 扫描或手动粘贴。
    internal static func factoryAPIKeyCandidates() -> [ProviderAuthCandidate] {
        var found: [(key: String, source: String)] = []

        if let envKey = ProcessInfo.processInfo.environment["FACTORY_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !envKey.isEmpty {
            found.append((envKey, "FACTORY_API_KEY (env)"))
        }

        let profiles = ["~/.zshrc", "~/.zprofile", "~/.bashrc", "~/.bash_profile", "~/.profile"]
        for rawPath in profiles {
            let path = expand(rawPath)
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            for key in factoryAPIKeys(inShellProfile: contents) {
                found.append((key, displayPath(path)))
            }
        }

        var seen = Set<String>()
        return found.compactMap { entry -> ProviderAuthCandidate? in
            let fingerprint = tokenFingerprint(entry.key)
            guard seen.insert(fingerprint).inserted else { return nil }
            return ProviderAuthCandidate(
                id: "droid:apikey:\(fingerprint)",
                providerId: "droid",
                sourceIdentifier: "factory-api-key:\(fingerprint)",
                sessionFingerprint: fingerprint,
                title: "Factory API Key",
                subtitle: entry.source,
                detail: compactDetail(parts: [maskedSecret(entry.key), entry.source]),
                modifiedAt: nil,
                authMethod: .apiKey,
                credentialValue: entry.key,
                sourcePath: nil,
                shouldCopyFile: false,
                identityScope: .accountScoped
            )
        }
    }

    private static let factoryAPIKeyRegex = try? NSRegularExpression(
        pattern: #"FACTORY_API_KEY\s*=\s*["']?(fk-[A-Za-z0-9._-]+)["']?"#
    )

    /// 从 shell profile 文本里抽取 `FACTORY_API_KEY=fk-…` 形式的赋值（兼容 export 与引号）。
    private static func factoryAPIKeys(inShellProfile contents: String) -> [String] {
        guard let regex = factoryAPIKeyRegex else { return [] }
        let range = NSRange(contents.startIndex..., in: contents)
        return regex.matches(in: contents, range: range).compactMap { match in
            guard match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: contents) else { return nil }
            return String(contents[valueRange])
        }
    }

    internal static func cursorCandidates() -> [ProviderAuthCandidate] {
        // Cursor 应用的登录可直接使用，也不会像读取浏览器 Cookie 那样弹出钥匙串授权；
        // 只有应用未登录时才回退扫描浏览器。
        if let session = CursorProvider.discoverDesktopAppSession() {
            return [
                ProviderAuthCandidate(
                    id: "cursor:desktop-app",
                    providerId: "cursor",
                    sourceIdentifier: "cursor-desktop-app",
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.email ?? "Cursor account",
                    subtitle: L("Signed in to the Cursor app", "Cursor 应用当前登录的账号"),
                    detail: "cursor.com",
                    modifiedAt: nil,
                    authMethod: .webSession,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource,
                    plan: session.plan
                )
            ]
        }
        return deduplicated(
            CursorProvider.discoverBrowserSessions().map { session in
                let profileLabel = "\(session.browserName) \(session.profileName)"
                let sourceIdentifier = "browser-profile:cursor:\(session.browserName.lowercased()):\(session.profileName.lowercased())"
                return ProviderAuthCandidate(
                    id: "cursor:\(sourceIdentifier)",
                    providerId: "cursor",
                    sourceIdentifier: sourceIdentifier,
                    sessionFingerprint: tokenFingerprint(session.cookieHeader),
                    title: session.accountHint ?? "Cursor account",
                    subtitle: L("Signed in to cursor.com in \(session.browserName)", "\(session.browserName) 中登录的 cursor.com"),
                    detail: compactDetail(parts: [profileLabel, "cursor.com"]),
                    modifiedAt: nil,
                    authMethod: .cookie,
                    credentialValue: session.cookieHeader,
                    sourcePath: nil,
                    shouldCopyFile: false,
                    identityScope: .sharedSource
                )
            }
        )
    }
}
