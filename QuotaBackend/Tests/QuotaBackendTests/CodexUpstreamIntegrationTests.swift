import CryptoKit
import XCTest
@testable import QuotaBackend

/// Reset-card reads must use the private credential policy, not upstream's older token selection.
final class CodexUpstreamIntegrationTests: XCTestCase {
    private var directory: URL!
    private let identity = CodexAccountIdentity(accountId: "integration-workspace", userId: "member-a")
    private let endpoint = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    private let oauth = "https://auth.openai.com/oauth/token"
    private let list = #"{"available_count":1,"credits":[{"id":"chosen","reset_type":"codex_rate_limits","status":"available","expires_at":null}]}"#

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CodexLinkedCredentialCopies.resetForTesting()
        StubURLProtocol.install(hosts: ["chatgpt.com", "auth.openai.com"])
    }

    override func tearDown() {
        StubURLProtocol.uninstall()
        CodexLinkedCredentialCopies.resetForTesting()
        try? FileManager.default.removeItem(at: directory)
    }

    private func token(_ name: String, issuedAt: Int, user: String = "member-a") throws -> String {
        let payload: [String: Any] = [
            "jti": name, "iat": issuedAt, "exp": Int(Date().timeIntervalSince1970) + 864_000,
            "https://api.openai.com/auth": ["chatgpt_account_id": "integration-workspace", "chatgpt_user_id": user]
        ]
        return try jwt(payload)
    }

    private func jwt(_ payload: [String: Any]) throws -> String {
        let encoded = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).fixture"
    }

    private func write(_ name: String, access: String, refresh: String? = nil, nested: [String: Any]? = nil) throws -> URL {
        let url = directory.appendingPathComponent(name)
        var json: [String: Any] = ["access_token": access, "last_refresh": SharedFormatters.iso8601String(from: Date())]
        if let refresh { json["refresh_token"] = refresh }
        if let nested { json["tokens"] = nested }
        try JSONSerialization.data(withJSONObject: json, options: .sortedKeys).write(to: url)
        return url
    }

    private func credential(_ url: URL, source: URL? = nil) -> AccountCredential {
        var metadata = ["accountId": "integration-workspace", "workspaceUserId": "member-a"]
        if let source { metadata["sourcePath"] = source.path }
        return AccountCredential(providerId: "codex", authMethod: .authFile, credential: url.path, metadata: metadata)
    }

    func testResetListFallsBackToSameSecondAlternateAndHealsOnlyAfterSuccess() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let rejected = try token("flat-rejected", issuedAt: now)
        let accepted = try token("nested-winner", issuedAt: now)
        let own = try write("own.json", access: rejected, refresh: "flat-refresh",
                            nested: ["access_token": accepted, "refresh_token": "nested-refresh"])
        let before = try Data(contentsOf: own)
        StubURLProtocol.respond(endpoint, handler: { request in
            // A speculative candidate must not overwrite either chain before the GET validates it.
            XCTAssertEqual(try? Data(contentsOf: own), before)
            return request.headers["Authorization"] == "Bearer \(accepted)" ? (200, self.list) : (401, "{}")
        })
        let result = try await CodexProvider(homeDirectory: directory.path).fetchResetCredits(with: credential(own), identity: identity)
        XCTAssertEqual(result.availableCount, 1)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.headers["Authorization"] }, ["Bearer \(rejected)", "Bearer \(accepted)"])
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(oauth))
        let healed = try CodexProvider(homeDirectory: directory.path).loadCredentials(from: own.path)
        XCTAssertEqual(healed.accessToken, accepted)
        XCTAssertEqual(healed.refreshToken, "nested-refresh")
    }

    func testConsumeAdoptsNewerSourceWithoutReplayingRotatedRefreshToken() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let stale = try token("old", issuedAt: now - 100)
        let fresh = try token("new", issuedAt: now)
        let own = try write("own.json", access: stale, refresh: "rotated-out")
        let source = try write("source.json", access: fresh, refresh: "current")
        StubURLProtocol.respond(endpoint, body: list)
        StubURLProtocol.respond(endpoint + "/consume", body: #"{"code":"reset","windows_reset":2}"#)
        let operations = CodexResetCreditsOperations(journalURL: directory.appendingPathComponent("journal.json"),
                                                    provider: CodexProvider(homeDirectory: directory.path))
        let result = try await operations.consume(credential: credential(own, source: source), identity: identity, creditID: "chosen")
        XCTAssertEqual(result.code, .reset)
        XCTAssertEqual(StubURLProtocol.requests.map(\.method), ["GET", "POST"])
        XCTAssertTrue(StubURLProtocol.requests.allSatisfy { $0.headers["Authorization"] == "Bearer \(fresh)" })
        XCTAssertEqual(try CodexProvider(homeDirectory: directory.path).loadCredentials(from: own.path).refreshToken, "current")
    }

    func testFailedSourceReadNeverOverwritesManagedCopy() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let old = try token("own", issuedAt: now - 100)
        let sourceToken = try token("source", issuedAt: now)
        let own = try write("own.json", access: old)
        let source = try write("source.json", access: sourceToken)
        let before = try Data(contentsOf: own)
        StubURLProtocol.respond(endpoint, handler: { request in
            request.headers["Authorization"] == "Bearer \(old)" ? (401, "{}") : (500, "{}")
        })
        do {
            _ = try await CodexProvider(homeDirectory: directory.path).fetchResetCredits(with: credential(own, source: source), identity: identity)
            XCTFail("Failed recovery read must propagate")
        } catch { XCTAssertEqual((error as? ProviderError)?.code, "reset_list_failed") }
        XCTAssertEqual(try Data(contentsOf: own), before)
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testResetRejectsInternalJWTIdentityConflictBeforeAnyRequest() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let own = try write("own.json", access: token("access", issuedAt: now))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        json["id_token"] = try token("id", issuedAt: now, user: "member-b")
        try JSONSerialization.data(withJSONObject: json).write(to: own)
        let provider = CodexProvider(homeDirectory: directory.path)
        let creds = try provider.loadCredentials(from: own.path)
        XCTAssertTrue(creds.hasInternalIdentityConflict)
        XCTAssertThrowsError(try provider.validateResetIdentity(creds, identity: identity))
        do {
            _ = try await provider.fetchResetCredits(with: credential(own), identity: identity)
            XCTFail("Conflicting identity must not read reset cards")
        } catch { XCTAssertEqual((error as? ProviderError)?.code, "account_mismatch") }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testResetCountsRejectBooleansFractionsAndNegativeValues() throws {
        let provider = CodexProvider(homeDirectory: directory.path)
        for raw in ["true", "false", "-1", "1.5", "null", "\"3\""] {
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data("{\"rate_limit_reset_credits\":{\"available_count\":\(raw)}}".utf8)) as? [String: Any])
            let usage = provider.parseResponse(json, accountId: "integration-workspace", source: SourceInfo(mode: "manual", type: "fixture"), fallbackEmail: nil)
            XCTAssertNil(usage.codexResetCreditsAvailableCount, raw)
        }
    }

    private func recursiveArchiveManifest(at root: URL) throws -> [String] {
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        guard let enumerator = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else { return [] }
        var entries: [String] = []
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let resolvedItem = item.resolvingSymlinksInPath().standardizedFileURL
            let rel = resolvedItem.path.replacingOccurrences(of: resolvedRoot.path + "/", with: "")
            if values.isSymbolicLink == true {
                let target = (try? fm.destinationOfSymbolicLink(atPath: item.path)) ?? ""
                entries.append("L:\(rel)->\(target)")
                enumerator.skipDescendants()
            } else if values.isRegularFile == true {
                let data = try Data(contentsOf: item)
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                entries.append("F:\(rel):\(data.count):\(digest)")
            }
        }
        return entries.sorted()
    }

    func testUsageAndResetReadNeverMutateLegacyCPAAuthFiles() async throws {
        let folder = "Library/Application Support/AIUsage/CLIProxyAPI/auth"
        let archiveDir = directory.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
        let own = try write(folder + "/aiusage-codex-fixture.json", access: token("monthly", issuedAt: Int(Date().timeIntervalSince1970)), refresh: "arch-r0")
        var auth = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        auth["type"] = "codex"
        auth["account_id"] = "integration-workspace"
        auth["user_id"] = "member-a"
        try JSONSerialization.data(withJSONObject: auth).write(to: own)
        let preExistingLock = archiveDir.appendingPathComponent("preexisting.lock")
        try Data("keep-me".utf8).write(to: preExistingLock)
        try CodexPoolProtectionSettings.setEnabled(true, homeDirectory: directory.path)

        let staleArchive = archiveDir.appendingPathComponent("nested/stale-cpa.json")
        try FileManager.default.createDirectory(at: staleArchive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let staleAccess = try token("arch-stale", issuedAt: Int(Date().timeIntervalSince1970) - 9 * 86_400)
        let freshAccess = try token("arch-fresh", issuedAt: Int(Date().timeIntervalSince1970))
        try JSONSerialization.data(withJSONObject: [
            "type": "codex",
            "account_id": "integration-workspace",
            "user_id": "member-a",
            "last_refresh": "2020-01-01T00:00:00Z",
            "access_token": staleAccess,
            "refresh_token": "stale-arch-r0"
        ]).write(to: staleArchive)

        let linkDir = directory.appendingPathComponent("outside-aliases", isDirectory: true)
        try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let outsideTarget = linkDir.appendingPathComponent("outside-target.json")
        try JSONSerialization.data(withJSONObject: [
            "type": "codex",
            "account_id": "integration-workspace",
            "user_id": "member-a",
            "last_refresh": "2020-01-01T00:00:00Z",
            "access_token": staleAccess,
            "id_token": staleAccess,
            "refresh_token": "r-outside-orig"
        ]).write(to: outsideTarget)
        let insideSymlinkOut = archiveDir.appendingPathComponent("inside-symlink-out.json")
        let symlinkToArchiveFile = linkDir.appendingPathComponent("alias-file.json")
        let symlinkToArchiveDir = linkDir.appendingPathComponent("alias-dir")
        let symlinkToNestedDir = linkDir.appendingPathComponent("alias-nested-dir")
        let brokenHop1 = linkDir.appendingPathComponent("broken-hop1.json")
        let brokenHop2 = linkDir.appendingPathComponent("broken-hop2.json")
        try FileManager.default.createSymbolicLink(at: insideSymlinkOut, withDestinationURL: outsideTarget)
        try FileManager.default.createSymbolicLink(at: symlinkToArchiveFile, withDestinationURL: own)
        try FileManager.default.createSymbolicLink(at: symlinkToArchiveDir, withDestinationURL: archiveDir)
        try FileManager.default.createSymbolicLink(at: symlinkToNestedDir, withDestinationURL: staleArchive.deletingLastPathComponent())
        try FileManager.default.createSymbolicLink(atPath: brokenHop1.path, withDestinationPath: archiveDir.appendingPathComponent("nonexistent/missing.json").path)
        try FileManager.default.createSymbolicLink(atPath: brokenHop2.path, withDestinationPath: "broken-hop1.json")
        let nestedViaDirAlias = symlinkToArchiveDir.appendingPathComponent("nested/stale-cpa.json")
        let dotDotViaNestedAlias = symlinkToNestedDir.path + "/../missing-dotdot.json"
        let upperArchivePath = directory.appendingPathComponent("Library/Application Support/AIUsage/CLIPROXYAPI/AUTH/nested/stale-cpa.json").path
        XCTAssertTrue(CodexCredentialPolicy.isLegacyCPAArchivePath(brokenHop1.path, homeDirectory: directory.path))
        XCTAssertTrue(CodexCredentialPolicy.isLegacyCPAArchivePath(brokenHop2.path, homeDirectory: directory.path))
        XCTAssertTrue(CodexCredentialPolicy.isLegacyCPAArchivePath(dotDotViaNestedAlias, homeDirectory: directory.path))
        XCTAssertTrue(CodexCredentialPolicy.isLegacyCPAArchivePath(upperArchivePath, homeDirectory: directory.path))
        XCTAssertTrue(CodexCredentialPolicy.isLegacyCPAArchivePath("~/Library/Application Support/AIUsage/CLIProxyAPI/auth/fixture.json"))
        XCTAssertFalse(CodexCredentialPolicy.isLegacyCPAArchivePath(outsideTarget.path, homeDirectory: directory.path))

        let provider = CodexProvider(homeDirectory: directory.path)
        let before = try Data(contentsOf: own)
        let manifestBefore = try recursiveArchiveManifest(at: archiveDir)

        // 1. Fresh archive read (reset credits + usage) leaves recursive manifest identical (0 locks created, preexisting.lock kept)
        StubURLProtocol.respond(endpoint, body: list)
        _ = try await provider.fetchResetCredits(with: credential(own), identity: identity)
        XCTAssertEqual(try Data(contentsOf: own), before, "Reset-card reads must not mutate legacy CPA files")
        XCTAssertEqual(try recursiveArchiveManifest(at: archiveDir), manifestBefore)

        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage", body: #"{"plan_type":"self_serve_business_usage_based","spend_control":{"individual_limit":{"limit":"1000","used":"980","used_percent":98}}}"#)
        let usage = try await provider.fetchUsage(with: credential(own))
        XCTAssertNil(usage.extra["circuitBreakerTripped"])
        XCTAssertEqual(try recursiveArchiveManifest(at: archiveDir), manifestBefore, "Codex usage fetch must not mutate or lock legacy CPA directory")

        // 2. Stale direct archive & symlink aliases never trigger OAuth refresh or write locks into archive
        let oauthResponseData = try JSONSerialization.data(withJSONObject: ["access_token": freshAccess, "refresh_token": "r-new"])
        StubURLProtocol.respond(oauth, body: String(decoding: oauthResponseData, as: UTF8.self))
        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage", handler: { req in
            req.headers["Authorization"] == "Bearer \(freshAccess)" ? (200, #"{"plan_type":"team"}"#) : (401, "{}")
        })
        let oauthCountBeforeDirect = StubURLProtocol.requestedURLs.filter { $0 == oauth }.count
        for target in [own, staleArchive, symlinkToArchiveFile, nestedViaDirAlias] {
            _ = try? await provider.fetchUsage(with: credential(target))
        }
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0 == oauth }.count, oauthCountBeforeDirect,
                       "Archive-only credentials must not burn single-use OAuth refresh tokens")
        XCTAssertEqual(try recursiveArchiveManifest(at: archiveDir), manifestBefore, "Symlink aliases and stale archive reads must not alter archive")

        // 3. Direct persist sink refuses archive paths, symlink aliases, and inside-archive symlinks
        let origLoaded = try provider.loadCredentials(from: own.path)
        let outsideTargetBefore = try Data(contentsOf: outsideTarget)
        let minted = CodexProvider.Credentials(
            authFile: own.path, accessToken: freshAccess, refreshToken: "r-new", idToken: origLoaded.idToken,
            accountId: origLoaded.accountId, accountEmail: origLoaded.accountEmail, jwtPlanType: origLoaded.jwtPlanType,
            jwtUserId: origLoaded.jwtUserId, needsRefresh: false, isApiKeyMode: false
        )
        provider.persistRefreshedCredentials(minted, replacing: origLoaded, to: own.path)
        provider.persistRefreshedCredentials(minted, replacing: origLoaded, to: symlinkToArchiveFile.path)
        provider.persistRefreshedCredentials(minted, replacing: origLoaded, to: nestedViaDirAlias.path)
        provider.persistRefreshedCredentials(minted, replacing: try provider.loadCredentials(from: outsideTarget.path), to: insideSymlinkOut.path)
        XCTAssertEqual(try Data(contentsOf: outsideTarget), outsideTargetBefore)
        XCTAssertEqual(try recursiveArchiveManifest(at: archiveDir), manifestBefore)

        // 4. Managed Codex copy outside archive whose saved sourcePath points to archive refreshes & writes normally without touching archive
        let managedOutside = linkDir.appendingPathComponent("managed-own.json")
        try JSONSerialization.data(withJSONObject: [
            "last_refresh": "2020-01-01T00:00:00Z",
            "tokens": ["account_id": "integration-workspace", "id_token": staleAccess, "access_token": staleAccess, "refresh_token": "r-managed"]
        ]).write(to: managedOutside)
        _ = try await provider.fetchUsage(with: credential(managedOutside, source: symlinkToArchiveFile))
        XCTAssertEqual(try provider.loadCredentials(from: managedOutside.path).accessToken, freshAccess)

        // 5. Switch flush & warmup healing skip archive/aliases while healing writable copies outside archive
        let liveNewer = linkDir.appendingPathComponent("live-newer.json")
        let flushOutside = linkDir.appendingPathComponent("flush-outside.json")
        let warmupOutside = linkDir.appendingPathComponent("warmup-outside.json")
        let stagedNewer = linkDir.appendingPathComponent("staged-newer.json")
        let newerEpoch = Int(Date().timeIntervalSince1970) + 10
        let newerAccess = try token("arch-newer", issuedAt: newerEpoch)
        let staleData = try JSONSerialization.data(withJSONObject: [
            "last_refresh": "2020-01-01T00:00:00Z",
            "tokens": ["account_id": "integration-workspace", "id_token": staleAccess, "access_token": staleAccess, "refresh_token": "r-stale-out"]
        ])
        let newerData = try JSONSerialization.data(withJSONObject: [
            "last_refresh": SharedFormatters.iso8601String(from: Date(timeIntervalSince1970: TimeInterval(newerEpoch))),
            "tokens": ["account_id": "integration-workspace", "id_token": newerAccess, "access_token": newerAccess, "refresh_token": "r-newer-out"]
        ])
        try newerData.write(to: liveNewer)
        try newerData.write(to: stagedNewer)
        try staleData.write(to: flushOutside)
        try staleData.write(to: warmupOutside)
        let flushedCount = CodexCredentialPolicy.flushLiveAuthToManagedCopies(
            candidatePaths: [liveNewer.path],
            excludingIdentity: CodexAccountIdentity(accountId: "other-ws", userId: "other-u"),
            loadCredentials: { [credential(staleArchive), credential(symlinkToArchiveFile), credential(flushOutside)] },
            homeDirectory: directory.path
        )
        XCTAssertEqual(flushedCount, 1)
        XCTAssertEqual(try provider.loadCredentials(from: flushOutside.path).accessToken, newerAccess)

        let healOk = OfficialWarmupProcess.healStagedCodexAuth(
            stagedAuth: stagedNewer,
            stagedBaselineData: staleData,
            destinations: [staleArchive.path, symlinkToArchiveFile.path, insideSymlinkOut.path, warmupOutside.path],
            expectedIdentity: identity,
            boundary: ManagedAuthImportBoundary(bundleIdentifier: "com.test", applicationSupportDirectory: linkDir.appendingPathComponent("AppSupport")),
            homeURL: directory
        )
        XCTAssertTrue(healOk)
        XCTAssertEqual(try provider.loadCredentials(from: warmupOutside.path).accessToken, newerAccess)
        XCTAssertEqual(try Data(contentsOf: outsideTarget), outsideTargetBefore)
        XCTAssertEqual(try recursiveArchiveManifest(at: archiveDir), manifestBefore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: preExistingLock.path), "Pre-existing lock in archive must not be deleted")
    }

    func testNativeUserAndLegacySubjectUseSeparateNamespacesInEitherDirection() throws {
        let native = try token("native", issuedAt: Int(Date().timeIntervalSince1970))
        let legacy = try jwt(["sub": "auth0-legacy"])
        for (access, id) in [(native, legacy), (legacy, native)] {
            let selected = CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]])
            XCTAssertEqual(selected.nativeKey, identity.nativeKey)
            let pair = CodexAccountIdentity.tokenPairIdentities(access, id)
            XCTAssertFalse(pair.access.conflicts(with: pair.id))
        }
        // External candidate identities still use subject fallback and strict conflict checks.
        XCTAssertEqual(CodexAccountIdentity.tokenIdentity(legacy).userId, "auth0-legacy")
        XCTAssertTrue(CodexAccountIdentity.tokenIdentity(native).conflicts(with: CodexAccountIdentity.tokenIdentity(legacy)))
    }

    func testExplicitNativeUserAndAccountMismatchesStillRejectTokenPair() throws {
        let native = try token("native", issuedAt: Int(Date().timeIntervalSince1970))
        let otherUser = try token("other-user", issuedAt: Int(Date().timeIntervalSince1970), user: "member-b")
        let otherAccount = try jwt(["sub": "auth0-legacy", "https://api.openai.com/auth": ["chatgpt_account_id": "different-workspace"]])
        for other in [otherUser, otherAccount] {
            for (access, id) in [(native, other), (other, native)] {
                let selected = CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]])
                XCTAssertNil(selected.nativeKey)
                let pair = CodexAccountIdentity.tokenPairIdentities(access, id)
                XCTAssertTrue(pair.access.conflicts(with: pair.id))
            }
        }
    }

    func testSameNativeIdentityIgnoresChangedEmailButUnknownUserKeepsEmailGuard() throws {
        let auth = ["chatgpt_account_id": "integration-workspace", "chatgpt_user_id": "member-a"]
        let access = try jwt(["email": "old@example.invalid", "https://api.openai.com/auth": auth])
        let id = try jwt(["email": "new@example.invalid", "https://api.openai.com/auth": auth])
        XCTAssertEqual(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]]).nativeKey, identity.nativeKey)
        XCTAssertTrue(CodexAccountIdentity.tokenIdentity(access).matches(CodexAccountIdentity.tokenIdentity(id)))
        let legacy = try jwt(["sub": "legacy", "email": "new@example.invalid"])
        let pair = CodexAccountIdentity.tokenPairIdentities(access, legacy)
        XCTAssertTrue(pair.access.conflicts(with: pair.id), "Without two native IDs, different emails must still fail closed")
        XCTAssertNil(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": legacy]]).nativeKey)
    }

    func testPureSubjectFallbackMismatchStillRejectsAndMatchingSubjectIsLastResort() throws {
        let access = try jwt(["sub": "legacy-a", "email": "same@example.invalid"])
        let id = try jwt(["sub": "legacy-b", "email": "same@example.invalid"])
        let pair = CodexAccountIdentity.tokenPairIdentities(access, id)
        XCTAssertTrue(pair.access.conflicts(with: pair.id))
        XCTAssertNil(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": id]]).userId)
        XCTAssertEqual(CodexAccountIdentity(authJSON: ["tokens": ["access_token": access, "id_token": access]]).userId, "legacy-a")
        let own = try write("fallback-subjects.json", access: access)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        json["id_token"] = id
        try JSONSerialization.data(withJSONObject: json).write(to: own)
        XCTAssertTrue(try CodexProvider(homeDirectory: directory.path).loadCredentials(from: own.path).hasInternalIdentityConflict)
    }

    func testResetAndAutomaticUsageAcceptNativeAccessWithLegacyIDSubject() async throws {
        let own = try write("own.json", access: token("native", issuedAt: Int(Date().timeIntervalSince1970)))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
        json["id_token"] = try jwt(["sub": "auth0-legacy"])
        try JSONSerialization.data(withJSONObject: json).write(to: own)
        let provider = CodexProvider(homeDirectory: directory.path)
        let creds = try provider.loadCredentials(from: own.path)
        XCTAssertFalse(creds.hasInternalIdentityConflict)
        XCTAssertEqual(creds.jwtUserId, "member-a")
        StubURLProtocol.respond(endpoint, body: list)
        _ = try await provider.fetchResetCredits(with: credential(own), identity: identity)
        let authFolder = directory.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: authFolder, withIntermediateDirectories: true)
        try Data(contentsOf: own).write(to: authFolder.appendingPathComponent("auth.json"))
        StubURLProtocol.respond("https://chatgpt.com/backend-api/wham/usage", body: #"{"plan_type":"plus"}"#)
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.extra["userId"]?.value as? String, "member-a")
        XCTAssertFalse(StubURLProtocol.requestedURLs.contains(oauth))
    }

    func testOAuthPairNamespaceFixRetainsCrossAccountAndNativeUserGuards() async throws {
        let now = Int(Date().timeIntervalSince1970)
        let provider = CodexProvider(homeDirectory: directory.path)
        let valid = try token("new", issuedAt: now)
        let legacy = try jwt(["sub": "auth0-legacy"])
        let otherAccount = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "other-workspace", "chatgpt_user_id": "member-a"]])
        let otherUser = try token("other", issuedAt: now, user: "member-b")
        for (index, responseTokens) in [(valid, legacy), (otherAccount, legacy), (otherUser, legacy),
                                         (valid, otherUser), (valid, otherAccount)].enumerated() {
            let own = try write("refresh-\(index).json", access: token("old-\(index)", issuedAt: now - 100), refresh: "old-refresh")
            var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: own)) as? [String: Any])
            json["last_refresh"] = "2020-01-01T00:00:00Z"
            json["id_token"] = legacy
            try JSONSerialization.data(withJSONObject: json).write(to: own)
            let before = try Data(contentsOf: own)
            let response = try JSONSerialization.data(withJSONObject: ["access_token": responseTokens.0, "id_token": responseTokens.1, "refresh_token": "new-refresh"])
            StubURLProtocol.respond(oauth, body: String(decoding: response, as: UTF8.self))
            let creds = try provider.loadCredentials(from: own.path)
            do {
                let refreshed = try await provider.performSerializedRefresh(creds, fallbackRefreshToken: "old-refresh", persistTo: [own.path])
                XCTAssertEqual(index, 0, "Cross-account/member refresh must not succeed")
                XCTAssertEqual(refreshed.jwtUserId, "member-a")
                XCTAssertEqual(try provider.loadCredentials(from: own.path).accessToken, valid)
            } catch {
                XCTAssertNotEqual(index, 0, "Native access plus legacy ID subject must refresh successfully")
                XCTAssertEqual((error as? ProviderError)?.code, "account_mismatch")
                XCTAssertEqual(try Data(contentsOf: own), before)
            }
        }
    }
}
