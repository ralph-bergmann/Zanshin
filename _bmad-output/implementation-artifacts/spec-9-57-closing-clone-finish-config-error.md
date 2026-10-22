---
title: 'Story 9.57 closing run — clone refuses an unresolvable `immutable_heads()` as `jj.config_error`'
type: 'bugfix'
created: '2026-10-22'
status: 'done'
baseline_revision: '35c42cecab9b1ca459548538d3656613c5194bcd'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      An unresolvable `immutable_heads()` refuses every verb (and clone, convert_import) with jj-lib's
      bare resolution error as `context`, while the CLI's message is "Invalid
      `revset-aliases.immutable_heads()`" with that error as its cause.
    evidence: |-
      `crates/zanshin-jj/src/op_support.rs:86-91` (`resolve_expression(..).map_err(cfg)`, reason =
      the `RevsetError` text only); CLI v0.46.0 `cli/src/cli_util.rs:1146-1167`
      (`config_error_with_message("Invalid `revset-aliases.immutable_heads()`", e)`). Pre-existing,
      shared by every caller of `resolve_immutable`; found in this run's review.
    location: >-
      crates/zanshin-jj/src/op_support.rs:86
    severity: low
    resolved: >-
      2026-10-22 — fixed (spec-9-58-init-left-behind-one-level-immutable-text, commit 2bb36ad): resolve_immutable prefixes "Invalid `revset-aliases.immutable_heads()`: "; git push's commit check keeps jj-lib's plain text, as the CLI.
---

<intent-contract>

## Intent

**Problem:** Story 9.57's deferred item 1, verified at `35c42ce`: clone's shared `finish` (`crates/zanshin-jj/src/creation.rs:484-505`) maps `op_support::resolve_immutable`'s error (always `MutateError::Config`, `op_support.rs:86-91`) to `clone_failed` → `RepoError::CloneFailed` → `jj.jj_lib_error`. The CLI's `tx.finish` → `rebase_mutable_descendants` → `resolve_immutable_expression` (`cli_util.rs:2986-3002` @ v0.46.0) raises a config error, which `jj git clone` propagates after `clean_up_dirs` (`clone.rs:262-284`). Every other verb's finish (`mutate.rs finish_verb`) and `convert_import`'s head-import finish (`convert.rs:704`, `finish_error` :722-727) already report `jj.config_error`.

**Approach:** Map the `resolve_immutable` error in clone's `finish` through a small `finish_error` (`MutateError::Config` → `RepoError::Config`, anything else → `clone_failed`), mirroring `convert.rs::finish_error`. The refusal point, the clean-up and the warnings stay as they are.

## Boundaries & Constraints

**Always:**
- The clone refuses at its FIRST finish with changes (`add git remote <name>` inside the clean-up scope), exactly where it refuses today; the clean-up (`clean_up`, `.jj` / colocated `.git`, the destination iff created) runs as today; no operation survives; the reason is `resolve_immutable`'s text (names the alias / the symbol).
- `Repo::clone`'s rustdoc `# Errors` (`repo.rs:2918-2921`), `zanshin_repo_clone`'s rustdoc `jj.config_error` bullet (`crates/zanshin-ffi/src/repo.rs:851-854`, copied into `bindings.dart` by `cargo make codegen` — commit the regenerated output) and the `jj.config_error` registry row (`docs/rust-error-codes.md:58`) name the new emitter.
- Tests per project-context.md: integration rows go in the own-process `tests/it/creation_warnings.rs` walk (it already switches `JJ_CONFIG` per phase and restores `""`); the mapping gets an inline unit test next to `creation.rs`'s existing tests.

