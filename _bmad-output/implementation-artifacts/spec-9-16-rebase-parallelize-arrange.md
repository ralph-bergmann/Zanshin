---
title: 'Story 9.16: `rebase`, `parallelize`, `arrange` (headless)'
type: 'feature'
created: '2026-10-23'
status: 'done'
baseline_revision: '7f6d75b29870e91cb8db33e0a2a85ac314d8ed63'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      The cbindgen-generated `zanshin_ffi.h` keeps each bare FlatBuffers `VT_*` offset name only once across all tables, so adding tables silently drops other tables' `Table_VT_*` defines.
    evidence: |-
      Story 9.16's regeneration removed `GitPushRequest_VT_REVISIONS`, `RepoCloneRequest_VT_SOURCE`, `DropActionsRequest_VT_CHANGE_ID` and `DropActions_VT_ACTIONS` and emitted only part of the new tables' offsets; the baseline header already held a single `_VT_KIND` for every table. No C, Dart or Rust consumer reads these defines today (the FlatBuffers code is generated separately).
    location: >-
      crates/zanshin-ffi/include/zanshin_ffi.h; the cbindgen config of crates/zanshin-ffi
    severity: low
    resolved: >-
      2026-10-23 — fixed (spec-9-16-closing-cbindgen-ignores-flatbuffers-module, commit 3154d45): cbindgen skips
      the flatc module (`cbindgen:ignore`), so the header carries no VT_*/ENUM_* defines; a guard test fails on any
      `#define` but the include guard.
  - summary: >-
      No Dart round trip observes `keepDivergent`: dropping it anywhere along `RepoHandle.rebase` → worker → `zanshinRebase` would still pass the zanshin_core suite.
    evidence: |-
      `every_rebase_field_crosses_the_buffer` passes `keepDivergent: true` on a history with no divergent commit, so the flag cannot change the outcome; making a divergent commit needs jj-lib directly (the jj-level `divergent_b` makes an old commit visible again), which the Dart API cannot do. The Rust reader test `the_rebase_reader_carries_every_flag` and the jj-level `a_divergent_twin_already_in_the_destination_is_abandoned_unless_kept` cover the Rust side only. `simplifyParents` got its Dart witness in the follow-up review.
    location: >-
      packages/zanshin_core/test/worker/rebase_test.dart (every_rebase_field_crosses_the_buffer); packages/zanshin_core/lib/src/worker/handle.dart:947, isolate.dart:1637 and :3076, ffi/rebase.dart:86
    severity: low
---

<intent-contract>

## Intent

**Problem:** zanshin-jj has no `jj rebase`, `jj parallelize` or `jj arrange`. The floating client's drop menu (10.10) runs four rebase forms (`-s S -o T`, `-r S -o T`, `-r S -A T`, `-r S -B T`) and today only previews them (9.31's plan fns, which no verb calls yet). The deferred-work item I1 (`-s`/`-b` with `-A`/`-B` when the target lies inside the moved set) is still unsettled.

**Approach:** Port `cmd_rebase`, `cmd_parallelize` and the non-TUI half of `cmd_arrange` step for step at v0.46.0 over jj-lib, end to end (`.fbs` → zanshin-jj → `extern "C"` → `zanshin_core`). The rebase verb calls 9.31's existing plan fns (`plan_rebase_revisions` / `plan_rebase_source` / `plan_rebase_branch`) and shares ONE move-application fn with `rebase_is_no_op`, so preview and execution agree by construction. `arrange` replaces the ratatui TUI with a headless list of the TUI's own key actions (swap down, swap up, abandon, keep) replayed on a port of the CLI's `State`.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:cli/src/commands/{rebase,parallelize,arrange}.rs`): preconditions and their order, refusal texts verbatim (12-hex `short_commit_hash`), op descriptions byte-identical (`rebase commit <hex>`, `rebase commit <hex> and <n> more`, `rebase <n> commits`, `rebase commit <hex> and descendants`, `rebase <n> commits and their descendants`, `parallelize <n> commits`, `arrange revisions`), every repo effect (bookmarks, `@`, abandoned divergent / emptied commits).
- clap's rules become `MutateError::InvalidInput` naming the flags (house style, `squash_split.rs:241`), checked before anything resolves: at most one of `branch`/`source`/`revisions`; at least one location flag; `onto` excludes `insert_after`/`insert_before` (reuse `op_support::NO_LOCATION` / `ONTO_WITH_INSERT`).
- All three empty (`branch`, `source`, `revisions`) = the CLI's `-b @`: the verb resolves `@` and passes it to `plan_rebase_branch`.
- An empty target (e.g. `-b` already on the destination) is the CLI's "No revisions to rebase." — no operation, `new_op_id` = pre-call head. A move that changes nothing is "Nothing changed." — no operation (shared gate, `mutate::finish_verb` / `no_op_result`).
- `skip_emptied` (→ `EmptyBehavior::AbandonNewlyEmpty`), `keep_divergent` (skips `find_duplicate_divergent_commits`), `simplify_parents` (→ `simplify_ancestor_merge`) pass through as the CLI's flags; `delete_abandoned_bookmarks: false` always.
- `MutationResult` is the result of all three verbs (no new result type — the 10.10 design takes anchor/flash/origin from the request). `abandoned_change_ids` = jj-lib's own abandonments (divergent duplicates, newly emptied commits, arrange's abandons); `new_change_ids` = the replacement `@` only when `@` was abandoned (squash's rule).
- Every verb goes through `Repo::with_verb` (9.26 snapshot, 9.32 warnings); refusals reuse registered codes (`jj.invalid_input`, `jj.immutable`, `jj.change_not_found`, `jj.config_error`, `jj.jj_lib_error`, precondition codes) — NO new error or warning code.
- `arrange`: target = `revisions`, or `revsets.arrange` (jj-cli default layer, `reachable(@, mutable())`) parsed "In revset expression" when empty; `check_rewritable` on the target; gaps (`connected(T) ~ T` non-empty) refuse "Cannot arrange revset with gaps in." with hint "Revision <12 hex> would need to be in the set." (`MutateError::invalid_hinted`); empty target = "No revisions to arrange." no-op; then `State::new` → actions replayed → `to_rewrite_plan` → `RewritePlan::execute` → `rebase_descendants` → finish "arrange revisions". A swap the TUI would ignore (not exactly one parent/child, or an external one) is ignored, as the TUI does; an action naming a change outside the target set refuses `jj.invalid_input` ("<change id> is not among the revisions to arrange").
- I1 is settled by tests, not by a new refusal: the verb does exactly what the CLI does (no up-front check for `-s`/`-b` + `-A`/`-B` inside the moved set); a zanshin-jj test pins jj-lib's answer and oracle scenarios prove parity.

**Never:**
- No ratatui/TUI, no `templates.arrange` rendering, no arrange scroll/selection state; "Canceled by user" is not ported (the GUI simply does not call).
- No status-line facts (`Rebased N commits…`, `Abandoned N divergent commits…`) as warnings or new fields.
- No change to `drop_actions`' rows or outcomes (its `-s` rows stay `onto`-only; the shared move fn must keep `rebase_is_no_op`'s answers byte-identical).
- No MCP tool, no UI code; never regenerate fixtures; never lower the coverage baseline or add an `exclude_prefix`.

