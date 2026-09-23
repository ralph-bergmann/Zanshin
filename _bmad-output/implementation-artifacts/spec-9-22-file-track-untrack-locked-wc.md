---
title: 'Story 9.22: `file track`, `file untrack` (locked-WC lifecycle)'
type: 'feature'
created: '2026-09-17'
status: 'done'
baseline_revision: 'fc362ce28c0244d1d242a17b86ac377eb4f44b53'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      After a file_track that recorded anything, the working-copy state leads @ until the next snapshot, so Zanshin's next working-copy verb refuses (jj.concurrent_working_copy) and every check_out-based verb commits its op and then fails stale.
    evidence: |-
      The CLI's track discards its snapshot tree (GH #8298; confirmed with jj 0.45.1: `track paths` leaves @ unchanged, the next command writes `snapshot working copy`). The track snapshot also records every unsnapshotted on-disk edit into the WC state. The CLI never notices because its next command snapshots first; Zanshin has no pre-verb snapshot, which the intent's Never tier assigns to Story 9.26. sync_working_copy then hits jj-lib's ConcurrentCheckout after tx.commit. Fix is fully determined (9.26's precondition before lock_working_copy and every workspace_helper verb); handoff written into the 9.26 spec's Code Map and deferred-work.md.
    location: >-
      crates/zanshin-jj/src/mutate.rs::lock_working_copy / sync_working_copy; crates/zanshin-jj/src/wc_ops.rs::file_track
    severity: medium
  - summary: >-
      Shared op_support::build_matcher (restore, absorb, the four file reads) still refuses a trailing `/`, `./`, `//` or an in-workspace absolute path, which the CLI normalises.
    evidence: |-
      Pre-existing: build_matcher takes jj's internal string form verbatim, while the CLI parses bare path arguments with RepoPathUiConverter::parse_file_path. Story 9.22's two verbs already parse like the CLI (wc_ops::parse_paths, cwd = workspace root) because the matrix row paths=["nope/"] requires it; the six older verbs were outside this story's scope.
    location: >-
      crates/zanshin-jj/src/op_support.rs::build_matcher
    severity: low
---

<intent-contract>

## Intent

**Problem:** Zanshin cannot start or stop tracking working-copy paths, and no production code path in `zanshin-jj` holds the working-copy lock (`Workspace::start_working_copy_mutation` → `LockedWorkingCopy::{snapshot,reset}` → `LockedWorkspace::finish`). Every later story that touches the working copy — Story 9.26's per-verb snapshot, Story 9.23's `update-stale` — needs that lifecycle, and today its only in-repo examples are test setup helpers (`crates/zanshin-jj/tests/status.rs::snapshot_working_copy`, `tests/commit_views.rs::snapshot_working_copy`).

