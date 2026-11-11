import Foundation

public struct RTKVersionStore: Sendable {
    public struct Version: Identifiable, Sendable {
        public let id: String
        public let version: String
        public let binary: URL
        public let installedAt: Date
        public let isActive: Bool
        public let isManaged: Bool
    }
    public let home: URL
    public let cellarRoots: [URL]
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                cellarRoots: [URL] = [URL(fileURLWithPath: "/opt/homebrew/Cellar/rtk"), URL(fileURLWithPath: "/usr/local/Cellar/rtk")]) {
        self.home = home
        self.cellarRoots = cellarRoots
    }
    private var root: URL { home.appendingPathComponent("Library/Application Support/AIUsage/RTK") }
    public var current: URL { root.appendingPathComponent("current") }
    private static func realPath(_ url: URL) -> String? {
        guard let pointer = realpath(url.path, nil) else { return nil }
        defer { free(pointer) }
        return String(cString: pointer)
    }
    public func versions() throws -> [Version] {
        let fm = FileManager.default
        let active = Self.realPath(current)
        var results: [Version] = []
        for directory in cellarRoots + [root.appendingPathComponent("versions")] {
            guard fm.fileExists(atPath: directory.path) else { continue }
            for item in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.creationDateKey, .isSymbolicLinkKey]) {
                let values = try item.resourceValues(forKeys: [.creationDateKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { continue }
                let binary = item.appendingPathComponent("bin/rtk")
                guard fm.isExecutableFile(atPath: binary.path), Self.realPath(binary)?.hasPrefix((Self.realPath(item) ?? item.path) + "/") == true else { continue }
                results.append(Version(id: binary.path, version: item.lastPathComponent, binary: binary,
                    installedAt: values.creationDate ?? .distantPast, isActive: active != nil && active == Self.realPath(binary),
                    isManaged: directory == root.appendingPathComponent("versions")))
            }
        }
        return results.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
    }
    public func activate(_ id: String) throws {
        guard let selected = try versions().first(where: { $0.id == id }) else { throw Failure.changed }
        // Never replace the wrapper with a binary: its original-command fallback must survive rollback.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if FileManager.default.fileExists(atPath: current.path), (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true { throw Failure.changed }
        let wrapper = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        try TokenSaverSettingsStore.rejectSymlinks(wrapper)
        if FileManager.default.fileExists(atPath: wrapper.path) {
            let existing = try Data(contentsOf: wrapper)
            guard existing == Data(TokenSaverAgentRules.rtkWrapper.utf8) || existing == Data(TokenSaverAgentRules.legacyRTKWrapper.utf8) else { throw Failure.changed }
        }
        try FileManager.default.createDirectory(at: wrapper.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data(TokenSaverAgentRules.rtkWrapper.utf8).write(to: wrapper, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: wrapper.path)
        let temporary = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createSymbolicLink(at: temporary, withDestinationURL: selected.binary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard rename(temporary.path, current.path) == 0 else { throw Failure.changed }
    }
    public func delete(_ id: String) throws {
        guard let selected = try versions().first(where: { $0.id == id }), selected.isManaged, !selected.isActive else { throw Failure.changed }
        try FileManager.default.removeItem(at: selected.binary.deletingLastPathComponent().deletingLastPathComponent())
    }
    public enum Failure: LocalizedError {
        case changed
        public var errorDescription: String? { "RTK version changed, is active, or is managed by Homebrew. Refresh the list; remove Homebrew versions with Homebrew." }
    }
}
