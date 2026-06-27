---
stepsCompleted: [1, 2, 3, 4, 5, 6]
inputDocuments: []
workflowType: 'research'
lastStep: 6
research_type: 'technical'
research_topic: 'jj Operation API Surface — CLI command set vs. jj-lib primitives for zanshin-jj (FFI + MCP), targeting jj 0.42.0'
research_goals: 'Decide and document the operation-API architecture (ADR-0003); produce a per-operation feasibility map (orchestration thickness + backing jj-lib helper) to sequence the per-verb stories; survey prior art (GG and other jj/git GUIs).'
user_name: 'Ralph'
date: '2026-06-27'
web_research_enabled: true
source_verification: true
---

# Research Report: technical

**Date:** 2026-06-27
**Author:** Ralph
**Research Type:** technical

---

## Research Overview

This report decides how `zanshin-jj` should shape the operation surface it offers to
its consumers — the Flutter app (via the `zanshin-ffi` cdylib) and the `zanshin-mcp`
server (which consumes `zanshin-jj` directly, no FFI). The core question: should the
surface mirror **jj-lib's primitive method set** (consumer composes operations) or the
**jj CLI's curated command set** (we compose; consumer calls finished operations)?

Target version: **jj `0.42.0`** (latest release, 2026-06-04). The project currently pins
`jj-lib =0.41.0` (2026-05-07) — exactly one release behind. The architecture decision and
feasibility map target 0.42.0; bumping the pin `0.41 → 0.42` is recommended as the first
implementation step (see Sequencing).

**Methodology:** primary-source reading of the jj-vcs repository at tag `v0.42.0` (CLI
command implementations under `cli/src/commands/`, library API under `lib/src/`),
cross-checked against `docs.rs/jj-lib/0.42.0` and the official CLI reference; prior-art
review of jj-lib GUI consumers (GG and others); adversarial verification of each
operation→jj-lib-helper mapping.

---

## Technical Research Scope Confirmation

**Research Topic:** jj Operation API Surface — CLI command set vs. jj-lib primitives for
`zanshin-jj` (FFI + MCP), targeting jj 0.42.0

**Research Goals:**
1. ADR-0003 — decide & document the operation-API architecture.
2. Per-operation feasibility map — orchestration thickness + backing jj-lib helper, to
   sequence the per-verb stories.
3. Prior-art survey — GG and other jj/git GUIs.

**Scope:**

- **Operation inventory** — the jj 0.42 CLI command set as the curated verb vocabulary.
- **Orchestration mapping** — per verb: backing jj-lib primitive(s)/helpers, transaction
  model, thickness (cheap / medium / thick), free-via-helper vs. rebuild-from-CLI-logic.
- **Architecture decision** — CLI-operation-set as a typed API over jj-lib; we compose;
  revset query as the read-side "freedom" primitive; no mutation primitives across FFI;
  transaction boundaries Rust-side; one typed surface shared by FFI + MCP.
- **Prior art** — GG (gulbanana/gg) and other jj-lib consumers / libgit2 GUIs.
- **Read side** — revset query primitive + composed views.
- **Sequencing** — recommended story order + the 0.41 → 0.42 pin bump as precursor.

**Methodology:** current primary sources (jj-vcs @ v0.42.0, docs.rs/jj-lib/0.42.0, CLI
reference), multi-source validation for critical claims, confidence levels where uncertain.

**Scope Confirmed:** 2026-06-27

---

## 1. jj 0.42.0 Layering: `jj-lib` (engine) vs `jj-cli` (orchestration)

jj ships as two crates. **`jj-lib`** is the engine: repo loading, transactions, the
`rewrite` module, `commit_builder`, the revset engine, backends, working-copy. **`jj-cli`**
is a *binary* crate — its `cli/src/commands/*.rs` modules are the **orchestration** that
composes lib primitives into the user-facing verbs (`jj squash`, `jj rebase`, …). `jj-cli`
is **not a reusable library** (its command functions are not a stable public API; much of
its glue lives in `cli/src/cli_util.rs`, which is binary-internal). So the two real options
were never "expose lib functions" vs "call CLI functions" — calling CLI functions isn't on
the table. The axis is **who composes operations from primitives**: the consumer (Flutter +
MCP), or us (`zanshin-jj`).

