import Foundation
#if canImport(Darwin)
import Darwin
#endif

// Token-only ledger from local Antigravity transcripts. No proxy archive or pricing writer.

public struct AntigravityCostProvider: ProviderFetcher {
    public let id = "antigravity-cost"
    public let displayName = "Antigravity"
    public let description = "Token-only Antigravity transcript ledger"

    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    static let nonProxyArchive = AntigravityNonProxyUsageArchiveStore()

    public func requestFullHistoryImport() async {
        try? await Self.nonProxyArchive.requestFullHistoryImport(homeDirectory: homeDirectory)
    }

    public func needsFullHistoryImport() async -> Bool {
        await Self.nonProxyArchive.needsFullHistoryImport(homeDirectory: homeDirectory)
    }

    public init(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeZone: TimeZone = .current,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.homeDirectory = homeDirectory
        self.timeZone = timeZone
        self.environment = environment
    }

    public func fetchUsage() async throws -> ProviderUsage {
        let now = Date()
        let todayKey = dayKey(now)

        let shouldImportFullHistory = await Self.nonProxyArchive.consumeFullHistoryImportRequest(homeDirectory: homeDirectory)
        let scanWindowCutoff: Date? = shouldImportFullHistory ? nil : calendar().date(byAdding: .day, value: -1, to: calendar().startOfDay(for: now))

        let brainDir = resolveBrainDirectory()
        let files = try brainDir.map { try collectTranscriptFiles(brainDirectory: $0, scanWindowCutoff: scanWindowCutoff) } ?? []

        // 任一读取失败均不提交本轮快照，也不把未完成的历史导入标记为成功。
        let scannedByFile = try scanFilesByPath(files)
        var computedNonProxy: [String: CodexAggregateBucket] = [:]
        for fileBuckets in scannedByFile.values {
            for (dKey, bucket) in fileBuckets {
                computedNonProxy[dKey, default: .empty].merge(bucket)
            }
        }

        let nonProxyDays = try await Self.nonProxyArchive.freeze(
            homeDirectory: homeDirectory,
            computed: computedNonProxy,
            scannedByFile: scannedByFile,
            todayKey: todayKey,
            completedFullHistory: shouldImportFullHistory && brainDir != nil
        )

        let combined = nonProxyDays
        guard !combined.isEmpty else {
            throw ProviderError("no_usage_data", "No Antigravity transcript token usage recorded")
        }

        let weekRangeInfo = weekRange(now)
        let monthKey = monthKeyStr(now)

        let today = combined[todayKey] ?? .empty
        let currentWeek = aggregateDays(combined) { weekRangeInfo.dayKeys.contains($0) }
        let currentMonth = aggregateDays(combined) { $0.hasPrefix(monthKey) }
        let overall = aggregateDays(combined) { _ in true }

        let archiveDayCount = max(combined.count, 182) // 26 weeks for heatmap
        let overallRangeLabel = "All history"

        var extra: [String: AnyCodable] = [:]
        extra["today.estimatedCostUsd"] = AnyCodable(roundUsd(today.estimatedCostUsd))
        extra["today.totalTokens"] = AnyCodable(today.totalTokens)
        extra["today.key"] = AnyCodable(todayKey)

        extra["currentWeek.estimatedCostUsd"] = AnyCodable(roundUsd(currentWeek.estimatedCostUsd))
        extra["currentWeek.totalTokens"] = AnyCodable(currentWeek.totalTokens)
        extra["currentWeek.key"] = AnyCodable("\(weekRangeInfo.start)..\(weekRangeInfo.end)")

        extra["currentMonth.estimatedCostUsd"] = AnyCodable(roundUsd(currentMonth.estimatedCostUsd))
        extra["currentMonth.totalTokens"] = AnyCodable(currentMonth.totalTokens)
        extra["currentMonth.key"] = AnyCodable(monthKey)

        extra["timeline.hourly"] = AnyCodable([AnyCodable]())
        extra["timeline.daily"] = AnyCodable(encodeTimeline(trailingDailyTimeline(bucketsByDay: combined, now: now, dayCount: archiveDayCount)))

        extra["overall.estimatedCostUsd"] = AnyCodable(roundUsd(overall.estimatedCostUsd))
        extra["overall.totalTokens"] = AnyCodable(overall.totalTokens)
        extra["overall.usageRows"] = AnyCodable(overall.usageRows)
        extra["overall.rangeLabel"] = AnyCodable(overallRangeLabel)
        let sessionCount = await Self.nonProxyArchive.sessionCount(homeDirectory: homeDirectory)
        extra["overall.sessionCount"] = AnyCodable(sessionCount)

        func encodeModelBreakdown(_ agg: CodexAggregateBucket) -> [AnyCodable] {
            let sorted = agg.models.values.sorted {
                if $0.estimatedCostUsd != $1.estimatedCostUsd { return $0.estimatedCostUsd > $1.estimatedCostUsd }
                return $0.totalTokens > $1.totalTokens
            }
            let totalCost = agg.estimatedCostUsd
            let totalTokens = agg.totalTokens
            return sorted.map { model -> AnyCodable in
                let pct = totalCost > 0
                    ? roundUsd(model.estimatedCostUsd / totalCost * 100)
                    : (totalTokens > 0 ? roundUsd(Double(model.totalTokens) / Double(totalTokens) * 100) : 0)
                return AnyCodable([
                    "model": AnyCodable(model.model),
                    "totalTokens": AnyCodable(model.totalTokens),
                    "inputTokens": AnyCodable(model.inputTokens),
                    "outputTokens": AnyCodable(model.outputTokens),
                    "cacheReadTokens": AnyCodable(model.cacheReadTokens),
                    "cacheCreateTokens": AnyCodable(model.cacheCreateTokens),
                    "estimatedCostUsd": AnyCodable(roundUsd(model.estimatedCostUsd)),
                    "estimatedCostDisplay": AnyCodable(formatCurrency(roundUsd(model.estimatedCostUsd))),
                    "percentage": AnyCodable(pct)
                ] as [String: AnyCodable])
            }
        }

        extra["currentMonth.models"] = AnyCodable(encodeModelBreakdown(currentMonth))
        extra["today.models"] = AnyCodable(encodeModelBreakdown(today))
        extra["currentWeek.models"] = AnyCodable(encodeModelBreakdown(currentWeek))
        extra["overall.models"] = AnyCodable(encodeModelBreakdown(overall))

        var modelTimelines: [AnyCodable] = []
        let archivedModelNames = Set(combined.values.flatMap { $0.models.keys })
        for modelName in archivedModelNames.sorted() {
            let daily = trailingDailyTimeline(bucketsByDay: combined, now: now, dayCount: archiveDayCount, model: modelName)
            guard !daily.isEmpty else { continue }
            modelTimelines.append(AnyCodable([
                "model": AnyCodable(modelName),
                "hourly": AnyCodable([AnyCodable]()),
                "daily": AnyCodable(encodeTimeline(daily, includeDetail: true))
            ] as [String: AnyCodable]))
        }
        extra["timeline.byModel"] = AnyCodable(modelTimelines)

        var usage = ProviderUsage(provider: id, label: displayName, extra: extra)
        var source = SourceInfo(mode: "auto", type: "antigravity-transcripts")
        if let brainDir {
            source.roots = [brainDir]
        }
        usage.source = source
        return usage
    }
}
