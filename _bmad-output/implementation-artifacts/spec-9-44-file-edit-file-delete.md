---
title: 'Story 9.44: `file edit`, `file delete` — rewrite a file in any revision without touching the working copy (jj 0.46)'
type: 'feature'
created: '2026-10-25'
status: 'done'
baseline_revision: '760bef138f6c9bef185b610c2ad167a762e301f7'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** jj 0.46 added `jj file edit [-r REV=@] [--restore-descendants] FILE` (`cli/src/commands/file/edit.rs` @ v0.46.0) and `jj file delete [-r REV=@] [--restore-descendants] FILESETS…` (`file/delete.rs`), which rewrite one revision's tree without checking it out; Zanshin has neither, so the GUI cannot "edit/delete this file in that commit" (deferred-work I1, Story 9.44's part).

**Approach:** Port both verbs step for step through the full chain (`.fbs` → `zanshin-jj` → `extern "C"` → `WorkerCommand`/`RepoHandle`), modelled on `file chmod` (Story 9.13) and `diffedit` (9.17). `file_edit` replaces the editor (ADR-0003): the GUI passes the NEW file bytes, and the backend runs the CLI's own mechanism — a sparse `TreeState` in a temp dir holding only that path, checked out from the revision's tree (conflicts materialized with `ui.conflict-marker-style`), the GUI's bytes written where the editor would save, then snapshotted — so conflict markers parse back, the executable bit is kept and an unchanged buffer is "Nothing changed." exactly as in the CLI.

## Boundaries & Constraints

**Always:**
- Behavior = the CLI @ v0.46.0, in its order: resolve the revision (`None` = `@`), `check_rewritable`, parse the path(s), then the per-verb checks; descendants rebased, or reparented with `restore_descendants` (`rebase_or_reparent_descendants`, `cli_util.rs:3418-3440`); op descriptions byte-identical: `edit file <internal path> in commit <commit hex>`, `delete paths in commit <commit hex>`.
- "Nothing changed." (new tree ids == the revision's) is the house no-op result: no operation written, the pre-call head op id returned. It comes after the rewritability guard (an immutable revision refuses even when nothing would change).
- `file_edit` refusals, CLI text verbatim, `jj.invalid_input`: `Path is a directory: <ui path>`, `Path '<ui path>' is not a regular file` (symlink, submodule), `Path '<ui path>' has a non-file conflict and cannot be edited` (a conflict term that is not a file and not absent). An absent path is created (non-executable); an existing file keeps its executable bit; a conflicted file's buffer is the same text `file_show` returns, and an unchanged buffer is a no-op, an edited side stays conflicted, a marker-free buffer resolves it.
- `file_delete` paths parse exactly as `file chmod`'s (`wc_ops::parse_paths`: at least one — an empty list refuses `jj.invalid_input` "file delete requires at least one path" BEFORE the pre-verb snapshot (clap's `required`); prefixes, no fileset DSL — ADR-0003); an explicit path matching nothing warns `jj.paths_unmatched` (`print_unmatched_explicit_paths`); every matched entry is removed (`Merge::absent()`), conflicts included.
- `file_edit`'s `path` parses as `file show`'s (`op_support::parse_prefixes`, one entry, workspace-root relative; `""` is the root, which then refuses as a directory). The verbs resolve their config per CLI command name (`cli_command::FILE_EDIT = "file edit"`, `FILE_DELETE = "file delete"`).
- FFI: `content` and `path` are required — an ABSENT one refuses `jj.invalid_input` before the snapshot; an EMPTY `content` vector is an empty file (the Dart adapter always sends the vector).

