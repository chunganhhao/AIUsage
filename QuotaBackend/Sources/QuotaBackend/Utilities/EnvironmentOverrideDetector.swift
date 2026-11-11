import Foundation

/// Static inspection only: shell files are never sourced and values are never displayed.
public enum EnvironmentOverrideDetector {
    public static let keys: Set<String> = ["OPENAI_API_KEY", "OPENAI_BASE_URL", "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "GEMINI_API_KEY", "GOOGLE_API_KEY", "CODEX_HOME", "CLAUDE_CONFIG_DIR"]
    public struct Finding: Identifiable, Sendable {
        public let id: String
        public let key: String
        public let file: URL?
        public let line: Int?
        public let canRemove: Bool
        fileprivate let original: Data?
        fileprivate let replacement: Data?
    }
    public struct Undo: Sendable {
        fileprivate let file: URL
        fileprivate let before: Data
        fileprivate let after: Data
        public func restore() throws { try replace(file: file, expected: after, data: before) }
    }
    public static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            inherited: [String: String] = ProcessInfo.processInfo.environment) throws -> [Finding] {
        var result: [Finding] = []
        let regex = try NSRegularExpression(pattern: #"^\s*(?:export\s+)?([A-Z_][A-Z0-9_]*)\s*="#)
        for name in [".zshrc", ".zshenv", ".zprofile", ".bash_profile"] {
            let url = home.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { continue }
            let lines = text.components(separatedBy: "\n")
            let manualOnly = requiresManualShellEdit(text)
            for (index, line) in lines.enumerated() {
                guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                      let range = Range(match.range(at: 1), in: line), keys.contains(String(line[range])) else { continue }
                let key = String(line[range])
                // Do not remove commands/compound assignments or continuations under the guise of an env edit.
                let tail = String(line[Range(match.range, in: line)!.upperBound...]).trimmingCharacters(in: .whitespaces)
                let safe = !manualOnly && tail.range(of: #"^(?:[A-Za-z0-9_./:@%+,~=-]*|'[^'\r\n]*'|"[^"$`\\\r\n]*")\s*(?:#.*)?$"#, options: .regularExpression) != nil
                var updated = lines
                updated[index] = ": # Removed \(key) override by AIUsage (Undo available in this window)."
                result.append(Finding(id: "\(url.path):\(index)", key: key, file: url, line: index + 1, canRemove: safe,
                    original: data, replacement: safe ? Data(updated.joined(separator: "\n").utf8) : nil))
            }
        }
        let settings = home.appendingPathComponent(".claude/settings.json")
        if FileManager.default.fileExists(atPath: settings.path) {
            let data = try Data(contentsOf: settings)
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let env = json["env"] as? [String: Any] {
                for key in env.keys.sorted() where keys.contains(key) {
                    var copy = json; var vars = env; vars.removeValue(forKey: key); copy["env"] = vars
                    result.append(Finding(id: "\(settings.path):\(key)", key: key, file: settings, line: nil, canRemove: true,
                        original: data, replacement: try JSONSerialization.data(withJSONObject: copy, options: [.prettyPrinted, .sortedKeys])))
                }
            }
        }
        let agents = home.appendingPathComponent("Library/LaunchAgents")
        if FileManager.default.fileExists(atPath: agents.path) {
            for file in try FileManager.default.contentsOfDirectory(at: agents, includingPropertiesForKeys: nil) where file.pathExtension == "plist" {
                let data = try Data(contentsOf: file)
                if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], let env = plist["EnvironmentVariables"] as? [String: Any] {
                    for key in env.keys.sorted() where keys.contains(key) {
                        result.append(Finding(id: "\(file.path):\(key)", key: key, file: file, line: nil, canRemove: false, original: nil, replacement: nil))
                    }
                }
            }
        }
        for key in inherited.keys.sorted() where keys.contains(key) && inherited[key]?.isEmpty == false {
            result.append(Finding(id: "inherited:\(key)", key: key, file: nil, line: nil, canRemove: false, original: nil, replacement: nil))
        }
        return result
    }
    private static func requiresManualShellEdit(_ text: String) -> Bool {
        // Fail closed for shell constructs whose payload can look like an assignment; never source the file.
        if text.contains("<<") || text.contains("\\\n") || text.contains("\\\r\n") || text.contains("$(") || text.contains("`") || text.contains("$'") { return true }
        if text.contains("(") || text.contains(")") || text.range(of: #"\b(?:for|select)\b"#, options: .regularExpression) != nil { return true }
        var quote: Character?; var escaped = false; var comment = false; var previous: Character?
        for character in text {
            defer { previous = character }
            if character == "\n" || character == "\r" {
                if quote != nil { return true }
                comment = false; escaped = false; continue
            }
            if comment { continue }
            if escaped { escaped = false; continue }
            if character == "\\", quote != "'" { escaped = true; continue }
            if let current = quote {
                if character == current { quote = nil }
            } else if character == "#", previous == nil || previous.map({ " \t\r\n;|&()".contains($0) }) == true {
                comment = true
            } else if character == "\"" || character == "'" { quote = character }
        }
        return quote != nil
    }
    public static func remove(_ finding: Finding) throws -> Undo {
        guard finding.canRemove, let file = finding.file, let original = finding.original, let replacement = finding.replacement else { throw Failure.changed }
        try replace(file: file, expected: original, data: replacement)
        return Undo(file: file, before: original, after: replacement)
    }
    private static func replace(file: URL, expected: Data, data: Data) throws {
        try TokenSaverSettingsStore.rejectSymlinks(file)
        guard try Data(contentsOf: file) == expected else { throw Failure.changed }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try data.write(to: file, options: .atomic)
        if let mode = attributes[.posixPermissions] { try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: file.path) }
    }
    public enum Failure: LocalizedError {
        case changed
        public var errorDescription: String? { "File changed since inspection or cannot be safely edited. Rescan before editing. Undo never overwrites newer edits." }
    }
}
