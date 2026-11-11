import SwiftUI
import QuotaBackend

// MARK: - Call Analytics Derived
// 把快照按当前筛选（来源 scope）派生为 UI 直接消费的结构：KPI、Top-N 排行、每日趋势、零调用。
// 纯计算、无副作用，保持视图层简洁。

/// 来源筛选。
enum CallScope: String, CaseIterable, Identifiable {
    case all, claude, codex, opencode, antigravity
    var id: String { rawValue }

    var sourceKind: CallSourceKind? {
        switch self {
        case .all: return nil
        case .claude: return .claude
        case .codex: return .codex
        case .opencode: return .opencode
        case .antigravity: return .antigravity
        }
    }

    var title: String {
        switch self {
        case .all: return L("All", "全部", key: "calls.scope.all")
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .opencode: return "OpenCode"
        case .antigravity: return "Antigravity"
        }
    }
}

/// 排行维度。
enum CallLens: String, CaseIterable, Identifiable {
    case mcp, skill, tools
    var id: String { rawValue }

    var title: String {
        switch self {
        case .mcp: return L("MCP", "MCP", key: "calls.lens.mcp")
        case .skill: return L("Skills", "技能", key: "calls.lens.skill")
        case .tools: return L("Tools", "工具", key: "calls.lens.tools")
        }
    }
}

/// 解析时间范围。前四档为日历口径，与「用量统计」的 `ChartTimeRange` 完全一致：
/// 今日=今天 0 点起、本周=本周一起、本月=本月 1 号起、全部=不设下限；
/// `custom` 由视图按用户所选起止日期解析（见 `CallAnalyticsView.rangeSpec`）。
enum CallWindow: String, CaseIterable, Identifiable {
    case today
    case week
    case month
    case all
    case custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .today:  return L("Today", "今日", key: "calls.window.today")
        case .week:   return L("Week", "本周", key: "calls.window.week")
        case .month:  return L("Month", "本月", key: "calls.window.month")
        case .all:    return L("All", "全部", key: "calls.window.all")
        case .custom: return L("Custom", "自定义", key: "calls.window.custom")
        }
    }

    /// 该档自身的稳定标识。`custom` 的实际缓存键含起止日期，由视图拼接，不用此值。
    var rangeKey: String { rawValue }

    /// 起始日界（含）。`nil` = 不设下限（全部）。语义与用量统计 `ChartTimeRange.startDate` 一致。
    /// `custom` 返回 nil——其起止由视图依用户所选日期解析。
    func cutoff(now: Date = Date(), calendar: Calendar = .current) -> Date? {
        switch self {
        case .today:
            return calendar.startOfDay(for: now)
        case .week:
            let weekday = calendar.component(.weekday, from: now) // 1=Sun（公历）
            let mondayOffset = (weekday + 5) % 7
            return calendar.date(byAdding: .day, value: -mondayOffset, to: calendar.startOfDay(for: now))
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start
        case .all, .custom:
            return nil
        }
    }
}

struct RankedRow: Identifiable {
    let id: String
    let name: String
    let count: Int
    let sources: Set<CallSourceKind>
    /// 成功率（0...1）。无结果信号时为 nil（UI 留白，不显示 0%）。
    var successRate: Double? = nil
    /// 平均耗时（毫秒）。无计时数据时为 nil。
    var avgDurationMs: Double? = nil
    /// 该行是否为可下钻的 MCP server（其下还有具体 tool）。
    var isDrillable: Bool = false
}

struct InventoryStatusRow: Identifiable {
    let id: String
    let name: String
    let count: Int
    var used: Bool { count > 0 }
}

/// Claude 按 agent 分组的一行：`count` = 该 agent 的被调用次数（按会话计），非工具调用数。
struct AgentBreakdownRow: Identifiable {
    let id: String          // "main" 或具体 agentType（Explore/Plan/…）；"subagent" = 类型未知
    let count: Int
}

struct CallAnalyticsDerived {
    let snapshot: CallAnalyticsSnapshot
    let scope: CallScope
    /// 被侧边栏隐藏的来源——即使在「全部」聚合下也彻底排除（与用量统计一致）。
    var hiddenSources: Set<CallSourceKind> = []

    /// 按来源 scope 过滤后的条目；「全部」时排除被隐藏的来源。
    var entries: [CallAnalyticsEntry] {
        if let kind = scope.sourceKind {
            return snapshot.entries.filter { $0.source == kind }
        }
        guard !hiddenSources.isEmpty else { return snapshot.entries }
        return snapshot.entries.filter { !hiddenSources.contains($0.source) }
    }

