import XCTest
@testable import QuotaBackend

final class AntigravityProviderTests: XCTestCase {
    private let provider = AntigravityProvider()

    // MARK: - retrieveUserQuotaSummary parsing

    func testParsesGroupedFiveHourAndWeeklyWindows() throws {
        let models = try XCTUnwrap(provider.parseQuotaSummary(Self.json(Self.fullSummary)))

        XCTAssertEqual(models.map(\.label), [
            "Gemini · Weekly", "Gemini · 5h", "Claude + GPT · Weekly", "Claude + GPT · 5h"
        ])
        XCTAssertEqual(models.map(\.id), ["gemini-weekly", "gemini-5h", "3p-weekly", "3p-5h"])
        XCTAssertEqual(models[0].remainingPercent, 27.25, accuracy: 0.001)
        XCTAssertEqual(models[3].remainingPercent, 100, accuracy: 0.001)
        XCTAssertEqual(models[0].resetAt, "2026-10-25T00:00:00Z")
    }

    /// proto3 JSON 省略零值：用尽的桶只剩 resetTime，必须算 0%，不能被丢掉。
    func testBucketWithoutFractionButWithResetIsExhausted() throws {
        let models = try XCTUnwrap(provider.parseQuotaSummary(Self.json("""
        {"groups":[{"displayName":"Claude and GPT models","buckets":[
          {"bucketId":"3p-weekly","window":"weekly","remainingFraction":0.81,"resetTime":"2026-10-25T00:00:00Z"},
          {"bucketId":"3p-5h","window":"5h","resetTime":"2026-10-20T15:00:00Z"}
        ]}]}
        """)))

        XCTAssertEqual(models.map(\.label), ["Claude + GPT · Weekly", "Claude + GPT · 5h"])
        XCTAssertEqual(models[1].remainingPercent, 0)
    }

    /// 禁用的桶既不能显示成 100%，也不能显示成 0% 把整个账号拉成用尽。
    func testDisabledBucketsAreLeftOut() throws {
        let models = try XCTUnwrap(provider.parseQuotaSummary(Self.json("""
        {"groups":[
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","window":"weekly","resetTime":"2026-10-25T00:00:00Z"},
            {"bucketId":"3p-5h","window":"5h","remainingFraction":1,"disabled":true}
          ]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","window":"weekly","remainingFraction":0.9,"resetTime":"2026-10-25T00:00:00Z"}
          ]}
        ]}
        """)))

        XCTAssertEqual(models.map(\.label), ["Claude + GPT · Weekly", "Gemini 4 Argon · Weekly"])
        XCTAssertEqual(models.map(\.remainingPercent), [0, 90])
    }

