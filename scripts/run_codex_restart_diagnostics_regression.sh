#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="${CODEX_RESTART_FIXTURE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aiusage-restart-diagnostics.XXXXXX")}"
mkdir -p "$TEMP"
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys,plistlib
root,temp=map(Path,sys.argv[1:])
def function(path, marker):
    s=(root/path).read_text(); start=s.index(marker); brace=s.index('{',start); depth=1; i=brace+1
    while depth:
        if s[i]=='{': depth+=1
        elif s[i]=='}': depth-=1
        i+=1
    return s[start:i].replace('private func','func',1)
flow=function('AIUsage/ViewModels/ProviderActivationManager.swift','    @MainActor\n    func restartCodexApp(')
local=function('AIUsage/Views/CodexLocalManagementView.swift','    private func restartCodex()')
menu=function('AIUsage/Views/MenuBarView.swift','    private func confirmAndRestartApp(')
banner='    @ViewBuilder\n'+function('AIUsage/Views/CodexLocalManagementView.swift','    private func statusBanner(')
s=(root/'scripts/CodexRestartDiagnosticsRegression.swift').read_text()
for key,code in [('FLOW',flow),('LOCAL',local),('MENU',menu),('BANNER',banner)]:
    assert s.count('// PRODUCTION_'+key)==1
    s=s.replace('// PRODUCTION_'+key,code)
(temp/'Regression.swift').write_text(s)
app=temp/'CodexRestartDiagnosticsFixture.app/Contents';(app/'MacOS').mkdir(parents=True,exist_ok=True)
(app/'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'local.aiusage.restart-diagnostics-fixture','CFBundleName':'CodexRestartDiagnosticsFixture','CFBundleExecutable':'fixture','CFBundlePackageType':'APPL'}))
print('Fixture:',temp/'CodexRestartDiagnosticsFixture.app')
PY
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" \
  "$TEMP/Regression.swift" -o "$TEMP/CodexRestartDiagnosticsFixture.app/Contents/MacOS/fixture"
"$TEMP/CodexRestartDiagnosticsFixture.app/Contents/MacOS/fixture" --verify "$TEMP"
