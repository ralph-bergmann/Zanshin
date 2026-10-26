---
title: 'Fix-up 2 after the leftover runs A–C of the story loop 9.25…9.46 — coverage regressions in change.rs and commit_views.rs'
type: 'chore'
created: '2026-10-26'
status: 'done'
baseline_revision: 'd0854be7b1308a4443d1c0708d1789cc64ec40a1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/coverage.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `cargo make test` at d0854be fails only in its coverage step (failure 1): `crates/zanshin-jj/src/change.rs` 98.80% < 100.00% (line 198) and `crates/zanshin-jj/src/commit_views.rs` 96.90% < 98.87% (lines 235-237, 308-313). Line 198 is leftover run C's (0e180ac) `ResolveError::Backend` arm of `get_change`'s inline error mapping, now a line of its own (the old `.map_err(be)?` sat on a line other paths covered). Lines 308-313 are leftover run A's (b46a030) `short_prefixes_failed`, kept by run C for interdiff's commit-id side; no test loads a broken `revsets.short-prefixes` through `interdiff` with a valid commit-id hex. Lines 235-237 (`be`) were already uncovered at the baseline (265 lines, 3 uncovered = 98.87%).

**Approach:** change.rs — move `get_change`'s `ResolveError → ChangeError` closure into a private `res(e, id)` mapper (the `commit_views.rs::res` / `file.rs::res` house pattern) and unit-test every arm inline, since an index read failure cannot be induced through the public API. commit_views.rs — extend the existing broken-short-prefixes integration test with `interdiff` over a valid commit-id hex, which must refuse `RevsetResolutionError` with jj-lib's load error and no hints (287/290 = 98.97% ≥ 98.87%).

## Boundaries & Constraints

**Always:** the `res` extraction is behavior-neutral (same four arms, same outputs); tests assert the mapped variant and its fields, not only execution; the `coverage-baseline.txt` the green gate auto-raises is committed with the fix.

**Never:** no lowered baseline entry, no `exclude_prefix`, no other production change; no test-only code in `src/` outside `#[cfg(test)]`; no new fixture regeneration.

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/change.rs:182-208` -- `get_change`; lines 195-199 the inline `map_err(|e| match e { … })` over `crate::op_support::ResolveError` (arms: `NotFound | NoWorkingCopy(_)` → `NotFound { id }`, `Resolution { reason, hints }` → `RevsetResolutionError`, `Backend(reason)` → `Backend`). Inline test module at :291-308 (imports `get_change, ChangeError, ChangeId`).
- `crates/zanshin-jj/src/op_support.rs:619-632` -- `ResolveError` (`pub(crate)`; variants `NotFound`, `NoWorkingCopy(String)`, `Resolution { reason, hints }`, `Backend(String)`); :684-719 `resolve_change` — `Backend` only from `index.resolve_change_prefix`, unreachable in an integration test.
- `crates/zanshin-jj/src/commit_views.rs:262-277` -- `res`, the template for a mapper fn; its inline tests (`res_keeps_a_resolution_refusal_with_its_hints`) are the test pattern.
- `crates/zanshin-jj/src/commit_views.rs:306-313` -- `short_prefixes_failed`; called only at :337 inside `resolve_side`'s `RevisionRef::CommitId` arm after the hex check.
- `crates/zanshin-jj/tests/it/change_id_prefix.rs:148-193` -- `a_broken_short_prefixes_refuses_only_a_valid_id` (`BROKEN_SHORT = short-prefixes = "missing"`, `failed` = "Failed to resolve short-prefixes disambiguation revset"); already asserts the malformed commit-id `InvalidInput` at :189-192. `CommitId`, `CommitViewError`, `RevisionRef` already imported.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/change.rs` -- extract the closure into `fn res(e: ResolveError, id: &ChangeId) -> ChangeError` (doc comment), call it from `get_change`; add an inline test mapping each of the four `ResolveError` variants and asserting the resulting variant and fields.
- `crates/zanshin-jj/tests/it/change_id_prefix.rs` -- in `a_broken_short_prefixes_refuses_only_a_valid_id`, add `interdiff(Some(RevisionRef::CommitId(CommitId(<valid hex, e.g. "ab">))), None, &[])` asserting `CommitViewError::RevsetResolutionError { reason, hints }` with `reason.starts_with(failed)`, `reason.contains("missing")`, `hints.is_empty()`; update the doc comment.

**Acceptance Criteria:**
- Given the change, when `cargo test -p zanshin-jj --lib -- change::tests` and `cargo test -p zanshin-jj --test it -- change_id_prefix` run, then all pass.
- Given the change, when `cargo make test` runs, then every step passes with `change.rs` at 100.00%, `commit_views.rs` ≥ 98.87%, no file regressing, and the auto-raised `coverage-baseline.txt` is committed with the fix.

