import Darwin
import Foundation
import SQLite3

// MARK: - OpenCode Storage（版本无关数据访问）
// 把 opencode v1/v2 的本地数据 schema 差异收敛到各自的 reader（OpenCodeV1Storage / OpenCodeV2Storage），
// 业务层（用量统计 / 节点统计 / 调用分析 / 凭据接管）只依赖本协议 + 统一领域模型，不感知版本。
// 新增 v3 时只需新增 OpenCodeV3Storage 文件并扩展 resolveOpenCodeStorage() 路由，不触碰 v1/v2 实现。

// MARK: - 领域模型

/// 一条 assistant 消息（reader 保证只返回 assistant：v1 解析后过滤 / v2 SQL 层过滤）。
public struct OpenCodeMessage: Sendable, Equatable {
    public let id: String
    public let sessionId: String
    public let timeCreatedMillis: Int64
    /// 归一化 providerID：v1 顶层 providerID / v2 model.providerID。
    public let providerID: String?
    /// 归一化 modelID：v1 顶层 modelID / v2 model.id。
    public let modelID: String?
    public let inputTokens: Int
    public let outputTokens: Int
    /// v2 独立 reasoning token；v1 恒 0。
    public let reasoningTokens: Int
    public let cacheReadTokens: Int
    public let cacheCreateTokens: Int
    public let costUsd: Double
    /// data.time.completed - created（epoch 毫秒）；任一缺失为 nil。
    public let durationMs: Int?

    public var totalTokens: Int {
        inputTokens + outputTokens + reasoningTokens + cacheReadTokens + cacheCreateTokens
    }

    /// 模型名口径 `providerID/modelID`（保留 OpenCode 内部供应商维度）。
    public var modelLabel: String {
        let provider = providerID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let model = modelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch (provider.isEmpty, model.isEmpty) {
        case (false, false): return "\(provider)/\(model)"
        case (true, false):  return model
        case (false, true):  return provider
        case (true, true):   return "unknown"
        }
    }
}

/// 一次工具调用（reader 从 v1 part 表 / v2 message.data.content 提取后归一化）。
public struct OpenCodeToolCall: Sendable, Equatable {
    public let id: String
    /// 工具名：v1 `tool` / v2 `name`。
    public let name: String
    /// 工具调用时间（epoch 毫秒）：v1 part.time_created / v2 tool.time.created（缺失回退 message.time_created）。
    public let timeCreatedMillis: Int64
    /// 状态：completed/error/running/streaming 等（原样小写）。
    public let status: String?
    /// 耗时（毫秒）：v1 state.time.{start,end} / v2 time.{ran,completed}（ran 缺失则 created→completed）。
    public let durationMs: Double?
    /// state.input.name（skill 名，仅 skill 工具调用有值）。
    public let inputName: String?
}

/// message 查询条件（CostProvider 用增量 sinceMillis，NodeStats 用 dataLike 预过滤）。
public struct OpenCodeMessageQuery: Sendable {
    public var sinceMillis: Int64?
    public var dataLike: String?

    public init(sinceMillis: Int64? = nil, dataLike: String? = nil) {
        self.sinceMillis = sinceMillis
        self.dataLike = dataLike
    }
}

// MARK: - 协议

public protocol OpenCodeStorage: Sendable {
    var schema: OpenCodeSchema { get }

    /// 读 assistant 消息。dbPath 为快照 db 路径，调用方负责 resolve + 快照生命周期。
    func fetchMessages(dbPath: String, query: OpenCodeMessageQuery) throws -> [OpenCodeMessage]

    /// 读工具调用。dbPath 为快照 db 路径。
    func fetchToolCalls(dbPath: String, sinceMillis: Int64?) throws -> [OpenCodeToolCall]

    /// 读全部凭据（providerID → key）。
    func loadAllCredentials() -> [String: String]

    /// 写入/覆盖单个凭据；失败返回 false（调用方回退内联 key）。
    @discardableResult
    func upsertCredential(providerID: String, key: String) -> Bool

    /// 删除单个凭据；失败返回 false。
    @discardableResult
    func deleteCredential(providerID: String) -> Bool

    /// 参与配置文件事务的凭据路径（v1 为 auth.json；v2 凭据在 opencode.db 内，返回空）。
    var credentialFilePaths: [String] { get }
}

// MARK: - 凭证快照/恢复

public extension OpenCodeStorage {
    /// 快照匹配 `predicate` 的凭据（providerID → key），供激活/停用事务失败时回滚。
    /// v2 凭据在 opencode.db 内、不在文件事务保护范围，操作前快照、失败后据此恢复。
    func snapshotCredentials(matching predicate: (String) -> Bool) -> [String: String] {
        Dictionary(uniqueKeysWithValues: loadAllCredentials().filter { predicate($0.key) })
    }

    /// 让匹配 `predicate` 的凭据恰好等于 `snapshot`：删除其余匹配项、写回快照，非匹配项保留。
    /// 返回是否全部成功；任一失败也继续处理剩余项并最终返回 false。
    @discardableResult
    func restoreCredentials(_ snapshot: [String: String], matching predicate: (String) -> Bool) -> Bool {
        let existing = loadAllCredentials()
        var allSucceeded = true
        for providerId in existing.keys where predicate(providerId) {
            if !deleteCredential(providerID: providerId) { allSucceeded = false }
        }
        for (providerId, apiKey) in snapshot where !apiKey.isEmpty {
            if !upsertCredential(providerID: providerId, key: apiKey) { allSucceeded = false }
        }
        return allSucceeded
    }
}

