// MARK: - Kiro Login Coordinator
// Implements AWS SSO OIDC Device Authorization Flow for Kiro.
// Supports all Kiro login methods: Google, GitHub, Builder ID, Organization.
// Flow: register-client → start-device-authorization → poll create-token.
// Data source: AWS SSO OIDC → https://docs.aws.amazon.com/singlesignon/latest/OIDCAPIReference/

import AppKit
import Combine
import Foundation
import QuotaBackend

@MainActor
final class KiroLoginCoordinator: ObservableObject {
    @Published private(set) var phase: LoginPhase = .idle
    @Published private(set) var userCode: String?
    @Published private(set) var verificationURL: URL?
    /// AWS 授权页通过 verificationUriComplete 预填了验证码，用户只需核对后确认。
    @Published private(set) var codeIsPrefilled = false
    // 仅内部记录人类可读进度，UI 不直接展示；保持普通存储属性避免无谓的视图重渲染。
    private var outputSummary: String?
    @Published private(set) var importedAuthFileURL: URL?
    @Published private(set) var accountEmail: String?

    private static let defaultRegion = "us-east-1"
    private static let startURL = "https://view.awsapps.com/start/"
    private static let scopes = [
        "codewhisperer:completions",
        "codewhisperer:analysis",
        "codewhisperer:conversations",
        "codewhisperer:transformations",
        "codewhisperer:taskassist"
    ]
    private static let maxPollDuration: UInt64 = 15 * 60

    private var pollingTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var sessionDirectoryURL: URL?
    private var registeredClientId: String?
    private var registeredClientSecret: String?
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
        codeIsPrefilled = false
        outputSummary = nil
        importedAuthFileURL = nil
        accountEmail = nil
        registeredClientId = nil
        registeredClientSecret = nil
        deviceCode = nil
        didFinish = false

