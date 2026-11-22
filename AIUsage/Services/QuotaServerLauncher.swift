import Foundation
import os.log
import Security
import Darwin
import QuotaBackend

private final class NoRedirectHealthSessionDelegate: NSObject, URLSessionTaskDelegate {
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

// MARK: - QuotaServer Unified Cold Start
// 三条代理轨（Claude/Codex/OpenCode + Science）共用的唯一 QuotaServer 冷启动实现。
// 候选可执行文件的发现与按需构建见 QuotaServerLocator.swift。

private let launcherLog = Logger(subsystem: "com.aiusage.desktop", category: "QuotaServerLauncher")

/// 启动失败的类别是稳定契约：UI 可以给出精确提示，日志仍保留完整 stderr。
enum QuotaServerStartupError: LocalizedError {
    case executableNotFound
    case signatureBlocked(path: String, diagnostic: String, stderr: String)
    case portInUse(port: Int, stderr: String)
    case launchFailed(path: String, reason: String, stderr: String)
    case processExited(path: String, status: Int32, reason: Process.TerminationReason, stderr: String)
    case healthCheckTimedOut(path: String, lastProbe: String, stderr: String)

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return AppSettings.shared.t(
                "QuotaServer helper was not found.",
                "未找到 QuotaServer 辅助程序。"
            )
        case .signatureBlocked:
            return AppSettings.shared.t(
                "QuotaServer was blocked by macOS code-signing validation. Reinstall a correctly signed build.",
                "QuotaServer 被 macOS 代码签名校验阻止。请重新安装签名正确的版本。"
            )
        case .portInUse(let port, _):
            return AppSettings.shared.t(
                "Port \(port) is already in use by another process.",
                "端口 \(port) 已被其它进程占用。"
            )
        case .launchFailed(_, let reason, _):
            return AppSettings.shared.t(
                "QuotaServer could not be launched: \(reason)",
                "QuotaServer 无法启动：\(reason)"
            )
        case .processExited(_, let status, let reason, _):
            let reasonText = reason == .uncaughtSignal ? "signal" : "exit"
            return AppSettings.shared.t(
                "QuotaServer exited during startup (\(reasonText) \(status)).",
                "QuotaServer 在启动阶段退出（\(reasonText) \(status)）。"
            )
        case .healthCheckTimedOut(_, let lastProbe, _):
            return AppSettings.shared.t(
                "QuotaServer kept running, but its health check timed out: \(lastProbe)",
                "QuotaServer 进程仍在运行，但健康检查超时：\(lastProbe)"
            )
        }
    }

    var startupStderr: String {
        switch self {
        case .executableNotFound:
            return ""
        case .signatureBlocked(_, _, let stderr),
             .portInUse(_, let stderr),
             .launchFailed(_, _, let stderr),
             .processExited(_, _, _, let stderr),
             .healthCheckTimedOut(_, _, let stderr):
            return stderr
        }
    }

    var supplementalDiagnostic: String {
        if case .signatureBlocked(_, let diagnostic, _) = self {
            return diagnostic
        }
        return ""
    }
}

struct QuotaServerLaunchResult {
    let process: Process
    let executable: QuotaServerExecutable
    /// 从 spawn 到 /health ready 之间的完整 stderr，供诊断与回归测试使用。
    let startupStderr: String
}

