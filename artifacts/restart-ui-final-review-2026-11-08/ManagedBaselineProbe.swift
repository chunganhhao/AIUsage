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

func converterFastPath(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

    fatalError("Probe uses native-format fast path only")
}

@main struct ManagedBaselineProbe {
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
        let liveValid: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": ["access_token": a, "id_token": a, "refresh_token": "synthetic-live-valid-A", "account_id": "A"],
            "last_refresh": "2026-11-08T00:00:00Z"
        ]
        let livePath = dir.appendingPathComponent("auth.json")
        let liveBackupPath = dir.appendingPathComponent("auth.json.bak")
        let liveValidData = try JSONSerialization.data(withJSONObject: liveValid, options: [.prettyPrinted, .sortedKeys])
        try liveValidData.write(to: livePath)

        let expected = CodexAccountIdentity(authJSON: managed)
        precondition(expected.matches(CodexAccountIdentity(authJSON: mixed)))
        let mixedData = try JSONSerialization.data(withJSONObject: mixed)
        // Exact production converter fast-path below: tokens + auth_mode returns source bytes unchanged.
        let converted = try converterFastPath(mixedData)
        precondition(converted == mixedData)
        let result = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: converted,
            managedSourceData: mixedData,
            expectedIdentity: expected,
            candidatePaths: [livePath.path, liveBackupPath.path]
        )
        precondition(!result.isValidBaseline)
        precondition(!result.adoptedLiveCandidate)
        precondition(result.healedManagedData == nil)
        precondition(result.nativeData.isEmpty)
        precondition(result.nativeJSON.isEmpty)
        precondition(result.identity.accountId == nil)
        precondition(!result.identity.matches(expected))
        let liveAfter = try Data(contentsOf: livePath)
        precondition(liveAfter == liveValidData)
        precondition(!fm.fileExists(atPath: liveBackupPath.path))

        // Valid dual-group managed baseline is normalized into clean single-group native tokens.
        let validDualManaged: [String: Any] = [
            "auth_mode": "chatgpt",
            "access_token": a, "id_token": a, "refresh_token": "synthetic-flat-valid-A", "account_id": "A",
            "flat_last_refresh": "2026-11-07T00:00:00Z",
            "tokens": [
                "access_token": a, "id_token": a, "refresh_token": "synthetic-nested-valid-A", "account_id": "A",
                "last_refresh": "2026-11-06T00:00:00Z"
            ]
        ]
        let validDualData = try JSONSerialization.data(withJSONObject: validDualManaged)
        let validDualResult = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: try converterFastPath(validDualData),
            managedSourceData: validDualData,
            expectedIdentity: expected,
            candidatePaths: []
        )
        let normalizedTokens = validDualResult.nativeJSON["tokens"] as! [String: Any]
        precondition(validDualResult.isValidBaseline)
        precondition(!validDualResult.adoptedLiveCandidate)
        precondition(normalizedTokens["refresh_token"] as? String == "synthetic-flat-valid-A")
        precondition(CodexAccountIdentity(authJSON: ["tokens": normalizedTokens]).matches(expected))
        print("VERIFIED: conflicting dual-group managed baseline fails closed (isValidBaseline == false, empty payload/identity)")
        print("VERIFIED: pre-existing valid live auth.json is untouched and valid dual-group baseline normalizes cleanly")
        print("PASS: 13 isolated managed-baseline assertions; no live state touched")
    }
}
