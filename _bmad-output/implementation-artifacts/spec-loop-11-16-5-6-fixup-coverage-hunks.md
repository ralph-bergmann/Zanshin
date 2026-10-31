---
title: 'Story-loop 11.16..5.6 fix-up: hunks.rs coverage regression (copy kind)'
type: 'chore'
created: '2026-10-31'
status: 'done'
baseline_revision: 'aa0561b6368ca41051d08344283a029fe6a2c951'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` failed the coverage ratchet: `crates/zanshin-jj/src/hunks.rs` 99.76% < baseline 100.00%. The unified lcov shows exactly one 0-hit line, 430 — the `Some(CopyOperation::Copy) => ChangeKind::Copied { .. }` arm of `change_kind`, which no `Repo::diff` test reaches (only a rename is tested). The `map_err` closures the follow-up review suspected are covered.

**Approach:** Add one integration test in `crates/zanshin-jj/tests/it/diff.rs` where git's copy detection (`CopySource::FromSetOfModifiedFiles`) reports a copy: one commit modifies `old.txt` and adds `new.txt` with `old.txt`'s original content; `Repo::diff` must report `new.txt` as `ChangeKind::Copied { from: "old.txt" }`.

## Boundaries & Constraints

**Always:** Test only through the public `Repo::diff` surface, with the file's existing helpers (`init`, `write`, `commit`, `run`, `revision`, `paths`).

**Never:** Lower `coverage-baseline.txt`, add an `exclude_prefix`, or touch production code.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Copy | A: `old.txt` = 10 lines; C: `old.txt` edited, `new.txt` = A's `old.txt` | `new.txt` kind `Copied { from: old.txt }`, `old.txt` kind `Modified` | No error expected |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:426-435` -- `change_kind`; line 430 is the uncovered `Copy` arm.
- `crates/zanshin-jj/tests/it/diff.rs:202` -- `a_rename_is_one_file_with_its_source`, the template for the new test.
- `~/.cargo/registry/src/*/jj-lib-0.46.0/src/git_backend.rs:1533` -- git copy detection only from the set of modified files (the copy source must change in the same commit).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/diff.rs` -- add `a_copy_is_one_file_with_its_source` next to the rename test -- covers hunks.rs:430.

**Acceptance Criteria:**
- Given the copy fixture, when `Repo::diff` runs on C, then `new.txt` is `ChangeKind::Copied { from: "old.txt" }`.
- Given the fix, when `cargo make test` runs, then it is green and hunks.rs is back at 100%.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 11 findings — high 0, medium 0, low 8, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) Copy's content diff not pinned (left side at source) — added `hunks.is_empty()` and `(0, 0)` asserts for new.txt.
  - `[low]` `[patch]` (blind) Name/doc say "is one file" but two files result — renamed to `a_copy_names_its_source_which_stays_modified`.
  - `[low]` `[reject]` (blind) Unchanged-source boundary (`Added`, not `Copied`) untested — that is jj-lib/gix behaviour, not Zanshin's; adding a test is new scope for a coverage fix-up. The doc pointer half was patched (doc now cites `git_backend.rs` `CopySource::FromSetOfModifiedFiles`).
  - `[low]` `[reject]` (blind) Path filters / `--from --to` not repeated for the copy — the record-filtering path is shared and already pinned by the rename test; more test code for no new line.
  - `[low]` `[patch]` (blind) Modified source's counts not asserted — added one-hunk and `(1, 1)` asserts for old.txt.
  - `[low]` `[reject]` (blind) Parity-oracle check for the copy — oracle tests are a separate suite; out of a coverage fix-up's scope, unlikely to matter day to day.
  - `[low]` `[patch]` (edge) Copy's hunks/counts never asserted — same root cause as the first blind finding; fixed by that patch.
  - `[low]` `[reject]` (edge) Path filter / FromTo not exercised for `Copied` — same as the blind filter finding; rejected for the same reason.
  - `[false]` `[reject]` (verification-gap) No gaps found — a report, not a defect.
  - `[false]` `[reject]` (intent) Diff covers line 430, not the suspected map_err closures — the lcov's only 0-hit hunks.rs line is 430; the intent named the closures as "likely" only.
  - `[false]` `[reject]` (intent) No commit, baseline raise or Auto Run Result yet — produced at finalize; hunks.rs returns to 100.00%, equal to its baseline, so no raise is due.

## Auto Run Result

Status: done

- **Failure 1 (coverage: hunks.rs 99.76% < 100.00%)** — fixed by adding `a_copy_names_its_source_which_stays_modified` (`crates/zanshin-jj/tests/it/diff.rs`), which reaches the only uncovered line, hunks.rs:430 (`CopyOperation::Copy => ChangeKind::Copied`). The suspected `map_err` closures were already covered. Commit: b6a8ba12d1cca6a9a9ff43b8569cc31eab1b7e5a.
- Files: `crates/zanshin-jj/tests/it/diff.rs` — one new integration test; this spec.
- Review: 4 patches applied (all low), 4 lows rejected, 3 false; nothing deferred. Follow-up review recommended: false (patched: high 0, medium 0, low 4).
- Verification: `cargo test -p zanshin-jj --test it diff::` passed; full `cargo make test` exit 0, "coverage-check: OK — coverage held at 99.43% (35179/35381 lines)". `coverage-baseline.txt` unchanged: hunks.rs is back at its 100.00% baseline, nothing rose.
- Residual risk: the test depends on gix copy detection (`FromSetOfModifiedFiles`); a jj-lib pin bump that changes it fails this test loudly.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it diff::` -- expected: all pass
- `cargo make test` -- expected: exit 0
