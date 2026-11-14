---
title: 'Story 10.36 closing run — the backend says whether a call wrote an operation'
type: 'bugfix'
created: '2026-11-14'
status: 'done'
baseline_revision: 'c9cb3fe2e17b33d02e87d933d4462a37bcac1b12'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (Story 10.36's deferral). `GraphViewModel._execute` reads `headOpId()` before the verb and sets `wrote = result.newOpId != head`. A verb that writes nothing returns the head it started from; when a foreign operation landed between the two reads, that head is the foreign op, so the runner counts the no-op as written: the toast reads as a success ("Absorbed X into 0 changes") and offers an Undo pinned to the foreign operation. The same holds for every verb that can write nothing, and for a no-op verb whose per-command snapshot wrote a snapshot op in the same call.

**Approach:** The backend says it. `zanshin_jj::MutationResult` gains `committed: bool` — `true` exactly when the call's own transaction committed an operation (the CLI's `tx.finish` path, not its "Nothing changed." path). It rides the wire (`MutationResult.committed` in `schemas/envelope.fbs`, codegen) into Dart's `MutationResult.committed`, and the runner uses it instead of comparing op ids.

## Boundaries & Constraints

**Always:**
- `committed` is the verb's own transaction: the pre-verb snapshot / Git import ops of the same call do not count (the CLI prints "Nothing changed." after them too).
- `new_op_id` keeps its meaning (the head after the call). Its doc's "deliberately no separate `no_op` flag" sentence is replaced by a pointer to `committed`.
- One term on every layer: `committed` (Rust field, schema field, Dart field). The view model's internal `wrote` stays.
- The runner still reads `headOpId()` before an undo / redo (the `expectHead` check); only the `wrote` comparison goes.
- Wire docs follow: the field's doc in the schema, `docs/ffi-abi.md`'s no-op paragraph, the Dart doc.

