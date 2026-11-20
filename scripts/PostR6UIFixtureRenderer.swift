import AppKit
import SwiftUI
@testable import QuotaBackend

private struct UIFixtureError: Error, CustomStringConvertible {
    let description: String
}

private var uiCheckCount = 0
private func uiCheck(_ cond: @autoclosure () -> Bool, _ msg: String) throws {
    uiCheckCount += 1
    if !cond() {
        throw UIFixtureError(description: "FAILED [\(uiCheckCount)]: \(msg)")
    }
}

@main
struct PostR6UIFixtureRenderer {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        guard CommandLine.arguments.count >= 2 else {
            throw UIFixtureError(description: "Pass scratch output directory as argv[1]")
        }
        let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let fixtureHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("post-r6-ui-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixtureHome, withIntermediateDirectories: true)
        FixtureResetEnvironment.home = fixtureHome
        FixtureResetEnvironment.coordinator = CodexResetCreditsCoordinator(
            operations: .init(journalURL: fixtureHome.appendingPathComponent("pending.json")),
            loadCredential: { _ in nil },
            isLocal: { false }
        )

        StubURLProtocol.install(hosts: ["googleapis.com", "chatgpt.com", "auth.openai.com", "oauth2.googleapis.com"])
        defer {
            StubURLProtocol.uninstall()
            try? FileManager.default.removeItem(at: fixtureHome)
        }

        let now = Date()
        let sixtyMinsAgo = now.addingTimeInterval(-3600)
        let pastIso = SharedFormatters.iso8601String(from: now.addingTimeInterval(-300))
        let futureWeeklyIso = SharedFormatters.iso8601String(from: now.addingTimeInterval(36 * 3600))
        let future5hIso = SharedFormatters.iso8601String(from: now.addingTimeInterval(3 * 3600))

        // 1. Test [B1] / [B2] coordinator timestamp anchoring + last-good preservation using real extracted production methods
        let coordinator = ProviderRefreshCoordinator()
        coordinator.language = "en"

        let card60m = makeCard(
            id: "antigravity:cred:old60",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 80,
            fetchedAt: sixtyMinsAgo,
            windows: [
                .init(label: "Gemini 2.5 Pro", remainingPercent: 80, usedPercent: nil, value: "80%", note: "", resetAt: future5hIso)
            ]
        )
        coordinator.providers = [card60m]
        coordinator.completeGlobalRefresh(.classified(totalResults: 1, refreshedProviders: [card60m], at: now))
        let recordedAge = coordinator.accountRefreshDate(for: card60m)
        try uiCheck(recordedAge != nil && abs(recordedAge!.timeIntervalSince(sixtyMinsAgo)) < 1, "[B1] global refresh anchors dormant card to fetchedAt (-60m), not Date()")
        let providerAge = coordinator.providerRefreshTimes["antigravity"]
        try uiCheck(providerAge != nil && abs(providerAge!.timeIntervalSince(sixtyMinsAgo)) < 1, "[B1] providerRefreshTimes anchors to actual card fetchedAt, not Date()")

        // [Review #1] Two AGY credentials sharing email must not smear newer peer timestamp onto 60m-old card
        let peerNow = makeCard(
            id: "antigravity:cred:projectB",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 70,
            fetchedAt: now,
            windows: card60m.windows
        )
        FixtureResetEnvironment.credentialIDs[card60m.id] = "projectA"
        FixtureResetEnvironment.credentialIDs[peerNow.id] = "projectB"
        coordinator.providers = [card60m, peerNow]
        coordinator.completeGlobalRefresh(.classified(totalResults: 2, refreshedProviders: [card60m, peerNow], at: now))
        let ageWithPeer = coordinator.accountRefreshDate(for: card60m)
        try uiCheck(ageWithPeer != nil && abs(ageWithPeer!.timeIntervalSince(sixtyMinsAgo)) < 1, "[B1] newer peer with same email keeps 60m-old card age untouched")
        let unfetchedPeer = makeCard(
            id: "antigravity:cred:projectC",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 50,
            fetchedAt: nil,
            windows: card60m.windows
        )
        FixtureResetEnvironment.credentialIDs[unfetchedPeer.id] = "projectC"
        coordinator.providers = [card60m, peerNow, unfetchedPeer]
        try uiCheck(coordinator.accountRefreshDate(for: unfetchedPeer) == nil, "[B1] unfetched AGY workspace sharing email does not inherit active peer refresh time")
        try uiCheck(coordinator.currentProviderMatchingRefresh(peerNow)?.id == peerNow.id, "[B1] currentProviderMatchingRefresh matches projectB instead of earlier same-email projectA")
        try uiCheck(coordinator.currentProviderMatchingRefresh(unfetchedPeer)?.id == unfetchedPeer.id, "[B1] currentProviderMatchingRefresh keeps projectC isolated by credential")

        // Same quota percentages acquired live at `now` advances timestamp to `now`
        let cardSameQuotaNow = makeCard(
            id: "antigravity:cred:old60",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 80,
            fetchedAt: now,
            windows: [
                .init(label: "Gemini 2.5 Pro", remainingPercent: 80, usedPercent: nil, value: "80%", note: "", resetAt: future5hIso)
            ]
        )
        coordinator.completeAccountRefresh(
            refreshKey: "antigravity:old60",
            result: .success(refreshedProviders: [cardSameQuotaNow], at: now)
        )
        let updatedAge = coordinator.accountRefreshDate(for: cardSameQuotaNow)
        try uiCheck(updatedAge != nil && abs(updatedAge!.timeIntervalSince(now)) < 1, "[B1] real fetch with same 80% quota advances timestamp to new fetchedAt")

        // Failed transient 429 check preserves existing 80% card & -60m timestamp, and populates accountLastCheckErrors
        let errorIncoming = ProviderData(
            id: "antigravity:cred:old60",
            providerId: "antigravity",
            accountId: "dormant@example.invalid",
            name: "Antigravity",
            label: "dormant@example.invalid",
            description: "",
            category: "quota",
            channel: "ide",
            status: .error,
            statusLabel: "Error",
            theme: .init(accent: "cyan", glow: "#22d3ee"),
            sourceLabel: "OAuth",
            sourceType: "auth",
            fetchedAt: nil,
            accountLabel: "dormant@example.invalid",
            membershipLabel: "Pro",
            headline: .init(eyebrow: "", primary: "Rate limited", secondary: "", supporting: "HTTP 429"),
            metrics: [],
            windows: [],
            remainingPercent: nil,
            nextResetAt: nil,
            nextResetLabel: nil,
            spotlight: nil,
            models: nil,
            costSummary: nil,
            errorCode: "rate_limited"
        )
        let preserved = coordinator.preferredBulkRefreshProvider(incoming: errorIncoming, existing: card60m)
        try uiCheck(preserved?.remainingPercent == 80 && preserved?.fetchedAt == card60m.fetchedAt, "[B2] transient 429 preserves last-good 80% windows and fetchedAt")
        try uiCheck(coordinator.lastCheckError(for: card60m)?.message == "HTTP 429", "[B2] transient failure surfaces accountLastCheckErrors separately")
        try uiCheck(coordinator.lastCheckError(for: peerNow) == nil, "[B2] transient error on projectA does not leak onto same-email peer projectB")

        // [Review #4] Passive cache-only tick replaying the old preserved snapshot must NOT clear last real check error
        let afterPassiveCache = coordinator.preferredBulkRefreshProvider(incoming: card60m, existing: preserved)
        try uiCheck(afterPassiveCache?.fetchedAt == card60m.fetchedAt, "[B2] passive cache-only tick keeps preserved fetchedAt")
        try uiCheck(coordinator.lastCheckError(for: card60m)?.message == "HTTP 429", "[B2] cache-only tick must retain last real check failure")

        // A genuinely newer acquisition after the error clears the error cleanly
        let newerRecovery = makeCard(
            id: "antigravity:cred:old60",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 82,
            fetchedAt: now.addingTimeInterval(5),
            windows: card60m.windows
        )
        _ = coordinator.preferredBulkRefreshProvider(incoming: newerRecovery, existing: preserved)
        try uiCheck(coordinator.lastCheckError(for: card60m) == nil, "[B2] genuinely newer acquisition after failed check clears accountLastCheckErrors")

        // Same-UTC-second recovery (`failedAt = T.450`, ISO8601 `fetchedAt = T.000`) must also clear error
        let sameSecFloor = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 1)
        let sameSecMid = sameSecFloor.addingTimeInterval(0.45)
        for key in coordinator.accountCheckErrorKeys(for: card60m) {
            coordinator.accountLastCheckErrors[key] = AccountCheckError(message: "HTTP 429", errorCode: "rate_limited", failedAt: sameSecMid)
        }
        let sameSecRecovery = makeCard(
            id: "antigravity:cred:old60",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 83,
            fetchedAt: sameSecFloor,
            windows: card60m.windows
        )
        _ = coordinator.preferredBulkRefreshProvider(incoming: sameSecRecovery, existing: card60m)
        try uiCheck(coordinator.lastCheckError(for: card60m) == nil, "[B2] same-second ISO8601 recovery clears sub-second accountLastCheckErrors")