## I/O & Edge-Case Matrix

Fixture shorthand: `BASE` = A (a.txt) → B (b.txt, bookmark `b-mark`) → C (c.txt) = `@`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Move here | `source=[C]`, `onto=[A]` | C rebased onto A; op `rebase commit <C hex> and descendants` | — |
| Move only this | `revisions=[B]`, `onto=[root]` | B onto root, C onto A; op `rebase commit <B hex>` | — |
| `-r` onto own descendant | `revisions=[B]`, `onto=[C]` | allowed: C onto A, B onto C' | — |
| Insert after / before | `revisions=[C]`, `insert_after=[A]` / `insert_before=[B]` | C between A and B | loop / immutable-child refusals of `compute_commit_location` |
| Default `-b @` | nothing in `branch/source/revisions`, `onto=[X]` | `roots(X..@)` rebased onto X | — |
| Already in place | `source=[B]`, `onto=[A]`; or `branch=[A]`, `onto=[B]` | no operation; `new_op_id` = pre-call head | — |
| `-s` onto descendant / itself | `source=[A]`, `onto=[B]` / `[A]` | "Cannot rebase <A12> onto descendant <B12>" / "…onto itself" | `jj.invalid_input`, no op |
| I1 corner | `source=[A]`, `insert_after=[B]` (and `insert_before=[C]`) | whatever jj-lib's `compute_move_commits` does — same as the CLI (oracle) | as the CLI |
| clap conflicts | `revisions`+`source`; no location; `onto`+`insert_after` | refused before resolution | `jj.invalid_input` |
| Immutable | target or rewritten child immutable | refusal | `jj.immutable` |
| `skip_emptied` | B's change re-applied empty after move | newly emptied commit abandoned, listed in `abandoned_change_ids` | — |
| Parallelize | `[B, C]` | B and C siblings on A; op `parallelize 2 commits` | immutable target needing rewrite → `jj.immutable` |
| Parallelize no-op | `[B]` or `[]` | no operation | — |
| Arrange swap | `revisions=[B, C]`, `[SwapDown(C)]` | C on A, B on C; op `arrange revisions` | — |
| Arrange abandon | `[Abandon(B)]` | B abandoned, C onto A | — |
| Arrange no actions / ignored swap | `[]` or `[SwapDown(B)]` with B's parent external | no operation | — |
| Arrange gaps | `revisions=[A, C]` | "Cannot arrange revset with gaps in." + hint "Revision <B12> would need to be in the set." | `jj.invalid_input` with `hints`, no op |
| Arrange empty / foreign id | target empty; action on a change outside the set | no op / refusal | — / `jj.invalid_input` |

</intent-contract>

## Code Map

CLI anchors at `v0.46.0` (copies: `git -C ../jj show v0.46.0:cli/src/commands/<f>.rs`); jj-lib in vendored `~/.cargo/registry/src/*/jj-lib-0.46.0/src`; Zanshin at baseline `7f6d75b`.

