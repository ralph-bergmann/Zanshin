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
deferred:
  - summary: >-
      Option (c)'s trigger is met at 10k packed: the first timestamped topology call is 53 ms,
      above the ~50 ms the OQ 1 decision set for adopting a per-handle timestamp cache.
    evidence: |-
      crates/zanshin-ffi/benches/graph_topology.rs, medians, fresh handle:
      graph_topology(all(), with_timestamps) = 53.1 ms on large-10k packed (~31 ms of it are the
      commit loads), 105 ms on medium loose, ~1.04 s on large-10k loose. Zanshin never packs, so
      a repo only Zanshin writes accumulates loose commits. OQ 1 = (b) stands until Ralph picks
      (c) (commit id -> timestamp cache on zanshin_jj::Repo, ADR-0002 clause, bound) or (d)
      (a Dart-side cache in the worker), or accepts 53 ms. Mirrored in deferred-work.md
      "Surfaced in Story 4.10".
    location: >-
      crates/zanshin-jj/src/topology.rs (graph_topology, with_timestamps pass)
    severity: medium
  - summary: >-
      On a packed 10k store the pinned load_operation + load_at is about half of a 60-id
      content page; whether that "dominates" enough to memoise the pinned repo is Ralph's call.
    evidence: |-
      Empty-list content call vs page (medians, cold commit cache): ~8 % (medium loose),
      ~28 % (large loose), ~45 % (large packed; ~51 % with a changed-path index) of a 60-id page;
      ~3 / 12 / 33 % of a 200-id page. The story's Non-goal memoises only "if the bench shows
      load_operation + load_at dominating a page"; memoising adds handle state and an ADR-0002
      clause, or 10.11 pages in larger batches instead. Mirrored in deferred-work.md.
    location: >-
      crates/zanshin-jj/src/commit_content.rs (commit_contents, load_operation + load_at)
    severity: low
  - summary: >-
      No real-repo bench numbers: the optional local real-repo input (item 8) needs a path to
      one of Ralph's repos.
    evidence: |-
      The dispatch skipped item 8's real-repo input (no path given). The bench covers medium,
      large-10k loose and a git-gc-packed copy of large-10k only. Run it against a COPY of a
      real repo (the topology call snapshots). Mirrored in deferred-work.md.
    location: >-
      crates/zanshin-ffi/benches/graph_topology.rs
    severity: low
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

