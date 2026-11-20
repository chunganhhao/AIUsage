import CryptoKit
import Darwin
import Foundation

nonisolated protocol CLIProxyBinaryExtracting: Sendable {
    func extractBinary(from archiveURL: URL, assetName: String, to destinationURL: URL) throws
}

nonisolated protocol CLIProxyBinarySigning: Sendable {
    func sign(binaryAt url: URL) throws
}

nonisolated protocol CLIProxyBinaryValidating: Sendable {
    func validate(binaryAt url: URL, architecture: CLIProxyArchitecture) async throws
}

nonisolated struct CLIProxySecureArchiveExtractor: CLIProxyBinaryExtracting {
    func extractBinary(from archiveURL: URL, assetName: String, to destinationURL: URL) throws {
        let lowercasedName = assetName.lowercased()
        if lowercasedName.hasSuffix(".tar.gz") || lowercasedName.hasSuffix(".tgz") {
            try extractFromTarGzip(archiveURL, to: destinationURL)
            return
        }
        guard lowercasedName == "cliproxyapi" else {
            throw CLIProxyGatewayError.unsafeArchive("unsupported asset format")
        }
        try FileManager.default.copyItem(at: archiveURL, to: destinationURL)
    }

    private func extractFromTarGzip(_ archiveURL: URL, to destinationURL: URL) throws {
        let listing = try CLIProxyCommand.capture(
            executable: "/usr/bin/tar",
            arguments: ["-tzf", archiveURL.path]
        )
        guard listing.status == 0 else {
            throw CLIProxyGatewayError.extractionFailed(listing.output)
        }

        let entries = listing.output
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !entries.isEmpty else {
            throw CLIProxyGatewayError.unsafeArchive("archive is empty")
        }
        for entry in entries {
            try validateArchiveEntry(entry)
        }

        let allowedBinaryNames = Set(["cliproxyapi", "cli-proxy-api"])
        let candidates = entries.filter { entry in
            !entry.hasSuffix("/")
                && allowedBinaryNames.contains(URL(fileURLWithPath: entry).lastPathComponent.lowercased())
        }
        guard candidates.count == 1, let binaryEntry = candidates.first else {
            throw CLIProxyGatewayError.unsafeArchive("expected exactly one recognized CLIProxyAPI binary")
        }

        let verbose = try CLIProxyCommand.capture(
            executable: "/usr/bin/tar",
            arguments: ["-tvzf", archiveURL.path, binaryEntry]
        )
        guard verbose.status == 0 else {
            throw CLIProxyGatewayError.extractionFailed(verbose.output)
        }
        guard verbose.output.trimmingCharacters(in: .whitespacesAndNewlines).first == "-" else {
            throw CLIProxyGatewayError.unsafeArchive("CLIProxyAPI entry is not a regular file")
        }

        FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: destinationURL)
        defer { try? outputHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xOzf", archiveURL.path, binaryEntry]
        process.standardOutput = outputHandle
        let errorPipe = Pipe()
        process.standardError = errorPipe
        do {
            try process.run()
        } catch {
            throw CLIProxyGatewayError.extractionFailed(error.localizedDescription)
        }
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: errorData, encoding: .utf8) ?? "tar extraction failed"
            throw CLIProxyGatewayError.extractionFailed(message)
        }
    }

    private func validateArchiveEntry(_ entry: String) throws {
        guard !entry.hasPrefix("/"), !entry.contains("\0") else {
            throw CLIProxyGatewayError.unsafeArchive("absolute or invalid path")
        }
        let components = entry.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." }) else {
            throw CLIProxyGatewayError.unsafeArchive("path traversal entry")
        }
    }
}

nonisolated struct CLIProxyAdHocSigner: CLIProxyBinarySigning {
    func sign(binaryAt url: URL) throws {
        let result = try CLIProxyCommand.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--force", "--sign", "-", "--timestamp=none", url.path]
        )
        guard result.status == 0 else {
            throw CLIProxyGatewayError.signingFailed(result.output)
        }
    }
}

