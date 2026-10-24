---
title: 'Fix-up after the story loop 9.9 9.19 9.50 9.21 9.12 — coverage regressions in config.rs, duplicate.rs, op_log.rs'
type: 'chore'
created: '2026-10-24'
status: 'done'
baseline_revision: '0b691feb4d8dfea002539a2112e487b435326081'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` fails only in its coverage step (exit 105) with three per-file regressions below a 100.00% baseline: (1) `crates/zanshin-jj/src/config.rs` 99.87% — lines 1066, 1070, 1077 of `line_range_arg_rule`'s apply closure (Story 9.9); (2) `crates/zanshin-jj/src/duplicate.rs` 99.42% — line 155, the `parents.is_empty()` early return of `warn_self_placement` (Story 9.9); (3) `crates/zanshin-jj/src/op_log.rs` 99.63% — line 524 (the `?` error arm of `op_diff` inside `op_show`) and line 665 (`current.clone()`, an `op abandon` range with an empty end `X..`) (Story 9.21).

**Approach:** Add tests that run each line, keeping every behavior as the CLI has it. Where a line is unreachable through the verb (the CLI keeps the same guard), test the private item directly in its file's inline `mod tests`; for config.rs that needs the apply closure lifted into a named fn (no behavior change) so a test can call it.

## Boundaries & Constraints

**Always:** Behavior stays the CLI's (`cli/src/config.rs:974-1050`, `cli/src/commands/duplicate.rs`, `operation/abandon.rs` @ v0.46.0); the guards stay. Unit tests for private items inline; the op_log cases through `Repo` in `tests/it/`. jj runs only in test temp dirs. Commit the gate-raised `coverage-baseline.txt` with the fix.

**Never:** No lowered baseline entry, no `exclude_prefix`, no removal of the CLI-mirroring guards, no change to other files' behavior or unrelated tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| table-valued `line-range-arg` | layer `[fix.tools.t.line-range-arg]\nx = 1` | `migrate` succeeds; the description for that layer is `""` (`delete_value` refuses a table → `continue`), the table stays | No error |
| apply on a layer without `fix.tools` | `line_range_arg_apply` called directly | `Ok` with the CLI's generic "is deprecated; use `line-range-args` instead." text | No error |
| self-placement with no parents | plan `location = Some(([], [c1]))`, `to_duplicate = [c2]` | `Ok`, no warning (without the guard, `c1` ancestor of `c2` would warn) | No error |
| `op show` whose diff fails | head op rewrote commits, one new commit's git object deleted, `show_changes_in = description(...)` | `Err(MutateError::Backend(_))` | Backend error surfaces |
| `op abandon "@-.."` | one op head | refused "Cannot abandon the current operation <head12>" with the CLI's hint | InvalidInput |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/config.rs:1044-1098` -- `line_range_arg_rule()`: `ConfigMigrationRule::custom(matches, apply)`; jj-lib keeps `apply` private (`jj-lib-0.46.0/src/config_resolver.rs:377`) and calls it only after `matches` → 1066/1070 unreachable through `migrate`. Lift the apply closure to `fn line_range_arg_apply(layer: &mut ConfigLayer) -> Result<String, ConfigMigrateLayerError>` (same body, `// WHY` comment kept), pass it to `custom`.
- `crates/zanshin-jj/src/config.rs:1076-1078` -- reachable: `delete_value` returns `Err(WouldDeleteTable)` when `line-range-arg` is a table (`jj-lib-0.46.0/src/config.rs:481-485`).
- `crates/zanshin-jj/src/config.rs:4289-4352` -- existing inline test `migrate_rewrites_a_deprecated_line_range_arg_as_the_cli_does` (its `layer` closure, `StackedConfig`) — extend it.
- `crates/zanshin-jj/src/duplicate.rs:150-184` -- `warn_self_placement`; `resolve_commit_location` (`op_support.rs:326-328`) refuses empty parents, so 155 is unreachable through the verb (the CLI keeps `&& !parent_commit_ids.is_empty()`). Inline test at `duplicate.rs:254-327` shows the fixture/tx/config/`CommandEnv` setup; `VerbContext::new(config, env, false, SnapshotStats::default(), Warnings::default())` (`snapshot.rs:418-426`, used at `op_log.rs:1094`); `Warnings::take()` (`warning.rs:336`).
- `crates/zanshin-jj/src/op_log.rs:502-530` -- `op_show`; `crate::op_diff::op_diff` (`op_diff.rs:191`) fails only with `MutateError::Backend` (`commits_diff`, `op_diff.rs:278-356`: a filter revset evaluated on a commit whose object is gone).
- `crates/zanshin-jj/src/op_log.rs:658-669` -- `op_abandon` range parse; `X..` → `current.clone()` → always the current-operation refusal (`:681-688`), as the CLI.
- `crates/zanshin-jj/tests/it/op_show_diff.rs` -- `one`, `head_id` helpers; fixture `tiny-3-commits` (`root → Commit 1 → Commit 2 → Commit 3`, empty `@` off root). Git store path from `.jj/repo/store/git_target`.
- `crates/zanshin-jj/tests/it/op_abandon.rs:111-141` -- `op_abandon_refusals_leave_the_op_heads_alone`, loop `for current in ["@", "..@", &head[..]]`.
- `coverage-baseline.txt` -- `config.rs`, `duplicate.rs`, `op_log.rs` = 100.00.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- lift the apply closure into `line_range_arg_apply`; in the existing migrate test add a table-valued `line-range-arg` layer (assert `Ok`, description `""`, table untouched) and a direct `line_range_arg_apply` call on a layer without `fix.tools` (assert the generic text) -- covers 1066/1070/1077.
- `crates/zanshin-jj/src/duplicate.rs` -- inline test: `warn_self_placement` with `location: Some((vec![], vec![c1]))`, `to_duplicate: vec![c2]` → `Ok`, no warnings -- covers 155.
- `crates/zanshin-jj/tests/it/op_show_diff.rs` -- test: describe `Commit 1`, drop the repo, delete the described commit's loose git object, reopen, `op_show("@", Some("description(glob:'*')"))` → `MutateError::Backend` -- covers 524.
- `crates/zanshin-jj/tests/it/op_abandon.rs` -- add `"@-.."` to the current-operation refusal loop -- covers 665.

