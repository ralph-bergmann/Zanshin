---
title: 'Story 9.12: Operation edits — `op restore`, `op revert` (+ `op integrate`) — CLI parity at v0.46.0'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: '12c5b603ffa88aa0f5b263f12747b53375240b6a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      `op_show_diff::op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` is flaky (pre-existing): the reconciling merge does not always produce the predecessor cycle it pins.
    evidence: |-
      Measured 2026-10-24 by the implementation run: 3 of 40 isolated runs fail on the untouched baseline (git archive 12c5b60), 2 of 40 with Story 9.12 applied; the outcome depends on the unpinned timestamps of the two `diverge` describes. Not caused by 9.12; it passed in the two full `cargo test -p zanshin-jj` runs of this run's verification.
    location: >-
      crates/zanshin-jj/tests/it/op_show_diff.rs op_diff_of_a_rebasing_merge_operation_fails_like_the_cli
    severity: low
  - summary: >-
      `Repo::status` still refuses a workspace without `@` (`StatusError::NoWorkingCopy`) where the CLI prints "No working copy.", a state 9.12 made ordinary (root restore, undo to the root view, revert of `add workspace`).
    evidence: |-
      crates/zanshin-jj/src/status.rs:102 returns NoWorkingCopy; the CLI's cmd_status prints "No working copy." and succeeds (cli/src/commands/status.rs:195 @ v0.46.0). The Dart Status decoder turns an absent id into '' (packages/zanshin_core/lib/src/ffi/status.dart:109). Pre-existing: a workspace forgotten elsewhere reached it before 9.12.
    location: >-
      crates/zanshin-jj/src/status.rs:102
    severity: medium
  - summary: >-
      `undo` / `redo` / `op restore` / `op revert` reload the head with jj-lib's `load_at_head`, which reconciles divergent op heads without a workspace name; the CLI reconciles in this workspace.
    evidence: |-
      crates/zanshin-jj/src/op_log.rs:205, :389, :765, :810 call load_at_head after the pre-verb snapshot; snapshot::load_head (crates/zanshin-jj/src/snapshot.rs:313) is the CLI's way. Reached only when another process diverges the op heads between the snapshot and the reload. The pattern predates 9.12 (undo/redo, Story 9.21); 9.12's two verbs copied it.
    location: >-
      crates/zanshin-jj/src/op_log.rs:765
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin can undo/redo (9.39/9.21) but cannot restore the repo to an arbitrary operation ("Restore to here" in the Undo Timeline, 11.13), revert one specific operation (10.9's proper undo fix), nor integrate an operation the op log lacks (the remedy the `jj.stale_working_copy` `sibling_operation` hint names).

**Approach:** Port `cmd_op_restore`, `cmd_op_revert` (both with `--what`) and `cmd_op_integrate` from `../jj` @ v0.46.0 into `zanshin-jj`, generalise the shared `view_with_desired_portions_restored`, and wire all three end to end (`.fbs` → zanshin-jj → `extern "C"` + codegen → `zanshin_core`), with parity-oracle scenarios.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/operation/{restore,revert,integrate,mod}.rs`, `cli_util.rs`): precondition, refusal order and texts verbatim, op descriptions byte-identical (`restore to operation <hex>`, `revert operation <hex>`, `reconcile divergent operations`), every on-disk effect.
- `op restore` / `op revert` run the pre-verb snapshot (`with_verb`, the CLI's `workspace_helper`) and resolve the operation at the head repo (`op_walk::resolve_op_with_repo`, as `op_show`), errors through the existing `opset` mapping. `op revert`'s operation defaults to `@`; `op restore`'s is required.
- `--what` passes through as a list of `RestoreWhat { Repo, RemoteTracking }`; an empty list is the flag absent = the CLI's `DEFAULT_REVERT_WHAT` (both). One port of `view_with_desired_portions_restored` (repo portion: heads, local bookmarks/tags, wc commits; remote portion: `remote_views`; `git_refs`/`git_heads` always current) serves undo, redo, restore and revert; undo/redo keep their behavior (default `what`).
- `op revert`: parents `at_most_one` — none → "Cannot revert root operation", several → "Cannot revert a merge operation" (`jj.invalid_input`, before the transaction); then `tx.repo_mut().merge(repo_at_target, repo_at_parent)` and the restored portions of `tx.repo()` over the base view; the shared `finish_verb` (rebases the merge's recorded rewrites, 9.40 no-change gate).
- `op integrate`: NO snapshot and no Git import (the CLI's `workspace_helper_no_snapshot`): start-up fix-up + the CLI's head load (`snapshot::load_head`, may reconcile divergent heads) as `Repo::remote_changes` does, resolve at that head, then `update_op_heads(target.parent_ids(), target.id())` + `op_heads_store::resolve_op_heads` with the merge resolver (`RepoLoader::merge_operations`, this workspace's name, `reconcile divergent operations`, no args attribute). Result facts: the head op id afterwards and `reconciled` (the CLI's status line "The specified operation has been integrated with other existing operations." printed — a merge op was written).
- Restore and revert return `MutationResult` (as undo); a restored view equal to the current writes no operation and returns the pre-call head (9.40). Absence is `null`/`None`; fbs fields/members appended; never regenerate fixtures; every new extern gets a `packages/zanshin_core` real-cdylib test.

**Never:**
- No UI code, no MCP tool, no `--at-op` / `--ignore-working-copy` / `--no-integrate-operation` / templates; no "Restored to operation:" / "Reverted operation:" status text (the written op's description names the target).
- No new error code (the refusals are CLI `user_error`s → `jj.invalid_input`). Never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Restore earlier | 3 describes, `op restore @--` | view = that op's (git refs current); op `restore to operation <hex>` | — |
| Restore current / no change | `op restore @` | no op, pre-call head id | — |
| Restore root | `op restore 000000000000` | view = root's; op written | — |
| Restore `--what repo` / `remote-tracking` | a remote-tracking change after the target | only that portion restored, the other stays current | — |
| Restore/revert unknown op | `ffffffffffff` / bad prefix | nothing written beyond snapshot | `jj.operation_not_found` / `jj.invalid_input` |
| Revert default | `describe`, `op revert` | describe reverted; op `revert operation <hex of @>` | — |
| Revert earlier op with later work | describe A, new on A, `op revert @-` (the describe) | A's description back, the child rebased onto it | — |
| Revert already reverted | effect already gone | no op, pre-call head (9.40) | — |
| Revert root / merge op | `op revert 000000000000` / a reconcile merge op | nothing written by the verb | `jj.invalid_input` "Cannot revert root operation" / "Cannot revert a merge operation" |
| Integrate in-log op | `op integrate @-` | no effect: head unchanged, `reconciled = false` | — |
| Integrate unpublished op | op written by jj-lib and left unpublished, child of the head | it becomes the head, `reconciled = false` | — |
| Integrate sibling | unpublished op on an older op | merge op `reconcile divergent operations` in this workspace becomes head, `reconciled = true` | — |
| Integrate unknown | `ffffffffffff` | nothing written | `jj.operation_not_found` |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0`: RS = `cli/src/commands/operation/restore.rs` (`cmd_op_restore` :48-70), RV = `operation/revert.rs` (args `default_value = "@"` :38; `at_most_one` refusals :61-65; merge + restore :67-79; `tx_description` :49-51), IN = `operation/integrate.rs` (:36-66), M = `operation/mod.rs` (`RevertWhatToRestore` :76-84, `DEFAULT_REVERT_WHAT` :87-90, `view_with_desired_portions_restored` :93-117), CU = `cli/src/cli_util.rs` (`workspace_helper_no_snapshot` :522-529, `load_from_workspace` :531+, `merge_operations` :853-878, `resolve_single_op` :1824). jj-lib (vendored `~/.cargo/registry/src/*/jj-lib-0.46.0/src`): `MutableRepo::merge` repo.rs:2041 (index merge, `normalize_heads`, `merge_view` → `record_rewrites`), `set_view` :2036, `op_heads_store::resolve_op_heads` (filters ancestor heads, then the resolver), `RepoLoader::merge_operations` repo.rs:869.

**Reuse — `crates/zanshin-jj`.**
- `src/op_log.rs` — `undo` :197, `redo` :343 (templates: readonly head, `start_repo_transaction`, `finish_verb`, `mutation_result`); `restored_view` :301 → generalise to the M:93-117 port taking `&[RestoreWhat]`; `op_show` :450 (`resolve_op_with_repo` on the head), `merged_repo` :551, `opset` :700 (opset error mapping, reuse as is), `op_abandon` :595 (op-heads-store handling template for integrate). Add `RestoreWhat`, `op_restore`, `op_revert`, `op_integrate`, `OpIntegrateResult {head_op_id: OperationId, reconciled: bool}` here with fn docs citing the CLI lines.
- `src/mutate.rs` — `MutateError` :127 (`invalid` :526 for the two revert refusals; no new variant), `finish_verb` :911 (no-change gate :917-930, immutable resolve + `rebase_descendants_with_options` :933-938), `mutation_result` :959. `REDO_CROSS_WORKSPACE_HINT` :520 already names `jj op revert`.
- `src/repo.rs` — `with_verb` :479; `undo` :1400 / `redo` :1425 / `op_abandon` :1511 (doc-block style); `remote_changes` :1714 (no-snapshot + CLI head-load pattern for `op_integrate`); `src/snapshot.rs:313` `load_head`.
- `src/lib.rs` :110-112 — re-export `RestoreWhat`, `OpIntegrateResult`.

**Extend — wire + FFI.** `schemas/envelope.fbs`: `RequestKind` :94-148 (append `OpRestore`, `OpRevert` after `OpDiff`), new `enum RestoreWhat : ubyte { Unspecified, Repo, RemoteTracking }` (Unspecified-first, template `BookmarkSortKey` :841 + `BookmarkListRequest.sort` :878), request tables `OpRestoreRequest {kind, operation: string, what: [RestoreWhat]}` / `OpRevertRequest {kind, operation: string (absent = "@"), what: [RestoreWhat]}` beside `OpShowRequest` :1245, payload table `OpIntegrateResult {head_op_id: string, reconciled: bool}` appended to `union Payload` :2483-2537; `cargo make codegen` (commit generated files). `crates/zanshin-ffi/src/op_log.rs` — readers like `read_op_show_request` :351 (`expect_request_kind` envelope.rs:653; absent restore `operation` or an `Unspecified` `what` member → `ffi.invalid_argument`, as the sort-key reader treats Unspecified), externs `zanshin_op_restore(handle, data, len)`, `zanshin_op_revert(handle, data, len)` (→ `ok_mutation_result` envelope.rs:796 via `precondition_envelope` :587, template `zanshin_redo` repo.rs:1412), `zanshin_op_integrate(handle, *const c_char)` (template `zanshin_op_abandon` :507, serializer like `op_abandon_to_envelope` :320); `map_mutate_err` repo.rs:169 unchanged. `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS` 89 → 92. `docs/ffi-abi.md` (export count :545 + prose :41/:185/:203/:288, Payload 52 → 53 :253, request tables 50 → 52 :448, index rows near :573/:613-614, a "Story 9.12" section after :1891's), `docs/rust-error-codes.md` (`jj.invalid_input` :66 — revert's two refusals + the three verbs' opset failures; `jj.operation_not_found` :88 widened).

**Extend — Dart (`packages/zanshin_core`).** `lib/src/ffi/op_log.dart` (`RestoreWhat` enum, `OpIntegrateResult` model + decoder, adapters `zanshinOpRestore` / `zanshinOpRevert` built like `zanshinOpShow` :31 with `rejectInteriorNul`, `zanshinOpIntegrate` like `zanshinOpAbandon` :62; restore/revert decode with the existing MutationResult decoder used by `zanshinRedo` in `lib/src/ffi/mutate.dart:119`), `lib/src/worker/commands.dart` (beside `OpAbandonCommand` :622), `isolate.dart` (client :1263, dispatch :3360), `handle.dart` (`RepoHandle.opRestore(String operation, {List<RestoreWhat> what = const []})`, `opRevert({String operation = '@', List<RestoreWhat> what = const []})`, `opIntegrate(String operation)` after `opAbandon` :593), barrel `lib/zanshin_core.dart`.

**Tests.** `crates/zanshin-jj/tests/it/` — new modules `op_restore_revert.rs`, `op_integrate.rs` declared in `main.rs` (templates `redo.rs`, `op_abandon.rs`; an unpublished op via jj-lib in-test: `start_transaction` → change → `write(..)` → leave unpublished); `api_stability.rs` (a `story_9_12_*` fn like `story_9_21_*` :1595 pinning signatures by fn-pointer cast and the new types). FFI `tests/it/op_log_ffi.rs` (readers: kind mismatch, malformed buffer, absent/present strings, Unspecified `what`, zero handle, refusal envelopes, payloads). Dart `test/ffi/op_log_test.dart` (synthetic `OpIntegrateResult` decode, interior-NUL guards of the three adapters), `test/worker/op_verbs_test.dart` (real-cdylib round trips: restore, revert incl. root refusal, integrate no-effect). Oracle `crates/zanshin-parity/tests/oracle/scenarios.rs` (9.21 block :1119+ as template; `Step::Jj` passes global flags such as `--at-op` verbatim — `op_abandon_merge_refused` makes a merge op that way; setup cannot capture op ids, use relative expressions / `ROOT_OPERATION_PREFIX` :127), `main.rs` (`parity!` list + `every_scenario_has_a_test` 303 :373), `ledger.rs` (entries only with reason + reference).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_log.rs` -- add `RestoreWhat`, the generalised view-restore port (undo/redo call it with the default), `op_restore`, `op_revert`, `op_integrate` + `OpIntegrateResult`, each step per the Code Map with CLI-line docs; inline unit test of the view-restore portions (each `what` combination, empty = default, `git_refs`/`git_heads` always current).
- `crates/zanshin-jj/src/{repo,lib}.rs` -- `Repo::op_restore(&str, &[RestoreWhat])`, `op_revert(&str, &[RestoreWhat])` (with `with_verb`), `op_integrate(&str)` (no snapshot, CLI head load) with house doc blocks (`# Errors`); re-exports.
- `schemas/envelope.fbs` + `cargo make codegen` -- enum, two request tables, `RequestKind` + `Payload` appends; commit generated files.
- `crates/zanshin-ffi/src/{op_log,envelope,lib}.rs` -- three externs, readers, serializer, full rustdoc (`# Errors` = registry codes, `# Safety`); `EXPECTED_EXPORTS` → 92.
- `packages/zanshin_core` -- enum, model, decoder, adapters, worker commands, `RepoHandle` methods, barrel; the tests in the Code Map.
- `crates/zanshin-jj/tests/it/{op_restore_revert,op_integrate,main,api_stability}.rs` -- every I/O-matrix row, CLI ↔ Zanshin interleaving (restore/revert after a CLI-written op), op heads unchanged on every refusal.
- `crates/zanshin-ffi/tests/it/op_log_ffi.rs` -- as in the Code Map.
- `crates/zanshin-parity/tests/oracle/{scenarios,main,ledger}.rs` -- `op_restore_earlier`, `op_restore_current`, `op_restore_root`, `op_restore_what_repo`, `op_restore_what_remote_tracking` (a remote-tracking difference built in setup if an existing push/fetch scenario shows how — else ledger-free on a plain repo, noted in Verification), `op_restore_not_found`, `op_revert_default`, `op_revert_rebases_descendants`, `op_revert_twice` (no change), `op_revert_root_refused`, `op_revert_merge_refused`, `op_integrate_in_log`.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- as in the Code Map.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-12-operation-edits-op-restore-op-revert` to `done` with a sibling-style summary (hand-edit, bump `last_updated`); mirror every `deferred:` item under `## Surfaced in Story 9.12 (bmad-build-auto, 2026-10-24)`.

**Acceptance Criteria:**
- Given the three verbs, when a Dart caller reaches them, then the whole chain exists (`.fbs`, zanshin-jj verb, `extern "C"`, committed codegen, adapter, worker command, `RepoHandle` method) and `ffi_abi_doc_sync` passes with 92 exports.
- Given the oracle scenarios above, when the oracle runs, then each matches the pinned CLI on every aspect or diverges only through a ledgered entry with reason and reference.
- Given `undo`/`redo` after the view-restore refactor, when their existing tests and oracle scenarios run, then they pass unchanged.
- Given any refusal, when the op heads are compared before and after the verb (after the snapshot), then they are unchanged.
- Given the end of the run, then the targeted checks in Verification pass, `git status --porcelain` is clean and every commit ends with the required co-author trailer.

## Spec Change Log

- 2026-10-24 (implementation) — **`MutationResult.working_copy_change_id` became `Option<ChangeId>`** (ABSENT on the wire). The matrix row "Restore root … op written" cannot hold otherwise: the root operation's view has no working-copy commit, and `mutate::mutation_result` returned `jj.jj_lib_error` AFTER committing the operation (undo to the root view had the same latent bug). `mutation_result` is now infallible; every caller and test updated. Dart `MutationResult.workingCopyChangeId` became `String?` (absent = `null`); `no_op_result` reports `None` too, so a no-change verb after a root restore says "Nothing changed." instead of failing.
- 2026-10-24 (implementation) — **New warning `jj.workspace_no_longer_exists`** (`WarningKind::WorkspaceNoLongerExists`): the CLI's `report_repo_changes` line "The current workspace '<name>' no longer exists after this operation. The working copy was left untouched." (`cli/src/cli_util.rs:2489-2503` @ v0.46.0), raised by the shared `finish_transaction`. The oracle's `op_restore_root` showed it (CLI 1 warning, Zanshin 0). A warning code, not an error code — the "no new error code" rule stands.
- 2026-10-24 (implementation) — **Matrix row "Revert already reverted → no op" holds only when the merge records no rewrite.** Reverting a `describe` twice writes a second `revert operation <hex>` in the pinned CLI too (`MutableRepo::merge` → `record_rewrites` maps the described commit onto the original again, so `has_changes()` is true) — oracle `op_revert_twice` passes with that behaviour. The no-change gate is tested with a bookmark create → delete → revert of the create (`op_revert_of_an_operation_whose_effect_is_gone_writes_nothing`).

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 28 findings — high 0, medium 7, low 12, false 8, maybe-false 1
- findings:
  - `[medium]` `[patch]` (blind) `Repo::op_integrate` runs only the secure-config fix-up, not the CLI's `workspace_helper_no_snapshot` start-up (`workspace_environment` + `load_from_workspace`, cli_util.rs:522-562): deprecation / alias / `trunk()`-fallback warnings and the `jj.config_error` refusals are missing — now runs `start_call` without the snapshot (no precondition report), docs reworded, a broken `immutable_heads()` refusal test added.
  - `[medium]` `[patch]` (blind) `no_op_result` still errors `jj.jj_lib_error` without `@`, reachable after `op restore` of the root — now returns `working_copy_change_id: None`; witnessed by the extended root-restore test.
  - `[medium]` `[patch]` (blind) Dart `MutationResult.workingCopyChangeId` reads an absent id as `''`, against the spec's "Absence is null" — now `String?` (null), fallout fixed, the deferral withdrawn.
  - `[low]` `[patch]` (blind) undo / redo / op revert docs do not say the result can lack `@` and warn `jj.workspace_no_longer_exists` — one sentence each in Rust, FFI (regenerated header) and Dart docs.
  - `[low]` `[patch]` (blind) no revert test with a single `what` portion, none reverting an op whose inverse drops `@` — `op_revert_what_reverts_only_the_chosen_portion` and a drop-`@` revert test added.
  - `[low]` `[patch]` (blind) the state after losing the workspace is unwitnessed (files untouched, next no-change verb, undo back) — the root-restore test asserts all three.
  - `[low]` `[reject]` (blind) the oracle compares only `op integrate`'s no-effect case — the harness cannot capture an op id from setup (static `&[Step]`, no `State` accessor), so an unpublished-op scenario needs a harness extension; the two real paths are integration-tested (`tests/it/op_integrate.rs`, description + workspace name asserted).
  - `[low]` `[patch]` (blind) `OpIntegrateResult` drops merge_operations' rebase count and says "a reconcile op was written" although a head-load reconcile leaves `reconciled = false` — the doc now says `reconciled` is the integrate's own merge (the CLI's status line); the rebase count (a new field, a rare divergent-rewrite case) rejected as low.
  - `[maybe-false]` `[reject]` (blind) the new merge-op refusal test uses `op_show_diff::diverge`, the helper behind the pre-existing flaky test — would need repeated runs of `op_revert_of_the_root_or_a_merge_operation_refuses` to show it flakes; the refusal needs only two parents, not an id order, and it passed in every run here; if true only low.
  - `[low]` `[patch]` (blind) no test sends an out-of-range `RestoreWhat` byte, and no Dart test restores to the root — an FFI unknown-member refusal and a Dart `opRestore('000000000000')` test (warning + null `workingCopyChangeId`) added.
  - `[low]` `[patch]` (blind) the CLI's recovery hint after `jj.workspace_no_longer_exists` is dropped without saying so — registry row and ffi-abi.md now say so and name undo / redo / restore as the recovery.
  - `[medium]` `[patch]` (edge-case) `no_op_result` without `@` — same root as the blind row; fixed with it.
  - `[medium]` `[patch]` (edge-case) `op_integrate` skips the start-up environment — same root as the blind row; fixed with it.
  - `[low]` `[patch]` (edge-case) `reconciled` false when the head load reconciled — same root as the blind `OpIntegrateResult` row; doc fixed with it.
  - `[false]` `[reject]` (edge-case) zero handle + malformed request yields `ffi.invalid_argument` instead of `ffi.invalid_handle` — the house order of every request-table extern (`zanshin_op_show`, `zanshin_op_diff`, `zanshin_select_tree` read the request before `session_from_handle`); the new externs follow it.
  - `[false]` `[reject]` (edge-case, claim) `op_revert_twice` writes a second op although the matrix says "no op" — the pinned CLI writes it too (oracle `op_revert_twice` matches); the matrix row holds where the effect is really gone (bookmark create → delete → revert), logged in the Spec Change Log.
  - `[false]` `[reject]` (edge-case, claim) the undo-to-root test was rewritten behind an "unchanged tests" AC — not hidden: the Spec Change Log records it; the old test pinned a bug (op committed, then `jj.jj_lib_error`) the CLI does not have.
  - `[false]` `[reject]` (edge-case, claim) a refused `op integrate` can rewrite op heads when they were divergent — the CLI's `load_from_workspace` reconciles at load before `resolve_single_op` refuses; the project rule allows a write the CLI's flow makes before refusing.
  - `[medium]` `[patch]` (edge-case, claim) config-driven refusals / warnings of `jj op integrate` missing — same root as the blind start-up row; fixed with it.
  - `[low]` `[patch]` (verification-gap) `op revert --what` never exercised with one portion — same gap as the blind revert-test row; test added there.
  - `[low]` `[patch]` (verification-gap) the FFI `RemoteTracking` mapping and `zanshin_op_revert`'s ABSENT = `@` default are unobserved — the revert round trip asserts the head description `revert operation <hex>`, a `[RemoteTracking]` restore case and an unknown-member refusal added.
  - `[false]` `[reject]` (intent a) scope beyond the title (`op integrate`, the `Option`, the warning) — the Design Notes justify `op integrate` (9.21 assigned it here); the `Option` and the warning are what CLI parity of the root restore requires (Spec Change Log).
  - `[low]` `[patch]` (intent b) FFI / Dart round trips miss `--what remote-tracking` — same gap as the verification-gap FFI row; covered there. The merge refusal and the rebase stay Rust + oracle (the seam only marshals).
  - `[low]` `[reject]` (intent c) the oracle covers `op integrate`'s no-op only — same as the blind oracle row.
  - `[medium]` `[patch]` (intent d) Rust ABSENT vs Dart `''` — same root as the blind Dart row; fixed with it.
  - `[false]` `[reject]` (intent e) global flags and status lines not passed through — the intent-contract's Never excludes them (no Zanshin counterpart; terminal UX).
  - `[false]` `[reject]` (intent f) the "revert already reverted" row bent to the CLI — same as the edge-case `op_revert_twice` row.
  - `[false]` `[reject]` (intent g) the review diff omits the spec and generated code; gate wording — generated code and the claims file are excluded from the reviewers' diff by design; the spec is committed at finalisation; every check is recorded under Verification.

### 2026-10-24 — Review pass (follow-up)
- verdicts: 25 findings — high 0, medium 1, low 17, false 7, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) an absent `OpRestoreRequest.operation` was `ffi.invalid_argument` through a private helper, against the refusal ladder's row 4 (`missing_field` → `jj.invalid_input` "<field> is required", ffi-abi.md § refusal ladder) — the Code Map's wording conflicted with the documented ladder; now `missing_field("operation")`, rustdoc, `.fbs` doc (regenerated), ffi-abi.md, rust-error-codes.md and the FFI refusal test updated.
  - `[low]` `[reject]` (blind) `op integrate` drops `merge_operations`' rebase count — carried: the rebase count (a new field, a rare divergent-rewrite case) rejected as low in the first pass.
  - `[low]` `[patch]` (blind) the documented rule "a head-load reconcile leaves `reconciled = false`" was never tested — `op_integrate_after_a_head_load_reconcile_reports_no_reconcile_of_its_own` (two published sibling ops, `op_integrate("@")`: `reconciled` false, the merge in `default`) added.
  - `[low]` `[patch]` (blind) the oracle misses risky paths — integrate parts carried (harness cannot capture op ids from setup); `op revert --what` had no scenario: `op_revert_what_remote_tracking` added (DESCRIBE_THEN_PUSH, matches the CLI); undo-to-root / revert-of-`add workspace` scenarios rejected — the harness's base setup leaves no op log reaching the root by `undo`, and the shared finish path with its warning is compared by `op_restore_root`.
  - `[medium]` `[defer]` (blind) `Repo::status` still refuses a workspace without `@` where the CLI prints "No working copy." — pre-existing (`status.rs:102`; a forgotten workspace reached it before), now ordinary; deferred with the end-to-end optional-`@` fix as follow-up.
  - `[low]` `[patch]` (blind) `import_git_refs` still skipped the `git_refs` report without `@` (guards that existed only because `no_op_result` / `mutation_result` failed without `@`), against the wire doc "PRESENT exactly when the step ran" — guards removed, Rust docs reworded; `a_workspace_without_at_still_imports_the_refs` now asserts the report (no `@`, `other` imported).
  - `[low]` `[reject]` (blind) `working_copy_change_id` became `Option` for verbs that always set `@` without a per-verb promise — the wire contract states when it is absent; a sentence on each always-`@` verb adds no safety (test `expect("@")`s fail loudly if it ever changes).
  - `[low]` `[patch]` (blind) the `RestoreWhat::RemoteTracking` doc paraphrased the CLI wrongly, Dart left the advice out — both now quote "Do not restore these if you'd like to push after the undo".
  - `[low]` `[patch]` (blind) rust-error-codes.md's `jj.operation_not_found` "Emitted" column lacked the 9.12 sources — sentence added (and the absent-`operation` source on the `jj.invalid_input` row).
  - `[low]` `[reject]` (blind) revert's default `@` lives in the FFI reader and the Dart API — both are the intent's "defaults to `@`" (the CLI's `default_value`) at two documented surfaces; the absent-means-`@` path is tested from Rust.
  - `[low]` `[patch]` (blind) the FFI remote-tracking test discarded `eval_revset`'s `Result` — now `.expect("the revset evaluates")`.
  - `[low]` `[patch]` (blind) `--what` tests leave fields unchecked — refuted for Rust (the inline `view_restore_takes_each_portion_per_what` checks `local_tags` and `wc_commit_ids` per portion); the Dart half (only `[repo]` sent) is the verification-gap row below, fixed with it.
  - `[low]` `[defer]` (edge-case) `op_restore` / `op_revert` reload the head with jj-lib's `load_at_head` (reconcile without workspace name) instead of the CLI's — same pattern in undo/redo since 9.21, reached only through a concurrent op-head divergence between snapshot and reload; deferred for all four verbs.
  - `[false]` `[reject]` (edge-case, claim) undo's tests "pass unchanged" hides the undo-to-root change — carried: the Spec Change Log records it; the old test pinned a bug.
  - `[false]` `[reject]` (edge-case, claim) `op_revert_twice` "no change" — carried: the pinned CLI writes the second op too (Spec Change Log).
  - `[low]` `[patch]` (verification-gap) the Dart bridge's `what` forwarding was never observed — worker round trip `the chosen --what portion reaches restore and revert` added: `[remoteTracking]` restore writes nothing and keeps `B`; after a bookmark create, `[remoteTracking]` revert is "Nothing changed." and `[repo]` removes the bookmark (both behaviours checked against the pinned CLI binary in a scratch repo; a describe cannot tell revert's portions apart — the merge's recorded rewrite brings `A` back in the CLI too).
  - `[low]` `[patch]` (verification-gap) the old-`@` half of the `jj.workspace_no_longer_exists` condition was unwitnessed — the root-restore test now writes a bookmark with `@` absent before and after and asserts no such warning (mutation-checked: dropping the old-side test fails it).
  - `[false]` `[reject]` (intent 1) undo/redo's observable outcome changed — carried (as the edge-case claim row): CLI parity of the root restore, Spec Change Log.
  - `[false]` `[reject]` (intent 2) the shared `MutationResult` contract widened — carried (first-pass intent a).
  - `[false]` `[reject]` (intent 3) a new warning code — carried (first-pass intent a): a warning, not an error code.
  - `[false]` `[reject]` (intent 4) "revert already reverted" — carried (first-pass intent f).
  - `[low]` `[reject]` (intent 5) integrate's unpublished/sibling rows only at the Rust surface — carried (first-pass blind oracle row / intent c).
  - `[low]` `[patch]` (intent 6) revert `--what` has no oracle scenario — same as the blind oracle row; `op_revert_what_remote_tracking` added. The merge refusal / rebase staying at Rust + oracle is carried (first-pass intent b).
  - `[false]` `[reject]` (intent 7) real-cdylib tests are smoke-level — the intent asks every new extern to get one; the matrix rows live at zanshin-jj and the oracle, the seam only marshals.
  - `[low]` `[patch]` (intent 8) wire-only surfaces: an absent restore `operation` refused as `ffi.invalid_argument` — same as the blind first row; now `jj.invalid_input`. `Unspecified` → `ffi.invalid_argument` matches the sort-key reader.

## Design Notes

- **Why `op integrate` is in.** 9.21's spec assigned it here ("No `op restore` / `op revert` / `op integrate` (9.12)"), it is the third `operation/` edit verb, and Zanshin's `sibling_operation` stale hint names it — Ralph prefers scoping a story with its obvious siblings over follow-up chains.
- **`what` as a list.** Mirrors clap (`Vec<RevertWhatToRestore>`, repeatable, `contains` semantics); the CLI cannot express "nothing", so empty = absent = default needs no refusal.
- **Revert = 3-way merge.** `merge(base = target, other = target's parent)` applies the inverse of the target onto the current repo; `merge_view` records rewrites, so the finish rebases descendants — then the portion restore takes the merged repo state but keeps `git_refs`/`git_heads` (and, per `what`, the remote views) from the base, exactly as RV:73-77.

## Verification

**Commands (the story loop's gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj` -- all pass
- `cargo test -p zanshin-ffi` -- all pass
- `cargo test -p zanshin-parity --test oracle` -- all pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed, rerun leaves no diff
- `packages/zanshin_core`: `cargo make --allow-private test-core` (pinned env; bare `dart test` fails its env guard), `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed .` -- clean; `app/`: `dart analyze --fatal-infos` -- clean

**Notes (2026-10-24):** the two `--what` oracle scenarios build their remote-tracking difference in setup the way `git_scenarios.rs`' `PUSHED` does (a bare `../remote.git`, `git remote add`, a describe, then `git push -b b-mark`), so `@--` precedes both a repo change and a remote-tracking change. `op_show_diff::op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` is a pre-existing flaky test (3/40 isolated failures on the baseline) — it may fail a full `cargo test -p zanshin-jj` run; see deferred-work.md.

**Checks run (2026-10-24, build-auto run; full gate deliberately not run — story-loop gate rule):**
- `cargo fmt --all --check` — clean (after implementation and again after the review patches).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean (both rounds).
- `cargo test -p zanshin-jj` — 349 unit + 1210 integration passed, 1 ignored (pre-existing); after the patches 349 + 1213 passed, 1 ignored. (The implementation run saw the pre-existing flaky `op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` fail once; it passed in both verification runs here.)
- `cargo test -p zanshin-ffi` — 213 unit + 346 integration passed (incl. `ffi_abi_doc_sync` at 92 exports); after the patches 213 + 347.
- `cargo test -p zanshin-parity --test oracle` — 329 passed both rounds (12 new scenarios, `every_scenario_has_a_test` at 315; no ledger entry).
- `cargo make codegen` — rerun leaves no diff (both rounds).
- `packages/zanshin_core`: `cargo make --allow-private test-core` (pinned env) — 1029, then 1030 tests passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed .` — 0 changed. `app/`: `dart analyze --fatal-infos` — no issues.
- Coverage not measured (gate rule); every new line got a test.

**Checks run (2026-10-24, follow-up review pass; full gate deliberately not run — story-loop gate rule):**
- `cargo fmt --all --check` — clean (after `cargo fmt --all`).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean.
- `cargo test -p zanshin-jj` — 349 unit + 1214 integration passed, 1 ignored (pre-existing).
- `cargo test -p zanshin-ffi` — 213 unit + 347 integration passed.
- `cargo test -p zanshin-parity --test oracle` — 330 passed (new `op_revert_what_remote_tracking`; `every_scenario_has_a_test` at 316; no ledger entry).
- `cargo make codegen` — regenerated (the `OpRestoreRequest` doc and the `zanshin_op_restore` rustdoc changed); a rerun leaves no diff.
- `packages/zanshin_core`: `cargo make --allow-private test-core` — 1031 passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed .` — 0 changed. `app/`: `dart analyze --fatal-infos` — no issues.
- Mutation check: reducing `mutate.rs:887` to `maybe_new_wc_commit.is_none()` fails `op_restore_to_the_root_operation_writes_its_view` (restored afterwards, no diff).
- CLI check (pinned `target/debug/jj` in a scratch repo under the session scratchpad): `op revert --what remote-tracking` of a describe brings the old description back (recorded rewrite); of a bookmark create it is "Nothing changed."; `--what repo` removes the bookmark — the Dart test pins exactly that.

## Auto Run Result

Status: done

**Summary.** Ported `jj op restore`, `jj op revert` (both with `--what`) and `jj op integrate` @ v0.46.0 into `zanshin-jj` and wired them end to end (`.fbs` → zanshin-jj → three externs + codegen → `RepoHandle.opRestore` / `opRevert` / `opIntegrate`). One port of `view_with_desired_portions_restored` now serves undo, redo, restore and revert. Restoring a view without this workspace's `@` (the root op, reverting `add workspace`) is now a success: `MutationResult.working_copy_change_id` is `Option` / absent on the wire / `String?` in Dart, and the CLI's `report_repo_changes` warning is the new `jj.workspace_no_longer_exists`. `op integrate` runs the CLI's no-snapshot start-up and returns `OpIntegrateResult {head_op_id, reconciled}`.

**Files changed.**
- `crates/zanshin-jj/src/op_log.rs` — `RestoreWhat`, the view-restore port, `op_restore`, `op_revert`, `op_integrate`, `OpIntegrateResult`; inline portion unit test.
- `crates/zanshin-jj/src/{repo,lib,warning,mutate}.rs` — three `Repo` methods; re-exports; `WorkspaceNoLongerExists`; `working_copy_change_id: Option`, infallible `mutation_result`, `no_op_result` without `@`, the finish warning.
- `crates/zanshin-jj/src/{arrange,commit,duplicate,fix,metaedit,parallelize,rebase,remotes,snapshot,squash_split,workspace_add}.rs` — `mutation_result` call sites.
- `schemas/envelope.fbs` + generated Rust/Dart/C — `RestoreWhat`, `OpRestoreRequest`, `OpRevertRequest`, `OpIntegrateResult`, `RequestKind` / `Payload` appends.
- `crates/zanshin-ffi/src/{op_log,envelope,repo,git,snapshot}.rs` — `zanshin_op_restore`, `zanshin_op_revert`, `zanshin_op_integrate` (92 exports), readers, serializer, warning code, optional `@`.
- `packages/zanshin_core` — `RestoreWhat`, `OpIntegrateResult`, adapters, worker commands, `RepoHandle` methods, warning constant, `MutationResult.workingCopyChangeId` nullable.
- Tests: `crates/zanshin-jj/tests/it/{op_restore_revert,op_integrate}.rs` (new), `api_stability.rs`, `op_log.rs` and the `Option` fallout; `crates/zanshin-ffi/tests/it/op_log_ffi.rs`; Dart `test/ffi/op_log_test.dart`, `test/worker/op_verbs_test.dart` (+ fallout); oracle 12 scenarios (`scenarios.rs`, `main.rs`).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`; `sprint-status.yaml` (done), `deferred-work.md`.

**Review.** 28 findings (4 layers): 7 medium, 12 low, 8 false, 1 maybe-false. Patched 10 entries — 3 medium (`op integrate` skipped the CLI's no-snapshot start-up environment; `no_op_result` still failed without `@`; Dart coerced the absent `@` to `''` against the spec's null rule) and 7 low (undo/redo/revert docs, revert `--what` and drop-`@` tests, the post-restore recovery test, the `reconciled` doc, an unknown `RestoreWhat` byte + Dart root restore, the dropped hint documented, FFI `RemoteTracking` / ABSENT-operation witnesses). Rejected: 8 false (house request-before-handle order, `op_revert_twice` matches the CLI, the rewritten undo-to-root test pinned a bug and is logged, a refused integrate's head-load reconcile is the CLI's flow, scope/flags/diff-shape intent rows), 3 low (oracle cannot capture op ids for an unpublished-op integrate scenario ×2, the rebase count of a reconcile), 1 maybe-false (the merge-op refusal test reusing the flaky helper's `diverge`). Nothing newly deferred by the review; the implementation run's one deferral (pre-existing flaky test) is mirrored in deferred-work.md.

**Follow-up review recommended: true** (first pass, 3 medium entries patched). The unverified risk: `Repo::op_integrate` now runs `start_call` without the snapshot — its warnings/refusal parity with the CLI's `workspace_helper_no_snapshot` (deprecations, `trunk()` fallback) is witnessed by one broken-alias test only and never by the oracle; and the `Option` `@` change reaches every mutating verb's result shape.

**Verification.** See `## Verification` → "Checks run": fmt, clippy, zanshin-jj / zanshin-ffi / oracle tests, codegen idempotence, the zanshin_core suite, analyze and format — all green. Full gate and coverage not run (story-loop gate rule).

### Follow-up review pass (2026-10-24)

**Summary.** A fresh four-layer review of the shipped 9.12 diff. Patched: the absent restore `operation` now follows the refusal ladder (`jj.invalid_input` "operation is required"); `import_git_refs` reports the refs import without `@` too (obsolete guards removed); the `RestoreWhat::RemoteTracking` docs quote the CLI; rust-error-codes.md completed; and tests for the head-load reconcile of `op integrate`, the no-`@`-before-and-after warning condition, the Dart `what` forwarding, plus the oracle scenario `op_revert_what_remote_tracking`.

**Files changed.**
- `crates/zanshin-ffi/src/op_log.rs` — absent `operation` → `missing_field` (`jj.invalid_input`); docs.
- `crates/zanshin-jj/src/snapshot.rs` — `git_refs` report without the `@` guards; docs.
- `crates/zanshin-jj/src/op_log.rs`, `packages/zanshin_core/lib/src/ffi/op_log.dart` — `RemoteTracking` doc quotes the CLI.
- `schemas/envelope.fbs` + regenerated Rust/Dart/C — `OpRestoreRequest.operation` doc.
- Tests: `crates/zanshin-jj/tests/it/{op_integrate,op_restore_revert,snapshot_colocated}.rs`, `crates/zanshin-ffi/tests/it/op_log_ffi.rs`, `packages/zanshin_core/test/worker/op_verbs_test.dart`, oracle `scenarios.rs` / `main.rs`.
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`; `deferred-work.md` (two items mirrored).

**Review.** 25 findings: 1 medium, 17 low, 7 false. Patched 10 rows in 8 entries, all low (absent-operation code, head-load reconcile test, oracle `op revert --what`, `git_refs` without `@`, `RemoteTracking` doc, error-codes row, `eval_revset` `expect`, Dart `what` forwarding, the old-`@` warning half). Deferred: `Repo::status` without `@` (medium, pre-existing) and the `load_at_head` reload without workspace name (low, pre-existing pattern). Rejected: 7 false (carried claim/intent rows, smoke-level cdylib tests), 5 low (carried rebase count and integrate oracle rows ×2, per-verb `Option` promise, revert default `@` in two layers).

**Follow-up review recommended: false** (follow-up pass, no high patched; patched by verdict: 0 high, 0 medium, 8 low entries).

**Verification.** See `## Verification` → "Checks run (… follow-up review pass)": fmt, clippy, zanshin-jj / zanshin-ffi / oracle tests, codegen idempotence, the zanshin_core suite, analyze and format — all green. Full gate and coverage not run (story-loop gate rule).

**Residual risks.** Coverage unmeasured. `Repo::status` in a workspace without `@` still errors (deferred). The pre-existing flaky `op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` may turn the loop's final gate red (deferred).

**Residual risks (first pass).** Coverage unmeasured. The pre-existing flaky `op_diff_of_a_rebasing_merge_operation_fails_like_the_cli` may turn the loop's final gate red (deferred). `op integrate`'s real paths (unpublished child, reconciled sibling) are integration-tested only — the oracle compares only the no-effect case.
