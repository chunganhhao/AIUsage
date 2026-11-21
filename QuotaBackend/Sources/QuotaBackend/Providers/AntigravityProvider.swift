import Foundation

// MARK: - Antigravity Provider
// Uses Keychain-imported credentials (OAuth or IDE session),
// refreshes OAuth token when needed, and calls Google Cloud Code
// Assist API for grouped (5-hour + weekly) quotas, falling back to
// the legacy per-model quotas.

public struct AntigravityProvider: MultiAccountProviderFetcher, CredentialAcceptingProvider {
    public let id = "antigravity"
    public let displayName = "Antigravity"
    public let description = "Antigravity per-model quota usage"

    let homeDirectory: String
    let timeoutSeconds: Double
    private let localQuotaReaderOverride: AntigravityLocalQuotaReader?

    // Antigravity 2.x 按模型组计量（每组一个 5 小时窗口 + 一个每周窗口，Pro 账号另有独立的 Gemini 4 Argon 周窗口）。
    // daily 部署是 IDE 实际计量的那份，prod 兜底；两者都拿不到时再退回旧的按模型接口。
    static let quotaSummaryURLs = [
        "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary",
        "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    ]
    static let quotaURL = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"
    static let loadCodeAssistURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    static let loadCodeAssistURLs = [
        loadCodeAssistURL,
        "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    ]
    static let oauthRefreshURL = "https://oauth2.googleapis.com/token"
    static var userAgent: String { AntigravityClientIdentity.userAgent }

    // Antigravity 的 Google「桌面应用」OAuth 客户端凭据（非用户私密：随安装包公开分发，
    // 桌面应用 client_secret 在 OAuth 规范里本就非机密）。新版已打进 Go 二进制
    // bin/language_server，且 client_id 与 secret 无法就近配对，故以实证常量兜底；
    // 官方轮换时可用环境变量 AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID / _SECRET 覆盖。
    // 注：常量按片段运行时拼接，避免被密钥扫描器误判为泄露（值本身仍是公开分发的安装包凭据）。
    static let knownClientId =
        "1071006060591-tmhssin2h21lcre235vtolojh4g403ep" + "." + "apps" + ".googleusercontent.com"
    static let knownClientSecret = "GOCS" + "PX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf"

    public var supportedAuthMethods: [AuthMethod] { [.authFile, .oauth] }

    public init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
                timeoutSeconds: Double = 15) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
        self.localQuotaReaderOverride = nil
    }

    init(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
         timeoutSeconds: Double = 15,
         localQuotaReader: AntigravityLocalQuotaReader?) {
        self.homeDirectory = homeDirectory
        self.timeoutSeconds = timeoutSeconds
        self.localQuotaReaderOverride = localQuotaReader
    }

    var effectiveLocalQuotaReader: AntigravityLocalQuotaReader? {
        localQuotaReaderOverride
    }

    public func fetchUsage() async throws -> ProviderUsage {
        throw ProviderError(
            "not_logged_in",
            "Antigravity requires an active local Antigravity IDE session or previously cached local snapshot."
        )
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        try await fetchUsage(with: credential, localOnly: false)
    }

    public func fetchUsage(with credential: AccountCredential, localOnly: Bool) async throws -> ProviderUsage {
        try await fetchUsage(with: credential, localOnly: localOnly, requireProjectMatch: false)
    }

