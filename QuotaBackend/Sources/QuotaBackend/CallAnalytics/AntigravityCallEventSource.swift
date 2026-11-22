import Foundation

/// Read-only projection of Antigravity's exported transcripts; never executes tool arguments.
final class AntigravityCallEventSource {
    let homeDirectory: String
    let timeZone: TimeZone

    private struct CachedFile {
        let modified: Date
        let size: Int
        let inode: UInt64
        let entries: [CallAnalyticsEntry]
    }
    private var cachedServers: Set<String> = []
    private var cache: [String: CachedFile] = [:]
    private(set) var lastFilesRead = 0
    init(homeDirectory: String, timeZone: TimeZone) { self.homeDirectory = homeDirectory; self.timeZone = timeZone }

    func collect(cutoff: Date? = nil, rescan: Bool = false, knownMCPServers: Set<String> = []) -> (entries: [CallAnalyticsEntry], status: CallSourceStatus) {
        let root = URL(fileURLWithPath: homeDirectory).appendingPathComponent(".gemini/antigravity/brain").resolvingSymlinksInPath()
        guard let sessions = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else {
            return ([], .init(source: .antigravity, available: false, eventCount: 0, filesScanned: 0, errorCode: nil))
        }
        let clock = CallAnalyticsClock(timeZone: timeZone)
        if rescan || cachedServers != knownMCPServers { cache.removeAll(); cachedServers = knownMCPServers }
        lastFilesRead = 0
        var entries: [CallAnalyticsEntry] = []
        var currentPaths = Set<String>()
        let servers = knownMCPServers.sorted { $0.count > $1.count }
        var scanned = 0
        for session in sessions {
            let file = session.appendingPathComponent(".system_generated/logs/transcript.jsonl")
            currentPaths.insert(file.path)
            guard FileManager.default.isReadableFile(atPath: file.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
                  let modified = attributes[.modificationDate] as? Date, let size = attributes[.size] as? Int,
                  let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value else { continue }
            if let cutoff, modified < cutoff { continue }
            scanned += 1
            if let cached = cache[file.path], cached.modified == modified, cached.size == size, cached.inode == inode {
                entries.append(contentsOf: cached.entries); continue
            }
            lastFilesRead += 1
            var accumulator = CallEventAccumulator()
            var seenCalls = Set<String>()
            CallAnalyticsLineReader.forEachLine(path: file.path, needles: [Data("\"tool_calls\"".utf8)], maxLineBytes: 4 * 1024 * 1024) { data in
                guard let row = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let calls = row["tool_calls"] as? [[String: Any]],
                      let stamp = row["created_at"] as? String, let date = clock.date(fromISO: stamp) else { return }
                for (index, call) in calls.enumerated() {
                    if let step = row["step_index"] as? Int, !seenCalls.insert("\(step):\(index)").inserted { continue }
                    guard let name = call["name"] as? String, !name.isEmpty else { continue }
                    let args = call["args"] as? [String: Any] ?? [:]
                    let day = clock.dayKey(date)
                    if name == "call_mcp_tool", let server = Self.stringArgument(args["ServerName"]), let tool = Self.stringArgument(args["ToolName"]) {
                        accumulator.add(source: .antigravity, kind: .mcp, name: "\(server)/\(tool)", server: server, dayKey: day)
                    } else if let server = servers.first(where: { name.hasPrefix("mcp_" + $0 + "_") }) {
                        let tool = String(name.dropFirst(server.count + 5))
                        accumulator.add(source: .antigravity, kind: .mcp, name: "\(server)/\(tool)", server: server, dayKey: day)
                    } else {
                        accumulator.add(source: .antigravity, kind: .builtin, name: name, server: nil, dayKey: day)
                    }
                    // Only explicit file reads count as skill loads, not paths mentioned in prompts/output.
                    if (name == "view_file" || name == "read_file"), let path = Self.stringArgument(args["AbsolutePath"] ?? args["Path"]),
                       path.hasSuffix("/SKILL.md"), !path.contains(where: { "*?[]".contains($0) }) {
                        accumulator.add(source: .antigravity, kind: .skill,
                            name: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
                            server: nil, dayKey: day)
                    }
                }
            }
            let parsed = accumulator.entries()
            entries.append(contentsOf: parsed)
            if let after = try? FileManager.default.attributesOfItem(atPath: file.path),
               after[.modificationDate] as? Date == modified, after[.size] as? Int == size,
               (after[.systemFileNumber] as? NSNumber)?.uint64Value == inode {
                cache[file.path] = CachedFile(modified: modified, size: size, inode: inode, entries: parsed)
            } else { cache.removeValue(forKey: file.path) }
        }
        cache = cache.filter { currentPaths.contains($0.key) }
        return (entries, .init(source: .antigravity, available: true, eventCount: entries.reduce(0) { $0 + $1.count }, filesScanned: scanned, errorCode: nil))
    }
    private static func stringArgument(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        // Exports encode each argument separately; older fixtures/exports use plain strings.
        return (try? JSONSerialization.jsonObject(with: Data(raw.utf8), options: .fragmentsAllowed)) as? String ?? raw
    }

}