    // MARK: - KPI

    var totalCalls: Int { entries.reduce(0) { $0 + $1.count } }
    var mcpCalls: Int { entries.filter { $0.kind == .mcp }.reduce(0) { $0 + $1.count } }
    var skillCalls: Int { entries.filter { $0.kind == .skill }.reduce(0) { $0 + $1.count } }

    var usedServers: Set<String> {
        Set(entries.compactMap { $0.kind == .mcp ? $0.server : nil })
    }

    var usedSkills: Set<String> {
        Set(entries.filter { $0.kind == .skill }.map { $0.name })
    }

    /// 当前 scope 下「已安装」的技能名。指定来源时只取该来源装的；scope=全部 取并集（排除隐藏来源）。
    var installedSkillNames: Set<String> {
        if let kind = scope.sourceKind {
            return Set(snapshot.installedSkills.filter { $0.source == kind }.map(\.name))
        }
        return Set(snapshot.installedSkills.filter { !hiddenSources.contains($0.source) }.map(\.name))
    }

    /// 当前 scope 下「已配置」的 MCP server 名（scope=全部 时排除隐藏来源）。
    var installedServerNames: Set<String> {
        if let kind = scope.sourceKind {
            return Set(snapshot.installedMCPServers.filter { $0.source == kind }.map(\.name))
        }
        return Set(snapshot.installedMCPServers.filter { !hiddenSources.contains($0.source) }.map(\.name))
    }

    var zombieSkillCount: Int {
        installedSkillNames.subtracting(usedSkills).count
    }

    // MARK: - Rankings

    func ranking(for lens: CallLens) -> [RankedRow] {
        switch lens {
        case .mcp:
            return rankedByServer()
        case .skill:
            return ranked(entries.filter { $0.kind == .skill })
        case .tools:
            return ranked(entries.filter { $0.kind == .builtin || $0.kind == .webSearch || $0.kind == .other })
        }
    }

    /// 一组条目按指定键聚合的累加器（计数 + 成功率/耗时分量 + 来源集合）。
    private struct RankAgg {
        var count = 0
        var outcomeKnown = 0
        var success = 0
        var durationSamples = 0
        var durationMsTotal = 0.0
        var sources: Set<CallSourceKind> = []

        mutating func add(_ entry: CallAnalyticsEntry) {
            count += entry.count
            outcomeKnown += entry.outcomeKnownCount
            success += entry.successCount
            durationSamples += entry.durationSampleCount
            durationMsTotal += entry.durationMsTotal
            sources.insert(entry.source)
        }

        var successRate: Double? { outcomeKnown > 0 ? Double(success) / Double(outcomeKnown) : nil }
        var avgDurationMs: Double? { durationSamples > 0 ? durationMsTotal / Double(durationSamples) : nil }
    }

    /// MCP 维度按 server 折叠（一个 server 的所有 tool 合并计数 + 指标），并标记可下钻。
    func rankedByServer() -> [RankedRow] {
        let mcp = entries.filter { $0.kind == .mcp }
        var aggs: [String: RankAgg] = [:]
        for entry in mcp {
            aggs[entry.server ?? entry.name, default: RankAgg()].add(entry)
        }
        return aggs.map { key, agg in
            RankedRow(id: key, name: key, count: agg.count, sources: agg.sources,
                      successRate: agg.successRate, avgDurationMs: agg.avgDurationMs, isDrillable: true)
        }
        .sorted(by: Self.rankOrder)
    }

    /// 单个 MCP server 下的具体 tool 列表（下钻用），name 仅取 tool 段。
    func mcpTools(forServer server: String) -> [RankedRow] {
        let subset = entries.filter { $0.kind == .mcp && ($0.server ?? $0.name) == server }
        var aggs: [String: RankAgg] = [:]
        for entry in subset { aggs[entry.name, default: RankAgg()].add(entry) }
        let prefix = server + "/"
        return aggs.map { fullName, agg in
            let tool = fullName.hasPrefix(prefix) ? String(fullName.dropFirst(prefix.count)) : fullName
            return RankedRow(id: fullName, name: tool, count: agg.count, sources: agg.sources,
                             successRate: agg.successRate, avgDurationMs: agg.avgDurationMs)
        }
        .sorted(by: Self.rankOrder)
    }

