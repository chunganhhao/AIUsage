import Foundation

public struct CodexResetCredit: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let resetType: String
    public let status: String
    public let grantedAt: String?
    public let expiresAt: String?
    public let title: String?
    public let description: String?
    /// 只有服务端明确返回 null 才表示永久有效；缺失和坏日期都不可使用。
    public let hasExplicitUnlimitedExpiry: Bool

    enum CodingKeys: String, CodingKey {
        case id, status, title, description
        case resetType = "reset_type", grantedAt = "granted_at", expiresAt = "expires_at"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        resetType = try c.decode(String.self, forKey: .resetType)
        status = try c.decode(String.self, forKey: .status)
        grantedAt = try c.decodeIfPresent(String.self, forKey: .grantedAt)
        expiresAt = try? c.decode(String.self, forKey: .expiresAt)
        hasExplicitUnlimitedExpiry = try c.contains(.expiresAt) && c.decodeNil(forKey: .expiresAt)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        description = try c.decodeIfPresent(String.self, forKey: .description)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(resetType, forKey: .resetType)
        try c.encode(status, forKey: .status)
        try c.encodeIfPresent(grantedAt, forKey: .grantedAt)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(description, forKey: .description)
        if hasExplicitUnlimitedExpiry { try c.encodeNil(forKey: .expiresAt) }
        else { try c.encodeIfPresent(expiresAt, forKey: .expiresAt) }
    }

    public var expirationDate: Date? {
        guard let expiresAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: expiresAt) ?? ISO8601DateFormatter().date(from: expiresAt)
    }

    public func canConsume(at now: Date) -> Bool {
        !id.isEmpty && resetType == "codex_rate_limits" && status == "available"
            && (hasExplicitUnlimitedExpiry || expirationDate.map { $0 > now } == true)
    }
}

public struct CodexResetCredits: Codable, Sendable, Equatable {
    public let availableCount: Int
    public let credits: [CodexResetCredit]
    enum CodingKeys: String, CodingKey { case availableCount = "available_count", credits }

    public var sortedCredits: [CodexResetCredit] {
        credits.sorted {
            // 未知到期信息也不能伪装成永久有效。
            let a = $0.expirationDate ?? ($0.hasExplicitUnlimitedExpiry ? .distantFuture : Date.distantFuture.addingTimeInterval(-1))
            let b = $1.expirationDate ?? ($1.hasExplicitUnlimitedExpiry ? .distantFuture : Date.distantFuture.addingTimeInterval(-1))
            return a == b ? $0.id < $1.id : a < b
        }
    }
}

public struct CodexResetConsumeOutcome: Codable, Sendable, Equatable {
    public enum Code: String, Codable, Sendable { case reset, nothingToReset = "nothing_to_reset", noCredit = "no_credit", alreadyRedeemed = "already_redeemed" }
    public let code: Code
    public let windowsReset: Int?
    enum CodingKeys: String, CodingKey { case code, windowsReset = "windows_reset" }
}

/// 同一原生账号的操作共用锁；未知写入结果的 ID 落盘后才能发送。
public actor CodexResetCreditsOperations {
    private let provider: CodexProvider
    private let journalURL: URL
    private var consuming: Set<String> = []
    private var lists: [String: Task<CodexResetCredits, Error>] = [:]
    private var pending: [String: UUID]?

    public init(journalURL: URL, provider: CodexProvider = CodexProvider()) {
        self.journalURL = journalURL
        self.provider = provider
    }

    public func list(credential: AccountCredential, identity: CodexAccountIdentity) async throws -> CodexResetCredits {
        guard let key = identity.nativeKey else { throw ProviderError("reset_read_only", "Native account identity is required.") }
        if let task = lists[key] { return try await task.value }
        let task = Task { try await provider.fetchResetCredits(with: credential, identity: identity) }
        lists[key] = task
        defer { lists.removeValue(forKey: key) }
        return try await task.value
    }

    public func consume(credential: AccountCredential, identity: CodexAccountIdentity, creditID: String) async throws -> CodexResetConsumeOutcome {
        try Task.checkCancellation()
        guard let key = identity.nativeKey else { throw ProviderError("reset_read_only", "Native account identity is required.") }
        guard consuming.insert(key).inserted else { throw ProviderError("reset_busy", "This account already has a reset in progress.") }
        defer { consuming.remove(key) }
        // 不能复用打开弹窗时的明细：确认后再读一次，且在任何 await 前占用账号。
        let context = try await provider.resetCreditsContext(with: credential, identity: identity)
        guard context.list.credits.filter({ $0.id == creditID }).count == 1,
              let card = context.list.credits.first(where: { $0.id == creditID }), card.canConsume(at: Date()) else {
            throw ProviderError("reset_card_unavailable", "The selected reset card is no longer available.")
        }
        let path = NSString(string: credential.credential).expandingTildeInPath
        try provider.validateResetIdentity(provider.loadCredentials(from: path), identity: identity)
        try Task.checkCancellation()
        let journalKey = key + ":credit:" + creditID
        let requestID = try requestID(for: journalKey)
        let outcome = try await provider.submitResetCredit(creds: context.creds, creditID: creditID, requestID: requestID)
        pending?.removeValue(forKey: journalKey)
        // 已知服务端结果必须保留；清理失败只会让下次仍使用安全的旧 ID。
        try? saveJournal()
        return outcome
    }

    private func requestID(for key: String) throws -> UUID {
        do {
            if pending == nil {
                pending = FileManager.default.fileExists(atPath: journalURL.path)
                    ? try JSONDecoder().decode([String: UUID].self, from: Data(contentsOf: journalURL)) : [:]
            }
            if let existing = pending?[key] { return existing }
            let id = UUID()
            pending?[key] = id
            try saveJournal()
            return id
        } catch {
            // 内存记录也不能绕过失败的持久化。
            pending = nil
            throw ProviderError("reset_journal_failed", "Unable to save the reset request identifier. No card was submitted.")
        }
    }

    private func saveJournal() throws {
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(pending ?? [:]).write(to: journalURL, options: .atomic)
    }
}
