---
title: 'Story 9.26: Implicit snapshot + colocated Git import before every verb (`workspace_helper` parity, reverses D2)'
type: 'feature'
created: '2026-09-23'
status: 'done'
baseline_revision: '570272499fa66f454aa58be219705d67646f7f11'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
warnings: [oversized]
deferred:
  - summary: >-
      A wrong-typed snapshot knob is refused before the head import, while the CLI refuses after it (decision for Ralph).
    evidence: |-
      The matrix row "Wrong-typed knob: refused before the lock" makes Zanshin read snapshot.* and immutable_heads() before
      git_import_export.lock. The CLI reads the snapshot knobs inside snapshot_working_copy, i.e. after its lock and its
      `import git head`. Observable only in the double fault "Git HEAD moved outside AND a wrong-typed snapshot knob": the
      CLI writes `import git head` and then fails, Zanshin fails without writing anything. Pinned by
      tests/snapshot_colocated.rs::a_wrong_typed_knob_is_refused_before_the_lock.
    location: >-
      crates/zanshin-jj/src/snapshot.rs::Knobs::read
    severity: low
  - summary: >-
      `snapshot.auto-update-stale = true` still refuses a stale working copy until Story 9.23 lands the recovery.
    evidence: |-
      Its true arm is the CLI's recover_stale_working_copy_impl, which the intent assigns to Story 9.23. Pinned by
      tests/snapshot_precondition.rs::auto_update_stale_still_refuses_until_the_recovery_lands; 9.23 flips that pin.
    location: >-
      crates/zanshin-jj/src/snapshot.rs
    severity: medium
  - summary: >-
      The cost of the per-verb precondition (config reload, ignore reads, full working-copy scan without Watchman) on a
      GUI refresh that fans out into many reads is unmeasured.
    evidence: |-
      Unverified. The CLI does the same work once per command and the intent forbids caching/debouncing, but one GUI
      refresh issues several verbs, each scanning the working copy. Story 2.4's "< 100 ms on the large fixture" criterion
      was not re-measured. Settle it with a benchmark of `status()` + `walk_graph` on the large fixture with and without
      the precondition (benches/), and decide whether the UI must batch its reads.
    location: >-
      crates/zanshin-jj/src/repo.rs::Repo::precondition
    severity: medium (unverified)
---

<intent-contract>

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

</intent-contract>

## Code Map

All CLI anchors are `git -C ../jj show v0.44.0:<path>`; jj-lib anchors are the vendored `~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/jj-lib-0.44.0/src/`. Line numbers were taken on 2026-09-23. Re-locate them by symbol, because earlier edits shift them.

**Oracle (read-only):**
- `cli/src/cli_util.rs`, from top to bottom:
  - `is_working_copy_writable` :754.
  - `workspace_helper_with_stats` :472-516. It takes the lock BEFORE loading the repo. `changed` means the op id changed since load. `snapshot.auto-update-stale` is read only on a stale error.
  - `lock_git_import_export` :981-996. The lock is `<repo_path>/git_import_export.lock` via `jj_lib::lock::FileLock::lock`, taken for colocated workspaces only. It blocks, and it is dropped at the end of the helper.
  - `snapshot_impl` :1298-1326.
  - `import_git_head` :1352-1416. The normal-HEAD branch does `check_out` → `start_working_copy_mutation` → `locked_wc().reset(&wc)` → plain `rebase_descendants` → commit `"import git head"` → `locked_ws.finish(op)`. It does NOT call `finish_transaction`. The "Reset the working copy parent…" fact is set only if the OLD git head was present. The absent/conflicted-HEAD branch is plain `rebase_descendants`, then `finish_transaction("import git head")`.
  - `import_git_refs` :1428-1460. It builds the import options with `git_util::load_git_import_options` (git_util.rs:205-215). The stats summary is produced BEFORE the `has_changes` check. On changes it calls `rebase_mutable_descendants` (:2927-2945, immutable resolved against the BASE repo), then `finish_transaction("import git refs")`.
  - `snapshot_working_copy` :2058-2231. Quoted in full in Design Notes.
  - `finish_transaction` :2300-2417. It does not check `has_changes`. It runs the became-immutable new-commit-on-top step, then (if colocated) `try_reset_git_head` when a wc commit exists, then always `export_refs`, then commit. Next it ALWAYS calls `update_working_copy` when a new wc commit exists (:2367-2375 → free fn :3349-3368: `workspace.check_out(op, old_tree, new)` even if `@` did not move), then reports.
  - `try_reset_git_head` :2673-2695. `GitResetHeadError::UpdateHeadRef` becomes a warning, not an error.
  - `export_working_copy_changes_to_git` :2650-2661. It calls `git::update_intent_to_add(base_repo, old, new)`, then `export_refs`.
  - `rebase_mutable_descendants` :2927-2945.
  - `handle_stale_working_copy` :2952-3020.
- `cli/src/commands/util/snapshot.rs` is the whole `jj util snapshot`.
- `cli/src/git_util.rs:62-78` is `is_colocated_git_workspace`.
- `cli/src/revset_util.rs:378-391,457-470` is `parse_remote_auto_track_bookmarks_map`. It runs `revset::parse_string_expression(&mut RevsetDiagnostics::new(), text)?.to_matcher()` per `settings.remote_settings()` entry. The error text is ``Invalid `remotes.<name>.auto-track-bookmarks`: …`` and it is a CONFIG error.
- `cli/src/commands/git/init.rs::do_init`, the External arm. The order is `init_git_refs` (overrides `abandon_unreachable_commits=false`, `record_synthetic_predecessors=false` on top of `load_git_import_options`), then `maybe_add_gitignore`, then **`maybe_snapshot`** (= `snapshot_impl`), then the trunk alias. Only for a non-colocated workspace does it then run `import_head` + `tx.check_out` + `finish("import git head")`.
- CLI verbs that end in `tx.finish(…)` and therefore run `finish_transaction`: describe, new, edit, abandon, undo (`undo.rs:169`), restore, absorb, bookmark create/delete, git fetch/import/export, git remote add/remove/rename.
  - `file track`/`untrack` use a raw `tx.commit`.
  - `git remote set-url` writes no transaction at all.
- `workspace_helper_no_snapshot` / no-snapshot set: `workspace root`, `op integrate`, `util backend name`, `debug *`, `bench *`.
- jj-lib:
  - `lock/mod.rs:29` (`FileLock`).
  - `working_copy.rs:345-400` (`WorkingCopyFreshness::check_stale`).
  - `transaction.rs:116` (`set_is_snapshot`).
  - `git.rs`: `import_head` :1169, `import_refs` :587, `export_refs` :1287 (synchronous), `reset_head` :1801, `update_intent_to_add` :2055.
  - `local_working_copy.rs:1426-1450`. With the `watchman` feature, a failed Watchman query is `tracing::warn!` plus a full scan. Without the feature it is a hard `SnapshotError`.
  - `local_working_copy.rs:2922-2948` (`finish` writes nothing when the tree state is clean and the op is unchanged).

