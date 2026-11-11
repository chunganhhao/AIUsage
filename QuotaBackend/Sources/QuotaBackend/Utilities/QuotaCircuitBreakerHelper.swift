import Foundation

public enum QuotaCircuitBreakerHelper {
    public struct BreakerOutcome: Sendable {
        public let tripped: Bool
        public let reason: String
        public let error: String?

        public init(tripped: Bool, reason: String, error: String? = nil) {
            self.tripped = tripped
            self.reason = reason
            self.error = error
        }
    }

    /// Finds matching CLIProxyAPI auth files in ~/Library/Application Support/AIUsage/CLIProxyAPI/auth
    /// for a given provider ("antigravity", "codex", etc.) and optional email / credential identifier.
    public static func findTargetCPAAuthFiles(
        providerPrefix: String,
        email: String?,
        currentFileURL: URL?,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        codexIdentity: CodexAccountIdentity? = nil
    ) -> [URL] {
        var targets: [URL] = []
        var seenPaths = Set<String>()
        let isCodex = providerPrefix.lowercased() == "codex"
        let sourceJSON = isCodex ? currentFileURL.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } : nil
        let expectedCodex = codexIdentity ?? sourceJSON.map(CodexAccountIdentity.init(authJSON:))

        func addTarget(_ url: URL) {
            if isCodex {
                guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                      let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      json["type"] as? String == "codex", let expectedCodex,
                      expectedCodex.matches(CodexAccountIdentity(authJSON: json)) else { return }
            }
            let path = url.standardizedFileURL.path
            if !seenPaths.contains(path) {
                seenPaths.insert(path)
                targets.append(url)
            }
        }

