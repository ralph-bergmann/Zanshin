---
title: 'Story 9.26: Implicit snapshot + colocated Git import before every verb (`workspace_helper` parity, reverses D2)'
type: 'feature'
created: '2026-09-17'
status: 'draft'
review_loop_iteration: 0
context: []
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** Almost every jj CLI command starts with `workspace_helper` → `snapshot_impl` (`cli/src/cli_util.rs:472-516`, `:1298-1326` @ v0.44.0). In a colocated workspace that imports Git `HEAD` (re-parenting `@` and resetting the working-copy state when HEAD moved), snapshots the working copy into `@`, then imports Git refs; a non-colocated workspace gets the snapshot alone. Zanshin does none of it: project decision D2 (Story 2.4) made every verb a pure read of the last-snapshotted `@`, betting that Watchman would snapshot at the system level. That bet does not hold. Watchman is opt-in and not bundled, jj-lib triggers none of this on its own, and the trigger the CLI registers with Watchman excludes `.git` and `.jj` (`lib/src/fsmonitor.rs:318-337`), so a `git commit`, `git checkout`, an IDE's background fetch or a plain file edit made outside Zanshin leaves every Zanshin verb showing a stale `@`, stale bookmarks and a stale HEAD until the user runs a `jj` CLI command. A user switching between the CLI and Zanshin sees two different repositories.

**Approach:** Reverse D2. Port `snapshot_impl` and its three halves as ONE `zanshin-jj` precondition that every verb whose CLI counterpart runs through `workspace_helper` executes first, under the CLI's `git_import_export.lock`, with every knob read from the effective config; expose `jj util snapshot` as an explicit verb; return `SnapshotStats` and the import facts as typed payload. Ralph's rule (2026-09-06, reaffirmed 2026-09-17): Zanshin behaves exactly like the jj CLI so a user can switch between both without thinking — the op log a CLI user sees after a Zanshin session must be the one the CLI itself would have written.

## Boundaries & Constraints