**Zanshin, where the change lands:**
- `Cargo.toml:35`: `jj-lib = "=0.44.0"`. Add `features = ["watchman"]`, keep the exact pin, and add a WHY comment. `deny.toml` gets license/ban allowances only if `cargo deny` demands them, each with a WHY.
- `crates/zanshin-jj/src/repo.rs`:
  - `Repo` struct :107-112 gains `pending_precondition: Option<Precondition>`.
  - `refresh_settings` :196-204 is the hook the precondition runs after.
  - The public verb table:
    - Reads at :215-619 and :1139-1312.
    - The 18 `&mut` verbs at :647-1641.
    - `open`/`init`/`clone` at :1663/:1712/:1766.
  - `reload_workspace` :811.
  - The D2 paragraphs to delete: :208, :356-359, :851-854, :887, :1104-1105, :1326-1327, :1425-1427, :1500, :1550-1575.
- `crates/zanshin-jj/src/mutate.rs`:
  - `capture_old_wc` :477 and `sync_working_copy` :492. The latter checks out only when `@` moved; after this story it goes through `finish_transaction` and checks out always.
  - `finish_or_no_op{,_at}` :888/:920. Keep the has-changes skip.
  - `lock_working_copy` :999 and `commit_with_locked_wc` :1038.
  - `MutateError` :121-318.
  - The per-verb commit sites: describe :534-568, new_change :596-628, edit :662-682, abandon :721-794, restore :1133-1192, absorb :1255-1331.
  - D2 text at :16-20, :295, :1094, :1215.
- `crates/zanshin-jj/src/op_log.rs::undo` :140-166. `crates/zanshin-jj/src/remotes.rs::git_fetch` :248-330 currently takes `&Workspace` and never checks out (:323-325), and must go through `finish_transaction`.
- `crates/zanshin-jj/src/wc_ops.rs`:
  - `is_colocated_git_workspace` :324-338 is the full CLI port and the ONE colocation check.
  - `snapshot_options` :300, `auto_tracking_matcher` :196, `base_ignores` :259, `project_stats` :127, `merge_track_stats` :165.
  - `file_track` :393-422. At :412-416 it passes `SnapshotStats::default()` as auto stats; replace that with the precondition's raw jj-lib stats.
  - `file_untrack` :510-539.
  - D2 text at :4, :17-24, :77, :599.
