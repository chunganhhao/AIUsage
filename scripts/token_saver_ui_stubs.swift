// Isolated SwiftUI fixture only; never launches CPA or uses real account stores.
import SwiftUI
import Combine
import QuotaBackend
import CryptoKit

func L(_ en: String, _ zh: String) -> String { en }
struct CLIProxyGatewaySettings: Equatable {
    var autoStart = false, allowLANAccess = false, accountModelProbeEnabled = false, enablePlugins = false
    var port = 14420, accountModelProbeIntervalSeconds = 60, maxRetryCredentials = 0, requestRetry = 3, maxRetryInterval = 30
    var proxyURL = ""
    var routingStrategy = CLIProxyRoutingStrategy.roundRobin
    var normalized: Self { self }
    func requiresCPAProcessRestart(comparedTo: Self) -> Bool { self != comparedTo }
}
enum CLIProxyRoutingStrategy { case roundRobin, fillFirst }
struct FixtureRuntimeState { var isRunning = false; var isTransitioning = false }
@MainActor final class CLIProxyRuntimeController: ObservableObject {
    @Published var settings = CLIProxyGatewaySettings()
    var state = FixtureRuntimeState()
    func detectedLANBaseURLs(port: Int) -> [URL] { [] }
}
struct GatewayCard<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: () -> Content
    var body: some View { content().padding(padding).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12)) }
}
struct GatewayQuietBadge: View {
    let text: String
    var tint: Color = .secondary
    var body: some View { Text(text).foregroundStyle(tint) }
}
private func fixtureHome() -> URL {
    URL(fileURLWithPath: ProcessInfo.processInfo.environment["TOKEN_SAVER_FIXTURE_HOME"] ?? Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("home").path)
}
@MainActor private func fixtureReleaseManager() -> TokenSaverReleaseManager {
    let home = fixtureHome()
    let client = TokenSaverReleaseClient { request, _ in
        let path = request.url!.path
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
    let rtk = TokenSaverReleaseRTK(brewURL: URL(fileURLWithPath:"/opt/homebrew/bin/brew")) { _, args in
        .init(status:0,text:args == ["list","--versions","rtk"] ? "rtk 1.0.0" : "fixture upgrade only")
    }
    return TokenSaverReleaseManager(client:client,
        store:TokenSaverReleaseStore(root:home.appendingPathComponent("Library/Application Support/AIUsage/Rules")),
        rtk:rtk, reapplyRules:{ try TokenSaverSettingsStore.save(TokenSaverSettingsStore.load(home:home),home:home) })
}
@main struct TokenSaverUIFixture: App {
    @StateObject var runtime = CLIProxyRuntimeController()
    @State var draft = CLIProxyGatewaySettings()
    var body: some Scene {
        WindowGroup("AIUsage Token Saver — isolated fixture") {
            TabView {
                SubscriptionGatewaySettingsRuntimePane(runtime:runtime,draftSettings:$draft,onApply:{},tokenSaverHome:fixtureHome())
                    .tabItem { Text("Runtime") }
                ScrollView { TokenSaverUpdatesSection(manager:fixtureReleaseManager()).padding(20) }
                    .tabItem { Text("Updates (offline fixtures)") }
            }
            .padding(20).frame(minWidth:760,minHeight:920)
            .onAppear { NSApp.activate(ignoringOtherApps:true) }
        }
    }
}
