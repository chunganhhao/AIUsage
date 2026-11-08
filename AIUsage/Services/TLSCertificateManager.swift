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
    private let versionPath: URL

    private nonisolated static let identityPassword = "aiusage-proxy-tls"
    private nonisolated static let currentVersion = "ca-v5"
    private let log = Logger(subsystem: "com.aiusage.desktop", category: "TLS")

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appendingPathComponent(".config/aiusage/tls")
        tlsDirectory = dir
        caKeyPath = dir.appendingPathComponent("ca-key.pem")
        caCertPath = dir.appendingPathComponent("ca-cert.pem")
        serverKeyPath = dir.appendingPathComponent("server-key.pem")
        serverCertPath = dir.appendingPathComponent("server-cert.pem")
        identityPath = dir.appendingPathComponent("identity.p12")
        versionPath = dir.appendingPathComponent(".version")
    }

    var identityFilePath: String { identityPath.path }
    var certFilePath: String { caCertPath.path }

    private var hasValidCertificate: Bool {
        guard FileManager.default.fileExists(atPath: identityPath.path) else { return false }
        guard let version = try? String(contentsOf: versionPath, encoding: .utf8) else { return false }
        return version.trimmingCharacters(in: .whitespacesAndNewlines) == Self.currentVersion
    }

    func ensureCertificate() async throws {
        if hasValidCertificate { return }
        log.info("Certificate missing or outdated, regenerating...")
        try await regenerateCertificate()
    }

    func regenerateCertificate() async throws {
        for path in [caKeyPath, caCertPath, serverKeyPath, serverCertPath, identityPath] {
            try? FileManager.default.removeItem(at: path)
        }
        try await generateCertificateChain()
    }

    // MARK: - Certificate Chain Generation

    private func generateCertificateChain() async throws {
        try FileManager.default.createDirectory(
            at: tlsDirectory, withIntermediateDirectories: true
        )

        let dir = tlsDirectory
        let caKey = caKeyPath
        let caCert = caCertPath
        let serverKey = serverKeyPath
        let serverCert = serverCertPath
        let identity = identityPath
        let password = Self.identityPassword

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.generateCACert(dir: dir, keyPath: caKey, certPath: caCert)
                    try Self.generateServerCert(dir: dir, caKey: caKey, caCert: caCert,
                                                serverKey: serverKey, serverCert: serverCert)
                    try Self.exportPKCS12(identity: identity, serverKey: serverKey,
                                         serverCert: serverCert, caCert: caCert, password: password)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        try Self.currentVersion.write(to: versionPath, atomically: true, encoding: .utf8)

        await installCATrust()

        log.info("Certificate chain generated at \(self.tlsDirectory.path, privacy: .public)")
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
            "-passout", "pass:\(password)",
        ], errorContext: "export PKCS12 identity")
    }

    // MARK: Step 4 - Install CA to System Trust
    // Runs `security add-trusted-cert` via osascript on a background thread.
    // The `do shell script ... with administrator privileges` mechanism triggers
    // macOS's standard password dialog (same as Caddy `caddy trust`).

    private func installCATrust() async {
        let certPath = caCertPath.path

        guard FileManager.default.fileExists(atPath: certPath) else {
            log.error("CA certificate file not found at \(certPath, privacy: .public)")
            return
        }

        let result = await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = [
                    "-e",
                    #"do shell script "security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain '"# + certPath + #"'" with administrator privileges"#,
                ]
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

    private nonisolated static func runOpenSSL(_ arguments: [String], errorContext: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        process.standardError = errPipe

        try process.run()
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
