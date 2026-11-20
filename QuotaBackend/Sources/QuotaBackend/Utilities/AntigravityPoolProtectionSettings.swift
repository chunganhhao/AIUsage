import Foundation

public enum AntigravityQuotaPollingMode: String, Sendable, CaseIterable {
    case localOnly = "local_only"
    case randomTrickle = "random_trickle"
}

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
    private static let currentPollingModeVersion = 2

    public static func enabledPools(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> Set<String> {
        enabledPools(runtime: runtime(homeDirectory))
    }

    static func enabledPools(runtime: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: runtime.appendingPathComponent("pool-protection.json")),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return Set(pools) }
        guard let list = json["pools"] as? [String] else { return Set(pools) }
        return Set(list).intersection(pools)
    }

    public static func pollingMode(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AntigravityQuotaPollingMode {
        // Policy compliance: always stay local IDE RPC + cached snapshot only regardless of legacy v1/v2 files.
        _ = homeDirectory
        return .localOnly
    }

    public static func setPollingMode(
        _ mode: AntigravityQuotaPollingMode,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws {
        _ = mode
        try AntigravityCredentialFile.withLock {
            let directory = runtime(homeDirectory)
            try save(
                enabled: isEnabled(runtime: directory),
                pools: enabledPools(runtime: directory),
                pollingMode: .localOnly,
                runtime: directory
            )
        }
    }

    public static func setPool(_ pool: String, enabled: Bool, homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) throws {
        guard pools.contains(pool) else { return }
        try AntigravityCredentialFile.withLock {
            let directory = runtime(homeDirectory)
            var selected = enabledPools(runtime: directory)
            if enabled { selected.insert(pool) } else { selected.remove(pool) }
            // Remove only deselected pools immediately; do not wait for another quota poll.
            try AntigravityPoolCircuitBreaker.removeDeselectedPools(runtime: directory, enabledPools: selected)
            try save(
                enabled: isEnabled(runtime: directory),
                pools: selected,
                pollingMode: pollingMode(homeDirectory: homeDirectory),
                runtime: directory
            )
        }
    }

    private static func save(
        enabled: Bool,
        pools: Set<String>,
        pollingMode: AntigravityQuotaPollingMode,
        runtime: URL
    ) throws {
        try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = runtime.appendingPathComponent("pool-protection.json")
        var payload: [String: Any] = ["enabled": enabled, "pools": pools.sorted()]
        if pollingMode != .localOnly {
            payload["polling_mode"] = pollingMode.rawValue
            payload["polling_mode_version"] = currentPollingModeVersion
        }
        try JSONSerialization.data(withJSONObject: payload).write(to: url, options: .atomic)
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
            try save(
                enabled: enabled,
                pools: enabledPools(runtime: directory),
                pollingMode: pollingMode(homeDirectory: homeDirectory),
                runtime: directory
            )
        }
    }

    static func runtime(_ home: String) -> URL {
        URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI")
    }
}

/// Tracks exact auth-file bytes written by the current fetch task under CAS so cache
/// versioning only advances for self-owned writes, never external file replacements.
final class CredentialWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var writtenByPath: [String: Data] = [:]
    @TaskLocal static var current: CredentialWriteRecorder?

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: NSString(string: path).expandingTildeInPath)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    func record(url: URL, data: Data) {
        let normalized = Self.normalizedPath(url.path)
        lock.lock(); defer { lock.unlock() }
        writtenByPath[normalized] = data
    }

    func data(for path: String) -> Data? {
        let normalized = Self.normalizedPath(path)
        lock.lock(); defer { lock.unlock() }
        return writtenByPath[normalized]
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
        CredentialWriteRecorder.current?.record(url: url, data: data)
        return updated
    }
}

/// Evaluates whether a single-card remote Antigravity check should ask the user
/// to confirm first due to legacy/unknown scopes or missing `auth_source` provenance.
public enum AntigravityCredentialCheckGuard {
    public struct RiskAssessment: Sendable, Equatable {
        public let isLegacyOrUnknownScope: Bool
        public let missingAuthSource: Bool
        public let missingOrReducedScopes: Bool
        public let scopeCount: Int

        public var requiresConfirmation: Bool { isLegacyOrUnknownScope }
    }

    public static let minimumExpectedScopeCount = 5

    public static func assess(credential: AccountCredential) -> RiskAssessment {
        guard credential.providerId.lowercased() == "antigravity" else {
            return RiskAssessment(
                isLegacyOrUnknownScope: false,
                missingAuthSource: false,
                missingOrReducedScopes: false,
                scopeCount: 0
            )
        }

        let json: [String: Any]?
        if credential.authMethod == .authFile {
            let expanded = NSString(string: credential.credential).expandingTildeInPath
            json = FileManager.default.contents(atPath: expanded)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        } else {
            json = nil
        }

        let authSource = ((json?["auth_source"] as? String) ?? credential.metadata["auth_source"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let missingAuthSource = authSource?.isEmpty ?? true
        let untrustedExplicitAuthSource = authSource.map {
            let lower = $0.lowercased()
            return !lower.isEmpty && ["legacy", "unknown", "external", "third_party"].contains(lower)
        } ?? false

        let scopes = extractedScopes(json: json, metadata: credential.metadata)
        let missingOrReducedScopes = scopes.count < minimumExpectedScopeCount

        // Patch C ([C2]) auth_source tagging is deferred; do not require auth_source presence
        // yet so full-scope OAuth credentials are not perpetually flagged as unverified.
        return RiskAssessment(
            isLegacyOrUnknownScope: missingOrReducedScopes || untrustedExplicitAuthSource,
            missingAuthSource: missingAuthSource,
            missingOrReducedScopes: missingOrReducedScopes,
            scopeCount: scopes.count
        )
    }

    public static func assess(
        credentialId: String?,
        store: AccountCredentialStore = .shared
    ) -> RiskAssessment {
        guard let credentialId = credentialId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !credentialId.isEmpty,
              let credential = store.loadCredential(providerId: "antigravity", credentialId: credentialId) else {
            // Unreadable or unresolved Antigravity credential falls back to requiring confirmation.
            return RiskAssessment(
                isLegacyOrUnknownScope: true,
                missingAuthSource: true,
                missingOrReducedScopes: true,
                scopeCount: 0
            )
        }
        return assess(credential: credential)
    }

    private static func extractedScopes(json: [String: Any]?, metadata: [String: String]) -> Set<String> {
        var rawParts: [String] = []
        if let scopeString = json?["scope"] as? String {
            rawParts.append(contentsOf: scopeString.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        if let scopesString = json?["scopes"] as? String {
            rawParts.append(contentsOf: scopesString.split(whereSeparator: \.isWhitespace).map(String.init))
        } else if let scopesArray = json?["scopes"] as? [String] {
            rawParts.append(contentsOf: scopesArray)
        }
        if let metadataScope = metadata["scope"] ?? metadata["scopes"] {
            rawParts.append(contentsOf: metadataScope.split(whereSeparator: \.isWhitespace).map(String.init))
        }
        return Set(rawParts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }
}
