import Foundation
import CoreFoundation
import CryptoKit

/// 查询目标始终是配置的真实上游，不使用本地代理的展示地址。
public struct APIKeyBalanceTarget: Sendable {
    public let rootURL: URL
    let apiKey: String
    public let cacheKey: String

    public init?(baseURL: String, apiKey: String) {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("\n"), !key.contains("\r"),
              var parts = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(parts.scheme?.lowercased() ?? ""),
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil else { return nil }
        parts.scheme = parts.scheme?.lowercased()
        parts.host = host.lowercased()
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
        parts.path = path
        guard let root = parts.url else { return nil }
        self.rootURL = root
        self.apiKey = key
        // 不把 Key 写入日志、UI 标识或持久缓存；同上游同 Key 跨产品共享查询。
        self.cacheKey = SHA256.hash(data: Data((root.absoluteString + "\n" + key).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    public var supportsLookup: Bool {
        !["api.openai.com", "api.anthropic.com"].contains(rootURL.host?.lowercased() ?? "")
    }
}

public struct APIKeyBalanceAmount: Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable { case account, keyLimit }
    public let scope: Scope
    public let remaining: Double?
    /// nil 表示原始额度单位；不得默认套用站点的人民币或美元倍率。
    public let currency: String?
    public let uncapped: Bool

    public init(scope: Scope, remaining: Double?, currency: String?, uncapped: Bool = false) {
        self.scope = scope; self.remaining = remaining; self.currency = currency; self.uncapped = uncapped
    }
}

public struct APIKeyBalanceSnapshot: Sendable, Equatable {
    public enum Status: Sendable, Equatable { case available, unsupported, unauthorized, rateLimited, failed }
    public let status: Status
    public let amounts: [APIKeyBalanceAmount]
    public let checkedAt: Date
    public init(status: Status, amounts: [APIKeyBalanceAmount] = [], checkedAt: Date = Date()) {
        self.status = status; self.amounts = amounts; self.checkedAt = checkedAt
    }
}

/// 只发送免费 GET；不发送模型请求，不读控制台 cookie，不跟随重定向。
/// 成功缓存 5 分钟、不支持缓存 6 小时；失败短暂退避，手动刷新可重新探测。
public actor APIKeyBalanceService {
    private var cache: [String: APIKeyBalanceSnapshot] = [:]
    private var pending: [String: Task<APIKeyBalanceSnapshot, Never>] = [:]
    public init() {}

    public func fetch(_ target: APIKeyBalanceTarget, force: Bool = false) async -> APIKeyBalanceSnapshot {
        if let task = pending[target.cacheKey] { return await task.value }
        if !force, let old = cache[target.cacheKey] {
            let ttl: TimeInterval = old.status == .unsupported ? 21_600 : old.status == .available ? 300 : 60
            if Date().timeIntervalSince(old.checkedAt) < ttl { return old }
        }
        let task = Task { await Self.lookup(target) }
        pending[target.cacheKey] = task
        let result = await task.value
        pending[target.cacheKey] = nil
        if cache.count >= 256, let oldest = cache.min(by: { $0.value.checkedAt < $1.value.checkedAt })?.key {
            cache.removeValue(forKey: oldest)
        }
        cache[target.cacheKey] = result
        return result
    }

    private static func lookup(_ target: APIKeyBalanceTarget) async -> APIKeyBalanceSnapshot {
        guard target.supportsLookup else { return .init(status: .unsupported) }
        let host = target.rootURL.host?.lowercased() ?? ""
        let kind: String
        let endpoint: URL
        if host == "api.deepseek.com" {
            kind = "deepseek"
            endpoint = URL(string: "https://api.deepseek.com/user/balance")!
        } else if host == "openrouter.ai" {
            kind = "openrouter"
            // 官方通常配置 /api/v1；也兼容用户填写站点根地址。
            endpoint = target.rootURL.path.isEmpty
                ? target.rootURL.appendingPathComponent("api/v1/key")
                : target.rootURL.appendingPathComponent("v1/key")
        } else {
            kind = "newapi"
            endpoint = target.rootURL.appendingPathComponent("api/usage/token/")
        }
        do {
            let (json, status) = try await get(endpoint, key: target.apiKey)
            if [404, 405, 501].contains(status) { return .init(status: .unsupported) }
            if [401, 403].contains(status) { return .init(status: .unauthorized) }
            if status == 429 { return .init(status: .rateLimited) }
            guard (200..<300).contains(status), let json else { return .init(status: .failed) }
            let amounts: [APIKeyBalanceAmount]?
            switch kind {
            case "deepseek": amounts = parseDeepSeek(json)
            case "openrouter": amounts = parseOpenRouter(json)
            default:
                guard parseNewAPI(json, metadata: nil) != nil else {
                    let explicitFailure = json["error"] != nil || json["success"] as? Bool == false || json["code"] as? Bool == false
                    return .init(status: explicitFailure ? .failed : .unsupported)
                }
                // 元信息为公开 GET，不附带 Key。读取失败时仍可展示原始额度单位。
                let metadata = try? await get(target.rootURL.appendingPathComponent("api/status"), key: nil)
                amounts = parseNewAPI(json, metadata: metadata.flatMap { (200..<300).contains($0.1) ? $0.0 : nil })
            }
            guard let amounts, !amounts.isEmpty else { return .init(status: .failed) }
            return .init(status: .available, amounts: amounts)
        } catch {
            // 不回显服务端正文、底层错误或包含配置/凭据的地址。
            return .init(status: .failed)
        }
    }

    private static func get(_ url: URL, key: String?) async throws -> ([String: Any]?, Int) {
        var request = QuotaHTTP.request(url: url, timeout: 12)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await QuotaHTTP.data(for: request, allowRedirects: false)
        guard let http = response as? HTTPURLResponse else { return (nil, 0) }
        guard data.count <= 1_048_576 else { return (nil, http.statusCode) }
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any], http.statusCode)
    }

