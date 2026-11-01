---
title: 'Story 9.23: `workspace add`, `workspace update-stale` (+ the `snapshot.auto-update-stale` arm)'
type: 'feature'
created: '2026-10-19'
status: 'done'
baseline_revision: '94b37ea58a77a53ffdd30284b4ffa0a11c5d4d31'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [multiple-goals, oversized]
deferred:
  - summary: >-
      The StaleNotice's "Update working copy" action, its no-Undo rule and the error toast with Retry (epics 9.23 items 3, 4 and 6) wait for Story 10.5, which builds the StaleNotice; Story 9.23 ships only the wire (RepoHandle.workspaceUpdateStale and its StaleRecovery result).
    evidence: |-
      app/lib has only the shell's empty `staleNotice: Widget?` slot (app/lib/src/features/shell/floating_shell.dart:75) and a widgetbook placeholder (app/widgetbook/folders/shell.dart:167-169); sprint-status 10-5-graph-view-model-repo-wiring is backlog, and epics 9.23 item 6 says 10.5 owns the notice.
    location: >-
      app/lib/src/features/shell/floating_shell.dart (staleNotice slot); Story 10.5
    severity: low
    resolved: >-
      2026-11-01 — fixed (10.5 commit 5d5548c, 10.23 commit e2da414, spec-10-12-adopt-backend-layout commit 6b9feacb): the notice, its result toast and the error toast with Retry now reach the project window.
  - summary: >-
      snapshot_locked's error arm still reloads the head with jj-lib's load_at_head, so a reconcile operation written on that path carries no workspace name (pre-existing; the other head loads moved to snapshot::load_head in 9.23).
    evidence: |-
      crates/zanshin-jj/src/snapshot.rs snapshot_locked failure path calls repo_loader().load_at_head(); jj-lib's load_at_head merges divergent heads without a workspace name, while the CLI's resolve_operation (cli_util.rs:800-829 @ v0.46.0) names it. Observable only with divergent op heads at that moment.
    location: >-
      crates/zanshin-jj/src/snapshot.rs (snapshot_locked error arm)
    severity: low
    resolved: >-
      2026-10-19 — fixed (spec-9-23-closing-snapshot-error-arm-head-reload, commit bbeb79a): the error arm only reads the op heads and writes nothing, like the CLI (cli_util.rs:498 @ v0.46.0); the next head load reconciles under the workspace's name.
  - summary: >-
      No verb warns "There are unresolved conflicts at these paths" after checking out a conflicted @, which the CLI's print_updated_working_copy_stats does; the stale recovery inherits the gap.
    evidence: |-
      cli_util.rs:2297-2331 @ v0.46.0 writes the warning when new_commit.has_conflict(); zanshin-jj WarningKind has no such kind, and mutate::finish_transaction / stale::recover_at emit only checkout_files_skipped. Pre-existing across all checkout verbs.
    location: >-
      crates/zanshin-jj/src/mutate.rs finish_transaction; crates/zanshin-jj/src/stale.rs recover_at
    severity: low
    resolved: >-
      2026-10-20 — fixed (spec-9-53-parity-cleanup-after-2026-10-19-loop, commit 56f5868): new jj.unresolved_conflicts warning after a checkout onto a conflicted @, from finish_transaction and stale::recover_at.
  - summary: >-
      About 50 in-verb head reloads still call jj-lib's load_at_head(), which writes an unnamed "reconcile divergent operations" when heads diverge between the pre-verb snapshot and the verb; the CLI names the workspace on every reconcile.
    evidence: |-
      grep -rc "load_at_head()" crates/zanshin-jj/src: mutate.rs (8), view.rs, file.rs, squash_split.rs, commit_views.rs (3 each), status.rs, bookmark_ops.rs, git.rs, ...; Story 9.23 moved only the precondition, the recovery and workspace_add to snapshot::load_head (CLI resolve_operation, cli_util.rs:807-829 @ v0.46.0). Pre-existing; needs a concurrent writer.
    location: >-
      crates/zanshin-jj/src (in-verb load_at_head call sites)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin cannot leave a stale working copy: every snapshotting call refuses with `jj.stale_working_copy`, `snapshot.auto-update-stale = true` is read but still refuses (`repo.rs:313-323`, pinned by `tests/snapshot_precondition.rs::auto_update_stale_still_refuses_until_the_recovery_lands`), and there is no `jj workspace update-stale`. With several workspaces this is the normal case (epics 9.23 item 1). Zanshin also cannot create a second workspace (`jj workspace add`); only the test helper `test_helpers::add_workspace` does.

**Approach:** Port, step for step at jj **v0.46.0**, `cmd_workspace_update_stale` / `recover_stale_working_copy_impl` (incl. the colocated `reset git head` op, the lost-operation recovery commit, both snapshots), the implicit recovery of `workspace_helper_with_stats` when `snapshot.auto-update-stale = true`, and `cmd_workspace_add` (incl. `--colocate`/`--no-colocate` → `git::create_worktree`). Surface both verbs through the usual chain (`.fbs` → `zanshin-jj` → `extern "C"` → `RepoHandle`), prove them with 9.47 oracle scenarios, and close deferred items I1–I3. Ralph's rule holds: a user switching between the `jj` CLI and Zanshin must not be able to tell which wrote an operation or a file.

## Boundaries & Constraints

