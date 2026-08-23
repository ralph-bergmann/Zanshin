# Epic 4 Context: `zanshin-graph` — DAG Lane Assignment

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Compute commit-graph lane assignments for arbitrary jj DAGs (including working-copy and anonymous changes) and expose them to the Dart worker as render-ready FlatBuffers rows via the single `zanshin-ffi` cdylib. The graph is derived on demand from a lazy revset stream and re-derived whenever the op-heads advance, so a caller always gets a fresh, coherent graph without a held cache. This is what lets the (out-of-scope) Flutter UI draw a GitKraken/SourceTree-style graph that reflects external `jj` CLI / MCP mutations.

## Stories

- Story 4.1: Lane-assignment algorithm (`lane.rs`) — done
- Story 4.2: Graph output payload (originally JSON + schema; delivered standalone as the FlatBuffers `GraphSlice` payload — schema + Rust builder `zanshin-ffi/src/graph.rs` + Dart models/decoder `packages/zanshin_core/lib/src/ffi/graph.dart`; extern fn + worker command stay in 4.6) — done
- Story 4.3: Lane computation on demand (delivered as the lazy revset stream: `zanshin_jj::Repo::walk_graph` + `zanshin_graph::stream_lanes` in `crates/zanshin-graph/src/stream.rs` — no `cache.rs`, no cache) — done (reviewed 2026-08-23)
- Story 4.4: Return-all-lanes-for-revset API (`slice.rs`) — done (delivered 2026-08-23 as `zanshin_graph::collect_lanes(repo, revset, prioritize) -> Result<Vec<Row>, LaneStreamError>` in `crates/zanshin-graph/src/slice.rs`: a collecting sink over `stream_lanes`; no `LaneCache`/`render_slice`, no `start`/`count`/`limit`/`reversed`, no `total_rows` field)
- Story 4.5: 10k-commit performance test — DELETED (WIP)
- Story 4.6: FFI wrapper (`zanshin-ffi/src/graph.rs`) — done (delivered 2026-08-23 as ONE extern fn `zanshin_graph_slice(handle, revset, prioritize) -> *mut ZanshinBuf` over `collect_lanes` + Dart `GraphSliceCommand` / `ZanshinWorker.graphSlice` / `RepoHandle.graphSlice`; no `_build`/`_close`/graph handle, no `start`/`count`, no worker auto-re-derive)
- Story 4.7: Checkpoint-caching for very large repos — DELETED (deferred post-0.1)

## Requirements & Constraints

- **Lane output.** Every node in the requested revset gets one row with a lane number, per-parent edge routing (target + target lane, absent when the parent is outside the set) and a deterministic small-palette color index; "straight branches" strategy (a branch keeps its lane until it merges; forks take a free lane; merges reclaim). Octopus merges and multiple roots must not panic. Rows are keyed by commit id (change ids are ambiguous for divergent changes); display metadata joins later.
- **Superseded planning wording — current constraints:**
  - Transport is FlatBuffers, not JSON: the graph crosses FFI as a `GraphSlice` payload type in the `Envelope` `Payload` union defined in `schemas/*.fbs`; no `schema_version`, no `.v1` infix, edit in place and regenerate (`cargo make codegen`). Story 4.2/4.6 JSON-Schema / `jsonschema` acceptance text is obsolete; tests read via generated typed accessors + the `Verifier`.
  - No materialized or persistent lane cache: the graph is streamed lazily from the head-resolved repo and re-derived on op-id advance. Story 4.3/4.6 `LaneCache::build/rebuild`, "rebuild on every op_heads change", and "close the old graph handle" text is obsolete; the op-heads watcher triggers a re-derive, it does not invalidate a held cache. Measured baseline: full 10k graph derive ~3 ms, first 100-row page ~27 µs — lane assignment must stay O(1)/node with no graph buffering to preserve this.
  - The epic text for 4.3 / 4.4 / 4.6 still carries the old framing; these three stories need their specs re-authored to the stream model at create-story time (tracked in deferred-work).
- **Slice semantics (WIP).** One call returns all lanes for the resolved revset — delivered as `collect_lanes` (Story 4.4), a collect-all over the lazy `stream_lanes` stream; windowing/pagination is deferred. If paging ever returns it composes as an early-exit sink on `stream_lanes` (O(returned rows), never a scan of a held graph) and its out-of-range start / oversized count must clamp rather than panic — today no such parameters exist. The CLI's `--limit`/`--reversed` were deliberately not passed through (presentation/paging knobs dropped with windowing; a consumer wanting a prefix uses `stream_lanes` + `Break`); revisit when windowing returns.
- **Performance.** NFR budgets (< 1 s graph derive at 10k, < 2 s repo open) are soft targets; no perf gate, no large-fixture perf test in WIP. The only mandated correctness check is the ~100-commit algorithmic test (already in 4.1).
- **Parity / pass-through.** Row order inherits `jj log`'s observable order (same topo-grouped stream pipeline); the revset and branch-prioritization parameters are caller-supplied pass-throughs, not baked-in defaults. Lane drawing itself is GUI UX, not a CLI-parity concern.
- **Anti-speculation.** Do not emit per-row pass-through-lane info or other "the UI might want it" data until the UI asks.

## Technical Decisions

