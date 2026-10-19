---
title: 'Story 9.23 closing run — a failed snapshot step writes no reconcile operation'
type: 'bugfix'
created: '2026-10-19'
status: 'done'
baseline_revision: '29d9b184bb21efbf5b210c0a33300935fc3bb6fd'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      When the auto-update-stale recovery's trailing snapshot fails, the partial report's `was_snapshot_taken` is measured against the recovered operation, not the one `run` loaded, so it can read `false` although the recovery wrote operations.
    evidence: |-
      `snapshot::run` (crates/zanshin-jj/src/snapshot.rs:433) returns `crate::stale::recover(...)?`'s error as is; the flag was last set by `snapshot_locked` inside `trailing_snapshot` (crates/zanshin-jj/src/stale.rs:362), whose baseline is the repo the recovery left behind. A trailing step that fails before writing leaves the heads at that repo's op, so the flag reads `false` while the stale snapshot / `reset git head` / `update-stale` operations stay in the op log — against `run`'s doc ("whether the head moved off the operation loaded here"). Pre-existing since Story 9.23; no test covers a failing trailing snapshot. The CLI computes no `changed` on an error path, so this is a Zanshin-only report fact.
    location: >-
      crates/zanshin-jj/src/snapshot.rs:429-437; crates/zanshin-jj/src/stale.rs:362
    severity: low
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 9.23's `deferred:`), verified against the current code: when a step of the implicit snapshot fails, `snapshot_locked`'s error arm (`crates/zanshin-jj/src/snapshot.rs:462-470`) reloads the head with jj-lib's `RepoLoader::load_at_head` only to set the partial report's `was_snapshot_taken`. With divergent operation heads at that moment (a concurrent writer), that load MERGES them and writes a `reconcile divergent operations` operation that names no workspace — while the CLI's `workspace_helper_with_stats` (`cli/src/cli_util.rs:493-497` @ v0.46.0) just returns the snapshot error and writes nothing more; its next command reconciles, naming its workspace (`resolve_operation`, `:800-829`).

**Approach:** The error arm stops loading the head: it only READS the operation heads (`op_heads_store().get_op_heads()`, no merge, no write) and sets `was_snapshot_taken` to whether they are anything other than exactly the operation the snapshot started from. Divergent heads stay divergent for the next call's head load (`snapshot::load_head`), which reconciles them naming this workspace, as the CLI's next command does.

## Boundaries & Constraints

**Always:**
- On a failed step, `snapshot_locked` writes no operation of its own; the operations the steps committed before the failure stay (unchanged behavior).
- `was_snapshot_taken` on the error path: `false` iff the op heads are exactly `[loaded op id]`; `true` for any other set (a single moved head, divergent heads, a leftover ancestor head). An unreadable op-heads store leaves the flag at its default (as an unloadable head did).
- The success arm and every other caller-visible field of `Precondition` are untouched.
- Rust: clippy pedantic `-D warnings`, rustfmt, doc comments updated where they describe the reload; coverage never drops.

