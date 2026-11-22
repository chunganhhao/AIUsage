// Isolated SwiftUI fixture only; uses temporary homes and stubbed HTTP/RTK clients.
import SwiftUI
import AppKit
import PDFKit
import Combine
import QuotaBackend
import CryptoKit

var fixtureForceChinese = false
func L(_ en: String, _ zh: String, _ vi: String? = nil, key: String? = nil, file: String = #fileID) -> String {
    if fixtureForceChinese || ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_LANG"] == "zh" {
        return zh
    }
    if ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_LANG"] == "vi", let vi {
        return vi
    }
    return en
}
struct QuotaWindow { let label: String; let remainingPercent: Double?; let resetAt: String? }
struct ProviderData { let accountId: String?; let sourceFilePath: String?; let baseProviderId: String; let accountLabel: String?; let fetchedAt: String?; let windows: [QuotaWindow] }
func aiusageDefaultCLIPath() -> String { "/usr/bin:/bin" }
func aiusageCodexExecutable() -> String? { nil }
func aiusageResolvedExecutable(named: String) -> String? { nil }
enum ClaudeSubscriptionManager {
    static func authStatus(directory: String, executable: String) async throws -> ClaudeAuthStatus { .init(loggedIn: false) }
}
private func fixtureHome() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_HOME"] ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("home").path)
}
private func fixtureRTK() -> TokenSaverReleaseRTK {
    TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath:"/opt/homebrew/bin/brew")) { _, args in
        if args == ["list", "--versions", "rtk"], ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_RTK_MISSING"] == "1" {
            return .init(status: 1, text: "")
        }
        return .init(status:0,text:args == ["list","--versions","rtk"] ? "rtk 1.0.0" : "fixture upgrade only")
    }
}
@MainActor private func fixtureReleaseManager() -> TokenSaverReleaseManager {
    let home = fixtureHome()
    let client = TokenSaverReleaseClient { request, _ in
        let path = request.url!.path
        if ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_RATE_LIMIT"] == "1" {
            return (Data(), HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil,
                    headerFields: ["X-RateLimit-Reset": String(Int(Date().addingTimeInterval(120).timeIntervalSince1970))])!)
        }
        let body: [String: Any]
        if path.contains("/contents/") {
            let tool = path.contains("/ponytail/") ? "ponytail" : "caveman"
            let data = Data("---\nname: \(tool)\ndescription: Isolated UI fixture.\n---\nCoding-only fixture policy.\n".utf8)
            var blob = Data("blob \(data.count)\0".utf8); blob.append(data)
            body = ["type":"file", "path":"skills/\(tool)/SKILL.md", "encoding":"base64", "size":data.count,
                    "content":data.base64EncodedString(), "sha":Insecure.SHA1.hash(data:blob).map { String(format:"%02x",$0) }.joined()]
        } else if path.contains("/commits/") { body = ["sha":String(repeating:"a",count:40)] }
        else { body = ["tag_name":"v1.2.3", "draft":false, "prerelease":false] }
        return (try JSONSerialization.data(withJSONObject:body), HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!)
    }
    let rtk = fixtureRTK()
    return TokenSaverReleaseManager(client:client,
        store:TokenSaverReleaseStore(root:home.appendingPathComponent("Library/Application Support/AIUsage/Rules")),
        rtk:rtk, reapplyRules:{ try TokenSaverSettingsStore.save(TokenSaverSettingsStore.load(home:home),home:home) })
}
@MainActor
private func inspectOffscreen<V: View>(_ root: V, width: CGFloat, maxWidth: CGFloat? = nil) -> (size: NSSize, strings: [String]) {
    let hosting = NSHostingView(rootView: root)
    let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = hosting
    hosting.setFrameSize(NSSize(width: width, height: 1))
    hosting.layoutSubtreeIfNeeded()
    let fitting = hosting.fittingSize
    let size = NSSize(width: max(width, fitting.width), height: max(ceil(fitting.height), 40))
    window.setContentSize(size)
    hosting.frame = NSRect(origin: .zero, size: size)
    hosting.layoutSubtreeIfNeeded()
    window.displayIfNeeded()
    let rootScreenFrame = window.convertToScreen(hosting.convert(hosting.bounds, to: nil))

    var result: [String] = []
    var visited = Set<ObjectIdentifier>()

    func appendString(_ s: String?, screenFrame: NSRect? = nil) {
        guard let trimmed = s?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return }
        result.append(trimmed)
        if let maxWidth, let screenFrame, screenFrame.width > 0 {
            let minX = screenFrame.minX - rootScreenFrame.minX
            let maxX = screenFrame.maxX - rootScreenFrame.minX
            precondition(minX >= -2.0 && maxX <= maxWidth + 2.0,
                         "Element '\(trimmed)' exceeds \(maxWidth)pt bounds: minX=\(minX), maxX=\(maxX)")
        }
    }

    func visitAX(_ anyObj: AnyObject) {
        let id = ObjectIdentifier(anyObj)
        guard visited.insert(id).inserted else { return }
        let frame = (anyObj as? NSAccessibilityProtocol)?.accessibilityFrame()
            ?? (anyObj as? NSAccessibilityElementProtocol)?.accessibilityFrame()
        if let ax = anyObj as? NSAccessibilityProtocol {
            appendString(ax.accessibilityLabel(), screenFrame: frame)
            appendString(ax.accessibilityTitle(), screenFrame: frame)
            appendString(ax.accessibilityValue() as? String, screenFrame: frame)
            appendString(ax.accessibilityHelp(), screenFrame: frame)
            for child in (ax.accessibilityChildren() ?? []) {
                visitAX(child as AnyObject)
            }
        }
        if let view = anyObj as? NSView {
            if let tf = view as? NSTextField { appendString(tf.stringValue) }
            if let btn = view as? NSButton { appendString(btn.title) }
            for sub in view.subviews { visitAX(sub) }
        }
    }

    _ = NSApplication.shared
    visitAX(hosting)
    let pdfData = hosting.dataWithPDF(inside: hosting.bounds)
    if let pdfDoc = PDFDocument(data: pdfData), let pdfText = pdfDoc.string {
        appendString(pdfText)
        if let maxWidth, let page = pdfDoc.page(at: 0) {
            let pageBounds = page.bounds(for: .mediaBox)
            precondition(pageBounds.width <= maxWidth + 1.0,
                         "Rendered PDF page width (\(pageBounds.width)) exceeds \(maxWidth)pt")
        }
    }
    window.contentView = nil
    return (fitting, result)
}

