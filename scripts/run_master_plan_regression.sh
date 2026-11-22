#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-master.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys

root, temp = map(Path, sys.argv[1:])

def declaration(source, marker, indent="    "):
    start = source.index("\n" + indent + marker) + 1
    closing = "\n" + indent + "}"
    end = source.index(closing, start) + len(closing)
    return source[start:end]

settings = (root / "AIUsage/Models/AppSettings.swift").read_text()
visibility = (root / "AIUsage/Models/AgentVisibility.swift").read_text()
sync = (root / "AIUsage/ViewModels/ModelAutoSyncCoordinator.swift").read_text()
distributor = (root / "AIUsage/ViewModels/APIProviderDistributor.swift").read_text()
cards = (root / "AIUsage/Views/DashboardStateCards.swift").read_text()
flash = (root / "AIUsage/Views/AppFlashBanner.swift").read_text()
api_src = (root / "AIUsage/Services/APIService.swift").read_text()
for imp in ("import Darwin\n", "import Foundation\n", "import QuotaBackend\n"):
    api_src = api_src.replace(imp, "")

address = "\n".join(declaration(settings, marker) for marker in (
    "static func remoteBaseURL(", "static func resolveRemoteSettingsAddress(", "static func parseRemoteAddress(",
))
catalog = "\n".join(declaration(sync, marker) for marker in (
    "struct Report", "private func commitCatalogSync(", "private struct BaselineDecision",
    "private func baselineDecision(", "struct StateFile", "private func summaryFlash(",
))
sync_provider_fn = declaration(sync, "private func syncProvider(")
sync_opencode_fn = declaration(sync, "private func syncOpenCode(")
propagate_fn = declaration(distributor, "@discardableResult\n    func propagateCatalog(")
serialize_fn = declaration(distributor, "private func withProviderSerialization<T>(")
shimmer_struct = declaration(cards, "private struct ShimmerModifier: ViewModifier", indent="")
app_flash_struct = declaration(flash, "struct AppFlash: Equatable, Identifiable", indent="")
visibility_src = visibility.replace("import Foundation\nimport QuotaBackend\n", "")
app_section_src = declaration(settings, "enum AppSection:", indent="")

