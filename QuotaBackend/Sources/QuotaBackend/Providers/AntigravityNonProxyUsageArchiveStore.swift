import Foundation
import os.log

private let antigravityNonProxyArchiveLog = Logger(subsystem: "com.aiusage.quotabackend", category: "AntigravityNonProxyUsageArchive")

// MARK: - Antigravity Non-Proxy Usage Archive Store
// 非代理轨的「永久每日用量归档」：Antigravity 会话 transcript.jsonl 非代理行只统计 token、成本恒 0，并逐日冻结。
// 账号无关、每个 home 一张（按 homeDirectory 区分以隔离测试 / 多配置）。
//
// 冻结规则：
// - 「今天之前」的日期：首次写入后即冻结，之后改价 / 重扫都不再变动 → 历史不可篡改。
// - 「今天」：仍在累加，每次扫描用当前日志 token 重算并覆盖；跨天后自然冻结。
//
// 持久化:
//   <home>/.config/aiusage/usage-archive/antigravity-non-proxy-usage-v<version>.json

actor AntigravityNonProxyUsageArchiveStore {
    static let artifactVersion = 1

    private var archives: [String: CodexUsageArchive] = [:]
    private var loaded: Set<String> = []

    func needsFullHistoryImport(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    func consumeFullHistoryImportRequest(homeDirectory: String) -> Bool {
        load(homeDirectory).fullHistoryImportedAt == nil
    }

    func freeze(
        homeDirectory: String,
        computed: [String: CodexAggregateBucket],
        todayKey: String,
        completedFullHistory: Bool
    ) -> [String: CodexAggregateBucket] {
        var archive = load(homeDirectory)
        var changed = false

        for (day, bucket) in computed where !bucket.models.isEmpty {
            if day == todayKey {
                archive.days[day] = bucket
                changed = true
            } else if archive.days[day] == nil {
                archive.days[day] = bucket
                changed = true
            }
        }

        if computed[todayKey]?.models.isEmpty != false,
           archive.days.removeValue(forKey: todayKey) != nil {
            changed = true
        }

        if completedFullHistory, archive.fullHistoryImportedAt == nil {
            archive.fullHistoryImportedAt = SharedFormatters.iso8601String(from: Date())
            changed = true
        }

        if changed {
            archive.updatedAt = SharedFormatters.iso8601String(from: Date())
            archives[homeDirectory] = archive
            save(homeDirectory, archive)
        } else {
            archives[homeDirectory] = archive
        }
        return archive.days
    }

    // MARK: - Disk Operations

    private func load(_ homeDirectory: String) -> CodexUsageArchive {
        if let archive = archives[homeDirectory], loaded.contains(homeDirectory) { return archive }
        loaded.insert(homeDirectory)

        let url = Self.fileURL(homeDirectory: homeDirectory)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(CodexUsageArchive.self, from: data),
           decoded.version == Self.artifactVersion {
            archives[homeDirectory] = decoded
            return decoded
        }

        let fresh = CodexUsageArchive(version: Self.artifactVersion, updatedAt: "", days: [:])
        archives[homeDirectory] = fresh
        return fresh
    }

    private func save(_ homeDirectory: String, _ archive: CodexUsageArchive) {
        let normalized = CodexUsageArchive(
            version: Self.artifactVersion,
            updatedAt: archive.updatedAt,
            days: archive.days,
            fullHistoryImportedAt: archive.fullHistoryImportedAt
        )
        let url = Self.fileURL(homeDirectory: homeDirectory)
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(normalized)
            try data.write(to: url, options: .atomic)
        } catch {
            antigravityNonProxyArchiveLog.warning("Failed to save Antigravity non-proxy usage archive: \(String(describing: error), privacy: .public)")
        }
    }

    static func fileURL(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory, isDirectory: true)
            .appendingPathComponent(".config/aiusage/usage-archive/antigravity-non-proxy-usage-v\(artifactVersion).json")
    }
}
