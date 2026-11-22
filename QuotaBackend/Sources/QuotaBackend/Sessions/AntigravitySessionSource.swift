import Darwin
import Foundation

// MARK: - Session Center · Antigravity
// 数据来源：$ANTIGRAVITY_HOME 或 ~/.gemini/antigravity 下的 conversation_summaries.db 与
// brain/<conversation-id>/.system_generated/logs/transcript.jsonl（回退 transcript_full.jsonl）。
// 子代理会话（nesting_depth > 0 或 parent_conversation_id 非空）不进入主列表。
// 增量解析：transcript.jsonl 只会追加，同一个文件（inode 不变）变大时从上次停下的位置接着读。

final class AntigravitySessionSource {
    private let environment: SessionEnvironment
    /// 列表缓存：只在 scan 里读写（SessionCatalog 串行化扫描）。
    private var cache: [String: SummaryEntry] = [:]
    /// 正文缓存：最近打开的几份会话，进行中时只读新增的行。
    private var transcripts: [String: TranscriptEntry] = [:]
    private var transcriptOrder: [String] = []
    private let transcriptLock = NSLock()
    private static let transcriptCacheLimit = 4

    private static let summaryNeedles = ["USER_INPUT", "PLANNER_RESPONSE"]
        .map { Data("\($0)".utf8) }
    private static let transcriptNeedles = ["USER_INPUT", "PLANNER_RESPONSE", "GENERIC", "ERROR_MESSAGE", "CHECKPOINT"]
        .map { Data("\($0)".utf8) }
    private static let maxLineBytes = 8 * 1024 * 1024

    struct DatabaseMeta {
        let title: String?
        let preview: String?
        let directory: String?
        let updatedAt: Date?
        let isWorking: Bool
        let isSubagent: Bool
    }

    private struct SummaryEntry {
        let fingerprint: FileFingerprint
        let offset: UInt64
        let state: SummaryState
    }

    private struct TranscriptEntry {
        let fingerprint: FileFingerprint
        let offset: UInt64
        let state: TranscriptState
    }

    init(environment: SessionEnvironment) {
        self.environment = environment
    }

    func scan(now: Date = Date()) -> [SessionSummary] {
        let root = environment.antigravityRoot
        let brainRoot = (root as NSString).appendingPathComponent("brain")
        let fileManager = FileManager.default
        guard let conversationIDs = try? fileManager.contentsOfDirectory(atPath: brainRoot) else {
            cache.removeAll()
            return []
        }

        let dbPath = (root as NSString).appendingPathComponent("conversation_summaries.db")
        let dbMetaByID = Self.readDatabaseMeta(dbPath: dbPath)

        var fresh: [String: SummaryEntry] = [:]
        var summaries: [SessionSummary] = []

        for sessionID in conversationIDs {
            guard !sessionID.hasPrefix(".") else { continue }
            let meta = dbMetaByID[sessionID]
            if meta?.isSubagent == true { continue }

            guard let transcriptPath = Self.resolveTranscriptPath(brainRoot: brainRoot, sessionID: sessionID, fileManager: fileManager),
                  let fingerprint = FileFingerprint(path: transcriptPath) else { continue }

            let entry: SummaryEntry
            if let cached = cache[transcriptPath], cached.fingerprint == fingerprint {
                entry = cached
            } else {
                entry = summarize(path: transcriptPath, fingerprint: fingerprint, previous: cache[transcriptPath])
            }
            fresh[transcriptPath] = entry

            if let summary = entry.state.summary(
                sessionID: sessionID,
                transcriptPath: transcriptPath,
                meta: meta,
                now: now
            ) {
                summaries.append(summary)
            }
        }

        cache = fresh
        return summaries
    }

    static func resolveTranscriptPath(brainRoot: String, sessionID: String, fileManager: FileManager = .default) -> String? {
        let logsDir = ((brainRoot as NSString).appendingPathComponent(sessionID) as NSString)
            .appendingPathComponent(".system_generated/logs")
        let compact = (logsDir as NSString).appendingPathComponent("transcript.jsonl")
        if fileManager.isReadableFile(atPath: compact) { return compact }
        let full = (logsDir as NSString).appendingPathComponent("transcript_full.jsonl")
        if fileManager.isReadableFile(atPath: full) { return full }
        return nil
    }

    // MARK: Database Metadata

