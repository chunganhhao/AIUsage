import Foundation

// MARK: - Warp Provider
// 账号用 Warp 个人 API Key（Settings → Cloud platform → API keys，wk-…）走官方 GraphQL：
//   POST https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo
//   Warp 已把 requests 改名为 credits，但接口字段仍沿用 request 命名。
//   边缘限流只放行官方客户端形态的 User-Agent（Warp/1.0），否则返回 429。
//   查询与请求头照搬 CodexBar 的 WarpUsageFetcher；未经实测。
// 没有凭证的旧账号继续读 macOS defaults 里的应用缓存（dev.warp.Warp-Stable / Preview / Nightly）。

public struct WarpProvider: ProviderFetcher, CredentialAcceptingProvider {
    public let id = "warp"
    public let displayName = "Warp"
    public let description = "Warp terminal AI credits"

    static let domains = ["dev.warp.Warp-Stable", "dev.warp.Warp-Preview", "dev.warp.Warp-Nightly"]
    static let graphQLURL = "https://app.warp.dev/graphql/v2?op=GetRequestLimitInfo"
    static let userAgent = "Warp/1.0"
    static let graphQLQuery = """
    query GetRequestLimitInfo($requestContext: RequestContext!) {
      user(requestContext: $requestContext) {
        __typename
        ... on UserOutput {
          user {
            requestLimitInfo {
              isUnlimited
              nextRefreshTime
              requestLimit
              requestsUsedSinceLastRefresh
            }
            bonusGrants {
              requestCreditsGranted
              requestCreditsRemaining
              expiration
            }
            workspaces {
              bonusGrantsInfo {
                grants {
                  requestCreditsGranted
                  requestCreditsRemaining
                  expiration
                }
              }
            }
          }
        }
      }
    }
    """

    let timeoutSeconds: Double

    public var supportedAuthMethods: [AuthMethod] { [.apiKey] }

    public init(timeoutSeconds: Double = 15) {
        self.timeoutSeconds = timeoutSeconds
    }

