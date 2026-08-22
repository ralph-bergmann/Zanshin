# Epic 4 Context: `zanshin-graph` — DAG Lane Assignment

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Compute commit-graph lane assignments for arbitrary jj DAGs (including working-copy and anonymous changes) and expose them to the Dart worker as render-ready FlatBuffers rows via the single `zanshin-ffi` cdylib. The graph is derived on demand from a lazy revset stream and re-derived whenever the op-heads advance, so a caller always gets a fresh, coherent graph without a held cache. This is what lets the (out-of-scope) Flutter UI draw a GitKraken/SourceTree-style graph that reflects external `jj` CLI / MCP mutations.

## Stories

- Story 4.1: Lane-assignment algorithm (`lane.rs`) — done
- Story 4.2: Graph output payload (originally JSON + schema; delivered standalone as the FlatBuffers `GraphSlice` payload — schema + Rust builder `zanshin-ffi/src/graph.rs` + Dart models/decoder `packages/zanshin_core/lib/src/ffi/graph.dart`; extern fn + worker command stay in 4.6) — done
- Story 4.3: Lane computation on demand (`cache.rs`) — now the lazy revset stream wiring
- Story 4.4: Return-all-lanes-for-revset API (`slice.rs`)
- Story 4.5: 10k-commit performance test — DELETED (WIP)
- Story 4.6: FFI wrapper (`zanshin-ffi/src/graph.rs`)
- Story 4.7: Checkpoint-caching for very large repos — DELETED (deferred post-0.1)

## Requirements & Constraints

- **Lane output.** Every node in the requested revset gets one row with a lane number, per-parent edge routing (target + target lane, absent when the parent is outside the set) and a deterministic small-palette color index; "straight branches" strategy (a branch keeps its lane until it merges; forks take a free lane; merges reclaim). Octopus merges and multiple roots must not panic. Rows are keyed by commit id (change ids are ambiguous for divergent changes); display metadata joins later.
- **Superseded planning wording — current constraints:**
  - Transport is FlatBuffers, not JSON: the graph crosses FFI as a `GraphSlice` payload type in the `Envelope` `Payload` union defined in `schemas/*.fbs`; no `schema_version`, no `.v1` infix, edit in place and regenerate (`cargo make codegen`). Story 4.2/4.6 JSON-Schema / `jsonschema` acceptance text is obsolete; tests read via generated typed accessors + the `Verifier`.
  - No materialized or persistent lane cache: the graph is streamed lazily from the head-resolved repo and re-derived on op-id advance. Story 4.3/4.6 `LaneCache::build/rebuild`, "rebuild on every op_heads change", and "close the old graph handle" text is obsolete; the op-heads watcher triggers a re-derive, it does not invalidate a held cache. Measured baseline: full 10k graph derive ~3 ms, first 100-row page ~27 µs — lane assignment must stay O(1)/node with no graph buffering to preserve this.
  - The epic text for 4.3 / 4.4 / 4.6 still carries the old framing; these three stories need their specs re-authored to the stream model at create-story time (tracked in deferred-work).
- **Slice semantics (WIP).** One call returns all lanes for the resolved revset; windowing/pagination is deferred. Whatever paging exists must be O(returned rows), never a scan of the full graph; out-of-range start / oversized count clamp rather than panic.
- **Performance.** NFR budgets (< 1 s graph derive at 10k, < 2 s repo open) are soft targets; no perf gate, no large-fixture perf test in WIP. The only mandated correctness check is the ~100-commit algorithmic test (already in 4.1).
- **Parity / pass-through.** Row order inherits `jj log`'s observable order (same topo-grouped stream pipeline); the revset and branch-prioritization parameters are caller-supplied pass-throughs, not baked-in defaults. Lane drawing itself is GUI UX, not a CLI-parity concern.
- **Anti-speculation.** Do not emit per-row pass-through-lane info or other "the UI might want it" data until the UI asks.

## Technical Decisions

- **Crate boundaries.** `zanshin-graph` is a pure algorithm crate: no `jj_lib`, no fixtures, no FFI. Only `zanshin-jj` may import `jj_lib`, so the revset → topo-grouped graph stream (`stream_graph` + `TopoGroupedGraph`, GG model; runnable blueprint in `crates/zanshin-jj/benches/graph_blueprint.rs`) lives in `zanshin-jj`. Who maps that stream into `zanshin-graph`'s input types (graph depends on jj vs. the `zanshin-ffi` aggregator mapping) is Story 4.3's decision.
- **Repo state model.** Reads re-resolve to head (`load_at_head`) per operation; derived graph state may be memoized only within one resolved op-id, never across an advance. Worker isolate is the single consumer — no `Arc<Mutex>`, no internal locking.
- **FFI surface (4.6).** `zanshin_graph_*` extern fns in `crates/zanshin-ffi/src/graph.rs`, fallible calls return the FlatBuffers `Envelope`, any handle/correlation crosses as a `u64` scalar inside the payload, `start`/`count` stay plain `u32`. Regenerate `zanshin_ffi.h` + `bindings.dart` via `cargo make codegen` and commit. Add typed `WorkerCommand` subclasses in the Dart worker. No `unwrap`/`expect`/`panic!` on FFI-reachable paths — the `expect()` in `lane.rs` index/lane-number helpers becomes reachable in 4.6 and must be resolved then (deferred-work). Error codes use the `graph.*` domain and go into `docs/rust-error-codes.md`; extend the existing `docs/ffi-abi.md` § "GraphSlice payload (Story 4.2)" section (payload shapes are already documented there — add the extern fn signatures / error codes). The payload builder `zanshin_ffi::graph::graph_slice_to_envelope` and the Dart decoder `decodeGraphSliceEnvelopeInternal` already exist (4.2); 4.6 calls them rather than re-deriving the payload.
- **Schema/codegen gotcha.** `verify-codegen` is hard-coded to the envelope files; if the graph payload lands as a separate `.fbs`, generalize the drift check (deferred-work).
- **Coverage ratchet.** New Rust files ≥ 80 % line coverage; each new extern fn needs a real-cdylib test in `packages/zanshin_core` or the ratchet flags it. Unit tests inline, integration tests in `tests/`, no timing assertions.
- **Stack.** `jj-lib` pinned `=0.42.0`; `flatbuffers` `=25.12.19` / Dart `flat_buffers`; watcher debounce 50 ms (bursts coalesce before a re-derive).

## UX & Interaction Patterns

Target rendering is a GitKraken/SourceTree-style lane graph drawn by the out-of-scope Flutter UI: stable lane per branch, stable color per lane, elided-ancestor (`Indirect`) edges drawn dashed, out-of-set (`Missing`) parents as stubs. The backend exposes the data; it makes no layout/theme decisions.

## Cross-Story Dependencies

- 4.1 (done) supplies the streaming `LaneAssigner`; 4.3 feeds it from `zanshin-jj`'s revset stream and depends on Epic 2 revset resolution + Story 3.11's head-resolved repo model; 4.4 builds on 4.3.
- 4.2 (done) supplies the `GraphSlice` payload builder + Dart decoder that 4.6's wrapper calls; 4.6 needs Story 3.6's event dispatch (op-heads change → re-derive) and Story 3.9's worker isolate/command bus.
- Epic 9's generic `eval_revset` read joker (ADR-0003) shares the streamed-revset ground with 4.3/4.4 — keep the stream mapping reusable.
- Sequencing: after Epic 3; parallelizable with Epics 5 and 6.
