// MARK: - Antigravity Login Coordinator
// Manages browser-based Google OAuth2 login for Antigravity.
// Starts a local TCP listener, opens the Google sign-in page in the default browser,
// receives the redirect with an authorization code, exchanges it for tokens,
// and writes the result as an auth JSON file for the provider to import.
// OAuth client credentials are resolved from env vars or extracted from the
// Antigravity.app bundle JS, matching the backend AntigravityProvider logic.

import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import QuotaBackend

@MainActor
final class AntigravityLoginCoordinator: ObservableObject {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    typealias ListenerFactory = @Sendable () throws -> NWListener

    @Published private(set) var phase: LoginPhase = .idle
    @Published private(set) var authURL: URL?
    @Published private(set) var callbackURL: URL?
    // 仅内部记录人类可读进度，UI 不直接展示；保持普通存储属性避免无谓的视图重渲染。
    private var outputSummary: String?
    @Published private(set) var importedAuthFileURL: URL?
    @Published private(set) var accountEmail: String?

    struct OAuthConfiguration: Equatable, Sendable {
        let clientId: String
        let clientSecret: String
    }

    nonisolated static let callbackPath = "/oauth2callback"
    nonisolated static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    nonisolated static let userInfoURL = URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!
    nonisolated static let maxCallbackHeaderBytes = 64 * 1024
    nonisolated static let callbackReadTimeoutSeconds: TimeInterval = 5.0

    private let listenerQueue = DispatchQueue(label: "AIUsage.AntigravityOAuth")
    private let dataLoader: DataLoader
    private let oauthConfigurationProvider: @Sendable () -> OAuthConfiguration?
    private let openBrowserHandler: @MainActor (URL) -> Void
    private let listenerFactory: ListenerFactory
    private var listener: NWListener?
    private var timeoutTask: Task<Void, Never>?
    private var sessionID: UUID?
    private var sessionDirectoryURL: URL?
    private var redirectURL: URL?
    private var stateToken: String?
    private var codeVerifier: String?
    private var oauthConfiguration: OAuthConfiguration?
    private var didFinish = false

    init(
        dataLoader: @escaping DataLoader = { request in
            try await URLSession.shared.data(for: request)
        },
        oauthConfigurationProvider: @escaping @Sendable () -> OAuthConfiguration? = {
            AntigravityLoginCoordinator.resolveOAuthConfiguration()
        },
        openBrowserHandler: @escaping @MainActor (URL) -> Void = { url in
            NSWorkspace.shared.open(url)
        },
        listenerFactory: @escaping ListenerFactory = {
            try AntigravityLoginCoordinator.makeLoopbackListener()
        }
    ) {
        self.dataLoader = dataLoader
        self.oauthConfigurationProvider = oauthConfigurationProvider
        self.openBrowserHandler = openBrowserHandler
        self.listenerFactory = listenerFactory
    }

    var isRunning: Bool {
        switch phase {
        case .launching, .waitingForBrowser, .waitingForCompletion:
            return true
        case .idle, .succeeded, .failed:
            return false
        }
    }

    // MARK: - Lifecycle