    public func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        guard credential.authMethod == .apiKey else {
            throw ProviderError("unsupported_auth_method", "Warp only accepts API key credentials (wk-…).")
        }
        let key = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            throw ProviderError("missing_token", "Warp API key is empty.")
        }

        var usage = try parseGraphQLResponse(try await requestLimitInfo(apiKey: key))
        // 响应里没有邮箱，用 key 指纹做稳定标识。
        usage.usageAccountId = "warp-\(KimiProvider.stableFingerprint(key))"
        usage.source = SourceInfo(mode: "manual", type: "warp-api")
        return usage
    }

    public func fetchUsage() async throws -> ProviderUsage {
        // Try each Warp domain variant
        for domain in Self.domains {
            if let result = try? await fetchFromDomain(domain) {
                return result
            }
        }
        throw ProviderError("not_found", "Warp app data not found. Make sure Warp is installed and has been used at least once.")
    }

    private func fetchFromDomain(_ domain: String) async throws -> ProviderUsage {
        guard let limitInfo = readDefaultsJSON(domain: domain, key: "AIRequestLimitInfo") else {
            throw ProviderError("not_found", "No AIRequestLimitInfo in \(domain)")
        }

        let assistantInfo = readDefaultsJSON(domain: domain, key: "AIAssistantRequestLimitInfo")
        let quotaInfo = readDefaultsJSON(domain: domain, key: "AIRequestQuotaInfoSetting")
        let email = readKeychainEmail(domain: domain)

        var usage = ProviderUsage(provider: "warp", label: "Warp")
        usage.accountEmail = email

        var source = SourceInfo(mode: "auto", type: "app-cache")
        source.defaultsDomain = domain
        usage.source = source

        // Parse main request limit
        let primary = parseWarpLimitInfo(limitInfo, fallbackResetAt: latestCycleEndDate(quotaInfo))
        usage.primary = primary

        // Parse assistant limit
        if let assistantInfo {
            usage.secondary = parseWarpLimitInfo(assistantInfo, fallbackResetAt: nil)
        }

        // Extra fields for normalizer
        let requestsUsed = primary.usedPercent.map { Int($0 / 100.0 * Double(extra_limit(limitInfo))) } ?? intField(limitInfo, "num_requests_used_since_refresh")
        let requestLimit = extra_limit(limitInfo)
        let isUnlimited = boolField(limitInfo, "is_unlimited")

        var extra: [String: AnyCodable] = [:]
        extra["requestsUsed"]    = AnyCodable(requestsUsed ?? 0)
        extra["requestLimit"]    = AnyCodable(requestLimit)
        extra["requestsRemaining"] = AnyCodable(isUnlimited ? 0 : max(0, requestLimit - (requestsUsed ?? 0)))
        extra["isUnlimited"]     = AnyCodable(isUnlimited)
        extra["bonusCreditsRemaining"] = AnyCodable(0)
        extra["bonusCreditsTotal"]     = AnyCodable(0)

        if let assistantInfo {
            let aUsed = intField(assistantInfo, "num_requests_used_since_refresh") ?? 0
            extra["assistantRequestsUsed"] = AnyCodable(aUsed)
        }

        usage.extra = extra
        return usage
    }

    // MARK: - GraphQL API

    private func requestLimitInfo(apiKey: String) async throws -> [String: Any] {
        guard let url = URL(string: Self.graphQLURL) else {
            throw ProviderError("invalid_url", "Warp API URL is invalid.")
        }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osVersion = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"

        var request = QuotaHTTP.request(url: url, timeout: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("warp-app", forHTTPHeaderField: "x-warp-client-id")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-category")
        request.setValue("macOS", forHTTPHeaderField: "x-warp-os-name")
        request.setValue(osVersion, forHTTPHeaderField: "x-warp-os-version")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": Self.graphQLQuery,
            "operationName": "GetRequestLimitInfo",
            "variables": [
                "requestContext": [
                    "clientContext": [String: Any](),
                    "osContext": ["category": "macOS", "name": "macOS", "version": osVersion]
                ]
            ]
        ] as [String: Any])

        let (data, response) = try await QuotaHTTP.data(for: request)
        if let http = response as? HTTPURLResponse {
            switch http.statusCode {
            case 200..<300: break
            case 401, 403: throw ProviderError("invalid_credentials", "Warp API key was rejected. Create a personal key in Warp → Settings → Cloud platform → API keys.")
            case 429: throw ProviderError("rate_limited", "Warp API is rate limiting requests. Try again later.")
            default: throw ProviderError("api_error", "Warp API returned HTTP \(http.statusCode).")
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ProviderError("parse_failed", "Warp API returned invalid JSON.")
        }
        return json
    }

    func parseGraphQLResponse(_ json: [String: Any]) throws -> ProviderUsage {
        if let errors = json["errors"] as? [Any], !errors.isEmpty {
            let messages = errors.compactMap { ($0 as? [String: Any])?["message"] as? String ?? $0 as? String }
            throw ProviderError("api_error", messages.isEmpty ? "Warp API request failed." : messages.prefix(3).joined(separator: " | "))
        }
        guard let user = ((json["data"] as? [String: Any])?["user"] as? [String: Any])?["user"] as? [String: Any],
              let limitInfo = user["requestLimitInfo"] as? [String: Any] else {
            throw ProviderError("parse_failed", "Warp API response did not include requestLimitInfo.")
        }

        // 映射成应用缓存的字段形状，复用同一套窗口解析。
        let cacheShaped: [String: Any] = [
            "limit": limitInfo["requestLimit"] ?? 0,
            "num_requests_used_since_refresh": limitInfo["requestsUsedSinceLastRefresh"] ?? 0,
            "is_unlimited": limitInfo["isUnlimited"] ?? false,
            "next_refresh_time": limitInfo["nextRefreshTime"] ?? NSNull()
        ]
        let primary = parseWarpLimitInfo(cacheShaped, fallbackResetAt: nil)
        let limit = extra_limit(cacheShaped)
        let used = intField(cacheShaped, "num_requests_used_since_refresh") ?? 0
        let isUnlimited = boolField(cacheShaped, "is_unlimited")

        // 用户级与工作区级的 bonus grants 合并计算。
        let workspaceGrants = (user["workspaces"] as? [[String: Any]] ?? []).flatMap {
            ($0["bonusGrantsInfo"] as? [String: Any])?["grants"] as? [[String: Any]] ?? []
        }
        let grants = (user["bonusGrants"] as? [[String: Any]] ?? []) + workspaceGrants
        let bonusRemaining = grants.reduce(0) { $0 + (intField($1, "requestCreditsRemaining") ?? 0) }
        let bonusTotal = grants.reduce(0) { $0 + (intField($1, "requestCreditsGranted") ?? 0) }

        var usage = ProviderUsage(provider: "warp", label: "Warp")
        usage.primary = primary
        var extra: [String: AnyCodable] = [
            "requestsUsed": AnyCodable(used),
            "requestLimit": AnyCodable(limit),
            "requestsRemaining": AnyCodable(isUnlimited ? 0 : max(0, limit - used)),
            "isUnlimited": AnyCodable(isUnlimited)
        ]
        if bonusTotal > 0 || bonusRemaining > 0 {
            extra["bonusCreditsRemaining"] = AnyCodable(bonusRemaining)
            extra["bonusCreditsTotal"] = AnyCodable(bonusTotal)
        }
        usage.extra = extra
        return usage
    }

    // MARK: - Defaults reading

    private func readDefaultsJSON(domain: String, key: String) -> [String: Any]? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
        task.arguments = ["read", domain, key]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }

        // `defaults read` outputs property list format, try JSON first then plist
        if let jsonData = text.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] {
            return json
        }

        // Fall back to plist parsing
        if let plistData = text.data(using: .utf8),
           let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any] {
            return plist
        }

        return nil
    }

    private func readKeychainEmail(domain: String) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = ["find-generic-password", "-s", domain, "-a", "User", "-w"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()

        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }

        guard task.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty,
              let jsonData = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let email = json["email"] as? String, !email.isEmpty else { return nil }

        return email
    }

    // MARK: - Parsing helpers

    private func parseWarpLimitInfo(_ info: [String: Any], fallbackResetAt: Date?) -> RawQuotaWindow {
        let limit = extra_limit(info)
        let used = intField(info, "num_requests_used_since_refresh") ?? 0
        let isUnlimited = boolField(info, "is_unlimited")
        let nextRefreshRaw = info["next_refresh_time"] as? String
        let nextRefresh = nextRefreshRaw.flatMap { parseDate($0) } ?? fallbackResetAt

        var window = RawQuotaWindow()
        window.unlimited = isUnlimited
        window.entitlement = isUnlimited ? nil : limit
        window.remaining = isUnlimited ? nil : max(0, limit - used)
        window.resetAt = nextRefresh.map { SharedFormatters.iso8601String(from: $0) }

        if isUnlimited {
            window.usedPercent = 0
            window.remainingPercent = 100
            window.resetDescription = "Unlimited"
        } else if limit > 0 {
            let usedPct = min(100.0, max(0.0, Double(used) / Double(limit) * 100.0))
            window.usedPercent = usedPct
            window.remainingPercent = max(0, 100 - usedPct)
            window.resetDescription = nextRefresh.map { formatResetDescription($0, usage: "\(used)/\(limit) credits") }
        }

        return window
    }

    private func latestCycleEndDate(_ quotaInfo: [String: Any]?) -> Date? {
        guard let cycles = quotaInfo?["cycle_history"] as? [[String: Any]] else { return nil }
        return cycles.compactMap { c -> Date? in
            guard let s = c["end_date"] as? String else { return nil }
            return parseDate(s)
        }.max()
    }

    private func extra_limit(_ info: [String: Any]) -> Int {
        intField(info, "limit") ?? 0
    }

    private func intField(_ dict: [String: Any], _ key: String) -> Int? {
        switch dict[key] {
        case let v as Int: return v
        case let v as Double: return Int(v)
        case let v as String: return Int(v)
        default: return nil
        }
    }

    private func boolField(_ dict: [String: Any], _ key: String) -> Bool {
        switch dict[key] {
        case let v as Bool: return v
        case let v as Int: return v != 0
        case let v as String: return ["true", "1", "yes"].contains(v.lowercased())
        default: return false
        }
    }

    private func parseDate(_ s: String) -> Date? {
        SharedFormatters.parseISO8601(s)
    }

    private func formatResetDescription(_ date: Date, usage: String?) -> String {
        let day = DateFormat.string(from: date, format: "MMM d")
        let time = DateFormat.string(from: date, format: "h:mma")
        let base = "Resets \(day) at \(time)"
        return usage.map { "\($0), \(base)" } ?? base
    }
}
