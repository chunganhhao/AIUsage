import Foundation
import Darwin
@testable import QuotaBackend

@main
struct CodexCrossProcessLockRegression {
    static var checks = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ message: String) rethrows {
        checks += 1
        let result = try value()
        precondition(result, message)
    }

    static func auth(iat: Int, refresh: String, oldHeuristic: Bool = false, account: String = "workspace") throws -> Data {
        let claims: [String: Any] = [
            "iat": iat, "exp": iat + 10 * 86400,
            "email": "test@example.invalid",
            "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": "user"]
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).sig"
        return try JSONSerialization.data(withJSONObject: [
            "auth_mode": "chatgpt",
            "last_refresh": ISO8601DateFormatter().string(from: oldHeuristic ? Date().addingTimeInterval(-9 * 86400) : Date()),
            "tokens": ["access_token": token, "refresh_token": refresh, "id_token": token, "account_id": account]
        ])
    }

    static func holdLock(path: String, seconds: Double, replacement: Data? = nil) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-c", """
import base64, fcntl, os, sys, time
with open(sys.argv[1] + '.lock', 'a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    print('ready', flush=True)
    time.sleep(float(sys.argv[2]))
    if len(sys.argv) > 3:
        target = sys.argv[1]
        temp = target + '.rotated'
        with open(temp, 'wb') as out:
            out.write(base64.b64decode(sys.argv[3]))
        os.replace(temp, target)
""", path, String(seconds)] + (replacement.map { [$0.base64EncodedString()] } ?? [])
        let ready = Pipe()
        process.standardOutput = ready
        try process.run()
        let signal = ready.fileHandleForReading.availableData
        check(String(data: signal, encoding: .utf8)?.contains("ready") == true, "child owns actual flock before provider starts")
        return process
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("codex-process-lock-\(UUID().uuidString)")
        let codex = root.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = codex.appendingPathComponent("auth.json")
        let now = Int(Date().timeIntervalSince1970)
        StubURLProtocol.install(hosts: ["auth.openai.com", "chatgpt.com"])
        defer { StubURLProtocol.uninstall() }
        let provider = CodexProvider(homeDirectory: root.path, timeoutSeconds: 3)

        // A separate process rotates RT-0 -> RT-1 while owning the native lock.
        try auth(iat: now - 9 * 86400, refresh: "RT-0", oldHeuristic: true).write(to: file)
        let stale = try provider.loadCredentials(from: file.path)
        let rotated = try auth(iat: now, refresh: "RT-1")
        let child = try holdLock(path: file.path, seconds: 0.8, replacement: rotated)
        let started = Date()
        let adopted = try await provider.performSerializedRefresh(stale, fallbackRefreshToken: "RT-0", persistTo: [file.path])
        child.waitUntilExit()
        check(child.terminationStatus == 0, "rotating process exited successfully")
        check(Date().timeIntervalSince(started) >= 0.7, "provider waited for cross-process lock")
        check(adopted.refreshToken == "RT-1", "provider rereads and adopts rotation inside flock")
        check(StubURLProtocol.requests.isEmpty, "adopted access avoids duplicate OAuth POST")
        try check(try Data(contentsOf: file) == rotated, "rotation remains intact")

        // Both managed copies choose one lock even when callers reverse their order.
        let firstCopy = root.appendingPathComponent("a-managed.json")
        let lastCopy = root.appendingPathComponent("z-managed.json")
        let oldManaged = try auth(iat: now - 9 * 86400, refresh: "RT-0", oldHeuristic: true)
        try oldManaged.write(to: firstCopy)
        try oldManaged.write(to: lastCopy)
        let managed = try provider.loadCredentials(from: lastCopy.path)
        let linkedHolder = try holdLock(path: firstCopy.path, seconds: 0.7, replacement: rotated)
        let linkedStart = Date()
        let linkedAdopted = try await provider.performSerializedRefresh(managed, fallbackRefreshToken: "RT-0", persistTo: [lastCopy.path, firstCopy.path])
        linkedHolder.waitUntilExit()
        check(Date().timeIntervalSince(linkedStart) >= 0.6, "reordered linked copies share one deterministic file lock")
        check(linkedAdopted.refreshToken == "RT-1", "linked copy rotation is reread inside common lock")
        check(StubURLProtocol.requests.isEmpty, "linked adoption does not mint a token")

        // Waiting must remain bounded and cancellation must release our descriptor.
        let blocked = try holdLock(path: file.path, seconds: 0.7)
        let waiting = Task { try await provider.performSerializedRefresh(stale, fallbackRefreshToken: "RT-0", persistTo: [file.path]) }
        try await Task.sleep(nanoseconds: 150_000_000)
        waiting.cancel()
        do { _ = try await waiting.value; preconditionFailure("cancelled lock wait completed") }
        catch is CancellationError { check(true, "lock wait responds to task cancellation") }
        blocked.waitUntilExit()
        let afterCancel = try await provider.performSerializedRefresh(stale, fallbackRefreshToken: "RT-0", persistTo: [file.path])
        check(afterCancel.refreshToken == "RT-1", "cancelled wait does not leave held lock")

        let held = try holdLock(path: file.path, seconds: 0.7)
        let impatient = CodexProvider(homeDirectory: root.path, timeoutSeconds: 0.1)
        do { _ = try await impatient.performSerializedRefresh(stale, fallbackRefreshToken: "RT-0", persistTo: [file.path]); preconditionFailure("lock deadline ignored") }
        catch let error as ProviderError { check(error.code == "refresh_lock_timeout", "contended lock has a finite deadline") }
        held.waitUntilExit()

        // Old local heuristics do not prove server expiry while Desktop owns auth.
        try auth(iat: now - 9 * 86400, refresh: "RT-0", oldHeuristic: true).write(to: file)
        var activeProvider = provider
        activeProvider.desktopIsRunning = { true }
        let active = try activeProvider.loadCredentials(from: file.path)
        check(active.needsRefresh, "fixture really triggers proactive heuristic")
        check(activeProvider.deferProactiveRefresh(creds: active, paths: [file.path]), "active native account defers heuristic refresh")
        var stoppedProvider = provider
        stoppedProvider.desktopIsRunning = { false }
        check(!stoppedProvider.deferProactiveRefresh(creds: active, paths: [file.path]), "stopped Desktop retains normal refresh behavior")
        try auth(iat: now, refresh: "other", account: "other-workspace").write(to: file)
        check(!activeProvider.deferProactiveRefresh(creds: active, paths: [file.path]), "unrelated live account does not defer managed refresh")
        try auth(iat: now - 9 * 86400, refresh: "RT-0", oldHeuristic: true).write(to: file)
        let previousAuthFile = ProcessInfo.processInfo.environment["CODEX_AUTH_FILE"]
        setenv("CODEX_AUTH_FILE", file.path, 1)
        defer {
            if let previousAuthFile { setenv("CODEX_AUTH_FILE", previousAuthFile, 1) }
            else { unsetenv("CODEX_AUTH_FILE") }
        }
        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage", body: "{\"plan_type\":\"plus\",\"rate_limit\":{}}")
        let automaticUsage = try await activeProvider.fetchUsage()
        check(automaticUsage.provider == "codex", "automatic native path fetch succeeds with live access")
        check(StubURLProtocol.requestedURLs == ["https://chatgpt.com/backend-api/wham/usage"], "automatic path tries usage without proactive OAuth")
        StubURLProtocol.install(hosts: ["auth.openai.com", "chatgpt.com"])
        let credential = AccountCredential(providerId: "codex", accountLabel: "test@example.invalid", authMethod: .authFile, credential: file.path)
        var readCount = 0
        let token = try await activeProvider.withCredential(credential) { creds, _ in
            readCount += 1
            return creds.refreshToken
        }
        check(readCount == 1 && token == "RT-0", "active usage reads current token before OAuth")
        check(StubURLProtocol.requests.isEmpty, "successful active usage never posts OAuth")

        // An actual access rejection still enters the protected refresh path.
        let replacement = try auth(iat: now, refresh: "RT-2")
        var rejectedReads = 0
        let refreshed = try await activeProvider.withCredential(credential) { creds, _ in
            rejectedReads += 1
            if rejectedReads == 1 {
                try replacement.write(to: file, options: .atomic)
                throw ProviderError("unauthorized", "stub rejected old access")
            }
            return creds.refreshToken
        }
        check(rejectedReads == 2 && refreshed == "RT-2", "401 recovers the rotated Desktop chain")
        check(StubURLProtocol.requests.isEmpty, "401 adopts newer disk access without duplicate refresh")
        // Desktop ownership must never suppress a needed refresh after a 401.
        try auth(iat: now - 9 * 86400, refresh: "RT-0", oldHeuristic: true).write(to: file)
        let mintedJSON = try JSONSerialization.jsonObject(with: auth(iat: now + 1, refresh: "RT-4")) as! [String: Any]
        let mintedTokens = mintedJSON["tokens"] as! [String: Any]
        let mintedBody = String(data: try JSONSerialization.data(withJSONObject: mintedTokens), encoding: .utf8)!
        StubURLProtocol.respond("https://auth.openai.com/oauth/token", body: mintedBody)
        var expiredReads = 0
        let minted = try await activeProvider.withCredential(credential) { creds, _ in
            expiredReads += 1
            if expiredReads == 1 { throw ProviderError("unauthorized", "stub expired access") }
            return creds.refreshToken
        }
        check(expiredReads == 2 && minted == "RT-4", "rejected live access can refresh even while Desktop runs")
        check(StubURLProtocol.requestedURLs == ["https://auth.openai.com/oauth/token"], "a real 401 causes exactly one protected OAuth POST")
        // Actual native+managed discovery must skip a duplicate BEFORE HTTP.
        StubURLProtocol.install(hosts: ["auth.openai.com", "chatgpt.com"])
        let usageURL = "https://chatgpt.com/backend-api/wham/usage"
        StubURLProtocol.respond(usageURL, body: "{\"plan_type\":\"plus\",\"rate_limit\":{}}")
        let freshData = try auth(iat: now, refresh: "RT-fresh")
        try freshData.write(to: file)
        let managedURL = root.appendingPathComponent("managed.json")
        try freshData.write(to: managedURL)
        let memoryStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        try memoryStore.saveCredential(AccountCredential(id: "managed", providerId: "codex", authMethod: .authFile,
            credential: managedURL.path, metadata: ["accountId": "workspace", "workspaceUserId": "user"]))
        let engine = ProviderEngine(credentialStore: memoryStore)
        let managedResults = await engine.fetchAllResults(for: stoppedProvider)
        check(managedResults.count == 1 && managedResults[0].ok, "native duplicate does not add a ghost failure")
        check(StubURLProtocol.requests.count == 1, "native and managed same identity send one usage HTTP request")
        _ = await engine.fetchAllResults(for: stoppedProvider, useRecentResults: true)
        check(StubURLProtocol.requests.count == 1, "background recency covers automatic native scan too")
        try memoryStore.deleteCredential(AccountCredential(id: "managed", providerId: "codex", authMethod: .authFile, credential: managedURL.path))
        let afterManagedDelete = await engine.fetchAllResults(for: stoppedProvider, useRecentResults: true)
        check(afterManagedDelete.count == 1 && afterManagedDelete[0].ok, "deleting managed credential must not hide native auth under cached empty excluded scan")
        let emptyStore = AccountCredentialStore(readVaultData: { nil }, writeVaultData: { _ in })
        let cancelEngine = ProviderEngine(credentialStore: emptyStore)
        let cancelledNative = Task { await cancelEngine.fetchAllResults(for: stoppedProvider) }
        cancelledNative.cancel()
        _ = await cancelledNative.value
        let recoveredNative = await cancelEngine.fetchAllResults(for: stoppedProvider, useRecentResults: true)
        check(recoveredNative.count == 1 && recoveredNative[0].ok, "cancelled automatic scan must not poison 90s recency cache")
        // Automatic-only CODEX_AUTH_DIR contexts share the same serial lane.
        let directory = root.appendingPathComponent("discovered")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try auth(iat: now, refresh: "RT-A", account: "A").write(to: directory.appendingPathComponent("codex-a.json"))
        try auth(iat: now, refresh: "RT-B", account: "B").write(to: directory.appendingPathComponent("codex-b.json"))
        let previousDirectory = ProcessInfo.processInfo.environment["CODEX_AUTH_DIR"]
        unsetenv("CODEX_AUTH_FILE")
        setenv("CODEX_AUTH_DIR", directory.path, 1)
        defer {
            if let previousDirectory { setenv("CODEX_AUTH_DIR", previousDirectory, 1) }
            else { unsetenv("CODEX_AUTH_DIR") }
        }
        StubURLProtocol.install(hosts: ["auth.openai.com", "chatgpt.com"])
        var timestamps: [Date] = []
        StubURLProtocol.respond(usageURL) { _ in
            timestamps.append(Date())
            return (200, "{\"plan_type\":\"plus\",\"rate_limit\":{}}")
        }
        let discovered = await stoppedProvider.fetchAllAccounts()
        check(discovered.count == 3 && timestamps.count == 3, "three automatic contexts fetch once each")
        for pair in zip(timestamps, timestamps.dropFirst()) {
            check(pair.1.timeIntervalSince(pair.0) >= 0.8, "automatic contexts retain800ms minimum gap")
        }
        print("PASS: \(checks) Codex cross-process lock and active-account deferral regression checks")
    }
}
