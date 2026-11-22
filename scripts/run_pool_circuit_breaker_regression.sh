#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-pool-breaker.XXXXXX")"
trap 'rm -rf "$TEMP_DIR"' EXIT
swift build --package-path "$PROJECT_DIR/QuotaBackend" --build-system native --target QuotaBackend >/dev/null
BACKEND_BIN="$(swift build --package-path "$PROJECT_DIR/QuotaBackend" --build-system native --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BACKEND_BIN/description.json" > "$TEMP_DIR/objects.txt"
swiftc -parse-as-library -swift-version 5 -I "$BACKEND_BIN/Modules" \
  -Xlinker -filelist -Xlinker "$TEMP_DIR/objects.txt" -lsqlite3 \
  "$PROJECT_DIR/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift" \
  "$PROJECT_DIR/scripts/PoolCircuitBreakerRegression.swift" -o "$TEMP_DIR/regression"
"$TEMP_DIR/regression" "$TEMP_DIR"
if [[ -n "${AIUSAGE_CPA_TEST_BINARY:-}" ]]; then
  python3 "$PROJECT_DIR/scripts/pool_circuit_breaker_cpa_proof.py" "$AIUSAGE_CPA_TEST_BINARY" "$TEMP_DIR"
fi
