import Foundation
import Combine
import Darwin
import Network
import Security
import QuotaBackend

// MARK: - Quota Share (host side)
// 「共享给其他设备」：本机处于本地后端模式时，把当前已显示的额度快照只读地提供给远程模式的其它 AIUsage。
// 读取方只拿快照，不会让本机重新抓取、登录或刷新 OAuth 令牌——账号始终只在本机这一处活动。

/// 共享令牌：主机端令牌（自动生成）与客户端填写的远程令牌各存一条独立 Keychain 条目。
nonisolated enum QuotaShareTokenStore {
    enum Slot: String {
        case host = "quota-share.host-token.v1"
        case remote = "quota-share.remote-token.v1"
    }

    private static let keychainService: String = {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aiusage.desktop"
        return "\(bundleID).quotaShare"
    }()

    static func load(_ slot: Slot) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: slot.rawValue,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)?.nilIfBlank
    }

    /// 传 nil / 空串即删除该条目。
    static func save(_ value: String?, slot: Slot) {
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: slot.rawValue
        ]
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }
        let update: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        if SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            SecItemAdd(baseQuery.merging(update) { $1 } as CFDictionary, nil)
        }
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        if SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) != errSecSuccess {
            bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max) }
        }
        return "aiu-" + Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// 监听线程读取的快照：条目在主线程预先编码好，这里只按服务商过滤并拼接字节，
/// 不在后台线程触碰 MainActor 隔离的模型类型。
nonisolated final class QuotaShareSnapshotBox: @unchecked Sendable {
    struct Snapshot {
        let generatedAt: String
        let overviewJSON: Data
        let providers: [(providerId: String, json: Data)]
    }

    private let lock = NSLock()
    private var snapshot: Snapshot?

    func update(_ snapshot: Snapshot?) {
        lock.withLock { self.snapshot = snapshot }
    }

    func payload(for providerIds: [String]?) -> Data? {
        guard let snapshot = lock.withLock({ self.snapshot }) else { return nil }
        let wanted = providerIds.map(Set.init)
        let entries = snapshot.providers
            .filter { wanted?.contains($0.providerId) ?? true }
            .map(\.json)

        var body = Data("{\"generatedAt\":".utf8)
        body.append((try? JSONEncoder().encode(snapshot.generatedAt)) ?? Data("\"\"".utf8))
        body.append(Data(",\"overview\":".utf8))
        body.append(snapshot.overviewJSON)
        body.append(Data(",\"providers\":[".utf8))
        body.append(Data(entries.joined(separator: Data(",".utf8))))
        body.append(Data("]}".utf8))
        return body
    }
}

@MainActor
final class QuotaShareService: ObservableObject {
    static let shared = QuotaShareService()

    enum Status: Equatable {
        case off
        case starting
        case running(port: Int)
        case failed(message: String, portInUse: Bool)
    }

    struct ShareAddress: Identifiable, Equatable {
        enum Kind { case tailscale, lan }
        let ip: String
        let kind: Kind
        var id: String { ip }
    }

    @Published private(set) var status: Status = .off
    @Published private(set) var hostToken: String = ""
    @Published private(set) var isEncryptedTransportEnabled = false

    private let settings = AppSettings.shared
    private let refreshCoordinator = ProviderRefreshCoordinator.shared
    private let snapshotBox = QuotaShareSnapshotBox()
    private var server: QuotaShareServer?
    private var serverPort: Int?
    /// 每次重建监听器递增；旧监听器迟到的状态回调按代号丢弃，避免覆盖新状态。
    private var generation = 0
    private var cancellables = Set<AnyCancellable>()
    private var tlsOptionsProvider: () -> NWProtocolTLS.Options? = { nil }

    private init() {}

    /// 启动时调用一次：跟随设置开关 / 端口 / 后端模式启停，并在数据变化后更新快照。
    func activate() {
        guard cancellables.isEmpty else { return }

        settings.$shareQuotaEnabled
            .combineLatest(settings.$shareQuotaPort, settings.$backendMode)
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled, port, backendMode in
                self?.reconcile(enabled: enabled && backendMode == "local", port: port)
            }
            .store(in: &cancellables)