        // 1. If the current file itself is in the CLIProxyAPI auth directory, include it directly
        if let currentFileURL, currentFileURL.deletingLastPathComponent().standardizedFileURL == URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth").standardizedFileURL {
            addTarget(currentFileURL)
        }

        // 2. Scan the standard CLIProxyAPI auth directory
        let fileManager = FileManager.default
        let appSupport = URL(fileURLWithPath: homeDirectory).appendingPathComponent("Library/Application Support")

        let authDir = appSupport
            .appendingPathComponent("AIUsage", isDirectory: true)
            .appendingPathComponent("CLIProxyAPI", isDirectory: true)
            .appendingPathComponent("auth", isDirectory: true)

        guard let contents = try? fileManager.contentsOfDirectory(
            at: authDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return targets
        }

        let cleanTargetEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let prefix = "aiusage-\(providerPrefix.lowercased())-"

        for fileURL in contents where fileURL.pathExtension.lowercased() == "json" {
            let filename = fileURL.lastPathComponent.lowercased()
            guard filename.hasPrefix(prefix) else { continue }

            guard let data = try? Data(contentsOf: fileURL),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            if let cleanTargetEmail, !cleanTargetEmail.isEmpty {
                let fileEmail = ((json["email"] as? String) ?? (json["account"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                if fileEmail == cleanTargetEmail {
                    addTarget(fileURL)
                    continue
                }
            }

            // Fallback match: if currentFileURL filename contains the credential ID stored in json
            if let currentFileURL {
                let currentBasename = currentFileURL.lastPathComponent
                if let credId = json["aiusage_credential_id"] as? String, !credId.isEmpty {
                    if currentBasename.contains(credId) {
                        addTarget(fileURL)
                        continue
                    }
                }
            }
        }

        return targets
    }

    /// Evaluates and synchronizes the circuit breaker state across all target auth files.
    @discardableResult
    public static func syncCircuitBreaker(
        targets: [URL],
        shouldTrip: Bool,
        reason: String,
        codexIdentity: CodexAccountIdentity? = nil,
        quotaRemaining: [String: Double]? = nil,
        threshold: Double = 3
    ) -> BreakerOutcome? {
        guard !targets.isEmpty else { return nil }

        let activeReason = reason

        var applied = false
        var failures = 0
        var hasPausedTarget = false
        var recoveryDeferred = false
        for fileURL in targets {
            guard (try? fileURL.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
                  let data = try? Data(contentsOf: fileURL),
                  var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                failures += 1
                continue
            }

            guard json["type"] as? String == "codex" else { continue }
            if let codexIdentity, !codexIdentity.matches(CodexAccountIdentity(authJSON: json)) { failures += 1; continue }
            let currentDisabled = (json["disabled"] as? Bool) ?? ((json["disabled"] as? Int) == 1)
            let isTrippedByBreaker = json["circuit_breaker_tripped"] as? Bool ?? false

            // Safety guard: If the account was MANUALLY disabled by the user in UI,
            // the circuit breaker must never touch or re-enable it!
            if currentDisabled && !isTrippedByBreaker {
                continue
            }

            let original = json
            var didChange = false

            if shouldTrip {
                if let quotaRemaining {
                    var blocked = Set(quotaRemaining.filter { $0.value.isFinite && $0.value <= threshold }.keys)
                    if isTrippedByBreaker {
                        if let previous = json["circuit_breaker_blocked_windows"] as? [String], !previous.isEmpty {
                            blocked.formUnion(previous)
                        } else {
                            // Legacy pauses have no trustworthy record of the original depleted window.
                            blocked.insert("legacy-unknown")
                        }
                    }
                    let keys = blocked.sorted()
                    if json["circuit_breaker_blocked_windows"] as? [String] != keys {
                        json["circuit_breaker_blocked_windows"] = keys
                        didChange = true
                    }
                }
                if !currentDisabled || !isTrippedByBreaker {
                    json["disabled"] = true
                    json["circuit_breaker_tripped"] = true
                    json["circuit_breaker_partial"] = false
                    json["circuit_breaker_reason"] = reason
                    json["circuit_breaker_tripped_at"] = ISO8601DateFormatter().string(from: Date())
                    didChange = true
                } else if let existingReason = json["circuit_breaker_reason"] as? String, existingReason != reason {
                    json["circuit_breaker_reason"] = reason
                    didChange = true
                }
            } else {
                if currentDisabled && isTrippedByBreaker {
                    if let quotaRemaining {
                        guard let blocked = json["circuit_breaker_blocked_windows"] as? [String], !blocked.isEmpty,
                              blocked.allSatisfy({ key in
                                  guard let remaining = quotaRemaining[key] else { return false }
                                  return remaining.isFinite && remaining > threshold
                              }) else {
                            recoveryDeferred = true
                            hasPausedTarget = true
                            applied = true
                            continue
                        }
                    }
                    json.removeValue(forKey: "circuit_breaker_blocked_windows")
                    json["disabled"] = false
                    json["circuit_breaker_tripped"] = false
                    json["circuit_breaker_partial"] = false
                    json["circuit_breaker_recovered_at"] = ISO8601DateFormatter().string(from: Date())
                    didChange = true
                }
            }

            if didChange {
                do {
                    try AntigravityCredentialFile.update(fileURL) { current in
                        if let codexIdentity, !codexIdentity.matches(CodexAccountIdentity(authJSON: current)) {
                            throw AntigravityPoolCircuitBreaker.Failure.unsafe("Codex workspace changed during protection update; left unchanged.")
                        }
                        guard NSDictionary(dictionary: current).isEqual(to: original) else {
                            throw AntigravityPoolCircuitBreaker.Failure.unsafe("Credential changed during Codex protection update; left unchanged.")
                        }
                        return json
                    }
                } catch {
                    failures += 1
                    hasPausedTarget = hasPausedTarget || (currentDisabled && isTrippedByBreaker)
                    continue
                }
            }
            hasPausedTarget = hasPausedTarget || ((json["disabled"] as? Bool == true) && (json["circuit_breaker_tripped"] as? Bool == true))
            applied = true
        }

        let failureSummary = applied ? "updated only part of its targets" : "could not update any target"
        let error = failures > 0 ? "Codex pool protection \(failureSummary) (\(failures) failed). Refresh to retry; protection is not fully confirmed."
            : recoveryDeferred ? "Codex remains paused: a previously depleted quota window is missing or unknown. Wait for matching quota data; if the pause lacks reliable window metadata, turn protection off explicitly to restore." : nil
        return applied || error != nil ? BreakerOutcome(tripped: hasPausedTarget, reason: recoveryDeferred ? "Quota recovery is not confirmed." : activeReason, error: error) : nil
    }
}