- **Crate boundaries.** `zanshin-graph` has no `jj_lib` and no FFI; `lane.rs` stays a fixture-free pure algorithm, while `stream.rs` is tested against the committed fixtures through `zanshin_jj` + `test-helpers` (dev-dep). Only `zanshin-jj` may import `jj_lib`, so the revset → topo-grouped graph stream (`stream_graph` + `TopoGroupedGraph`, GG model; runnable blueprint in `crates/zanshin-jj/benches/graph_blueprint.rs`) lives in `zanshin-jj` as `Repo::walk_graph(revset, prioritize, visit)` (Story 4.3). **Mapping owner (decided in 4.3): `zanshin-graph` depends on `zanshin-jj`** (`zanshin-ffi` → `zanshin-graph` → `zanshin-jj`, no cycle, still no `jj_lib` in `zanshin-graph`); `zanshin_graph::stream_lanes(repo, revset, prioritize, sink)` maps the stream into the 4.1 input types and drives the `LaneAssigner`. 4.4's `slice.rs` (`collect_lanes`) calls `stream_lanes`, and 4.6's FFI wrapper calls `collect_lanes` — never the stream + assigner separately.
- **Repo state model.** Reads re-resolve to head (`load_at_head`) per operation; derived graph state may be memoized only within one resolved op-id, never across an advance. Worker isolate is the single consumer — no `Arc<Mutex>`, no internal locking.
- **FFI surface (4.6) — delivered as `zanshin_graph_slice`.** ONE extern fn `zanshin_graph_slice(handle: u64, revset: *const c_char, prioritize: *const c_char) -> *mut ZanshinBuf` in `crates/zanshin-ffi/src/graph.rs`: borrows the `RepoSession`, passes both caller-supplied expressions through to `collect_lanes`, returns the 4.2 builder's `Envelope<GraphSlice>` (no `start`/`count` scalars — 4.4 delivered return-all; no graph handle / `_build` / `_close` — ADR-0002 AC-4; `schemas/envelope.fbs` untouched). `zanshin_ffi.h` + `bindings.dart` regenerated via `cargo make codegen` and committed. Dart: `GraphSliceCommand(handleId, revset, prioritize)` + `ZanshinWorker.graphSlice` + `RepoHandle.graphSlice({revset, prioritize = defaultGraphPrioritize})` (CLI default `present(@)` pre-filled, editable; `none()` = no prioritisation). The `lane.rs` `expect()` decision: KEEP (infallible on 64-bit; `catch_unwind` backstop) — recorded as a `// WHY:` at the site and closed in deferred-work. Error codes (registry `docs/rust-error-codes.md`): `jj.revset_parse_error`, `jj.revset_resolution_error` (domain `jj` — `RevsetError` is `zanshin-jj`'s; reusable by Epic 9's `eval_revset`), `graph.dangling_edge` (first and only `graph.*` code; upstream-stream contract violation, unreachable with real fixtures), plus the existing `ffi.invalid_handle` / `ffi.null_pointer` / `ffi.utf8_error` / `jj.jj_lib_error`. `docs/ffi-abi.md` § "GraphSlice payload (Story 4.2) and `zanshin_graph_slice` (Story 4.6)" carries the signature, parameter semantics, error table, and worker integration. The 4.4-deferred re-derive-after-external-op proof lives at the FFI surface (`crates/zanshin-ffi/tests/graph_ffi.rs`) via `test_helpers::add_commit_off_root` (jj-lib write helper; `test-helpers` is a test-only tool crate like `xtask`).
- **Schema/codegen gotcha.** `verify-codegen` is hard-coded to the envelope files; if the graph payload lands as a separate `.fbs`, generalize the drift check (deferred-work).
- **Coverage ratchet.** New Rust files ≥ 80 % line coverage; each new extern fn needs a real-cdylib test in `packages/zanshin_core` or the ratchet flags it. Unit tests inline, integration tests in `tests/`, no timing assertions.
- **Stack.** `jj-lib` pinned `=0.42.0`; `flatbuffers` `=25.12.19` / Dart `flat_buffers`; watcher debounce 50 ms (bursts coalesce before a re-derive).

## UX & Interaction Patterns

Target rendering is a GitKraken/SourceTree-style lane graph drawn by the out-of-scope Flutter UI: stable lane per branch, stable color per lane, elided-ancestor (`Indirect`) edges drawn dashed, out-of-set (`Missing`) parents as stubs. The backend exposes the data; it makes no layout/theme decisions.

## Cross-Story Dependencies

- 4.1 (done) supplies the streaming `LaneAssigner`; 4.3 feeds it from `zanshin-jj`'s revset stream and depends on Epic 2 revset resolution + Story 3.11's head-resolved repo model; 4.4 builds on 4.3.
- 4.2 (done) supplies the `GraphSlice` payload builder + Dart decoder that 4.6's wrapper calls; 4.6 (done) rides Story 3.9's worker isolate/command bus, and Story 3.6's event dispatch (`OpHeadsChangedEvent`) is the UI's re-request trigger — not an automatic rebuild: the worker holds no graph state, every `graphSlice` call re-derives from head (ADR-0002).
- Epic 9's generic `eval_revset` read joker (ADR-0003) shares the streamed-revset ground with 4.3/4.4 — keep the stream mapping reusable.
- Sequencing: after Epic 3; parallelizable with Epics 5 and 6.