**Approach:** Port `cmd_file_track` / `cmd_file_untrack` @ jj v0.44.0 (`cli/src/commands/file/track.rs`, `untrack.rs`) step for step as `Repo::file_track` / `Repo::file_untrack`, and in doing so build the reusable locked-working-copy primitives in `zanshin-jj` (`SnapshotOptions` from the effective `snapshot.*` config, the CLI's `base_ignores()` chain, one lock → mutate → `finish` helper) that Story 9.26 drives. Ralph's rule applies without exception: a user switching between the `jj` CLI and Zanshin must not be able to tell which of the two wrote an operation.

## Boundaries & Constraints

**Always:**
- Reproduce the CLI's observable behaviour @ v0.44.0: verbs, preconditions, refusals, op-log entries and descriptions (`track paths`, `untrack paths`), default resolution (NFR-R-2, project-context § anti-patterns). Terminal text is not ported; every fact it would have printed rides the typed payload.
- **Both verbs commit unconditionally**, like the CLI: `cmd_file_track` and `cmd_file_untrack` call `tx.commit("track paths")` / `tx.commit("untrack paths")` on the raw `Transaction`, with no `has_changes` guard. `mutate::finish_or_no_op` is therefore the WRONG helper; add an always-commit sibling that is still routed through `op_support::start_repo_transaction` (op `workspace_name` metadata; the follow-up-L creep guard keeps zero exceptions).
- `SnapshotOptions` exactly as `snapshot_options_with_start_tracking_matcher` (`cli_util.rs:1613-1631`): `base_ignores` = the CLI's `base_ignores()` chain (`cli_util.rs:1644` ff.), `max_new_file_size` from `snapshot.max-new-file-size` (`0` → `u64::MAX`), `start_tracking_matcher` = the verb's path matcher (track) or the `snapshot.auto-track` fileset (untrack, `auto_tracking_matcher`, `:1604-1611`), `force_tracking_matcher` = the path matcher when `include_ignored` is set, else `NothingMatcher`. Every key from the EFFECTIVE config via `config::load` — never hardcoded, never a silent fallback on a wrong type (→ `jj.config_error`), FR-JJ-17.
- Paths are repo-relative prefixes → `PrefixMatcher` (the Story 9.3/9.4 convention for the CLI's bare-fileset form). An empty list is refused as `jj.invalid_input`: the CLI marks `paths` `required = true` for both verbs.
- `file_track`: `start_working_copy_mutation` → `snapshot(options)` → `rebase_descendants` → commit `track paths` → `locked_ws.finish(op_id)`. The result carries the MERGED `SnapshotStats` per `print_track_snapshot_stats`: a `FileNotAutoTracked` reason in the track stats is replaced by the pre-verb auto-snapshot's reason for the same path. Until Story 9.26 lands there is no pre-verb snapshot, so the auto stats are empty and the merge is the identity — say so at the call site.
- `file_untrack`: rewrite `@` without the entries the matcher hits → `locked_wc.reset(new_commit)` → `snapshot(options)` → compare trees. Matched entries that came back are NOT ignored → refuse with the CLI's fact (`'<path>' is not ignored.` / `'<path>' and N other files are not ignored.`) as a typed refusal carrying the paths, with NO operation written and the lock dropped WITHOUT `finish`. A tree difference outside the matcher is a concurrent working-copy change → `reset` again. Then `rebase_descendants`; colocated → `export_working_copy_changes_to_git` (`update_intent_to_add` + `export_refs`, `cli_util.rs:2650-2661`); commit `untrack paths`; `finish`. The result carries the unmatched explicit paths (the `print_unmatched_explicit_paths` fact), the rebased count and the post-reset `SnapshotStats`.
- New payload tables, ONE definition shared by both verbs and by Story 9.26: `SnapshotStats { untracked: [UntrackedPath { path, reason }], invalid_utf8_paths: [string] }`, `UntrackedReason` = `FileTooLarge { size, max_size }` | `FileNotAutoTracked` (jj-lib `working_copy.rs:234-255`).
- Surface through the usual chain: `schemas/envelope.fbs` → `zanshin-jj` → `extern "C"` `zanshin_file_track` / `zanshin_file_untrack` (request tables per `docs/ffi-abi.md` § Request-buffer contract) → `WorkerCommand` in `packages/zanshin_core`; `cargo make codegen` output committed; a row per symbol in `docs/ffi-abi.md` § Symbol index; every new code in `docs/rust-error-codes.md`.
- Coverage ratchet: new `src/` files ≥ 80 %, no per-file drop, a `zanshin_core` cdylib witness per extern fn.

**Ask First:**
- The name of the refusal code for non-ignored paths (proposal `jj.path_not_ignored`, offending paths in `context`) and whether the unmatched-paths fact gets its own field or reuses `SkippedPath`.
- Any change to `Repo` method receivers beyond `&mut self` on the two new verbs.
- If porting `base_ignores()` needs a gix config entry point beyond what `remotes.rs` already opens.

**Never:**
- No fileset DSL, no interactive selection, no MCP tool (Epic 7), no `--no-integrate-operation`.
- No per-verb snapshot in front of OTHER verbs — that is Story 9.26. This story only builds the primitives 9.26 drives.
- No lowering of `coverage-baseline.txt`, no `exclude_prefix`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| track: untracked file under limit | `snapshot.auto-track = "none()"`, new `a.txt`, `paths=["a.txt"]` | one op `track paths`; `a.txt` in `@` tree; stats empty; `rebased = 0` | N/A |
| track: file over limit | `a.bin` > `snapshot.max-new-file-size`, no `include_ignored` | op `track paths` written (unconditional); file NOT tracked; stats `FileTooLarge{size,max_size}` | N/A |
| track: over limit, forced | same, `include_ignored = true` | file tracked | N/A |
| track: ignored path | `.gitignore` matches `b.txt`, no `include_ignored` | op written; `b.txt` still untracked | N/A |
| track: ignored path, forced | same, `include_ignored = true` | `b.txt` tracked | N/A |
| track: nothing matches | `paths=["nope/"]` | op `track paths` still written; tree unchanged | N/A |
| track: descendants | `@` has children | children rebased; count in payload | N/A |
| untrack: ignored + tracked | `c.log` tracked and matched by `.gitignore` | op `untrack paths`; `c.log` gone from `@` tree, still on disk; stats from the post-reset snapshot | N/A |
| untrack: not ignored | `d.txt` tracked, not ignored | NO op; tree and WC state unchanged; lock released without `finish` | typed refusal (paths, count) |
| untrack: mixed | `c.log` ignored, `d.txt` not | refusal names `d.txt`; nothing written | as above |
| untrack: nothing matches | `paths=["nope.txt"]` | op written; `unmatched_paths=["nope.txt"]` | N/A |
| untrack: colocated | ignored + tracked, colocated workspace | additionally `update_intent_to_add` + `export_refs` in the same transaction; `.git` index reflects it | export failures reported per ref (as `GitExportResult`); op still written |
| untrack: concurrent WC edit | another file changed between `reset` and `snapshot` | second `reset`; commit proceeds; foreign change NOT mixed in | N/A |
| either: empty `paths` | `[]` | refused before any lock | `jj.invalid_input` |
| either: wrong-typed knob | `snapshot.max-new-file-size = "lots"` | refused before any lock | `jj.config_error` (key in context) |
| either: native backend | `init_simple` workspace, untrack | no git export attempted; op written | N/A |

</intent-contract>

## Code Map

All `../jj` anchors are `git -C ../jj show v0.44.0:<path>`; jj-lib anchors are the vendored `~/.cargo/registry/src/*/jj-lib-0.44.0/src/…`.

**Oracle (read-only)**
- `cli/src/commands/file/track.rs` -- `cmd_file_track` (auto-stats from `workspace_helper_with_stats` → matcher → options (+`force_tracking_matcher = &matcher` on `--include-ignored`) → `start_transaction().into_inner()` → `start_working_copy_mutation` → `snapshot` (tree DISCARDED) → `rebase_descendants` → `tx.commit("track paths")` → `finish(op_id)`); `print_track_snapshot_stats` (the FileNotAutoTracked→auto-reason merge).
- `cli/src/commands/file/untrack.rs` -- `cmd_file_untrack` step order, refusal text, `drop(locked_ws)` before the refusal, second `reset` on a foreign tree change, colocated export, `print_unmatched_explicit_paths(…, [&wc_tree])`, `print_snapshot_stats(&stats)`.
- `cli/src/cli_util.rs:1482-1507` -- `unchecked_start_working_copy_mutation` ("Nothing checked out in this workspace") + `start_working_copy_mutation` (`wc_commit.tree().tree_ids_and_labels() != locked_wc.old_tree().tree_ids_and_labels()` → "Concurrent working copy operation. Try again.").
- `cli/src/cli_util.rs:1604-1685` -- `auto_tracking_matcher` (`fileset::parse` of `snapshot.auto-track` with `fileset_parse_context_for_config` = fileset aliases + ROOT path converter `RepoPathUiConverter::Fs{cwd:"",base:""}`, `:1007-1018`), `snapshot_options_with_start_tracking_matcher` (`HumanByteSize` via `get_value_with(…, TryInto::try_into)`, `0 → u64::MAX`), `base_ignores` (git backend: `core.excludesFile` from `git_repo().config_snapshot()` else `$XDG_CONFIG_HOME/git/ignore` else `~/.config/git/ignore`, then `<git_repo_path>/info/exclude`; non-git backend: `gix::config::File::from_globals()` excludes file only; relative excludesFile joined onto the WORKSPACE root; `jj_lib::file_util::expand_home_path`).
- `cli/src/cli_util.rs:3407-3413` -- `load_fileset_aliases` = the same `load_aliases_map` over table `fileset-aliases`.
- `cli/src/cli_util.rs:2650-2661` -- `export_working_copy_changes_to_git` = `jj_lib::git::update_intent_to_add(mut_repo.base_repo(), old, new)` then `export_refs(mut_repo)`.
- `cli/src/cli_util.rs:3323-3347` -- `print_unmatched_explicit_paths`: explicit paths of the expression whose `tree.path_value(path)` is absent in `wc_tree`.
- `cli/src/git_util.rs:62-78` -- `is_colocated_git_workspace` (git backend, `git_workdir()` == workspace root, else canonicalized `<root>/.git`'s parent == canonicalized workdir; bare → false).
- `cli/src/config/misc.toml:59-61` -- `[snapshot] max-new-file-size = "1MiB"`, `auto-track = "all()"` (CLI-only defaults — jj-lib's `config/misc.toml` has neither).
- `cli/tests/test_file_track_untrack_commands.rs` -- behavioural expectations to mirror (`test_track_ignored`: "TODO: fix GH #8298 so tracking is immediate" — the NEXT command's snapshot is what rebases children; `test_track_untrack`: refusal texts, unchanged state after refusal, `nonexistent` warning).
- jj-lib `working_copy.rs:110-156` (`LockedWorkingCopy::{old_tree,snapshot,reset,finish}`), `:206-255` (`SnapshotOptions`, `SnapshotStats { untracked_paths: BTreeMap<RepoPathBuf,UntrackedReason>, invalid_utf8_paths: BTreeSet<(RepoPathBuf dir, OsString name)> }`, `UntrackedReason`); `workspace.rs:446-500` (`Workspace::start_working_copy_mutation`, `LockedWorkspace::{locked_wc,finish}`); `git.rs:419` `get_git_backend`, `:1287` `export_refs`, `:2055` `update_intent_to_add`; `git_backend.rs:356-366` (`git_repo`, `git_repo_path`, `git_workdir`); `gitignore.rs:44,87` (`GitIgnoreFile::{empty,chain_with_file}` — a missing file is not an error); `fileset.rs:419` `explicit_paths`, `:610` `parse`; `settings.rs:323-359` `HumanByteSize` + `TryFrom<ConfigValue>`; `file_util.rs:122` `expand_home_path` (uses `etcetera::home_dir`).

**zanshin-jj (edit)**
- `crates/zanshin-jj/src/mutate.rs` -- `MutationResult` `:42-91` (NO rebased field — rebased counts ride the verb's own result, like `AbsorbResult::num_rebased` `:321`, saturating `u32`); `MutateError` `:116-288` (add variants here); `be`/`cfg`/`flatten_chain` `:353,360,814`; `capture_old_wc`/`sync_working_copy` `:447,462` (the `check_out` path — the lock helper is documented AGAINST it); `finish_or_no_op{,_at}` `:858,890` (the no-op guard the new always-commit helper must NOT have); module doc `:16-18` says locked-WC is 9.22's scope → update. All async via `pollster::block_on`.
- `crates/zanshin-jj/src/op_support.rs` -- `start_repo_transaction(&Arc<ReadonlyRepo>, &WorkspaceName)` `:690` (mandatory opener; creep-guard test `:1248` flags ANY non-comment `src/` line containing `start_transaction` outside this file — `start_working_copy_mutation` does not match); `build_matcher(&[String])` `:638` (empty → EverythingMatcher, so the new verbs refuse `[]` BEFORE calling it; entries → `PrefixMatcher`); doc `:681-683` mentions 9.22.
- `crates/zanshin-jj/src/config.rs` -- `BUILTIN_CONFIG_TOML` `:148-180` (add the two `[snapshot]` keys verbatim from CLI `misc.toml:60-61`, and extend its doc comment's provenance list); `ConfigError::Load{reason}` `:196`, `value_error` `:249`; typed-reader pattern `git_import_options` `:894`; `load(repo)` `:614` (re-reads the effective stack per call).
- `crates/zanshin-jj/src/revset.rs:322-400` -- `build_aliases_map(&StackedConfig) -> RevsetAliasesMap` (CLI `load_aliases_map` port, table hard error / entry warn-and-skip). Generalize it over the alias-parser type + table name so `fileset-aliases` uses the SAME port (`FilesetAliasesMap`); do not copy it.
- `crates/zanshin-jj/src/git.rs` -- `GitExportFailure` `:150`, `project_failures` (`:~370`), `map_export_err` — reuse for untrack's colocated export failures.
- `crates/zanshin-jj/src/convert.rs:292` -- private simplified `is_colocated`; the new CLI-exact `is_colocated_git_workspace` port lives in the new module (leave convert's alone — out of scope).
- `crates/zanshin-jj/src/repo.rs` -- `Repo { workspace, settings, stack_fingerprint }` `:107`; `workspace_mut()` `:135`; `refresh_settings()` `:196` (first statement of every `&mut self` verb); delegation pattern e.g. `git_export` `:904`.
- `crates/zanshin-jj/src/lib.rs:51-68` -- public re-exports (no `pub use jj_lib::…` — `test-jj-adapter-hygiene`).
- `crates/zanshin-jj/Cargo.toml` -- add `etcetera` (already in `Cargo.lock` via jj-lib; pin the SAME version jj-lib 0.44.0 uses — no new crate in the tree). `gix` is already a dep.
- NEW `crates/zanshin-jj/src/wc_ops.rs` -- the two verbs, the public stats/result types, the snapshot-options builder, `base_ignores`, `is_colocated_git_workspace`, the track-stats merge.

**zanshin-jj tests**
- `crates/zanshin-jj/tests/status.rs:40-76`, `tests/commit_views.rs:186-227` -- in-test lock → snapshot → commit → finish recipe (copy it for fixture setup, e.g. to get a file into `@`).
- `crates/zanshin-jj/tests/convert.rs:27-46` (ENV_GUARD + leaked `XDG_CONFIG_HOME` tempdir), `:89-120` (`git` CLI colocated recipe → `convert_colocated` → `Repo::open`).
- `crates/test-helpers/src/lib.rs:71-103` -- `TEST_ENV`, `pin_test_env`, `test_settings`.
- `crates/zanshin-jj/tests/api_stability.rs` -- add `sample_*` builders for every new public type/variant and a `file_track_surface_resolves` test with `fn`-pointer casts (`api_surface_resolves` is at clippy's `too_many_lines` ceiling — new test fn).

**FFI / wire / bridge (edit)**
- `schemas/envelope.fbs` -- request tables before `// ── Payload union` (`:368`); `RequestKind` `:70-88` append `FileTrack`, `FileUntrack` (last is `BookmarkDelete`); `MutationResult` `:689-699`; `SkippedPath` `:719`; `GitExportFailure` `:901`; `union Payload` `:1038-1065` append-only; union-member tables declared BEFORE use (header rules `:31-49`); only existing union is request-side `RevisionRef` `:292`.
- `crates/zanshin-ffi/src/bookmark_ops.rs` (whole file) -- template: owned request struct, reader (`reject_null_request` → `root_with_opts` → `expect_request_kind` → list `into_iter().flatten()`), `#[no_mangle] extern "C"` wrapper (reader BEFORE `session_from_handle`), rustdoc `# Errors` (parsed by `ffi_abi_doc_sync`) + `# Safety`.
- `crates/zanshin-ffi/src/git.rs:136-198` -- nested-result builder template (`build_mutation_result` `envelope.rs:332`, `build_export_failures`, `finish_envelope`).
- `crates/zanshin-ffi/src/repo.rs:101-166` -- `map_mutate_err` (exhaustive; add arms); `crates/zanshin-ffi/src/envelope.rs:19-149` code consts (`JJ_NO_WORKING_COPY` exists), `FfiErrorObj { code, context: Option<String> }` `:166`.
- `crates/zanshin-ffi/src/lib.rs:32-51` -- module list.
- `crates/zanshin-ffi/tests/bookmark_ops_ffi.rs` -- FFI test scaffolding (`pin_env`, `read_and_free`, hand-built requests, kind-mismatch table, zero handle, absent vector).
- `Makefile.toml:310-365` -- `cargo make codegen` regenerates `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/envelope_zanshin.ffi_generated.dart`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/ffi/bindings.dart`; `:558-585` extern-fn coverage gate (every `extern "C"` must be hit by a `zanshin_core` dart test through the real cdylib).
- `packages/zanshin_core/lib/src/ffi/bookmark_ops.dart:41-67` + `request_bytes.dart` -- request-building adapter template; `lib/src/ffi/git.dart:214-325` -- model + decoder template (`_okEnvelope`, `_mutation`, `decodeIdentityMissingInternal` from `mutate.dart:219`); `lib/src/worker/commands.dart:772-820` (command class), `lib/src/worker/isolate.dart:1303-1310` (API) + `:1820-1840` (dispatch case), `lib/src/worker/handle.dart:866-871`; tests `test/worker/bookmark_ops_test.dart:55` (real cdylib witness) + `test/ffi/bookmark_ops_test.dart` (wire shape).
- `docs/ffi-abi.md` -- § Request-buffer contract `:101-277` (counts: "Sixteen of the 47" `:103`, "All sixteen" `:142,:181,:193`, "15 request tables … 16 request-buffer symbols" `:226-236`, "For 14 tables" `:253`), § Symbol index `:296-346` ("exports **47**" `:298`, row format `:346`); `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` enforces rows ↔ header `# Errors` ↔ registered codes.
- `docs/rust-error-codes.md:35-79` -- code table + "Adding a New Code".

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/config.rs` -- add `[snapshot] max-new-file-size = "1MiB"` and `auto-track = "all()"` to `BUILTIN_CONFIG_TOML` (provenance `misc.toml:60-61`; NOT `auto-update-stale`, no consumer yet); add `pub(crate)` readers: `snapshot_max_new_file_size(&StackedConfig) -> Result<u64, ConfigError>` (`get_value_with(…, HumanByteSize::try_from)`, `0 → u64::MAX`, error names the key) and `snapshot_auto_track(&StackedConfig) -> Result<String, ConfigError>` -- knobs from the effective stack, wrong type → `jj.config_error`.
- `crates/zanshin-jj/src/revset.rs` -- generalize `build_aliases_map` to any `AliasesMap<P, String>` + table name; revset call site unchanged in behaviour; fileset caller passes `fileset-aliases` -- one port of `load_aliases_map`.
- `crates/zanshin-jj/src/mutate.rs` -- (a) new `MutateError` variants `NoWorkingCopy`, `ConcurrentWorkingCopy`, `PathsNotIgnored { paths: Vec<String> }` (all offenders, CLI order = `entries_matching` order); (b) `pub(crate)` lock helper = port of `WorkspaceCommandHelper::start_working_copy_mutation`: resolve `@` from the given head-resolved repo (`NoWorkingCopy`), `workspace.start_working_copy_mutation()`, `tree_ids_and_labels` check (`ConcurrentWorkingCopy`), returns `(LockedWorkspace, wc_commit)`; (c) `pub(crate)` always-commit, lock-scoped transaction helper: opens the tx via `start_repo_transaction` FIRST, then (b), runs a closure `(&mut Transaction, &mut dyn LockedWorkingCopy, &Commit) -> Result<T, MutateError>`, on `Err` drops lock and tx WITHOUT `finish`, on `Ok` commits `description` unconditionally, then `finish(op_id)`; builds `MutationResult` from the committed repo (`working_copy_change_id` = new view's `@`, `identity_missing(new_repo.settings())`, id vectors empty) with NO `check_out`; rustdoc contrasts it with `sync_working_copy`/`finish_or_no_op` (Design Notes); update module doc `:16-18` -- the shared lifecycle 9.26 drives.
- `crates/zanshin-jj/src/wc_ops.rs` (NEW) -- public `SnapshotStats { untracked: Vec<UntrackedPath>, invalid_utf8_paths: Vec<String> }`, `UntrackedPath { path, reason }`, `UntrackedReason::{FileTooLarge{size,max_size}, FileNotAutoTracked}`, `TrackResult { mutation, num_rebased: u32, snapshot_stats }`, `UntrackResult { mutation, num_rebased: u32, unmatched_paths: Vec<String>, snapshot_stats, failed_bookmarks: Vec<GitExportFailure>, failed_tags: Vec<GitExportFailure> }`; `pub(crate)`: stats conversion from jj-lib (`invalid_utf8_paths` rendered `"<dir>/<lossy name>"`, bare name at root), `merge_track_stats(auto, track)` (= `print_track_snapshot_stats`'s loop), snapshot-options builder (auto-track matcher via `fileset::parse` + fileset aliases + root converter, parse failure → `Config` naming `snapshot.auto-track`; `base_ignores` port incl. `etcetera` home + `XDG_CONFIG_HOME`; max size reader), `is_colocated_git_workspace` port; verbs `file_track(workspace, config, paths, include_ignored)` / `file_untrack(workspace, config, paths)` step for step per the oracle; every refusal (empty paths, bad path, config) BEFORE the lock -- the verbs + the primitives 9.26 reuses.
- `crates/zanshin-jj/src/repo.rs`, `lib.rs`, `Cargo.toml` -- `pub fn file_track(&mut self, paths: &[String], include_ignored: bool) -> Result<TrackResult, MutateError>` / `pub fn file_untrack(&mut self, paths: &[String]) -> Result<UntrackResult, MutateError>` (`refresh_settings()` first, `config::load(self)` before `workspace_mut()`), full rustdoc incl. `# Errors` and the GH #8298 note; `pub mod`/re-exports; `etcetera` dep -- public surface.
- `crates/zanshin-jj/src/{file.rs:11,convert.rs:361,op_support.rs:681-683}` -- reword the "9.22 owns LockedWorkingCopy" remarks to name the new primitives (the per-verb snapshot remains 9.26's) -- no stale pointers.
- `schemas/envelope.fbs` + `cargo make codegen` -- `FileTrackRequest { kind; paths: [string]; include_ignored: bool; }`, `FileUntrackRequest { kind; paths: [string]; }`, tables `FileTooLarge { size: ulong; max_size: ulong; }`, `FileNotAutoTracked {}`, `union UntrackedReason { FileTooLarge, FileNotAutoTracked }`, `UntrackedPath { path: string; reason: UntrackedReason; }`, `SnapshotStats { untracked: [UntrackedPath]; invalid_utf8_paths: [string]; }`, `TrackResult { mutation: MutationResult; num_rebased: uint; snapshot_stats: SnapshotStats; }`, `UntrackResult { mutation; num_rebased: uint; unmatched_paths: [string]; snapshot_stats; failed_bookmarks: [GitExportFailure]; failed_tags: [GitExportFailure]; }`; `RequestKind` += `FileTrack`, `FileUntrack`; `Payload` += `TrackResult`, `UntrackResult`; commit all four generated files -- wire contract.
- `crates/zanshin-ffi/src/file_ops.rs` (NEW, `bookmark_ops` precedent: one module per error taxonomy) + `lib.rs` + `envelope.rs` + `repo.rs::map_mutate_err` -- `zanshin_file_track` / `zanshin_file_untrack(handle, data, len)`; absent `paths` vector → empty → `jj.invalid_input`; consts `JJ_PATH_NOT_IGNORED = "jj.path_not_ignored"` (context = offending paths joined by `\n`), `JJ_CONCURRENT_WORKING_COPY = "jj.concurrent_working_copy"`; `NoWorkingCopy` → existing `jj.no_working_copy`; result builders -- FFI.
- `crates/zanshin-ffi/tests/file_ops_ffi.rs` (NEW) -- round-trip per verb, refusal writes no op, absent vector, zero handle, kind mismatch both directions, `jj.path_not_ignored` context -- FFI witnesses.
- `packages/zanshin_core` -- `lib/src/ffi/file_ops.dart` (adapters + decoders + models `TrackResult`, `UntrackResult`, `SnapshotStats`, `UntrackedPath`, sealed `UntrackedReason`), `FileTrackCommand`/`FileUntrackCommand`, isolate API + dispatch, handle methods; `test/worker/file_ops_test.dart` (real-cdylib witness per extern fn) + `test/ffi/file_ops_test.dart` (wire shape incl. both union arms) -- bridge.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- two symbol rows (story 9.22), request-contract counts 16→18 symbols / 15→17 tables / 47→49 exports / "For 14 tables"→16 (verify each count against the file), rows for `jj.path_not_ignored` + `jj.concurrent_working_copy`, widen `jj.no_working_copy`'s row -- `ffi_abi_doc_sync` green.
- `crates/zanshin-jj/tests/file_track_untrack.rs` (NEW) + inline `#[cfg(test)]` in `wc_ops.rs`/`config.rs` -- one witness per matrix row (colocated rows via the `git` recipe; `.git` index via `git ls-files`, a bookmark on `@` for the export witness), plus: `base_ignores` chain (`info/exclude`, `$XDG_CONFIG_HOME/git/ignore`, `core.excludesFile` relative + `~/`), `snapshot.auto-track` parse error → `Config`, `max-new-file-size = 0` → unlimited, concurrent-WC refusal (rewrite `@`'s tree via jj-lib without checking out), the "untrack: concurrent WC edit" row by editing ANOTHER tracked file on disk without snapshotting before the call (the post-reset snapshot then sees a foreign change outside the matcher → second `reset`; assert `@` keeps the old content and the disk keeps the new), sparse untrack of an unignored out-of-sparse file (`test_track_untrack_sparse`), `merge_track_stats` + invalid-UTF-8 rendering inline (APFS cannot create such names) -- gate + ratchet; the binary pins `XDG_CONFIG_HOME` to a tempdir in its ENV_GUARD.
- `coverage-baseline.txt` -- commit the auto-raised baseline; `wc_ops.rs` ≥ 80 % -- ratchet.
- `_bmad-output/implementation-artifacts/deferred-work.md`, `sprint-status.yaml` -- mark only what this story resolves; row `9-22-…` → `done` with summary -- ledger.

**Acceptance Criteria:**
- Given a fixture and a step sequence mirroring `cli/tests/test_file_track_untrack_commands.rs` @ v0.44.0, when Zanshin runs `file_track`/`file_untrack`, then exactly one new operation per call carries `track paths`/`untrack paths` as its description, the view's `@` tree after `track` is the pre-call one (GH #8298) while the working-copy STATE tree (`Workspace::working_copy().tree()`, what the next snapshot records) contains the tracked path, and after `untrack` both `@` and the WC state lack it.
- Given a non-ignored matched path, when `file_untrack` runs, then it returns `MutateError::PathsNotIgnored` naming every offender, the op head is unchanged, and `.jj/working_copy/tree_state` is byte-identical to before; the FFI envelope carries `jj.path_not_ignored`.
- Given a colocated workspace with the path as an intent-to-add entry and a bookmark on `@`, when `file_untrack` succeeds, then `git ls-files` no longer lists it and `refs/heads/<bookmark>` points at the rewritten `@`.
- Given `@`'s tree changed in the op log without a checkout, when either verb runs, then it refuses with `ConcurrentWorkingCopy`/`jj.concurrent_working_copy` and writes nothing.
- Given every matrix row and the rows above, then a test exercises it, each extern fn has a real-cdylib `zanshin_core` witness, and every `cargo make test` step except the known pre-existing `test-flutter` splash failures passes, including the coverage ratchet.

## Spec Change Log

## Review Triage Log

### 2026-09-23 — Review pass
- verdicts: 28 findings — high 0, medium 8, low 15, false 5, maybe-false 0
- findings:
  - `[medium]` `[patch]` BH1 — an empty path entry `""` parses to the repo root (matches everything; `track --include-ignored [""]` force-tracks every ignored file) while the CLI refuses it (verified: `jj file track ""` → "Failed to parse fileset: Syntax error"); glob metacharacters are taken literally (the CLI's bare-glob form is fileset DSL, excluded by the intent) — refused as `InvalidInput` before `parse_fs_path`, witness added, `parse_paths` doc names the literal-glob rule.
  - `[low]` `[patch]` BH2 — Story 9.26's spec did not name the file_track/untrack handoff (auto stats into `merge_track_stats`, precondition before `lock_working_copy`) — added a Code Map bullet to `spec-9-26-…md` outside its frozen block (its line 42 only says 9.26 does not implement the two verbs).
  - `[medium]` `[patch]` BH3 — the check_out-verb hazard after `file_track` (commit, then `ConcurrentCheckout`, stale WC) was documented only in deferred-work.md, not on `Repo::file_track` / `RepoHandle.fileTrack` as claimed — documented at both; the hazard itself is deferred (EC2 row).
  - `[low]` `[patch]` BH4 — `ConcurrentWorkingCopy` docs named only "`@` rewritten without checkout" and promised a retry that cannot succeed before 9.26/9.23 — reworded neutrally at the variant, the FFI const, both `# Errors` blocks and the registry row; header regenerated.
  - `[low]` `[reject]` BH5 — `commit_with_locked_wc` can return `Err` after the op is committed (`finish`, post-commit `@` lookup) — `finish` after `tx.commit` is the CLI's own order (`locked_ws.finish(..).await?` in both oracle verbs) and `finish_or_no_op_at` has the same shape; the post-commit `@` lookup cannot miss because the transaction never removes `@`. Not worth extra machinery.
  - `[medium]` `[patch]` BH6 — `base_ignores` read `core.excludesFile` from the git config gix cached at `Repo::open` (jj-lib `git_backend.rs:356`), so a long-lived handle never saw a later change while the CLI re-reads per command — a fresh `gix::open_opts` with jj-lib's options per call; same-handle witness added.
  - `[low]` `[patch]` BH7 — `identity_missing` was set for both verbs although the CLI's raw-commit path never reaches `finish_transaction`'s identity warning — now `None`, documented on `MutationResult::identity_missing`, witnessed in `config_identity.rs`.
  - `[low]` `[reject]` BH8 — `snapshot.auto-track` parse diagnostics are discarded — fixing it needs a new payload field (new public surface) for warnings that almost never occur in everyday use.
  - `[false]` `[reject]` BH9 — ledger/spec bookkeeping (sprint-status `done` before review, `<intent-contract>` re-wrap, AC wording, twin-check result) — the re-wrap is byte-identical content explicitly allowed by the dispatch; status/ledger are finalized at this step; the twin check is recorded under Auto Run Result; ACs live outside the contract (fix = editing this spec).
  - `[low]` `[reject]` BH10 — Dart `_mutation`/`_exportFailures` duplicated from `git.dart`, `?? ''` for an absent path — the per-file private decoder copy and the `?? ''` projection are the existing house pattern (`git.dart:319-341`); deduplicating is a refactor across files, not a direct correction.
  - `[low]` `[reject]` BH11 — no tests for untrack on a non-colocated git backend skipping the export, the canonicalized-`.git`-parent branch, or an `Unspecified` kind — the internal-git untrack rows already run the `colocated = false` path; the `.git`-parent branch is the CLI port verbatim and needs a git-worktree fixture; `expect_request_kind`'s `Unspecified` handling is shared and covered by the other wrappers' suites.
  - `[medium]` `[patch]` EC1 — same defect as BH1 (grouped) — see BH1.
  - `[medium]` `[defer]` EC2 — `file_track` on a dirty working copy records every unsnapshotted edit into the WC state but not into `@` (tree discarded), so the state leads `@` even when nothing matched — same root cause as the 9.26 hazard; the fix (pre-verb snapshot) is excluded by the intent's Never tier; deferred (frontmatter `deferred[0]`, deferred-work.md).
  - `[low]` `[patch]` EC3 — `unmatched_explicit_paths` ran after `update_intent_to_add`/`export_refs`, so its read failure would leave the git index/refs rewritten with no op — moved before the reset/export.
  - `[low]` `[reject]` EC4 — same claim as BH5 (grouped) — see BH5.
  - `[medium]` `[patch]` EC5 — same as BH3's documentation half (grouped) — see BH3.
  - `[low]` `[patch]` EC6 — `Repo::file_track` rustdoc said `snapshot_stats` reports "ignored-and-unforced" files; jj-lib never reports ignored files — sentence corrected.
  - `[low]` `[patch]` VG1 — `identity_missing` for the two verbs was never exercised with an empty identity, and the Dart decoder fixture never set it — grouped with BH7: Rust witness asserts `None`; Dart decoder tests now set and read `identityMissing` inside both results.
  - `[medium]` `[patch]` VG2 — `include_ignored = true` never crossed the FFI reader or the Dart adapter/isolate in a test — FFI round trip and real-cdylib worker test with `include_ignored = true` added.
  - `[low]` `[patch]` VG3 — `UntrackResult.failed_bookmarks`/`failed_tags` only ever asserted empty — colocated untrack with a failing bookmark export added (recipe `git_sync.rs:424-429`).
  - `[false]` `[reject]` IA-a — "`a.txt` in `@` tree" is witnessed on the WC-state tree — the CLI's track discards the snapshot tree (oracle `track.rs`, re-confirmed with jj 0.45.1); the intent's step list and its "cannot tell which tool wrote the operation" rule select this reading (Design Notes).
  - `[false]` `[reject]` IA-b — "track: descendants" asserts no rebase — same oracle fact: `rebase_descendants` in `cmd_file_track` has nothing to rebase; the next snapshot rebases.
  - `[false]` `[reject]` IA-c — ACs rewritten toward reading B — ACs are outside the contract and the change would be an edit of this spec.
  - `[medium]` `[defer]` IA-d — observable non-parity after `file_track` (next verb refuses / commits then goes stale) — grouped with EC2, deferred to 9.26.
  - `[low]` `[reject]` IA-e — the concurrent-edit row is witnessed with a pre-call edit, not a race inside the lock window — a race cannot be injected deterministically; the pre-call edit drives exactly the row's code path (foreign tree difference → second `reset`) and asserts the row's outcome.
  - `[low]` `[patch]` IA-f — export failures ride `[GitExportFailure]` rather than a nested `GitExportResult`, with no failing-ref test — representation is the per-ref shape the row asks for; the missing failing-ref witness is VG3 (grouped).
  - `[low]` `[reject]` IA-g — path parsing accepts absolute in-workspace paths (beyond "repo-relative") — that is the CLI's own parse of a bare path argument (cwd = workspace root) and is what makes the matrix row `nope/` pass; documented, and the older verbs' gap is deferred (`deferred[1]`).
  - `[false]` `[reject]` IA-h — `base_ignores` reads `XDG_CONFIG_HOME` from the process env, not 9.27's `ConfigEnv` — the CLI reads it with `std::env::var` too (`cli_util.rs:1660-1667`).

### 2026-09-24 — Review pass (follow-up, `followup_pass = true`)
Review diff = this story's own range `fc362ce..5702724` (the four codegen outputs omitted; `schemas/envelope.fbs` included); every finding verified against HEAD `84a4df8`, which carries Stories 9.26/9.28 and the 9.27 follow-up on top.
- verdicts: 34 findings — high 0, medium 2, low 15, false 17, maybe-false 0
- findings:
  - `[false]` `[reject]` BH1 — `lock_working_copy` conflates the CLI's stale/sibling-op freshness cases with `ConcurrentWorkingCopy` — at HEAD every verb first runs 9.26's pre-verb snapshot, which calls `WorkingCopyFreshness::check_stale` (`snapshot.rs:678-685`) and refuses `Stale`/`SiblingOperation` as `PreconditionError::StaleWorkingCopy` with its own cause before `lock_working_copy` is reached; witnessed by `a_rewritten_but_unchecked_out_at_is_a_stale_working_copy`.
  - `[false]` `[reject]` BH2 — `file_track` never parses `snapshot.auto-track`, so it succeeds where the CLI fails — `Repo::file_track` calls `self.precondition()` first (`repo.rs:1669`), whose `Knobs::read` parses it via `wc_ops::auto_tracking_matcher` (`snapshot.rs:290`) and refuses before the verb.
  - `[false]` `[reject]` BH3 — nothing guards the "check_out verb commits, then goes stale" hazard after `file_track` — 9.26's pre-verb snapshot moves the tracked path into `@` before the next verb (`working_copy_verbs_after_track_snapshot_the_tracked_path_into_at_first`); the hazard no longer occurs.
  - `[false]` `[reject]` BH4 — `commit_with_locked_wc` is advertised as reusable by 9.26 and hardcodes `identity_missing: None` — the HEAD module doc (`mutate.rs:16-22`) names it the raw-transaction shape `file track`/`file untrack` use, and those are its only two callers (`wc_ops.rs:409,523`); the WHY comment at `:1185-1187` scopes `None` to them.
  - `[low]` `[reject]` BH5 — `base_ignores` re-opens git per call (cost on every verb since 9.26) while `update_intent_to_add`/`export_refs` use the cached repo — a gix open is milliseconds against a snapshot that walks the tree; the two cached-repo calls read no excludes config, so no mixed-config harm can be named; the fix (a stamp-keyed cache) adds state.
  - `[low]` `[reject]` BH6 — `jj.path_not_ignored` joins the offending paths with `\n`, a legal filename character — a newline in a tracked filename is rare in everyday use; the Rust variant already carries a `Vec<String>`, and a structured wire list would be new public surface.
  - `[false]` `[reject]` BH7 — sprint-status says `done` while the spec says `in-review` — both said `done` at `5702724`; `in-review` is this follow-up pass's own marker, reset to `done` at finalize.
  - `[low]` `[reject]` BH8 — the accepted path forms (absolute in-workspace, `./`, trailing `/`, `""` refused) are documented only in Rust rustdoc, not in `envelope.fbs`/Dart docs, and no seam test passes such a form — the wire docs are accurate for the repo-relative form a GUI supplies (the extra forms are a superset); the FFI reader passes strings through verbatim and the Rust suite pins the parse; an `envelope.fbs` doc edit forces regenerating four files.
  - `[low]` `[patch]` BH9a — `UntrackResult.snapshot_stats` was only ever asserted empty — added `untrack_reports_what_the_post_reset_snapshot_left_untracked` (a too-large new file surfaces as `FileTooLarge{20,10}` from the post-reset snapshot).
  - `[low]` `[reject]` BH9b — `NoWorkingCopy` witnessed for `file_track` only — `file_untrack` takes the identical precondition + `lock_working_copy` path, whose `NoWorkingCopy` arm has its own unit test (`mutate.rs:1560`); a duplicate row adds no coverage.
  - `[low]` `[reject]` BH9c — no FFI-wrapper witness for `jj.config_error`/`jj.no_working_copy` on the two symbols — the mapping is the shared, unit-tested `map_mutate_err`; since 9.26 a config error reaches these verbs as a `Precondition` code anyway.
  - `[false]` `[reject]` BH9d — the `base_ignores` tests only work because the first `tracked_after_track` records nothing (swap → `ConcurrentWorkingCopy`) — at HEAD the second call's pre-verb snapshot moves the first tracked path into `@` first, so the order no longer matters.
  - `[false]` `[reject]` BH10 — the Dart worker test reads the developer's real `~/.config/git/ignore` because `test-core`/`coverage` do not pin `XDG_CONFIG_HOME` — they do at HEAD (`Makefile.toml:136,524`, Story 9.28); the "pinned by `[tasks.test-flutter]`" header is the shared header of all eight worker suites.
  - `[false]` `[reject]` BH11a — `convert.rs`/`file.rs` docs still claim "Zanshin never snapshots" (D2) — no such text remains at HEAD (9.26 reworded both).
  - `[low]` `[patch]` BH11b — rustdoc/markdown lines left unwrapped — re-wrapped `repo.rs` (`file_track` rustdoc) and the `docs/ffi-abi.md` "Rows are grouped by noun" paragraph; the `convert.rs:76` line is already wrapped at HEAD.
  - `[false]` `[reject]` BH12a — `saturate`/`prefix_matcher` are needless wrappers — no caller diverges and no rule breaks; one definition each, `saturate` with its unit test.
  - `[false]` `[reject]` BH12b — the generic `build_aliases_map` lives in `revset.rs` — the spec's Code Map directed generalising it in place so both alias tables share one port; no named harm.
  - `[false]` `[reject]` BH12c — the revset-alias `tracing::warn!` texts were rewritten — log text only, now carrying `table = …`; nothing consumes the message text.
  - `[low]` `[reject]` EC1 — carried: `commit_with_locked_wc` can return `Err` after the op is committed (`finish`, post-commit `@` re-read) — same claim as BH5/EC4 of the first pass, code unchanged (`mutate.rs:1171-1177`); the CLI's own `finish` order.
  - `[low]` `[reject]` EC2 — a colocated untrack whose `export_refs` or `tx.commit` fails after `update_intent_to_add` leaves the git index rewritten with no op — the CLI has the identical order (`export_working_copy_changes_to_git` before `tx.commit` in `untrack.rs`, `cli_util.rs:2650-2661`); restoring the index would be rollback machinery the CLI lacks, for a failure that needs a broken git store.
  - `[false]` `[reject]` EC3 — `file_track` on a dirty WC makes later `check_out` verbs commit then fail — the first pass's deferred EC2; resolved at HEAD by 9.26 (see BH3).
  - `[false]` `[reject]` EC4 — missing `check_stale` in `lock_working_copy` — same refutation as BH1.
  - `[false]` `[reject]` EC5 — `file_track` does not parse `snapshot.auto-track` — same refutation as BH2.
  - `[low]` `[reject]` EC6 — claim: task (c) says `identity_missing(new_repo.settings())`, the code hardcodes `None` — deliberate CLI-parity change logged as the first pass's BH7; the fix would be an edit of this spec.
  - `[medium]` `[patch]` VG1 — `auto_track_resolves_fileset_aliases` passes whether or not aliases are expanded, and the non-table `[fileset-aliases]` refusal is unwitnessed — added `auto_track_alias_expansion_decides_the_untrack_refusal` (`everything = 'all()'` → `PathsNotIgnored`) and `a_non_table_fileset_aliases_is_a_config_error`; mutation-checked: both fail with the alias table name swapped.
  - `[medium]` `[patch]` VG2 — the `<home>/.config/git/ignore` fallback (the branch a Finder/Dock-launched app runs) never ran in a test — new binary `tests/file_track_home_git_ignore.rs` with `XDG_CONFIG_HOME=""` and a tempdir `HOME`; mutation-checked: fails with the fallback returning `None`.
  - `[false]` `[reject]` IA-a — carried: "`a.txt` in `@` tree" witnessed on the WC-state tree — first pass IA-a; code unchanged, GH #8298 reading.
  - `[false]` `[reject]` IA-b — after `track`, `check_out` verbs commit then go stale (stated only in rustdoc/deferred-work) — resolved at HEAD by 9.26 (see BH3).
  - `[low]` `[reject]` IA-c — carried: a second path convention (`parse_paths`) beside `build_matcher` — first pass IA-g; code unchanged.
  - `[low]` `[reject]` IA-d — carried: the concurrent-edit row is witnessed with a pre-call edit — first pass IA-e; code unchanged.
  - `[low]` `[reject]` IA-e — the wrong-typed-knob row's `jj.config_error` is tested only at the Rust layer — same as BH9c.
  - `[low]` `[patch]` IA-f — carried: export failures flattened into `UntrackResult`, failing case witnessed only in Rust — first pass IA-f/VG3; not re-patched.
  - `[low]` `[patch]` IA-g — carried: `identity_missing` always `None` — first pass BH7/VG1; not re-patched.
  - `[false]` `[reject]` IA-h — the Ask-First items were decided with no record of anyone being asked — Design Notes "Ask-First decisions (2026-09-23, Ralph delegated them to the spec's own proposals)" records it (the spec is not part of the reviewed diff).

## Design Notes

**Ask-First decisions (2026-09-23, Ralph delegated them to the spec's own proposals — resolved, not intent gaps):**
1. Non-ignored refusal: code `jj.path_not_ignored`, own variant `MutateError::PathsNotIgnored { paths }` (count = `paths.len()`), offending paths in `context`. The unmatched-explicit-paths fact is its OWN field `UntrackResult.unmatched_paths: [string]` — NOT `SkippedPath`, whose `reason` the CLI never prints for this case.
2. Receivers: `&mut self` on both verbs; every precondition (config, lock, concurrent check) lives inside `zanshin-jj`, none FFI-side.
3. `base_ignores()`: ported exactly, via jj-lib's own `get_git_backend(..).git_repo().config_snapshot()` / `gix::config::File::from_globals()`; the only new direct dependency is `etcetera` for `home_dir()` — the crate the CLI (and jj-lib's `expand_home_path`) uses, already in `Cargo.lock`.

**`@` after `track` (reading of the matrix rows "`a.txt` in `@` tree" and "track: descendants").** The contract's step list for `file_track` is the CLI's, and the CLI DISCARDS the snapshot tree: `track paths` writes an op whose view is unchanged; the tracked file lives in the working-copy state, and the NEXT command's snapshot (Story 9.26 in Zanshin; any `jj` command for a CLI user) moves it into `@` and rebases children — the CLI's own test says so ("TODO: fix GH #8298 so tracking is immediate"; the "Rebased 1 descendant commits onto updated working copy." line appears on the following `jj file list`). Rewriting `@` inside the track op would give a different op-log content and make the CLI's next command skip its snapshot op — a user could tell. So: "`a.txt` in `@` tree" is witnessed on the WC-state tree plus "view `@` unchanged"; `num_rebased` is computed exactly as the CLI does (always 0 for track today) and the descendant row asserts children are NOT rebased by the verb. This follows the contract's Always tier (CLI parity, the literal step list) and AC-1's twin comparison, which the literal row reading would fail.

**Why an always-commit sibling and not `finish_or_no_op`:** `finish_or_no_op` reproduces `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard; `track`/`untrack` commit the raw `Transaction` (`into_inner()`), so they bypass it — and also bypass `finish_transaction`'s git HEAD export/ITA update, which is why only untrack's explicit `export_working_copy_changes_to_git` runs. Both still open through `start_repo_transaction` (workspace-name metadata; the creep guard keeps zero exceptions). Borrow/lock order as in the CLI: tx → lock → work → commit → `finish(op_id)`.

**Lock helper vs `sync_working_copy`:** `sync_working_copy` uses `Workspace::check_out` and rewrites files; `snapshot`/`reset` never touch files. After `untrack`, the WC state was `reset` to the new `@`, so no checkout follows. Story 9.26 drives the lock helper (b) and the snapshot-options builder / `SnapshotStats` conversion / `merge_track_stats` with its own conditional commit; keep them `pub(crate)` single definitions.

**New error codes (house rule "own code when the remedy differs"):** `jj.concurrent_working_copy` (remedy: retry — the CLI's "Concurrent working copy operation. Try again."); `NoWorkingCopy` reuses the registered `jj.no_working_copy` (CLI "Nothing checked out in this workspace"). jj-lib failures of `snapshot`/`reset`/`finish`/`update_intent_to_add`/`base_ignores` → `Backend` (`jj.jj_lib_error`); export per-ref failures ride the result, never an error.

**`snapshot.auto-track` is parsed as a fileset** (`fileset::parse`, not `parse_maybe_bare`) with the fileset aliases and the root path converter, exactly as the CLI parses the CONFIG value. The contract's "no fileset DSL" is about the user's `paths` argument, which stays `PrefixMatcher` (`op_support::build_matcher`).

## Verification

**Commands:**
- `cargo make codegen` then `git status` -- expected: the four generated files changed and committed; tree clean.
- `cargo make --allow-private <each dependency of [tasks.test] in Makefile.toml>` then `cargo make --allow-private coverage` -- expected: all PASS except the known pre-existing `test-flutter` splash-card failures (`app/test/features/bootstrap/zanshin_bootstrap_test.dart`, red since `677dbf5`); `ffi_abi_doc_sync` green; coverage ≥ baseline, `wc_ops.rs` ≥ 80 %.

**Manual checks (if no CLI):**
- Twin check with the installed `jj` (0.45.1 — its `track.rs`/`untrack.rs` differ from v0.44.0 only by an import path and an export parameter): same sequence on twin copies of a scratch colocated repo → identical `jj op log` descriptions/count and `git ls-files`.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** `Repo::file_track(paths, include_ignored)` / `Repo::file_untrack(paths)` port `cmd_file_track` / `cmd_file_untrack` @ jj v0.44.0 step for step and always commit `track paths` / `untrack paths`. The locked-working-copy primitives Story 9.26 drives now exist: `mutate::lock_working_copy` (the CLI's `start_working_copy_mutation` checks) and `mutate::commit_with_locked_wc` (tx → lock → work → unconditional commit → `finish`), plus `wc_ops::{snapshot_options, base_ignores, auto_tracking_matcher, is_colocated_git_workspace, project_stats, merge_track_stats, parse_paths}` and the shared `SnapshotStats` payload. Surfaced end to end: fbs tables + union, `zanshin_file_track` / `zanshin_file_untrack`, Dart worker commands and `RepoHandle` methods, docs.

**Implementation decision beyond the planned tasks.** Paths are parsed like the CLI's bare path argument with cwd = the workspace root (`RepoPathBuf::parse_fs_path(root, root, entry)`), not through `op_support::build_matcher`: the matrix row `paths=["nope/"]` requires the normalisation, and the empty entry `""` is refused as the CLI refuses it. The six older path verbs keep `build_matcher` (deferred).

**Files changed.**
- `crates/zanshin-jj/src/wc_ops.rs` (new) — the two verbs, result/stats types, snapshot primitives, path parsing, colocation check.
- `crates/zanshin-jj/src/mutate.rs` — `NoWorkingCopy` / `ConcurrentWorkingCopy` / `PathsNotIgnored` variants, `lock_working_copy`, `commit_with_locked_wc`, doc updates.
- `crates/zanshin-jj/src/config.rs` — builtin `[snapshot]` defaults, `snapshot_max_new_file_size` / `snapshot_auto_track` readers + inline tests.
- `crates/zanshin-jj/src/revset.rs` — `build_aliases_map` generic over the alias parser and table name (`fileset-aliases`).
- `crates/zanshin-jj/src/{repo,lib,git,convert,file,op_support}.rs`, `crates/zanshin-jj/Cargo.toml`, root `Cargo.toml`/`Cargo.lock` — public verbs, re-exports, `pub(crate)` export helpers, stale 9.22 pointers reworded, `etcetera` (already a jj-lib transitive).
- `crates/zanshin-jj/tests/file_track_untrack.rs` (new, 36 tests), `tests/config_identity.rs`, `tests/api_stability.rs` — matrix witnesses, CLI sequence, `base_ignores` chain, surface pins.
- `schemas/envelope.fbs` + regenerated `envelope_generated.rs`, `zanshin_ffi.h`, `envelope_zanshin.ffi_generated.dart`, `bindings.dart`.
- `crates/zanshin-ffi/src/file_ops.rs` (new), `envelope.rs`, `repo.rs` (+3 mapper tests), `git.rs`, `lib.rs`; `tests/file_ops_ffi.rs` (new), `tests/ffi_abi_doc_sync.rs` (49 exports).
- `packages/zanshin_core/lib/src/ffi/file_ops.dart` (new), `worker/{commands,isolate,handle}.dart`; `test/ffi/file_ops_test.dart`, `test/worker/file_ops_test.dart` (new, real-cdylib witnesses).
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` — two symbol rows, request-contract counts, `jj.path_not_ignored`, `jj.concurrent_working_copy`, widened `jj.no_working_copy`.
- `coverage-baseline.txt` — auto-raised (`wc_ops.rs` 97.85, `file_ops.rs` 100.00, `mutate.rs` 98.14).
- `_bmad-output/implementation-artifacts/{deferred-work.md, sprint-status.yaml, spec-9-26-…md}` — deferrals, row → done, 9.26 handoff note (outside its frozen block).

**Review findings breakdown (28).** Patches applied (10 entries; entry verdicts: 4 medium, 6 low): empty path refused (BH1/EC1), 9.26 handoff note (BH2), check_out-verb hazard documented on the verb and handle (BH3/EC5), neutral `ConcurrentWorkingCopy` wording (BH4), fresh gix config per `base_ignores` call (BH6), `identity_missing` = None like the CLI + witnesses (BH7/VG1), unmatched-paths read moved before the git export (EC3), stats rustdoc corrected (EC6), `include_ignored` FFI/Dart round trips (VG2), failing-bookmark-export witness (VG3/IA-f). Deferred (2): WC state leads `@` after `file_track` until 9.26 (EC2/IA-d, medium); shared `build_matcher` path normalisation for the older verbs (low). Rejected: BH5/EC4 (post-commit error mirrors the CLI's own `finish` order, the `@` lookup cannot miss), BH8 (would need new payload surface for rare warnings), BH9 (false; bookkeeping settled at finalize, re-wrap allowed), BH10 (existing Dart decoder house pattern), BH11 (paths already exercised, or a CLI-verbatim branch needing a worktree fixture), IA-a/IA-b/IA-c/IA-h (false — CLI oracle and jj 0.45.1 confirm), IA-e (race not injectable; the same code path is witnessed), IA-g (the CLI's own path parse).

**Follow-up review recommendation:** `true` — four medium entries were patched after the review pass (empty-path refusal, `base_ignores` fresh open, the hazard docs, the `include_ignored` bridge tests). Only the `base_ignores` witness was mutation-checked (it fails against the cached-config code); the other patched behaviour has had no second review.

**Verification.** `cargo make codegen` (generated files regenerated and committed). Gate steps run one by one with `cargo make --allow-private <task>`: test-cargo, test-clippy, test-fmt, test-dart-analyze, test-dart-format, test-core (342 tests), test-core-analyze, test-core-format, every test-shell*/test-settings* step, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene, coverage — all PASS; test-flutter FAILS only on the 3 pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` splash-card tests (red since `677dbf5`, UI scope). Coverage overall 99.27 %, no regression. Manual CLI check with the installed jj 0.45.1: with `auto-track = none()`, `jj file track a.txt` writes `track paths`, `@` read with `--ignore-working-copy` stays empty, and the next command writes `snapshot working copy` containing `a.txt` — the reading the tests pin.

**Residual risks.** Until Story 9.26 lands, a `file_track` on a dirty or newly-tracked working copy leaves the working-copy state ahead of `@`: the next track/untrack refuses, and every `check_out`-based verb commits and then fails with a stale working copy (recoverable only with `jj workspace update-stale` until Story 9.23). Do not wire `fileTrack` into the UI before 9.26.

### Follow-up review pass (2026-09-24)

Status: done. Blocking condition: none. Requested by Ralph (2026-09-23) because the first pass cross-checked only one of its patches.

**Scope.** Review diff = this story's own commits `fc362ce..5702724` (c79d619 + 5702724); every finding classified against HEAD `84a4df8` (Stories 9.26, 9.28 and the 9.27 follow-up stacked on top). The first pass's patched paths (empty-path refusal, fresh-gix `base_ignores`, `identity_missing = None`, unmatched-paths ordering, hazard docs, `include_ignored` bridge tests) and the locked-WC primitives (`mutate::lock_working_copy` / `commit_with_locked_wc`, `wc_ops.rs`) were re-read at HEAD: no defect found in them. The freshness gap (BH1/EC4) and the post-track hazard (BH3/EC3/IA-b, the first pass's deferral) are closed at HEAD by 9.26's pre-verb snapshot (`snapshot.rs:678`).

**Change (tests and docs only, no production behaviour).**
- `crates/zanshin-jj/tests/file_track_untrack.rs` — three rows: fileset-alias expansion decides the untrack refusal; a non-table `[fileset-aliases]` is a config error; untrack's `snapshot_stats` carries the post-reset snapshot's `FileTooLarge`.
- `crates/zanshin-jj/tests/file_track_home_git_ignore.rs` (new binary) — an empty `$XDG_CONFIG_HOME` falls back to `<home>/.config/git/ignore`.
- `crates/zanshin-jj/src/repo.rs`, `docs/ffi-abi.md` — re-wrapped overlong doc lines.

**Findings breakdown (34).** Patched: 4 entries — medium 2 (VG1 alias-expansion witnesses, VG2 home-fallback witness), low 2 (BH9a untrack stats witness, BH11b doc wrapping); both medium patches mutation-checked. Deferred: none. Rejected: 17 false (BH1-4, BH7, BH9d, BH10, BH11a, BH12a-c, EC3-5, IA-a, IA-b, IA-h — mostly closed at HEAD by 9.26/9.28 or no named harm); 11 low (BH5 per-call gix open, BH6 `\n`-joined context, BH8 wire-doc path forms, BH9b/BH9c/IA-e duplicate witnesses, EC1 carried post-commit `Err`, EC2 colocated export before commit = CLI order, EC6 spec-text claim, IA-c/IA-d carried); IA-f/IA-g carried from the first pass's patches, not re-patched.

**Follow-up review recommendation:** `false` — follow-up pass, no `high` patched (medium 2, low 2).

**Verification.** `cargo make --allow-private <task>` for every `[tasks.test]` dependency, in order: test-cargo PASS, test-clippy PASS, test-fmt PASS, test-flutter FAIL (only the 3 known pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` splash-card tests, UI scope), test-dart-analyze PASS, test-dart-format PASS, test-core PASS, test-core-analyze PASS, test-core-format PASS, test-shell/-analyze/-format PASS, test-shell-pi/-analyze/-format PASS, test-shell-macos/-analyze/-format PASS, test-settings/-analyze/-format PASS, test-cargo-deny PASS, test-cargo-hygiene PASS, test-jj-adapter-hygiene PASS, coverage PASS (99.38 %, held; baseline unchanged). `pubspec.lock` drift reverted.

**Residual risks.** The deferral `deferred[0]` (WC state leads `@` after `file_track`) is resolved at HEAD by Story 9.26 (`fadbbfc`); `deferred[1]` (`build_matcher` path normalisation for the older verbs) stands.
