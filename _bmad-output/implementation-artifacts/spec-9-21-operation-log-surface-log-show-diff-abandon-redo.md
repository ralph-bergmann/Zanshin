---
title: 'Story 9.21: Operation-log surface — `op log`, `op show`, `op diff`, `op abandon`, `redo` — CLI parity at v0.46.0'
type: 'feature'
created: '2026-10-23'
status: 'done'
baseline_revision: 'a951eff8714700d40c6f53d9c51b2268ecb256e7'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      `op diff --op @` of a merge operation whose parents both rewrote the same commits fails with jj-lib's internal error "Predecessors cycle detected around commit …", in the pinned CLI and in Zanshin alike (CLI parity, not a Zanshin defect).
    evidence: |-
      jj-lib 0.46.0 `evolution::accumulate_predecessors` on the merged from-repo; witnessed against the pinned CLI during the review-patch run and pinned by crates/zanshin-jj/tests/it/op_show_diff.rs op_diff_of_a_rebasing_merge_operation_fails_like_the_cli (Backend → jj.jj_lib_error). The GUI's "Show changes" on such an op would get an internal error.
    location: >-
      crates/zanshin-jj/src/op_diff.rs commits_diff
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin reads the op log (Epic 2) and undoes (9.39), but has no `jj redo`, `jj op show`, `jj op diff` or `jj op abandon`, and its op-log entries lack the creating workspace's name and the op tags. The guarded ⌘Z/⇧⌘Z, the "Undid ‹action› · Redo" toast and the Undo Timeline (10.9, 10.23, 11.9, 11.13) need redo, typed op entries and a typed cross-op diff.

