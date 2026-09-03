---
title: 'Story 9.6: Read views — `show`, `evolog`, `interdiff`'
type: 'feature'
created: '2026-09-03'
status: 'done'
baseline_revision: 'a81d1f0410c97057d7ad259fa8c2e742bb75067e'
review_loop_iteration: 0
followup_review_recommended: true
context: []
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      `interdiff`'s change-id currency cannot address a hidden predecessor or a commit hex, so
      `evolog` and `interdiff` do not compose into a version-to-version diff.
    evidence: |-
      `op_support::resolve_commit` takes a reverse-hex CHANGE-ID prefix and calls
      `into_visible()`, so only the one currently-visible commit of a change is addressable.
      `EvologEntry.predecessor_commit_ids` are COMMIT ids of HIDDEN commits. The CLI's
      `--from`/`--to` are `RevisionArg`s resolved by `resolve_single_rev`, which accepts a
      commit hex and therefore reaches a hidden predecessor — so `jj interdiff` CAN diff two
      versions of one change and this cannot. That makes the spec's own stand-in for the
      unported `evolog --patch` ("a caller composes `evolog` + `interdiff`") inexpressible,
      and leaves the story's motivating question — "what differs between two versions of the
      same work" — unanswerable through the shipped API. The currency itself is mandated by
      the intent contract (Story 9.3's rule, FR-JJ-17), so widening it is a deliberate
      follow-up decision, not a patch. Documented at every layer in the meantime.
    location: >-
      crates/zanshin-jj/src/commit_views.rs::interdiff
    severity: medium
  - summary: >-
      `show` returns an unbounded entry list in one envelope, with a per-parent copy-record
      stream and a full tree diff per entry.
    evidence: |-
      `show` collects `Vec<ShowEntry>` with no limit, cursor or early stop, while `evolog`
      has `limit` and `zanshin-graph` streams. `show("all()")` on `medium-1k-commits`
      materializes a thousand entries, each paying `parent_tree` (a merge over all parents),
      one `get_copy_records` stream PER parent, a full `diff_stream_with_copies`, and a
      `change_from_commit` that itself reads every parent commit plus a `resolve_change_id`
      probe. The CLI's `jj show` is likewise unbounded, so matching it is CLI parity
      (NFR-R-2) rather than an oversight — but the CLI streams to a pager where this builds
      one FlatBuffers buffer. Nothing in the story bounds or measures it.
    location: >-
      crates/zanshin-jj/src/commit_views.rs::show
    severity: medium
  - summary: >-
      `InterdiffView` carries no signal that the rebase behind it left conflict states in the
      computed base tree.
    evidence: |-
      `rewrite::rebase_to_dest_parent` performs a 3-way merge that can leave conflicts in the
      returned `MergedTree` — the module doc calls this out as a trap. The payload is only
      `file_changes`, so a caller sees a plausible change list derived from a conflicted
      rebase with no way to distinguish it; `ShowEntry` at least carries `Change.conflict`.
      No test constructs a rebase that actually conflicts. The CLI renders conflict markers
      in the patch text, which is Epic 5's surface, so the fix is likely a presence flag on
      `InterdiffView` rather than anything textual.
    location: >-
      schemas/envelope.fbs::InterdiffView
    severity: medium
  - summary: >-
      A workspace with no working-copy commit still surfaces as `jj.jj_lib_error` instead of
      the registered `jj.no_working_copy`; `interdiff`'s `@` default widens the reach.
    evidence: |-
      `op_support::resolve_or_wc` maps a missing `@` to `ResolveError::Backend("workspace has
      no working-copy commit")`, which becomes `CommitViewError::Backend` and then
      `jj.jj_lib_error`. Story 9.4 already deferred this as a crate-wide fix (the mutation
      verbs share the behavior verbatim and an AC requires it to stay byte-identical);
      `interdiff` is one more verb reaching it, so the fix stays crate-wide.
    location: >-
      crates/zanshin-jj/src/op_support.rs::resolve_or_wc
    severity: low
  - summary: >-
      Request tables are structurally interchangeable, so a hand-crafted `ShowRequest`
      verifies as an `EvologRequest` and is answered rather than refused.
    evidence: |-
      `schemas/envelope.fbs` declares no `file_identifier` (only `root_type Envelope`), and
      `ShowRequest` / `EvologRequest` / `InterdiffRequest` all put a string in the first
      slot. Feeding `zanshin_evolog` a `ShowRequest` buffer verifies, reads `has_limit ==
      false`, and returns a plausible answer instead of `ffi.invalid_argument`; the wrappers'
      malformed-buffer test uses all-`0xff` garbage, which is the easy case. House-wide since
      Story 9.3 — every request table has the property — and only reachable by a caller that
      bypasses the generated Dart adapters, so the fix belongs with the schema convention,
      not with one story.
    location: >-
      schemas/envelope.fbs
    severity: low
  - summary: >-
      `evolog`'s start set is unbounded and entries from several start commits interleave
      with no per-start grouping.
    evidence: |-
      `limit` bounds the OUTPUT of `walk_predecessors`, not the start set the revset
      evaluates to, and the returned rows carry no marker for which start commit produced
      them. For the CLI this is invisible because its graph mode re-groups; a GUI drawing its
      own graph has to reconstruct the grouping from `predecessor_commit_ids`.
    location: >-
      crates/zanshin-jj/src/commit_views.rs::evolog
    severity: low
---

<intent-contract>

## Intent

**Problem:** Epic 9 has surfaced content ops (9.3), file reads (9.4) and git sync (9.5), but a GUI
still cannot answer the three questions `jj show`, `jj evolog` and `jj interdiff` answer: *what did
this commit change*, *how did this change evolve*, and *what differs between two versions of the
same work once the parent difference is factored out*. Without them the user goes back to the CLI
for every commit inspection.

**Approach:** Add the three verbs as typed read operations in a new `zanshin-jj` noun module
(`commit_views.rs`), implemented against jj-lib (`Commit::parent_tree` + `MergedTree::diff_stream*`,
`evolution::walk_predecessors`, `rewrite::rebase_to_dest_parent`), and surface each through the full
chain 9.3–9.5 established: `.fbs` → typed op → `extern "C"` + committed codegen → Dart
adapter/`WorkerCommand`/`ZanshinWorker`/`RepoHandle` → tests. The diff half is the CLI's *per-path
change list* (`ChangeKind` + path), not textual hunks: line/word-level diff is Epic 5's
(`zanshin-diff`, entirely backlog), and the mechanisms epics.md names for this story
(`parent_tree` + `diff_stream`) are exactly the tree-level ones. The jj CLI at tag `v0.44.0` is the
behavioral oracle for argument arity, defaults, refusals and op-log effect.

## Boundaries & Constraints

**Always:**
- All three verbs are READS: no transaction, no operation written — not even on a refusal. Assert
  the head operation id is unchanged around every call, success and failure alike (the
  `no_file_read_wrapper_writes_an_operation` pattern, `crates/zanshin-ffi/tests/file_ffi.rs:754`).
- CLI parity @ `v0.44.0` on **argument arity, defaults and refusals**: `show` and `evolog` take a
  revset (the CLI unions `Vec<RevisionArg>`; default `@`), `interdiff` takes two single revisions
  (`--from`/`--to`, each defaulting to `@`) plus filesets, and **refuses when both are absent**
  (the CLI's `ArgGroup … required(true)`).
- Parameter currency splits by kind, exactly as Story 9.3 recorded it: a single revision is a
  `ChangeId` (house currency), a parameter whose CLI form is a *set* stays a **revset string** so
  aliases and config resolution survive (FR-JJ-17). `show`/`evolog` therefore take
  `Option<String>`; `interdiff` takes `Option<ChangeId>` twice.
- Copy/rename detection follows the CLI's own asymmetry: `show` supplies copy records accumulated
  over **every** parent (`cli/src/diff_util.rs:677-682`), `interdiff` supplies **none**
  (`CopyRecords::default()`, `diff_util.rs:650`). Do not unify them.
- Reuse the shipped per-path change vocabulary — `zanshin_jj::{FileChange, ChangeKind}` and wire
  `table FileChange` / `enum ChangeKind` — and the shipped `Change` metadata table. No second
  spelling of either shape on the wire or in Rust/Dart.
- `zanshin-jj` stays sync: drive every jj-lib `Stream`/`async fn` with `pollster::block_on`
  (+ `futures::StreamExt`), the established idiom (`status.rs:128-166`, `revset.rs:156-166`).
- Every new `extern "C"` fn needs at least one `packages/zanshin_core` test that calls it through
  the real cdylib, or the coverage gate's extern-fn guard fails (`Makefile.toml:537-564`).

**Block If:**
- jj-lib 0.44.0 turns out not to expose `evolution::walk_predecessors` or
  `rewrite::rebase_to_dest_parent` with the signatures recorded in the Code Map (pin drift): HALT
  with `blocked`, blocking condition `jj-lib API drift`.
- The coverage ratchet can only be made green by lowering a baseline entry or adding an
  `exclude_prefix`: HALT with `blocked`, blocking condition `coverage ratchet regression`.

**Never:**
- No textual/line/word-level diff, no hunks, no syntax highlighting, no `--git`/`--color-words`/
  `--stat` rendering — Epic 5 owns those (`5-1`…`5-8`, all backlog).
- No terminal UX: no templates, `-T`, pager, colors, graph glyphs, `--reversed`, or the
  `TopoGroupedGraph` re-ordering `evolog`'s graph mode applies (the GUI draws its own graph; the
  returned order is the raw walk order = the CLI's `--no-graph` order).
- No `evolog --patch`: the CLI's `-p` *is* an interdiff of each entry's predecessors
  (`cli/src/commands/evolog.rs:193-206`); a caller composes `evolog` + `interdiff`.
- No path/fileset argument on `show` — the CLI hardcodes `EverythingMatcher`
  (`cli/src/commands/show.rs:109`). Do not extend it.
- No new `error.code`: every failure maps onto an already-registered code (Code Map §docs).
- No fixture regeneration, no shelling to `jj`, no MCP tool (`zanshin-mcp` is still a stub; Epic 7
  owns the tool surface — the epic calls MCP exposure "optional", and 9.3/9.4/9.5 all skipped it).
- Do not refactor `crates/zanshin-jj/src/status.rs` — see Design Notes.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| show, default revision | `show(None)` on a fixture whose `@` adds one file | One `ShowEntry`; `.change` equals `get_change(@)`'s metadata; `.file_changes` == `[{path, Added}]` | No error expected |
| show, explicit multi-commit revset | `show(Some("a \| b"))` for two commits | Two entries, in raw revset order, each diffed against **its own** parent tree | No error expected |
| show, merge commit | `show` of a merge built by `add_conflicted_merge_off_root` | Entry present; `file_changes` is the diff against the **merged** parent tree (`Commit::parent_tree`), i.e. only what the merge itself changed | No error expected |
| show, root commit | `show(Some("root()"))` | One entry, `file_changes` empty (root tree vs. itself) | No error expected |
| show, divergent change id | revset naming a change with two visible commits (`add_divergent_twin`) | **Both** commits are returned as two entries — the CLI's `show` unions revsets and never refuses ambiguity | No error expected |
| show, syntax error | `show(Some("::("))` | Refusal before any repo read | `jj.revset_parse_error`, context = jj-lib's reason |
| show, unknown symbol | `show(Some("nosuchbookmark"))` | Refusal | `jj.revset_resolution_error` |
| show, empty result | revset matching nothing (`none()`) | Empty entry list, `ok = true` | No error expected |
| evolog, rewritten change | change described twice (`describe_commit` ×2), `evolog(None, None)` | 3 entries newest-first (raw walk order); each entry's `predecessor_commit_ids` are the operation's recorded predecessors; `operation_id` names the recording op, and is **null** for entries the walk emits from its flush tail (no recording op) | No error expected |
| evolog, limit | same state, `evolog(None, Some(2))` | Exactly the first 2 entries of that order (the CLI applies `take(limit)` before any reversal) | No error expected |
| evolog, never-rewritten commit | `evolog(Some(<fresh commit>), None)` | Exactly one entry: the commit itself | No error expected |
| evolog, limit 0 | `evolog(None, Some(0))` | Empty entry list, `ok = true` | No error expected |
| evolog, bad revset | `evolog(Some("::("), None)` | Refusal | `jj.revset_parse_error` / `jj.revset_resolution_error` |
| interdiff, rewrite pair | `from` = pre-describe commit, `to` = its rewrite that also adds `b.txt` | `[{b.txt, Added}]` only — the shared parent-side content is factored out by `rebase_to_dest_parent` | No error expected |
| interdiff, identical trees | `from` and `to` with equal trees after rebase | Empty change list, `ok = true` | No error expected |
| interdiff, path filter | same pair, `paths = ["b.txt"]` (and a non-matching filter) | Filtered to the matching prefix; a non-matching filter yields an empty list (the CLI only *warns* about unmatched paths) | No error expected |
| interdiff, both revisions absent | `interdiff(None, None, &[])` | Refusal, no read performed | `jj.invalid_input`, context names that at least one of `from`/`to` is required |
| interdiff, one absent | `interdiff(Some(a), None, &[])` | `to` defaults to `@` | No error expected |
| interdiff, unknown / divergent id | `from` = unknown id, or an id resolving to 2 visible commits | Refusal (CLI `resolve_single_rev` parity) | `jj.change_not_found`, context = the id |
| interdiff, empty id string | `from = ChangeId("")` | Refusal (guards jj-lib's `panic!` on an empty prefix) | `jj.change_not_found` |
| any verb, unknown handle | `handle = 0` or a closed handle | No call into `zanshin-jj` | `ffi.invalid_handle` |
| any verb, null request buffer | `data = null` | — | `ffi.null_pointer` |
| any verb, malformed request buffer | non-FlatBuffers bytes | Verifier rejects before use | `ffi.invalid_argument` |
| any verb, malformed repo config | `.jj/repo/config.toml` with a bad `[revset-aliases]` *value type* | Refusal from the config load `show`/`evolog` perform per call | `jj.config_error` |

</intent-contract>

## Code Map

Zanshin anchors read against the working tree at baseline `a81d1f0`; jj CLI anchors at tag
`v0.44.0` (`git -C ../jj show v0.44.0:<path>`); jj-lib anchors in the vendored `jj-lib-0.44.0`.

**Prior art (read-only, at the tag)**
- `v0.44.0:cli/src/commands/show.rs:34-68` — args: positional `revisions_pos: Vec<RevisionArg>`
  (`REVSETS`) + hidden `-r` alias, **unioned** via `parse_union_revsets` `:83`; default `@` `:79-81`
  when both are empty; `-T/--template`, `--reversed`, `DiffFormatArgs`, `--no-patch` — all
  rendering. `:109` passes **`&EverythingMatcher`**: `show` has *no* path argument.
- `v0.44.0:cli/src/diff_util.rs:667-692` `show_patch` — the observable core:
  `from_tree = commit.parent_tree(repo)`, `to_tree = commit.tree()`, and copy records accumulated
  **per parent id** into one `CopyRecords` `:677-682`.
- `v0.44.0:cli/src/diff_util.rs:1871-1896` `diff_status_inner` / `diff_status` — the A/M/D/C/R
  classification (`copy_operation()` first, then present/absent), which is CLI-side only; jj-lib has
  no "(two trees) → (path, kind)" helper. `:1852-1869` `show_diff_summary` is its `--summary` use.
- `v0.44.0:cli/src/commands/evolog.rs:49-102` — `-r/--revisions` `Vec<RevisionArg>` with
  `default_value = "@"`, unioned then `evaluate_to_commit_ids()` `:113-117`; `-n/--limit` applied
  **before** `--reversed` `:62-64`, `:174-181`; `-p/--patch` is `show_inter_diff` over
  `entry.predecessors()` `:193-206`; `EverythingMatcher` `:199`; graph mode re-orders through
  `TopoGroupedGraph` `:172` (rendering).
- `v0.44.0:cli/src/commands/interdiff.rs:59-80` — `--from`/`--to` both `Option<RevisionArg>`
  defaulting to `@` (`:90`, `:93`), **`ArgGroup … .required(true)`** `:59` (omitting both is a
  refusal), positional `paths: Vec<String>` → `FILESETS` `:74-76`; `resolve_single_rev` for each
  side; `slice::from_ref(&from)` `:118`. Unmatched paths only *warn* (`cli_util.rs:3323-3347`).
- `v0.44.0:cli/src/diff_util.rs:626-664` `show_inter_diff` —
  `from_tree = rebase_to_dest_parent(repo, from_commits, to_commit)` `:648`,
  `to_tree = to_commit.tree()` `:649`, and **`copy_records = CopyRecords::default()`** `:650`.

**jj-lib 0.44.0 (vendored, exact signatures)**
- `commit.rs:132-143` `async fn parent_tree(&self, repo: &dyn Repo) -> BackendResult<MergedTree>` —
  merges *all* parents with conflict resolution; short-circuits to `self.tree()` when the index says
  the commit changed nothing (`:273-280`) — safe for diffs, **never expose it as "the parent tree id"**.
- `merged_tree.rs:282-289` `diff_stream(&self, other, matcher) -> TreeDiffStream<'_>` (a
  `BoxStream`); `:311-319` `diff_stream_with_copies(&self, other, matcher, &CopyRecords)` →
  `BoxStream<CopiesTreeDiffEntry>`; item carries `values: BackendResult<Diff<MergedTreeValue>>`
  (`:365-372`) — a **per-path** error. An empty `CopyRecords` makes the copies-aware stream behave
  exactly like the plain one.
- `evolution.rs:86-101` `pub fn walk_predecessors(repo: &ReadonlyRepo, start_commits: &[CommitId])
  -> impl Stream<Item = Result<CommitEvolutionEntry, WalkPredecessorsError>>` — a **sync fn
  returning a Stream**; walks the *operation* log. `:44-51`
  `CommitEvolutionEntry { commit: Commit, operation: Option<Operation> }`; `:55-60`
  `predecessor_ids()` reads them off the operation and is `&[]` when `operation` is `None`.
  `:114-131` the walk stops at the first op that does not store predecessors and flushes the
  remaining commits with `operation: None`. Errors: `:74-83` `{Backend, OpStore, CycleDetected}`.
- `rewrite.rs:449-489` `pub async fn rebase_to_dest_parent(repo: &dyn Repo, sources: &[Commit],
  destination: &Commit) -> BackendResult<MergedTree>` — in-memory only (no transaction, nothing
  written); fast path `:456-460` returns `source.tree()` when the parents already match; otherwise a
  3-way merge that may leave conflicts.
- `store.rs:106-113` `get_copy_records(paths, root: &CommitId, head: &CommitId)`; native backend
  yields an empty stream (graceful degradation to Added+Removed, already noted at `status.rs:121-122`).

**Extend — `crates/zanshin-jj`**
- `src/commit_views.rs` (**NEW**) — the three verbs, `ShowEntry`, `EvologEntry`,
  `CommitViewError`, a module-private tree-diff→`Vec<FileChange>` helper, and the
  `RevsetError`→`CommitViewError` mapper. Module-doc shape: `file.rs:3-22` / `git.rs:3-42` (CLI
  parity tag, ported CLI files, deliberate divergences). **`ViewError` is already taken by
  `view.rs` — hence `CommitViewError`.**
- `src/status.rs:138-166` — the exact classification to mirror (copy source → `Renamed`/`Copied`;
  else absent-before → `Added`, absent-after → `Removed`, else `Modified`), plus `:121-136` the
  copy-record collection loop and `:77-79` `repo_path_to_pathbuf`. **Read it; do not refactor it**
  (Design Notes). Types `FileChange` `:24-29`, `ChangeKind` `:33-50` (**reused**), `ChangeId` `:56`.
- `src/change.rs:217` `pub(crate) fn change_from_commit(&dyn Repo, &Commit) -> Result<Change, String>`
  — the single `Change` construction site; `Change` `:79-109`; `CommitId` `:18`.
- `src/revset.rs:180` `parse_revset(&Repo, &str)`, `:291` `evaluate_revset(&dyn Repo, &parsed)`,
  and the drive idiom `:143-166` (`load_at_head` → `evaluate_revset` → `set.stream().commits(store)`
  inside one `pollster::block_on`). `RevsetError` `:34-56`.
- `src/mutate.rs:283-293` `fn rev(crate::RevsetError) -> MutateError` — the mapper to mirror
  (Parse→parse, Resolution→resolution, Config→config, JjLibError→Backend).
- `src/op_support.rs:456` `ResolveError`, `:482` `resolve_commit(&dyn Repo, &ChangeId)` (refuses a
  divergent id as `NotFound`, guards the empty id), `:513` `resolve_or_wc(…, Option<&ChangeId>)`
  (the `@` default), `:555` `build_matcher(&[String])` (empty ⇒ `EverythingMatcher`, else
  `PrefixMatcher`; filesets deliberately unparsed). `file.rs:220-227` `fn res(ResolveError,
  Option<&ChangeId>)` is the mapping wrapper template.
- `src/file.rs:241` `fn head_commit(&Workspace, Option<&ChangeId>) -> Result<(Arc<ReadonlyRepo>,
  Commit), FileError>` — the one-snapshot-per-call entry point (`Arc<ReadonlyRepo>` is exactly what
  `walk_predecessors` needs). `FileError` `:159-207` and its `be`/`cfg` helpers `:210-217`.
- `src/repo.rs:289`/`:338`/`:378`/`:416` — the read-verb facade template (`#[must_use = "the Result
  must be used; drop it explicitly if intentional"]`, owned `ChangeId` + the
  `#[allow(clippy::needless_pass_by_value)]` WHY comment at `:286-288`, one-line delegation, the
  `# Errors` bullet-per-variant doc). Place the three facades after the 9.5 git block, before the
  Story 9.3 content ops.
- `src/lib.rs:33` module list (insert `pub(crate) mod commit_views;` between `commit_meta` and
  `config`) and `:50` re-export block (insert the `pub use commit_views::{…};` line between
  `commit_meta` and `config`). `missing_docs` is denied crate-wide (`lib.rs:3`); no `jj_lib` type
  may appear in a public signature (`lib.rs:17-28`, enforced by `test-jj-adapter-hygiene`).

**Extend — wire + FFI**
- `schemas/envelope.fbs` — request tables end at `:162` (append the three new ones there; the
  **field order is the wire contract**, `:36-39`); ledger comment `:164-178` (add a
  `//   Story 9-6 : …` line); payload tables end at `:679`; `union Payload` `:681-703` — **next free
  discriminants are 21, 22, 23**, appended after `GitExportResult` `:702` (append-only note `:693`).
  Reuse `enum ChangeKind : byte` `:201-202`, `table FileChange { path; kind; from_path }` `:205-210`,
  `table Change` `:231-245` and `table Signature` `:220-226`. Conventions: `snake_case`,
  null-for-absence on strings/tables, **presence-flag pair** for an optional scalar
  (`:594-597` `conflict_side`/`has_conflict_side`), saturating `uint` (`:498-501`).
- `crates/zanshin-ffi/src/commit_views.rs` (**NEW**) + `pub mod commit_views;` in `lib.rs:32-48`
  (alphabetical — `cargo fmt` re-sorts, and the header must then be regenerated; see commit
  `f77ecbf`). Template: `file.rs` — error mapper `:27-41`, request-reader banner `:43-49` (owned
  structs, lifetime rationale), reader `:76-91`, required-field reader `:118-128` (`missing_field`),
  payload builders `:165-189`, `extern "C"` skeleton + doc sections `:293-339`. Prefer
  `git.rs:197-209` `unsafe fn session_from_handle<'a>(handle) -> Result<&'a mut RepoSession, …>`
  over the inline 5-line borrow.
- `crates/zanshin-ffi/src/change.rs:63-121` `change_to_envelope` — **split out** a
  `pub(crate) fn change_offset<'a>(b, &Change) -> WIPOffset<fbs::Change<'a>>` (its steps 1–5,
  `:66-107`) so a `Change` can be nested; `signature_offset` `:42-54` stays private to it. This is
  the `build_mutation_result` move Story 9.5 already made (`envelope.rs:227-246`).
- `crates/zanshin-ffi/src/status.rs:41-60` `status_to_envelope` — **split out** a
  `pub(crate) fn file_changes_vector<'a>(b, &[FileChange]) -> WIPOffset<Vector<'a, ForwardsUOffset<
  fbs::FileChange<'a>>>>` (the `:48-60` loop) for reuse; `status_to_envelope` keeps calling it.
- `crates/zanshin-ffi/src/envelope.rs` — the code constants `:14-106` (reuse
  `FFI_INVALID_HANDLE` `:18`, `FFI_NULL_POINTER` `:20`, `FFI_INVALID_ARGUMENT` `:24`,
  `JJ_CHANGE_NOT_FOUND` `:36`, `JJ_INVALID_INPUT` `:45`, `JJ_JJ_LIB_ERROR` `:32`,
  `JJ_REVSET_PARSE_ERROR` `:91`, `JJ_REVSET_RESOLUTION_ERROR` `:94`, `JJ_CONFIG_ERROR` `:98` —
  **no new constant**); `FfiErrorObj` `:119-127`; `reject_null_request` `:136-148`;
  `invalid_request` `:150-156`; `missing_field` `:158-170`; `finish_envelope` `:357-379`
  (the shared tail every payload builder ends with); `err` `:381-409`; `catch` `:411-438`.
- `crates/zanshin-ffi/src/repo.rs:299-319` `RepoSession` — extend the doc's enumeration of the read
  wrappers that borrow `.repo` (`:304-306`). `map_mutate_err` `:89` is *not* used here.
- `crates/zanshin-ffi/src/ffi_strings.rs:106-110` `ZanshinBuf`, `:121-127` `vec_into_token`.

**Extend — Dart (`packages/zanshin_core`)**
- `lib/src/ffi/commit_views.dart` (**NEW**) — banners `// ── Request-buffer helpers ──` /
  `// ── FFI adapters ──` / `// ── Dart models ──` / `// ── Decoder ──`. Templates in
  `ffi/file.dart`: `_withRequestBytes` `:25-38`, `_rejectInteriorNul` `:40-49`, `_callWithRequest`
  `:59-72`, an adapter `:76-88`, a model `:169-192`, the decoder triple `:283-308`, `_okEnvelope`
  `:397-405`. Reuse models: `ffi/change.dart` `Change` `:75-127` and `ffi/status.dart`
  `FileChange` `:52`, `FileChangeKind` `:71` — imported with `show`, the `file.dart:13`
  (`import 'mutate.dart' show SkippedPath;`) precedent.
- `lib/src/ffi/change.dart:146-170` and `lib/src/ffi/status.dart:97-…` — extract the nested-table
  mapping now inlined in each private decoder into a library-internal `Change mapChangeTable(
  fbs.Change)` / `FileChange mapFileChangeTable(fbs.FileChange)` that both the existing decoder and
  `commit_views.dart` call, so a future `Change` field cannot be added to one mapper only.
- `lib/src/worker/commands.dart` — sealed base `:11-17`; request-carrying template
  `FileListCommand` `:402-425`; append after `GitRemoteSetUrlCommand` ends `:636`, before
  `ShutdownCommand` `:643` (**must stay last**).
- `lib/src/worker/isolate.dart` — aliased imports `:11-35`; `ZanshinWorker` method template
  `fileList` `:832-854`; append methods after `gitRemoteSetUrl` (`:1042-…`), before the
  `// ─── Worker entry point ───` banner `:1061`; switch-arm template (with the synthesized
  `ffi.invalid_handle` envelope) `:1460-1479`; append arms after the `GitRemoteSetUrlCommand` arm
  ends `:1662`, before `case ShutdownCommand():` `:1664`.
- `lib/src/worker/handle.dart` — `show`-listed imports `:3-15`; `RepoHandle` `:32`; the **non-async**
  `_closed`-guard method template `fileList` `:352-382`; append after `gitRemoteSetUrl` `:594-599`,
  before the `// GC backstop:` comment `:601`.
- Generated, regenerate only via `cargo make codegen`: `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `crates/zanshin-ffi/src/envelope_generated.rs`, `lib/src/ffi/bindings.dart`,
  `lib/src/ffi/envelope_zanshin.ffi_generated.dart`.

**Tests / gates**
- `crates/zanshin-jj/tests/file_reads.rs` — the closest harness: `ENV_GUARD`/`pin_env` `:40-49`,
  `make_test_settings` `:51-68`, `jj_repo` (**the raw jj-lib oracle**; never assert with a second
  call to the code under test — `:17-20`) `:71-81`, `head_op_id` `:114-116`, `write_repo_config`
  `:118-120`, `open` `:149-151`, and the purpose-built-commit style of `mixed_tree` `:125-147`.
  `tests/content_ops.rs` is the second model.
- `crates/test-helpers/src/lib.rs` — `extract_fixture` `:41`, `add_commit_off_root` `:95`,
  `add_commit_with_files(root, parents, files, desc)` `:196` (arbitrary parents ⇒ multi-parent
  commits are constructible), `add_commit_with_entries` `:236`, **`describe_commit` `:300` — the
  only helper that records a predecessor edge (`rewrite_commit` + `rebase_descendants`), so it is
  how an `evolog` chain and an `interdiff` rewrite pair get built**, `add_divergent_twin` `:323`,
  `abandon_commit` `:347`, `add_conflicted_merge_off_root` `:363`. Fixtures
  (`tiny-3-commits` = 3 linear commits, one operation; `medium-1k-commits` = one 3-parent merge)
  contain **no rewritten or divergent commit**, and **regenerating a fixture is forbidden**
  (`test-helpers/src/lib.rs:135-138`).
- `crates/zanshin-jj/tests/api_stability.rs` — alias block `:19-106` with the running type count in
  the header `:12-17` (**currently 55**), `sample_*` constructors, and the per-story
  `*_surface_resolves` convention (`file_reads_surface_resolves` `:433`,
  `git_ops_surface_resolves` `:494`, which also asserts each new error variant's `Display` because
  an unexercised `thiserror` arm is an uncovered line). Never extend `api_surface_resolves` `:272`.
- `crates/zanshin-ffi/tests/file_ffi.rs` — `read_and_free` `:49-62`, `parse_envelope` `:64-66`,
  `open_handle`/`close_handle` `:73-92`, `change_id_for_commit` `:96-101`, the request-buffer
  builders `:107-197` (**including the deliberately-absent-field variants** `:151-178`),
  `open_scenario` `:201-224` (with the `std::mem::forget(fixture)` so the `TempDir` outlives the
  handle), and `no_file_read_wrapper_writes_an_operation` `:754-760`.
- `packages/zanshin_core/test/ffi/file_test.dart:22-32` — `errorEnvelope` / `wrongPayload`
  synthetic-buffer helpers; one NUL-guard test per string parameter
  (`test/ffi/mutate_test.dart:226-284`).
- `packages/zanshin_core/test/worker/file_test.dart:3-24` — **the header paragraph the new worker
  test file must carry** ("…what credits each `zanshin_*` extern \"C\" function in the coverage
  ratchet's extern-fn guard"), plus the SCOPE NOTE about D2 (Zanshin never snapshots).
- `Makefile.toml` — `[tasks.test]` `:47-72` (`coverage` last), `[tasks.codegen]` `:289-295`,
  `[tasks.verify-codegen]` `:348` (manual; refuses on a dirty tree), `[tasks.coverage]` `:449-570`
  with the **extern-fn guard** `:537-564`. `coverage-baseline.txt`: `epsilon_pct = 0.10`,
  `new_file_floor_pct = 80.00`; siblings sit at 100.00 (`zanshin-ffi/src/file.rs`, `git.rs`),
  `zanshin-jj/src/status.rs = 88.89`, `op_support.rs = 99.59`.
- `docs/rust-error-codes.md:33-65` the registry table, `:69-74` the four-step add procedure, and the
  established reuse annotation `; also emitted — Story 9.6 by …` (see `:43`, `:47`, `:56` for the
  wording, including how a *widened* meaning is called out).

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/commit_views.rs` (new) -- add the module doc (CLI parity tag `v0.44.0`,
  the three ported CLI files, the deliberate divergences listed under **Never**), the owned types
  `ShowEntry { change: Change, file_changes: Vec<FileChange> }` and `EvologEntry { change: Change,
  predecessor_commit_ids: Vec<CommitId>, operation_id: Option<OperationId> }` (both
  `#[derive(Debug)]`), and `CommitViewError` with `ChangeNotFound { id }`, `InvalidInput { reason }`,
  `RevsetParseError { reason }`, `RevsetResolutionError { reason }`, `Config { reason }`,
  `Backend(String)` -- the name `ViewError` is taken by `view.rs`, and each variant maps onto an
  already-registered code so no new one is minted.
- `crates/zanshin-jj/src/commit_views.rs` -- implement `show(repo, revset: Option<&str>)`: default
  the revset to `@`, parse it through `revset::parse_revset` (config + aliases per call, never
  cached), `load_at_head` once, `evaluate_revset` and drive `set.stream().commits(store)` inside one
  `pollster::block_on`; per commit build the metadata with `change::change_from_commit` and the
  file changes from `commit.parent_tree(repo)` vs `commit.tree()` with copy records accumulated over
  **all** parent ids -- one snapshot per call so two halves of a result can never disagree.
- `crates/zanshin-jj/src/commit_views.rs` -- implement `evolog(repo, revset: Option<&str>, limit:
  Option<usize>)`: resolve the revset to commit ids the same way, feed them as the start set to
  `evolution::walk_predecessors(&readonly, &ids)`, drive the stream with `pollster::block_on`,
  `take(limit)` in walk order (the CLI limits before reversing), and project each
  `CommitEvolutionEntry` into `EvologEntry` -- `predecessor_ids()` are commit ids because all
  predecessors share one change id, and a `None` operation marks the walk's flush tail.
- `crates/zanshin-jj/src/commit_views.rs` -- implement `interdiff(repo, from: Option<&ChangeId>,
  to: Option<&ChangeId>, paths: &[String])`: refuse `InvalidInput` when **both** are absent (the
  CLI's `ArgGroup … required(true)`), otherwise resolve each side with `op_support::resolve_or_wc`
  (single-rev, refuses a divergent id), build the matcher with `op_support::build_matcher`, compute
  `rebase_to_dest_parent(repo, [from], to)` and diff that tree against `to.tree()` with an **empty**
  `CopyRecords` -- mirroring `show_inter_diff`, which passes `CopyRecords::default()`.
- `crates/zanshin-jj/src/commit_views.rs` -- add the module-private tree-diff helper that drives
  `diff_stream_with_copies` and classifies each entry into `ChangeKind` (copy source first, then
  present/absent), and the `RevsetError` -> `CommitViewError` mapper modelled on `mutate.rs:287`;
  reusing the shipped `FileChange`/`ChangeKind` keeps one per-path vocabulary across `status`,
  `show` and `interdiff`.
- `crates/zanshin-jj/src/repo.rs` -- add the three `#[must_use]` facades (`show`, `evolog`,
  `interdiff`) after the Story 9.5 git block, each a one-line delegation with the house doc block
  (summary naming the CLI verb, the ADR-0002 re-resolve + read-only + never-writes-an-operation
  sentence, defaults, deliberate divergences, `# Errors` one bullet per variant).
- `crates/zanshin-jj/src/lib.rs` -- declare `pub(crate) mod commit_views;` and re-export
  `CommitViewError`, `EvologEntry`, `ShowEntry`, both alphabetically between `commit_meta` and
  `config`.
- `schemas/envelope.fbs` -- append `ShowRequest { revset }`, `EvologRequest { revset; limit;
  has_limit }` (presence-flag pair, the only shape flatc 25.12.19 accepts for an optional scalar)
  and `InterdiffRequest { from; to; paths }` to the request block; append `ShowEntry`, `ShowView`,
  `EvologEntry`, `EvologView`, `InterdiffView` to the payload tables reusing `Change` and
  `FileChange`; append `ShowView`, `EvologView`, `InterdiffView` as Payload slots 21-23; add the
  Story 9-6 ledger line.
- `crates/zanshin-ffi/src/change.rs` + `crates/zanshin-ffi/src/status.rs` -- extract
  `pub(crate) change_offset` and `pub(crate) file_changes_vector` from the two existing envelope
  builders (which keep calling them) so the new payloads can nest a `Change` and a `[FileChange]`
  without a second builder -- the same move Story 9.5 made for `build_mutation_result`.
- `crates/zanshin-ffi/src/commit_views.rs` (new) + `lib.rs` -- add the error mapper, three request
  readers returning owned structs (null/verifier guards via `reject_null_request`/`invalid_request`),
  three payload builders ending in the shared `finish_envelope`, and the three `extern "C"` wrappers
  `zanshin_show`/`zanshin_evolog`/`zanshin_interdiff` (`handle`, `data`, `len` -> `*mut ZanshinBuf`)
  with the full doc block (`# Errors` one bullet per code, `# Safety` handle + buffer + free-once
  contract); update the `RepoSession` doc's read-wrapper enumeration.
- `cargo make codegen` -- regenerate and commit `zanshin_ffi.h`, `envelope_generated.rs`,
  `bindings.dart` and `envelope_zanshin.ffi_generated.dart` in the same change as the `.fbs` and
  `extern "C"` edits; `cargo make verify-codegen` must then report no drift on a clean tree.
- `packages/zanshin_core/lib/src/ffi/commit_views.dart` (new) -- the three adapters (interior-NUL
  guards on every string parameter), the `ShowEntry`/`EvologEntry` models reusing `Change`,
  `FileChange` and `FileChangeKind`, and the three decoder triples that guard the union discriminant
  before the cast.
- `packages/zanshin_core/lib/src/ffi/change.dart` + `status.dart` -- extract the nested-table
  mapping into internal `mapChangeTable`/`mapFileChangeTable` helpers used by both the existing
  decoders and the new one.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` -- add `ShowCommand`,
  `EvologCommand`, `InterdiffCommand` (before `ShutdownCommand`), the aliased import, the three
  `ZanshinWorker` methods, the three switch arms with the synthesized `ffi.invalid_handle` envelope,
  and the three non-async `RepoHandle` methods behind the `_closed` guard.
- `crates/zanshin-jj/tests/commit_views.rs` (new) -- cover every jj-level row of the I/O matrix
  against a raw jj-lib oracle, building the evolution chain and the interdiff pair with
  `describe_commit` and the divergent case with `add_divergent_twin`; assert `head_op_id` is
  unchanged around every call including refusals.
- `crates/zanshin-ffi/tests/commit_views_ffi.rs` (new) -- cover the envelope/verifier contract, the
  request-buffer readers (including absent-field and malformed-buffer variants), a zero-handle
  assertion per wrapper, and one cross-cutting no-operation-written test.
- `packages/zanshin_core/test/ffi/commit_views_test.dart` +
  `packages/zanshin_core/test/worker/commit_views_test.dart` (new) -- decode-contract tests over
  synthetic buffers (ok / error / wrong-payload / empty-list) and real-cdylib worker tests that call
  each of the three `extern "C"` functions at least once, carrying the extern-fn-guard header
  paragraph.
- `crates/zanshin-jj/tests/api_stability.rs` -- add the Story 9.6 alias block, bump the header type
  count, add `sample_*` constructors naming every field of the two new structs, and a
  `commit_views_surface_resolves` test pinning the three method signatures and every
  `CommitViewError` variant's `Display`.
- `docs/rust-error-codes.md` -- append `; also emitted — Story 9.6 by …` clauses to the reused rows
  (`ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.change_not_found`,
  `jj.invalid_input`, `jj.jj_lib_error`, `jj.revset_parse_error`, `jj.revset_resolution_error`,
  `jj.config_error`); add no new row.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- flip
  `9-6-read-views-show-evolog-interdiff` to `done` with a summary comment in the established style.

**Acceptance Criteria:**
- Given the three verbs exist, when a caller reaches them from Dart, then the whole chain is present
  for each -- `.fbs` request + payload, typed `zanshin-jj` op, `extern "C"` wrapper, regenerated and
  committed codegen, Dart adapter, `WorkerCommand`, `ZanshinWorker` method and `RepoHandle` method --
  and `cargo make verify-codegen` reports no drift.
- Given `show` runs on a commit, when its result is compared with a raw jj-lib oracle, then
  `.change` is byte-identical to what `Repo::get_change` reports for the same commit and
  `.file_changes` equals the classification of `commit.parent_tree` vs `commit.tree()` -- proving
  the metadata half reuses the single `Change` construction site rather than a second projection.
- Given a commit that renames a file (git backend), when `show` reports it, then the entry is
  `Renamed` with `from_path` set; given the same pair through `interdiff`, then no `Renamed`/
  `Copied` entry is ever produced, because `interdiff` passes no copy records -- the CLI's own
  asymmetry.
- Given any of the three verbs is called, when it succeeds **and** when it refuses, then the head
  operation id is unchanged, at both the `zanshin-jj` and the FFI layer.
- Given the story adds no new `error.code`, when the registry is inspected, then every failure path
  maps onto an already-registered code and the registry gained only "also emitted" clauses.
- Given `cargo make test` runs on the final tree, then it exits 0 -- cargo test, clippy pedantic
  `-D warnings`, rustfmt, flutter/dart analyze + format, `cargo deny`, the coverage ratchet and the
  extern-fn guard -- with no baseline entry lowered and no `exclude_prefix` added, and the raised
  `coverage-baseline.txt` is committed with the code that earned it.
- Given the working tree at the end of the run, when `git status --porcelain` is inspected, then it
  is clean and every commit message ends with the required co-author trailer.

## Spec Change Log

**2026-09-03 — two I/O-matrix rows corrected against jj-lib 0.44.0 (implementation).**

1. *"show, divergent change id → **Both** commits are returned … the CLI's `show` unions revsets
   and never refuses ambiguity"* is **wrong at v0.44.0**, and so is the Design Note built on it
   ("with a `ChangeId`, `show` of a divergent change would refuse, while the CLI shows both
   commits"). A bare divergent change-id SYMBOL is a resolution failure inside jj-lib's own
   `SymbolResolver` (`revset.rs:2827` `RevsetResolutionError::DivergentChangeId`), which every
   revset — the CLI's included — hits before evaluation. `jj show <divergent-id>` therefore
   refuses too. CLI parity (NFR-R-2) means refusing it here as `jj.revset_resolution_error`,
   which is still a *different* refusal from `interdiff`'s `jj.change_not_found` — the parameter
   currency split the story exists to make is intact, just for a different reason. The fact the
   row was meant to prove — that `show` emits one entry per COMMIT, not per change — is pinned
   instead by unioning the two commit hexes, which are ordinary revset symbols
   (`show_is_per_commit_and_refuses_a_bare_divergent_change_id`).
2. *"evolog, rewritten change → … `operation_id` … is **null** for entries the walk emits from
   its flush tail"* holds, but the scenario the row prescribes does not reach that state: a
   commit created by `MutableRepo::new_commit` still has a predecessor record (an EMPTY one), so
   `walk_predecessors` emits it with `operation: Some(op)` and no predecessors. The flush tail is
   reached when the walk exhausts the op log with commits still unvisited — deterministically for
   the ROOT commit, which no operation ever created. Both facts are now pinned separately
   (`evolog_walks_every_version_newest_first_with_its_predecessors` +
   `evolog_of_the_root_commit_is_emitted_from_the_flush_tail`).

**2026-09-04 — a third I/O-matrix row's scenario substituted (review).**

3. *"interdiff, rewrite pair → `from` = pre-describe commit, `to` = its rewrite that also adds
   `b.txt`"* prescribes a scenario that cannot exercise the mechanism the row exists to prove. A
   `describe_commit` rewrite keeps its parents, and `rebase_to_dest_parent` fast-paths to
   `source.tree()` when the parents already match (`rewrite.rs:456-460`, recorded in this spec's
   own Code Map) — so the row's pair never reaches the rebase, and a plain two-tree diff would
   satisfy it. The tests substitute a pair whose PARENTS differ (`interdiff_pair`): `from` on
   `p1`, `to` on `p2` which carries `extra.txt`, so a plain diff would report `extra.txt` and
   only the real rebase factors it out. That is a strictly stronger witness for "the parent
   difference is factored out". It does NOT witness the row's other, unstated half — comparing
   two versions of one change — which the shipped `ChangeId` currency cannot express at all; that
   gap is recorded in `deferred` rather than papered over.

## Review Triage Log

### 2026-09-04 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 9: (high 0, medium 2, low 7)
- defer: 6: (high 0, medium 3, low 3)
- reject: 14: (high 0, medium 2, low 12)
- addressed_findings:
  - `[medium]` `[patch]` `interdiff`'s doc claimed both sides are "resolved the way the CLI's
    `resolve_single_rev` resolves them" — true only of the ambiguity refusal. `resolve_commit`
    takes a reverse-hex CHANGE-ID prefix and `into_visible()`, so a commit hex, a revset
    expression and a hidden commit are all unaddressable, where the CLI accepts all three.
    Corrected at every layer (`commit_views.rs` module + `interdiff` doc, `Repo::interdiff`,
    `zanshin_interdiff`, `InterdiffRequest`, `zanshinInterdiff`, `ZanshinWorker.interdiff`,
    `RepoHandle.interdiff`) and the composition consequence named explicitly.
  - `[medium]` `[patch]` `interdiff`'s two symmetric `map_err` closures were exercised only on
    the `from` side, so mistyping the second as `res(e, from)` echoed the side the caller got
    RIGHT and the whole suite still passed. `interdiff_refuses_an_unknown_divergent_or_empty_
    revision_on_either_side` now runs every spelling through both sides against a resolvable
    counterpart.
  - `[low]` `[patch]` `EvologEntry.change` inherits two fields derived against the CURRENT view
    rather than that version's moment (`divergent`, `is_anonymous`), a consequence of reusing
    the single `Change` construction site. Documented on the Rust struct, the `.fbs` table, the
    Dart model, and both `evolog` facades.
  - `[low]` `[patch]` `evolog`'s negative-limit guard lived only in the FFI adapter, which runs
    in the WORKER isolate — so the `ArgumentError` that `ZanshinWorker.evolog` and
    `RepoHandle.evolog` both document was caught by the dispatch loop and reached the caller as
    `internal.dispatch_error`. Guard added on the calling side; the adapter keeps its own as the
    backstop for a direct caller.
  - `[low]` `[patch]` The `uint` saturation clamp in `zanshinEvolog` was documented in four
    places and asserted in none; replacing it with the obvious `limit ?? 0` passed every test
    while turning "give me everything" into an empty evolog. Pinned by a real-cdylib worker test
    at `limit: 0x100000000`.
  - `[low]` `[patch]` The documented absent-vs-explicitly-empty revset distinction had no
    witness, so normalizing `""` to `None` anywhere on the wire would have turned a cleared
    revset box into a silent answer about `@`. Pinned in
    `show_refuses_a_malformed_or_unresolvable_revset_without_writing_an_operation`.
  - `[low]` `[patch]` `docs/rust-error-codes.md` registers `jj.config_error` for `evolog`, which
    reaches it through its own `parse_revset` call, but only `show` had a witness. Added
    `evolog_reports_a_malformed_repo_config_as_a_config_error`.
  - `[low]` `[patch]` `sprint-status.yaml` recorded `zanshin-jj/src/commit_views.rs 95.63` while
    `coverage-baseline.txt` had been raised to 98.13. Summary comment refreshed to the reviewed
    final state.
  - `[low]` `[patch]` The `interdiff` rewrite-pair I/O-matrix row's scenario was substituted in
    the tests with no Spec Change Log entry; entry 3 now records the substitution and why the
    row's own scenario cannot reach the rebase.

## Design Notes

**Why the diff half is a per-path change list, not hunks.** `jj show`'s patch is rendered by
`DiffRenderer` in a format the user picks (`--git`, `--color-words`, `--stat`, `--summary`).
Line- and word-level diffing plus syntax highlighting is Epic 5 (`zanshin-diff`, stories 5-1…5-8,
all `backlog`), and epics.md names exactly two mechanisms for this story -- `Commit::parent_tree`
and `MergedTree::diff_stream`. Those produce `(path, before, after)`, which the CLI classifies into
A/M/D/C/R (`diff_util.rs:1871-1896`). So the observable data this story can carry today is the
per-path change list; the hunks arrive with Epic 5 and will extend, not replace, these payloads.

**Why the parameter currency splits.** Story 9.3 already recorded the rule: a single revision is a
`ChangeId`, but a parameter whose CLI form is a *set* stays a revset string, because materializing
it would destroy alias and config resolution (FR-JJ-17). `jj show` and `jj evolog` both take
`Vec<RevisionArg>` and union them; `jj interdiff` takes two `resolve_single_rev` arguments.

Matching that arity is not cosmetic, but the ORIGINAL argument for it was wrong and is corrected
here (see the Spec Change Log): "with a `ChangeId`, `show` of a divergent change would refuse,
while the CLI shows both commits" does not hold at v0.44.0 — a bare divergent change-id symbol is
refused by jj-lib's own `SymbolResolver` before evaluation, so the CLI refuses it too. The real,
still-observable difference is **which stage refuses, and under which code**: a revset verb fails
during symbol RESOLUTION (`jj.revset_resolution_error`, jj-lib's `DivergentChangeId`, raised for
the whole expression), while `interdiff` fails in its own single-revision resolver
(`jj.change_not_found`, with the offending id echoed in `context`). A GUI needs that split: the
first says "your expression is ambiguous — disambiguate it" and the second says "that revision
does not resolve". Two further consequences of the arity are unaffected by the correction and are
themselves observable: a revset verb accepts `a | b`, `none()`, `root()` and every alias the
user's config defines, none of which a `ChangeId` parameter could carry (FR-JJ-17); and its rows
are per COMMIT, so unioning two commit hexes of one divergent change yields two entries sharing a
`Change.id` — a shape `interdiff`'s currency cannot express at all.

**Why `evolog` rows are keyed by commit id.** Every predecessor of a change shares its change id, so
a list of `Change` rows would differ only in `commit_id`; and predecessors are *hidden* by
construction, which `op_support::resolve_commit` refuses (`op_support.rs:493`). The edges therefore
travel as `predecessor_commit_ids`. `operation_id` is kept because `CommitEvolutionEntry.operation`
is `None` exactly for the entries the walk flushes when it can go no further
(`evolution.rs:114-131`) -- it is the only signal a caller has that an evolution may be truncated,
and truncation is silent in the CLI.

**Why `status.rs` is not refactored.** The classification loop (`status.rs:138-166`) is the same
five-line present/absent decision the new verbs need, and Story 9.4's precedent was to *lift* shared
resolvers into `op_support.rs` rather than copy them. It does not apply here. The three call sites
differ in the half that matters -- `status` uses first-parent copy records (its own documented D4
approximation), `show` accumulates records over every parent, `interdiff` passes none -- so only a
trivial mapping is common. Lifting it would also move ~35 covered lines out of a file sitting at
88.89% baseline, mechanically dropping the remainder below its ratchet entry and dragging
working-copy-status test work into a read-views story. The shared *vocabulary* (`FileChange`,
`ChangeKind`, and their wire tables) is reused; the derivation stays with its verb. If a third
consumer appears, lift then.

**Traps to respect.** `Commit::parent_tree` short-circuits to the commit's own tree for an
index-empty commit (`commit.rs:134-143`) -- harmless for a diff, wrong if a tree id were ever
surfaced. `walk_predecessors` takes `&ReadonlyRepo` (not `&dyn Repo`) and returns a `Stream` from a
*sync* fn. `rebase_to_dest_parent` fast-paths to `source.tree()` when the parents already match
(`rewrite.rs:456-460`), so an interdiff between a commit and itself is trivially empty, and its
3-way merge can leave conflict states in the resulting tree. `TreeDiffEntry.values` is a **per-path**
`BackendResult`: the CLI aborts on the first error (`diff_util.rs:1859`) -- do the same rather than
inventing a per-path skip channel. An unmatched path filter is a CLI *warning*, not an error.

## Verification

**Commands:**
- `cargo make test` -- expected: exit 0, run unpiped (cargo test + clippy pedantic `-D warnings` +
  rustfmt + flutter/dart analyze + format + `cargo deny` + coverage ratchet + extern-fn guard).
  This is the single gate.
- `cargo make codegen` then `cargo make verify-codegen` -- expected: the second reports no drift.
  Run `verify-codegen` only on a clean tree; it refuses otherwise.
- `git -C ../jj show v0.44.0:cli/src/commands/show.rs` (and `evolog.rs`, `interdiff.rs`,
  `cli/src/diff_util.rs`) -- expected: re-confirms arg arity, the `@` defaults, the interdiff
  ArgGroup refusal and the copy-record asymmetry before relying on the anchors above.
- `git status --porcelain` -- expected: clean after each commit; the four generated files appear
  only together with the `.fbs`/`extern "C"` change that earned them, and `coverage-baseline.txt`
  only if the ratchet raised it.

**Manual checks (if no CLI):**
- Diff the crate's `pub` items: the additions are exactly three `Repo` methods, two structs and one
  error enum, and no `jj_lib` type appears in a public signature.

## Auto Run Result

Status: done
Blocking condition: none

### Summary of implemented change

Story 9.6 adds the jj CLI's three commit READ views — `show`, `evolog`, `interdiff` — as typed
`zanshin-jj` operations in a new `commit_views.rs` noun module, and surfaces each through the full
chain Stories 9.3–9.5 established: `schemas/envelope.fbs` request + payload tables, an `extern "C"`
wrapper in `zanshin-ffi`, committed `flatc`/cbindgen/ffigen output, and the Dart
adapter → `WorkerCommand` → `ZanshinWorker` → `RepoHandle` path. `show` diffs each commit against
its MERGED parent tree with copy records accumulated over EVERY parent; `evolog` walks
`evolution::walk_predecessors` in raw walk order with `take(limit)` applied before any reversal;
`interdiff` rebases `from` onto `to`'s parents in memory (`rewrite::rebase_to_dest_parent`) with
deliberately EMPTY copy records. The diff half is the CLI's per-path change list (`FileChange` /
`ChangeKind`), not hunks — Epic 5 owns textual diffing. Zero new `error.code` rows; nine registry
rows gained "also emitted" clauses. `zanshin-mcp` untouched (Epic 7 owns the tool surface).

This run resumed a spec left at `in-review` after two interrupted predecessors: the feature commit
and a close-out commit existed, but no review had been recorded and the working tree carried a
half-applied patch round. That work was completed, codegen regenerated, the gate driven green, and
then the full review pass below was run over the whole diff since baseline.

### Files changed

- `crates/zanshin-jj/src/commit_views.rs` (new) — the three verbs, `ShowEntry`, `EvologEntry`,
  `CommitViewError`, the tree-diff → `Vec<FileChange>` classifier, the per-parent copy-record
  accumulator, and the `RevsetError`/`ResolveError` mappers.
- `crates/zanshin-jj/src/repo.rs` — the three `#[must_use]` `Repo` facades and their doc blocks.
- `crates/zanshin-jj/src/lib.rs` — module declaration and re-exports.
- `crates/zanshin-jj/tests/commit_views.rs` (new) — 22 integration scenarios against a raw jj-lib
  oracle, including a git-backed workspace for the rename/copy rows.
- `crates/zanshin-jj/tests/api_stability.rs` — the Story 9.6 alias block, `sample_*` constructors
  and `commit_views_surface_resolves`.
- `schemas/envelope.fbs` — `ShowRequest`, `EvologRequest` (presence-flag limit pair),
  `InterdiffRequest`; `ShowEntry`, `ShowView`, `EvologEntry`, `EvologView`, `InterdiffView`;
  `Payload` slots 21–23; the Story 9-6 ledger line.
- `crates/zanshin-ffi/src/commit_views.rs` (new) — request readers, payload builders and the three
  `extern "C"` wrappers.
- `crates/zanshin-ffi/src/{change,status}.rs` — `change_offset` / `file_changes_vector` extracted so
  the new payloads nest a `Change` and a `[FileChange]` without a second builder.
- `crates/zanshin-ffi/src/{lib,repo}.rs` — module declaration; `RepoSession`'s read-wrapper doc.
- `crates/zanshin-ffi/tests/commit_views_ffi.rs` (new) — envelope/verifier contract, request-reader
  variants, per-wrapper zero-handle assertions, and the cross-cutting no-operation-written test.
- `packages/zanshin_core/lib/src/ffi/commit_views.dart` (new) — adapters, models, decoders.
- `packages/zanshin_core/lib/src/ffi/{change,status}.dart` — `mapChangeTable` /
  `mapFileChangeTable` extracted so a future field cannot reach one decoder only.
- `packages/zanshin_core/lib/src/worker/{commands,isolate,handle}.dart` — the three commands,
  switch arms, `ZanshinWorker` methods and `RepoHandle` methods.
- `packages/zanshin_core/test/{ffi,worker}/commit_views_test.dart` (new) — decode-contract tests
  over synthetic buffers plus real-cdylib worker tests.
- Committed codegen: `crates/zanshin-ffi/include/zanshin_ffi.h`,
  `crates/zanshin-ffi/src/envelope_generated.rs`,
  `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}`.
- `docs/rust-error-codes.md` — "also emitted" clauses on nine reused rows; no new row.
- `coverage-baseline.txt` — `zanshin-jj/src/commit_views.rs` 95.63 → 98.13, `repo.rs` 95.74 →
  95.97; nothing lowered, no `exclude_prefix` added.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` — the story flipped to `done` with the
  summary comment refreshed to this reviewed final state.

### Review findings breakdown

Four review layers ran in parallel (blind hunter, edge-case hunter, verification-gap, intent
alignment).

- Patches applied: 9 — 0 high, 2 medium, 7 low. Listed individually in the Review Triage Log.
- Items deferred: 6 — 3 medium, 3 low. In the `deferred` frontmatter, with evidence.
- Items rejected: 14. The substantive ones and why: the duplicated `session_from_handle` and the
  duplicated `status.rs` classifier are the crate's existing per-module pattern, and this spec's
  Design Notes explicitly forbid refactoring `status.rs`; the classifier's `(absent, absent)`
  fall-through to `Modified` (where the CLI `panic!`s) is unreachable — a tree diff never yields an
  equal pair — and an error arm would add a line the coverage ratchet could not cover;
  `res(NotFound, None)` producing an empty `context` is a defensive arm `resolve_or_wc` cannot
  reach (an absent id fails as `Backend`) and is deliberately unit-tested as such; the four Dart
  copies of `_withRequestBytes`/`_rejectInteriorNul` and `isolate.dart`'s repeated synthesized
  `ffi.invalid_handle` envelope are already on Story 9.4's deferred list; the read wrappers' `&mut`
  session borrow matches every existing read wrapper and changing it is a crate-wide refactor; and
  "the spec artifact was never closed out" is precisely what this run does.

### Follow-up review recommendation

`followup_review_recommended: true`. Patched findings by severity: high 0, medium 2, low 7. No
high-severity patch, so the score decides: `3 × 2 + 1 × 7 = 13`, which is ≥ 5.

### Verification performed

- `cargo make test` — exit 0, run unpiped, three times across this run (on the inherited dirty tree,
  after completing the half-applied patch round, and after the review patches). Final run: all Rust
  suites green, clippy pedantic `-D warnings` clean, rustfmt clean, `dart analyze --fatal-infos
  --fatal-warnings` clean, `dart format` clean, `cargo deny` clean, coverage held at 99.13 %
  (7964/8034 lines over 42 files) with no baseline entry lowered and no `exclude_prefix` added, and
  `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered`.
- `cargo make codegen` then `cargo make verify-codegen` — run after each of the two commits this run
  created, since both carried `.fbs` / `extern "C"` doc corrections. Both times: no drift.
- `git status --porcelain` — clean after each commit.
- Note for future runs: the inherited `.fbs` edit was doc-comment only, but `flatc` propagates doc
  comments into both generated accessors, so codegen had to be regenerated BEFORE gating; the
  header and `bindings.dart` moved too, because cbindgen and ffigen lift the `extern "C"` doc block.

### Residual risks

- The `interdiff` currency gap (first `deferred` item) is the substantive one: the story's own
  motivating question — what differs between two versions of the same work — is not answerable
  through the shipped API, because a hidden predecessor has no address in a `ChangeId` parameter.
  Every layer now documents this and no test claims otherwise, but a GUI author reading only the
  story title could reasonably expect it to work.
- `show` is unbounded by design (CLI parity), so a broad revset on a large repository builds one
  large FlatBuffers envelope. Not measured; no committed fixture is large enough for the suite to
  notice.
- Copy/rename classification produces `Renamed`/`Copied` only on the git backend; on the native
  backend it degrades to `Added`+`Removed`. That is jj-lib's own behavior and is documented, but it
  means the two backends give observably different `show` output for the same operation.
- The interrupted predecessor runs leave this story's history spread over four commits rather than
  the usual two; the feature commit and the first close-out commit predate any review.
