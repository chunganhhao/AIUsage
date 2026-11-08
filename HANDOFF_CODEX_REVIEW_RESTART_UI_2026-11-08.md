# Hand-Off Brief for Codex Re-Review — Restart UI & Same-Identity Credential Reconciliation (`P2` Managed-Baseline Fail-Closed Remediation)

- **Date**: 2026-11-08
- **Repository**: `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`
- **Branch**: `feat/token-saver-integration`
- **Prior Review Reports**:
  - `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REVIEW_RESTART_UI_RESULT_2026-11-08.md` (`REQUEST CHANGES — 1 P2` -> Fixed)
  - `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REREVIEW_RESTART_UI_P2_RESULT_2026-11-08.md` (`REQUEST CHANGES — 1 P2` -> Fixed)
  - `/Users/apple/Downloads/Repo Github/AIUsage-token-saver/CODEX_REREVIEW_RESTART_UI_SELECTED_GROUP_RESULT_2026-11-08.md` (`REQUEST CHANGES — 1 P2` -> Fixed in this hand-off)
- **Fast Review Loop Policy**: Full 230-file `AIUsage.app` compilation is deferred until Codex returns final `APPROVED`; `QuotaBackend` module and all regression/probe executables are compiled and verified.
- **Regression & Probe Suites**:
  - `bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` -> `PASS: 13 isolated managed-baseline assertions; no live state touched`
  - `bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh` -> `PASS: 11 isolated conflict-rejection & output-identity assertions; no live state touched`
  - `bash artifacts/restart-ui-review-2026-11-08/run_probe.sh` -> `PASS: 10 isolated assertions; production source slices, temporary synthetic files only`
  - `bash scripts/run_account_identity_regression.sh` -> `PASS: 196 account identity & OAuth assertions (production save/reconcile/hide/delete/OAuth, isolated storage)`
  - `LC_ALL=en_US.UTF-8 bash scripts/run_codex_reset_cards_regression.sh` -> `PASS: 179 Codex reset-card coordinator/conversion/concurrency assertions`
  - `bash artifacts/account-switcher-review-2026-11-08/run_probe.sh` -> `PASS: 4 isolated state-preservation assertions`
  - `bash artifacts/account-switcher-rereview-2026-11-08/run_probe.sh` -> `PASS: 2 isolated remediation edge assertions`
  - `git diff --check` -> `0 errors`

---

## 1. Disposition of Finding in `CODEX_REREVIEW_RESTART_UI_SELECTED_GROUP_RESULT_2026-11-08.md`

| Finding | Verdict | Remediation & Exact Code Locations | Executed Proof |
| :--- | :---: | :--- | :--- |
| **`[P2]` Fail closed when the managed baseline fails strict parsing** (`CodexCredentialPolicy.swift:807–815`, `ProviderActivationManager.swift:284–303, 473–490`) | **Accepted & Fixed** | • **Explicit Fail-Closed Baseline Contract (`CodexCredentialPolicy.swift:754–772, 812–896`)**: Added `isValidBaseline: Bool` to `ReconciledAuthPayload` and `invalidReconciledPayload()` (`nativeData: Data()`, `nativeJSON: [:]`, `identity: CodexAccountIdentity(accountId: nil, userId: nil, email: nil)`, `adoptedLiveCandidate: false`, `healedManagedData: nil`, `isValidBaseline: false`). When `parseAuthSnapshot(from: managedNativeData)` (or `parseAuthSnapshot(from: managedSourceData)` when provided) fails strict validation or does not match `expectedIdentity` / `nativeKey`, `reconcileSameIdentityAuthData` immediately returns `invalidReconciledPayload()` instead of echoing back the unvalidated baseline bytes and aggregate identity.<br>• **Always Normalize & Verify `tokens`-Only Identity (`CodexCredentialPolicy.swift:869–895`)**: Even when `adoptedLive == false` (no newer live candidate), `reconcileSameIdentityAuthData` normalizes `best` (`managedSnapshot`) via `buildCleanNativePayload(from: best)` and verifies both `CodexAccountIdentity(authJSON: bestNativeJSON)` and `CodexAccountIdentity(authJSON: ["tokens": bestNativeJSON["tokens"]])` (plus `parseAuthSnapshot(from: bestNativeData)`) against `expectedIdentity` and `managedSnapshot.identity`, failing closed with `invalidReconciledPayload()` if any check fails.<br>• **Caller Abort Before Any Side Effects (`ProviderActivationManager.swift:284–303, 473–489`)**: Both `activateCodexAccount` (`Lines 291–300`) and `reapplyCodexAccountForRestart` (`Lines 480–486`) now guard `reconciled.isValidBaseline && expectedIdentity.matches(reconciled.identity)` and throw `ProviderError("account_mismatch", ...)` **before** posting activation notifications, restoring `config.toml`, writing `~/.codex/auth.json` / `auth.json.bak`, or syncing `.codex-global-state.json`. | • `bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` (`VERIFIED: conflicting dual-group managed baseline fails closed (isValidBaseline == false, empty payload/identity)` + `VERIFIED: pre-existing valid live auth.json is untouched and valid dual-group baseline normalizes cleanly`, `PASS: 13 isolated managed-baseline assertions`)<br>• `bash artifacts/restart-ui-review-2026-11-08/run_probe.sh` (`VERIFIED: invalid conflicting managed baseline aborts both activate and restart before config/auth writes`, `PASS: 10 isolated assertions`)<br>• `scripts/AccountIdentityRegression.swift:1756–1773` (Assertion 196: `PASS: 196 account identity & OAuth assertions`) |

