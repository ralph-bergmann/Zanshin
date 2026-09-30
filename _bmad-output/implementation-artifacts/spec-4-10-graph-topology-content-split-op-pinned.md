---
title: 'Story 4.10: Graph topology vs. card content — index-only topology call + op-pinned batch content lookup'
type: 'feature'
created: '2026-09-30'
status: 'done'
baseline_revision: '64ed3b32cc3d76e2ecfc75db1b8dbc1ceb5dd828'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md'
  - '{project-root}/_bmad-output/planning-artifacts/epics.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The commit-graph view (Epic 10) lays out the WHOLE revset before its first frame (4.11, in Dart), but the only graph read, `Repo::walk_graph` / `zanshin_graph_slice`, loads every commit object inline for the card metadata (`crates/zanshin-jj/src/graph.rs:233-234`). The topology therefore waits for all content: ~1.2 s on the loose `large-10k` fixture, and on a real repo ~115 ms of `empty` checks on merges. Content is only needed for the visible page.

**Approach:** Split `jj log` along "index/View-derived" vs "object-derived". A new `Repo::graph_topology` (next to an unchanged `walk_graph`) runs the pre-verb precondition exactly once and returns, index-only per node, the whole revset's nodes in `jj log` order with the view half, an exact `parent_count`, jj's edges verbatim (targets resolved to node indices), `all_count`, the anchor node sets, committer timestamps only on request, and the `operation_id` it loaded. A new `Repo::commit_contents(&self, operation_id, commit_ids)` reads the object half at that PINNED operation (`load_operation` + `load_at`, never `load_at_head`) and ships full-stack: `zanshin_commit_contents` extern, `CommitContentsRequest` / `CommitContents` wire, Dart `RepoHandle.commitContents`. The topology's wire and Dart view are Story 4.12.

## Boundaries & Constraints

