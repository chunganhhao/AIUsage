import XCTest
@testable import QuotaBackend

final class APIKeyBalanceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.install(hosts: ["balance.invalid", "api.deepseek.com", "openrouter.ai"])
    }
    override func tearDown() {
        StubURLProtocol.uninstall()
        super.tearDown()
    }
    private func target(_ url: String = "https://balance.invalid/team/v1", key: String = "fixture-key") -> APIKeyBalanceTarget {
        APIKeyBalanceTarget(baseURL: url, apiKey: key)!
    }

    func testTargetPreservesPrefixAndIsolatesKeysWithoutExposingThem() {
        let a = target()
        XCTAssertEqual(a.rootURL.absoluteString, "https://balance.invalid/team")
        XCTAssertEqual(a.cacheKey, target("https://balance.invalid/team/v1/").cacheKey)
        XCTAssertNotEqual(a.cacheKey, target(key: "other-key").cacheKey)
        XCTAssertNotEqual(a.cacheKey, target("https://balance.invalid/other/v1").cacheKey)
        XCTAssertFalse(a.cacheKey.contains("fixture"))
        for url in ["https://user:pass@balance.invalid", "https://balance.invalid?k=secret", "file:///tmp", "https://balance.invalid/#secret"] {
            XCTAssertNil(APIKeyBalanceTarget(baseURL: url, apiKey: "fixture"))
        }
        XCTAssertNil(APIKeyBalanceTarget(baseURL: "https://balance.invalid", apiKey: "fixture\nkey"))
        XCTAssertNil(APIKeyBalanceTarget(baseURL: "https://balance.invalid", apiKey: " "))
    }

    func testOfficialInferenceKeysAreNotTreatedAsBillingCredentials() async {
        let service = APIKeyBalanceService()
        for host in ["api.openai.com", "api.anthropic.com"] {
            let result = await service.fetch(target("https://\(host)/v1"))
            XCTAssertEqual(result.status, .unsupported)
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testNewAPIMetadataAndAccountQuotaAreSeparateFromKeyCap() async {
        StubURLProtocol.respond("https://balance.invalid/team/api/usage/token/", body: #"{"code":true,"data":{"object":"token_usage","total_available":250000,"unlimited_quota":false,"user_quota":{"total_available":1000000}}}"#)
        StubURLProtocol.respond("https://balance.invalid/team/api/status", body: #"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"CNY","usd_exchange_rate":7}}"#)
        let result = await APIKeyBalanceService().fetch(target())
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.amounts, [.init(scope: .account, remaining: 14, currency: "CNY"), .init(scope: .keyLimit, remaining: 3.5, currency: "CNY")])
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
        let usage = StubURLProtocol.lastRequest(to: "https://balance.invalid/team/api/usage/token/")!
        XCTAssertEqual(usage.headers.first { $0.key.lowercased() == "authorization" }?.value, "Bearer fixture-key")
        let metadata = StubURLProtocol.lastRequest(to: "https://balance.invalid/team/api/status")!
        XCTAssertNil(metadata.headers.first { $0.key.lowercased() == "authorization" })
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.method == "GET" && !$0.url.contains("fixture-key") })
    }

    func testUnknownMetadataDoesNotInventCurrencyAndNegativeBalanceIsPreserved() {
        let json: [String: Any] = ["data": ["object": "token_usage", "total_available": "-15", "unlimited_quota": false]]
        for meta: [String: Any]? in [nil, ["success": true, "data": ["quota_per_unit": 500000]], ["success": false, "data": ["quota_per_unit": 500000, "quota_display_type": "USD"]]] {
            let values = APIKeyBalanceService.parseNewAPI(json, metadata: meta)
            XCTAssertEqual(values, [.init(scope: .keyLimit, remaining: -15, currency: nil)])
        }
        let uncapped = APIKeyBalanceService.parseNewAPI(["data": ["object": "token_usage", "total_available": 0, "unlimited_quota": true]], metadata: nil)
        XCTAssertEqual(uncapped, [.init(scope: .keyLimit, remaining: nil, currency: nil, uncapped: true)])
    }

    func testMalformedResponsesNeverBecomeZeroOrUnlimited() {
        for raw: Any in [true, "NaN", "Infinity", NSNull()] { XCTAssertNil(APIKeyBalanceService.number(raw)) }
        XCTAssertNil(APIKeyBalanceService.parseNewAPI(["data": ["total_available": 0]], metadata: nil))
        XCTAssertNil(APIKeyBalanceService.parseNewAPI(["code": false, "data": ["object": "token_usage", "total_available": 0]], metadata: nil))
        XCTAssertNil(APIKeyBalanceService.parseOpenRouter(["data": [:]]))
        XCTAssertNil(APIKeyBalanceService.parseOpenRouter(["data": ["limit": NSNull()]]))
        XCTAssertNil(APIKeyBalanceService.parseDeepSeek(["balance_infos": [["currency": "USD", "total_balance": 0]]]))
    }

    func testOpenRouterZeroAndUncappedAreDifferent() async {
        let url = "https://openrouter.ai/api/v1/key"
        StubURLProtocol.respond(url, body: #"{"data":{"limit":10,"limit_remaining":0}}"#)
        let service = APIKeyBalanceService()
        let key = target("https://openrouter.ai/api/v1")
        let zero = await service.fetch(key)
        XCTAssertEqual(zero.amounts, [.init(scope: .keyLimit, remaining: 0, currency: "USD")])
        StubURLProtocol.respond(url, body: #"{"data":{"limit":null,"limit_remaining":null}}"#)
        let uncapped = await service.fetch(key, force: true)
        XCTAssertEqual(uncapped.amounts, [.init(scope: .keyLimit, remaining: nil, currency: "USD", uncapped: true)])
    }

    func testOpenRouterHonorsLowerEffectiveBudget() {
        let amounts = APIKeyBalanceService.parseOpenRouter(["data": ["limit_remaining": 10, "effective_budget": ["remaining_usd": 2.5]]])
        XCTAssertEqual(amounts, [.init(scope: .keyLimit, remaining: 2.5, currency: "USD")])
        let uncappedWithBudget = APIKeyBalanceService.parseOpenRouter(["data": ["limit": NSNull(), "limit_remaining": NSNull(), "effective_budget": ["remaining_usd": 0]]])
        XCTAssertEqual(uncappedWithBudget, [.init(scope: .keyLimit, remaining: 0, currency: "USD")])
    }

    func testDeepSeekKeepsReturnedCurrencyAndSignedBalance() async {
        StubURLProtocol.respond("https://api.deepseek.com/user/balance", body: #"{"is_available":false,"balance_infos":[{"currency":"CNY","total_balance":"-0.25"},{"currency":"USD","total_balance":"0"}]}"#)
        let result = await APIKeyBalanceService().fetch(target("https://api.deepseek.com/v1"))
        XCTAssertEqual(result.status, .available)
        XCTAssertEqual(result.amounts, [.init(scope: .account, remaining: -0.25, currency: "CNY"), .init(scope: .account, remaining: 0, currency: "USD")])
    }

    func testUnsupportedEndpointsAreCachedButManualRefreshCanRetry() async {
        let service = APIKeyBalanceService()
        let key = target()
        let first = await service.fetch(key)
        let cached = await service.fetch(key)
        XCTAssertEqual(first.status, .unsupported)
        XCTAssertEqual(cached, first)
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let forced = await service.fetch(key, force: true)
        XCTAssertEqual(forced.status, .unsupported)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testConcurrentProductsDeduplicateAndFailureDoesNotReplayOldBalance() async {
        let service = APIKeyBalanceService()
        let key = target("https://api.deepseek.com")
        StubURLProtocol.respond("https://api.deepseek.com/user/balance", body: #"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"12"}]}"#)
        async let a = service.fetch(key)
        async let b = service.fetch(key)
        let results = await [a, b]
        XCTAssertTrue(results.allSatisfy { $0.status == .available })
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
        let failures: [(Int, APIKeyBalanceSnapshot.Status)] = [(401, .unauthorized), (429, .rateLimited), (500, .failed), (302, .failed)]
        for (http, status) in failures {
            StubURLProtocol.respond("https://api.deepseek.com/user/balance", status: http, body: #"{"secret":"never display"}"#)
            let failed = await service.fetch(key, force: true)
            XCTAssertEqual(failed.status, status)
            XCTAssertTrue(failed.amounts.isEmpty)
        }
    }
}