- `crates/zanshin-jj/src/git.rs`:
  - `git_import` :316-367 (one combined `import git refs` tx, which is the CLI's non-colocated `jj git import`; keep it).
  - `git_export` :401.
  - `project_updates` :251, `project_abandoned` :284, `project_failures` :373, `map_import_err` :219, `map_export_err` :237.
  - The divergence note :46-54 must be deleted.
- `crates/zanshin-jj/src/convert.rs`:
  - `is_colocated` :292-300 is simpler than the CLI's. Delete it and use `wc_ops::is_colocated_git_workspace`.
  - `init_git_refs` :319-339 hardcodes the options. Switch to `config::git_import_options` plus the CLI's two overrides.
  - `import_git_head` :368-376 is replaced by the shared `snapshot_impl` port.
  - `convert_into` :430-455, `import_into` :460+.
  - D2 text at :71-78, :112-116, :192, :355-367.
- `crates/zanshin-jj/src/config.rs`:
  - `BUILTIN_CONFIG_TOML` :151-187.
  - `git_import_options` :901-911 (`remote_auto_track_bookmarks: HashMap::new()`, doc :890-893).
  - `snapshot_max_new_file_size` :924, `snapshot_auto_track` :939.
  - `load_for_workspace` :819, `ConfigError` :203.
- `crates/zanshin-jj/src/op_support.rs`:
  - `start_repo_transaction` :692 (doc :681-685 about `is_snapshot`).
  - `immutable_user_expression` :82, `resolve_immutable` :105.
  - The creep-guard test :1183-1331 forbids direct `start_transaction`. Call `set_is_snapshot(true)` on the helper's result instead.
  - D2 text at :588.
- Read modules whose error enums gain a precondition variant:
  - `status.rs` :60 (D2 :84)
  - `change.rs` :113
  - `op_log.rs` :54
  - `bookmarks.rs` :47
  - `view.rs` :62
  - `remotes.rs` :68
  - `file.rs` :179 (D2 :8-13)
  - `revset.rs` :35 (D2 :61-63)
  - `commit_views.rs` :164 (D2 :9-10, :269)
  - `workspace.rs` :75
  - `bookmark_ops.rs` has D2 text at :159.
  - `change.rs:36,231` "D2" is an UNRELATED decision (raw timestamps). Leave it.
- `crates/zanshin-jj/src/lib.rs:52-70` holds the re-exports. It has no `pub use jj_lib`.
- `crates/zanshin-graph/src/{stream.rs:113,slice.rs:35}` take `&zanshin_jj::Repo`. These become `&mut`.
- `schemas/envelope.fbs`:
  - `Envelope` :1170-1174 (ok=4, error=6, data_type=8, data=10). The new `precondition` field goes at slot 12.
  - `MutationResult` :713-723, `GitImportResult` :910-917, `GitExportFailure` :925-929, `SnapshotStats` :1091-1094.
  - `Payload` :1126-1155 (27 members) is unchanged.
  - The D2 comments at :139, :236, :347, :1088 must go.
  - Scalars cannot be absent: use a table for null-for-absence.
- `crates/zanshin-ffi/src/envelope.rs`:
  - Codes :19-162.
  - `FfiErrorObj` :179-183.
  - `session_from_handle` :280.
  - `finish_envelope` :493-509, `err` :517-539, `catch` :559-568.
  - `PANIC_FALLBACK_ENVELOPE` :170-173. It stays byte-identical because `err` without a precondition writes no field.
  - Hand-rolled `EnvelopeArgs` sites: `envelope.rs` :297/322/387/442/474, `bookmarks.rs:54`, `change.rs:120`, `events.rs:160,195`, `graph.rs:205`, `log_defaults.rs:48`, `status.rs:90`, `op_log.rs:64`, `remotes.rs:52`, `repo.rs:329`.
- `crates/zanshin-ffi/src/repo.rs`: `map_repo_err` :41, `map_mutate_err` :104-181, `RepoSession` :356. The wrappers are at :782-1150 (describe…absorb). D2 text at :708, :1051, :1116.
- `crates/zanshin-ffi/src/{git.rs,bookmark_ops.rs,file_ops.rs,file.rs,commit_views.rs,workspace.rs,status.rs,change.rs,op_log.rs,bookmarks.rs,remotes.rs,graph.rs}` hold every other wrapper and its per-noun `map_*_err`.
  - `file_ops.rs::build_snapshot_stats` :94-133 must become `pub(crate)` and be the single SnapshotStats builder.
  - `git.rs` template for a handle-only wrapper: `zanshin_git_import` :232-242, `build_ref_updates` :112, `build_export_failures` :137.
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs:37` (`EXPECTED_EXPORTS = 49` becomes 50). `crates/zanshin-ffi/tests/file_ops_ffi.rs` is the template for a new FFI test file.
- `packages/zanshin_core`:
  - `lib/src/worker/commands.dart`: `GitImportCommand` :520 is the handle-only template. Add the new command before `ShutdownCommand` :866.
  - `lib/src/worker/isolate.dart`: `send` :391, `gitImport` :954, worker switch :1443 (`GitImportCommand` arm :1741), `_invalidHandleEnvelope` :1960.
  - `lib/src/worker/handle.dart`: `gitImport` :500, `fileTrack` :898. D2 text at :373, :634, :818, :880-892.
  - `lib/src/ffi/git.dart:38` (`readToken(zanshin_git_import(raw))`).
  - `lib/src/ffi/mutate.dart`: `MutationResult` :165, `decodeIdentityMissingInternal` :219.
  - `lib/src/ffi/file_ops.dart` (`SnapshotStats` model :95, `_stats` :228). D2 text at `file.dart:36`, `commit_views.dart:34`, `file_ops.dart:17`.
  - Tests: `test/ffi/file_ops_test.dart` (synthetic decode) and `test/worker/file_ops_test.dart` (real cdylib, extern-fn coverage witness, header :6-13; the `a_second_verb_right_after_track_surfaces_jj_concurrent_working_copy` twin :117-128 flips).
- Docs:
  - `docs/ffi-abi.md`: Envelope section :51-71 (":68 says 25 members" is stale; the true count is 27), export count :36/:103/:298, index rows :314-364 (working-copy tracking :347-348), convert text :443-448, knob note :976.
  - `docs/rust-error-codes.md`: table :33-72; the `jj.concurrent_working_copy` row :71 says "until Story 9.26".
  - `docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md`: :3, :23, :65, :94. The phrase "Zanshin reacts, never initiates" does NOT occur there. The addendum targets the "snapshot → Watchman" passages.
  - `_bmad-output/planning-artifacts/epics.md:1233-1236` (Story 2.4's AC).
  - `_bmad-output/project-context.md` :64, :245-248, :270-272, :639-642, :650-653.
- Tests and fixtures:
  - `crates/test-helpers/src/lib.rs`: `TEST_ENV` :71, `pin_test_env` :84, `test_settings` :103, `add_workspace` :580, `rewrite_commit_files` :364.
  - Fixtures (`test-fixtures/repos/*.tar.zst`) are git-backed, NOT colocated, and have NO working-tree files. `@` is the init's empty commit, the WC op is the init op, and the head is the gen op. So a precondition on a fresh fixture is `Fresh`, finds an empty tree, and writes NO operation. Never regenerate them.
  - Colocated repos are built in-test: `tests/convert.rs:88-120` (`git` / `init_git_repo_with_commit`) and `tests/file_track_untrack.rs:101-111` (`colocated_fx`). The external-`git` recipe for remotes is `tests/remotes_write.rs`.
  - `tests/concurrent_writes.rs:80-138`: two handles on ONE workspace.
  - `tests/api_stability.rs:392-884`: fn-pointer receiver pins.
  - `tests/file_track_untrack.rs`: :298-315 expects `FileNotAutoTracked` for `.gitignore` "with no pre-verb snapshot"; :349-371; :789-806 `a_second_verb_after_track_needs_the_next_snapshot_first`. These expectations flip.
  - `tests/git_sync.rs:525-577`: colocated `git_import`/`git_export` "do real work", which becomes "find nothing".
  - `tests/status.rs:37-76`: the test-only snapshot recipe.
- **9.22 hand-over (kept from the authoring session):** `Repo::file_track` / `Repo::file_untrack` are CLI `workspace_helper_with_stats` / `workspace_helper` verbs. The precondition therefore runs in front of them too, before `lock_working_copy`. `file_track` must pass the precondition's `SnapshotStats` into `merge_track_stats` in place of today's `SnapshotStats::default()` (`print_track_snapshot_stats`). Until this lands, a `file_track` leaves the working-copy state AHEAD of `@`, and every later `check_out`-based verb commits and then fails as stale (deferred-work.md, "Surfaced 2026-09-23 while implementing Story 9.22").

## Tasks & Acceptance

**Execution:**

**Dependencies and configuration**
- [x] `Cargo.toml`, `deny.toml`: enable `jj-lib` feature `watchman` (exact pin kept, WHY comment) and keep `cargo deny` green. This matches the CLI default feature set, and without it a user's `fsmonitor.backend = "watchman"` breaks every snapshot.
- [x] `crates/zanshin-jj/src/config.rs`:
  - Add readers `snapshot_auto_update_stale(&StackedConfig) -> Result<bool, ConfigError>`.
  - Port `parse_remote_auto_track_bookmarks_map` into `git_import_options`, keyed off `UserSettings::remote_settings()` (or the same `remotes.<name>` table), with the CLI's error text as `ConfigError`.
  - Every reader errors with the KEY on a wrong type, and none silently falls back.
  - Rationale: FR-JJ-17. This closes the auto-track ledger item at all import sites (fetch/import/clone/convert/precondition).

**The precondition and finish ports**
- [x] `crates/zanshin-jj/src/snapshot.rs` (NEW, `pub(crate)` module, ≥80% coverage, unit tests inline). It contains:
  - `GitImportExportLock` (the `Option<jj_lib::lock::FileLock>` token) and `lock_git_import_export(&Workspace, colocated)`.
  - The ports `import_git_head`, `snapshot_working_copy`, `import_git_refs`, `handle_stale_working_copy`, `snapshot_impl`.
  - The public types `Precondition`, `PreconditionError`, `StaleCause`, `FinishFacts`, with the field lists in Design Notes.
  - Every port operates on `&mut Workspace` + a loaded `Arc<ReadonlyRepo>` + a `&StackedConfig`, so that `Repo` and the convert verbs share them.
  - Rationale: one port, several callers.
- [x] `crates/zanshin-jj/src/mutate.rs`:
  - Add `finish_transaction` (the port of cli_util :2300-2417 minus terminal output). Its parameters are the lock token, the old wc commit and the description.
  - It returns the new repo plus `FinishFacts`.
  - Route EVERY commit site whose CLI verb ends in `tx.finish` through it: describe, new_change, edit, abandon, restore, absorb, `op_log::undo`, `remotes::git_fetch`, and via `finish_or_no_op_at`: git_import, git_export, git_remote_add/remove/rename, bookmark_create/delete. Each verb takes the lock right before the finish, as `WorkspaceCommandTransaction::finish` does.
  - Delete `sync_working_copy` if it is orphaned.
  - Keep every verb's existing has-changes / no-op behaviour unchanged. The 9.27 "describe/fetch commit when nothing changed" item stays open.
  - `MutationResult` gains `finish: Option<FinishFacts>`, which is `None` when every fact is at its default.
  - Rationale: this is the contract's lock clause and AC-1's Git HEAD parity. Without it a colocated `new`/`describe` leaves Git HEAD and branches stale.
- [x] `crates/zanshin-jj/src/repo.rs`:
  - Add `fn precondition(&mut self) -> Result<(), PreconditionError>`, which runs `refresh_settings` → config knobs → colocation → lock → `snapshot_impl` and stores the report in `pending_precondition`, including a PARTIAL report when a later step fails.
  - Call it first in every verb listed in Design Notes "Where it runs"; those reads become `&mut self`.
  - Add the public `Repo::snapshot(&mut self) -> Result<Precondition, PreconditionError>` and `Repo::take_precondition(&mut self) -> Option<Precondition>`.
  - Remove the D2 paragraphs.
  - Rationale: the story's core. This also closes 9.27's read-verb reload item.
- [x] Read-verb error enums (`status.rs`, `change.rs`, `op_log.rs`, `bookmarks.rs`, `view.rs`, `remotes.rs`, `file.rs`, `revset.rs`, `commit_views.rs`, `workspace.rs`) and `MutateError`: each gains `Precondition(PreconditionError)` (`#[from]`). Rationale: one typed precondition failure everywhere.

**Other call sites and the D2 sweep**
- [x] `crates/zanshin-jj/src/wc_ops.rs`: `file_track` merges the precondition's raw jj-lib stats through `merge_track_stats`. Remove D2 text. Rationale: 9.22 hand-over, `print_track_snapshot_stats`.
- [x] `crates/zanshin-jj/src/convert.rs`:
  - Both verbs follow `do_init`'s External arm: `init_git_refs` (import options from config + the two overrides), then `.gitignore`, then the shared `snapshot_impl` under the lock (colocated: head import with `check_out`+`reset`, then snapshot, then refs; non-colocated: snapshot only), then the trunk alias, then the existing non-colocated head import.
  - Delete `is_colocated` and `import_git_head`.
  - Rollback stays `.jj/`-only.
  - Remove D2 text.
  - Rationale: closes the 2026-09-06 ledger item plus the dirty-tree convert ops.
- [x] `crates/zanshin-jj/src/{status,revset,file,commit_views,bookmark_ops,op_support,git}.rs` and `crates/zanshin-graph/src/{stream,slice}.rs`:
  - Delete the D2 paragraphs and the `git.rs:46-54` note.
  - `op_support` doc :681-685 now names the snapshot caller.
  - zanshin-graph takes `&mut Repo`.
  - `resolve_revset` stays `&Repo` and precondition-free, documented as a resolver over the current head (see Design Notes).
  - Rationale: the record matches the code.

**Wire contract, FFI and Dart bridge**
- [x] `schemas/envelope.fbs` + `cargo make codegen`:
  - Tables `FinishFacts`, `Precondition`.
  - `MutationResult.finish` appended.
  - `Envelope.precondition` appended.
  - Remove the D2 comments.
  - Commit all four generated outputs.
  - Rationale: the wire contract (Ask-First decision 1).
- [x] `crates/zanshin-ffi/src/*`:
  - The new `zanshin_snapshot(handle)`. It returns an ok envelope with no `data` and with `precondition` set. It lives in `file_ops.rs` or a new `snapshot.rs` registered in `lib.rs`, with rustdoc `# Errors`/`# Safety`.
  - The `JJ_STALE_WORKING_COPY` const plus a shared `map_precondition_err`, and a `Precondition` arm in every `map_*_err`.
  - `FfiErrorObj` carries an optional precondition.
  - `finish_envelope`/`err` write `precondition` when given.
  - Migrate every hand-rolled `EnvelopeArgs` onto them.
  - Every wrapper of a precondition-running verb attaches `session.repo.take_precondition()` on BOTH the ok and the error arm.
  - `build_mutation_result` writes `finish`.
  - Rationale: FFI + every-envelope payload.
- [x] `packages/zanshin_core`:
  - `lib/src/ffi/precondition.dart` holds the `Precondition` / `FinishFacts` models and null-for-absence decoders.
  - `MutationResult.finish`.
  - `SnapshotCommand` + worker case + `ZanshinWorker.snapshot` + `RepoHandle.snapshot()` → `Future<Precondition>`.
  - ONE choke point in `ZanshinWorker` records the envelope's precondition per handle for every handle-scoped reply (ok or error), exposed as `RepoHandle.lastPrecondition`.
  - Remove the D2 doc text.
  - Rationale: the bridge (Ralph: bridge is in scope, UI is not).

**Docs**
- [x] `docs/ffi-abi.md`:
  - Envelope section: add the `precondition` field + a cross-cutting note.
  - `zanshin_snapshot` index row.
  - Counts 49→50, and fix the stale Payload count to 27.
  - Rewrite the convert text.
  - Remove D2 text.
- [x] `docs/rust-error-codes.md`: add a `jj.stale_working_copy` row, and drop the "until Story 9.26" wording from the `jj.concurrent_working_copy` row.
- [x] `docs/adr/0002-*.md`: a dated 2026-09-23 addendum.
- [x] `_bmad-output/planning-artifacts/epics.md:1233-1236`: a dated addendum under Story 2.4's AC.
- [x] `_bmad-output/project-context.md`: amend the Watchman rule :64/:245-248 (and the :650-653 note if needed) and the lock rule :639-642 + :270-272.
- Rationale for the docs group: the contract's knock-ons and Ask-First decision 4.

**Tests and coverage**
- [x] `crates/zanshin-jj/tests/` (new binaries, e.g. `snapshot_precondition.rs`, `snapshot_colocated.rs`, `snapshot_watchman.rs`, plus updates to existing ones):
  - One witness per matrix row (colocated rows built in-test with the `git` CLI recipe).
  - The op-log sequence witnesses (description, `is_snapshot`, order).
  - The loop-free witness.
  - The `workspace root` no-op witness.
  - The on-disk-edit witnesses for restore/absorb/file reads/interdiff/workspace list.
  - The 9.22 track → second track → `describe`/`new_change` witness.
  - The finish-port witnesses (colocated `new_change` resets Git HEAD; `describe` of a bookmarked commit exports the Git branch).
  - The three stale causes.
  - The `api_stability.rs` pins.
  - Flip the pinned 9.22 expectations.
  - Rationale: the gate.
- [x] `crates/zanshin-ffi/tests/snapshot_ffi.rs` + `packages/zanshin_core/test/{ffi,worker}/snapshot_test.dart`: a round-trip through the real cdylib for `zanshin_snapshot` (the extern-fn coverage guard), a `precondition` present on a read and on an error envelope, synthetic decode of every field, and `lastPrecondition`. Rationale: bridge witnesses.
- [x] `coverage-baseline.txt`: commit the auto-raised baseline and never lower it. Rationale: the ratchet.

**Acceptance Criteria:**
- **AC-1 (op-log parity).** Given the matrix's colocated rows built in-test, when a precondition-running verb runs, then:
  - `jj op log` equals the sequence derived from the v0.44.0 source: descriptions, `is_snapshot` (true only on `snapshot working copy`), and order.
  - The view equals it as well: bookmarks, `@` parent, and the Git HEAD read back with `git rev-parse HEAD`.
  - A manual twin-copy check against the installed `jj` is recorded in the spec (not in the gate).
- **AC-2 (colocated mutation finish).** Given a colocated repo, when `new_change` or `describe` (of a bookmarked commit) runs, then Git HEAD equals `@-` and the Git branch equals the bookmark target, exactly as after the CLI's `finish_transaction`.
- **AC-3 (FFI precondition field).** Given any FFI wrapper of a precondition-running verb, when it returns (ok or error), then:
  - The envelope carries `precondition`.
  - Wrappers of no-precondition symbols (`zanshin_workspace_root`, `zanshin_log_defaults`, open/init/clone/convert/detect, events) never carry it.
- **AC-4 (Dart bridge).** Given the Dart bridge, when `RepoHandle.snapshot()` runs on a dirty git-backed repo, then it returns `Precondition(wasSnapshotTaken: true)`, and a following `status()` leaves `lastPrecondition.wasSnapshotTaken == false`.
- **AC-5 (track, then working-copy verbs).** Given a `file_track` that tracked a new path, when a second `file_track`, then `describe`, then `new_change` run, then:
  - All succeed.
  - The path is in `@`'s tree after the second call.
  - No `jj.concurrent_working_copy` or stale failure occurs.
- **AC-6 (convert).** Given a dirty Git work tree, when `convert_colocated` runs on it, then the op log is:
  - `import git refs` (only if refs), then `import git head` (with `@` re-parented onto HEAD), then `snapshot working copy`, then the trunk alias config.
  - No user file is written or deleted.
- **AC-7 (gate).** Given the whole change, when every `[tasks.test]` step runs, then `cargo make test` is green except the three pre-existing `app/` splash-card tests, including clippy pedantic, `cargo deny`, dart analyze/format, and the coverage ratchet with no baseline decrease.

## Spec Change Log

## Review Triage Log

- **2026-09-23 — AC-1 manual twin-copy check (installed `jj` 0.45.1, not in the gate).** Scratch repo: `git init` + one commit, `jj git init --colocate`, then `echo two >> a.txt && git commit -qam second` from Git; copied to `a` and `b` (identical `JJ_CONFIG=""`, `GIT_CONFIG_GLOBAL=/dev/null`, `JJ_USER`/`JJ_EMAIL`/`JJ_OP_*` env). `jj status` on `a` vs `Repo::open(b).status()` (a throwaway `zanshin-jj` example, deleted afterwards). Result: identical `jj op log` on both — `import git refs`, `import git head` (the CLI's init pair), then `import git head`, `import git refs` from the status call, every `snapshot=false`; `git rev-parse HEAD` equal (`eebda924…`) on both; `@-` = `eebda924 main` on both; `@` a new empty commit on both (ids differ only by change id/timestamp). Zanshin's report: `git_head_imported`, `git_head_reset` (the CLI's "Reset the working copy parent to the new Git HEAD."), `git_refs.changed_bookmarks = [main@git Updated]`, `was_snapshot_taken`. A following `jj status` on `b` wrote no further operation. No difference found.

### 2026-09-23 — Review pass
- verdicts: 34 findings — high 0, medium 7, low 19, false 6, maybe-false 2
- findings:
  - `[low]` `[patch]` (blind) A failed precondition reports `was_snapshot_taken = false` after an earlier step already wrote an operation — patched: `snapshot::run` reloads the head on the error path and compares op ids; witness `snapshot_colocated.rs::a_failure_after_the_head_import_still_reports_the_written_operation`.
  - `[medium]` `[patch]` (blind) A colocated workspace with no `@` fails every verb in `import_git_refs` (`no_op_result`/`mutation_result` need `@`), where the CLI proceeds — patched: the import (and finish) still runs, the `git_refs` projection is skipped (`None`, rustdoc updated); witness `a_workspace_without_at_still_imports_the_refs`.
  - `[false]` `[reject]` (blind) A stale working copy locks the GUI out of every read, op log included — the CLI's `op log`/`status`/… also run `workspace_helper` and refuse identically @ v0.44.0; the intent mandates this refusal until Story 9.23's recovery (already deferred).
  - `[low]` `[reject]` (blind) Single-workspace concurrency lost its test (`concurrent_writes.rs` moved to a second workspace) — the Design Notes prescribe that move; the timing race it no longer pins is the same race two CLI processes have (parity), not a Zanshin defect, and a deterministic same-workspace witness would need new test machinery.
  - `[low]` `[reject]` (blind) A colocated convert that fails after the snapshot leaves intent-to-add entries in `.git/index` — `docs/ffi-abi.md` already states `.git/` is written by the CLI's own colocated steps and the rollback never rewrites it; the CLI never rolls back at all; reachable only via an alias-write failure after the snapshot, and fixing it would widen the `.jj/`-only rollback (a product decision already recorded in 2.12/followup-K items).
  - `[low]` `[patch]` (blind) New branches lack behavioural witnesses (absent-HEAD arm, FinishFacts failure fields, Updated reload finding the workspace gone) — patched for the first two via the verification-gap tests below; the Updated-then-gone race is not constructible deterministically and stays uncovered (snapshot.rs at 98.43%).
  - `[low]` `[patch]` (blind) Colocated finish side effects are tested only for `new_change`/`describe` — patched: `a_failed_bookmark_export_is_reported_in_finish` also asserts `refs/heads/foo` equals the bookmark target after `bookmark_create` (a third finishing verb through `finish_verb`).
  - `[low]` `[patch]` (blind) Dart `RepoHandle` docs list only pre-9.26 error codes — patched: class-level paragraph (snapshot/import ops may be written; `jj.stale_working_copy` / `jj.config_error`; report in `lastPrecondition`).
  - `[low]` `[patch]` (blind) Garbled rustdoc "only its pre-verb snapshot may write an operation — not even on a refusal" on `show`/`evolog`/`interdiff` — patched in `repo.rs` and the three FFI wrapper module docs with the same wording.
  - `[low]` `[patch]` (blind) `lastPrecondition` is a side channel and `Envelope.precondition` is documented as present on every envelope of a snapshotting symbol, untrue for request-validation/handle failures — the side channel is the spec's Ask-First decision 1/bridge design (per-result widening would add public surface), so only the false doc claim is patched: `envelope.fbs` + `docs/ffi-abi.md` now say "present whenever the pre-verb snapshot ran, absent when refused before the verb ran"; codegen re-run.
  - `[low]` `[patch]` (blind) Docs claim "the watcher's file-change handler calls" `snapshot()`, but no watcher does — patched: `Repo::snapshot`, `zanshin_snapshot` and `RepoHandle.snapshot` now say the GUI's "sync now" or a future working-tree trigger calls it and the UI decides when; the missing working-tree trigger itself is already tracked (Story 3.10 FR-RX-2 / FR-FFI-7 item).
  - `[low]` `[reject]` (blind) Spec history rewritten without a Spec Change Log entry — the fix is to edit this build's spec.
  - `[maybe-false]` `[defer]` (blind) Per-verb precondition cost on a GUI refresh is unmeasured — would be medium if true; settle with a `benches/` run of `status()` + `walk_graph` on the large fixture; deferred (spec `deferred` + deferred-work.md).
  - `[medium]` `[patch]` (edge) = blind #2 (no `@` in a colocated workspace) — same patch.
  - `[medium]` `[patch]` (edge) `snapshot.auto-update-stale` and `git`/`remotes.<name>.auto-track-bookmarks` import options were read before every verb, so a bad value refused `status` etc. where the CLI never reads them there (`cli_util.rs:499`, colocated `import_git_refs`, `jj git import/fetch`) — patched: `auto-update-stale` read only on the stale path, import options only when colocated, `git_import`/`git_fetch` read their own; witnesses `a_wrong_typed_auto_update_stale_only_matters_on_a_stale_working_copy`, `an_invalid_auto_track_bookmarks_expression_refuses_only_the_import`; the matrix row `a_wrong_typed_knob_is_refused_before_the_lock` (max-new-file-size) unchanged.
  - `[low]` `[patch]` (edge) = blind #1 (`was_snapshot_taken` on the error path) — same patch.
  - `[low]` `[reject]` (edge) `isolate.dart` re-records a `Precondition` for a handle whose reply lands after `closeRepo` — one small map entry per closed handle, only when a call is in flight during close; the fix is an added guard.
  - `[medium]` `[patch]` (edge) `git_export` in a colocated workspace writes `export git refs` for never-exported refs where the CLI returns "No export needed in colocated workspaces" (`export.rs:41-46` @ v0.44.0; `import.rs` likewise) — patched: both verbs return the no-op result before any transaction when colocated; witness `git_export_writes_nothing_in_a_colocated_workspace`.
  - `[low]` `[patch]` (edge) Wrappers refused before the verb carry no `precondition` although AC-3 reads "ok or error" — nothing ran, so absence is correct (null-for-absence); the doc wording is the defect — patched with blind #10.
  - `[medium]` `[patch]` (verification-gap) The absent-Git-HEAD arm of `import_git_head` had no test — patched: `an_unborn_git_head_is_imported_without_moving_at` (`git checkout --orphan`; one `import git head`, `git_head_imported`, not `git_head_reset`).
  - `[medium]` `[patch]` (verification-gap) `try_reset_git_head`'s `UpdateHeadRef` → `git_head_update_failed` had no test — patched: `a_held_head_lock_makes_the_head_reset_a_reported_warning` (held `.git/HEAD.lock`, verb succeeds, HEAD unchanged).
  - `[low]` `[patch]` (verification-gap) Non-empty `FinishFacts.export_failed_bookmarks` was never asserted — patched: `a_failed_bookmark_export_is_reported_in_finish` + FFI twin `a_colocated_export_failure_rides_finish_export_failed_bookmarks`.
  - `[medium]` `[patch]` (verification-gap) `file_track` merging the pre-verb snapshot's stats had only a helper test — patched: `track_reports_the_pre_verb_snapshots_reason_for_a_path_it_did_not_match` (`big.bin` → `FileTooLarge { max_size: 5 }`; confirmed it fails with the pre-9.26 default stats).
  - `[low]` `[patch]` (verification-gap, other) = blind #1 — same patch.
  - `[false]` `[reject]` (intent) The lock is released after the precondition and re-taken for the finish, not held continuously — the v0.44.0 source does exactly that (`workspace_helper_with_stats` drops it, `WorkspaceCommandTransaction::finish` re-takes it, `cli_util.rs:2800-2805`).
  - `[false]` `[reject]` (intent) The Watchman-unavailable row proceeds instead of failing — with the CLI's default `watchman` feature jj-lib warns and full-scans (`local_working_copy.rs:1433-1440`), which is "fails as in the CLI"'s operative clause; the error column is witnessed by the mode-000 failure.
  - `[false]` `[reject]` (intent) Convert runs the whole `snapshot_impl`, not just `check_out`+`reset` — `do_init` calls `maybe_snapshot` (= `snapshot_impl`) at that point @ v0.44.0; parity.
  - `[low]` `[reject]` (intent) The gate never compares against a real `jj` binary — the spec designates a recorded manual twin check (above); bundling a pinned `jj` into the gate is new tooling, not a defect.
  - `[maybe-false]` `[reject]` (intent) Loop-free witness not run after a colocated mutation finish — by code: the finish resets the view's `git_head` and records the exported refs, so the next `import_head`/`import_refs` see no change and the checked-out WC is fresh; the colocated `git commit` row already pins a follow-up verb writing nothing; if wrong it would be low.
  - `[low]` `[patch]` (intent) "The watcher's file-change handler calls it" is not wired — = blind #11, same doc patch; wiring is UI scope (the intent's Never: the UI decides when).
  - `[low]` `[reject]` (intent) The stale row is built by rewriting `@` from another handle, not from a second workspace — same `WorkingCopyStale` state the Design Notes prescribe for race-free witnesses; adding a second-workspace variant adds no coverage of Zanshin code.
  - `[low]` `[reject]` (intent) The `git fetch` outside row does not assert tracked-local merge / abandonment — that is jj-lib's `import_refs` with the effective options, whose `git.abandon-unreachable-commits` handling is pinned by `git_sync.rs::git_import_honours_abandon_unreachable_commits_false`.
  - `[false]` `[reject]` (intent) MCP inheritance untested — no MCP tools exist yet (Epic 7, `zanshin-mcp/src/main.rs` is a stub); they will call the same `zanshin-jj` verbs.
  - `[false]` `[reject]` (intent) `Repo::resolve_revset` is an unnamed exemption — Design Notes name it; it is exported to neither FFI nor MCP and its CLI surface (`eval_revset`) runs the precondition.

## Design Notes

**Ask-First decisions (Ralph, 2026-09-23).** These are resolved, not intent gaps.
1. **Payload.** An optional `precondition` table goes on EVERY envelope whose verb ran the precondition, because the CLI reports on every command. It is placed on the outer `Envelope`, not per payload. On error envelopes it carries the PARTIAL facts up to the failing step. `zanshin_snapshot`'s success is `ok` with no `data` and `precondition` set, so there is no new `Payload` member.
2. **Receiver.** The precondition lives INSIDE `zanshin-jj`. Every read that runs it becomes `&mut self`. Never FFI-side; MCP inherits it by calling the same verbs plus `take_precondition()`.
3. **Error codes.**
   - The ONE new code is `jj.stale_working_copy`. Its `context` is `"<cause>\n<working_copy_op_id>\n<repo_op_id>"` (full hex), where cause is `stale` | `sibling_operation` | `operation_not_found`.
   - Config faults reuse `jj.config_error`, naming the key.
   - jj-lib failures reuse `jj.jj_lib_error`, with jj-lib's message.
   - No export-failure code: export failures are warnings in the CLI, so they ride `FinishFacts`.
4. **Watchman.** The jj-lib `watchman` feature is enabled on the workspace pin; `cargo deny` stays green. project-context is amended in this change: Zanshin compiles jj-lib's client in, and never bundles, installs or launches the daemon.

**Where it runs.**
- **Runs the precondition (`&mut self`):**
  - Reads: `status`, `get_change`, `op_log`, `list_bookmarks`, `list_tags`, `list_heads`, `list_working_copies`, `list_remotes`, `file_list`/`show`/`annotate`/`search`, `walk_graph`, `eval_revset`, `show`, `evolog`, `interdiff`, `list_workspaces`.
  - Mutations: all 18 existing `&mut` verbs.
  - The new `snapshot`.
- **Does NOT run it:**
  - `workspace_root`, `resolve_workspace_root` (CLI `workspace root`, no snapshot), `log_defaults` (config read, no CLI verb).
  - `open`/`init`/`clone`, `detect_repo`/`find_repo_root`.
  - The convert verbs. They call `snapshot_impl` directly at `do_init`'s `maybe_snapshot` point, never the verb precondition.
  - `resolve_revset` stays a `&Repo` resolver over the current head. It is exported to neither FFI nor MCP, it is the test oracle, and its CLI counterpart surface is `eval_revset`, which does run the precondition. Its rustdoc says so.
- There are no `--at-op` reads yet. Story 9.21 must follow the CLI rule: no snapshot when not at head.

**Precondition sequence** (`Repo::precondition`):
1. `refresh_settings()?` (the 9.27 hook).
2. `pending_precondition = None`.
3. Read EVERY knob: `snapshot.auto-update-stale`, `snapshot.auto-track` matcher, `snapshot.max-new-file-size`, `git_import_options` (incl. auto-track-bookmarks), and the immutable expression. A wrong type is `PreconditionError::Config` naming the key, raised before the lock (matrix row).
4. `colocated = wc_ops::is_colocated_git_workspace`, then lock (colocated only; `FileLock::lock` blocks; a lock failure is `Backend("Failed to take lock for Git import/export: …")`).
5. `load_at_head`.
6. `snapshot_impl` (head import, then snapshot, then refs import).
7. `was_snapshot_taken = final op id != loaded op id`.
8. Store the report and drop the lock.

On `StaleWorkingCopy` with `snapshot.auto-update-stale = true` the result is the same refusal until Story 9.23 wires `recover_stale_working_copy_impl` (contract). The knob is still read and type-checked.

**`snapshot_working_copy` port** (cli_util :2058-2231):
1. Lock the WC (`start_working_copy_mutation`), then `handle_stale_working_copy`.
   - No wc commit: default stats, drop the lock without `finish`, no op.
   - `Updated(op)`: `reload_at(op)` and re-read `@`.
   - `WorkingCopyStale` / `SiblingOperation` / `OpStoreError::ObjectNotFound`: `PreconditionError::StaleWorkingCopy`.
   - Other errors: `Backend`.
2. `snapshot(&options)`.
3. If `new_tree.tree_ids_and_labels() != @.tree()…`:
   - Open a tx via `start_repo_transaction` + `set_is_snapshot(true)`.
   - `wc_immutable = !immutable ∩ commit(@) .is_empty()`, evaluated on `tx.repo()`.
   - If immutable: `new_commit(vec![@], tree)` and set `working_copy_immutable_new_commit`. Otherwise: `rewrite_commit(@).set_tree(tree)`.
   - `set_wc_commit`, then plain `rebase_descendants` (→ `snapshot_rebased`).
   - If colocated:
     - Immutable: `try_reset_git_head` + `export_refs`.
     - Otherwise: `update_intent_to_add(base_repo, old, new)` + `export_refs`.
     - Facts go into `finish`.
   - Commit `"snapshot working copy"`.
4. If colocated and the tree resolves and a top-level entry starts with `.jjconflict`: set `jjconflict_files_present`.
5. `locked_ws.finish(current op id)`, ALWAYS (writes nothing when clean and unchanged).

**Public types** (Rust; the fbs mirrors them field for field, scalars non-optional, tables null-for-absence):
- `Precondition { was_snapshot_taken: bool, snapshot_stats: SnapshotStats, git_head_imported: bool /* an "import git head" op was written */, git_head_reset: bool /* CLI's "Reset the working copy parent to the new Git HEAD." = normal-HEAD branch AND old git head present */, git_head_rebased: u32, snapshot_rebased: u32, working_copy_immutable_new_commit: bool, git_refs: Option<GitImportResult> /* Some iff colocated (refs import ran), even without changes — failed_ref_names ride it */, git_refs_rebased: u32, jjconflict_files_present: bool, finish: Option<FinishFacts> /* merged over every reset/export inside the precondition */ }`.
- `FinishFacts { working_copy_became_immutable: bool, git_head_update_failed: bool /* try_reset_git_head UpdateHeadRef */, export_failed_bookmarks: Vec<GitExportFailure>, export_failed_tags: Vec<GitExportFailure> }`.
- `PreconditionError { StaleWorkingCopy { cause: StaleCause, working_copy_op_id: String, repo_op_id: String }, Config { reason: String }, Backend(String) }`.
- `StaleCause { Stale, SiblingOperation, OperationNotFound }`.
- All of these are `#[non_exhaustive]`-free, documented (`deny(missing_docs)`), re-exported from `lib.rs`, and pinned in `api_stability.rs`.

