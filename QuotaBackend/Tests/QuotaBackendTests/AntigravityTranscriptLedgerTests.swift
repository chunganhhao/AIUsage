import XCTest
@testable import QuotaBackend

final class AntigravityTranscriptLedgerTests: XCTestCase {
    private func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("antigravity-ledger-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func bucket(_ count: Int, model: String = "gemini-4-argon (Non-Proxy)") -> CodexAggregateBucket {
        var result = CodexAggregateBucket.empty
        result.totalTokens = count
        result.usageRows = 1
        result.models[model] = CodexModelAggregate(model: model, totalTokens: count, inputTokens: count)
        return result
    }

    private func line(_ type: String, content: String? = nil, tokens: Int? = nil) throws -> String {
        var json: [String: Any] = ["type": type, "created_at": SharedFormatters.iso8601String(from: Date())]
        if let content { json["content"] = content }
        if let tokens { json["input_tokens"] = tokens; json["output_tokens"] = 0 }
        return String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self)
    }

    func testModelSelectionOnlyComesFromStructuredUserEvents() throws {
        let change = "<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 4 Argon (Medium). No need to acknowledge this change.\n</USER_SETTINGS_CHANGE>"
        XCTAssertEqual(AntigravityCostProvider.extractSelectedModel(from: try line("USER_INPUT", content: change)), "gemini-4-argon")
        XCTAssertNil(AntigravityCostProvider.extractSelectedModel(from: try line("PLANNER_RESPONSE", content: change)))
        XCTAssertEqual(AntigravityCostProvider.normalizeSelectedModelName("Future Model 9 (High)"), "future-model-9")
    }

    func testCanonicalSnapshotsPartialReadsAndGrowthAreNotDoubleCounted() async throws {
        let root = try home()
        let logs = root.appendingPathComponent(".gemini/antigravity/brain/fixture/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let selected = try line("USER_INPUT", content: "<USER_SETTINGS_CHANGE>Model Selection from None to Gemini 4 Argon (Medium). No need</USER_SETTINGS_CHANGE>")
        let full = logs.appendingPathComponent("transcript_full.jsonl")
        let normal = logs.appendingPathComponent("transcript.jsonl")
        try Data((selected + "\n" + line("PLANNER_RESPONSE", tokens: 100) + "\n").utf8).write(to: full)
        try Data((selected + "\n" + line("PLANNER_RESPONSE", tokens: 50) + "\n").utf8).write(to: normal)
        let provider = AntigravityCostProvider(homeDirectory: root.path, timeZone: TimeZone(secondsFromGMT: 0)!)
        let first = try await provider.fetchUsage()
        XCTAssertEqual(first.extra["overall.totalTokens"]?.value as? Int, 100)
        XCTAssertEqual(first.extra["overall.sessionCount"]?.value as? Int, 1)
        XCTAssertNil(first.extra["overall.proxy.totalTokens"])
        try Data("{partial".utf8).write(to: normal)
        let partial = try await provider.fetchUsage()
        XCTAssertEqual(partial.extra["overall.totalTokens"]?.value as? Int, 100)
        try Data((selected + "\n" + line("PLANNER_RESPONSE", tokens: 150) + "\n").utf8).write(to: normal)
        let grown = try await provider.fetchUsage()
        XCTAssertEqual(grown.extra["overall.totalTokens"]?.value as? Int, 150)
        XCTAssertEqual(grown.extra["overall.estimatedCostUsd"]?.value as? Double, 0)
        let summary = UsageNormalizer.normalize(provider: provider, usage: grown)
        XCTAssertEqual(summary.headline.secondary, "Antigravity transcript tokens this month")
    }

    func testReattributionReplacesCheckpointInsteadOfAddingTokens() async throws {
        let root = try home(); let store = AntigravityNonProxyUsageArchiveStore()
        let old = bucket(100, model: "old (Non-Proxy)")
        _ = try await store.freeze(homeDirectory: root.path, computed: ["2026-10-01": old], scannedByFile: ["conversation/transcript.jsonl": ["2026-10-01": old]], todayKey: "2026-10-26", completedFullHistory: true)
        let next = bucket(150, model: "new (Non-Proxy)")
        let grown = try await store.freeze(homeDirectory: root.path, computed: ["2026-10-01": next], scannedByFile: ["conversation/transcript_full.jsonl": ["2026-10-01": next]], todayKey: "2026-10-26", completedFullHistory: false)
        XCTAssertEqual(grown["2026-10-01"]?.totalTokens, 150)
        XCTAssertNil(grown["2026-10-01"]?.models["old (Non-Proxy)"])
        let partial = bucket(120)
        let kept = try await store.freeze(homeDirectory: root.path, computed: ["2026-10-01": partial], scannedByFile: ["conversation/transcript.jsonl": ["2026-10-01": partial]], todayKey: "2026-10-26", completedFullHistory: false)
        XCTAssertEqual(kept["2026-10-01"]?.totalTokens, 150)
        let reloaded = AntigravityNonProxyUsageArchiveStore()
        let persisted = try await reloaded.freeze(homeDirectory: root.path, computed: [:], scannedByFile: [:], todayKey: "2026-10-27", completedFullHistory: false)
        XCTAssertEqual(persisted["2026-10-01"]?.totalTokens, 150)
    }

    func testV1MigrationPreservesPurgedHistoryWithoutAddingRescanTwice() async throws {
        let root = try home(); var old = bucket(100, model: "live (Non-Proxy)")
        old.merge(bucket(100, model: "purged (Non-Proxy)"))
        let url = AntigravityNonProxyUsageArchiveStore.fileURL(homeDirectory: root.path, version: 1)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(AntigravityUsageArchive(version: 1, updatedAt: "", days: ["2026-10-01": old])).write(to: url)
        let store = AntigravityNonProxyUsageArchiveStore(); let scan = bucket(100, model: "live (Non-Proxy)")
        let migrated = try await store.freeze(homeDirectory: root.path, computed: ["2026-10-01": scan], scannedByFile: ["file": ["2026-10-01": scan]], todayKey: "2026-10-26", completedFullHistory: true)
        XCTAssertEqual(migrated["2026-10-01"]?.totalTokens, 200)
        let growth = bucket(150, model: "live (Non-Proxy)")
        let grown = try await store.freeze(homeDirectory: root.path, computed: ["2026-10-01": growth], scannedByFile: ["file": ["2026-10-01": growth]], todayKey: "2026-10-26", completedFullHistory: false)
        XCTAssertEqual(grown["2026-10-01"]?.totalTokens, 250)
        let unscanned = try await store.freeze(homeDirectory: root.path, computed: [:], scannedByFile: [:], todayKey: "2026-10-27", completedFullHistory: false)
        XCTAssertEqual(unscanned["2026-10-01"]?.totalTokens, 250)
    }

    func testV1MigrationPreservesPurgedModelWhenFirstRescanAlreadyGrew() async throws {
        for currentCount in [150, 200, 250] {
            let root = try home()
            var old = bucket(100, model: "live (Non-Proxy)")
            old.merge(bucket(100, model: "purged (Non-Proxy)"))
            let url = AntigravityNonProxyUsageArchiveStore.fileURL(homeDirectory: root.path, version: 1)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(AntigravityUsageArchive(version: 1, updatedAt: "", days: ["2026-10-01": old])).write(to: url)
            let store = AntigravityNonProxyUsageArchiveStore()
            let scan = bucket(currentCount, model: "live (Non-Proxy)")
            let migrated = try await store.freeze(homeDirectory: root.path, computed: ["2026-10-01": scan], scannedByFile: ["file": ["2026-10-01": scan]], todayKey: "2026-10-26", completedFullHistory: true)
            XCTAssertEqual(migrated["2026-10-01"]?.totalTokens, currentCount + 100)
            XCTAssertEqual(migrated["2026-10-01"]?.models["purged (Non-Proxy)"]?.totalTokens, 100)
            XCTAssertEqual(migrated["2026-10-01"]?.models["purged (Non-Proxy)"]?.inputTokens, 100)
            let reloaded = AntigravityNonProxyUsageArchiveStore()
            let unscanned = try await reloaded.freeze(homeDirectory: root.path, computed: [:], scannedByFile: [:], todayKey: "2026-10-27", completedFullHistory: false)
            XCTAssertEqual(unscanned["2026-10-01"]?.totalTokens, currentCount + 100)
        }
    }

    func testFullHistoryRequestAndPersistenceFailureAreVisible() async throws {
        let root = try home(); let store = AntigravityNonProxyUsageArchiveStore()
        _ = try await store.freeze(homeDirectory: root.path, computed: [:], scannedByFile: [:], todayKey: "2026-10-26", completedFullHistory: true)
        let before = await store.needsFullHistoryImport(homeDirectory: root.path)
        XCTAssertFalse(before)
        try await store.requestFullHistoryImport(homeDirectory: root.path)
        let requested = await store.needsFullHistoryImport(homeDirectory: root.path)
        XCTAssertTrue(requested)
        let blocked = try home(); try Data().write(to: blocked.appendingPathComponent(".config"))
        do {
            _ = try await store.freeze(homeDirectory: blocked.path, computed: [:], scannedByFile: [:], todayKey: "2026-10-26", completedFullHistory: true)
            XCTFail("Expected persistence failure")
        } catch { }
    }

    func testFailedInitialTranscriptReadRemainsPendingAndRetriesOldFiles() async throws {
        let root = try home()
        let logs = root.appendingPathComponent(".gemini/antigravity/brain/old/.system_generated/logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appendingPathComponent("transcript.jsonl")
        let oldDate = Date().addingTimeInterval(-10 * 86400)
        try Data([0xff]).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let provider = AntigravityCostProvider(homeDirectory: root.path)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("Unreadable transcript must fail the import")
        } catch { }
        let pending = await provider.needsFullHistoryImport()
        XCTAssertTrue(pending)

        try Data((line("PLANNER_RESPONSE", tokens: 777) + "\n").utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: file.path)
        let retried = try await provider.fetchUsage()
        XCTAssertEqual(retried.extra["overall.totalTokens"]?.value as? Int, 777)
        let completed = await provider.needsFullHistoryImport()
        XCTAssertFalse(completed)
    }

    func testUnreadableDirectoryDoesNotCompleteHistoryImport() async throws {
        let root = try home()
        let brain = root.appendingPathComponent(".gemini/antigravity/brain")
        try FileManager.default.createDirectory(at: brain, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: brain.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: brain.path) }
        let provider = AntigravityCostProvider(homeDirectory: root.path)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Unreadable directory must fail the import")
        } catch { }
        let pending = await provider.needsFullHistoryImport()
        XCTAssertTrue(pending)
    }

    func testHistoricalSessionCountSurvivesIncrementalScansAndPurgedFiles() async throws {
        let root = try home()
        func transcript(_ conversation: String, tokens: Int, old: Bool) throws -> URL {
            let logs = root.appendingPathComponent(".gemini/antigravity/brain/\(conversation)/.system_generated/logs")
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let file = logs.appendingPathComponent("transcript.jsonl")
            try Data((line("PLANNER_RESPONSE", tokens: tokens) + "\n").utf8).write(to: file)
            if old {
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-10 * 86400)], ofItemAtPath: file.path)
            }
            return file
        }
        let oldFile = try transcript("old", tokens: 100, old: true)
        let recentFile = try transcript("recent", tokens: 200, old: false)
        let fullFile = recentFile.deletingLastPathComponent().appendingPathComponent("transcript_full.jsonl")
        try FileManager.default.copyItem(at: recentFile, to: fullFile)
        let provider = AntigravityCostProvider(homeDirectory: root.path)
        let initial = try await provider.fetchUsage()
        XCTAssertEqual(initial.extra["overall.sessionCount"]?.value as? Int, 2)
        XCTAssertEqual(initial.extra["overall.totalTokens"]?.value as? Int, 300)

        let incremental = try await provider.fetchUsage()
        XCTAssertEqual(incremental.extra["overall.sessionCount"]?.value as? Int, 2)
        try FileManager.default.removeItem(at: oldFile)
        let purged = try await provider.fetchUsage()
        XCTAssertEqual(purged.extra["overall.sessionCount"]?.value as? Int, 2)
        XCTAssertEqual(purged.extra["overall.totalTokens"]?.value as? Int, 300)
        let reloaded = AntigravityNonProxyUsageArchiveStore()
        let count = await reloaded.sessionCount(homeDirectory: root.path)
        XCTAssertEqual(count, 2)
    }
}
