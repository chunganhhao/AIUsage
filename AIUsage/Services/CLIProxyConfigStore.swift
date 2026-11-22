import CryptoKit
import QuotaBackend
import Foundation

nonisolated struct CLIProxyConfigStore {
    private struct StateFile: Codable {
        static let currentSettingsVersion = 4
        // Keep `version == 1` so WeeklyResetPriority continues recognizing saved state files.
        let version: Int
        var settingsVersion: Int?
        var settings: CLIProxyGatewaySettings
    }

    private let paths: CLIProxyPaths
    private let fileManager: FileManager

    init(paths: CLIProxyPaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func loadSettingsWithMigrationState() -> (settings: CLIProxyGatewaySettings, migratedFromLegacyV1: Bool) {
        guard let data = fileManager.contents(atPath: paths.stateURL.path),
              let state = try? JSONDecoder().decode(StateFile.self, from: data),
              state.version == 1 else { return (.default, false) }
        if (state.settingsVersion ?? 1) < StateFile.currentSettingsVersion {
            return (state.settings.migratedFromLegacyV1, true)
        }
        return (state.settings.normalized, false)
    }

    func loadSettings() -> CLIProxyGatewaySettings {
        loadSettingsWithMigrationState().settings
    }

    func saveSettings(_ settings: CLIProxyGatewaySettings) throws {
        do {
            try paths.prepare(fileManager: fileManager)
            let data = try JSONEncoder.pretty.encode(
                StateFile(
                    version: 1,
                    settingsVersion: StateFile.currentSettingsVersion,
                    settings: settings.normalized
                )
            )
            try data.write(to: paths.stateURL, options: [.atomic])
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.stateURL.path)
            // Publish Off before cleanup so queued background workers cannot reapply the overlay.
            // Preserve legacy auth/ files untouched in API-key-only builds.
            if CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
               settings.routingStrategy != .earliestWeeklyReset {
                try WeeklyResetPriority.sync(authDirectory: paths.authDirectory, enabled: false, observations: [])
            }
        } catch {
            throw CLIProxyGatewayError.configuration(error.localizedDescription)
        }
    }

    func runtimeConfigSHA256() -> String? {
        guard let data = fileManager.contents(atPath: paths.configURL.path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Returns true only when `paths.configURL` exists and every managed gateway
    /// policy, retry/failover knob, and management/client key matches `settings` and `secrets`.
    func runtimeConfigMatches(
        settings: CLIProxyGatewaySettings,
        secrets: CLIProxySecrets,
        clientAPIKeys: [String]? = nil
    ) -> Bool {
        guard let existing = try? existingRuntimeConfig() else { return false }
        let value = settings.normalized
        let managementKey = secrets.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultClientKey = secrets.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedClientKeys: [String] = {
            let raw = (clientAPIKeys ?? [defaultClientKey])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var unique: [String] = []
            for key in raw where !unique.contains(key) {
                unique.append(key)
            }
            if !unique.contains(defaultClientKey), !defaultClientKey.isEmpty {
                unique.insert(defaultClientKey, at: 0)
            }
            return unique
        }()
        guard !managementKey.isEmpty,
              !resolvedClientKeys.isEmpty,
              resolvedClientKeys.allSatisfy({ $0 != managementKey }) else {
            return false
        }
        do {
            let expectedAuthDir = CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                ? paths.authDirectory.path
                : paths.isolatedAuthDirectory.path
            var document = RuntimeYAMLDocument(existing)
            guard try document.managedStringScalar("host") == value.bindHost,
                  try document.managedStringScalar("port") == "\(value.port)",
                  try document.managedStringScalar("auth-dir") == expectedAuthDir,
                  try document.managedStringScalar("ws-auth") == "true",
                  try document.managedStringScalar("remote-management.allow-remote") == "false",
                  try document.managedStringScalar("remote-management.secret-key") == managementKey,
                  try document.managedStringScalar("remote-management.disable-control-panel") == "true",
                  try document.managedStringScalar("routing.strategy") == value.routingStrategy.cpaValue,
                  try document.managedStringScalar("request-retry") == "0",
                  try document.managedStringScalar("max-retry-interval") == "\(value.maxRetryInterval)",
                  try document.managedStringScalar("max-retry-credentials") == "1",
                  try document.managedStringScalar("quota-exceeded.switch-project") == "false",
                  try document.managedStringScalar("quota-exceeded.switch-preview-model") == "false",
                  try document.managedStringScalar("quota-exceeded.antigravity-credits") == "false",
                  try document.managedStringScalar("plugins.enabled") == (value.enablePlugins ? "true" : "false"),
                  try document.managedStringScalar("disable-cooling") == "false",
                  try document.managedStringScalar("save-cooldown-status") == "false" else {
                return false
            }
            if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
               try document.managedStringScalar("kv-store.disabled")?
                   .trimmingCharacters(in: .whitespacesAndNewlines)
                   .lowercased() != "true" {
                return false
            }
            let existingProxy = try document.managedStringScalar("proxy-url") ?? ""
            guard existingProxy == value.proxyURL else { return false }

            let configuredKeys = try document.managedStringSequence("api-keys")
            guard resolvedClientKeys.allSatisfy({ configuredKeys.contains($0) }),
                  configuredKeys.allSatisfy({ key in
                      resolvedClientKeys.contains(key)
                          || !CLIProxyManagedAPIKeyNamespace.prefixes.contains(where: { key.hasPrefix($0) })
                  }) else {
                return false
            }

            let protectionURL = paths.root.appendingPathComponent("pool-protection.json")
            if let protectionData = try? Data(contentsOf: protectionURL),
               let protection = try? JSONSerialization.jsonObject(with: protectionData) as? [String: Any],
               let protectionEnabled = protection["enabled"] as? Bool {
                guard try document.managedStringScalar("antigravity.tos-pause-window") == (protectionEnabled ? "6h" : "0") else {
                    return false
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Returns the inference keys from the configuration the CPA process
    /// actually loads. This matters when production and Debug builds coexist:
    /// their Keychain vaults are intentionally isolated, while a running CPA
    /// process and its config file are shared.
    func runtimeClientAPIKeys() throws -> [String]? {
        guard let existing = try existingRuntimeConfig() else { return nil }
        var document = RuntimeYAMLDocument(existing)
        return try document.managedStringSequence("api-keys")
    }

    func writeRuntimeConfig(
        settings: CLIProxyGatewaySettings,
        secrets: CLIProxySecrets,
        clientAPIKeys: [String]? = nil
    ) throws {
        let value = settings.normalized
        guard (1_024...65_535).contains(value.port) else {
            throw CLIProxyGatewayError.invalidPort(value.port)
        }
        let managementKey = secrets.managementKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultClientKey = secrets.clientAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedClientKeys: [String] = {
            let raw = (clientAPIKeys ?? [defaultClientKey])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            var unique: [String] = []
            for key in raw where !unique.contains(key) {
                unique.append(key)
            }
            if !unique.contains(defaultClientKey), !defaultClientKey.isEmpty {
                unique.insert(defaultClientKey, at: 0)
            }
            return unique
        }()
        guard !managementKey.isEmpty,
              !resolvedClientKeys.isEmpty,
              resolvedClientKeys.allSatisfy({ $0 != managementKey }) else {
            throw CLIProxyGatewayError.configuration("CPA management and client keys must be non-empty and distinct")
        }
        do {
            try paths.prepare(fileManager: fileManager)
            let existing = try existingRuntimeConfig()
            var document = RuntimeYAMLDocument(existing)
            let configuredPluginDirectory = try document.managedStringScalar("plugins.dir")
            let targetAuthDir = CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                ? paths.authDirectory.path
                : paths.isolatedAuthDirectory.path
            try document.setManagedScalar("host", value: yamlQuoted(value.bindHost))
            try document.setManagedScalar("port", value: "\(value.port)")
            try document.setManagedScalar("auth-dir", value: yamlQuoted(targetAuthDir))
            try document.syncManagedSequence(
                "api-keys",
                ensuredValues: resolvedClientKeys.map(yamlQuoted),
                managedPrefixes: CLIProxyManagedAPIKeyNamespace.prefixes
            )
            // CPA's /v1/ws route bypasses the normal AuthMiddleware when this is false.
            // Keep it authenticated for loopback and LAN operation alike.
            try document.setManagedScalar("ws-auth", value: "true")
            try document.setManagedScalar("remote-management.allow-remote", value: "false")
            try document.setManagedScalar("remote-management.secret-key",
                value: yamlQuoted(managementKey)
            )
            try document.setManagedScalar("remote-management.disable-control-panel",
                value: "true"
            )
            try document.setManagedScalar("routing.strategy",
                value: yamlQuoted(value.routingStrategy.cpaValue)
            )
            // 以下不是「额外补丁策略」，而是 CPA 自己的故障转移旋钮。
            // fill-first/round-robin 只决定「先挑谁」；429 后能否换号还依赖：
            // 1) MarkResult 把失败号冷却；2) request-retry + max-retry-interval 允许再挑。
            // Go bool 缺省 false，YAML 不写就等于关——所以必须显式托管。
            try document.setManagedScalar("request-retry", value: "\(value.requestRetry)")
            try document.setManagedScalar("max-retry-interval", value: "\(value.maxRetryInterval)")
            try document.setManagedScalar("max-retry-credentials", value: "\(value.maxRetryCredentials)")
            try document.setManagedScalar("quota-exceeded.switch-project",
                value: value.quotaSwitchProject ? "true" : "false"
            )
            try document.setManagedScalar("quota-exceeded.switch-preview-model",
                value: value.quotaSwitchPreviewModel ? "true" : "false"
            )
            try document.setManagedScalar("quota-exceeded.antigravity-credits",
                value: value.quotaAntigravityCredits ? "true" : "false"
            )
            try document.setManagedScalar("plugins.enabled",
                value: value.enablePlugins ? "true" : "false"
            )
            try document.setManagedScalar("disable-cooling", value: "false")
            try document.setManagedScalar("save-cooldown-status", value: "false")
            if !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild {
                try document.setManagedScalar("kv-store.disabled", value: "true")
            }
            let protectionURL = paths.root.appendingPathComponent("pool-protection.json")
            let protectionData = try? Data(contentsOf: protectionURL)
            let protection = protectionData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            if let protectionEnabled = protection?["enabled"] as? Bool {
                try document.setManagedScalar("antigravity.tos-pause-window", value: yamlQuoted(protectionEnabled ? "6h" : "0"))
            }
            // Perform filesystem migration only after the existing YAML has passed
            // every structural validation above.
            let runtimePluginDirectory = try paths.runtimePluginsDirectory(
                configuredPath: configuredPluginDirectory,
                fileManager: fileManager
            )
            try document.setManagedScalar("plugins.dir",
                value: yamlQuoted(runtimePluginDirectory.path)
            )
            try document.setManagedScalar("debug", value: "false")
            try document.setManagedScalar("logging-to-file", value: "false")
            try document.setManagedScalar("usage-statistics-enabled", value: "true")
            if value.proxyURL.isEmpty {
                try document.removeManagedValue("proxy-url")
            } else {
                try document.setManagedScalar("proxy-url", value: yamlQuoted(value.proxyURL))
            }
            let config = document.rendered
            try config.write(to: paths.configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configURL.path)
        } catch {
            if let error = error as? CLIProxyGatewayError { throw error }
            throw CLIProxyGatewayError.configuration(error.localizedDescription)
        }
    }

    /// CPA watches config.yaml; an explicit pool toggle only updates its protective pause.
    func syncPoolProtectionPause(enabled: Bool) throws {
        guard let existing = try existingRuntimeConfig() else { return }
        var document = RuntimeYAMLDocument(existing)
        try document.setManagedScalar("antigravity.tos-pause-window", value: yamlQuoted(enabled ? "6h" : "0"))
        try document.rendered.write(to: paths.configURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.configURL.path)
    }

    private func existingRuntimeConfig() throws -> String? {
        guard fileManager.fileExists(atPath: paths.configURL.path) else { return nil }
        do {
            return try String(contentsOf: paths.configURL, encoding: .utf8)
        } catch {
            throw CLIProxyGatewayError.configuration(
                "existing CPA config could not be read safely: \(error.localizedDescription)"
            )
        }
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        return "\"\(escaped)\""
    }
}

/// A deliberately small, lossless editor for the scalar paths AIUsage owns.
/// Unknown top-level fields and nested CPA/plugin configuration remain byte-for-byte
/// intact. Inline mappings are rejected instead of being rewritten destructively.
nonisolated private struct RuntimeYAMLDocument {
    private var lines: [String]
    private var isNested = false

    init(_ source: String?) {
        guard let source, !source.isEmpty else {
            lines = []
            return
        }
        lines = source.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
    }

    var rendered: String {
        lines.joined(separator: "\n") + "\n"
    }

    // CPA v8 translates these legacy fields at the YAML boundary. Keep the user's layout.
    private func managedPath(_ legacy: String) throws -> [String] {
        let version = topLevelRange("config-version")
        if let version {
            let line = lines[version.lowerBound]
            let colon = line.firstIndex(of: ":")!
            let value = String(line[line.index(after: colon)...])
            guard try parseSimpleStringScalar(value, context: "config-version") == "8" else {
                throw CLIProxyGatewayError.configuration("Unsupported CPA config-version; config was left unchanged")
            }
        }
        let hasNativeRouting = topLevelRange("routing")?.dropFirst().contains {
            let key = mappingKey(in: lines[$0], indent: 2)
            return key == "retry" || key == "cooldown"
        } ?? false
        let v8 = version != nil || hasNativeRouting || ["server", "management", "access", "oauth", "requests", "observability"]
            .contains { topLevelRange($0) != nil }
        guard v8 else { return legacy.components(separatedBy: ".") }
        let paths = [
            "host": "server.host", "port": "server.port", "auth-dir": "oauth.auth-dir",
            "kv-store.disabled": "server.kv-store.disabled",
            "api-keys": "access.api-keys", "ws-auth": "oauth.providers.aistudio.ws-auth",
            "remote-management.allow-remote": "management.allow-remote",
            "remote-management.secret-key": "management.secret-key",
            "remote-management.disable-control-panel": "management.disable-control-panel",
            "request-retry": "routing.retry.request-retry",
            "max-retry-interval": "routing.retry.max-retry-interval",
            "max-retry-credentials": "routing.retry.max-retry-credentials",
            "disable-cooling": "routing.cooldown.disable-cooling",
            "save-cooldown-status": "routing.cooldown.save-cooldown-status",
            "quota-exceeded.antigravity-credits": "oauth.providers.antigravity.antigravity-credits",
            "antigravity.tos-pause-window": "oauth.providers.antigravity.tos-pause-window",
            "debug": "observability.logs.debug", "logging-to-file": "observability.logs.logging-to-file",
            "usage-statistics-enabled": "observability.usage.usage-statistics-enabled",
            "proxy-url": "requests.proxy-url"
        ]
        return (paths[legacy] ?? legacy).components(separatedBy: ".")
    }

    private mutating func atPath<T>(
        _ path: ArraySlice<String>, create: Bool = true,
        _ operation: (inout RuntimeYAMLDocument, String) throws -> T
    ) throws -> T? {
        guard let key = path.first else { return nil }
        guard lines.filter({ mappingKey(in: $0, indent: 0) == key }).count <= 1 else {
            throw CLIProxyGatewayError.configuration("Duplicate CPA key '\(key)'; config was left unchanged")
        }
        if path.count == 1 { return try operation(&self, key) }
        if topLevelRange(key) == nil {
            guard create else { return nil }
            appendBlock(["\(key):"])
        }
        guard let range = topLevelRange(key), !hasInlineValue(at: range.lowerBound) else {
            throw CLIProxyGatewayError.configuration("CPA config uses an unsupported mapping for '\(key)'; config was left unchanged")
        }
        let body = (range.lowerBound + 1)..<range.upperBound
        let childIndent = body.compactMap { index -> Int? in
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") ? nil : leadingSpaces(in: lines[index])
        }.min()
        // shortcut: bounded editor supports two-space edited maps; reject other
        // valid YAML indentation rather than invent duplicate sibling mappings.
        guard childIndent == nil || childIndent == 2, body.allSatisfy({
            let trimmed = lines[$0].trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty || trimmed.hasPrefix("#") || leadingSpaces(in: lines[$0]) >= 2
        }) else {
            throw CLIProxyGatewayError.configuration("CPA config uses unsupported indentation for '\(key)'")
        }
        var child = RuntimeYAMLDocument(body.map { String(lines[$0].dropFirst(min(2, leadingSpaces(in: lines[$0])))) }.joined(separator: "\n"))
        child.isNested = true
        let result = try child.atPath(path.dropFirst(), create: create, operation)
        lines.replaceSubrange(body, with: child.lines.map { $0.isEmpty ? "" : "  " + $0 })
        return result
    }

    mutating func setManagedScalar(_ legacy: String, value: String) throws {
        let path = try managedPath(legacy)
        try atPath(path[...]) { $0.setTopLevelScalar($1, value: value) }
        if path != legacy.components(separatedBy: ".") {
            try atPath(legacy.components(separatedBy: ".")[...], create: false) { $0.removeTopLevel($1) }
        }
    }

    mutating func removeManagedValue(_ legacy: String) throws {
        let path = try managedPath(legacy)
        try atPath(path[...], create: false) { $0.removeTopLevel($1) }
        if path != legacy.components(separatedBy: ".") {
            try atPath(legacy.components(separatedBy: ".")[...], create: false) { $0.removeTopLevel($1) }
        }
    }

    mutating func managedStringScalar(_ legacy: String) throws -> String? {
        let path = try managedPath(legacy)
        return try atPath(path[...], create: false) { document, key in
            guard let range = document.topLevelRange(key) else { return nil }
            guard range.dropFirst().allSatisfy({ document.lines[$0].trimmingCharacters(in: .whitespaces).isEmpty || document.lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("#") }),
                  let colon = document.lines[range.lowerBound].firstIndex(of: ":") else {
                throw CLIProxyGatewayError.configuration("CPA config requires a scalar for '\(legacy)'")
            }
            let line = document.lines[range.lowerBound]
            return try document.parseSimpleStringScalar(String(line[line.index(after: colon)...]), context: legacy)
        } ?? nil
    }

    private func isTopLevelSequence(_ key: String) -> Bool {
        guard let range = topLevelRange(key) else { return false }
        return range.dropFirst().contains {
            leadingSpaces(in: lines[$0]) == 2 && lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("-")
        }
    }

    mutating func managedStringSequence(_ legacy: String) throws -> [String] {
        let path = try managedPath(legacy)
        let exists = try atPath(path[...], create: false) { $0.topLevelRange($1) != nil } ?? false
        if !exists, path != [legacy], isTopLevelSequence(legacy) {
            return try topLevelStringSequence(legacy)
        }
        return try atPath(path[...], create: false) { try $0.topLevelStringSequence($1) } ?? []
    }

    mutating func syncManagedSequence(_ legacy: String, ensuredValues: [String], managedPrefixes: [String]) throws {
        let path = try managedPath(legacy)
        let exists = try atPath(path[...], create: false) { $0.topLevelRange($1) != nil } ?? false
        let legacyIsSequence = isTopLevelSequence(legacy)
        let migrated = !exists && path != [legacy] && legacyIsSequence ? try topLevelStringSequence(legacy).map(yamlQuoteIfNeeded) : []
        try atPath(path[...]) { try $0.syncManagedStringSequence($1, ensuredValues: migrated + ensuredValues, managedPrefixes: managedPrefixes) }
        if path != legacy.components(separatedBy: ".") {
            // A v8 api-keys mapping holds upstream provider groups, not client keys.
            if legacy != "api-keys" || legacyIsSequence {
                try atPath(legacy.components(separatedBy: ".")[...], create: false) { $0.removeTopLevel($1) }
            }
        }
    }

    mutating func setTopLevelScalar(_ key: String, value: String) {
        guard let range = topLevelRange(key) else {
            appendBlock(["\(key): \(value)"])
            return
        }
        if hasInlineValue(at: range.lowerBound) || range.count == 1 {
            lines[range.lowerBound] = "\(key): \(value)"
        } else {
            lines.replaceSubrange(contentRange(range), with: ["\(key): \(value)"])
        }
    }

    /// 同步受管字符串序列：删掉匹配托管前缀的旧项，再确保 `ensuredValues` 全部存在；其它项保留。
    mutating func syncManagedStringSequence(
        _ key: String,
        ensuredValues: [String],
        managedPrefixes: [String]
    ) throws {
        guard !ensuredValues.isEmpty else {
            throw CLIProxyGatewayError.configuration("CPA config requires at least one '\(key)' entry")
        }
        if topLevelRange(key) == nil {
            var block = ["\(key):"]
            block.append(contentsOf: ensuredValues.map { "  - \($0)" })
            appendBlock(block)
            return
        }
        guard let range = topLevelRange(key) else { return }
        guard !hasInlineValue(at: range.lowerBound) else {
            throw CLIProxyGatewayError.configuration(
                "CPA config uses an unsupported inline sequence for '\(key)'; it was left unchanged"
            )
        }

        var kept: [String] = []
        var seenEnsured = Set<String>()
        for index in lines.indices where range.contains(index) && index > range.lowerBound {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard leadingSpaces(in: lines[index]) == 2,
                  trimmed.first == "-",
                  trimmed.dropFirst().first?.isWhitespace == true else {
                throw CLIProxyGatewayError.configuration(
                    "CPA config uses an unsupported complex sequence for '\(key)'; it was left unchanged"
                )
            }
            let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            let existingValue = try parseSimpleStringScalar(item, context: key)
            if ensuredValues.contains(where: { (try? parseSimpleStringScalar($0, context: key)) == existingValue }) {
                if !seenEnsured.contains(existingValue) {
                    kept.append("  - \(item.contains("\"") || item.contains("'") ? item : yamlQuoteIfNeeded(existingValue))")
                    seenEnsured.insert(existingValue)
                }
                continue
            }
            if managedPrefixes.contains(where: { existingValue.hasPrefix($0) }) {
                continue
            }
            kept.append(lines[index])
        }

        for ensured in ensuredValues {
            let plain = try parseSimpleStringScalar(ensured, context: key)
            if seenEnsured.contains(plain) { continue }
            kept.append("  - \(ensured)")
            seenEnsured.insert(plain)
        }

        let replacement = ["\(key):"] + kept
        lines.replaceSubrange(contentRange(range), with: replacement)
    }

    func topLevelStringSequence(_ key: String) throws -> [String] {
        guard let range = topLevelRange(key) else { return [] }
        guard !hasInlineValue(at: range.lowerBound) else {
            throw CLIProxyGatewayError.configuration(
                "CPA config uses an unsupported inline sequence for '\(key)'"
            )
        }

        var values: [String] = []
        for index in range.dropFirst() {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard leadingSpaces(in: lines[index]) == 2,
                  trimmed.first == "-",
                  trimmed.dropFirst().first?.isWhitespace == true else {
                throw CLIProxyGatewayError.configuration(
                    "CPA config uses an unsupported complex sequence for '\(key)'"
                )
            }
            let item = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            values.append(try parseSimpleStringScalar(item, context: key))
        }
        return values
    }

    private func yamlQuoteIfNeeded(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    mutating func removeTopLevel(_ key: String) {
        guard let range = topLevelRange(key) else { return }
        lines.removeSubrange(contentRange(range))
        trimRepeatedBlankLines()
    }

    private func topLevelRange(_ key: String) -> Range<Int>? {
        guard let start = lines.indices.first(where: { mappingKey(in: lines[$0], indent: 0) == key }) else {
            return nil
        }
        let end = lines.indices.dropFirst(start + 1).first(where: {
            mappingKey(in: lines[$0], indent: 0) != nil
        }) ?? lines.endIndex
        return start..<end
    }

    private func contentRange(_ range: Range<Int>) -> Range<Int> {
        var upper = range.upperBound
        while upper > range.lowerBound + 1 {
            let value = lines[upper - 1].trimmingCharacters(in: .whitespaces)
            guard value.isEmpty || value.hasPrefix("#") else { break }
            upper -= 1
        }
        return range.lowerBound..<upper
    }

    private func mappingKey(in line: String, indent: Int) -> String? {
        guard leadingSpaces(in: line) == indent else { return nil }
        let trimmed = line.dropFirst(indent)
        guard !trimmed.hasPrefix("#"), let colon = trimmed.firstIndex(of: ":") else { return nil }
        let key = String(trimmed[..<colon])
        guard !key.isEmpty,
              key.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_")).contains($0)
              }) else { return nil }
        return key
    }

    private func leadingSpaces(in line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private func hasInlineValue(at index: Int) -> Bool {
        guard let colon = lines[index].firstIndex(of: ":") else { return false }
        let value = lines[index][lines[index].index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return !value.isEmpty && !value.hasPrefix("#")
    }

    private func parseSimpleStringScalar(_ source: String, context: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            throw unsupportedScalar(context)
        }
        if value.first == "\"" {
            return try parseDoubleQuotedScalar(value, context: context)
        }
        if value.first == "'" {
            return try parseSingleQuotedScalar(value, context: context)
        }

        var characters = Array(value)
        if let comment = characters.indices.first(where: {
            characters[$0] == "#" && $0 > characters.startIndex && characters[$0 - 1].isWhitespace
        }) {
            characters.removeSubrange(comment...)
        }
        let plain = String(characters).trimmingCharacters(in: .whitespaces)
        guard let first = plain.first,
              !"[{&*!|>@`".contains(first),
              !plain.enumerated().contains(where: { offset, character in
                  guard character == ":" else { return false }
                  let next = plain.index(plain.startIndex, offsetBy: offset + 1)
                  return next < plain.endIndex && plain[next].isWhitespace
              }) else {
            throw unsupportedScalar(context)
        }
        return plain
    }

    private func parseSingleQuotedScalar(_ source: String, context: String) throws -> String {
        let characters = Array(source)
        var result = ""
        var index = 1
        while index < characters.count {
            if characters[index] == "'" {
                if index + 1 < characters.count, characters[index + 1] == "'" {
                    result.append("'")
                    index += 2
                    continue
                }
                try validateScalarRemainder(characters[(index + 1)...], context: context)
                return result
            }
            result.append(characters[index])
            index += 1
        }
        throw unsupportedScalar(context)
    }

    private func parseDoubleQuotedScalar(_ source: String, context: String) throws -> String {
        let characters = Array(source)
        var result = ""
        var index = 1
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                try validateScalarRemainder(characters[(index + 1)...], context: context)
                return result
            }
            guard character == "\\" else {
                result.append(character)
                index += 1
                continue
            }
            index += 1
            guard index < characters.count else { throw unsupportedScalar(context) }
            switch characters[index] {
            case "0": result.append("\0")
            case "a": result.append("\u{7}")
            case "b": result.append("\u{8}")
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "v": result.append("\u{B}")
            case "f": result.append("\u{C}")
            case "r": result.append("\r")
            case "e": result.append("\u{1B}")
            case " ": result.append(" ")
            case "\"": result.append("\"")
            case "/": result.append("/")
            case "\\": result.append("\\")
            case "N": result.append("\u{85}")
            case "_": result.append("\u{A0}")
            case "L": result.append("\u{2028}")
            case "P": result.append("\u{2029}")
            case "x", "u", "U":
                let count = characters[index] == "x" ? 2 : (characters[index] == "u" ? 4 : 8)
                let start = index + 1
                let end = start + count
                guard end <= characters.count,
                      let codePoint = UInt32(String(characters[start..<end]), radix: 16),
                      let scalar = UnicodeScalar(codePoint) else {
                    throw unsupportedScalar(context)
                }
                result.unicodeScalars.append(scalar)
                index = end - 1
            default:
                throw unsupportedScalar(context)
            }
            index += 1
        }
        throw unsupportedScalar(context)
    }

    private func validateScalarRemainder(
        _ remainder: ArraySlice<Character>,
        context: String
    ) throws {
        let trailing = String(remainder).trimmingCharacters(in: .whitespaces)
        guard trailing.isEmpty || trailing.hasPrefix("#") else {
            throw unsupportedScalar(context)
        }
    }

    private func unsupportedScalar(_ context: String) -> CLIProxyGatewayError {
        CLIProxyGatewayError.configuration(
            "CPA config uses an unsupported YAML scalar for '\(context)'; it was left unchanged"
        )
    }

    private mutating func appendBlock(_ block: [String]) {
        if !isNested, let last = lines.last, !last.isEmpty { lines.append("") }
        lines.append(contentsOf: block)
    }

    private mutating func trimRepeatedBlankLines() {
        var index = lines.count - 1
        while index > 0 {
            if lines[index].isEmpty, lines[index - 1].isEmpty { lines.remove(at: index) }
            index -= 1
        }
    }
}

nonisolated private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