This was settled by reading the **real v0.42.0 source** (cloned at tag `v0.42.0`): 12
operation groups mapped to jj-lib helpers, each mapping **adversarially verified** against
the lib source (helper existence, `pub`-ness, real signature); plus the shared mutation
lifecycle, the revset read-path, a secondary-command triage, and a prior-art survey.

## 2. The Decisive Constraint: the mutation lifecycle cannot cross FFI

Every jj write operation runs the same lifecycle (verified against
`lib/src/{transaction,repo,workspace,working_copy,commit_builder}.rs`):

1. `Workspace::load(...)` → `repo_loader().load_at_head()` → `Arc<ReadonlyRepo>`
2. **(separate WC lock)** `start_working_copy_mutation()` → `LockedWorkingCopy::snapshot()` → `(MergedTree, SnapshotStats)`
3. `readonly_repo.start_transaction()` → `Transaction` (owns a `MutableRepo`)
4. mutate via `tx.repo_mut() -> &mut MutableRepo` (`new_commit`/`rewrite_commit` → `CommitBuilder<'repo>` → `.set_description().write().await`)
5. `repo_mut.rebase_descendants().await` — **mandatory**: `Transaction::write` has a hard `assert!(!has_rewrites())` (a *panic*, not a `Result`)
6. `tx.commit(description).await` → two-phase `write()` then `publish()` (takes the op-heads lock, advances heads)
7. `LockedWorkspace::finish(op_id)` — bind the WC state to the new operation

**Why this forces operation-level FFI (not primitive-level):** every load-bearing object in
this sequence is *either* a borrowed handle (`&mut MutableRepo`; `CommitBuilder<'repo>` literally
stores `&'repo mut MutableRepo`; `LockedWorkspace<'a>` stores `&'a mut Workspace`) *or* an
owned-but-non-portable resource holding an open in-memory view or an on-disk lock
(`Transaction`, `LockedWorkingCopy` + its `FileLock`, `UnpublishedOperation`). Rust borrows
have no ABI; a `&mut MutableRepo` cannot outlive its `Transaction`; the op-heads lock taken in
`publish()` plus the `write()`-time rewrite assertion mean the **rewrite → rebase → write →
publish** sequence must run start-to-finish without yielding control. **Primitive-level FFI is
not merely undesirable — it is impossible.** The only things that legitimately cross the
boundary are opaque owned handles kept in a Rust-side registry (`Arc<ReadonlyRepo>`,
`Workspace`, `RepoLoader`, referenced by token) and serializable id/value blobs (`CommitId`,
`OperationId`, change-ids, descriptions, trees/diffs as bytes). This is the hard technical floor
under the decision, independent of taste. (It also aligns with AD-2 and ADR-0002: the transaction
boundary stays entirely Rust-side; many mutators are `async`, so the wrapper needs `block_on`
at the FFI seam.)

## 3. Feasibility Map (jj 0.42.0, all helper claims verified `pub` @ 0.42.0)

**Thickness legend** — `cheap`: a pub jj-lib helper does ~all the work, wrap + typed I/O ·
`medium`: real but bounded orchestration around pub helpers · `thick`: substantial CLI-only
logic. **Crucially, "thick" almost never means "re-derive an algorithm":** it means one of
(a) an *interactive editor* the GUI replaces anyway (the underlying tree ops are pub helpers),
or (b) orchestration that lives in **`cli_util`** / has *no* lib helper and must be re-ported.
`M`=mutation, `R`=read. **All 69 operations verified `high` confidence.**

