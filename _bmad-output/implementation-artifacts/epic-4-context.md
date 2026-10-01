# Epic 4 Context: `zanshin-graph` — DAG Lane Assignment (2026-10-01: the lane crate was removed in 4.12)

<!-- Generated from planning artifacts. Regenerate with compile-epic-context if planning docs change. -->

## Goal

Supply the commit-graph data layer from jj. Stories 4.1–4.9 delivered a `jj log`-parity lane graph (`zanshin_graph_slice`: pvigier lanes + per-row CLI metadata, config-aware aliases). The epic was reopened on 2026-09-26 because the commit-graph view (Epic 10) no longer draws `jj log`'s one-commit-per-row lanes: it draws the design's layered layout (rows shared by several commits, packed lanes, routed orthogonal edges), computed in Dart on `zanshin_core`'s worker isolate. Epic 4 now delivers the whole revset's index-only topology plus op-pinned lazy card content (4.10), a compact FlatBuffers wire with a lazy Dart view (4.12), the ported Dart layout engine (4.11), and commit-stack grouping in that engine (4.13).

## Stories

- Story 4.1: Lane-assignment algorithm (done)
- Story 4.2: GraphSlice FlatBuffers payload (done)
- Story 4.3: Lane computation on demand — lazy revset stream (done)
- Story 4.4: Return-all-lanes-for-revset API (done)
- Story 4.5: 10k-commit performance test (deleted)
- Story 4.6: FFI wrapper `zanshin_graph_slice` (done)
- Story 4.7: Checkpoint-caching for very large repos (deleted)
- Story 4.8: CLI-parity log rows (done)
- Story 4.9: Honor jj config revset aliases + effective log defaults (done)
- Story 4.10: Graph topology vs. card content — index-only topology call + op-pinned batch content lookup (done)
- Story 4.11: Dart layout engine on the worker isolate, ported from the A/B spike (done)
- Story 4.12: Graph topology wire — scalar vectors + CSR, lazy Dart view, id lookups, one copy across isolates (done)
- Story 4.13: Commit stacks in the layout engine — columns from the ungrouped layout, vertical compaction only

## Requirements & Constraints

- **Complete topology per operation, lazy content per page.** Row-range windowing is replaced, not built: the layout needs the whole revset before the first frame. Topology is index-only per node (a few per-call loads such as `trunk()` candidates are fine); card content loads per visible page in O(page).
- **Topology facts (4.10):** nodes in `jj log` order with commit id and the view half (change id via one index-only `commit_change_ids` pass, prefix lengths, change offset / hidden / divergent, immutable, bookmarks / tags / working copies of every workspace, root, and a new exact `parent_count` from index-only merge filtering). Edges are jj facts verbatim: Direct / Indirect / Missing, stream order, repeated targets kept, a Missing edge has no target. No synthetic "(elided revisions)" nodes. `all_count` = `|all()|` by iterating — never `count_estimate` (jj-lib's `testing` feature, on in zanshin-jj's dev-deps, makes it return 10). Runs the pre-verb precondition exactly once; returns the loaded `operation_id` in the `Ok` value.
- **Timestamps** only with `with_timestamps`: committer timestamp (epoch ms), object load only (never `is_empty`), loaded per call, no cache; the root carries none. `free` is the default layout, so every default reload pays them.
- **Content call (4.10):** `&self`, pinned to the caller's operation (`load_operation` + `load_at`, never `load_at_head`); object half = author name/email, committer timestamp, full description, conflict, empty; one entry per id in request order. Framed as the continuation of the topology call's `jj log`: no precondition, snapshot, import, config load or fix-ups, writes no operation, carries no precondition/warnings. Error order: bad operation id (full hex only) → `jj.invalid_input`; vanished operation → new `jj.operation_not_found` (CLI text `No operation ID matching "<id>"`); malformed commit id → `jj.invalid_input`; id not in the pinned index → `jj.change_not_found`; load failure → `jj.jj_lib_error`. Empty list is ok.
- **No elided counts anywhere** (decided 2026-09-30): no count call, no count field.
- **Pass-through, never decide:** revset, prioritize, short prefixes, anchors, mode, order, budget are caller arguments; Rust bakes in no default. `zanshin_core` exports editable pre-fills (anchors `["trunk()", "present(@)"]`; log defaults from `logDefaults()`).
- **Null for absence;** decoders throw on a missing required field (no `?? ''` coercions).
- **Product layout scope:** modes `free` (default) + `compact`; lane orders `compact` (default) + greedy. `time`, Time+gaps and `optimized` are dropped and not ported.
- **Stacks (4.13):** a toggle or the "Group stacks" switch never changes a column; only rows move. `stacks: false` equals 4.11's output byte for byte.
- **Performance** stays a soft target: benches (`harness = false`, in `benches/`) record numbers per store kind (loose vs packed); no timing assertions in tests.

## Technical Decisions