**Always:**
- **Sequence and operation descriptions exactly as `snapshot_impl`.** Colocated → `import git head` (`import_git_head`, `cli_util.rs:1352-1416`: `git::import_head`; if HEAD changed: `check_out(new HEAD)` → `locked_wc.reset(wc_commit)` → `rebase_descendants` → commit; HEAD deleted → `rebase_descendants` only). Then `snapshot working copy` (`snapshot_working_copy`, `:2058-2231`: `handle_stale_working_copy`, `snapshot(options)`, and only when the tree changed: `set_is_snapshot(true)`, immutable `@` → a NEW commit on top instead of a rewrite, `set_wc_commit`, `rebase_descendants`, colocated → `try_reset_git_head` + `export_refs` for the on-top case or `export_working_copy_changes_to_git` for the rewrite case, commit, `locked_ws.finish`). Then colocated → `import git refs` (`import_git_refs`, `:1428-1460`: `git::import_refs(options)` → `rebase_mutable_descendants` → commit). Each operation is written only when its transaction `has_changes()`. Non-colocated = the middle step only.
- **Where it runs.** Before every verb whose CLI counterpart calls `workspace_helper` / `workspace_helper_with_stats` — reads and mutations alike: `status`, graph/`log`, `show`/`evolog`/`interdiff`, `diff`, `file *`, `describe`/`new`/`edit`/`abandon`/`undo`, `restore`/`absorb`, `bookmark *`, `git fetch/import/export/remote *`, `workspace list`, and every later Epic 9 verb. NOT before the CLI's `workspace_helper_no_snapshot` set (`workspace root`, `op integrate`, `util backend name`, `debug *`, `bench *`), and NOT before Zanshin's creation/detection paths (`detect`, `open`, `init`, `clone`, `convert`), which already mirror the CLI's own import steps. Story 9.21's at-op reads follow the CLI's `--at-op` rule (no snapshot when not at head).
- **The lock is parity, not a new lock.** `<repo_path>/git_import_export.lock` via jj-lib `FileLock` (`cli_util.rs:983-996`), taken for colocated workspaces only, held across the whole precondition AND across the colocated `export_refs`/`reset_head` inside every mutation's finish — the CLI holds it from `workspace_helper` to `finish_transaction`. `FileLock::lock` waits; there is no "busy" outcome. project-context's "no cross-process locks" rule (`:639-642`) is about `op_heads`; amend it to name this jj-owned lock as the one exception.
- **Effective config for everything the CLI reads on this path:** `snapshot.auto-track`, `snapshot.max-new-file-size`, `snapshot.auto-update-stale`, `git.abandon-unreachable-commits`, `git.record-synthetic-predecessors`, `remotes.<name>.auto-track-bookmarks` (open ledger item, same reader), `fsmonitor.backend`, `fsmonitor.watchman.register-snapshot-trigger`, and the `immutable_heads()` alias for the immutable-`@` check. **Prerequisite:** `Repo::open`/`init`/`clone` must build their `UserSettings` from the effective config stack (`config::load_for_workspace`). Today `repo.rs::make_settings` hardcodes `user.name`/`user.email`/`operation.username`/`operation.hostname` and adds NO user config layers, so jj-lib's working-copy `fsmonitor` settings and every op/commit identity Zanshin writes come from that stub. **Story 9.27** (`spec-9-27-effective-user-settings-config-stack.md`) lands it BEFORE this story — this story's tests assume it.
- **jj-lib `watchman` feature on.** The CLI's default features are `["watchman", "git"]` (`cli/Cargo.toml:139`); jj-lib's default is `["git"]`, which is what the workspace pin uses. Without the feature a user's `fsmonitor.backend = "watchman"` makes every snapshot fail with jj-lib's "not compiled with the `watchman` feature" error. Enable it on the workspace pin; `cargo deny` stays green (adds `watchman_client` + `tokio`). Zanshin still never bundles or launches Watchman beyond what jj-lib's client does — amend project-context `:245-248` accordingly.
- **Stale working copy** as `handle_stale_working_copy` (`:2952-3020`): `Fresh` → proceed; `Updated(op)` → reload the repo at the working copy's operation and proceed; `WorkingCopyStale`, `SiblingOperation`, unreadable WC operation → typed refusal, no operation written; `snapshot.auto-update-stale = true` routes to Story 9.23's recovery (`recover_stale_working_copy_impl`) — until 9.23 lands it is the same refusal.
- **Facts that ride the payload** (each a typed field, never text): `SnapshotStats` (the table Story 9.22 defines), `was_snapshot_taken`, `working_copy_immutable_new_commit` (the "immutable; a new commit has been created on top" warning), `rebased_descendants` per step, `git_head_reset` (the "Reset the working copy parent to the new Git HEAD" fact), the `import git refs` projection Story 9.5 already uses (`GitImportResult`: changed bookmarks/tags, abandoned, failed refs), the colocated `.jjconflict` warning, `export_refs` failures.
- **Explicit verb.** `jj util snapshot` (`cli/src/commands/util/snapshot.rs`: `workspace_helper_with_stats` + stats + `was_snapshot_taken`) as `Repo::snapshot()`; the GUI's "sync now" and the watcher's file-change handler call it.
- **Loop-free with the watcher.** A Zanshin-written operation fires `OpHeadsChanged` → UI refresh → verbs → precondition → nothing changed → no operation; `LockedWorkspace::finish` writes nothing when the tree state is clean and the op id is unchanged (`local_working_copy.rs:2922-2948`). A test pins that a refresh after a Zanshin snapshot writes zero operations.
- **Knock-ons closed in the same change:** `convert.rs::import_git_head` gains the `check_out` + `reset` half (ledger item of 2026-09-06, same port); `git.rs`'s "no colocated skip" divergence note (`git.rs:46-54`) becomes obsolete — after the precondition, `git_import`/`git_export` in a colocated workspace find nothing to do, the CLI's observable end state — delete the note, add the witness; every "Zanshin never snapshots (D2)" paragraph goes (`status.rs`, `revset.rs`, `mutate.rs`, `file.rs`, `commit_views.rs`, `bookmark_ops.rs`, `op_support.rs`, `repo.rs`, `convert.rs`, `git.rs`, `docs/ffi-abi.md`); Story 2.4's D2 note in `epics.md:1233-1236` and ADR-0002's "Zanshin reacts, never initiates" get a dated addendum pointing here; the on-disk-edit witnesses Stories 9.3/9.4/9.7 documented as missing are added.
- Surface: `.fbs` → `zanshin-jj` → `extern "C"` (`zanshin_snapshot` plus the payload widening on existing wrappers) → `WorkerCommand`; codegen committed; `docs/ffi-abi.md` + `docs/rust-error-codes.md` rows; coverage ratchet. MCP (Epic 7) inherits automatically because it goes through `zanshin-jj`.

