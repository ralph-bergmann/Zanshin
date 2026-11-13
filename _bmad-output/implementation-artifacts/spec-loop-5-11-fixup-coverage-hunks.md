---
title: 'Story-loop 5.11 fix-up: hunks.rs coverage regression (Words style, line-diff loop)'
type: 'chore'
created: '2026-11-13'
status: 'done'
baseline_revision: 'a02d8f07838bd134565cb41aeeec6fe32d8fc8cf'
review_loop_iteration: 0
followup_review_recommended: false
context: []
warnings: []
deferred:
  - summary: >-
      The coverage gate may count hits from instrumented builds of older source, so a line can read as covered or uncovered at the wrong line number.
    evidence: |-
      Unverified. At 8ed9991e a clean cargo llvm-cov already had the unreachable brace at 0 hits, yet the 5.10 gate reported hunks.rs at 100%. In this run, cargo llvm-cov without clean --workspace merged a stale zanshin-jj object and reported 0 hits on blank lines. lcov_union.rs takes the per-line maximum and cannot tell a stale input. Settled by checking whether cargo make coverage can pick up stale objects or profiles (cargo half and the FFI cdylib under .dart_tool/hooks_runner).
    location: >-
      crates/xtask/src/tasks/lcov_union.rs
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` failed the coverage ratchet: `crates/zanshin-jj/src/hunks.rs` 99.87% < baseline 100.00%. Two lines have 0 hits: 1340 (`lines.push(line);` in `run_lines`, the last piece of a `Words` block without a line break) and 1076 (the closing brace of `if let &[left, right] = &hunk.contents[..] {` in `Walk::resolved_hunks`, whose implicit else cannot run).

**Approach:** (1) Add one inline unit test that runs the `Words` style on a changed block whose last line has no line break (a file without a final newline). (2) Rewrite the line-diff loop to take the two sides by index instead of an `if let` with an unreachable else, so no line is left without a hit; behaviour is unchanged (two inputs always give two sides).

## Boundaries & Constraints

**Always:** Behaviour and every existing test expectation (including the parity oracle) stay unchanged. Tests go inline in `hunks.rs` `mod tests`, using the existing `words` and `render` helpers.

**Never:** Touch `coverage-baseline.txt`, add an `exclude_prefix`, run the full gate (`cargo make test` / `test-full` / `coverage`), or change anything a failure does not need.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Last line without line break | `Words`, left `"a\nold word"`, right `"a\nnew word"` | context line `a`, then removed line 2 `old word` (mark on `old`), then added line 2 `new word` (mark on `new`) | No error expected |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/hunks.rs:1044-1081` -- `Walk::resolved_hunks`; the `if let &[left, right]` at 1058 has an unreachable implicit else, attributed to its closing brace 1076.
- `crates/zanshin-jj/src/hunks.rs:1327-1343` -- `run_lines`; 1339-1341 handle a last piece without `\n`.
- `crates/zanshin-jj/src/hunks.rs:1631` -- `words(left, right, language)` test helper (`Words` style, context 3); `render` at 1695.
- `crates/zanshin-jj/src/hunks.rs:2279` -- `words_leave_a_one_sided_block_unmarked`, a template for the new test.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/hunks.rs` -- add `words_keep_a_last_line_without_a_line_break` to `mod tests` -- covers line 1340.
- `crates/zanshin-jj/src/hunks.rs` -- in `resolved_hunks`, build `hunk_contents` from `hunk.contents[0]` and `hunk.contents[1]` and drop the `if let` block -- removes the unreachable else line 1076.

**Acceptance Criteria:**
- Given the matrix input, when the `Words` diff runs, then the last removed and added lines are `old word` / `new word` without a line break, marked on the changed word.
- Given the fix, when `cargo llvm-cov -p zanshin-jj` runs on `hunks::` and `diff::`, then no `DA:` line of `hunks.rs` has 0 hits.

## Spec Change Log

## Review Triage Log

### 2026-11-13 — Review pass
- verdicts: 9 findings — high 0, medium 0, low 3, false 4, maybe-false 2
- findings:
  - `[low]` `[patch]` (blind) `render` hides a trailing `\n`, so only the added line was proven to lack a line break — added a `text() == "old word"` assert on the removed line.
  - `[low]` `[reject]` (blind) Mixed case (one side with a final newline) untested — no uncovered line and no defect shown; new test scope for a coverage fix-up.
  - `[low]` `[patch]` (blind) Comment above the indexing no longer states what it guards — reworded to "A line diff of two inputs has exactly two contents per hunk, so the indexing cannot panic."
  - `[false]` `[reject]` (blind) Three inputs would fail differently — `diff_by_line(contents.into_array(), …)` takes a fixed `[_; 2]`, so no other count can reach the loop.
  - `[false]` `[reject]` (blind) Code Map line numbers stale — the fix is an edit to this spec.
  - `[maybe-false]` `[defer]` (blind) Root cause of the false 100% (stale or mismatched lcov input) left open — medium if true; settled by checking whether `cargo make coverage` can pick up stale objects or profiles. Deferred and mirrored into deferred-work.md.
  - `[maybe-false]` `[defer]` (intent) Line 1076's "why" answered only in prose, the cause partly a guess — same root cause as the row above; deferred with it.
  - `[false]` `[reject]` (intent) Equivalence rests on an invariant, not a test — the `[_; 2]` input makes other counts unrepresentable; existing tests and the parity oracle pass unchanged.
  - `[false]` `[reject]` (intent) Auto Run Result and deferred-work section missing — written at finalize, in the same commit.
  - (edge-case layer: no findings; verification-gap layer: no gaps)

## Auto Run Result

Status: done

- **Failure 1 (coverage: hunks.rs 99.87% < 100.00%)** — fixed in 0e63134b041661cc08edd29478def4ea755eeaf8:
  - hunks.rs:1340 (`run_lines`, last piece without `\n`): new inline test `words_keep_a_last_line_without_a_line_break` (`Words` on `"a\nold word"` → `"a\nnew word"`).
  - hunks.rs:1076 (brace of the `if let &[left, right]` in `Walk::resolved_hunks`): the two sides are now indexed directly (`hunk.contents[0]`, `[1]`); the input is a fixed `[_; 2]`, so behaviour is unchanged. Why it counted: it already had 0 hits in a clean cargo measurement at 8ed9991e (Design Notes); 5.10's 100% most likely came from a mismatched lcov input, now deferred.
- Files: `crates/zanshin-jj/src/hunks.rs` (one test, loop rewrite); this spec; `deferred-work.md` (one section).
- Review: 2 low patches applied (removed-line assert, comment), 1 low rejected (mixed-newline case: no uncovered line or defect shown), 4 false rejected (see triage log), 1 entry deferred (stale coverage input, medium unverified). Follow-up review recommended: false (patched: high 0, medium 0, low 2).
- Verification (no full gate, per the run's rule):
  - `cargo llvm-cov clean --workspace`, then `cargo llvm-cov -p zanshin-jj --lcov -- hunks:: diff::` to a scratch file: hunks.rs record has 1533 `DA:` lines, none with 0 hits (1058: 607, 1076: 279, 1338: 2). A run without the clean first showed stale 0-hit lines from an old object.
  - `cargo test -p zanshin-jj --lib -- hunks::`: 27 passed. `--test it -- hunks:: diff::`: 63 passed. `cargo test -p zanshin-parity --test oracle -- diff_color_words::`: 11 passed, expectations untouched.
  - `cargo clippy -p zanshin-jj --all-targets -- -D warnings`: clean. `cargo fmt --all --check`: clean.
  - `coverage-baseline.txt` untouched.
- Residual risk: the gate unions with the FFI half; if that half still carries stale line mappings, the gate's numbers may differ from this measurement (see the deferred item).

## Design Notes

Why line 1076 now counts: measured with `cargo llvm-cov -p zanshin-jj -- hunks:: diff::` at 8ed9991e (the last commit before Story 5.11, in a scratch worktree), the same brace (then line 1040) already had 0 hits. Story 5.11 did not create the uncovered line; it was already uncovered in the cargo half of the measurement. The 5.10 gate reported 100% only through the source-level union with the FFI half (`crates/xtask/src/tasks/lcov_union.rs` takes the maximum per line); in 5.11's gate the FFI half (`target/coverage/ffi.lcov`) also reports `DA:1076,0`. A likely cause is that the 5.10 gate's FFI half came from an instrumented cdylib whose line numbers did not match the source, so another hit line landed on 1040; this was not reproduced. The line cannot run either way, so the rewrite is the fix.

## Verification

**Commands:**
- `cargo llvm-cov -p zanshin-jj --lcov --output-path <scratch>/after.lcov -- hunks:: diff::` -- expected: no `DA:<n>,0` in the `hunks.rs` record
- `cargo test -p zanshin-jj --lib -- hunks::` -- expected: all pass
- `cargo test -p zanshin-jj --test it -- hunks:: diff::` -- expected: all pass
- `cargo test -p zanshin-parity --test oracle -- diff_color_words::` -- expected: all pass, expectations untouched
- `cargo clippy -p zanshin-jj --all-targets -- -D warnings` -- expected: clean
- `cargo fmt --all --check` -- expected: clean
