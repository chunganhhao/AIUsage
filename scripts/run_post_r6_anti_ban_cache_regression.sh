#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-post-r6.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

SCRATCH="${AIUSAGE_POST_R6_SWIFTPM_SCRATCH:-${TMPDIR:-/tmp}/aiusage-post-r6-swiftpm}"
swift build --build-system native --package-path "$ROOT/QuotaBackend" --scratch-path "$SCRATCH" --target QuotaBackend >/dev/null
swift build --build-system native --package-path "$ROOT/QuotaBackend" --scratch-path "$SCRATCH" --target QuotaServerCore >/dev/null
BIN="$(swift build --build-system native --package-path "$ROOT/QuotaBackend" --scratch-path "$SCRATCH" --show-bin-path)"

jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend" or .moduleName == "QuotaServerCore") | .objects[]' "$BIN/description.json" \
  | awk '!seen[$0]++' > "$REGRESSION_DIR/objects.txt"

if [[ "${AIUSAGE_ONLY_LEAN_CUT_3B:-0}" != "1" ]]; then
# 1. Backend / HTTP / Snapshot Store / Policy Regression
swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift" \
  "$ROOT/scripts/PostR6AntiBanCacheRegression.swift" \
  -o "$REGRESSION_DIR/post-r6-backend"
"$REGRESSION_DIR/post-r6-backend"

# 2. Compiled Production Coordinator + UI Fixture Proof
ruby -E UTF-8:UTF-8 - "$ROOT" "$REGRESSION_DIR" <<'RUBY'
root, output = ARGV

pipeline = File.read(File.join(root, 'AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift'))
coordinator = File.read(File.join(root, 'AIUsage/ViewModels/ProviderRefreshCoordinator.swift'))
conversion = File.read(File.join(root, 'AIUsage/ViewModels/ProviderRefreshCoordinator+Conversion.swift'))

def extract(source, name)
  pattern = /^    (?:nonisolated )?func #{Regexp.escape(name)}\(/
  start = source.index(pattern)
  abort("Missing #{name}") unless start
  brace = source.index('{', start)
  depth = 0
  index = brace
  while index < source.length
    ch = source[index]
    depth += 1 if ch == '{'
    depth -= 1 if ch == '}'
    return source[start..index] if depth == 0
    index += 1
  end
  abort("Unterminated #{name}")
end

extracted_pipeline_methods = %w[
  completeGlobalRefresh
  completeProviderRefresh
  completeAccountRefresh
  markAccountRefreshed
  resolvedTimestamp
  accountRefreshKeys
  providerMatchesRefresh
  currentProviderMatchingRefresh
  timestampableProviders
  normalizedAccountLookupValue
  accountRefreshKey
  preferredBulkRefreshProvider
].map { |name| extract(pipeline, name) }

# Also extract overload accountRefreshKey variants & coordinator production timestamp/error methods
extra_pipeline = []
pipeline.scan(/^    func accountRefreshKey\([^)]*\) -> String \{.*?^    \}/m) { |m| extra_pipeline << m }
coordinator_methods = %w[
  accountRefreshDate
  resolvedFetchedDate
  accountCheckErrorKeys
  recordAccountCheckError
  clearAccountCheckError
  lastCheckError
].map { |name| extract(coordinator, name) }

File.write(
  File.join(output, 'ExtractedCoordinatorPipeline.swift'),
  "import Foundation\nimport QuotaBackend\nextension ProviderRefreshCoordinator {\n" +
  (extracted_pipeline_methods + extra_pipeline.drop(1) + coordinator_methods).join("\n\n") +
  "\n}\n"
)

card = File.read(File.join(root, 'AIUsage/Views/ProviderCard.swift')).split(/^#Preview \{/).first
File.write(File.join(output, 'PreviewProviderCard.swift'), card)

utilities = File.read(File.join(root, 'AIUsage/Views/Utilities.swift')).split('// MARK: - Refreshable Time Views', 2).last
File.write(File.join(output, 'PreviewUtilities.swift'), "import SwiftUI\nimport Combine\nimport QuotaBackend\n" + utilities)

widgets = File.read(File.join(root, 'AIUsage/Views/AgentToolsView.swift')).split(/^struct AgentConfigToolsView\b/).first
abort 'Missing environment model fixture seam' unless widgets.sub!('static let shared = EnvironmentOverrideModel()', 'static let shared = EnvironmentOverrideModel(home: FixtureResetEnvironment.home)')
File.write(File.join(output, 'PreviewAgentWidgets.swift'), widgets)

subscription = File.read(File.join(root, 'AIUsage/Views/CodexProxyManagementView.swift')).split('struct CodexSubscriptionSection', 2).last.split('// MARK: - Codex Global Config Section', 2).first
File.write(File.join(output, 'PreviewCodexSubscriptionSection.swift'), "import SwiftUI\nimport Combine\nstruct CodexSubscriptionSection" + subscription)

toggle = File.read(File.join(root, 'AIUsage/Views/ProxyManagementView+Card.swift')).split('// MARK: - Proxy Activation Toggle Style', 2).last.split('// MARK: - Instant Tooltip Modifier', 2).first
File.write(File.join(output, 'PreviewProxyToggle.swift'), "import SwiftUI\n" + toggle)

coordinator_reset = File.read(File.join(root, 'AIUsage/ViewModels/CodexResetCreditsCoordinator.swift'))
abort 'Missing coordinator shared binding' unless coordinator_reset.sub!('static let shared = CodexResetCreditsCoordinator()', 'static var shared: CodexResetCreditsCoordinator { FixtureResetEnvironment.coordinator }')
File.write(File.join(output, 'PreviewResetCoordinator.swift'), coordinator_reset)

support = File.read(File.join(root, 'scripts/ProviderCardResetPreviewSupport.swift'))
File.write(File.join(output, 'ExtendedPreviewSupport.swift'), support)

stub = File.read(File.join(root, 'QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift'))
File.write(File.join(output, 'PreviewStubURLProtocol.swift'), stub)
RUBY

# Patch ExtendedPreviewSupport.swift so it exposes exact extracted coordinator properties & helpers without touching real Keychain/Engine
cat >> "$REGRESSION_DIR/ExtendedPreviewSupport.swift" <<'SWIFT'

extension ProviderRefreshCoordinator {
    private static var stateStorage: [ObjectIdentifier: CoordinatorFixtureState] = [:]
    final class AccountStoreStub {
        var accountRegistry: [StoredProviderAccount] = []
        func matchesStoredWithLive(_ stored: StoredProviderAccount, provider: ProviderData) -> Bool { false }
    }
    private final class CoordinatorFixtureState {
        var language = "en"
        var lastRefreshTime: Date?
        var providerRefreshTimes: [String: Date] = [:]
        var accountRefreshTimes: [String: Date] = [:]
        var accountLastCheckErrors: [String: AccountCheckError] = [:]
        var providers: [ProviderData] = []
        let accountStore = AccountStoreStub()
    }
    private var fixtureState: CoordinatorFixtureState {
        let key = ObjectIdentifier(self)
        if let existing = Self.stateStorage[key] { return existing }
        let created = CoordinatorFixtureState()
        Self.stateStorage[key] = created
        return created
    }

    var accountStore: AccountStoreStub { fixtureState.accountStore }
    var language: String {
        get { fixtureState.language }
        set { fixtureState.language = newValue }
    }
    var lastRefreshTime: Date? {
        get { fixtureState.lastRefreshTime }
        set { fixtureState.lastRefreshTime = newValue }
    }
    var providerRefreshTimes: [String: Date] {
        get { fixtureState.providerRefreshTimes }
        set { fixtureState.providerRefreshTimes = newValue }
    }
    var accountRefreshTimes: [String: Date] {
        get { fixtureState.accountRefreshTimes }
        set { fixtureState.accountRefreshTimes = newValue }
    }
    var accountLastCheckErrors: [String: AccountCheckError] {
        get { fixtureState.accountLastCheckErrors }
        set { fixtureState.accountLastCheckErrors = newValue }
    }
    var providers: [ProviderData] {
        get { fixtureState.providers }
        set { fixtureState.providers = newValue }
    }

    func liveProviderIdentity(_ provider: ProviderData) -> String { provider.id }
    func isLastKnownErrorPreservable(_ provider: ProviderData) -> Bool {
        provider.status != .error && (!provider.windows.isEmpty || provider.remainingPercent != nil || provider.fetchedAt != nil)
    }
    func isTerminalStopFailure(_ provider: ProviderData) -> Bool {
        provider.status == .error && ["tos_violation", "account_disabled", "unsupported_client", "not_logged_in"].contains(provider.errorCode ?? "")
    }
}
enum AccountIdentityPolicy {
    static func codexLiveAccountsMatch(_ lhs: ProviderData, _ rhs: ProviderData) -> Bool { lhs.id == rhs.id }
}
SWIFT

# Remove simplified UI preview stubs that are now supplied directly by ExtractedCoordinatorPipeline.swift
ruby -E UTF-8:UTF-8 - "$REGRESSION_DIR/ExtendedPreviewSupport.swift" <<'RUBY'
path = ARGV[0]
src = File.read(path)
src.sub!("    func accountRefreshDate(for provider: ProviderData) -> Date? { provider.fetchedAt.flatMap(SharedFormatters.parseISO8601) }\n", "")
src.sub!("    func lastCheckError(for provider: ProviderData) -> AccountCheckError? { nil }\n", "")
File.write(path, src)
RUBY

UI_OUT="${1:-$REGRESSION_DIR/ui-out}"
mkdir -p "$UI_OUT"

swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/AIUsage/Models/ProviderModels.swift" \
  "$ROOT/AIUsage/ViewModels/ProviderRefreshResult.swift" \
  "$ROOT/AIUsage/Views/AppSurfaceTokens.swift" \
  "$ROOT/AIUsage/Views/GatewayChrome.swift" \
  "$ROOT/AIUsage/Views/CodexResetCreditsView.swift" \
  "$REGRESSION_DIR/ExtendedPreviewSupport.swift" \
  "$REGRESSION_DIR/ExtractedCoordinatorPipeline.swift" \
  "$REGRESSION_DIR/PreviewResetCoordinator.swift" \
  "$REGRESSION_DIR/PreviewStubURLProtocol.swift" \
  "$REGRESSION_DIR/PreviewProviderCard.swift" \
  "$REGRESSION_DIR/PreviewAgentWidgets.swift" \
  "$REGRESSION_DIR/PreviewUtilities.swift" \
  "$ROOT/AIUsage/Views/ProviderIconView.swift" \
  "$ROOT/AIUsage/Views/ProviderCard+MultiWindowQuota.swift" \
  "$ROOT/AIUsage/Views/ProviderCard+QuotaIndicator.swift" \
  "$ROOT/AIUsage/Views/SmallProgressView.swift" \
  "$ROOT/AIUsage/Views/MenuBarAccountRow.swift" \
  "$ROOT/AIUsage/Views/MenuBarRows.swift" \
  "$ROOT/AIUsage/Views/MenuBarSupport.swift" \
  "$ROOT/AIUsage/Views/NodeBalanceView.swift" \
  "$REGRESSION_DIR/PreviewCodexSubscriptionSection.swift" \
  "$REGRESSION_DIR/PreviewProxyToggle.swift" \
  "$ROOT/scripts/PostR6UIFixtureRenderer.swift" \
  -o "$REGRESSION_DIR/post-r6-ui"

"$REGRESSION_DIR/post-r6-ui" "$UI_OUT"

# 3. [Review #3] Mid-flight Codex switch during exact extracted production syncUnifiedManagedAccounts
python3 - "$ROOT" "$REGRESSION_DIR" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])

def function(src, marker):
    s = src.index(marker); i = src.index('{', s); d = 1; j = i + 1
    while d:
        if src[j] == '{': d += 1
        elif src[j] == '}': d -= 1
        j += 1
    return src[s:j]

auth = (root / 'AIUsage/Services/ProviderAuthManager.swift').read_text()
discovery = (root / 'AIUsage/Services/ProviderAuth/ProviderAuthCandidateDiscovery.swift').read_text()
parsing = (root / 'AIUsage/Services/ProviderAuth/ProviderAuthParsing.swift').read_text()
pipe = (root / 'AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift').read_text()
store = (root / 'AIUsage/Services/ProviderAuth/ProviderManagedImportStore.swift').read_text()
store = store.replace('import Foundation\nimport QuotaBackend\n', '')
boundary_fn = function(store, '    private static func boundary(')
store = store.replace(boundary_fn, """    static var managedBase: URL!
    private static func boundary(create: Bool) throws -> ManagedAuthImportBoundary {
        ManagedAuthImportBoundary(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            applicationSupportDirectory: managedBase
        )
    }""")

sync_fn = function(pipe, '    @MainActor\n    func syncUnifiedManagedAccounts(')
sync_fn = sync_fn.replace('CodexQuotaPollingPolicy.activeNativeIdentity()', 'CodexQuotaPollingPolicy.activeNativeIdentity(homeDirectory: DiscoverySwitchFixture.home.path)')
sync_fn = sync_fn.replace('CodexQuotaPollingPolicy.verifiedNativeIdentity(atPath: candidate.credentialValue)', 'CodexQuotaPollingPolicy.verifiedNativeIdentity(atPath: candidate.credentialValue)')
codex_ok = '{"plan_type":"plus","rate_limit":{"allowed":true,"primary_window":{"used_percent":20,"limit_window_seconds":18000,"reset_after_seconds":3600}}}'

harness = f"""import Foundation
import Security
import Darwin
@testable import QuotaBackend
@testable import QuotaServerCore

enum DiscoverySwitchFixture {{ static var home: URL! }}

struct ProviderAuthCandidate {{
    enum IdentityScope: String {{ case sharedSource }}
    var id = "codex-candidate"
    var providerId = "codex"
    var title = "fixture@example.invalid"
    var authMethod: AuthMethod = .authFile
    var shouldCopyFile = true
    var sourcePath: String?
    var credentialValue: String
    var sourceIdentifier = "codex-cli:a"
    var sessionFingerprint: String? = "a"
    var identityScope = IdentityScope.sharedSource
    var workspaceId: String? = nil
    var capturesWorkspaceIdentity: Bool = false
}}

enum ProviderRegistry {{
    static var injected: any CredentialAcceptingProvider = CodexProvider()
    static var agyInjected: AntigravityProvider?
    static func provider(for id: String) -> Any? {{
        if id == "antigravity", let agyInjected {{ return agyInjected }}
        return injected
    }}
}}

{store}

enum GeminiCredentialBridge {{ static func makeNativePayload(from data: Data) throws -> Data {{ data }} }}

enum ProviderAuthManager {{
    static var injected: ProviderAuthCandidate!
    static var injectedByProvider: [String: [ProviderAuthCandidate]] = [:]
    static func unmanagedCandidates(for providerId: String) -> [ProviderAuthCandidate] {{
        injectedByProvider[providerId] ?? [injected]
    }}
    nonisolated(unsafe) static var onCopyAuthFile: (() -> Void)?
{function(auth, '    static func authenticateCandidate(')}
{function(discovery, '    static func normalizedAntigravityWorkspaceId(')}
    private static func stageDeferredAuthFileIfNeeded(
        for candidate: ProviderAuthCandidate
    ) throws -> (directoryURL: URL, fileURL: URL)? {{ nil }}
{function(auth, '    private static func validate(')}
{function(auth, '    private static func validateLocalAuthFileMetadata(')}
    private static func copyImportedAuthFile(
        providerId: String,
        sourcePath: String,
        suggestedName: String
    ) throws -> String {{
        onCopyAuthFile?()
        let sourceURL = URL(fileURLWithPath: sourcePath)
        let directory = try managedImportDirectory(for: providerId)
        let stem = sanitizedFilenameStem(suggestedName)
        let filename = "\\(stem)-\\(DateFormat.string(from: Date(), format: "yyyyMMdd-HHmmss"))-\\(UUID().uuidString).json"
        let destinationURL = directory.appendingPathComponent(filename)
        try Data(contentsOf: sourceURL).write(to: destinationURL, options: .atomic)
        return destinationURL.path
    }}
{function(auth, '    private static func managedImportDirectory(')}
{function(parsing, '    static func sanitizedFilenameStem(')}
}}

struct Settings {{ var backendMode = "local" }}

@MainActor final class ProviderRefreshCoordinator {{
    var settings = Settings()
    var discoveryFailureBackoff: [String: Date] = [:]
    var discoveryFailureCooldown: TimeInterval = 300
    var registered = 0
    var suppressCandidateHook: ((ProviderAuthCandidate, String) -> Bool)?
    func discoveryBackoffKey(for candidate: ProviderAuthCandidate) -> String {{ candidate.id }}
    func shouldSuppressAutoManagedCandidate(_ candidate: ProviderAuthCandidate, providerId: String) -> Bool {{
        suppressCandidateHook?(candidate, providerId) ?? false
    }}
    func shouldSuppressAutoManagedAccount(providerId: String, usage: ProviderUsage, credential: AccountCredential) -> Bool {{ false }}
    func registerAuthenticatedCredential(_ credential: AccountCredential, usage: ProviderUsage, note: String?, providerDisplayTitle: String) throws {{ registered += 1 }}
    func providerTitleForId(_ id: String) -> String {{ id }}
{sync_fn}
}}

extension String {{ var nilIfBlank: String? {{ isEmpty ? nil : self }} }}

func writeCodexAuthFixture(_ url: URL, account: String, user: String) throws {{
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let payload: [String: Any] = ["email": "fixture@example.invalid", "https://api.openai.com/auth": ["chatgpt_account_id": account, "chatgpt_user_id": user]]
    let jwt = "e30." + (try JSONSerialization.data(withJSONObject: payload)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".sig"
    let obj: [String: Any] = ["last_refresh": SharedFormatters.iso8601String(from: Date()), "tokens": ["account_id": account, "id_token": jwt, "access_token": "fixture-access", "refresh_token": "fixture-refresh"]]
    try JSONSerialization.data(withJSONObject: obj).write(to: url, options: .atomic)
}}

@main
struct DiscoverySwitchMidFlightRegression {{
    @MainActor static func main() async throws {{
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("post-r6-discovery-switch-" + UUID().uuidString)
        let managedBase = home.appendingPathComponent("AppSupport")
        try FileManager.default.createDirectory(at: managedBase, withIntermediateDirectories: true)
        ProviderManagedImportStore.managedBase = managedBase
        DiscoverySwitchFixture.home = home
        let managedRoot = try ProviderManagedImportStore.managedImportsRootDirectory()
        defer {{ try? FileManager.default.removeItem(at: home); StubURLProtocol.uninstall() }}

        let native = CodexQuotaPollingPolicy.nativeAuthFileURL(homeDirectory: home.path)
        let imported = home.appendingPathComponent("source-a.json")
        try writeCodexAuthFixture(native, account: "account-a", user: "user-a")
        try writeCodexAuthFixture(imported, account: "account-a", user: "user-a")
        ProviderRegistry.injected = CodexProvider(homeDirectory: home.path)
        ProviderAuthManager.injected = ProviderAuthCandidate(sourcePath: imported.path, credentialValue: imported.path)

        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage") {{ _ in
            (200, #"{codex_ok}"#)
        }}

        let codexDir = managedRoot.appendingPathComponent("codex")
        let coord = ProviderRefreshCoordinator()

        // [§6.3] Pre-auth suppression blocks tombstone/hidden candidate BEFORE copyImportedAuthFile or HTTP validation
        coord.suppressCandidateHook = {{ _, _ in true }}
        await coord.syncUnifiedManagedAccounts(for: ["codex"])
        let suppressedCopies = (try? FileManager.default.contentsOfDirectory(atPath: codexDir.path)) ?? []
        precondition(coord.registered == 0 && suppressedCopies.isEmpty && StubURLProtocol.requests.isEmpty,
                     "[§6.3] Suppressed candidate must create 0 auth copies and 0 network requests")

        // [Review #3 + §6.3] Mid-flight Codex native switch during 0-HTTP discovery drops stale account-a & cleans copy
        coord.suppressCandidateHook = nil
        coord.discoveryFailureBackoff.removeAll()
        ProviderAuthManager.onCopyAuthFile = {{
            try? writeCodexAuthFixture(native, account: "account-b", user: "user-b")
        }}
        await coord.syncUnifiedManagedAccounts(for: ["codex"])
        ProviderAuthManager.onCopyAuthFile = nil
        let remainingCopies = (try? FileManager.default.contentsOfDirectory(atPath: codexDir.path)) ?? []
        precondition(coord.registered == 0, "Stale A switched to B mid-flight must not be registered")
        precondition(remainingCopies.isEmpty, "Stale copied auth file created by mid-flight attempt must be cleaned up")
        precondition(StubURLProtocol.requests.isEmpty, "[§6.3] Codex discovery performs 0 outbound HTTP calls during registration")

        // Steady-state Codex discovery registers pending metadata with 0 HTTP requests
        try writeCodexAuthFixture(native, account: "account-a", user: "user-a")
        await coord.syncUnifiedManagedAccounts(for: ["codex"])
        precondition(coord.registered == 1 && StubURLProtocol.requests.isEmpty,
                     "[§6.3] Active Codex discovery registers local pending metadata with 0 outbound HTTP requests")

        // [§8-Evidence] Non-file auto-discovery (e.g. Copilot .token / Cursor .webSession) must ALSO perform 0 HTTP requests
        StubURLProtocol.install(hosts: ["api.github.com", "chatgpt.com", "auth.openai.com"])
        var copilotCandidate = ProviderAuthCandidate(sourcePath: nil, credentialValue: "gho-fixture-token")
        copilotCandidate.id = "copilot:gh"
        copilotCandidate.providerId = "copilot"
        copilotCandidate.authMethod = .token
        copilotCandidate.shouldCopyFile = false
        copilotCandidate.title = "octocat"
        copilotCandidate.sourceIdentifier = "github-cli:octocat"
        ProviderAuthManager.injectedByProvider["copilot"] = [copilotCandidate]
        let regBeforeNonFile = coord.registered
        await coord.syncUnifiedManagedAccounts(for: ["copilot"])
        precondition(coord.registered == regBeforeNonFile + 1 && StubURLProtocol.requests.isEmpty,
                     "[§8-Evidence] Non-file auto-discovery registers local pending metadata with 0 HTTP requests")
        print("PASS: [§6.3 + §8-Evidence] 0-HTTP Codex & non-file (Copilot) discovery + pre-auth suppression + mid-flight switch cleanup (requests=\\(StubURLProtocol.requests.count))")

        // [M2] Pre-validation local-metadata guard: 0 HTTP for Antigravity, Codex, and Gemini; suspended AGY still throws tos_violation
        let agyAbsent = AntigravityLocalQuotaReader(listProcesses: {{ [] }}, listPorts: {{ _ in [] }}, callRPC: {{ _, _, _, _ in nil }})
        ProviderRegistry.agyInjected = AntigravityProvider(homeDirectory: home.path, localQuotaReader: agyAbsent)
        let requestsBeforeM2 = StubURLProtocol.requests.count
        let agyFile = home.appendingPathComponent("m2-agy.json")
        try Data(#"{{"email":"m2-agy@example.invalid","project_id":"proj-m2","access_token":"tok","refresh_token":"ref"}}"#.utf8).write(to: agyFile)
        let agyCand = ProviderAuthCandidate(id: "m2-agy", providerId: "antigravity", title: "m2-agy@example.invalid", sourcePath: agyFile.path, credentialValue: agyFile.path)
        let (agyCred, agyUsage) = try await ProviderAuthManager.authenticateCandidate(agyCand, localOnly: true, allowLocalMetadataFallback: true)
        let agyPendingSummary = UsageNormalizer.normalize(provider: ProviderRegistry.agyInjected!, usage: agyUsage)
        precondition(agyUsage.accountEmail == "m2-agy@example.invalid"
                        && (agyUsage.extra["snapshotState"]?.value as? String) == "pending"
                        && agyUsage.fetchedAt.isEmpty
                        && agyPendingSummary.fetchedAt == nil
                        && agyPendingSummary.status == "idle"
                        && agyPendingSummary.statusLabel == "Waiting",
                     "[M2] AGY local metadata fallback returns idle/Waiting pending usage with empty/nil fetchedAt")
        let snapStore = QuotaSnapshotStore.store(homeDirectory: home.path)
        let pendingSaveResult = snapStore.save(
            result: ProviderResult(id: "antigravity:cred:\\(agyCred.id)", providerId: "antigravity", accountId: agyUsage.usageAccountId, ok: true, usage: agyUsage, summary: agyPendingSummary),
            credential: agyCred
        )
        precondition(!pendingSaveResult && snapStore.loadDocument().snapshots.isEmpty,
                     "[M2] QuotaSnapshotStore.save refuses snapshotState == pending stubs")

        let agySuspFile = home.appendingPathComponent("m2-agy-susp.json")
        let agySuspRaw = Data(#"{{"email":"susp@example.invalid","access_token":"tok","refresh_token":"ref"}}"#.utf8)
        try agySuspRaw.write(to: agySuspFile)
        try AntigravityAccountProtection.suspend(agySuspFile, error: ProviderError("tos_violation", "Disabled test"), expectedData: agySuspRaw)
        let agySuspCand = ProviderAuthCandidate(id: "m2-agy-s", providerId: "antigravity", title: "susp@example.invalid", sourcePath: agySuspFile.path, credentialValue: agySuspFile.path)
        var suspBlocked = false
        do {{ _ = try await ProviderAuthManager.authenticateCandidate(agySuspCand, localOnly: true, allowLocalMetadataFallback: true) }}
        catch let err as ProviderError where err.code == "tos_violation" {{ suspBlocked = true }}
        precondition(suspBlocked, "[M2] locally suspended AGY still fails closed under metadata fallback")

        let codexDormantCand = ProviderAuthCandidate(id: "m2-codex", providerId: "codex", title: "m2-codex@example.invalid", sourcePath: imported.path, credentialValue: imported.path)
        let (_, codexUsage) = try await ProviderAuthManager.authenticateCandidate(codexDormantCand, localOnly: true, allowLocalMetadataFallback: true)
        precondition(codexUsage.usageAccountId == "account-a" && (codexUsage.extra["snapshotState"]?.value as? String) == "pending", "[M2] Codex local metadata fallback parses workspace without network")

        let gemFile = home.appendingPathComponent("m2-gemini.json")
        try Data(#"{{"email":"m2-gem@example.invalid","access_token":"gtok","refresh_token":"gref"}}"#.utf8).write(to: gemFile)
        let gemCand = ProviderAuthCandidate(id: "m2-gem", providerId: "gemini", title: "m2-gem@example.invalid", sourcePath: gemFile.path, credentialValue: gemFile.path)
        let (_, gemUsage) = try await ProviderAuthManager.authenticateCandidate(gemCand, localOnly: true, allowLocalMetadataFallback: true)
        precondition(gemUsage.accountEmail == "m2-gem@example.invalid" && StubURLProtocol.requests.count == requestsBeforeM2, "[M2] Batch/Bridge local metadata validation makes 0 outbound HTTP calls")

        // [M5] Disposable TLS cert generation under umask 022: 0700 dir, 0600 keys/p12/pass, non-fixed passphrase, argv osascript
        let oldUmask = umask(0o022)
        defer {{ _ = umask(oldUmask) }}
        let tlsDir = home.appendingPathComponent("disposable-tls")
        let tlsMgr = TLSCertificateManager(tlsDirectory: tlsDir, allowSystemTrustInstall: false)
        try await tlsMgr.ensureCertificate()
        let dirMode = ((try FileManager.default.attributesOfItem(atPath: tlsDir.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
        precondition(dirMode == 0o700, "[M5] TLS dir created with 0700 under umask 022")
        for secret in ["ca-key.pem", "server-key.pem", "identity.p12", ".identity-pass"] {{
            let mode = ((try FileManager.default.attributesOfItem(atPath: tlsDir.appendingPathComponent(secret).path)[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
            precondition(mode == 0o600, "[M5] \\(secret) created with 0600 under umask 022")
        }}
        let generatedPass = try String(contentsOf: tlsDir.appendingPathComponent(".identity-pass"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!generatedPass.isEmpty && generatedPass != "aiusage-proxy-tls", "[M5] TLS passphrase is random and never hardcoded")
        let tlsServer = QuotaHTTPServer(host: "127.0.0.1", port: 0)
        _ = try tlsServer.loadTLSIdentity(from: tlsMgr.identityFilePath)
        let osaArgs = try TLSCertificateManager.makeAdminTrustOsascriptArguments(certURL: URL(fileURLWithPath: tlsMgr.certFilePath), expectedDirectory: tlsDir)
        precondition(osaArgs.suffix(2) == ["--", tlsMgr.certFilePath], "[M5] admin trust passes cert path via argv after -- without shell interpolation")
        print("PASS: [M2] local-metadata validation (0 HTTP) & [M5] disposable TLS 0700/0600 + random PKCS#12 + argv osascript")
    }}
}}
"""
(temp / 'DiscoverySwitchRegression.swift').write_text(harness)
PY

swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift" \
  "$ROOT/AIUsage/Services/TLSCertificateManager.swift" \
  "$REGRESSION_DIR/DiscoverySwitchRegression.swift" \
  -o "$REGRESSION_DIR/post-r6-discovery-switch"