    /// MCP 维度展开到具体 tool（server/tool）。
    func rankedMCPTools() -> [RankedRow] {
        ranked(entries.filter { $0.kind == .mcp })
    }

    private func ranked(_ subset: [CallAnalyticsEntry]) -> [RankedRow] {
        var aggs: [String: RankAgg] = [:]
        for entry in subset { aggs[entry.name, default: RankAgg()].add(entry) }
        return aggs.map { key, agg in
            RankedRow(id: key, name: key, count: agg.count, sources: agg.sources,
                      successRate: agg.successRate, avgDurationMs: agg.avgDurationMs)
        }
        .sorted(by: Self.rankOrder)
    }

    /// 排行排序：次数降序 → 名称升序。
    /// 同次数时用名称定序，避免字典枚举顺序导致同分项每次刷新位次抖动。
    private static func rankOrder(_ a: RankedRow, _ b: RankedRow) -> Bool {
        if a.count != b.count { return a.count > b.count }
        return a.name < b.name
    }

    // MARK: - Agent breakdown (Claude only)

    /// 当前 scope 下是否有 Claude subagent 活动（决定是否显示 agent 分组卡）。
    /// 口径为「被调用次数」（按会话计），与子代理是否调过工具无关——纯文本输出的子代理也算。
    /// agent 取值：`"main"` = 主会话；其余（具体类型 Explore/Plan… 或兜底 "subagent"）= 子代理。
    var hasSubagentActivity: Bool {
        guard scope == .all || scope == .claude else { return false }
        guard !hiddenSources.contains(.claude) else { return false }
        return snapshot.agentInvocations.contains { $0.source == .claude && $0.agent != "main" && $0.count > 0 }
    }

    /// Claude 按 agent 分组：主会话 + 每个被调用过的子代理类型各一行，`count` = 被调用次数（按会话计）。
    /// 数据源为 `subagents/*.meta.json` 边车统计，故纯文本输出 / 自定义子代理都会出现。其它来源无此维度。
    func agentBreakdown() -> [AgentBreakdownRow] {
        guard scope == .all || scope == .claude else { return [] }
        guard !hiddenSources.contains(.claude) else { return [] }
        var merged: [String: Int] = [:]
        for inv in snapshot.agentInvocations where inv.source == .claude && inv.count > 0 {
            merged[inv.agent, default: 0] += inv.count
        }
        guard !merged.isEmpty else { return [] }
        return merged.map { AgentBreakdownRow(id: $0.key, count: $0.value) }
            .sorted(by: Self.agentOrder)
    }

    /// 排序：主会话永远第一；其余子代理类型按次数降序 → 名称升序。
    private static func agentOrder(_ a: AgentBreakdownRow, _ b: AgentBreakdownRow) -> Bool {
        if a.id == "main" || b.id == "main" { return a.id == "main" && b.id != "main" }
        if a.count != b.count { return a.count > b.count }
        return a.id < b.id
    }

    // MARK: - Daily trend

    /// 每日总调用计数，按日期升序。
    var dailyCounts: [(day: String, count: Int)] {
        var counts: [String: Int] = [:]
        for entry in entries {
            counts[entry.dayKey, default: 0] += entry.count
        }
        return counts.sorted { $0.key < $1.key }.map { (day: $0.key, count: $0.value) }
    }

    // MARK: - Zero-call inventory

    func skillStatuses() -> [InventoryStatusRow] {
        var used: [String: Int] = [:]
        for entry in entries where entry.kind == .skill {
            used[entry.name, default: 0] += entry.count
        }
        let names = installedSkillNames.union(used.keys)
        return names.map { InventoryStatusRow(id: $0, name: $0, count: used[$0] ?? 0) }
            .sorted(by: Self.inventoryOrder)
    }

    func serverStatuses() -> [InventoryStatusRow] {
        var used: [String: Int] = [:]
        for entry in entries where entry.kind == .mcp {
            let key = entry.server ?? entry.name
            used[key, default: 0] += entry.count
        }
        let names = installedServerNames.union(used.keys)
        return names.map { InventoryStatusRow(id: $0, name: $0, count: used[$0] ?? 0) }
            .sorted(by: Self.inventoryOrder)
    }

    /// 排序：已调用在前 → 次数降序 → 名称升序。
    private static func inventoryOrder(_ a: InventoryStatusRow, _ b: InventoryStatusRow) -> Bool {
        if a.used != b.used { return a.used && !b.used }
        if a.count != b.count { return a.count > b.count }
        return a.name < b.name
    }
}
