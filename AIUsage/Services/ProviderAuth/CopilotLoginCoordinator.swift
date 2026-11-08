// MARK: - Copilot Login Coordinator
// Implements GitHub Device Flow OAuth for browser-based GitHub authentication
// without requiring the gh CLI. Opens a code verification page in the user's
// browser, polls for completion, and produces a GitHub token for Copilot usage.
// Data source: GitHub OAuth Device Flow → https://docs.github.com/en/apps/oauth-apps/building-oauth-apps/authorizing-oauth-apps#device-flow

import AppKit
import Combine
import Foundation
import QuotaBackend

@MainActor
final class CopilotLoginCoordinator: ObservableObject {
    @Published private(set) var phase: LoginPhase = .idle
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    /// GitHub 设备页不支持预填验证码；打开浏览器前先把验证码放进剪贴板，用户粘贴即可。
    @Published private(set) var codeCopied = false
    // 仅内部记录人类可读进度，UI 不直接展示；保持普通存储属性避免无谓的视图重渲染。
    private var outputSummary: String?
    @Published private(set) var githubToken: String?
    @Published private(set) var accountLogin: String?
    @Published private(set) var accountEmail: String?

    private nonisolated static let deviceCodeURL = URL(string: "https://github.com/login/device/code")!
    private nonisolated static let tokenURL = URL(string: "https://github.com/login/oauth/access_token")!

    // gh CLI's public OAuth App client_id. Device flow tokens appear as
    // "GitHub CLI" in the user's GitHub settings. Override via env var
    // AIUSAGE_GITHUB_OAUTH_CLIENT_ID if you register a dedicated OAuth App.
    private nonisolated static let defaultClientId = "178c6fc778ccc68e1d6a"

    private nonisolated static let scopes = "read:user user:email"
    private nonisolated static let maxPollDuration: UInt64 = 15 * 60

    private var pollingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var deviceCode: String?
    private var pollInterval: Int = 5
    private var didFinish = false

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

        phase = .launching
        userCode = nil
        verificationURL = nil
        codeCopied = false
        outputSummary = nil
        githubToken = nil
        accountLogin = nil
        accountEmail = nil
        deviceCode = nil
        didFinish = false

