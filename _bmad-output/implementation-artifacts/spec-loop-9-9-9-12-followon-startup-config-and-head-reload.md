---
title: 'Loop 9.9–9.12 follow-on — `workspace root` and `config edit` run the CLI start-up, every head load reconciles in this workspace'
type: 'bugfix'
created: '2026-10-24'
status: 'done'
baseline_revision: '746c9a7106b43a1f39b7893f1c868c56a49f42fb'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
warnings: ['multiple-goals', 'oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Three low CLI-parity gaps the loop 9.9–9.12 left, verified at `746c9a7`:
1. `Repo::resolve_workspace_root` (`crates/zanshin-jj/src/repo.rs:2343`, `&self`) calls `workspace::resolve_root` only — no secure-config fix-up, no stack load, no `jj.config_deprecated`, no refusal of a broken config. The CLI's `run_internal` (`cli_util.rs:4630-4750` @ v0.46.0) runs `reload_repo_config` (the fix-up), resolves + migrates, prints "Deprecated … config" and builds `UserSettings` for EVERY command; `jj workspace root --name` additionally runs `workspace_helper_no_snapshot` (`cli/src/commands/workspace/root.rs:42`: the alias tables, `immutable_heads()` / short-prefixes parse, `trunk()` fallback, the CLI's head load), the bare form only `workspace_loader()`.
2. The `jj config edit` halves (`config_cmd.rs` `file_read_with` `:1032`, `file_write_with` `:1070`) run `fix_up` alone, so they never warn `jj.config_deprecated`; the CLI's `jj config edit` prints it whenever its start-up stack resolves and migrates.
3. ~50 production `load_at_head()` sites across `crates/zanshin-jj/src/` reload the head after the precondition (or as a no-snapshot read) with jj-lib's `RepoLoader::load_at_head`, which reconciles divergent op heads WITHOUT a workspace name; the CLI's every head load (`load_from_workspace` → `resolve_operation`, `cli_util.rs:800-829`) reconciles in this workspace — `snapshot::load_head` (`snapshot.rs:313`) is that port.

**Approach:** (1) `resolve_workspace_root(&mut self, name) -> Result<PathBuf, WorkspaceError>`: the bare form runs the CLI's command start-up (fix-up + migrated stack + deprecations, nothing more), the named form `start_call` (the `workspace_helper_no_snapshot` start-up, as `op_integrate`); every warning, `jj.workspace_path_inaccessible` included, goes to the call's collector (`take_warnings`), no precondition report. (2) The editor halves try the start-up resolve after their fix-up and record its deprecations only when it succeeds. (3) Every production head load goes through the CLI's `load_head` (a crate helper returning jj-lib's flattened reason, so each caller keeps its own error variant).

## Boundaries & Constraints

