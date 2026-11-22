#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-master.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys

root, temp = map(Path, sys.argv[1:])

def declaration(source, marker, indent="    "):
    start = source.index("\n" + indent + marker) + 1
    closing = "\n" + indent + "}"
    end = source.index(closing, start) + len(closing)
    return source[start:end]

settings = (root / "AIUsage/Models/AppSettings.swift").read_text()
visibility = (root / "AIUsage/Models/AgentVisibility.swift").read_text()
sync = (root / "AIUsage/ViewModels/ModelAutoSyncCoordinator.swift").read_text()
address = "\n".join(declaration(settings, marker) for marker in (
    "static func remoteBaseURL(", "static func resolveRemoteSettingsAddress(", "static func parseRemoteAddress(",
))
catalog = "\n".join(declaration(sync, marker) for marker in (
    "private func commitCatalogSync(", "private struct BaselineDecision",
    "private func baselineDecision(", "struct StateFile",
))
(temp / "AppRegressionFixture.swift").write_text(f"""
{visibility}

{declaration(settings, "enum AppSection:", indent="")}

enum AppSettingsAddressFixture {{
{address}
}}

final class CatalogSyncFixture {{
    private struct Target {{ let stateKey = "fixture" }}
    private struct FetchSpec {{ let upstreamIdentity = "fixture" }}
    private var state = StateFile()

    func sync(upstream: [String], existing: Set<String>, save: () -> Bool) -> [String] {{
        let target = Target()
        let decision = baselineDecision(
            for: target, spec: FetchSpec(), upstream: upstream, existing: existing, mergeAllOnFirstSync: false
        )
        _ = commitCatalogSync(decision.entry, for: target, save: save)
        return decision.newModels
    }}

{catalog}
}}
""")
PY
swiftc -parse-as-library -swift-version 5 -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 "$ROOT/scripts/MasterPlanRegression.swift" "$TEMP/AppRegressionFixture.swift" -o "$TEMP/regression"
"$TEMP/regression"