    /// Gemini 4 Argon 为附加周额度池：必须展示在 5 个窗口中，但耗尽时不能拉低账号主剩余百分比或触发断路器。
    func testGemini4ArgonAuxiliaryBucketDoesNotDragDownHeadlineRemainingPercent() async throws {
        let summaryWithExhaustedArgon = """
        {"groups":[
          {"displayName":"Gemini Models","buckets":[
            {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.9923,"resetTime":"2026-10-25T00:00:00Z"},
            {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1.0,"resetTime":"2026-10-20T15:00:00Z"}
          ]},
          {"displayName":"Claude and GPT models","buckets":[
            {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.9531,"resetTime":"2026-10-25T00:00:00Z"},
            {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1.0,"resetTime":"2026-10-20T15:00:00Z"}
          ]},
          {"displayName":"Gemini 4 Argon","buckets":[
            {"bucketId":"gemini-argon-wtu-weekly","displayName":"Gemini 4 Argon Weekly Limit","window":"weekly","remainingFraction":0.0008,"resetTime":"2026-10-28T13:17:17Z"}
          ]}
        ]}
        """
        let localReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 1, csrfToken: "csrf-argon")] },
            listPorts: { _ in [60432] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "user@example.com", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                if method.hasSuffix("RetrieveUserQuotaSummary") {
                    return Self.json(summaryWithExhaustedArgon)
                }
                return nil
            }
        )
        let localProvider = AntigravityProvider(homeDirectory: "/tmp/agy-test", localQuotaReader: localReader)
        let usage = try await localProvider.fetchUsage(with: makeCredential(withProjectStub: false))
        let normalized = UsageNormalizer.normalize(provider: localProvider, usage: usage)

        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(normalized.windows.count, 5)
        XCTAssertEqual(normalized.windows.last?.label, "Gemini 4 Argon · Weekly")
        XCTAssertEqual(normalized.windows.last?.remainingPercent ?? -1, 0.08, accuracy: 0.001)
        // Headline remainingPercent reflects tightest core pool (Claude + GPT · Weekly = 95.31%), not Argon (0.08%)
        XCTAssertEqual(normalized.remainingPercent ?? -1, 95.31, accuracy: 0.01)
        XCTAssertEqual(normalized.status, "healthy")
    }

    func testExtractsSelectedModelFromTranscriptSettingsChange() {
        let line1 = #"{"type":"USER_INPUT","content":"<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Gemini 4 Argon (Medium). No need to acknowledge this change.\n</USER_SETTINGS_CHANGE>"}"#
        let line2 = #"{"type":"USER_INPUT","content":"<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from Gemini 4 Argon (Medium) to Gemini 3.8 Flash (High).\n</USER_SETTINGS_CHANGE>"}"#
        let line3 = #"{"type":"USER_INPUT","content":"<USER_SETTINGS_CHANGE>\nThe user changed setting `Model Selection` from None to Claude Opus 4.6 (Thinking). No need to acknowledge this change.\n</USER_SETTINGS_CHANGE>"}"#
        let codeDiscussionLine = #"{"type":"PLANNER_RESPONSE","content":"if line.contains(\"Model Selection from None to Gemini 2.5 Flash\")"}"#

        XCTAssertEqual(AntigravityCostProvider.extractSelectedModel(from: line1), "gemini-4-argon")
        XCTAssertEqual(AntigravityCostProvider.extractSelectedModel(from: line2), "gemini-3.8-flash")
        XCTAssertEqual(AntigravityCostProvider.extractSelectedModel(from: line3), "claude-opus-4.6")
        XCTAssertNil(AntigravityCostProvider.extractSelectedModel(from: codeDiscussionLine))
    }

    func testSummaryWithoutUsableBucketsIsRejected() {
        XCTAssertNil(provider.parseQuotaSummary([:]))
        XCTAssertNil(provider.parseQuotaSummary(Self.json(#"{"groups":[]}"#)))
        XCTAssertNil(provider.parseQuotaSummary(Self.json("""
        {"groups":[{"displayName":"Gemini Models","buckets":[
          {"bucketId":"gemini-5h","window":"5h","remainingFraction":1,"disabled":true},
          {"bucketId":"gemini-weekly","window":"weekly"}
        ]}]}
        """)))
    }

    // MARK: - Policy-compliant local IDE RPC & zero remote Google HTTPS

    override func setUp() {
        super.setUp()
        StubURLProtocol.install(hosts: ["googleapis.com", "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com", "oauth2.googleapis.com"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }

    func testPersonalBuildEnablesLiveIDEReaderOnRealHomeAndIsolatesTestHomes() async throws {
        let realHomeProd = AntigravityProvider(homeDirectory: NSHomeDirectory())
        let isolatedProd = AntigravityProvider(homeDirectory: "/tmp/agy-isolated-home")
        let explicitNilProvider = AntigravityProvider(homeDirectory: NSHomeDirectory(), localQuotaReader: nil)
        XCTAssertNotNil(realHomeProd.effectiveLocalQuotaReader)
        XCTAssertNil(isolatedProd.effectiveLocalQuotaReader)
        XCTAssertNil(explicitNilProvider.effectiveLocalQuotaReader)

        for disabledProvider in [isolatedProd, explicitNilProvider] {
            do {
                _ = try await disabledProvider.fetchUsage(with: makeCredential(withProjectStub: false))
                XCTFail("Expected local_only_unavailable when isolated or explicit-nil local IDE RPC is disabled")
            } catch let error as ProviderError {
                XCTAssertEqual(error.code, "local_only_unavailable")
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testDiscoverDaemonHubServersReadsNewestAliveHubAndSkipsDeadAndSymlinks() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("agy-daemon-hub-test-\(UUID().uuidString)", isDirectory: true)
        let daemonDir = dir.appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        try FileManager.default.createDirectory(at: daemonDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let oldAliveURL = daemonDir.appendingPathComponent("hub_50300.json")
        try Data(#"{"pid":3001,"httpPort":50300,"httpsPort":50299,"lsVersion":"2.34.0","csrfToken":"tok-old"}"#.utf8)
            .write(to: oldAliveURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_000)], ofItemAtPath: oldAliveURL.path)

        let deadURL = daemonDir.appendingPathComponent("hub_50001.json")
        try Data(#"{"pid":9999,"httpPort":50001,"httpsPort":50000,"lsVersion":"2.34.0","csrfToken":"tok-dead"}"#.utf8)
            .write(to: deadURL)

        let symlinkTarget = dir.appendingPathComponent("outside.json")
        try Data(#"{"pid":4082,"httpPort":50002,"httpsPort":50003,"csrfToken":"tok-symlink"}"#.utf8)
            .write(to: symlinkTarget)
        try FileManager.default.createSymbolicLink(
            at: daemonDir.appendingPathComponent("hub_50002.json"),
            withDestinationURL: symlinkTarget
        )

        let newAliveURL = daemonDir.appendingPathComponent("hub_50312.json")
        try Data(#"{"pid":4082,"httpPort":50312,"httpsPort":50311,"lsVersion":"2.34.0","csrfToken":"tok-new"}"#.utf8)
            .write(to: newAliveURL)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_800_000_100)], ofItemAtPath: newAliveURL.path)

        let discovered = AntigravityLocalQuotaReader.discoverDaemonHubServers(
            homeDirectory: dir.path,
            isProcessAlive: { $0 == 4082 || $0 == 3001 }
        )
        XCTAssertEqual(discovered.count, 2)
        XCTAssertEqual(discovered.first, .init(pid: 4082, csrfToken: "tok-new", preferredPorts: [50312, 50311]))
        XCTAssertEqual(discovered.last, .init(pid: 3001, csrfToken: "tok-old", preferredPorts: [50300, 50299]))
    }

    func testLocalIDEReaderEnforcesProjectAttributionWhenRequiredOrMismatched() async throws {
        let cred = try makeCredential(withProjectStub: false, projectId: "proj-123")

        let mismatchedProjectReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 42, csrfToken: "csrf-local")] },
            listPorts: { _ in [60432] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "user@example.com", "projectId": "proj-other", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                if method.hasSuffix("RetrieveUserQuotaSummary") {
                    return Self.json(Self.fullSummary)
                }
                return nil
            }
        )
        let mismatchedProvider = AntigravityProvider(homeDirectory: "/tmp/agy-mismatch", localQuotaReader: mismatchedProjectReader)
        do {
            _ = try await mismatchedProvider.fetchUsage(with: cred, localOnly: true, requireProjectMatch: false)
            XCTFail("Expected local_only_unavailable on mismatched projectId")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "local_only_unavailable")
        }

        let unboundReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 42, csrfToken: "csrf-local")] },
            listPorts: { _ in [60432] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "user@example.com", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                if method.hasSuffix("RetrieveUserQuotaSummary") {
                    return Self.json(Self.fullSummary)
                }
                return nil
            }
        )
        let unboundProvider = AntigravityProvider(homeDirectory: "/tmp/agy-unbound", localQuotaReader: unboundReader)
        do {
            _ = try await unboundProvider.fetchUsage(with: cred, localOnly: true, requireProjectMatch: true)
            XCTFail("Expected local_only_unavailable when requireProjectMatch is true and sample has no projectId")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "local_only_unavailable")
        }

        let matchingReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 42, csrfToken: "csrf-local")] },
            listPorts: { _ in [60432] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "user@example.com", "projectId": "proj-123", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                if method.hasSuffix("RetrieveUserQuotaSummary") {
                    return Self.json(Self.fullSummary)
                }
                return nil
            }
        )
        let matchingProvider = AntigravityProvider(homeDirectory: "/tmp/agy-matching", localQuotaReader: matchingReader)
        let matchedUsage = try await matchingProvider.fetchUsage(with: cred, localOnly: true, requireProjectMatch: true)
        XCTAssertEqual(matchedUsage.extra["projectId"]?.value as? String, "proj-123")

        let legacySentinelCred = try makeCredential(withProjectStub: false, projectId: "aicode-consumers")
        let sentinelUpgradedUsage = try await matchingProvider.fetchUsage(with: legacySentinelCred, localOnly: true, requireProjectMatch: false)
        XCTAssertEqual(sentinelUpgradedUsage.extra["projectId"]?.value as? String, "proj-123")
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testFetchUsageFailsClosedLocallyWhenIDEAbsentWithZeroHTTPS() async throws {
        let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
        let absentProvider = AntigravityProvider(homeDirectory: "/tmp/agy-absent", localQuotaReader: absentReader)

        do {
            _ = try await absentProvider.fetchUsage(with: makeCredential(withProjectStub: false))
            XCTFail("Expected local_only_unavailable when local IDE is absent")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "local_only_unavailable")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testFetchUsageReadsMatchingLocalIDERPCWithZeroHTTPS() async throws {
        let localReader = AntigravityLocalQuotaReader(
            listProcesses: { [.init(pid: 42, csrfToken: "csrf-local")] },
            listPorts: { _ in [60432] },
            callRPC: { _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {
                    return ["userStatus": ["email": "user@example.com", "userTier": ["id": "pro", "name": "Pro"]]]
                }
                if method.hasSuffix("RetrieveUserQuotaSummary") {
                    return Self.json(Self.fullSummary)
                }
                return nil
            }
        )
        let localProvider = AntigravityProvider(homeDirectory: "/tmp/agy-local", localQuotaReader: localReader)
        let usage = try await localProvider.fetchUsage(with: makeCredential(withProjectStub: false))

        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(usage.extra["transport"]?.value as? String, "loopback_rpc")
        XCTAssertEqual(usage.extra["quotaSource"]?.value as? String, "groups")
        XCTAssertEqual(usage.primary?.label, "Gemini · Weekly")
        XCTAssertEqual(usage.primary?.remainingPercent ?? -1, 27.25, accuracy: 0.001)

        let summary = UsageNormalizer.normalize(provider: localProvider, usage: usage)
        XCTAssertEqual(summary.windows.count, 4)
        XCTAssertNil(summary.models)
        XCTAssertEqual(summary.headline.secondary, "lowest remaining window")
    }

    func testPreSuspendedCredentialReturnsTosViolationWithZeroHTTPS() async throws {
        let absentReader = AntigravityLocalQuotaReader(listProcesses: { [] }, listPorts: { _ in [] }, callRPC: { _, _, _, _ in nil })
        let localProvider = AntigravityProvider(homeDirectory: "/tmp/agy-susp", localQuotaReader: absentReader)
        let cred = try makeCredential(withProjectStub: false)
        let url = URL(fileURLWithPath: cred.credential)
        let raw = try Data(contentsOf: url)
        try AntigravityAccountProtection.suspend(url, error: ProviderError("tos_violation", "Suspended"), expectedData: raw)

        do {
            _ = try await localProvider.fetchUsage(with: cred)
            XCTFail("Expected tos_violation")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "tos_violation")
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testAntigravityCostTranscriptScanCacheHitsInvalidatesPrunesAndIsolatesTimeZones() async throws {
        final class ParseCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []
            func record(_ path: String) {
                lock.lock()
                paths.append(path)
                lock.unlock()
            }
            var count: Int {
                lock.lock()
                defer { lock.unlock() }
                return paths.count
            }
            var recordedPaths: [String] {
                lock.lock()
                defer { lock.unlock() }
                return paths
            }
        }

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agy-scan-cache-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        let brainDir = root.appendingPathComponent("brain", isDirectory: true)
        let siblingBrainDir = root.appendingPathComponent("brain2", isDirectory: true)
        let tokenLogDir = brainDir.appendingPathComponent("conv-token/.system_generated/logs", isDirectory: true)
        let emptyLogDir = brainDir.appendingPathComponent("conv-empty/.system_generated/logs", isDirectory: true)
        let siblingLogDir = siblingBrainDir.appendingPathComponent("conv-sibling/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: tokenLogDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: emptyLogDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: siblingLogDir, withIntermediateDirectories: true)

        let tokenFile = tokenLogDir.appendingPathComponent("transcript.jsonl").path
        let emptyFile = emptyLogDir.appendingPathComponent("transcript.jsonl").path
        let siblingFile = siblingLogDir.appendingPathComponent("transcript.jsonl").path

        let line1 = #"{"type":"PLANNER_RESPONSE","created_at":"2026-11-21T23:30:00Z","input_tokens":100,"output_tokens":20,"cache_read_tokens":30}"# + "\n"
        try Data(line1.utf8).write(to: URL(fileURLWithPath: tokenFile))
        try Data(#"{"type":"USER_INPUT","content":"hello"}"#.utf8).write(to: URL(fileURLWithPath: emptyFile))
        try Data(line1.utf8).write(to: URL(fileURLWithPath: siblingFile))

        let tzPlus7 = try XCTUnwrap(TimeZone(secondsFromGMT: 7 * 3600))
        let tzMinus8 = try XCTUnwrap(TimeZone(secondsFromGMT: -8 * 3600))
        let providerPlus7 = AntigravityCostProvider(homeDirectory: root.path, timeZone: tzPlus7)
        let providerMinus8 = AntigravityCostProvider(homeDirectory: root.path, timeZone: tzMinus8)

        let counter = ParseCounter()
        let countingParser: @Sendable (String) -> [String: CodexAggregateBucket]? = { path in
            counter.record(path)
            return providerPlus7.processFile(path)
        }
        let minus8Parser: @Sendable (String) -> [String: CodexAggregateBucket]? = { path in
            counter.record(path)
            return providerMinus8.processFile(path)
        }

        // 1. Cold scan parses both tokenFile and emptyFile (emptyFile omitted from output, still cached)
        let first = await providerPlus7.scanFilesByPathCached([tokenFile, emptyFile], brainDirectory: brainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(first.keys.sorted(), [tokenFile])
        XCTAssertEqual(first[tokenFile]?["2026-11-22"]?.totalTokens, 150)

        // 2. Unchanged rescan hits cache for BOTH files (0 parses)
        let second = await providerPlus7.scanFilesByPathCached([tokenFile, emptyFile], brainDirectory: brainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 2)
        XCTAssertEqual(second[tokenFile]?["2026-11-22"]?.totalTokens, 150)

        // 3. Appending a line invalidates ONLY tokenFile
        let line2 = #"{"type":"PLANNER_RESPONSE","created_at":"2026-11-21T23:31:00Z","input_tokens":50,"output_tokens":10,"cache_read_tokens":0}"# + "\n"
        try Data((line1 + line2).utf8).write(to: URL(fileURLWithPath: tokenFile))
        let third = await providerPlus7.scanFilesByPathCached([tokenFile, emptyFile], brainDirectory: brainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 3)
        XCTAssertEqual(counter.recordedPaths.last, tokenFile)
        XCTAssertEqual(third[tokenFile]?["2026-11-22"]?.totalTokens, 210)

        // 4. Different TimeZone reparses instead of returning wrong-day cached buckets
        let minus8Result = await providerMinus8.scanFilesByPathCached([tokenFile], parseFile: minus8Parser)
        XCTAssertEqual(counter.count, 4)
        XCTAssertEqual(minus8Result[tokenFile]?["2026-11-21"]?.totalTokens, 210)
        XCTAssertNil(minus8Result[tokenFile]?["2026-11-22"])

        // Restore tzPlus7 entry for tokenFile before pruning test
        _ = await providerPlus7.scanFilesByPathCached([tokenFile], parseFile: countingParser)
        XCTAssertEqual(counter.count, 5)

        // 5. Sibling brain2 is cached; pruning brain removes dropped tokenFile without evicting brain2
        _ = await providerPlus7.scanFilesByPathCached([siblingFile], brainDirectory: siblingBrainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 6)

        _ = await providerPlus7.scanFilesByPathCached([emptyFile], brainDirectory: brainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 6) // emptyFile still cached

        _ = await providerPlus7.scanFilesByPathCached([siblingFile], brainDirectory: siblingBrainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 6) // brain2 NOT evicted by brain's prune

        let reparsedAfterPrune = await providerPlus7.scanFilesByPathCached([tokenFile], brainDirectory: brainDir.path, parseFile: countingParser)
        XCTAssertEqual(counter.count, 7) // tokenFile was pruned so it reparses
        XCTAssertEqual(reparsedAfterPrune[tokenFile]?["2026-11-22"]?.totalTokens, 210)

        // 6. [§6.1] Unreadable transcript (000 -> 600 chmod) must not poison cache as empty
        let permLine = #"{"type":"PLANNER_RESPONSE","created_at":"2026-11-21T23:32:00Z","input_tokens":30,"output_tokens":12,"cache_read_tokens":0}"# + "\n"
        let permLogDir = brainDir.appendingPathComponent("conv-perm/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: permLogDir, withIntermediateDirectories: true)
        let permFile = permLogDir.appendingPathComponent("transcript.jsonl").path
        try Data(permLine.utf8).write(to: URL(fileURLWithPath: permFile))
        if ProcessInfo.processInfo.userName != "root" {
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: permFile)
            let unreadableScan = await providerPlus7.scanFilesByPathCached([permFile], parseFile: countingParser)
            XCTAssertTrue(unreadableScan.isEmpty)
            XCTAssertEqual(counter.count, 8)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permFile)
            let recoveredScan = await providerPlus7.scanFilesByPathCached([permFile], parseFile: countingParser)
            XCTAssertEqual(counter.count, 9) // failed read was not cached
            XCTAssertEqual(recoveredScan[permFile]?["2026-11-22"]?.totalTokens, 42)
            let cachedAfterRecovery = await providerPlus7.scanFilesByPathCached([permFile], parseFile: countingParser)
            XCTAssertEqual(counter.count, 9) // successful recovery is now cached
            XCTAssertEqual(cachedAfterRecovery[permFile]?["2026-11-22"]?.totalTokens, 42)
        }

        // 7. [§6.2] Symlink transcript tracks resolved target file stamp while preserving canonical symlink key
        let symlinkTarget = root.appendingPathComponent("symlink-target.jsonl").path
        let symlinkLogDir = brainDir.appendingPathComponent("conv-sym/.system_generated/logs", isDirectory: true)
        try fm.createDirectory(at: symlinkLogDir, withIntermediateDirectories: true)
        let symlinkPath = symlinkLogDir.appendingPathComponent("transcript.jsonl").path
        try Data(permLine.utf8).write(to: URL(fileURLWithPath: symlinkTarget))
        try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: symlinkTarget)

        let symFirst = await providerPlus7.scanFilesByPathCached([symlinkPath], parseFile: countingParser)
        let countAfterSymFirst = counter.count
        XCTAssertEqual(symFirst[symlinkPath]?["2026-11-22"]?.totalTokens, 42)
        let symHit = await providerPlus7.scanFilesByPathCached([symlinkPath], parseFile: countingParser)
        XCTAssertEqual(counter.count, countAfterSymFirst)
        XCTAssertEqual(symHit[symlinkPath]?["2026-11-22"]?.totalTokens, 42)

        try Data((permLine + permLine).utf8).write(to: URL(fileURLWithPath: symlinkTarget))
        let symUpdated = await providerPlus7.scanFilesByPathCached([symlinkPath], parseFile: countingParser)
        XCTAssertEqual(counter.count, countAfterSymFirst + 1)
        XCTAssertEqual(symUpdated[symlinkPath]?["2026-11-22"]?.totalTokens, 84)
    }

    func testCredentialStoreRevisionFencedAuxiliaryWriteRejectsStaleOverwrite() throws {
        let key = "providerAccounts.registry"
        var persistedVaultData: Data?
        var physicalWriteCount = 0
        var shouldFailWrite = false
        let makeStore: () -> AccountCredentialStore = {
            AccountCredentialStore(
                readVaultData: { persistedVaultData },
                writeVaultData: { data in
                    physicalWriteCount += 1
                    if shouldFailWrite {
                        throw CredentialStoreError.keychainWriteFailed(-25291)
                    }
                    persistedVaultData = data
                }
            )
        }

        let store = makeStore()
        let rev2Data = Data("rev2".utf8)
        let rev1Data = Data("rev1".utf8)
        let rev3Data = Data("rev3".utf8)

        let outcome2 = try store.saveAuxiliaryData(rev2Data, forKey: key, revision: 2)
        XCTAssertEqual(outcome2, .committed)
        XCTAssertEqual(physicalWriteCount, 1)
        XCTAssertEqual(store.committedAuxiliaryRevision(forKey: key), 2)

        let staleOutcome = try store.saveAuxiliaryData(rev1Data, forKey: key, revision: 1)
        XCTAssertEqual(staleOutcome, .superseded(committedRevision: 2, committedData: rev2Data))
        XCTAssertEqual(physicalWriteCount, 1)
        XCTAssertEqual(store.loadAuxiliaryData(forKey: key), rev2Data)

        shouldFailWrite = true
        XCTAssertThrowsError(try store.saveAuxiliaryData(rev3Data, forKey: key, revision: 3))
        XCTAssertEqual(physicalWriteCount, 2)
        XCTAssertEqual(store.committedAuxiliaryRevision(forKey: key), 2)
        XCTAssertEqual(store.loadAuxiliaryData(forKey: key), rev2Data)

        shouldFailWrite = false
        let outcome3 = try store.saveAuxiliaryData(rev3Data, forKey: key, revision: 3)
        XCTAssertEqual(outcome3, .committed)
        XCTAssertEqual(physicalWriteCount, 3)
        XCTAssertEqual(store.committedAuxiliaryRevision(forKey: key), 3)

        let reopenedStore = makeStore()
        XCTAssertEqual(reopenedStore.loadAuxiliaryData(forKey: key), rev3Data)
    }

    func testCredentialStorePreservesExistingCredentialsAfterTransientVaultReadFailure() throws {
        let key = "providerAccounts.registry"
        var persistedVaultData: Data?
        let seedStore = AccountCredentialStore(
            readVaultData: { persistedVaultData },
            writeVaultData: { persistedVaultData = $0 }
        )
        let existingCred = AccountCredential(
            id: "seeded-codex-1",
            providerId: "codex",
            accountLabel: "seeded@example.invalid",
            authMethod: .authFile,
            credential: "/tmp/seeded-codex-1/auth.json",
            metadata: ["accountId": "acct-seeded", "workspaceUserId": "user-seeded"]
        )
        let extraCred = AccountCredential(
            id: "seeded-codex-2",
            providerId: "codex",
            accountLabel: "extra@example.invalid",
            authMethod: .authFile,
            credential: "/tmp/seeded-codex-2/auth.json",
            metadata: ["accountId": "acct-extra", "workspaceUserId": "user-extra"]
        )
        try seedStore.saveCredential(existingCred)

        var readAttempts = 0
        var writeAttempts = 0
        let failFirstReadStore = {
            AccountCredentialStore(
                readVaultData: {
                    readAttempts += 1
                    if readAttempts == 1 {
                        throw CredentialStoreError.keychainReadFailed(-25308)
                    }
                    return persistedVaultData
                },
                writeVaultData: { data in
                    writeAttempts += 1
                    persistedVaultData = data
                }
            )
        }
        let cleanReader = {
            AccountCredentialStore(readVaultData: { persistedVaultData }, writeVaultData: { _ in })
        }

        let rev7 = Data("rev7".utf8)
        let versionedStore = failFirstReadStore()
        XCTAssertNil(versionedStore.loadAuxiliaryData(forKey: key))
        XCTAssertEqual(try versionedStore.saveAuxiliaryData(rev7, forKey: key, revision: 7), .committed)
        XCTAssertEqual(readAttempts, 2)
        XCTAssertEqual(writeAttempts, 1)
        XCTAssertEqual(cleanReader().loadAllCredentials().map(\.id), ["seeded-codex-1"])
        XCTAssertEqual(cleanReader().loadAuxiliaryData(forKey: key), rev7)

        readAttempts = 0
        writeAttempts = 0
        let unversionedBlob = Data("unversioned".utf8)
        let unversionedStore = failFirstReadStore()
        XCTAssertTrue(unversionedStore.loadAllCredentials().isEmpty)
        try unversionedStore.saveAuxiliaryData(unversionedBlob, forKey: "cliProxy.test")
        XCTAssertEqual(readAttempts, 2)
        XCTAssertEqual(writeAttempts, 1)
        XCTAssertEqual(cleanReader().loadAllCredentials().map(\.id), ["seeded-codex-1"])
        XCTAssertEqual(cleanReader().loadAuxiliaryData(forKey: key), rev7)
        XCTAssertEqual(cleanReader().loadAuxiliaryData(forKey: "cliProxy.test"), unversionedBlob)

        readAttempts = 0
        let credStore = failFirstReadStore()
        XCTAssertTrue(credStore.loadAllCredentials().isEmpty)
        try credStore.saveCredential(extraCred)
        XCTAssertEqual(Set(cleanReader().loadAllCredentials().map(\.id)), ["seeded-codex-1", "seeded-codex-2"])
    }

    // MARK: - Fixtures

    private static let loadCodeAssist = "https://daily-cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let prodLoadCodeAssist = "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist"
    private static let dailySummary = "https://daily-cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    private static let prodSummary = "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuotaSummary"
    private static let legacyModels = "https://cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels"

    private static let fullSummary = """
    {"groups":[
      {"displayName":"Gemini Models","buckets":[
        {"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.2725,"resetTime":"2026-10-25T00:00:00Z"},
        {"bucketId":"gemini-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":0.9302,"resetTime":"2026-10-20T15:00:00Z"}
      ]},
      {"displayName":"Claude and GPT models","buckets":[
        {"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining","window":"weekly","remainingFraction":0.8127,"resetTime":"2026-10-25T00:00:00Z"},
        {"bucketId":"3p-5h","displayName":"Five Hour Limit Remaining","window":"5h","remainingFraction":1.0,"resetTime":"2026-10-20T15:00:00Z"}
      ]}
    ]}
    """

    private static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func makeCredential(withProjectStub: Bool = true, projectId: String? = nil) throws -> AccountCredential {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let authFile = directory.appendingPathComponent("antigravity-user@example.com.json")
        var payload: [String: Any] = ["access_token": "test-token", "email": "user@example.com"]
        if let projectId {
            payload["project_id"] = projectId
        }
        try JSONSerialization.data(withJSONObject: payload).write(to: authFile)
        if withProjectStub {
            StubURLProtocol.respond(Self.loadCodeAssist, status: 200, body: #"{"currentTier":{"id":"pro","name":"Pro"},"cloudaicompanionProject":"proj-123"}"#)
        }
        return AccountCredential(
            providerId: "antigravity",
            authMethod: .authFile,
            credential: authFile.path,
            metadata: projectId.map { ["projectId": $0] } ?? [:]
        )
    }
}
