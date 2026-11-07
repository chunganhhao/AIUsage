import Foundation
import SQLite3
#if canImport(AppKit)
import AppKit
#endif
#if canImport(QuotaBackend)
import QuotaBackend
#endif

// MARK: - Antigravity Account Switcher
// Manages local Antigravity IDE / Hub account switching without browser re-login:
//   1. Backs up per-account SQLite state rows before switching (~/.config/aiusage/antigravity-switch/snapshots/).
//   2. Updates ~/Library/Application Support/Antigravity/User/globalStorage/state.vscdb (and .backup if present):
//      - antigravityAuthStatus (email, name, apiKey, userStatusProtoBinaryBase64 Field 3 & Field 7)
//      - jetskiStateSync.agentManagerInitState (Field 6 OAuthTokenInfo, preserving Field 19+ preferences)
//      - antigravityUnifiedStateSync.oauthToken & antigravityUnifiedStateSync.userStatus
//      - antigravityOnboarding = "true"
//   3. Updates ~/.gemini/jetski-standalone-oauth-token and ~/.gemini/antigravity-cli/antigravity-oauth-token when present.

enum AntigravitySwitchError: LocalizedError, Equatable {
    case authFileNotFound(String)
    case invalidAuthFile(String)
    case missingAccessToken
    case missingRefreshToken
    case databaseNotFound(String)
    case databaseOpenFailed(String)
    case databaseWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .authFileNotFound(let path):
            return "Antigravity auth file not found at \(path)."
        case .invalidAuthFile(let reason):
            return "Invalid Antigravity auth file: \(reason)"
        case .missingAccessToken:
            return "Antigravity credential is missing an access token."
        case .missingRefreshToken:
            return "Antigravity credential has no refresh token and none could be recovered for this account."
        case .databaseNotFound(let path):
            return "Antigravity database not found at \(path). Launch Antigravity at least once first."
        case .databaseOpenFailed(let reason):
            return "Could not open Antigravity state database: \(reason)"
        case .databaseWriteFailed(let reason):
            return "Could not write Antigravity state database: \(reason)"
        }
    }
}

struct AntigravityIDECandidatePayload: Equatable {
    let email: String?
    let name: String?
    let accessToken: String
    let refreshToken: String?
    let databasePath: String
}

struct AntigravitySwitchedIdentity: Equatable {
    let email: String
    let name: String
    let sourceFilePath: String
}

struct AntigravityDetectedAccount: Equatable {
    let email: String?
    let name: String?
    let hasAccessToken: Bool
    let hasRefreshToken: Bool
}

struct AntigravityEnvironmentSummary: Equatable {
    let isAppInstalled: Bool
    let isAppRunning: Bool
    let appVersion: String?
    let mcpServerCount: Int
    let skillCount: Int
    let brainSessionCount: Int
    let geminiRulesPath: String
    let mcpConfigPath: String
    let activeAccountEmail: String?
    let activeStoragePath: String

    static let empty = AntigravityEnvironmentSummary(
        isAppInstalled: false,
        isAppRunning: false,
        appVersion: nil,
        mcpServerCount: 0,
        skillCount: 0,
        brainSessionCount: 0,
        geminiRulesPath: "",
        mcpConfigPath: "",
        activeAccountEmail: nil,
        activeStoragePath: "Keychain (gemini/antigravity)"
    )
}

enum AntigravityAccountSwitcher {
    static let bundleIdentifier = "com.google.antigravity"
    static let keyringService = "gemini"
    static let keyringAccount = "antigravity"
    static let keyringBase64Prefix = "go-keyring-base64:"
    static let keyringHexPrefix = "go-keyring-encoded:"

    private static let stateKeysToSnapshot = [
        "antigravityAuthStatus",
        "jetskiStateSync.agentManagerInitState",
        "antigravityUnifiedStateSync.oauthToken",
        "antigravityUnifiedStateSync.userStatus"
    ]
    private static let snapshotStoredTokenRefreshKey = "storedTokenRefreshToken"

    private static let keyringCacheLock = NSLock()
    private static var cachedLiveKeyringEntry: (secret: String, modifiedAt: Date?)?
    private static var cachedLiveKeyringTimestamp: Date = .distantPast

    // MARK: - Paths

