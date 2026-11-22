import Foundation

// MARK: - Usage Normalizer
// Swift port of normalizeUsage.js — converts raw ProviderUsage into ProviderSummary

public enum UsageNormalizer {

    private enum FormatterCache {
        static func currencyFormatter(fractionDigits: Int) -> NumberFormatter {
            let key = "QuotaBackend.CurrencyFormatter.\(fractionDigits)"
            if let formatter = Thread.current.threadDictionary[key] as? NumberFormatter {
                return formatter
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = "USD"
            formatter.minimumFractionDigits = fractionDigits
            formatter.maximumFractionDigits = fractionDigits
            Thread.current.threadDictionary[key] = formatter
            return formatter
        }

        static func percentFormatter() -> NumberFormatter {
            let key = "QuotaBackend.PercentFormatter"
            if let formatter = Thread.current.threadDictionary[key] as? NumberFormatter {
                return formatter
            }

            let formatter = NumberFormatter()
            formatter.maximumFractionDigits = 1
            Thread.current.threadDictionary[key] = formatter
            return formatter
        }

        static func decimalFormatter() -> NumberFormatter {
            let key = "QuotaBackend.DecimalFormatter"
            if let formatter = Thread.current.threadDictionary[key] as? NumberFormatter {
                return formatter
            }

            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            Thread.current.threadDictionary[key] = formatter
            return formatter
        }
    }

    static let providerThemes: [String: ThemeInfo] = [
        "antigravity": ThemeInfo(accent: "sky", glow: "#5cc9ff"),
        "antigravity-cost": ThemeInfo(accent: "sky", glow: "#5cc9ff"),
        "claude":  ThemeInfo(accent: "sunset", glow: "#ff9d6c"),
        "claude-subscription": ThemeInfo(accent: "sunset", glow: "#d97757"),
        "codex-cost": ThemeInfo(accent: "indigo", glow: "#6875ff"),
        "codex":   ThemeInfo(accent: "violet", glow: "#8d7dff"),
        "copilot": ThemeInfo(accent: "blue",   glow: "#5aa2ff"),
        "cursor":  ThemeInfo(accent: "emerald",glow: "#4dd4aa"),
        "droid":   ThemeInfo(accent: "amber",  glow: "#ffb34d"),
        "gemini":  ThemeInfo(accent: "iris",   glow: "#7f8cff"),
        "kimi":    ThemeInfo(accent: "blue",   glow: "#1783ff"),
        "kiro":    ThemeInfo(accent: "violet", glow: "#9046ff"),
        "minimax": ThemeInfo(accent: "magenta",glow: "#e2167e"),
        "opencode": ThemeInfo(accent: "teal",  glow: "#2dd4bf"),
        "warp":    ThemeInfo(accent: "rose",   glow: "#ff7eb2")
    ]

