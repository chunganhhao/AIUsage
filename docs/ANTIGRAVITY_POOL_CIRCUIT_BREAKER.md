# Antigravity pool circuit breaker

Antigravity's Gemini, Claude/GPT and Gemini 4 Argon quotas are independent pools.
Depleting one pool should not disable the account's other eligible models.

## Behavior
- Evaluate **Weekly <= 3.0%** and **5-hour <= 5.0%** using unrounded values. Argon's weekly quota is protected independently without affecting the core-pool headline percentage.
- Keep the Antigravity account enabled and put only the affected pool's exact model IDs into its credential `excluded_models`. Classify Argon before generic Gemini IDs and keep `antigravity_capability_hints` intact for recovery.
- Track blocked window IDs. Missing or disabled windows are not evidence of recovery; remove a block only after its corresponding observed window recovers above its threshold.
- Preserve manual account pauses and user model exclusions. While a credential inherits global exclusions, the breaker overlay includes the current global policy; recovery restores the original credential policy/inheritance.
- V8 `excluded-models` takes precedence over legacy `oauth-excluded-models`. Credential exclusions are trimmed and empty entries do not suppress inheritance.
- A legacy breaker-owned whole-account pause migrates only when each core pool either remains model-blocked by an observed depleted window or has both weekly and 5-hour windows observed healthy.
- Codex retains its existing whole-account circuit breaker.

## Compatibility and failure handling
- Requires the managed CLIProxyAPI `current` symlink to identify **v8.0.43 or later**, which supports per-credential model exclusions including cached Antigravity model registration.
- Missing model IDs, unsupported versions/policy syntax, invalid credentials, external exclusion edits and persistence failures produce an explicit attention state rather than claiming successful protection.
- The dependency-free YAML policy reader supports ordinary block lists, root indentation, quoted/JSON-escaped keys and an initial BOM. Unsupported directives, anchors, tags, flow roots, merge keys and relevant unsupported syntax fail closed before credential mutation.
- Credential updates use atomic writes and compare the just-read bytes before replacement. This narrows, but cannot eliminate, races with a separate CPA process; there is no shared cross-process compare-and-swap.
- Explicit subscription-to-CPA replacement remains an existing operation; the next successful quota poll reapplies the breaker overlay. No billing, project-switching or preview-model settings are changed by this feature.

## Verification
```sh
swift test --package-path QuotaBackend --filter 'AntigravityProviderTests|AntigravityPoolCircuitBreakerTests'
bash scripts/run_pool_circuit_breaker_regression.sh
AIUSAGE_CPA_TEST_BINARY=/absolute/path/to/CLIProxyAPI bash scripts/run_pool_circuit_breaker_regression.sh
swift build --package-path QuotaBackend --build-system native --product QuotaServer
```

The standalone runner links the actual backend and checks provider-to-CPA lookup, exact thresholds, pool/account isolation, manual pauses, inherited exclusions, legacy migration, missing windows, recovery and normalizer output. It replaces the old account-dependent circuit-breaker script.

The optional CPA integration starts a separate process with fake credentials, a local fixture catalog and a dead loopback proxy. It checks baseline model registration, pool-specific exclusion hot reload, another account remaining intact, account enabled status and restored registration after recovery. It does not submit paid model inference or prove live provider completion/delivery.

CLIProxyAPI references: [credential exclusion priority](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.43/sdk/cliproxy/service_models.go), [Antigravity cached-hint registration](https://github.com/router-for-me/CLIProxyAPI/blob/v8.0.43/sdk/cliproxy/antigravity_models.go).
