import Foundation

struct AntigravityUsageArchive: Codable, Sendable {
    let version: Int
    var updatedAt: String
    var days: [String: CodexAggregateBucket]
    var fullHistoryImportedAt: String?
    var fileDays: [String: [String: CodexAggregateBucket]]?
}

/// Per-file/day high-water snapshots preserve closed/purged files and reject
/// partial reads without adding a second copy of re-attributed model tokens.
actor AntigravityNonProxyUsageArchiveStore {
    static let artifactVersion = 2
    private var archives: [String: AntigravityUsageArchive] = [:]

    func needsFullHistoryImport(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        needsFullHistoryImport(homeDirectory: homeDirectory)
    }

    func requestFullHistoryImport(homeDirectory: String) throws {
        var archive = load(homeDirectory)
        archive.fullHistoryImportedAt = nil
        try save(homeDirectory, archive)
        archives[homeDirectory] = archive
    }

    func freeze(
        homeDirectory: String,
        computed: [String: CodexAggregateBucket],
        scannedByFile: [String: [String: CodexAggregateBucket]]? = nil,
        todayKey: String,
        completedFullHistory: Bool
    ) throws -> [String: CodexAggregateBucket] {
        var archive = load(homeDirectory)
        var tracked = Self.canonicalize(archive.fileDays ?? [:])
        let oldRepresented = tracked.isEmpty ? computed : Self.aggregate(tracked)
        // Existing v1 or purged historical data not represented by known files
        // remains in the ledger. Never add the whole old day to a full rescan.
        var remainders: [String: CodexAggregateBucket] = [:]
        for (day, bucket) in archive.days {
            let represented = oldRepresented[day] ?? .empty
            let missing = max(0, bucket.totalTokens - represented.totalTokens)
            guard missing > 0 else { continue }
            var remainder = CodexAggregateBucket.empty
            for (name, model) in bucket.models {
                let old = represented.models[name]
                let count = max(0, model.totalTokens - (old?.totalTokens ?? 0))
                guard count > 0 else { continue }
                remainder.models[name] = CodexModelAggregate(model: name, totalTokens: count,
                    inputTokens: max(0, model.inputTokens - (old?.inputTokens ?? 0)),
                    outputTokens: max(0, model.outputTokens - (old?.outputTokens ?? 0)),
                    cacheReadTokens: max(0, model.cacheReadTokens - (old?.cacheReadTokens ?? 0)),
                    cacheCreateTokens: max(0, model.cacheCreateTokens - (old?.cacheCreateTokens ?? 0)), estimatedCostUsd: 0)
                remainder.totalTokens += count
            }
            if remainder.totalTokens != missing {
                let key = "historical-unattributed" + AntigravityCostProvider.nonProxySourceSuffix
                remainder = .empty
                remainder.models[key] = CodexModelAggregate(model: key, totalTokens: missing)
                remainder.totalTokens = missing
            }
            remainder.usageRows = max(0, bucket.usageRows - represented.usageRows)
            remainders[day] = remainder
        }
        for (path, days) in Self.canonicalize(scannedByFile ?? [:]) {
            for (day, bucket) in days where bucket.totalTokens >= (tracked[path]?[day]?.totalTokens ?? 0) {
                tracked[path, default: [:]][day] = bucket
            }
        }
        var days = Self.aggregate(tracked)
        // Keep the legacy API usable for fixture callers without file checkpoints.
        if scannedByFile == nil { days = computed }
        for (day, remainder) in remainders { days[day, default: .empty].merge(remainder) }
        archive.days = days
        archive.fileDays = tracked
        if completedFullHistory, archive.fullHistoryImportedAt == nil {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
        }
        archive.updatedAt = SharedFormatters.iso8601String(from: Date())
        try save(homeDirectory, archive)
        archives[homeDirectory] = archive
        return days
    }

    private static func canonicalize(_ files: [String: [String: CodexAggregateBucket]]) -> [String: [String: CodexAggregateBucket]] {
        var result: [String: [String: CodexAggregateBucket]] = [:]
        for (path, days) in files {
            let key = AntigravityCostProvider.canonicalTranscriptKey(path)
            for (day, bucket) in days where bucket.totalTokens >= (result[key]?[day]?.totalTokens ?? 0) {
                result[key, default: [:]][day] = bucket
            }
        }
        return result
    }

    private static func aggregate(_ files: [String: [String: CodexAggregateBucket]]) -> [String: CodexAggregateBucket] {
        var days: [String: CodexAggregateBucket] = [:]
        for file in files.values {
            for (day, bucket) in file { days[day, default: .empty].merge(bucket) }
        }
        return days
    }

    private func load(_ homeDirectory: String) -> AntigravityUsageArchive {
        if let archive = archives[homeDirectory] { return archive }
        for version in [Self.artifactVersion, 1] {
            if let data = try? Data(contentsOf: Self.fileURL(homeDirectory: homeDirectory, version: version)),
               var archive = try? JSONDecoder().decode(AntigravityUsageArchive.self, from: data),
               archive.version == version {
                if version == 1 || archive.fileDays == nil { archive.fullHistoryImportedAt = nil }
                archive = AntigravityUsageArchive(version: Self.artifactVersion, updatedAt: archive.updatedAt,
                    days: archive.days, fullHistoryImportedAt: archive.fullHistoryImportedAt, fileDays: archive.fileDays)
                archives[homeDirectory] = archive
                return archive
            }
        }
        let archive = AntigravityUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
        archives[homeDirectory] = archive
        return archive
    }

    private func save(_ homeDirectory: String, _ archive: AntigravityUsageArchive) throws {
        let url = Self.fileURL(homeDirectory: homeDirectory)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func fileURL(homeDirectory: String, version: Int = artifactVersion) -> URL {
        URL(fileURLWithPath: homeDirectory).appendingPathComponent(".config/aiusage/usage-archive/antigravity-non-proxy-usage-v\(version).json")
    }
}
