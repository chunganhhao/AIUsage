import AppKit
import Combine
import Foundation
import QuotaBackend
import SwiftUI

func L(_ en: String, _ zh: String) -> String { en }

enum AppSurface {
    static func card(_ scheme: ColorScheme) -> Color { Color(nsColor: .controlBackgroundColor) }
}
enum AppStroke {
    static func card(_ scheme: ColorScheme) -> Color { Color.secondary.opacity(0.2) }
}

struct TokenSaverStatusBadge: View {
    enum Tone { case active, warning, danger, neutral }
    let text: String
    let tone: Tone
    let id: String
    var body: some View {
        Text(text).accessibilityIdentifier(id)
    }
}

@main struct TokenSaverSilentErrorProbe {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let home = fm.temporaryDirectory.appendingPathComponent("local-sidebar-review-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: home) }
        let controller = TokenSaverSettingsController(home: home)
        controller.mutate { $0.cavemanEnabled = true }
        precondition(controller.error == nil && controller.lastSaveSucceeded)
        precondition(controller.notice?.contains("Saved.") == true)

        let hostSuccess = NSHostingView(rootView: ExtractedCodexTokenSaverHarness(tokenSaver: controller))
        hostSuccess.frame = NSRect(x: 0, y: 0, width: 760, height: 260)
        hostSuccess.layoutSubtreeIfNeeded()

        let agents = home.appendingPathComponent(".codex/AGENTS.md")
        let original = try String(contentsOf: agents, encoding: .utf8)
        let edited = original.replacingOccurrences(of: "Caveman active mode:", with: "User-edited Caveman active mode:")
        precondition(edited != original)
        try Data(edited.utf8).write(to: agents)
        let persisted = try TokenSaverSettingsStore.load(home: home)

        controller.mutate { $0.ponytailEnabled = true }
        precondition(controller.error?.contains("edited externally") == true)
        precondition(controller.localizedError?.contains("edited externally") == true)
        precondition(controller.settings == persisted && !controller.lastSaveSucceeded)
        let afterSettings = try TokenSaverSettingsStore.load(home: home)
        let afterRules = try String(contentsOf: agents, encoding: .utf8)
        precondition(afterSettings == persisted)
        precondition(afterRules == edited)
        print("PASS: production controller rejects toggle, exposes conflict error, rolls back settings, preserves edited rules")

        controller.reapply()
        precondition(controller.localizedError?.contains("edited externally") == true)
        precondition(!controller.lastSaveSucceeded)

        let hostFailure = NSHostingView(rootView: ExtractedCodexTokenSaverHarness(tokenSaver: controller))
        hostFailure.frame = NSRect(x: 0, y: 0, width: 760, height: 260)
        hostFailure.layoutSubtreeIfNeeded()
        print("PASS: production controller reapply also exposes conflict error and renders extracted CodexLocalManagementView.tokenSaverCard")

        RecordedAGYMetricTags.values.removeAll()
        let hostAGYNil = NSHostingView(rootView: ExtractedAGYPoolProtectionHarness(envSummary: DummyAGYEnvSummary()))
        hostAGYNil.frame = NSRect(x: 0, y: 0, width: 760, height: 220)
        hostAGYNil.layoutSubtreeIfNeeded()
        precondition(RecordedAGYMetricTags.values["Model"] == "—")
        precondition(RecordedAGYMetricTags.values["Thinking"] == "—")
        precondition(RecordedAGYMetricTags.values["Execution"] == "—")
        precondition(RecordedAGYMetricTags.values["Artifact Review"] == "—")
        precondition(RecordedAGYMetricTags.values["Security"] == "—")
        precondition(RecordedAGYMetricTags.values["Workspaces"] == "0")
        print("PASS: extracted AntigravityManagementView.poolProtectionCard renders '—' when runtime/policy inspection values are nil")

        RecordedAGYMetricTags.values.removeAll()
        let hostAGYPopulated = NSHostingView(
            rootView: ExtractedAGYPoolProtectionHarness(
                envSummary: DummyAGYEnvSummary(
                    activeModel: "gemini-3-flash",
                    thinkingEffort: nil,
                    executionPolicy: "request-review",
                    artifactReviewPolicy: "ask-review",
                    securityMode: "secure-sandbox",
                    workspaceCount: 4
                )
            )
        )
        hostAGYPopulated.frame = NSRect(x: 0, y: 0, width: 760, height: 220)
        hostAGYPopulated.layoutSubtreeIfNeeded()
        precondition(RecordedAGYMetricTags.values["Model"] == "gemini-3-flash")
        precondition(RecordedAGYMetricTags.values["Thinking"] == "—")
        precondition(RecordedAGYMetricTags.values["Execution"] == "request-review")
        precondition(RecordedAGYMetricTags.values["Artifact Review"] == "ask-review")
        precondition(RecordedAGYMetricTags.values["Security"] == "secure-sandbox")
        precondition(RecordedAGYMetricTags.values["Workspaces"] == "4")
        print("PASS: extracted AntigravityManagementView.poolProtectionCard renders decoded values and keeps nil Thinking as '—'")

        // Verify 28x28 right-square hit target on SessionResumeButton split-button layout
        _ = NSApplication.shared
        var leftClicks = 0
        var rightClicks = 0
        struct PrimarySegmentProbeStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
                    .frame(maxHeight: .infinity)
                    .background(Color.white.opacity(0.001))
                    .contentShape(Rectangle())
            }
        }
        struct SplitButtonHitHarness: View {
            var onLeft: () -> Void
            var onRight: () -> Void
            var body: some View {
                HStack(spacing: 0) {
                    Button(action: onLeft) {
                        Text("Resume in Terminal")
                            .padding(.leading, 11)
                            .padding(.trailing, 9)
                    }
                    .buttonStyle(PrimarySegmentProbeStyle())
                    Rectangle()
                        .fill(Color.white.opacity(0.28))
                        .frame(width: 1, height: 16)
                    Button(action: onRight) {
                        ZStack {
                            Color.white.opacity(0.001)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PrimarySegmentProbeStyle())
                    .frame(width: 28, height: 28)
                }
                .frame(height: 28)
                .fixedSize()
            }
        }
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 28),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let splitHost = NSHostingView(
            rootView: SplitButtonHitHarness(
                onLeft: { leftClicks += 1 },
                onRight: { rightClicks += 1 }
            )
        )
        let fitSize = splitHost.fittingSize
        win.setContentSize(fitSize)
        splitHost.frame = NSRect(origin: .zero, size: fitSize)
        win.contentView = splitHost
        splitHost.layoutSubtreeIfNeeded()
        let rightMinX = fitSize.width - 28.0
        for pt in [
            NSPoint(x: rightMinX + 2, y: 2),
            NSPoint(x: fitSize.width - 2, y: 2),
            NSPoint(x: rightMinX + 2, y: 26),
            NSPoint(x: fitSize.width - 2, y: 26),
            NSPoint(x: rightMinX + 14, y: 14)
        ] {
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown,
                location: pt,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: win.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 1
            )!
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp,
                location: pt,
                modifierFlags: [],
                timestamp: 0,
                windowNumber: win.windowNumber,
                context: nil,
                eventNumber: 1,
                clickCount: 1,
                pressure: 0
            )!
            splitHost.mouseDown(with: down)
            splitHost.mouseUp(with: up)
        }
        precondition(rightClicks == 5 && leftClicks == 0, "Expected 5/5 right-square corner+center clicks, got right=\(rightClicks) left=\(leftClicks)")
        print("PASS: SessionResumeButton 28x28 right square registers 5/5 corner+center clicks with 0 false left-segment hits")

        precondition(
            SessionResumePlan.desktopDeepLinkURL(for: .codex, sessionID: "019A0000-0000-7000-8000-000000000001")
                == URL(string: "codex://threads/019a0000-0000-7000-8000-000000000001")
        )
        precondition(SessionResumePlan.desktopDeepLinkURL(for: .codex, sessionID: "not-a-uuid") == nil)
        precondition(SessionResumePlan.desktopDeepLinkURL(for: .claude, sessionID: "11111111-2222-4333-8444-555555555555") == nil)
        precondition(SessionResumePlan.desktopDeepLinkURL(for: .opencode, sessionID: "ses_47d61c905ffesCirj") == nil)
        precondition(SessionResumePlan.desktopDeepLinkURL(for: .antigravity, sessionID: "22222222-3333-4444-8555-666666666666") == nil)
        print("PASS: SessionResumePlan.desktopDeepLinkURL produces codex://threads/<uuid> for Codex and nil for non-deep-link tools")

        await controller.waitForPendingInspection()
    }
}
