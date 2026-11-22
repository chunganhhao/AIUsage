import Darwin
import Foundation
import QuotaBackend

private final class SameOriginRedirectDelegate: NSObject, URLSessionTaskDelegate {
    nonisolated override init() { super.init() }

    nonisolated func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let allowed = APIService.shouldFollowRedirect(from: task.originalRequest?.url, to: request.url)
        completionHandler(allowed ? request : nil)
    }
}

class APIService {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let shared = APIService()
    
    private var baseURL: String
    private var accessToken: String?
    private let transport: Transport

    init(baseURL: String, accessToken: String?, transport: @escaping Transport) {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        self.baseURL = trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
        self.accessToken = accessToken?.nilIfBlank
        self.transport = transport
    }
    
    private convenience init() {
        let defaults = UserDefaults.standard
        let host = defaults.string(forKey: DefaultsKey.remoteHost) ?? "127.0.0.1"
        let port = defaults.integer(forKey: DefaultsKey.remotePort) == 0 ? 4318 : defaults.integer(forKey: DefaultsKey.remotePort)
        let initialURL = AppSettings.remoteBaseURL(host: host, port: port)
        let initialToken = QuotaShareTokenStore.load(.remote)
        
        // 远程主机是 Tailscale / 局域网直连地址：必须绕过系统 HTTP 代理（Clash 等），
        // 否则代理连不上 100.x 地址会回一个误导性的 502。快照也不能走 URLCache。
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        let session = URLSession(configuration: config, delegate: SameOriginRedirectDelegate(), delegateQueue: nil)
        self.init(baseURL: initialURL, accessToken: initialToken) { try await session.data(for: $0) }
    }

    nonisolated static func isAllowedRemoteURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              let host = url.host,
              !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        if scheme == "http" { return isLoopbackHost(host) }
        return false
    }

    nonisolated static func isLoopbackHost(_ rawHost: String?) -> Bool {
        guard var host = rawHost?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty else {
            return false
        }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        var addr4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            return withUnsafeBytes(of: addr4.s_addr) { $0[0] == 127 }
        }
        var addr6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            let bytes = withUnsafeBytes(of: addr6) { Array($0) }
            let isIPv6Loopback = bytes.count == 16 && bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let isMappedIPv4Loopback = bytes.count == 16
                && bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xff && bytes[11] == 0xff
                && bytes[12] == 127
            return isIPv6Loopback || isMappedIPv4Loopback
        }
        return false
    }

    nonisolated static func shouldFollowRedirect(from originalURL: URL?, to redirectURL: URL?) -> Bool {
        guard let originalURL,
              let redirectURL,
              isAllowedRemoteURL(redirectURL),
              isSameOrigin(originalURL, redirectURL) else {
            return false
        }
        return true
    }

    nonisolated static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let lScheme = lhs.scheme?.lowercased(),
              let rScheme = rhs.scheme?.lowercased(),
              let lHost = lhs.host?.lowercased(),
              let rHost = rhs.host?.lowercased() else {
            return false
        }
        let lPort = lhs.port ?? (lScheme == "https" ? 443 : 80)
        let rPort = rhs.port ?? (rScheme == "https" ? 443 : 80)
        return lScheme == rScheme && lHost == rHost && lPort == rPort
    }

    func updateBaseURL(_ url: String) {
        self.baseURL = url.hasSuffix("/") ? String(url.dropLast()) : url
    }

    func updateAccessToken(_ token: String?) {
        accessToken = token?.nilIfBlank
    }
    
    // MARK: - Dashboard API
    
    func fetchDashboard(providerIds: [String] = []) async throws -> DashboardResponse {
        guard var components = URLComponents(string: "\(baseURL)/api/dashboard") else {
            throw APIError.invalidURL
        }
        if !providerIds.isEmpty {
            components.queryItems = [
                URLQueryItem(name: "ids", value: providerIds.joined(separator: ","))
            ]
        }
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        return try await decode(DashboardResponse.self, from: url)
    }
    
    func fetchProviders(_ providerId: String) async throws -> [ProviderData] {
        let results = try await fetchProviderResults(providerId)
        return results.map(\.summary)
    }

    func fetchProviderResults(_ providerId: String) async throws -> [ProviderWrapper] {
        let dashboard = try await fetchDashboard(providerIds: [providerId])
        return dashboard.providers
    }
    
    func checkHealth() async throws -> HealthResponse {
        guard let url = URL(string: "\(baseURL)/health") else {
            throw APIError.invalidURL
        }
        let data = try await requestData(from: url)
        let decoder = JSONDecoder()

        do {
            return try decoder.decode(HealthResponse.self, from: data)
        } catch let decodeError {
            if let legacy = try? decoder.decode(LegacyHealthResponse.self, from: data) {
                return HealthResponse(
                    ok: legacy.status?.lowercased() == "ok",
                    generatedAt: legacy.time ?? SharedFormatters.iso8601String(from: Date())
                )
            }
            throw APIError.decodingError(decodeError)
        }
    }

    private func requestData(from url: URL) async throws -> Data {
        guard Self.isAllowedRemoteURL(url) else {
            throw APIError.insecureTransport
        }

        var request = URLRequest(url: url)
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch let error as URLError {
            throw APIError.networkError(error, host: url.host.map { "\($0):\(url.port ?? 80)" } ?? baseURL)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        if let finalURL = httpResponse.url, !Self.isSameOrigin(url, finalURL) {
            throw APIError.insecureTransport
        }

        switch httpResponse.statusCode {
        case 200...299:
            return data
        case 300...399:
            throw APIError.insecureTransport
        case 401, 403:
            throw APIError.unauthorized
        case 503:
            throw APIError.hostNotReady
        case 404 where url.path == "/api/dashboard":
            throw APIError.notQuotaShare
        default:
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from url: URL) async throws -> T {
        let data = try await requestData(from: url)

        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw APIError.decodingError(error)
        }
    }
}

