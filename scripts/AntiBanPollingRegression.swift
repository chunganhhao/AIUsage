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
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let provider = AntigravityProvider(homeDirectory: root.path)
        let a = try credential("tos")
        let cpaDir = root.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
        try FileManager.default.createDirectory(at:cpaDir,withIntermediateDirectories:true)
        var owned = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:a.credential))) as! [String:Any]
        owned["aiusage_credential_id"] = a.id
        owned["proxy_url"] = "http://127.0.0.1:8080"
        let ownedURL = cpaDir.appendingPathComponent("owned.json")
        try JSONSerialization.data(withJSONObject:owned).write(to:ownedURL)
        owned["aiusage_credential_id"] = "not-owned"
        let unrelatedURL = cpaDir.appendingPathComponent("unrelated.json")
        try JSONSerialization.data(withJSONObject:owned).write(to:unrelatedURL)
        StubURLProtocol.respond(load, status:403, body:tos)
        do { _ = try await provider.fetchUsage(with: a); throw NSError(domain:"TOS must fail",code:1) }
        catch let error as ProviderError { try check(error.code == "tos_violation", "terminal TOS code") }
        try check(StubURLProtocol.requests.count == 1, "load TOS stops after one request")
        let paused = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath:a.credential))) as! [String:Any]
        try check(paused["disabled"] as? Bool == true && paused["tos_suspended"] as? Bool == true, "TOS persisted disabled")
        try check(paused["appeal_url"] as? String == "https://support.google.com/appeal", "appeal preserved")
        let copied = try JSONSerialization.jsonObject(with:Data(contentsOf:ownedURL)) as! [String:Any]
        try check(copied["disabled"] as? Bool == true && copied["proxy_url"] as? String == "http://127.0.0.1:8080", "owned CPA copy suspended without destroying proxy")
        try check(AntigravityAccountProtection.suspension(in:Data(contentsOf:unrelatedURL)) == nil, "same email non-owned CPA file untouched")
        do { _ = try await provider.fetchUsage(with:a) } catch { }
        try check(StubURLProtocol.requests.count == 1, "persistent suspension sends zero calls on next poll")
        StubURLProtocol.install(hosts:["googleapis.com"])
        StubURLProtocol.respond(load, body:#"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#)
        do { _ = try await provider.fetchUsage(with: credential("unsupported")); throw NSError(domain:"unsupported must fail",code:1) }
        catch let error as ProviderError { try check(error.code == "unsupported_client", "unsupported client surfaced") }
        try check(StubURLProtocol.requests.count == 1, "unsupported client no quota fallback")
        StubURLProtocol.install(hosts:["googleapis.com"])
        StubURLProtocol.respond(load, body:"{}")
        StubURLProtocol.respond(quota, status:403, body:tos)
        do { _ = try await provider.fetchUsage(with: credential("quotaTOS")) } catch { }
        try check(StubURLProtocol.requestedURLs == [load,quota], "quota TOS no prod/legacy retry")
        StubURLProtocol.install(hosts:["googleapis.com"])
        StubURLProtocol.respond(load) { request in
            (request.headers["Authorization"] == "Bearer refreshed" ? 200 : 401, "{}")
        }
        StubURLProtocol.respond(refresh, body:#"{"access_token":"refreshed","expires_in":3600}"#)
        StubURLProtocol.respond(quota, body:summary)
        _ = try await provider.fetchUsage(with: credential("revoked"))
        try check(StubURLProtocol.requestedURLs == [load,refresh,load,quota], "load401 refreshes exactly once")
        // An already newer source login must not be suspended by the old
        // managed token's response, even when the email and file stay stable.
        StubURLProtocol.install(hosts:["googleapis.com"])
        let oldManaged = try credential("oldManaged")
        let freshSource = root.appendingPathComponent("fresh-source.json")
        let oldJSON = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:oldManaged.credential))) as! [String:Any]
        var newLogin = oldJSON; newLogin["access_token"] = "new-access"; newLogin["refresh_token"] = "new-refresh"
        try JSONSerialization.data(withJSONObject:newLogin).write(to:freshSource)
        let oldWithFreshSource = AccountCredential(id:oldManaged.id,providerId:"antigravity",authMethod:.authFile,
            credential:oldManaged.credential,metadata:["sourcePath":freshSource.path])
        StubURLProtocol.respond(load,status:403,body:tos)
        do { _ = try await provider.fetchUsage(with:oldWithFreshSource) } catch { }
        try check(AntigravityAccountProtection.suspension(in:Data(contentsOf:freshSource)) == nil, "newer source login chain is never disabled by old TOS")
        // A persistence failure must retain the terminal code, never recover
        // tokens from a source copy and send another quota request.
        StubURLProtocol.install(hosts:["googleapis.com"])
        let failureCredential = try credential("persistFailure")
        let failureURL = URL(fileURLWithPath:failureCredential.credential)
        let failureSource = root.appendingPathComponent("persist-source.json")
        try Data(contentsOf:failureURL).write(to:failureSource)
        let withSource = AccountCredential(id:failureCredential.id,providerId:"antigravity",authMethod:.authFile,
            credential:failureURL.path,metadata:["sourcePath":failureSource.path])
        let failures = AccountCredentialStore(readVaultData:{nil},writeVaultData:{_ in})
        try failures.saveCredential(withSource)
        StubURLProtocol.respond(load) { _ in
            try! FileManager.default.removeItem(at:failureURL)
            try! FileManager.default.createDirectory(at:failureURL,withIntermediateDirectories:true)
            return (403,tos)
        }
        let failureResults = await ProviderEngine(credentialStore:failures).fetchCredentialBackedResults(for:provider)
        try check(failureResults.first?.summary?.errorCode == "tos_violation", "persistence failure preserves terminal error")
        try check(StubURLProtocol.requests.count == 1, "persistence failure never enters source retry")
        // A stale TOS result must never disable a replacement credential.
        let replaced = try credential("replacement")
        let old = try Data(contentsOf: URL(fileURLWithPath:replaced.credential))
        var new = try JSONSerialization.jsonObject(with:old) as! [String:Any]; new["access_token"] = "new-session"
        try JSONSerialization.data(withJSONObject:new).write(to:URL(fileURLWithPath:replaced.credential))
        try AntigravityAccountProtection.suspend(URL(fileURLWithPath:replaced.credential), error:ProviderError("tos_violation","TOS"), expectedData:old)
        let untouched = try Data(contentsOf:URL(fileURLWithPath:replaced.credential))
        try check(AntigravityAccountProtection.suspension(in:untouched) == nil, "stale TOS does not disable a new session")
        // Cold HTTP cache in default .localOnly mode sends 0 Google HTTP requests for a lone dormant account (SINGLE_DORMANT).
        StubURLProtocol.install(hosts:["googleapis.com"])
        StubURLProtocol.respond(load, body:"{}")
        StubURLProtocol.respond(quota, body:summary)
        let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
        let cacheRoot = root.appendingPathComponent("cache-home")
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let one = AccountCredentialStore(readVaultData:{nil},writeVaultData:{_ in})
        try one.saveCredential(credential("cached"))
        let localOnlyEngine = ProviderEngine(
            credentialStore: one,
            providersOverride: [AntigravityProvider(homeDirectory: cacheRoot.path, localQuotaReader: absentReader)]
        )
        let loneCold = await localOnlyEngine.cachedDashboard(ids:["antigravity"])
        try check(loneCold.providers.first?.summary?.errorCode == "refresh_pending", "cold cache explicitly pending in localOnly")
        try await Task.sleep(for: .milliseconds(100))
        _ = await localOnlyEngine.cachedDashboard(ids:["antigravity"])
        try check(StubURLProtocol.requests.isEmpty, "SINGLE_DORMANT: default localOnly sends zero background Google HTTPS requests even for 1 dormant account")

        // When opted into .randomTrickle, cold HTTP cache is prompt, scoped, single-flight, and checks the lone dormant account once.
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: cacheRoot.path)
        let cachedEngine = ProviderEngine(
            credentialStore: one,
            providersOverride: [AntigravityProvider(homeDirectory: cacheRoot.path, localQuotaReader: absentReader)]
        )
        let start = Date()
        let cold = await cachedEngine.cachedDashboard(ids:["antigravity"])
        try check(Date().timeIntervalSince(start) < 0.2, "cold HTTP returns immediately")
        try check(cold.providers.first?.summary?.errorCode == "refresh_pending", "cold cache explicitly pending")
        _ = await cachedEngine.cachedDashboard(ids:["antigravity"])
        var warm = cold
        for _ in 0..<100 {
            warm = await cachedEngine.cachedDashboard(ids:["antigravity"])
            if warm.providers.first?.ok == true { break }
            try await Task.sleep(for:.milliseconds(20))
        }
        try check(warm.providers.first?.ok == true, "cache publishes completed poll")
        try check(StubURLProtocol.requests.count == 2, "concurrent cold reads share one poll")
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
        // Source refresh encountering 403 TOS_VIOLATION must surface terminal error + appeal_url.
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let retryStaleURL = root.appendingPathComponent("retry-stale.json")
        try JSONSerialization.data(withJSONObject: ["type": "antigravity", "access_token": "stale-only", "email": "retry@example.invalid", "expired": "2099-01-01T00:00:00Z"]).write(to: retryStaleURL)
        let retrySourceURL = root.appendingPathComponent("retry-source.json")
        try JSONSerialization.data(withJSONObject: ["type": "antigravity", "access_token": "source-tos", "email": "retry@example.invalid", "expired": "2099-01-01T00:00:00Z"]).write(to: retrySourceURL)
        let retryStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try retryStore.saveCredential(AccountCredential(id: "retryTOS", providerId: "antigravity", authMethod: .authFile,
            credential: retryStaleURL.path, metadata: ["sourcePath": retrySourceURL.path]))
        StubURLProtocol.respond(load) { req in
            req.headers["Authorization"] == "Bearer source-tos" ? (403, tos) : (401, "{}")
        }
        let retryResults = await ProviderEngine(credentialStore: retryStore).fetchCredentialBackedResults(for: provider)
        try check(retryResults.first?.summary?.errorCode == "tos_violation", "source-refresh TOS must not be swallowed")
        try check(retryResults.first?.error?.contains("https://support.google.com/appeal") == true, "source-refresh TOS keeps appeal URL")

        // [P2] Mid-flight credential re-auth must not join poll 1's stale flight (runs sequentially with updated content).
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

        // Calibrated UA+CL strictly paired to verified 2.32.1 bundle, never mismatched to other versions.
        try check(AntigravityClientIdentity.userAgent(forVersion: "2.32.1", arch: "arm64") == "antigravity/hub/2.32.1 (aidev_client; os_type=darwin; arch=arm64; cl=1021296516)", "verified 2.32.1 UA includes matching CL")
        try check(AntigravityClientIdentity.userAgent(forVersion: "2.99.0", arch: "arm64") == "antigravity/hub/2.99.0 (aidev_client; os_type=darwin; arch=arm64)", "unverified version omits CL cleanly")

        // Daily loadCodeAssist fallback to prod on 500, omit aicode-consumers placeholder.
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 500, body: "{}")
        StubURLProtocol.respond(prodLoad, status: 200, body: #"{"currentTier":{"id":"free","name":"Free"}}"#)
        StubURLProtocol.respond(quota, status: 200, body: summary)
        let fallbackCred = try credential("fallbackNoProj")
        _ = try await provider.fetchUsage(with: fallbackCred)
        try check(StubURLProtocol.requestedURLs == [load, prodLoad, quota], "daily loadCodeAssist falls back to prod on 500")
        try check(StubURLProtocol.lastRequest(to: quota)?.jsonBody?.keys.contains("project") == false, "quota request omits aicode-consumers placeholder")

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

        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: switchHome.path)
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let optInBg = await switchEngine.fetchAllResults(for: switchProvider, useRecentResults: true, backgroundAutomatic: true)
        try check(optInBg.contains(where: { $0.id == "antigravity:cred:activeLocal" && $0.ok })
                  && optInBg.contains(where: { $0.id == "antigravity:cred:dormantTOS" })
                  && optInBg.contains(where: { $0.id == "antigravity:cred:dormantRemote" && $0.ok })
                  && StubURLProtocol.requests.count == 2, "opting into randomTrickle checks 1 due dormant account via HTTPS")

        // Turning localOnly back on preserves already-cached dormant results without extra Google requests.
        try AntigravityPoolProtectionSettings.setPollingMode(.localOnly, homeDirectory: switchHome.path)
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let preservedBg = await switchEngine.fetchAllResults(for: switchProvider, useRecentResults: false, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.isEmpty && preservedBg.contains(where: { $0.id == "antigravity:cred:dormantRemote" && $0.ok }), "Switch-Safe preserves previously fetched dormant cards with zero Google traffic")

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

        // [P2] EXTERNAL_REPLACEMENT: external access-token-only edit while old TOS is in flight keeps new login unsuspended and forces cache miss.
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let extStale = try credential("extStale", extra: ["refresh_token": "stable-refresh"])
        let extStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try extStore.saveCredential(extStale)
        let extEngine = ProviderEngine(credentialStore: extStore)
        let extProvider = AntigravityProvider(homeDirectory: raceHome.path, localQuotaReader: absentReader)
        StubURLProtocol.respond(load) { _ in
            let url = URL(fileURLWithPath: extStale.credential)
            var updated = try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            updated["access_token"] = "externally-replaced-access"
            try! JSONSerialization.data(withJSONObject: updated).write(to: url, options: .atomic)
            return (403, tos)
        }
        let extFirst = await extEngine.fetchCredentialBackedResults(for: extProvider)
        let extDisk = try Data(contentsOf: URL(fileURLWithPath: extStale.credential))
        try check(AntigravityAccountProtection.suspension(in: extDisk) == nil && extFirst.first?.summary?.errorCode == "tos_violation",
                  "EXTERNAL_REPLACEMENT: stale TOS never suspends externally replaced token")
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 200, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let extSecond = await extEngine.fetchCredentialBackedResults(for: extProvider, useRecentResults: true)
        try check(extSecond.first?.ok == true && StubURLProtocol.requests.count == 2,
                  "EXTERNAL_REPLACEMENT: new external session is not poisoned by old TOS cache")

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

        // Random 1-by-1 trickle anti-burst: 5 dormant accounts never burst together; respects 3m global spacing, 15m cooldown, 30m error backoff, and manual single-pick.
        final class FakeClock: @unchecked Sendable {
            private let lock = NSLock()
            private var current = Date(timeIntervalSince1970: 1_700_000_000)
            func now() -> Date { lock.lock(); defer { lock.unlock() }; return current }
            func advance(by seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
        }
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let trickleHome = root.appendingPathComponent("trickle-home")
        try FileManager.default.createDirectory(at: trickleHome, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: trickleHome.path)
        let trickleStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        for idx in 0..<5 { try trickleStore.saveCredential(credential("t\(idx)")) }
        let clock = FakeClock()
        let trickleProvider = AntigravityProvider(homeDirectory: trickleHome.path, localQuotaReader: absentReader)
        let trickleEngine = ProviderEngine(credentialStore: trickleStore, providersOverride: [trickleProvider], now: { clock.now() })
        var seenBearers: [String] = []
        let tick1 = await trickleEngine.fetchAllResults(for: trickleProvider, useRecentResults: false, backgroundAutomatic: true)
        try check(tick1.count == 1 && StubURLProtocol.requests.count == 2, "randomTrickle checks at most 1 random account on first tick")
        if let firstBearer = StubURLProtocol.requests.first?.headers["Authorization"] { seenBearers.append(firstBearer) }

        clock.advance(by: 60) // < 3m global spacing
        let tickBlocked = await trickleEngine.fetchAllResults(for: trickleProvider, useRecentResults: false, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.count == 2 && tickBlocked.count == 1, "randomTrickle blocks remote call inside 3m global spacing")

        for _ in 0..<4 {
            clock.advance(by: 190) // >= 3m global spacing, < 15m per-account cooldown
            let prev = StubURLProtocol.requests.count
            _ = await trickleEngine.fetchAllResults(for: trickleProvider, useRecentResults: false, backgroundAutomatic: true)
            try check(StubURLProtocol.requests.count - prev == 2, "randomTrickle polls 1 due account per spaced tick")
            if let bearer = StubURLProtocol.requests.dropFirst(prev).first?.headers["Authorization"] {
                seenBearers.append(bearer)
            }
        }
        try check(Set(seenBearers).count == 5, "randomTrickle covers all 5 distinct dormant accounts across 5 spaced ticks without repeats")

        // 429 error backoff (30m > 15m cooldown): single account hits 429, skipped at +20m, eligible at +31m.
        let backoffHome = root.appendingPathComponent("backoff-home")
        try FileManager.default.createDirectory(at: backoffHome, withIntermediateDirectories: true)
        let backoffStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try backoffStore.saveCredential(credential("err0"))
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 429, body: #"{"error":{"code":429,"message":"rate limit"}}"#)
        let backoffClock = FakeClock()
        let backoffProvider = AntigravityProvider(homeDirectory: backoffHome.path, localQuotaReader: absentReader)
        let backoffEngine = ProviderEngine(credentialStore: backoffStore, providersOverride: [backoffProvider], now: { backoffClock.now() })
        let manualClick1 = await backoffEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        try check(manualClick1.first?.summary?.errorCode == "rate_limited" && StubURLProtocol.requests.count == 1, "429 triggers rate_limited")
        backoffClock.advance(by: 20 * 60) // past 15m cooldown, still inside 30m error backoff
        _ = await backoffEngine.fetchMultiAccountProvider(id: "antigravity")
        try check(StubURLProtocol.requests.count == 1, "30m error backoff skips failed account even past 15m cooldown")
        backoffClock.advance(by: 11 * 60) // 31m total
        StubURLProtocol.respond(load, status: 200, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let recovered = await backoffEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        try check(recovered.first?.ok == true && StubURLProtocol.requests.count == 3, "account recovers after 30m error backoff")

        // Manual multi-account Refresh never bursts 3 due accounts in .localOnly mode (checks at most 1 random due account).
        let manualPoolHome = root.appendingPathComponent("manual-pool-home")
        try FileManager.default.createDirectory(at: manualPoolHome, withIntermediateDirectories: true)
        let manualStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        for idx in 0..<3 { try manualStore.saveCredential(credential("m\(idx)")) }
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let manualProvider = AntigravityProvider(homeDirectory: manualPoolHome.path, localQuotaReader: absentReader)
        let manualEngine = ProviderEngine(credentialStore: manualStore, providersOverride: [manualProvider])
        let manualResults = await manualEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        try check(manualResults.count == 1 && StubURLProtocol.requests.count == 2, "manual pool refresh picks at most 1 random dormant account, never bursting 3")

        // [P1] Provider-owned OAuth refresh writing disk tokens must advance stored version hash so 90s guard & Switch-Safe preservation still hit.
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let rotHome = root.appendingPathComponent("rot-home")
        try FileManager.default.createDirectory(at: rotHome, withIntermediateDirectories: true)
        let rotDormant = try credential("rotDormant", extra: ["expired": "2000-01-01T00:00:00Z"])
        let rotPeer = try credential("rotPeer")
        let rotStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try rotStore.saveCredential(rotDormant)
        try rotStore.saveCredential(rotPeer)
        StubURLProtocol.respond(refresh, body: #"{"access_token":"rotated-access","expires_in":3600}"#)
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let rotProvider = AntigravityProvider(homeDirectory: rotHome.path, localQuotaReader: nil)
        let rotEngine = ProviderEngine(credentialStore: rotStore)
        let rotInitial = await rotEngine.fetchAllResults(for: rotProvider, useRecentResults: true, backgroundAutomatic: false)
        try check(rotInitial.count == 2 && rotInitial.allSatisfy(\.ok), "initial manual poll succeeds after OAuth refresh write")
        let rotatedDisk = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: rotDormant.credential))) as! [String: Any]
        try check(rotatedDisk["access_token"] as? String == "rotated-access", "provider persisted rotated access_token to disk")
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let rotRecent = await rotEngine.fetchAllResults(for: rotProvider, useRecentResults: true, backgroundAutomatic: false)
        try check(StubURLProtocol.requests.isEmpty && rotRecent.count == 2, "90s duplicate-poll guard hits after provider OAuth refresh write")
        let rotSwitchSafe = await rotEngine.fetchAllResults(for: rotProvider, useRecentResults: false, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.isEmpty && rotSwitchSafe.contains(where: { $0.id == "antigravity:cred:rotDormant" && $0.ok }), "Switch-Safe preserves dormant card after provider OAuth refresh write")

        // [R3 Finding 1] Stale lastCredentialResults V0 version must not negate V1 429 error backoff.
        let v01Home = root.appendingPathComponent("v01-home")
        try FileManager.default.createDirectory(at: v01Home, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: v01Home.path)
        let v01Cred = try credential("v01Account")
        let v01Store = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try v01Store.saveCredential(v01Cred)
        let v01Clock = FakeClock()
        let v01Provider = AntigravityProvider(homeDirectory: v01Home.path, localQuotaReader: absentReader)
        let v01Engine = ProviderEngine(credentialStore: v01Store, providersOverride: [v01Provider], now: { v01Clock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let step0 = await v01Engine.fetchAllResults(for: v01Provider, useRecentResults: false, backgroundAutomatic: true)
        try check(step0.first?.ok == true && StubURLProtocol.requests.count == 2, "R3-F1 step 0 V0 succeeds")
        var v1JSON = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: v01Cred.credential))) as! [String: Any]
        v1JSON["access_token"] = "v1-new-access"
        try JSONSerialization.data(withJSONObject: v1JSON).write(to: URL(fileURLWithPath: v01Cred.credential), options: .atomic)
        v01Clock.advance(by: 20 * 60)
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 429, body: #"{"error":{"code":429,"message":"rate limit"}}"#)
        let step1 = await v01Engine.fetchAllResults(for: v01Provider, useRecentResults: false, backgroundAutomatic: true)
        try check(step1.first?.summary?.errorCode == "rate_limited" && StubURLProtocol.requests.count == 1, "R3-F1 step 1 V1 hits 429")
        v01Clock.advance(by: 4 * 60) // > 3m global spacing, still inside V1 30m backoff
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 429, body: #"{"error":{"code":429,"message":"rate limit"}}"#)
        let step2 = await v01Engine.fetchAllResults(for: v01Provider, useRecentResults: false, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.isEmpty && step2.isEmpty, "R3-F1 step 2 respects 30m backoff for V1 instead of re-hitting 429 via stale V0")
        v01Clock.advance(by: 27 * 60) // 31m total past V1 429
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let step3 = await v01Engine.fetchAllResults(for: v01Provider, useRecentResults: false, backgroundAutomatic: true)
        try check(step3.first?.ok == true && StubURLProtocol.requests.count == 2, "R3-F1 step 3 V1 recovers cleanly after 30m backoff")

        // [R3 Finding 2] SingleFlight must commit 90s cache before waking callers (no intermittent race miss).
        let sfHome = root.appendingPathComponent("sf-home")
        try FileManager.default.createDirectory(at: sfHome, withIntermediateDirectories: true)
        let sfProvider = AntigravityProvider(homeDirectory: sfHome.path, localQuotaReader: absentReader)
        for iteration in 0..<10 {
            let iterCred = try credential("sfRace\(iteration)")
            let iterStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
            try iterStore.saveCredential(iterCred)
            let iterEngine = ProviderEngine(credentialStore: iterStore, providersOverride: [sfProvider])
            StubURLProtocol.install(hosts: ["googleapis.com"])
            StubURLProtocol.respond(load, body: "{}")
            StubURLProtocol.respond(quota, body: summary)
            let direct = await iterEngine.fetchForCredential(providerId: "antigravity", credentialId: iterCred.id)
            let afterDirect = StubURLProtocol.requests.count
            let cached = await iterEngine.fetchAllResults(for: sfProvider, useRecentResults: true, backgroundAutomatic: false)
            try check(direct?.ok == true && afterDirect == 2 && cached.first?.ok == true && StubURLProtocol.requests.count == afterDirect,
                      "R3-F2 iter \(iteration): SingleFlight commits 90s cache before waking caller")
        }

        // [R3 Finding 3] CredentialFlightKey isolates localOnly:true vs localOnly:false flights.
        actor MixGate {
            var count = 0
            var entered: CheckedContinuation<Void, Never>?
            var release: CheckedContinuation<Void, Never>?
            func waitLocalFirst() async -> String? {
                count += 1
                if count == 1 { return "mix@example.invalid" }
                if count == 2 {
                    entered?.resume(); entered = nil
                    await withCheckedContinuation { release = $0 }
                }
                return "other@example.invalid"
            }
            func awaitProviderEntered() async {
                if count < 2 { await withCheckedContinuation { entered = $0 } }
            }
            func finishLocal() { release?.resume(); release = nil }
        }
        let mixGate = MixGate()
        let mixCred = try credential("mix", extra: ["email": "mix@example.invalid"])
        let mixStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try mixStore.saveCredential(mixCred)
        let mixHome = root.appendingPathComponent("mix-home")
        try FileManager.default.createDirectory(at: mixHome, withIntermediateDirectories: true)
        let mixReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60434] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    if let email = await mixGate.waitLocalFirst() { return ["userStatus": ["email": email]] }
                }
                return nil
            }
        )
        let mixProvider = AntigravityProvider(homeDirectory: mixHome.path, localQuotaReader: mixReader)
        let mixEngine = ProviderEngine(credentialStore: mixStore, providersOverride: [mixProvider])
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let bgLocalTask = Task { await mixEngine.fetchAllResults(for: mixProvider, useRecentResults: false, backgroundAutomatic: true) }
        await mixGate.awaitProviderEntered()
        let manualMix = await mixEngine.fetchForCredential(providerId: "antigravity", credentialId: "mix")
        await mixGate.finishLocal()
        _ = await bgLocalTask.value
        try check(manualMix?.ok == true && StubURLProtocol.requests.count == 2, "R3-F3 concurrent manual refresh uses separate non-localOnly flight instead of inheriting local_only_unavailable")

        // [R3 Finding 5] CredentialWriteRecorder resolves /private symlinks consistently.
        let recURL = URL(fileURLWithPath: root.path).appendingPathComponent("sym-write.json")
        try Data("{}".utf8).write(to: recURL)
        let resolvedURL = recURL.resolvingSymlinksInPath()
        let rec = CredentialWriteRecorder()
        let payload = Data(#"{"access_token":"sym-ok"}"#.utf8)
        rec.record(url: resolvedURL, data: payload)
        try check(rec.data(for: recURL.path) == payload, "R3-F5 CredentialWriteRecorder normalizes symlinks across /var and /private/var")

        // [R4 Finding 2] CONCURRENT_TRICKLE: overlapping background refreshes cannot bypass the 180s global remote gap.
        let concHome = root.appendingPathComponent("conc-home")
        try FileManager.default.createDirectory(at: concHome, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: concHome.path)
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
        let httpEntered = DispatchSemaphore(value: 0)
        let httpRelease = DispatchSemaphore(value: 0)
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load) { _ in
            httpEntered.signal()
            _ = httpRelease.wait(timeout: .now() + 5)
            return (200, "{}")
        }
        StubURLProtocol.respond(quota, body: summary)
        let refresh1 = Task { await concEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true) }
        for _ in 0..<400 {
            if !StubURLProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(StubURLProtocol.requests.count == 1, "R4-F2 first concurrent trickle entered remote HTTP for dormant concB")
        concEmail.set("concB@example.invalid")
        concClock.advance(by: 1.8)
        let refresh2 = await concEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        httpRelease.signal()
        _ = await refresh1.value
        let loadRequests = StubURLProtocol.requestedURLs.filter { $0 == load }
        try check(loadRequests.count == 1 && refresh2.providers.contains(where: { $0.id == "antigravity:cred:concB" && $0.ok }),
                  "R4-F2 CONCURRENT_TRICKLE: second overlapping refresh within 180s skips remote dormant poll while reading new active IDE locally")

        // [R4 Finding 3] UNSUPPORTED_RETRY: unsupported_client stays stopped past 15m/30m until credential version changes or explicit single-card fetch.
        let unsupHome = root.appendingPathComponent("unsup-home")
        try FileManager.default.createDirectory(at: unsupHome, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: unsupHome.path)
        let unsupCred = try credential("unsup")
        let unsupStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try unsupStore.saveCredential(unsupCred)
        let unsupClock = FakeClock()
        let unsupProvider = AntigravityProvider(homeDirectory: unsupHome.path, localQuotaReader: absentReader)
        let unsupEngine = ProviderEngine(credentialStore: unsupStore, providersOverride: [unsupProvider], now: { unsupClock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: #"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#)
        let unsupTick1 = await unsupEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(unsupTick1.providers.first?.summary?.errorCode == "unsupported_client" && StubURLProtocol.requests.count == 1,
                  "R4-F3 initial tick records unsupported_client")
        unsupClock.advance(by: 901) // > 15m cooldown
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let unsupTick2 = await unsupEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.isEmpty && unsupTick2.providers.first?.summary?.errorCode == "unsupported_client",
                  "R4-F3 automatic tick at +901s never retries unsupported_client and preserves card")
        unsupClock.advance(by: 1900) // > 30m more
        let unsupManualPool = await unsupEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        try check(StubURLProtocol.requests.isEmpty && unsupManualPool.first?.summary?.errorCode == "unsupported_client",
                  "R4-F3 manual pool refresh also respects terminal stop until re-auth")
        var unsupEdited = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: unsupCred.credential))) as! [String: Any]
        unsupEdited["access_token"] = "reauthed-unsup"
        try JSONSerialization.data(withJSONObject: unsupEdited).write(to: URL(fileURLWithPath: unsupCred.credential), options: .atomic)
        let unsupReauthed = await unsupEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(unsupReauthed.providers.first?.ok == true && StubURLProtocol.requests.count == 2,
                  "R4-F3 external credential version change clears unsupported_client terminal stop")

        // [R5 Finding 1a] DIRECT_TERMINAL + DIRECT_RECOVERY: single-card fetchForCredential unsupported_client stops automatic & pool retries until explicit recheck or version change.
        let directUnsupHome = root.appendingPathComponent("direct-unsup-home")
        try FileManager.default.createDirectory(at: directUnsupHome, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: directUnsupHome.path)
        let directUnsupCred = try credential("directUnsup")
        let directUnsupStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try directUnsupStore.saveCredential(directUnsupCred)
        let directUnsupClock = FakeClock()
        let directUnsupProvider = AntigravityProvider(homeDirectory: directUnsupHome.path, localQuotaReader: absentReader)
        let directUnsupEngine = ProviderEngine(credentialStore: directUnsupStore, providersOverride: [directUnsupProvider], now: { directUnsupClock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: #"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#)
        let directUnsupRes = await directUnsupEngine.fetchForCredential(providerId: "antigravity", credentialId: "directUnsup")
        try check(directUnsupRes?.summary?.errorCode == "unsupported_client" && StubURLProtocol.requests.count == 1,
                  "R5-F1 direct fetchForCredential records unsupported_client")
        directUnsupClock.advance(by: 901) // > 15m cooldown
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let directUnsupBg = await directUnsupEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        let directUnsupPool = await directUnsupEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        try check(StubURLProtocol.requests.isEmpty
                    && directUnsupBg.providers.first?.summary?.errorCode == "unsupported_client"
                    && directUnsupPool.first?.summary?.errorCode == "unsupported_client",
                  "R5-F1 DIRECT_TERMINAL: automatic and manual pool refreshes skip unsupported_client after direct card failure")
        let directUnsupRecovered = await directUnsupEngine.fetchForCredential(providerId: "antigravity", credentialId: "directUnsup")
        let afterDirectRecoveryCount = StubURLProtocol.requests.count
        let afterRecoveryBg = await directUnsupEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(directUnsupRecovered?.ok == true
                    && afterDirectRecoveryCount == 2
                    && afterRecoveryBg.providers.first?.ok == true
                    && StubURLProtocol.requests.count == afterDirectRecoveryCount,
                  "R5-F1 DIRECT_RECOVERY: explicit single-card recheck recovers and informs subsequent automatic polling without extra HTTP")

        // [R5 Finding 1b] DIRECT_429: single-card fetchForCredential 429 enforces both 180s global spacing across accounts and 30m backoff for that card.
        let direct429Home = root.appendingPathComponent("direct-429-home")
        try FileManager.default.createDirectory(at: direct429Home, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: direct429Home.path)
        let direct429A = try credential("direct429A")
        let direct429B = try credential("direct429B")
        let direct429Store = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try direct429Store.saveCredential(direct429A)
        try direct429Store.saveCredential(direct429B)
        let direct429Clock = FakeClock()
        let direct429Provider = AntigravityProvider(homeDirectory: direct429Home.path, localQuotaReader: absentReader)
        let direct429Engine = ProviderEngine(credentialStore: direct429Store, providersOverride: [direct429Provider], now: { direct429Clock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 429, body: #"{"error":{"code":429,"message":"rate limit"}}"#)
        let direct429Res = await direct429Engine.fetchForCredential(providerId: "antigravity", credentialId: "direct429A")
        try check(direct429Res?.summary?.errorCode == "rate_limited" && StubURLProtocol.requests.count == 1,
                  "R5-F1 direct fetchForCredential hits 429")
        direct429Clock.advance(by: 10) // < 3m global spacing
        _ = await direct429Engine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(StubURLProtocol.requests.count == 1,
                  "R5-F1 DIRECT_429 enforces 180s global spacing after direct card HTTP attempt")

        let directSoloHome = root.appendingPathComponent("direct-429-solo-home")
        try FileManager.default.createDirectory(at: directSoloHome, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: directSoloHome.path)
        let directSolo = try credential("direct429Solo")
        let directSoloStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try directSoloStore.saveCredential(directSolo)
        let directSoloClock = FakeClock()
        let directSoloProvider = AntigravityProvider(homeDirectory: directSoloHome.path, localQuotaReader: absentReader)
        let directSoloEngine = ProviderEngine(credentialStore: directSoloStore, providersOverride: [directSoloProvider], now: { directSoloClock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, status: 429, body: #"{"error":{"code":429,"message":"rate limit"}}"#)
        let solo429 = await directSoloEngine.fetchForCredential(providerId: "antigravity", credentialId: "direct429Solo")
        try check(solo429?.summary?.errorCode == "rate_limited" && StubURLProtocol.requests.count == 1,
                  "R5-F1 solo direct fetchForCredential hits 429")
        directSoloClock.advance(by: 20 * 60) // past 15m cooldown, still inside 30m backoff
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)
        let soloBgBlocked = await directSoloEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        let soloPoolBlocked = await directSoloEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        try check(StubURLProtocol.requests.isEmpty && soloBgBlocked.providers.isEmpty && soloPoolBlocked.isEmpty,
                  "R5-F1 DIRECT_429 skips backed-off credential in automatic and pool refreshes for 30m")
        directSoloClock.advance(by: 11 * 60) // 31m total
        let soloRecovered = await directSoloEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(soloRecovered.providers.first?.ok == true && StubURLProtocol.requests.count == 2,
                  "R5-F1 solo credential recovers automatically after 30m backoff")

        // [R6 Finding 1] QUEUED_BACKGROUND: active single-card remote flight blocks background & pool dormant selection until completion.
        let queuedHome = root.appendingPathComponent("queued-bg-home")
        try FileManager.default.createDirectory(at: queuedHome, withIntermediateDirectories: true)
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: queuedHome.path)
        let queuedA = try credential("queuedA")
        let queuedB = try credential("queuedB")
        let queuedStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try queuedStore.saveCredential(queuedA)
        try queuedStore.saveCredential(queuedB)
        let queuedClock = FakeClock()
        let queuedProvider = AntigravityProvider(homeDirectory: queuedHome.path, localQuotaReader: absentReader)
        let queuedEngine = ProviderEngine(credentialStore: queuedStore, providersOverride: [queuedProvider], now: { queuedClock.now() })
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: #"{"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT"}]}"#)
        let queuedInit = await queuedEngine.fetchForCredential(providerId: "antigravity", credentialId: "queuedA")
        try check(queuedInit?.summary?.errorCode == "unsupported_client", "R6-F1 setup marks queuedA unsupported_client")
        queuedClock.advance(by: 181) // > 180s global spacing so queuedB would otherwise be due
        StubURLProtocol.install(hosts: ["googleapis.com"])
        let queuedRelease = DispatchSemaphore(value: 0)
        StubURLProtocol.respond(load) { request in
            if request.headers["Authorization"] == "Bearer access-queuedA" {
                _ = queuedRelease.wait(timeout: .now() + 5)
                return (429, #"{"error":{"code":429,"message":"rate limit"}}"#)
            }
            return (200, "{}")
        }
        StubURLProtocol.respond(quota, body: summary)
        let directInFlight = Task { await queuedEngine.fetchForCredential(providerId: "antigravity", credentialId: "queuedA") }
        for _ in 0..<400 {
            if !StubURLProtocol.requests.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try check(StubURLProtocol.requests.count == 1, "R6-F1 queuedA entered remote HTTP")
        let bgOverlap = await queuedEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        let poolOverlap = await queuedEngine.fetchMultiAccountProvider(id: "antigravity") ?? []
        let countDuringFlight = StubURLProtocol.requests.count
        queuedRelease.signal()
        let directOverlapResult = await directInFlight.value
        let bgAfter429 = await queuedEngine.fetchAll(ids: ["antigravity"], useRecentResults: false, backgroundAutomatic: true)
        try check(directOverlapResult?.summary?.errorCode == "rate_limited"
                    && countDuringFlight == 1
                    && StubURLProtocol.requests.count == 1
                    && !bgOverlap.providers.contains(where: { $0.id == "antigravity:cred:queuedB" })
                    && !poolOverlap.contains(where: { $0.id == "antigravity:cred:queuedB" })
                    && bgOverlap.providers.first?.summary?.errorCode == "unsupported_client"
                    && poolOverlap.first?.summary?.errorCode == "unsupported_client"
                    && bgAfter429.providers.first?.summary?.errorCode == "unsupported_client",
                  "R6-F1 QUEUED_BACKGROUND: active single-card remote flight prevents queueing dormant B before 429 commits")

        print("Anti-ban polling regression: PASS (\(checks) checks)")
    }
}
