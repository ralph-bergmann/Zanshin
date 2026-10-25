---
title: 'Story 9.17 — `resolve`, `diffedit` (GUI-editor-backed)'
type: 'feature'
created: '2026-10-24'
status: 'done'
baseline_revision: '5c9c179e3564670c1c36cd0476bf9fe6ba9b209b'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-9-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/spec-9-50-hunk-selection-select-tree.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `diffedit` replaces the target's whole tree with the selected tree, so an edit the target received after `select_tree` (an autosaving editor folded in by the pre-verb snapshot) is silently lost; only `left` is checked.
    evidence: |-
      crates/zanshin-jj/src/diffedit.rs (check_left only, then set_tree). 9.50's rule "a change to the revision's own content is not stale" rests on "the rest stays in @", which holds for commit/split/squash but not for diffedit, whose target keeps nothing. The CLI cannot hit it: its editor works on the current tree. A fix adds public surface (e.g. `DiffeditOptions.right` = the target tree ids the selection saw, `ShowEntry.tree_ids`, refused `jj.stale_selection` when the target's tree differs), i.e. a new staleness rule for the 9.50 contract, which Ralph confirms (9.50's rule was Claude's proposal, confirmed).
    location: >-
      crates/zanshin-jj/src/diffedit.rs (diffedit)
    severity: medium
    resolved: >-
      2026-10-25 — fixed (spec-9-17-staleness-run-diffedit-resolve, commit 66dc1cf): `DiffeditOptions.right` (required) = the target's `ShowEntry.tree_ids`; a target tree that differs after the `left` check refuses `jj.stale_selection` with no operation beyond the snapshot, the edit kept.
  - summary: >-
      `resolve` with GUI files has no staleness token: when a path's conflict changes between `resolve_list` and `resolve` (rebase, rewritten parent, marker edit on disk) but is still a conflict, content composed from the old sides is written as the resolution.
    evidence: |-
      crates/zanshin-jj/src/resolve.rs (merge_tool_file only checks "still a conflict"). The CLI cannot hit it: its editor reads the current conflict. A fix adds public surface — per-file term ids on `ConflictedFile` sent back on `ResolvedFile`, refused `jj.stale_selection` on mismatch — a staleness rule for the GUI contract Ralph confirms, like 9.50's.
    location: >-
      crates/zanshin-jj/src/resolve.rs (merge_tool_file, resolved_tree)
    severity: medium
    resolved: >-
      2026-10-25 — fixed (spec-9-17-staleness-run-diffedit-resolve, commit 66dc1cf): `ConflictedFile.term_ids` come back on every `ResolvedFile.term_ids` (required); a mismatch, or a conflict that is no longer a file conflict, refuses `jj.stale_selection` before the resolvability refusal, nothing written.
  - summary: >-
      `resolve_list`'s hunks cannot tell an absent side (modify/delete conflict) from an empty file: both are an empty term; `description` says "including 1 deletion" but not which side.
    evidence: |-
      crates/zanshin-jj/src/resolve.rs (conflict_hunks over MaterializedFileConflictValue.contents, where an absent side is empty bytes); jj-lib also exposes `ids: Merge<Option<FileId>>`. A per-term presence (or the term ids of the deferral above, absent = none) closes it; it belongs with that staleness token, so it waits on the same decision.
    location: >-
      crates/zanshin-jj/src/resolve.rs (resolve_list), schemas/envelope.fbs (ConflictedFile)
    severity: low
    resolved: >-
      2026-10-25 — fixed (spec-9-17-staleness-run-diffedit-resolve, commit 66dc1cf): a term without a file has no term id (Rust `None`, absent `ConflictTermId.id`, Dart `null`), an empty file has one; witnessed on a modify/delete conflict in Rust and Dart, an absent base through the FFI.
---

<intent-contract>

## Intent

**Problem:** Zanshin has no `jj resolve` and no `jj diffedit` (FR-JJ-11/12). The CLI runs a merge / diff editor for both; the GUI replaces those editors (ADR-0003), so each verb needs a context read the GUI shows and an apply call that takes what the GUI's editor produced. Deferred item I1 (deferred-work.md, "Conflicted files have no designed diff view") waits on `resolve`'s context giving a conflict view the sides and base of each conflict.

**Approach:** Port `cmd_resolve` (`cli/src/commands/resolve.rs` @ v0.46.0) as `Repo::resolve_list` (`--list`, plus per-file conflict hunks for I1) and `Repo::resolve` (tools `:ours`, `:theirs`, or the GUI merge editor's per-file output, written as the builtin merge editor writes it); port `cmd_diffedit` (`cli/src/commands/diffedit.rs` @ v0.46.0) as `Repo::diffedit` taking a 9.50 `TreeSelection` — the builtin diff editor IS a hunk selection, so `select_tree` builds the edited tree (it gains `from` for `--from`, and `show` gains the commit's own `tree_ids` as that `left`). Every chain step per the epic's "done per verb".