**Approach:** Port `cmd_redo`, `cmd_op_show`, `cmd_op_diff` (its `show_op_diff` / `compute_operation_commits_diff` as typed data) and `cmd_op_abandon` from `../jj` @ v0.46.0 into `zanshin-jj`, widen `Operation`, and wire all four end to end (`.fbs` → zanshin-jj → `extern "C"` + codegen → `zanshin_core`), with parity-oracle scenarios for the two mutating verbs.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/{redo.rs,operation/{log,show,diff,abandon,mod}.rs}`, `cli_util.rs`, `command_error.rs`): preconditions and their order, refusal texts verbatim, op descriptions byte-identical, every on-disk effect (op store, op heads, the working copy's recorded operation). Terminal UX (templates, graph, pager, `-p` patches, status lines) is replaced by typed data.
- `redo` mirrors 9.39's `undo` and reuses its pieces (`UNDO_OP_DESC_PREFIX`, `restored_view` = `DEFAULT_REVERT_WHAT`, `start_repo_transaction`, `finish_verb` with 9.40's no-change gate): description `redo: restore to operation <hex>`; a target from ANOTHER workspace refuses unless `allow_cross_workspace` (an op with no workspace never refuses).
- `op show` / `op diff` / `redo` run the pre-verb snapshot (the CLI's `workspace_helper`); `op abandon` does NOT (the CLI's `load_workspace`): it runs only the start-up secure-config fix-up, like a clap refusal (`Repo::refuse_before_snapshot`), and leaves no precondition report.
- Operation strings are resolved by jj-lib's `op_walk` exactly as the CLI does (`@`, `@-`, `@+`, id prefixes): `op show` / `op diff` via `resolve_op_with_repo` on the head repo; `op abandon` via `resolve_op_at(op_store, get_current_head_ops(..))` (unmerged heads). `OpsetResolutionError::NoSuchOperation` → `jj.operation_not_found` (context = jj-lib text); every other resolution error → `jj.invalid_input` with jj-lib's text, and `MultipleOperations` carries the CLI hint "Try specifying one of the operations by ID: <12-hex>, …".
- `op diff`'s clap rule (`--operation` conflicts with `--from`/`--to`) refuses `jj.invalid_input` before the snapshot (`with_checked_verb`), wording as the existing clap refusals (`push.rs:775`).
- `show_changes_in` absent → `revsets.op-diff-changes-in` from the effective config (already in the stack via `CLI_DEFAULTS`, default `mutable() | immutable_heads()`); a config text that fails to parse → `jj.config_error` "Invalid `revsets.op-diff-changes-in`: …"; a caller text → `jj.revset_parse_error` with context "Invalid `--show-changes-in` expression: <text>: …"; parse diagnostics → `jj.revset_diagnostic` under "In `revsets.op-diff-changes-in`" / "In `--show-changes-in`". A resolution failure is NOT an error: warning `jj.op_diff_changes_unresolved` with "Could not resolve revset expression for elision: <err>" and the commit section absent (`null`).
- Every CLI `ui.warning_*` on a ported path is a registered warning code with the CLI text verbatim; status lines ("Nothing changed.", "Abandoned N operations and reparented M descendant operations.") are typed facts.
- Absence is `null`/`None`; new fbs fields are appended; never regenerate fixtures; every new extern gets a `packages/zanshin_core` real-cdylib test.

**Never:**
- No UI code, no MCP tool. No `op restore` / `op revert` / `op integrate` (9.12). No `--at-op`, `--ignore-working-copy`, templates (`-T`), `--no-graph` / graph layout, `--reversed`, `-p` / diff formats, `--no-op-diff`, `op log -d` — the GUI composes patches from the returned commit ids with the shipped `interdiff` / `show` (9.6), and lays out and orders rows itself.
- No ⌘Z guard logic (10.9's runner owns it), no ConfirmDialog copy (items 4–5 are UI records).
- Never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Op log entry | any op | + `workspace_name` (null when unrecorded, e.g. root), + `tags` (key/value, sorted by key) | — |
| Redo after undo | `describe`, `undo`, `redo` | view restored to the undone op's state; op `redo: restore to operation <hex of the describe op>` | — |
| Redo stack | undo, undo, redo, redo | each redo goes one step forward (CLI comment's example); a redo restoring a redo op restores its original op | — |
| Nothing to redo | head is no undo op (and no redo of one) | nothing written | `jj.nothing_to_redo` (new), context "Nothing to redo" |
| Redo cross-workspace | the undo op was written in `ws2` | refused unless `allow_cross_workspace` | `jj.redo_cross_workspace` (new), context `"<12-hex>\n<workspace>"`, hint "Use `--allow-cross-workspace` to redo it anyway, or use `jj op revert` to revert a specific undo operation" |
| Redo no change | restored view equals current | no op, pre-call head id (9.40) | — |
| Op show | `@` (default), `@-`, a prefix | the `Operation` + its `OpDiff` vs its parent | unknown id → `jj.operation_not_found`; ambiguous / invalid prefix → `jj.invalid_input` |
| Op show of a merge op | op with 2 parents | `Operation`, `diff = null` (the CLI prints none) | — |
| Op diff | `--from A --to B`, or `--op X` (= X's parents → X), or nothing (= `@`'s parents → `@`) | `from` ops, `to` op, `OpDiff` | `--op` with `--from`/`--to` → `jj.invalid_input`, before the snapshot |
| OpDiff content | describe / new / abandon / bookmark / tag / wc moves | `commits`: per changed commit (revset order) its key id, `abandoned`, added and removed (predecessor) commit ids; elided newly-visible/hidden `RefDistance`; changed working copies; local bookmarks/tags; remote bookmarks/tags (minus the `git` remote) with tracked state | unresolvable `show_changes_in` → warning, `commits = null` |
| Op abandon range | `..@-` | ops before `@` unreachable, `@` reparented onto root, op heads + working-copy op updated; counts; `@`'s parent is root afterwards | — |
| Op abandon nothing | range already empty (e.g. `..@-` twice) | `nothing_changed = true`, nothing written | — |
| Op abandon refusals | `@` / a range ending at a head; root; a merge op | "Cannot abandon the current operation <12-hex>" (+ hint "Run `jj undo` to revert the current operation, then use `jj op abandon`" with one head); "Cannot abandon the root operation"; "Cannot abandon a merge operation" | `jj.invalid_input`, nothing written |
| Op abandon, wc op elsewhere | the working copy's op is not a head | warning `jj.op_abandon_working_copy_not_updated` "The working copy operation <12-hex> is not updated because it differs from the repo <12-hex>, …." | — |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0` (`git -C ../jj show v0.46.0:<path>`): R = `cli/src/commands/redo.rs`, A = `operation/abandon.rs`, S = `operation/show.rs`, D = `operation/diff.rs`, L = `operation/log.rs`, M = `operation/mod.rs`, CE = `cli/src/command_error.rs`, CU = `cli/src/cli_util.rs`. jj-lib vendored at `~/.cargo/registry/src/*/jj-lib-0.46.0/src`.

