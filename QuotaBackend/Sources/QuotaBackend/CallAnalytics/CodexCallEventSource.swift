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
    var knownMCPServers: Set<String> = []

    private static let maxLineBytes = 256 * 1024
    private static let functionCallNeedle = Data("\"function_call\"".utf8)
    private static let customToolCallNeedle = Data("\"custom_tool_call\"".utf8)
    private static let mcpEndNeedle = Data("\"mcp_tool_call_end\"".utf8)
    private static let skillMarker = "/SKILL.md"
    private static let skillsSegment = "skills"
    /// 合法技能目录名字符集：排除 glob（* ? [ ]）、空白等，避免把 `skills/*/SKILL.md` 当成技能。
    private static let skillNameAllowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let jsWrapperToolRegex = try? NSRegularExpression(pattern: #"tools\.([A-Za-z_][A-Za-z0-9_]*)\s*\("#)
    private static let regexValueKeywords: Set<String> = [
        "return", "throw", "case", "delete", "void", "typeof", "instanceof",
        "in", "of", "new", "yield", "await"
    ]
    private static let regexBlockKeywords: Set<String> = [
        "else", "do", "try", "finally"
    ]
    private static let controlParenKeywords: Set<String> = [
        "if", "while", "for", "with", "switch", "catch"
    ]

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
                needles: [Self.functionCallNeedle, Self.customToolCallNeedle, Self.mcpEndNeedle],
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

        let header = line.prefix(512)
        if header.range(of: Self.mcpEndNeedle) != nil {
            guard let invocation = CallAnalyticsJSON.objectRange(forKey: "invocation", in: line) else { return }
            let rawServer = CallAnalyticsJSON.stringValue(forKey: "server", in: line, range: invocation)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let tool = CallAnalyticsJSON.stringValue(forKey: "tool", in: line, range: invocation)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let rawServer, !rawServer.isEmpty, let tool, !tool.isEmpty else { return }
            let server = resolveServer(rawServer)
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

        if header.range(of: Self.customToolCallNeedle) != nil {
            parseCustomToolCall(line: line, dayKey: dayKey, into: &accumulator)
            return
        }

        if header.range(of: Self.functionCallNeedle) != nil {
            parseFunctionCall(line: line, dayKey: dayKey, into: &accumulator)
        }
    }

    private func parseFunctionCall(
        line: Data,
        dayKey: String,
        into accumulator: inout CallEventAccumulator
    ) {
        let funcName = CallAnalyticsJSON.stringValue(forKey: "name", in: line)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let namespace = CallAnalyticsJSON.stringValue(forKey: "namespace", in: line)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let funcName, !funcName.isEmpty {
            if let namespace, namespace.hasPrefix("mcp__") {
                let rawServer = String(namespace.dropFirst("mcp__".count))
                let server = resolveServer(rawServer)
                accumulator.add(
                    source: .codex,
                    kind: .mcp,
                    name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: funcName),
                    server: server,
                    dayKey: dayKey,
                    reclassifiedBuiltin: !funcName.hasPrefix("mcp__")
                )
            } else if let mcp = CallAnalyticsNaming.parseClaudeMCP(funcName) {
                let server = resolveServer(mcp.server)
                accumulator.add(
                    source: .codex,
                    kind: .mcp,
                    name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: mcp.tool),
                    server: server,
                    dayKey: dayKey
                )
            } else {
                accumulator.add(source: .codex, kind: .builtin, name: funcName, server: nil, dayKey: dayKey)
            }
        }
        // 同一行的 exec_command 参数里若读取了 skills/<name>/SKILL.md，记一次技能调用。
        if funcName != "apply_patch" {
            for skill in Self.skillReads(in: String(decoding: line, as: UTF8.self)) {
                accumulator.add(source: .codex, kind: .skill, name: skill, server: nil, dayKey: dayKey)
            }
        }
    }

    private func parseCustomToolCall(
        line: Data,
        dayKey: String,
        into accumulator: inout CallEventAccumulator
    ) {
        let wrapperName = CallAnalyticsJSON.stringValue(forKey: "name", in: line)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isJSWrapper = (wrapperName == "js_repl" || wrapperName == "exec")
        guard let wrapperName, isJSWrapper else {
            if let wrapperName, !wrapperName.isEmpty {
                accumulator.add(source: .codex, kind: .builtin, name: wrapperName, server: nil, dayKey: dayKey)
            }
            return
        }
        let inputText = CallAnalyticsJSON.stringValue(forKey: "input", in: line)
            ?? String(decoding: line, as: UTF8.self)
        let jsCalls = Self.extractJSWrapperToolCalls(in: inputText)
        if jsCalls.isEmpty {
            accumulator.add(source: .codex, kind: .builtin, name: wrapperName, server: nil, dayKey: dayKey)
        } else {
            for identifier in jsCalls {
                if let mcp = CallAnalyticsNaming.parseClaudeMCP(identifier) {
                    let server = resolveServer(mcp.server)
                    accumulator.add(
                        source: .codex,
                        kind: .mcp,
                        name: CallAnalyticsNaming.mcpDisplayName(server: server, tool: mcp.tool),
                        server: server,
                        dayKey: dayKey
                    )
                } else {
                    accumulator.add(source: .codex, kind: .builtin, name: identifier, server: nil, dayKey: dayKey)
                }
            }
        }
        for skill in Self.skillReads(in: inputText) {
            accumulator.add(source: .codex, kind: .skill, name: skill, server: nil, dayKey: dayKey)
        }
    }

    private func resolveServer(_ rawServer: String) -> String {
        if knownMCPServers.contains(rawServer) { return rawServer }
        if let matched = knownMCPServers.first(where: { $0.replacingOccurrences(of: "-", with: "_") == rawServer }) {
            return matched
        }
        if rawServer == "cua_repl", knownMCPServers.contains("computer-use") {
            return "computer-use"
        }
        return rawServer
    }

    private static func extractJSWrapperToolCalls(in text: String) -> [String] {
        guard text.contains("tools."), let regex = jsWrapperToolRegex else { return [] }
        let sanitized = stripJSCommentsAndStrings(text)
        guard sanitized.contains("tools.") else { return [] }
        let range = NSRange(sanitized.startIndex..., in: sanitized)
        return regex.matches(in: sanitized, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let nameRange = Range(match.range(at: 1), in: sanitized) else {
                return nil
            }
            return String(sanitized[nameRange])
        }
    }

    private static func isJSWordScalar(_ scalar: UnicodeScalar) -> Bool {
        let v = scalar.value
        return (v >= 0x30 && v <= 0x39) // 0-9
            || (v >= 0x41 && v <= 0x5A) // A-Z
            || (v >= 0x61 && v <= 0x7A) // a-z
            || v == 0x5F // _
            || v == 0x24 // $
    }

    private static func consumeRegexLiteral(scalars: [UnicodeScalar], from startIndex: Int) -> Int? {
        var i = startIndex + 1
        var inCharClass = false
        while i < scalars.count {
            let c = scalars[i]
            if c == "\n" || c == "\r" {
                return nil
            }
            if c == "\\" {
                i += 1
                guard i < scalars.count, scalars[i] != "\n", scalars[i] != "\r" else {
                    return nil
                }
                i += 1
                continue
            }
            if c == "[" {
                inCharClass = true
                i += 1
                continue
            }
            if c == "]", inCharClass {
                inCharClass = false
                i += 1
                continue
            }
            if c == "/", !inCharClass {
                i += 1
                while i < scalars.count {
                    let flag = scalars[i].value
                    if (flag >= 0x41 && flag <= 0x5A) || (flag >= 0x61 && flag <= 0x7A) {
                        i += 1
                    } else {
                        break
                    }
                }
                return i
            }
            i += 1
        }
        return nil
    }

    private enum ParenRole {
        case controlHeader
        case functionParams(isExpression: Bool)
        case expression
    }

    private struct BraceContext {
        let allowsRegexAfterClose: Bool
        let isObjectLiteral: Bool
        var pendingTernaryColons: Int = 0
    }

    private static func stripJSCommentsAndStrings(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var result: [UnicodeScalar] = []
        result.reserveCapacity(scalars.count)
        var index = 0
        var interpolationDepths: [Int] = []
        var parenStack: [ParenRole] = []
        var braceStack: [BraceContext] = []
        var bracketDepth = 0
        var topLevelTernaryColons = 0
        var canStartRegex = true
        var nextBraceIsObjectLiteral = false
        var pendingControlParen = false
        var pendingFunctionParenIsExpression: Bool? = nil
        var pendingBodyBraceIsExpression = false
        var pendingArrowBlockBrace = false
        var pendingClassBodies: [(isExpression: Bool, parenDepth: Int, braceDepth: Int, bracketDepth: Int)] = []
        var lastTokenWasDot = false
        var currentWord = ""

        func popCurrentPendingClassBody() {
            guard let last = pendingClassBodies.last,
                  last.parenDepth == parenStack.count,
                  last.braceDepth == braceStack.count,
                  last.bracketDepth == bracketDepth else { return }
            _ = pendingClassBodies.popLast()
        }

        while index < scalars.count {
            let ch = scalars[index]

            if isJSWordScalar(ch) {
                currentWord.unicodeScalars.append(ch)
                result.append(ch)
                canStartRegex = false
                index += 1
                continue
            }
            if !currentWord.isEmpty {
                pendingArrowBlockBrace = false
                if !lastTokenWasDot {
                    if currentWord == "async" {
                        canStartRegex = false
                        pendingControlParen = false
                        pendingBodyBraceIsExpression = false
                    } else if currentWord == "function" {
                        canStartRegex = false
                        pendingFunctionParenIsExpression = nextBraceIsObjectLiteral
                        nextBraceIsObjectLiteral = false
                        pendingControlParen = false
                        pendingBodyBraceIsExpression = false
                    } else if currentWord == "class" {
                        canStartRegex = false
                        pendingClassBodies.append((
                            isExpression: nextBraceIsObjectLiteral,
                            parenDepth: parenStack.count,
                            braceDepth: braceStack.count,
                            bracketDepth: bracketDepth
                        ))
                        nextBraceIsObjectLiteral = false
                        pendingControlParen = false
                        pendingFunctionParenIsExpression = nil
                        pendingBodyBraceIsExpression = false
                    } else if currentWord == "extends" {
                        canStartRegex = true
                        nextBraceIsObjectLiteral = true
                        pendingControlParen = false
                        pendingFunctionParenIsExpression = nil
                        pendingBodyBraceIsExpression = false
                    } else if regexValueKeywords.contains(currentWord) {
                        canStartRegex = true
                        nextBraceIsObjectLiteral = true
                        if !(currentWord == "await" && pendingControlParen) {
                            pendingControlParen = false
                        }
                        pendingFunctionParenIsExpression = nil
                        pendingBodyBraceIsExpression = false
                    } else if regexBlockKeywords.contains(currentWord) {
                        canStartRegex = true
                        nextBraceIsObjectLiteral = false
                        pendingControlParen = false
                        pendingFunctionParenIsExpression = nil
                        pendingBodyBraceIsExpression = false
                    } else if controlParenKeywords.contains(currentWord) {
                        canStartRegex = false
                        nextBraceIsObjectLiteral = false
                        pendingControlParen = true
                        pendingFunctionParenIsExpression = nil
                        pendingBodyBraceIsExpression = false
                    } else {
                        nextBraceIsObjectLiteral = false
                        pendingControlParen = false
                        pendingBodyBraceIsExpression = false
                    }
                } else {
                    nextBraceIsObjectLiteral = false
                    pendingControlParen = false
                    pendingFunctionParenIsExpression = nil
                    pendingBodyBraceIsExpression = false
                }
                lastTokenWasDot = false
                currentWord.removeAll(keepingCapacity: true)
            }

            if !interpolationDepths.isEmpty {
                if ch == "{" {
                    interpolationDepths[interpolationDepths.count - 1] += 1
                } else if ch == "}" {
                    if interpolationDepths[interpolationDepths.count - 1] == 0 {
                        interpolationDepths.removeLast()
                        let closingDepth = braceStack.count
                        while pendingClassBodies.last?.braceDepth == closingDepth {
                            _ = pendingClassBodies.popLast()
                        }
                        _ = braceStack.popLast()
                        result.append(ch)
                        index += 1
                        consumeTemplateLiteral(
                            scalars: scalars,
                            index: &index,
                            result: &result,
                            interpolationDepths: &interpolationDepths,
                            braceStack: &braceStack,
                            canStartRegex: &canStartRegex,
                            nextBraceIsObjectLiteral: &nextBraceIsObjectLiteral,
                            pendingControlParen: &pendingControlParen,
                            pendingFunctionParenIsExpression: &pendingFunctionParenIsExpression,
                            pendingBodyBraceIsExpression: &pendingBodyBraceIsExpression,
                            pendingArrowBlockBrace: &pendingArrowBlockBrace,
                            lastTokenWasDot: &lastTokenWasDot
                        )
                        continue
                    }
                    interpolationDepths[interpolationDepths.count - 1] -= 1
                }
            }

            if ch == "/", index + 1 < scalars.count {
                let next = scalars[index + 1]
                if next == "/" {
                    index += 2
                    while index < scalars.count, scalars[index] != "\n", scalars[index] != "\r" {
                        index += 1
                    }
                    continue
                }
                if next == "*" {
                    index += 2
                    while index + 1 < scalars.count, !(scalars[index] == "*" && scalars[index + 1] == "/") {
                        index += 1
                    }
                    index = min(scalars.count, index + 2)
                    result.append(" ")
                    continue
                }
                if canStartRegex, let nextIndex = consumeRegexLiteral(scalars: scalars, from: index) {
                    result.append(" ")
                    index = nextIndex
                    canStartRegex = false
                    nextBraceIsObjectLiteral = false
                    pendingControlParen = false
                    pendingFunctionParenIsExpression = nil
                    pendingBodyBraceIsExpression = false
                    pendingArrowBlockBrace = false
                    lastTokenWasDot = false
                    continue
                }
            }

            if ch == "\"" || ch == "'" {
                let quote = ch
                result.append(quote)
                index += 1
                while index < scalars.count {
                    let c = scalars[index]
                    index += 1
                    if c == "\\", index < scalars.count {
                        index += 1
                        continue
                    }
                    if c == quote {
                        result.append(quote)
                        break
                    }
                }
                canStartRegex = false
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
                continue
            }

            if ch == "`" {
                result.append(ch)
                index += 1
                consumeTemplateLiteral(
                    scalars: scalars,
                    index: &index,
                    result: &result,
                    interpolationDepths: &interpolationDepths,
                    braceStack: &braceStack,
                    canStartRegex: &canStartRegex,
                    nextBraceIsObjectLiteral: &nextBraceIsObjectLiteral,
                    pendingControlParen: &pendingControlParen,
                    pendingFunctionParenIsExpression: &pendingFunctionParenIsExpression,
                    pendingBodyBraceIsExpression: &pendingBodyBraceIsExpression,
                    pendingArrowBlockBrace: &pendingArrowBlockBrace,
                    lastTokenWasDot: &lastTokenWasDot
                )
                continue
            }

            if ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                // Whitespace does not alter whether `/` begins a regex literal or division.
            } else if ch == "=" && index + 1 < scalars.count && scalars[index + 1] == ">" {
                result.append("=")
                result.append(">")
                index += 2
                canStartRegex = true
                nextBraceIsObjectLiteral = true
                pendingArrowBlockBrace = true
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                popCurrentPendingClassBody()
                lastTokenWasDot = false
                continue
            } else if (ch == "+" || ch == "-") && index + 1 < scalars.count && scalars[index + 1] == ch {
                result.append(ch)
                result.append(ch)
                index += 2
                nextBraceIsObjectLiteral = canStartRegex
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
                continue
            } else if ch == "(" {
                if let isFuncExpr = pendingFunctionParenIsExpression {
                    parenStack.append(.functionParams(isExpression: isFuncExpr))
                    pendingFunctionParenIsExpression = nil
                } else if pendingControlParen {
                    parenStack.append(.controlHeader)
                } else {
                    parenStack.append(.expression)
                }
                pendingControlParen = false
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                canStartRegex = true
                nextBraceIsObjectLiteral = true
                lastTokenWasDot = false
            } else if ch == ")" {
                switch parenStack.popLast() {
                case .controlHeader:
                    canStartRegex = true
                    pendingBodyBraceIsExpression = false
                case .functionParams(let isExpression):
                    canStartRegex = false
                    pendingBodyBraceIsExpression = isExpression
                case .expression, nil:
                    canStartRegex = false
                    pendingBodyBraceIsExpression = false
                }
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            } else if ch == "[" {
                bracketDepth += 1
                canStartRegex = true
                nextBraceIsObjectLiteral = true
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            } else if ch == "]" {
                bracketDepth = max(0, bracketDepth - 1)
                canStartRegex = false
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            } else if ch == "{" {
                let allowsRegexAfterClose: Bool
                let isObjectLiteral: Bool
                if pendingArrowBlockBrace {
                    allowsRegexAfterClose = true
                    isObjectLiteral = false
                } else if pendingBodyBraceIsExpression {
                    allowsRegexAfterClose = false
                    isObjectLiteral = false
                } else if let pendingClass = pendingClassBodies.last,
                          pendingClass.parenDepth == parenStack.count,
                          pendingClass.braceDepth == braceStack.count,
                          pendingClass.bracketDepth == bracketDepth,
                          !nextBraceIsObjectLiteral {
                    _ = pendingClassBodies.popLast()
                    allowsRegexAfterClose = !pendingClass.isExpression
                    isObjectLiteral = false
                } else if nextBraceIsObjectLiteral {
                    allowsRegexAfterClose = false
                    isObjectLiteral = true
                } else {
                    allowsRegexAfterClose = true
                    isObjectLiteral = false
                }
                braceStack.append(BraceContext(allowsRegexAfterClose: allowsRegexAfterClose, isObjectLiteral: isObjectLiteral))
                canStartRegex = true
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            } else if ch == "}" {
                if !braceStack.isEmpty {
                    let closingDepth = braceStack.count
                    while pendingClassBodies.last?.braceDepth == closingDepth {
                        _ = pendingClassBodies.popLast()
                    }
                }
                canStartRegex = braceStack.popLast()?.allowsRegexAfterClose ?? true
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            } else if ch == "." {
                canStartRegex = false
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = true
            } else if ch == ";" {
                canStartRegex = true
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                popCurrentPendingClassBody()
                lastTokenWasDot = false
            } else if ch == "?" {
                pendingArrowBlockBrace = false
                if index + 1 < scalars.count, scalars[index + 1] == "." {
                    let afterDot = index + 2 < scalars.count ? scalars[index + 2].value : 0
                    if !(afterDot >= 0x30 && afterDot <= 0x39) {
                        result.append("?")
                        result.append(".")
                        index += 2
                        canStartRegex = false
                        nextBraceIsObjectLiteral = false
                        pendingControlParen = false
                        pendingFunctionParenIsExpression = nil
                        pendingBodyBraceIsExpression = false
                        lastTokenWasDot = true
                        continue
                    }
                }
                if index + 1 < scalars.count, scalars[index + 1] == "?" {
                    result.append("?")
                    result.append("?")
                    index += 2
                    canStartRegex = true
                    nextBraceIsObjectLiteral = true
                    pendingControlParen = false
                    pendingFunctionParenIsExpression = nil
                    pendingBodyBraceIsExpression = false
                    lastTokenWasDot = false
                    continue
                }
                if !braceStack.isEmpty {
                    braceStack[braceStack.count - 1].pendingTernaryColons += 1
                } else {
                    topLevelTernaryColons += 1
                }
                canStartRegex = true
                nextBraceIsObjectLiteral = true
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                lastTokenWasDot = false
            } else if ch == ":" {
                let isTernaryColon: Bool
                if !braceStack.isEmpty {
                    if braceStack[braceStack.count - 1].pendingTernaryColons > 0 {
                        braceStack[braceStack.count - 1].pendingTernaryColons -= 1
                        isTernaryColon = true
                    } else {
                        isTernaryColon = false
                    }
                } else if topLevelTernaryColons > 0 {
                    topLevelTernaryColons -= 1
                    isTernaryColon = true
                } else {
                    isTernaryColon = false
                }
                let inObjectLiteral = braceStack.last?.isObjectLiteral ?? false
                canStartRegex = true
                nextBraceIsObjectLiteral = isTernaryColon || inObjectLiteral
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                popCurrentPendingClassBody()
                lastTokenWasDot = false
            } else if ch == "," || ch == "="
                        || ch == "!" || ch == "<" || ch == ">" || ch == "&" || ch == "|"
                        || ch == "^" || ch == "+" || ch == "-" || ch == "*" || ch == "%"
                        || ch == "/" || ch == "~" {
                canStartRegex = true
                nextBraceIsObjectLiteral = true
                pendingControlParen = false
                if ch != "*" {
                    pendingFunctionParenIsExpression = nil
                }
                if ch == "," || ch == "=" {
                    popCurrentPendingClassBody()
                }
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            } else {
                canStartRegex = false
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
            }

            result.append(ch)
            index += 1
        }

        return String(String.UnicodeScalarView(result))
    }

    private static func consumeTemplateLiteral(
        scalars: [UnicodeScalar],
        index: inout Int,
        result: inout [UnicodeScalar],
        interpolationDepths: inout [Int],
        braceStack: inout [BraceContext],
        canStartRegex: inout Bool,
        nextBraceIsObjectLiteral: inout Bool,
        pendingControlParen: inout Bool,
        pendingFunctionParenIsExpression: inout Bool?,
        pendingBodyBraceIsExpression: inout Bool,
        pendingArrowBlockBrace: inout Bool,
        lastTokenWasDot: inout Bool
    ) {
        while index < scalars.count {
            let c = scalars[index]
            index += 1
            if c == "\\", index < scalars.count {
                index += 1
                continue
            }
            if c == "`" {
                result.append(c)
                canStartRegex = false
                nextBraceIsObjectLiteral = false
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
                return
            }
            if c == "$", index < scalars.count, scalars[index] == "{" {
                index += 1
                result.append("$")
                result.append("{")
                interpolationDepths.append(0)
                braceStack.append(BraceContext(allowsRegexAfterClose: false, isObjectLiteral: false))
                canStartRegex = true
                nextBraceIsObjectLiteral = true
                pendingControlParen = false
                pendingFunctionParenIsExpression = nil
                pendingBodyBraceIsExpression = false
                pendingArrowBlockBrace = false
                lastTokenWasDot = false
                return
            }
        }
        canStartRegex = false
        nextBraceIsObjectLiteral = false
        pendingControlParen = false
        pendingFunctionParenIsExpression = nil
        pendingBodyBraceIsExpression = false
        pendingArrowBlockBrace = false
        lastTokenWasDot = false
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
    private static func skillReads(in rawText: String) -> [String] {
        guard rawText.contains(skillMarker) else { return [] }
        // JSON 里转义的 \/ 归一为 /，保证路径段切分稳定。
        let text = rawText.contains("\\/") ? rawText.replacingOccurrences(of: "\\/", with: "/") : rawText

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