## Boundaries & Constraints

**Always:**
- **CLI order and texts @ v0.46.0.** `resolve`/`resolve_list`: paths → revision → `conflicts_matching` → unmatched-paths warning (`jj.paths_unmatched`, over `[&tree]`) → empty → `jj.no_conflicts` ("No conflicts found at this revision" / "No conflicts found at the given path(s)") → [list ends here] → rewritable guard (`jj.immutable`) → per matched conflict `MergeToolFile::from_tree_and_path` (`merge_tools/mod.rs:333-369`) → write. Its refusals map to the new `jj.conflict_not_resolvable` with the CLI's Display text verbatim (`mod.rs:87-110`: NotNormalFiles with `conflict.describe(labels)`, ConflictTooComplicated, ExecutableConflict; paths as `{:?}` of `RepoPathBuf`). Op description `Resolve conflicts in commit <full hex>`; descendants rebased (`rebase_descendants`) before the finish.
- **resolve tools:** `ResolveTool::Ours` / `Theirs` = `pick_conflict_side` (`mod.rs:473-496`: simplified `file.ids.get_add(0|1)`, merged executable, `CopyId::placeholder()`, `set_or_remove`). `ResolveTool::Files(Vec<ResolvedFile { path, content }>)` = the GUI merge editor's output, written as `apply_merge_builtin` writes a file (`builtin.rs:734-760`): `store.write_file`, `Merge::normal(File { id, executable: file.executable, copy_id: resolve_file_copy_id(tree value) or placeholder })` — always resolved, no marker re-parse. The files ARE the paths: `paths` together with `Files` refuses `jj.invalid_input` before the snapshot (as do an empty `Files` list and an invalid/root/duplicate file path); the matched set is exactly the files' paths; a listed file that is not a conflict at the revision refuses `jj.stale_selection` with the CLI's `NotAConflict` / `PathNotFound` text (`mod.rs:93-96`) — after the `jj.no_conflicts` check, which wins when none of them is a conflict.
- **resolve warning:** after the finish, when the new commit has conflicts and is not this workspace's `@`, warn `jj.resolve_conflicts_remain`: "After this operation, some files at this revision still have conflicts:" + `print_conflicted_paths` lines (reuse `warning.rs::conflicted_paths`' line format). For `@` the finish's existing `jj.unresolved_conflicts` covers it (`resolve.rs:126-140`).
- **resolve_list payload (I1):** per matched conflict, in tree order: `path`, `description` (`warning.rs::conflict_description` of the simplified value — the `--list` line), `num_sides` (simplified), `unresolvable` (the `jj.conflict_not_resolvable` text `resolve` would refuse with, absent = resolvable), and for a file conflict (`try_materialize_file_conflict_value` is `Some`) its simplified `labels` and `hunks` = `jj_lib::files::merge_hunks(&file.contents, store.merge_options())`: `Resolved(buf)` → one hunk with one term; `Conflict(hunks)` → each hunk's terms in jj's `Merge` order (side 1, base 1, side 2, …; one term = text all sides share). A non-file conflict has no hunks.
- **diffedit:** `DiffeditOptions { revision, from, to, tree: TreeSelection, restore_descendants }`; `revision` with `from`/`to` refuses `jj.invalid_input` before the snapshot (clap `conflicts_with`), as does a malformed `tree`. Target = `to` or `revision` (default `@`); base = `[from or @]` when `from`/`to` given, else the target's parents; base tree = `merge_commit_trees` (= `Commit::parent_tree` for the parents case). Rewritable guard on the target, THEN `check_left(base_tree, tree.left)` (`jj.stale_selection`), then: tree ids == target's tree ids → no operation ("Nothing changed.", house no-op result), else rewrite `set_tree`, `reparent_descendants` if `restore_descendants` else `rebase_descendants`, finish `edit commit <full target hex>`. Returns `MutationResult` (as `restore`).
- **select_tree `from`:** `SelectTreeOptions.from: Option<ChangeId>` — when set, the diff's left is that revision's own tree (`--from`) and `left` is checked against it; unset keeps 9.50's parent tree. **`ShowEntry.tree_ids`**: the commit's own tree, hex in `Merge` order — the `left` for `from`.
- Chain per verb: `.fbs` edited in place (append-only: new `RequestKind`s, tables, union members, fields) → `zanshin-jj` → `extern "C"` `zanshin_resolve_list`, `zanshin_resolve`, `zanshin_diffedit` + committed `cargo make codegen` output → `WorkerCommand` + `RepoHandle.resolveList/resolve/diffedit` (+ `selectTree(from:)`, `ShowEntry.treeIds`) → `docs/ffi-abi.md` (+ export count 103 → 106) → `docs/rust-error-codes.md` (`jj.no_conflicts`, `jj.conflict_not_resolvable`, warning `jj.resolve_conflicts_remain`, new emitters of `jj.stale_selection`/`jj.paths_unmatched`) → a real-cdylib `zanshin_core` test per new extern fn → parity-oracle scenarios.