### Group: change creation & navigation
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj new` | M | medium | `MutableRepo::new_commit`, `rewrite::merge_commit_trees`, `rebase_commit`, `rebase_descendants`, `edit` | location resolution (`compute_commit_location`) + insert-loop are cli_util |
| `jj edit` | M | **cheap** | `MutableRepo::edit` (chains abandon-wc + add_head + set_wc_commit) | wrap a single helper |
| `jj commit` | M | thick | `MutableRepo::rewrite_commit`, `DetachedCommitBuilder::*` | interactive partial-file + message editor → GUI subsumes |
| `jj next` / `jj prev` | M | medium | `MutableRepo::check_out`/`edit`/`new_commit` | revset target computation + ambiguity prompt |

### Group: change metadata
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj describe` | M | thick | `rewrite_commit`, `DetachedCommitBuilder::set_description/write_hidden` | multi-target *editor* reconciliation → GUI subsumes; setters are thin |
| `jj metaedit` | M | medium | `transform_descendants`, `CommitRewriter::reparent`, `CommitBuilder::author` | author/timestamp typed structs (Timestamp = millis + tz_offset) |
| `jj abandon` | M | medium | `transform_descendants_with_options`, `RewriteRefsOptions`, `CommitRewriter::abandon/rebase` | bookmark-deletion plumbing |
| `jj restore` | M | **cheap** | `rewrite::restore_tree` (pub async, does the tree math) | whole-file restore is one call; interactive selection out of scope |

### Group: rewrites (the "thick" cluster)
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj squash` | M | thick | `rewrite::squash_commits`, `CommitWithSelection`, `restore_tree` | tree math is lib; **message-combine + DiffSelector are cli_util** (no lib helper) |
| `jj split` | M | thick | `CommitWithSelection`, `restore_tree` | **no lib `split`** — assemble two builders + parallel-tree math in zanshin-jj |
| `jj rebase` | M | thick | `rewrite::MoveCommitsTarget/Location`, `compute_move_commits`, `ComputedMoveCommits::apply` | graph rewrite is lib; target/dest resolution is cli_util |
| `jj parallelize` | M | thick | `transform_descendants`, `CommitRewriter::set_new_rewritten_parents` | two-HashMap parent-recompute is CLI-only — port verbatim |
| `jj simplify-parents` | M | medium | `CommitRewriter::simplify_ancestor_merge` | core is a lib call |
| `jj arrange` | M | thick | `CommitRewriter::new/rebase/abandon` | full ratatui TUI → expose only headless `arrange_apply(plan)` |

### Group: absorb / duplicate / revert
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj absorb` | M | **cheap** | `absorb::{AbsorbSource, split_hunks_to_trees, absorb_hunks}` (`lib/src/absorb.rs` does it all) | one of the "feared" ops — actually cheap |
| `jj duplicate` | M | medium | `rewrite::duplicate_commits{,_onto_parents}`, `DuplicateCommitsStats` | only location-compute (cli_util) to port |
| `jj revert` | M | thick | `merge_commit_trees`, `MergedTree::merge`, `conflict_label_for_commits` | **no lib `revert`** — port reverse-3-way-merge + chaining |

### Group: conflicts / diff-edit / fix
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj resolve` | M | thick | `MergedTree::conflicts*`, `conflicts::try_materialize_file_conflict_value` | merge editor is CLI/UI → GUI replaces it; lib gives conflict materialization |
| `jj diffedit` | M | thick | `merge_commit_trees`, `MergedTree::tree_ids` | the diff editor *is* the op → GUI carries it; expose context+apply |
| `jj fix` | M | medium | `fix::{fix_files, ParallelFileFixer, FileToFix}` (`lib/src/fix.rs`) | call `fix_files` as the CLI does; we own tool-config + subprocess closure |

### Group: bookmarks
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj bookmark create` | M | medium | `MutableRepo::set_local_bookmark_target`, `track_remote_bookmark`, `RefTarget::normal` | precondition checks |
| `jj bookmark set` | M | medium | `set_local_bookmark_target` | new/move classify + FF guard |
| `jj bookmark move` | M | thick | `set_local_bookmark_target`, `View::local_bookmarks_matching`, `Index::is_ancestor` | --from revset membership + pattern matching |
| `jj bookmark advance` | M | thick | `set_local_bookmark_target`, `View::local_bookmarks` | dynamic revset with injected `to` var |
| `jj bookmark delete` | M | **cheap** | `set_local_bookmark_target` (→ `RefTarget::absent`) | one call per match |
| `jj bookmark forget` | M | medium | `set_local_bookmark_target`, `set_remote_bookmark`, `untrack_remote_bookmark` | --include-remotes branching |
| `jj bookmark rename` | M | thick | `set_local_bookmark_target`, `track/untrack_remote_bookmark` | tracking-state transfer across remotes |
| `jj bookmark track` | M | medium | `track_remote_bookmark`, `merge_local_bookmark` | pattern matching + conflict render |
| `jj bookmark untrack` | M | medium | `untrack_remote_bookmark` | pattern matching |
| `jj bookmark list` | R | thick | `View::bookmarks`, `RevsetExpression::bookmarks` | flag→predicate matrix → return typed rows, not template text |

