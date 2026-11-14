import XCTest
@testable import QuotaBackend

final class CallAnalyticsEngineTests: XCTestCase {
    func testOpenCodeScanCutoffFullImportReturnsNil() {
        let cutoff = CallAnalyticsEngine.openCodeScanCutoff(
            ledgerNeedsFullImport: true,
            lastSuccessfulScanDate: Date(timeIntervalSince1970: 1_700_000_000),
            fallbackCutoff: Date(timeIntervalSince1970: 1_700_100_000)
        )
        XCTAssertNil(cutoff)
    }

    func testOpenCodeScanCutoffUsesCursorMinusOverlap() {
        let cursor = Date(timeIntervalSince1970: 1_700_000_000)
        let fallback = Date(timeIntervalSince1970: 1_700_100_000)

        let cutoff = CallAnalyticsEngine.openCodeScanCutoff(
            ledgerNeedsFullImport: false,
            lastSuccessfulScanDate: cursor,
            fallbackCutoff: fallback
        )

        XCTAssertEqual(cutoff, cursor.addingTimeInterval(-24 * 3600))
    }

    func testOpenCodeScanCutoffFallsBackWhenNoCursor() {
        let fallback = Date(timeIntervalSince1970: 1_700_100_000)

        let cutoff = CallAnalyticsEngine.openCodeScanCutoff(
            ledgerNeedsFullImport: false,
            lastSuccessfulScanDate: nil,
            fallbackCutoff: fallback
        )

        XCTAssertEqual(cutoff, fallback)
    }

    func testLegacyOpenCodeDroppedWhenLegacyArchiveMigrated() {
        let opencodeBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )
        let claudeBash = CallAnalyticsEntry(
            source: .claude, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )

        let deduped = CallAnalyticsEngine.deduplicateLegacyOpenCode(
            entries: [opencodeBash, claudeBash],
            legacyArchiveMigrated: true
        )

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.source, .claude)
    }

    func testLegacyOpenCodeEntryKeptWhenArchiveNotMigrated() {
        let opencodeBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1
        )

        let deduped = CallAnalyticsEngine.deduplicateLegacyOpenCode(
            entries: [opencodeBash],
            legacyArchiveMigrated: false
        )

        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.source, .opencode)
    }

    func testResidualEntriesPreservesPartialSameDayDeletion() {
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 2, outcomeKnownCount: 2, successCount: 2
        )
        let legacyRead = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "read", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )
        let ledgerBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )

        let residual = CallAnalyticsEngine.residualEntries(
            legacy: [legacyBash, legacyRead],
            ledger: [ledgerBash]
        )

        XCTAssertEqual(residual.count, 2)
        XCTAssertEqual(residual.first(where: { $0.name == "bash" })?.count, 1)
        XCTAssertEqual(residual.first(where: { $0.name == "read" })?.count, 1)
    }

    func testResidualEntriesEmptyWhenFullyOverlapped() {
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )
        let ledgerBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 1, outcomeKnownCount: 1, successCount: 1
        )

        let residual = CallAnalyticsEngine.residualEntries(
            legacy: [legacyBash],
            ledger: [ledgerBash]
        )

        XCTAssertTrue(residual.isEmpty)
    }

    func testResidualEntriesKeepsFullyDeletedEntry() {
        let legacyBash = CallAnalyticsEntry(
            source: .opencode, kind: .builtin, name: "bash", server: nil,
            dayKey: "2026-01-01", count: 2, outcomeKnownCount: 2, successCount: 2
        )

        let residual = CallAnalyticsEngine.residualEntries(
            legacy: [legacyBash],
            ledger: []
        )

        XCTAssertEqual(residual.count, 1)
        XCTAssertEqual(residual.first?.count, 2)
    }

    func testCodexCustomToolCallIgnoresCommentsAndStringLiterals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-calls-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rows = [
            #"{"timestamp":"2026-11-10T03:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"// await tools.mcp__engram__mem_search({query: 'nope'})\ntext('hello')"}}"#,
            #"{"timestamp":"2026-11-10T03:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text(\"tools.mcp__engram__mem_search({})\")"}}"#,
            #"{"timestamp":"2026-11-10T03:00:02Z","type":"response_item","payload":{"type":"custom_tool_call","name":"js_repl","input":"/* tools.mcp__engram__mem_search({}) */ await tools.mcp__engram__mem_search({\"q\":\"ok\"})"}}"#,
            #"{"timestamp":"2026-11-10T03:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const escaped = 'hello'.replace(/'/g, ''); await tools.mcp__engram__mem_context({})"}}"#,
            #"{"timestamp":"2026-11-10T03:00:04Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"if (true) /'/.test(\"x\"); await tools.mcp__engram__mem_context({});"}}"#,
            #"{"timestamp":"2026-11-10T03:00:05Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"if (true) /tools.mcp__engram__mem_context(.*)/.test(\"example\");"}}"#,
            #"{"timestamp":"2026-11-10T03:00:06Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"let i = 2; const ratio = i++ / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:07Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const ratio = {value:2} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:08Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const ratio = function() {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:09Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"switch (1) { case 1: {} /'/.test(\"x\"); await tools.mcp__engram__mem_context({}); break; }"}}"#,
            #"{"timestamp":"2026-11-10T03:00:10Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const arr = [class {}]; const r1 = class extends arr[0] {} / await tools.mcp__engram__mem_context({}) / 2; function F() { return class {}; } const r2 = class extends new F() {} / await tools.mcp__engram__mem_context({}) / 2; const r3 = class extends (function() { return class {}; })() {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:11Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"async function g(y) { const getBase = async () => class {}; const r4 = class extends (await getBase()) {} / await tools.mcp__engram__mem_context({}) / 2; for await (const x of y) /'/.test(x); await tools.mcp__engram__mem_context({}); } const af1 = () => function() {} / await tools.mcp__engram__mem_context({}) / 2; const af2 = () => class {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#
        ].joined(separator: "\n") + "\n"
        try rows.write(to: root.appendingPathComponent(".codex/sessions/day/test.jsonl"), atomically: true, encoding: .utf8)
        let result = CodexCallEventSource(homeDirectory: root.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).collect(cutoff: nil)
        XCTAssertEqual(result.entries.first(where: { $0.kind == .mcp && $0.name == "engram/mem_search" })?.count, 1)
        XCTAssertEqual(result.entries.first(where: { $0.kind == .mcp && $0.name == "engram/mem_context" })?.count, 13)
        XCTAssertEqual(result.entries.first(where: { $0.kind == .builtin && $0.name == "exec" })?.count, 3)
    }

    func testCodexV1ToV2PartialBackfillPreservesDeletedHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-partial-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = "2026-11-09"
        let v1 = CallAnalyticsArchive(
            version: 1,
            updatedAt: "\(day)T12:00:00Z",
            fullHistoryImportedAt: "\(day)T12:00:00Z",
            days: [day: CallAnalyticsDayBucket(entries: [
                CallAnalyticsEntry(source: .codex, kind: .builtin, name: "search_graph", server: nil, dayKey: day, count: 100)
            ], agentInvocations: [])]
        )
        let v1URL = CallAnalyticsArchiveStore.fileURL(homeDirectory: root.path, version: 1)
        try FileManager.default.createDirectory(at: v1URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(v1).write(to: v1URL)
        let line = #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"search_graph","namespace":"mcp__codebase_memory_mcp","arguments":"{}"}}"# + "\n"
        try line.write(to: root.appendingPathComponent(".codex/sessions/day/remaining.jsonl"), atomically: true, encoding: .utf8)
        let snap = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(snap.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count }, 100)
        XCTAssertEqual(CallAnalyticsArchiveStore(homeDirectory: root.path).allDays[day]?.entries.reduce(0) { $0 + $1.count }, 100)
    }

    func testCodexV1CuaReplAliasAndV2RescanPreserveBuiltins() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-cua-v2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "[mcp_servers.computer-use]\ncommand = \"npx\"\n".write(to: root.appendingPathComponent(".codex/config.toml"), atomically: true, encoding: .utf8)
        let cuaDay = "2026-11-09"
        let v1 = CallAnalyticsArchive(
            version: 1,
            updatedAt: "\(cuaDay)T12:00:00Z",
            fullHistoryImportedAt: "\(cuaDay)T12:00:00Z",
            days: [cuaDay: CallAnalyticsDayBucket(entries: [
                CallAnalyticsEntry(source: .codex, kind: .builtin, name: "mcp__cua_repl__js", server: nil, dayKey: cuaDay, count: 3)
            ], agentInvocations: [])]
        )
        let v1URL = CallAnalyticsArchiveStore.fileURL(homeDirectory: root.path, version: 1)
        try FileManager.default.createDirectory(at: v1URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(v1).write(to: v1URL)
        let cuaLine = #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"js","namespace":"mcp__cua_repl","arguments":"{}"}}"# + "\n"
        try cuaLine.write(to: root.appendingPathComponent(".codex/sessions/day/cua.jsonl"), atomically: true, encoding: .utf8)
        let snap1 = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(snap1.entries.filter { $0.source == .codex && $0.kind == .mcp }.count, 1)
        XCTAssertEqual(snap1.entries.first(where: { $0.name == "computer-use/js" })?.count, 3)

        // Add genuine v2 builtin `exec` on an earlier day and rescan with new `.mcp` `engram/exec`
        let day2 = "2026-11-08"
        let v2URL = CallAnalyticsArchiveStore.fileURL(homeDirectory: root.path, version: 2)
        var v2Archive = try JSONDecoder().decode(CallAnalyticsArchive.self, from: Data(contentsOf: v2URL))
        v2Archive.days[day2] = CallAnalyticsDayBucket(entries: [
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "exec", server: nil, dayKey: day2, count: 5)
        ], agentInvocations: [])
        try JSONEncoder().encode(v2Archive).write(to: v2URL)
        let execLine = #"{"timestamp":"2026-11-08T03:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__engram__exec({})"}}"# + "\n"
        try execLine.write(to: root.appendingPathComponent(".codex/sessions/day/exec.jsonl"), atomically: true, encoding: .utf8)
        let rescanSnap = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil, rescan: true)
        XCTAssertEqual(rescanSnap.entries.first(where: { $0.kind == .builtin && $0.name == "exec" })?.count, 5)
        XCTAssertEqual(rescanSnap.entries.first(where: { $0.kind == .mcp && $0.name == "engram/exec" })?.count, 1)
    }

    func testCodexV1MigrationPreservesGenuineBuiltinsOnWrapperMCPCollision() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-v1-wrapper-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".codex/sessions/day"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let day = "2026-11-09"
        let v1 = CallAnalyticsArchive(
            version: 1,
            updatedAt: "\(day)T12:00:00Z",
            fullHistoryImportedAt: "\(day)T12:00:00Z",
            days: [day: CallAnalyticsDayBucket(entries: [
                CallAnalyticsEntry(source: .codex, kind: .builtin, name: "exec_command", server: nil, dayKey: day, count: 5)
            ], agentInvocations: [])]
        )
        let v1URL = CallAnalyticsArchiveStore.fileURL(homeDirectory: root.path, version: 1)
        try FileManager.default.createDirectory(at: v1URL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(v1).write(to: v1URL)
        let lines = [
            #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__terminal__exec_command({})"}}"#,
            #"{"timestamp":"2026-11-09T03:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__terminal__exec_command({})"}}"#
        ].joined(separator: "\n") + "\n"
        try lines.write(to: root.appendingPathComponent(".codex/sessions/day/remaining.jsonl"), atomically: true, encoding: .utf8)
        let snap = await CallAnalyticsEngine(homeDirectory: root.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        XCTAssertEqual(snap.entries.first(where: { $0.kind == .builtin && $0.name == "exec_command" })?.count, 5)
        XCTAssertEqual(snap.entries.first(where: { $0.kind == .mcp && $0.name == "terminal/exec_command" })?.count, 2)
        XCTAssertEqual(CallAnalyticsArchiveStore(homeDirectory: root.path).allDays[day]?.entries.reduce(0) { $0 + $1.count }, 7)
    }
}