    static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() { result = n.doubleValue }
        else if let s = value as? String { result = Double(s) }
        else { result = nil }
        guard let result, result.isFinite else { return nil }
        return result
    }

    static func parseDeepSeek(_ json: [String: Any]) -> [APIKeyBalanceAmount]? {
        guard json["is_available"] is Bool, let infos = json["balance_infos"] as? [[String: Any]], !infos.isEmpty else { return nil }
        var result: [APIKeyBalanceAmount] = []
        for info in infos {
            guard let currency = info["currency"] as? String, ["USD", "CNY"].contains(currency),
                  let balance = number(info["total_balance"]) else { return nil }
            result.append(.init(scope: .account, remaining: balance, currency: currency))
        }
        return result
    }

    static func parseOpenRouter(_ json: [String: Any]) -> [APIKeyBalanceAmount]? {
        guard json["error"] == nil, let data = json["data"] as? [String: Any] else { return nil }
        let cap = number(data["limit_remaining"])
        let budget = (data["effective_budget"] as? [String: Any]).flatMap { number($0["remaining_usd"]) }
        if let remaining = [cap, budget].compactMap({ $0 }).min() {
            return [.init(scope: .keyLimit, remaining: remaining, currency: "USD")]
        }
        // 明确的 null 才表示 Key 未设限；没有字段不是无限余额。
        if data["limit"] is NSNull, data["limit_remaining"] is NSNull {
            return [.init(scope: .keyLimit, remaining: nil, currency: "USD", uncapped: true)]
        }
        return nil
    }

    static func parseNewAPI(_ json: [String: Any], metadata: [String: Any]?) -> [APIKeyBalanceAmount]? {
        guard json["error"] == nil, json["success"] as? Bool != false, json["code"] as? Bool != false,
              let data = json["data"] as? [String: Any], data["object"] as? String == "token_usage",
              let remaining = number(data["total_available"]) else { return nil }
        var divisor = 1.0
        var multiplier = 1.0
        var currency: String?
        if metadata?["success"] as? Bool == true, let info = metadata?["data"] as? [String: Any],
           let scale = number(info["quota_per_unit"]), scale > 0 {
            switch info["quota_display_type"] as? String {
            case "USD": divisor = scale; currency = "USD"
            case "CNY":
                if let fx = number(info["usd_exchange_rate"]), fx > 0 {
                    divisor = scale; multiplier = fx; currency = "CNY"
                }
            default: break // TOKENS / 自定义币种 / 老站点：不猜币种或倍率。
            }
        }
        func amount(_ raw: Double, scope: APIKeyBalanceAmount.Scope) -> APIKeyBalanceAmount? {
            let value = raw / divisor * multiplier
            return value.isFinite ? .init(scope: scope, remaining: value, currency: currency) : nil
        }
        var result: [APIKeyBalanceAmount] = []
        if let user = data["user_quota"] as? [String: Any], let value = number(user["total_available"]),
           let account = amount(value, scope: .account) { result.append(account) }
        if data["unlimited_quota"] as? Bool == true {
            result.append(.init(scope: .keyLimit, remaining: nil, currency: currency, uncapped: true))
        } else if let key = amount(remaining, scope: .keyLimit) { result.append(key) }
        return result
    }
}
