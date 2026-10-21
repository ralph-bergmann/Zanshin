---
title: 'Fix-up after Story 9.56 — coverage regressions in duplicate.rs and workspace_add.rs'
type: 'chore'
created: '2026-10-21'
status: 'done'
baseline_revision: 'e5748f6a8a86c52e744f5446c14150361c3a12a7'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `cargo make test` at e5748f6 fails only in its coverage step (failure 1): `crates/zanshin-jj/src/duplicate.rs` 89.66% < 92.59% (uncovered 68, 78, 82 — `plan_duplicate`'s `-A`/`-B` immutable resolution and its no-location branch; the only caller, `drop_actions`' `duplicate` row, always passes `-o`) and `crates/zanshin-jj/src/workspace_add.rs` 98.07% < 98.58% (uncovered 200, 223, 238, 243). In workspace_add.rs only 223 is new — Story 9.56's `rebase_descendants_with_options(…, |_, _| {})` puts a never-called no-op closure on its own line (the abandoned initial `@` never has descendants); 200 (no old `@` → root parent), 238/243 (`)?;` error arms of `finish_transaction`/`mutation_result`) were uncovered before, and Story 9.56's shorter error constructors shrank the line count, so fixing 223 alone still leaves 98.54%.

**Approach:** duplicate.rs: an inline test runs `plan_duplicate` with no location and with `-A "Commit 1"` (plus its `Immutable` refusal). workspace_add.rs: write the rebase call in creation.rs's shape (closure on the call's line, `RebaseOptions` imported) and add an integration test for `workspace add` from a workspace whose `@` was forgotten — the CLI's root-parent default (`add.rs` @ v0.46.0, `else { vec![root_commit] }`).

## Boundaries & Constraints

**Always:** Tests plus the one layout-only rewrite of the rebase call (same call, same arguments); the `coverage-baseline.txt` the green gate auto-raises is committed with the fix. Inline tests start with `test_helpers::pin_test_env()`; the new integration test lives in `crates/zanshin-jj/tests/it/workspace_add.rs` and uses its helpers.

