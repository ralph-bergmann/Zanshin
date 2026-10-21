---
title: 'Fix-up after the 9.24/9.30/9.31 loop — coverage regressions in config.rs and remotes.rs'
type: 'chore'
created: '2026-10-21'
status: 'done'
baseline_revision: '2d86289c7d955b21cadaeaa7b8c1c9f897994580'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred:
  - summary: >-
      fetch_error maps GitFetchError::RejectedUpdates to MutateError::Backend, where the CLI treats it as a user error.
    evidence: |-
      jj-cli v0.46.0 cli/src/command_error.rs:590 maps `RejectedUpdates(_) | Subprocess(_)` to user_error; Zanshin's fetch_error sends every unmapped variant to mutate::be (Backend). Pre-existing since Story 9.30; the fix-up test only witnesses today's mapping.
    location: >-
      crates/zanshin-jj/src/remotes.rs:447 fetch_error
    severity: medium
  - summary: >-
      fetch_error's GitFetchError::RemoteName arm falls through to Backend and drops the CLI's rename hint.
    evidence: |-
      CLI command_error.rs:587-588 adds "Run `jj git remote rename` to give a different name."; push_error (crates/zanshin-jj/src/push.rs:1703-1705) carries it for the same jj-lib variant, fetch_error does not. Pre-existing.
    location: >-
      crates/zanshin-jj/src/remotes.rs:447 fetch_error
    severity: low
  - summary: >-
      No test pins that a malformed git.fetch is ignored when --remote or --all-remotes is given, nor that Repo::git_fetch_remotes refuses it.
    evidence: |-
      resolve_fetch_remotes reads git.fetch only on FetchRemotes::Default (matching CLI fetch.rs:142-148); git_fetch_remotes documents MutateError::Config for a malformed git.fetch; neither is witnessed. Pre-existing test gaps.
    location: >-
      crates/zanshin-jj/tests/it/git_fetch_parity.rs
    severity: low
  - summary: >-
      resolve_fetch_remotes lists the remotes before it reads git.fetch / parses --remote, the CLI does it the other way round.
    evidence: |-
      CLI cmd_git_fetch (fetch.rs:142-150 @ v0.46.0) builds remote_expr first, then get_all_remote_names; Zanshin (remotes.rs:290) calls get_all_remote_names first and maps its failure to NotAGitRepo, so a non-Git backend with a malformed git.fetch answers NotAGitRepo where the CLI reports the config error. Pre-existing.
    location: >-
      crates/zanshin-jj/src/remotes.rs:290 resolve_fetch_remotes
    severity: low
  - summary: >-
      Never-run panic! arms in the loop's new test helpers keep remote_changes.rs and drop_actions.rs below 100% in the new baseline.
    evidence: |-
      crates/zanshin-jj/src/remote_changes.rs:319 and :477 and crates/zanshin-jj/src/drop_actions.rs:463 use let-else/match panic fallbacks; baseline entries 99.31 / 99.32 freeze those uncovered lines. Above the 80% floor, gate green.
    location: >-
      crates/zanshin-jj/src/remote_changes.rs, crates/zanshin-jj/src/drop_actions.rs
    severity: low
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` fails only in its coverage step: `crates/zanshin-jj/src/config.rs` 99.85% and `crates/zanshin-jj/src/remotes.rs` 98.37%, both below their 100.00% baseline. Uncovered at HEAD 2d86289: config.rs 3893, 3955, 3968 (never-taken `panic!` arms inside inline tests — a `match` fallback and two `let … else { panic!() }`); remotes.rs 308 (the `?` of `default_remotes` in `resolve_fetch_remotes`, i.e. a malformed `git.fetch`), 449–451 and 456 (`fetch_error`'s `NoSuchRemote` arm and its catch-all `other => mutate::be(other)` arm).

**Approach:** Add tests that run the uncovered production branches of remotes.rs, and rewrite the three config.rs test assertions so their failure path is an `assert!(matches!(…))` message instead of a dedicated never-run `panic!` line — same checks, no lost assertion.

## Boundaries & Constraints

**Always:** Tests only (plus the auto-raised `coverage-baseline.txt` the gate writes). Inline unit tests for private items stay in the module's `#[cfg(test)] mod tests`; integration tests go in `crates/zanshin-jj/tests/it/git_fetch_parity.rs` (the existing one-binary layout) and call `test_helpers::pin_test_env()` via the existing `Fx::new`. Each rewritten config.rs assertion checks exactly what it checked before (the error variant and the reason prefix).