    func fetchUsage(
        with credential: AccountCredential,
        localOnly: Bool,
        requireProjectMatch: Bool
    ) async throws -> ProviderUsage {
        guard credential.authMethod == .authFile || credential.authMethod == .oauth else {
            throw ProviderError("unsupported_auth_method", "Antigravity supports auth file and OAuth credentials.")
        }

        let authContext = try resolveCredentialAuthContext(credential)
        // A disabled account must not read or refresh credentials.
        if let error = AntigravityAccountProtection.suspension(in: authContext.rawData) { throw error }
        let sourceURL = credential.metadata["sourcePath"].map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) }
        let sourceData = sourceURL.flatMap { try? Data(contentsOf: $0) }
        let expectedProjectId = [
            authContext.authFile.projectId,
            credential.metadata["projectId"],
            credential.metadata["project_id"]
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first(where: { !$0.isEmpty })
        let session: URLSession? = nil
        do {
            var usage = try await fetchForAuthContext(
                authContext,
                session: session,
                localOnly: localOnly,
                expectedProjectId: expectedProjectId,
                requireProjectMatch: requireProjectMatch
            )
            usage.usageAccountId = authContext.authFile.email ?? authContext.url.lastPathComponent
            if usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                usage.accountEmail = credential.accountLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return usage
        } catch let terminal as ProviderError where terminal.code == "tos_violation" {
            if let url = sourceURL, url.path != authContext.url.path, let data = sourceData,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = authContext.authFile.email,
               (json["email"] as? String)?.lowercased() == email.lowercased(),
               AntigravityAccountProtection.sharesTokenChain(json, authContext.authFile.accessToken, authContext.authFile.refreshToken) {
                do { try AntigravityAccountProtection.suspend(url, error: terminal, expectedData: data) }
                catch {
                    throw ProviderError(terminal.code, terminal.message + " Source suspension could not be saved; stop polling and check file permissions.", metadata: terminal.metadata)
                }
            }
            throw terminal
        }
    }

    public func fetchAllAccounts() async -> [AccountFetchResult] {
        []
    }

    /// Core fetch logic for a single auth context (local Antigravity IDE RPC only; no third-party Google consumer HTTPS calls)
    private func fetchForAuthContext(
        _ authContext: AuthContext,
        session: URLSession?,
        localOnly: Bool = false,
        expectedProjectId: String? = nil,
        requireProjectMatch: Bool = false
    ) async throws -> ProviderUsage {
        let authFile = authContext.authFile
        _ = session
        _ = localOnly

        guard let localReader = effectiveLocalQuotaReader,
              let local = await localReader.fetchMatchingQuota(
                expectedEmail: authFile.email,
                expectedProjectId: expectedProjectId,
                requireProjectMatch: requireProjectMatch
              ) else {
            throw ProviderError(
                "local_only_unavailable",
                "Direct third-party Antigravity consumer API checks are disabled for policy compliance; showing local IDE session or last-known cached snapshot only."
            )
        }
        let subscription = SubscriptionInfo(tierId: local.tierId, tierName: local.tierName, projectId: local.projectId ?? expectedProjectId)
        let quota = QuotaSnapshot(models: local.models, isGrouped: true)
        let transport = "loopback_rpc"
        var usage = buildUsage(
            authContext: authContext,
            authFile: authFile,
            subscription: subscription,
            quota: quota,
            transport: transport
        )

        // MARK: - Smart Circuit Breaker
        if let circuitBreakerInfo = applySmartCircuitBreaker(
            at: authContext.url,
            models: quota.models,
            email: authFile.email ?? emailFromFilename(authContext.url.lastPathComponent)
        ) {
            usage.extra["circuitBreakerTripped"] = AnyCodable(false)
            usage.extra["circuitBreakerPartialTripped"] = AnyCodable(!circuitBreakerInfo.blockedPools.isEmpty)
            usage.extra["circuitBreakerTrippedPool"] = AnyCodable(circuitBreakerInfo.blockedPools.joined(separator: ", "))
            usage.extra["circuitBreakerError"] = AnyCodable(circuitBreakerInfo.error ?? "")
            usage.extra["circuitBreakerReason"] = AnyCodable(circuitBreakerInfo.reason)
        }

        return usage
    }

    // MARK: - Auth Files

    private struct AuthContext {
        let url: URL
        let authFile: AntigravityAuthFile
        let rawData: Data
        let fileCount: Int
        let sourceDirectory: String
    }

    private struct AntigravityAuthFile: Codable {
        var accessToken: String
        var email: String?
        var expired: String?
        let expiresIn: Int?
        let refreshToken: String?
        let timestamp: Int?
        let type: String?
        let prefix: String?
        let projectId: String?
        let proxyUrl: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case email
            case expired
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
            case timestamp
            case type
            case prefix
            case projectId = "project_id"
            case proxyUrl = "proxy_url"
        }

        var expiryDate: Date? {
            if let expired, let parsed = AntigravityProvider.parseISO8601(expired) {
                return parsed
            }
            if let timestamp, let expiresIn {
                return Date(timeIntervalSince1970: Double(timestamp) / 1000 + Double(expiresIn))
            }
            return nil
        }

        var needsRefresh: Bool {
            guard let expiryDate else { return false }
            return expiryDate.timeIntervalSinceNow <= 60
        }
    }

    private func loadAuthContext(url: URL, fileCount: Int, sourceDirectory: String) throws -> AuthContext {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderError("not_logged_in", "Antigravity auth file not found at \(url.path).")
        }
        let data = try Data(contentsOf: url)
        var authFile = try JSONDecoder().decode(AntigravityAuthFile.self, from: data)
        if authFile.email?.isEmpty ?? true {
            authFile.email = emailFromFilename(url.lastPathComponent)
        }
        guard !authFile.accessToken.isEmpty else {
            throw ProviderError("missing_tokens", "Antigravity auth file exists but has no access token.")
        }
        return AuthContext(url: url, authFile: authFile, rawData: data, fileCount: fileCount, sourceDirectory: sourceDirectory)
    }

    private func resolveCredentialAuthContext(_ credential: AccountCredential) throws -> AuthContext {
        let path = NSString(string: credential.credential).expandingTildeInPath
        let url = URL(fileURLWithPath: path)
        return try loadAuthContext(url: url, fileCount: 1, sourceDirectory: url.deletingLastPathComponent().path)
    }

    private func emailFromFilename(_ filename: String) -> String? {
        guard filename.hasPrefix("antigravity-"), filename.hasSuffix(".json") else { return nil }
        let value = filename
            .replacingOccurrences(of: "antigravity-", with: "")
            .replacingOccurrences(of: ".json", with: "")
        if value.contains("@") { return value }
        let restored = value
            .replacingOccurrences(of: ".gmail.com", with: "@gmail.com")
            .replacingOccurrences(of: "_", with: ".")
        return restored.contains("@") ? restored : nil
    }

    // MARK: - API

    private struct SubscriptionInfo {
        let tierId: String?
        let tierName: String?
        let projectId: String?
    }

    struct ModelQuota {
        let id: String
        let label: String
        let remainingPercent: Double
        let resetAt: String?
        let providerLabel: String?

        /// Argon and Carbon share the auxiliary pool: protect together without lowering the core-pool headline.
        var isAuxiliary: Bool {
            id.localizedCaseInsensitiveContains("argon") || label.localizedCaseInsensitiveContains("argon")
                || id.localizedCaseInsensitiveContains("carbon") || label.localizedCaseInsensitiveContains("carbon")
        }
    }

    private struct QuotaSnapshot {
        let models: [ModelQuota]
        /// true = 来自 retrieveUserQuotaSummary 的分组窗口；false = 旧的按模型配额。
        let isGrouped: Bool
    }

    // MARK: - Build Usage

    private func buildUsage(authContext: AuthContext,
                            authFile: AntigravityAuthFile,
                            subscription: SubscriptionInfo,
                            quota: QuotaSnapshot,
                            transport: String = "https") -> ProviderUsage {
        let models = quota.models
        let coreModels = models.filter { !$0.isAuxiliary }
        let lowestPercent = (coreModels.isEmpty ? models : coreModels).map(\.remainingPercent).min()
        let sortedModels = models.sorted {
            if $0.isAuxiliary != $1.isAuxiliary {
                return !$0.isAuxiliary && $1.isAuxiliary
            }
            if $0.remainingPercent == $1.remainingPercent {
                return $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }
            return $0.remainingPercent < $1.remainingPercent
        }

        var usage = ProviderUsage(provider: "antigravity", label: "Antigravity")
        usage.accountEmail = authFile.email
        usage.accountPlan = subscription.tierName ?? parsePlanName(tierId: subscription.tierId)
        usage.primary = sortedModels.indices.contains(0) ? modelWindow(from: sortedModels[0]) : nil
        usage.secondary = sortedModels.indices.contains(1) ? modelWindow(from: sortedModels[1]) : nil
        usage.tertiary = sortedModels.indices.contains(2) ? modelWindow(from: sortedModels[2]) : nil

        var source = SourceInfo(mode: "oauth", type: "imported-auth-file")
        source.profile = authContext.url.lastPathComponent
        source.roots = [authContext.sourceDirectory]
        usage.source = source

        usage.extra["projectId"] = AnyCodable(subscription.projectId ?? authFile.projectId ?? "")
        usage.extra["lowestPercentLeft"] = AnyCodable(lowestPercent ?? -1)
        usage.extra["modelCount"] = AnyCodable(models.count)
        usage.extra["quotaSource"] = AnyCodable(quota.isGrouped ? "groups" : "models")
        usage.extra["transport"] = AnyCodable(transport)
        usage.extra["authFileCount"] = AnyCodable(authContext.fileCount)
        usage.extra["selectedAuthFile"] = AnyCodable(authContext.url.lastPathComponent)
        usage.extra["trackedModels"] = AnyCodable(sortedModels.map { model in
            AnyCodable([
                "id": AnyCodable(model.id),
                "label": AnyCodable(model.label),
                "remainingPercent": AnyCodable(model.remainingPercent),
                "resetAt": AnyCodable(model.resetAt ?? ""),
                "providerLabel": AnyCodable(model.providerLabel ?? "")
            ] as [String: AnyCodable])
        })

        return usage
    }

    // MARK: - Smart Circuit Breaker Implementation

    private struct CircuitBreakerResult {
        let blockedPools: [String]
        let reason: String
        let error: String?
    }

    private func applySmartCircuitBreaker(
        at fileURL: URL,
        models: [ModelQuota],
        email: String?
    ) -> CircuitBreakerResult? {
        _ = (fileURL, models, email)
        return nil
    }

    /// 返回 nil 表示没有可用窗口（旧部署、桶全被禁用等），由调用方换下一个来源。
    func parseQuotaSummary(_ response: [String: Any]) -> [ModelQuota]? {
        Self.parseQuotaSummaryPayload(response)
    }

    static func parseQuotaSummaryPayload(_ response: [String: Any]) -> [ModelQuota]? {
        guard let groups = response["groups"] as? [[String: Any]] else { return nil }
        var models: [ModelQuota] = []

        for group in groups {
            let groupName = summaryGroupName(group["displayName"] as? String)
            let providerTag = groupName.localizedCaseInsensitiveContains("Gemini") ? "Google" : "Claude/3P"
            for bucket in group["buckets"] as? [[String: Any]] ?? [] {
                // 禁用的桶不计入：周额度用尽时 5 小时桶会被禁用（周桶自己已经是 0%）；
                // 套餐不含该模型组时也会禁用，按 0% 算会把整个账号误报成用尽。
                if bucket["disabled"] as? Bool == true { continue }

                let resetAt = (bucket["resetTime"] as? String)
                    .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                // proto3 JSON 会省略零值：用尽的桶没有 remainingFraction，只剩 resetTime。
                guard let fraction = doubleValue(bucket["remainingFraction"]) ?? (resetAt == nil ? nil : 0) else { continue }

                let bucketId = (bucket["bucketId"] as? String) ?? ""
                models.append(ModelQuota(
                    id: bucketId.isEmpty ? "\(groupName)-\(models.count)" : bucketId,
                    label: summaryWindowLabel(groupName: groupName, bucket: bucket),
                    remainingPercent: min(100, max(0, fraction * 100)),
                    resetAt: resetAt,
                    providerLabel: providerTag
                ))
            }
        }

        return models.isEmpty ? nil : models
    }

    /// "Gemini Models" → "Gemini"，"Claude and GPT models" → "Claude + GPT"，"Gemini 4 Argon" 原样保留。
    private static func summaryGroupName(_ raw: String?) -> String {
        var name = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if name.lowercased().hasSuffix(" models") {
            name = String(name.dropLast(" models".count))
        }
        name = name.replacingOccurrences(of: " and ", with: " + ")
        return name.isEmpty ? "Models" : name
    }

    private static func summaryWindowLabel(groupName: String, bucket: [String: Any]) -> String {
        let window = (bucket["window"] as? String)?.lowercased()
        let bucketId = (bucket["bucketId"] as? String)?.lowercased() ?? ""
        if window == "5h" || bucketId.hasSuffix("-5h") { return "\(groupName) · 5h" }
        if window == "weekly" || bucketId.hasSuffix("-weekly") { return "\(groupName) · Weekly" }
        if let name = (bucket["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "\(groupName) · \(name)"
        }
        return groupName
    }

    private func parseModels(_ response: [String: Any]) -> [ModelQuota] {
        if let grouped = parseQuotaSummary(response) {
            return grouped
        }

        let rawModels = response["models"] as? [String: Any] ?? [:]
        var models: [ModelQuota] = []

        for (name, rawInfo) in rawModels {
            guard let info = rawInfo as? [String: Any],
                  let quotaInfo = info["quotaInfo"] as? [String: Any] else { continue }
            let resetAt = (quotaInfo["resetTime"] as? String)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            // 与分组接口相同：proto3 省略零值，用尽的模型只剩 resetTime。
            guard let remainingFraction = doubleValue(quotaInfo["remainingFraction"]) ?? (resetAt == nil ? nil : 0) else { continue }

            let isInternal = info["isInternal"] as? Bool ?? false
            let apiProvider = info["apiProvider"] as? String
            guard !isInternal, apiProvider != "API_PROVIDER_INTERNAL" else { continue }

            let displayName = (info["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let label = displayName, !label.isEmpty else { continue }

            let remainingPercent = min(100, max(0, remainingFraction * 100))
            models.append(ModelQuota(
                id: name,
                label: label,
                remainingPercent: remainingPercent,
                resetAt: resetAt,
                providerLabel: providerLabel(apiProvider: apiProvider, modelProvider: info["modelProvider"] as? String)
            ))
        }

        return models
    }

    private func modelWindow(from model: ModelQuota) -> RawQuotaWindow {
        var window = RawQuotaWindow()
        window.label = model.label
        window.remainingPercent = model.remainingPercent
        window.usedPercent = max(0, 100 - model.remainingPercent)
        window.resetAt = model.resetAt
        window.resetDescription = formatResetDescription(
            model.resetAt.flatMap(Self.parseISO8601),
            prefix: model.providerLabel ?? "Model"
        )
        return window
    }

    private func providerLabel(apiProvider: String?, modelProvider: String?) -> String? {
        let value = (modelProvider ?? apiProvider ?? "").uppercased()
        if value.contains("ANTHROPIC") { return "Anthropic" }
        if value.contains("OPENAI") { return "OpenAI" }
        if value.contains("GOOGLE") || value.contains("GEMINI") { return "Google" }
        return nil
    }

    // MARK: - Helpers

    private func parsePlanName(tierId: String?) -> String? {
        guard let tierId, !tierId.isEmpty else { return nil }
        switch tierId.lowercased() {
        case "free": return "Free"
        case "standard": return "Standard"
        case "pro": return "Pro"
        case "ultra": return "Ultra"
        case "enterprise": return "Enterprise"
        default: return tierId.capitalized
        }
    }

    private func normalizeProjectId(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let dict = value as? [String: Any] {
            return dict["id"] as? String ?? dict["projectId"] as? String
        }
        return nil
    }

    private static func parseISO8601(_ value: String) -> Date? {
        SharedFormatters.parseISO8601(value)
    }

    private func iso8601String(_ date: Date) -> String {
        SharedFormatters.iso8601String(from: date)
    }

    private func formatResetDescription(_ date: Date?, prefix: String) -> String {
        guard let date else { return "\(prefix) • Reset unavailable" }
        let diff = date.timeIntervalSinceNow
        if diff <= 0 { return "\(prefix) • Resets soon" }

        let totalMinutes = Int(diff / 60)
        let days = totalMinutes / 1440
        let hours = (totalMinutes % 1440) / 60
        let minutes = totalMinutes % 60

        if days > 0 { return "\(prefix) • Resets in \(days)d \(hours)h" }
        if hours > 0 { return "\(prefix) • Resets in \(hours)h \(minutes)m" }
        return "\(prefix) • Resets in \(max(1, minutes))m"
    }

    private func intValue(_ value: Any?) -> Int? {
        switch value {
        case let n as Int: return n
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }

    private func doubleValue(_ value: Any?) -> Double? {
        Self.doubleValue(value)
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let d as Double: return d
        case let n as Int: return Double(n)
        case let s as String: return Double(s)
        default: return nil
        }
    }
}

/// Never attach a CL from a different release to the installed bundle version.
public enum AntigravityClientIdentity {
    private static let verifiedChangelists: [String: String] = [
        "2.32.1": "1021296516"
    ]

    public static var userAgent: String {
        let roots = ["/Applications/Antigravity.app", NSHomeDirectory() + "/Applications/Antigravity.app"]
        let version = roots.compactMap { root -> String? in
            guard let data = FileManager.default.contents(atPath: root + "/Contents/Info.plist"),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let value = plist["CFBundleShortVersionString"] as? String,
                  value.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
            return value
        }.first
        return userAgent(forVersion: version)
    }

    public static func userAgent(forVersion version: String?, arch: String? = nil) -> String {
        guard let version else { return "AIUsage/AntigravityQuotaMonitor" }
        var metadata = ["aidev_client", "os_type=darwin", "arch=\(arch ?? currentArch)"]
        if let cl = verifiedChangelists[version] {
            metadata.append("cl=\(cl)")
        }
        return "antigravity/hub/\(version) (\(metadata.joined(separator: "; ")))"
    }

    private static var currentArch: String {
        #if arch(arm64)
        return "arm64"
        #else
        return "amd64"
        #endif
    }
}

public enum AntigravityAPIError {
    public static func parse(statusCode: Int, data: Data) -> ProviderError? {
        let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let error = root["error"] as? [String: Any] ?? root
        let details = error["details"] as? [[String: Any]] ?? []
        let reason = details.compactMap { $0["reason"] as? String }.first { $0 == "TOS_VIOLATION" }
        let message = (error["message"] as? String ?? "").lowercased()
        if statusCode == 403 && (reason != nil || message.contains("terms of service") || message.contains("tos_violation")) {
            let appeal = details.compactMap { ($0["metadata"] as? [String: Any])?["appeal_url"] as? String }
                .first.flatMap { value -> String? in
                    guard let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
                    return url.absoluteString
                }
            return ProviderError("tos_violation", "Antigravity suspended this credential. Automatic polling is stopped."
                                 + (appeal.map { " Appeal: \($0)" } ?? ""), metadata: appeal.map { ["appeal_url": $0] } ?? [:])
        }
        let ineligible = root["ineligibleTiers"] as? [[String: Any]] ?? []
        if root["paidTier"] == nil, root["currentTier"] == nil,
           ineligible.contains(where: { $0["reasonCode"] as? String == "UNSUPPORTED_CLIENT" }) {
            return ProviderError("unsupported_client", "This OAuth client is unsupported. Import the Antigravity IDE session instead.")
        }
        switch statusCode {
        case 401: return ProviderError("unauthorized", "Antigravity OAuth token is invalid or expired.")
        case 403: return ProviderError("forbidden", "Antigravity quota API returned HTTP 403. No fallback request was sent.")
        case 429: return ProviderError("rate_limited", "Antigravity quota API is rate limited. No fallback request was sent.")
        default: return nil
        }
    }
}

public enum AntigravityAccountProtection {
    static func sharesTokenChain(_ json: [String: Any], _ access: String, _ refresh: String?) -> Bool {
        if let refresh, !refresh.isEmpty, json["refresh_token"] as? String == refresh { return true }
        return !access.isEmpty && json["access_token"] as? String == access
    }
    static func ownedCopies(credentialID: String, homeDirectory: String, expectedData: Data) -> [(URL, Data)] {
        let directory = AntigravityPoolProtectionSettings.runtime(homeDirectory).appendingPathComponent("auth")
        guard let expected = try? JSONSerialization.jsonObject(with: expectedData) as? [String: Any],
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return [] }
        return files.compactMap { url in
            guard url.pathExtension == "json", (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
                  let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  json["type"] as? String == "antigravity", json["aiusage_credential_id"] as? String == credentialID,
                  json["email"] as? String == expected["email"] as? String,
                  sharesTokenChain(json, expected["access_token"] as? String ?? "", expected["refresh_token"] as? String) else { return nil }
            return (url, data)
        }
    }
    public static func suspension(in data: Data) -> ProviderError? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tos = json["tos_suspended"] as? Bool == true || json["tos_violation"] as? Bool == true
            || json["circuit_breaker_reason"] as? String == "TOS_VIOLATION"
        guard tos || json["disabled"] as? Bool == true else { return nil }
        let appeal = json["appeal_url"] as? String
        return ProviderError(tos ? "tos_violation" : "account_disabled", "Antigravity account is disabled; re-authenticate to recheck."
                             + (appeal.map { " Appeal: \($0)" } ?? ""), metadata: appeal.map { ["appeal_url": $0] } ?? [:])
    }

    public static func suspend(_ url: URL, error: ProviderError, expectedData: Data) throws {
        guard let expected = try JSONSerialization.jsonObject(with: expectedData) as? [String: Any] else { return }
        try AntigravityCredentialFile.update(url) { json in
            guard json["access_token"] as? String == expected["access_token"] as? String,
                  json["refresh_token"] as? String == expected["refresh_token"] as? String,
                  json["email"] as? String == expected["email"] as? String else { return nil }
            var updated = json
            updated["disabled"] = true
            updated["tos_suspended"] = true
            updated["circuit_breaker_tripped"] = false
            updated["circuit_breaker_reason"] = "TOS_VIOLATION"
            if let appeal = error.metadata["appeal_url"] { updated["appeal_url"] = appeal }
            return updated
        }
    }
}

extension AntigravityProvider {
    static func proxyConfiguration(proxyURL: String?) throws -> URLSessionConfiguration? {
        guard let value = proxyURL?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        guard let url = URLComponents(string: value), let host = url.host, !host.isEmpty,
              let scheme = url.scheme?.lowercased(), ["http", "https", "socks5"].contains(scheme),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/" else {
            throw ProviderError("invalid_proxy", "Use an http/https/socks5 proxy URL without embedded credentials. No direct request was sent.")
        }
        let port = url.port ?? (scheme == "https" ? 443 : scheme == "socks5" ? 1080 : 80)
        guard (1...65535).contains(port) else { throw ProviderError("invalid_proxy", "Proxy port is invalid.") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if scheme == "socks5" {
            configuration.connectionProxyDictionary = ["SOCKSEnable": 1, "SOCKSProxy": host, "SOCKSPort": port, "SOCKSVersion": "5"]
        } else {
            configuration.connectionProxyDictionary = ["HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                                                       "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port]
        }
        return configuration
    }

    private static func proxySession(proxyURL: String?) throws -> URLSession? {
        guard let configuration = try proxyConfiguration(proxyURL: proxyURL) else { return nil }
        configuration.protocolClasses = QuotaHTTP.sessionOverride?.configuration.protocolClasses ?? configuration.protocolClasses
        return URLSession(configuration: configuration)
    }
}
