import Foundation

// MARK: - Codex Call Event Source
// 解析 Codex 的本地会话日志，提取工具 / MCP / Skill 调用计数。
// 数据来源: ~/.codex/sessions、archived_sessions（或 $CODEX_HOME）下的 *.jsonl。
// 关注三类信号（皆带根 timestamp，ISO8601）：
//   • response_item.payload.type==function_call → 内置工具（取 payload.name）
//   • event_msg.type==mcp_tool_call_end → MCP 调用（取 invocation.{server,tool}）
//   • Codex 自 2025/12 起原生支持 Skills（~/.codex/skills，SKILL.md 开放标准）。
//     技能调用不是离散事件：渐进式披露下「用到才读全文」，体现为 exec_command
//     读取 skills/<name>/SKILL.md。故按 function_call 行内的 SKILL.md 路径启发式
//     计数（每个读取命令计一次），排除 .system 系统技能。属弱信号、可能有噪声。
// 单文件可达 95MB，故只读匹配行的前缀（字节级取字段），不整体反序列化。

struct CodexCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone
    let environment: [String: String]

    private static let maxLineBytes = 256 * 1024
    private static let functionCallNeedle = Data("\"function_call\"".utf8)
    private static let mcpEndNeedle = Data("\"mcp_tool_call_end\"".utf8)
    private static let skillMarker = "/SKILL.md"
    private static let skillsSegment = "skills"
    /// 合法技能目录名字符集：排除 glob（* ? [ ]）、空白等，避免把 `skills/*/SKILL.md` 当成技能。
    private static let skillNameAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    func resolveSessionRoots() -> [String] {
        let codexHome: String
        if let value = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            codexHome = value
        } else {
            codexHome = "\(homeDirectory)/.codex"
        }
        return ["\(codexHome)/sessions", "\(codexHome)/archived_sessions"]
    }

    func collect(cutoff: Date?) -> (entries: [CallAnalyticsEntry], status: CallSourceStatus) {
        let clock = CallAnalyticsClock(timeZone: timeZone)
        let roots = resolveSessionRoots().filter { FileManager.default.fileExists(atPath: $0) }
        guard !roots.isEmpty else {
            return ([], CallSourceStatus(source: .codex, available: false, eventCount: 0, filesScanned: 0, errorCode: nil))
        }

        let files = collectJSONLFiles(roots: roots, cutoff: cutoff)
        var accumulator = CallEventAccumulator()
        for file in files {
            let fallbackDayKey = clock.dayKey(fileModificationDate(file) ?? Date())
            CallAnalyticsLineReader.forEachLine(
                path: file,
                needles: [Self.functionCallNeedle, Self.mcpEndNeedle],
                maxLineBytes: Self.maxLineBytes
            ) { line in
                parseLine(line, clock: clock, fallbackDayKey: fallbackDayKey, into: &accumulator)
            }
        }

        let status = CallSourceStatus(
            source: .codex,
            available: true,
            eventCount: accumulator.eventCount,
            filesScanned: files.count,
            errorCode: nil
        )
        return (accumulator.entries(), status)
    }

    // MARK: - Parsing

    private func parseLine(
        _ line: Data,
        clock: CallAnalyticsClock,
        fallbackDayKey: String,
        into accumulator: inout CallEventAccumulator
    ) {
        let dayKey: String
        if let ts = CallAnalyticsJSON.stringValue(forKey: "timestamp", in: line), let date = clock.date(fromISO: ts) {
            dayKey = clock.dayKey(date)
        } else {
            dayKey = fallbackDayKey
        }

        if line.range(of: Self.mcpEndNeedle) != nil {
            guard let invocation = CallAnalyticsJSON.objectRange(forKey: "invocation", in: line) else { return }
            let server = CallAnalyticsJSON.stringValue(forKey: "server", in: line, range: invocation)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = CallAnalyticsJSON.stringValue(forKey: "tool", in: line, range: invocation)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let server, !server.isEmpty, let tool, !tool.isEmpty else { return }
            accumulator.add(
                source: .codex,
                kind: .mcp,
                name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: tool),
                server: server,
                dayKey: dayKey,
                success: Self.mcpSuccess(in: line),
                durationMs: Self.mcpDurationMs(in: line)
            )
            return
        }

        // function_call：取 payload.name（行内首个 "name" 即函数名，在 arguments 之前）。
        if line.range(of: Self.functionCallNeedle) != nil {
            if let name = CallAnalyticsJSON.stringValue(forKey: "name", in: line)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
                accumulator.add(source: .codex, kind: .builtin, name: name, server: nil, dayKey: dayKey)
            }
            // 同一行的 exec_command 参数里若读取了 skills/<name>/SKILL.md，记一次技能调用。
            for skill in Self.skillReads(in: line) {
                accumulator.add(source: .codex, kind: .skill, name: skill, server: nil, dayKey: dayKey)
            }
        }
    }

    /// 判定 MCP 调用成功/失败：result 对象首 key 为 `Ok`→成功、`Err`→失败，缺失/截断→nil。
    /// 用「对象首 key」而非整行子串，避免正文里的 "Ok"/"Err" 误判（大行可能被 256KB 截断 → nil，优雅降级）。
    private static func mcpSuccess(in line: Data) -> Bool? {
        guard let resultRange = CallAnalyticsJSON.objectRange(forKey: "result", in: line),
              let key = CallAnalyticsJSON.firstKey(inObject: resultRange, in: line) else { return nil }
        switch key {
        case "Ok": return true
        case "Err": return false
        default: return nil
        }
    }

    /// 从 `"duration":{"secs":S,"nanos":N}` 算耗时（毫秒）。缺失/截断返回 nil。
    private static func mcpDurationMs(in line: Data) -> Double? {
        guard let durationRange = CallAnalyticsJSON.objectRange(forKey: "duration", in: line) else { return nil }
        let secs = CallAnalyticsJSON.intValue(forKey: "secs", in: line, range: durationRange) ?? 0
        let nanos = CallAnalyticsJSON.intValue(forKey: "nanos", in: line, range: durationRange) ?? 0
        if secs == 0 && nanos == 0 { return nil }
        return Double(secs) * 1000 + Double(nanos) / 1_000_000
    }

    /// 从 function_call 行内提取被读取的技能名（skills/<name>/SKILL.md 的父目录名）。
    /// 排除 .system 系统技能；按读取命令去重（function_call 输出行不含闭合的
    /// "function_call" 串，不会被本分支命中，因此天然避免文件内容造成的重复计数）。
    private static func skillReads(in line: Data) -> [String] {
        guard var text = String(data: line, encoding: .utf8), text.contains(skillMarker) else { return [] }
        // JSON 里转义的 \/ 归一为 /，保证路径段切分稳定。
        if text.contains("\\/") { text = text.replacingOccurrences(of: "\\/", with: "/") }

        var names = Set<String>()
        var cursor = text.startIndex
        while let marker = text.range(of: skillMarker, range: cursor..<text.endIndex) {
            cursor = marker.upperBound
            let before = text[text.startIndex..<marker.lowerBound]
            guard let nameSlash = before.lastIndex(of: "/") else { continue }
            let name = String(before[before.index(after: nameSlash)...])
            // 父级路径段必须是 skills/，排除系统技能、空名与含 glob/非法字符的名。
            let parentPath = before[before.startIndex..<nameSlash]
            guard parentPath.hasSuffix("/\(skillsSegment)") || parentPath == skillsSegment,
                  !name.isEmpty, name != ".system",
                  !before.contains("/.system/"),
                  name.unicodeScalars.allSatisfy(skillNameAllowed.contains) else { continue }
            names.insert(name)
        }
        return Array(names)
    }

    // MARK: - File discovery

    private func collectJSONLFiles(roots: [String], cutoff: Date?) -> [String] {
        var files: [String] = []
        var seen = Set<String>()
        for root in roots {
            let rootURL = URL(fileURLWithPath: root, isDirectory: true).resolvingSymlinksInPath()
            guard let enumerator = FileManager.default.enumerator(
                at: rootURL,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let item as URL in enumerator {
                guard item.pathExtension.lowercased() == "jsonl" else { continue }
                let values = try? item.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
                if values?.isRegularFile == false { continue }
                if let cutoff, let modified = values?.contentModificationDate, modified < cutoff { continue }
                guard seen.insert(item.path).inserted else { continue }
                files.append(item.path)
            }
        }
        return files
    }

    private func fileModificationDate(_ path: String) -> Date? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate
    }
}
