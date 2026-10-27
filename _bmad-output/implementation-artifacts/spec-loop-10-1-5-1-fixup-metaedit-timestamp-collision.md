---
title: 'Fix-up after the story loop 10.1 4.14 4.15 5.1 — metaedit author-timestamp test collides with the fixture commit'
type: 'bugfix'
created: '2026-10-27'
status: 'done'
baseline_revision: '468a629bbc23fc54840431687b9367c5ed865e51'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` fails in the coverage step (failure 1): `metaedit::author_and_author_timestamp_are_set_as_the_cli_sets_them` (`crates/zanshin-jj/tests/it/metaedit.rs:140`) sees the author timestamp one second AFTER the committer timestamp after `--update-author-timestamp`. Reproduced unloaded: 20 of 30 sequential runs fail (the test takes ~0.5 s); none of the loop's stories touched metaedit.

**Approach:** Root cause (Design Notes): Zanshin already matches the CLI — both set the new author timestamp to the rewrite builder's committer timestamp (`metaedit.rs:203-205` = CLI `metaedit.rs` @ v0.46.0). The last step restores every field of the fixture's original `B` commit, so when the test runs within one second the rewrite is byte-identical to that Git object; jj-lib's Git backend then decrements the committer second until the id is new (`git_backend.rs:1443-1459` @ v0.46.0), exactly as the CLI would. The test's last step gets a description no earlier `B` version had, so its object is always new and the exact equality holds deterministically. Then the gate runs on; any further failure (the coverage ratchet for the loop's new files has not been evaluated yet) is fixed at its cause the same way, coverage only by adding tests.

## Boundaries & Constraints

**Always:** the row still proves `--update-author-timestamp` sets the author timestamp to the rewrite's committer timestamp (exact equality) and changes it; a one-line WHY comment at the change; finish with a green `cargo make test` and commit a raised `coverage-baseline.txt` with the code that earned it.

**Never:** no change to `crates/zanshin-jj/src/metaedit.rs` (it is at CLI parity); no relaxed/tolerance assert, retry, sleep or `#[ignore]`; never lower `coverage-baseline.txt` or add an `exclude_prefix`; no change unrelated to a gate failure.

</intent-contract>

## Code Map

- `crates/zanshin-jj/tests/it/metaedit.rs:83-142` -- the failing row; the last step (132-141) calls `metaedit` with only `update_author_timestamp: true`, after `--update-author` (113-130) put back the configured user as author.
- `crates/zanshin-jj/tests/it/metaedit.rs:13-15` -- `message()` helper, reuse for the description.
- `crates/zanshin-jj/tests/it/rebase.rs:105-147` -- `base()`: B is written by `step()` (snapshot, then `describe "B\n"`), author = configured user.
- `crates/zanshin-jj/src/metaedit.rs:192-230` -- read-only: the same author/timestamp logic as the CLI.
- `../jj` @ v0.46.0 `cli/src/commands/metaedit.rs` (`new_author.timestamp = commit_builder.committer().timestamp`) and `lib/src/git_backend.rs:1443-1472` (collision loop, `committer.time.seconds -= 1`) -- read-only evidence.
- `coverage-baseline.txt` -- per-file ratchet; raised automatically by the gate.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/metaedit.rs` -- in the last step of `author_and_author_timestamp_are_set_as_the_cli_sets_them`, also pass `message: Some(message("B2"))`, with a one-line comment: the rewrite would otherwise reproduce the fixture's `B` object when the test runs within one second, and the Git backend shifts the committer second of a colliding commit -- removes the collision at its cause.
- Gate -- run `cargo make test` from the repo root; for every further failure, fix the cause (coverage: add tests to the reported file's inline `#[cfg(test)]` module or the crate's `tests/it/` binary per project-context.md) and record it in the Spec Change Log; commit the raised `coverage-baseline.txt` with the tests.

**Acceptance Criteria:**
- Given the fix, when the row runs 30 times sequentially unloaded, then 0 fail (before: 20 / 30).
- Given all fixes, when `cargo make test` runs from the repo root, then it exits 0.

## Spec Change Log

## Review Triage Log