**Always:**
- **Decisions are taken** (`decisions-review-4-10-to-4-13.md` § 4.10, Ralph: recommended option, else status quo): OQ1 = (b) `with_timestamps` flag, loaded per call, no handle state · OQ2 = committer timestamp · OQ3 = the content call is the CONTINUATION of the topology call's `jj log` · OQ4 = ADR-0002 Addendum for the pinned read only · OQ5 = new `jj.operation_not_found`, CLI text `No operation ID matching "<id>"` · OQ6 = `anchors` is a required pass-through list; zanshin_core exports the pre-fill `['trunk()', 'present(@)']`. 2026-09-28 design update: the object half carries the FULL description, no stats fields.
- **CLI parity at v0.44.0 (NFR-R-2, ADR-0003).** Topology = the CLI's one `jj log` (`cli/src/commands/log.rs`): same parse order and diagnostics as `walk_graph`, same `TopoGroupedGraph` + `prioritize_branch` pipeline, precondition exactly once through `Repo::with_verb`. Content = the per-row `get_commit_async` of that same `jj log`: no precondition, snapshot, import, config load or 9.37 fix-up; writes no operation and no op head; leaves `take_precondition()` / `take_warnings()` untouched; its envelope carries NO `precondition` and NO `warnings` (ok and error arms alike).
- **Pass-throughs (FR-JJ-17):** `revset`, `prioritize`, `short_prefixes`, `anchors`, `with_timestamps` are caller arguments; Rust bakes in no default for any of them.
- **Index-only per node.** Change ids come from ONE `Revset::commit_change_ids()` pass into a commit → change map; `parent_count` from `ParentCount` filter passes; `all_count` by iterating `all()`'s stream. Per-call loads (`trunk()`'s ≤ 7 `latest` candidates, a filter alias) are fine. NEVER `Revset::count_estimate` (jj-lib's `testing` feature, on in zanshin-jj's dev-deps, makes it return 10).
- **Edges are jj facts, verbatim:** Direct / Indirect / Missing in `TopoGroupedGraph` stream order; repeated targets kept; a Missing edge has no target; a Direct/Indirect target outside the node set is `RevsetError::DanglingEdge` (4.12 maps it to `graph.dangling_edge`). No synthetic "(elided revisions)" nodes and no `synthetic_elided` parameter.
- **The slice path is untouched:** `walk_graph`, `stream_lanes`, `collect_lanes`, `zanshin_graph_slice` keep their signatures, their per-row commit load and their rows; `crates/zanshin-jj/tests/{graph,warnings}.rs`, `crates/zanshin-graph/tests/*`, `crates/zanshin-ffi/tests/graph_ffi.rs` pass WITHOUT edits. The only compile-forced touch is the new `DanglingEdge` arm in the three exhaustive `RevsetError` mappers.
- **One extraction path per half.** `LogMetaIndex` is split into a view-half and an object-half extractor; `walk_graph`'s `CommitMeta` is composed from both (values unchanged), `graph_topology` uses the view half, `commit_contents` the object half.
- **Null for absence;** the Dart decoder throws on a missing required field (no `?? ''`). Interior-NUL guards on the operation id and every commit id, Dart-side at both layers (Rust does not re-check — `docs/ffi-abi.md` § Interior NUL).
- **Error taxonomy:** `jj.operation_not_found` enters `docs/rust-error-codes.md` and `crates/zanshin-ffi/src/envelope.rs` in the same change; ids go in `context`.
- **Transport (ADR-0001):** `schemas/envelope.fbs` edited in place; `RequestKind.CommitContents` and `Payload.CommitContents` APPENDED; `cargo make codegen` regenerates all four generated files (never by hand); `EXPECTED_EXPORTS` 60 → 61.
- **Quality bar:** clippy pedantic refactor-not-suppress (the WHY'd `struct_excessive_bools` allow on `CommitMeta` is the only accepted precedent), rustfmt, SPDX first line, `# Errors`/`# Safety` rustdoc, no `unwrap`/`expect`/`panic!` in library paths, scenario-named tests, no `#[ignore]`/`skip:`, no timing assertions; `dart analyze` + `dart format` clean.
- **Coverage ratchet:** new Rust files ≥ 80 %, no per-file drop, the new extern credited by a `packages/zanshin_core` real-cdylib test; commit the raised `coverage-baseline.txt`. Benches live in `benches/`, never in `src/`.
- **Repo conventions:** fixtures never regenerated (special cases built in-test with `test_helpers`); commits on `main` with `--no-gpg-sign` and the `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` trailer; `epic-4-context.md` edited LAST so it stays newer than every planning artifact; `sprint-status.yaml`: only the `4-10-…` status value + `last_updated`, never `sprint_plan.py generate`.

**Never:**
- No topology wire, lazy Dart view or id → index lookups (4.12); no layout, priority classes or repeated-target normalisation (4.11); no elided count; no row-range API; no `--limit`/`--reversed`; no detail-panel data (parents/diff stay `show`); no stats fields.
- No Rust state across calls: no timestamp cache, no memoised pinned `ReadonlyRepo`, no `Arc<Mutex>`.
- No operation-id prefix resolution and no `op_walk::resolve_op_for_load` (it resolves `@` against op heads).
- No Flutter UI (`app/lib` untouched); no `jj_lib` import outside `zanshin-jj` / `test-helpers`; no shelling to `jj` (the bench may shell to `git gc` for its packed copy, fixture-setup style).
- No new crate (`Makefile.toml` asserts exactly 8 `Cargo.toml` files); no lowered baseline, no `exclude_prefix`, no `EXTERN_COV_ALLOW` addition.

## I/O & Edge-Case Matrix

Fixture facts: **tiny-3-commits** — `all()` in `jj log` order is `[@, c3, c2, c1, root]` (`@` → root, root ← c1 ← c2 ← c3; descriptions `Commit 1/2/3`), loose git objects, no remote bookmarks, so `trunk()` = root. **medium-1k-commits** — 1002 nodes, exactly one octopus merge (3 parents), every `all()` edge Direct.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Topology happy path | tiny, `all()`, `present(@)`, `DEFAULT_LOG_REVSET`, anchors `[trunk(), present(@)]`, no timestamps | nodes/ids/edges == `walk_graph` verbatim; `parent_count` @/c*=1, root=0; anchors `[[4],[0]]`; `all_count` 5; every timestamp `None`; `operation_id` == the single op head after the call | — |
| Timestamps on | same, `with_timestamps = true` | every non-root node carries its committer timestamp (epoch ms) == the oracle's; root `None` | — |
| Octopus | medium, `all()` | 1002 nodes; the merge has `parent_count` 3; all edges Direct; `all_count` 1002 | — |
| Narrowed revset | tiny, `@`, anchors `[trunk(), present(@)]` | 1 node; `all_count` 5 (≠ node count); anchors `[[], [0]]` | — |
| Empty anchors / empty revset | anchors `[]`; revset `none()` | `anchors == []`; `nodes == []`, `all_count` 5 | — |
| Bad anchor | anchor `(` / `nosuchbookmark` | — | `RevsetError::ParseError` (before any load) / `ResolutionError` |
| Repeated target | in-test merge M(A, B), B a child of A, revset `all() ~ B` | M carries a Direct AND an Indirect edge to A's index, both kept, == `walk_graph` | — |
| WC edit before topology | file written into the workspace | precondition snapshots once; `operation_id` == the new head (≠ the pre-call head); `take_precondition()` is `Some` | — |
| Removed git object | c2's loose commit object deleted after open | topology without timestamps `Ok`; with timestamps `JjLibError` | propagated |
| Content happy path | head op id, ids `[c3, root, @]` | 3 entries in REQUEST order, each: commit id, author name/email, committer timestamp (millis + tz), FULL description, conflict, empty == oracle | — |
| Content, empty list | valid op id, `[]` | `Ok([])` | — |
| Bad op id | `""`, `"xyz"` | — | `InvalidInput`, text `Operation ID "xyz" is not a valid hexadecimal prefix` → `jj.invalid_input` |
| Op id not full | 12-hex prefix of head, odd-length hex | — | `InvalidInput` (full ids only, no prefix resolution) → `jj.invalid_input` |
| Vanished op | unknown 128-hex id; a real older op whose `op_store/operations/<id>` file was deleted | — | `OperationNotFound` → `jj.operation_not_found`, context `No operation ID matching "<id>"` |
| Bad commit id | `""`, `"zz"`, a 12-hex prefix of a real id | — | `InvalidInput` → `jj.invalid_input` |
| Unindexed commit id | 40-hex absent from the pinned index, incl. a commit created AFTER the pinned op | — | `CommitNotFound` → `jj.change_not_found`, context = the hex |
| Check order | bad op id + malformed commit id; `[unindexed, malformed]` | op-id error wins; the malformed id wins over the unindexed one (all ids are validated before any load) | as above |
| Removed git object (content) | c2's object deleted | content(c2) and content(c3) (c3's `empty` loads parent c2) both fail; the index still has both | `Backend` → `jj.jj_lib_error` |
| Pinned read writes nothing | WC edit + an external commit that moves head, after a topology call | content at the old op: op heads + operation files unchanged, `take_precondition()` stays `None`, values unchanged; the next topology call snapshots and sees both changes | — |
| Divergent op heads | heads dir holds h0 (ancestor) + h1 | content at h1 leaves both markers (no prune, no reconcile merge) | — |
| FFI ladder | null data; wrong/absent kind; zero handle with a valid buffer; absent `operation_id`; NUL inside a Rust-built id | `ffi.null_pointer`; `ffi.invalid_argument` (`request kind mismatch: expected CommitContents, got …`, before the handle); `ffi.invalid_handle`; `jj.invalid_input` (`operation_id is required`); `jj.invalid_input` (not hex) — NO precondition, NO warnings on any envelope | no deref |
| Dart | NUL in op/commit id; closed handle; synthetic payload missing a required string | `ArgumentError` (calling side); `StateError`; `ZanshinFfiException('ffi.unknown', …)` | — |

