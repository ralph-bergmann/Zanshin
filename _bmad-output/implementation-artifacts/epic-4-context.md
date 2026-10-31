# Epic 4 Context: `zanshin-graph` — DAG Lane Assignment (2026-10-01: the lane crate was removed in 4.12)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Supply the commit-graph's data and layout from jj. Stories 4.1–4.9 built a `jj log`-parity lane graph, which 4.12 removed: the commit-graph view (Epic 10) draws the design's layered layout (rows shared by several commits, packed lanes, routed orthogonal edges), computed in pure Dart on `zanshin_core`'s worker isolate. The epic delivers the whole revset's index-only topology plus op-pinned lazy card content (4.10), its compact wire and lazy Dart view (4.12), the layout engine (4.11) with commit stacks (4.13), one shared set of columns for Free and Compact (4.14), line router B as a `zanshin_core` library (4.15), and — now — Free's guarantee that no card sits in the band around a day divider (4.16).

## Stories

- Story 4.1: Lane-assignment algorithm (done; removed in 4.12)
- Story 4.2: GraphSlice FlatBuffers payload (done; removed in 4.12)
- Story 4.3: Lane computation on demand — lazy revset stream (done)
- Story 4.4: Return-all-lanes-for-revset API (done; removed in 4.12)
- Story 4.5: 10k-commit performance test (deleted)
- Story 4.6: FFI wrapper `zanshin_graph_slice` (done; removed in 4.12)
- Story 4.7: Checkpoint-caching for very large repos (deleted)
- Story 4.8: CLI-parity log rows (done)
- Story 4.9: Honor jj config revset aliases + effective log defaults (done)
- Story 4.10: Index-only topology call + op-pinned batch content lookup (done)
- Story 4.11: Dart layout engine on the worker isolate (done)
- Story 4.12: Topology wire, lazy Dart view, id lookups, one copy across isolates (done)
- Story 4.13: Commit stacks in the layout engine (done)
- Story 4.14: Shared columns — one lane packing and column order for Free and Compact (done)
- Story 4.15: Line router B — one line per parent → child pair, as a `zanshin_core` library (done)
- Story 4.16: Free — no card in the band around a day divider (done)

## Requirements & Constraints

- **Complete topology per operation, lazy content per page.** No row-range windowing. Card content loads per visible page, pinned to the topology's operation, and writes nothing.
- **Pass-through, never decide:** revset, anchors, mode, lane order and budget are caller arguments; Rust bakes in no default. `zanshin_core` exports editable pre-fills.
- **Null for absence;** decoders throw on a missing required field.
- **Product layout scope:** modes `free` (default) and `compact`; lane orders `compact` (default) and greedy. `time` and `optimized` are dropped. No lane-order control in the UI.
- **The layout is independent of card width and height** (W, H never appear in a layout request); requested once per operation, never on resize. Route geometry is a separate stage keyed by the metrics.
- **Columns never move for presentation switches:** stack toggles, "Group stacks" and Free ↔ Compact move cards only vertically (I7, I8).
- **Free's day bands are card-free (4.16):** when the day key changes between consecutive y-ordered visible nodes, the newer day's oldest node sits at least one pitch (16 units) above the older day's newest node, in any column; nodes above shift up with it (y stays monotone in time within a day). `rows` grows only at such boundaries; a boundary between cards already a pitch apart changes nothing. Stacks and the root follow the existing free-walk treatment. Compact's rows (no days) are untouched, though its joint lanes and columns can follow the free model (I8 holds); the painter's divider stays midway.
- **Deterministic integer engine:** byte-identical to `docs/graph-layout.md` (GLD); total sort keys; floor division; budget "stops the phase".
- **No elided counts** anywhere. No timing assertions in tests.

## Technical Decisions

