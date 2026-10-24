---
title: 'Loop 9.9-9.12 fix-up 2 — coverage regressions in snapshot.rs and cancel.rs'
type: 'chore'
created: '2026-10-24'
status: 'done'
baseline_revision: '7b188f1968c02f17c20b20d2294235f41db85f29'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred:
  - summary: >-
      The load_at_head source scan stops at any line that trims to `#[cfg(test)]`, so an indented `#[cfg(test)]` item in the middle of production code hides every later production line.
    evidence: |-
      `text.lines().take_while(|line| line.trim() != "#[cfg(test)]")` in the scan added by 80b3f09 (pre-existing logic, unchanged by this fix-up); no file in src/ has an indented `#[cfg(test)]` today, so the hole is latent. Fix: compare the untrimmed line, plus a fixture case.
    location: >-
      crates/zanshin-jj/src/snapshot.rs (tests::load_at_head_offenders)
    severity: low
    resolved: >-
      2026-10-24 — fixed (console session after fix-up 2, commit 7619a28): the scan stops only at an unindented `#[cfg(test)]`; the fixture adds an indented `#[cfg(test)]` item before a later production call, which is reported.
  - summary: >-
      The fix.rs baseline raise (96.89 -> 97.80) comes from 73134a3's never-gated cancel/timeout tests; if any newly covered line depends on a race, the higher baseline can make the gate flake.
    evidence: |-
      Unverified (maybe-false, medium if true). Two green gates in this run (28763a9, 11ab984) both measured fix.rs at >= 97.80, so no flake seen yet. Settled by checking which fix.rs lines the raise added for timing-dependent branches, or by repeated coverage runs.
    location: >-
      crates/zanshin-jj/src/fix.rs, coverage-baseline.txt:67
    severity: medium (unverified)
    resolved: >-
      2026-10-24 — rejected (console session): the rarely-hit cancel/timeout lines are pinned by deterministic sequencing — `cancel_when` cancels only once the tool wrote its pid (fix.rs Ended::Cancelled arm), the SIGKILL escalation (fix.rs kill) is asserted by the test's elapsed >= 2.9 s check, the before-start arm is a unit test; no line's coverage depends on a race.
  - summary: >-
      The trap/SIGKILL cancel test keeps a hand-rolled wait loop whose sleep body runs only when the trap file is not yet written at the first check — the same coverage-timing shape this fix-up removed from the group-kill test.
    evidence: |-
      crates/zanshin-jj/src/cancel.rs `a_process_ignoring_sigterm_gets_sigkill_after_the_grace_period`: `while !trapped.exists() && Instant::now() < deadline { sleep }` (pre-existing, covered in both gates here); the fix-up's "no edits to other tests" kept it out. Could reuse `poll_until`.
    location: >-
      crates/zanshin-jj/src/cancel.rs (tests, ~line 686)
    severity: low
    resolved: >-
      2026-10-24 — fixed (console session after fix-up 2, commit 7619a28): the trap test waits with `poll_until` and asserts the trap is installed.
---

<intent-contract>

## Intent

**Problem:** `cargo make test` at 7b188f1 fails only in its coverage step: (1) `crates/zanshin-jj/src/snapshot.rs` 98.18% < 98.67% — 11 of 604 lines uncovered, 4 of them (1161, 1162, 1165, 1171) in the inline source-scan test `no_production_code_calls_load_at_head` (80b3f09), whose subdirectory, non-`.rs` and offender branches never run on the current `src/` tree; (2) `crates/zanshin-jj/src/cancel.rs` 98.54% < 98.85% — 6 of 412 lines uncovered, 2 of them (736-737) the sleep body of the member wait loop in the inline test `kill_group_signals_a_whole_group_and_never_ours` (bb05395), which is skipped when the member is already gone at the first check.

**Approach:** Make every line the two new tests added run. (1) Split the scan into a test-local helper that walks a given root; the test first runs it over a temp tree holding a subdirectory, a non-`.rs` file and an offending `.rs` file (call in production part, call in a comment, call after `#[cfg(test)]`), asserting it reports exactly the one production offender, then over the real `src/` asserting none — every helper branch runs and the guard is proven able to fail. (2) Replace the test's two hand-rolled wait loops with one test-local poll helper whose sleep always runs through the pid-file wait (the shell needs time to fork and write it); the member wait becomes an assertion on that helper.

## Boundaries & Constraints