@MainActor
private func runHeadlessUIVerification() async throws {
    let fm = FileManager.default
    let tempRoot = fm.temporaryDirectory.appendingPathComponent("aiusage-ui-verify-" + UUID().uuidString)
    let homeA = tempRoot.appendingPathComponent("home-a")
    let homeB = tempRoot.appendingPathComponent("home-b")
    try fm.createDirectory(at: homeA, withIntermediateDirectories: true)
    try fm.createDirectory(at: homeB, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempRoot) }

    // 1. Verify REAL extracted MenuBarView.openTokenSaverSettings -> AppState.requestedSettingsCategory -> SettingsView.consumeRequestedSettingsCategory
    let appState = ProductionAppStateRoutingStub()
    let menuRouter = ProductionMenuBarRouting(appState: appState)
    let settingsRouter = ProductionSettingsRouting(appState: appState)
    precondition(settingsRouter.selectedCategory == .general)
    menuRouter.openTokenSaverSettings()
    precondition(menuRouter.revealedSection == .settings, "Expected MenuBarView.openTokenSaverSettings to reveal .settings")
    precondition(appState.requestedSettingsCategory == .tokenSaver, "Expected pending destination .tokenSaver")
    settingsRouter.consumeRequestedSettingsCategory()
    precondition(settingsRouter.selectedCategory == .tokenSaver, "Expected consumeRequestedSettingsCategory() to select .tokenSaver")
    precondition(appState.requestedSettingsCategory == nil, "Expected requestedSettingsCategory to be cleared after consumption")

    // 2. Verify unconstrained & 420pt offscreen NSHostingView layout + rendered text/accessibility state in EN & ZH across all Caveman modes
    for useZH in [false, true] {
        fixtureForceChinese = useZH
        for mode in TokenSaverSettings.CavemanMode.allCases {
            _ = try TokenSaverSettingsStore.update(home: homeA) {
                $0.rtkEnabled = true
                $0.cavemanEnabled = true
                $0.cavemanMode = mode
                $0.ponytailEnabled = true
            }
            let naturalHost = NSHostingView(rootView: TokenSaverMenuBarSection(home: homeA, rtk: fixtureRTK(), onOpenSettings: { menuRouter.openTokenSaverSettings() }))
            naturalHost.layoutSubtreeIfNeeded()
            let naturalSize = naturalHost.fittingSize
            precondition(naturalSize.width <= 420.0 && naturalSize.height >= 40 && naturalSize.height <= 160,
                         "Unconstrained MenuBar section width exceeds 420pt (\(naturalSize)) for zh=\(useZH) mode=\(mode.rawValue)")

            let (_, strings) = inspectOffscreen(
                TokenSaverMenuBarSection(home: homeA, rtk: fixtureRTK(), onOpenSettings: { menuRouter.openTokenSaverSettings() }).frame(width: 420),
                width: 420,
                maxWidth: 420
            )
            let joined = strings.joined(separator: " | ")
            let expectedTitle = useZH ? "Token 节省" : "Token Saver"
            let expectedBadge = useZH ? "已启用 3/3" : "Enabled 3/3"
            precondition(joined.contains(expectedTitle), "Missing title '\(expectedTitle)' in rendered MenuBar strings: \(joined)")
            precondition(joined.contains(expectedBadge), "Missing badge '\(expectedBadge)' in rendered MenuBar strings: \(joined)")
            precondition(joined.contains("RTK") && joined.contains("Caveman") && joined.contains("Ponytail"),
                         "Missing tool pills in rendered MenuBar strings: \(joined)")
        }

        let (_, updateStringList) = inspectOffscreen(
            TokenSaverUpdatesSection(manager: fixtureReleaseManager(), onOpenRuntime: {}).frame(width: 680),
            width: 680
        )
        let updateStrings = updateStringList.joined(separator: " | ")
        let expectedBuiltIn = useZH ? "内置精简规则 · 在 Token 节省页启用" : "Built-in compact rules · Enable in Token Saver"
        let forbiddenSavedRef = useZH ? "已保存参考 · 非当前生效策略" : "Saved reference · not active policy"
        let forbiddenStagedCommit = useZH ? "已暂存提交：" : "Staged commit:"
        precondition(updateStrings.contains(expectedBuiltIn), "Missing built-in policy label in Updates: \(updateStrings)")
        precondition(!updateStrings.contains(forbiddenSavedRef) && !updateStrings.contains(forbiddenStagedCommit),
                     "Unexpected legacy staged reference UI in Updates: \(updateStrings)")
    }
    fixtureForceChinese = false

    // 3. Verify named NSPasteboard isolation, repeat-click timer cancellation across first deadline, and final expiry to false
    let testPasteboard = NSPasteboard.withUniqueName()
    defer { testPasteboard.releaseGlobally() }
    let pasteController = TokenSaverSettingsController(
        home: homeA,
        rtk: fixtureRTK(),
        copyFeedbackDurationNanoseconds: 140_000_000
    ) { text in
        testPasteboard.clearContents()
        return testPasteboard.setString(text, forType: .string)
    }
    await pasteController.checkOnboarding()
    precondition(pasteController.onboarding?.rules == .current)
    precondition(pasteController.copyDiagnostic() && pasteController.copiedDiagnostic)
    precondition(testPasteboard.string(forType: .string)?.contains("Optional diagnostic") == true)
    precondition(pasteController.copyBrewInstallCommand() && pasteController.copiedBrewCommand)
    precondition(testPasteboard.string(forType: .string) == "brew install rtk")
    try? await Task.sleep(nanoseconds: 80_000_000)
    precondition(pasteController.copyDiagnostic() && pasteController.copiedDiagnostic)
    precondition(pasteController.copyBrewInstallCommand() && pasteController.copiedBrewCommand)
    try? await Task.sleep(nanoseconds: 85_000_000)
    precondition(pasteController.copiedDiagnostic && pasteController.copiedBrewCommand,
                 "Expected repeat click to cancel first timer and keep copied state true across first deadline")
    try? await Task.sleep(nanoseconds: 100_000_000)
    precondition(!pasteController.copiedDiagnostic && !pasteController.copiedBrewCommand,
                 "Expected copied state to reset to false after replacement timer expires")

    // 4. Verify offscreen rendering of TokenSaverSettingsPane (runtime controls, RTK versions, and updates)
    let (_, paneStringList) = inspectOffscreen(
        TokenSaverSettingsPane(home: homeA, rtk: fixtureRTK(), releases: fixtureReleaseManager()).frame(width: 680),
        width: 680
    )
    let paneStrings = paneStringList.joined(separator: " | ")
    precondition(paneStrings.contains("Enabled 3/3"), "Expected Enabled 3/3 badge in TokenSaverSettingsPane: \(paneStrings)")
    precondition(paneStrings.contains("RTK — Versions & rollback"), "Expected RTK versions view in TokenSaverSettingsPane: \(paneStrings)")
    precondition(paneStrings.contains("Built-in compact rules · Enable in Token Saver"), "Expected updates section in TokenSaverSettingsPane: \(paneStrings)")

    // Banner sheet and settings reuse one observable model; removing a candidate clears its observers.
    let overrideHome = homeA.appendingPathComponent("override-model")
    try FileManager.default.createDirectory(at: overrideHome, withIntermediateDirectories: true)
    let overrideFile = overrideHome.appendingPathComponent(".zshrc")
    try Data("export OPENAI_API_KEY='fixture-only'\n".utf8).write(to: overrideFile)
    let overrideModel = EnvironmentOverrideModel(home: overrideHome)
    overrideModel.scan()
    precondition(overrideModel.findings.count == 1)
    _ = inspectOffscreen(EnvironmentOverrideView(model: overrideModel).frame(width: 680), width: 680)
    overrideModel.remove(overrideModel.findings[0])
    precondition(overrideModel.findings.isEmpty, "Shared banner model kept a stale file candidate after removal")
    overrideModel.restore()
    precondition(overrideModel.findings.count == 1, "Shared model Undo did not restore its candidate")

    // Master-plan surfaces render real production views, isolated from user homes/Keychain.
    let toolHome = homeA.appendingPathComponent("master-tools")
    let codexConfig = toolHome.appendingPathComponent(".codex/config.toml")
    try FileManager.default.createDirectory(at: codexConfig.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"[mcp_servers.fixture]"#.utf8).write(to: codexConfig)
    let (_, tools) = inspectOffscreen(AgentToolsSettingsView(home: toolHome).frame(width: 680), width: 680)
    let toolText = tools.joined(separator: " | ")
    precondition(toolText.contains("Scheduled 5h-Window Warmup"), "Missing warmup surface")
    precondition(toolText.contains("Environment Overrides"), "Missing environment surface")
    precondition(toolText.contains("Config Sets"), "Missing config sets surface")
    let (_, rtkVersions) = inspectOffscreen(RTKVersionsView(store: RTKVersionStore(home: toolHome, cellarRoots: [])).frame(width: 680), width: 680)
    precondition(rtkVersions.joined(separator: " | ").contains("RTK — Versions & rollback"), "Missing RTK version surface")
    try prepareLinkedMCPFixture(toolHome)
    let (_, linkedLabels) = inspectOffscreen(AgentConfigToolsView(home: toolHome, platform: .antigravity).frame(width: 680), width: 680)
    let linkedText = linkedLabels.joined(separator: " | ")
    precondition(linkedText.contains("Read-only") && linkedText.contains("fixture-linked"), "Linked MCP config should remain visible as read-only")
    precondition(!linkedText.contains("Token Saver will not replace"), "Read-only MCP is not a load failure")

    print("PASS TokenSaverUIFixture headless verification (unconstrained <=420pt EN/ZH layout, real SettingsView .tokenSaver routing, timer cancellation/expiry on isolated NSPasteboard, TokenSaverSettingsPane, warmup/env/config-sets & linked MCP read-only)")
}