/// 三条代理轨共用的唯一 QuotaServer 冷启动实现。
///
/// - 分离 stdout/stderr，避免业务日志解析吞掉启动错误；
/// - 首选候选在 spawn 或早退时自动尝试下一个候选；
/// - 活进程健康超时不会盲目换二进制（这通常是配置/系统问题）；
/// - SIGTRAP/SIGKILL 本身不等同签名错误，只在明确的 codesign 诊断出现时归类签名。
@MainActor
enum QuotaServerLauncher {
    static func launch(
        arguments: [String],
        environment: [String: String],
        healthURL: URL,
        startupTimeout: TimeInterval,
        probeIntervalNanos: UInt64,
        stdoutLineHandler: @escaping (String) -> Void
    ) async throws -> QuotaServerLaunchResult {
        var candidates = QuotaServerLocator.availableExecutables()
        if candidates.isEmpty, let built = await QuotaServerLocator.buildFallback() {
            candidates.append(built)
        }
        guard !candidates.isEmpty else { throw QuotaServerStartupError.executableNotFound }

        let startupToken = UUID().uuidString
        var launchEnvironment = environment
        launchEnvironment["AIUSAGE_STARTUP_TOKEN"] = startupToken

        var attemptedOnDemandBuild = candidates.contains(where: { $0.origin == .onDemandBuild })
        var index = 0
        while index < candidates.count {
            let candidate = candidates[index]
            do {
                return try await launchCandidate(
                    candidate,
                    arguments: arguments,
                    environment: launchEnvironment,
                    healthURL: healthURL,
                    startupToken: startupToken,
                    startupTimeout: startupTimeout,
                    probeIntervalNanos: probeIntervalNanos,
                    stdoutLineHandler: stdoutLineHandler
                )
            } catch let error as QuotaServerStartupError {
                logFailure(error, candidate: candidate)

                switch error {
                case .portInUse, .executableNotFound:
                    throw error
                case .healthCheckTimedOut:
#if DEBUG
                    break
#else
                    throw error
#endif
                case .launchFailed, .processExited, .signatureBlocked:
                    break
                }

                index += 1
                if index >= candidates.count, !attemptedOnDemandBuild {
                    attemptedOnDemandBuild = true
                    if let built = await QuotaServerLocator.buildFallback(),
                       !candidates.contains(where: { $0.path == built.path }) {
                        candidates.append(built)
                    }
                }
                if index < candidates.count {
                    launcherLog.notice(
                        "QuotaServer cold start failed from \(candidate.origin.rawValue, privacy: .public); trying the next executable candidate"
                    )
                    continue
                }
                throw error
            }
        }

        throw QuotaServerStartupError.executableNotFound
    }