        refreshCoordinator.objectWillChange
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.updateSnapshot() }
            .store(in: &cancellables)
    }

    func regenerateToken() {
        let token = QuotaShareTokenStore.generateToken()
        QuotaShareTokenStore.save(token, slot: .host)
        hostToken = token
        restartServer()
    }

    func restartServer() {
        stopServer()
        reconcile(enabled: settings.shareQuotaEnabled && settings.backendMode == "local", port: settings.shareQuotaPort)
    }

    private func reconcile(enabled: Bool, port: Int) {
        guard enabled else {
            stopServer()
            snapshotBox.update(nil)
            isEncryptedTransportEnabled = false
            status = .off
            return
        }

        if hostToken.isEmpty {
            if let stored = QuotaShareTokenStore.load(.host) {
                hostToken = stored
            } else {
                let token = QuotaShareTokenStore.generateToken()
                QuotaShareTokenStore.save(token, slot: .host)
                hostToken = token
            }
        }
        if server != nil, serverPort == port { return }

        stopServer()
        generation += 1
        let currentGeneration = generation
        let box = snapshotBox
        let tlsOptions = tlsOptionsProvider()
        isEncryptedTransportEnabled = (tlsOptions != nil)
        let server = QuotaShareServer(port: port, token: hostToken, tlsOptions: tlsOptions) { providerIds in
            box.payload(for: providerIds)
        }
        self.server = server
        serverPort = port
        status = .starting
        updateSnapshot()
        server.start { state in
            Task { @MainActor in
                QuotaShareService.shared.applyServerState(state, generation: currentGeneration)
            }
        }
    }

    private func applyServerState(_ state: QuotaShareServer.State, generation: Int) {
        guard generation == self.generation else { return }
        switch state {
        case .stopped: status = .off
        case .starting: status = .starting
        case .running(let port): status = .running(port: port)
        case .failed(let message, let portInUse): status = .failed(message: message, portInUse: portInUse)
        }
    }

    private func stopServer() {
        generation += 1
        server?.stop()
        server = nil
        serverPort = nil
    }

    private func updateSnapshot() {
        guard server != nil else { return }
        guard refreshCoordinator.hasCompletedInitialLoad,
              let overview = refreshCoordinator.overview else {
            snapshotBox.update(nil)
            return
        }

        let encoder = JSONEncoder()
        guard let overviewJSON = try? encoder.encode(overview) else { return }
        let providers = refreshCoordinator.providers.compactMap { provider -> (providerId: String, json: Data)? in
            let entry = SharedProviderEntry(
                id: provider.id,
                providerId: provider.providerId,
                accountId: provider.accountId,
                ok: provider.status != .error,
                summary: provider
            )
            guard let json = try? encoder.encode(entry) else { return nil }
            return (provider.baseProviderId, json)
        }
        snapshotBox.update(QuotaShareSnapshotBox.Snapshot(
            generatedAt: SharedFormatters.iso8601String(from: refreshCoordinator.lastRefreshTime ?? Date()),
            overviewJSON: overviewJSON,
            providers: providers
        ))
    }

    /// 与远程端 `ProviderWrapper` 的解码格式一致。
    private struct SharedProviderEntry: Encodable {
        let id: String
        let providerId: String
        let accountId: String?
        let ok: Bool
        let summary: ProviderData
    }

    // MARK: - Addresses

    /// Addresses other devices can reach (plaintext sharing stays loopback-only; CGNAT/LAN IPs are omitted unless TLS is configured).
    static func shareAddresses(
        includePrivateLAN: Bool = false,
        includeUnverifiedCGNAT: Bool = false
    ) -> [ShareAddress] {
        guard includePrivateLAN || includeUnverifiedCGNAT else { return [] }
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var addresses: [ShareAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0,
                  let sockaddr = current.pointee.ifa_addr,
                  sockaddr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let raw = sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr }
            let bytes = withUnsafeBytes(of: raw) { Array($0) }
            let kind: ShareAddress.Kind
            switch (bytes[0], bytes[1]) {
            case (100, 64...127):
                guard includeUnverifiedCGNAT else { continue }
                kind = .tailscale
            case (10, _), (172, 16...31), (192, 168):
                guard includePrivateLAN else { continue }
                kind = .lan
            default: continue
            }
            let ip = bytes.map(String.init).joined(separator: ".")
            if !addresses.contains(where: { $0.ip == ip }) {
                addresses.append(ShareAddress(ip: ip, kind: kind))
            }
        }
        return addresses.sorted { lhs, rhs in
            if lhs.kind != rhs.kind { return lhs.kind == .tailscale }
            return lhs.ip < rhs.ip
        }
    }
}
