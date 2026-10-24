---
title: 'Story 9.12 closing run — `status` without `@` succeeds like the CLI, the op verbs reload the head in this workspace, the flaky merge-diff test made deterministic'
type: 'bugfix'
created: '2026-10-24'
status: 'done'
baseline_revision: '87e71bb53c44b7626b89ad7c64fc45f02c177a15'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      Every other verb still reloads the head after the pre-verb snapshot with jj-lib's `load_at_head`, so a divergence another process creates in that window is reconciled without a workspace name; the CLI runs the verb on the repo its snapshot left, reconciled in this workspace.
    evidence: |-
      The other `load_at_head` sites across crates/zanshin-jj/src/ (verbs and reads, e.g. mutate.rs, bookmark_ops.rs, op_log.rs op_show / op_diff, status.rs working_copy_status); this run changed only undo / redo / op restore / op revert (its spec's Never). The only observable difference is the reconcile operation's workspace_name, reached only under a concurrent op-head divergence.
    location: >-
      crates/zanshin-jj/src/mutate.rs:1041
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 9.12's run deferred three items, verified at `87e71bb`:
1. `op_show_diff::op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` flakes: `diverge_with` (`crates/zanshin-jj/tests/it/op_show_diff.rs:282-297`) writes the two describes back to back, so their operations' end timestamps (milliseconds) can tie; `op_heads_store::resolve_op_heads` orders the heads by `time.end` only (jj-lib 0.46.0 `op_heads_store.rs:154`) after `dag_walk_async::heads` returned them as a `HashSet` (jj-core `dag_walk_async.rs:492`), so a tie merges in random order and the predecessor cycle the test pins appears only in one order.
2. `Repo::status` refuses a workspace without `@` (`StatusError::NoWorkingCopy`, `crates/zanshin-jj/src/status.rs:100-103`), while the CLI's `cmd_status` prints "No working copy." and succeeds (`cli/src/commands/status.rs:195-197` @ v0.46.0) — a state 9.12 made ordinary (root restore, undo to the root view, revert of `add workspace`). The Dart decoder turns the absent ids into `''` (`packages/zanshin_core/lib/src/ffi/status.dart:109-110`).
3. `undo` / `redo` / `op_restore` / `op_revert` (`crates/zanshin-jj/src/op_log.rs:205`, `:389`, `:765`, `:810`) reload the head after the pre-verb snapshot with jj-lib's `load_at_head`, which reconciles divergent op heads without a workspace name; the CLI's head load (`load_from_workspace` → `resolve_operation`, `cli_util.rs:800-829`) names this workspace — `snapshot::load_head` (`snapshot.rs:313`) is that port.

**Approach:** (1) make `diverge_with` order the two branches by time deterministically (the second describe ends strictly after the first). (2) Make `@` optional end to end in the status result: Rust `Status.working_copy_change_id` / `parent_change_id` become `Option<ChangeId>` (both absent together), `StatusError::NoWorkingCopy` goes (no emitter left), absent fields on the wire, Dart `String?`. (3) The four verbs load the head through `snapshot::load_head`, a `PreconditionError::Backend` mapped to `MutateError::Backend` (the error code stays `jj.jj_lib_error`).

## Boundaries & Constraints

**Always:**
- CLI v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/status.rs`). Without `@`: `status` succeeds, `files` empty, both change ids absent (`None` / ABSENT / `null`), warnings and precondition reported as for any status call.
- With `@`: unchanged results (both ids present; root fallback for the parent as today).
- `.fbs`: no structural change — `Status`' doc comment states when the ids are absent; `cargo make codegen` regenerated and committed.
- Docs: `docs/rust-error-codes.md` `jj.no_working_copy` row (status no longer emits it; the other emitters stay), `docs/ffi-abi.md` status row and any status prose; `zanshin_status` rustdoc `# Errors` drops `jj.no_working_copy`.
- Item 3: only the four named verbs change; their error variants/codes are unchanged; the reconcile operation a divergent head load writes names this workspace.
- Tests per item (below); all-test fallout of the `Option` change fixed with `expect`/`!` in tests only.

**Never:**
- No change to other verbs' head loads (every verb in the crate reloads with `load_at_head`; out of these items), no status of conflicted bookmarks / untracked paths / path filters, no UI code, no new error or warning code.
- Never regenerate fixtures, never lower `coverage-baseline.txt`, never touch Story 9.12's spec, `epics.md` or `epic-9-context.md`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Status after root restore | `op_restore("000000000000")`, then `status()` | `Ok`, `files` empty, both ids `None`; FFI ABSENT; Dart `null` | — |
| Status of a forgotten workspace | `@` removed via jj-lib (existing test setup) | same as above | — |
| Status with `@` | any fixture | ids present as today | — |
| Op verb on divergent heads | two sibling ops published, then each of `undo` (merge-op refusal), `redo` (nothing to redo), `op_restore("ffffffffffff")`, `op_revert("ffffffffffff")` called directly | the single op head afterwards is `reconcile divergent operations` with `workspace_name` = this workspace | the verb's own refusal, unchanged |
| Flaky test | `diverge` then `op_diff` | always "Predecessors cycle detected around commit …" | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/tests/it/op_show_diff.rs:282-297` `diverge_with` -- after the first describe, wait until the wall clock is past that operation's end (or sleep ≥ 2 ms) before the second describe, with a comment naming `resolve_op_heads`' end-timestamp sort and the `HashSet` tie order; shared by `op_show_of_a_merge_operation_has_no_diff`, `op_revert` merge-refusal test (`op_restore_revert.rs`) — neither order-sensitive.
- `crates/zanshin-jj/src/status.rs` -- `Status` fields :17/:19 → `Option<ChangeId>` (doc: both absent without `@`); `working_copy_status` :95-178: no `@` → `Ok(Status { files: vec![], None, None })`; `StatusError::NoWorkingCopy` :66-67 removed, docs :91-94 updated.
- `crates/zanshin-jj/src/repo.rs:590-599` `Repo::status` -- doc `# Errors` drops `NoWorkingCopy`, says what a workspace without `@` returns (the CLI's "No working copy.").
- `crates/zanshin-ffi/src/status.rs` -- `map_status_err` :22-38 loses the arm (and the `JJ_NO_WORKING_COPY` import if unused here); `status_to_envelope` :79-99 writes each id only when `Some`; rustdoc :108 drops `jj.no_working_copy`, adds the absent-ids sentence; inline tests :147-253 updated + a no-`@` serialiser case.
- `schemas/envelope.fbs:1182-1188` `Status` -- doc comment: ids ABSENT exactly when this workspace has no `@` (`files` then empty). Then `cargo make codegen`.
- `packages/zanshin_core/lib/src/ffi/status.dart:26-46, :107-112` -- `workingCopyChangeId` / `parentChangeId` → `String?` (doc: `null` without `@`, the CLI's "No working copy."), decoder passes the nullable values through.
- `crates/zanshin-jj/src/op_log.rs:205, :389, :765, :810` -- replace the `load_at_head` reload with one private helper `fn load_head(workspace) -> Result<Arc<ReadonlyRepo>, MutateError>` over `crate::snapshot::load_head` (map `PreconditionError::Backend(r)` → `MutateError::Backend(r)`, any other variant via `MutateError::Precondition`); fn docs mention it. Template for divergent siblings: `snapshot.rs:1000-1067` `a_failed_step_leaves_divergent_heads_unreconciled` (`start_repo_transaction` on a base head, two commits). Inline test in `op_log.rs`'s `#[cfg(test)]` calling the four `pub(crate)` fns directly with a `VerbContext::new(..)` (`snapshot.rs:420`).
- Tests to update / add:
  - `crates/zanshin-jj/tests/it/status.rs:302-325` -- flip `status_on_workspace_without_wc_commit_returns_no_working_copy` to the success shape (rename); fallout `.0` → `.as_ref().expect(..)` across `tests/it/*.rs` (`status.rs`, `change.rs`, `commit_views.rs`, `revset.rs`, …) and `crates/zanshin-ffi` tests/benches (compiler-driven).
  - `crates/zanshin-jj/tests/it/op_restore_revert.rs:137` root-restore test -- add `status()` afterwards: `Ok`, empty, `None` ids (the CLI-parity scenario).
  - `crates/zanshin-jj/tests/it/api_stability.rs` -- the `StatusError::NoWorkingCopy` reference (if any) removed; pin `Status` field types `Option<ChangeId>` like neighbouring pins.
  - `crates/zanshin-ffi/tests/it/status_ffi.rs` -- a workspace without `@` → ok envelope, both ids `None`, files empty.
  - Dart: `packages/zanshin_core/test/ffi/status_test.dart` (synthetic absent ids → `null`), `test/worker/op_verbs_test.dart:155` root-restore test (then `status()`: `workingCopyChangeId` / `parentChangeId` `null`, files empty); fallout `!` in `packages/zanshin_core/test/**` and `app/test/features/projects/worker_project_repos_test.dart` (analyzer-driven).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/tests/it/op_show_diff.rs` -- deterministic `diverge_with` -- item 1.
- `crates/zanshin-jj/src/{status,repo}.rs`, `crates/zanshin-ffi/src/status.rs`, `schemas/envelope.fbs` + codegen, `packages/zanshin_core/lib/src/ffi/status.dart` -- optional `@` end to end -- item 2.
- `crates/zanshin-jj/src/op_log.rs` -- `load_head` helper in the four verbs + inline divergent-heads test -- item 3.
- Tests and fallout listed in the Code Map; `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- as in Always.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- mark the three "Surfaced in Story 9.12" items resolved (date, commit) in the file's existing resolved-note style; mirror any NEW deferral under `## Surfaced in the closing run of Story 9.12 (bmad-build-auto, 2026-10-24)`.

**Acceptance Criteria:**
- Given `op_diff_of_a_rebasing_merge_operation_fails_like_the_cli`, when it runs 40 times isolated, then it passes every time.
- Given a Dart caller after `opRestore('000000000000')`, when it calls `status()`, then it gets a `WorkingCopyStatus` with `null` ids and no files — and the pinned `jj status` in a scratch repo after `jj op restore 000000000000` prints "No working copy." (checked by hand, recorded in Verification).
- Given the targeted checks in Verification, when run, then all pass, `git status --porcelain` is clean and every commit ends with the co-author trailer.

## Spec Change Log

- 2026-10-24 (implementation) — **Item 1's root cause was not the op-head order.** Ordering the two `diverge` describes by end time (the Code Map's fix) still failed 4 of 40 isolated runs whose end times were distinct and ordered. The real cause: `op_diff`'s own `merge_operations` of the merge op's two parents re-rebases the second branch's commit, and the predecessor cycle appears only when that rebase reproduces exactly the commit the head load's merge wrote; the Git backend stores the committer timestamp in whole seconds, so the two merges agree only within one second (the pinned CLI too: with `JJ_TIMESTAMP` set `jj op diff` fails with the cycle every time, with the wall clock and > 1 s between the merges it prints the diff). Amended: the test pins `debug.commit-timestamp` (the CLI's `JJ_TIMESTAMP`) in the fixture's repo config; `diverge_with` stays unchanged. KEEP: the Design Notes' point that pinning `JJ_OP_TIMESTAMP` would be wrong still holds (op heads tie, `HashSet` order) — only the commit timestamp is pinned. The intent-contract's Problem text for item 1 describes the first hypothesis; this entry supersedes it.

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 21 findings — high 0, medium 0, low 13, false 8, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `head_load_error`'s non-`Backend` arm can never run (`snapshot::load_head` only returns `PreconditionError::Backend`) and its test feeds an impossible input — helpers and test removed; the four verbs call `crate::snapshot::load_head(workspace)?` (wire code unchanged, `jj.jj_lib_error`), `# Errors` names `MutateError::Precondition`.
  - `[low]` `[patch]` (blind) two conventions for the same head load in `op_log.rs` (`op_integrate` → `Precondition(Backend)`, the four verbs → `Backend`) — same root as the row above; fixed with it.
  - `[low]` `[patch]` (blind) `working_copy_status` still reloads with `load_at_head` and the new deferral did not name it — deferral evidence (frontmatter + deferred-work.md) now names `status.rs` `working_copy_status`; the reload itself stays out of the three items.
  - `[false]` `[reject]` (blind) `Status` / `WorkingCopyStatus` allow one id without the other — the only producer (`working_copy_status`) sets both or neither in its two returns, and the decoder only reads buffers that producer wrote; no reachable half-present state.
  - `[low]` `[reject]` (blind) no parity-oracle scenario for `jj status` after a root restore — the oracle compares repo state and warning counts, not a read's output (reads need hand audit, epic context); the CLI's "No working copy." was checked by hand against the pinned binary and the outcome is pinned at zanshin-jj, FFI and Dart.
  - `[low]` `[reject]` (blind) status without `@` witnessed only via root restore and a forgotten workspace, not undo-to-root / revert of `add workspace` — all reach the same view state (no wc id for this workspace) and the same single branch in `working_copy_status`.
  - `[low]` `[reject]` (blind) the divergent-heads test drives each verb only into a refusal — the reconcile under test happens in the head load before any verb logic; a success path adds setup without witnessing more of the change.
  - `[false]` `[reject]` (blind) the reconcile op lacks the CLI's command-args attribute — a GUI call has no command line; `snapshot::load_head` (pre-existing, every precondition) passes none by design, as 9.12 recorded for `op integrate`.
  - `[low]` `[patch]` (blind) `status_ffi` accepted an absent `files` vector — now asserts `Some(0)`.
  - `[false]` `[reject]` (blind) the `jj.no_working_copy` registry row contradicts itself — registry rows accumulate dated history; the row now states explicitly that `zanshin_status` no longer emits it since this run.
  - `[low]` `[patch]` (blind) half-updated Dart docs (`WorkingCopyStatus` / `files`, `status()` throws lists missing `jj.config_error` / `jj.stale_working_copy`) — docs completed.
  - `[low]` `[patch]` (blind) bookkeeping: "commit pending" placeholders, no sprint-status note of the API change — hashes filled and a CLOSING RUN note added to the 9.12 sprint-status row at finalisation.
  - `[low]` `[reject]` (blind) the flake fix `fs::write`s the repo config instead of appending — the fixture has no repo config (never regenerated), so nothing is lost; an append adds code for a state that cannot occur.
  - `[false]` `[reject]` (edge-case) one-present-one-absent ids decode silently — same as the blind half-present row.
  - `[low]` `[patch]` (edge-case) `envelope.rs` `JJ_NO_WORKING_COPY` doc still named `status.rs` — now lists the remaining emitters only.
  - `[false]` `[reject]` (edge-case, claim) `diverge_with` unchanged against the Approach — the Spec Change Log records the re-measured root cause (commit timestamp, whole seconds) that superseded it.
  - `[false]` `[reject]` (intent 1) the test pins one of the CLI's two outcomes — the ledger's option "pin `JJ_TIMESTAMP`"; under a pinned clock the pinned CLI produces exactly that outcome (checked).
  - `[low]` `[reject]` (intent 2) item 2's parity scenario not on the oracle surface — same as the blind oracle row.
  - `[low]` `[reject]` (intent 3) item 3 implements the `load_head` reading, not the snapshot's-repo reading, and the test bypasses the snapshot window — the ledger offers both; the snapshot's-repo flow is the crate-wide pattern change recorded as this run's deferral; the window cannot be hit deterministically, the test witnesses the load path it reaches.
  - `[false]` `[reject]` (intent 4) no `## Auto Run Result` / hashes in the diff — written at finalisation, after the commit.
  - `[false]` `[reject]` (intent 5) deferred-work.md items edited in place — marking an item resolved is not re-mirroring it; the intent forbids mirroring deferred items again.

## Design Notes

- **Why not pin `JJ_OP_TIMESTAMP` for item 1:** a pinned op timestamp makes the two end times tie on every run, so the `HashSet` order decides — 50 % flaky instead of rare. Distinct, ordered end times are what make the order deterministic (first describe merged first, the order the test was checked against).
- **Why `snapshot::load_head` and not the snapshot's own repo for item 3:** the CLI runs the verb on the repo its snapshot left (no reload); every Zanshin verb reloads after the precondition (~30 `load_at_head` sites), which would need the precondition to hand its repo through `VerbContext`. The ledger names `load_head` as a fix; it makes the only observable difference — the reconcile operation's workspace — the CLI's. The crate-wide reload pattern is not in these items.

## Verification

**Commands (story-loop gate rule — no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj` -- all pass; `cargo test -p zanshin-jj --test it op_show_diff::op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` ×40 -- all pass
- `cargo test -p zanshin-ffi` -- all pass
- `cargo test -p zanshin-parity --test oracle` -- all pass (op verbs changed)
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean; `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed, rerun leaves no diff
- `packages/zanshin_core`: `cargo make --allow-private test-core`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed .` -- clean; `app/`: `dart analyze --fatal-infos`, `flutter test test/features/projects/worker_project_repos_test.dart` -- clean

**Manual checks:**
- Pinned CLI (`target/debug/jj` from `zanshin-parity`, or the oracle's binary) in a scratch repo under the session scratchpad: `jj git init`, `jj op restore 000000000000`, `jj status` prints "No working copy." and exits 0.

**Deviation from the Approach, item 1 (root cause re-measured):** ordering the two `diverge` describes by end time (the Code Map's `diverge_with` wait) was implemented first and did NOT fix the flake — 36 of 40 isolated runs passed, and the failing runs had distinct, correctly ordered op end times (e.g. …442 ms vs …536 ms). The real cause: `op diff` merges the merge op's two parents itself (`merged_repo` → `merge_operations`), re-rebasing the second branch's commit; the predecessor map cycles only when that rebase yields the very commit the head load's merge wrote, and the Git backend stores the committer timestamp in whole seconds, so the two merges agree only within one second. Probed in-test (a 1.1 s sleep between the head load and `op_diff` → success every time; `debug.commit-timestamp` pinned → the cycle every time) and with the pinned CLI (`JJ_TIMESTAMP` set → "Internal error: Predecessors cycle detected …", exit 255; wall clock with 1.2 s between the reconcile and `jj op diff` → the diff, exit 0). So the wait was reverted (`diverge_with` unchanged) and the test pins `debug.commit-timestamp` (the CLI's `JJ_TIMESTAMP`) in the fixture's `.jj/repo/config.toml` before `diverge`; its doc comment says why. The Design Notes' "why not pin `JJ_OP_TIMESTAMP`" stands — the pin is the COMMIT timestamp, not the operation timestamp.

**Checks run (2026-10-24, closing run; full gate deliberately not run — story-loop gate rule):**
- `cargo test -p zanshin-jj` — 351 unit + 1214 integration passed, 1 ignored (pre-existing); run twice (before and after the final clippy/doc touch-ups).
- `cargo test -p zanshin-jj --test it op_show_diff::op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` ×40 isolated — 40/40 passed (twice: after the fix and after the final edits). With only the end-time ordering wait it was 36/40.
- `cargo test -p zanshin-ffi` — 214 unit + 348 integration passed (new `status_to_envelope_without_a_working_copy_leaves_both_ids_absent`, `status_ffi::status_without_a_working_copy_returns_ok_with_absent_ids`).
- `cargo test -p zanshin-parity --test oracle` — 330 passed (no ledger change).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean (after moving the test's `type Verb` alias to the top of its fn, `items_after_statements`); `cargo fmt --all --check` — clean; `cargo check --workspace --all-targets` — clean (zanshin-mcp unaffected).
- `cargo make codegen` — regenerated `zanshin_ffi.h`, `bindings.dart` (the `zanshin_status` rustdoc) and both FlatBuffers accessors (the `Status` doc comment); a rerun leaves no diff.
- `packages/zanshin_core`: `cargo make --allow-private test-core` (pinned env) — 1032 passed (incl. the new `decodes absent change ids as null` and the extended `opRestore of the root operation …`); `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed .` — 0 changed.
- `app/`: `dart analyze --fatal-infos` — no issues; `flutter test test/features/projects/worker_project_repos_test.dart` with `test-flutter`'s pinned env (`XDG_CONFIG_HOME=target/test-xdg-config`, JJ/GIT pins; bare `flutter test` trips the file's env guard) — 32 passed.
- Manual CLI check (pinned `target/debug/jj`, scratch repo under the session scratchpad): `jj git init`, `jj op restore 000000000000` (warns "The current workspace 'default' no longer exists …"), `jj status` prints "No working copy." and exits 0.
- Coverage not measured (gate rule). The new branches have witnesses: the no-`@` return in `status.rs` (jj + ffi integration tests), both arms of `op_log::head_load_error` (inline test), `op_log::load_head` (the divergent-heads inline test, which fails with jj-lib's `load_at_head` — its reconcile names no workspace).
- Not committed (run rule): `git status --porcelain` shows the closing run's changes only; the commit and its co-author trailer are the orchestrator's.

**Checks run (2026-10-24, review fix-ups; only the edited files' tests):**
- Review fix-ups: the four restoring verbs call `crate::snapshot::load_head(workspace)?` as `op_integrate` does (a head-load failure is `MutateError::Precondition(Backend)`, wire code still `jj.jj_lib_error` — this replaces the Approach's `Backend` → `Backend` mapping, whose other arm could never run); the private `load_head` / `head_load_error` and their unit test are gone, each `# Errors` block names `MutateError::Precondition`. `status_ffi` asserts `files` present and empty; `envelope.rs`' `JJ_NO_WORKING_COPY` doc drops `status.rs`; the Dart `WorkingCopyStatus` / `files` docs name the no-`@` case and the `status()` throws lists name `jj.config_error` / `jj.stale_working_copy`; the new deferral names `status.rs` `working_copy_status`.
- `cargo test -p zanshin-jj --lib op_log::` — 4 passed (incl. `the_restoring_verbs_reconcile_divergent_heads_in_this_workspace`); `cargo test -p zanshin-ffi --test it status_ffi::` — 3 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean; `cargo make codegen` — no drift; `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings lib` — no issues, `dart format` — 0 changed.

**Checks run (2026-10-24, after the review fix-ups, orchestrator):**
- `cargo fmt --all --check` — clean; `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 350 unit + 1214 integration passed, 1 ignored (pre-existing).
- `cargo test -p zanshin-ffi --test it -- status_ffi:: op_log_ffi::` — 19 passed.
- `cargo test -p zanshin-parity --test oracle` — 330 passed.

## Auto Run Result

Status: done

**Items.**
1. **Fixed (0b707044e216c226864c8016778139a0b4029dbe).** `op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` is deterministic: the test pins `debug.commit-timestamp` (the CLI's `JJ_TIMESTAMP`) in the fixture's repo config. Root cause re-measured (Spec Change Log): not the op-head order but the Git backend's whole-second committer time — `op diff`'s own merge of the two parents reproduces the head load's rebase (and so the predecessor cycle) only within one second; the pinned CLI behaves identically. 40/40 isolated runs pass (36/40 with the op-head ordering alone).
2. **Fixed (0b707044e216c226864c8016778139a0b4029dbe).** `Repo::status` in a workspace without `@` succeeds like the CLI's "No working copy." (checked by hand against the pinned `jj`): `Status.working_copy_change_id` / `parent_change_id` are `Option<ChangeId>` (both `None`, `files` empty), `StatusError::NoWorkingCopy` removed, ids ABSENT on the wire (`.fbs` doc, codegen), Dart `String?` (`null`, no `''`); `zanshin_status` no longer emits `jj.no_working_copy` (registry, ffi-abi.md, rustdoc, `envelope.rs`). Witnessed at zanshin-jj (forgotten workspace, status after `op restore 000000000000`), FFI (serialiser + integration) and Dart (decoder + real-cdylib after a root restore).
3. **Fixed (0b707044e216c226864c8016778139a0b4029dbe).** `undo` / `redo` / `op restore` / `op revert` load the head with `snapshot::load_head` (as `op_integrate` already did), so divergent op heads are reconciled in this workspace; a head-load failure is `MutateError::Precondition(Backend)`, wire code unchanged (`jj.jj_lib_error`). Witness: `op_log::tests::the_restoring_verbs_reconcile_divergent_heads_in_this_workspace` (fails with jj-lib's `load_at_head`).

**Files changed.**
- `crates/zanshin-jj/src/status.rs`, `repo.rs` — optional ids, no-`@` success, docs.
- `crates/zanshin-jj/src/op_log.rs` — the four verbs' head load + inline divergent-heads test.
- `crates/zanshin-ffi/src/status.rs`, `envelope.rs` — ids written only when present, mapping arm removed, docs; inline no-`@` test.
- `schemas/envelope.fbs` + regenerated `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart` — `Status` doc.
- `packages/zanshin_core/lib/src/ffi/status.dart`, `worker/{handle,isolate}.dart` — `String?` ids, docs.
- Tests: `crates/zanshin-jj/tests/it/{status,op_restore_revert,op_show_diff,api_stability}.rs` + `Option` fallout; `crates/zanshin-ffi/tests/it/status_ffi.rs` + fallout; Dart `test/ffi/status_test.dart`, `test/worker/op_verbs_test.dart` + fallout; `app/test/features/projects/worker_project_repos_test.dart` fallout.
- Docs: `docs/rust-error-codes.md`, `docs/ffi-abi.md`; `deferred-work.md` (three items resolved, one new), `sprint-status.yaml` (CLOSING RUN note).

**Review.** 21 findings (4 layers): 13 low, 8 false. Patched 7 entries, all low (the unreachable head-load mapping arm + the two conventions in `op_log.rs`, the deferral naming `working_copy_status`, the FFI `files` assertion, Dart docs, `JJ_NO_WORKING_COPY` doc, bookkeeping). Rejected: 8 false (half-present ids unreachable ×2, reconcile args attribute by design, registry history row, superseded Approach recorded, pinned-clock CLI outcome, Auto Run Result at finalisation, resolved-not-re-mirrored), 6 low (oracle compares no read output ×2, the other no-`@` paths share one branch, success path of the reconcile test, `fs::write` on a fixture without repo config, the load_head reading per the ledger). Deferred: 1 new low (every other verb and read still reloads with `load_at_head`), mirrored in deferred-work.md.

**Follow-up review recommended: false** (first pass; patched by verdict: 0 high, 0 medium, 7 low entries).

**Verification.** See `## Verification` → the three "Checks run" lists: fmt, clippy, `cargo test -p zanshin-jj` / `zanshin-ffi` / oracle, the flaky test ×40, codegen idempotence, the zanshin_core suite, analyze and format, `app/` analyze + the touched test file, the manual CLI check. Full gate and coverage not run (story-loop gate rule).

**Residual risks.** Coverage unmeasured (every new branch has a witness). The `Option` ids are a breaking change of `Status` / `WorkingCopyStatus` for every caller (only tests used them). Every other verb's head reload still names no workspace when it reconciles (deferred, low).
