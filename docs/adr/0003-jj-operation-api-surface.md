# ADR-0003: jj operation API surface — CLI-operation-set as a typed API over jj-lib (we compose)

- **Status:** Accepted (2026-06-27) — Ralph. The technical floor
  (§ Decision pt. 1) is **source-verified** against jj `v0.42.0`; the rest is the architecture
  choice it forces.
- **Date:** 2026-06-27
- **Deciders:** Ralph
- **Refines:** AD-2 (handle ownership / single-consumer), AD-4 (worker isolate) in `architecture.md`;
  builds on ADR-0001 (FlatBuffers FFI transport) and ADR-0002 (warm loader, reload-per-operation).
- **Touches:** FR-JJ-16 (`zanshin-jj` public API surface), the whole Epic-2…7 per-operation story line.
- **Backed by:** `_bmad-output/planning-artifacts/research/technical-jj-operation-api-cli-vs-lib-surface-research-2026-06-27.md`
  (30-agent feasibility study against jj `v0.42.0`).

## Context

Zanshin has, so far, only built the scaffolding to *run* the app (FFI handle, worker isolate,
repo open/detect, remotes read). No "real" jj operation (`new`, `squash`, `rebase`, `describe`, …)
is exposed yet. Before building the first one, a foundational question must be settled: **what
shape should the operation surface of `zanshin-jj` have** — the API that `zanshin-ffi` lifts to
Flutter and that `zanshin-mcp` consumes directly?

Two framings were on the table:

- **(a)** Expose jj-lib's primitive method set; the consumer (Flutter, MCP) composes operations.
- **(b)** Expose the jj **CLI's operation set** as typed verb-level calls; `zanshin-jj` composes.

The "(b) = copying the CLI" worry is unfounded: jj is Apache-2.0, and reimplementing a command's
*behavior* against jj-lib (the CLI as a behavioral spec) is normal, licensed reuse — not piracy.
The real axis is **who composes operations from primitives.** `jj-cli` is a binary crate, not a
reusable library; its command logic and much glue (`cli/src/cli_util.rs`) are binary-internal, so
"call CLI functions" was never an option — the choice is compose-in-consumer vs compose-in-adapter.

## Decision

**`zanshin-jj` exposes a curated, typed, operation-level (verb) API over jj-lib. We compose the
operations; the consumer names the verb. The transaction boundary lives entirely Rust-side. Reads
additionally get one generic `eval_revset` primitive plus direct `View` access.**

Concretely:

1. **Primitive-level FFI is impossible, not just undesirable (the hard floor).** Every jj write
   runs `snapshot → start_transaction → mutate via &mut MutableRepo → rebase_descendants →
   commit → finish`. Every load-bearing object is a *borrowed* handle (`&mut MutableRepo`;
   `CommitBuilder<'repo>` stores `&'repo mut MutableRepo`; `LockedWorkspace<'a>`) or an
   owned-but-non-portable resource holding an open view or an on-disk lock (`Transaction`,
   `LockedWorkingCopy` + `FileLock`, `UnpublishedOperation`). Rust borrows have no ABI; the
   op-heads lock in `publish()` and the `write()`-time `assert!(!has_rewrites())` (a panic) mean
   the rewrite→rebase→write→publish sequence must run start-to-finish without yielding. So a
   transaction **cannot** be driven step-by-step across FFI. (Verified against jj `v0.42.0`
   `lib/src/{transaction,repo,workspace,working_copy,commit_builder}.rs`.)

2. **Operation granularity tracks the CLI command set; implementation tracks jj-lib.** The CLI's
   verbs are jj's own curated list of meaningful operations — we adopt that *scope decision*,
   implement each against jj-lib primitives, and return **typed structs** (never CLI text, never
   raw borrowed jj-lib types over FFI). Inputs/outputs are owned id/value blobs (`ChangeId`,
   `CommitId`, descriptions, trees/diffs as bytes) per ADR-0001.

3. **One surface, two consumers.** The same typed `zanshin-jj` operation is lifted to Flutter via
   `zanshin-ffi` **and** called directly by `zanshin-mcp`. The orchestration is written once.
   (Option (a) would push composition into Flutter and leave MCP without it — a non-starter.)

