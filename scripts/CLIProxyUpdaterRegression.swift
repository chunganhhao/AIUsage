import CryptoKit
import Darwin
import Foundation

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

    private static func testRuntimeConfiguration() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AIUsage-CPA-Config-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = try CLIProxyPaths(root: root)
        let store = CLIProxyConfigStore(paths: paths)
        var settings = CLIProxyGatewaySettings.default
        settings.port = 14_420
        settings.routingStrategy = .fillFirst
        settings.requestRetry = 4
        settings.proxyURL = "http://127.0.0.1:7890/\"quoted"
        settings.enablePlugins = true
        try store.saveSettings(settings)
        try store.writeRuntimeConfig(
            settings: settings,
            secrets: CLIProxySecrets(managementKey: "management-secret", clientAPIKey: "client-secret")
        )
        try expect(store.loadSettings() == settings, "gateway settings did not round-trip")
        let config = try String(contentsOf: paths.configURL, encoding: .utf8)
        try expect(config.contains("strategy: \"fill-first\""), "routing strategy was not generated")
        try expect(config.contains("host: \"127.0.0.1\""), "loopback-only host was not generated by default")
        try expect(config.contains("request-retry: 4"), "retry count was not generated")
        try expect(config.contains("max-retry-interval: 30"), "max retry interval was not generated")
        try expect(config.contains("max-retry-credentials: 0"), "max retry credentials was not generated")
        try expect(config.contains("switch-project: true"), "quota switch-project was not generated")
        try expect(config.contains("switch-preview-model: true"), "quota switch-preview-model was not generated")
        try expect(config.contains("antigravity-credits: true"), "quota antigravity-credits was not generated")
        try expect(config.contains("management-secret"), "management secret was not generated")
        try expect(config.contains("client-secret"), "client key was not generated")
        try expect(config.contains("ws-auth: true"), "WebSocket client authentication was not enabled")
        try expect(config.contains("\\\"quoted"), "YAML string was not escaped")
        try expect(config.contains("dir: \"\(paths.pluginsDirectory.path)\""), "stable plugin directory was not generated")

        let migrated = try JSONDecoder().decode(
            CLIProxyGatewaySettings.self,
            from: Data(#"{"port":14420,"autoStart":true,"routingStrategy":"round-robin","requestRetry":2,"proxyURL":"","enablePlugins":false}"#.utf8)
        )
        try expect(!migrated.allowLANAccess, "legacy settings did not migrate to LAN access disabled")
        try expect(migrated.quotaSwitchProject, "legacy settings did not default quota switch-project on")
        try expect(migrated.maxRetryInterval == 30, "legacy settings did not default max-retry-interval to 30")

        let personalPaths = try CLIProxyPaths(root: root.appendingPathComponent("personal-policy"))
        let personalStore = CLIProxyConfigStore(paths: personalPaths)
        var personal = CLIProxyGatewaySettings.default
        personal.requestRetry = 1
        personal.quotaSwitchProject = false
        personal.quotaAntigravityCredits = false
        try personalStore.saveSettings(personal)
        let retained = personalStore.loadSettings()
        try expect(!retained.quotaSwitchProject && !retained.quotaAntigravityCredits && retained.requestRetry == 1,
                   "personal build changed persisted routing policy")
        try personalStore.writeRuntimeConfig(settings: retained, secrets: CLIProxySecrets(managementKey: "management-fixture", clientAPIKey: "client-fixture"))
        let personalYAML = try String(contentsOf: personalPaths.configURL, encoding: .utf8)
        try expect(personalYAML.contains("switch-project: false") && personalYAML.contains("antigravity-credits: false") && personalYAML.contains("request-retry: 1"),
                   "personal build did not preserve runtime YAML routing policy")

        let generatedPluginBlock = "plugins:\n  enabled: true\n  dir: \"\(paths.pluginsDirectory.path)\""
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
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("AIUsage-CPA-Default-Plugin-Migration-\(UUID().uuidString)")
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

    private static func testCredentialAdapters() throws {
        let codex = Data(#"{"tokens":{"access_token":"access","refresh_token":"refresh","id_token":"id","account_id":"account"}}"#.utf8)
        let converted = try CLIProxyCredentialAdapter.convert(
            providerId: "codex",
            credentialId: "credential-1",
            accountLabel: "user@example.com",
            metadata: [:],
            sourceData: codex
        )
        let object = try JSONSerialization.jsonObject(with: converted) as? [String: Any]
        try expect(object?["type"] as? String == "codex", "Codex adapter did not set CPA type")
        try expect(object?["access_token"] as? String == "access", "Codex adapter did not flatten access token")
        try expect(object?["refresh_token"] as? String == "refresh", "Codex adapter did not flatten refresh token")
        try expect(object?["aiusage_credential_id"] as? String == "credential-1", "adapter linkage marker is missing")

        do {
            _ = try CLIProxyCredentialAdapter.convert(
                providerId: "antigravity",
                credentialId: "credential-3",
                accountLabel: nil,
                metadata: [:],
                sourceData: Data(#"{"access_token":"access"}"#.utf8)
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
        let cpa = try CLIProxyCredentialAdapter.convert(
            providerId: "gemini",
            credentialId: "credential-gemini",
            accountLabel: "user@example.com",
            metadata: [:],
            sourceData: native
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
            sourceData: nativeRoundTrip
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
        includePlanClaim: Bool = true
    ) throws -> Data {
        var authClaims: [String: Any] = ["chatgpt_account_id": accountID]
        if includeChatGPTUserID { authClaims["chatgpt_user_id"] = userID }
        if includePlanClaim { authClaims["chatgpt_plan_type"] = plan }
        let claims: [String: Any] = [
            "sub": userID,
            "email": email,
            "https://api.openai.com/auth": authClaims
        ]
        var object: [String: Any] = [
            "type": "codex",
            "email": email,
            "id_token": try unsignedJWT(claims),
            "access_token": accessToken,
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
        let root = fileManager.temporaryDirectory.appendingPathComponent("AIUsage-CPA-Test-\(UUID().uuidString)")
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
        let root = fileManager.temporaryDirectory.appendingPathComponent("AIUsage-CPA-Duplicate-\(UUID().uuidString)")
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

    private static func testLatestOfficialReleaseEndToEnd() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("AIUsage-CPA-Live-\(UUID().uuidString)")
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
