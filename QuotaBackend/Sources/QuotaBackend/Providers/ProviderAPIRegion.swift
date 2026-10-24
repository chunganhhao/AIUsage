import Foundation

/// MiniMax / Kimi 等海内外分站 API 的区域偏好。
/// 存入 `AccountCredential.metadata["apiRegion"]`；缺省为 `.auto`。
public enum ProviderAPIRegion: String, Codable, CaseIterable, Sendable {
    case auto
    case china
    case international

    public static let metadataKey = "apiRegion"

    public init(metadataValue: String?) {
        let raw = metadataValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        switch raw {
        case Self.china.rawValue, "cn", "domestic":
            self = .china
        case Self.international.rawValue, "global", "intl", "overseas":
            self = .international
        default:
            self = .auto
        }
    }

    /// 实际要尝试的端点：`.auto` 按传入顺序全部尝试；显式区域只试该区域的端点（保持原顺序），
    /// 同一区域有多个端点（如新旧两代接口）时可以在区域内回退。
    public func candidates(_ endpoints: [String], chinaContains: [String], internationalContains: [String]) -> [String] {
        func matches(_ url: String, needles: [String]) -> Bool {
            let lower = url.lowercased()
            return needles.contains { lower.contains($0) }
        }
        switch self {
        case .auto: return endpoints
        case .china: return endpoints.filter { matches($0, needles: chinaContains) }
        case .international: return endpoints.filter { matches($0, needles: internationalContains) }
        }
    }
}