    public static func normalize(provider: any ProviderFetcher, usage: ProviderUsage) -> ProviderSummary {
        let theme = providerThemes[provider.id] ?? ThemeInfo(accent: "slate", glow: "#8e96a8")
        let sourceLabel = formatSourceLabel(usage.source)

        let uniqueId: String
        if let acctId = usage.usageAccountId {
            uniqueId = "\(provider.id):\(acctId)"
        } else {
            uniqueId = provider.id
        }

        var base = ProviderSummary(
            id: uniqueId,
            providerId: provider.id,
            accountId: usage.usageAccountId,
            name: provider.displayName,
            label: compactProviderLabel(provider.id, fallback: usage.label),
            description: provider.description,
            category: "snapshot",
            channel: channel(for: provider.id),
            status: "healthy",
            statusLabel: "Active",
            theme: theme,
            sourceLabel: sourceLabel,
            sourceType: usage.source?.type ?? "unknown",
            fetchedAt: usage.fetchedAt,
            accountLabel: nil,
            membershipLabel: nil,
            remainingPercent: nil,
            nextResetAt: nil,
            nextResetLabel: nil,
            headline: HeadlineInfo(eyebrow: "", primary: "", secondary: "", supporting: ""),
            metrics: [],
            windows: [],
            costSummary: nil,
            models: nil,
            spotlight: "",
            unpricedModels: nil,
            raw: usage
        )

        var normalized: ProviderSummary
        switch provider.id {
        case "warp":    normalized = normalizeWarp(base: &base, usage: usage)
        case "antigravity": normalized = normalizeAntigravity(base: &base, usage: usage)
        case "antigravity-cost": normalized = normalizeAntigravityCost(base: &base, usage: usage)
        case "claude":  normalized = normalizeClaude(base: &base, usage: usage)
        case "claude-subscription": normalized = normalizeClaudeSubscription(base: &base, usage: usage)
        case "codex-cost": normalized = normalizeCodexCost(base: &base, usage: usage)
        case "copilot": normalized = normalizeCopilot(base: &base, usage: usage)
        case "codex":   normalized = normalizeCodex(base: &base, usage: usage)
        case "gemini":  normalized = normalizeGemini(base: &base, usage: usage)
        case "kimi":    normalized = normalizeKimi(base: &base, usage: usage)
        case "kiro":    normalized = normalizeKiro(base: &base, usage: usage)
        case "minimax": normalized = normalizeMiniMax(base: &base, usage: usage)
        case "opencode": normalized = normalizeOpenCode(base: &base, usage: usage)
        case "cursor":  normalized = normalizeCursor(base: &base, usage: usage)
        case "droid":   normalized = normalizeDroid(base: &base, usage: usage)
        default:
            base.headline = HeadlineInfo(eyebrow: "Live snapshot", primary: base.label, secondary: "Fetched successfully", supporting: sourceLabel)
            base.spotlight = "This provider is connected."
            normalized = base
        }

        if (usage.extra["snapshotState"]?.value as? String) == "pending" {
            normalized.fetchedAt = nil
            normalized.status = "idle"
            normalized.statusLabel = "Waiting"
            if normalized.remainingPercent == nil && normalized.windows.isEmpty {
                normalized.headline = HeadlineInfo(
                    eyebrow: normalized.headline.eyebrow,
                    primary: "Waiting for first sync",
                    secondary: "Local metadata only — awaiting quota sync",
                    supporting: normalized.headline.supporting
                )
            }
        }
        return normalized
    }

    public static func errorSummary(provider: any ProviderFetcher, error: Error) -> ProviderSummary {
        let theme = providerThemes[provider.id] ?? ThemeInfo(accent: "slate", glow: "#8e96a8")
        let msg = SensitiveDataRedactor.redactedMessage(for: error)
        var summary = ProviderSummary(
            id: provider.id,
            providerId: provider.id,
            accountId: nil,
            name: provider.displayName,
            label: compactProviderLabel(provider.id, fallback: provider.displayName),
            description: provider.description,
            category: "snapshot",
            channel: channel(for: provider.id),
            status: "error",
            statusLabel: "Error",
            theme: theme,
            sourceLabel: "Unavailable",
            sourceType: "unknown",
            fetchedAt: nil,
            accountLabel: nil,
            membershipLabel: nil,
            remainingPercent: nil,
            nextResetAt: nil,
            nextResetLabel: nil,
            headline: HeadlineInfo(eyebrow: "Collection failed", primary: "Unavailable", secondary: msg, supporting: "Check local auth or provider session"),
            metrics: [],
            windows: [],
            costSummary: nil,
            models: nil,
            spotlight: "This provider could not be fetched during the current refresh cycle.",
            unpricedModels: nil,
            raw: nil
        )
        summary.errorCode = (error as? ProviderError)?.code
        return summary
    }

    // MARK: - Dashboard Overview

    public struct OverviewEntry: Sendable {
        public let id: String
        public let label: String
        public let category: String
        public let status: String
        public let secondaryHeadline: String
        public let nextResetAt: String?
        public let monthUsd: Double
        public let weekTokens: Int
        public let unpricedAlertBody: String?

        public init(
            id: String,
            label: String,
            category: String,
            status: String,
            secondaryHeadline: String,
            nextResetAt: String?,
            monthUsd: Double = 0,
            weekTokens: Int = 0,
            unpricedAlertBody: String? = nil
        ) {
            self.id = id
            self.label = label
            self.category = category
            self.status = status
            self.secondaryHeadline = secondaryHeadline
            self.nextResetAt = nextResetAt
            self.monthUsd = monthUsd
            self.weekTokens = weekTokens
            self.unpricedAlertBody = unpricedAlertBody
        }
    }

