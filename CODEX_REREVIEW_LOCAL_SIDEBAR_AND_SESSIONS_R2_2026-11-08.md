# Codex Independent Re-review — Round 2

Date: 2026-11-08
Repository: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`
Handoff: `HANDOFF_CODEX_REVIEW_LOCAL_SIDEBAR_AND_SESSIONS_2026-11-08.md` (Round 2).
Baseline: `b844c71c5cfa39ead39614294b6db5f745c23623` plus scoped working-tree files.

## Verdict: APPROVED

F1 is closed. No remaining P0/P1/P2 findings in the scoped Round 2 changes. Independent reviewer also returned APPROVED after source audit and isolated native scroll checks. This is source/probe approval, not a claim that a rebuilt app has been deployed.

## Scope

Round 1 remains the baseline review. This re-review covers F1 remediation in both Local panels, new SessionReaderView bottom-scroll logic and its search/live-tail callers, timestamp normalization, and changes to the supplied probes. Assumed load: a local single-user macOS app; long transcripts remain lazily rendered. Unrelated dirty documentation deletions and prior artifacts are excluded and preserved.

## F1 closure

The prior silent-error P2 is resolved in current source:

- `AIUsage/Views/CodexLocalManagementView.swift:884–896` displays notice and localized error, with selectable red error text and stable accessibility identifiers.
- `AIUsage/Views/AntigravityManagementView.swift:722–734` renders the same feedback.
- Saved badges are conditional on `lastSaveSucceeded && error == nil` in both panels, so failed writes do not show successful-save feedback.
- The shared controller/store fail-closed behavior is unchanged. Executed production-controller probes confirm rejected toggle and reapply operations expose errors, restore persisted settings and preserve the external rules edit.

## Other Round 2 changes

`AntigravitySessionSource.parseDate` first preserves valid ISO8601 input, then converts the first SQLite date/time separator to `T`. The new end-to-end catalog fixture exercises a space-separated microsecond timestamp from the database and verifies it wins over the earlier transcript time.

The reader defaults to the bottom only without an explicit search focus; the focus task remains separate. Initial positioning is keyed by session ID and delayed corrections check cancellation/focus. Live-tail behavior remains gated by the bottom sentinel. The new API typechecks against the app's macOS 14 deployment target.

## Executed checks

| Check | Actual result |
|---|---|
| Handoff SHA-256 fingerprints | 30/30 matched |
| `bash artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh` | Exit 0; source wiring, production controller rollback/error, extracted Codex card NSHostingView layout |
| `bash scripts/run_local_sidebar_and_sessions_regression.sh` | PASS: 29 assertions |
| `bash scripts/run_account_identity_regression.sh` | PASS: 196 assertions |
| `bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` | PASS: 13 assertions |
| `bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh` | PASS: 11 assertions |
| `bash artifacts/restart-ui-review-2026-11-08/run_probe.sh` | PASS: 10 assertions |
| RTK `git diff --check` | Exit 0, no diagnostics |
| `swiftc -typecheck -target arm64-apple-macosx14.0` for ScrollView.defaultScrollAnchor | Exit 0, no diagnostics |

Total supplied counted regressions: **259 assertions**, plus the controller/card/source probe.

## Verification boundaries

The supplied NSHostingView probe lays out an extracted production Codex card using deterministic chrome/badge stubs; it does not assert visible/accessibility error text or exercise the complete installed app. Its SessionReaderView check is source wiring, not runtime scroll geometry. No full app rebuild, deployment, installed binary verification, restart, provider request or credential/account mutation was performed. Backend/harness compilation only was used. XCTest was not rerun; Round 1 established the local `no such module 'XCTest'` limitation, and standalone probes were executed instead. Existing graph coverage predates some changes; changed source was checked directly.

## Additional native reader verification

Independent reviewer executed `bash artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh` (exit 0). Parent inspected the extraction script and probe source. It extracts the production SessionTranscriptView, uses deterministic model/row/chrome stubs in its own 720×500 NSWindow, and inspects native NSScrollView geometry after layout:

```text
NORMAL offset=9123.0 max=9145.0
PASS: extracted production reader reaches bottom on normal open (100 fixed-height rows)
FOCUSED offset=502.0 max=9224.0
PASS: extracted production reader preserves near-top search focus instead of bottom
```

The normal 22-point gap corresponds to production vertical padding after the bottom sentinel. This verifies the normal-open and explicit-focus branches, not real Markdown rendering, every variable-height layout race, accessibility contents, or the full installed reader. These are intentional approval boundaries, not additional requested rounds.

No further changes are required by this review. Build/deployment remains a separate follow-up; none was performed here.
