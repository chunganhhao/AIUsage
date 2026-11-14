import Foundation
import os.log

private let callAnalyticsArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "CallAnalyticsArchive")

// MARK: - Call Analytics Archive Store
// 「调用分析」的永久每日冻结归档：解决「agent 删除 session 后历史调用统计被清空」（issue #32）。
// 调用分析的事件源是本地会话日志（Claude jsonl / Codex jsonl / opencode.db），删 session 即丢源。
// 早期设计判断「无成本冻结需求」故只做整份可重建的缓存（见 CALL_ANALYTICS_DESIGN.md §6），
// 但这意味着删 session 后重扫条目变少、缓存被整份覆盖，历史 MCP/技能/工具调用统计随之丢失。
// 本归档复刻用量归档（OpenCodeUsageArchiveStore / CodexNonProxyUsageArchiveStore）的冻结语义：
// - 「今天之前」的日期：首次写入后即冻结，之后重扫/删 session 都不再变动 → 历史不可篡改、删库不丢账。
// - 「今天」：仍在累加，每次扫描用当前会话重算并覆盖；跨天后自然冻结。
// - 首次启动做一次「全量历史导入」（扫全历史冻结所有过去日），之后只扫请求窗口即可。
//
// 持久化（永久、放 ~/.config/aiusage 避免被系统在磁盘紧张时清理）:
//   <home>/.config/aiusage/usage-archive/call-analytics-archive-v<version>.json
//
// 线程：本类仅由 CallAnalyticsEngine（actor）持有并访问，故无需自身做锁——访问被引擎 actor 串行化。

/// 一天的冻结调用数据：该日全部归一化条目 + 该日各 agent 的被调用次数。
struct CallAnalyticsDayBucket: Codable, Sendable {
    var entries: [CallAnalyticsEntry]
    var agentInvocations: [AgentInvocationCount]

    static let empty = CallAnalyticsDayBucket(entries: [], agentInvocations: [])

    var isEmpty: Bool { entries.isEmpty && agentInvocations.isEmpty }
}

struct CallAnalyticsArchive: Codable, Sendable {
    var version: Int
    var updatedAt: String
    /// 全量历史导入完成时间（ISO8601）。非空 = 已做过一次全历史冻结，之后只扫窗口。
    var fullHistoryImportedAt: String?
    var days: [String: CallAnalyticsDayBucket]
}

final class CallAnalyticsArchiveStore {
    static let artifactVersion = 2

    private let homeDirectory: String
    private var cached: CallAnalyticsArchive?

    init(homeDirectory: String) {
        self.homeDirectory = homeDirectory
    }

    /// 是否已完成全量历史导入。false → 引擎应先扫全历史以冻结所有过去日。
    var fullHistoryImported: Bool {
        load().fullHistoryImportedAt != nil
    }

    var allDays: [String: CallAnalyticsDayBucket] { load().days }

