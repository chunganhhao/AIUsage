# Codex Independent Re-review — Round 5

Date: 2026-11-09 (Asia/Ho_Chi_Minh)
Repository: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`
Handoff: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/HANDOFF_CODEX_REVIEW_LOCAL_SIDEBAR_AND_SESSIONS_2026-11-08.md` (current Round 5 version)
Prior approved review: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REREVIEW_LOCAL_SIDEBAR_AND_SESSIONS_R4_2026-11-08.md`
Baseline: `b844c71c5cfa39ead39614294b6db5f745c23623` plus scoped working-tree files.

## What this change does:

Round 5 normalizes Codex workspace paths, recognizes the Codex app when its filename is ChatGPT.app, and preserves unknown runtime settings as unknown. It adds desktop opening for all four session tools, a full-square dropdown button, Codex session deep links, and actor-isolation fixes.

## Verdict: APPROVED

Looks good. Ship within this source/isolated-probe review scope. No concrete P0/P1/P2 findings remain in the Round 5 changes. Independent Gatekeeper `/root/round5_gatekeeper` also returned APPROVED. No extra review round is required.

## Scope and Engram

Called Engram context and search for project `aiusage`; read full observation **#7140**, covering path normalization, ChatGPT.app detection and the macOS split-button hit-target gotcha. Prior Round 3 parser/stale-effort and nil-policy failures were retained as regression checks. Memory guided the checks; actual source and executed probes determine this verdict.

Assumed load: a single-user macOS menu-bar app with several local agent sessions. Reviewed the new Round 5 behavior and connected callers; prior Round 4 approval is the unchanged baseline, not an invitation to reopen its accepted boundaries. Unrelated dirty files and documentation-image deletions remain excluded and preserved.

## Review results

### Codex environment summary

`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Views/CodexLocalManagementView.swift:56–207,716–744`

Both TOML project sections and saved/active global-state roots pass through the same normalization helper before entering a Set. File URLs are decoded and paths standardized. A temporary fixture compiled the actual extracted production `CodexLocalEnvironmentSummary`, combining TOML and global-state duplicates with percent-encoded spaces, file URLs and trailing slashes. It returned the expected **two** unique paths and left missing model/effort/sandbox/approval values nil.

The ChatGPT.app candidates require `com.openai.codex`, so the regular ChatGPT application is not treated as Codex merely because of its filename. Optional runtime tags now show an em dash instead of invented values. The shared desktop-opening flow also uses the existing Codex bundle resolver.

### Actor-isolation changes

`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Services/TLSCertificateManager.swift`
`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Services/ProviderAuth/CopilotLoginCoordinator.swift`
`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Services/ProviderAuth/KiroLoginCoordinator.swift`
`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/ViewModels/CLIProxyGatewayManager.swift`
`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Models/APIProvider.swift`
`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/ViewModels/ProviderActivationManager.swift:1117–1129`

The nonisolated static values are immutable. The certificate helpers use passed-in paths and local process state, not mutable instance state. The provider loop guard explicitly stays on MainActor; its UI/distributor callers were traced.

Active-account detection now owns an inherited-main-actor Task. Only the disk detection executes detached; the detached closure does not capture self. Canceled results are rejected before publishing to the owner. No concrete state-ordering regression was found. This review did not independently rerun the claimed full 231-source Release compilation or certify zero concurrency warnings across that build.

### Desktop opening and deep links

`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/ViewModels/SessionCenterStore.swift:487–577`
`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/QuotaBackend/Sources/QuotaBackend/Sessions/SessionResumePlan.swift:65–80`

All four tools expose the action. A missing desktop app results in explicit feedback. Codex uses the shared resolver, including bundle-identified ChatGPT.app installation. The deep-link builder validates UUID input before lowercasing and constructing `codex://threads/<uuid>`; invalid IDs and other tools return nil.

The store dispatches to the selected app rather than whichever app owns the scheme globally. Dispatch errors fall back to the project folder and then app launch. Actual target-app URL consumption and exact-session navigation were not invoked during this review; successful URL construction or codesigning alone does not prove those behaviors.