**Never:** No editor, `$EDITOR`, temp-dir-left-behind recovery or `ui.status` chatter (terminal UX); no new error codes; no MCP surface (the `zanshin-mcp` crate is an empty placeholder); never write into the user's working copy (only through `finish_verb`'s normal checkout when `@` is rewritten); no change to existing verbs.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Edit in `@` | `file_edit(None, false, "a.txt", b"new\n")` | `@`'s `a.txt` = `new\n`; op `edit file a.txt in commit <old @ hex>`; on disk `a.txt` = `new\n` | — |
| Edit `-r`, descendants | `-r A` (child B inherits the file) | A has the new content, B rebased and shows it | — |
| `restore_descendants` | same, `true` | A changed, B's content unchanged (reparented) | — |
| New file | path absent in the revision, incl. `dir/new.txt` with `dir` absent | file created non-executable (missing parent dirs created in the temp working copy) | — |
| Executable kept | executable `script.sh`, new bytes | still `executable: true` | — |
| Unchanged buffer | bytes == current content | no-op result, no operation | — |
| Conflict | content = `file_show`'s materialized text | unchanged → no-op; one side edited inside the markers → still conflicted; markers removed → resolved file | — |
| Empty content | `b""` | empty file in the revision | — |
| Directory / symlink / non-file conflict | `dir`, a symlink, a file-vs-symlink conflict | — | `jj.invalid_input`, CLI text, no operation |
| Ancestor is a file | `a.txt/x` where `a.txt` is a file | — | `jj.invalid_input` "Failed to edit file: '<ui path of a.txt>' is not a directory", no operation (see Design Notes) |
| Immutable | root or an immutable revision, unchanged buffer too | — | `jj.immutable` |
| Delete | `file_delete(None, false, ["dir"])` | every entry under `dir` removed; op `delete paths in commit <hex>` | — |
| Delete unmatched | `["nope"]` only | `jj.paths_unmatched` warning AND no-op result (tree unchanged) | — |
| Delete, no paths | `[]` | — | `jj.invalid_input` before the snapshot, no operation |
| FFI absent field | `FileEditRequest` without `path` or `content` | — | `jj.invalid_input` before the snapshot |

</intent-contract>

## Code Map

