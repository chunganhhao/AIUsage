import Foundation

/// Reads quota directly from the running Antigravity.app `language_server` over
/// loopback `127.0.0.1` Connect RPC so active-account monitoring triggers zero
/// outbound Google CloudCode requests.
struct AntigravityLocalQuotaReader: Sendable {
    struct ServerProcess: Equatable, Sendable {
        let pid: Int32
        let csrfToken: String
        let preferredPorts: [Int]

        init(pid: Int32, csrfToken: String, preferredPorts: [Int] = []) {
            self.pid = pid
            self.csrfToken = csrfToken
            self.preferredPorts = preferredPorts
        }
    }

    struct ActiveSession: Equatable, Sendable {
        let baseURL: URL
        let csrfToken: String
        let email: String
        let tierId: String?
        let tierName: String?
        let projectId: String?

        init(
            baseURL: URL,
            csrfToken: String,
            email: String,
            tierId: String?,
            tierName: String?,
            projectId: String? = nil
        ) {
            self.baseURL = baseURL
            self.csrfToken = csrfToken
            self.email = email
            self.tierId = tierId
            self.tierName = tierName
            self.projectId = projectId
        }
    }

    struct LocalQuotaResult: Sendable {
        let email: String
        let tierId: String?
        let tierName: String?
        let projectId: String?
        let models: [AntigravityProvider.ModelQuota]

        init(
            email: String,
            tierId: String?,
            tierName: String?,
            projectId: String? = nil,
            models: [AntigravityProvider.ModelQuota]
        ) {
            self.email = email
            self.tierId = tierId
            self.tierName = tierName
            self.projectId = projectId
            self.models = models
        }
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
            let ports = server.preferredPorts.isEmpty ? listPorts(server.pid) : server.preferredPorts
            for port in ports {
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
                    let statusProjects = Self.embeddedProjectIds(in: [status, userStatus])
                    if Set(statusProjects.map { $0.lowercased() }).count > 1 { continue }
                    let tierId = (userTier?["id"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let tierName = (userTier?["name"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    return ActiveSession(
                        baseURL: baseURL,
                        csrfToken: server.csrfToken,
                        email: email,
                        tierId: tierId?.isEmpty == false ? tierId : nil,
                        tierName: tierName?.isEmpty == false ? tierName : nil,
                        projectId: statusProjects.first
                    )
                }
            }
        }
        return nil
    }

    func probeActiveEmail() async -> String? {
        await probeActiveSession()?.email
    }

    func fetchMatchingQuota(
        expectedEmail: String?,
        expectedProjectId: String? = nil,
        requireProjectMatch: Bool = false
    ) async -> LocalQuotaResult? {
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
        let embeddedEmails: [String?] = [
            summary["email"] as? String,
            payload["email"] as? String,
            (summary["userStatus"] as? [String: Any])?["email"] as? String,
            (payload["userStatus"] as? [String: Any])?["email"] as? String
        ]
        for rawEmbedded in embeddedEmails {
            if let embedded = rawEmbedded?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !embedded.isEmpty,
               embedded != lhs {
                return nil
            }
        }
        let embeddedProjects = Self.embeddedProjectIds(in: [
            session.projectId.map { ["projectId": $0] },
            summary,
            payload,
            summary["userStatus"] as? [String: Any],
            payload["userStatus"] as? [String: Any]
        ])
        if Set(embeddedProjects.map { $0.lowercased() }).count > 1 {
            return nil
        }
        let observedProjectId = embeddedProjects.first
        if let normalizedExpectedProject = Self.normalizedProjectId(expectedProjectId)?.lowercased() {
            if let observedLower = observedProjectId?.lowercased(),
               observedLower != normalizedExpectedProject {
                return nil
            }
            if requireProjectMatch && observedProjectId == nil {
                return nil
            }
        } else if requireProjectMatch {
            return nil
        }
        guard let models = AntigravityProvider.parseQuotaSummaryPayload(payload), !models.isEmpty else {
            return nil
        }
        return LocalQuotaResult(
            email: session.email,
            tierId: session.tierId,
            tierName: session.tierName,
            projectId: observedProjectId,
            models: models
        )
    }

    static func normalizedProjectId(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        let lower = trimmed.lowercased()
        if lower == "unknown" || lower == "aicode-consumers" {
            return nil
        }
        return trimmed
    }

    private static func embeddedProjectIds(in dictionaries: [[String: Any]?]) -> [String] {
        let keys = ["cloudaicompanionProject", "projectId", "project_id"]
        var results: [String] = []
        for dict in dictionaries {
            guard let dict else { continue }
            for key in keys {
                if let rawString = dict[key] as? String,
                   let normalized = normalizedProjectId(rawString) {
                    results.append(normalized)
                } else if let nested = dict[key] as? [String: Any],
                          let rawId = nested["id"] as? String,
                          let normalized = normalizedProjectId(rawId) {
                    results.append(normalized)
                }
            }
        }
        return results
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

    static func discoverDaemonHubServers(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        isProcessAlive: (Int32) -> Bool = { kill($0, 0) == 0 }
    ) -> [ServerProcess] {
        let daemonDir = URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".gemini/antigravity/daemon", isDirectory: true)
        let dirAttrs = try? daemonDir.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard dirAttrs?.isSymbolicLink != true,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: daemonDir,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        let hubFiles = entries
            .filter { $0.lastPathComponent.hasPrefix("hub_") && $0.pathExtension == "json" }
            .compactMap { url -> (url: URL, mtime: Date)? in
                let attrs = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .contentModificationDateKey])
                guard attrs?.isSymbolicLink != true, attrs?.isRegularFile == true else { return nil }
                return (url, attrs?.contentModificationDate ?? .distantPast)
            }
            .sorted { $0.mtime > $1.mtime }

