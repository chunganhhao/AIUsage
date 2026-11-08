# Hand-Off Brief for Codex Re-Review (Round 5) — `/ponytail-audit` Fixes (Items 1–3), 4-Tool `Open in <Tool>.app` Unification, `28x28` Full-Square Split Dropdown Button, & `codex://threads/<uuid>` Session Deep-Linking

- **Date**: 2026-11-09
- **Repository**: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`
- **Branch**: `feat/token-saver-integration` (base commit `b844c71c5cfa39ead39614294b6db5f745c23623`)
- **Installed Patched App**: `/Applications/AIUsage.app` (`Contents/MacOS/AIUsage` SHA-256: `e8928d5dda73a69a308956de28df7ee88acd5099164eea32f97301e16559a4e2`, `Contents/Helpers/QuotaServer` SHA-256: `b152bcd020bb80c5969f3d5605378d4298ef5f1071d0fc29a01ef222a61284f7`, staged copy in `dist/AIUsage.app`, running at `PID: 95560`)
- **Prior Codex Reviews**:
  - Round 1: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REVIEW_LOCAL_SIDEBAR_AND_SESSIONS_RESULT_2026-11-08.md` (`REQUEST CHANGES` — 1 P2 `F1`, remediated in Round 2)
  - Round 2: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REREVIEW_LOCAL_SIDEBAR_AND_SESSIONS_R2_2026-11-08.md` (`APPROVED`)
  - Round 3: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REREVIEW_LOCAL_SIDEBAR_AND_SESSIONS_R3_2026-11-08.md` (`REQUEST CHANGES` — 2 P2 findings, both remediated in Round 4)
  - Round 4: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REREVIEW_LOCAL_SIDEBAR_AND_SESSIONS_R4_2026-11-08.md` (`APPROVED` / `Verdict: Ship`)
- **Independent Gatekeeper Review (Round 5)**: Subagent `916c09b6-eca9-4a70-a42d-d90c119968f6` (`Role="Code Reviewer"`) audited all Round 5 changes against Engram and `git diff` and returned **`APPROVED`** (`0` P0/P1/P2 findings).
- **Executed Regression & Verification Suites (Round 5)**:
  - `bash artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh` -> **`exit 0`**:
    - `PASS: source audit confirms CodexLocalManagementView, AntigravityManagementView (including nil-safe 6 runtime tags), SessionCenterStore, SessionCenterView, and SessionReaderView wiring`
    - `PASS: production controller rejects toggle, exposes conflict error, rolls back settings, preserves edited rules`
    - `PASS: production controller reapply also exposes conflict error and renders extracted CodexLocalManagementView.tokenSaverCard`
    - `PASS: extracted AntigravityManagementView.poolProtectionCard renders '—' when runtime/policy inspection values are nil`
    - `PASS: extracted AntigravityManagementView.poolProtectionCard renders decoded values and keeps nil Thinking as '—'`
    - `PASS: SessionResumeButton 28x28 right square registers 5/5 corner+center clicks with 0 false left-segment hits`
    - `PASS: SessionResumePlan.desktopDeepLinkURL produces codex://threads/<uuid> for Codex and nil for non-deep-link tools`
  - `bash artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh` -> **`exit 0`** (`NORMAL offset=9123.0 max=9145.0`, `FOCUSED offset=502.0 max=9224.0`)
  - `bash scripts/run_local_sidebar_and_sessions_regression.sh` -> **`exit 0`** (`PASS: 29 Antigravity Session Center assertions`)
  - `bash scripts/run_account_identity_regression.sh` -> **`exit 0`** (`PASS: 203 account identity & OAuth assertions (production save/reconcile/hide/delete/OAuth, isolated storage)`)
  - `bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` -> **`exit 0`** (`PASS: 13 isolated managed-baseline assertions`)
  - `bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh` -> **`exit 0`** (`PASS: 11 isolated conflict-rejection & output-identity assertions`)
  - `bash artifacts/restart-ui-review-2026-11-08/run_probe.sh` -> **`exit 0`** (`PASS: 10 isolated assertions`)
  - `'/Users/apple/Library/Application Support/AIUsage/bin/token-saver-rtk' git diff --check` -> **`0 errors`**
  - `codesign --verify --deep --strict /Applications/AIUsage.app` -> **`exit 0`**