// MARK: - Helper Models

struct HealthResponse: Decodable {
    let ok: Bool
    let generatedAt: String

    init(ok: Bool, generatedAt: String) {
        self.ok = ok
        self.generatedAt = generatedAt
    }
}

private struct LegacyHealthResponse: Decodable {
    let status: String?
    let time: String?
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidResponse
    case invalidURL
    case httpError(statusCode: Int)
    case decodingError(Error)
    case networkError(URLError, host: String)
    case unauthorized
    case hostNotReady
    case notQuotaShare
    case insecureTransport
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return AppSettings.localized("Invalid server response", "服务器响应无效")
        case .invalidURL:
            return AppSettings.localized("Invalid server URL", "服务器地址无效")
        case .httpError(let code):
            return AppSettings.localized("HTTP error: \(code)", "HTTP 错误：\(code)")
        case .decodingError(let error):
            return AppSettings.localized(
                "Failed to parse data: \(error.localizedDescription)",
                "数据解析失败：\(error.localizedDescription)"
            )
        case .unauthorized:
            return AppSettings.localized(
                "The host rejected the access token. Copy the token again from the host's Settings → Data & Refresh.",
                "主机拒绝了访问令牌。请到主机的「设置 → 数据与刷新」重新复制令牌。"
            )
        case .hostNotReady:
            return AppSettings.localized(
                "The host is still loading quota data. Try again in a moment.",
                "主机仍在加载额度数据，请稍后再试。"
            )
        case .notQuotaShare:
            return AppSettings.localized(
                "Something answered on this port, but it is not AIUsage quota sharing. Check the port shown on the host.",
                "该端口有服务响应，但不是 AIUsage 额度共享。请核对主机上显示的端口。"
            )
        case .insecureTransport:
            return AppSettings.localized(
                "Plaintext HTTP is only allowed for loopback addresses (127.0.0.1 / ::1). Use https:// (such as Tailscale Serve) or a loopback tunnel for remote hosts.",
                "明文 HTTP 仅允许用于本机回环地址（127.0.0.1 / ::1）。远程主机请使用 https://（例如 Tailscale Serve）或回环隧道。",
                "HTTP không mã hóa chỉ được phép cho địa chỉ loopback (127.0.0.1 / ::1). Hãy dùng https:// (như Tailscale Serve) hoặc đường hầm loopback cho máy chủ từ xa."
            )
        case .networkError(let error, let host):
            switch error.code {
            case .cannotConnectToHost, .networkConnectionLost:
                return AppSettings.localized(
                    "Cannot connect to \(host). Make sure AIUsage is running on the host with \"Share with other devices\" turned on, and the port matches.",
                    "无法连接 \(host)。请确认主机上的 AIUsage 正在运行并已开启「共享给其他设备」，且端口一致。"
                )
            case .timedOut:
                return AppSettings.localized(
                    "Connection to \(host) timed out. Make sure both devices are online in Tailscale (or on the same network).",
                    "连接 \(host) 超时。请确认两台设备都已连上 Tailscale（或在同一局域网）。"
                )
            case .cannotFindHost, .dnsLookupFailed:
                return AppSettings.localized(
                    "Host \(host) was not found. Check the address.",
                    "找不到主机 \(host)，请检查地址。"
                )
            default:
                return AppSettings.localized(
                    "Network error: \(error.localizedDescription)",
                    "网络错误：\(error.localizedDescription)"
                )
            }
        }
    }
}
