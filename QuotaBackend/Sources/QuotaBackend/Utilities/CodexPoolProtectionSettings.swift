import Foundation

/// Independent, default-off policy. Only breaker-owned Codex pauses may be restored.
public enum CodexPoolProtectionSettings {
    private static func file(_ home: String) -> URL {
        AntigravityPoolProtectionSettings.runtime(home).appendingPathComponent("codex-pool-protection.json")
    }
    public static func isEnabled(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Bool {
        read(homeDirectory)["enabled"] as? Bool == true
    }
    public static func threshold(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Double {
        let value = (read(homeDirectory)["threshold"] as? NSNumber)?.doubleValue ?? 3
        return [1.0, 3.0, 5.0].contains(value) ? value : 3
    }
    private static func read(_ home: String) -> [String: Any] {
        guard let data = try? Data(contentsOf: file(home)), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return json
    }
    public static func setEnabled(_ enabled: Bool, threshold: Double = 3, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        try AntigravityCredentialFile.withLock {
            guard [1.0, 3.0, 5.0].contains(threshold) else { throw AntigravityPoolCircuitBreaker.Failure.unsafe("Choose a 1%, 3% or 5% threshold.") }
            if !enabled {
                let auth = AntigravityPoolProtectionSettings.runtime(homeDirectory).appendingPathComponent("auth")
                if FileManager.default.fileExists(atPath: auth.path) {
                    for url in try FileManager.default.contentsOfDirectory(at: auth, includingPropertiesForKeys: [.isSymbolicLinkKey]) where url.pathExtension == "json" {
                        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                        try AntigravityCredentialFile.update(url) { json in
                            guard json["type"] as? String == "codex", json["circuit_breaker_tripped"] as? Bool == true else { return nil }
                            var updated = json
                            updated["disabled"] = false
                            updated["circuit_breaker_tripped"] = false
                            updated["circuit_breaker_partial"] = false
                            updated.removeValue(forKey: "circuit_breaker_blocked_windows")
                            return updated
                        }
                    }
                }
            }
            let url = file(homeDirectory)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONSerialization.data(withJSONObject: ["enabled": enabled, "threshold": threshold]).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    static func sync(targets: [URL], shouldTrip: Bool, reason: String, homeDirectory: String, identity: CodexAccountIdentity? = nil, quotaRemaining: [String: Double]? = nil, threshold: Double = 3) -> QuotaCircuitBreakerHelper.BreakerOutcome? {
        AntigravityCredentialFile.withLock {
            guard isEnabled(homeDirectory: homeDirectory) else { return nil }
            return QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: targets, shouldTrip: shouldTrip, reason: reason, codexIdentity: identity, quotaRemaining: quotaRemaining, threshold: threshold)
        }
    }
}
