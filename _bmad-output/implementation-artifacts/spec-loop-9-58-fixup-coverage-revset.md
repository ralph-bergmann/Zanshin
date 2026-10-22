---
title: 'Fix-up after Story 9.58 — coverage regression in revset.rs'
type: 'chore'
created: '2026-10-22'
status: 'done'
baseline_revision: 'c7f63a4a8942ad0b0bd3991d3a50144e0e26ab25'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred:
  - summary: >-
      No project rule stops a loop's new test helper from carrying a never-run `panic!` fallback arm, which drops the file below a 100% baseline.
    evidence: |-
      Second occurrence: remote_changes.rs/drop_actions.rs/config.rs (deferred-work.md:1742, fixed 46031ea) and now revset.rs (593f6c9). Neither _bmad-output/project-context.md nor docs/coverage.md names the pattern; the fix belongs in agent-context files, outside this fix-up's intent.
    location: >-
      _bmad-output/project-context.md (testing rules)
    severity: low
    resolved: >-
      2026-10-23 — fixed (console session, Ralph: rule in project-context.md; commit 8ffb8b1): testing rules forbid a match with a panic! arm in test helpers.
---

<intent-contract>

## Intent

**Problem:** `cargo make test` at c7f63a4 fails only in its coverage step (failure 1): `crates/zanshin-jj/src/revset.rs` 99.71% < baseline 100.00%. The single uncovered line is 738, `Ok(_) => panic!("expected a config error"),` in the inline test helper `fn reason<T>(result: Result<T, ConfigError>) -> String` added by Story 9.58's closing run (593f6c9) — every caller passes an `Err`, so the arm never runs.

**Approach:** Rewrite the helper so no never-run line remains, the same fix earlier fix-ups applied (deferred-work.md "Never-run `panic!` fallbacks in the loop's new tests"): `ConfigError` has the single variant `Load { reason }`, so `let ConfigError::Load { reason } = result.err().expect("expected a config error");` is irrefutable and the test still fails on an `Ok`.

## Boundaries & Constraints

**Always:** Test-only change inside revset.rs's `#[cfg(test)] mod tests`; the helper keeps its signature and still fails a test that gets `Ok`; the `coverage-baseline.txt` the green gate auto-raises (e.g. `creation.rs` 97.00 → 98.12) is committed with the fix.

**Never:** No production-code change, no lowered baseline entry, no `exclude_prefix`, no edits to other files or tests.

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/revset.rs:735-740` -- `reason<T>` helper; callers at :749/:754 (`an_unparseable_alias_is_the_clis_config_error`) always pass an `Err`.
- `crates/zanshin-jj/src/config.rs:284-294` -- `ConfigError` has exactly one variant, `Load { reason: String }`, not `#[non_exhaustive]` → an irrefutable `let` pattern compiles.
- `coverage-baseline.txt:75` -- `revset.rs = 100.00`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- replace the `match` body of `reason` with the irrefutable `let` over `result.err().expect(...)` -- removes the never-run line 738.

**Acceptance Criteria:**
- Given the change, when `cargo test -p zanshin-jj --lib -- revset::tests` runs, then both tests pass.
- Given the change, when `cargo make test` runs, then every step passes with `revset.rs` at 100.00% and no file regressing, and the auto-raised `coverage-baseline.txt` is committed with the fix.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 12 findings — high 0, medium 0, low 6, false 6, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) the Approach calls the irrefutable `let` "the same fix earlier fix-ups applied", but 46031ea used `assert!(matches!(…))` — true, same class (no never-run line), different form; the fix is a spec edit.
  - `[low]` `[defer]` (blind) no project rule prevents a never-run `panic!` fallback in new test helpers (second occurrence) — fix edits agent-context files (project-context.md / docs/coverage.md); recorded in `deferred`.
  - `[low]` `[reject]` (blind) no dated deferred-work.md section for this fix-up — ledger mirroring is the story loop's own closing step; the intent says nothing else.
  - `[false]` `[reject]` (blind) spec untracked, status `in-review`, logs empty — finalize writes `status: done`, this log and the Auto Run Result, and commits the spec.
  - `[false]` `[reject]` (blind) Verification records no results / no gate evidence — the Auto Run Result records them: `cargo make test` exit 0 at b4fff0b, `xtask gate-plan`: 0 paths changed since the last green run.
  - `[low]` `[reject]` (blind) the `creation.rs` raise is not attributed in spec or commit — the fix is a spec/commit-message edit; the Auto Run Result names it (earned by Story 9.58's work, recorded by the gate's first green run).
  - `[false]` `[reject]` (blind) the irrefutable `let` stops compiling if `ConfigError` grows — a compile error is a loud, correct failure, not a defect; the author then picks a form for the new variant.
  - `[false]` `[reject]` (blind) a failing test gives a weaker message — the `Ok` path panics with the identical text "expected a config error"; the old `match` could not show the `Ok` value either (no `Debug` bound).
  - `[low]` `[reject]` (blind) Code Map line numbers are pre-change — they refer to `baseline_revision` c7f63a4; fix is a spec edit.
  - `[low]` `[reject]` (blind) spec `type: 'chore'` vs commit `test(jj):` — cosmetic; fix is a spec edit.
  - `[false]` `[reject]` (intent) no evidence of a green gate and no `## Auto Run Result` — written at finalize below with the gate outcome and b4fff0b.
  - `[false]` `[reject]` (intent) reading R2 (literally "add tests", e.g. a `#[should_panic]` on `Ok`) not followed — the intent points to the helper-rewrite precedent itself, and the uncovered line is in test code; removing it fixes the cause, revset.rs is back at 100.00%.
  - (verification-gap layer: no gaps; edge-case layer: no findings.)

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- revset::tests` -- expected: 2 passed
- `cargo make test` -- expected: green, `revset.rs` 100.00%

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at c7f63a4):**
1. coverage (`revset.rs` 99.71% < 100.00%) — FIXED by b4fff0b. The inline test helper `reason<T>` in `crates/zanshin-jj/src/revset.rs` now reads `let ConfigError::Load { reason } = result.err().expect("expected a config error"); reason` — irrefutable because `ConfigError` has the single variant `Load`, an `Ok` still panics with the same text, and no never-run line (old 738) remains. `revset.rs` is back at 100.00%. The same commit carries the gate-raised `coverage-baseline.txt`: `creation.rs` 97.00 → 98.12 (earned by Story 9.58's work, first stamped by this green gate). No entry lowered, no `exclude_prefix`.

**Files changed:** `crates/zanshin-jj/src/revset.rs` (test helper only, no production change), `coverage-baseline.txt` (gate-raised), this spec.

**Review:** 0 patches, 1 deferred (no project rule against never-run `panic!` fallbacks in test helpers — agent-context edit), 11 rejected with reasons in the triage log (6 false, 5 low). Follow-up review: false (patched: 0 high, 0 medium, 0 low).

**Verification:** `cargo test -p zanshin-jj --lib -- revset::tests` 2 passed; `cargo make test` exit 0 at b4fff0b (no REGRESSION / BELOW FLOOR, gate stamp written); `cargo xtask gate-plan` afterwards: 0 paths changed since the last green run.

**Residual risk:** none beyond the deferred recurrence rule.
