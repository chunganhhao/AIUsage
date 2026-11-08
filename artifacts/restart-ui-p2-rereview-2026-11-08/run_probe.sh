#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HERE="$ROOT/artifacts/restart-ui-p2-rereview-2026-11-08"
swift build --package-path "$ROOT/QuotaBackend" >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/codex-conflict-probe.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" "$HERE/ConflictPolicyProbe.swift" -o "$TEMP/probe"
"$TEMP/probe" | tee "$HERE/probe-output.txt"
