#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-local-sidebar-review.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root/'AIUsage/Views/SubscriptionGatewaySettingsRuntimePane.swift').read_text()
controller = source.split('/// Agent-side instructions only. No request middleware or CPA runtime changes.\n', 1)[1]
(temp/'Controller.swift').write_text('import Foundation\nimport Combine\nimport QuotaBackend\n'+controller)

codex_view = (root/'AIUsage/Views/CodexLocalManagementView.swift').read_text()
agy_view = (root/'AIUsage/Views/AntigravityManagementView.swift').read_text()
reader_view = (root/'AIUsage/Views/SessionReaderView.swift').read_text()

for name, text, prefix in [
    ('CodexLocalManagementView.swift', codex_view, 'codex-token-saver'),
    ('AntigravityManagementView.swift', agy_view, 'agy-token-saver'),
]:
    assert 'tokenSaver.reapply()' in text and 'tokenSaver.mutate' in text, name
    assert 'tokenSaver.localizedError' in text, f'{name} missing tokenSaver.localizedError'
    assert 'tokenSaver.notice' in text, f'{name} missing tokenSaver.notice'
    assert 'tokenSaver.lastSaveSucceeded' in text, f'{name} missing tokenSaver.lastSaveSucceeded'
    assert f'"{prefix}-error"' in text, f'{name} missing {prefix}-error accessibility id'
    assert f'"{prefix}-notice"' in text, f'{name} missing {prefix}-notice accessibility id'
    assert f'"{prefix}-saved-badge"' in text, f'{name} missing {prefix}-saved-badge id'

assert '.defaultScrollAnchor(focus == nil ? .bottom : .top)' in reader_view, 'SessionReaderView missing bottom defaultScrollAnchor'
assert '.task(id: session.id)' in reader_view and 'proxy.scrollTo(Self.bottomID, anchor: .bottom)' in reader_view, 'SessionReaderView missing initial bottom scroll task'

center_view = (root/'AIUsage/Views/SessionCenterView.swift').read_text()
store_source = (root/'AIUsage/ViewModels/SessionCenterStore.swift').read_text()
assert 'if session.tool != .antigravity,' in store_source, 'SessionCenterStore should skip active-session modal warning for .antigravity'
assert 'func openInDesktopApp(_ session: SessionSummary)' in store_source and 'func desktopAppInfo(for tool: SessionTool) -> (name: String, url: URL?)' in store_source, 'SessionCenterStore missing openInDesktopApp / desktopAppInfo'
for app_label in ['"Claude.app"', '"Codex.app"', '"OpenCode.app"', '"Antigravity.app"']:
    assert app_label in store_source, f'SessionCenterStore missing desktopAppInfo entry for {app_label}'
assert 'ProviderActivationManager.resolveInstalledCodexAppURL' in store_source, 'SessionCenterStore should resolve Codex.app via ProviderActivationManager.resolveInstalledCodexAppURL'
assert 'store.openInDesktopApp(session)' in center_view and 'handleOpenInDesktopApp' in reader_view, 'SessionReaderView / SessionCenterView missing Open in <App> menu item'
assert 'SessionDropdownMenuAnchor' in reader_view and '.frame(width: 28, height: 28)' in reader_view, 'SessionResumeButton missing 28x28 square dropdown button + SessionDropdownMenuAnchor'
assert 'session.tool == .antigravity ? "macwindow" : "terminal"' not in reader_view, 'SessionResumeButton primary segment should be unified as Resume in <Terminal>'

for forbidden_codex in [
    'envSummary.model ?? L("Default", "默认")',
    '(envSummary.reasoningEffort ?? "medium").uppercased()',
    'envSummary.sandboxMode ?? "workspace-write"',
    'envSummary.approvalPolicy ?? "on-request"',
]:
    assert forbidden_codex not in codex_view, f'CodexLocalManagementView must not coerce nil runtime state via {forbidden_codex}'

for required_codex in [
    'envSummary.model ?? "—"',
    'envSummary.reasoningEffort?.uppercased() ?? "—"',
    'envSummary.sandboxMode ?? "—"',
    'envSummary.approvalPolicy ?? "—"',
    'normalizeWorkspacePath(',
]:
    assert required_codex in codex_view, f'CodexLocalManagementView missing {required_codex}'

