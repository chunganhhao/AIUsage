import Foundation
import Security
import os.log

// MARK: - TLS Certificate Manager
// Uses a local CA root certificate to sign server certificates (same approach as Caddy `tls internal`).
// 1. Generate CA root key + cert (one-time)
// 2. Generate server key + CSR, sign with CA → server cert
// 3. Export server identity as PKCS12 for Network.framework TLS listener
// 4. Install CA root cert to macOS System Keychain (triggers admin password dialog via osascript)
// All files stored at ~/.config/aiusage/tls/

@MainActor
final class TLSCertificateManager {
    static let shared = TLSCertificateManager()

    private let tlsDirectory: URL
    private let caKeyPath: URL
    private let caCertPath: URL
    private let serverKeyPath: URL
    private let serverCertPath: URL
    private let identityPath: URL
    private let passwordPath: URL
    private let versionPath: URL
    private let allowSystemTrustInstall: Bool

    private nonisolated static let currentVersion = "ca-v6"
    private let log = Logger(subsystem: "com.aiusage.desktop", category: "TLS")

    init(tlsDirectory: URL? = nil, allowSystemTrustInstall: Bool = false) {
        let dir = (tlsDirectory
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/aiusage/tls"))
            .standardizedFileURL
        self.tlsDirectory = dir
        self.allowSystemTrustInstall = allowSystemTrustInstall
        caKeyPath = dir.appendingPathComponent("ca-key.pem")
        caCertPath = dir.appendingPathComponent("ca-cert.pem")
        serverKeyPath = dir.appendingPathComponent("server-key.pem")
        serverCertPath = dir.appendingPathComponent("server-cert.pem")
        identityPath = dir.appendingPathComponent("identity.p12")
        passwordPath = dir.appendingPathComponent(".identity-pass")
        versionPath = dir.appendingPathComponent(".version")
    }

    var identityFilePath: String { identityPath.path }
    var certFilePath: String { caCertPath.path }

    private var hasValidCertificate: Bool {
        guard FileManager.default.fileExists(atPath: identityPath.path),
              FileManager.default.fileExists(atPath: passwordPath.path),
              let version = try? String(contentsOf: versionPath, encoding: .utf8),
              version.trimmingCharacters(in: .whitespacesAndNewlines) == Self.currentVersion else {
            return false
        }
        do {
            try Self.validateDirectoryAndSecretPermissions(
                directory: tlsDirectory,
                secretFiles: [caKeyPath, serverKeyPath, identityPath, passwordPath]
            )
            return true
        } catch {
            return false
        }
    }

    nonisolated static func supportsMemoryOnlyTLSIdentityImport(isMacOS15OrLater: Bool? = nil) -> Bool {
        if let isMacOS15OrLater { return isMacOS15OrLater }
        if #available(macOS 15.0, *) { return true }
        return false
    }

    nonisolated static func requireMemoryOnlyTLSRuntimeSupport(isMacOS15OrLater: Bool? = nil) throws {
        guard supportsMemoryOnlyTLSIdentityImport(isMacOS15OrLater: isMacOS15OrLater) else {
            throw TLSCertificateError.generationFailed(
                "Native local HTTPS requires macOS 15.0 or later for memory-only PKCS#12 identity loading without importing keys into the default Keychain."
            )
        }
    }

    func ensureCertificate() async throws {
        try Self.requireMemoryOnlyTLSRuntimeSupport()
        if hasValidCertificate { return }
        log.info("Certificate missing or outdated, regenerating...")
        try await regenerateCertificate()
    }

    func regenerateCertificate() async throws {
        try Self.requireMemoryOnlyTLSRuntimeSupport()
        for path in [caKeyPath, caCertPath, serverKeyPath, serverCertPath, identityPath, passwordPath] {
            try? FileManager.default.removeItem(at: path)
        }
        try await generateCertificateChain()
    }

    // MARK: - Certificate Chain Generation

    private func generateCertificateChain() async throws {
        try Self.rejectSymlinkIfPresent(at: tlsDirectory)
        try FileManager.default.createDirectory(
            at: tlsDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try Self.enforcePermissions(
            directory: tlsDirectory,
            secretFiles: [caKeyPath, serverKeyPath, identityPath, passwordPath],
            createMissingSecrets: true
        )

        let dir = tlsDirectory
        let caKey = caKeyPath
        let caCert = caCertPath
        let serverKey = serverKeyPath
        let serverCert = serverCertPath
        let identity = identityPath
        let passwordFile = passwordPath
        let password = try Self.generateRandomPassphrase()
        try Data(password.utf8).write(to: passwordFile, options: .atomic)
        try Self.enforcePermissions(
            directory: dir,
            secretFiles: [caKey, serverKey, identity, passwordFile],
            createMissingSecrets: false
        )

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.generateCACert(dir: dir, keyPath: caKey, certPath: caCert)
                    try Self.generateServerCert(dir: dir, caKey: caKey, caCert: caCert,
                                                serverKey: serverKey, serverCert: serverCert)
                    try Self.exportPKCS12(identity: identity, serverKey: serverKey,
                                         serverCert: serverCert, caCert: caCert, password: password)
                    try Self.enforcePermissions(
                        directory: dir,
                        secretFiles: [caKey, serverKey, identity, passwordFile],
                        createMissingSecrets: false
                    )
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        try Self.rejectSymlinkIfPresent(at: versionPath)
        try Self.currentVersion.write(to: versionPath, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: versionPath.path)

        await installCATrust()

        log.info("Certificate chain generated at \(self.tlsDirectory.path, privacy: .public)")
    }

    nonisolated static func rejectSymlinkIfPresent(at url: URL) throws {
        var st = stat()
        if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK {
            throw TLSCertificateError.generationFailed("Refusing symlink at TLS path: \(url.lastPathComponent)")
        }
    }

    nonisolated static func enforcePermissions(
        directory: URL,
        secretFiles: [URL],
        createMissingSecrets: Bool
    ) throws {
        try rejectSymlinkIfPresent(at: directory)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        for file in secretFiles {
            try rejectSymlinkIfPresent(at: file)
            if createMissingSecrets && !FileManager.default.fileExists(atPath: file.path) {
                FileManager.default.createFile(
                    atPath: file.path,
                    contents: Data(),
                    attributes: [.posixPermissions: 0o600]
                )
            }
            if FileManager.default.fileExists(atPath: file.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
    }

    nonisolated static func validateDirectoryAndSecretPermissions(
        directory: URL,
        secretFiles: [URL]
    ) throws {
        try rejectSymlinkIfPresent(at: directory)
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: directory.path)
        let dirMode = (dirAttrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        guard (dirMode & 0o077) == 0 else {
            throw TLSCertificateError.generationFailed("Insecure permissions on TLS directory")
        }
        for file in secretFiles {
            try rejectSymlinkIfPresent(at: file)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
            guard (mode & 0o077) == 0 else {
                throw TLSCertificateError.generationFailed("Insecure permissions on TLS secret: \(file.lastPathComponent)")
            }
        }
    }

    private nonisolated static func generateRandomPassphrase() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw TLSCertificateError.generationFailed("SecRandomCopyBytes failed with status \(status)")
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: Step 1 - CA Root Certificate

    private nonisolated static func generateCACert(dir: URL, keyPath: URL, certPath: URL) throws {
        let configPath = dir.appendingPathComponent("ca.cnf")
        try """
        [req]
        distinguished_name = dn
        x509_extensions = v3_ca
        prompt = no
        [dn]
        CN = AIUsage Local CA
        [v3_ca]
        basicConstraints = critical,CA:TRUE,pathlen:0
        keyUsage = critical,keyCertSign,cRLSign
        subjectKeyIdentifier = hash
        """.write(to: configPath, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: configPath) }

        try runOpenSSL([
            "req", "-x509", "-newkey", "rsa:2048", "-nodes",
            "-keyout", keyPath.path,
            "-out", certPath.path,
            "-days", "3650",
            "-config", configPath.path,
        ], errorContext: "generate CA certificate")
    }

    // MARK: Step 2 - Server Certificate signed by CA

    private nonisolated static func generateServerCert(dir: URL, caKey: URL, caCert: URL,
                                                       serverKey: URL, serverCert: URL) throws {
        let csrPath = dir.appendingPathComponent("server.csr")
        let serverConfig = dir.appendingPathComponent("server.cnf")
        let extConfig = dir.appendingPathComponent("server-ext.cnf")

        try """
        [req]
        distinguished_name = dn
        prompt = no
        [dn]
        CN = AIUsage Local Proxy
        """.write(to: serverConfig, atomically: true, encoding: .utf8)

        try """
        subjectAltName = DNS:localhost,IP:127.0.0.1
        basicConstraints = CA:FALSE
        keyUsage = digitalSignature, keyEncipherment
        extendedKeyUsage = serverAuth
        """.write(to: extConfig, atomically: true, encoding: .utf8)

        defer {
            for tmp in [csrPath, serverConfig, extConfig,
                        dir.appendingPathComponent("ca-cert.srl")] {
                try? FileManager.default.removeItem(at: tmp)
            }
        }

        try runOpenSSL([
            "req", "-newkey", "rsa:2048", "-nodes",
            "-keyout", serverKey.path,
            "-out", csrPath.path,
            "-config", serverConfig.path,
        ], errorContext: "generate server CSR")

        try runOpenSSL([
            "x509", "-req",
            "-in", csrPath.path,
            "-CA", caCert.path,
            "-CAkey", caKey.path,
            "-CAcreateserial",
            "-out", serverCert.path,
            "-days", "825",
            "-extfile", extConfig.path,
        ], errorContext: "sign server certificate with CA")
    }

    // MARK: Step 3 - PKCS12 Identity (server key + cert chain)

    private nonisolated static func exportPKCS12(identity: URL, serverKey: URL,
                                                 serverCert: URL, caCert: URL, password: String) throws {
        try runOpenSSL([
            "pkcs12", "-export",
            "-out", identity.path,
            "-inkey", serverKey.path,
            "-in", serverCert.path,
            "-certfile", caCert.path,
            "-passout", "stdin",
        ], standardInputData: Data((password + "\n").utf8), errorContext: "export PKCS12 identity")
    }

    // MARK: Step 4 - Install CA to System Trust
    // Disabled by default (`allowSystemTrustInstall == false`) until explicitly enabled.

    nonisolated static func makeAdminTrustOsascriptArguments(certURL: URL, expectedDirectory: URL) throws -> [String] {
        let resolvedCert = certURL.standardizedFileURL
        let resolvedDir = expectedDirectory.standardizedFileURL
        try rejectSymlinkIfPresent(at: resolvedDir)
        try rejectSymlinkIfPresent(at: resolvedCert)
        guard resolvedCert.deletingLastPathComponent() == resolvedDir else {
            throw TLSCertificateError.generationFailed("CA certificate path outside TLS directory")
        }
        let path = resolvedCert.path
        guard !path.isEmpty,
              !path.contains("\0"),
              !path.contains("\n"),
              !path.contains("\r"),
              FileManager.default.fileExists(atPath: path) else {
            throw TLSCertificateError.generationFailed("Invalid CA certificate path for trust installation")
        }
        return [
            "-e", "on run argv",
            "-e", "set certPath to item 1 of argv",
            "-e", #"do shell script "/usr/bin/security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain " & quoted form of certPath with administrator privileges"#,
            "-e", "end run",
            "--",
            path,
        ]
    }

    private func installCATrust() async {
        guard allowSystemTrustInstall else {
            log.info("System Keychain CA trust installation skipped (allowSystemTrustInstall=false)")
            return
        }
        let args: [String]
        do {
            args = try Self.makeAdminTrustOsascriptArguments(certURL: caCertPath, expectedDirectory: tlsDirectory)
        } catch {
            log.error("Refusing CA trust installation: \(String(describing: error), privacy: .public)")
            return
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = args
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    continuation.resume(returning: -1)
                    return
                }

                continuation.resume(returning: process.terminationStatus)
            }
        }

        if result == 0 {
            log.info("CA root trusted in System Keychain via admin dialog")
        } else {
            log.warning("Admin trust via osascript returned \(result), falling back to user domain")
            installUserDomainTrust()
        }
    }

    private func installUserDomainTrust() {
        guard let pemData = try? Data(contentsOf: caCertPath),
              let pemString = String(data: pemData, encoding: .utf8) else {
            log.error("Cannot read CA certificate for user trust fallback")
            return
        }

        let base64 = pemString
            .components(separatedBy: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()

        guard let derData = Data(base64Encoded: base64),
              let certificate = SecCertificateCreateWithData(nil, derData as CFData) else {
            log.error("Cannot parse CA certificate DER data")
            return
        }

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: "AIUsage Local CA",
        ]
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess && addStatus != errSecDuplicateItem {
            log.warning("Failed to add CA cert to login keychain (status: \(addStatus))")
        }

        let status = SecTrustSettingsSetTrustSettings(certificate, .user, nil)
        if status == errSecSuccess {
            log.info("CA root trusted in user domain")
        } else {
            log.error("User domain trust failed (status: \(status))")
        }
    }

    // MARK: - Process Helpers

    private nonisolated static func runOpenSSL(
        _ arguments: [String],
        standardInputData: Data? = nil,
        errorContext: String
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice

        let inPipe: Pipe?
        if standardInputData != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inPipe = pipe
        } else {
            inPipe = nil
        }

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
        if let standardInputData, let inPipe {
            inPipe.fileHandleForWriting.write(standardInputData)
            try? inPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw TLSCertificateError.generationFailed(
                "\(errorContext): exit code \(process.terminationStatus) — \(stderr)"
            )
        }
    }
}

// MARK: - Error

enum TLSCertificateError: LocalizedError {
    case generationFailed(String)

    var errorDescription: String? {
        switch self {
        case .generationFailed(let reason):
            return "TLS certificate generation failed: \(reason)"
        }
    }
}
