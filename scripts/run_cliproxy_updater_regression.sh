#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cliproxy-updater-regression.XXXXXX")"

cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

swift build --package-path "$ROOT_DIR/QuotaBackend" --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --package-path "$ROOT_DIR/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BACKEND_BIN/description.json" > "$WORK_DIR/backend-objects.txt"
swiftc -parse-as-library -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$WORK_DIR/backend-objects.txt" -lsqlite3 \
  "$ROOT_DIR/AIUsage/Models/CLIProxyGatewayModels.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyPaths.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyConfigStore.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyGeminiCredentialBridge.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyCredentialAdapter.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyManagementClient.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyReleaseClient.swift" \
  "$ROOT_DIR/AIUsage/Services/CLIProxyBinaryStore.swift" \
  "$ROOT_DIR/scripts/CLIProxyUpdaterRegression.swift" \
  -o "$WORK_DIR/cliproxy-updater-regression"

"$WORK_DIR/cliproxy-updater-regression" "$@"
