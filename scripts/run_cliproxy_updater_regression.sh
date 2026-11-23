#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cliproxy-updater-regression.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

BUILD_ARGS=(--package-path "$ROOT_DIR/QuotaBackend")
if [[ -n "${AIUSAGE_SWIFTPM_SCRATCH:-}" ]]; then
  BUILD_ARGS+=(--scratch-path "$AIUSAGE_SWIFTPM_SCRATCH")
fi
swift build "${BUILD_ARGS[@]}" --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BACKEND_BIN/description.json" > "$WORK_DIR/backend-objects.txt"
swiftc -parse-as-library -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$WORK_DIR/backend-objects.txt" -lsqlite3 \
  "$ROOT_DIR/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT_DIR/AIUsage/Models/CLIProxyUpstreamCapability.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyGeminiCredentialBridge.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyCredentialAdapter.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyManagementClient.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyReleaseClient.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyBinaryStore.swift" \
  "$ROOT_DIR/scripts/CLIProxyUpdaterRegression.swift" \
  -o "$WORK_DIR/cliproxy-updater-regression"

mkdir -p "$WORK_DIR/fixtures"
AIUSAGE_TEST_FIXTURE_ROOT="$WORK_DIR/fixtures" "$WORK_DIR/cliproxy-updater-regression" "$WORK_DIR/fixtures" "$@"