---

## 1. Round 5 Changes Summary (`/ponytail-audit` Items 1–3 + Session Center UX & Deep-Link Enhancements)

| Scope Item | User Request / Audit Finding | Exact Implementation & Code Locations | Verification Proof |
| :--- | :--- | :--- | :--- |
| **1. `/ponytail-audit` Item 1: `Local -> Codex` Workspace Path Normalization, `/Applications/ChatGPT.app` Detection, & Nil-Safe Runtime Tags** | 1. Normalize workspace paths before inserting into `workspacePaths: Set<String>` so paths with/without trailing slashes or `file://` prefixes are not double-counted.<br>2. Detect Codex Desktop installed at `/Applications/ChatGPT.app` (`CFBundleIdentifier == "com.openai.codex"`).<br>3. Render `"—"` when optional `model`, `reasoningEffort`, `sandboxMode`, or `approvalPolicy` in `~/.codex/config.toml` are `nil` (matching `Local -> Antigravity`). | • `AIUsage/Views/CodexLocalManagementView.swift:64–74`: Added `/Applications/ChatGPT.app` and `~/Applications/ChatGPT.app` to `appCandidates`, verifying `Bundle(url:)?.bundleIdentifier == "com.openai.codex"`.<br>• `AIUsage/Views/CodexLocalManagementView.swift:110–113, 141–145, 198–207`: Added `normalizeWorkspacePath(_:)` (`file://` decoding + `(path as NSString).standardizingPath`) for both `.codex-global-state.json` and `config.toml` `[projects."..."]`.<br>• `AIUsage/Views/CodexLocalManagementView.swift:716–744`: Replaced fabricated fallbacks (`"Default"`, `"MEDIUM"`, `"workspace-write"`, `"on-request"`) with `"—"` (and `.secondary` tint when `sandboxMode == nil`). | • `artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh:46–64`: Asserts absence of all 4 fabricated fallbacks and presence of `envSummary.model ?? "—"`, `envSummary.reasoningEffort?.uppercased() ?? "—"`, `envSummary.sandboxMode ?? "—"`, `envSummary.approvalPolicy ?? "—"`, and `normalizeWorkspacePath(`. |
| **2. `/ponytail-audit` Items 2 & 3: Zero Swift 6 Concurrency Warnings Across All 231 App Sources** | Eliminate all Swift 6 actor-isolation and Sendable capture warnings across `TLSCertificateManager.swift`, `CLIProxyGatewayManager.swift`, `APIProvider.swift`, `CopilotLoginCoordinator.swift`, `KiroLoginCoordinator.swift`, and `ProviderActivationManager.swift`. | • `AIUsage/Services/TLSCertificateManager.swift:25–26, 102, 130–131, 179–180, 273`: Marked `identityPassword`, `currentVersion`, `generateCACert`, `generateServerCert`, `exportPKCS12`, and `runOpenSSL` as `private nonisolated static`.<br>• `AIUsage/ViewModels/CLIProxyGatewayManager.swift:154` & `AIUsage/Models/APIProvider.swift:299–300`: Marked `managedProviderID` `nonisolated static let`.<br>• `AIUsage/Services/ProviderAuth/CopilotLoginCoordinator.swift:269` & `KiroLoginCoordinator.swift:318`: Marked `userAgent` `private nonisolated static let`.<br>• `AIUsage/ViewModels/ProviderActivationManager.swift:1098–1128`: Hop to `MainActor.run` inside `Task { [weak self] in ... }` before spawning `Task.detached` so `weak self` is never captured in a `@Sendable` detached closure. | • Full Release (`-O`) `swiftc` build across all 231 Swift files completes with **`0` concurrency/actor-isolation warnings** (`task-1154`). |
| **3. Unify `Open in <Tool>.app` Across All 4 Session Tools (`Claude.app`, `Codex.app`, `OpenCode.app`, `Antigravity.app`)** | Previously `Open in Codex.app` was hidden when Codex Desktop was installed at `/Applications/ChatGPT.app` (`com.openai.codex`), and `Claude` / `OpenCode` did not show `Open in <Tool>.app`. User requested `Open in <Tool>.app` across all 4 tools. | • `AIUsage/ViewModels/SessionCenterStore.swift:487–534`: `desktopAppInfo(for:)` returns non-optional `(name: String, url: URL?)` for all 4 tools (`.codex` -> `"Codex.app"` via `ProviderActivationManager.resolveInstalledCodexAppURL`, `.antigravity` -> `"Antigravity.app"`, `.claude` -> `"Claude.app"`, `.opencode` -> `"OpenCode.app"`).<br>• `AIUsage/Views/SessionReaderView.swift:901–908` & `AIUsage/Views/SessionCenterView.swift:426–430, 513–521`: Always displays `Open in \(app.name)` in both the split-button dropdown and context menu; if the desktop app is not installed, `openInDesktopApp(_:)` displays an explicit toast (`"<App> is not installed in /Applications."`). | • `artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh:38–42`: Verifies `desktopAppInfo(for:)` entries for all 4 tools and `ProviderActivationManager.resolveInstalledCodexAppURL` wiring. |
| **4. Upgrade `SessionResumeButton` Right-Hand Dropdown to a Full `28 x 28` Square Button (`SessionDropdownMenuAnchor`)** | Previously the right-hand segment of `SessionResumeButton` used SwiftUI `Menu` with `.menuStyle(.button)` + `.fixedSize()`, which shrunk the control to a `26 x 8` strip (`y: 10, height: 8`) with a `9 x 6` `_NSShapeHitTestingView` (only the chevron icon was clickable, causing missed clicks inside the right square). | • `AIUsage/Views/SessionReaderView.swift:875–1005`: Replaced the right-hand `Menu` with a full `28 x 28` `Button` styled with `SessionPrimarySegmentStyle()` (`Color.white.opacity(0.001)` background + `.contentShape(Rectangle())`) and backed by `SessionDropdownMenuAnchor` (`NSViewRepresentable` popping up a native `NSMenu` with `Open in <Tool>.app` + `Resume in` terminal choices anchored at `(0, -4)` below the `28 x 28` square). | • `artifacts/local-sidebar-review-2026-11-08/TokenSaverSilentErrorProbe.swift:101–195`: Dispatches synthetic `leftMouseDown`/`leftMouseUp` events at all 4 corners `(rightMinX + 2, 2)`, `(width - 2, 2)`, `(rightMinX + 2, 26)`, `(width - 2, 26)` and center `(rightMinX + 14, 14)` of the `28 x 28` right square -> **`5/5` right-square clicks, `0` false left-segment hits**. |
| **5. Direct Session Deep-Linking (`codex://threads/<uuid>`) for `Open in Codex.app`** | Previously `openInDesktopApp(_:)` only called `NSWorkspace.shared.open([folderURL], withApplicationAt: appURL)`, which opened the workspace folder without jumping to `session.sessionID`. | • Reverse-engineered `/Applications/ChatGPT.app/Contents/Resources/app.asar` (module `58973` / `startHandlingNativeUrls`): `Codex.app` (`com.openai.codex`) natively routes `codex://threads/<UUID>` to `{kind: "localConversation", conversationId: <UUID>}`.<br>• Reverse-engineered `/Applications/Antigravity.app` v2.29.0 (`main.js` `OJb` / `KJb` / `eMb`): `Antigravity.app`'s `antigravity://` handler currently hardcodes `void 0` for `cascadeId` (`c(void 0, {projectId: l})`) and only handles `/customizations`, `/teleport/ai_studio`, and `/open?prompt=...&project=...`.<br>• `QuotaBackend/Sources/QuotaBackend/Sessions/SessionResumePlan.swift:65–80`: Added `desktopDeepLinkURL` / `desktopDeepLinkURL(for:sessionID:)` returning `URL(string: "codex://threads/\(sessionID.lowercased())")` for `.codex` (after `isValidSessionID` UUID validation) and `nil` for `.claude`, `.opencode`, `.antigravity`.<br>• `AIUsage/ViewModels/SessionCenterStore.swift:557–577`: When `let deepLinkURL = plan.desktopDeepLinkURL` is present, dispatches `NSWorkspace.shared.open([deepLinkURL], withApplicationAt: appURL, configuration: configuration)` (`"Opened session in Codex.app"`), with fallback to `[folderURL]` and `openApplication(at: appURL)`. | • `QuotaBackend/Tests/QuotaBackendTests/SessionCatalogTests.swift:369–386` & `artifacts/local-sidebar-review-2026-11-08/TokenSaverSilentErrorProbe.swift:196–205`: Verifies uppercase UUID normalization (`019A0000-...` -> `codex://threads/019a0000-...`), invalid ID rejection (`not-a-uuid` -> `nil`), and `nil` return for `.claude`, `.opencode`, `.antigravity`. |