- **Open questions of 4.10–4.13 are answered** in `_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md` (recommended option, else status quo). A run that has to decide something new appends it there under "Taken during the runs".
- **Crate boundaries:** only `zanshin-jj` imports `jj_lib`; `extern "C"` only in `zanshin-ffi`. The engine is pure Dart in `packages/zanshin_core/lib/src/graph_layout/` (no `dart:ffi`, no Flutter), private to the worker; its result view is public. Never export a type named `GraphLayout` (10.1's app-side contract) or `GraphRef`.
- **State model (ADR-0002):** no state on the repo handle, none in the worker between commands; every request re-runs the topology call. The pinned read is recorded as an ADR-0002 Addendum next to the 2026-09-23 one, never by rewriting accepted text.
- **FFI transport:** FlatBuffers `Envelope` for fallible calls; list arguments go in request tables with a `RequestKind` member appended. `Payload` union member order is the wire discriminant: append, or reuse a removed member's slot. Edit `.fbs` in place, regenerate with `cargo make codegen`, commit generated outputs; update `docs/ffi-abi.md`, `docs/rust-error-codes.md` and the `EXPECTED_EXPORTS` count. flatc has no optional scalars for Dart → kind-gated or presence-flagged scalars. Interior-NUL guards on every string/list argument. Tests read via typed accessors + the `Verifier`.
- **Error taxonomy:** `<domain>.<reason>`, ids go in `error.context`, every new code enters the registry in the same change.
- **Wire (4.12):** `GraphTopology` as scalar vectors + CSR (edges, anchors), a flags byte, optional timestamps, sparse ref / working-copy tables. The old lane path is removed (`zanshin_graph_slice`, its tables and Dart models, the `zanshin-graph` crate); `GraphTopology` takes `GraphSlice`'s union slot; `Repo::walk_graph` stays. The ids cross as fixed-stride raw bytes, formatted in Dart (hex / jj reverse-hex) — measured (spec-4-12 § Measurements): 36 vs 96 B/node, Rust build 146 vs 175 µs, Dart first access level at 10k packed, so option (b); the flags as one packed byte per node. The envelope is 56 B/node (64 with timestamps). At most one copy across isolates: worker reads the native buffer through views, copies once into `TransferableTypedData`, UI `materialize()` is zero-copy. Id → index lookups built lazily.
- **Engine (4.11):** SPEC moves to `docs/graph-layout.md` (the spike's `SPEC.md` becomes a pointer); behaviour is byte-identical to SPEC, integers only, deterministic; every rule change is a dated SPEC amendment plus goldens. Guardrails: flat typed arrays, no per-node objects on hot paths, monomorphic sorts (no `List.sort`), tunables as request params or `const` (hot reload), worker stays `Isolate.spawn`ed. Input builder: repeated targets → one layout edge per (child, target) at the first position, `direct` if any is direct; Missing edges are not layout edges; V1/V2/V4 violations fail with a named Dart error. Priority classes from anchors (trunk chain, @ chain, rest; ties by `jj log` order). `free` emits day buckets under a fixed UTC offset. No lane-order stability hint; blocked-merge routing and free-mode buses unchanged; ordering budget default 2,000,000. As built: `RepoHandle.graphLayout(revset, anchors, utcOffsetMin, …)` returns `({GraphTopologyView topology, GraphGridView grid})`, the topology and the grid crossing as one `TransferableTypedData` each; the grid is one little-endian buffer read through `GraphGridView` (format: its doc and `docs/graph-layout.md` §13); `LayoutMode` / `LaneOrder` / the `default*` pre-fills / `LayoutContractException` are public but not in the barrel (10.12 exports them; `graph_grid_view.dart` also holds the engine's `@internal` `writeGraphGrid`, so its export is `show GraphGridView`). New engine rules: a dated `docs/graph-layout.md` amendment, then `node tools/goldens.mjs` (spike) rewrites `packages/zanshin_core/test/graph_layout/goldens/`.
- **Coverage:** the ratchet is Rust-only (new files ≥ 80 %); each new extern needs a real-cdylib `zanshin_core` test to be credited. Dart engine tests (unit, goldens, ≥ 1,000 seeded DAGs for invariants) are the safety net.
- **Tests:** committed fixtures, never regenerated; edge states are constructed in-test. jj reference is `jj-lib =0.44.0`, CLI read at `../jj` tag `v0.44.0`.

## UX & Interaction Patterns

The view never computes rows, columns, routes, buckets or a free y — it maps the engine's output to pixels. Indirect edges draw dashed, Missing edges as stubs, without counts. Edges are coloured by state (one gray plus @'s gold lineage), not by lane. The layout is independent of card size, so it is requested once per operation, never on resize. Stack toggles move cards only vertically.

## Cross-Story Dependencies

- Build order 4.10 → 4.12 → 4.11 → 4.13. 4.12 needs 4.10. 4.11 items 1–8 stand alone; its layout command needs 4.10 + 4.12 and its dumper switch needs 4.10. 4.13 needs 4.11 + 4.10.
- 4.10 leaves `walk_graph` / `stream_lanes` / `collect_lanes` / `zanshin_graph_slice` untouched; 4.12 removes the slice path and re-points its precondition witness and 9.25's `graphSlice` consumer.
- Epic 9: the pre-verb precondition (9.26), secure-config fix-ups (9.37), the precondition/warnings side channels (9.35).
- Epic 10 consumes everything: 10.1 (`GraphLayout` contract), 10.5 (request coalescing), 10.11 (content paging), 10.12 (adoption), 10.17 (stack view). The watcher's `OpHeadsChanged` (3.5/3.6) triggers a re-request.
- Worker occupancy: one isolate serves every handle and every watcher event, so a layout blocks head-of-line; rely on 10.5's coalescing; a second layout isolate only if measured.
- Left for Ralph: the one-time manual hot-reload check (4.11); optional real-repo numbers need a repo path.
