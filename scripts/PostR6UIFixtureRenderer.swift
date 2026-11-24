import AppKit
import PDFKit
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

        // 4. Antigravity active badge vs dormant BurnRateBadge suppression (compiled ProviderCard + MenuBarAccountRow in VI)
        fixtureLanguage = "vi"
        defer {
            fixtureLanguage = "en"
            activation.activeAccountIds.removeAll()
        }
        let agyActiveSlow = makeCard(
            id: "antigravity:cred:activeSlow",
            providerId: "antigravity",
            label: "active@example.invalid",
            remaining: 74,
            fetchedAt: now,
            windows: [
                .init(label: "Claude + GPT · Hàng tuần", remainingPercent: 74, usedPercent: nil, value: "74%", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(3 * 86400))),
                .init(label: "Gemini · 5 giờ", remainingPercent: 95, usedPercent: nil, value: "95%", note: "", resetAt: future5hIso)
            ]
        )
        let agyActiveFast = makeCard(
            id: "antigravity:cred:activeFast",
            providerId: "antigravity",
            label: "fast-active@example.invalid",
            remaining: 28,
            fetchedAt: now,
            windows: [
                .init(label: "Claude + GPT · Hàng tuần", remainingPercent: 28.6, usedPercent: nil, value: "28.6%", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(4.5 * 86400))),
                .init(label: "Gemini · 5 giờ", remainingPercent: 95.6, usedPercent: nil, value: "95.6%", note: "", resetAt: future5hIso)
            ]
        )
        let agyActiveStale = makeCard(
            id: "antigravity:cred:activeStale",
            providerId: "antigravity",
            label: "stale-active@example.invalid",
            remaining: 74,
            fetchedAt: now.addingTimeInterval(-3600),
            windows: agyActiveSlow.windows
        )
        let agyDormantOld = makeCard(
            id: "antigravity:cred:dormantOld",
            providerId: "antigravity",
            label: "dormant@example.invalid",
            remaining: 66.6,
            fetchedAt: now.addingTimeInterval(-3 * 86400),
            windows: [
                .init(label: "Claude + GPT · Hàng tuần", remainingPercent: 100, usedPercent: nil, value: "100%", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(4 * 86400))),
                .init(label: "Gemini · Hàng tuần", remainingPercent: 74.2, usedPercent: nil, value: "74.2%", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(3.8 * 86400)))
            ]
        )
        let agyDormantRecent = makeCard(
            id: "antigravity:cred:dormantRecent",
            providerId: "antigravity",
            label: "dormant-recent@example.invalid",
            remaining: 74,
            fetchedAt: now.addingTimeInterval(-300),
            windows: agyActiveSlow.windows
        )

        func agyEntry(_ card: ProviderData) -> ProviderAccountEntry {
            ProviderAccountEntry(
                id: card.id,
                providerId: "antigravity",
                providerTitle: "Antigravity",
                providerSubtitle: nil,
                liveProvider: card,
                storedAccount: StoredProviderAccount(
                    id: card.id,
                    providerId: "antigravity",
                    email: card.accountLabel ?? card.label,
                    displayName: nil,
                    note: nil,
                    accountId: card.accountId,
                    providerResultId: card.id,
                    credentialId: card.id,
                    createdAt: SharedFormatters.iso8601String(from: now),
                    lastSeenAt: card.fetchedAt,
                    sourceFilePath: "/tmp/fixture/\(card.id).json"
                )
            )
        }

        let activeSlowEntry = agyEntry(agyActiveSlow)
        let activeFastEntry = agyEntry(agyActiveFast)
        let activeStaleEntry = agyEntry(agyActiveStale)
        let dormantOldEntry = agyEntry(agyDormantOld)
        let dormantRecentEntry = agyEntry(agyDormantRecent)
        activation.activeAccountIds = [activeSlowEntry.id, activeFastEntry.id, activeStaleEntry.id]

        @MainActor func renderCardText(_ entry: ProviderAccountEntry) async throws -> String {
            let view = ProviderCard(
                provider: entry.liveProvider!,
                titleOverride: entry.cardTitle,
                footerAccountLabelOverride: entry.footerAccountLabel,
                accountEntry: entry
            )
            .frame(width: 360)
            .environmentObject(appState)
            .environmentObject(renderCoordinator)
            .environmentObject(activation)
            .environmentObject(settings)
            return try await extractRenderedText(view, scheme: .dark, width: 360)
        }

        let activeSlowText = try await renderCardText(activeSlowEntry)
        try uiCheck(activeSlowText.contains("Đang dùng"), "active slow Antigravity ProviderCard renders 'Đang dùng' badge: \(activeSlowText)")
        try uiCheck(activeSlowText.contains("Tốc độ: ổn định") && !activeSlowText.contains("Steady"), "active slow Antigravity ProviderCard renders localized 'Tốc độ: ổn định'")

        let activeFastText = try await renderCardText(activeFastEntry)
        try uiCheck(activeFastText.contains("Đang dùng"), "active fast Antigravity ProviderCard renders 'Đang dùng' badge")
        try uiCheck(activeFastText.contains("🔥") && activeFastText.contains("phút nữa hết") && !activeFastText.contains("ổn định"),
                    "active fast Antigravity ProviderCard renders localized burn alert instead of steady")

        let activeStaleText = try await renderCardText(activeStaleEntry)
        try uiCheck(activeStaleText.contains("Đang dùng"), "stale active Antigravity ProviderCard still shows 'Đang dùng'")
        try uiCheck(!activeStaleText.contains("ổn định") && !activeStaleText.contains("Steady") && !activeStaleText.contains("🔥"),
                    "stale (>30m) active Antigravity ProviderCard suppresses BurnRateBadge")

        for (name, dormantEntry) in [("3d-old dormant", dormantOldEntry), ("5m-recent dormant", dormantRecentEntry)] {
            let dormantText = try await renderCardText(dormantEntry)
            try uiCheck(!dormantText.contains("Đang dùng"), "\(name) Antigravity ProviderCard omits 'Đang dùng'")
            try uiCheck(!dormantText.contains("ổn định") && !dormantText.contains("Steady") && !dormantText.contains("🔥") && !dormantText.contains("phút nữa hết"),
                        "\(name) Antigravity ProviderCard suppresses BurnRateBadge: \(dormantText)")
        }

        @MainActor func renderMenuRowText(_ entry: ProviderAccountEntry) async throws -> String {
            let view = MenuBarAccountRow(
                entry: entry,
                providerId: "antigravity",
                accentColor: .cyan,
                codexProxyActive: false,
                codexGlobalProxyManaged: false,
                activationMessage: .constant(nil),
                activationSuccess: .constant(false)
            )
            .frame(width: 400)
            .environmentObject(appState)
            .environmentObject(renderCoordinator)
            .environmentObject(activation)
            return try await extractRenderedText(view, scheme: .dark, width: 400)
        }

        let activeRowText = try await renderMenuRowText(activeSlowEntry)
        try uiCheck(activeRowText.contains("Đang dùng") && !activeRowText.contains("Switch") && activeRowText.contains("Tốc độ: ổn định"),
                    "active Antigravity MenuBarAccountRow shows 'Đang dùng' + fresh pace without 'Switch': \(activeRowText)")

        let dormantRowText = try await renderMenuRowText(dormantOldEntry)
        try uiCheck(!dormantRowText.contains("Đang dùng") && !dormantRowText.contains("Switch") && !dormantRowText.contains("ổn định") && !dormantRowText.contains("Steady") && !dormantRowText.contains("🔥"),
                    "dormant Antigravity MenuBarAccountRow omits 'Đang dùng', 'Switch', and BurnRateBadge: \(dormantRowText)")

        // 5. Codex §5.1–§5.3 regressions: missing/malformed fetchedAt ignores coordinator refresh history,
        // past-projected ETA omits '~1 min left', and Codex proxy takeover hides Active + BurnRateBadge.
        renderCoordinator.markAccountRefreshed(agyActiveSlow, at: now)
        let agyActiveMissingTs = makeCard(
            id: agyActiveSlow.id,
            providerId: "antigravity",
            label: "active@example.invalid",
            remaining: 74,
            fetchedAt: nil,
            windows: agyActiveSlow.windows
        )
        let agyActiveMalformedTs = makeCard(
            id: agyActiveSlow.id,
            providerId: "antigravity",
            label: "active@example.invalid",
            remaining: 74,
            fetchedAt: nil,
            rawFetchedAt: "not-a-timestamp",
            windows: agyActiveSlow.windows
        )
        let agyActiveTrailingJunkTs = makeCard(
            id: agyActiveSlow.id,
            providerId: "antigravity",
            label: "active@example.invalid",
            remaining: 74,
            fetchedAt: nil,
            rawFetchedAt: SharedFormatters.iso8601String(from: now) + "junk",
            windows: agyActiveSlow.windows
        )
        let agyActiveInvalidCalendarTs = makeCard(
            id: agyActiveSlow.id,
            providerId: "antigravity",
            label: "active@example.invalid",
            remaining: 74,
            fetchedAt: nil,
            rawFetchedAt: "2026-11-31T00:00:00Z",
            windows: agyActiveSlow.windows
        )
        try uiCheck(renderCoordinator.accountRefreshDate(for: agyActiveMissingTs) != nil,
                    "precondition: coordinator history fallback is populated for missing-timestamp card")
        for (tsKind, card) in [
            ("missing fetchedAt", agyActiveMissingTs),
            ("malformed fetchedAt", agyActiveMalformedTs),
            ("trailing-junk fetchedAt", agyActiveTrailingJunkTs),
            ("invalid-calendar fetchedAt", agyActiveInvalidCalendarTs)
        ] {
            let entry = agyEntry(card)
            let cardText = try await renderCardText(entry)
            try uiCheck(cardText.contains("Đang dùng"), "\(tsKind) active ProviderCard keeps 'Đang dùng'")
            try uiCheck(!cardText.contains("ổn định") && !cardText.contains("Steady") && !cardText.contains("🔥") && !cardText.contains("phút nữa hết") && !cardText.contains("đã qua mốc dự báo"),
                        "\(tsKind) ProviderCard suppresses BurnRateBadge despite coordinator refresh history: \(cardText)")
            let rowText = try await renderMenuRowText(entry)
            try uiCheck(rowText.contains("Đang dùng"), "\(tsKind) active MenuBarAccountRow keeps 'Đang dùng'")
            try uiCheck(!rowText.contains("ổn định") && !rowText.contains("Steady") && !rowText.contains("🔥") && !rowText.contains("phút nữa hết") && !rowText.contains("đã qua mốc dự báo"),
                        "\(tsKind) MenuBarAccountRow suppresses BurnRateBadge despite coordinator refresh history: \(rowText)")
        }

        let offsetFormatter = ISO8601DateFormatter()
        offsetFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        offsetFormatter.timeZone = TimeZone(secondsFromGMT: 7 * 3600)
        let agyActiveFractionalOffsetTs = makeCard(
            id: agyActiveSlow.id,
            providerId: "antigravity",
            label: "active@example.invalid",
            remaining: 74,
            fetchedAt: nil,
            rawFetchedAt: offsetFormatter.string(from: now),
            windows: agyActiveSlow.windows
        )
        let fractionalOffsetEntry = agyEntry(agyActiveFractionalOffsetTs)
        let fractionalCardText = try await renderCardText(fractionalOffsetEntry)
        try uiCheck(fractionalCardText.contains("Đang dùng") && fractionalCardText.contains("Tốc độ: ổn định"),
                    "fractional +07:00 ISO8601 timestamp renders 'Đang dùng' + 'Tốc độ: ổn định' on ProviderCard: \(fractionalCardText)")
        let fractionalRowText = try await renderMenuRowText(fractionalOffsetEntry)
        try uiCheck(fractionalRowText.contains("Đang dùng") && fractionalRowText.contains("Tốc độ: ổn định"),
                    "fractional +07:00 ISO8601 timestamp renders 'Đang dùng' + 'Tốc độ: ổn định' on MenuBarAccountRow: \(fractionalRowText)")

        let rolloverFixedClock = QuotaBurnRate.parseSnapshotTimestamp("2026-12-01T00:00:00Z")!
        let rolloverWindows: [QuotaWindow] = [
            .init(label: "Gemini · 5 giờ", remainingPercent: 74, usedPercent: nil, value: "74%", note: "", resetAt: "2026-12-01T03:00:00Z")
        ]
        let looseRolloverBadge = BurnRateBadge(
            windows: rolloverWindows,
            fetchedAt: SharedFormatters.parseISO8601("2026-11-31T00:00:00Z"),
            isStale: false,
            now: rolloverFixedClock
        )
        let strictRolloverBadge = BurnRateBadge(
            windows: rolloverWindows,
            fetchedAt: QuotaBurnRate.parseSnapshotTimestamp("2026-11-31T00:00:00Z"),
            isStale: false,
            now: rolloverFixedClock
        )
        let looseRolloverText = try await extractRenderedText(looseRolloverBadge, scheme: .dark, width: 280)
        try uiCheck(looseRolloverText.contains("Tốc độ: ổn định"),
                    "precondition: Foundation loose parse would roll 2026-11-31 to 2026-12-01 and render BurnRateBadge: \(looseRolloverText)")
        let strictRolloverText = try await extractRenderedText(strictRolloverBadge, scheme: .dark, width: 280)
        try uiCheck(!strictRolloverText.contains("ổn định") && !strictRolloverText.contains("Steady") && !strictRolloverText.contains("🔥"),
                    "strict parseSnapshotTimestamp suppresses BurnRateBadge on 2026-11-31 at 2026-12-01 clock: \(strictRolloverText)")

        let agyActivePastEta = makeCard(
            id: "antigravity:cred:activePastEta",
            providerId: "antigravity",
            label: "past-eta@example.invalid",
            remaining: 5,
            fetchedAt: now.addingTimeInterval(-600),
            windows: [
                .init(label: "Gemini · 5 giờ", remainingPercent: 5, usedPercent: nil, value: "5%", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(4 * 3600 - 600)))
            ]
        )
        let agyActiveSubMinuteEta = makeCard(
            id: "antigravity:cred:activeSubMinuteEta",
            providerId: "antigravity",
            label: "subminute-eta@example.invalid",
            remaining: 5,
            fetchedAt: now.addingTimeInterval(-159),
            windows: [
                .init(label: "Gemini · 5 giờ", remainingPercent: 5, usedPercent: nil, value: "5%", note: "", resetAt: SharedFormatters.iso8601String(from: now.addingTimeInterval(4 * 3600 - 159)))
            ]
        )
        let activePastEtaEntry = agyEntry(agyActivePastEta)
        let activeSubMinuteEntry = agyEntry(agyActiveSubMinuteEta)
        activation.activeAccountIds.insert(activePastEtaEntry.id)
        activation.activeAccountIds.insert(activeSubMinuteEntry.id)

        let pastEtaText = try await renderCardText(activePastEtaEntry)
        try uiCheck(pastEtaText.contains("🔥") && pastEtaText.contains("đã qua mốc dự báo") && !pastEtaText.contains("phút nữa hết") && !pastEtaText.contains("~1"),
                    "past-projected ETA renders 'đã qua mốc dự báo' instead of '~1 phút nữa hết': \(pastEtaText)")

        let subMinuteText = try await renderCardText(activeSubMinuteEntry)
        try uiCheck(subMinuteText.contains("🔥") && subMinuteText.contains("~1 phút nữa hết") && !subMinuteText.contains("đã qua mốc dự báo"),
                    "positive sub-minute ETA keeps '~1 phút nữa hết' distinct from past-projected ETA: \(subMinuteText)")

        let codexCard = makeCard(
            id: "codex:cred:proxyCheck",
            providerId: "codex",
            label: "codex-proxy@example.invalid",
            remaining: 74,
            fetchedAt: now,
            windows: [
                .init(label: "5h Window", remainingPercent: 74, usedPercent: nil, value: "74%", note: "", resetAt: future5hIso)
            ]
        )
        let codexEntry = ProviderAccountEntry(
            id: codexCard.id,
            providerId: "codex",
            providerTitle: "Codex",
            providerSubtitle: nil,
            liveProvider: codexCard,
            storedAccount: StoredProviderAccount(
                id: codexCard.id,
                providerId: "codex",
                email: "codex-proxy@example.invalid",
                displayName: nil,
                note: nil,
                accountId: codexCard.accountId,
                providerResultId: codexCard.id,
                credentialId: codexCard.id,
                createdAt: SharedFormatters.iso8601String(from: now),
                lastSeenAt: codexCard.fetchedAt,
                sourceFilePath: "/tmp/fixture/codex-proxy.json"
            )
        )
        let codexProxyCardText = try await renderCardText(codexEntry)
        try uiCheck(!codexProxyCardText.contains("Đang dùng") && !codexProxyCardText.contains("ổn định") && !codexProxyCardText.contains("🔥"),
                    "Codex ProviderCard suppresses Active and BurnRateBadge when proxy leaves active ID nil: \(codexProxyCardText)")
        let codexProxyRow = MenuBarAccountRow(
            entry: codexEntry,
            providerId: "codex",
            accentColor: .indigo,
            codexProxyActive: true,
            codexGlobalProxyManaged: false,
            activationMessage: .constant(nil),
            activationSuccess: .constant(false)
        )
        .frame(width: 400)
        .environmentObject(appState)
        .environmentObject(renderCoordinator)
        .environmentObject(activation)
        let codexProxyRowText = try await extractRenderedText(codexProxyRow, scheme: .dark, width: 400)
        try uiCheck(!codexProxyRowText.contains("Đang dùng") && !codexProxyRowText.contains("ổn định") && !codexProxyRowText.contains("🔥"),
                    "Codex MenuBarAccountRow omits Active and BurnRateBadge when codexProxyActive=true: \(codexProxyRowText)")
        activation.activeAccountIds.insert(codexEntry.id)
        let codexProxyFallbackRowText = try await extractRenderedText(codexProxyRow, scheme: .dark, width: 400)
        try uiCheck(!codexProxyFallbackRowText.contains("Đang dùng") && !codexProxyFallbackRowText.contains("ổn định") && !codexProxyFallbackRowText.contains("🔥"),
                    "Codex MenuBarAccountRow still omits Active and BurnRateBadge when codexProxyActive=true even if activeAccountIds contains entry: \(codexProxyFallbackRowText)")
        activation.activeAccountIds.remove(codexEntry.id)

        let agyStackView = VStack(spacing: 12) {
            ProviderCard(
                provider: agyActiveFast,
                titleOverride: activeFastEntry.cardTitle,
                footerAccountLabelOverride: activeFastEntry.footerAccountLabel,
                accountEntry: activeFastEntry
            )
            ProviderCard(
                provider: agyDormantOld,
                titleOverride: dormantOldEntry.cardTitle,
                footerAccountLabelOverride: dormantOldEntry.footerAccountLabel,
                accountEntry: dormantOldEntry
            )
        }
        .padding(16)
        .frame(width: 420)
        .background(AppSurface.page(.dark))
        .environmentObject(appState)
        .environmentObject(renderCoordinator)
        .environmentObject(activation)
        .environmentObject(settings)

        let agyPngURL = outputDir.appendingPathComponent("post-r6-agy-active-burnrate-vi-dark.png")
        let agySize = try await renderOffscreen(agyStackView, scheme: .dark, width: 420, to: agyPngURL)
        try uiCheck(agySize.height > 200, "Rendered Antigravity active/dormant VI dark stack height=\(agySize.height)")
        try uiCheck(StubURLProtocol.requests.isEmpty, "UI rendering performed ZERO network requests")

        let manifest: [String: Any] = [
            "rendered": [
                ["file": pngURL.lastPathComponent, "width": size.width, "height": size.height],
                ["file": agyPngURL.lastPathComponent, "width": agySize.width, "height": agySize.height]
            ],
            "assertions": uiCheckCount,
            "httpRequests": StubURLProtocol.requests.count
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            .write(to: outputDir.appendingPathComponent("ui-fixture-manifest.json"))
        print("PASS: Post-R6 compiled production UI + coordinator timestamp/health fixture (\(uiCheckCount) assertions, \(StubURLProtocol.requests.count) HTTP calls, rendered \(pngURL.lastPathComponent) & \(agyPngURL.lastPathComponent))")
    }

    @MainActor static func makeCard(
        id: String,
        providerId: String,
        label: String,
        remaining: Double,
        fetchedAt: Date?,
        rawFetchedAt: String? = nil,
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
            fetchedAt: rawFetchedAt ?? fetchedAt.map { SharedFormatters.iso8601String(from: $0) },
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

    @MainActor static func extractRenderedText<V: View>(_ root: V, scheme: ColorScheme, width: CGFloat) async throws -> String {
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.setFrameSize(NSSize(width: width, height: 1))
        let height = ceil(hosting.fittingSize.height)
        let size = NSSize(width: width, height: max(height, 40))
        window.setContentSize(size)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        await Task.yield()
        hosting.layoutSubtreeIfNeeded()
        var parts: [String] = []
        var visited = Set<ObjectIdentifier>()
        func visit(_ obj: AnyObject) {
            let id = ObjectIdentifier(obj)
            guard visited.insert(id).inserted else { return }
            if let ax = obj as? NSAccessibilityProtocol {
                for value in [ax.accessibilityLabel(), ax.accessibilityTitle(), ax.accessibilityValue() as? String, ax.accessibilityHelp()] {
                    if let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        parts.append(text)
                    }
                }
                for child in (ax.accessibilityChildren() ?? []) {
                    visit(child as AnyObject)
                }
            }
            if let view = obj as? NSView {
                if let tf = view as? NSTextField, !tf.stringValue.isEmpty { parts.append(tf.stringValue) }
                if let btn = view as? NSButton, !btn.title.isEmpty { parts.append(btn.title) }
                for sub in view.subviews { visit(sub) }
            }
        }
        visit(hosting)
        let pdfData = hosting.dataWithPDF(inside: hosting.bounds)
        if let pdfString = PDFDocument(data: pdfData)?.string {
            parts.append(pdfString)
        }
        window.contentView = nil
        return parts.joined(separator: " | ")
    }

    @MainActor static func renderOffscreen<V: View>(_ root: V, scheme: ColorScheme, width: CGFloat, to url: URL) async throws -> CGSize {
        let hosting = NSHostingView(rootView: root.environment(\.colorScheme, scheme))
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: width, height: 1), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
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