**Matrix readings (resolved by the v0.44.0 source, per Ralph's parity rule).**
- **Watchman configured, daemon unavailable.** The operative clause is "as in the CLI". With the CLI's default features, jj-lib logs the failed query and falls back to a full scan (`local_working_copy.rs:1433-1440`), so the snapshot PROCEEDS with the same result as without Watchman.
  - The witness forces the query to fail deterministically (dedicated test binary; e.g. `WATCHMAN_SOCK` pointed at a nonexistent socket, whether or not `watchman` is installed) and asserts identical ops and stats.
  - The row's error column (`jj.jj_lib_error` with jj-lib's message) is witnessed separately by a snapshot jj-lib DOES fail. Example: a new file with mode 000 → `jj.jj_lib_error` carrying jj-lib's message, with no op written.
- **Wrong-typed knob "refused before the lock".**
  - The matrix wins: all knobs are read before the lock. Witness: hold the lock in another thread; the verb returns `jj.config_error` without waiting (bounded `recv_timeout`); no op is written.
  - Known consequence: the CLI reads the snapshot knobs AFTER its lock and head import. So in the double fault "HEAD moved outside AND a wrong-typed snapshot knob", the CLI writes `import git head` before failing, and Zanshin does not. This is recorded as a deferred decision for Ralph and is not otherwise observable.