**Never:**
- No change to the in-verb `load_at_head` calls elsewhere in `zanshin-jj` (they stay with Story 9.46's audit, already in the ledger) and no change to `load_head`, `run`, `stale.rs` or `convert.rs` beyond what the error arm needs.
- No change to Story 9.23's spec, `epic-9-context.md`, `epics.md`, `sprint-status.yaml`, `project-context.md` or existing deferred-work.md bullets; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Divergent heads at the failure | two sibling op heads off the loaded op, then a step fails (wrong-typed `snapshot.max-new-file-size`) | the step's error is returned; op heads still the two siblings; no `reconcile divergent operations` written; `was_snapshot_taken == true` | the step's `PreconditionError::Config` |
| Nothing written before the failure | single head == loaded op, step fails | `was_snapshot_taken == false`, no new operation | existing witness `a_wrong_typed_knob_is_refused_only_once_the_held_lock_is_free` |
| A step committed before the failure | colocated `import git head` written, then the knob fails | `was_snapshot_taken == true`, op log holds `import git head` only | existing witness `a_wrong_typed_knob_fails_after_the_head_import_like_the_cli` |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/snapshot.rs` -- `snapshot_locked` :449-472 (error arm :462-470 calls `workspace.repo_loader().load_at_head()`); its doc :442-448; `load_head` :279-307 (the CLI-style named reconcile the NEXT call uses); `run` :410-440 (calls `load_head` then `snapshot_locked`); `lock_git_import_export` :261-277; `StepCtx` :530-540; `CommandEnv::load` :339-348; inline `mod tests` :821-900 (add the witness here — `snapshot_locked` is `pub(crate)`).
- Other callers of `snapshot_locked` (behavior follows automatically, no edits): `crates/zanshin-jj/src/stale.rs:362` (`trailing_snapshot`), `crates/zanshin-jj/src/convert.rs:451` (`maybe_snapshot`).
- jj-lib 0.46.0 `op_heads_store.rs` (vendored at `~/.cargo/registry/src/index.crates.io-*/jj-lib-0.46.0/src/op_heads_store.rs`) -- `OpHeadsStore::get_op_heads` :65 (async, read-only, may hold ancestor heads); `resolve_op_heads` :85-162 is what merges and writes.
- CLI reference -- `git -C ../jj show v0.46.0:cli/src/cli_util.rs`, `workspace_helper_with_stats` :473-517: a `SnapshotWorkingCopyError::Command` is returned as is (`:497`), no reload.
- Test patterns -- divergence via two `base.start_transaction()` commits off one loaded repo: `crates/zanshin-jj/tests/snapshot_precondition.rs:602-629`; inline repo fixture `test_helpers::pin_test_env()` + `crate::Repo::init(tmp.path(), None)` + `repo.workspace()`/`workspace_mut()`: `crates/zanshin-jj/src/stale.rs:399-427`; effective config `crate::config::load(&repo)` (`repo.rs:342`); wrong-typed knob via `.jj/repo/config.toml` `snapshot.max-new-file-size = true` (`tests/snapshot_colocated.rs:424-446`).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/snapshot.rs` -- error arm: replace the `load_at_head` reload with a read of `op_heads_store().get_op_heads()`; `was_snapshot_taken = heads != [loaded_op_id]`; update the arm comment and `snapshot_locked`'s doc (failure path reads the heads, writes nothing; divergent heads are reconciled by the next call's `load_head`) -- the CLI writes nothing after a failed snapshot step.
- `crates/zanshin-jj/src/snapshot.rs` (`mod tests`) -- witness for the matrix's first row: init a repo, write the bad knob into the repo config, load config + `CommandEnv`, `load_head` → base, two sibling transactions off base, `snapshot_locked` with a non-colocated `StepCtx` → `Err(Config)`; assert two op heads remain, neither is a `reconcile divergent operations`, and `was_snapshot_taken` is true -- fails against the old `load_at_head` reload (it leaves one merged head).

**Acceptance Criteria:**
- Given divergent op heads when a pre-verb snapshot step fails, when `snapshot_locked` returns, then no operation was written by it and the next call's head load reconciles the heads naming this workspace (existing witness `the_precondition_reconciles_divergent_heads_as_this_workspace`).
- Given the change, when `cargo make test` runs unpiped from the repo root, then it exits 0 and `coverage-baseline.txt` is not lowered (an auto-raise is committed with the code).

## Spec Change Log

## Review Triage Log