    private static let healthProbeDelegate = NoRedirectHealthSessionDelegate()
    private static let healthProbeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: healthProbeDelegate, delegateQueue: nil)
    }()

    private static func launchCandidate(
        _ candidate: QuotaServerExecutable,
        arguments: [String],
        environment: [String: String],
        healthURL: URL,
        startupToken: String,
        startupTimeout: TimeInterval,
        probeIntervalNanos: UInt64,
        stdoutLineHandler: @escaping (String) -> Void
    ) async throws -> QuotaServerLaunchResult {
        if candidate.origin == .bundledHelper,
           let diagnostic = bundledSignatureFailure(atPath: candidate.path) {
            throw QuotaServerStartupError.signatureBlocked(
                path: candidate.path,
                diagnostic: diagnostic,
                stderr: ""
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: candidate.path)
        process.arguments = arguments
        process.environment = environment

        let capture = QuotaServerStartupCapture(
            executable: candidate,
            stdoutLineHandler: stdoutLineHandler
        )
        capture.attach(to: process)

        do {
            try process.run()
            capture.startReading()
        } catch {
            let failure = classifyLaunchFailure(
                path: candidate.path,
                reason: error.localizedDescription,
                stderr: capture.stderrSnapshot
            )
            throw failure
        }

        let deadline = Date().addingTimeInterval(startupTimeout)
        var lastProbe = "health check did not complete"
        repeat {
            if !process.isRunning {
                let stderr = capture.finishAfterProcessExit()
                let failure = classifyExitedProcess(
                    process,
                    path: candidate.path,
                    stderr: stderr,
                    port: healthURL.port
                )
                throw failure
            }

            do {
                let challenge = UUID().uuidString
                var request = URLRequest(url: healthURL, timeoutInterval: 1)
                request.httpMethod = "GET"
                request.setValue(challenge, forHTTPHeaderField: QuotaServerHealthProof.challengeHeader)
                let (data, response) = try await healthProbeSession.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    let expectedProof = QuotaServerHealthProof.compute(
                        challenge: challenge,
                        startupToken: startupToken
                    ) ?? ""
                    let receivedProof = (payload?["instanceProof"] as? String) ?? ""
                    guard payload?["instanceToken"] == nil,
                          !expectedProof.isEmpty,
                          QuotaShareServer.constantTimeEquals(Array(receivedProof.utf8), Array(expectedProof.utf8)) else {
                        lastProbe = "health endpoint belongs to another process"
                        try? await Task.sleep(nanoseconds: probeIntervalNanos)
                        continue
                    }
                    // 防止另一个进程恰好占用同端口时，把它的 /health 当成当前子进程成功。
                    guard process.isRunning else { continue }
                    let startupStderr = capture.markReady()
                    launcherLog.info(
                        "QuotaServer ready from \(candidate.origin.rawValue, privacy: .public) at \(candidate.path, privacy: .public) pid=\(process.processIdentifier, privacy: .public)"
                    )
                    return QuotaServerLaunchResult(
                        process: process,
                        executable: candidate,
                        startupStderr: startupStderr
                    )
                }
                if let http = response as? HTTPURLResponse {
                    lastProbe = "HTTP \(http.statusCode)"
                } else {
                    lastProbe = "non-HTTP response"
                }
            } catch {
                lastProbe = error.localizedDescription
            }

            try? await Task.sleep(nanoseconds: probeIntervalNanos)
        } while Date() < deadline

        if !process.isRunning {
            let stderr = capture.finishAfterProcessExit()
            let failure = classifyExitedProcess(
                process,
                path: candidate.path,
                stderr: stderr,
                port: healthURL.port
            )
            throw failure
        }

        await terminateOwnedProcess(process)
        let stderr = capture.finishAfterProcessExit()
        throw QuotaServerStartupError.healthCheckTimedOut(
            path: candidate.path,
            lastProbe: lastProbe,
            stderr: stderr
        )
    }

    static func terminateOwnedProcess(_ process: Process) async {
        guard process.isRunning else { return }
        process.terminate()
        let gracefulDeadline = Date().addingTimeInterval(0.75)
        while process.isRunning, Date() < gracefulDeadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        if process.isRunning {
            launcherLog.notice("Force-stopping unready QuotaServer pid=\(process.processIdentifier, privacy: .public)")
            kill(process.processIdentifier, SIGKILL)
            let killDeadline = Date().addingTimeInterval(0.5)
            while process.isRunning, Date() < killDeadline {
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
        }
    }

    private static func classifyLaunchFailure(
        path: String,
        reason: String,
        stderr: String
    ) -> QuotaServerStartupError {
        let diagnostic = reason + "\n" + stderr
        if indicatesSignatureBlock(diagnostic) {
            return .signatureBlocked(path: path, diagnostic: diagnostic, stderr: stderr)
        }
        return .launchFailed(path: path, reason: reason, stderr: stderr)
    }

    private static func classifyExitedProcess(
        _ process: Process,
        path: String,
        stderr: String,
        port: Int?
    ) -> QuotaServerStartupError {
        if indicatesPortConflict(stderr), let port {
            return .portInUse(port: port, stderr: stderr)
        }
        if indicatesSignatureBlock(stderr) {
            return .signatureBlocked(path: path, diagnostic: stderr, stderr: stderr)
        }
        return .processExited(
            path: path,
            status: process.terminationStatus,
            reason: process.terminationReason,
            stderr: stderr
        )
    }

    static func indicatesPortConflict(_ diagnostic: String) -> Bool {
        let value = diagnostic.lowercased()
        return value.contains("category=port_in_use")
            || value.contains("address already in use")
            || value.contains("eaddrinuse")
    }

    static func indicatesSignatureBlock(_ diagnostic: String) -> Bool {
        let value = diagnostic.lowercased()
        return value.contains("category=signature_blocked")
            || value.contains("code signature invalid")
            || value.contains("code signature in")
            || value.contains("codesign")
            || value.contains("errseccs")
            || value.contains("mapped file has no cdhash")
            || value.contains("library validation")
            || value.contains("not valid for use in process")
            || value.contains("disallowed by system policy")
    }

    /// 对 bundle nested code 做真正的静态校验。不能把 SIGTRAP/SIGKILL 本身当成签名错误；
    /// 只有 Security.framework 返回失败，或系统给出明确 codesign 诊断时才归类。
    private static func bundledSignatureFailure(atPath path: String) -> String? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            URL(fileURLWithPath: path) as CFURL,
            SecCSFlags(),
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            return "SecStaticCodeCreateWithPath failed (OSStatus \(createStatus))"
        }

        var validationError: Unmanaged<CFError>?
        let status = SecStaticCodeCheckValidityWithErrors(
            staticCode,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil,
            &validationError
        )
        guard status != errSecSuccess else { return nil }
        let reason = validationError?.takeRetainedValue().localizedDescription
            ?? "OSStatus \(status)"
        return "strict code-signing validation failed: \(reason)"
    }

    private static func logFailure(
        _ error: QuotaServerStartupError,
        candidate: QuotaServerExecutable
    ) {
        launcherLog.error(
            "QuotaServer startup failed from \(candidate.origin.rawValue, privacy: .public) path=\(candidate.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
        if !error.startupStderr.isEmpty {
            // stderr 可能含上游 URL 等运行信息，完整保留但不标记 public。
            launcherLog.error("QuotaServer startup stderr:\n\(error.startupStderr, privacy: .private)")
        }
        if !error.supplementalDiagnostic.isEmpty {
            launcherLog.error("QuotaServer startup diagnostic: \(error.supplementalDiagnostic, privacy: .private)")
        }
    }
}

