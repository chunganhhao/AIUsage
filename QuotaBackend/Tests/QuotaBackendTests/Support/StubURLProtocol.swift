import Foundation
@testable import QuotaBackend

/// Answers requests to the installed hosts from canned responses (unmatched URLs
/// get 404) and records every request. `install` covers both transports:
/// providers on `URLSession.shared` (global registration) and providers on
/// `QuotaHTTP` (a custom session, which ignores global registration).
final class StubURLProtocol: URLProtocol {
    struct RecordedRequest {
        let url: String
        let method: String
        let headers: [String: String]
        let body: Data?

        var jsonBody: [String: Any]? {
            body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        }
    }

    private static let lock = NSLock()
    private static var _hosts: [String] = []
    private static var _responses: [String: (status: Int, body: String)] = [:]
    private static var _requests: [RecordedRequest] = []

    /// Hosts match exactly or as a parent domain ("googleapis.com" covers "daily-cloudcode-pa.googleapis.com").
    static func install(hosts: [String]) {
        lock.withLock {
            _hosts = hosts
            _responses = [:]
            _requests = []
        }
        URLProtocol.registerClass(StubURLProtocol.self)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        QuotaHTTP.sessionOverride = URLSession(configuration: configuration)
    }

    static func uninstall() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        QuotaHTTP.sessionOverride = nil
        lock.withLock {
            _hosts = []
            _responses = [:]
            _requests = []
        }
    }

    static func respond(_ url: String, status: Int = 200, body: String) {
        lock.withLock { _responses[url] = (status, body) }
    }

    static var requests: [RecordedRequest] { lock.withLock { _requests } }
    static var requestedURLs: [String] { requests.map(\.url) }

    static func lastRequest(to url: String) -> RecordedRequest? {
        requests.last { $0.url == url }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return lock.withLock { _hosts.contains { host == $0 || host.hasSuffix(".\($0)") } }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let key = url.absoluteString
        let recorded = RecordedRequest(
            url: key,
            method: request.httpMethod ?? "GET",
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.readBody(request)
        )
        let (status, text) = Self.lock.withLock { () -> (Int, String) in
            Self._requests.append(recorded)
            return Self._responses[key] ?? (404, "{}")
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    /// Inside a URLProtocol the body usually arrives as a stream, not `httpBody`.
    private static func readBody(_ request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