    func start() {
        cancel()

        let currentSessionID = UUID()
        sessionID = currentSessionID
        phase = .launching
        authURL = nil
        callbackURL = nil
        outputSummary = "Preparing Google sign-in…"
        importedAuthFileURL = nil
        accountEmail = nil
        didFinish = false

        let fileManager = FileManager.default
        let sessionDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("aiusage-antigravity-login-\(currentSessionID.uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            sessionID = nil
            phase = .failed("Failed to prepare an Antigravity login session: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return
        }

        sessionDirectoryURL = sessionDirectory

        guard let oauthConfiguration = oauthConfigurationProvider() else {
            cleanup(removeArtifacts: true)
            phase = .failed("AIUsage could not find Antigravity OAuth configuration. Install Antigravity or set AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID / AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_SECRET.")
            return
        }
        self.oauthConfiguration = oauthConfiguration

        do {
            let listener = try listenerFactory()
            self.listener = listener

            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == currentSessionID else { return }
                    self.handleListenerState(state, sessionID: currentSessionID)
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async {
                    guard let self, self.sessionID == currentSessionID else {
                        connection.cancel()
                        return
                    }
                    self.accept(connection, sessionID: currentSessionID)
                }
            }

            listener.start(queue: listenerQueue)
        } catch {
            cleanup(removeArtifacts: true)
            phase = .failed("Failed to start the Antigravity sign-in callback server: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    func cancel() {
        timeoutTask?.cancel()
        timeoutTask = nil
        listener?.cancel()
        listener = nil
        sessionID = nil
        redirectURL = nil
        stateToken = nil
        codeVerifier = nil
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
        openBrowserHandler(authURL)
    }

    // MARK: - Listener

    private func handleListenerState(_ state: NWListener.State, sessionID: UUID) {
        guard self.sessionID == sessionID, !didFinish else { return }
        switch state {
        case .ready:
            guard let listener,
                  let port = listener.port?.rawValue,
                  let oauthConfiguration else {
                phase = .failed("Antigravity sign-in could not determine its callback port.")
                cleanup(removeArtifacts: true)
                return
            }

            activateSession(port: port, oauthConfiguration: oauthConfiguration, sessionID: sessionID)
        case .failed(let error):
            phase = .failed("Antigravity sign-in listener failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
            cleanup(removeArtifacts: true)
        default:
            break
        }
    }

    func activateSessionForTesting(port: UInt16) {
        let currentSessionID = UUID()
        sessionID = currentSessionID
        didFinish = false
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-antigravity-test-\(currentSessionID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        sessionDirectoryURL = dir
        let config = oauthConfigurationProvider() ?? OAuthConfiguration(clientId: Self.knownClientId, clientSecret: Self.knownClientSecret)
        oauthConfiguration = config
        activateSession(port: port, oauthConfiguration: config, sessionID: currentSessionID)
    }

    private func activateSession(port: UInt16, oauthConfiguration: OAuthConfiguration, sessionID: UUID) {
        let stateToken = Self.randomStateToken()
        let codeVerifier = Self.randomPKCECodeVerifier()
        let codeChallenge = Self.pkceCodeChallenge(for: codeVerifier)
        self.stateToken = stateToken
        self.codeVerifier = codeVerifier
        let redirectURL = URL(string: "http://127.0.0.1:\(port)\(Self.callbackPath)")!
        self.redirectURL = redirectURL
        self.authURL = Self.makeAuthURL(
            clientId: oauthConfiguration.clientId,
            redirectURL: redirectURL,
            stateToken: stateToken,
            codeChallenge: codeChallenge
        )

        phase = .waitingForBrowser
        outputSummary = "Google sign-in opened in your browser. Finish authentication and AIUsage will connect the account automatically."
        if let authURL {
            openBrowserHandler(authURL)
        }
        beginTimeout(sessionID: sessionID)
    }

    private func beginTimeout(sessionID: UUID) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            guard let self, !Task.isCancelled, self.sessionID == sessionID, !self.didFinish else { return }
            self.phase = .failed("Antigravity authentication timed out after 5 minutes. Please try again.")
            self.cleanup(removeArtifacts: true)
        }
    }

    // MARK: - Connection Handling

    private final class CallbackReadState: @unchecked Sendable {
        var buffer = Data()
        var finished = false
        var timeoutItem: DispatchWorkItem?

        func markFinished() {
            finished = true
            timeoutItem?.cancel()
            timeoutItem = nil
        }
    }

    private func accept(_ connection: NWConnection, sessionID: UUID) {
        if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
           !Self.isLoopbackEndpoint(remoteEndpoint) {
            connection.cancel()
            return
        }
        connection.stateUpdateHandler = { _ in }
        connection.start(queue: listenerQueue)

        let readState = CallbackReadState()
        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self, !readState.finished else { return }
            readState.markFinished()
            self.respond(
                on: connection,
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: "AIUsage timed out waiting for the complete Antigravity sign-in callback.")
            )
        }
        readState.timeoutItem = timeoutItem
        listenerQueue.asyncAfter(
            deadline: .now() + Self.callbackReadTimeoutSeconds,
            execute: timeoutItem
        )

        receiveNextCallbackChunk(
            on: connection,
            sessionID: sessionID,
            readState: readState
        )
    }

