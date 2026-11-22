#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-safe-switch.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys
root,temp=map(Path,sys.argv[1:])
s=(root/'AIUsage/ViewModels/ProviderActivationManager.swift').read_text()
coord=(root/'AIUsage/ViewModels/ProviderRefreshCoordinator.swift').read_text()
pipeline=(root/'AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift').read_text()
def function(marker, src=s):
    start=src.index(marker); brace=src.index('{',start); depth=1; i=brace+1
    while depth:
        if src[i]=='{': depth+=1
        elif src[i]=='}': depth-=1
        i+=1
    return src[start:i]
t=(root/'scripts/SafeSwitchRegression.swift').read_text()
row=(root/'AIUsage/Views/CodexProxyManagementView.swift').read_text()
start=row.index('                Toggle("", isOn: Binding(')
end=row.index('                .labelsHidden()',start)
binding=row[start:end].strip().removeprefix('Toggle("", isOn: ').removesuffix(')')
t=t.replace('// PRODUCTION_BINDING',binding)
start=row.index('    private func performAccountActivation(')
line=row[:start].splitlines()[-1] if row[:start].splitlines() else ''
assert '@ViewBuilder' not in line, 'side-effect activation helper must not be a ViewBuilder'
brace=row.index('{',start);depth=1;i=brace+1
while depth:
    if row[i]=='{': depth+=1
    elif row[i]=='}': depth-=1
    i+=1
t=t.replace('// PRODUCTION_ROW_ACTIVATION',row[start:i])

for key,marker in [
    ('ACTIVATE','    @MainActor\n    @discardableResult\n    func activateAccount('),
    ('CODEX_RESTART','    @MainActor\n    func restartCodexApp('),
    ('AGY_RESTART','    @MainActor\n    func restartAntigravityApp('),
    ('AGY_ACTIVATE','    @MainActor\n    func activateAntigravityAccount('),
    ('AGY_REAPPLY','    func reapplyAntigravityAccountForRestart('),
]:
    code=function(marker)
    # Auth/app seams only. Keep production flow and detached/main-actor placement unchanged.
    code=code.replace('AntigravityAccountSwitcher.', 'FakeAGYSwitcher.')
    code=code.replace('NSRunningApplication.', 'FixtureRunningApplication.').replace('NSWorkspace.', 'FixtureWorkspace.').replace('NSAlert()', 'FixtureAlert()')
    t=t.replace('// PRODUCTION_'+key,code)
assert 'timeoutSeconds: TimeInterval = 20.0' in s, 'restartCodexApp default quit timeout must stay at 20.0s'
keyring_helpers='\n'.join([
    '    nonisolated static let codexBundleIdentifier = "com.openai.codex"',
    function('    static func codexUsesKeyring('),
    function('    static func codexConfigUsesKeyring('),
    function('    nonisolated static func readBundleIdentifier('),
    function('    nonisolated static func isVerifiedCodexBundleURL('),
    function('    static func verifiedCodexAppBundlePaths('),
    function('    static func resolveInstalledCodexAppURL('),
    function('    nonisolated static func extractCodexPIDs('),
    function('    nonisolated static func isBundledCodexExecutablePath('),
    function('    nonisolated static func isBundledCodexAppCommandLine('),
    function('    nonisolated static func hasExternalCodexCommandLines('),
])
t=t.replace('// PRODUCTION_CODEX_KEYRING',keyring_helpers)
codex_write_boundary=function('    static func validateNativeCodexWriteTargets(')+'\n'+function('    func writeAuthFileWithBackup(')
t=t.replace('// PRODUCTION_CODEX_WRITE_BOUNDARY',codex_write_boundary)
coord_flow='\n'.join([
    function('    func refreshAllProviders(', coord),
    function('    func stabilizedBulkRefreshProviders(\n        _ incomingProviders:', pipeline),
    function('    func stabilizedBulkRefreshProviders(\n        for providerId:', pipeline),
    function('    func preferredBulkRefreshProvider(', pipeline),
    function('    func deduplicatedProvidersByID(', pipeline),
])
t=t.replace('// PRODUCTION_COORDINATOR_FLOW',coord_flow)
(temp/'Regression.swift').write_text(t)
PY
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" \
  "$ROOT/AIUsage/Services/AntigravityAccountSwitcher.swift" "$TEMP/Regression.swift" -o "$TEMP/regression"
"$TEMP/regression"
