import CryptoKit
import Darwin
import Foundation
import Network
import SQLite3
@testable import QuotaBackend
@testable import QuotaServerCore

private struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

private var assertionCount = 0

private func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    assertionCount += 1
    if !condition() {
        throw CheckFailure(description: "FAILED [\(assertionCount)]: \(message)")
    }
}

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ initial: Date) {
        self.current = initial
    }

    func now() -> Date {
        lock.withLock { current }
    }

    func set(_ newDate: Date) {
        lock.withLock { current = newDate }
    }

    func advance(by seconds: TimeInterval) {
        lock.withLock { current = current.addingTimeInterval(seconds) }
    }
}

private func makeJWT(email: String?, accountId: String?, userId: String?, plan: String = "plus") throws -> String {
    var payload: [String: Any] = ["sub": userId ?? "sub-default"]
    if let email { payload["email"] = email }
    var auth: [String: Any] = ["chatgpt_plan_type": plan]
    if let accountId { auth["chatgpt_account_id"] = accountId }
    if let userId { auth["chatgpt_user_id"] = userId }
    payload["https://api.openai.com/auth"] = auth
    let headerData = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"])
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    func b64u(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    return "\(b64u(headerData)).\(b64u(payloadData)).sig"
}

private func writeCodexAuth(
    to url: URL,
    accountId: String,
    userId: String,
    email: String,
    accessToken: String,
    refreshToken: String
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let idToken = try makeJWT(email: email, accountId: accountId, userId: userId)
    let obj: [String: Any] = [
        "last_refresh": SharedFormatters.iso8601String(from: Date()),
        "tokens": [
            "account_id": accountId,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "id_token": idToken
        ]
    ]
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
}

private func writeAGYAuth(
    to url: URL,
    email: String,
    accessToken: String,
    refreshToken: String,
    projectId: String? = nil,
    extraFields: [String: Any] = [:]
) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    var obj: [String: Any] = [
        "email": email,
        "access_token": accessToken,
        "refresh_token": refreshToken,
        "expired": "2099-01-01T00:00:00Z"
    ]
    if let projectId { obj["project_id"] = projectId }
    for (k, v) in extraFields { obj[k] = v }
    let data = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    try data.write(to: url, options: .atomic)
}

@main
struct PostR6AntiBanCacheRegression {
    static func main() async throws {
        let scratchRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-r6-backend-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratchRoot, withIntermediateDirectories: true)
        defer {
            StubURLProtocol.uninstall()
            try? FileManager.default.removeItem(at: scratchRoot)
        }

        let codexUsageURL = "https://chatgpt.com/backend-api/wham/usage"
        let codexRefreshURL = "https://auth.openai.com/oauth/token"
        let agyLoadURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
        let agyQuotaURL = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        let agyRefreshURL = "https://oauth2.googleapis.com/token"
        let codexUsageOK = #"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600},"secondary_window":{"used_percent":40,"limit_window_seconds":604800,"reset_after_seconds":86400}}}"#
        let agyLoadOK = #"{"cloudaicompanionProject":"proj-default","currentTier":{"id":"pro","name":"Pro"}}"#
        let agyQuotaOK = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-5h","window":"5h","remainingFraction":0.8,"resetTime":"2099-01-01T00:00:00Z"}]}]}"#

        // 1. [A1] Antigravity .localOnly default across all passive/global/provider/HTTP triggers + legacy credential guard
        do {
            let home = scratchRoot.appendingPathComponent("agy-local-only", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let store = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })

            let c0Path = home.appendingPathComponent("creds/agy0.json")
            let c1Path = home.appendingPathComponent("creds/agy1.json")
            let c2Path = home.appendingPathComponent("creds/agy2.json")
            try writeAGYAuth(to: c0Path, email: "active@example.invalid", accessToken: "secret-agy-tok-0", refreshToken: "secret-agy-ref-0", projectId: "proj-0")
            try writeAGYAuth(to: c1Path, email: "dormant1@example.invalid", accessToken: "secret-agy-tok-1", refreshToken: "secret-agy-ref-1", projectId: "proj-1")
            try writeAGYAuth(to: c2Path, email: "dormant2@example.invalid", accessToken: "secret-agy-tok-2", refreshToken: "secret-agy-ref-2", projectId: "proj-2", extraFields: [
                "scope": "openid https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog"
            ])

            let cred0 = AccountCredential(id: "agy-0", providerId: "antigravity", accountLabel: "active@example.invalid", authMethod: .authFile, credential: c0Path.path)
            let cred1 = AccountCredential(id: "agy-1", providerId: "antigravity", accountLabel: "dormant1@example.invalid", authMethod: .authFile, credential: c1Path.path)
            let cred2 = AccountCredential(id: "agy-2", providerId: "antigravity", accountLabel: "dormant2@example.invalid", authMethod: .authFile, credential: c2Path.path)
            try store.saveCredential(cred0)
            try store.saveCredential(cred1)
            try store.saveCredential(cred2)

            // Guard checks: legacy/missing scope -> confirmation required; >=5 scopes does not depend on excluded [C2] auth_source
            try check(AntigravityCredentialCheckGuard.assess(credential: cred0).requiresConfirmation == true, "[A1] legacy AGY cred without scope requires confirmation")
            try check(AntigravityCredentialCheckGuard.assess(credential: cred2).requiresConfirmation == false, "[A1] verified AGY cred with >=5 scopes does not require confirmation without [C2] auth_source")
            let reducedPath = home.appendingPathComponent("creds/reduced.json")
            try writeAGYAuth(to: reducedPath, email: "reduced@example.invalid", accessToken: "x", refreshToken: "r", extraFields: ["scope": "openid email"])
            let credReduced = AccountCredential(id: "agy-red", providerId: "antigravity", accountLabel: "reduced@example.invalid", authMethod: .authFile, credential: reducedPath.path)
            try check(AntigravityCredentialCheckGuard.assess(credential: credReduced).requiresConfirmation == true, "[A1] <5 scopes requires confirmation")
            let taggedLegacyPath = home.appendingPathComponent("creds/tagged-legacy.json")
            try writeAGYAuth(to: taggedLegacyPath, email: "legacy@example.invalid", accessToken: "x", refreshToken: "r", extraFields: [
                "auth_source": "legacy",
                "scope": "openid https://www.googleapis.com/auth/cloud-platform https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/cclog"
            ])
            let credTaggedLegacy = AccountCredential(id: "agy-leg", providerId: "antigravity", accountLabel: "legacy@example.invalid", authMethod: .authFile, credential: taggedLegacyPath.path)
            try check(AntigravityCredentialCheckGuard.assess(credential: credTaggedLegacy).requiresConfirmation == true, "[A1] explicit legacy auth_source tag requires confirmation")

            let baseClock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
            let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
            let providerAbsent = AntigravityProvider(homeDirectory: home.path, localQuotaReader: absentReader)
            let engine = ProviderEngine(credentialStore: store, providersOverride: [providerAbsent], homeDirectory: home.path, now: { baseClock.now() })

