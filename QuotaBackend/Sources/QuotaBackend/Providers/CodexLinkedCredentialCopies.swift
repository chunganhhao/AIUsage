import Foundation

// MARK: - Codex Linked Credential Copies
// 同一次 Codex 登录在本机可能有多份文件：订阅监控的托管副本，以及复制给 CPA 网关的副本。
// Codex 的 refresh_token 只能用一次，各副本各自刷新会互相作废，所以刷新时把它们当作
// 同一条凭据：先采用签发时间最新的一份，刷新后写回全部副本。

public enum CodexLinkedCredentialCopies {
    private static let lock = NSLock()
    private static var directories: [String] = []

    /// 登记存放副本的目录（如 AIUsage 内置 CPA 的 auth 目录）。
    /// 只认 AIUsage 复制过去、带 `aiusage_credential_id` 归属标记的文件。
    public static func registerDirectory(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        lock.withLock {
            if !directories.contains(path) { directories.append(path) }
        }
    }

    static func resetForTesting() {
        lock.withLock { directories = [] }
    }

    /// 已登记目录中属于该凭据的副本：标记是这个凭据，或标记是旧凭据但原生身份（工作区 + 用户）相同。
    /// 重新登录会换凭据 ID，CPA 副本上的标记要等用户再次同步才会更新。
    /// 没有标记的文件（CPA 自己登录的账号）是独立的 token 链，不关联。
    static func paths(forCredentialId credentialId: String, nativeIdentityKey: String? = nil) -> [String] {
        let id = normalized(credentialId)
        guard !id.isEmpty else { return [] }
        let registered = lock.withLock { directories }
        return registered.flatMap { directory -> [String] in
            // 用登记时的目录拼路径：枚举结果会解析软链（/var → /private/var），去重时会对不上。
            let root = URL(fileURLWithPath: directory, isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
            return names
                .filter { !$0.hasPrefix(".") && $0.lowercased().hasSuffix(".json") }
                .sorted()
                .map { root.appendingPathComponent($0) }
                .filter { url in
                    guard let json = jsonObject(at: url), let owner = ownerCredentialId(in: json) else { return false }
                    if normalized(owner) == id { return true }
                    guard let nativeIdentityKey else { return false }
                    return CodexAccountIdentity(authJSON: json).nativeKey == nativeIdentityKey
                }
                .map(\.path)
        }
    }

    private static func jsonObject(at url: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func ownerCredentialId(in json: [String: Any]) -> String? {
        let tokens = json["tokens"] as? [String: Any]
        let owner = (json["aiusage_credential_id"] ?? tokens?["aiusage_credential_id"]) as? String
        return owner.map(normalized).flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
