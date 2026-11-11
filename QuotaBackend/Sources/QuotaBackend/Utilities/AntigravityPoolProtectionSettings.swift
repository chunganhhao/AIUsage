import Foundation

/// Non-secret opt-in setting. Missing or malformed settings mean disabled.
/// Credentials change only after explicit enable, disable, or restore actions.
public enum AntigravityPoolProtectionSettings {
    public static func isEnabled(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        isEnabled(runtime: runtime(homeDirectory))
    }

    static func isEnabled(runtime: URL) -> Bool {
        let url = runtime.appendingPathComponent("pool-protection.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return json["enabled"] as? Bool == true
    }

    public static let pools = ["gemini", "claude", "argon"]

    public static func enabledPools(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Set<String> {
        enabledPools(runtime: runtime(homeDirectory))
    }

    static func enabledPools(runtime: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("pool-protection.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Set(pools) }
        guard let list = json["pools"] as? [String] else { return Set(pools) }
        return Set(list).intersection(pools)
    }

    public static func setPool(_ pool: String, enabled: Bool, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        guard pools.contains(pool) else { return }
        try AntigravityCredentialFile.withLock {
            let directory = runtime(homeDirectory)
            var selected = enabledPools(runtime: directory)
            if enabled { selected.insert(pool) } else { selected.remove(pool) }
            // Remove only deselected pools immediately; do not wait for another quota poll.
            try AntigravityPoolCircuitBreaker.removeDeselectedPools(runtime: directory, enabledPools: selected)
            try save(enabled: isEnabled(runtime: directory), pools: selected, runtime: directory)
        }
    }

    private static func save(enabled: Bool, pools: Set<String>, runtime: URL) throws {
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = runtime.appendingPathComponent("pool-protection.json")
        try JSONSerialization.data(withJSONObject: ["enabled": enabled, "pools": pools.sorted()]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Read-only upgrade attention; malformed/unreadable credentials throw rather
    /// than incorrectly reporting that previously applied protection is absent.
    public static func hasResidualProtection(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws -> Bool {
        try AntigravityCredentialFile.withLock {
            let directory = runtime(homeDirectory).appendingPathComponent("auth")
            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return false
            }
            var found = false
            for url in files where url.pathExtension.lowercased() == "json" {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
                    throw AntigravityPoolCircuitBreaker.Failure.unsafe("Cannot inspect a symlinked credential for previous pool protection.")
                }
                let data = try Data(contentsOf: url)
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw AntigravityPoolCircuitBreaker.Failure.unsafe("Cannot inspect malformed credentials for previous pool protection.")
                }
                if json["type"] as? String == "antigravity", json["aiusage_pool_breaker"] != nil { found = true }
            }
            return found
        }
    }

    /// Explicit recovery also works when the opt-in setting is missing or off.
    /// Does not enable protection or create/change the setting.
    public static func restorePreviousExclusions(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        try AntigravityCredentialFile.withLock {
            try AntigravityPoolCircuitBreaker.clearProtection(runtime: runtime(homeDirectory))
        }
    }

    public static func setEnabled(_ enabled: Bool, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        try AntigravityCredentialFile.withLock {
            let directory = runtime(homeDirectory)
            if enabled { try AntigravityPoolCircuitBreaker.requireSupportedVersion(directory) }
            else if isEnabled(homeDirectory: homeDirectory) {
                try AntigravityPoolCircuitBreaker.clearProtection(runtime: directory)
            }
            try save(enabled: enabled, pools: enabledPools(runtime: directory), runtime: directory)
        }
    }

    static func runtime(_ home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI")
    }
}

/// Shared by Antigravity token persistence and the opt-in metadata overlay.
/// Reads fresh metadata, serializes in-process writers, and detects intervening
/// external changes immediately before atomic replacement. No cross-process CAS claim.
enum AntigravityCredentialFile {
    private static let lock = NSRecursiveLock()
    static func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    @discardableResult
    static func update(_ url: URL, transform: ([String: Any]) throws -> [String: Any]?) throws -> [String: Any]? {
        lock.lock(); defer { lock.unlock() }
        let original = try Data(contentsOf: url)
        guard let json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
            throw AntigravityPoolCircuitBreaker.Failure.unsafe("Invalid Antigravity credential JSON.")
        }
        guard let updated = try transform(json) else { return nil }
        if NSDictionary(dictionary: json).isEqual(to: updated) { return updated }
        let data = try JSONSerialization.data(withJSONObject: updated, options: [.sortedKeys, .prettyPrinted])
        guard try Data(contentsOf: url) == original else {
            throw AntigravityPoolCircuitBreaker.Failure.unsafe("Credential changed during update; retry on the next poll.")
        }
        try data.write(to: url, options: .atomic)
        return updated
    }
}
