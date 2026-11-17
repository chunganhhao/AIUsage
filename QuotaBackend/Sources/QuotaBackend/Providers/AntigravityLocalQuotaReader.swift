import Foundation

/// Reads quota directly from the running Antigravity.app `language_server` over
/// loopback `127.0.0.1` Connect RPC so active-account monitoring triggers zero
/// outbound Google CloudCode requests.
struct AntigravityLocalQuotaReader: Sendable {
    struct ServerProcess: Equatable, Sendable {
        let pid: Int32
        let csrfToken: String
    }

    struct ActiveSession: Equatable, Sendable {
        let baseURL: URL
        let csrfToken: String
        let email: String
        let tierId: String?
        let tierName: String?
    }

    struct LocalQuotaResult: Sendable {
        let email: String
        let tierId: String?
        let tierName: String?
        let models: [AntigravityProvider.ModelQuota]
    }

    typealias ProcessLister = @Sendable () -> [ServerProcess]
    typealias PortLister = @Sendable (Int32) -> [Int]
    typealias RPCCaller = @Sendable (URL, String, String, [String: Any]) async -> [String: Any]?

    static let live = AntigravityLocalQuotaReader()

    private let listProcesses: ProcessLister
    private let listPorts: PortLister
    private let callRPC: RPCCaller

    init(
        listProcesses: @escaping ProcessLister = { AntigravityLocalQuotaReader.discoverRunningServers() },
        listPorts: @escaping PortLister = { AntigravityLocalQuotaReader.discoverListeningPorts(pid: $0) },
        callRPC: @escaping RPCCaller = { await AntigravityLocalQuotaReader.defaultPerformRPC(baseURL: $0, methodPath: $1, csrfToken: $2, body: $3) }
    ) {
        self.listProcesses = listProcesses
        self.listPorts = listPorts
        self.callRPC = callRPC
    }