---

## 2. Scoped Files, Line Counts & SHA-256 Fingerprints

| File Path | Lines | SHA-256 | Key Symbols & Line Ranges |
| :--- | :---: | :--- | :--- |
| `QuotaBackend/Sources/QuotaBackend/Providers/CodexCredentialPolicy.swift` | `1346` | `da494cfb0cf03fac7284e0d59a19b91596a1277d01c35b38671bd7ed12ec7c1a` | `ReconciledAuthPayload` (`Lines 754–761`), `invalidReconciledPayload` (`Lines 763–772`), `reconcileSameIdentityAuthData` (`Lines 812–896`), `validateTokenGroup` (`Lines 919–1037`), `parseAuthSnapshot` (`Lines 1039–1127`), `buildCleanNativePayload` (`Lines 1129–1149`), `buildHealedManagedData` (`Lines 1151–1207`). |
| `AIUsage/ViewModels/ProviderActivationManager.swift` | `1132` | `b4b5e76344fbce3dc9b37516d6094523980e099bbabc7b3666375bc31fc8524d` | `activateCodexAccount` + fail-closed baseline guard (`Lines 252–358`), `reapplyCodexAccountForRestart` + fail-closed baseline guard (`Lines 428–536`), `restartCodexApp` (`Lines 577–659`), `restartAntigravityApp` (`Lines 661–669`). |
| `AIUsage/Views/ProxyManagementView.swift` | `423` | `77604558e74ce2806fd0864108fe1462069c89a3d2f0da2a8cc29272abd72bd2` | `isRestartingCodex` & `codexStatusBannerMessage` (`Lines 41–43`), `activeCodexSubscriptionEntry` (`Lines 58–65`), `codexStatusBanner` & `CodexSubscriptionSection` wiring (`Lines 112–135`). |
| `AIUsage/Views/ProxyManagementView+Toolbar.swift` | `447` | `572546a58541265294534e61d987e46abc0b00e95c9b5d3d04cc3e28adf72f81` | `restartCodexButton` (`Lines 77–103`), `restartCodex()` (`Lines 105–119`), `codexStatusBanner(_:isError:)` (`Lines 121–151`). |
| `AIUsage/Views/CodexProxyManagementView.swift` | `567` | `b18899b51b4a296cea14e05dfc04db27adfef2ac48d31fcdf9353bfe096bb3cc` | `CodexSubscriptionSection` (`Lines 317–454`), `IDE Active` badge (`Lines 389–395`), account toggle & `onShowStatus` (`Lines 400–422`), right-click `.contextMenu` (`Lines 424–453`). |
| `AIUsage/Views/MenuBarView.swift` | `697` | `617c9faa6a69343886dd7a97dc4b94c5ee1746e10c0bd81019c4ee7488b419e5` | `pendingRestartPrompt` & `isConfirmingRestart` (`Lines 19–20`), `.overlay { restartConfirmationOverlay }` (`Lines 40–44`), `presentRestartConfirmation(for:)` & `confirmAndRestartApp(for:)` (`Lines 247–296`), `restartConfirmationOverlay(prompt:)` (`Lines 298–417`), `MenuBarRestartPrompt` (`Lines 671–690`). |
| `AIUsage/Views/MenuBarRows.swift` | `164` | `3d9ee9fc21f99764decbdeb367bd656d14f45727710654035df73de1d3f85b05` | `onRequestRestartConfirmation` passthrough (`Lines 12, 38`). |
| `AIUsage/Views/MenuBarAccountRow.swift` | `325` | `3d2e5887384ca36594c3fad1a566a6b00b6e0220026b9a6f546ed8ef9af85157` | `onRequestRestartConfirmation` property (`Line 20`), `performActivation()` (`Lines 307–324`). |
| `AIUsage/Views/MenuBarView+TrackSwitcher.swift` | `350` | `637e598e2ef08d20d2d80a5158d64fd1087cc0353d502adbab6d79f8da7e0847` | TrackSwitcher Codex `Subscription` row switch action calling `presentRestartConfirmation(for: entry)` (`Lines 153–164`). |
| `scripts/AccountIdentityRegression.swift` | `1774` | `e94b2caa87fb849f2162e8e026cafab2b2a7758c09363c59970560051f3fc418` | Section `8m` (`Lines 1648–1773`: same-identity fresher live refresh_token preservation + managed healing, foreign-identity rejection, mixed candidate rejection, and mixed managed-baseline fail-closed rejection). |
| `artifacts/restart-ui-final-review-2026-11-08/ManagedBaselineProbe.swift` | `110` | `c8979d1bb5278c3fa199820d66dd05c638f1a79fa9306983a0d5e67b61eedbfa` | Direct compiled-production `CodexCredentialPolicy` probe verifying conflicting managed baseline fail-closed rejection, untouched live `auth.json`, and valid dual-group normalization (`13 isolated assertions`). |
| `artifacts/restart-ui-final-review-2026-11-08/run_probe.sh` | `11` | `002b903f11126647ae49e5c950ffde7bdb273cb9d672085e47bda60b410f6daa` | Builds `QuotaBackend` and executes `ManagedBaselineProbe.swift`. |
| `artifacts/restart-ui-p2-rereview-2026-11-08/ConflictPolicyProbe.swift` | `81` | `e0b3215dd281f27e3f3a3ccfbc9313d400016a934a731b4845e8594f1f892b5e` | Direct compiled-production `CodexCredentialPolicy` probe verifying mixed `A-access/B-id` candidate rejection and valid dual-group `A` acceptance (`11 isolated assertions`). |
| `artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh` | `11` | `e71429bdb554989a37ba268d733fe8e7ed4f75405cfb5f5195ec6aa13f7d1a09` | Builds `QuotaBackend` and executes `ConflictPolicyProbe.swift`. |
| `artifacts/restart-ui-review-2026-11-08/build_probe.py` | `150` | `6d1eff54e966500eb664c7dd3c2869b5690ef3579ae930cdf1e57b59af0650f6` | Extracts production `activateCodexAccount` and `reapplyCodexAccountForRestart` slices and asserts token preservation, foreign replacement, and no-write abort on conflicting managed baseline. |
| `artifacts/restart-ui-review-2026-11-08/StaleRestartTokenProbe.swift` | `273` | `0acb223124387e2f0dad4f0146c231b11a4dd0e308801762d628420f03fa0c86` | Generated executable probe harness (`10 isolated assertions`). |
| `artifacts/restart-ui-review-2026-11-08/run_probe.sh` | `12` | `1b252dd1cec0db1e2219466e4e47c823a26294d0c46c10c41a85a37058f5dd93` | Builds `QuotaBackend`, regenerates `StaleRestartTokenProbe.swift`, and executes the 10-assertion probe. |