### Group: git interop (ties to Story 2.9)
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj git fetch` | M | thick | `git::GitFetch::{new,fetch,import_refs}` | network; config-driven refspecs; progress via typed callback |
| `jj git push` | M | thick | `git::push_refs`, `GitPushRefTargets/Options/Stats` | safety/classification pipeline is CLI |
| `jj git import` | M | **cheap** | `git::import_refs`, `import_head` | two calls in a tx |
| `jj git export` | M | **cheap** | `git::export_refs` | one call |
| `jj git clone` | M | thick | `Workspace::init_*_git`, `git::add_remote`, `GitFetch` | multi-tx filesystem setup |
| `jj git init` | M | thick | `Workspace::init_{internal,colocated,external}_git`, `import_refs/head` | 3 modes |
| `jj git remote add` | M | **cheap** | `git::add_remote` | URL-absolutize only |
| `jj git remote remove` | M | medium | `git::remove_remote` | also rewrites repo config file (outside tx) |
| `jj git remote rename` | M | medium | `git::rename_remote` | config-file rewrite |
| `jj git remote set-url` | M | **cheap** | `git::set_remote_urls` | Store op, no tx |
| `jj git remote list` | R | medium | `git::get_git_repo` (+ gix for URLs) | **matches Story 2.9's existing pattern** |

### Group: operation log (time travel)
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj op log` | R | thick | `op_walk::walk_ancestors`, `Operation::{parents,metadata}` | graph layout + templating → typed entries |
| `jj op show` / `jj op diff` | R | thick | `op_walk::resolve_op_with_repo`, `RepoLoader::{merge_operations,load_at}` | cross-op diff renderer |
| `jj op abandon` | M | thick | `op_walk::reparent_range`, `ReparentStats` | corrupt-repo recovery; op-heads remap |
| `jj op restore` | M | medium | `op_walk::resolve_op_with_repo`, `MutableRepo::set_view` | partial-view reassembly |
| `jj op revert` | M | medium | `MutableRepo::merge` | inverse-delta 3-way merge |
| `jj undo` / `jj redo` | M | thick | `ReadonlyRepo::operation/loader`, `Operation::view` | undo/redo *stack* semantics (description-prefix) are CLI-only |

### Group: file-level
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj file list` | R | **cheap** | `MergedTree::entries_matching` | one iterator |
| `jj file show` | R | medium | `MergedTree::path_value`, `conflicts::materialize_tree_value` | per-variant dispatch |
| `jj file annotate` | R | **cheap** | `annotate::FileAnnotator::{from_commit,compute,to_annotation}` | blame is entirely lib |
| `jj file chmod` | M | medium | `MergedTreeBuilder::*`, `rewrite_commit` | exec-bit edit loop |
| `jj file track` / `untrack` | M | thick | `LockedWorkingCopy::{snapshot,reset}`, `SnapshotOptions` | locked-WC lifecycle |
| `jj file search` | R | medium | `str_util::StringPattern`, `materialize_tree_value` | immature upstream |

### Group: workspaces
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj workspace add` | M | thick | `Workspace::init_workspace_with_existing_repo`, `start_working_copy_mutation` | multi-phase init + sparse |
| `jj workspace forget` | M | medium | `MutableRepo::remove_wc_commit`, `WorkspaceStore::forget` | metadata write outside tx |
| `jj workspace list` | R | **cheap** | `View::wc_commit_ids` | typed rows |
| `jj workspace rename` | M | medium | `LockedWorkingCopy::rename_workspace`, `MutableRepo::rename_workspace` | 3-surface coordination |
| `jj workspace root` | R | **cheap** | `WorkspaceStore::get_workspace_path` | path read |
| `jj workspace update-stale` | M | thick | `WorkingCopyFreshness::check_stale`, `create_and_check_out_recovery_commit` | recovery orchestration |

