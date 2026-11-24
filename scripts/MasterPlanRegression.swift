import AppKit
import Darwin
import Darwin.membership
import Foundation
import SQLite3
import SwiftUI
@testable import QuotaBackend

private var assertions = 0
private func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    assertions += 1
    if try !value() { throw AgentMCPStore.Failure.invalid("Assertion failed: \(message)") }
}
private func checkExternalPriorityWarning(_ operation: () throws -> Void) throws {
    var message: String?
    do { try operation() } catch { message = error.localizedDescription }
    try check(message?.contains("excluded from weekly routing") == true, "external override is not silently excluded")
    try check(message?.contains("can change relative account order") == true, "warning explains Off ordering risk")
}
private func write(_ value: String, _ file: URL) throws {
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(value.utf8).write(to: file)
}
private func object(_ file: URL) throws -> [String: Any] { try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any] }
private final class Vault {
    var values: [String: String] = [:]
    var service: MCPSecretVault { .init(put: { self.values[$0] = $1 }, get: { self.values[$0] }, delete: { self.values.removeValue(forKey: $0) }) }
}
private actor Attempts {
    var ids: [String] = []
    func add(_ value: String) { ids.append(value) }
    func count() -> Int { ids.count }
}

@main struct MasterPlanRegression {
    static func main() async throws {
        let fixtureBase = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TokenSaverSettingsStore.resolvedTemporaryDirectory()
        try FileManager.default.createDirectory(at: fixtureBase, withIntermediateDirectories: true)
        let root = fixtureBase.resolvingSymlinksInPath().appendingPathComponent("aiusage-master-regression-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await analytics(root.appendingPathComponent("analytics"))
        try poolProtection(root.appendingPathComponent("pools"))
        try rtk(root.appendingPathComponent("rtk"))
        try env(root.appendingPathComponent("env"))
        try mcp(root.appendingPathComponent("mcp"))
        try priority(root.appendingPathComponent("priority"))
        try burnRate()
        try await catalogSyncAndQuotaShare()
        try await warmup(root.appendingPathComponent("warmup"))
        try await reviewRegressions(root.appendingPathComponent("review"))
        print("Master plan regression: \(assertions) assertions passed; temporary homes, fake vault, no paid requests")
    }

    static func catalogSyncAndQuotaShare() async throws {
        let catalog = CatalogSyncFixture()
        try check(catalog.sync(upstream: ["existing"], existing: ["existing"], save: { true }).isEmpty,
                  "first catalog sync records the baseline")
        let upstream = ["existing", "new"]
        try check(catalog.sync(upstream: upstream, existing: ["existing"], save: { false }) == ["new"],
                  "new model is detected before failed catalog save")
        try check(catalog.sync(upstream: upstream, existing: ["existing"], save: { true }) == ["new"],
                  "failed catalog save leaves new model eligible for retry")
        try check(catalog.sync(upstream: upstream, existing: ["existing"], save: { true }).isEmpty,
                  "successfully saved model is now known to the baseline")

        let oldHost = "100.64.1.2"
        let https = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://mini.example.test/", savedHost: oldHost, savedPort: 4318, portInput: "4318"
        )
        try check(AppSettingsAddressFixture.remoteBaseURL(host: https.host, port: https.port) == "https://mini.example.test:443",
                  "pasted HTTPS URL defaults to 443, not the previous HTTP port")
        let explicit = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://mini.example.test:8443", savedHost: oldHost, savedPort: 4318, portInput: "9443"
        )
        try check(explicit.port == 8443, "pasted explicit HTTPS port wins")
        let reapplied = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            explicit.host, savedHost: explicit.host, savedPort: explicit.port, portInput: "\(explicit.port)"
        )
        try check(reapplied.port == 8443, "reapplying normalized settings preserves the custom port")
        let trailingSlash = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://mini.example.test/", savedHost: "https://mini.example.test", savedPort: 8443, portInput: "8443"
        )
        try check(trailingSlash.port == 8443, "equivalent HTTPS URL with trailing slash preserves custom port")
        let ipv6Bracket = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fd7a::1]", savedHost: "https://fd7a::1", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6Bracket.port == 8443 && AppSettingsAddressFixture.remoteBaseURL(host: ipv6Bracket.host, port: ipv6Bracket.port) == "https://[fd7a::1]:8443",
                  "equivalent bracketed IPv6 HTTPS URL preserves custom port")
        let ipv6Expanded = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            " HTTPS://[FD7A:0:0:0:0:0:0:1]/ ", savedHost: "https://fd7a::1", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6Expanded.port == 8443, "equivalent expanded IPv6 HTTPS URL preserves custom port")
        let ipv6LoopbackExpanded = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[0:0:0:0:0:0:0:1]/", savedHost: "https://::1", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6LoopbackExpanded.port == 8443, "equivalent expanded loopback IPv6 HTTPS URL preserves custom port")
        let ipv6ZoneMatch = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80:0:0:0:0:0:0:1%en0]/", savedHost: "https://fe80::1%en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6ZoneMatch.port == 8443, "equivalent zone-scoped IPv6 HTTPS URL preserves custom port")
        let ipv6EncodedZoneMatch = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80::1%25en0]", savedHost: "https://fe80::1%en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6EncodedZoneMatch.host == "https://fe80::1%en0" && ipv6EncodedZoneMatch.port == 8443,
                  "RFC 6874 %25-encoded zone URL normalizes zone ID and preserves custom port")
        let ipv6ReverseEncodedZone = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80:0:0:0:0:0:0:1%en0]/", savedHost: "https://fe80::1%25en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6ReverseEncodedZone.port == 8443,
                  "saved RFC 6874 %25-encoded host matches unencoded expanded IPv6 zone and preserves custom port")
        try check(AppSettingsAddressFixture.remoteHostsMatch("[fe80::1%25en0]", "fe80:0:0:0:0:0:0:1%en0"),
                  "remoteHostsMatch treats RFC 6874 %25en0 and %en0 on equivalent IPv6 literals as equal")
        let ipv6EncodedZoneCaseMismatch = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80::1%25EN0]/", savedHost: "https://fe80::1%en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6EncodedZoneCaseMismatch.port == 443,
                  "different-case RFC 6874 %25-encoded IPv6 zone ID treats endpoint as changed")
        let ipv6EmptyEncodedZone = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80::1%25]/", savedHost: "https://fe80::1%25", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6EmptyEncodedZone.port == 443
                    && !AppSettingsAddressFixture.remoteHostsMatch("fe80::1%25", "fe80::1%25"),
                  "empty RFC 6874 %25 zone delimiter never matches")
        try check(!AppSettingsAddressFixture.remoteHostsMatch("fe80::1%25%zz", "fe80::1%25%zz"),
                  "malformed percent-encoded IPv6 zone ID never matches")
        let ipv6HexPrefixZone = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80:0:0:0:0:0:0:1%25de0]/", savedHost: "https://fe80::1%de0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6HexPrefixZone.port == 8443
                    && AppSettingsAddressFixture.remoteHostsMatch("fe80::1%de0", "fe80:0:0:0:0:0:0:1%25de0"),
                  "unencoded %de0 zone stays intact and matches RFC 6874 %25de0")
        let ipv6ZoneCaseCompressed = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80::1%EN0]/", savedHost: "https://fe80::1%en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6ZoneCaseCompressed.port == 443, "different-case IPv6 zone ID on compressed host treats endpoint as changed")
        let ipv6ZoneCaseExpanded = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80:0:0:0:0:0:0:1%EN0]/", savedHost: "https://fe80::1%en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6ZoneCaseExpanded.port == 443, "different-case IPv6 zone ID on expanded host treats endpoint as changed")
        let ipv6TrailingEmptyZone = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80::1%]/", savedHost: "https://fe80::1%", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6TrailingEmptyZone.port == 443, "empty trailing IPv6 zone delimiter is never treated as matching")
        let ipv6ZoneMismatch = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fe80::1%en1]/", savedHost: "https://fe80::1%en0", savedPort: 8443, portInput: "8443"
        )
        try check(ipv6ZoneMismatch.port == 443, "mismatched IPv6 zone ID treats endpoint as changed")
        let ipv6Upgrade = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://[fd7a::1]/", savedHost: "fd7a:0:0:0:0:0:0:1", savedPort: 4318, portInput: "4318"
        )
        try check(ipv6Upgrade.port == 443, "equivalent IPv6 hosts do not override an HTTPS upgrade")
        let httpToHTTPS = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://mini.example.test", savedHost: "mini.example.test", savedPort: 4318, portInput: "4318"
        )
        try check(httpToHTTPS.port == 443, "upgrading same host from HTTP to HTTPS still defaults to 443")
        let editedPort = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "https://mini.example.test", savedHost: oldHost, savedPort: 4318, portInput: "9443"
        )
        try check(editedPort.port == 9443, "an edited port field overrides the HTTPS default")
        let http = AppSettingsAddressFixture.resolveRemoteSettingsAddress(
            "127.0.0.1", savedHost: oldHost, savedPort: 4318, portInput: "4319"
        )
        try check(AppSettingsAddressFixture.remoteBaseURL(host: http.host, port: http.port) == "http://127.0.0.1:4319",
                  "loopback HTTP still uses the configured port")

        // Finding #1: Quota Share client never attaches Authorization over plaintext non-loopback HTTP or redirects
        final class RecordedRequests: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [URLRequest] = []
            func append(_ req: URLRequest) { lock.withLock { items.append(req) } }
            func snapshot() -> [URLRequest] { lock.withLock { items } }
            func clear() { lock.withLock { items.removeAll() } }
        }
        let sentRequests = RecordedRequests()
        let healthData = Data(#"{"ok":true,"generatedAt":"2026-11-22T00:00:00Z"}"#.utf8)
        let dashboardData = Data(#"{"providers":[]}"#.utf8)
        for badURL in [
            "http://100.64.1.2:4318",
            "http://192.168.1.10:4318",
            "http://stats.example.test:4318",
            "http://localhost:4318",
        ] {
            sentRequests.clear()
            let client = await MainActor.run {
                APIService(baseURL: badURL, accessToken: "aiu-fixture-secret") { req in
                    sentRequests.append(req)
                    return (healthData, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }
            var threwInsecure = false
            do {
                _ = try await client.checkHealth()
            } catch APIError.insecureTransport {
                threwInsecure = true
            }
            try check(threwInsecure && sentRequests.snapshot().isEmpty, "reject plaintext non-loopback \(badURL) before transport")
        }

        for okURL in [
            ("http://127.0.0.1:4318", "/api/dashboard", dashboardData),
            ("http://[::1]:4318", "/api/dashboard", dashboardData),
            ("http://[::ffff:127.0.0.1]:4318", "/api/dashboard", dashboardData),
            ("https://stats.example.test:8443", "/api/dashboard", dashboardData),
        ] {
            sentRequests.clear()
            let client = await MainActor.run {
                APIService(baseURL: okURL.0, accessToken: "aiu-fixture-secret") { req in
                    sentRequests.append(req)
                    return (okURL.2, HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            }
            _ = try await client.fetchDashboard()
            let captured = sentRequests.snapshot()
            try check(captured.count == 1
                        && captured[0].value(forHTTPHeaderField: "Authorization") == "Bearer aiu-fixture-secret",
                      "allowed transport \(okURL.0) sends Bearer token")
        }

        // Cross-origin / downgrade response URL or 3xx blocked redirect fails closed
        let downgradedClient = await MainActor.run {
            APIService(baseURL: "https://stats.example.test:8443", accessToken: "aiu-fixture-secret") { req in
                let wrongOrigin = URL(string: "http://stats.example.test:80/api/dashboard")!
                return (dashboardData, HTTPURLResponse(url: wrongOrigin, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        var caughtDowngrade = false
        do { _ = try await downgradedClient.fetchDashboard() } catch APIError.insecureTransport { caughtDowngrade = true }
        try check(caughtDowngrade, "response with mismatched origin rejects before decoding")

        let redirect302Client = await MainActor.run {
            APIService(baseURL: "https://stats.example.test:8443", accessToken: "aiu-fixture-secret") { req in
                return (Data(), HTTPURLResponse(url: req.url!, statusCode: 302, httpVersion: nil, headerFields: ["Location": "http://100.64.1.2/leak"])!)
            }
        }
        var caught302 = false
        do { _ = try await redirect302Client.fetchDashboard() } catch APIError.insecureTransport { caught302 = true }
        try check(caught302, "blocked 3xx redirect surfaces insecureTransport error")

        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "https://stats.example.test:443/health"),
            to: URL(string: "http://stats.example.test:443/health")
        ), "redirect downgrading https to http is blocked")
        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "https://stats.example.test:443/health"),
            to: URL(string: "https://evil.example.test:443/health")
        ), "cross-host redirect is blocked")
        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "https://stats.example.test:443/health"),
            to: URL(string: "https://stats.example.test:8443/health")
        ), "cross-port redirect is blocked")
        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "http://127.0.0.1:4318/health"),
            to: URL(string: "http://100.64.1.2:4318/health")
        ), "loopback-to-non-loopback HTTP redirect is blocked")
        try check(APIService.shouldFollowRedirect(
            from: URL(string: "https://stats.example.test:443/health"),
            to: URL(string: "https://stats.example.test/health/")
        ), "same-origin HTTPS redirect with implicit 443 is allowed")
        try check(APIService.shouldFollowRedirect(
            from: URL(string: "https://[fd7a:0:0:0:0:0:0:1]:8443/api/dashboard"),
            to: URL(string: "https://[fd7a::1]:8443/api/dashboard")
        ), "same-origin HTTPS redirect across equivalent IPv6 spellings is allowed")
        try check(APIService.shouldFollowRedirect(
            from: URL(string: "http://[0:0:0:0:0:0:0:1]:4318/health"),
            to: URL(string: "http://[::1]:4318/health")
        ), "same-origin loopback HTTP redirect across equivalent IPv6 spellings is allowed")
        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "https://[fd7a::1]:8443/health"),
            to: URL(string: "https://[fd7a::2]:8443/health")
        ), "cross-host IPv6 redirect is blocked")
        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "https://[fe80::1%25en0]:8443/health"),
            to: URL(string: "https://[fe80::1%25en1]:8443/health")
        ), "cross-zone IPv6 redirect is blocked")
        try check(!APIService.shouldFollowRedirect(
            from: URL(string: "https://[fe80::1%25en0]:8443/health"),
            to: URL(string: "https://[fe80::1%25EN0]:8443/health")
        ), "case-mismatched IPv6 zone redirect is blocked")
        let ipv6CanonicalClient = await MainActor.run {
            APIService(baseURL: "https://[fd7a:0:0:0:0:0:0:1]:8443", accessToken: "aiu-fixture-secret") { _ in
                let compressedURL = URL(string: "https://[fd7a::1]:8443/api/dashboard")!
                return (dashboardData, HTTPURLResponse(url: compressedURL, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
        }
        let ipv6Dashboard = try await ipv6CanonicalClient.fetchDashboard()
        try check(ipv6Dashboard.providers.isEmpty, "APIService accepts canonicalized same-address IPv6 final response URL")

        // Finding #2 & #3: Child propagation errors, unchanged-master reconciliation, and hidden OpenCode isolation
        await MainActor.run {
            OpenCodeNodeStore.resetForTest()
            APIProviderStore.shared.providers.removeAll()
            ProxyViewModel.shared.profiles.removeAll()
            ProxyViewModel.shared.failingIDs.removeAll()
            ProxyViewModel.shared.updateCalls.removeAll()
            AppSettings.shared.hiddenSidebarSections = [AppSection.opencodeManagement.rawValue]
        }
        let masterID = "prov-1"
        await MainActor.run {
            APIProviderStore.shared.providers[masterID] = APIProvider(
                id: masterID,
                models: [.init(name: "m1")]
            )
            ProxyViewModel.shared.profiles["codex-child"] = NodeProfile(
                metadata: .init(
                    id: "codex-child",
                    nodeType: .codexProxy,
                    linkedProviderId: masterID,
                    proxy: .init(modelCatalog: .init(models: ["m1"]))
                )
            )
            ProxyViewModel.shared.profiles["claude-child"] = NodeProfile(
                metadata: .init(
                    id: "claude-child",
                    nodeType: .anthropicDirect,
                    linkedProviderId: masterID,
                    proxy: .init(modelCatalog: .init(models: ["m1"]))
                )
            )
            ProxyViewModel.shared.failingIDs = ["codex-child"]
        }
        let harness = await MainActor.run { ModelSyncHarness() }
        // First sync establishes baseline ["m1"] while OpenCode is hidden
        await MainActor.run { harness.nextUpstreamModels = ["m1"] }
        _ = await harness.runProviderSync(masterID)
        let initCountWhileHidden = await MainActor.run { OpenCodeNodeStore.initCount }
        try check(initCountWhileHidden == 0, "hidden OpenCode is never initialized during background sync")

        // Round 1: upstream adds m2; master saves, claude saves, codex fails
        await MainActor.run { harness.nextUpstreamModels = ["m1", "m2"] }
        let failReport = await harness.runProviderSync(masterID)
        let failFlash = await MainActor.run { harness.flash(for: failReport, failures: 1, subject: "Master") }
        let claudeModelsAfterFail = await MainActor.run { ProxyViewModel.shared.profiles["claude-child"]?.metadata.proxy.modelCatalog.models ?? [] }
        let codexModelsAfterFail = await MainActor.run { ProxyViewModel.shared.profiles["codex-child"]?.metadata.proxy.modelCatalog.models ?? [] }
        try check(failReport.error != nil && failFlash.kind == .error,
                  "child catalog save failure surfaces error report and error flash even when master added models")
        try check(claudeModelsAfterFail == ["m1", "m2"] && codexModelsAfterFail == ["m1"],
                  "healthy sibling keeps saved models while failing child preserves prior catalog")

        // Round 2: master unchanged (m1, m2), codex save recovers
        await MainActor.run {
            ProxyViewModel.shared.failingIDs.removeAll()
            ProxyViewModel.shared.updateCalls.removeAll()
        }
        let retryReport = await harness.runProviderSync(masterID)
        let codexModelsAfterRetry = await MainActor.run { ProxyViewModel.shared.profiles["codex-child"]?.metadata.proxy.modelCatalog.models ?? [] }
        let callsOnRetry = await MainActor.run { ProxyViewModel.shared.updateCalls }
        try check(retryReport.error == nil && codexModelsAfterRetry == ["m1", "m2"] && callsOnRetry == ["codex-child"],
                  "retry with unchanged master heals only the drifted child without rewriting healthy sibling")

        // Round 3: un-hide OpenCode with failing disk write, verify no memory mutation/reapply, then recover
        await MainActor.run {
            AppSettings.shared.hiddenSidebarSections.remove(AppSection.opencodeManagement.rawValue)
            OpenCodeNodeStore.shared.nodes = [
                OpenCodeNode(id: "oc-child", linkedProviderId: masterID, modelEntries: [.init(id: "m1")])
            ]
            OpenCodeNodeStore.shared.failingIDs = ["oc-child"]
        }
        let ocFailReport = await harness.runProviderSync(masterID)
        let ocStateAfterFail = await MainActor.run {
            (OpenCodeNodeStore.shared.nodes[0].modelEntries.map(\.id), OpenCodeNodeStore.shared.reapplyCount)
        }
        try check(ocFailReport.error != nil && ocStateAfterFail.0 == ["m1"] && ocStateAfterFail.1 == 0,
                  "failed OpenCode catalog propagation reports error without mutating memory or scheduling reapply")

        await MainActor.run { OpenCodeNodeStore.shared.failingIDs.removeAll() }
        let ocRetryReport = await harness.runProviderSync(masterID)
        let ocStateAfterRetry = await MainActor.run {
            (OpenCodeNodeStore.shared.nodes[0].modelEntries.map(\.id), OpenCodeNodeStore.shared.reapplyCount)
        }
        try check(ocRetryReport.error == nil && ocStateAfterRetry.0 == ["m1", "m2"] && ocStateAfterRetry.1 == 1,
                  "OpenCode child heals on next sync even when master provider did not change")

        // Round 4 (Codex Round-2 race): Hide OpenCode while propagateCatalog waits on withProviderSerialization lock
        @MainActor
        final class ProviderLockGate {
            private var acquiredCont: CheckedContinuation<Void, Never>?
            private var releaseCont: CheckedContinuation<Void, Never>?
            private var didAcquire = false
            private var didRelease = false

            func signalAcquired() {
                didAcquire = true
                acquiredCont?.resume()
                acquiredCont = nil
            }
            func waitAcquired() async {
                if didAcquire { return }
                await withCheckedContinuation { acquiredCont = $0 }
            }
            func waitRelease() async {
                if didRelease { return }
                await withCheckedContinuation { releaseCont = $0 }
            }
            func release() {
                didRelease = true
                releaseCont?.resume()
                releaseCont = nil
            }
        }
        let lockGate = await MainActor.run {
            OpenCodeNodeStore.shared.saveCalls = 0
            OpenCodeNodeStore.shared.reapplyCount = 0
            harness.nextUpstreamModels = ["m1", "m2", "m3"]
            return ProviderLockGate()
        }
        let lockHolder = Task { @MainActor in
            await APIProviderDistributor.shared.holdProviderLock(
                for: masterID,
                onAcquired: { lockGate.signalAcquired() },
                waitRelease: { await lockGate.waitRelease() }
            )
        }
        await lockGate.waitAcquired()
        let queuedSync = Task { @MainActor in
            await harness.runProviderSync(masterID)
        }
        while !(await MainActor.run { APIProviderDistributor.shared.hasWaiter(for: masterID) }) {
            await Task.yield()
        }
        await MainActor.run {
            AppSettings.shared.hiddenSidebarSections = [AppSection.opencodeManagement.rawValue]
            lockGate.release()
        }
        await lockHolder.value
        let queuedReport = await queuedSync.value
        let ocStateDuringHiddenRace = await MainActor.run {
            (
                OpenCodeNodeStore.shared.saveCalls,
                OpenCodeNodeStore.shared.reapplyCount,
                OpenCodeNodeStore.shared.nodes[0].modelEntries.map(\.id),
                ProxyViewModel.shared.profiles["codex-child"]?.metadata.proxy.modelCatalog.models ?? [],
                ProxyViewModel.shared.profiles["claude-child"]?.metadata.proxy.modelCatalog.models ?? []
            )
        }
        try check(queuedReport.error == nil
                    && ocStateDuringHiddenRace.0 == 0
                    && ocStateDuringHiddenRace.1 == 0
                    && ocStateDuringHiddenRace.2 == ["m1", "m2"]
                    && ocStateDuringHiddenRace.3 == ["m1", "m2", "m3"]
                    && ocStateDuringHiddenRace.4 == ["m1", "m2", "m3"],
                  "hiding OpenCode while propagateCatalog waits for lock skips OpenCode writes and reapply")

        await MainActor.run {
            _ = AppSettings.shared.hiddenSidebarSections.remove(AppSection.opencodeManagement.rawValue)
        }
        let catchUpReport = await harness.runProviderSync(masterID)
        let ocStateAfterCatchUp = await MainActor.run {
            (
                OpenCodeNodeStore.shared.saveCalls,
                OpenCodeNodeStore.shared.reapplyCount,
                OpenCodeNodeStore.shared.nodes[0].modelEntries.map(\.id)
            )
        }
        try check(catchUpReport.error == nil
                    && ocStateAfterCatchUp.0 == 1
                    && ocStateAfterCatchUp.1 == 1
                    && ocStateAfterCatchUp.2 == ["m1", "m2", "m3"],
                  "un-hiding OpenCode heals queued-race skipped child on next sync")

        // Round 5 (Codex Round-2 race): Standalone syncOpenCode re-checks visibility after upstream fetch
        await MainActor.run {
            OpenCodeNodeStore.shared.nodes = [
                OpenCodeNode(id: "oc-standalone", linkedProviderId: nil, modelEntries: [.init(id: "m1")])
            ]
            OpenCodeNodeStore.shared.saveCalls = 0
            OpenCodeNodeStore.shared.reapplyCount = 0
            harness.nextUpstreamModels = ["m1"]
            harness.onFetchUpstream = nil
        }
        let baselineOC = await harness.runOpenCodeSync("oc-standalone")
        try check(baselineOC.error == nil && baselineOC.addedModels.isEmpty && baselineOC.baselineRecorded == 1,
                  "standalone OpenCode baseline established while visible")

        await MainActor.run {
            OpenCodeNodeStore.shared.saveCalls = 0
            OpenCodeNodeStore.shared.reapplyCount = 0
            harness.nextUpstreamModels = ["m1", "m2"]
            harness.onFetchUpstream = {
                AppSettings.shared.hiddenSidebarSections = [AppSection.opencodeManagement.rawValue]
            }
        }
        let hiddenMidFetchOC = await harness.runOpenCodeSync("oc-standalone")
        let midFetchState = await MainActor.run {
            (
                OpenCodeNodeStore.shared.saveCalls,
                OpenCodeNodeStore.shared.reapplyCount,
                OpenCodeNodeStore.shared.nodes[0].modelEntries.map(\.id)
            )
        }
        try check(hiddenMidFetchOC.error == nil
                    && hiddenMidFetchOC.addedModels.isEmpty
                    && midFetchState.0 == 0
                    && midFetchState.1 == 0
                    && midFetchState.2 == ["m1"],
                  "hiding OpenCode mid-fetch aborts syncOpenCode before reading/saving or committing baseline")

        await MainActor.run {
            harness.onFetchUpstream = nil
            _ = AppSettings.shared.hiddenSidebarSections.remove(AppSection.opencodeManagement.rawValue)
        }
        let resumedOC = await harness.runOpenCodeSync("oc-standalone")
        let resumedOCState = await MainActor.run {
            (
                OpenCodeNodeStore.shared.saveCalls,
                OpenCodeNodeStore.shared.reapplyCount,
                OpenCodeNodeStore.shared.nodes[0].modelEntries.map(\.id)
            )
        }
        try check(resumedOC.error == nil
                    && resumedOC.addedModels == ["m2"]
                    && resumedOCState.0 == 1
                    && resumedOCState.1 == 1
                    && resumedOCState.2 == ["m1", "m2"],
                  "un-hiding OpenCode picks up m2 on next sync because aborted run did not commit baseline")

        // Round 6: Hidden OpenCode before syncOpenCode skips both upstream fetch and OpenCodeNodeStore init
        await MainActor.run {
            OpenCodeNodeStore.resetForTest()
            AppSettings.shared.hiddenSidebarSections = [AppSection.opencodeManagement.rawValue]
            harness.onFetchUpstream = { preconditionFailure("hidden syncOpenCode must not fetch upstream") }
        }
        let preHiddenOC = await harness.runOpenCodeSync("oc-standalone")
        let preHiddenInitCount = await MainActor.run {
            harness.onFetchUpstream = nil
            return OpenCodeNodeStore.initCount
        }
        try check(preHiddenOC.error == nil && preHiddenOC.addedModels.isEmpty && preHiddenInitCount == 0,
                  "already-hidden OpenCode skips both upstream fetch and OpenCodeNodeStore initialization")

        // Finding #6: ShimmerModifier gradient stops stay strictly ordered within 0...1 across animation phases
        let stopLocations = ShimmerRegressionProbe.stops.map(\.location)
        try check(stopLocations == [0, 0.5, 1] && zip(stopLocations, stopLocations.dropFirst()).allSatisfy(<),
                  "ShimmerModifier stops are strictly ordered inside 0...1")
        for phase in [-1.0, 0.0, 0.5, 2.0] as [CGFloat] {
            let pts = ShimmerRegressionProbe.points(for: phase)
            try check(pts.start.x < pts.end.x && pts.start.y < pts.end.y,
                      "ShimmerModifier gradient sweeps monotonically at phase \(phase)")
        }
    }
    static func archiveRescanMetrics(_ home: URL) throws {
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        let pastDay = "2026-11-10"
        let today = "2026-11-11"
        let archived = CallAnalyticsEntry(
            source: .codex, kind: .mcp, name: "docs/search", server: "docs", dayKey: pastDay, count: 2,
            outcomeKnownCount: 2, successCount: 0, durationSampleCount: 2, durationMsTotal: 1050
        )
        let rescanned = CallAnalyticsEntry(
            source: .codex, kind: .mcp, name: "docs/search", server: "docs", dayKey: pastDay, count: 3,
            outcomeKnownCount: 1, successCount: 1, durationSampleCount: 3, durationMsTotal: 150
        )
        try check(archived.avgDurationMs == 525 && rescanned.avgDurationMs == 50, "partial rescan duration fixture")
        _ = archive.freeze(computed: [pastDay: .init(entries: [archived], agentInvocations: [])],
                           todayKey: today, completedFullHistory: true)
        let merged = archive.freeze(computed: [pastDay: .init(entries: [rescanned], agentInvocations: [])],
                                    todayKey: today, completedFullHistory: true, backfill: true)[pastDay]?.entries.first
        try check(merged?.count == 3, "partial rescan keeps the existing count merge")
        try check(merged?.avgDurationMs == 50 && merged?.durationSampleCount == 3,
                  "use the better-sampled 50 ms rescan; without call IDs the 287.5 ms union cannot be reconstructed")
        try check(merged?.outcomeKnownCount == 2 && merged?.successRate == 0,
                  "keep both archived outcome values when the archive has better coverage")

        // Finding #4: Equal-sample tie with partial (fewer total calls) rescan keeps archived metrics
        let tieArchive = CallAnalyticsArchiveStore(homeDirectory: home.appendingPathComponent("tie").path)
        let fullDay = CallAnalyticsEntry(
            source: .codex, kind: .mcp, name: "docs/search", server: "docs", dayKey: pastDay, count: 5,
            outcomeKnownCount: 2, successCount: 2, durationSampleCount: 2, durationMsTotal: 1000
        )
        let partialTie = CallAnalyticsEntry(
            source: .codex, kind: .mcp, name: "docs/search", server: "docs", dayKey: pastDay, count: 3,
            outcomeKnownCount: 2, successCount: 0, durationSampleCount: 2, durationMsTotal: 80
        )
        _ = tieArchive.freeze(computed: [pastDay: .init(entries: [fullDay], agentInvocations: [])],
                              todayKey: today, completedFullHistory: true)
        let tieMerged = tieArchive.freeze(computed: [pastDay: .init(entries: [partialTie], agentInvocations: [])],
                                          todayKey: today, completedFullHistory: true, backfill: true)[pastDay]?.entries.first
        try check(tieMerged?.count == 5 && tieMerged?.successRate == 1.0 && tieMerged?.avgDurationMs == 500,
                  "equal sample count with fewer rescanned calls retains archived outcome and duration")

        let largerTie = CallAnalyticsEntry(
            source: .codex, kind: .mcp, name: "docs/search", server: "docs", dayKey: pastDay, count: 6,
            outcomeKnownCount: 2, successCount: 1, durationSampleCount: 2, durationMsTotal: 300
        )
        let largerMerged = tieArchive.freeze(computed: [pastDay: .init(entries: [largerTie], agentInvocations: [])],
                                             todayKey: today, completedFullHistory: true, backfill: true)[pastDay]?.entries.first
        try check(largerMerged?.count == 6 && largerMerged?.successRate == 0.5 && largerMerged?.avgDurationMs == 150,
                  "equal sample count with strictly more rescanned calls accepts the new metrics")
    }

    static func analytics(_ home: URL) async throws {
        let actual = home.appendingPathComponent("archive")
        let sessions = home.appendingPathComponent(".codex/sessions")
        try write(#"{"timestamp":"2026-11-10T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}"# + "\n", actual.appendingPathComponent("day/session.jsonl"))
        try FileManager.default.createDirectory(at: sessions.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: sessions, withDestinationURL: actual)
        let source = CodexCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        try check(source.collect(cutoff: nil).status.filesScanned == 1, "Codex follows root symlink")
        try check(source.collect(cutoff: nil).status.eventCount > 0, "Codex parses linked history")
        let transcript = home.appendingPathComponent(".gemini/antigravity/brain/demo/.system_generated/logs/transcript.jsonl")
        let row = #"{"step_index":1,"created_at":"2026-11-10T03:00:00Z","tool_calls":[{"name":"view_file","args":{"AbsolutePath":"\"/skills/demo/SKILL.md\""}},{"name":"call_mcp_tool","args":{"ServerName":"\"docs\"","ToolName":"\"search\""}}]}"#
        try write(row + "\n" + row + "\n", transcript)
        let agy = AntigravityCallEventSource(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!).collect()
        try check(agy.entries.first(where: { $0.kind == .skill })?.count == 1, "AGY explicit skill reads deduplicated")
        try check(agy.entries.first(where: { $0.kind == .mcp })?.name == "docs/search", "AGY MCP server mapping")
        let archive = CallAnalyticsArchiveStore(homeDirectory: home.path)
        _ = archive.freeze(computed: [:], todayKey: "2026-11-11", completedFullHistory: true)
        let engine = CallAnalyticsEngine(homeDirectory: home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let recovered = await engine.computeSnapshot(rangeKey: "all", cutoff: nil)
        try check(recovered.entries.contains(where: { $0.source == .codex }), "poisoned empty import self-recovers")
        try check(recovered.entries.contains(where: { $0.source == .antigravity }), "visible Antigravity contributes calls")
        let excluded = AgentVisibility.hiddenCallSources(hidden: [AppSection.antigravityManagement.rawValue])
        try check(excluded == [.antigravity], "hiding Antigravity excludes just its call source")
        let hidden = await engine.computeSnapshot(rangeKey: "all", cutoff: nil, excludedSources: excluded)
        try check(!hidden.entries.contains(where: { $0.source == .antigravity })
                    && !hidden.sources.contains(where: { $0.source == .antigravity }),
                  "hidden Antigravity contributes neither calls nor scan status")
        let rescanned = await engine.computeSnapshot(rangeKey: "all", cutoff: nil, rescan: true)
        try check(rescanned.entries.filter { $0.source == .codex }.map(\.count) == recovered.entries.filter { $0.source == .codex }.map(\.count), "rescan idempotent")
        try archiveRescanMetrics(home.appendingPathComponent("codex-rescan-metrics"))

        let modernHome = home.appendingPathComponent("codex-modern")
        let modernLines = [
            #"{"timestamp":"2026-11-10T03:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"js_repl","input":"await tools.mcp__codebase_memory_mcp__search_graph({\"pattern\":\"Foo\"})"}}"#,
            #"{"timestamp":"2026-11-10T03:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"js_repl","input":"cat /Users/test/.codex/skills/ponytail-audit/SKILL.md"}}"#,
            #"{"timestamp":"2026-11-10T03:00:02Z","type":"response_item","payload":{"type":"function_call","name":"js","namespace":"mcp__cua_repl","arguments":"{}"}}"#,
            #"{"timestamp":"2026-11-10T03:00:03Z","type":"response_item","payload":{"type":"custom_tool_call","name":"apply_patch","input":"*** Update File: /repo/skills/my-skill/SKILL.md\n+const x = tools.filter(Boolean);\n"}}"#,
            #"{"timestamp":"2026-11-10T03:00:04Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__engram__mem_search({\"query\":\"pool\"});\nawait tools.exec_command({\"cmd\":\"cat /Users/test/.codex/skills/e2e/SKILL.md\"});"}}"#,
            #"{"timestamp":"2026-11-10T03:00:05Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"// await tools.mcp__engram__mem_search({query: 'not executed'})\ntext('hello')"}}"#,
            #"{"timestamp":"2026-11-10T03:00:06Z","type":"response_item","payload":{"type":"custom_tool_call","name":"js_repl","input":"/* tools.mcp__engram__mem_search({}) */\ntext(\"tools.mcp__engram__mem_search({})\");\ntext(`tools.mcp__engram__mem_search({})`);"}}"#,
            #"{"timestamp":"2026-11-10T03:00:07Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.exec_command({\"cmd\":\"python3 -c 'tools.mcp__engram__mem_search({})'\"})"}}"#,
            #"{"timestamp":"2026-11-10T03:00:08Z","type":"response_item","payload":{"type":"custom_tool_call","name":"js_repl","input":"text(`r=${await tools.mcp__engram__mem_context({})}`)"}}"#,
            #"{"timestamp":"2026-11-10T03:00:09Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const escaped = 'hello'.replace(/'/g, ''); await tools.mcp__engram__mem_context({})"}}"#,
            #"{"timestamp":"2026-11-10T03:00:10Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const proto = 'https://x'.replace(/https?:\\/\\//g, ''); const div = 10 / 2 + 'a/b'.length; const cls = /[/'\"]/g; const rx = /tools\\.mcp__engram__mem_search\\(/g; await tools.mcp__engram__mem_get_observation({})"}}"#,
            #"{"timestamp":"2026-11-10T03:00:11Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"if (true) /'/.test(\"x\"); await tools.mcp__engram__mem_context({});"}}"#,
            #"{"timestamp":"2026-11-10T03:00:12Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"if (true) /tools.mcp__engram__mem_context(.*)/.test(\"example\");"}}"#,
            #"{"timestamp":"2026-11-10T03:00:13Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"let i = 2; const ratio = i++ / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:14Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const ratio = {value:2} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:15Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"if (true) { a(); } /'/.test(\"x\"); await tools.mcp__engram__mem_context({});"}}"#,
            #"{"timestamp":"2026-11-10T03:00:16Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const d = obj.delete / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:17Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const ratio = function() {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:18Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"switch (1) { case 1: {} /'/.test(\"x\"); await tools.mcp__engram__mem_context({}); break; }"}}"#,
            #"{"timestamp":"2026-11-10T03:00:19Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"function decl() {} /'/.test(\"x\"); await tools.mcp__engram__mem_context({}); const cls = class {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:20Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const tern = true ? {a: 1} : {} / await tools.mcp__engram__mem_context({}) / 2; switch (1) { default: {} /'/.test(\"x\"); await tools.mcp__engram__mem_context({}); break; }"}}"#,
            #"{"timestamp":"2026-11-10T03:00:21Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"const arr = [class {}]; const r1 = class extends arr[0] {} / await tools.mcp__engram__mem_context({}) / 2; function F() { return class {}; } const r2 = class extends new F() {} / await tools.mcp__engram__mem_context({}) / 2; const r3 = class extends (function() { return class {}; })() {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#,
            #"{"timestamp":"2026-11-10T03:00:22Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"async function g(y) { const getBase = async () => class {}; const r4 = class extends (await getBase()) {} / await tools.mcp__engram__mem_context({}) / 2; for await (const x of y) /'/.test(x); await tools.mcp__engram__mem_context({}); } const af1 = () => function() {} / await tools.mcp__engram__mem_context({}) / 2; const af2 = () => class {} / await tools.mcp__engram__mem_context({}) / 2;"}}"#
        ].joined(separator: "\n") + "\n"
        try write(modernLines, modernHome.appendingPathComponent(".codex/sessions/day/modern.jsonl"))
        let modernCodex = CodexCallEventSource(
            homeDirectory: modernHome.path,
            timeZone: TimeZone(secondsFromGMT: 0)!,
            environment: [:],
            knownMCPServers: ["codebase-memory-mcp", "computer-use"]
        ).collect(cutoff: nil)
        try check(modernCodex.entries.contains(where: { $0.kind == .mcp && $0.name == "codebase-memory-mcp/search_graph" }), "Codex parses modern js_repl MCP call")
        try check(modernCodex.entries.contains(where: { $0.kind == .mcp && $0.name == "computer-use/js" }), "Codex maps cua_repl namespace to computer-use MCP")
        try check(modernCodex.entries.first(where: { $0.kind == .mcp && $0.name == "engram/mem_search" })?.count == 1, "Codex ignores JS comments, string literals, and regex literals when counting MCP calls")
        try check(modernCodex.entries.first(where: { $0.kind == .mcp && $0.name == "engram/mem_context" })?.count == 20, "Codex handles control/for-await regexes, function/class/arrow expressions, class extends heritage, switch case/default/ternary braces, postfix ++ division, and dot-keyword division")
        try check(modernCodex.entries.first(where: { $0.kind == .mcp && $0.name == "engram/mem_get_observation" })?.count == 1, "Codex handles escaped slashes, division, and character classes before real MCP calls")
        try check(modernCodex.entries.first(where: { $0.kind == .builtin && $0.name == "exec" })?.count == 2, "comment-only and regex-suppressed exec wrappers record ordinary builtin fallback")
        try check(modernCodex.entries.first(where: { $0.kind == .builtin && $0.name == "js_repl" })?.count == 2, "comment/string-only and skill-only js_repl wrappers record ordinary builtin fallback")
        try check(modernCodex.entries.first(where: { $0.kind == .builtin && $0.name == "exec_command" })?.count == 2, "real exec_command wrapper calls counted without string-nested Python calls")
        try check(modernCodex.entries.contains(where: { $0.kind == .skill && $0.name == "ponytail-audit" }), "Codex parses custom_tool_call skill reads")
        try check(modernCodex.entries.contains(where: { $0.kind == .skill && $0.name == "e2e" }), "Codex parses modern exec custom_tool_call skill reads")
        try check(modernCodex.entries.first(where: { $0.kind == .builtin && $0.name == "apply_patch" })?.count == 1, "apply_patch counted once as builtin")
        try check(!modernCodex.entries.contains(where: { $0.kind == .builtin && $0.name == "filter" }), "apply_patch diff text not parsed as js_repl wrapper call")
        try check(!modernCodex.entries.contains(where: { $0.kind == .skill && $0.name == "my-skill" }), "apply_patch SKILL.md diff not miscounted as skill invocation")

        let v1Home = home.appendingPathComponent("codex-v1-migrate")
        try write("[mcp_servers.codebase-memory-mcp]\ncommand = \"npx\"\n\n[mcp_servers.computer-use]\ncommand = \"npx\"\n", v1Home.appendingPathComponent(".codex/config.toml"))
        let v1SessionLines = [
            #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"js","namespace":"mcp__cua_repl","arguments":"{}"}}"#,
            #"{"timestamp":"2026-11-09T03:00:01Z","type":"response_item","payload":{"type":"function_call","name":"search_graph","namespace":"mcp__codebase_memory_mcp","arguments":"{}"}}"#,
            #"{"timestamp":"2026-11-09T03:00:02Z","type":"response_item","payload":{"type":"function_call","name":"mcp__engram__mem_search","arguments":"{}"}}"#
        ].joined(separator: "\n") + "\n"
        try write(v1SessionLines, v1Home.appendingPathComponent(".codex/sessions/day/migrated.jsonl"))
        let v1Day = CallAnalyticsDayBucket(entries: [
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "js", server: nil, dayKey: "2026-11-09", count: 1),
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "search_graph", server: nil, dayKey: "2026-11-09", count: 1),
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "mcp__engram__mem_search", server: nil, dayKey: "2026-11-09", count: 1)
        ], agentInvocations: [])
        let v1Archive = CallAnalyticsArchive(version: 1, updatedAt: "2026-11-09T12:00:00Z", fullHistoryImportedAt: "2026-11-09T12:00:00Z", days: ["2026-11-09": v1Day])
        let v1URL = CallAnalyticsArchiveStore.fileURL(homeDirectory: v1Home.path, version: 1)
        try write(String(decoding: JSONEncoder().encode(v1Archive), as: UTF8.self), v1URL)
        let v1Migrated = await CallAnalyticsEngine(homeDirectory: v1Home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        let v1Codex = v1Migrated.entries.filter { $0.source == .codex }
        try check(v1Codex.reduce(0) { $0 + $1.count } == 3, "v1 -> v2 backfill avoids double-counting legacy Codex MCP calls")
        try check(v1Codex.filter { $0.kind == .builtin }.isEmpty, "v1 -> v2 backfill removes superseded Codex MCP builtins")
        try check(v1Codex.contains(where: { $0.kind == .mcp && $0.name == "computer-use/js" }), "v1 -> v2 backfill retains computer-use/js MCP")
        try check(v1Codex.contains(where: { $0.kind == .mcp && $0.name == "codebase-memory-mcp/search_graph" }), "v1 -> v2 backfill retains codebase-memory-mcp/search_graph MCP")
        try check(v1Codex.contains(where: { $0.kind == .mcp && $0.name == "engram/mem_search" }), "v1 -> v2 backfill retains engram/mem_search MCP")

        let partialV1Home = home.appendingPathComponent("codex-v1-partial")
        try write("[mcp_servers.codebase-memory-mcp]\ncommand = \"npx\"\n", partialV1Home.appendingPathComponent(".codex/config.toml"))
        try write(
            #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"search_graph","namespace":"mcp__codebase_memory_mcp","arguments":"{}"}}"# + "\n",
            partialV1Home.appendingPathComponent(".codex/sessions/day/remaining.jsonl")
        )
        let partialV1Day = CallAnalyticsDayBucket(entries: [
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "search_graph", server: nil, dayKey: "2026-11-09", count: 100)
        ], agentInvocations: [])
        let partialV1Archive = CallAnalyticsArchive(version: 1, updatedAt: "2026-11-09T12:00:00Z", fullHistoryImportedAt: "2026-11-09T12:00:00Z", days: ["2026-11-09": partialV1Day])
        try write(String(decoding: JSONEncoder().encode(partialV1Archive), as: UTF8.self), CallAnalyticsArchiveStore.fileURL(homeDirectory: partialV1Home.path, version: 1))
        let partialEngine = CallAnalyticsEngine(homeDirectory: partialV1Home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:])
        let partialSnap = await partialEngine.computeSnapshot(rangeKey: "all", cutoff: nil)
        let partialCodex = partialSnap.entries.filter { $0.source == .codex }
        try check(partialCodex.reduce(0) { $0 + $1.count } == 100, "partial v1 -> v2 migration preserves deleted-session calls")
        try check(partialCodex.first(where: { $0.kind == .mcp && $0.name == "codebase-memory-mcp/search_graph" })?.count == 1, "partial migration upgrades surviving MCP call")
        try check(partialCodex.first(where: { $0.kind == .builtin && $0.name == "search_graph" })?.count == 99, "partial migration preserves 99 deleted-session calls")
        let reopenedCount = CallAnalyticsArchiveStore(homeDirectory: partialV1Home.path).allDays["2026-11-09"]?.entries.reduce(0) { $0 + $1.count } ?? -1
        try check(reopenedCount == 100, "reopened v2 archive persists all 100 calls")
        let partialRescan = await partialEngine.computeSnapshot(rangeKey: "all", cutoff: nil, rescan: true)
        try check(partialRescan.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count } == 100, "repeated rescan after partial v1 -> v2 migration stays idempotent at 100")

        // v1 archive with legacy `mcp__cua_repl__js` deduplicates with live `computer-use/js` on backfill
        let cuaHome = home.appendingPathComponent("codex-v1-cua-alias")
        try write("[mcp_servers.computer-use]\ncommand = \"npx\"\n", cuaHome.appendingPathComponent(".codex/config.toml"))
        try write(
            #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"function_call","name":"js","namespace":"mcp__cua_repl","arguments":"{}"}}"# + "\n",
            cuaHome.appendingPathComponent(".codex/sessions/day/cua.jsonl")
        )
        let cuaV1Day = CallAnalyticsDayBucket(entries: [
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "mcp__cua_repl__js", server: nil, dayKey: "2026-11-09", count: 3)
        ], agentInvocations: [])
        let cuaV1Archive = CallAnalyticsArchive(version: 1, updatedAt: "2026-11-09T12:00:00Z", fullHistoryImportedAt: "2026-11-09T12:00:00Z", days: ["2026-11-09": cuaV1Day])
        try write(String(decoding: JSONEncoder().encode(cuaV1Archive), as: UTF8.self), CallAnalyticsArchiveStore.fileURL(homeDirectory: cuaHome.path, version: 1))
        let cuaSnap = await CallAnalyticsEngine(homeDirectory: cuaHome.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        let cuaEntries = cuaSnap.entries.filter { $0.source == .codex && $0.kind == .mcp }
        try check(cuaEntries.count == 1 && cuaEntries.first?.name == "computer-use/js" && cuaEntries.first?.count == 3, "cua_repl v1 archive entry merges with computer-use/js without double counting")

        // Already-imported v2 archive preserves genuine .builtin `exec` counts when rescan discovers `.mcp` `<server>/exec`
        let v2Home = home.appendingPathComponent("codex-v2-rescan-exec")
        let v2Day = CallAnalyticsDayBucket(entries: [
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "exec", server: nil, dayKey: "2026-11-08", count: 5)
        ], agentInvocations: [])
        let v2Archive = CallAnalyticsArchive(version: 2, updatedAt: "2026-11-08T12:00:00Z", fullHistoryImportedAt: "2026-11-08T12:00:00Z", days: ["2026-11-08": v2Day])
        try write(String(decoding: JSONEncoder().encode(v2Archive), as: UTF8.self), CallAnalyticsArchiveStore.fileURL(homeDirectory: v2Home.path, version: 2))
        try write(
            [
                #"{"timestamp":"2026-11-08T03:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__engram__exec({})"}}"#,
                #"{"timestamp":"2026-11-08T03:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__engram__exec({})"}}"#
            ].joined(separator: "\n") + "\n",
            v2Home.appendingPathComponent(".codex/sessions/day/new.jsonl")
        )
        let v2Rescan = await CallAnalyticsEngine(homeDirectory: v2Home.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil, rescan: true)
        try check(v2Rescan.entries.first(where: { $0.kind == .builtin && $0.name == "exec" })?.count == 5, "v2 rescan does not deduct genuine builtin exec counts when new MCP exec calls appear")
        try check(v2Rescan.entries.first(where: { $0.kind == .mcp && $0.name == "engram/exec" })?.count == 2, "v2 rescan still adds newly discovered MCP exec calls")

        // v1 archive keeps genuine builtin `exec_command` calls untouched when custom_tool_call wrappers add `terminal/exec_command`,
        // while deducting only provably reclassified `function_call(namespace: "mcp__...")` items.
        let v1WrapperCollisionHome = home.appendingPathComponent("codex-v1-wrapper-collision")
        let v1WrapperCollisionDay = CallAnalyticsDayBucket(entries: [
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "exec_command", server: nil, dayKey: "2026-11-09", count: 5),
            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "search_graph", server: nil, dayKey: "2026-11-09", count: 4)
        ], agentInvocations: [])
        let v1WrapperCollisionArchive = CallAnalyticsArchive(version: 1, updatedAt: "2026-11-09T12:00:00Z", fullHistoryImportedAt: "2026-11-09T12:00:00Z", days: ["2026-11-09": v1WrapperCollisionDay])
        try write(String(decoding: JSONEncoder().encode(v1WrapperCollisionArchive), as: UTF8.self), CallAnalyticsArchiveStore.fileURL(homeDirectory: v1WrapperCollisionHome.path, version: 1))
        try write(
            [
                #"{"timestamp":"2026-11-09T03:00:00Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__terminal__exec_command({})"}}"#,
                #"{"timestamp":"2026-11-09T03:00:01Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"await tools.mcp__terminal__exec_command({})"}}"#,
                #"{"timestamp":"2026-11-09T03:00:02Z","type":"response_item","payload":{"type":"function_call","name":"search_graph","namespace":"mcp__codebase_memory_mcp","arguments":"{}"}}"#
            ].joined(separator: "\n") + "\n",
            v1WrapperCollisionHome.appendingPathComponent(".codex/sessions/day/collision.jsonl")
        )
        let wrapperCollisionSnap = await CallAnalyticsEngine(homeDirectory: v1WrapperCollisionHome.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
        let wrapperCollisionCodex = wrapperCollisionSnap.entries.filter { $0.source == .codex }
        try check(wrapperCollisionCodex.first(where: { $0.kind == .builtin && $0.name == "exec_command" })?.count == 5, "v1 migration preserves genuine builtin exec_command calls when custom wrapper MCP has same tool name")
        try check(wrapperCollisionCodex.first(where: { $0.kind == .mcp && $0.name == "terminal/exec_command" })?.count == 2, "v1 migration adds custom wrapper MCP calls without deduction")
        try check(wrapperCollisionCodex.first(where: { $0.kind == .builtin && $0.name == "search_graph" })?.count == 3, "v1 migration still deducts provably reclassified legacy function_call(namespace: mcp__...) items")
        try check(wrapperCollisionCodex.first(where: { $0.kind == .mcp && $0.name == "codebase_memory_mcp/search_graph" })?.count == 1, "v1 migration retains reclassified function_call MCP item")
        let persistedCollisionCount = CallAnalyticsArchiveStore(homeDirectory: v1WrapperCollisionHome.path).allDays["2026-11-09"]?.entries.reduce(0) { $0 + $1.count } ?? -1
        try check(persistedCollisionCount == 11, "v1 migration persists combined total (5+2+3+1=11) to v2 archive")

        try check(AntigravityCostProvider.extractSelectedModel(from: "<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from None to Gemini 4 Hydrogen. No need to comment</USER_SETTINGS_CHANGE>") == "gemini-4-hydrogen", "Gemini 4 Hydrogen selected model extracted")
        try check(AntigravityCostProvider.extractSelectedModel(from: "<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from Gemini 4 Hydrogen to Gemini 4 Carbon. No need to comment</USER_SETTINGS_CHANGE>") == "gemini-4-carbon", "Gemini 4 Carbon selected model extracted")
        try check(AntigravityCostProvider.extractSelectedModel(from: "<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from None to Orchestrator (Argon). No need to comment</USER_SETTINGS_CHANGE>") == "gemini-4-argon", "Orchestrator (Argon) selected model normalized")
        try check(AntigravityCostProvider.extractSelectedModel(from: "<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from None to Gemini 4 Argon. Later Model Selection changed to Gemini 4 Carbon. No need to comment</USER_SETTINGS_CHANGE>") == "gemini-4-carbon", "AntigravityCostProvider extractSelectedModel picks latest marker")
        try check(AntigravityCostProvider.extractSelectedModel(from: "<USER_SETTINGS_CHANGE>The user changed setting `Model Selection` from None to Gemini 4 Argon\\n. No need</USER_SETTINGS_CHANGE>") == "gemini-4-argon", "AntigravityCostProvider extractSelectedModel truncates at earliest newline delimiter before '. No need'")
    }
    static func poolProtection(_ home: URL) throws {
        let auth = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
        let owned = auth.appendingPathComponent("codex-owned.json")
        let manual = auth.appendingPathComponent("codex-manual.json")
        let agy = auth.appendingPathComponent("agy.json")
        try write(#"{"type":"codex","disabled":true,"circuit_breaker_tripped":true}"#, owned)
        try write(#"{"type":"codex","disabled":true}"#, manual)
        try write(#"{"type":"antigravity","disabled":true,"circuit_breaker_tripped":true}"#, agy)
        try check(!CodexPoolProtectionSettings.isEnabled(homeDirectory: home.path), "Codex default off")
        try CodexPoolProtectionSettings.setEnabled(false, threshold: 1, homeDirectory: home.path)
        try check(try object(owned)["disabled"] as? Bool == false, "turn off restores owned Codex pauses")
        try check(try object(manual)["disabled"] as? Bool == true, "manual Codex pause preserved")
        try check(try object(agy)["disabled"] as? Bool == true, "Codex never modifies AGY")
        try CodexPoolProtectionSettings.setEnabled(true, threshold: 5, homeDirectory: home.path)
        try check(CodexPoolProtectionSettings.threshold(homeDirectory: home.path) == 5, "Codex configurable threshold")
        let input: [String: Any] = ["type": "antigravity", "antigravity_capability_hints": ["model_ids": ["gemini-pro", "claude-sonnet", "gemini-4-argon"]]]
        let models = [AntigravityProvider.ModelQuota(id: "gemini-pro", label: "Gemini · Weekly", remainingPercent: 1, resetAt: nil, providerLabel: nil), AntigravityProvider.ModelQuota(id: "claude-sonnet", label: "Claude + GPT · Weekly", remainingPercent: 1, resetAt: nil, providerLabel: nil)]
        let result = try AntigravityPoolCircuitBreaker.updatedCredential(input, models: models, global: [], enabledPools: ["gemini"])!
        try check(result["excluded_models"] as? [String] == ["gemini-pro"], "only enabled pool blocks")
        let cleared = try AntigravityPoolCircuitBreaker.updatedCredential(result, models: [], global: [], enabledPools: [])!
        try check(cleared["excluded_models"] == nil, "deselect restores without fresh quota")
    }
    static func rtk(_ home: URL) throws {
        let old = home.appendingPathComponent("Library/Application Support/AIUsage/bin/token-saver-rtk")
        let binary = home.appendingPathComponent("Library/Application Support/AIUsage/RTK/versions/1.2.0/bin/rtk")
        try write("#!/bin/sh\nprintf selected-version\\n\n", binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
        try write(TokenSaverAgentRules.legacyRTKWrapper, old)
        let store = RTKVersionStore(home: home, cellarRoots: [])
        try check(try store.versions().count == 1, "RTK discovers managed versions")
        try store.activate(try store.versions().first!.id)
        try check(try store.versions().first?.isActive == true, "RTK current selected")
        try check(try String(contentsOf: old, encoding: .utf8) == TokenSaverAgentRules.rtkWrapper, "old wrapper migrated")
        var rejected = false
        do { try store.delete(binary.path) } catch { rejected = true }
        try check(rejected, "active RTK deletion rejected")
    }
    static func env(_ home: URL) throws {
        let file = home.appendingPathComponent(".zshrc")
        let original = "# keep\nexport OPENAI_API_KEY='fake-key'\nexport GEMINI_API_KEY=x; echo keep\n"
        try write(original, file)
        let findings = try EnvironmentOverrideDetector.scan(home: home, inherited: [:])
        try check(findings.count == 2, "env detects candidates without printing values")
        try check(findings.first { $0.key == "OPENAI_API_KEY" }?.canRemove == true, "simple env editable")
        try check(findings.first { $0.key == "GEMINI_API_KEY" }?.canRemove == false, "compound shell never removed")
        let undo = try EnvironmentOverrideDetector.remove(findings.first { $0.key == "OPENAI_API_KEY" }!)
        try check(!(try String(contentsOf: file, encoding: .utf8)).contains("fake-key"), "remove only exact assignment")
        try undo.restore()
        try check(try String(contentsOf: file, encoding: .utf8) == original, "Undo exact restore")
        try write("# concurrent edit", file)
        var rejected = false
        do { try undo.restore() } catch { rejected = true }
        try check(rejected, "Undo respects later edits")

        let uncertainShells = [
            "arguments=(\nOPENAI_API_KEY=fixture\n)\n",
            "for item in\nOPENAI_API_KEY=literal\ndo\n: \"$item\"\ndone\n",
            "select item in\nOPENAI_API_KEY=literal\ndo\nbreak\ndone\n",
            "cat <<'PAYLOAD'\nexport OPENAI_API_KEY=template-key\nPAYLOAD\n",
            "cat <<'PAYLOAD'\nexport OPENAI_API_KEY=template-key\nPAYLOAD\nexport GEMINI_API_KEY=actual-key\n",
            "text='literal\nexport OPENAI_API_KEY=template-key\n'\n",
            "text=word#'literal\nexport OPENAI_API_KEY=template-key\n'\n",
            "text=\"literal\nexport OPENAI_API_KEY=template-key\n\"\n",
            "printf '%s' \\\nexport OPENAI_API_KEY=template-key\n"
        ]
        for uncertain in uncertainShells {
            try write(uncertain, file)
            let inspected = try EnvironmentOverrideDetector.scan(home: home, inherited: [:])
            try check(!inspected.isEmpty && inspected.allSatisfy { !$0.canRemove }, "uncertain shell context is manual-only")
            var refused = false
            do { _ = try EnvironmentOverrideDetector.remove(inspected.first!) } catch { refused = true }
            try check(refused && String(contentsOf: file, encoding: .utf8) == uncertain, "heredoc, quoted payload and continuation stay byte-identical")
        }
        try write("# user's note\nif true; then\nexport OPENAI_API_KEY='simple-value'\nfi\n", file)
        let simpleBranch = try EnvironmentOverrideDetector.scan(home: home, inherited: [:])
        try check(simpleBranch.first?.canRemove == true, "ordinary comments and single-line quoted branch assignment remain editable")
    }
    static func mcp(_ home: URL) throws {
        let vault = Vault()
        for platform in AgentMCPStore.Platform.allCases {
            let store = AgentMCPStore(home: home, platform: platform, vault: vault.service)
            let server = AgentMCPStore.Server(name: "demo", command: "/usr/bin/env", args: ["/tmp/demo"], env: ["KEY": "secret-fixture"])
            try store.importServers([server])
            try check(try store.items().count == 1, "import \(platform)")
            let text = try String(contentsOf: store.configURL, encoding: .utf8)
            try check(!text.contains("secret-fixture"), "env secret absent from config")
            if platform == .codex { try check(!text.contains(#"\/"#), "TOML has no JSON slash escapes") }
            try store.setEnabled("demo", enabled: false)
            try check(try store.items().first?.enabled == false, "disable \(platform)")
            try store.setEnabled("demo", enabled: true)
            try check(try store.items().first?.enabled == true, "enable \(platform)")
            var duplicate = false
            do { try store.importServers([server]) } catch { duplicate = true }
            try check(duplicate, "never overwrite existing MCP")
        }
        for platform in AgentMCPStore.Platform.allCases {
            let linked = AgentMCPStore(home: home, platform: platform, vault: vault.service)
            let target = linked.configURL.appendingPathExtension("shared")
            try FileManager.default.moveItem(at: linked.configURL, to: target)
            try FileManager.default.createSymbolicLink(at: linked.configURL, withDestinationURL: target)
            let bytes = try Data(contentsOf: target)
            try check(linked.isConfigReadOnly, "linked config is explicitly read-only")
            try check(try linked.items().first?.name == "demo", "linked config remains inspectable")
            var blockedToggle = false
            do { try linked.setEnabled("demo", enabled: false) } catch { blockedToggle = true }
            var blockedImport = false
            do { try linked.importServers([.init(name: "linked-new", command: "/usr/bin/true")]) } catch { blockedImport = true }
            try check(blockedToggle && blockedImport, "linked MCP writes remain refused")
            try check(try Data(contentsOf: target) == bytes, "linked source bytes unchanged")
            try check(try FileManager.default.destinationOfSymbolicLink(atPath: linked.configURL.path) == target.path, "linked config never replaced")
            try FileManager.default.removeItem(at: linked.configURL)
            try FileManager.default.moveItem(at: target, to: linked.configURL)
            try check(!linked.isConfigReadOnly, "ordinary config remains editable")
        }
        let agySkills = AgentMCPStore(home: home, platform: .antigravity, vault: vault.service)
        try check(agySkills.skillsURL.path.hasSuffix(".gemini/antigravity/global_skills"), "AGY manages its actual native global skills directory")
        try write("---\nname: agy-native\n---\n", agySkills.skillsURL.appendingPathComponent("agy-native/SKILL.md"))
        try check(try AgentConfigProfiles(mcp: agySkills).skills().first?.name == "agy-native", "native AGY skills visible")
        let codex = AgentMCPStore(home: home, platform: .codex, vault: vault.service)
        try write("# preserve\n[mcp_servers.demo]\ncommand = \"/usr/bin/env\"\nenabled = false\n[mcp_servers.demo.http_headers]\nX-Test = \"header\"\n[features]\nkeep = true\n", codex.configURL)
        try check(try codex.items().map(\.name) == ["demo"], "MCP subtables grouped under parent")
        try codex.setEnabled("demo", enabled: true)
        let changed = try String(contentsOf: codex.configURL, encoding: .utf8)
        try check(changed.contains("X-Test = \"header\"") && changed.contains("keep = true"), "toggle preserves headers and unrelated config")
        try check(try codex.items().first?.enabled == true, "native disabled table can enable")
        let parsed = try AgentMCPStore.parse("[mcp_servers.docs]\ncommand = '/usr/bin/env'\nargs = [\"a\"]\n[mcp_servers.docs.env]\nKEY = 'value'\n")
        try check(parsed.first?.env["KEY"] == "value", "paste TOML env")
        let jsonStore = AgentMCPStore(home: home, platform: .antigravity, vault: vault.service)
        try jsonStore.setEnabled("demo", enabled: false)
        let index = home.appendingPathComponent("Library/Application Support/AIUsage/AgentConfig/antigravity-disabled.json")
        let backup = index.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: index, to: backup)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: backup)
        let before = try Data(contentsOf: jsonStore.configURL)
        var failed = false
        do { try jsonStore.setEnabled("demo", enabled: true) } catch { failed = true }
        try check(failed && (try Data(contentsOf: jsonStore.configURL)) == before, "MCP metadata failure never leaves untracked enable")
        try FileManager.default.removeItem(at: index)
        try FileManager.default.moveItem(at: backup, to: index)
        let unhealthy = AgentMCPStore(home: home, platform: .claude, vault: vault.service)
        try unhealthy.importServers([.init(name: "missing", command: "/nonexistent/mcp", env: ["API_KEY": ""])])
        try check(try unhealthy.items().first(where: { $0.name == "missing" })?.health == "Command not found", "health inspects wrapped command")
        try unhealthy.importServers([.init(name: "missing-key", command: "/usr/bin/true", env: ["API_KEY": ""])])
        try check(try unhealthy.items().first(where: { $0.name == "missing-key" })?.health == "Missing Key", "health checks Keychain env")
        let profiles = AgentConfigProfiles(mcp: codex)
        try write("---\nname: sample\n---\n", codex.skillsURL.appendingPathComponent("sample/SKILL.md"))
        try profiles.saveCurrent(name: "Coding")
        try profiles.setSkill("sample", enabled: false)
        try check(try profiles.skills().first?.enabled == false, "disable skill without deletion")
        try profiles.apply(try profiles.profiles().first!)
        try check(try profiles.skills().first?.enabled == true, "apply restores skill")
        try profiles.setSkill("sample", enabled: false)
        try write("duplicate", codex.skillsURL.appendingPathComponent("sample/SKILL.md"))
        var collision = false
        do { try profiles.saveCurrent(name: "Collision") } catch { collision = true }
        try check(collision, "duplicate skill gives error not trap")

        // [M6] Valid non-dictionary JSON root (`[]`) in MCP config throws Failure.invalid cleanly without SIGTRAP crash
        try write("[]", jsonStore.configURL)
        var nonObjectSetEnabledThrown = false
        do {
            try jsonStore.setEnabled("demo", enabled: true)
        } catch AgentMCPStore.Failure.invalid {
            nonObjectSetEnabledThrown = true
        }
        var nonObjectReplacingThrown = false
        do {
            _ = try jsonStore.replacing(Data("[]".utf8), name: "demo", with: nil)
        } catch AgentMCPStore.Failure.invalid {
            nonObjectReplacingThrown = true
        }
        try check(nonObjectSetEnabledThrown && nonObjectReplacingThrown, "[M6] non-object JSON root in MCP config throws Failure.invalid in both setEnabled and replacing without crashing")
    }
    static func priority(_ home: URL) throws {
        let a = home.appendingPathComponent("a.json"); let b = home.appendingPathComponent("b.json")
        try write(#"{"type":"codex","email":"same@example.test","account_id":"workspace-a","priority":2}"#, a)
        try write(#"{"type":"codex","email":"same@example.test","account_id":"workspace-b","priority":2}"#, b)
        let now = Date()
        try WeeklyResetPriority.sync(authDirectory: home, enabled: true, observations: [
            .init(provider: "codex", email: "same@example.test", reset: now.addingTimeInterval(100), accountID: "workspace-a"),
            .init(provider: "codex", email: "same@example.test", reset: now.addingTimeInterval(1000), accountID: "workspace-b")], now: now)
        try check((try object(a)["priority"] as! Int) > (try object(b)["priority"] as! Int), "weekly routing honors workspace identity")
        try WeeklyResetPriority.sync(authDirectory: home, enabled: false, observations: [])
        try check(try object(a)["priority"] as? Int == 2 && object(b)["priority"] as? Int == 2, "switch away restores user tier")
    }
    static func burnRate() throws {
        let now = Date(); let parser = ISO8601DateFormatter()
        let risk = QuotaBurnRate.estimate(remainingPercent: 10, resetAt: parser.string(from: now.addingTimeInterval(4 * 3600)), label: "5h Window", now: now)
        try check(risk?.isAtRisk == true, "fast burn predicts exhaustion")
        try check((risk?.multiplier ?? 0) > 4, "burn multiplier uses elapsed fraction")
        try check(QuotaBurnRate.estimate(remainingPercent: 95, resetAt: parser.string(from: now.addingTimeInterval(3600)), label: "5h Window", now: now)?.isAtRisk == false, "slow burn steady")
        try check(QuotaBurnRate.estimate(remainingPercent: 10, resetAt: nil, label: "Unknown", now: now) == nil, "unknown duration not invented")
        try check(QuotaBurnRate.windowDuration(label: "Gemini · 5 giờ") == 5 * 3600, "Vietnamese 5h label resolves window duration")
        try check(QuotaBurnRate.windowDuration(label: "Gemini · Hàng tuần") == 7 * 86400, "Vietnamese weekly label resolves window duration")
        try check(QuotaBurnRate.windowDuration(label: "5GB RAM") == nil, "5GB does not match 5h burn-rate window")

        let slow7dReset = parser.string(from: now.addingTimeInterval(3 * 86400))
        let fast7dReset = parser.string(from: now.addingTimeInterval(4 * 86400))
        let freshSlow = QuotaBurnRate.estimate(remainingPercent: 74, resetAt: slow7dReset, label: "Weekly", fetchedAt: now, isStale: false, now: now)
        try check(freshSlow != nil && freshSlow?.isAtRisk == false && freshSlow?.exhaustionAfter == nil,
                  "fresh active slow-burn snapshot stays steady without exhaustion")

        let atCaptureFast = QuotaBurnRate.estimate(remainingPercent: 28.6, resetAt: fast7dReset, label: "Weekly", now: now.addingTimeInterval(-600))
        let agedFast = QuotaBurnRate.estimate(remainingPercent: 28.6, resetAt: fast7dReset, label: "Weekly", fetchedAt: now.addingTimeInterval(-600), isStale: false, now: now)
        try check(agedFast?.isAtRisk == true, "fresh active fast-burn snapshot remains at risk")
        if let rawLeft = atCaptureFast?.exhaustionAfter, let agedLeft = agedFast?.exhaustionAfter {
            try check(abs(agedLeft - max(0, rawLeft - 600)) < 1.0, "snapshot-aware exhaustion subtracts elapsed age since capture")
        } else {
            try check(false, "expected exhaustionAfter on fast burn snapshot")
        }

        try check(QuotaBurnRate.estimate(remainingPercent: 74, resetAt: slow7dReset, label: "Weekly", fetchedAt: now.addingTimeInterval(-3 * 86400), isStale: false, now: now) == nil,
                  "dormant 3-day-old snapshot suppresses burn-rate prediction")
        try check(QuotaBurnRate.estimate(remainingPercent: 74, resetAt: slow7dReset, label: "Weekly", fetchedAt: now.addingTimeInterval(-(30 * 60 + 1)), isStale: false, now: now) == nil,
                  "30m + 1s old snapshot is stale and suppresses burn-rate prediction")
        try check(QuotaBurnRate.estimate(remainingPercent: 74, resetAt: slow7dReset, label: "Weekly", fetchedAt: now.addingTimeInterval(-30 * 60), isStale: false, now: now) != nil,
                  "exact 30m boundary snapshot remains eligible")
        try check(QuotaBurnRate.estimate(remainingPercent: 74, resetAt: slow7dReset, label: "Weekly", fetchedAt: now, isStale: true, now: now) == nil,
                  "explicit isStale=true suppresses burn-rate even at age 0")
        try check(QuotaBurnRate.estimate(remainingPercent: 74, resetAt: slow7dReset, label: "Weekly", fetchedAt: nil, isStale: false, now: now) == nil,
                  "missing fetchedAt suppresses burn-rate prediction")
        try check(QuotaBurnRate.isSnapshotFresh(fetchedAt: now.addingTimeInterval(30), now: now) == true,
                  "small +30s future clock skew tolerated")
        try check(QuotaBurnRate.isSnapshotFresh(fetchedAt: now.addingTimeInterval(120), now: now) == false,
                  "large +120s future clock skew rejected")
        try check(QuotaBurnRate.estimate(remainingPercent: 20, resetAt: parser.string(from: now.addingTimeInterval(-10)), label: "5h Window", fetchedAt: now.addingTimeInterval(-300), isStale: false, now: now) == nil,
                  "window expired at now suppresses prediction even if unexpired at fetchedAt")
        try check(QuotaBurnRate.isSnapshotFresh(fetchedAt: now, now: now, maxAge: -1) == false
                  && QuotaBurnRate.isSnapshotFresh(fetchedAt: now, now: now, maxAge: .nan) == false,
                  "negative or NaN maxAge rejected")

        let pastProjected = QuotaBurnRate.estimate(
            remainingPercent: 5,
            resetAt: parser.string(from: now.addingTimeInterval(4 * 3600 - 600)),
            label: "5h Window",
            fetchedAt: now.addingTimeInterval(-600),
            isStale: false,
            now: now
        )
        try check(pastProjected != nil && pastProjected?.isAtRisk == true && pastProjected?.exhaustionAfter == 0,
                  "past-projected exhaustion within TTL clamps to 0.0 instead of positive minutes")

        let subMinute = QuotaBurnRate.estimate(
            remainingPercent: 5,
            resetAt: parser.string(from: now.addingTimeInterval(4 * 3600 - 159)),
            label: "5h Window",
            fetchedAt: now.addingTimeInterval(-159),
            isStale: false,
            now: now
        )
        if let secs = subMinute?.exhaustionAfter {
            try check(subMinute?.isAtRisk == true && secs > 0 && secs < 60,
                      "positive sub-minute ETA remains strictly positive (0 < secs < 60)")
        } else {
            try check(false, "expected positive sub-minute exhaustionAfter")
        }

        let validTimestamps = [
            "2023-11-14T22:13:20Z",
            "2023-11-14T22:13:20.123456Z",
            "2023-11-14T22:13:20+07:00",
            "2023-11-14T22:13:20.5+07:00",
            "2023-11-14T22:13:20-05:30",
            "2023-11-14T22:13:20+0700",
            "2023-11-14T22:13:20+07"
        ]
        for valid in validTimestamps {
            try check(QuotaBurnRate.parseSnapshotTimestamp(valid) != nil,
                      "strict snapshot timestamp accepts valid ISO8601 \(valid)")
        }

        let invalidTimestamps: [String?] = [
            "2023-11-14T22:13:20Zjunk",
            "2023-11-14T22:13:20.123Zjunk",
            "2023-11-14T22:13:20+07:00junk",
            "2023-11-14T22:13:20Z\n",
            "2023-11-14T22:13:20Z ",
            " 2023-11-14T22:13:20Z",
            "2023-11-14T22:13:20+99:99",
            "not-a-timestamp",
            "",
            nil
        ]
        for invalid in invalidTimestamps {
            try check(QuotaBurnRate.parseSnapshotTimestamp(invalid) == nil,
                      "strict snapshot timestamp rejects malformed/trailing junk \(String(describing: invalid))")
        }

        let probeNow = QuotaBurnRate.parseSnapshotTimestamp("2023-11-14T22:13:20Z")!
        let probeReset = SharedFormatters.iso8601String(from: probeNow.addingTimeInterval(3 * 3600))
        try check(
            QuotaBurnRate.estimate(
                remainingPercent: 74,
                resetAt: probeReset,
                label: "5h Window",
                fetchedAt: QuotaBurnRate.parseSnapshotTimestamp("2023-11-14T22:13:20Z"),
                now: probeNow
            ) != nil,
            "fixed-clock probe accepts exact ISO8601 timestamp"
        )
        try check(
            QuotaBurnRate.estimate(
                remainingPercent: 74,
                resetAt: probeReset,
                label: "5h Window",
                fetchedAt: QuotaBurnRate.parseSnapshotTimestamp("2023-11-14T22:13:20Zjunk"),
                now: probeNow
            ) == nil,
            "fixed-clock probe suppresses prediction when timestamp has trailing junk"
        )

        let rolloverClock = QuotaBurnRate.parseSnapshotTimestamp("2026-12-01T00:00:00Z")!
        let rolloverReset = "2026-12-01T03:00:00Z"
        try check(
            QuotaBurnRate.estimate(
                remainingPercent: 74,
                resetAt: rolloverReset,
                label: "5h Window",
                fetchedAt: QuotaBurnRate.parseSnapshotTimestamp("2026-12-01T00:00:00Z"),
                now: rolloverClock
            ) != nil,
            "valid 2026-12-01T00:00:00Z produces burn-rate estimate at fixed clock"
        )
        try check(
            QuotaBurnRate.parseSnapshotTimestamp("2026-11-31T00:00:00Z") == nil
                && QuotaBurnRate.estimate(
                    remainingPercent: 74,
                    resetAt: rolloverReset,
                    label: "5h Window",
                    fetchedAt: QuotaBurnRate.parseSnapshotTimestamp("2026-11-31T00:00:00Z"),
                    now: rolloverClock
                ) == nil,
            "nonexistent 2026-11-31T00:00:00Z is rejected instead of rolling over to 2026-12-01"
        )

        let nonLeapRolloverClock = QuotaBurnRate.parseSnapshotTimestamp("2026-03-01T00:00:00Z")!
        try check(
            QuotaBurnRate.parseSnapshotTimestamp("2026-02-29T00:00:00Z") == nil
                && QuotaBurnRate.estimate(
                    remainingPercent: 74,
                    resetAt: "2026-03-01T03:00:00Z",
                    label: "5h Window",
                    fetchedAt: QuotaBurnRate.parseSnapshotTimestamp("2026-02-29T00:00:00Z"),
                    now: nonLeapRolloverClock
                ) == nil,
            "non-leap 2026-02-29T00:00:00Z is rejected instead of rolling over to 2026-03-01"
        )
        try check(QuotaBurnRate.parseSnapshotTimestamp("2100-02-29T00:00:00Z") == nil,
                  "century non-leap 2100-02-29T00:00:00Z is rejected")

        let leapClock = QuotaBurnRate.parseSnapshotTimestamp("2028-02-29T00:00:00Z")
        try check(
            leapClock != nil
                && QuotaBurnRate.estimate(
                    remainingPercent: 74,
                    resetAt: "2028-02-29T03:00:00Z",
                    label: "5h Window",
                    fetchedAt: leapClock,
                    now: leapClock!
                ) != nil,
            "valid leap-year 2028-02-29T00:00:00Z parses and produces estimate"
        )
        try check(QuotaBurnRate.parseSnapshotTimestamp("2000-02-29T00:00:00Z") != nil,
                  "quadricentennial leap-year 2000-02-29T00:00:00Z parses")

        let plus07Midnight = QuotaBurnRate.parseSnapshotTimestamp("2026-12-01T01:30:00+07:00")
        let utcPrevDay = QuotaBurnRate.parseSnapshotTimestamp("2026-11-30T18:30:00Z")
        try check(
            plus07Midnight != nil && plus07Midnight == utcPrevDay
                && QuotaBurnRate.estimate(
                    remainingPercent: 74,
                    resetAt: "2026-11-30T21:30:00Z",
                    label: "5h Window",
                    fetchedAt: plus07Midnight,
                    now: utcPrevDay!
                ) != nil,
            "midnight-crossing +07:00 timestamp preserves raw calendar day and matches UTC instant"
        )
        try check(
            QuotaBurnRate.parseSnapshotTimestamp("2026-11-30T23:30:00-07:00") == QuotaBurnRate.parseSnapshotTimestamp("2026-12-01T06:30:00Z")
                && QuotaBurnRate.parseSnapshotTimestamp("2028-02-29T00:30:00+07:00") == QuotaBurnRate.parseSnapshotTimestamp("2028-02-28T17:30:00Z")
                && QuotaBurnRate.parseSnapshotTimestamp("2026-11-31T01:30:00+07:00") == nil,
            "midnight-crossing negative/leap offsets preserve exact instant while rejecting nonexistent offset date"
        )
        for badClock in [
            "2026-12-01T24:00:00Z",
            "2026-12-01T23:60:00Z",
            "2026-12-01T23:59:60Z",
            "0000-01-01T00:00:00Z",
            "2026-00-10T00:00:00Z",
            "2026-11-00T00:00:00Z"
        ] {
            try check(QuotaBurnRate.parseSnapshotTimestamp(badClock) == nil,
                      "out-of-range calendar/clock component rejected: \(badClock)")
        }
    }
    static func warmup(_ home: URL) async throws {
        try check(WarmupSettings().autoChainReset == false, "WarmupSettings.autoChainReset defaults to false")
        let decodedDefaults = try JSONDecoder().decode(WarmupSettings.self, from: Data("{}".utf8))
        try check(decodedDefaults.autoChainReset == false, "WarmupSettings decodes autoChainReset as false when omitted")
        var settings = WarmupSettings(); settings.enabled = true
        let now = Date(); let calendar: Calendar = { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(secondsFromGMT: 0)!; return value }()
        settings.hour = calendar.component(.hour, from: now); settings.minute = calendar.component(.minute, from: now)
        let stamp = ISO8601DateFormatter().string(from: now)
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 50, resetAt: "invalid") == nil, "malformed reset is unknown, never inactive")
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 50, resetAt: nil) == nil, "missing reset on used window is unknown")
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 100, resetAt: nil) != nil, "fresh full inactive window accepted")
        let codexIdleReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(5 * 3600))
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 100, resetAt: codexIdleReset)?.activeUntil == nil, "idle 100% 5h horizon treated as unstarted")
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 99, resetAt: codexIdleReset)?.activeUntil != nil, "used 5h window treated as active")
        let shortReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(3600))
        try check(ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, remainingPercent: 100, resetAt: shortReset)?.activeUntil != nil, "short non-5h reset treated as active")
        try check(OfficialWarmupProcess.codexAuthFile(directory: "/tmp/codex-auth-sample.json").lastPathComponent == "codex-auth-sample.json", "direct json auth file path supported")
        try check(OfficialWarmupProcess.codexAuthFile(directory: "/tmp/codex-home").lastPathComponent == "auth.json", "directory auth path resolves auth.json")
        let target = WarmupSettings.Target(provider: .codex, directory: "/fixture/.codex", email: "fixture@example.test")
        settings.targets = [target]; try settings.save(home: home)
        let attempts = Attempts(); let scheduler = ScheduledWarmup(home: home)
        try await scheduler.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: nil)], now: now, calendar: calendar, jitter: 0) { target in await attempts.add(target.id) }
        let count = await attempts.count(); try check(count == 1, "scheduled warmup dispatches via injected runner")
        let restarted = ScheduledWarmup(home: home)
        try await restarted.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: nil)], now: now, calendar: calendar, jitter: 0) { target in await attempts.add(target.id) }
        let second = await attempts.count(); try check(second == 1, "warmup restart never replays claimed request")
        let parallelHome = home.appendingPathComponent("parallel")
        try settings.save(home: parallelHome)
        let first = ScheduledWarmup(home: parallelHome); let other = ScheduledWarmup(home: parallelHome)
        let parallel = Attempts()
        let observation = ScheduledWarmup.Observation(targetID: target.id, fetchedAt: now, activeUntil: nil)
        async let one: Void = first.tick(observations: [observation], now: now, calendar: calendar, jitter: 0) { target in
            await parallel.add(target.id); try await Task.sleep(nanoseconds: 10_000_000)
        }
        async let two: Void = other.tick(observations: [observation], now: now, calendar: calendar, jitter: 0) { target in await parallel.add(target.id) }
        _ = try await (one, two)
        let parallelCount = await parallel.count(); try check(parallelCount == 1, "warmup cross-instance flock prevents duplicate dispatch")
        var aliases = settings
        aliases.targets = [target, .init(provider: target.provider, directory: target.directory + "/", email: target.email)]
        var aliasRejected = false
        do { try aliases.save(home: home.appendingPathComponent("aliases")) } catch { aliasRejected = true }
        try check(aliasRejected, "warmup rejects equivalent native directory aliases")
        let activeHome = home.appendingPathComponent("active")
        try settings.save(home: activeHome)
        let active = ScheduledWarmup(home: activeHome)
        try await active.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: now.addingTimeInterval(3600))], now: now, calendar: calendar, jitter: 0) { target in await parallel.add(target.id) }
        let activeCount = await parallel.count(); try check(activeCount == 1, "active 5h window never dispatched")
        let corrupt = activeHome.appendingPathComponent("Library/Application Support/AIUsage/warmup-attempts.json")
        try write("corrupt", corrupt)
        var corruptFailed = false
        do { try await active.tick(observations: [observation], now: now, calendar: calendar, jitter: 0) { target in await parallel.add(target.id) } } catch { corruptFailed = true }
        try check(corruptFailed, "corrupt uncertainty fence fails closed")

        let chainHome = home.appendingPathComponent("autochain")
        var chainSettings = settings; chainSettings.autoChainReset = true
        try chainSettings.save(home: chainHome)
        let chainAttempts = Attempts(); let chain = ScheduledWarmup(home: chainHome)
        try await chain.tick(observations: [.init(targetID: target.id, fetchedAt: now, activeUntil: nil)], now: now, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in await chainAttempts.add(t.id) }
        let c1 = await chainAttempts.count(); try check(c1 == 1, "auto-chain initial warmup dispatches")
        let midWindow = now.addingTimeInterval(3600)
        try await chain.tick(observations: [.init(targetID: target.id, fetchedAt: midWindow, activeUntil: nil)], now: midWindow, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in await chainAttempts.add(t.id) }
        let c2 = await chainAttempts.count(); try check(c2 == 1, "auto-chain skips mid-window 5h cycle")
        let justExpired = now.addingTimeInterval(5 * 3600 + 10)
        try await chain.tick(observations: [.init(targetID: target.id, fetchedAt: justExpired, activeUntil: nil)], now: justExpired, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in await chainAttempts.add(t.id) }
        let c3 = await chainAttempts.count(); try check(c3 == 1, "auto-chain waits for randomized post-reset delay")
        let afterDelay = now.addingTimeInterval(5 * 3600 + 605)
        try await chain.tick(observations: [.init(targetID: target.id, fetchedAt: afterDelay, activeUntil: nil)], now: afterDelay, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in await chainAttempts.add(t.id) }
        let c4 = await chainAttempts.count(); try check(c4 == 2, "auto-chain dispatches next 5h cycle after randomized delay")

        let isolationHome = home.appendingPathComponent("isolation")
        let tA = WarmupSettings.Target(provider: .codex, directory: "/fixture/acc-a", email: "a@example.test", accountID: "acct-a")
        let tB = WarmupSettings.Target(provider: .codex, directory: "/fixture/acc-b", email: "b@example.test", accountID: "acct-b")
        var isolationSettings = WarmupSettings(); isolationSettings.enabled = true
        isolationSettings.hour = calendar.component(.hour, from: now); isolationSettings.minute = calendar.component(.minute, from: now)
        isolationSettings.targets = [tA, tB]
        try isolationSettings.save(home: isolationHome)
        let isoAttempts = Attempts(); let isoScheduler = ScheduledWarmup(home: isolationHome)
        var preflightThrew = false
        do {
            try await isoScheduler.tick(
                observations: [.init(targetID: tA.id, fetchedAt: now, activeUntil: nil), .init(targetID: tB.id, fetchedAt: now, activeUntil: nil)],
                preflight: { t in if t.id == tA.id { throw AgentMCPStore.Failure.invalid("preflight reject A") } },
                now: now, calendar: calendar, jitter: 0
            ) { t in await isoAttempts.add(t.id) }
        } catch { preflightThrew = true }
        try check(preflightThrew, "preflight failure surfaces error")
        let iso1 = await isoAttempts.count(); try check(iso1 == 1, "preflight failure on first target does not abort sibling")
        let retryNow = now.addingTimeInterval(65)
        try await isoScheduler.tick(
            observations: [.init(targetID: tA.id, fetchedAt: retryNow, activeUntil: nil), .init(targetID: tB.id, fetchedAt: retryNow, activeUntil: nil)],
            preflight: { _ in },
            now: retryNow, calendar: calendar, jitter: 0
        ) { t in await isoAttempts.add(t.id) }
        let iso2 = await isoAttempts.count(); try check(iso2 == 2, "preflight failure never 5h-fences rejected target")

        let day1Due = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 7, minute: 0, second: 0))!
        let day2Base = calendar.date(byAdding: .day, value: 1, to: day1Due)!
        let rolloverHome = home.appendingPathComponent("rollover")
        var rolloverSettings = WarmupSettings(); rolloverSettings.enabled = true; rolloverSettings.autoChainReset = true
        rolloverSettings.hour = 7; rolloverSettings.minute = 0; rolloverSettings.targets = [target]
        try rolloverSettings.save(home: rolloverHome)
        let rolloverAttempts = Attempts(); let rollover = ScheduledWarmup(home: rolloverHome)
        try await rollover.tick(observations: [.init(targetID: target.id, fetchedAt: day1Due, activeUntil: day2Base.addingTimeInterval(60))], now: day1Due, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in
            await rolloverAttempts.add(t.id)
        }
        let day2Before = day2Base.addingTimeInterval(120)
        try await rollover.tick(observations: [.init(targetID: target.id, fetchedAt: day2Before, activeUntil: nil)], now: day2Before, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in
            await rolloverAttempts.add(t.id)
        }
        let roll1 = await rolloverAttempts.count(); try check(roll1 == 0, "day rollover daily window respects pending chain delay")
        let day2After = day2Base.addingTimeInterval(665)
        try await rollover.tick(observations: [.init(targetID: target.id, fetchedAt: day2After, activeUntil: nil)], now: day2After, calendar: calendar, jitter: 0, postResetDelay: { 600 }) { t in
            await rolloverAttempts.add(t.id)
        }
        let roll2 = await rolloverAttempts.count(); try check(roll2 == 1, "day rollover dispatches after chain delay elapses")

        func makeJWT(_ payload: [String: Any]) throws -> String {
            func b64url(_ data: Data) -> String {
                data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            }
            let h = try JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"])
            let b = try JSONSerialization.data(withJSONObject: payload)
            return "\(b64url(h)).\(b64url(b)).sig"
        }
        let oldAccess = try makeJWT(["email": "heal@example.test", "iat": 1_700_000_000, "https://api.openai.com/auth": ["chatgpt_account_id": "ws-heal", "chatgpt_user_id": "user-heal"]])
        let newAccess = try makeJWT(["email": "heal@example.test", "iat": 1_700_000_200, "https://api.openai.com/auth": ["chatgpt_account_id": "ws-heal", "chatgpt_user_id": "user-heal"]])
        let idToken = try makeJWT(["email": "heal@example.test", "https://api.openai.com/auth": ["chatgpt_account_id": "ws-heal", "chatgpt_user_id": "user-heal"]])
        let healDir = home.appendingPathComponent("heal-test")
        let sourceAuth = healDir.appendingPathComponent("source.json")
        let linkedDir = healDir.appendingPathComponent("linked-cpa")
        let linkedCopy = linkedDir.appendingPathComponent("cpa-heal.json")
        let sourceObj: [String: Any] = [
            "auth_mode": "chatgpt",
            "aiusage_credential_id": "cred-heal-1",
            "tokens": ["access_token": oldAccess, "id_token": idToken, "refresh_token": "rt-old", "account_id": "ws-heal"]
        ]
        let linkedObj: [String: Any] = [
            "type": "codex",
            "aiusage_credential_id": "cred-heal-1",
            "email": "heal@example.test",
            "account_id": "ws-heal",
            "access_token": oldAccess,
            "id_token": idToken,
            "refresh_token": "rt-old"
        ]
        try FileManager.default.createDirectory(at: linkedDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: sourceAuth)
        try JSONSerialization.data(withJSONObject: linkedObj).write(to: linkedCopy)
        CodexLinkedCredentialCopies.registerDirectory(linkedDir)
        defer { CodexLinkedCredentialCopies.resetForTesting() }
        let rotatedObj: [String: Any] = [
            "auth_mode": "chatgpt",
            "tokens": ["access_token": newAccess, "id_token": idToken, "refresh_token": "rt-rotated", "account_id": "ws-heal"]
        ]
        let rotatedString = String(data: try JSONSerialization.data(withJSONObject: rotatedObj), encoding: .utf8)!
        let mockCLI = healDir.appendingPathComponent("mock-codex.sh")
        try write("#!/bin/sh\ncat > \"$CODEX_HOME/auth.json\" <<'JSON'\n\(rotatedString)\nJSON\nexit 1\n", mockCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mockCLI.path)
        let healTarget = WarmupSettings.Target(provider: .codex, directory: sourceAuth.path, email: "heal@example.test", accountID: "ws-heal")
        var cliThrew = false
        do { try await OfficialWarmupProcess.run(target: healTarget, executable: mockCLI.path, environment: [:]) } catch { cliThrew = true }
        try check(cliThrew, "non-zero CLI exit propagates error after healing")
        try check((try object(sourceAuth)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-rotated", "rotated refresh_token healed to source file on CLI failure")
        try check(try object(linkedCopy)["refresh_token"] as? String == "rt-rotated", "rotated refresh_token synced to linked copy on CLI failure")

        let switchHome = home.appendingPathComponent("switch-race")
        let switchSource = switchHome.appendingPathComponent(".codex/auth.json")
        let switchBackup = switchHome.appendingPathComponent(".codex/auth.json.bak")
        let switchManaged = switchHome.appendingPathComponent("Library/Application Support/AIUsage/AuthImports/codex/cred-switch.json")
        let otherAccess = try makeJWT(["email": "heal@example.test", "iat": 1_700_000_100, "https://api.openai.com/auth": ["chatgpt_account_id": "ws-other", "chatgpt_user_id": "user-heal"]])
        let otherID = try makeJWT(["email": "heal@example.test", "https://api.openai.com/auth": ["chatgpt_account_id": "ws-other", "chatgpt_user_id": "user-heal"]])
        let otherObj: [String: Any] = ["auth_mode": "chatgpt", "tokens": ["access_token": otherAccess, "id_token": otherID, "refresh_token": "rt-other", "account_id": "ws-other"]]
        let otherFile = switchHome.appendingPathComponent("other.json")
        try FileManager.default.createDirectory(at: switchSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: switchManaged.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: switchSource)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: switchManaged)
        try JSONSerialization.data(withJSONObject: otherObj).write(to: otherFile)
        let switchMock = switchHome.appendingPathComponent("mock-switch.sh")
        let switchCapture = switchHome.appendingPathComponent("staged-path.txt")
        let switchScript = "#!/bin/sh\nprintf '%s' \"$CODEX_HOME/auth.json\" > \"\(switchCapture.path)\"\ncat > \"$CODEX_HOME/auth.json\" <<'JSON'\n\(rotatedString)\nJSON\n/bin/cp \"\(switchSource.path)\" \"\(switchBackup.path)\"\n/bin/cp \"\(otherFile.path)\" \"\(switchSource.path)\"\nexit 1\n"
        try write(switchScript, switchMock)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: switchMock.path)
        let switchTarget = WarmupSettings.Target(provider: .codex, directory: switchSource.path, email: "heal@example.test", accountID: "ws-heal")
        var switchThrew = false
        do { try await OfficialWarmupProcess.run(target: switchTarget, executable: switchMock.path, environment: [:]) } catch { switchThrew = true }
        try check(switchThrew, "switch-race mock CLI surfaces error")
        let capturedStage = try String(contentsOf: switchCapture, encoding: .utf8)
        try check((try object(switchSource)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-other", "live switched account B remains untouched")
        try check((try object(switchBackup)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-rotated", "newly created backup receives rotated A token")
        try check((try object(switchManaged)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-rotated", "AuthImports copy receives rotated A token across switch race")
        try check(!FileManager.default.fileExists(atPath: capturedStage), "temp staged dir cleaned after durable heal")

        let brokenHome = home.appendingPathComponent("prespawn-fence")
        let brokenCLI = brokenHome.appendingPathComponent("broken-codex")
        try write("#!/definitely-not-an-installed-interpreter\nexit 0\n", brokenCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brokenCLI.path)
        let brokenSource = brokenHome.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: brokenSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: brokenSource)
        let brokenTarget = WarmupSettings.Target(provider: .codex, directory: brokenSource.path, email: "heal@example.test", accountID: "ws-heal")
        var brokenSettings = WarmupSettings(); brokenSettings.enabled = true
        brokenSettings.hour = calendar.component(.hour, from: now); brokenSettings.minute = calendar.component(.minute, from: now)
        brokenSettings.targets = [brokenTarget]
        try brokenSettings.save(home: brokenHome)
        let brokenScheduler = ScheduledWarmup(home: brokenHome)
        let brokenAttempts = Attempts()
        var preSpawnThrew = false
        do {
            try await brokenScheduler.tick(
                observations: [.init(targetID: brokenTarget.id, fetchedAt: now, activeUntil: nil)],
                now: now, calendar: calendar, jitter: 0
            ) { t in try await OfficialWarmupProcess.run(target: t, executable: brokenCLI.path, environment: [:]) }
        } catch is OfficialWarmupProcess.PreSpawnFailure { preSpawnThrew = true }
        try check(preSpawnThrew, "missing interpreter surfaces PreSpawnFailure")
        let repairNow = now.addingTimeInterval(65)
        try await brokenScheduler.tick(
            observations: [.init(targetID: brokenTarget.id, fetchedAt: repairNow, activeUntil: nil)],
            now: repairNow, calendar: calendar, jitter: 0
        ) { t in await brokenAttempts.add(t.id) }
        let repairCount = await brokenAttempts.count()
        try check(repairCount == 1, "confirmed pre-spawn failure releases 5h fence for repaired retry")

        // Late CLI resolution failure inside runner (between preflight and spawn) must also release the 5h fence.
        let lateHome = home.appendingPathComponent("late-cli-disappear")
        let lateSource = lateHome.appendingPathComponent(".codex/auth.json")
        try FileManager.default.createDirectory(at: lateSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: lateSource)
        let lateTarget = WarmupSettings.Target(provider: .codex, directory: lateSource.path, email: "heal@example.test", accountID: "ws-heal")
        var lateSettings = WarmupSettings(); lateSettings.enabled = true
        lateSettings.hour = calendar.component(.hour, from: now); lateSettings.minute = calendar.component(.minute, from: now)
        lateSettings.targets = [lateTarget]
        try lateSettings.save(home: lateHome)
        let lateScheduler = ScheduledWarmup(home: lateHome)
        let lateAttempts = Attempts()
        var latePreSpawnThrew = false
        do {
            try await lateScheduler.tick(
                observations: [.init(targetID: lateTarget.id, fetchedAt: now, activeUntil: nil)],
                preflight: { _ in },
                now: now, calendar: calendar, jitter: 0
            ) { _ in
                throw OfficialWarmupProcess.PreSpawnFailure("Official CLI not found; warmup skipped.")
            }
        } catch is OfficialWarmupProcess.PreSpawnFailure {
            latePreSpawnThrew = true
        }
        try check(latePreSpawnThrew, "late runner CLI disappearance surfaces PreSpawnFailure")
        try await lateScheduler.tick(
            observations: [.init(targetID: lateTarget.id, fetchedAt: repairNow, activeUntil: nil)],
            now: repairNow, calendar: calendar, jitter: 0
        ) { t in await lateAttempts.add(t.id) }
        let lateRetryCount = await lateAttempts.count()
        try check(lateRetryCount == 1, "late runner PreSpawnFailure releases 5h fence for next tick retry")

        // ManagedAuthImportBoundary: Debug may read production imports pre-stage, must never mutate them on heal.
        CodexLinkedCredentialCopies.resetForTesting()
        let boundaryHome = home.appendingPathComponent("managed-boundary")
        let appSupport = boundaryHome.appendingPathComponent("Library/Application Support")
        let debugBoundary = ManagedAuthImportBoundary(bundleIdentifier: "com.aiusage.desktop.debug", applicationSupportDirectory: appSupport)
        let debugSource = debugBoundary.activeRootURL.appendingPathComponent("codex/review.json")
        let prodImport = debugBoundary.productionRootURL.appendingPathComponent("codex/review.json")
        try FileManager.default.createDirectory(at: debugSource.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prodImport.deletingLastPathComponent(), withIntermediateDirectories: true)
        let midAccess = try makeJWT(["email": "heal@example.test", "iat": 1_700_000_100, "https://api.openai.com/auth": ["chatgpt_account_id": "ws-heal", "chatgpt_user_id": "user-heal"]])
        let prodInitialObj: [String: Any] = [
            "auth_mode": "chatgpt",
            "aiusage_credential_id": "cred-heal-1",
            "tokens": ["access_token": midAccess, "id_token": idToken, "refresh_token": "rt-prod-initial", "account_id": "ws-heal"]
        ]
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: debugSource)
        try JSONSerialization.data(withJSONObject: prodInitialObj).write(to: prodImport)
        let boundaryCapture = boundaryHome.appendingPathComponent("prestage-refresh.txt")
        let boundaryCLI = boundaryHome.appendingPathComponent("mock-boundary-codex.sh")
        let boundaryScript = """
        #!/bin/sh
        /usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[2],"w").write(d["tokens"]["refresh_token"])' "$CODEX_HOME/auth.json" "\(boundaryCapture.path)"
        cat > "$CODEX_HOME/auth.json" <<'JSON'
        \(rotatedString)
        JSON
        exit 1
        """
        try write(boundaryScript, boundaryCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: boundaryCLI.path)
        let debugTarget = WarmupSettings.Target(provider: .codex, directory: debugSource.path, email: "heal@example.test", accountID: "ws-heal")
        var boundaryThrew = false
        do { try await OfficialWarmupProcess.run(target: debugTarget, executable: boundaryCLI.path, environment: [:]) } catch { boundaryThrew = true }
        try check(boundaryThrew, "boundary mock CLI failure propagates")
        try check((try? String(contentsOf: boundaryCapture, encoding: .utf8)) == "rt-prod-initial", "Debug warmup still reads newer production AuthImports pre-stage")
        try check((try object(debugSource)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-rotated", "Debug warmup heals its own active managed root")
        try check((try object(prodImport)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-prod-initial", "Debug warmup never mutates production AuthImports")

        // Production managed warmup must likewise heal production without mutating Debug AuthImports.
        let prodOnlyObj: [String: Any] = [
            "auth_mode": "chatgpt",
            "aiusage_credential_id": "cred-heal-1",
            "tokens": ["access_token": oldAccess, "id_token": idToken, "refresh_token": "rt-prod-old", "account_id": "ws-heal"]
        ]
        let debugUntouchedObj: [String: Any] = [
            "auth_mode": "chatgpt",
            "aiusage_credential_id": "cred-heal-1",
            "tokens": ["access_token": oldAccess, "id_token": idToken, "refresh_token": "rt-debug-only", "account_id": "ws-heal"]
        ]
        try JSONSerialization.data(withJSONObject: prodOnlyObj).write(to: prodImport)
        try JSONSerialization.data(withJSONObject: debugUntouchedObj).write(to: debugSource)
        let prodTarget = WarmupSettings.Target(provider: .codex, directory: prodImport.path, email: "heal@example.test", accountID: "ws-heal")
        do { try await OfficialWarmupProcess.run(target: prodTarget, executable: mockCLI.path, environment: [:]) } catch {}
        try check((try object(prodImport)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-rotated", "production warmup heals production managed root")
        try check((try object(debugSource)["tokens"] as? [String: Any])?["refresh_token"] as? String == "rt-debug-only", "production warmup never mutates Debug AuthImports")

        // Round 4 audit fixes: env scrub, Claude --settings parity, weekly/monthly gating, and recovery diagnostics.
        let auditHome = home.appendingPathComponent("audit-fixes")
        let auditSource = auditHome.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: auditHome, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: auditSource)
        let auditTarget = WarmupSettings.Target(provider: .codex, directory: auditSource.path, email: "heal@example.test", accountID: "ws-heal")
        let envCapture = auditHome.appendingPathComponent("child-env.txt")
        let envCLI = auditHome.appendingPathComponent("env-codex.sh")
        try write("#!/bin/sh\n/usr/bin/printenv CODEX_API_KEY > \"\(envCapture.path)\" 2>/dev/null || true\nexit 0\n", envCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: envCLI.path)
        try await OfficialWarmupProcess.run(target: auditTarget, executable: envCLI.path, environment: ["CODEX_API_KEY": "fixture-only-key"])
        let childCodexKey = (try? String(contentsOf: envCapture, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        try check(childCodexKey.isEmpty, "warmup scrubs CODEX_API_KEY from child environment")

        let claudeDir = auditHome.appendingPathComponent("claude-profile")
        let claudeArgsFile = auditHome.appendingPathComponent("claude-args.txt")
        let claudeCLI = auditHome.appendingPathComponent("mock-claude.sh")
        try FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
        try write("#!/bin/sh\nprintf '%s\\n' \"$@\" > \"\(claudeArgsFile.path)\"\nexit 0\n", claudeCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: claudeCLI.path)
        let claudeTarget = WarmupSettings.Target(provider: .claude, directory: claudeDir.path, email: "heal@example.test")
        try await OfficialWarmupProcess.run(target: claudeTarget, executable: claudeCLI.path, environment: ["ANTHROPIC_API_KEY": "fixture-only"])
        let claudeArgs = try String(contentsOf: claudeArgsFile, encoding: .utf8).components(separatedBy: "\n")
        let expectedOverride = try ClaudeSubscriptionLaunch.settingsOverride()
        if let settingsIndex = claudeArgs.firstIndex(of: "--settings"), settingsIndex + 1 < claudeArgs.count {
            try check(claudeArgs[settingsIndex + 1] == expectedOverride, "Claude warmup passes session-only subscription --settings override")
        } else {
            try check(false, "Claude warmup must pass --settings before -p")
        }

        let futureWeeklyReset = ISO8601DateFormatter().string(from: now.addingTimeInterval(2 * 86400))
        let weeklyBlocked = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "5h Window", remainingPercent: 100, resetAt: codexIdleReset),
            .init(label: "Weekly Window", remainingPercent: 0, resetAt: futureWeeklyReset),
            .init(label: "Code Review", remainingPercent: 100, resetAt: nil)
        ])
        try check(weeklyBlocked?.activeUntil != nil, "exhausted weekly allowance blocks eligible 5h warmup until weekly reset")
        let monthlyBlocked = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "5h Window", remainingPercent: 100, resetAt: nil),
            .init(label: "Monthly Credit Limit", remainingPercent: 0, resetAt: futureWeeklyReset)
        ])
        try check(monthlyBlocked?.activeUntil != nil, "exhausted monthly credit limit blocks eligible 5h warmup")
        let featureOnlyExhausted = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "5h Window", remainingPercent: 100, resetAt: codexIdleReset),
            .init(label: "Weekly Window", remainingPercent: 50, resetAt: futureWeeklyReset),
            .init(label: "Code Review", remainingPercent: 0, resetAt: futureWeeklyReset),
            .init(label: "GPT-5.3-Codex-Spark · Weekly", remainingPercent: 0, resetAt: futureWeeklyReset)
        ])
        try check(featureOnlyExhausted != nil && featureOnlyExhausted?.activeUntil == nil, "feature/model-specific 0% limits never block main inference warmup")
        let missingWeeklyReset = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "5h Window", remainingPercent: 100, resetAt: nil),
            .init(label: "Weekly Window", remainingPercent: 0, resetAt: nil)
        ])
        try check(missingWeeklyReset == nil, "exhausted weekly allowance without future reset fails closed")
        let weeklyOnly = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "Weekly Window", remainingPercent: 80, resetAt: futureWeeklyReset)
        ])
        try check(weeklyOnly == nil, "plan without main 5h window is skipped cleanly")
        let zhWeeklyBlocked = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "5 小时", remainingPercent: 100, resetAt: nil),
            .init(label: "7 天", remainingPercent: 0, resetAt: futureWeeklyReset)
        ])
        try check(zhWeeklyBlocked?.activeUntil != nil, "localized Chinese weekly exhaustion (7 天) blocks eligible 5h warmup")
        let zhMonthlyBlocked = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "5 小时", remainingPercent: 100, resetAt: nil),
            .init(label: "月度积分上限", remainingPercent: 0, resetAt: futureWeeklyReset)
        ])
        try check(zhMonthlyBlocked?.activeUntil != nil, "localized Chinese monthly exhaustion blocks eligible 5h warmup")
        let viMonthlyBlocked = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "Cửa sổ 5 giờ", remainingPercent: 100, resetAt: nil),
            .init(label: "Giới hạn tín dụng tháng", remainingPercent: 0, resetAt: futureWeeklyReset)
        ])
        try check(viMonthlyBlocked?.activeUntil != nil, "localized Vietnamese monthly credit limit blocks eligible 5h warmup")
        let viMonthlyWindowBlocked = ScheduledWarmup.observation(targetID: "fixture", fetchedAt: stamp, windows: [
            .init(label: "Cửa sổ 5 giờ", remainingPercent: 100, resetAt: nil),
            .init(label: "Cửa sổ 1 tháng", remainingPercent: 0, resetAt: futureWeeklyReset)
        ])
        try check(viMonthlyWindowBlocked?.activeUntil != nil, "localized Vietnamese monthly window blocks eligible 5h warmup")
        let codexMonthlyResponse: [String: Any] = [
            "email": "vi-cap@example.test",
            "rate_limit": ["primary_window": ["used_percent": 0, "limit_window_seconds": 18000, "reset_after_seconds": 18000]],
            "spend_control": ["individual_limit": ["used_percent": 100, "reset_at": now.addingTimeInterval(86400).timeIntervalSince1970]]
        ]
        let decodedMonthlyResponse = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: codexMonthlyResponse)) as! [String: Any]
        let codexParsed = CodexProvider(homeDirectory: auditHome.path).parseResponse(
            decodedMonthlyResponse,
            accountId: "ws-vi-cap",
            source: SourceInfo(mode: "auto", type: "fixture"),
            fallbackEmail: "vi-cap@example.test"
        )
        let codexSummary = UsageNormalizer.normalize(provider: CodexProvider(homeDirectory: auditHome.path), usage: codexParsed)
        let localizedMaps: [(String, [String: String])] = [
            ("en", [:]),
            ("zh", ["5h Window": "5 小时", "Monthly Credit Limit": "月度积分上限"]),
            ("vi", ["5h Window": "Cửa sổ 5 giờ", "Monthly Credit Limit": "Giới hạn tín dụng tháng"])
        ]
        for (lang, map) in localizedMaps {
            let capHome = auditHome.appendingPathComponent("monthly-cap-" + lang)
            let capAuth = capHome.appendingPathComponent("auth.json")
            try FileManager.default.createDirectory(at: capHome, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: sourceObj).write(to: capAuth)
            let capTarget = WarmupSettings.Target(provider: .codex, directory: capAuth.path, email: "vi-cap@example.test", accountID: "ws-vi-cap")
            var capSettings = WarmupSettings(); capSettings.enabled = true
            capSettings.hour = calendar.component(.hour, from: now); capSettings.minute = calendar.component(.minute, from: now)
            capSettings.targets = [capTarget]
            try capSettings.save(home: capHome)
            let samples = codexSummary.windows.map {
                ScheduledWarmup.WindowSample(label: map[$0.label] ?? $0.label, remainingPercent: $0.remainingPercent, resetAt: $0.resetAt)
            }
            guard let obs = ScheduledWarmup.observation(targetID: capTarget.id, fetchedAt: stamp, windows: samples) else {
                throw AgentMCPStore.Failure.invalid("Missing observation for monthly parity test \(lang)")
            }
            let capAttempts = Attempts()
            try await ScheduledWarmup(home: capHome).tick(observations: [obs], now: now, calendar: calendar, jitter: 0) { _ in
                await capAttempts.add(lang)
            }
            let capCount = await capAttempts.count()
            try check(capCount == 0, "exhausted Codex Monthly Credit Limit blocks warmup in \(lang)")
        }

        let recHome = auditHome.appendingPathComponent("recovery-flow")
        let recSource = recHome.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: recHome, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: recSource)
        let recTarget = WarmupSettings.Target(provider: .codex, directory: recSource.path, email: "heal@example.test", accountID: "ws-heal")
        var recSettings = WarmupSettings(); recSettings.enabled = true
        recSettings.hour = calendar.component(.hour, from: now); recSettings.minute = calendar.component(.minute, from: now)
        recSettings.targets = [recTarget]
        try recSettings.save(home: recHome)
        let recStagePathFile = auditHome.appendingPathComponent("retained-stage.txt")
        let vanishCLI = auditHome.appendingPathComponent("vanish-codex.sh")
        try write("#!/bin/sh\nprintf '%s' \"$CODEX_HOME/auth.json\" > \"\(recStagePathFile.path)\"\ncat > \"$CODEX_HOME/auth.json\" <<'JSON'\n\(rotatedString)\nJSON\n/bin/rm \"\(recSource.path)\"\nexit 0\n", vanishCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vanishCLI.path)
        let recScheduler = ScheduledWarmup(home: recHome)
        var recoveryRequiredThrew = false
        var preSpawnWasThrown = false
        do {
            try await recScheduler.tick(observations: [.init(targetID: recTarget.id, fetchedAt: now, activeUntil: nil)], now: now, calendar: calendar, jitter: 0) { t in
                try await OfficialWarmupProcess.run(target: t, executable: vanishCLI.path, environment: [:])
            }
        } catch is OfficialWarmupProcess.RecoveryRequiredFailure {
            recoveryRequiredThrew = true
        } catch is OfficialWarmupProcess.PreSpawnFailure {
            preSpawnWasThrown = true
        }
        try check(recoveryRequiredThrew && !preSpawnWasThrown, "vanished source with rotated token throws RecoveryRequiredFailure")
        let recReplayAttempts = Attempts()
        try await recScheduler.tick(observations: [.init(targetID: recTarget.id, fetchedAt: repairNow, activeUntil: nil)], now: repairNow, calendar: calendar, jitter: 0) { t in
            await recReplayAttempts.add(t.id)
        }
        let recReplayCount = await recReplayAttempts.count()
        try check(recReplayCount == 0, "RecoveryRequiredFailure retains post-spawn 5h fence")
        let retainedStagePath = try String(contentsOf: recStagePathFile, encoding: .utf8)
        let retainedStageRoot = URL(fileURLWithPath: retainedStagePath).deletingLastPathComponent().deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: retainedStageRoot) }
        try check(FileManager.default.fileExists(atPath: retainedStagePath), "retained staging survives when durable saves == 0")
        let recoveryDir = recHome.appendingPathComponent("Library/Application Support/AIUsage/AuthImports/warmup-recovery")
        let dirAttrs = try FileManager.default.attributesOfItem(atPath: recoveryDir.path)
        try check((dirAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o700, "owned warmup-recovery dir uses 0700 permissions")
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: recoveryDir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
        try check(recoveryFiles.count == 1, "owned warmup-recovery stores rotated credential copy")
        let recoveryFileAttrs = try FileManager.default.attributesOfItem(atPath: recoveryFiles[0].path)
        try check((recoveryFileAttrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "owned recovery file uses 0600 permissions")
        // Restore stale source and verify next run recovers rotated token automatically from warmup-recovery.
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: recSource)
        let prestageCheckCapture = auditHome.appendingPathComponent("recovered-refresh.txt")
        let recoverVerifyCLI = auditHome.appendingPathComponent("recover-verify.sh")
        try write("#!/bin/sh\n/usr/bin/python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); open(sys.argv[2],\"w\").write(d[\"tokens\"][\"refresh_token\"])' \"$CODEX_HOME/auth.json\" \"\(prestageCheckCapture.path)\"\nexit 0\n", recoverVerifyCLI)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: recoverVerifyCLI.path)
        try await OfficialWarmupProcess.run(target: recTarget, executable: recoverVerifyCLI.path, environment: [:])
        try check((try? String(contentsOf: prestageCheckCapture, encoding: .utf8)) == "rt-rotated", "subsequent warmup recovers rotated token from owned warmup-recovery copy")

        // Round 5 (R4 P2): Reject directory/file aliases and separate copies sharing one Codex subscription/workspace.
        let dupHome = auditHome.appendingPathComponent("duplicate-identity")
        let dupCodexDir = dupHome.appendingPathComponent(".codex")
        let dupAuthFile = dupCodexDir.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: dupCodexDir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: sourceObj).write(to: dupAuthFile)
        var aliasTargets = WarmupSettings(); aliasTargets.enabled = true
        aliasTargets.targets = [
            .init(provider: .codex, directory: dupCodexDir.path, email: "heal@example.test", accountID: "ws-heal"),
            .init(provider: .codex, directory: dupAuthFile.path, email: "heal@example.test", accountID: "ws-heal")
        ]
        var dirFileAliasRejected = false
        do { try aliasTargets.save(home: dupHome) } catch { dirFileAliasRejected = true }
        try check(dirFileAliasRejected, "warmup rejects directory vs auth.json file alias for same Codex target")

        var separateCopyRejected = false
        var dupCopySettings = WarmupSettings(); dupCopySettings.enabled = true
        dupCopySettings.targets = [
            .init(provider: .codex, directory: "/fixture/copy-a/auth.json", email: "heal@example.test", accountID: "ws-heal"),
            .init(provider: .codex, directory: "/fixture/copy-b/auth.json", email: " HEAL@EXAMPLE.TEST ", accountID: " WS-HEAL ")
        ]
        do { try dupCopySettings.save(home: dupHome) } catch { separateCopyRejected = true }
        try check(separateCopyRejected, "warmup rejects separate paths sharing same Codex email and workspace (case/whitespace normalized)")

        var wildcardCollisionRejected = false
        var nilAccountSettings = WarmupSettings(); nilAccountSettings.enabled = true
        nilAccountSettings.targets = [
            .init(provider: .codex, directory: "/fixture/copy-a/auth.json", email: "heal@example.test", accountID: nil),
            .init(provider: .codex, directory: "/fixture/copy-b/auth.json", email: "heal@example.test", accountID: "ws-heal")
        ]
        do { try nilAccountSettings.save(home: dupHome) } catch { wildcardCollisionRejected = true }
        try check(wildcardCollisionRejected, "warmup rejects duplicate Codex email when workspace accountID is missing")

        var distinctWorkspaces = WarmupSettings(); distinctWorkspaces.enabled = true
        distinctWorkspaces.targets = [
            .init(provider: .codex, directory: "/fixture/ws-a/auth.json", email: "heal@example.test", accountID: "ws-a"),
            .init(provider: .codex, directory: "/fixture/ws-b/auth.json", email: "heal@example.test", accountID: "ws-b")
        ]
        try distinctWorkspaces.save(home: dupHome)
        try check((try WarmupSettings.load(home: dupHome)).targets.count == 2, "warmup allows same email across distinct workspaces and paths")
    }
    static func reviewRegressions(_ home: URL) async throws {
        let absent = home.appendingPathComponent("absent-codex")
        let engine = CallAnalyticsEngine(homeDirectory: absent.path, timeZone: .current, environment: [:])
        _ = await engine.computeSnapshot(rangeKey: "today", cutoff: Calendar.current.startOfDay(for: Date()))
        let archive = CallAnalyticsArchiveStore(homeDirectory: absent.path)
        try check(archive.fullHistoryImported, "absent Codex completes empty import rather than permanent full rescans")
        let archiveFile = CallAnalyticsArchiveStore.fileURL(homeDirectory: absent.path)
        let original = try Data(contentsOf: archiveFile)
        _ = await engine.computeSnapshot(rangeKey: "today", cutoff: Calendar.current.startOfDay(for: Date()))
        try check(try Data(contentsOf: archiveFile) == original, "second absent-source tick does not rewrite archive")

        let brain = home.appendingPathComponent(".gemini/antigravity/brain")
        let recent = brain.appendingPathComponent("recent/.system_generated/logs/transcript.jsonl")
        let old = brain.appendingPathComponent("old/.system_generated/logs/transcript.jsonl")
        let stamp = SharedFormatters.iso8601String(from: Date())
        let row = "{\"step_index\":1,\"created_at\":\"\(stamp)\",\"tool_calls\":[{\"name\":\"read_file\",\"args\":{\"Path\":\"/skills/new-skill/SKILL.md\"}},{\"name\":\"mcp_my_server_search\",\"args\":{}}]}"
        try write(row + "\n", recent); try write(row + "\n", old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 0)], ofItemAtPath: old.path)
        let source = AntigravityCallEventSource(homeDirectory: home.path, timeZone: .current)
        let today = Calendar.current.startOfDay(for: Date())
        let result = source.collect(cutoff: today, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1 && result.status.filesScanned == 1, "cutoff avoids old AGY transcript bytes")
        try check(result.entries.contains { $0.kind == .skill && $0.name == "new-skill" }, "new read_file Path skill schema")
        try check(result.entries.contains { $0.kind == .mcp && $0.server == "my_server" && $0.name == "my_server/search" }, "eager MCP uses longest configured server prefix")
        _ = source.collect(cutoff: today, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 0, "unchanged recent transcripts are cached")
        _ = source.collect(knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1, "all-history range backfills uncached old transcript")
        _ = source.collect(knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 0, "all-history refresh does not reread unchanged bytes")
        _ = source.collect(cutoff: today, rescan: true, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1, "explicit Rescan bypasses cache without bypassing selected range")
        try write(row + "\n\n", recent)
        _ = source.collect(cutoff: today, knownMCPServers: ["my", "my_server"])
        try check(source.lastFilesRead == 1, "changed transcript is reparsed")
        let reclassified = source.collect(cutoff: today, knownMCPServers: [])
        try check(source.lastFilesRead == 1 && !reclassified.entries.contains { $0.kind == .mcp }, "inventory change invalidates eager-MCP classification cache")

        // Sanitized real export schema: each argument value is independently JSON encoded.
        let encodedRow = #"{"step_index":2,"created_at":"2026-11-11T03:56:29Z","tool_calls":[{"name":"read_file","args":{"Path":"\"/skills/quoted skill/SKILL.md\""}},{"name":"call_mcp_tool","args":{"ServerName":"\"engram\"","ToolName":"\"mem_search\""}}]}"#
        try write(encodedRow + "\n", recent)
        let encoded = source.collect(rescan: true)
        try check(encoded.entries.contains { $0.kind == .skill && $0.name == "quoted skill" }, "real-export JSON-encoded Path counts skill")
        try check(encoded.entries.contains { $0.kind == .mcp && $0.name == "engram/mem_search" && $0.server == "engram" }, "real-export MCP names have no JSON quotes")

        let shell = home.appendingPathComponent(".bash_profile")
        try write("if true; then\nexport OPENAI_API_KEY='fixture'\nfi\n", shell)
        let finding = try EnvironmentOverrideDetector.scan(home: home, inherited: [:]).first { $0.file == shell }!
        let undo = try EnvironmentOverrideDetector.remove(finding)
        for executable in ["/bin/bash", "/bin/zsh"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["-n", shell.path]
            process.terminationHandler = { _ in }; try process.run(); process.waitUntilExit()
            try check(process.terminationStatus == 0, "removing sole branch assignment keeps shell syntax valid")
        }
        try undo.restore()
        try check(try String(contentsOf: shell, encoding: .utf8).contains("export OPENAI_API_KEY"), "branch removal Undo restores original assignment")

        let vault = Vault(); let store = AgentMCPStore(home: home, platform: .codex, vault: vault.service)
        try write("[mcp_servers.remote]\nurl = \"https://mcp.example.test/service\"\n[mcp_servers.local]\ncommand = \"/usr/bin/true\"\ncwd = \"/tmp\"\nenv_vars = [\"PATH\"]\n", store.configURL)
        let items = try store.items()
        try check(items.first { $0.name == "remote" }?.health == nil, "valid remote MCP is not judged by stdio-only importer")
        try check(items.first { $0.name == "local" }?.health == nil, "advanced stdio fields do not cause false health warning")
        try store.importServers([.init(name: "keychain", command: "/usr/bin/true", env: ["KEY": "fixture-only"])])
        try check(try store.items().first { $0.name == "keychain" }?.canAuthorizeKeychain == true, "managed env launcher exposes explicit foreground authorization check")
        let readers = Attempts()
        try await store.verifyKeychainAccess(name: "keychain") { args in
            guard args.count == 6, args[0] == "find-generic-password", args[2] == MCPSecretVault.service, args[5] == "-w" else { throw AgentMCPStore.Failure.invalid("Unsafe reader arguments") }
            await readers.add(args[4])
        }
        let readerCount = await readers.count()
        try check(readerCount == 1, "Keychain check calls only injected reader, never MCP command")

        let good = home.appendingPathComponent("auth/a.json"); let other = home.appendingPathComponent("auth/b.json")
        let broken = home.appendingPathComponent("auth/directory.json")
        try write(#"{"type":"codex","disabled":false}"#, good); try write(#"{"type":"codex","disabled":false}"#, other)
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        let outcome = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [good, broken, other], shouldTrip: true, reason: "fixture")
        try check(try object(good)["disabled"] as? Bool == true && object(other)["disabled"] as? Bool == true, "Codex protection continues after one target fails")
        try check(outcome?.tripped == true && outcome?.error != nil, "partial protection reports error rather than nil/full success")
        let failed = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: [broken], shouldTrip: true, reason: "fixture")
        try check(failed?.tripped == false && failed?.error != nil, "total protection failure is visible and does not claim paused")

        try check(failed?.error?.contains("could not update any target") == true, "total failure never implies partial protection")
        try check(outcome?.error?.contains("updated only part") == true, "partial protection message stays distinct")

        let cpaAuth = home.appendingPathComponent("Library/Application Support/AIUsage/CLIProxyAPI/auth")
        let workspaceA = cpaAuth.appendingPathComponent("aiusage-codex-a.json")
        let workspaceB = cpaAuth.appendingPathComponent("aiusage-codex-b.json")
        try write(#"{"type":"codex","email":"shared@example.test","account_id":"workspace-a","user_id":"user-a"}"#, workspaceA)
        try write(#"{"type":"codex","email":"shared@example.test","account_id":"workspace-b","user_id":"user-a"}"#, workspaceB)
        let targets = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(providerPrefix: "codex", email: "shared@example.test", currentFileURL: workspaceA, homeDirectory: home.path)
        try check(targets == [workspaceA], "same-email breaker targeting respects Codex workspace identity")
        _ = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: targets, shouldTrip: true, reason: "fixture workspace A")
        try check(try object(workspaceA)["disabled"] as? Bool == true && object(workspaceB)["disabled"] == nil, "depleted workspace never disables healthy sibling workspace")
        let unknown = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(providerPrefix: "codex", email: "shared@example.test", currentFileURL: nil, homeDirectory: home.path)
        try check(unknown.isEmpty, "Codex breaker refuses email-only identity")
        let staleSource = QuotaCircuitBreakerHelper.findTargetCPAAuthFiles(providerPrefix: "codex", email: "shared@example.test", currentFileURL: workspaceA, homeDirectory: home.path,
            codexIdentity: .init(accountId: "workspace-b", userId: "user-a", email: "shared@example.test"))
        try check(!staleSource.contains(workspaceA), "explicit fetched identity guards current path reused by another workspace")

        try write(#"{"type":"codex","email":"shared@example.test","account_id":"workspace-replaced","user_id":"user-a"}"#, workspaceA)
        let replaced = QuotaCircuitBreakerHelper.syncCircuitBreaker(targets: targets, shouldTrip: true, reason: "stale snapshot",
            codexIdentity: .init(accountId: "workspace-a", userId: "user-a", email: "shared@example.test"))
        try check(try object(workspaceA)["disabled"] == nil && replaced?.error != nil, "protection rejects account switched after target discovery")

        let claude = WeeklyResetPriority.Observation(provider: "claude-subscription", email: "fixture", reset: Date().addingTimeInterval(100))
        try check(claude.provider == "claude", "Claude subscription provider maps to CPA auth type")
        let claudeA = home.appendingPathComponent("claude-auth/a.json"); let claudeB = home.appendingPathComponent("claude-auth/b.json")
        try write(#"{"type":"claude","email":"fixture"}"#, claudeA); try write(#"{"type":"claude","email":"later"}"#, claudeB)
        try WeeklyResetPriority.sync(authDirectory: claudeA.deletingLastPathComponent(), enabled: true, observations: [claude,
            .init(provider: "claude-subscription", email: "later", reset: Date().addingTimeInterval(1000))])
        try check((try object(claudeA)["priority"] as! Int) > (try object(claudeB)["priority"] as! Int), "Claude observations reach real CPA priority ordering")

        let edited = claudeA
        var editedJSON = try object(edited); editedJSON["priority"] = 7
        try JSONSerialization.data(withJSONObject: editedJSON).write(to: edited)
        try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(edited)["priority"] as? Int == 7 && object(edited)["aiusage_weekly_priority"] == nil, "disabling preserves external priority and relinquishes stale marker")
        try check(try object(claudeB)["priority"] == nil && object(claudeB)["aiusage_weekly_priority"] == nil, "external edit does not prevent other account cleanup")
        try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: true, observations: [claude])
        for value in [500, 1500, -1500, 9] {
            editedJSON = try object(edited); editedJSON["priority"] = value
            try JSONSerialization.data(withJSONObject: editedJSON).write(to: edited)
            for _ in 0..<3 {
                try checkExternalPriorityWarning {
                    try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: true, observations: [claude])
                }
                try check(try object(edited)["priority"] as? Int == value, "repeated sync never rescales external effective priority \(value)")
            }
            try check(try object(claudeB)["aiusage_weekly_priority"] != nil, "external override does not block other accounts")
        }
        try WeeklyResetPriority.sync(authDirectory: edited.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(edited)["priority"] as? Int == 9 && object(edited)["aiusage_weekly_priority"] == nil, "Off retains external override and clears ownership fence")
        let orderA = home.appendingPathComponent("effective-order/a.json")
        let orderB = home.appendingPathComponent("effective-order/b.json")
        try write(#"{"type":"claude","email":"fixture"}"#, orderA)
        try write(#"{"type":"claude","email":"later"}"#, orderB)
        let orderObservations = [claude, WeeklyResetPriority.Observation(provider: "claude", email: "later", reset: Date().addingTimeInterval(1000))]
        try WeeklyResetPriority.sync(authDirectory: orderA.deletingLastPathComponent(), enabled: true, observations: orderObservations)
        try check(try object(orderA)["priority"] as? Int == 999 && object(orderB)["priority"] as? Int == 998, "review repro starts with effective priorities 999 and 998")
        var effective = try object(orderA); effective["priority"] = 500
        let effectiveBytes = try JSONSerialization.data(withJSONObject: effective)
        try effectiveBytes.write(to: orderA)
        for _ in 0..<3 {
            try write(#"{"type":"claude","email":"later"}"#, orderB)
            try checkExternalPriorityWarning {
                try WeeklyResetPriority.sync(authDirectory: orderA.deletingLastPathComponent(), enabled: true, observations: orderObservations)
            }
            try check(try object(orderA)["priority"] as? Int == 500 && object(orderB)["priority"] as? Int == 998, "manual 500 remains below peer 998 on repeated refresh")
            try check(try Data(contentsOf: orderA) == effectiveBytes, "external override is byte-for-byte untouched while enabled")
        }
        try WeeklyResetPriority.sync(authDirectory: orderA.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(orderA)["priority"] as? Int == 500 && object(orderA)["aiusage_weekly_priority"] == nil, "Off preserves manual effective priority and clears marker without throwing")
        try check(try object(orderB)["priority"] == nil && object(orderB)["aiusage_weekly_priority"] == nil, "Off restores managed peer; relative order may change as warned")
        let tiered = home.appendingPathComponent("large-tier/a.json")
        try write(#"{"type":"claude","email":"fixture","priority":2000}"#, tiered)
        try WeeklyResetPriority.sync(authDirectory: tiered.deletingLastPathComponent(), enabled: true, observations: [claude])
        try check(try object(tiered)["priority"] as? Int == 2_000_999, "legitimate large original tier is not guessed to be an overlay")
        try WeeklyResetPriority.sync(authDirectory: tiered.deletingLastPathComponent(), enabled: false, observations: [])
        try check(try object(tiered)["priority"] as? Int == 2000, "large original priority restored exactly")

        try check(QuotaBurnRate.windowDuration(label: "Gemini · Weekly") == 7 * 86400 && QuotaBurnRate.windowDuration(label: "每周窗口") == 7 * 86400 && QuotaBurnRate.windowDuration(label: "7 天") == 7 * 86400, "weekly classification covers EN and ZH")
        try check(QuotaBurnRate.windowDuration(label: "5 小时") == 5 * 3600, "five-hour classification covers localized labels")
        try check(SharedFormatters.parseISO8601("2026-11-11T07:00:00.123Z") != nil, "shared parser retains fractional reset precision")
        let policy = home.appendingPathComponent("state.json")
        try write(#"{"version":1,"settings":{"routingStrategy":"round-robin"}}"#, policy)
        let snapshot = try Data(contentsOf: good)
        try await WeeklyResetPriorityWorker().sync(authDirectory: good.deletingLastPathComponent(), policyURL: policy, observations: [claude])
        try check(try Data(contentsOf: good) == snapshot, "background worker rechecks Off policy inside credential lock")

        let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let plist = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Info.plist"), encoding: .utf8)
        try check(plist.contains("<string>0.16.1</string>"), "Info.plist version bumped to 0.16.1")
        let pbxproj = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage.xcodeproj/project.pbxproj"), encoding: .utf8)
        try check(pbxproj.contains("MARKETING_VERSION = 0.16.1;"), "pbxproj MARKETING_VERSION bumped to 0.16.1")
        try check(pbxproj.contains("ModelAutoSyncCoordinator.swift"), "pbxproj includes ModelAutoSyncCoordinator.swift")
        let appSettings = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Models/AppSettings.swift"), encoding: .utf8)
        try check(
            appSettings.contains("UserDefaults.standard.object(forKey: DefaultsKey.showSponsorSpot) as? Bool ?? false"),
            "AppSettings defaults showSponsorSpot to false"
        )
        let menuBar = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Views/MenuBarView.swift"), encoding: .utf8)
        try check(menuBar.contains("TokenSaverMenuBarSection(onOpenSettings: openTokenSaverSettings)"), "MenuBarView preserves TokenSaverMenuBarSection")
        try check(menuBar.contains("quotaSection"), "MenuBarView preserves collapsible quotaSection")
        try check(
            menuBar.contains("AgentVisibility.isQuotaAccount(providerId: $0.baseProviderId, category: $0.category)"),
            "MenuBarView quotaCollapsedSummary preserves isQuotaAccount filter"
        )
        let viStrings = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Resources/vi.lproj/Localizable.strings"), encoding: .utf8)
        try check(viStrings.contains("\"Auto-sync models & prices\" ="), "vi Localizable.strings includes v0.16.1 keys")
        try check(viStrings.contains("\"Pace: steady\" =") && viStrings.contains("\"Active account in Antigravity IDE\" ="),
                  "vi Localizable.strings includes active Antigravity and burn-rate copy")
        try check(viStrings.contains("\"past projected limit\" ="),
                  "vi Localizable.strings includes past projected limit copy")

        let activationManagerSrc = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/ViewModels/ProviderActivationManager.swift"), encoding: .utf8)
        try check(activationManagerSrc.contains(#"static let activatableProviders: Set<String> = ["codex", "gemini"]"#),
                  "ProviderActivationManager keeps antigravity out of activatableProviders (no 1-click IDE switch)")
        try check(activationManagerSrc.contains(#"static let activeAccountDetectionProviders: Set<String> = ["codex", "gemini", "antigravity"]"#),
                  "ProviderActivationManager allows active-account display for antigravity")
        let providerCardSrc = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Views/ProviderCard.swift"), encoding: .utf8)
        let menuRowSrc = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Views/MenuBarAccountRow.swift"), encoding: .utf8)
        let groupSectionSrc = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Views/ProviderAccountGroupSection.swift"), encoding: .utf8)
        try check(providerCardSrc.contains("activationManager.canDisplayActiveAccount(provider.providerId)"),
                  "ProviderCard gates active indicator on canDisplayActiveAccount rather than canActivateProvider")
        try check(menuRowSrc.contains("activationManager.canDisplayActiveAccount(providerId)"),
                  "MenuBarAccountRow gates active badge on canDisplayActiveAccount rather than canActivateProvider")
        try check(groupSectionSrc.contains("if group.providerId == \"antigravity\"")
                  && groupSectionSrc.contains("activationManager.detectActiveAntigravityAccount()")
                  && !groupSectionSrc.contains("detectActiveCodexAccount")
                  && !groupSectionSrc.contains("detectActiveGeminiAccount"),
                  "ProviderAccountGroupSection Refresh App only re-detects antigravity (no Codex proxy active overwrite)")

        // Verify legacy v1 call archive fixtures still migrate cleanly when written to call-analytics-archive-v1.json.
        let fm = FileManager.default
        let utc = TimeZone(secondsFromGMT: 0)!
        let claudeLegacyRoot = home.appendingPathComponent("master-claude-v1-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: claudeLegacyRoot) }
        let claudeDay = "2026-01-02"
        let claudeOld = CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Read", server: nil, agent: "main", dayKey: claudeDay, count: 3)
        let claudeLegacyArchive = CallAnalyticsArchive(
            version: 1, updatedAt: "", fullHistoryImportedAt: "done",
            days: [claudeDay: CallAnalyticsDayBucket(entries: [claudeOld], agentInvocations: [AgentInvocationCount(source: .claude, agent: "main", count: 3)])]
        )
        try write(String(decoding: JSONEncoder().encode(claudeLegacyArchive), as: UTF8.self), CallAnalyticsArchiveStore.fileURL(homeDirectory: claudeLegacyRoot.path, version: 1))
        let claudeRow = try JSONSerialization.data(withJSONObject: [
            "type": "assistant", "timestamp": "\(claudeDay)T12:00:00Z",
            "message": [
                "id": "existing", "model": "claude-sonnet",
                "content": [["type": "tool_use", "id": "tool-existing", "name": "Read", "input": [:]]],
                "usage": ["input_tokens": 10, "output_tokens": 5, "cache_read_input_tokens": 20, "cache_creation_input_tokens": 3]
            ]
        ])
        var claudeBody = claudeRow; claudeBody.append(0x0A)
        let claudeSession = claudeLegacyRoot.appendingPathComponent(".claude/projects/test/session.jsonl")
        try fm.createDirectory(at: claudeSession.deletingLastPathComponent(), withIntermediateDirectories: true)
        try claudeBody.write(to: claudeSession)
        for _ in 0..<2 {
            let snap = await CallAnalyticsEngine(homeDirectory: claudeLegacyRoot.path, timeZone: utc, environment: [:]).computeSnapshot(rangeKey: "all", cutoff: nil)
            try check(snap.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count } == 3, "legacy v1 Claude residual keeps total calls = 3")
            try check(snap.agentInvocations.filter { $0.source == .claude }.reduce(0) { $0 + $1.count } == 3, "legacy v1 Claude residual keeps agent invocations = 3")
        }

        let ocLegacyRoot = home.appendingPathComponent("master-opencode-v1-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: ocLegacyRoot) }
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let ocMillis = Int64(cal.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!.timeIntervalSince1970 * 1000)
        let ocArchive = CallAnalyticsArchive(
            version: 1, updatedAt: "", fullHistoryImportedAt: "2026-01-05T00:00:00Z",
            days: ["2026-01-10": CallAnalyticsDayBucket(entries: [
                CallAnalyticsEntry(source: .opencode, kind: .builtin, name: "bash", server: nil, dayKey: "2026-01-10", count: 2, outcomeKnownCount: 2, successCount: 2),
                CallAnalyticsEntry(source: .opencode, kind: .builtin, name: "read", server: nil, dayKey: "2026-01-10", count: 1, outcomeKnownCount: 1, successCount: 1)
            ], agentInvocations: [])]
        )
        try write(String(decoding: JSONEncoder().encode(ocArchive), as: UTF8.self), CallAnalyticsArchiveStore.fileURL(homeDirectory: ocLegacyRoot.path, version: 1))
        let xdg = ocLegacyRoot.appendingPathComponent("xdg", isDirectory: true)
        let ocDBDir = xdg.appendingPathComponent("opencode", isDirectory: true)
        try fm.createDirectory(at: ocDBDir, withIntermediateDirectories: true)
        let ocDBPath = ocDBDir.appendingPathComponent("opencode.db").path
        var ocDB: OpaquePointer?
        try check(sqlite3_open_v2(ocDBPath, &ocDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, "open opencode regression db")
        defer { if let ocDB { sqlite3_close(ocDB) } }
        let ocPart = #"{"type":"tool","tool":"bash","state":{"status":"completed"}}"#
        try check(sqlite3_exec(ocDB, "CREATE TABLE part (id TEXT, time_created INTEGER, data TEXT); INSERT INTO part VALUES ('part_1', \(ocMillis), '\(ocPart)');", nil, nil, nil) == SQLITE_OK, "seed opencode regression db")
        let ocEngine = CallAnalyticsEngine(homeDirectory: ocLegacyRoot.path, timeZone: utc, environment: ["XDG_DATA_HOME": xdg.path])
        let ocFirst = await ocEngine.computeSnapshot(rangeKey: "all", cutoff: nil)
        try check(ocFirst.entries.filter { $0.name == "bash" }.reduce(0) { $0 + $1.count } == 2, "legacy v1 OpenCode preserves bash=2")
        try check(ocFirst.entries.filter { $0.name == "read" }.reduce(0) { $0 + $1.count } == 1, "legacy v1 OpenCode preserves read=1")
        try check(sqlite3_exec(ocDB, "INSERT INTO part VALUES ('part_2', \(Int64(Date().timeIntervalSince1970 * 1000)), '\(ocPart)');", nil, nil, nil) == SQLITE_OK, "append post-migration opencode call")
        let ocSecond = await ocEngine.computeSnapshot(rangeKey: "all", cutoff: nil)
        try check(ocSecond.entries.filter { $0.name == "bash" }.reduce(0) { $0 + $1.count } == 3, "post-migration OpenCode increments bash=3")
        try check(ocSecond.entries.filter { $0.name == "read" }.reduce(0) { $0 + $1.count } == 1, "post-migration OpenCode retains deleted read=1")

        // AntigravityCostProvider in-memory transcript scan cache
        let cacheRoot = home.appendingPathComponent("master-agy-scan-cache-\(UUID())", isDirectory: true)
        defer { try? fm.removeItem(at: cacheRoot) }
        let brainA = cacheRoot.appendingPathComponent("brain", isDirectory: true)
        let brainSibling = cacheRoot.appendingPathComponent("brain2", isDirectory: true)
        let tokenFile = brainA.appendingPathComponent("conv-tok/.system_generated/logs/transcript.jsonl").path
        let emptyFile = brainA.appendingPathComponent("conv-empty/.system_generated/logs/transcript.jsonl").path
        let siblingFile = brainSibling.appendingPathComponent("conv-sib/.system_generated/logs/transcript.jsonl").path
        let line1 = #"{"type":"PLANNER_RESPONSE","created_at":"2026-11-21T23:30:00Z","input_tokens":100,"output_tokens":20,"cache_read_tokens":30}"# + "\n"
        try write(line1, URL(fileURLWithPath: tokenFile))
        try write(#"{"type":"USER_INPUT","content":"hi"}"# + "\n", URL(fileURLWithPath: emptyFile))
        try write(line1, URL(fileURLWithPath: siblingFile))

        final class ScanCount: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []
            func record(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
            var count: Int { lock.lock(); defer { lock.unlock() }; return paths.count }
            var last: String? { lock.lock(); defer { lock.unlock() }; return paths.last }
        }
        let tzPlus7 = TimeZone(secondsFromGMT: 7 * 3600)!
        let tzMinus8 = TimeZone(secondsFromGMT: -8 * 3600)!
        let p7 = AntigravityCostProvider(homeDirectory: cacheRoot.path, timeZone: tzPlus7)
        let pMinus8 = AntigravityCostProvider(homeDirectory: cacheRoot.path, timeZone: tzMinus8)
        let sc = ScanCount()
        let parse7: @Sendable (String) -> [String: CodexAggregateBucket]? = { path in
            sc.record(path)
            return p7.processFile(path)
        }
        let parseMinus8: @Sendable (String) -> [String: CodexAggregateBucket]? = { path in
            sc.record(path)
            return pMinus8.processFile(path)
        }
        let c1 = await p7.scanFilesByPathCached([tokenFile, emptyFile], brainDirectory: brainA.path, parseFile: parse7)
        try check(sc.count == 2 && c1.keys.sorted() == [tokenFile] && c1[tokenFile]?["2026-11-22"]?.totalTokens == 150,
                  "AntigravityCost cache cold scan parses both files and omits empty")
        let c2 = await p7.scanFilesByPathCached([tokenFile, emptyFile], brainDirectory: brainA.path, parseFile: parse7)
        try check(sc.count == 2 && c2[tokenFile]?["2026-11-22"]?.totalTokens == 150,
                  "AntigravityCost cache unchanged rescan parses 0 files")
        let line2 = #"{"type":"PLANNER_RESPONSE","created_at":"2026-11-21T23:31:00Z","input_tokens":50,"output_tokens":10,"cache_read_tokens":0}"# + "\n"
        try write(line1 + line2, URL(fileURLWithPath: tokenFile))
        let c3 = await p7.scanFilesByPathCached([tokenFile, emptyFile], brainDirectory: brainA.path, parseFile: parse7)
        try check(sc.count == 3 && sc.last == tokenFile && c3[tokenFile]?["2026-11-22"]?.totalTokens == 210,
                  "AntigravityCost cache invalidates only modified file")
        let cTz = await pMinus8.scanFilesByPathCached([tokenFile], parseFile: parseMinus8)
        try check(sc.count == 4 && cTz[tokenFile]?["2026-11-21"]?.totalTokens == 210 && cTz[tokenFile]?["2026-11-22"] == nil,
                  "AntigravityCost cache isolates TimeZone day keys")
        _ = await p7.scanFilesByPathCached([tokenFile], parseFile: parse7)
        _ = await p7.scanFilesByPathCached([siblingFile], brainDirectory: brainSibling.path, parseFile: parse7)
        try check(sc.count == 6, "AntigravityCost cache warms tzPlus7 + sibling brain2")
        _ = await p7.scanFilesByPathCached([emptyFile], brainDirectory: brainA.path, parseFile: parse7)
        _ = await p7.scanFilesByPathCached([siblingFile], brainDirectory: brainSibling.path, parseFile: parse7)
        try check(sc.count == 6, "AntigravityCost cache prefix pruning preserves sibling brain2")
        let cPruned = await p7.scanFilesByPathCached([tokenFile], brainDirectory: brainA.path, parseFile: parse7)
        try check(sc.count == 7 && cPruned[tokenFile]?["2026-11-22"]?.totalTokens == 210,
                  "AntigravityCost cache reparses dropped file after pruning")

        // [§6.1] Unreadable transcript (000 -> 600 chmod) must not be cached as empty, including end-to-end fetchUsage()
        let recentISO = SharedFormatters.iso8601String(from: Date())
        let line42 = #"{"type":"PLANNER_RESPONSE","created_at":"\#(recentISO)","input_tokens":30,"output_tokens":12,"cache_read_tokens":0}"# + "\n"
        let permHome = cacheRoot.appendingPathComponent("perm-home", isDirectory: true)
        let permFileURL = permHome.appendingPathComponent(".gemini/antigravity/brain/conv-perm/.system_generated/logs/transcript.jsonl")
        try write(line42, permFileURL)
        if ProcessInfo.processInfo.userName != "root" {
            try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: permFileURL.path)
            defer { try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permFileURL.path) }
            let permProvider = AntigravityCostProvider(homeDirectory: permHome.path, timeZone: tzPlus7)
            var threwNoUsage = false
            do {
                _ = try await permProvider.fetchUsage()
            } catch let err as ProviderError where err.code == "no_usage_data" {
                threwNoUsage = true
            }
            try check(threwNoUsage, "[§6.1] fetchUsage reports no_usage_data while transcript is 000")
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: permFileURL.path)
            let recoveredUsage = try await permProvider.fetchUsage()
            try check((recoveredUsage.extra["overall.totalTokens"]?.value as? Int) == 42,
                      "[§6.1] fetchUsage recovers all 42 tokens after 000 -> 600 without content/mtime/inode change")

            let permScanCount = sc.count
            let hitAfterRecover = await permProvider.scanFilesByPathCached(
                [permFileURL.path],
                brainDirectory: permHome.appendingPathComponent(".gemini/antigravity/brain").path,
                parseFile: parse7
            )
            try check(sc.count == permScanCount && hitAfterRecover[permFileURL.path]?.values.reduce(0) { $0 + $1.totalTokens } == 42,
                      "[§6.1] recovered file stays cached on subsequent scan")
        }

        // [§6.2] Symlink transcript tracks resolved target stamp (42 -> 84 tokens) while keeping canonical symlink key
        let symHome = cacheRoot.appendingPathComponent("sym-home", isDirectory: true)
        let symTarget = cacheRoot.appendingPathComponent("external-transcript-target.jsonl")
        let symTranscript = symHome.appendingPathComponent(".gemini/antigravity/brain/conv-sym/.system_generated/logs/transcript.jsonl")
        try fm.createDirectory(at: symTranscript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try write(line42, symTarget)
        try fm.createSymbolicLink(atPath: symTranscript.path, withDestinationPath: symTarget.path)
        let symProvider = AntigravityCostProvider(homeDirectory: symHome.path, timeZone: tzPlus7)
        let symUsage1 = try await symProvider.fetchUsage()
        try check((symUsage1.extra["overall.totalTokens"]?.value as? Int) == 42,
                  "[§6.2] symlink transcript initially reads 42 tokens")
        try write(line42 + line42, symTarget)
        let symUsage2 = try await symProvider.fetchUsage()
        try check((symUsage2.extra["overall.totalTokens"]?.value as? Int) == 84,
                  "[§6.2] updating symlink target from 42 -> 84 invalidates cache despite unchanged symlink lstat")
        let symCached = await symProvider.scanFilesByPathCached(
            [symTranscript.path],
            brainDirectory: symHome.appendingPathComponent(".gemini/antigravity/brain").path
        )
        try check(symCached[symTranscript.path]?.values.reduce(0) { $0 + $1.totalTokens } == 84,
                  "[§6.2] symlink cache result remains keyed by canonical transcript path")

        // [§6.4] SettingsView Launch at Login stays disabled until async hydration completes
        let settingsSrc = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Views/SettingsView.swift"), encoding: .utf8)
        let settingsCardsSrc = try String(contentsOf: repoRoot.appendingPathComponent("AIUsage/Views/SettingsView+Cards.swift"), encoding: .utf8)
        try check(
            settingsSrc.contains("@State var isLaunchAtLoginLoaded = false")
                && settingsSrc.contains("guard !Task.isCancelled, !isLaunchAtLoginLoaded else { return }")
                && settingsSrc.contains("guard isLaunchAtLoginLoaded else { return }")
                && !settingsSrc.contains("didModifyLaunchAtLogin")
                && settingsCardsSrc.contains(".disabled(!isLaunchAtLoginLoaded)"),
            "[§6.4] SettingsView gates Launch at Login toggle and setter behind isLaunchAtLoginLoaded"
        )
        func extractBlock(_ src: String, marker: String) throws -> String {
            guard let start = src.range(of: marker)?.lowerBound,
                  let openBrace = src[start...].firstIndex(of: "{") else {
                throw AgentMCPStore.Failure.invalid("Missing SettingsView marker: \(marker)")
            }
            var depth = 0
            var idx = openBrace
            while idx < src.endIndex {
                let ch = src[idx]
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(src[start...idx])
                    }
                }
                idx = src.index(after: idx)
            }
            throw AgentMCPStore.Failure.invalid("Unterminated SettingsView block: \(marker)")
        }
        let taskBlock = try extractBlock(settingsSrc, marker: ".task {")
        let taskBodyStart = taskBlock.index(after: taskBlock.firstIndex(of: "{")!)
        let taskBodyEnd = taskBlock.index(before: taskBlock.endIndex)
        let taskBody = String(taskBlock[taskBodyStart..<taskBodyEnd])
        let setterBlock = try extractBlock(settingsSrc, marker: "func setLaunchAtLogin(_ newValue: Bool)")
        let harnessSrc = """
        import Foundation

        enum SMAppService {
            enum Status { case enabled, notRegistered }
            final class FakeMainApp: @unchecked Sendable {
                private let lock = NSLock()
                private let statusReadStarted = DispatchSemaphore(value: 0)
                private let statusReadMayFinish = DispatchSemaphore(value: 0)
                var currentStatus: Status = .enabled
                var registerCount = 0
                var unregisterCount = 0
                var status: Status {
                    statusReadStarted.signal()
                    precondition(statusReadMayFinish.wait(timeout: .now() + 10) == .success,
                                 "test did not release the pending status read")
                    return lock.withLock { currentStatus }
                }
                func waitForStatusRead() async -> Bool {
                    await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .userInitiated).async { [self] in
                            continuation.resume(returning: statusReadStarted.wait(timeout: .now() + 10) == .success)
                        }
                    }
                }
                func finishStatusRead() { statusReadMayFinish.signal() }
                func register() throws {
                    lock.withLock {
                        registerCount += 1
                        currentStatus = .enabled
                    }
                }
                func unregister() throws {
                    lock.withLock {
                        unregisterCount += 1
                        currentStatus = .notRegistered
                    }
                }
            }
            static let mainApp = FakeMainApp()
        }

        @MainActor
        final class LaunchAtLoginHarness {
            var launchAtLogin = false
            var isLaunchAtLoginLoaded = false

            func runHydrationTask() async {
        \(taskBody)
            }

        \(setterBlock)
        }

        @main
        struct LaunchAtLoginFixtureMain {
            @MainActor static func main() async throws {
                let harness = LaunchAtLoginHarness()
                let hydrate = Task { @MainActor in
                    await harness.runHydrationTask()
                }
                let statusReadStarted = await SMAppService.mainApp.waitForStatusRead()
                precondition(statusReadStarted, "hydration must start reading the OS status")
                precondition(!harness.isLaunchAtLoginLoaded, "toggle must stay disabled while SMAppService read is pending")
                harness.setLaunchAtLogin(!harness.launchAtLogin)
                precondition(SMAppService.mainApp.registerCount == 0 && SMAppService.mainApp.unregisterCount == 0,
                             "pre-hydration click must never call register/unregister")
                SMAppService.mainApp.finishStatusRead()
                await hydrate.value
                precondition(harness.isLaunchAtLoginLoaded && harness.launchAtLogin,
                             "hydration populates authoritative enabled OS status and unlocks toggle")
                harness.setLaunchAtLogin(!harness.launchAtLogin)
                precondition(SMAppService.mainApp.registerCount == 0 && SMAppService.mainApp.unregisterCount == 1 && !harness.launchAtLogin,
                             "first click after hydration calls unregister() instead of register()")
            }
        }
        """
        let harnessFile = cacheRoot.appendingPathComponent("LaunchAtLoginHarness.swift")
        let harnessBin = cacheRoot.appendingPathComponent("LaunchAtLoginHarness")
        try write(harnessSrc, harnessFile)
        let compileProc = Process()
        compileProc.executableURL = URL(fileURLWithPath: "/usr/bin/swiftc")
        compileProc.arguments = ["-parse-as-library", "-swift-version", "5", harnessFile.path, "-o", harnessBin.path]
        try compileProc.run()
        compileProc.waitUntilExit()
        try check(compileProc.terminationStatus == 0, "[§6.4] extracted Launch at Login fixture compiles")
        let runProc = Process()
        runProc.executableURL = harnessBin
        try runProc.run()
        runProc.waitUntilExit()
        try check(runProc.terminationStatus == 0, "[§6.4] extracted Launch at Login fixture passes delayed OS-enabled hydration & first-click unregister")

        // [§12.1] Revision-fenced auxiliary write enforces stale-revision rejection & failure rollback inside AccountCredentialStore lock
        let auxKey = "providerAccounts.registry"
        var vaultBytes: Data?
        var auxWriteCount = 0
        var failAuxWrite = false
        let makeAuxStore: () -> AccountCredentialStore = {
            AccountCredentialStore(
                readVaultData: { vaultBytes },
                writeVaultData: { data in
                    auxWriteCount += 1
                    if failAuxWrite {
                        throw CredentialStoreError.keychainWriteFailed(-25291)
                    }
                    vaultBytes = data
                }
            )
        }
        let auxStore = makeAuxStore()
        let auxRev2 = Data("rev-2".utf8)
        let auxRev1 = Data("rev-1".utf8)
        let auxRev3 = Data("rev-3".utf8)
        try check(
            try auxStore.saveAuxiliaryData(auxRev2, forKey: auxKey, revision: 2) == .committed
                && auxWriteCount == 1
                && auxStore.committedAuxiliaryRevision(forKey: auxKey) == 2,
            "[§12.1] revision 2 auxiliary write commits once and advances committed revision"
        )
        try check(
            try auxStore.saveAuxiliaryData(auxRev1, forKey: auxKey, revision: 1)
                == .superseded(committedRevision: 2, committedData: auxRev2)
                && auxWriteCount == 1
                && auxStore.loadAuxiliaryData(forKey: auxKey) == auxRev2,
            "[§12.1] older revision 1 returns superseded inside vault lock without physical write"
        )
        failAuxWrite = true
        var rev3Threw = false
        do { _ = try auxStore.saveAuxiliaryData(auxRev3, forKey: auxKey, revision: 3) } catch { rev3Threw = true }
        try check(
            rev3Threw
                && auxStore.committedAuxiliaryRevision(forKey: auxKey) == 2
                && auxStore.loadAuxiliaryData(forKey: auxKey) == auxRev2,
            "[§12.1] failed revision 3 rolls back cached auxiliary blob and preserves committed revision 2"
        )
        failAuxWrite = false
        try check(
            try auxStore.saveAuxiliaryData(auxRev3, forKey: auxKey, revision: 3) == .committed
                && auxWriteCount == 3
                && auxStore.committedAuxiliaryRevision(forKey: auxKey) == 3
                && makeAuxStore().loadAuxiliaryData(forKey: auxKey) == auxRev3,
            "[§12.1] retried revision 3 commits and persists across fresh store reopen"
        )

        // [§14.1] Transient vault read failure followed by recovery preserves existing credentials on saveAuxiliaryData / saveCredential
        var recoveredVaultBytes: Data?
        let seedStore = AccountCredentialStore(
            readVaultData: { recoveredVaultBytes },
            writeVaultData: { recoveredVaultBytes = $0 }
        )
        let seededCred1 = AccountCredential(
            id: "seeded-codex-1",
            providerId: "codex",
            accountLabel: "seeded1@example.invalid",
            authMethod: .authFile,
            credential: "/tmp/sec14-seeded-1/auth.json",
            metadata: ["accountId": "acct-sec14-1", "workspaceUserId": "user-sec14-1"]
        )
        let seededCred2 = AccountCredential(
            id: "seeded-codex-2",
            providerId: "codex",
            accountLabel: "seeded2@example.invalid",
            authMethod: .authFile,
            credential: "/tmp/sec14-seeded-2/auth.json",
            metadata: ["accountId": "acct-sec14-2", "workspaceUserId": "user-sec14-2"]
        )
        try seedStore.saveCredential(seededCred1)

        var sec14ReadCount = 0
        var sec14WriteCount = 0
        var sec14FailReads: Set<Int> = [1]
        let makeRecoveryStore: () -> AccountCredentialStore = {
            AccountCredentialStore(
                readVaultData: {
                    sec14ReadCount += 1
                    if sec14FailReads.contains(sec14ReadCount) {
                        throw CredentialStoreError.keychainReadFailed(-25308)
                    }
                    return recoveredVaultBytes
                },
                writeVaultData: { data in
                    sec14WriteCount += 1
                    recoveredVaultBytes = data
                }
            )
        }
        let makeCleanReader: () -> AccountCredentialStore = {
            AccountCredentialStore(readVaultData: { recoveredVaultBytes }, writeVaultData: { _ in })
        }

        // Case 1: Prior read fails (#1), versioned saveAuxiliaryData recovers on read (#2) and preserves seededCred1
        let rev7Blob = Data("rev-7".utf8)
        let case1Store = makeRecoveryStore()
        try check(
            case1Store.loadAuxiliaryData(forKey: auxKey) == nil && sec14ReadCount == 1 && sec14WriteCount == 0,
            "[§14.1] initial failed read returns nil with zero writes"
        )
        try check(
            try case1Store.saveAuxiliaryData(rev7Blob, forKey: auxKey, revision: 7) == .committed
                && sec14ReadCount == 2
                && sec14WriteCount == 1
                && case1Store.committedAuxiliaryRevision(forKey: auxKey) == 7,
            "[§14.1] versioned saveAuxiliaryData recovers on second read and commits rev 7"
        )
        let reopenedAfterCase1 = makeCleanReader()
        try check(
            reopenedAfterCase1.loadAllCredentials().map(\.id) == ["seeded-codex-1"]
                && reopenedAfterCase1.loadAuxiliaryData(forKey: auxKey) == rev7Blob,
            "[§14.1] fresh reopen preserves seeded-codex-1 and rev 7 registry blob after read recovery"
        )

        // Case 2: Direct saveAuxiliaryData fails closed on read (#1) with 0 writes, then succeeds on retry (#2)
        sec14ReadCount = 0
        sec14WriteCount = 0
        sec14FailReads = [1]
        let rev8Blob = Data("rev-8".utf8)
        let case2Store = makeRecoveryStore()
        var case2ThrewUnavailable = false
        do {
            _ = try case2Store.saveAuxiliaryData(rev8Blob, forKey: auxKey, revision: 8)
        } catch CredentialStoreError.vaultUnavailable {
            case2ThrewUnavailable = true
        }
        try check(
            case2ThrewUnavailable
                && sec14ReadCount == 1
                && sec14WriteCount == 0
                && case2Store.committedAuxiliaryRevision(forKey: auxKey) == nil
                && makeCleanReader().loadAllCredentials().map(\.id) == ["seeded-codex-1"],
            "[§14.1] failed read throws vaultUnavailable with 0 writes and preserves seeded credential"
        )
        try check(
            try case2Store.saveAuxiliaryData(rev8Blob, forKey: auxKey, revision: 8) == .committed
                && sec14ReadCount == 2
                && sec14WriteCount == 1
                && makeCleanReader().loadAllCredentials().map(\.id) == ["seeded-codex-1"]
                && makeCleanReader().loadAuxiliaryData(forKey: auxKey) == rev8Blob,
            "[§14.1] retry saveAuxiliaryData after read failure preserves seeded-codex-1 and commits rev 8"
        )

        // Case 3: Unversioned saveAuxiliaryData & saveCredential preserve credentials after failed read; continuous errors never write
        sec14ReadCount = 0
        sec14WriteCount = 0
        sec14FailReads = [1]
        let unversionedBlob = Data("secret-unversioned".utf8)
        let case3AuxStore = makeRecoveryStore()
        try check(case3AuxStore.loadAllCredentials().isEmpty && sec14ReadCount == 1, "[§14.1] unversioned case starts with failed read")
        try case3AuxStore.saveAuxiliaryData(unversionedBlob, forKey: "cliProxy.test")
        let reopenedAfterCase3Aux = makeCleanReader()
        try check(
            sec14ReadCount == 2
                && sec14WriteCount == 1
                && reopenedAfterCase3Aux.loadAllCredentials().map(\.id) == ["seeded-codex-1"]
                && reopenedAfterCase3Aux.loadAuxiliaryData(forKey: auxKey) == rev8Blob
                && reopenedAfterCase3Aux.loadAuxiliaryData(forKey: "cliProxy.test") == unversionedBlob,
            "[§14.1] unversioned saveAuxiliaryData preserves existing credentials and auxiliary blobs on read recovery"
        )

        sec14ReadCount = 0
        sec14WriteCount = 0
        sec14FailReads = [1]
        let case3CredStore = makeRecoveryStore()
        try check(case3CredStore.loadAllCredentials().isEmpty && sec14ReadCount == 1, "[§14.1] credential recovery case starts with failed read")
        try case3CredStore.saveCredential(seededCred2)
        let reopenedAfterCred = makeCleanReader()
        try check(
            Set(reopenedAfterCred.loadAllCredentials().map(\.id)) == ["seeded-codex-1", "seeded-codex-2"]
                && reopenedAfterCred.loadAuxiliaryData(forKey: auxKey) == rev8Blob,
            "[§14.1] saveCredential after transient read failure preserves existing credentials and auxiliary data"
        )

        var alwaysFailWrites = 0
        let alwaysFailStore = AccountCredentialStore(
            readVaultData: { throw CredentialStoreError.keychainReadFailed(-25308) },
            writeVaultData: { _ in alwaysFailWrites += 1 }
        )
        var alwaysFailThrew = false
        do { _ = try alwaysFailStore.saveAuxiliaryData(Data("rev-9".utf8), forKey: auxKey, revision: 9) } catch { alwaysFailThrew = true }
        try check(
            alwaysFailThrew
                && alwaysFailWrites == 0
                && Set(makeCleanReader().loadAllCredentials().map(\.id)) == ["seeded-codex-1", "seeded-codex-2"],
            "[§14.1] persistent read failure performs 0 writes and leaves existing vault intact"
        )

        // Codex §6.1, §6.2, §6.5, §6.9 regressions
        do {
            let leanHome = home.appendingPathComponent("master-lean-cut-\(UUID())", isDirectory: true)
            defer { try? fm.removeItem(at: leanHome) }

            // §6.1 AntigravityLocalQuotaReader:
            // (a) cached A from probeActiveEmail does not approve B when IDE switches before fetchMatchingQuota
            final class SwitchState: @unchecked Sendable {
                private let lock = NSLock()
                var activeEmail = "a@example.test"
                var activeProject = "proj-a"
                var flipDuringQuota = false
                var primaryCalls = 0
                var fallbackCalls = 0
                var statusCalls = 0
                func snapshot() -> (email: String, project: String) {
                    lock.lock(); defer { lock.unlock() }
                    return (activeEmail, activeProject)
                }
                func setActive(email: String, project: String) {
                    lock.lock(); activeEmail = email; activeProject = project; lock.unlock()
                }
                func markQuotaAndMaybeFlip() {
                    lock.lock()
                    if flipDuringQuota {
                        activeEmail = "b@example.test"
                        activeProject = "proj-b"
                    }
                    lock.unlock()
                }
                func bumpPrimary() { lock.lock(); primaryCalls += 1; lock.unlock() }
                func bumpFallback() { lock.lock(); fallbackCalls += 1; lock.unlock() }
                func bumpStatus() { lock.lock(); statusCalls += 1; lock.unlock() }
            }
            let preSwitchState = SwitchState()
            let preSwitchReader = AntigravityLocalQuotaReader(
                listProcesses: {
                    preSwitchState.bumpPrimary()
                    return [AntigravityLocalQuotaReader.ServerProcess(pid: 4242, csrfToken: "tok", preferredPorts: [19001])]
                },
                listPorts: { _ in [] },
                callRPC: { _, methodPath, _, _ in
                    if methodPath.hasSuffix("GetUserStatus") {
                        preSwitchState.bumpStatus()
                        let cur = preSwitchState.snapshot()
                        return ["userStatus": ["email": cur.email, "cloudaicompanionProject": cur.project]]
                    }
                    if methodPath.hasSuffix("RetrieveUserQuotaSummary") {
                        return ["groups": [["displayName": "Gemini Pro", "buckets": [["bucketId": "gemini-pro", "remainingFraction": 0.23, "resetTime": "2027-01-01T00:00:00Z"]]]]]
                    }
                    return nil
                },
                fallbackListProcesses: {
                    preSwitchState.bumpFallback()
                    return []
                },
                sessionCacheTTL: 5.0
            )
            let probedEmail1 = await preSwitchReader.probeActiveEmail()
            preSwitchState.setActive(email: "b@example.test", project: "proj-b")
            let cachedHintEmail = await preSwitchReader.probeActiveEmail()
            let blockedPreSwitch = await preSwitchReader.fetchMatchingQuota(
                expectedEmail: "a@example.test",
                expectedProjectId: "proj-a",
                requireProjectMatch: true
            )
            try check(
                probedEmail1 == "a@example.test"
                    && cachedHintEmail == "a@example.test"
                    && blockedPreSwitch == nil
                    && preSwitchState.fallbackCalls == 0,
                "[§6.1] cached probeActiveEmail never validates B quota under A after IDE switch before fetchMatchingQuota"
            )

            // (b) mid-flight A -> B switch during RetrieveUserQuotaSummary on identity-less summary is rejected on post-check
            let midSwitchState = SwitchState()
            midSwitchState.flipDuringQuota = true
            let midSwitchReader = AntigravityLocalQuotaReader(
                listProcesses: { [AntigravityLocalQuotaReader.ServerProcess(pid: 4243, csrfToken: "tok", preferredPorts: [19002])] },
                listPorts: { _ in [] },
                callRPC: { _, methodPath, _, _ in
                    if methodPath.hasSuffix("GetUserStatus") {
                        midSwitchState.bumpStatus()
                        let cur = midSwitchState.snapshot()
                        return ["userStatus": ["email": cur.email, "cloudaicompanionProject": cur.project]]
                    }
                    if methodPath.hasSuffix("RetrieveUserQuotaSummary") {
                        midSwitchState.markQuotaAndMaybeFlip()
                        return ["groups": [["displayName": "Gemini Pro", "buckets": [["bucketId": "gemini-pro", "remainingFraction": 0.23, "resetTime": "2027-01-01T00:00:00Z"]]]]]
                    }
                    return nil
                },
                sessionCacheTTL: 5.0
            )
            let blockedMidSwitch = await midSwitchReader.fetchMatchingQuota(
                expectedEmail: "a@example.test",
                expectedProjectId: "proj-a",
                requireProjectMatch: true
            )
            try check(
                blockedMidSwitch == nil && midSwitchState.statusCalls == 2,
                "[§6.1] mid-flight A->B switch during identity-less RetrieveUserQuotaSummary is rejected by post-quota status re-check"
            )

            // (c) stable A/proj-a succeeds + scheduling hint still caches within TTL without ps fallback
            let stableState = SwitchState()
            let stableReader = AntigravityLocalQuotaReader(
                listProcesses: {
                    stableState.bumpPrimary()
                    return [AntigravityLocalQuotaReader.ServerProcess(pid: 4244, csrfToken: "tok", preferredPorts: [19003])]
                },
                listPorts: { _ in [] },
                callRPC: { _, methodPath, _, _ in
                    if methodPath.hasSuffix("GetUserStatus") {
                        stableState.bumpStatus()
                        let cur = stableState.snapshot()
                        return ["userStatus": ["email": cur.email, "cloudaicompanionProject": cur.project]]
                    }
                    if methodPath.hasSuffix("RetrieveUserQuotaSummary") {
                        return ["groups": [["displayName": "Gemini Pro", "buckets": [["bucketId": "gemini-pro", "remainingFraction": 0.23, "resetTime": "2027-01-01T00:00:00Z"]]]]]
                    }
                    return nil
                },
                fallbackListProcesses: {
                    stableState.bumpFallback()
                    return []
                },
                sessionCacheTTL: 5.0
            )
            let hint1 = await stableReader.probeActiveSession()
            let hint2 = await stableReader.probeActiveSession()
            let stableQuota = await stableReader.fetchMatchingQuota(
                expectedEmail: "a@example.test",
                expectedProjectId: "proj-a",
                requireProjectMatch: true
            )
            try check(
                hint1?.email == "a@example.test"
                    && hint2?.email == "a@example.test"
                    && stableQuota?.email == "a@example.test"
                    && stableQuota?.projectId == "proj-a"
                    && stableState.fallbackCalls == 0
                    && stableState.primaryCalls == 2
                    && stableState.statusCalls == 3,
                "[§6.1] stable identity-less quota post-verifies and succeeds while probeActiveSession still reuses TTL without ps fallback"
            )

            // §6.2 CallAnalyticsEngine excludedSources preserves today's archive bucket on disk while hiding it from snapshot
            let caHome = leanHome.appendingPathComponent("call-analytics-preserve", isDirectory: true)
            let caTz = TimeZone(secondsFromGMT: 0)!
            let caClock = CallAnalyticsClock(timeZone: caTz)
            let caNow = Date()
            let caTodayStart = caClock.calendar.startOfDay(for: caNow)
            let caTodayKey = caClock.dayKey(caNow)
            let caISO = ISO8601DateFormatter().string(from: caNow)
            let codexSessionsDir = caHome.appendingPathComponent(".codex/sessions", isDirectory: true)
            try fm.createDirectory(at: codexSessionsDir, withIntermediateDirectories: true)
            let codexSessionFile = codexSessionsDir.appendingPathComponent("today.jsonl")
            let codexLine = #"{"timestamp":"\#(caISO)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}"#
            try Data((Array(repeating: codexLine, count: 7).joined(separator: "\n") + "\n").utf8).write(to: codexSessionFile)
            let caEnv = ["XDG_DATA_HOME": leanHome.appendingPathComponent("empty-xdg").path, "CODEX_HOME": caHome.appendingPathComponent(".codex").path]
            let caEngine = CallAnalyticsEngine(homeDirectory: caHome.path, timeZone: caTz, environment: caEnv)
            let visibleSnap = await caEngine.computeSnapshot(rangeKey: "today", cutoff: caTodayStart, excludedSources: [])
            let visibleCount = visibleSnap.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count }
            let storedBeforeHide = CallAnalyticsArchiveStore(homeDirectory: caHome.path).allDays[caTodayKey]?.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count } ?? 0
            await caEngine.syncToday(excludedSources: [.codex])
            let hiddenSnap = await caEngine.computeSnapshot(rangeKey: "today", cutoff: caTodayStart, excludedSources: [.codex])
            let hiddenVisibleCount = hiddenSnap.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count }
            let storedAfterHiddenWhileLogPresent = CallAnalyticsArchiveStore(homeDirectory: caHome.path).allDays[caTodayKey]?.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count } ?? 0
            try fm.removeItem(at: codexSessionFile)
            await caEngine.syncToday(excludedSources: [.codex])
            let storedAfterHiddenAndLogRemoved = CallAnalyticsArchiveStore(homeDirectory: caHome.path).allDays[caTodayKey]?.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count } ?? 0
            try Data((Array(repeating: codexLine, count: 9).joined(separator: "\n") + "\n").utf8).write(to: codexSessionFile)
            _ = await caEngine.computeSnapshot(rangeKey: "today", cutoff: caTodayStart, excludedSources: [])
            let storedAfterNonHiddenReplace = CallAnalyticsArchiveStore(homeDirectory: caHome.path).allDays[caTodayKey]?.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count } ?? 0
            try fm.removeItem(at: codexSessionFile)
            _ = await caEngine.computeSnapshot(rangeKey: "today", cutoff: caTodayStart, excludedSources: [])
            let storedAfterNonHiddenDelete = CallAnalyticsArchiveStore(homeDirectory: caHome.path).allDays[caTodayKey]
            let emptyHiddenHome = leanHome.appendingPathComponent("call-analytics-empty-hidden", isDirectory: true)
            let emptyHiddenEngine = CallAnalyticsEngine(homeDirectory: emptyHiddenHome.path, timeZone: caTz, environment: caEnv)
            await emptyHiddenEngine.syncToday(excludedSources: [.claude, .codex, .opencode, .antigravity])
            let hiddenMarkedComplete = CallAnalyticsArchiveStore(homeDirectory: emptyHiddenHome.path).fullHistoryImported

            // Today replace path with another excluded source preserves excluded entries & agentInvocations on disk
            let mixArchive = CallAnalyticsArchiveStore(homeDirectory: caHome.path)
            _ = mixArchive.freeze(
                computed: [
                    caTodayKey: CallAnalyticsDayBucket(
                        entries: [
                            CallAnalyticsEntry(source: .claude, kind: .builtin, name: "Bash", server: nil, dayKey: caTodayKey, count: 3),
                            CallAnalyticsEntry(source: .codex, kind: .builtin, name: "exec_command", server: nil, dayKey: caTodayKey, count: 7)
                        ],
                        agentInvocations: [AgentInvocationCount(source: .claude, agent: "main", count: 2)]
                    )
                ],
                todayKey: caTodayKey,
                completedFullHistory: true
            )
            try Data((Array(repeating: codexLine, count: 9).joined(separator: "\n") + "\n").utf8).write(to: codexSessionFile)
            let mixEngine = CallAnalyticsEngine(homeDirectory: caHome.path, timeZone: caTz, environment: caEnv)
            _ = await mixEngine.computeSnapshot(rangeKey: "today", cutoff: caTodayStart, excludedSources: [.claude])
            let mixedDay = CallAnalyticsArchiveStore(homeDirectory: caHome.path).allDays[caTodayKey]
            let mixedCodex = mixedDay?.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count } ?? 0
            let mixedClaude = mixedDay?.entries.filter { $0.source == .claude }.reduce(0) { $0 + $1.count } ?? 0
            let mixedInvocations = mixedDay?.agentInvocations ?? []

            // Frozen past day survives source-log deletion after hidden sync and unhides cleanly on fresh engine
            let frozenHome = leanHome.appendingPathComponent("call-analytics-frozen", isDirectory: true)
            let frozenSessionsDir = frozenHome.appendingPathComponent(".codex/sessions", isDirectory: true)
            try fm.createDirectory(at: frozenSessionsDir, withIntermediateDirectories: true)
            let frozenEnv = ["XDG_DATA_HOME": leanHome.appendingPathComponent("empty-xdg").path, "CODEX_HOME": frozenHome.appendingPathComponent(".codex").path]
            let caYesterday = caTodayStart.addingTimeInterval(-86400)
            let caYesterdayISO = ISO8601DateFormatter().string(from: caYesterday)
            let yesterdayFile = frozenSessionsDir.appendingPathComponent("yesterday.jsonl")
            let yesterdayLine = #"{"timestamp":"\#(caYesterdayISO)","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{}"}}"#
            try Data((Array(repeating: yesterdayLine, count: 7).joined(separator: "\n") + "\n").utf8).write(to: yesterdayFile)
            let frozenEngine = CallAnalyticsEngine(homeDirectory: frozenHome.path, timeZone: caTz, environment: frozenEnv)
            let frozenInitial = await frozenEngine.computeSnapshot(rangeKey: "all", cutoff: nil, excludedSources: [])
            let frozenInitialCount = frozenInitial.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count }
            await frozenEngine.syncToday(excludedSources: [.codex])
            try fm.removeItem(at: yesterdayFile)
            let frozenReopenedEngine = CallAnalyticsEngine(homeDirectory: frozenHome.path, timeZone: caTz, environment: frozenEnv)
            let frozenRestoredSnap = await frozenReopenedEngine.computeSnapshot(rangeKey: "all", cutoff: nil, excludedSources: [])
            let frozenRestoredCount = frozenRestoredSnap.entries.filter { $0.source == .codex }.reduce(0) { $0 + $1.count }

            try check(
                visibleCount == 7
                    && storedBeforeHide == 7
                    && hiddenVisibleCount == 0
                    && !hiddenSnap.sources.contains(where: { $0.source == .codex })
                    && storedAfterHiddenWhileLogPresent == 7
                    && storedAfterHiddenAndLogRemoved == 7
                    && storedAfterNonHiddenReplace == 9
                    && storedAfterNonHiddenDelete == nil
                    && !hiddenMarkedComplete
                    && mixedCodex == 9
                    && mixedClaude == 3
                    && mixedInvocations == [AgentInvocationCount(source: .claude, agent: "main", count: 2)]
                    && frozenInitialCount == 7
                    && frozenRestoredCount == 7,
                "[§6.2] excluded Codex scan hides snapshot rows without erasing today's archive bucket or marking full history complete"
            )

            // §6.5 OpenCodeCostProvider: commit on preallocated reused WAL with equal mtime, size, and 32-byte header is never skipped
            let ocCostHome = leanHome.appendingPathComponent("oc-cost", isDirectory: true)
            let ocCostXdg = ocCostHome.appendingPathComponent("xdg", isDirectory: true)
            let ocCostDir = ocCostXdg.appendingPathComponent("opencode", isDirectory: true)
            try fm.createDirectory(at: ocCostDir, withIntermediateDirectories: true)
            let ocCostDBURL = ocCostDir.appendingPathComponent("opencode.db")
            let ocCostWALURL = ocCostDir.appendingPathComponent("opencode.db-wal")
            var costDB: OpaquePointer?
            try check(sqlite3_open_v2(ocCostDBURL.path, &costDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, "open opencode WAL db")
            defer { if let costDB { sqlite3_close(costDB) } }
            let padText = String(repeating: "x", count: 65536)
            let nowMillis = Int64(Date().timeIntervalSince1970 * 1000)
            let msg50 = #"{"role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-4","tokens":{"input":40,"output":10,"cache":{"read":0,"write":0}},"cost":0.01}"#
            try check(sqlite3_exec(
                costDB,
                "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0; CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT); CREATE TABLE pad (x TEXT); INSERT INTO pad VALUES ('\(padText)'); DELETE FROM pad; DROP TABLE pad; PRAGMA wal_checkpoint(RESTART); INSERT INTO message VALUES ('m1', 's1', \(nowMillis), '\(msg50)');",
                nil, nil, nil
            ) == SQLITE_OK, "seed preallocated WAL message 1")
            let ocProvider = OpenCodeCostProvider(homeDirectory: ocCostHome.path, timeZone: TimeZone(secondsFromGMT: 0)!, environment: ["XDG_DATA_HOME": ocCostXdg.path])
            let usage1 = try await ocProvider.fetchUsage()
            func fileStats(_ url: URL) throws -> (mtime: Date, size: Int, header: Data) {
                let attrs = try fm.attributesOfItem(atPath: url.path)
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let header = (try? handle.read(upToCount: 32)) ?? Data()
                return ((attrs[.modificationDate] as? Date) ?? Date(), (attrs[.size] as? Int) ?? 0, header)
            }
            let dbStats1 = try fileStats(ocCostDBURL)
            let walStats1 = try fileStats(ocCostWALURL)
            try check(sqlite3_exec(costDB, "INSERT INTO message VALUES ('m2', 's1', \(nowMillis), '\(msg50)');", nil, nil, nil) == SQLITE_OK, "commit message 2 onto reused WAL")
            try fm.setAttributes([.modificationDate: dbStats1.mtime], ofItemAtPath: ocCostDBURL.path)
            try fm.setAttributes([.modificationDate: walStats1.mtime], ofItemAtPath: ocCostWALURL.path)
            let dbStats2 = try fileStats(ocCostDBURL)
            let walStats2 = try fileStats(ocCostWALURL)
            let usage2 = try await ocProvider.fetchUsage()
            try check(walStats2.size == walStats1.size && dbStats2.size == dbStats1.size,
                      "[§6.5] reused WAL commit keeps identical db/wal sizes (wal1=\(walStats1.size) wal2=\(walStats2.size))")
            try check(walStats2.header == walStats1.header && dbStats2.header == dbStats1.header,
                      "[§6.5] reused WAL commit keeps identical 32-byte db/wal headers")
            try check(abs(walStats2.mtime.timeIntervalSince(walStats1.mtime)) < 0.001 && abs(dbStats2.mtime.timeIntervalSince(dbStats1.mtime)) < 0.001,
                      "[§6.5] restored mtimes match pre-commit mtimes")
            try check((usage1.extra["overall.totalTokens"]?.value as? Int) == 50 && (usage2.extra["overall.totalTokens"]?.value as? Int) == 100,
                      "[§6.5] OpenCodeCostProvider picks up new SQLite commit on reused WAL (usage1=\(usage1.extra["overall.totalTokens"]?.value as? Int ?? -1) usage2=\(usage2.extra["overall.totalTokens"]?.value as? Int ?? -1))")

            // §6.9 CallAnalyticsInventory excludes hidden sources before listing dirs, reading files, or constructing resolvers
            let invHome = leanHome.appendingPathComponent("inventory-gate", isDirectory: true)
            let invEnv = ["XDG_CONFIG_HOME": invHome.appendingPathComponent(".config").path, "CLAUDE_CONFIG_DIR": invHome.appendingPathComponent(".claude").path]
            try write("---\nname: claude-s\n---\n", invHome.appendingPathComponent(".claude/skills/claude-s/SKILL.md"))
            try write(#"{"mcpServers":{"claude-mcp":{"command":"echo"}}}"#, invHome.appendingPathComponent(".claude.json"))
            try write("---\nname: oc-s\n---\n", invHome.appendingPathComponent(".config/opencode/skills/oc-s/SKILL.md"))
            try write(#"{"mcp":{"oc-mcp":{"command":["echo"]}}}"#, invHome.appendingPathComponent(".config/opencode/opencode.json"))
            try write("---\nname: codex-s\n---\n", invHome.appendingPathComponent(".codex/skills/codex-s/SKILL.md"))
            try write("[mcp_servers.codex_mcp]\ncommand = \"echo\"\n", invHome.appendingPathComponent(".codex/config.toml"))
            var controlTouched: [CallSourceKind] = []
            let controlInv = CallAnalyticsInventory(homeDirectory: invHome.path, environment: invEnv) { source, _ in
                controlTouched.append(source)
            }
            let controlSkills = controlInv.installedSkills()
            let controlMCP = controlInv.installedMCPServers()
            var excludedTouched: [(CallSourceKind, String)] = []
            let leanInv = CallAnalyticsInventory(homeDirectory: invHome.path, environment: invEnv) { source, path in
                excludedTouched.append((source, path))
            }
            let leanSkills = leanInv.installedSkills(excludedSources: [.claude, .opencode])
            let leanMCP = leanInv.installedMCPServers(excludedSources: [.claude, .opencode])
            try check(
                Set(controlTouched).contains(.claude)
                    && Set(controlTouched).contains(.opencode)
                    && controlSkills.contains(InstalledItem(source: .claude, name: "claude-s"))
                    && controlMCP.contains(InstalledItem(source: .opencode, name: "oc-mcp"))
                    && !excludedTouched.contains(where: { $0.0 == .claude || $0.0 == .opencode || $0.1.contains(".claude") || $0.1.contains("opencode") })
                    && Set(excludedTouched.map(\.0)) == Set([.codex, .antigravity])
                    && leanSkills == [InstalledItem(source: .codex, name: "codex-s")]
                    && leanMCP == [InstalledItem(source: .codex, name: "codex_mcp")],
                "[§6.9] CallAnalyticsInventory excludes claude and opencode before touching hidden paths or resolvers"
            )
        }

        // Finding #1 & R2-P2-1 & R2-P2-2: SidebarSelectionRelay defers genuine list writes out of view updates,
        // drops redundant same-selection writes, prevents stale queued selections from overwriting newer selections,
        // rechecks target visibility before commit, and preserves fresh selections after external navigation.
        do {
            @MainActor
            final class DetailActivationBox {
                var sessionsDetailActivated = false
            }

            @MainActor
            final class SidebarRelayState: ObservableObject {
                @Published var selected: AppSection = .dashboard
                @Published var hiddenSections: Set<String> = []
                var commits: [AppSection] = []
                let relay = SidebarSelectionRelay()
                var queuedWriteDuringRender: AppSection?

                var binding: Binding<AppSection> {
                    relay.binding(
                        current: { self.selected },
                        isSelectable: { SidebarNavigation.isVisible($0, hidden: self.hiddenSections) },
                        commit: { section in
                            self.selected = section
                            self.commits.append(section)
                        }
                    )
                }

                func hideSection(_ section: AppSection) {
                    hiddenSections.insert(section.rawValue)
                    if selected == section {
                        relay.cancelPending()
                        selected = .dashboard
                    }
                }
            }

            struct SidebarRelayHostView: View {
                @ObservedObject var state: SidebarRelayState
                let tracker: DetailActivationBox
                var body: some View {
                    if let target = state.queuedWriteDuringRender {
                        state.queuedWriteDuringRender = nil
                        state.binding.wrappedValue = target
                    }
                    return Group {
                        switch state.selected {
                        case .sessions:
                            let _ = { tracker.sessionsDetailActivated = true }()
                            Text("sessions")
                        default:
                            Text(state.selected.rawValue)
                        }
                    }
                    .frame(width: 120, height: 40)
                }
            }

            @MainActor
            func drainMainQueue() async {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    DispatchQueue.main.async { continuation.resume() }
                }
            }

            let tracker = await MainActor.run { DetailActivationBox() }
            let state = await MainActor.run {
                _ = NSApplication.shared
                return SidebarRelayState()
            }

            // 1. Repeated same-selection write performs 0 commits
            await MainActor.run { state.binding.wrappedValue = .dashboard }
            await drainMainQueue()
            let afterSameWrite = await MainActor.run { (state.selected, state.commits) }
            try check(afterSameWrite.0 == .dashboard && afterSameWrite.1.isEmpty,
                      "[Finding #1] redundant same-selection write must not publish")

            // 2. Render-pass selection write via disposable NSHostingView commits asynchronously after body returns
            let (window, host, immediateSelected, immediateCommits) = await MainActor.run { () -> (NSWindow, NSHostingView<SidebarRelayHostView>, AppSection, Int) in
                state.queuedWriteDuringRender = .sessions
                let host = NSHostingView(rootView: SidebarRelayHostView(state: state, tracker: tracker))
                let win = NSWindow(
                    contentRect: NSRect(x: -10000, y: -10000, width: 160, height: 60),
                    styleMask: [.borderless],
                    backing: .buffered,
                    defer: false
                )
                win.contentView = host
                host.layoutSubtreeIfNeeded()
                win.displayIfNeeded()
                win.orderFront(nil)
                return (win, host, state.selected, state.commits.count)
            }
            try check(immediateSelected == .dashboard && immediateCommits == 0,
                      "[Finding #1] selection write during NSHostingView update must defer out of the current render pass")
            await drainMainQueue()
            let settledAfterRender = await MainActor.run { (state.selected, state.commits) }
            try check(settledAfterRender.0 == .sessions && settledAfterRender.1 == [.sessions],
                      "[Finding #1] deferred selection settles cleanly on next main-queue turn")

            // 3. Rapid distinct selections collapse to only the final selection
            await MainActor.run {
                state.commits.removeAll()
                state.binding.wrappedValue = .costTracking
                state.binding.wrappedValue = .inbox
                state.binding.wrappedValue = .settings
            }
            await drainMainQueue()
            let afterRapidDistinct = await MainActor.run { (state.selected, state.commits) }
            try check(afterRapidDistinct.0 == .settings && afterRapidDistinct.1 == [.settings],
                      "[Finding #1] rapid distinct selections must commit only the latest selection")

            // 4. Rapid round-trip back to current active selection cancels pending delivery
            await MainActor.run {
                state.commits.removeAll()
                state.binding.wrappedValue = .inbox
                state.binding.wrappedValue = .settings
            }
            await drainMainQueue()
            let afterRoundTrip = await MainActor.run { (state.selected, state.commits) }
            try check(afterRoundTrip.0 == .settings && afterRoundTrip.1.isEmpty,
                      "[Finding #1] round-trip selection returning to active cancels pending commit")

            // 5. Synchronous programmatic navigation & external state changes supersede queued list writes
            await MainActor.run {
                state.commits.removeAll()
                state.binding.wrappedValue = .inbox
                state.relay.cancelPending()
                state.selected = .providerAccounts
            }
            await drainMainQueue()
            let afterProgrammaticCancel = await MainActor.run { (state.selected, state.commits) }
            try check(afterProgrammaticCancel.0 == .providerAccounts && afterProgrammaticCancel.1.isEmpty,
                      "[Finding #1] cancelPending + programmatic navigation drops queued sidebar write")

            // 6. R2-P2-1: Queuing a section then hiding it before drain keeps Dashboard selected & never activates detail
            await MainActor.run {
                state.selected = .dashboard
                state.commits.removeAll()
                state.hiddenSections.removeAll()
                tracker.sessionsDetailActivated = false
                host.layoutSubtreeIfNeeded()
                state.binding.wrappedValue = .sessions
                state.hideSection(.sessions)
                host.layoutSubtreeIfNeeded()
            }
            await drainMainQueue()
            let afterHiddenDrain = await MainActor.run { () -> (AppSection, [AppSection], Bool) in
                host.layoutSubtreeIfNeeded()
                winDisplay: do { window.displayIfNeeded() }
                return (state.selected, state.commits, tracker.sessionsDetailActivated)
            }
            try check(afterHiddenDrain.0 == .dashboard && afterHiddenDrain.1.isEmpty && !afterHiddenDrain.2,
                      "[R2-P2-1] queued selection must not open a newly hidden section or construct SessionCenterView")

            // 6b. R2-P2-1 control: when visible again, queuing .sessions commits and activates detail
            await MainActor.run {
                state.hiddenSections.removeAll()
                tracker.sessionsDetailActivated = false
                state.binding.wrappedValue = .sessions
            }
            await drainMainQueue()
            let afterVisibleDrain = await MainActor.run { () -> (AppSection, [AppSection], Bool) in
                host.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                return (state.selected, state.commits, tracker.sessionsDetailActivated)
            }
            try check(afterVisibleDrain.0 == .sessions && afterVisibleDrain.1 == [.sessions] && afterVisibleDrain.2,
                      "[R2-P2-1] ordinary visible selection still commits and opens detail")

            // 7. R2-P2-2: Queue Inbox -> externally select Settings -> select Inbox again -> drain commits Inbox once
            await MainActor.run {
                state.selected = .dashboard
                state.commits.removeAll()
                state.binding.wrappedValue = .inbox
                state.selected = .settings
                state.binding.wrappedValue = .inbox
            }
            await drainMainQueue()
            let afterExternalReselect = await MainActor.run { (state.selected, state.commits) }
            try check(afterExternalReselect.0 == .inbox && afterExternalReselect.1 == [.inbox],
                      "[R2-P2-2] fresh selection after external navigation commits once instead of dropping")

            // 7b. R2-P2-2 control: without the second Inbox selection, external Settings remains selected
            await MainActor.run {
                state.selected = .dashboard
                state.commits.removeAll()
                state.binding.wrappedValue = .inbox
                state.selected = .settings
                window.orderOut(nil)
            }
            await drainMainQueue()
            let afterExternalNoReselect = await MainActor.run { (state.selected, state.commits) }
            try check(afterExternalNoReselect.0 == .settings && afterExternalNoReselect.1.isEmpty,
                      "[R2-P2-2] stale queued selection still drops when user does not re-select")
        }

        // R2-P2-3: OpenCode snapshots isolate db/-wal/-shm inside fresh 0700 subdirectories with 0600 files even under an owned 0755 temp root
        do {
            final class SnapshotObservationBox: @unchecked Sendable {
                private let lock = NSLock()
                private var recorded: [(dir: URL, mode: Int, fileModes: [String: Int], parentDirectEntries: [String])] = []
                func record(_ dir: URL, mode: Int, fileModes: [String: Int], parentDirectEntries: [String]) {
                    lock.withLock { recorded.append((dir, mode, fileModes, parentDirectEntries)) }
                }
                func items() -> [(dir: URL, mode: Int, fileModes: [String: Int], parentDirectEntries: [String])] {
                    lock.withLock { recorded }
                }
                func clear() { lock.withLock { recorded.removeAll() } }
            }

            @Sendable func fileMode(_ path: String) -> Int? {
                var st = stat()
                guard lstat(path, &st) == 0 else { return nil }
                return Int(st.st_mode & 0o7777)
            }

            let isolationRoot = home.appendingPathComponent("opencode-snapshot-isolation", isDirectory: true)
            let parent0755 = isolationRoot.appendingPathComponent("owned-0755-temp", isDirectory: true)
            let dataHome = isolationRoot.appendingPathComponent("synthetic-xdg", isDirectory: true)
            let ocDir = dataHome.appendingPathComponent("opencode", isDirectory: true)
            try fm.createDirectory(at: parent0755, withIntermediateDirectories: true)
            try fm.createDirectory(at: ocDir, withIntermediateDirectories: true)
            try check(chmod(parent0755.path, 0o755) == 0 && fileMode(parent0755.path) == 0o755,
                      "[R2-P2-3] test parent directory must be owned 0755")

            let dbURL = ocDir.appendingPathComponent("opencode.db")
            let walURL = ocDir.appendingPathComponent("opencode.db-wal")
            let shmURL = ocDir.appendingPathComponent("opencode.db-shm")
            var snapDB: OpaquePointer?
            try check(sqlite3_open_v2(dbURL.path, &snapDB, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                      "[R2-P2-3] create synthetic OpenCode DB")
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            let msgJSON = #"{"role":"assistant","providerID":"anthropic","modelID":"claude-sonnet-4","tokens":{"input":30,"output":20,"cache":{"read":0,"write":0}},"cost":0.02}"#
            let partJSON = #"{"type":"tool","tool":"bash","state":{"status":"completed"}}"#
            let setupSQL = """
            PRAGMA journal_mode=WAL;
            PRAGMA wal_autocheckpoint=0;
            CREATE TABLE part (id TEXT, time_created INTEGER, data TEXT);
            CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO part VALUES ('p1', \(nowMs), '\(partJSON)');
            INSERT INTO message VALUES ('m1', 's1', \(nowMs), '\(msgJSON)');
            """
            try check(sqlite3_exec(snapDB, setupSQL, nil, nil, nil) == SQLITE_OK, "[R2-P2-3] seed WAL part and message rows")
            chmod(dbURL.path, 0o644)
            chmod(walURL.path, 0o644)
            chmod(shmURL.path, 0o644)

            let snapEnv = [
                "XDG_DATA_HOME": dataHome.path,
                "TMPDIR": parent0755.path,
                "AIUSAGE_TEST_FIXTURE_ROOT": parent0755.path,
            ]
            let box = SnapshotObservationBox()
            let observer: @Sendable (URL) -> Void = { dir in
                let dirMode = fileMode(dir.path) ?? -1
                let parentDirect = ((try? FileManager.default.contentsOfDirectory(atPath: parent0755.path)) ?? []).sorted()
                var modes: [String: Int] = [:]
                for name in ["opencode.db", "opencode.db-wal", "opencode.db-shm"] {
                    if let m = fileMode(dir.appendingPathComponent(name).path) {
                        modes[name] = m
                    }
                }
                box.record(dir, mode: dirMode, fileModes: modes, parentDirectEntries: parentDirect)
            }

            // Success path: CallAnalytics OpenCodeCallEventSource
            let callSnap = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(observer) {
                OpenCodeCallEventSource(homeDirectory: isolationRoot.path, timeZone: utc, environment: snapEnv).collect(cutoff: nil)
            }
            let callObserved = box.items()
            try check(callSnap.status.errorCode == nil
                        && callSnap.entries.first(where: { $0.name == "bash" }) != nil
                        && callObserved.count == 1
                        && callObserved[0].mode == 0o700
                        && callObserved[0].parentDirectEntries == [callObserved[0].dir.lastPathComponent]
                        && callObserved[0].fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                        && ((try? fm.contentsOfDirectory(atPath: parent0755.path)) ?? ["nonempty"]).isEmpty,
                      "[R2-P2-3] OpenCodeCallEventSource isolates DB/WAL/SHM in 0700 subdir with 0600 files and cleans up on success")

            // Success path: OpenCodeCostProvider
            box.clear()
            let costUsage = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(observer) {
                try await OpenCodeCostProvider(homeDirectory: isolationRoot.appendingPathComponent("cost-success").path, timeZone: utc, environment: snapEnv).fetchUsage()
            }
            let costObserved = box.items()
            try check((costUsage.extra["overall.totalTokens"]?.value as? Int) == 50
                        && costObserved.count == 1
                        && costObserved[0].mode == 0o700
                        && costObserved[0].parentDirectEntries == [costObserved[0].dir.lastPathComponent]
                        && costObserved[0].fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                        && ((try? fm.contentsOfDirectory(atPath: parent0755.path)) ?? ["nonempty"]).isEmpty,
                      "[R2-P2-3] OpenCodeCostProvider isolates DB/WAL/SHM in 0700 subdir with 0600 files and cleans up on success")

            if let snapDB { sqlite3_close(snapDB) }

            // Failure path (a): sidecar copy error (-wal replaced with directory) cleans up partial 0700 dir on both consumers
            try? fm.removeItem(at: walURL)
            try? fm.removeItem(at: shmURL)
            try fm.createDirectory(at: walURL, withIntermediateDirectories: true)
            box.clear()
            let copyFailCall = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(observer) {
                OpenCodeCallEventSource(homeDirectory: isolationRoot.path, timeZone: utc, environment: snapEnv).collect(cutoff: nil)
            }
            var copyFailCostThrew = false
            do {
                _ = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(observer) {
                    try await OpenCodeCostProvider(homeDirectory: isolationRoot.appendingPathComponent("cost-copy-fail").path, timeZone: utc, environment: snapEnv).fetchUsage()
                }
            } catch {
                copyFailCostThrew = true
            }
            try check(copyFailCall.status.errorCode == "db_snapshot_failed"
                        && copyFailCostThrew
                        && box.items().isEmpty
                        && ((try? fm.contentsOfDirectory(atPath: parent0755.path)) ?? ["nonempty"]).isEmpty,
                      "[R2-P2-3] sidecar copy failure cleans up partial 0700 snapshot directory on both consumers")

            // Failure path (b): corrupt SQLite bytes pass isolated 0700/0600 prep and clean up after failed read on both consumers
            try? fm.removeItem(at: walURL)
            try? fm.removeItem(at: dbURL)
            try Data("not-a-sqlite-db".utf8).write(to: dbURL)
            try Data("corrupt-wal".utf8).write(to: walURL)
            try Data("corrupt-shm".utf8).write(to: shmURL)
            chmod(dbURL.path, 0o644)
            chmod(walURL.path, 0o644)
            chmod(shmURL.path, 0o644)
            box.clear()
            let readFailCall = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(observer) {
                OpenCodeCallEventSource(homeDirectory: isolationRoot.path, timeZone: utc, environment: snapEnv).collect(cutoff: nil)
            }
            var readFailCostThrew = false
            do {
                _ = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(observer) {
                    try await OpenCodeCostProvider(homeDirectory: isolationRoot.appendingPathComponent("cost-read-fail").path, timeZone: utc, environment: snapEnv).fetchUsage()
                }
            } catch {
                readFailCostThrew = true
            }
            let readFailObserved = box.items()
            try check(readFailCall.status.errorCode != nil
                        && readFailCostThrew
                        && readFailObserved.count == 2
                        && readFailObserved.allSatisfy {
                            $0.mode == 0o700
                                && $0.parentDirectEntries == [$0.dir.lastPathComponent]
                                && $0.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                        }
                        && ((try? fm.contentsOfDirectory(atPath: parent0755.path)) ?? ["nonempty"]).isEmpty,
                      "[R2-P2-3] SQLite read failure preserves 0700/0600 pre-read isolation and removes snapshot dirs on both consumers")

            func hasSafeExtendedACLForTest(at path: String, isLeaf: Bool, euid: uid_t) -> Bool {
                let benignMask: acl_permset_mask_t = [
                    ACL_READ_DATA, ACL_EXECUTE, ACL_READ_ATTRIBUTES,
                    ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_SYNCHRONIZE,
                ].reduce(0) { $0 | acl_permset_mask_t($1.rawValue) }
                errno = 0
                guard let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) else {
                    let err = errno
                    return err == ENOENT || err == ENOTSUP || err == EOPNOTSUPP
                }
                defer { acl_free(UnsafeMutableRawPointer(acl)) }
                var entry: acl_entry_t?
                var entryID = ACL_FIRST_ENTRY.rawValue
                while true {
                    errno = 0
                    let status = acl_get_entry(acl, entryID, &entry)
                    guard status == 0, let currentEntry = entry else {
                        let err = errno
                        return entryID == ACL_NEXT_ENTRY.rawValue ? (err == EINVAL || err == ENOENT) : err == ENOENT
                    }
                    entryID = ACL_NEXT_ENTRY.rawValue
                    var tag = ACL_UNDEFINED_TAG
                    guard acl_get_tag_type(currentEntry, &tag) == 0 else { return false }
                    guard tag == ACL_EXTENDED_DENY || tag == ACL_EXTENDED_ALLOW else { return false }
                    var permMask: acl_permset_mask_t = 0
                    guard acl_get_permset_mask_np(currentEntry, &permMask) == 0 else { return false }
                    var fileInherit: Int32 = 0
                    var dirInherit: Int32 = 0
                    var onlyInherit: Int32 = 0
                    if isLeaf && permMask != 0 {
                        var flagset: acl_flagset_t?
                        guard acl_get_flagset_np(UnsafeMutableRawPointer(currentEntry), &flagset) == 0,
                              let flagset else { return false }
                        fileInherit = acl_get_flag_np(flagset, ACL_ENTRY_FILE_INHERIT)
                        dirInherit = acl_get_flag_np(flagset, ACL_ENTRY_DIRECTORY_INHERIT)
                        onlyInherit = acl_get_flag_np(flagset, ACL_ENTRY_ONLY_INHERIT)
                        guard fileInherit >= 0, dirInherit >= 0, onlyInherit >= 0 else { return false }
                    }
                    if tag == ACL_EXTENDED_DENY {
                        if !isLeaf || permMask == 0 { continue }
                        if fileInherit != 0 || dirInherit != 0 { return false }
                        if onlyInherit == 0 && (permMask & acl_permset_mask_t(ACL_DELETE_CHILD.rawValue)) != 0 { return false }
                        continue
                    }
                    let hasLeafInherit = fileInherit != 0 || dirInherit != 0
                    if (permMask & ~benignMask) == 0 && !hasLeafInherit { continue }
                    guard let qualifier = acl_get_qualifier(currentEntry) else { return false }
                    defer { acl_free(qualifier) }
                    var uu: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
                    _ = withUnsafeMutableBytes(of: &uu) { dst in
                        memcpy(dst.baseAddress!, qualifier, dst.count)
                    }
                    var resolvedID: id_t = 0
                    var idType: Int32 = -1
                    guard mbr_uuid_to_id(&uu, &resolvedID, &idType) == 0,
                          idType == ID_TYPE_UID,
                          uid_t(resolvedID) == euid || uid_t(resolvedID) == 0 else {
                        return false
                    }
                }
            }

            func isVerifiedSafeTempDir(_ url: URL) -> Bool {
                guard !url.path.components(separatedBy: "/").contains(".."),
                      let resolvedPtr = realpath(url.path, nil) else { return false }
                defer { free(resolvedPtr) }
                let canonical = String(cString: resolvedPtr)
                let euid = geteuid()
                var st = stat()
                guard lstat(canonical, &st) == 0,
                      (st.st_mode & S_IFMT) == S_IFDIR,
                      st.st_uid == euid,
                      (st.st_mode & S_IRWXU) == S_IRWXU,
                      (st.st_mode & (S_IWGRP | S_IWOTH)) == 0,
                      Darwin.access(canonical, R_OK | W_OK | X_OK) == 0,
                      hasSafeExtendedACLForTest(at: canonical, isLeaf: true, euid: euid) else {
                    return false
                }
                var currentPath = canonical
                var currentStat = st
                while currentPath != "/" {
                    let parentPath = (currentPath as NSString).deletingLastPathComponent
                    if parentPath.isEmpty || parentPath == currentPath { return false }
                    var parentStat = stat()
                    guard lstat(parentPath, &parentStat) == 0,
                          (parentStat.st_mode & S_IFMT) == S_IFDIR,
                          parentStat.st_uid == euid || parentStat.st_uid == 0,
                          hasSafeExtendedACLForTest(at: parentPath, isLeaf: false, euid: euid) else {
                        return false
                    }
                    if (parentStat.st_mode & (S_IWGRP | S_IWOTH)) != 0 {
                        guard (parentStat.st_mode & S_ISVTX) != 0,
                              currentStat.st_uid == euid || (parentStat.st_uid == 0 && currentStat.st_uid == 0) else {
                            return false
                        }
                    }
                    currentPath = parentPath
                    currentStat = parentStat
                }
                return true
            }

            @Sendable func canonicalPath(_ url: URL) -> String {
                TokenSaverSettingsStore.canonicalHomePath(url)
            }

            @discardableResult
            func seedSyntheticOpenCodeDB(at directory: URL, walMode: Bool) throws -> OpaquePointer? {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                let targetDB = directory.appendingPathComponent("opencode.db")
                try? fm.removeItem(at: targetDB)
                try? fm.removeItem(at: directory.appendingPathComponent("opencode.db-wal"))
                try? fm.removeItem(at: directory.appendingPathComponent("opencode.db-shm"))
                var db: OpaquePointer?
                try check(sqlite3_open_v2(targetDB.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                          "[R3] open synthetic OpenCode DB")
                var transferOwnership = false
                defer { if !transferOwnership, let db { sqlite3_close(db) } }
                let journalSQL = walMode
                    ? "PRAGMA journal_mode=WAL;\nPRAGMA wal_autocheckpoint=0;\n"
                    : "PRAGMA journal_mode=DELETE;\n"
                let sql = journalSQL + """
                CREATE TABLE part (id TEXT, time_created INTEGER, data TEXT);
                CREATE TABLE message (id TEXT, session_id TEXT, time_created INTEGER, data TEXT);
                INSERT INTO part VALUES ('p1', \(nowMs), '\(partJSON)');
                INSERT INTO message VALUES ('m1', 's1', \(nowMs), '\(msgJSON)');
                """
                try check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, "[R3] seed synthetic part and message rows")
                chmod(targetDB.path, 0o644)
                if walMode {
                    chmod(directory.appendingPathComponent("opencode.db-wal").path, 0o644)
                    chmod(directory.appendingPathComponent("opencode.db-shm").path, 0o644)
                    transferOwnership = true
                    return db
                }
                return nil
            }

            // R3-P2-1: Reject group/other-writable override roots (0770/0777) while keeping owned 0700/0755
            let r3Root = isolationRoot.appendingPathComponent("r3-checks", isDirectory: true)
            let r3Dir0700 = r3Root.appendingPathComponent("owned-0700", isDirectory: true)
            let r3Dir0755 = r3Root.appendingPathComponent("owned-0755", isDirectory: true)
            let r3Dir0770 = r3Root.appendingPathComponent("unsafe-0770", isDirectory: true)
            let r3Dir0777 = r3Root.appendingPathComponent("unsafe-0777", isDirectory: true)
            let r3Dir0500 = r3Root.appendingPathComponent("readonly-0500", isDirectory: true)
            let r3SafeHome = r3Root.appendingPathComponent("safe-home", isDirectory: true)
            for (dir, mode) in [
                (r3Dir0700, mode_t(0o700)),
                (r3Dir0755, mode_t(0o755)),
                (r3Dir0770, mode_t(0o770)),
                (r3Dir0777, mode_t(0o777)),
                (r3Dir0500, mode_t(0o500)),
                (r3SafeHome, mode_t(0o700)),
            ] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                try check(chmod(dir.path, mode) == 0 && fileMode(dir.path) == Int(mode),
                          "[R3-P2-1] set mode \(String(mode, radix: 8)) on \(dir.lastPathComponent)")
            }
            defer { _ = chmod(r3Dir0500.path, 0o700) }

            let chosen0700 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": r3Dir0700.path],
                processEnvironment: ["HOME": r3SafeHome.path]
            )
            let chosen0755 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0755.path, "TMPDIR": r3Dir0777.path],
                processEnvironment: ["TMPDIR": r3Dir0770.path, "HOME": r3SafeHome.path]
            )
            let fallbackFrom0770And0777 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0770.path, "TMPDIR": r3Dir0777.path],
                processEnvironment: ["AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0777.path, "TMPDIR": r3Dir0770.path, "HOME": r3SafeHome.path]
            )
            let fallbackFromReadOnly = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0500.path, "TMPDIR": r3Dir0777.path],
                processEnvironment: ["AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0755.path, "HOME": r3SafeHome.path]
            )
            let fallbackUncheckedSentinel = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0770.path, "TMPDIR": r3Dir0777.path],
                processEnvironment: ["HOME": r3Dir0777.path]
            )
            try check(canonicalPath(chosen0700) == canonicalPath(r3Dir0700)
                        && canonicalPath(chosen0755) == canonicalPath(r3Dir0755)
                        && canonicalPath(fallbackFromReadOnly) == canonicalPath(r3Dir0755),
                      "[R3-P2-1] owned 0700 and 0755 roots remain accepted")
            let sentinelIsSafeOrClosed = isVerifiedSafeTempDir(fallbackUncheckedSentinel)
                || fallbackUncheckedSentinel.path == "/var/empty/aiusage-unverified-temporary-root"
            try check(canonicalPath(fallbackFrom0770And0777) != canonicalPath(r3Dir0770)
                        && canonicalPath(fallbackFrom0770And0777) != canonicalPath(r3Dir0777)
                        && isVerifiedSafeTempDir(fallbackFrom0770And0777)
                        && canonicalPath(fallbackUncheckedSentinel) != canonicalPath(r3Dir0770)
                        && canonicalPath(fallbackUncheckedSentinel) != canonicalPath(r3Dir0777)
                        && sentinelIsSafeOrClosed,
                      "[R3-P2-1] skips non-sticky 0770/0777 roots across all keys and returns verified safe fallback")

            let r3ValidXDG = r3Root.appendingPathComponent("valid-xdg", isDirectory: true)
            let r3WalDB = try seedSyntheticOpenCodeDB(at: r3ValidXDG.appendingPathComponent("opencode", isDirectory: true), walMode: true)
            defer { if let r3WalDB { sqlite3_close(r3WalDB) } }
            let r3SnapshotBox = SnapshotObservationBox()
            let r3Observer: @Sendable (URL) -> Void = { dir in
                let dirMode = fileMode(dir.path) ?? -1
                let actualParent = dir.deletingLastPathComponent()
                let parentDirect = ((try? FileManager.default.contentsOfDirectory(atPath: actualParent.path)) ?? []).sorted()
                var modes: [String: Int] = [:]
                for name in ["opencode.db", "opencode.db-wal", "opencode.db-shm"] {
                    if let m = fileMode(dir.appendingPathComponent(name).path) {
                        modes[name] = m
                    }
                }
                r3SnapshotBox.record(dir, mode: dirMode, fileModes: modes, parentDirectEntries: parentDirect)
            }

            for (label, unsafeRoot) in [("0770", r3Dir0770), ("0777", r3Dir0777)] {
                r3SnapshotBox.clear()
                let env = [
                    "XDG_DATA_HOME": r3ValidXDG.path,
                    "TMPDIR": unsafeRoot.path,
                    "AIUSAGE_TEST_FIXTURE_ROOT": unsafeRoot.path,
                    "HOME": r3SafeHome.path,
                ]
                let callRes = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                    OpenCodeCallEventSource(homeDirectory: r3SafeHome.path, timeZone: utc, environment: env).collect(cutoff: nil)
                }
                let costRes = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                    try await OpenCodeCostProvider(
                        homeDirectory: r3SafeHome.appendingPathComponent("cost-r3-\(label)").path,
                        timeZone: utc,
                        environment: env
                    ).fetchUsage()
                }
                let obs = r3SnapshotBox.items()
                try check(callRes.status.errorCode == nil
                            && callRes.entries.first(where: { $0.name == "bash" }) != nil
                            && (costRes.extra["overall.totalTokens"]?.value as? Int) == 50
                            && obs.count == 2
                            && obs.allSatisfy { item in
                                let snapParent = item.dir.deletingLastPathComponent()
                                let snapParentMode = fileMode(snapParent.path) ?? 0o777
                                return item.mode == 0o700
                                    && (snapParentMode & 0o022) == 0
                                    && canonicalPath(snapParent) != canonicalPath(unsafeRoot)
                                    && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                            }
                            && ((try? fm.contentsOfDirectory(atPath: r3Dir0770.path)) ?? ["nonempty"]).isEmpty
                            && ((try? fm.contentsOfDirectory(atPath: r3Dir0777.path)) ?? ["nonempty"]).isEmpty,
                          "[R3-P2-1] snapshot consumers avoid \(label) root, use safe 0700/0600 fallback, and leave unsafe roots empty")
            }

            // R3-P2-2: Non-blocking FIFO rejection with deterministic EFTYPE, empty temp roots, and optional-sidecar retention
            final class FIFOWatchdogState: @unchecked Sendable {
                private let lock = NSLock()
                private var fired = false
                func markFired() { lock.withLock { fired = true } }
                func didFire() -> Bool { lock.withLock { fired } }
            }
            let expectedNonRegularMessage = SensitiveDataRedactor.redactedMessage(
                for: NSError(domain: NSPOSIXErrorDomain, code: Int(EFTYPE))
            )
            let r3FIFOXDG = r3Root.appendingPathComponent("fifo-xdg", isDirectory: true)
            let r3FIFOOC = r3FIFOXDG.appendingPathComponent("opencode", isDirectory: true)
            let fifoEnv = [
                "XDG_DATA_HOME": r3FIFOXDG.path,
                "TMPDIR": r3Dir0755.path,
                "AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0755.path,
                "HOME": r3SafeHome.path,
            ]

            for fifoTarget in ["opencode.db-wal", "opencode.db-shm", "opencode.db"] {
                _ = try seedSyntheticOpenCodeDB(at: r3FIFOOC, walMode: false)
                if fifoTarget == "opencode.db-shm" {
                    try Data("dummy-wal".utf8).write(to: r3FIFOOC.appendingPathComponent("opencode.db-wal"))
                    chmod(r3FIFOOC.appendingPathComponent("opencode.db-wal").path, 0o644)
                }
                let fifoURL = r3FIFOOC.appendingPathComponent(fifoTarget)
                try? fm.removeItem(at: fifoURL)
                try check(mkfifo(fifoURL.path, 0o600) == 0, "[R3-P2-2] create writerless FIFO \(fifoTarget)")

                let callState = FIFOWatchdogState()
                let callWatchdog = DispatchWorkItem {
                    callState.markFired()
                    let fd = Darwin.open(fifoURL.path, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 { _ = Darwin.close(fd) }
                }
                r3SnapshotBox.clear()
                errno = ENOENT
                let callStart = Date()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: callWatchdog)
                let fifoCall = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                    OpenCodeCallEventSource(homeDirectory: r3SafeHome.path, timeZone: utc, environment: fifoEnv).collect(cutoff: nil)
                }
                let callElapsed = Date().timeIntervalSince(callStart)
                callWatchdog.cancel()

                let costState = FIFOWatchdogState()
                let costWatchdog = DispatchWorkItem {
                    costState.markFired()
                    let fd = Darwin.open(fifoURL.path, O_WRONLY | O_NONBLOCK)
                    if fd >= 0 { _ = Darwin.close(fd) }
                }
                var costError: ProviderError?
                errno = ENOENT
                let costStart = Date()
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: costWatchdog)
                do {
                    _ = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                        try await OpenCodeCostProvider(
                            homeDirectory: r3SafeHome.appendingPathComponent("cost-fifo-\(fifoTarget)").path,
                            timeZone: utc,
                            environment: fifoEnv
                        ).fetchUsage()
                    }
                } catch let err as ProviderError {
                    costError = err
                }
                let costElapsed = Date().timeIntervalSince(costStart)
                costWatchdog.cancel()

                try check(!callState.didFire() && !costState.didFire()
                            && callElapsed < 0.4 && costElapsed < 0.4
                            && fifoCall.status.errorCode == "db_snapshot_failed"
                            && costError?.code == "db_snapshot_failed"
                            && costError?.redactedMessage == expectedNonRegularMessage
                            && r3SnapshotBox.items().isEmpty
                            && ((try? fm.contentsOfDirectory(atPath: r3Dir0755.path)) ?? ["nonempty"]).isEmpty,
                          "[R3-P2-2] writerless FIFO \(fifoTarget) rejects promptly with deterministic EFTYPE and cleans up temp root")
            }

            // Retain optional missing -wal / -shm behavior
            let r3NoSidecarXDG = r3Root.appendingPathComponent("no-sidecar-xdg", isDirectory: true)
            let r3NoSidecarOC = r3NoSidecarXDG.appendingPathComponent("opencode", isDirectory: true)
            _ = try seedSyntheticOpenCodeDB(at: r3NoSidecarOC, walMode: false)
            try check(!fm.fileExists(atPath: r3NoSidecarOC.appendingPathComponent("opencode.db-wal").path)
                        && !fm.fileExists(atPath: r3NoSidecarOC.appendingPathComponent("opencode.db-shm").path),
                      "[R3-P2-2] no-sidecar fixture has no -wal or -shm")
            let noSidecarEnv = [
                "XDG_DATA_HOME": r3NoSidecarXDG.path,
                "TMPDIR": r3Dir0755.path,
                "AIUSAGE_TEST_FIXTURE_ROOT": r3Dir0755.path,
                "HOME": r3SafeHome.path,
            ]
            r3SnapshotBox.clear()
            let noSidecarCall = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                OpenCodeCallEventSource(homeDirectory: r3SafeHome.path, timeZone: utc, environment: noSidecarEnv).collect(cutoff: nil)
            }
            let noSidecarCost = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                try await OpenCodeCostProvider(
                    homeDirectory: r3SafeHome.appendingPathComponent("cost-no-sidecar").path,
                    timeZone: utc,
                    environment: noSidecarEnv
                ).fetchUsage()
            }
            let noSidecarObs = r3SnapshotBox.items()
            try check(noSidecarCall.status.errorCode == nil
                        && noSidecarCall.entries.first(where: { $0.name == "bash" }) != nil
                        && (noSidecarCost.extra["overall.totalTokens"]?.value as? Int) == 50
                        && noSidecarObs.count == 2
                        && noSidecarObs.allSatisfy { $0.mode == 0o700 && $0.fileModes == ["opencode.db": 0o600] }
                        && ((try? fm.contentsOfDirectory(atPath: r3Dir0755.path)) ?? ["nonempty"]).isEmpty,
                      "[R3-P2-2] missing optional -wal/-shm sidecars still succeed with isolated 0700/0600 db snapshot")

            // R4-P2-1: Reject non-sticky writable ancestors while preserving owned 0755 and sticky system/synthetic temp controls
            let r4Root = isolationRoot.appendingPathComponent("r4-nested-checks", isDirectory: true)
            let r4SafeHome = r4Root.appendingPathComponent("safe-home", isDirectory: true)
            let r4Owned0755Parent = r4Root.appendingPathComponent("parent-0755", isDirectory: true)
            let r4Child0700Under0755 = r4Owned0755Parent.appendingPathComponent("child-0700", isDirectory: true)
            let r4Child0755Under0755 = r4Owned0755Parent.appendingPathComponent("child-0755", isDirectory: true)
            let r4Unsafe0770Parent = r4Root.appendingPathComponent("parent-0770", isDirectory: true)
            let r4Child0700Under0770 = r4Unsafe0770Parent.appendingPathComponent("child-0700", isDirectory: true)
            let r4Unsafe0777Parent = r4Root.appendingPathComponent("parent-0777", isDirectory: true)
            let r4Child0700Under0777 = r4Unsafe0777Parent.appendingPathComponent("child-0700", isDirectory: true)
            let r4Deep0770Grandparent = r4Root.appendingPathComponent("grandparent-0770", isDirectory: true)
            let r4Mid0755 = r4Deep0770Grandparent.appendingPathComponent("mid-0755", isDirectory: true)
            let r4DeepChild0700 = r4Mid0755.appendingPathComponent("child-0700", isDirectory: true)
            let r4UnsafeHomeParent = r4Root.appendingPathComponent("home-parent-0770", isDirectory: true)
            let r4Home0700Under0770 = r4UnsafeHomeParent.appendingPathComponent("home-0700", isDirectory: true)
            let r4Sticky1777Parent = r4Root.appendingPathComponent("sticky-1777", isDirectory: true)
            let r4Child0700UnderSticky1777 = r4Sticky1777Parent.appendingPathComponent("child-0700", isDirectory: true)
            let r4Sticky1770Parent = r4Root.appendingPathComponent("sticky-1770", isDirectory: true)
            let r4Child0700UnderSticky1770 = r4Sticky1770Parent.appendingPathComponent("child-0700", isDirectory: true)

            for dir in [
                r4SafeHome, r4Child0700Under0755, r4Child0755Under0755,
                r4Child0700Under0770, r4Child0700Under0777, r4DeepChild0700,
                r4Home0700Under0770, r4Child0700UnderSticky1777, r4Child0700UnderSticky1770,
            ] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            for (dir, mode) in [
                (r4SafeHome, mode_t(0o700)),
                (r4Owned0755Parent, mode_t(0o755)),
                (r4Child0700Under0755, mode_t(0o700)),
                (r4Child0755Under0755, mode_t(0o755)),
                (r4Child0700Under0770, mode_t(0o700)),
                (r4Unsafe0770Parent, mode_t(0o770)),
                (r4Child0700Under0777, mode_t(0o700)),
                (r4Unsafe0777Parent, mode_t(0o777)),
                (r4DeepChild0700, mode_t(0o700)),
                (r4Mid0755, mode_t(0o755)),
                (r4Deep0770Grandparent, mode_t(0o770)),
                (r4Home0700Under0770, mode_t(0o700)),
                (r4UnsafeHomeParent, mode_t(0o770)),
                (r4Child0700UnderSticky1777, mode_t(0o700)),
                (r4Sticky1777Parent, mode_t(0o1777)),
                (r4Child0700UnderSticky1770, mode_t(0o700)),
                (r4Sticky1770Parent, mode_t(0o1770)),
            ] {
                try check(chmod(dir.path, mode) == 0 && fileMode(dir.path) == Int(mode),
                          "[R4-P2-1] set mode \(String(mode, radix: 8)) on \(dir.lastPathComponent)")
            }
            defer {
                for d in [r4Unsafe0770Parent, r4Unsafe0777Parent, r4Deep0770Grandparent, r4UnsafeHomeParent, r4Sticky1777Parent, r4Sticky1770Parent] {
                    _ = chmod(d.path, 0o700)
                }
            }

            let r4Control0700 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": r4Child0700Under0755.path],
                processEnvironment: ["HOME": r4SafeHome.path]
            )
            let r4Control0755 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r4Child0755Under0755.path],
                processEnvironment: ["HOME": r4SafeHome.path]
            )
            let r4Sticky1777 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": r4Child0700UnderSticky1777.path],
                processEnvironment: ["HOME": r4SafeHome.path]
            )
            let r4Sticky1770 = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r4Child0700UnderSticky1770.path],
                processEnvironment: ["HOME": r4SafeHome.path]
            )
            try check(canonicalPath(r4Control0700) == canonicalPath(r4Child0700Under0755)
                        && canonicalPath(r4Control0755) == canonicalPath(r4Child0755Under0755)
                        && canonicalPath(r4Sticky1777) == canonicalPath(r4Child0700UnderSticky1777)
                        && canonicalPath(r4Sticky1770) == canonicalPath(r4Child0700UnderSticky1770),
                      "[R4-P2-1] owned 0755 parent and sticky 1777/1770 controls remain accepted")

            // Sticky system /tmp and /private/tmp spelling controls
            let stickyControlTarget: URL
            var ephemeralStickyRoot: URL?
            let canon0755Child = canonicalPath(r4Child0700Under0755)
            if canon0755Child.hasPrefix("/private/tmp/") {
                stickyControlTarget = URL(fileURLWithPath: canon0755Child, isDirectory: true)
            } else {
                let holder = URL(fileURLWithPath: "/private/tmp/aiusage-r4-sticky-\(UUID().uuidString)", isDirectory: true)
                let child = holder.appendingPathComponent("child-0700", isDirectory: true)
                try fm.createDirectory(at: child, withIntermediateDirectories: true)
                _ = chmod(holder.path, 0o700)
                _ = chmod(child.path, 0o700)
                ephemeralStickyRoot = holder
                stickyControlTarget = child
            }
            defer { if let ephemeralStickyRoot { try? fm.removeItem(at: ephemeralStickyRoot) } }
            let privateTmpSpelling = canonicalPath(stickyControlTarget)
            let tmpAliasSpelling = "/tmp/" + String(privateTmpSpelling.dropFirst("/private/tmp/".count))
            let pickedPrivateTmp = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": privateTmpSpelling],
                processEnvironment: ["HOME": r4SafeHome.path]
            )
            let pickedTmpAlias = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": tmpAliasSpelling],
                processEnvironment: ["HOME": r4SafeHome.path]
            )
            try check(canonicalPath(pickedPrivateTmp) == privateTmpSpelling
                        && canonicalPath(pickedTmpAlias) == privateTmpSpelling,
                      "[R4-P2-1] sticky macOS /tmp and /private/tmp controls remain accepted")

            // Reject non-sticky 0770/0777 ancestors and HOME fallback under 0770 ancestor
            for (label, unsafeLeaf) in [
                ("0770-parent", r4Child0700Under0770),
                ("0777-parent", r4Child0700Under0777),
                ("0770-grandparent", r4DeepChild0700),
            ] {
                let pickedFromOverridesAndEnv = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                    overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": unsafeLeaf.path, "TMPDIR": unsafeLeaf.path],
                    processEnvironment: [
                        "AIUSAGE_TEST_FIXTURE_ROOT": r4DeepChild0700.path,
                        "TMPDIR": r4Child0700Under0777.path,
                        "HOME": r4SafeHome.path,
                    ]
                )
                try check(canonicalPath(pickedFromOverridesAndEnv) != canonicalPath(unsafeLeaf)
                            && canonicalPath(pickedFromOverridesAndEnv) != canonicalPath(r4DeepChild0700)
                            && canonicalPath(pickedFromOverridesAndEnv) != canonicalPath(r4Child0700Under0777)
                            && isVerifiedSafeTempDir(pickedFromOverridesAndEnv),
                          "[R4-P2-1] rejects \(label) across override and process keys and selects ancestor-safe fallback")
            }

            let rejectedUnsafeHomeFallback = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r4Child0700Under0770.path, "TMPDIR": r4Child0700Under0777.path],
                processEnvironment: ["HOME": r4Home0700Under0770.path]
            )
            let r4SentinelSafeOrClosed = isVerifiedSafeTempDir(rejectedUnsafeHomeFallback)
                || rejectedUnsafeHomeFallback.path == "/var/empty/aiusage-unverified-temporary-root"
            try check(canonicalPath(rejectedUnsafeHomeFallback) != canonicalPath(r4Child0700Under0770)
                        && canonicalPath(rejectedUnsafeHomeFallback) != canonicalPath(r4Child0700Under0777)
                        && !canonicalPath(rejectedUnsafeHomeFallback).hasPrefix(canonicalPath(r4Home0700Under0770))
                        && !fm.fileExists(atPath: r4Home0700Under0770.appendingPathComponent(".aiusage-tmp").path)
                        && r4SentinelSafeOrClosed,
                      "[R4-P2-1] rejects unsafe-ancestor HOME fallback without creating .aiusage-tmp inside it")

            let r4ValidXDG = r4Root.appendingPathComponent("valid-xdg", isDirectory: true)
            let r4WalDB = try seedSyntheticOpenCodeDB(at: r4ValidXDG.appendingPathComponent("opencode", isDirectory: true), walMode: true)
            defer { if let r4WalDB { sqlite3_close(r4WalDB) } }

            for (label, targetLeaf, parentDir) in [
                ("0770-ancestor", r4Child0700Under0770, r4Unsafe0770Parent),
                ("0777-ancestor", r4Child0700Under0777, r4Unsafe0777Parent),
                ("0770-grandparent", r4DeepChild0700, r4Deep0770Grandparent),
            ] {
                r3SnapshotBox.clear()
                let env = [
                    "XDG_DATA_HOME": r4ValidXDG.path,
                    "TMPDIR": targetLeaf.path,
                    "AIUSAGE_TEST_FIXTURE_ROOT": targetLeaf.path,
                    "HOME": r4SafeHome.path,
                ]
                let callRes = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                    OpenCodeCallEventSource(homeDirectory: r4SafeHome.path, timeZone: utc, environment: env).collect(cutoff: nil)
                }
                let costRes = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                    try await OpenCodeCostProvider(
                        homeDirectory: r4SafeHome.appendingPathComponent("cost-r4-\(label)").path,
                        timeZone: utc,
                        environment: env
                    ).fetchUsage()
                }
                let obs = r3SnapshotBox.items()
                try check(callRes.status.errorCode == nil
                            && callRes.entries.first(where: { $0.name == "bash" }) != nil
                            && (costRes.extra["overall.totalTokens"]?.value as? Int) == 50
                            && obs.count == 2
                            && obs.allSatisfy { item in
                                let snapParent = item.dir.deletingLastPathComponent()
                                return item.mode == 0o700
                                    && isVerifiedSafeTempDir(snapParent)
                                    && canonicalPath(snapParent) != canonicalPath(targetLeaf)
                                    && !canonicalPath(snapParent).hasPrefix(canonicalPath(parentDir))
                                    && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                            }
                            && ((try? fm.contentsOfDirectory(atPath: targetLeaf.path)) ?? ["nonempty"]).isEmpty,
                          "[R4-P2-1] snapshot consumers reject \(label) leaf and leave it empty")
            }

            // Positive snapshot control under owned 0755 parent -> 0700 leaf
            r3SnapshotBox.clear()
            let r4ControlEnv = [
                "XDG_DATA_HOME": r4ValidXDG.path,
                "TMPDIR": r4Child0700Under0755.path,
                "AIUSAGE_TEST_FIXTURE_ROOT": r4Child0700Under0755.path,
                "HOME": r4SafeHome.path,
            ]
            let r4ControlCall = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                OpenCodeCallEventSource(homeDirectory: r4SafeHome.path, timeZone: utc, environment: r4ControlEnv).collect(cutoff: nil)
            }
            let r4ControlCost = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r3Observer) {
                try await OpenCodeCostProvider(
                    homeDirectory: r4SafeHome.appendingPathComponent("cost-r4-0755-control").path,
                    timeZone: utc,
                    environment: r4ControlEnv
                ).fetchUsage()
            }
            let r4ControlObs = r3SnapshotBox.items()
            try check(r4ControlCall.status.errorCode == nil
                        && r4ControlCall.entries.first(where: { $0.name == "bash" }) != nil
                        && (r4ControlCost.extra["overall.totalTokens"]?.value as? Int) == 50
                        && r4ControlObs.count == 2
                        && r4ControlObs.allSatisfy {
                            $0.mode == 0o700
                                && canonicalPath($0.dir.deletingLastPathComponent()) == canonicalPath(r4Child0700Under0755)
                                && $0.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                        }
                        && ((try? fm.contentsOfDirectory(atPath: r4Child0700Under0755.path)) ?? ["nonempty"]).isEmpty,
                      "[R4-P2-1] owned 0755 parent control continues to host 0700/0600 snapshot isolation cleanly")

            // R5-P2-1: Reject extended ACL grants and unassessable ACL candidates while preserving deny-only & benign read/traverse ACLs
            func applyExtendedACL(
                to path: String,
                tag: acl_tag_t,
                uuid: inout uuid_t,
                perms: acl_permset_mask_t,
                flags: [acl_flag_t] = []
            ) -> Bool {
                var acl: acl_t? = acl_init(1)
                guard acl != nil else { return false }
                defer { if let acl { acl_free(UnsafeMutableRawPointer(acl)) } }
                var entry: acl_entry_t?
                guard acl_create_entry(&acl, &entry) == 0, let entry, let currentACL = acl else { return false }
                guard acl_set_tag_type(entry, tag) == 0 else { return false }
                let qrc = withUnsafeBytes(of: &uuid) { raw -> Int32 in
                    guard let base = raw.baseAddress else { return -1 }
                    return acl_set_qualifier(entry, base)
                }
                guard qrc == 0, acl_set_permset_mask_np(entry, perms) == 0 else { return false }
                if !flags.isEmpty {
                    var flagset: acl_flagset_t?
                    guard acl_get_flagset_np(UnsafeMutableRawPointer(entry), &flagset) == 0, let flagset else { return false }
                    for flag in flags {
                        guard acl_add_flag_np(flagset, flag) == 0 else { return false }
                    }
                }
                return acl_set_link_np(path, ACL_TYPE_EXTENDED, currentACL) == 0
            }

            func clearExtendedACL(_ path: String) {
                guard let fs = filesec_init() else { return }
                defer { filesec_free(fs) }
                var removeSentinel = UnsafeMutableRawPointer(bitPattern: 1)
                if filesec_set_property(fs, FILESEC_ACL, &removeSentinel) == 0 {
                    _ = chmodx_np(path, fs)
                }
            }

            @Sendable func hasNoExtendedACL(_ path: String) -> Bool {
                errno = 0
                if let acl = acl_get_link_np(path, ACL_TYPE_EXTENDED) {
                    acl_free(UnsafeMutableRawPointer(acl))
                    return false
                }
                return errno == ENOENT || errno == ENOTSUP || errno == EOPNOTSUPP
            }

            var everyoneUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            var selfUUID: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            try check(mbr_gid_to_uuid(12, &everyoneUUID) == 0 && mbr_uid_to_uuid(geteuid(), &selfUUID) == 0,
                      "[R5-P2-1] resolve synthetic ACL UUIDs for group:everyone and owner UID")

            let r5Root = isolationRoot.appendingPathComponent("r5-acl-checks", isDirectory: true)
            let r5SafeHome = r5Root.appendingPathComponent("safe-home", isDirectory: true)
            let r5DelChildParent = r5Root.appendingPathComponent("acl-delchild-parent-0755", isDirectory: true)
            let r5DelChildLeaf = r5DelChildParent.appendingPathComponent("child-0700", isDirectory: true)
            let r5DelLeafParent = r5Root.appendingPathComponent("clean-parent-delleaf-0755", isDirectory: true)
            let r5DelLeaf = r5DelLeafParent.appendingPathComponent("acl-del-child-0700", isDirectory: true)
            let r5GrandACL = r5Root.appendingPathComponent("acl-grandparent-0755", isDirectory: true)
            let r5GrandMid = r5GrandACL.appendingPathComponent("mid-0755", isDirectory: true)
            let r5GrandLeaf = r5GrandMid.appendingPathComponent("child-0700", isDirectory: true)
            let r5StickyACLParent = r5Root.appendingPathComponent("acl-sticky-1777", isDirectory: true)
            let r5StickyACLLeaf = r5StickyACLParent.appendingPathComponent("child-0700", isDirectory: true)
            let r5InheritParent = r5Root.appendingPathComponent("clean-parent-inherit-0755", isDirectory: true)
            let r5InheritLeaf = r5InheritParent.appendingPathComponent("acl-inherit-child-0700", isDirectory: true)
            let r5UnassessableParent = r5Root.appendingPathComponent("acl-deny-readsec-parent-0755", isDirectory: true)
            let r5UnassessableLeaf = r5UnassessableParent.appendingPathComponent("child-0700", isDirectory: true)
            let r5UnsafeHomeParent = r5Root.appendingPathComponent("acl-home-parent-0755", isDirectory: true)
            let r5UnsafeHomeLeaf = r5UnsafeHomeParent.appendingPathComponent("home-0700", isDirectory: true)

            let r5DenyDelParent = r5Root.appendingPathComponent("acl-deny-del-parent-0755", isDirectory: true)
            let r5DenyDelParentLeaf = r5DenyDelParent.appendingPathComponent("child-0700", isDirectory: true)
            let r5DenyDelLeafParent = r5Root.appendingPathComponent("clean-parent-denydel-0755", isDirectory: true)
            let r5DenyDelLeaf = r5DenyDelLeafParent.appendingPathComponent("acl-denydel-child-0700", isDirectory: true)
            let r5BenignParent = r5Root.appendingPathComponent("acl-benign-parent-0755", isDirectory: true)
            let r5BenignParentLeaf = r5BenignParent.appendingPathComponent("child-0700", isDirectory: true)
            let r5BenignLeafParent = r5Root.appendingPathComponent("clean-parent-benignleaf-0755", isDirectory: true)
            let r5BenignLeaf0755 = r5BenignLeafParent.appendingPathComponent("acl-benign-child-0755", isDirectory: true)
            let r5SelfAllowParent = r5Root.appendingPathComponent("acl-self-allow-parent-0755", isDirectory: true)
            let r5SelfAllowLeaf = r5SelfAllowParent.appendingPathComponent("child-0700", isDirectory: true)

            for dir in [
                r5SafeHome, r5DelChildLeaf, r5DelLeaf, r5GrandLeaf, r5StickyACLLeaf,
                r5InheritLeaf, r5UnassessableLeaf, r5UnsafeHomeLeaf, r5DenyDelParentLeaf,
                r5DenyDelLeaf, r5BenignParentLeaf, r5BenignLeaf0755, r5SelfAllowLeaf,
            ] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            let r5AllManagedDirs = [
                r5SafeHome, r5DelChildParent, r5DelChildLeaf, r5DelLeafParent, r5DelLeaf,
                r5GrandACL, r5GrandMid, r5GrandLeaf, r5StickyACLParent, r5StickyACLLeaf,
                r5InheritParent, r5InheritLeaf, r5UnassessableParent, r5UnassessableLeaf,
                r5UnsafeHomeParent, r5UnsafeHomeLeaf, r5DenyDelParent, r5DenyDelParentLeaf,
                r5DenyDelLeafParent, r5DenyDelLeaf, r5BenignParent, r5BenignParentLeaf,
                r5BenignLeafParent, r5BenignLeaf0755, r5SelfAllowParent, r5SelfAllowLeaf,
            ]
            defer {
                for dir in r5AllManagedDirs {
                    clearExtendedACL(dir.path)
                    _ = chmod(dir.path, 0o700)
                }
            }
            for (dir, mode) in [
                (r5SafeHome, mode_t(0o700)),
                (r5DelChildParent, mode_t(0o755)), (r5DelChildLeaf, mode_t(0o700)),
                (r5DelLeafParent, mode_t(0o755)), (r5DelLeaf, mode_t(0o700)),
                (r5GrandACL, mode_t(0o755)), (r5GrandMid, mode_t(0o755)), (r5GrandLeaf, mode_t(0o700)),
                (r5StickyACLParent, mode_t(0o1777)), (r5StickyACLLeaf, mode_t(0o700)),
                (r5InheritParent, mode_t(0o755)), (r5InheritLeaf, mode_t(0o700)),
                (r5UnassessableParent, mode_t(0o755)), (r5UnassessableLeaf, mode_t(0o700)),
                (r5UnsafeHomeParent, mode_t(0o755)), (r5UnsafeHomeLeaf, mode_t(0o700)),
                (r5DenyDelParent, mode_t(0o755)), (r5DenyDelParentLeaf, mode_t(0o700)),
                (r5DenyDelLeafParent, mode_t(0o755)), (r5DenyDelLeaf, mode_t(0o700)),
                (r5BenignParent, mode_t(0o755)), (r5BenignParentLeaf, mode_t(0o700)),
                (r5BenignLeafParent, mode_t(0o755)), (r5BenignLeaf0755, mode_t(0o755)),
                (r5SelfAllowParent, mode_t(0o755)), (r5SelfAllowLeaf, mode_t(0o700)),
            ] {
                try check(chmod(dir.path, mode) == 0 && fileMode(dir.path) == Int(mode),
                          "[R5-P2-1] set mode \(String(mode, radix: 8)) on \(dir.lastPathComponent)")
            }

            let benignACLMask: acl_permset_mask_t = [
                ACL_READ_DATA, ACL_EXECUTE, ACL_READ_ATTRIBUTES,
                ACL_READ_EXTATTRIBUTES, ACL_READ_SECURITY, ACL_SYNCHRONIZE,
            ].reduce(0) { $0 | acl_permset_mask_t($1.rawValue) }
            let mutatingGrandMask: acl_permset_mask_t = [
                ACL_WRITE_DATA, ACL_APPEND_DATA, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER,
            ].reduce(0) { $0 | acl_permset_mask_t($1.rawValue) }
            let selfAllowMask: acl_permset_mask_t = [
                ACL_READ_DATA, ACL_WRITE_DATA, ACL_EXECUTE,
                ACL_DELETE, ACL_APPEND_DATA, ACL_DELETE_CHILD,
            ].reduce(0) { $0 | acl_permset_mask_t($1.rawValue) }

            // Positive ACL controls first (and negative ACL controls next, with unassessable parent applied separately)
            try check(
                applyExtendedACL(to: r5DelChildParent.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_DELETE_CHILD.rawValue))
                && applyExtendedACL(to: r5DelLeaf.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_DELETE.rawValue))
                && applyExtendedACL(to: r5GrandACL.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: mutatingGrandMask)
                && applyExtendedACL(to: r5StickyACLParent.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_DELETE_CHILD.rawValue))
                && applyExtendedACL(to: r5InheritLeaf.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_READ_DATA.rawValue | ACL_EXECUTE.rawValue), flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT])
                && applyExtendedACL(to: r5UnsafeHomeParent.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_DELETE_CHILD.rawValue))
                && applyExtendedACL(to: r5UnassessableParent.path, tag: ACL_EXTENDED_DENY, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_READ_SECURITY.rawValue))
                && applyExtendedACL(to: r5DenyDelParent.path, tag: ACL_EXTENDED_DENY, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_DELETE.rawValue))
                && applyExtendedACL(to: r5DenyDelLeaf.path, tag: ACL_EXTENDED_DENY, uuid: &everyoneUUID, perms: acl_permset_mask_t(ACL_DELETE.rawValue))
                && applyExtendedACL(to: r5BenignParent.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: benignACLMask)
                && applyExtendedACL(to: r5BenignLeaf0755.path, tag: ACL_EXTENDED_ALLOW, uuid: &everyoneUUID, perms: benignACLMask)
                && applyExtendedACL(to: r5SelfAllowParent.path, tag: ACL_EXTENDED_ALLOW, uuid: &selfUUID, perms: selfAllowMask),
                "[R5-P2-1] attach synthetic APFS negative and positive ACLs"
            )

            for (label, positiveLeaf) in [
                ("deny-delete-parent", r5DenyDelParentLeaf),
                ("deny-delete-leaf", r5DenyDelLeaf),
                ("benign-read-traverse-parent", r5BenignParentLeaf),
                ("benign-noninherit-read-leaf-0755", r5BenignLeaf0755),
                ("trusted-owner-allow-parent", r5SelfAllowLeaf),
            ] {
                let picked = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                    overrides: ["TMPDIR": positiveLeaf.path],
                    processEnvironment: ["HOME": r5SafeHome.path]
                )
                try check(canonicalPath(picked) == canonicalPath(positiveLeaf)
                            && isVerifiedSafeTempDir(picked),
                          "[R5-P2-1] positive ACL control '\(label)' remains accepted")
            }

            // Sticky /tmp and /private/tmp spelling controls preserved alongside ACL check
            let r5PickedPrivate = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": privateTmpSpelling],
                processEnvironment: ["HOME": r5SafeHome.path]
            )
            let r5PickedTmp = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["TMPDIR": tmpAliasSpelling],
                processEnvironment: ["HOME": r5SafeHome.path]
            )
            try check(canonicalPath(r5PickedPrivate) == privateTmpSpelling
                        && canonicalPath(r5PickedTmp) == privateTmpSpelling,
                      "[R5-P2-1] sticky macOS /tmp and /private/tmp controls remain accepted with ACL verification")

            for (label, unsafeLeaf) in [
                ("0755-parent-allow-delete_child", r5DelChildLeaf),
                ("0700-leaf-allow-delete", r5DelLeaf),
                ("0755-grandparent-allow-write_sec_chown", r5GrandLeaf),
                ("sticky-1777-parent-allow-delete_child", r5StickyACLLeaf),
                ("0700-leaf-inheritable-read", r5InheritLeaf),
                ("0755-parent-unassessable-deny-readsec", r5UnassessableLeaf),
            ] {
                let picked = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                    overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": unsafeLeaf.path, "TMPDIR": unsafeLeaf.path],
                    processEnvironment: [
                        "AIUSAGE_TEST_FIXTURE_ROOT": r5DelChildLeaf.path,
                        "TMPDIR": r5UnassessableLeaf.path,
                        "HOME": r5SafeHome.path,
                    ]
                )
                try check(canonicalPath(picked) != canonicalPath(unsafeLeaf)
                            && canonicalPath(picked) != canonicalPath(r5DelChildLeaf)
                            && canonicalPath(picked) != canonicalPath(r5UnassessableLeaf)
                            && isVerifiedSafeTempDir(picked),
                          "[R5-P2-1] negative ACL case '\(label)' rejected across override and process keys")
            }

            let rejectedACLHomeFallback = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r5DelChildLeaf.path, "TMPDIR": r5InheritLeaf.path],
                processEnvironment: ["HOME": r5UnsafeHomeLeaf.path]
            )
            let r5SentinelSafeOrClosed = isVerifiedSafeTempDir(rejectedACLHomeFallback)
                || rejectedACLHomeFallback.path == "/var/empty/aiusage-unverified-temporary-root"
            try check(canonicalPath(rejectedACLHomeFallback) != canonicalPath(r5DelChildLeaf)
                        && canonicalPath(rejectedACLHomeFallback) != canonicalPath(r5InheritLeaf)
                        && !canonicalPath(rejectedACLHomeFallback).hasPrefix(canonicalPath(r5UnsafeHomeParent))
                        && !fm.fileExists(atPath: r5UnsafeHomeLeaf.appendingPathComponent(".aiusage-tmp").path)
                        && r5SentinelSafeOrClosed,
                      "[R5-P2-1] rejects ACL-unsafe HOME fallback without creating .aiusage-tmp inside it")

            let r5ValidXDG = r5Root.appendingPathComponent("valid-xdg", isDirectory: true)
            let r5WalDB = try seedSyntheticOpenCodeDB(at: r5ValidXDG.appendingPathComponent("opencode", isDirectory: true), walMode: true)
            defer { if let r5WalDB { sqlite3_close(r5WalDB) } }

            final class SnapshotACLBox: @unchecked Sendable {
                private let lock = NSLock()
                private var itemsList: [Bool] = []
                func record(_ allACLFree: Bool) { lock.withLock { itemsList.append(allACLFree) } }
                func values() -> [Bool] { lock.withLock { itemsList } }
                func clear() { lock.withLock { itemsList.removeAll() } }
            }
            let r5ACLBox = SnapshotACLBox()
            let r5Observer: @Sendable (URL) -> Void = { dir in
                r3Observer(dir)
                var allClean = hasNoExtendedACL(dir.path)
                for name in ["opencode.db", "opencode.db-wal", "opencode.db-shm"] {
                    allClean = allClean && hasNoExtendedACL(dir.appendingPathComponent(name).path)
                }
                r5ACLBox.record(allClean)
            }

            for (label, targetLeaf, excludedPrefix) in [
                ("acl-allow-delete_child-parent", r5DelChildLeaf, r5DelChildParent),
                ("acl-allow-delete-leaf", r5DelLeaf, r5DelLeaf),
                ("acl-inheritable-leaf", r5InheritLeaf, r5InheritLeaf),
                ("acl-unassessable-parent", r5UnassessableLeaf, r5UnassessableParent),
            ] {
                r3SnapshotBox.clear()
                r5ACLBox.clear()
                let env = [
                    "XDG_DATA_HOME": r5ValidXDG.path,
                    "TMPDIR": targetLeaf.path,
                    "AIUSAGE_TEST_FIXTURE_ROOT": targetLeaf.path,
                    "HOME": r5SafeHome.path,
                ]
                let callRes = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                    OpenCodeCallEventSource(homeDirectory: r5SafeHome.path, timeZone: utc, environment: env).collect(cutoff: nil)
                }
                let costRes = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                    try await OpenCodeCostProvider(
                        homeDirectory: r5SafeHome.appendingPathComponent("cost-r5-neg-\(label)").path,
                        timeZone: utc,
                        environment: env
                    ).fetchUsage()
                }
                let obs = r3SnapshotBox.items()
                let aclClean = r5ACLBox.values()
                try check(callRes.status.errorCode == nil
                            && callRes.entries.first(where: { $0.name == "bash" }) != nil
                            && (costRes.extra["overall.totalTokens"]?.value as? Int) == 50
                            && obs.count == 2
                            && aclClean == [true, true]
                            && obs.allSatisfy { item in
                                let snapParent = item.dir.deletingLastPathComponent()
                                return item.mode == 0o700
                                    && isVerifiedSafeTempDir(snapParent)
                                    && canonicalPath(snapParent) != canonicalPath(targetLeaf)
                                    && !canonicalPath(snapParent).hasPrefix(canonicalPath(excludedPrefix))
                                    && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                            }
                            && ((try? fm.contentsOfDirectory(atPath: targetLeaf.path)) ?? ["nonempty"]).isEmpty,
                          "[R5-P2-1] OpenCode consumers reject '\(label)', use ACL-safe fallback, and leave unsafe leaf empty")
            }

            for (label, positiveLeaf) in [
                ("acl-deny-delete-parent", r5DenyDelParentLeaf),
                ("acl-benign-read-parent", r5BenignParentLeaf),
                ("acl-trusted-owner-parent", r5SelfAllowLeaf),
            ] {
                r3SnapshotBox.clear()
                r5ACLBox.clear()
                let env = [
                    "XDG_DATA_HOME": r5ValidXDG.path,
                    "TMPDIR": positiveLeaf.path,
                    "AIUSAGE_TEST_FIXTURE_ROOT": positiveLeaf.path,
                    "HOME": r5SafeHome.path,
                ]
                let callRes = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                    OpenCodeCallEventSource(homeDirectory: r5SafeHome.path, timeZone: utc, environment: env).collect(cutoff: nil)
                }
                let costRes = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                    try await OpenCodeCostProvider(
                        homeDirectory: r5SafeHome.appendingPathComponent("cost-r5-pos-\(label)").path,
                        timeZone: utc,
                        environment: env
                    ).fetchUsage()
                }
                let obs = r3SnapshotBox.items()
                let aclClean = r5ACLBox.values()
                try check(callRes.status.errorCode == nil
                            && callRes.entries.first(where: { $0.name == "bash" }) != nil
                            && (costRes.extra["overall.totalTokens"]?.value as? Int) == 50
                            && obs.count == 2
                            && aclClean == [true, true]
                            && obs.allSatisfy { item in
                                item.mode == 0o700
                                    && canonicalPath(item.dir.deletingLastPathComponent()) == canonicalPath(positiveLeaf)
                                    && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                            }
                            && ((try? fm.contentsOfDirectory(atPath: positiveLeaf.path)) ?? ["nonempty"]).isEmpty,
                          "[R5-P2-1] OpenCode consumers accept positive ACL control '\(label)' with zero-ACL 0700/0600 snapshot cleanup")
            }

            // R6-P2-1: Reject inheritable & delete-child-blocking deny ACLs on candidate temp leaf without modifying user ACLs
            func clearTreeExtendedACL(_ rootPath: String) {
                guard let fs = filesec_init() else { return }
                defer { filesec_free(fs) }
                var removeSentinel = UnsafeMutableRawPointer(bitPattern: 1)
                guard filesec_set_property(fs, FILESEC_ACL, &removeSentinel) == 0 else { return }
                if let enumerator = fm.enumerator(atPath: rootPath) {
                    var children: [String] = []
                    while let rel = enumerator.nextObject() as? String {
                        children.append((rootPath as NSString).appendingPathComponent(rel))
                    }
                    for child in children.reversed() {
                        _ = chmodx_np(child, fs)
                        _ = chmod(child, 0o700)
                    }
                }
                _ = chmodx_np(rootPath, fs)
                _ = chmod(rootPath, 0o700)
            }

            let r6Root = isolationRoot.appendingPathComponent("r6-deny-retention-checks", isDirectory: true)
            let r6SafeHome = r6Root.appendingPathComponent("safe-home", isDirectory: true)
            let r6CleanFallback = r6Root.appendingPathComponent("clean-fallback-0700", isDirectory: true)
            let r6InhOnlyDenyLeaf = r6Root.appendingPathComponent("inh-only-deny-del-delchild-0700", isDirectory: true)
            let r6FileInheritDenyLeaf = r6Root.appendingPathComponent("file-inherit-deny-del-0700", isDirectory: true)
            let r6DirInheritDenyLeaf = r6Root.appendingPathComponent("dir-inherit-deny-del-0700", isDirectory: true)
            let r6InhDenyReadSecLeaf = r6Root.appendingPathComponent("inh-only-deny-readsec-0700", isDirectory: true)
            let r6DirectDenyDelChildLeaf = r6Root.appendingPathComponent("noninh-deny-delchild-0700", isDirectory: true)
            let r6UnsafeDenyHomeLeaf = r6Root.appendingPathComponent("inh-deny-home-0700", isDirectory: true)
            let r6NonInhDenyDeleteLeaf = r6Root.appendingPathComponent("noninh-deny-del-positive-0700", isDirectory: true)

            let r6Leaves = [
                r6SafeHome, r6CleanFallback, r6InhOnlyDenyLeaf, r6FileInheritDenyLeaf,
                r6DirInheritDenyLeaf, r6InhDenyReadSecLeaf, r6DirectDenyDelChildLeaf,
                r6UnsafeDenyHomeLeaf, r6NonInhDenyDeleteLeaf,
            ]
            for dir in r6Leaves {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            defer { clearTreeExtendedACL(r6Root.path) }
            for dir in r6Leaves {
                try check(chmod(dir.path, 0o700) == 0 && fileMode(dir.path) == 0o700,
                          "[R6-P2-1] set mode 0700 on \(dir.lastPathComponent)")
            }

            try check(
                applyExtendedACL(
                    to: r6InhOnlyDenyLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_DELETE.rawValue | ACL_DELETE_CHILD.rawValue),
                    flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                )
                && applyExtendedACL(
                    to: r6FileInheritDenyLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_DELETE.rawValue),
                    flags: [ACL_ENTRY_FILE_INHERIT]
                )
                && applyExtendedACL(
                    to: r6DirInheritDenyLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_DELETE.rawValue),
                    flags: [ACL_ENTRY_DIRECTORY_INHERIT]
                )
                && applyExtendedACL(
                    to: r6InhDenyReadSecLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_READ_SECURITY.rawValue),
                    flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                )
                && applyExtendedACL(
                    to: r6DirectDenyDelChildLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_DELETE_CHILD.rawValue)
                )
                && applyExtendedACL(
                    to: r6UnsafeDenyHomeLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_DELETE.rawValue | ACL_DELETE_CHILD.rawValue),
                    flags: [ACL_ENTRY_FILE_INHERIT, ACL_ENTRY_DIRECTORY_INHERIT, ACL_ENTRY_ONLY_INHERIT]
                )
                && applyExtendedACL(
                    to: r6NonInhDenyDeleteLeaf.path,
                    tag: ACL_EXTENDED_DENY,
                    uuid: &everyoneUUID,
                    perms: acl_permset_mask_t(ACL_DELETE.rawValue)
                ),
                "[R6-P2-1] attach synthetic APFS retention-deny and benign deny-delete ACLs"
            )

            // Negative retention-ACL leaves must reject without mutating the user's ACL
            let r6NegCases: [(String, URL)] = [
                ("inh-only-deny-delete-delete_child", r6InhOnlyDenyLeaf),
                ("file-inherit-deny-delete", r6FileInheritDenyLeaf),
                ("dir-inherit-deny-delete", r6DirInheritDenyLeaf),
                ("inh-only-deny-read_security", r6InhDenyReadSecLeaf),
                ("noninh-deny-delete_child", r6DirectDenyDelChildLeaf),
            ]
            for (label, unsafeLeaf) in r6NegCases {
                let picked = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                    overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": unsafeLeaf.path, "TMPDIR": unsafeLeaf.path],
                    processEnvironment: ["TMPDIR": r6CleanFallback.path, "HOME": r6SafeHome.path]
                )
                try check(canonicalPath(picked) == canonicalPath(r6CleanFallback)
                            && canonicalPath(picked) != canonicalPath(unsafeLeaf)
                            && isVerifiedSafeTempDir(picked)
                            && !hasNoExtendedACL(unsafeLeaf.path),
                          "[R6-P2-1] rejects '\(label)' via process fallback without altering leaf ACL")
            }

            let rejectedR6HomeFallback = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                overrides: ["AIUSAGE_TEST_FIXTURE_ROOT": r6InhOnlyDenyLeaf.path, "TMPDIR": r6DirectDenyDelChildLeaf.path],
                processEnvironment: ["HOME": r6UnsafeDenyHomeLeaf.path]
            )
            let r6SentinelSafeOrClosed = isVerifiedSafeTempDir(rejectedR6HomeFallback)
                || rejectedR6HomeFallback.path == "/var/empty/aiusage-unverified-temporary-root"
            try check(canonicalPath(rejectedR6HomeFallback) != canonicalPath(r6InhOnlyDenyLeaf)
                        && canonicalPath(rejectedR6HomeFallback) != canonicalPath(r6DirectDenyDelChildLeaf)
                        && !canonicalPath(rejectedR6HomeFallback).hasPrefix(canonicalPath(r6UnsafeDenyHomeLeaf))
                        && !fm.fileExists(atPath: r6UnsafeDenyHomeLeaf.appendingPathComponent(".aiusage-tmp").path)
                        && r6SentinelSafeOrClosed,
                      "[R6-P2-1] rejects inheritable-deny HOME fallback without creating .aiusage-tmp inside it")

            // Positive controls preserved: non-inheritable deny-delete leaf & parent, 0755 parent, and sticky /tmp /private/tmp
            for (label, positiveURL, expectedPath) in [
                ("noninh-deny-delete-0700-leaf", r6NonInhDenyDeleteLeaf, canonicalPath(r6NonInhDenyDeleteLeaf)),
                ("noninh-deny-delete-0755-parent", r5DenyDelParentLeaf, canonicalPath(r5DenyDelParentLeaf)),
                ("plain-0755-parent-control", r4Child0700Under0755, canonicalPath(r4Child0700Under0755)),
                ("sticky-private-tmp-control", URL(fileURLWithPath: privateTmpSpelling, isDirectory: true), privateTmpSpelling),
                ("sticky-tmp-alias-control", URL(fileURLWithPath: tmpAliasSpelling, isDirectory: true), privateTmpSpelling),
            ] {
                let picked = TokenSaverSettingsStore.resolvedTemporaryDirectory(
                    overrides: ["TMPDIR": positiveURL.path],
                    processEnvironment: ["HOME": r6SafeHome.path]
                )
                try check(canonicalPath(picked) == expectedPath && isVerifiedSafeTempDir(picked),
                          "[R6-P2-1] positive control '\(label)' remains accepted")
            }

            let r6ValidXDG = r6Root.appendingPathComponent("valid-xdg", isDirectory: true)
            let r6WalDB = try seedSyntheticOpenCodeDB(at: r6ValidXDG.appendingPathComponent("opencode", isDirectory: true), walMode: true)
            defer { if let r6WalDB { sqlite3_close(r6WalDB) } }

            // (a) Dedicated clean fallback in processEnvironment: verify OpenCode consumers + direct snapshot helper leave 0 snapshots in leaf and fallback
            for (label, unsafeLeaf) in r6NegCases {
                let env = [
                    "XDG_DATA_HOME": r6ValidXDG.path,
                    "AIUSAGE_TEST_FIXTURE_ROOT": unsafeLeaf.path,
                    "TMPDIR": r6CleanFallback.path,
                    "HOME": r6SafeHome.path,
                ]
                r3SnapshotBox.clear()
                r5ACLBox.clear()
                let callRes = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                    OpenCodeCallEventSource(homeDirectory: r6SafeHome.path, timeZone: utc, environment: env).collect(cutoff: nil)
                }
                let costRes = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                    try await OpenCodeCostProvider(
                        homeDirectory: r6SafeHome.appendingPathComponent("cost-r6-neg-\(label)").path,
                        timeZone: utc,
                        environment: env
                    ).fetchUsage()
                }
                let obs = r3SnapshotBox.items()
                try check(callRes.status.errorCode == nil
                            && callRes.entries.first(where: { $0.name == "bash" }) != nil
                            && (costRes.extra["overall.totalTokens"]?.value as? Int) == 50
                            && obs.count == 2
                            && r5ACLBox.values() == [true, true]
                            && obs.allSatisfy { item in
                                item.mode == 0o700
                                    && canonicalPath(item.dir.deletingLastPathComponent()) == canonicalPath(r6CleanFallback)
                                    && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                                    && !fm.fileExists(atPath: item.dir.path)
                            }
                            && ((try? fm.contentsOfDirectory(atPath: unsafeLeaf.path)) ?? ["nonempty"]).isEmpty
                            && ((try? fm.contentsOfDirectory(atPath: r6CleanFallback.path)) ?? ["nonempty"]).isEmpty
                            && !hasNoExtendedACL(unsafeLeaf.path),
                          "[R6-P2-1] OpenCode consumers reject '\(label)', use fallback, retain 0 files/dirs in both leaf and fallback, and keep leaf ACL untouched")
            }

            // Direct snapshot + cleanup helper check on R6-P2-1 exact reproducer
            let directEnv = [
                "AIUSAGE_TEST_FIXTURE_ROOT": r6InhOnlyDenyLeaf.path,
                "TMPDIR": r6CleanFallback.path,
                "HOME": r6SafeHome.path,
            ]
            let directSnapshotPath = try makeOpenCodeDatabaseSnapshot(
                dataDirectory: r6ValidXDG.appendingPathComponent("opencode", isDirectory: true).path,
                prefix: "opencode-r6-direct",
                environment: directEnv
            )
            let directSnapshotURL = URL(fileURLWithPath: directSnapshotPath, isDirectory: false).deletingLastPathComponent()
            let directInFallback = canonicalPath(directSnapshotURL.deletingLastPathComponent()) == canonicalPath(r6CleanFallback)
            cleanupOpenCodeDatabaseSnapshot(directSnapshotPath, expectedDirectoryPrefix: "opencode-r6-direct")
            try check(directInFallback
                        && !fm.fileExists(atPath: directSnapshotURL.path)
                        && ((try? fm.contentsOfDirectory(atPath: r6InhOnlyDenyLeaf.path)) ?? ["nonempty"]).isEmpty
                        && ((try? fm.contentsOfDirectory(atPath: r6CleanFallback.path)) ?? ["nonempty"]).isEmpty,
                      "[R6-P2-1] direct make/cleanupOpenCodeDatabaseSnapshot selects fallback and leaves 0 files or dirs in leaf or fallback")

            // (b) When both overrides and TMPDIR target r6InhOnlyDenyLeaf, both consumers still resolve a safe fallback with 0 retained snapshots
            let bothUnsafeEnv = [
                "XDG_DATA_HOME": r6ValidXDG.path,
                "AIUSAGE_TEST_FIXTURE_ROOT": r6InhOnlyDenyLeaf.path,
                "TMPDIR": r6InhOnlyDenyLeaf.path,
                "HOME": r6SafeHome.path,
            ]
            r3SnapshotBox.clear()
            r5ACLBox.clear()
            let callResAllUnsafe = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                OpenCodeCallEventSource(homeDirectory: r6SafeHome.path, timeZone: utc, environment: bothUnsafeEnv).collect(cutoff: nil)
            }
            let costResAllUnsafe = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                try await OpenCodeCostProvider(
                    homeDirectory: r6SafeHome.appendingPathComponent("cost-r6-all-unsafe").path,
                    timeZone: utc,
                    environment: bothUnsafeEnv
                ).fetchUsage()
            }
            let obsAllUnsafe = r3SnapshotBox.items()
            try check(callResAllUnsafe.status.errorCode == nil
                        && callResAllUnsafe.entries.first(where: { $0.name == "bash" }) != nil
                        && (costResAllUnsafe.extra["overall.totalTokens"]?.value as? Int) == 50
                        && obsAllUnsafe.count == 2
                        && r5ACLBox.values() == [true, true]
                        && obsAllUnsafe.allSatisfy { item in
                            let snapParent = item.dir.deletingLastPathComponent()
                            return item.mode == 0o700
                                && isVerifiedSafeTempDir(snapParent)
                                && canonicalPath(snapParent) != canonicalPath(r6InhOnlyDenyLeaf)
                                && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                                && !fm.fileExists(atPath: item.dir.path)
                        }
                        && ((try? fm.contentsOfDirectory(atPath: r6InhOnlyDenyLeaf.path)) ?? ["nonempty"]).isEmpty
                        && !hasNoExtendedACL(r6InhOnlyDenyLeaf.path),
                      "[R6-P2-1] OpenCode consumers leave 0 snapshots in rejected leaf or fallback even when all override/TMPDIR keys target r6InhOnlyDenyLeaf")

            // (c) Non-inheritable deny-delete 0700 leaf positive control remains directly usable and cleans up 100%
            let r6PosEnv = [
                "XDG_DATA_HOME": r6ValidXDG.path,
                "TMPDIR": r6NonInhDenyDeleteLeaf.path,
                "AIUSAGE_TEST_FIXTURE_ROOT": r6NonInhDenyDeleteLeaf.path,
                "HOME": r6SafeHome.path,
            ]
            r3SnapshotBox.clear()
            r5ACLBox.clear()
            let r6PosCall = OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                OpenCodeCallEventSource(homeDirectory: r6SafeHome.path, timeZone: utc, environment: r6PosEnv).collect(cutoff: nil)
            }
            let r6PosCost = try await OpenCodeSnapshotIsolation.$didPrepareSnapshot.withValue(r5Observer) {
                try await OpenCodeCostProvider(
                    homeDirectory: r6SafeHome.appendingPathComponent("cost-r6-pos-denydel").path,
                    timeZone: utc,
                    environment: r6PosEnv
                ).fetchUsage()
            }
            let r6PosObs = r3SnapshotBox.items()
            try check(r6PosCall.status.errorCode == nil
                        && r6PosCall.entries.first(where: { $0.name == "bash" }) != nil
                        && (r6PosCost.extra["overall.totalTokens"]?.value as? Int) == 50
                        && r6PosObs.count == 2
                        && r5ACLBox.values() == [true, true]
                        && r6PosObs.allSatisfy { item in
                            item.mode == 0o700
                                && canonicalPath(item.dir.deletingLastPathComponent()) == canonicalPath(r6NonInhDenyDeleteLeaf)
                                && item.fileModes == ["opencode.db": 0o600, "opencode.db-wal": 0o600, "opencode.db-shm": 0o600]
                                && !fm.fileExists(atPath: item.dir.path)
                        }
                        && ((try? fm.contentsOfDirectory(atPath: r6NonInhDenyDeleteLeaf.path)) ?? ["nonempty"]).isEmpty,
                      "[R6-P2-1] non-inheritable deny-delete 0700 leaf positive control hosts 0700/0600 snapshots and cleans up to 0 files/dirs")
        }
    }

}
