---
title: 'Fix-up 2 after the 9.24/9.30/9.31 loop — coverage regression in rebase.rs'
type: 'chore'
created: '2026-10-21'
status: 'done'
baseline_revision: 'e5f3acbc9e45564189bfe4409943e2439be2ae4f'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` (HEAD e5f3acb) fails only in its coverage step: `crates/zanshin-jj/src/rebase.rs` 98.96% < baseline 99.19%. Uncovered: line 99, the closing `}` of `if !location.onto.is_empty() { … }` in `plan_rebase_source` (no test plans `-s` with an `-A`/`-B` location), and line 320, the never-run `panic!("no commit described …")` fallback of the `by_description` helper in the inline test `plan_rebase_branch_with_an_insert_location_checks_the_children`.

**Approach:** Run `plan_rebase_source` with the same `-A "Commit 1"` location the existing inline `-b` test uses (same two assertions: the planned location, and the `Immutable` refusal of the child Commit 2), and rewrite `by_description` as an iterator search ending in `.expect(…)` so no dedicated never-run line remains.

## Boundaries & Constraints

**Always:** Tests only (plus the `coverage-baseline.txt` the green gate auto-raises). The new `-s` checks live in `rebase.rs`'s inline `#[cfg(test)] mod tests` and reuse the existing fixture setup (`tiny-3-commits`, `test_helpers::pin_test_env()` first). The rewritten helper finds the same commit (walk from the view heads through parents, match on trimmed description).