### 2026-10-01 — Review pass
- verdicts: 33 findings — high 0, medium 0, low 26, false 7, maybe-false 0
- findings:
  - `[low]` `[patch]` (Blind Hunter) The Measurements read-out and the deferred-work "memoising … not triggered" item put the pinned `load_operation` + `load_at` at "10–25 %" of a page; at large-10k packed it is ~45 % of a 60-id page — re-stated per store (8 / 28 / 45 %, 51 % with the index; 3 / 12 / 33 % at 200 ids) in the read-out and deferred-work.md, the item reworded as a decision for Ralph (deferred entry 2) instead of "not triggered".
  - `[low]` `[patch]` (Blind Hunter) Option (c)'s trigger is a FIRST timestamped call, but the bench timed only the warm median on a reused handle — added a fresh-handle first-call row; re-run: 53.1 ms packed / 1.04 s loose, the same as a repeat call; numbers updated in the spec, deferred-work.md, the decisions file and the ADR-0002 Addendum.
  - `[low]` `[patch]` (Blind Hunter) `commit_contents_leaves_divergent_op_heads_unreconciled` wrote h0 as an ANCESTOR of h1 (only `load_at_head`'s prune path) — the test now builds two SIBLING op heads (the `tests/op_log.rs` marker choreography), reads at each with a non-empty id list, and asserts both markers stay and no operation file appears.
  - `[false]` `[reject]` (Blind Hunter) The story is marked done (sprint-status, epics.md, epic-4-context) before its review — the run finalizes to `done` after this pass, so the records match the final state; no reader sees a done story whose review failed.
  - `[low]` `[reject]` (Blind Hunter) The sprint-status 4-10 comment is stale now that it reads `done` (first-line description, "proposed" code, "Ralph chooses") — the dispatch intent requires updating only the status value and keeping the comment; editing it is excluded by the intent itself.
  - `[low]` `[patch]` (Blind Hunter) The root's content (empty author, committer timestamp 0) vs the topology's absent root timestamp was undocumented and untested — one sentence each in `CommitContent`'s rustdoc and the ffi-abi.md payload notes; the happy-path test asserts the root's author and `Timestamp { 0, 0 }`.
  - `[low]` `[patch]` (Blind Hunter) The Dart decoder coerced an absent `contents` vector with `?? const []` (and the "absent `commit_ids` = empty request" case had no FFI test) — the decoder now throws `ffi.unknown` "CommitContents is missing its contents" with a decode-contract test; `commit_contents_treats_an_absent_commit_ids_vector_as_an_empty_request` pins the Rust side.
  - `[false]` `[reject]` (Blind Hunter) A bad anchor looks exactly like a bad revset — the story specifies exactly that ("A malformed anchor fails the way `revset` does"); the missing warnings test it also names is the Verification Gap finding below and was patched there.
  - `[low]` `[patch]` (Blind Hunter) The `graph_blueprint.rs` relabel said its figures "time `Repo::graph_topology`'s stream pass", but the blueprint has no per-node view half — reworded: the raw jj-lib topology stream only; `graph_topology` adds the view half.
  - `[low]` `[reject]` (Blind Hunter) Codegen dropped `EvologEntry_VT_OPERATION_ID` from `zanshin_ffi.h` / `bindings.dart` (cbindgen keeps one associated const per name) — nothing consumes the C `VT_*` defines (Dart uses the flatc accessors; ffigen includes functions only), the files come from `cargo make codegen` unchanged (re-run: no drift), and a fix needs cbindgen export rules; unlikely to be met.
  - `[low]` `[reject]` (Blind Hunter) `RevsetError::DanglingEdge` puts a topology-only failure into the crate-wide revset error with three unreachable arms — a decision recorded for Ralph in `decisions-review-4-10-to-4-13.md` § Taken during the runs → 4.10 with its "if overruled" path; no user or caller harm (the arms map to their `Backend` / `graph.dangling_edge`).
  - `[low]` `[patch]` (Blind Hunter) The new Dart worker test found the root id through `handle.graphSlice`, which Story 4.12 (next) removes — `wcAndRoot` now uses `handle.show(revset: 'root()')`; the Rust suites use `walk_graph`, which 4.12 keeps (OQ 1b).
  - `[low]` `[patch]` (Blind Hunter) "Topology + contents for every id — the old one-call cost" was inferred; `walk_graph` itself was never timed — added a fresh-handle `walk_graph(all())` row (53 ms packed / 1.09 s loose at 10k); the ADR-0002 Addendum now cites it.
  - `[low]` `[patch]` (Blind Hunter) The changed-path-index conclusion ("saves the parent loads, 1.9 → 1.6 ms") is within noise — reworded to "no measurable effect on the fixtures (within noise)" in the read-out and deferred-work.md.
  - `[low]` `[reject]` (Blind Hunter) `epic-4-context.md` was rewritten wholesale — step-01 of this workflow regenerated it because every planning artifact was newer (mandated); the dropped facts (slice error codes, `lane.rs` `expect()`, the verify-codegen/separate-.fbs gotcha) concern the slice path 4.12 removes, and 4.12's `GraphTopology` stays in `envelope.fbs`.
  - `[low]` `[reject]` (Blind Hunter) `LogMetaIndex::extract` computes a `parent_count` only to discard it — one `parent_ids().len()` per row on the slice path, no named caller harm; restructuring `view_half`'s signature is more than a direct correction.
  - `[low]` `[reject]` (Blind Hunter) Uppercase ids are echoed in the caller's case by `jj.change_not_found` but answered lowercase in `CommitContent.commit_id` — every caller id comes lowercase from the topology call; unlikely to be met, and normalising adds a branch.
  - `[low]` `[patch]` (Edge Case Hunter) An ok envelope whose `contents` is absent decoded as empty (grouped with the Blind Hunter decoder finding above) — fixed there; the proposed per-call count-mismatch guard was not added: Rust always returns one entry per id, so it would guard a state never shown to occur.
  - `[low]` `[patch]` (Edge Case Hunter) A revset that names hidden commits can yield more nodes than `all_count` (visible `all()` only) — documented on `GraphTopology::all_count` and in the zanshin-jj README.
  - `[low]` `[reject]` (Edge Case Hunter) The dropped `EvologEntry_VT_OPERATION_ID` (same root cause as the Blind Hunter codegen finding) — rejected there.
  - `[low]` `[patch]` (Verification Gap) `prioritize` / `short_prefixes` were only ever passed at their defaults on the topology path — new `graph_topology_passes_prioritize_and_short_prefixes_through_without_a_default` (`none()` / `""`: c3 first, every node recomposes `walk_graph`'s meta).
  - `[low]` `[patch]` (Verification Gap) No test read `take_warnings()` after `graph_topology` (an anchor's diagnostics could be dropped) — new `graph_topology_records_an_anchors_parse_diagnostics_as_warnings` (`[RevsetDiagnostic]` under "In revset expression").
  - `[low]` `[patch]` (Verification Gap) The worker's unknown-handle branch for `CommitContentsCommand` was untested — new Dart `unknown_handle_id_surfaces_ffi_invalid_handle`.
  - `[false]` `[reject]` (Intent Alignment) The story's FFI codes for a bad anchor / a removed object and `DanglingEdge` → `graph.dangling_edge` are only pinned as Rust variants — the story makes the topology "Rust API only" in 4.10 (item 7; its wire and FFI mapper are 4.12), so no FFI surface exists yet to pin.
  - `[false]` `[reject]` (Intent Alignment) Topology → content composition is exercised only at the Rust API — same reason: the topology has no FFI/Dart surface until 4.12; the FFI and Dart tests take the operation id from the op heads / `opLog`, which is the operation the topology would return.
  - `[false]` `[reject]` (Intent Alignment) `defaultGraphAnchors` and `CommitContent` are not in the `zanshin_core.dart` barrel — none of their siblings (`defaultLogRevset`, `LogDefaults`, `RepoHandle`) are, and epics.md Story 10.12 item 4 assigns "Export 4.10–4.12's Dart types from `zanshin_core.dart`" to 10.12.
  - `[false]` `[reject]` (Intent Alignment) The Dart API returns `WarnedList` although the envelope carries no warnings — the wire rule holds (absent on every arm, pinned by Rust and Dart tests); `warnings` on every result is Story 9.32's Dart convention, always empty here.
  - `[low]` `[patch]` (Intent Alignment) The divergent-op-heads test used an ancestor head, not siblings (same root cause as the Blind Hunter finding above) — patched there.
  - `[low]` `[patch]` (Intent Alignment) The (c) trigger was compared against a warm median, not a first call (same root cause as the Blind Hunter bench finding) — patched there; the other shares come from the proxies the spec planned (snapshot, the anchors delta, the blueprint's raw passes), which is not a defect.
  - `[false]` `[reject]` (Intent Alignment) "Slice path untouched" is violated internally (shared `LogParse`/`LogSetup`, the `extract` split, a new `RevsetError` variant, compile-forced mapper arms) — the story itself asks for the shared helper; signatures, behaviour and every slice-path test are unchanged (`git diff` of those tests empty, gate green).
  - `[low]` `[defer]` (Intent Alignment) The spec's `deferred:` list was empty while deferred-work.md § "Surfaced in Story 4.10" lists items, one a decision for Ralph — the three Ralph-facing items (option (c)'s trigger, pinned-repo memoising, real-repo numbers) are now in the spec's `deferred:` list and the deferred-work.md intro line says so; the fourth (changed-path index) is a record, not a deferral.
  - `[low]` `[reject]` (Intent Alignment) `epic-4-context.md` rewritten wholesale (same root cause as the Blind Hunter finding) — rejected there.
  - `[low]` `[reject]` (Intent Alignment) Codegen dropped `EvologEntry_VT_OPERATION_ID` (same root cause as the Blind Hunter codegen finding) — rejected there.

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
- **Option (c)'s trigger is measured, not acted on.** The FIRST timestamped topology call on a fresh handle is 53 ms (median) at 10k packed — above the ~50 ms trigger — and ~1.04 s on the loose fixture; recorded for Ralph in `deferred-work.md` § "Surfaced in Story 4.10". Basis: OQ 1 = (b) stands until Ralph decides. If overruled: a follow-up story builds (c) or (d).

### Measurements

Release builds, jj-lib 0.44.0, this machine (Apple silicon), 2026-10-01 (the `graph_topology` bench's second run, after review added the first-call and `walk_graph` rows; the `graph_blueprint` rows are from 2026-09-30); min / median over 5 runs after 1 warm-up (`crates/zanshin-ffi/benches/graph_topology.rs`), 7 / 21 runs for `crates/zanshin-jj/benches/graph_blueprint.rs`. "Loose" = the committed fixture (every git object loose); "packed" = a `git gc`-packed copy of `large-10k`. Content pages and the rows marked "fresh handle" run on a FRESH handle each time (cold commit cache, the first call after a reload); the other topology rows reuse one handle.

| Timing | medium (1,002 nodes) loose | large-10k (10,002) loose | large-10k packed |
|---|---|---|---|
| topology-only walk, raw jj-lib (`graph_blueprint`) | 0.31 ms (first-100: 30 µs) | 3.07 ms (first-100: 30 µs) | — |
| `all()` count pass / `ParentCount` passes, raw (`graph_blueprint`) | 29 µs / 10 µs (1 merge) | 290 µs / 82 µs (1 merge) | — |
| `graph_topology(all())`, default anchors — the call total | 5.2 / 5.2 ms | 25.0 / 25.8 ms | 21.9 / 22.0 ms |
| `Repo::snapshot()` on the unchanged tree (precondition share) | 1.7 / 1.7 ms | 2.5 / 2.6 ms | 2.5 / 2.6 ms |
| `graph_topology`, anchors `[]` (anchor share = difference) | 4.9 / 5.0 ms | 24.5 / 24.9 ms | 21.4 / 21.5 ms |
| `graph_topology` with timestamps, repeat call (reused handle) | 104 / 108 ms | 1.024 / 1.039 s | 53.1 / 53.2 ms |
| `graph_topology` with timestamps, FIRST call (fresh handle) | 103 / 105 ms | 1.017 / 1.040 s | 53.1 / 53.1 ms |
| content, EMPTY list (`load_operation` + `load_at` share) | 0.17 / 0.19 ms | 0.74 / 0.86 ms | 0.72 / 0.78 ms |
| content page 60 ids, no merge (no changed-path index) | 2.35 / 2.45 ms | 3.02 / 3.09 ms | 1.62 / 1.74 ms |
| content page 60 ids, 1 merge (no changed-path index) | 2.63 / 2.70 ms | 3.38 / 3.44 ms | 1.96 / 1.97 ms |
| content page 200 ids, no merge (no changed-path index) | 6.12 / 6.29 ms | 6.54 / 7.05 ms | 2.30 / 2.34 ms |
| content page 200 ids, 1 merge (no changed-path index) | 5.97 / 6.17 ms | 6.13 / 6.48 ms | 1.94 / 2.11 ms |
| content page 60 ids, no merge (changed-path index) | 2.84 / 3.22 ms | 3.76 / 4.27 ms | 1.42 / 1.54 ms |
| content page 60 ids, 1 merge (changed-path index) | 2.55 / 2.60 ms | 3.28 / 3.48 ms | 1.79 / 1.87 ms |
| content page 200 ids, no merge (changed-path index) | 6.20 / 7.09 ms | 7.55 / 8.13 ms | 2.47 / 2.56 ms |
| content page 200 ids, 1 merge (changed-path index) | 5.89 / 6.10 ms | 6.54 / 6.64 ms | 2.50 / 2.74 ms |
| topology + contents for every id (fresh handle) | 103 / 106 ms | 0.969 / 1.043 s | 58.2 / 58.5 ms |
| `walk_graph(all())` to the end (fresh handle) — the old one-call cost | 101 / 103 ms | 1.052 / 1.091 s | 53.1 / 53.4 ms |

Read-outs:
- The raw index-only topology walk is unchanged (3.1 ms / 30 µs at 10k). The whole topology call is ~7× that at 10k: ~2.5 ms is the precondition, the rest the per-node view half (change-id resolution, two prefix lengths, immutable containment). Anchors cost ~0.2–0.9 ms.
- Timestamps cost ~31 ms packed and ~1 s loose at 10k, the first call on a fresh handle as much as a repeat call.
- The old one-call cost, `walk_graph(all())`, is 53 ms packed / 1.09 s loose at 10k; the split path (topology, then every node's content) is 58 ms / 1.04 s. The split pays off only because a page loads content for the visible nodes alone.
- The pinned `load_operation` + `load_at` share of a content page (empty-list median ÷ page median, no changed-path index): 60 ids — ~8 % (medium loose), ~28 % (large loose), ~45 % (large packed; ~51 % with the changed-path index); 200 ids — ~3 %, ~12 %, ~33 %. Whether that dominates a page enough to memoise the pinned repo is Ralph's call (`deferred-work.md` § "Surfaced in Story 4.10").
- The changed-path index has no measurable effect on the fixtures (within noise: 5 samples, and several index rows are slower than their no-index rows); the fixtures' one octopus merge merges tiny trees.

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

## Auto Run Result

Status: done
Blocking condition: none

### Summary of implemented change

`jj log` is split along "index/View-derived" vs "object-derived". `Repo::graph_topology(revset, prioritize, short_prefixes, anchors, with_timestamps)` (new `crates/zanshin-jj/src/topology.rs`) runs `walk_graph`'s parse → `load_at_head` → `TopoGroupedGraph` + `prioritize_branch` setup — now one shared helper (`graph.rs::LogParse` / `LogSetup`) — and the pre-verb precondition exactly once, and returns the loaded `operation_id`, every node in `jj log` order with its commit id, jj's edges verbatim (targets as node indices, Missing without a target, repeated targets kept; a miss is the new `RevsetError::DanglingEdge`) and `TopologyMeta` (the view half + an exact index-only `parent_count` from `ParentCount` filter passes), plus `all_count` (iterating `all()`, never `count_estimate`), the anchors' node indices and — only with `with_timestamps` — each non-root committer timestamp (epoch ms). `Repo::commit_contents(&self, operation_id, commit_ids)` (new `commit_content.rs`) reads the object half (author, committer timestamp, FULL description, conflict, empty) at the PINNED operation (`load_operation` + `load_at`): no precondition, no config load, no warnings, no operation or op head written; full hex ids only, request order, error ladder `jj.invalid_input` → new `jj.operation_not_found` → `jj.invalid_input` → `jj.change_not_found` → `jj.jj_lib_error`. `commit_meta.rs`'s extraction is split into the two halves; `walk_graph`'s `CommitMeta` is composed from them, values unchanged. The content call ships full stack: `zanshin_commit_contents` over `CommitContentsRequest` → `CommitContents` (61 exports), Dart `RepoHandle.commitContents` → `WarnedList<CommitContent>` with a throwing decoder, and the `defaultGraphAnchors` pre-fill. ADR-0002 Addendum 2026-09-30 records the pinned read; a bench re-measures every figure.

### Files changed (baseline `64ed3b32cc3d76e2ecfc75db1b8dbc1ceb5dd828`)

- `crates/zanshin-jj/src/topology.rs` (NEW) — `GraphTopology` / `TopologyNode` / `TopologyEdge` / `TopologyMeta`, `graph_topology`, pure helpers + unit tests.
- `crates/zanshin-jj/src/commit_content.rs` (NEW) — `CommitContent`, `CommitContentError`, `commit_contents` (two passes over the ids), id classifiers + unit tests.
- `crates/zanshin-jj/src/{graph,commit_meta,repo,revset,lib}.rs` — shared `LogParse` / `LogSetup`; view/object half split; the two `Repo` methods; `RevsetError::DanglingEdge`; exports; dated note on `Repo`'s doc.
- `crates/zanshin-jj/src/{commit_views,mutate}.rs` — the `DanglingEdge` arm in the two exhaustive mappers (+ test rows).
- `crates/zanshin-jj/tests/{graph_topology,commit_contents}.rs` (NEW), `tests/api_stability.rs` — every zanshin-jj matrix row, split equivalence on tiny + medium, API pins.
- `crates/zanshin-jj/{README.md,benches/graph_blueprint.rs}` — topology/content section; blueprint relabelled (raw topology stream) + the count and `ParentCount` pass timings.
- `schemas/envelope.fbs` + regenerated `crates/zanshin-ffi/include/zanshin_ffi.h`, `crates/zanshin-ffi/src/envelope_generated.rs`, `packages/zanshin_core/lib/src/ffi/{bindings.dart,envelope_zanshin.ffi_generated.dart}` — `CommitContentsRequest`, `CommitContent` / `CommitContents`, appended `RequestKind` / `Payload` members.
- `crates/zanshin-ffi/src/commit_contents.rs` (NEW), `src/{envelope,lib,graph,repo}.rs` — the extern, reader, builder, mapper; `JJ_OPERATION_NOT_FOUND`; the `DanglingEdge` arm; dated note.
- `crates/zanshin-ffi/tests/commit_contents_ffi.rs` (NEW), `tests/{snapshot_ffi,ffi_abi_doc_sync}.rs` — the FFI ladder, the no-precondition list, `EXPECTED_EXPORTS` 61.
- `crates/zanshin-ffi/{Cargo.toml,benches/graph_topology.rs}` (NEW bench), `crates/test-helpers/src/lib.rs` (`build_changed_path_index`).
- `packages/zanshin_core/lib/src/{ffi/commit_contents.dart (NEW),ffi/graph.dart,worker/commands.dart,worker/isolate.dart,worker/handle.dart}`, `test/ffi/commit_contents_test.dart` (NEW), `test/worker/commit_contents_test.dart` (NEW), `test/ffi/graph_test.dart`.
- `docs/{adr/0002-…,ffi-abi,rust-error-codes}.md` — Addendum, the CommitContents section + counts + index row, the `jj.operation_not_found` row and "also emitted" clauses.
- `_bmad-output/{project-context.md,planning-artifacts/architecture.md,planning-artifacts/epics.md}` — dated notes, the Delivered note; `implementation-artifacts/{deferred-work.md,decisions-review-4-10-to-4-13.md,sprint-status.yaml,epic-4-context.md}`, `coverage-baseline.txt` (three new files at 100 / 97.17 / 99.52 %).

### Review findings breakdown

One review pass (four layers: Blind Hunter, Edge Case Hunter, Verification Gap, Intent Alignment), 33 findings: high 0, medium 0, low 26, false 7.
- **Patched (13 entries, all low):** the pinned-load share and changed-path-index read-outs corrected; a first-call and a `walk_graph` row added to the bench (re-run, numbers updated everywhere they are cited); sibling op heads in the divergent-heads test; the Dart decoder throws on an absent `contents` vector; an FFI test for an absent `commit_ids`; the root commit's content documented and asserted; `all_count` vs hidden commits documented; the blueprint comment corrected; tests for non-default `prioritize` / `short_prefixes`, for the topology's warnings and for the worker's unknown-handle branch; the Dart test no longer depends on `graphSlice`.
- **Deferred (3, spec `deferred:` + deferred-work.md):** option (c)'s trigger met at 10k packed (decision for Ralph); whether the pinned load (~45 % of a 60-id page, packed 10k) dominates enough to memoise (decision for Ralph); no real-repo numbers (needs a repo path).
- **Rejected:** 7 false (done-before-review is resolved by this finalization; the anchor error behaviour is the story's; FFI-surface expectations of the topology are 4.12's; the barrel export is 10.12's; `WarnedList` is Story 9.32's convention while the wire stays warning-free; the slice path's signatures, behaviour and tests are unchanged) and 7 low (the sprint-status comment — the intent keeps it; the codegen-dropped `EvologEntry_VT_OPERATION_ID` — no consumer, a cbindgen export-rule fix; `RevsetError::DanglingEdge` — a recorded decision for Ralph; the regenerated epic context — mandated by step-01, the dropped facts belong to the slice path 4.12 removes; the discarded `parent_count` in `extract` — negligible; uppercase-id echo — unreachable from the topology's lowercase ids), each with its reason in the triage log.

### Follow-up review recommendation

`followup_review_recommended: false` — first pass, patched entries by verdict: high 0, medium 0, low 13; no high and fewer than two medium patches.

### Verification performed

- `cargo make codegen` — exit 0, no drift (the committed generated files are reproducible); the header, bindings and both flatc outputs carry `zanshin_commit_contents` / the new tables.
- `cargo test -p zanshin-jj --test graph_topology --test commit_contents --test api_stability` (11 + 14 + 14 before the patches) and `cargo test -p zanshin-ffi --test commit_contents_ffi --test snapshot_ffi --test ffi_abi_doc_sync` — green; after the patches the implementer ran the touched suites green (13 + 14, 7, 16 Dart).
- `cargo make test`, synchronous and unpiped (output to a file): exit 0 twice — before the review (820 s) and after the patches (751 s); both `coverage-check: OK — coverage held at 99.48% (14841/14919 lines)` and `extern-coverage: OK`; the Dart suite `+573: All tests passed!`; no baseline lowered, no `exclude_prefix`, no `EXTERN_COV_ALLOW` addition.
- `cargo bench -p zanshin-jj --bench graph_blueprint -- --large` and `cargo bench -p zanshin-ffi --bench graph_topology` — run to completion (the latter again after the patches); the numbers reproduce § Measurements within noise.
- `git diff 64ed3b3 -- crates/zanshin-jj/tests/graph.rs crates/zanshin-jj/tests/warnings.rs crates/zanshin-graph crates/zanshin-ffi/tests/graph_ffi.rs app/lib` — empty.
- Manual: `grep -rn count_estimate crates/zanshin-jj/src` — no hit; `epic-4-context.md` newer than every planning artifact.
- Matrix test audit: every I/O-matrix row maps to a test that ran and passed in the gate output (zanshin-jj, zanshin-ffi and Dart names checked in the log).

### Residual risks

- Option (c) / (d): every default (free-layout) reload loads every commit's timestamp — 53 ms at 10k packed, ~1 s on loose stores; Ralph's decision is open (deferred).
- `RevsetError::DanglingEdge` is unreachable through jj-lib and pinned only by a unit test of the pure resolution helper.
- The topology's FFI error codes (anchors, dangling edge) are only reached in Story 4.12; this story pins them as Rust variants.
- The bench runs on synthetic fixtures (one octopus merge, tiny trees); real repos with many merges were not measured (deferred).

