import XCTest
import CryptoKit
@testable import QuotaBackend

final class TokenSaverReleaseTests: XCTestCase {
    private let commit = String(repeating: "a", count: 40)
    private let markdown = Data("---\nname: ponytail\n---\nUse minimal code.\n".utf8)

    private actor Fixture {
        struct Reply: Sendable { let status: Int; let body: Data; var redirect = false }
        var replies: [Reply]
        var requests: [URLRequest] = []
        init(_ replies: [Reply]) { self.replies = replies }
        func respond(_ request: URLRequest, limit: Int) throws -> (Data, HTTPURLResponse) {
            requests.append(request)
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            let reply = replies.removeFirst()
            return (reply.body, HTTPURLResponse(url: reply.redirect ? URL(string: "https://evil.example/payload")! : request.url!,
                statusCode: reply.status, httpVersion: nil, headerFields: ["X-RateLimit-Reset": "12345"])!)
        }
        func captured() -> [URLRequest] { requests }
    }
    private func reply(_ object: Any, status: Int = 200) throws -> Fixture.Reply {
        .init(status: status, body: try JSONSerialization.data(withJSONObject: object))
    }
    private func client(_ fixture: Fixture) -> TokenSaverReleaseClient {
        .init { request, limit in try await fixture.respond(request, limit: limit) }
    }
    private func release(_ tool: TokenSaverReleaseTool = .ponytail) -> TokenSaverRelease {
        .init(tool: tool, version: "v1.2.3", commit: commit, isRelease: true)
    }
    private func temporaryStore() throws -> TokenSaverReleaseStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathComponent("skills")
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return .init(root: root)
    }
    private func content(sha: String? = nil, type: String = "file", path: String = "skills/ponytail/SKILL.md") -> [String: Any] {
        var blob = Data("blob \(markdown.count)\0".utf8); blob.append(markdown)
        let digest = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        return ["type": type, "path": path, "encoding": "base64", "size": markdown.count,
                "sha": sha ?? digest, "content": markdown.base64EncodedString()]
    }

    func testRepositoriesAndInstallCapabilities() {
        XCTAssertEqual(TokenSaverReleaseTool.allCases.map(\.repository),
            ["rtk-ai/rtk", "JuliusBrussee/caveman", "DietrichGebert/ponytail"])
        XCTAssertNil(TokenSaverReleaseTool.rtk.skillPath)
        XCTAssertEqual(TokenSaverReleaseTool.caveman.skillPath, "skills/caveman/SKILL.md")
    }

    func testStableReleaseResolvesImmutableCommitForEveryTool() async throws {
        for tool in TokenSaverReleaseTool.allCases {
            let fixture = Fixture(try [reply(["tag_name": "v9.8.7", "draft": false, "prerelease": false]), reply(["sha": commit])])
            let result = try await client(fixture).latest(for: tool)
            XCTAssertEqual(result.version, "v9.8.7")
            XCTAssertEqual(result.commit, commit)
            XCTAssertTrue(result.isRelease)
            let requests = await fixture.captured()
            XCTAssertEqual(requests[0].url?.path, "/repos/\(tool.repository)/releases/latest")
            XCTAssertEqual(requests[0].value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testMissingReleaseUsesClearlyLabelledCommit() async throws {
        let fixture = Fixture(try [reply(["message": "Not Found"], status: 404), reply([["sha": commit]])])
        let result = try await client(fixture).latest(for: .caveman)
        XCTAssertFalse(result.isRelease)
        XCTAssertEqual(result.version, "commit aaaaaaaaaaaa")
        let requests = await fixture.captured()
        XCTAssertEqual(requests.last?.url?.query, "per_page=1")
    }

    func testTagIsOneEncodedPathComponent() async throws {
        let fixture = Fixture(try [reply(["tag_name": "skill/v2?x=y", "draft": false, "prerelease": false]), reply(["sha": commit])])
        _ = try await client(fixture).latest(for: .ponytail)
        let requests = await fixture.captured()
        XCTAssertTrue(requests[1].url!.absoluteString.contains("skill%2Fv2%3Fx%3Dy"))
        XCTAssertNil(requests[1].url?.query)
    }

    func testRejectsPrereleaseDraftAndInvalidCommit() async throws {
        for flags in [(true, false), (false, true)] {
            let fixture = Fixture(try [reply(["tag_name": "v1", "draft": flags.0, "prerelease": flags.1])])
            do { _ = try await client(fixture).latest(for: .rtk); XCTFail("accepted unstable release") }
            catch TokenSaverReleaseError.invalidMetadata { }
        }
        let fixture = Fixture(try [reply(["tag_name": "v1", "draft": false, "prerelease": false]), reply(["sha": "main"])])
        do { _ = try await client(fixture).latest(for: .rtk); XCTFail("accepted mutable ref") }
        catch TokenSaverReleaseError.invalidMetadata { }
    }

    func testRateLimitAndHTTPFailuresDoNotFallbackToCommits() async throws {
        for status in [403, 429, 500] {
            let fixture = Fixture(try [reply(["message": "error"], status: status)])
            do { _ = try await client(fixture).latest(for: .rtk); XCTFail("accepted error") }
            catch {
                if status == 500 { XCTAssertTrue(error.localizedDescription.contains("500")) }
                else {
                    if case TokenSaverReleaseError.rateLimited(let reset) = error {
                        XCTAssertEqual(reset, "12345")
                        XCTAssertTrue(error.localizedDescription.contains("GitHub API"))
                        XCTAssertFalse(error.localizedDescription.contains("Unix"))
                    } else {
                        XCTFail("expected rate limit")
                    }
                }
            }
            let requests = await fixture.captured()
            XCTAssertEqual(requests.count, 1)
        }
    }

    func testOfflineAndMalformedResponsesFail() async throws {
        let fixture = Fixture([])
        do { _ = try await client(fixture).latest(for: .rtk); XCTFail("accepted offline") } catch { }
        let malformed = Fixture([.init(status: 200, body: Data("not json".utf8))])
        do { _ = try await client(malformed).latest(for: .rtk); XCTFail("accepted malformed") } catch { }
    }

    func testRejectsOversizedOrRedirectedResponse() async throws {
        for response in [Fixture.Reply(status: 200, body: Data(repeating: 0, count: 512 * 1024 + 1)),
                         Fixture.Reply(status: 200, body: Data(), redirect: true)] {
            do { _ = try await client(Fixture([response])).latest(for: .rtk); XCTFail("accepted unsafe response") } catch { }
        }
    }

    func testSkillUsesPinnedCommitAndVerifiesGitBlob() async throws {
        let fixture = Fixture(try [reply(content())])
        let bytes = try await client(fixture).skill(for: release())
        XCTAssertEqual(bytes, markdown)
        let requests = await fixture.captured()
        XCTAssertEqual(requests[0].url?.path, "/repos/DietrichGebert/ponytail/contents/skills/ponytail/SKILL.md")
        XCTAssertEqual(requests[0].url?.query, "ref=\(commit)")
    }

    func testRejectsWrongDigestSymlinkAndWrongSkillPath() async throws {
        for object in [content(sha: String(repeating: "0", count: 40)), content(type: "symlink"), content(path: "install.sh")] {
            do { _ = try await client(Fixture(try [reply(object)])).skill(for: release()); XCTFail("accepted invalid content") } catch { }
        }
    }

    func testBinaryDownloadAndInstallAreForbidden() async throws {
        let fixture = Fixture([])
        let store = try temporaryStore()
        for tool in [TokenSaverReleaseTool.rtk] {
            do { _ = try await client(fixture).skill(for: release(tool)); XCTFail("downloaded binary") }
            catch TokenSaverReleaseError.manualInstallation { }
            XCTAssertThrowsError(try store.stage(release(tool), markdown: markdown))
        }
        let requests = await fixture.captured()
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    }

    func testStagedIsAbsentUntilAtomicManagedWriteAndSurvivesRelaunch() throws {
        let store = try temporaryStore()
        XCTAssertNil(try store.staged(.ponytail))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
        let staged = try store.stage(release(), markdown: markdown)
        XCTAssertEqual(staged.version, "v1.2.3")
        XCTAssertEqual(staged.commit, commit)
        XCTAssertEqual(try TokenSaverReleaseStore(root: store.root).staged(.ponytail), staged)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.root.path), ["ponytail.json"])
        XCTAssertNil(try store.staged(.caveman))
        let next = TokenSaverRelease(tool: .ponytail, version: "v2", commit: String(repeating: "b", count: 40), isRelease: true)
        try store.stage(next, markdown: markdown)
        XCTAssertEqual(try store.staged(.ponytail)?.version, "v2")
    }

    func testCorruptReceiptDoesNotClaimStagedVersion() throws {
        let store = try temporaryStore()
        try store.stage(release(), markdown: markdown)
        let url = store.root.appendingPathComponent("ponytail.json")
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        object["sha256"] = "bad"
        try JSONSerialization.data(withJSONObject: object).write(to: url)
        XCTAssertThrowsError(try store.staged(.ponytail))
    }

    func testSymlinkRootAncestorAndReceiptCannotEscapeManagedStorage() throws {
        let store = try temporaryStore()
        let parent = store.root.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let outside = parent.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: store.root, withDestinationURL: outside)
        XCTAssertThrowsError(try store.stage(release(), markdown: markdown))
        XCTAssertThrowsError(try store.staged(.ponytail))
        XCTAssertThrowsError(try TokenSaverReleaseStore(root: store.root.appendingPathComponent("nested")).stage(release(), markdown: markdown))
        try FileManager.default.removeItem(at: store.root)
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        let externalFile = outside.appendingPathComponent("user-skill.md")
        let original = Data("user-owned".utf8)
        try original.write(to: externalFile)
        try FileManager.default.createSymbolicLink(at: store.root.appendingPathComponent("ponytail.json"), withDestinationURL: externalFile)
        XCTAssertThrowsError(try store.stage(release(), markdown: markdown))
        XCTAssertEqual(try Data(contentsOf: externalFile), original)
    }
    private actor BrewFixture {
        var replies: [TokenSaverReleaseRTK.Output]
        var arguments: [[String]] = []
        init(_ replies: [TokenSaverReleaseRTK.Output]) { self.replies = replies }
        func run(_ url: URL, _ args: [String]) throws -> TokenSaverReleaseRTK.Output {
            arguments.append(args)
            guard !replies.isEmpty else { throw URLError(.badServerResponse) }
            return replies.removeFirst()
        }
        func calls() -> [[String]] { arguments }
    }

    func testRTKInstalledVersionUsesOnlyInjectedReadonlyBrew() async throws {
        let fixture = BrewFixture([.init(status: 0, text: "rtk 1.0.0 1.1.0\n")])
        let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { try await fixture.run($0, $1) }
        let version = try await rtk.installedVersion()
        XCTAssertEqual(version, "1.0.0, 1.1.0")
        let calls = await fixture.calls()
        XCTAssertEqual(calls, [["list", "--versions", "rtk"]])
    }

    func testRTKUpgradeRequiresInstalledAndRechecksActualVersion() async throws {
        let fixture = BrewFixture([.init(status: 0, text: "rtk 1.0.0"), .init(status: 0, text: "upgraded"), .init(status: 0, text: "rtk 1.1.0")])
        let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/usr/local/bin/brew")) { try await fixture.run($0, $1) }
        let version = try await rtk.upgrade()
        XCTAssertEqual(version, "1.1.0")
        let calls = await fixture.calls()
        XCTAssertEqual(calls, [["list", "--versions", "rtk"], ["upgrade", "rtk"], ["list", "--versions", "rtk"]])
    }

    func testRTKMissingInstallationNeverRunsUpgradeOrInstall() async throws {
        for status: Int32 in [0, 1] {
            let fixture = BrewFixture([.init(status: status, text: "")])
            let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { try await fixture.run($0, $1) }
            do { _ = try await rtk.upgrade(); XCTFail("upgraded missing RTK") } catch { }
            let calls = await fixture.calls()
            XCTAssertEqual(calls, [["list", "--versions", "rtk"]])
        }
    }

    func testRTKRejectsUnknownBrewAndMalformedVersion() async throws {
        let fixture = BrewFixture([])
        let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/tmp/brew")) { try await fixture.run($0, $1) }
        XCTAssertNil(rtk.brewURL)
        do { _ = try await rtk.installedVersion(); XCTFail("ran untrusted brew path") } catch { }
        let calls = await fixture.calls()
        XCTAssertTrue(calls.isEmpty)
        let invalid = BrewFixture([.init(status: 0, text: "other 1.2.3")])
        let other = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { try await invalid.run($0, $1) }
        do { _ = try await other.installedVersion(); XCTFail("accepted invalid installed version") } catch { }
    }

    func testRTKFailureDoesNotClaimUpgradeSuccess() async throws {
        let fixture = BrewFixture([.init(status: 0, text: "rtk 1.0.0"), .init(status: 2, text: "failure")])
        let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { try await fixture.run($0, $1) }
        do { _ = try await rtk.upgrade(); XCTFail("claimed success") }
        catch { XCTAssertTrue(error.localizedDescription.contains("failure")) }
        let calls = await fixture.calls()
        XCTAssertEqual(calls.count, 2)
    }

}
