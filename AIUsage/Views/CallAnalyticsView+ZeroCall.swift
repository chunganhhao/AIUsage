import SwiftUI
import QuotaBackend

// MARK: - Call Analytics Zero-Call Detection
// 零调用检测：把「本地已装 skill / 已配置 MCP server」与「窗口内实际调用」对照，
// 标出从未调用的「可清理」候选。跟随顶部来源筛选：选某应用即只看该应用自己装的清单与其调用，
// 选「全部」则取三家并集、任一工具用过即算已用。与上方 KPI 同口径，数字一致。

extension CallAnalyticsView {
    var zeroCallCard: some View {
        // 跟随当前 scope（与 KPI 一致）：按应用看各自的技能/MCP 与僵尸。
        let skills = derived.skillStatuses()
        let servers = derived.serverStatuses()

        return cardContainer(
            title: L("Zero-Call Detection", "零调用检测", key: "calls.zero.title"),
            subtitle: L("Installed but never called = cleanup candidates",
                        "装了但从未调用 = 可清理候选",
                        key: "calls.zero.sub")
        ) {
            inventoryBlock(
                title: L("Skills", "技能", key: "calls.zero.skills"),
                rows: skills,
                emptyHint: L("No skills detected locally.", "本地未探测到技能。", key: "calls.zero.skills.empty")
            )

            if !servers.isEmpty {
                Divider().padding(.vertical, 4)
                inventoryBlock(
                    title: L("MCP Servers", "MCP Server", key: "calls.zero.servers"),
                    rows: servers,
                    emptyHint: ""
                )
            }
        }
    }

    private func inventoryBlock(title: String, rows: [InventoryStatusRow], emptyHint: String) -> some View {
        let usedCount = rows.filter(\.used).count
        let zombieCount = rows.count - usedCount
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                if !rows.isEmpty {
                    Text(L("\(usedCount) used / \(rows.count) total · \(zombieCount) cleanup",
                           "已用 \(usedCount) / 共 \(rows.count) · 可清理 \(zombieCount)",
                           "\(usedCount) đã dùng / \(rows.count) tổng · \(zombieCount) cần dọn",
                           key: "calls.zero.summary"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            if rows.isEmpty {
                Text(emptyHint).font(.caption).foregroundStyle(.tertiary)
            } else {
                // 流式自适应：芯片按内容宽度排布、自动换行，长名整行完整显示，不再截断。
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(rows) { inventoryChip($0) }
                }
            }
        }
    }

    private func inventoryChip(_ row: InventoryStatusRow) -> some View {
        HStack(spacing: 6) {
            Image(systemName: row.used ? "checkmark.circle.fill" : "moon.zzz.fill")
                .font(.caption2)
                .foregroundStyle(row.used ? Color.green : Color.orange)
            Text(row.name)
                .font(.caption)
                .lineLimit(1)
            if row.used {
                Text("\(row.count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help(row.name)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(row.used ? Color.green.opacity(0.08) : Color.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(row.used ? Color.green.opacity(0.25) : Color.orange.opacity(0.3),
                        style: StrokeStyle(lineWidth: 1, dash: row.used ? [] : [3, 2]))
        )
    }
}

// MARK: - Flow Layout
// 标签云式流式布局：子视图按各自内容宽度从左到右排布，超出容器宽度自动换行。
// 取代等宽 LazyVGrid，避免长名称在固定列宽里被截断。

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var widest: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxWidth), height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x: CGFloat = bounds.minX
        var y: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
