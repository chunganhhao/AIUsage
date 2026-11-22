#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-anti-ban-polling.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT
swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"
swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 \
  "$ROOT/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift" \
  "$ROOT/scripts/AntiBanPollingRegression.swift" \
  -o "$TEMP/anti-ban-polling-regression"
"$TEMP/anti-ban-polling-regression"

python3 - "$ROOT" "$TEMP" <<'PY'
from pathlib import Path
import sys
root, temp = map(Path, sys.argv[1:])
def function(src, marker):
    s = src.index(marker); i = src.index('{', s); d = 1; j = i + 1
    while d:
        if src[j] == '{': d += 1
        elif src[j] == '}': d -= 1
        j += 1
    return src[s:j]
auth = (root / 'AIUsage/Services/ProviderAuthManager.swift').read_text()
discovery = (root / 'AIUsage/Services/ProviderAuth/ProviderAuthCandidateDiscovery.swift').read_text()
parsing = (root / 'AIUsage/Services/ProviderAuth/ProviderAuthParsing.swift').read_text()
pipe = (root / 'AIUsage/ViewModels/ProviderRefreshCoordinator+FetchPipeline.swift').read_text()
store = (root / 'AIUsage/Services/ProviderAuth/ProviderManagedImportStore.swift').read_text()
store = store.replace('import Foundation\nimport QuotaBackend\n', '')
boundary_fn = function(store, '    private static func boundary(')
store = store.replace(boundary_fn, """    static var managedBase: URL!
    private static func boundary(create: Bool) throws -> ManagedAuthImportBoundary {
        ManagedAuthImportBoundary(
            bundleIdentifier: ManagedAuthImportBoundary.productionBundleIdentifier,
            applicationSupportDirectory: managedBase
        )
    }""")
src = (root / 'scripts/DiscoveryAntiBanRegression.swift').read_text()
src = src.replace('// PRODUCTION_MANAGED_IMPORT_STORE', store)
src = src.replace('// PRODUCTION_AUTHENTICATE_CANDIDATE', function(auth, '    static func authenticateCandidate('))
src = src.replace('// PRODUCTION_NORMALIZED_AGY_WORKSPACE', function(discovery, '    static func normalizedAntigravityWorkspaceId('))
src = src.replace('// PRODUCTION_VALIDATE_LOCAL_METADATA', function(auth, '    private static func validateLocalAuthFileMetadata('))
src = src.replace('// PRODUCTION_VALIDATE', function(auth, '    private static func validate('))
src = src.replace('// PRODUCTION_COPY_IMPORTED_AUTH_FILE', function(auth, '    private static func copyImportedAuthFile('))
src = src.replace('// PRODUCTION_MANAGED_IMPORT_DIRECTORY', function(auth, '    private static func managedImportDirectory('))
src = src.replace('// PRODUCTION_SANITIZED_FILENAME_STEM', function(parsing, '    static func sanitizedFilenameStem('))
src = src.replace('// PRODUCTION_SYNC_UNIFIED', function(pipe, '    @MainActor\n    func syncUnifiedManagedAccounts('))
(temp / 'DiscoveryRegression.swift').write_text(src)
PY
swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 \
  "$ROOT/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift" \
  "$TEMP/DiscoveryRegression.swift" \
  -o "$TEMP/discovery-anti-ban-regression"
"$TEMP/discovery-anti-ban-regression"
