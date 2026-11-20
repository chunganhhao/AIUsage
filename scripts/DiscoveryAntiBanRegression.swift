import Foundation
@testable import QuotaBackend

struct ProviderAuthCandidate {
    enum IdentityScope: String { case sharedSource }
    var id = "candidate"
    var providerId = "antigravity"
    var title = "fixture@example.invalid"
    var authMethod: AuthMethod = .authFile
    var shouldCopyFile = true
    var sourcePath: String?
    var credentialValue: String
    var sourceIdentifier = "antigravity-ide:fixture@example.invalid"
    var sessionFingerprint: String? = "fixture@example.invalid"
    var identityScope = IdentityScope.sharedSource
}

enum ProviderRegistry {
    static var injected: AntigravityProvider!
    static func provider(for _: String) -> Any? { injected }
}

// PRODUCTION_MANAGED_IMPORT_STORE

enum GeminiCredentialBridge {
    static func makeNativePayload(from data: Data) throws -> Data { data }
}

enum ProviderAuthManager {
    static var injected: ProviderAuthCandidate!
    static func unmanagedCandidates(for _: String) -> [ProviderAuthCandidate] { [injected] }
    // PRODUCTION_AUTHENTICATE_CANDIDATE
    // PRODUCTION_VALIDATE
    // PRODUCTION_VALIDATE_LOCAL_METADATA
    // PRODUCTION_COPY_IMPORTED_AUTH_FILE
    // PRODUCTION_MANAGED_IMPORT_DIRECTORY
    // PRODUCTION_SANITIZED_FILENAME_STEM
}

struct Settings { var backendMode = "local" }

@MainActor final class ProviderRefreshCoordinator {
    var settings = Settings()
    var discoveryFailureBackoff: [String: Date] = [:]
    var discoveryFailureCooldown: TimeInterval = 300
    var registered = 0
    func discoveryBackoffKey(for candidate: ProviderAuthCandidate) -> String { candidate.id }
    func shouldSuppressAutoManagedCandidate(_ candidate: ProviderAuthCandidate, providerId: String) -> Bool { false }
    func shouldSuppressAutoManagedAccount(providerId: String, usage: ProviderUsage, credential: AccountCredential) -> Bool { false }
    func registerAuthenticatedCredential(_ credential: AccountCredential, usage: ProviderUsage, note: String?, providerDisplayTitle: String) throws { registered += 1 }
    func providerTitleForId(_ id: String) -> String { id }
    // PRODUCTION_SYNC_UNIFIED
}

extension String { var nilIfBlank: String? { isEmpty ? nil : self } }