**Never:**
- Running external merge/diff tools or `ui.merge-editor`/`ui.diff-editor` (terminal UX the GUI replaces); `--tool <name>` other than `:ours`/`:theirs`; the external tools' partial-resolution error and `EmptyOrUnchanged` check; editor instruction texts; diffedit `paths` (the tree already holds the selection — 9.50's rule; documented divergence); re-parsing markers in `Files` content; Flutter/app UI code (the designed conflict view is a later Epic 10/11 story); MCP tools; regenerating fixtures; shelling out to `jj` outside oracle tests.
- Running the full gate (`cargo make test` / `test-full` / `coverage`) — targeted checks only (story-loop gate rule).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| list | `@` = conflicted merge, 2-sided `c.txt` | one file: description `2-sided conflict`, num_sides 2, unresolvable absent, hunks with a 3-term conflict hunk (side, base, side) | — |
| list non-file / 3-sided | symlink-vs-file conflict; 3-sided file conflict | unresolvable = CLI NotNormalFiles text (no hunks); ConflictTooComplicated text (hunks present) | — |
| no conflicts | clean revision; paths matching no conflict | — | `jj.no_conflicts` with the CLI's two texts; an absent explicit path also warns `jj.paths_unmatched` |
| ours / theirs | conflicted `@` | file = side 1 / side 2; op `Resolve conflicts in commit <hex>`; tree = CLI's `--tool :ours/:theirs` | — |
| files | `[{c.txt, "merged\n"}]` | `c.txt` resolved to that content, other conflicts stay | — |
| files + paths / dup / invalid | — | — | `jj.invalid_input`, before the snapshot, no op |
| files: not a conflict | one listed path conflicted, another clean | — | `jj.stale_selection` (CLI NotAConflict text), no op |
| non-@ partial | M conflicted in a.txt and b.txt, `@` its child; resolve a.txt of M | M rewritten, `@` rebased; warning `jj.resolve_conflicts_remain` naming b.txt | — |
| immutable / unresolvable | conflict in an immutable commit; 3-sided file | — | `jj.immutable`; `jj.conflict_not_resolvable` |
| diffedit -r | tree from `select_tree` sections 1+3 of `@` | `@`'s tree = that tree; op `edit commit <hex>`; = CLI `diffedit --tool zs` | — |
| diffedit from/to | `from` X, `to` Y, tree from `select_tree(revision Y, from X, left = show(X).tree_ids)` | Y's tree = selection; descendants rebased (or reparented with `restore_descendants`) | — |
| diffedit unchanged | tree = target's tree | no operation, pre-call head | — |
| diffedit stale / args | `left` ≠ base tree; `revision` + `from` | — | `jj.stale_selection` (after the immutable check); `jj.invalid_input` before snapshot |

</intent-contract>

## Code Map

