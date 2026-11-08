# Codex final scoped review — Restart UI / credential reconciliation

Date: 2026-11-08
Verdict: **APPROVED — offline source/regression scope, no remaining actionable P0/P1/P2 found.**

## Review evidence
Read current handoff, current policy/manager git diff, shared reconciliation and both callers, direct-policy probes and generated integration-probe builder. Seven View files retain prior reviewed fingerprints. Consulted Engram context, searched managed-baseline history and read full updated observation #7035; historical fix claims independently checked against current source and executed tests. Independent reviewer also returned APPROVED for the same scope.

## Prior P2 findings resolved
1. Same-identity stale-token overwrite: fresher live credential preserved, managed copy healed under existing byte comparison guard; foreign identity not adopted.
2. Mixed candidate group selection: per-group validation rejects conflicting access/id groups; selected credentials and identity aligned; emitted native auth verified.
3. Invalid managed baseline fallback: policy now validates both native and original managed data, returns empty payload/identity with isValidBaseline=false on failure, and normalizes/verifies native tokens even without adopting a live candidate. Activation (291–300) and restart (490–496) check validity/identity before notification/config/auth/global-state writes. Production-source integration slices confirm invalid baseline throws account_mismatch without config restore or live/backup changes.

## Executed verification (all exit 0)
| Command/check | Result |
|---|---|
| SHA-256 against handoff table, before and after tests | 17/17 matched |
| bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh | 13 managed-baseline assertions |
| bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh | 11 candidate/output-identity assertions |
| bash artifacts/restart-ui-review-2026-11-08/run_probe.sh | 10 extracted production activation/restart assertions |
| bash scripts/run_account_identity_regression.sh | 196 account identity/OAuth assertions |
| LC_ALL=en_US.UTF-8 bash scripts/run_codex_reset_cards_regression.sh | 179 coordinator/conversion/concurrency assertions |
| bash artifacts/account-switcher-review-2026-11-08/run_probe.sh | 4 state-preservation assertions |
| bash artifacts/account-switcher-rereview-2026-11-08/run_probe.sh | 2 remediation assertions |
| RTK git diff --check | clean |
| swiftc -frontend -parse policy, manager, seven Views, regression source | syntax pass |

QuotaBackend compiled through probe scripts. Tests use synthetic credentials and temporary storage. Integration probe extracts current production slices; config manager, selection/generation and running-process seams are isolated, not a full native-app execution. Direct policy checks alone do not prove manager side effects; the separate integration slices provide that offline proof.

## Acceptance boundary and handoff
This is final APPROVED for the requested fast offline code/regression review, not a claim of full AIUsage.app build, native GUI E2E or live OAuth/provider acceptance. The handoff explicitly defers the full 230-file app compilation until this approval; it can proceed now. No production edits, Keychain/account mutation or real process restart performed; unrelated worktree deletions/files preserved. Do not reopen another review round solely for these declared scope boundaries.

Separate Antigravity/Gemini Gatekeeper acknowledgment remains unchecked in task.md; this Codex review does not impersonate that role.

## Key Learnings:
Validate both managed source and emitted native tokens; propagate invalidity explicitly and guard every writer before side effects.