    public static func createDashboardOverview(summaries: [ProviderSummary], generatedAt: String) -> DashboardOverview {
        let entries = summaries.map { s in
            OverviewEntry(
                id: s.id,
                label: s.label,
                category: s.category,
                status: s.status,
                secondaryHeadline: s.headline.secondary,
                nextResetAt: s.nextResetAt,
                monthUsd: s.costSummary?.month?.usd ?? 0,
                weekTokens: s.costSummary?.week?.tokens ?? 0,
                unpricedAlertBody: s.unpricedModels.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") }
            )
        }
        return createDashboardOverview(entries: entries, generatedAt: generatedAt)
    }

    public static func createDashboardOverview(entries: [OverviewEntry], generatedAt: String) -> DashboardOverview {
        let active     = entries.filter { $0.status != "error" }
        let attention  = entries.filter { $0.status == "watch" || $0.status == "critical" }
        let critical   = entries.filter { $0.status == "critical" }
        let localCost  = entries.filter { $0.category == ProviderCategory.localCost }
        let resetSoon  = entries.filter { e in e.nextResetAt.map { isWithinHours($0, hours: 24) } ?? false }

        let localCostMonthUsd = localCost.reduce(0.0) { $0 + $1.monthUsd }
        let localWeekTokens   = localCost.reduce(0) { $0 + $1.weekTokens }

        var alerts: [AlertInfo] = []
        for e in entries {
            if e.status == "critical" {
                alerts.append(
                    AlertInfo(
                        id: "\(e.id):status-critical",
                        tone: "critical",
                        providerId: e.id,
                        title: "\(e.label) needs attention",
                        body: e.secondaryHeadline
                    )
                )
            } else if e.status == "watch" {
                alerts.append(
                    AlertInfo(
                        id: "\(e.id):status-watch",
                        tone: "watch",
                        providerId: e.id,
                        title: "\(e.label) is getting tight",
                        body: e.secondaryHeadline
                    )
                )
            } else if let unpriced = e.unpricedAlertBody, !unpriced.isEmpty {
                alerts.append(
                    AlertInfo(
                        id: "\(e.id):unpriced-models",
                        tone: "neutral",
                        providerId: e.id,
                        title: "\(e.label) has unpriced models",
                        body: unpriced
                    )
                )
            }
        }

        return DashboardOverview(
            generatedAt: generatedAt,
            activeProviders:    active.count,
            attentionProviders: attention.count,
            criticalProviders:  critical.count,
            resetSoonProviders: resetSoon.count,
            localCostMonthUsd:  roundNumber(localCostMonthUsd, digits: 2),
            localWeekTokens:    localWeekTokens,
            stats: [
                StatInfo(label: "Connected Sources", value: "\(active.count)",    note: "\(entries.count) providers in the mesh"),
                StatInfo(label: "Attention Queue",   value: "\(attention.count)", note: critical.count > 0 ? "\(critical.count) critical right now" : "Everything is within normal range"),
                StatInfo(label: "Tracked Local Cost", value: formatCurrency(localCostMonthUsd), note: "\(formatInt(localWeekTokens)) tokens observed this week"),
                StatInfo(label: "Resets In 24h",     value: "\(resetSoon.count)", note: resetSoon.isEmpty ? "No urgent resets detected" : "A few windows are about to roll over")
            ],
            alerts: Array(alerts.prefix(6))
        )
    }

    // MARK: - Window Helpers

    static func createPercentWindow(label: String, window: RawQuotaWindow) -> WindowInfo {
        let remaining = window.remainingPercent
        let used = window.usedPercent ?? remaining.map { 100 - $0 }
        let note = window.resetDescription ?? formatShortDateTime(window.resetAt) ?? "Live snapshot"
        return WindowInfo(
            label: label,
            remainingPercent: remaining,
            usedPercent: used,
            value: remaining.map { "\(formatPercent($0)) left" } ?? "Tracked",
            note: note,
            resetAt: window.resetAt
        )
    }

    static func createEntitlementWindow(label: String, window: RawQuotaWindow) -> WindowInfo {
        if window.unlimited == true {
            return WindowInfo(label: label, remainingPercent: nil, usedPercent: nil, value: "Unlimited", note: window.resetDescription ?? "No fixed cap detected", resetAt: window.resetAt)
        }
        let remaining = window.remainingPercent
        let entitlement = window.entitlement ?? 0
        let rem = window.remaining ?? 0
        var note = "\(formatInt(entitlement)) total"
        if let rd = window.resetDescription { note += " • \(rd)" }
        return WindowInfo(
            label: label,
            remainingPercent: remaining,
            usedPercent: window.usedPercent ?? remaining.map { 100 - $0 },
            // Copilot 允许超额：remaining 为负数时显示超出多少，而不是 "-740 left"。
            value: rem < 0 ? "\(formatInt(-rem)) over" : "\(formatInt(rem)) left",
            note: note,
            resetAt: window.resetAt
        )
    }

