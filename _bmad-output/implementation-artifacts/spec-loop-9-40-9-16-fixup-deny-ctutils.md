---
title: 'Fix-up after the story loop 9.40 9.16 — cargo deny advisory RUSTSEC-2026-0385 (ctutils)'
type: 'chore'
created: '2026-10-23'
status: 'done'
baseline_revision: 'b4d89bfcb1716f82eeab349eb6600ac9fbc6800a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred:
  - summary: >-
      parallelize's merge-child-with-outside-parent arm (a child of the parallelized set that also has a parent outside it keeps that parent) has no test.
    evidence: |-
      Coverage run at cc5e816: parallelize.rs 95.95%, lines 102-104 (`else { new_parents.push(parent.clone()) }`) never executed; no case in crates/zanshin-jj/tests/it/parallelize_arrange.rs or the parity-oracle scenarios builds such a merge. Pre-existing Story 9.16 code, above the 80% floor, not a gate failure.
    location: >-
      crates/zanshin-jj/src/parallelize.rs:102
    severity: medium
  - summary: >-
      RewritePlan::execute's cycle-detected error arm (Zanshin returns an error where the CLI panics) has no test.
    evidence: |-
      Coverage run at cc5e816: arrange.rs 99.50%, line 247 (`|_| MutateError::Backend("cycle detected".to_owned())`) never executed; the inline tests build RewritePlans by hand and could add a two-commit cycle. Pre-existing Story 9.16 code, above the floor.
    location: >-
      crates/zanshin-jj/src/arrange.rs:247
    severity: low
---

<intent-contract>

## Intent

**Problem:** The loop's final `cargo make test` at b4d89bf fails in `cargo deny` (failure 1): advisory RUSTSEC-2026-0385 (non-constant-time mask generation / `u128` comparisons) hits `ctutils 0.4.3`, a transitive dependency of jj-lib (`jj-core 0.46.0 → blake2 0.11.0 → digest 0.11.3 → ctutils`); the fix is `>=0.4.4`. The coverage ratchet never ran, so the loop's new code (Stories 9.40, 9.16: `arrange.rs`, `parallelize.rs`, `zanshin-ffi/src/rebase.rs`, three new C exports) has not yet met it.

**Approach:** Bump `ctutils` in `Cargo.lock` with `cargo update -p ctutils` (resolves to 0.4.5, semver-compatible, lockfile-only — no manifest change). Then run the full gate; if the coverage ratchet reports a regression or a new file below the 80% floor, close each gap by adding tests at the reported file, and commit the gate-raised `coverage-baseline.txt` with the fix.

## Boundaries & Constraints

**Always:** Lockfile-only dependency change, exactly the `ctutils` entry; fix every further red step at its cause; a coverage gap is closed by tests (inline `#[cfg(test)]` for private items, `tests/it/` for integration, a `packages/zanshin_core` cdylib test per uncovered `extern fn`); commit the auto-raised baseline with the fix.

**Never:** No `deny.toml` ignore/exemption for the advisory, no `cargo update` of other packages, no `Cargo.toml` edits, no lowered baseline entry, no `exclude_prefix`, no production-behavior change.

</intent-contract>

## Code Map

- `Cargo.lock:601-604` -- `ctutils 0.4.3` entry; `cargo update -p ctutils --dry-run` → `v0.4.3 -> v0.4.5`, 1 package, nothing else moves.
- `deny.toml` -- advisories config; read-only (no ignore added).
- `coverage-baseline.txt` -- per-file floors; new files default 80%.
- `crates/zanshin-jj/src/arrange.rs`, `crates/zanshin-jj/src/parallelize.rs`, `crates/zanshin-ffi/src/rebase.rs` -- the loop's new files, first time under the ratchet; test locations if a gap is reported (zanshin-jj/zanshin-ffi integration tests live in the single binary `tests/it/main.rs`).
- `packages/zanshin_core/test/` -- cdylib tests; every new `extern fn` needs a hit here for the cross-FFI coverage union.

## Tasks & Acceptance

**Execution:**
- `Cargo.lock` -- `cargo update -p ctutils` -- clears RUSTSEC-2026-0385 at its cause.
- Gate-reported coverage gaps (only if `cargo make test` reports REGRESSION / BELOW FLOOR) -- add tests at the named file -- the ratchet's sanctioned fix.
- `coverage-baseline.txt` -- commit the gate's auto-raise -- ratchet rule.

