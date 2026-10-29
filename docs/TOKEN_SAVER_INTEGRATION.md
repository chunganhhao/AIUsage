# Token Saver — safe trio

The current handoff (2026-10-29) explicitly excludes Headroom. This integration contains **RTK, Caveman and Ponytail only**.

## Architecture

Agent-side, coding-scoped rules. **No request middleware, listener, Python dependency, response postprocessing, CPA restart or change to `proxy-url`.** Consequently no mutation of Claude thinking signatures, OAuth credentials or provider egress/TLS.

- Each tool is opt-in and off by default. Atomic settings at `~/Library/Application Support/AIUsage/token-saver-settings.json` (0600), protected by an in-process lock.
- Coding-only isolation is mandatory. Managed agent instructions explicitly exclude RonC scripts, lyrics, creative writing, Zalo/customer-care responses and other non-coding tasks. These are instructions, not an infallible semantic classifier. No claims of guaranteed model compliance or measured savings.
- RTK rules support Antigravity `run_command` (zsh), Claude Code, Codex and OpenCode. RTK must be on the agent's PATH. A reversible, explicit zsh wrapper under AIUsage/bin supports Antigravity run_command and other agents without changing global PATH. No shell aliases or hidden interception; unsupported commands fall back to originals.
- Caveman Lite/Full/Ultra controls prose instructions only; exact code, paths, errors, security checks and essential explanations must remain intact.
- Ponytail chooses reuse/stdlib/native features and minimal verified code, not speculative abstractions.
- Rules are applied to dedicated Antigravity/Claude rules and managed blocks in Codex/OpenCode AGENTS. Existing user instructions are preserved. Start a new session to reload instructions.
- Upstream Markdown downloads are separate managed rule artifacts, never executed as code. RTK Check reads its Homebrew installed version; Update requires explicit confirmation and runs only `brew upgrade rtk` on an existing installation through a validated Homebrew path. No downloaded script, automatic install or update is executed.
- Reject symlinked targets and externally edited owned blocks. In-process serialization is not cross-process atomicity across several files.

## Verification boundaries

Run `swift test --package-path QuotaBackend`, `bash scripts/run_token_saver_settings_regression.sh` (CLT-only fallback), `bash scripts/run_token_saver_release_regression.sh`, and `bash scripts/run_pool_circuit_breaker_regression.sh`.

Full app build/tests use GitHub Actions (`build-personal.yml`) on `feat/token-saver-integration`, based on `personal-build` (`af7f4f8`). That workflow now runs Debug xcodebuild, the full QuotaBackend XCTest suite, Safe Trio/pool/updater regressions and universal Release packaging with provenance/hashes. Only read repository permission is needed; branch builds do not publish tags/releases or update main. No local Xcode installation is requested.

The original worktree retains its preexisting project/image deletions. The isolated feature worktree gets project/assets from its tracked personal-build base, without restoring or modifying the original checkout. Personal-build lacked the opt-in setting referenced by the handoff; the dependency port adds that switch support while preserving the personal-build ledger/provider/runtime behavior rather than merging the divergent upstream branch wholesale.

The release manager is registered as `AIUsage/Services/TokenSaverReleaseManager.swift` in this feature worktree’s Xcode project, matching the handoff. The original deleted project file is unchanged.
