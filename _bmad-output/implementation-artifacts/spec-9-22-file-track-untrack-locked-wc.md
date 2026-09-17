---
title: 'Story 9.22: `file track`, `file untrack` (locked-WC lifecycle)'
type: 'feature'
created: '2026-09-17'
status: 'draft'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

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

</frozen-after-approval>

## Code Map

- `crates/zanshin-jj/src/file.rs` -- Story 9.4 file reads; home of the two verbs or a new `wc_ops.rs` (step-02 decides; one module owns the locked-WC helper)
- `crates/zanshin-jj/src/mutate.rs` -- `finish_or_no_op{,_at}`, `capture_old_wc`, `sync_working_copy` (`Workspace::check_out`, touches files); add the always-commit helper and the lock-scoped helper beside them
- `crates/zanshin-jj/src/op_support.rs` -- `start_repo_transaction` (the mandatory opener), `resolve_immutable`
- `crates/zanshin-jj/src/config.rs` -- `load` / `load_for_workspace`; add the `snapshot.*` readers and the `base_ignores()` port
- `crates/zanshin-jj/src/repo.rs` -- `Repo { workspace, settings }`, `workspace_mut()`, public verbs
- `crates/zanshin-jj/src/git.rs` -- `export_refs` call site to reuse in `export_working_copy_changes_to_git`
- `crates/zanshin-jj/tests/status.rs:57`, `tests/commit_views.rs:203` -- existing in-test lock → snapshot → finish recipes
- `crates/zanshin-jj/tests/convert.rs:86-100` -- `git` CLI recipe for colocated fixtures
- `crates/zanshin-ffi/src/file.rs` -- Story 9.4 wrappers; add `zanshin_file_track` / `zanshin_file_untrack`
- `schemas/envelope.fbs` -- `FileTrackRequest`, `FileUntrackRequest`, `SnapshotStats`, `UntrackedPath`, `TrackResult`, `UntrackResult`; `RequestKind`; `Payload` union
- `crates/zanshin-ffi/src/envelope_generated.rs`, `crates/zanshin-ffi/include/zanshin_ffi.h`, `packages/zanshin_core/lib/src/**` -- codegen outputs, worker commands
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbol rows, request tables, new code
- `../jj` @ v0.44.0 -- `cli/src/commands/file/{track,untrack}.rs`; `cli/src/cli_util.rs:1604-1700` (matchers, options, ignores), `:2650-2661` (`export_working_copy_changes_to_git`); `lib/src/working_copy.rs:110-140` (`LockedWorkingCopy`), `:206-255` (`SnapshotOptions`, `SnapshotStats`); `lib/src/workspace.rs:446-500` (`LockedWorkspace`)

## Tasks & Acceptance

**Execution:**
- [ ] `crates/zanshin-jj/src/config.rs` -- `snapshot.*` readers + `base_ignores()` port -- knobs come from the effective config like every other reader
- [ ] `crates/zanshin-jj/src/mutate.rs` -- always-commit transaction helper + lock-scoped WC helper -- both verbs and Story 9.26 share one lifecycle
- [ ] `crates/zanshin-jj/src/file.rs` (or `wc_ops.rs`) -- `file_track` / `file_untrack` per the oracle -- the verbs
- [ ] `crates/zanshin-jj/src/repo.rs`, `lib.rs` -- public `Repo::file_track` / `Repo::file_untrack`, typed results, error variants -- public surface
- [ ] `schemas/envelope.fbs` + `cargo make codegen` -- tables above; commit generated files -- wire contract
- [ ] `crates/zanshin-ffi/src/file.rs` -- two wrappers, request verification, error mapping -- FFI
- [ ] `packages/zanshin_core` -- `WorkerCommand`s + cdylib witnesses -- bridge (in scope per project rule)
- [ ] `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows -- `ffi_abi_doc_sync` enforces the first
- [ ] `crates/zanshin-jj/tests/` -- a witness per matrix row, colocated rows via the `git` recipe -- gate
- [ ] `coverage-baseline.txt` -- commit the auto-raised baseline -- ratchet

**Acceptance Criteria:**
- Given a fixture and the same sequence run with `jj file track` / `jj file untrack` @ v0.44.0 on a twin copy, when Zanshin runs the verbs, then `jj op log` shows the same number of operations with the same descriptions and `@` has the same tree.
- Given a non-ignored path, when `file_untrack` runs, then no operation is written, the working-copy state file is unchanged and the refusal names the path(s).
- Given a colocated workspace, when `file_untrack` succeeds, then `.git`'s index no longer lists the path and refs are exported.
- Given every matrix row, then a test exercises it and `cargo make test` is green including the coverage ratchet.

## Design Notes

- Why a separate always-commit helper: `finish_or_no_op` reproduces `WorkspaceCommandTransaction::finish`'s "Nothing changed." guard. `track`/`untrack` bypass that guard by committing the raw transaction, so reproducing THEM means bypassing it too. Route both through `start_repo_transaction` so the op-metadata guard keeps zero exceptions.
- The lock-scoped helper is not a second `sync_working_copy`: that one uses `Workspace::check_out` and changes files; `snapshot`/`reset` never touch files. Keep both in `mutate.rs`, documented against each other.
- Borrow order as in the CLI: transaction first, `start_working_copy_mutation` second, `finish(op_id)` after `commit`. `LockedWorkspace<'_>` holds `&mut Workspace`, so `Repo` hands out `workspace_mut()` for the duration of the verb only.

## Verification

**Commands:**
- `cargo make test` -- expected: green, coverage ≥ baseline, `ffi_abi_doc_sync` green
- `cargo make codegen` then `git status` -- expected: header/bindings regenerated and committed, tree clean

**Manual checks (if no CLI):**
- On a scratch colocated repo: `jj file untrack` via CLI vs. via Zanshin on twin copies → identical `jj op log` and `git status`.