**Acceptance Criteria:**
- Given the bumped lockfile, when `cargo deny check` runs, then advisories pass with no new ignore.
- Given the change, when `cargo make test` runs, then every step passes (coverage without REGRESSION / BELOW FLOOR), and the gate-stamp is written.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 10 findings — high 0, medium 1, low 4, false 5, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) baseline entries committed in the `fix(deps)` commit instead of with the code that earned them — the intent explicitly directs "commit a raised coverage-baseline.txt with the fix"; the earning code (9.16) predates the gate's first ratchet run.
  - `[medium]` `[defer]` (blind) `crates/zanshin-jj/src/parallelize.rs:102-104` — the merge-child-with-outside-parent arm is never run by any test (confirmed: file at 95.95%) — pre-existing Story 9.16 code, above the floor, no gate failure; recorded in `deferred`.
  - `[low]` `[defer]` (blind) `crates/zanshin-jj/src/arrange.rs:247` cycle-error arm of `RewritePlan::execute` never run — pre-existing Story 9.16 code, above the floor; recorded in `deferred`.
  - `[false]` `[reject]` (blind) no evidence existing files' baseline values were checked — the ratchet compares every file: "0 file(s) up, 3 new, 0 removed", no REGRESSION, exit 0.
  - `[low]` `[reject]` (blind) no record why 0.4.5 not 0.4.4 — `cargo update -p` picks the latest compatible release; fix is a spec/commit-message edit (now noted in the Auto Run Result).
  - `[false]` `[reject]` (intent) failure 1 verified only through the run's report — the gate log shows `advisories ok, bans ok` and `EXIT=0` after the bump.
  - `[false]` `[reject]` (intent) reading R3 (proactive cdylib tests for the new exports) not taken — the intent conditions tests on "where it reports a gap"; the ratchet reported `extern-coverage: OK` and all floors met.
  - `[low]` `[reject]` (intent) the spec's Verification `cargo deny check` (licenses) differs from the gate's `advisories bans` — fix is a spec edit; noted in the Auto Run Result.
  - `[low]` `[reject]` (intent) the Auto Run Result did not list failure 1 by number — fix is a spec edit; the finalized Auto Run Result lists it.
  - `[false]` `[reject]` (intent) spec status drifted to an uncommitted `in-review` — step-04 sets `in-review` deliberately; finalize writes `done` and commits.
  - (edge-case layer: no findings; verification-gap layer: no gaps.)

## Verification

**Commands:**
- `cargo deny check` -- expected: advisories ok, bans ok, licenses ok, sources ok
- `cargo make test` -- expected: exit 0

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at b4d89bf):**
1. cargo deny (advisories, RUSTSEC-2026-0385 on `ctutils 0.4.3`) — FIXED by cc5e816. `cargo update -p ctutils` moved only `ctutils` 0.4.3 → 0.4.5 in `Cargo.lock` (0.4.5 = latest semver-compatible release, ≥ the advisory's 0.4.4; its `cmov ^0.5.3` is met by the locked `cmov 0.5.4`, no other entry moves). No `deny.toml` ignore, no `Cargo.toml` edit. The gate's deny step (`cargo deny --workspace check advisories bans`): advisories ok, bans ok.

**Coverage ratchet (first run over Stories 9.40/9.16):** no REGRESSION / BELOW FLOOR, no existing file moved ("0 file(s) up, 3 new, 0 removed"); new files `crates/zanshin-ffi/src/rebase.rs` 100.00%, `crates/zanshin-jj/src/arrange.rs` 99.50%, `crates/zanshin-jj/src/parallelize.rs` 95.95% (all ≥ 80% floor); `extern-coverage: OK` (every extern "C" fn has a cdylib hit). No tests needed. The gate-raised `coverage-baseline.txt` (3 new entries, nothing lowered, no `exclude_prefix`) is committed in cc5e816 with the bump, as the intent directs.

**Files changed:** `Cargo.lock` (ctutils 0.4.3 → 0.4.5), `coverage-baseline.txt` (gate-added floors for the loop's 3 new files), this spec.

**Review:** 10 findings — 0 patches, 2 deferred (untested merge-with-outside-parent arm in `parallelize.rs:102-104`; untested cycle-error arm in `arrange.rs:247` — both pre-existing Story 9.16 code, above floor, not a gate failure), 8 rejected with reasons in the triage log. Follow-up review: false (patched: 0 high, 0 medium, 0 low).

**Verification:** full `cargo make test` (every step planned: `Cargo.lock` is a root manifest) exit 0 at cc5e816 in 1080 s, gate-stamp written, gate-sweep ran. Note: the spec's Verification line's bare `cargo deny check` additionally runs `licenses`, which fails (461 rejections) because `deny.toml` has no licenses allow-list yet by design (release phase); the gate runs `advisories bans` only — a spec slip, not a regression.

**Residual risk:** the two deferred untested branches.