---

## 2. Scoped Files, Line Counts & SHA-256 Fingerprints (39 Files)

| File Path | Lines | SHA-256 | Role / Key Symbols |
| :--- | :---: | :--- | :--- |
| `AIUsage/AIUsageApp.swift` | `460` | `304a393375da192bf2aab2d5374d2a0a4a0cb88a46dbba1e93c46b287ab6fef8` | `@MainActor @objc func quit()` (`Line 456`) |
| `AIUsage/Models/APIProvider.swift` | `324` | `7ae0ff9392ddce1116fc3e6745e21a99e5634a150398b1e11c26e2267a9a984f` | `CLIProxyGatewayManager.managedProviderID` nonisolated access (`Lines 299–300`) |
| `AIUsage/Models/AgentVisibility.swift` | `109` | `24e2870ae94e6d5701f72338c941e22944690c471bfa3e744aee4162cd816dcd` | `isHidden(_:hidden:)` for `.codex` (`Lines 47–55`) |
| `AIUsage/Models/AppSettings.swift` | `500` | `e8eb64a998189a7f5398b913827fa867e04f75d5a864405b0f0e68f072d9af62` | `AppSection.codexLocalManagement`, `sidebarLocalGroupExpanded` (`Lines 12–28, 70, 294–296, 456–458`) |
| `AIUsage/Services/AntigravityAccountSwitcher.swift` | `2467` | `9e084769d5abd73539769dc5ec35bcbd50026ecc43cbb48bda73dc4d5bea0a2a` | `AntigravityEnvironmentSummary`, `inspectRuntimeAndWorkspaces`, `extractLatestModelAndEffort`, `parseModelSelection`, `parseAgentPreferencesProto` |
| `AIUsage/Services/GlobalProxyRuntime.swift` | `356` | `dfeec8b2e06c2974ce608d2b85de3282087df70d9c5ca6dd2122468c11ef2729` | Explicit `[Int]` annotations on `ports` & `requestedPorts` (`Lines 118, 141`) |
| `AIUsage/Services/ProviderAuth/CopilotLoginCoordinator.swift` | `351` | `96340229bfa4f6d2b37d63b9ba13d9603ded65f62c2bbf7832fafe30ef7ad09a` | `private nonisolated static let userAgent` (`Line 269`) |
| `AIUsage/Services/ProviderAuth/KiroLoginCoordinator.swift` | `539` | `9622e1110f77d55a8a405db1065458603f19f6e9751369474bce726397fe69e9` | `private nonisolated static let userAgent` (`Line 318`) |
| `AIUsage/Services/ProviderAuth/ProviderAuthCandidateDiscovery.swift` | `377` | `f01aebe6f5336bc94868e02a6923afa8d30ff021c6975de3d1b71e616c5d1ffa` | `@MainActor static func savedAPIKeyCandidates(for:)` (`Line 190`) |
| `AIUsage/Services/TLSCertificateManager.swift` | `305` | `83d087209f304db6c3eb0eb7d62501dda8b724928faf491f41cb3dbe5b0cc4a7` | `private nonisolated static` on certificate generation & `runOpenSSL` helpers (`Lines 25–26, 102, 130–131, 179–180, 273`) |
| `AIUsage/ViewModels/CLIProxyGatewayManager.swift` | `2868` | `f2f31c23c8404fe588f3a4b916775ee9132bb8834b39492fc640c4c5b96e6092` | `nonisolated static let managedProviderID` (`Line 154`) |
| `AIUsage/ViewModels/ProviderActivationManager.swift` | `1131` | `82750e71ca10c2a6fbf35b4a0061b66169d7d3e34a92890f95ad33b487e1935f` | `resolveInstalledCodexAppURL` & Sendable-safe `Task { [weak self] in ... }` in `refreshAntigravityDetectedEmail` (`Lines 1098–1128`) |
| `AIUsage/ViewModels/ProviderRefreshCoordinator.swift` | `501` | `e549317a8cd13430500889f965b278652e57850397779b5590ca743579765785` | `language: settings.language` in `insertImmediateProviderData` (`Line 338`) |
| `AIUsage/ViewModels/SessionCenterStore.swift` | `745` | `92e60fedbedfb4f2b4c777511056f462fd405225d4f03bb5178ee8b8b93ebe54` | 4-tool `desktopAppInfo(for:)`, `resolveDesktopAppURL`, and `openInDesktopApp(_:)` with `plan.desktopDeepLinkURL` dispatch + fallback (`Lines 487–577`) |
| `AIUsage/Views/AntigravityManagementView.swift` | `1462` | `98224ed31cbf37749914718bef7a663879693c3c00133ac89598532e88933e61` | 6 nil-safe runtime `metricTag` pills in `poolProtectionCard` (`Lines 568–643`) & `tokenSaverCard` error/notice/saved badge (`Lines 700–800`) |
| `AIUsage/Views/CodexLocalManagementView.swift` | `1043` | `3788232f99d89567445107de73c24a5e6c344681bb0cbfcb4912f83ea6f2a9ab` | `normalizeWorkspacePath(_:)`, `/Applications/ChatGPT.app` detection, and nil-safe `"—"` runtime tags (`Lines 64–74, 110–145, 198–207, 716–744`) |
| `AIUsage/Views/CodexProxyManagementView.swift` | `647` | `a1c11c2ceacb7de340d1798b5e9716a5e2fae1af806f6fe25b6b088d9402a313` | `CodexSubscriptionSection` (`onAddAccount`, `onAccountSwitched`, `emptyAccountList`, `Refresh Quota`, `Remove Account`) |
| `AIUsage/Views/ContentView.swift` | `375` | `aea301b650418f3ddf411ac3ea4ebc4bcc5b4c10f965932f80c8bb07608e288e` | Collapsible `Local` sidebar section & `.codexLocalManagement` routing (`Lines 92–146, 200–209, 252–255`) |
| `AIUsage/Views/GatewayAccountListModels.swift` | `361` | `c819c95aa1f10e0b217c722399642168af885e5939ae7fa9ba27252fc8bf557c` | `@MainActor` annotations on `CLIProxyGatewayManager` helpers (`Lines 177–217, 270`) |
| `AIUsage/Views/ProxyManagementView+Toolbar.swift` | `369` | `ec4e3f0c9c8a056d70960dbc3e990eeec79fa781da2597effbc198edd2f2fc9e` | Restored pure proxy toolbar (`Lines 65–78`) |
| `AIUsage/Views/ProxyManagementView.swift` | `388` | `0feb2ca9a7dffc73535f6f77ba3455eae42f21d811c1e4b5b4d9865c3146e9d2` | Restored pure proxy node list (`Lines 39–55, 86–125`) |
| `AIUsage/Views/SessionCenterView.swift` | `633` | `c1eff07c295c6a436af7302e4fc79e4d754a0318a2201f023129fcfcbc41ef2d` | `SessionListColumn` 5-tab filter bar & unified `Open in <Tool>.app` in `SessionActionsMenu` (`Lines 426–430, 513–521`) |
| `AIUsage/Views/SessionReaderView.swift` | `1095` | `80090d05aa7e27d2033fd3c645969539c4ca41bd8b500b2ede68e66365b0a049` | Auto-scroll to bottom (`Lines 318–338`), `28 x 28` full-square dropdown button in `SessionResumeButton` & `SessionDropdownMenuAnchor` (`Lines 844–1005`) |
| `AIUsage/Views/SettingsView+Sidebar.swift` | `72` | `c5d0008224096e2eaa9d97c10fe76fdccfc7ba0c85b154a4a9434681fd51dec0` | Uses `item.settingsTitle` (`Line 41`) |
| `AIUsage/Views/SidebarNavigation.swift` | `126` | `3ae30f1e120b01139b9451e81186a5fb9d2754eb9f309431c90662e60b934939` | `SidebarNavigation.local`, `SidebarNavigation.proxies`, `settingsTitle` |
| `QuotaBackend/Sources/QuotaBackend/Sessions/AntigravitySessionSource.swift` | `481` | `f96d15cd738cf1344d69731caa863d1057b7ac91569b79e07ec30b3c1f65cda4` | `AntigravitySessionSource` (`scan`, `readDatabaseMeta`, `parseDate`, `SummaryState`, `TranscriptState`) |
| `QuotaBackend/Sources/QuotaBackend/Sessions/SessionCatalog.swift` | `69` | `48772d90b1fb959c34d37910258029281a495f66746b8d539846ac8a7fe753f1` | 4-source concurrent scan & `.antigravityBrain` transcript dispatch |
| `QuotaBackend/Sources/QuotaBackend/Sessions/SessionModels.swift` | `150` | `5b3ab142b64ae1abd4b020e64f8857d1d21ad0e9a9e334d66ef57f6a36fdc3e6` | `SessionTool.antigravity`, `SessionLocator.antigravityBrain` |
| `QuotaBackend/Sources/QuotaBackend/Sessions/SessionResumePlan.swift` | `112` | `87add22d27ede86af33f9e14f510f3626fe6b400bf591436dbf49cda7e3aa721` | `desktopDeepLinkURL` / `desktopDeepLinkURL(for:sessionID:)` (`codex://threads/<lowercased-uuid>`) & `.antigravity` UUID validation (`Lines 65–80`) |
| `QuotaBackend/Sources/QuotaBackend/Sessions/SessionSourceMonitor.swift` | `167` | `f02480629a511751b991674e1fe19c61f99ed5d59d517e3037d341a4f926da29` | `Roots.antigravity` & FSEvents relevance filter |
| `QuotaBackend/Sources/QuotaBackend/Sessions/SessionSupport.swift` | `351` | `5d5ec6029b308409bea3e7613db2a74e0556875f9904d89028f0b3a8e9577f16` | `SessionEnvironment.antigravityRoot` & `ToolStepFactory` Antigravity tools |
| `QuotaBackend/Tests/QuotaBackendTests/SessionCatalogTests.swift` | `542` | `f9516cbf61987ba6296bc069fbd292169f17cc32ae1ff653608305c54d9132b5` | `testAntigravityScansBrainAndSummariesDatabaseAndBuildsTranscript` & `desktopDeepLinkURL` assertions (`Lines 369–386`) |
| `QuotaBackend/Tests/QuotaBackendTests/SessionLiveSearchTests.swift` | `441` | `e4de132b2adfe49b7f51a15e7b06f01500b2db564eacaa52e9f98967b0a2c0dc` | Antigravity monitor path relevance assertions |
| `scripts/AccountIdentityRegression.swift` | `1876` | `dbe54f4b54ba0ba3f8aa96d80833c7e83a2e43d3506201051f1a7b6e9e89274e` | 203-assertion Account Identity, OAuth & Antigravity Runtime Telemetry regression suite |
| `scripts/LocalSidebarAndSessionsRegression.swift` | `159` | `0b36812a7981ab404a04663c77a93d9c9191e2c26a7d5108b231b6e54ff64316` | 29-assertion standalone regression harness for Antigravity Session Center |
| `scripts/run_local_sidebar_and_sessions_regression.sh` | `18` | `ba9b89902ff0b11e8db89f28048016b437c99a4a2fff767ad3122321aa721000` | Compiles `QuotaBackend` + `LocalSidebarAndSessionsRegression.swift` and runs all 29 assertions |
| `artifacts/local-sidebar-review-2026-11-08/TokenSaverSilentErrorProbe.swift` | `208` | `6d4a0822ec9124420d4ecb9abea80a83c7f3e7b67474e574bf7160286bba13c8` | Probe verifying `tokenSaverCard` error/rollback, `poolProtectionCard` nil-safe tags, `28x28` split-button `5/5` corner+center mouse hit-test, and `SessionResumePlan.desktopDeepLinkURL` |
| `artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh` | `150` | `e7becc25250f16b6022acf8a5d56e86196d0c78277541e7ff5a7ea5cd39208fc` | Source audit (including `CodexLocalManagementView` nil-safe tags, 4-tool `desktopAppInfo`, and `SessionDropdownMenuAnchor`) + `TokenSaverSilentErrorProbe` runner |
| `artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh` | `15` | `bb64f2054067512a45e067342034a54068e6c61e43d8b4ab72f08be379319037` | Native `NSScrollView` geometry probe for `SessionTranscriptView` bottom auto-scroll |

