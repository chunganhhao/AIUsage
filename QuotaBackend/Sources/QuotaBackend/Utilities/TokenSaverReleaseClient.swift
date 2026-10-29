import Foundation
import CryptoKit

public enum TokenSaverReleaseTool: String, CaseIterable, Codable, Identifiable, Sendable {
    case rtk, caveman, ponytail
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .rtk: return "RTK"
        case .caveman: return "Caveman"
        case .ponytail: return "Ponytail"
        }
    }
    public var repository: String {
        switch self {
        case .rtk: return "rtk-ai/rtk"
        case .caveman: return "JuliusBrussee/caveman"
        case .ponytail: return "DietrichGebert/ponytail"
        }
    }
    public var skillPath: String? {
        switch self {
        case .caveman, .ponytail: return "skills/\(rawValue)/SKILL.md"
        default: return nil
        }
    }
    public var upstreamURL: URL { URL(string: "https://github.com/\(repository)")! }
}

public struct TokenSaverRelease: Equatable, Sendable {
    public let tool: TokenSaverReleaseTool
    public let version: String
    public let commit: String
    public let isRelease: Bool
    public var upstreamURL: URL { tool.upstreamURL }
}

public enum TokenSaverReleaseError: LocalizedError {
    case http(Int), rateLimited(String?), invalidMetadata, oversized, unsafeStorage, manualInstallation
    public var errorDescription: String? {
        switch self {
        case .http(let status): return "GitHub returned HTTP \(status). Check again later."
        case .rateLimited(let reset): return "GitHub rate limited this check.\(reset.map { " Reset (Unix): \($0)." } ?? " Try again later.")"
        case .invalidMetadata: return "GitHub metadata or skill integrity validation failed."
        case .oversized: return "GitHub response exceeds the safe size limit."
        case .unsafeStorage: return "Managed storage is invalid or contains a symbolic link."
        case .manualInstallation: return "External installation required; AIUsage does not install or execute unverified binaries."
        }
    }
}

private final class TokenSaverReleaseNoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }
}

/// Read-only GitHub API access. No shell, archive extraction, package manager, or provider calls.
public struct TokenSaverReleaseClient: Sendable {
    public typealias Transport = @Sendable (URLRequest, Int) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    public init(transport: @escaping Transport = { request, limit in
        try await TokenSaverReleaseClient.fetch(request, limit: limit)
    }) { self.transport = transport }

    public static func fetch(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request, delegate: TokenSaverReleaseNoRedirects())
        guard let http = response as? HTTPURLResponse else { throw TokenSaverReleaseError.invalidMetadata }
        guard response.expectedContentLength <= limit else { throw TokenSaverReleaseError.oversized }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw TokenSaverReleaseError.oversized }
            data.append(byte)
        }
        return (data, http)
    }

    public func latest(for tool: TokenSaverReleaseTool) async throws -> TokenSaverRelease {
        struct Release: Decodable { let tag_name: String; let draft: Bool; let prerelease: Bool }
        let (data, response) = try await request(tool, path: ["releases", "latest"], allowNotFound: true)
        if response.statusCode == 404 {
            // ponytail: repositories without releases use an explicitly labelled commit, never a made-up version.
            struct Commit: Decodable { let sha: String }
            let (commits, _) = try await request(tool, path: ["commits"], query: [.init(name: "per_page", value: "1")])
            guard let commit = try JSONDecoder().decode([Commit].self, from: commits).first,
                  Self.validSHA(commit.sha) else { throw TokenSaverReleaseError.invalidMetadata }
            return TokenSaverRelease(tool: tool, version: "commit \(commit.sha.prefix(12))", commit: commit.sha, isRelease: false)
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease, !release.tag_name.isEmpty,
              release.tag_name.count <= 200, !release.tag_name.contains(where: { $0.isNewline || $0.isASCII && $0.asciiValue! < 32 }) else {
            throw TokenSaverReleaseError.invalidMetadata
        }
        struct Commit: Decodable { let sha: String }
        let (commitData, _) = try await request(tool, path: ["commits", release.tag_name])
        let commit = try JSONDecoder().decode(Commit.self, from: commitData)
        guard Self.validSHA(commit.sha) else { throw TokenSaverReleaseError.invalidMetadata }
        return TokenSaverRelease(tool: tool, version: release.tag_name, commit: commit.sha, isRelease: true)
    }

    public func skill(for release: TokenSaverRelease) async throws -> Data {
        guard let path = release.tool.skillPath, Self.validSHA(release.commit) else {
            throw TokenSaverReleaseError.manualInstallation
        }
        struct Content: Decodable {
            let type: String; let path: String; let encoding: String
            let size: Int; let sha: String; let content: String
        }
        let (data, _) = try await request(release.tool, path: ["contents"] + path.components(separatedBy: "/"),
                                          query: [.init(name: "ref", value: release.commit)])
        let content = try JSONDecoder().decode(Content.self, from: data)
        guard content.type == "file", content.path == path, content.encoding == "base64",
              content.size > 0, content.size <= 128 * 1024,
              let bytes = Data(base64Encoded: content.content.filter { !$0.isWhitespace }),
              bytes.count == content.size,
              let markdown = String(data: bytes, encoding: .utf8), markdown.contains("name:"),
              !markdown.contains("\0") else { throw TokenSaverReleaseError.invalidMetadata }
        var blob = Data("blob \(bytes.count)\0".utf8)
        blob.append(bytes)
        let sha = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        guard sha == content.sha else { throw TokenSaverReleaseError.invalidMetadata }
        return bytes
    }

    static func validSHA(_ value: String) -> Bool {
        value.count == 40 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    private func request(_ tool: TokenSaverReleaseTool, path: [String], query: [URLQueryItem] = [],
                         allowNotFound: Bool = false) async throws -> (Data, HTTPURLResponse) {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        let components = ["repos"] + tool.repository.components(separatedBy: "/") + path
        var url = URLComponents(string: "https://api.github.com")!
        url.percentEncodedPath = "/" + components.map { $0.addingPercentEncoding(withAllowedCharacters: allowed)! }.joined(separator: "/")
        if !query.isEmpty { url.queryItems = query }
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AIUsage-TokenSaver-Updater", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        let limit = 512 * 1024
        let (data, response) = try await transport(request, limit)
        guard response.url == request.url else { throw TokenSaverReleaseError.invalidMetadata }
        guard data.count <= limit else { throw TokenSaverReleaseError.oversized }
        if response.statusCode == 403 || response.statusCode == 429 {
            throw TokenSaverReleaseError.rateLimited(response.value(forHTTPHeaderField: "X-RateLimit-Reset"))
        }
        guard response.statusCode == 200 || (allowNotFound && response.statusCode == 404) else {
            throw TokenSaverReleaseError.http(response.statusCode)
        }
        return (data, response)
    }
}