"$REGRESSION_DIR/post-r6-discovery-switch"
fi

# 3b. [§6.3 + §6.4 + §6.6 + §6.7 + §6.8 + §9.1 + §9.2 + §9.3 + §9.5] Lean Cut & Anti-Ban Offline App-Layer Regressions (no sockets)
python3 - "$ROOT" "$REGRESSION_DIR" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])

def function(src, marker):
    s = src.index(marker); i = src.index('{', s); d = 1; j = i + 1
    while d:
        if src[j] == '{': d += 1
        elif src[j] == '}': d -= 1
        j += 1
    return src[s:j]

def block(src, marker):
    return function(src, marker)

settings_src = (root / 'AIUsage/Models/AppSettings.swift').read_text()
agent_vis_src = (root / 'AIUsage/Models/AgentVisibility.swift').read_text()
opencode_node_src = (root / 'AIUsage/ViewModels/OpenCodeNodeStore.swift').read_text()
app_src = (root / 'AIUsage/AIUsageApp.swift').read_text()
api_src = (root / 'AIUsage/Services/APIService.swift').read_text()
coord_src = (root / 'AIUsage/ViewModels/ProviderRefreshCoordinator.swift').read_text()
pipe_src = (root / 'AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift').read_text()
conv_src = (root / 'AIUsage/ViewModels/ProviderRefreshCoordinator+Conversion.swift').read_text()
parsing_src = (root / 'AIUsage/Services/ProviderAuth/ProviderAuthParsing.swift').read_text()
discovery_src = (root / 'AIUsage/Services/ProviderAuth/ProviderAuthCandidateDiscovery.swift').read_text()
auth_src = (root / 'AIUsage/Services/ProviderAuthManager.swift').read_text()
store_src = (root / 'AIUsage/Services/ProviderAuth/ProviderManagedImportStore.swift').read_text()
row_src = (root / 'AIUsage/Views/MenuBarAccountRow.swift').read_text()
menu_view_src = (root / 'AIUsage/Views/MenuBarView.swift').read_text()

# Verify AIUsageApp/MenuBarView contain §6.3 launch gate & §9.5 feedback presenter hooks.
assert 'OpenCodeNodeStore.hasPersistedManagedProxyRoute()' in app_src, 'Missing §6.3 launch gate in AIUsageApp.swift'
assert 'MenuBarActivationFeedback.bindPresenter' in menu_view_src, 'Missing §9.5 presenter bindPresenter in MenuBarView.swift'
assert 'MenuBarActivationFeedback.unbindPresenter' in menu_view_src, 'Missing §9.5 presenter unbindPresenter in MenuBarView.swift'
assert 'MenuBarActivationFeedback.unbindAll()' in app_src, 'Missing §9.5 unbindAll in AIUsageApp.swift popoverDidClose'

store_clean = store_src.replace('import Foundation\nimport QuotaBackend\n', '')
boundary_fn = function(store_clean, '    private static func boundary(')
store_clean = store_clean.replace(boundary_fn, """    static var managedBase: URL!
    private static func boundary(create: Bool) throws -> ManagedAuthImportBoundary {
        ManagedAuthImportBoundary(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            applicationSupportDirectory: managedBase
        )
    }""")

# Extract OpenCodeNodeStore §6.3 pieces
oc_store_file = function(opencode_node_src, '    private struct StoreFile: Codable')
oc_has_route = function(opencode_node_src, '    static func hasPersistedManagedProxyRoute(')
oc_restore = function(opencode_node_src, '    private func restoreProxyIfNeeded()')

# Extract Coordinator §6.4 / §6.8 pieces
coord_banner_start = coord_src.index('    @Published private var refreshError:')
coord_banner_end = coord_src.index('    @Published var lastRefreshTime:', coord_banner_start)
coord_banner_state = coord_src[coord_banner_start:coord_banner_end].rstrip()
coord_fetch_dashboard = function(coord_src, '    @MainActor\n    @discardableResult\n    func fetchDashboard(')
coord_fetch_single = function(coord_src, '    @MainActor\n    func fetchSingleProvider(')
coord_refresh_provider_now = function(coord_src, '    @MainActor\n    func refreshProviderNow(')
coord_refresh_acct_now = function(coord_src, '    @MainActor\n    func refreshAccountNow(')
coord_hydrate = function(coord_src, '    @MainActor\n    func hydrateFromDiskCacheIfNeeded()')
coord_visibility = function(coord_src, '    func handleSurfaceVisibilityOrWake(')
coord_clear_stale_banner = function(coord_src, '    func clearStaleOwnedRefreshErrorIfNeeded(')
coord_sync_overview = function(coord_src, '    func syncOverviewIfPresent()')
coord_remove_ids = function(coord_src, '    func removeProviders(matchingBaseProviderIds ')
coord_remove_id = function(coord_src, '    func removeProviders(matchingBaseProviderId ')
coord_reapply_visible = function(coord_src, '    func reapplyVisibleSortedProviders()')
pipe_fetch_cred = function(pipe_src, '    @MainActor\n    func fetchAccountByCredential(')
pipe_fetch_local = function(pipe_src, '    @MainActor\n    func fetchSingleProviderLocal(')
pipe_fetch_remote = function(pipe_src, '    @MainActor\n    func fetchSingleProviderRemote(')
pipe_local = function(pipe_src, '    @MainActor\n    func fetchDashboardLocal(')
pipe_remote = function(pipe_src, '    @MainActor\n    func fetchDashboardRemote(')
pipe_codex_id = function(pipe_src, '    func codexResetIdentity(')
pipe_accept_reset = function(pipe_src, '    func acceptsCodexResetRefresh(')
pipe_preserve_reset = function(pipe_src, '    func preserveCodexResetUpdates(')
pipe_sort = function(pipe_src, '    func providerSort(')
pipe_selected = function(pipe_src, '    func selectedProviderIDList(')
pipe_extract_credential = function(pipe_src, '    func extractCredentialId(')
pipe_replace_entries = function(pipe_src, '    func replaceProviderEntries(')
pipe_visible = function(pipe_src, '    func visibleProviders(')
pipe_hidden = function(pipe_src, '    func isProviderHidden(')
pipe_complete_global = function(pipe_src, '    func completeGlobalRefresh(')
pipe_complete_provider = function(pipe_src, '    func completeProviderRefresh(')
pipe_complete_acct = function(pipe_src, '    func completeAccountRefresh(')
conv_summary = function(conv_src, '    nonisolated func convertSummary(')
conv_convert_overview = function(conv_src, '    nonisolated func convertOverview(')
conv_loc_provider = function(conv_src, '    nonisolated func localizeProviderData(')
conv_loc_cost = function(conv_src, '    nonisolated func localizedCostPeriod(')
conv_loc_tl = function(conv_src, '    nonisolated func localizedTimelinePoint(')
conv_localize_overview = function(conv_src, '    nonisolated func localizeOverview(')
conv_loc_results = function(conv_src, '    nonisolated func localizedProviderResults(')
conv_loc_dash = function(conv_src, '    nonisolated func localizedDashboard(')
conv_loc_list = function(conv_src, '    nonisolated func localizedProviderList(')
conv_recomputed_overview = function(conv_src, '    nonisolated func recomputedOverview(')
api_fetch_dashboard = function(api_src, '    func fetchDashboard(')

# Extract Parsing §6.6 pieces
git_session_struct = function(parsing_src, 'struct GitHubCLISession')
gh_hosts_fn = function(parsing_src, '    static func githubCLIHostsPath(')
gh_session_fn = function(parsing_src, '    static func currentGitHubCLISession(')
token_fp_fn = function(parsing_src, '    static func tokenFingerprint(')
norm_handle_fn = function(parsing_src, '    static func normalizedHandle(')
expand_fn = function(parsing_src, '    static func expand(')
display_path_fn = function(parsing_src, '    static func displayPath(')

# Extract Staging §6.7 / §9.1 pieces
norm_agy_ws_fn = function(discovery_src, '    static func normalizedAntigravityWorkspaceId(')
agy_candidates_fn = function(discovery_src, '    internal static func antigravityCandidates(')
agy_stage_fn = function(discovery_src, '    static func stageAntigravityIDECandidate(')
auth_cand_fn = function(auth_src, '    static func authenticateCandidate(')
auth_stage_helper = function(auth_src, '    private static func stageDeferredAuthFileIfNeeded(').replace(
    'expectedWorkspaceId: expectedWorkspace\n        )',
    'expectedWorkspaceId: expectedWorkspace,\n            homeDirectory: homeOverride\n        )',
)
auth_copy_fn = function(auth_src, '    private static func copyImportedAuthFile(')
auth_dir_fn = function(auth_src, '    private static func managedImportDirectory(')
auth_validate_fn = function(auth_src, '    private static func validate(')
auth_validate_meta_fn = function(auth_src, '    private static func validateLocalAuthFileMetadata(')
sanitized_stem_fn = function(parsing_src, '    static func sanitizedFilenameStem(')

# Extract MenuBar §9.5 pieces
row_perform_activation = function(row_src, '    private func performActivation()').replace('private func performActivation()', 'func performActivation()', 1)
feedback_enum = function(row_src, '@MainActor\nenum MenuBarActivationFeedback')
agent_vis_body = agent_vis_src.replace('import Foundation\nimport QuotaBackend\n', '')

