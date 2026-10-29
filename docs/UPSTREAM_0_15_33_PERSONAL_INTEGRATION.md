# AIUsage 0.15.33 personal integration

## Sources
- Personal baseline: `af7f4f8`.
- AGY-approved Safe Trio snapshot: `3cd64ab` (including the CI fix that excludes the obsolete CPA updater regression).
- Released upstream: `v0.15.33`, `c8cec2c`.

## Added upstream behavior
Codex reset-card details and confirmed redemption, Credits and account-list/menu-bar summaries, refresh fences, and shared GET-only node key-balance lookup. Existing upstream regressions and preview renderer are included in the personal build workflow.

## Private behavior preserved
- Antigravity Argon independent grouping, provider user-agent/project fallbacks and cost/heatmap ledger.
- Opt-in pool protection, shared credential locking, explicit residual-exclusion Restore and guarded two-refresh persistence.
- CPA runtime adoption/recovery/shutdown/activity changes; request retry default1 and normalized switch-project/Antigravity-credits false.
- Codex identity/token selection, rejected-token tracking, stale-copy recovery and monthly breaker policies.
- RTK, Caveman and Ponytail only. No Headroom, extra LLM middleware or changed live provider routing.

## Compatibility adaptation
Codex reset-card GET reads reuse private credential recovery. Consume POST stays single-submit, with account revalidation and no auth replay or redirect. Native user IDs and legacy JWT subjects are compared in their proper namespaces throughout parsing/loading/refresh; true account/native/fallback-subject/email mismatch guards remain.

## Evidence boundaries
Local production-source regressions and isolated English/light + Chinese/dark UI renders were exercised without real reset POSTs, provider calls or user-account reads. Full Debug/Release app build, native XCTest and universal ZIP/DMG verification must be established by GitHub Actions on the integration commit. Preview images do not establish live account or provider outcomes. No installation or runtime restart is included.
