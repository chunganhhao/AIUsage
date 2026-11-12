#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-codex-switch-loss.XXXXXX")"
trap 'rm -rf "$TEMP"' EXIT

python3 - "$ROOT" "$TEMP/GeneratedActivationSlice.swift" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
out_file = Path(sys.argv[2])
src = (root / "AIUsage/ViewModels/ProviderActivationManager.swift").read_text()

def function_slice(signature: str) -> str:
    start = src.index(signature)
    opening = src.index("{", start)
    depth = 1
    pos = opening + 1
    while depth:
        depth += (src[pos] == "{") - (src[pos] == "}")
        pos += 1
    return src[start:pos]

start = src.index("            let sourceData = try Data(contentsOf: selected.authFileURL)", src.index("func reapplyCodexAccountForRestart"))
end = src.index("            let genAfter", start)
reapply_slice = src[start:end].replace('NSString(string: "~/.codex").expandingTildeInPath', "testCodexDir")

act_start = src.index("        let reconciled = CodexCredentialPolicy.reconcileSameIdentityAuthData(", src.index("func activateCodexAccount"))
act_end = src.index("        codexSwitchGeneration &+= 1", act_start)
act_slice = (
    src[act_start:act_end]
    .replace("let effectiveIdentity = reconciled.identity", "_ = reconciled.identity")
    .replace('let isCodexRunning = NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex")\n            .contains { !$0.isTerminated }', "let isCodexRunning = false")
    .replace("let syncOutcome = CodexGlobalStateSync.syncWorkspaceProjects(", "_ = CodexGlobalStateSync.syncWorkspaceProjects(")
)

helpers = function_slice("    private func convertToCodexNativeFormat") + "\n" + function_slice("    private func writeAuthFileWithBackup")

generated = """import Foundation
import QuotaBackend

extension Notification.Name {
    static let codexSubscriptionAccountActivating = Notification.Name("codexSubscriptionAccountActivating")
}

struct ActivationSettings {
    func t(_ en: String, _ zh: String) -> String { en }
}

enum ActivationStateResult {
    case failure(String)
}

final class CodexConfigManager {
    static let shared = CodexConfigManager()
    func restore() throws {}
}

struct ActivationTarget {
    let authFileURL: URL
    let expectedIdentity: CodexAccountIdentity
}

final class ActivationHarness {
    let settings = ActivationSettings()
    var activationResult: ActivationStateResult?
    var codexActivationResult: ActivationStateResult?
    let codexSwitchGeneration: UInt64 = 0
    func allKnownCodexOwnerHashes(excluding: String?) -> Set<String> { [] }

    func activateSlice(selected: ActivationTarget, testCodexDir: String) throws {
        let fm = FileManager.default
        let resolved = selected.authFileURL.path
        let codexDir = testCodexDir
        let targetPath = "\\(codexDir)/auth.json"
        let sourceData = try Data(contentsOf: selected.authFileURL)
        let nativeData = try convertToCodexNativeFormat(sourceData)
        let expectedIdentity = selected.expectedIdentity
""" + act_slice + """
    }

    func reapplySlice(selected: ActivationTarget, testCodexDir: String) async throws {
        let fm = FileManager.default
        let genBefore: UInt64 = 0
        for _ in 0..<1 {
""" + reapply_slice + """
        }
    }

""" + helpers + """
}
"""
out_file.write_text(generated)
PY

swift build --package-path "$ROOT/QuotaBackend" --target QuotaBackend >/dev/null
BIN="$(swift build --package-path "$ROOT/QuotaBackend" --show-bin-path)"
jq -r '.swiftCommands[] | select(.moduleName == "QuotaBackend") | .objects[]' "$BIN/description.json" > "$TEMP/objects.txt"

swiftc -parse-as-library -swift-version 5 \
  -I "$BIN/Modules" -Xlinker -filelist -Xlinker "$TEMP/objects.txt" -lsqlite3 \
  "$ROOT/AIUsage/Models/ProviderModels.swift" \
  "$ROOT/AIUsage/Models/AccountStore.swift" \
  "$ROOT/AIUsage/Models/AccountStore+Persistence.swift" \
  "$ROOT/AIUsage/Models/AccountStore+Matching.swift" \
  "$ROOT/AIUsage/Services/ProviderAuth/ProviderAuthTypes.swift" \
  "$ROOT/AIUsage/Services/ProviderAuth/ProviderAuthParsing.swift" \
  "$ROOT/AIUsage/Services/ProviderAuth/LoginPhase.swift" \
  "$ROOT/AIUsage/Services/ProviderAuth/AntigravityLoginCoordinator.swift" \
  "$ROOT/AIUsage/Services/AntigravityAccountSwitcher.swift" \
  "$ROOT/scripts/AccountIdentityRegressionSupport.swift" \
  "$ROOT/QuotaBackend/Tests/QuotaBackendTests/Support/StubURLProtocol.swift" \
  "$TEMP/GeneratedActivationSlice.swift" \
  "$ROOT/scripts/CodexSwitchTokenLossRegression.swift" \
  -o "$TEMP/codex-switch-token-loss-regression"

"$TEMP/codex-switch-token-loss-regression"