        // Re-record 429 before testing terminal override
        _ = coordinator.preferredBulkRefreshProvider(incoming: errorIncoming, existing: card60m)

        // Terminal tos_violation overrides last-good card cleanly
        let terminalIncoming = ProviderData(
            id: "antigravity:cred:old60",
            providerId: "antigravity",
            accountId: "dormant@example.invalid",
            name: "Antigravity",
            label: "dormant@example.invalid",
            description: "",
            category: "quota",
            channel: "ide",
            status: .error,
            statusLabel: "Error",
            theme: .init(accent: "cyan", glow: "#22d3ee"),
            sourceLabel: "OAuth",
            sourceType: "auth",
            fetchedAt: nil,
            accountLabel: "dormant@example.invalid",
            membershipLabel: "Pro",
            headline: .init(eyebrow: "", primary: "Suspended", secondary: "", supporting: "TOS Violation"),
            metrics: [],
            windows: [],
            remainingPercent: nil,
            nextResetAt: nil,
            nextResetLabel: nil,
            spotlight: nil,
            models: nil,
            costSummary: nil,
            errorCode: "tos_violation"
        )
        let suspendedChoice = coordinator.preferredBulkRefreshProvider(incoming: terminalIncoming, existing: card60m)
        try uiCheck(suspendedChoice?.errorCode == "tos_violation" && suspendedChoice?.status == .error, "[B2] terminal tos_violation replaces stale ok card cleanly")

