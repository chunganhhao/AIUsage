import Foundation

// MARK: - OpenCode Data Discovery
// 解析 OpenCode 数据目录并为 opencode.db 制作临时只读快照。
// 目录优先级与 OpenCode 的 Global.Path.data 对齐：
//   1. $XDG_DATA_HOME/opencode
//   2. ~/.local/share/opencode（CLI 默认，含 macOS）
//   3. ~/Library/Application Support/opencode（桌面版 fallback）
// OpenCode 运行中可能持续写库（WAL），故复制 db/-wal/-shm 后再以只读模式打开，避免锁冲突。

extension OpenCodeCostProvider {

    static let databaseFilename = "opencode.db"

    /// 返回第一个包含 opencode.db 的数据目录；OpenCode 未安装或版本 < 1.2 时为 nil。
    func resolveDataDirectory() -> String? {
        var candidates: [String] = []
        if let xdgDataHome = environment["XDG_DATA_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !xdgDataHome.isEmpty {
            candidates.append((xdgDataHome as NSString).appendingPathComponent("opencode"))
        }
        candidates.append((homeDirectory as NSString).appendingPathComponent(".local/share/opencode"))
        candidates.append((homeDirectory as NSString).appendingPathComponent("Library/Application Support/opencode"))

        return candidates.first { directory in
            FileManager.default.fileExists(
                atPath: (directory as NSString).appendingPathComponent(Self.databaseFilename)
            )
        }
    }

    /// 把 db / -wal / -shm 复制到 0700 私有临时目录，返回快照 db 路径。wal/shm 容忍缺失。
    func makeDatabaseSnapshot(dataDirectory: String) throws -> String {
        try makeOpenCodeDatabaseSnapshot(
            dataDirectory: dataDirectory,
            databaseFilename: Self.databaseFilename,
            prefix: "aiusage-opencode",
            environment: environment
        )
    }

    func cleanupDatabaseSnapshot(_ snapshotPath: String) {
        cleanupOpenCodeDatabaseSnapshot(snapshotPath, expectedDirectoryPrefix: "aiusage-opencode-")
    }
}