**Always:** Test-only changes inside the `#[cfg(test)] mod tests` of the two files; both tests keep their assertions' meaning; the `coverage-baseline.txt` the green gate auto-raises (e.g. `fix.rs` 96.89 → 97.80) is committed with the fix. The older uncovered lines (snapshot.rs 294-298 / 899 / 1063, cancel.rs 240-243) predate the last baseline raise (81e8113) and stay as they are: after the fix the files sit at 597/604 = 98.84% and 408/412 = 99.03%, both above baseline.

**Never:** No production-code change, no lowered baseline entry, no `exclude_prefix`, no test moved out of `src/`, no edits to other tests or files. Never `cd` by bare name; jj runs only in temp dirs.

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/snapshot.rs:1150-1176` -- `no_production_code_calls_load_at_head`: `dirs` stack walk, `is_dir` branch (:1160-1162), non-`.rs` skip (:1164-1165), cut at the first line exactly `#[cfg(test)]`, comment skip, `offenders.push` (:1171).
- `crates/zanshin-jj/src/cancel.rs:703-740` -- `kill_group_signals_a_whole_group_and_never_ours`: pid-file wait loop (:722-725, body covered), member wait loop (:734-737, body uncovered).
- `crates/zanshin-jj/Cargo.toml:49` -- `tempfile` is already a dev-dependency.
- `coverage-baseline.txt:52,67,85` -- `cancel.rs = 98.85`, `fix.rs = 96.89`, `snapshot.rs = 98.67`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/snapshot.rs` -- extract a test-local `fn load_at_head_offenders(root: &Path) -> Vec<String>` from the scan; the test runs it over a `tempfile` tree (subdir + `notes.txt` + offending `.rs`) and asserts exactly one offender at the production line, then over `CARGO_MANIFEST_DIR/src` asserting empty -- every scan line runs.
- `crates/zanshin-jj/src/cancel.rs` -- add a test-local `fn poll_until(done: impl FnMut() -> bool) -> bool` (10 ms steps, 10 s cap, returns the last answer); use it for the pid-file wait and the member-death assertion in the group-kill test -- removes the conditionally-run sleep.

**Acceptance Criteria:**
- Given the change, when `cargo test -p zanshin-jj --lib -- snapshot::tests::no_production_code_calls_load_at_head cancel::tests::kill_group_signals_a_whole_group_and_never_ours` runs, then both pass.
- Given the change, when `cargo make test` runs, then every step passes with no REGRESSION / BELOW FLOOR line, and the auto-raised `coverage-baseline.txt` is committed.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 16 findings — high 0, medium 0, low 10, false 4, maybe-false 2
- findings:
  - `[low]` `[defer]` (blind) an indented `#[cfg(test)]` silently ends the scan — pre-existing scan logic from 80b3f09, latent (no indented one in src/); recorded in `deferred`.
  - `[low]` `[patch]` (blind) the new comment "finds a production call, wherever it hides" overclaims; the UFCS/spaced spellings are not matched — comment reworded to "reports a production `.load_at_head()` call in a nested `.rs` file, and nothing else" (11ab984); widening the match itself rejected: no such spelling exists or is likely, and the matcher is pre-existing.
  - `[low]` `[reject]` (blind) two checks in one test — a fixture failure still fails the test loudly with an assert_eq diff; splitting is restructuring beyond what the failure needs.
  - `[low]` `[patch]` (blind) stale `expect` messages "src dir"/"source" in the helper that now walks any root — changed to "readable dir"/"readable .rs file" (11ab984).
  - `[low]` `[patch]` (blind) the pid-file `poll_until` answer is dropped, so a timeout surfaces as a ParseIntError — wrapped in `assert!(…, "the leader records its member's pid")`, `poll_until` is `#[must_use]` (11ab984).
  - `[low]` `[patch]` (blind) `poll_until`'s sleep/re-check lines ran only if the first check was false (timing-dependent coverage) — first patch (sleep-first `loop` + `if … return`) left the `if`'s closing brace uncovered (gate 2: cancel.rs 98.80 < 99.04, line 751); final form is a `repeat_with(sleep; done()).find(answer || deadline) == Some(true)` chain whose every line runs on every call (11ab984, gate 3 green).
  - `[maybe-false]` `[defer]` (blind) the fix.rs raise is not earned by this diff and could encode a timing-dependent line — would be medium if true; the intent expects the raise; recorded in `deferred` with what settles it.
  - `[low]` `[defer]` (blind) the neighbouring trap/SIGKILL test keeps the old hand-rolled wait loop — pre-existing, outside "no edits to other tests"; recorded in `deferred`.
  - `[low]` `[reject]` (blind) pid reuse could fail the member-death check — macOS pid reuse within 10 s of a death is very unlikely and the check predates this fix-up; a procargs-content guard adds a branch.
  - `[false]` `[reject]` (blind) the spec is untracked with empty logs — finalize writes this log and the Auto Run Result and commits the spec; the 98.84/99.03 predictions were pre-gate estimates, the Auto Run Result records the measured numbers.
  - `[low]` `[reject]` (edge) pid recycled within the poll window — same as the blind pid-reuse row.
  - `[low]` `[patch]` (edge) the claim that `poll_until`'s sleep "always runs through the pid-file wait" is timing-based — same root cause as the blind timing row; fixed structurally (11ab984).
  - `[maybe-false]` `[reject]` (intent) the "predate the last baseline raise (81e8113)" anchor is loose — 81e8113 did not touch the snapshot/cancel entries; the commits that added those lines (fadbbfc, bbeb79a, 910179b) all predate every later baseline write, and the green gate confirms the files clear the baseline with them still uncovered; the fix would be a spec edit.
  - `[false]` `[reject]` (intent) R2 (also cover the older production error arms) not implemented — the intent says "change only what a failure needs" and asks only to check whether they were uncovered at the baseline; they were, and the files pass without them.
  - `[false]` `[reject]` (intent) the positive-detection fixture goes beyond "nothing else" — it is how the formerly dead branches run, test-only.
  - `[false]` `[reject]` (intent) `## Auto Run Result` missing — written at finalize below.
  - (verification-gap layer: no gaps.)

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- snapshot::tests::no_production_code_calls_load_at_head cancel::tests::kill_group_signals_a_whole_group_and_never_ours` -- expected: 2 passed
- `cargo make test` -- expected: exit 0, snapshot.rs ≥ 98.67, cancel.rs ≥ 98.85

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at 7b188f1):**
1. coverage (`snapshot.rs` 98.18% < 98.67%) — FIXED by 28763a9 (review polish 11ab984). The inline scan test now walks a test-local `load_at_head_offenders(root)` helper, first over a `tempfile` tree (subdir, `notes.txt`, `sub/offending.rs` with the call in production code, in a comment and after `#[cfg(test)]`; exactly one offender asserted), then over the real `src/` (none). The formerly dead lines 1161/1162/1165/1171 run. The older uncovered lines (294-298 `FileLock::lock` error arm, 899, 1063) come from fadbbfc / bbeb79a, which predate every later baseline write, so they were already uncovered at the baseline; left as is. `snapshot.rs` 98.67 → 98.87.
2. coverage (`cancel.rs` 98.54% < 98.85%) — FIXED by 28763a9, made timing-independent by 11ab984. The group-kill test's two wait loops became one test-local `#[must_use] poll_until`, finally a `repeat_with(sleep 10 ms; done()).find(answer || deadline) == Some(true)` chain whose every line runs on every call; both waits are asserted. The old 736-737 are gone. 240-243 (cancel-poller spawn-failure arm, 910179b) predate the baseline and stay uncovered. `cancel.rs` 98.85 → 99.04 (raised in 28763a9; held by gate 3).