**Acceptance Criteria:**
- Given the change, when `cargo test -p zanshin-jj --lib -- config::tests duplicate::tests` and `cargo test -p zanshin-jj --test it -- op_show_diff op_abandon` run, then all pass.
- Given the change, when `cargo make test` runs, then every step passes with `config.rs`, `duplicate.rs`, `op_log.rs` at 100.00% and no file regressing, and the auto-raised `coverage-baseline.txt` is committed with the fix.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 19 findings — high 0, medium 0, low 12, false 7, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) six first-time baseline entries (fix.rs, metaedit.rs, op_diff.rs, select_tree.rs ×2, metaedit_duplicate_fix.rs) land in a test-only commit — the loop runs the gate once at its end (CLAUDE.md 2026-10-20); the red final gate wrote no rows, the first green run seeds them; the intent says to commit the raised baseline.
  - `[low]` `[reject]` (blind) the table-valued case does not assert the user-visible warning text — no bad outcome in code; `deprecation_warnings` is tested on its own (`deprecation_warnings_word_every_source_as_the_cli_does`) and the empty description is the CLI's own (same rule code).
  - `[low]` `[reject]` (blind) the table-valued case does not assert the warning repeats on a second migrate — test-completeness only, nobody meets it in everyday use; the code path is the CLI's.
  - `[low]` `[patch]` (blind) "`delete_value` refuses a table" is imprecise (only a non-inline table) — fixed in ffcbc60: "a (non-inline) table"; the inline case is the existing non-string refusal.
  - `[low]` `[patch]` (blind) the WHY comment is stale and the test doc comment lists only the old cases — WHY comment is still accurate (through `migrate`, `apply` only runs after `matches`); doc comment extended with the two new cases in ffcbc60.
  - `[low]` `[patch]` (blind) duplicate.rs no-parents test has no positive control — fixed in ffcbc60: the same plan with parents `[root]` asserts exactly one `DuplicateAsOwnAncestor`.
  - `[low]` `[reject]` (blind) `by_description` walker duplicated across the two tests — cosmetic, the fix is a refactor of an existing test, not a direct correction.
  - `[low]` `[patch]` (blind) `MutateError::Backend(_)` does not pin the op_show failure to the diff — fixed in ffcbc60: `op_show("@", None)` must succeed with a diff in the same broken store first.
  - `[low]` `[patch]` (blind) the default (`None`) path is not tested on the broken store — same root cause and fix as the row above (ffcbc60).
  - `[false]` `[reject]` (blind) the test relies on a loose-object layout — a packed object fails loudly at `remove_file` naming the path; loud failure on an unshown state is correct.
  - `[low]` `[reject]` (blind) bare `..` and open-ended with divergent heads untested — both take branches already covered (empty root `:660`, `current.clone()` `:665`, multi-head refusal `:686`); no line or behavior gap.
  - `[low]` `[patch]` (edge) op_show assertion could pass if the failure moved off `:524` — same root cause as the blind op_show rows; fixed in ffcbc60.
  - `[low]` `[patch]` (edge) the empty-warnings assertion could pass vacuously — same root cause as the blind duplicate row; fixed in ffcbc60.
  - `[false]` `[reject]` (intent) R1 (tests only) vs the config.rs closure→fn lift — lines 1066/1070 are unreachable through `migrate` (jj-lib's `apply` is private, runs only after `matches`); the lift is behavior-neutral and is what the failure needs; no baseline/exclude change.
  - `[false]` `[reject]` (intent) R3: 1066/1070 and duplicate.rs:155 are reached below the public surface — no public path reaches them (the CLI keeps the same guards); the other three lines are covered through `migrate` / `Repo::op_show` / `Repo::op_abandon`.
  - `[false]` `[reject]` (intent) failure 3's annotation names `vec![resolve(head_str)?]` but the test covers `current.clone()` — the coverage.lcov of the red run marks 665 (= `current.clone()`, file unchanged since 0b70704) uncovered and 667 covered; the line number is authoritative.
  - `[low]` `[patch]` (intent) the line-524 test asserts only "some Backend error" — same root cause as the op_show rows; fixed in ffcbc60.
  - `[false]` `[reject]` (intent) first-time baseline entries go beyond "raised" — the gate writes them automatically on the first green run; nothing lowered.
  - `[false]` `[reject]` (intent) no `## Auto Run Result` / no gate evidence in the diff — written at finalize below.
  - (verification-gap layer: no gaps.)

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- config::tests duplicate::tests` -- expected: pass
- `cargo test -p zanshin-jj --test it -- op_show_diff op_abandon` -- expected: pass
- `cargo make test` -- expected: green, the three files at 100.00%

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at 0b691fe, coverage step exit 105):**
1. coverage (`crates/zanshin-jj/src/config.rs` 99.87% < 100.00%, lines 1066/1070/1077) — FIXED by 81e8113 (review polish ffcbc60). The apply closure of `line_range_arg_rule` is lifted, body unchanged, into `fn line_range_arg_apply` (jj-lib's `ConfigMigrationRule::apply` is private and runs only after `matches`, so 1066/1070 are unreachable through `migrate`); the inline test `migrate_rewrites_a_deprecated_line_range_arg_as_the_cli_does` now calls it on a layer without `fix.tools` (the CLI's generic text, 1066 + 1070) and migrates a non-inline table-valued `line-range-arg` (`delete_value` refuses it → skipped, empty description, 1077). `config.rs` back at 100.00%.
2. coverage (`crates/zanshin-jj/src/duplicate.rs` 99.42% < 100.00%, line 155) — FIXED by 81e8113 (control added in ffcbc60). New inline test `warn_self_placement_without_parents_warns_nothing`: a plan with location parents `[]` warns nothing; the control with parents `[root]` warns `DuplicateAsOwnAncestor`. The CLI's guard stays (the verb never builds empty parents — `resolve_commit_location` refuses them). `duplicate.rs` back at 100.00%.
3. coverage (`crates/zanshin-jj/src/op_log.rs` 99.63% < 100.00%, lines 524 and 665) — FIXED by 81e8113 (assertion pinned in ffcbc60). 524: new `tests/it/op_show_diff.rs::op_show_whose_diff_fails_reports_the_backend_error` — the described commit's loose Git object is deleted; `op_show("@", None)` still succeeds, `op_show("@", Some("description(glob:'*')"))` is `MutateError::Backend`. 665: per the red run's coverage.lcov, line 665 is `current.clone()` (open-ended `X..`; 667 `vec![resolve(head_str)?]` was already covered) — `"@-.."` joins the current-operation refusal loop in `tests/it/op_abandon.rs`, refused as the CLI refuses it. `op_log.rs` back at 100.00%.

**Baseline:** 81e8113 commits the gate-raised `coverage-baseline.txt`: raised `push.rs` 94.43→94.94, `repo.rs` 99.16→99.32, `status.rs` 89.71→90.00, `workspace_add.rs` 99.03→99.51 (zanshin-jj); first entries for the loop's new files (zanshin-jj `fix.rs` 96.89, `metaedit.rs` 100.00, `op_diff.rs` 98.58, `select_tree.rs` 100.00; zanshin-ffi `metaedit_duplicate_fix.rs` 100.00, `select_tree.rs` 100.00). Nothing lowered, no `exclude_prefix`.

**Files changed:** `crates/zanshin-jj/src/config.rs` (closure → named fn, inline test cases), `crates/zanshin-jj/src/duplicate.rs` (inline test), `crates/zanshin-jj/tests/it/op_show_diff.rs` (new test), `crates/zanshin-jj/tests/it/op_abandon.rs` (`"@-.."` refusal case), `coverage-baseline.txt` (gate-raised), this spec.

**Review:** 19 findings — 8 patched (all low: comment precision, test doc, duplicate positive control, op_show failure pinned to the filtered diff — 4 root causes, ffcbc60), 0 deferred, 11 rejected with reasons in the triage log (7 false, 4 low). Follow-up review: false (patched: 0 high, 0 medium, 8 low rows / 4 low entries).

**Verification:** `cargo test -p zanshin-jj --lib -- config::tests duplicate::tests` 90 passed; `cargo test -p zanshin-jj --test it -- op_show_diff op_abandon` 28 passed; `cargo make test` exit 0 at 81e8113 (implementer's run) and again exit 0 on the patched tree (ffcbc60, no REGRESSION / BELOW FLOOR, gate stamp written, baseline unchanged by the patches).

**Residual risk:** the op_show failure test depends on the commit object being loose (fails loudly at `remove_file` otherwise).
