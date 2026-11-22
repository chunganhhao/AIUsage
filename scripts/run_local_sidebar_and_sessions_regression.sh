#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REGRESSION_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-local-sessions.XXXXXX")"
trap 'rm -rf "$REGRESSION_DIR"' EXIT

swift build --package-path "$PROJECT_DIR/QuotaBackend" --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --package-path "$PROJECT_DIR/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' \
  "$BACKEND_BIN/description.json" > "$REGRESSION_DIR/backend-objects.txt"

swiftc -parse-as-library -swift-version 5 \
  -I "$BACKEND_BIN/Modules" -Xlinker -filelist -Xlinker "$REGRESSION_DIR/backend-objects.txt" -lsqlite3 \
  "$PROJECT_DIR/scripts/LocalSidebarAndSessionsRegression.swift" \
  -o "$REGRESSION_DIR/local-sessions-regression"

"$REGRESSION_DIR/local-sessions-regression"