---

## 3. Verification Commands for Codex Reviewer

Run from `/Users/apple/Downloads/Repo Github/AIUsage-token-saver`:

```bash
# 1. Verify SHA-256 fingerprints across all 17 scoped files
shasum -a 256 \
  QuotaBackend/Sources/QuotaBackend/Providers/CodexCredentialPolicy.swift \
  AIUsage/ViewModels/ProviderActivationManager.swift \
  AIUsage/Views/ProxyManagementView.swift \
  AIUsage/Views/ProxyManagementView+Toolbar.swift \
  AIUsage/Views/CodexProxyManagementView.swift \
  AIUsage/Views/MenuBarView.swift \
  AIUsage/Views/MenuBarRows.swift \
  AIUsage/Views/MenuBarAccountRow.swift \
  AIUsage/Views/MenuBarView+TrackSwitcher.swift \
  scripts/AccountIdentityRegression.swift \
  artifacts/restart-ui-final-review-2026-11-08/ManagedBaselineProbe.swift \
  artifacts/restart-ui-final-review-2026-11-08/run_probe.sh \
  artifacts/restart-ui-p2-rereview-2026-11-08/ConflictPolicyProbe.swift \
  artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh \
  artifacts/restart-ui-review-2026-11-08/build_probe.py \
  artifacts/restart-ui-review-2026-11-08/StaleRestartTokenProbe.swift \
  artifacts/restart-ui-review-2026-11-08/run_probe.sh

# 2. Run the managed-baseline probe (13 assertions), conflict probe (11 assertions), restart probe (10 assertions) & 196-assertion account identity regression suite
bash artifacts/restart-ui-final-review-2026-11-08/run_probe.sh
bash artifacts/restart-ui-p2-rereview-2026-11-08/run_probe.sh
bash artifacts/restart-ui-review-2026-11-08/run_probe.sh
bash scripts/run_account_identity_regression.sh

# 3. Run the remaining regression & probe suites
LC_ALL=en_US.UTF-8 bash scripts/run_codex_reset_cards_regression.sh
bash artifacts/account-switcher-review-2026-11-08/run_probe.sh
bash artifacts/account-switcher-rereview-2026-11-08/run_probe.sh
'/Users/apple/Library/Application Support/AIUsage/bin/token-saver-rtk' git diff --check
```