**Never:**
- No change to `finish_transaction`'s, the rebase's or the lock's error mapping (they never return `Config`), no new code, variant or warning, no `.fbs` edit, no Dart/UI/MCP change.
- No change to `init`, `convert` or the other two deferred Story 9.57 items.
- Never regenerate fixtures; never lower `coverage-baseline.txt`; do not touch Story 9.57's spec, `epics.md` or `epic-9-context.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Unresolvable alias, new destination | user config `revset-aliases."immutable_heads()" = "nonexistent_symbol_xyz"`; clone a Git source with a commit into a missing `dst` (non-colocated) | `Err(RepoError::Config)`, reason contains `nonexistent_symbol_xyz`; `dst` removed (the call created it) | `jj.config_error` |
| Unresolvable alias, existing empty destination, colocated | same alias; clone into an existing empty dir, default colocation | `Err(RepoError::Config)`; the dir stays, empty (no `.jj`, no `.git`) | `jj.config_error` |
| Other finish failures | rebase / lock / `finish_transaction` failing | unchanged: `CloneFailed` | `jj.jj_lib_error` |
| Mapping (unit) | `finish_error(MutateError::Config{..})`, `finish_error(MutateError::Backend(..))` | `RepoError::Config` with the same reason; `RepoError::CloneFailed` with the text | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/creation.rs` -- `clone_failed` :263-268; `clone_steps` :308-382 (clean-up scope :356-364); `finish` :480-505 (`resolve_immutable(..).map_err(|e| clone_failed(e.to_string()))` :488-489 — the one line to change); callers `configure_remote` :519, `fetch_new_remote` :628, `check_out_working_branch` :650; inline `mod tests` :657+ (imports `add_remote_error, clean_up, fetch_error`).
- `crates/zanshin-jj/src/convert.rs:720-727 finish_error` + its unit test `head_import_finish_failures_map_onto_the_repo_error_taxonomy` -- the pattern to mirror.
- `crates/zanshin-jj/src/op_support.rs:86-91 resolve_immutable` -- returns `MutateError::Config` only.
- `crates/zanshin-jj/src/repo.rs:2912-2930` -- `Repo::clone` `# Errors`: add the unresolvable-alias case to the `Config` bullet.
- `crates/zanshin-ffi/src/repo.rs:851-854` -- `zanshin_repo_clone` `jj.config_error` bullet; `cargo make codegen` regenerates `packages/zanshin_core/lib/src/ffi/bindings.dart` (and leaves the rest unchanged).
- `docs/rust-error-codes.md:58` -- `jj.config_error` row: append "Also emitted — Story 9.57 closing run by `zanshin_repo_clone` …".
- `crates/zanshin-jj/tests/it/creation_warnings.rs` -- the single own-process test's phase list :140-153 (configured-identity section), helpers `git_with_commit` :58, `file_url` :67, `set_env`; model rows `an_unresolvable_immutable_heads_alias_refuses_the_import_at_its_head_finish` :629-664.
- Oracle (witness of the unchanged refusal/clean-up): `crates/zanshin-parity/tests/oracle/git_scenarios.rs` `CREATION_SCENARIOS` (+ `user_config: Some(UNRESOLVABLE_IMMUTABLE)`), `main.rs` `own_process:` list :245-250 and count :264, `ledger.rs` warnings entries :103-125 (add one only for an observed divergence).
- `_bmad-output/implementation-artifacts/deferred-work.md:1804-1806` -- strike the item through, `RESOLVED 2026-10-22 (spec-9-57-closing-clone-finish-config-error, commit …)`, follow-up `Done (…)`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/creation.rs` -- add `fn finish_error(e: MutateError) -> RepoError` (doc citing `cli_util.rs:2986-3002`), use it on `resolve_immutable`'s result in `finish`; inline unit test of both arms -- item 1.
- `crates/zanshin-jj/tests/it/creation_warnings.rs` -- two phases: the two unresolvable-alias clone rows of the matrix (Config code, reason names the symbol, destination as the CLI's clean-up leaves it, `outcome.left_behind` empty), `JJ_CONFIG` restored to `""` after each -- Rust witness.
- `crates/zanshin-parity/tests/oracle/{git_scenarios.rs,main.rs,ledger.rs}` -- creation scenario `clone_unresolvable_immutable` (SOURCE, `git clone src dest`, the unresolvable user config) in the `own_process:` list, count 195; ledger entry only for a divergence the run observes, with its reason -- parity witness that the refusal and the on-disk result match.
- `crates/zanshin-jj/src/repo.rs`, `crates/zanshin-ffi/src/repo.rs`, `docs/rust-error-codes.md`, then `cargo make codegen` -- docs -- registry.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- resolve the item -- ledger.

**Acceptance Criteria:**
- Given an unresolvable `immutable_heads()` alias, when `Repo::clone` runs, then it returns `RepoError::Config` (FFI `jj.config_error` via the existing `map_repo_err`) and the disk is as the CLI's `clean_up_dirs` leaves it.
- Given the oracle scenario `clone_unresolvable_immutable`, when it runs against the pinned `jj git clone`, then the ledger reports no UNEXPECTED / CHANGED / STALE.
- Given the docs, when read, then `Repo::clone`, `zanshin_repo_clone` (and its generated binding) and the `jj.config_error` row name the unresolvable alias at a clone finish.

## Spec Change Log

## Review Triage Log

### 2026-10-22 — Review pass
- verdicts: 19 findings (the blind layer's sprint-status / ffi-abi bullet logged as two) — high 0, medium 0, low 14, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) the new docs claim `context` names the alias and the symbol, but the reason is `resolve_immutable`'s jj-lib resolution error, naming only the symbol — `Repo::clone`, `zanshin_repo_clone` (+ regenerated header/bindings) and the registry sentence now say the unresolved symbol. The missing CLI prefix ("Invalid `revset-aliases.immutable_heads()`") is shared by every verb's `resolve_immutable` — pre-existing, added to `deferred:`.
  - `[low]` `[reject]` (blind) `finish_error`'s non-`Config` arm is unreachable (its only input always returns `Config`) — the match on `MutateError` must be exhaustive; the catch-all mirrors `convert.rs::finish_error` and keeps the mapping correct if `resolve_immutable` ever widens; the alternatives (`unreachable!`, a stringly `RepoError::Config` from `Display`) are worse; sharing one helper across two crates' modules with different failure variants is a refactor, not a correction.
  - `[false]` `[reject]` (blind) "mapped as convert's head-import finish does" is only partly true because clone's `finish_transaction` errors still go to `clone_failed` — `finish_transaction` never returns `MutateError::Config` (documented errors: `Backend`, `NotAGitRepo`), so no error is classified differently from convert's.
  - `[low]` `[patch]` (blind) the mapping also covers the checkout finish, outside the clean-up scope, where a refusal keeps the workspace — reachable only for an alias that resolves on the empty repo but not after the fetch (e.g. a commit-id prefix turning ambiguous); the CLI keeps the workspace there too. The three doc sites now say so.
  - `[low]` `[patch]` (blind) the deferred-work RESOLVED note lists the oracle scenario as a witness of the code change, but the oracle never compares codes — reworded: the code is pinned by the Rust tests; the scenario witnesses that refusal and clean-up stay CLI-equal.
  - `[low]` `[reject]` (blind) the oracle does not cover the existing-empty-destination clean-up — `clean_up` is unchanged code with its own unit test (`clean_up_removes_what_the_clone_created_and_reports_a_failure`) and the Rust row; a second own-process oracle scenario adds no witness of this item's change.
  - `[low]` `[patch]` (blind) the "colocated" row relied on the `git.colocate` default — passes `Some(true)` now.
  - `[low]` `[patch]` (blind) the CLI citation names only `rebase_mutable_descendants` (`:2986-3002`) — `resolve_immutable_expression` (`cli_util.rs:1146-1167`), where the config error is raised, is cited too.
  - `[false]` `[reject]` (blind) `sprint-status.yaml`'s 9.57 line still lists the clone deferral — that line records what Story 9.57's run deferred (history, accurate); closing runs record their outcome in their spec and deferred-work.md (no closing run has edited sprint-status).
  - `[low]` `[patch]` (blind) `docs/ffi-abi.md`'s `zanshin_repo_clone` story trail lacks this run — "9.57 closing run" added.
  - `[false]` `[reject]` (blind) the spec is not in the reviewed diff — by design: the spec is the change's own account and goes to the edge-case layer only.
  - `[low]` `[reject]` (blind) no FFI/Dart end-to-end witness of `jj.config_error` for clone — `zanshin_repo_clone` maps every `RepoError` through `map_repo_err`, whose `RepoError::Config` → `jj.config_error` arm is pinned by `crates/zanshin-ffi/src/repo.rs`'s mapping test; an FFI witness needs a new own-process `JJ_CONFIG` test binary module for a code path that is variant-independent.
  - `[low]` `[patch]` (edge) the docs promise the alias in `context` — same root cause as the first blind row; fixed with it.
  - `[low]` `[patch]` (edge) a refusal at the checkout finish keeps the workspace, contrary to the docs — same as the blind row; fixed with it.
  - `[low]` `[patch]` (edge) the colocated row passes `colocate: None` — same as the blind row; fixed with it.
  - `[low]` `[reject]` (intent) the FFI code is asserted in docs, not tested at the FFI surface — same as the blind FFI-witness row; rejected with it.
  - `[low]` `[patch]` (intent) the oracle cannot see the item's subject (the code) — same as the blind deferred-work-wording row; the oracle's role is stated correctly now.
  - `[false]` `[reject]` (intent) `finish_error`'s other arm is reached only by a fabricated input — duplicate of the blind dead-arm row, rejected there; the unit test pins the exhaustive mapping, which is all it claims.
  - `[false]` `[reject]` (intent) Auto Run Result, verification outcomes and the commit hash are missing — written at finalize; the 0-vs-7 warning ledger entry is the known start-up template-parse gap (Story 9.56 closing run's deferral, already in deferred-work.md), not a new finding.

## Verification

**Commands (targeted; the story loop runs the full gate):**
- `cargo test -p zanshin-jj --lib creation::` and `cargo test -p zanshin-jj --test it creation_warnings::` -- expected: green.
- `cargo test -p zanshin-jj` -- expected: green.
- `cargo test -p zanshin-ffi` -- expected: green (dependent; doc-only change there).
- `cargo test -p zanshin-parity --test oracle` -- expected: green, no UNEXPECTED / CHANGED / STALE.
- `cargo make codegen` -- expected: only `bindings.dart`'s copied doc changes; a re-run leaves the tree clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed .` -- expected: clean (generated doc only).