### 2026-10-19 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 10, false 7, maybe-false 0
- findings:
  - `[false]` `[reject]` (blind 1) The error-path flag says "true" when a concurrent writer moved the heads, not only when a step wrote — the old `load_at_head` reload answered the same `true` for a concurrent writer (merged head ≠ loaded op), and the field's doc is "whether the head operation changed during the precondition"; the semantics are unchanged by this diff.
  - `[low]` `[reject]` (blind 2) A raw `get_op_heads()` can read `[]` (non-atomic store mid-update) or a leftover ancestor head and set `true` with nothing moved — real only in a race against a concurrent op-heads update (the precondition's `load_head` just cleaned ancestor heads); the fix is an extra guard / a DAG walk on a path nobody meets in everyday use.
  - `[low]` `[patch]` (blind 3) The CLI citation is off by one — `Err(SnapshotWorkingCopyError::Command(err)) => return Err(err)` is `cli_util.rs:498` @ v0.46.0 — patched in the arm comment and the test doc (the spec's intent-contract keeps ":493-497", read-only).
  - `[low]` `[patch]` (blind 4) "An unreadable store leaves the flag at its default" is wrong for `trailing_snapshot`'s pre-filled report — patched: "leaves the flag as it was".
  - `[low]` `[defer]` (blind 5) When the stale recovery's trailing snapshot fails, the flag is measured against the recovered op, not `run`'s loaded op, and can read `false` though the recovery wrote operations — pre-existing since Story 9.23 (`snapshot.rs:429-437`, `stale.rs:362`); deferred (frontmatter `deferred:`, mirrored in deferred-work.md).
  - `[low]` `[patch]` (blind 6) The witness checks only a head count and a description string — patched: it captures both sibling op ids from `tx.commit` and asserts the head set is exactly them.
  - `[low]` `[patch]` (blind 7) The witness never shows the next head load reconciles — patched: it ends with `load_head` and asserts a `reconcile divergent operations` naming this workspace.
  - `[false]` `[reject]` (blind 8) `run`'s doc calls the flag "the CLI's `changed`" unqualified — that sentence describes the recovered SUCCESS path, where the CLI does compute `changed`; the error path's flag is documented in `snapshot_locked`.
  - `[low]` `[patch]` (blind 9) `let commit = …; drop(commit);` is noise — patched with blind 6 (plain `.expect` statement).
  - `[low]` `[reject]` (edge 1) An empty `get_op_heads()` read sets `true` — same as blind 2, rejected there.
  - `[low]` `[defer]` (edge 2) The recovery path's flag baseline — same root cause as blind 5, deferred there.
  - `[low]` `[patch]` (edge 3) The doc's claim "the next call's `load_head` reconciles them" does not hold for a next call without a precondition (e.g. `resolve_workspace_root`, `workspace.rs:207`, still uses `load_at_head`) — patched: the doc says "a later head load … the next precondition's `load_head`"; those in-verb loads stay with Story 9.46's audit (already in the ledger, not mirrored again).
  - `[false]` `[reject]` (intent 1) The intent's surface is the reconcile op's workspace name, the diff makes no reconcile op at all — the defect is an unnamed reconcile written on that path; writing none removes it, and the CLI writes none there (`cli_util.rs:493-498`), so this is the CLI-parity fix the project rule asks for (Design Notes); the next load's named reconcile is witnessed.
  - `[false]` `[reject]` (intent 2) The ledger's "reconcile-op witness per site" is inverted — the witness now asserts no op on the failure path AND the named reconcile on the next load (blind 7 patch).
  - `[false]` `[reject]` (intent 3) The test calls `snapshot_locked` directly, not through its callers — the three callers pass their arguments through unchanged and the error arm is inside `snapshot_locked`; divergence between the precondition's own `load_head` and a failing step cannot be staged through the public API.
  - `[low]` `[reject]` (intent 4) The flag's ancestor-head / empty-set semantics changed — same as blind 2, rejected there.
  - `[false]` `[reject]` (intent 5) No Auto Run Result, no commit — a mid-run state; finalize writes both.

## Design Notes

**Why read the heads instead of switching to `load_head`.** The ledger's follow-up proposes `snapshot::load_head`, which would make the reconcile op name this workspace. But the CLI writes no reconcile op here at all: `workspace_helper_with_stats` returns the snapshot error without touching the op heads, and the reconcile happens on the next command's `load_from_workspace`. A read of the op heads answers the only question the arm asks ("did the head move off the loaded op?") with no write, so Zanshin's op log after a failed verb matches the CLI's, and the next verb's `load_head` writes the named reconcile exactly where the CLI's next command would.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --lib snapshot::tests` -- expected: the new witness passes (and fails with the old reload restored).
- `cargo test -p zanshin-jj --test snapshot_colocated --test snapshot_precondition` -- expected: green (the single-head error-path witnesses keep their `was_snapshot_taken` values).
- `cargo make test` (repo root, unpiped; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0; coverage held or raised.

## Auto Run Result

Status: done (2026-10-19). Blocking condition: none. Code commit: bbeb79a63afec04166d4e4b43367bc6c6dd05ceb.

**Items handed to this closing run.**
1. **`snapshot_locked`'s error arm reloads the head with jj-lib's `load_at_head` — fixed** (commit `bbeb79a63afec04166d4e4b43367bc6c6dd05ceb`).
   - Verified first: the failure path (`crates/zanshin-jj/src/snapshot.rs`, `snapshot_locked`'s `Err` arm) called `workspace.repo_loader().load_at_head()` only to set the partial report's `was_snapshot_taken`; with divergent op heads that load merged them and wrote a `reconcile divergent operations` with no workspace name (the deliberate break below proves it: the restored reload leaves one merged head). The CLI's `workspace_helper_with_stats` returns the snapshot error and writes nothing more (`cli_util.rs:498` @ v0.46.0).
   - Fixed the CLI's way rather than with the ledger's suggested `load_head` swap (Design Notes): the arm only READS the op heads and writes nothing; the next precondition's `load_head` reconciles them naming this workspace, as the CLI's next command does. The in-verb `load_at_head` calls stay with Story 9.46's audit (the ledger line's other half, not this item's location); Story 9.23's code changed only in this arm.

**Summary.** On a failed pre-verb snapshot step (verb precondition, stale recovery's trailing snapshot, conversion's `maybe_snapshot`), Zanshin no longer writes a workspace-less reconcile operation; `was_snapshot_taken` on that path is `false` only while the op heads are exactly the operation the snapshot started from.

**Files changed:**
- `crates/zanshin-jj/src/snapshot.rs` — the error arm reads `op_heads_store().get_op_heads()` instead of `load_at_head`; `snapshot_locked`'s doc and the arm comment; new inline witness `a_failed_step_leaves_divergent_heads_unreconciled` (exact sibling head set after the failure, then a named reconcile on the next `load_head`).
- Tracking: this spec; `deferred-work.md` ("Surfaced in the closing run of Story 9.23": 1 item).

**Review findings.** 17 findings (high 0, medium 0, low 10, false 7).
- **Patched, 5 entries (all low):** the CLI line citation `:498` (blind 3); "leaves the flag as it was" (blind 4); the witness pins the exact head set and drops the `drop(commit)` noise (blind 6 + 9); the witness ends with the named reconcile on the next head load (blind 7); the doc's "next call" claim narrowed to the next precondition's head load (edge 3). The implementation subagent was not re-engaged (a resumed agent reports asynchronously, which this unattended run cannot wait for); the parent applied the patches.
- **Deferred (new, mirrored in deferred-work.md):** the stale recovery's failure path measures `was_snapshot_taken` against the recovered op (blind 5 + edge 2; low, pre-existing since 9.23).
- **Rejected, low:** an empty or ancestor-holding op-heads read setting `true` (blind 2 + edge 1 + intent 4: only in a race against a concurrent op-heads update right after `load_head` cleaned the ancestors; the fix is a guard / DAG walk).
- **False, 7:** concurrent-writer `true` (blind 1: same as the old reload), `run`'s "CLI's `changed`" (blind 8: the success path), the remedy's surface and witness shape (intent 1, 2: CLI parity; the named reconcile is witnessed), the direct-call test level (intent 3), the mid-run state (intent 5).

**Follow-up review recommendation:** false — this first pass patched 5 entries, all low (0 high, 0 medium).

**Verification:**
- `cargo test -p zanshin-jj --lib snapshot::tests`: 5 passed (before and after the review patches).
- `cargo test -p zanshin-jj --test snapshot_colocated --test snapshot_precondition`: 27 + 27 passed (incl. the single-head failure witnesses `a_wrong_typed_knob_fails_after_the_head_import_like_the_cli`, `a_wrong_typed_knob_is_refused_only_once_the_held_lock_is_free`, and `the_precondition_reconciles_divergent_heads_as_this_workspace`).
- Deliberate break: the old `load_at_head` reload restored → the new witness fails (implementation run: "left: 1, right: 2" on the head count; after the patches it fails again), restored.
- `cargo make test` (repo root, unpiped to a log, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset): implementation run — green on the third run (run 1 failed on the crate's "no direct `start_transaction` in `src/`" guard, fixed with `start_repo_transaction`; run 2 failed once in the unrelated `projects_window_test.dart` "↩ opens a project" timing test, which passed alone and in run 3). After the review patches: exit 0, coverage held at 99.40 % (15445/15538 lines, 59 files), extern-fn coverage OK; `coverage-baseline.txt` unchanged.
- Matrix audit: row 1 (divergent heads) — the new witness; rows 2 and 3 — the existing `snapshot_colocated.rs` witnesses named above; all ran and passed.

**Residual risks:**
- `was_snapshot_taken` on a failed step reads `true` for a transient empty or ancestor-holding op-heads read (rejected low).
- Verbs that load the head without a precondition (the in-verb `load_at_head` calls) still reconcile without a workspace name — Story 9.46's audit, already in the ledger.
- `projects_window_test.dart`'s "↩ opens a project; a missing one does not open" failed once under the gate's load (outside this story, not changed).
