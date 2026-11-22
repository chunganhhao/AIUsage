import Foundation
@testable import QuotaBackend

private actor Calls {
    var starts: [(String, Date)] = []
    var active = 0
    var overlap = false
    func enter(_ id: String) { active += 1; overlap = overlap || active > 1; starts.append((id, Date())) }
    func leave() { active -= 1 }
}
private struct PollProvider: CredentialAcceptingProvider {
    let id = "antigravity"
    let displayName = "Fixture"
    let description = "Fixture"
    var supportedAuthMethods: [AuthMethod] { [.authFile] }
    let calls: Calls
    func fetchUsage() async throws -> ProviderUsage { fatalError("credential required") }
    func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
        await calls.enter(credential.id)
        try await Task.sleep(for: .milliseconds(20))
        await calls.leave()
        return ProviderUsage(provider: id, label: displayName, accountId: credential.id)
    }
}
@main struct AntiBanPollingRegression {
    static var checks = 0
    static func check(_ pass: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try pass() else { throw NSError(domain: message, code: 1) }; checks += 1
    }
    static let load = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    static let prodLoad = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    static let quota = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    static let refresh = "https://oauth2.googleapis.com/token"
    static let summary = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.8,"resetTime":"2027-01-01T00:00:00Z"}]}]}"#
    static let tos = #"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"TOS_VIOLATION","metadata":{"appeal_url":"https://support.google.com/appeal"}}]}}"#
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); StubURLProtocol.uninstall() }
        var vault: Data?
        let store = AccountCredentialStore(readVaultData: { vault }, writeVaultData: { vault = $0 })
        func credential(_ id: String, extra: [String: Any] = [:]) throws -> AccountCredential {
            let url = root.appendingPathComponent(id + ".json")
            var json: [String: Any] = ["type":"antigravity", "access_token":"access-" + id, "refresh_token":"refresh-" + id,
                                      "email":id + "@example.invalid", "expired":"2099-01-01T00:00:00Z"]
            json.merge(extra) { _, new in new }
            try JSONSerialization.data(withJSONObject: json).write(to: url)
            return AccountCredential(id: id, providerId: "antigravity", authMethod: .authFile, credential: url.path)
        }
        for i in 0..<6 { try store.saveCredential(credential("c\(i)")) }
        try store.saveCredential(credential("suspended", extra: ["disabled":true,"tos_suspended":true]))
        try store.saveCredential(credential("proxy", extra: ["proxy_url":"socks5://127.0.0.1:1080"]))
        let calls = Calls(), engine = ProviderEngine(credentialStore: store)
        let fake = PollProvider(calls: calls)
        let results = await engine.fetchCredentialBackedResults(for: fake)
        let starts = await calls.starts
        try check(results.count == 8 && starts.count == 7, "seven eligible + one suspended result")
        try check(!starts.contains { $0.0 == "suspended" }, "suspended sends zero calls")
        let overlap = await calls.overlap
        try check(!overlap, "no overlapping account fetches")
        for pair in zip(starts, starts.dropFirst()) {
            try check(pair.1.1.timeIntervalSince(pair.0.1) >= 0.8, "minimum800ms account spacing")
        }
        print("Observed randomized order:", starts.map(\.0).joined(separator: ","))
        _ = await engine.fetchCredentialBackedResults(for: fake, useRecentResults: true)
        let afterRecent = await calls.starts.count
        try check(afterRecent == 7, "automatic recent-success guard sends zero extra calls")
        let cancelled = Task { await engine.fetchCredentialBackedResults(for: fake) }
        cancelled.cancel()
        _ = await cancelled.value
        let afterCancel = await calls.starts.count
        try check(afterCancel == 7, "cancelled batch sends zero calls")
        let socks = try AntigravityProvider.proxyConfiguration(proxyURL: "socks5://127.0.0.1:1080")
        try check(socks?.connectionProxyDictionary?["SOCKSProxy"] as? String == "127.0.0.1", "SOCKS proxy is attached")
        for scheme in ["http", "https"] {
            let config = try AntigravityProvider.proxyConfiguration(proxyURL: "\(scheme)://127.0.0.1:8080")
            try check(config?.connectionProxyDictionary?["HTTPSPort"] as? Int == 8080, "CONNECT proxy attached")
        }
        do { _ = try AntigravityProvider.proxyConfiguration(proxyURL: "ftp://proxy.invalid"); throw NSError(domain:"unsafe direct fallback",code:1) }
        catch let error as ProviderError { try check(error.code == "invalid_proxy", "invalid proxy fails closed") }
        StubURLProtocol.install(hosts: ["googleapis.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com"])
        let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
        let provider = AntigravityProvider(homeDirectory: root.path, localQuotaReader: absentReader)

        // Direct fetchUsage(with:) when local IDE is absent fails closed with local_only_unavailable and 0 Google HTTPS calls
        let noIDE = try credential("noIDE")
        do {
            _ = try await provider.fetchUsage(with: noIDE)
            throw NSError(domain: "Expected local_only_unavailable when local IDE absent", code: 1)
        } catch let error as ProviderError {
            try check(error.code == "local_only_unavailable", "direct Antigravity fetch fails closed locally without remote Google HTTPS fallback")
        }
        try check(StubURLProtocol.requests.isEmpty, "absent IDE sends zero Google HTTPS requests")

        // Pre-suspended tos_violation credential throws tos_violation with 0 HTTPS calls and preserves markers on disk
        let suspAuth = try credential("tos", extra: [
            "disabled": true,
            "tos_suspended": true,
            "appeal_url": "https://support.google.com/appeal"
        ])
        do {
            _ = try await provider.fetchUsage(with: suspAuth)
            throw NSError(domain: "Expected tos_violation on pre-suspended file", code: 1)
        } catch let error as ProviderError {
            try check(error.code == "tos_violation", "pre-suspended Antigravity file surfaces terminal tos_violation locally")
        }
        try check(StubURLProtocol.requests.isEmpty, "pre-suspended Antigravity file sends zero HTTPS calls")

        // AntigravityAccountProtection.suspend CAS guard: stale expectedData never suspends a replaced session; matching expectedData persists suspension cleanly
        let toSuspend = try credential("suspendCAS")
        let suspendData = try Data(contentsOf: URL(fileURLWithPath: toSuspend.credential))
        try AntigravityAccountProtection.suspend(URL(fileURLWithPath: toSuspend.credential), error: ProviderError("tos_violation", "TOS", metadata: ["appeal_url": "https://support.google.com/appeal"]), expectedData: suspendData)
        let persistedSusp = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: toSuspend.credential))) as! [String: Any]
        try check(persistedSusp["disabled"] as? Bool == true && persistedSusp["tos_suspended"] as? Bool == true, "TOS persisted disabled")
        try check(persistedSusp["appeal_url"] as? String == "https://support.google.com/appeal", "appeal preserved")

        let replaced = try credential("replacement")
        let old = try Data(contentsOf: URL(fileURLWithPath: replaced.credential))
        var new = try JSONSerialization.jsonObject(with: old) as! [String: Any]; new["access_token"] = "new-session"
        try JSONSerialization.data(withJSONObject: new).write(to: URL(fileURLWithPath: replaced.credential))
        try AntigravityAccountProtection.suspend(URL(fileURLWithPath: replaced.credential), error: ProviderError("tos_violation", "TOS"), expectedData: old)
        let untouched = try Data(contentsOf: URL(fileURLWithPath: replaced.credential))
        try check(AntigravityAccountProtection.suspension(in: untouched) == nil, "stale TOS does not disable a new session")

        // Cold HTTP cache + persisted v2 random_trickle config both fail closed to .localOnly with 0 Google HTTPS calls
        StubURLProtocol.install(hosts: ["googleapis.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let cacheRoot = root.appendingPathComponent("cache-home")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let one = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try one.saveCredential(credential("cached"))
        let localOnlyEngine = ProviderEngine(
            credentialStore: one,
            providersOverride: [AntigravityProvider(homeDirectory: cacheRoot.path, localQuotaReader: absentReader)]
        )
        let loneCold = await localOnlyEngine.cachedDashboard(ids: ["antigravity"])
        try check(loneCold.providers.first?.summary?.errorCode == "unavailable", "cold AGY cache returns terminal unavailable in localOnly")
        try await Task.sleep(for: .milliseconds(100))
        _ = await localOnlyEngine.cachedDashboard(ids: ["antigravity"])
        try check(StubURLProtocol.requests.isEmpty, "SINGLE_DORMANT: default localOnly sends zero Google HTTPS requests on cold dashboard reads")

        // Even if a persisted pool-protection.json has v2 random_trickle, ProviderEngine fails closed with 0 Google HTTPS requests
        let protectionDir = cacheRoot.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI", isDirectory: true)
        try FileManager.default.createDirectory(at: protectionDir, withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"pools":["gemini"],"polling_mode":"random_trickle","polling_mode_version":2}"#.utf8)
            .write(to: protectionDir.appendingPathComponent("pool-protection.json"), options: .atomic)
        try check(AntigravityPoolProtectionSettings.pollingMode(homeDirectory: cacheRoot.path) == .localOnly,
                  "persisted v2 random_trickle config fails closed to .localOnly")
        let forcedEngine = ProviderEngine(
            credentialStore: one,
            providersOverride: [AntigravityProvider(homeDirectory: cacheRoot.path, localQuotaReader: absentReader)]
        )
        _ = await forcedEngine.cachedDashboard(ids: ["antigravity"])
        _ = await forcedEngine.fetchAll(ids: ["antigravity"], backgroundAutomatic: true)
        _ = await forcedEngine.fetchAll(ids: ["antigravity"], backgroundAutomatic: false)
        _ = await forcedEngine.fetchMultiAccountProvider(id: "antigravity")
        _ = await forcedEngine.fetchForCredential(providerId: "antigravity", credentialId: "cached")
        try check(StubURLProtocol.requests.isEmpty, "all dashboard/manual/single-card Antigravity paths emit 0 Google HTTPS calls even with v2 random_trickle on disk")
        // Cancelling one waiter on a shared credential fetch must not abort peer waiters.
        let gate = Calls()
        struct SlowPollProvider: CredentialAcceptingProvider {
            let id = "antigravity", displayName = "Fixture", description = "Fixture"
            var supportedAuthMethods: [AuthMethod] { [.authFile] }
            let calls: Calls
            func fetchUsage() async throws -> ProviderUsage { fatalError("credential required") }
            func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
                await calls.enter(credential.id)
                try await Task.sleep(for: .milliseconds(250))
                await calls.leave()
                return ProviderUsage(provider: id, label: displayName, accountId: credential.id)
            }
        }
        let sharedStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try sharedStore.saveCredential(credential("sharedWait"))
        let sharedEngine = ProviderEngine(credentialStore: sharedStore)
        let slowFake = SlowPollProvider(calls: gate)
        let waiterA = Task { await sharedEngine.fetchCredentialBackedResults(for: slowFake) }
        for _ in 0..<50 {
            if await !gate.starts.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let waiterB = Task { await sharedEngine.fetchCredentialBackedResults(for: slowFake) }
        try await Task.sleep(for: .milliseconds(30))
        waiterA.cancel()
        let resultA = await waiterA.value
        let resultB = await waiterB.value
        try check(resultA.first?.ok == false && resultB.first?.ok == true, "cancelling one waiter preserves shared single-flight result for peers")
        // A fresh call right after a cancelled sole waiter must never inherit its aborted fallback.
        let cancelledSole = Task { await sharedEngine.fetchCredentialBackedResults(for: slowFake) }
        cancelledSole.cancel()
        let freshAfterCancel = Task { await sharedEngine.fetchCredentialBackedResults(for: slowFake) }
        _ = await cancelledSole.value
        let freshResult = await freshAfterCancel.value
        try check(freshResult.first?.ok == true, "new caller after cancelled sole waiter runs fresh flight")
        // Calibrated UA+CL strictly paired to verified 2.32.1 bundle, never mismatched to other versions.
        try check(AntigravityClientIdentity.userAgent(forVersion: "2.32.1", arch: "arm64") == "antigravity/hub/2.32.1 (aidev_client; os_type=darwin; arch=arm64; cl=1021296516)", "verified 2.32.1 UA includes matching CL")
        try check(AntigravityClientIdentity.userAgent(forVersion: "2.99.0", arch: "arm64") == "antigravity/hub/2.99.0 (aidev_client; os_type=darwin; arch=arm64)", "unverified version omits CL cleanly")

        // Local 127.0.0.1 RPC parser + >64KB pipe drain + fail-closed blank/nil email check.
        let largeOutput = AntigravityLocalQuotaReader.runProcessCapture(
            executable: "/bin/sh",
            arguments: ["-c", "head -c 262144 /dev/zero | tr '\\0' 'x'"],
            timeoutSeconds: 2.0
        )
        try check(largeOutput?.count == 262144, "process capture drains >64KB pipe output without deadlock")
        let parsedProcs = AntigravityLocalQuotaReader.parseServerProcesses(fromPSOutput: "123 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token tok-abc --app_data_dir antigravity\n")
        let parsedPorts = AntigravityLocalQuotaReader.parseListeningPorts(fromLsofOutput: "p123\nf4\nn127.0.0.1:60432\nn127.0.0.1:60431\n")
        try check(parsedProcs == [.init(pid: 123, csrfToken: "tok-abc")] && parsedPorts == [60431, 60432], "loopback server & port discovery parses process args and listening sockets")

        let switchHome = root.appendingPathComponent("switch-safe-home")
        try FileManager.default.createDirectory(at: switchHome, withIntermediateDirectories: true)
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let activeCred = try credential("activeLocal")
        let dormantCred = try credential("dormantRemote")
        let dormantSuspended = try credential("dormantTOS", extra: ["disabled": true, "tos_suspended": true])
        let switchStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try switchStore.saveCredential(activeCred)
        try switchStore.saveCredential(dormantCred)
        try switchStore.saveCredential(dormantSuspended)
        let fakeReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60432] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "activeLocal@example.invalid", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                return ["response": ["groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.75, "resetTime": "2027-01-01T00:00:00Z"]]]]]]
            }
        )
        let nilEmailRPC = await fakeReader.fetchMatchingQuota(expectedEmail: nil)
        let blankEmailRPC = await fakeReader.fetchMatchingQuota(expectedEmail: "   ")
        try check(nilEmailRPC == nil && blankEmailRPC == nil, "loopback RPC fails closed when credential lacks email")

        let switchProvider = AntigravityProvider(homeDirectory: switchHome.path, localQuotaReader: fakeReader)
        let switchEngine = ProviderEngine(credentialStore: switchStore)
        let bgResults = await switchEngine.fetchAllResults(for: switchProvider, useRecentResults: true, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.isEmpty, "Switch-Safe background poll + local RPC sends zero Google HTTPS requests")
        try check(bgResults.contains(where: { $0.id == "antigravity:cred:activeLocal" && $0.ok && $0.usage?.extra["transport"]?.value as? String == "loopback_rpc" }), "Switch-Safe polls active local RPC account cleanly")
        try check(bgResults.contains(where: { $0.id == "antigravity:cred:dormantTOS" && $0.summary?.errorCode == "tos_violation" }), "Switch-Safe preserves dormant local tos_violation even on cold start")
        try check(!bgResults.contains(where: { $0.id == "antigravity:cred:dormantRemote" }), "Switch-Safe skips cold dormant HTTPS account")

        // Re-verify mid-flight credential re-auth via local TokenRecordingProvider before CodexCacheProbe
        let reauthFile = root.appendingPathComponent("reauth.json")
        try JSONSerialization.data(withJSONObject: ["email": "reauth@example.invalid", "access_token": "v1-token"]).write(to: reauthFile)
        let reauthStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try reauthStore.saveCredential(AccountCredential(id: "reauth", providerId: "antigravity", authMethod: .authFile, credential: reauthFile.path))
        actor TokenRecordingProvider: CredentialAcceptingProvider {
            let id = "antigravity", displayName = "Fixture", description = "Fixture"
            nonisolated var supportedAuthMethods: [AuthMethod] { [.authFile] }
            var observedTokens: [String] = []
            func fetchUsage() async throws -> ProviderUsage { fatalError() }
            func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
                let raw = (try? Data(contentsOf: URL(fileURLWithPath: credential.credential))) ?? Data()
                let tok = ((try? JSONSerialization.jsonObject(with: raw)) as? [String: Any])?["access_token"] as? String ?? ""
                observedTokens.append(tok)
                if tok == "v1-token" { try await Task.sleep(for: .milliseconds(250)) }
                var usage = ProviderUsage(provider: id, label: displayName, accountId: tok)
                usage.accountEmail = "reauth@example.invalid"
                return usage
            }
        }
        let reauthProvider = TokenRecordingProvider()
        let reauthEngine = ProviderEngine(credentialStore: reauthStore)
        let poll1Task = Task { await reauthEngine.fetchCredentialBackedResults(for: reauthProvider) }
        for _ in 0..<50 {
            if await !reauthProvider.observedTokens.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try JSONSerialization.data(withJSONObject: ["email": "reauth@example.invalid", "access_token": "v2-token"]).write(to: reauthFile)
        let poll2Task = Task { await reauthEngine.fetchCredentialBackedResults(for: reauthProvider) }
        let poll1Result = await poll1Task.value
        let poll2Result = await poll2Task.value
        let recorded = await reauthProvider.observedTokens
        try check(recorded == ["v1-token", "v2-token"], "re-auth mid-flight runs poll 2 sequentially with updated credential")
        try check(poll1Result.first?.usage?.usageAccountId == "v1-token" && poll2Result.first?.usage?.usageAccountId == "v2-token", "poll 2 returns fresh re-auth result instead of joining stale poll 1 flight")

        // Even if setPollingMode(.randomTrickle) is called, ProviderEngine still stays strictly localOnly with 0 Google HTTPS traffic.
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: switchHome.path)
        let trickleBlocked = await switchEngine.fetchAllResults(for: switchProvider, useRecentResults: true, backgroundAutomatic: true)
        try check(trickleBlocked.contains(where: { $0.id == "antigravity:cred:activeLocal" && $0.ok })
                  && trickleBlocked.contains(where: { $0.id == "antigravity:cred:dormantTOS" })
                  && !trickleBlocked.contains(where: { $0.id == "antigravity:cred:dormantRemote" })
                  && StubURLProtocol.requests.isEmpty, "setPollingMode(.randomTrickle) sends zero Google HTTPS requests for dormant accounts")

        // [P1] SWITCH_SAFE_RACE: active identity changes A -> B mid-flight must fail closed in localOnly with 0 Google HTTPS calls.
        final class StatusSequence: @unchecked Sendable {
            private let lock = NSLock()
            private var n = 0
            func next() -> String { lock.lock(); defer { lock.unlock() }; n += 1; return n == 1 ? "raceA@example.invalid" : "raceB@example.invalid" }
        }
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let raceStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try raceStore.saveCredential(credential("raceA"))
        try raceStore.saveCredential(credential("raceB"))
        let seq = StatusSequence()
        let raceReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60433] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") { return ["userStatus": ["email": seq.next()]] }
                return nil
            }
        )
        let raceHome = root.appendingPathComponent("race-home")
        try FileManager.default.createDirectory(at: raceHome, withIntermediateDirectories: true)
        let raceProvider = AntigravityProvider(homeDirectory: raceHome.path, localQuotaReader: raceReader)
        let raceResults = await ProviderEngine(credentialStore: raceStore).fetchAllResults(for: raceProvider, useRecentResults: true, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.isEmpty && !raceResults.contains(where: { $0.summary?.errorCode == "local_only_unavailable" }),
                  "SWITCH_SAFE_RACE: mid-flight IDE account switch A->B sends zero Google HTTPS fallback requests")

        // [P2] CodexCacheProbe: native Codex `tokens` overwrite on disk during in-flight old poll must never poison next cached poll.
        actor CodexGate {
            var calls: [String] = []
            var release: CheckedContinuation<Void, Never>?
            func enter(_ token: String) async {
                calls.append(token)
                if token == "old" { await withCheckedContinuation { release = $0 } }
            }
            func open() { release?.resume(); release = nil }
        }
        struct ProbeCodexProvider: CredentialAcceptingProvider {
            let id = "codex", displayName = "Fixture", description = "Fixture"
            var supportedAuthMethods: [AuthMethod] { [.authFile] }
            let gate: CodexGate
            func fetchUsage() async throws -> ProviderUsage { fatalError() }
            func fetchUsage(with credential: AccountCredential) async throws -> ProviderUsage {
                let json = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: credential.credential))) as! [String: Any]
                let tok = (json["tokens"] as? [String: Any])?["access_token"] as? String ?? ""
                await gate.enter(tok)
                return ProviderUsage(provider: id, label: tok, accountId: "same-account")
            }
        }
        let codexFile = root.appendingPathComponent("codex-auth.json")
        try Data(#"{"tokens":{"access_token":"old","refresh_token":"old-rt","account_id":"same-account"}}"#.utf8).write(to: codexFile)
        let codexStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try codexStore.saveCredential(.init(id: "same-id", providerId: "codex", authMethod: .authFile, credential: codexFile.path))
        let codexGate = CodexGate()
        let codexProbe = ProbeCodexProvider(gate: codexGate)
        let codexEngine = ProviderEngine(credentialStore: codexStore)
        let oldCodexTask = Task { await codexEngine.fetchCredentialBackedResults(for: codexProbe) }
        while await codexGate.calls.isEmpty { await Task.yield() }
        try Data(#"{"tokens":{"access_token":"fresh","refresh_token":"fresh-rt","account_id":"same-account"}}"#.utf8).write(to: codexFile)
        try codexStore.saveCredential(.init(id: "same-id", providerId: "codex", authMethod: .authFile, credential: codexFile.path))
        await codexGate.open()
        let oldCodexResult = await oldCodexTask.value
        let freshCodexResult = await codexEngine.fetchCredentialBackedResults(for: codexProbe, useRecentResults: true)
        let codexCalls = await codexGate.calls
        try check(codexCalls == ["old", "fresh"] && oldCodexResult.first?.usage?.label == "old" && freshCodexResult.first?.usage?.label == "fresh",
                  "CodexCacheProbe: external native tokens replacement forces fresh fetch")

        // Policy compliance: persisted v2 random_trickle across 5 dormant credentials emits 0 Google HTTPS across all refresh paths.
        final class FakeClock: @unchecked Sendable {
            private let lock = NSLock()
            private var current = Date(timeIntervalSince1970: 1_700_000_000)
            func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
            func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
        }
        StubURLProtocol.install(hosts: ["googleapis.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let trickleHome = root.appendingPathComponent("trickle-home")
        try FileManager.default.createDirectory(at: trickleHome, withIntermediateDirectories: true)
        let v2PoolDir = trickleHome.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI", isDirectory: true)
        try FileManager.default.createDirectory(at: v2PoolDir, withIntermediateDirectories: true)
        try Data(#"{"enabled":true,"pools":["gemini"],"polling_mode":"random_trickle","polling_mode_version":2}"#.utf8)
            .write(to: v2PoolDir.appendingPathComponent("pool-protection.json"), options: .atomic)
        let trickleStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        for idx in 0..<5 { try trickleStore.saveCredential(credential("t\(idx)")) }
        let clock = FakeClock()
        let trickleProvider = AntigravityProvider(homeDirectory: trickleHome.path, localQuotaReader: absentReader)
        let trickleEngine = ProviderEngine(credentialStore: trickleStore, providersOverride: [trickleProvider], now: { clock.now() })
        let trickleBg = await trickleEngine.fetchAllResults(for: trickleProvider, useRecentResults: false, backgroundAutomatic: true)
        let trickleManual = await trickleEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        let trickleSingle = await trickleEngine.fetchForCredential(providerId: "antigravity", credentialId: "t0")
        try check(trickleBg.isEmpty && trickleManual.isEmpty && trickleSingle == nil && StubURLProtocol.requests.isEmpty,
                  "[§28] 5 dormant credentials + v2 random_trickle on disk emit 0 Google HTTPS calls across auto, manual pool, and single-card fetch")

        // [R3 Finding 2] SingleFlight commits 90s cache before waking callers using local IDE RPC (0 Google HTTPS calls).
        actor RPCCounter {
            var count = 0
            func bump() { count += 1 }
        }
        let rpcCounter = RPCCounter()
        let sfCred = try credential("sfLocal")
        let sfStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try sfStore.saveCredential(sfCred)
        let sfReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf-sf")] },
            listPorts: { _ in [60434] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    await rpcCounter.bump()
                    return ["userStatus": ["email": "sfLocal@example.invalid", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                if method.hasSuffix("RetrieveUserQuotaSummary") {
                    return ["groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.85, "resetTime": "2027-01-01T00:00:00Z"]]]]]
                }
                return nil
            }
        )
        let sfHome = root.appendingPathComponent("sf-home")
        try FileManager.default.createDirectory(at: sfHome, withIntermediateDirectories: true)
        let sfProvider = AntigravityProvider(homeDirectory: sfHome.path, localQuotaReader: sfReader)
        let sfEngine = ProviderEngine(credentialStore: sfStore, providersOverride: [sfProvider], now: { clock.now() })
        let directSF = await sfEngine.fetchForCredential(providerId: "antigravity", credentialId: sfCred.id)
        let rpcCountAfterDirect = await rpcCounter.count
        let cachedSF = await sfEngine.fetchAllResults(for: sfProvider, useRecentResults: true, backgroundAutomatic: false)
        let rpcCountAfterCached = await rpcCounter.count
        try check(directSF?.ok == true
                    && rpcCountAfterDirect == 2
                    && cachedSF.first?.ok == true
                    && rpcCountAfterCached == rpcCountAfterDirect
                    && StubURLProtocol.requests.isEmpty,
                  "R3-F2: SingleFlight pre/post-verifies local identity and commits 90s local cache with 0 Google HTTPS calls")

        // [R3 Finding 5] CredentialWriteRecorder resolves /private symlinks consistently.
        let recURL = URL(fileURLWithPath: root.path).appendingPathComponent("sym-write.json")
        try Data("{}".utf8).write(to: recURL)
        let resolvedURL = recURL.resolvingSymlinksInPath()
        let rec = CredentialWriteRecorder()
        let payload = Data(#"{"access_token":"sym-ok"}"#.utf8)
        rec.record(url: resolvedURL, data: payload)
        try check(rec.data(for: recURL.path) == payload, "R3-F5 CredentialWriteRecorder normalizes symlinks across /var and /private/var")

        // [R4 Finding 2] Concurrent refresh after switching active IDE locally reads new active account and preserves old cached card with 0 Google HTTPS.
        let concHome = root.appendingPathComponent("conc-home")
        try FileManager.default.createDirectory(at: concHome, withIntermediateDirectories: true)
        let concA = try credential("concA")
        let concB = try credential("concB")
        let concStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try concStore.saveCredential(concA)
        try concStore.saveCredential(concB)
        final class SwitchedEmailBox: @unchecked Sendable {
            private let lock = NSLock()
            private var value = "concA@example.invalid"
            func get() -> String { lock.lock(); defer { lock.unlock() }; return value }
            func set(_ next: String) { lock.lock(); value = next; lock.unlock() }
        }
        let concEmail = SwitchedEmailBox()
        let concReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60435] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": concEmail.get(), "userTier": ["id": "pro", "name": "Pro"]]]
                }
                return ["response": ["groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9, "resetTime": "2027-01-01T00:00:00Z"]]]]]]
            }
        )
        let concClock = FakeClock()
        let concProvider = AntigravityProvider(homeDirectory: concHome.path, localQuotaReader: concReader)
        let concEngine = ProviderEngine(credentialStore: concStore, providersOverride: [concProvider], now: { concClock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com"])
        let concDash1 = await concEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        concEmail.set("concB@example.invalid")
        concClock.advance(by: 5)
        let concDash2 = await concEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(concDash1.providers.contains(where: { $0.id == "antigravity:cred:concA" && $0.ok })
                    && concDash2.providers.contains(where: { $0.id == "antigravity:cred:concA" && $0.ok })
                    && concDash2.providers.contains(where: { $0.id == "antigravity:cred:concB" && $0.ok })
                    && StubURLProtocol.requests.isEmpty,
                  "[R4-F2 + §28] IDE switch concA -> concB preserves concA snapshot and reads concB locally with 0 Google HTTPS calls")

        print("Anti-ban polling regression: PASS (\(checks) checks)")
    }
}
