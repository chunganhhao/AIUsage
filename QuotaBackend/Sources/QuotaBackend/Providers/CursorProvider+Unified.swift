import Foundation

// MARK: - Cursor Unified Plan (The X Subscription)
// 2026-10 起 Cursor 与 xAI 合并套餐：一个每周的共享包含额度池（与 Grok / Grok Bot 共用）+ 预付余额。
// 这类账号的 usage-summary 按自然月给出显式 0，真实用量要从 Cursor 设置页同源的 RPC 读。
//   - 识别：POST cursor.com/api/dashboard/get-plan-info 的 isMerged（拿不到时看 sand 状态的 isUnified）
//   - 用量：POST api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage → planUsage.totalPercentUsed
//   - 兜底：POST cursor.com/api/dashboard/get-sand-usage-status → usagePercent
// 这些接口是 proto3 JSON：int64 是十进制字符串、枚举是全名、零值字段被省略。
// 未经实测（参照 token-monitor 的 Cursor provider，2026-10）；老套餐完全不走这里。

extension CursorProvider {
    static let planInfoURL = "https://cursor.com/api/dashboard/get-plan-info"
    static let sandUsageURL = "https://cursor.com/api/dashboard/get-sand-usage-status"
    static let prepaidBillingURL = "https://cursor.com/api/dashboard/get-user-prepaid-billing"
    static let currentPeriodUsageURL = "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"

    enum IncludedUsagePeriod: String {
        case weekly
        case monthly
    }

    struct PlanInfo {
        let isMerged: Bool
        let planName: String?
        let period: IncludedUsagePeriod?
        let includedUsageResetsAt: Date?
    }

    struct SandStatus {
        let usedPercent: Double?
        let isUnified: Bool
        let resetsAt: Date?
    }

    struct UnifiedUsage {
        let usedPercent: Double?
        let period: IncludedUsagePeriod
        let resetsAt: Date?
        let prepaidBalanceUsd: Double?
        let planName: String?
    }

    // MARK: Parsing

