import Foundation
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
        let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(
            managedNativeData: nativeData,
            managedSourceData: sourceData,
            expectedIdentity: expectedIdentity,
            candidatePaths: [targetPath, "\(targetPath).bak"],
            fm: fm
        )
        guard reconciled.isValidBaseline,
              expectedIdentity.matches(reconciled.identity) else {
            let msg = settings.t(
                "The auth file no longer belongs to this account. Reconnect it before switching.",
                "认证文件已不属于此账号，请重新连接后再切换。"
            )
            activationResult = .failure(msg)
            codexActivationResult = .failure(msg)
            throw ProviderError("account_mismatch", msg)
        }
        let effectiveData = reconciled.nativeData
        let effectiveJSON = reconciled.nativeJSON
        _ = reconciled.identity

        let targetOwnerHash = CodexAccountIdentity.rendererOwnerHash(fromAuthJSON: effectiveJSON)
        let knownOwnerHashes = allKnownCodexOwnerHashes(excluding: targetOwnerHash)

        // 目标账号验证完成后再解除代理接管，避免坏文件让当前可用路由先被停掉。
        // 停进程走通知（异步），但文件必须在写账号之前同步归位，否则异步 restore 会覆盖新账号。
        // 先完成 config.toml 与 auth.json 写入，成功后才更新 .codex-global-state.json，避免切换失败时污染 renderer 状态。
        NotificationCenter.default.post(name: .codexSubscriptionAccountActivating, object: nil)
        try CodexConfigManager.shared.restore()
        try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: effectiveData, fm: fm)
        let managedURL = URL(fileURLWithPath: resolved)
        if reconciled.adoptedLiveCandidate,
           let healedManagedData = reconciled.healedManagedData,
           managedURL.standardizedFileURL.path != URL(fileURLWithPath: targetPath).standardizedFileURL.path,
           fm.contents(atPath: resolved) == sourceData {
            try? healedManagedData.write(to: managedURL, options: .atomic)
        }

        let isCodexRunning = false
        _ = CodexGlobalStateSync.syncWorkspaceProjects(
            codexDir: codexDir,
            targetOwnerHash: targetOwnerHash,
            additionalOwnerHashes: knownOwnerHashes,
            transitionOwner: !isCodexRunning
        )


    }
    func reapplySlice(selected: Target, testCodexDir: String) async throws {
        let fm = FileManager.default
        let genBefore: UInt64 = 0
        for _ in 0..<1 {
            let sourceData = try Data(contentsOf: selected.authFileURL)
            let nativeData = try convertToCodexNativeFormat(sourceData)
            let nativeJSON = try JSONSerialization.jsonObject(with: nativeData) as? [String: Any] ?? [:]
            let nativeIdentity = CodexAccountIdentity(authJSON: nativeJSON)
            guard selected.expectedIdentity.matches(nativeIdentity) else {
                throw ProviderError("account_mismatch", settings.t(
                    "The auth file no longer belongs to this account. Reconnect it before switching.",
                    "认证文件已不属于此账号，请重新连接后再切换。"
                ))
            }

            let codexDir = testCodexDir
            let targetPath = "\(codexDir)/auth.json"
            let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(
                managedNativeData: nativeData,
                managedSourceData: sourceData,
                expectedIdentity: selected.expectedIdentity,
                candidatePaths: [targetPath, "\(targetPath).bak"],
                fm: fm
            )
            guard reconciled.isValidBaseline,
                  selected.expectedIdentity.matches(reconciled.identity) else {
                throw ProviderError("account_mismatch", settings.t(
                    "The auth file no longer belongs to this account. Reconnect it before switching.",
                    "认证文件已不属于此账号，请重新连接后再切换。"
                ))
            }
            let effectiveData = reconciled.nativeData
            let effectiveJSON = reconciled.nativeJSON

            let targetOwnerHash = CodexAccountIdentity.rendererOwnerHash(fromAuthJSON: effectiveJSON)
            let knownOwnerHashes = await MainActor.run { self.allKnownCodexOwnerHashes(excluding: targetOwnerHash) }

            let genMid = await MainActor.run { self.codexSwitchGeneration }
            if genMid != genBefore { continue }

            try CodexConfigManager.shared.restore()
            try writeAuthFileWithBackup(targetDir: codexDir, targetPath: targetPath, data: effectiveData, fm: fm)
            if reconciled.adoptedLiveCandidate,
               let healedManagedData = reconciled.healedManagedData,
               selected.authFileURL.standardizedFileURL.path != URL(fileURLWithPath: targetPath).standardizedFileURL.path,
               fm.contents(atPath: selected.authFileURL.path) == sourceData {
                try? healedManagedData.write(to: selected.authFileURL, options: .atomic)
            }
            _ = CodexGlobalStateSync.syncWorkspaceProjects(
                codexDir: codexDir,
                targetOwnerHash: targetOwnerHash,
                additionalOwnerHashes: knownOwnerHashes,
                transitionOwner: true
            )


        }
    }
    private func convertToCodexNativeFormat(_ data: Data) throws -> Data {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return data
        }

        if json["tokens"] is [String: Any], json["auth_mode"] != nil {
            return data
        }

        guard let accessToken = json["access_token"] as? String,
              let refreshToken = json["refresh_token"] as? String else {
            return data
        }

        var native: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": [
                "access_token": accessToken,
                "refresh_token": refreshToken,
                "account_id": json["account_id"] ?? "",
                "id_token": json["id_token"] ?? ""
            ] as [String: Any],
            "last_refresh": json["last_refresh"] ?? SharedFormatters.iso8601String(from: Date())
        ]
        if let email = json["email"] as? String, !email.isEmpty {
            native["email"] = email
        }
        native["OPENAI_API_KEY"] = NSNull()

        return try JSONSerialization.data(withJSONObject: native, options: [.prettyPrinted, .sortedKeys])
    }
    private func writeAuthFileWithBackup(targetDir: String, targetPath: String, data: Data, fm: FileManager) throws {
        if !fm.fileExists(atPath: targetDir) {
            try fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
        }

        let backupPath = "\(targetPath).bak"
        if fm.fileExists(atPath: targetPath) {
            try? fm.removeItem(atPath: backupPath)
            try fm.copyItem(atPath: targetPath, toPath: backupPath)
        }

        do {
            try data.write(to: URL(fileURLWithPath: targetPath), options: .atomic)
        } catch {
            if fm.fileExists(atPath: backupPath) {
                try? fm.removeItem(atPath: targetPath)
                try? fm.copyItem(atPath: backupPath, toPath: targetPath)
            }
            let redactedError = SensitiveDataRedactor.redactedMessage(for: error)
            let msg = settings.t("Switch failed: \(redactedError)", "切换失败：\(redactedError)")
            activationResult = .failure(msg)
            throw error
        }
    }
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