**Prior art.**
- Redo R:51-171: `REDO_OP_DESC_PREFIX` R:51; head through the redo prefix R:105-117 ("Failed to parse ID of target operation in redo-stack"); not an undo op → "Nothing to redo" R:119-126; cross-workspace R:128-143 (text + hint, `short_operation_hash` = 12 hex); exactly one parent else internal "Undo operation should have a single parent" R:145-150; parent through the redo prefix R:159-171 ("Failed to parse ID of target operation's parent in redo-stack"); `view_with_desired_portions_restored(.., DEFAULT_REVERT_WHAT)` M:84-117; `tx.finish("redo: restore to operation <hex>")`.
- Abandon A:51-156: range parse A:66-87 (`a..b`; empty root side → `repo_loader.root_operation()`, empty head side → current heads; single op → its sole parent, refusals A:84-88); current-op refusal + one-head hint A:90-104; `op_walk::reparent_range` A:107-118 (`ReparentStats {new_head_ids, rewritten_count, unreachable_count}`, jj-lib `op_walk.rs:380-420`); all heads unchanged → "Nothing changed." A:120-123; status A:124-129; `op_heads_store.update_op_heads` per changed head A:130-135; working-copy remap via `workspace.start_working_copy_mutation()` + `locked_wc().old_operation_id()` + `finish(new_id)` else warning A:136-154.
- Show S:83-171: `resolve_single_op` (= `op_walk::resolve_op_with_repo(repo, s)`, CU:1824), parents, `merge_operations(None, loader, parents, None, None, &[])` (CU:853-878 → `RepoLoader::merge_operations`, jj-lib `repo.rs:869`), `load_at` both; `parent_ops.len() > 1` → no diff S:153-158.
- Diff D:95-186: from/to resolution D:104-112; merged from-op D:116-129; `to_repo.start_transaction()` + `merge_index(&from_repo)` for the shared index D:131-136 (dropped, never committed); `parse_op_diff_changes_in` D:189-223; `resolve_op_diff_changes_exprs` D:227-246; `show_op_diff` D:253-582 (section order: commits, working copies, local bookmarks, local tags, remote bookmarks, remote tags; `default_ignored_remote_name` CU:3465 filters `git`; `RemoteRefState::{New→untracked, Tracked→tracked}`); `compute_operation_commits_diff` D:739-823 (`accumulate_predecessors`, `count_estimate` of the elided parts, hidden-by-change map, `ModifiedChange::{Existing, Abandoned}`); `write_ref_target_summary` D:641-690 (absent / conflicted present adds+removes / normal).
- Opset errors CE:376-389 + hint CE:876-890. `count_estimate` is exact under 10 in tests (`testing` feature, `default_index/revset_engine.rs:195-213`).