**Never:**
- No change to which calls write an operation, to op-log effects, or to the toast wording.
- No change to Story 10.36's spec or ledger bullet.
- No full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (loop gate rule).
- No jj outside temp dirs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Verb writes | `describe` with a new text | `committed: true`, `new_op_id` = the new op | — |
| Verb writes nothing | `describe` with the unchanged text | `committed: false`, `new_op_id` = pre-call head | — |
| Raw commit paths | `file_track` / `file_untrack` (locked working copy), `workspace_rename` | `committed: true` | — |
| Foreign op before a no-op verb (Dart) | runner read head `op0`; a foreign `F` lands; verb writes nothing and returns `newOpId: F, committed: false` | outcome not undoable, the previous own undo kept, toast reads "nothing changed" | — |
| Own write (Dart) | verb returns `committed: true` | outcome undoable, as today | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/mutate.rs:58-120` -- `pub struct MutationResult`; `new_op_id` doc (61-69) states "deliberately no separate `no_op` flag". Constructors: `mutation_result` (1018-1033, from `Finish`, which carries `committed` at 764; `finish_verb`'s no-change arm sets `false` at 993, `finish_transaction` `true` at 952), `no_op_result` (1551-1570, always a no-op except the two callers below), `commit_with_locked_wc` (1752-1790, raw commit → `true`).
- `crates/zanshin-jj/src/workspace_ops.rs:186-196` -- `rename` commits raw then builds its result with `no_op_result(new_name, &new_repo)` → set `committed = true` on it.
- `crates/zanshin-jj/src/snapshot.rs:914-924` -- precondition import: commits "export git refs" only when the export changed something, then `no_op_result` → `committed` = whether that commit ran.
- `crates/zanshin-jj/tests/it/mutate.rs:141` `describe_with_the_unchanged_text_writes_no_operation` -- add `assert!(!result.committed)`; a writing describe test nearby asserts `committed`.
- `crates/zanshin-jj/tests/it/api_stability.rs:182,1184,1350,1450,1524` -- struct literals; add the field.
- `crates/zanshin-ffi/src/envelope.rs:849-870` `build_mutation_result` -- write `committed`; tests 1710-1750 / 2008-2042 build literals and read back through accessors — add the field and assert it round-trips.
- `crates/zanshin-ffi/src/git.rs:745`, `snapshot.rs:222`, `repo.rs:1902` -- test struct literals.
- `schemas/envelope.fbs:2138-2152` `table MutationResult` -- append `committed: bool;` (append-only table). Then `cargo make codegen` (generated Rust, C header if any, Dart flatc output).
- `docs/ffi-abi.md:284-295` -- the no-op paragraph names `new_op_id` as the signal; add `committed`.
- `packages/zanshin_core/lib/src/ffi/mutate.dart:184-251` -- Dart `MutationResult` (add `required this.committed`) and `decodeMutationResultInternal` (`m?.committed ?? false`).
- `app/lib/src/features/graph/graph_view_model.dart:786-801` -- `wrote: result.newOpId != head` → `wrote: result.committed`; `_absorbMutation` (826-837) copies the field. `graph_ports.dart:993` split copy also copies it.
- Dart `MutationResult(` constructors to update: `app/test/features/graph/{graph_view_model_test,graph_toasts_test,graph_view_test,graph_card_menu_test,graph_drag_test,graph_inspector_test,graph_controls_test}.dart`, `app/test/app/menu/app_menu_test.dart`, `app/test/helpers/{fake_bookmark_list,fake_remote_sync}.dart`, `app/widgetbook/folders/graph.dart`. Fakes with a `noOp` flag pass `committed: !noOp`.
- `packages/zanshin_core/test/worker/mutate_test.dart` -- real-cdylib describe tests: assert `committed` for a write and a no-op.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/mutate.rs` -- add `committed: bool` with a doc (the call's own transaction committed an operation; snapshot/import ops before it do not count); set it in the three constructors; reword `new_op_id`'s doc. -- the backend knows, the Dart side cannot.
- `crates/zanshin-jj/src/workspace_ops.rs`, `crates/zanshin-jj/src/snapshot.rs` -- set `committed` where `no_op_result` follows a raw commit. -- honest flag on every path.
- `crates/zanshin-jj/tests/it/mutate.rs`, `api_stability.rs` -- assertions for write / no-op; literals. -- pins the contract.
- `schemas/envelope.fbs` + `cargo make codegen`; `crates/zanshin-ffi/src/envelope.rs` (+ test literals in `git.rs`, `snapshot.rs`, `repo.rs`) -- wire it; round-trip test asserts both values. -- FFI.
- `docs/ffi-abi.md` -- no-op paragraph. -- contract doc.
- `packages/zanshin_core/lib/src/ffi/mutate.dart`, `packages/zanshin_core/test/worker/mutate_test.dart` -- field, decode, real-cdylib assertion. -- bridge.
- `app/lib/src/features/graph/graph_view_model.dart`, `graph_ports.dart` -- use / copy `committed`. -- the fix.
- `app/test/...` fakes and `app/widgetbook/folders/graph.dart` -- pass `committed`; new view-model test for the foreign-op row of the matrix. -- witness.

**Acceptance Criteria:**
- Given a foreign operation lands between the runner's head read and a verb that writes nothing, when the verb returns, then the outcome is not undoable and the earlier own undo is unchanged.
- Given any mutation through the FFI, when it is decoded in Dart, then `MutationResult.committed` equals the Rust value.

## Spec Change Log

## Review Triage Log

### 2026-11-14 — Review pass
- verdicts: 17 findings — high 0, medium 0, low 11, false 6, maybe-false 0
- findings:
  - `[false]` `[reject]` (intent-alignment 1) The change reaches the Rust API, the schema and the bridge, wider than the cited view-model lines — the ledger follow-up asks for exactly this ("have the backend say whether the call wrote"); the Dart side cannot tell it from two separate calls.
  - `[false]` `[reject]` (intent-alignment 2) No toast test shows the foreign-op case — the toast text derives from `outcome.undoable` (`graph_toasts.dart:185`: "Nothing changed." when not undoable), which the new view-model test pins; the existing no-op toast tests cover the rendering.
  - `[false]` `[reject]` (intent-alignment 3) A no-op verb after a pre-verb snapshot op now reads as not written — intended and CLI-matching: jj prints "Nothing changed." after its own snapshot; stated in the spec's Boundaries.
  - `[false]` `[reject]` (intent-alignment 4) `## Auto Run Result` and the commit hash are missing — written at finalize.
  - `[low]` `[patch]` (verification-gap) `RepoGraphActions._split`'s copy of `committed` is untested — `graph_ports_test.dart` split test now asserts `outcome.undoable` and `model.undoable?.action is GraphSplit`.
  - `[low]` `[reject]` (edge-case 1) After a foreign op and a no-op verb the earlier own Undo stays offered, since `_checkHead` skipped the op-heads event while the run was busy — real but rare (a concurrent jj within one call); clicking it runs nothing wrong: `undoLast` checks `expectHead`, reports the foreign operation and drops the Undo; the same skipped-event window already exists after a refused verb; the fix adds a branch, and the matrix row keeps the own undo.
  - `[low]` `[reject]` (blind 1) Same as edge-case 1 — same reason.
  - `[low]` `[reject]` (blind 2) `no_op_result` now also builds results that wrote (rename, refs export) — `rename` already used it for a written result before this change; a `committed` parameter touches about 25 call sites for two patch-ups.
  - `[false]` `[reject]` (blind 3) Two sources of truth: `Finished::committed`, `project_import`'s `committed` against `mutation.committed`, contradicting in the snapshot export arm — `project_import`'s parameter only decides whether the import's ref changes are projected (the import changed nothing there, stats empty), and it is not stored in `GitImportResult`; the result holds one `committed`, the export operation's; no consumer diverges.
  - `[low]` `[patch]` (blind 4) `new_op_id`'s Rust doc still opens "Id of the operation this mutation committed" — reworded to "The op-log head after this call: the operation it committed, or the head it started from when it wrote nothing".
  - `[low]` `[reject]` (blind 5) Docs (`finish_or_no_op_at`, `bookmark_ops.rs`, `repo.rs`, `handle.dart`, `bindings.dart`) still call the pre-call head the no-op signal — the statements stay true (the id is the pre-call head); the wire docs now name `committed`; `bindings.dart` is generated, so the edit is a codegen round for wording only.
  - `[low]` `[patch]` (blind 6) `docs/ffi-abi.md` lists only `file_track` / `_untrack` as not ending in `tx.finish`, while the new paragraph adds `workspace_rename` — added there (verified: `rename` commits raw and never reaches `finish_transaction`).
  - `[low]` `[patch]` (blind 7) "A snapshot or Git import operation … does not count" is unclear where the import or export is the result's own operation — one sentence added in Rust, schema (+ codegen), Dart and ffi-abi: the flag describes the operation of the result it sits in, so a nested precondition `git_refs` result reports its own import or export operation.
  - `[false]` `[reject]` (blind 8) The import arm and the nested round-trips never assert `committed`; a nested encoder could bypass it — every `MutationResult` table is built by the one `build_mutation_result` (`MutationResultArgs` has no other caller); the import arm goes through `mutation_result`, pinned by the describe tests.
  - `[low]` `[reject]` (blind 9) The parity oracle does not check `committed` — the flag is `has_changes()`, the same gate whose op-log effect the oracle already compares; an oracle check is new harness work.
  - `[low]` `[patch]` (blind 10) The unchanged-describe Dart test never checks the first describe committed — `expect(first.committed, isTrue)` added. The raw-commit-through-FFI part is rejected: one encoder carries the field for every result.
  - `[low]` `[patch]` (blind 11) The fake's `foreign` reapplies on every later run — cleared once it lands.

## Design Notes

Why a flag, against Story 9.40's "deliberately no `no_op` flag": that note assumed the caller compares against a head it read in the same view; across the FFI the caller's head read is a separate call, so only the backend can say. Comparing against a head read inside the same call (the ledger's other option) needs the same wire field (a `base_op_id`) and is still wrong after a pre-verb snapshot op, where the CLI says "Nothing changed." while the op log moved.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test it mutate:: api_stability::` (one filter per run) -- expected: pass.
- `cargo test -p zanshin-jj --lib` -- expected: pass.
- `cargo test -p zanshin-ffi --lib envelope::` and `--test it` (affected modules) -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen`, then `git diff --stat` -- expected: generated files gain the field.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass (no verb behavior changed).
- `dart test test/worker/mutate_test.dart` in `packages/zanshin_core`; `flutter test test/features/graph` and `test/app/menu` in `app`; `dart analyze` / `dart format --set-exit-if-changed` in both -- expected: pass / clean.

**Results (2026-11-14, after the review patches):**
- `cargo fmt --all --check` clean; `cargo clippy -p zanshin-jj -p zanshin-ffi --all-targets -- -D warnings` clean (the build run also ran workspace-wide clippy, clean).
- `cargo test -p zanshin-jj --lib` 450 passed; `--test it` with `mutate::` 21, `api_stability::` 40, `workspace_ops::` 20, `file_track` 42, `snapshot_colocated::` 28 passed.
- `cargo test -p zanshin-ffi --lib` 240 passed; `--test it mutat` 9 passed.
- `cargo make codegen`: the generated Rust and Dart readers gained `committed`; a rerun changes nothing.
- `cargo test -p zanshin-parity --test oracle` 522 passed (build run; the review patches changed Rust doc comments only).
- `packages/zanshin_core`: `dart test test/worker/mutate_test.dart` (the `[tasks.test-core]` env) 31 passed; `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` clean.
- `app`: `flutter test test/features/graph test/app/menu` 976 passed; `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed` clean.
- No full gate (`cargo make test` / `test-full` / `coverage`), per the loop's gate rule; coverage of the changed Rust lines is not measured here.
- Matrix audit: verb writes (`mutate.rs` `describe_happy_path…`, `mutate_test.dart`), verb writes nothing (`describe_with_the_unchanged_text_writes_no_operation`, `describe_with_the_unchanged_text_commits_nothing`), raw commits (`track_untracked_file_writes_one_track_op…`, `rename_renames_view_store_and_working_copy`), foreign op before a no-op verb (`graph_view_model_test.dart` "a foreign operation before a verb that writes nothing…"), own write (existing undo tests) — all ran and passed.

## Auto Run Result

Status: done

**Items handed to this run:**
1. A foreign operation between the runner's head read and a verb that wrote nothing made the runner count the verb as written — **fixed** (cfe09d51bc749f0cbfa2447ca7319622a749df88). The backend now says it: `MutationResult.committed` (Rust, schema, Dart) is true exactly when the call's own transaction committed an operation, and `GraphViewModel._execute` uses it instead of comparing op ids. The runner reads the head only before an undo or redo now.

**Files changed:**
- `crates/zanshin-jj/src/mutate.rs` -- `committed` field and docs; set in `mutation_result`, `no_op_result`, `commit_with_locked_wc`.
- `crates/zanshin-jj/src/workspace_ops.rs`, `crates/zanshin-jj/src/snapshot.rs` -- `committed` on the two raw commits that reuse `no_op_result`.
- `schemas/envelope.fbs`, generated `crates/zanshin-ffi/src/envelope_generated.rs` and `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart` -- the wire field.
- `crates/zanshin-ffi/src/envelope.rs` -- writes the field; round-trip tests for both values.
- `packages/zanshin_core/lib/src/ffi/mutate.dart` -- Dart field and decode.
- `app/lib/src/features/graph/graph_view_model.dart`, `graph_ports.dart` -- use and copy the flag.
- `docs/ffi-abi.md` -- the flag and why a caller must not compare op ids.
- Tests: zanshin-jj `it` (`mutate`, `file_track_untrack`, `workspace_ops`, `snapshot_colocated`, `api_stability`), zanshin-ffi literals, `mutate_test.dart`, app fakes, a new view-model test for the foreign-op case, the split runner test; the widgetbook demo.

**Review:** 17 findings. Patched 6 (all low): split copy test, `new_op_id` doc, ffi-abi exception list, the flag's scope sentence, the first-describe assertion, the fake's `foreign` reset. Deferred: none. Rejected: 6 false (see the triage log) and 5 low — the earlier own Undo kept after a foreign op (rare; clicking it refuses with the foreign operation; same window exists after a refused verb), `no_op_result`'s name, the pre-call-head wording in other docs, a parity-oracle check of the flag, a raw-commit FFI test.

**Follow-up review recommended:** false — no high or medium entry was patched (patched: high 0, medium 0, low 6).

**Residual risks:** coverage of the changed Rust lines is checked only by the loop's final gate. After a foreign operation and a no-op verb, the earlier own Undo stays offered until the next op-heads event or a click, which then reports the foreign operation.