    static func parsePlanInfo(_ json: [String: Any]) -> PlanInfo {
        let info = json["planInfo"] as? [String: Any] ?? [:]
        let period: IncludedUsagePeriod?
        switch info["includedUsagePeriod"] as? String {
        case "INCLUDED_USAGE_PERIOD_WEEKLY": period = .weekly
        case "INCLUDED_USAGE_PERIOD_MONTHLY": period = .monthly
        default: period = nil
        }
        return PlanInfo(
            isMerged: json["isMerged"] as? Bool == true,
            planName: (info["planName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank,
            period: period,
            includedUsageResetsAt: epochMillisDate(info["includedUsageResetsAt"])
        )
    }

    static func parseSandStatus(_ json: [String: Any]) -> SandStatus {
        SandStatus(
            usedPercent: clampedPercent(decimal(json["usagePercent"])),
            isUnified: json["isUnified"] as? Bool == true,
            resetsAt: (json["nextResetTimestampUtc"] as? String).flatMap(SharedFormatters.parseISO8601)
        )
    }

    /// `planUsage.totalPercentUsed`；proto3 省略零值，所以 planUsage 存在但字段缺失时按 0。
    static func parseCurrentPeriodPercent(_ json: [String: Any]) -> Double? {
        guard let planUsage = json["planUsage"] as? [String: Any] else { return nil }
        return clampedPercent(decimal(planUsage["totalPercentUsed"]) ?? 0)
    }

    /// `availableCents` 缺失即 0（proto3）；非正数不展示。
    static func parsePrepaidBalanceUsd(_ json: [String: Any]) -> Double? {
        guard let cents = decimal(json["availableCents"]), cents > 0 else { return nil }
        return cents / 100
    }

    /// 本周包含额度：当前周期 RPC（显式 0 也算）→ 统一套餐的 sand 用量 → 仅明确按月的套餐才退回 usage-summary。
    static func unifiedIncludedPercent(periodPercent: Double?,
                                       sand: SandStatus?,
                                       summaryPercent: Double?,
                                       period: IncludedUsagePeriod?) -> Double? {
        if let periodPercent { return periodPercent }
        if let sand, sand.isUnified, let percent = sand.usedPercent { return percent }
        return period == .monthly ? summaryPercent : nil
    }

    /// `WorkosCursorSessionToken=<userId>%3A%3A<accessToken>` 里的 accessToken（必须是 JWT）。
    static func accessToken(fromCookieHeader header: String) -> String? {
        for part in header.split(separator: ";") {
            let pair = part.trimmingCharacters(in: .whitespaces)
            guard pair.hasPrefix("WorkosCursorSessionToken=") else { continue }
            let raw = String(pair.dropFirst("WorkosCursorSessionToken=".count))
            let decoded = raw.removingPercentEncoding ?? raw
            guard let separator = decoded.range(of: "::") else { return nil }
            let token = decoded[separator.upperBound...].trimmingCharacters(in: .whitespaces)
            return token.split(separator: ".", omittingEmptySubsequences: false).count == 3 ? token : nil
        }
        return nil
    }

    // MARK: Requests (best effort: failures never fail the account row)

    func fetchUnifiedUsage(cookie: String,
                           userAgent: String,
                           planInfo: PlanInfo?,
                           summaryPercent: Double?) async -> UnifiedUsage? {
        var sand: SandStatus?
        if planInfo == nil {
            sand = await fetchDashboardRPC(Self.sandUsageURL, cookie: cookie, userAgent: userAgent).map(Self.parseSandStatus)
        }
        guard planInfo?.isMerged ?? (sand?.isUnified == true) else { return nil }

        async let periodTask = fetchCurrentPeriodPercent(cookie: cookie, userAgent: userAgent)
        async let prepaidTask = fetchDashboardRPC(Self.prepaidBillingURL, cookie: cookie, userAgent: userAgent)
        let periodPercent = await periodTask
        let prepaid = await prepaidTask
        if periodPercent == nil, sand == nil {
            sand = await fetchDashboardRPC(Self.sandUsageURL, cookie: cookie, userAgent: userAgent).map(Self.parseSandStatus)
        }

        let period = planInfo?.period ?? .weekly
        let usedPercent = Self.unifiedIncludedPercent(
            periodPercent: periodPercent,
            sand: sand,
            summaryPercent: summaryPercent,
            period: planInfo?.period
        )
        let fromSand = periodPercent == nil && usedPercent != nil && usedPercent == sand?.usedPercent
        return UnifiedUsage(
            usedPercent: usedPercent,
            period: period,
            resetsAt: planInfo?.includedUsageResetsAt ?? (fromSand ? sand?.resetsAt : nil),
            prepaidBalanceUsd: prepaid.flatMap(Self.parsePrepaidBalanceUsd),
            planName: planInfo?.planName
        )
    }

    func fetchPlanInfo(cookie: String, userAgent: String) async -> PlanInfo? {
        await fetchDashboardRPC(Self.planInfoURL, cookie: cookie, userAgent: userAgent).map(Self.parsePlanInfo)
    }

    private var bestEffortTimeout: Double { min(timeoutSeconds, 5) }

    private func fetchDashboardRPC(_ urlString: String, cookie: String, userAgent: String) async -> [String: Any]? {
        guard let url = URL(string: urlString) else { return nil }
        var request = QuotaHTTP.request(url: url, timeout: bestEffortTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com/dashboard", forHTTPHeaderField: "Referer")
        request.setValue(cookie, forHTTPHeaderField: "Cookie")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return await Self.bestEffortJSON(request)
    }

    private func fetchCurrentPeriodPercent(cookie: String, userAgent: String) async -> Double? {
        guard let token = Self.accessToken(fromCookieHeader: cookie),
              let url = URL(string: Self.currentPeriodUsageURL) else { return nil }
        var request = QuotaHTTP.request(url: url, timeout: bestEffortTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("{}".utf8)
        return await Self.bestEffortJSON(request).flatMap(Self.parseCurrentPeriodPercent)
    }

    private static func bestEffortJSON(_ request: URLRequest) async -> [String: Any]? {
        guard let (data, response) = try? await QuotaHTTP.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    // MARK: Helpers

    private static func decimal(_ value: Any?) -> Double? {
        switch value {
        case let number as NSNumber: return number.doubleValue.isFinite ? number.doubleValue : nil
        case let text as String: return Double(text.trimmingCharacters(in: .whitespaces)).flatMap { $0.isFinite ? $0 : nil }
        default: return nil
        }
    }

    private static func clampedPercent(_ value: Double?) -> Double? {
        value.map { min(100, max(0, $0)) }
    }

    private static func epochMillisDate(_ value: Any?) -> Date? {
        guard let millis = decimal(value), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }
}

private extension String {
    var nilIfBlank: String? { isEmpty ? nil : self }
}
