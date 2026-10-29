// Standalone CLT fallback: runs the unchanged XCTest method bodies with local assertions.
// Execute scripts/run_token_saver_release_regression.sh. No network or real Homebrew invocation.
import Foundation
import Combine
import CryptoKit

func XCTFail(_ message: String = "assertion failed", file: StaticString = #file, line: UInt = #line) -> Never { fatalError(message, file: file, line: line) }
func XCTAssertEqual<T: Equatable>(_ a: @autoclosure () throws -> T, _ b: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) {
 do { let lhs = try a(); let rhs = try b(); if lhs != rhs { XCTFail("\(lhs) != \(rhs)", file: file, line: line) } } catch { XCTFail("unexpected error: \(error)", file: file, line: line) }
}
func XCTAssertTrue(_ a: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) { do { if try !a() { XCTFail(file: file, line: line) } } catch { XCTFail("\(error)", file: file, line: line) } }
func XCTAssertFalse(_ a: @autoclosure () throws -> Bool, file: StaticString = #file, line: UInt = #line) { do { if try a() { XCTFail(file: file, line: line) } } catch { XCTFail("\(error)", file: file, line: line) } }
func XCTAssertNil<T>(_ a: @autoclosure () throws -> T?, file: StaticString = #file, line: UInt = #line) { do { if try a() != nil { XCTFail(file: file, line: line) } } catch { XCTFail("\(error)", file: file, line: line) } }
func XCTAssertThrowsError<T>(_ a: @autoclosure () throws -> T, file: StaticString = #file, line: UInt = #line) { do { _ = try a() } catch { return }; XCTFail("expected throw", file: file, line: line) }
class XCTestCase {
 var teardowns: [() throws -> Void] = []
 func addTeardownBlock(_ block: @escaping () throws -> Void) { teardowns.append(block) }
 func tearDown() throws { for block in teardowns.reversed() { try block() } }
}

@main struct TokenSaverReleaseRegression {
static func main() async throws {
do { let test = TokenSaverReleaseTests(); test.testRepositoriesAndInstallCapabilities(); try test.tearDown(); print("PASS testRepositoriesAndInstallCapabilities") }
do { let test = TokenSaverReleaseTests(); try await test.testStableReleaseResolvesImmutableCommitForEveryTool(); try test.tearDown(); print("PASS testStableReleaseResolvesImmutableCommitForEveryTool") }
do { let test = TokenSaverReleaseTests(); try await test.testMissingReleaseUsesClearlyLabelledCommit(); try test.tearDown(); print("PASS testMissingReleaseUsesClearlyLabelledCommit") }
do { let test = TokenSaverReleaseTests(); try await test.testTagIsOneEncodedPathComponent(); try test.tearDown(); print("PASS testTagIsOneEncodedPathComponent") }
do { let test = TokenSaverReleaseTests(); try await test.testRejectsPrereleaseDraftAndInvalidCommit(); try test.tearDown(); print("PASS testRejectsPrereleaseDraftAndInvalidCommit") }
do { let test = TokenSaverReleaseTests(); try await test.testRateLimitAndHTTPFailuresDoNotFallbackToCommits(); try test.tearDown(); print("PASS testRateLimitAndHTTPFailuresDoNotFallbackToCommits") }
do { let test = TokenSaverReleaseTests(); try await test.testOfflineAndMalformedResponsesFail(); try test.tearDown(); print("PASS testOfflineAndMalformedResponsesFail") }
do { let test = TokenSaverReleaseTests(); try await test.testRejectsOversizedOrRedirectedResponse(); try test.tearDown(); print("PASS testRejectsOversizedOrRedirectedResponse") }
do { let test = TokenSaverReleaseTests(); try await test.testSkillUsesPinnedCommitAndVerifiesGitBlob(); try test.tearDown(); print("PASS testSkillUsesPinnedCommitAndVerifiesGitBlob") }
do { let test = TokenSaverReleaseTests(); try await test.testRejectsWrongDigestSymlinkAndWrongSkillPath(); try test.tearDown(); print("PASS testRejectsWrongDigestSymlinkAndWrongSkillPath") }
do { let test = TokenSaverReleaseTests(); try await test.testBinaryDownloadAndInstallAreForbidden(); try test.tearDown(); print("PASS testBinaryDownloadAndInstallAreForbidden") }
do { let test = TokenSaverReleaseTests(); try test.testStagedIsAbsentUntilAtomicManagedWriteAndSurvivesRelaunch(); try test.tearDown(); print("PASS testStagedIsAbsentUntilAtomicManagedWriteAndSurvivesRelaunch") }
do { let test = TokenSaverReleaseTests(); try test.testCorruptReceiptDoesNotClaimStagedVersion(); try test.tearDown(); print("PASS testCorruptReceiptDoesNotClaimStagedVersion") }
do { let test = TokenSaverReleaseTests(); try test.testSymlinkRootAncestorAndReceiptCannotEscapeManagedStorage(); try test.tearDown(); print("PASS testSymlinkRootAncestorAndReceiptCannotEscapeManagedStorage") }
do { let test = TokenSaverReleaseTests(); try await test.testRTKInstalledVersionUsesOnlyInjectedReadonlyBrew(); try test.tearDown(); print("PASS testRTKInstalledVersionUsesOnlyInjectedReadonlyBrew") }
do { let test = TokenSaverReleaseTests(); try await test.testRTKUpgradeRequiresInstalledAndRechecksActualVersion(); try test.tearDown(); print("PASS testRTKUpgradeRequiresInstalledAndRechecksActualVersion") }
do { let test = TokenSaverReleaseTests(); try await test.testRTKMissingInstallationNeverRunsUpgradeOrInstall(); try test.tearDown(); print("PASS testRTKMissingInstallationNeverRunsUpgradeOrInstall") }
do { let test = TokenSaverReleaseTests(); try await test.testRTKRejectsUnknownBrewAndMalformedVersion(); try test.tearDown(); print("PASS testRTKRejectsUnknownBrewAndMalformedVersion") }
do { let test = TokenSaverReleaseTests(); try await test.testRTKFailureDoesNotClaimUpgradeSuccess(); try test.tearDown(); print("PASS testRTKFailureDoesNotClaimUpgradeSuccess") }
print("Release offline regression: 19 passed")
try await runManagerChecks()
}
}

private actor ReleaseManagerFixture {
    var failChecks = false
    var failDownloads = false
    func setFailures(checks: Bool = false, downloads: Bool = false) { failChecks = checks; failDownloads = downloads }
    func response(_ request: URLRequest, _ limit: Int) throws -> (Data, HTTPURLResponse) {
        let path = request.url!.path
        if path.contains("/contents/") && failDownloads || !path.contains("/contents/") && failChecks { throw URLError(.notConnectedToInternet) }
        let object: [String: Any]
        if path.contains("/contents/") {
            let bytes = Data("---\nname: ponytail\n---\nMinimal code.\n".utf8)
            var blob = Data("blob \(bytes.count)\0".utf8); blob.append(bytes)
            let digest = Insecure.SHA1.hash(data: blob).map { String(format: "%02x", $0) }.joined()
            object = ["type": "file", "path": "skills/ponytail/SKILL.md", "encoding": "base64", "size": bytes.count, "sha": digest, "content": bytes.base64EncodedString()]
        } else if path.contains("/commits/") {
            object = ["sha": String(repeating: "a", count: 40)]
        } else {
            object = ["tag_name": "v1.2.3", "draft": false, "prerelease": false]
        }
        return (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor ReleaseManagerBrew {
    var version = "1.0.0"
    func run(_ url: URL, _ args: [String]) -> TokenSaverReleaseRTK.Output {
        if args == ["upgrade", "rtk"] { version = "1.2.3"; return .init(status: 0, text: "upgraded") }
        return .init(status: 0, text: "rtk \(version)")
    }
}

@MainActor
private func runManagerChecks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = ReleaseManagerFixture()
    let client = TokenSaverReleaseClient { try await fixture.response($0, $1) }
    let store = TokenSaverReleaseStore(root: root.appendingPathComponent("Rules"))
    let noBrew = TokenSaverReleaseRTK(brewURL: nil) { _, _ in fatalError("unexpected real process") }
    var applied = 0
    let manager = TokenSaverReleaseManager(client: client, store: store, rtk: noBrew, reapplyRules: { applied += 1 })
    await manager.stage(.ponytail)
    XCTAssertEqual(applied, 0)
    await manager.check(.ponytail)
    XCTAssertEqual(manager.statuses[.ponytail]?.latest?.version, "v1.2.3")
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.root.path))
    await manager.stage(.ponytail)
    XCTAssertEqual(applied, 1)
    XCTAssertEqual(manager.statuses[.ponytail]?.staged?.version, "v1.2.3")
    XCTAssertTrue(manager.statuses[.ponytail]?.notice?.contains("New coding session reload required") == true)
    print("PASS manager stage/reapply and distinct staged version")

    enum ApplyFailure: Error { case externallyEdited }
    let failing = TokenSaverReleaseManager(client: client, store: store, rtk: noBrew, reapplyRules: { throw ApplyFailure.externallyEdited })
    await failing.check(.ponytail)
    await failing.stage(.ponytail)
    XCTAssertTrue(failing.statuses[.ponytail]?.error?.contains("Downloaded/staged rules, but not applied") == true)
    XCTAssertEqual(try store.staged(.ponytail)?.version, "v1.2.3")
    print("PASS manager apply failure retains staged data and reports not applied")

    let emptyStore = TokenSaverReleaseStore(root: root.appendingPathComponent("failed-download"))
    let downloadFailure = TokenSaverReleaseManager(client: client, store: emptyStore, rtk: noBrew, reapplyRules: { applied += 1 })
    await downloadFailure.check(.ponytail)
    await fixture.setFailures(downloads: true)
    await downloadFailure.stage(.ponytail)
    XCTAssertEqual(applied, 1)
    XCTAssertNil(try emptyStore.staged(.ponytail))
    XCTAssertTrue(downloadFailure.statuses[.ponytail]?.error != nil)
    print("PASS manager download failure never applies or claims staged rules")

    await fixture.setFailures(checks: true)
    await manager.check(.ponytail)
    XCTAssertNil(manager.statuses[.ponytail]?.latest)
    XCTAssertNil(manager.statuses[.ponytail]?.checkedAt)
    await manager.stage(.ponytail)
    XCTAssertEqual(applied, 1)
    print("PASS manager failed check invalidates stale update eligibility")

    await fixture.setFailures()
    let brew = ReleaseManagerBrew()
    let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath: "/opt/homebrew/bin/brew")) { await brew.run($0, $1) }
    let rtkManager = TokenSaverReleaseManager(client: client, store: store, rtk: rtk, reapplyRules: { XCTFail("RTK must not reapply rules") })
    await rtkManager.check(.rtk)
    XCTAssertEqual(rtkManager.statuses[.rtk]?.installedBinaryVersion, "1.0.0")
    XCTAssertEqual(rtkManager.statuses[.rtk]?.latest?.version, "v1.2.3")
    await rtkManager.updateRTK()
    XCTAssertEqual(rtkManager.statuses[.rtk]?.installedBinaryVersion, "1.2.3")
    XCTAssertNil(rtkManager.statuses[.rtk]?.staged)
    print("PASS manager RTK actual installed version stays separate from GitHub latest")
    print("Release manager offline regression: 5 passed")
}
