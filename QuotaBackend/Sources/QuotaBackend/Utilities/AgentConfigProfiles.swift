import Foundation

public struct AgentConfigProfiles {
    public struct Profile: Codable, Identifiable, Sendable {
        public let name: String
        public let servers: [String: Bool]
        public let skills: [String: Bool]
        public var id: String { name }
        public init(name: String, servers: [String: Bool], skills: [String: Bool]) { self.name = name; self.servers = servers; self.skills = skills }
    }
    public struct Skill: Identifiable, Sendable {
        public let name: String
        public let enabled: Bool
        public let broken: Bool
        public var id: String { name }
    }
    public let mcp: AgentMCPStore
    public init(mcp: AgentMCPStore) { self.mcp = mcp }
    private var file: URL { mcp.home.appendingPathComponent("Library/Application Support/AIUsage/AgentConfig/\(mcp.platform.rawValue)-profiles.json") }
    private var disabledSkills: URL { mcp.skillsURL.appendingPathComponent(".aiusage-disabled") }
    public func profiles() throws -> [Profile] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try JSONDecoder().decode([Profile].self, from: Data(contentsOf: file))
    }
    public func skills() throws -> [Skill] {
        var result: [Skill] = []
        for (root, enabled) in [(mcp.skillsURL, true), (disabledSkills, false)] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            for item in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) {
                let link = try item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true
                let broken = link && !FileManager.default.fileExists(atPath: item.path)
                guard broken || FileManager.default.fileExists(atPath: item.appendingPathComponent("SKILL.md").path) else { continue }
                result.append(Skill(name: item.lastPathComponent, enabled: enabled, broken: broken))
            }
        }
        guard Set(result.map(\.name)).count == result.count else { throw AgentMCPStore.Failure.invalid("A skill exists both in the active and disabled folders. Rename or remove the duplicate before applying/saving a set.") }
        return result.sorted { $0.name < $1.name }
    }
    public func saveCurrent(name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { throw AgentMCPStore.Failure.invalid("Profile name must be 1–80 characters.") }
        let profile = Profile(name: trimmed, servers: Dictionary(uniqueKeysWithValues: try mcp.items().map { ($0.name, $0.enabled) }),
            skills: Dictionary(uniqueKeysWithValues: try skills().map { ($0.name, $0.enabled) }))
        var all = try profiles().filter { $0.name != trimmed }; all.append(profile)
        try TokenSaverSettingsStore.rejectSymlinks(file)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(all).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    public func setSkill(_ name: String, enabled: Bool) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.hasPrefix(".") else { throw AgentMCPStore.Failure.invalid("Invalid skill name.") }
        try TokenSaverSettingsStore.rejectSymlinks(mcp.skillsURL)
        try TokenSaverSettingsStore.rejectSymlinks(disabledSkills)
        guard let skill = try skills().first(where: { $0.name == name }), skill.enabled != enabled else { return }
        let source = (enabled ? disabledSkills : mcp.skillsURL).appendingPathComponent(name)
        let target = (enabled ? mcp.skillsURL : disabledSkills).appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path), (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) == nil else { throw AgentMCPStore.Failure.invalid("Skill target already exists; no files moved.") }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: target)
    }
    public func repairSkill(_ name: String, target: URL) throws {
        guard let skill = try skills().first(where: { $0.name == name }), skill.broken,
              FileManager.default.fileExists(atPath: target.appendingPathComponent("SKILL.md").path) else { throw AgentMCPStore.Failure.invalid("Choose an existing skill directory containing SKILL.md.") }
        let link = (skill.enabled ? mcp.skillsURL : disabledSkills).appendingPathComponent(name)
        try TokenSaverSettingsStore.rejectSymlinks(link.deletingLastPathComponent())
        let old = try FileManager.default.destinationOfSymbolicLink(atPath: link.path)
        let temporary = link.deletingLastPathComponent().appendingPathComponent(".repair-" + UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: target.resolvingSymlinksInPath())
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard !FileManager.default.fileExists(atPath: link.path), try FileManager.default.destinationOfSymbolicLink(atPath: link.path) == old,
              rename(temporary.path, link.path) == 0 else { throw AgentMCPStore.Failure.invalid("Skill changed during repair. Rescan.") }
    }
    public func apply(_ profile: Profile) throws {
        let oldMCP = try mcp.items(); let oldSkills = try skills()
        var undo: [() throws -> Void] = []
        do {
            for item in oldMCP {
                guard let enabled = profile.servers[item.name], enabled != item.enabled else { continue }
                try mcp.setEnabled(item.name, enabled: enabled)
                undo.append { try mcp.setEnabled(item.name, enabled: item.enabled) }
            }
            for item in oldSkills {
                guard let enabled = profile.skills[item.name], enabled != item.enabled else { continue }
                try setSkill(item.name, enabled: enabled)
                undo.append { try setSkill(item.name, enabled: item.enabled) }
            }
        } catch {
            var failed = false
            for action in undo.reversed() { do { try action() } catch { failed = true } }
            if failed { throw AgentMCPStore.Failure.invalid("Profile apply failed and rollback was incomplete. Inspect MCP/skill state before retrying.") }
            throw error
        }
    }
}