**Prior art (read-only)**
- `cli/src/commands/rebase.rs` — `RebaseArgs` `:265-326` (ArgGroup `to_rebase`, `skip_emptied`, `keep_divergent`, `simplify_parents`), `RebaseDestinationArgs` `:328-366` (group required, `onto` conflicts `-A`/`-B`); `cmd_rebase` `:368-429` (options `:374-383`, plan dispatch `:386-392`, "No revisions to rebase." `:394-401`, `compute_move_commits` + divergent `:403-423`, apply + finish `:424-426`); plan fns `:431-599` (already ported); `tx_description` `:601-615`.
- `cli/src/commands/parallelize.rs` `:71-156` — the whole verb (two-map recompute, `check_rewritable(needs_rewrite)`, `transform_descendants`).
- `cli/src/commands/arrange.rs` — `cmd_arrange` `:90-170` (target, `check_rewritable_expr`, gaps + hint `:109-120`, external children `:122-130`, "No revisions to arrange." `:134-137`, execute + finish `:161-166`); `State` `:186-413` (`new`, `swap_commits`, `to_rewrite_plan`, `swap_selection_down/up`; skip `update_commit_order`/`clamp_scroll`/`current_*` — selection is by id here); `RewritePlan::execute` `:431-471`; `handle_key_event` `:555-582` (the action set); unit tests `:699-1298` (port `test_swap_commits`, `test_swap_selection_down/up`, `test_execute_plan_reorder/abandon` as Zanshin tests).
- CLI tests to mirror: `cli/tests/test_rebase_command.rs` `test_rebase_invalid` `:22`, `test_rebase_empty_sets` `:134`, `test_rebase_revision_onto_descendant` `:657`, `test_rebase_after` `:1337`, `test_rebase_before` `:1846`, `test_rebase_skip_emptied` `:2647`, `test_rebase_skip_duplicate_divergent` `:2921`, `test_rebase_simplify_parents` `:3007`; `cli/tests/test_parallelize_command.rs` (`:20-710`, incl. immutable cases `:648`, `:710`).
- jj-lib `rewrite.rs`: `MoveCommitsLocation`/`Target` `:596-603`, `compute_move_commits` `:667` (I1: a new parent inside the target set is replaced by the set's external parents `:748-761`, a new child inside it by its external descendants `:763-837`), `find_duplicate_divergent_commits`, `ComputedMoveCommits::{record_to_abandon, apply}` (returns `MoveCommitsStats`), `CommitRewriter::{new, abandon, rebase, parents_changed, set_new_rewritten_parents}`; `repo.rs` `MutableRepo::{transform_descendants, new_parents, rebase_descendants}`; `dag_walk::topo_order_forward`.

**Reuse — `crates/zanshin-jj`**
- `src/rebase.rs` — plan fns `:52-151`, `check_rebase_destinations` `:161`, `rebase_is_no_op` `:203-225` (extract its body after the empty check into a shared `apply_move(tx, loc, &jj_lib::rewrite::RebaseOptions, keep_divergent) -> Vec<Commit /*divergent*/>` both call; the preview keeps the default options), `load_dry_run_head`, `unsupported` `:262`. Module doc `:3-13` names 9.16 as the caller — update it.
- `src/drop_actions.rs:271-290` — the rebase rows (must keep passing unchanged).
- `src/squash_split.rs` — verb template: `squash` `:362-426` (load head, `start_repo_transaction`, plan, mutate, `rebase_descendants`, `has_changes` gate → `no_op_result`, `finish_verb`, `mutation_result`); clap-conflict refusals `:241-246`.
- `src/mutate.rs` — `MutationResult` `:59`, `MutateError::invalid` `:462` / `invalid_hinted` `:471`, `guard_rewritable` `:611`, `finish_verb` `:843`, `mutation_result` `:891`, `no_op_result` `:1414`, helpers `be`/`cfg`/`res`.
- `src/op_support.rs` — `LocationArgs` `:190`, `NO_LOCATION`/`ONTO_WITH_INSERT` `:179-184`, `resolve_ordered`, `resolve_or_wc`, `start_repo_transaction`, `check_rewritable`/`resolve_immutable`.
- `src/revset.rs` — `revset_config` `:249`, `parse_diagnosed` (context `IN_REVSET_EXPRESSION`) for `revsets.arrange`; `push.rs:1114-1145` shows a config revset parsed + evaluated; config read via `crate::config` (the key reaches the stack through `CLI_DEFAULTS`, `config.rs:190-194`).
- `src/repo.rs` — `with_verb` `:476`; facades `squash` `:2471`, `split` `:2616` (doc-block template: `# Errors` one bullet per reachable variant). New facades after `split`.
- `src/lib.rs` — module list + re-exports.

**Extend — wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` `:~100-133` (append `Rebase`, `Parallelize`, `Arrange`), `ChangeIdList` `:143` (reused by `zanshin_parallelize` with kind `Parallelize`; extend its doc), new `RebaseRequest`, `ArrangeRequest` + `ArrangeAction` table + `ArrangeActionKind` enum after the squash/split requests (field order = wire contract, `kind` field 0); results reuse `MutationResult`.
- `crates/zanshin-ffi/src/squash_split.rs` — reader + extern template (`read_split_request` `:80`, `zanshin_split`); new `crates/zanshin-ffi/src/rebase.rs` with `zanshin_rebase`, `zanshin_parallelize`, `zanshin_arrange`; `lib.rs` module list `:29-60`; `repo.rs` `map_mutate_err` `:167`; `envelope.rs` `precondition_envelope` `:532`, `ok_mutation_result`.
- Generated (only via `cargo make codegen`): `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` (symbol index + request tables) and guard `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs` `EXPECTED_EXPORTS = 75` `:37` → 78; `docs/rust-error-codes.md` ("also emitted — Story 9.16" clauses on reused rows).

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/squash_split.dart` (template) → new `lib/src/ffi/rebase.dart`; reuse `mutate.dart`'s `decodeMutationResultInternal` / mutation-envelope decoder; `lib/src/worker/{commands,isolate,handle}.dart` (`SplitCommand`, `split` worker method + dispatch arm, `RepoHandle.split` as templates); barrel `lib/zanshin_core.dart`.
- Tests: `test/ffi/squash_split_test.dart`, `test/worker/squash_split_test.dart` (synthetic + real-cdylib templates; every new extern needs a real-cdylib test or the coverage extern-fn guard fails).

**Tests / gates**
- `crates/zanshin-jj/tests/it/main.rs` (declare new modules) + `tests/it/squash_split.rs` / `drop_actions.rs` (harness templates), `tests/it/api_stability.rs` (surface pin template, e.g. squash/split).
- `crates/zanshin-ffi/tests/it/squash_split_ffi.rs` (FFI harness template).
- `crates/zanshin-parity/tests/oracle/scenarios.rs` (`BASE` `:32`, `simple`, `s.change`/`s.change_arg`, squash scenarios `:1230-1300`), `main.rs` `parity!` list, `ledger.rs` (only with reason + reference).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/rebase.rs` -- add public `RebaseOptions { branch, source, revisions, onto, insert_after, insert_before: Vec<ChangeId>, skip_emptied, keep_divergent, simplify_parents: bool }` (empty vec = flag not given), `pub(crate) fn rebase(workspace, ctx, &RebaseOptions) -> Result<MutationResult, MutateError>` (clap checks → `-b @` default → existing plan fn → empty target no-op → shared `apply_move` → `has_changes` gate → `finish_verb(tx_description)` → `mutation_result`), the `tx_description` port, and `apply_move` shared with `rebase_is_no_op`; update module doc; inline unit tests for `tx_description` (all five shapes) and the clap refusals.
- `crates/zanshin-jj/src/parallelize.rs` (new) -- module doc (parity tag, ported file); `pub(crate) fn parallelize(workspace, ctx, &[ChangeId])` porting `cmd_parallelize` (targets resolved and ordered children-before-parents by evaluating the revset, `guard_rewritable(needs_rewrite)`, both maps, `transform_descendants`, finish `parallelize <n> commits`).
- `crates/zanshin-jj/src/arrange.rs` (new) -- module doc listing divergences (no TUI; actions by change id; foreign-id refusal); public `ArrangeOptions { revisions: Vec<ChangeId>, actions: Vec<ArrangeAction> }`, `ArrangeAction { SwapDown(ChangeId), SwapUp(ChangeId), Abandon(ChangeId), Keep(ChangeId) }`; private port of `State` (`new`, `swap_commits`, `swap_down`, `swap_up`, `to_rewrite_plan`) and `RewritePlan::execute`; `pub(crate) fn arrange(workspace, ctx, &ArrangeOptions)`; inline unit tests porting the CLI's five State/plan tests.
- `crates/zanshin-jj/src/repo.rs` + `src/lib.rs` -- `#[must_use]` facades `rebase(&RebaseOptions)`, `parallelize(&[ChangeId])`, `arrange(&ArrangeOptions)` → `Result<MutationResult, MutateError>` through `with_verb`, house doc blocks; module declarations + re-exports.
- `schemas/envelope.fbs` + `cargo make codegen` -- `RequestKind` `Rebase`/`Parallelize`/`Arrange`; `RebaseRequest { kind, branch, source, revisions, onto, insert_after, insert_before: [string], skip_emptied, keep_divergent, simplify_parents: bool }`; `enum ArrangeActionKind : byte { SwapDown, SwapUp, Abandon, Keep }`, `table ArrangeAction { kind: ArrangeActionKind; change_id: string }`, `ArrangeRequest { kind, revisions: [string], actions: [ArrangeAction] }`; `zanshin_parallelize` reads `ChangeIdList`; commit the regenerated files.
- `crates/zanshin-ffi/src/rebase.rs` (new) + `lib.rs` -- owned readers (malformed buffer, wrong kind, missing change id → `ffi` codes as the siblings do), `zanshin_rebase`, `zanshin_parallelize`, `zanshin_arrange` via `precondition_envelope` + `ok_mutation_result`; full rustdoc (`# Errors`, `# Safety`).
- `packages/zanshin_core/lib/src/ffi/rebase.dart` (new) + worker/handle/barrel -- request builders, `RebaseCommand`/`ParallelizeCommand`/`ArrangeCommand` before `ShutdownCommand`, worker methods + dispatch arms, `RepoHandle.rebase`/`parallelize`/`arrange` (Dart `RebaseOptions`-style named params, `ArrangeAction` model) behind the close guard with interior-NUL rejection on the calling side.
- `crates/zanshin-jj/tests/it/rebase.rs` (new) -- every jj-level matrix row against jj-lib state: op descriptions verbatim, the four drop forms, `-r` onto descendant allowed, `-b @` default, "No revisions to rebase."/already-in-place no-op keeps the head, refusals keep the head, `skip_emptied`, `simplify_parents`, divergent abandon vs `keep_divergent`, **I1**: `-s A -A B` and `-s A -B C` (and `-b`) on BASE — assert the actual outcome (no-op or the graph), and that `drop_actions` agrees with the verb for every rebase row it offers (verb run after the preview on the same head).
- `crates/zanshin-jj/tests/it/parallelize_arrange.rs` (new) -- parallelize rows (siblings, descendants get both parents, no-op, immutable base allowed vs immutable needing rewrite refused); arrange rows (swap down/up, abandon, ignored swap no-op, empty actions no-op, gaps refusal with hint, empty target, foreign id, `revsets.arrange` default with a config override).
- `crates/zanshin-ffi/tests/it/rebase_ffi.rs` (new) -- readers (absent vs present vectors, malformed buffer, wrong kind, unknown action kind), zero-handle for all three externs, a refusal envelope carrying `jj.invalid_input` (+ hints for arrange gaps), a success envelope.
- `packages/zanshin_core/test/ffi/rebase_test.dart` + `test/worker/rebase_test.dart` (new) -- synthetic request/decoding + NUL guards; real-cdylib round trips calling all three externs (one success each, one refusal), with the extern-fn-guard header paragraph.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- scenarios: `rebase -s C -o A`, `-r B -o root()`, `-r B -o C` (onto descendant), `-r C -A A`, `-r C -B B`, default `-b @ -o A`, `-b A -o B` (no-op), `-s A -o B` refused, `-r A -o A` refused, `--skip-emptied`, `--simplify-parents`, I1 `-s A -A B` and `-s A -B C`; `parallelize B C`, `parallelize B` (no-op). Arrange has no oracle scenario (the CLI's arrange is TUI-only) — record that in the scenario file comment.
- `crates/zanshin-jj/tests/it/api_stability.rs` -- `rebase_parallelize_arrange_surface_resolves`: new types field by field, the three `Repo` methods as `fn` pointers; header type count updated.
- `docs/ffi-abi.md` + `docs/rust-error-codes.md` -- three symbol rows, request tables, "also emitted — Story 9.16" clauses.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-16-rebase-parallelize-arrange` to `done` with a summary comment in sibling style (bump `last_updated`); mark the I1 item (section "Surfaced 2026-09-21 while designing commit drag-and-drop") resolved with the commit and the settled answer; add a `## Surfaced in Story 9.16 (bmad-build-auto, 2026-10-23)` section mirroring any `deferred:` entry of this spec.

**Acceptance Criteria:**
- Given the three verbs exist, when a Dart caller reaches them, then the whole chain is present (`.fbs` tables, zanshin-jj verb, `extern "C"`, committed codegen, adapter, `WorkerCommand`, worker method, `RepoHandle` method) and `ffi_abi_doc_sync` passes with 78 exports.
- Given every parity scenario above, when the oracle runs, then each matches the pinned CLI on every compared aspect or diverges only through a ledgered entry with reason and reference.
- Given a `drop_actions` rebase row answered Available or NoOp on a head, when the rebase verb runs the same form on that head, then it writes an operation exactly when the row said Available, and refuses with the row's refusal when it said Refused.
- Given I1 (`-s`/`-b` with `-A`/`-B` and the target inside the moved set), when the verb runs, then its outcome equals the CLI's (oracle) and is pinned by a zanshin-jj test; the deferred-work item is marked resolved with that answer.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged and `new_op_id` equals the pre-call head (zanshin-jj and FFI layers).
- Given the targeted checks of this run's gate rule, then each passes (see Verification), and `git status --porcelain` is clean at the end with every commit carrying the required co-author trailer.

## Spec Change Log

## Review Triage Log

### 2026-10-23 — Review pass
- verdicts: 27 findings — high 0, medium 6, low 16, false 5, maybe-false 0
- findings:
  - `[low]` `[defer]` (blind) the regenerated `zanshin_ffi.h` lost four `Table_VT_*` defines (`GitPushRequest_VT_REVISIONS`, `RepoCloneRequest_VT_SOURCE`, `DropActionsRequest_VT_CHANGE_ID`, `DropActions_VT_ACTIONS`) and the new tables come out partial — real (`git diff 7f6d75b -- crates/zanshin-ffi/include/zanshin_ffi.h`), but pre-existing generator behaviour: cbindgen keeps each bare `VT_*` name once across all tables (the baseline header already holds a single `_VT_KIND`); no C/Dart/Rust consumer reads these defines (FlatBuffers code is generated separately). Deferred and mirrored to deferred-work.md.
  - `[medium]` `[patch]` (blind) `ArrangeActionKind` had no `Unspecified = 0`, so an absent `kind` decoded as `SwapDown` — fixed: `Unspecified` first member, the reader refuses it, reader test added.
  - `[medium]` `[patch]` (blind) I1 "settled" only on linear BASE where every case is a no-op; no relocating case, no `-b` oracle — fixed: zanshin-jj test + oracle scenarios with a merge outside the moved set, `-b` I1 oracle scenarios, deferred-work wording corrected (per-commit external ancestors/descendants).
  - `[low]` `[patch]` (blind) deferred-work I1 resolution carries "commit: this story's" — filled with the real hash in the finalisation commit.
  - `[low]` `[reject]` (blind) `arrange` cannot name a divergent change — the whole verb surface addresses commits by change id and refuses a divergent one (`resolve_ordered`/`resolve_commit`, as `split`/`squash`/`rebase`); an id-by-commit variant would add public surface for a rare case.
  - `[low]` `[patch]` (blind) arrange's bookmark effects untested (no oracle for arrange) — fixed: `b-mark` asserted after abandoning and swapping B.
  - `[medium]` `[patch]` (blind) the three rebase booleans never shown to leave Dart — fixed: `skipEmptied` worker round trip asserting `abandonedChangeIds`; distinct-valued Rust reader test.
  - `[low]` `[patch]` (blind) oracle covers only the simple paths — fixed in part: `parallelize A B` (outside child becomes a merge) and a rebase immutable refusal scenario; the divergent abandon stays covered by `a_divergent_twin_already_in_the_destination_is_abandoned_unless_kept` (a CLI-side divergence setup costs more than it adds); `-s B -o A` is the same no-op path as the listed `-b A -o B`.
  - `[low]` `[reject]` (blind) the preview-equals-verb test explores linear BASE only — both sides call the same plan fns and `apply_move` by construction; more graph shapes would multiply a test that already takes ~30 s.
  - `[false]` `[reject]` (blind) the "Nothing changed." gate is duplicated before `finish_verb` — not a defect: `squash`/`split` use the same explicit `no_op_result` early return (squash_split.rs:416-419); both paths return the base head.
  - `[low]` `[reject]` (blind) emptied commits in `abandoned_change_ids` are ordered by commit id — the order is stable and deterministic; a topological order would need an extra revset walk for no consumer that relies on order.
  - `[low]` `[patch]` (blind) test hygiene (wrong comment, misleading test name, Immutable refusals without the commit asserted) — fixed: comment, rename, `commit_id` asserts.
  - `[false]` `[reject]` (blind) sprint-status says done while the spec is in-review — the finalisation commit sets both together.
  - `[low]` `[reject]` (edge) empty target with non-empty actions is a silent no-op — the CLI answers "No revisions to arrange." before any TUI exists, so the actions have nothing to act on; refusing first would put a Zanshin refusal ahead of the CLI's answer.
  - `[low]` `[reject]` (edge) divergent targets cannot be named by an action — same as the blind divergent row.
  - `[low]` `[patch]` (edge) `abandoned_change_ids` names a divergent twin whose change id stays visible — the list is the spec's (jj-lib's abandonments); fixed the doc to say the twin's change id stays visible on the surviving commit.
  - `[low]` `[defer]` (edge) header `VT_*` defines lost — same as the blind header row.
  - `[medium]` `[patch]` (verification-gap) rebase flags not verified Dart→Rust — same as the blind flags row.
  - `[medium]` `[patch]` (verification-gap) `branch` not verified Dart→Rust — fixed: worker round trip with `branch` ≠ `@` asserting the moved root; reader test sets a non-empty branch.
  - `[medium]` `[patch]` (verification-gap) arrange SwapDown/SwapUp/Keep mapping unpinned in Dart — fixed: single-action round trips whose outcomes differ by kind.
  - `[low]` `[defer]` (verification-gap, other) header `VT_*` defines lost — same as the blind header row.
  - `[low]` `[patch]` (intent) I1 shown only on the no-op outcome — same as the blind I1 row.
  - `[low]` `[patch]` (intent) `-b` I1 cases have no oracle scenario — same as the blind I1 row.
  - `[false]` `[reject]` (intent) the preview does not answer the I1 forms — epics.md Story 9.16's design update 2026-10-14 gives `-s`/`-b` with `-A`/`-B` no UI and takes the corner off the UI path; `drop_actions` offers no such row, so there is nothing to mirror.
  - `[false]` `[reject]` (intent) no Auto Run Result / recorded verification outcomes — written at finalisation of this run.
  - `[low]` `[patch]` (intent) the "Surfaced in Story 9.16" section holds only a "Nothing deferred" line — replaced by the mirrored deferral at finalisation.
  - `[false]` `[reject]` (intent) sprint-status claims oracle results before the spec records them — the claims are true (oracle run green, 228 tests) and recorded under Verification at finalisation.

### 2026-10-23 — Review pass (follow-up)
- verdicts: 33 findings — high 0, medium 2, low 21, false 10, maybe-false 0
- findings:
  - `[low]` `[reject]` (blind) clap-rule refusals run after the pre-verb snapshot, so a clap-invalid call on a dirty working copy writes a snapshot operation the CLI would not — real (`check_rebase_args` runs inside `with_verb`, `rebase.rs:383`), but it is the house pattern of `squash`/`split` (`squash_split.rs:241-251`, also inside the verb), the GUI builds its requests from valid forms, and the snapshot is one the next call writes anyway; hoisting the check before `with_verb` must also clear `pending_warnings` / the precondition report by hand — added state handling for a case nobody meets in everyday use.
  - `[low]` `[reject]` (blind) the `-b @` default in a workspace with no working-copy commit answers `jj.jj_lib_error` rather than a user error — real (`op_support.rs:782` `ResolveError::Backend`), but `squash`/`split`'s `resolve_or_wc(None)` answer the same; it needs a workspace forgotten from another one, and a dedicated mapping adds a branch and an error variant to the verb's contract.
  - `[low]` `[reject]` (blind) arrange skips validating actions when the target set is empty — carried: same claim as the first pass's edge row (CLI answers "No revisions to arrange." before any TUI exists).
  - `[low]` `[patch]` (blind) no oracle scenario covers divergent-twin abandonment / `--keep-divergent` — carried: same claim as the first pass's "oracle covers only the simple paths" row (divergent abandon stays covered by the jj-level test).
  - `[low]` `[patch]` (blind) the I1 `-s B -B M` relocation was never compared with the CLI — fixed: oracle scenario `rebase_i1_source_insert_before_merge` (matches the CLI).
  - `[low]` `[patch]` (blind) repeated flags, plural op descriptions and a multi-`onto` merge are untested against the CLI — fixed: oracle scenarios `rebase_several_revisions` (`-r B -r C`), `rebase_several_sources` (`-s C -s X`), `rebase_onto_two_parents` (`-s C -o B -o X`), all matching the CLI.
  - `[low]` `[reject]` (blind) the "was `@` abandoned → its replacement" block is repeated in `squash_split.rs`, `rebase.rs`, `arrange.rs` (and a variant in `mutate.rs` abandon) — six lines per verb, each next to its own abandonment source; a shared helper means editing two pre-existing verbs outside this story for no behavioural change.
  - `[low]` `[patch]` (blind) `rebase_ffi.rs::rebase_moves_a_source_onto_a_target` compared the head description with itself — fixed: asserts `rebase commit <C's full hex> and descendants`.
  - `[medium]` `[patch]` (blind) the Dart round trip never observes `keepDivergent` / `simplifyParents` — fixed in part: `simplify_parents_crosses_the_buffer` (M = merge(C, B), `-s A -o X` → M's parents `[C]`); `keepDivergent` needs a divergent commit the Dart API cannot make → deferred (mirrored to deferred-work.md).
  - `[low]` `[reject]` (blind) the FFI / Dart error lists omit `jj.not_a_git_repo` — the new rows match every sibling mutation row (`zanshin_squash`, `docs/ffi-abi.md:583`), and the code needs a colocated workspace without a Git backend, which a real repo cannot be.
  - `[low]` `[patch]` (blind) `arrange_defaults_to_revsets_arrange`'s `revsets.arrange = "@"` case asserted only `InvalidInput` — fixed: compares the reason "<A> is not among the revisions to arrange".
  - `[low]` `[defer]` (blind) the regenerated header drops `Table_VT_*` defines — carried: same as the first pass's deferred header row.
  - `[low]` `[reject]` (blind) the drop_actions/verb agreement test covers linear BASE only — carried: same as the first pass's rejected row.
  - `[low]` `[patch]` (blind) `abandoned_change_ids` can name a change still visible through a divergent twin — carried: same as the first pass's edge row (documented on `MutationResult`).
  - `[false]` `[reject]` (blind) the sprint-status / deferred-work entries re-embed their history after "Was:" — that is the files' sibling style (18 "Was:" entries in sprint-status.yaml, 5 in deferred-work.md).
  - `[low]` `[reject]` (edge) clap-invalid options on a dirty working copy write a snapshot operation — same as the blind clap-snapshot row.
  - `[low]` `[reject]` (edge) a divergent arrange target cannot be named by an action — carried: same as the first pass's divergent rows.
  - `[false]` `[reject]` (edge) the spec's `ArrangeActionKind` lacks the code's `Unspecified = 0` — the code is the first pass's deliberate fix (absent kind ≠ `SwapDown`); every client is generated from the `.fbs`, and the only fix would edit this spec.
  - `[false]` `[reject]` (edge) a missing `change_id` answers `jj.invalid_input`, not an `ffi` code — that is what the siblings do: `envelope.rs:617` `missing_field` is `JJ_INVALID_INPUT`, used by 11 other FFI modules.
  - `[false]` `[reject]` (edge) on a dirty working copy a refusal or no-op reports a head other than the pre-call one — the CLI snapshots before every non-clap refusal and before "No revisions to rebase." / "Nothing changed." too, so the post-snapshot head is the CLI's; only the clap case differs (rejected above).
  - `[medium]` `[patch]` (verification-gap) `keepDivergent` / `simplifyParents` not verified Dart→Rust — same as the blind Dart-flags row (fixed in part, `keepDivergent` deferred).
  - `[low]` `[reject]` (intent) arrange's effects are compared with the port's expectations, never the CLI's — the CLI's arrange is TUI-only (crossterm raw mode) and cannot run headless; the ported CLI unit tests are the available CLI evidence.
  - `[low]` `[patch]` (intent) the matrix's `-s` onto itself is oracle-checked only as `-r A -o A` — fixed: oracle scenario `rebase_source_onto_itself_refused` (matches the CLI).
  - `[low]` `[reject]` (intent) "already in place" `-s B -o A` has no oracle scenario — carried: the first pass noted it is the same no-op path as the oracle's `-b A -o B`.
  - `[low]` `[patch]` (intent) `keep_divergent` has no oracle scenario — carried: same as the blind divergent-oracle row.
  - `[low]` `[patch]` (intent) `compute_commit_location`'s loop refusal has no rebase witness — fixed: oracle scenario `rebase_insert_loop_refused` (`-r C -A B -B A`, refused as the CLI refuses).
  - `[false]` `[reject]` (intent) the clap rows use house-style text — the intent prescribes `MutateError::InvalidInput` naming the flags; clap's own text is terminal UX with nothing to compare.
  - `[false]` `[reject]` (intent) preview/verb agreement is shown for default flags only — `drop_actions` rows carry no flags, so default flags are the only preview there is.
  - `[false]` `[reject]` (intent) the `-b @` default calls `plan_rebase_branch_ids`, not `plan_rebase_branch` — `plan_rebase_branch` resolves its ids and delegates to `plan_rebase_branch_ids`; same behaviour, and the oracle's `rebase_default_branch*` match the CLI.
  - `[false]` `[reject]` (intent) `MutationResult` fields are checked in Zanshin only — the CLI has no counterpart; the intent defines them.
  - `[low]` `[defer]` (intent) the header regeneration removed unrelated defines — carried: same as the deferred header row.
  - `[false]` `[reject]` (intent) `ChangeIdList` gained a third reader instead of a new table — the spec's Code Map prescribes it; the intent is silent and the reuse has no harm.
  - `[false]` `[reject]` (intent) I1 bookkeeping — the diff matches the intent's Never list (`drop_actions` unchanged) and records I1 resolved; no divergence.

## Design Notes

- **Arrange's headless plan = the TUI's key actions.** The CLI's TUI can only swap a commit with its single parent/child and toggle abandon/keep; `c` confirms the resulting `State`. Replaying those actions (by change id instead of cursor position) on a port of `State` reaches exactly the CLI's reachable states and needs no cycle or set validation beyond "the id is a target". A free-form "new parents per commit" plan would accept graphs the CLI can never produce. The facade is `Repo::arrange` (house naming after the CLI verb); it is the epic's "headless `arrange_apply(plan)`".
- **One move fn.** `rebase_is_no_op` already applies the CLI's move on a dry-run head; the verb applies the same fn on the real head with the user's flags, so preview and verb cannot drift. Example: `-s B -o A` on BASE → preview NoOp, verb writes nothing.
- **No arrange oracle.** `jj arrange` needs a terminal (crossterm raw mode); the port's correctness rests on the ported CLI unit tests and jj-level tests.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`; targeted checks only.

**Commands:**
- `cargo make codegen` -- expected: regenerated files committed, no further diff.
- `cargo test -p zanshin-jj --lib rebase:: arrange:: parallelize::` and `cargo test -p zanshin-jj --test it rebase:: parallelize_arrange:: drop_actions:: api_stability::` -- expected: pass.
- `cargo test -p zanshin-ffi --test it rebase_ffi:: ffi_abi_doc_sync::` (+ `cargo test -p zanshin-ffi --lib`) -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` and `cargo fmt --all --check` -- expected: clean.
- `flutter test` (or `dart test`) for the new `packages/zanshin_core` tests, `dart analyze packages/zanshin_core`, `dart format --set-exit-if-changed packages/zanshin_core` -- expected: pass/clean.

**Outcomes (2026-10-23, final tree after the review patches; full gate not run per the run's gate rule):**
- `cargo make codegen` -- exit 0; a second run left the tree unchanged.
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --lib` -- 318 passed. `cargo test -p zanshin-jj --test it -- rebase:: parallelize_arrange:: drop_actions:: api_stability:: mutate::` -- 112 passed.
- `cargo test -p zanshin-ffi --lib` -- 199 passed. `cargo test -p zanshin-ffi --test it -- rebase_ffi:: ffi_abi_doc_sync:: repo_write_ffi:: drop_actions_ffi::` -- 69 passed.
- `cargo test -p zanshin-parity --test oracle` -- 233 passed (21 new Story 9.16 scenarios, no ledger entry).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `dart test test/ffi/rebase_test.dart test/worker/rebase_test.dart test/ffi/warning_test.dart test/worker/squash_split_test.dart test/worker/mutate_test.dart` -- 221 passed (real cdylib).
- Not run (gate rule): `cargo make test`, `test-full`, `coverage` — the story loop runs the gate once at its end.

**Outcomes of the follow-up review pass (2026-10-23; tests only, no production code changed; full gate not run per the run's gate rule):**
- `cargo test -p zanshin-parity --test oracle` -- 239 passed (6 new scenarios: `rebase_i1_source_insert_before_merge`, `rebase_source_onto_itself_refused`, `rebase_several_revisions`, `rebase_several_sources`, `rebase_onto_two_parents`, `rebase_insert_loop_refused`; no ledger entry).
- `cargo test -p zanshin-jj --test it -- parallelize_arrange::` -- 13 passed.
- `cargo test -p zanshin-ffi --test it -- rebase_ffi::` -- 7 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean. `cargo fmt --all --check` -- clean.
- `packages/zanshin_core`: `dart format --set-exit-if-changed lib test` -- 0 changed; `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart test test/ffi/rebase_test.dart test/worker/rebase_test.dart` (test-core env) -- 18 passed (real cdylib).
- `cargo make codegen` not needed: no FFI or schema change.

## Auto Run Result

Status: done

**Summary.** `jj rebase`, `jj parallelize` and the non-TUI half of `jj arrange` are ported from the CLI at v0.46.0 and wired end to end (`.fbs` → zanshin-jj → `zanshin_rebase` / `zanshin_parallelize` / `zanshin_arrange` → `RepoHandle.rebase` / `parallelize` / `arrange`, 78 exports). `Repo::rebase` calls 9.31's plan fns and applies the move through one `apply_move` shared with `rebase_is_no_op`, so `drop_actions`' rows and the verb agree (pinned by `every_drop_actions_rebase_row_agrees_with_the_verb`); clap's rules refuse before resolution, `-b @` is the default, and "No revisions to rebase." / "Nothing changed." write no operation. `Repo::parallelize` ports the two-map recompute. `Repo::arrange` takes the TUI's own key actions (swap down/up, abandon, keep) by change id and replays them on a port of the CLI's `State`; `revsets.arrange` is the default target, gaps refuse with the CLI's hint. All three return `MutationResult`; no new error or warning code.

**Items handed to this story.**
- **I1** (`-s`/`-b` with `-A`/`-B` not refused when the target lies inside the moved set) — **fixed** (settled, 1216b77): the verb does what the CLI does — no up-front refusal. jj-lib's `compute_move_commits` replaces an inside new parent by that commit's external ancestors and an inside new child by its external descendants: on a linear history every case is "Nothing changed." (or "No revisions to rebase." for `-b A -B C`), and it relocates when the inside target has a parent outside the moved set (`-s B -A M`, M = merge(C, X) → B onto merge(A, X)). Pinned by `tests/it/rebase.rs::i1_*` and oracle scenarios `rebase_i1_source_insert_after`, `rebase_i1_source_insert_before`, `rebase_i1_source_insert_after_merge`, `rebase_i1_branch_insert_after`, `rebase_i1_branch_insert_before`, all matching the CLI. The "preview mirrors" half needs nothing: `drop_actions` offers no `-s`/`-b` row at `-A`/`-B` (epics.md 9.16 design update 2026-10-14). Marked resolved in deferred-work.md with the commit.

**Files changed (1216b77).**
- `crates/zanshin-jj/src/rebase.rs` — `RebaseOptions`, the verb, `apply_move`, `tx_description`, clap checks.
- `crates/zanshin-jj/src/parallelize.rs` (new) — `cmd_parallelize` port.
- `crates/zanshin-jj/src/arrange.rs` (new) — `ArrangeOptions`/`ArrangeAction`, `State`/`RewritePlan` port, the verb, the CLI's five unit tests.
- `crates/zanshin-jj/src/{repo,lib,mutate}.rs` — facades, re-exports, `MutationResult` docs.
- `schemas/envelope.fbs` + generated files — `RequestKind` Rebase/Parallelize/Arrange, `RebaseRequest`, `ArrangeRequest`, `ArrangeAction`, `ArrangeActionKind` (with `Unspecified`).
- `crates/zanshin-ffi/src/rebase.rs` (new), `lib.rs`, `repo.rs` — readers + three externs.
- `packages/zanshin_core/lib/src/ffi/rebase.dart` (new), worker `commands`/`isolate`/`handle`, barrel — Dart surface.
- Tests: `crates/zanshin-jj/tests/it/{rebase,parallelize_arrange,api_stability}.rs`, `crates/zanshin-ffi/tests/it/rebase_ffi.rs`, `packages/zanshin_core/test/{ffi,worker}/rebase_test.dart`, oracle `scenarios.rs`/`main.rs` (21 scenarios; arrange has none — the CLI's arrange is TUI-only).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`.
- Ledger (finalisation commit): this spec, `sprint-status.yaml` (9-16 done), `deferred-work.md` (I1 resolved, Story 9.16 section).

**Review findings.** 27 findings (medium 6, low 16, false 5). Patched (in 1216b77): `ArrangeActionKind` absent kind (medium), I1 relocating case + `-b` oracle (medium), rebase flags and `branch` across Dart→Rust (medium ×2), arrange action-kind mapping (medium), arrange bookmark asserts, parallelize/immutable oracle scenarios, test hygiene, divergent-twin doc (low). Deferred (mirrored to deferred-work.md): the cbindgen header's lost `Table_VT_*` defines (low, pre-existing generator behaviour). Rejected: divergent change ids in arrange (house change-id API), drop_actions agreement beyond linear BASE (same fns by construction), duplicated no-op gate (squash/split pattern), emptied-commit order (stable, no consumer), silent no-op for actions on an empty target (CLI answers before any TUI), preview for the I1 forms (no UI by the 2026-10-14 design update), and three bookkeeping rows settled by this finalisation.

**Follow-up review recommendation: true.** Patched at entry verdict: high 0, medium 5, low 4. Unverified risk: the review patches were checked only by the targeted runs above — per-file coverage of the four new files (`arrange.rs`, `parallelize.rs`, `zanshin-ffi/src/rebase.rs`, and the extern-fn guard for the three new externs) is unmeasured until the story loop's final gate; the never-firing "cycle detected" closure in `arrange.rs` is the line most likely to stay uncovered.

**Residual risks.** Coverage ratchet not run (gate rule). `jj arrange` has no parity oracle (TUI-only in the CLI); its correctness rests on the ported CLI unit tests and jj-level tests. The `every_drop_actions_rebase_row_agrees_with_the_verb` test takes ~30 s.

### Follow-up review pass (2026-10-23)

Status: done

**Summary.** A fresh four-layer review of the finished story (diff since `7f6d75b`). No production code changed; the pass added tests only.

**Files changed.**
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` — six new rebase scenarios (`-s B -B M` I1 relocation, `-s A -o A`, `-r B -r C`, `-s C -s X`, `-s C -o B -o X`, the `-A`/`-B` loop refusal); scenario count 219 → 225.
- `crates/zanshin-ffi/tests/it/rebase_ffi.rs` — the success test asserts the exact operation description.
- `crates/zanshin-jj/tests/it/parallelize_arrange.rs` — the `revsets.arrange = "@"` refusal asserts its reason.
- `packages/zanshin_core/test/worker/rebase_test.dart` — `simplify_parents_crosses_the_buffer`.
- This spec and `deferred-work.md` (one mirrored deferral).

**Review findings.** 33 findings: medium 2, low 21, false 10. Patched: the Dart `simplifyParents` round trip (medium; the same root cause came from two layers), the I1 `-B` relocation oracle, the repeated-flag and multi-`onto` oracles, the `-s` onto-itself oracle, the loop-refusal oracle, the vacuous FFI description assertion, and the reason-less arrange assertion (low). Deferred: the Dart `keepDivergent` round trip (low; needs a divergent commit the Dart API cannot make). Rejected:
- The clap refusals run after the snapshot (two layers). Squash and split do the same; the GUI sends valid forms; a fix needs hand-cleared per-call state.
- `-b @` with no working-copy commit answers `jj.jj_lib_error`, as squash and split do. It needs a forgotten workspace.
- The repeated "`@` abandoned" block. Extracting it would touch two pre-existing verbs.
- `jj.not_a_git_repo` is not listed in the new error rows, as in every sibling row. A real repo cannot reach it.
- arrange has no CLI comparison. The CLI's arrange is TUI-only.
- Ten false findings, and the rows carried from the first pass.

**Follow-up review recommendation: false.** This was a follow-up pass and patched no `high` finding. Patched at entry verdict: high 0, medium 1, low 6.

**Residual risks.** The coverage ratchet was not run (gate rule). `keepDivergent`'s Dart half has no observing test (deferred). The clap refusals still follow a snapshot on a dirty working copy; this is rejected as the house pattern.
