import Foundation

/// Opt-in only. A corrupt file must never enable compression or broaden scope.
public struct TokenSaverSettings: Codable, Equatable, Sendable {
    public enum CavemanMode: String, Codable, CaseIterable, Sendable { case lite, full, ultra }
    public var rtkEnabled = false
    public var cavemanEnabled = false
    public var cavemanMode: CavemanMode = .full
    public var ponytailEnabled = false
    public let codingOnlyScope = true
    public init() {}

    enum CodingKeys: String, CodingKey {
        case rtkEnabled, cavemanEnabled, cavemanMode, ponytailEnabled, codingOnlyScope
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rtkEnabled = try c.decodeIfPresent(Bool.self, forKey: .rtkEnabled) ?? false
        cavemanEnabled = try c.decodeIfPresent(Bool.self, forKey: .cavemanEnabled) ?? false
        cavemanMode = try c.decodeIfPresent(CavemanMode.self, forKey: .cavemanMode) ?? .full
        ponytailEnabled = try c.decodeIfPresent(Bool.self, forKey: .ponytailEnabled) ?? false
        // Intentionally ignore a false codingOnlyScope in old/edited settings.
    }
}

public enum TokenSaverSettingsStore {
    private static let lock = NSRecursiveLock()
    public static func settingsURL(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/AIUsage/token-saver-settings.json")
    }
    public static func load(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> TokenSaverSettings {
        lock.lock(); defer { lock.unlock() }
        let url = settingsURL(home: home)
        guard let data = try contents(url) else { return .init() }
        return try JSONDecoder().decode(TokenSaverSettings.self, from: data)
    }
    public static func save(_ settings: TokenSaverSettings, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = try load(home: home)
        let url = settingsURL(home: home)
        try rejectSymlinks(url)
        let blockURL = settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("token-saver-managed-block.txt")
        let ledgerData = try contents(blockURL)
        guard ledgerData == nil || String(data: ledgerData!, encoding: .utf8) != nil else { throw Failure.changed }
        let oldBlock = ledgerData.flatMap { String(data: $0, encoding: .utf8) } ?? TokenSaverAgentRules.block(previous)
        let newBlock = try TokenSaverAgentRules.block(settings, home: home)
        var changes = try TokenSaverAgentRules.changes(from: oldBlock, to: newBlock, home: home)
        let wrapper = settingsURL(home: home).deletingLastPathComponent().appendingPathComponent("bin/token-saver-rtk")
        let wrapperBefore = try contents(wrapper)
        let wrapperAfter = settings.rtkEnabled ? Data(TokenSaverAgentRules.rtkWrapper.utf8) : nil
        if wrapperBefore != wrapperAfter {
            guard wrapperBefore == nil || wrapperBefore == Data(TokenSaverAgentRules.rtkWrapper.utf8) else { throw Failure.changed }
            changes.append((wrapper, wrapperBefore, wrapperAfter))
        }
        let oldLedger = try contents(blockURL)
        changes.append((blockURL, oldLedger, newBlock.isEmpty ? nil : Data(newBlock.utf8)))
        let settingsBefore = try contents(url)
        var applied: [(URL, Data?, Data?)] = []
        do {
            for (target, before, after) in changes {
                guard try contents(target) == before else { throw Failure.changed }
                try replace(target, data: after)
                applied.append((target, before, after))
                if target == wrapper, after != nil {
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: target.path)
                }
            }
            guard try contents(url) == settingsBefore else { throw Failure.changed }
            try replace(url, data: JSONEncoder().encode(settings))
        } catch {
            for (target, before, after) in applied.reversed() {
                if (try? contents(target)) == after { try? replace(target, data: before) }
            }
            throw error
        }
    }
    static func contents(_ url: URL) throws -> Data? {
        try rejectSymlinks(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }
    static func rejectSymlinks(_ url: URL) throws {
        var path = url.standardizedFileURL
        while path.path != "/" {
            // macOS system aliases are root-owned; URL canonicalization maps /private/var back to /var.
            if let expected = ["/var": "private/var", "/tmp": "private/tmp"][path.path] {
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: path.path)
                guard (attributes[.ownerAccountID] as? NSNumber)?.intValue == 0,
                      target == expected || target == "/" + expected else { throw Failure.symlink }
                break
            }
            if (try? path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw Failure.symlink }
            path.deleteLastPathComponent()
        }
    }
    static func replace(_ url: URL, data: Data?) throws {
        try rejectSymlinks(url)
        let fm = FileManager.default
        if let data {
            let permissions = (try? fm.attributesOfItem(atPath: url.path)[.posixPermissions]) ?? 0o600
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path)
        } else if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
    }
    enum Failure: LocalizedError {
        case changed, symlink
        var errorDescription: String? {
            switch self {
            case .changed: "Token Saver rule was edited externally. Preserve it and resolve the AIUsage managed block before retrying."
            case .symlink: "Token Saver will not replace symlinked settings or rules."
            }
        }
    }
}

