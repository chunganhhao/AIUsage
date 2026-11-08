import Foundation
import SQLite3
@testable import QuotaBackend

@main
struct LocalSidebarAndSessionsRegression {
    private static var passed = 0

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) {
        if condition() {
            passed += 1
        } else {
            fputs("FAIL [\(file):\(line)]: \(message)\n", stderr)
            Foundation.exit(1)
        }
    }

    static func main() throws {
        let home = NSTemporaryDirectory() + "aiusage-agy-sessions-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        try FileManager.default.createDirectory(atPath: home + "/app/Sources", withIntermediateDirectories: true)

        let agyRoot = home + "/.gemini/antigravity"
        let mainID = "22222222-3333-4444-8555-666666666666"
        let subagentID = "99999999-3333-4444-8555-666666666666"
        let mainLogs = agyRoot + "/brain/\(mainID)/.system_generated/logs"
        let subLogs = agyRoot + "/brain/\(subagentID)/.system_generated/logs"
        try FileManager.default.createDirectory(atPath: mainLogs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: subLogs, withIntermediateDirectories: true)

        var db: OpaquePointer?
        check(sqlite3_open(agyRoot + "/conversation_summaries.db", &db) == SQLITE_OK, "open conversation_summaries.db")
        let encodedAppURI = URL(fileURLWithPath: home + "/app").absoluteString
        let createSQL = """
            CREATE TABLE conversation_summaries (
              conversation_id TEXT PRIMARY KEY,
              title TEXT,
              preview TEXT,
              step_count INTEGER,
              last_modified_time TEXT,
              workspace_uris TEXT,
              status TEXT,
              parent_conversation_id TEXT,
              nesting_depth INTEGER,
              not_fully_idle INTEGER
            );
            INSERT INTO conversation_summaries VALUES (
              '\(mainID)', 'AGY session title', 'Preview text', 6,
              '2026-11-08 08:10:00.500000+00:00', '["\(encodedAppURI)"]',
              'CASCADE_RUN_STATUS_RUNNING', '', 0, 1
            );
            INSERT INTO conversation_summaries VALUES (
              '\(subagentID)', 'Subagent task', 'Sub preview', 2,
              '2026-11-08T08:10:00Z', '["\(encodedAppURI)"]',
              'CASCADE_RUN_STATUS_IDLE', '\(mainID)', 1, 0
            );
            """
        check(sqlite3_exec(db, createSQL, nil, nil, nil) == SQLITE_OK, "seed conversation_summaries.db")
        sqlite3_close(db)

        let mainTranscriptPath = mainLogs + "/transcript.jsonl"
        let mainTranscript = """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-08T08:00:00Z","content":"<USER_REQUEST>\\nFix Antigravity session reader\\n</USER_REQUEST>\\n<ADDITIONAL_METADATA>\\nCommand Working Directory: \(home)/app\\n</ADDITIONAL_METADATA>\\n<USER_SETTINGS_CHANGE>\\nModel Selection changed to Claude Opus 4.6 (Thinking). No need to acknowledge.\\n</USER_SETTINGS_CHANGE>"}
            {"step_index":1,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-08T08:01:00Z","content":"Inspecting files.","input_tokens":100,"output_tokens":50,"cache_read_tokens":250,"tool_calls":[{"name":"read_file","args":{"Path":"\(home)/app/Sources/Main.swift"}},{"name":"edit_file","args":{"Path":"\(home)/app/Sources/Main.swift"}},{"name":"run_command","args":{"CommandLine":"swift test"}},{"name":"call_mcp_tool","args":{"ServerName":"engram","ToolName":"mem_context"}}]}
            {"step_index":2,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-11-08T08:01:01Z","content":"Read 20 lines."}
            {"step_index":3,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-11-08T08:01:02Z","content":"Made 1 replacement."}
            {"step_index":4,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-11-08T08:01:03Z","content":"Command exited with code 1.\\nTest suite failed"}
            {"step_index":5,"source":"SYSTEM","type":"GENERIC","status":"DONE","created_at":"2026-11-08T08:01:04Z","content":"{}"}
            {"step_index":6,"source":"SYSTEM","type":"CHECKPOINT","status":"DONE","created_at":"2026-11-08T08:05:00Z","content":""}
            {"step_index":7,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-08T08:06:00Z","content":"All done."}

            """
        try mainTranscript.write(toFile: mainTranscriptPath, atomically: true, encoding: .utf8)
        try """
            {"step_index":0,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-08T08:00:00Z","content":"Subagent prompt"}
            """.write(toFile: subLogs + "/transcript.jsonl", atomically: true, encoding: .utf8)

        let env = SessionEnvironment(homeDirectory: home, variables: [:])
        let catalog = SessionCatalog(environment: env)
        let sessions = catalog.scan()
        check(sessions.map(\.sessionID) == [mainID], "Subagent session excluded; main session listed")

        let session = sessions[0]
        check(session.tool == .antigravity, "SessionTool is .antigravity")
        check(session.tool.displayName == "Antigravity", "DisplayName is Antigravity")
        check(session.title == "AGY session title", "Title loaded from conversation_summaries.db")
        check(session.directory == home + "/app", "Workspace URI decoded to directory path")
        check(session.model == "claude-opus-4.6", "Model parsed from <USER_SETTINGS_CHANGE>")
        check(session.promptCount == 1, "Prompt count is 1")
        check(session.tokens == 400, "Tokens summed from PLANNER_RESPONSE")
        check(session.updatedAt == AntigravitySessionSource.parseDate("2026-11-08 08:10:00.500000+00:00"), "Space-separated SQLite last_modified_time parsed into updatedAt")
        check(session.resumeBlocker == nil, "Existing directory has nil resumeBlocker")
        check(session.matches("fix antigravity"), "Search text matches user prompt")

        // Activity window check
        let source = AntigravitySessionSource(environment: env)
        let activeNow = SessionText.date(iso: "2026-11-08T08:15:00Z")!
        check(source.scan(now: activeNow).first?.activity == .working, "Running session within 30m is .working")
        let expiredNow = activeNow.addingTimeInterval(SessionText.activityWindow + 60)
        check(source.scan(now: expiredNow).first?.activity == nil, "Running session older than 30m expires to nil")

        // Transcript parsing check
        let transcript = try catalog.transcript(for: session)
        let expectedEntries: [TranscriptEntry] = [
            .prompt("Fix Antigravity session reader"),
            .reply("Inspecting files."),
            .steps([
                ToolStep(name: "Read", detail: "Sources/Main.swift", kind: .read, failed: false, failureNote: nil, paths: [home + "/app/Sources/Main.swift"]),
                ToolStep(name: "Edit", detail: "Sources/Main.swift", kind: .edit, failed: false, failureNote: nil, paths: [home + "/app/Sources/Main.swift"]),
                ToolStep(name: "Shell", detail: "swift test", kind: .command, failed: true, failureNote: "Test suite failed", paths: []),
                ToolStep(name: "MCP", detail: "engram · mem_context", kind: .mcp, failed: false, failureNote: nil, paths: [])
            ]),
            .notice(.contextCompacted),
            .reply("All done.")
        ]
        check(transcript.items.map(\.entry) == expectedEntries, "Transcript items match expected prompt/reply/steps/notice")
        check(transcript.stats == TranscriptStats(prompts: 1, toolCalls: 4, failures: 1, filesChanged: 1), "TranscriptStats match")

        // Incremental append check
        let handle = FileHandle(forWritingAtPath: mainTranscriptPath)!
        try handle.seekToEnd()
        let appended = """
            {"step_index":8,"source":"USER_EXPLICIT","type":"USER_INPUT","status":"DONE","created_at":"2026-11-08T08:12:00Z","content":"<USER_REQUEST>\\nSecond question\\n</USER_REQUEST>"}
            {"step_index":9,"source":"MODEL","type":"PLANNER_RESPONSE","status":"DONE","created_at":"2026-11-08T08:12:05Z","content":"Second answer.","input_tokens":20,"output_tokens":30,"cache_read_tokens":50}

            """
        handle.write(Data(appended.utf8))
        try handle.close()

        let rescanned = catalog.scan()[0]
        check(rescanned.promptCount == 2, "Incremental scan updated promptCount to 2")
        check(rescanned.tokens == 500, "Incremental scan updated tokens to 500")
        check(rescanned.matches("second question"), "Incremental scan indexed second prompt")
        let updatedTranscript = try catalog.transcript(for: rescanned)
        check(updatedTranscript.items.last?.entry == .reply("Second answer."), "Incremental transcript appended reply")

        // Full-text search index check
        let indexURL = URL(fileURLWithPath: home + "/cache/search-index.sqlite")
        let index = SessionSearchIndex(url: indexURL, catalog: catalog)
        check(index.update(with: [rescanned]), "FTS5 index updated with Antigravity session")
        let hit = index.search("Inspecting", in: [rescanned])[rescanned.id]
        check(hit?.excerpt?.kind == .reply, "FTS5 search hit Antigravity reply")
        let stepHit = index.search("mem_context", in: [rescanned])[rescanned.id]
        check(stepHit?.excerpt?.kind == .steps, "FTS5 search hit Antigravity MCP step")

        // Monitor relevance check
        let roots = SessionSourceMonitor.Roots(claude: "/h/.claude", codex: "/h/.codex", openCode: "/h/oc", antigravity: "/h/.gemini/antigravity")
        check(SessionSourceMonitor.isRelevant("/h/.gemini/antigravity/conversation_summaries.db-wal", roots: roots), "Monitor watches conversation_summaries.db-wal")
        check(SessionSourceMonitor.isRelevant("/h/.gemini/antigravity/brain/\(mainID)/.system_generated/logs/transcript.jsonl", roots: roots), "Monitor watches transcript.jsonl")
        check(!SessionSourceMonitor.isRelevant("/h/.gemini/antigravity/conversation_summaries.db-shm", roots: roots), "Monitor ignores -shm")
        check(!SessionSourceMonitor.isRelevant("/h/.gemini/antigravity/brain/\(mainID)/scratch/tmp.py", roots: roots), "Monitor ignores scratch files")

        // Resume plan check
        let plan = try SessionResumePlan.make(for: rescanned, homeDirectory: home)
        check(plan.arguments == ["open", "-a", "Antigravity", home + "/app"], "Antigravity SessionResumePlan arguments match")

        print("PASS: \(passed) Antigravity Session Center assertions")
    }
}