---

## 3. Verification Commands for Codex Reviewer

Run from `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`:

```bash
# 1. Verify SHA-256 fingerprints across all 39 scoped files
shasum -a 256 \
  AIUsage/AIUsageApp.swift \
  AIUsage/Models/APIProvider.swift \
  AIUsage/Models/AgentVisibility.swift \
  AIUsage/Models/AppSettings.swift \
  AIUsage/Services/AntigravityAccountSwitcher.swift \
  AIUsage/Services/GlobalProxyRuntime.swift \
  AIUsage/Services/ProviderAuth/CopilotLoginCoordinator.swift \
  AIUsage/Services/ProviderAuth/KiroLoginCoordinator.swift \
  AIUsage/Services/ProviderAuth/ProviderAuthCandidateDiscovery.swift \
  AIUsage/Services/TLSCertificateManager.swift \
  AIUsage/ViewModels/CLIProxyGatewayManager.swift \
  AIUsage/ViewModels/ProviderActivationManager.swift \
  AIUsage/ViewModels/ProviderRefreshCoordinator.swift \
  AIUsage/ViewModels/SessionCenterStore.swift \
  AIUsage/Views/AntigravityManagementView.swift \
  AIUsage/Views/CodexLocalManagementView.swift \
  AIUsage/Views/CodexProxyManagementView.swift \
  AIUsage/Views/ContentView.swift \
  AIUsage/Views/GatewayAccountListModels.swift \
  AIUsage/Views/ProxyManagementView+Toolbar.swift \
  AIUsage/Views/ProxyManagementView.swift \
  AIUsage/Views/SessionCenterView.swift \
  AIUsage/Views/SessionReaderView.swift \
  AIUsage/Views/SettingsView+Sidebar.swift \
  AIUsage/Views/SidebarNavigation.swift \
  QuotaBackend/Sources/QuotaBackend/Sessions/AntigravitySessionSource.swift \
  QuotaBackend/Sources/QuotaBackend/Sessions/SessionCatalog.swift \
  QuotaBackend/Sources/QuotaBackend/Sessions/SessionModels.swift \
  QuotaBackend/Sources/QuotaBackend/Sessions/SessionResumePlan.swift \
  QuotaBackend/Sources/QuotaBackend/Sessions/SessionSourceMonitor.swift \
  QuotaBackend/Sources/QuotaBackend/Sessions/SessionSupport.swift \
  QuotaBackend/Tests/QuotaBackendTests/SessionCatalogTests.swift \
  QuotaBackend/Tests/QuotaBackendTests/SessionLiveSearchTests.swift \
  scripts/AccountIdentityRegression.swift \
  scripts/LocalSidebarAndSessionsRegression.swift \
  scripts/run_local_sidebar_and_sessions_regression.sh \
  artifacts/local-sidebar-review-2026-11-08/TokenSaverSilentErrorProbe.swift \
  artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh \
  artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh

# 2. Run Round 5 source audit, Token Saver conflict probe, AGY nil-state tag probe, 28x28 mouse hit-test probe, desktopDeepLinkURL probe, and reader scroll probe
bash artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh
bash artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh

# 3. Run the 29-assertion Antigravity Session Center regression suite
bash scripts/run_local_sidebar_and_sessions_regression.sh

# 4. Run the 203-assertion Account Identity, OAuth & Antigravity Runtime Telemetry regression suite + prior probes
bash scripts/run_account_identity_regression.sh
bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh
bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh
bash artifacts/restart-ui-review-2026-11-08/run_probe.sh

# 5. Syntax/whitespace check & installed binary verification
'/Users/apple/Library/Application Support/AIUsage/bin/token-saver-rtk' git diff --check
codesign --verify --deep --strict /Applications/AIUsage.app
shasum -a 256 /Applications/AIUsage.app/Contents/MacOS/AIUsage /Applications/AIUsage.app/Contents/Helpers/QuotaServer
```
