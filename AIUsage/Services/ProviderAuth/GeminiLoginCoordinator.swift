import AppKit
import Combine
import Foundation
import Network
import QuotaBackend

@MainActor
final class GeminiLoginCoordinator: ObservableObject {
    @Published private(set) var phase: LoginPhase = .idle
    @Published private(set) var authURL: URL?
    @Published private(set) var callbackURL: URL?
    // 仅内部记录人类可读进度，UI 不直接展示；保持普通存储属性避免无谓的视图重渲染。
    private var outputSummary: String?
    @Published private(set) var importedAuthFileURL: URL?
    @Published private(set) var accountEmail: String?

    private struct OAuthConfiguration {
        let clientId: String
        let clientSecret: String
    }

    private static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    private static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!

    private let listenerQueue = DispatchQueue(label: "AIUsage.GeminiOAuth")
    private var listener: NWListener?
    private var timeoutTask: Task<Void, Never>?
    private var sessionDirectoryURL: URL?
    private var redirectURL: URL?
    private var stateToken: String?
    private var oauthConfiguration: OAuthConfiguration?
    private var didFinish = false

    var isRunning: Bool {
        switch phase {
        case .launching, .waitingForBrowser, .waitingForCompletion:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    func start() {
        cancel()

        phase = .launching
        authURL = nil
        callbackURL = nil
        outputSummary = "Preparing Google sign-in…"
        importedAuthFileURL = nil
        accountEmail = nil
        didFinish = false

        let fileManager = FileManager.default
        let sessionDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-gemini-login-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Failed to prepare a Gemini login session: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return
        }

        sessionDirectoryURL = sessionDirectory

        guard let oauthConfiguration = Self.resolveOAuthConfiguration() else {
            cleanup(removeArtifacts: true)
            phase = .failed("AIUsage could not find Gemini CLI OAuth configuration. Reinstall Gemini CLI or set AIUSAGE_GEMINI_OAUTH_CLIENT_ID / AIUSAGE_GEMINI_OAUTH_CLIENT_SECRET.")
            return
        }
        self.oauthConfiguration = oauthConfiguration

        do {
            let listener = try NWListener(using: .tcp, on: .any)
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    self?.handleListenerState(state)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    self?.accept(connection)
                }
            }

            listener.start(queue: listenerQueue)
        } catch {
            cleanup(removeArtifacts: true)
            phase = .failed("Failed to start the Gemini sign-in callback server: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        redirectURL = nil
        stateToken = nil
        oauthConfiguration = nil
        didFinish = false
        cleanup(removeArtifacts: true)
        phase = .idle
    }

    func discardImportedSession() {
        cleanup(removeArtifacts: true)
    }

    func reopenInBrowser() {
        guard let authURL else { return }
        NSWorkspace.shared.open(authURL)
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let listener,
                  let port = listener.port?.rawValue,
                  let oauthConfiguration else {
                phase = .failed("Gemini sign-in could not determine its callback port.")
                cleanup(removeArtifacts: true)
                return
            }

            let stateToken = Self.randomStateToken()
            self.stateToken = stateToken
            let redirectURL = URL(string: "http://127.0.0.1:\(port)/oauth2callback")!
            self.redirectURL = redirectURL
            self.authURL = Self.makeAuthURL(
                clientId: oauthConfiguration.clientId,
                redirectURL: redirectURL,
                stateToken: stateToken
            )

            phase = .waitingForBrowser
            outputSummary = "Google sign-in opened in your browser. Finish authentication and AIUsage will connect the account automatically."
            if let authURL {
                NSWorkspace.shared.open(authURL)
            }
            beginTimeout()
        case .failed(let error):
            phase = .failed("Gemini sign-in listener failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
            cleanup(removeArtifacts: true)
        default:
            break
        }
    }

    private func beginTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled, !didFinish else { return }
            self.phase = .failed("Gemini authentication timed out after 5 minutes. Please try again.")
            self.cleanup(removeArtifacts: true)
        }
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: listenerQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }

            if let error {
                Task { @MainActor in
                    self.phase = .failed("Gemini callback failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
                }
                connection.cancel()
                return
            }

            guard let data, !data.isEmpty,
                  let request = String(data: data, encoding: .utf8),
                  let requestURL = Self.extractRequestURL(from: request) else {
                self.respond(
                    on: connection,
                    html: Self.failureHTML(message: "AIUsage could not read the Gemini sign-in callback.")
                )
                return
            }

            Task { @MainActor in
                await self.handleCallback(requestURL, connection: connection)
            }
        }
    }

    private func handleCallback(_ url: URL, connection: NWConnection) async {
        callbackURL = url

        guard Self.isSuccessfulCallbackURL(url) else {
            respond(
                on: connection,
                html: Self.failureHTML(message: "Unexpected Gemini callback URL.")
            )
            return
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []
        let queryValue: (String) -> String? = { name in
            queryItems.first(where: { $0.name == name })?.value
        }

        if let errorCode = queryValue("error") {
            let description = queryValue("error_description") ?? "No additional details provided."
            let message = "Google OAuth error: \(errorCode). \(description)"
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
            return
        }

        guard queryValue("state") == stateToken else {
            let message = "Gemini OAuth state mismatch. Please try again."
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
            return
        }

        guard let code = queryValue("code")?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else {
            let message = "No authorization code was returned by Google OAuth."
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
            return
        }

        phase = .waitingForCompletion
        outputSummary = "Google sign-in approved. Finalizing Gemini account…"

        do {
            let (authFileURL, email) = try await finalizeLogin(usingAuthorizationCode: code)
            accountEmail = email
            importedAuthFileURL = authFileURL
            didFinish = true
            phase = .succeeded
            if let email, !email.isEmpty {
                outputSummary = "Gemini account connected for \(email)."
            } else {
                outputSummary = "Gemini account connected."
            }

            respond(on: connection, html: Self.successHTML(email: email))
            timeoutTask?.cancel()
            timeoutTask = nil
            listener?.cancel()
            listener = nil
        } catch {
            let message = SensitiveDataRedactor.redactedMessage(for: error)
            phase = .failed(message)
            respond(on: connection, html: Self.failureHTML(message: message))
            cleanup(removeArtifacts: true)
        }
    }

    private func finalizeLogin(usingAuthorizationCode code: String) async throws -> (URL, String?) {
        guard let oauthConfiguration,
              let redirectURL,
              let sessionDirectoryURL else {
            throw ProviderError("oauth_setup_failed", "Gemini OAuth session was not fully initialized.")
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: oauthConfiguration.clientId),
            URLQueryItem(name: "client_secret", value: oauthConfiguration.clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "grant_type", value: "authorization_code")
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError("oauth_exchange_failed", "Gemini OAuth token exchange failed (\(http.statusCode)). \(payload)")
        }

        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["access_token"] as? String != nil else {
            throw ProviderError("oauth_exchange_failed", "Gemini OAuth token exchange did not return an access token.")
        }

        if let expiresIn = json["expires_in"] as? Double {
            json["expiry_date"] = Int(Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000)
        } else if let expiresIn = json["expires_in"] as? Int {
            json["expiry_date"] = Int(Date().addingTimeInterval(TimeInterval(expiresIn)).timeIntervalSince1970 * 1000)
        }

        let email = try? await fetchGoogleAccountEmail(accessToken: json["access_token"] as? String)
        if let email, !email.isEmpty {
            json["email"] = email
        }

        let authFileURL = sessionDirectoryURL.appendingPathComponent("oauth_creds.json")
        let fileData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fileData.write(to: authFileURL, options: .atomic)
        return (authFileURL, email)
    }

    private func fetchGoogleAccountEmail(accessToken: String?) async throws -> String? {
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var request = URLRequest(url: Self.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    private nonisolated func respond(on connection: NWConnection, html: String) {
        let data = """
        HTTP/1.1 200 OK\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Connection: close\r
        \r
        \(html)
        """.data(using: .utf8) ?? Data()

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func cleanup(removeArtifacts: Bool) {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        redirectURL = nil
        stateToken = nil
        oauthConfiguration = nil

        if removeArtifacts, let sessionDirectoryURL {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            self.sessionDirectoryURL = nil
            importedAuthFileURL = nil
            accountEmail = nil
        }
    }

    private nonisolated static func resolveOAuthConfiguration() -> OAuthConfiguration? {
        guard let credentials = GeminiCredentialBridge.oauthClientCredentials() else {
            return nil
        }
        return OAuthConfiguration(
            clientId: credentials.clientID,
            clientSecret: credentials.clientSecret
        )
    }

    private nonisolated static func makeAuthURL(clientId: String, redirectURL: URL, stateToken: String) -> URL? {
        var components = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")
        components?.queryItems = [
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "scope", value: [
                "openid",
                "https://www.googleapis.com/auth/cloud-platform",
                "https://www.googleapis.com/auth/userinfo.email",
                "https://www.googleapis.com/auth/userinfo.profile"
            ].joined(separator: " ")),
            URLQueryItem(name: "state", value: stateToken),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId)
        ]
        return components?.url
    }

    private nonisolated static func randomStateToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private nonisolated static func extractRequestURL(from request: String) -> URL? {
        guard let firstLine = request.components(separatedBy: .newlines).first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        return URL(string: String(parts[1]), relativeTo: URL(string: "http://127.0.0.1"))
    }

    private nonisolated static func isSuccessfulCallbackURL(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased(),
              host.contains("localhost") || host.contains("127.0.0.1") else {
            return false
        }
        return url.path.lowercased().contains("oauth2callback")
    }

    private nonisolated static func successHTML(email: String?) -> String {
        let accountLine: String
        if let email, !email.isEmpty {
            accountLine = "<p><strong>\(email)</strong> has been connected.</p>"
        } else {
            accountLine = ""
        }
        return """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Gemini Connected</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#f6f8fb;color:#111827;">
        <h2 style="margin:0 0 12px;">Gemini account connected</h2>
        \(accountLine)
        <p>You can return to AIUsage now. This tab can be closed.</p>
        </body>
        </html>
        """
    }

    private nonisolated static func failureHTML(message: String) -> String {
        """
        <!doctype html>
        <html>
        <head><meta charset="utf-8"><title>Gemini Login Failed</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#fff7f7;color:#7f1d1d;">
        <h2 style="margin:0 0 12px;">Gemini login failed</h2>
        <p>\(message)</p>
        <p>You can return to AIUsage and try again.</p>
        </body>
        </html>
        """
    }
}
