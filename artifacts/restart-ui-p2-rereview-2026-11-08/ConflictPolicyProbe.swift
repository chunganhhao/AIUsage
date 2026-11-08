import Foundation
import QuotaBackend

// Calls production reconciliation directly. No source extraction or mocks.
// All JWTs and paths are synthetic; candidate files live only in a disposable directory.
func jwt(_ account: String, _ user: String) throws -> String {
    let data = try JSONSerialization.data(withJSONObject: [
        "iat": 100,
        "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user]
    ])
    return "e30." + data.base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_") + ".sig"
}

@main struct ConflictPolicyProbe {
    static func main() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("codex-conflict-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let a = try jwt("A", "user-A")
        let b = try jwt("B", "user-B")
        let managed: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": ["access_token": a, "id_token": a, "refresh_token": "synthetic-old-A", "account_id": "A"],
            "last_refresh": "2026-11-01T00:00:00Z"
        ]
        let mixed: [String: Any] = [
            "auth_mode": "chatgpt",
            "access_token": a, "id_token": a, "refresh_token": "synthetic-flat-A", "account_id": "A",
            "flat_last_refresh": "2026-11-07T00:00:00Z",
            "tokens": [
                "access_token": a, "id_token": b, "refresh_token": "synthetic-nested-B", "account_id": "A",
                "last_refresh": "2026-11-08T00:00:00Z"
            ]
        ]
        let path = dir.appendingPathComponent("candidate.json")
        try JSONSerialization.data(withJSONObject: mixed).write(to: path)
        let expected = CodexAccountIdentity(authJSON: managed)
        precondition(expected.matches(CodexAccountIdentity(authJSON: mixed)))
        let result = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: try JSONSerialization.data(withJSONObject: managed),
            expectedIdentity: expected,
            candidatePaths: [path.path]
        )
        let tokens = result.nativeJSON["tokens"] as! [String: Any]
        precondition(!result.adoptedLiveCandidate)
        precondition(result.healedManagedData == nil)
        precondition(tokens["id_token"] as? String == a)
        precondition(tokens["refresh_token"] as? String == "synthetic-old-A")
        precondition(result.identity.matches(expected))
        precondition(CodexAccountIdentity(authJSON: result.nativeJSON).matches(expected))

        let validDualA: [String: Any] = [
            "auth_mode": "chatgpt",
            "access_token": a, "id_token": a, "refresh_token": "synthetic-flat-A", "account_id": "A",
            "flat_last_refresh": "2026-11-07T00:00:00Z",
            "tokens": [
                "access_token": a, "id_token": a, "refresh_token": "synthetic-nested-valid-A", "account_id": "A",
                "last_refresh": "2026-11-08T00:00:00Z"
            ]
        ]
        try JSONSerialization.data(withJSONObject: validDualA).write(to: path)
        let validResult = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: try JSONSerialization.data(withJSONObject: managed),
            expectedIdentity: expected,
            candidatePaths: [path.path]
        )
        let validTokens = validResult.nativeJSON["tokens"] as! [String: Any]
        precondition(validResult.adoptedLiveCandidate)
        precondition(validTokens["id_token"] as? String == a)
        precondition(validTokens["refresh_token"] as? String == "synthetic-nested-valid-A")
        precondition(validResult.identity.matches(expected))
        precondition(CodexAccountIdentity(authJSON: validResult.nativeJSON).matches(expected))
        print("VERIFIED: mixed candidate with conflicting A-access/B-id nested token group is rejected")
        print("VERIFIED: result.identity and emitted nativeJSON both preserve valid identity A with no healed overwrite")
        print("PASS: 11 isolated conflict-rejection & output-identity assertions; no live state touched")
    }
}
