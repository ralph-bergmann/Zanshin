---
title: 'Story-loop 10.10..11.21 fix-up: rebase.rs coverage regression (dead test branch)'
type: 'chore'
created: '2026-11-03'
status: 'done'
baseline_revision: '96ef9bccf5cc98f809b82d447d6d53d139731bb9'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` failed the coverage ratchet: `crates/zanshin-jj/src/rebase.rs` 99.85% < baseline 100.00%. The unified lcov (`target/coverage/coverage.lcov`, LF 688 / LH 687) shows exactly one 0-hit line, 1106 — `Ok(true)` in the inline test `rebase_is_no_op_answers_what_the_dry_run_answers` (Story 10.10), the `target_ids(&loc).is_empty()` branch of the test's expected-value computation. Every source the test plans is a non-empty set of change ids, so no plan ever has empty targets and the branch is dead. All production lines, incl. the ported planner and `rebase_is_no_op`'s own empty-targets guard (269-270), are covered.

**Approach:** Drop the dead branch from the test: the expected value is always the dry-run `apply_move` result. The test's comparison stays exactly as strong (the branch was never taken).

## Boundaries & Constraints

**Always:** Keep the test's assertions (writes nothing, check == dry run, the compared/moved/root-merge count floor) unchanged.

**Never:** Lower `coverage-baseline.txt`, add an `exclude_prefix`, touch production code, or move the test out of `src/`.

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/rebase.rs:1036-1129` -- `rebase_is_no_op_answers_what_the_dry_run_answers`; lines 1105-1110 hold the `if target_ids(&loc).is_empty() { Ok(true) } else { apply_move(..) }` with the dead `Ok(true)` (1106).
- `crates/zanshin-jj/src/rebase.rs:268-271` -- production `rebase_is_no_op` empty-targets guard (covered; untouched).
- `target/coverage/coverage.lcov` -- evidence: `DA:1106,0` is the file's only unhit line.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/rebase.rs` -- replace the `if/else` at 1105-1110 with the `apply_move(..).map(|_| !dry.repo().has_changes())` expression alone -- removes the never-taken line.

**Acceptance Criteria:**
- Given the edit, when `cargo test -p zanshin-jj --lib rebase::` runs, then `rebase_is_no_op_answers_what_the_dry_run_answers` passes.
- Given the fix, when `cargo make test` runs, then it is green and rebase.rs is back at 100.00%.

## Spec Change Log

## Review Triage Log

### 2026-11-03 — Review pass
- verdicts: 4 findings — high 0, medium 0, low 0, false 4, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) Test no longer links `rebase_is_no_op`'s empty-targets guard to the dry run — the removed arm was never taken; jj-lib 0.46.0 `compute_move_commits` returns `ComputedMoveCommits::empty()` for empty targets (`rewrite.rs:676-707`), so `apply_move` would also answer `Ok(true)`; the guard (269-270) stays covered by `tests/it/drop_actions.rs:341` (`-b B -o C`, empty `C..B`).
  - `[false]` `[reject]` (blind) Non-empty-target premise unenforced; add an assert — if an empty plan ever appeared, check and oracle still agree (see above), so nothing is silently wrong.
  - `[false]` `[reject]` (blind) Formatting unverified — implementer ran `cargo fmt -p zanshin-jj --check` clean; the full gate's rustfmt step passed.
  - `[false]` `[reject]` (intent) Fix removes a line instead of adding tests; no baseline raise — the only 0-hit line was dead test code (the cause), not production; rebase.rs returns to 100.00% = baseline, so no raise is due. Edge-case and verification-gap layers reported no findings.

## Auto Run Result

Status: done

- **Failure 1 (coverage: rebase.rs 99.85% < 100.00%)** — fixed by removing the never-taken `Ok(true)` arm (line 1106, the file's only 0-hit line) from the inline test `rebase_is_no_op_answers_what_the_dry_run_answers`; the expected value is always the dry-run `apply_move` result. All Story 10.10 planner lines were already covered. Commit: 487b4ab8e8151429c3fe45f6d5e1a0fcc3cca6be.
- Files: `crates/zanshin-jj/src/rebase.rs` — test-only edit; this spec.
- Review: 0 patches, 0 deferred; 4 findings rejected as false (reasons in the triage log). Follow-up review recommended: false (patched: high 0, medium 0, low 0).
- Verification: `cargo test -p zanshin-jj --lib rebase::` 6 passed; full `cargo make test` exit 0 (run from this session, not killed), "coverage-check: OK — coverage held at 99.44% (36003/36205 lines)", parity oracle 507/507. `coverage-baseline.txt` unchanged: rebase.rs is back at its 100.00% baseline, nothing rose.
- Residual risk: none beyond the test no longer encoding the empty-targets case itself (covered by `tests/it/drop_actions.rs`).

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib rebase::` -- expected: all pass
- `cargo make test` -- expected: exit 0 (fallback if killed in a subagent: `cargo make --allow-private coverage`)
