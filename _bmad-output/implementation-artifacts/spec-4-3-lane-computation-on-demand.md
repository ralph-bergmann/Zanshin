---
title: 'Story 4.3: Lane computation on demand (was: cache.rs) — lazy revset graph stream → LaneAssigner'
type: 'feature'
created: '2026-08-22'
status: 'done'
baseline_revision: '4e679cbf5f581d9df52e63f06a22ea786727c8fe'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/docs/adr/0002-repository-state-model-warm-loader-reload-per-operation.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      architecture.md's zanshin-graph tree block still lists `output.rs # FR-GR-2 JSON` right
      under the (now updated) `stream.rs` line, although Story 4.2 delivered the graph payload as
      the FlatBuffers `GraphSlice` in `zanshin-ffi` (ADR-0001) — the JSON output module no longer
      exists in the plan.
    evidence: |-
      `_bmad-output/planning-artifacts/architecture.md:446` reads `output.rs # FR-GR-2 JSON`;
      the 4.2 "Delivered standalone" note in epics.md and `crates/zanshin-ffi/src/graph.rs`
      (FlatBuffers builder) show the JSON output was superseded. Pre-existing, surfaced because
      4.3 edited the adjacent `cache.rs` → `stream.rs` line (`architecture.md:444`).
    location: >-
      _bmad-output/planning-artifacts/architecture.md:446
    severity: low
  - summary: >-
      `test-jj-adapter-hygiene` only greps `crates/zanshin-jj/src/` for `pub use jj_lib`; nothing
      mechanically verifies that `zanshin-graph` (the first crate depending on `zanshin-jj`) has
      no `jj-lib` dependency or `jj_lib` import, although spec/docs state that invariant.
    evidence: |-
      `Makefile.toml` `[tasks.test-jj-adapter-hygiene]` (l.192-222) iterates
      `git ls-files 'crates/zanshin-jj/src/'` only; `crates/zanshin-graph/Cargo.toml` and its
      sources are not inspected. The invariant currently holds by inspection (no `jj-lib` in
      `crates/zanshin-graph/Cargo.toml`, no `jj_lib` in its sources) but is unguarded.
    location: >-
      Makefile.toml:192-222 (test-jj-adapter-hygiene); crates/zanshin-graph/Cargo.toml
    severity: low
---

<intent-contract>

## Intent

**Problem:** Story 4.1's streaming `LaneAssigner` has no real input yet — nothing turns a repo + revset into the topologically-ordered `GraphNode` stream it consumes. The epic's Story 4.3 (`LaneCache::build/rebuild`, a materialized `cache.rs` with a `Map<ChangeId, usize>` index, rebuilt on every `op_heads` change) is superseded by ADR-0002 AC-4: the graph is a **lazy revset stream** re-derived from the head operation on every call, never held as a cache (full 10k derive ~3 ms).

**Approach:** (1) `zanshin-jj` gains the jj-lib-free revset **graph stream** — `Repo::walk_graph(revset, prioritize, visit)` — built on the exact `jj log` pipeline (`revset.stream_graph()` wrapped in `TopoGroupedGraph`, prioritized by `revsets.log-graph-prioritize` semantics), re-resolving to head per call and handing each node to a visitor callback (streaming, early-exit capable). (2) `zanshin-graph` gains `src/stream.rs` — `stream_lanes(repo, revset, prioritize, sink)` — which maps that stream into 4.1's `GraphNode` and pushes it through `LaneAssigner`, emitting one final `Row` per node as it arrives. **Mapping-owner decision (left open by 4.1 / epic context): `zanshin-graph` depends on `zanshin-jj`** (`zanshin-ffi` → `zanshin-graph` → `zanshin-jj`; no cycle). No cache struct, no rebuild API, no FFI (4.6), no collect-all/paging API (4.4 `slice.rs`).

## Boundaries & Constraints