### 2026-10-27 — Review pass
- verdicts: 12 findings — high 0, medium 1, low 3, false 8, maybe-false 0 (edge-case layer: none; verification-gap layer: no gaps)
- findings:
  - `[medium]` `[patch]` (blind) the B2 description forces the rewrite by itself, so no test in `tests/it` witnesses that `--update-author-timestamp` alone rewrites (the parity oracle collapses recent timestamps to `recent`) — added a flag-only step before the B2 step asserting a new commit id and a changed author timestamp, both of which survive a committer-second shift (d3e2fb2).
  - `[false]` `[reject]` (blind) the exact `"now"` equality asks more than the CLI guarantees — only for a colliding object; the B2 description makes the object unique, so equality holds deterministically (30/30 runs, twice).
  - `[false]` `[reject]` (blind) `assert_ne!` against the 2000 stamp proves nothing about "now" — the exact equality with the committer timestamp, which jj-lib sets to `now`, is what proves it.
  - `[low]` `[reject]` (blind) the `B2` description is never asserted — not the row's subject; the `message` rows in this file witness descriptions; no one is misled by it.
  - `[low]` `[patch]` (blind) the WHY comment omits why the object repeats — reworded: `--update-author` restored the fixture's author, so a rewrite within one second reproduces `B`'s Git object (d3e2fb2).
  - `[false]` `[reject]` (blind) the baseline lines belong to other commits — inside a story loop the gate runs once at the end (project rule since 2026-10-20), so the raised baseline lands with the fix-up, as the intent asks.
  - `[false]` `[reject]` (blind) other restore-to-identical rewrites share the hazard — `git grep "committer().timestamp"` finds no other assert on it; `force_rewrite_rewrites_with_nothing_else_changed`'s new id holds with or without the shift.
  - `[false]` `[reject]` (blind) the spec and paper trail are not committed — committed at finalize below.
  - `[false]` `[reject]` (blind) no evidence the flake is gone — 30/30 sequential unloaded runs after each commit (before: 20/30 failed).
  - `[false]` `[reject]` (intent) neither literal branch was taken — the branch premise (a separate "now") is false at v0.46.0 and Zanshin already uses the builder's committer timestamp; the cause was a Git-object collision, fixed at its cause (Design Notes).
  - `[low]` `[patch]` (intent) the lone-flag case is no longer exercised in `tests/it` — same root cause as the first row, same fix (d3e2fb2).
  - `[false]` `[reject]` (intent) no Auto Run Result / failure list / committed spec yet — written and committed at finalize below.

## Design Notes

Evidence: the fixture's `B` is snapshot at t2 (discardable `@` → author timestamp reset to t2), then described at t3 (author keeps t2). The test's last step writes author = configured user @ T, committer = configured user @ T, same tree, parent, description `B\n` and change-id header. If t2 = t3 = T (same second — the whole test takes ~0.5 s), that Git object already exists with other extras (predecessors), so `GitBackend::write_commit` writes it with committer T-1 s — observed: author …861000, committer …860000. The CLI runs the same jj-lib write and shows the same shift; nothing in Zanshin deviates. A fresh description makes the object unique, so no earlier `B` version can collide.

## Verification

**Commands:**
- `<scratchpad>/loop.sh <it test binary> metaedit::author_and_author_timestamp_are_set_as_the_cli_sets_them 30 1` -- expected: `pass: 30 fail: 0`
- `cargo test -p zanshin-jj --test it metaedit::` -- expected: all passed
- `cargo make test` (repo root) -- expected: exit 0

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test`):**
1. coverage step, `zanshin-jj --test it` — `metaedit::author_and_author_timestamp_are_set_as_the_cli_sets_them` (author timestamp one second after the committer's) — FIXED by 386c48133dcea9ac1ad5d06bb21f533754e5519a (B2 description makes the last rewrite a never-written Git object), review follow-up d3e2fb28a07db09e0e76d346854697bb5e8bfdb6 (flag-only witness restored, comment reworded). Not a race and not a parity gap: the CLI (`metaedit.rs` @ v0.46.0) and Zanshin (`crates/zanshin-jj/src/metaedit.rs:203-205`) both set the author timestamp to the rewrite builder's committer timestamp. The test's last step restored every field of the fixture's `B`; when the test ran within one second (it takes ~0.5 s unloaded: 20/30 runs failed) the rewrite was byte-identical to that Git object, and jj-lib's Git backend decremented the committer second to get a new id (`git_backend.rs:1443-1472`) — the CLI would show the same shift. `src/` unchanged.
2. coverage ratchet (not evaluated in the loop's gate) — no regression: the gate raised `coverage-baseline.txt` (new `hunks.rs` and `source_symbol.rs` at 100.00, `commit_views.rs` 98.87 → 98.99), committed in 386c48133dcea9ac1ad5d06bb21f533754e5519a. Nothing lowered, no `exclude_prefix`.

**Files changed:** `crates/zanshin-jj/tests/it/metaedit.rs` (that row only: flag-only step, B2 step + WHY comment), `coverage-baseline.txt` (gate-raised), this spec.

**Review:** 12 findings — 3 rows patched in 2 entries (1 medium: lone-flag witness lost — 2 rows; 1 low: comment), 0 deferred, 9 rejected with reasons in the triage log (1 low: B2 never asserted; 8 false). Follow-up review: false (patched entries: 0 high, 1 medium, 1 low).

**Verification:** 30-run sequential loop of the row: before 20 fail / 30, after 30 / 30 pass (on 386c481 and on d3e2fb2); `cargo test -p zanshin-jj --test it metaedit::` 13 passed; full `cargo make test` from the repo root exited 0 on d3e2fb2 (coverage held at 99.42%, extern-coverage OK, gate stamped).

**Residual risk:** none known; other `tests/it` rows run on the real clock, but no other assert depends on author == committer timestamps.
