import SwiftUI
import AppKit

func L(_ en: String, _ zh: String, key: String = "") -> String { en }
enum SessionPlural { static func en(_ n: Int, _ noun: String) -> String { "\(n) \(noun)s" } }
enum SessionTool { case codex }
struct SessionSummary { var id: String; var tool = SessionTool.codex }
struct ToolStep: Hashable { var name = ""; var detail = ""; var failureNote: String? }
enum TranscriptEntry: Hashable { case prompt(String), reply(String), steps([ToolStep]), notice }
struct TranscriptItem: Identifiable, Hashable { let id: Int; let entry: TranscriptEntry }
struct TranscriptStats { var prompts = 100; var toolCalls = 0; var filesChanged = 0; var failures = 0 }
struct SessionTranscript { let items: [TranscriptItem]; var omittedCount = 0; var stats = TranscriptStats() }
enum SessionCenterStore {
    struct TranscriptFocus: Equatable { let sessionID: String; let itemID: Int; let token: Int }
}
enum AppContent {
    static func primary(_ scheme: ColorScheme) -> Color { .primary }
    static func secondary(_ scheme: ColorScheme) -> Color { .secondary }
    static func tertiary(_ scheme: ColorScheme) -> Color { .secondary }
}
enum AppSurface {
    static func sidebar(_ scheme: ColorScheme) -> Color { .gray }
    static func card(_ scheme: ColorScheme) -> Color { .gray }
}
enum AppStroke { static func subtle(_ scheme: ColorScheme) -> Color { .gray } }
struct SessionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { configuration.label }
}
struct TranscriptItemView: View {
    let tool: SessionTool; let item: TranscriptItem; let terms: [String]
    var body: some View {
        Text("row \(item.id)").frame(maxWidth: .infinity, minHeight: 80, maxHeight: 80)
    }
}

@main struct ReaderScrollProbe {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        let transcript = SessionTranscript(items: (0..<100).map { TranscriptItem(id: $0, entry: .prompt("row \($0)")) })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        func install(focus: SessionCenterStore.TranscriptFocus?) {
            let view = SessionTranscriptView(session: SessionSummary(id: "probe"), transcript: transcript, terms: [], focus: focus)
            window.contentView = NSHostingView(rootView: view)
            window.orderBack(nil)
        }
        func scrolls(_ root: NSView) -> [NSScrollView] {
            (root as? NSScrollView).map { [$0] } ?? root.subviews.flatMap(scrolls)
        }
        func settle() async throws {
            for _ in 0..<20 {
                window.contentView?.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        func offset() -> (CGFloat, CGFloat) {
            let all = scrolls(window.contentView!)
            precondition(all.count == 1, "Expected one native scroll view, found \(all.count)")
            let scroll = all[0]
            let visible = scroll.contentView.bounds
            let doc = scroll.documentView!.bounds
            return (visible.minY, max(0, doc.height - visible.height))
        }
        install(focus: nil)
        try await settle()
        let normal = offset()
        print("NORMAL offset=\(normal.0) max=\(normal.1)")
        // The production bottom marker precedes the 22-point vertical stack padding.
        precondition(normal.1 > 1000 && abs(normal.0 - normal.1) <= 24, "Normal open must reach bottom marker")
        print("PASS: extracted production reader reaches bottom on normal open (100 fixed-height rows)")
        install(focus: .init(sessionID: "probe", itemID: 5, token: 1))
        try await settle()
        let focused = offset()
        print("FOCUSED offset=\(focused.0) max=\(focused.1)")
        precondition(focused.0 < 1000 && focused.1 - focused.0 > 1000, "Search focus near top must not land at bottom")
        print("PASS: extracted production reader preserves near-top search focus instead of bottom")
    }
}