- `../jj` @ v0.46.0 (read-only, `git -C ../jj show v0.46.0:<path>`): `cli/src/commands/resolve.rs` (whole), `cli/src/commands/diffedit.rs` (whole), `cli/src/merge_tools/mod.rs:87-123` (ConflictResolveError texts), `:328-369` (MergeToolFile), `:473-496` (pick_conflict_side), `cli/src/merge_tools/builtin.rs:705-760` (edit/apply_merge_builtin write), `cli/src/cli_util.rs:3129-3219` (print_conflicted_paths), `:3382-3412` (unmatched paths), `:3418-3440` (rebase_or_reparent_descendants). jj-lib 0.46 (vendored `~/.cargo/registry/src/index.crates.io-*/jj-lib-0.46.0`): `conflicts.rs:187-204,265` (`MaterializedFileConflictValue`, `try_materialize_file_conflict_value`), `files.rs:278-290` (`MergeResult`, `merge_hunks`), `merged_tree.rs:199-210` (`conflicts`, `conflicts_matching`), `rewrite.rs` `merge_commit_trees`; jj-core `backend.rs:465` (`MergedTreeValueExt::describe`).
- NEW `crates/zanshin-jj/src/resolve.rs` -- `ResolveListOptions { revision, paths }`, `ResolveList { files: Vec<ConflictedFile> }`, `ConflictedFile { path, description, num_sides, unresolvable: Option<String>, labels, hunks: Vec<ConflictHunk> }`, `ConflictHunk { terms: Vec<Vec<u8>> }`, `ResolveOptions { revision, paths, tool }`, `ResolveTool { Ours, Theirs, Files(Vec<ResolvedFile>) }`, `ResolvedFile { path, content }`; `check_resolve_args`; one shared "conflicts + MergeToolFile check" helper used by both verbs; inline unit tests (error texts, hunk shaping). Pattern: `simplify_parents.rs` (tx, guard, finish, no-op).
- NEW `crates/zanshin-jj/src/diffedit.rs` -- `DiffeditOptions`, `check_diffedit_args`, the verb. Pattern: `mutate.rs:1872-1913` (`restore`: rewrite → reparent/rebase → `finish_verb`), tree arm: `commit.rs:~188` (`SelectedTree::from_tree_id(store, &selection.tree)`), `select_tree::check_left`, `check_tree_selection`.
- `crates/zanshin-jj/src/select_tree.rs:118-128,265-287` -- `SelectTreeOptions.from`; `select_tree` uses `from`'s tree as left when set; make `resolve_file_copy_id` (L460) `pub(crate)` for resolve's writer; module doc + `Repo::select_tree` doc mention `from`.
- `crates/zanshin-jj/src/commit_views.rs:96-108,~440-450` -- `ShowEntry.tree_ids` (the commit's own tree, `ObjectId::hex`).
- `crates/zanshin-jj/src/warning.rs:32ff,610-653` -- `WarningKind::ResolveConflictsRemain` (+ its code `jj.resolve_conflicts_remain` wherever kinds map to codes); factor `conflicted_paths` so the heading is a parameter; `conflict_description` → `pub(crate)`.
- `crates/zanshin-jj/src/mutate.rs:129-~440,548` -- variants `NoConflicts { message }`, `ConflictNotResolvable { message }` (+ `hints()` arms if exhaustive); helpers `build_matcher` L629, `warn_unmatched` L640, `guard_rewritable` L681, `finish_verb` L924, `mutation_result` L968, `no_op_result` L1508; `op_support::resolve_or_wc`, `start_repo_transaction`.
- `crates/zanshin-jj/src/repo.rs` -- `pub fn resolve_list` (via `with_verb`), `resolve` / `diffedit` (via `with_checked_verb`, pattern `select_tree` L3806); rustdoc errors lists as siblings (`simplify_parents` L3453-3488).
- `crates/zanshin-jj/src/lib.rs` -- re-export new types; `crates/zanshin-jj/tests/it/api_stability.rs` -- pin new types/fields; NEW `tests/it/resolve.rs`, `tests/it/diffedit.rs` + `mod` lines in `tests/it/main.rs` (patterns: `tests/it/select_tree.rs`, `simplify_parents.rs`; build conflicts in-test, never regenerate fixtures).
- `schemas/envelope.fbs` -- `RequestKind` (L94-159) append `ResolveList, Resolve, Diffedit`; `SelectTreeRequest` (L247) append `from`; `ShowEntry` (L2330) append `tree_ids`; new `enum ResolveTool : ubyte { Files, Ours, Theirs }`, `ResolvedFile { path; content: [ubyte] }`, `ResolveListRequest`, `ResolveRequest { kind; revision; paths; tool; files }`, `DiffeditRequest { kind; revision; from; to; tree: TreeSelection; restore_descendants }`, payloads `ConflictTerm { content: [ubyte] }`, `ConflictHunk { terms }`, `ConflictedFile`, `ResolveList` appended to `union Payload` (L2712); resolve/diffedit return the existing `MutationResult` payload.
- `crates/zanshin-ffi/src/` -- NEW `resolve.rs` (both externs + readers; `Ours`/`Theirs` with files refuse `jj.invalid_input`) and `diffedit.rs` (pattern `select_tree.rs` whole file; `tree_selection()` reader L34); `envelope.rs` consts `JJ_NO_CONFLICTS`, `JJ_CONFLICT_NOT_RESOLVABLE` (near L168), `ok_resolve_list` (pattern `ok_selected_tree` L913), `ok_mutation_result` L831 reused; `repo.rs::map_mutate_err` L169-206 arms + unit tests; warning-code mapping for the new kind; `select_tree.rs` reads `from`; `commit_views.rs:204-221` writes `tree_ids`; `lib.rs` module lines; `tests/it/ffi_abi_doc_sync.rs:37` 103→106; FFI it-tests (pattern `tests/it/select_tree_ffi.rs`).
- `packages/zanshin_core` -- NEW `lib/src/ffi/resolve.dart`, `diffedit.dart` (pattern `select_tree.dart`, `rebase.dart`); `lib/src/worker/commands.dart` (pattern `SelectTreeCommand` L2108), `isolate.dart` (client ~L1761, dispatcher ~L4238), `handle.dart` (`selectTree` L1467 gains `from`); `ffi/commit_views.dart` show model `treeIds`; barrel `lib/zanshin_core.dart`; real-cdylib tests NEW `test/worker/resolve_test.dart`, `test/worker/diffedit_test.dart` (pattern `test/worker/select_tree_test.dart`).
- `crates/zanshin-parity/tests/oracle/scenarios.rs` + `main.rs` `parity!` list -- resolve scenarios on a conflicted-merge setup (pattern L873-891 / `CONFLICT_THEN_CHILD` L4483): `resolve_ours`, `resolve_theirs`, `resolve_tool_files` (repo config `merge-tools.zs.program = "sh"`, `merge-tools.zs.merge-args = ["-c", 'printf "…" > "$1"', "sh", "$output"]`, CLI `resolve --tool zs`, Zanshin `Files` with the same content), `resolve_non_wc_partial`, `resolve_no_conflicts`; diffedit scenarios on `SECTIONS_TOOL` (L580; `diffedit --tool zs` uses the same `edit-args`): `diffedit_tool_sections_1_3`, `diffedit_from_to`, `diffedit_restore_descendants`, `diffedit_nothing_changed` (tool writes the right side unchanged).
- `docs/ffi-abi.md` (symbol index + counts), `docs/rust-error-codes.md` (code table, warning section, `jj.stale_selection`/`jj.paths_unmatched` emitter rows).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/{resolve,diffedit}.rs` (new), `select_tree.rs`, `commit_views.rs`, `warning.rs`, `mutate.rs`, `repo.rs`, `lib.rs` -- implement per Boundaries; inline unit tests for new private logic.
- `crates/zanshin-jj/tests/it/{resolve,diffedit}.rs` (new) + `main.rs`, `api_stability.rs`, existing show/select_tree tests -- every matrix row; `select_tree` with `from`; `show` `tree_ids`.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/**`, then `cargo make codegen` -- wire, regenerate, commit generated files; FFI unit + it tests (readers, kind mismatch, `map_mutate_err` arms, a resolve and a diffedit round trip).
- `packages/zanshin_core/**` -- Dart surface + real-cdylib tests: `resolveList` returns the conflict hunk's three terms; `resolve(tool: ours)` clears the conflict; `diffedit` with a `selectTree` tree keeps only sections 1+3; a stale `left` refuses `jj.stale_selection`.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- the scenarios above, matching the stock CLI with no ledger entry.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- rows, counts, codes.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- mark I1 ("Conflicted files have no designed diff view") resolved for its backend part with the commit hash (the designed view stays Epic 10/11 UI work); `sprint-status.yaml` 9-17 status.

**Acceptance Criteria:**
- Given a conflicted revision, when the GUI calls `resolve_list`, then each file carries the CLI's `--list` description, its side count, whether `resolve` can take it, and for a file conflict its merge hunks with each conflict's sides and base.
- Given a conflicted `@`, when `resolve` runs with `Ours`, `Theirs`, or `Files` content, then the repo state equals the stock CLI's `jj resolve --tool :ours` / `:theirs` / an external merge tool writing that content (oracle, no ledger entry).
- Given a revision with three changed sections, when `select_tree` picks sections 1 and 3 and `diffedit` takes that tree, then the repo equals the CLI's `jj diffedit --tool <script>` making the same choice (oracle).
- Given any refusal in the matrix, when the verb returns, then no operation is written beyond the CLI's own start-up snapshot.
- Given the Dart `RepoHandle`, when `resolveList`, `resolve` and `diffedit` run through the real cdylib, then they return the facts above.

## Spec Change Log

## Review Triage Log

### 2026-10-24 — Review pass
- verdicts: 30 findings — high 0, medium 8, low 16, false 6, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) Dart tests cannot see `from`/`to`/`restoreDescendants`/`revision` cross the buffer (from = @'s parent equals the default) — patched: Dart diffedit cases with a non-parent `from` and with `restoreDescendants`, Dart resolve/resolveList on a non-@ revision with paths.
  - `[medium]` `[patch]` (verification-gap) `ResolveList` labels and `unresolvable` unpinned across jj → FFI → Dart — patched: exact labels in `tests/it/resolve.rs`, an `ok_resolve_list` unit test, Dart labels + a non-null `unresolvable` through the real cdylib.
  - `[medium]` `[patch]` (verification-gap) the executable bit kept and the deleting side removing the path are not exercised — patched: `+x` kept by `Ours` and `Files`, modify/delete resolved to absence.
  - `[low]` `[patch]` (verification-gap) `from` alone / `to` alone untested — patched: one test each in `tests/it/diffedit.rs`.
  - `[medium]` `[defer]` (blind) diffedit drops edits made to the target after `select_tree` (only `left` checked, whole tree replaced) — real; the fix is a new staleness rule + public surface on the 9.50 contract (whose staleness rule Ralph confirmed), so deferred for Ralph's decision with Claude's proposal (frontmatter + deferred-work.md "Surfaced in Story 9.17").
  - `[medium]` `[defer]` (blind) resolve `Files` has no staleness token — real; same decision, deferred with the proposal (per-file term ids).
  - `[low]` `[reject]` (blind) `:ours`/`:theirs` turn a missing simplified side into a deletion (CLI panics) — needs file ids that simplify while the tree value stays conflicted, i.e. a copy-id-only conflict; the Git backend's copy ids are always the placeholder, so it is unreachable, and the guard adds a branch.
  - `[low]` `[defer]` (blind) hunks cannot tell an absent side from an empty file — real (I1 completeness); closes with the term ids of the token above, deferred with it.
  - `[low]` `[reject]` (blind) no binary/non-UTF-8 flag; builtin refuses non-UTF-8 hunks — the GUI has the bytes and can test them; `Files` is the GUI editor's output, not the builtin's TUI, so there is nothing to refuse.
  - `[low]` `[reject]` (blind) `resolve_list` reads every conflicted file's contents — the GUI calls it to resolve, where it needs them; the cheap "what is conflicted" read is `status`/`show`; a mode flag is new surface for no measured cost.
  - `[low]` `[reject]` (blind) absent `content`/`path` in a hand-built `ResolvedFile` are coerced — the Dart surface always sets both; an empty resolution is legitimate (9.50 precedent for hand-built buffers).
  - `[low]` `[reject]` (blind) `ResolveTool` wire default 0 = `Files` gives a confusing message when `tool` is omitted — the Dart surface always sets it; hand-built buffers only.
  - `[medium]` `[patch]` (blind) the labels assertion pins nothing — grouped with the verification-gap labels row.
  - `[medium]` `[patch]` (blind) missing Rust witnesses for the risky writes — grouped with the verification-gap write row (copy id skipped: placeholder on Git).
  - `[low]` `[reject]` (blind) thin FFI coverage of refusal codes and the diffedit no-op — every code travels the one unit-tested `map_mutate_err` arm; per-layer copies add nothing (9.50 precedent).
  - `[medium]` `[patch]` (blind) no Dart decode-contract test for `decodeResolveListEnvelope` — grouped with the labels row (labels + `unresolvable` asserted through the real cdylib decode).
  - `[low]` `[patch]` (blind) oracle gaps + `UNCHANGED_TOOL` doc slip — doc corrected; the modify/delete write is witnessed by the write row; refusal scenarios rejected (codes need hand audit, the jj-level tests assert the CLI texts).
  - `[low]` `[patch]` (blind) Dart error lists drift from `docs/ffi-abi.md` — patched: `jj.revset_resolution_error` / `jj.not_a_git_repo` added.
  - `[false]` `[reject]` (blind) no "Surfaced in Story 9.17" section — the section mirrors spec deferrals, of which there were none at review time; the deliberate divergences are in the module docs (the section exists now for this pass's deferrals).
  - `[low]` `[reject]` (edge) `:theirs` on a copy-id-only conflict deletes the file — same as the blind row: unreachable on the Git backend.
  - `[low]` `[patch]` (edge) with only `to`, `select_tree(from: None)` uses the parent tree, not `@`'s — a stale refusal, no data loss; docs now say to pass `@`'s change id as `from`.
  - `[false]` `[reject]` (edge) `-r` on an index-empty commit never matches `merge_commit_trees` — an empty commit's own tree IS its parents' merged tree, so `parent_tree`'s shortcut and `merge_commit_trees` give the same ids.
  - `[false]` `[reject]` (edge) `Files` writes empty content and takes `resolve_file_copy_id` where an external tool refuses / uses the placeholder — the spec models the builtin merge editor, which accepts empty output and keeps the copy id; on Git both copy ids are the placeholder.
  - `[low]` `[reject]` (intent) `resolve` takes file contents, not a 9.50 tree — 9.50's contract is a hunk selection between two trees and cannot express a merge resolution (Design Notes); diffedit goes through it.
  - `[false]` `[reject]` (intent) marker re-parse untested in the oracle — neither side re-parses: the `zs` tool runs without `merge-tool-edits-conflict-markers`, and `Files` never re-parses.
  - `[false]` `[reject]` (intent) I1-b (the inspector diff) not addressed — the intent narrows 9.17's part to `resolve`'s context.
  - `[low]` `[defer]` (intent) sides exposed as hunks without per-term ids/presence — grouped with the blind absent-side deferral.
  - `[low]` `[reject]` (intent) `--list` description not oracle-checked — the oracle compares repo state; the description port is unit-tested against the CLI's golden lines in `warning.rs`.
  - `[false]` `[reject]` (intent) no `## Auto Run Result` / commit pending — written at finalize, after the commit.
  - `[low]` `[patch]` (intent) the hunk witness has an empty base only — grouped with the labels row (fixture with a non-empty base).

## Design Notes

- **Why `resolve` takes file contents, not a 9.50 tree:** the builtin merge editor's result per file is text composed from the conflict's terms (`make_merge_sections`: side lines as added, base lines as removed, per-line checks) — not a selection between two trees, so 9.50's keys cannot express it, and any GUI composition (pick a side per hunk, edit by hand) ends as one file. The file is written exactly as `apply_merge_builtin` writes it, so the tree equals the builtin's (and an external tool's without marker re-parse) for the same text.
- **Why `diffedit` takes a 9.50 tree:** with the default `ui.diff-editor = ":builtin"` diffedit IS `apply_diff_builtin(base, target, choice)` — `select_tree`'s build. Content edits beyond selection need an external editor, which the GUI replaces; no design asks for a text editor yet.
- Example `resolve_list` hunks for `c.txt` with base absent, sides `c from C\n` / `c from D\n`: `[[ "c from C\n", "", "c from D\n" ]]` (one conflicting hunk, three terms).

## Verification

**Commands:**
- `cargo fmt --all --check` -- clean
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean
- `cargo test -p zanshin-jj` -- green (incl. `--test it resolve:: diffedit:: select_tree:: commit_views::`)
- `cargo test -p zanshin-ffi` -- green (incl. `ffi_abi_doc_sync`)
- `cargo make codegen` -- generated files committed, no further diff
- `cargo test -p zanshin-parity --test oracle` -- green, new scenarios with no ledger entry
- `packages/zanshin_core`: `dart analyze --fatal-infos`, `dart format --set-exit-if-changed .`, `dart test test/worker/resolve_test.dart test/worker/diffedit_test.dart test/worker/select_tree_test.dart test/worker/commit_views_test.dart test/ffi` (Makefile `test-core` env for the cdylib) -- green
- `dart analyze app` -- clean (barrel exports)

**Verification notes (this run; full gate deliberately NOT run — story-loop gate rule):**
- `cargo fmt --all --check` -- clean.
- `cargo clippy -p zanshin-jj -p zanshin-ffi -p zanshin-parity --all-targets -- -D warnings` -- clean.
- `cargo test -p zanshin-jj` -- 375 lib + 1342 integration passed (1 pre-existing `#[ignore]` perf benchmark).
- `cargo test -p zanshin-ffi` -- 222 lib + 377 integration passed (incl. `ffi_abi_doc_sync`, 106 exports).
- `cargo make codegen` -- exit 0; its output is in commit aeefd82.
- `cargo test -p zanshin-parity --test oracle` -- 429 passed, incl. the 11 new scenarios (`resolve_ours`, `resolve_theirs`, `resolve_tool_files`, `resolve_non_wc_partial`, `resolve_no_conflicts`, `resolve_modify_delete_ours`, `resolve_modify_delete_theirs`, `diffedit_tool_sections_1_3`, `diffedit_from_to`, `diffedit_restore_descendants`, `diffedit_nothing_changed`), no ledger entry.
- `packages/zanshin_core` (Makefile `test-core` env): `dart test test/worker/{resolve,diffedit,select_tree,commit_views}_test.dart test/ffi` -- 567 passed (real cdylib); `dart analyze --fatal-infos --fatal-warnings` -- no issues; `dart format --set-exit-if-changed` -- 0 changed.
- `dart analyze app` -- no issues.
- Coverage not measured (the loop's final gate runs it); every new source file has unit + integration + real-cdylib tests.

## Auto Run Result

Status: done

**Summary.** `jj resolve` and `jj diffedit` @ v0.46.0 are ported end to end. `Repo::resolve_list` is `--list` plus, per conflict, the CLI's description, the side count, the text `resolve` would refuse it with, the labels and the `merge_hunks` terms (sides and base, hunk by hunk). `Repo::resolve` takes `:ours`, `:theirs` or the GUI merge editor's file contents (written as `apply_merge_builtin` writes them), in the CLI's order and with its texts (`jj.no_conflicts`, `jj.conflict_not_resolvable`, warning `jj.resolve_conflicts_remain`). `Repo::diffedit` takes a 9.50 `TreeSelection` (`-r`, `--from`/`--to`, `--restore-descendants`, "Nothing changed." writes no operation); `select_tree` gains `from` and `ShowEntry` gains `tree_ids`. FFI `zanshin_resolve_list` / `zanshin_resolve` / `zanshin_diffedit`, Dart `RepoHandle.resolveList` / `resolve` / `diffedit`, 11 oracle scenarios.

**Items.**
- I1 (conflicted files have no designed diff view) — fixed, commit aeefd82, for 9.17's backend part: `resolve_list`'s `ConflictedFile.hunks` carries each conflict's sides and base (`jj_lib::files::merge_hunks` over the materialized simplified conflict, terms in `Merge` order) with labels; witnessed in `tests/it/resolve.rs`, `resolve_ffi.rs` and `resolve_test.dart`. Left: telling an absent side from an empty one (deferred, low, waits on the staleness decision below); the designed view stays Epic 10/11 UI work.

**Files changed (aeefd82).**
- `crates/zanshin-jj/src/{resolve,diffedit}.rs` (new) -- the verbs, arg checks, unit tests.
- `crates/zanshin-jj/src/{select_tree,commit_views,warning,mutate,repo,lib}.rs` -- `from`, `tree_ids`, the warning, two error variants, facades, re-exports.
- `crates/zanshin-jj/tests/it/{resolve,diffedit}.rs` (new), `api_stability.rs`, `select_tree.rs`, `main.rs` -- every matrix row plus executable bit, modify/delete, base term, lone `from`/`to`.
- `schemas/envelope.fbs`, `crates/zanshin-ffi/src/{resolve,diffedit}.rs` (new), `envelope.rs`, `repo.rs`, `select_tree.rs`, `commit_views.rs`, generated files -- wire, externs, `ok_resolve_list` + its unit test.
- `crates/zanshin-ffi/tests/it/{resolve_ffi.rs (new),select_tree_ffi.rs,ffi_abi_doc_sync.rs}` -- FFI round trips, 106 exports.
- `packages/zanshin_core/lib/src/{ffi/resolve.dart,ffi/diffedit.dart (new),ffi/select_tree.dart,ffi/commit_views.dart,ffi/warning.dart,worker/*}`, barrel, `test/worker/{resolve,diffedit}_test.dart` (new) -- Dart surface + real-cdylib tests.
- `crates/zanshin-parity/tests/oracle/{scenarios,main}.rs` -- 11 scenarios.
- `docs/ffi-abi.md`, `docs/rust-error-codes.md` -- symbols, counts, codes.

**Review.** 30 findings (high 0, medium 8, low 16, false 6). Patched (all tests/docs): medium — Dart request fields crossing the buffer, labels/`unresolvable` pinned through jj → FFI → Dart (incl. `ok_resolve_list` test), executable bit and modify/delete writes (+2 oracle scenarios); low — lone `from`/`to`, the `to`-only doc, Dart error lists, the oracle doc slip; plus the stale-`left` text now fits `from`. Deferred (frontmatter + deferred-work.md "Surfaced in Story 9.17"): diffedit loses edits made to the target after `select_tree` (medium), `resolve` files have no staleness token (medium), absent vs empty side (low) — each needs Ralph to confirm a staleness rule for the GUI contract (Claude's proposals recorded). Rejected with reasons in the triage log: copy-id-only `:ours`/`:theirs` deletion (unreachable on Git), binary flag, list cost, hand-built buffer coercions, `ResolveTool` wire default, FFI per-layer copies, refusal oracle scenarios, `resolve` not taking a 9.50 tree (Design Notes), and the false rows.

**Follow-up review recommended: false.** Patched at entry verdict: high 0, medium 3 entries (all tests), low 4. The rule's two-medium threshold is met, but every patch added tests or docs only and the full targeted suites were re-run green afterwards, so no specific unverified risk can be named — hence `false`.

**Residual risks.** The two staleness gaps (deferred) are real once a GUI calls these verbs with a delay between reading and applying; coverage unmeasured until the loop's final gate.

**Commits.** aeefd82 (code, docs, schema, generated files); the spec/ledger/sprint-status commit follows.