        // 2. Derived formatter assertions ([B2] never says "soon", never fabricates 100%)
        fixtureLanguage = "en"
        try uiCheck(QuotaResetFormatter.compactText(resetAt: pastIso, language: "en", now: now) == "Past reset", "[B2] expired resetAt displays 'Past reset' instead of 'soon'")
        let pastHealth = QuotaResetFormatter.snapshotHealth(for: makeCard(id: "p", providerId: "codex", label: "p", remaining: 0, fetchedAt: sixtyMinsAgo, windows: [.init(label: "5h Window", remainingPercent: 0, usedPercent: nil, value: "0%", note: "", resetAt: pastIso)]), now: now)
        try uiCheck(QuotaResetFormatter.snapshotHealthBannerText(for: pastHealth, language: "en", now: now) == "Past reset — Check again", "[B2] past reset banner renders 'Past reset — Check again'")

        let weeklyCard = makeCard(
            id: "codex:cred:dep",
            providerId: "codex",
            label: "depleted@example.invalid",
            remaining: 0,
            fetchedAt: sixtyMinsAgo,
            windows: [
                .init(label: "5h Window", remainingPercent: 0, usedPercent: nil, value: "0%", note: "", resetAt: future5hIso),
                .init(label: "Weekly Window", remainingPercent: 0, usedPercent: nil, value: "0%", note: "", resetAt: futureWeeklyIso)
            ]
        )
        let weeklyHealth = QuotaResetFormatter.snapshotHealth(for: weeklyCard, now: now)
        let weeklyBanner = QuotaResetFormatter.snapshotHealthBannerText(for: weeklyHealth, language: "en", now: now) ?? ""
        try uiCheck(weeklyBanner.hasPrefix("Weekly depleted · Resets at "), "[B2] weekly depleted banner renders '\(weeklyBanner)'")