// MARK: - 路由

/// 按本机 opencode 版本返回对应 reader。探测失败回退 v1（唯一正式版）。
public func resolveOpenCodeStorage(
    homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
    environment: [String: String] = ProcessInfo.processInfo.environment
) -> OpenCodeStorage {
    switch detectOpenCodeSchema() {
    case .v2:
        return OpenCodeV2Storage(homeDirectory: homeDirectory, environment: environment)
    case .v1:
        return OpenCodeV1Storage(homeDirectory: homeDirectory, environment: environment)
    }
}

/// 解析 opencode 数据目录（版本无关，供 credential 读写用）。
/// 返回第一个已存在的目录；都不存在返回默认（~/.local/share/opencode），写时 createDirectory 兜底。
func resolveOpenCodeDataDirectory(homeDirectory: String, environment: [String: String]) -> String {
    var candidates: [String] = []
    if let xdg = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines), !xdg.isEmpty {
        candidates.append((xdg as NSString).appendingPathComponent("opencode"))
    }
    candidates.append((homeDirectory as NSString).appendingPathComponent(".local/share/opencode"))
    candidates.append((homeDirectory as NSString).appendingPathComponent("Library/Application Support/opencode"))
    return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? candidates[1]
}

// MARK: - SQLite 绑定 helper

enum BindValue {
    case int64(Int64)
    case text(String)
}

func bind(_ values: [BindValue], to statement: OpaquePointer?) {
    guard let statement else { return }
    for (index, value) in values.enumerated() {
        let position = Int32(index + 1)
        switch value {
        case .int64(let int):
            sqlite3_bind_int64(statement, position, int)
        case .text(let str):
            sqlite3_bind_text(statement, position, str, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
    }
}

// MARK: - Private SQLite Snapshot Isolation

enum OpenCodeSnapshotIsolation {
    @TaskLocal static var didPrepareSnapshot: (@Sendable (URL) -> Void)?
}

func makeOpenCodeDatabaseSnapshot(
    dataDirectory: String,
    databaseFilename: String = "opencode.db",
    prefix: String,
    environment: [String: String]
) throws -> String {
    let fm = FileManager.default
    let parentURL = TokenSaverSettingsStore.resolvedTemporaryDirectory(overrides: environment)
    let snapshotDirectory = parentURL.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    let sourceDB = (dataDirectory as NSString).appendingPathComponent(databaseFilename)
    let destinationDB = snapshotDirectory.appendingPathComponent(databaseFilename, isDirectory: false).path

    do {
        try fm.createDirectory(at: snapshotDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        if chmod(snapshotDirectory.path, 0o700) != 0 {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var dirStat = stat()
        guard lstat(snapshotDirectory.path, &dirStat) == 0,
              (dirStat.st_mode & S_IFMT) == S_IFDIR,
              dirStat.st_uid == geteuid(),
              (dirStat.st_mode & 0o777) == 0o700 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        }

        try copyPrivateSnapshotFile(from: sourceDB, to: destinationDB, required: true)
        try copyPrivateSnapshotFile(from: sourceDB + "-wal", to: destinationDB + "-wal", required: false)
        try copyPrivateSnapshotFile(from: sourceDB + "-shm", to: destinationDB + "-shm", required: false)
    } catch {
        try? fm.removeItem(at: snapshotDirectory)
        throw ProviderError("db_snapshot_failed", SensitiveDataRedactor.redactedMessage(for: error))
    }

    OpenCodeSnapshotIsolation.didPrepareSnapshot?(snapshotDirectory)
    return destinationDB
}

func cleanupOpenCodeDatabaseSnapshot(_ snapshotPath: String, expectedDirectoryPrefix: String) {
    let fm = FileManager.default
    try? fm.removeItem(atPath: snapshotPath)
    try? fm.removeItem(atPath: snapshotPath + "-wal")
    try? fm.removeItem(atPath: snapshotPath + "-shm")
    let parent = URL(fileURLWithPath: snapshotPath, isDirectory: false).deletingLastPathComponent()
    if parent.lastPathComponent.hasPrefix(expectedDirectoryPrefix) {
        try? fm.removeItem(at: parent)
    }
}

private func copyPrivateSnapshotFile(from sourcePath: String, to destinationPath: String, required: Bool) throws {
    let srcFD = Darwin.open(sourcePath, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
    if srcFD < 0 {
        if !required && errno == ENOENT { return }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { _ = Darwin.close(srcFD) }

    var srcStat = stat()
    guard fstat(srcFD, &srcStat) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    guard (srcStat.st_mode & S_IFMT) == S_IFREG else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
    }
    let srcFlags = fcntl(srcFD, F_GETFL)
    guard srcFlags >= 0, fcntl(srcFD, F_SETFL, srcFlags & ~O_NONBLOCK) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    let dstFD = Darwin.open(destinationPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard dstFD >= 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
    defer { _ = Darwin.close(dstFD) }
    guard fchmod(dstFD, 0o600) == 0 else {
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    var buffer = [UInt8](repeating: 0, count: 65_536)
    try buffer.withUnsafeMutableBytes { rawBuffer in
        guard let base = rawBuffer.baseAddress else { return }
        while true {
            let bytesRead = Darwin.read(srcFD, base, rawBuffer.count)
            if bytesRead == 0 { break }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            var offset = 0
            while offset < bytesRead {
                let written = Darwin.write(dstFD, base.advanced(by: offset), bytesRead - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                offset += written
            }
        }
    }
}
