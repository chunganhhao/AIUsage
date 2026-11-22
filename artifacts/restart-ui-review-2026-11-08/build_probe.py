from pathlib import Path
root = Path(__file__).resolve().parents[2]
src = (root / 'AIUsage/ViewModels/ProviderActivationManager.swift').read_text()
def function(signature):
    start = src.index(signature)
    opening = src.index('{', start)
    depth = 1
    pos = opening + 1
    while depth:
        depth += (src[pos] == '{') - (src[pos] == '}')
        pos += 1
    return src[start:pos]
start = src.index('            let sourceData = try Data(contentsOf: selected.authFileURL)', src.index('func reapplyCodexAccountForRestart'))
end = src.index('            let genAfter', start)
slice = src[start:end].replace('NSString(string: "~/.codex").expandingTildeInPath', 'testCodexDir')
act_start = src.index('        let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(', src.index('func activateCodexAccount'))
act_end = src.index('        codexSwitchGeneration &+= 1', act_start)
act_slice = (
    src[act_start:act_end]
    .replace('let effectiveIdentity = reconciled.identity', '_ = reconciled.identity')
    .replace('let isCodexRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")\n            .contains { !$0.isTerminated }', 'let isCodexRunning = false')
    .replace('let syncOutcome = CodexGlobalStateSync.syncWorkspaceProjects(', '_ = CodexGlobalStateSync.syncWorkspaceProjects(')
)
helpers = function('    private func convertToCodexNativeFormat') + '\n' + function('    private func writeAuthFileWithBackup')
code = r'''import Foundation
import QuotaBackend
// Seams: selection/generation fixed to the already-active synthetic account; error UI mocks only;
// exact production read/identity/restore/write/sync slice + exact conversion/write helpers below.
// Only production path expression is replaced with testCodexDir. Config restore is a no-op.
extension Notification.Name { static let codexSubscriptionAccountActivating = Notification.Name("codexSubscriptionAccountActivating") }
struct Settings { func t(_ en: String, _ zh: String) -> String { en } }
enum ActivationResult { case failure(String) }
enum SensitiveDataRedactor { static func redactedMessage(for error: Error) -> String { String(describing: error) } }
enum SharedFormatters { static func iso8601String(from date: Date) -> String { ISO8601DateFormatter().string(from: date) } }
final class CodexConfigManager { static let shared = CodexConfigManager(); var restoreCount = 0; func restore() throws { restoreCount += 1 } }
struct Target { let authFileURL: URL; let expectedIdentity: CodexAccountIdentity }
final class Harness {
    let settings = Settings()
    var activationResult: ActivationResult?
    var codexActivationResult: ActivationResult?
    let codexSwitchGeneration: UInt64 = 0
    func allKnownCodexOwnerHashes(excluding: String?) -> Set<String> { [] }
    func activateSlice(selected: Target, testCodexDir: String) throws {
        let fm = FileManager.default
        let resolved = selected.authFileURL.path
        let codexDir = testCodexDir
        let targetPath = "\(codexDir)/auth.json"
        let sourceData = try Data(contentsOf: selected.authFileURL)
        let nativeData = try convertToCodexNativeFormat(sourceData)
        let expectedIdentity = selected.expectedIdentity
''' + act_slice + r'''
    }
    func reapplySlice(selected: Target, testCodexDir: String) async throws {
        let fm = FileManager.default
        let genBefore: UInt64 = 0
        for _ in 0..<1 {
''' + slice + r'''
        }
    }
''' + helpers + r'''
}
@main struct Probe {
    static func main() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("restart-token-review-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        func jwt(_ payload: [String: Any]) throws -> String {
            let b64 = try JSONSerialization.data(withJSONObject: payload).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            return "e30.\(b64).sig"
        }
        let id = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "account-A", "chatgpt_user_id": "user-A"], "email": "synthetic@example.invalid"])
        func auth(_ refresh: String, _ date: String) -> [String: Any] {
            ["auth_mode": "chatgpt", "tokens": ["id_token": id, "access_token": id, "account_id": "account-A", "refresh_token": refresh], "last_refresh": date]
        }
        let old = auth("synthetic-old-rotated-refresh", "2026-11-01T00:00:00Z")
        let new = auth("synthetic-new-valid-refresh", "2026-11-08T00:00:00Z")
        let managed = dir.appendingPathComponent("managed-account.json")
        let live = dir.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: old).write(to: managed)
        try JSONSerialization.data(withJSONObject: new).write(to: live)
        let identity = CodexAccountIdentity(authJSON: old)
        precondition(identity.matches(CodexAccountIdentity(authJSON: new)))
        try await Harness().reapplySlice(selected: Target(authFileURL: managed, expectedIdentity: identity), testCodexDir: dir.path)
        func refresh(_ path: URL) throws -> String {
            let json = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
            return (json["tokens"] as! [String: Any])["refresh_token"] as! String
        }
        let liveRefresh = try refresh(live)
        let backupRefresh = try refresh(dir.appendingPathComponent("auth.json.bak"))
        let managedRefresh = try refresh(managed)
        precondition(liveRefresh == "synthetic-new-valid-refresh")
        precondition(backupRefresh == "synthetic-new-valid-refresh")
        precondition(managedRefresh == "synthetic-new-valid-refresh")
        print("VERIFIED: same-identity restart preserves newer live refresh token in auth.json and heals managed copy")

        // Ensure a newer foreign-identity live auth.json is NEVER preserved when restarting into account-A
        let foreignId = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "account-B", "chatgpt_user_id": "user-B"], "email": "foreign@example.invalid"])
        let foreignAuth: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["id_token": foreignId, "access_token": foreignId, "account_id": "account-B", "refresh_token": "synthetic-foreign-refresh"], "last_refresh": "2026-11-09T00:00:00Z"]
        try JSONSerialization.data(withJSONObject: foreignAuth).write(to: live)
        try await Harness().reapplySlice(selected: Target(authFileURL: managed, expectedIdentity: identity), testCodexDir: dir.path)
        let liveAfterForeign = try refresh(live)
        let backupAfterForeign = try refresh(dir.appendingPathComponent("auth.json.bak"))
        precondition(liveAfterForeign == "synthetic-new-valid-refresh")
        precondition(backupAfterForeign == "synthetic-foreign-refresh")
        print("VERIFIED: foreign-identity live credential is replaced by selected account-A and backed up to auth.json.bak")

        // Ensure a conflicting dual-group managed baseline fails closed on restart/switch without overwriting live auth.json
        let mixedManaged: [String: Any] = [
            "auth_mode": "chatgpt",
            "access_token": id, "id_token": id, "refresh_token": "synthetic-flat-A", "account_id": "account-A",
            "flat_last_refresh": "2026-11-07T00:00:00Z",
            "tokens": [
                "access_token": id, "id_token": foreignId, "refresh_token": "synthetic-nested-conflict-B", "account_id": "account-A",
                "last_refresh": "2026-11-10T00:00:00Z"
            ]
        ]
        let badManaged = dir.appendingPathComponent("bad-managed-account.json")
        try JSONSerialization.data(withJSONObject: mixedManaged).write(to: badManaged)
        let liveBytesBeforeBadBaseline = try Data(contentsOf: live)
        let backupBytesBeforeBadBaseline = try Data(contentsOf: dir.appendingPathComponent("auth.json.bak"))
        let restoresBeforeBadBaseline = CodexConfigManager.shared.restoreCount
        var didThrowActivateMismatch = false
        do {
            try Harness().activateSlice(selected: Target(authFileURL: badManaged, expectedIdentity: identity), testCodexDir: dir.path)
        } catch let err as ProviderError {
            didThrowActivateMismatch = (err.code == "account_mismatch")
        }
        var didThrowMismatch = false
        do {
            try await Harness().reapplySlice(selected: Target(authFileURL: badManaged, expectedIdentity: identity), testCodexDir: dir.path)
        } catch let err as ProviderError {
            didThrowMismatch = (err.code == "account_mismatch")
        }
        let liveBytesAfterBadBaseline = try Data(contentsOf: live)
        let backupBytesAfterBadBaseline = try Data(contentsOf: dir.appendingPathComponent("auth.json.bak"))
        precondition(didThrowActivateMismatch)
        precondition(didThrowMismatch)
        precondition(CodexConfigManager.shared.restoreCount == restoresBeforeBadBaseline)
        precondition(liveBytesAfterBadBaseline == liveBytesBeforeBadBaseline)
        precondition(backupBytesAfterBadBaseline == backupBytesBeforeBadBaseline)
        print("VERIFIED: invalid conflicting managed baseline aborts both activate and restart before config/auth writes")
        print("PASS: 10 isolated assertions; production source slices, temporary synthetic files only")
    }
}
'''
# Raw Python blocks intentionally contain Swift interpolation: remove extra escaping used in generation.
code = code.replace(chr(92) * 2 + '(', chr(92) + '(')
(root / 'artifacts/restart-ui-review-2026-11-08/StaleRestartTokenProbe.swift').write_text(code)