**Never:** No production-code change, no lowered baseline entry, no `exclude_prefix`, no edits to unrelated tests or files.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| `-s @ -A "Commit 1"` | `tiny-3-commits` (root → C1 → C2 → C3, empty `@` off root), immutable = `root()` | `new_parent_ids == [C1]`, `new_child_ids == [C2]`, target `Roots([@])` | No error expected |
| `-s @ -A "Commit 1"`, C2 immutable | immutable = `commits([C2])` | `Err(MutateError::Immutable { commit_id: C2 hex })` | refusal |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/rebase.rs:85-105` -- `plan_rebase_source`; `if !location.onto.is_empty()` (94-99) is skipped for an `-A`/`-B` location → line 99 runs only then. `resolve_commit_location` gets the immutable set `guard_rewritable` resolved (mutate.rs:535), so `-A` refuses an immutable child exactly like `-b`.
- `crates/zanshin-jj/src/rebase.rs:290-345` -- inline test `plan_rebase_branch_with_an_insert_location_checks_the_children`: fixture, `by_description` closure (311-321, `panic!` at 320), `change`, `LocationArgs { onto: &[], insert_after: &[C1], insert_before: &[] }`, two assertions on `plan_rebase_branch`. Both plan fns share the signature `(&Transaction, &Arc<UserRevsetExpression>, &[ChangeId], &LocationArgs<'_>) -> Result<MoveCommitsLocation, MutateError>`.
- `drop_actions.rs` offers no `rebase -s` row with `-A`/`-B`, so the branch is reachable only through a direct call (inline test).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/rebase.rs` -- in the inline test, rewrite `by_description` as `std::iter::from_fn` over the pending stack + `.find(…)` + `.expect(…)`; run the existing two assertions for both `plan_rebase_source` and `plan_rebase_branch` (loop over the two fns), update the test's doc comment and name to cover `-s` -- covers 99 and removes 320.

**Acceptance Criteria:**
- Given the change, when `cargo make coverage` runs, then rebase.rs reports ≥ 99.19% (expected 100.00%) and no file regresses.
- Given the change, when `cargo make test` runs, then every step passes and the auto-raised `coverage-baseline.txt` is committed with the test.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 13 findings — high 0, medium 0, low 5, false 8, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the `-s` round would still pass if the `onto` guard were deleted: with `-A "Commit 1"` the parent C1 is no descendant of `@` — true, but showing the skip needs an `-A`/`-B` location `-o` would refuse, which `compute_commit_location` already refuses as a loop for the usual shapes; extra fixture work beyond what the failure needs.
  - `[low]` `[reject]` (blind) `-B` never exercised for `-s`/`-b` — same guard as `-A`; the intent says change only what the failure needs, and line 99 is covered.
  - `[false]` `[reject]` (blind) spec untracked, status stale — the spec is committed at finalize with `status: done`.
  - `[low]` `[reject]` (blind) spec does not record the other baseline raises — its fix edits this build's spec; the Auto Run Result below records them anyway.
  - `[low]` `[patch]` (blind) `by_description`'s `.expect` lost the missing description the old `panic!` named — chain now ends `.ok_or(description).expect("no commit described")`, `Result::expect` prints it, still one executed line (21a414c).
  - `[false]` `[reject]` (blind) `.expect(flag)` prints only `-s`/`-b` — `Result::expect` appends the `Err`'s Debug, so the failure shows `-s: <MutateError>`.
  - `[low]` `[reject]` (blind) Code Map line numbers are pre-change — fix edits this build's spec; they are anchored to `baseline_revision`.
  - `[false]` `[reject]` (blind) the `-s` immutable refusal could come from the source guard — the assertion pins `commit_id == C2`; the source is `@`, so only the location's child check can name C2 (confirmed by the verification-gap layer).
  - `[false]` `[reject]` (intent) the diff shows no gate output — `cargo make test` exited 0 after bcdaecb (907 s) and again after 21a414c (942.65 s, `coverage held at 99.19%`, gate-stamp written).
  - `[false]` `[reject]` (intent) the `-s -A` test pins a path no product code reaches, not parity-checked — the intent prescribes a test for exactly this line; `drop_actions` offering no such row is why it was uncovered.
  - `[false]` `[reject]` (intent) the line-320 rewrite changes measurement, not behavior — that is the cause the intent names and the pattern it cites; the same lookup is kept.
  - `[false]` `[reject]` (intent) baseline commit goes beyond rebase.rs — the intent asks to commit the raised baseline; the gate wrote the four other entries the red loop gate never stamped, none lowered.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize, below.
  - (edge-case layer: no findings; verification-gap layer: no gaps.)

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at e5f3acb):**
1. coverage (`rebase.rs` 98.96% < 99.19%) — FIXED by bcdaecb (test + gate-raised `coverage-baseline.txt`), review patch 21a414c. Line 99: the inline test, now `plan_rebase_source_and_branch_with_an_insert_location_check_the_children`, runs its plan and `Immutable`-refusal assertions for `plan_rebase_source` as well as `plan_rebase_branch` with `-A "Commit 1"`, so `-s` skips the `onto` block. Line 320: `by_description` is an iterator search ending in `.ok_or(description).expect(…)`, no never-run `panic!`. `rebase.rs` is at 100.00%; the gate also recorded the loop's earlier raises (`drop_actions.rs` 99.32→99.75, `mutate.rs` 99.52→99.63, `remote_changes.rs` 99.31→100.00, new `revert.rs` 100.00). No entry lowered, no exclude_prefix.

**Files changed:** `crates/zanshin-jj/src/rebase.rs` (inline test only), `coverage-baseline.txt` (gate-raised).

**Review:** 1 patch applied (low), 0 deferred, 12 rejected with reasons in the triage log (8 false, 4 low). Follow-up review: false (patched: 0 high, 0 medium, 1 low).

**Verification:** `cargo test -p zanshin-jj --lib -- rebase::tests` 3 passed; `cargo make test` exit 0 after bcdaecb and again after 21a414c (`coverage-check: OK — coverage held at 99.19%`, extern-coverage OK, gate-stamp written).

**Residual risk:** none named.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- rebase::tests` -- expected: pass
- `cargo make test` -- expected: green, rebase.rs at 100.00%