        Task { await beginDeviceFlow() }
    }

    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        deviceCode = nil
        didFinish = false
        phase = .idle
    }

    func reopenInBrowser() {
        guard let verificationURL else { return }
        NSWorkspace.shared.open(verificationURL)
    }

    // MARK: - Device Flow

    private func beginDeviceFlow() async {
        let clientId = Self.resolveClientId()

        var request = URLRequest(url: Self.deviceCodeURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "scope", value: Self.scopes)
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                phase = .failed("GitHub device code request failed (HTTP \(status)).")
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let code = json["device_code"] as? String,
                  let uCode = json["user_code"] as? String,
                  let vURI = json["verification_uri"] as? String else {
                phase = .failed("GitHub returned an unexpected device code response.")
                return
            }

            deviceCode = code
            userCode = uCode
            pollInterval = (json["interval"] as? Int) ?? 5

            if let fullURI = json["verification_uri_complete"] as? String,
               let url = URL(string: fullURI) {
                verificationURL = url
            } else if let url = URL(string: vURI) {
                verificationURL = url
            }

            phase = .waitingForBrowser
            outputSummary = L(
                "Enter the code in your browser to authorize AIUsage.",
                "在浏览器中输入验证码以授权 AIUsage。"
            )

            NSPasteboard.general.clearContents()
            codeCopied = NSPasteboard.general.setString(uCode, forType: .string)

            if let verificationURL {
                NSWorkspace.shared.open(verificationURL)
            }

            beginPolling(clientId: clientId, deviceCode: code)
            beginTimeout()
        } catch {
            phase = .failed("Failed to start GitHub sign-in: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    private func beginPolling(clientId: String, deviceCode: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }

            let maxIterations = Int(Self.maxPollDuration) / max(self.pollInterval, 1)
            for _ in 0..<maxIterations {
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval) * 1_000_000_000)
                guard !Task.isCancelled else { return }

                let result = await self.pollForToken(clientId: clientId, deviceCode: deviceCode)
                switch result {
                case .pending:
                    continue
                case .slowDown:
                    self.pollInterval += 5
                    continue
                case .success(let token):
                    await self.finalizeLogin(token: token)
                    return
                case .expired:
                    self.phase = .failed(L(
                        "GitHub device code expired. Please try again.",
                        "GitHub 设备码已过期，请重试。"
                    ))
                    return
                case .denied:
                    self.phase = .failed(L(
                        "GitHub authorization was denied.",
                        "GitHub 授权被拒绝。"
                    ))
                    return
                case .error(let message):
                    self.phase = .failed(message)
                    return
                }
            }

            if !self.didFinish {
                self.phase = .failed(L(
                    "GitHub authentication timed out. Please try again.",
                    "GitHub 认证超时，请重试。"
                ))
            }
        }
    }

    private enum PollResult: Sendable {
        case pending
        case slowDown
        case success(String)
        case expired
        case denied
        case error(String)
    }

    private nonisolated func pollForToken(clientId: String, deviceCode: String) async -> PollResult {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "device_code", value: deviceCode),
            URLQueryItem(name: "grant_type", value: "urn:ietf:params:oauth:grant-type:device_code")
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                return .error("GitHub token request failed.")
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("GitHub returned invalid JSON.")
            }

            if let error = json["error"] as? String {
                switch error {
                case "authorization_pending": return .pending
                case "slow_down":             return .slowDown
                case "expired_token":         return .expired
                case "access_denied":         return .denied
                default:
                    let desc = json["error_description"] as? String ?? error
                    return .error("GitHub OAuth error: \(desc)")
                }
            }

            if let token = json["access_token"] as? String, !token.isEmpty {
                return .success(token)
            }

            return .pending
        } catch {
            return .error("GitHub token poll failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    // MARK: - Finalize

    private func finalizeLogin(token: String) async {
        guard !didFinish else { return }

        phase = .waitingForCompletion
        outputSummary = L(
            "GitHub authorized. Verifying account…",
            "GitHub 已授权，正在验证账号…"
        )

        let (login, email) = await fetchGitHubUserInfo(token: token)

        didFinish = true
        githubToken = token
        accountLogin = login
        accountEmail = email
        phase = .succeeded

        if let login, !login.isEmpty {
            outputSummary = L(
                "GitHub Copilot connected for @\(login).",
                "已连接 GitHub Copilot 账号 @\(login)。"
            )
        } else if let email, !email.isEmpty {
            outputSummary = L(
                "GitHub Copilot connected for \(email).",
                "已连接 GitHub Copilot 账号 \(email)。"
            )
        } else {
            outputSummary = L(
                "GitHub Copilot account connected.",
                "GitHub Copilot 账号已连接。"
            )
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    private nonisolated func fetchGitHubUserInfo(token: String) async -> (String?, String?) {
        var login: String?
        var email: String?

        if let url = URL(string: "https://api.github.com/user") {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("token \(token)", forHTTPHeaderField: "Authorization")

            if let (data, _) = try? await URLSession.shared.data(for: req),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                login = json["login"] as? String
                if let e = json["email"] as? String, !e.isEmpty { email = e }
            }
        }

        if email == nil, let url = URL(string: "https://api.github.com/user/emails") {
            var req = URLRequest(url: url, timeoutInterval: 10)
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            req.setValue("token \(token)", forHTTPHeaderField: "Authorization")

            if let (data, _) = try? await URLSession.shared.data(for: req),
               let emails = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                email = emails
                    .first(where: { ($0["primary"] as? Bool) == true && ($0["verified"] as? Bool) == true })?["email"] as? String
                    ?? emails
                    .first(where: { ($0["verified"] as? Bool) == true })?["email"] as? String
            }
        }

        return (login, email)
    }

    // MARK: - Timeout

    private func beginTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxPollDuration * 1_000_000_000)
            guard let self, !Task.isCancelled, !didFinish else { return }
            self.pollingTask?.cancel()
            self.phase = .failed(L(
                "GitHub authentication timed out after 15 minutes. Please try again.",
                "GitHub 认证 15 分钟超时，请重试。"
            ))
        }
    }

    // MARK: - Client ID Resolution

    private nonisolated static func resolveClientId() -> String {
        if let envId = ProcessInfo.processInfo.environment["AIUSAGE_GITHUB_OAUTH_CLIENT_ID"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !envId.isEmpty {
            return envId
        }
        return defaultClientId
    }
}