        let sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aiusage-kiro-login-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        } catch {
            phase = .failed("Failed to prepare Kiro login session: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return
        }
        sessionDirectoryURL = sessionDirectory

        Task { await beginDeviceFlow() }
    }

    func cancel() {
        pollingTask?.cancel()
        pollingTask = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        registeredClientId = nil
        registeredClientSecret = nil
        deviceCode = nil
        didFinish = false
        cleanup(removeArtifacts: true)
        phase = .idle
    }

    func discardImportedSession() {
        cleanup(removeArtifacts: true)
    }

    func reopenInBrowser() {
        guard let verificationURL else { return }
        NSWorkspace.shared.open(verificationURL)
    }

    // MARK: - AWS SSO OIDC Device Flow

    private func beginDeviceFlow() async {
        let region = Self.defaultRegion
        let oidcBase = "https://oidc.\(region).amazonaws.com"

        outputSummary = L("Registering with AWS SSO…", "正在向 AWS SSO 注册…")

        // Step 1: Register client
        guard let registration = await registerClient(oidcBase: oidcBase) else { return }
        registeredClientId = registration.clientId
        registeredClientSecret = registration.clientSecret

        // Step 2: Start device authorization
        guard let authorization = await startDeviceAuthorization(
            oidcBase: oidcBase,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret
        ) else { return }

        deviceCode = authorization.deviceCode
        userCode = authorization.userCode
        pollInterval = authorization.interval

        if let fullURI = authorization.verificationUriComplete, let url = URL(string: fullURI) {
            verificationURL = url
            codeIsPrefilled = true
        } else if let url = URL(string: authorization.verificationUri) {
            verificationURL = url
        }

        phase = .waitingForBrowser
        outputSummary = L(
            "Enter the code on the Kiro sign-in page to connect your account.",
            "在 Kiro 登录页上输入验证码以连接你的账号。"
        )

        if let verificationURL {
            NSWorkspace.shared.open(verificationURL)
        }

        beginPolling(
            oidcBase: oidcBase,
            clientId: registration.clientId,
            clientSecret: registration.clientSecret,
            deviceCode: authorization.deviceCode,
            region: region
        )
        beginTimeout()
    }

    // MARK: - Step 1: Register Client

    private struct ClientRegistration {
        let clientId: String
        let clientSecret: String
    }

    private nonisolated static let kiroUserAgent = "aws-sdk-js/3.980.0 ua/2.1 os/other lang/js md/browser#unknown_unknown api/sso-oidc#3.980.0 m/E KiroIDE"

    private func registerClient(oidcBase: String) async -> ClientRegistration? {
        guard let url = URL(string: "\(oidcBase)/client/register") else {
            phase = .failed("Invalid AWS SSO OIDC URL.")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.kiroUserAgent, forHTTPHeaderField: "x-amz-user-agent")

        let body: [String: Any] = [
            "clientName": "Kiro IDE",
            "clientType": "public",
            "scopes": Self.scopes
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                phase = .failed("AWS SSO client registration failed (HTTP \(status)). \(body.prefix(200))")
                return nil
            }

            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                phase = .failed("AWS SSO client registration returned invalid JSON.")
                return nil
            }

            let json: [String: Any]
            if let output = raw["Output"] as? [String: Any] {
                json = output
            } else if let outputStr = raw["Output"] as? String,
                      let outputData = outputStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] {
                json = parsed
            } else {
                json = raw
            }

            let clientIdVal = json["clientId"] as? String ?? json["ClientId"] as? String
            let clientSecretVal = json["clientSecret"] as? String ?? json["ClientSecret"] as? String

            guard let clientId = clientIdVal,
                  let clientSecret = clientSecretVal else {
                let hint = (json["error_description"] ?? json["error"] ?? json["message"]) as? String ?? ""
                phase = .failed("AWS SSO client registration missing credentials. \(hint)")
                return nil
            }

            return ClientRegistration(clientId: clientId, clientSecret: clientSecret)
        } catch {
            phase = .failed("AWS SSO client registration failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return nil
        }
    }

    // MARK: - Step 2: Start Device Authorization

    private struct DeviceAuthorization {
        let deviceCode: String
        let userCode: String
        let verificationUri: String
        let verificationUriComplete: String?
        let interval: Int
    }

    private func startDeviceAuthorization(oidcBase: String, clientId: String, clientSecret: String) async -> DeviceAuthorization? {
        guard let url = URL(string: "\(oidcBase)/device_authorization") else {
            phase = .failed("Invalid AWS SSO OIDC URL.")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.kiroUserAgent, forHTTPHeaderField: "x-amz-user-agent")

        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "startUrl": Self.startURL
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                let body = String(data: data, encoding: .utf8) ?? ""
                phase = .failed("AWS SSO device authorization failed (HTTP \(status)). \(body.prefix(200))")
                return nil
            }

            guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                phase = .failed("AWS SSO device authorization returned invalid JSON.")
                return nil
            }

            let json: [String: Any]
            if let output = raw["Output"] as? [String: Any] {
                json = output
            } else if let outputStr = raw["Output"] as? String,
                      let outputData = outputStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] {
                json = parsed
            } else {
                json = raw
            }

            let deviceCodeVal = json["deviceCode"] as? String ?? json["DeviceCode"] as? String
            let userCodeVal = json["userCode"] as? String ?? json["UserCode"] as? String
            let verificationUriVal = json["verificationUri"] as? String ?? json["VerificationUri"] as? String

            guard let deviceCode = deviceCodeVal,
                  let userCode = userCodeVal,
                  let verificationUri = verificationUriVal else {
                let hint = (json["error_description"] ?? json["error"] ?? json["message"]) as? String ?? ""
                phase = .failed("AWS SSO device authorization missing expected fields. \(hint)")
                return nil
            }

            let verificationUriComplete = json["verificationUriComplete"] as? String ?? json["VerificationUriComplete"] as? String
            let interval = (json["interval"] as? Int) ?? (json["Interval"] as? Int) ?? 5

            return DeviceAuthorization(
                deviceCode: deviceCode,
                userCode: userCode,
                verificationUri: verificationUri,
                verificationUriComplete: verificationUriComplete,
                interval: interval
            )
        } catch {
            phase = .failed("AWS SSO device authorization failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
            return nil
        }
    }

    // MARK: - Step 3: Poll for Token

    private func beginPolling(oidcBase: String, clientId: String, clientSecret: String, deviceCode: String, region: String) {
        pollingTask?.cancel()
        pollingTask = Task { [weak self] in
            guard let self else { return }

            let maxIterations = Int(Self.maxPollDuration) / max(self.pollInterval, 1)
            for _ in 0..<maxIterations {
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval) * 1_000_000_000)
                guard !Task.isCancelled else { return }

                let result = await self.pollForToken(
                    oidcBase: oidcBase,
                    clientId: clientId,
                    clientSecret: clientSecret,
                    deviceCode: deviceCode
                )

                switch result {
                case .pending:
                    continue
                case .slowDown:
                    self.pollInterval += 5
                    continue
                case .success(let tokenData):
                    await self.finalizeLogin(
                        tokenData: tokenData,
                        clientId: clientId,
                        clientSecret: clientSecret,
                        region: region
                    )
                    return
                case .expired:
                    self.phase = .failed(L(
                        "Kiro device code expired. Please try again.",
                        "Kiro 设备码已过期，请重试。"
                    ))
                    return
                case .denied:
                    self.phase = .failed(L(
                        "Kiro authorization was denied.",
                        "Kiro 授权被拒绝。"
                    ))
                    return
                case .error(let message):
                    self.phase = .failed(message)
                    return
                }
            }

            if !self.didFinish {
                self.phase = .failed(L(
                    "Kiro authentication timed out. Please try again.",
                    "Kiro 认证超时，请重试。"
                ))
            }
        }
    }

    private struct OIDCTokenData: Sendable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Int
        let idToken: String?
    }

    private enum PollResult: Sendable {
        case pending
        case slowDown
        case success(OIDCTokenData)
        case expired
        case denied
        case error(String)
    }

    private nonisolated func pollForToken(oidcBase: String, clientId: String, clientSecret: String, deviceCode: String) async -> PollResult {
        guard let url = URL(string: "\(oidcBase)/token") else {
            return .error("Invalid AWS SSO OIDC token URL.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.kiroUserAgent, forHTTPHeaderField: "x-amz-user-agent")

        let body: [String: Any] = [
            "clientId": clientId,
            "clientSecret": clientSecret,
            "grantType": "urn:ietf:params:oauth:grant-type:device_code",
            "deviceCode": deviceCode
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return .error("AWS SSO returned invalid JSON.")
            }

            let json: [String: Any]
            if let output = raw["Output"] as? [String: Any] {
                json = output
            } else if let outputStr = raw["Output"] as? String,
                      let outputData = outputStr.data(using: .utf8),
                      let parsed = try? JSONSerialization.jsonObject(with: outputData) as? [String: Any] {
                json = parsed
            } else {
                json = raw
            }

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let errorCode = json["error"] as? String ?? ""
                switch errorCode {
                case "authorization_pending": return .pending
                case "slow_down":             return .slowDown
                case "expired_token":         return .expired
                case "access_denied":         return .denied
                default:
                    let desc = json["error_description"] as? String ?? errorCode
                    return .error("AWS SSO error: \(desc)")
                }
            }

            let accessToken = json["accessToken"] as? String ?? json["AccessToken"] as? String ?? ""
            if !accessToken.isEmpty {
                return .success(OIDCTokenData(
                    accessToken: accessToken,
                    refreshToken: json["refreshToken"] as? String ?? json["RefreshToken"] as? String,
                    expiresIn: (json["expiresIn"] as? Int) ?? (json["ExpiresIn"] as? Int) ?? 3600,
                    idToken: json["idToken"] as? String ?? json["IdToken"] as? String
                ))
            }

            return .pending
        } catch {
            return .error("AWS SSO token poll failed: \(SensitiveDataRedactor.redactedMessage(for: error))")
        }
    }

    // MARK: - Finalize

    private func finalizeLogin(tokenData: OIDCTokenData, clientId: String, clientSecret: String, region: String) async {
        guard !didFinish, let sessionDirectoryURL else { return }

        phase = .waitingForCompletion
        outputSummary = L("Kiro authorized. Saving account…", "Kiro 已授权，正在保存账号…")

        let email = extractEmail(from: tokenData.idToken)
        let expiresAt = ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(tokenData.expiresIn)))

        var authJSON: [String: Any] = [
            "access_token": tokenData.accessToken,
            "expires_at": expiresAt,
            "client_id": clientId,
            "client_secret": clientSecret,
            "auth_method": "idc",
            "region": region
        ]
        if let refreshToken = tokenData.refreshToken {
            authJSON["refresh_token"] = refreshToken
        }
        if let email, !email.isEmpty {
            authJSON["email"] = email
        }

        let authFileURL = sessionDirectoryURL.appendingPathComponent("kiro-aiusage-login.json")
        guard let data = try? JSONSerialization.data(withJSONObject: authJSON, options: [.prettyPrinted, .sortedKeys]),
              let _ = try? data.write(to: authFileURL, options: .atomic) else {
            phase = .failed(L(
                "Failed to save Kiro auth file.",
                "保存 Kiro 认证文件失败。"
            ))
            return
        }

        didFinish = true
        importedAuthFileURL = authFileURL
        accountEmail = email
        phase = .succeeded

        if let email, !email.isEmpty {
            outputSummary = L("Kiro account connected for \(email).", "已连接 Kiro 账号 \(email)。")
        } else {
            outputSummary = L("Kiro account connected.", "Kiro 账号已连接。")
        }

        timeoutTask?.cancel()
        timeoutTask = nil
        pollingTask?.cancel()
        pollingTask = nil
    }

    private nonisolated func extractEmail(from idToken: String?) -> String? {
        guard let idToken, idToken.contains(".") else { return nil }
        let segments = idToken.split(separator: ".")
        guard segments.count >= 2 else { return nil }
        var payload = String(segments[1])
        let remainder = payload.count % 4
        if remainder > 0 { payload += String(repeating: "=", count: 4 - remainder) }
        payload = payload.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: payload),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Timeout

    private func beginTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.maxPollDuration * 1_000_000_000)
            guard let self, !Task.isCancelled, !didFinish else { return }
            self.pollingTask?.cancel()
            self.phase = .failed(L(
                "Kiro authentication timed out after 15 minutes. Please try again.",
                "Kiro 认证 15 分钟超时，请重试。"
            ))
        }
    }

    // MARK: - Cleanup

    private func cleanup(removeArtifacts: Bool) {
        if removeArtifacts, let sessionDirectoryURL {
            try? FileManager.default.removeItem(at: sessionDirectoryURL)
            self.sessionDirectoryURL = nil
            importedAuthFileURL = nil
            accountEmail = nil
        }
    }
}