**Always:**
- Behaviour = the CLI's at **v0.46.0** (`git -C ../jj show v0.46.0:<path>`): step order, refusals and their order, op descriptions byte-identical (`add workspace '<name>'` — written by jj-lib itself —, `create initial working-copy commit in workspace <name.as_symbol()>`, `reset git head`, `snapshot working copy`, `recovery commit`, `reconcile divergent operations`, `import git head`/`import git refs`), every on-disk effect (`.jj/repo` file, workspace store, sparse patterns, `.jj/.gitignore`, Git worktree, per-workspace Git HEAD + index). Terminal text is not ported; every fact it prints rides typed fields, every `ui.warning_*` a 9.32 warning code.
- **update-stale** = `recover_stale_working_copy_impl` (`cli_util.rs:626-766`): load at the working copy's OWN operation → snapshot there (no git imports at this stage) → head load (the same head-load path `snapshot::run` uses) → `check_stale` → Fresh/Updated: "not stale"; Stale/Sibling: colocated → `try_reset_git_head` in its own transaction, committed as `reset git head` only `if has_changes()`; then the concurrent-tree check ("Concurrent working copy operation. Try again.") → `check_out` → `finish` at the reset op or head (NO op of its own in the plain case) → then `snapshot_impl` again; stats of both snapshots merged. Missing wc operation (`ObjectNotFound`) → `create_and_check_out_recovery_commit` (jj-lib's own `recovery commit` op, the CLI's description text verbatim from `cli_util.rs:1544-1551`) → `snapshot_impl`. It never runs the pre-verb precondition (it is the recovery).
- **auto arm:** inside the precondition, under the SAME git import/export lock `snapshot::run` holds (`cli_util.rs:493-511`): on any `StaleWorkingCopy`, read `snapshot.auto-update-stale` there (only there — a wrong type stays a config fault only on a stale working copy); `false` → refuse as today; `true` → run the same recovery and let the verb continue on the recovered state. The convert path's `maybe_snapshot` never recovers (`cli_util.rs:1359-1370`).
- **workspace add** = `cmd_workspace_add` (`add.rs:110-280`): the pre-verb precondition on the CURRENT workspace (`with_verb`) → destination = workspace root joined with `destination` (the 9.22 cwd convention; absolute stays absolute) → name (`name` or the destination's final component) → refuse empty name → refuse an existing name → create the directory (`fs::create_dir`) or refuse a non-empty one / a file → colocate decision (`colocate: Option<bool>`; `None` = current workspace colocated (`wc_ops::is_colocated_git_workspace`) AND `git.colocate`, read only in that case) → `git::create_worktree` with `environment::git_subprocess_options` → `Workspace::init_workspace_with_existing_repo` → no-separator warning → colocated new workspace: `.jj/.gitignore` = `/*\n` (reuse `convert.rs::maybe_add_gitignore`) → sparse `Copy` (default) / `Full` / `Empty` via the locked new working copy → transaction on the NEW workspace (`start_repo_transaction`, new name): parents = old `@`'s parents (root when none) or the ordered, deduplicated union of `revisions` evaluated in the OLD workspace's context ("Empty revision set" when empty) → `merge_commit_trees` → description = `join_message_paragraphs` → `edit` → `finish_transaction` on the NEW `Workspace` with ITS colocated flag (checkout into the new directory, Git HEAD reset, export, warnings).
- Pass CLI parameters through (FR-JJ-17): `destination`, `name: Option`, `revisions` (revset strings, CLI `-r`), `message_paragraphs` (CLI `-m`), `colocate: Option<bool>` (wire: the two CLI flags; both set → `jj.invalid_input`), `sparse_patterns` (enum, default `Copy`). `git.colocate = true` joins `BUILTIN_CONFIG_TOML` verbatim from CLI `misc.toml:27-28`.
- Refusals: empty name / no final component / empty revision set / both colocate flags → `jj.invalid_input`; existing name → new `jj.workspace_exists` (name in context); non-empty destination or a file → new `jj.destination_not_empty`; `GitCreateWorktreeError` → new `jj.git_worktree_failed` (jj-lib text in context); revset faults → the existing revset codes; the rest as today (`jj.concurrent_working_copy`, `jj.no_working_copy`, `jj.config_error`, `jj.stale_working_copy`, `jj.jj_lib_error`). Refusals AFTER the workspace exists (bad `revisions`, worktree failure after `create_dir`) leave what the CLI leaves.
- Results: `WorkspaceAddResult { mutation (new op = the create-initial op; `working_copy_change_id` = the NEW workspace's `@`), workspace_name, workspace_root, git_worktree_created, checkout: CheckoutStats }`; `StaleRecovery { outcome: NotStale|Updated|Recovered, commit_id: Option (fresh `@` / recovery commit, full hex), checkout: Option<CheckoutStats>, git_head_reset_op_id: Option, snapshot_stats (merged), op_id (head after the call) }`; `CheckoutStats { added, updated, removed, skipped }` (jj-lib counts, saturating `u32`). `Precondition` gains `stale_recovery: Option<StaleRecovery>` (set by the auto arm). update-stale's envelope `precondition` = its trailing `snapshot_impl` report (the 9.33 convert precedent); the snapshot-stats warnings come from the merged stats.
- Coverage ratchet: new `src/` files ≥ 80 %, no per-file drop, a real-cdylib `zanshin_core` test per new extern fn; `cargo make test` green.

**Never:**
- No `--at-op` / `--ignore-working-copy` / `--no-integrate-operation` (the "must be able to update the working copy" refusals are unreachable). No `templates.commit_trailers` rendering for `-m` — the known gap shared with `describe`/`new` (deferred-work "Surfaced 2026-10-08 … fork jj", which names `workspace add`). No `jj git colocation` (Story 9.45), no `workspace forget/rename/remove` (9.13). No MCP tool.
- No UI widget: the StaleNotice and its "Update working copy" action belong to Story 10.5 (not built); this story ships the wire only.
- No lowering of `coverage-baseline.txt`, no `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| add: default | non-colocated repo, `@` on `p`, `destination="../ws2"` | ops `add workspace 'ws2'` → `create initial working-copy commit in workspace ws2`; `ws2@` = new empty-description commit on `p`; files of `p` on disk in `../ws2`; `.jj/repo` is a file; sparse copied; `workspace_list` shows `ws2` | N/A |
| add: name / revisions / message | `name="x"`; `revisions=["a","b|a"]`; `message_paragraphs=["T","U"]` | workspace `x`; parents `[a,b]` in argument order, deduplicated; description `"T\n\nU\n"` | N/A |
| add: empty revision set | `revisions=["none()"]` | workspace dir + `add workspace` op exist (CLI order), no second op | `jj.invalid_input` "Empty revision set" |
| add: empty name | `name=""` | nothing created | `jj.invalid_input` |
| add: no final component | `destination="x/.."` | nothing created (the CLI panics here) | `jj.invalid_input` |
| add: existing name | `name="default"` | nothing created | `jj.workspace_exists` |
| add: busy destination | non-empty dir, or a file | nothing written | `jj.destination_not_empty` |
| add: inside workspace | `destination="ws2"` (no separator) | created under the workspace root; warning `jj.workspace_in_current_directory` (CLI text) | N/A |
| add: colocated default | colocated repo, `git.colocate` default | Git worktree in the destination (`.git` file), `.jj/.gitignore` = `/*\n`, ws2's Git HEAD = first parent of `ws2@` (`refs/jj/root` when that is root); `git_worktree_created = true` | N/A |
| add: colocate overrides | `colocate=Some(false)` on colocated; `git.colocate=false`; `colocate=Some(true)` on a non-colocated git repo | no worktree; no worktree; worktree | N/A |
| add: native backend + colocate | `init_simple`, `colocate=Some(true)` | directory created first (CLI order) | `jj.git_worktree_failed` |
| add: sparse | old WC sparse `["a"]`; `Full`; `Empty` | copied `["a"]`; `["."]`; `[]` | N/A |
| update-stale: stale, clean | `default@` tree rewritten from ws2 | `Updated`, `commit_id` = new `@`, checkout stats; head op unchanged (no op of its own); WC records the head op | N/A |
| update-stale: stale, dirty | as above + an edited file in default | `snapshot working copy` op (at the WC op) + `reconcile divergent operations`; `Updated` | N/A |
| update-stale: not stale | fresh workspace | `NotStale`, `commit_id` null; no op when clean | N/A |
| update-stale: sibling op | WC finished at an unpublished sibling op | `Updated` | N/A |
| update-stale: lost op | WC at a missing operation | ops `recovery commit` + `snapshot working copy`; `Recovered`, `commit_id` = recovery commit; CLI description verbatim; on-disk files kept | N/A |
| update-stale: colocated | colocated, `@`'s first parent changed elsewhere | `reset git head` op BEFORE the checkout; `git_head_reset_op_id` set; Git HEAD = new parent, index reset | N/A |
| update-stale: concurrent tree | stale `@` tree ≠ recorded WC tree | nothing checked out | `jj.concurrent_working_copy` |
| auto arm | `snapshot.auto-update-stale = true`, stale WC, any snapshotting verb (`snapshot`, `status`, …) | recovers, then the verb runs; `precondition.stale_recovery` set | N/A |
| auto arm: wrong type | `= "yes"`, stale WC | refused | `jj.config_error` |
| wire: both flags | `colocate` and `no_colocate` true | nothing done | `jj.invalid_input` |

</intent-contract>

## Code Map

`../jj` anchors are `git -C ../jj show v0.46.0:<path>`; `cu` = `cli/src/cli_util.rs`. jj-lib = `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/`.

**Oracle (read-only)**
- `cli/src/commands/workspace/add.rs:58-109` (args; `--sparse-patterns` default `copy`; `-r` repeatable `Vec<RevisionArg>`), `:110-280` (`cmd_workspace_add`, every step above). `cli/src/commands/workspace/update_stale.rs:31-41` (`recover_stale_working_copy` + `print_snapshot_stats` of the merged stats).
- `cu:473-517` `workspace_helper_with_stats` (auto arm `:497-512`, `get_bool("snapshot.auto-update-stale")` at `:500`, `changed` at `:515`); `cu:615-624` `recover_stale_working_copy` (lock), `:626-766` `_impl` (stale snapshot `:652-655`, head load `:660`, `prepare_working_copy_mutation` `:662`, `check_stale` `:667-673`, "Attempted recovery, but the working copy is not stale." `:674-680`, colocated `reset git head` `:684-706`, `update_stale_working_copy` `:708-714`, "Updated working copy to fresh commit" `:721-725`, `snapshot_impl` again `:733-736`, stats merge `:737-748`, lost op `:751-763`); `:807-829` `resolve_operation` ("reconcile divergent operations"); `:1326-1354` `snapshot_impl`; `:1359-1370` `maybe_snapshot` (no recovery); `:1511-1529` `prepare_working_copy_mutation`/`start_working_copy_mutation`; `:1531-1566` `create_and_check_out_recovery_commit` (DESC `:1544-1551`, "Created and checked out recovery commit" `:1555-1558`); `:1846-1873` `resolve_revsets_ordered`/`resolve_some_revsets`; `:2297-2331` `print_updated_working_copy_stats`; `:2347-2470` `finish_transaction`; `:2730-2754` `try_reset_git_head`; `:3011-3079` `handle_stale_working_copy`; `:3081-3107` `update_stale_working_copy`.
- `cli/src/commands/git/mod.rs:110-123` `maybe_add_gitignore`; `cli/src/git_util.rs:67-77` `is_colocated_git_workspace`; `cli/src/description_util.rs:421-428` `join_message_paragraphs`; `cli/src/config/misc.toml:27-28` (`git.colocate = true`), `:59-62` (`snapshot.auto-update-stale = false`).
- Behaviour to mirror: `cli/tests/test_workspaces.rs` — `test_workspaces_invalid_name` :25, `_add_second_and_third_workspace` :52, `_add_with_message` :128, `_sparse_patterns` :200, `_add_second_workspace_on_merge` :255, `_add_workspace_multiple_revisions` :465, `_add_workspace_in_current_workspace` :567, `_conflicting_edits` :694, `_updated_by_other` :798, `_updated_by_other_automatic` :873, `…_with_changes_in_working_copy_automatic` :946, `_current_op_discarded_by_other` :1046, `_update_stale_noop` :1224, `_unpublished_operation_same_tree` :1256, `_update_stale_snapshot` :1294, `test_colocated_workspace_update_stale` :1338, `test_workspaces_add_forget_colocated` :2404, `_add_colocated_at_revision` :2539, `_add_colocated_unborn_head` :2627; `cli/tests/test_git_colocated.rs:247` `test_git_colocated_update_stale_resets_git_head`.
- jj-lib: `workspace.rs:374-413` `Workspace::init_workspace_with_existing_repo` (async; writes `.jj/repo` as a FILE, publishes `add workspace '<name>'` via a plain transaction — outside the creep guard, as in the CLI); `git.rs:1860-1903` `create_worktree(store, GitSubprocessOptions, dest)` (git ≥ 2.42, HEAD → `refs/jj/root`); `git.rs:1998-2048` `reset_head`; `working_copy.rs:345-401` `WorkingCopyFreshness::check_stale` (a describe-only rewrite stays `Fresh` — make tests change the TREE); `:424-451` `create_and_check_out_recovery_commit`; `repo.rs:809` jj-lib's own reconcile in `load_at_head`.

**zanshin-jj (edit)**
- `src/snapshot.rs` — `run` `:340-369` (holds the lock; the auto arm and the recovery must run inside it, so `run` either recovers there or hands the lock back), `snapshot_locked` `:379-402`, `snapshot_impl`/`snapshot_steps` `:422-457`, `snapshot_working_copy` `:547-583` (private; the stale-snapshot step reuses it on a repo loaded at the WC op), `handle_stale_working_copy` `:716-748` (`StaleCause::{Stale,SiblingOperation,OperationNotFound}`), `Precondition` `:63-103` (add `stale_recovery`; snapshot_stats is ASSIGNED at `:568` — the recovery must merge), `PreconditionError` `:167-195`, `lock_git_import_export` `:243-259`. Citations to re-point (I2): `:7`, `:30`, `:32`, `:132-133`, `:169-170`, `:711`.
- `src/repo.rs` — `precondition` `:293-337` (stale arm `:313-323` reads the knob AFTER the lock is gone — move into `run`), `with_verb`/`with_verb_stats` `:342-358`, `snapshot` `:375`, `take_precondition` `:386`, `list_workspaces` `:1588`, `resolve_workspace_root` `:1620`, `absorb` `:1824` (how a revset argument is parsed for a mutation), `open_reported` `:1994-2010` (root canonicalised so the new workspace's recorded relative path is right). Citations to re-point (I2): `:259`, `:275-276`, `:316-317`.
- `src/mutate.rs` — `finish_transaction` `:605-670` (takes `&mut Workspace` + `FinishCtx`; reuse for the NEW workspace; extend its `Finish` with the `check_out` `CheckoutStats`), `FinishCtx` `:492-500`, `try_reset_git_head` `:521-536`, `finish_verb` `:678-697`, `mutation_result` `:704-722`, `no_op_result` `:975-993`, `lock_working_copy` `:1141-1157` (CLI `start_working_copy_mutation` — use for the sparse step), `commit_with_locked_wc` `:1180-1222`, `MutateError` `:104-310` (add `WorkspaceExists{name}`, `DestinationNotEmpty`, `GitWorktree(String)`), `absorb` `:1375` (`resolve_expression` pattern).
- `src/config.rs` — `BUILTIN_CONFIG_TOML` `:174-212` (add `[git] colocate = true`), `snapshot_auto_update_stale` `:1324-1326` (citation `:1317` → `:500`), reader pattern `:1271-1354`.
- `src/workspace.rs` — the read verbs; module doc `:16-17` names 9.13/9.23 (update). `src/wc_ops.rs:352-361` `is_colocated_git_workspace` (v0.46 port), `project_stats`. `src/convert.rs:417` `maybe_add_gitignore` (make `pub(crate)`, reuse). `src/environment.rs:109-113` `git_subprocess_options`. `src/warning.rs` (`WarningKind` 31 variants; `snapshot_stats` `:363`, `checkout_files_skipped` `:377`). `src/op_support.rs:703-707` `start_repo_transaction`, creep guard `:1259-1281`. `src/lib.rs:62-90` re-exports (no `pub use jj_lib`).
- NEW `src/stale.rs` (recovery + `StaleRecovery`/`StaleRecoveryOutcome`/`CheckoutStats`) and NEW `src/workspace_add.rs` (`SparseInheritance`, `WorkspaceAddResult`, the add port) — the two verbs.

**zanshin-jj tests**
- `tests/snapshot_precondition.rs` — `git_fx`/`init` `:46-66` (internal git, NOT colocated), stale tests `:354-539` (`unpublished_op_with_the_working_copy_at_it` `:471-486` sibling recipe; missing-op recipe `:525-539`; `assert_stale` `:414-420`), I1 pin `:437-449`, citation `:355`.
- `crates/test-helpers/src/lib.rs` — `rewrite_commit_files` `:414` (stale recipe), `add_workspace` `:619-659` (comment `:634-639` calls itself the 9.23 stand-in; canonicalize trap), `TEST_ENV`/`pin_test_env`/`test_settings` `:71-103`. Colocated recipe: `tests/convert.rs:89-120`.
- `tests/api_stability.rs` — `workspace_surface_resolves` `:849-891`, `snapshot_precondition_surface_resolves` `:1010-1070`, WarningKind list + count `:1176-1258`; add a `workspace_add_update_stale_surface_resolves` test.

**Parity oracle** (`crates/zanshin-parity/tests/oracle/`)
- `main.rs:40-67` `parity!` ids + count `:80`; `scenarios.rs:44-58` `Scenario` (`init`, `setup: &[Step]`, `files`, `zanshin`, `cli`, `extra`), multi-workspace example `:336-356`; `driver.rs:66-74` `Step::{Jj,JjAt,Write}`; `harness.rs:36-66`/`state.rs:36-57,288-325` (captures only the DEFAULT workspace's `@`, Git HEAD and files — use `extra` for ws2, the store, `.git`); `compare.rs:16-56`; `ledger.rs` (one entry per accepted divergence, reason + reference + values). Stale recipe: from `../ws2` change `default@`'s TREE (e.g. `restore --into default@` after default recorded a file).

**FFI / wire / bridge (edit)**
- `schemas/envelope.fbs` — header rules `:31-49`, `RequestKind` `:70-102` (append), "For the other 28 tables" `:62`, `WorkspaceRootRequest` `:344`, `MutationResult` `:863-875`, `SnapshotStats` `:1245-1248`, `Precondition` `:1295-1305` (append `stale_recovery`; declare `CheckoutStats`, the outcome enum and `StaleRecovery` before it), `Payload` `:1408-1446` (append), `Envelope` doc `:1472-1482`.
- `crates/zanshin-ffi/src/workspace.rs` — `map_workspace_err` `:38`, reader `:72`, builders `:92,:121`, `zanshin_workspace_list` `:160` (handle-only template), `zanshin_workspace_root` `:214`; `file_ops.rs:56-231` (request reader + `precondition_envelope` template, `build_snapshot_stats` `:94`); `envelope.rs` (codes `:19-149`, `warning_code` `:273`, `CallReport` `:344`, `map_precondition_err` `:378-395`, `precondition_envelope` `:405`, readers `:429-487`, `build_mutation_result` `:579`, `finish_envelope` `:717`); `snapshot.rs:41` `build_precondition`; `repo.rs:112-213` `map_mutate_err`.
- `crates/zanshin-ffi/tests/` — `snapshot_ffi.rs:188-214` (stale envelope), `:419` `ok_row` + `:607-650` (every envelope builder carries the report — add the new payloads), `workspace_ffi.rs`, `ffi_abi_doc_sync.rs` (`EXPECTED_EXPORTS = 61` `:37`).
- `docs/ffi-abi.md` — counters `:39`, `:172`, `:207-209`, `:367`, `:376-377`, `:396`, `:441`; no-precondition lists `:122-123`, `:138-141`; rule `:154-155`; Symbol index rows `:458-519` (workspace rows `:481-482`). `docs/rust-error-codes.md` — table `:35-110` (`jj.stale_working_copy` row `:80` names 9.23 → update), warning table, "Adding a New Code" `:178`.
- `Makefile.toml:497-552` `cargo make codegen` (4 committed outputs), `:745-772` extern-fn coverage guard.
- `packages/zanshin_core` — `lib/src/ffi/workspace.dart` (`zanshinWorkspaceList` `:38`, `zanshinWorkspaceRoot` `:50`, decoders `:107,:138`), `lib/src/ffi/file_ops.dart:35-237` (request adapter + decoder + model template), `lib/src/ffi/precondition.dart` (`decodePreconditionInternal` `:117`, `decodeEnvelopeErrorInternal` `:174`), `lib/src/ffi/warning.dart:46,:158` (`ZanshinWarningCode`), `lib/src/worker/commands.dart:858-1022`, `isolate.dart` (API `:1413-1584`, `send` `:463`, dispatch `:2370-2433`), `handle.dart:921-1086`, barrel `lib/zanshin_core.dart:30-37`; tests `test/worker/workspace_test.dart` (scope note `:14-21` wrongly says add is 9.13), `test/ffi/workspace_test.dart`, `test/ffi/warning_test.dart:356`.
- `app/lib/src/features/projects/project_repos.dart:101` `isStale`, `worker_project_repos.dart:89-112` `read()` (stale → `ProjectStatus.stale`); `app/test/features/projects/worker_project_repos_test.dart` (`:45-48` predicate only; repos via `worker.initRepo` `:70-76`). Real stale recipe: `initRepo` A, write a file, `status()` (A's `@` records it), `workspaceAdd` B, `openRepo(B)`, `B.restore(into: A's change id)` → A reads `stale`; `A.workspaceUpdateStale()` → clean/dirty again.

## Tasks & Acceptance

**Execution** (update-stale first — epics item 1 ships it even if `workspace add` stalls):
- `crates/zanshin-jj/src/config.rs` -- `[git] colocate = true` in `BUILTIN_CONFIG_TOML` (provenance `misc.toml:27-28`), typed reader `git_colocate`; re-point `:1317` -- CLI default, read only when needed.
- `crates/zanshin-jj/src/stale.rs` (NEW) + `snapshot.rs` + `mutate.rs` -- `CheckoutStats`, `StaleRecoveryOutcome`, `StaleRecovery`; the `_impl` port (both arms, colocated `reset git head` via `try_reset_git_head` + `start_repo_transaction` committed only on `has_changes()`, concurrent-tree check, `check_out` + `finish` without an op, recovery commit via jj-lib, trailing `snapshot_impl`, merged stats); `snapshot::run` gains the auto arm under its lock (knob read only on the stale path) and fills `Precondition.stale_recovery`; `Finish` carries the checkout stats; convert's snapshot keeps refusing -- the recovery, one definition for both callers.
- `crates/zanshin-jj/src/repo.rs` -- `pub fn workspace_update_stale(&mut self) -> Result<StaleRecovery, MutateError>` (`refresh_settings`, config, colocated, `CommandEnv`, lock, recovery; trailing snapshot report → `pending_precondition`, warnings → `pending_warnings`); `precondition` no longer reads the knob itself; `pub fn workspace_add(&mut self, destination: &str, name: Option<&str>, revisions: &[String], message_paragraphs: &[String], colocate: Option<bool>, sparse: SparseInheritance) -> Result<WorkspaceAddResult, MutateError>` via `with_verb`; full rustdoc with `# Errors`; re-point `:259`, `:275-276`, `:316-317` -- public surface.
- `crates/zanshin-jj/src/workspace_add.rs` (NEW) + `convert.rs` -- the add port in the CLI's step order (Boundaries); `maybe_add_gitignore` → `pub(crate)`; warning kind `WorkspaceInCurrentDirectory` (CLI text verbatim, `add.rs:184-191`) -- the verb.
- `crates/zanshin-jj/src/{lib.rs,workspace.rs,snapshot.rs,warning.rs}` -- re-exports, module docs (9.13 keeps forget/rename), I2 citations `snapshot.rs:7,:30,:32,:132-133,:169-170,:711` → v0.46.0 anchors (`:473-517`, `:500`, `:3011-3079`, `:615-766`); other v0.44.0 citations stay for 9.46 -- surface + I2.
- `crates/zanshin-jj/tests/snapshot_precondition.rs` -- I1: replace the pin with `auto_update_stale_recovers_a_stale_working_copy` (+ sibling and missing-op auto cases); citation `:355` -- I1.
- `crates/zanshin-jj/tests/workspace_update_stale.rs` + `tests/workspace_add.rs` (NEW) + `tests/api_stability.rs` + inline unit tests -- one witness per matrix row (colocated rows via the `git` CLI recipe; second workspaces via the new verb where possible); `XDG_CONFIG_HOME`/`JJ_*` pinned -- gate.
- `crates/zanshin-parity/tests/oracle/{scenarios.rs,main.rs,ledger.rs}` -- scenarios: add default, add `-r`+`-m`+`--name`, add sparse empty, add colocated (default + `--no-colocate`), update-stale stale→fresh, not-stale, dirty stale, colocated reset git head, auto-update-stale on `util snapshot`; `extra` captures ws2 (`.jj/repo`, files, `@` parents, `.git`, Git HEAD) and the WC operation; ledger only genuine, reasoned divergences -- acceptance against the stock CLI.
- `schemas/envelope.fbs` + `cargo make codegen` -- `WorkspaceAddRequest { kind; destination; name; revisions: [string]; message_paragraphs: [string]; colocate: bool; no_colocate: bool; sparse_patterns: SparseInheritance; }` (`enum SparseInheritance : ubyte { Copy, Full, Empty }`), `CheckoutStats`, `enum StaleRecoveryOutcome : ubyte { NotStale, Updated, Recovered }`, `StaleRecovery`, `WorkspaceAddResult`; `RequestKind` += `WorkspaceAdd`, `WorkspaceUpdateStale`; `Payload` += `WorkspaceAddResult`, `StaleRecovery`; `Precondition.stale_recovery`; Envelope doc names update-stale's trailing-snapshot precondition; commit the 4 outputs -- wire.
- `crates/zanshin-ffi/src/{workspace.rs,envelope.rs,repo.rs,snapshot.rs}` -- `zanshin_workspace_add(handle, data, len)` (reader before handle; absent `destination` → `jj.invalid_input`; absent `name` = None, `""` = a value), `zanshin_workspace_update_stale(handle)`; consts `JJ_WORKSPACE_EXISTS`, `JJ_DESTINATION_NOT_EMPTY`, `JJ_GIT_WORKTREE_FAILED`, warning `JJ_WORKSPACE_IN_CURRENT_DIRECTORY`; `map_mutate_err` arms; builders (+ `stale_recovery` in `build_precondition`) -- FFI.
- `crates/zanshin-ffi/tests/workspace_ffi.rs` (+ `snapshot_ffi.rs` rows, `ffi_abi_doc_sync.rs` count) -- round trips, every new code, both-flags, zero handle, kind mismatch, stale recovery envelope -- FFI witnesses.
- `packages/zanshin_core` -- adapters/decoders/models (`WorkspaceAddResult`, `StaleRecovery`, `StaleRecoveryOutcome`, `CheckoutStats`, `SparseInheritance`; `Precondition.staleRecovery`), commands, isolate API + dispatch, `RepoHandle.workspaceAdd(...)` / `workspaceUpdateStale()`, warning code, barrel exports for the new public models; `test/worker/workspace_test.dart` real-cdylib witnesses (add → open B → make A stale → update-stale; not-stale) + scope note fix; `test/ffi/workspace_test.dart` wire shapes -- bridge.
- `app/test/features/projects/worker_project_repos_test.dart` -- I3: a real stale case through `WorkerProjectRepos.read()` → `ProjectStatus.stale`, and back after `workspaceUpdateStale()` -- I3.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- two symbol rows (story 9.23), every counter re-counted against the files, three error rows + one warning row, `jj.stale_working_copy` row now names the shipped remedy; `crates/test-helpers/src/lib.rs:634-639` comment names `Repo::workspace_add` -- docs.
- `coverage-baseline.txt` -- commit the auto-raised baseline -- ratchet.
- `_bmad-output/implementation-artifacts/sprint-status.yaml`, `deferred-work.md` -- row `9-23-…` → `done` with summary; mark I1–I3 resolved where fixed -- ledger.

**Acceptance Criteria:**
- Given each oracle scenario above, when `cargo make test` runs the parity oracle, then Zanshin and the stock `jj` v0.46.0 end in the same repo state (default workspace, ws2 via `extra`) or the difference is a reasoned `ledger.rs` entry.
- Given a working copy made stale from a second workspace created by `RepoHandle.workspaceAdd`, when the app's `WorkerProjectRepos.read()` runs, then it returns `ProjectStatus.stale`, and after `workspaceUpdateStale()` it no longer does (I3).
- Given `snapshot.auto-update-stale = true` and a stale working copy, when `Repo::snapshot()` runs, then it succeeds, `@`'s files are on disk and `take_precondition().stale_recovery` reports `Updated` (I1; the old pin is gone).
- Given the touched stale-recovery comments, then none cites the recovery code at v0.44.0 (I2).
- Given both new extern fns, then each has a real-cdylib `zanshin_core` witness, `ffi_abi_doc_sync` is green, and every `cargo make test` step passes including the coverage ratchet.

## Spec Change Log

## Review Triage Log

### 2026-10-19 — Review pass
- verdicts: 30 findings — high 0, medium 4, low 21, false 5, maybe-false 0
- findings:
  - `[low]` `[reject]` update-stale on a workspace with no `@` reports `jj.jj_lib_error`, not `jj.no_working_copy` — real (`stale.rs::wc_commit` → `PreconditionError::Backend`), but it needs a forgotten workspace (forget is 9.13, unbuilt) and the fix adds a `PreconditionError` variant plus mapping.
  - `[low]` `[patch]` `workspace_add` reloaded the head with jj-lib's `load_at_head`, reconciling without a workspace name — `old_repo` now loads via `snapshot::load_head` (mapped through `MutateError::from`; simplified after the coverage ratchet flagged an unreachable match arm).
  - `[low]` `[patch]` touched `snapshot.rs` comments mixed v0.44/v0.46 anchors (`:1298-1326`, `:477`, `:2058-2231`) — re-pointed to `:1326-1354`, `:478`, `:2091-2278` @ v0.46.0, checked against the tag.
  - `[low]` `[patch]` error-code docs: the auto arm adds `jj.concurrent_working_copy` to every pre-verb snapshot, and `RepoHandle.workspaceAdd`'s throw list missed codes — the throw list now names `ffi.invalid_handle`, `jj.no_working_copy`, `jj.concurrent_working_copy`; the per-row part is already stated by the rule paragraph `docs/ffi-abi.md:158-164`, so the dozens of rows were not rewritten.
  - `[low]` `[patch]` oracle/tests skip the colocated add whose first parent is root (unborn `refs/jj/root` HEAD); lost-op and sibling rows are Rust-tested only — added `tests/workspace_add.rs::a_colocated_workspace_on_root_gets_an_unborn_head` (empty repo and `-r root()`); the AC's oracle scenario list is otherwise complete.
  - `[medium]` `[patch]` auto arm untested in a colocated workspace (lock re-take hang / skipped Git HEAD reset would pass) — added `auto_update_stale_recovers_a_colocated_working_copy` (completes, `git_head_reset_op_id` set, Git HEAD = new parent).
  - `[low]` `[reject]` the explicit verb drops the stale snapshot's non-stat facts (e.g. rebased count) — matches the intent ("precondition = its trailing snapshot_impl report"); needs a dirty stale `@` with descendants, and the fix adds report fields.
  - `[low]` `[patch]` Dart decoders coerced missing required fields to `''` / zero stats — they now throw `ffi.unknown` like the WorkspaceRoot decoder; the Rust `unwrap_or_default` on `checkout` is unreachable for a just-created workspace.
  - `[low]` `[patch]` Dart auto-arm `staleRecovery` and the absent-vs-empty `name` rule were only synthetic/untested — real-cdylib Dart auto-arm case (`lastPrecondition.staleRecovery.outcome == updated`) and FFI test `workspace_add_refuses_an_empty_name_and_defaults_an_absent_one` added.
  - `[false]` `[reject]` spec record mismatch (empty change log, sprint-status `done` while spec in review) — the fix edits this build's spec; sprint-status is `done` as of this run's commit.
  - `[low]` `[reject]` quadratic revset dedup in `resolve_some_revsets` — only absurd inputs (thousands of parents for a new `@`) reach it; not worth a change.
  - `[low]` `[defer]` no "unresolved conflicts" warning after the stale checkout — pre-existing across every checkout verb (no WarningKind exists); deferred to frontmatter + deferred-work.md.
  - `[low]` `[reject]` recover_at error paths after the stale snapshot drop its committed facts from the partial report — rare jj-lib failure paths; fix adds branches.
  - `[low]` `[reject]` `immutable_heads()` parsed in the OLD workspace context for the new workspace's finish — differs only for a custom `immutable_heads()` referencing `@`; fix needs a second CommandEnv.
  - `[low]` `[reject]` `new_change_ids` omits an extra `@` created when the new commit is immutable — needs an immutable parent set for a brand-new workspace; rare.
  - `[low]` `[reject]` `to_string_lossy` for a non-UTF-8 new workspace root — same lossy pattern as the existing workspace wrappers; non-UTF-8 roots are unreachable through the `&str` API's typical use.
  - `[low]` `[defer]` `snapshot_locked`'s error arm still uses `load_at_head` — pre-existing site not touched by the diff; deferred to frontmatter + deferred-work.md.
  - `[low]` `[patch]` `workspace_add` `load_at_head` (same root cause as row 2) — fixed with row 2.
  - `[false]` `[reject]` `RequestKind` lacks `WorkspaceUpdateStale` — handle-only verbs carry no RequestKind (`WorkspaceList` has none either; the `.fbs` rule ties each variant to a request table), so nothing reads or misses the tag.
  - `[low]` `[patch]` `snapshot_working_copy` doc still cited v0.44.0 (same root cause as row 3) — fixed with row 3.
  - `[low]` `[reject]` `-m` without `templates.commit_trailers` — the intent's Never list excludes trailer rendering.
  - `[medium]` `[patch]` the precondition's switch to `snapshot::load_head` had no witness — added `snapshot_precondition.rs::the_precondition_reconciles_divergent_heads_as_this_workspace` (fails when `run` reverts to `load_at_head`).
  - `[medium]` `[patch]` colocated auto arm untested (same root cause as row 6) — fixed with row 6.
  - `[medium]` `[patch]` update-stale's merged stats and `jj.snapshot_files_refused` warning never observed — added `update_stale_reports_the_files_its_snapshots_refused` (stats name `big.bin`, warning present).
  - `[low]` `[patch]` Dart `workspaceAdd` colocate tri-state / sparse mapping unverified — real-cdylib cases for `colocate: false` on a colocated repo, `sparse: empty`/`full`, and `colocate: true` reaching Rust (`jj.git_worktree_failed` on a native repo; a real worktree cannot be waited on inside `dart test`, a known limitation).
  - `[false]` `[reject]` the CLI-style head load reaches every verb's precondition — the intent requires the recovery and `snapshot::run` to share one head load, and the CLI names the workspace on every reconcile; this is parity, recorded in deferred-work.md.
  - `[low]` `[reject]` update-stale's envelope precondition carries merged stats rather than the trailing snapshot's alone — the merged stats are what the CLI prints for the call; no consumer harm, and splitting them would drop facts.
  - `[low]` `[patch]` `StaleRecovery.commit_id` doc said "the commit the working copy now holds", untrue for `Recovered` after a rewriting trailing snapshot — doc reworded (the recovery commit as jj-lib created it).
  - `[false]` `[reject]` some matrix rows are proven by Zanshin tests, not the oracle — the AC names the oracle scenarios, all present and equal; the matrix audit found every row covered by a passing test.
  - `[false]` `[reject]` `RequestKind` deviation (duplicate of row 19) — same refutation.

### 2026-10-20 — Review pass (follow-up)
- scope: the review diff is `94b37ea..6575d9e` (Story 9.23 and its closing run), excluding `_bmad-output/` and the four generated files; the later stories on `main` (9.15, 9.49, 9.48, 9.29, 9.20) are not this story's diff. Findings were verified against the current tree.
- verdicts: 32 findings — high 0, medium 3, low 22, false 7, maybe-false 0
- findings:
  - `[false]` `[reject]` many matrix rows (add refusals, sibling/lost op, auto-arm variants) are proven by hand-asserted tests, not the oracle — carried: same claim as the 2026-10-19 row "some matrix rows are proven by Zanshin tests, not the oracle"; the AC names the oracle scenarios, all present.
  - `[low]` `[reject]` the concurrent-tree row is witnessed only on the private `update_stale_working_copy`, no verb-level call reaches it — real, but inside the recovery only a racing writer triggers it; a verb-level witness needs a concurrency harness.
  - `[false]` `[reject]` the CLI-style head load changes every verb's precondition (C2 reading) — carried: same claim as the 2026-10-19 row; it is parity, recorded in deferred-work.md.
  - `[low]` `[reject]` the envelope `precondition` carries the merged stats, not the trailing snapshot's alone (D2 reading) — carried: same claim as the 2026-10-19 row; merged stats are what the CLI prints for the call.
  - `[false]` `[reject]` `was_snapshot_taken` after the auto arm is defined by the diff (head moved off the loaded op) while the intent is silent — no bad outcome: the definition is documented and asserted both ways in zanshin-jj tests.
  - `[low]` `[patch]` a successful Git-worktree add is not witnessed from Dart — carried: the 2026-10-19 row (Dart cannot wait on the `git` child inside `dart test`); no further change.
  - `[false]` `[reject]` unrequested edits (`map_mutate_err` tuple rewrite, `maybe_add_gitignore` signature, `start_call`) — behaviour preserved and covered by the FFI mapping tests; `maybe_add_gitignore`'s change is needed for reuse; no caller diverges.
  - `[false]` `[reject]` the ledger edits (sprint-status, deferred-work) are not in the diff — the review diff excluded `_bmad-output/`; they are committed in 29d9b18 / 6575d9e.
  - `[false]` `[reject]` CLI facts without typed fields ("Concurrent modification detected", the new `@`'s commit id/parents) — the first is a `ui.status()` line the Design Notes map to the reconcile op; the second is reachable through `mutation.working_copy_change_id` + `get_change`.
  - `[medium]` `[patch]` `message_paragraphs` is never observed after an FFI add — `workspace_add_round_trips_its_result` now opens the new workspace and asserts its `@` description is `"T\n"`.
  - `[low]` `[patch]` `workspace_update_stale`'s error path (code + partial report) never ran — added `a_failed_recovery_reports_its_code_and_a_report` (wrong-typed `snapshot.max-new-file-size` → `Precondition(Config)` naming the key, `take_precondition()` present).
  - `[low]` `[patch]` `git.colocate` read only for a colocated current workspace was unwitnessed (`None` arm) — `colocation_follows_the_flags_and_git_colocate` now adds with `colocate = None` on the non-colocated "never read" fixture and asserts no worktree.
  - `[medium]` `[patch]` `reset git head` committed only on `has_changes()` was unwitnessed — added `a_colocated_recovery_with_an_unmoved_parent_writes_no_reset` (`git_head_reset_op_id == None`, head op unchanged).
  - `[low]` `[patch]` `docs/ffi-abi.md` "every such symbol's row names all three" omits `jj.concurrent_working_copy` from the auto arm — carried: same claim as the 2026-10-19 error-code-docs row (the rule paragraph `:158-164` states it); not patched again.
  - `[low]` `[patch]` `docs/rust-error-codes.md` did not name `zanshin_workspace_add` / `zanshin_workspace_update_stale` as emitters of existing codes — appended Story 9.23 sentences to the `jj.invalid_input`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error` and `jj.no_working_copy` rows.
  - `[low]` `[reject]` Dart decoders still default a missing `mutation` / `snapshot_stats` — the Rust producer always writes both (`workspace_add.rs` / `stale.rs` builders); unreachable short of a broken producer, and the fix adds guards to the shared `decodeMutationResultInternal`.
  - `[low]` `[patch]` `RepoHandle.workspaceUpdateStale` doc claimed "nothing on disk is lost" for a dirty working copy — reworded: the edits are kept in a divergent commit and leave the disk, as in the CLI.
  - `[low]` `[reject]` the "trailing report on the error envelope" is partial/empty when the recovery fails before the trailing snapshot — carried: same claim as the 2026-10-19 row "recover_at error paths … drop its committed facts".
  - `[false]` `[reject]` unrequested `map_mutate_err` refactor (duplicate of the intent layer's row) — same refutation.
  - `[low]` `[reject]` `snapshot::load_head` discards `merge_operations`' rebased count — real, but jj-lib's `load_at_head` discarded it before 9.23 too; needs divergent heads, and the fix adds a public `Precondition` field.
  - `[low]` `[defer]` about 50 in-verb `load_at_head()` reloads still write an unnamed reconcile; the records overstate "every verb" — pre-existing sites; the record wording is this spec's (not edited). Deferred to frontmatter + deferred-work.md.
  - `[medium]` `[patch]` the new workspace's path in the workspace store was never checked (canonicalisation trap) — `add_default_creates_a_sibling_workspace_on_ats_parents` now asserts `resolve_workspace_root(Some("ws2"))` canonicalises to the destination.
  - `[low]` `[patch]` `revisions` evaluated in the OLD workspace's context had no witness — added `revisions_resolve_in_the_current_workspaces_context` (`-r @` → ws2's parent is default's `@`).
  - `[low]` `[patch]` a bad revset's leftover workspace was unasserted — `a_bad_revset_refuses_with_the_revset_code` now asserts `ws3/.jj` exists and the head op is `add workspace 'ws3'`.
  - `[low]` `[patch]` the `git.colocate = "yes"` refusal did not assert the directory was created first — asserted in `colocation_follows_the_flags_and_git_colocate`.
  - `[low]` `[patch]` no auto-arm witness for a DIRTY stale working copy — added `auto_update_stale_snapshots_a_dirty_working_copy_first` (`was_snapshot_taken`, `Updated`, head op `reconcile divergent operations`).
  - `[low]` `[reject]` no auto-arm test for a FAILING recovery — the partial report on failure paths is the carried reject above; a failing auto recovery after writes needs fault injection.
  - `[low]` `[patch]` update-stale's error lists missed `jj.stale_working_copy` (the trailing `snapshot_locked` runs `handle_stale_working_copy`) — added to `Repo::workspace_update_stale` `# Errors`, the FFI rustdoc (+ regenerated header), the `docs/ffi-abi.md` row, and the Dart `RepoHandle` / worker docs.
  - `[low]` `[reject]` an out-of-range `outcome` byte raises a raw `StateError` in Dart — the Rust producer only writes the three variants; a guard for a broken producer is not worth it.
  - `[low]` `[reject]` `recover_at` failing after committed operations leaves a partial report that says nothing was written — carried: the 2026-10-19 row.
  - `[low]` `[reject]` the auto arm's failed `recover` keeps the pre-recovery `was_snapshot_taken` — real, same class as the carried row at a different site; rare jj-lib/concurrency failure after writes, fix adds an error branch.
  - `[low]` `[reject]` quadratic dedup in `resolve_some_revsets` — carried: the 2026-10-19 row.

## Design Notes

**Why one recovery for two callers.** The CLI's `update-stale` and its auto arm call the same `recover_stale_working_copy_impl`, the auto arm under the lock `workspace_helper` already holds. Zanshin's `snapshot::run` drops its lock on return, so reading the knob in `Repo::precondition` (today) cannot recover under the lock; the arm moves into `run`.

**Reporting.** The CLI prints the recovery's facts before the verb's own output (`test_workspaces_updated_by_other_automatic`); `Precondition.stale_recovery` is that report on the auto arm, so the UI shows item 2's result and no StaleNotice. For the explicit verb the payload is the `StaleRecovery` and the envelope's `precondition` is its trailing snapshot (as convert's post-conversion snapshot since 9.33). "Concurrent modification detected…" and "Failed to read working copy's current operation…" are `ui.status()` lines, not warnings — they become no codes; `Recovered` and the reconcile op carry the fact.

**`workspace add` details the CLI decides for us.** The destination's final component is the default name; `destination_path.file_name().unwrap()` panics on `x/..` or `/`, so Zanshin refuses with `jj.invalid_input` and writes nothing — the panicking CLI also writes nothing beyond the pre-verb snapshot. Non-UTF-8 names are unreachable through a `&str` API. A bad `revisions` entry is resolved AFTER the workspace and its op exist (`add.rs:226-252`), and Zanshin leaves the same state. `revisions` are revset strings, like absorb's `into`, because the CLI unions whole revsets (`resolve_revsets_ordered`), which change ids cannot express.

## Verification

**Commands:**
- `cargo make codegen` then `git status` -- expected: the four generated files changed and committed.
- `cargo make test` -- expected: every step green (clippy, fmt, doctests, Dart analyze/format/tests, `cargo deny`, parity oracle, coverage ratchet with new files ≥ 80 % and every extern fn hit).

## Auto Run Result

Status: done

**Summary.** Story 9.23 ports, at jj v0.46.0, `jj workspace update-stale` (`recover_stale_working_copy_impl`: stale snapshot at the working copy's own op, CLI-style head load, colocated `reset git head`, checkout without an op of its own, jj-lib `recovery commit` for a lost op, trailing snapshot, merged stats), the `snapshot.auto-update-stale = true` arm inside the pre-verb snapshot under its lock (`Precondition.stale_recovery`), and `jj workspace add` (name / `-r` revsets / `-m` / `--colocate|--no-colocate` / `--sparse-patterns` passed through, `git.colocate` builtin default, Git worktree, `.jj/.gitignore`, sparse copy/full/empty). Surfaced as `Repo::workspace_update_stale` / `Repo::workspace_add`, FFI `zanshin_workspace_update_stale` / `zanshin_workspace_add` (63 exports), Dart `RepoHandle.workspaceUpdateStale` / `workspaceAdd`. Deferred items I1–I3 resolved. The pre-verb head load now reconciles divergent operations as the workspace (CLI `resolve_operation`), for every verb.

**Files changed.**
- `crates/zanshin-jj/src/stale.rs` (new) — the recovery, `StaleRecovery` / `StaleRecoveryOutcome` / `CheckoutStats`; `update_stale_working_copy` extracted for the concurrent-tree witness.
- `crates/zanshin-jj/src/workspace_add.rs` (new) — the `workspace add` port, `SparseInheritance`, `WorkspaceAddResult`.
- `crates/zanshin-jj/src/snapshot.rs` — auto arm in `run`, `load_head` (CLI head load), `PreconditionError::ConcurrentWorkingCopy`, v0.46.0 citations.
- `crates/zanshin-jj/src/repo.rs` — `workspace_update_stale`, `workspace_add`, shared `start_call`.
- `crates/zanshin-jj/src/{mutate,config,convert,warning,lib,workspace}.rs` — new MutateError variants + finish checkout stats, `git.colocate` builtin + reader, shared `.jj/.gitignore` writer, `WorkspaceInCurrentDirectory` warning, re-exports, docs.
- `crates/zanshin-jj/tests/{workspace_add,workspace_update_stale}.rs` (new), `snapshot_precondition.rs`, `api_stability.rs` — witnesses incl. I1.
- `schemas/envelope.fbs` + 4 generated outputs — request/result tables, `Precondition.stale_recovery`.
- `crates/zanshin-ffi/src/{workspace,envelope,repo,snapshot}.rs` + tests — the two extern fns, 3 error codes + 1 warning code, builders.
- `crates/zanshin-parity/tests/oracle/{main,scenarios,state}.rs` — 10 scenarios, no ledger entry.
- `packages/zanshin_core/**` — models, decoders, commands, isolate API, `RepoHandle` verbs, real-cdylib tests.
- `app/test/features/projects/worker_project_repos_test.dart` — I3 real stale case.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `crates/test-helpers/src/lib.rs` — docs; `coverage-baseline.txt` raised.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` — 9-23 done, I1–I3 resolved, deferrals mirrored.

**Review findings.** 30 findings (0 high, 4 medium, 21 low, 5 false). Patched: 17 rows in 12 entries (3 medium entries: colocated auto-arm witness, precondition reconcile-name witness, update-stale refused-file stats/warning witness; 9 low entries: `workspace_add` head load, v0.46.0 citations, `workspaceAdd` throw list, unborn-HEAD colocated add test, Dart decoders throw on missing fields, Dart auto-arm + empty-name FFI tests, Dart colocate/sparse tests, `commit_id` doc). Deferred: 2 (snapshot_locked error-arm `load_at_head`; no "unresolved conflicts" warning after checkout — both pre-existing). Rejected: 11 — see the triage log for each reason (no-`@` code needs a forgotten workspace; dropped stale-snapshot facts match the intent; quadratic dedup only for absurd inputs; rare error-path partial reports; old-context `immutable_heads()`; immutable-parent extra `@`; lossy non-UTF-8 root; trailers excluded by the intent; merged stats in the envelope precondition; plus 5 false findings).

**Follow-up review recommendation: true.** First pass, 3 medium entries patched (0 high). The unverified risk: the review-round source changes — `workspace_add` now loads the head through `snapshot::load_head` (a head-load failure now surfaces as `MutateError::Precondition(Backend)`, still `jj.jj_lib_error` on the wire) and the Dart decoders now throw `ffi.unknown` on missing required fields — were verified only by the gate, not re-reviewed.

**Verification.**
- `cargo make codegen` → exit 0, no further change to the four committed generated files.
- Matrix test audit: every I/O row has a passing test; "update-stale: concurrent tree" is witnessed by `stale::tests::a_recorded_tree_other_than_the_stale_ats_is_a_concurrent_working_copy` (step extracted; inside the recovery only a concurrent writer can trigger it).
- `cargo make test` → green (exit 0) on the final tree: clippy, fmt, doctests, Flutter/Dart suites, parity oracle 45/45, coverage ratchet (no regression, every extern fn covered). Earlier runs failed on a format nit, a coverage regression in `workspace_add.rs` from an unreachable match arm (simplified), and three runs on `app/test/features/projects/projects_window_test.dart` timing out in `_Rig.settle` (500 ms real-IO budget) under machine load — that file passes alone and in a solo `flutter test` of `app/`, and touches no code this story changed.

**Residual risks.**
- `projects_window_test.dart`'s `settle` budget is flaky under load (pre-existing, not this story's).
- Every verb's pre-verb snapshot now names the workspace on a reconcile op — a parity change wider than the two new verbs.
- The colocated `workspaceAdd(colocate: true)` worktree is only proven from Rust; Dart cannot wait on the `git` child inside `dart test`.
- A dirty stale working copy's edits move into a divergent commit and leave the disk (the CLI's behaviour).

**Dispatched deferred items.**
- I1 (`snapshot.auto-update-stale = true` still refuses a stale working copy): fixed (29cb597e0972b9746e46860c37e92e1acde945ce). The auto arm runs the recovery inside `snapshot::run` under its lock; the pin `auto_update_stale_still_refuses_until_the_recovery_lands` is replaced by `auto_update_stale_recovers_a_stale_working_copy` (+ sibling-op and missing-op cases) in `crates/zanshin-jj/tests/snapshot_precondition.rs`, plus `auto_update_stale_recovers_in_front_of_status` / `_a_colocated_working_copy` in `tests/workspace_update_stale.rs`.
- I2 (stale-recovery comments cite the CLI at v0.44.0): fixed (29cb597e0972b9746e46860c37e92e1acde945ce). The stale-working-copy recovery citations in `snapshot.rs` / `repo.rs` now point at `cli_util.rs` @ v0.46.0; the other v0.44.0 citations stay for Story 9.46, as dispatched.
- I3 (the adapter's stale mapping never tested against a real stale working copy): fixed (29cb597e0972b9746e46860c37e92e1acde945ce). `app/test/features/projects/worker_project_repos_test.dart` makes a working copy stale through `RepoHandle.workspaceAdd` + a rewrite from the second workspace, asserts `ProjectStatus.stale`, and asserts it clears after `workspaceUpdateStale()`.

### Follow-up review pass (2026-10-20)

Status: done

**Summary.** A fresh four-layer review (blind, edge-case, verification-gap, intent-alignment) of Story 9.23's diff (`94b37ea..6575d9e`, generated files and `_bmad-output/` excluded). No production behaviour changed: the patches close verification gaps and correct docs.

**Files changed.**
- `crates/zanshin-jj/tests/workspace_add.rs` — workspace-store path check, `-r @` old-context witness, bad-revset leftover, `git.colocate` refusal after `create_dir`, `colocate = None` on a non-colocated repo never reads `git.colocate`.
- `crates/zanshin-jj/tests/workspace_update_stale.rs` — colocated recovery with an unmoved parent writes no `reset git head`, failed recovery keeps its code and a report, dirty auto-arm recovery.
- `crates/zanshin-ffi/tests/workspace_ffi.rs` — `-m` survives the wire (new `@` description `"T\n"`).
- `crates/zanshin-jj/src/repo.rs`, `crates/zanshin-ffi/src/workspace.rs` (+ regenerated `include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`), `docs/ffi-abi.md`, `packages/zanshin_core/lib/src/worker/{handle,isolate}.dart` — update-stale error lists name `jj.stale_working_copy`; the dirty-working-copy doc no longer claims nothing leaves the disk.
- `docs/rust-error-codes.md` — Story 9.23 emitters on `jj.invalid_input`, `jj.revset_parse_error`, `jj.revset_resolution_error`, `jj.config_error`, `jj.no_working_copy`.
- `coverage-baseline.txt` — raised (1 file up).
- `_bmad-output/implementation-artifacts/deferred-work.md` — the new deferral mirrored.

**Review findings.** 32 findings (0 high, 3 medium, 22 low, 7 false). Patched: 3 medium (FFI `-m` witness, `has_changes()` reset-guard witness, workspace-store path check) and 10 low (update-stale error path, `git.colocate` `None` arm, `-r @` context, bad-revset leftover, directory-before-config-refusal, dirty auto arm, error-code registry emitters, dirty-working-copy doc, `jj.stale_working_copy` in the error lists; plus one carried low patch row needing no change). Deferred: 1 (in-verb `load_at_head` reloads still write unnamed reconciles — pre-existing). Rejected: 18 — concurrent-tree verb-level witness (needs a racing harness); Dart decoder defaults for fields the producer always writes; reconcile `num_rebased` dropped (pre-existing, adds a public field); failing auto-arm recovery test and its partial report (fault injection; carried class); auto-arm failed-recover `was_snapshot_taken` (rare, adds a branch); out-of-range Dart enum byte; plus carried rejects (oracle-vs-test rows, C2 head load, D2 merged stats, partial report on error paths, quadratic dedup, `ffi-abi.md` "all three" rule) and 7 false findings (see the triage log).

**Follow-up review recommendation: false.** Follow-up pass with no high patched; 3 medium + 10 low entries patched, all test or doc changes — the work has converged.

**Verification.**
- `cargo test -p zanshin-jj --test workspace_add --test workspace_update_stale` → 14 + 12 passed; `cargo test -p zanshin-ffi --test workspace_ffi workspace_add_round_trips` → passed.
- `cargo make codegen` → exit 0; the header and `bindings.dart` doc comments regenerated and committed.
- `cargo make test` → green (exit 0) after one `cargo fmt` pass (the first run failed on rustfmt line wrapping of the new tests); coverage ratchet raised the baseline for one file, every extern fn covered.

**Residual risks.**
- The concurrent-tree refusal is still reached only through the private step; in-verb head reloads keep jj-lib's unnamed reconcile (deferred).
- The new tests were not mutation-checked (each assertion was not proven to fail with its guard removed).