(temp / "AppRegressionFixture.swift").write_text(f"""
import Darwin
import Foundation
import SwiftUI
import QuotaBackend

{visibility_src}

{app_section_src}

func L(_ en: String, _ _: String, _ _: String? = nil) -> String {{ en }}

private extension String {{
    var nilIfBlank: String? {{
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }}
}}

enum DefaultsKey {{
    static let remoteHost = "remoteHost"
    static let remotePort = "remotePort"
}}

enum QuotaShareTokenStore {{
    enum Slot {{ case remote }}
    static func load(_: Slot) -> String? {{ nil }}
}}

final class AppSettings {{
    static let shared = AppSettings()
    var hiddenSidebarSections: Set<String> = []
    static func remoteBaseURL(host: String, port: Int) -> String {{
        AppSettingsAddressFixture.remoteBaseURL(host: host, port: port)
    }}
    static func localized(_ en: String, _ _: String, _ _: String? = nil) -> String {{ en }}
}}

struct ProviderData: Codable, Sendable {{
    var id = ""
}}

struct ProviderWrapper: Codable, Sendable {{
    let summary: ProviderData
    let ok: Bool
}}

struct DashboardResponse: Codable, Sendable {{
    let providers: [ProviderWrapper]
}}

{api_src}

{app_flash_struct}

{shimmer_struct}

enum ShimmerRegressionProbe {{
    static var stops: [Gradient.Stop] {{ ShimmerModifier.gradientStops }}
    static func points(for phase: CGFloat) -> (start: UnitPoint, end: UnitPoint) {{
        ShimmerModifier.gradientPoints(for: phase)
    }}
}}

enum AppSettingsAddressFixture {{
{address}
}}

final class CatalogSyncFixture {{
    private struct Target {{ let stateKey = "fixture" }}
    private struct FetchSpec {{ let upstreamIdentity = "fixture" }}
    private var state = StateFile()

    func sync(upstream: [String], existing: Set<String>, save: () -> Bool) -> [String] {{
        let target = Target()
        let decision = baselineDecision(
            for: target, spec: FetchSpec(), upstream: upstream, existing: existing, mergeAllOnFirstSync: false
        )
        _ = commitCatalogSync(decision.entry, for: target, save: save)
        return decision.newModels
    }}

{catalog}
}}

enum APIProviderSharedKey {{
    static let models = "models"
}}

struct ProxyConfiguration {{
    struct ModelPricing: Equatable {{
        struct Source: Equatable {{
            enum Kind {{ case modelsDev }}
            var kind: Kind = .modelsDev
        }}
        var hasAnyRate = false
        var source: Source? = nil
    }}
    struct MappedModel: Equatable {{
        var name: String
        var pricing: ModelPricing = .init()
    }}
    struct ModelCatalog: Equatable {{
        var models: [String]
        var pricingOverrides: [String: ModelPricing] = [:]
        var supports1MModels: Set<String> = []
        init(models: [String], pricingOverrides: [String: ModelPricing] = [:], supports1MModels: Set<String> = []) {{
            self.models = models
            self.pricingOverrides = pricingOverrides
            self.supports1MModels = supports1MModels
        }}
        init(mappedModels: [MappedModel]) {{
            self.models = mappedModels.map(\\.name)
        }}
    }}
}}

struct OpenCodeModelEntry: Equatable {{
    var id: String
    var inputModalities: [String] = []
    var outputModalities: [String] = []
    var hasPricing = false
    var pricingSource: ProxyConfiguration.ModelPricing.Source? = nil
}}

struct OpenCodeNode: Equatable {{
    enum Currency: Equatable {{ case none, usd }}
    let id: String
    var baseURL: String = "https://api.example.test/v1"
    var linkedProviderId: String?
    var overriddenKeys: Set<String>? = nil
    var defaultModel: String = ""
    var modelEntries: [OpenCodeModelEntry] = []
    var pricingCurrency: Currency = .none
    var models: [String] {{ modelEntries.map(\\.id) }}
}}

struct NodeProfile: Equatable {{
    struct Proxy: Equatable {{
        var modelCatalog: ProxyConfiguration.ModelCatalog
    }}
    struct Metadata: Equatable {{
        enum NodeType {{ case codexProxy, anthropicDirect; var isCodex: Bool {{ self == .codexProxy }} }}
        var id: String
        var nodeType: NodeType = .codexProxy
        var linkedProviderId: String?
        var overriddenKeys: Set<String>? = nil
        var proxy: Proxy
    }}
    var id: String {{ metadata.id }}
    var metadata: Metadata
}}

struct APIProvider: Equatable {{
    enum Format {{ case openAI, anthropic }}
    let id: String
    var baseURL: String = "https://api.example.test/v1"
    var apiKey: String = "k"
    var format: Format = .openAI
    var models: [ProxyConfiguration.MappedModel] = []
}}

enum UpstreamModelListClient {{
    static func upstreamIdentity(baseURL: String) -> String {{ baseURL }}
}}
enum ModelsDevPricingService {{
    struct Catalog {{}}
    static func pricingMap(models: [String], upstreamBaseURL: String, in: Catalog) -> [String: ProxyConfiguration.ModelPricing] {{ [:] }}
}}
enum PublicPriceUpdate {{
    static func dominantCurrency(_: [ProxyConfiguration.ModelPricing]) -> String {{ "USD" }}
    static func updatedPricing(forProviderModel: ProxyConfiguration.ModelPricing, candidate: ProxyConfiguration.ModelPricing?, targetCurrency: String) -> ProxyConfiguration.ModelPricing? {{ nil }}
    static func updatedEntry(_: OpenCodeModelEntry, nodeCurrency _: OpenCodeNode.Currency, candidate _: ProxyConfiguration.ModelPricing?) -> OpenCodeModelEntry? {{ nil }}
}}
enum APIProviderCPALoopGuard {{
    static func blockReason(for _: APIProvider) -> String? {{ nil }}
}}

@MainActor
final class APIProviderStore {{
    static let shared = APIProviderStore()
    var providers: [String: APIProvider] = [:]
    var failNextSave = false
    func provider(id: String) -> APIProvider? {{ providers[id] }}
    func saveCatalogUpdate(_ provider: APIProvider) -> Bool {{
        guard !failNextSave else {{ return false }}
        providers[provider.id] = provider
        return true
    }}
}}

@MainActor
final class ProxyViewModel {{
    static let shared = ProxyViewModel()
    var profiles: [String: NodeProfile] = [:]
    var failingIDs: Set<String> = []
    var updateCalls: [String] = []
    func applyModelCatalogUpdate(nodeID: String, catalog: ProxyConfiguration.ModelCatalog) -> Bool {{
        updateCalls.append(nodeID)
        guard !failingIDs.contains(nodeID), var profile = profiles[nodeID] else {{ return false }}
        profile.metadata.proxy.modelCatalog = catalog
        profiles[nodeID] = profile
        return true
    }}
}}

@MainActor
final class OpenCodeNodeStore {{
    private static var _shared: OpenCodeNodeStore?
    static var initCount = 0
    static var shared: OpenCodeNodeStore {{
        if let existing = _shared {{ return existing }}
        initCount += 1
        let store = OpenCodeNodeStore()
        _shared = store
        return store
    }}
    static func resetForTest() {{
        _shared = nil
        initCount = 0
    }}
    var nodes: [OpenCodeNode] = []
    var failingIDs: Set<String> = []
    var saveCalls = 0
    var reapplyCount = 0
    func saveCatalogUpdate(_ node: OpenCodeNode) -> Bool {{
        saveCalls += 1
        guard !failingIDs.contains(node.id),
              let idx = nodes.firstIndex(where: {{ $0.id == node.id }}) else {{ return false }}
        nodes[idx] = node
        reapplyCount += 1
        return true
    }}
}}

@MainActor
final class APIProviderDistributor {{
    static let shared = APIProviderDistributor()
    struct CPALinks {{ func hasLink(for _: String) -> Bool {{ false }} }}
    var containmentFencedProviderIds: Set<String> = []
    var providerWriteGeneration: [String: UInt64] = [:]
    private var lockedProviderIds: Set<String> = []
    private var providerWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    var proxyVM: ProxyViewModel {{ ProxyViewModel.shared }}
    var openCodeStore: OpenCodeNodeStore {{ OpenCodeNodeStore.shared }}
    var cpaLinks = CPALinks()
    private func isWriteAuthorized(for _: String, generation _: UInt64) -> Bool {{ true }}
    func hasWaiter(for providerId: String) -> Bool {{
        !(providerWaiters[providerId]?.isEmpty ?? true)
    }}
    func holdProviderLock(
        for providerId: String,
        onAcquired: @MainActor () -> Void,
        waitRelease: @MainActor () async -> Void
    ) async {{
        await withProviderSerialization(for: providerId) {{
            onAcquired()
            await waitRelease()
        }}
    }}
    private func codexChild(for providerId: String) -> NodeProfile? {{
        proxyVM.profiles.values.first {{ $0.metadata.linkedProviderId == providerId && $0.metadata.nodeType.isCodex }}
    }}
    private func claudeChild(for providerId: String) -> NodeProfile? {{
        proxyVM.profiles.values.first {{ $0.metadata.linkedProviderId == providerId && !$0.metadata.nodeType.isCodex }}
    }}
    private func openCodeChild(for providerId: String) -> OpenCodeNode? {{
        openCodeStore.nodes.first {{ $0.linkedProviderId == providerId }}
    }}
    private static func openCodeEntries(from models: [ProxyConfiguration.MappedModel]) -> [OpenCodeModelEntry] {{
        models.map {{ OpenCodeModelEntry(id: $0.name) }}
    }}
    private func upsertCPAChild(_: APIProvider, writeGeneration _: UInt64?) async {{}}

{serialize_fn}

{propagate_fn}
}}

@MainActor
final class ModelSyncHarness {{
    private enum Target: Hashable {{
        case provider(String)
        case openCode(String)
        var stateKey: String {{
            switch self {{
            case .provider(let id): return "provider:\\(id)"
            case .openCode(let id): return "opencode:\\(id)"
            }}
        }}
    }}
    private struct FetchSpec {{ let upstreamIdentity = "https://api.example.test/v1" }}
    private struct FetchedUpstream {{ let spec: FetchSpec; let models: [String] }}
    private enum UpstreamOutcome {{ case success(FetchSpec, [String]); case failure(String); case skipped }}
    private var state = StateFile()
    var nextUpstreamModels: [String] = []
    var onFetchUpstream: (@MainActor () async -> Void)? = nil

    func reset() {{
        state = StateFile()
        nextUpstreamModels = []
        onFetchUpstream = nil
    }}

    func runProviderSync(_ id: String) async -> Report {{
        await syncProvider(id, priceCatalog: nil)
    }}

    func runOpenCodeSync(_ id: String) async -> Report {{
        await syncOpenCode(id, priceCatalog: nil)
    }}

    func flash(for report: Report, failures: Int, subject: String?) -> AppFlash {{
        summaryFlash(for: report, failures: failures, subject: subject)
    }}

    private func linkedProvider(_ id: String?) -> APIProvider? {{
        id.flatMap {{ APIProviderStore.shared.provider(id: $0) }}
    }}

    private func fetchUpstream(for _: Target) async -> FetchedUpstream? {{
        await onFetchUpstream?()
        return FetchedUpstream(spec: FetchSpec(), models: nextUpstreamModels)
    }}
    private func currentUpstreamResult(_ fetched: FetchedUpstream?, for _: Target) -> UpstreamOutcome {{
        guard let fetched else {{ return .skipped }}
        return .success(fetched.spec, fetched.models)
    }}

{catalog}

{sync_provider_fn}

{sync_opencode_fn}
}}
""")
PY
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$ROOT/scripts/MasterPlanRegression.swift" "$TEMP/AppRegressionFixture.swift" -o "$TEMP/regression"
"$TEMP/regression"