## Spec Change Log

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 10 findings — high 0, medium 0, low 7, false 3, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind) `commit_views.rs` baseline not raised, so the new interdiff test may not reach `short_prefixes_failed` — the gate's lcov shows `commit_views.rs` 287/290 = 98.97% (lines 308-313 covered, only `be` 235-237 open); docs/coverage.md raises only on a rise greater than `epsilon_pct = 0.10`, and 98.97 − 98.87 = 0.10.
  - `[low]` `[reject]` (blind) the `commit_content.rs` raise 97.32 → 97.60 is unexplained — it is the gate's own auto-raise from the leftover runs' earlier tests (this diff does not touch the file); line coverage over a fixed test set is deterministic, and the intent asks for the raised baseline to be committed. Named in the Auto Run Result.
  - `[low]` `[patch]` (blind) the new `res` doc calls `commit_views.rs::res` its template although `NoWorkingCopy` maps differently — doc reworded: no template claim, `NoWorkingCopy` is never raised for an id-carrying resolve and folds into `NotFound`.
  - `[low]` `[reject]` (blind) the unit test pins the `NoWorkingCopy` arm `get_change` can never produce — the arm is the exhaustive match's pre-existing mapping (the old closure had it); pinning it costs one assertion, and the doc now says it is unreachable for an id.
  - `[low]` `[patch]` (blind) the test's `NotFound { id } if id == "zk"` bindings shadow the local `id` — rebound as `{ id: echoed } if echoed == "zk"`.
  - `[low]` `[reject]` (blind) only interdiff's `from` side is exercised under the broken set — `from` and `to` go through the one `resolve_side`; a second call adds no line and no behavior.
  - (edge-case layer: no findings.)
  - (verification-gap layer: no gaps.)
  - `[low]` `[reject]` (intent) the `Backend` arm is covered through the extracted `res`, not through `get_change` — an index read failure in `index.resolve_change_prefix` cannot be provoked through the public API; the call site is one covered line and the extraction is behavior-neutral (house pattern `commit_views.rs::res`).
  - `[low]` `[reject]` (intent) `commit_views.rs` 235-237 (`be`) stay uncovered — pre-existing at the baseline (265 lines, 3 uncovered = 98.87%); the failure is the per-file regression, which is fixed; covering `be` needs a jj-lib backend failure on a read path.
  - `[false]` `[reject]` (intent) no commit / hash / Auto Run Result yet — written at finalize (5edac8a, this spec).

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib -- change::tests` -- expected: all pass
- `cargo test -p zanshin-jj --test it -- change_id_prefix` -- expected: all pass
- `cargo make test` -- expected: green, no REGRESSION / BELOW FLOOR

## Auto Run Result

Status: done

**Failures (from the loop's final `cargo make test` at d0854be):**
1. coverage (`change.rs` 98.80% < 100.00%, `commit_views.rs` 96.90% < 98.87%) — FIXED by 5edac8aa43902c6442ccd452c52b6039a1b311df. `change.rs:198` (run C's `ResolveError::Backend` arm, a line of its own since 0e180ac) — `get_change`'s closure extracted to the private `res(e, id)` (behavior-neutral, same four arms) and pinned by the inline `res_maps_every_resolve_error`; an index read failure cannot be provoked through the public API. `commit_views.rs:308-313` (run A's `short_prefixes_failed`, b46a030) — `tests/it/change_id_prefix.rs` `a_broken_short_prefixes_refuses_only_a_valid_id` now calls `interdiff` with commit-id hex `ab` under `short-prefixes = "missing"` and asserts `RevsetResolutionError` with jj-lib's load error and no hints. `commit_views.rs:235-237` (`be`) were already uncovered at the baseline and stay so; the file is at 287/290 = 98.97% (no auto-raise: the rise equals the 0.10 epsilon). The same commit carries the gate-written raise `commit_content.rs` 97.32 → 97.60. No entry lowered, no `exclude_prefix`.

**Files changed:** `crates/zanshin-jj/src/change.rs` (mapper `res` + inline test), `crates/zanshin-jj/tests/it/change_id_prefix.rs` (one interdiff case in an existing test), `coverage-baseline.txt` (gate-written), this spec.

**Review:** 2 patches (low: `res` doc no longer claims `commit_views.rs::res` as its template; test bindings no longer shadow `id`), 0 deferred, 8 rejected with reasons in the triage log (5 low, 3 false). Follow-up review: false (patched: 0 high, 0 medium, 2 low).

**Verification:** `cargo test -p zanshin-jj --lib -- change::tests` 2 passed; `cargo test -p zanshin-jj --test it -- change_id_prefix` 6 passed; full `cargo make test` from this process exit 0 twice — before and after the review patches, the second on the tree committed as 5edac8a (no REGRESSION / BELOW FLOOR; zanshin-jj it 1474 passed, parity oracle 497 passed; gate stamp written). Each gate run exceeded the 600 s tool timeout and was moved to the background by the harness; this run waited for it in the same turn by polling its exit file, so no fallback was needed.

**Residual risk:** `get_change`'s routing of a real index failure to `ChangeError::Backend` is pinned only at the mapper, not end to end.