harness = f"""import AppKit
import Combine
import CryptoKit
import Darwin
import Foundation
import SwiftUI
@testable import QuotaBackend

enum APIError: Error {{ case invalidURL }}

extension JSONDecoder {{
    static let profileDecoder = JSONDecoder()
}}

func L(_ english: String, _ _: String, _ _: String? = nil) -> String {{ english }}

enum SensitiveDataRedactor {{
    static func redactedMessage(for error: Error) -> String {{ error.localizedDescription }}
}}

{function(settings_src, 'enum AppSection: String, Hashable')}

{agent_vis_body}

@MainActor final class AppSettings {{
    static let shared = AppSettings()
    var hiddenSidebarSections: Set<String> = []
    var backendMode = "remote"
    var remoteBaseURL = "http://127.0.0.1:4318"
    var proxyAutoRestoreOnLaunch = true
    var autoRefreshInterval = 60
    var claudeCodeRefreshInterval = 0
}}

// --- §6.3 OpenCodeNodeStore production launch gate + restoreProxyIfNeeded fixture ---
struct StubOpenCodeNode: Codable {{
    var id: String
    var proxyEnabled: Bool
}}
typealias OpenCodeNode = StubOpenCodeNode
enum StubManagementState {{ case managed, unmanaged }}
@MainActor final class StubOpenCodeConfigManager {{
    static var defaultManagementState: StubManagementState = .managed
    static var defaultIsManaged = true
    var managementState: StubManagementState = StubOpenCodeConfigManager.defaultManagementState
    var isManaged: Bool = StubOpenCodeConfigManager.defaultIsManaged
}}
@MainActor final class StubOpenCodeProxyRuntime {{
    var beginRestoringIDs: [[String]] = []
    var startedIDs: [String] = []
    var endRestoringIDs: [[String]] = []
    func beginRestoring(nodeIds: [String]) {{ beginRestoringIDs.append(nodeIds) }}
    func endRestoring(nodeIds: [String]) {{ endRestoringIDs.append(nodeIds) }}
    func start(node: OpenCodeNode) async throws {{ startedIDs.append(node.id) }}
}}
enum ProxyProcessInspector {{
    static let shared = Inspector()
    actor Inspector {{
        var reapCount = 0
        func reapOrphanedHelpers() async {{ reapCount += 1 }}
    }}
}}
@MainActor final class OpenCodeNodeStore {{
    static var sharedStorage: OpenCodeNodeStore?
    static var initCount = 0
    static var nextFixturePath = ""
    static var shared: OpenCodeNodeStore {{
        if let existing = sharedStorage {{ return existing }}
        let created = OpenCodeNodeStore(storePath: nextFixturePath)
        sharedStorage = created
        return created
    }}
    static var storePath: String {{ nextFixturePath }}
    static var shouldTriggerLaunchRestore: Bool {{
        AgentVisibility.isVisible(.opencode, hidden: AppSettings.shared.hiddenSidebarSections)
            || hasPersistedManagedProxyRoute()
    }}

    var nodes: [OpenCodeNode] = []
    var activeNodeIds: [String] = []
    var proxyOnlyNodeIds: Set<String> = []
    var deactivatedCalls: [[String]] = []
    let configManager = StubOpenCodeConfigManager()
    let proxyRuntime = StubOpenCodeProxyRuntime()
    var activeNodes: [OpenCodeNode] {{ activeNodeIds.compactMap {{ id in nodes.first {{ $0.id == id }} }} }}

{oc_store_file}
{oc_has_route}
{oc_restore.replace('openCodeStoreLog.error', '// log error').replace('Task { [proxyRuntime] in', 'Task { @MainActor [proxyRuntime] in')}

    init(storePath: String) {{
        Self.initCount += 1
        if let data = FileManager.default.contents(atPath: storePath),
           let file = try? JSONDecoder().decode(StoreFile.self, from: data) {{
            self.nodes = file.nodes
            self.activeNodeIds = file.activeNodeIds ?? (file.activeNodeId.map {{ [$0] }} ?? [])
            self.proxyOnlyNodeIds = Set(file.proxyOnlyNodeIds ?? [])
        }}
        restoreProxyIfNeeded()
    }}

    func deactivate(_ ids: [String]) throws {{
        deactivatedCalls.append(ids)
        activeNodeIds.removeAll {{ ids.contains($0) }}
    }}
}}

// --- §6.4 APIService URL builder + Coordinator remote/visibility fixture ---
struct StubDashboardResponse {{
    struct StubProviderWrapper {{
        let summary: ProviderData
        let ok: Bool
    }}
    let providers: [StubProviderWrapper]
    let overview: DashboardOverview
}}

@MainActor final class APIService {{
    static let shared = APIService()
    var baseURL = "http://127.0.0.1:4318"
    var recordedURLs: [URL] = []
    var recordedProviderResultCalls: [String] = []
    var onDashboardRequest: ((URL) async throws -> StubDashboardResponse)!
    var onProviderResultsRequest: ((String) async throws -> [StubDashboardResponse.StubProviderWrapper])?
    func updateBaseURL(_ url: String) {{ baseURL = url }}
    private func decode<T>(_ type: T.Type, from url: URL) async throws -> T {{
        recordedURLs.append(url)
        let response = try await onDashboardRequest(url)
        return response as! T
    }}
{api_fetch_dashboard.replace('DashboardResponse', 'StubDashboardResponse')}
    func fetchProviderResults(_ providerId: String) async throws -> [StubDashboardResponse.StubProviderWrapper] {{
        recordedProviderResultCalls.append(providerId)
        if let onProviderResultsRequest {{
            return try await onProviderResultsRequest(providerId)
        }}
        return try await fetchDashboard(providerIds: [providerId]).providers
    }}
}}

@MainActor final class CoordinatorUnderTest: ObservableObject {{
    let settings = AppSettings.shared
    var providers: [ProviderData] = []
    var overview: DashboardOverview?
    var didHydrateDiskSnapshots = false
    var isLoading = false
    var hasCompletedInitialLoad = false
{coord_banner_state}
    var language = "en"
    var lastRefreshTime: Date?
    var providerRefreshTimes: [String: Date] = [:]
    var accountRefreshTimes: [String: Date] = [:]
    var refreshingProviderIDs: Set<String> = []
    var refreshingAccountIDs: Set<String> = []
    var markedRefreshed: [(String, Date)] = []
    var recordedAccountErrors: [String] = []
    var errorNotifications: [String] = []
    var codexResetRefreshFence = CodexResetRefreshFence()
    var isPopoverVisible = false
    var lastSurfaceVisible = true
    var lastLocalStatsRefreshAt: Date?
    var lastVisibilityCatchUpAttemptAt: Date?
    static let wakeVisibilityDebounceSeconds: TimeInterval = 10
    var selected: Set<String> = []
    var catalog: [String] = ["claude", "claude-subscription", "codex", "antigravity"]
    var hiddenAccounts: Set<String> = []
    var deletedCredentialKeysThisSession: Set<String> = []
    final class AccountStoreStub {{
        var excludedCredentials: Set<String> = []
        func excludedEngineAccountFilters() -> (credentialIDs: Set<String>, codexNativeKeys: Set<String>) {{
            (excludedCredentials, [])
        }}
    }}
    let accountStore = AccountStoreStub()
    var setupAutoRefreshCalls = 0
    var setupClaudeCalls = 0
    var refreshAllCalls: [Bool] = []
    var localStatsCalls = 0
    var isAnyAppSurfaceVisible: Bool {{ isPopoverVisible }}

    func selectedProviderIds() -> Set<String> {{ selected }}
    func providerCatalogIds() -> [String] {{ catalog }}
    func setupAutoRefresh() {{ setupAutoRefreshCalls += 1 }}
    func setupClaudeCodeAutoRefresh() {{ setupClaudeCalls += 1 }}
    func refreshAllProviders(automatic: Bool) {{ refreshAllCalls.append(automatic) }}
    func refreshLocalTokenStatsOnly() {{ localStatsCalls += 1 }}
    func syncExcludedAccountsToEngine() async {{}}
    func syncUnifiedManagedAccounts(for _: [String]) async {{}}
    func reconcileResetProtectedAccountRegistry(_ _: [ProviderData], since _: Int) async {{}}
    func stabilizedBulkRefreshProviders(_ incoming: [ProviderData], preservingExistingFor _: String? = nil, includingExistingFor _: Set<String> = []) -> [ProviderData] {{ incoming }}
    func isProviderHidden(_ p: ProviderData) -> Bool {{ hiddenAccounts.contains(p.id) }}
{pipe_extract_credential}
    func credentialID(for row: ProviderData) -> String? {{ extractCredentialId(from: row.id) }}
    func sendErrorNotification(_ message: String) {{ errorNotifications.append(message) }}
    func timestampableProviders(for incoming: [ProviderData]) -> [ProviderData] {{
        providers.filter {{ cur in incoming.contains {{ $0.id == cur.id }} }}
    }}
    func resolvedFetchedDate(for provider: ProviderData) -> Date? {{ provider.fetchedAt.flatMap {{ SharedFormatters.parseISO8601($0) }} }}
    func resolvedTimestamp(for provider: ProviderData, fallback: Date?) -> Date? {{ resolvedFetchedDate(for: provider) ?? fallback }}
    func markAccountRefreshed(_ p: ProviderData, at date: Date) {{ markedRefreshed.append((p.id, date)) }}
    func accountRefreshKey(providerId: String, credentialId: String) -> String {{ "\\(providerId):cred:\\(credentialId.lowercased())" }}
    func isCredentialStillRegistered(providerId _: String, credentialId _: String) -> Bool {{ true }}
    func clearAccountCheckError(for _: ProviderData, credentialId _: String? = nil) {{}}
    func recordAccountCheckError(for _: ProviderData, credentialId _: String? = nil, message: String, errorCode _: String?) {{
        recordedAccountErrors.append(message)
    }}
    func isLastKnownErrorPreservable(_ p: ProviderData) -> Bool {{ p.status != .error && !p.windows.isEmpty }}
    func isTerminalStopFailure(_ p: ProviderData) -> Bool {{
        p.status == .error && ["tos_violation", "account_disabled", "unsupported_client", "not_logged_in"].contains(p.errorCode ?? "")
    }}
    func currentProviderMatchingRefresh(_ p: ProviderData) -> ProviderData? {{ providers.first {{ $0.id == p.id }} }}
    nonisolated func localizedDynamicText(_ text: String, _: String) -> String {{ text }}
{conv_summary}
{conv_convert_overview}
{conv_loc_provider}
{conv_loc_cost}
{conv_loc_tl}
{conv_localize_overview}
{conv_loc_results}
{conv_loc_dash}
{conv_loc_list}
{conv_recomputed_overview}
    nonisolated func localizedRemoteDashboard(_ items: [(provider: ProviderData, ok: Bool)], overview: DashboardOverview, language _: String) -> (providers: [(provider: ProviderData, ok: Bool)], overview: DashboardOverview) {{
        (items, overview)
    }}

    @MainActor final class EngineStub {{
        var credentialFetchCount = 0
        var onFetchForCredential: ((String, String) async -> ProviderResult?)?
        var onFetchMulti: ((String) async -> [ProviderResult]?)?
        var onFetchSingle: ((String) async -> ProviderResult?)?
        var onFetchAll: (([String]) async -> DashboardSnapshot)?
        var onCachedDashboard: (([String]) async -> DashboardSnapshot)?
        func fetchForCredential(providerId: String, credentialId: String) async -> ProviderResult? {{
            credentialFetchCount += 1
            return await onFetchForCredential?(providerId, credentialId)
        }}
        func fetchMultiAccountProvider(id: String) async -> [ProviderResult]? {{
            await onFetchMulti?(id)
        }}
        func fetchSingle(id: String) async -> ProviderResult? {{
            await onFetchSingle?(id)
        }}
        func fetchAll(ids: [String], useRecentResults _: Bool, backgroundAutomatic _: Bool) async -> DashboardSnapshot {{
            if let onFetchAll {{ return await onFetchAll(ids) }}
            return DashboardSnapshot(generatedAt: "", overview: UsageNormalizer.createDashboardOverview(summaries: [], generatedAt: ""), providers: [])
        }}
        func cachedDashboard(ids: [String], spawnBackgroundRefresh _: Bool) async -> DashboardSnapshot {{
            if let onCachedDashboard {{ return await onCachedDashboard(ids) }}
            return DashboardSnapshot(generatedAt: "", overview: UsageNormalizer.createDashboardOverview(summaries: [], generatedAt: ""), providers: [])
        }}
    }}
    let engine = EngineStub()

{coord_fetch_single}
{coord_fetch_dashboard}
{coord_refresh_provider_now}
{coord_refresh_acct_now}
{coord_hydrate}
{coord_visibility}
{coord_clear_stale_banner}
{coord_sync_overview}
{coord_remove_ids}
{coord_remove_id}
{coord_reapply_visible}
{pipe_fetch_cred}
{pipe_fetch_local}
{pipe_fetch_remote}
{pipe_local}
{pipe_remote}
{pipe_codex_id}
{pipe_accept_reset}
{pipe_preserve_reset}
{pipe_sort}
{pipe_selected}
{pipe_replace_entries}
{pipe_visible}
{pipe_complete_global}
{pipe_complete_provider}
{pipe_complete_acct}
}}

// --- §6.6 + §6.7 ProviderAuthManager extraction fixture ---
{git_session_struct}
private nonisolated let githubCLISessionCacheLock = NSLock()
private nonisolated(unsafe) var githubCLISessionCache: (key: String, fetchedAt: Date, session: GitHubCLISession?)?

struct ProviderAuthCandidate {{
    enum IdentityScope: String {{ case accountScoped, sharedSource }}
    let id: String
    let providerId: String
    let sourceIdentifier: String
    let sessionFingerprint: String?
    let title: String
    let subtitle: String?
    let detail: String
    let modifiedAt: Date?
    let authMethod: AuthMethod
    let credentialValue: String
    let sourcePath: String?
    let shouldCopyFile: Bool
    let identityScope: IdentityScope
    var workspaceId: String? = nil
    var capturesWorkspaceIdentity: Bool = false
}}

struct AntigravityIDECandidatePayload {{
    let email: String?
    let name: String?
    let accessToken: String
    let refreshToken: String?
    let databasePath: String
    let expiryDate: Date?
    let idToken: String?
    let projectId: String?
}}
enum AntigravityAccountSwitcher {{
    static var injectedPayload: AntigravityIDECandidatePayload?
    static func discoverIDECandidatePayload(homeDirectory _: String) -> AntigravityIDECandidatePayload? {{
        injectedPayload
    }}
}}
enum GeminiCredentialBridge {{
    static func makeNativePayload(from data: Data) throws -> Data {{ data }}
}}
enum DroidProvider {{
    static func managedSessionData(from _: String) -> Data? {{ nil }}
}}
enum ProviderRegistry {{
    static var agyProvider: AntigravityProvider!
    static func provider(for id: String) -> Any? {{ id == "antigravity" ? agyProvider : nil }}
}}
{store_clean}

enum ProviderAuthManager {{
    static var homeOverride: String = FileManager.default.homeDirectoryForCurrentUser.path
    static var onBeforeValidate: (@Sendable () async throws -> Void)?

{expand_fn}
{display_path_fn}
{norm_handle_fn}
{norm_agy_ws_fn}
{token_fp_fn}
{sanitized_stem_fn}
    static func modificationDate(for url: URL) -> Date? {{ try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }}
    static func formattedDate(_ _: Date?) -> String? {{ nil }}
    static func compactDetail(parts: [String?]) -> String {{ parts.compactMap {{ $0 }}.joined(separator: " · ") }}
    static func runCommand(path _: String, arguments _: [String], environment _: [String: String]? = nil) -> String? {{ nil }}
{gh_hosts_fn}
{gh_session_fn}
{agy_candidates_fn}
{agy_stage_fn}
{auth_cand_fn}
{auth_stage_helper}
{auth_copy_fn}
{auth_dir_fn}
{auth_validate_fn.replace('private static func validate(', 'private static func originalValidate(')}
    private static func validate(
        credential: AccountCredential,
        localOnly: Bool = false,
        allowLocalMetadataFallback: Bool = false
    ) async throws -> ProviderUsage {{
        if let onBeforeValidate {{ try await onBeforeValidate() }}
        return try await originalValidate(
            credential: credential,
            localOnly: localOnly,
            allowLocalMetadataFallback: allowLocalMetadataFallback
        )
    }}
{auth_validate_meta_fn}
}}

// --- §9.5 MenuBarAccountRow performActivation + MenuBarActivationFeedback fixture ---
{feedback_enum}

@MainActor final class StubRowActivationManager {{
    var activateHandler: (() async throws -> Bool)?
    func activateAccount(entry _: String) async throws -> Bool {{
        try await (activateHandler?() ?? true)
    }}
}}

@MainActor final class MenuBarRowBox {{
    var activationSuccess = true
    var activationMessage: String?
}}

@MainActor struct MenuBarRowHarness {{
    let activationManager: StubRowActivationManager
    let state = MenuBarRowBox()
    let entry = "codex"
    let primaryLabel = "nhntrong592@gmail.com"
    var activationSuccess: Bool {{
        get {{ state.activationSuccess }}
        nonmutating set {{ state.activationSuccess = newValue }}
    }}
    var activationMessage: String? {{
        get {{ state.activationMessage }}
        nonmutating set {{ state.activationMessage = newValue }}
    }}
{row_perform_activation}
}}

@main struct LeanCutAndAntibanP1P2Regression {{
    @MainActor static func main() async throws {{
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lean-cut-app-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {{ try? fm.removeItem(at: root) }}

        // 1. [§6.3 + §9.2] Persisted OpenCode managed proxy route recovery & cleanup even when hidden
        let ocPath = root.appendingPathComponent("opencode-nodes.json")
        func resetOC(path: String, autoRestore: Bool, managementState: StubManagementState = .managed, isManaged: Bool = true) {{
            OpenCodeNodeStore.sharedStorage = nil
            OpenCodeNodeStore.initCount = 0
            OpenCodeNodeStore.nextFixturePath = path
            StubOpenCodeConfigManager.defaultManagementState = managementState
            StubOpenCodeConfigManager.defaultIsManaged = isManaged
            AppSettings.shared.hiddenSidebarSections = [AppSection.opencodeManagement.rawValue]
            AppSettings.shared.proxyAutoRestoreOnLaunch = autoRestore
        }}
        let proxyStorePayload = #"{{"version":1,"nodes":[{{"id":"n-proxy","proxyEnabled":true}},{{"id":"n-direct","proxyEnabled":false}}],"activeNodeIds":["n-proxy"],"proxyOnlyNodeIds":["n-proxy"]}}"#
        try Data(proxyStorePayload.utf8).write(to: ocPath)
        resetOC(path: ocPath.path, autoRestore: true)
        precondition(OpenCodeNodeStore.shouldTriggerLaunchRestore, "[§6.3] hidden active proxy route still triggers launch store init")
        let ocStoreRestore = OpenCodeNodeStore.shared
        try await Task.sleep(for: .milliseconds(50))
        precondition(OpenCodeNodeStore.initCount == 1 && ocStoreRestore.proxyRuntime.startedIDs == ["n-proxy"],
                     "[§6.3] hidden active proxy route restores proxy listener at boot")

        // [§9.2] Truly unmanaged config (managementState = .unmanaged && isManaged = false) still restores proxy-only listeners while blocking active managed routes.
        let proxyOnlyPayload = #"{{"version":1,"nodes":[{{"id":"n-only","proxyEnabled":true}}],"activeNodeIds":[],"proxyOnlyNodeIds":["n-only"]}}"#
        try Data(proxyOnlyPayload.utf8).write(to: ocPath)
        resetOC(path: ocPath.path, autoRestore: true, managementState: .unmanaged, isManaged: false)
        precondition(OpenCodeNodeStore.shouldTriggerLaunchRestore, "[§9.2] hidden proxy-only route triggers launch init on unmanaged config")
        let ocOnlyStore = OpenCodeNodeStore.shared
        try await Task.sleep(for: .milliseconds(50))
        precondition(ocOnlyStore.proxyRuntime.startedIDs == ["n-only"],
                     "[§9.2] proxy-only OpenCode node restores at boot even when config is truly unmanaged (isManaged=false)")

        let activeOnlyPayload = #"{{"version":1,"nodes":[{{"id":"n-active","proxyEnabled":true}}],"activeNodeIds":["n-active"],"proxyOnlyNodeIds":[]}}"#
        try Data(activeOnlyPayload.utf8).write(to: ocPath)
        resetOC(path: ocPath.path, autoRestore: true, managementState: .unmanaged, isManaged: false)
        let ocBlockedActiveStore = OpenCodeNodeStore.shared
        try await Task.sleep(for: .milliseconds(50))
        precondition(ocBlockedActiveStore.proxyRuntime.startedIDs.isEmpty,
                     "[§9.2] unmanaged config (isManaged=false) still refuses to restore active managed route")

        try Data(proxyStorePayload.utf8).write(to: ocPath)
        resetOC(path: ocPath.path, autoRestore: false)
        let ocDisabledStore = OpenCodeNodeStore.shared
        try await Task.sleep(for: .milliseconds(20))
        precondition(ocDisabledStore.deactivatedCalls == [["n-proxy"]] && ocDisabledStore.proxyRuntime.startedIDs.isEmpty,
                     "[§6.3] auto-restore disabled cleanly deactivates lingering managed proxy route")

        let directOnlyPayload = #"{{"version":1,"nodes":[{{"id":"n-direct","proxyEnabled":false}}],"activeNodeIds":["n-direct"],"proxyOnlyNodeIds":[]}}"#
        try Data(directOnlyPayload.utf8).write(to: ocPath)
        resetOC(path: ocPath.path, autoRestore: true)
        precondition(!OpenCodeNodeStore.shouldTriggerLaunchRestore && OpenCodeNodeStore.initCount == 0,
                     "[§6.3] hidden direct-only OpenCode setup skips launch singleton init")
        print("PASS: [§6.3] OpenCode persisted proxy boot restore & disabled cleanup verified")

        // 2. [§6.4] Remote refresh never turns "no visible providers" into unfiltered "all providers"
        AppSettings.shared.backendMode = "remote"
        let emptyAppOverview = DashboardOverview(
            generatedAt: "",
            activeProviders: 0,
            attentionProviders: 0,
            criticalProviders: 0,
            resetSoonProviders: 0,
            localCostMonthUsd: 0,
            localWeekTokens: 0,
            stats: [],
            alerts: []
        )
        APIService.shared.recordedURLs.removeAll()
        APIService.shared.onDashboardRequest = {{ _ in
            StubDashboardResponse(providers: [], overview: emptyAppOverview)
        }}
        _ = try await APIService.shared.fetchDashboard()
        precondition(APIService.shared.recordedURLs.last?.query == nil, "[§6.4] Settings Remote deliberate fetchDashboard() stays unfiltered")

        APIService.shared.recordedURLs.removeAll()
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let remoteCoord = CoordinatorUnderTest()
        remoteCoord.selected = ["claude"]
        let emptyHiddenRes = await remoteCoord.fetchDashboard()
        let directSingleHidden = await remoteCoord.fetchSingleProvider("claude")
        precondition(emptyHiddenRes.status == .success
                        && remoteCoord.providers.isEmpty
                        && APIService.shared.recordedURLs.isEmpty
                        && directSingleHidden.status == .failure
                        && APIService.shared.recordedProviderResultCalls.isEmpty,
                     "[§6.4] selecting only hidden provider sends 0 HTTP requests and returns empty dashboard")

        // Mid-flight hide during refresh_pending must stop polling instead of sending unfiltered ids=nil
        AppSettings.shared.hiddenSidebarSections = []
        remoteCoord.selected = ["codex"]
        var pendingPollCalls = 0
        APIService.shared.onDashboardRequest = {{ _ in
            pendingPollCalls += 1
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            let pending = ProviderData(
                id: "codex:1",
                providerId: "codex",
                accountId: nil,
                name: "Codex",
                label: "Codex",
                description: "",
                category: "quota",
                channel: nil,
                status: .healthy,
                statusLabel: "OK",
                theme: ProviderTheme(accent: "#000", glow: "#000"),
                sourceLabel: "",
                sourceType: "oauth",
                fetchedAt: nil,
                accountLabel: nil,
                membershipLabel: nil,
                headline: Headline(eyebrow: "", primary: "", secondary: "", supporting: nil),
                metrics: [],
                windows: [],
                remainingPercent: 80,
                nextResetAt: nil,
                nextResetLabel: nil,
                spotlight: nil,
                models: nil,
                costSummary: nil,
                errorCode: "refresh_pending"
            )
            return StubDashboardResponse(providers: [.init(summary: pending, ok: true)], overview: emptyAppOverview)
        }}
        let abortedMidFlight = await remoteCoord.fetchDashboardRemote(showMessageOnFailure: false)
        precondition(abortedMidFlight.status == .success
                        && pendingPollCalls == 1
                        && APIService.shared.recordedURLs.count == 1
                        && APIService.shared.recordedURLs[0].query == "ids=codex"
                        && remoteCoord.providers.isEmpty,
                     "[§6.4] hiding last visible provider during refresh_pending aborts follow-up without unfiltered HTTP call")

        // [§9.3] Late settled remote response arriving after hide must also clear/recompute overview and Inbox alerts
        func makeRemoteProvider(id: String, providerId: String, label: String, status: ProviderStatus, errorCode: String? = nil, windows: [QuotaWindow] = []) -> ProviderData {{
            ProviderData(
                id: id,
                providerId: providerId,
                accountId: nil,
                name: label,
                label: label,
                description: "",
                category: "quota",
                channel: nil,
                status: status,
                statusLabel: status == .critical ? "Critical" : "OK",
                theme: ProviderTheme(accent: "#000", glow: "#000"),
                sourceLabel: "",
                sourceType: "oauth",
                fetchedAt: nil,
                accountLabel: nil,
                membershipLabel: nil,
                headline: Headline(eyebrow: "", primary: "", secondary: status == .critical ? "0% left" : "90% left", supporting: nil),
                metrics: [],
                windows: windows,
                remainingPercent: status == .critical ? 0 : 90,
                nextResetAt: nil,
                nextResetLabel: nil,
                spotlight: nil,
                models: nil,
                costSummary: nil,
                errorCode: errorCode
            )
        }}
        let settledCodex = makeRemoteProvider(id: "codex:1", providerId: "codex", label: "Codex", status: .critical)
        let settledAGY = makeRemoteProvider(id: "antigravity:1", providerId: "antigravity", label: "Antigravity", status: .healthy)
        let staleCodexAlertOverview = DashboardOverview(
            generatedAt: "2026-11-22T00:00:00Z",
            activeProviders: 1,
            attentionProviders: 1,
            criticalProviders: 1,
            resetSoonProviders: 0,
            localCostMonthUsd: 0,
            localWeekTokens: 0,
            stats: [OverviewStat(label: "Connected Sources", value: "1", note: "1 providers in the mesh")],
            alerts: [Alert(id: "codex:1:status-critical", tone: "critical", providerId: "codex:1", title: "Codex needs attention", body: "0% left")]
        )
        AppSettings.shared.hiddenSidebarSections = []
        remoteCoord.selected = ["codex"]
        APIService.shared.onDashboardRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            return StubDashboardResponse(providers: [.init(summary: settledCodex, ok: true)], overview: staleCodexAlertOverview)
        }}
        _ = await remoteCoord.fetchDashboardRemote(showMessageOnFailure: false)
        precondition(remoteCoord.providers.isEmpty
                        && remoteCoord.overview?.activeProviders == 0
                        && remoteCoord.overview?.criticalProviders == 0
                        && remoteCoord.overview?.alerts.isEmpty == true,
                     "[§9.3] hiding sole visible provider during settled remote response clears overview and Inbox alerts")

        AppSettings.shared.hiddenSidebarSections = []
        remoteCoord.selected = ["codex", "antigravity"]
        APIService.shared.onDashboardRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            return StubDashboardResponse(
                providers: [.init(summary: settledCodex, ok: true), .init(summary: settledAGY, ok: true)],
                overview: staleCodexAlertOverview
            )
        }}
        _ = await remoteCoord.fetchDashboardRemote(showMessageOnFailure: false)
        precondition(remoteCoord.providers.map(\\.baseProviderId) == ["antigravity"]
                        && remoteCoord.overview?.activeProviders == 1
                        && remoteCoord.overview?.criticalProviders == 0
                        && remoteCoord.overview?.alerts.isEmpty == true,
                     "[§9.3] hiding one of multiple visible providers during settled remote response recomputes overview and strips hidden alert")
        AppSettings.shared.hiddenSidebarSections = []
        print("PASS: [§6.4 + §9.3] Remote dashboard empty selection, mid-flight hide & late settled overview filtering verified")

        // 3. [§6.6] Copilot GitHub CLI supports GH_CONFIG_DIR and XDG_CONFIG_HOME
        let ghHome = root.appendingPathComponent("gh-home")
        try fm.createDirectory(at: ghHome, withIntermediateDirectories: true)
        let customGHDir = root.appendingPathComponent("custom-gh-dir")
        try fm.createDirectory(at: customGHDir, withIntermediateDirectories: true)
        try Data("github.com:\\n  user: octo-gh-dir\\n".utf8).write(to: customGHDir.appendingPathComponent("hosts.yml"))
        var ghStubCalls = 0
        let ghDirSession1 = ProviderAuthManager.currentGitHubCLISession(
            environment: ["GH_CONFIG_DIR": customGHDir.path],
            homeDirectory: ghHome.path,
            commandRunner: {{ _, _ in ghStubCalls += 1; return "gho_custom_dir" }}
        )
        let ghDirSession2 = ProviderAuthManager.currentGitHubCLISession(
            environment: ["GH_CONFIG_DIR": customGHDir.path],
            homeDirectory: ghHome.path,
            commandRunner: {{ _, _ in ghStubCalls += 1; return "gho_custom_dir" }}
        )
        let xdgDir = root.appendingPathComponent("xdg-cfg")
        try fm.createDirectory(at: xdgDir.appendingPathComponent("gh"), withIntermediateDirectories: true)
        try Data("github.com:\\n  user: octo-xdg\\n".utf8).write(to: xdgDir.appendingPathComponent("gh/hosts.yml"))
        let xdgSession = ProviderAuthManager.currentGitHubCLISession(
            environment: ["XDG_CONFIG_HOME": xdgDir.path],
            homeDirectory: ghHome.path,
            commandRunner: {{ _, _ in ghStubCalls += 1; return "gho_xdg" }}
        )
        let missingSession = ProviderAuthManager.currentGitHubCLISession(
            environment: [:],
            homeDirectory: ghHome.path,
            commandRunner: {{ _, _ in ghStubCalls += 1; return "should-not-run" }}
        )
        precondition(ghDirSession1?.label == "octo-gh-dir"
                        && ghDirSession1?.token == "gho_custom_dir"
                        && ghDirSession2?.label == "octo-gh-dir"
                        && xdgSession?.label == "octo-xdg"
                        && missingSession == nil
                        && ghStubCalls == 2,
                     "[§6.6] GH_CONFIG_DIR and XDG_CONFIG_HOME resolve custom hosts.yml & cache separately")
        print("PASS: [§6.6] GitHub CLI GH_CONFIG_DIR & XDG_CONFIG_HOME resolution verified")

        // 4. [§6.7] On-demand scoped 0700/0600 Antigravity staging & immediate/delete cleanup
        let oldUmask = umask(0o022)
        defer {{ _ = umask(oldUmask) }}
        let agyHome = root.appendingPathComponent("agy-home")
        let agyManagedBase = agyHome.appendingPathComponent("Library/Application Support", isDirectory: true)
        try fm.createDirectory(at: agyManagedBase, withIntermediateDirectories: true)
        ProviderManagedImportStore.managedBase = agyManagedBase
        ProviderAuthManager.homeOverride = agyHome.path
        let ideDB = agyHome.appendingPathComponent("state.vscdb")
        try Data("sqlite-ide-db".utf8).write(to: ideDB)
        AntigravityAccountSwitcher.injectedPayload = AntigravityIDECandidatePayload(
            email: "agy-stage@example.invalid",
            name: "Agy Stage",
            accessToken: "ya29.secret",
            refreshToken: "1//refresh-secret",
            databasePath: ideDB.path,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: "id-secret",
            projectId: "proj-secret"
        )
        let stagingRoot = try ProviderManagedImportStore.stagingRootDirectory()
        let importsRoot = try ProviderManagedImportStore.managedImportsRootDirectory()
        func allFiles(under dir: URL) -> [URL] {{
            guard fm.fileExists(atPath: dir.path),
                  let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else {{ return [] }}
            return (e.allObjects as? [URL] ?? []).filter {{
                (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }}
        }}

        // (a) Candidate listing + cancel writes 0 credential files
        let candidates = ProviderAuthManager.antigravityCandidates(homeDirectory: agyHome.path)
        precondition(candidates.count == 1
                        && candidates[0].sourcePath == nil
                        && candidates[0].credentialValue.isEmpty
                        && allFiles(under: stagingRoot).isEmpty
                        && allFiles(under: importsRoot).isEmpty,
                     "[§6.7] Antigravity candidate discovery writes 0 token files when cancelled")

        // (b) Permission failure cleans stage directory
        var permFailed = false
        do {{
            _ = try ProviderAuthManager.stageAntigravityIDECandidate(
                expectedSourceIdentifier: candidates[0].sourceIdentifier,
                expectedWorkspaceId: candidates[0].workspaceId,
                homeDirectory: agyHome.path,
                stagingRootOverride: stagingRoot,
                permissionSetter: {{ path, mode in
                    if mode == 0o600 {{ throw CocoaError(.fileWriteNoPermission) }}
                }}
            )
        }} catch {{ permFailed = true }}
        precondition(permFailed && allFiles(under: stagingRoot).isEmpty, "[§6.7] permission error leaves 0 staging files")

        // (c) Direct stage verifies 0700 dir & 0600 file modes under umask 022
        let stagedProbe = try ProviderAuthManager.stageAntigravityIDECandidate(
            expectedSourceIdentifier: candidates[0].sourceIdentifier,
            expectedWorkspaceId: candidates[0].workspaceId,
            homeDirectory: agyHome.path,
            stagingRootOverride: stagingRoot
        )
        let sRootMode = ((try fm.attributesOfItem(atPath: stagingRoot.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let sDirMode = ((try fm.attributesOfItem(atPath: stagedProbe.directoryURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        let sFileMode = ((try fm.attributesOfItem(atPath: stagedProbe.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        precondition(sRootMode == 0o700 && sDirMode == 0o700 && sFileMode == 0o600, "[§6.7] staging root/dir=0700 and file=0600")
        try fm.removeItem(at: stagedProbe.directoryURL)

        // (d) Validation failure cleans both staging and AuthImports
        let absentReader = AntigravityLocalQuotaReader(listProcesses: {{ [] }}, listPorts: {{ _ in [] }}, callRPC: {{ _, _, _, _ in nil }})
        ProviderRegistry.agyProvider = AntigravityProvider(homeDirectory: agyHome.path, localQuotaReader: absentReader)
        var failCaught = false
        do {{ _ = try await ProviderAuthManager.authenticateCandidate(candidates[0], localOnly: true) }}
        catch {{ failCaught = true }}
        precondition(failCaught && allFiles(under: stagingRoot).isEmpty && allFiles(under: importsRoot).isEmpty,
                     "[§6.7] failed import leaves 0 staging and 0 AuthImports files")

        // (e) Cancelled import task leaves 0 staging and 0 AuthImports files
        let validReader = AntigravityLocalQuotaReader(
            listProcesses: {{ [.init(pid: 88, csrfToken: "tok", preferredPorts: [19088])] }},
            listPorts: {{ _ in [] }},
            callRPC: {{ _, method, _, _ in
                if method.hasSuffix("GetUserStatus") {{
                    return ["userStatus": ["email": "agy-stage@example.invalid", "cloudaicompanionProject": "proj-secret"]]
                }}
                return ["groups": [["displayName": "Gemini", "buckets": [["bucketId": "g-5h", "remainingFraction": 0.9, "resetTime": "2027-01-01T00:00:00Z"]]]]]
            }}
        )
        ProviderRegistry.agyProvider = AntigravityProvider(homeDirectory: agyHome.path, localQuotaReader: validReader)
        let cancelTask = Task {{
            ProviderAuthManager.onBeforeValidate = {{
                await Task.yield()
                throw CancellationError()
            }}
            return try await ProviderAuthManager.authenticateCandidate(candidates[0], localOnly: true)
        }}
        var cancelled = false
        do {{ _ = try await cancelTask.value }} catch {{ cancelled = true }}
        ProviderAuthManager.onBeforeValidate = nil
        precondition(cancelled && allFiles(under: stagingRoot).isEmpty && allFiles(under: importsRoot).isEmpty,
                     "[§6.7] cancelled import leaves 0 staging and 0 AuthImports files")

        // (f) Successful import removes stage immediately, clears sourcePath, and account deletion leaves 0 files without touching IDE DB
        let (cred, _) = try await ProviderAuthManager.authenticateCandidate(candidates[0], localOnly: true)
        let authFilesAfterImport = allFiles(under: importsRoot)
        let importedMode = ((try fm.attributesOfItem(atPath: cred.credential)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
        precondition(allFiles(under: stagingRoot).isEmpty
                        && authFilesAfterImport.count == 1
                        && importedMode == 0o600
                        && (cred.metadata["sourcePath"] ?? "") == ""
                        && fm.fileExists(atPath: ideDB.path),
                     "[§6.7] successful import removes staging immediately & stores 0600 managed copy")
        ProviderManagedImportStore.cleanupManagedImports(forDeletedCredentials: [cred], referencedBy: [])
        precondition(allFiles(under: stagingRoot).isEmpty
                        && allFiles(under: importsRoot).isEmpty
                        && fm.fileExists(atPath: ideDB.path),
                     "[§6.7] deleting account cleans all managed copies and leaves 0 files & intact IDE DB")

        // [§9.1] Same-email / different-workspace deferred Antigravity import rejection + same-workspace token rotation allowance
        ProviderRegistry.agyProvider = AntigravityProvider(homeDirectory: agyHome.path, localQuotaReader: absentReader)
        AntigravityAccountSwitcher.injectedPayload = AntigravityIDECandidatePayload(
            email: "agy-stage@example.invalid",
            name: "Agy Stage",
            accessToken: "ya29.secret",
            refreshToken: "1//refresh-secret",
            databasePath: ideDB.path,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: "id-secret",
            projectId: "proj-secret"
        )
        let candidatesA = ProviderAuthManager.antigravityCandidates(homeDirectory: agyHome.path)
        precondition(candidatesA.count == 1 && candidatesA[0].workspaceId == "proj-secret",
                     "[§9.1] listed candidate captures non-secret workspace identity")
        // IDE switches to project-b under the exact same email before user clicks Connect
        AntigravityAccountSwitcher.injectedPayload = AntigravityIDECandidatePayload(
            email: "agy-stage@example.invalid",
            name: "Agy Stage",
            accessToken: "ya29.secret-b",
            refreshToken: "1//refresh-b",
            databasePath: ideDB.path,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: "id-b",
            projectId: "project-b"
        )
        var driftErrorCode: String?
        do {{
            _ = try await ProviderAuthManager.authenticateCandidate(
                candidatesA[0],
                localOnly: true,
                allowLocalMetadataFallback: true
            )
        }} catch let error as ProviderError {{
            driftErrorCode = error.code
        }}
        let refreshedCandidatesB = ProviderAuthManager.antigravityCandidates(homeDirectory: agyHome.path)
        precondition(driftErrorCode == "candidate_changed"
                        && allFiles(under: stagingRoot).isEmpty
                        && allFiles(under: importsRoot).isEmpty
                        && refreshedCandidatesB.count == 1
                        && refreshedCandidatesB[0].workspaceId == "project-b"
                        && refreshedCandidatesB[0].id != candidatesA[0].id,
                     "[§9.1] same-email workspace change A->B rejects with 0 staged/managed files and refreshes to distinct candidate id")

        // Unverifiable project (nil) must also reject
        AntigravityAccountSwitcher.injectedPayload = AntigravityIDECandidatePayload(
            email: "agy-stage@example.invalid",
            name: "Agy Stage",
            accessToken: "ya29.secret-nil",
            refreshToken: "1//refresh-nil",
            databasePath: ideDB.path,
            expiryDate: Date().addingTimeInterval(3600),
            idToken: "id-nil",
            projectId: nil
        )
        var unverifiedCode: String?
        do {{
            _ = try await ProviderAuthManager.authenticateCandidate(
                candidatesA[0],
                localOnly: true,
                allowLocalMetadataFallback: true
            )
        }} catch let error as ProviderError {{
            unverifiedCode = error.code
        }}
        precondition(unverifiedCode == "candidate_changed"
                        && allFiles(under: stagingRoot).isEmpty
                        && allFiles(under: importsRoot).isEmpty,
                     "[§9.1] missing workspace identity on re-read fails closed with 0 files")

        // Same verified workspace with rotated tokens is accepted cleanly
        AntigravityAccountSwitcher.injectedPayload = AntigravityIDECandidatePayload(
            email: "agy-stage@example.invalid",
            name: "Agy Stage",
            accessToken: "ya29.rotated-a",
            refreshToken: "1//rotated-a",
            databasePath: ideDB.path,
            expiryDate: Date().addingTimeInterval(7200),
            idToken: "id-rotated-a",
            projectId: "proj-secret"
        )
        let (rotatedCred, rotatedUsage) = try await ProviderAuthManager.authenticateCandidate(
            candidatesA[0],
            localOnly: true,
            allowLocalMetadataFallback: true
        )
        precondition(rotatedCred.metadata["projectId"] == "proj-secret"
                        && (rotatedUsage.extra["projectId"]?.value as? String) == "proj-secret"
                        && allFiles(under: stagingRoot).isEmpty,
                     "[§9.1] token rotation within verified workspace succeeds cleanly")
        ProviderManagedImportStore.cleanupManagedImports(forDeletedCredentials: [rotatedCred], referencedBy: [])
        print("PASS: [§6.7 + §9.1] Antigravity staging, same-email/different-workspace rejection & rotation verified")

        // 5. [§6.8] Visibility catch-up debounced by attempt time even when lastRefreshTime stays stale
        let debCoord = CoordinatorUnderTest()
        debCoord.settings.autoRefreshInterval = 60
        debCoord.settings.claudeCodeRefreshInterval = 0
        debCoord.lastRefreshTime = Date(timeIntervalSince1970: 100) // stale! cache-only refreshes do not advance it
        debCoord.isPopoverVisible = true
        debCoord.lastSurfaceVisible = false
        debCoord.handleSurfaceVisibilityOrWake(isWake: false, now: Date(timeIntervalSince1970: 1000))
        debCoord.lastSurfaceVisible = false
        debCoord.handleSurfaceVisibilityOrWake(isWake: false, now: Date(timeIntervalSince1970: 1002))
        debCoord.lastSurfaceVisible = false
        debCoord.handleSurfaceVisibilityOrWake(isWake: true, now: Date(timeIntervalSince1970: 1005))
        precondition(debCoord.refreshAllCalls.count == 1 && debCoord.lastRefreshTime == Date(timeIntervalSince1970: 100),
                     "[§6.8] 3 rapid reopen/wake events within 10s trigger only 1 refresh even with stale lastRefreshTime")
        debCoord.lastSurfaceVisible = false
        debCoord.handleSurfaceVisibilityOrWake(isWake: false, now: Date(timeIntervalSince1970: 1011))
        precondition(debCoord.refreshAllCalls.count == 2,
                     "[§6.8] transition after >=10s dispatches next visibility catch-up")
        print("PASS: [§6.8] Visibility catch-up 10s attempt debounce verified")

        // 6. [§9.5] Reopened menu bar popover still receives async switch failure & stay-closed shows modal
        var fakePopoverVisible = true
        var shownModals: [String] = []
        MenuBarActivationFeedback.popoverVisibilityProvider = {{ fakePopoverVisible }}
        MenuBarActivationFeedback.modalWarningPresenter = {{ shownModals.append($0) }}

        // (a) Reopen before async failure: host 1 closes, host 2 opens and binds presenter -> failure lands on host 2, 0 modals
        var host1Toast: (String, Bool)?
        var host2Toast: (String, Bool)?
        var pendingFailure: CheckedContinuation<Bool, Error>?
        let rowMgr1 = StubRowActivationManager()
        rowMgr1.activateHandler = {{
            try await withCheckedThrowingContinuation {{ pendingFailure = $0 }}
        }}
        let row1 = MenuBarRowHarness(activationManager: rowMgr1)
        _ = MenuBarActivationFeedback.bindPresenter {{ msg, ok in host1Toast = (msg, ok) }}
        row1.performActivation()
        try await Task.sleep(for: .milliseconds(20))
        precondition(pendingFailure != nil, "[§9.5] activation task started")
        MenuBarActivationFeedback.unbindAll()
        _ = MenuBarActivationFeedback.bindPresenter {{ msg, ok in host2Toast = (msg, ok) }}
        fakePopoverVisible = true
        pendingFailure?.resume(throwing: NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Quit timed out"]))
        try await Task.sleep(for: .milliseconds(30))
        precondition(host1Toast == nil
                        && row1.activationMessage == nil
                        && host2Toast?.0 == "Quit timed out"
                        && host2Toast?.1 == false
                        && shownModals.isEmpty,
                     "[§9.5] reopened popover host receives async failure cleanly without modal")

        // (b) Stay closed until failure: presenter unbound & popover invisible -> 0 toasts, 1 modal
        host2Toast = nil
        shownModals.removeAll()
        var stayedClosedCont: CheckedContinuation<Bool, Error>?
        let rowMgr2 = StubRowActivationManager()
        rowMgr2.activateHandler = {{
            try await withCheckedThrowingContinuation {{ stayedClosedCont = $0 }}
        }}
        let row2 = MenuBarRowHarness(activationManager: rowMgr2)
        _ = MenuBarActivationFeedback.bindPresenter {{ msg, ok in host2Toast = (msg, ok) }}
        row2.performActivation()
        try await Task.sleep(for: .milliseconds(20))
        fakePopoverVisible = false
        MenuBarActivationFeedback.unbindAll()
        stayedClosedCont?.resume(throwing: NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Helper exited slow"]))
        try await Task.sleep(for: .milliseconds(30))
        precondition(host2Toast == nil && row2.activationMessage == nil && shownModals == ["Helper exited slow"],
                     "[§9.5] closed popover presents fallback modal warning")
        print("PASS: [§9.5] Reopened menu bar failure routing & closed modal fallback verified")

        // 7. [§11.1] Hide-during-hydration must drop hidden cached rows, clear alerts, and skip timestamp updates
        func makeBackendCodexResult(id: String = "codex:cred:A", status: String = "critical", fetchedAt: String = "2026-11-22T01:00:00Z") -> ProviderResult {{
            var usage = ProviderUsage(provider: "codex", label: "Codex")
            usage.usageAccountId = "acct-a"
            usage.extra["userId"] = AnyCodable("user-a")
            var summary = UsageNormalizer.normalize(provider: CodexProvider(), usage: usage)
            summary.id = id
            summary.fetchedAt = fetchedAt
            summary.status = status
            summary.statusLabel = status == "critical" ? "Critical" : "OK"
            summary.headline = HeadlineInfo(
                eyebrow: summary.headline.eyebrow,
                primary: summary.headline.primary,
                secondary: status == "critical" ? "0% left" : "95% left",
                supporting: summary.headline.supporting
            )
            return ProviderResult(id: id, providerId: "codex", ok: true, usage: usage, summary: summary)
        }}

        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = []
        let criticalCodexResult = makeBackendCodexResult(id: "codex:cred:A", status: "critical")
        let criticalCodexOverview = UsageNormalizer.createDashboardOverview(
            summaries: [criticalCodexResult.summary!],
            generatedAt: "2026-11-22T01:00:00Z"
        )
        let criticalCodexSnapshot = DashboardSnapshot(
            generatedAt: "2026-11-22T01:00:00Z",
            overview: criticalCodexOverview,
            providers: [criticalCodexResult]
        )

        // (a) Visible control
        let visibleHydrateCoord = CoordinatorUnderTest()
        visibleHydrateCoord.selected = ["codex"]
        visibleHydrateCoord.engine.onCachedDashboard = {{ _ in criticalCodexSnapshot }}
        await visibleHydrateCoord.hydrateFromDiskCacheIfNeeded()
        precondition(visibleHydrateCoord.providers.map(\\.baseProviderId) == ["codex"]
                        && visibleHydrateCoord.overview?.activeProviders == 1
                        && visibleHydrateCoord.overview?.criticalProviders == 1
                        && visibleHydrateCoord.overview?.alerts.map(\\.id) == ["codex:cred:A:status-critical"]
                        && visibleHydrateCoord.markedRefreshed.count == 1
                        && visibleHydrateCoord.providerRefreshTimes["codex"] != nil,
                     "[§11.1] visible control hydrates Codex row, critical alert, and timestamps")

        // (b) Hide sole provider while disk cache hydration is suspended
        let fullHideHydrateCoord = CoordinatorUnderTest()
        fullHideHydrateCoord.selected = ["codex"]
        fullHideHydrateCoord.engine.onCachedDashboard = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            return criticalCodexSnapshot
        }}
        await fullHideHydrateCoord.hydrateFromDiskCacheIfNeeded()
        precondition(fullHideHydrateCoord.providers.isEmpty
                        && fullHideHydrateCoord.overview?.activeProviders == 0
                        && fullHideHydrateCoord.overview?.criticalProviders == 0
                        && fullHideHydrateCoord.overview?.alerts.isEmpty == true
                        && fullHideHydrateCoord.markedRefreshed.isEmpty
                        && fullHideHydrateCoord.providerRefreshTimes.isEmpty,
                     "[§11.1] hiding Codex during suspended hydration publishes 0 rows, 0 alerts, and 0 timestamp updates")

        // (c) Partial hide while disk cache hydration is suspended: keep existing visible Antigravity, drop hidden Codex
        AppSettings.shared.hiddenSidebarSections = []
        let partialHideHydrateCoord = CoordinatorUnderTest()
        partialHideHydrateCoord.selected = ["codex", "antigravity"]
        let healthyAGYRow = makeRemoteProvider(id: "antigravity:1", providerId: "antigravity", label: "Antigravity", status: .healthy)
        partialHideHydrateCoord.providers = [healthyAGYRow]
        partialHideHydrateCoord.engine.onCachedDashboard = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            return criticalCodexSnapshot
        }}
        await partialHideHydrateCoord.hydrateFromDiskCacheIfNeeded()
        precondition(partialHideHydrateCoord.providers.map(\\.baseProviderId) == ["antigravity"]
                        && partialHideHydrateCoord.overview?.activeProviders == 1
                        && partialHideHydrateCoord.overview?.criticalProviders == 0
                        && partialHideHydrateCoord.overview?.alerts.isEmpty == true
                        && partialHideHydrateCoord.markedRefreshed.isEmpty
                        && partialHideHydrateCoord.providerRefreshTimes["codex"] == nil,
                     "[§11.1] partial hide during suspended hydration keeps visible Antigravity overview clean of hidden Codex alert")
        AppSettings.shared.hiddenSidebarSections = []
        print("PASS: [§11.1] In-flight hydration visibility filter, overview recomputation & timestamp guard verified")

        // 8. [§11.2] Unchanged row ID (codex:cred:A) with reset-protected healthy content clears stale critical overview
        let healthyCodexBackend = makeBackendCodexResult(id: "codex:cred:A", status: "healthy", fetchedAt: "2026-11-22T02:00:00Z")
        func makeHealthyCodexRow(windows: [QuotaWindow]? = nil) -> ProviderData {{
            var usage = ProviderUsage(provider: "codex", label: "Codex")
            usage.usageAccountId = "acct-a"
            usage.extra["userId"] = AnyCodable("user-a")
            var data = CoordinatorUnderTest().convertSummary(healthyCodexBackend.summary!)
            data = ProviderData(
                id: data.id, providerId: data.providerId, accountId: "acct-a", name: data.name, label: data.label,
                description: data.description, category: data.category, channel: data.channel, status: .healthy,
                statusLabel: "OK", theme: data.theme, sourceLabel: data.sourceLabel, sourceType: data.sourceType,
                fetchedAt: data.fetchedAt, accountLabel: data.accountLabel, membershipLabel: data.membershipLabel,
                workspaceLabel: data.workspaceLabel, workspaceUserId: "user-a",
                headline: Headline(eyebrow: data.headline.eyebrow, primary: data.headline.primary, secondary: "95% left", supporting: data.headline.supporting),
                metrics: data.metrics, windows: windows ?? data.windows, remainingPercent: 95, nextResetAt: data.nextResetAt,
                nextResetLabel: data.nextResetLabel, spotlight: data.spotlight, models: data.models, costSummary: data.costSummary,
                sourceFilePath: data.sourceFilePath, errorCode: nil, codexResetCreditsAvailableCount: 3
            )
            return data
        }}

        // (a) Local fetchDashboardLocal
        let localSameIDCoord = CoordinatorUnderTest()
        localSameIDCoord.selected = ["codex"]
        let healthyLocalRow = makeHealthyCodexRow()
        localSameIDCoord.providers = [healthyLocalRow]
        let codexFenceKey = localSameIDCoord.codexResetIdentity(healthyLocalRow)!
        localSameIDCoord.engine.onFetchAll = {{ _ in
            localSameIDCoord.codexResetRefreshFence.invalidate(codexFenceKey)
            return criticalCodexSnapshot
        }}
        _ = await localSameIDCoord.fetchDashboardLocal()
        precondition(localSameIDCoord.providers.map(\\.id) == ["codex:cred:A"]
                        && localSameIDCoord.providers.first?.status == .healthy
                        && localSameIDCoord.overview?.activeProviders == 1
                        && localSameIDCoord.overview?.criticalProviders == 0
                        && localSameIDCoord.overview?.alerts.isEmpty == true,
                     "[§11.2] Local fetchDashboardLocal rebuilds overview from reset-protected healthy row when ID is unchanged")

        // (b) Remote fetchDashboardRemote
        AppSettings.shared.backendMode = "remote"
        let remoteSameIDCoord = CoordinatorUnderTest()
        remoteSameIDCoord.selected = ["codex"]
        remoteSameIDCoord.providers = [healthyLocalRow]
        let staleCriticalRemoteRow = remoteSameIDCoord.convertSummary(criticalCodexResult.summary!)
        let staleRemoteOverview = remoteSameIDCoord.convertOverview(criticalCodexOverview)
        APIService.shared.onDashboardRequest = {{ _ in
            remoteSameIDCoord.codexResetRefreshFence.invalidate(codexFenceKey)
            return StubDashboardResponse(
                providers: [.init(summary: staleCriticalRemoteRow, ok: true)],
                overview: staleRemoteOverview
            )
        }}
        _ = await remoteSameIDCoord.fetchDashboardRemote(showMessageOnFailure: false)
        precondition(remoteSameIDCoord.providers.map(\\.id) == ["codex:cred:A"]
                        && remoteSameIDCoord.providers.first?.status == .healthy
                        && remoteSameIDCoord.overview?.activeProviders == 1
                        && remoteSameIDCoord.overview?.criticalProviders == 0
                        && remoteSameIDCoord.overview?.alerts.isEmpty == true,
                     "[§11.2] Remote fetchDashboardRemote rebuilds overview from reset-protected healthy row when ID is unchanged")
        print("PASS: [§11.2] Same-ID changed-status overview consistency (Local + Remote) verified")

        // 9. [§13.1] Targeted refresh & replaceProviderEntries arriving after agent hide must drop hidden row/alert
        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = []

        // (a) Visible targeted refresh control
        let targetVisibleCoord = CoordinatorUnderTest()
        targetVisibleCoord.selected = ["codex"]
        targetVisibleCoord.engine.onFetchForCredential = {{ _, _ in criticalCodexResult }}
        await targetVisibleCoord.refreshAccountNow(credentialId: "A", providerId: "codex")
        precondition(targetVisibleCoord.providers.map(\\.id) == ["codex:cred:A"]
                        && targetVisibleCoord.markedRefreshed.count == 1
                        && !targetVisibleCoord.accountRefreshTimes.isEmpty,
                     "[§13.1] visible targeted refresh publishes Codex row and timestamps")

        // (b) Hide both Codex sidebar sections while targeted critical refresh is in flight
        AppSettings.shared.hiddenSidebarSections = []
        let targetHideCoord = CoordinatorUnderTest()
        targetHideCoord.selected = ["codex"]
        targetHideCoord.providers = [healthyLocalRow]
        targetHideCoord.overview = targetHideCoord.recomputedOverview(
            for: [healthyLocalRow], baseOverview: nil, generatedAt: "2026-11-22T03:00:00Z", language: "en"
        )
        targetHideCoord.engine.onFetchForCredential = {{ _, _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            targetHideCoord.providers = []
            targetHideCoord.overview = targetHideCoord.recomputedOverview(
                for: [], baseOverview: nil, generatedAt: "2026-11-22T03:01:00Z", language: "en"
            )
            return criticalCodexResult
        }}
        await targetHideCoord.refreshAccountNow(credentialId: "A", providerId: "codex")
        precondition(targetHideCoord.providers.isEmpty
                        && targetHideCoord.overview?.activeProviders == 0
                        && targetHideCoord.overview?.criticalProviders == 0
                        && targetHideCoord.overview?.alerts.isEmpty == true
                        && targetHideCoord.markedRefreshed.isEmpty
                        && targetHideCoord.accountRefreshTimes.isEmpty,
                     "[§13.1] hiding Codex during targeted critical refresh prevents row/alert/timestamp resurrection")

        // (c) Subsequent refreshAccountNow while hidden makes 0 new requests
        let countAfterHide = targetHideCoord.engine.credentialFetchCount
        await targetHideCoord.refreshAccountNow(credentialId: "A", providerId: "codex")
        precondition(targetHideCoord.engine.credentialFetchCount == countAfterHide,
                     "[§13.1] second targeted refresh while hidden makes 0 backend requests")

        // (d) Hide both Codex sidebar sections while targeted terminal-error refresh is in flight
        AppSettings.shared.hiddenSidebarSections = []
        var terminalUsage = ProviderUsage(provider: "codex", label: "Codex")
        terminalUsage.usageAccountId = "acct-a"
        terminalUsage.extra["userId"] = AnyCodable("user-a")
        var terminalSummary = UsageNormalizer.normalize(provider: CodexProvider(), usage: terminalUsage)
        terminalSummary.id = "codex:cred:A"
        terminalSummary.status = "error"
        terminalSummary.errorCode = "tos_violation"
        let terminalErrorResult = ProviderResult(id: "codex:cred:A", providerId: "codex", ok: false, usage: terminalUsage, summary: terminalSummary, error: "TOS violation")

        let terminalHideCoord = CoordinatorUnderTest()
        terminalHideCoord.selected = ["codex"]
        terminalHideCoord.providers = [healthyLocalRow]
        terminalHideCoord.overview = terminalHideCoord.recomputedOverview(
            for: [healthyLocalRow], baseOverview: nil, generatedAt: "2026-11-22T03:02:00Z", language: "en"
        )
        terminalHideCoord.engine.onFetchForCredential = {{ _, _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            terminalHideCoord.providers = []
            terminalHideCoord.overview = terminalHideCoord.recomputedOverview(
                for: [], baseOverview: nil, generatedAt: "2026-11-22T03:03:00Z", language: "en"
            )
            return terminalErrorResult
        }}
        await terminalHideCoord.refreshAccountNow(credentialId: "A", providerId: "codex")
        precondition(terminalHideCoord.providers.isEmpty
                        && terminalHideCoord.overview?.activeProviders == 0
                        && terminalHideCoord.overview?.alerts.isEmpty == true
                        && terminalHideCoord.recordedAccountErrors.isEmpty
                        && terminalHideCoord.errorMessage == nil
                        && terminalHideCoord.accountRefreshTimes.isEmpty,
                     "[§13.1] terminal error arriving after hide drops hidden row/error/alert cleanly")

        // (e) replaceProviderEntries also filters hidden replacements and recomputes overview
        terminalHideCoord.replaceProviderEntries(for: "codex", with: [healthyLocalRow])
        precondition(terminalHideCoord.providers.isEmpty
                        && terminalHideCoord.overview?.activeProviders == 0
                        && terminalHideCoord.overview?.alerts.isEmpty == true,
                     "[§13.1] replaceProviderEntries ignores hidden Codex replacement and preserves empty overview")
        AppSettings.shared.hiddenSidebarSections = []
        print("PASS: [§13.1] Targeted & single-provider publication guards after agent hide verified")

        // 10. [§15.1] Account/provider removal and late targeted rejection synchronize overview even when row was already pruned
        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = []
        let criticalCodexRow = makeRemoteProvider(id: "codex:cred:A", providerId: "codex", label: "Codex", status: .critical)

        // (a) Hide account via hiddenAccounts + reapplyVisibleSortedProviders clears stale alert
        let accountHideCoord = CoordinatorUnderTest()
        accountHideCoord.selected = ["codex"]
        accountHideCoord.providers = [criticalCodexRow]
        accountHideCoord.overview = accountHideCoord.recomputedOverview(
            for: [criticalCodexRow], baseOverview: nil, generatedAt: "2026-11-22T04:00:00Z", language: "en"
        )
        precondition(accountHideCoord.overview?.alerts.map(\\.id) == ["codex:cred:A:status-critical"],
                     "[§15.1] precondition sets critical alert")
        accountHideCoord.hiddenAccounts.insert("codex:cred:A")
        accountHideCoord.reapplyVisibleSortedProviders()
        precondition(accountHideCoord.providers.isEmpty
                        && accountHideCoord.overview?.activeProviders == 0
                        && accountHideCoord.overview?.criticalProviders == 0
                        && accountHideCoord.overview?.alerts.isEmpty == true,
                     "[§15.1] reapplyVisibleSortedProviders rebuilds overview after account hide")

        // (b) Late targeted rejection reconciles stale overview even when row was already removed before await returns
        let lateEmptyCoord = CoordinatorUnderTest()
        lateEmptyCoord.selected = ["codex"]
        lateEmptyCoord.providers = [criticalCodexRow]
        lateEmptyCoord.overview = lateEmptyCoord.recomputedOverview(
            for: [criticalCodexRow], baseOverview: nil, generatedAt: "2026-11-22T04:01:00Z", language: "en"
        )
        lateEmptyCoord.engine.onFetchForCredential = {{ _, _ in
            // Simulate removeLiveProviders clearing row while stale critical alert lingered in overview
            lateEmptyCoord.hiddenAccounts.insert("codex:cred:A")
            lateEmptyCoord.providers = []
            return criticalCodexResult
        }}
        await lateEmptyCoord.refreshAccountNow(credentialId: "A", providerId: "codex")
        precondition(lateEmptyCoord.providers.isEmpty
                        && lateEmptyCoord.overview?.activeProviders == 0
                        && lateEmptyCoord.overview?.criticalProviders == 0
                        && lateEmptyCoord.overview?.alerts.isEmpty == true
                        && lateEmptyCoord.markedRefreshed.isEmpty
                        && lateEmptyCoord.accountRefreshTimes.isEmpty,
                     "[§15.1] late targeted rejection clears stale overview alert even when pruned.count == providers.count")

        // (c) removeProviders(matchingBaseProviderId:) also syncs overview
        let scanDisableCoord = CoordinatorUnderTest()
        scanDisableCoord.selected = ["codex"]
        scanDisableCoord.providers = [criticalCodexRow]
        scanDisableCoord.overview = scanDisableCoord.recomputedOverview(
            for: [criticalCodexRow], baseOverview: nil, generatedAt: "2026-11-22T04:02:00Z", language: "en"
        )
        scanDisableCoord.removeProviders(matchingBaseProviderId: "codex")
        precondition(scanDisableCoord.providers.isEmpty
                        && scanDisableCoord.overview?.activeProviders == 0
                        && scanDisableCoord.overview?.alerts.isEmpty == true,
                     "[§15.1] removeProviders(matchingBaseProviderId:) clears overview alerts immediately")
        print("PASS: [§15.1] Account/provider removal and late targeted rejection overview sync verified")

        // 11. [§15.2] Single-provider & dashboard error banners re-check visibility after await
        struct MockRemoteTimeoutError: LocalizedError {{
            var errorDescription: String? {{ "Remote quota request timed out" }}
        }}

        // (a) Visible control: Remote refreshProviderNow timeout sets user-visible banner & diagnostic notification
        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = []
        let remoteTimeoutVisibleCoord = CoordinatorUnderTest()
        remoteTimeoutVisibleCoord.selected = ["codex"]
        APIService.shared.onProviderResultsRequest = {{ _ in
            throw MockRemoteTimeoutError()
        }}
        await remoteTimeoutVisibleCoord.refreshProviderNow("codex")
        precondition(remoteTimeoutVisibleCoord.errorMessage == "Remote quota request timed out"
                        && remoteTimeoutVisibleCoord.errorNotifications.count == 1,
                     "[§15.2] visible Remote timeout shows banner and records diagnostic notification")

        // (b) Exact Codex §15.2 repro: hide Codex during Remote refreshProviderNow timeout leaves errorMessage nil
        AppSettings.shared.hiddenSidebarSections = []
        let remoteTimeoutHiddenCoord = CoordinatorUnderTest()
        remoteTimeoutHiddenCoord.selected = ["codex"]
        APIService.shared.onProviderResultsRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            throw MockRemoteTimeoutError()
        }}
        await remoteTimeoutHiddenCoord.refreshProviderNow("codex")
        precondition(remoteTimeoutHiddenCoord.selectedProviderIDList().isEmpty
                        && remoteTimeoutHiddenCoord.providers.isEmpty
                        && remoteTimeoutHiddenCoord.errorMessage == nil
                        && remoteTimeoutHiddenCoord.errorNotifications.count == 1,
                     "[§15.2] hiding provider during Remote timeout keeps diagnostic log but suppresses global error banner")

        // (c) Hide during Remote refreshProviderNow critical success drops row, alert, timestamp & banner
        AppSettings.shared.hiddenSidebarSections = []
        let remoteSuccessHiddenCoord = CoordinatorUnderTest()
        remoteSuccessHiddenCoord.selected = ["codex"]
        remoteSuccessHiddenCoord.overview = remoteSuccessHiddenCoord.recomputedOverview(
            for: [], baseOverview: nil, generatedAt: "2026-11-22T04:03:00Z", language: "en"
        )
        APIService.shared.onProviderResultsRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            return [StubDashboardResponse.StubProviderWrapper(summary: criticalCodexRow, ok: true)]
        }}
        await remoteSuccessHiddenCoord.refreshProviderNow("codex")
        precondition(remoteSuccessHiddenCoord.providers.isEmpty
                        && remoteSuccessHiddenCoord.overview?.activeProviders == 0
                        && remoteSuccessHiddenCoord.overview?.alerts.isEmpty == true
                        && remoteSuccessHiddenCoord.providerRefreshTimes["codex"] == nil
                        && remoteSuccessHiddenCoord.errorMessage == nil,
                     "[§15.2] hiding provider during Remote success drops row, alert, timestamp, and banner")

        // (d) Remote fetchDashboard timeout: visible control shows banner, hide mid-flight suppresses banner
        AppSettings.shared.hiddenSidebarSections = []
        let remoteDashVisible = CoordinatorUnderTest()
        remoteDashVisible.selected = ["codex"]
        APIService.shared.onDashboardRequest = {{ _ in throw MockRemoteTimeoutError() }}
        _ = await remoteDashVisible.fetchDashboard()
        precondition(remoteDashVisible.errorMessage == "Remote quota request timed out",
                     "[§15.2] visible Remote fetchDashboard timeout shows banner")

        AppSettings.shared.hiddenSidebarSections = []
        let remoteDashHidden = CoordinatorUnderTest()
        remoteDashHidden.selected = ["codex"]
        APIService.shared.onDashboardRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            throw MockRemoteTimeoutError()
        }}
        _ = await remoteDashHidden.fetchDashboard()
        precondition(remoteDashHidden.errorMessage == nil,
                     "[§15.2] hiding last provider during Remote fetchDashboard timeout suppresses global error banner")

        // (e) Local fetchSingleProviderLocal non-terminal error after hide suppresses account error, row & banner
        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = []
        var nonTerminalUsage = ProviderUsage(provider: "codex", label: "Codex")
        nonTerminalUsage.usageAccountId = "acct-a"
        nonTerminalUsage.extra["userId"] = AnyCodable("user-a")
        var nonTerminalSummary = UsageNormalizer.normalize(provider: CodexProvider(), usage: nonTerminalUsage)
        nonTerminalSummary.id = "codex:cred:A"
        nonTerminalSummary.status = "error"
        nonTerminalSummary.errorCode = "temporary_503"
        let nonTerminalErrorResult = ProviderResult(id: "codex:cred:A", providerId: "codex", ok: false, usage: nonTerminalUsage, summary: nonTerminalSummary, error: "Temporary 503")

        let localSingleHiddenCoord = CoordinatorUnderTest()
        localSingleHiddenCoord.selected = ["codex"]
        localSingleHiddenCoord.providers = [healthyLocalRow]
        localSingleHiddenCoord.overview = localSingleHiddenCoord.recomputedOverview(
            for: [healthyLocalRow], baseOverview: nil, generatedAt: "2026-11-22T04:04:00Z", language: "en"
        )
        localSingleHiddenCoord.engine.onFetchMulti = {{ _ in nil }}
        localSingleHiddenCoord.engine.onFetchSingle = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            return nonTerminalErrorResult
        }}
        await localSingleHiddenCoord.refreshProviderNow("codex")
        precondition(localSingleHiddenCoord.providers.isEmpty
                        && localSingleHiddenCoord.overview?.activeProviders == 0
                        && localSingleHiddenCoord.overview?.alerts.isEmpty == true
                        && localSingleHiddenCoord.recordedAccountErrors.isEmpty
                        && localSingleHiddenCoord.errorMessage == nil,
                     "[§15.2] hiding provider during Local single-provider non-terminal error clears row and suppresses error banner")

        APIService.shared.onProviderResultsRequest = nil
        AppSettings.shared.hiddenSidebarSections = []
        print("PASS: [§15.2] Single-provider & dashboard post-await error banner visibility guards verified")

        // 12. [§17.1] Remote/Local dashboard disjoint-scope & follow-up poll scope guards
        let claudeRemoteRow = makeRemoteProvider(id: "claude-subscription:1", providerId: "claude-subscription", label: "Claude", status: .healthy)

        // (a) Exact §17.1 disjoint-scope Remote timeout: Codex requested, switched to Claude before timeout
        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        APIService.shared.recordedURLs.removeAll()
        let disjointErrCoord = CoordinatorUnderTest()
        disjointErrCoord.selected = ["codex", "claude-subscription"]
        disjointErrCoord.errorMessage = nil
        precondition(disjointErrCoord.selectedProviderIDList() == ["codex"], "[§17.1] precondition starts Codex-only visible")
        APIService.shared.onDashboardRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            throw MockRemoteTimeoutError()
        }}
        _ = await disjointErrCoord.fetchDashboard()
        precondition(disjointErrCoord.selectedProviderIDList() == ["claude-subscription"]
                        && APIService.shared.recordedURLs.last?.query == "ids=codex"
                        && disjointErrCoord.errorMessage == nil,
                     "[§17.1] disjoint Codex-only timeout must not show error banner when only Claude is visible")

        // Repeat with an active Claude error set in flight: obsolete Codex failure must not overwrite Claude's banner
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        APIService.shared.recordedURLs.removeAll()
        let disjointPreserveCoord = CoordinatorUnderTest()
        disjointPreserveCoord.selected = ["codex", "claude-subscription"]
        APIService.shared.onDashboardRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            disjointPreserveCoord.errorMessage = "Visible Claude refresh timed out"
            throw MockRemoteTimeoutError()
        }}
        _ = await disjointPreserveCoord.fetchDashboard()
        precondition(disjointPreserveCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§17.1] disjoint Codex-only timeout preserves existing visible Claude banner without overwriting")

        // (b1) Follow-up refresh_pending poll remains Codex-only, hides Codex before poll 2 fails -> no banner
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        APIService.shared.recordedURLs.removeAll()
        let pendingCodexRow = makeRemoteProvider(id: "codex:1", providerId: "codex", label: "Codex", status: .healthy, errorCode: "refresh_pending")
        var pollCallB1 = 0
        let pollDisjointCoord = CoordinatorUnderTest()
        pollDisjointCoord.selected = ["codex", "claude-subscription"]
        APIService.shared.onDashboardRequest = {{ _ in
            pollCallB1 += 1
            if pollCallB1 == 1 {{
                return StubDashboardResponse(providers: [.init(summary: pendingCodexRow, ok: true)], overview: emptyAppOverview)
            }}
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            throw MockRemoteTimeoutError()
        }}
        _ = await pollDisjointCoord.fetchDashboard()
        precondition(APIService.shared.recordedURLs.map(\\.query) == ["ids=codex", "ids=codex"]
                        && pollDisjointCoord.selectedProviderIDList() == ["claude-subscription"]
                        && pollDisjointCoord.errorMessage == nil,
                     "[§17.1] follow-up Codex-only poll failing after switch to Claude suppresses banner")

        // (b2) Updated follow-up poll actually requested Claude before failing while Claude stays visible -> shows banner
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        APIService.shared.recordedURLs.removeAll()
        var pollCallB2 = 0
        let pollClaudeVisibleCoord = CoordinatorUnderTest()
        pollClaudeVisibleCoord.selected = ["codex", "claude-subscription"]
        APIService.shared.onDashboardRequest = {{ _ in
            pollCallB2 += 1
            if pollCallB2 == 1 {{
                AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
                return StubDashboardResponse(providers: [.init(summary: pendingCodexRow, ok: true)], overview: emptyAppOverview)
            }}
            throw MockRemoteTimeoutError()
        }}
        _ = await pollClaudeVisibleCoord.fetchDashboard()
        precondition(APIService.shared.recordedURLs.map(\\.query) == ["ids=codex", "ids=claude-subscription"]
                        && pollClaudeVisibleCoord.errorMessage == "Remote quota request timed out",
                     "[§17.1] follow-up poll requesting newly visible Claude shows banner when that follow-up fails")

        // (c) Disjoint settled Remote & Local dashboard preserves newly visible Claude rows & error banner
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let remoteSettledDisjoint = CoordinatorUnderTest()
        remoteSettledDisjoint.selected = ["codex", "claude-subscription"]
        APIService.shared.onDashboardRequest = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            remoteSettledDisjoint.providers = [claudeRemoteRow]
            remoteSettledDisjoint.errorMessage = "Visible Claude refresh timed out"
            return StubDashboardResponse(providers: [.init(summary: settledCodex, ok: true)], overview: staleCodexAlertOverview)
        }}
        _ = await remoteSettledDisjoint.fetchDashboard()
        precondition(remoteSettledDisjoint.providers.map(\\.id) == ["claude-subscription:1"]
                        && remoteSettledDisjoint.errorMessage == "Visible Claude refresh timed out",
                     "[§17.1] disjoint settled Remote dashboard preserves newly visible Claude row and banner")

        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let localSettledDisjoint = CoordinatorUnderTest()
        localSettledDisjoint.selected = ["codex", "claude-subscription"]
        localSettledDisjoint.engine.onFetchAll = {{ _ in
            AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
            localSettledDisjoint.providers = [claudeRemoteRow]
            localSettledDisjoint.errorMessage = "Visible Claude refresh timed out"
            return criticalCodexSnapshot
        }}
        _ = await localSettledDisjoint.fetchDashboard()
        precondition(localSettledDisjoint.providers.map(\\.id) == ["claude-subscription:1"]
                        && localSettledDisjoint.errorMessage == "Visible Claude refresh timed out",
                     "[§17.1] disjoint settled Local dashboard preserves newly visible Claude row and banner")
        print("PASS: [§17.1] Disjoint dashboard scope and follow-up poll guards verified")

        // 13. [§17.2] Hidden late per-provider completion performs no write to shared errorMessage
        struct MockClaudeTimeoutError: LocalizedError {{
            var errorDescription: String? {{ "Visible Claude refresh timed out" }}
        }}

        // (a) Exact §17.2 ordered Remote two-request repro (hidden Codex error completes after visible Claude error)
        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = []
        let orderedErrCoord = CoordinatorUnderTest()
        orderedErrCoord.selected = ["codex", "claude-subscription"]
        var codexErrGate: CheckedContinuation<[StubDashboardResponse.StubProviderWrapper], Error>?
        APIService.shared.onProviderResultsRequest = {{ providerId in
            if providerId == "codex" {{
                return try await withCheckedThrowingContinuation {{ codexErrGate = $0 }}
            }}
            throw MockClaudeTimeoutError()
        }}
        let codexErrTask = Task {{ await orderedErrCoord.refreshProviderNow("codex") }}
        while codexErrGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
        precondition(orderedErrCoord.selectedProviderIDList() == ["claude-subscription"], "[§17.2] Claude remains visible after Codex hide")
        await orderedErrCoord.refreshProviderNow("claude-subscription")
        let bannerBeforeHiddenFinish = orderedErrCoord.errorMessage
        precondition(bannerBeforeHiddenFinish == "Visible Claude refresh timed out",
                     "[§17.2] visible Claude failure populates shared error banner")
        codexErrGate?.resume(throwing: MockRemoteTimeoutError())
        _ = await codexErrTask.value
        precondition(orderedErrCoord.errorMessage == "Visible Claude refresh timed out"
                        && orderedErrCoord.errorNotifications.count == 2,
                     "[§17.2] late hidden Codex timeout performs zero write to Claude banner while keeping diagnostic logs")

        // (b) Hidden Codex success completes after visible Claude error -> still zero write to Claude banner
        AppSettings.shared.hiddenSidebarSections = []
        let orderedSuccessCoord = CoordinatorUnderTest()
        orderedSuccessCoord.selected = ["codex", "claude-subscription"]
        var codexSuccessGate: CheckedContinuation<[StubDashboardResponse.StubProviderWrapper], Error>?
        APIService.shared.onProviderResultsRequest = {{ providerId in
            if providerId == "codex" {{
                return try await withCheckedThrowingContinuation {{ codexSuccessGate = $0 }}
            }}
            throw MockClaudeTimeoutError()
        }}
        let codexSuccessTask = Task {{ await orderedSuccessCoord.refreshProviderNow("codex") }}
        while codexSuccessGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = [AppSection.codexProxyManagement.rawValue, AppSection.codexLocalManagement.rawValue]
        await orderedSuccessCoord.refreshProviderNow("claude-subscription")
        precondition(orderedSuccessCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§17.2] (b) visible Claude failure populates shared error banner")
        codexSuccessGate?.resume(returning: [StubDashboardResponse.StubProviderWrapper(summary: criticalCodexRow, ok: true)])
        _ = await codexSuccessTask.value
        precondition(orderedSuccessCoord.providers.isEmpty
                        && orderedSuccessCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§17.2] late hidden Codex success performs zero write to Claude banner")

        // (c) Local targeted refreshAccountNow explicitly hidden during concurrent Claude error performs zero write
        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = []
        let claudeLocalUsage = ProviderUsage(provider: "claude-subscription", label: "Claude")
        var claudeLocalSummary = UsageNormalizer.normalize(provider: CodexProvider(), usage: claudeLocalUsage)
        claudeLocalSummary.id = "claude-subscription:1"
        claudeLocalSummary.providerId = "claude-subscription"
        claudeLocalSummary.status = "error"
        claudeLocalSummary.errorCode = "temporary_503"
        let claudeLocalNonTerminal = ProviderResult(
            id: "claude-subscription:1",
            providerId: "claude-subscription",
            ok: false,
            usage: claudeLocalUsage,
            summary: claudeLocalSummary,
            error: "Visible Claude 503"
        )
        let claudeLocalPreservable = ProviderData(
            id: "claude-subscription:1",
            providerId: "claude-subscription",
            accountId: nil,
            name: "Claude",
            label: "Claude",
            description: "",
            category: "quota",
            channel: nil,
            status: .healthy,
            statusLabel: "OK",
            theme: ProviderTheme(accent: "#000", glow: "#000"),
            sourceLabel: "",
            sourceType: "oauth",
            fetchedAt: nil,
            accountLabel: nil,
            membershipLabel: nil,
            headline: Headline(eyebrow: "", primary: "", secondary: "90% left", supporting: nil),
            metrics: [],
            windows: [QuotaWindow(label: "5h", remainingPercent: 90, usedPercent: 10, value: "90%", note: "", resetAt: nil)],
            remainingPercent: 90,
            nextResetAt: nil,
            nextResetLabel: nil,
            spotlight: nil,
            models: nil,
            costSummary: nil,
            errorCode: nil
        )
        let orderedAcctCoord = CoordinatorUnderTest()
        orderedAcctCoord.selected = ["codex", "claude-subscription"]
        orderedAcctCoord.providers = [claudeLocalPreservable]
        var acctGate: CheckedContinuation<ProviderResult?, Never>?
        orderedAcctCoord.engine.onFetchForCredential = {{ _, _ in
            await withCheckedContinuation {{ acctGate = $0 }}
        }}
        orderedAcctCoord.engine.onFetchMulti = {{ _ in nil }}
        orderedAcctCoord.engine.onFetchSingle = {{ _ in claudeLocalNonTerminal }}
        let acctTask = Task {{ await orderedAcctCoord.refreshAccountNow(credentialId: "A", providerId: "codex") }}
        while acctGate == nil {{ await Task.yield() }}
        orderedAcctCoord.hiddenAccounts.insert("codex:cred:A")
        await orderedAcctCoord.refreshProviderNow("claude-subscription")
        precondition(orderedAcctCoord.errorMessage == "Visible Claude 503"
                        && orderedAcctCoord.recordedAccountErrors == ["Visible Claude 503"],
                     "[§17.2] (c) visible Claude Local failure populates shared banner")
        acctGate?.resume(returning: criticalCodexResult)
        _ = await acctTask.value
        precondition(orderedAcctCoord.providers.map(\\.id) == ["claude-subscription:1"]
                        && orderedAcctCoord.errorMessage == "Visible Claude 503",
                     "[§17.2] late hidden account refresh performs zero write to visible Claude banner")

        // (d) Engine returning nil for excluded credential (AccountStore.hideAccounts parity) also performs zero write
        var nilAcctGate: CheckedContinuation<ProviderResult?, Never>?
        orderedAcctCoord.engine.onFetchForCredential = {{ _, _ in
            await withCheckedContinuation {{ nilAcctGate = $0 }}
        }}
        let nilAcctTask = Task {{ await orderedAcctCoord.refreshAccountNow(credentialId: "A", providerId: "codex") }}
        while nilAcctGate == nil {{ await Task.yield() }}
        orderedAcctCoord.errorMessage = "Visible Claude 503"
        nilAcctGate?.resume(returning: nil)
        _ = await nilAcctTask.value
        precondition(orderedAcctCoord.providers.map(\\.id) == ["claude-subscription:1"]
                        && orderedAcctCoord.errorMessage == "Visible Claude 503",
                     "[§17.2] (d) nil/excluded targeted account result performs zero write to visible Claude banner")

        // (e) Selected provider whose returned accounts are all account-hidden (Local + Remote) performs zero write
        var multiGate: CheckedContinuation<[ProviderResult]?, Never>?
        orderedAcctCoord.engine.onFetchMulti = {{ id in
            if id == "codex" {{
                return await withCheckedContinuation {{ multiGate = $0 }}
            }}
            return nil
        }}
        let allHiddenLocalTask = Task {{ await orderedAcctCoord.refreshProviderNow("codex") }}
        while multiGate == nil {{ await Task.yield() }}
        orderedAcctCoord.hiddenAccounts.insert("codex:cred:A")
        await orderedAcctCoord.refreshProviderNow("claude-subscription")
        precondition(orderedAcctCoord.errorMessage == "Visible Claude 503",
                     "[§17.2] (e) visible Claude failure sets shared banner before hidden-only Codex Local finishes")
        multiGate?.resume(returning: [criticalCodexResult])
        _ = await allHiddenLocalTask.value
        precondition(orderedAcctCoord.providers.map(\\.id) == ["claude-subscription:1"]
                        && orderedAcctCoord.errorMessage == "Visible Claude 503",
                     "[§17.2] (e) all-hidden Local provider results perform zero write to visible Claude banner")

        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = []
        let remoteAllHiddenCoord = CoordinatorUnderTest()
        remoteAllHiddenCoord.selected = ["codex", "claude-subscription"]
        var remoteCodexAllHiddenGate: CheckedContinuation<[StubDashboardResponse.StubProviderWrapper], Error>?
        APIService.shared.onProviderResultsRequest = {{ providerId in
            if providerId == "codex" {{
                return try await withCheckedThrowingContinuation {{ remoteCodexAllHiddenGate = $0 }}
            }}
            throw MockClaudeTimeoutError()
        }}
        let remoteAllHiddenTask = Task {{ await remoteAllHiddenCoord.refreshProviderNow("codex") }}
        while remoteCodexAllHiddenGate == nil {{ await Task.yield() }}
        remoteAllHiddenCoord.hiddenAccounts.insert("codex:cred:A")
        await remoteAllHiddenCoord.refreshProviderNow("claude-subscription")
        precondition(remoteAllHiddenCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§17.2] (f) visible Claude Remote failure sets shared banner before hidden-only Codex Remote finishes")
        remoteCodexAllHiddenGate?.resume(returning: [StubDashboardResponse.StubProviderWrapper(summary: criticalCodexRow, ok: true)])
        _ = await remoteAllHiddenTask.value
        precondition(remoteAllHiddenCoord.providers.isEmpty
                        && remoteAllHiddenCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§17.2] (f) all-hidden Remote provider results perform zero write to visible Claude banner")

        APIService.shared.onProviderResultsRequest = nil
        AppSettings.shared.hiddenSidebarSections = []
        print("PASS: [§17.2] Ordered hidden per-provider/account no-write banner guards verified")

        // 14. [§19.1] Partial-overlap dashboard settlement merges only covered visible IDs and preserves newly shown providers
        let criticalClaudeRow = makeRemoteProvider(id: "claude-subscription:1", providerId: "claude-subscription", label: "Claude", status: .critical)
        let healthyCodexBackendResult = makeBackendCodexResult(id: "codex:cred:A", status: "healthy", fetchedAt: "2026-11-22T02:00:00Z")
        let healthyCodexOverview = UsageNormalizer.createDashboardOverview(
            summaries: [healthyCodexBackendResult.summary!],
            generatedAt: "2026-11-22T02:00:00Z"
        )
        let healthyCodexSnapshot = DashboardSnapshot(
            generatedAt: "2026-11-22T02:00:00Z",
            overview: healthyCodexOverview,
            providers: [healthyCodexBackendResult]
        )

        // (a) Exact §19.1 Local partial-overlap repro: Codex-only dashboard settles after Claude is un-hidden and populated
        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let localPartialCoord = CoordinatorUnderTest()
        localPartialCoord.selected = ["codex", "claude-subscription"]
        var localPartialIds: [String] = []
        var localPartialGate: CheckedContinuation<DashboardSnapshot, Never>?
        localPartialCoord.engine.onFetchAll = {{ ids in
            localPartialIds = ids
            return await withCheckedContinuation {{ localPartialGate = $0 }}
        }}
        let localPartialTask = Task {{ await localPartialCoord.fetchDashboard() }}
        while localPartialGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = []
        localPartialCoord.replaceProviderEntries(for: "claude-subscription", with: [criticalClaudeRow])
        precondition(localPartialIds == ["codex"]
                        && localPartialCoord.selectedProviderIDList() == ["claude-subscription", "codex"]
                        && localPartialCoord.providers.map(\\.baseProviderId) == ["claude-subscription"],
                     "[§19.1] (a) Local precondition: Codex-only request in flight while Claude card appears")
        localPartialGate?.resume(returning: healthyCodexSnapshot)
        _ = await localPartialTask.value
        precondition(localPartialCoord.providers.map(\\.baseProviderId) == ["claude-subscription", "codex"]
                        && localPartialCoord.overview?.activeProviders == 2
                        && localPartialCoord.overview?.criticalProviders == 1
                        && localPartialCoord.overview?.alerts.map(\\.id) == ["claude-subscription:1:status-critical"],
                     "[§19.1] (a) Local partial-overlap dashboard merges Codex without dropping newly shown Claude row or alert")

        // (b) Exact §19.1 Remote partial-overlap repro: Codex-only dashboard settles after Claude single-provider refresh completes
        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        APIService.shared.recordedURLs.removeAll()
        let remotePartialCoord = CoordinatorUnderTest()
        remotePartialCoord.selected = ["codex", "claude-subscription"]
        var remotePartialGate: CheckedContinuation<StubDashboardResponse, Error>?
        APIService.shared.onDashboardRequest = {{ _ in
            try await withCheckedThrowingContinuation {{ remotePartialGate = $0 }}
        }}
        APIService.shared.onProviderResultsRequest = {{ _ in
            [StubDashboardResponse.StubProviderWrapper(summary: criticalClaudeRow, ok: true)]
        }}
        let remotePartialTask = Task {{ await remotePartialCoord.fetchDashboard() }}
        while remotePartialGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = []
        await remotePartialCoord.refreshProviderNow("claude-subscription")
        precondition(APIService.shared.recordedURLs.last?.query == "ids=codex"
                        && remotePartialCoord.selectedProviderIDList() == ["claude-subscription", "codex"]
                        && remotePartialCoord.providers.map(\\.baseProviderId) == ["claude-subscription"],
                     "[§19.1] (b) Remote precondition: Codex-only dashboard held while Claude single-provider card published")
        remotePartialGate?.resume(returning: StubDashboardResponse(
            providers: [.init(summary: healthyLocalRow, ok: true)],
            overview: emptyAppOverview
        ))
        _ = await remotePartialTask.value
        precondition(remotePartialCoord.providers.map(\\.baseProviderId) == ["claude-subscription", "codex"]
                        && remotePartialCoord.overview?.activeProviders == 2
                        && remotePartialCoord.overview?.criticalProviders == 1
                        && remotePartialCoord.overview?.alerts.map(\\.id) == ["claude-subscription:1:status-critical"],
                     "[§19.1] (b) Remote partial-overlap dashboard merges Codex without dropping newly shown Claude row or alert")

        // (c) Remote refresh_pending Poll 2 expands to [claude-subscription, codex] and authoritatively replaces both
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        APIService.shared.recordedURLs.removeAll()
        let pollExpandCoord = CoordinatorUnderTest()
        pollExpandCoord.selected = ["codex", "claude-subscription"]
        var pollExpandCount = 0
        APIService.shared.onDashboardRequest = {{ _ in
            pollExpandCount += 1
            if pollExpandCount == 1 {{
                AppSettings.shared.hiddenSidebarSections = []
                pollExpandCoord.replaceProviderEntries(for: "claude-subscription", with: [criticalClaudeRow])
                return StubDashboardResponse(providers: [.init(summary: pendingCodexRow, ok: true)], overview: emptyAppOverview)
            }}
            return StubDashboardResponse(providers: [.init(summary: healthyLocalRow, ok: true)], overview: emptyAppOverview)
        }}
        _ = await pollExpandCoord.fetchDashboard()
        precondition(APIService.shared.recordedURLs.map(\\.query) == ["ids=codex", "ids=claude-subscription,codex"]
                        && pollExpandCoord.providers.map(\\.baseProviderId) == ["codex"]
                        && pollExpandCoord.overview?.activeProviders == 1
                        && pollExpandCoord.overview?.criticalProviders == 0
                        && pollExpandCoord.overview?.alerts.isEmpty == true,
                     "[§19.1] (c) Remote refresh_pending Poll 2 tracks expanded attempted IDs and strips unreturned covered Claude row")

        // (d) Authoritative empty response for requested Codex removes old Codex card while preserving newly shown Claude (Local & Remote)
        AppSettings.shared.backendMode = "local"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let emptyLocalCoord = CoordinatorUnderTest()
        emptyLocalCoord.selected = ["codex", "claude-subscription"]
        emptyLocalCoord.providers = [criticalCodexRow]
        emptyLocalCoord.overview = emptyLocalCoord.recomputedOverview(
            for: [criticalCodexRow], baseOverview: nil, generatedAt: "2026-11-22T05:00:00Z", language: "en"
        )
        var emptyLocalGate: CheckedContinuation<DashboardSnapshot, Never>?
        emptyLocalCoord.engine.onFetchAll = {{ _ in
            await withCheckedContinuation {{ emptyLocalGate = $0 }}
        }}
        let emptyLocalTask = Task {{ await emptyLocalCoord.fetchDashboard() }}
        while emptyLocalGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = []
        emptyLocalCoord.replaceProviderEntries(for: "claude-subscription", with: [claudeRemoteRow])
        emptyLocalGate?.resume(returning: DashboardSnapshot(
            generatedAt: "2026-11-22T05:01:00Z",
            overview: UsageNormalizer.createDashboardOverview(summaries: [], generatedAt: "2026-11-22T05:01:00Z"),
            providers: []
        ))
        _ = await emptyLocalTask.value
        precondition(emptyLocalCoord.providers.map(\\.id) == ["claude-subscription:1"]
                        && emptyLocalCoord.overview?.activeProviders == 1
                        && emptyLocalCoord.overview?.criticalProviders == 0
                        && emptyLocalCoord.overview?.alerts.isEmpty == true,
                     "[§19.1] (d) Local authoritative empty Codex response removes stale Codex card while keeping newly shown Claude")

        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let emptyRemoteCoord = CoordinatorUnderTest()
        emptyRemoteCoord.selected = ["codex", "claude-subscription"]
        emptyRemoteCoord.providers = [criticalCodexRow]
        emptyRemoteCoord.overview = emptyRemoteCoord.recomputedOverview(
            for: [criticalCodexRow], baseOverview: nil, generatedAt: "2026-11-22T05:02:00Z", language: "en"
        )
        var emptyRemoteGate: CheckedContinuation<StubDashboardResponse, Error>?
        APIService.shared.onDashboardRequest = {{ _ in
            try await withCheckedThrowingContinuation {{ emptyRemoteGate = $0 }}
        }}
        APIService.shared.onProviderResultsRequest = {{ _ in
            [StubDashboardResponse.StubProviderWrapper(summary: claudeRemoteRow, ok: true)]
        }}
        let emptyRemoteTask = Task {{ await emptyRemoteCoord.fetchDashboard() }}
        while emptyRemoteGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = []
        await emptyRemoteCoord.refreshProviderNow("claude-subscription")
        emptyRemoteGate?.resume(returning: StubDashboardResponse(providers: [], overview: emptyAppOverview))
        _ = await emptyRemoteTask.value
        precondition(emptyRemoteCoord.providers.map(\\.id) == ["claude-subscription:1"]
                        && emptyRemoteCoord.overview?.activeProviders == 1
                        && emptyRemoteCoord.overview?.criticalProviders == 0
                        && emptyRemoteCoord.overview?.alerts.isEmpty == true,
                     "[§19.1] (d) Remote authoritative empty Codex response removes stale Codex card while keeping newly shown Claude")

        // (e) Partial-overlap newly shown Claude timeout banner is preserved when Codex-only dashboard settles
        AppSettings.shared.backendMode = "remote"
        AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
        let bannerPartialCoord = CoordinatorUnderTest()
        bannerPartialCoord.selected = ["codex", "claude-subscription"]
        var bannerPartialGate: CheckedContinuation<StubDashboardResponse, Error>?
        APIService.shared.onDashboardRequest = {{ _ in
            try await withCheckedThrowingContinuation {{ bannerPartialGate = $0 }}
        }}
        APIService.shared.onProviderResultsRequest = {{ _ in throw MockClaudeTimeoutError() }}
        let bannerPartialTask = Task {{ await bannerPartialCoord.fetchDashboard() }}
        while bannerPartialGate == nil {{ await Task.yield() }}
        AppSettings.shared.hiddenSidebarSections = []
        await bannerPartialCoord.refreshProviderNow("claude-subscription")
        precondition(bannerPartialCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§19.1] (e) precondition sets Claude error banner while Codex dashboard in flight")
        bannerPartialGate?.resume(returning: StubDashboardResponse(
            providers: [.init(summary: healthyLocalRow, ok: true)],
            overview: emptyAppOverview
        ))
        _ = await bannerPartialTask.value
        precondition(bannerPartialCoord.providers.map(\\.id) == ["codex:cred:A"]
                        && bannerPartialCoord.errorMessage == "Visible Claude refresh timed out",
                     "[§19.1] (e) partial-overlap Codex dashboard settlement does not erase active uncovered Claude banner")

        print("PASS: [§19.1] Partial-overlap dashboard merge, follow-up poll scope & uncovered banner preservation verified")

        // [§21.1] A targeted Codex timeout clears only when Codex recovers, even with uncovered Claude visible.
        for recovers in [true, false] {{
            AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
            let coord = CoordinatorUnderTest()
            coord.selected = ["codex", "claude-subscription"]
            var gate: CheckedContinuation<StubDashboardResponse, Error>?
            APIService.shared.onDashboardRequest = {{ _ in try await withCheckedThrowingContinuation {{ gate = $0 }} }}
            let dashboardTask = Task {{ await coord.fetchDashboard() }}
            while gate == nil {{ await Task.yield() }}
            precondition(APIService.shared.recordedURLs.last?.query == "ids=codex")
            AppSettings.shared.hiddenSidebarSections = []
            APIService.shared.onProviderResultsRequest = {{ _ in [.init(summary: claudeRemoteRow, ok: true)] }}
            await coord.refreshProviderNow("claude-subscription")
            APIService.shared.onProviderResultsRequest = {{ _ in throw MockRemoteTimeoutError() }}
            await coord.refreshProviderNow("codex")
            precondition(coord.errorMessage == "Remote quota request timed out"
                        && coord.providers.map(\\.id) == ["claude-subscription:1"])
            var bannerDidChange = false
            let observation = coord.objectWillChange.sink {{ bannerDidChange = true }}
            let failedCodex = makeRemoteProvider(id: "codex:cred:A", providerId: "codex", label: "Codex", status: .error)
            gate?.resume(returning: StubDashboardResponse(
                providers: [.init(summary: recovers ? healthyLocalRow : failedCodex, ok: recovers)],
                overview: emptyAppOverview
            ))
            let result = await dashboardTask.value
            precondition(result.status == (recovers ? .success : .failure)
                        && coord.providers.map(\\.id) == ["claude-subscription:1", "codex:cred:A"]
                        && coord.errorMessage == (recovers ? nil : "Remote quota request timed out"),
                         "[§21.1] Clear the covered Codex timeout on successful refresh only")
            withExtendedLifetime(observation) {{
                precondition(bannerDidChange == recovers, "[§21.1] Clearing the banner notifies SwiftUI")
            }}
        }}
        print("PASS: [§21.1] Remote dashboard clears a recovered covered provider's banner and keeps it on failure")
        // Local targeted-account errors must survive recovery of a different credential for the same provider.
        AppSettings.shared.backendMode = "local"
        var failedSummary = UsageNormalizer.errorSummary(provider: CodexProvider(), error: MockRemoteTimeoutError())
        failedSummary.id = "codex:cred:A"
        let failedAccount = ProviderResult(id: failedSummary.id, providerId: "codex", ok: false,
                                          summary: failedSummary, error: "Codex account A timed out")
        for (credential, removesOwner) in [("B", false), ("A", false), ("B", true)] {{
            AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
            let coord = CoordinatorUnderTest()
            coord.selected = ["codex", "claude-subscription"]
            coord.providers = [makeRemoteProvider(id: "codex:cred:A", providerId: "codex", label: "Codex", status: .healthy,
                                                 windows: claudeLocalPreservable.windows)]
            var gate: CheckedContinuation<DashboardSnapshot, Never>?
            coord.engine.onFetchAll = {{ _ in await withCheckedContinuation {{ gate = $0 }} }}
            let dashboardTask = Task {{ await coord.fetchDashboard() }}
            while gate == nil {{ await Task.yield() }}
            if !removesOwner {{
                AppSettings.shared.hiddenSidebarSections = []
                coord.replaceProviderEntries(for: "claude-subscription", with: [claudeRemoteRow])
            }}
            coord.engine.onFetchForCredential = {{ _, _ in failedAccount }}
            await coord.refreshAccountNow(credentialId: "a", providerId: "codex")
            precondition(coord.errorMessage == "Codex account A timed out")
            if removesOwner {{
                coord.hiddenAccounts.insert("codex:cred:A")
                coord.accountStore.excludedCredentials.insert("a")
                coord.reapplyVisibleSortedProviders()
                precondition(coord.errorMessage == nil && coord.providers.isEmpty,
                             "[AGY #1A] Hiding the owning credential clears its banner immediately")
            }}
            let healthy = makeBackendCodexResult(id: "codex:cred:\\(credential)", status: "healthy")
            gate?.resume(returning: DashboardSnapshot(
                generatedAt: "2026-11-22T05:03:00Z", overview: healthyCodexOverview, providers: [healthy]
            ))
            let result = await dashboardTask.value
            let expectedIds = (removesOwner ? [] : ["claude-subscription:1"]) + ["codex:cred:\\(credential)"]
            precondition(result.status == .success
                        && coord.providers.map(\\.id) == expectedIds
                        && coord.errorMessage == (credential == "A" || removesOwner ? nil : "Codex account A timed out"),
                         "[§21.1] Clear a targeted account's banner only on that credential's successful refresh")
        }}
        print("PASS: [§21.1] Local dashboard preserves a sibling credential's banner")
        print("PASS: [AGY #1A] Owner hide clears immediately and full-scope sibling refresh stays clear")

        // A provider can own a timeout before any card exists. Handle all visibility boundaries without waiting for a card.
        for action in ["sidebar", "unselect", "settlement"] {{
            AppSettings.shared.backendMode = "remote"
            AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
            let coord = CoordinatorUnderTest()
            coord.selected = ["codex", "claude-subscription"]
            var gate: CheckedContinuation<StubDashboardResponse, Error>?
            APIService.shared.onDashboardRequest = {{ _ in try await withCheckedThrowingContinuation {{ gate = $0 }} }}
            let task = Task {{ await coord.fetchDashboard() }}
            while gate == nil {{ await Task.yield() }}
            precondition(APIService.shared.recordedURLs.last?.query == "ids=codex")
            AppSettings.shared.hiddenSidebarSections = []
            APIService.shared.onProviderResultsRequest = {{ _ in throw MockClaudeTimeoutError() }}
            await coord.refreshProviderNow("claude-subscription")
            precondition(coord.errorMessage == "Visible Claude refresh timed out" && coord.providers.isEmpty)
            coord.selected.insert("antigravity")
            if action == "unselect" {{
                coord.selected.remove("claude-subscription")
                coord.removeProviders(matchingBaseProviderId: "claude-subscription")
            }} else {{
                AppSettings.shared.hiddenSidebarSections = [AppSection.proxyManagement.rawValue]
                if action == "sidebar" {{ coord.clearStaleOwnedRefreshErrorIfNeeded() }}
            }}
            if action != "settlement" {{
                precondition(coord.errorMessage == nil,
                             "[AGY #1B] Sidebar hide or unselect removes its banner even with zero rows")
            }}
            gate?.resume(returning: StubDashboardResponse(
                providers: [.init(summary: healthyLocalRow, ok: true)], overview: emptyAppOverview
            ))
            let result = await task.value
            precondition(!result.shouldUpdateErrorBanner && coord.errorMessage == nil,
                         "[AGY #1B] Partial settlement cannot keep a banner owned by a hidden provider")
        }}
        print("PASS: [AGY #1B] Sidebar hide, unselect and partial settlement clear an unavailable owner")

        // A protected card and the rejected pre-reset payload may use the exact same row ID.
        for remote in [false, true] {{
            AppSettings.shared.backendMode = remote ? "remote" : "local"
            AppSettings.shared.hiddenSidebarSections = []
            let coord = CoordinatorUnderTest()
            coord.selected = ["codex"]
            var localGate: CheckedContinuation<DashboardSnapshot, Never>?
            var remoteGate: CheckedContinuation<StubDashboardResponse, Error>?
            coord.engine.onFetchAll = {{ _ in await withCheckedContinuation {{ localGate = $0 }} }}
            APIService.shared.onDashboardRequest = {{ _ in try await withCheckedThrowingContinuation {{ remoteGate = $0 }} }}
            let task = Task {{ await coord.fetchDashboard() }}
            while localGate == nil && remoteGate == nil {{ await Task.yield() }}
            let oldToken = coord.codexResetRefreshFence.token
            let postResetRow = makeHealthyCodexRow(windows: claudeLocalPreservable.windows)
            let key = coord.codexResetIdentity(postResetRow)!
            coord.codexResetRefreshFence.invalidate(key)
            coord.providers = [postResetRow]
            coord.engine.onFetchForCredential = {{ _, _ in failedAccount }}
            // Account refresh is local; a remote Dashboard request already in flight can still settle.
            AppSettings.shared.backendMode = "local"
            await coord.refreshAccountNow(credentialId: "A", providerId: "codex")
            precondition(!coord.codexResetRefreshFence.accepts(oldToken, identity: key)
                        && coord.errorMessage == "Codex account A timed out")
            localGate?.resume(returning: healthyCodexSnapshot)
            remoteGate?.resume(returning: StubDashboardResponse(
                providers: [.init(summary: healthyLocalRow, ok: true)], overview: emptyAppOverview
            ))
            let result = await task.value
            precondition(result.refreshedProviders.isEmpty
                        && coord.markedRefreshed.isEmpty
                        && coord.providers.map(\\.id) == ["codex:cred:A"]
                        && coord.providers.first?.windows.count == postResetRow.windows.count
                        && coord.errorMessage == "Codex account A timed out",
                         "[AGY #2] Rejected same-ID pre-reset payload cannot update timestamps or clear the banner")
        }}
        print("PASS: [AGY #2] Local and Remote same-ID fence rejection protects card, timestamps and banner")

        APIService.shared.onProviderResultsRequest = nil
        AppSettings.shared.hiddenSidebarSections = []
    }}
}}
"""
(temp / 'LeanCutAndAntibanP1P2Regression.swift').write_text(harness)
PY

swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/AIUsage/Models/ProviderModels.swift" \
  "$ROOT/AIUsage/ViewModels/ProviderRefreshResult.swift" \
  "$ROOT/AIUsage/ViewModels/CodexResetRefreshFence.swift" \
  "$REGRESSION_DIR/LeanCutAndAntibanP1P2Regression.swift" \
  -o "$REGRESSION_DIR/lean-cut-p1-p2"
"$REGRESSION_DIR/lean-cut-p1-p2"

if [[ "${AIUSAGE_ONLY_LEAN_CUT_3B:-0}" != "1" ]]; then
# 4. [§8.5 + §8.6 + §10.4 + §12.4 + §28] Partial delete snapshot scoping, live TLS QuotaShareServer handshake & macOS 14 gating
python3 - "$ROOT" "$REGRESSION_DIR" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])

def function(src, marker):
    s = src.index(marker); i = src.index('{', s); d = 1; j = i + 1
    while d:
        if src[j] == '{': d += 1
        elif src[j] == '}': d -= 1
        j += 1
    return src[s:j]

app_state = (root / 'AIUsage/Models/AppState.swift').read_text()
delete_fn = function(app_state, '    func deleteAccounts(')

harness = f"""import CryptoKit
import Foundation
import Network
import Security
@testable import QuotaBackend
@testable import QuotaServerCore

// [§8.5] Minimal harness exercising real AppState.deleteAccounts
struct ProviderAccountEntry: Identifiable {{
    let id: String
    let providerId: String
    let credentialId: String
    let email: String?
}}
struct SnapshotPurgeTarget {{ let entryId: String }}
@MainActor final class StubRefreshCoordinator {{
    var purgedEntryIds: [String] = []
    func snapshotPurgeTarget(for entry: ProviderAccountEntry, matchedCredentials: [String]) -> SnapshotPurgeTarget {{
        SnapshotPurgeTarget(entryId: entry.id)
    }}
    func removeLiveProviders(matching _: [ProviderAccountEntry]) {{}}
    func reapplyVisibleSortedProviders() {{}}
    func syncExcludedAccountsToEngine() async {{}}
    func purgePersistedSnapshots(targets: [SnapshotPurgeTarget]) async {{
        purgedEntryIds = targets.map(\\.entryId)
    }}
}}
@MainActor final class StubAccountStore {{
    var failingEntryIds: Set<String> = []
    func matchingCredentials(for _: ProviderAccountEntry) -> [String] {{ [] }}
    func deleteAccounts(_ entries: [ProviderAccountEntry], onPostRegistryDelete: ([ProviderAccountEntry]) -> Void) {{
        onPostRegistryDelete(entries.filter {{ !failingEntryIds.contains($0.id) }})
    }}
}}
enum ClaudeSubscriptionManager {{
    @MainActor static let shared = StubClaude()
    @MainActor final class StubClaude {{ func releaseDeletedAccounts(_ _: [ProviderAccountEntry]) {{}} }}
}}
@MainActor final class StubAppState {{
    let accountStore = StubAccountStore()
    let refreshCoordinator = StubRefreshCoordinator()
    func managedPauseContext(for entries: [ProviderAccountEntry]) -> (credentialIDs: Set<String>, hints: [String]) {{
        (Set(entries.map(\\.credentialId)), [])
    }}
    func reportCPAPauseWarningIfNeeded(_ _: Int) {{}}
{delete_fn}
}}

func runEncryptedTLSClient(port: UInt16, token: String, expectedServerCert: SecCertificate) async throws -> (Int, String) {{
    let tlsOpts = NWProtocolTLS.Options()
    let expectedCertData = SecCertificateCopyData(expectedServerCert) as Data
    sec_protocol_options_set_verify_block(tlsOpts.securityProtocolOptions, {{ _, trust, complete in
        let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
        let peerCert = SecTrustCopyCertificateChain(secTrust) as? [SecCertificate]
        let ok = (peerCert?.first.map {{ SecCertificateCopyData($0) as Data }} == expectedCertData)
        complete(ok)
    }}, DispatchQueue.global())
    let params = NWParameters(tls: tlsOpts, tcp: .init())
    let conn = NWConnection(host: NWEndpoint.Host("127.0.0.1"), port: NWEndpoint.Port(rawValue: port)!, using: params)
    return try await withCheckedThrowingContinuation {{ continuation in
        let queue = DispatchQueue(label: "tls.client")
        final class Once: @unchecked Sendable {{
            private let lock = NSLock()
            private var done = false
            func fire(_ block: () -> Void) {{
                let shouldRun = lock.withLock {{
                    guard !done else {{ return false }}
                    done = true
                    return true
                }}
                if shouldRun {{ block() }}
            }}
        }}
        let once = Once()
        conn.stateUpdateHandler = {{ state in
            switch state {{
            case .ready:
                let req = "GET /api/dashboard HTTP/1.1\\r\\nHost: 127.0.0.1:\\(port)\\r\\nAuthorization: Bearer \\(token)\\r\\n\\r\\n"
                conn.send(content: Data(req.utf8), completion: .contentProcessed {{ _ in
                    conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) {{ data, _, _, err in
                        once.fire {{
                            conn.cancel()
                            if let err {{ continuation.resume(throwing: err); return }}
                            let text = String(data: data ?? Data(), encoding: .utf8) ?? ""
                            let status = text.contains("200 OK") ? 200 : (text.contains("401") ? 401 : 0)
                            continuation.resume(returning: (status, text))
                        }}
                    }}
                }})
            case .failed(let err):
                once.fire {{ conn.cancel(); continuation.resume(throwing: err) }}
            default: break
            }}
        }}
        conn.start(queue: queue)
    }}
}}

@main struct Section8ProductionRegression {{
    @MainActor static func main() async throws {{
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("section8-prod-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer {{ try? FileManager.default.removeItem(at: scratch) }}

        // [§8.5] Partial bulk delete scopes snapshot purge strictly to deletedEntries
        let appState = StubAppState()
        appState.accountStore.failingEntryIds = ["entry-b"]
        let eA = ProviderAccountEntry(id: "entry-a", providerId: "codex", credentialId: "cred-a", email: "a@example.invalid")
        let eB = ProviderAccountEntry(id: "entry-b", providerId: "codex", credentialId: "cred-b", email: "b@example.invalid")
        appState.deleteAccounts([eA, eB])
        try await Task.sleep(for: .milliseconds(50))
        precondition(appState.refreshCoordinator.purgedEntryIds == ["entry-a"],
                     "[§8.5] Partial delete purges persisted snapshot strictly for successfully deleted row(s)")

        // [§8.6 + §10.4 + §12.4] Live TLS QuotaShareServer connection over disposable SecIdentity (macOS 15+ memory-only)
        // and explicit macOS 14 native HTTPS gating without default Keychain import.
        precondition(!TLSCertificateManager.supportsMemoryOnlyTLSIdentityImport(isMacOS15OrLater: false),
                     "[§12.4] TLSCertificateManager reports memory-only TLS import unsupported on simulated macOS 14")
        var macos14MgrThrew = false
        do {{
            try TLSCertificateManager.requireMemoryOnlyTLSRuntimeSupport(isMacOS15OrLater: false)
        }} catch {{
            macos14MgrThrew = true
        }}
        precondition(macos14MgrThrew, "[§12.4] Native local HTTPS runtime support gate rejects simulated macOS 14 before cert/server startup")
        let tlsDir = scratch.appendingPathComponent("tls")
        let tlsMgr = TLSCertificateManager(tlsDirectory: tlsDir, allowSystemTrustInstall: false)
        try await tlsMgr.ensureCertificate()
        let httpTLS = QuotaHTTPServer(host: "127.0.0.1", port: 0)
        var macos14LoaderThrew = false
        do {{
            _ = try httpTLS.loadTLSIdentity(from: tlsMgr.identityFilePath, isMacOS15OrLater: false)
        }} catch {{
            macos14LoaderThrew = true
        }}
        precondition(macos14LoaderThrew, "[§12.4] QuotaHTTPServer.loadTLSIdentity fails closed on simulated macOS 14 before default Keychain import")
        let (secIdentity, certChain) = try httpTLS.loadTLSIdentity(from: tlsMgr.identityFilePath)
        var leafCert: SecCertificate?
        SecIdentityCopyCertificate(secIdentity, &leafCert)
        guard let serverCert = leafCert ?? certChain.first else {{ preconditionFailure("missing server cert from in-memory identity") }}
        let serverTLS = NWProtocolTLS.Options()
        guard let secIdRef = sec_identity_create(secIdentity) else {{ preconditionFailure("sec_identity_create failed") }}
        sec_protocol_options_set_local_identity(serverTLS.securityProtocolOptions, secIdRef)
        let shareServer = QuotaShareServer(port: 0, token: "tls-share-tok", tlsOptions: serverTLS) {{ _ in
            Data(#"{{"providers":[{{"id":"codex"}}]}}"#.utf8)
        }}
        let boundPort: Int = await withCheckedContinuation {{ cont in
            final class PortOnce: @unchecked Sendable {{
                private let lock = NSLock()
                private var resumed = false
                func resumeIfNeeded(_ block: () -> Void) {{
                    let shouldRun = lock.withLock {{
                        guard !resumed else {{ return false }}
                        resumed = true
                        return true
                    }}
                    if shouldRun {{ block() }}
                }}
            }}
            let once = PortOnce()
            shareServer.start {{ state in
                if case .running(let p) = state {{
                    once.resumeIfNeeded {{ cont.resume(returning: p) }}
                }}
            }}
        }}
        defer {{ shareServer.stop() }}
        let (tlsStatus, tlsBody) = try await runEncryptedTLSClient(port: UInt16(boundPort), token: "tls-share-tok", expectedServerCert: serverCert)
        precondition(tlsStatus == 200 && tlsBody.contains(#""codex""#),
                     "[§8.6 + §10.4] In-memory TLS QuotaShareServer serves authenticated /api/dashboard snapshot cleanly without Keychain import")
        let (badTokStatus, _) = try await runEncryptedTLSClient(port: UInt16(boundPort), token: "wrong-tok", expectedServerCert: serverCert)
        precondition(badTokStatus == 401, "[§8.6] Encrypted TLS QuotaShareServer rejects invalid bearer token with 401")
        try await Section8LegacyUpgradeTests.runAll(scratchRoot: scratch)
        print("PASS: [§8.5 + §8.6 + §10.4 + §12.4 + §32.3 + §34] partial delete snapshot scoping, macOS 14 TLS gating, macOS 15+ TLS handshake, active CPA provider store, & chmod-0500 disk resilience")
    }}
}}
"""
(temp / 'Section8ProductionRegression.swift').write_text(harness)