actor ConcurrentImportGate {
    private var calls = 0
    private var firstStarted = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func handleStatusCall() async -> [String: Any]? {
        calls += 1
        if calls == 1 {
            firstStarted = true
            startedWaiter?.resume()
            startedWaiter = nil
            await withCheckedContinuation { releaseWaiter = $0 }
            return ["userStatus": ["email": "fixture@example.invalid", "userTier": ["id": "pro", "name": "Pro"]]]
        }
        return nil
    }

    func waitForFirstStart() async {
        if !firstStarted {
            await withCheckedContinuation { startedWaiter = $0 }
        }
    }

    func releaseFirst() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@main struct DiscoveryAntiBanRegression {
    @MainActor static func main() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let managedBase = home.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(at: managedBase, withIntermediateDirectories: true)
        ProviderManagedImportStore.managedBase = managedBase
        let managedRoot = try ProviderManagedImportStore.managedImportsRootDirectory()
        defer { try? FileManager.default.removeItem(at: home); StubURLProtocol.uninstall() }

        let source = home.appendingPathComponent("ide-import.json")
        try Data(#"{"email":"fixture@example.invalid","access_token":"fixture","refresh_token":"fixture-refresh","expired":"2099-01-01T00:00:00Z"}"#.utf8).write(to: source)
        ProviderAuthManager.injected = ProviderAuthCandidate(sourcePath: source.path, credentialValue: source.path)

        let load = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
        let quota = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
        let summary = #"{"groups":[{"displayName":"Gemini Models","buckets":[{"bucketId":"gemini-weekly","window":"weekly","remainingFraction":0.8,"resetTime":"2027-01-01T00:00:00Z"}]}]}"#
        StubURLProtocol.install(hosts: ["googleapis.com"])
        StubURLProtocol.respond(load, body: "{}")
        StubURLProtocol.respond(quota, body: summary)

        // 1. Default localOnly with closed IDE sends ZERO Google HTTPS/OAuth during automatic discovery and leaves no backoff poison or stray copies.
        let absent = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
        ProviderRegistry.injected = AntigravityProvider(homeDirectory: home.path, localQuotaReader: absent)
        let coordinator = ProviderRefreshCoordinator()
        await coordinator.syncUnifiedManagedAccounts(for: ["antigravity"])
        let emptyAfterFail = (try? FileManager.default.contentsOfDirectory(atPath: managedRoot.appendingPathComponent("antigravity").path)) ?? []
        precondition(coordinator.registered == 0 && StubURLProtocol.requests.isEmpty && coordinator.discoveryFailureBackoff.isEmpty && emptyAfterFail.isEmpty,
                     "Closed IDE discovery must send 0 Google HTTP requests, leave no stray copied files, and must not set discovery backoff")

        // 2. Even if pollingMode == .randomTrickle, passive automatic discovery stays localOnly (0 Google HTTP) until IDE runs or user connects explicitly.
        try AntigravityPoolProtectionSettings.setPollingMode(.randomTrickle, homeDirectory: home.path)
        await coordinator.syncUnifiedManagedAccounts(for: ["antigravity"])
        precondition(coordinator.registered == 0 && StubURLProtocol.requests.isEmpty,
                     "Passive discovery in randomTrickle also stays localOnly when IDE is closed")

        // 3. When Antigravity IDE is running locally on 127.0.0.1, automatic discovery registers via loopback RPC with STILL 0 Google HTTP requests.
        let liveReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60439] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "fixture@example.invalid", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                return ["response": ["groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9, "resetTime": "2027-01-01T00:00:00Z"]]]]]]
            }
        )
        ProviderRegistry.injected = AntigravityProvider(homeDirectory: home.path, localQuotaReader: liveReader)
        await coordinator.syncUnifiedManagedAccounts(for: ["antigravity"])
        precondition(coordinator.registered == 1 && StubURLProtocol.requests.isEmpty,
                     "Running IDE discovery registers cleanly via 127.0.0.1 RPC with 0 Google HTTP requests")

        // 4. Policy compliance: closed IDE explicit connect refuses remote Google HTTPS fallback, while metadata fallback stays strictly local (0 HTTPS).
        ProviderRegistry.injected = AntigravityProvider(homeDirectory: home.path, localQuotaReader: absent)
        var absentExplicitCode: String?
        do {
            _ = try await ProviderAuthManager.authenticateCandidate(ProviderAuthManager.injected)
        } catch let error as ProviderError {
            absentExplicitCode = error.code
        }
        precondition(absentExplicitCode == "local_only_unavailable" && StubURLProtocol.requests.isEmpty,
                     "Explicit closed-IDE connect fails closed locally without Google HTTPS fallback")
        let localMeta = try await ProviderAuthManager.authenticateCandidate(
            ProviderAuthManager.injected,
            localOnly: true,
            allowLocalMetadataFallback: true
        )
        precondition(localMeta.0.providerId == "antigravity"
                        && (localMeta.1.extra["snapshotState"]?.value as? String) == "pending"
                        && StubURLProtocol.requests.isEmpty,
                     "Local metadata fallback preserves offline pending registration with 0 Google HTTPS calls")

        // 5. [R5 Finding 2] Concurrent same-second imports via production copyImportedAuthFile use distinct UUID files; failed cleanup cannot delete first credential.
        let concBase = home.appendingPathComponent("ConcurrentAppSupport")
        try FileManager.default.createDirectory(at: concBase, withIntermediateDirectories: true)
        ProviderManagedImportStore.managedBase = concBase
        let concManagedRoot = try ProviderManagedImportStore.managedImportsRootDirectory()
        let ns = Calendar.current.component(.nanosecond, from: Date())
        if ns > 500_000_000 {
            try await Task.sleep(for: .nanoseconds(1_050_000_000 - ns))
        }
        let gate = ConcurrentImportGate()
        let concReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60440] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return await gate.handleStatusCall()
                }
                return ["response": ["groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9, "resetTime": "2027-01-01T00:00:00Z"]]]]]]
            }
        )
        ProviderRegistry.injected = AntigravityProvider(homeDirectory: home.path, localQuotaReader: concReader)
        let concCandidate = ProviderAuthManager.injected!
        let firstImport = Task { try await ProviderAuthManager.authenticateCandidate(concCandidate, localOnly: true) }
        await gate.waitForFirstStart()
        let agyDir = concManagedRoot.appendingPathComponent("antigravity")
        let filesBeforeSecond = try FileManager.default.contentsOfDirectory(atPath: agyDir.path)
        precondition(filesBeforeSecond.count == 1, "First import wrote exactly one UUID-suffixed managed file")
        var secondErrorCode: String?
        do {
            _ = try await ProviderAuthManager.authenticateCandidate(concCandidate, localOnly: true)
        } catch let error as ProviderError {
            secondErrorCode = error.code
        }
        let filesAfterSecondFail = try FileManager.default.contentsOfDirectory(atPath: agyDir.path)
        await gate.releaseFirst()
        let (firstCredential, _) = try await firstImport.value
        precondition(secondErrorCode == "local_only_unavailable"
                        && filesAfterSecondFail == filesBeforeSecond
                        && FileManager.default.fileExists(atPath: firstCredential.credential),
                     "R5-F2 Concurrent failed import cleans only its own UUID file without deleting the succeeding credential")

        // 6. [R6 Finding 2] Runtime deletion cleanup removes only unreferenced files owned by deleted credentials, sparing in-flight imports & shared paths.
        let cleanupBase = home.appendingPathComponent("CleanupAppSupport")
        try FileManager.default.createDirectory(at: cleanupBase, withIntermediateDirectories: true)
        ProviderManagedImportStore.managedBase = cleanupBase
        let cleanupAgyDir = try ProviderManagedImportStore.managedImportsRootDirectory().appendingPathComponent("antigravity")
        try FileManager.default.createDirectory(at: cleanupAgyDir, withIntermediateDirectories: true)
        let retainedFile = cleanupAgyDir.appendingPathComponent("retained.json")
        let deletedFile = cleanupAgyDir.appendingPathComponent("deleted.json")
        let sharedFile = cleanupAgyDir.appendingPathComponent("shared.json")
        for url in [retainedFile, deletedFile, sharedFile] {
            try FileManager.default.copyItem(at: source, to: url)
        }
        let retainedCred = AccountCredential(providerId: "antigravity", accountLabel: "retained", authMethod: .authFile, credential: retainedFile.path)
        let retainedShared = AccountCredential(providerId: "antigravity", accountLabel: "retainedShared", authMethod: .authFile, credential: sharedFile.path)
        let deletedCred = AccountCredential(providerId: "antigravity", accountLabel: "deleted", authMethod: .authFile, credential: deletedFile.path)
        let deletedShared = AccountCredential(providerId: "antigravity", accountLabel: "deletedShared", authMethod: .authFile, credential: sharedFile.path)
        let cleanupGate = ConcurrentImportGate()
        let cleanupReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf")] },
            listPorts: { _ in [60441] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return await cleanupGate.handleStatusCall()
                }
                return ["response": ["groups": [["displayName": "Gemini Models", "buckets": [["bucketId": "gemini-5h", "window": "5h", "remainingFraction": 0.9, "resetTime": "2027-01-01T00:00:00Z"]]]]]]
            }
        )
        ProviderRegistry.injected = AntigravityProvider(homeDirectory: home.path, localQuotaReader: cleanupReader)
        let pendingImport = Task { try await ProviderAuthManager.authenticateCandidate(concCandidate, localOnly: true) }
        await cleanupGate.waitForFirstStart()
        let beforeCleanupFiles = try FileManager.default.contentsOfDirectory(atPath: cleanupAgyDir.path)
        precondition(beforeCleanupFiles.count == 4, "Three existing managed files plus one in-flight import exist prior to runtime deletion")
        ProviderManagedImportStore.cleanupManagedImports(
            forDeletedCredentials: [deletedCred, deletedShared],
            referencedBy: [retainedCred, retainedShared]
        )
        let afterCleanupFiles = try FileManager.default.contentsOfDirectory(atPath: cleanupAgyDir.path)
        await cleanupGate.releaseFirst()
        let (pendingCredential, _) = try await pendingImport.value
        precondition(!FileManager.default.fileExists(atPath: deletedFile.path)
                        && FileManager.default.fileExists(atPath: retainedFile.path)
                        && FileManager.default.fileExists(atPath: sharedFile.path)
                        && afterCleanupFiles.count == 3
                        && FileManager.default.fileExists(atPath: pendingCredential.credential),
                     "R6-F2 Runtime account deletion removes only unreferenced deleted files while preserving retained, shared, and in-flight imports")

        print("Discovery anti-ban workflow regression: PASS (6 assertions)")
    }
}
