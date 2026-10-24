---
title: 'Fix-up after the 9.10–9.18 loop — coverage regressions in bookmark_ops.rs and drop_actions.rs'
type: 'chore'
created: '2026-10-24'
status: 'done'
baseline_revision: 'ffdf0053b6582012f5af8209ca110baeaa9d97fd'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The story loop's final `cargo make test` (9.10, 9.11, 9.13, 9.14, 9.17, 9.18) fails only in its coverage step (failure 1): `crates/zanshin-jj/src/bookmark_ops.rs` 99.88% < 100.00% (line 1226 never runs) and `crates/zanshin-jj/src/drop_actions.rs` 99.52% < 99.75% (lines 327 and 584 never run).

**Approach:** Add an integration test for each reachable line — a pattern `bookmark_track` with no `remotes` on a Git-backed repo whose `git` remote has no view (line 1226, Story 9.11's matcher), and a `change_actions` query whose squash row fails with a jj-lib store error (line 584, the `?` that hands a `Backend` error up). Line 327 is the implicit `else` of the Revert row's `if plan.is_some()` (Story 9.18 closing, 3aba05a); a row reverts exactly one resolved change, so `plan_revert` never returns `None` there — the row resolves the immutable set through the plan's `Option` without a dead branch, behavior unchanged.

## Boundaries & Constraints

**Always:** Tests in `crates/zanshin-jj/tests/it/bookmark_tracking.rs` / `tests/it/drop_actions.rs`, each calling `test_helpers::pin_test_env()` (directly or via the fixture's `base()`); each new test proven to execute its line (fails when that branch is temporarily broken, then restored); the Revert row's observable outcome is unchanged (Available / Refused exactly as before, immutable set resolved only for a plan that writes).

**Never:** No lowered `coverage-baseline.txt` entry, no `exclude_prefix`, no change to other verbs or files; no full `cargo make test` / `test-full` / `coverage` in this run (orchestrator rule — it reruns the gate itself).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Track pattern, no `git` view | Git-backed repo, `y@origin` untracked, no `git` remote view; `bookmark_track(["y"], [])` | `y@origin` tracked, description `track remote bookmark y@origin`, no warnings | — |
| Squash row store failure | `B`'s root tree object removed from the git store; `change_actions(B)` | the query fails with `MutateError::Backend` (the rows before squash plan without reading `B`'s tree) | error propagated, no operation written |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/bookmark_ops.rs:1218-1227` -- `track_or_untrack`: `ignored` = `default_ignored_remote` filtered by a `git` remote view; with no `remotes` and `ignored == None` the remote expression is `StringExpression::all()` (1226). Existing pattern tests always give `remotes` or set `x@git` (which creates the `git` view).
- `crates/zanshin-jj/tests/it/bookmark_tracking.rs` -- fixture `base()` from `bookmark_move.rs` (non-colocated Git-backed, no `git` view until `set_remote(.., "git", ..)`); helpers `names`, `remote`, `head_op`, `fx.set_remote`, `fx.kinds()`.
- `crates/zanshin-jj/src/drop_actions.rs:315-333` -- `Rows::revert`: `plan_revert(...)?` then `if plan.is_some() { resolve_immutable(...)?; }`; `revert.rs:86-109` `plan_revert` returns `None` only for an empty `to_revert`, impossible for one resolved `ChangeId` (`op_support.rs:665` `resolve_ordered` errors on an unknown id).
- `crates/zanshin-jj/src/drop_actions.rs:559-591` -- `change_actions`; `outcome` (192-212) passes `Backend`/`Precondition` up as `Err`, so the squash row's `?` (584) runs only on such an error. `squash_split.rs:281` `plan_squash` diffs the source's parent tree against its tree (`SelectedTree::from_paths`) — the first tree-object read of the seven rows.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- fixture `base(None)`: `root → A → B → C`, `D` child of `A` = `@`; helpers `load`, `hex`, `head_op`. Precedent for removing a loose object: `tests/it/revset.rs:1058-1083`.
- `coverage-baseline.txt:50,63` -- `bookmark_ops.rs = 100.00`, `drop_actions.rs = 99.75` (the pre-loop gap was line 584).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/bookmark_tracking.rs` -- add `track_a_pattern_without_a_git_view_matches_every_remote` (I/O row 1) -- executes line 1226.
- `crates/zanshin-jj/src/drop_actions.rs` -- in `Rows::revert`, resolve the immutable set via `plan.as_ref().map(|_| resolve_immutable(..)).transpose()?` (comment kept: only a writing plan reaches the CLI's finish) -- removes the unreachable implicit `else` (line 327), no behavior change.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- add `change_actions_fails_when_the_squash_row_cannot_read_the_tree` (I/O row 2) -- executes line 584.

**Acceptance Criteria:**
- Given the new tests, when each is run by name, then it passes; and with its target branch temporarily broken (1226's expression swapped, 584's `?` replaced by a panic), it fails.
- Given the change, when `cargo test -p zanshin-jj --test it drop_actions` runs, then every existing drop-actions test still passes (Revert rows unchanged).
- Given the change, when `cargo clippy -p zanshin-jj --all-targets -- -D warnings` and `cargo fmt --all --check` run, then both are clean.

## Spec Change Log

- 2026-10-24 (build): I/O row 2 removes `A`'s commit object, not `B`'s root tree — `change_actions`' squash row selects the whole commit (`EverythingMatcher`, `restore_tree` keeps the tree ids), so no row reads a tree and the original test passed without an error. `A` (the squash destination) is read first by the squash row (probe: its `?` replaced by a panic → `Backend("Object … of type commit not found")`). Test renamed `change_actions_fails_when_the_squash_row_cannot_read_the_parent`.

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 10, false 7, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) the Revert row's `.map(..).transpose()?` hides the unreachable `None` path instead of stating the invariant — the comment now says a row reverts exactly one resolved change, so `plan_revert` never returns `None` there, and that the `Option` form keeps the CLI's rule (only a writing plan resolves the set); code unchanged (behavior-identical, CLI parity kept should a multi-revision row ever exist).
  - `[low]` `[patch]` (blind) `no_op: plan.is_none()` and the "never reaches it" comment read as if a no-op revert row were reachable — same root cause and comment fix as the row above.
  - `[low]` `[reject]` (blind) the combinator form reads harder than the sibling `if`/`?` sites — cosmetic; the clarified comment explains it, and a plain `if` reintroduces the never-taken branch.
  - `[low]` `[reject]` (blind) the bookmark test never asserts the fixture has no `git` view — a fixture change that adds one drops line 1226 again, which the coverage ratchet reports loudly; the guard needs a jj-lib view probe (more than a direct correction) for an unlikely change.
  - `[low]` `[reject]` (blind) "every remote" shown with one remote only — with no `git` view `all()` and "all but `git`" match the same remotes, so a second remote proves nothing more; renaming is cosmetic.
  - `[low]` `[reject]` (blind) the squash-row test does not show which row failed — if an earlier row ever reads `A` first, the coverage ratchet flags line 584 again; the test's doc names the jj-lib-pin dependence and the build probe attributed it.
  - `[false]` `[reject]` (blind) hard-coded loose-object path — if the object is packed, `remove_file(..).expect(..)` fails loudly, it never passes silently; same pattern as the `revset.rs:1058-1083` precedent.
  - `[false]` `[reject]` (blind) spec stale (matrix row 2, task test name) — fix is an edit to this build's spec; the Spec Change Log records the deviation and the Auto Run Result names the real test.
  - `[false]` `[reject]` (blind) `coverage-baseline.txt` not in the diff — the intent forbids running coverage in this run; the orchestrator's gate rerun auto-raises and stamps the baseline.
  - `[low]` `[patch]` (edge) the pattern track's merge into local `y` is not asserted — added `assert_eq!(fx.normal("y"), Some(d_hex))`.
  - `[false]` `[reject]` (edge) swapping 1226's expression for `exact("git").negated()` keeps the test green — that mutant is observationally identical where line 1226 runs (no `git` view exists); the build probe's non-equivalent swap (`exact("PROBE")`) failed the test as the AC requires.
  - `[false]` `[reject]` (edge) the spec's task test name finds nothing — spec edit; the Change Log records the rename.
  - `[false]` `[reject]` (verification-gap, other) spec matrix/task stale — spec edit, as above.
  - `[low]` `[patch]` (intent) line 327 fixed by reshaping production code, not by a test — the `None` path is unreachable for a row (one resolved `ChangeId` → non-empty `to_revert`, `revert.rs:86-109`), so no test can run it; grouped with the first row: the invariant is now stated in the code comment. No baseline lowered, no `exclude_prefix`.
  - `[low]` `[patch]` (intent) no break-and-restore proof for 327 — no test can exist for an unreachable path; grouped with the first row (comment states why).
  - `[low]` `[reject]` (intent) the 584 test does not attribute the error to the squash row — same as the blind row above (ratchet catches a move; probe attributed it).
  - `[false]` `[reject]` (intent) no `## Auto Run Result`, nothing committed — written and committed at finalize below.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it bookmark_tracking::track_a_pattern_without_a_git_view_matches_every_remote` -- expected: 1 passed
- `cargo test -p zanshin-jj --test it drop_actions` -- expected: all passed
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at ffdf005):**
1. coverage — FIXED by bff2904 (pending the orchestrator's gate rerun, which this run must not start):
   - `bookmark_ops.rs:1226` (`StringExpression::all()`, Story 9.11): new test `bookmark_tracking::track_a_pattern_without_a_git_view_matches_every_remote` tracks the pattern `y` with no `remotes` on a Git-backed repo whose `git` remote has no view. Proven: with the line swapped to `exact("PROBE")` the test fails (`y@origin` stays untracked); restored.
   - `drop_actions.rs:584` (the squash row's `?` in `change_actions`): this was the pre-loop gap behind the 99.75 baseline (3aba05a did not touch `change_actions`); it is reachable. New test `drop_actions::change_actions_fails_when_the_squash_row_cannot_read_the_parent` removes `A`'s loose commit object; the squash row (first to read its destination `A`) fails with `MutateError::Backend`, no operation written. Proven: with that `?` replaced by a panic the test panics with `Backend("Object … of type commit not found")`; restored. (Removing `B`'s tree, as first planned, fails nothing — the whole-commit squash reads no tree; see Spec Change Log.)
   - `drop_actions.rs:327` (Story 9.18 closing, 3aba05a): the count-0 line is the implicit `else` of `if plan.is_some()`, not the `?` error path (that path runs: `an_unresolvable_alias_refuses_the_unguarded_rows` refuses the Revert row as `Config`). A row reverts exactly one resolved change, so `plan_revert` never returns `None` there and no test can take the branch. The row now resolves the set via `plan.as_ref().map(..).transpose()?` — same behavior (resolved only for a writing plan, error propagated), the invariant stated in the comment. No baseline lowered, no `exclude_prefix`.
   Expected after the gate: `bookmark_ops.rs` 100.00, `drop_actions.rs` 100.00 (baseline auto-raised from 99.75 — the gate's raise must be committed).

**Files changed:** `crates/zanshin-jj/src/drop_actions.rs` (Revert row: Option form + comment), `crates/zanshin-jj/tests/it/bookmark_tracking.rs` (1 test), `crates/zanshin-jj/tests/it/drop_actions.rs` (1 test), this spec.

**Review:** 17 findings — 6 patched (one root cause: the Revert row's unstated invariant → comment; plus the local-merge assertion in the bookmark test), 0 deferred, 11 rejected with reasons in the triage log (7 false, 4 low). Follow-up review: false (patched: 0 high, 0 medium, 6 low).

**Verification:** both new tests pass by name; `cargo test -p zanshin-jj --test it -- bookmark_tracking drop_actions revert` 98 passed; `cargo clippy -p zanshin-jj --all-targets -- -D warnings` clean; `cargo fmt --all --check` clean. Full `cargo make test` / coverage NOT run (orchestrator rule).

**Residual risk:** the squash-row test depends on jj-lib 0.46 reading `A` first in the squash row; a pin bump could move the failure to an earlier row (the ratchet would then flag line 584 again). The spec's I/O row 2 / task name still say "`B`'s tree" / `..._cannot_read_the_tree` (intent-contract read-only); the Change Log and this result give the real test.