# Build Section8APIProviderStore.swift (real APIProviderStore pointing at scratch home) & Section8LegacyUpgrade.swift
store_src = (root / 'AIUsage/ViewModels/APIProviderStore.swift').read_text()
store_src = store_src.replace('static let shared = APIProviderStore()', 'static var shared: APIProviderStore!')
store_src = store_src.replace('FileManager.default.homeDirectoryForCurrentUser.path', 'Section8LegacyUpgradeEnv.home.path')
(temp / 'Section8APIProviderStore.swift').write_text(store_src)

dist_src = (root / 'AIUsage/ViewModels/APIProviderDistributor.swift').read_text()
opencode_src = (root / 'AIUsage/ViewModels/OpenCodeNodeStore.swift').read_text()
profile_store_src = (root / 'AIUsage/ViewModels/NodeProfileStore.swift').read_text()
adapters_src = (root / 'AIUsage/ViewModels/GlobalProxyTrackAdapters.swift').read_text()

dist_blocks = "\n\n".join([
    function(dist_src, '    func beginContainment('),
    function(dist_src, '    func endContainment('),
    function(dist_src, '    func isContainmentActive('),
    function(dist_src, '    private func isWriteAuthorized('),
    function(dist_src, '    private func withProviderSerialization<T>('),
    function(dist_src, '    func currentTargets('),
    function(dist_src, '    struct DistributionRemovalVerification:'),
    function(dist_src, '    func removeAllDistributionForContainment('),
    function(dist_src, '    private func releaseManagedConsumers('),
    function(dist_src, '    private func removeChild('),
    function(dist_src, '    private func removeProxyChild('),
    function(dist_src, '    private func unlinkChild(').replace('    private func unlinkChild(', '    func unlinkChild(', 1),
    function(dist_src, '    private func codexChild('),
    function(dist_src, '    private func claudeChild('),
    function(dist_src, '    private func openCodeChild('),
    function(dist_src, '    func stampOverrides(_ profile: NodeProfile)'),
    function(dist_src, '    private func trimmed('),
])

