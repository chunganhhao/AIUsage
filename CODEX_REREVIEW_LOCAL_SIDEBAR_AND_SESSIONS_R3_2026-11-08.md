# Codex Independent Re-review — Round 3

Date: 2026-11-08
Repository: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`
Handoff: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/HANDOFF_CODEX_REVIEW_LOCAL_SIDEBAR_AND_SESSIONS_2026-11-08.md`
Baseline: `b844c71c5cfa39ead39614294b6db5f745c23623` plus scoped working-tree files; Round 2 approved review retained as baseline.

## Verdict: REQUEST CHANGES

What this change does: Round 3 gives all session tools a common terminal-resume button and adds desktop-app opening for Codex and Antigravity. It also shows Antigravity model, thinking, policy and workspace information read from local files.

Assumed load: one user running a local macOS app with multiple local sessions. This review checked Round 3 connected source, parser helpers, callers, UI wiring and supplied isolated regressions. Unrelated dirty files and documentation-image deletions are excluded and preserved.

## Must fix

1. **[P2] Model and thinking tags can report the wrong selection.**
   Locations: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Services/AntigravityAccountSwitcher.swift:2027–2029,2044–2054`.
   - **What this is:** The new runtime tags decode model-change messages in recent transcripts.
   - **Problem:** A selection without parentheses includes the notification suffix in the model name. A later model with no effort also inherits the earlier model's HIGH effort because nil is replaced with the previous value.
   - **Fix:** Strip the notification suffix before normalizing the model; assign the new effort directly, including nil. Add both negative regression cases to the existing suite.
   - **If we skip it:** The runtime card shows a malformed model or a thinking level that belongs to another model.

Executed isolated Swift probe extracted the actual production methods, not a rewritten parser. Exit 0:

```text
Input: The user changed setting `Model Selection` from None to Gemini 3 Flash. No need to comment.
SUFFIX: model=gemini-3-flash.-no-need-to-comment, effort=nil

Transcript: first Claude Opus 5.5 (High), then Gemini 3 Flash.
SWITCH: model=gemini-3-flash, effort=Optional("HIGH")
```

The suffix format is already present in the supplied Round 3 parser fixture. Temporary probe files were removed automatically. Parent and independent reviewer both reproduced these outputs.

2. **[P2] Failed runtime inspection is shown as known policy settings.**
   Location: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/AIUsage/Views/AntigravityManagementView.swift:581–602`.
   - **What this is:** The new card reports thinking, command execution, artifact review and security settings.
   - **Problem:** Missing/unreadable databases or invalid preference data leave optional values nil. The view turns those missing values into MEDIUM, always-proceed and standard without evidence that these are the actual settings.
   - **Fix:** Show Unknown or an em dash when inspection returns nil. Keep decoded values unchanged and test the missing/invalid-data case.
   - **If we skip it:** Users cannot distinguish a failed inspection from verified execution and security settings.

Source proof: `inspectRuntimeAndWorkspaces` initializes all policy fields to nil and only fills them after a successful read. `parseAgentPreferencesProto` returns `(nil, nil, nil)` for invalid base64. The card's nil-coalescing expressions replace those unknowns with named policies. No live account access is needed to establish this case.

## Executed checks

| Check | Actual result |
|---|---|
| Handoff SHA-256 fingerprints | 33/33 match |
| `bash scripts/run_account_identity_regression.sh` | PASS: 199 assertions |
| `bash scripts/run_local_sidebar_and_sessions_regression.sh` | PASS: 29 assertions |
| `bash artifacts/local-sidebar-review-2026-11-08/run_token_saver_error_probe.sh` | Exit 0; source audit, production rollback/error, extracted Codex card layout |
| `bash artifacts/local-sidebar-review-2026-11-08/run_reader_scroll_probe.sh` | Exit 0; normal open reaches bottom; explicit search focus stays near top |
| `bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` | PASS: 13 assertions |
| `bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh` | PASS: 11 assertions |
| `bash artifacts/restart-ui-review-2026-11-08/run_probe.sh` | PASS: 10 assertions |
| RTK `git diff --check` | Exit 0, no diagnostics |
| Additional extracted production parser probe | Exit 0; reproduced finding 1 twice independently |

Counted supplied assertions: **262**. Passing happy-path fixtures do not cover the parser/unknown-state cases above.

## Connected flow and prior finding

- Prior F1 error rendering remains present in both Local panels; the executed controller/card probe passes.
- `SessionReaderView` and `SessionActionsMenu` reach the same store actions. `resume` keeps activity confirmation for CLI tools and skips the misleading second-writer warning only for Antigravity.
- `SessionResumePlan` validates IDs and shell-quotes values; TerminalLauncher retains existing script permissions and launch-error behavior.
- Option A desktop opening opens the workspace directory, not an exact historical session. This matches the handoff and is not a finding.
- Runtime disk inspection runs in a detached task, while running-app enumeration is on MainActor. New SQLite handles use READONLY. This does not establish the handoff's stronger claim of zero SQLite locks under all runtime conditions.
- A fresh graph index was used; partial parse coverage and broad Swift call-name matches were checked against actual source.

## Independent Gatekeeper

Independent reviewer `/root/gatekeeper` returned **REQUEST CHANGES**, confirming the same two P2 areas and no concrete P0/P1 issue. Gatekeeper remains unchecked in task.md. No product remediation was made.

## Verification boundaries

Not checked: full Xcode app build, installed-app UI, actual terminal/desktop-app launches, live provider behavior, or production database contention. The NSHostingView/NSScrollView checks run extracted production views with deterministic stubs, not the complete installed app. XCTest was not rerun; Round 2 documents the local missing-XCTest limitation. No rebuild/deploy, app restart, provider request, credential/account change, commit or push was performed. Supplied scripts compile backend/harness targets and refresh probe artifacts only.

Verdict: fix 1 and 2 first. Build/deployment is not authorized by this review result.