    static func createQuotaWindow(label: String, window: RawQuotaWindow) -> WindowInfo {
        if window.unlimited == true {
            return WindowInfo(label: label, remainingPercent: nil, usedPercent: nil, value: "Unlimited", note: window.resetDescription ?? "No cap detected", resetAt: window.resetAt)
        }
        let remaining = window.remainingPercent
        let note = window.resetDescription ?? formatShortDateTime(window.resetAt) ?? "Live snapshot"
        return WindowInfo(
            label: label,
            remainingPercent: remaining,
            usedPercent: window.usedPercent,
            value: remaining.map { "\(formatPercent($0)) left" } ?? "Unknown",
            note: note,
            resetAt: window.resetAt
        )
    }

    static func pickSmallestRemaining(_ windows: [WindowInfo]) -> Double? {
        let values = windows.compactMap { $0.remainingPercent }
        return values.isEmpty ? nil : values.min()
    }

    static func resolveStatus(_ remaining: Double?) -> (String, String) {
        guard let r = remaining else { return ("healthy", "Active") }
        if r <= 12 { return ("critical", "Critical") }
        if r <= 30 { return ("watch", "Watch") }
        return ("healthy", "Healthy")
    }

    // MARK: - Extra field accessors

    static func extra(_ usage: ProviderUsage, _ key: String) -> Any? {
        usage.extra[key]?.value
    }

    static func extraString(_ usage: ProviderUsage, _ key: String) -> String? {
        usage.extra[key]?.value as? String
    }

    static func extraInt(_ usage: ProviderUsage, _ key: String) -> Int? {
        switch usage.extra[key]?.value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        default: return nil
        }
    }

    static func optionalInt(_ value: Any?) -> Int? {
        switch value {
        case let v as Int: return v
        case let v as Double: return Int(v)
        default: return nil
        }
    }

    static func extraDouble(_ usage: ProviderUsage, _ key: String) -> Double? {
        switch usage.extra[key]?.value {
        case let v as Double: return v
        case let v as Int: return Double(v)
        default: return nil
        }
    }

    static func extraStringArray(_ usage: ProviderUsage, _ key: String) -> [String] {
        (usage.extra[key]?.value as? [AnyCodable])?.compactMap { $0.value as? String } ?? []
    }