**Never:** No production-code change, no lowered baseline, no `exclude_prefix`, no edits to unrelated tests or files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Malformed `git.fetch` | Repo with remote `origin`, repo config `git.fetch = 1`; `Repo::git_fetch(GitFetchArgs::default())` | `Err(MutateError::Config { .. })`; head operation unchanged | refusal, no op written |
| Remote vanished before its fetch | `fetch_error(GitFetchError::NoSuchRemote("gone"), None)` | `MutateError::RemoteNotFound { name: "gone" }` | mapped |
| Any other fetch failure | `fetch_error(GitFetchError::RejectedUpdates(vec!["refs/heads/main"]), None)` | `MutateError::Backend(_)` carrying the jj-lib Display ("Failed to update refs: …") | mapped |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:3885-3894` -- test `remote_fetch_expression_parses_the_named_field_or_reports_none`: `match … { Err(ConfigError::Load { reason }) => assert!(prefix), other => panic!(..) }` → line 3893 uncovered.
- `crates/zanshin-jj/src/config.rs:3951-3972` -- test `new_bookmark_matchers_refuse_a_broken_field_with_the_cli_text`: two `let Err(crate::ConfigError::Load { reason }) = … else { panic!(..) };` → lines 3955, 3968 uncovered.
- `crates/zanshin-jj/src/remotes.rs:283-317` -- `resolve_fetch_remotes`; line 308 `)?` after `crate::push::default_remotes(..)` — Err when `crate::config::git_fetch_remotes` (config.rs:1619, `remote_name_patterns`) refuses a non-string/non-list `git.fetch` (`value_error` → `mutate::cfg` → `MutateError::Config`).
- `crates/zanshin-jj/src/remotes.rs:447-458` -- private `fetch_error(e: GitFetchError, cancel: Option<&CancelGuard>)`; arms `NoSuchRemote(name)` → `RemoteNotFound { name }`, `other` → `mutate::be` (= `MutateError::Backend(e.to_string())`, mutate.rs:432).
- `crates/zanshin-jj/src/remotes.rs:578` -- inline `mod tests` (add the `fetch_error` unit test here).
- jj-lib 0.46.0 `git.rs:2908` -- `GitFetchError { NoSuchRemote(RemoteNameBuf), RemoteName(..), RejectedUpdates(Vec<GitRefNameBuf>), Subprocess(..) }`.
- `crates/zanshin-jj/tests/it/git_fetch_parity.rs` -- `Fx::new`, `Fx::set(key, toml)`, `Fx::fetch`, `Fx::head_op`; sibling `a_malformed_remote_fetch_setting_is_a_config_error` (line ~500) is the template for the new test.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- rewrite the three panic-arm assertions as `let result = …; assert!(matches!(&result, Err(ConfigError::Load { reason }) if reason.starts_with("…")), "{result:?}");` -- same checks, no never-run line.
- `crates/zanshin-jj/src/remotes.rs` -- add inline test `fetch_failures_map_to_their_mutate_errors` covering the two `fetch_error` rows of the matrix -- covers 449–451, 456.
- `crates/zanshin-jj/tests/it/git_fetch_parity.rs` -- add `a_malformed_git_fetch_setting_is_a_config_error` (matrix row 1) -- covers 308.

**Acceptance Criteria:**
- Given the changes, when `cargo make coverage` runs, then config.rs and remotes.rs report 100.00% and no file regresses.
- Given the changes, when `cargo make test` runs, then every step passes and any auto-raised `coverage-baseline.txt` is committed with the tests.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 15 findings — high 0, medium 1, low 9, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (edge-case) `a_malformed_git_fetch_setting_is_a_config_error` accepts any `MutateError::Config`, so another config refusal would pass it — narrowed to `Config { reason } if reason.contains("git.fetch")` (1141db4).
  - `[medium]` `[defer]` (blind) `RejectedUpdates` maps to `Backend`, CLI says user_error (command_error.rs:590) — pre-existing Story 9.30 mapping, the test only witnesses it; deferred.
  - `[low]` `[defer]` (blind) `RemoteName` arm drops the CLI rename hint that `push_error` keeps — pre-existing; deferred.
  - `[low]` `[patch]` (blind) the new unit test's doc claims both errors are unreachable through a fixture, true only for `NoSuchRemote` — doc corrected (1141db4).
  - `[low]` `[patch]` (blind) the malformed-git.fetch test checks only the variant, its sibling also checks the text — same root cause as the edge-case row; fixed by the same narrowing (1141db4).
  - `[low]` `[defer]` (blind) no test that a malformed `git.fetch` is ignored under `--remote` / `--all-remotes` — pre-existing behavior gap, correct in code (remotes.rs `FetchRemotes::Named`/`All` skip `default_remotes`); deferred.
  - `[low]` `[defer]` (blind) `Repo::git_fetch_remotes` not witnessed for a malformed `git.fetch` — pre-existing; deferred (grouped with the row above in the frontmatter item).
  - `[low]` `[defer]` (blind) remotes listed before `git.fetch` is read, CLI reads first (fetch.rs:142-150) — verified; only a non-Git backend with a malformed `git.fetch` diverges (`NotAGitRepo` vs config error); pre-existing; deferred.
  - `[low]` `[defer]` (blind) never-run `panic!` arms remain in `remote_changes.rs:319,:477` and `drop_actions.rs:463`, frozen at 99.31/99.32 — loop's own files, above the floor, gate green; deferred.
  - `[false]` `[reject]` (blind) spec uncommitted / baseline scope not recorded — the spec is committed at finalize; the spec's Always allows the gate-written baseline, and the five new-file entries are what a green gate writes for files the red loop gate never stamped.
  - `[false]` `[reject]` (intent) config.rs recovered by removing lines, not adding tests — the uncovered lines were never-run `panic!` fallbacks inside `#[cfg(test)]`, the cause itself; same checks kept, no baseline lowered, no exclude_prefix.
  - `[low]` `[reject]` (intent) `fetch_error` tested in isolation, not through the fetch loop — the mapping is a pure fn; an end-to-end `RejectedUpdates` needs a fabricated ref-lock fixture for no extra line; not worth the added fixture.
  - `[false]` `[reject]` (intent) baseline additions not needed by the failures — the intent asks to commit the raised baseline the green gate writes; no existing entry changed.
  - `[false]` `[reject]` (intent) `## Auto Run Result` absent at review time — written at finalize, below.
  - `[false]` `[reject]` (intent) green gate not shown / stamp tree hash differs — `cargo make test` exited 0 twice in this run (after 492220f and after the patch); the stamp hashes the working tree incl. the then-untracked spec.

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test`):**
1. coverage — FIXED by 492220f (tests + gate-raised `coverage-baseline.txt`), tightened by review patch 1141db4. `config.rs`: the three uncovered lines were never-run `panic!` fallbacks in inline tests (3893 `match` arm, 3955/3968 `let … else`); rewritten as `assert!(matches!(… if reason.starts_with(…)))` with the same checks. `remotes.rs`: 308 covered by `tests/it/git_fetch_parity.rs::a_malformed_git_fetch_setting_is_a_config_error` (`git.fetch = 1` → `Config` refusal naming `git.fetch`, no operation written); 449–451 and 456 covered by inline `remotes::tests::fetch_failures_map_to_their_mutate_errors` (`NoSuchRemote` → `RemoteNotFound`, `RejectedUpdates` → `Backend` with jj-lib's text). Both files are back at 100.00%; the gate added baseline entries for the loop's five new files (zanshin-ffi `drop_actions.rs` 100.00, zanshin-jj `drop_actions.rs` 99.32, `duplicate.rs` 92.59, `rebase.rs` 99.19, `remote_changes.rs` 99.31). No entry lowered, no exclude_prefix.

**Files changed:** `crates/zanshin-jj/src/config.rs` (three test assertions), `crates/zanshin-jj/src/remotes.rs` (new inline test), `crates/zanshin-jj/tests/it/git_fetch_parity.rs` (new integration test), `coverage-baseline.txt` (gate-raised).

**Review:** 2 patches applied (one low group of two rows, one low doc fix), 5 deferred (1 medium, 4 low; mirrored in deferred-work.md), 6 rejected (5 false, 1 low) with reasons in the triage log. Follow-up review: false (patched: 0 high, 0 medium, 3 low rows).

**Verification:** targeted `cargo test` of the touched tests passed; `cargo make test` exit 0 after 492220f and again after 1141db4 (`coverage-check: OK — coverage held at 99.16%`, extern-coverage OK, gate-stamp written).

**Residual risk:** the `git_fetch_parity` fixtures commit with the user's git signing; with 1Password locked they fail outside the gate's environment (the implementation subagent hit this with a direct `cargo test`; both gate runs passed).

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- remotes::tests config::tests` -- expected: pass
- `cargo test -p zanshin-jj --test it -- git_fetch_parity` -- expected: pass
- `cargo make test` -- expected: green, config.rs and remotes.rs at 100.00%