**Always:**
- SAFETY: never `cd <name>` (zoxide may jump into a real repo of Ralph's); absolute paths only; run jj (stock or built) only inside temp dirs a test or you created.
- CLI v0.46.0 is the spec (`git -C ../jj show v0.46.0:<path>`). Warning order: fix-up notices, then deprecations, then the call's own (path-inaccessible last). A refused start-up keeps the warnings recorded before the refusal.
- Item 1: a broken stack (bad TOML, wrong-typed `user.*` the settings read) refuses BOTH forms as `WorkspaceError::Precondition(Config)` → `jj.config_error`; the named form also refuses what `start_call` refuses (bad alias table / `immutable_heads()`). `pending_precondition` is `None` after the call, `trunk_fallback` reset (as `op_integrate`). FFI `zanshin_workspace_root` builds its envelope through `precondition_envelope` (warnings on ok AND error envelope). No `.fbs` change; Dart decoder unchanged (it already reads envelope warnings, errors carry them).
- Item 2: `config edit` command name `"config edit"` for `--when.commands`; the try-load is `load_raw(env, paths, None)` + `resolve_raw(.., Some("config edit"))` (no second fix-up, no `settings_from` — the CLI prints deprecations before building settings); any failure is silently ignored (the repair path never refuses).
- Item 3: every non-test `.load_at_head()` call in `crates/zanshin-jj/src/` is replaced (including `rebase.rs` `load_dry_run_head`'s preview loader and `config_cmd.rs` `working_copy_author`); the error variant each site returns stays the same (only its reason text may now be the flattened source chain). Doc comments in `zanshin-jj/src` and `zanshin-ffi/src` that name the crate's own "`load_at_head` failed" become "the head load failed" (keep `snapshot.rs`' and `commit_content.rs`' explanatory contrasts).
- Docs: `docs/rust-error-codes.md` (`jj.config_deprecated` emitter clause: add `zanshin_workspace_root` and the two `config_file_*` halves "when their start-up stack resolves"; `jj.workspace_path_inaccessible` "ONLY warning" wording; the `:203` divergence bullet resolved; `jj.config_error` emitters if they list wrappers), `docs/ffi-abi.md` (`:157`, `:184`, `:204` lists, `:592` row gains `jj.config_error`).
- One code commit (`git commit --no-gpg-sign`, message ending `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`), on `main`; do NOT touch the spec / `deferred-work.md` / other specs (the orchestrator does the bookkeeping).

**Never:** No `VerbContext` repo hand-off (Design Notes); no change to `start_call`'s steps beyond extracting its first half; no change to test-module `load_at_head` calls; no new warning kind or error code; no `config edit` refusal on a broken stack; no full gate (`cargo make test` / `test-full` / `coverage`).

## I/O & Edge-Case Matrix

`D` = the "Deprecated user-level config: fix.tools.t.line-range-arg is updated to …" warning of a `JJ_CONFIG` holding `fix.tools.t.line-range-arg = "--l"`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| root bare, deprecated | `resolve_workspace_root(None)` | `Ok(workspace_root)`, `take_warnings() == [D]`, `take_precondition() == None` | — |
| root named, deprecated | `resolve_workspace_root(Some("default"))` | `Ok(recorded path)`, warnings `[D]` | — |
| root named, missing dir + deprecated | recorded dir deleted | `Ok(path)`, warnings `[D, path_inaccessible]` | — |
| root named, unknown + deprecated | `Some("nosuch")` | `Err(NotFound)`, warnings `[D]` | kept on the error |
| root, broken stack | repo config not valid TOML | bare AND named: `Err(Precondition(Config))` → `jj.config_error` | — |
| root, clean config | as today | as today, warnings empty (path-inaccessible only when the dir is gone) | — |
| edit halves, deprecated | `config_file_read` / `config_file_write` with and without a workspace root | `result` Ok, `warnings == [D]` | — |
| edit halves, broken stack | the edited file is not valid TOML | `config_file_read` Ok (text returned), `config_file_write` of valid TOML Ok; no `D`, no refusal | load failure ignored |
| head reload, divergent | two sibling ops published from one head, then a verb / read body called directly | the single op head is `reconcile divergent operations` naming THIS workspace | — |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/repo.rs:406-423` `start_call` -- extract its first half (`trunk_fallback = false`, `refresh_settings` with fix-ups, fresh report + collector, fix-ups extended, `refreshed?`, `load_migrated` + deprecations) into a private `start_command(&mut self) -> Result<StackedConfig, PreconditionError>` (doc: `run_internal`'s part every command runs); `start_call` calls it, then colocated / env / trunk unchanged.
- `crates/zanshin-jj/src/repo.rs:2321-2345` `resolve_workspace_root` -- `&mut self`, `Result<PathBuf, WorkspaceError>`: `None` → `start_command()` then `workspace_root()`; `Some` → `start_call()` then `workspace::resolve_root(&self.workspace, name, &mut self.pending_warnings)`; afterwards `pending_precondition = None`, `trunk_fallback = false` (mirror `op_integrate` `:1607-1617`). Rewrite its doc (start-up, warnings via `take_warnings`, can now fail on both forms). Docs `:561` (still no precondition report — keep) and `:576` (warnings: it now resets and records them — move it out of that list).
- `crates/zanshin-jj/src/workspace.rs:181-220` `resolve_root` -- drop the `None` arm (the `Repo` handles it) or keep it trivially; take `sink: &mut Warnings`, return `PathBuf`, push the inaccessible-path warning into the sink; head via item 3's helper. Docs `:60-70` (`WorkspaceError` doc), `:158`, `:196`.
- `crates/zanshin-jj/src/snapshot.rs:305-331` `load_head` -- add `pub(crate) fn load_head_with(loader: &RepoLoader, workspace_name: &WorkspaceName) -> Result<Arc<ReadonlyRepo>, String>` (the body, `flatten_chain` for both failures) and `pub(crate) fn reload_head(workspace: &Workspace) -> Result<Arc<ReadonlyRepo>, String>`; `load_head` = `reload_head(w).map_err(PreconditionError::Backend)`. Docs: why (the CLI's head load; jj-lib's reconciles without a name).
- Item 3 sites (all `PROD` hits of `grep -n "load_at_head()" crates/zanshin-jj/src/*.rs` before the file's `#[cfg(test)]`): `arrange.rs:340`, `bookmark_ops.rs:241/358/580/673/754`, `bookmarks.rs:492`, `change.rs:167`, `commit.rs:163`, `commit_views.rs:423/480/574`, `config_cmd.rs:1002` (`.ok()?`), `duplicate.rs:199`, `file.rs:269`, `fix.rs:545`, `git.rs:347/665`, `graph.rs:346`, `metaedit.rs:162`, `mutate.rs:1041/1245/1358/1436/1589/1881/2036`, `op_log.rs:111/509/573`, `parallelize.rs:37`, `push.rs:1853`, `rebase.rs:387` and `:452` (`load_dry_run_head(loader)` → also take the workspace name, call `load_head_with(&preview, name)`; caller `drop_actions.rs:507`), `remotes.rs:120/513`, `revset.rs:102/174`, `select_tree.rs:252`, `squash_split.rs:432/506/768`, `status.rs:98`, `topology.rs:154`, `view.rs:93/150/168`, `wc_ops.rs:426/546`, `workspace.rs:207`. Pattern: `pollster::block_on(X.repo_loader().load_at_head()).map_err(be)?` → `crate::snapshot::reload_head(X).map_err(be)?` (`be`, `jj`, `re`, `mutate::be` take `Display`; `revset.rs` closure → `RevsetError::JjLibError`).
- `crates/zanshin-jj/src/config_cmd.rs:534-561` -- new private `fn startup_deprecations(env, ws, warnings)` next to `fix_up` (doc: the CLI's start-up resolve, tried — recorded only when it resolves and migrates, never refusing the repair path); called by `file_read_with` / `file_write_with` right after `fix_up`. Docs: module doc `:36-41`, `config_file_read` `:439-450`, `config_file_write` `:454-466`, `fix_up` `:532-533`; `config.rs:41` module doc and `fix_up_layers` `:968-973` if they say the halves warn nothing.
- `crates/zanshin-ffi/src/workspace.rs:280-333` `zanshin_workspace_root` -- `precondition_envelope(&mut session.repo, result, map_workspace_err, |root, report| workspace_root_to_envelope(root, report))`; doc: start-up warnings (`jj.config_migrated` / `_copied` / `_regenerated`, `jj.config_deprecated`, the named form's alias warnings), `# Errors` gains `jj.config_error` (and `jj.jj_lib_error` wording "the head load"). Config editor externs' docs in `crates/zanshin-ffi/src/config.rs` if they say no `jj.config_deprecated`. Run `cargo make codegen` (header/bindings comments) and commit its output.
- Tests to adapt: `crates/zanshin-jj/tests/it/workspace.rs` (~15 call sites `.value` / `Warned`), `convert.rs:1074-1080`, `repo.rs:385-391`, `snapshot_precondition.rs:311`, `workspace_add.rs:184`; `api_stability.rs:864-894` pin → `fn(&mut zanshin_jj::Repo, Option<&str>) -> Result<std::path::PathBuf, zanshin_jj::WorkspaceError>` (comment: start-up like `op_integrate`); `crates/zanshin-ffi/tests/it/` workspace-root tests (grep `zanshin_workspace_root`); `packages/zanshin_core` workspace-root tests only if they assert "no warnings" on a deprecated config (they run under the pinned env — likely untouched).
- New witnesses: item 1 and 2 rows — an own-process test (`test_helpers::own_process!`, repoint `JJ_CONFIG` like `crates/zanshin-jj/tests/it/config_cmd.rs` `a_deprecated_user_key_warns_on_config_gc` / `config_cmd_user.rs`); broken-stack rows — write invalid TOML into the repo's secure config (see how `creation_warnings.rs` / `config_cmd.rs` tests locate it) or a `JJ_CONFIG` file. Item 3 — inline test in `snapshot.rs` `#[cfg(test)]` built like `op_log.rs:1060-1117` (`start_repo_transaction` siblings off `load_head`): `reload_head` and `load_head_with` reconcile naming this workspace; plus `status::working_copy_status` and one `mutate.rs` verb body called directly reconcile the same way; plus a source guard test: no `src/*.rs` file has a `.load_at_head()` call before its first `#[cfg(test)]` outside comments.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/snapshot.rs` -- `load_head_with` / `reload_head`; inline divergent-reload + guard tests -- item 3 core.
- The item-3 site files listed in the Code Map -- swap each head load; fix touched `# Errors` docs -- item 3.
- `crates/zanshin-jj/src/repo.rs`, `workspace.rs` -- `start_command`, new `resolve_workspace_root`, `resolve_root` sink -- item 1.
- `crates/zanshin-jj/src/config_cmd.rs` (+ `config.rs` docs) -- `startup_deprecations` in both halves -- item 2.
- `crates/zanshin-ffi/src/workspace.rs` (+ `config.rs` docs), codegen output -- item 1 wire.
- `crates/zanshin-jj/tests/it/{workspace,convert,repo,snapshot_precondition,workspace_add,api_stability,config_cmd or config_cmd_user}.rs`, zanshin-ffi tests -- adapt + the matrix rows.
- `docs/rust-error-codes.md`, `docs/ffi-abi.md` -- emitter clauses and lists.

**Acceptance Criteria:**
- Given a deprecated user key, when `zanshin_workspace_root` runs (bare, named, named-unknown), then its envelope (ok or error) carries `jj.config_deprecated` first, and a broken stack answers `jj.config_error`.
- Given a deprecated user key, when either `config edit` half runs, then its outcome warns it once; given a broken stack, then neither half refuses because of it.
- Given the source tree, when the guard test runs, then no production `.load_at_head()` call remains in `crates/zanshin-jj/src`.
- Given the targeted checks below, then each passes and the tree is clean after the code commit.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 29 findings — high 0, medium 0, low 23, false 6, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind) `load_dry_run_head` reconciled divergent heads through the preview loader, so a read-only drop-actions query could publish a reconcile whose rebased commits are written under `signing.behavior = "drop"` (the nameless pre-change `load_at_head` on that loader did the same) — now reconciles through the workspace's own loader (`reload_head`), then `preview.load_at(head.operation())`; `load_head_with` folded back; witness case `load_dry_run_head` in `snapshot::tests::every_head_load_reconciles_divergent_heads_in_this_workspace`, commit 80b3f09.
  - `[low]` `[patch]` (blind) the source guard cut each file at the first textual `#[cfg(test)]`, which sits in a comment at `op_support.rs:171` (lines 172-902 unscanned), and read only the top level of `src/` — now stops at the first line that is exactly `#[cfg(test)]` and walks `src/` recursively, commit 80b3f09.
  - `[low]` `[patch]` (blind) Dart `workspaceRoot` docs (`handle.dart`, `isolate.dart`, `ffi/workspace.dart`) still said the bare form cannot fail / writes nothing and lacked `jj.config_error` — updated, commit 80b3f09.
  - `[low]` `[patch]` (blind) the `workspace.rs` module docs (zanshin-jj, zanshin-ffi) still promised no operation is ever written — reworded: no transaction; only a reconciling head load (or the list's snapshot) may write, commit 80b3f09.
  - `[low]` `[patch]` (blind) test assertion messages ("the no-name default cannot fail", "never warns", "the loader-only path cannot fail") contradicted the new failure mode — reworded, commit 80b3f09.
  - `[low]` `[reject]` (blind) ADR-0002, the `jj.jj_lib_error` registry row and `ffi-abi.md:1586` still name `load_at_head` — prose naming the failure point of a head load; the ADR's decision (reload per call) stands, and the guard test refuses any new `load_at_head` call a reader might copy from it.
  - `[low]` `[reject]` (blind) both editor halves warn, so one GUI edit (read + write) surfaces the deprecation twice — each half is its own call with its own warning list, as the `config gc` pair (Story 9.9 closing run rejected the same double warning); the ledger item names both functions.
  - `[false]` `[reject]` (blind) the "CLI's repair path" wording is wrong because the CLI refuses a broken stack — the phrase (Story 9.37) means the user's own editor, the CLI user's repair path outside jj; the non-refusing halves are that stand-in, and the intent requires that a failing load not refuse.
  - `[low]` `[patch]` (blind) documented behaviours untested (fix-up notices first, the named form's alias / `trunk()` warnings, reconcile) — the `trunk()` fallback on the named form got a witness (see the verification-gap row); the rest are `start_call` / `reload_head` behaviour shared with every start-up verb and pinned there (`snapshot_precondition.rs`, `every_head_load_reconciles…`).
  - `[low]` `[patch]` (blind) the `Precondition` error docs omitted `PreconditionError::Backend` from the named form's colocation check / environment / `trunk()` head load — added to `WorkspaceError::Precondition`, `resolve_workspace_root` and `zanshin_workspace_root` docs, commit 80b3f09.
  - `[low]` `[reject]` (blind) the reconcile description exists twice (`snapshot.rs` literal, `op_log::RECONCILE_DESCRIPTION`) — pre-existing (both predate this change), and every reconcile witness asserts the exact CLI string, so a drift fails a test.
  - `[low]` `[reject]` (blind) the bare root resolves with command `None` for `--when.commands` — pre-existing for every Zanshin start-up but the config verbs, tracked by Story 9.41 (`9-41-when-commands-config-scopes-per-verb`), as the 9.9 closing run recorded.
  - `[low]` `[patch]` (edge) guard blind spot — same root as the blind guard row; fixed with it, commit 80b3f09.
  - `[low]` `[patch]` (edge) preview loader publishes a drop-signed reconcile — same root as the blind dry-run row; fixed with it, commit 80b3f09.
  - `[low]` `[reject]` (edge) the named form loads the store after the start-up, while the CLI loads it when it loads the workspace (before the environment) — only differs when the store is unloadable AND the config is broken (two faults at once; the open `Repo` already loaded the store once); a reorder would split `resolve_root` for no everyday case.
  - `[low]` `[patch]` (verification-gap) the named root's `trunk()` fallback warning and its one-call reset were unpinned — `repo::tests::the_trunk_fallback_ends_with_its_call` extended: named root with an unresolvable `trunk()` returns the path, warns `TrunkAliasUnresolved`, `trunk_fallback()` false afterwards, commit 80b3f09.
  - `[low]` `[patch]` (verification-gap) `config_file_write`'s "stack BEFORE the write" was unpinned — `a_deprecated_user_key_warns_on_both_config_edit_halves` also writes the user file without the key and still gets the one `ConfigDeprecated`, commit 80b3f09.
  - `[low]` `[patch]` (verification-gap) the halves' "fix-up notices, then deprecations" order was unpinned — new own-process `config_cmd::the_editor_half_warns_the_fix_up_before_the_deprecations` (legacy repo config + valid deprecated `JJ_CONFIG` → exactly `[ConfigMigrated, ConfigDeprecated]`), commit 80b3f09.
  - `[low]` `[patch]` (verification-gap, other) stale Dart `workspaceRoot` docs — same as the blind Dart-docs row; fixed with it.
  - `[false]` `[reject]` (intent) item 1 goes beyond "loads no config stack" by also running `workspace_helper_no_snapshot`'s start-up on the named form — the item says "as every other command does" and CLI parity is never Ralph's decision; the CLI's named path runs exactly that (`root.rs:42` @ v0.46.0).
  - `[low]` `[reject]` (intent) the warning channel moved from `Warned` to `take_warnings` — `Warned` exists only on `Ok`, so a refusal would drop the start-up's warnings; `take_warnings` is the channel every start-up-running `Repo` verb uses (`op_integrate`), and the envelope carries the warnings on ok and error.
  - `[false]` `[reject]` (intent) the "never writes an operation" guarantee was replaced — the CLI's `workspace root --name` loads the head through `load_from_workspace` and so reconciles too; the docs now say so (module docs patched).
  - `[low]` `[patch]` (intent) stale Dart doc for the bare form — same as the blind Dart-docs row; fixed with it.
  - `[low]` `[reject]` (intent) no parity-oracle scenario was added — the expected strings are the CLI's verbatim text at v0.46.0 (`cli_util.rs:4726-4741`, `root.rs:60-66`) and the oracle (330 scenarios) stayed green; adding scenarios is beyond the three items.
  - `[low]` `[reject]` (intent) item 2 warns on each half, not once per edit — same as the blind double-warning row.
  - `[false]` `[reject]` (intent) item 2's non-refusing repair path follows the intent, not the CLI — the intent states it explicitly ("a failing load must not refuse the repair path").
  - `[low]` `[reject]` (intent) item 3 is witnessed only through crate-internal calls and a source scan — the snapshot-to-reload window cannot be hit deterministically through the public API (the precondition's own reconciling load runs first); the internal witnesses plus the guard cover every site.
  - `[false]` `[reject]` (intent) item 3 does not reproduce the CLI's no-reload flow — the ledger offers `load_head` crate-wide as a fix; Design Notes record why the hand-off is not worth it (no observable difference beyond the race window).
  - `[false]` `[reject]` (intent) item 3 also changes no-snapshot reads — every CLI command loads its head through `load_from_workspace`, snapshot or not, so those loads are the CLI's too.

## Design Notes

- **Why `load_head` everywhere and not the precondition's repo through `VerbContext`.** The CLI runs the verb on the repo its snapshot left; Zanshin reloads. The two differ only inside a race window (another process writing between the snapshot and the reload): with the reload the verb sees that operation (merged in THIS workspace if it diverged), the CLI would commit beside it and leave the next command to reconcile. Neither is deterministically observable; the reconcile's `workspace_name` — the one observable fact the ledger names — is the CLI's with `load_head`. The hand-off would rewrite ~50 verb/read bodies plus the stale-recovery return path for no testable difference; Story 9.12's closing run chose `load_head` for the same reason.
- **Why the bare `workspace root` loads no alias tables.** The CLI's bare form never builds a workspace helper (`root.rs:75`): `run_internal`'s config start-up only. The named form builds it (`workspace_helper_no_snapshot`), so it gets `start_call`.

## Verification

**Commands (targeted; the orchestrating session runs the full gate — no `cargo make test` / `test-full` / `coverage`):**
- `cargo test -p zanshin-jj --lib` -- expected: pass.
- `cargo test -p zanshin-jj --test it` -- expected: pass (every module: item 3 touches every verb).
- `cargo test -p zanshin-ffi --lib` and `cargo test -p zanshin-ffi --test it` -- expected: pass.
- `cargo test -p zanshin-parity --test oracle` -- expected: pass.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` -- expected: clean.
- `cargo make codegen` -- expected: only doc-comment drift, committed.
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings`, `dart format --set-exit-if-changed lib test`, and the workspace/config tests (`dart test test/ffi/workspace_test.dart test/ffi/config_test.dart` or the files that exist, with the gate's pinned env) -- expected: pass.

**Verification notes (2026-10-24, after the review patches, HEAD 80b3f0950181b9780e08949d8d5cbc87ed2de837; no `cargo make test` / `test-full` / `coverage` per the gate rule):**
- `cargo test -p zanshin-jj --lib` — 353 passed (incl. `snapshot::tests::every_head_load_reconciles_divergent_heads_in_this_workspace`, `snapshot::tests::no_production_code_calls_load_at_head`, `repo::tests::the_trunk_fallback_ends_with_its_call`).
- `cargo test -p zanshin-jj --test it` — 1221 passed, 1 ignored (pre-existing).
- `cargo test -p zanshin-ffi --lib` — 214 passed; `cargo test -p zanshin-ffi --test it` — 350 passed (incl. `ffi_abi_doc_sync`, `workspace_ffi::workspace_root_carries_the_start_up_deprecation_on_either_envelope`, `workspace_ffi::workspace_root_refuses_a_broken_config_stack_on_both_forms`).
- `cargo test -p zanshin-parity --test oracle` — 330 passed.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`, `cargo fmt --all --check` — clean.
- `cargo make codegen` — no drift (the header / `bindings.dart` doc-comment changes are committed in 2b7076d and 80b3f09).
- `packages/zanshin_core`: `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --set-exit-if-changed lib test` — 0 changed; with the gate's pinned env (`JJ_CONFIG=""`, `XDG_CONFIG_HOME=target/test-xdg-config`, …) `dart test test/worker/{workspace,config,warnings,secure_config,drop_actions}_test.dart` — 45 passed.
- Matrix audit: root bare / named / missing dir / unknown with `D` — `workspace::both_forms_of_root_warn_the_start_up_deprecations` (+ FFI `workspace_root_carries_the_start_up_deprecation_on_either_envelope`); broken stack — `workspace::a_broken_config_stack_refuses_both_forms_of_root` (+ FFI twin); clean config — the pre-existing `workspace::` root tests (warnings empty); edit halves with `D` (with and without a root) — `config_cmd::a_deprecated_user_key_warns_on_both_config_edit_halves`; edit halves, broken stack — `config_cmd::a_broken_stack_refuses_neither_config_edit_half`; head reload, divergent — `snapshot::tests::every_head_load_reconciles_divergent_heads_in_this_workspace`. All ran and passed.

## Auto Run Result

Status: done

**Items:**
- **1 — fixed (2b7076d7f28743f95f5020c87a91145cf260dd96; review patches 80b3f0950181b9780e08949d8d5cbc87ed2de837).** Verified real at `746c9a7`: `resolve_workspace_root` called `workspace::resolve_root` only. Now both forms run the CLI's command start-up (`Repo::start_command`, extracted from `start_call`: secure-config fix-up, migrated stack, `jj.config_deprecated`; a broken stack refuses as `jj.config_error`); the named form runs `start_call` (the `workspace_helper_no_snapshot` start-up: alias tables, `immutable_heads()` / short-prefixes, `trunk()` fallback). `resolve_workspace_root(&mut self, name) -> Result<PathBuf, WorkspaceError>`; every warning (start-up first, `jj.workspace_path_inaccessible` last) goes through `take_warnings`, so `zanshin_workspace_root` carries them on the ok and the error envelope (`precondition_envelope`, no precondition report).
- **2 — fixed (2b7076d7f28743f95f5020c87a91145cf260dd96; review patches 80b3f0950181b9780e08949d8d5cbc87ed2de837).** Verified real: the halves ran `fix_up` alone. Both now try the start-up resolve (`load_raw` without a second fix-up + `resolve_raw(.., Some("config edit"))`) right after the fix-up and record its deprecations only when it succeeds; a stack that does not load is ignored, never refused.
- **3 — fixed (2b7076d7f28743f95f5020c87a91145cf260dd96; review patches 80b3f0950181b9780e08949d8d5cbc87ed2de837).** Verified real: ~50 production `load_at_head()` sites. Every one now goes through `snapshot::reload_head` (the CLI's `load_from_workspace`: divergent heads reconciled in this workspace), each site keeping its error variant; the rebase / drop-actions preview reconciles through the workspace's own loader, then loads the preview at that operation (so a reconcile keeps the real signing settings). A source guard test keeps `load_at_head` out of production code. The `VerbContext` hand-off was not taken: it differs from the reload only inside a non-deterministic race window (Design Notes).

**New findings:** none deferred (`deferred: []`; nothing mirrored to deferred-work.md).

**Files changed:**
- `crates/zanshin-jj/src/repo.rs` — `start_command`, new `resolve_workspace_root`, `take_warnings` / `start_call` docs, trunk-fallback test case.
- `crates/zanshin-jj/src/workspace.rs` — `resolve_root(workspace, name, sink) -> PathBuf`, docs.
- `crates/zanshin-jj/src/config_cmd.rs` (+ `config.rs` module doc) — `startup_deprecations` in both editor halves.
- `crates/zanshin-jj/src/snapshot.rs` — `reload_head`; divergent-reload and source-guard tests.
- The head-load sites in `arrange`, `bookmark_ops`, `bookmarks`, `change`, `commit`, `commit_views`, `config_cmd`, `drop_actions`, `duplicate`, `file`, `fix`, `git`, `graph`, `metaedit`, `mutate`, `op_log`, `parallelize`, `push`, `rebase`, `remotes`, `revset`, `select_tree`, `squash_split`, `status`, `topology`, `view`, `wc_ops`, `workspace` (`crates/zanshin-jj/src/`) — `reload_head`; "the head load" in their docs.
- `crates/zanshin-ffi/src/workspace.rs`, `config.rs`, `commit_contents.rs` docs; `zanshin_ffi.h`, `bindings.dart` regenerated (doc comments).
- `packages/zanshin_core/lib/src/{ffi/workspace.dart,worker/handle.dart,worker/isolate.dart}` — `workspaceRoot` docs.
- Tests: `crates/zanshin-jj/tests/it/{workspace,config_cmd,convert,repo,workspace_add,api_stability}.rs`, `crates/zanshin-ffi/tests/it/workspace_ffi.rs`.
- Docs: `docs/rust-error-codes.md`, `docs/ffi-abi.md`.
- Ledger: `deferred-work.md` (three bullets RESOLVED), `resolved:` fields in `spec-9-9-closing-config-deprecated-every-start-up.md` (items 1, 2) and `spec-9-12-closing-status-without-at-and-head-reload.md` (item 3), this spec.

**Review:** 29 findings (low 23, false 6). Patched (9 entries, all low): the preview loader's drop-signed reconcile, the source guard's blind spot, stale Dart / module docs, stale test messages, `PreconditionError::Backend` in the root docs, and three witnesses (named-root `trunk()` fallback + reset, the write half's pre-write stack, fix-up-before-deprecation order). Rejected: `load_at_head` prose in the ADR / registry (guard catches copies), the per-half double warning (each half its own call, as `config gc`), the duplicated reconcile literal (pre-existing, asserted by tests), `--when.commands` (Story 9.41), store-load order (two simultaneous faults), the warning-channel move (`Warned` loses warnings on refusals), no oracle scenario, internal-only item-3 witnesses (window not reachable through the public API); false: the repair-path wording, item 1's full start-up scope, the operation-write guarantee, item 2's non-refusal (the intent's own rule), the no-hand-off choice, no-snapshot reads' scope.

**Follow-up review recommended:** false — patched entries at entry verdict: high 0, medium 0, low 9.

**Residual risks:** coverage not measured (gate rule); the new lines have witnesses, the item-3 swaps are one-for-one. The full gate runs in the orchestrating session. A pre-existing stale bullet in `docs/rust-error-codes.md` (~line 200) still calls the `trunk()` fallback unported although Story 9.56 ported it — not touched (outside the three items).