    static func candidateDBPaths(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> [String] {
        [
            "\(homeDirectory)/Library/Application Support/Antigravity/User/globalStorage/state.vscdb",
            "\(homeDirectory)/Library/Application Support/Antigravity IDE/User/globalStorage/state.vscdb",
            "\(homeDirectory)/Library/Application Support/Antigravity/state.vscdb"
        ]
    }

    static func primaryDBPath(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        let candidates = candidateDBPaths(homeDirectory: homeDirectory)
        return candidates.first { FileManager.default.fileExists(atPath: $0) } ?? candidates[0]
    }

    static func appStoragePath(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        "\(homeDirectory)/Library/Application Support/Antigravity/app_storage.json"
    }

    static func standaloneTokenPath(homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path) -> String {
        "\(homeDirectory)/.gemini/jetski-standalone-oauth-token"
    }

    static func testKeyringFilePath(homeDirectory: String) -> String {
        "\(homeDirectory)/.gemini/.keychain-gemini-antigravity"
    }

    private static func isRealUserHomeDirectory(_ homeDirectory: String) -> Bool {
        let lhs = URL(fileURLWithPath: homeDirectory).standardizedFileURL.path
        let rhs = URL(fileURLWithPath: FileManager.default.homeDirectoryForCurrentUser.path).standardizedFileURL.path
        return lhs == rhs
    }

    static func activeStorageDisplayPath(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String {
        if let best = resolveActiveStorageCandidates(homeDirectory: homeDirectory).first {
            return best.displayPath
        }
        if FileManager.default.fileExists(atPath: appStoragePath(homeDirectory: homeDirectory)) {
            return "Keychain (gemini/antigravity)"
        }
        return "~/Library/Application Support/Antigravity/.../state.vscdb"
    }

    static func snapshotsDirectory(homeDirectory: String) -> URL {
        URL(fileURLWithPath: homeDirectory)
            .appendingPathComponent(".config/aiusage/antigravity-switch/snapshots", isDirectory: true)
    }

    // MARK: - Keyring (zalando/go-keyring service="gemini", account="antigravity")

    static func encodeKeyringSecret(_ jsonData: Data) -> String {
        keyringBase64Prefix + jsonData.base64EncodedString()
    }

    static func decodeKeyringSecret(_ rawSecret: String) -> Data? {
        let trimmed = rawSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix(keyringBase64Prefix) {
            let b64 = String(trimmed.dropFirst(keyringBase64Prefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return Data(base64Encoded: b64)
        }
        if trimmed.hasPrefix(keyringHexPrefix) {
            let hex = String(trimmed.dropFirst(keyringHexPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard hex.count % 2 == 0 else { return nil }
            var data = Data(capacity: hex.count / 2)
            var index = hex.startIndex
            while index < hex.endIndex {
                let nextIndex = hex.index(index, offsetBy: 2)
                guard let byte = UInt8(hex[index..<nextIndex], radix: 16) else { return nil }
                data.append(byte)
                index = nextIndex
            }
            return data
        }
        if trimmed.hasPrefix("{") {
            return Data(trimmed.utf8)
        }
        return nil
    }

    static func parseKeychainAttributesModificationDate(_ output: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"

        for tag in ["\"mdat\"<timedate>=", "\"cdat\"<timedate>="] {
            guard let tagRange = output.range(of: tag) else { continue }
            let tail = output[tagRange.upperBound...]
            let line = tail.prefix { $0 != "\n" && $0 != "\r" }
            guard let quoteStart = line.firstIndex(of: "\"") else { continue }
            let afterQuote = line[line.index(after: quoteStart)...]
            let digits = afterQuote.prefix(14)
            if digits.count == 14, digits.allSatisfy(\.isNumber),
               let parsed = formatter.date(from: String(digits)) {
                return parsed
            }
        }
        return nil
    }

    static func generateWriterID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<16 {
            bytes[index] = UInt8.random(in: 0...255)
        }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func runSecurityCommand(
        arguments: [String],
        stdinString: String? = nil,
        timeoutSeconds: TimeInterval = 2.0
    ) -> (exitCode: Int32, stdout: String)? {
        let securityPath = "/usr/bin/security"
        guard FileManager.default.isExecutableFile(atPath: securityPath) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: securityPath)
        process.arguments = arguments
        // Install a non-nil terminationHandler so Foundation uses the GCD Mach port waiter
        // rather than blocking CFRunLoopRunInMode on Swift Concurrency cooperative threads.
        process.terminationHandler = { _ in }

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        var stdinPipe: Pipe?
        if stdinString != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            stdinPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        do {
            try process.run()
        } catch {
            return nil
        }

        if let stdinString, let writer = stdinPipe?.fileHandleForWriting {
            try? writer.write(contentsOf: Data(stdinString.utf8))
            try? writer.close()
        }

        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while process.isRunning && Date() < deadline {
            Darwin.usleep(10_000)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(0.1)
            while process.isRunning && Date() < killDeadline {
                Darwin.usleep(10_000)
            }
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }

        let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }

    static func readKeyringRawEntry(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> (secret: String, modifiedAt: Date?)? {
        if !isRealUserHomeDirectory(homeDirectory) {
            let path = testKeyringFilePath(homeDirectory: homeDirectory)
            guard let data = FileManager.default.contents(atPath: path),
                  let secret = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !secret.isEmpty else {
                return nil
            }
            return (secret, fileModificationDate(atPath: path))
        }

        keyringCacheLock.lock()
        if Date().timeIntervalSince(cachedLiveKeyringTimestamp) < 1.0 {
            let cached = cachedLiveKeyringEntry
            keyringCacheLock.unlock()
            return cached
        }
        keyringCacheLock.unlock()

        guard let secretRes = runSecurityCommand(arguments: [
            "find-generic-password", "-s", keyringService, "-wa", keyringAccount
        ]), secretRes.exitCode == 0 else {
            keyringCacheLock.lock()
            cachedLiveKeyringEntry = nil
            cachedLiveKeyringTimestamp = Date()
            keyringCacheLock.unlock()
            return nil
        }

        let secret = secretRes.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { return nil }

        var modifiedAt: Date?
        if let metaRes = runSecurityCommand(arguments: [
            "find-generic-password", "-s", keyringService, "-a", keyringAccount
        ]), metaRes.exitCode == 0 {
            modifiedAt = parseKeychainAttributesModificationDate(metaRes.stdout)
        }

        let entry = (secret: secret, modifiedAt: modifiedAt)
        keyringCacheLock.lock()
        cachedLiveKeyringEntry = entry
        cachedLiveKeyringTimestamp = Date()
        keyringCacheLock.unlock()
        return entry
    }

    static func writeKeyringRawSecret(
        _ encodedSecret: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws {
        let clean = encodedSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        // zalando/go-keyring macOSXKeychain.Set enforces a 4096-byte command buffer for `/usr/bin/security -i`.
        guard !clean.isEmpty, clean.utf8.count <= 3800,
              !clean.contains("\"") && !clean.contains("\n") && !clean.contains("\r") else {
            throw AntigravitySwitchError.databaseWriteFailed("Encoded Keychain StoredToken exceeds safe go-keyring command size.")
        }

        if !isRealUserHomeDirectory(homeDirectory) {
            let path = testKeyringFilePath(homeDirectory: homeDirectory)
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Data(clean.utf8).write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
            return
        }

        let command = "add-generic-password -U -s \"\(keyringService)\" -a \"\(keyringAccount)\" -w \"\(clean)\"\n"
        guard let result = runSecurityCommand(arguments: ["-i"], stdinString: command),
              result.exitCode == 0 else {
            throw AntigravitySwitchError.databaseWriteFailed("Could not update macOS Keychain item (\(keyringService)/\(keyringAccount)).")
        }

        keyringCacheLock.lock()
        cachedLiveKeyringEntry = (secret: clean, modifiedAt: Date())
        cachedLiveKeyringTimestamp = Date()
        keyringCacheLock.unlock()
    }

    // MARK: - Detection

    private struct StorageCandidate {
        let account: AntigravityDetectedAccount
        let accessToken: String
        let refreshToken: String
        let tier: Int
        let modifiedAt: Date
        let priority: Int
        let displayPath: String
        let sourcePath: String
    }

    // Authoritative storage resolution shared across detection, IDE import, and default refresh extraction:
    //   - Tier 2 (Antigravity 2.0 CompositeTokenStorage): Keyring (gemini/antigravity) and ~/.gemini/jetski-standalone-oauth-token.
    //     Within Tier 2, the more recently modified authenticated StoredToken wins (tie-breaker: Keyring > standalone).
    //   - Tier 1 (Legacy Antigravity 1.x): state.vscdb. Used only when Tier 2 has no authenticated StoredToken,
    //     so non-auth SQLite writes (e.g. window.layout) never override an active Antigravity 2.0 Keyring/standalone session.
    private static func resolveActiveStorageCandidates(
        homeDirectory: String
    ) -> [StorageCandidate] {
        var candidates: [StorageCandidate] = []

        if let keyring = detectAccountFromKeyring(homeDirectory: homeDirectory) {
            candidates.append(StorageCandidate(
                account: keyring.account,
                accessToken: keyring.accessToken,
                refreshToken: keyring.refreshToken,
                tier: 2,
                modifiedAt: keyring.modifiedAt ?? .distantPast,
                priority: 3,
                displayPath: "Keychain (gemini/antigravity)",
                sourcePath: "Keychain (gemini/antigravity)"
            ))
        }

        let standalonePath = standaloneTokenPath(homeDirectory: homeDirectory)
        if let standalone = detectAccountFromStandaloneFile(at: standalonePath) {
            let mtime = fileModificationDate(atPath: standalonePath) ?? .distantPast
            candidates.append(StorageCandidate(
                account: standalone.account,
                accessToken: standalone.accessToken,
                refreshToken: standalone.refreshToken,
                tier: 2,
                modifiedAt: mtime,
                priority: 2,
                displayPath: "~/.gemini/jetski-standalone-oauth-token",
                sourcePath: standalonePath
            ))
        }

        let dbPath = primaryDBPath(homeDirectory: homeDirectory)
        if FileManager.default.fileExists(atPath: dbPath),
           let detectedDB = detectAccountFromDB(at: dbPath) {
            let mtime = sqliteModificationDate(atPath: dbPath) ?? .distantPast
            candidates.append(StorageCandidate(
                account: detectedDB.account,
                accessToken: detectedDB.accessToken,
                refreshToken: detectedDB.refreshToken,
                tier: 1,
                modifiedAt: mtime,
                priority: 1,
                displayPath: "~/Library/Application Support/Antigravity/.../state.vscdb",
                sourcePath: dbPath
            ))
        }

        return candidates.sorted { lhs, rhs in
            if lhs.tier != rhs.tier {
                return lhs.tier > rhs.tier
            }
            if lhs.modifiedAt != rhs.modifiedAt {
                return lhs.modifiedAt > rhs.modifiedAt
            }
            return lhs.priority > rhs.priority
        }
    }

    static func detectActiveAccount(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AntigravityDetectedAccount? {
        resolveActiveStorageCandidates(homeDirectory: homeDirectory).first?.account
    }

    private static func fileModificationDate(atPath path: String) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }

    private static func sqliteModificationDate(atPath dbPath: String) -> Date? {
        let mainDate = fileModificationDate(atPath: dbPath)
        let walDate = fileModificationDate(atPath: dbPath + "-wal")
        switch (mainDate, walDate) {
        case let (m?, w?): return max(m, w)
        case let (m?, nil): return m
        case let (nil, w?): return w
        case (nil, nil): return nil
        }
    }

    private static func parseStoredTokenJSON(
        _ data: Data
    ) -> (account: AntigravityDetectedAccount, accessToken: String, refreshToken: String, expiryDate: Date?)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        let token = (json["token"] as? [String: Any]) ?? json
        let access = ((token["access_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refresh = ((token["refresh_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let hasAccess = !access.isEmpty
        let hasRefresh = !refresh.isEmpty
        guard hasAccess || hasRefresh else {
            return nil
        }

        // Identity must be bound directly to the StoredToken payload itself;
        // never substitute agy.onboarding.lastLoginUsername from app_storage.json.
        let explicitEmail = ((json["id_token_email"] as? String)
            ?? (json["email"] as? String)
            ?? (token["email"] as? String))?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let email = explicitEmail, !email.isEmpty, email.contains("@") else {
            return nil
        }

        let expiryStr = (token["expiry"] as? String) ?? (token["expired"] as? String)
        let expiryDate = expiryStr.flatMap { parseISO8601($0) }
        let name = email.components(separatedBy: "@").first ?? email
        let detected = AntigravityDetectedAccount(
            email: email,
            name: name,
            hasAccessToken: hasAccess,
            hasRefreshToken: hasRefresh
        )
        return (detected, access, refresh, expiryDate)
    }

    private static func detectAccountFromKeyring(
        homeDirectory: String
    ) -> (account: AntigravityDetectedAccount, accessToken: String, refreshToken: String, modifiedAt: Date?)? {
        guard let entry = readKeyringRawEntry(homeDirectory: homeDirectory),
              let jsonData = decodeKeyringSecret(entry.secret),
              let parsed = parseStoredTokenJSON(jsonData) else {
            return nil
        }
        let effectiveDate = entry.modifiedAt ?? parsed.expiryDate?.addingTimeInterval(-3600)
        return (parsed.account, parsed.accessToken, parsed.refreshToken, effectiveDate)
    }

    private static func detectAccountFromStandaloneFile(
        at path: String
    ) -> (account: AntigravityDetectedAccount, accessToken: String, refreshToken: String)? {
        guard let data = FileManager.default.contents(atPath: path),
              let parsed = parseStoredTokenJSON(data) else {
            return nil
        }
        return (parsed.account, parsed.accessToken, parsed.refreshToken)
    }

    static func extractRefreshToken(
        forEmail expectedEmail: String? = nil,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> String? {
        let targetEmail: String
        if let expectedEmail {
            guard let clean = normalizeEmail(expectedEmail) else { return nil }
            targetEmail = clean
        } else {
            // Use the exact same active storage resolution policy as detectActiveAccount & discoverIDECandidatePayload.
            guard let active = resolveActiveStorageCandidates(homeDirectory: homeDirectory).first else {
                return nil
            }
            if !active.refreshToken.isEmpty {
                return active.refreshToken
            }
            guard let activeEmail = normalizeEmail(active.account.email) else {
                return nil
            }
            targetEmail = activeEmail
        }

        let fm = FileManager.default

        if let keyringEntry = readKeyringRawEntry(homeDirectory: homeDirectory),
           let keyringData = decodeKeyringSecret(keyringEntry.secret),
           let parsedKeyring = parseStoredTokenJSON(keyringData),
           !parsedKeyring.refreshToken.isEmpty,
           normalizeEmail(parsedKeyring.account.email) == targetEmail {
            return parsedKeyring.refreshToken
        }

        for dbPath in candidateDBPaths(homeDirectory: homeDirectory) where fm.fileExists(atPath: dbPath) {
            if let token = extractRefreshTokenFromDB(at: dbPath, expectedEmail: targetEmail) {
                return token
            }
        }

        if let snapshot = loadAccountSnapshot(forEmail: targetEmail, homeDirectory: homeDirectory) {
            if let storedTokenRefresh = snapshot[snapshotStoredTokenRefreshKey]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !storedTokenRefresh.isEmpty {
                return storedTokenRefresh
            }
            for key in ["antigravityUnifiedStateSync.oauthToken", "jetskiStateSync.agentManagerInitState"] {
                if let b64 = snapshot[key],
                   let token = extractRefreshTokenFromBase64Protobuf(b64) {
                    return token
                }
            }
        }

        let standaloneCandidates = [
            "\(homeDirectory)/.gemini/jetski-standalone-oauth-token",
            "\(homeDirectory)/.gemini/antigravity-cli/antigravity-oauth-token"
        ]
        for path in standaloneCandidates {
            if let data = fm.contents(atPath: path),
               let parsed = parseStoredTokenJSON(data),
               !parsed.refreshToken.isEmpty,
               normalizeEmail(parsed.account.email) == targetEmail {
                return parsed.refreshToken
            }
        }
        return nil
    }

    static func discoverIDECandidatePayload(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AntigravityIDECandidatePayload? {
        guard let active = resolveActiveStorageCandidates(homeDirectory: homeDirectory).first,
              !active.accessToken.isEmpty else {
            return nil
        }

        let email = active.account.email
        let refreshToken: String?
        if !active.refreshToken.isEmpty {
            refreshToken = active.refreshToken
        } else if let email {
            refreshToken = extractRefreshToken(forEmail: email, homeDirectory: homeDirectory)
        } else {
            refreshToken = nil
        }

        return AntigravityIDECandidatePayload(
            email: email,
            name: active.account.name,
            accessToken: active.accessToken,
            refreshToken: refreshToken,
            databasePath: active.sourcePath
        )
    }

    private static func normalizeEmail(_ email: String?) -> String? {
        guard let trimmed = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func readAuthStatusJSON(db: OpaquePointer?) -> [String: Any]? {
        guard let rawStatus = queryItemValue(db: db, key: "antigravityAuthStatus"),
              let data = rawStatus.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private static func readEmailFromOpenDB(_ db: OpaquePointer?) -> String? {
        readAuthStatusJSON(db: db)?["email"] as? String
    }

    private static func detectAccountFromDB(
        at dbPath: String
    ) -> (account: AntigravityDetectedAccount, accessToken: String, refreshToken: String)? {
        guard let db = openSQLite(at: dbPath, readonly: true) else { return nil }
        defer { sqlite3_close(db) }

        var email: String?
        var name: String?
        var accessToken = ""

        if let json = readAuthStatusJSON(db: db) {
            email = (json["email"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            name = (json["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let apiKey = (json["apiKey"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !apiKey.isEmpty {
                accessToken = apiKey
            }
        }

        let refreshToken = extractRefreshTokenFromOpenDB(db) ?? ""
        let hasAccess = !accessToken.isEmpty
        let hasRefresh = !refreshToken.isEmpty
        guard hasAccess || hasRefresh else {
            return nil
        }
        let detected = AntigravityDetectedAccount(
            email: email?.isEmpty == false ? email : nil,
            name: name?.isEmpty == false ? name : nil,
            hasAccessToken: hasAccess,
            hasRefreshToken: hasRefresh
        )
        return (detected, accessToken, refreshToken)
    }

    static func extractRefreshTokenFromDB(at dbPath: String, expectedEmail: String? = nil) -> String? {
        guard let db = openSQLite(at: dbPath, readonly: true) else { return nil }
        defer { sqlite3_close(db) }
        if let expectedEmail {
            guard let required = normalizeEmail(expectedEmail),
                  normalizeEmail(readEmailFromOpenDB(db)) == required else {
                return nil
            }
        }
        return extractRefreshTokenFromOpenDB(db)
    }

    private static func extractRefreshTokenFromOpenDB(_ db: OpaquePointer?) -> String? {
        for key in ["antigravityUnifiedStateSync.oauthToken", "jetskiStateSync.agentManagerInitState"] {
            if let b64 = queryItemValue(db: db, key: key),
               let token = extractRefreshTokenFromBase64Protobuf(b64) {
                return token
            }
        }
        return nil
    }

    static func extractRefreshTokenFromBase64Protobuf(_ b64String: String) -> String? {
        guard let outerDecoded = Data(base64Encoded: b64String) else {
            return nil
        }

        // 1. Structured Protobuf extraction (jetskiStateSync Field 6 -> OAuthTokenInfo Field 3)
        if let oauthInfo = ProtobufCodec.extractFirstBytesField(outerDecoded, fieldNumber: 6),
           let token = ProtobufCodec.extractFirstStringField(oauthInfo, fieldNumber: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        // 2. Structured Protobuf extraction (antigravityUnifiedStateSync.oauthToken sentinel -> OAuthTokenInfo Field 3)
        if let oauthInfo = ProtobufCodec.extractUnifiedTopicPayload(outerDecoded, targetKey: "oauthTokenInfoSentinelKey"),
           let token = ProtobufCodec.extractFirstStringField(oauthInfo, fieldNumber: 3)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !token.isEmpty {
            return token
        }

        // 3. Fallback regex scan for raw 1// refresh token patterns
        guard let outerText = String(data: outerDecoded, encoding: .isoLatin1),
              let refreshTokenPattern = try? NSRegularExpression(pattern: #"1//[A-Za-z0-9_-]+"#) else {
            return nil
        }

        if let match = refreshTokenPattern.firstMatch(in: outerText, range: NSRange(outerText.startIndex..., in: outerText)),
           let range = Range(match.range, in: outerText) {
            return String(outerText[range])
        }

        guard let innerB64Pattern = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/_-]{40,}"#) else { return nil }
        let innerMatches = innerB64Pattern.matches(in: outerText, range: NSRange(outerText.startIndex..., in: outerText))
        for innerMatch in innerMatches {
            guard let matchRange = Range(innerMatch.range, in: outerText) else { continue }
            let segment = String(outerText[matchRange])
                .replacingOccurrences(of: "-", with: "+")
                .replacingOccurrences(of: "_", with: "/")
            let padded = segment + String(repeating: "=", count: (4 - segment.count % 4) % 4)
            guard let innerData = Data(base64Encoded: padded),
                  let innerText = String(data: innerData, encoding: .isoLatin1) else {
                continue
            }
            if let match = refreshTokenPattern.firstMatch(in: innerText, range: NSRange(innerText.startIndex..., in: innerText)),
               let range = Range(match.range, in: innerText) {
                return String(innerText[range])
            }
        }
        return nil
    }

    // MARK: - Switching

    struct ParsedCredential {
        let accessToken: String
        let refreshToken: String
        let email: String
        let name: String
        let expirySeconds: Int64
        let idToken: String?
        let projectId: String?
    }

    static func parseCredentialFile(
        at url: URL,
        fallbackEmail: String?,
        fallbackName: String?
    ) throws -> ParsedCredential {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AntigravitySwitchError.authFileNotFound(url.path)
        }
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AntigravitySwitchError.invalidAuthFile("Root JSON is not an object")
        }

        let tokenDict = (root["token"] as? [String: Any]) ?? (root["tokens"] as? [String: Any]) ?? root
        let accessToken = ((tokenDict["access_token"] as? String) ?? (root["access_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refreshToken = ((tokenDict["refresh_token"] as? String) ?? (root["refresh_token"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !accessToken.isEmpty else {
            throw AntigravitySwitchError.missingAccessToken
        }

        let rawEmail = ((root["email"] as? String)
            ?? (root["id_token_email"] as? String)
            ?? (tokenDict["email"] as? String)
            ?? fallbackEmail
            ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let email = rawEmail.isEmpty ? "antigravity-user@google.com" : rawEmail
        let rawName = ((root["name"] as? String) ?? fallbackName ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = email.components(separatedBy: "@").first ?? email
        let name = (rawName.isEmpty || rawName == email) ? defaultName : rawName

        let defaultExpiry = Int64(Date().addingTimeInterval(3600).timeIntervalSince1970)
        var expirySeconds = defaultExpiry

        if let expiredStr = (tokenDict["expired"] as? String) ?? (tokenDict["expiry"] as? String) ?? (root["expired"] as? String),
           let parsedDate = parseISO8601(expiredStr) {
            let ts = Int64(parsedDate.timeIntervalSince1970)
            // Ignore synthetic 2000-01-01 placeholder timestamps
            if ts > 1_000_000_000 {
                expirySeconds = ts
            }
        } else if let timestampMs = int64Value(root["timestamp"]),
                  let expiresIn = int64Value(root["expires_in"]) {
            expirySeconds = (timestampMs / 1000) + expiresIn
        }

        if expirySeconds <= Int64(Date().timeIntervalSince1970) && refreshToken.isEmpty {
            expirySeconds = defaultExpiry
        }

        let idToken = ((tokenDict["id_token"] as? String) ?? (root["id_token"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let projectId = ((root["project_id"] as? String) ?? (tokenDict["project_id"] as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return ParsedCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            email: email,
            name: name,
            expirySeconds: expirySeconds,
            idToken: idToken?.isEmpty == false ? idToken : nil,
            projectId: projectId?.isEmpty == false ? projectId : nil
        )
    }

    @discardableResult
    static func switchAccount(
        authFileURL: URL,
        fallbackEmail: String? = nil,
        fallbackName: String? = nil,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) throws -> AntigravitySwitchedIdentity {
        var parsed = try parseCredentialFile(at: authFileURL, fallbackEmail: fallbackEmail, fallbackName: fallbackName)

        let existingDBPaths = candidateDBPaths(homeDirectory: homeDirectory).filter {
            FileManager.default.fileExists(atPath: $0)
        }
        let appStorage = appStoragePath(homeDirectory: homeDirectory)
        let hasAppStorage = FileManager.default.fileExists(atPath: appStorage)
        let standalonePath = standaloneTokenPath(homeDirectory: homeDirectory)
        let hasStandaloneToken = FileManager.default.fileExists(atPath: standalonePath)
        let existingKeyringEntry = readKeyringRawEntry(homeDirectory: homeDirectory)
        let hasKeyringToken = existingKeyringEntry != nil

        guard !existingDBPaths.isEmpty || hasAppStorage || hasStandaloneToken || hasKeyringToken else {
            throw AntigravitySwitchError.databaseNotFound(primaryDBPath(homeDirectory: homeDirectory))
        }

        // If the stored auth file came from IDE import without a refresh_token, try recovering
        // the refresh_token from a verified same-email current DB, Keyring, snapshot, or standalone file.
        var recoveredRefreshToken: String?
        if parsed.refreshToken.isEmpty {
            if let recovered = extractRefreshToken(forEmail: parsed.email, homeDirectory: homeDirectory) {
                parsed = ParsedCredential(
                    accessToken: parsed.accessToken,
                    refreshToken: recovered,
                    email: parsed.email,
                    name: parsed.name,
                    expirySeconds: parsed.expirySeconds,
                    idToken: parsed.idToken,
                    projectId: parsed.projectId
                )
                recoveredRefreshToken = recovered
            }
        }

        guard !parsed.refreshToken.isEmpty else {
            throw AntigravitySwitchError.missingRefreshToken
        }

        let writerID = generateWriterID()
        let requiresKeyringUpdate = hasAppStorage || hasKeyringToken

        // Preflight Keyring StoredToken encoding and size limit BEFORE mutating any database, snapshot, or file,
        // so oversized or invalid tokens fail atomically without leaving side effects or divergent stores.
        let preflightKeyringSecret: String?
        if requiresKeyringUpdate {
            preflightKeyringSecret = try encodeValidatedKeyringStoredToken(
                credential: parsed,
                writerID: writerID
            )
        } else {
            preflightKeyringSecret = nil
        }

        // Snapshot all existing databases and StoredToken stores right before writing,
        // so activating a refreshless credential for the currently active account preserves its live refresh token.
        for dbPath in existingDBPaths {
            if let db = openSQLite(at: dbPath, readonly: true) {
                saveCurrentAccountSnapshot(db: db, homeDirectory: homeDirectory)
                sqlite3_close(db)
            }
        }
        if let existingKeyringEntry,
           let keyringData = decodeKeyringSecret(existingKeyringEntry.secret) {
            saveCurrentStoredTokenSnapshot(from: keyringData, homeDirectory: homeDirectory)
        }
        if let standaloneData = FileManager.default.contents(atPath: standalonePath) {
            saveCurrentStoredTokenSnapshot(from: standaloneData, homeDirectory: homeDirectory)
        }

        var fileBackups: [(path: String, data: Data?)] = []
        var candidateRollbackPaths: [String] = [
            "\(homeDirectory)/.gemini/jetski-standalone-oauth-token",
            "\(homeDirectory)/.gemini/antigravity-cli/antigravity-oauth-token"
        ]
        for dbPath in existingDBPaths {
            candidateRollbackPaths.append(dbPath)
            candidateRollbackPaths.append("\(dbPath)-wal")
            candidateRollbackPaths.append("\(dbPath)-shm")
            candidateRollbackPaths.append("\(dbPath).backup")
            candidateRollbackPaths.append("\(dbPath).backup-wal")
            candidateRollbackPaths.append("\(dbPath).backup-shm")
        }
        for path in candidateRollbackPaths {
            if FileManager.default.fileExists(atPath: path) {
                fileBackups.append((path: path, data: FileManager.default.contents(atPath: path)))
            } else {
                fileBackups.append((path: path, data: nil))
            }
        }
        let previousKeyringSecret = existingKeyringEntry?.secret
        let testKeyringPath = testKeyringFilePath(homeDirectory: homeDirectory)
        let hadTestKeyringFile = !isRealUserHomeDirectory(homeDirectory)
            && FileManager.default.fileExists(atPath: testKeyringPath)

        var updatedAnyAuthStore = false

        do {
            // 1. Update legacy SQLite databases first if present.
            for dbPath in existingDBPaths {
                try injectCredentialIntoDatabase(
                    at: dbPath,
                    credential: parsed,
                    homeDirectory: homeDirectory,
                    saveSnapshotBeforeWrite: false
                )
                updatedAnyAuthStore = true
                let backupDBPath = dbPath + ".backup"
                if FileManager.default.fileExists(atPath: backupDBPath) {
                    try? injectCredentialIntoDatabase(
                        at: backupDBPath,
                        credential: parsed,
                        homeDirectory: homeDirectory,
                        saveSnapshotBeforeWrite: false
                    )
                }
            }

            // 2. Sync standalone/CLI fallback files if present on disk; surface write errors if present.
            if try syncStandaloneFallbackFiles(credential: parsed, writerID: writerID, homeDirectory: homeDirectory) {
                updatedAnyAuthStore = true
            }

            // 3. Commit authoritative Antigravity 2.0 KeyringTokenStorage last so a SQLite/fallback failure
            // never leaves Keyring holding the new account while local stores fail.
            if let preflightKeyringSecret {
                try writeKeyringRawSecret(preflightKeyringSecret, homeDirectory: homeDirectory)
                updatedAnyAuthStore = true
            }

            guard updatedAnyAuthStore else {
                throw AntigravitySwitchError.databaseWriteFailed("No Antigravity credential store could be updated.")
            }
        } catch {
            for backup in fileBackups {
                if let data = backup.data {
                    try? data.write(to: URL(fileURLWithPath: backup.path), options: .atomic)
                } else if FileManager.default.fileExists(atPath: backup.path) {
                    try? FileManager.default.removeItem(atPath: backup.path)
                }
            }
            if let previousKeyringSecret {
                try? writeKeyringRawSecret(previousKeyringSecret, homeDirectory: homeDirectory)
            } else if !isRealUserHomeDirectory(homeDirectory) && !hadTestKeyringFile {
                try? FileManager.default.removeItem(atPath: testKeyringPath)
            }
            throw error
        }

        if let recoveredRefreshToken {
            backfillRefreshTokenInAuthFile(at: authFileURL, refreshToken: recoveredRefreshToken)
        }

        // 4. Sync Antigravity 2.0 Hub onboarding username hint in app_storage.json last.
        syncAppStorageFile(email: parsed.email, homeDirectory: homeDirectory)

        return AntigravitySwitchedIdentity(
            email: parsed.email,
            name: parsed.name,
            sourceFilePath: authFileURL.path
        )
    }

    private static func backfillRefreshTokenInAuthFile(at url: URL, refreshToken: String) {
        guard !refreshToken.isEmpty,
              let data = try? Data(contentsOf: url),
              var root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }
        if var tokenDict = root["token"] as? [String: Any] {
            tokenDict["refresh_token"] = refreshToken
            root["token"] = tokenDict
        } else if var tokensDict = root["tokens"] as? [String: Any] {
            tokensDict["refresh_token"] = refreshToken
            root["tokens"] = tokensDict
        } else {
            root["refresh_token"] = refreshToken
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? encoded.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func injectCredentialIntoDatabase(
        at dbPath: String,
        credential: ParsedCredential,
        homeDirectory: String,
        saveSnapshotBeforeWrite: Bool = true
    ) throws {
        guard let db = openSQLite(at: dbPath, readonly: false) else {
            throw AntigravitySwitchError.databaseOpenFailed(dbPath)
        }
        defer { sqlite3_close(db) }

        sqlite3_busy_timeout(db, 2000)

        if saveSnapshotBeforeWrite {
            saveCurrentAccountSnapshot(db: db, homeDirectory: homeDirectory)
        }

        let targetSnapshot = loadAccountSnapshot(forEmail: credential.email, homeDirectory: homeDirectory)

        // 1. Build updated antigravityAuthStatus JSON
        let existingAuthStatusRaw = targetSnapshot?["antigravityAuthStatus"]
            ?? queryItemValue(db: db, key: "antigravityAuthStatus")
        var authStatusDict: [String: Any] = [:]
        if let existingAuthStatusRaw,
           let data = existingAuthStatusRaw.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            authStatusDict = json
        }

        let existingUserStatusB64 = authStatusDict["userStatusProtoBinaryBase64"] as? String
        let updatedUserStatusBytes = ProtobufCodec.updateUserStatusPayload(
            existingBase64: existingUserStatusB64,
            name: credential.name,
            email: credential.email
        )
        authStatusDict["name"] = credential.name
        authStatusDict["email"] = credential.email
        authStatusDict["apiKey"] = credential.accessToken
        authStatusDict["userStatusProtoBinaryBase64"] = updatedUserStatusBytes.base64EncodedString()

        let authStatusData = try JSONSerialization.data(withJSONObject: authStatusDict, options: [.sortedKeys])
        guard let authStatusJSON = String(data: authStatusData, encoding: .utf8) else {
            throw AntigravitySwitchError.databaseWriteFailed("Could not encode antigravityAuthStatus JSON")
        }

        // 2. Build updated jetskiStateSync.agentManagerInitState (Field 6 OAuthTokenInfo + preserved fields)
        let existingJetskiB64 = targetSnapshot?["jetskiStateSync.agentManagerInitState"]
            ?? queryItemValue(db: db, key: "jetskiStateSync.agentManagerInitState")
        let updatedJetskiB64 = ProtobufCodec.updateJetskiAgentManagerState(
            existingBase64: existingJetskiB64,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expirySeconds: credential.expirySeconds
        )

        // 3. Build updated antigravityUnifiedStateSync.oauthToken & userStatus
        let existingUnifiedOAuthB64 = targetSnapshot?["antigravityUnifiedStateSync.oauthToken"]
            ?? queryItemValue(db: db, key: "antigravityUnifiedStateSync.oauthToken")
        let updatedUnifiedOAuthB64 = ProtobufCodec.updateUnifiedOAuthTokenTopic(
            existingBase64: existingUnifiedOAuthB64,
            accessToken: credential.accessToken,
            refreshToken: credential.refreshToken,
            expirySeconds: credential.expirySeconds,
            idToken: credential.idToken
        )
        let updatedUnifiedUserStatusB64 = ProtobufCodec.createUnifiedStateEntry(
            sentinelKey: "userStatusSentinelKey",
            payload: updatedUserStatusBytes
        )

        // Execute atomic transaction in SQLite
        guard sqlite3_exec(db, "BEGIN IMMEDIATE TRANSACTION;", nil, nil, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw AntigravitySwitchError.databaseWriteFailed(msg)
        }

        do {
            try upsertItemValue(db: db, key: "antigravityAuthStatus", value: authStatusJSON)
            try upsertItemValue(db: db, key: "jetskiStateSync.agentManagerInitState", value: updatedJetskiB64)
            try upsertItemValue(db: db, key: "antigravityUnifiedStateSync.oauthToken", value: updatedUnifiedOAuthB64)
            try upsertItemValue(db: db, key: "antigravityUnifiedStateSync.userStatus", value: updatedUnifiedUserStatusB64)
            try upsertItemValue(db: db, key: "antigravityOnboarding", value: "true")
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                let msg = String(cString: sqlite3_errmsg(db))
                throw AntigravitySwitchError.databaseWriteFailed(msg)
            }
        } catch {
            sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }

    private static func buildStoredTokenPayload(
        credential: ParsedCredential,
        writerID: String,
        includeExtendedFields: Bool
    ) -> [String: Any] {
        let expiryISO = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: TimeInterval(credential.expirySeconds))
        )
        var payload: [String: Any] = [
            "token": [
                "access_token": credential.accessToken,
                "token_type": "Bearer",
                "refresh_token": credential.refreshToken,
                "expiry": expiryISO
            ],
            "auth_method": "consumer",
            "id_token_email": credential.email,
            "writer_id": writerID
        ]
        if let projectId = credential.projectId {
            payload["project_id"] = projectId
        }
        if includeExtendedFields {
            payload["email"] = credential.email
            if let idToken = credential.idToken {
                payload["id_token"] = idToken
            }
        }
        return payload
    }

    private static func encodeValidatedKeyringStoredToken(
        credential: ParsedCredential,
        writerID: String
    ) throws -> String {
        // Keychain StoredToken JSON must be compact (no .prettyPrinted and no raw id_token JWT)
        // so the go-keyring `security -i` command remains well below 4096 bytes.
        let payload = buildStoredTokenPayload(
            credential: credential,
            writerID: writerID,
            includeExtendedFields: false
        )
        guard let jsonData = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            throw AntigravitySwitchError.databaseWriteFailed("Could not encode Keychain StoredToken JSON.")
        }
        let encodedSecret = encodeKeyringSecret(jsonData).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encodedSecret.isEmpty, encodedSecret.utf8.count <= 3800,
              !encodedSecret.contains("\"") && !encodedSecret.contains("\n") && !encodedSecret.contains("\r") else {
            throw AntigravitySwitchError.databaseWriteFailed("Encoded Keychain StoredToken exceeds safe go-keyring command size.")
        }
        return encodedSecret
    }

    static func syncAppStorageFile(email: String, homeDirectory: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let path = appStoragePath(homeDirectory: homeDirectory)
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        var storageDict: [String: Any] = [:]
        if let existingData = fm.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: existingData) as? [String: Any] {
            storageDict = json
        }
        storageDict["agy.onboarding.lastLoginUsername"] = trimmed
        if storageDict["agy.onboarding.lastLoginIsGcpTos"] == nil {
            storageDict["agy.onboarding.lastLoginIsGcpTos"] = "false"
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: storageDict, options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? encoded.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    @discardableResult
    private static func syncStandaloneFallbackFiles(
        credential: ParsedCredential,
        writerID: String,
        homeDirectory: String
    ) throws -> Bool {
        let payload = buildStoredTokenPayload(
            credential: credential,
            writerID: writerID,
            includeExtendedFields: true
        )
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]) else {
            throw AntigravitySwitchError.databaseWriteFailed("Could not encode standalone StoredToken JSON.")
        }

        let fm = FileManager.default
        let candidatePaths = [
            "\(homeDirectory)/.gemini/jetski-standalone-oauth-token",
            "\(homeDirectory)/.gemini/antigravity-cli/antigravity-oauth-token"
        ]
        var wroteAny = false
        for path in candidatePaths where fm.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path)
            do {
                try data.write(to: url, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
                wroteAny = true
            } catch {
                throw AntigravitySwitchError.databaseWriteFailed("Could not update standalone token file at \(path).")
            }
        }
        return wroteAny
    }

    // MARK: - Per-Account SQLite & StoredToken Snapshots

    private static func saveCurrentStoredTokenSnapshot(from jsonData: Data, homeDirectory: String) {
        guard let parsed = parseStoredTokenJSON(jsonData),
              !parsed.refreshToken.isEmpty,
              let email = normalizeEmail(parsed.account.email) else {
            return
        }
        var snapshot = loadAccountSnapshot(forEmail: email, homeDirectory: homeDirectory) ?? [:]
        snapshot[snapshotStoredTokenRefreshKey] = parsed.refreshToken
        writeAccountSnapshot(snapshot, forEmail: email, homeDirectory: homeDirectory)
    }

    private static func saveCurrentAccountSnapshot(db: OpaquePointer?, homeDirectory: String) {
        guard let statusJSON = readAuthStatusJSON(db: db),
              let email = normalizeEmail(statusJSON["email"] as? String) else {
            return
        }

        var snapshot = loadAccountSnapshot(forEmail: email, homeDirectory: homeDirectory) ?? [:]
        let currentHasRefresh = extractRefreshTokenFromOpenDB(db) != nil
        for key in stateKeysToSnapshot {
            if let val = queryItemValue(db: db, key: key) {
                if !currentHasRefresh,
                   (key == "jetskiStateSync.agentManagerInitState" || key == "antigravityUnifiedStateSync.oauthToken"),
                   let existingVal = snapshot[key],
                   extractRefreshTokenFromBase64Protobuf(existingVal) != nil {
                    continue
                }
                snapshot[key] = val
            }
        }
        guard !snapshot.isEmpty else { return }
        writeAccountSnapshot(snapshot, forEmail: email, homeDirectory: homeDirectory)
    }

    private static func writeAccountSnapshot(_ snapshot: [String: String], forEmail email: String, homeDirectory: String) {
        let dir = snapshotsDirectory(homeDirectory: homeDirectory)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let safeFilename = email.replacingOccurrences(of: "/", with: "_") + ".json"
        let fileURL = dir.appendingPathComponent(safeFilename)
        if let encoded = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]) {
            try? encoded.write(to: fileURL, options: .atomic)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
    }

    private static func loadAccountSnapshot(forEmail email: String, homeDirectory: String) -> [String: String]? {
        guard let normalized = normalizeEmail(email) else { return nil }
        let safeFilename = normalized.replacingOccurrences(of: "/", with: "_") + ".json"
        let fileURL = snapshotsDirectory(homeDirectory: homeDirectory).appendingPathComponent(safeFilename)
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return nil
        }
        return dict
    }

    // MARK: - SQLite Helpers

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private static func openSQLite(at path: String, readonly: Bool) -> OpaquePointer? {
        var db: OpaquePointer?
        let flags = (readonly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE) | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            if let db { sqlite3_close(db) }
            return nil
        }
        return db
    }

    private static func queryItemValue(db: OpaquePointer?, key: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM ItemTable WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cStr = sqlite3_column_text(stmt, 0) else {
            return nil
        }
        return String(cString: cStr)
    }

    private static func upsertItemValue(db: OpaquePointer?, key: String, value: String) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO ItemTable (key, value) VALUES (?, ?)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "prepare failed"
            throw AntigravitySwitchError.databaseWriteFailed(msg)
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, (key as NSString).utf8String, -1, sqliteTransient)
        sqlite3_bind_text(stmt, 2, (value as NSString).utf8String, -1, sqliteTransient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "step failed"
            throw AntigravitySwitchError.databaseWriteFailed(msg)
        }
    }

    // MARK: - Protobuf Wire Codec

    enum ProtobufCodec {
        static func encodeVarint(_ value: UInt64) -> Data {
            var val = value
            var data = Data()
            while val >= 0x80 {
                data.append(UInt8((val & 0x7F) | 0x80))
                val >>= 7
            }
            data.append(UInt8(val))
            return data
        }

        static func readVarint(_ data: Data, offset: Int) -> (UInt64, Int)? {
            guard offset >= 0, offset < data.count else { return nil }
            var result: UInt64 = 0
            var shift: UInt64 = 0
            var pos = offset
            while pos < data.count {
                let byte = data[pos]
                pos += 1
                if shift == 63 && byte > 0x01 {
                    return nil
                }
                result |= UInt64(byte & 0x7F) << shift
                if (byte & 0x80) == 0 {
                    return (result, pos)
                }
                shift += 7
                if shift >= 64 { return nil }
            }
            return nil
        }

        static func decodeTag(_ data: Data, offset: Int) -> (fieldNumber: UInt32, wireType: UInt8, afterTag: Int)? {
            guard let (tag, afterTag) = readVarint(data, offset: offset) else { return nil }
            let wireType = UInt8(tag & 0x07)
            let rawFieldNum = tag >> 3
            // Protobuf valid field number range is 1 ... 536,870,911 ((1 << 29) - 1)
            guard rawFieldNum >= 1, rawFieldNum <= 0x1FFF_FFFF else { return nil }
            return (UInt32(rawFieldNum), wireType, afterTag)
        }

        static func readLengthDelimitedRange(_ data: Data, offset: Int) -> Range<Int>? {
            guard offset >= 0, offset <= data.count,
                  let (len, contentStart) = readVarint(data, offset: offset),
                  contentStart >= 0,
                  contentStart <= data.count,
                  len <= UInt64(data.count - contentStart) else {
                return nil
            }
            let end = contentStart + Int(len)
            return contentStart..<end
        }

        static func skipField(_ data: Data, offset: Int, wireType: UInt8) -> Int? {
            guard offset >= 0, offset <= data.count else { return nil }
            switch wireType {
            case 0:
                guard let (_, next) = readVarint(data, offset: offset) else { return nil }
                return next
            case 1:
                guard data.count - offset >= 8 else { return nil }
                return offset + 8
            case 2:
                return readLengthDelimitedRange(data, offset: offset)?.upperBound
            case 5:
                guard data.count - offset >= 4 else { return nil }
                return offset + 4
            default:
                return nil
            }
        }

        static func removeFields(_ data: Data, fieldNumbers: Set<UInt32>) -> Data? {
            var result = Data()
            var offset = 0
            while offset < data.count {
                let start = offset
                guard let (fieldNum, wireType, afterTag) = decodeTag(data, offset: offset),
                      let nextOffset = skipField(data, offset: afterTag, wireType: wireType) else {
                    return nil
                }
                if !fieldNumbers.contains(fieldNum) {
                    result.append(data.subdata(in: start..<nextOffset))
                }
                offset = nextOffset
            }
            return result
        }

        static func encodeLenDelimField(_ fieldNumber: UInt32, payload: Data) -> Data {
            let tag = UInt64(fieldNumber << 3) | 2
            var out = encodeVarint(tag)
            out.append(encodeVarint(UInt64(payload.count)))
            out.append(payload)
            return out
        }

        static func encodeStringField(_ fieldNumber: UInt32, value: String) -> Data {
            encodeLenDelimField(fieldNumber, payload: Data(value.utf8))
        }

        static func encodeVarintField(_ fieldNumber: UInt32, value: UInt64) -> Data {
            let tag = UInt64(fieldNumber << 3) | 0
            var out = encodeVarint(tag)
            out.append(encodeVarint(value))
            return out
        }

        static func createOAuthTokenInfo(
            accessToken: String,
            refreshToken: String,
            expirySeconds: Int64,
            includeZeroNanos: Bool,
            idToken: String? = nil
        ) -> Data {
            var info = Data()
            info.append(encodeStringField(1, value: accessToken))
            info.append(encodeStringField(2, value: "Bearer"))
            if !refreshToken.isEmpty {
                info.append(encodeStringField(3, value: refreshToken))
            }
            var timestampMsg = encodeVarintField(1, value: UInt64(max(expirySeconds, 0)))
            if includeZeroNanos {
                timestampMsg.append(encodeVarintField(2, value: 0))
            }
            info.append(encodeLenDelimField(4, payload: timestampMsg))
            if let idToken, !idToken.isEmpty {
                info.append(encodeStringField(5, value: idToken))
            }
            return info
        }

        static func updateJetskiAgentManagerState(
            existingBase64: String?,
            accessToken: String,
            refreshToken: String,
            expirySeconds: Int64
        ) -> String {
            let oauthInfo = createOAuthTokenInfo(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expirySeconds: expirySeconds,
                includeZeroNanos: false
            )
            let field6 = encodeLenDelimField(6, payload: oauthInfo)

            if let existingBase64,
               let existingData = Data(base64Encoded: existingBase64),
               let stripped = removeFields(existingData, fieldNumbers: [6]) {
                var combined = Data()
                combined.append(field6)
                combined.append(stripped)
                return combined.base64EncodedString()
            }
            return field6.base64EncodedString()
        }

        static func updateUserStatusPayload(
            existingBase64: String?,
            name: String,
            email: String
        ) -> Data {
            var header = Data()
            header.append(encodeStringField(3, value: name))
            header.append(encodeStringField(7, value: email))

            if let existingBase64,
               let existingData = Data(base64Encoded: existingBase64),
               let stripped = removeFields(existingData, fieldNumbers: [3, 7]) {
                var combined = Data()
                combined.append(header)
                combined.append(stripped)
                return combined
            }
            return header
        }

        static func createUnifiedTopicEntry(sentinelKey: String, payload: Data) -> Data {
            let row = encodeStringField(1, value: payload.base64EncodedString())
            var entry = encodeStringField(1, value: sentinelKey)
            entry.append(encodeLenDelimField(2, payload: row))
            return encodeLenDelimField(1, payload: entry)
        }

        static func createUnifiedStateEntry(sentinelKey: String, payload: Data) -> String {
            createUnifiedTopicEntry(sentinelKey: sentinelKey, payload: payload).base64EncodedString()
        }

        static func updateUnifiedOAuthTokenTopic(
            existingBase64: String?,
            accessToken: String,
            refreshToken: String,
            expirySeconds: Int64,
            idToken: String?
        ) -> String {
            let oauthInfo = createOAuthTokenInfo(
                accessToken: accessToken,
                refreshToken: refreshToken,
                expirySeconds: expirySeconds,
                includeZeroNanos: true,
                idToken: idToken
            )
            let newEntry = createUnifiedTopicEntry(sentinelKey: "oauthTokenInfoSentinelKey", payload: oauthInfo)

            guard let existingBase64,
                  let existingData = Data(base64Encoded: existingBase64),
                  let filtered = removeUnifiedTopicEntry(existingData, targetKey: "oauthTokenInfoSentinelKey") else {
                return newEntry.base64EncodedString()
            }
            var combined = filtered
            combined.append(newEntry)
            return combined.base64EncodedString()
        }

        private static func removeUnifiedTopicEntry(_ data: Data, targetKey: String) -> Data? {
            var result = Data()
            var offset = 0
            while offset < data.count {
                let start = offset
                guard let (fieldNum, wireType, afterTag) = decodeTag(data, offset: offset),
                      let nextOffset = skipField(data, offset: afterTag, wireType: wireType) else {
                    return nil
                }

                var shouldRemove = false
                if fieldNum == 1 && wireType == 2,
                   let payloadRange = readLengthDelimitedRange(data, offset: afterTag) {
                    let entryData = data.subdata(in: payloadRange)
                    if extractFirstStringField(entryData, fieldNumber: 1) == targetKey {
                        shouldRemove = true
                    }
                }
                if !shouldRemove {
                    result.append(data.subdata(in: start..<nextOffset))
                }
                offset = nextOffset
            }
            return result
        }

        static func extractUnifiedTopicPayload(_ data: Data, targetKey: String) -> Data? {
            var offset = 0
            while offset < data.count {
                guard let (fieldNum, wireType, afterTag) = decodeTag(data, offset: offset),
                      let nextOffset = skipField(data, offset: afterTag, wireType: wireType) else {
                    return nil
                }
                if fieldNum == 1 && wireType == 2,
                   let entryRange = readLengthDelimitedRange(data, offset: afterTag) {
                    let entryData = data.subdata(in: entryRange)
                    if extractFirstStringField(entryData, fieldNumber: 1) == targetKey,
                       let rowData = extractFirstBytesField(entryData, fieldNumber: 2),
                       let innerB64 = extractFirstStringField(rowData, fieldNumber: 1),
                       let decoded = Data(base64Encoded: innerB64) {
                        return decoded
                    }
                }
                offset = nextOffset
            }
            return nil
        }

        static func extractFirstBytesField(_ data: Data, fieldNumber: UInt32) -> Data? {
            var offset = 0
            while offset < data.count {
                guard let (fieldNum, wireType, afterTag) = decodeTag(data, offset: offset),
                      let nextOffset = skipField(data, offset: afterTag, wireType: wireType) else {
                    return nil
                }
                if fieldNum == fieldNumber && wireType == 2,
                   let payloadRange = readLengthDelimitedRange(data, offset: afterTag) {
                    return data.subdata(in: payloadRange)
                }
                offset = nextOffset
            }
            return nil
        }

        static func extractFirstStringField(_ data: Data, fieldNumber: UInt32) -> String? {
            guard let sub = extractFirstBytesField(data, fieldNumber: fieldNumber) else { return nil }
            return String(data: sub, encoding: .utf8)
        }
    }

    // MARK: - App & Environment Inspection

    static func inspectEnvironment(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) -> AntigravityEnvironmentSummary {
        let fm = FileManager.default
        let appCandidates = [
            "/Applications/Antigravity.app",
            "\(homeDirectory)/Applications/Antigravity.app"
        ]
        let installedAppPath = appCandidates.first { fm.fileExists(atPath: $0) }
        let appVersion = installedAppPath
            .flatMap { Bundle(path: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }

        #if canImport(AppKit)
        let isRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier || $0.localizedName == "Antigravity"
        }
        #else
        let isRunning = false
        #endif

        // Count MCP servers from ~/.gemini/antigravity/mcp_config.json or ~/.gemini/config/mcp_config.json
        let mcpCandidates = [
            "\(homeDirectory)/.gemini/antigravity/mcp_config.json",
            "\(homeDirectory)/.gemini/config/mcp_config.json"
        ]
        let mcpConfigPath = mcpCandidates.first { fm.fileExists(atPath: $0) } ?? mcpCandidates[0]
        var mcpServerCount = 0
        if let data = fm.contents(atPath: mcpConfigPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let servers = json["mcpServers"] as? [String: Any] {
            mcpServerCount = servers.count
        }

        // Count skills across ~/.gemini/antigravity/global_skills and ~/.gemini/config/skills
        let skillDirs = [
            "\(homeDirectory)/.gemini/antigravity/global_skills",
            "\(homeDirectory)/.gemini/config/skills",
            "\(homeDirectory)/.gemini/skills"
        ]
        var skillNames = Set<String>()
        for dir in skillDirs {
            if let items = try? fm.contentsOfDirectory(atPath: dir) {
                for item in items where !item.hasPrefix(".") {
                    var isDir: ObjCBool = false
                    let full = (dir as NSString).appendingPathComponent(item)
                    if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                        skillNames.insert(item)
                    }
                }
            }
        }

        // Count local brain sessions in ~/.gemini/antigravity/brain
        let brainDir = "\(homeDirectory)/.gemini/antigravity/brain"
        var brainSessionCount = 0
        if let items = try? fm.contentsOfDirectory(atPath: brainDir) {
            for item in items where !item.hasPrefix(".") {
                var isDir: ObjCBool = false
                let full = (brainDir as NSString).appendingPathComponent(item)
                if fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue {
                    brainSessionCount += 1
                }
            }
        }

        let activeCandidates = resolveActiveStorageCandidates(homeDirectory: homeDirectory)
        let activeAccountEmail = activeCandidates.first?.account.email
        let activeStoragePath = activeCandidates.first?.displayPath
            ?? (fm.fileExists(atPath: appStoragePath(homeDirectory: homeDirectory))
                ? "Keychain (gemini/antigravity)"
                : "~/Library/Application Support/Antigravity/.../state.vscdb")

        return AntigravityEnvironmentSummary(
            isAppInstalled: installedAppPath != nil,
            isAppRunning: isRunning,
            appVersion: appVersion,
            mcpServerCount: mcpServerCount,
            skillCount: skillNames.count,
            brainSessionCount: brainSessionCount,
            geminiRulesPath: "\(homeDirectory)/.gemini/GEMINI.md",
            mcpConfigPath: mcpConfigPath,
            activeAccountEmail: activeAccountEmail,
            activeStoragePath: activeStoragePath
        )
    }

    static func inspectEnvironmentAsync(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    ) async -> AntigravityEnvironmentSummary {
        await Task.detached(priority: .userInitiated) {
            inspectEnvironment(homeDirectory: homeDirectory)
        }.value
    }

    #if canImport(AppKit)
    private static func isMatchingRunningApp(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier == bundleIdentifier || app.localizedName == "Antigravity"
    }

    private static func defaultIsAntigravityRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { isMatchingRunningApp($0) && !$0.isTerminated }
    }

    private static func defaultTerminateAntigravity() -> Bool {
        let runningApps = NSWorkspace.shared.runningApplications.filter { isMatchingRunningApp($0) && !$0.isTerminated }
        for app in runningApps {
            if !app.terminate() {
                return false
            }
        }
        return true
    }

    @MainActor
    private static func defaultRelaunchAntigravity(at appURL: URL) async -> Bool {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        do {
            _ = try await NSWorkspace.shared.openApplication(at: appURL, configuration: config)
            return true
        } catch {
            return false
        }
    }

    @MainActor
    static func restartAntigravityApp(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        timeoutSeconds: TimeInterval = 6.0,
        pollIntervalMilliseconds: Int = 150,
        appExists: ((String) -> Bool)? = nil,
        isTargetRunning: (() -> Bool)? = nil,
        requestTerminate: (() -> Bool)? = nil,
        relaunchApp: ((URL) async -> Bool)? = nil
    ) async -> Bool {
        let checkAppExists = appExists ?? { FileManager.default.fileExists(atPath: $0) }
        let checkRunning = isTargetRunning ?? { defaultIsAntigravityRunning() }
        let terminateRunning = requestTerminate ?? { defaultTerminateAntigravity() }
        let relaunch = relaunchApp ?? { await defaultRelaunchAntigravity(at: $0) }

        let appCandidates = [
            "/Applications/Antigravity.app",
            "\(homeDirectory)/Applications/Antigravity.app"
        ]
        guard let appPath = appCandidates.first(where: { checkAppExists($0) }) else {
            return false
        }

        if checkRunning() {
            guard terminateRunning() else {
                return false
            }
            let deadline = Date().addingTimeInterval(timeoutSeconds)
            while Date() < deadline && checkRunning() {
                try? await Task.sleep(for: .milliseconds(pollIntervalMilliseconds))
            }
            // Do not report restart success or call openApplication while the old process still runs.
            guard !checkRunning() else {
                return false
            }
        }

        // Re-sync app_storage.json after the old Electron process has exited and before relaunching,
        // so quit-time windowState writes cannot clobber agy.onboarding.lastLoginUsername.
        if let activeEmail = detectActiveAccount(homeDirectory: homeDirectory)?.email {
            syncAppStorageFile(email: activeEmail, homeDirectory: homeDirectory)
        }

        return await relaunch(URL(fileURLWithPath: appPath))
    }
    #endif

    // MARK: - Formatting Helpers

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: value)
    }

    private static func int64Value(_ any: Any?) -> Int64? {
        switch any {
        case let v as Int64: return v
        case let v as Int: return Int64(v)
        case let v as Double: return Int64(v)
        case let v as NSNumber: return v.int64Value
        case let v as String: return Int64(v)
        default: return nil
        }
    }
}
