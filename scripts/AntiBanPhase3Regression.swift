import Foundation
import QuotaBackend

@main
struct AntiBanPhase3Regression {
    static var checks = 0
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        checks += 1
    }

    static func main() throws {
        try vaultRecency()
        try runtimeLayout()
        print("PASS: \(checks) anti-ban Phase 3 assertions (vault writes, legacy/v8 CPA YAML, isolated files)")
    }

    static func vaultRecency() throws {
        var persisted: Data?
        var writes = 0
        var failWrite = false
        let store = AccountCredentialStore(readVaultData: { persisted }, writeVaultData: { data in
            if failWrite { throw CredentialStoreError.keychainWriteFailed(-1) }
            writes += 1
            persisted = data
        })
        var credential = AccountCredential(id: "c", providerId: "codex", accountLabel: "a@example.com", authMethod: .authFile,
                                           credential: "/isolated/a.json", metadata: [:])
        try store.saveCredential(credential)
        let afterSave = writes
        for _ in 0..<100 { store.updateLastUsed(credential) }
        check(writes == afterSave, "polling unchanged credentials must not rewrite the vault")
        check(store.loadCredential(providerId: "codex", credentialId: "c")?.lastUsedAt != nil, "recency must remain visible in memory")
        let fresh = AccountCredentialStore(readVaultData: { persisted }, writeVaultData: { _ in })
        check(fresh.loadCredential(providerId: "codex", credentialId: "c")?.lastUsedAt == nil, "timestamp-only polls must not persist")
        let verified = CodexAccountIdentity(accountId: "acct", userId: "user", email: "a@example.com")
        store.updateLastUsed(credential, codexIdentity: verified)
        check(writes == afterSave + 1, "new verified native identity must persist immediately")
        credential = store.loadCredential(providerId: "codex", credentialId: "c")!
        check(credential.metadata["accountId"] == "acct" && credential.metadata["workspaceUserId"] == "user", "native identity must not be lost")
        for _ in 0..<100 { store.updateLastUsed(credential, codexIdentity: verified) }
        check(writes == afterSave + 1, "the same identity must not trigger full-vault writes")
        let replacement = AccountCredential(id: "c", providerId: "codex", accountLabel: "other@example.com", authMethod: .authFile,
                                            credential: "/isolated/new.json", metadata: ["accountId": "other", "workspaceUserId": "other"])
        try store.saveCredential(replacement)
        let beforeStale = writes
        store.updateLastUsed(credential, codexIdentity: verified)
        check(writes == beforeStale, "stale request must not persist old native identity")
        check(store.loadCredential(providerId: "codex", credentialId: "c")?.metadata["accountId"] == "other", "stale request must not overwrite replacement")
        try store.deleteCredential(replacement)
        let afterDelete = writes
        store.updateLastUsed(credential, codexIdentity: verified)
        check(writes == afterDelete && store.loadCredential(providerId: "codex", credentialId: "c") == nil, "poll completion must not resurrect deleted credentials")
        var incomplete = replacement
        incomplete.metadata = [:]
        try store.saveCredential(incomplete)
        failWrite = true
        store.updateLastUsed(incomplete, codexIdentity: verified)
        check(store.loadCredential(providerId: "codex", credentialId: "c")?.metadata["accountId"] == nil, "failed identity persistence must not claim durable success")
        failWrite = false
        store.updateLastUsed(incomplete, codexIdentity: verified)
        check(store.loadCredential(providerId: "codex", credentialId: "c")?.metadata["accountId"] == "acct", "failed native identity write must be retried")
    }

    static func runtimeLayout() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("anti-ban-phase3-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try CLIProxyPaths(root: root)
        try paths.prepare()
        let store = CLIProxyConfigStore(paths: paths)
        let secrets = CLIProxySecrets(managementKey: "management-only", clientAPIKey: "cpa-client-test")
        let protection = root.appendingPathComponent("pool-protection.json")
        var enabledSettings = CLIProxyGatewaySettings.default
        enabledSettings.enablePlugins = true
        try store.writeRuntimeConfig(settings: enabledSettings, secrets: secrets)
        let generated = try String(contentsOf: paths.configURL, encoding: .utf8)
        check(generated.contains("plugins:\n  enabled: true\n  dir: \"\(paths.pluginsDirectory.path)\""), "generated plugin block must stay compatible with legacy migration fixtures")
        let alias = "oauth-model-alias:\n  antigravity:\n    - name: original\n      alias: retained\n"
        try ("antigravity:\n  tos-pause-window: \"2h\"\n  sensitive-words:\n    - kept\n" + alias).write(to: paths.configURL, atomically: true, encoding: .utf8)
        try store.writeRuntimeConfig(settings: .default, secrets: secrets)
        var config = try String(contentsOf: paths.configURL, encoding: .utf8)
        check(config.contains("tos-pause-window: \"2h\""), "unmanaged external TOS window must stay untouched")
        try Data(#"{"enabled":true}"#.utf8).write(to: protection)
        try store.writeRuntimeConfig(settings: .default, secrets: secrets)
        config = try String(contentsOf: paths.configURL, encoding: .utf8)
        check(config.contains("tos-pause-window: \"6h\""), "Pool Protection opt-in must arm CPA pause")
        check(config.contains(alias.trimmingCharacters(in: .newlines)), "legacy aliases must stay byte-for-byte intact")
        check(config.contains("sensitive-words:\n    - kept"), "existing provider fields must survive")
        try store.syncPoolProtectionPause(enabled: false)
        check(try String(contentsOf: paths.configURL, encoding: .utf8).contains("tos-pause-window: \"0\""), "explicit Off must clear CPA pause")
        let fourSpace = "config-version: 8\noauth:\n    providers:\n        antigravity:\n            tos-pause-window: \"2h\"\n"
        try fourSpace.write(to:paths.configURL,atomically:true,encoding:.utf8)
        do { try store.syncPoolProtectionPause(enabled:true); preconditionFailure("unsupported indentation must not create duplicate providers") }
        catch { check(true, "four-space edited YAML fails closed") }
        check(try String(contentsOf:paths.configURL,encoding:.utf8) == fourSpace, "four-space YAML remains byte-identical")
        let v8 = """
        config-version: 8
        server:
          host: "0.0.0.0"
          port: 19999
        access:
          api-keys:
            - "external-client"
        api-keys:
          gemini:
            - name: keep-upstream
              keys:
                - api-key: "upstream-secret"
        oauth: # preserve this section
          providers:
            antigravity:
              tos-pause-window: "2h"
              connection-pool:
                enabled: false
          model-alias:
            antigravity:
              - name: native
                alias: keep-alias
        plugins:
          enabled: false
        """ + "\n"
        try v8.write(to: paths.configURL, atomically: true, encoding: .utf8)
        try store.writeRuntimeConfig(settings: .default, secrets: secrets)
        config = try String(contentsOf: paths.configURL, encoding: .utf8)
        check(config.contains("server:\n  host: \"127.0.0.1\"\n  port: 14420"), "v8 server values must update at canonical paths")
        check(!config.split(separator: "\n").contains(where: { $0.hasPrefix("host:") || $0.hasPrefix("port:") || $0.hasPrefix("auth-dir:") || $0.hasPrefix("antigravity:") }), "v8 must not gain ignored legacy managed keys")
        check(config.contains("      tos-pause-window: \"6h\""), "v8 pause must live under oauth.providers.antigravity")
        check(config.contains("    - name: native\n        alias: keep-alias") || config.contains("      - name: native\n        alias: keep-alias"), "v8 aliases must survive")
        check(config.contains("api-key: \"upstream-secret\""), "v8 upstream API-key groups must not be deleted")
        check(config.components(separatedBy: "tos-pause-window:").count == 2, "v8 pause must not duplicate")
        check(try store.runtimeClientAPIKeys() == ["external-client", "cpa-client-test"], "v8 client keys must read from access not provider groups")
        try store.syncPoolProtectionPause(enabled: false)
        config = try String(contentsOf: paths.configURL, encoding: .utf8)
        check(config.contains("      tos-pause-window: \"0\""), "v8 explicit Off must use same canonical path")
        try Data(#"{"enabled":false}"#.utf8).write(to: protection)
        try store.writeRuntimeConfig(settings: .default, secrets: secrets)
        config = try String(contentsOf: paths.configURL, encoding: .utf8)
        check(config.contains("      tos-pause-window: \"0\""), "runtime regeneration must not re-arm an explicit Off")
        try "config-version: 8\napi-keys:\n  - \"legacy-external\"\n".write(to: paths.configURL, atomically: true, encoding: .utf8)
        check(try store.runtimeClientAPIKeys() == ["legacy-external"], "mixed-layout client key read must use effective legacy fallback")
        try store.writeRuntimeConfig(settings: .default, secrets: secrets)
        check(try store.runtimeClientAPIKeys() == ["legacy-external", "cpa-client-test"], "legacy fallback keys must survive v8 canonicalization")
        for bad in ["config-version: 9\n", "oauth: {providers: {antigravity: {tos-pause-window: 1h}}}\n", "antigravity:\n  tos-pause-window: 1h\n  tos-pause-window: 2h\n", "oauth:\n  providers:\n    antigravity: {}\n", "oauth:\n  providers:\n    antigravity:\n    antigravity:\n"] {
            try bad.write(to: paths.configURL, atomically: true, encoding: .utf8)
            var failed = false
            do { try store.syncPoolProtectionPause(enabled: true) } catch { failed = true }
            check(failed, "ambiguous/unsupported YAML must fail closed")
            check(try String(contentsOf: paths.configURL, encoding: .utf8) == bad, "failed YAML edit must leave bytes unchanged")
        }
    }
}
