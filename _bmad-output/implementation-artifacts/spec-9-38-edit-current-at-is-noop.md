---
title: 'Story 9.38 — `edit` of the current `@` is a no-op: "Already editing that commit." parity'
type: 'bugfix'
created: '2026-10-25'
status: 'done'
baseline_revision: 'f5778d324dec4dad0dc47663a1766827bcff6256'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: []
deferred: []
---

<intent-contract>

## Intent

**Problem:** `cmd_edit` (`cli/src/commands/edit.rs` @ v0.46.0) resolves the revision, runs `check_rewritable`, and when `get_wc_commit_id() == Some(new_commit.id())` prints "Already editing that commit." and opens NO transaction. Zanshin's `mutate::edit` always calls jj-lib's `MutableRepo::edit`, whose `maybe_abandon_wc_commit` abandons a discardable `@` (empty, undescribed, unreferenced) and re-adds it — the transaction has changes, so `edit commit <id>` is written; a CLI `jj undo` then undoes the wrong operation. Since Story 9.40 the non-discardable case already writes nothing (only through the no-change gate, not the CLI's early return). The card menu's `edit` row (`drop_actions::change_actions`) reports `Available` for the current `@`.

**Approach:** Port the early return: after `plan_edit`'s resolve + rewritability guard, if the commit is the workspace's `@` in the repo the verb loaded, return the house no-op result (`no_op_result`: pre-call head op id) without touching jj-lib's `edit`. `plan_edit` reports that fact so the `edit` row becomes `NoOp` from the same fn.

## Boundaries & Constraints

**Always:** CLI order — resolve, then rewritability (an immutable current `@` still refuses `jj.immutable`), then the early return; the 9.26 pre-verb snapshot still runs first (the comparison is against the post-snapshot `@`, as the CLI's `get_wc_commit_id` is); the no-op result is `no_op_result` (pre-call head op id, `@`'s change id, no finish facts); `drop_actions`' row and the verb share `plan_edit`.

**Never:** no FFI/schema/Dart change (the `MutationResult` shape already carries the no-op); no warning or status fact for "Already editing that commit." (a CLI status line, not a `ui.warning_*`); no change to `finish_verb`'s gate.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Discardable `@` | `@` empty + undescribed; `edit(@)` | Ok; `new_op_id` = pre-call head; op log unchanged; `@` keeps its change AND commit id | — |
| Non-discardable `@` | `@` = described commit; `edit(@)` | Same no-op result (now via the early return) | — |
| Immutable `@` | `immutable_heads()` covers `@`; `edit(@)` | Refuses | `jj.immutable`, no operation |
| Other commit | `edit(B)` | Unchanged: `edit commit <hex>` written | — |
| Card row | `change_actions(@)` | `edit` row `NoOp`; the verb then writes nothing | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs:1341-1397` -- `plan_edit` (resolve + `guard_rewritable`) and `edit` (reload head → tx → `plan_edit` → `MutableRepo::edit` → `rebase_descendants` → `finish_verb`). Early return goes between `plan_edit` and `MutableRepo::edit`; the doc cites `edit.rs:63` @ v0.44.0 → re-point to v0.46.0.
- `crates/zanshin-jj/src/mutate.rs:1536` -- `no_op_result(workspace_name, readonly)` — reuse for the early return (the tx's `base_repo()` = `readonly`).
- `crates/zanshin-jj/src/drop_actions.rs:590-593` -- `change_actions`' `edit` row: `plan_edit(...)?; Ok(Planned::AVAILABLE)` → `no_op` from `plan_edit`'s answer. `rows.workspace` gives the workspace name.
- `crates/zanshin-jj/src/repo.rs:1411-1436` -- `Repo::edit` doc: "a discardable current `@` remains Story 9.38's" → state the no-op for any current `@`.
- jj-lib `repo.rs:1722-1760` (0.46.0, read-only) -- `MutableRepo::edit` → `maybe_abandon_wc_commit`: the reason a discardable `@` writes today.
- `crates/zanshin-jj/tests/it/mutate.rs:295-344` -- edit witnesses; tiny-3-commits' `@` (`layout.wc_change_id`) is the fixture's working-copy commit; `with`-style repo config for immutable alias: see `:168-180`.
- `crates/zanshin-jj/tests/it/drop_actions.rs:955-1223` -- `card()`, `base()` (`@` = `fx.d`, described D), `change_actions_rows_agree_with_their_verbs` (picks b/root/unknown).
- `crates/zanshin-parity/tests/oracle/scenarios.rs:867-874`, `main.rs:56-65` -- `edit_parent` scenario pattern; add scenarios + register ids in `parity!`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- `plan_edit` takes the workspace name and returns the commit plus whether it already is `@` (in `tx.base_repo()`); `edit` returns `no_op_result` when it is, before `MutableRepo::edit`; docs re-pointed to v0.46.0 -- the CLI's early return.
- `crates/zanshin-jj/src/drop_actions.rs` -- `edit` row sets `no_op` from `plan_edit` -- row = verb.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::edit` doc updated -- contract text.
- `crates/zanshin-jj/tests/it/mutate.rs` -- witnesses: discardable `@` (op log + commit id unchanged), immutable current `@` refuses `jj.immutable` with no op -- I/O rows 1, 3.
- `crates/zanshin-jj/tests/it/drop_actions.rs` -- `@`'s card has `edit` = `no_op()`; add `@` (fx.d) to the agreement picks -- I/O row 5.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` -- scenarios `edit_wc` (BASE `@` = C), `edit_discardable_wc` (setup `jj new`), `edit_immutable_wc` (`immutable_heads()` = `@`) -- the oracle is the verb's AC.

**Acceptance Criteria:**
- Given a repo whose `@` is discardable, when `Repo::edit(@)` runs, then the op log head is unchanged, the result's `new_op_id` is the pre-call head and the CLI's `jj edit @` leaves the same repo state (oracle `edit_discardable_wc` matches with no ledger entry).
- Given `immutable_heads()` covering `@`, when `Repo::edit(@)` runs, then it refuses `jj.immutable` and writes nothing, as `jj edit @` does.
- Given the card menu for `@`, when `change_actions(@)` runs, then the `edit` row is `NoOp` and running `edit` afterwards writes no operation.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 13 findings — high 0, medium 0, low 10, false 3, maybe-false 0
- findings:
  - `[low]` `[patch]` `ActionStatus::NoOp` docs (Rust `drop_actions.rs`, `envelope.fbs`, Dart `drop_actions.dart`) list only rebase/squash/bookmark move/revert/restore/absorb — `edit` added with "Already editing that commit."; codegen re-run.
  - `[low]` `[patch]` `Repo::change_actions` doc says "Only the squash reports NoOp" — now names the current-`@` edit row too. The FFI/Dart `changeActions` mirrors make no NoOp claim, so nothing false there.
  - `[low]` `[patch]` `zanshin_edit` / `RepoHandle.edit` docs don't mention the no-op result — one sentence each added.
  - `[low]` `[reject]` row-level tests cover only a non-discardable `@` and no immutable-`@` row — `is_wc` does not depend on discardability and the guard order lives in the one shared `plan_edit`, pinned by `edit_of_an_immutable_current_wc_refuses` and oracle `edit_immutable_wc`/`edit_discardable_wc`; more fixtures add nothing.
  - `[low]` `[patch]` the discardable test's commit-id assertion message ("not re-added") overstates what it proves — message reworded (`@` stays the same commit); the op-log assertions are the regression catch.
  - `[low]` `[patch]` the non-discardable edit test's doc still credits Story 9.40's gate and lacks `finish.is_none()` — doc re-pointed to 9.38's early return, assertion added.
  - `[low]` `[reject]` `plan_edit`'s `(Commit, bool)` is unclear at call sites — two callers, the doc names the bool, both bind it as `is_wc`; a struct is ceremony.
  - `[low]` `[patch]` (same root cause as row 2) `Repo::change_actions` doc contract false for the edit row — fixed with row 2.
  - `[false]` `[reject]` `no_op_result` returns the post-snapshot head, not the "pre-call" head — the house contract (epic context, `finish_verb`'s no-change arm) is the head after the pre-verb snapshot, which the CLI's start-up snapshot also writes; `edit` matches every other no-op verb.
  - `[low]` `[patch]` stale test comments (`zanshin-ffi/tests/it/repo_write_ffi.rs:393`, `zanshin_core/test/worker/mutate_test.dart:159`) say editing `@` to itself mints a replacement — reworded to the 9.38 no-op.
  - `[low]` `[patch]` tracking text (sprint-status `9-38-…`, deferred-work 9.38 bullets, epics Story 9.38) still says `edit` always commits / cites v0.44.0 — updated at finalize.
  - `[false]` `[reject]` the no-op is not exercised through FFI/Dart — `MutationResult` crosses unchanged (`zanshin_edit` wraps `Repo::edit`); the intent's expectations sit at the verb and the preview row, both tested.
  - `[false]` `[reject]` no typed "Already editing that commit." fact — a CLI `ui.status` line; house rule: status lines are typed facts, here the no-op result (pre-call head, `finish: None`), as for every no-op verb.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it mutate::` and `--test it drop_actions::` -- expected: pass
- `cargo test -p zanshin-jj --lib` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass
- `cargo clippy -p zanshin-jj -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean

**Verification notes (2026-10-25, gate rule of the story loop: no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj --test it -- mutate:: drop_actions::` — 63 passed (before and after the review patches).
- `cargo test -p zanshin-jj --lib` — 389 passed.
- `cargo test -p zanshin-parity --test oracle` — 447 passed incl. `edit_wc`, `edit_discardable_wc`, `edit_immutable_wc`, no ledger entry (run before the doc-only review patches). The implementer also disabled the early return temporarily: `edit_discardable_wc` and the discardable mutate test then failed (an operation written) — the witnesses bite.
- `cargo test -p zanshin-ffi --test it -- drop_actions_ffi:: repo_write_ffi:: file_ops_ffi::` — 58 passed.
- `cargo clippy -p zanshin-jj -p zanshin-parity -p zanshin-ffi --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean.
- `cargo make codegen` (the `ActionStatus` doc in `envelope.fbs`) — comment-only changes in `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`; the header/bindings also picked up two doc lines Story 9.25 had left un-regenerated (`zanshin_revset_counts`, `zanshin_find_changes`).
- `packages/zanshin_core`: `dart format --set-exit-if-changed lib test` clean, `dart analyze` no issues, `dart test test/worker/mutate_test.dart test/worker/drop_actions_test.dart` — 36 passed.

## Auto Run Result

Status: done. Blocking condition: none.

**Summary.** `jj edit <@>` parity at v0.46.0: `plan_edit` resolves the target, runs the rewritability guard, then reports whether the target already is the workspace's `@` (post-snapshot); `mutate::edit` returns the house no-op result (pre-call head op id, no finish facts) before jj-lib's `MutableRepo::edit`, which abandoned and re-added a discardable `@` and wrote `edit commit <id>`. The card menu's `edit` row for `@` is `NoOp` from the same fn. An immutable current `@` still refuses `jj.immutable`.

**Files changed** (code commit `5b71805ea891ba8f05fd389e714a6611922079e4`):
- `crates/zanshin-jj/src/mutate.rs` — `plan_edit(…, workspace_name, …) -> (Commit, is_wc)`; `edit`'s early return; docs at v0.46.0.
- `crates/zanshin-jj/src/drop_actions.rs` — edit row `no_op: is_wc`; `ActionStatus::NoOp` doc names `edit`.
- `crates/zanshin-jj/src/repo.rs` — `Repo::edit` / `Repo::change_actions` docs.
- `schemas/envelope.fbs` + codegen (`zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`) — `ActionStatus` doc only.
- `crates/zanshin-ffi/src/repo.rs`, `packages/zanshin_core/lib/src/worker/handle.dart`, `packages/zanshin_core/lib/src/ffi/drop_actions.dart` — doc sentences on the no-op.
- `crates/zanshin-jj/tests/it/mutate.rs` — discardable-`@` and immutable-`@` witnesses; non-discardable test re-pointed to 9.38.
- `crates/zanshin-jj/tests/it/drop_actions.rs` — `@`'s card (edit = NoOp), `@` in the row/verb agreement sweep.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` — `edit_wc`, `edit_discardable_wc`, `edit_immutable_wc` (425 → 428 ids).
- `crates/zanshin-ffi/tests/it/repo_write_ffi.rs`, `packages/zanshin_core/test/worker/mutate_test.dart` — stale comments.
- Tracking (ledger commit): `sprint-status.yaml` (9-38 → done), `epics.md` Story 9.38 dated update, `deferred-work.md` markers.

**Review findings.** 13 findings: 8 patched (all low — docs/comments, two test-assertion tweaks, tracking text), 5 rejected (2 low: extra row fixtures add nothing over the shared `plan_edit` + verb/oracle witnesses; `(Commit, bool)` style. 3 false: the no-op op id is the post-snapshot head like every no-op verb; FFI/Dart shape unchanged; no typed status text by house rule). Nothing deferred.

**Follow-up review recommendation:** false — patched: high 0, medium 0, low 8.

**Intent items:**
- I1 — fixed (`5b71805`): the discardable current `@` no longer writes an operation; non-discardable now via the same early return.
- I2 — fixed (`5b71805`): Story 9.38's part is I1's fix; 9.39/9.40 were already done (bullet marked resolved).
- I3 — fixed (`5b71805`): the `edit` row for `@` is `NoOp`.
- I4 — fixed (this run's ledger commit, the one adding this section): sprint-status and epics.md now name the discardable case + early return at v0.46.0.

**Residual risks.** Coverage ratchet not measured here (story-loop gate rule); the new branch is covered by the new tests. Not checked: `next`/`prev --edit` (separate verbs with their own CLI paths).
