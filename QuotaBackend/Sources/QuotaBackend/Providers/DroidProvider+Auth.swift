import Foundation
import CryptoKit

// MARK: - Droid Provider — Auth

extension DroidProvider {
    func resolveAuth() async throws -> DroidAuth {
        if let env = ProcessInfo.processInfo.environment["DROID_COOKIE_HEADER"].nilIfBlank {
            let normalizedCookie = Self.normalizeCookieHeader(env)
            let token = Self.bearerToken(fromCookieHeader: normalizedCookie)
            let claims = parseJWTClaims(token ?? "")
            return DroidAuth(
                cookieHeader: normalizedCookie,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: SourceInfo(mode: "manual", type: "cookie-header")
            )
        }

        if let session = loadSessionFile() {
            return try await resolveStoredSession(
                session,
                source: SourceInfo(mode: "auto", type: "auth-file"),
                persistencePath: nil
            )
        }

        throw ProviderError(
            "not_logged_in",
            "No Droid login state found. Connect a FACTORY_API_KEY or sign in with Factory CLI."
        )
    }

    func resolveAuth(from credential: AccountCredential) async throws -> DroidAuth {
        switch credential.authMethod {
        case .cookie:
            let normalizedCookie = Self.normalizeCookieHeader(credential.credential)
            guard !normalizedCookie.isEmpty else {
                throw ProviderError("missing_cookie", "Droid cookie header is empty.")
            }

            let token = Self.bearerToken(fromCookieHeader: normalizedCookie)
            let claims = parseJWTClaims(token ?? "")
            return DroidAuth(
                cookieHeader: normalizedCookie,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: SourceInfo(mode: "manual", type: "browser-cookie")
            )

        case .apiKey:
            // 官方 FACTORY_API_KEY（fk-…）。它不是 JWT，没有 org/sub claims，也没有 cookie，
            // 直接当作 Bearer token 打公开 API 即可，无需走 cookie 变体扩展与 WorkOS 刷新。
            let key = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else {
                throw ProviderError("missing_token", "Droid API key is empty.")
            }
            return DroidAuth(
                cookieHeader: nil,
                bearerToken: key,
                refreshToken: nil,
                organizationId: nil,
                userId: nil,
                source: SourceInfo(mode: "manual", type: "api-key")
            )

        case .token:
            let token = credential.credential.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else {
                throw ProviderError("missing_token", "Droid bearer token is empty.")
            }
            // fk- 开头的官方 API Key 不是 JWT，跳过 claim 解析，避免把它当成 JWT 误判。
            let claims: [String: Any] = token.hasPrefix("fk-") ? [:] : parseJWTClaims(token)
            return DroidAuth(
                cookieHeader: nil,
                bearerToken: token,
                refreshToken: nil,
                organizationId: claims["org_id"] as? String,
                userId: claims["sub"] as? String,
                source: SourceInfo(mode: "manual", type: token.hasPrefix("fk-") ? "api-key" : "bearer-token")
            )

        case .authFile:
            let path = NSString(string: credential.credential).expandingTildeInPath
            guard let session = loadSessionFile(at: path) else {
                throw ProviderError("not_logged_in", "Could not read the Droid auth file.")
            }
            do {
                return try await resolveStoredSession(
                    session,
                    source: SourceInfo(mode: "manual", type: "auth-file"),
                    persistencePath: path
                )
            } catch {
                if let freshAuth = try await resyncFromOriginalSource(
                    credential: credential,
                    managedPath: path
                ) {
                    return freshAuth
                }
                throw error
            }

        case .auto:
            return try await resolveAuth()

        default:
            throw ProviderError("unsupported_auth_method", "Droid does not support \(credential.authMethod.rawValue) credentials.")
        }
    }

    func loadSessionFile() -> SessionFile? {
        loadSessionFile(at: nil)
    }

    func loadSessionFile(at pathOverride: String?) -> SessionFile? {
        let paths = pathOverride.map { [$0] } ?? [
            "\(homeDirectory)/.factory/auth.v2.file",
            "\(homeDirectory)/.factory/auth.v2.keyring",
            "\(homeDirectory)/.factory/auth.encrypted",
            "\(homeDirectory)/.config/factory/auth.json",
            "\(homeDirectory)/.factory/auth.json",
            "\(homeDirectory)/.config/droid/auth.json"
        ]

        for path in paths {
            guard let session = loadSingleSessionFile(at: path) else { continue }
            return session
        }
        return nil
    }

    func exchangeRefreshToken(_ refreshToken: String, orgId: String?) async throws -> RefreshedAuth {
        guard let url = URL(string: Self.workOSRefreshURL) else {
            throw ProviderError("invalid_url", "Droid token refresh URL is invalid.")
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        var queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: Self.workOSClientID)
        ]
        if let orgId = orgId?.nilIfBlank {
            queryItems.append(URLQueryItem(name: "organization_id", value: orgId))
        }

