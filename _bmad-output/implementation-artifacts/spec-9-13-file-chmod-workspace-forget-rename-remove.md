---
title: 'Story 9.13 — `file chmod`; `workspace forget`, `rename`, `remove`'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: '7bd14f542fee1a03655622ca7d082981de9c6ec6'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: [oversized]
deferred: []
---

<intent-contract>

## Intent

**Problem:** zanshin-jj has no `jj file chmod`, `jj workspace forget`, `jj workspace rename` or (new in jj 0.46) `jj workspace remove`. A GUI cannot set a file's executable bit, stop tracking or delete a secondary workspace (the remedy `jj.workspace_in_current_directory` already names), or rename one. Open item I1 (deferred-work.md, "Must-haves (cross-cutting, medium)": a missing `@` surfacing as `jj.jj_lib_error`) names this story, because `workspace forget` first makes that state reachable through the public API.

**Approach:** Port `cmd_file_chmod` (`cli/src/commands/file/chmod.rs`) and `cmd_workspace_{forget,rename,remove}` (`cli/src/commands/workspace/{forget,rename,remove}.rs`) at v0.46.0 end to end (`.fbs` → zanshin-jj → `extern "C"` → committed codegen → `packages/zanshin_core`) on the house verb template (`with_verb` / `with_checked_verb`, `finish_verb`, `MutationResult`), with parity-oracle scenarios. Settle I1 against the code as this story leaves it.

## Boundaries & Constraints