### Group: read views (rendered first)
| Op | M/R | Thick | Primary jj-lib helper(s) | Note |
|----|-----|-------|--------------------------|------|
| `jj log` | R | medium | `RevsetExpression::{all,filter}`, `Revset::stream`/`stream_graph` | graph layout is GUI-native; lib gives the stream |
| `jj show` | R | **cheap** | `Commit::parent_tree`, `MergedTree::diff_stream` | thin |
| `jj status` | R | thick | `SnapshotStats`, `Commit::parent_tree`, `MergedTree::tree_ids` | bespoke aggregation (snapshot + diff + conflict + bookmark scan) |
| `jj diff` | R | medium | `merge_commit_trees`, `MergedTree::diff_stream_with_copies`, `CopyRecords` | revset-range path adds merging |
| `jj evolog` | R | medium | `evolution::walk_predecessors` | topo grouping + interdiff |
| `jj interdiff` | R | **cheap** | `rewrite::rebase_to_dest_parent`, `MergedTree::diff_stream` | lib does the rebase-then-diff trick |

### Histogram & interpretation
**cheap = 13, medium = 27, thick = 29 (of 69).** But the 29 "thick" split into:
- **GUI-subsumed interactivity** (the cost is the diff/merge editor, which the Flutter UI builds
  anyway; the backend wraps *pub* tree helpers): `commit`, `squash`, `split`, `resolve`,
  `diffedit`, `arrange`, `describe`. The backend side of these is closer to medium.
- **Orchestration to re-port from `cli_util` / no lib helper:** `rebase`, `parallelize`,
  `revert`, the op-log/undo-redo stack, bookmark `move`/`advance`/`rename`/`list`, git
  `fetch`/`push`/`clone`/`init`, `status`, file `track`/`untrack`, `workspace add`/`update-stale`.
- **Genuinely algorithm-heavy with *zero* lib helper** (the real long poles): **`revert`**
  (reverse-3-way-merge + chaining), **`split`** & **`arrange`** (assemble from low-level
  `rewrite` parts), **`parallelize`** (two-map parent recompute). Everything else thick is
  plumbing, not invention.

## 4. The `cli_util` gap — orchestration that is NOT in jj-lib

Several pieces of orchestration the CLI relies on live in `cli/src/cli_util.rs` (binary-internal),
**not** in jj-lib. zanshin-jj must re-port them once into a small **operation-support layer**
(reused by every verb + by MCP):

- **`compute_commit_location`** — resolves `-A/-B/--onto` insert positions (needed by `new`,
  `rebase`, `duplicate`, `revert`, `split --move`).
- **`check_rewritable` / `check_rewritable_expr`** — the immutable-revs guard. *Not in jj-lib* —
  zanshin-jj ports its own immutable-heads check (also true for `absorb`).
- **Message combination** — `try_combine_messages` / `combine_messages` / `add_trailers` (jj-lib
  only parses trailers; it does **not** combine descriptions). Needed by `squash`, `split`.
- **`DiffSelector`** — interactive hunk selection. **No lib hunk-selection helper exists.** For
  `squash`/`split`/`commit`/`restore`, the GUI supplies a caller-built selected `TreeId`; the
  backend wraps it into `CommitWithSelection` and never spawns an editor.