4. **A small shared operation-support layer** re-ports the orchestration that lives in
   `cli/src/cli_util.rs` (binary-internal, **not** in jj-lib): the immutable-heads check
   (`check_rewritable`), insert-location resolution (`compute_commit_location`), description
   combination (`combine_messages`/trailers), and the `SelectedTree` plumbing that replaces the
   CLI's interactive `DiffSelector`. Written once, reused by every verb.

5. **Reads = named composed views + one revset joker + direct `View`.** Named typed views
   (`status`, `log`, `show`, `diff`, …) cover the common cases; a generic
   `eval_revset(&str) -> Stream<Commit>` (lazy `Box<dyn Revset>`, streamed per ADR-0002, never
   `try_collect`-ed) is the read-side "freedom" primitive; bookmark/tag/conflict listing reads
   straight off `repo.view()` (cheaper than a revset). The parse/resolution/evaluation error
   stages map to the `<domain>.<reason>` taxonomy.

6. **No mutation primitives cross FFI, ever.** Only opaque owned handles in a Rust-side registry
   (`Arc<ReadonlyRepo>`, `Workspace`, `RepoLoader`) and serializable blobs cross. (Consistent with
   AD-2 single-consumer and ADR-0002 reload-per-operation; the transaction's `async` mutators are
   `block_on`-driven at the FFI seam.)

## Evidence

From the feasibility study (full citations + per-operation map in the research report):

- **Mutation lifecycle** — borrowed handles + on-disk lock + the `has_rewrites()` panic assertion
  force operation-level calls; primitive-level FFI cannot represent the borrowed/locked
  intermediates. (jj `v0.42.0` source.)
- **Rebuild is bounded** — of 69 operations: **13 cheap, 27 medium, 29 thick**, but "thick" is
  dominated by (a) interactive editors the Flutter GUI provides anyway (backend wraps *pub* tree
  helpers: `squash`/`split`/`resolve`/`diffedit`/`commit`/`arrange`/`describe`) and (b) `cli_util`
  plumbing to re-port once. Only ~4 ops (`revert`, `split`, `arrange`, `parallelize`) are genuine
  algorithm ports, and even those reuse low-level `rewrite` helpers. Several "feared" ops are
  cheap: `absorb` (`lib/src/absorb.rs`), `restore` (`rewrite::restore_tree`), `fix`
  (`fix::fix_files`), `file annotate` (`annotate::FileAnnotator`).
- **Prior art is unanimous** — every library-linked jj GUI wraps at the operation level: **GG**
  (`src/messages/mutations.rs` is a flat verb list; the `Mutation` trait is "effectively sealed");
  **JayJay** (Rust core + SwiftUI over FFI — the closest twin); **VisualJJ** (30k+ installs).
  CLI-shelling tools (`lazyjj`, `jjui`, `jj-fzf`, JetBrains plugins) take the approach the project
  forbids. Cross-ecosystem, **GitButler** and **Gittyup** (libgit2) keep primitives away from the
  UI behind an explicit actions/operations tier.

## Consequences

**Positive**
- The surface is buildable: no primitive ever needs to cross FFI, so the boundary stays the
  ADR-0001 typed-blob model with zero lifetime/borrow leakage.
- Orchestration is written once and shared by Flutter and MCP; no duplicated (and divergent)
  operation logic.
- The public `zanshin-jj` surface is named after stable user operations, so jj-lib churn
  (pre-1.0) is absorbed *inside* each verb — the anti-corruption-layer promise holds at the API
  level, not just internally.
- The read side gets jj's full revset power as a safe, read-only joker without exposing any
  mutation capability.

**Negative / costs**
- A **shared operation-support layer** must re-port `cli_util` orchestration jj-lib does not
  expose (immutable check, location resolution, message combination, selected-tree plumbing).
  This is upfront work that precedes the thick verbs.
- ~4 operations (`revert`, `split`, `arrange`, `parallelize`) have *no* lib helper and must be
  re-implemented from CLI logic over low-level `rewrite` parts.
