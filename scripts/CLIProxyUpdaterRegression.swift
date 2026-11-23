import CryptoKit
import Darwin
import Foundation
import QuotaBackend

nonisolated private struct NoopSigner: CLIProxyBinarySigning {
    func sign(binaryAt url: URL) throws {}
}

nonisolated private struct NoopValidator: CLIProxyBinaryValidating {
    func validate(binaryAt url: URL, architecture: CLIProxyArchitecture) async throws {}
}

@main
struct CLIProxyUpdaterRegression {
    static func main() async throws {
        try testReleaseSelection()
        try testVersionRules()
        try testClaudeCompatibilityAliasCanonicalization()
        try testUnifiedCatalogDeduplicatesProtocolAliases()
        try testCatalogPreservesPerFormatRouteIDs()
        try testCaseAndWhitespaceCanonicalMerge()
        try testProviderResolutionPrefersOwnedBy()
        try testDisplayNameEnrichmentDoesNotChangeIdentity()
        try testUnknownCustomProviderUsesNeutralBrand()
        try testInvalidClaudeAliasIsNotDecoded()
        try testThinkingSuffixIsPreserved()
        try testSettingsThreeWayMerge()
        try testRuntimeConfiguration()
        try testDefaultPluginDirectoryUpgradeMigration()
        try testCredentialAdapters()
        try await testGeminiCredentialBridge()
        try testCanonicalCredentialFingerprint()
        try testSyncManifestValidation()
        try testCodexIdentityKeepsPlansSeparate()
        try testCodexIdentityParityAndPlanChanges()
        try testCodexManagedCopiesDeduplicateSafely()
        try testAntigravityManagedCopiesDeduplicate()
        try testWeakIdentityNeverDeduplicates()
        try testManagedCopyConflictsAreNeverDeleted()
        try testExpandedAuthFileDecoding()
        try testDynamicProviderModels()
        try await testVersionedInstallAndRollback()
        try testDuplicateBinaryArchiveIsRejected()
        try testCodexGoFreePolicy()
        try await testABARollbackCommitIdentity()
        try await testLockedVersionDelete()
        try await testHeldBuildLeavesLegacyAuthUntouched()
        if CommandLine.arguments.contains("--live") {
            try await testLatestOfficialReleaseEndToEnd()
        }
        print("CLIProxy updater regression passed")
    }

    private static func testReleaseSelection() throws {
        let digest = String(repeating: "a", count: 64)
        let json = """
        {
          "tag_name": "v7.2.67",
          "name": "v7.2.67",
          "body": "release notes",
          "prerelease": false,
          "published_at": "2026-07-11T19:29:42Z",
          "assets": [
            {
              "name": "CLIProxyAPI_7.2.67_darwin_aarch64_no-plugin.tar.gz",
              "browser_download_url": "https://example.invalid/no-plugin.tar.gz",
              "digest": "sha256:\(digest)",
              "size": 1
            },
            {
              "name": "CLIProxyAPI_7.2.67_darwin_aarch64.tar.gz",
              "browser_download_url": "https://example.invalid/full.tar.gz",
              "digest": "sha256:\(digest)",
              "size": 123
            },
            {
              "name": "CLIProxyAPI_7.2.67_darwin_amd64.tar.gz",
              "browser_download_url": "https://example.invalid/intel.tar.gz",
              "digest": "sha256:\(digest)",
              "size": 456
            }
          ]
        }
        """
        let release = try CLIProxyReleaseClient.decodeRelease(Data(json.utf8), architecture: .arm64)
        try expect(release.version == "7.2.67", "version prefix was not normalized")
        try expect(release.assetName == "CLIProxyAPI_7.2.67_darwin_aarch64.tar.gz", "full plugin asset was not selected")
        try expect(release.size == 123, "wrong architecture asset selected")
    }

    private static func testVersionRules() throws {
        try expect(CLIProxyVersion.isNewer("7.2.67", than: "7.2.9"), "semantic version comparison failed")
        try expect(CLIProxyVersion.compare("v7.2.67", "7.2.67") == .orderedSame, "v prefix normalization failed")
        try expect(!CLIProxyVersion.isSafePathComponent("../7.2.67"), "path traversal version was accepted")
        try expect(!CLIProxyVersion.isSafePathComponent("7.2.67/evil"), "nested version path was accepted")
    }

    private static func testClaudeCompatibilityAliasCanonicalization() throws {
        let routeID = "claude-fable-5-dd-2-egami-tpg"
        try expect(
            CLIProxyModelIdentity.canonicalID(for: routeID, protocol: .anthropic) == "gpt-image-2",
            "Anthropic compatibility alias did not decode to its canonical model ID"
        )
    }

    private static func testUnifiedCatalogDeduplicatesProtocolAliases() throws {
        let openAIModels = [
            CLIProxyModel(id: "gpt-image-2", ownedBy: "openai")
        ]
        let snapshot = CLIProxyModelCatalogBuilder.build(
            openAIModels: openAIModels,
            anthropicModels: [
                CLIProxyModel(
                    id: "claude-fable-5-dd-2-egami-tpg",
                    displayName: "GPT Image 2",
                    ownedBy: "openai"
                )
            ],
            geminiModels: [
                CLIProxyModel(id: "gpt-image-2", displayName: "GPT Image 2", ownedBy: "openai")
            ]
        )

        try expect(snapshot.openAIModels == openAIModels, "catalog builder modified the OpenAI distribution source")
        try expect(snapshot.entries.count == 1, "one model exposed through three API formats was duplicated")
        guard let entry = snapshot.entries.first else {
            throw RegressionFailure("unified catalog unexpectedly had no entries")
        }
        try expect(entry.model.id == "gpt-image-2", "unified catalog did not retain the canonical model ID")
        try expect(
            entry.protocols == Set([.openAI, .anthropic, .gemini]),
            "unified catalog did not retain every API format"
        )
    }

    private static func testCatalogPreservesPerFormatRouteIDs() throws {
        let anthropicRoute = "claude-fable-5-dd-2-egami-tpg"
        let caseVariantAnthropicRoute = "claude-fable-5-dd-2-EGAMI-TPG"
        let snapshot = CLIProxyModelCatalogBuilder.build(
            openAIModels: [CLIProxyModel(id: "gpt-image-2", ownedBy: "openai")],
            anthropicModels: [
                CLIProxyModel(id: anthropicRoute, ownedBy: "openai"),
                CLIProxyModel(id: caseVariantAnthropicRoute, ownedBy: "openai")
            ],
            geminiModels: [CLIProxyModel(id: "gpt-image-2", ownedBy: "google")]
        )
        guard let entry = snapshot.entries.first else {
            throw RegressionFailure("route preservation catalog unexpectedly had no entries")
        }

        try expect(entry.models(for: .openAI).map(\.id) == ["gpt-image-2"], "OpenAI route ID was lost")
        try expect(
            Set(entry.models(for: .anthropic).map(\.id)) == Set([anthropicRoute, caseVariantAnthropicRoute]),
            "distinct Anthropic route aliases were lost"
        )
        try expect(entry.models(for: .gemini).map(\.id) == ["gpt-image-2"], "Gemini route ID was lost")
        try expect(
            entry.routeID(for: .anthropic).map {
                Set([anthropicRoute, caseVariantAnthropicRoute]).contains($0)
            } == true,
            "preferred Anthropic route ID was wrong"
        )
    }

    private static func testCaseAndWhitespaceCanonicalMerge() throws {
        let openAIModels = [CLIProxyModel(id: "  GPT-IMAGE-2  ", ownedBy: "openai")]
        let snapshot = CLIProxyModelCatalogBuilder.build(
            openAIModels: openAIModels,
            anthropicModels: [
                CLIProxyModel(id: "claude-fable-5-dd-2-egami-tpg", ownedBy: "openai")
            ],
            geminiModels: [CLIProxyModel(id: "gpt-image-2", ownedBy: "google")]
        )

        try expect(snapshot.openAIModels == openAIModels, "OpenAI source whitespace was not preserved verbatim")
        try expect(snapshot.entries.count == 1, "case or surrounding whitespace produced duplicate catalog entries")
        try expect(snapshot.entries.first?.model.id == "GPT-IMAGE-2", "canonical display ID was not trimmed")
    }

    private static func testProviderResolutionPrefersOwnedBy() throws {
        let explicitOpenAI = CLIProxyModel(
            id: "claude-looking-route",
            displayName: "Gemini Looking Name",
            ownedBy: "openai"
        )
        try expect(
            CLIProxyModelBrandResolver.providerID(for: explicitOpenAI) == "openai",
            "owned_by did not take precedence when resolving the model brand"
        )

        let explicitGoogle = CLIProxyModel(id: "gpt-looking-model", ownedBy: "google")
        try expect(
            CLIProxyModelBrandResolver.providerID(for: explicitGoogle) == "gemini",
            "Google owned_by did not take precedence over the canonical model ID"
        )

        let explicitXAI = CLIProxyModel(id: "vendor-model", ownedBy: "xai")
        try expect(
            CLIProxyModelBrandResolver.providerID(for: explicitXAI) == "xai",
            "xAI owned_by did not resolve to the xAI brand"
        )

        let grokFallback = CLIProxyModel(id: "grok-4-fast", ownedBy: "custom-router")
        try expect(
            CLIProxyModelBrandResolver.providerID(for: grokFallback) == "xai",
            "Grok model ID did not resolve to the xAI brand"
        )

        let canonicalFallback = CLIProxyModel(id: "gpt-5", ownedBy: "antigravity")
        try expect(
            CLIProxyModelBrandResolver.providerID(for: canonicalFallback) == "openai",
            "canonical model ID was not used after an unrecognized owned_by"
        )

        let displayFallback = CLIProxyModel(id: "vendor-alpha", displayName: "Claude Alpha")
        try expect(
            CLIProxyModelBrandResolver.providerID(for: displayFallback) == "claude",
            "display name was not used as the final brand hint"
        )
    }

    private static func testDisplayNameEnrichmentDoesNotChangeIdentity() throws {
        let snapshot = CLIProxyModelCatalogBuilder.build(
            openAIModels: [CLIProxyModel(id: "gpt-5", ownedBy: "openai")],
            anthropicModels: [
                CLIProxyModel(
                    id: "claude-fable-5-dd-5-tpg",
                    displayName: "GPT 5",
                    ownedBy: "openai"
                )
            ],
            geminiModels: nil
        )
        guard let entry = snapshot.entries.first else {
            throw RegressionFailure("metadata enrichment catalog unexpectedly had no entries")
        }
        try expect(entry.model.id == "gpt-5", "display metadata changed the canonical model identity")
        try expect(entry.model.displayName == "GPT 5", "richer display metadata was not retained")
        try expect(entry.providerID == "openai", "enriched model resolved to the wrong provider brand")
    }

    private static func testUnknownCustomProviderUsesNeutralBrand() throws {
        let model = CLIProxyModel(id: "acme-alpha", displayName: "Acme Alpha", ownedBy: "acme")
        try expect(
            CLIProxyModelBrandResolver.providerID(for: model) == "cliproxyapi",
            "unknown custom provider did not use the neutral CPA brand"
        )
    }

    private static func testInvalidClaudeAliasIsNotDecoded() throws {
        let wrongCase = "Claude-fable-5-dd-o4-tpg"
        try expect(
            CLIProxyModelIdentity.canonicalID(for: wrongCase, protocol: .anthropic) == wrongCase,
            "non-exact Anthropic alias prefix was decoded"
        )

        let emptyPayload = CLIProxyModelIdentity.anthropicCompatibilityPrefix
        try expect(
            CLIProxyModelIdentity.canonicalID(for: emptyPayload, protocol: .anthropic) == emptyPayload,
            "empty Anthropic alias payload was decoded"
        )

        let validAliasOnWrongAPI = "claude-fable-5-dd-o4-tpg"
        try expect(
            CLIProxyModelIdentity.canonicalID(for: validAliasOnWrongAPI, protocol: .openAI) == validAliasOnWrongAPI,
            "Anthropic alias was decoded outside the Anthropic API format"
        )
    }

    private static func testThinkingSuffixIsPreserved() throws {
        let routeID = "claude-fable-5-dd-o4-tpg(high)"
        try expect(
            CLIProxyModelIdentity.canonicalID(for: routeID, protocol: .anthropic) == "gpt-4o(high)",
            "Anthropic compatibility alias lost its thinking suffix"
        )
    }

    private static func testSettingsThreeWayMerge() throws {
        let base = CLIProxyGatewaySettings.default
        var draft = base
        draft.port = 14_421
        var external = base
        external.enablePlugins = true
        let merged = draft.mergingExternalChange(from: base, to: external)
        try expect(merged.port == 14_421, "three-way settings merge discarded the local port edit")
        try expect(merged.enablePlugins, "three-way settings merge discarded the external plugin change")
    }

    private static func makeScratchRoot(_ prefix: String) throws -> URL {
        let base = CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") })
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? TokenSaverSettingsStore.resolvedTemporaryDirectory()
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.resolvingSymlinksInPath().standardizedFileURL
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
    }