**Always:**
- ACL (FR-JJ-16): only `zanshin-jj` imports `jj_lib`; no `jj_lib` type in any public position; `zanshin-graph` never adds `jj-lib` (not even as dev-dep — its tests use the `zanshin_jj` API + fixtures only). `test-jj-adapter-hygiene` stays green; `crates/zanshin-jj/tests/api_stability.rs` grows 27 → 30 types.
- **CLI parity (NFR-R-2, ADR-0003): row order = `jj log`'s observable order.** Pipeline = `TopoGroupedGraph::new(revset.stream_graph(), |id| id)`; prioritization = the CLI's `revsets.log-graph-prioritize` mechanics: `parse(prioritize) ∩ parse(revset)` (user-expression intersection BEFORE resolution — mandatory, an out-of-set id makes `TopoGroupedGraph` panic), evaluated to commit ids, each passed to `prioritize_branch` (`../jj` @ v0.42.0 `cli/src/commands/log.rs:186-231`). Both `revset` and `prioritize` are caller pass-throughs (FR-JJ-17); `pub const DEFAULT_GRAPH_PRIORITIZE: &str = "present(@)"` exposes the CLI config default (`cli/src/config/revsets.toml`) as the pre-fill — never applied silently.
- Re-resolve to head on every call (`load_at_head`, ADR-0002 "Decision D4"); nothing is retained across calls; no struct holds rows/nodes beyond the current node in production code.
- Streaming shape: internal iteration — `visit: impl FnMut(GraphNode) -> ControlFlow<()>` / `sink: impl FnMut(Row) -> ControlFlow<()>`; return `Result<ControlFlow<()>, _>` (`Continue` = stream exhausted, `Break` = visitor stopped). `stream_lanes` runs `LaneAssigner::finish()` ONLY when the stream was exhausted (an early `Break` legitimately leaves open reservations).
- Errors: `zanshin-jj` reuses `RevsetError` (`ParseError` for either expression, `ResolutionError`, `JjLibError` for evaluation + per-item stream failures) — no new jj error type; `zanshin-graph` adds `LaneStreamError { Revset(#[from] RevsetError), Graph(#[from] GraphError) }` in `stream.rs`. No new `error.code` (nothing crosses FFI) → `docs/rust-error-codes.md` untouched.
- Reuse, don't duplicate: the revset parse context in `crates/zanshin-jj/src/revset.rs` is split into crate-private `parse_revset` + `evaluate_revset` helpers used by `resolve_revset` AND `walk_graph`; `resolve_revset`'s observable behavior is unchanged (its 20+ tests are the guard; `revset.rs` stays 100 %).
- `zanshin-jj` stays sync (`pollster::block_on`, revset.rs precedent); `jj_lib::graph::TopoGroupedGraph` needs `S: Unpin` (`LocalBoxStream` is) and `F: Fn(&N) -> &ID + Unpin` (use a `fn` pointer as in `graph_blueprint.rs:124`).
- Quality bar: clippy pedantic refactor-not-suppress, rustfmt, `#![deny(missing_docs)]` (doc every `pub` item incl. `# Errors`), SPDX first line, no `unwrap`/`expect`/`panic!` in library paths, scenario-named tests, `JJ_CONFIG`/`GIT_CONFIG_GLOBAL` pinned via the `LazyLock` pattern, no timing asserts, fixtures `tiny-3-commits` + `medium-1k-commits` only.
- Coverage ratchet: new `crates/zanshin-jj/src/graph.rs` and `crates/zanshin-graph/src/stream.rs` ≥ 80 % (aim ~100 % via `tests/` + inline mapping tests); no regression in `revset.rs`/`repo.rs`/`lane.rs`; commit the auto-raised `coverage-baseline.txt` with the code.
- Repo conventions: ONE focused commit on `main` (`feat(zanshin-graph): stream lanes on demand from the revset graph (Story 4.3)`) incl. story artifacts; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, never committed (4.1/4.2 precedent). Edit `epic-4-context.md` AFTER any planning-artifact edit so it stays the newest file (validity rule of the epic-context cache).

**Block If:**
- `cargo make test` fails for a reason outside this story that cannot be fixed in scope (do not lower the baseline / add `exclude_prefix`).
- jj-lib 0.42.0 cannot express the CLI's prioritization (user-expression `intersection` + `prioritize_branch`) — do not improvise a different ordering; block instead.

**Never:**
- No materialized or persistent lane cache, no `LaneCache`, no `Map<ChangeId, usize>`, no `rebuild`, no watcher/op-heads wiring (4.6 re-derives on op-id advance via this API), no memoization across calls.
- No `extern "C"` fn, `.fbs`, codegen, Dart, `WorkerCommand`, `docs/ffi-abi.md` change (4.6); no collect-all / `total_rows` / `GraphSlice` return API / paging / `limit` / `reversed` (4.4 `slice.rs` decides; CLI `--limit`/`--reversed` are paging/terminal concerns).
- No change to `lane.rs` semantics or `Row`/`RowEdge`/`GraphNode` shapes; no edits to `crates/zanshin-ffi/src/graph.rs` (4.2).
- No `revset-aliases` beyond `trunk()` (`build_aliases_map`, Story 2.5 D2) — `immutable_heads()` etc. still fail to parse; document, don't extend.
- No `large-10k` fixture, no perf assertions, no `#[ignore]`.

## I/O & Edge-Case Matrix

