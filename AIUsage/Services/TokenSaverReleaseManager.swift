import Foundation
import Combine
import QuotaBackend

// MARK: - Token Saver release manager

@MainActor
final class TokenSaverReleaseManager: ObservableObject {
    struct Status {
        var staged: TokenSaverReleaseStagedRules?
        var installedBinaryVersion: String?
        var binaryInspected = false
        var brewAvailable = false
        var latest: TokenSaverRelease?
        var checkedAt: Date?
        var isBusy = false
        var error: String?
        var notice: String?
        var isCurrent: Bool { staged?.commit == latest?.commit && staged != nil && latest != nil }
    }

    @Published private(set) var statuses: [TokenSaverReleaseTool: Status] = [:]
    private let client: TokenSaverReleaseClient
    private let store: TokenSaverReleaseStore
    private let reapplyRules: () throws -> Void
    private let rtk: TokenSaverReleaseRTK

    init(client: TokenSaverReleaseClient = .init(), store: TokenSaverReleaseStore = .init(),
         rtk: TokenSaverReleaseRTK = .init(),
         reapplyRules: @escaping () throws -> Void = {
             try TokenSaverSettingsStore.save(TokenSaverSettingsStore.load())
         }) {
        self.client = client
        self.store = store
        self.reapplyRules = reapplyRules
        self.rtk = rtk
        for tool in TokenSaverReleaseTool.allCases {
            var status = Status()
            if tool == .rtk { status.brewAvailable = rtk.brewURL != nil }
            do { status.staged = try store.staged(tool) }
            catch { status.error = error.localizedDescription }
            statuses[tool] = status
        }
    }

    func check(_ tool: TokenSaverReleaseTool) async {
        guard statuses[tool]?.isBusy != true else { return }
        statuses[tool, default: Status()].isBusy = true
        statuses[tool]?.error = nil
        statuses[tool]?.notice = nil
        // A failed refresh must not leave an old release eligible for installation.
        statuses[tool]?.latest = nil
        statuses[tool]?.checkedAt = nil
        defer { statuses[tool]?.isBusy = false }
        do {
            statuses[tool]?.staged = nil
            statuses[tool]?.staged = try store.staged(tool)
            if tool == .rtk {
                statuses[tool]?.installedBinaryVersion = nil
                statuses[tool]?.binaryInspected = false
                do {
                    statuses[tool]?.installedBinaryVersion = try await rtk.installedVersion()
                    statuses[tool]?.binaryInspected = true
                } catch { statuses[tool]?.error = error.localizedDescription }
            }
            statuses[tool]?.latest = try await client.latest(for: tool)
            statuses[tool]?.checkedAt = Date()
        } catch { statuses[tool]?.error = error.localizedDescription }
    }

    func updateRTK() async {
        let tool = TokenSaverReleaseTool.rtk
        guard statuses[tool]?.isBusy != true, statuses[tool]?.installedBinaryVersion != nil else { return }
        statuses[tool]?.isBusy = true
        statuses[tool]?.error = nil
        statuses[tool]?.notice = nil
        defer { statuses[tool]?.isBusy = false }
        do {
            statuses[tool]?.installedBinaryVersion = try await rtk.upgrade()
            statuses[tool]?.binaryInspected = true
            statuses[tool]?.notice = "Homebrew RTK upgrade finished. Installed Homebrew version is separate from the latest GitHub release."
        } catch {
            statuses[tool]?.installedBinaryVersion = nil
            statuses[tool]?.binaryInspected = false
            statuses[tool]?.error = error.localizedDescription
        }
    }

    func stage(_ tool: TokenSaverReleaseTool) async {
        guard statuses[tool]?.isBusy != true, let release = statuses[tool]?.latest,
              tool.skillPath != nil else { return }
        statuses[tool]?.isBusy = true
        statuses[tool]?.error = nil
        statuses[tool]?.notice = nil
        defer { statuses[tool]?.isBusy = false }
        do {
            let markdown = try await client.skill(for: release)
            statuses[tool]?.staged = try store.stage(release, markdown: markdown)
            do {
                try reapplyRules()
                statuses[tool]?.notice = "Rules saved; enabled tools reapplied. New coding session reload required. Disabled tools remain staged only."
            } catch {
                statuses[tool]?.error = "Downloaded/staged rules, but not applied: \(error.localizedDescription)"
                statuses[tool]?.notice = nil
            }
        } catch { statuses[tool]?.error = error.localizedDescription }
    }
}