**Ask First:**
- Payload shape: `SnapshotStats` + import facts as an optional `precondition` table on EVERY envelope vs. only on `zanshin_snapshot` and `MutationResult` (recommendation: every envelope, because the CLI reports them on every command).
- Receiver change: the precondition mutates the workspace, so either `Repo`'s read verbs become `&mut self` or the FFI wrapper runs the precondition first and keeps the reads `&self` — decide once, apply everywhere.
- Error-code names: `jj.stale_working_copy` (the CLI's three causes as `context`), any new export-failure code.
- Enabling the jj-lib `watchman` feature (dependency-tree change) and amending project-context `:245-248` / `:639-642`.

**Never:**
- No caching, debouncing, timers or "only snapshot if the watcher saw something" heuristics: the trigger is the verb call, exactly like the CLI; the UI decides WHEN to call (FR-JJ-17).
- No terminal text ("Done importing changes from the underlying Git repo.", "Rebased N …", hints), no `--ignore-working-copy` / `--at-op` / `--no-integrate-operation` flags.
- Not Story 9.23's stale recovery, not Story 9.22's `file track`/`untrack`, not Watchman detection (FR-FFI-7).
- No hardcoded knobs, no silent fallback on a wrong-typed config value (→ `jj.config_error`).
- No lowering of `coverage-baseline.txt`, no `exclude_prefix`.

## I/O & Edge-Case Matrix

Colocated workspace unless stated. "op" = one entry in `jj op log`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Nothing changed | clean tree, refs unchanged | no op; `was_snapshot_taken=false`; stats empty | N/A |
| File edited outside Zanshin (non-colocated) | tracked file modified | one op `snapshot working copy` (`is_snapshot=true`); `@` tree updated | N/A |
| New file over limit | `snapshot.max-new-file-size` exceeded | not tracked; stats `FileTooLarge`; op only if other changes | N/A |
| `snapshot.auto-track = "none()"` | new file | untracked; stats `FileNotAutoTracked`; no op | N/A |
| `git commit` outside | HEAD moved, tree unchanged | op `import git head` (new empty `@` on the new HEAD, old `@` abandoned if discardable, `git_head_reset=true`), then op `import git refs` (branch moved) | N/A |
| `git fetch` outside (IDE) | only `refs/remotes/*` changed | one op `import git refs`; remote bookmarks updated; tracked locals merged; abandoned per `git.abandon-unreachable-commits` | N/A |
| `git checkout other` outside | HEAD + files changed | op `import git head`; WC state reset without touching files; snapshot finds no diff; refs op only if refs moved | N/A |
| `git switch -c new` outside | HEAD symbolic → new branch, same commit | no HEAD import (same target); op `import git refs` (new bookmark) | N/A |
| `@` immutable | `immutable_heads()` covers `@`, file edited | new commit ON TOP; `working_copy_immutable_new_commit=true`; git HEAD reset to it | N/A |
| Stale WC | another workspace advanced heads; `snapshot.auto-update-stale=false` | no op | `jj.stale_working_copy` |
| Updated WC | CLI snapshotted between load and lock | repo reloaded at the WC's op; proceed | N/A |
| Concurrent CLI holds the lock | `git_import_export.lock` held | waits, then proceeds | N/A |
| No-snapshot verb | `workspace root` on a dirty tree | no precondition; no op | N/A |
| Explicit verb | `Repo::snapshot()` on a dirty tree | op `snapshot working copy`; `was_snapshot_taken=true` | N/A |
| Zanshin's own op → watcher → refresh | after any row above | zero further ops | N/A |
| `.jjconflict` files present | user `git checkout`ed a conflicted commit | flag set; snapshot proceeds | N/A |
| Watchman configured, daemon unavailable | `fsmonitor.backend="watchman"` | snapshot fails as in the CLI | `jj.jj_lib_error` with jj-lib's message |
| Wrong-typed knob | `snapshot.max-new-file-size = true` | refused before the lock | `jj.config_error` (key) |
| Native backend | `init_simple` workspace | middle step only; no lock, no git steps | N/A |

</frozen-after-approval>

## Code Map

- `crates/zanshin-jj/src/repo.rs` -- `Repo { workspace, settings }`, `open` (settings from Story 9.27), every public verb = a call site of the precondition
- `crates/zanshin-jj/src/mutate.rs` -- `finish_or_no_op{,_at}`, `capture_old_wc`, `sync_working_copy`; the lock has to wrap the colocated export in the finish path; Story 9.22's lock-scoped helper lives here (`lock_working_copy`, `commit_with_locked_wc`)
- `crates/zanshin-jj/src/wc_ops.rs` (added by Story 9.22, 2026-09-23) -- `snapshot_options`, `base_ignores`, `auto_tracking_matcher`, `project_stats`, `SnapshotStats`, `merge_track_stats`. HANDOFF: `Repo::file_track` / `Repo::file_untrack` are CLI `workspace_helper_with_stats` / `workspace_helper` verbs, so the precondition runs in front of them too (before `lock_working_copy`); `file_track` must pass the precondition's `SnapshotStats` into `merge_track_stats` in place of today's `SnapshotStats::default()` (`print_track_snapshot_stats`). Until this lands, a `file_track` leaves the working-copy state AHEAD of `@` and every later `check_out`-based verb commits and then fails stale (deferred-work.md, "Surfaced 2026-09-23 while implementing Story 9.22").
- `crates/zanshin-jj/src/op_support.rs` -- `start_repo_transaction` (add the `set_is_snapshot(true)` caller), `resolve_immutable`
- `crates/zanshin-jj/src/git.rs` -- `git_import` (the `import_head` → `import_refs` pair to reuse), `git_export`, `project_*` helpers, the divergence note at `:46-54`
- `crates/zanshin-jj/src/convert.rs` -- `import_git_head` (gains `reset`), `is_colocated` (promote to the shared helper = CLI `is_colocated_git_workspace`, `cli/src/git_util.rs:62`)
- `crates/zanshin-jj/src/config.rs` -- readers for the knobs above; `git_import_options`
- `crates/zanshin-jj/src/status.rs`, `revset.rs`, `file.rs`, `commit_views.rs`, `bookmark_ops.rs`, `workspace.rs` -- D2 paragraphs; `workspace.rs::resolve_workspace_root` is the no-snapshot verb
- `crates/zanshin-ffi/src/*.rs`, `handle.rs` (raw `&mut Repo` from a handle) -- where the precondition attaches if it stays outside `Repo`
- `schemas/envelope.fbs` -- `SnapshotStats` (9.22), the precondition/snapshot tables, `Payload` union, `RequestKind`
- `packages/zanshin_core` -- `WorkerCommand` for `snapshot`; cdylib witnesses
- `Cargo.toml` (workspace root), `deny.toml` -- `jj-lib` features `["watchman"]`
- `_bmad-output/project-context.md:245-248`, `:639-642`; `docs/adr/0002-*.md`; `_bmad-output/planning-artifacts/epics.md:1233-1236` -- rules and notes to amend
- `crates/zanshin-jj/tests/status.rs:57` (in-test snapshot recipe), `tests/convert.rs:86-100` (`git` CLI recipe), `tests/concurrent_writes.rs` -- fixtures and patterns
- `../jj` @ v0.44.0 -- `cli/src/cli_util.rs:472-516`, `:983-996`, `:1298-1460`, `:2058-2231`, `:2650-2695`, `:2952-3020`, `:3230-3249`; `cli/src/commands/util/snapshot.rs`; `lib/src/fsmonitor.rs`; `lib/src/working_copy.rs`; `lib/src/local_working_copy.rs:2922-2948`

## Tasks & Acceptance

**Execution:**
- [ ] `Cargo.toml`, `deny.toml` -- enable `jj-lib/watchman`; `cargo deny` green -- CLI default feature set
- [ ] `crates/zanshin-jj/src/config.rs` -- readers for every knob above -- FR-JJ-17
- [ ] `crates/zanshin-jj/src/convert.rs` → shared module -- promote `is_colocated`; add the git import/export lock helper -- one colocation check, one lock
- [ ] `crates/zanshin-jj/src/git.rs` -- factor `import_head`-with-reset and `import_refs` steps out of `git_import` so the precondition and the explicit verbs share them -- one port, two callers
- [ ] `crates/zanshin-jj/src/mutate.rs` (or `snapshot.rs`) -- the precondition: lock → stale check → import head → snapshot → import refs; the explicit `snapshot()` verb -- the story
- [ ] `crates/zanshin-jj/src/repo.rs` + every verb module -- run the precondition per the "where it runs" rule; delete D2 paragraphs -- coverage of the rule
- [ ] `crates/zanshin-jj/src/convert.rs` -- `import_git_head` gains `check_out` + `reset` -- closes the 2026-09-06 ledger item
- [ ] `schemas/envelope.fbs` + `cargo make codegen` -- payload tables; commit generated files -- wire contract
- [ ] `crates/zanshin-ffi/src/*.rs` -- `zanshin_snapshot`; payload widening; error mapping -- FFI
- [ ] `packages/zanshin_core` -- `WorkerCommand`; witnesses -- bridge
- [ ] `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `docs/adr/0002-*.md`, `epics.md:1233-1236`, `project-context.md:245-248`/`:639-642` -- rows, addenda, rule amendments -- the record matches the code
- [ ] `crates/zanshin-jj/tests/` -- a witness per matrix row; op-log parity witnesses; the loop-free witness; the on-disk-edit witnesses for 9.3/9.4/9.7 -- gate
- [ ] `coverage-baseline.txt` -- commit the auto-raised baseline -- ratchet

**Acceptance Criteria:**
- Given a colocated fixture where the same external Git and file events happen, when Zanshin runs any `workspace_helper`-class verb and the CLI runs its counterpart on a twin copy, then `jj op log` shows the same operation sequence (descriptions, `is_snapshot`, order) and the same view (bookmarks, `@` parent, Git HEAD).
- Given a Zanshin-written snapshot operation, when the watcher-triggered refresh runs the reads again, then zero further operations are written.
- Given a dirty tree, when `workspace root` runs, then no operation is written.
- Given an on-disk edit made outside Zanshin, when `restore`, `absorb`, any `file *` read, `interdiff`'s `@` default or `workspace list` runs, then the edit is visible in the result.
- Given `Repo::snapshot()` on a clean tree, then `was_snapshot_taken=false` and no operation; on a dirty tree, `true` and exactly one `snapshot working copy` operation.
- Given every matrix row, then a test exercises it and `cargo make test` is green including the coverage ratchet and `cargo deny`.

## Design Notes

- **Order of landing:** (1) Story 9.27 (effective `UserSettings`), (2) Story 9.22's lock-scoped helper, (3) the precondition + explicit verb + payload, (4) the D2/doc sweep. Steps 3 and 4 are this story.
- **Why per verb call and not once per GUI session:** the CLI's guarantee is per invocation, and that is the only guarantee a user can reason about when alternating between the two tools. A no-change precondition costs jj-lib's mtime/size scan and writes nothing; Watchman narrows the scan when configured. ADR-0002 already places that cost outside the hold-vs-reload decision.
- **Why the lock belongs to the finish path too:** `try_reset_git_head`'s comment (`cli_util.rs:2680-2685`) names the two races it prevents — two finishes updating HEAD, and an `import_git_head` running concurrently. Zanshin's colocated `export_refs` in `convert.rs`/`git.rs` runs without it today; that becomes wrong the moment Zanshin imports HEAD.
- **The `git_import`/`git_export` colocated divergence resolves itself:** the CLI refuses those verbs in colocated repos because the snapshot already did the work. With the precondition in place the verbs find no changes and write nothing — the same observable end state without porting the refusal text.

## Verification

**Commands:**
- `cargo make test` -- expected: green, coverage ≥ baseline, `cargo deny` green with `watchman_client` in the tree
- `cargo make codegen` then `git status` -- expected: generated outputs committed, tree clean

**Manual checks (if no CLI):**
- Scratch colocated repo, IDE open: edit a file, `git fetch` in the background, `git commit` from the IDE; run a Zanshin read → `jj op log` shows `import git head`, `snapshot working copy`, `import git refs` with the user's own `user.name`/hostname, byte-for-byte the sequence a `jj status` would have written on the twin copy.
