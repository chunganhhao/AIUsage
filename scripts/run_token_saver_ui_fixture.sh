#!/usr/bin/env bash
# Compile/render real Token Saver UI components with isolated stubs, never production AIUsage.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE="${TOKEN_SAVER_FIXTURE_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/aiusage-token-ui.XXXXXX")}"
mkdir -p "$FIXTURE"
FIXTURE="$(cd "$FIXTURE" && pwd -P)"
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
python3 - "$ROOT" "$FIXTURE" <<'PYCODE'
from pathlib import Path
import sys
root, fixture = map(Path, sys.argv[1:])

settings_src = (root/'AIUsage/Views/SettingsView.swift').read_text()
categories = settings_src.split('enum SettingsCategory', 1)[1].split('// MARK: - Settings View', 1)[0]
categories = 'enum SettingsCategory' + categories
consume_fn = '    func consumeRequestedSettingsCategory()' + settings_src.split('    func consumeRequestedSettingsCategory()', 1)[1].split('\n    func updateDockIconVisibility', 1)[0]

mb = (root/'AIUsage/Views/MenuBarView.swift').read_text()
open_fn = '    func openTokenSaverSettings()' + mb.split('    private func openTokenSaverSettings()', 1)[1].split('\n    private func openMainWindow', 1)[0]
mb_section = mb.split('// MARK: - Token Saver Menu Bar Quick Controls', 1)[1].split('// MARK: - Overall Health Status', 1)[0]

routing_harness = f'''import SwiftUI

enum AppSection {{ case settings }}

@MainActor final class ProductionAppStateRoutingStub {{
    var requestedSettingsCategory: SettingsCategory?
    var presentedSection: AppSection?
    func presentMainWindow(section: AppSection) {{ presentedSection = section }}
}}

@MainActor final class ProductionMenuBarRouting {{
    let appState: ProductionAppStateRoutingStub
    var revealedSection: AppSection? {{ appState.presentedSection }}
    init(appState: ProductionAppStateRoutingStub) {{ self.appState = appState }}
    private func openMainWindow(section: AppSection) {{ appState.presentMainWindow(section: section) }}
{open_fn}
}}

@MainActor final class ProductionSettingsRouting {{
    let appState: ProductionAppStateRoutingStub
    var selectedCategory: SettingsCategory = .general
    init(appState: ProductionAppStateRoutingStub) {{ self.appState = appState }}
{consume_fn}
}}
'''
(fixture/'Routing.swift').write_text(categories + '\n' + routing_harness)
(fixture/'MenuBarTokenSaver.swift').write_text('import SwiftUI\nimport Combine\nimport QuotaBackend\n' + mb_section)
PYCODE

jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$FIXTURE/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$FIXTURE/objects.txt" -lsqlite3 \
  "$ROOT/AIUsage/Views/AppSurfaceTokens.swift" \
  "$ROOT/AIUsage/Views/GatewayChrome.swift" \
  "$ROOT/AIUsage/Views/AgentToolsView.swift" \
  "$ROOT/AIUsage/Views/PoolProtectionControls.swift" \
  "$ROOT/AIUsage/Views/TokenSaverSettingsView.swift" \
  "$ROOT/AIUsage/Services/TokenSaverReleaseManager.swift" \
  "$FIXTURE/Routing.swift" \
  "$FIXTURE/MenuBarTokenSaver.swift" \
  "$ROOT/scripts/token_saver_ui_stubs.swift" \
  -o "$FIXTURE/TokenSaverUIFixture"

mkdir -p "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS"
cp "$FIXTURE/TokenSaverUIFixture" "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS/TokenSaverUIFixture"
cat > "$FIXTURE/TokenSaverUIFixture.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>local.aiusage.token-saver-fixture</string><key>CFBundleName</key><string>TokenSaverUIFixture</string><key>CFBundleExecutable</key><string>TokenSaverUIFixture</string><key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><false/></dict></plist>
PLIST
python3 - "$FIXTURE" <<'PYCODE'
from pathlib import Path
import hashlib,plistlib,sys
root=Path(sys.argv[1]);p=root/'TokenSaverUIFixture.app/Contents/Info.plist'
data=plistlib.loads(p.read_bytes())
data['CFBundleIdentifier']='local.aiusage.token-saver-fixture.'+hashlib.sha256(str(root).encode()).hexdigest()[:12]
p.write_bytes(plistlib.dumps(data))
PYCODE
printf 'Fixture path: %s\n' "$FIXTURE"
if [[ "${1:-}" == "--run" ]]; then
  TOKEN_SAVER_FIXTURE_HOME="$FIXTURE" "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS/TokenSaverUIFixture"
else
  TOKEN_SAVER_FIXTURE_HOME="$FIXTURE/verify-home" "$FIXTURE/TokenSaverUIFixture.app/Contents/MacOS/TokenSaverUIFixture" --verify-ui
fi