**Stale witnesses without races.** Build the three causes deterministically with jj-lib from the test:
- **Stale:** rewrite this workspace's `@` tree from another handle without checking out.
- **Sibling:** write op X from head H via `tx.write(..).leave_unpublished()`, `finish` the WC at X, then publish Y from H.
- **Not found:** point the WC checkout at a missing op id.
- **Updated:** only an unpublished X plus WC at X. The precondition reloads at X and proceeds.

**Test fallout is parity, not a bug.** A test that moves `@` through test-helpers or jj-lib WITHOUT updating the working copy now gets `jj.stale_working_copy`, as the CLI would. Fix the setup (check out, or use a Zanshin verb), never the precondition.

`tests/concurrent_writes.rs` runs two handles on ONE workspace. There the CLI's `SiblingOperation` refusal becomes reachable by timing. Keep the op-log assertion and make it deterministic, e.g. move the second writer into a second workspace via `add_workspace`, and record why in the test doc.

## Verification

**Commands** (all in the foreground; `test-flutter` has 3 pre-existing splash-card failures, so run the `[tasks.test]` dependencies one by one with `cargo make --allow-private <task>`, `coverage` last):
- `cargo make codegen` then `git status`: expected clean after committing the generated outputs.
- `cargo make --allow-private test-cargo`, `test-clippy`, `test-fmt`, `test-dart-analyze`, `test-dart-format`, `test-core`, `test-core-analyze`, `test-core-format`, the `test-shell*`/`test-settings*` steps, `test-cargo-deny`, `test-cargo-hygiene`, `test-jj-adapter-hygiene`, `coverage`: expected green, with `watchman_client` in the tree.
- `cargo make --allow-private test-flutter`: expected only the 3 pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` failures.

**Manual checks:**
- Twin-copy sanity check with the installed `jj` (0.45.1; where it differs from v0.44.0, v0.44.0 wins):
  1. Make a scratch colocated repo, edit a file, `git commit` from git, then copy it.
  2. Run `status` through a Zanshin test harness on one copy and `jj status` on the other.
  3. `jj op log` shows the same descriptions/order and `git rev-parse HEAD` is equal.
  4. Record the outcome in this spec's Review Triage Log.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** D2 is reversed. `zanshin-jj` gained `snapshot.rs`, a port of the CLI's `snapshot_impl` (`import git head` with `check_out` + `locked_wc.reset` → `snapshot working copy` with `is_snapshot`, immutable-`@` new-commit-on-top and colocated export → `import git refs` with `rebase_mutable_descendants`) under `git_import_export.lock`, plus `handle_stale_working_copy` (three typed stale causes, `Updated` reload). `Repo::precondition` runs it (after `refresh_settings`) in front of every `workspace_helper` verb — reads became `&mut self` — and `Repo::snapshot()` is `jj util snapshot`. `mutate::finish_transaction` ports the CLI's finish (became-immutable new `@`, colocated `try_reset_git_head` + `export_refs`, unconditional `check_out`), and every `tx.finish` verb goes through it with the lock re-taken, as the CLI does. Wire: `Envelope.precondition` (slot 12), `Precondition`/`FinishFacts` tables, `MutationResult.finish`, `zanshin_snapshot` (50 exports), `jj.stale_working_copy`; Dart `precondition.dart`, `SnapshotCommand`, `RepoHandle.snapshot()` / `lastPrecondition`. jj-lib `watchman` feature on. Convert follows `do_init`'s External arm with the shared `snapshot_impl`. All D2 text swept; ADR-0002, epics.md Story 2.4 and project-context amended.

**Files changed (main groups).**
- `Cargo.toml`, `Cargo.lock` — jj-lib `watchman` feature (exact pin kept).
- `crates/zanshin-jj/src/snapshot.rs` (new) — the precondition port, `Precondition`/`FinishFacts`/`PreconditionError`/`StaleCause`.
- `crates/zanshin-jj/src/{repo,mutate,git,remotes,op_log,convert,config,wc_ops,op_support}.rs` — precondition wiring, `finish_transaction`, colocated early returns for `git import`/`git export`, auto-track-bookmarks reader, convert via `snapshot_impl`, `file_track` merges the pre-verb stats.
- `crates/zanshin-jj/src/{status,change,bookmarks,view,file,revset,commit_views,workspace,bookmark_ops,lib}.rs` — `Precondition` error variants, D2 sweep, re-exports.
- `crates/zanshin-graph/src/{stream,slice}.rs` — `&mut Repo`.
- `schemas/envelope.fbs` + the 4 generated outputs — the wire contract.
- `crates/zanshin-ffi/src/*` (new `snapshot.rs`) — `zanshin_snapshot`, precondition on every snapshotting envelope, `map_precondition_err`, envelope-builder migration.
- `packages/zanshin_core/lib/src/{ffi,worker}/*` — models, command, worker choke point, handle API.
- Tests: `crates/zanshin-jj/tests/snapshot_{precondition,colocated,watchman}.rs` (new), `crates/zanshin-ffi/tests/snapshot_ffi.rs` (new), `packages/zanshin_core/test/{ffi,worker}/snapshot_test.dart` (new), setup fixes across existing binaries (stale-WC parity), flipped 9.22 pins.
- Docs: `docs/ffi-abi.md`, `docs/rust-error-codes.md`, `docs/adr/0002-*.md`, `_bmad-output/planning-artifacts/epics.md`, `_bmad-output/project-context.md`, `deferred-work.md`, `sprint-status.yaml`, `coverage-baseline.txt` (raised only).

**Review findings.** 34 findings (high 0, medium 7, low 19, false 6, maybe-false 2). Patches applied: 6 medium entries (no-`@` colocated refs import; knobs read only where the CLI reads them; colocated `git import`/`git export` early return; absent-HEAD arm witness; `HEAD.lock` → `git_head_update_failed` witness; `file_track` stats-merge caller witness) and 8 low entries (`was_snapshot_taken` on the error path; export-failure + branch-export witnesses; behavioural-witness gap; Dart `RepoHandle` doc; garbled rustdoc; `Envelope.precondition` presence doc; watcher wording; finish side effects on a third verb). Deferred: 1 from review (per-verb precondition cost unmeasured, medium unverified) plus the two implementation deferrals (knob order vs the CLI's head import — decision for Ralph; `auto-update-stale = true` waits for 9.23). Rejected, with reasons in the Review Triage Log: stale-WC read lockout (CLI parity), same-workspace concurrency test (parity race, prescribed move), convert index residue on a late failure (documented; rollback extent is a product decision), spec-history rewrite (the fix edits the spec), isolate close-race map entry (an added guard for a negligible case), no real-`jj` gate (manual twin check designated), second-workspace stale setup (same state), fetch merge/abandon assertions (jj-lib, pinned elsewhere), lock continuity / Watchman fallback / full convert snapshot / MCP / `resolve_revset` (false: v0.44.0 parity or outside the surface), loop-free after a colocated finish (maybe-false, refuted by code).

**Follow-up review: recommended (`true`).** Patched counts: medium 6, low 8, high 0 — two or more medium entries were patched on a first pass. Named unverified risk: the knob-read relocation moved the Git import options out of `VerbContext` into `git_import`/`git_fetch` and made the refs step conditional on an `Option`, and the no-`@` refs import now finishes a transaction without a projected result. Each new path has one witness but no independent review pass.

**Verification.** `cargo make codegen` leaves the tree unchanged. Gate run step by step (`cargo make --allow-private <task>`), rerun in full after the review patches: test-cargo, test-clippy, test-fmt, test-dart-analyze, test-dart-format, test-core, test-core-analyze, test-core-format, the nine test-shell* steps, the three test-settings* steps, test-cargo-deny, test-cargo-hygiene, test-jj-adapter-hygiene and coverage all PASS. test-flutter FAILS with exactly the 3 pre-existing `app/test/features/bootstrap/zanshin_bootstrap_test.dart` splash-card tests (Expected 524.0, Actual 584.0; red since before 9.27, UI scope). Coverage 99.34% overall, ratchet OK, extern-coverage OK; raised: `zanshin-jj/src/snapshot.rs` 98.43 (new), `zanshin-ffi/src/snapshot.rs` 100 (new), `zanshin-jj/src/lib.rs` 100 (new), `mutate.rs` 98.14→99.52, `repo.rs` 97.08→97.25, `status.rs` 88.89→89.71, `bookmarks.rs` 94.12→94.87, `wc_ops.rs` 97.85→98.15; nothing lowered, no `exclude_prefix`. Matrix audit: every row has a running, passing witness in `snapshot_precondition.rs`, `snapshot_colocated.rs` or `snapshot_watchman.rs`. The AC-1 manual twin check is recorded in the Review Triage Log.

**Residual risks.** The cost of the per-verb precondition on large repos is unmeasured (deferred). A stale working copy refuses every snapshotting verb until Story 9.23's recovery lands (CLI parity). The knob-order double-fault divergence awaits Ralph's decision.