codex_section = adapters_src.split('struct CodexGlobalProxyAdapter:', 1)[1]
codex_node_fn = function(codex_section, '    private func node(_ id: String) -> ProxyConfiguration?')
codex_avail_fn = function(codex_section, '    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef]')
claude_section = adapters_src.split('struct ClaudeGlobalProxyAdapter:', 1)[1]
claude_node_fn = function(claude_section, '    private func node(_ id: String) -> ProxyConfiguration?')
claude_avail_fn = function(claude_section, '    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef]')
opencode_section = adapters_src.split('struct OpenCodeGlobalProxyAdapter:', 1)[1]
opencode_node_fn = function(opencode_section, '    private func node(_ id: String) -> OpenCodeNode?')
opencode_avail_fn = function(opencode_section, '    func availableNodes(config: GlobalProxyConfig) -> [GlobalProxyNodeRef]')

profile_store_blocks = "\n\n".join([
    function(profile_store_src, '    private func ensureDirectoryExists('),
    function(profile_store_src, '    func loadAll('),
    function(profile_store_src, '    @discardableResult\n    func save(_ profile: NodeProfile)'),
    function(profile_store_src, '    @discardableResult\n    func delete(_ id: String)'),
    function(profile_store_src, '    func profile(for id: String)'),
    function(profile_store_src, '    private func filePath(for id: String)'),
])

oc_error_enum = function(opencode_src, 'enum OpenCodeNodeStoreError: LocalizedError')
oc_blocks = "\n\n".join([
    function(opencode_src, '    func delete(_ node: OpenCodeNode)'),
    function(opencode_src, '    func upsert(_ node: OpenCodeNode)'),
    function(opencode_src, '    private func reapplyIfRunning('),
    function(opencode_src, '    func activate(_ node: OpenCodeNode)'),
    function(opencode_src, '    func activate(_ nodes: [OpenCodeNode])'),
    function(opencode_src, '    func deactivate(_ node: OpenCodeNode)'),
    function(opencode_src, '    func deactivate(_ ids: [String])'),
    function(opencode_src, '    private func rewriteManagedConfig('),
    function(opencode_src, '    func startProxyOnly(_ node: OpenCodeNode)'),
    function(opencode_src, '    func stopProxyOnly(_ node: OpenCodeNode)'),
    function(opencode_src, '    private func load()'),
    function(opencode_src, '    @discardableResult\n    func save()'),
    function(opencode_src, '    private func save(nodes: [OpenCodeNode])'),
])

legacy_upgrade_swift = f"""import Foundation
import os.log
import QuotaBackend

private let storeLog = Logger(subsystem: "com.aiusage.section8", category: "NodeProfileStore")
private let openCodeStoreLog = Logger(subsystem: "com.aiusage.section8", category: "OpenCodeNodeStore")

enum Section8LegacyUpgradeEnv {{
    nonisolated(unsafe) static var home: URL = FileManager.default.temporaryDirectory
}}

final class AppSettings {{
    static let shared = AppSettings()
    var proxyAutoRestoreOnLaunch = true
    func t(_ en: String, _ zh: String) -> String {{ en }}
}}

extension JSONEncoder {{
    static let profileEncoder: JSONEncoder = {{
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }}()
}}
extension JSONDecoder {{ static let profileDecoder = JSONDecoder() }}
extension String {{
    var nilIfBlank: String? {{
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }}
}}

enum OpenCodeProtocol: String, Codable, Equatable {{
    case openAICompatible = "openai-compatible"
    case anthropic = "anthropic"
    case openAIResponses = "openai-responses"
}}

enum OpenAIUpstreamAPI: String, Codable, Equatable {{
    case chatCompletions = "chat-completions"
    case responses = "responses"
}}

enum NodeType: String, Codable, Equatable {{
    case openaiProxy
    case anthropicDirect
    case codexProxy
    var isCodex: Bool {{ self == .codexProxy }}
}}

enum ProxyNodeFamily {{
    static let claude: Set<NodeType> = [.anthropicDirect, .openaiProxy]
}}

struct ProxyConfiguration: Identifiable, Equatable {{
    struct MappedModel: Codable, Equatable {{
        var name: String
        init(name: String) {{ self.name = name }}
    }}
    struct ModelCatalog: Codable, Equatable {{
        var models: [String]
        init(mappedModels: [MappedModel]) {{ self.models = mappedModels.map(\\.name) }}
    }}
    var id: String
    var name: String
    var nodeType: NodeType
}}

struct ProxySettings: Codable, Equatable {{
    var upstreamBaseURL: String = ""
    var upstreamAPIKey: String = ""
    var anthropicBaseURL: String = ""
    var anthropicAPIKey: String = ""
    var modelCatalog: ProxyConfiguration.ModelCatalog = .init(mappedModels: [])
    var defaultModel: String = ""
    var extraTOML: String? = nil
}}

struct NodeProfile: Identifiable, Codable, Equatable {{
    struct Metadata: Codable, Equatable {{
        var id: String
        var name: String
        var nodeType: NodeType
        var proxy: ProxySettings
        var linkedProviderId: String?
        var overriddenKeys: Set<String>?
        var createdAt: Date = Date()
        var sortOrder: Int = Int.max
    }}
    var metadata: Metadata
    var settings: [String: String] = [:]
    var id: String {{ metadata.id }}
    func toFileData() throws -> Data {{ try JSONEncoder.profileEncoder.encode(self) }}
    static func fromFileData(_ data: Data) throws -> NodeProfile {{
        try JSONDecoder.profileDecoder.decode(NodeProfile.self, from: data)
    }}
}}

struct OpenCodeNode: Identifiable, Codable, Equatable {{
    var id: String
    var name: String
    var baseURL: String
    var apiKey: String
    var proxyEnabled: Bool
    var protocolType: OpenCodeProtocol = .openAIResponses
    var isComplete: Bool {{ !baseURL.isEmpty }}
    var linkedProviderId: String?
    var overriddenKeys: Set<String>?
    var lastUsedAt: Date? = nil
    var sortOrder: Int = Int.max
    var displayName: String {{ name.isEmpty ? id : name }}
}}

@MainActor
final class NodeProfileStore {{
    static var shared = NodeProfileStore()
    static var profilesDirectory: String {{
        (Section8LegacyUpgradeEnv.home.path as NSString).appendingPathComponent(".config/aiusage/profiles")
    }}
    private let fileManager = FileManager.default
    var profiles: [NodeProfile] = []
    var activatedProfileId: String?
    var lastIOError: String?
    init() {{ loadAll() }}
    func saveActivatedId() {{}}

{profile_store_blocks}
}}

enum GlobalProxyTrack: String {{ case codex, claude, desktop, opencode, science }}

struct GlobalProxyNodeRef: Identifiable, Equatable {{
    let id: String
    let name: String
}}

struct GlobalProxyConfig {{
    var effectiveClaudeCodeEnabled = false
    var isEnabled = false
    var activeNodeId: String? = nil
    var openCodeInterface: OpenCodeProtocol = .openAIResponses
    var effectiveOpenCodeInterface: OpenCodeProtocol {{ openCodeInterface }}
}}

@MainActor
struct CodexGlobalProxyAdapter {{
{codex_node_fn}
{codex_avail_fn}
}}

@MainActor
struct ClaudeGlobalProxyAdapter {{
    let track: GlobalProxyTrack
    init(track: GlobalProxyTrack = .claude) {{ self.track = track }}
{claude_node_fn}
{claude_avail_fn}
}}

@MainActor
struct OpenCodeGlobalProxyAdapter {{
{opencode_node_fn}
{opencode_avail_fn}
}}

@MainActor
final class GlobalProxyManager {{
    typealias Config = GlobalProxyConfig
    static var codex = GlobalProxyManager(track: .codex)
    static var claude = GlobalProxyManager(track: .claude)
    static var desktop = GlobalProxyManager(track: .desktop)
    static var opencode = GlobalProxyManager(track: .opencode)
    let track: GlobalProxyTrack
    var isRuntimeEnabled = false
    var config = Config()
    var isEnabled: Bool {{
        get {{ track == .claude ? config.effectiveClaudeCodeEnabled : config.isEnabled }}
        set {{
            if track == .claude {{ config.effectiveClaudeCodeEnabled = newValue }}
            else {{ config.isEnabled = newValue }}
        }}
    }}
    var activeNodeId: String? {{
        get {{ config.activeNodeId }}
        set {{ config.activeNodeId = newValue }}
    }}
    var operationError: String?
    var disableShouldFail = false
    var startedRuntimeCount = 0
    init(track: GlobalProxyTrack) {{ self.track = track }}
    func availableNodes() -> [GlobalProxyNodeRef] {{
        switch track {{
        case .codex: return CodexGlobalProxyAdapter().availableNodes(config: config)
        case .claude, .desktop, .science: return ClaudeGlobalProxyAdapter(track: track).availableNodes(config: config)
        case .opencode: return OpenCodeGlobalProxyAdapter().availableNodes(config: config)
        }}
    }}
    func node(for id: String?) -> GlobalProxyNodeRef? {{
        guard let id else {{ return nil }}
        return availableNodes().first {{ $0.id == id }}
    }}
    func disable() async {{
        if disableShouldFail {{
            operationError = "simulated consumer disable failure"
            return
        }}
        isRuntimeEnabled = false
        isEnabled = false
        config.isEnabled = false
        config.effectiveClaudeCodeEnabled = false
        activeNodeId = nil
    }}
}}

@MainActor
final class ClaudeDesktopIntegrationManager {{
    enum IntegrationState {{ case disconnected, conflict(String), failed(String) }}
    static var shared = ClaudeDesktopIntegrationManager()
    var state: IntegrationState = .disconnected
    func disconnect(quitDesktop: Bool) async {{
        GlobalProxyManager.desktop.isEnabled = false
        GlobalProxyManager.desktop.activeNodeId = nil
        state = .disconnected
    }}
}}

@MainActor
final class ScienceProxyManager {{
    static var shared = ScienceProxyManager()
    var config = GlobalProxyConfig()
    var isEnabled: Bool {{
        get {{ config.isEnabled }}
        set {{ config.isEnabled = newValue }}
    }}
    var activeNodeId: String? {{
        get {{ config.activeNodeId }}
        set {{ config.activeNodeId = newValue }}
    }}
    var operationError: String?
    func stop() async {{
        isEnabled = false
        activeNodeId = nil
    }}
}}

@MainActor
final class OpenCodeProxyRuntime {{
    static var shared = OpenCodeProxyRuntime()
    var startedNodeIds: [String] = []
    var stoppedNodeIds: [String] = []
    func start(node: OpenCodeNode) async throws {{ startedNodeIds.append(node.id) }}
    func stop(nodeId: String) {{ stoppedNodeIds.append(nodeId) }}
    func purgeNode(_ _: String) {{}}
}}

@MainActor
final class OpenCodeConfigManager {{
    static let shared = OpenCodeConfigManager()
    var activateWriteCount = 0
    var restoreCount = 0
    var simulateRestoreError: Error?
    func activate(nodes: [OpenCodeNode], defaultNodeId: String, commonSettings: (OpenCodeNode) -> [String: Any]?) throws {{
        activateWriteCount += 1
    }}
    func restore() throws {{
        if let simulateRestoreError {{ throw simulateRestoreError }}
        restoreCount += 1
    }}
}}

{oc_error_enum}

@MainActor
final class OpenCodeNodeStore {{
    static var shared = OpenCodeNodeStore()
    static var storePath: String {{
        (Section8LegacyUpgradeEnv.home.path as NSString).appendingPathComponent(".config/aiusage/opencode-nodes.json")
    }}
    private static let storeVersion = 1
    private struct StoreFile: Codable {{
        var version: Int
        var nodes: [OpenCodeNode]
        var activeNodeId: String?
        var activeNodeIds: [String]?
        var proxyOnlyNodeIds: [String]?
        var openCodeDefaultNodeId: String?
    }}
    private let fileManager = FileManager.default
    var nodes: [OpenCodeNode] = []
    var activeNodeIds: [String] = []
    var proxyOnlyNodeIds: Set<String> = []
    var openCodeDefaultNodeId: String?
    var lastSaveError: String?
    struct ObjectWillChangeStub {{ func send() {{}} }}
    let objectWillChange = ObjectWillChangeStub()

    init() {{ load() }}

    private var configManager: OpenCodeConfigManager {{ OpenCodeConfigManager.shared }}
    private var proxyRuntime: OpenCodeProxyRuntime {{ OpenCodeProxyRuntime.shared }}
    func commonSettings(for node: OpenCodeNode) -> [String: Any]? {{ nil }}
    private func sortNodes() {{}}
    private func ensureProviderSlug(_ node: inout OpenCodeNode) {{}}
    private func backfillProviderSlugs() {{}}
    var activeNodes: [OpenCodeNode] {{
        activeNodeIds.compactMap {{ id in nodes.first {{ $0.id == id }} }}
    }}

{oc_blocks}
}}

enum NodeRuntimeConsumer {{ case manual }}

@MainActor
final class ProxyViewModel {{
    static var shared = ProxyViewModel()
    var configurations: [ProxyConfiguration] = []
    var activatedIds: Set<String> = []
    var proxyOnlyRunningIds: Set<String> = []
    var startedRuntimeIds: [String] = []
    var operationErrorMessage: String?
    var blockedDeletionErrors: [String: String] = [:]

    func isNodeActivated(_ id: String) -> Bool {{ activatedIds.contains(id) }}
    func isNodeRuntimeRunning(_ id: String) -> Bool {{ proxyOnlyRunningIds.contains(id) }}
    func managedRuntimeDeletionBlockReason(for id: String) -> String? {{ blockedDeletionErrors[id] }}
    func loadConfigurations() {{
        configurations = NodeProfileStore.shared.profiles.map {{
            ProxyConfiguration(id: $0.id, name: $0.metadata.name, nodeType: $0.metadata.nodeType)
        }}
    }}
    func deactivateConfiguration(_ id: String) async {{
        if let block = blockedDeletionErrors[id] {{ operationErrorMessage = block; return }}
        activatedIds.remove(id)
    }}
    func stopProxyOnly(_ id: String) async {{ proxyOnlyRunningIds.remove(id) }}
    func deleteConfiguration(_ id: String) async {{
        if let reason = managedRuntimeDeletionBlockReason(for: id) {{
            operationErrorMessage = reason
            return
        }}
        activatedIds.remove(id)
        proxyOnlyRunningIds.remove(id)
        guard NodeProfileStore.shared.delete(id) else {{
            operationErrorMessage = NodeProfileStore.shared.lastIOError
                ?? "Failed to delete node profile from disk."
            return
        }}
        configurations.removeAll {{ $0.id == id }}
    }}
}}

@MainActor
final class CLIProxyRuntimeController {{
    struct Settings {{
        struct Normalized {{ var port: Int = 8317 }}
        var normalized = Normalized()
    }}
    static let shared = CLIProxyRuntimeController()
    var settings = Settings()
}}

@MainActor
final class CLIProxyGatewayManager {{
    static let managedProviderID = "aiusage.cliproxyapi.gateway"
    static let shared = CLIProxyGatewayManager()
    func pauseManagedAuthFiles(forCredentialIDs _: Set<String>, accountHints _: [String]) async -> Int {{ 0 }}
}}

@MainActor
final class StubGatewayManager {{
    static let shared = StubGatewayManager()
    var lastError: String?
    func deleteOpenAICompatibleProviderLinked(cpaName _: String) async throws {{}}
}}

@MainActor
final class StubCPALinkStore {{
    static let shared = StubCPALinkStore()
    var removedProviderIDs: [String] = []
    func cpaName(for _: String) -> String? {{ nil }}
    func hasLink(for _: String) -> Bool {{ false }}
    func removeLink(providerId: String) {{ removedProviderIDs.append(providerId) }}
}}

@MainActor
final class APIProviderDistributor {{
    static var shared = APIProviderDistributor()
    private var proxyVM: ProxyViewModel {{ ProxyViewModel.shared }}
    private var profileStore: NodeProfileStore {{ NodeProfileStore.shared }}
    private var openCodeStore: OpenCodeNodeStore {{ OpenCodeNodeStore.shared }}
    private var gateway: StubGatewayManager {{ StubGatewayManager.shared }}
    private var cpaLinks: StubCPALinkStore {{ StubCPALinkStore.shared }}
    var lastError: String?
    private var lockedProviderIds: Set<String> = []
    private var providerWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var containmentFencedProviderIds: Set<String> = []
    private var providerWriteGeneration: [String: UInt64] = [:]

{dist_blocks}
}}

enum Section8LegacyUpgradeTests {{
    @MainActor static func resetAllStores(home: URL) {{
        Section8LegacyUpgradeEnv.home = home
        APIProviderStore.shared = APIProviderStore()
        APIProviderDistributor.shared = APIProviderDistributor()
        NodeProfileStore.shared = NodeProfileStore()
        OpenCodeNodeStore.shared = OpenCodeNodeStore()
        ProxyViewModel.shared = ProxyViewModel()
        OpenCodeProxyRuntime.shared = OpenCodeProxyRuntime()
        GlobalProxyManager.codex = GlobalProxyManager(track: .codex)
        GlobalProxyManager.claude = GlobalProxyManager(track: .claude)
        GlobalProxyManager.desktop = GlobalProxyManager(track: .desktop)
        GlobalProxyManager.opencode = GlobalProxyManager(track: .opencode)
        ClaudeDesktopIntegrationManager.shared = ClaudeDesktopIntegrationManager()
        ScienceProxyManager.shared = ScienceProxyManager()
        StubGatewayManager.shared.lastError = nil
        StubCPALinkStore.shared.removedProviderIDs = []
    }}

    @MainActor static func writeProviderStore(home: URL) throws {{
        let dir = home.appendingPathComponent(".config/aiusage", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = \"\"\"
        {{
          "version": 1,
          "providers": [
            {{
              "id": "aiusage.cliproxyapi.gateway",
              "name": "CPA Gateway",
              "baseURL": "http://127.0.0.1:8317/v1",
              "apiKey": "cpa-key",
              "format": "openai-responses",
              "models": [{{"name": "gpt-5"}}]
            }},
            {{
              "id": "legit",
              "name": "Keep Me",
              "baseURL": "https://api.example.invalid/v1",
              "apiKey": "user-key",
              "format": "openai-responses",
              "models": [{{"name": "gpt-5"}}]
            }}
          ]
        }}
        \"\"\"
        try Data(json.utf8).write(to: dir.appendingPathComponent("api-providers.json"), options: .atomic)
    }}

    @MainActor static func runAll(scratchRoot: URL) async throws {{
        let homeA = scratchRoot.appendingPathComponent("active-cpa-a", isDirectory: true)
        try writeProviderStore(home: homeA)
        resetAllStores(home: homeA)
        let cpaMaster = APIProviderStore.shared.provider(id: "aiusage.cliproxyapi.gateway")
        precondition(cpaMaster?.isComplete == true
                        && cpaMaster?.compatibleTargets.count == 4
                        && (cpaMaster.flatMap {{ APIProviderCPALoopGuard.blockReason(for: $0) }} != nil)
                        && APIProviderStore.shared.provider(id: "legit")?.isComplete == true
                        && APIProviderStore.shared.provider(id: "legit")?.compatibleTargets.count == 4,
                     "[§34] APIProviderStore preserves active aiusage.cliproxyapi.gateway master and unrelated providers")

        let repProfile = NodeProfile(metadata: .init(
            id: "codex-repurposed",
            name: "Repurposed Codex",
            nodeType: .codexProxy,
            proxy: .init(upstreamBaseURL: "https://api.custom.invalid/v1", upstreamAPIKey: "user-key", extraTOML: "keep = true"),
            linkedProviderId: "aiusage.cliproxyapi.gateway",
            overriddenKeys: nil
        ))
        precondition(NodeProfileStore.shared.save(repProfile), "seed repurposed profile")
        let afterStamp = APIProviderDistributor.shared.stampOverrides(repProfile)
        precondition(afterStamp.metadata.overriddenKeys?.contains(APIProviderSharedKey.baseURL) == true
                        && afterStamp.metadata.proxy.extraTOML == "keep = true",
                     "[§34] stampOverrides marks baseURL override when upstreamBaseURL is repurposed while keeping extraTOML")

        // [§32.3] Real filesystem write/delete failure (chmod 0500) retains retryable memory/disk state and surfaces errors
        let homeFS = scratchRoot.appendingPathComponent("fs-fail", isDirectory: true)
        try writeProviderStore(home: homeFS)
        resetAllStores(home: homeFS)
        precondition(NodeProfileStore.shared.save(NodeProfile(metadata: .init(
            id: "codex-ro",
            name: "Readonly Codex Profile",
            nodeType: .codexProxy,
            proxy: .init(upstreamBaseURL: "http://127.0.0.1:8317", upstreamAPIKey: "cpa-key", extraTOML: "keep-on-ro"),
            linkedProviderId: "aiusage.cliproxyapi.gateway",
            overriddenKeys: nil
        ))), "seed codex-ro")
        let ocRO = OpenCodeNode(
            id: "oc-ro",
            name: "Readonly OpenCode Node",
            baseURL: "https://api.custom.invalid/v1",
            apiKey: "k",
            proxyEnabled: false,
            linkedProviderId: "aiusage.cliproxyapi.gateway",
            overriddenKeys: [APIProviderSharedKey.baseURL]
        )
        OpenCodeNodeStore.shared.nodes = [ocRO]
        precondition(OpenCodeNodeStore.shared.save(), "seed oc-ro")
        ProxyViewModel.shared.loadConfigurations()

        let profilesDirURL = URL(fileURLWithPath: NodeProfileStore.profilesDirectory)
        let configDirURL = URL(fileURLWithPath: OpenCodeNodeStore.storePath).deletingLastPathComponent()
        let codexROFileURL = profilesDirURL.appendingPathComponent("codex-ro.json")
        let ocROFileURL = URL(fileURLWithPath: OpenCodeNodeStore.storePath)
        let codexROBytesBefore = try Data(contentsOf: codexROFileURL)
        let ocROBytesBefore = try Data(contentsOf: ocROFileURL)

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: profilesDirURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: configDirURL.path)
        defer {{
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDirURL.path)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profilesDirURL.path)
        }}

        await ProxyViewModel.shared.deleteConfiguration("codex-ro")
        let codexROBytesAfter = try Data(contentsOf: codexROFileURL)
        precondition(NodeProfileStore.shared.profile(for: "codex-ro") != nil
                        && ProxyViewModel.shared.configurations.contains(where: {{ $0.id == "codex-ro" }})
                        && ProxyViewModel.shared.operationErrorMessage != nil
                        && codexROBytesAfter == codexROBytesBefore,
                     "[§32.3] Failed profile file delete retains in-memory profile, configurations entry, disk bytes, and surfaces error")

        APIProviderDistributor.shared.unlinkChild(for: "aiusage.cliproxyapi.gateway", target: .codex)
        let codexROBytesAfterUnlink = try Data(contentsOf: codexROFileURL)
        precondition(NodeProfileStore.shared.profile(for: "codex-ro")?.metadata.linkedProviderId == "aiusage.cliproxyapi.gateway"
                        && StubGatewayManager.shared.lastError != nil
                        && codexROBytesAfterUnlink == codexROBytesBefore,
                     "[§32.3] Failed profile save during unlinkChild preserves persisted state and reports error")

        var ocDeleteThrew = false
        do {{
            try OpenCodeNodeStore.shared.delete(ocRO)
        }} catch {{
            ocDeleteThrew = true
        }}
        let ocROBytesAfter = try Data(contentsOf: ocROFileURL)
        precondition(ocDeleteThrew
                        && OpenCodeNodeStore.shared.nodes.contains(where: {{ $0.id == "oc-ro" }})
                        && OpenCodeNodeStore.shared.lastSaveError != nil
                        && ocROBytesAfter == ocROBytesBefore,
                     "[§32.3] Failed OpenCode delete retains in-memory node, disk bytes, and surfaces save error")

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: configDirURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: profilesDirURL.path)
        let reloadedProfiles = NodeProfileStore()
        let reloadedOC = OpenCodeNodeStore()
        precondition(reloadedProfiles.profile(for: "codex-ro")?.metadata.proxy.extraTOML == "keep-on-ro"
                        && reloadedOC.nodes.first(where: {{ $0.id == "oc-ro" }})?.linkedProviderId == "aiusage.cliproxyapi.gateway",
                     "[§32.3] Fresh store reload after failed write/delete still sees retryable persisted state")
        NodeProfileStore.shared = reloadedProfiles
        OpenCodeNodeStore.shared = reloadedOC
        ProxyViewModel.shared.loadConfigurations()
        await ProxyViewModel.shared.deleteConfiguration("codex-ro")
        try OpenCodeNodeStore.shared.delete(ocRO)
        precondition(NodeProfileStore.shared.profile(for: "codex-ro") == nil
                        && !FileManager.default.fileExists(atPath: codexROFileURL.path)
                        && !OpenCodeNodeStore.shared.nodes.contains(where: {{ $0.id == "oc-ro" }}),
                     "[§32.3] Explicit retry after restoring directory permissions deletes profile/node cleanly on disk and in memory")
    }}
}}
"""
(temp / 'Section8LegacyUpgrade.swift').write_text(legacy_upgrade_swift)
PY

swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/AIUsage/Services/TLSCertificateManager.swift" \
  "$ROOT/AIUsage/Models/APIProvider.swift" \
  "$REGRESSION_DIR/Section8APIProviderStore.swift" \
  "$REGRESSION_DIR/Section8LegacyUpgrade.swift" \
  "$REGRESSION_DIR/Section8ProductionRegression.swift" \
  -o "$REGRESSION_DIR/section8-prod"
"$REGRESSION_DIR/section8-prod"

# 5. [§34.1 + §28.1] Compiled CLIProxyAuthImportInspector, CLIProxyRuntimeController & CLIProxyBinaryStore regression
cat > "$REGRESSION_DIR/CPAGatewayRuntimeRegression.swift" <<'SWIFT'
import CryptoKit
import Darwin
import Foundation
import QuotaBackend

func L(_ en: String, _ zh: String) -> String { en }

nonisolated struct CLIProxySecretStore: Sendable {
    let secrets = CLIProxySecrets(managementKey: "test-mgmt-key", clientAPIKey: "test-client-key")
    func loadOrCreate() throws -> CLIProxySecrets { secrets }
    func load() -> CLIProxySecrets? { secrets }
    func delete() throws {}
}

nonisolated struct CLIProxyClientKeyStore {
    let secretStore: CLIProxySecretStore
    func loadEntries() throws -> [CLIProxyClientKeyEntry] { [] }
    func enabledKeysForRuntime() throws -> [String] { [secretStore.secrets.clientAPIKey] }
}

private func reserveLoopbackPort() throws -> Int {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    precondition(descriptor >= 0, "socket creation failed")
    defer { Darwin.close(descriptor) }
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    precondition(bound == 0, "bind failed")
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    let gotName = withUnsafeMutablePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.getsockname(descriptor, $0, &len)
        }
    }
    precondition(gotName == 0, "getsockname failed")
    return Int(UInt16(bigEndian: addr.sin_port))
}

@MainActor
enum ProxyPortArbiter {
    struct Owner {
        let id: String
        let ports: [Int]
        let track: String
        let label: String
    }
    struct Conflict {
        let port: Int
        let track: String
        let label: String
    }
    static func conflict(forPorts _: [Int], excluding _: String) -> Conflict? { nil }
}

@MainActor
final class AccountStore {
    static let shared = AccountStore()
    struct ExcludedFilters {
        let credentialIDs: Set<String> = []
    }
    func excludedEngineAccountFilters() -> ExcludedFilters { ExcludedFilters() }
}

private let testIssuerPrivateKey = P256.Signing.PrivateKey()
private let testIssuerKey = CLIProxyTrustedJWSKey(
    keyID: "codex-post-r6-k1",
    issuer: "https://auth.openai.com",
    allowedAudiences: ["https://api.openai.com/v1"],
    publicKeyData: testIssuerPrivateKey.publicKey.x963Representation
)

private func signedES256JWT(
    _ rawClaims: [String: Any],
    key: P256.Signing.PrivateKey = testIssuerPrivateKey,
    kid: String? = "codex-post-r6-k1",
    includeExp: Bool = true
) throws -> String {
    func b64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    var claims = rawClaims
    if claims["iss"] == nil { claims["iss"] = "https://auth.openai.com" }
    if claims["aud"] == nil { claims["aud"] = "https://api.openai.com/v1" }
    if claims["iat"] == nil { claims["iat"] = 1_700_000_000 }
    if includeExp && claims["exp"] == nil { claims["exp"] = 4_102_444_800 }
    var headerDict: [String: Any] = ["alg": "ES256", "typ": "JWT"]
    if let kid { headerDict["kid"] = kid }
    let header = try JSONSerialization.data(withJSONObject: headerDict, options: [.sortedKeys])
    let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let signingInput = "\(b64url(header)).\(b64url(payload))"
    let sig = try key.signature(for: Data(signingInput.utf8))
    return "\(signingInput).\(b64url(sig.rawRepresentation))"
}

private func makeCodexAuthPayload(
    email: String,
    plan: String?,
    credentialID: String? = nil,
    nestedTokens: Bool = false,
    includeExp: Bool = true,
    signingKey: P256.Signing.PrivateKey = testIssuerPrivateKey,
    stampVerificationMarkers: Bool = false
) throws -> Data {
    var authClaims: [String: Any] = ["chatgpt_account_id": "acct-\(email)", "chatgpt_user_id": "user-\(email)"]
    if let plan { authClaims["chatgpt_plan_type"] = plan }
    let claims: [String: Any] = ["sub": "user-\(email)", "email": email, "https://api.openai.com/auth": authClaims]
    let jwt = try signedES256JWT(claims, key: signingKey, includeExp: includeExp)
    var accessClaims = claims
    accessClaims["jti"] = "acc-\(email)"
    let accessJWT = try signedES256JWT(accessClaims, key: signingKey, includeExp: includeExp)
    var obj: [String: Any] = [
        "type": "codex",
        "email": email,
        "disabled": false
    ]
    if nestedTokens {
        obj["tokens"] = [
            "access_token": accessJWT,
            "refresh_token": "ref-\(email)",
            "id_token": jwt,
            "account_id": "acct-\(email)"
        ]
    } else {
        obj["access_token"] = accessJWT
        obj["refresh_token"] = "ref-\(email)"
        obj["id_token"] = jwt
        obj["account_id"] = "acct-\(email)"
    }
    if let credentialID {
        obj["aiusage_credential_id"] = credentialID
    }
    if stampVerificationMarkers {
        obj["aiusage_verified_account_id"] = "acct-\(email)"
        obj["aiusage_verified_user_id"] = "user-\(email)"
        obj["aiusage_verified_access_token_sha256"] = CLIProxyCapabilityMatrix.sha256Hex(accessJWT)
    }
    return try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
}