    static func extraCostTimeline(_ usage: ProviderUsage, _ key: String) -> [CostTimelinePoint] {
        guard let items = usage.extra[key]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let bucket = dict["bucket"]?.value as? String,
                  let label = dict["label"]?.value as? String else {
                return nil
            }

            let usd: Double
            switch dict["usd"]?.value {
            case let value as Double:
                usd = value
            case let value as Int:
                usd = Double(value)
            default:
                usd = 0
            }

            let tokens: Int
            switch dict["tokens"]?.value {
            case let value as Int:
                tokens = value
            case let value as Double:
                tokens = Int(value)
            default:
                tokens = 0
            }

            return CostTimelinePoint(
                bucket: bucket,
                label: label,
                usd: usd,
                tokens: tokens,
                inputTokens: optionalInt(dict["inputTokens"]?.value),
                outputTokens: optionalInt(dict["outputTokens"]?.value),
                cacheReadTokens: optionalInt(dict["cacheReadTokens"]?.value),
                cacheCreateTokens: optionalInt(dict["cacheCreateTokens"]?.value)
            )
        }
    }

    static func extractModelBreakdown(_ usage: ProviderUsage, _ key: String) -> [ModelCostInfo] {
        let rawItems = (usage.extra[key]?.value as? [AnyCodable]) ?? []
        return rawItems.compactMap { item in
            guard let m = item.value as? [String: AnyCodable],
                  let model = m["model"]?.value as? String else { return nil }
            func intVal(_ k: String) -> Int {
                switch m[k]?.value {
                case let v as Int: return v
                case let v as Double: return Int(v)
                default: return 0
                }
            }
            func dblVal(_ k: String) -> Double {
                switch m[k]?.value {
                case let v as Double: return v
                case let v as Int: return Double(v)
                default: return 0
                }
            }
            return ModelCostInfo(
                model: model,
                totalTokens: intVal("totalTokens"),
                inputTokens: intVal("inputTokens"),
                outputTokens: intVal("outputTokens"),
                cacheReadTokens: intVal("cacheReadTokens"),
                cacheCreateTokens: intVal("cacheCreateTokens"),
                estimatedCostUsd: dblVal("estimatedCostUsd"),
                percentage: dblVal("percentage")
            )
        }
    }

    private static func parseCostTimelinePoints(_ items: [AnyCodable]) -> [CostTimelinePoint] {
        items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let bucket = dict["bucket"]?.value as? String,
                  let label = dict["label"]?.value as? String else { return nil }
            let usd: Double
            switch dict["usd"]?.value {
            case let v as Double: usd = v
            case let v as Int: usd = Double(v)
            default: usd = 0
            }
            let tokens: Int
            switch dict["tokens"]?.value {
            case let v as Int: tokens = v
            case let v as Double: tokens = Int(v)
            default: tokens = 0
            }
            return CostTimelinePoint(
                bucket: bucket,
                label: label,
                usd: usd,
                tokens: tokens,
                inputTokens: optionalInt(dict["inputTokens"]?.value),
                outputTokens: optionalInt(dict["outputTokens"]?.value),
                cacheReadTokens: optionalInt(dict["cacheReadTokens"]?.value),
                cacheCreateTokens: optionalInt(dict["cacheCreateTokens"]?.value)
            )
        }
    }

    static func extraModelTimelines(_ usage: ProviderUsage, _ key: String) -> [ModelTimelineSeries] {
        guard let items = usage.extra[key]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let model = dict["model"]?.value as? String else { return nil }
            let hourlyRaw = dict["hourly"]?.value as? [AnyCodable] ?? []
            let dailyRaw = dict["daily"]?.value as? [AnyCodable] ?? []
            let hourly = parseCostTimelinePoints(hourlyRaw)
            let daily = parseCostTimelinePoints(dailyRaw)
            guard !hourly.isEmpty || !daily.isEmpty else { return nil }
            return ModelTimelineSeries(model: model, hourly: hourly, daily: daily)
        }
    }

    struct TrackedModel {
        let label: String
        let remainingPercent: Double
        let resetAt: String?
        let providerLabel: String?
    }

    static func extraTrackedModels(_ usage: ProviderUsage) -> [TrackedModel] {
        guard let items = usage.extra["trackedModels"]?.value as? [AnyCodable] else { return [] }
        return items.compactMap { item in
            guard let dict = item.value as? [String: AnyCodable],
                  let label = dict["label"]?.value as? String,
                  let remainingPercent = dict["remainingPercent"]?.value as? Double else {
                return nil
            }

            let resetAt = (dict["resetAt"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }
            let providerLabel = (dict["providerLabel"]?.value as? String).flatMap { $0.isEmpty ? nil : $0 }

            return TrackedModel(
                label: label,
                remainingPercent: remainingPercent,
                resetAt: resetAt,
                providerLabel: providerLabel
            )
        }
    }

    // MARK: - Format Helpers

    static func formatSourceLabel(_ source: SourceInfo?) -> String {
        guard let s = source else { return "Unknown source" }
        if s.mode == "manual" { return s.type == "env-var" ? "Environment variable" : "Manual credentials" }
        if s.mode == "stored" {
            let labels: [String: String] = [
                "keychain-credential": "Stored credential",
                "webview-session": "WebView session",
                "pasted-cookie": "Pasted cookie"
            ]
            return labels[s.type] ?? "Stored session"
        }
        if s.type == "browser-cookie" { return [s.browserName, s.profile].compactMap { $0 }.joined(separator: " · ").isEmpty ? "Browser session" : [s.browserName, s.profile].compactMap { $0 }.joined(separator: " · ") }
        let labels: [String: String] = [
            "app-cache": "Desktop cache",
            "cli-proxy-auth-file": "Imported auth file",
            "imported-auth-file": "Imported auth file",
            "gh-cli": "GitHub CLI",
            "cli-auth-file": "Local CLI session",
            "claude-project-logs": "Local Claude logs",
            "claude-proxy-usage": "Proxy usage ledger",
            "claude-local-ledger": "Proxy + non-proxy ledger",
            "codex-session-logs": "Local Codex logs",
            "codex-proxy-non-proxy": "Proxy + non-proxy ledger",
            "opencode-session-db": "Local OpenCode sessions",
            "gemini-cli": "Gemini CLI OAuth",
            "kiro-ide-auth-file": "Kiro IDE session",
            "pasted-cookie": "Pasted cookie",
            "imported-credential": "Imported credential"
        ]
        return labels[s.type] ?? s.type
    }

    private static func channel(for providerId: String) -> String {
        switch providerId {
        case "cursor", "copilot", "kiro", "antigravity", "warp":
            return "ide"
        case "claude", "codex-cost", "opencode", "antigravity-cost":
            return "local"
        default:
            return "cli"
        }
    }

    private static func compactProviderLabel(_ providerId: String, fallback: String) -> String {
        switch providerId {
        case "codex-cost":
            return "Codex"
        case "antigravity-cost":
            return "Antigravity"
        case "claude":
            return "Claude"
        case "copilot":
            return "Copilot"
        case "gemini":
            return "Gemini CLI"
        case "opencode":
            return "OpenCode"
        default:
            return fallback
        }
    }

    static func preferredAccountEmail(_ usage: ProviderUsage) -> String? {
        guard let email = usage.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines),
              email.contains("@") else {
            return nil
        }
        return email
    }

    static func membershipBadge(from raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        let uppercase = value.uppercased()
        if uppercase.contains("ULTRA") { return "Ultra" }
        if uppercase.contains("ENTERPRISE") { return "Enterprise" }
        if uppercase.contains("BUSINESS") { return "Business" }
        if uppercase.contains("TEAM") { return "Team" }
        if uppercase.contains("PREMIUM") { return "Premium" }
        if uppercase.contains("PRO") { return "Pro" }
        if uppercase.contains("PLUS") { return "Plus" }
        if uppercase.contains("MAX") { return "Max" }
        if uppercase.contains("FREE") { return "Free" }
        if uppercase.contains("HOBBY") { return "Hobby" }
        if uppercase.contains("LOCAL") { return "Local" }

        return titleCase(value)
    }

    static func formatKiroAuthMethod(_ value: String?) -> String? {
        guard let value else { return nil }
        switch value.lowercased() {
        case "social": return "Google OAuth"
        case "idc": return "AWS Builder ID"
        default: return titleCase(value)
        }
    }

    private static func warpDomainLabel(_ domain: String) -> String {
        ["dev.warp.Warp-Stable": "Warp Stable", "dev.warp.Warp-Preview": "Warp Preview", "dev.warp.Warp-Nightly": "Warp Nightly"][domain] ?? domain
    }

    static func formatCurrency(_ value: Double) -> String {
        let fractionDigits = value >= 1 ? 2 : 4
        let fmt = FormatterCache.currencyFormatter(fractionDigits: fractionDigits)
        return fmt.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    static func formatPercent(_ value: Double) -> String {
        let fmt = FormatterCache.percentFormatter()
        return "\(fmt.string(from: NSNumber(value: value)) ?? "0")%"
    }

    static func formatInt(_ value: Int) -> String {
        let fmt = FormatterCache.decimalFormatter()
        return fmt.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    static func formatRange(_ start: String?, _ end: String?) -> String {
        [start, end].compactMap { $0 }.compactMap { s -> String? in
            guard let d = SharedFormatters.parseISO8601(s) else { return nil }
            return DateFormat.string(from: d, format: "MMM d")
        }.joined(separator: " → ")
    }

    static func formatShortDateTime(_ value: String?) -> String? {
        guard let v = value, let date = parseDate(v) else { return nil }
        return DateFormat.string(from: date, format: "MMM d, HH:mm")
    }

    static func parseDate(_ s: String) -> Date? {
        SharedFormatters.parseISO8601(s)
    }

    private static func isWithinHours(_ value: String, hours: Double) -> Bool {
        guard let date = parseDate(value) else { return false }
        let diff = date.timeIntervalSinceNow
        return diff > 0 && diff <= hours * 3600
    }

    static func joinParts(_ parts: [String?]) -> String? {
        let filtered = parts.compactMap { $0 }
        return filtered.isEmpty ? nil : filtered.joined(separator: " / ")
    }

    static func titleCase(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "_- ")).map { $0.capitalized }.joined(separator: " ")
    }

    private static func roundNumber(_ value: Double, digits: Int) -> Double {
        let factor = pow(10.0, Double(digits))
        return (value * factor).rounded() / factor
    }
}