        return hubFiles.compactMap { entry in
            guard let data = try? Data(contentsOf: entry.url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let pidNumber = json["pid"] as? NSNumber else {
                return nil
            }
            let pid = pidNumber.int32Value
            guard pid > 0, isProcessAlive(pid),
                  let rawCsrf = json["csrfToken"] as? String else {
                return nil
            }
            let csrf = rawCsrf.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !csrf.isEmpty else { return nil }

            var ports: [Int] = []
            for key in ["httpPort", "httpsPort"] {
                if let port = (json[key] as? NSNumber)?.intValue,
                   (1...65535).contains(port),
                   !ports.contains(port) {
                    ports.append(port)
                }
            }
            return ServerProcess(pid: pid, csrfToken: csrf, preferredPorts: ports)
        }
    }

    private static func discoverRunningServers() -> [ServerProcess] {
        var combined: [ServerProcess] = []
        var seen = Set<String>()
        func appendUnique(_ servers: [ServerProcess]) {
            for server in servers {
                let key = "\(server.pid):\(server.csrfToken)"
                if seen.insert(key).inserted {
                    combined.append(server)
                }
            }
        }
        appendUnique(discoverDaemonHubServers())
        if let output = runProcessCapture(executable: "/bin/ps", arguments: ["-axo", "pid=,args="]) {
            appendUnique(parseServerProcesses(fromPSOutput: output))
        }
        return combined
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

    private final class LoopbackNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
        let trustAllLoopbackHTTPS: Bool

        init(trustAllLoopbackHTTPS: Bool) {
            self.trustAllLoopbackHTTPS = trustAllLoopbackHTTPS
        }

        func urlSession(
            _ session: URLSession,
            didReceive challenge: URLAuthenticationChallenge,
            completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
        ) {
            let space = challenge.protectionSpace
            guard trustAllLoopbackHTTPS,
                  space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  space.host == "127.0.0.1" || space.host == "::1",
                  let trust = space.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: trust))
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    private static let loopbackHTTPSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: LoopbackNoRedirectDelegate(trustAllLoopbackHTTPS: false), delegateQueue: nil)
    }()

    private static let loopbackHTTPSSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config, delegate: LoopbackNoRedirectDelegate(trustAllLoopbackHTTPS: true), delegateQueue: nil)
    }()

    private static func isSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && (lhs.port ?? (lhs.scheme?.lowercased() == "https" ? 443 : 80))
                == (rhs.port ?? (rhs.scheme?.lowercased() == "https" ? 443 : 80))
    }

    private static func defaultPerformRPC(
        baseURL: URL,
        methodPath: String,
        csrfToken: String,
        body: [String: Any]
    ) async -> [String: Any]? {
        guard baseURL.host == "127.0.0.1" || baseURL.host == "::1" else { return nil }
        let url = baseURL.appendingPathComponent(methodPath)
        var request = QuotaHTTP.request(url: url, timeout: 1.5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue(csrfToken, forHTTPHeaderField: "x-codeium-csrf-token")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let session: URLSession = (baseURL.scheme == "https" ? loopbackHTTPSSession : loopbackHTTPSession)
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse,
              (200...299).contains(http.statusCode),
              let finalURL = http.url,
              isSameOrigin(url, finalURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