### Actual split button and native menu

`/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Views/SessionReaderView.swift:844–1025`

The new button uses a full 28×28 rectangle. The coordinator refreshes its store/session, opens a native menu on a changed trigger, and routes app-opening and terminal-selection actions to the store. Reader callers retain the resume-blocker disabled state.

The supplied 5-click test is a **hand-written lookalike** of the split-button layout. It does not extract the production SessionResumeButton or include SessionDropdownMenuAnchor, so its PASS message alone is not proof of the actual coordinator path.

To close that evidence gap, the independent reviewer compiled the actual extracted production SessionResumeButton, SessionDropdownMenuAnchor and SessionPrimarySegmentStyle. A stub store prevented live actions; a RecordingMenu subclass replaced only NSMenu construction and intercepted popUp so the test did not enter a live modal menu. Results, exit 0:

- Four corners plus center: **5 menu popups, 0 resume actions**.
- Menu item titles and tool labels matched.
- Performing the app-opening menu action: **1 stub open**.
- Performing a terminal menu action changed the stub terminal.

This verifies actual click -> coordinator -> menu/action wiring. It does not verify popup screen position, the full installed app, or real desktop application dispatch. A warning in this review-only probe concerned an unused return value because the recording override lacked the original discardable-result annotation; it is not an app warning.

## Executed checks

| Check | Actual result |
|---|---|
| Current handoff SHA-256 fingerprints | 39/39 matched |
| `bash scripts/run_account_identity_regression.sh` | PASS: 203 assertions, exit 0 |
| `bash scripts/run_local_sidebar_and_sessions_regression.sh` | PASS: 29 assertions, exit 0 |
| `bash artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh` | Exit 0; rollback/error, nil-safe AGY tags, copied-layout 5-click test, deep-link builder checks |
| `bash artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh` | Exit 0; normal bottom position and near-top search focus preserved |
| `bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` | PASS: 13 assertions, exit 0 |
| `bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh` | PASS: 11 assertions, exit 0 |
| `bash artifacts/restart-ui-review-2026-11-08/run_probe.sh` | PASS: 10 assertions, exit 0 |
| RTK `git diff --check` | Exit 0, no diagnostics |
| Additional production Codex-summary fixture | Exit 0; normalized unique workspace count and nil fields correct |
| Independent extracted actual split-button/coordinator fixture | Exit 0; 5/5 popups and action routing correct |
| `codesign --verify --deep --strict /Applications/AIUsage.app` | Exit 0 |
| Installed app executable and helper SHA-256 | Both match current handoff |
| Independent Gatekeeper | APPROVED, zero P0/P1/P2 |

Counted supplied regressions: **266 assertions**, plus the native/controller/deep-link and additional production-source probes. Prior Round 3 parser and unknown-policy regression cases remain covered by the 203-assertion suite and native tag probe.

Installed hashes independently verified:

```text
AIUsage:     e8928d5dda73a69a308956de28df7ee88acd5099164eea32f97301e16559a4e2
QuotaServer: b152bcd020bb80c5969f3d5605378d4298ef5f1071d0fc29a01ef222a61284f7
```

Matching hashes bind these installed files to the handoff's named binaries; they do not independently prove the binaries were built from all reviewed source files.

## Boundaries and cleanup

Not checked: a fresh full 231-source Release build, installed-app end-to-end routing, popup screen placement, accessibility contents, actual desktop/terminal opening, live provider behavior or production SQLite contention. XCTest was not rerun; earlier reviews document its local missing-module limitation. Backend/harness compilation and isolated native view checks were executed instead. These are approval boundaries, not additional requested rounds.

No product code edits, app rebuild/deploy/restart, live desktop session dispatch, credential/account mutation, provider request, commit or push was performed. Supplied scripts can refresh their own review output artifacts. Temporary probes removed their synthetic data. Root task.md was checked off and removed only after both parent and independent Gatekeeper approval.

Verdict: Ship.