- `../jj` @ v0.46.0 (`git -C ../jj show v0.46.0:<path>`): `cli/src/commands/file/edit.rs` (`cmd_file_edit`: TreeState settings `EolConversionMode::None`, `ExecChangeSetting::Auto`, `FsmonitorSettings::None`; `set_sparse_patterns(vec![path])`, `check_out(&tree)`, snapshot with `GitIgnoreFile::empty()`, `EverythingMatcher`/`NothingMatcher`, `max_new_file_size: u64::MAX`), `file/delete.rs`, `cli_util.rs:3418` (`rebase_or_reparent_descendants`); tests `cli/tests/test_file_edit_command.rs`, `test_file_delete_command.rs` (the matrix's cases come from them).
- jj-lib 0.46.0 (vendored: `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.46.0/src/local_working_copy.rs`): `TreeState::init` (:1054), `working_copy_path` (:1034), `current_tree` (:1038), `snapshot` (:1295, async → `pollster::block_on`), `check_out` (:2290), `set_sparse_patterns` (:2299). Racy-clean is handled (`own_mtime`, :1952), so writing right after `check_out` is detected.
- `crates/zanshin-jj/src/wc_ops.rs` -- `parse_paths` (:384), `prefix_matcher`, `chmod_refusal` (:596), `file_chmod` (:614-660): the template for both new fns (reload_head → `start_repo_transaction` → `mutate::resolve_or_wc` → `mutate::guard_rewritable` → paths → `warning::warn_unmatched_paths` → `MergedTreeBuilder` → `rewrite_commit(..).set_tree(..)` → `finish_verb` → `mutation_result`). Put `file_edit` and `file_delete` here.
- `crates/zanshin-jj/src/diffedit.rs:114-134` -- the no-op (`drop(tx); no_op_result(&workspace_name, &readonly)`) and the explicit `reparent_descendants()` / `rebase_descendants()` before `finish_verb`; copy that shape.
- `crates/zanshin-jj/src/config.rs:1533` -- `conflict_marker_style(&ctx.config)` (map like `select_tree.rs:280`'s `cfg`); `crate::warning::ui_path(root, &path)` -- the CLI's `format_file_path`; `crate::op_support::parse_prefixes` (used by `file.rs:257` `parse_path`).
- `crates/zanshin-jj/src/repo.rs` -- `Repo::file_chmod` (:4325-4370, rustdoc `# Errors` style + `with_checked_verb` pre-snapshot arg refusal), `with_checked_verb` (:550); unit test `every_verb_resolves_for_its_cli_command` (:4814, add `records!` lines as at :4992-4999). New: `Repo::file_edit(&mut self, revision: Option<&ChangeId>, restore_descendants: bool, path: &str, content: &[u8])` and `Repo::file_delete(&mut self, revision: Option<&ChangeId>, restore_descendants: bool, paths: &[String])`, both `-> Result<MutationResult, MutateError>`.
- `crates/zanshin-jj/src/cli_command.rs` -- table (:37), add `FILE_DELETE = "file delete"`, `FILE_EDIT = "file edit"` alphabetically; its audit test checks them against the pinned `jj_cli` app.
- `crates/zanshin-jj/Cargo.toml` -- `tempfile` is dev-only (:49); add `tempfile = { workspace = true }` to `[dependencies]` (already in the lock via jj-lib; no new crate).
- `crates/zanshin-jj/tests/it/file_chmod.rs` -- fixture `Fx`/`fx()` (:19-55: Git repo with `dir/a.txt`, `dir/b.txt`, `top.txt`, symlink `link`, empty `@`) and helpers; `tests/it/rebase.rs:26-192` shared helpers (`no_op`, `immutable`, `refused`, …) used by `tests/it/diffedit.rs`; `tests/it/main.rs` module list; `tests/it/api_stability.rs` (:1210 chmod cast pattern).
- `schemas/envelope.fbs` -- `enum RequestKind` (:158, append-only, last `FindChanges` :229) → append `FileEdit`, `FileDelete`; `FileChmodRequest` (:1166-1179) doc+table pattern; payload is the existing `MutationResult`. Then `cargo make codegen` (`Makefile.toml:532`) and commit `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `packages/zanshin_core/lib/src/ffi/bindings.dart` (check `packages/zanshin_core/ffigen.yaml` allow-list for new symbols).
- `crates/zanshin-ffi/src/file_ops.rs` -- `read_file_chmod_request` (:101), `zanshin_file_chmod` (:356, `catch` + `session_from_handle` + `precondition_envelope(.., map_mutate_err, ok_mutation_result)`); add `zanshin_file_edit` / `zanshin_file_delete` with rustdoc `# Errors` bullets (checked against `docs/ffi-abi.md` by `tests/it/ffi_abi_doc_sync.rs`).
- `crates/zanshin-ffi/tests/it/file_ops_ffi.rs` -- `chmod_request_bytes` (:445), `chmod_round_trips_through_mutation_result` (:473), `chmod_refusals_cross_the_wire` (:499): mirror per verb.
- `packages/zanshin_core/lib/src/ffi/file_ops.dart:63` (`zanshinFileChmod`), `lib/src/worker/commands.dart:1743` (`FileChmodCommand`), `lib/src/worker/isolate.dart` (client `fileChmod` :3280, dispatch `case FileChmodCommand(` :5035), `lib/src/worker/handle.dart:2580` (`RepoHandle.fileChmod`); tests `test/worker/file_ops_test.dart:228` (real cdylib — one per extern fn, the ratchet's extern-fn guard) and `test/ffi/file_ops_test.dart:207`.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` -- chmod scenarios (:4866-4925, `simple(id, zanshin, cli)`, `Scenario { setup, .. }`), editor steps via `ui.editor` scripts (:396-420, e.g. `["sh","-c","… > \"$1\"","sh","$path"]`), master list (:3011); `tests/oracle/main.rs` `parity!` id list (chmod :319-325); `ledger.rs` (add only if a divergence is real).
- `docs/ffi-abi.md` -- index rows (`zanshin_file_chmod` :687) + section `## File chmod; …` (:1752): add rows + a `## zanshin_file_edit, zanshin_file_delete (Story 9.44)` section. `docs/rust-error-codes.md` -- "Also emitted — Story 9.44 by …" on `jj.invalid_input` (:66), `jj.immutable` (:67), `jj.config_error` if listed per emitter, warning `jj.paths_unmatched` (:136, delete).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/wc_ops.rs` -- `file_edit`: read the marker style; resolve + guard; parse the path; `tree.path_value` → the CLI's three refusals; each ancestor dir of the path that is present in the tree and not a directory refuses (Design Notes); temp dir (`tempfile`, prefix `jj-file-edit-`) with `wc/` + `state/`, `TreeState::init`, sparse = `[path]`, `check_out(&tree)`, `create_dir_all` of the file's parent, write `content`, snapshot with the CLI's options, compare tree ids → no-op, else rewrite + rebase/reparent + `finish_verb`. `file_delete`: chmod's shape with `set_or_remove(path, Merge::absent())`, the no-op check, rebase/reparent, `finish_verb`. Inline unit tests for any private helper with branches.
- `crates/zanshin-jj/src/repo.rs`, `cli_command.rs`, `Cargo.toml` -- the two public methods (rustdoc incl. `# Errors` and the CLI citation @ v0.46.0), `file_delete`'s empty-paths refusal through `with_checked_verb`, table entries, `records!` lines, `tempfile` dependency.
- `crates/zanshin-jj/tests/it/file_edit.rs`, `file_delete.rs` (new, + `main.rs`), `api_stability.rs` -- one witness per matrix row on the Rust API (the conflict rows use `file_show`'s output as the buffer; on-disk content checked for the `@` case).
- `schemas/envelope.fbs` + `cargo make codegen` -- `FileEditRequest { kind; revision: string; restore_descendants: bool; path: string; content: [ubyte]; }`, `FileDeleteRequest { kind; revision: string; restore_descendants: bool; paths: [string]; }`, documented like `FileChmodRequest`; commit the generated files.
- `crates/zanshin-ffi/src/file_ops.rs` + `tests/it/file_ops_ffi.rs` -- the two extern fns (absent `path`/`content` refused before the snapshot), round-trip + refusal tests (wrong kind, handle 0, null data, absent fields, empty paths).
- `packages/zanshin_core` -- adapters `zanshinFileEdit(rawHandle, path, content, {revision, restoreDescendants})` / `zanshinFileDelete(rawHandle, paths, {revision, restoreDescendants})` with NUL guards like chmod's, `FileEditCommand`/`FileDeleteCommand`, client methods + dispatch, `RepoHandle.fileEdit`/`fileDelete`; real-cdylib worker tests per extern fn (round trip + a refusal + closed handle) and ffi tests.
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` -- `file_edit` scenarios (CLI side: `ui.editor` script saving fixed bytes, `mkdir -p` first for the nested new file): `@`, `-r A`, `-r A --restore-descendants`, new file, nested new file, unchanged buffer (editor `true`), directory refusal, immutable root; `file_delete` scenarios: `@`, `-r A`, `--restore-descendants`, unmatched path, immutable root.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, section, emitter sentences.

**Acceptance Criteria:**
- Given each oracle scenario, when Zanshin and the pinned CLI run it on twin repos, then the repo states match (no ledger entry unless a divergence is named in this spec).
- Given a `RepoHandle` from `packages/zanshin_core`, when `fileEdit` / `fileDelete` run against the real cdylib, then they return a `MutationResult` (new op id) and a refusal surfaces as `ZanshinFfiException` with the registry code.
- Given `cargo test -p zanshin-jj --lib`, when `cli_command`'s audit runs, then `file edit` and `file delete` are canonical subcommand paths of the pinned jj-cli.

## Spec Change Log

## Review Triage Log

### 2026-10-25 — Review pass
- verdicts: 23 findings — high 0, medium 0, low 19, false 3, maybe-false 1
- findings:
  - (intent-alignment) `low` `reject` `file_delete` takes prefixes, not the fileset DSL (`glob:`, `root:`) — the house rule for every path verb (`op_support.rs:798-801`: the CLI's BARE fileset form is exactly `prefix_path`; the DSL is terminal input language ADR-0003 replaces), as `file chmod`/`track`/`untrack`/`restore` already do.
  - (intent-alignment) `false` `reject` `-r` is a change id, not a revset — every Zanshin verb takes the CLI's `-r` as a resolved change id (`resolve_or_wc`); the oracle passes the same commit to both sides, which is the observable effect.
  - (intent-alignment) `low` `patch` the editor-dependent cases (missing parents created, a file ancestor refused) rest on two different editor models and the ancestor refusal is Zanshin-only — same root as the blind-hunter documentation rows; documented as one deliberate divergence (see those rows).
  - (intent-alignment) `low` `patch` refusals and the conflict round trip are witnessed only against Zanshin's API, not the pinned CLI — same root as the blind-hunter oracle-coverage row; oracle scenarios added.
  - (intent-alignment) `false` `reject` I1 is not recorded under `## Auto Run Result` — written at finalization (this run).
  - (verification-gap) `low` `patch` `restore_descendants` and delete's `revision` are never observed across the FFI/worker seam (childless `@` everywhere) — FFI and worker tests now edit/delete in a revision with a child that inherits the file and assert the child keeps its content with `restore_descendants`.
  - (verification-gap) `low` `patch` `file_edit`'s `ui.conflict-marker-style` read and its `jj.config_error` refusal are untested — `tests/it/file_edit.rs` now refuses a malformed style as `MutateError::Config` with no operation.
  - (edge-case-hunter) `low` `patch` `file_edit` parses its path with `parse_prefixes`, refusing `dir/` and absolute in-workspace paths the CLI's `parse_file_path` accepts — now `parse_fs_path(root, root, path)` (no empty-entry refusal; `""` stays the root); witness `dir/` → "Path is a directory: dir".
  - (edge-case-hunter) `maybe-false` `reject` an ancestor conflict whose REMOVED terms hold a non-tree passes `non_directory_ancestor` — whether jj-lib's builder then rewrites that base term needs a hand-built conflict with a file base under tree sides; if true only `low` (a conflicted directory path in an edit of a new file below it), so rejected with this note.
  - (edge-case-hunter) `low` `patch` `TreeState::init` failure surfaces as `jj.invalid_input` while the docs say temp-dir failures are `jj.jj_lib_error` — mapped to `Backend`.
  - (blind-hunter) `low` `patch` path parsing differs from the CLI and from `file_delete` — same root and fix as the edge-case row.
  - (blind-hunter) `low` `patch` the ancestor refusal's text is presented as CLI text and its rationale names the wrong outcome (an ordinary editor ends in an ok no-op) — the docs (`Repo::file_edit`, `zanshin_file_edit`, `docs/ffi-abi.md`) now name it as Zanshin's deliberate divergence: the CLI's editor either cannot save (no change) or, creating the directory, has jj-lib replace that file; a GUI edit is refused instead of silently dropped or silently replacing an entry.
  - (blind-hunter) `low` `reject` the ancestor divergence has no oracle scenario or ledger entry — the case needs a path below an existing file (rare in a GUI that edits listed files); the divergence is named in the API docs; a scenario + ledger entry adds test machinery for an edge case.
  - (blind-hunter) `low` `patch` the missing-parent rule and the file-ancestor rule follow different editor models — same root as the documentation row: one rule stated (a directory-creating editor's outcome, except that an existing entry is never replaced).
  - (blind-hunter) `low` `patch` the oracle does not cover the conflict round trip, symlink/non-file-conflict refusals, the executable bit or empty content — scenarios added (see Auto Run Result).
  - (blind-hunter) `low` `patch` the `file delete` oracle is thin (directory prefix, conflicted entry, several paths with one unmatched, no paths on a dirty working copy) — scenarios added.
  - (blind-hunter) `low` `patch` temp-dir failure codes in the docs disagree with the code — same root and fix as the edge-case `TreeState::init` row.
  - (blind-hunter) `low` `patch` `docs/rust-error-codes.md` has no Story 9.44 sentence on `jj.config_error` — added.
  - (blind-hunter) `low` `reject` `non_directory_ancestor` has no unit test per branch — both outcomes are witnessed (a file ancestor refuses, an absent ancestor chain creates the file in `an_absent_path_is_created_with_its_missing_parents`); the walk is one `any()` per ancestor.
  - (blind-hunter) `low` `patch` `restore_descendants` never observed across the wire — same root and fix as the verification-gap row.
  - (blind-hunter) `low` `reject` a new `error_code` test helper duplicates ones in other `tests/it` modules — a pre-existing per-module pattern; consolidating the helpers is an unrelated refactor.
  - (blind-hunter) `false` `reject` `sprint-status.yaml` / deferred-work I1 not updated — done in this run's ledger commit (finalization).
  - (blind-hunter) `low` `reject` `FileEditCommand` copies the buffer across the isolate boundary — every worker command copies its arguments; files edited from a commit view are small; `TransferableTypedData` adds a second transport for no measured cost.

## Design Notes

**Ancestor is a file.** In the CLI the sparse working copy holds only `path`, so for `a.txt/x` with `a.txt` a file, an ordinary editor fails to save (no directory) and the revision stays unchanged; an editor that creates the directory would make jj-lib's tree builder replace the file `a.txt` with a directory (`tree_builder.rs:164-167`, `sub_tree` of a file → empty tree) — silently dropping `a.txt`. Zanshin creates missing parent directories (an absent ancestor, the new-file-in-new-dir case) but refuses a present non-directory ancestor, the outcome of the ordinary editor, so no file is dropped by an edit of another path.

**Why the TreeState round trip instead of writing a blob.** It is the CLI's code path: conflict-marker parsing back into a conflict (the marker length/labels recorded at checkout), the executable bit (`ExecChangeSetting::Auto` keeps the checked-out mode) and the unchanged-buffer no-op all fall out of jj-lib, with nothing re-implemented.

## Verification

**Commands (gate rule of this run — no `cargo make test`/`test-full`/`coverage`):**
- `cargo test -p zanshin-jj --lib` -- expected: pass (incl. `cli_command` audit, `every_verb_resolves_for_its_cli_command`)
- `cargo test -p zanshin-jj --test it file_edit::` and `--test it file_delete::` and `--test it api_stability::` -- expected: pass
- `cargo make codegen` -- expected: regenerated files committed, `git status` shows no further drift on a rerun
- `cargo test -p zanshin-ffi --test it file_ops_ffi::` and `--test it ffi_abi_doc_sync::` and `cargo test -p zanshin-ffi --lib` -- expected: pass
- `cargo test -p zanshin-parity --test oracle` -- expected: pass incl. the new scenarios
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings`; `cargo fmt --all --check` -- expected: clean
- in `packages/zanshin_core`: `dart test test/worker/file_ops_test.dart test/ffi/file_ops_test.dart` (pure-Dart package; builds the cdylib through its hook), `dart analyze`, `dart format --set-exit-if-changed .` -- expected: pass/clean

**Results (2026-10-25, orchestrator run on the patched tree, before commit ff4f515; the full gate is the story loop's, not run here):**
- `cargo test -p zanshin-jj --lib` — 397 passed (incl. the `cli_command` audit against the pinned jj-cli and `every_verb_resolves_for_its_cli_command`)
- `cargo test -p zanshin-jj --test it -- file_edit:: file_delete:: file_chmod:: api_stability::` — 64 passed
- `cargo test -p zanshin-ffi --lib` — 229 passed; `--test it -- file_ops_ffi:: ffi_abi_doc_sync::` — 34 passed
- `cargo test -p zanshin-parity --test oracle` — 479 passed (23 `file_edit_*`/`file_delete_*` scenarios, no ledger entry)
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` — clean; `cargo fmt --all --check` — clean
- `cargo make codegen` re-run — exit 0, no drift beyond the committed generated files
- `packages/zanshin_core`: `cargo make --allow-private test-core` (the whole suite, with the pinned env; a bare `dart test` of `test/worker/file_ops_test.dart` fails its setUpAll on "XDG_CONFIG_HOME is not pinned — run via cargo make", pre-existing) — 1106 passed; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --output=none --set-exit-if-changed .` — 0 changed
- Coverage not measured (gate rule). Every new line runs in a witness except `edit_in_sparse_copy`'s I/O error arms (temp dir, `TreeState::init`, `to_fs_path`, the write) — the ratchet at the loop's end decides.

## Auto Run Result

Status: done

**Summary.** `file edit` and `file delete` (jj 0.46) are ported end to end: `Repo::file_edit(revision, restore_descendants, path, content)` runs the CLI's own mechanism — a temporary sparse `TreeState` holding only `path`, checked out from the revision (conflicts materialized in the effective `ui.conflict-marker-style`), the GUI's bytes written where the editor would save, then snapshotted — so an absent file is created, an executable bit is kept, a conflict buffer round-trips (unchanged = no-op, an edited side stays conflicted, a marker-free buffer resolves it); the CLI's refusals (directory, not a regular file, non-file conflict, immutable) come with its texts, the path parses as the CLI's `parse_file_path`. `Repo::file_delete(revision, restore_descendants, paths)` removes every entry under the given prefixes (warning `jj.paths_unmatched` for an unmatched one; an empty list refused before the snapshot). Both share one tail: an unchanged tree is the house no-op (no operation), otherwise the rewrite, descendants rebased or (with `restore_descendants`) reparented, op `edit file <path> in commit <hex>` / `delete paths in commit <hex>`. Chain: `FileEditRequest`/`FileDeleteRequest` + `zanshin_file_edit`/`zanshin_file_delete` + `FileEditCommand`/`FileDeleteCommand` + `RepoHandle.fileEdit`/`fileDelete`. Deliberate divergence (named in the API docs): a path below an existing non-directory refuses `jj.invalid_input` "Failed to edit file: '<x>' is not a directory" — the CLI's editor either cannot save there or, creating the directory, has jj-lib replace that file.

**Files changed (code commit ff4f515):**
- `crates/zanshin-jj/src/wc_ops.rs` -- `file_edit`, `file_delete`, `finish_tree_rewrite`, `edit_refusal`, `non_directory_ancestor`, `edit_in_sparse_copy`; unit test `edit_refuses_what_the_cli_refuses`.
- `crates/zanshin-jj/src/repo.rs`, `cli_command.rs`, `Cargo.toml` -- the two public verbs, `FILE_EDIT`/`FILE_DELETE`, `records!` lines, `tempfile` as a normal dependency (already in the lock).
- `crates/zanshin-jj/tests/it/file_edit.rs`, `file_delete.rs` (new), `file_chmod.rs` (fixture helpers `pub(crate)`), `main.rs`, `api_stability.rs` -- one witness per matrix row, plus path parsing and the marker-style config refusal.
- `schemas/envelope.fbs` + generated `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart` -- two request tables, two `RequestKind`s.
- `crates/zanshin-ffi/src/file_ops.rs`, `tests/it/file_ops_ffi.rs`, `tests/it/ffi_abi_doc_sync.rs` -- the two extern fns; round trips, refusals, `restore_descendants` on a parent with a child.
- `packages/zanshin_core/lib/src/ffi/file_ops.dart`, `worker/{commands,isolate,handle}.dart`, `test/ffi/file_ops_test.dart`, `test/worker/file_ops_test.dart` -- adapters, commands, `RepoHandle` methods, real-cdylib tests.
- `crates/zanshin-parity/tests/oracle/scenarios.rs`, `main.rs` -- 23 scenarios against the pinned CLI.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, section, emitter sentences.

**Items:**
- I1 (Story 9.44's part: `jj file edit` / `jj file delete` (0.46) recorded as a story) -- fixed (ff4f515); the entry's other parts (9.43, 9.45, 9.20's addendum, 9.40's update) belong to those stories.

**Review:** 23 findings (high 0, medium 0, low 19, false 3, maybe-false 1). Patched (all low): `file_edit`'s path parses as the CLI's `parse_file_path` (`dir/`, absolute in-workspace paths); `TreeState::init` failure is `Backend`; the ancestor refusal and the editor model are documented as one deliberate divergence; `jj.config_error` emitter sentences; a marker-style config-refusal witness (it surfaces as `Precondition(Config)` → `jj.config_error`, the start-up reads the key first, as for `file show`); `restore_descendants`/`revision` observed across the FFI and the worker; 9 more oracle scenarios (conflict unchanged/resolved, symlink refusal, executable kept, empty content; delete of a directory prefix, a conflict, several paths with one unmatched, no paths on a dirty working copy). Deferred: none. Rejected: prefixes instead of the fileset DSL (house rule, ADR-0003), `-r` as a change id (house rule), the I1/tracking rows (written at finalization), a conflict ancestor with a file base term (maybe-false, low if true), no oracle/ledger entry for the ancestor divergence (rare; named in the docs), per-branch unit tests for the ancestor walk (both outcomes witnessed), the duplicated `error_code` test helper (pre-existing pattern), the cross-isolate buffer copy (every command copies; small files).

**Follow-up review recommended:** false — no high and no medium entry was patched (patched: 8 entries, all low).

**Residual risks:** the full gate (incl. the coverage ratchet for `wc_ops.rs`, whose temp-dir error arms have no test, and the extern-fn guard for the two new symbols) runs at the end of the story loop.
