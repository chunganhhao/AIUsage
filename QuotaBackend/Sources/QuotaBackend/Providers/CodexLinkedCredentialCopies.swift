import Foundation

// MARK: - Codex Linked Credential Copies
// 同一次 Codex 登录在本机可能有多份文件：订阅监控的托管副本，以及复制给 CPA 网关的副本。
// Codex 的 refresh_token 只能用一次，各副本各自刷新会互相作废，所以刷新时把它们当作
// 同一条凭据：先采用签发时间最新的一份，刷新后写回全部副本。

public enum CodexLinkedCredentialCopies {
    private static let lock = NSLock()
    private static var directories: [String] = []

    /// 登记存放副本的目录（如 AIUsage 内置 CPA 的 auth 目录）。
    /// 副本靠 AIUsage 复制时写入的 `aiusage_credential_id` 归属标记关联到具体凭据。
    public static func registerDirectory(_ directory: URL) {
        let path = directory.standardizedFileURL.path
        lock.withLock {
            if !directories.contains(path) { directories.append(path) }
        }
    }

    static func resetForTesting() {
        lock.withLock { directories = [] }
    }

    /// 已登记目录中归属于该凭据的副本路径。
    static func paths(forCredentialId credentialId: String) -> [String] {
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
                .filter { ownerCredentialId(of: $0).map(normalized) == id }
                .map(\.path)
        }
    }

    private static func ownerCredentialId(of url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let tokens = json["tokens"] as? [String: Any]
        return (json["aiusage_credential_id"] ?? tokens?["aiusage_credential_id"]) as? String
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
