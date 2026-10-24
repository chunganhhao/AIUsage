import Foundation

extension UsageNormalizer {

    // MARK: - Copilot

    static func normalizeCopilot(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let planName = usage.accountPlan ?? "Unknown"
        let accountLogin = usage.accountLogin ?? "GitHub account"
        let quotaResetAt = extraString(usage, "quotaResetAt")
        let planNote = extraString(usage, "planNote")

        var windows: [WindowInfo] = []
        let premiumLabel = extraString(usage, "premiumUnit") == "credits" ? "AI Credits" : "Premium"
        if let w = usage.primary   { windows.append(createEntitlementWindow(label: premiumLabel, window: w)) }
        if let w = usage.secondary { windows.append(createEntitlementWindow(label: "Chat", window: w)) }
        if let w = usage.tertiary  { windows.append(createEntitlementWindow(label: "Completions", window: w)) }

        let remainingPercent = pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)

        var metrics: [MetricInfo] = [
            MetricInfo(label: "Account", value: accountLogin),
            MetricInfo(label: "Plan",    value: planName, note: planNote?.isEmpty == false ? planNote : nil),
            MetricInfo(label: "Reset",   value: extraString(usage, "resetDescription") ?? formatShortDateTime(quotaResetAt) ?? "Unknown"),
            MetricInfo(label: "Source",  value: formatSourceLabel(usage.source))
        ]
        if let email = usage.accountEmail {
            metrics.insert(MetricInfo(label: "Email", value: email), at: 1)
        }

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: planName)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = quotaResetAt
        base.nextResetLabel = formatShortDateTime(quotaResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(planName)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Unlimited",
            secondary: remainingPercent == nil ? "Most Copilot lanes are unlimited" : "tightest Copilot lane",
            supporting: accountLogin
        )
        base.metrics = metrics
        base.windows = windows
        base.spotlight = "Copilot can mix unlimited and metered lanes. The dashboard keeps unlimited channels visible, but only metered windows affect watch and critical states."
        return base
    }
}