        var components = URLComponents()
        components.queryItems = queryItems
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ... 299).contains(http.statusCode) {
            let message = String(data: data, encoding: .utf8)?.nilIfBlank ?? "Failed to refresh Droid token."
            throw ProviderError("refresh_failed", message)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accessToken = firstNonEmpty(
                json["accessToken"] as? String,
                json["access_token"] as? String
              ) else {
            throw ProviderError("refresh_failed", "Failed to refresh Droid token.")
        }

        return RefreshedAuth(
            accessToken: accessToken,
            refreshToken: firstNonEmpty(
                json["refreshToken"] as? String,
                json["refresh_token"] as? String,
                refreshToken
            ),
            organizationId: firstNonEmpty(
                json["organizationId"] as? String,
                json["organization_id"] as? String,
                orgId
            )
        )
    }

    func resolveStoredSession(
        _ session: SessionFile,
        source: SourceInfo,
        persistencePath: String?
    ) async throws -> DroidAuth {
        let normalizedCookie = session.cookieHeader.nilIfBlank.map(Self.normalizeCookieHeader)
        let cookieToken = Self.bearerToken(fromCookieHeader: normalizedCookie)
        let preferredToken = session.accessToken.nilIfBlank ?? cookieToken
        let refreshToken = session.refreshToken.nilIfBlank

        if let preferredToken,
           !shouldRefreshAccessToken(preferredToken, refreshToken: refreshToken) {
            return makeAuth(
                cookieHeader: normalizedCookie,
                accessToken: preferredToken,
                refreshToken: refreshToken,
                organizationId: session.organizationId,
                source: source
            )
        }

        if let refreshToken {
            return try await refreshStoredSession(
                refreshToken: refreshToken,
                currentSession: session,
                source: source,
                persistencePath: persistencePath
            )
        }

        if let normalizedCookie {
            return makeAuth(
                cookieHeader: normalizedCookie,
                accessToken: preferredToken,
                refreshToken: nil,
                organizationId: session.organizationId,
                source: source
            )
        }

        throw ProviderError("missing_tokens", "Droid auth file does not contain a usable cookie or token.")
    }

    func refreshAuth(_ auth: DroidAuth, persistencePath: String?) async throws -> DroidAuth {
        guard let refreshToken = auth.refreshToken.nilIfBlank else {
            throw ProviderError("refresh_failed", "Droid refresh token is missing.")
        }

        return try await refreshStoredSession(
            refreshToken: refreshToken,
            currentSession: SessionFile(
                accessToken: auth.bearerToken,
                refreshToken: auth.refreshToken,
                organizationId: auth.organizationId,
                cookieHeader: auth.cookieHeader
            ),
            source: auth.source,
            persistencePath: persistencePath
        )
    }

    func refreshStoredSession(
        refreshToken: String,
        currentSession: SessionFile,
        source: SourceInfo,
        persistencePath: String?
    ) async throws -> DroidAuth {
        let refreshed = try await exchangeRefreshToken(refreshToken, orgId: currentSession.organizationId)
        let updatedSession = SessionFile(
            accessToken: refreshed.accessToken,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            organizationId: refreshed.organizationId ?? currentSession.organizationId,
            cookieHeader: currentSession.cookieHeader
        )
        if let persistencePath {
            persistSessionFile(updatedSession, to: persistencePath)
        }
        return makeAuth(
            cookieHeader: updatedSession.cookieHeader,
            accessToken: updatedSession.accessToken,
            refreshToken: updatedSession.refreshToken,
            organizationId: updatedSession.organizationId,
            source: source
        )
    }

    func makeAuth(
        cookieHeader: String?,
        accessToken: String?,
        refreshToken: String?,
        organizationId: String?,
        source: SourceInfo
    ) -> DroidAuth {
        let normalizedCookie = cookieHeader.nilIfBlank.map(Self.normalizeCookieHeader)
        let token = accessToken.nilIfBlank ?? Self.bearerToken(fromCookieHeader: normalizedCookie)
        let claims = parseJWTClaims(token ?? "")
        return DroidAuth(
            cookieHeader: normalizedCookie,
            bearerToken: token,
            refreshToken: refreshToken.nilIfBlank,
            organizationId: organizationId ?? claims["org_id"] as? String,
            userId: claims["sub"] as? String,
            source: source
        )
    }

    // MARK: - Managed Copy Resync

    func resyncFromOriginalSource(
        credential: AccountCredential,
        managedPath: String
    ) async throws -> DroidAuth? {
        guard let sourcePath = credential.metadata["sourcePath"]?.nilIfBlank else { return nil }

        let expandedSource = NSString(string: sourcePath).expandingTildeInPath
        guard expandedSource != managedPath,
              FileManager.default.fileExists(atPath: expandedSource) else { return nil }

        guard let freshSession = loadSessionFile(at: expandedSource) else { return nil }

        let auth = try await resolveStoredSession(
            freshSession,
            source: SourceInfo(mode: "manual", type: "auth-file"),
            persistencePath: managedPath
        )

        persistSessionFile(
            SessionFile(
                accessToken: auth.bearerToken,
                refreshToken: auth.refreshToken,
                organizationId: auth.organizationId,
                cookieHeader: auth.cookieHeader
            ),
            to: managedPath
        )

        return auth
    }

    func shouldRefreshAccessToken(_ token: String, refreshToken: String?) -> Bool {
        guard refreshToken.nilIfBlank != nil else { return false }
        let claims = parseJWTClaims(token)
        guard let exp = claims["exp"] as? Double ?? (claims["exp"] as? Int).map(Double.init) else {
            return true
        }
        return Date().timeIntervalSince1970 >= exp - 60
    }

    func persistSessionFile(_ session: SessionFile, to path: String) {
        var json: [String: Any] = [:]
        if let accessToken = session.accessToken { json["access_token"] = accessToken }
        if let refreshToken = session.refreshToken { json["refresh_token"] = refreshToken }
        if let organizationId = session.organizationId { json["organization_id"] = organizationId }
        if let cookieHeader = session.cookieHeader { json["cookie_header"] = cookieHeader }
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    func loadSingleSessionFile(at path: String) -> SessionFile? {
        guard let data = FileManager.default.contents(atPath: path) else {
            return nil
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return sessionFile(from: json)
        }

        let filename = URL(fileURLWithPath: path).lastPathComponent
        if filename == "auth.v2.file" {
            let keyPath = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("auth.v2.key").path
            guard let keyData = loadFactoryKeyFile(at: keyPath),
                  let plaintext = decryptFactoryCredentials(payload: data, key: keyData),
                  let jsonData = plaintext.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return sessionFile(from: json)
        }

        if filename == "auth.v2.keyring" {
            guard let keyData = loadFactoryKeyringKey(),
                  let plaintext = decryptFactoryCredentials(payload: data, key: keyData),
                  let jsonData = plaintext.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return sessionFile(from: json)
        }

        if filename == "auth.encrypted" {
            guard let keyData = loadFactoryKeyringKey(),
                  let plaintext = decryptFactoryCredentials(payload: data, key: keyData),
                  let jsonData = plaintext.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
                return nil
            }
            return sessionFile(from: json)
        }

        return nil
    }

    func sessionFile(from json: [String: Any]) -> SessionFile {
        SessionFile(
            accessToken: firstNonEmpty(
                json["accessToken"] as? String,
                json["access_token"] as? String,
                json["token"] as? String
            ),
            refreshToken: firstNonEmpty(
                json["refreshToken"] as? String,
                json["refresh_token"] as? String
            ),
            organizationId: firstNonEmpty(
                json["organizationId"] as? String,
                json["organization_id"] as? String,
                json["orgId"] as? String
            ),
            cookieHeader: firstNonEmpty(
                json["cookieHeader"] as? String,
                json["cookie_header"] as? String,
                json["cookie"] as? String
            )
        )
    }

    func loadFactoryKeyFile(at path: String) -> Data? {
        guard let rawKey = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank else {
            return nil
        }
        return Data(base64Encoded: Self.base64URLSafeToStandard(rawKey))
    }

    func loadFactoryKeyringKey() -> Data? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = [
            "find-generic-password",
            "-s", Self.keyringServiceName,
            "-a", Self.keyringAccountName,
            "-w"
        ]
        let output = Pipe()
        task.standardOutput = output
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
        } catch {
            return nil
        }
        guard task.terminationStatus == 0 else { return nil }
        let rawKey = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let rawKey = rawKey.nilIfBlank else { return nil }
        return Data(base64Encoded: Self.base64URLSafeToStandard(rawKey))
    }

    func decryptFactoryCredentials(payload: Data, key: Data) -> String? {
        guard let text = String(data: payload, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return nil
        }
        let components = text.split(separator: ":").map(String.init)
        guard components.count == 3,
              let nonceData = Data(base64Encoded: Self.base64URLSafeToStandard(components[0])),
              let tagData = Data(base64Encoded: Self.base64URLSafeToStandard(components[1])),
              let ciphertext = Data(base64Encoded: Self.base64URLSafeToStandard(components[2])) else {
            return nil
        }

        guard let nonce = try? AES.GCM.Nonce(data: nonceData) else { return nil }
        let key = SymmetricKey(data: key)
        guard let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tagData),
              let plaintext = try? AES.GCM.open(sealedBox, using: key) else {
            return nil
        }
        return String(data: plaintext, encoding: .utf8)
    }
}

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

private extension Optional where Wrapped == String {
    var nilIfBlank: String? {
        switch self {
        case .some(let value):
            return value.nilIfBlank
        case .none:
            return nil
        }
    }
}