private func prepareLinkedMCPFixture(_ home: URL) throws {
    let fm = FileManager.default
    let config = home.appendingPathComponent(".gemini/antigravity/mcp_config.json")
    let source = home.appendingPathComponent(".gemini/config/mcp_config.json")
    try fm.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
    if !fm.fileExists(atPath: config.path) {
        try Data(#"{"mcpServers":{"fixture-linked":{"command":"/usr/bin/true"}}}"#.utf8).write(to: source)
        try fm.createSymbolicLink(at: config, withDestinationURL: source)
    }
}

struct TokenSaverUIFixtureApp: App {
    @StateObject private var releases = fixtureReleaseManager()
    @State private var tab = 0
    var body: some Scene {
        WindowGroup("AIUsage Token Saver — isolated fixture") {
            TabView(selection: $tab) {
                ScrollView {
                    TokenSaverSettingsPane(home: fixtureHome(), rtk: fixtureRTK(), releases: releases).padding(20)
                }
                .tabItem { Text("Token Saver") }.tag(0)
                ScrollView { AgentConfigToolsView(home: fixtureHome(), platform: .antigravity).padding(20) }
                    .tabItem { Text("Linked MCP (read-only)") }.tag(1)
            }
            .padding(20).frame(minWidth: 760, minHeight: 920)
            .onAppear { NSApp.activate(ignoringOtherApps: true) }
        }
    }
}

@main
struct TokenSaverUIFixtureEntry {
    static func main() async throws {
        if CommandLine.arguments.contains("--verify-ui") {
            try await runHeadlessUIVerification()
            return
        }
        try prepareLinkedMCPFixture(fixtureHome())
        TokenSaverUIFixtureApp.main()
    }
}
