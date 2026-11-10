# Epic 4 Context: `zanshin-graph` — DAG Lane Assignment (2026-10-01: the lane crate was removed in 4.12)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Supply the commit graph's data and layout from jj. The commit-graph view (Epic 10) draws a layered layout computed in pure Dart in `zanshin_core`, not `jj log`'s lanes. The topology, lazy card content, the layout engine with commit stacks and a line router are done. Stories 4.17 and 4.18 move the graph layout lab's column and line rules into the product, so the main branch stays in column 0, a branch keeps its column and lines stop lying on top of each other.

## Stories

- Story 4.1: Lane assignment (removed in 4.12)
- Story 4.2: GraphSlice payload (removed in 4.12)
- Story 4.3: Lazy revset stream (done)
- Story 4.4: All lanes for a revset (removed in 4.12)
- Story 4.5: 10k performance test (deleted)
- Story 4.6: FFI wrapper `zanshin_graph_slice` (removed in 4.12)
- Story 4.7: Checkpoint caching (deleted)
- Story 4.8: CLI-parity log rows (done)
- Story 4.9: jj config revset aliases and log defaults (done)
- Story 4.10: Index-only topology, op-pinned content (done)
- Story 4.11: Dart layout engine on the worker isolate (done)
- Story 4.12: Topology wire and lazy Dart view (done)
- Story 4.13: Commit stacks in the engine (done)
- Story 4.14: Shared columns (done; superseded by 4.17)
- Story 4.15: Line router B (done; superseded in part by 4.18)
- Story 4.16: Free: no card in the day-divider band (done)
- Story 4.17: Columns by branch, per mode (done)
- Story 4.18: Lines by the lab's rules (done)

## Requirements & Constraints

- **Complete topology per operation, lazy content per page.** Card content is pinned to the topology's operation and writes nothing.
- **Pass-through, never decide.** Revset, anchors and mode are caller arguments, and Rust bakes in no default.
- **Null for absence.** Decoders must throw on a missing required field. There are no elided counts.
- **Modes:** `free` (default) and `compact`. 4.17 removes `LaneOrder`, `order` and `budget` everywhere, so the request has no lane-order parameter.
- **The layout ignores card size.** It is requested once per operation, never on resize. Line geometry is a separate stage keyed by the card metrics.
- **Columns (4.17).** The lab's rule replaces the joint lane packing and the `compact` lane order. Free and Compact each choose their own columns, so invariant I8 (same columns in both modes) goes. The main branch is alone in column 0. A branch, a first-parent chain, keeps one column for its whole life. Two branches in one column keep one pitch between their reserved rows.
- **Stack toggles and "Group stacks" never move a column (I7).** Columns come from the requested mode's ungrouped layout.
- **Lines (4.18).** A line runs in its branch's column, never behind a card, and shares no stretch with another line. The lines that turn at one card edge always keep the order of their columns. Anything the rules cannot avoid must be counted and reported.
- **Free's day bands stay card-free.** Across a day change, the newer day's oldest card sits at least one pitch above the older day's newest card, in any column.
- **The engine is deterministic and integer-only:** same input, same bytes; total sort keys; floor division. Tests assert no timings.

## Technical Decisions

- **`docs/graph-layout.md` (GLD) is the engine's contract.** Every behavioural change must be a dated GLD amendment first. The spec lists every changed golden with its reason.
- **References (from 4.17).** The reference is the lab, `spikes/graph-layout-lab`: `lib/columns.dart` for columns, `lib/lines.dart` for lines. Goldens are recorded with the product CLI `packages/zanshin_core/benchmark/graph_layout_cli.dart`. The A/B spike's references (`spikes/graph-layout-ab`) no longer match and stay as history.
- **Standing rules.** No type named `GraphLayout` or `GraphRef` in `packages/`. Engine types stay out of the `lib/zanshin_core.dart` barrel, except the router's. A run that decides something new appends it to `decisions-review-4-10-to-4-13.md` under its own `### 4.x` heading.
- **Engine guardrails:** flat typed arrays and CSR offsets; no per-node objects or maps on hot paths; hand-written monomorphic sorts with total keys, never `List.sort`; tunables `const` or request parameters; the core imports only `dart:typed_data`, `package:meta` and itself; the worker stays `Isolate.spawn`ed. Contract violations throw `LayoutContractException`, never a repaired layout.
- **Router (`router.dart`).** 4.18 replaced router B's classes and tracks with the lab's line rules. Its output arrays, ports, shared entries, bridges and reports stay. A polyline can have up to 8 points, so consumers must assume no fixed count. It runs on the UI side: synchronous up to `routeSyncNodeLimit` (7,000 visible nodes), `Isolate.run` above, never a worker request.
- **Worker.** `RepoHandle.graphLayout(...)` re-runs the topology per request, keeps no state and loads timestamps for every request, because every day key needs them. One worker serves every repository, so a layout delays whatever is queued behind it.
- **Rust (stable).** Only `zanshin-jj` imports `jj_lib`; externs live only in `zanshin-ffi`. The jj reference pin is `v0.47.0`.
- **Tests.** Coverage is Rust-only, so Dart tests are the safety net: unit tests, goldens, invariants on at least 1,000 seeded DAGs, real-cdylib worker tests. Fixtures are committed and never regenerated.

## UX & Interaction Patterns

The view never decides rows, columns, line shapes, buckets or a free y. It maps the engine's and the router's output to pixels. A Free ↔ Compact switch re-centres on @, plays no transition and can move a card sideways.

## Cross-Story Dependencies

- 4.17 needs 4.11, 4.13, 4.14 and 4.16 (done). 4.18 needs 4.17, because its rules count on a branch's reserved column, and 4.15, 10.4, 10.19 and 10.30 (done).
- Witnesses that retire: I8, the joint design oracle and byte identity with the A/B spike (4.17); the router oracle (4.18). I1, I5, I6 and I7 stay; I2–I4 are restated for branch columns.
- Epic 10 consumers: 10.1, 10.2, 10.4, 10.12, 10.16, 10.17, 10.19.
