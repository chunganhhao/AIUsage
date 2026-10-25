# Antigravity pool circuit breaker

## Behavior
- Evaluate Gemini, Claude/GPT and Gemini 4 Argon independently. Weekly trips at **<= 3.0%**, other windows at **<= 5.0%**, using unrounded floating-point values.
- Keep the account active and add exact model IDs from CPA's `antigravity_capability_hints.model_ids` to credential `excluded_models`. Argon is classified before generic Gemini IDs. Do not modify capability hints, tokens, or other accounts.
- Persist blocked window IDs, not just the minimum pool percentage. A missing/disabled window cannot prove recovery. Remove only the breaker overlay when the corresponding observed windows recover.
- Preserve original credential exclusions. When the credential inherited global exclusions, include current global exclusions while the overlay is active; restore inheritance when recovered. V8 `excluded-models` takes precedence over legacy `oauth-excluded-models`.
- Manual pauses are never re-enabled. Legacy breaker-owned whole-account pauses migrate only when each core pool either has an observed blocked window (so it remains model-blocked), or both weekly and 5h windows are observed healthy. All required blocked-pool model IDs must be available.
- Codex keeps its existing whole-account circuit breaker.

## Safety boundaries
- Require the managed `current` symlink to resolve to a version >= v8.0.43. Older/unknown versions, missing model IDs, malformed JSON, unsupported exclusion policies, or external edits to managed exclusions produce an explicit attention status, not a success claim.
- The bounded global-policy reader accepts ordinary block lists with plain/single/double-quoted model IDs. It rejects flow lists/maps, aliases, merge keys and unsupported relevant syntax rather than silently overriding policy. No new YAML dependency.
- Atomic credential writes are preceded by a byte comparison against the freshly read file. This narrows but cannot eliminate a race with an independent CPA process (there is no shared cross-process CAS). This patch does not change CPA's token refresh mechanism.
- External exclusion edits while the overlay is present fail closed, requiring reconciliation rather than guessing which entries the user owns.
- Account-sync upload behavior remains unchanged. Explicit subscription-to-CPA replacement can replace credential metadata; the next successful quota poll reapplies protection. This patch does not authorize or perform that replacement.

## Verification (2026-10-25)
```sh
bash scripts/run_pool_circuit_breaker_regression.sh
AIUSAGE_CPA_TEST_BINARY='/absolute/path/to/CLIProxyAPI' bash scripts/run_pool_circuit_breaker_regression.sh
swift build --package-path QuotaBackend --build-system native --product QuotaServer
git diff --check
```

Results after reviewer R1–R3 remediation: **53 standalone checks passed**, backend/provider/AuthImports/normalizer exercised with fake quota responses; **CPA v8.0.43 (30780351)** isolated process confirmed baseline model registration, pool-specific exclusion hot reload, another account unchanged, active account status and restored model registration after recovery. Added coverage for indented/escaped YAML keys, blank credential exclusions, and each missing legacy weekly/5h window. Integration supplies a local fixture model catalog because embedded catalogs do not necessarily include the new provider models. Fake credentials use a dead loopback proxy; no live generation or real credential request.

The XCTest file is supplied for environments with Xcode. This machine's `swift test` cannot import XCTest; `xcodebuild -version` confirms only Command Line Tools. The normalizer is backend payload logic; no SwiftUI view was modified. No claim of full GUI or installed-app verification.

## Upstream evidence
- [v8.0.43 credential exclusion priority and registration](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.43/sdk/cliproxy/service_models.go)
- [v8.0.43 Antigravity cached-hint registration also applies exclusions](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.43/sdk/cliproxy/antigravity_models.go)
- Engram #4920 and #5025 describe older, contradictory model-exclusion assumptions. Current source and isolated binary behavior, not those historical assertions, establish v8.0.43 support. Keep AuthImports-to-CPA lookup, strict floating-point thresholds (#5030), manual-pause protection, and intact capability hints.
- Toolchain search proof: GitHub repository search `swift XCTest`, open PR search `no such module XCTest`, and scoped/global issue search `XCTest Command Line Tools no such module`. No matching corrective issue found; no toolchain patch/dependency was added. Use the project's existing standalone Swift regression pattern.

## Deployment
Source changes and the QuotaServer backend build are verified. The personal-build GitHub Actions workflow now runs targeted XCTest and standalone regression checks, verifies the packaged helper contains the new implementation, and exports SHA256SUMS plus commit/run provenance. This personal workflow uses the existing ad-hoc-signing policy (no signing secrets configured); it is not a notarized/public Sparkle release. The installed AIUsage app has **not** been replaced/re-signed/restarted; a personal package download alone does not activate the new behavior in the running app.
