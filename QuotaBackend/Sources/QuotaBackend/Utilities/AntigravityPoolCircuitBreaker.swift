import Foundation

/// CPA >= 8.0.43 applies credential exclusions before publishing model routes.
/// Never edit capability hints: removing IDs there makes recovery lossy.
enum AntigravityPoolCircuitBreaker {
    enum Pool: String, CaseIterable {
        case gemini, claude, argon

        static func model(_ id: String) -> Pool? {
            let id = id.lowercased()
            if id.hasPrefix("gemini-4-argon") { return .argon }
            if id.hasPrefix("gemini-") { return .gemini }
            if id.hasPrefix("claude-") || id.hasPrefix("gpt-") { return .claude }
            return nil
        }

        static func quota(_ model: AntigravityProvider.ModelQuota) -> Pool? {
            if model.isAuxiliary { return .argon }
            if model.id.hasPrefix("3p-") || model.label.hasPrefix("Claude + GPT") { return .claude }
            if model.label.hasPrefix("Gemini ·") { return .gemini }
            return Self.model(model.id)
        }
    }

    struct Outcome {
        let blockedPools: [String]
        let reason: String
    }

    enum Failure: LocalizedError {
        case unsafe(String)
        var errorDescription: String? {
            switch self { case .unsafe(let message): return message }
        }
    }

    private static let stateKey = "aiusage_pool_breaker"
    // Serializes concurrent quota polls in this process. CPA remains an independent writer;
    // compare the original bytes immediately before atomic replacement rather than overwriting stale tokens.
    private static let lock = NSLock()

