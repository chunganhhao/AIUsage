import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import QuotaBackend

@main
struct CodexSwitchTokenLossRegression {
    static var checks = 0

    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String, file: StaticString = #file, line: UInt = #line) rethrows {
        checks += 1
        guard try condition() else {
            fatalError("FAIL [\(file):\(line)]: \(message)")
        }
    }

    static func jwt(_ payload: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(b64).sig"
    }

    static func authPayload(
        account: String,
        user: String,
        email: String,
        refresh: String,
        iat: Int,
        lastRefresh: String
    ) throws -> (access: String, data: Data) {
        let access = try jwt([
            "iat": iat,
            "exp": iat + 86_400,
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": account,
                "chatgpt_user_id": user
            ]
        ])
        let data = try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": lastRefresh,
            "tokens": [
                "account_id": account,
                "access_token": access,
                "refresh_token": refresh,
                "id_token": access
            ]
        ], options: [.sortedKeys])
        return (access, data)
    }

    static func cpaPayload(
        account: String,
        user: String,
        email: String,
        ownerCredentialId: String,
        refresh: String,
        iat: Int,
        lastRefresh: String
    ) throws -> Data {
        let access = try jwt([
            "iat": iat,
            "exp": iat + 86_400,
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": account,
                "chatgpt_user_id": user
            ]
        ])
        return try JSONSerialization.data(withJSONObject: [
            "type": "codex",
            "email": email,
            "aiusage_credential_id": ownerCredentialId,
            "account_id": account,
            "access_token": access,
            "refresh_token": refresh,
            "id_token": access,
            "expired": "2020-01-01T00:00:00Z",
            "last_refresh": lastRefresh,
            "tokens": [
                "account_id": account,
                "access_token": access,
                "refresh_token": refresh,
                "id_token": access
            ]
        ], options: [.sortedKeys])
    }

    static func readJSON(_ url: URL) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }

    static func refreshToken(at url: URL) throws -> String? {
        let json = try readJSON(url)
        return ((json["tokens"] as? [String: Any])?["refresh_token"] ?? json["refresh_token"]) as? String
    }

    @MainActor
    static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("codex-switch-token-loss-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try await testSwitchAndRestartPreservesOutgoingTokens(root: root, fm: fm)
        try testEphemeralSourcePathAndReLoginPreservation(root: root, fm: fm)
        try await testProviderHealsAndRecoversWithoutSourcePath(root: root, fm: fm)

        print("PASS: \(checks) switch/restart Codex token loss regression checks passed (production activation slices, store metadata, CodexProvider recovery)")
    }

    /// 1+2: Switching A -> B flushes A's live token to AuthImports + linked CPA, and Restart Codex (reapply B) keeps A in .bak.
    @MainActor
    static func testSwitchAndRestartPreservesOutgoingTokens(root: URL, fm: FileManager) async throws {
        let scenario = root.appendingPathComponent("switch-restart", isDirectory: true)
        let dotCodex = scenario.appendingPathComponent("dotcodex", isDirectory: true)
        let managedDir = scenario.appendingPathComponent("AuthImports/codex", isDirectory: true)
        let cpaDir = scenario.appendingPathComponent("CLIProxyAPI/auth", isDirectory: true)
        try fm.createDirectory(at: dotCodex, withIntermediateDirectories: true)
        try fm.createDirectory(at: managedDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cpaDir, withIntermediateDirectories: true)

        CodexLinkedCredentialCopies.resetForTesting()
        CodexLinkedCredentialCopies.registerDirectory(cpaDir)
        defer { CodexLinkedCredentialCopies.resetForTesting() }

        let now = Int(Date().timeIntervalSince1970)
        let aStale = try authPayload(account: "acct-A", user: "user-A", email: "nhntrong@example.invalid", refresh: "rt-A-consumed", iat: now - 600, lastRefresh: "2026-11-11T00:00:00Z")
        let aFresh = try authPayload(account: "acct-A", user: "user-A", email: "nhntrong@example.invalid", refresh: "rt-A-live-fresh", iat: now - 30, lastRefresh: "2026-11-12T06:00:00Z")
        let bCurrent = try authPayload(account: "acct-B", user: "user-B", email: "chunganhhao@example.invalid", refresh: "rt-B-valid", iat: now - 10, lastRefresh: "2026-11-12T06:10:00Z")

        let managedA = managedDir.appendingPathComponent("a.json")
        let cpaA = cpaDir.appendingPathComponent("aiusage-codex-a.json")
        let managedB = managedDir.appendingPathComponent("b.json")
        let liveAuth = dotCodex.appendingPathComponent("auth.json")
        let liveBak = dotCodex.appendingPathComponent("auth.json.bak")

        try aStale.data.write(to: managedA)
        try cpaPayload(account: "acct-A", user: "user-A", email: "nhntrong@example.invalid", ownerCredentialId: "cred-A", refresh: "rt-A-cpa-consumed", iat: now - 700, lastRefresh: "2026-11-10T00:00:00Z")
            .write(to: cpaA)
        try bCurrent.data.write(to: managedB)
        try aFresh.data.write(to: liveAuth)

        let credA = AccountCredential(
            id: "cred-A",
            providerId: "codex",
            accountLabel: "nhntrong@example.invalid",
            authMethod: .authFile,
            credential: managedA.path,
            metadata: ["accountId": "acct-A", "workspaceUserId": "user-A", "accountEmail": "nhntrong@example.invalid"]
        )
        let credB = AccountCredential(
            id: "cred-B",
            providerId: "codex",
            accountLabel: "chunganhhao@example.invalid",
            authMethod: .authFile,
            credential: managedB.path,
            metadata: ["accountId": "acct-B", "workspaceUserId": "user-B", "accountEmail": "chunganhhao@example.invalid"]
        )
        AccountCredentialStore.shared.credentials = [credA, credB]
        defer { AccountCredentialStore.shared.credentials = [] }

        let harness = ActivationHarness()
        let identityA = CodexAccountIdentity(credential: credA)
        let identityB = CodexAccountIdentity(credential: credB)

        // Step 1: User clicks Switch Account from A -> B.
        try harness.activateSlice(selected: ActivationTarget(authFileURL: managedB, expectedIdentity: identityB), testCodexDir: dotCodex.path)

        try check(try refreshToken(at: managedA) == "rt-A-live-fresh", "Switch A->B must flush live A refresh_token to managed AuthImports before overwriting ~/.codex/auth.json")
        let healedCPA = try readJSON(cpaA)
        check(healedCPA["type"] as? String == "codex", "Linked CPA copy must retain type")
        check(healedCPA["aiusage_credential_id"] as? String == "cred-A", "Linked CPA copy must retain aiusage_credential_id")
        check(healedCPA["refresh_token"] as? String == "rt-A-live-fresh", "Linked CPA copy top-level refresh_token must be healed")
        check((healedCPA["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-A-live-fresh", "Linked CPA copy nested refresh_token must be healed")
        let expectedCPAExpired = SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: Double((now - 30) + 86_400)))
        check(healedCPA["expired"] as? String == expectedCPAExpired, "Linked CPA copy must update stale past expired timestamp from adopted JWT exp")
        try check(!(try CodexProvider().loadCredentials(from: cpaA.path)).needsRefresh, "Healed CPA copy must not remain marked needsRefresh")
        try check(CodexAccountIdentity(authJSON: try readJSON(liveAuth)).matches(identityB), "Live auth.json must now be incoming account B")
        try check(CodexAccountIdentity(authJSON: try readJSON(liveBak)).matches(identityA) && (try refreshToken(at: liveBak)) == "rt-A-live-fresh",
              "Live auth.json.bak must preserve outgoing A")

        // Step 2: User immediately clicks Restart Codex on B.
        try await harness.reapplySlice(selected: ActivationTarget(authFileURL: managedB, expectedIdentity: identityB), testCodexDir: dotCodex.path)

        try check(CodexAccountIdentity(authJSON: try readJSON(liveAuth)).matches(identityB), "Restart Codex keeps B in auth.json")
        try check(CodexAccountIdentity(authJSON: try readJSON(liveBak)).matches(identityA), "Restart Codex must NOT overwrite foreign outgoing A in auth.json.bak")
        try check(try refreshToken(at: liveBak) == "rt-A-live-fresh", "Restart Codex must preserve A's fresh refresh_token in auth.json.bak")

        // Step 2b: If atomic write fails during Restart Codex, catch must NOT roll back foreign A from .bak onto auth.json.
        let oversizedAccessB = try jwt([
            "iat": now - 5,
            "exp": (now - 5) + 86_400,
            "email": "chunganhhao@example.invalid",
            "pad": String(repeating: "b", count: 4096),
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-B",
                "chatgpt_user_id": "user-B"
            ]
        ])
        let managedBPadded = root.appendingPathComponent("managed-B-padded.json")
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T06:30:00Z",
            "tokens": [
                "account_id": "acct-B",
                "access_token": oversizedAccessB,
                "refresh_token": "rt-B-padded",
                "id_token": oversizedAccessB
            ]
        ], options: [.sortedKeys]).write(to: managedBPadded)
        var rollbackWriteFailed = false
        #if canImport(Darwin)
        var origLimit = rlimit()
        if getrlimit(RLIMIT_FSIZE, &origLimit) == 0 {
            let prevSig = signal(SIGXFSZ, SIG_IGN)
            var lowLimit = rlimit(rlim_cur: rlim_t(max(bCurrent.data.count, aFresh.data.count) + 512), rlim_max: origLimit.rlim_max)
            _ = setrlimit(RLIMIT_FSIZE, &lowLimit)
            defer {
                _ = setrlimit(RLIMIT_FSIZE, &origLimit)
                _ = signal(SIGXFSZ, prevSig)
            }
            do {
                try await harness.reapplySlice(selected: ActivationTarget(authFileURL: managedBPadded, expectedIdentity: identityB), testCodexDir: dotCodex.path)
            } catch {
                rollbackWriteFailed = true
            }
        }
        #endif
        check(rollbackWriteFailed, "Oversized atomic write under RLIMIT_FSIZE must fail so rollback branch executes")
        try check(CodexAccountIdentity(authJSON: try readJSON(liveAuth)).matches(identityB) && (try refreshToken(at: liveAuth)) == "rt-B-valid",
                  "Failed Restart write must keep B in auth.json and NEVER roll back foreign A from .bak")
        try check(CodexAccountIdentity(authJSON: try readJSON(liveBak)).matches(identityA) && (try refreshToken(at: liveBak)) == "rt-A-live-fresh",
                  "Failed Restart write must leave preserved foreign A intact in auth.json.bak")

        // Step 3: Same-account restart when .bak ALREADY holds same account B still refreshes .bak.
        let liveBNewer = try authPayload(account: "acct-B", user: "user-B", email: "chunganhhao@example.invalid", refresh: "rt-B-rotated", iat: now, lastRefresh: "2026-11-12T07:00:00Z")
        try bCurrent.data.write(to: liveBak)
        try liveBNewer.data.write(to: liveAuth)
        try await harness.reapplySlice(selected: ActivationTarget(authFileURL: managedB, expectedIdentity: identityB), testCodexDir: dotCodex.path)
        try check(try refreshToken(at: liveBak) == "rt-B-rotated", "Same-identity backup updates normally when .bak belongs to the same account")
    }

    /// 3a: Ephemeral login temp dirs are never persisted in sourcePath, stale temp paths are stripped, durable sourcePath is kept across re-login.
    static func testEphemeralSourcePathAndReLoginPreservation(root: URL, fm: FileManager) throws {
        let loginTemp = fm.temporaryDirectory
            .appendingPathComponent("aiusage-codex-login-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("auth.json")
            .path
        check(AccountCredentialStore.isEphemeralTemporaryAuthPath(loginTemp), "Login coordinator temp path must be flagged ephemeral")
        check(AccountCredentialStore.persistentSourcePath(from: loginTemp) == nil, "Ephemeral login temp path must not be stored as sourcePath")
        check(AccountCredentialStore.isEphemeralTemporaryAuthPath("/tmp/aiusage-codex-login-abc/auth.json"), "/tmp codex login dir must be flagged ephemeral")
        check(AccountCredentialStore.persistentSourcePath(from: "/Users/example/.codex/auth.json") == "/Users/example/.codex/auth.json",
              "Durable sourcePath must be preserved")

        let store = AccountStore.shared
        AccountCredentialStore.shared.credentials = []
        SecureAccountVault.shared.accounts = []
        defer {
            AccountCredentialStore.shared.credentials = []
            SecureAccountVault.shared.accounts = []
        }

        func codexUsage(account: String, user: String, email: String) -> ProviderUsage {
            var usage = ProviderUsage(provider: "codex", label: "Codex")
            usage.usageAccountId = account
            usage.accountEmail = email
            usage.accountPlan = "Plus"
            usage.extra["userId"] = AnyCodable(user)
            return usage
        }

        let managedA = root.appendingPathComponent("relogin-a.json")
        try Data("{}".utf8).write(to: managedA)

        // Old broken credential had an ephemeral temp sourcePath recorded.
        let initialWithTemp = AccountCredential(
            id: "cred-relogin",
            providerId: "codex",
            accountLabel: "user@example.invalid",
            authMethod: .authFile,
            credential: managedA.path,
            metadata: [
                "accountId": "acct-1",
                "workspaceUserId": "user-1",
                "sourcePath": loginTemp
            ]
        )
        _ = try store.registerAuthenticatedCredential(
            initialWithTemp,
            usage: codexUsage(account: "acct-1", user: "user-1", email: "user@example.invalid"),
            note: nil,
            providerDisplayTitle: "Codex",
            insertImmediateProviderData: { _, _, _, _ in },
            ensureProviderSelected: { _ in }
        )

        // Re-login with empty incoming sourcePath (ephemeral filtered out) cleans stale ephemeral sourcePath.
        let reloginEmptySource = AccountCredential(
            id: "cred-relogin-2",
            providerId: "codex",
            accountLabel: "user@example.invalid",
            authMethod: .authFile,
            credential: managedA.path,
            metadata: [
                "accountId": "acct-1",
                "workspaceUserId": "user-1",
                "sourcePath": ""
            ]
        )
        _ = try store.registerAuthenticatedCredential(
            reloginEmptySource,
            usage: codexUsage(account: "acct-1", user: "user-1", email: "user@example.invalid"),
            note: nil,
            providerDisplayTitle: "Codex",
            insertImmediateProviderData: { _, _, _, _ in },
            ensureProviderSelected: { _ in }
        )
        let savedAfterClean = AccountCredentialStore.shared.loadCredentials(for: "codex").first
        check(savedAfterClean?.metadata["sourcePath"] == "", "Old ephemeral temp sourcePath must be cleared on re-login")

        // Next, import/re-connect with durable ~/.codex/auth.json, then re-login via isolated login dir (incoming "").
        let durableConnect = AccountCredential(
            id: savedAfterClean!.id,
            providerId: "codex",
            accountLabel: "user@example.invalid",
            authMethod: .authFile,
            credential: managedA.path,
            metadata: [
                "accountId": "acct-1",
                "workspaceUserId": "user-1",
                "sourcePath": "/Users/example/.codex/auth.json"
            ]
        )
        _ = try store.registerAuthenticatedCredential(
            durableConnect,
            usage: codexUsage(account: "acct-1", user: "user-1", email: "user@example.invalid"),
            note: nil,
            providerDisplayTitle: "Codex",
            insertImmediateProviderData: { _, _, _, _ in },
            ensureProviderSelected: { _ in }
        )
        _ = try store.registerAuthenticatedCredential(
            reloginEmptySource,
            usage: codexUsage(account: "acct-1", user: "user-1", email: "user@example.invalid"),
            note: nil,
            providerDisplayTitle: "Codex",
            insertImmediateProviderData: { _, _, _, _ in },
            ensureProviderSelected: { _ in }
        )
        let preserved = AccountCredentialStore.shared.loadCredentials(for: "codex").first?.metadata["sourcePath"]
        check(preserved == "/Users/example/.codex/auth.json", "Re-login with filtered ephemeral sourcePath must preserve existing durable sourcePath")
    }

    /// 3b: CodexProvider heals & recovers from homeDirectory/.codex/auth.json(.bak) even when sourcePath is nil or points to deleted temp dir.
    static func testProviderHealsAndRecoversWithoutSourcePath(root: URL, fm: FileManager) async throws {
        let home = root.appendingPathComponent("home-recovery", isDirectory: true)
        let dotCodex = home.appendingPathComponent(".codex", isDirectory: true)
        let cpaDir = home.appendingPathComponent("cpa", isDirectory: true)
        try fm.createDirectory(at: dotCodex, withIntermediateDirectories: true)
        try fm.createDirectory(at: cpaDir, withIntermediateDirectories: true)

        CodexLinkedCredentialCopies.resetForTesting()
        CodexLinkedCredentialCopies.registerDirectory(cpaDir)
        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
        defer {
            StubURLProtocol.uninstall()
            CodexLinkedCredentialCopies.resetForTesting()
        }

        let usageURL = "https://chatgpt.com/backend-api/wham/usage"
        let oauthURL = "https://auth.openai.com/oauth/token"
        let now = Int(Date().timeIntervalSince1970)

        let aStale = try authPayload(account: "ws-recovery", user: "user-A", email: "a@example.invalid", refresh: "rt-stale", iat: now - 500, lastRefresh: "2026-11-11T00:00:00Z")
        let aFresh = try authPayload(account: "ws-recovery", user: "user-A", email: "a@example.invalid", refresh: "rt-live-bak", iat: now - 10, lastRefresh: "2026-11-12T06:00:00Z")
        let bForeign = try authPayload(account: "ws-recovery", user: "user-B", email: "b@example.invalid", refresh: "rt-foreign-B", iat: now, lastRefresh: "2026-11-12T06:05:00Z")

        let managedA = home.appendingPathComponent("managed-a.json")
        let cpaA = cpaDir.appendingPathComponent("aiusage-codex-a.json")
        let liveAuth = dotCodex.appendingPathComponent("auth.json")
        let liveBak = dotCodex.appendingPathComponent("auth.json.bak")

        try aStale.data.write(to: managedA)
        try cpaPayload(account: "ws-recovery", user: "user-A", email: "a@example.invalid", ownerCredentialId: "cred-rec-A", refresh: "rt-cpa-stale", iat: now - 600, lastRefresh: "2026-11-10T00:00:00Z")
            .write(to: cpaA)
        try bForeign.data.write(to: liveAuth)
        try aFresh.data.write(to: liveBak)
        let liveAuthBefore = try Data(contentsOf: liveAuth)

        StubURLProtocol.respond(usageURL) { req in
            if req.headers["Authorization"] == "Bearer \(aFresh.access)" {
                return (200, #"{"plan_type":"plus"}"#)
            }
            return (401, "{}")
        }
        StubURLProtocol.respond(oauthURL, status: 400, body: #"{"error":"refresh_token_reused"}"#)

        let credDeletedSource = AccountCredential(
            id: "cred-rec-A",
            providerId: "codex",
            authMethod: .authFile,
            credential: managedA.path,
            metadata: [
                "accountId": "ws-recovery",
                "workspaceUserId": "user-A",
                "sourcePath": "/var/folders/deleted/aiusage-codex-login-dead/auth.json"
            ]
        )

        let provider = CodexProvider(homeDirectory: home.path)
        _ = try await provider.fetchUsage(with: credDeletedSource)

        try check(try refreshToken(at: managedA) == "rt-live-bak", "Managed copy must heal from .codex/auth.json.bak when sourcePath is deleted temp dir")
        try check(try refreshToken(at: cpaA) == "rt-live-bak", "Linked CPA copy must also heal alongside managed copy")
        try check(try Data(contentsOf: liveAuth) == liveAuthBefore, "Foreign .codex/auth.json must never be modified or adopted")

        // Direct recoverFromSourceAndRead check: managed copy without refresh_token gets 401 and has nil sourcePath,
        // yet rescues from homeDirectory/.codex/auth.json.bak.
        let managedNoRefresh = home.appendingPathComponent("managed-no-refresh.json")
        let noRefreshAccess = try jwt([
            "iat": now - 500,
            "exp": now + 86_400,
            "email": "a@example.invalid",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "ws-recovery",
                "chatgpt_user_id": "user-A"
            ]
        ])
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T05:59:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": noRefreshAccess,
                "id_token": noRefreshAccess
            ]
        ], options: [.sortedKeys]).write(to: managedNoRefresh)
        let credNoSource = AccountCredential(
            id: "cred-rec-no-rt",
            providerId: "codex",
            authMethod: .authFile,
            credential: managedNoRefresh.path,
            metadata: ["accountId": "ws-recovery", "workspaceUserId": "user-A"]
        )
        _ = try await provider.fetchUsage(with: credNoSource)
        try check(try refreshToken(at: managedNoRefresh) == "rt-live-bak", "recoverFromSourceAndRead must rescue from .codex/auth.json.bak even when sourcePath is nil")

        // Equal-iat tie-break: explicit no-refresh source at exact same second yields to .codex/auth.json.bak with valid refresh_token.
        let sameSecondNoRefresh = try jwt([
            "jti": "same-second-explicit-no-rt",
            "iat": now - 10,
            "exp": (now - 10) + 86_400,
            "email": "a@example.invalid",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "ws-recovery",
                "chatgpt_user_id": "user-A"
            ]
        ])
        let sameSecondExplicit = home.appendingPathComponent("same-second-explicit.json")
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T06:00:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": sameSecondNoRefresh,
                "id_token": sameSecondNoRefresh
            ]
        ], options: [.sortedKeys]).write(to: sameSecondExplicit)
        let tiedManaged = home.appendingPathComponent("managed-tied.json")
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T05:59:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": noRefreshAccess,
                "id_token": noRefreshAccess
            ]
        ], options: [.sortedKeys]).write(to: tiedManaged)
        let credTied = AccountCredential(
            id: "cred-rec-tied",
            providerId: "codex",
            authMethod: .authFile,
            credential: tiedManaged.path,
            metadata: [
                "accountId": "ws-recovery",
                "workspaceUserId": "user-A",
                "sourcePath": sameSecondExplicit.path
            ]
        )
        StubURLProtocol.respond(usageURL) { req in
            req.headers["Authorization"] == "Bearer \(aFresh.access)" ? (200, #"{"plan_type":"plus"}"#) : (401, "{}")
        }
        _ = try await provider.fetchUsage(with: credTied)
        try check(try refreshToken(at: tiedManaged) == "rt-live-bak", "Equal-iat tie-break in recoverFromSourceAndRead must prefer candidate with refreshToken")

        // Equal-iat reverse case: explicit usable access token (without refresh_token) must NOT be displaced by a
        // known-rejected access token in .codex/auth.json.bak even when .bak also carries a refresh_token.
        let equalIat = now - 5
        let rejectedAccess = try jwt([
            "jti": "equal-iat-rejected",
            "iat": equalIat,
            "exp": equalIat + 86_400,
            "email": "a@example.invalid",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "ws-recovery",
                "chatgpt_user_id": "user-A"
            ]
        ])
        let goodAccessNoRT = try jwt([
            "jti": "equal-iat-good-no-rt",
            "iat": equalIat,
            "exp": equalIat + 86_400,
            "email": "a@example.invalid",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "ws-recovery",
                "chatgpt_user_id": "user-A"
            ]
        ])
        let revManaged = home.appendingPathComponent("managed-rev-tied.json")
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T06:00:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": rejectedAccess,
                "id_token": rejectedAccess
            ]
        ], options: [.sortedKeys]).write(to: revManaged)
        let revExplicit = home.appendingPathComponent("explicit-good-no-rt.json")
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T06:00:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": goodAccessNoRT,
                "id_token": goodAccessNoRT
            ]
        ], options: [.sortedKeys]).write(to: revExplicit)
        let savedLiveBak = try Data(contentsOf: liveBak)
        defer { try? savedLiveBak.write(to: liveBak, options: .atomic) }
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T06:00:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": rejectedAccess,
                "refresh_token": "rt-consumed-bak",
                "id_token": rejectedAccess
            ]
        ], options: [.sortedKeys]).write(to: liveBak)
        let revCred = AccountCredential(
            id: "cred-rec-rev-tied",
            providerId: "codex",
            authMethod: .authFile,
            credential: revManaged.path,
            metadata: [
                "accountId": "ws-recovery",
                "workspaceUserId": "user-A",
                "sourcePath": revExplicit.path
            ]
        )
        StubURLProtocol.respond(usageURL) { req in
            req.headers["Authorization"] == "Bearer \(goodAccessNoRT)" ? (200, #"{"plan_type":"plus"}"#) : (401, "{}")
        }
        _ = try await provider.fetchUsage(with: revCred)
        let revHealed = try CodexProvider(homeDirectory: home.path).loadCredentials(from: revManaged.path)
        check(revHealed.accessToken == goodAccessNoRT,
              "Equal-iat recovery must prefer usable access_token over known-rejected access_token even if rejected candidate has refresh_token")

        // Preserves workspace_mismatch when explicit sourcePath is foreign and no matching .codex fallback exists.
        try? fm.removeItem(at: liveBak)
        let foreignOnlyCred = AccountCredential(
            id: "cred-rec-mismatch",
            providerId: "codex",
            authMethod: .authFile,
            credential: managedNoRefresh.path,
            metadata: [
                "accountId": "ws-recovery",
                "workspaceUserId": "user-A",
                "sourcePath": liveAuth.path
            ]
        )
        try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": "2026-11-12T05:59:00Z",
            "tokens": [
                "account_id": "ws-recovery",
                "access_token": noRefreshAccess,
                "id_token": noRefreshAccess
            ]
        ], options: [.sortedKeys]).write(to: managedNoRefresh)
        var gotWorkspaceMismatch = false
        do {
            _ = try await provider.fetchUsage(with: foreignOnlyCred)
        } catch let error as ProviderError {
            gotWorkspaceMismatch = (error.code == "workspace_mismatch")
        }
        check(gotWorkspaceMismatch, "Explicit foreign sourcePath without matching .codex fallback must still report workspace_mismatch")
    }
}