nonisolated struct CLIProxyDefaultBinaryValidator: CLIProxyBinaryValidating {
    func validate(binaryAt url: URL, architecture: CLIProxyArchitecture) async throws {
        let architectureResult = try CLIProxyCommand.capture(
            executable: "/usr/bin/lipo",
            arguments: ["-archs", url.path]
        )
        guard architectureResult.status == 0,
              architectureResult.output
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
                .contains(architecture.lipoToken) else {
            throw CLIProxyGatewayError.incompatibleBinary(
                "expected \(architecture.lipoToken), got \(architectureResult.output)"
            )
        }

        let signatureResult = try CLIProxyCommand.capture(
            executable: "/usr/bin/codesign",
            arguments: ["--verify", "--strict", url.path]
        )
        guard signatureResult.status == 0 else {
            throw CLIProxyGatewayError.signingFailed(signatureResult.output)
        }

        try await dryRun(binaryAt: url)
    }

    private func dryRun(binaryAt binaryURL: URL) async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("AIUsage-CLIProxy-DryRun-\(UUID().uuidString)", isDirectory: true)
        let authDirectory = directory.appendingPathComponent("auth", isDirectory: true)
        let configURL = directory.appendingPathComponent("config.yaml", isDirectory: false)
        let port = try CLIProxyPortReservation.availableLoopbackPort()

        do {
            try fileManager.createDirectory(at: authDirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: authDirectory.path)
            let config = """
            host: "127.0.0.1"
            port: \(port)
            auth-dir: \(yamlQuoted(authDirectory.path))
            api-keys:
              - "aiusage-dry-run"
            remote-management:
              allow-remote: false
              secret-key: ""
              disable-control-panel: true
            plugins:
              enabled: false
            debug: false
            logging-to-file: false
            usage-statistics-enabled: false
            """
            try config.write(to: configURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CLIProxyGatewayError.dryRunFailed(error.localizedDescription)
        }

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = ["-config", configURL.path]
        process.currentDirectoryURL = binaryURL.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            try? fileManager.removeItem(at: directory)
            throw CLIProxyGatewayError.dryRunFailed(error.localizedDescription)
        }

        defer {
            terminate(process)
            try? fileManager.removeItem(at: directory)
        }

        let endpoint = URL(string: "http://127.0.0.1:\(port)/healthz")!
        let deadline = Date().addingTimeInterval(10)
        var lastError = "health endpoint did not become ready"
        while Date() < deadline, process.isRunning {
            var request = URLRequest(url: endpoint, timeoutInterval: 0.7)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    return
                }
            } catch {
                lastError = error.localizedDescription
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        if !process.isRunning {
            lastError = "process exited with status \(process.terminationStatus)"
        }
        throw CLIProxyGatewayError.dryRunFailed(lastError)
    }

    private func yamlQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private func terminate(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(2)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

actor CLIProxyBinaryStore {
    private let paths: CLIProxyPaths
    private let fileManager: FileManager
    private let extractor: any CLIProxyBinaryExtracting
    private let signer: any CLIProxyBinarySigning
    private let validator: any CLIProxyBinaryValidating

    init(
        paths: CLIProxyPaths,
        fileManager: FileManager = .default,
        extractor: any CLIProxyBinaryExtracting = CLIProxySecureArchiveExtractor(),
        signer: any CLIProxyBinarySigning = CLIProxyAdHocSigner(),
        validator: any CLIProxyBinaryValidating = CLIProxyDefaultBinaryValidator()
    ) {
        self.paths = paths
        self.fileManager = fileManager
        self.extractor = extractor
        self.signer = signer
        self.validator = validator
    }

    private func parseActiveSelection() throws -> (version: String, commitID: String?)? {
        let destination: String
        do {
            destination = try fileManager.destinationOfSymbolicLink(atPath: paths.currentSymlink.path)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return nil
        } catch {
            if !fileManager.fileExists(atPath: paths.currentSymlink.path) { return nil }
            throw CLIProxyGatewayError.fileSystem(error.localizedDescription)
        }
        let name = URL(fileURLWithPath: destination).lastPathComponent
        if name.hasPrefix(".commit-"), let separator = name.range(of: "-v", options: .backwards) {
            let commitStart = name.index(name.startIndex, offsetBy: ".commit-".count)
            let commitID = String(name[commitStart..<separator.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let version = String(name[separator.upperBound...])
            guard !commitID.isEmpty, CLIProxyVersion.isSafePathComponent(version) else { return nil }
            return (version, commitID)
        }
        guard name.hasPrefix("v") else { return nil }
        let version = String(name.dropFirst())
        guard CLIProxyVersion.isSafePathComponent(version) else { return nil }
        var st = stat()
        var legacyCommitID: String?
        if lstat(activeCommitIDURL.path, &st) == 0,
           (st.st_mode & S_IFMT) == S_IFREG,
           let raw = try? String(contentsOf: activeCommitIDURL, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { legacyCommitID = trimmed }
        }
        return (version, legacyCommitID)
    }

    func currentVersion() throws -> String? {
        try paths.prepare(fileManager: fileManager)
        return try parseActiveSelection()?.version
    }

    func currentBinaryURL() throws -> URL? {
        guard try currentVersion() != nil else { return nil }
        let binaryURL = paths.currentSymlink.appendingPathComponent(paths.binaryName)
        return fileManager.fileExists(atPath: binaryURL.path) ? binaryURL : nil
    }

    func installedVersions() throws -> [CLIProxyInstalledVersion] {
        try paths.prepare(fileManager: fileManager)
        let current = try currentVersion()
        let contents = try fileManager.contentsOfDirectory(
            at: paths.versionsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return contents.compactMap { directory in
            let name = directory.lastPathComponent
            guard name.hasPrefix("v") else { return nil }
            let version = String(name.dropFirst())
            guard CLIProxyVersion.isSafePathComponent(version) else { return nil }
            let binaryURL = directory.appendingPathComponent(paths.binaryName)
            guard fileManager.fileExists(atPath: binaryURL.path) else { return nil }
            let values = try? directory.resourceValues(forKeys: [.creationDateKey])
            return CLIProxyInstalledVersion(
                version: version,
                binaryURL: binaryURL,
                installedAt: values?.creationDate ?? .distantPast,
                isCurrent: version == current
            )
        }
        .sorted { lhs, rhs in
            let comparison = CLIProxyVersion.compare(lhs.version, rhs.version)
            if comparison == .orderedSame { return lhs.installedAt > rhs.installedAt }
            return comparison == .orderedDescending
        }
    }

    func install(
        downloadedAssetURL: URL,
        release: CLIProxyRelease,
        architecture: CLIProxyArchitecture = .current
    ) async throws -> CLIProxyInstalledVersion {
        try paths.prepare(fileManager: fileManager)
        let archiveData = try Data(contentsOf: downloadedAssetURL, options: [.mappedIfSafe])
        let actualDigest = SHA256.hash(data: archiveData).map { String(format: "%02x", $0) }.joined()
        guard actualDigest == release.sha256.lowercased() else {
            throw CLIProxyGatewayError.checksumMismatch(expected: release.sha256, actual: actualDigest)
        }

        let finalDirectory = try paths.versionDirectory(release.version)
        let finalBinary = finalDirectory.appendingPathComponent(paths.binaryName)
        if fileManager.fileExists(atPath: finalBinary.path) {
            let current = try currentVersion()
            return CLIProxyInstalledVersion(
                version: release.version,
                binaryURL: finalBinary,
                installedAt: (try? finalDirectory.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast,
                isCurrent: current == release.version
            )
        }
        if fileManager.fileExists(atPath: finalDirectory.path) {
            try fileManager.removeItem(at: finalDirectory)
        }

        let stagingDirectory = paths.versionsDirectory
            .appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let stagingBinary = stagingDirectory.appendingPathComponent(paths.binaryName)
        do {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false)
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stagingDirectory.path)
            try extractor.extractBinary(
                from: downloadedAssetURL,
                assetName: release.assetName,
                to: stagingBinary
            )
            let resourceValues = try stagingBinary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard resourceValues.isRegularFile == true,
                  resourceValues.isSymbolicLink != true,
                  (resourceValues.fileSize ?? 0) > 0 else {
                throw CLIProxyGatewayError.incompatibleBinary("extracted payload is not a regular non-empty file")
            }
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stagingBinary.path)
            try signer.sign(binaryAt: stagingBinary)
            try await validator.validate(binaryAt: stagingBinary, architecture: architecture)
            try fileManager.moveItem(at: stagingDirectory, to: finalDirectory)
        } catch {
            try? fileManager.removeItem(at: stagingDirectory)
            throw error
        }

        return CLIProxyInstalledVersion(
            version: release.version,
            binaryURL: finalBinary,
            installedAt: Date(),
            isCurrent: false
        )
    }

    private var activeCommitIDURL: URL {
        paths.root.appendingPathComponent(".active-commit-id")
    }

    func currentCommitID() -> String? {
        (try? parseActiveSelection())?.commitID
    }

    private struct SharedRuntimePIDRecord: Codable {
        let pid: Int32
        let binaryPath: String
        let configPath: String
        let configSHA256: String?
        let port: Int?
        let bindHost: String?
    }

    private struct SharedUnconfirmedEndpoint: Codable {
        let pid: Int32?
        let port: Int
        let bindHost: String
    }

    private func withRuntimeFenceLock<T>(_ body: () throws -> T) throws -> T {
        try paths.prepare(fileManager: fileManager)
        let lockURL = paths.root.appendingPathComponent("runtime.fence.lock")
        let lockPath = lockURL.path
        var st = stat()
        if lstat(lockPath, &st) == 0, (st.st_mode & S_IFMT) != S_IFREG {
            throw CLIProxyGatewayError.process(
                "Containment unconfirmed: shared CPA fence lock path is not a regular file (\(lockPath))."
            )
        }
        var fd: Int32 = -1
        while true {
            fd = Darwin.open(lockPath, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_EXLOCK, S_IRUSR | S_IWUSR)
            if fd >= 0 { break }
            if errno == EINTR { continue }
            throw CLIProxyGatewayError.process(
                "Containment unconfirmed: failed to open and lock shared CPA fence (\(String(cString: strerror(errno))))."
            )
        }
        defer { Darwin.close(fd) }
        _ = Darwin.fchmod(fd, S_IRUSR | S_IWUSR)

        let unconfirmedURL = paths.root.appendingPathComponent("runtime.unconfirmed.json")
        if fileManager.fileExists(atPath: unconfirmedURL.path) {
            guard let data = fileManager.contents(atPath: unconfirmedURL.path),
                  let decoded = try? JSONDecoder().decode(SharedUnconfirmedEndpoint.self, from: data),
                  (1...65_535).contains(decoded.port),
                  !decoded.bindHost.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw CLIProxyGatewayError.process(
                    "Containment unconfirmed: unresolved CPA stop marker at \(unconfirmedURL.path) is unreadable and the original listener endpoint is unknown. Stop any running CPA process and remove the corrupt marker only after verifying no old CPA listener remains active."
                )
            }
            if let pid = decoded.pid, pid > 1 {
                throw CLIProxyGatewayError.process(
                    "Containment unconfirmed: previous CPA listener pid=\(pid) on port \(decoded.port) must be stopped and verified before continuing."
                )
            }
            throw CLIProxyGatewayError.process(
                "Containment unconfirmed: original CPA listener port \(decoded.port) remains occupied and must be released before continuing."
            )
        }

        let pidURL = paths.root.appendingPathComponent("runtime.pid.json")
        if let pidData = fileManager.contents(atPath: pidURL.path),
           let record = try? JSONDecoder().decode(SharedRuntimePIDRecord.self, from: pidData),
           record.configPath == paths.configURL.path,
           record.pid > 1,
           (Darwin.kill(record.pid, 0) == 0 || errno == EPERM) {
            let portSuffix = record.port.map { " on port \($0)" } ?? ""
            throw CLIProxyGatewayError.process(
                "Containment unconfirmed: live sibling AIUsage instance owns CPA listener pid=\(record.pid)\(portSuffix); stop it before changing or replacing the shared runtime."
            )
        }

        return try body()
    }

    @discardableResult
    func activateTracked(
        version: String,
        expectedCurrentVersion: String? = nil,
        expectedCommitID: String? = nil,
        publicationFault: (() throws -> Void)? = nil
    ) throws -> (previous: String?, commitID: String) {
        try withRuntimeFenceLock {
            let previousSelection = try parseActiveSelection()
            let previous = previousSelection?.version
            if let expectedCurrentVersion {
                let normalizedExpected = CLIProxyVersion.normalized(expectedCurrentVersion)
                guard previous == normalizedExpected else {
                    throw CLIProxyGatewayError.process(
                        "Containment unconfirmed: active CPA version changed from \(normalizedExpected) to \(previous ?? "none") before version commit."
                    )
                }
            }
            if let expectedCommitID {
                let actualCommitID = previousSelection?.commitID
                guard actualCommitID == expectedCommitID else {
                    throw CLIProxyGatewayError.process(
                        "Containment unconfirmed: active CPA activation commit changed before rollback (expected \(expectedCommitID), found \(actualCommitID ?? "none"))."
                    )
                }
            }
            let normalizedTarget = CLIProxyVersion.normalized(version)
            let versionDirectory = try paths.versionDirectory(version)
            let binaryURL = versionDirectory.appendingPathComponent(paths.binaryName)
            guard fileManager.fileExists(atPath: binaryURL.path) else {
                throw CLIProxyGatewayError.versionNotInstalled(version)
            }

            var legacyCommitStat = stat()
            if lstat(activeCommitIDURL.path, &legacyCommitStat) == 0,
               (legacyCommitStat.st_mode & S_IFMT) != S_IFREG {
                throw CLIProxyGatewayError.fileSystem(
                    "Refusing CPA version activation: legacy .active-commit-id path is not a regular file"
                )
            }

            let commitID = UUID().uuidString.lowercased()
            let commitLinkName = ".commit-\(commitID)-v\(normalizedTarget)"
            let commitLinkURL = paths.versionsDirectory.appendingPathComponent(commitLinkName, isDirectory: false)
            let temporaryLink = paths.root.appendingPathComponent(".current-\(UUID().uuidString)")
            var didPublish = false
            defer {
                try? fileManager.removeItem(at: temporaryLink)
                if !didPublish {
                    try? fileManager.removeItem(at: commitLinkURL)
                }
            }
            if fileManager.fileExists(atPath: commitLinkURL.path) {
                try? fileManager.removeItem(at: commitLinkURL)
            }
            try fileManager.createSymbolicLink(
                atPath: commitLinkURL.path,
                withDestinationPath: "v\(normalizedTarget)"
            )
            try fileManager.createSymbolicLink(
                atPath: temporaryLink.path,
                withDestinationPath: "versions/\(commitLinkName)"
            )
            if let publicationFault {
                try publicationFault()
            }
            guard Darwin.rename(temporaryLink.path, paths.currentSymlink.path) == 0 else {
                throw CLIProxyGatewayError.fileSystem(String(cString: strerror(errno)))
            }
            didPublish = true
            try? fileManager.removeItem(at: activeCommitIDURL)
            if let entries = try? fileManager.contentsOfDirectory(
                at: paths.versionsDirectory,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                for entry in entries where entry.lastPathComponent.hasPrefix(".commit-") && entry.lastPathComponent != commitLinkName {
                    try? fileManager.removeItem(at: entry)
                }
            }
            return (previous, commitID)
        }
    }

    @discardableResult
    func activate(
        version: String,
        expectedCurrentVersion: String? = nil,
        expectedCommitID: String? = nil
    ) throws -> String? {
        try activateTracked(
            version: version,
            expectedCurrentVersion: expectedCurrentVersion,
            expectedCommitID: expectedCommitID
        ).previous
    }

    func delete(version: String) throws {
        try withRuntimeFenceLock {
            let normalized = CLIProxyVersion.normalized(version)
            if try currentVersion() == normalized {
                throw CLIProxyGatewayError.cannotDeleteCurrentVersion
            }
            let directory = try paths.versionDirectory(version)
            if fileManager.fileExists(atPath: directory.path) {
                try fileManager.removeItem(at: directory)
            }
        }
    }

    func cleanup(keeping limit: Int = 3) throws {
        let keepCount = max(limit, 2)
        let versions = try installedVersions()
        let removable = versions.filter { !$0.isCurrent }.dropFirst(max(keepCount - 1, 1))
        for version in removable {
            try? delete(version: version.version)
        }
    }
}

nonisolated private enum CLIProxyCommand {
    struct Result {
        let status: Int32
        let output: String
    }

    static func capture(executable: String, arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            throw CLIProxyGatewayError.fileSystem(error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
    }
}

nonisolated private enum CLIProxyPortReservation {
    static func availableLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw CLIProxyGatewayError.dryRunFailed("could not create port reservation socket")
        }
        defer { Darwin.close(descriptor) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            throw CLIProxyGatewayError.dryRunFailed("could not reserve a loopback port")
        }

        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }
        guard nameResult == 0 else {
            throw CLIProxyGatewayError.dryRunFailed("could not resolve the dry-run port")
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