    private static func testHeldBuildLeavesLegacyAuthUntouched() async throws {
        try expect(!CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
                   "[Finding #2] Test assumes subscriptions are disabled in held build")
        let fileManager = FileManager.default
        let absentRoot = try makeScratchRoot("AIUsage-CPA-Held-Absent")
        defer { try? fileManager.removeItem(at: absentRoot) }
        let absentPaths = try CLIProxyPaths(root: absentRoot)
        try absentPaths.prepare(fileManager: fileManager)
        try CLIProxyConfigStore(paths: absentPaths).saveSettings(.default)
        _ = try await CLIProxyBinaryStore(paths: absentPaths).currentVersion()
        try expect(!fileManager.fileExists(atPath: absentPaths.authDirectory.path),
                   "[Finding #2] Held build prepare must not create missing legacy auth/")
        for runtimeDir in [
            absentPaths.root,
            absentPaths.versionsDirectory,
            absentPaths.isolatedAuthDirectory,
            absentPaths.runtimeWorkingDirectory,
            absentPaths.runtimeTempDirectory,
            absentPaths.pluginsDirectory,
            absentPaths.logsDirectory
        ] {
            let mode = (try fileManager.attributesOfItem(atPath: runtimeDir.path)[.posixPermissions] as? NSNumber)?.intValue
            try expect(mode == 0o700, "[Finding #2] Active runtime directory \(runtimeDir.lastPathComponent) must have mode 0700")
        }

        let existingRoot = try makeScratchRoot("AIUsage-CPA-Held-Existing")
        defer { try? fileManager.removeItem(at: existingRoot) }
        let existingPaths = try CLIProxyPaths(root: existingRoot)
        try fileManager.createDirectory(
            at: existingPaths.authDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o750]
        )
        let seedFile = existingPaths.authDirectory.appendingPathComponent("legacy.json")
        let seedBytes = Data(#"{"type":"codex","email":"keep@example.invalid"}"#.utf8)
        try seedBytes.write(to: seedFile)
        try fileManager.setAttributes([.posixPermissions: 0o640], ofItemAtPath: seedFile.path)

        var dirBefore = stat()
        try expect(lstat(existingPaths.authDirectory.path, &dirBefore) == 0, "[Finding #2] lstat on seeded auth/ failed")
        var fileBefore = stat()
        try expect(lstat(seedFile.path, &fileBefore) == 0, "[Finding #2] lstat on seeded legacy.json failed")

        try existingPaths.prepare(fileManager: fileManager)
        try CLIProxyConfigStore(paths: existingPaths).saveSettings(.default)
        _ = try await CLIProxyBinaryStore(paths: existingPaths).currentVersion()

        var dirAfter = stat()
        try expect(lstat(existingPaths.authDirectory.path, &dirAfter) == 0, "[Finding #2] lstat after prepare failed")
        try expect((dirAfter.st_mode & 0o777) == 0o750, "[Finding #2] Held build prepare altered legacy auth/ permissions")
        try expect(
            dirAfter.st_ctimespec.tv_sec == dirBefore.st_ctimespec.tv_sec
                && dirAfter.st_ctimespec.tv_nsec == dirBefore.st_ctimespec.tv_nsec
                && dirAfter.st_mtimespec.tv_sec == dirBefore.st_mtimespec.tv_sec
                && dirAfter.st_mtimespec.tv_nsec == dirBefore.st_mtimespec.tv_nsec,
            "[Finding #2] Held build prepare touched existing legacy auth/ inode metadata"
        )
        var fileAfter = stat()
        try expect(lstat(seedFile.path, &fileAfter) == 0 && (fileAfter.st_mode & 0o777) == 0o640,
                   "[Finding #2] Legacy credential file metadata changed")
        let seedAfterBytes = try Data(contentsOf: seedFile)
        try expect(seedAfterBytes == seedBytes, "[Finding #2] Legacy credential bytes changed")

        try absentPaths.prepare(includeLegacyAuthDirectory: true, fileManager: fileManager)
        let optInMode = (try fileManager.attributesOfItem(atPath: absentPaths.authDirectory.path)[.posixPermissions] as? NSNumber)?.intValue
        try expect(optInMode == 0o700, "[Finding #2] Explicit includeLegacyAuthDirectory creates auth/ with mode 0700")
    }