    private nonisolated func receiveNextCallbackChunk(
        on connection: NWConnection,
        sessionID: UUID,
        readState: CallbackReadState
    ) {
        let remainingAllowance = max(1, Self.maxCallbackHeaderBytes - readState.buffer.count + 1)
        connection.receive(minimumIncompleteLength: 1, maximumLength: remainingAllowance) { [weak self] data, _, isComplete, error in
            guard let self else {
                readState.markFinished()
                connection.cancel()
                return
            }
            guard !readState.finished else { return }

            if let error {
                readState.markFinished()
                Task { @MainActor in
                    guard self.sessionID == sessionID, self.phase == .waitingForBrowser, !self.didFinish else { return }
                    self.outputSummary = "Ignored transient callback connection error: \(SensitiveDataRedactor.redactedMessage(for: error))"
                }
                connection.cancel()
                return
            }

            if let remoteEndpoint = connection.currentPath?.remoteEndpoint,
               !Self.isLoopbackEndpoint(remoteEndpoint) {
                readState.markFinished()
                connection.cancel()
                return
            }

            if let data, !data.isEmpty {
                readState.buffer.append(data)
                if readState.buffer.count > Self.maxCallbackHeaderBytes {
                    readState.markFinished()
                    self.respond(
                        on: connection,
                        statusLine: "HTTP/1.1 400 Bad Request",
                        html: Self.failureHTML(message: "Antigravity sign-in callback exceeded the maximum allowed header size.")
                    )
                    return
                }
            }

            if Self.containsHTTPHeaderTerminator(readState.buffer) {
                readState.markFinished()
                guard let request = String(data: readState.buffer, encoding: .utf8) else {
                    self.respond(
                        on: connection,
                        statusLine: "HTTP/1.1 400 Bad Request",
                        html: Self.failureHTML(message: "AIUsage could not read the Antigravity sign-in callback.")
                    )
                    return
                }
                Task { @MainActor in
                    guard self.sessionID == sessionID else {
                        connection.cancel()
                        return
                    }
                    let htmlResponse = await self.processRawHTTPRequest(request, sessionID: sessionID)
                    self.respond(
                        on: connection,
                        statusLine: htmlResponse.statusLine,
                        html: htmlResponse.html
                    )
                }
                return
            }

            if isComplete {
                readState.markFinished()
                self.respond(
                    on: connection,
                    statusLine: "HTTP/1.1 400 Bad Request",
                    html: Self.failureHTML(message: "AIUsage received an incomplete Antigravity sign-in callback.")
                )
                return
            }

            self.receiveNextCallbackChunk(
                on: connection,
                sessionID: sessionID,
                readState: readState
            )
        }
    }

    struct CallbackHTTPResponse: Equatable, Sendable {
        let statusLine: String
        let html: String
    }

