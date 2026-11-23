#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-tc.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
BUILD_ARGS=(--package-path "$ROOT/QuotaBackend")
if [[ -n "${AIUSAGE_SWIFTPM_SCRATCH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$AIUSAGE_SWIFTPM_SCRATCH")
fi
swift build "${BUILD_ARGS[@]}" --target QuotaBackend >/dev/null
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
source = (root/'AIUsage/Views/TokenSaverSettingsView.swift').read_text()
controller = source.split('/// Agent-side instructions only. No request middleware or runtime changes.\n', 1)[1].split('\n// MARK: - Token Saver updates section', 1)[0]
(temp/'Controller.swift').write_text('import Foundation\nimport Combine\nimport QuotaBackend\n'+controller)
PY
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$TEMP/Controller.swift" "$ROOT/scripts/TokenSaverControllerRegression.swift" -o "$TEMP/regression"
mkdir -p "$TEMP/fx"
AIUSAGE_TEST_FIXTURE_ROOT="$TEMP/fx" "$TEMP/regression" "$TEMP/fx"