    static func sync(targets: [URL], models: [AntigravityProvider.ModelQuota], runtime: URL) throws -> Outcome? {
        guard !targets.isEmpty else { return nil }
        lock.lock()
        defer { lock.unlock() }
        let version = try FileManager.default.destinationOfSymbolicLink(atPath: runtime.appendingPathComponent("current").path)
        let number = URL(fileURLWithPath: version).lastPathComponent
        guard number.range(of: #"^v[0-9]+\.[0-9]+\.[0-9]+$"#, options: .regularExpression) != nil,
              String(number.dropFirst()).compare("8.0.43", options: .numeric) != .orderedAscending else {
            throw Failure.unsafe("Pool protection requires CLIProxyAPI >= 8.0.43; credentials were left unchanged.")
        }
        let config = try String(contentsOf: runtime.appendingPathComponent("config.yaml"), encoding: .utf8)
        let global = try globalExclusions(config)
        var blocked = Set<String>()
        var applied = false
        for target in targets {
            let original = try Data(contentsOf: target)
            guard let json = try JSONSerialization.jsonObject(with: original) as? [String: Any] else {
                throw Failure.unsafe("Invalid CPA credential JSON; left unchanged.")
            }
            guard let updated = try updatedCredential(json, models: models, global: global) else { continue }
            let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys])
            guard try Data(contentsOf: target) == original else {
                throw Failure.unsafe("CPA credential changed during quota polling; retry on the next poll.")
            }
            if !NSDictionary(dictionary: json).isEqual(to: updated) {
                try data.write(to: target, options: .atomic)
            }
            applied = true
            let state = updated[stateKey] as? [String: Any]
            blocked.formUnion((state?["blocked_windows"] as? [String: String] ?? [:]).values)
        }
        guard applied else { return nil }
        let pools = blocked.sorted()
        return Outcome(blockedPools: pools, reason: pools.isEmpty
            ? "Quota đã hồi phục; đã gỡ chặn do cầu dao tạo."
            : "Đã chặn riêng pool: \(pools.joined(separator: ", ")). Các pool khác không bị cầu dao tắt.")
    }

    /// Pure transform also used by offline tests. nil means a manually paused account.
    static func updatedCredential(_ original: [String: Any], models: [AntigravityProvider.ModelQuota], global: [String]) throws -> [String: Any]? {
        var json = original
        guard json["type"] as? String == "antigravity" else {
            throw Failure.unsafe("Pool protection can only modify Antigravity credentials.")
        }
        let oldState = json[stateKey] as? [String: Any]
        let disabled = (json["disabled"] as? Bool) ?? ((json["disabled"] as? Int) == 1)
        let legacyTrip = oldState == nil && json["circuit_breaker_tripped"] as? Bool == true
        if disabled && !legacyTrip { return nil }
        if legacyTrip {
            for pool in [Pool.gemini, .claude] {
                let observed = models.filter { Pool.quota($0) == pool && $0.remainingPercent.isFinite }
                let stillBlocked = observed.contains { $0.remainingPercent <= (isWeekly($0) ? 3.0 : 5.0) }
                let weeklySeen = observed.contains(where: isWeekly)
                let fiveHourSeen = observed.contains {
                    let name = ($0.id + " " + $0.label).lowercased()
                    return name.contains("5h") || name.contains("five hour") || name.contains("5-hour")
                }
                guard stillBlocked || (weeklySeen && fiveHourSeen) else {
                    throw Failure.unsafe("Each core pool needs a blocked window or both weekly/5h windows before migrating a whole-account pause.")
                }
            }
        }
        guard json["excluded-models"] == nil else {
            throw Failure.unsafe("Legacy credential exclusions need migration; credential left unchanged.")
        }
        // Refuse ambiguous concurrent/manual edits instead of deleting a user's exclusion.
        if let last = oldState?["last_excluded_models"],
           !NSDictionary(dictionary: ["v": last]).isEqual(to: ["v": json["excluded_models"] ?? NSNull()]) {
            throw Failure.unsafe("Credential exclusions were edited outside the pool breaker; left unchanged.")
        }
        let baseline = oldState?["original_excluded_models"] ?? json["excluded_models"] ?? NSNull()
        let userExclusions = try exclusionList(baseline)
        var windows = oldState?["blocked_windows"] as? [String: String] ?? [:]
        var observed = false
        for model in models {
            guard let pool = Pool.quota(model), model.remainingPercent.isFinite else { continue }
            observed = true
            if model.remainingPercent <= (isWeekly(model) ? 3.0 : 5.0) {
                windows[model.id] = pool.rawValue
            } else {
                windows.removeValue(forKey: model.id)
            }
        }
        // Missing/disabled windows are unknown, not evidence of recovery.
        guard observed else { return nil }
        let blocked = Set(windows.values)
        let hints = json["antigravity_capability_hints"] as? [String: Any]
        let ids = hints?["model_ids"] as? [String] ?? []
        let managed = ids.filter { Pool.model($0).map { blocked.contains($0.rawValue) } ?? false }
        for pool in blocked {
            guard managed.contains(where: { Pool.model($0)?.rawValue == pool }) else {
                throw Failure.unsafe("CPA has no verified model IDs for pool \(pool); credential left unchanged.")
            }
        }
        if blocked.isEmpty {
            if baseline is NSNull { json.removeValue(forKey: "excluded_models") }
            else { json["excluded_models"] = baseline }
            json.removeValue(forKey: stateKey)
        } else {
            // Nonempty credential exclusions override (not merge with) global rules in CPA.
            // Copy global policy only when the original credential inherited it.
            let exclusions = Array(Set((userExclusions.isEmpty ? global : userExclusions) + managed)).sorted()
            json["excluded_models"] = exclusions
            json[stateKey] = ["original_excluded_models": baseline,
                              "last_excluded_models": exclusions,
                              "blocked_windows": windows]
        }
        // Migrate only breaker-owned whole-account pauses; all future trips are model-only.
        if legacyTrip { json["disabled"] = false }
        json["circuit_breaker_tripped"] = false
        json["circuit_breaker_partial"] = !blocked.isEmpty
        json["circuit_breaker_pools"] = blocked.sorted()
        json["circuit_breaker_reason"] = blocked.isEmpty ? "Quota recovered" : "Pools paused: \(blocked.sorted().joined(separator: ", "))"
        return json
    }

    private static func exclusionList(_ value: Any) throws -> [String] {
        if value is NSNull { return [] }
        guard let values = value as? [String] else {
            throw Failure.unsafe("Unsupported credential exclusions; left unchanged.")
        }
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func isWeekly(_ model: AntigravityProvider.ModelQuota) -> Bool {
        (model.id + " " + model.label).lowercased().contains("week")
    }

    /// ponytail: deliberately bounded YAML reader, not a general YAML implementation.
    /// Unsupported relevant syntax fails closed; add a shared full parser if config needs it.
    static func globalExclusions(_ source: String) throws -> [String] {
        var sections: [String: [String]] = [:]
        var section: String?
        var provider: String?
        let text = source.hasPrefix("\u{FEFF}") ? String(source.dropFirst()) : source
        let lines = text.components(separatedBy: .newlines)
        let content = lines.filter {
            let value = $0.trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && !value.hasPrefix("#") && value != "---" && value != "..."
        }
        guard !content.contains(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.first.map { "%&*!{[?:".contains($0) } == true || line.hasPrefix("---") || line.hasPrefix("...")
        }) else { throw Failure.unsafe("Unsupported YAML directives, root syntax or document markers; credentials left unchanged.") }
        let rootIndent = content.map { $0.prefix(while: { $0 == " " }).count }.min() ?? 0
        var documentSeen = false
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "---" {
                guard !documentSeen else { throw Failure.unsafe("Multiple YAML documents are not supported for pool protection.") }
                documentSeen = true
                continue
            }
            if line == "..." { continue }
            if raw.prefix(while: { $0.isWhitespace }).contains("\t") {
                throw Failure.unsafe("Unsupported YAML indentation for pool protection.")
            }
            // YAML merge keys may inject exclusions from elsewhere; do not guess their meaning.
            if line.hasPrefix("<<:") { throw Failure.unsafe("YAML merge rules require manual review before pool protection.") }
            if raw.prefix(while: { $0 == " " }).count == rootIndent {
                section = nil; provider = nil
                let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let candidate = try yamlKey(String(pair[0]))
                for key in ["excluded-models", "oauth-excluded-models"] where candidate == key {
                    guard pair.count == 2 else { throw Failure.unsafe("Invalid global exclusion mapping.") }
                    guard sections[key] == nil else { throw Failure.unsafe("Duplicate exclusion configuration.") }
                    let tail = pair[1].trimmingCharacters(in: .whitespaces)
                    guard tail.isEmpty || tail == "{}" || tail.hasPrefix("#") else {
                        throw Failure.unsafe("Unsupported global exclusions; credentials left unchanged.")
                    }
                    section = key; sections[key] = []
                }
                continue
            }
            guard let section else { continue }
            if line.hasPrefix("-") {
                if provider == "antigravity" {
                    sections[section, default: []].append(try simpleModelScalar(String(line.dropFirst())))
                }
            } else {
                let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { throw Failure.unsafe("Unsupported exclusion mapping.") }
                provider = try yamlKey(String(parts[0]))
                if provider == "antigravity" {
                    let tail = parts[1].trimmingCharacters(in: .whitespaces)
                    if tail == "[]" { continue }
                    guard tail.isEmpty || tail.hasPrefix("#") else {
                        throw Failure.unsafe("Use a block list for global Antigravity exclusions before enabling pool protection.")
                    }
                }
            }
        }
        return sections["excluded-models"] ?? sections["oauth-excluded-models"] ?? []
    }

    private static func yamlKey(_ source: String) throws -> String {
        let key = source.trimmingCharacters(in: .whitespaces)
        if key.hasPrefix("\"") {
            guard let decoded = try? JSONSerialization.jsonObject(with: Data(key.utf8), options: .fragmentsAllowed) as? String else {
                throw Failure.unsafe("Unsupported escaped YAML key for pool protection.")
            }
            return decoded
        }
        if key.hasPrefix("'") {
            guard key.hasSuffix("'") && key.count >= 2 else { throw Failure.unsafe("Invalid quoted YAML key.") }
            return String(key.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return key
    }

    private static func simpleModelScalar(_ source: String) throws -> String {
        let value = source.trimmingCharacters(in: .whitespaces)
        let pattern = #"^(?:"([A-Za-z0-9_.*:/-]+)"|'([A-Za-z0-9_.*:/-]+)'|([A-Za-z0-9_.*:/-]+))(?:\s+#.*)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) else {
            throw Failure.unsafe("Unsupported global model exclusion scalar.")
        }
        for index in 1...3 {
            if let range = Range(match.range(at: index), in: value) { return String(value[range]) }
        }
        throw Failure.unsafe("Invalid global model exclusion.")
    }
}