        // 3. Render real production ProviderCard states (60m cached, Past Reset, Weekly Depleted, Last Check Failed w/ Last-Good)
        let cardPastReset = makeCard(
            id: "codex:cred:past",
            providerId: "codex",
            label: "pastreset@example.invalid",
            remaining: 0,
            fetchedAt: sixtyMinsAgo,
            windows: [.init(label: "5h Window", remainingPercent: 0, usedPercent: nil, value: "0%", note: "", resetAt: pastIso)]
        )
        let renderCoordinator = ProviderRefreshCoordinator()
        _ = renderCoordinator.preferredBulkRefreshProvider(incoming: errorIncoming, existing: card60m)
        let appState = AppState()
        let activation = ProviderActivationManager.shared
        let settings = AppSettings.shared

        let rootView = VStack(spacing: 12) {
            ProviderCard(provider: card60m, titleOverride: "Last known + Check failed (80% preserved)")
            ProviderCard(provider: cardPastReset, titleOverride: "Past reset (0% preserved)")
            ProviderCard(provider: weeklyCard, titleOverride: "Weekly depleted")
        }
        .padding(16)
        .frame(width: 440)
        .background(AppSurface.page(.light))
        .environmentObject(appState)
        .environmentObject(renderCoordinator)
        .environmentObject(activation)
        .environmentObject(settings)

        let pngURL = outputDir.appendingPathComponent("post-r6-provider-cards-en-light.png")
        let size = try await renderOffscreen(rootView, scheme: .light, width: 440, to: pngURL)
        try uiCheck(size.height > 250, "Rendered real ProviderCard UI stack height=\(size.height)")
        try uiCheck(StubURLProtocol.requests.isEmpty, "UI rendering performed ZERO network requests")

        let manifest: [String: Any] = [
            "rendered": ["file": pngURL.lastPathComponent, "width": size.width, "height": size.height],
            "assertions": uiCheckCount,
            "httpRequests": StubURLProtocol.requests.count
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDir.appendingPathComponent("ui-fixture-manifest.json"))
        print("PASS: Post-R6 compiled production UI + coordinator timestamp/health fixture (\(uiCheckCount) assertions, \(StubURLProtocol.requests.count) HTTP calls, rendered \(pngURL.lastPathComponent))")
    }

    @MainActor static func makeCard(
        id: String,
        providerId: String,
        label: String,
        remaining: Double,
        fetchedAt: Date?,
        windows: [QuotaWindow]
    ) -> ProviderData {
        ProviderData(
            id: id,
            providerId: providerId,
            accountId: label,
            name: providerId.capitalized,
            label: label,
            description: "",
            category: "quota",
            channel: "cli",
            status: remaining <= 10 ? .critical : .healthy,
            statusLabel: remaining <= 10 ? "Critical" : "Healthy",
            theme: .init(accent: providerId == "codex" ? "indigo" : "cyan", glow: ""),
            sourceLabel: "Fixture",
            sourceType: "auth",
            fetchedAt: fetchedAt.map { SharedFormatters.iso8601String(from: $0) },
            accountLabel: label,
            membershipLabel: "Pro",
            headline: .init(eyebrow: "", primary: "\(Int(remaining))%", secondary: "", supporting: ""),
            metrics: [],
            windows: windows,
            remainingPercent: remaining,
            nextResetAt: windows.first?.resetAt,
            nextResetLabel: nil,
            spotlight: nil,
            models: nil,
            costSummary: nil
        )
    }

    @MainActor static func renderOffscreen<V: View>(_ root: V, scheme: ColorScheme, width: CGFloat, to url: URL) async throws -> CGSize {
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        hosting.setFrameSize(NSSize(width: width, height: 1))
        let height = ceil(hosting.fittingSize.height)
        let size = NSSize(width: width, height: max(height, 120))
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width * 2),
            pixelsHigh: Int(size.height * 2),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw UIFixtureError(description: "Unable to create NSBitmapImageRep")
        }
        bitmap.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw UIFixtureError(description: "Unable to encode PNG")
        }
        try png.write(to: url)
        window.contentView = nil
        return size
    }
}