**Reuse — `crates/zanshin-jj`.**
- `src/op_log.rs` — `Operation` :36 (append `workspace_name: Option<String>`, `tags: Vec<OperationTag>`), `op_log` :83 (fill them; `OperationMetadata.workspace_name` / `.tags`), `undo` :159, `through_undo` :237 (generalise to a prefix parameter for redo), `restored_view` :252, `UNDO_OP_DESC_PREFIX` :220. Put redo, show, diff, abandon here or in a new `src/op_diff.rs` for the diff computation (new file ≥ 80 % coverage).
- `src/repo.rs` — `op_log` :626, `undo` :1400 (template for `redo`), `with_verb` :479, `with_checked_verb` :492, `refuse_before_snapshot` :508 (`op_abandon`'s start), `workspace_mut` :231.
- `src/mutate.rs` — `MutateError` (add `NothingToRedo`, `RedoCrossWorkspace {operation, workspace}`, `OperationNotFound {reason}`; `hints()` arm with the redo hint const next to `UNDO_CROSS_WORKSPACE_HINT` :487), `finish_verb`, `mutation_result`, `be`, `invalid`/`invalid_hinted`, `rev` (`RevsetError` → `MutateError` :559), `cfg`.
- `src/revset.rs` — `revset_config` :249, `parse_diagnosed` :311 (context strings), `resolve_expression` :518 (resolve against the from-repo and the to-repo separately).
- `src/arrange.rs:280-300` — `target_expression`: the config-key revset read + parse template (`ctx.config.get(key)`, `crate::config::value_error`).
- `src/bookmarks.rs` — `RefDistance` (reuse for the elided estimates) and its `count_estimate` use :635.
- `src/op_support.rs` — `start_repo_transaction`.
- `src/warning.rs` — `WarningKind` (add `OpDiffChangesUnresolved`, `OpAbandonWorkingCopyNotUpdated`); `src/lib.rs` re-exports.

**Extend — wire + FFI.** `schemas/envelope.fbs`: `table Operation` :1214 (append `workspace_name: string`, `tags: [OperationTag]`), `RequestKind` (append `OpShow`, `OpDiff` after `SelectTree`), request tables `OpShowRequest {kind, operation, show_changes_in}` / `OpDiffRequest {kind, operation, from, to, show_changes_in}` (absent string = not given), payload tables `OpShow`, `OpDiffResult`, `OpDiff`, `OpChangedCommit`, `OpWorkingCopyChange`, `OpRefChange`, `OpRemoteRefChange`, `OpRefTarget`, `OpAbandonResult`, appended to `union Payload`; reuse `RefDistance` :1239; then `cargo make codegen` (commit generated files). `crates/zanshin-ffi/src/op_log.rs` (`op_log_to_envelope` fills the new fields; new externs `zanshin_op_show(handle, data, len)`, `zanshin_op_diff(handle, data, len)`, `zanshin_op_abandon(handle, *const c_char)`), `src/repo.rs:1363` `zanshin_undo` (template for `zanshin_redo(handle, bool)`), `map_mutate_err` :167 (new arms), `src/select_tree.rs:95` (request-reader template), `src/envelope.rs` (`JJ_NOTHING_TO_REDO`, `JJ_REDO_CROSS_WORKSPACE`, warning consts + `warning_code()` arms + table test, `expect_request_kind`), `src/lib.rs`. `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` `EXPECTED_EXPORTS` 85 → 89. `docs/ffi-abi.md` (index rows, request/payload tables, Payload count prose), `docs/rust-error-codes.md` (rows for the two new codes, `jj.operation_not_found` / `jj.invalid_input` / `jj.revset_parse_error` / `jj.config_error` emitters widened, two warning rows, close any "Not ported" row for these verbs).

**Extend — Dart (`packages/zanshin_core`).** `lib/src/ffi/op_log.dart` (`Operation` + `workspaceName` (String?) + `tags`; new models `OpShow`, `OpDiffResult`, `OpDiff`, `OpChangedCommit`, `OpWorkingCopyChange`, `OpRefChange`, `OpRemoteRefChange`, `OpRefTarget`, `OpAbandonResult`; decoders; request builders as in the select-tree / squash adapters), `lib/src/ffi/mutate.dart` (undo adapter → template for redo), `lib/src/worker/{commands,isolate,handle}.dart` (`RepoHandle.redo({bool allowCrossWorkspace = false})`, `opShow`, `opDiff`, `opAbandon` next to `undo` / `opLog`), `lib/src/ffi/warning.dart` (`ZanshinWarningCode`), barrel `lib/zanshin_core.dart`.

**Tests.** `crates/zanshin-jj/tests/it/op_log.rs` (extend; template for undo-stack witnesses) or new modules `redo.rs`, `op_show_diff.rs`, `op_abandon.rs` declared in `tests/it/main.rs`; `tests/it/op_workspace_name.rs` (its module doc says exposing the field is 9.21's — switch one row to read it through `Repo::op_log`); `tests/it/api_stability.rs` (pin new signatures/types, new warning kinds); FFI `tests/it/op_log_ffi.rs`; Dart `test/` (mirror the undo tests: find them with `rg -l "undo" packages/zanshin_core/test`). Oracle `crates/zanshin-parity/tests/oracle/scenarios.rs:808-1076` (undo scenarios = template), `main.rs` (scenario list/count), `ledger.rs`, `state.rs:397-460` (operation aspects walk "since before": after `op abandon` the old head is gone — verify the comparison is meaningful, else an `extra` read-back of the op chain shape or a ledger entry with reason).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/op_log.rs` (+ new `src/op_diff.rs` if it helps) -- widen `Operation`; add `redo(workspace, ctx, allow_cross_workspace)`, `op_show(workspace, ctx, operation, show_changes_in)`, `op_diff(workspace, ctx, &OpDiffOptions)`, `op_abandon(workspace, operation, warnings)` and the typed result types (`OpShow {operation, diff: Option<OpDiff>}`, `OpDiffResult {from: Vec<Operation>, to, diff}`, `OpDiff {commits: Option<OpCommitsDiff>, working_copies, local_bookmarks, local_tags, remote_bookmarks, remote_tags}`, `OpCommitsDiff {changes: Vec<OpChangedCommit {commit_id, abandoned, added_commit_ids, removed_commit_ids}>, elided_newly_visible: RefDistance, elided_newly_hidden: RefDistance}`, `OpWorkingCopyChange {workspace, from: Option<String>, to: Option<String>}`, `OpRefChange {name, from: OpRefTarget, to}`, `OpRemoteRefChange {name, remote, from, from_tracked, to, to_tracked}`, `OpRefTarget {adds, removes, conflicted}`, `OpAbandonResult {abandoned_count, reparented_count, nothing_changed, head_op_ids}`), each step ported per the Code Map with module/fn docs citing the CLI lines; inline unit tests for pure helpers (range parsing, ref-target mapping, opset error mapping).
- `crates/zanshin-jj/src/{mutate,warning,lib,repo}.rs` -- new `MutateError` variants + hint, two `WarningKind`s, re-exports, and `Repo::redo(bool)` / `op_show(&str, Option<&str>)` / `op_diff(&OpDiffOptions)` / `op_abandon(&str)` with house doc blocks (`# Errors`).
- `schemas/envelope.fbs` + `cargo make codegen` -- tables/enums/union appends as in the Code Map; commit generated files.
- `crates/zanshin-ffi/src/{op_log,repo,envelope,lib}.rs` -- four externs, readers, serialisers, error/warning mapping, full rustdoc (`# Errors` = registry codes, `# Safety`); `EXPECTED_EXPORTS` → 89.
- `packages/zanshin_core` -- models, decoders, adapters, worker commands, `RepoHandle` methods, warning constants, barrel; tests: synthetic decode of every new payload, real-cdylib round trips for `redo` (undo then redo; nothing to redo), `opShow`, `opDiff` (incl. the conflicting-flags refusal), `opAbandon` (range + current-op refusal), and the op log's `workspaceName`.
- `crates/zanshin-jj/tests/it/` -- every I/O-matrix row (redo stack incl. the CLI comment's `undo, undo, redo, redo`, CLI ↔ Zanshin interleaving through the description; op show/diff on describe, new, abandon, bookmark create/move/delete, tag via jj-lib in-test, a remote bookmark set in-test, working-copy move, merge-op show; op abandon range/nothing/refusals/working-copy op remap + warning via a second workspace or a divergent head); api_stability pins.
- `crates/zanshin-ffi/tests/it/op_log_ffi.rs` -- readers (absent vs present strings, wrong kind, malformed buffer), zero handle, each payload on the wire, refusal envelopes with hints.
- `crates/zanshin-parity/tests/oracle/{scenarios,main,ledger}.rs` -- `redo_after_undo`, `redo_nothing`, `redo_stack` (undo, undo, redo), `redo_cross_workspace`, `op_abandon_range` (`..@-`), `op_abandon_current_refused` (`@`), `op_abandon_root_refused`; ledger entries only with reason + reference.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- as in the Code Map.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-21-operation-log-surface-log-show-diff-abandon-redo` to `done` with a sibling-style summary (bump `last_updated`); mirror every `deferred:` item under `## Surfaced in Story 9.21 (bmad-build-auto, 2026-10-23)`.

**Acceptance Criteria:**
- Given the four verbs, when a Dart caller reaches them, then the whole chain exists (`.fbs`, zanshin-jj verb, `extern "C"`, committed codegen, adapter, worker command, `RepoHandle` method) and `ffi_abi_doc_sync` passes with 89 exports.
- Given `undo` followed by `redo`, when the oracle runs the scenarios above, then each matches the pinned CLI on every aspect or diverges only through a ledgered entry with reason and reference.
- Given `op abandon ..@-`, when `op_log` is read afterwards, then the newest entry's `parentIds` is the root op's id (the undo guard's input, item 2), and no operation was written.
- Given any refusal, when the op heads are compared before and after, then they are unchanged (zanshin-jj and FFI layers).
- Given the end of the run, then the targeted checks named in Verification pass, `git status --porcelain` is clean and every commit ends with the required co-author trailer.

## Spec Change Log

- 2026-10-23 (implementation): the commit ids of `OpDiff` (`OpChangedCommit`, `OpWorkingCopyChange.from` / `.to`, `OpRefTarget`) are the crate's hex `CommitId` newtype rather than bare `String`s, as every other commit id of the public API; on the wire they are strings. The commit section is its own table, `OpCommitsDiff` (absent = the CLI printed none), beside the tables the Code Map lists. `op diff`'s throw-away transaction is opened through `op_support::start_repo_transaction` (never committed), which `op_support`'s creep guard requires of every transaction in the crate.

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 27 findings — high 0, medium 4, low 14, false 9, maybe-false 0 (2 lows rejected)
- findings:
  - `[low]` `[patch]` (edge-case) `jj.op_diff_changes_unresolved` drops the CLI's detail line "   (Use --show-changes-in=all() to see all changes)" written at the same site (diff.rs show_op_diff), against warning.rs's message contract — detail line appended verbatim, registry row updated.
  - `[low]` `[reject]` (edge-case) op abandon: a working-copy lock/finish failure after the op heads were rewritten returns Err and loses the counts — the CLI fails the same way after the same rewrite (abandon.rs:136-154 `?`); reaching it needs a lock failure, and a partial-result error type is more than a direct correction.
  - `[false]` `[reject]` (edge-case) a refused redo / op show / op diff can still move the op head via the pre-verb snapshot — that is the CLI's flow (workspace_helper snapshots before the verb body refuses), which the project rule "a refused verb writes no operation unless the CLI's flow wrote one before refusing" requires; the verb itself writes nothing.
  - `[low]` `[patch]` (edge-case) range parsing has no inline unit test as the task said — grouped with the bounded-range gap below: an integration witness of the non-empty left side added (the parse is three lines inline in op_abandon; a pure helper for it adds nothing).
  - `[medium]` `[patch]` (verification-gap) `show_changes_in` never observed crossing FFI/Dart — real-handle zanshin_op_show/zanshin_op_diff and `opShow`/`opDiff` with `none()` asserting an empty commit section and a non-zero elided count added.
  - `[medium]` `[patch]` (verification-gap) op diff of a merge op (merged from-repo) untested — `op_diff --op @` on a divergent merge (from = both parents, no stray rows) and op diff of the root op added.
  - `[medium]` `[patch]` (verification-gap) op abandon with a non-empty range start untested — bounded `<op>..@-` test added (counts, head's new parent = `<op>`).
  - `[medium]` `[patch]` (verification-gap, other) op abandon searched the working-copy op only among CHANGED heads, warning falsely when the working copy sits at an unchanged head of two — now searches every reparented pair as abandon.rs:136-154 does; witness added.
  - `[false]` `[reject]` (blind) redo drops "Restored to operation:" so the caller cannot learn the restored op — the written op's description `redo: restore to operation <hex>` names it (op_log/op_show head entry), and with no change nothing is restored; same shape as 9.39's undo.
  - `[low]` `[patch]` (blind) same root as the first edge-case row (warning detail line) — fixed with it.
  - `[low]` `[patch]` (blind) `jj.invalid_input` Meaning column's exhaustive hints list misses the two new hinted refusals — added.
  - `[low]` `[patch]` (blind) `jj.operation_not_found` Meaning not widened and cites v0.44.0 — widened to caller-typed operation expressions, cites v0.46.0.
  - `[low]` `[patch]` (blind) bounded range never exercised — same group as the verification-gap row.
  - `[low]` `[patch]` (blind) oracle never redoes while the head is a redo op; no op abandon single / nothing scenario — `redo_of_a_redo`, `op_abandon_single`, `op_abandon_nothing` added.
  - `[low]` `[patch]` (blind) `op_abandon_range` runs on a near-empty history — setup of a few describes added.
  - `[low]` `[patch]` (blind) no real-repo test for an absent working-copy side — `op_show` after `workspace_add` (`from: None`) added.
  - `[low]` `[patch]` (blind) op diff with several or zero from-ops untested — same group as the verification-gap merge-op row.
  - `[low]` `[patch]` (blind) FFI tests miss invalid UTF-8 for zanshin_op_abandon and a present lone `to` / `show_changes_in` — added.
  - `[low]` `[patch]` (blind) working-copy remap checked only indirectly — the bounded-range test asserts the recorded working-copy op id equals `head_op_ids[0]`.
  - `[false]` `[reject]` (blind) sprint-status done while the spec is in-review — the run was mid-review; finalisation sets the spec done in the same run.
  - `[low]` `[reject]` (intent 3a) oracle redo-stack coverage partial — superseded by the `redo_of_a_redo` row above (counted there as the patch); kept as a rejected duplicate observation.
  - `[false]` `[reject]` (intent 3b) op show / op diff have no oracle scenario — the oracle compares repo state and warning counts; read verbs change neither, and their CLI output is terminal text (epic context: "Reads … need hand audit").
  - `[false]` `[reject]` (intent 3c) op show / op diff carry no head-op field — the reading "every result" is the mutating results (item 1 serves the undo guard); a read's `to`/shown op carries its id.
  - `[false]` `[reject]` (intent 3d) UI items unwired — CLAUDE.md: UI code only inside a story that asks for it; items 4-5 are records for 10.9/10.23/11.9/11.13.
  - `[false]` `[reject]` (intent 3e) item 1's open race not deferred — it is an open Ralph decision already recorded in epics.md 9.21 item 1, not a gap this story found.
  - `[false]` `[reject]` (intent 3f) checks not recorded under the spec's verification notes — finalisation records every check and outcome under Verification and Auto Run Result (this run's rule), not a code fix.
  - `[false]` `[reject]` (intent 3g) op log only widened, not re-ported — the shipped Epic 2 read is the walk the CLI does (walk_ancestors from the head, limit); the remaining `op log` flags are terminal UX (spec Never).

## Design Notes

- **Typed op diff, not text.** The CLI's `show_op_diff` output maps 1:1 onto `OpDiff` sections; a changed commit carries ids only — the GUI gets summaries from `commit_contents` and patches from `interdiff(predecessor[0] → commit)` / `show(abandoned)` (the CLI's own `show_change_diff` choice). Row order = the flat (`-G`) revset order; the graph layout is UI.
- **Codes.** `jj.nothing_to_redo` and `jj.redo_cross_workspace` mirror undo's two codes (one remedy each). Abandon's three refusals are `jj.invalid_input` (CLI `user_error`, no specific remedy beyond the hint). Opset `NoSuchOperation` reuses `jj.operation_not_found` (same meaning as 4.10's).
- **`op abandon` and the handle.** It rewrites op heads without a transaction; the handle's next call re-resolves the head (ADR-0002), so nothing cached needs invalidating — verify no `Repo` field holds an op id across calls.

## Verification

**Commands (the story loop's gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj` -- all pass (or at least `--test it` modules touched + lib unit tests)
- `cargo test -p zanshin-ffi` -- all pass
- `cargo test -p zanshin-parity --test oracle` -- all pass
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo fmt --all --check` -- clean
- `cargo make codegen` -- generated files committed, rerun leaves no diff
- `flutter test` + `dart analyze` + `dart format --set-exit-if-changed .` in `packages/zanshin_core` -- clean

**Checks run (2026-10-23, build-auto run; full gate deliberately not run — story-loop gate rule):**
- `cargo fmt --all --check` — clean (after implementation and again after the review patches).
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean (both rounds).
- `cargo test -p zanshin-jj` — 348 unit + 1187 integration passed, 1 ignored (pre-existing); after the patches 348 + 1193 passed, 1 ignored. `op_show_diff::op_diff_of_a*` repeated 5× — stable.
- `cargo test -p zanshin-ffi` — 212 unit + 339 integration passed; after the patches 212 + 341 (incl. `ffi_abi_doc_sync` at 89 exports).
- `cargo test -p zanshin-parity --test oracle` — 310 passed; after the patches 313 (no ledger entry for the new scenarios).
- `cargo make codegen` — rerun leaves no diff (both rounds).
- `packages/zanshin_core`: `cargo make --allow-private test-core` (`dart test` with the pinned env; a bare `dart test` / `flutter test` fails its env guard "XDG_CONFIG_HOME is not pinned") — 1016, then 1017 tests passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed` — 0 changed. `app/`: `dart analyze --fatal-infos` — no issues.
- Coverage not measured (gate rule); new lines got tests.

## Auto Run Result

Status: done

**Summary.** Ported `jj redo`, `jj op show`, `jj op diff` and `jj op abandon` @ v0.46.0 into `zanshin-jj` and wired them end to end; `Operation` now carries `workspace_name` and `tags`. Redo reuses 9.39's undo pieces (stack through `REDO_OP_DESC_PREFIX`, `restored_view`, 9.40's no-change gate); op show/diff return a typed `OpDiff` (commits with predecessors and elided estimates, working copies, local/remote bookmarks and tags); op abandon runs no snapshot, reparents through `op_walk::reparent_range`, rewrites the op heads and remaps the working copy.

**Files changed.**
- `crates/zanshin-jj/src/op_log.rs` — widened `Operation`, `redo`, `op_show`, `op_diff`, `op_abandon`, opset error mapping.
- `crates/zanshin-jj/src/op_diff.rs` (new) — `parse_changes_in`, typed `show_op_diff` / `compute_operation_commits_diff` port.
- `crates/zanshin-jj/src/{mutate,warning,lib,repo}.rs` — `NothingToRedo`, `RedoCrossWorkspace` (+hint), `OperationNotFound`; two warning kinds; re-exports; four `Repo` methods.
- `schemas/envelope.fbs` + generated Rust/Dart/C — `OperationTag`, request/payload tables, `RequestKind::OpShow/OpDiff`.
- `crates/zanshin-ffi/src/{op_log,repo,envelope}.rs` — `zanshin_redo`, `zanshin_op_show`, `zanshin_op_diff`, `zanshin_op_abandon` (89 exports), codes `jj.nothing_to_redo`, `jj.redo_cross_workspace`.
- `packages/zanshin_core` — models/decoders, adapters, worker commands, `RepoHandle.redo/opShow/opDiff/opAbandon`, warning constants.
- Tests: `crates/zanshin-jj/tests/it/{redo,op_show_diff,op_abandon}.rs` (new), `op_log.rs`, `op_workspace_name.rs`, `api_stability.rs`; `crates/zanshin-ffi/tests/it/op_log_ffi.rs`; Dart `test/ffi/op_log_test.dart`, `test/worker/op_verbs_test.dart`; oracle scenarios (10 new: redo ×5, op abandon ×5).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`; `sprint-status.yaml`, `deferred-work.md`.

**Review.** 27 findings (4 layers): 16 patched (4 medium — `show_changes_in` across the FFI/Dart seam untested, merge-op op diff untested, bounded abandon range untested, false working-copy warning when the wc op is an unchanged head of two (code fix); 12 low — warning detail line restored, two registry rows corrected, oracle/redo/abandon/FFI/workspace-add tests); 9 false and 2 low rejected (reasons in the triage log: CLI-parity snapshot before refusals, redo's restored op named by its description, wc lock failure after the head rewrite mirrors the CLI, the read verbs have no oracle surface, UI items out of scope). 1 item deferred (jj-lib's "Predecessors cycle detected" on a rebasing merge op, CLI parity), mirrored into deferred-work.md.

**Follow-up review recommended: true** (first pass, 4 medium entries patched). The unverified risk: the `op_abandon` working-copy remap now searches every reparented head and calls `finish` for an unchanged head too — witnessed by one two-head test only, and never by the oracle (two-workspace abandon scenarios are absent).

**Verification.** See `## Verification` → "Checks run": fmt, clippy, `cargo test` for zanshin-jj / zanshin-ffi / the parity oracle, codegen idempotence, the zanshin_core suite via `cargo make --allow-private test-core`, analyze and format — all green. Coverage and the full gate were not run (story-loop gate rule).

**Residual risks / incident.**
- Coverage unmeasured; `op_diff.rs`'s non-resolution fallback in `resolve_both` may be uncovered (file expected above the 80 % floor).
- INCIDENT during the review-patch run: a bare `cd r` in the implementation subagent's shell was resolved by zoxide to `/Users/ralph.bergmann/development/projects/Kunden/viega/TWMS-Flutter-App`, and a few `target/debug/jj` commands ran there (`JJ_CONFIG=/dev/null JJ_USER=t JJ_EMAIL=t@t`). Per the subagent, jj's start-up snapshot wrote two operations there at 2026-10-23 23:03:57 (`0081acda15d9` "snapshot working copy", `db47525e502f` "import git refs"); a dirty working copy would have been snapshotted with committer "t <t@t>". Nothing was undone; `jj op restore ef2e5a032688` there restores the prior state — Ralph's decision.