This is the concrete answer to "how much do we rebuild": a **bounded, shared support module**,
not a per-verb rewrite.

## 5. Read Side: a revset-query primitive + the View, not "everything is a revset"

jj's revset engine gives the GUI its read "freedom" via a clean, verified 6-step path
(`parse → resolve_user_expression → evaluate → Revset::stream → .commits(store)`), yielding a
**lazy `Box<dyn Revset>`** that streams `CommitId`s topologically — exactly the GG / ADR-0002
streaming model (do **not** `try_collect`; pump one row at a time across FFI, cancellable
mid-walk). A typed `eval_revset(repo, ctx, resolver, &str) -> Stream<Commit>` maps 1:1 onto this;
variants reuse the same `Box<dyn Revset>` for `.stream_graph()` (log+graph), `.count_estimate()`
(the `--count` fast path), and `.containing_fn()` (point membership).

Two subtleties the bridge must respect:

- **Three-stage error taxonomy** — parse vs resolution vs evaluation are distinct jj error types.
  Preserve them in the bridge error enum (aligns with the project's `<domain>.<reason>` taxonomy):
  `RevsetResolutionError::NoSuchRevision{candidates}` lets the UI say "unknown revision X (did you
  mean …)" distinctly from a syntax error.
- **View ≠ revset.** Bookmark/tag/remote listing and conflict flags come **straight off
  `repo.view()`** (`local_bookmarks`, `all_remote_bookmarks`, `tags`, `heads`, `wc_commit_ids`),
  not through the revset engine — cheaper and exactly what `status` does. Reserve revsets for DAG
  queries (log, ancestors-with-conflicts, show targets). Short-prefix id resolution requires
  wiring `SymbolResolver::with_id_prefix_context`.

So the read surface = **named composed views** (`status`, `log`, `show`, `diff`) **+ one generic
`eval_revset` joker** + direct `View` reads. Graph views need three extra lib pieces on top of
the stream (`graph::TopoGroupedGraph`, `graph::reverse_graph`, `GraphNode` edge types).

## 6. Prior Art — unanimous validation of operation-level wrapping

Verified against primary source:

- **GG (gulbanana/gg)** — the reference jj desktop GUI (Tauri+Svelte, links `jj-lib` directly).
  Its `src/messages/mutations.rs` is a **flat list of verb structs** (`DescribeRevision`,
  `MoveChanges`, `AbandonRevisions`, `MoveRef`, `GitPush`, …), each carrying only domain ids —
  never a `Transaction`/`MutableRepo` handle. The `Mutation` trait (`src/worker/mod.rs`) is
  documented as **"effectively sealed … cannot be implemented outside of this crate"** — the
  operation set is **closed and backend-owned**; "Implementations should start a jj transaction,
  perform their changes, and commit it." The frontend just names the verb
  (`mutate<MoveChanges>("move_changes", …)`). This is option (b), exactly.
- **JayJay** (Rust core + SwiftUI **via FFI/uniffi**) — the closest twin to Zanshin's design.
  "Wrapping jj-lib directly — no CLI scraping"; verb-level (`squash`, `split`, `graft`, `absorb`,
  `revert`, …). **VisualJJ** (VS Code, 30k+ installs) links `jj_lib` directly too.
- **CLI-shellers** (`lazyjj`, `jjui`, `jj-fzf`, `vjj`, JetBrains plugins) — all **shell out to the
  `jj` binary**, the approach the project explicitly forbids. The library-linked, GUI-over-FFI
  camp (GG, JayJay, VisualJJ) is precisely the cohort architecturally analogous to Zanshin.
- **libgit2 GUIs** (cross-ecosystem check): **GitButler** has an explicit verb tier
  (`gitbutler-branch-actions`, `gitbutler-stack`, …) the UI calls; **Gittyup** wraps libgit2 in a
  thin object layer with composite logic *above* it. Both keep primitives away from the UI and put
  a curated **actions/operations module** in between. Same principle.

## 7. Decision & Rationale

