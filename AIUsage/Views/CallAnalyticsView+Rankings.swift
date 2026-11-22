import SwiftUI
import QuotaBackend

// MARK: - Call Analytics Rankings
// Top-N 排行：按 MCP（server 折叠）/ 技能 / 工具 维度展示调用次数条形榜。
// Phase 2：行内附「成功率 · 平均耗时」徽章（仅在来源提供该信号时显示，缺失留白）；
// MCP 维度可点 server 下钻展开其具体 tool 列表。

extension CallAnalyticsView {
    var rankingCard: some View {
        let rows = Array(derived.ranking(for: lens).prefix(12))
        let maxCount = max(rows.map(\.count).max() ?? 1, 1)
        // 当前维度若至少一行有成功率/耗时，才显示指标列（技能/工具维度通常无 → 不占位）。
        let showMetrics = rows.contains { $0.successRate != nil || $0.avgDurationMs != nil }
        return cardContainer(title: rankingTitle, subtitle: rankingSubtitle) {
            StatsSegmentedControl(
                CallLens.allCases,
                selection: $lens,
                segmentWidth: 60,
                tint: .purple
            ) { $0.title }
            .onChange(of: lens) { _, _ in expandedServers.removeAll() }

            if rows.isEmpty {
                Text(L("No \(lens.title) calls in range", "范围内暂无\(lens.title)调用", "Không có lượt gọi \(lens.title) trong khoảng này", key: "calls.rank.empty"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
            } else {
                rankingLegend(showMetrics: showMetrics)
                VStack(spacing: 8) {
                    ForEach(rows) { row in
                        rankingRow(row, maxCount: maxCount, showMetrics: showMetrics, isChild: false)
                        if lens == .mcp, row.isDrillable, expandedServers.contains(row.id) {
                            drillDown(server: row.id, maxCount: maxCount, showMetrics: showMetrics)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
    }

    /// 列含义图例：进度条=调用次数、%=成功率（有指标时）、圆点=来源（仅「全部」范围下来源点才有意义）。
    @ViewBuilder
    private func rankingLegend(showMetrics: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Capsule().fill(barColor).frame(width: 16, height: 7)
                Text(L("Calls", "调用次数", key: "calls.legend.count"))
            }
            if showMetrics {
                HStack(spacing: 5) {
                    Text("%").foregroundStyle(.green)
                    Text(L("Success rate", "成功率", key: "calls.legend.rate"))
                }
            }
            if scope == .all {
                HStack(spacing: 9) {
                    ForEach(visibleSourceKinds, id: \.self) { source in
                        HStack(spacing: 4) {
                            Circle().fill(CallAnalyticsView.color(for: source)).frame(width: 6, height: 6)
                            Text(source.displayName)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    /// 某个 server 下钻：展开其具体 tool 行（缩进、字号更小）。
    /// 子项进度条沿用母级（全局）maxCount，而非子项内部最大值——这样每个 tool 的条长
    /// 与同 count 的顶层行一致，且必然 ≤ 母级 server 条（母级 = 各 tool 之和），不会出现“子比母长”。
    @ViewBuilder
    private func drillDown(server: String, maxCount: Int, showMetrics: Bool) -> some View {
        let tools = derived.mcpTools(forServer: server)
        if tools.isEmpty {
            EmptyView()
        } else {
            // 缩进 34 = 母级「chevron(12)+间距(10)+名列(200)」与子级「名列(188)+间距(10)」对齐，
            // 使子条与母条同一左缘起点；子名相对母名再缩进一个 chevron 宽度，体现层级。
            VStack(spacing: 6) {
                ForEach(tools) { rankingRow($0, maxCount: maxCount, showMetrics: showMetrics, isChild: true) }
            }
            .padding(.leading, 34)
            .padding(.vertical, 2)
        }
    }

    private var rankingTitle: String {
        switch lens {
        case .mcp: return L("Top MCP Servers", "MCP Server 排行", key: "calls.rank.mcp")
        case .skill: return L("Top Skills", "技能排行", key: "calls.rank.skill")
        case .tools: return L("Top Tools", "工具排行", key: "calls.rank.tools")
        }
    }

    private var rankingSubtitle: String {
        switch lens {
        case .mcp: return L("Calls grouped by MCP server — click to expand tools", "按 MCP server 折叠计数 · 点击展开 tool", key: "calls.rank.mcp.sub")
        case .skill: return L("Skill invocations by name", "按技能名统计调用", key: "calls.rank.skill.sub")
        case .tools: return L("Built-in / web tools by name", "内置 / 网络工具调用", key: "calls.rank.tools.sub")
        }
    }

    private func rankingRow(_ row: RankedRow, maxCount: Int, showMetrics: Bool, isChild: Bool) -> some View {
        let canDrill = lens == .mcp && row.isDrillable && !isChild
        return HStack(spacing: 10) {
            if canDrill {
                Button {
                    toggleExpand(row.id)
                } label: {
                    Image(systemName: expandedServers.contains(row.id) ? "chevron.down" : "chevron.right")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
            } else if lens == .mcp && !isChild {
                Spacer().frame(width: 12)
            }

            Text(row.name)
                .font(isChild ? .caption : .callout)
                .foregroundStyle(isChild ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: isChild ? 188 : 200, alignment: .leading)

            GeometryReader { proxy in
                let ratio = CGFloat(row.count) / CGFloat(maxCount)
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(isChild ? barColor.opacity(0.55) : barColor)
                        .frame(width: max(4, proxy.size.width * ratio))
                }
            }
            .frame(height: isChild ? 10 : 14)

            if showMetrics {
                metricBadge(row)
            }

            // 来源圆点仅在「全部」范围下展示——单应用筛选时所有点同色、零信息量，故隐藏整列。
            if scope == .all {
                HStack(spacing: 3) {
                    ForEach(Array(row.sources).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { source in
                        Circle().fill(CallAnalyticsView.color(for: source)).frame(width: 6, height: 6)
                    }
                }
                .frame(width: 40, alignment: .trailing)
            }

            Text("\(row.count)")
                .font((isChild ? Font.caption : Font.callout).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
    }

    /// 成功率 · 平均耗时徽章。两者各自缺数据则不显示对应段，全缺则该行此列留白。
    private func metricBadge(_ row: RankedRow) -> some View {
        HStack(spacing: 4) {
            if let rate = row.successRate {
                Text(Self.formatRate(rate))
                    .foregroundStyle(rate >= 0.999 ? Color.green : (rate >= 0.9 ? Color.secondary : Color.orange))
                    .help(L("Success rate", "成功率", key: "calls.metric.success.help"))
            }
            if row.successRate != nil, row.avgDurationMs != nil {
                Text("·").foregroundStyle(.tertiary)
            }
            if let ms = row.avgDurationMs {
                Text(Self.formatDuration(ms))
                    .foregroundStyle(.secondary)
                    .help(L("Average duration", "平均耗时", key: "calls.metric.duration.help"))
            }
        }
        .font(.caption2.monospacedDigit())
        .frame(width: 92, alignment: .trailing)
    }

    private var barColor: Color {
        switch lens {
        case .mcp: return .purple
        case .skill: return .pink
        case .tools: return .teal
        }
    }

    private func toggleExpand(_ server: String) {
        if expandedServers.contains(server) {
            expandedServers.remove(server)
        } else {
            expandedServers.insert(server)
        }
    }

    static func formatRate(_ rate: Double) -> String {
        "\(Int((rate * 100).rounded()))%"
    }

    static func formatDuration(_ ms: Double) -> String {
        if ms < 1 { return "<1ms" }
        if ms < 1000 { return "\(Int(ms.rounded()))ms" }
        return String(format: "%.1fs", ms / 1000)
    }
}