</intent-contract>

## Code Map

**zanshin-jj (sole `jj_lib` importer)**
- `crates/zanshin-jj/src/graph.rs` -- `walk_graph` (`:173-241`): factor steps 1-5 (config + `revset_config`, `immutable_expression`, `short` via `parse_diagnosed`, `log`/`prio` via `parse_revset_with` + `.intersection`, `load_at_head`, `evaluate_revset`, prio ids, prefix context, `TopoGroupedGraph` + `prioritize_branch`) into a private shared helper; `walk_graph` keeps its signature, loop and per-row load. `short_prefix_index` (`:118`), `prefix_context` (`:142`), `edge_kind` (`:81`), `DEFAULT_GRAPH_PRIORITIZE` stay. Lifetimes: `Revset::stream_graph<'a>(&self)` does not borrow `&self`, only `'r` of the repo, so a helper taking `&'r dyn Repo` can return the topo graph.
- `crates/zanshin-jj/src/commit_meta.rs` -- `LogMetaIndex::extract` (`:161-213`): split into a view-half extractor (commit id + change id in → `change_id` reverse-hex, both prefix lens, `change_offset`/`hidden`/`divergent` from `resolve_change_id(change_id)`, `immutable` from the containing fn, `bookmarks`/`tags`/`working_copies`/`working_copy`, `root`; NO `Commit` needed) and an object-half extractor (`Commit` + repo → author name/email, committer `Timestamp`, `conflict` = `has_conflict()`, `empty` = `is_empty(repo_dyn)`, full `description`); `extract` composes them (`description_first_line` = first line of the full description, exactly `:211`'s rule). The `jj(...)` mapper and `prefix_len` stay.
- `crates/zanshin-jj/src/topology.rs` (**NEW**) -- public `GraphTopology { operation_id: OperationId, nodes: Vec<TopologyNode>, anchors: Vec<Vec<usize>>, all_count: usize }`, `TopologyNode { commit_id: CommitId, edges: Vec<TopologyEdge>, meta: TopologyMeta, committer_timestamp_ms: Option<i64> }`, `TopologyEdge { target: Option<usize>, kind: GraphEdgeKind }` (`None` iff Missing), `TopologyMeta` = the view half + `parent_count: u32` (bools → the `CommitMeta` WHY'd allow). `pub(crate) fn graph_topology(repo, sink, revset, prioritize, short_prefixes, anchors, with_timestamps)`. Pass list: (1) shared parse + each anchor parsed with the same `RevsetConfig` via `parse_revset_with` and `.intersection(&log)` — all BEFORE `load_at_head`; (2) shared load/evaluate; `operation_id` = `readonly.op_id().hex()`; (3) one `set.commit_change_ids()` pass → map; (4) `parent_count`: resolve `log` ONCE (`revset::resolve_expression`), evaluate `resolved.filtered(RevsetFilterPredicate::ParentCount(2..u32::MAX))` → the merge set; refine with `ResolvedRevsetExpression::commits(prev).filtered(ParentCount(k..u32::MAX))` for k = 3, 4, … until empty; root 0, else 1; (5) drive `topo.stream()`: per node the view half (change id from the map), plus — iff `with_timestamps` and not root — `store.get_commit_async` → `committer().timestamp.timestamp.0`; (6) resolve targets after the pass through a commit id → index map (pure helper, unit-testable; a miss is `DanglingEdge`); (7) each anchor evaluated once, its ids mapped to node indices, sorted ascending (= `jj log` order); (8) `all_count` = count of `ResolvedRevsetExpression::all().evaluate(repo_dyn)?.stream()`. Inline `#[cfg(test)]` for the pure helpers.
- `crates/zanshin-jj/src/commit_content.rs` (**NEW**) -- public `CommitContent { commit_id: CommitId, author_name, author_email, committer_timestamp: Timestamp, description, conflict, empty }` and `CommitContentError { InvalidInput(String), OperationNotFound(String), CommitNotFound(String), Backend(String) }` (`thiserror`; Display of `OperationNotFound(id)` is exactly `No operation ID matching "{id}"`). `pub(crate) fn commit_contents(workspace, operation_id, commit_ids)`: (a) op id: empty or any non-hex char → `Operation ID "<x>" is not a valid hexadecimal prefix` (jj-lib `op_walk.rs:79-81` text); all-hex but not the op store's full length (`op_store().root_operation_id()` byte length × 2 = 128) → a Zanshin "not a full operation ID" text; (b) `OperationId::try_from_hex` → `repo_loader().load_operation` (async → pollster): `OpStoreError::ObjectNotFound` → `OperationNotFound`, else `Backend`; then `load_at(&op)` → `Backend` on error; (c) FIRST pass over all ids: empty/non-hex/≠ `store.commit_id_length()`×2 → `InvalidInput`; then `index().has_id` false → `CommitNotFound(hex)` (an index error → `Backend`); (d) SECOND pass: `store.get_commit_async` + the object-half extractor → `Backend` on failure; output in request order. Uppercase hex is accepted (jj-lib's decoder accepts it).
- `crates/zanshin-jj/src/revset.rs` -- `RevsetError` (`:37-63`) gains `DanglingEdge { target: String }` (Display names the target hex). Exhaustive mappers to update: `crates/zanshin-jj/src/commit_views.rs:223-229` and `crates/zanshin-jj/src/mutate.rs:384-388` (→ their `Backend` with the Display text) + their inline mapper tests (`commit_views.rs:~594-615`, `mutate.rs:~1526-1543`).
- `crates/zanshin-jj/src/repo.rs` -- ADD `pub fn graph_topology(&mut self, revset: &str, prioritize: &str, short_prefixes: &str, anchors: &[String], with_timestamps: bool) -> Result<crate::GraphTopology, crate::RevsetError>` via `self.with_verb(|repo, ctx| crate::topology::graph_topology(repo, &mut ctx.warnings, …))` (model: `walk_graph` `:778-788`) and `pub fn commit_contents(&self, operation_id: &crate::OperationId, commit_ids: &[crate::CommitId]) -> Result<Vec<crate::CommitContent>, crate::CommitContentError>` (model: `log_defaults` `:548`, a `&self` delegator). Dated note on `Repo`'s doc `:117-119` ("re-resolves to the operation-log head on every call") pointing at the ADR-0002 Addendum for `commit_contents`; add `commit_contents` to the "verbs that do not snapshot" lists in `take_precondition` (`:375-380`) and `take_warnings` (`:386-398`).
- `crates/zanshin-jj/src/lib.rs` -- `pub(crate) mod commit_content; pub(crate) mod topology;` in the alphabetical block; `pub use commit_content::{CommitContent, CommitContentError};` `pub use topology::{GraphTopology, TopologyEdge, TopologyMeta, TopologyNode};` (`#![deny(missing_docs)]`).
- `crates/zanshin-jj/README.md` -- after `## Graph stream (Repo::walk_graph)` (`:86`), a short section for the topology + pinned content split.
- `crates/zanshin-jj/benches/graph_blueprint.rs` -- relabel `:18-19` as the TOPOLOGY-only walk (index-only) and add two raw jj-lib timings: the `all()` count pass and the `ParentCount` passes (the story's pass-level numbers).

**zanshin-jj tests**
- `crates/zanshin-jj/tests/graph_topology.rs` (**NEW**; env pin copied from `tests/graph.rs:25-39`) -- topology rows of the matrix; split equivalence (tiny + medium): `TopologyMeta` + `commit_contents(op, all ids)` recompose `walk_graph`'s `CommitMeta` for every node, plus the independent `eval_revset("all()")` `Change` oracle (commit id, author email, committer timestamp, full description, `parents.len()` == `parent_count`); the repeated-target case (`test_helpers::add_commit_with_files(root, &[a, b], …)`, parents are arbitrary hex); the removed-object case (delete `.jj/repo/store/git/objects/<2>/<38>` of c2 AFTER open — loose objects; find c2 via an oracle handle or its position); op-id-after-precondition.
- `crates/zanshin-jj/tests/commit_contents.rs` (**NEW**) -- the content ladder rows, request order, empty list, the vanished-op file deletion, pinned-reads-write-nothing (compare directory listings of `.jj/repo/op_heads/heads/` and `.jj/repo/op_store/operations/` — NOT `op_log`, which snapshots), divergent op heads (hand-written head markers, precedent `tests/op_log.rs:509-545`), the removed-object content rows. External writes via `test_helpers::{add_commit_off_root, describe_commit}`.
- `crates/zanshin-jj/tests/api_stability.rs` -- type aliases for the 6 new types; a new test `graph_topology_surface_resolves` (pattern `content_ops_surface_resolves` `:536-557`) pinning every field, every `CommitContentError` variant, `RevsetError::DanglingEdge`, and both methods as `fn` pointers.

**zanshin-ffi + wire**
- `schemas/envelope.fbs` -- append `CommitContents` to `RequestKind` (`:70-100`) and bump the doc's "other 26 tables" (`:62`) to 27; add `table CommitContentsRequest { kind: RequestKind; operation_id: string; commit_ids: [string]; }` after `EnvironmentAdoptRequest` (`:507-510`); add `table CommitContent { commit_id; author_name; author_email; committer_timestamp_millis: long; committer_tz_offset_minutes: int; description; conflict: bool; empty: bool; }` + `table CommitContents { contents: [CommitContent]; }` (field names mirror `GraphRowMeta` `:765-786`); append `CommitContents` to `union Payload` (`:1366-1403`); changelog line `Story 4-10 : CommitContents ✓` (`:512-540`); add `zanshin_commit_contents` to the `Envelope` doc's no-precondition list (`:1429-1439`).
- `crates/zanshin-ffi/src/commit_contents.rs` (**NEW**; template `workspace.rs`'s `zanshin_workspace_root` `:60-83`, `:118-132`, `:179-232`) -- `read_commit_contents_request` (null → verify → `expect_request_kind(…, CommitContents)` → owned struct; absent `operation_id` → `missing_field("operation_id")`), `map_commit_content_err` (InvalidInput → `JJ_INVALID_INPUT`; OperationNotFound → `JJ_OPERATION_NOT_FOUND` with the Display text; CommitNotFound → `JJ_CHANGE_NOT_FOUND` with the hex; Backend → `JJ_JJ_LIB_ERROR`; all `report: None`), `commit_contents_to_envelope(&[CommitContent])` with `CallReport::default()`, and `#[no_mangle] pub unsafe extern "C" fn zanshin_commit_contents(handle: u64, data: *const u8, len: usize) -> *mut ZanshinBuf` (request read BEFORE `session_from_handle`; `catch` + `vec_into_token`). `# Errors` bullets exactly: `ffi.invalid_handle`, `ffi.null_pointer`, `ffi.invalid_argument`, `jj.invalid_input`, `jj.operation_not_found`, `jj.change_not_found`, `jj.jj_lib_error`. Inline tests: builder round-trip through `flatbuffers::root::<fbs::Envelope>` + typed accessors (no precondition, no warnings), the mapper per variant.
- `crates/zanshin-ffi/src/envelope.rs` -- `pub const JJ_OPERATION_NOT_FOUND: &str = "jj.operation_not_found";` inside the error-code block (`:31-184`, e.g. after `JJ_CHANGE_NOT_FOUND` `:58`), NOT in the warning block (`:194-256`).
- `crates/zanshin-ffi/src/lib.rs` -- `pub mod commit_contents;` between `change` (`:34`) and `commit_views` (`:35`).
- `crates/zanshin-ffi/src/graph.rs` -- `map_lane_stream_err` (`:32-61`): arm `Revset(RevsetError::DanglingEdge { target })` → `GRAPH_DANGLING_EDGE`; one row in `map_lane_stream_err_maps_every_variant` (`:741-768`).
- `crates/zanshin-ffi/src/repo.rs` -- dated note after `:694-695` ("reads re-resolve to head") pointing at the ADR-0002 Addendum; regenerate the header (`include/zanshin_ffi.h:1893-1894`).
- `crates/zanshin-ffi/tests/commit_contents_ffi.rs` (**NEW**; helpers from `tests/log_defaults_ffi.rs:33-87` and request builders like `tests/workspace_ffi.rs:108-120`) -- happy path on tiny (head op id from `op_heads/heads/` or `zanshin_op_log`), the ladder incl. a `KindCase` table (`workspace_ffi.rs:481-557`), `jj.operation_not_found` / `jj.change_not_found` contexts, and `precondition().is_none()` + `warnings().is_none()` on ok AND error envelopes.
- `crates/zanshin-ffi/tests/snapshot_ffi.rs` -- add `zanshin_commit_contents` to `symbols_that_run_no_precondition_never_carry_the_field` (`:830-875`).
- `crates/zanshin-ffi/tests/ffi_abi_doc_sync.rs` -- `EXPECTED_EXPORTS` 60 → 61 (`:37`).
- `crates/zanshin-ffi/benches/graph_topology.rs` (**NEW**) + `crates/zanshin-ffi/Cargo.toml` `[[bench]] name = "graph_topology" harness = false` with a `# WHY:` (pattern `crates/zanshin-jj/Cargo.toml:38-52`) -- `measure` helper like `graph_blueprint.rs:67-80`; stores: `medium` + `large-10k` as committed (loose) and a packed copy of `large-10k` (`git --git-dir=<tmp>/.jj/repo/store/git -c gc.pruneExpire=never gc --quiet`); timings: `graph_topology` (default anchors) total, `Repo::snapshot()` on the unchanged tree (= the precondition share), anchors `[]` vs default (anchor share), with timestamps; `zanshin_commit_contents` pages of 60 and 200 ids with and without the octopus merge, with and without a changed-path index; an EMPTY-list content call (= the `load_operation` + `load_at` share); topology + contents for every id. Prints node counts + min/median only.
- `crates/test-helpers/src/lib.rs` -- ADD `pub fn build_changed_path_index(root: &Path)` (load at head; `index_store().downcast_ref::<jj_lib::default_index::DefaultIndexStore>()`; `build_changed_path_index_at_operation(op_id, store, u32::MAX, |_| {})`, jj-lib `default_index/store.rs:353`) for the bench.

**Dart bridge (`packages/zanshin_core`)**
- `lib/src/ffi/commit_contents.dart` (**NEW**; template `lib/src/ffi/workspace.dart:3-12`, `:50-57`, `:132-161`, list precedent `bookmark_ops.dart:61-66`) -- adapter `Uint8List zanshinCommitContents(int rawHandle, {required String operationId, required List<String> commitIds})` (`rejectInteriorNul` / `rejectInteriorNuls`, `fbs.CommitContentsRequestObjectBuilder(kind: fbs.RequestKind.CommitContents, …)`, `callWithRequest`); `final class CommitContent` (commitId, authorName, authorEmail, committerTimestampMillis, committerTzOffsetMinutes, description, conflict, empty); `@visibleForTesting decodeCommitContentsEnvelope` + `…Internal` → `WarnedList<CommitContent>` (Story 9.32's "every result exposes `warnings`" convention; always empty here); a missing string → `ZanshinFfiException('ffi.unknown', '<Table> is missing its <field>')` (precedent `workspace.dart:144-150`).
- `lib/src/ffi/graph.dart` -- `const List<String> defaultGraphAnchors = ['trunk()', 'present(@)'];` with a doc comment beside `defaultGraphPrioritize` (`:22-69`): the editable pre-fill for `graph_topology`'s required `anchors` (4.11's priority rule), not applied by anything. Not added to the barrel (its siblings are not; 10.12 exports the 4.10-4.12 types).
- `lib/src/worker/commands.dart` -- `CommitContentsCommand({required super.commandId, required this.handleId, required this.operationId, required this.commitIds})` implementing `HandleScopedCommand` (template `WorkspaceRootCommand` `:784-805`).
- `lib/src/worker/isolate.dart` -- aliased import (`:11-43`), dispatch arm (template `:2131-2140`), `ZanshinWorker.commitContents(int handleId, {required String operationId, required List<String> commitIds})` → `Future<WarnedList<CommitContent>>` with calling-side NUL guards before `send` (template `workspaceRoot` `:1288-1321`, `bookmarkCreate` `:1355-1356`).
- `lib/src/worker/handle.dart` -- `RepoHandle.commitContents({required String operationId, required List<String> commitIds})` with the `_closed` `StateError` guard (template `logDefaults` `:202-220`); a line in the class doc (`:60-61`) naming it among the verbs without precondition.
- `test/ffi/commit_contents_test.dart` (**NEW**; template `test/ffi/workspace_test.dart`) -- error envelope, wrong payload, full field equality, absent warnings → `[]`, each missing required string → `ffi.unknown`, adapter NUL guard with raw handle 0. `test/ffi/graph_test.dart` -- pin `defaultGraphAnchors`.
- `test/worker/commit_contents_test.dart` (**NEW**; template `test/worker/workspace_test.dart:52-63`) -- real cdylib: `initRepo` temp dir, op id via `handle.opLog(limit: 1)` (helper precedent `test/worker/file_ops_test.dart:31-34`), commit ids via `status()` → `getChange(...).commitId` and `graphSlice(revset: 'all()')`; round trip in request order; `jj.operation_not_found`, `jj.invalid_input`, `jj.change_not_found` as `ZanshinFfiException`; `ArgumentError` for NULs; `StateError` after close; `handle.lastPrecondition` unchanged by the call. THIS test credits the extern in the coverage guard (`Makefile.toml:562-589`).

**Docs, planning, tracking**
- `docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md` -- `## Addendum 2026-09-30 — the op-pinned content read (Story 4.10)` after the 2026-09-23 one (`:98-102`), before `## References`: a read that answers at a caller-supplied operation is pinned, not re-resolved, and returns commit-intrinsic values only; `load_at` writes no operation/op head (it may write index files); second paragraph: the ~3.1 ms / ~27 µs figures at `:3`, `:40`, `:89`, `:95` time the index-only topology walk, and since Story 4.8 the full row costs the commit loads — the re-measured numbers. Accepted text unchanged; a dated pointer at AD-2 `:87`.
- `docs/rust-error-codes.md` -- new row `jj.operation_not_found` after `:80` (note: unrelated to the `operation_not_found` CAUSE string inside `jj.stale_working_copy`'s context); "also emitted — Story 4.10 by `zanshin_commit_contents`" clauses on `jj.invalid_input` (`:65`), `jj.change_not_found` (`:48`), `jj.jj_lib_error` (`:45`), `ffi.invalid_handle`/`ffi.null_pointer`/`ffi.invalid_argument` (`:40`, `:41`, `:46`, counts twenty-eight → twenty-nine).
- `docs/ffi-abi.md` -- symbol-index row after `zanshin_graph_slice` (`:461`; codes = the header `# Errors` bullets exactly); count `**60**` → `**61**` (`:432`); "twenty-eight" (`:263`, `:325`), "**27** request tables" / "27 tables + 1 shared reuse = the 28" (`:358`, `:367`), "For 26 tables" (`:387`) bumped; the no-precondition lists (`:116-117` and the warnings section); "Four symbols … keep a prose section" (`:535-538`) → five, plus a section `## CommitContents payload and zanshin_commit_contents (Story 4.10)` at the end (shape of `:1103-1180`: prototype, the pinned-read framing, check order, request order, no precondition/warnings); dated note at "exactly ONE graph function" (`:885-890`).
- `_bmad-output/project-context.md` -- dated notes at `:232-233` (pinned read → ADR-0002 Addendum), `:13` and `:694-699` (the ~3 ms / ~27 µs are topology-only; point at the re-measured numbers). `:14` already names Story 4.10 — verify only.
- `_bmad-output/planning-artifacts/architecture.md:444` -- dated note on "~3 ms full graph derive": topology-only.
- `_bmad-output/planning-artifacts/epics.md` -- dated notes at Story 4.8's user story (`:3225`) and first AC (`:3241`): the commit-graph view renders from the topology call plus the op-pinned content call (Stories 4.10–4.12); the slice keeps its one-call rows until 4.12. A dated `**Delivered (2026-09-30, Story 4.10 done):**` note at the end of § Story 4.10 (before `### Story 4.11`). `prd.md:237` / `:312` already point at Story 4.10 — verify only.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- dated note on `:394` (the precondition-share numbers answer its graph half); new section "Surfaced in Story 4.10 (bmad-build-auto, 2026-09-30)" mirroring every spec deferral.
- `_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md` -- under `## Taken during the runs` add `### 4.10` with the decisions in Design Notes § Taken during this run.
- `_bmad-output/implementation-artifacts/sprint-status.yaml:50` -- status value only (+ `last_updated`), keep the comment.
- `_bmad-output/implementation-artifacts/epic-4-context.md` -- 4.10 → done, one line; edit LAST.
- `coverage-baseline.txt` -- raised in place by the gate; commit it.

## Tasks & Acceptance

**Execution:**
- [x] `crates/zanshin-jj/src/{revset,commit_meta,graph}.rs` + `commit_views.rs`/`mutate.rs` mappers -- `DanglingEdge` variant; split `LogMetaIndex::extract` into the two halves; factor `walk_graph`'s setup into the shared helper -- one extraction path per half, slice path unchanged.
- [x] `crates/zanshin-jj/src/topology.rs` (new) -- the topology types + `graph_topology` passes (1)-(8) + inline unit tests of the pure helpers (target resolution incl. the dangling miss, anchor index mapping, parent-count refinement bookkeeping) -- item 1-4.
- [x] `crates/zanshin-jj/src/commit_content.rs` (new) -- `CommitContent`, `CommitContentError`, `commit_contents` with the (a)-(d) ladder, two passes over the ids; inline unit tests of the id classifiers -- items 5-6.
- [x] `crates/zanshin-jj/src/{repo,lib}.rs`, `README.md` -- the two `Repo` methods, exports, docs -- surface.
- [x] `crates/zanshin-jj/tests/{graph_topology,commit_contents}.rs` (new) + `api_stability.rs` -- every zanshin-jj row of the I/O matrix, split equivalence, API pins.
- [x] `schemas/envelope.fbs` then `cargo make codegen` -- request table, payload tables, appended enum/union members, doc lines; commit the four regenerated files -- wire.
- [x] `crates/zanshin-ffi/src/{commit_contents,envelope,lib,graph,repo}.rs` -- extern + reader + builder + mapper + constant + the `DanglingEdge` arm + the dated note -- content call over FFI.
- [x] `crates/zanshin-ffi/tests/{commit_contents_ffi,snapshot_ffi,ffi_abi_doc_sync}.rs` -- the FFI ladder, no-precondition list, export count.
- [x] `packages/zanshin_core/lib/src/{ffi/commit_contents,ffi/graph,worker/commands,worker/isolate,worker/handle}.dart` + `test/{ffi,worker}/commit_contents_test.dart` + `test/ffi/graph_test.dart` -- Dart content call, anchors pre-fill, decode-contract + real-cdylib tests.
- [x] `crates/test-helpers/src/lib.rs`, `crates/zanshin-ffi/{Cargo.toml,benches/graph_topology.rs}`, `crates/zanshin-jj/benches/graph_blueprint.rs` -- bench; run `cargo bench -p zanshin-ffi --bench graph_topology` and `cargo bench -p zanshin-jj --bench graph_blueprint -- --large`; record every number with its store kind in Design Notes § Measurements (created then) -- item 8.
- [x] `docs/{adr/0002-…,rust-error-codes,ffi-abi}.md`, `_bmad-output/{project-context.md,planning-artifacts/architecture.md,planning-artifacts/epics.md}`, `deferred-work.md`, `decisions-review-4-10-to-4-13.md` -- Addendum, registry, ABI doc, dated notes with the measured numbers, decisions -- items 8-9.
- [x] run `cargo make test` synchronously, unpiped (exit code read directly) -- fix by refactoring/adding tests; commit the raised baseline; then `sprint-status.yaml` + `epic-4-context.md` (LAST) and commit -- definition of done.

**Acceptance Criteria:**
- Given any fixture and revset, when `Repo::graph_topology` is called, then its node ids, order and edges (kinds, order, repeated targets, Missing without target) equal `walk_graph`'s stream for the same `revset`/`prioritize`/`short_prefixes`, and every `TopologyMeta` field plus the matching `commit_contents` entry at the returned `operation_id` recompose `walk_graph`'s `CommitMeta` exactly (`description_first_line` = first line of `description`).
- Given the finished tree, when `crates/zanshin-jj/tests/{graph,warnings}.rs`, `crates/zanshin-graph/tests/*` and `crates/zanshin-ffi/tests/graph_ffi.rs` run, then they pass and `git diff <baseline> -- <those paths>` is empty.
- Given a Dart `RepoHandle` on a fresh repo, when `commitContents(operationId: <head op>, commitIds: [@, root])` is called through the real cdylib, then it returns two `CommitContent`s in request order with the full description, `lastPrecondition` is unchanged and the result's `warnings` is empty; with an unknown full op id it throws `ZanshinFfiException` with code `jj.operation_not_found` and context `No operation ID matching "<id>"`.
- Given `zanshin_commit_contents` on any path (ok, refusal, jj error), when its envelope is read with the typed accessors, then `precondition()` and `warnings()` are absent.
- Given the finished tree, when `cargo make codegen` has run and `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` and `coverage-check: OK`, both new zanshin-jj files and the new zanshin-ffi file ≥ 80 %, no per-file regression, and `git status` is clean after the commit(s).

## Spec Change Log

## Review Triage Log

## Design Notes

- **Split names.** View half `TopologyMeta` (avoids `CommitView*`, which `commit_views.rs` uses), object half `CommitContent`, node `TopologyNode`, edge `TopologyEdge`, result `GraphTopology`. `CommitContent` carries its own `commit_id`: rows stay self-describing for 10.11's commit-id cache even though the order is the request order.
- **Topology timestamps are epoch ms only** (`Option<i64>`): the layout needs the instant; day buckets use a fixed per-layout UTC offset (4.11 D7). `None` = not requested, or the root. The content half keeps the full `Timestamp` (millis + tz) that `jj log` shows.
- **Why two passes in `commit_contents`.** Validating every id (format, then `has_id`) before the first load gives a deterministic ladder: a malformed id is `jj.invalid_input` wherever it sits, and `jj.change_not_found` (id unknown to the pinned index) stays separate from `jj.jj_lib_error` (indexed but unloadable — `get_commit_async` answers `ObjectNotFound` for both, so the index check is the only separator).
- **Why the parent-count passes run on the resolved `log`, then on `commits(prev)`.** `ParentCount` reads the index entry (`default_index/revset_engine.rs:1303-1308`); intersecting it with the revset yields exactly the merge nodes, and each refinement tests only the previous set. A bare `filter(…)` would test every visible commit per pass. Resolving `log` once avoids re-resolving symbols per pass.
- **Why `RevsetError::DanglingEdge`** rather than folding the miss into `JjLibError`: 4.12 maps the topology's errors to FFI codes and must emit `graph.dangling_edge` as the slice path does; the case is unreachable through jj-lib (targets always arrive later in the stream), so it is covered by a unit test of the pure resolution helper.
- **Why new test files** instead of appending to `tests/graph.rs`: the story requires the slice path's tests to pass WITHOUT edits; separate binaries make that a clean `git diff` check.
- **Anchors** are intersected with `log` as USER expressions before resolution (like `prioritize`, `graph.rs:198`), so an anchor outside the revset selects nothing instead of failing, and `trunk()` follows the user's `[revset-aliases]` (Story 4.9).
- **Dart returns `WarnedList<CommitContent>`** although Rust never sends warnings for this verb: Story 9.32 made `warnings` part of every `ZanshinWorker` / `RepoHandle` result (`logDefaults` / `workspaceRoot` carry it too); the wire rule (absent) is unchanged.

### Taken during this run (also appended to `decisions-review-4-10-to-4-13.md` § Taken during the runs → 4.10)
- **Not-a-full-id texts.** The CLI resolves prefixes, so it has no text for "valid hex, wrong length"; Zanshin uses its own `Operation ID "<x>" is not a full operation ID` / `Commit ID "<x>" is not a full commit ID` (both `jj.invalid_input`), keeping the CLI's `… is not a valid hexadecimal prefix` for empty/non-hex operation ids — and, by the same wording, `Commit ID "<x>" is not a valid hexadecimal prefix` for an empty/non-hex commit id. Basis: status quo (no prefix resolution, per the story). If overruled: change the strings.
- **`RevsetError::DanglingEdge`** as a new public variant (see above). Basis: the story's "`graph.dangling_edge`, as in `walk_graph`". If overruled: fold into `JjLibError`, drop three mapper arms.
- **Option (c)'s trigger is measured, not acted on.** The first timestamped topology call is 53 ms at 10k packed (above the ~50 ms trigger) and ~1 s on the loose fixture; recorded for Ralph in `deferred-work.md` § "Surfaced in Story 4.10". Basis: OQ 1 = (b) stands until Ralph decides. If overruled: a follow-up story builds (c) or (d).

### Measurements

Release builds, jj-lib 0.44.0, this machine (Apple silicon), 2026-09-30; min / median over 5 runs after 1 warm-up (`crates/zanshin-ffi/benches/graph_topology.rs`), 7 / 21 runs for `crates/zanshin-jj/benches/graph_blueprint.rs`. "Loose" = the committed fixture (every git object loose); "packed" = a `git gc`-packed copy of `large-10k`. Content pages run on a FRESH handle each time (cold commit cache, the first page after a reload); the topology rows reuse one handle.

| Timing | medium (1,002 nodes) loose | large-10k (10,002) loose | large-10k packed |
|---|---|---|---|
| topology-only walk, raw jj-lib (`graph_blueprint`) | 0.31 ms (first-100: 30 µs) | 3.07 ms (first-100: 30 µs) | — |
| `all()` count pass / `ParentCount` passes, raw (`graph_blueprint`) | 29 µs / 10 µs (1 merge) | 290 µs / 82 µs (1 merge) | — |
| `graph_topology(all())`, default anchors — the call total | 5.9 / 6.0 ms | 25.4 / 25.5 ms | 22.3 / 22.4 ms |
| `Repo::snapshot()` on the unchanged tree (precondition share) | 2.3 / 2.4 ms | 2.3 / 2.5 ms | 2.4 / 2.5 ms |
| `graph_topology`, anchors `[]` (anchor share = difference) | 5.4 / 5.5 ms | 23.6 / 23.9 ms | 21.7 / 21.8 ms |
| `graph_topology` with timestamps | 102 / 111 ms | 1.031 / 1.050 s | 52.9 / 53.1 ms |
| content, EMPTY list (`load_operation` + `load_at` share) | 0.17 / 0.20 ms | 0.73 / 0.88 ms | 0.71 / 0.84 ms |
| content page 60 ids, no merge (no changed-path index) | 2.48 / 2.58 ms | 3.42 / 3.46 ms | 1.83 / 1.94 ms |
| content page 60 ids, 1 merge (no changed-path index) | 2.90 / 3.02 ms | 3.73 / 3.98 ms | 1.81 / 1.90 ms |
| content page 200 ids, no merge (no changed-path index) | 6.41 / 6.48 ms | 7.17 / 7.99 ms | 2.52 / 2.60 ms |
| content page 200 ids, 1 merge (no changed-path index) | 6.15 / 6.33 ms | 6.55 / 6.64 ms | 2.75 / 2.83 ms |
| content page 60 ids, no merge (changed-path index) | 2.56 / 2.61 ms | 3.77 / 4.09 ms | 1.38 / 1.56 ms |
| content page 60 ids, 1 merge (changed-path index) | 2.42 / 2.54 ms | 3.73 / 3.86 ms | 1.81 / 1.86 ms |
| content page 200 ids, no merge (changed-path index) | 6.82 / 7.58 ms | 8.08 / 9.15 ms | 2.51 / 2.66 ms |
| content page 200 ids, 1 merge (changed-path index) | 5.92 / 5.98 ms | 7.16 / 7.40 ms | 2.70 / 2.74 ms |
| topology + contents for every id (fresh handle) | 101 / 103 ms | 1.022 / 1.036 s | 58.2 / 58.5 ms |

Read-outs: the index-only topology walk is unchanged (3.1 ms / 30 µs at 10k); the whole topology call is 7× that at 10k, of which ~2.4 ms is the precondition and the rest the per-node view half (change-id resolution, two prefix lengths, immutable containment); anchors cost ~0.5–1.6 ms; timestamps cost ~31 ms packed and ~1 s loose at 10k; a content page's pinned load is 10–25 % of the page, so memoising the pinned repo stays unwarranted; the fixtures' one octopus merge merges tiny trees, so the changed-path index only saves parent loads here.

## Verification

**Commands:**
- `cargo make codegen` -- expected: `zanshin_ffi.h` + `bindings.dart` carry `zanshin_commit_contents`; `envelope_generated.rs` + `envelope_zanshin.ffi_generated.dart` carry the new tables and the appended members.
- `cargo test -p zanshin-jj --test graph_topology --test commit_contents --test api_stability`, `cargo test -p zanshin-ffi --test commit_contents_ffi --test snapshot_ffi --test ffi_abi_doc_sync` -- expected: green.
- `cargo bench -p zanshin-ffi --bench graph_topology` and `cargo bench -p zanshin-jj --bench graph_blueprint -- --large` -- expected: runs to completion; numbers recorded in § Measurements.
- `git diff 64ed3b32cc3d76e2ecfc75db1b8dbc1ceb5dd828 -- crates/zanshin-jj/tests/graph.rs crates/zanshin-jj/tests/warnings.rs crates/zanshin-graph crates/zanshin-ffi/tests/graph_ffi.rs app/lib` -- expected: empty.
- `cargo make test` (synchronous, unpiped; redirect to a file is fine, `| tail` is not) -- expected: exit 0, `extern-coverage: OK`, `coverage-check: OK`.
- `git status --porcelain` after the final commit -- expected: empty.

**Manual checks:**
- `grep -rn "count_estimate" crates/zanshin-jj/src` -- no hit in the new code.
- `_bmad-output/implementation-artifacts/epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/`.