**Verification notes (run 2026-10-22, after the review patches; no `cargo make test` / `test-full` / `coverage` per the loop's gate rule):**
- `cargo fmt --all --check` — clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 307 lib + 1016 `it` passed (1 pre-existing ignored perf benchmark); incl. `creation::tests::clone_finish_failures_map_onto_the_repo_error_taxonomy` and the two new phases of `creation_warnings::creation_paths_report_what_the_cli_prints`.
- `cargo test -p zanshin-ffi` — 196 lib + 307 `it` passed (dependent; doc-only change).
- `cargo test -p zanshin-parity --test oracle` — 209 passed (195 scenarios, incl. own-process `clone_unresolvable_immutable`), no UNEXPECTED / CHANGED / STALE.
- `cargo make codegen` — regenerated `zanshin_ffi.h` / `bindings.dart` doc lines only; a re-run leaves the tree unchanged.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed .` — 0 changed.
- Manual: the pinned `jj git clone` under the same user config prints 7 short-prefix warnings, then "Config error: Invalid `revset-aliases.immutable_heads()`", exits 1 and removes `dest` (implementation run).
- Coverage not measured (loop gate rule); the one new production fn `finish_error` is covered by its unit test (both arms) and the two integration rows.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (cee2f0d93368ba10041f462a022b893916a87a4f).** Verified real at `35c42ce`: clone's `finish` (`creation.rs:488-489`) mapped `resolve_immutable`'s `MutateError::Config` to `clone_failed` → `jj.jj_lib_error`, while the CLI's `tx.finish` → `rebase_mutable_descendants` → `resolve_immutable_expression` raises a config error. Now `creation::finish_error` maps `Config` → `RepoError::Config` (`jj.config_error`), anything else → `CloneFailed`, as `convert`'s head-import finish. The refusal point (the first finish with changes, `add git remote <name>`, inside the clean-up scope), the clean-up and the warnings are unchanged. Witnesses: unit test, `creation_warnings` rows (non-colocated new destination removed; colocated existing empty directory left empty), oracle `clone_unresolvable_immutable` (refusal + clean-up CLI-equal; ledgered only for the CLI's 7 start-up template warnings, the known 9.56-closing-run gap).

**New finding (deferred, mirrored into deferred-work.md):** `resolve_immutable`'s `Config` reason lacks the CLI's "Invalid `revset-aliases.immutable_heads()`" prefix, for every verb — see `deferred:`.

**Files changed (cee2f0d):**
- `crates/zanshin-jj/src/creation.rs` — `finish_error` + its unit test; clone's `finish` uses it for the immutable-set resolution.
- `crates/zanshin-jj/src/repo.rs` — `Repo::clone` `# Errors`: the unresolvable alias under `Config`.
- `crates/zanshin-jj/tests/it/creation_warnings.rs` — two clone rows under an unresolvable alias.
- `crates/zanshin-parity/tests/oracle/{git_scenarios,main,ledger,harness}.rs` — scenario `clone_unresolvable_immutable` (own process, count 195), its warnings ledger entry, `created()` reports a removed target instead of panicking.
- `crates/zanshin-ffi/src/repo.rs` + generated `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart` — `zanshin_repo_clone`'s `jj.config_error` bullet.
- `docs/rust-error-codes.md` (`jj.config_error` emitter), `docs/ffi-abi.md` (clone story trail).
- `_bmad-output/implementation-artifacts/deferred-work.md` — item resolved; the new finding mirrored (spec commit).

**Review:** 19 findings (low 14, false 5). Patched (all low): docs said `context` names the alias (it names the symbol); a refusal at the checkout finish keeps the workspace (documented); CLI citation `:1146-1167` added; colocated row passes `Some(true)`; deferred-work note no longer claims the oracle witnesses the code; ffi-abi story trail. Deferred: the missing CLI message prefix (new, pre-existing). Rejected: `finish_error`'s exhaustive catch-all arm (mirrors convert, match must be exhaustive), oracle row for an existing empty destination (unchanged `clean_up`, unit-tested), no FFI end-to-end witness (variant-independent `map_repo_err`, mapping pinned), plus the false rows in the triage log.

**Follow-up review recommended:** false — patched counts high 0, medium 0, low 9 entries.

**Residual risks:** coverage ratchet not run (loop gate at the end); the `jj.config_error` code at the FFI surface is pinned via `map_repo_err`'s mapping test, not a clone-specific FFI test; `context` still differs from the CLI's text (deferred).
