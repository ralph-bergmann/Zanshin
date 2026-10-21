---
title: 'Story 9.31 closing run — conflicted-bookmark fast-forward witness'
type: 'chore'
created: '2026-10-21'
status: 'done'
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

### 2026-10-21 — Review pass
- verdicts: 13 findings — high 0, medium 0, low 8, false 5, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind 1) the struck deferred-work bullet kept a now-false evidence line and a "Follow-up: Story 9.19 …" that silently closed with it, though 9.19's move verb still owes a test of the WRITE — evidence line prefixed "Was:" (past tense), follow-up rewritten to stay live for 9.19's write test (6a5d447).
  - `[low]` `[patch]` (blind 2) a conflict with a DELETED side (concurrent delete vs move) was not witnessed — added `a_conflicted_bookmark_with_a_deleted_side_counts_only_the_present_side` (adds `B` + absent; onto C / B available, onto A backwards) with shared helpers `commit_id` / `conflict_mark` (6a5d447); a mutation "some add absent ⇒ fast-forward" fails it on `onto A`.
  - `[low]` `[patch]` (blind 3) rows `onto D` / `onto A` uncommented, the no-op exclusion never mutation-checked — row comments added (6a5d447); mutation `plan_bookmark_move` = no-op when the target is any present add fails both tests; reverted.
  - `[low]` `[reject]` (blind 4) the spec's AC names only `onto C` and its Code Map says `CommitId::from_hex` while the code uses `try_from_hex` — the fix edits this build's spec; the Results note records the deviation.
  - `[low]` `[patch]` (blind 5) the test doc cited `as_normal() != Some(target)` as if it lived in `mod.rs` — now names `cli/src/commands/bookmark/move.rs` @ v0.46.0 (6a5d447).
  - `[low]` `[patch]` (blind 6) the module header says the fixture uses Zanshin's own verbs, the new test writes through jj-lib — `conflict_mark`'s doc says why: no Zanshin verb creates a conflicted bookmark (6a5d447).
  - `[false]` `[reject]` (blind 7) the `present_adds` order assertion could break if jj-lib canonicalised side order — `RefTarget::from_legacy_form` in jj-lib 0.46.0 keeps the given order, so the precondition is deterministic; a future change would fail loudly on the precondition, not mask the rule.
  - `[low]` `[patch]` (edge 1) absent-add conflict never exercised — same root as blind 2, patched there.
  - `[false]` `[reject]` (intent 1) no inline unit test at the `is_fast_forward` surface — the intent names `drop_actions`' bookmark source as the surface to witness ("witness it there now"); the mutation checks prove the indirect witness reaches the fn.
  - `[false]` `[reject]` (intent 2) no running-CLI comparison — the intent says the CLI is read at `git show v0.46.0`, and there is no Zanshin move verb for the oracle to compare (gate rule: oracle only when a jj verb changed).
  - `[false]` `[reject]` (intent 3) no `## Auto Run Result`, status mismatch — mid-run state; finalisation writes both.
  - `[low]` `[patch]` (intent 4) the deferred-work edit was unrequested and left stale child lines — the stale lines are blind 1's root, patched there; resolving the handed item's bullet is every closing run's ledger hygiene (9.23, 9.48, 9.49, 9.51, 9.54).
  - `[false]` `[reject]` (intent 5) the test pins `onto D` / `onto A` beyond the item — assertions inside the requested witness covering the CLI's own neighbouring rules (no-op exclusion, backwards branch); no production behaviour added.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it drop_actions::` -- expected: all pass.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean.
- `cargo fmt --all --check` -- expected: clean.

**Results (2026-10-21, commit 6691ae0):**
- `cargo test -p zanshin-jj --test it drop_actions::` -- 27 passed (the new test included).
- Mutation check: `is_fast_forward` changed to require every present add → the new test failed (`onto C` and `onto D` read `backwards`); reverted, `bookmark_ops.rs` unchanged.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` and `cargo fmt --all --check` -- clean.
- Note: `CommitId::from_hex` takes `&'static str` in jj-core 0.46.0, so the test uses `try_from_hex`.

**Results after the review patches (2026-10-21, commit 6a5d447):**
- `cargo test -p zanshin-jj --test it drop_actions::` -- 28 passed (both conflicted-bookmark tests included).
- Mutation checks, each reverted (`bookmark_ops.rs` has no diff): `is_fast_forward` → true when any add is absent: the deleted-side test fails on `onto A`; `plan_bookmark_move` → no-op when the target is any present add: both conflicted tests fail.
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean.
- Not run, per the run's gate rule: `cargo make test` / `test-full` / `coverage` (the story loop runs the gate once at its end). No FFI, schema, jj verb or Dart change, so no codegen, oracle or Dart checks apply.

## Auto Run Result

Status: done (2026-10-21). Blocking condition: none.

**Items.**
- **Item 1 (the bookmark row's "any side of a conflict" fast-forward rule is untested)** — fixed (6691ae0; review patches 6a5d447). Verified real at `8ecd14c`: `bookmark_ops::is_fast_forward` mirrors the CLI's `fallible_any` over `present_adds()` (`cli/src/commands/bookmark/mod.rs:165-182` @ v0.46.0), but every test used an absent or non-conflicted target. No product decision needed; no production code changed. `tests/it/drop_actions.rs` now witnesses the rule through `Repo::drop_actions`' bookmark source: a conflicted `mark` (adds `B`, `D`) reads onto `C` (only `B` an ancestor) and onto `D` as fast-forwards and onto `A` as backwards; a conflict with a deleted side (adds `B` + absent) reads onto `C` / `B` as fast-forwards and onto `A` as backwards.

No new finding was deferred, so nothing new was mirrored into deferred-work.md; the item's own bullet there is marked RESOLVED, with its 9.19 follow-up kept live (the move verb's WRITE of a conflicted bookmark still owes its own test).

**Files changed.**
- `crates/zanshin-jj/tests/it/drop_actions.rs` — helpers `commit_id`, `conflict_mark` (writes the conflict through jj-lib, reopens, asserts it); tests `a_conflicted_bookmark_moves_forward_when_any_side_is_an_ancestor`, `a_conflicted_bookmark_with_a_deleted_side_counts_only_the_present_side`.
- `_bmad-output/implementation-artifacts/deferred-work.md` — the item's bullet resolved.

**Review.** 13 findings: high 0, medium 0, low 8, false 5, maybe-false 0 (triage log above).
- Patched (6a5d447, 5 entries, all low): stale ledger child lines (blind 1 / intent 4); deleted-side conflict witness (blind 2 / edge 1); row comments + no-op mutation check (blind 3); CLI citation of the no-op exclusion (blind 5); why jj-lib writes the conflict (blind 6).
- Deferred: none.
- Rejected: spec self-contradictions (blind 4 — fix edits this build's spec); false: order brittleness (blind 7), unit-test surface (intent 1), running-CLI comparison (intent 2), missing result mid-run (intent 3), extra rows (intent 5).

**Follow-up review recommendation:** false — this first pass patched 0 high and 0 medium entries (patched counts: high 0, medium 0, low 5).

**Matrix audit.** One side an ancestor (onto C), onto one side (onto D), no side an ancestor (onto A): all three rows in `a_conflicted_bookmark_moves_forward_when_any_side_is_an_ancestor`, which ran and passed.

**Residual risks.** None beyond the gate not having run in this loop iteration; the change is test-only.

**Commits.** addc321 (spec), 6691ae0 (test), b180511 (interim finalisation by the implementer), 6a5d447 (review patches), and the finalisation commit of this spec.
