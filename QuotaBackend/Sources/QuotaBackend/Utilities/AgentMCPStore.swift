import Foundation
import Security

public struct MCPSecretVault {
    public let put: (String, String) throws -> Void
    public let get: (String) throws -> String?
    public let delete: (String) throws -> Void
    public static let service = "com.aiusage.mcp"
    public static let keychain = Self(put: { account, value in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemAdd(query.merging([kSecValueData as String: Data(value.utf8), kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 } as CFDictionary, nil)
        if status == errSecDuplicateItem {
            guard SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(value.utf8)] as CFDictionary) == errSecSuccess else { throw AgentMCPStore.Failure.invalid("Keychain update failed.") }
        } else if status != errSecSuccess { throw AgentMCPStore.Failure.invalid("Keychain write failed (\(status)).") }
    }, get: { account in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne, kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let value = String(data: data, encoding: .utf8) else { throw AgentMCPStore.Failure.invalid("Keychain read failed.") }
        return value
    }, delete: { account in
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentMCPStore.Failure.invalid("Keychain delete failed.") }
    })
    public init(put: @escaping (String, String) throws -> Void, get: @escaping (String) throws -> String?, delete: @escaping (String) throws -> Void) {
        self.put = put; self.get = get; self.delete = delete
    }
}

public struct AgentMCPStore {
    public enum Platform: String, CaseIterable, Codable, Sendable { case codex, antigravity, claude }
    public struct Server: Codable, Equatable, Sendable {
        public let name: String
        public let command: String
        public let args: [String]
        public let env: [String: String]
        public init(name: String, command: String, args: [String] = [], env: [String: String] = [:]) {
            self.name = name; self.command = command; self.args = args; self.env = env
        }
    }
    public struct Item: Identifiable, Sendable {
        public var id: String { name }
        public let name: String
        public let enabled: Bool
        public let health: String?
        public let canAuthorizeKeychain: Bool
    }
    public let home: URL
    public let platform: Platform
    public let vault: MCPSecretVault
    private var support: URL { home.appendingPathComponent("Library/Application Support/AIUsage/AgentConfig") }
    public var configURL: URL {
        home.appendingPathComponent(platform == .codex ? ".codex/config.toml" : platform == .antigravity ? ".gemini/antigravity/mcp_config.json" : ".claude.json")
    }
    public var skillsURL: URL { home.appendingPathComponent(platform == .codex ? ".codex/skills" : platform == .antigravity ? ".gemini/antigravity/skills" : ".claude/skills") }
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser, platform: Platform, vault: MCPSecretVault = .keychain) { self.home = home; self.platform = platform; self.vault = vault }
    public enum Failure: LocalizedError {
        case invalid(String)
        public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    private func account(_ name: String) -> String { "disabled:\(home.path):\(platform.rawValue):\(name)" }
    private var indexURL: URL { support.appendingPathComponent("\(platform.rawValue)-disabled.json") }
    private func disabledNames() throws -> Set<String> {
        try TokenSaverSettingsStore.rejectSymlinks(indexURL)
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return [] }
        return Set(try JSONDecoder().decode([String].self, from: Data(contentsOf: indexURL)))
    }
    private func saveIndex(_ names: Set<String>) throws { try write(try JSONEncoder().encode(names.sorted()), to: indexURL) }
    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 160 && name.range(of: #"^[A-Za-z0-9_.-]+$"#, options: .regularExpression) != nil && name != "." && name != ".."
    }
    private static func jsonData<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func table(_ line: String) throws -> (name: String, root: Bool)? {
        guard line.hasPrefix("[mcp_servers.") else { return nil }
        let regex = try NSRegularExpression(pattern: #"^\[mcp_servers\.(?:"([^"\\]+)"|'([^']+)'|([A-Za-z0-9_-]+))(\.[A-Za-z0-9_.-]+)?\]$"#)
        guard let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) else { throw Failure.invalid("Unsupported MCP TOML table name.") }
        let name = (1...3).compactMap { Range(match.range(at: $0), in: line).map { String(line[$0]) } }.first!
        guard validName(name) else { throw Failure.invalid("Invalid MCP name.") }
        return (name, match.range(at: 4).location == NSNotFound)
    }
    private static func codexEnabled(_ record: String) -> Bool {
        var inRoot = false
        for raw in record.components(separatedBy: "\n") {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { inRoot = (try? table(line)?.root) == true }
            if inRoot, line.range(of: #"^enabled\s*=\s*false$"#, options: .regularExpression) != nil { return false }
        }
        return true
    }
    private static func codexRecord(_ record: String, enabled: Bool) -> String {
        var inRoot = false; var inserted = false; var lines: [String] = []
        for raw in record.components(separatedBy: "\n") {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inRoot = (try? table(line)?.root) == true
                lines.append(raw)
                if inRoot, !inserted { lines.append("enabled = \(enabled)"); inserted = true }
                continue
            }
            if inRoot, line.range(of: #"^enabled\s*="#, options: .regularExpression) != nil { continue }
            lines.append(raw)
        }
        return lines.joined(separator: "\n")
    }
    private static func quote(_ value: String) -> String { String(decoding: try! jsonData(value), as: UTF8.self) }
    private static func shell(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'" }

    /// Paste-safe JSON or common TOML server tables. Unsupported syntax fails explicitly, never guesses.
    public static func parse(_ pasted: String) throws -> [Server] {
        var text = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            var lines = text.components(separatedBy: "\n")
            guard lines.count >= 3, lines.last?.hasPrefix("```") == true else { throw Failure.invalid("Unclosed code fence.") }
            lines.removeFirst(); lines.removeLast(); text = lines.joined(separator: "\n")
        }
        if text.hasPrefix("{") {
            guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw Failure.invalid("Expected MCP object.") }
            let map = json["mcpServers"] as? [String: Any] ?? json["mcp_servers"] as? [String: Any] ?? json
            return try map.keys.sorted().map { name in
                guard validName(name), let entry = map[name] as? [String: Any], let command = entry["command"] as? String,
                      !command.isEmpty, !command.contains("\0"),
                      entry["args"] == nil || entry["args"] is [String], entry["env"] == nil || entry["env"] is [String: String] else { throw Failure.invalid("Each MCP server needs a name, command, string args and string env. Remote URLs are not stdio commands.") }
                let env = entry["env"] as? [String: String] ?? [:]
                guard env.keys.allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }) else { throw Failure.invalid("Invalid environment key.") }
                return Server(name: name, command: command, args: entry["args"] as? [String] ?? [], env: env)
            }
        }
        let blocks = try tomlBlocks(text)
        guard !blocks.isEmpty else { throw Failure.invalid("Paste mcpServers JSON or [mcp_servers.NAME] TOML tables.") }
        return try blocks.keys.sorted().map { name in
            var command: String?; var args: [String] = []; var env: [String: String] = [:]; var inEnv = false
            for raw in blocks[name]!.components(separatedBy: "\n") {
                let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                if line.hasPrefix("[") { inEnv = line.hasSuffix(".env]"); continue }
                let fields = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count == 2 else { throw Failure.invalid("Unsupported TOML MCP assignment.") }
                let key = fields[0]
                let value = fields[1]
                if inEnv { env[key] = try tomlString(value) }
                else if key == "command" { command = try tomlString(value) }
                else if key == "args", let decoded = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) { args = decoded }
                else if key == "enabled" || key == "startup_timeout_sec" || key == "tool_timeout_sec" { continue }
                else { throw Failure.invalid("Unsupported TOML field or multiline value. Paste JSON for complex configurations.") }
            }
            guard let command, !command.isEmpty, env.keys.allSatisfy({ $0.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil }) else { throw Failure.invalid("Missing command or invalid env key.") }
            return Server(name: name, command: command, args: args, env: env)
        }
    }
    private static func tomlString(_ value: String) throws -> String {
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 { return String(value.dropFirst().dropLast()) }
        guard let decoded = try? JSONDecoder().decode(String.self, from: Data(value.utf8)) else { throw Failure.invalid("Expected a quoted TOML string.") }
        return decoded
    }
    private static func stripComment(_ raw: String) -> String {
        var quote: Character?; var escaped = false; var out = ""
        for ch in raw {
            if escaped { out.append(ch); escaped = false; continue }
            if ch == "\\", quote == "\"" { escaped = true; out.append(ch); continue }
            if let current = quote { if ch == current { quote = nil } }
            else if ch == "\"" || ch == "'" { quote = ch }
            else if ch == "#" { break }
            out.append(ch)
        }
        return out
    }
    private static func tomlBlocks(_ text: String) throws -> [String: String] {
        var result: [String: String] = [:]; var current: String?
        for raw in text.components(separatedBy: "\n") {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                current = nil
                if let parsed = try table(line) { current = parsed.name }
            }
            if let current { result[current, default: ""] += raw + "\n" }
        }
        return result
    }
    private func readConfig() throws -> Data {
        try TokenSaverSettingsStore.rejectSymlinks(configURL)
        return FileManager.default.fileExists(atPath: configURL.path) ? try Data(contentsOf: configURL) : Data((platform == .codex ? "" : "{}").utf8)
    }
    private func records(_ data: Data) throws -> [String: String] {
        guard let text = String(data: data, encoding: .utf8) else { throw Failure.invalid("Config is not UTF-8.") }
        if platform == .codex { return try Self.tomlBlocks(text) }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], json["mcpServers"] == nil || json["mcpServers"] is [String: Any] else { throw Failure.invalid("Invalid MCP config.") }
        return try (json["mcpServers"] as? [String: Any] ?? [:]).mapValues { value in
            guard let object = value as? [String: Any] else { throw Failure.invalid("Invalid server entry.") }
            return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        }
    }
    private func replacing(_ data: Data, name: String, with record: String?) throws -> Data {
        if platform == .codex {
            var removing = false
            var retained: [String] = []
            for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\n") {
                let trimmed = Self.stripComment(line).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") {
                    removing = try Self.tomlBlocks(line).keys.contains(name)
                }
                if !removing { retained.append(line) }
            }
            var text = retained.joined(separator: "\n")
            if let record { text += "\n" + record + "\n" }
            return Data(text.utf8)
        }
        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var map = json["mcpServers"] as? [String: Any] ?? [:]
        if let record { map[name] = try JSONSerialization.jsonObject(with: Data(record.utf8)) } else { map.removeValue(forKey: name) }
        json["mcpServers"] = map
        return try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    }
    private func write(_ data: Data, to url: URL) throws {
        try TokenSaverSettingsStore.rejectSymlinks(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    private func commit(_ after: Data, original: Data) throws {
        guard try readConfig() == original else { throw Failure.invalid("MCP config changed during edit. Rescan before retrying.") }
        try write(after, to: configURL)
    }
    private struct LauncherInfo: Codable {
        let command: String
        let accounts: [String]
    }
    private static func codexHealthEntry(_ record: String, name: String) throws -> (entry: Server?, remote: Bool) {
        var root = false; var envTable = false
        var command: String?; var url: String?; var env: [String: String] = [:]
        for raw in record.components(separatedBy: "\n") {
            let line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { root = try table(line)?.root == true; envTable = line.hasSuffix(".env]"); continue }
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2 else { continue }
            if root && pair[0] == "command" { command = try tomlString(pair[1]) }
            if root && pair[0] == "url" { url = try tomlString(pair[1]) }
            if envTable { env[pair[0]] = try tomlString(pair[1]) }
        }
        let remote = url.flatMap(URL.init(string:)).map { ["http", "https"].contains($0.scheme ?? "") && $0.host != nil } ?? false
        return (command.map { Server(name: name, command: $0, env: env) }, remote)
    }
    public func items(path: String = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin") throws -> [Item] {
        let active = try records(readConfig()); let names = Set(active.keys).union(try disabledNames())
        return names.sorted().map { name in
            let enabled = active[name].map { record in
                if platform == .codex { return Self.codexEnabled(record) }
                guard let object = try? JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any] else { return false }
                return object["disabled"] as? Bool != true && object["enabled"] as? Bool != false
            } ?? false
            var health: String?
            var canAuthorizeKeychain = false
            if let record = active[name] {
                let entry: Server?
                var remote = false
                if platform == .codex {
                    let result = try? Self.codexHealthEntry(record, name: name)
                    entry = result?.entry; remote = result?.remote ?? false
                } else { entry = try? Self.parse("{\(Self.quote(name)):\(record)}").first }
                if let entry {
                    var command = entry.command
                    var required: [String] = []
                    if command.hasPrefix(support.appendingPathComponent("launchers").path + "/") {
                        if let data = try? Data(contentsOf: URL(fileURLWithPath: command + ".json")), let info = try? JSONDecoder().decode(LauncherInfo.self, from: data) {
                            command = info.command; required = info.accounts; canAuthorizeKeychain = !required.isEmpty
                        } else { health = "Inspect launcher configuration" }
                    }
                    let candidates = command.hasPrefix("/") ? [command] : path.split(separator: ":").map { String($0) + "/" + command }
                    if !candidates.contains(where: FileManager.default.isExecutableFile(atPath:)) { health = "Command not found" }
                    else if entry.env.values.contains(where: { $0.isEmpty || $0.hasPrefix("${") || $0.hasPrefix("YOUR_") }) { health = "Missing Key" }
                    else {
                        for account in required {
                            do {
                                guard let value = try vault.get(account), !value.isEmpty, !value.hasPrefix("YOUR_"), !value.hasPrefix("${") else { health = "Missing Key"; break }
                            } catch { health = "Keychain access needs authorization"; break }
                        }
                    }
                } else if !remote { health = "Inspect configuration" }
            }
            return Item(name: name, enabled: enabled, health: health, canAuthorizeKeychain: canAuthorizeKeychain)
        }
    }
    /// Explicit foreground check runs only Apple's reader, never the imported MCP command.
    public func verifyKeychainAccess(name: String, reader: @Sendable ([String]) async throws -> Void = Self.authorizeKeychainReader) async throws {
        guard let record = try records(readConfig())[name] else { throw Failure.invalid("Server is not enabled.") }
        let command = platform == .codex ? try Self.codexHealthEntry(record, name: name).entry?.command : (try? Self.parse("{\(Self.quote(name)):\(record)}").first?.command)
        guard let command, command.hasPrefix(support.appendingPathComponent("launchers").path + "/") else { throw Failure.invalid("Only AIUsage-managed Keychain launchers can be checked.") }
        let infoURL = URL(fileURLWithPath: command + ".json")
        try TokenSaverSettingsStore.rejectSymlinks(infoURL)
        let info = try JSONDecoder().decode(LauncherInfo.self, from: Data(contentsOf: infoURL))
        for account in info.accounts {
            guard account.hasPrefix("env:"), account.count < 256 else { throw Failure.invalid("Invalid launcher Keychain account.") }
            try await reader(["find-generic-password", "-s", MCPSecretVault.service, "-a", account, "-w"])
        }
    }
    public static func authorizeKeychainReader(_ arguments: [String]) async throws {
        guard arguments.count == 6, arguments[0] == "find-generic-password", arguments[1] == "-s",
              arguments[2] == MCPSecretVault.service, arguments[3] == "-a", arguments[4].hasPrefix("env:"), arguments[5] == "-w" else {
            throw Failure.invalid("Only the AIUsage MCP Keychain reader is allowed.")
        }
        let worker = Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            process.terminationHandler = { _ in }
            try process.run()
            let deadline = Date().addingTimeInterval(60)
            while process.isRunning {
                if Task.isCancelled || Date() >= deadline {
                    process.terminate()
                    for _ in 0..<10 { if !process.isRunning { break }; try? await Task.sleep(nanoseconds: 50_000_000) }
                    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    throw Failure.invalid("Keychain check cancelled/timed out. No MCP command was started.")
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            guard process.terminationStatus == 0 else { throw Failure.invalid("Keychain access was denied or the item is unavailable. Authorize the reader in the macOS prompt and retry explicitly.") }
        }
        try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
    private static func enabledJSON(_ record: String) throws -> String {
        guard var object = try JSONSerialization.jsonObject(with: Data(record.utf8)) as? [String: Any] else { throw Failure.invalid("Invalid saved MCP object.") }
        if object["disabled"] != nil { object["disabled"] = false }
        if object["enabled"] != nil { object["enabled"] = true }
        return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
    }
    public func setEnabled(_ name: String, enabled: Bool) throws {
        guard Self.validName(name) else { throw Failure.invalid("Invalid server name.") }
        let original = try readConfig(); let map = try records(original); var disabled = try disabledNames()
        if platform == .codex, let record = map[name] {
            try commit(try replacing(original, name: name, with: Self.codexRecord(record, enabled: enabled)), original: original)
            return
        }
        if enabled {
            if let existing = map[name] {
                try commit(try replacing(original, name: name, with: Self.enabledJSON(existing)), original: original)
                return
            }
            guard let saved = try vault.get(account(name)) else { throw Failure.invalid("Disabled server backup missing from Keychain.") }
            // Keep the saved catalog entry through commit. A crash must not orphan its encrypted backup.
            // Active config takes precedence over the catalog when deriving the toggle state.
            try commit(try replacing(original, name: name, with: Self.enabledJSON(saved)), original: original)
            // Retain encrypted backup for crash recovery; active config is authoritative.
        } else {
            guard let record = map[name] else { return }
            try vault.put(account(name), record)
            disabled.insert(name); try saveIndex(disabled)
            try commit(try replacing(original, name: name, with: nil), original: original)
        }
    }
    public func importServers(_ servers: [Server]) throws {
        let original = try readConfig(); let existing = try records(original)
        guard !servers.isEmpty, Set(servers.map(\.name)).count == servers.count,
              servers.allSatisfy({ Self.validName($0.name) && existing[$0.name] == nil }) else { throw Failure.invalid("Duplicate/existing server name. Rename before importing; existing entries are never overwritten.") }
        var output = original; var secrets: [String] = []; var launchers: [URL] = []
        do {
            for server in servers {
                let token = UUID().uuidString
                let launcher = support.appendingPathComponent("launchers/\(token).sh")
                var script = "#!/bin/sh\nset -eu\n"
                for key in server.env.keys.sorted() {
                    guard key.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else { throw Failure.invalid("Invalid env key.") }
                    let account = "env:\(token):\(key)"
                    try vault.put(account, server.env[key]!); secrets.append(account)
                    script += "\(key)=$(/usr/bin/security find-generic-password -s \(Self.shell(MCPSecretVault.service)) -a \(Self.shell(account)) -w)\nexport \(key)\n"
                }
                script += "exec \(Self.shell(server.command)) \"$@\"\n"
                if !server.env.isEmpty {
                    try write(Data(script.utf8), to: launcher); launchers.append(launcher)
                    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: launcher.path)
                    let infoFile = URL(fileURLWithPath: launcher.path + ".json")
                    try write(try JSONEncoder().encode(LauncherInfo(command: server.command, accounts: server.env.keys.sorted().map { "env:\(token):\($0)" })), to: infoFile)
                    launchers.append(infoFile)
                }
                let command = server.env.isEmpty ? server.command : launcher.path
                let record: String
                if platform == .codex {
                    record = "[mcp_servers.\(Self.quote(server.name))]\ncommand = \(Self.quote(command))\nargs = \(String(decoding: try Self.jsonData(server.args), as: UTF8.self))\n"
                } else {
                    record = String(decoding: try JSONSerialization.data(withJSONObject: ["command": command, "args": server.args]), as: UTF8.self)
                }
                output = try replacing(output, name: server.name, with: record)
            }
            try commit(output, original: original)
        } catch {
            for account in secrets { try? vault.delete(account) }
            for launcher in launchers { try? FileManager.default.removeItem(at: launcher) }
            throw error
        }
    }
}
