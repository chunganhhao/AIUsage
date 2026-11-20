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
    function(opencode_src, '    func activate(_ node: OpenCodeNode)'),
    function(opencode_src, '    func activate(_ nodes: [OpenCodeNode])'),
    function(opencode_src, '    func deactivate(_ node: OpenCodeNode)'),
    function(opencode_src, '    func deactivate(_ ids: [String])'),
    function(opencode_src, '    private func rewriteManagedConfig('),
    function(opencode_src, '    func startProxyOnly(_ node: OpenCodeNode)'),
    function(opencode_src, '    func stopProxyOnly(_ node: OpenCodeNode)'),
    function(opencode_src, '    private func load()'),
    function(opencode_src, '    @discardableResult\n    func save()'),
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