    /// 冻结合并：past(<today) 仅在缺失时首次写入；today 每次覆盖重算；已冻结的 past 保持不动。
    /// 返回合并后的全部归档日，供引擎按请求范围裁剪展示。
    func freeze(
        computed: [String: CallAnalyticsDayBucket],
        todayKey: String,
        completedFullHistory: Bool,
        backfill: Bool = false
    ) -> [String: CallAnalyticsDayBucket] {
        var archive = load()
        let isLegacyV1Migration = (archive.fullHistoryImportedAt == nil)
        var changed = false

        for (day, bucket) in computed where !bucket.isEmpty {
            if day == todayKey {
                var cleanBucket = bucket
                for i in cleanBucket.entries.indices {
                    cleanBucket.entries[i].reclassifiedBuiltinCount = 0
                }
                archive.days[day] = cleanBucket
                changed = true
            } else if backfill, var previous = archive.days[day] {
                // Backfill missing calls without deleting history whose source sessions were removed.
                previous = Self.migratedV1DayBucket(previous)
                for entry in bucket.entries {
                    let addedCount: Int
                    var cleanedEntry = entry
                    cleanedEntry.reclassifiedBuiltinCount = 0
                    if let index = previous.entries.firstIndex(where: { Self.matchesBackfillEntry($0, cleanedEntry) }) {
                        let existing = previous.entries[index]
                        addedCount = max(0, cleanedEntry.count - existing.count)
                        var merged = cleanedEntry
                        merged.count = max(cleanedEntry.count, existing.count)
                        merged.outcomeKnownCount = min(merged.count, max(cleanedEntry.outcomeKnownCount, existing.outcomeKnownCount))
                        merged.successCount = min(merged.outcomeKnownCount, max(cleanedEntry.successCount, existing.successCount))
                        merged.durationSampleCount = min(merged.count, max(cleanedEntry.durationSampleCount, existing.durationSampleCount))
                        merged.durationMsTotal = max(cleanedEntry.durationMsTotal, existing.durationMsTotal)
                        previous.entries[index] = merged
                    } else {
                        addedCount = cleanedEntry.count
                        previous.entries.append(cleanedEntry)
                    }
                    let deductCount = min(addedCount, entry.reclassifiedBuiltinCount)
                    if isLegacyV1Migration,
                       cleanedEntry.source == .codex, cleanedEntry.kind == .mcp, deductCount > 0,
                       let toolName = cleanedEntry.name.split(separator: "/", maxSplits: 1).last.map(String.init),
                       !toolName.isEmpty {
                        Self.deductSupersededLegacyCodexBuiltin(
                            toolName: toolName,
                            agent: cleanedEntry.agent,
                            count: deductCount,
                            from: &previous.entries
                        )
                    }
                }
                archive.days[day] = previous
                changed = true
            } else if archive.days[day] == nil {
                var cleanBucket = bucket
                for i in cleanBucket.entries.indices {
                    cleanBucket.entries[i].reclassifiedBuiltinCount = 0
                }
                archive.days[day] = cleanBucket
                changed = true
            }
        }

        // 今天若重算为空（当天调用被全部删除）且归档里有今天 → 移除，避免显示陈旧的今天数据。
        if (computed[todayKey]?.isEmpty ?? true), archive.days.removeValue(forKey: todayKey) != nil {
            changed = true
        }

        if completedFullHistory, archive.fullHistoryImportedAt == nil {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            cached = archive
            save(archive)
        } else {
            cached = archive
        }
        return archive.days
    }

    // MARK: - Disk

    private func load() -> CallAnalyticsArchive {
        if let cached { return cached }

        if let data = try? Data(contentsOf: Self.fileURL(homeDirectory: homeDirectory, version: Self.artifactVersion)),
           let decoded = try? JSONDecoder().decode(CallAnalyticsArchive.self, from: data),
           decoded.version == Self.artifactVersion {
            cached = decoded
            return decoded
        }

        // Migrate v1 -> v2: retain existing historical days (for deleted sessions), upgrading legacy
        // Codex `mcp__...` builtins to `.mcp` and resetting fullHistoryImportedAt for backfill.
        if let v1Data = try? Data(contentsOf: Self.fileURL(homeDirectory: homeDirectory, version: 1)),
           let decodedV1 = try? JSONDecoder().decode(CallAnalyticsArchive.self, from: v1Data) {
            let seeded = CallAnalyticsArchive(
                version: Self.artifactVersion,
                updatedAt: decodedV1.updatedAt,
                fullHistoryImportedAt: nil,
                days: decodedV1.days.mapValues(Self.migratedV1DayBucket)
            )
            cached = seeded
            return seeded
        }

        let fresh = CallAnalyticsArchive(version: Self.artifactVersion, updatedAt: "", fullHistoryImportedAt: nil, days: [:])
        cached = fresh
        return fresh
    }

    private static func canonicalCodexServer(_ raw: String?) -> String {
        let normalized = (raw ?? "").replacingOccurrences(of: "-", with: "_")
        return normalized == "cua_repl" ? "computer_use" : normalized
    }