**Never:** No behavior change, no lowered baseline entry, no `exclude_prefix`, no edits to unrelated files or tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| duplicate, no location | `tiny-3-commits`, revisions `[Commit 2]`, immutable `root()` | `to_duplicate == [C2]`, `location == None` | No error expected |
| duplicate `-A "Commit 1"` | revisions `[@]`, immutable `root()` | `location == Some(([C1], [C2]))` | No error expected |
| duplicate `-A "Commit 1"`, C2 immutable | immutable `commits([C2])` | `Err(Immutable { commit_id: C2 hex })` | refusal |
| workspace add, current `@` forgotten | default `@` on `p` removed from the view via jj-lib, `Repo::open` + `workspace_add("../ws2")` | ws2's `@` has the root as its only parent; `p.txt` absent in ws2; ops `create initial working-copy commit in workspace ws2`, `add workspace 'ws2'` | No error expected |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/duplicate.rs:50-84` -- `plan_duplicate(tx, templates, revisions, location)`; no `#[cfg(test)]` module yet. `drop_actions.rs:416` is its only caller, `onto` always non-empty.
- `crates/zanshin-jj/src/rebase.rs:295-370` -- reuse pattern for the inline test: `tiny-3-commits` fixture, `by_description`, `change`, `start_repo_transaction`, `config::load`, `CommandEnv::load`, `Templates::new(&config, &immutable, &env.template_startup, repo.workspace())`.
- `crates/zanshin-jj/src/workspace_add.rs:194-201` -- parents default: old `@`'s parents, else root (200). `:219-225` -- the rebase call; `creation.rs:486-492` is the one-line-closure shape to copy. 238/243 stay uncovered (unreachable error arms, pre-existing).
- `crates/zanshin-jj/src/snapshot.rs:860-874` -- `handle_stale_working_copy` returns `None` without `@`, so the precondition snapshot passes for a forgotten workspace.
- `crates/zanshin-jj/tests/it/status.rs:89-110` -- `remove_working_copy`: `remove_workspace` + `rebase_descendants` + commit via jj-lib; copy into workspace_add.rs's test.
- `crates/zanshin-jj/tests/it/workspace_add.rs:138-185` -- `add_default_creates_a_sibling_workspace_on_ats_parents` (`init`, `wc_of`, `change_id`, `descriptions`, `add`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/duplicate.rs` -- add `#[cfg(test)] mod tests` with one test covering the three duplicate rows of the matrix -- covers 68, 78, 82.
- `crates/zanshin-jj/src/workspace_add.rs` -- import `jj_lib::rewrite::RebaseOptions`; rewrite the rebase call in creation.rs's shape so `|_, _| {}` shares the call's line -- removes 223.
- `crates/zanshin-jj/tests/it/workspace_add.rs` -- add `a_workspace_without_at_adds_on_the_root` (matrix row 4) -- covers 200.

**Acceptance Criteria:**
- Given the change, when `cargo make coverage` runs, then duplicate.rs ≥ 92.59% and workspace_add.rs ≥ 98.58% and no file regresses.
- Given the change, when `cargo make test` runs, then every step passes and the auto-raised `coverage-baseline.txt` is committed with the fix.

## Spec Change Log

## Review Triage Log

### 2026-10-21 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 11, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (edge-case) `a_workspace_without_at_adds_on_the_root` asserts only the top two ops, so a precondition snapshot of the forgotten default workspace (the CLI takes none without an `@`) would pass unnoticed — now asserts `[..3]` with `test: remove working-copy commit` third (8c29c70).
  - `[low]` `[reject]` (blind) the no-location test does not show line 81's unresolvable-alias refusal — Story 9.56's own behavior, not what the coverage failure needs; the intent says change only what a failure needs.
  - `[low]` `[reject]` (blind) nothing pins that an immutable revision can still be duplicated — same: beyond the failure, intent-excluded.
  - `[low]` `[reject]` (blind) the duplicate test copies `rebase.rs`'s setup — a shared helper is a refactor of a second file the failure does not need.
  - `[low]` `[reject]` (blind) the workspace-add test inlines `status.rs`'s `remove_working_copy` — sharing it means moving a helper out of another test module; beyond the failure.
  - `[low]` `[reject]` (blind) the test does not assert `default` still has no `@` afterwards — not part of matrix row 4; nothing in `add` writes the old workspace (`edit` targets `name` only).
  - `[low]` `[patch]` (blind) the line-223 layout fix is fragile against a future split — added a `// WHY:` comment above the call (8c29c70).
  - `[low]` `[patch]` (blind) "inserts the duplicate above Commit 2" contradicts the asserted `([C1], [C2])` — now "between Commit 1 and Commit 2" (8c29c70).
  - `[low]` `[patch]` (blind) CLI citation "`add.rs` @ v0.46.0" ambiguous — now `cli/src/commands/workspace/add.rs` @ v0.46.0 (8c29c70).
  - `[false]` `[reject]` (blind) spec untracked / status stale — committed at finalize with `status: done`.
  - `[low]` `[reject]` (blind) spec does not account for the other baseline raises — fix edits this build's spec; the Auto Run Result records them.
  - `[low]` `[reject]` (blind) `-B` never exercised — same `inserts` arm as `-A`, lines covered; beyond the failure.
  - `[false]` `[reject]` (intent) line 223 fixed by a layout change instead of a test — the closure is unreachable (the abandoned initial `@` has no descendants), so no test can run it; the call and its arguments are unchanged, the shape is `creation.rs:486-492`'s, and the rule forbids only a lowered baseline or an `exclude_prefix`.
  - `[false]` `[reject]` (intent) line 68 is the `-A`/`-B` arm, not the no-location one — descriptive, no defect; the test covers both arms.
  - `[false]` `[reject]` (intent) the duplicate test calls the private planner, not a public verb — no public path reaches these arms (`drop_actions` always passes `-o`); the intent's surface is per-file coverage.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize, below.
  - `[false]` `[reject]` (intent) no evidence of a green gate — `cargo make test` exit 0 after 1481fc9 (gate-plan: 0 paths changed since last green) and rerun after 8c29c70, recorded below.
  - (verification-gap layer: no gaps.)

## Auto Run Result

Status: done

**Failures (from `cargo make test` at e5748f6):**
1. coverage (`duplicate.rs` 89.66% < 92.59%, `workspace_add.rs` 98.07% < 98.58%) — FIXED by 1481fc9 (tests, layout-only rebase call, gate-raised `coverage-baseline.txt`), review patches 8c29c70.
   - `duplicate.rs` lines 68/78/82: the inline test `plan_duplicate_without_a_location_and_with_an_insert_location` runs `plan_duplicate` with no location (`to_duplicate == [C2]`, `location == None`), with `-A "Commit 1"` (`([C1], [C2])`) and with Commit 2 immutable (`Immutable`). 100.00%.
   - `workspace_add.rs` line 200: the integration test `a_workspace_without_at_adds_on_the_root` adds `../ws2` from a workspace whose `@` was removed through jj-lib — ws2's `@` on the root, the CLI's default (`cli/src/commands/workspace/add.rs` @ v0.46.0); no precondition snapshot is written. Line 223: the never-called no-op closure now shares the `rebase_descendants_with_options` call's line (creation.rs's shape, `RebaseOptions` imported, `// WHY:` comment). Lines 238/243 (`)?;` error arms of `finish_transaction`/`mutation_result`) stay uncovered, as before Story 9.56. 99.03%.
   - The gate also recorded raises the earlier red gates never stamped: `creation.rs` 96.88→97.00, `git.rs` 99.55→100.00, `push.rs` 93.99→94.43, `snapshot.rs` 98.57→98.67. No entry lowered, no `exclude_prefix`.

**Files changed:** `crates/zanshin-jj/src/duplicate.rs` (inline test), `crates/zanshin-jj/src/workspace_add.rs` (layout of one call + WHY comment, no behavior change), `crates/zanshin-jj/tests/it/workspace_add.rs` (new test), `coverage-baseline.txt` (gate-raised).

**Review:** 4 patches applied (all low), 0 deferred, 13 rejected with reasons in the triage log (6 false, 7 low). Follow-up review: false (patched: 0 high, 0 medium, 4 low).

**Verification:** `cargo test -p zanshin-jj --lib -- duplicate::tests` 1 passed; `cargo test -p zanshin-jj --test it -- workspace_add` 20 passed; `cargo make test` exit 0 after 1481fc9 and again after 8c29c70 (987 s, `coverage-check: OK — coverage held at 99.25%`, extern-coverage OK, gate-stamp written).

**Residual risk:** line 223's coverage depends on rustfmt keeping the closure on the call's line (the WHY comment says so).

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- duplicate::tests` -- expected: pass
- `cargo test -p zanshin-jj --test it -- workspace_add` -- expected: pass
- `cargo make test` -- expected: green