            StubURLProtocol.install(hosts: ["googleapis.com"])
            StubURLProtocol.respond(agyLoadURL, body: agyLoadOK)
            StubURLProtocol.respond(agyQuotaURL, body: agyQuotaOK)
            StubURLProtocol.respond(agyRefreshURL, body: #"{"access_token":"new","expires_in":3600}"#)

            try check(AntigravityPoolProtectionSettings.pollingMode(homeDirectory: home.path) == .localOnly, "[A1] default AGY polling mode is .localOnly")

            // [§10.1 + §28] Legacy and v2 random_trickle configs + setPollingMode(.randomTrickle) must all fail closed to .localOnly
            let protectionRuntimeDir = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI", isDirectory: true)
            try FileManager.default.createDirectory(at: protectionRuntimeDir, withIntermediateDirectories: true)
            try Data(#"{"enabled":true,"pools":["gemini"],"polling_mode":"random_trickle"}"#.utf8)
                .write(to: protectionRuntimeDir.appendingPathComponent("pool-protection.json"), options: .atomic)
            try check(AntigravityPoolProtectionSettings.pollingMode(homeDirectory: home.path) == .localOnly,
                      "[§10.1] legacy pool-protection.json with random_trickle fails closed to .localOnly")
            try Data(#"{"enabled":true,"pools":["gemini"],"polling_mode":"random_trickle","polling_mode_version":2}"#.utf8)
                .write(to: protectionRuntimeDir.appendingPathComponent("pool-protection.json"), options: .atomic)
            try check(AntigravityPoolProtectionSettings.pollingMode(homeDirectory: home.path) == .localOnly,
                      "[§28] persisted v2 random_trickle config fails closed to .localOnly")
            try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: home.path)
            let savedPoolData = try Data(contentsOf: protectionRuntimeDir.appendingPathComponent("pool-protection.json"))
            let savedPoolJSON = try JSONSerialization.jsonObject(with: savedPoolData) as? [String: Any]
            try check(AntigravityPoolProtectionSettings.pollingMode(homeDirectory: home.path) == .localOnly
                        && savedPoolJSON?["polling_mode"] == nil
                        && savedPoolJSON?["polling_mode_version"] == nil,
                      "[§28] setPollingMode(.randomTrickle) strips remote trickle keys and returns .localOnly")
            let serverToken = "test-quota-token"
            let authHeaders = ["x-aiusage-startup-token": serverToken]
            let server = QuotaHTTPServer(host: "127.0.0.1", port: 0, startupToken: serverToken, engine: engine)
            let unauthHealth = await server.routeRequest(.init(method: "GET", path: "/health", headers: [:], body: Data()))
            let unauthHealthJSON = try JSONSerialization.jsonObject(with: unauthHealth.body) as? [String: Any]
            try check(unauthHealth.status == 200 && unauthHealthJSON?["instanceToken"] == nil && unauthHealthJSON?["instanceProof"] == nil && unauthHealth.headers["Access-Control-Allow-Origin"] == nil, "[M3] public GET /health omits instanceToken, instanceProof, and wildcard CORS")
            let sentRawHealth = await server.routeRequest(.init(method: "GET", path: "/health", headers: authHeaders, body: Data()))
            let sentRawHealthJSON = try JSONSerialization.jsonObject(with: sentRawHealth.body) as? [String: Any]
            try check(sentRawHealthJSON?["instanceToken"] == nil, "[§6.5] /health never echoes startupToken even if X-AIUsage-Startup-Token is sent")
            let healthNonce = "nonce-65-check"
            let challengeHealth = await server.routeRequest(.init(
                method: "GET",
                path: "/health",
                headers: [QuotaServerHealthProof.challengeHeader.lowercased(): healthNonce],
                body: Data()
            ))
            let challengeHealthJSON = try JSONSerialization.jsonObject(with: challengeHealth.body) as? [String: Any]
            try check(challengeHealthJSON?["instanceToken"] == nil
                        && challengeHealthJSON?["instanceProof"] as? String == QuotaServerHealthProof.compute(challenge: healthNonce, startupToken: serverToken),
                      "[§6.5] challenged GET /health returns keyed HMAC instanceProof without revealing startupToken")
            // [§6.5] Wrong listener on occupied port cannot forge instanceProof and never sees startupToken
            let occupiedServer = QuotaHTTPServer(host: "127.0.0.1", port: 0, startupToken: "wrong-listener-token", engine: engine)
            let expectedProof = QuotaServerHealthProof.compute(challenge: healthNonce, startupToken: serverToken) ?? ""
            let wrongResp = await occupiedServer.routeRequest(.init(
                method: "GET",
                path: "/health",
                headers: [QuotaServerHealthProof.challengeHeader.lowercased(): healthNonce],
                body: Data()
            ))
            let wrongJSON = try JSONSerialization.jsonObject(with: wrongResp.body) as? [String: Any]
            let wrongProof = (wrongJSON?["instanceProof"] as? String) ?? ""
            try check(wrongJSON?["instanceToken"] == nil && !QuotaShareServer.constantTimeEquals(Array(wrongProof.utf8), Array(expectedProof.utf8)),
                      "[§6.5] wrong listener fails challenge-response HMAC verification")

            let unauthDash = await server.routeRequest(.init(method: "GET", path: "/api/dashboard?ids=antigravity", headers: [:], body: Data()))
            try check(unauthDash.status == 401 && unauthDash.headers["Access-Control-Allow-Origin"] == nil, "[M3] unauthenticated GET /api/dashboard returns 401 without CORS *")
            let unauthProviders = await server.routeRequest(.init(method: "GET", path: "/api/providers", headers: [:], body: Data()))
            try check(unauthProviders.status == 401, "[M3] unauthenticated GET /api/providers returns 401")
            let coldDash = await server.routeRequest(.init(method: "GET", path: "/api/dashboard?ids=antigravity", headers: authHeaders, body: Data()))
            let coldManualDash = await server.routeRequest(.init(method: "GET", path: "/api/dashboard?ids=antigravity&manual=1", headers: authHeaders, body: Data()))
            let coldSnap = try JSONDecoder().decode(DashboardSnapshot.self, from: coldDash.body)
            let coldManualSnap = try JSONDecoder().decode(DashboardSnapshot.self, from: coldManualDash.body)
            try check(coldSnap.providers.first?.summary?.errorCode == "unavailable", "[A2] GET /api/dashboard cold AGY returns terminal unavailable")
            try check(coldManualSnap.providers.first?.summary?.errorCode == "unavailable", "[A2] GET /api/dashboard?manual=1 cold AGY returns terminal unavailable")

            _ = await engine.fetchAll(ids: ["antigravity"], backgroundAutomatic: true)
            _ = await engine.fetchAll(ids: ["antigravity"], backgroundAutomatic: false)
            _ = await engine.fetchMultiAccountProvider(id: "antigravity")
            try check(StubURLProtocol.requests.isEmpty, "[A1] 0 Google HTTPS calls when IDE loopback is absent in .localOnly across auto, manual Refresh All, Refresh Provider, and HTTP API")

            // Loopback active matching active@example.invalid -> reads local IDE via loopback only, still 0 Google HTTPS
            let localReader = AntigravityLocalQuotaReader(
                listProcesses: { [.init(pid: 999, csrfToken: "csrf-secret")] },
                listPorts: { _ in [12345] },
                callRPC: { _, endpoint, _, _ in
                    if endpoint.contains("GetUserStatus") {
                        return [
                            "userStatus": [
                                "email": "active@example.invalid",
                                "userTier": ["id": "pro", "name": "Pro"]
                            ]
                        ]
                    }
                    if endpoint.contains("RetrieveUserQuotaSummary") {
                        return [
                            "groups": [[
                                "displayName": "Gemini 2.5 Pro",
                                "buckets": [[
                                    "bucketId": "gemini-2.5-pro",
                                    "remainingFraction": 0.9,
                                    "resetTime": "2099-01-01T00:00:00Z"
                                ]]
                            ]]
                        ]
                    }
                    return nil
                }
            )
            let providerLoopback = AntigravityProvider(homeDirectory: home.path, localQuotaReader: localReader)
            let engineLoop = ProviderEngine(credentialStore: store, providersOverride: [providerLoopback], homeDirectory: home.path, now: { baseClock.now() })
            let loopDash = await engineLoop.fetchAll(ids: ["antigravity"], backgroundAutomatic: true)
            let loopResults = loopDash.providers
            try check(StubURLProtocol.requests.isEmpty, "[A1] active IDE loopback read emits 0 Google HTTPS calls")
            let loopSummary = loopResults.map { "\($0.id):ok=\($0.ok):code=\($0.summary?.errorCode ?? $0.error ?? "")" }.joined(separator: ", ")
            try check(loopResults.contains(where: { $0.id == "antigravity:cred:agy-0" && $0.ok }), "[A1] active IDE loopback populates active account locally (got: [\(loopSummary)])")

            // Policy compliance: per-card click uses local IDE RPC only (0 Google HTTPS calls for dormant accounts)
            let explicitDormant = await engineLoop.fetchForCredential(providerId: "antigravity", credentialId: "agy-1")
            let explicitActive = await engineLoop.fetchForCredential(providerId: "antigravity", credentialId: "agy-0")
            try check((explicitDormant == nil || explicitDormant?.ok == false)
                        && explicitActive?.ok == true
                        && StubURLProtocol.requests.isEmpty,
                      "[A1 + §28] single-card fetchForCredential uses local IDE RPC only with 0 Google HTTPS calls")

            // [personal-build + §55-P2] Real user home enables .live 127.0.0.1 IDE loopback (0 Google HTTPS),
            // while isolated test homes and explicit localQuotaReader: nil fail closed with local_only_unavailable.
            let realHomeProdProvider = AntigravityProvider(homeDirectory: NSHomeDirectory())
            let isolatedProdProvider = AntigravityProvider(homeDirectory: scratchRoot.path)
            let explicitNilProdProvider = AntigravityProvider(homeDirectory: NSHomeDirectory(), localQuotaReader: nil)
            try check(realHomeProdProvider.effectiveLocalQuotaReader != nil
                        && isolatedProdProvider.effectiveLocalQuotaReader == nil
                        && explicitNilProdProvider.effectiveLocalQuotaReader == nil,
                      "[personal-build] AntigravityProvider enables .live IDE RPC on NSHomeDirectory() while isolating non-user/explicit-nil homes")
            for disabledProvider in [isolatedProdProvider, explicitNilProdProvider] {
                for modeLocalOnly in [true, false] {
                    var prodCode: String?
                    do {
                        _ = try await disabledProvider.fetchUsage(with: cred0, localOnly: modeLocalOnly)
                    } catch let err as ProviderError {
                        prodCode = err.code
                    }
                    try check(prodCode == "local_only_unavailable",
                              "[personal-build] isolated/explicit-nil AntigravityProvider fails closed locally (localOnly=\(modeLocalOnly))")
                }
            }

            // [§55-P2] Multi-project credentials sharing an active email require verified project match and preserve existing snapshots when unbound.
            let multiHome = scratchRoot.appendingPathComponent("agy-multi-project-55p2", isDirectory: true)
            let multiAuthA = multiHome.appendingPathComponent("creds/agy-proj-a.json")
            let multiAuthB = multiHome.appendingPathComponent("creds/agy-proj-b.json")
            try writeAGYAuth(to: multiAuthA, email: "active@example.invalid", accessToken: "tok-a", refreshToken: "ref-a", projectId: "proj-0")
            try writeAGYAuth(to: multiAuthB, email: "active@example.invalid", accessToken: "tok-b", refreshToken: "ref-b", projectId: "proj-sibling")
            let multiCredA = AccountCredential(id: "agy-multi-a", providerId: "antigravity", accountLabel: "active@example.invalid", authMethod: .authFile, credential: multiAuthA.path, metadata: ["projectId": "proj-0"])
            let multiCredB = AccountCredential(id: "agy-multi-b", providerId: "antigravity", accountLabel: "active@example.invalid", authMethod: .authFile, credential: multiAuthB.path, metadata: ["projectId": "proj-sibling"])
            let multiCredStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            try multiCredStore.saveCredential(multiCredA)
            try multiCredStore.saveCredential(multiCredB)
            let multiBaseProvider = AntigravityProvider(homeDirectory: multiHome.path)
            for (cred, proj, pct, ts) in [
                (multiCredA, "proj-0", 80.0, "2026-11-19T10:00:00Z"),
                (multiCredB, "proj-sibling", 35.0, "2026-11-19T10:05:00Z")
            ] {
                var u = ProviderUsage(
                    provider: "antigravity",
                    label: "Antigravity",
                    accountId: "active@example.invalid",
                    extra: [
                        "projectId": AnyCodable(proj),
                        "trackedModels": AnyCodable([AnyCodable(["label": AnyCodable("Gemini"), "remainingPercent": AnyCodable(pct)])])
                    ]
                )
                u.fetchedAt = ts
                u.accountEmail = "active@example.invalid"
                var s = UsageNormalizer.normalize(provider: multiBaseProvider, usage: u)
                s.id = "antigravity:cred:\(cred.id)"
                s.providerId = "antigravity"
                s.accountId = "active@example.invalid"
                s.accountLabel = "active@example.invalid"
                s.fetchedAt = ts
                s.remainingPercent = pct
                let r = ProviderResult(id: "antigravity:cred:\(cred.id)", providerId: "antigravity", accountId: "active@example.invalid", ok: true, usage: u, summary: s)
                try check(QuotaSnapshotStore.store(homeDirectory: multiHome.path).save(result: r, credential: cred),
                          "[§55-P2] saved initial snapshot for \(proj)")
            }

            let unboundEngine55 = ProviderEngine(
                credentialStore: multiCredStore,
                providersOverride: [AntigravityProvider(homeDirectory: multiHome.path, localQuotaReader: localReader)],
                homeDirectory: multiHome.path,
                now: { baseClock.now() }
            )
            await unboundEngine55.hydratePersistedSnapshotsIfNeeded()
            let unboundResults55 = await unboundEngine55.fetchAll(ids: ["antigravity"], backgroundAutomatic: false).providers
            let unboundA = unboundResults55.first(where: { $0.id == "antigravity:cred:agy-multi-a" })
            let unboundB = unboundResults55.first(where: { $0.id == "antigravity:cred:agy-multi-b" })
            try check(unboundA?.summary?.remainingPercent == 80 && unboundA?.summary?.fetchedAt == "2026-11-19T10:00:00Z"
                        && unboundB?.summary?.remainingPercent == 35 && unboundB?.summary?.fetchedAt == "2026-11-19T10:05:00Z"
                        && StubURLProtocol.requests.isEmpty,
                      "[§55-P2] unbound email-only IDE sample preserves existing project snapshots when multiple projects share email")

            let siblingScopedReader = AntigravityLocalQuotaReader(
                listProcesses: { [.init(pid: 999, csrfToken: "csrf-secret")] },
                listPorts: { _ in [12345] },
                callRPC: { _, endpoint, _, _ in
                    if endpoint.contains("GetUserStatus") {
                        return [
                            "userStatus": [
                                "email": "active@example.invalid",
                                "projectId": "proj-sibling",
                                "userTier": ["id": "pro", "name": "Pro"]
                            ]
                        ]
                    }
                    if endpoint.contains("RetrieveUserQuotaSummary") {
                        return [
                            "groups": [[
                                "displayName": "Gemini 2.5 Pro",
                                "buckets": [[
                                    "bucketId": "gemini-2.5-pro",
                                    "remainingFraction": 0.9,
                                    "resetTime": "2099-01-01T00:00:00Z"
                                ]]
                            ]]
                        ]
                    }
                    return nil
                }
            )
            let scopedEngine55 = ProviderEngine(
                credentialStore: multiCredStore,
                providersOverride: [AntigravityProvider(homeDirectory: multiHome.path, localQuotaReader: siblingScopedReader)],
                homeDirectory: multiHome.path,
                now: { baseClock.now() }
            )
            await scopedEngine55.hydratePersistedSnapshotsIfNeeded()
            let scopedResults55 = await scopedEngine55.fetchAll(ids: ["antigravity"], backgroundAutomatic: false).providers
            let scopedA = scopedResults55.first(where: { $0.id == "antigravity:cred:agy-multi-a" })
            let scopedB = scopedResults55.first(where: { $0.id == "antigravity:cred:agy-multi-b" })
            try check(scopedA?.summary?.remainingPercent == 80 && scopedA?.summary?.fetchedAt == "2026-11-19T10:00:00Z"
                        && scopedB?.summary?.remainingPercent == 90
                        && StubURLProtocol.requests.isEmpty,
                      "[§55-P2] project-verified IDE sample updates only the matching project while preserving peer project snapshot")

            // [§32.4] Reload Saved Snapshot re-reads replaced on-disk snapshot after warm hydration with 0 HTTP calls
            let snapHome = scratchRoot.appendingPathComponent("agy-snapshot-reload-324", isDirectory: true)
            let snapProdProvider = AntigravityProvider(homeDirectory: snapHome.path)
            try FileManager.default.createDirectory(at: snapHome, withIntermediateDirectories: true)
            let snapAuthPath = snapHome.appendingPathComponent("creds/agy0.json")
            try writeAGYAuth(to: snapAuthPath, email: "active@example.invalid", accessToken: "secret-agy-tok-0", refreshToken: "secret-agy-ref-0", projectId: "proj-0")
            let reloadCred = AccountCredential(id: "agy-reload-0", providerId: "antigravity", accountLabel: "active@example.invalid", authMethod: .authFile, credential: snapAuthPath.path)
            let reloadCredStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            try reloadCredStore.saveCredential(reloadCred)

            func saveAGYDiskSnapshot(fraction: Double, fetchedAt: String) throws {
                var usage = ProviderUsage(
                    provider: "antigravity",
                    label: "Antigravity",
                    accountId: "active@example.invalid",
                    extra: [
                        "projectId": AnyCodable("proj-0"),
                        "trackedModels": AnyCodable([
                            AnyCodable([
                                "label": AnyCodable("Gemini"),
                                "remainingPercent": AnyCodable(fraction * 100)
                            ])
                        ])
                    ]
                )
                usage.fetchedAt = fetchedAt
                usage.accountEmail = "active@example.invalid"
                var summary = UsageNormalizer.normalize(provider: snapProdProvider, usage: usage)
                summary.id = "antigravity:cred:agy-reload-0"
                summary.providerId = "antigravity"
                summary.accountId = "active@example.invalid"
                summary.accountLabel = "active@example.invalid"
                summary.fetchedAt = fetchedAt
                summary.remainingPercent = fraction * 100
                let result = ProviderResult(
                    id: "antigravity:cred:agy-reload-0",
                    providerId: "antigravity",
                    accountId: "active@example.invalid",
                    ok: true,
                    usage: usage,
                    summary: summary
                )
                try check(QuotaSnapshotStore.store(homeDirectory: snapHome.path).save(result: result, credential: reloadCred),
                          "[§32.4] saved snapshot to disk")
            }

            try saveAGYDiskSnapshot(fraction: 0.80, fetchedAt: "2026-11-19T10:00:00Z")
            let snapshotFileURL = QuotaSnapshotStore.store(homeDirectory: snapHome.path).fileURL
            let olderBackupBytes = try Data(contentsOf: snapshotFileURL)
            let reloadEngine = ProviderEngine(credentialStore: reloadCredStore, providersOverride: [snapProdProvider], homeDirectory: snapHome.path, now: { baseClock.now() })
            await reloadEngine.hydratePersistedSnapshotsIfNeeded()
            let initialReload = await reloadEngine.fetchForCredential(providerId: "antigravity", credentialId: "agy-reload-0")
            try check(initialReload?.summary?.fetchedAt == "2026-11-19T10:00:00Z"
                        && initialReload?.summary?.remainingPercent == 80,
                      "[§32.4] warm startup hydrates initial Antigravity disk snapshot")

            try saveAGYDiskSnapshot(fraction: 0.45, fetchedAt: "2026-11-19T12:34:56Z")
            let refreshedCard = await reloadEngine.fetchForCredential(providerId: "antigravity", credentialId: "agy-reload-0")
            let refreshedProvider = await reloadEngine.fetchAll(ids: ["antigravity"], backgroundAutomatic: false)
                .providers.first(where: { $0.id == "antigravity:cred:agy-reload-0" })
            try check(refreshedCard?.summary?.remainingPercent == 45
                        && refreshedCard?.summary?.fetchedAt == "2026-11-19T12:34:56Z"
                        && refreshedProvider?.summary?.remainingPercent == 45
                        && refreshedProvider?.summary?.fetchedAt == "2026-11-19T12:34:56Z"
                        && StubURLProtocol.requests.isEmpty,
                      "[§32.4] Reload Saved Snapshot re-reads replaced on-disk snapshot, keeps fetchedAt, and makes 0 HTTP calls")

            // [§35.4] Restoring an older disk snapshot backup must NOT regress a newer warm in-memory result
            try olderBackupBytes.write(to: snapshotFileURL, options: .atomic)
            let afterStaleBackupCard = await reloadEngine.fetchForCredential(providerId: "antigravity", credentialId: "agy-reload-0")
            let afterStaleBackupAll = await reloadEngine.fetchAll(ids: ["antigravity"], backgroundAutomatic: false)
                .providers.first(where: { $0.id == "antigravity:cred:agy-reload-0" })
            let afterStaleBackupCached = await reloadEngine.cachedDashboard(ids: ["antigravity"])
                .providers.first(where: { $0.id == "antigravity:cred:agy-reload-0" })
            try check(afterStaleBackupCard?.summary?.remainingPercent == 45
                        && afterStaleBackupCard?.summary?.fetchedAt == "2026-11-19T12:34:56Z"
                        && afterStaleBackupAll?.summary?.remainingPercent == 45
                        && afterStaleBackupAll?.summary?.fetchedAt == "2026-11-19T12:34:56Z"
                        && afterStaleBackupCached?.summary?.remainingPercent == 45
                        && afterStaleBackupCached?.summary?.fetchedAt == "2026-11-19T12:34:56Z"
                        && StubURLProtocol.requests.isEmpty,
                      "[§35.4] Reload rejects older disk backup over newer warm in-memory snapshot across card/fetchAll/cachedResults with 0 HTTP calls")

            // [§30.1] AntigravityLocalQuotaReader rejects HTTP redirects and mismatched quota summary identities
            final class LoopbackStubHTTPServer: @unchecked Sendable {
                private let listener: NWListener
                private let queue = DispatchQueue(label: "test.agy.loopback.\(UUID().uuidString)")
                private let lock = NSLock()
                private var hitPaths: [String] = []
                private(set) var port: Int = 0

                init(responder: @escaping @Sendable (_ path: String, _ headers: [String: String]) -> (status: Int, extraHeaders: [String], body: String)) throws {
                    let params = NWParameters.tcp
                    params.allowLocalEndpointReuse = true
                    self.listener = try NWListener(using: params, on: .any)
                    let readySem = DispatchSemaphore(value: 0)
                    listener.stateUpdateHandler = { [weak self] state in
                        if case .ready = state, let self, let p = self.listener.port?.rawValue {
                            self.port = Int(p)
                            readySem.signal()
                        }
                    }
                    listener.newConnectionHandler = { [weak self] conn in
                        guard let self else { return }
                        conn.start(queue: self.queue)
                        self.handle(conn: conn, responder: responder)
                    }
                    listener.start(queue: queue)
                    _ = readySem.wait(timeout: .now() + 3)
                }

                var paths: [String] { lock.withLock { hitPaths } }

                func stop() { listener.cancel() }

                private func handle(
                    conn: NWConnection,
                    responder: @escaping @Sendable (_ path: String, _ headers: [String: String]) -> (status: Int, extraHeaders: [String], body: String)
                ) {
                    var accumulated = Data()
                    func readMore() {
                        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, isComplete, _ in
                            if let data { accumulated.append(data) }
                            if let sepRange = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                                let headText = String(decoding: accumulated[..<sepRange.lowerBound], as: UTF8.self)
                                let lines = headText.components(separatedBy: "\r\n")
                                let firstParts = (lines.first ?? "").split(separator: " ")
                                let path = firstParts.count >= 2 ? String(firstParts[1]) : "/"
                                var headers: [String: String] = [:]
                                for line in lines.dropFirst() {
                                    if let colon = line.firstIndex(of: ":") {
                                        let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                                        let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                                        headers[key] = val
                                    }
                                }
                                let contentLength = Int(headers["content-length"] ?? "0") ?? 0
                                let bodyStart = sepRange.upperBound
                                if accumulated.count - bodyStart < contentLength && !isComplete {
                                    readMore()
                                    return
                                }
                                self.lock.withLock { self.hitPaths.append(path) }
                                let reply = responder(path, headers)
                                var head = "HTTP/1.1 \(reply.status) OK\r\nContent-Type: application/json\r\nContent-Length: \(reply.body.utf8.count)\r\nConnection: close\r\n"
                                for h in reply.extraHeaders { head += "\(h)\r\n" }
                                head += "\r\n\(reply.body)"
                                conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in
                                    conn.cancel()
                                })
                            } else if !isComplete {
                                readMore()
                            } else {
                                conn.cancel()
                            }
                        }
                    }
                    readMore()
                }
            }

            let redirectTargetServer = try LoopbackStubHTTPServer { path, _ in
                return (200, [], #"{"groups":[{"displayName":"Account B quota","buckets":[{"bucketId":"b-only","window":"weekly","remainingFraction":0.31,"resetTime":"2027-01-01T00:00:00Z"}]}]}"#)
            }
            defer { redirectTargetServer.stop() }
            let targetPort = redirectTargetServer.port
            let originRedirectServer = try LoopbackStubHTTPServer { path, _ in
                if path.hasSuffix("GetUserStatus") {
                    return (200, [], #"{"userStatus":{"email":"active@example.invalid","userTier":{"id":"pro","name":"Pro"}}}"#)
                }
                if path.hasSuffix("RetrieveUserQuotaSummary") {
                    return (307, ["Location: http://127.0.0.1:\(targetPort)/summary"], "")
                }
                return (404, [], "{}")
            }
            defer { originRedirectServer.stop() }

            let realTransportRedirectReader = AntigravityLocalQuotaReader(
                listProcesses: { [.init(pid: 7001, csrfToken: "fixture-token")] },
                listPorts: { _ in [originRedirectServer.port] }
            )
            let redirectProvider = AntigravityProvider(homeDirectory: home.path, localQuotaReader: realTransportRedirectReader)
            var redirectErrorCode: String?
            do {
                _ = try await redirectProvider.fetchUsage(with: cred0, localOnly: true)
            } catch let err as ProviderError {
                redirectErrorCode = err.code
            }
            try check(redirectErrorCode == "local_only_unavailable" && redirectTargetServer.paths.isEmpty,
                      "[§30.1] injected AntigravityLocalQuotaReader rejects HTTP 307 redirect without contacting redirect target")

            let mismatchedIdentityReader = AntigravityLocalQuotaReader(
                listProcesses: { [.init(pid: 7002, csrfToken: "fixture-token")] },
                listPorts: { _ in [12349] },
                callRPC: { _, method, _, _ in
                    if method.hasSuffix("GetUserStatus") {
                        return ["userStatus": ["email": "active@example.invalid"]]
                    }
                    return [
                        "email": "other-b@example.invalid",
                        "groups": [[
                            "displayName": "Account B",
                            "buckets": [[
                                "bucketId": "b-only",
                                "window": "weekly",
                                "remainingFraction": 0.31,
                                "resetTime": "2027-01-01T00:00:00Z"
                            ]]
                        ]]
                    ]
                }
            )
            let mismatchResult = await mismatchedIdentityReader.fetchMatchingQuota(expectedEmail: "active@example.invalid")
            try check(mismatchResult == nil && StubURLProtocol.requests.isEmpty,
                      "[§30.1] AntigravityLocalQuotaReader rejects mismatched embedded quota summary identity")
        }

        // 2. [A2] Codex .activeOnly across triggers + 401 bounded retry + env trap + invalid auth + mid-flight switch + HTTP API
        do {
            let home = scratchRoot.appendingPathComponent("codex-active-only", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let store = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })

            let nativePath = CodexQuotaPollingPolicy.nativeAuthFileURL(homeDirectory: home.path)
            let credActivePath = home.appendingPathComponent("vault/codex-active.json")
            let credDormant1Path = home.appendingPathComponent("vault/codex-dormant1.json")
            let credDormant2Path = home.appendingPathComponent("vault/codex-dormant2.json")
            let envTrapDir = home.appendingPathComponent("env-trap-dir", isDirectory: true)
            let envTrapFile = envTrapDir.appendingPathComponent("dormant-newer.json")

            try writeCodexAuth(to: nativePath, accountId: "acct-1", userId: "user-1", email: "active@example.invalid", accessToken: "secret-codex-active-tok", refreshToken: "secret-codex-active-ref")
            try writeCodexAuth(to: credActivePath, accountId: "acct-1", userId: "user-1", email: "active@example.invalid", accessToken: "secret-codex-active-tok", refreshToken: "secret-codex-active-ref")
            try writeCodexAuth(to: credDormant1Path, accountId: "acct-2", userId: "user-2", email: "dormant1@example.invalid", accessToken: "secret-codex-dormant1-tok", refreshToken: "secret-codex-dormant1-ref")
            try writeCodexAuth(to: credDormant2Path, accountId: "acct-3", userId: "user-3", email: "dormant2@example.invalid", accessToken: "secret-codex-dormant2-tok", refreshToken: "secret-codex-dormant2-ref")
            try writeCodexAuth(to: envTrapFile, accountId: "acct-2", userId: "user-2", email: "dormant1@example.invalid", accessToken: "secret-codex-env-tok", refreshToken: "secret-codex-env-ref")

            try store.saveCredential(AccountCredential(id: "codex-a", providerId: "codex", accountLabel: "active@example.invalid", authMethod: .authFile, credential: credActivePath.path, metadata: ["accountId": "acct-1", "workspaceUserId": "user-1"]))
            try store.saveCredential(AccountCredential(id: "codex-d1", providerId: "codex", accountLabel: "dormant1@example.invalid", authMethod: .authFile, credential: credDormant1Path.path, metadata: ["accountId": "acct-2", "workspaceUserId": "user-2"]))
            try store.saveCredential(AccountCredential(id: "codex-d2", providerId: "codex", accountLabel: "dormant2@example.invalid", authMethod: .authFile, credential: credDormant2Path.path, metadata: ["accountId": "acct-3", "workspaceUserId": "user-3"]))

            // Inject CODEX_AUTH_FILE and CODEX_AUTH_DIR pointing to dormant acct-2 (newer mtime) -> must be IGNORED!
            setenv("CODEX_AUTH_FILE", envTrapFile.path, 1)
            setenv("CODEX_AUTH_DIR", envTrapDir.path, 1)
            defer {
                unsetenv("CODEX_AUTH_FILE")
                unsetenv("CODEX_AUTH_DIR")
            }

            try check(CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: home.path)?.nativeKey == "codex:account:acct-1:user:user-1", "[A2] policy reads ~/.codex/auth.json despite CODEX_AUTH_FILE/DIR env vars")
            try check(!CodexQuotaPollingPolicy.authFileMatchesActiveIdentity(atPath: credDormant1Path.path, homeDirectory: home.path), "[A2] dormant auth file rejected by active-identity filter")

            let clock = MutableClock(Date(timeIntervalSince1970: 1_800_000_000))
            let codexProvider = CodexProvider(homeDirectory: home.path)
            let codexToken = "test-codex-token"
            let codexHeaders = ["x-aiusage-startup-token": codexToken]
            let engine = ProviderEngine(credentialStore: store, providersOverride: [codexProvider], homeDirectory: home.path, now: { clock.now() })
            let server = QuotaHTTPServer(host: "127.0.0.1", port: 0, startupToken: codexToken, engine: engine)

            StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
            StubURLProtocol.respond(codexUsageURL) { req in
                let bearer = req.headers["Authorization"] ?? ""
                if bearer.contains("dormant") || bearer.contains("env-tok") {
                    fatalError("Dormant Codex credential must NEVER be polled passively!")
                }
                return (200, codexUsageOK)
            }

            // Unauthorized /api/provider/codex -> 401; Authorized Cold HTTP /api/provider/codex -> terminal unavailable, 0 HTTP
            let unauthSingle = await server.routeRequest(.init(method: "GET", path: "/api/provider/codex", headers: [:], body: Data()))
            try check(unauthSingle.status == 401 && StubURLProtocol.requests.isEmpty, "[M3] unauthorized GET /api/provider/codex returns 401 with 0 OpenAI calls")
            let coldSingle = await server.routeRequest(.init(method: "GET", path: "/api/provider/codex", headers: codexHeaders, body: Data()))
            let coldSingleRes = try JSONDecoder().decode(ProviderResult.self, from: coldSingle.body)
            try check(coldSingleRes.ok == false && coldSingleRes.summary?.errorCode == "unavailable" && StubURLProtocol.requests.isEmpty, "[A2] cold GET /api/provider/codex returns unavailable with 0 OpenAI calls")

            // Passive fetchAll(backgroundAutomatic: true) -> exactly 1 OpenAI GET for active acct-1
            let autoDash = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try check(StubURLProtocol.requests.count == 1 && autoDash.providers.filter(\.ok).count == 1, "[A2] automatic poll sends exactly 1 OpenAI request for active acct-1 only")

            // Warm GET /api/provider/codex -> 0 HTTP, returns cached active acct-1
            let warmSingle = await server.routeRequest(.init(method: "GET", path: "/api/provider/codex", headers: codexHeaders, body: Data()))
            let warmSingleRes = try JSONDecoder().decode(ProviderResult.self, from: warmSingle.body)
            try check(warmSingleRes.ok == true && warmSingleRes.resultAccountId == "acct-1" && StubURLProtocol.requests.count == 1, "[A2] warm GET /api/provider/codex serves active acct-1 with 0 OpenAI calls")

            // Manual fetchMultiAccountProvider(codex) past 90s guard -> still 1 active OpenAI call, 0 dormant
            clock.advance(by: 120)
            _ = await engine.fetchMultiAccountProvider(id: "codex")
            try check(StubURLProtocol.requests.count == 2, "[A2] manual Refresh Codex provider polls only active acct-1 (2nd request total)")

            // Active 401 + bounded refresh recovery -> 3 requests for this cycle (usage 401 -> refresh -> usage 200), still 0 dormant
            clock.advance(by: 120)
            var usageAttempt = 0
            StubURLProtocol.respond(codexUsageURL) { _ in
                usageAttempt += 1
                if usageAttempt == 1 { return (401, #"{"error":"expired"}"#) }
                return (200, codexUsageOK)
            }
            StubURLProtocol.respond(codexRefreshURL, body: #"{"access_token":"secret-codex-refreshed-tok","refresh_token":"secret-codex-refreshed-ref","expires_in":3600}"#)
            let recovered = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try check(recovered.providers.first?.ok == true, "[A2] active 401 recovers cleanly")
            try check(StubURLProtocol.requests.count == 5, "[A2] 401 recovery runs bounded 3 requests (+1 refresh +2 usage), 0 dormant")

            // Invalid / API-key / missing / conflicting ~/.codex/auth.json -> 0 OpenAI calls
            let savedBeforeInvalid = StubURLProtocol.requests.count
            clock.advance(by: 120)
            try Data(#"{"OPENAI_API_KEY":"sk-test-key"}"#.utf8).write(to: nativePath, options: .atomic)
            try check(CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: home.path) == nil, "[A2] API-key-only auth.json yields nil")
            _ = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try Data(#"{"tokens":{"access_token":"a","id_token":"e30.e30.s"},"access_token":"b"}"#.utf8).write(to: nativePath, options: .atomic)
            _ = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try FileManager.default.removeItem(at: nativePath)
            _ = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try check(StubURLProtocol.requests.count == savedBeforeInvalid, "[A2] missing/API-key/conflicting native auth sends 0 OpenAI requests")

            // Mid-flight account switch during Codex poll -> stale response dropped cleanly, wrong identity never corrupted
            try writeCodexAuth(to: nativePath, accountId: "acct-1", userId: "user-1", email: "active@example.invalid", accessToken: "secret-codex-active-tok", refreshToken: "secret-codex-active-ref")
            clock.advance(by: 120)
            StubURLProtocol.respond(codexUsageURL) { _ in
                // Mutate ~/.codex/auth.json to acct-2 while acct-1 fetch is in flight!
                try? writeCodexAuth(to: nativePath, accountId: "acct-2", userId: "user-2", email: "dormant1@example.invalid", accessToken: "secret-codex-dormant1-tok", refreshToken: "secret-codex-dormant1-ref")
                return (200, codexUsageOK)
            }
            let preSwitchSnapshot = QuotaSnapshotStore.store(homeDirectory: home.path).loadDocument()
            let preSwitchFetchedAt = preSwitchSnapshot.snapshots[QuotaSnapshotIdentity.codexNative(accountId: "acct-1", userId: "user-1").storageKey]?.fetchedAt
            let switchedDash = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            let postSwitchSnapshot = QuotaSnapshotStore.store(homeDirectory: home.path).loadDocument()
            try check(switchedDash.providers.first?.summary?.errorCode != "codex_active_switched", "[A2] switched mid-flight falls back cleanly without fake error card")
            try check(postSwitchSnapshot.snapshots[QuotaSnapshotIdentity.codexNative(accountId: "acct-2", userId: "user-2").storageKey] == nil, "[A2] mid-flight switch does not corrupt acct-2 snapshot")
            try check(postSwitchSnapshot.snapshots[QuotaSnapshotIdentity.codexNative(accountId: "acct-1", userId: "user-1").storageKey]?.fetchedAt == preSwitchFetchedAt, "[A2] mid-flight stale acct-1 response is not persisted after switch")

            // Unvaulted active native account works with 1 GET
            let unvaultedHome = scratchRoot.appendingPathComponent("codex-unvaulted", isDirectory: true)
            let unvaultedNative = CodexQuotaPollingPolicy.nativeAuthFileURL(homeDirectory: unvaultedHome.path)
            try writeCodexAuth(to: unvaultedNative, accountId: "acct-raw", userId: "user-raw", email: "raw@example.invalid", accessToken: "secret-raw-tok", refreshToken: "secret-raw-ref")
            let rawClock = MutableClock(Date(timeIntervalSince1970: 1_800_100_000))
            let rawEngine = ProviderEngine(
                credentialStore: AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in }),
                providersOverride: [CodexProvider(homeDirectory: unvaultedHome.path)],
                homeDirectory: unvaultedHome.path,
                now: { rawClock.now() }
            )
            StubURLProtocol.respond(codexUsageURL, body: codexUsageOK)
            let reqBeforeRaw = StubURLProtocol.requests.count
            let rawRes = await rawEngine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try check(StubURLProtocol.requests.count == reqBeforeRaw + 1 && rawRes.providers.first?.ok == true, "[A2] unvaulted native ~/.codex/auth.json runs 1 GET and hydrates")
        }

        // 3. [B2] Snapshot Persistence, 0600 Security, Non-Secret Whitelist, Identity Isolation, Restart Hydration, Corruption/Symlink, Deletion & Terminal Override
        do {
            let home = scratchRoot.appendingPathComponent("snapshot-store-test", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let snapStore = QuotaSnapshotStore.store(homeDirectory: home.path)

            // Special characters & multi-workspace isolation
            let colonsKey1 = QuotaSnapshotIdentity.codexNative(accountId: "org:alpha", userId: "usr:1").storageKey
            let colonsKey2 = QuotaSnapshotIdentity.codexNative(accountId: "org", userId: "alpha:usr:1").storageKey
            let agyWork1 = QuotaSnapshotIdentity.antigravityEmail(email: "multi@example.invalid", projectId: "proj-alpha").storageKey
            let agyWork2 = QuotaSnapshotIdentity.antigravityEmail(email: "multi@example.invalid", projectId: "proj-beta").storageKey
            try check(colonsKey1 != colonsKey2, "[B2] deterministic base64url keys do not collide on embedded colons")
            try check(agyWork1 != agyWork2, "[B2] same email with different projectIds keep separate keys")

            var placeholderUsage = ProviderUsage(
                provider: "antigravity",
                label: "Antigravity",
                accountId: "multi@example.invalid",
                extra: ["projectId": AnyCodable("aicode-consumers")]
            )
            placeholderUsage.accountEmail = "multi@example.invalid"
            var placeholderSummary = UsageNormalizer.normalize(provider: AntigravityProvider(homeDirectory: home.path), usage: placeholderUsage)
            placeholderSummary.accountLabel = "multi@example.invalid"
            let placeholderResult = ProviderResult(
                id: "antigravity:cred:agy-ph",
                providerId: "antigravity",
                accountId: "multi@example.invalid",
                ok: true,
                usage: placeholderUsage,
                summary: placeholderSummary
            )
            let placeholderKey = QuotaSnapshotIdentity.antigravityEmail(email: "multi@example.invalid", projectId: nil).storageKey
            try check(QuotaSnapshotStore.identity(from: placeholderResult).storageKey == placeholderKey, "[B2] aicode-consumers placeholder project_id is stripped to email-only key")

            let store = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            let agyPathA = home.appendingPathComponent("c-agy-a.json")
            let agyPathB = home.appendingPathComponent("c-agy-b.json")
            let codexPathA = home.appendingPathComponent("c-codex-a.json")
            try writeAGYAuth(to: agyPathA, email: "multi@example.invalid", accessToken: "secret-agy-token-alpha", refreshToken: "secret-agy-refresh-alpha", projectId: "proj-alpha")
            try writeAGYAuth(to: agyPathB, email: "multi@example.invalid", accessToken: "secret-agy-token-beta", refreshToken: "secret-agy-refresh-beta", projectId: "proj-beta")
            try writeCodexAuth(to: codexPathA, accountId: "org:alpha", userId: "usr:1", email: "codex@example.invalid", accessToken: "secret-codex-tok-123", refreshToken: "secret-codex-ref-456")

            let agyCredA = AccountCredential(id: "agy-ws-a", providerId: "antigravity", accountLabel: "multi@example.invalid", authMethod: .authFile, credential: agyPathA.path)
            let agyCredB = AccountCredential(id: "agy-ws-b", providerId: "antigravity", accountLabel: "multi@example.invalid", authMethod: .authFile, credential: agyPathB.path)
            let codexCredA = AccountCredential(id: "codex-ws-a", providerId: "codex", accountLabel: "codex@example.invalid", authMethod: .authFile, credential: codexPathA.path, metadata: ["accountId": "org:alpha", "workspaceUserId": "usr:1"])
            try store.saveCredential(agyCredA)
            try store.saveCredential(agyCredB)
            try store.saveCredential(codexCredA)

            let t0 = Date(timeIntervalSince1970: 1_800_200_000)
            let clock = MutableClock(t0)
            final class LocalFractionBox: @unchecked Sendable {
                private let lock = NSLock()
                private var fraction = 0.85
                private var projectId = "proj-alpha"
                func set(_ next: Double, projectId: String) {
                    lock.withLock {
                        fraction = next
                        self.projectId = projectId
                    }
                }
                func get() -> (fraction: Double, projectId: String) {
                    lock.withLock { (fraction, projectId) }
                }
            }
            let localFraction = LocalFractionBox()
            let matchingLocalReader = AntigravityLocalQuotaReader(
                listProcesses: { [.init(pid: 998, csrfToken: "csrf-b2")] },
                listPorts: { _ in [12346] },
                callRPC: { _, endpoint, _, _ in
                    let state = localFraction.get()
                    if endpoint.contains("GetUserStatus") {
                        return [
                            "userStatus": [
                                "email": "multi@example.invalid",
                                "projectId": state.projectId,
                                "userTier": ["id": "pro", "name": "Pro"]
                            ]
                        ]
                    }
                    if endpoint.contains("RetrieveUserQuotaSummary") {
                        return [
                            "groups": [[
                                "displayName": "Gemini Models",
                                "buckets": [[
                                    "bucketId": "gemini-5h",
                                    "window": "5h",
                                    "remainingFraction": state.fraction,
                                    "resetTime": "2099-01-01T00:00:00Z"
                                ]]
                            ]]
                        ]
                    }
                    return nil
                }
            )
            let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
            let agyProvider = AntigravityProvider(homeDirectory: home.path, localQuotaReader: matchingLocalReader)
            let codexProvider = CodexProvider(homeDirectory: home.path)

            StubURLProtocol.install(hosts: ["googleapis.com", "chatgpt.com"])
            StubURLProtocol.respond(codexUsageURL, body: codexUsageOK)

            let engine1 = ProviderEngine(credentialStore: store, providersOverride: [agyProvider, codexProvider], homeDirectory: home.path, now: { clock.now() })
            localFraction.set(0.85, projectId: "proj-alpha")
            let rA = await engine1.fetchForCredential(providerId: "antigravity", credentialId: "agy-ws-a")
            localFraction.set(0.35, projectId: "proj-beta")
            let rB = await engine1.fetchForCredential(providerId: "antigravity", credentialId: "agy-ws-b")
            let rC = await engine1.fetchForCredential(providerId: "codex", credentialId: "codex-ws-a")
            try check(rA?.ok == true && rB?.ok == true && rC?.ok == true, "[B2] saved snapshots for both AGY workspaces and Codex")
            try check(!StubURLProtocol.requestedURLs.contains(where: { $0.contains("googleapis.com") }), "[B2 + §28] AGY local snapshots gathered with 0 Google HTTPS calls")

            // Inspect raw disk file permissions & secret whitelist
            let rawJSON = try String(contentsOf: snapStore.fileURL, encoding: .utf8)
            var fileStat = stat()
            try check(lstat(snapStore.fileURL.path, &fileStat) == 0 && (fileStat.st_mode & 0o777) == 0o600, "[B2] quota-snapshots.json has mode 0o600")
            var dirStat = stat()
            try check(lstat(snapStore.fileURL.deletingLastPathComponent().path, &dirStat) == 0 && (dirStat.st_mode & 0o777) == 0o700, "[B2] AIUsage dir has mode 0o700")
            for forbidden in ["secret-agy-token", "secret-agy-refresh", "secret-codex-tok", "secret-codex-ref", "Authorization", "Bearer", "e30."] {
                try check(!rawJSON.contains(forbidden), "[B2] disk snapshot must never store '\(forbidden)'")
            }

            // Backdate fetchedAt in snapshot file by 60 minutes to simulate cold restart 60m later, switch AGY back to default .localOnly
            var doc = snapStore.loadDocument()
            let sixtyMinsAgo = SharedFormatters.iso8601String(from: t0.addingTimeInterval(-3600))
            for key in doc.snapshots.keys {
                doc.snapshots[key]?.fetchedAt = sixtyMinsAgo
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(doc).write(to: snapStore.fileURL, options: .atomic)
            try AntigravityPoolProtectionSettings.setPollingMode(.localOnly, homeDirectory: home.path)

            // Cold restart with NEW ProviderEngine -> hydrates both AGY workspaces + Codex with 0 HTTP, retaining exact 60m-old fetchedAt!
            let httpBeforeHydrate = StubURLProtocol.requests.count
            let engine2 = ProviderEngine(credentialStore: store, providersOverride: [agyProvider, codexProvider], homeDirectory: home.path, now: { clock.now() })
            let hydratedDash = await engine2.cachedDashboard()
            try check(StubURLProtocol.requests.count == httpBeforeHydrate, "[B2] cold hydration + cachedDashboard executes 0 HTTP")
            let hA = hydratedDash.providers.first { $0.id == "antigravity:cred:agy-ws-a" }
            let hB = hydratedDash.providers.first { $0.id == "antigravity:cred:agy-ws-b" }
            let hC = hydratedDash.providers.first { $0.id == "codex:cred:codex-ws-a" }
            try check(hA?.summary?.remainingPercent == 85 && hB?.summary?.remainingPercent == 35, "[B2] both AGY workspaces under same email keep separate 85% and 35% snapshots")
            try check(hA?.summary?.fetchedAt == sixtyMinsAgo && hC?.summary?.fetchedAt == sixtyMinsAgo, "[B2] hydrated snapshots preserve 60m-old fetchedAt")

            // [Review #2] Deleting workspace A must preserve peer workspace B (both on disk and cached projection)
            await engine2.purgePersistedSnapshots(
                providerId: "antigravity",
                storageKeys: [agyWork1],
                credentialIds: [agyCredA.id],
                accountIds: ["multi@example.invalid"],
                emails: ["multi@example.invalid"]
            )
            let docAfterDeleteA = snapStore.loadDocument()
            try check(docAfterDeleteA.snapshots[agyWork1] == nil, "[B2] deleted workspace A snapshot removed from disk")
            try check(docAfterDeleteA.snapshots[agyWork2]?.remainingPercent == 35, "[B2] peer workspace B under same email survives delete of A on disk")
            let dashAfterDeleteA = await engine2.cachedDashboard(ids: ["antigravity"])
            try check(!dashAfterDeleteA.providers.contains(where: { $0.id == "antigravity:cred:agy-ws-a" }), "[B2] deleted workspace A absent from cachedDashboard")
            try check(dashAfterDeleteA.providers.contains(where: { $0.id == "antigravity:cred:agy-ws-b" && $0.summary?.remainingPercent == 35 }), "[B2] peer workspace B survives delete of A in cachedDashboard")

            // Restore workspace A for subsequent suspension test & verify [Review #5] out-of-order save monotonicity
            _ = snapStore.save(result: rA!, credential: agyCredA)
            let newerIso = SharedFormatters.iso8601String(from: t0.addingTimeInterval(300))
            let olderIso = SharedFormatters.iso8601String(from: t0.addingTimeInterval(60))
            var newerSnap = rB!
            newerSnap.summary?.fetchedAt = newerIso
            newerSnap.summary?.remainingPercent = 20
            var olderSnap = rB!
            olderSnap.summary?.fetchedAt = olderIso
            olderSnap.summary?.remainingPercent = 85
            try check(snapStore.save(result: newerSnap, credential: agyCredB), "[B2] newer snapshot saves cleanly")
            try check(!snapStore.save(result: olderSnap, credential: agyCredB), "[B2] stale out-of-order save returns false")
            let afterLateOld = snapStore.loadDocument().snapshots[agyWork2]
            try check(afterLateOld?.fetchedAt == newerIso && afterLateOld?.remainingPercent == 20, "[B2] out-of-order older save does not overwrite newer snapshot")

            // Terminal tos_violation overrides stale ok:true snapshot cleanly!
            let agyPathAData = try Data(contentsOf: agyPathA)
            try AntigravityAccountProtection.suspend(agyPathA, error: ProviderError("tos_violation", "Suspended test"), expectedData: agyPathAData)
            let agyAbsentEngine = ProviderEngine(credentialStore: store, providersOverride: [AntigravityProvider(homeDirectory: home.path, localQuotaReader: absentReader)], homeDirectory: home.path, now: { clock.now() })
            let suspendedDash = await agyAbsentEngine.cachedDashboard(ids: ["antigravity"])
            let suspCard = suspendedDash.providers.first { $0.id == "antigravity:cred:agy-ws-a" }
            try check(suspCard?.ok == false && suspCard?.summary?.errorCode == "tos_violation", "[B2] terminal tos_violation overrides stale ok:true disk snapshot on restart")

            // Corrupt JSON tolerance
            let corruptStore = QuotaSnapshotStore.store(homeDirectory: scratchRoot.appendingPathComponent("corrupt-home").path)
            try FileManager.default.createDirectory(at: corruptStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{not json!!!".utf8).write(to: corruptStore.fileURL, options: .atomic)
            try check(corruptStore.loadDocument().snapshots.isEmpty, "[B2] corrupt snapshot JSON returns empty document safely without crash")

            // Symlink rejection
            let symlinkHome = scratchRoot.appendingPathComponent("symlink-home", isDirectory: true)
            let symlinkStore = QuotaSnapshotStore.store(homeDirectory: symlinkHome.path)
            try FileManager.default.createDirectory(at: symlinkStore.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let victim = scratchRoot.appendingPathComponent("victim.txt")
            try Data("untouched".utf8).write(to: victim)
            try FileManager.default.createSymbolicLink(at: symlinkStore.fileURL, withDestinationURL: victim)
            let wroteSymlink = symlinkStore.save(result: rC!, credential: codexCredA)
            let victimText = try String(contentsOf: victim, encoding: .utf8)
            try check(!wroteSymlink && victimText == "untouched", "[B2] symlink snapshot target is safely rejected without clobbering victim")

            // In-flight delete race -> deleted account cannot resurrect or re-save into quota-snapshots.json
            let delHome = scratchRoot.appendingPathComponent("delete-race", isDirectory: true)
            try FileManager.default.createDirectory(at: delHome, withIntermediateDirectories: true)
            let delStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            let delPath = delHome.appendingPathComponent("del-codex.json")
            try writeCodexAuth(to: delPath, accountId: "org:del", userId: "usr:del", email: "deleted@example.invalid", accessToken: "secret-del", refreshToken: "secret-del-r")
            let delCred = AccountCredential(id: "codex-del", providerId: "codex", accountLabel: "deleted@example.invalid", authMethod: .authFile, credential: delPath.path, metadata: ["accountId": "org:del", "workspaceUserId": "usr:del"])
            try delStore.saveCredential(delCred)
            let delEngine = ProviderEngine(credentialStore: delStore, providersOverride: [CodexProvider(homeDirectory: delHome.path)], homeDirectory: delHome.path)
            StubURLProtocol.respond(codexUsageURL) { _ in
                try? delStore.deleteCredentials([delCred])
                return (200, codexUsageOK)
            }
            _ = await delEngine.fetchForCredential(providerId: "codex", credentialId: "codex-del")
            await delEngine.purgePersistedSnapshots(providerId: "codex", credentialIds: ["codex-del"], emails: ["deleted@example.invalid"])
            let postDelDash = await delEngine.cachedDashboard(ids: ["codex"])
            try check(!postDelDash.providers.contains(where: { $0.id == "codex:cred:codex-del" }), "[B2] deleted account does not resurrect in cachedDashboard")
            try check(QuotaSnapshotStore.store(homeDirectory: delHome.path).loadDocument().snapshots.isEmpty, "[B2] late response for deleted account does not persist to quota-snapshots.json")
        }

        // 4. [B2] QuotaSnapshotHealth & Read-Only BestNextAdvisor
        do {
            let now = Date(timeIntervalSince1970: 1_800_300_000)
            let pastIso = SharedFormatters.iso8601String(from: now.addingTimeInterval(-60))
            let futureIso = SharedFormatters.iso8601String(from: now.addingTimeInterval(3600 * 48))

            let pastStatus = QuotaSnapshotHealth.assess(windows: [
                .init(label: "5h Window", remainingPercent: 0, resetAt: pastIso),
                .init(label: "Weekly Window", remainingPercent: 75, resetAt: futureIso)
            ], now: now)
            try check(pastStatus.isPastReset, "[B2] now >= resetAt surfaces .pastReset without fabricating 100%")

            let weeklyDepleted = QuotaSnapshotHealth.assess(windows: [
                .init(label: "5h Window", remainingPercent: 0, resetAt: pastIso),
                .init(label: "Weekly Window", remainingPercent: 0, resetAt: futureIso)
            ], now: now)
            try check(weeklyDepleted.isWeeklyDepleted, "[B2] weekly 0% before weekly reset overrides past-reset 5h window as .weeklyDepleted")

            let best = QuotaSnapshotAdvisor.bestNextCandidate(from: [
                .init(id: "active", providerId: "antigravity", label: "active@e.inv", remainingPercent: 95, fetchedAt: now, isActive: true, isTerminalSuspended: false, windows: []),
                .init(id: "suspended", providerId: "antigravity", label: "susp@e.inv", remainingPercent: 90, fetchedAt: now, isActive: false, isTerminalSuspended: true, windows: []),
                .init(id: "depleted", providerId: "antigravity", label: "dep@e.inv", remainingPercent: 0, fetchedAt: now, isActive: false, isTerminalSuspended: false, windows: [.init(label: "Weekly Window", remainingPercent: 0, resetAt: futureIso)]),
                .init(id: "dormant-low", providerId: "antigravity", label: "low@e.inv", remainingPercent: 40, fetchedAt: now, isActive: false, isTerminalSuspended: false, windows: []),
                .init(id: "dormant-best", providerId: "antigravity", label: "best@e.inv", remainingPercent: 85, fetchedAt: now, isActive: false, isTerminalSuspended: false, windows: [])
            ], now: now)
            try check(best?.id == "dormant-best" && best?.remainingPercent == 85, "[B2] read-only advisor excludes active/suspended/weekly-depleted and recommends best@e.inv")
        }

        // 5. [M1] & [M3] Paused/Tombstoned Engine Exclusion (Same Email Peer, Codex Native Fallback, Late Completion) + Cold Non-AGY HTTP Guard
        do {
            let home = scratchRoot.appendingPathComponent("m1-m3-exclusion", isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let store = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            let nativePath = CodexQuotaPollingPolicy.nativeAuthFileURL(homeDirectory: home.path)
            let credPausedPath = home.appendingPathComponent("vault/codex-paused.json")
            let credPeerPath = home.appendingPathComponent("vault/codex-peer.json")
            let agyPausedPath = home.appendingPathComponent("vault/agy-paused.json")

            // Same email ("shared@example.invalid") across two workspaces
            try writeCodexAuth(to: nativePath, accountId: "ws-paused", userId: "user-1", email: "shared@example.invalid", accessToken: "secret-paused-tok", refreshToken: "secret-paused-ref")
            try writeCodexAuth(to: credPausedPath, accountId: "ws-paused", userId: "user-1", email: "shared@example.invalid", accessToken: "secret-paused-tok", refreshToken: "secret-paused-ref")
            try writeCodexAuth(to: credPeerPath, accountId: "ws-peer", userId: "user-2", email: "shared@example.invalid", accessToken: "secret-peer-tok", refreshToken: "secret-peer-ref")
            try writeAGYAuth(to: agyPausedPath, email: "shared@example.invalid", accessToken: "secret-agy-paused", refreshToken: "secret-agy-r", projectId: "proj-paused")

            try store.saveCredential(AccountCredential(id: "codex-paused", providerId: "codex", accountLabel: "shared@example.invalid", authMethod: .authFile, credential: credPausedPath.path, metadata: ["accountId": "ws-paused", "workspaceUserId": "user-1"]))
            try store.saveCredential(AccountCredential(id: "codex-peer", providerId: "codex", accountLabel: "shared@example.invalid", authMethod: .authFile, credential: credPeerPath.path, metadata: ["accountId": "ws-peer", "workspaceUserId": "user-2"]))
            try store.saveCredential(AccountCredential(id: "agy-paused", providerId: "antigravity", accountLabel: "shared@example.invalid", authMethod: .authFile, credential: agyPausedPath.path, metadata: ["projectId": "proj-paused"]))

            let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
            let engine = ProviderEngine(
                credentialStore: store,
                providersOverride: [
                    CodexProvider(homeDirectory: home.path),
                    AntigravityProvider(homeDirectory: home.path, localQuotaReader: absentReader),
                    GeminiProvider(homeDirectory: home.path)
                ],
                homeDirectory: home.path
            )
            let pausedKey = CodexAccountIdentity(accountId: "ws-paused", userId: "user-1").nativeKey!
            await engine.setExcludedAccounts(credentialIDs: ["codex-paused", "agy-paused"], codexNativeKeys: [pausedKey])

            StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com", "googleapis.com", "cloudcode-pa.googleapis.com"])
            StubURLProtocol.respond(codexUsageURL) { req in
                let bearer = req.headers["Authorization"] ?? ""
                if bearer.contains("secret-paused-tok") {
                    fatalError("[M1] Paused Codex credential/native fallback must NEVER be polled!")
                }
                return (200, codexUsageOK)
            }
            StubURLProtocol.respond(agyQuotaURL, body: agyQuotaOK)

            // Paused active native workspace must not poll via vault or native fallback
            let dashPaused = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try check(StubURLProtocol.requests.isEmpty && !dashPaused.providers.contains(where: { $0.resultAccountId == "ws-paused" || $0.summary?.accountId == "ws-paused" }),
                      "[M1] paused Codex identity blocked on both vault and native ~/.codex/auth.json fallback")

            // Switching native ~/.codex/auth.json to the peer workspace (same email!) polls ONLY the peer
            try writeCodexAuth(to: nativePath, accountId: "ws-peer", userId: "user-2", email: "shared@example.invalid", accessToken: "secret-peer-tok", refreshToken: "secret-peer-ref")
            let dashPeer = await engine.fetchAll(ids: ["codex"], backgroundAutomatic: true)
            try check(StubURLProtocol.requests.count == 1 && dashPeer.providers.contains(where: { $0.id == "codex:cred:codex-peer" && $0.ok }),
                      "[M1] pausing one workspace does not block peer workspace with same email")

            // Paused Antigravity credential is skipped even by direct fetchForCredential, and late completion during delete/hide cannot save to QuotaSnapshotStore
            let pausedFetch = await engine.fetchForCredential(providerId: "antigravity", credentialId: "agy-paused")
            try check(pausedFetch == nil && StubURLProtocol.requests.count == 1, "[M1] paused Antigravity credential returns nil from fetchForCredential with 0 HTTPS calls")

            // Late completion race after pause mid-flight on fresh Codex credential (keeps Antigravity strictly 0-HTTP)
            let credLatePath = home.appendingPathComponent("vault/codex-late.json")
            try writeCodexAuth(to: credLatePath, accountId: "ws-late", userId: "user-3", email: "late@example.invalid", accessToken: "secret-late-tok", refreshToken: "secret-late-ref")
            try store.saveCredential(AccountCredential(id: "codex-late", providerId: "codex", accountLabel: "late@example.invalid", authMethod: .authFile, credential: credLatePath.path, metadata: ["accountId": "ws-late", "workspaceUserId": "user-3"]))
            StubURLProtocol.respond(codexUsageURL) { req in
                let bearer = req.headers["Authorization"] ?? ""
                if bearer.contains("secret-paused-tok") {
                    fatalError("[M1] Paused Codex credential/native fallback must NEVER be polled!")
                }
                let excludedGate = DispatchSemaphore(value: 0)
                Task {
                    await engine.setExcludedAccounts(credentialIDs: ["codex-paused", "agy-paused", "codex-late"], codexNativeKeys: [pausedKey])
                    excludedGate.signal()
                }
                _ = excludedGate.wait(timeout: .now() + 2)
                return (200, codexUsageOK)
            }
            let lateHiddenCodex = await engine.fetchForCredential(providerId: "codex", credentialId: "codex-late")
            let afterHideSnap = QuotaSnapshotStore.store(homeDirectory: home.path).loadDocument().snapshots
            try check(lateHiddenCodex == nil && !afterHideSnap.values.contains(where: { $0.credentialId == "codex-late" }),
                      "[M1] late completion hidden mid-flight does not write snapshot to QuotaSnapshotStore")

            // [§6.2] Queued credential paused/removed while waiting on credentialLaneTails must NEVER reach provider
            final class QueuedLaneGateProvider: CredentialAcceptingProvider, @unchecked Sendable {
                let id = "codex"
                let displayName = "Codex"
                let description = "Queued lane test provider"
                let supportedAuthMethods: [AuthMethod] = [.authFile]
                private let lock = NSLock()
                private var recordedCalls: [String] = []
                private var enteredFirst = false
                private var firstEnteredContinuation: CheckedContinuation<Void, Never>?
                private var firstReleaseContinuation: CheckedContinuation<Void, Never>?

                var calls: [String] { lock.withLock { recordedCalls } }

                func fetchUsage() async throws -> ProviderUsage {
                    throw ProviderError("unsupported", "unused")
                }

                func waitUntilFirstEntered() async {
                    let alreadyEntered = lock.withLock { enteredFirst }
                    if !alreadyEntered {
                        await withCheckedContinuation { continuation in
                            let resumeNow = lock.withLock { () -> Bool in
                                if enteredFirst { return true }
                                firstEnteredContinuation = continuation
                                return false
                            }
                            if resumeNow { continuation.resume() }
                        }
                    }
                }

                func releaseFirst() {
                    let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                        let c = firstReleaseContinuation
                        firstReleaseContinuation = nil
                        return c
                    }
                    continuation?.resume()
                }

                func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
                    let shouldHold = lock.withLock { () -> Bool in
                        recordedCalls.append(credential.id)
                        if credential.id == "codex-q-a" && !enteredFirst {
                            enteredFirst = true
                            return true
                        }
                        return false
                    }
                    if shouldHold {
                        let waiter = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                            let c = firstEnteredContinuation
                            firstEnteredContinuation = nil
                            return c
                        }
                        waiter?.resume()
                        await withCheckedContinuation { continuation in
                            lock.withLock { firstReleaseContinuation = continuation }
                        }
                    }
                    var usage = ProviderUsage(provider: "codex", label: "Codex", accountId: credential.accountLabel ?? credential.id)
                    usage.accountEmail = credential.accountLabel
                    return usage
                }
            }

            let queueHome = home.appendingPathComponent("queue-gate-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: queueHome, withIntermediateDirectories: true)
            let queueStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            let codexQAPath = queueHome.appendingPathComponent("codex-q-a.json")
            let codexQBPath = queueHome.appendingPathComponent("codex-q-b.json")
            try writeCodexAuth(to: codexQAPath, accountId: "ws-qa", userId: "u-qa", email: "qa@example.invalid", accessToken: "tok-a", refreshToken: "ref-a")
            try writeCodexAuth(to: codexQBPath, accountId: "ws-qb", userId: "u-qb", email: "qb@example.invalid", accessToken: "tok-b", refreshToken: "ref-b")
            try queueStore.saveCredential(AccountCredential(id: "codex-q-a", providerId: "codex", accountLabel: "qa@example.invalid", authMethod: .authFile, credential: codexQAPath.path, metadata: ["accountId": "ws-qa", "workspaceUserId": "u-qa"]))
            try queueStore.saveCredential(AccountCredential(id: "codex-q-b", providerId: "codex", accountLabel: "qb@example.invalid", authMethod: .authFile, credential: codexQBPath.path, metadata: ["accountId": "ws-qb", "workspaceUserId": "u-qb"]))
            let fakeQueueProvider = QueuedLaneGateProvider()
            let queueEngine = ProviderEngine(credentialStore: queueStore, providersOverride: [fakeQueueProvider], homeDirectory: queueHome.path)

            let taskA = Task { await queueEngine.fetchForCredential(providerId: "codex", credentialId: "codex-q-a") }
            await fakeQueueProvider.waitUntilFirstEntered()
            let taskB = Task { await queueEngine.fetchForCredential(providerId: "codex", credentialId: "codex-q-b") }
            try await Task.sleep(for: .milliseconds(50))
            await queueEngine.setExcludedAccounts(credentialIDs: ["codex-q-b"], codexNativeKeys: [])
            fakeQueueProvider.releaseFirst()
            let resultA = await taskA.value
            let resultB = await taskB.value
            try check(fakeQueueProvider.calls == ["codex-q-a"] && resultA?.ok == true && resultB == nil,
                      "[§6.2] queued credential paused before lane dispatch never reaches provider and returns nil")

            // [§6.2] Pausing after recentCredentials populated must still reject useRecentResults: true fetches
            await queueEngine.setExcludedAccounts(credentialIDs: ["codex-q-a", "codex-q-b"], codexNativeKeys: [])
            let cachedAfterPause = await queueEngine.fetchAll(ids: ["codex"], useRecentResults: true)
            let directCachedAfterPause = await queueEngine.fetchForCredential(providerId: "codex", credentialId: "codex-q-a")
            try check(cachedAfterPause.providers.isEmpty && directCachedAfterPause == nil,
                      "[§6.2] excluded credential never returns stale recentCredentials even when useRecentResults=true")

            // [§8.6] QuotaShareServer plaintext policy allows loopback ONLY (rejects 100.64.0.0/10 CGNAT, fd7a::, RFC1918, link-local) unless TLS is active
            try check(!QuotaShareServer.isAllowedPeer(NWEndpoint.Host("192.168.1.25"))
                        && !QuotaShareServer.isAllowedPeer(NWEndpoint.Host("10.0.0.5"))
                        && !QuotaShareServer.isAllowedPeer(NWEndpoint.Host("172.16.0.10"))
                        && !QuotaShareServer.isAllowedPeer(NWEndpoint.Host("100.64.1.2"))
                        && !QuotaShareServer.isAllowedPeer(NWEndpoint.Host("fd7a:115c:a1e0::1234"))
                        && !QuotaShareServer.isAllowedPeer(NWEndpoint.Host("fe80::1"))
                        && QuotaShareServer.isAllowedPeer(NWEndpoint.Host("127.0.0.1"))
                        && QuotaShareServer.isAllowedPeer(NWEndpoint.Host("::1"))
                        && QuotaShareServer.isAllowedPeer(NWEndpoint.Host("::ffff:127.0.0.1"))
                        && QuotaShareServer.isAllowedPeer(NWEndpoint.Host("100.64.1.2"), allowPrivateLAN: true)
                        && QuotaShareServer.isAllowedPeer(NWEndpoint.Host("192.168.1.25"), allowPrivateLAN: true),
                      "[§8.6] QuotaShareServer plaintext allows loopback only; shared CGNAT & LAN require TLS")

            // [M3] Cache-only cachedSingle(antigravity) must return terminal unavailable when projection is empty (never fall through to stale cachedProviders)
            let server = QuotaHTTPServer(host: "127.0.0.1", port: 0, startupToken: "m3-secret", engine: engine)
            let agyHeaders = ["x-aiusage-startup-token": "m3-secret"]
            let agyExcludedSingle = await server.routeRequest(.init(method: "GET", path: "/api/provider/antigravity", headers: agyHeaders, body: Data()))
            let agyExcludedRes = try JSONDecoder().decode(ProviderResult.self, from: agyExcludedSingle.body)
            try check(agyExcludedSingle.status == 200 && !agyExcludedRes.ok && agyExcludedRes.summary?.errorCode == "unavailable",
                      "[M3] cachedSingle(antigravity) returns terminal unavailable when all credentials are excluded")

            // [M3] Authorized cold HTTP GETs on non-Codex/AGY provider (`gemini`) must schedule 0 background fetches
            let reqCountBeforeHTTP = StubURLProtocol.requests.count
            let gemHeaders = ["x-aiusage-startup-token": "m3-secret"]
            let gemDash = await server.routeRequest(.init(method: "GET", path: "/api/dashboard?ids=gemini", headers: gemHeaders, body: Data()))
            let gemSingle = await server.routeRequest(.init(method: "GET", path: "/api/provider/gemini", headers: gemHeaders, body: Data()))
            let gemDashSnap = try JSONDecoder().decode(DashboardSnapshot.self, from: gemDash.body)
            let gemSingleRes = try JSONDecoder().decode(ProviderResult.self, from: gemSingle.body)
            try check(gemDash.status == 200 && gemSingle.status == 200
                        && gemDashSnap.providers.first?.summary?.errorCode == "unavailable"
                        && gemSingleRes.summary?.errorCode == "unavailable",
                      "[M3] authorized cold non-Codex/AGY HTTP GETs return unavailable")
            try await Task.sleep(for: .milliseconds(150))
            try check(StubURLProtocol.requests.count == reqCountBeforeHTTP,
                      "[M3] cold GET /api/dashboard & /api/provider/gemini schedule zero background fetches")

            // [§45] Legacy CPA archive remains recursively read-only across Codex lock/refresh/persist/flush paths
            do {
                let archiveHome = home.appendingPathComponent("codex-archive-ro-\(UUID().uuidString)")
                let archiveDir = archiveHome.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth", isDirectory: true)
                let nestedArchiveDir = archiveDir.appendingPathComponent("nested", isDirectory: true)
                let outsideDir = archiveHome.appendingPathComponent("outside", isDirectory: true)
                try FileManager.default.createDirectory(at: nestedArchiveDir, withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)

                func recursiveManifest(at root: URL) throws -> [String] {
                    let fm = FileManager.default
                    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
                    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
                    var entries: [String] = []
                    for case let item as URL in enumerator {
                        let vals = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        let resolvedItem = item.resolvingSymlinksInPath().standardizedFileURL
                        let rel = resolvedItem.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
                        if vals.isSymbolicLink == true {
                            let dest = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                            entries.append("L:\(rel)->\(dest)")
                            enumerator.skipDescendants()
                        } else if vals.isRegularFile == true {
                            let d = try Data(contentsOf: item)
                            let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
                            entries.append("F:\(rel):\(d.count):\(sha)")
                        }
                    }
                    return entries.sorted()
                }

                let nowEpoch = Int(Date().timeIntervalSince1970)
                func signedJWT(jti: String, iat: Int) throws -> String {
                    let payload: [String: Any] = [
                        "jti": jti, "iat": iat, "exp": nowEpoch + 864_000,
                        "https://api.openai.com/auth": ["chatgpt_account_id": "ws-arch-1", "chatgpt_user_id": "u-arch-1"]
                    ]
                    let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]).base64EncodedString()
                        .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                    return "e30.\(encoded).fixture"
                }

                let freshTok = try signedJWT(jti: "arch-fresh", iat: nowEpoch)
                let staleTok = try signedJWT(jti: "arch-stale", iat: nowEpoch - 9 * 86_400)
                let rotatedTok = try signedJWT(jti: "arch-rotated", iat: nowEpoch + 1)

                let preExistingLock = archiveDir.appendingPathComponent("preexisting.lock")
                try Data("existing-lock".utf8).write(to: preExistingLock)
                let freshArch = archiveDir.appendingPathComponent("aiusage-codex-fresh.json")
                let staleArch = nestedArchiveDir.appendingPathComponent("aiusage-codex-stale.json")
                try JSONSerialization.data(withJSONObject: [
                    "type": "codex", "account_id": "ws-arch-1", "user_id": "u-arch-1",
                    "access_token": freshTok, "refresh_token": "r-arch-fresh",
                    "last_refresh": SharedFormatters.iso8601String(from: Date())
                ]).write(to: freshArch)
                try JSONSerialization.data(withJSONObject: [
                    "type": "codex", "account_id": "ws-arch-1", "user_id": "u-arch-1",
                    "access_token": staleTok, "refresh_token": "r-arch-stale",
                    "last_refresh": "2020-01-01T00:00:00Z"
                ]).write(to: staleArch)

                let outsideTarget = outsideDir.appendingPathComponent("outside-real.json")
                try JSONSerialization.data(withJSONObject: [
                    "type": "codex", "account_id": "ws-arch-1", "user_id": "u-arch-1",
                    "access_token": staleTok, "id_token": staleTok, "refresh_token": "r-outside-real",
                    "last_refresh": "2020-01-01T00:00:00Z"
                ]).write(to: outsideTarget)
                let outsideTargetBefore = try Data(contentsOf: outsideTarget)
                let insideSymlinkOut = archiveDir.appendingPathComponent("inside-symlink.json")
                let aliasFile = outsideDir.appendingPathComponent("alias-file.json")
                let aliasDir = outsideDir.appendingPathComponent("alias-dir")
                let aliasNestedDir = outsideDir.appendingPathComponent("alias-nested-dir")
                let brokenHop1 = outsideDir.appendingPathComponent("broken-hop1.json")
                let brokenHop2 = outsideDir.appendingPathComponent("broken-hop2.json")
                try FileManager.default.createSymbolicLink(at: insideSymlinkOut, withDestinationURL: outsideTarget)
                try FileManager.default.createSymbolicLink(at: aliasFile, withDestinationURL: freshArch)
                try FileManager.default.createSymbolicLink(at: aliasDir, withDestinationURL: archiveDir)
                try FileManager.default.createSymbolicLink(at: aliasNestedDir, withDestinationURL: nestedArchiveDir)
                try FileManager.default.createSymbolicLink(atPath: brokenHop1.path, withDestinationPath: archiveDir.appendingPathComponent("nonexistent/missing.json").path)
                try FileManager.default.createSymbolicLink(atPath: brokenHop2.path, withDestinationPath: "broken-hop1.json")
                let dotDotAcrossSymlink = aliasNestedDir.path + "/../missing-dotdot.json"
                let upperCaseArchive = archiveHome.appendingPathComponent("Library/Application Support/AIUsage/CLIPROXYAPI/AUTH/nested/aiusage-codex-stale.json").path

                try check(CodexCredentialPolicy.isLegacyCPAArchivePath(freshArch.path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(staleArch.path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(aliasFile.path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(aliasDir.appendingPathComponent("nested/aiusage-codex-stale.json").path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(insideSymlinkOut.path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(brokenHop1.path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(brokenHop2.path, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(dotDotAcrossSymlink, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath(upperCaseArchive, homeDirectory: archiveHome.path)
                            && CodexCredentialPolicy.isLegacyCPAArchivePath("~/Library/Application Support/AIUsage/CLIProxyAPI/auth/fixture.json")
                            && !CodexCredentialPolicy.isLegacyCPAArchivePath(outsideTarget.path, homeDirectory: archiveHome.path),
                          "[§45] archive path detector catches direct, nested, 1/2-hop broken symlinks, dot-dot across symlink, case/tilde variants, and internal-symlink paths without blocking outside files")

                let manifestBefore = try recursiveManifest(at: archiveDir)
                let archProvider = CodexProvider(homeDirectory: archiveHome.path)
                let archCred = AccountCredential(providerId: "codex", authMethod: .authFile, credential: freshArch.path, metadata: ["accountId": "ws-arch-1", "workspaceUserId": "u-arch-1"])
                let oauthURL = "https://auth.openai.com/oauth/token"
                let usageURL = "https://chatgpt.com/backend-api/wham/usage"
                StubURLProtocol.respond(oauthURL, status: 200, body: String(decoding: try JSONSerialization.data(withJSONObject: ["access_token": rotatedTok, "refresh_token": "r-rot"]), as: UTF8.self))
                StubURLProtocol.respond(usageURL) { req in
                    let auth = req.headers["Authorization"] ?? ""
                    return (auth == "Bearer \(freshTok)" || auth == "Bearer \(rotatedTok)") ? (200, #"{"plan_type":"plus"}"#) : (401, "{}")
                }
                let oauthBefore = StubURLProtocol.requests.filter { $0.url == oauthURL }.count
                _ = try await archProvider.fetchUsage(with: archCred)
                for roTarget in [staleArch, aliasFile, aliasDir.appendingPathComponent("nested/aiusage-codex-stale.json")] {
                    let c = AccountCredential(providerId: "codex", authMethod: .authFile, credential: roTarget.path, metadata: ["accountId": "ws-arch-1", "workspaceUserId": "u-arch-1"])
                    _ = try? await archProvider.fetchUsage(with: c)
                }
                let oauthAfterDirect = StubURLProtocol.requests.filter { $0.url == oauthURL }.count
                try check(oauthAfterDirect == oauthBefore, "[§45] direct & aliased archive reads must not invoke OAuth refresh")

                let loadedFresh = try archProvider.loadCredentials(from: freshArch.path)
                let loadedOutsideTarget = try archProvider.loadCredentials(from: outsideTarget.path)
                let mintedArch = CodexProvider.Credentials(
                    authFile: freshArch.path, accessToken: rotatedTok, refreshToken: "r-rot", idToken: loadedFresh.idToken,
                    accountId: "ws-arch-1", accountEmail: nil, jwtPlanType: nil, jwtUserId: "u-arch-1", needsRefresh: false, isApiKeyMode: false
                )
                archProvider.persistRefreshedCredentials(mintedArch, replacing: loadedFresh, to: freshArch.path)
                archProvider.persistRefreshedCredentials(mintedArch, replacing: loadedFresh, to: aliasFile.path)
                archProvider.persistRefreshedCredentials(mintedArch, replacing: loadedOutsideTarget, to: insideSymlinkOut.path)
                let manifestAfterPersist = try recursiveManifest(at: archiveDir)
                let outsideUnchanged = (try Data(contentsOf: outsideTarget)) == outsideTargetBefore
                try check(manifestAfterPersist == manifestBefore && outsideUnchanged,
                          "[§45] archive manifest, valid-token symlink target, and pre-existing lock stay identical after fresh/stale/alias usage & direct persist")

                // Ordinary managed copy outside archive with saved sourcePath pointing to archive refreshes normally without modifying archive
                let managedOutside = outsideDir.appendingPathComponent("managed-codex.json")
                try JSONSerialization.data(withJSONObject: [
                    "last_refresh": "2020-01-01T00:00:00Z",
                    "tokens": ["account_id": "ws-arch-1", "id_token": staleTok, "access_token": staleTok, "refresh_token": "r-managed"]
                ]).write(to: managedOutside)
                let managedCred = AccountCredential(
                    id: "managed-arch-src", providerId: "codex", authMethod: .authFile, credential: managedOutside.path,
                    metadata: ["accountId": "ws-arch-1", "workspaceUserId": "u-arch-1", "sourcePath": aliasFile.path]
                )
                _ = try await archProvider.fetchUsage(with: managedCred)
                let reloadedManaged = try archProvider.loadCredentials(from: managedOutside.path)
                let manifestAfterManaged = try recursiveManifest(at: archiveDir)
                try check(reloadedManaged.accessToken == rotatedTok
                            && manifestAfterManaged == manifestBefore
                            && FileManager.default.fileExists(atPath: preExistingLock.path),
                          "[§45] ordinary managed Codex copy refreshes & saves outside archive while archive & pre-existing lock remain untouched")

                // flushLiveAuthToManagedCopies + OfficialWarmupProcess.healStagedCodexAuth skip archive/aliases while healing writable outside copies
                let liveFlushSource = outsideDir.appendingPathComponent("live-flush.json")
                let flushOutside = outsideDir.appendingPathComponent("flush-outside.json")
                let warmupOutside = outsideDir.appendingPathComponent("warmup-outside.json")
                let stagedWarmupSource = outsideDir.appendingPathComponent("staged-warmup.json")
                let flushBaselineData = try JSONSerialization.data(withJSONObject: [
                    "last_refresh": "2020-01-01T00:00:00Z",
                    "tokens": ["account_id": "ws-arch-1", "id_token": staleTok, "access_token": staleTok, "refresh_token": "r-flush-stale"]
                ])
                let flushNewerData = try JSONSerialization.data(withJSONObject: [
                    "last_refresh": SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: TimeInterval(nowEpoch + 10))),
                    "tokens": ["account_id": "ws-arch-1", "id_token": rotatedTok, "access_token": rotatedTok, "refresh_token": "r-flush-new"]
                ])
                try flushNewerData.write(to: liveFlushSource)
                try flushNewerData.write(to: stagedWarmupSource)
                try flushBaselineData.write(to: flushOutside)
                try flushBaselineData.write(to: warmupOutside)
                let archStaleCred = AccountCredential(id: "arch-stale", providerId: "codex", authMethod: .authFile, credential: staleArch.path, metadata: ["accountId": "ws-arch-1", "workspaceUserId": "u-arch-1"])
                let archAliasCred = AccountCredential(id: "arch-alias", providerId: "codex", authMethod: .authFile, credential: aliasFile.path, metadata: ["accountId": "ws-arch-1", "workspaceUserId": "u-arch-1"])
                let flushOutCred = AccountCredential(id: "flush-out", providerId: "codex", authMethod: .authFile, credential: flushOutside.path, metadata: ["accountId": "ws-arch-1", "workspaceUserId": "u-arch-1"])
                let flushWritten = CodexCredentialPolicy.flushLiveAuthToManagedCopies(
                    candidatePaths: [liveFlushSource.path],
                    excludingIdentity: CodexAccountIdentity(accountId: "other-ws", userId: "other-u"),
                    loadCredentials: { [archStaleCred, archAliasCred, flushOutCred] },
                    homeDirectory: archiveHome.path
                )
                let healResult = OfficialWarmupProcess.healStagedCodexAuth(
                    stagedAuth: stagedWarmupSource,
                    stagedBaselineData: flushBaselineData,
                    destinations: [staleArch.path, aliasFile.path, insideSymlinkOut.path, warmupOutside.path],
                    expectedIdentity: CodexAccountIdentity(accountId: "ws-arch-1", userId: "u-arch-1"),
                    boundary: ManagedAuthImportBoundary(bundleIdentifier: "com.test", applicationSupportDirectory: outsideDir.appendingPathComponent("AppSupport")),
                    homeURL: archiveHome
                )
                let reloadedFlushOut = try archProvider.loadCredentials(from: flushOutside.path)
                let reloadedWarmupOut = try archProvider.loadCredentials(from: warmupOutside.path)
                let manifestAfterFlushWarmup = try recursiveManifest(at: archiveDir)
                let outsideStillUnchanged = (try Data(contentsOf: outsideTarget)) == outsideTargetBefore
                try check(flushWritten == 1
                            && healResult
                            && reloadedFlushOut.accessToken == rotatedTok
                            && reloadedWarmupOut.accessToken == rotatedTok
                            && outsideStillUnchanged
                            && manifestAfterFlushWarmup == manifestBefore,
                          "[§45] flushLiveAuthToManagedCopies & healStagedCodexAuth heal outside copies only while leaving archive & symlinks untouched")
            }

            // [§49] CodexSessionProviderMigrator skips archive-backed roots, files, SQLite indexes, and symlinked -wal sidecars
            do {
                let fm = FileManager.default
                func manifest(at root: URL) throws -> [String] {
                    guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: []) else { return [] }
                    let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
                    var out: [String] = []
                    for case let item as URL in enumerator {
                        let vals = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                        let rel = item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
                        if vals.isSymbolicLink == true {
                            out.append("L:\(rel)->\((try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? "")")
                        } else if vals.isRegularFile == true {
                            let d = try Data(contentsOf: item)
                            let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
                            out.append("F:\(rel):\(d.count):\(sha)")
                        }
                    }
                    return out.sorted()
                }
                func writeSession(_ url: URL, id: String, provider: String) throws {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let line = try JSONSerialization.data(withJSONObject: [
                        "timestamp": "2026-09-05T00:00:00.000Z",
                        "type": "session_meta",
                        "payload": ["id": id, "model_provider": provider]
                    ], options: [.sortedKeys])
                    try (line + Data("\n{\"type\":\"response_item\",\"payload\":{\"text\":\"ok\"}}\n".utf8)).write(to: url, options: .atomic)
                }
                func readSessionProvider(_ url: URL) throws -> String? {
                    let raw = try String(contentsOf: url, encoding: .utf8)
                    guard let first = raw.split(separator: "\n").first,
                          let obj = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { return nil }
                    return payload["model_provider"] as? String
                }
                func createDB(_ url: URL, table: String) throws {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    var db: OpaquePointer?
                    defer { if let db { sqlite3_close(db) } }
                    try check(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, "create sqlite db")
                    let sql = "CREATE TABLE \(table) (id TEXT PRIMARY KEY, model_provider TEXT NOT NULL); INSERT INTO \(table) VALUES ('legacy','aiusage-proxy'),('native','openai');"
                    try check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "seed sqlite db")
                }
                func legacyRowCount(_ url: URL, table: String) throws -> Int {
                    var db: OpaquePointer?
                    defer { if let db { sqlite3_close(db) } }
                    try check(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, "open readonly db")
                    var stmt: OpaquePointer?
                    defer { sqlite3_finalize(stmt) }
                    try check(sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table) WHERE model_provider = 'aiusage-proxy'", -1, &stmt, nil) == SQLITE_OK, "prepare count")
                    try check(sqlite3_step(stmt) == SQLITE_ROW, "step count")
                    return Int(sqlite3_column_int(stmt, 0))
                }

                let migHome = home.appendingPathComponent("codex-migrator-ro-\(UUID().uuidString)")
                let migArchive = migHome.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth", isDirectory: true)
                let migArchSessions = migArchive.appendingPathComponent("archive-sessions", isDirectory: true)
                let migArchSqlite = migArchive.appendingPathComponent("archive-sqlite", isDirectory: true)
                try fm.createDirectory(at: migArchSessions, withIntermediateDirectories: true)
                try fm.createDirectory(at: migArchSqlite, withIntermediateDirectories: true)
                let migLock = migArchive.appendingPathComponent("preexisting.lock")
                try Data("keep-lock".utf8).write(to: migLock)
                try Data("keep-wal".utf8).write(to: migArchive.appendingPathComponent("wal-target.bin"))
                let migArchRollout = migArchSessions.appendingPathComponent("archived-rollout.jsonl")
                let migArchStateDB = migArchSqlite.appendingPathComponent("state_9.sqlite")
                let migArchCatalogDB = migArchSqlite.appendingPathComponent("codex-dev.db")
                try writeSession(migArchRollout, id: "arch-sess", provider: "aiusage-proxy")
                try createDB(migArchStateDB, table: "threads")
                try createDB(migArchCatalogDB, table: "local_thread_catalog")
                let migManifestBefore = try manifest(at: migArchive)

                let migCodex = migHome.appendingPathComponent(".codex", isDirectory: true)
                let migOrdinaryRollout = migCodex.appendingPathComponent("sessions/2026/09/05/ordinary.jsonl")
                try writeSession(migOrdinaryRollout, id: "ord-sess", provider: "aiusage-proxy")
                try fm.createSymbolicLink(at: migCodex.appendingPathComponent("sessions/2026/09/05/aliased-leaf.jsonl"), withDestinationURL: migArchRollout)
                try fm.createSymbolicLink(at: migCodex.appendingPathComponent("sessions/aliased-subdir"), withDestinationURL: migArchSessions)
                try fm.createSymbolicLink(at: migCodex.appendingPathComponent("archived_sessions"), withDestinationURL: migArchSessions)
                let migOrdinaryDB = migCodex.appendingPathComponent("state_1.sqlite")
                let migWalDB = migCodex.appendingPathComponent("state_2.sqlite")
                try createDB(migOrdinaryDB, table: "threads")
                try createDB(migWalDB, table: "threads")
                let migWalDBBefore = try Data(contentsOf: migWalDB)
                try fm.createSymbolicLink(at: migCodex.appendingPathComponent("state_2.sqlite-wal"), withDestinationURL: migArchive.appendingPathComponent("wal-target.bin"))
                try fm.createSymbolicLink(at: migCodex.appendingPathComponent("sqlite"), withDestinationURL: migArchSqlite)

                let migReport = try CodexSessionProviderMigrator.migrate(homeDirectory: migHome.path)
                let migWalVerifyCopy = migHome.appendingPathComponent("verify-wal-state.sqlite")
                try fm.copyItem(at: migWalDB, to: migWalVerifyCopy)
                let migOrdProvider = try readSessionProvider(migOrdinaryRollout)
                let migOrdDBLegacy = try legacyRowCount(migOrdinaryDB, table: "threads")
                let migWalDBLegacy = try legacyRowCount(migWalVerifyCopy, table: "threads")
                let migWalUnchanged = (try Data(contentsOf: migWalDB)) == migWalDBBefore
                let migArchProvider = try readSessionProvider(migArchRollout)
                let migArchStateLegacy = try legacyRowCount(migArchStateDB, table: "threads")
                let migArchCatalogLegacy = try legacyRowCount(migArchCatalogDB, table: "local_thread_catalog")
                let migManifestAfter = try manifest(at: migArchive)
                try check(migReport.migratedFiles == 1
                            && migReport.migratedDatabaseRows == 1
                            && migOrdProvider == "openai"
                            && migOrdDBLegacy == 0
                            && migWalUnchanged
                            && migWalDBLegacy == 1
                            && migArchProvider == "aiusage-proxy"
                            && migArchStateLegacy == 1
                            && migArchCatalogLegacy == 1
                            && migManifestAfter == migManifestBefore
                            && fm.fileExists(atPath: migLock.path),
                          "[§49] CodexSessionProviderMigrator skips aliased roots/subdirs/SQLite/-wal while migrating ordinary session & index and keeping archive byte-identical (files=\(migReport.migratedFiles) db=\(migReport.migratedDatabaseRows) ord=\(migOrdProvider ?? "nil") ordDB=\(migOrdDBLegacy) walUnchanged=\(migWalUnchanged) walDB=\(migWalDBLegacy) arch=\(migArchProvider ?? "nil") archState=\(migArchStateLegacy) archCat=\(migArchCatalogLegacy) manifestEq=\(migManifestAfter == migManifestBefore) lock=\(fm.fileExists(atPath: migLock.path)))")

                let migHome2 = home.appendingPathComponent("codex-migrator-whole-\(UUID().uuidString)")
                let migArchive2 = migHome2.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth", isDirectory: true)
                try writeSession(migArchive2.appendingPathComponent("sessions/arch2.jsonl"), id: "arch2-sess", provider: "aiusage-proxy")
                try createDB(migArchive2.appendingPathComponent("state_8.sqlite"), table: "threads")
                try fm.createDirectory(at: migHome2, withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: migHome2.appendingPathComponent(".codex"), withDestinationURL: migArchive2)
                let mig2Before = try manifest(at: migArchive2)
                let migReport2 = try CodexSessionProviderMigrator.migrate(homeDirectory: migHome2.path)
                let mig2After = try manifest(at: migArchive2)
                try check(migReport2.scannedFiles == 0
                            && migReport2.migratedFiles == 0
                            && migReport2.migratedDatabaseRows == 0
                            && mig2After == mig2Before,
                          "[§49] CodexSessionProviderMigrator scans & migrates nothing when ~/.codex resolves directly into CLIProxyAPI/auth")

                // [§53] Mid-scan archive-root repointing: write checks resolve fresh archiveRoots after discovery
                let migHome3 = home.appendingPathComponent("codex-migrator-repoint-\(UUID().uuidString)")
                let migV1 = migHome3.appendingPathComponent("archive-v1", isDirectory: true)
                let migV2 = migHome3.appendingPathComponent("archive-v2", isDirectory: true)
                try fm.createDirectory(at: migV1, withIntermediateDirectories: true)
                try writeSession(migV2.appendingPathComponent("sessions/2026/09/05/race.jsonl"), id: "race-sess", provider: "aiusage-proxy")
                try createDB(migV2.appendingPathComponent("state_8.sqlite"), table: "threads")
                let migAuthLink = migHome3.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
                try fm.createDirectory(at: migAuthLink.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createSymbolicLink(at: migAuthLink, withDestinationURL: migV1)
                try fm.createSymbolicLink(at: migHome3.appendingPathComponent(".codex"), withDestinationURL: migV2)
                let mig3Before = try manifest(at: migV2)
                CodexSessionProviderMigrator.afterDiscoveryHookForTesting = {
                    let staging = migAuthLink.deletingLastPathComponent().appendingPathComponent(".swap-\(UUID().uuidString)")
                    try? fm.createSymbolicLink(at: staging, withDestinationURL: migV2)
                    _ = rename(staging.path, migAuthLink.path)
                }
                defer { CodexSessionProviderMigrator.afterDiscoveryHookForTesting = nil }
                let migReport3 = try CodexSessionProviderMigrator.migrate(homeDirectory: migHome3.path)
                CodexSessionProviderMigrator.afterDiscoveryHookForTesting = nil
                let mig3After = try manifest(at: migV2)
                let mig3JournalExists = fm.fileExists(atPath: CodexSessionProviderMigrator.archiveURL(homeDirectory: migHome3.path).path)
                try check(migReport3.scannedFiles == 1
                            && migReport3.migratedFiles == 0
                            && migReport3.migratedDatabaseRows == 0
                            && !mig3JournalExists
                            && mig3After == mig3Before,
                          "[§53] CodexSessionProviderMigrator write checks resolve fresh archiveRoots after discovery and block mid-scan repointed archive (scanned=\(migReport3.scannedFiles) files=\(migReport3.migratedFiles) db=\(migReport3.migratedDatabaseRows) journal=\(mig3JournalExists))")
            }
        }

        print("PASS: Post-R6 MasterPlan v3 backend/HTTP/cache regression (\(assertionCount) assertions, zero real vault/network side effects)")
    }
}
