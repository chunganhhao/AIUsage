import CryptoKit
import Foundation
import Network
import os.log

public enum QuotaServerHealthProof {
    public static let challengeHeader = "X-AIUsage-Health-Challenge"

    public static func compute(challenge: String, startupToken: String) -> String? {
        let trimmedChallenge = challenge.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = startupToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedChallenge.isEmpty, !trimmedToken.isEmpty else { return nil }
        let key = SymmetricKey(data: Data(trimmedToken.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(trimmedChallenge.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

private let shareLog = Logger(subsystem: "com.aiusage.desktop", category: "QuotaShare")

// MARK: - Quota Share Server
// 宿主 App 进程内的只读额度共享服务：把宿主当前已显示的额度快照提供给同一 tailnet / 局域网里
// 处于「远程」后端模式的其它 AIUsage。请求只读取宿主内存里的快照，绝不触发上游抓取或 OAuth 刷新——
// 多台设备读取不会叠加账号登录 / refresh_token 轮换（两个进程各自刷新同一 refresh_token 会互相作废）。
//
// 访问边界：只接受回环、Tailscale（100.64.0.0/10、fd7a:115c:a1e0::/48）与私有局域网来源，
// 且 /api/dashboard 必须携带 `Authorization: Bearer <token>`。不发 CORS 头：这不是给浏览器用的接口。

public final class QuotaShareServer: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case running(port: Int)
        case failed(message: String, portInUse: Bool)
    }

    /// 返回 `/api/dashboard` 的 JSON；`providerIds` 为 nil 表示不过滤。返回 nil 表示宿主尚未完成首次加载。
    public typealias SnapshotProvider = @Sendable (_ providerIds: [String]?) -> Data?

    static let maxHeaderBytes = 16 * 1024
    static let requestTimeoutSeconds: Double = 10

    private let requestedPort: Int
    private let token: String
    private let tlsOptions: NWProtocolTLS.Options?
    private let allowPlaintextPrivateLAN: Bool
    private let snapshotProvider: SnapshotProvider
    private let queue = DispatchQueue(label: "com.aiusage.quotashare")
    private var listener: NWListener?
    private var onStateChange: (@Sendable (State) -> Void)?

    public init(
        port: Int,
        token: String,
        tlsOptions: NWProtocolTLS.Options? = nil,
        allowPlaintextPrivateLAN: Bool = false,
        snapshotProvider: @escaping SnapshotProvider
    ) {
        self.requestedPort = port
        self.token = token
        self.tlsOptions = tlsOptions
        self.allowPlaintextPrivateLAN = allowPlaintextPrivateLAN
        self.snapshotProvider = snapshotProvider
    }

    /// 实际监听端口（`port: 0` 时由系统分配，供测试使用）。
    public var boundPort: Int? {
        queue.sync { listener?.port.map { Int($0.rawValue) } }
    }

    public func start(onStateChange: @escaping @Sendable (State) -> Void) {
        queue.sync {
            guard listener == nil else { return }
            self.onStateChange = onStateChange
            onStateChange(.starting)

            guard (0...Int(UInt16.max)).contains(requestedPort),
                  let port = NWEndpoint.Port(rawValue: UInt16(requestedPort)) else {
                onStateChange(.failed(message: "Invalid port \(requestedPort)", portInUse: false))
                return
            }

            let params = tlsOptions.map { NWParameters(tls: $0, tcp: .init()) } ?? NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let listener: NWListener
            do {
                listener = try NWListener(using: params, on: port)
            } catch {
                onStateChange(Self.failedState(for: error))
                return
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let boundPort = listener?.port.map { Int($0.rawValue) } ?? self.requestedPort
                    shareLog.info("Quota share listening on port \(boundPort, privacy: .public)")
                    self.onStateChange?(.running(port: boundPort))
                case .waiting(let error):
                    // 网络暂不可用时监听器会自行恢复到 .ready，这里只上报、不拆除。
                    self.onStateChange?(Self.failedState(for: error))
                case .failed(let error):
                    shareLog.error("Quota share listener failed: \(error.localizedDescription, privacy: .public)")
                    self.onStateChange?(Self.failedState(for: error))
                    listener?.cancel()
                    if self.listener === listener { self.listener = nil }
                default:
                    break
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.stateUpdateHandler = nil
            listener?.newConnectionHandler = nil
            listener?.cancel()
            listener = nil
            onStateChange?(.stopped)
            onStateChange = nil
        }
    }

    static func failedState(for error: Error) -> State {
        if case .posix(let code) = error as? NWError, code == .EADDRINUSE {
            return .failed(message: error.localizedDescription, portInUse: true)
        }
        return .failed(message: error.localizedDescription, portInUse: false)
    }

    // MARK: - Connection Handling

    private func accept(_ connection: NWConnection) {
        let allowPrivateLAN = tlsOptions != nil || allowPlaintextPrivateLAN
        guard case .hostPort(let host, _) = connection.endpoint,
              Self.isAllowedPeer(host, allowPrivateLAN: allowPrivateLAN) else {
            shareLog.notice("Quota share rejected connection from \(String(describing: connection.endpoint), privacy: .private)")
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        let timeout = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.requestTimeoutSeconds, execute: timeout)
        receive(on: connection, buffer: Data(), timeout: timeout)
    }

    private func receive(on connection: NWConnection, buffer: Data, timeout: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: Self.maxHeaderBytes) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = RequestHead.parse(buffer) {
                timeout.cancel()
                self.send(self.response(for: request), on: connection)
            } else if buffer.count > Self.maxHeaderBytes {
                timeout.cancel()
                self.send(Response.json(status: 431, ["error": "Request header too large"]), on: connection)
            } else if isComplete || error != nil {
                timeout.cancel()
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer, timeout: timeout)
            }
        }
    }

    private func send(_ response: Response, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Routing

    func response(for request: RequestHead) -> Response {
        switch request.path {
        case "/health", "/api/health":
            guard request.method == "GET" else { return Response.methodNotAllowed }
            return Response.json(status: 200, [
                "ok": true,
                "service": "aiusage-share",
                "generatedAt": SharedFormatters.iso8601String(from: Date()),
            ])

        case "/api/dashboard":
            guard request.method == "GET" else { return Response.methodNotAllowed }
            guard isAuthorized(request) else {
                return Response.json(status: 401, ["error": "Missing or invalid access token"])
            }
            let ids = request.query["ids"]?
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard let body = snapshotProvider(ids) else {
                return Response.json(status: 503, ["error": "The host has not finished loading quota data yet"])
            }
            return Response(status: 200, contentType: "application/json", body: body)

        default:
            return Response.json(status: 404, ["error": "Not found"])
        }
    }

    private func isAuthorized(_ request: RequestHead) -> Bool {
        guard let header = request.headers["authorization"] else { return false }
        let parts = header.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, parts[0].lowercased() == "bearer" else { return false }
        return Self.constantTimeEquals(
            Array(parts[1].trimmingCharacters(in: .whitespaces).utf8),
            Array(token.utf8)
        )
    }

    public static func constantTimeEquals(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        guard !rhs.isEmpty, lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }

    // MARK: - Peer Policy

    /// Plaintext defaults allow loopback (`127.0.0.0/8`, `::1`) ONLY; shared CGNAT (`100.64.0.0/10`,
    /// which can overlap with non-Tailscale VPNs) and RFC1918/link-local peers require TLS (`tlsOptions != nil`).
    public static func isAllowedPeer(_ host: NWEndpoint.Host, allowPrivateLAN: Bool = false) -> Bool {
        switch host {
        case .ipv4(let address):
            return isAllowedIPv4(Array(address.rawValue), allowPrivateLAN: allowPrivateLAN)
        case .ipv6(let address):
            if let mapped = address.asIPv4 {
                return isAllowedIPv4(Array(mapped.rawValue), allowPrivateLAN: allowPrivateLAN)
            }
            return isAllowedIPv6(Array(address.rawValue), allowPrivateLAN: allowPrivateLAN)
        default:
            return false
        }
    }

    private static func isAllowedIPv4(_ bytes: [UInt8], allowPrivateLAN: Bool) -> Bool {
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (127, _): return true                      // loopback
        case (100, 64...127), (10, _), (172, 16...31), (192, 168), (169, 254):
            return allowPrivateLAN
        default: return false
        }
    }

    private static func isAllowedIPv6(_ bytes: [UInt8], allowPrivateLAN: Bool) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) && bytes[15] == 1 { return true }      // ::1
        if bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11
            && bytes[3] == 0x5c && bytes[4] == 0xa1 && bytes[5] == 0xe0 {
            return allowPrivateLAN                                                       // ULA fd7a:115c:a1e0::/48 requires TLS
        }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return allowPrivateLAN }     // fe80::/10 link-local
        if (bytes[0] & 0xfe) == 0xfc { return allowPrivateLAN }                          // fc00::/7 ULA
        return false
    }

    // MARK: - HTTP Primitives

    struct RequestHead: Equatable {
        let method: String
        let path: String
        let query: [String: String]
        /// 键已小写。
        let headers: [String: String]

        /// 头部未收全时返回 nil；本服务只处理无 body 的 GET，所以忽略头部之后的字节。
        static func parse(_ data: Data) -> RequestHead? {
            guard let terminator = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[data.startIndex..<terminator.lowerBound], encoding: .utf8) else {
                return nil
            }
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ")
            guard requestLine.count >= 2 else {
                return RequestHead(method: "", path: "", query: [:], headers: [:])
            }

            let target = String(requestLine[1])
            let components = URLComponents(string: target)
            var query: [String: String] = [:]
            for item in components?.queryItems ?? [] {
                query[item.name] = item.value ?? ""
            }

            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }

            return RequestHead(
                method: String(requestLine[0]).uppercased(),
                path: components?.path ?? target,
                query: query,
                headers: headers
            )
        }
    }

    struct Response {
        let status: Int
        let contentType: String
        let body: Data

        static let methodNotAllowed = Response.json(status: 405, ["error": "Method not allowed"])

        static func json(status: Int, _ object: [String: Any]) -> Response {
            let body = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
            return Response(status: status, contentType: "application/json", body: body)
        }

        func serialized() -> Data {
            var head = "HTTP/1.1 \(status) \(Self.reasonPhrase(status))\r\n"
            head += "Content-Type: \(contentType)\r\n"
            head += "Content-Length: \(body.count)\r\n"
            head += "Cache-Control: no-store\r\n"
            head += "Connection: close\r\n\r\n"
            return Data(head.utf8) + body
        }

        private static func reasonPhrase(_ status: Int) -> String {
            switch status {
            case 200: return "OK"
            case 401: return "Unauthorized"
            case 404: return "Not Found"
            case 405: return "Method Not Allowed"
            case 431: return "Request Header Fields Too Large"
            case 503: return "Service Unavailable"
            default: return "Status"
            }
        }
    }
}
