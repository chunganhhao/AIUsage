#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-anti-ban-phase3.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
BUILD_ARGS=(--package-path "$ROOT/QuotaBackend")
if [[ -n "${AIUSAGE_SWIFTPM_SCRATCH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$AIUSAGE_SWIFTPM_SCRATCH")
fi
swift build "${BUILD_ARGS[@]}" --target QuotaBackend >/dev/null
BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 \
  "$ROOT/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT/AIUsage/Models/CLIProxyUpstreamCapability.swift" \
  "$ROOT/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT/scripts/AntiBanPhase3Regression.swift" -o "$TEMP/regression"
mkdir -p "$TEMP/fixtures"
AIUSAGE_TEST_FIXTURE_ROOT="$TEMP/fixtures" "$TEMP/regression" "$TEMP/fixtures"
