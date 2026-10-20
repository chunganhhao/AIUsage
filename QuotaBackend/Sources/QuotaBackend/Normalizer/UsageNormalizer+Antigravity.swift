import Foundation

extension UsageNormalizer {

    // MARK: - Antigravity

    static func normalizeAntigravity(base: inout ProviderSummary, usage: ProviderUsage) -> ProviderSummary {
        let trackedModels = extraTrackedModels(usage)
        let windows = trackedModels.map { model in
            WindowInfo(
                label: model.label,
                remainingPercent: model.remainingPercent,
                usedPercent: max(0, 100 - model.remainingPercent),
                value: "\(formatPercent(model.remainingPercent)) left",
                note: joinParts([model.providerLabel, formatShortDateTime(model.resetAt)]) ?? formatShortDateTime(model.resetAt) ?? "Live snapshot",
                resetAt: model.resetAt
            )
        }

        let remainingPercent = trackedModels.map(\.remainingPercent).min() ?? pickSmallestRemaining(windows)
        let (status, statusLabel) = resolveStatus(remainingPercent)
        let plan = usage.accountPlan ?? "Unknown"
        let projectId = extraString(usage, "projectId")
        let modelCount = extraInt(usage, "modelCount") ?? trackedModels.count
        let authFileCount = extraInt(usage, "authFileCount") ?? 1
        let selectedAuthFile = extraString(usage, "selectedAuthFile")
        // "groups"：按模型组的 5 小时 / 每周窗口；"models"（或旧快照缺省）：按模型的配额。
        let isGrouped = extraString(usage, "quotaSource") == "groups"

        base.accountLabel = preferredAccountEmail(usage)
        base.membershipLabel = membershipBadge(from: plan)
        base.category = "quota"
        base.status = status
        base.statusLabel = statusLabel
        base.remainingPercent = remainingPercent
        base.nextResetAt = trackedModels.compactMap { $0.resetAt }.compactMap(parseDate).min().map { SharedFormatters.iso8601String(from: $0) }
        base.nextResetLabel = formatShortDateTime(base.nextResetAt)
        base.headline = HeadlineInfo(
            eyebrow: "Plan · \(plan)",
            primary: remainingPercent.map { formatPercent($0) } ?? "Connected",
            secondary: remainingPercent == nil
                ? "Antigravity quota snapshot"
                : (isGrouped ? "lowest remaining window" : "lowest remaining model"),
            supporting: usage.accountEmail ?? projectId ?? "CLIProxy auth file"
        )
        base.metrics = [
            MetricInfo(label: "Account", value: usage.accountEmail ?? "Unknown"),
            MetricInfo(label: "Project", value: projectId ?? "Unknown"),
            MetricInfo(label: isGrouped ? "Quota Windows" : "Tracked Models", value: formatInt(modelCount)),
            MetricInfo(label: "Source", value: formatSourceLabel(usage.source))
        ]
        base.windows = windows
        // 分组窗口已经全部列在 windows 里，再列一遍模型只是重复。
        base.models = trackedModels.isEmpty || isGrouped ? nil : trackedModels.map {
            ModelInfo(
                label: $0.label,
                value: formatPercent($0.remainingPercent),
                note: joinParts([$0.providerLabel, formatShortDateTime($0.resetAt)])
            )
        }
        base.spotlight = authFileCount > 1
            ? "Antigravity auth files detected: \(formatInt(authFileCount)). This snapshot uses the most recently updated file (\(selectedAuthFile ?? "unknown"))."
            : isGrouped
                ? "Antigravity meters quota per model group, each with a 5-hour and a weekly limit, so the dashboard lists every window and puts the tightest ones first."
                : "Antigravity exposes per-model quotas, so the dashboard keeps each model separate and puts the tightest ones first."
        return base
    }
}
