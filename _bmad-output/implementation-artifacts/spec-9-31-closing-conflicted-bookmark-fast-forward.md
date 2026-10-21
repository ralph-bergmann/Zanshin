---
title: 'Story 9.31 closing run — conflicted-bookmark fast-forward witness'
type: 'chore'
created: '2026-10-21'
status: 'in-progress'
baseline_revision: '8ecd14c05057dd075ec0f4708b40e491fe05ee54'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 9.31's `deferred:` item), verified against the code at `8ecd14c`: `bookmark_ops::is_fast_forward` (`crates/zanshin-jj/src/bookmark_ops.rs:399-416`) returns true when ANY present add of the old target is an ancestor of the new one — the CLI's rule (`cli/src/commands/bookmark/mod.rs:165-182` @ v0.46.0, "we allow conflict resolution by setting bookmark to 'any' of the old target descendants") — but every test (`is_fast_forward_counts_an_absent_old_target_as_a_fast_forward` inline; `a_bookmark_moves_forward_backwards_or_nowhere` in `tests/it/drop_actions.rs:644-670`) uses an absent or non-conflicted target, so an "all sides" regression would pass. The gap is real and needs no product decision.

**Approach:** Add one integration test in `crates/zanshin-jj/tests/it/drop_actions.rs` that makes the local bookmark `mark` conflicted (adds `B` and `D`, the two sibling children of `A`) through jj-lib on the fixture repo, then asks `Repo::drop_actions` with `DropSource::Bookmark("mark")` — the outermost surface the rule is reachable through today — and pins the CLI's answers. No production code changes.

## Boundaries & Constraints

**Always:**
- Expected rows follow `cmd_bookmark_move` (`cli/src/commands/bookmark/move.rs` @ v0.46.0): a conflicted target is never a no-op (`old_target.as_normal() != Some(target)`), and `is_fast_forward` decides FastForward vs Backwards over `present_adds()`.
- The conflict is written with jj-lib (`Workspace::load` + `repo.start_transaction()` + `set_local_bookmark_target(…, RefTarget::from_legacy_form([A], [B, D]))` + `tx.commit(…)`), then `fx.repo` is reopened (`Repo::open`) so the query reads the new head; assert the bookmark really is conflicted before querying.
- The test uses the file's existing `query` helper (no op written, no warning left) and `Row` builders.

**Never:**
- No change to `is_fast_forward`, `plan_bookmark_move`, `drop_actions` or any other production code; no bookmark move verb (Story 9.19 stays backlog); no oracle scenario (no move verb to compare); no fixture regeneration; no edit of `epics.md`, `epic-9-context.md`, `sprint-status.yaml` or Story 9.31's spec.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| One side is an ancestor | conflicted `mark` (adds `B`, `D`); drop onto `C` (child of `B`, not a descendant of `D`) | `BookmarkMove` row `Available` (fast-forward) — an "all sides" rule would say backwards | — |
| Onto one side itself | drop onto `D` | `Available` (a side is its own ancestor; not a no-op, the target is not normal) | — |
| No side is an ancestor | drop onto `A` (parent of both sides) | `Available` with `allow_backwards_needed` | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/bookmark_ops.rs:358-416` -- `BookmarkMovePlan`, `plan_bookmark_move` (no-op = absent or `as_normal() == Some(target)`), `is_fast_forward` (any present add) -- read-only; the rule under test.
- `crates/zanshin-jj/src/drop_actions.rs:329-346` -- the bookmark row: `NoOp` → `Planned{no_op}`, `FastForward` → `AVAILABLE`, `Backwards` → `allow_backwards_needed` -- read-only.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- fixture `base` `:88-138` (`root → A → B → C`, `D` second child of `A` = `@`), `load` `:44-53` (jj-lib `Workspace::load` with `test_helpers::test_settings()`), `hex` `:70-81` (change id → commit hex), `query` `:236-246`, row builders `:179-214`, sibling test `a_bookmark_moves_forward_backwards_or_nowhere` `:644-670` -- add the new test after it.
- jj-lib 0.46.0: `RefTarget::from_legacy_form(removes, adds)` (`op_store.rs`), `MutableRepo::set_local_bookmark_target`, `Transaction::commit(description)` (async → `pollster::block_on`), `CommitId::from_hex`.
- CLI @ v0.46.0: `cli/src/commands/bookmark/mod.rs:165-182` `is_fast_forward`; `cli/src/commands/bookmark/move.rs` no-op exclusion `bookmarks.retain(|(_, old)| old.as_normal() != Some(target))`.
- `_bmad-output/implementation-artifacts/deferred-work.md:1710-1712` -- the item's bullet; mark it resolved with the fix commit at finalisation.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- add `a_conflicted_bookmark_moves_forward_when_any_side_is_an_ancestor`: conflict `mark` via jj-lib (removes `[A]`, adds `[B, D]`), reopen, assert conflicted, query `onto C`, `onto D`, `onto A` and pin `available`, `available`, `backwards` -- witnesses the CLI's "any side" rule at the outermost reachable surface.

**Acceptance Criteria:**
- Given the new test, when `cargo test -p zanshin-jj --test it drop_actions::` runs, then it passes; and given `is_fast_forward` temporarily changed to require every present add, then the new test fails on the `onto C` row (mutation check, reverted).
- Given the end of the run, then `cargo clippy -p zanshin-jj --all-targets -- -D warnings` and `cargo fmt --all --check` pass and `git status --porcelain` is clean.

## Spec Change Log

## Review Triage Log

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it drop_actions::` -- expected: all pass.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean.
- `cargo fmt --all --check` -- expected: clean.