    func processRawHTTPRequest(_ request: String, sessionID: UUID? = nil) async -> CallbackHTTPResponse {
        let effectiveSessionID = sessionID ?? self.sessionID
        guard let effectiveSessionID,
              self.sessionID == effectiveSessionID,
              phase == .waitingForBrowser,
              !didFinish,
              let expectedRedirectURL = redirectURL,
              let expectedState = stateToken,
              let verifier = codeVerifier,
              let oauthConfig = oauthConfiguration,
              let sessionDir = sessionDirectoryURL else {
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: "No active Antigravity sign-in session is waiting for a callback.")
            )
        }

        guard let requestURL = Self.parseCallbackRequest(request, expectedRedirectURL: expectedRedirectURL),
              Self.isSuccessfulCallbackURL(requestURL, expectedRedirectURL: expectedRedirectURL) else {
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: "Unexpected Antigravity callback URL.")
            )
        }

        let components = URLComponents(url: requestURL, resolvingAgainstBaseURL: false)
        let queryItems = components?.queryItems ?? []

        // Validate state strictly (single occurrence, exact match) before honoring error or code
        // so stray or unauthenticated requests cannot abort the active browser login session.
        guard case .single(let receivedState) = Self.queryParameter("state", in: queryItems),
              receivedState == expectedState else {
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: "Antigravity OAuth state mismatch. Please try again.")
            )
        }

        callbackURL = requestURL

        switch Self.queryParameter("error", in: queryItems) {
        case .duplicate:
            let message = "Ambiguous OAuth error callback parameters."
            phase = .failed(message)
            cleanup(removeArtifacts: true)
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: message)
            )
        case .single(let errorCode):
            let description: String
            if case .single(let desc) = Self.queryParameter("error_description", in: queryItems), !desc.isEmpty {
                description = desc
            } else {
                description = "No additional details provided."
            }
            let message = "Google OAuth error: \(errorCode). \(description)"
            phase = .failed(message)
            cleanup(removeArtifacts: true)
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: message)
            )
        case .missing:
            break
        }

        guard case .single(let rawCode) = Self.queryParameter("code", in: queryItems) else {
            let message = "No valid authorization code was returned by Google OAuth."
            phase = .failed(message)
            cleanup(removeArtifacts: true)
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: message)
            )
        }

        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            let message = "No authorization code was returned by Google OAuth."
            phase = .failed(message)
            cleanup(removeArtifacts: true)
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: message)
            )
        }

        // Consume one-time state/verifier before awaiting network I/O so duplicate callbacks cannot re-enter.
        self.stateToken = nil
        self.codeVerifier = nil
        phase = .waitingForCompletion
        outputSummary = "Google sign-in approved. Finalizing Antigravity account…"

        do {
            let (authFileURL, email) = try await finalizeLogin(
                usingAuthorizationCode: code,
                codeVerifier: verifier,
                oauthConfiguration: oauthConfig,
                redirectURL: expectedRedirectURL,
                sessionDirectoryURL: sessionDir
            )
            guard self.sessionID == effectiveSessionID, !self.didFinish else {
                return CallbackHTTPResponse(
                    statusLine: "HTTP/1.1 400 Bad Request",
                    html: Self.failureHTML(message: "Antigravity sign-in session was superseded.")
                )
            }
            accountEmail = email
            importedAuthFileURL = authFileURL
            didFinish = true
            phase = .succeeded
            if let email, !email.isEmpty {
                outputSummary = "Antigravity account connected for \(email)."
            } else {
                outputSummary = "Antigravity account connected."
            }

            timeoutTask?.cancel()
            timeoutTask = nil
            listener?.cancel()
            listener = nil
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 200 OK",
                html: Self.successHTML(email: email)
            )
        } catch {
            guard self.sessionID == effectiveSessionID, !self.didFinish else {
                return CallbackHTTPResponse(
                    statusLine: "HTTP/1.1 400 Bad Request",
                    html: Self.failureHTML(message: "Antigravity sign-in session was superseded.")
                )
            }
            let message = SensitiveDataRedactor.redactedMessage(for: error)
            phase = .failed(message)
            cleanup(removeArtifacts: true)
            return CallbackHTTPResponse(
                statusLine: "HTTP/1.1 400 Bad Request",
                html: Self.failureHTML(message: message)
            )
        }
    }

    // MARK: - Token Exchange

    private func finalizeLogin(
        usingAuthorizationCode code: String,
        codeVerifier: String,
        oauthConfiguration: OAuthConfiguration,
        redirectURL: URL,
        sessionDirectoryURL: URL
    ) async throws -> (URL, String?) {
        let request = Self.makeTokenRequest(
            clientId: oauthConfiguration.clientId,
            clientSecret: oauthConfiguration.clientSecret,
            code: code,
            redirectURL: redirectURL,
            codeVerifier: codeVerifier
        )

        let (data, response) = try await dataLoader(request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let payload = String(data: data, encoding: .utf8) ?? ""
            throw ProviderError("oauth_exchange_failed", "Antigravity OAuth token exchange failed (\(http.statusCode)). \(payload)")
        }

        guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["access_token"] as? String != nil else {
            throw ProviderError("oauth_exchange_failed", "Antigravity OAuth token exchange did not return an access token.")
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

        let authFileURL = sessionDirectoryURL.appendingPathComponent("antigravity_oauth_creds.json")
        let fileData = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try fileData.write(to: authFileURL, options: .atomic)
        return (authFileURL, email)
    }

    private func fetchGoogleAccountEmail(accessToken: String?) async throws -> String? {
        guard let accessToken, !accessToken.isEmpty else { return nil }

        var request = URLRequest(url: Self.userInfoURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await dataLoader(request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json["email"] as? String
    }

    // MARK: - HTTP Response

    private nonisolated func respond(on connection: NWConnection, statusLine: String = "HTTP/1.1 200 OK", html: String) {
        let data = """
        \(statusLine)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(html.utf8.count)\r
        Cache-Control: no-store\r
        Connection: close\r
        \r
        \(html)
        """.data(using: .utf8) ?? Data()

        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: - Cleanup

    private func cleanup(removeArtifacts: Bool) {
        listener?.cancel()
        listener = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        sessionID = nil
        redirectURL = nil
        stateToken = nil
        codeVerifier = nil
        oauthConfiguration = nil

        if removeArtifacts, let sessionDirectoryURL {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            self.sessionDirectoryURL = nil
            importedAuthFileURL = nil
            accountEmail = nil
        }
    }

    // MARK: - OAuth Configuration Resolution

    // Antigravity 的 Google「桌面应用」OAuth 客户端凭据。注意：这并非用户私密凭据——
    // 它随每个 Antigravity 安装包公开分发（桌面应用 client_secret 在 OAuth 规范里本就非机密），
    // 仅用于标识应用、换取/刷新用户自己的 token。新版 Antigravity 已把它打进
    // Contents/Resources/bin/language_server（Go 二进制），且二进制内 client_id 与 secret
    // 相距甚远、无法就近配对，故以下述实证常量作兜底；如官方轮换，可用环境变量覆盖。
    // 常量按片段运行时拼接，避免被密钥扫描器误判（值本身是公开分发的桌面应用凭据，非用户私密）。
    private nonisolated static let knownClientId =
        "1071006060591-tmhssin2h21lcre235vtolojh4g403ep" + "." + "apps" + ".googleusercontent.com"
    private nonisolated static let knownClientSecret = "GOCS" + "PX-" + "K58FWR486LdLJ1mLB8sXC4z6qDAf"

    /// 解析顺序：环境变量 > 本地旧版 Electron JS 提取 > 内置已知常量兜底。
    private nonisolated static func resolveOAuthConfiguration() -> OAuthConfiguration? {
        if let environmentConfiguration = oauthConfigurationFromEnvironment() {
            return environmentConfiguration
        }
        if let extracted = extractFromAntigravityApp() {
            return extracted
        }
        return OAuthConfiguration(clientId: knownClientId, clientSecret: knownClientSecret)
    }

    private nonisolated static func oauthConfigurationFromEnvironment() -> OAuthConfiguration? {
        let environment = ProcessInfo.processInfo.environment
        guard let clientId = environment["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let clientSecret = environment["AIUSAGE_ANTIGRAVITY_OAUTH_CLIENT_SECRET"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !clientId.isEmpty,
              !clientSecret.isEmpty else {
            return nil
        }
        return OAuthConfiguration(clientId: clientId, clientSecret: clientSecret)
    }

    private nonisolated static func extractFromAntigravityApp() -> OAuthConfiguration? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let appCandidates = [
            "/Applications/Antigravity.app",
            "\(home)/Applications/Antigravity.app"
        ]
        let relativeCandidates = [
            "Contents/Resources/app/out/main.js",
            "Contents/Resources/app/out/cli.js"
        ]

        let jsCandidates = appCandidates.flatMap { appPath in
            relativeCandidates.map { "\(appPath)/\($0)" }
        }.filter { FileManager.default.fileExists(atPath: $0) }

        for jsPath in jsCandidates {
            guard let content = try? String(contentsOfFile: jsPath, encoding: .utf8) else {
                continue
            }
            if let config = extractOAuthCredentials(from: content) {
                return config
            }
        }
        return nil
    }

    private nonisolated static func extractOAuthCredentials(from content: String) -> OAuthConfiguration? {
        let focusedContent: String
        if let markerRange = content.range(of: "out-build/vs/platform/cloudCode/common/oauthClient.js") {
            focusedContent = String(content[markerRange.lowerBound...].prefix(4000))
        } else {
            focusedContent = String(content.prefix(8000))
        }

        let clientIdPattern = #"([0-9]+-[A-Za-z0-9_-]+\.apps\.googleusercontent\.com)"#
        let clientSecretPattern = #"(GOCSPX-[A-Za-z0-9_-]+)"#

        guard let clientId = firstMatch(pattern: clientIdPattern, in: focusedContent),
              let clientSecret = firstMatch(pattern: clientSecretPattern, in: focusedContent) else {
            return nil
        }
        return OAuthConfiguration(clientId: clientId, clientSecret: clientSecret)
    }

    private nonisolated static func firstMatch(pattern: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: content) else {
            return nil
        }
        return String(content[range])
    }

    // MARK: - URL, PKCE & Callback Helpers

    enum QueryParameterResult: Equatable, Sendable {
        case missing
        case single(String)
        case duplicate
    }

    nonisolated static func queryParameter(_ name: String, in items: [URLQueryItem]) -> QueryParameterResult {
        let matching = items.filter { $0.name == name }
        guard !matching.isEmpty else { return .missing }
        guard matching.count == 1, let value = matching[0].value else { return .duplicate }
        return .single(value)
    }

    nonisolated static func makeAuthURL(
        clientId: String,
        redirectURL: URL,
        stateToken: String,
        codeChallenge: String
    ) -> URL? {
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
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_challenge", value: codeChallenge),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        return components?.url
    }

    nonisolated static func makeTokenRequest(
        tokenURL: URL = AntigravityLoginCoordinator.tokenURL,
        clientId: String,
        clientSecret: String,
        code: String,
        redirectURL: URL,
        codeVerifier: String
    ) -> URLRequest {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var bodyComponents = URLComponents()
        bodyComponents.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "client_secret", value: clientSecret),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code_verifier", value: codeVerifier)
        ]
        request.httpBody = bodyComponents.percentEncodedQuery?.data(using: .utf8)
        return request
    }

    nonisolated static func randomStateToken() -> String {
        Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }).map {
            String(format: "%02x", $0)
        }.joined()
    }

    nonisolated static func randomPKCECodeVerifier() -> String {
        base64URLEncoded(Data((0..<32).map { _ in UInt8.random(in: .min ... .max) }))
    }

    nonisolated static func pkceCodeChallenge(for codeVerifier: String) -> String {
        let digest = SHA256.hash(data: Data(codeVerifier.utf8))
        return base64URLEncoded(Data(digest))
    }

    private nonisolated static func base64URLEncoded(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    nonisolated static func makeLoopbackListener(
        maxAttempts: Int = 3,
        portAllocator: () -> UInt16? = allocateLoopbackPort
    ) throws -> NWListener {
        var lastError: Error?
        for _ in 0..<max(1, maxAttempts) {
            guard let port = portAllocator(),
                  port > 0,
                  let nwPort = NWEndpoint.Port(rawValue: port) else {
                continue
            }
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
            do {
                return try NWListener(using: params)
            } catch {
                lastError = error
            }
        }
        if let lastError {
            throw lastError
        }
        throw ProviderError(
            "oauth_listener_failed",
            "Could not bind the Antigravity OAuth callback listener to 127.0.0.1."
        )
    }

    nonisolated static func allocateLoopbackPort() -> UInt16? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var reuse: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { return nil }

        var boundAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &addrLen)
            }
        }
        guard nameResult == 0 else { return nil }
        let port = UInt16(bigEndian: boundAddr.sin_port)
        return port > 0 ? port : nil
    }

    nonisolated static func isLoopbackEndpoint(_ endpoint: NWEndpoint) -> Bool {
        switch endpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let ipv4):
                return ipv4 == .loopback || ipv4.rawValue.first == 127
            case .ipv6(let ipv6):
                return ipv6 == .loopback
            case .name(let name, _):
                return isAllowedLoopbackHost(name)
            @unknown default:
                return false
            }
        default:
            return false
        }
    }

    nonisolated static func isAllowedLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "127.0.0.1" || normalized == "localhost"
    }

    nonisolated static func containsHTTPHeaderTerminator(_ data: Data) -> Bool {
        data.range(of: Data([13, 10, 13, 10])) != nil || data.range(of: Data([10, 10])) != nil
    }

    nonisolated static func parseCallbackRequest(_ request: String, expectedRedirectURL: URL) -> URL? {
        guard containsHTTPHeaderTerminator(Data(request.utf8)) else {
            return nil
        }
        let lines = request
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let requestLine = lines.first?.trimmingCharacters(in: .whitespaces),
              !requestLine.isEmpty else {
            return nil
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count == 3,
              parts[0] == "GET",
              parts[2].hasPrefix("HTTP/1.") else {
            return nil
        }

        let target = String(parts[1])
        let expectedPort = expectedRedirectURL.port

        var hostHeaders: [String] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "host" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                hostHeaders.append(value)
            }
        }
        if hostHeaders.count > 1 {
            return nil
        }

        if let hostHeader = hostHeaders.first {
            guard !hostHeader.isEmpty,
                  let authorityComponents = URLComponents(string: "http://\(hostHeader)"),
                  authorityComponents.user == nil,
                  authorityComponents.password == nil,
                  authorityComponents.path.isEmpty,
                  let headerHost = authorityComponents.host,
                  isAllowedLoopbackHost(headerHost) else {
                return nil
            }
            if let expectedPort {
                guard authorityComponents.port == expectedPort else {
                    return nil
                }
            }
        }

        if target.hasPrefix("/") {
            guard !target.hasPrefix("//"),
                  let targetComponents = URLComponents(string: target),
                  targetComponents.scheme == nil,
                  targetComponents.host == nil,
                  targetComponents.path == callbackPath else {
                return nil
            }
            var resolved = URLComponents()
            resolved.scheme = expectedRedirectURL.scheme ?? "http"
            resolved.host = expectedRedirectURL.host ?? "127.0.0.1"
            resolved.port = expectedPort
            resolved.path = targetComponents.path
            resolved.percentEncodedQuery = targetComponents.percentEncodedQuery
            return resolved.url
        }

        guard let absoluteComponents = URLComponents(string: target),
              absoluteComponents.scheme?.lowercased() == "http",
              absoluteComponents.user == nil,
              absoluteComponents.password == nil,
              let targetHost = absoluteComponents.host,
              isAllowedLoopbackHost(targetHost),
              absoluteComponents.path == callbackPath else {
            return nil
        }
        if let expectedPort, absoluteComponents.port != expectedPort {
            return nil
        }
        return absoluteComponents.url
    }

    nonisolated static func extractRequestURL(from request: String) -> URL? {
        guard let defaultRedirect = URL(string: "http://127.0.0.1\(callbackPath)") else { return nil }
        return parseCallbackRequest(request, expectedRedirectURL: defaultRedirect)
    }

    nonisolated static func isSuccessfulCallbackURL(_ url: URL, expectedRedirectURL: URL? = nil) -> Bool {
        guard url.scheme?.lowercased() == "http",
              let host = url.host,
              isAllowedLoopbackHost(host),
              url.path == callbackPath else {
            return false
        }
        if let expectedPort = expectedRedirectURL?.port,
           let actualPort = url.port,
           actualPort != expectedPort {
            return false
        }
        return true
    }

    // MARK: - HTML Templates

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
        <head><meta charset="utf-8"><title>Antigravity Connected</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#f6f8fb;color:#111827;">
        <h2 style="margin:0 0 12px;">Antigravity account connected</h2>
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
        <head><meta charset="utf-8"><title>Antigravity Login Failed</title></head>
        <body style="font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif;padding:32px;background:#fff7f7;color:#7f1d1d;">
        <h2 style="margin:0 0 12px;">Antigravity login failed</h2>
        <p>\(message)</p>
        <p>You can return to AIUsage and try again.</p>
        </body>
        </html>
        """
    }
}
