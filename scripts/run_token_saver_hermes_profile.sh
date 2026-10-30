#!/usr/bin/env bash
# Explicit offline export to token-saver-test only. No profile creation or inference.
set -euo pipefail
if [[ $# != 2 || "$1" != "--home" || "$2" != /* ]]; then
  printf 'Usage: %s --home /absolute/home\n' "$0" >&2
  exit 64
fi
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-hermes-export.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
cat > "$TEMP/export.swift" <<'SWIFT'
import Foundation
import QuotaBackend
@main struct Export {
    static func main() throws {
        let target = try TokenSaverSettingsStore.exportHermesTestProfile(home: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        print(target.path)
    }
}
SWIFT
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$TEMP/export.swift" -o "$TEMP/export"
"$TEMP/export" "$2"