**Always:**
- The CLI at v0.46.0 is the spec (`git -C ../jj show v0.46.0:<path>`): order of checks, refusal and warning texts verbatim, op descriptions byte-identical, every on-disk effect. Clap-level refusals come BEFORE the pre-verb snapshot (`with_checked_verb`); everything else after it.
- **file chmod** `(executable: bool, revision: Option<ChangeId>, paths: &[String])` → `MutationResult`. (1) Clap: empty `paths` → `jj.invalid_input` before the snapshot. (2) Resolve the revision (`None` = `@`, `mutate::resolve_or_wc`). (3) `guard_rewritable` on it. (4) Parse paths with `wc_ops::parse_paths` (made `pub(crate)`; empty entry refused, absolute/workspace-relative like `file track`), warn unmatched over `[&commit tree]` (`warning::warn_unmatched_paths`, existing `jj.paths_unmatched`). (5) In the transaction: `MergedTreeBuilder` over the tree; per matching entry, refuse unless every `adds()` term is a `TreeValue::File` — "Found neither a file nor a conflict at '{p}'." for a resolved value, "Some of the sides of the conflict are not files at '{p}'." otherwise (`{p}` = `warning::ui_path`) → `jj.invalid_input`, no operation; else set every file term's bit (`select_tree::with_executable`, made `pub(crate)`) and `set_or_remove`. (6) `rewrite_commit(&commit).set_tree(..).write()`, `finish_verb` with `make paths executable|non-executable in commit {full hex}` — no own no-op shortcut (the finish's `has_changes` gate decides, as `tx.finish` does).
- **workspace forget** `(names: &[String])` → `WorkspaceRemoveResult`. Empty `names` = the current workspace. Per name in argument order: no `@` in the view → warning `jj.workspace_names_unmatched` "No such workspace: {name.as_symbol()}"; none left → no operation (`no_op_result`). Before the transaction, collect each kept name's recorded store path that canonicalizes (`std::fs::canonicalize`; unreachable ones omitted). One transaction: `remove_workspace` per kept name; description `forget workspace {n}` / `forget workspaces {a, b}` (`as_symbol`, `", "`); `finish_verb`. The recorded path STAYS in the store (jj #9991). Then per collected path `jj_lib::git::unlink_worktree` (options from `environment::git_subprocess_options`): `Ok(true)` → path into `git_worktrees_removed`; `Err` → warning `jj.git_worktree_unlink_failed` `Failed to remove Git worktree for "{path}".` + `: {flatten_chain}`; the call still succeeds.
- **workspace rename** `(new_name: &str)` → `MutationResult`. (1) Empty → "New workspace name cannot be empty" `jj.invalid_input` before the snapshot. (2) Equal to the current name → no operation. (3) Current workspace has no `@` → `MutateError::NoWorkingCopy` (CLI "The current workspace '{old}' is not tracked in the repo."). (4) Start the raw transaction, lock the working copy (`mutate::lock_working_copy`), `locked_wc.rename_workspace`, `tx.repo_mut().rename_workspace` (exists → `MutateError::WorkspaceExists { name }`, nothing written), store `rename` (after the view, before the commit), `tx.commit("Renamed workspace '{old}' to '{new}'")` — a plain commit, no finish/rebase/export — then `locked_ws.finish(op)`. Result `working_copy_change_id` = `@` under the NEW name; the handle then reloads its workspace so later calls run under the new name.
- **workspace remove** `(names: &[String])` → `WorkspaceRemoveResult`. (1) Clap: empty `names` → `jj.invalid_input` before the snapshot. (2) Unknown names warn as forget; none left → no operation. (3) Per kept name, in order, refusals `jj.invalid_input` with hint `Use \`jj workspace forget\` to stop tracking a workspace without deleting files.` unless noted: no recorded path → "Cannot remove unreachable workspace '{n}'"; canonicalize fails → "Cannot access workspace '{n}' directory: {cause}"; the canonical path contains this repo's `.jj/repo` → "Cannot remove workspace '{n}' because it contains the repository" (no hint); loading a `Workspace` there fails → the CLI's `map_workspace_load_error` text (`NoWorkspaceHere`/`RepoDoesNotExist`/path errors → `jj.invalid_input`, others `jj.jj_lib_error`); its `repo_path()` differs → "Cannot remove workspace '{n}' because it belongs to another repository". (4) Snapshot each target workspace (`snapshot::run` on it: its own colocation + `CommandEnv::load`, warnings appended to the call's list, a throwaway `Precondition`); a refusal (e.g. stale) stops the call there. (5) The current workspace's `CommandEnv::load` again (warnings again, as `for_workable_repo`), reload head, one transaction `remove_workspace` per name, `remove workspace {n}` / `remove workspaces {a, b}`, `finish_verb`. (6) Store `forget(names)`, unlink worktrees as forget, then `std::fs::remove_dir_all` each path: success → `directories_removed`; failure → warning `jj.workspace_directory_remove_failed` `Failed to remove workspace directory "{path}".` + `: {cause}`.
- New `WorkspaceRemoveResult { mutation: MutationResult, git_worktrees_removed: Vec<PathBuf>, directories_removed: Vec<PathBuf> }` (forget's `directories_removed` always empty) — the CLI's status lines as typed facts. Three NEW warning codes: `jj.workspace_names_unmatched`, `jj.git_worktree_unlink_failed`, `jj.workspace_directory_remove_failed`. No new error code.

**Never:** no terminal chatter ("Nothing changed.", "Removed Git worktree…" as text); no fileset DSL (ADR-0003, the 9.22 path rule); no MCP; no UI code; never regenerate fixtures; never run `jj` outside temp dirs; no full gate (`cargo make test` / `test-full` / `coverage`) — this run's gate rule.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| chmod x / n | `a.txt` in `@`; `executable=true` then `false` | bit set/cleared, descendants rebased; op `make paths executable in commit <hex>` | — |
| chmod revision / dir prefix | `revision=B`; `paths=["dir"]` | B rewritten; every file under `dir` changed | — |
| chmod unmatched / immutable | `paths=["nope"]`; root or immutable rev | warns, op still per finish; refused, head unchanged | `jj.paths_unmatched`; `jj.immutable` |
| chmod non-file / clap | symlink path; `paths=[]` | refused, no op; refused before snapshot | `jj.invalid_input` |
| forget other / current / two | `ws2`; `[]`; `[ws2, ws3]` | view loses them, store keeps paths, files untouched; current: warning, `working_copy_change_id` absent | `jj.workspace_no_longer_exists` (current) |
| forget unknown | `[nope]` | no operation | `jj.workspace_names_unmatched` |
| forget colocated child | `ws2` added with Git worktree | `.git` file gone, path in `git_worktrees_removed` | `jj.git_worktree_unlink_failed` on failure |
| rename | `[new]`; same name; existing `ws2`; `""` | view + store + working copy renamed, op `Renamed workspace 'default' to 'new'`; no op; refused; refused pre-snapshot | `jj.workspace_exists`; `jj.invalid_input` |
| remove | `ws2` with dirty file | ws2 snapshotted (op), removed (op `remove workspace ws2`), store entry gone, dir deleted | — |
| remove refusals | `default`; dir deleted; `[]`; `[nope]` | refused / no op | `jj.invalid_input` (+ forget hint); warning for `nope` |
| I1 | forget current, then `file_list(None)` / `restore(None…)` | CLI text "Workspace `default` doesn't have a working-copy commit" | `jj.invalid_input` / `jj.revset_resolution_error` (not `jj.jj_lib_error`) |

</intent-contract>

## Code Map

CLI anchors @ v0.46.0: `file/chmod.rs:61-136`, `workspace/forget.rs:41-131`, `workspace/rename.rs:30-82`, `workspace/remove.rs:34-200` (`USE_WORKSPACE_FORGET_HINT` :34), `git_util.rs:572-595` (`unlink_git_worktree`), `cli_util.rs:2906-2940` (`map_workspace_load_error`), `command_error.rs:312-316` (rename error). jj-lib 0.46.0 (`~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/`): `jj-lib-0.46.0/src/repo.rs:1666` `remove_workspace` (async), `:1701` `rename_workspace`; `git.rs:1955` `unlink_worktree(&Store, GitSubprocessOptions, &Path) -> Result<bool, _>` (Ok(false) when `.git` is not a file); `working_copy.rs:127` `LockedWorkingCopy::rename_workspace`; `jj-core-0.46.0/src/workspace_store.rs:42-60` `add/forget/rename/get_workspace_path` (all `&self`). CLI tests: `cli/tests/test_workspaces.rs` (forget/rename/remove), `test_file_chmod_command.rs`.

**zanshin-jj**
- `src/workspace.rs` — module doc :17-19 (update: forget/rename/remove now Story 9.13's); `load_store` :138 → `pub(crate)` (fresh store as the CLI's start-up). New verbs may live in a new `src/workspace_ops.rs` (forget/rename/remove + `WorkspaceRemoveResult`; `lib.rs` re-export).
- `src/workspace_add.rs:160-163` — `environment::git_subprocess_options(settings, None)` idiom for the unlink options; `:137` `add` as verb template (`VerbContext`, `start_repo_transaction`, `CommandEnv::load` into `ctx.warnings` :184-186).
- `src/mutate.rs` — `MutateError` :129 (`InvalidInput` :142, `NoWorkingCopy` :368, `WorkspaceExists` :391), `invalid` :528, `invalid_hinted` :537, `be`/`cfg`, `flatten_chain`, `resolve_or_wc` :652, `guard_rewritable` :681, `finish_verb` :924, `mutation_result` :968, `no_op_result` :1508, `lock_working_copy` :1677, `commit_with_locked_wc` :1715 (reads `@` under the OLD name after commit — rename cannot use it unchanged; write rename's own few lines or parameterize the name), `restore` :1872 (rewrite → `rebase_descendants` → finish template), `finish_transaction` :820 (emits `WorkspaceNoLongerExists` :889).
- `src/wc_ops.rs:380` `parse_paths` and `:399` `prefix_matcher` (→ `pub(crate)`); `:352` `is_colocated_git_workspace`; `:472-477` builder idiom.
- `src/select_tree.rs:468` `with_executable` (→ `pub(crate)`). `src/warning.rs` — `WarningKind` (workspace kinds :154-165, `WorkspaceNoLongerExists` :284), `push` :338, `ui_path` :388, `warn_unmatched_paths` :739.
- `src/snapshot.rs` — `run(&mut Workspace, &StackedConfig, &CommandEnv, colocated, &mut Precondition, &mut Warnings)` :481, `load_head` :313, `CommandEnv::load` :384, `VerbContext` :413.
- `src/repo.rs` — `with_verb` :491, `with_checked_verb` :504, `reload_workspace` :1849 (rename's handle reload), `workspace_add` :2494 doc shape, `restore` :2899, `file_untrack` :3754. Facades: `file_chmod`, `workspace_forget`, `workspace_rename`, `workspace_remove`.
- `src/op_support.rs:610` `ResolveError::NoWorkingCopy`, `:764` `resolve_or_wc` (I1, already the CLI's text since commit 3ee3f29); `file.rs:249` / `mutate.rs:614` / `commit_views.rs:248` map it.

**Wire + FFI**
- `schemas/envelope.fbs` — `RequestKind` :94-155 (append `FileChmod, WorkspaceForget, WorkspaceRename, WorkspaceRemove` after `BookmarkUntrack`); tables `FileChmodRequest { kind, executable: bool, revision: string, paths: [string] }`, `WorkspaceNamesRequest { kind, names: [string] }` (forget + remove), `WorkspaceRenameRequest { kind, new_name: string }`; result `WorkspaceRemoveResult { mutation: MutationResult, git_worktrees_removed: [string], directories_removed: [string] }` appended to `union Payload` :2632.
- `crates/zanshin-ffi/src/workspace.rs` (`read_workspace_add_request` :109, `zanshin_workspace_add` :392 templates) — three externs `zanshin_workspace_forget` / `_rename` / `_remove`; `src/file_ops.rs` (`read_file_untrack_request` :75, `zanshin_file_untrack` :277) — `zanshin_file_chmod` returning `ok_mutation_result` (`envelope.rs:822`); `src/envelope.rs` warning consts + `warning_code()` arms (~:461, ~:1657) + list (~:1740); `src/repo.rs:169` `map_mutate_err` (no new variant expected).
- Generated only via `cargo make codegen`: `zanshin_ffi.h`, `envelope_generated.rs`, `bindings.dart`, `envelope_zanshin.ffi_generated.dart`.
- `docs/ffi-abi.md` (98 → 102 exports :554, FlatBuffers count :293, rows :600); `crates/zanshin-ffi/tests/it/ffi_abi_doc_sync.rs:37` → 102. `docs/rust-error-codes.md` — three warning rows; "Also emitted — Story 9.13" clauses on `jj.invalid_input`, `jj.workspace_exists`, `jj.no_working_copy`, `jj.immutable`, `jj.paths_unmatched`, `jj.workspace_no_longer_exists`.

**Dart (`packages/zanshin_core`)**
- `lib/src/ffi/workspace.dart` (`zanshinWorkspaceAdd` :80, `WorkspaceAddResult` :207, decoder :340), `lib/src/ffi/mutate.dart:132` (`zanshinRestore` MutationResult template), `lib/src/ffi/warning.dart` (codes + `values`), `lib/src/worker/commands.dart` (`WorkspaceAddCommand` :1277, `FileUntrackCommand` :1608), `lib/src/worker/isolate.dart` (`workspaceAdd` :2551, dispatch :4335), `lib/src/worker/handle.dart` (`workspaceAdd` :1921), barrel `lib/zanshin_core.dart:102`.

**Tests**
- `crates/zanshin-jj/tests/it/` — new modules `workspace_ops.rs`, `file_chmod.rs` (declare in `main.rs`); fixtures `workspace_update_stale.rs:52` `two_workspaces(colocated, config)`, `workspace_add.rs:47-135`, `select_tree.rs:158` `set_executable`, `file_track_untrack.rs:66-230`; `api_stability.rs` (facade pins `:1104` area, `WarningKind` lists, new public type).
- `crates/zanshin-ffi/tests/it/workspace_ffi.rs` (`open_two_workspace_scenario` :116, `tagged_request_bytes` :595), `file_ops_ffi.rs` (`track_request_bytes` :98, refusal set :338-414).
- `packages/zanshin_core/test/{ffi,worker}/{workspace,file_ops}_test.dart`, `test/ffi/warning_test.dart`.
- Oracle `crates/zanshin-parity/tests/oracle/`: `scenarios.rs` workspace block :1572-1640 (`ws2_read_back` :220, `STALE_FROM_WS2` :275, `commit_without_working_copy` :2133), `BASE` :44, `restore_from` :1143; `git_scenarios.rs` (colocated workspace setup); `main.rs` `parity!` list :55; `ledger.rs:70`.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/warning.rs` -- three `WarningKind` variants citing the CLI lines -- ride the call's list.
- `crates/zanshin-jj/src/{wc_ops,select_tree,workspace}.rs` -- `pub(crate)` on `parse_paths`, `prefix_matcher`, `with_executable`, `load_store`; module doc update -- reuse, no copies.
- `crates/zanshin-jj/src/wc_ops.rs` (or `mutate.rs`) -- `file_chmod` per Always; inline tests for the non-file classifier.
- `crates/zanshin-jj/src/workspace_ops.rs` (new) + `lib.rs` -- `forget`, `rename`, `remove`, `WorkspaceRemoveResult`, the load-error mapping, unlink helper shared by forget/remove; module doc with CLI anchors and divergences (status lines as typed facts, `std::fs::canonicalize` for `dunce`).
- `crates/zanshin-jj/src/repo.rs` -- facades `file_chmod(bool, Option<&ChangeId>, &[String])`, `workspace_forget(&[String])`, `workspace_rename(&str)`, `workspace_remove(&[String])` with house doc blocks + `# Errors`; clap checks via `with_checked_verb`; rename reloads the workspace on success.
- `schemas/envelope.fbs` + `cargo make codegen` -- kinds, three request tables, result table; commit generated files.
- `crates/zanshin-ffi/src/{file_ops,workspace,envelope}.rs` -- readers (absent vector = empty, wrong kind refused), four externs with rustdoc (codes emitted), result builder, warning consts/arms/tables.
- `packages/zanshin_core` lib -- builders, `WorkspaceRemoveResult` decoder, commands, worker methods, dispatch, NUL guards, `RepoHandle.fileChmod(paths, {required executable, revision})`, `workspaceForget([names])`, `workspaceRename(newName)`, `workspaceRemove(names)`; three `ZanshinWarningCode`s; barrel.
- `crates/zanshin-jj/tests/it/{file_chmod,workspace_ops}.rs` + `main.rs` + `api_stability.rs` -- every matrix row against jj-lib state, store and disk; refusals and no-ops keep the head; clap refusals leave no precondition; I1 rows through `workspace_forget`.
- `crates/zanshin-ffi/tests/it/{file_ops_ffi,workspace_ffi,ffi_abi_doc_sync}.rs` -- readers, zero handle, kind mismatch, one success + one refusal per extern, each request field crossing, result lists crossing.
- `packages/zanshin_core/test/...` -- wire shape + NUL guards; real-cdylib round trip per new extern (success + refusal).
- `crates/zanshin-parity/tests/oracle/{scenarios,git_scenarios,main}.rs` -- chmod (x, n, revision, unmatched, immutable, symlink refusal, empty paths), forget (other, current, two, unknown, colocated worktree), rename (new, same, existing, empty), remove (ws2 dirty, two, unknown, default refused, unreachable refused, empty) with read-backs of store/disk where the oracle cannot see them.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- per Code Map.
- `_bmad-output/implementation-artifacts/{sprint-status.yaml,deferred-work.md}` -- flip `9-13-file-chmod-workspace-forget-rename` to `done` (sibling-style summary, bump `last_updated`); strike I1's bullet (deferred-work.md:192) as settled with the evidence; `## Surfaced in Story 9.13 (bmad-build-auto, 2026-10-24)` mirroring every `deferred:` entry.

**Acceptance Criteria:**
- Given the four verbs, when a Dart caller reaches them, then the whole chain exists and `ffi_abi_doc_sync` passes with 102 exports.
- Given every oracle scenario, when the oracle runs, then each matches the pinned CLI or diverges only through a ledgered entry with reason and reference.
- Given any refusal or no-op, when the op head is compared before and after, then it is unchanged (beyond the pre-verb snapshot / remove's per-workspace snapshots, as in the CLI) and `new_op_id` equals that head.
- Given a workspace forgotten through `workspace_forget`, when a file read or a mutation is called with an omitted revision, then it refuses with the CLI's "Workspace `<name>` doesn't have a working-copy commit" text and never `jj.jj_lib_error`.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 25 findings — high 0, medium 0, low 19, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (verification-gap) `git_worktrees_removed` never asserted non-empty across the FFI, so a swap with `directories_removed` would pass — fixed: colocated FFI remove round trip asserting both lists equal the canonical ws2 path.
  - `[low]` `[patch]` (verification-gap) chmod of a conflicted file (every side a file) never runs through the facade — fixed: integration tests for a file/file conflict (every file term takes the bit) and a file/symlink conflict refusal.
  - `[low]` `[patch]` (verification-gap) remove with a target whose snapshot refuses (stale) untested — fixed: test asserts the refusal, ws2 still in view and store, directory kept, no `remove workspace` op.
  - `[low]` `[patch]` (blind) remove docs say every refusal but "contains the repository" carries the forget hint, but the workspace-load errors carry none (CLI parity) — fixed: prose in `Repo::workspace_remove` and `zanshin_workspace_remove`.
  - `[low]` `[reject]` (blind) rename without `@` drops the CLI's text "The current workspace '<name>' is not tracked in the repo." — the spec chose `MutateError::NoWorkingCopy` (no context), as 9.49's `commit` reports the CLI's "requires a working copy"; carrying the text needs a new variant field (public surface) for a state only reachable after forgetting the current workspace — rare; the misleading doc sentence is patched (row below).
  - `[low]` `[patch]` (blind) removing the handle's OWN secondary workspace (allowed by the CLI) untested/undocumented — fixed: test from a ws2 handle (dir gone, `working_copy_change_id` None, `jj.workspace_no_longer_exists`) and the outcome stated in `Repo::workspace_remove`'s doc.
  - `[low]` `[reject]` (blind) rename reloads the handle only on success; if `locked_ws.finish` fails after commit the handle keeps the old name — needs a working-copy finish failure after a successful commit (disk error), unlikely in everyday use; the fix adds a second reload path.
  - `[low]` `[patch]` (blind) chmod on conflicts only unit-tested — same fix as the verification-gap conflict row.
  - `[low]` `[patch]` (blind) parity coverage lacks a colocated remove — fixed: oracle scenario `workspace_remove_colocated_worktree`. Rest of the row rejected: "unreachable" cannot be built through the CLI (needs a workspace with no recorded path; covered in the Rust suite), "another repository", duplicates and failure warnings are covered by Rust tests, and duplicate handling is a straight port.
  - `[low]` `[patch]` (blind) dead `canonicalize` after the directory was deleted in the FFI remove test — fixed: computed before the call.
  - `[low]` `[patch]` (blind) an absent `FileChmodRequest.executable` silently means `n` — fixed: the schema documents absent = `false` (the CLI's `n`); `RepoHandle.fileChmod` makes it a required argument, so the GUI path always sets it.
  - `[low]` `[patch]` (blind) several `remove.rs` line citations wrong at v0.46.0 — fixed: anchors re-read and corrected.
  - `[low]` `[patch]` (blind) FFI test gaps: forget with ABSENT names never sent; rename/remove lack null-buffer / zero-handle refusal tests — fixed: tests added.
  - `[low]` `[patch]` (blind) `RepoHandle.workspaceRemove` doc omits `gitWorktreesRemoved` / `jj.git_worktree_unlink_failed` — fixed.
  - `[low]` `[patch]` (edge) the handle's own secondary workspace removed — same fix as the blind own-workspace row (test + doc; behaviour is the CLI's).
  - `[false]` `[reject]` (edge) chmod docs claim a no-change rewrite writes no operation — the claim as a defect in behaviour is false (the code always writes, as the CLI: the rewrite is recorded in the parent mapping, `has_changes` true; tested by `an_unmatched_path_warns`); the doc sentence itself was misleading and is corrected in the patch round.
  - `[low]` `[patch]` (edge) remove hint docs — same as the blind hint-doc row.
  - `[low]` `[patch]` (edge) dead canonicalize — same as the blind row.
  - `[false]` `[reject]` (edge) `abandoned_change_ids` empty although `remove_workspace` abandons a discardable `@` — the field's contract (`mutate.rs:87`) excludes jj-lib's implicit abandon of a discardable `@`, as for `edit`/`new`.
  - `[low]` `[patch]` (edge) rename docs cite the CLI's named text that `jj.no_working_copy` does not carry — fixed: reworded (the CLI's refusal, reported without its text).
  - `[false]` `[reject]` (edge) no oracle scenario for "Cannot remove unreachable workspace" — the stock CLI cannot construct a workspace without a recorded path (pre-0.38 repos only); the refusal is covered by the Rust suite.
  - `[false]` `[reject]` (intent) I1's literal reading expects `jj.no_working_copy` on the wire — the run's rule makes CLI parity decisive: the CLI reports an omitted `@` as a revset-resolution user error, which 3ee3f29 already ports with its text; `jj.no_working_copy` stays the "requires a working copy" refusal. Recorded as I1 = rejected (no longer applies).
  - `[low]` `[patch]` (intent) the I1 witness covers only `file_list` and `restore` — fixed: the witness also runs `file_chmod(None)` and a commit-view `@` default.
  - `[false]` `[reject]` (intent) chmod parses paths as prefixes, not filesets — ADR-0003 / the 9.22 path rule (fileset DSL is terminal input language); the spec's Never.
  - `[false]` `[reject]` (intent) remove unlinks worktrees before deleting directories, against the addendum's prose order — `remove.rs` @ v0.46.0 unlinks first, then `remove_dir_all`; the code follows the CLI.

## Design Notes

- **I1 is already settled in code.** Commit 3ee3f29 (2026-10-23) made `ResolveError::NoWorkingCopy` carry jj-lib's `RevsetResolutionError::WorkspaceMissingWorkingCopy` text — the CLI's own user error for an omitted `-r @` — mapped to `jj.revset_resolution_error` (mutations, commit views) and `jj.invalid_input` (file reads). `jj.no_working_copy` stays the code for "this command requires a working copy" (lock-taking verbs), matching the CLI's split. This story adds the public-path witness and closes the ledger entry; no code change.
- **Store vs view.** forget keeps the store path (undo can re-point it); remove forgets it; rename renames it. The store is loaded afresh per call (`workspace::load_store`), as the CLI's start-up loads it.
- **remove snapshots other workspaces** with this call's config (the CLI builds them with `command.settings()`); each `for_workable_repo` reloads the environment, so its alias/immutable warnings repeat per workspace, as `workspace_add` already reports them twice.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`; targeted checks only.

**Commands:**
- `cargo make codegen` -- generated files committed; a second run leaves the tree unchanged.
- `cargo test -p zanshin-jj --lib`; `cargo test -p zanshin-jj --test it -- file_chmod:: workspace_ops:: workspace_add:: workspace_update_stale:: workspace:: file_track_untrack:: select_tree:: api_stability:: warnings::` -- pass.
- `cargo test -p zanshin-ffi --lib`; `cargo test -p zanshin-ffi --test it -- file_ops_ffi:: workspace_ffi:: ffi_abi_doc_sync::` -- pass.
- `cargo test -p zanshin-parity --test oracle` -- pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p test-helpers --all-targets -- -D warnings`; `cargo fmt --all --check` -- clean.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, `dart test` on the touched test files (real cdylib, test env as in 9.11) -- pass/clean.

**Outcomes (2026-10-24, final tree after the review patches; full gate not run per the run's gate rule):**
- `cargo make codegen` -- exit 0; a re-run left the tree unchanged.
- `cargo fmt --all --check` -- clean. `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity -p test-helpers --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj --lib` -- 370 passed. `cargo test -p zanshin-jj --test it -- file_chmod:: workspace_ops:: workspace_add:: workspace_update_stale:: workspace:: file_track_untrack:: select_tree:: api_stability:: warnings:: commit_views::` -- 234 passed (199 before the review's added tests, without `commit_views::`).
- `cargo test -p zanshin-ffi --lib` -- 215 passed. `cargo test -p zanshin-ffi --test it -- file_ops_ffi:: workspace_ffi:: ffi_abi_doc_sync::` -- 48 passed (102 exports).
- `cargo test -p zanshin-parity --test oracle` -- 403 passed (23 new Story 9.13 scenarios, no ledger entry).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed lib test` -- 0 changed; `dart test test/ffi/file_ops_test.dart test/ffi/workspace_test.dart test/ffi/warning_test.dart test/worker/file_ops_test.dart test/worker/workspace_test.dart` (JJ_*, GIT_CONFIG_GLOBAL, XDG_CONFIG_HOME pinned as `test-core`) -- 236 passed (real cdylib).
- Not run (gate rule): `cargo make test`, `test-full`, `coverage` -- the story loop runs the gate once at its end.

## Auto Run Result

Status: done

**Summary.** `jj file chmod`, `jj workspace forget`, `jj workspace rename` and the new jj 0.46 `jj workspace remove` are ported from the CLI at v0.46.0 end to end (`.fbs` → zanshin-jj → `zanshin_file_chmod` / `zanshin_workspace_forget` / `_rename` / `_remove` → `RepoHandle.fileChmod` / `workspaceForget` / `workspaceRename` / `workspaceRemove`; 102 exports). chmod resolves the revision (default `@`), guards rewritability, parses paths as `file track` does, warns unmatched paths, refuses non-file entries with the CLI's two texts, sets the bit on every file term (conflicts included) and finishes `make paths executable|non-executable in commit <hex>`. forget (default: the current workspace) warns unknown names, removes the rest in one transaction, keeps the store path and unlinks Git worktrees; rename renames the locked working copy, the view and the store in a raw commit `Renamed workspace 'a' to 'b'` and reloads the handle; remove refuses unreachable / inaccessible / repository-containing / foreign workspaces, snapshots each target, removes them in one transaction, forgets their store entries, unlinks worktrees and deletes the directories. New `WorkspaceRemoveResult { mutation, git_worktrees_removed, directories_removed }`; three new warning codes `jj.workspace_names_unmatched`, `jj.git_worktree_unlink_failed`, `jj.workspace_directory_remove_failed`; no new error code. Code commit: 2430c99f9c5eea2e502fcff81a72801b56521e05.

**Open items.**
- **I1** (a workspace with no `@` surfacing as `jj.jj_lib_error`) — rejected: no longer applies. Commit 3ee3f29 (2026-10-23) already made the omitted-`@` default return jj-lib's `RevsetResolutionError::WorkspaceMissingWorkingCopy` text, the CLI's own user error ("Workspace `default` doesn't have a working-copy commit"), as `jj.revset_resolution_error` (mutations, commit views) / `jj.invalid_input` (file reads); `jj.no_working_copy` stays the CLI's separate "requires a working copy" refusal. This story makes the state reachable through `workspace_forget` and adds the public-path witness `crates/zanshin-jj/tests/it/workspace_ops.rs::forget_the_current_workspace_then_at_defaults_refuse_with_the_clis_text` (file_list, restore, file_chmod, interdiff) in 2430c99; the deferred-work.md entry is struck as settled.

**Files changed.**
- `crates/zanshin-jj/src/workspace_ops.rs` (new) — forget / rename / remove, `WorkspaceRemoveResult`, load-error mapping, worktree unlink, inline tests.
- `crates/zanshin-jj/src/wc_ops.rs` — `file_chmod` + `chmod_refusal` (inline test); `select_tree.rs` / `workspace.rs` — `with_executable`, `load_store` made `pub(crate)`; `warning.rs` — three kinds; `repo.rs` — four facades; `lib.rs` — re-export.
- `schemas/envelope.fbs` + generated files — four request kinds, three request tables, `WorkspaceRemoveResult` payload.
- `crates/zanshin-ffi/src/{file_ops,workspace,envelope}.rs` — readers, four externs, result builder, warning codes.
- `packages/zanshin_core/lib/src/{ffi/file_ops,ffi/workspace,ffi/warning,worker/commands,worker/isolate,worker/handle}.dart`, barrel — adapters, model, commands, worker methods, `RepoHandle` methods, codes.
- Tests: `crates/zanshin-jj/tests/it/{file_chmod,workspace_ops}.rs` (new), `api_stability.rs`, `main.rs`, `workspace_update_stale.rs` (shared fixture); `crates/zanshin-ffi/tests/it/{file_ops_ffi,workspace_ffi,ffi_abi_doc_sync}.rs`; Dart `test/{ffi,worker}/{file_ops,workspace}_test.dart`, `test/ffi/warning_test.dart`; oracle `scenarios.rs`, `driver.rs` (`Symlink`, `RemoveDir` steps), `main.rs` (23 scenarios).
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`. Ledger: this spec, `sprint-status.yaml` (9-13 done), `deferred-work.md` (I1 struck, Story 9.13 section, nothing deferred).

**Review findings.** 25 findings (low 19, false 6). Patched 17 low (tests, docs, anchors): colocated FFI remove round trip asserting both result lists, chmod of file/file and file/symlink conflicts through the facade, remove stopping at a stale target, removing the handle's own secondary workspace (test + doc), the I1 witness widened to chmod and interdiff, a colocated-remove oracle scenario, the FFI tests' late canonicalize, absent-names forget and rename/remove null/zero-handle refusals, hint/rename/chmod doc corrections, the `executable` absent-default doc, `RepoHandle.workspaceRemove`'s doc, and every `remove.rs`/`forget.rs`/`rename.rs`/`chmod.rs` anchor. Nothing deferred. Rejected: rename-without-`@` not carrying the CLI's text (spec's `jj.no_working_copy` choice, as 9.49's commit; a text field is new public surface for a rare state), rename's reload skipped when `locked_ws.finish` fails after the commit (disk-failure-only path), and six false findings (no-op chmod — always writes like the CLI; `abandoned_change_ids` contract excludes implicit `@` abandon; unreachable oracle row not constructible by the CLI; I1 literal code reading vs CLI parity; prefix paths per ADR-0003; unlink-before-delete is the CLI's order).

**Follow-up review recommendation: false.** Patched at entry verdict: high 0, medium 0, low 17.

**Residual risks.** Coverage ratchet not run (gate rule): `workspace_ops.rs` is a new file that must reach the 80 % floor at the loop's final gate; its error-mapping arms are unit-tested. Rename without `@` reports `jj.no_working_copy` without the CLI's sentence. A rename whose working-copy finish fails after the commit leaves the handle on the old name until reopened. `remove` snapshots targets on the head operation rather than threading the CLI's `op_id` (differs only under a concurrent writer).