for tag_label in ['"Model"', '"Thinking"', '"Execution"', '"Artifact Review"', '"Security"', '"Workspaces"']:
    assert tag_label in agy_view, f'AntigravityManagementView missing runtime metricTag {tag_label}'

for forbidden in [
    'envSummary.thinkingEffort ?? "MEDIUM"',
    'envSummary.executionPolicy ?? "always-proceed"',
    'envSummary.artifactReviewPolicy ?? "always-proceed"',
    'envSummary.securityMode ?? "standard"',
]:
    assert forbidden not in agy_view, f'AntigravityManagementView must not coerce nil runtime state via {forbidden}'

for required in [
    'envSummary.activeModel ?? "—"',
    'envSummary.thinkingEffort?.uppercased() ?? "—"',
    'envSummary.executionPolicy ?? "—"',
    'envSummary.artifactReviewPolicy ?? "—"',
    'envSummary.securityMode ?? "—"',
]:
    assert required in agy_view, f'AntigravityManagementView missing nil-safe fallback {required}'

print('PASS: source audit confirms CodexLocalManagementView, AntigravityManagementView (including nil-safe 6 runtime tags), SessionCenterStore, SessionCenterView, and SessionReaderView wiring')

card_slice = codex_view.split('    // MARK: - Token Saver & Codex Customization Card\n', 1)[1].split('\n// MARK: - Inline AGENTS.md Rules Editor Sheet\n', 1)[0]
agy_pool_slice = agy_view.split('    // MARK: - Smart Pool Protection & TOS-Safe Mode Card\n', 1)[1].split('\n    // MARK: - Token Saver & AGY Customization Card\n', 1)[0]
agy_pool_slice = agy_pool_slice.replace(
    '    private func metricTag(icon: String, label: String, value: String, tint: Color) -> some View {\n        HStack(spacing: 5) {\n',
    '    private func metricTag(icon: String, label: String, value: String, tint: Color) -> some View {\n        RecordedAGYMetricTags.record(label: label, value: value)\n        return HStack(spacing: 5) {\n'
)
harness = f'''import SwiftUI
import QuotaBackend

enum RecordedAGYMetricTags {{
    static var values: [String: String] = [:]
    static func record(label: String, value: String) {{
        values[label] = value
    }}
}}

struct DummyEnvSummary {{
    var mcpServerCount = 2
    var skillCount = 5
    var isAppInstalled = true
    var appVersion: String? = "1.0"
    var isAppRunning = true
}}

struct DummyAGYEnvSummary {{
    var activeModel: String?
    var thinkingEffort: String?
    var executionPolicy: String?
    var artifactReviewPolicy: String?
    var securityMode: String?
    var workspaceCount: Int = 0
}}

enum AntigravityPoolProtectionSettings {{
    static func setEnabled(_ enabled: Bool) throws {{}}
    static func isEnabled() -> Bool {{ true }}
    static func hasResidualProtection() throws -> Bool {{ false }}
    static func restorePreviousExclusions() throws {{}}
}}

struct ExtractedCodexTokenSaverHarness: View {{
    private static let brand = Color.blue
    @ObservedObject var tokenSaver: TokenSaverSettingsController
    @Environment(\\.colorScheme) private var colorScheme
    let envSummary = DummyEnvSummary()
    func refreshEnvironment() {{}}
    var body: some View {{ tokenSaverCard }}
{card_slice}

struct ExtractedAGYPoolProtectionHarness: View {{
    private static let brand = Color.purple
    @Environment(\\.colorScheme) private var colorScheme
    let envSummary: DummyAGYEnvSummary
    @State private var poolProtectionEnabled = true
    @State private var poolProtectionResidual = false
    @State private var poolProtectionError: String?
    func reloadState() {{}}
    var body: some View {{ poolProtectionCard }}
{agy_pool_slice}
}}
'''
(temp/'ExtractedCard.swift').write_text(harness)
PY
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$TEMP/Controller.swift" "$TEMP/ExtractedCard.swift" "$ROOT/artifacts/local-sidebar-review-2026-11-08/TokenSaverSilentErrorProbe.swift" -o "$TEMP/probe"
"$TEMP/probe"