Fixture facts (`crates/xtask/src/tasks/gen_fixture.rs:177-268`): **tiny** = `root` ← `@` (empty working-copy commit created at init) and `root` ← c1 ← c2 ← c3 (descriptions `"Commit 1".."Commit 3"`) → two heads `{@, c3}`, `all()` = 5 nodes. **medium** = root ← `@` plus 200 linear → 3 branches × 66 → octopus merge (3 parents) → 601 linear → `all()` = 1002 nodes, every edge `Direct`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Tiny, CLI-default prio | `stream_lanes(tiny, "all()", "present(@)")` | `Ok(Continue)`; 5 rows in order `@, c3, c2, c1, root`; lanes `@=0, c3=c2=c1=1, root=0`; edges: `@→root Direct Some(0)`, `c3→c2 Some(1)`, `c2→c1 Some(1)`, `c1→root Some(1)`, root none; `color_idx == lane` | none |
| Tiny, no prio | same, prioritize `"none()"` | same 5 rows as a set; first row is NOT `@` (c3's branch first — natural `TopoGroupedGraph` order); proves the parameter is honoured | none |
| Heads only → `Missing` | tiny, `"heads(all())"`, `"present(@)"` | 2 rows (`@` first); each has exactly 1 edge, `kind Missing`, `target_lane None`; both rows lane 0 (a stub frees its lane) | none |
| Elided parent → `Indirect` | tiny, `"all() ~ description(\"Commit 2\")"`, `"present(@)"` | 4 rows; c3's row has 1 edge, `kind Indirect`, `target == c1`'s commit id, `target_lane Some(c3.lane)`; c2 absent (commit ids via `resolve_revset` + `Repo::get_change(..).commit_id`) | none |
| Medium invariants | medium, `"all()"`, `"present(@)"` | 1002 rows; row 0 is `@`; exactly one row with 3 edges (the merge), all edges `Direct`; max lane == 3; every edge target appears in a LATER row (children-before-parents); `finish` Ok; second run identical (determinism) | none |
| Early exit | tiny `all()`, sink returns `Break` after 2 rows | `Ok(Break)`; exactly 2 rows observed; no `DanglingEdge` | none |
| Re-derive per call (ADR-0002) | `walk_graph(tiny, "all()", ..)` counts n; a jj-lib test transaction adds a visible commit off root (external op); same `Repo` handle walks again | n+1 nodes, the new commit id present — no reopen, no cache | none |
| Prio outside revset | tiny, revset `"heads(all())"`, prioritize `"root()"` | `Ok`, 2 nodes, no panic (intersection empties the prio set → natural order) | none |
| Empty revset | `"none()"` | `Ok(Continue)`, zero nodes / rows | none |
| Parse error (either param) | revset `"bogus_function()"` or prioritize `"("` | `walk_graph` → `Err(RevsetError::ParseError)`; `stream_lanes` → `Err(LaneStreamError::Revset(ParseError))` | propagated, no panic |
| Resolution error | revset `"nonexistent-bookmark-xyz"` | `Err(RevsetError::ResolutionError)` | propagated |
| Kind mapping | each `jj_lib::graph::GraphEdgeType` / each `zanshin_jj::GraphEdgeKind` | `Missing→Missing`, `Direct→Direct`, `Indirect→Indirect` (exhaustive matches) | none |

</intent-contract>

## Code Map

- `crates/zanshin-jj/src/revset.rs` -- `resolve_revset` l.51-110: reload-to-head l.53-55, parse-context build l.58-82 (`build_aliases_map`, `FilesetAliasesMap`, `RevsetExtensions::default()`, `RepoPathUiConverter::Fs`, `RevsetWorkspaceContext`, `RevsetParseContext`), parse l.85-87, resolve l.88-91, evaluate l.92-94, collect l.99-109. SPLIT into `pub(crate) fn parse_revset(repo: &Repo, expr: &str) -> Result<Arc<UserRevsetExpression>, RevsetError>` (l.58-87) and `pub(crate) fn evaluate_revset<'r>(repo_dyn: &'r dyn jj_lib::repo::Repo, expr: &Arc<UserRevsetExpression>) -> Result<Box<dyn Revset + 'r>, RevsetError>` (l.88-94; builds its own `RevsetExtensions::default()` for `SymbolResolver`); `resolve_revset` = load head → `parse_revset` → `evaluate_revset` → l.99-109 unchanged. jj-lib: `UserRevsetExpression::intersection(self: &Arc<Self>, other: &Arc<Self>) -> Arc<Self>` (vendored `revset.rs:636`), `resolve_user_expression` (l.669), `evaluate(self: Arc<Self>, repo: &'index dyn Repo) -> Result<Box<dyn Revset + 'index>, _>` (l.680).
- `crates/zanshin-jj/src/graph.rs` (NEW) -- noun module: `GraphEdgeKind { Direct, Indirect, Missing }` (4.1/4.2 order, NOT jj-lib's), `GraphEdge { target: CommitId, kind }`, `GraphNode { id: CommitId, parents: Vec<GraphEdge> }` (doc: edges in stream order, not 1:1 per parent — jj-lib splices elided-parent edges, `revset_graph_iterator.rs:155-282`), `pub const DEFAULT_GRAPH_PRIORITIZE: &str = "present(@)"`, `pub(crate) fn walk_graph(repo: &Repo, revset: &str, prioritize: &str, visit: impl FnMut(GraphNode) -> ControlFlow<()>) -> Result<ControlFlow<()>, RevsetError>` + private `fn edge_kind(jj_lib::graph::GraphEdgeType) -> GraphEdgeKind` with an inline exhaustive test. jj-lib API: `Revset::stream_graph(&self) -> LocalBoxStream<'_, Result<GraphNode<CommitId>, RevsetEvaluationError>>` (vendored `revset.rs:3437`), `Revset::stream()` (l.3424, commit ids for the prio set), `TopoGroupedGraph::new(input, as_id)` / `prioritize_branch(id)` / `stream(self) -> impl Stream` (vendored `graph.rs:173,192,336`; `GraphNode<N> = (N, Vec<GraphEdge<N>>)` l.30, `GraphEdge { target, edge_type }` l.33, `GraphEdgeType { Missing, Direct, Indirect }` l.81). Commit id hex via `jj_lib::object_id::ObjectId::hex()` (change.rs precedent).
- `crates/zanshin-jj/benches/graph_blueprint.rs` -- `walk_graph` l.118-135: the runnable upstream pipeline (identity `as_id` fn pointer l.124, `Box::pin(TopoGroupedGraph::new(revset.stream_graph(), as_id).stream())`, `block_on(stream.next())`). READ-ONLY; the bench stays.
- `git -C ../jj show v0.42.0:cli/src/commands/log.rs` (the jj CLI's `log` at the pinned tag) -- l.186-188 prio revset = config string parsed then `intersect_with(revset_expression.expression())`; l.225-231 `TopoGroupedGraph::new(revset.stream_graph(), |id| id)` + `prioritize_branch` per prio commit id; l.235 `take(limit)` on the OUTPUT (4.4's concern). `git -C ../jj show v0.42.0:cli/src/config/revsets.toml` → `log-graph-prioritize = "present(@)"`.
- `crates/zanshin-jj/src/repo.rs` -- `Repo { workspace, settings }` l.80-83; `workspace()` l.101, `settings()` l.106 (crate-private accessors); read-method pattern + doc style l.137-150 (`op_log`: "Re-resolves to the head operation per call (ADR-0002)", `# Errors`, `#[must_use = …]`). ADD `pub fn walk_graph(&self, revset: &str, prioritize: &str, visit: impl FnMut(crate::GraphNode) -> ControlFlow<()>) -> Result<ControlFlow<()>, crate::RevsetError>` delegating to `crate::graph::walk_graph(self, …)`.
- `crates/zanshin-jj/src/lib.rs` -- module list l.30-38 (`pub(crate) mod graph;`), re-exports l.40-48 (`pub use graph::{GraphEdge, GraphEdgeKind, GraphNode, DEFAULT_GRAPH_PRIORITIZE};`). `pub use jj_lib::…` forbidden (hygiene gate `Makefile.toml:192-219`).
- `crates/zanshin-jj/tests/api_stability.rs` -- type-alias table l.12-55 (comment says 27 types → 30), value constructions l.67-106; ADD `_GraphNode/_GraphEdge/_GraphEdgeKind`, `GraphEdgeKind::Direct`, a `GraphNode { id: CommitId(String::new()), parents: vec![] }`, `_ = zanshin_jj::DEFAULT_GRAPH_PRIORITIZE`.
- `crates/zanshin-jj/tests/revset.rs` -- golden fixture test pattern: `ENV_GUARD`/`pin_env` l.15-25, `make_test_settings` l.27-44, jj-lib oracle workspace load l.50-57, test transaction adding commits l.290-340 (`repo.start_transaction()`, `new_commit(vec![root_id], root_commit.tree()).set_description(..).write()`, `add_head`, `tx.commit(..)`). Mirror for `tests/graph.rs` (new), incl. the external-op re-derive test.
- `crates/zanshin-graph/src/lane.rs` -- input types `EdgeKind` l.22-33, `GraphEdge` l.37-42, `GraphNode` l.61-70; `LaneAssigner::new/push/finish` l.155-214; `Row`/`RowEdge` l.74-106; `GraphError::DanglingEdge` l.110-120. READ-ONLY.
- `crates/zanshin-graph/src/lib.rs` -- crate doc l.5-16 (last sentence "Story 4.3 decides where that mapping lives" → state the decision), `mod lane;` l.18 + `pub use` l.20. ADD `mod stream;` + `pub use stream::{stream_lanes, LaneStreamError};`.
- `crates/zanshin-graph/src/stream.rs` (NEW) -- `LaneStreamError` (thiserror, `#[from]` both), `impl From<zanshin_jj::GraphEdgeKind> for EdgeKind`, `impl From<zanshin_jj::GraphNode> for GraphNode` (move `CommitId.0` strings), `pub fn stream_lanes(repo: &zanshin_jj::Repo, revset: &str, prioritize: &str, mut sink: impl FnMut(Row) -> ControlFlow<()>) -> Result<ControlFlow<()>, LaneStreamError>`; inline tests for both `From` impls (exhaustive kind map, field moves).
- `crates/zanshin-graph/Cargo.toml` -- `[dependencies]` l.12-13 (+ `zanshin-jj = { workspace = true }`); ADD `[dev-dependencies] test-helpers = { path = "../test-helpers", version = "0.1.0" }` (mirror `crates/zanshin-jj/Cargo.toml:20-22`). Root `Cargo.toml:43-44` already declares both workspace deps.
- `crates/zanshin-graph/tests/lane.rs` -- helper/naming style for the new `tests/stream.rs` (scenario names, `node(..)` builders); fixture handling = `test_helpers::extract_fixture("tiny-3-commits")` + `zanshin_jj::Repo::open(&fx.path)` + `pin_env`.
- `crates/test-helpers/src/lib.rs` -- `extract_fixture(name) -> FixtureHandle { path }` (temp dir, auto-cleanup).
- `crates/zanshin-jj/README.md` -- API doc; ADD a short "Graph stream (`Repo::walk_graph`)" section after "Conversion modes" (pipeline, pass-through params, `DEFAULT_GRAPH_PRIORITIZE`, callback shape, alias caveat).
- `coverage-baseline.txt` -- l.30 `lane.rs = 100.00`, l.38 `revset.rs = 100.00`, l.37 `repo.rs = 91.43`; the ratchet adds `crates/zanshin-jj/src/graph.rs` + `crates/zanshin-graph/src/stream.rs` rows on `cargo make test`.
- `_bmad-output/planning-artifacts/epics.md` -- Story 4.3 l.2818-2874 (stale `LaneCache` ACs; dated notes l.2820/2822); APPEND a dated "Delivered (2026-08-22)" note (4.2 precedent l.2763). `architecture.md:444` (`cache.rs` → `stream.rs`). `deferred-work.md:100` (annotate 4.3 as delivered). `epic-4-context.md` l.13 (4.3 → done) + l.33 (mapping decision) — edit LAST.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- l.86 `4-3-lane-computation-on-demand-cache-rs: backlog` → `review` (note "(reconciled to the ADR-0002 lazy stream, see last_updated)"); l.48 `last_updated` history line: prepend the new entry, keep the `PREV:` chain.

## Tasks & Acceptance

**Execution:**
- `crates/zanshin-jj/src/revset.rs` -- extract `parse_revset` + `evaluate_revset` (crate-private), rewire `resolve_revset` -- one parse context, shared by the graph walk (Epic 9's `eval_revset` joker reuses the same ground).
- `crates/zanshin-jj/src/graph.rs` (new) + `crates/zanshin-jj/src/lib.rs` (`pub(crate) mod graph;` + re-exports) -- types, `DEFAULT_GRAPH_PRIORITIZE`, `walk_graph`: load head → `parse_revset(revset)`, `parse_revset(prioritize)` → `prio = prio.intersection(&log)` → `evaluate_revset` both → prio commit ids via `block_on(prio_set.stream().try_collect())` → `TopoGroupedGraph::new(set.stream_graph(), as_id)` + `prioritize_branch` each → `pin!(topo.stream())` driven in one `pollster::block_on(async { while let Some(item) = stream.next().await { … visit(node)?… } })`; map item errors to `JjLibError`; return `Break`/`Continue` -- the CLI-parity stream, jj-lib-free at the boundary.
- `crates/zanshin-jj/src/repo.rs` -- `Repo::walk_graph` method (doc: re-resolves to head; `jj log` order; pass-through params; `# Errors`) -- the public entry point (read-method convention).
- `crates/zanshin-jj/tests/api_stability.rs` -- 27 → 30 types + value constructions + const -- surface lock.
- `crates/zanshin-jj/tests/graph.rs` (new) -- fixture tests for every matrix row that names `walk_graph`: tiny node set/order with `present(@)` (@ first) vs `none()`, Missing/Indirect kinds, children-before-parents on medium (1002 nodes, prio first), prio-outside-revset no-panic, empty revset, parse/resolution errors for each param, early `Break`, external-op re-derive on the same handle -- the stream contract 4.1 relies on (`GraphNode` doc items 1-3).
- `crates/zanshin-graph/Cargo.toml` -- `+zanshin-jj` dep, `+test-helpers` dev-dep -- the mapping-owner decision.
- `crates/zanshin-graph/src/stream.rs` (new) + `crates/zanshin-graph/src/lib.rs` (`mod stream;`, re-exports, crate-doc sentence) -- `LaneStreamError`, `From` impls, `stream_lanes` (walk → `From` → `LaneAssigner::push` → sink; `finish()` only on `Continue`) + inline `From` tests -- lane computation on demand.
- `crates/zanshin-graph/tests/stream.rs` (new) -- matrix rows naming `stream_lanes`: tiny exact rows (both prio values), heads → Missing stubs, elided → Indirect (commit ids via `resolve_revset` + `get_change`), medium invariants + determinism, early exit, empty, parse error → `LaneStreamError::Revset` -- end-to-end proof incl. the 4.1 contract (`finish` Ok on real streams).
- `crates/zanshin-jj/README.md`, `_bmad-output/planning-artifacts/epics.md` (§4.3 delivered note), `_bmad-output/planning-artifacts/architecture.md:444`, `_bmad-output/implementation-artifacts/deferred-work.md:100`, then `epic-4-context.md` (last) -- doc reconciliation -- planning docs stop describing the retired cache; the epic-context cache stays valid.
- `_bmad-output/implementation-artifacts/sprint-status.yaml` -- `4-3` → `review` + `last_updated` entry -- tracking convention (step-04 flips to `done`).
- run `cargo make test` (unpiped) -- fix by refactoring; commit the raised `coverage-baseline.txt`; revert gate churn; one commit -- definition of done.

**Acceptance Criteria:**
- Given a `zanshin_jj::Repo` on a fixture, when `repo.walk_graph(revset, prioritize, visit)` runs, then every node of the revset is visited exactly once, children before parents, with edge kinds `Direct`/`Indirect`/`Missing` as classified by jj-lib, in the order `jj log -r <revset>` would print with `revsets.log-graph-prioritize = <prioritize>`, and the call re-resolves to the head operation (a commit added by an external jj-lib transaction appears on the next call of the SAME handle).
- Given `stream_lanes(repo, revset, prioritize, sink)`, when the stream is exhausted, then `sink` received exactly one `Row` per node in walk order, `LaneAssigner::finish()` returned `Ok`, the result is `Ok(Continue)`; when `sink` returns `Break`, then no further rows are produced, `finish` is skipped, and the result is `Ok(Break)`.
- Given an invalid `revset` or `prioritize` expression, when either API runs, then it returns `RevsetError::ParseError`/`ResolutionError` (wrapped in `LaneStreamError::Revset` for `stream_lanes`) and never panics — including a `prioritize` whose commits lie outside `revset`.
- Given the finished tree, when `cargo make test` runs unpiped, then it exits 0 with `crates/zanshin-jj/src/graph.rs` and `crates/zanshin-graph/src/stream.rs` ≥ 80 %, `revset.rs`/`lane.rs` unchanged at 100 %, api_stability at 30 types, hygiene gates green; `git status` is clean after the single commit (deliberate gate-churn reverts aside).

## Spec Change Log

## Review Triage Log

### 2026-08-23 — Review pass
- intent_gap: 0
- bad_spec: 0
- patch: 10: (high 0, medium 1, low 9)
- defer: 2: (high 0, medium 0, low 2)
- reject: 16
- addressed_findings:
  - `[medium]` `[patch]` `stream_lanes`'s exhausted-stream `finish()` → `LaneStreamError::Graph` path was unobservable (real fixtures never leave a dangling edge; deleting the `finish()` call kept every test green) — split the loop into a crate-private `drive_lanes(walk, sink)` (`stream_lanes` = `drive_lanes(|visit| repo.walk_graph(..), sink)`) and added the inline test `drive_lanes_reports_a_dangling_edge_when_the_exhausted_stream_never_delivered_the_target` (synthetic walk, one `Direct` edge to a target that never arrives → `Err(Graph(DanglingEdge { target }))`, the row still emitted first).
  - `[low]` `[patch]` `DEFAULT_GRAPH_PRIORITIZE`'s value was never pinned (changing it to `"@"` kept every test green) — `tests/api_stability.rs` now asserts `== "present(@)"`.
  - `[low]` `[patch]` Documented "empty/blank `prioritize` is a `ParseError`" was untested at both surfaces — added `walk_graph_blank_prioritize_returns_parse_error` (`""`, `"   "`) and `stream_lanes_blank_prioritize_returns_revset_parse_error`.
  - `[low]` `[patch]` `walk_graph` paid `load_at_head` I/O before parsing either expression (parsing needs no loaded operation) — reordered: parse + intersect first, then load head, then evaluate.
  - `[low]` `[patch]` Test counts in `epics.md` §4.3 and `sprint-status.yaml` (13 / 10 / 3 inline) did not match the delivered files — reconciled to 18 `tests/graph.rs` + 12 `tests/stream.rs` + 5 inline `stream.rs` tests (post-patch numbers).
  - `[low]` `[patch]` `walk_graph_prioritize_of_a_non_working_copy_branch_emits_that_branch_first` bundled two scenarios (under-a-merge → no reorder; three heads → B first) under a name describing only the second — split into `walk_graph_prioritize_under_a_merge_cannot_reorder_the_merges_parent_branches` and `walk_graph_prioritize_of_a_non_working_copy_head_emits_that_branch_first` (shared `node_position` helper).
  - `[low]` `[patch]` `stream_lanes_tiny_all_without_prioritize_honours_the_parameter` only asserted `first != @` — now also pins `first == c3` like its `walk_graph` twin.
  - `[low]` `[patch]` `walk_graph_mid_stream_store_failure_returns_jj_lib_error` silently depends on jj-lib 0.42.0 internals (index answers `all()` without object reads; `description()` reads lazily) — comment names the assumption and the pin so the next bump knows why it might move.
  - `[low]` `[patch]` `GraphNode::id` doc said "Git-SHA form" (commit ids are hex for any backend) — now "Hex commit id".
  - `[low]` `[patch]` `api_stability.rs` comment "count unchanged at 30" read oddly right after the block that added the three types — reworded to "still 30 after graph".

## Design Notes

- **Mapping owner = `zanshin-graph` depends on `zanshin-jj`** (`ffi → graph → jj`). Rationale: the planning docs place the on-demand lane computation in `zanshin-graph` (`architecture.md:444` `cache.rs` → stream; epic context "4.4 `slice.rs` builds on 4.3"); `zanshin-ffi` (4.6) then calls one function (`stream_lanes`) instead of composing stream + assigner itself; `lane.rs` stays a pure algorithm module (no jj dep leaks into it). Rejected: (a) aggregator mapping in `zanshin-ffi` — leaves "lane computation on demand" homeless until 4.6 and makes 4.4's `slice.rs` unable to reach a repo; (b) `zanshin-jj` depending on `zanshin-graph` — inverts the layering (the ACL crate would own a rendering concern).
- **Why a visitor callback, not a returned iterator:** `evaluate()` yields `Box<dyn Revset + 'index>` borrowing the freshly loaded `ReadonlyRepo`, and `stream_graph()` borrows that box — a returned lazy iterator would be self-referential (needs `ouroboros`/`self_cell` or a two-level public snapshot handle). Internal iteration (`FnMut(..) -> ControlFlow<()>`, like `Iterator::try_for_each`) keeps the stream lazy and early-exit capable with zero new deps and one public entry point; 4.4 collects via the sink, future paging breaks early.
- **Why `stream.rs`, not `cache.rs`:** there is no cache (ADR-0002 AC-4); naming a non-cache `cache.rs` would mislead every future reader. The sprint key keeps its historical name; architecture.md line 444 is updated.
- **Walk sketch (`crates/zanshin-jj/src/graph.rs`):**
  ```rust
  let readonly = pollster::block_on(repo.workspace().repo_loader().load_at_head()).map_err(..JjLibError)?;
  let repo_dyn: &dyn jj_lib::repo::Repo = readonly.as_ref();
  let log = parse_revset(repo, revset)?;
  let prio = parse_revset(repo, prioritize)?.intersection(&log);   // CLI: prio & log, BEFORE resolution
  let set = evaluate_revset(repo_dyn, &log)?;
  let prio_ids: Vec<CommitId> = pollster::block_on(evaluate_revset(repo_dyn, &prio)?.stream().try_collect()).map_err(..)?;
  let as_id: for<'a> fn(&'a CommitId) -> &'a CommitId = |id| id;
  let mut topo = TopoGroupedGraph::new(set.stream_graph(), as_id);
  prio_ids.into_iter().for_each(|id| topo.prioritize_branch(id));
  pollster::block_on(async { let mut s = pin!(topo.stream()); while let Some(item) = s.next().await { let (id, edges) = item.map_err(..)?; if visit(to_node(id, edges)).is_break() { return Ok(ControlFlow::Break(())); } } Ok(ControlFlow::Continue(())) })
  ```
- **Tiny lane trace with `present(@)`** (hand-traced against 4.1 rules): `@` → no reservation → lane 0; edge→root reserves lane 0 for root. `c3` → lane 1 (lane 0 reserved); edge→c2 reserves lane 1. `c2` → lane 1 → reserves lane 1 for c1. `c1` → lane 1 → first edge reserves OWN lane 1 for root (root now reserved at lanes 0 and 1). `root` → leftmost = lane 0, lane 1 freed, no edges. With `none()` c3's branch is emitted first (`TopoGroupedGraph`: "the branch containing the first commit in the input iterator will be emitted first"; the revset stream yields newest index position first = c3).
- **jj-lib kind order differs** (`Missing, Direct, Indirect`) from ours (`Direct, Indirect, Missing`, pinned by 4.1 `EdgeKind` and 4.2's `.fbs`) — map by exhaustive `match`, never by discriminant.

## Verification

**Commands:**
- `cargo test -p zanshin-jj --test graph --test revset --test api_stability` -- expected: green (fast inner loop for the jj side).
- `cargo test -p zanshin-graph` -- expected: green (`tests/lane.rs` untouched + new `tests/stream.rs` + inline tests).
- `cargo clippy --workspace --all-targets -- -D warnings` and `cargo fmt --all --check` -- expected: clean without any new `#[allow]`.
- `cargo make test` (unpiped) -- expected: exit 0; coverage summary lists `crates/zanshin-jj/src/graph.rs` and `crates/zanshin-graph/src/stream.rs` ≥ 80.00, no regressions; `coverage-baseline.txt` updated → commit it.
- `git status --porcelain` after the commit -- expected: empty.

## Auto Run Result

Status: done

Finalization note: the resumed run's final commit initially could not be written — SSH commit signing through the 1Password agent failed four times in the unattended session (`error: 1Password: failed to fill whole buffer` ×3, `error: 1Password: agent returned an error` ×1; `commit.gpgsign=true`, `gpg.format=ssh`, `gpg.ssh.program=op-ssh-sign`), so the run temporarily HALTed `blocked` / `finalization left repository dirty` with every changed file staged. No unsigned commit was made (every commit on `main` is SSH-signed). The staged change set was committed unchanged once signing was available again (subject `fix(zanshin-graph): apply Story 4.3 second review pass; mark done`); nothing else was outstanding.

**Run history.** The first run implemented the story (commit `84612b2`, 2026-08-22) and ran a review pass whose patches P1–P9 landed in `2f4d0c0` (`fix(zanshin-graph): apply Story 4.3 review findings`: `prioritize` resolution-error tests at both surfaces, mid-stream store-failure `JjLibError` test, non-working-copy-branch prioritisation test on medium, epic-4-context crate-boundary rewording, Code Map cites `git -C ../jj show v0.42.0:cli/src/commands/log.rs`, root `Cargo.toml` `futures` WHY, order-asserting prio-outside-revset test, `Repo::walk_graph`/`stream_lanes`/README rustdoc on `none()`/blank/materialisation/no-retraction/no-locking, inline `LaneStreamError` transparency test) but was cut off by a session limit before the triage log, this section and `status: done` were written — that pass has no triage-log entry; its scope is recorded here and in the `2f4d0c0` commit message. This resumed run (2026-08-23, `status: in-review` → step-04) re-reviewed the full diff since `baseline_revision` (`84612b2` + `2f4d0c0`) with the four layers and finalized.

**Summary of implemented change.** Story 4.3 delivered as the ADR-0002 lazy stream, not a cache: (1) `zanshin-jj` gained the jj-lib-free revset graph stream `Repo::walk_graph(revset, prioritize, visit) -> Result<ControlFlow<()>, RevsetError>` (`src/graph.rs`: `GraphNode`/`GraphEdge`/`GraphEdgeKind`, `DEFAULT_GRAPH_PRIORITIZE = "present(@)"`) on the exact `jj log` v0.42.0 pipeline (`TopoGroupedGraph::new(set.stream_graph(), |id| id)` + `prioritize_branch` for every commit of `prioritize ∩ revset`, intersected as user expressions before resolution), re-resolved to head per call, lazy with early exit; `revset.rs` split into crate-private `parse_revset` + `evaluate_revset` shared with `resolve_revset` (behaviour unchanged). (2) `zanshin-graph` gained `src/stream.rs`: `stream_lanes(repo, revset, prioritize, sink) -> Result<ControlFlow<()>, LaneStreamError { Revset, Graph }>` = `drive_lanes` over `Repo::walk_graph` → `From` mapping → `LaneAssigner::push` → sink, `finish()` only when exhausted. Mapping-owner decision: `zanshin-graph` depends on `zanshin-jj` (`ffi → graph → jj`, no `jj_lib` in `zanshin-graph`). No cache/rebuild/memoization, no FFI/.fbs/codegen/Dart, no collect-all/paging, `lane.rs` and `zanshin-ffi/src/graph.rs` untouched, no new `error.code`.

**Files changed (since `4e679cb`).**
- `crates/zanshin-jj/src/graph.rs` (new) — types, `DEFAULT_GRAPH_PRIORITIZE`, `walk_graph` (parse → load head → evaluate → topo-group + prioritise → drive into visitor), inline `edge_kind` test.
- `crates/zanshin-jj/src/revset.rs` — `parse_revset` + `evaluate_revset` extracted; `resolve_revset` rewired.
- `crates/zanshin-jj/src/repo.rs` — public `Repo::walk_graph` (rustdoc: parity, pass-through, `none()`, blank = ParseError, materialised prio set, no retraction, no locking).
- `crates/zanshin-jj/src/lib.rs` — `pub(crate) mod graph` + re-exports.
- `crates/zanshin-jj/tests/graph.rs` (new, 18 tests) — order/kinds/invariants/early exit/empty/re-derive/prio-outside/errors (parse incl. blank, resolution, corrupt op_heads, mid-stream store failure)/prioritisation on medium.
- `crates/zanshin-jj/tests/api_stability.rs` — 27 → 30 types, value constructions, `DEFAULT_GRAPH_PRIORITIZE == "present(@)"`.
- `crates/zanshin-jj/README.md` — "Graph stream (`Repo::walk_graph`)" section.
- `crates/zanshin-graph/Cargo.toml` — `+zanshin-jj` dep, `+test-helpers` dev-dep; `Cargo.lock` accordingly.
- `crates/zanshin-graph/src/stream.rs` (new) — `LaneStreamError`, `From` impls, `stream_lanes`, crate-private `drive_lanes`, 5 inline tests.
- `crates/zanshin-graph/src/lib.rs` — `mod stream`, re-exports, crate-doc states the mapping decision.
- `crates/zanshin-graph/tests/stream.rs` (new, 12 tests) — hand-traced tiny rows (both prio values), Missing stubs, Indirect edge, medium invariants + determinism, Break skips finish, empty, parse (incl. blank)/resolution errors as `LaneStreamError::Revset`.
- `Cargo.toml` — `futures` WHY comment names the consumers.
- `coverage-baseline.txt` — `graph.rs = 100.00`, `stream.rs = 100.00` (new rows), `repo.rs 91.43 → 91.80`.
- `_bmad-output/planning-artifacts/epics.md` (§4.3 dated Delivered note), `architecture.md:444` (`cache.rs` → `stream.rs`), `_bmad-output/implementation-artifacts/deferred-work.md` (4.3 delivered), `epic-4-context.md` (4.3 done + mapping decision; edited last), `sprint-status.yaml` (4-3 → done + `last_updated`), this spec.

**Review findings breakdown (this pass).** 32 raw findings from 4 layers (Blind Hunter 18, Edge Case Hunter 3, Verification Gap 4, Intent Alignment 7 descriptive divergences) → 28 unique → 0 intent_gap, 0 bad_spec, 10 patch (1 medium, 9 low — all applied, see Review Triage Log), 2 defer (frontmatter `deferred`: stale `output.rs # FR-GR-2 JSON` line in architecture.md; hygiene gate does not mechanically cover `zanshin-graph`'s no-`jj_lib` invariant), 16 reject. Rejected (not this story's problem / noise): spec I/O matrix not listing the superset tests (extra tests are additive evidence, intent-contract untouched); "done" wording in planning docs vs `review` in sprint-status (resolved by this finalize); `ControlFlow<B>` generic callbacks (intent pins `ControlFlow<()>`); op-id exposure for 4.4/4.6 paging (those stories' concern, already tracked in deferred-work); `test-helpers` path-dep style (not a workspace dep; mirrors zanshin-jj); triplicated `pin_env` scaffolding (spec mandated the mirror; refactor out of scope); duplicated `RevsetExtensions::default()`; `#[must_use]` symmetry (`Result` is must_use; repo.rs convention); `jj()` helper name; `prioritize = all()` materialisation and deep-non-head buffering (jj CLI does the same — parity, documented in rustdoc); possible `Direct`+`Indirect` edges to one target (jj-lib output passed through; `LaneAssigner` reservations are idempotent; 4.1 contract says edges are not 1:1 per parent); CLI parity proven by pipeline identity + hand-traced orders rather than a `jj log` oracle (shelling to jj is banned; the matrix spells the orders out); laziness/`resolve_revset`-guard/process-surface observations (descriptive, by design).

**Follow-up review recommendation.** `followup_review_recommended: true` — patched this pass: high 0, medium 1, low 9 → score 3 × 1 + 9 = 12 ≥ 5.

**Verification performed.** `cargo fmt --all --check` clean; `cargo clippy --workspace --all-targets -- -D warnings` clean (no new `#[allow]`); `cargo test -p zanshin-jj --test graph --test revset --test api_stability` green (18 / 15 + 1 ignored pre-existing perf test / 1); `cargo test -p zanshin-graph` green (13 inline incl. 5 in `stream.rs`, 20 `tests/lane.rs`, 12 `tests/stream.rs`); full gate `cargo make test` unpiped after the patches → exit 0 in 209 s (cargo test workspace, clippy pedantic, fmt, flutter test, dart analyze/format, cargo deny, jj-adapter hygiene, coverage ratchet): `coverage-check: OK — coverage held at 98.63% (3104/3147 lines over 29 files)`, `coverage-baseline.txt` unchanged (`graph.rs`/`stream.rs` stay 100.00, `revset.rs`/`lane.rs` 100.00, no regression), `extern-coverage: OK`; `flutter`/`dart` gate churn (`app/analysis_options.yaml`, `pubspec.lock`) reverted, not committed.

**Residual risks.** (1) `walk_graph_mid_stream_store_failure_returns_jj_lib_error` encodes jj-lib 0.42.0 internals (annotated) — a pin bump may move where the failure surfaces. (2) The prioritised set `prioritize ∩ revset` is materialised before streaming (CLI-identical; documented "keep it small") — a UI-supplied `prioritize = all()` would materialise every id. (3) Visit order parity with `jj log` rests on pipeline identity with `cli/src/commands/log.rs` @ v0.42.0 plus hand-traced fixture orders, not on an independent oracle (shelling to jj is banned); re-verify the pipeline at the next pin bump. (4) The 4.2-era `output.rs` line in architecture.md and the unguarded `zanshin-graph` no-`jj_lib` invariant are deferred (frontmatter).
