#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/artifacts/restart-ui-review-2026-11-08"
python3 "$HERE/build_probe.py"
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/restart-token-probe.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" "$HERE/StaleRestartTokenProbe.swift" -o "$TEMP/probe"
"$TEMP/probe"