- The interactive verbs (`squash`/`split`/`resolve`/`diffedit`) only work end-to-end once the
  Flutter UI supplies its own diff/merge editor (out of this repo's scope) feeding a
  caller-built `TreeId`; the backend cannot self-test them through the editor path.

**Neutral**
- Operation granularity = the jj CLI verb set, re-evaluated per jj release at pin-bump time
  (the set is stable; new verbs are added to the API as they appear upstream).

## Sequencing (informative — see research § 8)

**Step 0:** pin bump `jj-lib =0.41.0 → =0.42.0` as its own reviewed change, before any operation
work. **Step 1:** the operation-support layer (§ Decision pt. 4). **Then** per-verb stories tiered
cheap → medium → thick; each follows `.fbs` → `zanshin-jj` typed op → `zanshin-ffi` + codegen →
Dart `WorkerCommand` → optional MCP tool → tests (+ coverage attribution + ratchet).

## Open questions

- **MCP coverage per verb** — does every mutation verb also get an MCP tool immediately, or do
  read verbs + a core mutation subset ship first? (Independent of this ADR; a scoping call.)
- **`eval_revset` exposure to MCP** — a raw revset tool is powerful for agents but unbounded;
  decide whether MCP gets `eval_revset` or only named views.
- ~~**Interactive-verb contract**~~ — CLOSED 2026-10-23 (Story 9.50): see the implementation note
  "The interactive-verb contract is a separate `select_tree` read" below. `diffedit`/`resolve`
  (Story 9.17) reuse it.

## Implementation notes (as built)

- **`eval_revset` ships as a visitor, not a returned stream (Story 9.2).** Decision pt. 5 writes
  the primitive as `eval_revset(&str) -> Stream<Commit>`. jj-lib's `Revset::evaluate` returns
  `Box<dyn Revset + 'index>` borrowing the `ReadonlyRepo` that the call itself loads (ADR-0002
  reload-per-operation), so a stream cannot outlive the function that owns that repo. The shipped
  shape inverts control instead —
  `Repo::eval_revset(&str, impl FnMut(Change) -> ControlFlow<()>) -> Result<ControlFlow<()>, RevsetError>`
  — which is the same inversion `Repo::walk_graph` already uses. **Every property this ADR asks
  for is preserved:** the set is lazy (`Box<dyn Revset>`), never `try_collect`-ed, and cancellable
  mid-walk (`ControlFlow::Break`). The item type is the crate's existing `Change`; there is no
  public `Commit` type, and minting one would be a third commit shape.
- **The read side landed `zanshin-jj`-only (Story 9.2).** `eval_revset` and the direct `View`
  reads (`list_tags`, `list_heads`, `list_working_copies`; bookmarks shipped in Epic 2) stop at the
  crate API. A `Stream` has no wire representation, and the FFI boundary is snapshot-only, so
  surfacing is a separate decision — as is the `eval_revset`-to-MCP open question above.
- **The interactive-verb contract is a separate `select_tree` read (Story 9.50, contract B).** The
  GUI's diff editor hands its choice to `Repo::select_tree(revision, left, files)`: per path the
  whole file or a set of `HunkKey`s — the builtin diff editor's sections
  (`ContentDiff::by_line`, `cli/src/merge_tools/builtin.rs:225-271` @ v0.46.0) keyed by their
  0-based line ranges on each side. It builds the tree exactly as the builtin editor applies a
  choice (`apply_diff_builtin`, `:405-465`), writes it to the store — no operation — and returns
  its tree ids AND conflict labels, so a conflicted result round-trips. `left` is the revision's
  parent tree (`Commit::parent_tree`, what `split`/`squash`/`commit` diff against), exposed as
  `ShowEntry::parent_tree_ids`; it is ids, not one id, because a merge's parent tree can be
  conflicted. `commit`, `split` and `squash` (one tree per source) take the tree plus `left` in a
  TREE ARM, in place of the CLI's `--interactive`/`--tool`; paths and a tree together refuse
  `jj.invalid_input`. **Staleness:** a `left` that is no longer the revision's parent tree (a
  rebase), or a key that is not a current section, refuses `jj.stale_selection` (a new code: one
  remedy, re-select) — checked by `select_tree` and again by each tree arm where the CLI runs its
  editor. A change to the revision's own content is NOT stale: every verb snapshots first (Story
  9.26), the tree is absolute, and the rest stays in the revision. Whole-only: added/deleted
  files, mode changes, binary (NUL or non-UTF-8) files, symlinks, submodules and conflicts — for
  mode changes and conflicts a deliberate divergence (epics.md Story 9.50): the builtin editor
  offers a mode change as a separate `FileMode` toggle (`builtin.rs:296-301` @ v0.46.0) and
  sections a conflicted file over its materialized markers (`:423-445`). The
  9.47 oracle drives the stock CLI's `--tool` with a scripted editor making the same choice
  (`split_tool_sections_1_3`, `commit_tool_sections_1_3`, `squash_tool_sections_1_3`).