    func probeActiveSession() async -> ActiveSession? {
        for server in listProcesses() {
            for port in listPorts(server.pid) {
                for scheme in ["http", "https"] {
                    guard let baseURL = URL(string: "\(scheme)://127.0.0.1:\(port)") else { continue }
                    guard let status = await callRPC(
                        baseURL,
                        "exa.language_server_pb.LanguageServerService/GetUserStatus",
                        server.csrfToken,
                        [:]
                    ),
                    let userStatus = status["userStatus"] as? [String: Any],
                    let rawEmail = userStatus["email"] as? String else { continue }
                    let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !email.isEmpty else { continue }
                    let userTier = userStatus["userTier"] as? [String: Any]
                    let tierId = (userTier?["id"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let tierName = (userTier?["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return ActiveSession(
                        baseURL: baseURL,
                        csrfToken: server.csrfToken,
                        email: email,
                        tierId: tierId?.isEmpty == false ? tierId : nil,
                        tierName: tierName?.isEmpty == false ? tierName : nil
                    )
                }
            }
        }
        return nil
    }

    func probeActiveEmail() async -> String? {
        await probeActiveSession()?.email
    }

    func fetchMatchingQuota(expectedEmail: String?) async -> LocalQuotaResult? {
        guard let lhs = expectedEmail?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !lhs.isEmpty,
              let session = await probeActiveSession(),
              lhs == session.email.lowercased() else {
            return nil
        }
        guard let summary = await callRPC(
            session.baseURL,
            "exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary",
            session.csrfToken,
            ["request": [String: Any](), "forceRefresh": false]
        ) else { return nil }

        let payload = (summary["response"] as? [String: Any]) ?? summary
        guard let models = AntigravityProvider.parseQuotaSummaryPayload(payload), !models.isEmpty else {
            return nil
        }
        return LocalQuotaResult(
            email: session.email,
            tierId: session.tierId,
            tierName: session.tierName,
            models: models
        )
    }

    // MARK: - Process & Port Parsing

    static func parseServerProcesses(fromPSOutput output: String) -> [ServerProcess] {
        output.split(separator: "\n").compactMap { rawLine in
            let line = String(rawLine).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, line.contains("/Antigravity.app/Contents/Resources/bin/language_server") else {
                return nil
            }
            let parts = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard parts.count == 2, let pid = Int32(parts[0]) else { return nil }
            let argsString = String(parts[1])
            guard let csrf = extractFlagValue(named: "--csrf_token", from: argsString) else { return nil }
            return ServerProcess(pid: pid, csrfToken: csrf)
        }
    }

    static func parseListeningPorts(fromLsofOutput output: String) -> [Int] {
        var ports = Set<Int>()
        for rawLine in output.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("n") else { continue }
            let endpoint = line.dropFirst()
            guard endpoint.hasPrefix("127.0.0.1:") || endpoint.hasPrefix("[::1]:") || endpoint.hasPrefix("*:") else {
                continue
            }
            if let colon = endpoint.lastIndex(of: ":"),
               let port = Int(endpoint[endpoint.index(after: colon)...]),
               (1...65535).contains(port) {
                ports.insert(port)
            }
        }
        return ports.sorted()
    }

    private static func extractFlagValue(named flag: String, from args: String) -> String? {
        let tokens = args.split(whereSeparator: \.isWhitespace).map(String.init)
        for (idx, token) in tokens.enumerated() {
            if token == flag, idx + 1 < tokens.count {
                let candidate = tokens[idx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.isEmpty ? nil : candidate
            }
            if token.hasPrefix(flag + "=") {
                let candidate = String(token.dropFirst(flag.count + 1)).trimmingCharacters(in: .whitespacesAndNewlines)
                return candidate.isEmpty ? nil : candidate
            }
        }
        return nil
    }

    // MARK: - Live Process Discovery & Loopback Transport

    private static func discoverRunningServers() -> [ServerProcess] {
        guard let output = runProcessCapture(executable: "/bin/ps", arguments: ["-axo", "pid=,args="]) else {
            return []
        }
        return parseServerProcesses(fromPSOutput: output)
    }

    private static func discoverListeningPorts(pid: Int32) -> [Int] {
        guard let output = runProcessCapture(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-a", "-p", "\(pid)", "-iTCP", "-sTCP:LISTEN", "-Fn"]
        ) else { return [] }
        return parseListeningPorts(fromLsofOutput: output)
    }

    private final class LockedData: @unchecked Sendable {
        private let lock = NSLock()
        private var storage = Data()
        func set(_ data: Data) { lock.lock(); defer { lock.unlock() }; storage = data }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return storage }
    }

    static func runProcessCapture(executable: String, arguments: [String], timeoutSeconds: TimeInterval = 1.0) -> String? {
        guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.terminationHandler = { _ in }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }

        // Drain stdout concurrently before waitUntilExit; waiting first deadlocks when output exceeds the 64 KB pipe buffer (e.g. ps).
        let reader = pipe.fileHandleForReading
        let output = LockedData()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            output.set(reader.readDataToEndOfFile())
            drained.signal()
        }
        if drained.wait(timeout: .now() + timeoutSeconds) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = drained.wait(timeout: .now() + 0.2)
            return nil
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: output.get(), as: UTF8.self)
    }

    private final class LoopbackTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  space.host == "127.0.0.1" || space.host == "::1",
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    private static let loopbackHTTPSSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: LoopbackTrustDelegate(), delegateQueue: nil)
    }()

    private static func defaultPerformRPC(
        baseURL: URL,
        methodPath: String,
        csrfToken: String,
        body: [String: Any]
    ) async -> [String: Any]? {
        let url = baseURL.appendingPathComponent(methodPath)
        var request = QuotaHTTP.request(url: url, timeout: 1.5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let session: URLSession = QuotaHTTP.sessionOverride
            ?? (baseURL.scheme == "https" ? loopbackHTTPSSession : QuotaHTTP.session)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