28763a9 also carries the gate-raised `fix.rs` 96.89 → 97.80 (earned by the second follow-on run, first stamped by this green gate). No entry lowered, no `exclude_prefix`, no production code changed, no test moved out of `src/`.

**Files changed:** `crates/zanshin-jj/src/snapshot.rs` (test module only), `crates/zanshin-jj/src/cancel.rs` (test module only), `coverage-baseline.txt` (gate-raised), this spec.

**Review:** 5 patches (all low: comment wording, expect messages, asserted pid wait, timing-independent `poll_until` ×2 rows), 3 deferred (indented `#[cfg(test)]` hole in the scan, fix.rs raise unverified-flake risk, trap test's old wait loop), 8 rejected with reasons in the triage log. Follow-up review: false (patched: 0 high, 0 medium, 5 low).

**Verification:** gate 1 at 28763a9's tree: `cargo make test` exit 0 (3 files raised, no REGRESSION). The first review patch failed gate 2 (exit 105, `cancel.rs` 98.80 < 99.04 — the sleep-first `loop`'s `if` closing brace never ran); rewritten as the iterator chain. Gate 3 at 11ab984's tree: `cargo make test` exit 0, "coverage held at 99.36%", no REGRESSION / BELOW FLOOR, gate stamp written. `cargo clippy -p zanshin-jj --all-targets -- -D warnings` clean; the two tests pass.

**Residual risk:** the deferred fix.rs raise (unverified timing dependence); otherwise none.