@main
struct CPAGatewayRuntimeRegression {
    @MainActor
    static func main() async throws {
        if CommandLine.arguments.count >= 5,
           CommandLine.arguments[1] == "--verify-isolated-binary" {
            let rootURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let port = Int(CommandLine.arguments[3])!
            let readyFile = URL(fileURLWithPath: CommandLine.arguments[4])
            let stopFile = URL(fileURLWithPath: CommandLine.arguments[5])
            let binPaths = try CLIProxyPaths(root: rootURL)
            let binaryStore = CLIProxyBinaryStore(paths: binPaths)
            let controller = try CLIProxyRuntimeController(paths: binPaths, binaryStore: binaryStore)
            controller.settings.port = port
            controller.allowIsolatedFixtureLaunch = true
            await controller.start()
            precondition(controller.state.isRunning, "[§39.1] Isolated real CPA binary failed to start: \(controller.state) logs=\(controller.recentLogs)")
            let runningPID: Int32 = {
                if case .running(let pid) = controller.state { return pid }
                return 0
            }()
            let readyPayload: [String: Any] = [
                "port": port,
                "pid": runningPID,
                "managementKey": CLIProxySecretStore().secrets.managementKey,
                "clientAPIKey": CLIProxySecretStore().secrets.clientAPIKey
            ]
            try JSONSerialization.data(withJSONObject: readyPayload).write(to: readyFile, options: .atomic)
            while !FileManager.default.fileExists(atPath: stopFile.path) {
                try await Task.sleep(for: .milliseconds(50))
            }
            let stopped = await controller.stop()
            precondition(stopped && !controller.state.isRunning, "[§39.1] Isolated real CPA binary did not stop cleanly")
            return
        }

        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("cpa-runtime-reg-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // 5A. CLIProxyAuthImportInspector enforces Codex Go/Free-only + [§37.1] trusted-key & expiry + [§39.2] retry override gate
        let goRaw = try makeCodexAuthPayload(email: "go@example.com", plan: "go", nestedTokens: true)
        let freeFlat = try makeCodexAuthPayload(email: "free@example.com", plan: "ChatGPT Free", nestedTokens: false)

        // Default production mode (immutable empty defaultTrustedCodexIssuerKeys) must fail closed even on well-formed ES256 Go/Free payloads
        precondition(CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys.isEmpty && !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
                     "[§39.3] Production default issuer trust must remain empty and subscriptions disabled")
        if case .success = CLIProxyAuthImportInspector.inspect(fileName: "go.json", data: goRaw, enabledPluginProviderIDs: ["codex"]) {
            preconditionFailure("[§37.1] Import inspector must fail closed when defaultTrustedCodexIssuerKeys is empty")
        }

        for (name, data) in [("go.json", goRaw), ("free.json", freeFlat)] {
            let res = CLIProxyAuthImportInspector.inspect(
                fileName: name,
                data: data,
                enabledPluginProviderIDs: ["codex", "claude", "gemini-cli"],
                trustedCodexIssuerKeys: [testIssuerKey]
            )
            guard case .success = res else {
                preconditionFailure("[§34.1] Expected import inspector to accept Codex \(name): \(res)")
            }
        }

        var goRetryOverride = try JSONSerialization.jsonObject(with: goRaw) as! [String: Any]
        goRetryOverride["request_retry"] = 2
        let goRetryOverrideData = try JSONSerialization.data(withJSONObject: goRetryOverride)
        guard case .failure(.disallowedRetryOverride) = CLIProxyAuthImportInspector.inspect(
            fileName: "retry-override.json",
            data: goRetryOverrideData,
            enabledPluginProviderIDs: ["codex"],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) else {
            preconditionFailure("[§39.2] Import inspector must reject per-credential request_retry > 0 override")
        }

        var goDisableCooling = try JSONSerialization.jsonObject(with: goRaw) as! [String: Any]
        goDisableCooling["metadata"] = ["disable-cooling": true]
        let goDisableCoolingData = try JSONSerialization.data(withJSONObject: goDisableCooling)
        guard case .failure(.disallowedRetryOverride) = CLIProxyAuthImportInspector.inspect(
            fileName: "cooling-override.json",
            data: goDisableCoolingData,
            enabledPluginProviderIDs: ["codex"],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) else {
            preconditionFailure("[§39.2] Import inspector must reject per-credential disable-cooling override")
        }

        let untrustedSignerPayload = try! makeCodexAuthPayload(
            email: "untrusted@example.com",
            plan: "go",
            signingKey: P256.Signing.PrivateKey()
        )
        guard case .failure(.disallowedCodexPlan) = CLIProxyAuthImportInspector.inspect(
            fileName: "untrusted.json",
            data: untrustedSignerPayload,
            enabledPluginProviderIDs: ["codex"],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) else {
            preconditionFailure("[§37.1] Import inspector must reject valid-format ES256 token from untrusted signer")
        }

        let missingExpPayload = try! makeCodexAuthPayload(
            email: "noexp@example.com",
            plan: "go",
            includeExp: false
        )
        guard case .failure(.disallowedCodexPlan) = CLIProxyAuthImportInspector.inspect(
            fileName: "noexp.json",
            data: missingExpPayload,
            enabledPluginProviderIDs: ["codex"],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) else {
            preconditionFailure("[§37.1] Import inspector must reject token missing exp")
        }

        for blockedPlan in ["plus", "pro", "team", "business", "enterprise", "edu", nil] {
            let payload = try! makeCodexAuthPayload(email: "blocked@example.com", plan: blockedPlan)
            let res = CLIProxyAuthImportInspector.inspect(
                fileName: "blocked.json",
                data: payload,
                enabledPluginProviderIDs: ["codex"],
                trustedCodexIssuerKeys: [testIssuerKey]
            )
            guard case .failure(.disallowedCodexPlan) = res else {
                preconditionFailure("[§34.1] Import inspector must fail closed on Codex plan=\(blockedPlan ?? "nil"): \(res)")
            }
        }

        let plusJWT = try! signedES256JWT(["sub": "u", "https://api.openai.com/auth": ["chatgpt_account_id": "a", "chatgpt_user_id": "u", "chatgpt_plan_type": "plus"]])
        let conflictingCodex = Data(#"""
        {"type":"codex","plan_type":"go","id_token":"\#(plusJWT)","access_token":"\#(plusJWT)","refresh_token":"ref"}
        """#.utf8)
        let conflictRes = CLIProxyAuthImportInspector.inspect(
            fileName: "conflict.json",
            data: conflictingCodex,
            enabledPluginProviderIDs: [],
            trustedCodexIssuerKeys: [testIssuerKey]
        )
        guard case .failure(.disallowedCodexPlan) = conflictRes else {
            preconditionFailure("[§34.1] Import inspector must reject conflicting Codex plan claims")
        }

        for nonCodex in ["antigravity", "claude", "anthropic", "kimi", "xai", "gemini", "gemini-cli"] {
            let nonCodexData = Data(#"{"type":"\#(nonCodex)","access_token":"a","refresh_token":"r"}"#.utf8)
            let res = CLIProxyAuthImportInspector.inspect(
                fileName: "\(nonCodex).json",
                data: nonCodexData,
                enabledPluginProviderIDs: ["claude", "gemini", "gemini-cli"],
                trustedCodexIssuerKeys: [testIssuerKey]
            )
            guard case .failure(.disallowedProvider) = res else {
                preconditionFailure("[§34.1] Import inspector must reject non-Codex '\(nonCodex)' even when plugins enabled: \(res)")
            }
        }

        // 5B. CLIProxyRuntimeController sanitizeManagedAuthDirectory + reEnableRejectionReason + [§39.1] isolation checks
        let cpaRoot = scratch.appendingPathComponent("cpa-home", isDirectory: true)
        let paths = try CLIProxyPaths(root: cpaRoot)
        try paths.prepare(fileManager: fm)
        let authDir = paths.authDirectory

        let managedGoURL = authDir.appendingPathComponent("aiusage-codex-go.json")
        let managedFreeURL = authDir.appendingPathComponent("aiusage-codex-free.json")
        let managedPlusURL = authDir.appendingPathComponent("aiusage-codex-plus.json")
        let managedMissingURL = authDir.appendingPathComponent("aiusage-codex-missing.json")
        let managedClaudeURL = authDir.appendingPathComponent("aiusage-claude-1.json")
        let managedRotatedURL = authDir.appendingPathComponent("aiusage-codex-rotated.json")
        let nestedBackupDir = authDir.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: nestedBackupDir, withIntermediateDirectories: true)
        let managedNestedPlusURL = nestedBackupDir.appendingPathComponent("aiusage-codex-nested-plus.json")

        try makeCodexAuthPayload(email: "go@example.com", plan: "go", credentialID: "cred-go", stampVerificationMarkers: true).write(to: managedGoURL)
        try makeCodexAuthPayload(email: "free@example.com", plan: "free", credentialID: "cred-free", stampVerificationMarkers: true).write(to: managedFreeURL)
        try makeCodexAuthPayload(email: "plus@example.com", plan: "plus", credentialID: "cred-plus").write(to: managedPlusURL)
        try makeCodexAuthPayload(email: "miss@example.com", plan: nil, credentialID: "cred-miss").write(to: managedMissingURL)
        try Data(#"{"type":"claude","access_token":"a","refresh_token":"r","aiusage_credential_id":"cred-claude"}"#.utf8).write(to: managedClaudeURL)
        try makeCodexAuthPayload(email: "nested@example.com", plan: "plus", credentialID: "cred-nested-plus").write(to: managedNestedPlusURL)

        // Create a stamped Go copy whose access_token subsequently rotated on refresh
        let preRotateRaw = try makeCodexAuthPayload(email: "rot@example.com", plan: "go", credentialID: "cred-rot", stampVerificationMarkers: true)
        var rotatedJSON = try JSONSerialization.jsonObject(with: preRotateRaw) as! [String: Any]
        rotatedJSON["access_token"] = try signedES256JWT([
            "sub": "user-rot@example.com",
            "jti": "rotated-new-token",
            "email": "rot@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-rot@example.com",
                "chatgpt_user_id": "user-rot@example.com",
                "chatgpt_plan_type": "go"
            ]
        ])
        try JSONSerialization.data(withJSONObject: rotatedJSON, options: [.prettyPrinted, .sortedKeys]).write(to: managedRotatedURL)

        let disabled = try CLIProxyRuntimeController.sanitizeManagedAuthDirectory(
            authDirectory: authDir,
            excludedCredentialIDs: [],
            trustedCodexIssuerKeys: [testIssuerKey]
        )
        precondition(Set(disabled) == Set([
            "aiusage-codex-plus.json",
            "aiusage-codex-missing.json",
            "aiusage-claude-1.json",
            "aiusage-codex-rotated.json",
            "backup/aiusage-codex-nested-plus.json"
        ]), "[§34.1 + §37.1 + §39.1] recursive sanitizeManagedAuthDirectory disabled wrong set: \(disabled)")
        for validURL in [managedGoURL, managedFreeURL] {
            let obj = try! JSONSerialization.jsonObject(with: try! Data(contentsOf: validURL)) as? [String: Any]
            precondition(obj?["disabled"] as? Bool == false, "[§34.1] Valid Codex Go/Free managed auth file must stay enabled")
        }
        for blockedURL in [managedPlusURL, managedMissingURL, managedClaudeURL, managedRotatedURL, managedNestedPlusURL] {
            let obj = try! JSONSerialization.jsonObject(with: try! Data(contentsOf: blockedURL)) as? [String: Any]
            let perms = ((try! fm.attributesOfItem(atPath: blockedURL.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1) & 0o777
            precondition(obj?["disabled"] as? Bool == true && perms == 0o600,
                         "[§34.1 + §37.1 + §39.1] Disallowed/nested managed auth \(blockedURL.lastPathComponent) must be disabled & 0600")
        }

        // [§39.1] Nested enabled external file and symlinked auth subdirectory must fail closed
        let extNestedURL = nestedBackupDir.appendingPathComponent("external-nested-plus.json")
        try makeCodexAuthPayload(email: "extnested@example.com", plan: "plus").write(to: extNestedURL)
        var nestedExtThrew = false
        do {
            _ = try CLIProxyRuntimeController.sanitizeManagedAuthDirectory(
                authDirectory: authDir,
                excludedCredentialIDs: [],
                trustedCodexIssuerKeys: [testIssuerKey]
            )
        } catch {
            nestedExtThrew = true
        }
        precondition(nestedExtThrew, "[§39.1] Recursive sanitizeManagedAuthDirectory must reject nested enabled external disallowed auth")
        try fm.removeItem(at: extNestedURL)

        let symlinkDir = authDir.appendingPathComponent("linked-subdir", isDirectory: true)
        try fm.createSymbolicLink(at: symlinkDir, withDestinationURL: scratch)
        var symlinkThrew = false
        do {
            _ = try CLIProxyRuntimeController.sanitizeManagedAuthDirectory(
                authDirectory: authDir,
                excludedCredentialIDs: [],
                trustedCodexIssuerKeys: [testIssuerKey]
            )
        } catch {
            symlinkThrew = true
        }
        precondition(symlinkThrew, "[§39.1] Recursive sanitizeManagedAuthDirectory must reject symlinks")
        try fm.removeItem(at: symlinkDir)

        // [§37.1] Runtime identity row whose account/email disagrees with disk auth file must be rejected
        let runtimeMismatchedRow = try! JSONDecoder().decode(
            CLIProxyAuthFile.self,
            from: Data(#"{"name":"aiusage-codex-go.json","type":"codex","provider":"codex","account":"acct-other-live","email":"go@example.com","disabled":false,"unavailable":false,"runtime_only":false}"#.utf8)
        )
        precondition(CLIProxyRuntimeController.reEnableRejectionReason(
            for: runtimeMismatchedRow,
            in: authDir,
            excludedCredentialIDs: [],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) != nil, "[§37.1] Runtime row whose account disagrees with disk auth file must fail closed")

        let runtimeOnlyCodex = try! JSONDecoder().decode(
            CLIProxyAuthFile.self,
            from: Data(#"{"name":"runtime-codex.json","type":"codex","provider":"codex","email":"plus@example.com","disabled":false,"unavailable":false,"runtime_only":true}"#.utf8)
        )
        precondition(CLIProxyRuntimeController.reEnableRejectionReason(
            for: runtimeOnlyCodex,
            in: authDir,
            excludedCredentialIDs: [],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) != nil, "[§34.1] Runtime-only Codex row must fail closed without disk plan verification")

        // [§35.1] Non-managed external Codex row with missing disk file must be rejected by reEnableRejectionReason
        let missingExternalCodex = try! JSONDecoder().decode(
            CLIProxyAuthFile.self,
            from: Data(#"{"name":"missing-external-codex.json","type":"codex","provider":"codex","email":"missing@example.com","disabled":false,"unavailable":false,"runtime_only":false}"#.utf8)
        )
        precondition(CLIProxyRuntimeController.reEnableRejectionReason(
            for: missingExternalCodex,
            in: authDir,
            excludedCredentialIDs: [],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) != nil, "[§35.1] External Codex row with missing disk file must fail closed")

        // [§39.2] External auth file carrying per-credential retry override must fail closed
        let extRetryURL = authDir.appendingPathComponent("external-retry-override.json")
        try JSONSerialization.data(withJSONObject: goRetryOverride).write(to: extRetryURL)
        let extRetryRow = try! JSONDecoder().decode(
            CLIProxyAuthFile.self,
            from: Data(#"{"name":"external-retry-override.json","type":"codex","provider":"codex","email":"go@example.com","disabled":false,"unavailable":false,"runtime_only":false}"#.utf8)
        )
        precondition(CLIProxyRuntimeController.reEnableRejectionReason(
            for: extRetryRow,
            in: authDir,
            excludedCredentialIDs: [],
            trustedCodexIssuerKeys: [testIssuerKey]
        ) != nil, "[§39.2] External row with per-credential request_retry > 0 must fail closed")
        try fm.removeItem(at: extRetryURL)

        // [§35.1] Metadata-only plan without token-bound plan proof must fail closed (.missing)
        let planlessPayload = try! makeCodexAuthPayload(email: "planless@example.com", plan: nil)
        let metaOnlyVerification = CLIProxyCapabilityMatrix.codexPlanVerification(
            fromAuthData: planlessPayload,
            metadata: ["accountPlan": "go"],
            trustedKeys: [testIssuerKey]
        )
        precondition(metaOnlyVerification == .missing && metaOnlyVerification.verifiedPlan == nil,
                     "[§35.1] Metadata-only plan must not return .verified: \(metaOnlyVerification)")

        // [§39.1] Isolated runtime directory & allowlisted child environment checks (legacy auth/ left untouched)
        let legacyGoBytesBefore = try Data(contentsOf: managedGoURL)
        try CLIProxyRuntimeController.verifyIsolatedAPIOnlyRuntimeDirectories(paths: paths, fileManager: fm)
        let legacyGoBytesAfter = try Data(contentsOf: managedGoURL)
        precondition(legacyGoBytesAfter == legacyGoBytesBefore,
                     "[§39.1] Isolation verification must leave legacy auth/ bytes untouched")
        let strayEnv = paths.runtimeWorkingDirectory.appendingPathComponent(".env")
        try Data("PGSTORE_DSN=postgres://bad\n".utf8).write(to: strayEnv)
        var nonEmptyWDThrew = false
        do {
            try CLIProxyRuntimeController.verifyIsolatedAPIOnlyRuntimeDirectories(paths: paths, fileManager: fm)
        } catch {
            nonEmptyWDThrew = true
        }
        precondition(nonEmptyWDThrew, "[§39.1] verifyIsolatedAPIOnlyRuntimeDirectories must fail closed on dotfile in runtime-wd")
        try fm.removeItem(at: strayEnv)

        let isolatedEnv = CLIProxyRuntimeController.buildIsolatedChildEnvironment(
            paths: paths,
            parentEnvironment: [
                "HOME": "/Users/should-not-leak",
                "TMPDIR": "/tmp/should-not-leak",
                "PATH": "/opt/poison/bin:/usr/bin",
                "HOME_JWT": "poison-jwt",
                "PGSTORE_DSN": "postgres://poison",
                "GITSTORE_GIT_URL": "https://poison.example/repo.git",
                "OBJECTSTORE_ENDPOINT": "https://poison.example",
                "DEPLOY": "cloud",
                "WRITABLE_PATH": "/tmp/poison-writable",
                "MANAGEMENT_PASSWORD": "poison-password",
                "HTTP_PROXY": "http://127.0.0.1:9999",
                "TZ": "UTC"
            ]
        )
        precondition(
            isolatedEnv["HOME"] == paths.runtimeWorkingDirectory.path
                && isolatedEnv["TMPDIR"] == paths.runtimeTempDirectory.path
                && isolatedEnv["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"
                && isolatedEnv["TZ"] == "UTC"
                && isolatedEnv["HOME_JWT"] == nil
                && isolatedEnv["PGSTORE_DSN"] == nil
                && isolatedEnv["GITSTORE_GIT_URL"] == nil
                && isolatedEnv["OBJECTSTORE_ENDPOINT"] == nil
                && isolatedEnv["DEPLOY"] == nil
                && isolatedEnv["WRITABLE_PATH"] == nil
                && isolatedEnv["MANAGEMENT_PASSWORD"] == nil
                && isolatedEnv["HTTP_PROXY"] == nil,
            "[§39.1] buildIsolatedChildEnvironment leaked poisoned parent env vars: \(isolatedEnv)"
        )

        // [§35.2] Direct CPA sidecar OAuth sign-in must be rejected before contacting the running sidecar
        let testMgmtClient = CLIProxyManagementClient(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            managementKey: "mgmt-key",
            clientAPIKey: "client-key"
        )
        var directOAuthBlocked = false
        do {
            _ = try await testMgmtClient.beginOAuth(.codex)
        } catch is CLIProxyGatewayError {
            directOAuthBlocked = true
        }
        precondition(directOAuthBlocked, "[§35.2] Direct CPA Codex OAuth must be blocked before hitting sidecar")

        let extPlusURL = authDir.appendingPathComponent("external-plus.json")
        try makeCodexAuthPayload(email: "extplus@example.com", plan: "plus").write(to: extPlusURL)
        var extThrew = false
        do {
            _ = try CLIProxyRuntimeController.sanitizeManagedAuthDirectory(
                authDirectory: authDir,
                excludedCredentialIDs: [],
                trustedCodexIssuerKeys: [testIssuerKey]
            )
        } catch {
            extThrew = true
        }
        precondition(extThrew, "[§34.1] Enabled external Codex Plus auth file must refuse CPA startup")
        try fm.removeItem(at: extPlusURL)

        // 5C. [§28.1 + §39.1] performVersionActivation rollback + isolated listener adoption & post-health auth check
        let storeRoot = scratch.appendingPathComponent("bin-store", isDirectory: true)
        let binPaths = try CLIProxyPaths(root: storeRoot)
        try binPaths.prepare(fileManager: fm)
        let testPort = try reserveLoopbackPort()
        let v10Dir = try binPaths.versionDirectory("1.0.0")
        let v11Dir = try binPaths.versionDirectory("1.1.0")
        try fm.createDirectory(at: v10Dir, withIntermediateDirectories: true)
        try fm.createDirectory(at: v11Dir, withIntermediateDirectories: true)
        let subInjectFlag = scratch.appendingPathComponent("inject-subscription.flag")
        let pyServer = """
        #!/usr/bin/env python3
        import http.server, os, socketserver, sys
        FLAG = \(String(reflecting: subInjectFlag.path))
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200)
                self.end_headers()
                if "auth-files" in self.path:
                    if os.path.exists(FLAG):
                        self.wfile.write(b'{"files":[{"id":"sub1","name":"legacy-sub.json","type":"codex","provider":"codex","disabled":false,"unavailable":false,"runtime_only":false}]}')
                    else:
                        self.wfile.write(b'{"files":[]}')
                else:
                    self.wfile.write(b"{}")
            def log_message(self, *args): pass
        class ReuseTCP(socketserver.TCPServer):
            allow_reuse_address = True
        with ReuseTCP(("127.0.0.1", \(testPort)), Handler) as httpd:
            httpd.serve_forever()
        """
        let v10Exe = v10Dir.appendingPathComponent(binPaths.binaryName)
        let v11Exe = v11Dir.appendingPathComponent(binPaths.binaryName)
        try Data(pyServer.utf8).write(to: v10Exe)
        try Data("#!/bin/sh\necho bad\nexit 1\n".utf8).write(to: v11Exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v10Exe.path)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v11Exe.path)

        let defaultsKeys = [
            "cliproxy.gateway.client-key-fingerprint.v1",
            "cliproxy.gateway.client-key-ack.v1"
        ]
        let savedDefaults = defaultsKeys.map { ($0, UserDefaults.standard.object(forKey: $0)) }
        defer {
            for (k, v) in savedDefaults {
                if let v { UserDefaults.standard.set(v, forKey: k) } else { UserDefaults.standard.removeObject(forKey: k) }
            }
        }

        let binaryStore = CLIProxyBinaryStore(paths: binPaths)
        _ = try await binaryStore.activateTracked(version: "1.0.0")

        let controller = try CLIProxyRuntimeController(paths: binPaths, binaryStore: binaryStore)
        controller.settings.port = testPort
        let hold = CLIProxyRuntimeController.managedRuntimeHoldMessage
        controller.settings.autoStart = true
        await controller.startIfConfigured()
        precondition(controller.state == .failed(hold), "[§41.1] Auto-start must honor the runtime hold")
        await controller.start()
        precondition(controller.state == .failed(hold), "[§41.1] Manual start must honor the runtime hold")
        await controller.restart()
        precondition(controller.state == .failed(hold), "[§41.1] Restart must honor the runtime hold")
        do {
            _ = try await controller.performVersionActivation(
                version: "1.1.0",
                switchVersion: { preconditionFailure("[§41.1] Must not switch on hold") },
                rollbackVersion: { preconditionFailure("[§41.1] Must not rollback on hold") }
            )
            preconditionFailure("[§41.1] Activation must be blocked")
        } catch {
            precondition(error.localizedDescription.contains(hold))
        }
        let heldAdoption = await controller.canAdoptRunningListener(
            settings: controller.settings, secrets: CLIProxySecretStore().secrets,
            clientAPIKeys: nil, listeningPIDs: [42],
            processVerifier: { _ in preconditionFailure("[§41.4] Must not probe ownership on hold") }
        )
        precondition(!heldAdoption.isSafeToAdopt && heldAdoption.reason == hold)
        precondition(!fm.fileExists(atPath: binPaths.configURL.path),
                     "[§41.1] Held paths must not publish the watched config")
        let heldStop = await controller.stop()
        precondition(heldStop, "[§41.1] Stop verification remains available while startup is held")
        let busyStop = await controller.stop(
            portAvailableCheck: { _, _ in false },
            pidTerminator: { _ in preconditionFailure("[§41.1] Must not kill an unverified listener") }
        )
        precondition(!busyStop && controller.hasUnconfirmedListener,
                     "[§41.1] A busy port with no PID record must not be reported as stopped")
        let releasedStop = await controller.stop(portAvailableCheck: { _, _ in true })
        precondition(releasedStop && !controller.hasUnconfirmedListener,
                     "[§41.1] A verified released port clears the held stop marker")
        print("PASS: [§41.1 + §41.4] Runtime hold blocks auto/manual start, restart, activation, and adoption; Verify Stop checks the port")
        controller.settings.autoStart = false
        controller.allowIsolatedFixtureLaunch = true
        await controller.start()
        precondition(controller.state.isRunning, "[§28.1] 1.0.0 test listener must reach running state (state=\(controller.state))")

        var capturedPrev: String?
        var capturedCommit: String?
        var rollbackInvoked = false
        var abaThrew = false
        do {
            _ = try await controller.performVersionActivation(
                version: "1.1.0",
                switchVersion: {
                    let act = try await binaryStore.activateTracked(version: "1.1.0")
                    capturedPrev = act.previous
                    capturedCommit = act.commitID
                    _ = try await binaryStore.activateTracked(version: "1.0.0")
                    _ = try await binaryStore.activateTracked(version: "1.1.0")
                },
                rollbackVersion: {
                    rollbackInvoked = true
                    guard let prev = capturedPrev, let cid = capturedCommit else { return }
                    _ = try await binaryStore.activate(
                        version: prev,
                        expectedCurrentVersion: "1.1.0",
                        expectedCommitID: cid
                    )
                }
            )
        } catch {
            abaThrew = true
        }
        _ = await controller.stop()
        precondition(abaThrew && rollbackInvoked, "[§28.1] performVersionActivation should invoke rollback and surface activation error")
        let activeVer = try await binaryStore.currentVersion()
        precondition(activeVer == "1.1.0", "[§28.1] ABA commit guard left current version intact")
        precondition(!controller.state.isRunning, "[§28.1] performVersionActivation skipped post-rollback restart when rollback threw")
        precondition(controller.recentLogs.contains { $0.contains("Rollback skipped:") },
                     "[§28.1] performVersionActivation logged skipped rollback when commitID changed")

        // [§39.1] Post-health loopback verification must abort and terminate child if /auth-files exposes subscription row
        _ = try await binaryStore.activateTracked(version: "1.0.0")
        try Data("1".utf8).write(to: subInjectFlag)
        let failClosedPort = try reserveLoopbackPort()
        let pyServer2 = pyServer.replacingOccurrences(of: "\(testPort)", with: "\(failClosedPort)")
        try Data(pyServer2.utf8).write(to: v10Exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v10Exe.path)
        controller.settings.port = failClosedPort
        await controller.start()
        precondition(!controller.state.isRunning,
                     "[§39.1] start() must abort and terminate CPA if post-health /auth-files contains subscription auth")
        try? fm.removeItem(at: subInjectFlag)

        // [§39.1] canAdoptRunningListener must refuse pre-isolation PID records missing isolationProfile/runtimeAuthDir
        let pidURL = binPaths.root.appendingPathComponent("runtime.pid.json")
        let adoptPort = try reserveLoopbackPort()
        let pyServerAdopt = pyServer.replacingOccurrences(of: "\(testPort)", with: "\(adoptPort)")
        try Data(pyServerAdopt.utf8).write(to: v10Exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: v10Exe.path)
        let adoptProc = Process()
        adoptProc.executableURL = v10Exe
        adoptProc.arguments = ["-config", binPaths.configURL.path]
        try adoptProc.run()
        defer { if adoptProc.isRunning { adoptProc.terminate() } }
        try await Task.sleep(for: .milliseconds(250))
        controller.settings.port = adoptPort
        let secrets = CLIProxySecretStore().secrets
        _ = try CLIProxyConfigStore(paths: binPaths).writeRuntimeConfig(settings: controller.settings, secrets: secrets)
        let digest = CLIProxyConfigStore(paths: binPaths).runtimeConfigSHA256() ?? ""
        let legacyAdoptRecord: [String: Any] = [
            "pid": Int(adoptProc.processIdentifier),
            "binaryPath": v10Exe.path,
            "configPath": binPaths.configURL.path,
            "configSHA256": digest,
            "port": adoptPort,
            "bindHost": "127.0.0.1"
        ]
        try JSONSerialization.data(withJSONObject: legacyAdoptRecord).write(to: pidURL)
        let adoptResult = await controller.canAdoptRunningListener(
            settings: controller.settings.normalized,
            secrets: secrets,
            clientAPIKeys: [secrets.clientAPIKey],
            listeningPIDs: [adoptProc.processIdentifier],
            processVerifier: { _ in true }
        )
        precondition(!adoptResult.isSafeToAdopt,
                     "[§39.1] canAdoptRunningListener must refuse pre-isolation PIDRecord without isolationProfile")
        adoptProc.terminate()
        try? fm.removeItem(at: subInjectFlag)
        print("PASS: [§34.1 + §28.1 + §39.1 + §39.2] Codex Go/Free containment, isolation, env allowlist, adoption guard, post-health check, & ABA rollback guard")
    }
}
SWIFT

swiftc -parse-as-library -swift-version 5 -D AIUSAGE_CPA_ISOLATION_FIXTURE \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT/AIUsage/Models/CLIProxyUpstreamCapability.swift" \
  "$ROOT/AIUsage/Models/CLIProxyAuthImportPlanner.swift" \
  "$ROOT/AIUsage/Models/CLIProxyClientKeyModels.swift" \
  "$ROOT/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT/AIUsage/Services/CLIProxyGeminiCredentialBridge.swift" \
  "$ROOT/AIUsage/Services/CLIProxyCredentialAdapter.swift" \
  "$ROOT/AIUsage/Services/CLIProxyManagementClient.swift" \
  "$ROOT/AIUsage/Services/CLIProxyReleaseClient.swift" \
  "$ROOT/AIUsage/Services/CLIProxyBinaryStore.swift" \
  "$ROOT/AIUsage/Services/CLIProxyRuntimeController.swift" \
  "$REGRESSION_DIR/CPAGatewayRuntimeRegression.swift" \
  -o "$REGRESSION_DIR/cpa-runtime-regression"
"$REGRESSION_DIR/cpa-runtime-regression"
if [[ -n "${AIUSAGE_CPA_TEST_BINARY:-}" ]]; then
  python3 "$ROOT/scripts/cpa_isolated_runtime_proof.py" "$AIUSAGE_CPA_TEST_BINARY" "$REGRESSION_DIR/cpa-runtime-regression"
fi

# 5D. [§37.2] Extracted production CLIProxyGatewayManager connectivity & stop-on-429 regression (0 HTTP)
python3 - "$ROOT" "$REGRESSION_DIR" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
temp = pathlib.Path(sys.argv[2])
mgr_src = (root / 'AIUsage/ViewModels/CLIProxyGatewayManager.swift').read_text()
start = mgr_src.index('    nonisolated static func shouldStopBulkConnectivityCheck')
end = mgr_src.index('\n    /// 账号中心 / 池变更后预取各凭据可用模型')
conn_methods = mgr_src[start:end]
pause_start = mgr_src.index("    struct ManagedPauseOutcome")
pause_end = mgr_src.index("        func normalizeID(", pause_start)
# Exercise the production held-build path; the subscription-only implementation must never be reached.
held_pause = mgr_src[pause_start:pause_end] + '        preconditionFailure("Archived CPA credential writer reached")\n    }'

harness_swift = f"""import CryptoKit
import Foundation
import QuotaBackend

func L(_ en: String, _ zh: String) -> String {{ en }}

private extension String {{
    var nilIfBlank: String? {{
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }}
}}

private extension CLIProxyAuthFile {{
    var gatewayProviderID: String {{
        CLIProxyCapabilityMatrix.normalizedProviderIDs(from: [provider, type]).first ?? ""
    }}
}}

nonisolated struct CLIProxySecretStore: Sendable {{
    let secrets = CLIProxySecrets(managementKey: "test-mgmt-key", clientAPIKey: "test-client-key")
    func loadOrCreate() throws -> CLIProxySecrets {{ secrets }}
    func load() -> CLIProxySecrets? {{ secrets }}
    func delete() throws {{}}
}}

nonisolated struct CLIProxyClientKeyStore {{
    let secretStore: CLIProxySecretStore
    func loadEntries() throws -> [CLIProxyClientKeyEntry] {{ [] }}
    func enabledKeysForRuntime() throws -> [String] {{ [secretStore.secrets.clientAPIKey] }}
}}

nonisolated final class RecordingURLProtocol: URLProtocol {{
    private static let lock = NSLock()
    static var requestURLs: [String] = []
    override class func canInit(with request: URLRequest) -> Bool {{ true }}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {{ request }}
    override func startLoading() {{
        Self.lock.withLock {{
            Self.requestURLs.append(request.url?.absoluteString ?? "unknown")
        }}
        let resp = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }}
    override func stopLoading() {{}}
}}

@MainActor
enum ProxyPortArbiter {{
    struct Owner {{
        let id: String
        let ports: [Int]
        let track: String
        let label: String
    }}
    struct Conflict {{
        let port: Int
        let track: String
        let label: String
    }}
    static func conflict(forPorts _: [Int], excluding _: String) -> Conflict? {{ nil }}
}}

@MainActor
final class AccountStore {{
    static let shared = AccountStore()
    struct ExcludedFilters {{
        var credentialIDs: Set<String> = []
    }}
    var excludedFilters = ExcludedFilters()
    func excludedEngineAccountFilters() -> ExcludedFilters {{ excludedFilters }}
}}

@MainActor
final class ConnectivityManagerHarness {{
    let paths: CLIProxyPaths
    let runtime: CLIProxyRuntimeController
    var authFiles: [CLIProxyAuthFile] = []
    var authFileConnectivity: [String: CLIProxyAccountConnectivityState] = [:]
    var connectivityProbeOverride: ((CLIProxyAuthFile) async -> CLIProxyAccountConnectivityState)?

    init(paths: CLIProxyPaths, runtime: CLIProxyRuntimeController) {{
        self.paths = paths
        self.runtime = runtime
    }}

    func managementClient() -> CLIProxyManagementClient? {{
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [RecordingURLProtocol.self]
        return CLIProxyManagementClient(
            baseURL: URL(string: "http://127.0.0.1:14420")!,
            managementKey: "test-mgmt-key",
            clientAPIKey: "test-client-key",
            session: URLSession(configuration: cfg)
        )
    }}

{conn_methods}
{held_pause}
}}

private func signES256(_ rawClaims: [String: Any], key: P256.Signing.PrivateKey) throws -> String {{
    func b64u(_ data: Data) -> String {{
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }}
    var claims = rawClaims
    claims["iss"] = "https://auth.openai.com"
    claims["aud"] = "https://api.openai.com/v1"
    claims["iat"] = 1_700_000_000
    claims["exp"] = 4_102_444_800
    let header = try JSONSerialization.data(withJSONObject: ["alg": "ES256", "typ": "JWT", "kid": "k1"], options: [.sortedKeys])
    let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
    let signingInput = "\\(b64u(header)).\\(b64u(payload))"
    let sig = try key.signature(for: Data(signingInput.utf8))
    return "\\(signingInput).\\(b64u(sig.rawRepresentation))"
}}

@main
struct CPAConnectivityMain {{
    @MainActor
    static func main() async throws {{
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("cpa-conn-reg-\\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer {{ try? fm.removeItem(at: root) }}

        let paths = try CLIProxyPaths(root: root.appendingPathComponent("cpa", isDirectory: true))
        try paths.prepare(fileManager: fm)
        let priv = P256.Signing.PrivateKey()
        let trusted = CLIProxyTrustedJWSKey(
            keyID: "k1",
            issuer: "https://auth.openai.com",
            allowedAudiences: ["https://api.openai.com/v1"],
            publicKeyData: priv.publicKey.x963Representation
        )

        func writeValidCodex(name: String, email: String, credID: String) throws -> CLIProxyAuthFile {{
            let tok = try signES256([
                "sub": "user-\\(credID)",
                "email": email,
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct-\\(credID)",
                    "chatgpt_user_id": "user-\\(credID)",
                    "chatgpt_plan_type": "go"
                ]
            ], key: priv)
            let obj: [String: Any] = [
                "type": "codex",
                "email": email,
                "account_id": "acct-\\(credID)",
                "access_token": tok,
                "id_token": tok,
                "refresh_token": "ref-\\(credID)",
                "aiusage_credential_id": credID,
                "aiusage_verified_account_id": "acct-\\(credID)",
                "aiusage_verified_user_id": "user-\\(credID)",
                "aiusage_verified_access_token_sha256": CLIProxyCapabilityMatrix.sha256Hex(tok),
                "disabled": false
            ]
            try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]).write(
                to: paths.authDirectory.appendingPathComponent(name)
            )
            let metaObj: [String: Any] = [
                "id": credID,
                "auth_index": "idx-\\(credID)",
                "name": name,
                "type": "codex",
                "provider": "codex",
                "account": "acct-\\(credID)",
                "email": email,
                "disabled": false,
                "unavailable": false,
                "runtime_only": false
            ]
            let metaData = try JSONSerialization.data(withJSONObject: metaObj)
            return try JSONDecoder().decode(CLIProxyAuthFile.self, from: metaData)
        }}

        let f1 = try writeValidCodex(name: "aiusage-codex-1.json", email: "c1@example.com", credID: "c1")
        let f2 = try writeValidCodex(name: "aiusage-codex-2.json", email: "c2@example.com", credID: "c2")
        let runtime = try CLIProxyRuntimeController(paths: paths)
        let manager = ConnectivityManagerHarness(paths: paths, runtime: runtime)
        manager.authFiles = [f1, f2]

        let archiveURL = paths.authDirectory.appendingPathComponent(f1.name)
        let archivedHash = SHA256.hash(data: try Data(contentsOf: archiveURL))
        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.protocolClasses = [RecordingURLProtocol.self]
        let adoption = await runtime.canAdoptRunningListener(
            settings: runtime.settings, secrets: CLIProxySecretStore().secrets,
            clientAPIKeys: nil, listeningPIDs: [42], session: URLSession(configuration: probeConfig)
        )
        precondition(!adoption.isSafeToAdopt && RecordingURLProtocol.requestURLs.isEmpty,
                     "[§41.4] Production adoption must refuse before any HTTP")

        // The unreadable fence simulates an old listener whose stop cannot be verified.
        // The held build must surface the failure but must not touch the saved credential.
        let fenceURL = paths.root.appendingPathComponent("runtime.unconfirmed.json")
        try Data("invalid fixture fence".utf8).write(to: fenceURL)
        let pauseOutcome = await manager.pauseManagedAuthFiles(forCredentialIDs: ["c1"])
        precondition(pauseOutcome.verificationError != nil && pauseOutcome.pausedFiles.isEmpty,
                     "[§41.3] Unconfirmed stop must not report a paused file")
        let afterPauseHash = SHA256.hash(data: try Data(contentsOf: archiveURL))
        precondition(afterPauseHash == archivedHash, "[§41.3] Held build must preserve archived credential bytes")
        try FileManager.default.removeItem(at: fenceURL)
        print("PASS: [§41.3 + §41.4] Archive hash unchanged after dashboard pause; held adoption performed 0 HTTP")

        // 1) Default production build (no trusted issuer keys) fails closed on policy_rejected with 0 HTTP;
        // explicit fixture trust returns .unsupported with 0 HTTP across single, family, and pool buttons.
        let singleDefault = await manager.testAccountConnectivity(for: f1)
        let familyDefault = await manager.testFamilyAccountConnectivity([f1, f2])
        let poolDefault = await manager.testAllAccountConnectivity()
        guard case .failed(let defaultCode, _, _) = singleDefault.state, defaultCode == "policy_rejected",
              familyDefault.count == 1, poolDefault.count == 1 else {{
            preconditionFailure("[§39.3 + §37.2] Default production connectivity must fail closed and stop immediately")
        }}

        let singleRes = await manager.testAccountConnectivity(for: f1, trustedCodexIssuerKeys: [trusted])
        let familyRes = await manager.testFamilyAccountConnectivity([f1, f2], trustedCodexIssuerKeys: [trusted])
        let poolRes = await manager.testAllAccountConnectivity(trustedCodexIssuerKeys: [trusted])
        guard case .unsupported = singleRes.state else {{
            preconditionFailure("[§37.2] Codex single connectivity check must return .unsupported without HTTP, got \\(singleRes.state)")
        }}
        precondition(familyRes.isEmpty && poolRes.isEmpty && RecordingURLProtocol.requestURLs.isEmpty,
                     "[§37.2] Single/family/pool checks must make 0 consumer HTTP calls: urls=\\(RecordingURLProtocol.requestURLs)")

        // 2) Policy gate runs immediately before dispatch even when probe override is present
        AccountStore.shared.excludedFilters.credentialIDs = ["c1"]
        var probed: [String] = []
        manager.connectivityProbeOverride = {{ file in
            probed.append(file.name)
            return .failed(code: "upstream_rate_limited", message: "429", checkedAt: Date())
        }}
        let pausedRes = await manager.testAccountConnectivity(for: f1, trustedCodexIssuerKeys: [trusted])
        guard case .failed(let code, _, _) = pausedRes.state, code == "policy_rejected", probed.isEmpty else {{
            preconditionFailure("[§37.2] Paused account must fail policy gate before probe: \\(pausedRes.state), probed=\\(probed)")
        }}

        // 3) Bulk & family checks stop immediately after 429 on first account (never touching second account)
        AccountStore.shared.excludedFilters.credentialIDs = []
        let pool429 = await manager.testAllAccountConnectivity(trustedCodexIssuerKeys: [trusted])
        precondition(pool429.count == 1 && probed == ["aiusage-codex-1.json"],
                     "[§37.2] Pool check must stop immediately on 429; got probed=\\(probed)")

        probed.removeAll()
        let family429 = await manager.testFamilyAccountConnectivity([f1, f2], trustedCodexIssuerKeys: [trusted])
        precondition(family429.count == 1 && probed == ["aiusage-codex-1.json"],
                     "[§37.2] Family check must stop immediately on 429; got probed=\\(probed)")
        print("PASS: [§37.2] Single/family/pool connectivity checks make 0 consumer HTTP calls and stop on 429")
    }}
}}
"""
(temp / 'CPAConnectivityRegression.swift').write_text(harness_swift)
PY

swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" \
  -Xlinker -filelist -Xlinker "$REGRESSION_DIR/objects.txt" \
  -lsqlite3 \
  "$ROOT/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT/AIUsage/Models/CLIProxyUpstreamCapability.swift" \
  "$ROOT/AIUsage/Models/CLIProxyAuthImportPlanner.swift" \
  "$ROOT/AIUsage/Models/CLIProxyClientKeyModels.swift" \
  "$ROOT/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT/AIUsage/Services/CLIProxyGeminiCredentialBridge.swift" \
  "$ROOT/AIUsage/Services/CLIProxyCredentialAdapter.swift" \
  "$ROOT/AIUsage/Services/CLIProxyManagementClient.swift" \
  "$ROOT/AIUsage/Services/CLIProxyReleaseClient.swift" \
  "$ROOT/AIUsage/Services/CLIProxyBinaryStore.swift" \
  "$ROOT/AIUsage/Services/CLIProxyRuntimeController.swift" \
  "$REGRESSION_DIR/CPAConnectivityRegression.swift" \
  -o "$REGRESSION_DIR/cpa-connectivity-regression"
"$REGRESSION_DIR/cpa-connectivity-regression"

# 5. Parse-check every Swift file in AIUsage (CommandLineTools has no full Xcode build target)
AIUSAGE_SWIFT_FILES=()
while IFS= read -r line; do
  AIUSAGE_SWIFT_FILES+=("$line")
done < <(find "$ROOT/AIUsage" -name '*.swift' | sort)
swiftc -parse "${AIUSAGE_SWIFT_FILES[@]}"
echo "PASS: swiftc -parse clean on all ${#AIUSAGE_SWIFT_FILES[@]} AIUsage Swift files"
fi