    static func readDatabaseMeta(dbPath: String) -> [String: DatabaseMeta] {
        guard FileManager.default.fileExists(atPath: dbPath),
              let db = SessionSQLite(path: dbPath),
              db.tableExists("conversation_summaries") else {
            return [:]
        }
        let columns = db.columns(of: "conversation_summaries")
        guard columns.contains("conversation_id") else { return [:] }
        let wanted = [
            "conversation_id", "title", "preview", "last_modified_time",
            "workspace_uris", "status", "not_fully_idle",
            "parent_conversation_id", "nesting_depth"
        ].filter(columns.contains)

        var result: [String: DatabaseMeta] = [:]
        db.query("SELECT \(wanted.joined(separator: ", ")) FROM conversation_summaries") { row in
            guard let id = row.string("conversation_id"), !id.isEmpty else { return }
            let parentID = row.string("parent_conversation_id") ?? ""
            let nesting = row.int64("nesting_depth") ?? 0
            let isSubagent = !parentID.isEmpty || nesting > 0
            let title = row.string("title").flatMap(ClaudeSessionSource.nonEmpty)
            let preview = row.string("preview").flatMap(ClaudeSessionSource.nonEmpty)
            let directory = firstWorkspacePath(from: row.string("workspace_uris"))
            let updatedAt = parseDate(row.string("last_modified_time"))
            let status = row.string("status") ?? ""
            let notFullyIdle = (row.int64("not_fully_idle") ?? 0) != 0
            let isWorking = notFullyIdle || status == "CASCADE_RUN_STATUS_RUNNING"
            result[id] = DatabaseMeta(
                title: title,
                preview: preview,
                directory: directory,
                updatedAt: updatedAt,
                isWorking: isWorking,
                isSubagent: isSubagent
            )
        }
        return result
    }

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        if let direct = SessionText.date(iso: raw) { return direct }
        // SQLite timestamps in conversation_summaries.db may use a space separator ("2026-11-08 10:07:49.056419+00:00").
        if let spaceIndex = raw.firstIndex(of: " ") {
            var normalized = raw
            normalized.replaceSubrange(spaceIndex...spaceIndex, with: "T")
            if let parsed = SessionText.date(iso: normalized) { return parsed }
        }
        return nil
    }

    static func firstWorkspacePath(from rawJSON: String?) -> String? {
        guard let rawJSON, !rawJSON.isEmpty,
              let data = rawJSON.data(using: .utf8),
              let uris = (try? JSONSerialization.jsonObject(with: data)) as? [String] else {
            return nil
        }
        for uri in uris {
            let trimmed = uri.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            if trimmed.hasPrefix("file://"), let url = URL(string: trimmed), !url.path.isEmpty {
                return url.path
            }
            if trimmed.hasPrefix("/") {
                return trimmed
            }
        }
        return nil
    }

    // MARK: Summary

    private func summarize(path: String, fingerprint: FileFingerprint, previous: SummaryEntry?) -> SummaryEntry {
        var state = SummaryState()
        var offset: UInt64 = 0
        if let previous, ClaudeSessionSource.canContinue(from: previous.fingerprint, offset: previous.offset, to: fingerprint, path: path) {
            state = previous.state
            offset = previous.offset
        }
        let end = SessionLineReader.read(path: path, from: offset, needles: Self.summaryNeedles, maxLineBytes: Self.maxLineBytes) { line in
            guard let record = SessionJSON.object(line) else { return false }
            state.consume(record)
            return true
        } ?? offset
        return SummaryEntry(fingerprint: fingerprint, offset: end, state: state)
    }

    struct SummaryState {
        var firstPrompt: String?
        var prompts = 0
        var directory: String?
        var model: String?
        var firstDate: Date?
        var lastDate: Date?
        var usageByStep: [Int: Int] = [:]
        var unindexedUsage = 0
        var search = SessionText.SearchBuffer()

        mutating func consume(_ record: [String: Any]) {
            guard let type = record["type"] as? String else { return }
            if let date = SessionText.date(iso: record["created_at"] as? String) {
                firstDate = firstDate ?? date
                lastDate = date
            }
            switch type {
            case "USER_INPUT":
                let content = record["content"] as? String ?? ""
                if directory == nil, let extractedDir = AntigravitySessionSource.extractDirectory(from: content) {
                    directory = extractedDir
                }
                if let selectedModel = AntigravitySessionSource.extractModel(from: content) {
                    model = selectedModel
                }
                if let prompt = AntigravitySessionSource.extractUserPrompt(from: content) {
                    prompts += 1
                    firstPrompt = firstPrompt ?? prompt
                    search.append(prompt)
                }
            case "PLANNER_RESPONSE":
                let input = SessionJSON.int(record["input_tokens"]) ?? 0
                let output = SessionJSON.int(record["output_tokens"]) ?? 0
                let cacheRead = SessionJSON.int(record["cache_read_tokens"]) ?? 0
                let total = input + output + cacheRead
                if total > 0 {
                    if let stepIndex = SessionJSON.int(record["step_index"]) {
                        usageByStep[stepIndex] = total
                    } else {
                        unindexedUsage += total
                    }
                }
            default:
                break
            }
        }

        func summary(sessionID: String, transcriptPath: String, meta: DatabaseMeta?, now: Date) -> SessionSummary? {
            let updatedAt = [lastDate, meta?.updatedAt].compactMap { $0 }.max()
            guard prompts > 0, let updatedAt else { return nil }
            let resolvedDirectory = meta?.directory ?? directory
            let rawTitle = meta?.title
                ?? firstPrompt.map(SessionText.title(fromPrompt:))
                ?? meta?.preview.map(SessionText.title(fromPrompt:))
                ?? sessionID
            let title = rawTitle.isEmpty ? sessionID : rawTitle

            var searchText = SessionText.SearchBuffer()
            searchText.append([title, resolvedDirectory, sessionID].compactMap { $0 }.joined(separator: " "))
            searchText.append(search.text)

            let tokens = usageByStep.values.reduce(unindexedUsage, +)
            var result = SessionSummary(
                tool: .antigravity,
                sessionID: sessionID,
                title: title,
                directory: resolvedDirectory,
                gitBranch: nil,
                model: model,
                createdAt: firstDate ?? meta?.updatedAt,
                updatedAt: updatedAt,
                promptCount: prompts,
                tokens: tokens > 0 ? tokens : nil,
                isPinned: false,
                hasTranscript: true,
                resumeBlocker: resolvedDirectory.map { FileManager.default.fileExists(atPath: $0) } == false ? .directoryMissing : nil,
                searchText: searchText.text,
                locator: .antigravityBrain(transcriptPath: transcriptPath)
            )
            if meta?.isWorking == true, now.timeIntervalSince(updatedAt) < SessionText.activityWindow {
                result.activity = .working
            }
            return result
        }
    }

    // MARK: Transcript

    func transcript(path: String, base: String?, home: String, limit: Int, cached: Bool) throws -> SessionTranscript {
        guard FileManager.default.isReadableFile(atPath: path), let fingerprint = FileFingerprint(path: path) else {
            throw SessionTranscriptError.unreadable
        }
        guard cached else {
            var state = TranscriptState(directory: base)
            _ = Self.readTranscript(path: path, from: 0, home: home, into: &state)
            return state.builder.build(limit: limit)
        }

        transcriptLock.lock()
        defer { transcriptLock.unlock() }
        var state = TranscriptState(directory: base)
        var offset: UInt64 = 0
        if let previous = transcripts[path] {
            if previous.fingerprint == fingerprint { return previous.state.builder.build(limit: limit) }
            if ClaudeSessionSource.canContinue(from: previous.fingerprint, offset: previous.offset, to: fingerprint, path: path) {
                state = previous.state
                offset = previous.offset
            }
        }
        let end = Self.readTranscript(path: path, from: offset, home: home, into: &state) ?? offset
        transcripts[path] = TranscriptEntry(fingerprint: fingerprint, offset: end, state: state)
        transcriptOrder.removeAll { $0 == path }
        transcriptOrder.append(path)
        while transcriptOrder.count > Self.transcriptCacheLimit {
            transcripts.removeValue(forKey: transcriptOrder.removeFirst())
        }
        return state.builder.build(limit: limit)
    }

    private static func readTranscript(path: String, from offset: UInt64, home: String, into state: inout TranscriptState) -> UInt64? {
        SessionLineReader.read(path: path, from: offset, needles: transcriptNeedles, maxLineBytes: maxLineBytes) { line in
            guard let record = SessionJSON.object(line) else { return false }
            state.consume(record, home: home)
            return true
        }
    }

    struct TranscriptState {
        var builder = TranscriptBuilder()
        var directory: String?
        var pendingCallIDs: [String] = []
        var stepCounter = 0

        mutating func consume(_ record: [String: Any], home: String) {
            guard let type = record["type"] as? String else { return }
            let date = SessionText.date(iso: record["created_at"] as? String)
            let stepIndex = SessionJSON.int(record["step_index"]) ?? stepCounter
            stepCounter += 1

            switch type {
            case "USER_INPUT":
                pendingCallIDs.removeAll()
                let content = record["content"] as? String ?? ""
                if directory == nil, let extractedDir = AntigravitySessionSource.extractDirectory(from: content) {
                    directory = extractedDir
                }
                if content.contains("<CONTEXT_SUMMARY>") {
                    builder.notice(.contextCompacted, date: date)
                }
                if let prompt = AntigravitySessionSource.extractUserPrompt(from: content) {
                    builder.prompt(prompt, date: date)
                }

            case "PLANNER_RESPONSE":
                pendingCallIDs.removeAll()
                let content = SessionText.clean(record["content"] as? String ?? "")
                if !content.isEmpty {
                    builder.reply(content, date: date)
                }
                let toolCalls = record["tool_calls"] as? [[String: Any]] ?? []
                for (index, call) in toolCalls.enumerated() {
                    let name = call["name"] as? String ?? ""
                    let args = (call["args"] as? [String: Any])
                        ?? (call["arguments"] as? [String: Any])
                        ?? SessionJSON.object(call["args"] as? String)
                        ?? [:]
                    let callID = "\(stepIndex):\(index)"
                    let step = ToolStepFactory.make(name: name, input: args, base: directory, home: home)
                    builder.step(step, callID: callID, date: date)
                    pendingCallIDs.append(callID)
                }

            case "GENERIC":
                guard !pendingCallIDs.isEmpty else { return }
                let callID = pendingCallIDs.removeFirst()
                if let note = AntigravitySessionSource.failureNote(in: record) {
                    builder.markFailed(callID: callID, note: note)
                }

            case "ERROR_MESSAGE":
                guard let callID = pendingCallIDs.first else { return }
                let rawError = (record["error"] as? String) ?? (record["content"] as? String) ?? "Error"
                builder.markFailed(callID: callID, note: SessionText.oneLine(rawError, limit: 200))

            case "CHECKPOINT":
                builder.notice(.contextCompacted, date: date)

            default:
                break
            }
        }
    }

    // MARK: Parsing Helpers

    static func extractUserPrompt(from content: String) -> String? {
        guard !content.isEmpty else { return nil }
        if let start = content.range(of: "<USER_REQUEST>"),
           let end = content.range(of: "</USER_REQUEST>", range: start.upperBound..<content.endIndex) {
            let body = String(content[start.upperBound..<end.lowerBound])
            let cleaned = SessionText.clean(body)
            return cleaned.isEmpty ? nil : cleaned
        }

        // Subagent or plain prompt without <USER_REQUEST> wrapper: strip known system metadata blocks.
        var stripped = content
        for tag in ["ADDITIONAL_METADATA", "USER_SETTINGS_CHANGE", "CONTEXT_SUMMARY", "EPHEMERAL_MESSAGE"] {
            while let start = stripped.range(of: "<\(tag)>"),
                  let end = stripped.range(of: "</\(tag)>", range: start.upperBound..<stripped.endIndex) {
                stripped.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        let cleaned = SessionText.clean(stripped)
        return cleaned.isEmpty ? nil : cleaned
    }

    static func extractDirectory(from content: String) -> String? {
        guard let metaStart = content.range(of: "<ADDITIONAL_METADATA>"),
              let metaEnd = content.range(of: "</ADDITIONAL_METADATA>", range: metaStart.upperBound..<content.endIndex) else {
            return nil
        }
        let meta = content[metaStart.upperBound..<metaEnd.lowerBound]
        if let cwdMarker = meta.range(of: "Command Working Directory:") {
            let after = meta[cwdMarker.upperBound...]
            if let line = after.split(whereSeparator: \.isNewline).first {
                let path = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if path.hasPrefix("/") { return path }
            }
        }
        if let wsMarker = meta.range(of: "Active Workspaces:") {
            let after = meta[wsMarker.upperBound...]
            for rawLine in after.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("- /") {
                    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            }
        }
        return nil
    }

    static func extractModel(from content: String) -> String? {
        if let selected = AntigravityCostProvider.extractSelectedModel(from: content),
           selected != "unknown-model",
           !selected.hasPrefix("model-placeholder") {
            return selected
        }
        guard content.contains("<USER_SETTINGS_CHANGE>"),
              content.contains("Model Selection") else {
            return nil
        }
        if let newRange = content.range(of: "New:") {
            let after = content[newRange.upperBound...]
            if let line = after.split(whereSeparator: \.isNewline).first {
                let raw = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !raw.isEmpty,
                   !raw.uppercased().hasPrefix("MODEL_PLACEHOLDER"),
                   let normalized = AntigravityCostProvider.normalizeSelectedModelName(raw),
                   normalized != "unknown-model" {
                    return normalized
                }
            }
        }
        return nil
    }

    static func failureNote(in record: [String: Any]) -> String? {
        let status = (record["status"] as? String ?? "").uppercased()
        let content = record["content"] as? String ?? ""
        if status == "ERROR" {
            return SessionText.lastLine(content, limit: 200) ?? "Tool error"
        }
        if let errRange = content.range(of: "Encountered error in ") {
            let tail = String(content[errRange.lowerBound...])
            return SessionText.oneLine(tail, limit: 200)
        }
        if let exitRange = content.range(of: "Command exited with code ") {
            let after = content[exitRange.upperBound...]
            let codePrefix = after.prefix { $0.isNumber || $0 == "-" }
            if let code = Int(codePrefix), code != 0 {
                return SessionText.lastLine(content, limit: 200) ?? "exit \(code)"
            }
        }
        return nil
    }
}
