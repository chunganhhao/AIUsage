import XCTest
@testable import QuotaBackend

final class GeminiProviderTests: XCTestCase {
    /// Google 停止个人账号使用 Gemini CLI 后的 403 响应：要识别出来，而不是当成令牌过期让用户反复重新登录。
    func testRecognizesIndividualTierShutdownResponse() {
        let body = Data("""
        {
          "error": {
            "code": 403,
            "message": "This client is no longer supported for Gemini Code Assist for individuals. To continue using Gemini, please migrate to the Antigravity suite of products: https://antigravity.google",
            "status": "PERMISSION_DENIED",
            "details": [{ "@type": "type.googleapis.com/google.rpc.ErrorInfo", "reason": "UNSUPPORTED_CLIENT" }]
          }
        }
        """.utf8)
        XCTAssertTrue(GeminiProvider.isIndividualTierDiscontinued(responseBody: body))
    }

    func testOtherPermissionErrorsAreNotTreatedAsShutdown() {
        let body = Data("""
        { "error": { "code": 403, "message": "Verify your account to continue.", "status": "PERMISSION_DENIED",
          "details": [{ "reason": "VALIDATION_REQUIRED" }] } }
        """.utf8)
        XCTAssertFalse(GeminiProvider.isIndividualTierDiscontinued(responseBody: body))
        XCTAssertFalse(GeminiProvider.isIndividualTierDiscontinued(responseBody: Data()))
    }

    /// proto3 omits a zero remainingFraction: an exhausted bucket (resetTime only) must read 0%, not vanish.
    func testExhaustedBucketWithoutFractionCountsAsZero() {
        let buckets: [[String: Any]] = [
            ["modelId": "gemini-3-pro", "tokenType": "REQUESTS", "remainingFraction": 0.6, "resetTime": "2026-10-21T00:00:00Z"],
            ["modelId": "gemini-3-pro", "tokenType": "REQUESTS", "resetTime": "2026-10-21T00:00:00Z"],
            ["modelId": "gemini-3-flash", "tokenType": "REQUESTS", "remainingFraction": 1],
            ["modelId": "gemini-3-flash-lite", "tokenType": "REQUESTS"]
        ]
        let byModel = GeminiProvider.lowestBucketsByModel(buckets)

        XCTAssertEqual(byModel["gemini-3-pro"]?.remainingFraction, 0)
        XCTAssertEqual(byModel["gemini-3-flash"]?.remainingFraction, 1)
        XCTAssertNil(byModel["gemini-3-flash-lite"], "No fraction and no reset time carries no signal")
    }
}