    private static func matchesBackfillEntry(_ existing: CallAnalyticsEntry, _ incoming: CallAnalyticsEntry) -> Bool {
        if existing.source == incoming.source,
           existing.kind == incoming.kind,
           existing.name == incoming.name,
           existing.server == incoming.server,
           existing.agent == incoming.agent {
            return true
        }
        guard existing.source == .codex, incoming.source == .codex,
              existing.kind == .mcp, incoming.kind == .mcp,
              existing.agent == incoming.agent else {
            return false
        }
        let existingTool = existing.name.split(separator: "/", maxSplits: 1).last
        let incomingTool = incoming.name.split(separator: "/", maxSplits: 1).last
        guard let existingTool, let incomingTool, existingTool == incomingTool else {
            return false
        }
        let existingServer = canonicalCodexServer(existing.server)
        let incomingServer = canonicalCodexServer(incoming.server)
        return !existingServer.isEmpty && existingServer == incomingServer
    }

    private static func deductSupersededLegacyCodexBuiltin(
        toolName: String,
        agent: String?,
        count: Int,
        from entries: inout [CallAnalyticsEntry]
    ) {
        var remainingToDeduct = count
        var idx = 0
        while idx < entries.count && remainingToDeduct > 0 {
            let candidate = entries[idx]
            if candidate.source == .codex,
               candidate.kind == .builtin,
               candidate.name == toolName,
               candidate.agent == agent {
                let deducted = min(candidate.count, remainingToDeduct)
                let newCount = candidate.count - deducted
                remainingToDeduct -= deducted
                if newCount > 0 {
                    var updated = candidate
                    updated.count = newCount
                    updated.outcomeKnownCount = min(candidate.outcomeKnownCount, newCount)
                    updated.successCount = min(candidate.successCount, updated.outcomeKnownCount)
                    updated.durationSampleCount = min(candidate.durationSampleCount, newCount)
                    entries[idx] = updated
                    idx += 1
                } else {
                    entries.remove(at: idx)
                }
            } else {
                idx += 1
            }
        }
    }

    private static func migratedV1DayBucket(_ bucket: CallAnalyticsDayBucket) -> CallAnalyticsDayBucket {
        var migratedEntries: [CallAnalyticsEntry] = []
        for entry in bucket.entries {
            let normalized: CallAnalyticsEntry
            if entry.source == .codex,
               entry.kind == .builtin,
               let mcp = CallAnalyticsNaming.parseClaudeMCP(entry.name) {
                normalized = CallAnalyticsEntry(
                    source: entry.source,
                    kind: .mcp,
                    name: CallAnalyticsNaming.mcpDisplayName(server: mcp.server, tool: mcp.tool),
                    server: mcp.server,
                    agent: entry.agent,
                    dayKey: entry.dayKey,
                    count: entry.count,
                    outcomeKnownCount: entry.outcomeKnownCount,
                    successCount: entry.successCount,
                    durationSampleCount: entry.durationSampleCount,
                    durationMsTotal: entry.durationMsTotal
                )
            } else {
                normalized = entry
            }
            if let idx = migratedEntries.firstIndex(where: {
                $0.source == normalized.source && $0.kind == normalized.kind
                    && $0.name == normalized.name && $0.server == normalized.server && $0.agent == normalized.agent
            }) {
                migratedEntries[idx].count += normalized.count
                migratedEntries[idx].outcomeKnownCount += normalized.outcomeKnownCount
                migratedEntries[idx].successCount += normalized.successCount
                migratedEntries[idx].durationSampleCount += normalized.durationSampleCount
                migratedEntries[idx].durationMsTotal += normalized.durationMsTotal
            } else {
                migratedEntries.append(normalized)
            }
        }
        return CallAnalyticsDayBucket(entries: migratedEntries, agentInvocations: bucket.agentInvocations)
    }

    private func save(_ archive: CallAnalyticsArchive) {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(archive)
            try data.write(to: url, options: .atomic)
        } catch {
            callAnalyticsArchiveLog.warning("Failed to save call analytics archive: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String, version: Int = artifactVersion) -> URL {
        let dir = (homeDirectory as NSString).appendingPathComponent(".config/aiusage/usage-archive")
        return URL(fileURLWithPath: dir, isDirectory: true)
            .appendingPathComponent("call-analytics-archive-v\(version).json")
    }
}