**Adopt option (b): `zanshin-jj` exposes a curated, typed, operation-level (verb) API over
jj-lib. We compose; the consumer names the verb.** Reads additionally get a generic
`eval_revset` primitive + direct `View` access. This is captured as **ADR-0003** (draft,
`docs/adr/0003-jj-operation-api-surface.md`).

The case is over-determined:
1. **Technical floor (§2):** primitive-level FFI is *impossible* — the transaction's borrowed
   handles and locks cannot cross the boundary. The transaction must run start-to-finish Rust-side.
2. **No duplication:** the orchestration is written once in `zanshin-jj` and shared by FFI
   (Flutter) **and** `zanshin-mcp` (direct consumer). Option (a) would push it into Flutter and
   leave MCP without it.
3. **Right altitude:** GUI buttons and MCP tools are verbs (`squash`), not transaction steps.
4. **Curated vocabulary:** the CLI command set is jj's own curated list of meaningful operations
   — we adopt the *scope decision*, implement against lib, return typed structs (not CLI text).
5. **Bounded rebuild (§3, §4):** 13 cheap + 27 medium; "thick" is mostly GUI-subsumed editors or
   `cli_util` plumbing to re-port once. Only ~4 ops (`revert`, `split`, `arrange`, `parallelize`)
   are genuine algorithm ports — and even those reuse low-level `rewrite` helpers.
6. **Prior art is unanimous (§6):** every library-linked jj GUI (GG, JayJay, VisualJJ) and the
   mature libgit2 GUIs do exactly this.

## 8. Story Sequencing Recommendation

**Step 0 — pin bump `jj-lib =0.41.0 → =0.42.0`** (one release; ACL absorbs it) as its own
reviewed change, *before* any operation work, so the whole surface is built on current.

**Step 1 — operation-support layer** (the §4 `cli_util` re-port): immutable-heads check,
`compute_commit_location`, message-combination, the `SelectedTree` plumbing. Unblocks the thick
ops.

**Then tier the per-verb stories by thickness (cheap first):**
- **Tier A (cheap, build confidence):** read views (`log`/`show`/`status`/`diff` + `eval_revset`),
  `edit`, `restore`, `absorb`, `file list`/`annotate`, `git import`/`export`/`remote *`,
  `bookmark create`/`delete`, `workspace list`/`root`.
- **Tier B (medium):** `new`, `describe`, `abandon`, `metaedit`, `duplicate`, `fix`, the rest of
  `bookmark *`, `git remote remove`/`rename`, `op restore`/`revert`, `file show`/`chmod`.
- **Tier C (thick — needs Step 1 + the GUI's diff/merge editor):** `squash`, `split`, `rebase`,
  `commit`, `resolve`, `diffedit`, `git fetch`/`push`/`clone`, op-log/undo/redo, `parallelize`,
  `revert`, `arrange`, `workspace add`/`update-stale`.

Each per-verb story follows the surfacing chain: `.fbs` schema → `zanshin-jj` typed op (tx
Rust-side) → `zanshin-ffi` `extern "C"` + `cargo make codegen` → Dart `WorkerCommand` →
(optional) MCP tool → tests (zanshin-jj integration + FFI-path Dart test for coverage attribution
+ Verifier + ratchet).

## Sources

Primary source read at tag `v0.42.0` (`cli/src/commands/**`, `lib/src/**`); cross-checked vs
`docs.rs/jj-lib/0.42.0` and the jj CLI reference. Prior art: `github.com/gulbanana/gg`
(`src/messages/mutations.rs`, `src/worker/mod.rs`, `doc/DESIGN.md`); JayJay, VisualJJ (jj
maintainer attestation); `github.com/gitbutlerapp/gitbutler/tree/master/crates`;
`github.com/Murmele/Gittyup/tree/master/src/git`; `libgit2.org/docs/guides/101-samples`. Version
delta confirmed via crates.io / jj-vcs GitHub releases (0.42.0, 2026-06-04; pin 0.41.0,
2026-05-07). Backed by the 30-agent `jj-operation-api-feasibility` workflow run (2026-06-27).