- **GLD is the engine's contract.** Every behavioural change is a dated GLD amendment first, implemented in the spike's Dart reference (`spikes/graph-layout-ab/dart/`) and its recorder, then ported byte-identically into `packages/zanshin_core/lib/src/graph_layout/`; goldens regenerated with the recorder (`node tools/goldens.mjs`), every changed golden listed with its reason in the spec. Dart-only features (the `compact` order, stacks, joint columns) have no Rust reference.
- **Relevant GLD parts:** §2 input, §4.2 layering (compact y = generation rows; free y = clamped time, U = 16, gap curve, cap 48 units, one pitch per edge, then stacks in step 4; 4.14 added a day key dk per node), §4.3 joint lane packing, §4.7 the `compact` order, §4.8 stacks, §7.3 invariants I1–I8 (I5 = free's day buckets), §9 known limits (the midnight overlap is one; 4.16 closes it), §13 the product engine (core imports only `dart:typed_data`, `package:meta`, itself), §14 routing.
- **Day keys:** grid format v3/v4 carry `nodeDays` (dk of the clamped T, both modes; root = `GraphGridView.noDay`; a stack = its newest member's). The invariant checker `layout_invariants` (core) and the app's `checkLayoutInvariants` must both learn 4.16's I5 extension.
- **Standing rules:** no type named `GraphLayout` or `GraphRef` in `packages/`; engine types stay out of the `lib/zanshin_core.dart` barrel except the router's; a run that decides something new appends it to `decisions-review-4-10-to-4-13.md` under its own `### 4.x` heading.
- **Engine guardrails:** flat typed arrays and CSR, no per-node objects or maps on hot paths, hand-written monomorphic sorts (never `List.sort`), tunables `const` or request parameters, worker stays `Isolate.spawn`ed. Contract violations throw `LayoutContractException` (V1–V5), never a repaired layout.
- **Router B (4.15):** `router.dart`, class stage per layout (no W/H), geometry per `RouteMetrics`, `bridges(...)` window query; UI side, synchronous up to `routeSyncNodeLimit` = 20,000, `Isolate.run` above, never a worker request. Engine `route` / `blocked` and goldens unaffected by it.
- **Worker / wire:** `RepoHandle.graphLayout(...)` re-runs the topology per request (ADR-0002: no state in worker or handle), replies with `GraphTopologyView` + `GraphGridView` as one `TransferableTypedData` each, and loads timestamps for every request.
- **Rust side (stable):** only `zanshin-jj` imports `jj_lib`; externs only in `zanshin-ffi`; FlatBuffers envelope, regenerate with `cargo make codegen`; jj reference pin `v0.46.0`.
- **Tests and coverage:** the ratchet is Rust-only, so Dart engine tests are the safety net: unit tests, goldens, invariants on ≥ 1,000 seeded DAGs, real-cdylib worker tests. Fixtures are committed and never regenerated. Dev tools stay outside the gate.

## UX & Interaction Patterns

The view never decides rows, columns, route classes, buckets or a free y — it maps the engine's output and the router's geometry to pixels. Day dividers (10.2) are painted midway between the older day's newest and the newer day's oldest card; after 4.16 that band never holds a card, so a "Today" label never covers yesterday's card. Indirect edges draw dashed, Missing edges as stubs, without counts.

## Cross-Story Dependencies

- 4.16 depends on 4.11, 4.13 and 10.2 (all done); related to 10.12 (real layout in the app) and 10.13 (the view-side time-gap variant, a non-goal here). Its docs step closes deferred-work.md's "Day dividers can cross cards around midnight" bullet and amends GLD §4.2 and §9.
- 4.16's witnesses: a hand case of the demo (23:50 in one column, 00:10 in another) leaves the divider's band card-free; a same-column boundary already a pitch apart is unchanged; the invariant fails on a layout without the gap; recorded goldens pass.
- Earlier witnesses stay in force: I8 (lane, col, `lanes`, day keys identical in compact and free output), I1–I7 in both modes, the design oracles (`tools/design-layout.mjs`, `tools/router-oracle.mjs`) and the `compare.mjs --core` byte-identity of product vs spike.
- Epic 10 consumers: 10.1 (`GraphLayout` contract, invariant checker), 10.2 (day axis), 10.4 (edges), 10.12, 10.16 (minimap labels via `nodeDays`), 10.17 (stack view), 10.19 (gaps). The watcher's `OpHeadsChanged` triggers a re-request; one worker serves every handle, so rely on 10.5's coalescing.