/// 启动阶段完整积累 stderr；ready 后继续排空管道但不再无限增长内存。
private final class QuotaServerStartupCapture {
    private let executable: QuotaServerExecutable
    private let stdoutLineHandler: (String) -> Void
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private let stderrEOF = DispatchGroup()
    private var stderrData = Data()
    private var stdoutData = Data()
    private var stderrLineData = Data()
    private var isCapturingStartup = true
    private var readersStarted = false

    init(executable: QuotaServerExecutable, stdoutLineHandler: @escaping (String) -> Void) {
        self.executable = executable
        self.stdoutLineHandler = stdoutLineHandler
    }

    var stderrSnapshot: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderrData, as: UTF8.self)
    }

    func attach(to process: Process) {
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
    }

    /// 专属阻塞 reader 持续排空 pipe：不依赖 readabilityHandler 的调度时序，
    /// 进程退出后可用 EOF barrier 保证分类看见最后一块 stderr。
    func startReading() {
        guard !readersStarted else { return }
        readersStarted = true

        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let data = stdoutPipe.fileHandleForReading.availableData
                guard !data.isEmpty else {
                    flushStdoutRemainder()
                    return
                }
                consumeStdout(data)
            }
        }

        stderrEOF.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { stderrEOF.leave() }
            while true {
                let data = stderrPipe.fileHandleForReading.availableData
                guard !data.isEmpty else {
                    flushStderrRemainder()
                    return
                }
                lock.lock()
                let shouldCapture = isCapturingStartup
                if shouldCapture { stderrData.append(data) }
                lock.unlock()

                if !shouldCapture {
                    consumeStderrForLogging(data)
                }
            }
        }
    }

    private func consumeStdout(_ data: Data) {
        stdoutData.append(data)
        while let newline = stdoutData.firstIndex(of: 0x0A) {
            var line = stdoutData[..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            stdoutLineHandler(String(decoding: line, as: UTF8.self))
            stdoutData.removeSubrange(...newline)
        }
    }

    private func flushStdoutRemainder() {
        guard !stdoutData.isEmpty else { return }
        stdoutLineHandler(String(decoding: stdoutData, as: UTF8.self))
        stdoutData.removeAll(keepingCapacity: false)
    }

    private func consumeStderrForLogging(_ data: Data) {
        stderrLineData.append(data)
        while let newline = stderrLineData.firstIndex(of: 0x0A) {
            var line = stderrLineData[..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            logStderrLine(String(decoding: line, as: UTF8.self))
            stderrLineData.removeSubrange(...newline)
        }
    }

    private func flushStderrRemainder() {
        guard !stderrLineData.isEmpty else { return }
        logStderrLine(String(decoding: stderrLineData, as: UTF8.self))
        stderrLineData.removeAll(keepingCapacity: false)
    }

    private func logStderrLine(_ line: String) {
        launcherLog.debug(
            "QuotaServer stderr (\(self.executable.origin.rawValue, privacy: .public)): \(line, privacy: .private)"
        )
    }

    func markReady() -> String {
        lock.lock()
        isCapturingStartup = false
        let result = String(decoding: stderrData, as: UTF8.self)
        lock.unlock()
        return result
    }

    /// 子进程退出后等待 stderr reader 看到 EOF；超时只返回已收集数据，绝不在 MainActor 无界阻塞。
    func finishAfterProcessExit() -> String {
        if readersStarted, stderrEOF.wait(timeout: .now() + 1) == .timedOut {
            launcherLog.error("Timed out waiting for QuotaServer stderr EOF")
        }
        lock.lock()
        isCapturingStartup = false
        let result = String(decoding: stderrData, as: UTF8.self)
        lock.unlock()
        return result
    }
}