/// Adds only an owned block. Existing instructions are never replaced.
public enum TokenSaverAgentRules {
    public static let rtkWrapper = """
    #!/bin/zsh
    # AIUsage-owned explicit RTK wrapper. No aliases, PATH mutation or retry.
    set -eu
    if (( $# == 0 )); then exit 64; fi
    if command -v rtk >/dev/null 2>&1; then
        exec rtk "$@"
    fi
    exec "$@"
    """ + "\n"
    static let begin = "<!-- AIUsage Token Saver BEGIN -->"
    static let end = "<!-- AIUsage Token Saver END -->"
    public static func rulePaths(home: URL) -> [URL] {
        [".gemini/antigravity/rules/aiusage-token-saver.md", ".claude/rules/aiusage-token-saver.md",
         ".codex/AGENTS.md", ".config/opencode/AGENTS.md"].map { home.appendingPathComponent($0) }
    }
    public static func block(_ s: TokenSaverSettings) -> String {
        // Built-in policy remains usable before downloading any upstream skill.
        (try? block(s, home: nil)) ?? ""
    }
    static func block(_ s: TokenSaverSettings, home: URL?) throws -> String {
        guard s.rtkEnabled || s.cavemanEnabled || s.ponytailEnabled else { return "" }
        var sections = [begin, "# Token Saver — coding work only",
            "Apply ALL instructions below ONLY while implementing, testing, reviewing or debugging source code.",
            "Bypass these rules for RonC scripts, lyrics, creative writing, Zalo/customer-care responses and all non-coding work. Never alter those tasks' tone or output."]
        if s.rtkEnabled {
            if let home {
                let wrapper = settingsPathForWrapper(home)
                sections.append("Antigravity run_command (zsh), Claude Code, Codex and OpenCode: use the explicit managed zsh wrapper `\(wrapper)` followed by a supported command, e.g. git status. Quote its path because it contains spaces. It uses RTK when available, otherwise runs the original command exactly once. It does not install binaries or modify PATH.")
            }
            sections.append("For coding shell commands, when `command -v rtk` succeeds, prefer `rtk git status`, `rtk git diff`, `rtk git log`, `rtk ls`, `rtk grep` and `rtk pytest` where supported by `rtk --help`. Antigravity: use run_command (zsh). Claude Code, Codex and OpenCode: use the same explicit RTK commands. Do not change aliases/PATH, wrap unsupported commands, hide failures or truncate diagnostic evidence. If RTK is absent, use the original command and report it.")
        }
        for tool in [TokenSaverReleaseTool.caveman, .ponytail] {
            let enabled = tool == .caveman ? s.cavemanEnabled : s.ponytailEnabled
            guard enabled else { continue }
            if let home, let staged = try TokenSaverReleaseStore(root: home.appendingPathComponent("Library/Application Support/AIUsage/Rules")).staged(tool),
               let text = String(data: staged.markdown, encoding: .utf8) {
                guard !text.contains(begin), !text.contains(end) else { throw TokenSaverSettingsStore.Failure.changed }
                sections.append("## \(tool.title) upstream rules (coding scope above overrides general applicability)\n" + text)
            }
            if tool == .caveman {
                let mode: String
                switch s.cavemanMode {
                case .lite: mode = "Concise natural sentences. Drop greetings and filler, retain essential explanations."
                case .full: mode = "Terse direct prose. Omit filler and repetition; keep required context and actionable facts."
                case .ultra: mode = "Minimum prose: compact bullets or fragments. Never sacrifice correctness, necessary caveats or instructions."
                }
                sections.append("Caveman active mode: \(s.cavemanMode.rawValue). \(mode) Preserve code, paths, commands, error messages, security warnings and user-requested detail exactly. This mode overrides any default in the upstream rule.")
            } else {
                sections.append("Ponytail: question unnecessary work (YAGNI), reuse project helpers, then stdlib/native features and existing dependencies. Prefer minimal correct code and deletion over speculative abstractions. Trace root cause and verify changes; never remove validation, security, accessibility or required behavior.")
            }
        }
        sections.append("Scope reminder: ALL preceding Token Saver policies are coding-only. RonC, Zalo, creative and non-coding tasks are excluded. No request/response or signed history rewriting.")
        sections.append(end)
        return sections.joined(separator: "\n")
    }
    private static func settingsPathForWrapper(_ home: URL) -> String {
        // Shell single-quote escaping protects user home paths with spaces or quotes.
        let path = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk").path
        return "'" + path.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
    static func changes(from oldBlock: String, to newBlock: String, home: URL) throws -> [(URL, Data?, Data?)] {
        guard oldBlock != newBlock else { return [] }
        return try rulePaths(home: home).map { url in
            let before = try TokenSaverSettingsStore.contents(url)
            guard var text = before.flatMap({ String(data: $0, encoding: .utf8) }) ?? (before == nil ? "" : nil) else {
                throw TokenSaverSettingsStore.Failure.changed
            }
            if text.contains(begin) || text.contains(end) {
                let owned = "\n" + oldBlock
                guard !oldBlock.isEmpty, text.components(separatedBy: owned).count == 2,
                      text.components(separatedBy: begin).count == 2,
                      text.components(separatedBy: end).count == 2 else {
                    throw TokenSaverSettingsStore.Failure.changed
                }
                text = text.replacingOccurrences(of: owned, with: newBlock.isEmpty ? "" : "\n" + newBlock)
            } else if !newBlock.isEmpty {
                text += "\n" + newBlock
            }
            return (url, before, text.isEmpty ? nil : Data(text.utf8))
        }
    }
}
