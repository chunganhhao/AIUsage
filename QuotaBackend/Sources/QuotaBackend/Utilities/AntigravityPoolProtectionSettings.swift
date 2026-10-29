import Foundation

/// Non-secret opt-in setting. Missing or malformed settings mean disabled.
/// Pool protection cannot mutate CPA credentials unless the user enables this.
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

    public static func setEnabled(_ enabled: Bool, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        try AntigravityCredentialFile.withLock {
            let directory = runtime(homeDirectory)
            if enabled { try AntigravityPoolCircuitBreaker.requireSupportedVersion(directory) }
            else {
                // 即使设置文件丢失或旧版本已写入关闭，也尝试清理原有保护规则。
                try AntigravityPoolCircuitBreaker.clearProtection(runtime: directory)
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("pool-protection.json")
            try JSONSerialization.data(withJSONObject: ["enabled": enabled]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
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
