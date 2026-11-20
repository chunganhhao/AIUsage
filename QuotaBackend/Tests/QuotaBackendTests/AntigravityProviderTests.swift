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

    func testDefaultProductionProviderDisablesLiveIDEReaderevenForRealHomeDirectory() async throws {
        let prodProvider = AntigravityProvider(homeDirectory: NSHomeDirectory())
        XCTAssertNil(prodProvider.effectiveLocalQuotaReader)
        do {
            _ = try await prodProvider.fetchUsage(with: makeCredential(withProjectStub: false))
            XCTFail("Expected local_only_unavailable when default production provider has live IDE RPC disabled")
        } catch let error as ProviderError {
            XCTAssertEqual(error.code, "local_only_unavailable")
        }
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

    private func makeCredential(withProjectStub: Bool = true) throws -> AccountCredential {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let authFile = directory.appendingPathComponent("antigravity-user@example.com.json")
        try Data(#"{"access_token":"test-token","email":"user@example.com"}"#.utf8).write(to: authFile)
        if withProjectStub {
            StubURLProtocol.respond(Self.loadCodeAssist, status: 200, body: #"{"currentTier":{"id":"pro","name":"Pro"},"cloudaicompanionProject":"proj-123"}"#)
        }
        return AccountCredential(providerId: "antigravity", authMethod: .authFile, credential: authFile.path)
    }
}
