#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-anti-ban-phase3.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 \
  "$ROOT/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT/AIUsage/Models/CLIProxyUpstreamCapability.swift" \
  "$ROOT/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT/scripts/AntiBanPhase3Regression.swift" -o "$TEMP/regression"
"$TEMP/regression"