    private static func testRuntimeConfiguration() throws {
        let root = try makeScratchRoot("AIUsage-CPA-Config")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try CLIProxyPaths(root: root)
        let store = CLIProxyConfigStore(paths: paths)
        var settings = CLIProxyGatewaySettings.default
        settings.port = 14_420
        settings.routingStrategy = .fillFirst
        settings.requestRetry = 4
        settings.maxRetryCredentials = 4
        settings.quotaSwitchPreviewModel = true
        settings.proxyURL = "http://127.0.0.1:7890/\"quoted"
        settings.enablePlugins = true
        try store.saveSettings(settings)
        try store.writeRuntimeConfig(
            settings: settings,
            secrets: CLIProxySecrets(managementKey: "management-secret", clientAPIKey: "client-secret")
        )
        try expect(store.loadSettings().normalized == settings.normalized, "gateway settings did not round-trip")
        let config = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(config.contains("strategy: \"fill-first\""), "routing strategy was not generated")
        try expect(config.contains("host: \"127.0.0.1\""), "loopback-only host was not generated by default")
        try expect(config.contains("auth-dir: \"\(paths.isolatedAuthDirectory.path)\""), "[§39.1] API-key-only config must point auth-dir to isolated empty runtime-auth")
        try expect(!config.contains("auth-dir: \"\(paths.authDirectory.path)\""), "[§39.1] runtime config must never point auth-dir to legacy auth/")
        try expect(config.contains("request-retry: 0"), "[§37.3] retry count must be enforced to 0")
        try expect(config.contains("max-retry-interval: 30"), "max retry interval was not generated")
        try expect(config.contains("max-retry-credentials: 1"), "[§37.3] max retry credentials must be enforced to 1")
        try expect(config.contains("switch-project: false"), "quota switch-project was not forced off for TOS protection")
        try expect(config.contains("switch-preview-model: false"), "[§37.3] quota switch-preview-model must be enforced off")
        try expect(config.contains("antigravity-credits: false"), "quota antigravity-credits was not forced off for TOS protection")
        try expect(config.contains("kv-store:\n  disabled: true"), "[§39.1] API-key-only runtime config must disable kv-store so runtime-auth stays empty")
        try expect(config.contains("plugins:\n  enabled: false\n  dir: \"\(paths.pluginsDirectory.path)\""), "[§39.3] API-key-only runtime config must keep plugins disabled")
        try expect(config.contains("management-secret"), "management secret was not generated")
        try expect(config.contains("client-secret"), "client key was not generated")
        try expect(config.contains("ws-auth: true"), "WebSocket client authentication was not enabled")
        try expect(config.contains("\\\"quoted"), "YAML string was not escaped")
        try expect(config.contains("dir: \"\(paths.pluginsDirectory.path)\""), "stable plugin directory was not generated")

        let migrated = try JSONDecoder().decode(
            CLIProxyGatewaySettings.self,
            from: Data(#"{"port":14420,"autoStart":true,"routingStrategy":"round-robin","requestRetry":2,"proxyURL":"","enablePlugins":false}"#.utf8)
        ).normalized
        try expect(!migrated.allowLANAccess, "legacy settings did not migrate to LAN access disabled")
        try expect(!migrated.quotaSwitchProject, "legacy settings did not default quota switch-project off for TOS protection")
        try expect(!migrated.quotaSwitchPreviewModel, "legacy settings did not enforce preview model fallback off")
        try expect(!migrated.quotaAntigravityCredits, "legacy settings did not default quota antigravity-credits off for TOS protection")
        try expect(migrated.requestRetry == 0 && migrated.maxRetryCredentials == 1, "legacy settings did not enforce zero failover")
        try expect(migrated.maxRetryInterval == 30, "legacy settings did not default max-retry-interval to 30")

        // [§8.2 + §37.3 + §39.3] Persisted v1/v2/v3 state.json with retries/plugins/preview fallback
        // must normalize to v4 API-key-only zero-failover while keeping unrelated user prefs and official API upstreams intact.
        let v1Root = try makeScratchRoot("AIUsage-CPA-V1")
        defer { try? FileManager.default.removeItem(at: v1Root) }
        let v1Paths = try CLIProxyPaths(root: v1Root)
        let v1Store = CLIProxyConfigStore(paths: v1Paths)
        try v1Paths.prepare()
        for (label, versionLine) in [("v1", ""), ("v2", #"  "settingsVersion": 2,"#), ("v3", #"  "settingsVersion": 3,"#)] {
            let persistedState = """
            {
              "version": 1,
            \(versionLine)
              "settings": {
                "port": 14425,
                "autoStart": true,
                "allowLANAccess": false,
                "routingStrategy": "fill-first",
                "requestRetry": 4,
                "maxRetryInterval": 30,
                "maxRetryCredentials": 4,
                "quotaSwitchProject": true,
                "quotaSwitchPreviewModel": true,
                "quotaAntigravityCredits": true,
                "proxyURL": "",
                "enablePlugins": true,
                "accountModelProbeEnabled": true,
                "accountModelProbeIntervalSeconds": 60
              }
            }
            """
            try Data(persistedState.utf8).write(to: v1Paths.stateURL, options: .atomic)
            let loaded = v1Store.loadSettingsWithMigrationState()
            try expect(loaded.migratedFromLegacyV1, "persisted \(label) state.json must trigger fail-closed migration")
            try expect(loaded.settings.port == 14_425 && loaded.settings.autoStart, "\(label) migration must preserve non-failover settings")
            try expect(loaded.settings.routingStrategy == .fillFirst, "\(label) migration must preserve routing strategy")
            try expect(loaded.settings.requestRetry == 0, "[§37.3] \(label) migration must reset requestRetry to 0")
            try expect(loaded.settings.maxRetryCredentials == 1, "[§37.3] \(label) migration must bound maxRetryCredentials to 1")
            try expect(!loaded.settings.quotaSwitchPreviewModel, "[§37.3] \(label) migration must disable quotaSwitchPreviewModel")
            try expect(!loaded.settings.enablePlugins, "[§39.3] \(label) migration must disable plugins in API-key-only build")
            try expect(!loaded.settings.quotaSwitchProject && !loaded.settings.quotaAntigravityCredits,
                       "\(label) migration must keep switch-project and antigravity-credits disabled")

            try Data("""
            openai-compatibility:
              - name: official-openai-api
                base-url: https://api.openai.com/v1
            """.utf8).write(to: v1Paths.configURL, options: .atomic)
            let v1Secrets = CLIProxySecrets(managementKey: "mgmt-v1", clientAPIKey: "cpa-client-v1")
            try v1Store.writeRuntimeConfig(settings: loaded.settings, secrets: v1Secrets)
            let migratedYAML = try String(contentsOf: v1Paths.configURL, encoding: .utf8)
            try expect(migratedYAML.contains("official-openai-api"), "writing hardened config must preserve official API routes")
            try expect(migratedYAML.contains("request-retry: 0") && migratedYAML.contains("max-retry-credentials: 1") && migratedYAML.contains("switch-preview-model: false"),
                       "[§37.3] \(label) generated YAML must enforce zero-failover profile")
            try expect(migratedYAML.contains("auth-dir: \"\(v1Paths.isolatedAuthDirectory.path)\""),
                       "[§39.1] \(label) generated YAML must enforce isolated auth-dir")
            try expect(v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "runtimeConfigMatches must return true for matching hardened config")

            let tamperedYAML = migratedYAML.replacingOccurrences(of: "request-retry: 0", with: "request-retry: 3")
            try Data(tamperedYAML.utf8).write(to: v1Paths.configURL, options: .atomic)
            try expect(!v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "[§37.3] runtimeConfigMatches must reject YAML with non-zero request-retry")

            let tamperedAuthYAML = migratedYAML.replacingOccurrences(
                of: v1Paths.isolatedAuthDirectory.path,
                with: v1Paths.authDirectory.path
            )
            try Data(tamperedAuthYAML.utf8).write(to: v1Paths.configURL, options: .atomic)
            try expect(!v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "[§39.1] runtimeConfigMatches must reject YAML pointing to legacy authDirectory")

            let tamperedCoolingYAML = migratedYAML.replacingOccurrences(of: "disable-cooling: false", with: "disable-cooling: true")
            try Data(tamperedCoolingYAML.utf8).write(to: v1Paths.configURL, options: .atomic)
            try expect(!v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "[§39.2] runtimeConfigMatches must reject YAML with disable-cooling: true")

            let tamperedCooldownFileYAML = migratedYAML.replacingOccurrences(of: "save-cooldown-status: false", with: "save-cooldown-status: true")
            try Data(tamperedCooldownFileYAML.utf8).write(to: v1Paths.configURL, options: .atomic)
            try expect(!v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "[§39.1] runtimeConfigMatches must reject YAML with save-cooldown-status: true")

            let tamperedKVStoreYAML = migratedYAML.replacingOccurrences(
                of: "kv-store:\n  disabled: true",
                with: "kv-store:\n  disabled: false"
            )
            try Data(tamperedKVStoreYAML.utf8).write(to: v1Paths.configURL, options: .atomic)
            try expect(!v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "[§39.1] runtimeConfigMatches must reject YAML with kv-store.disabled: false")

            let tamperedPluginYAML = migratedYAML.replacingOccurrences(of: "enabled: false", with: "enabled: true")
            try Data(tamperedPluginYAML.utf8).write(to: v1Paths.configURL, options: .atomic)
            try expect(!v1Store.runtimeConfigMatches(settings: loaded.settings, secrets: v1Secrets),
                       "[§39.3] runtimeConfigMatches must reject YAML with plugins enabled")
            try Data(migratedYAML.utf8).write(to: v1Paths.configURL, options: .atomic)

            var mismatchedSettings = loaded.settings
            mismatchedSettings.maxRetryInterval = 99
            try expect(!v1Store.runtimeConfigMatches(settings: mismatchedSettings, secrets: v1Secrets),
                       "runtimeConfigMatches must reject stale retry interval mismatch")

            // Post-upgrade v4 explicit save must persist cleanly without re-running migration
            try v1Store.saveSettings(loaded.settings)
            let v4Check = v1Store.loadSettingsWithMigrationState()
            try expect(!v4Check.migratedFromLegacyV1, "saved v4 state must not re-run legacy migration")
        }
        let v1Secrets = CLIProxySecrets(managementKey: "mgmt-v1", clientAPIKey: "cpa-client-v1")
        try v1Store.writeRuntimeConfig(settings: v1Store.loadSettings(), secrets: v1Secrets)

        let v8CooldownConfig = """
        config-version: 8
        disable-cooling: false
        save-cooldown-status: false
        routing:
          cooldown:
            disable-cooling: true
            save-cooldown-status: true

        """
        for layout in [v8CooldownConfig, v8CooldownConfig.replacingOccurrences(of: "config-version: 8\n", with: "")] {
            try Data(layout.utf8).write(to: v1Paths.configURL, options: .atomic)
            try v1Store.writeRuntimeConfig(settings: v1Store.loadSettings(), secrets: v1Secrets)
            let hardenedV8 = try String(contentsOf: v1Paths.configURL, encoding: .utf8)
            try expect(hardenedV8.contains("    disable-cooling: false") && hardenedV8.contains("    save-cooldown-status: false"),
                       "[§41.2] Writer must turn off the effective v8 cooldown flags")
            try expect(!hardenedV8.contains("\ndisable-cooling:") && !hardenedV8.contains("\nsave-cooldown-status:"),
                       "[§41.2] Writer must remove obsolete flat cooldown aliases")
            try expect(v1Store.runtimeConfigMatches(settings: v1Store.loadSettings(), secrets: v1Secrets), "Hardened v8 config must match")
            for flag in ["disable-cooling", "save-cooldown-status"] {
                let unsafeV8 = hardenedV8.replacingOccurrences(of: "    \(flag): false", with: "    \(flag): true") + "\(flag): false\n"
                try Data(unsafeV8.utf8).write(to: v1Paths.configURL, options: .atomic)
                try expect(!v1Store.runtimeConfigMatches(settings: v1Store.loadSettings(), secrets: v1Secrets),
                           "[§41.2] Reject the unsafe native cooldown value even when the legacy alias is false")
            }
        }

        let generatedPluginBlock = "plugins:\n  enabled: false\n  dir: \"\(paths.pluginsDirectory.path)\""
        let persistedPluginBlock = """
        plugins:
          enabled: true
          dir: "legacy"
          store-sources:
            - https://store.example.invalid/index.json
          configs:
            gemini-cli:
              enabled: true
              custom-future-field: keep-me
        """
        let managementOwnedConfig = config
            .replacingOccurrences(of: "ws-auth: true", with: "ws-auth: false")
            .replacingOccurrences(
                of: "  - \"client-secret\"",
                with: """
                  - "client-secret"
                  - "external-client-key"
                  - "cpa-client-obsolete"
                  - "cpa-client-current"
                  - "cpa-client-current"
                """
            )
            .replacingOccurrences(of: generatedPluginBlock, with: persistedPluginBlock) + """

        openai-compatibility:
          - name: existing-upstream
            base-url: https://example.invalid/v1
            models:
              - name: model-a
                alias: model-a
                thinking:
                  type: levels
        """ + "\n"
        try managementOwnedConfig.write(to: paths.configURL, atomically: true, encoding: .utf8)

        let legacyVersionDirectory = try paths.versionDirectory("7.2.60")
        let activatedVersionDirectory = try paths.versionDirectory("7.2.61")
        let legacyPluginDirectory = legacyVersionDirectory.appendingPathComponent("legacy", isDirectory: true)
        let legacyProviderDirectory = legacyPluginDirectory.appendingPathComponent("provider-a", isDirectory: true)
        let legacyPluginFile = legacyProviderDirectory.appendingPathComponent("plugin.json")
        try FileManager.default.createDirectory(at: legacyProviderDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: activatedVersionDirectory, withIntermediateDirectories: true)
        try Data("legacy-plugin".utf8).write(to: legacyPluginFile)
        // Reproduce the real update order: activation has already switched current
        // to v2 before runtime config reconciliation sees v1's relative directory.
        try FileManager.default.createSymbolicLink(at: paths.currentSymlink, withDestinationURL: activatedVersionDirectory)

        let conflictingProviderDirectory = paths.pluginsDirectory
            .appendingPathComponent("provider-a", isDirectory: true)
        let conflictingPluginFile = conflictingProviderDirectory.appendingPathComponent("plugin.json")
        try FileManager.default.createDirectory(at: conflictingProviderDirectory, withIntermediateDirectories: true)
        try Data("different-plugin".utf8).write(to: conflictingPluginFile)
        settings.port = 14_421
        settings.enablePlugins = false
        settings.allowLANAccess = true
        do {
            try store.writeRuntimeConfig(
                settings: settings,
                secrets: CLIProxySecrets(
                    managementKey: "new-management-secret",
                    clientAPIKey: "cpa-client-current"
                )
            )
            throw RegressionFailure("conflicting legacy plugin migration was accepted")
        } catch is CLIProxyGatewayError {
            let unchanged = try String(contentsOf: paths.configURL, encoding: .utf8)
            let legacySourceAfterConflict = try Data(contentsOf: legacyPluginFile)
            try expect(unchanged == managementOwnedConfig, "plugin migration conflict rewrote the CPA config")
            try expect(
                legacySourceAfterConflict == Data("legacy-plugin".utf8),
                "plugin migration conflict changed the legacy source"
            )
        }
        try FileManager.default.removeItem(at: conflictingProviderDirectory)
        try store.writeRuntimeConfig(
            settings: settings,
            secrets: CLIProxySecrets(
                managementKey: "new-management-secret",
                clientAPIKey: "cpa-client-current"
            )
        )
        let merged = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(merged.contains("port: 14421"), "managed scalar was not updated")
        try expect(merged.contains("host: \"0.0.0.0\""), "LAN bind host was not generated")
        try expect(merged.contains("allow-remote: false"), "LAN access accidentally enabled remote management")
        try expect(merged.contains("existing-upstream"), "OpenAI-compatible config was erased on restart")
        try expect(merged.contains("thinking:"), "unknown nested provider fields were erased")
        try expect(merged.contains("store.example.invalid"), "plugin store sources were erased")
        try expect(merged.contains("gemini-cli:"), "plugin instance config was erased")
        try expect(merged.contains("custom-future-field: keep-me"), "unknown plugin fields were erased")
        try expect(merged.contains("enabled: false"), "managed plugin switch was not updated")
        try expect(merged.contains("dir: \"\(paths.pluginsDirectory.path)\""), "plugin directory was not stabilized")
        try expect(merged.contains("external-client-key"), "an external CPA client key was erased")
        try expect(merged.contains("client-secret"), "an existing unowned CPA client key was erased")
        try expect(!merged.contains("cpa-client-obsolete"), "a rotated AIUsage client key remained valid")
        try expect(
            occurrences(of: "cpa-client-current", in: merged) == 1,
            "the AIUsage client key was duplicated"
        )
        let runtimeKeys = try store.runtimeClientAPIKeys() ?? []
        try expect(runtimeKeys.contains("external-client-key"), "runtime client keys lost an external key")
        try expect(runtimeKeys.contains("client-secret"), "runtime client keys lost an unowned key")
        try expect(runtimeKeys.contains("cpa-client-current"), "runtime client keys lost the managed key")
        try expect(!runtimeKeys.contains("cpa-client-obsolete"), "runtime client keys returned a retired key")
        try expect(
            CLIProxyManagedAPIKeyNamespace.ownedKey(
                in: ["external-client-key", "cpa-client-current"],
                preferred: "debug-only-key"
            ) == "cpa-client-current",
            "runtime credential selection did not prefer an AIUsage-owned key"
        )
        try expect(
            CLIProxyManagedAPIKeyNamespace.ownedKey(
                in: ["external-client-key"],
                preferred: "debug-only-key"
            ) == nil,
            "runtime credential selection exposed an unowned external key"
        )
        try expect(merged.contains("ws-auth: true"), "an existing ws-auth false value was not tightened")
        try expect(!merged.contains("ws-auth: false"), "WebSocket authentication remained disabled")
        let migratedPluginFile = paths.pluginsDirectory
            .appendingPathComponent("provider-a", isDirectory: true)
            .appendingPathComponent("plugin.json")
        let migratedPluginData = try Data(contentsOf: migratedPluginFile)
        let legacyPluginData = try Data(contentsOf: legacyPluginFile)
        try expect(
            migratedPluginData == Data("legacy-plugin".utf8),
            "legacy relative plugins were not copied into the stable directory"
        )
        try expect(
            legacyPluginData == Data("legacy-plugin".utf8),
            "legacy plugin migration removed or changed its source"
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: paths.configURL.path)
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue
        try expect(permissions == 0o600, "runtime config permissions are not 0600")

        let externalPluginDirectory = root.appendingPathComponent("externally-managed-plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: externalPluginDirectory, withIntermediateDirectories: true)
        let absolutePluginConfig = merged.replacingOccurrences(
            of: "dir: \"\(paths.pluginsDirectory.path)\"",
            with: "dir: \"\(externalPluginDirectory.path)\""
        )
        try absolutePluginConfig.write(to: paths.configURL, atomically: true, encoding: .utf8)
        try store.writeRuntimeConfig(
            settings: settings,
            secrets: CLIProxySecrets(
                managementKey: "absolute-management-secret",
                clientAPIKey: "cpa-client-current"
            )
        )
        let absolutePreserved = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(
            absolutePreserved.contains("dir: \"\(externalPluginDirectory.path)\""),
            "an explicit absolute plugin directory was replaced"
        )

        settings.allowLANAccess = false
        try store.writeRuntimeConfig(
            settings: settings,
            secrets: CLIProxySecrets(managementKey: "final-management-secret", clientAPIKey: "final-client-secret")
        )
        let loopbackAgain = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(loopbackAgain.contains("host: \"127.0.0.1\""), "disabling LAN access did not restore loopback binding")

        let inlineSequenceConfig = """
        api-keys: ["external-client-key"]
        plugins:
          enabled: false
          dir: "\(externalPluginDirectory.path)"
        """ + "\n"
        try inlineSequenceConfig.write(to: paths.configURL, atomically: true, encoding: .utf8)
        do {
            try store.writeRuntimeConfig(
                settings: settings,
                secrets: CLIProxySecrets(
                    managementKey: "unsafe-management-secret",
                    clientAPIKey: "cpa-client-current"
                )
            )
            throw RegressionFailure("inline api-keys sequence was rewritten destructively")
        } catch is CLIProxyGatewayError {
            let unchanged = try String(contentsOf: paths.configURL, encoding: .utf8)
            try expect(unchanged == inlineSequenceConfig, "unsupported inline api-keys config was changed")
        }
    }

    private static func testDefaultPluginDirectoryUpgradeMigration() throws {
        let fileManager = FileManager.default
        let root = try makeScratchRoot("AIUsage-CPA-Default-Plugin-Migration")
        defer { try? fileManager.removeItem(at: root) }
        let paths = try CLIProxyPaths(root: root)
        try paths.prepare(fileManager: fileManager)

        let oldestVersion = try paths.versionDirectory("7.2.59")
        let previousVersion = try paths.versionDirectory("7.2.60")
        let activatedVersion = try paths.versionDirectory("7.2.61")
        let oldestPlugins = oldestVersion.appendingPathComponent("plugins", isDirectory: true)
        let previousPlugins = previousVersion.appendingPathComponent("plugins", isDirectory: true)
        let activatedPlugins = activatedVersion.appendingPathComponent("plugins", isDirectory: true)
        try fileManager.createDirectory(at: oldestPlugins, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previousPlugins, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: activatedPlugins, withIntermediateDirectories: true)
        try Data("ambiguous-old-plugin".utf8).write(
            to: oldestPlugins.appendingPathComponent("plugin.json")
        )
        let previousPluginFile = previousPlugins.appendingPathComponent("plugin.json")
        try Data("previous-active-plugin".utf8).write(to: previousPluginFile)
        try Data("new-version-plugin".utf8).write(
            to: activatedPlugins.appendingPathComponent("plugin.json")
        )
        try fileManager.createSymbolicLink(at: paths.currentSymlink, withDestinationURL: activatedVersion)

        // Legacy CPA configs omitted plugins.dir, so CPA used <binary CWD>/plugins.
        let legacyConfig = """
        api-keys:
          - "external-client-key"
        plugins:
          enabled: true
        ws-auth: false
        """ + "\n"
        try legacyConfig.write(to: paths.configURL, atomically: true, encoding: .utf8)
        let store = CLIProxyConfigStore(paths: paths)
        let secrets = CLIProxySecrets(
            managementKey: "migration-management-secret",
            clientAPIKey: "cpa-client-migrated"
        )

        do {
            try store.writeRuntimeConfig(settings: .default, secrets: secrets)
            throw RegressionFailure("ambiguous old-version plugin directories were merged")
        } catch is CLIProxyGatewayError {
            let unchanged = try String(contentsOf: paths.configURL, encoding: .utf8)
            try expect(unchanged == legacyConfig, "ambiguous plugin discovery rewrote the CPA config")
        }

        try fileManager.removeItem(at: oldestPlugins)
        do {
            try store.writeRuntimeConfig(settings: .default, secrets: secrets)
            throw RegressionFailure("old and current version plugin directories were merged")
        } catch is CLIProxyGatewayError {
            let unchanged = try String(contentsOf: paths.configURL, encoding: .utf8)
            try expect(unchanged == legacyConfig, "cross-version plugin ambiguity rewrote the CPA config")
        }

        try fileManager.removeItem(at: activatedPlugins)
        try store.writeRuntimeConfig(settings: .default, secrets: secrets)
        let migratedConfig = try String(contentsOf: paths.configURL, encoding: .utf8)
        let stablePluginFile = paths.pluginsDirectory.appendingPathComponent("plugin.json")
        let stablePluginData = try Data(contentsOf: stablePluginFile)
        let previousPluginData = try Data(contentsOf: previousPluginFile)
        try expect(
            migratedConfig.contains("dir: \"\(paths.pluginsDirectory.path)\""),
            "legacy default plugin directory was not stabilized after activation"
        )
        try expect(
            stablePluginData == Data("previous-active-plugin".utf8),
            "the previous active version's default plugins were not migrated"
        )
        try expect(
            previousPluginData == Data("previous-active-plugin".utf8),
            "default plugin migration changed the previous version's source"
        )
        // Once config stabilization succeeds, version cleanup must be free to
        // remove the old runtime without removing the migrated plugin copy.
        try fileManager.removeItem(at: previousVersion)
        let stableAfterCleanup = try Data(contentsOf: stablePluginFile)
        try expect(
            stableAfterCleanup == Data("previous-active-plugin".utf8),
            "version cleanup removed the stabilized plugin copy"
        )
    }

    private static let testIssuerPrivateKey = P256.Signing.PrivateKey()
    private static let testIssuerKey = CLIProxyTrustedJWSKey(
        keyID: "codex-test-k1",
        issuer: "https://auth.openai.com",
        allowedAudiences: ["https://api.openai.com/v1"],
        publicKeyData: testIssuerPrivateKey.publicKey.x963Representation
    )

    private static func testCredentialAdapters() throws {
        let goJWS = try signedES256JWT([
            "sub": "user-1",
            "email": "user@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account",
                "chatgpt_user_id": "user-1",
                "chatgpt_plan_type": "go"
            ]
        ])
        let codex = Data(#"{"plan_type":"go","tokens":{"access_token":"\#(goJWS)","refresh_token":"refresh","id_token":"\#(goJWS)","account_id":"account"}}"#.utf8)

        // [§37.1] Production default (no trusted issuer keys configured) must fail closed even on well-formed ES256 Go tokens.
        try expect(CLIProxyCapabilityMatrix.defaultTrustedCodexIssuerKeys.isEmpty && !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild,
                   "[§39.3] production build must keep immutable empty issuer trust and subscriptions disabled")
        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "codex",
                credentialId: "credential-untrusted-default",
                accountLabel: "user@example.com",
                metadata: [:],
                sourceData: codex
            )
            throw RegressionFailure("[§37.1] empty defaultTrustedCodexIssuerKeys accepted Codex conversion")
        } catch is CLIProxyGatewayError {}

        let converted = try CLIProxyCredentialAdapter.convert(
            providerId: "codex",
            credentialId: "credential-1",
            accountLabel: "user@example.com",
            metadata: [:],
            sourceData: codex,
            trustedCodexIssuerKeys: [testIssuerKey]
        )
        let object = try JSONSerialization.jsonObject(with: converted) as? [String: Any]
        try expect(object?["type"] as? String == "codex", "Codex adapter did not set CPA type")
        try expect(object?["chatgpt_plan_type"] as? String == "go", "Codex adapter did not stamp verified plan type")
        try expect(object?["access_token"] as? String == goJWS, "Codex adapter did not flatten access token")
        try expect(object?["refresh_token"] as? String == "refresh", "Codex adapter did not flatten refresh token")
        try expect(object?["aiusage_credential_id"] as? String == "credential-1", "adapter linkage marker is missing")
        try expect(object?["aiusage_verified_account_id"] as? String == "account", "[§37.1] verified account id marker missing")
        try expect(object?["aiusage_verified_user_id"] as? String == "user-1", "[§37.1] verified user id marker missing")
        try expect(object?["aiusage_verified_access_token_sha256"] as? String == CLIProxyCapabilityMatrix.sha256Hex(goJWS), "[§37.1] verified token sha256 marker missing")

        let freeJWS = try signedES256JWT([
            "sub": "user-2",
            "email": "free@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "account",
                "chatgpt_user_id": "user-2",
                "chatgpt_plan_type": "ChatGPT Free"
            ]
        ])
        let codexFree = Data(#"{"chatgpt_plan_type":"ChatGPT Free","tokens":{"access_token":"\#(freeJWS)","refresh_token":"refresh","id_token":"\#(freeJWS)","account_id":"account"}}"#.utf8)
        let convertedFree = try CLIProxyCredentialAdapter.convert(
            providerId: "codex",
            credentialId: "credential-2",
            accountLabel: "free@example.com",
            metadata: [:],
            sourceData: codexFree,
            trustedCodexIssuerKeys: [testIssuerKey]
        )
        let freeObject = try JSONSerialization.jsonObject(with: convertedFree) as? [String: Any]
        try expect(freeObject?["chatgpt_plan_type"] as? String == "free", "Codex adapter did not normalize ChatGPT Free plan")

        // [§35.1] Bare JSON plan_type without validated token-bound JWS proof must fail closed
        let labelOnlyCodex = Data(#"{"plan_type":"go","tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id","account_id":"account"}}"#.utf8)
        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "codex",
                credentialId: "credential-label-only",
                accountLabel: "user@example.com",
                metadata: ["accountPlan": "go"],
                sourceData: labelOnlyCodex,
                trustedCodexIssuerKeys: [testIssuerKey]
            )
            throw RegressionFailure("[§35.1] bare JSON label / metadata without token-bound JWS plan proof was accepted")
        } catch is CLIProxyGatewayError {}

        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "antigravity",
                credentialId: "credential-3",
                accountLabel: nil,
                metadata: [:],
                sourceData: Data(#"{"access_token":"access"}"#.utf8),
                disallowedProviderIDs: []
            )
            throw RegressionFailure("credential without refresh token was accepted")
        } catch is CLIProxyGatewayError {}
    }

    private static func testGeminiCredentialBridge() async throws {
        let native = Data(#"""
        {
          "access_token":"gemini-access",
          "refresh_token":"gemini-refresh",
          "token_type":"Bearer",
          "email":"user@example.com",
          "expiry_date":4102444800000,
          "scope":"openid cloud-platform",
          "project_id":"project-primary",
          "project_ids":["project-primary","project-secondary"]
        }
        """#.utf8)
        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "gemini",
                credentialId: "credential-gemini-blocked",
                accountLabel: "user@example.com",
                metadata: [:],
                sourceData: native
            )
            throw RegressionFailure("[§34.1] default policy must block Gemini CPA credential conversion")
        } catch is CLIProxyGatewayError {}

        let cpa = try CLIProxyCredentialAdapter.convert(
            providerId: "gemini",
            credentialId: "credential-gemini",
            accountLabel: "user@example.com",
            metadata: [:],
            sourceData: native,
            disallowedProviderIDs: ["antigravity"]
        )
        guard let cpaObject = try JSONSerialization.jsonObject(with: cpa) as? [String: Any],
              let token = cpaObject["token"] as? [String: Any] else {
            throw RegressionFailure("Gemini adapter did not produce a CPA object")
        }
        try expect(cpaObject["type"] as? String == "gemini-cli", "Gemini adapter did not select the plugin type")
        try expect(cpaObject["email"] as? String == "user@example.com", "Gemini adapter lost the account email")
        try expect(token["access_token"] as? String == "gemini-access", "Gemini adapter lost the nested access token")
        try expect(token["refresh_token"] as? String == "gemini-refresh", "Gemini adapter lost the nested refresh token")
        try expect(
            (cpaObject["project_ids"] as? [String]) == ["project-primary", "project-secondary"],
            "Gemini adapter lost the project inventory"
        )

        let nativeRoundTrip = try CLIProxyGeminiCredentialBridge.makeNativePayload(from: cpa)
        guard let nativeObject = try JSONSerialization.jsonObject(with: nativeRoundTrip) as? [String: Any] else {
            throw RegressionFailure("Gemini reverse adapter did not produce native JSON")
        }
        try expect(nativeObject["access_token"] as? String == "gemini-access", "Gemini reverse adapter lost access token")
        try expect(nativeObject["refresh_token"] as? String == "gemini-refresh", "Gemini reverse adapter lost refresh token")
        try expect(nativeObject["expiry_date"] is NSNumber, "Gemini reverse adapter did not normalize expiry_date")

        let firstIdentity = try CLIProxyAccountIdentity.parse(data: cpa, providerHint: "gemini")
        let secondCPA = try CLIProxyCredentialAdapter.convert(
            providerId: "gemini-cli",
            credentialId: "credential-round-trip",
            accountLabel: nil,
            metadata: [:],
            sourceData: nativeRoundTrip,
            disallowedProviderIDs: ["antigravity"]
        )
        let secondIdentity = try CLIProxyAccountIdentity.parse(data: secondCPA, providerHint: "gemini-cli")
        try expect(firstIdentity.key == secondIdentity.key, "Gemini identity changed across a round trip")
        try expect(firstIdentity.canAutomaticallyMerge, "Gemini email identity was not treated as stable")

        var projectlessObject = cpaObject
        projectlessObject.removeValue(forKey: "project_id")
        projectlessObject.removeValue(forKey: "project_ids")
        let projectless = try JSONSerialization.data(withJSONObject: projectlessObject)
        var existingObject = cpaObject
        existingObject["note"] = "Keep CPA preference"
        let existingData = try JSONSerialization.data(withJSONObject: existingObject)
        let prepared = try await CLIProxyGeminiCredentialBridge.prepareCPAPayloadForUpload(
            projectless,
            existingCPAData: existingData,
            allowNetworkDiscovery: false
        )
        let preparedObject = try JSONSerialization.jsonObject(with: prepared) as? [String: Any]
        try expect(
            (preparedObject?["project_ids"] as? [String]) == ["project-primary", "project-secondary"],
            "Gemini bridge did not reuse the same account's existing project inventory"
        )
        try expect(
            preparedObject?["note"] as? String == "Keep CPA preference",
            "Gemini bridge overwrote a CPA-local account preference"
        )

        let preparedWithProjects = try await CLIProxyGeminiCredentialBridge.prepareCPAPayloadForUpload(
            cpa,
            existingCPAData: existingData,
            allowNetworkDiscovery: false
        )
        let preparedWithProjectsObject = try JSONSerialization.jsonObject(
            with: preparedWithProjects
        ) as? [String: Any]
        try expect(
            preparedWithProjectsObject?["note"] as? String == "Keep CPA preference",
            "Gemini bridge dropped CPA preferences when the source already had projects"
        )

        let refreshOnlyNative = try CLIProxyGeminiCredentialBridge.makeNativePayload(
            from: Data(#"{"type":"gemini-cli","refresh_token":"refresh-only","email":"user@example.com"}"#.utf8)
        )
        let refreshOnlyObject = try JSONSerialization.jsonObject(with: refreshOnlyNative) as? [String: Any]
        try expect(
            refreshOnlyObject?["refresh_token"] as? String == "refresh-only",
            "Gemini reverse adapter rejected a refreshable session without a cached access token"
        )

        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "droid",
                credentialId: "unsupported",
                accountLabel: nil,
                metadata: [:],
                sourceData: native
            )
            throw RegressionFailure("unknown credential adapter was accepted")
        } catch is CLIProxyGatewayError {}

        do {
            _ = try CLIProxyGeminiCredentialBridge.makeNativePayload(
                from: Data(#"{"type":"gemini-cli","access_token":"only-access"}"#.utf8)
            )
            throw RegressionFailure("Gemini credential without refresh token was accepted")
        } catch is CLIProxyGatewayError {}
    }

    private static func testCanonicalCredentialFingerprint() throws {
        let first = Data(#"{"type":"codex","nested":{"b":2,"a":1}}"#.utf8)
        let reordered = Data(#"{ "nested" : { "a" : 1, "b" : 2 }, "type" : "codex" }"#.utf8)
        let changed = Data(#"{"type":"codex","nested":{"b":3,"a":1}}"#.utf8)
        let firstHash = try CLIProxyJSONFingerprint.hash(first)
        let reorderedHash = try CLIProxyJSONFingerprint.hash(reordered)
        let changedHash = try CLIProxyJSONFingerprint.hash(changed)
        try expect(firstHash == reorderedHash, "canonical JSON fingerprint changed for formatting or key order")
        try expect(firstHash != changedHash, "canonical JSON fingerprint missed a credential value change")
    }

    private static func testSyncManifestValidation() throws {
        let sourceHash = String(repeating: "a", count: 64)
        let copiedHash = String(repeating: "b", count: 64)
        let legacyJSON = #"""
        {
          "schemaVersion": 1,
          "records": [{
            "providerId": "codex",
            "credentialId": "legacy-credential",
            "authFileName": "aiusage-codex-legacy.json",
            "sourceFingerprint": "\#(sourceHash)",
            "lastCopiedFingerprint": "\#(copiedHash)",
            "lastSyncedAt": "2026-07-12T12:00:00Z",
            "mode": "manualCopy"
          }]
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(
            CLIProxyAccountSyncManifest.self,
            from: Data(legacyJSON.utf8)
        )
        try expect(legacy.records.first?.accountIdentity == nil, "legacy v1 manifest required accountIdentity")
        let validatedLegacy = try CLIProxyAccountSyncManifestValidator.validate(legacy)
        try expect(
            validatedLegacy == legacy,
            "valid legacy v1 manifest was rejected"
        )

        let identityHash = String(repeating: "c", count: 64)
        let current = CLIProxyAccountSyncManifest(
            schemaVersion: 1,
            records: [syncManifestRecord(accountIdentity: "codex:\(identityHash)")]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(current)
        let decoded = try decoder.decode(CLIProxyAccountSyncManifest.self, from: encoded)
        try expect(decoded == current, "manifest accountIdentity did not round-trip")
        let validatedCurrent = try CLIProxyAccountSyncManifestValidator.validate(decoded)
        try expect(
            validatedCurrent == current,
            "round-tripped manifest failed structural validation"
        )

        let duplicateRecords = CLIProxyAccountSyncManifest(
            schemaVersion: 1,
            records: [
                syncManifestRecord(providerID: "codex", credentialID: "Duplicate", fileName: "first.json"),
                syncManifestRecord(providerID: "CODEX", credentialID: "duplicate", fileName: "second.json")
            ]
        )
        try expectManifestRejected(duplicateRecords, "case-insensitive duplicate manifest record ID was accepted")

        let invalidManifests = [
            CLIProxyAccountSyncManifest(
                schemaVersion: 2,
                records: [syncManifestRecord()]
            ),
            CLIProxyAccountSyncManifest(
                schemaVersion: 1,
                records: [syncManifestRecord(sourceFingerprint: String(repeating: "a", count: 63))]
            ),
            CLIProxyAccountSyncManifest(
                schemaVersion: 1,
                records: [syncManifestRecord(lastCopiedFingerprint: String(repeating: "F", count: 64))]
            ),
            CLIProxyAccountSyncManifest(
                schemaVersion: 1,
                records: [syncManifestRecord(fileName: "../escape.json")]
            ),
            CLIProxyAccountSyncManifest(
                schemaVersion: 1,
                records: [syncManifestRecord(accountIdentity: "antigravity:\(identityHash)")]
            ),
            CLIProxyAccountSyncManifest(
                schemaVersion: 1,
                records: [syncManifestRecord(accountIdentity: "codex:\(String(repeating: "c", count: 63))")]
            )
        ]
        for (index, manifest) in invalidManifests.enumerated() {
            try expectManifestRejected(manifest, "invalid manifest fixture \(index) was accepted")
        }
    }

    private static func syncManifestRecord(
        providerID: String = "codex",
        credentialID: String = "credential",
        fileName: String = "aiusage-codex-credential.json",
        accountIdentity: String? = nil,
        sourceFingerprint: String = String(repeating: "a", count: 64),
        lastCopiedFingerprint: String = String(repeating: "b", count: 64)
    ) -> CLIProxyAccountSyncRecord {
        CLIProxyAccountSyncRecord(
            providerId: providerID,
            credentialId: credentialID,
            authFileName: fileName,
            accountIdentity: accountIdentity,
            sourceFingerprint: sourceFingerprint,
            lastCopiedFingerprint: lastCopiedFingerprint,
            lastSyncedAt: Date(timeIntervalSince1970: 1_752_321_600),
            mode: .manualCopy
        )
    }

    private static func expectManifestRejected(
        _ manifest: CLIProxyAccountSyncManifest,
        _ message: String
    ) throws {
        do {
            _ = try CLIProxyAccountSyncManifestValidator.validate(manifest)
            throw RegressionFailure(message)
        } catch is CLIProxyGatewayError {
            // Expected.
        }
    }

    private static func testCodexIdentityKeepsPlansSeparate() throws {
        let freeData = try codexAuthData(
            accountID: "account-free-1234567890",
            userID: "user-shared-1234567890",
            plan: "free",
            email: "same@example.com",
            credentialID: "free-credential",
            refreshToken: "shared-refresh"
        )
        let teamData = try codexAuthData(
            accountID: "account-team-1234567890",
            userID: "user-shared-1234567890",
            plan: "team",
            email: "same@example.com",
            credentialID: "team-credential",
            refreshToken: "shared-refresh"
        )
        let free = try CLIProxyAccountIdentity.parse(data: freeData, providerHint: "codex")
        let team = try CLIProxyAccountIdentity.parse(data: teamData, providerHint: "codex")

        try expect(free.canAutomaticallyMerge && team.canAutomaticallyMerge, "complete Codex identities were not strong")
        try expect(free.key != team.key, "Free and Team workspaces with one email were merged")
        try expect(free.planDisplayName == "Free" && team.planDisplayName == "Business", "Codex plan summary is wrong")
        try expect(free.shortAccountID != free.accountID, "long Codex account ID was not shortened for display")

        let plan = CLIProxyManagedAuthDeduplicator.plan(for: [
            try managedCopy(name: "free.json", data: freeData, modifiedAt: 1, manifestTracked: true),
            try managedCopy(name: "team.json", data: teamData, modifiedAt: 2, manifestTracked: true)
        ])
        try expect(plan.duplicateFileNames.isEmpty, "same-email Codex plans produced a deletion candidate")
        try expect(plan.conflictingIdentityKeys.isEmpty, "separate Codex plans were reported as conflicts")
    }

    private static func testCodexIdentityParityAndPlanChanges() throws {
        let plusData = try codexAuthData(
            accountID: "same-account-1234567890",
            userID: "same-user-1234567890",
            plan: "plus",
            email: "upgrade@example.com",
            credentialID: "upgrade-plus",
            refreshToken: "upgrade-refresh"
        )
        let teamData = try codexAuthData(
            accountID: "same-account-1234567890",
            userID: "same-user-1234567890",
            plan: "team",
            email: "upgrade@example.com",
            credentialID: "upgrade-team",
            refreshToken: "upgrade-refresh"
        )
        let jwtAccountAndSubjectOnly = try codexAuthData(
            accountID: "same-account-1234567890",
            userID: "same-user-1234567890",
            plan: "plus",
            email: "upgrade@example.com",
            credentialID: "jwt-subject-only",
            refreshToken: "upgrade-refresh",
            includeRootAccountID: false,
            includeChatGPTUserID: false
        )
        let noPlan = try codexAuthData(
            accountID: "same-account-1234567890",
            userID: "same-user-1234567890",
            plan: "plus",
            email: "upgrade@example.com",
            credentialID: "no-plan",
            refreshToken: "upgrade-refresh",
            includePlanClaim: false
        )

        let plus = try CLIProxyAccountIdentity.parse(data: plusData)
        let team = try CLIProxyAccountIdentity.parse(data: teamData)
        let fallback = try CLIProxyAccountIdentity.parse(data: jwtAccountAndSubjectOnly)
        let planless = try CLIProxyAccountIdentity.parse(data: noPlan)
        try expect(plus.key == team.key, "Codex plan change created a new account identity")
        try expect(plus.key == fallback.key, "root account/chatgpt user and JWT account/sub did not have identity parity")
        try expect(plus.key == planless.key && planless.canAutomaticallyMerge, "missing plan claim weakened a complete Codex identity")
        try expect(plus.planDisplayName == "Plus" && team.planDisplayName == "Business", "plan display did not follow the current JWT")

        let plusFingerprint = try CLIProxyManagedAuthSafety.destructiveMergeFingerprint(for: plusData)
        let teamFingerprint = try CLIProxyManagedAuthSafety.destructiveMergeFingerprint(for: teamData)
        try expect(plusFingerprint != teamFingerprint, "plan change was omitted from the destructive safety fingerprint")
        let plan = CLIProxyManagedAuthDeduplicator.plan(for: [
            try managedCopy(name: "upgrade-plus.json", data: plusData, modifiedAt: 1, manifestTracked: true),
            try managedCopy(name: "upgrade-team.json", data: teamData, modifiedAt: 2, manifestTracked: true)
        ])
        try expect(plan.duplicateFileNames.isEmpty, "different Codex plan snapshots were automatically deleted")
        try expect(plan.conflictingIdentityKeys == [plus.key], "plan change was not surfaced as a safe-review conflict")
    }

    private static func testCodexManagedCopiesDeduplicateSafely() throws {
        let first = try codexAuthData(
            accountID: "team-account-1234567890",
            userID: "team-user-1234567890",
            plan: "team",
            email: "team@example.com",
            credentialID: "historical-1",
            refreshToken: "same-team-refresh",
            accessToken: "rotated-access-1"
        )
        let second = try codexAuthData(
            accountID: "team-account-1234567890",
            userID: "team-user-1234567890",
            plan: "team",
            email: "team@example.com",
            credentialID: "historical-z",
            refreshToken: "same-team-refresh",
            accessToken: "rotated-access-2"
        )
        let third = try codexAuthData(
            accountID: "team-account-1234567890",
            userID: "team-user-1234567890",
            plan: "team",
            email: "team@example.com",
            credentialID: "historical-b",
            refreshToken: "same-team-refresh",
            accessToken: "rotated-access-3"
        )
        let fourth = try codexAuthData(
            accountID: "team-account-1234567890",
            userID: "team-user-1234567890",
            plan: "team",
            email: "team@example.com",
            credentialID: "historical-c",
            refreshToken: "same-team-refresh",
            accessToken: "rotated-access-4"
        )
        let firstIdentity = try CLIProxyAccountIdentity.parse(data: first)
        let secondIdentity = try CLIProxyAccountIdentity.parse(data: second)
        try expect(firstIdentity.key == secondIdentity.key, "Codex identity changed with credential ID or access-token rotation")
        try expect(firstIdentity.sourceCredentialID != secondIdentity.sourceCredentialID, "source linkage fixture is invalid")
        let firstMergeFingerprint = try CLIProxyManagedAuthSafety.destructiveMergeFingerprint(for: first)
        let secondMergeFingerprint = try CLIProxyManagedAuthSafety.destructiveMergeFingerprint(for: second)
        try expect(
            firstMergeFingerprint == secondMergeFingerprint,
            "safe merge fingerprint changed with volatile tokens or AIUsage marker"
        )

        let plan = CLIProxyManagedAuthDeduplicator.plan(for: [
            try managedCopy(name: "aiusage-codex-historical-1.json", data: first, modifiedAt: 1, manifestTracked: true),
            try managedCopy(name: "aiusage-codex-historical-z.json", data: second, modifiedAt: 2, manifestTracked: false),
            try managedCopy(name: "aiusage-codex-historical-b.json", data: third, modifiedAt: 2, manifestTracked: true),
            try managedCopy(name: "aiusage-codex-historical-c.json", data: fourth, modifiedAt: 2, manifestTracked: true),
            try managedCopy(name: "marker-only-arbitrary.json", data: second, modifiedAt: 3, manifestTracked: false)
        ])
        try expect(
            plan.canonicalFileByIdentity[firstIdentity.key] == "aiusage-codex-historical-b.json",
            "canonical ordering did not prefer latest, manifest-tracked, then stable filename"
        )
        try expect(
            plan.duplicateFileNames == [
                "aiusage-codex-historical-1.json",
                "aiusage-codex-historical-c.json",
                "aiusage-codex-historical-z.json"
            ],
            "same Team copies did not produce a stable duplicate plan"
        )
        try expect(!plan.duplicateFileNames.contains("marker-only-arbitrary.json"), "marker-only arbitrary file was deletable")
        try expect(plan.conflictingIdentityKeys.isEmpty, "safe same-Team copies were reported as conflicting")
    }

    private static func testAntigravityManagedCopiesDeduplicate() throws {
        let first = try antigravityAuthData(
            projectID: "project-alpha-1234567890",
            email: "gravity@example.com",
            credentialID: "gravity-1",
            refreshToken: "gravity-refresh",
            accessToken: "gravity-access-1"
        )
        let second = try antigravityAuthData(
            projectID: "project-alpha-1234567890",
            email: "GRAVITY@example.com",
            credentialID: "gravity-2",
            refreshToken: "gravity-refresh",
            accessToken: "gravity-access-2"
        )
        let otherProject = try antigravityAuthData(
            projectID: "project-beta-1234567890",
            email: "gravity@example.com",
            credentialID: "gravity-3",
            refreshToken: "gravity-refresh"
        )
        let firstIdentity = try CLIProxyAccountIdentity.parse(data: first)
        let secondIdentity = try CLIProxyAccountIdentity.parse(data: second)
        let otherIdentity = try CLIProxyAccountIdentity.parse(data: otherProject)
        try expect(firstIdentity.key == secondIdentity.key, "same Antigravity project and email did not share identity")
        try expect(firstIdentity.key != otherIdentity.key, "different Antigravity projects with one email were merged")
        try expect(firstIdentity.shortProjectID != firstIdentity.projectID, "long Antigravity project ID was not shortened")

        let plan = CLIProxyManagedAuthDeduplicator.plan(for: [
            try managedCopy(name: "gravity-old.json", data: first, modifiedAt: 1, manifestTracked: true),
            try managedCopy(name: "gravity-new.json", data: second, modifiedAt: 2, manifestTracked: true),
            try managedCopy(name: "gravity-other.json", data: otherProject, modifiedAt: 3, manifestTracked: true)
        ])
        try expect(plan.duplicateFileNames == ["gravity-old.json"], "Antigravity strong identity was not deduplicated safely")
        try expect(
            plan.canonicalFileByIdentity[firstIdentity.key] == "gravity-new.json",
            "newest Antigravity copy was not canonical"
        )
    }

    private static func testWeakIdentityNeverDeduplicates() throws {
        let weak = Data(#"{"type":"codex","email":"weak@example.com","aiusage_credential_id":"weak-1","refresh_token":"same"}"#.utf8)
        let otherWeak = Data(#"{"type":"codex","email":"weak@example.com","aiusage_credential_id":"weak-2","refresh_token":"same"}"#.utf8)
        let identity = try CLIProxyAccountIdentity.parse(data: weak)
        try expect(!identity.canAutomaticallyMerge, "email-only Codex auth was treated as a strong identity")
        let plan = CLIProxyManagedAuthDeduplicator.plan(for: [
            try managedCopy(name: "weak-a.json", data: weak, modifiedAt: 1, manifestTracked: true),
            try managedCopy(name: "weak-b.json", data: otherWeak, modifiedAt: 2, manifestTracked: true)
        ])
        try expect(plan.canonicalFileByIdentity.isEmpty, "weak identity was assigned a canonical file")
        try expect(plan.duplicateFileNames.isEmpty, "weak identity produced a deletion candidate")
        try expect(plan.conflictingIdentityKeys.isEmpty, "weak identity was promoted to a destructive conflict")
    }

    private static func testManagedCopyConflictsAreNeverDeleted() throws {
        let base = try codexAuthData(
            accountID: "conflict-account-1234567890",
            userID: "conflict-user-1234567890",
            plan: "team",
            email: "conflict@example.com",
            credentialID: "conflict-1",
            refreshToken: "refresh-a"
        )
        let differentRefresh = try codexAuthData(
            accountID: "conflict-account-1234567890",
            userID: "conflict-user-1234567890",
            plan: "team",
            email: "conflict@example.com",
            credentialID: "conflict-2",
            refreshToken: "refresh-b"
        )
        let differentSettings = try codexAuthData(
            accountID: "conflict-account-1234567890",
            userID: "conflict-user-1234567890",
            plan: "team",
            email: "conflict@example.com",
            credentialID: "conflict-3",
            refreshToken: "refresh-a",
            note: "locally edited"
        )
        let identity = try CLIProxyAccountIdentity.parse(data: base)

        for conflicting in [differentRefresh, differentSettings] {
            let plan = CLIProxyManagedAuthDeduplicator.plan(for: [
                try managedCopy(name: "conflict-a.json", data: base, modifiedAt: 1, manifestTracked: true),
                try managedCopy(name: "conflict-b.json", data: conflicting, modifiedAt: 2, manifestTracked: true)
            ])
            try expect(plan.duplicateFileNames.isEmpty, "refresh token or persistent setting conflict produced a deletion")
            try expect(plan.conflictingIdentityKeys == [identity.key], "unsafe managed copies were not surfaced for review")
            try expect(plan.canonicalFileByIdentity[identity.key] == nil, "unsafe group received a verified canonical file")
        }

        let missingRefresh = Data(#"{"type":"antigravity","project_id":"project","email":"user@example.com","aiusage_credential_id":"managed"}"#.utf8)
        let missingRefreshFingerprint = try CLIProxyManagedAuthSafety.destructiveMergeFingerprint(for: missingRefresh)
        try expect(
            missingRefreshFingerprint == nil,
            "auth file without refresh token received a destructive merge fingerprint"
        )
        let missingRefreshPlan = CLIProxyManagedAuthDeduplicator.plan(for: [
            try managedCopy(name: "missing-refresh.json", data: missingRefresh, modifiedAt: 1, manifestTracked: true)
        ])
        try expect(missingRefreshPlan.canonicalFileByIdentity.isEmpty, "missing refresh token received a verified canonical file")
    }

    private static func managedCopy(
        name: String,
        data: Data,
        modifiedAt: TimeInterval,
        manifestTracked: Bool
    ) throws -> CLIProxyManagedAuthCopy {
        CLIProxyManagedAuthCopy(
            fileName: name,
            identity: try CLIProxyAccountIdentity.parse(data: data),
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            isManifestTracked: manifestTracked,
            destructiveMergeFingerprint: try CLIProxyManagedAuthSafety.destructiveMergeFingerprint(for: data)
        )
    }

    private static func codexAuthData(
        accountID: String,
        userID: String,
        plan: String,
        email: String,
        credentialID: String,
        refreshToken: String,
        accessToken: String = "access",
        note: String = "Synced from AIUsage",
        includeRootAccountID: Bool = true,
        includeChatGPTUserID: Bool = true,
        includePlanClaim: Bool = true,
        includeExp: Bool = true,
        includeIat: Bool = true,
        issuer: String = "https://auth.openai.com",
        audience: String = "https://api.openai.com/v1",
        signingKey: P256.Signing.PrivateKey? = nil
    ) throws -> Data {
        var authClaims: [String: Any] = ["chatgpt_account_id": accountID]
        if includeChatGPTUserID { authClaims["chatgpt_user_id"] = userID }
        if includePlanClaim { authClaims["chatgpt_plan_type"] = plan }
        let claims: [String: Any] = [
            "sub": userID,
            "email": email,
            "https://api.openai.com/auth": authClaims
        ]
        var accessClaims = claims
        accessClaims["jti"] = accessToken
        let resolvedSigningKey = signingKey ?? testIssuerPrivateKey
        let resolvedAccessToken = accessToken.split(separator: ".", omittingEmptySubsequences: false).count == 3
            ? accessToken
            : try signedES256JWT(
                accessClaims,
                key: resolvedSigningKey,
                includeExp: includeExp,
                includeIat: includeIat,
                issuer: issuer,
                audience: audience
            )
        var object: [String: Any] = [
            "type": "codex",
            "email": email,
            "id_token": try signedES256JWT(
                claims,
                key: resolvedSigningKey,
                includeExp: includeExp,
                includeIat: includeIat,
                issuer: issuer,
                audience: audience
            ),
            "access_token": resolvedAccessToken,
            "refresh_token": refreshToken,
            "aiusage_credential_id": credentialID,
            "disabled": false,
            "note": note,
            "priority": 0,
            "websockets": false
        ]
        if includeRootAccountID { object["account_id"] = accountID }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func antigravityAuthData(
        projectID: String,
        email: String,
        credentialID: String,
        refreshToken: String,
        accessToken: String = "access"
    ) throws -> Data {
        let object: [String: Any] = [
            "type": "antigravity",
            "project_id": projectID,
            "email": email,
            "access_token": accessToken,
            "refresh_token": refreshToken,
            "aiusage_credential_id": credentialID,
            "disabled": false,
            "note": "Synced from AIUsage",
            "priority": 0,
            "websockets": false
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    private static func signedES256JWT(
        _ rawClaims: [String: Any],
        key: P256.Signing.PrivateKey = testIssuerPrivateKey,
        kid: String? = "codex-test-k1",
        includeExp: Bool = true,
        includeIat: Bool = true,
        issuer: String = "https://auth.openai.com",
        audience: String = "https://api.openai.com/v1"
    ) throws -> String {
        var claims = rawClaims
        if claims["iss"] == nil { claims["iss"] = issuer }
        if claims["aud"] == nil { claims["aud"] = audience }
        if includeIat && claims["iat"] == nil { claims["iat"] = 1_700_000_000 }
        if includeExp && claims["exp"] == nil { claims["exp"] = 4_102_444_800 }
        var headerDict: [String: Any] = ["alg": "ES256", "typ": "JWT"]
        if let kid { headerDict["kid"] = kid }
        let header = try JSONSerialization.data(withJSONObject: headerDict, options: [.sortedKeys])
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput = "\(base64URL(header)).\(base64URL(payload))"
        let signature = try key.signature(for: Data(signingInput.utf8))
        return "\(signingInput).\(base64URL(signature.rawRepresentation))"
    }

    private static func signedJWT(_ claims: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "HS256", "typ": "JWT"], options: [.sortedKeys])
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        let signingInput = "\(base64URL(header)).\(base64URL(payload))"
        let key = SymmetricKey(data: Data("aiusage-cpa-regression-test-key-32b".utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(signingInput.utf8), using: key)
        return "\(signingInput).\(base64URL(Data(mac)))"
    }

    private static func unsignedJWT(_ claims: [String: Any]) throws -> String {
        let header = try JSONSerialization.data(withJSONObject: ["alg": "none", "typ": "JWT"], options: [.sortedKeys])
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return "\(base64URL(header)).\(base64URL(payload))."
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func testExpandedAuthFileDecoding() throws {
        let json = #"""
        {
          "id":"auth-1","auth_index":"idx-1","name":"account.json","provider":"claude",
          "email":"user@example.com","status":"ready","disabled":false,"runtime_only":false,
          "source":"file","path":"/private/account.json","size":1234,"success":41,"failed":2,
          "recent_requests":[{"time":"2026-07-12T10:00:00Z","success":3,"failed":1}],
          "project_id":"project-1","account_type":"subscription","priority":7,"note":"primary"
        }
        """#
        let file = try JSONDecoder().decode(CLIProxyAuthFile.self, from: Data(json.utf8))
        try expect(file.authIndex == "idx-1", "auth index was not decoded")
        try expect(file.success == 41 && file.failed == 2, "request counters were not decoded")
        try expect(file.recentRequests.first?.success == 3, "recent request counters were not decoded")
        try expect(file.projectID == "project-1" && file.accountType == "subscription", "account metadata was not decoded")
        try expect(file.priority == 7 && file.note == "primary", "editable metadata was not decoded")
    }

    private static func testDynamicProviderModels() throws {
        let pluginJSON = #"""
        {
          "id":"gemini-cli","configured":true,"registered":true,"enabled":true,
          "effective_enabled":true,"supports_oauth":true,"oauth_provider":"gemini-cli",
          "metadata":{"name":"Gemini CLI","version":"1.0.0","author":"CPA","github_repository":"https://example.invalid/plugin"}
        }
        """#
        let plugin = try JSONDecoder().decode(CLIProxyPlugin.self, from: Data(pluginJSON.utf8))
        try expect(plugin.supportsOAuth && plugin.providerID == "gemini-cli", "dynamic plugin OAuth capability was not decoded")

        let provider = CLIProxyOpenAICompatibleProvider(
            name: "Regression Provider",
            priority: 3,
            disabled: false,
            prefix: "regression",
            baseURL: "https://example.invalid/v1",
            apiKeyEntries: [.init(apiKey: "placeholder", proxyURL: nil)],
            models: [.init(name: "model-a", alias: "", forceMapping: false)],
            headers: nil,
            disableCooling: false
        )
        let encoded = try JSONEncoder().encode(provider)
        let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        try expect(object?["base-url"] as? String == "https://example.invalid/v1", "compatible provider base URL key is wrong")
        try expect((object?["api-key-entries"] as? [[String: Any]])?.first?["api-key"] as? String == "placeholder", "compatible provider key schema is wrong")
    }

    private static func testVersionedInstallAndRollback() async throws {
        let fileManager = FileManager.default
        let root = try makeScratchRoot("AIUsage-CPA-Test")
        defer { try? fileManager.removeItem(at: root) }
        let archive = try makeArchive(root: root, duplicateBinary: false)
        let digest = try sha256(of: archive)
        let paths = try CLIProxyPaths(root: root.appendingPathComponent("store"))
        let store = CLIProxyBinaryStore(
            paths: paths,
            extractor: CLIProxySecureArchiveExtractor(),
            signer: NoopSigner(),
            validator: NoopValidator()
        )

        let firstRelease = makeRelease(version: "7.2.66", archive: archive, digest: digest)
        _ = try await store.install(downloadedAssetURL: archive, release: firstRelease)
        let currentBeforePromotion = try await store.currentVersion()
        try expect(currentBeforePromotion == nil, "install changed current before promotion")
        _ = try await store.activate(version: firstRelease.version)
        let firstCurrent = try await store.currentVersion()
        try expect(firstCurrent == firstRelease.version, "first promotion failed")

        let invalidRelease = makeRelease(
            version: "7.2.66.1",
            archive: archive,
            digest: String(repeating: "0", count: 64)
        )
        do {
            _ = try await store.install(downloadedAssetURL: archive, release: invalidRelease)
            throw RegressionFailure("checksum mismatch was accepted")
        } catch is CLIProxyGatewayError {
            let currentAfterFailedInstall = try await store.currentVersion()
            try expect(currentAfterFailedInstall == firstRelease.version, "failed install changed the active version")
        }

        let secondRelease = makeRelease(version: "7.2.67", archive: archive, digest: digest)
        _ = try await store.install(downloadedAssetURL: archive, release: secondRelease)
        let previous = try await store.activate(version: secondRelease.version)
        try expect(previous == firstRelease.version, "previous version was not reported")
        let secondCurrent = try await store.currentVersion()
        try expect(secondCurrent == secondRelease.version, "second promotion failed")

        let installed = try await store.installedVersions()
        try expect(installed.count == 2, "versioned storage did not retain rollback version")
        try expect(installed.first(where: { $0.version == secondRelease.version })?.isCurrent == true, "active version flag is wrong")

        _ = try await store.activate(version: firstRelease.version)
        let rolledBackCurrent = try await store.currentVersion()
        try expect(rolledBackCurrent == firstRelease.version, "rollback activation failed")
        try await store.delete(version: secondRelease.version)
        let remainingVersions = try await store.installedVersions()
        try expect(remainingVersions.count == 1, "old version deletion failed")
    }

    private static func testDuplicateBinaryArchiveIsRejected() throws {
        let fileManager = FileManager.default
        let root = try makeScratchRoot("AIUsage-CPA-Duplicate")
        defer { try? fileManager.removeItem(at: root) }
        let archive = try makeArchive(root: root, duplicateBinary: true)
        let destination = root.appendingPathComponent("output")
        do {
            try CLIProxySecureArchiveExtractor().extractBinary(
                from: archive,
                assetName: archive.lastPathComponent,
                to: destination
            )
            throw RegressionFailure("duplicate CLIProxyAPI archive was accepted")
        } catch is CLIProxyGatewayError {
            // Expected.
        }
    }

    private static func testCodexGoFreePolicy() throws {
        try expect(
            CLIProxyCapabilityMatrix.allowedCodexPlanTypes == ["go", "free"],
            "[§34.1] CPA allowed Codex plan types must be strictly go and free"
        )
        try expect(
            CLIProxyCapabilityMatrix.importableAuthTypes == ["codex"],
            "[§34.1] CPA importable auth types must be codex-only"
        )
        try expect(
            CLIProxyCapabilityMatrix.allowedOAuthProviderIDs.isEmpty
                && CLIProxyCapabilityMatrix.directOAuthRejectionReason(for: "codex") != nil,
            "[§35.2] Direct CPA sidecar OAuth sign-in must be disabled under ChatGPT Go/Free restriction"
        )
        try expect(
            CLIProxyCredentialAdapter.supportedProviderIDs == ["codex"],
            "[§34.1] CredentialAdapter must expose only codex as supported"
        )

        try expect(
            !CLIProxyCapabilityMatrix.subscriptionsEnabledInThisBuild
                && CLIProxyCapabilityMatrix.capability(forAIUsageProvider: "codex") == .notAnUpstream
                && CLIProxyCapabilityMatrix.capability(forAIUsageProvider: "openai") == .notAnUpstream
                && CLIProxyCapabilityMatrix.capability(forAIUsageProvider: "chatgpt") == .notAnUpstream,
            "[§39.3] Subscriptions disabled in API-key-only build must map all providers to .notAnUpstream"
        )
        for blocked in ["antigravity", "gemini", "gemini-cli", "claude", "anthropic", "kimi", "xai", "qwen", "unknown"] {
            try expect(
                CLIProxyCapabilityMatrix.capability(forAIUsageProvider: blocked) == .notAnUpstream,
                "[§34.1] \(blocked) capability must be .notAnUpstream"
            )
            try expect(
                CLIProxyCapabilityMatrix.isDisallowedCPAProvider(blocked),
                "[§34.1] \(blocked) must be disallowed by default CPA policy"
            )
            do {
                _ = try CLIProxyCredentialAdapter.convert(
                    providerId: blocked,
                    credentialId: "blocked-\(blocked)",
                    accountLabel: nil,
                    metadata: [:],
                    sourceData: Data(#"{"type":"\#(blocked)","access_token":"a","refresh_token":"r"}"#.utf8)
                )
                throw RegressionFailure("[§34.1] \(blocked) was accepted by CredentialAdapter")
            } catch is CLIProxyGatewayError {}
        }
        try expect(
            !CLIProxyCapabilityMatrix.isDisallowedCPAProvider("codex"),
            "[§34.1] codex must be permitted by default CPA policy"
        )

        // Codex JWT claim extraction for ChatGPT Go & Free using explicit fixture issuer keys
        let jwtGo = try codexAuthData(
            accountID: "acct-go-1",
            userID: "user-go-1",
            plan: "chatgpt_go",
            email: "go@example.com",
            credentialID: "cred-go",
            refreshToken: "r-go"
        )
        let convertedGo = try CLIProxyCredentialAdapter.convert(
            providerId: "codex",
            credentialId: "cred-go",
            accountLabel: "go@example.com",
            metadata: ["accountPlan": "ChatGPT Go"],
            sourceData: jwtGo,
            trustedCodexIssuerKeys: [testIssuerKey]
        )
        let goObj = try JSONSerialization.jsonObject(with: convertedGo) as? [String: Any]
        try expect(goObj?["chatgpt_plan_type"] as? String == "go", "[§34.1] Go plan should be normalized and stamped")

        // [§39.2] Per-credential retry/cooling overrides must be rejected even with valid issuer signature
        for overridePayload in [
            #"{"type":"codex","request_retry":2,"plan_type":"go","access_token":"\#(try signedES256JWT(["sub":"u-ovr","https://api.openai.com/auth":["chatgpt_account_id":"a-ovr","chatgpt_user_id":"u-ovr","chatgpt_plan_type":"go"]]))","id_token":"\#(try signedES256JWT(["sub":"u-ovr","https://api.openai.com/auth":["chatgpt_account_id":"a-ovr","chatgpt_user_id":"u-ovr","chatgpt_plan_type":"go"]]))","refresh_token":"r-ovr","account_id":"a-ovr"}"#,
            #"{"type":"codex","request-retry":"3","plan_type":"go","access_token":"\#(try signedES256JWT(["sub":"u-ovr","https://api.openai.com/auth":["chatgpt_account_id":"a-ovr","chatgpt_user_id":"u-ovr","chatgpt_plan_type":"go"]]))","id_token":"\#(try signedES256JWT(["sub":"u-ovr","https://api.openai.com/auth":["chatgpt_account_id":"a-ovr","chatgpt_user_id":"u-ovr","chatgpt_plan_type":"go"]]))","refresh_token":"r-ovr","account_id":"a-ovr"}"#,
            #"{"type":"codex","metadata":{"disable_cooling":true},"plan_type":"go","access_token":"\#(try signedES256JWT(["sub":"u-ovr","https://api.openai.com/auth":["chatgpt_account_id":"a-ovr","chatgpt_user_id":"u-ovr","chatgpt_plan_type":"go"]]))","id_token":"\#(try signedES256JWT(["sub":"u-ovr","https://api.openai.com/auth":["chatgpt_account_id":"a-ovr","chatgpt_user_id":"u-ovr","chatgpt_plan_type":"go"]]))","refresh_token":"r-ovr","account_id":"a-ovr"}"#
        ] {
            do {
                _ = try CLIProxyCredentialAdapter.convert(
                    providerId: "codex",
                    credentialId: "cred-override",
                    accountLabel: "override@example.com",
                    metadata: [:],
                    sourceData: Data(overridePayload.utf8),
                    trustedCodexIssuerKeys: [testIssuerKey]
                )
                throw RegressionFailure("[§39.2] per-credential retry/cooling override was accepted by CredentialAdapter")
            } catch is CLIProxyGatewayError {}
        }

        let jwtFree = try codexAuthData(
            accountID: "acct-free-1",
            userID: "user-free-1",
            plan: "free",
            email: "free@example.com",
            credentialID: "cred-free",
            refreshToken: "r-free"
        )
        let convertedFree = try CLIProxyCredentialAdapter.convert(
            providerId: "codex",
            credentialId: "cred-free",
            accountLabel: "free@example.com",
            metadata: [:],
            sourceData: jwtFree,
            trustedCodexIssuerKeys: [testIssuerKey]
        )
        let freeObj = try JSONSerialization.jsonObject(with: convertedFree) as? [String: Any]
        try expect(freeObj?["chatgpt_plan_type"] as? String == "free", "[§34.1] Free plan should be verified and stamped")

        // [§37.1] Valid-format token from an untrusted signer must fail closed
        let untrustedKey = P256.Signing.PrivateKey()
        let untrustedGo = try codexAuthData(
            accountID: "acct-untrusted",
            userID: "user-untrusted",
            plan: "go",
            email: "untrusted@example.com",
            credentialID: "cred-untrusted",
            refreshToken: "r-untrusted",
            signingKey: untrustedKey
        )
        try expect(
            CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: untrustedGo, trustedKeys: [testIssuerKey]) == .missing,
            "[§37.1] ES256 token signed by untrusted key must fail closed"
        )

        // [§37.1] Missing expiry, wrong issuer, or wrong audience must fail closed
        let undatedGo = try codexAuthData(
            accountID: "acct-noexp",
            userID: "user-noexp",
            plan: "go",
            email: "noexp@example.com",
            credentialID: "cred-noexp",
            refreshToken: "r-noexp",
            includeExp: false
        )
        try expect(
            CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: undatedGo, trustedKeys: [testIssuerKey]) == .missing,
            "[§37.1] token missing exp must fail closed"
        )

        let wrongIssuerGo = try codexAuthData(
            accountID: "acct-iss",
            userID: "user-iss",
            plan: "go",
            email: "iss@example.com",
            credentialID: "cred-iss",
            refreshToken: "r-iss",
            issuer: "https://untrusted.example.invalid"
        )
        try expect(
            CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: wrongIssuerGo, trustedKeys: [testIssuerKey]) == .missing,
            "[§37.1] token with wrong issuer must fail closed"
        )

        let wrongAudGo = try codexAuthData(
            accountID: "acct-aud",
            userID: "user-aud",
            plan: "go",
            email: "aud@example.com",
            credentialID: "cred-aud",
            refreshToken: "r-aud",
            audience: "https://other.example.invalid"
        )
        try expect(
            CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: wrongAudGo, trustedKeys: [testIssuerKey]) == .missing,
            "[§37.1] token with wrong audience must fail closed"
        )

        // [§37.1] Post-refresh identity change and token rotation invalidation
        var rotatedObj = goObj!
        let refreshedOtherAcctJWS = try signedES256JWT([
            "sub": "user-other",
            "email": "go@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-other-after-refresh",
                "chatgpt_user_id": "user-other",
                "chatgpt_plan_type": "go"
            ]
        ])
        rotatedObj["access_token"] = refreshedOtherAcctJWS
        rotatedObj["id_token"] = refreshedOtherAcctJWS
        rotatedObj["account_id"] = "acct-other-after-refresh"
        let identityChangedAfterRefreshData = try JSONSerialization.data(withJSONObject: rotatedObj)
        if case .mismatched = CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: identityChangedAfterRefreshData, trustedKeys: [testIssuerKey]) {
            // Expected.
        } else {
            throw RegressionFailure("[§37.1] identity change after refresh was accepted")
        }

        var accessRotatedSameAcct = goObj!
        let newAccessSameAcctJWS = try signedES256JWT([
            "sub": "user-go-1",
            "jti": "rotated-access-2",
            "email": "go@example.com",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-go-1",
                "chatgpt_user_id": "user-go-1",
                "chatgpt_plan_type": "go"
            ]
        ])
        accessRotatedSameAcct["access_token"] = newAccessSameAcctJWS
        let accessRotatedData = try JSONSerialization.data(withJSONObject: accessRotatedSameAcct)
        if case .stale = CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: accessRotatedData, trustedKeys: [testIssuerKey]) {
            // Expected: bound proof must invalidate when dispatched access_token rotates.
        } else {
            throw RegressionFailure("[§37.1] token rotation did not invalidate stamped plan proof")
        }

        // Paid / missing / conflicting Codex plans must fail closed
        for blockedPlan in ["plus", "pro", "team", "business", "enterprise", "edu", "ChatGPT Plus", ""] {
            let blockedData = try codexAuthData(
                accountID: "acct-blocked-\(blockedPlan)",
                userID: "user-blocked",
                plan: blockedPlan,
                email: "blocked@example.com",
                credentialID: "cred-blocked",
                refreshToken: "r-blocked",
                includePlanClaim: !blockedPlan.isEmpty
            )
            do {
                _ = try CLIProxyCredentialAdapter.convert(
                    providerId: "codex",
                    credentialId: "cred-blocked",
                    accountLabel: "blocked@example.com",
                    metadata: [:],
                    sourceData: blockedData,
                    trustedCodexIssuerKeys: [testIssuerKey]
                )
                throw RegressionFailure("[§34.1] disallowed Codex plan '\(blockedPlan)' was accepted")
            } catch is CLIProxyGatewayError {}
        }

        // Conflicting plan across JWT vs metadata or JSON
        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "codex",
                credentialId: "cred-conflict-meta",
                accountLabel: "conflict@example.com",
                metadata: ["accountPlan": "ChatGPT Plus"],
                sourceData: jwtGo,
                trustedCodexIssuerKeys: [testIssuerKey]
            )
            throw RegressionFailure("[§34.1] conflicting metadata plan vs JWT plan was accepted")
        } catch is CLIProxyGatewayError {}

        let jsonGoJwtPlus = Data(#"""
        {
          "type": "codex",
          "plan_type": "go",
          "id_token": "\#(try signedES256JWT(["sub": "u1", "https://api.openai.com/auth": ["chatgpt_account_id": "a1", "chatgpt_user_id": "u1", "chatgpt_plan_type": "plus"]]))",
          "access_token": "\#(try signedES256JWT(["sub": "u1", "https://api.openai.com/auth": ["chatgpt_account_id": "a1", "chatgpt_user_id": "u1", "chatgpt_plan_type": "plus"]]))",
          "refresh_token": "ref"
        }
        """#.utf8)
        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "codex",
                credentialId: "cred-conflict-jwt",
                accountLabel: "conflict@example.com",
                metadata: [:],
                sourceData: jsonGoJwtPlus,
                trustedCodexIssuerKeys: [testIssuerKey]
            )
            throw RegressionFailure("[§34.1] conflicting top-level plan_type='go' vs id_token='plus' was accepted")
        } catch is CLIProxyGatewayError {}

        // [§35.1] Metadata-only plan without token-bound plan proof must fail closed (.missing)
        let planlessTokenData = try codexAuthData(
            accountID: "acct-planless",
            userID: "user-planless",
            plan: "",
            email: "planless@example.com",
            credentialID: "cred-planless",
            refreshToken: "r-planless",
            includePlanClaim: false
        )
        let metaOnlyRes = CLIProxyCapabilityMatrix.codexPlanVerification(
            fromAuthData: planlessTokenData,
            metadata: ["accountPlan": "go"],
            trustedKeys: [testIssuerKey]
        )
        try expect(metaOnlyRes == .missing && metaOnlyRes.verifiedPlan == nil,
                   "[§35.1] metadata-only plan must not be treated as verified: \(metaOnlyRes)")

        // [§35.1] Unsigned (alg:none) and HS256 JWTs must fail closed
        let unsignedClaims: [String: Any] = [
            "iss": "https://auth.openai.com",
            "aud": "https://api.openai.com/v1",
            "iat": 1_700_000_000,
            "exp": 4_102_444_800,
            "sub": "u-un",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "a-un",
                "chatgpt_user_id": "u-un",
                "chatgpt_plan_type": "go"
            ]
        ]
        for rejectedAlgTok in [try unsignedJWT(unsignedClaims), try signedJWT(unsignedClaims)] {
            let rejectedData = Data(#"{"type":"codex","id_token":"\#(rejectedAlgTok)","access_token":"\#(rejectedAlgTok)","refresh_token":"r","account_id":"a-un"}"#.utf8)
            try expect(CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: rejectedData, trustedKeys: [testIssuerKey]) == .missing,
                       "[§37.1] unsigned or symmetric HS256 JWT must fail closed")
        }

        // [§35.1] Mismatched id_token vs dispatched access_token principal must fail closed
        let idGoAcct1 = try signedES256JWT([
            "sub": "user-1",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-1",
                "chatgpt_user_id": "user-1",
                "chatgpt_plan_type": "go"
            ]
        ])
        let accessAcct2 = try signedES256JWT([
            "sub": "user-2",
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-2",
                "chatgpt_user_id": "user-2"
            ]
        ])
        let mismatchedTokenData = Data(#"{"type":"codex","id_token":"\#(idGoAcct1)","access_token":"\#(accessAcct2)","refresh_token":"r","account_id":"acct-1"}"#.utf8)
        if case .mismatched = CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: mismatchedTokenData, trustedKeys: [testIssuerKey]) {
            // Expected.
        } else {
            throw RegressionFailure("[§35.1] mismatched id_token vs dispatched access_token principal was accepted")
        }

        // [§35.1] Stale (expired or older than rotated access_token) plan evidence must fail closed
        let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
        let expiredGo = try signedES256JWT([
            "sub": "user-exp",
            "iat": 1_799_990_000,
            "exp": 1_799_999_000,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-exp",
                "chatgpt_user_id": "user-exp",
                "chatgpt_plan_type": "go"
            ]
        ])
        let expiredData = Data(#"{"type":"codex","id_token":"\#(expiredGo)","access_token":"\#(expiredGo)","refresh_token":"r","account_id":"acct-exp"}"#.utf8)
        if case .stale = CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: expiredData, trustedKeys: [testIssuerKey], now: fixedNow) {
            // Expected.
        } else {
            throw RegressionFailure("[§35.1] expired JWT plan evidence was accepted")
        }

        let staleIdToken = try signedES256JWT([
            "sub": "user-rot",
            "iat": 1_700_000_000,
            "exp": 4_102_444_800,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-rot",
                "chatgpt_user_id": "user-rot",
                "chatgpt_plan_type": "go"
            ]
        ])
        let newerAccessNoPlan = try signedES256JWT([
            "sub": "user-rot",
            "iat": 1_700_001_000,
            "exp": 4_102_444_800,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": "acct-rot",
                "chatgpt_user_id": "user-rot"
            ]
        ])
        let rotatedStaleData = Data(#"{"type":"codex","id_token":"\#(staleIdToken)","access_token":"\#(newerAccessNoPlan)","refresh_token":"r","account_id":"acct-rot"}"#.utf8)
        if case .stale = CLIProxyCapabilityMatrix.codexPlanVerification(fromAuthData: rotatedStaleData, trustedKeys: [testIssuerKey], now: fixedNow) {
            // Expected.
        } else {
            throw RegressionFailure("[§35.1] stale id_token older than rotated access_token was accepted")
        }

        // [§35.2] Direct CPA sidecar OAuth sign-in must fail closed before contacting the sidecar
        let blockedMgmtClient = CLIProxyManagementClient(
            baseURL: URL(string: "http://127.0.0.1:9")!,
            managementKey: "mgmt-key",
            clientAPIKey: "client-key"
        )
        try expect(
            CLIProxyCapabilityMatrix.directOAuthRejectionReason(for: "codex") != nil
                && CLIProxyCapabilityMatrix.directOAuthRejectionReason(for: blockedMgmtClient.baseURL.host) != nil,
            "[§35.2] Direct CPA OAuth must be rejected by capability matrix before sidecar dispatch"
        )
    }

    private static func testABARollbackCommitIdentity() async throws {
        let fileManager = FileManager.default
        let root = try makeScratchRoot("AIUsage-CPA-ABA")
        defer { try? fileManager.removeItem(at: root) }
        let archive = try makeArchive(root: root, duplicateBinary: false)
        let digest = try sha256(of: archive)
        let paths = try CLIProxyPaths(root: root.appendingPathComponent("store"))
        let store = CLIProxyBinaryStore(
            paths: paths,
            extractor: CLIProxySecureArchiveExtractor(),
            signer: NoopSigner(),
            validator: NoopValidator()
        )
        _ = try await store.install(downloadedAssetURL: archive, release: makeRelease(version: "1.0.0", archive: archive, digest: digest))
        _ = try await store.install(downloadedAssetURL: archive, release: makeRelease(version: "1.1.0", archive: archive, digest: digest))

        _ = try await store.activateTracked(version: "1.0.0")
        let activationB = try await store.activateTracked(version: "1.1.0")
        // Simulate ABA: 1.1.0 -> 1.0.0 -> 1.1.0 under a newer commit identity
        _ = try await store.activateTracked(version: "1.0.0")
        let newerActivationB = try await store.activateTracked(version: "1.1.0")
        try expect(activationB.commitID != newerActivationB.commitID, "[§28.1] commit IDs must be unique per activation")

        do {
            _ = try await store.activate(
                version: "1.0.0",
                expectedCurrentVersion: "1.1.0",
                expectedCommitID: activationB.commitID
            )
            throw RegressionFailure("[§28.1] stale ABA rollback with mismatched commitID was allowed")
        } catch is CLIProxyGatewayError {
            let currentVer = try await store.currentVersion()
            let currentCommit = await store.currentCommitID()
            try expect(currentVer == "1.1.0", "[§28.1] rejected ABA rollback changed active version")
            try expect(currentCommit == newerActivationB.commitID, "[§28.1] rejected ABA rollback altered commit ID")
        }

        // [§35.3] Fault-test failed publication and fresh-store read: active version and commit ID must remain atomic
        do {
            _ = try await store.activateTracked(
                version: "1.0.0",
                publicationFault: {
                    throw CLIProxyGatewayError.fileSystem("simulated publication failure")
                }
            )
            throw RegressionFailure("[§35.3] faulted activation unexpectedly succeeded")
        } catch is CLIProxyGatewayError {
            let freshStore = CLIProxyBinaryStore(
                paths: paths,
                extractor: CLIProxySecureArchiveExtractor(),
                signer: NoopSigner(),
                validator: NoopValidator()
            )
            let verAfterFault = try await freshStore.currentVersion()
            let commitAfterFault = await freshStore.currentCommitID()
            try expect(verAfterFault == "1.1.0", "[§35.3] failed publication changed active version to \(verAfterFault ?? "nil")")
            try expect(commitAfterFault == newerActivationB.commitID, "[§35.3] failed publication lost or altered active commit ID")
        }

        // [§35.3] Obstructed legacy .active-commit-id directory fault must fail before mutating current symlink
        let legacyCommitDir = paths.root.appendingPathComponent(".active-commit-id", isDirectory: true)
        try fileManager.createDirectory(at: legacyCommitDir, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: legacyCommitDir) }
        do {
            _ = try await store.activateTracked(version: "1.0.0")
            throw RegressionFailure("[§35.3] activation with obstructed .active-commit-id directory unexpectedly succeeded")
        } catch is CLIProxyGatewayError {
            let freshStore = CLIProxyBinaryStore(
                paths: paths,
                extractor: CLIProxySecureArchiveExtractor(),
                signer: NoopSigner(),
                validator: NoopValidator()
            )
            let verAfterDirFault = try await freshStore.currentVersion()
            let commitAfterDirFault = await freshStore.currentCommitID()
            try expect(verAfterDirFault == "1.1.0" && commitAfterDirFault == newerActivationB.commitID,
                       "[§35.3] obstructed .active-commit-id fault altered active version or commit ID")
        }
        try? fileManager.removeItem(at: legacyCommitDir)
    }

    private static func testLockedVersionDelete() async throws {
        let fileManager = FileManager.default
        let root = try makeScratchRoot("AIUsage-CPA-LockedDel")
        defer { try? fileManager.removeItem(at: root) }
        let archive = try makeArchive(root: root, duplicateBinary: false)
        let digest = try sha256(of: archive)
        let paths = try CLIProxyPaths(root: root.appendingPathComponent("store"))
        let store = CLIProxyBinaryStore(
            paths: paths,
            extractor: CLIProxySecureArchiveExtractor(),
            signer: NoopSigner(),
            validator: NoopValidator()
        )
        _ = try await store.install(downloadedAssetURL: archive, release: makeRelease(version: "1.0.0", archive: archive, digest: digest))
        _ = try await store.install(downloadedAssetURL: archive, release: makeRelease(version: "1.1.0", archive: archive, digest: digest))
        _ = try await store.activate(version: "1.0.0")
        let v11Dir = try paths.versionDirectory("1.1.0")

        // Live sibling runtime.pid.json blocks version deletion
        let pidRecord: [String: Any] = [
            "pid": Int(ProcessInfo.processInfo.processIdentifier),
            "binaryPath": try paths.versionDirectory("1.0.0").appendingPathComponent(paths.binaryName).path,
            "configPath": paths.configURL.path
        ]
        let pidURL = paths.root.appendingPathComponent("runtime.pid.json")
        try JSONSerialization.data(withJSONObject: pidRecord).write(to: pidURL)
        do {
            try await store.delete(version: "1.1.0")
            throw RegressionFailure("[§28.2] delete(version:) bypassed live sibling runtime fence")
        } catch is CLIProxyGatewayError {
            try expect(fileManager.fileExists(atPath: v11Dir.path), "[§28.2] blocked delete removed version directory")
        }
        try fileManager.removeItem(at: pidURL)

        // Unconfirmed listener fence blocks version deletion
        let unconfirmedURL = paths.root.appendingPathComponent("runtime.unconfirmed.json")
        try Data(#"{"pid":null,"port":8317,"bindHost":"127.0.0.1"}"#.utf8).write(to: unconfirmedURL)
        do {
            try await store.delete(version: "1.1.0")
            throw RegressionFailure("[§28.2] delete(version:) bypassed unconfirmed listener fence")
        } catch is CLIProxyGatewayError {
            try expect(fileManager.fileExists(atPath: v11Dir.path), "[§28.2] blocked delete removed version directory")
        }
        try fileManager.removeItem(at: unconfirmedURL)

        // Active current version with v-prefix cannot be deleted
        do {
            try await store.delete(version: "v1.0.0")
            throw RegressionFailure("[§28.2] delete(v1.0.0) bypassed normalized currentVersion guard")
        } catch CLIProxyGatewayError.cannotDeleteCurrentVersion {}

        // Now unfenced inactive version deletes cleanly
        try await store.delete(version: "1.1.0")
        try expect(!fileManager.fileExists(atPath: v11Dir.path), "[§28.2] unfenced delete failed to remove inactive version")
    }

    private static func testLatestOfficialReleaseEndToEnd() async throws {
        let fileManager = FileManager.default
        let root = try makeScratchRoot("AIUsage-CPA-Live")
        defer { try? fileManager.removeItem(at: root) }

        let release = try await CLIProxyReleaseClient().latestStableRelease()
        let downloaded = try await CLIProxyAssetDownloader().download(release)
        defer { try? fileManager.removeItem(at: downloaded.cleanupDirectory) }

        let paths = try CLIProxyPaths(root: root)
        let store = CLIProxyBinaryStore(paths: paths)
        _ = try await store.install(downloadedAssetURL: downloaded.fileURL, release: release)
        _ = try await store.activate(version: release.version)
        let current = try await store.currentVersion()
        try expect(current == release.version, "live official release was not activated")
        let binaryURL = try await store.currentBinaryURL()
        try expect(binaryURL != nil, "live official binary is missing")
        guard let binaryURL else { throw RegressionFailure("live binary URL was nil") }

        let port = try availableLoopbackPort()
        let settings = CLIProxyGatewaySettings(
            port: port,
            autoStart: false,
            routingStrategy: .roundRobin,
            requestRetry: 2,
            proxyURL: "",
            enablePlugins: false
        )
        let secrets = CLIProxySecrets(
            managementKey: "live-management-\(UUID().uuidString)",
            clientAPIKey: "live-client-\(UUID().uuidString)"
        )
        try CLIProxyConfigStore(paths: paths).writeRuntimeConfig(settings: settings, secrets: secrets)
        func makeProcess() -> Process {
            let process = Process()
            process.executableURL = binaryURL
            process.arguments = ["-config", paths.configURL.path]
            var environment = ProcessInfo.processInfo.environment
            environment.removeValue(forKey: "MANAGEMENT_PASSWORD")
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return process
        }
        var process = makeProcess()
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let endpoint = URL(string: "http://127.0.0.1:\(port)")!
        try await waitForHealth(endpoint.appendingPathComponent("healthz"), process: process)
        let management = CLIProxyManagementClient(
            baseURL: endpoint,
            managementKey: secrets.managementKey,
            clientAPIKey: secrets.clientAPIKey
        )
        let authFiles = try await management.listAuthFiles()
        try expect(authFiles.isEmpty, "fresh live runtime unexpectedly contains auth files")
        let regressionName = "aiusage-regression.json"
        try await management.uploadAuthFile(
            data: Data(#"{"type":"codex","email":"regression@example.com","access_token":"placeholder"}"#.utf8),
            name: regressionName
        )
        var uploaded = try await management.listAuthFiles()
        try expect(uploaded.contains(where: { $0.name == regressionName }), "Management API auth upload was not listed")
        try await management.setDisabled(true, name: regressionName)
        uploaded = try await management.listAuthFiles()
        try expect(uploaded.first(where: { $0.name == regressionName })?.disabled == true, "Management API auth disable failed")
        try await management.patchAuthFileFields(name: regressionName, note: "regression", priority: 9)
        uploaded = try await management.listAuthFiles()
        let patched = uploaded.first(where: { $0.name == regressionName })
        try expect(patched?.note == "regression" && patched?.priority == 9, "Management API auth metadata patch failed")
        let downloadedAuth = try await management.downloadAuthFile(name: regressionName)
        let downloadedObject = try JSONSerialization.jsonObject(with: downloadedAuth) as? [String: Any]
        try expect(downloadedObject?["email"] as? String == "regression@example.com", "Management API auth download failed")
        try await management.deleteAuthFile(name: regressionName)
        uploaded = try await management.listAuthFiles()
        try expect(!uploaded.contains(where: { $0.name == regressionName }), "Management API auth delete failed")
        _ = try await management.listPlugins()

        let advancedName = "AIUsage Advanced \(UUID().uuidString.prefix(8))"
        let advancedProvider: [String: Any] = [
            "name": advancedName,
            "base-url": "https://advanced.example.invalid/v1",
            "api-key-entries": [["api-key": "placeholder"]],
            "models": [[
                "name": "advanced-model",
                "alias": "advanced-model",
                "input-modalities": ["text"],
                "thinking": ["type": "levels", "levels": ["low", "high"]]
            ]]
        ]
        var seedRequest = URLRequest(url: endpoint.appendingPathComponent("v0/management/openai-compatibility"))
        seedRequest.httpMethod = "PUT"
        seedRequest.setValue("Bearer \(secrets.managementKey)", forHTTPHeaderField: "Authorization")
        seedRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        seedRequest.httpBody = try JSONSerialization.data(withJSONObject: [advancedProvider])
        let (seedData, seedResponse) = try await URLSession.shared.data(for: seedRequest)
        guard let seedHTTP = seedResponse as? HTTPURLResponse, (200..<300).contains(seedHTTP.statusCode) else {
            throw RegressionFailure("could not seed advanced OpenAI-compatible provider: \(String(data: seedData, encoding: .utf8) ?? "unknown")")
        }

        let compatName = "AIUsage Regression \(UUID().uuidString.prefix(8))"
        let compat = CLIProxyOpenAICompatibleProvider(
            name: compatName,
            priority: 1,
            disabled: false,
            prefix: "regression",
            baseURL: "https://example.invalid/v1",
            apiKeyEntries: [.init(apiKey: "placeholder", proxyURL: nil)],
            models: [.init(name: "regression-model", alias: "", forceMapping: false)],
            headers: nil,
            disableCooling: false
        )
        try await management.addOpenAICompatibleProvider(compat)
        try await Task.sleep(for: .milliseconds(300))
        var rawRequest = URLRequest(url: endpoint.appendingPathComponent("v0/management/openai-compatibility"))
        rawRequest.setValue("Bearer \(secrets.managementKey)", forHTTPHeaderField: "Authorization")
        let (rawData, rawResponse) = try await URLSession.shared.data(for: rawRequest)
        guard let rawHTTP = rawResponse as? HTTPURLResponse, (200..<300).contains(rawHTTP.statusCode),
              let rawRoot = try JSONSerialization.jsonObject(with: rawData) as? [String: Any],
              let rawProviders = rawRoot["openai-compatibility"] as? [[String: Any]],
              let preserved = rawProviders.first(where: { ($0["name"] as? String) == advancedName }),
              let preservedModels = preserved["models"] as? [[String: Any]],
              preservedModels.first?["thinking"] != nil,
              preservedModels.first?["input-modalities"] != nil else {
            throw RegressionFailure("adding a provider erased advanced fields from an existing provider")
        }
        try await management.setOpenAICompatibleProviderDisabled(name: compatName, disabled: true)
        let disabledProviders = try await management.listOpenAICompatibleProviders()
        try expect(disabledProviders.first(where: { $0.name == compatName })?.disabled == true, "OpenAI-compatible provider disable did not persist")
        try await management.setOpenAICompatibleProviderDisabled(name: compatName, disabled: false)

        process.terminate()
        process.waitUntilExit()
        try CLIProxyConfigStore(paths: paths).writeRuntimeConfig(settings: settings, secrets: secrets)
        let mergedConfig = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(mergedConfig.contains(compatName), "OpenAI-compatible provider was erased by runtime config reconciliation")
        try expect(mergedConfig.contains(paths.pluginsDirectory.path), "stable plugin directory was lost before restart")

        process = makeProcess()
        try process.run()
        try await waitForHealth(endpoint.appendingPathComponent("healthz"), process: process)
        let providersAfterRestart = try await management.listOpenAICompatibleProviders()
        try expect(providersAfterRestart.contains(where: { $0.name == compatName }), "OpenAI-compatible provider did not survive CPA restart")
        try expect(providersAfterRestart.contains(where: { $0.name == advancedName }), "advanced OpenAI-compatible provider did not survive CPA restart")
        let modelsAfterRestart = try await management.availableModels()
        try expect(
            modelsAfterRestart.contains(where: { $0.id.contains("regression-model") }),
            "OpenAI-compatible model was not registered after CPA restart"
        )
        let catalogAfterRestart = try await management.modelCatalog()
        try expect(
            catalogAfterRestart.openAIModels.contains(where: { $0.id.contains("regression-model") }),
            "protocol catalog changed the OpenAI model source used for managed distribution"
        )
        let regressionOpenAIRouteIDs = catalogAfterRestart.openAIModels
            .map(\.id)
            .filter { $0.lowercased().contains("regression-model") }
        try expect(
            !regressionOpenAIRouteIDs.isEmpty,
            "live OpenAI model view did not expose a regression route ID"
        )
        for openAIRouteID in Set(regressionOpenAIRouteIDs) {
            let canonicalKey = CLIProxyModelIdentity.normalizedKey(for: openAIRouteID)
            let matchingEntries = catalogAfterRestart.entries.filter {
                CLIProxyModelIdentity.normalizedKey(for: $0.model.id) == canonicalKey
            }
            try expect(
                matchingEntries.count == 1,
                "one live OpenAI route resolved to \(matchingEntries.count) canonical entries: \(openAIRouteID)"
            )
            guard let regressionCatalogEntry = matchingEntries.first else {
                throw RegressionFailure("live protocol catalog did not include route \(openAIRouteID)")
            }
            try expect(
                regressionCatalogEntry.models(for: .openAI).contains(where: {
                    CLIProxyModelIdentity.normalizedKey(for: $0.id) == canonicalKey
                }),
                "live catalog entry lost its OpenAI API route"
            )

            let liveAnthropicRoutes = regressionCatalogEntry.models(for: .anthropic)
            try expect(
                liveAnthropicRoutes.contains(where: {
                    $0.id.hasPrefix(CLIProxyModelIdentity.anthropicCompatibilityPrefix)
                }),
                "live catalog did not preserve the Anthropic compatibility route ID"
            )
            try expect(
                liveAnthropicRoutes.contains(where: {
                    CLIProxyModelIdentity.normalizedKey(
                        for: CLIProxyModelIdentity.canonicalID(for: $0.id, protocol: .anthropic)
                    ) == canonicalKey
                }),
                "live Anthropic route did not resolve to the unified canonical model"
            )
            try expect(
                regressionCatalogEntry.providerID != "claude",
                "Anthropic API compatibility route overrode the live model provider brand"
            )
        }
        try expect(
            catalogAfterRestart.entries.allSatisfy { !$0.protocols.isEmpty },
            "protocol catalog produced an entry without a protocol"
        )
        try await management.deleteOpenAICompatibleProvider(name: compatName)
        try await management.deleteOpenAICompatibleProvider(name: advancedName)
        _ = try await management.availableModels()

        process.terminate()
        process.waitUntilExit()
        var lanSettings = settings
        lanSettings.allowLANAccess = true
        try CLIProxyConfigStore(paths: paths).writeRuntimeConfig(settings: lanSettings, secrets: secrets)
        let lanConfig = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(lanConfig.contains("host: \"0.0.0.0\""), "live LAN configuration did not bind all IPv4 interfaces")
        try expect(lanConfig.contains("allow-remote: false"), "live LAN configuration exposed remote management")
        process = makeProcess()
        try process.run()
        try await waitForHealth(endpoint.appendingPathComponent("healthz"), process: process)
        _ = try await management.listAuthFiles()
        print("Verified official CLIProxyAPI v\(release.version) end to end")
    }

    private static func waitForHealth(_ url: URL, process: Process) async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            if let (_, response) = try? await URLSession.shared.data(from: url),
               let http = response as? HTTPURLResponse,
               (200..<300).contains(http.statusCode) { return }
            try await Task.sleep(for: .milliseconds(200))
        }
        throw RegressionFailure("live runtime health check failed")
    }

    private static func availableLoopbackPort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw RegressionFailure("could not create socket") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw RegressionFailure("could not bind socket") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(descriptor, $0, &length)
            }
        }) == 0 else { throw RegressionFailure("could not read socket port") }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private static func makeArchive(root: URL, duplicateBinary: Bool) throws -> URL {
        let fileManager = FileManager.default
        let payload = root.appendingPathComponent("payload", isDirectory: true)
        let primaryDirectory = payload.appendingPathComponent("release", isDirectory: true)
        try fileManager.createDirectory(at: primaryDirectory, withIntermediateDirectories: true)
        try Data("test-binary".utf8).write(to: primaryDirectory.appendingPathComponent("CLIProxyAPI"))
        if duplicateBinary {
            let duplicateDirectory = payload.appendingPathComponent("duplicate", isDirectory: true)
            try fileManager.createDirectory(at: duplicateDirectory, withIntermediateDirectories: true)
            try Data("duplicate".utf8).write(to: duplicateDirectory.appendingPathComponent("CLIProxyAPI"))
        }
        let archive = root.appendingPathComponent("CLIProxyAPI_test_darwin_aarch64.tar.gz")
        try run("/usr/bin/tar", ["-czf", archive.path, "-C", payload.path, "."])
        return archive
    }

    private static func makeRelease(version: String, archive: URL, digest: String) -> CLIProxyRelease {
        CLIProxyRelease(
            tagName: "v\(version)",
            version: version,
            assetName: archive.lastPathComponent,
            downloadURL: URL(string: "https://example.invalid/\(archive.lastPathComponent)")!,
            sha256: digest,
            size: (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        )
    }

    private static func sha256(of url: URL) throws -> String {
        let data = try Data(contentsOf: url)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try expect(process.terminationStatus == 0, "command failed: \(executable)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw RegressionFailure(message) }
    }

    private static func occurrences(of needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }
}

nonisolated private struct RegressionFailure: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}
