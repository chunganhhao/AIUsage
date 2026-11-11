import Foundation

/// ponytail: temporary priority overlay pending upstream https://github.com/router-for-me/CLIProxyAPI/pull/7246
/// Preserves user priority tiers; within a tier, the nearest known weekly reset wins.
public enum WeeklyResetPriority {
    public struct Observation: Sendable {
        public let provider: String
        public let email: String
        public let reset: Date
        public let accountID: String?
        public init(provider: String, email: String, reset: Date, accountID: String? = nil) { self.provider = provider == "claude-subscription" ? "claude" : provider; self.email = email; self.reset = reset; self.accountID = accountID }
    }
    public static func sync(authDirectory: URL, enabled: Bool, observations: [Observation], now: Date = Date(), policyURL: URL? = nil) throws {
        try AntigravityCredentialFile.withLock {
            if enabled, let policyURL {
                guard let data = try? Data(contentsOf: policyURL), let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      state["version"] as? Int == 1, let settings = state["settings"] as? [String: Any],
                      settings["routingStrategy"] as? String == "earliest-weekly-reset" else { return }
            }
            guard FileManager.default.fileExists(atPath: authDirectory.path) else { return }
            let files = try FileManager.default.contentsOfDirectory(at: authDirectory, includingPropertiesForKeys: [.isSymbolicLinkKey])
                .filter { $0.pathExtension == "json" }
            let future = observations.filter { $0.reset > now }
            let sorted = Array(Set(future.map(\.reset))).sorted()
            // 1000 slots per existing tier; reject out-of-range tiers rather than overflowing.
            guard sorted.count < 1000 else { throw Failure.unsafe }
            var fenced = false
            for file in files {
                guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                try AntigravityCredentialFile.update(file) { json in
                    guard let type = json["type"] as? String, ["codex", "antigravity", "claude"].contains(type) else { return nil }
                    var copy = json
                    let previous = json["aiusage_weekly_priority"] as? [String: Any]
                    if let last = previous?["last"] as? Int, json["priority"] as? Int != last {
                        // Keep the old marker as an ownership fence until Off; never rescale an external effective priority.
                        if enabled { fenced = true; return nil }
                        copy.removeValue(forKey: "aiusage_weekly_priority")
                        return copy
                    }
                    let baseline = previous?["original"] ?? json["priority"] ?? NSNull()
                    guard baseline is NSNull || baseline is Int else { throw Failure.unsafe }
                    let tier = baseline as? Int ?? 0
                    guard (-1_000_000...1_000_000).contains(tier) else { throw Failure.unsafe }
                    let email = (json["email"] as? String ?? "").lowercased()
                    let accountID = (json["account_id"] as? String) ?? (json["chatgpt_account_id"] as? String)
                    let matches = future.filter { $0.provider == type && $0.email.lowercased() == email }
                    let exact = type == "codex" ? matches.filter { $0.accountID != nil && $0.accountID == accountID } : matches
                    // Email is not a Codex workspace identity; unknown/ambiguous identities remain unranked.
                    let reset = Set(exact.map(\.reset)).count == 1 ? exact.first?.reset : nil
                    if enabled, let reset, let rank = sorted.firstIndex(of: reset) {
                        let priority = tier * 1000 + (999 - rank)
                        copy["priority"] = priority
                        copy["aiusage_weekly_priority"] = ["original": baseline, "last": priority]
                    } else if !enabled, previous != nil {
                        if baseline is NSNull { copy.removeValue(forKey: "priority") } else { copy["priority"] = baseline }
                        copy.removeValue(forKey: "aiusage_weekly_priority")
                    } else if enabled {
                        // Keep unknown reset accounts in their original tier, below known reset accounts.
                        copy["priority"] = tier * 1000
                        copy["aiusage_weekly_priority"] = ["original": baseline, "last": tier * 1000]
                    }
                    return copy
                }
            }
            if fenced { throw Failure.externalPriorityOverride }
        }
    }
    public enum Failure: LocalizedError {
        case unsafe
        case externalPriorityOverride
        public var errorDescription: String? {
            switch self {
            case .unsafe:
                return "Weekly-reset priority uses an unsupported priority tier or too many reset ranks. Credentials left unchanged where possible; reconcile priority before switching strategies."
            case .externalPriorityOverride:
                return "Some accounts have externally edited priorities and are excluded from weekly routing. Other accounts were synchronized. Turning weekly routing off preserves edited values but can change relative account order; review all priorities before switching strategies."
            }
        }
    }
}

/// Serial background I/O; cancelled/coalesced refreshes never enter the credential write path.
public actor WeeklyResetPriorityWorker {
    public init() {}
    public func sync(authDirectory: URL, policyURL: URL, observations: [WeeklyResetPriority.Observation]) throws {
        try Task.checkCancellation()
        try WeeklyResetPriority.sync(authDirectory: authDirectory, enabled: true, observations: observations, policyURL: policyURL)
    }
}
