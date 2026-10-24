import Foundation

// MARK: - Codex Global Config
// Codex 版「通用配置基底」，存于 ~/.config/aiusage/codex-global-config.json。
// 与 Claude 的 GlobalConfig 心智一致：启用后，激活或保存当前配置时把这份 TOML 基底片段
// 与节点的额外 TOML 按顶层键合并（节点键覆盖全局同名键），外科式注入 ~/.codex/config.toml。
//
// 之所以存为 JSON 而非 .toml：仅做容器（保存原文文本 + 开关），原文本身才是 TOML，
// 由 CodexConfigManager 负责合并/注入；这样与现有 NodeProfileStore 的 JSON 持久化方式一致。

struct CodexGlobalConfig: Codable, Equatable {
    var enabled: Bool
    var tomlText: String

    static let empty = CodexGlobalConfig(enabled: false, tomlText: "")

    /// 是否存在可注入内容（启用且去空白后非空）。
    var hasContent: Bool {
        enabled && !tomlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func toFileData() throws -> Data {
        try JSONEncoder.profileEncoder.encode(self)
    }

    static func fromFileData(_ data: Data) throws -> CodexGlobalConfig {
        try JSONDecoder.profileDecoder.decode(CodexGlobalConfig.self, from: data)
    }

    /// 粗略统计原文 TOML 的顶层条目数：顶层 `key = value` 行 + `[table]` 头。
    /// 仅用于 UI 摘要展示，忽略注释 / 空行 / 缩进（表内）字段。
    static func topLevelEntryCount(in toml: String) -> Int {
        var count = 0
        for rawLine in toml.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            // 仅统计无前导空白的顶层行（表内缩进字段不计入）
            guard rawLine.first.map({ !$0.isWhitespace }) ?? false else { continue }
            if line.hasPrefix("[") {
                count += 1
            } else if line.contains("=") {
                count += 1
            }
        }
        return count
    }
}
