---
title: 'Story 4.11: Dart layout engine on the worker isolate — the design''s layered layout ported from the A/B spike'
type: 'feature'
created: '2026-10-01'
status: 'done'
baseline_revision: '2e7a64db451ce584f02016d75fcbebdfc95fe0d1'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-4-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md'
  - '{project-root}/spikes/graph-layout-ab/SPEC.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The "Manual check, once" (hot reload of an engine edit in the running app) is not done:
      it needs Ralph at a running Zanshin.
    evidence: |-
      Story 4.11's manual check: `flutter run` on Zanshin, edit the free gap function and one
      tunable const (e.g. compactGravity), hot reload, and a debug relayout must use the new code
      and value. Not doable unattended (Design Notes, "Open for Ralph"). The engine keeps every
      tunable `const` or a request parameter (no static/top-level final), the precondition for it;
      the relayout trigger itself is 10.12's reassemble hook. Mirrored in deferred-work.md
      "Surfaced in Story 4.11".
    location: >-
      packages/zanshin_core/lib/src/graph_layout/layout_engine.dart (freeGap),
      packages/zanshin_core/lib/src/graph_layout/compact_order.dart (compactGravity / Reach / Rounds)
    severity: medium
  - summary: >-
      No real-repo dumps or numbers: the dumper's `dump` and the benchmarks need a path to one of
      Ralph's repos.
    evidence: |-
      The run measured the committed fixtures, a git-gc-packed copy of large-10k and the spike's
      synthetic inputs only (Design Notes § Measurements). `gen-inputs dump --repo <copy>` and
      graph_layout_cli bench / graph_layout_occupancy against a COPY of a real repo (the topology
      call snapshots) would add the real-history point. Mirrored in deferred-work.md.
    location: >-
      spikes/graph-layout-ab/rust-inputs/src/main.rs (dump),
      packages/zanshin_core/benchmark/graph_layout_cli.dart,
      packages/zanshin_core/benchmark/graph_layout_occupancy.dart
    severity: low
  - summary: >-
      A layout request on a loose store waits ~1.2 s for its timestamps, and everything queued
      behind it waits too (head-of-line on the one worker).
    evidence: |-
      Occupancy (Design Notes § Measurements): a 60-id content page behind graphLayout(free,
      compact) takes 1.24 s on large-10k loose and 59 ms packed, of which the layout adds ~1.3 ms
      (packed); the rest is the timestamped topology call. This is 4.10's open option (c)/(d)
      timestamp-cache decision (deferred-work.md "Surfaced in Story 4.10") plus 10.5's
      coalescing, not a layout-engine cost. Mirrored in deferred-work.md.
    location: packages/zanshin_core/lib/src/worker/isolate.dart (GraphLayoutCommand arm)
    severity: low
  - summary: >-
      The worker fixture-parity test's large-10k `free` case costs ~20 s of the zanshin_core suite
      on a cold loose copy.
    evidence: |-
      test/worker/graph_layout_test.dart extracts large-10k-commits once and runs 4 layouts;
      the first timestamped topology call on the freshly extracted loose store took ~20 s
      (the other three ~0.5-2 s). Timeout 10 minutes for the coverage-instrumented run.
      Mirrored in deferred-work.md.
    location: packages/zanshin_core/test/worker/graph_layout_test.dart
    severity: low
  - summary: >-
      The barrel export of the layout's public types is left to 10.12, but 10.12's sprint-status
      entry does not say so.
    evidence: |-
      decisions-review-4-10-to-4-13.md (### 4.11, "Names and the request's defaults") and
      epic-4-context.md say 10.12 exports GraphGridView, LayoutMode, LaneOrder, the default*
      pre-fills and LayoutContractException; the 10-12-adopt-backend-layout-4-10-4-12 entry in
      sprint-status.yaml does not mention it, and this story may change only its own sprint-status
      line. Until then the exported ZanshinWorker.graphLayout takes LayoutMode / LaneOrder arguments
      a barrel-only caller cannot name. writeGraphGrid is @internal (review pass), so an export of
      graph_grid_view.dart should still `show GraphGridView` only. Found by the review pass;
      mirrored in deferred-work.md.
    location: >-
      packages/zanshin_core/lib/zanshin_core.dart,
      _bmad-output/implementation-artifacts/sprint-status.yaml (10-12 entry)
    severity: low
  - summary: >-
      project-context.md, the canonical ruleset, carries no rules for the new layout engine.
    evidence: |-
      The engine's guardrails (no `.sort(` in lib/src/graph_layout/, tunables `const` or request
      parameters so hot reload works, engine-core import purity, every rule change = a dated
      docs/graph-layout.md amendment + `node tools/goldens.mjs`) and the goldens' home
      (packages/zanshin_core/test/graph_layout/goldens/, rewritten wholesale by the spike tool; the
      `test-fixtures/golden/` line in project-context.md is about diff fixtures) live only in this
      spec, epic-4-context.md and docs/graph-layout.md §13. Story 4.13 and later engine work start
      from project-context.md. An agent-context edit is Ralph's call (review triage routes it to
      defer). Found by the review pass; mirrored in deferred-work.md.
    location: _bmad-output/project-context.md
    severity: low
---

<intent-contract>

## Intent

**Problem:** The commit-graph view (Epic 10) draws the design's layered layout (rows shared by several commits, packed lanes, routed edges), and Ralph decided it is computed in Dart on `zanshin_core`'s worker isolate. The layout exists only in the throwaway A/B spike (`spikes/graph-layout-ab`): no product engine, no input builder from 4.10/4.12's topology, no worker command, no result view, no versioned SPEC home, and the spike's dumper still reads the old `walk_graph`.

**Approach:** Port the spike's Dart engine — only the shipped scope: modes `compact` | `free` (default `free`), lane orders `greedy` | `compact` (default `compact`) — into `packages/zanshin_core/lib/src/graph_layout/` with the guardrails (flat typed arrays, monomorphic sorts, `const` tunables). Add the input builder (topology → engine input: repeated-target rule, anchors priority rule), a `GraphLayoutCommand` behind `RepoHandle.graphLayout(…)` that replies with the topology and a one-buffer result (`GraphGridView`), both as `TransferableTypedData`. Move SPEC to `docs/graph-layout.md` with dated amendments (free day buckets, repeated targets, priority rule, top-centre exit), implement the free day buckets in the spike's Rust and Dart references first, switch the spike's dumper to `Repo::graph_topology` + `Repo::commit_contents`, and generate committed goldens from the references.

## Boundaries & Constraints

**Always:**
- **Decisions are taken** (`decisions-review-4-10-to-4-13.md` § 4.11, Ralph: recommended option, else status quo): port scope modes `compact`|`free`, orders `greedy`|`compact`, `nowMs` gone · OQ 1 anchors priority rule (dated SPEC §11.2 amendment) · OQ 2 repeated targets → one layout edge per (child, target) at the first position, `direct` if any duplicate is direct (dated SPEC §2 amendment; V3 stays the engine's check) · OQ 3/8 no lane-order stability hint (item 7 not built) · OQ 4 D8/D9 unchanged · OQ 5 SPEC → `docs/graph-layout.md`, the spike's `SPEC.md` a pointer · OQ 6 fixed UTC offset per layout (D7) · OQ 8 budget a request parameter, default 2,000,000, no greedy-first pair · OQ 9 the engine EMITS free day buckets, `utcOffsetMin` a `free` input, dated SPEC §2/§3/§4.2/§7.3 amendments implemented in the spike's `dart/` AND `rust/` BEFORE the goldens · route geometry: the dated SPEC §4.5 top-centre text amendment only (no output change). Further decisions this run takes are in Design Notes § Taken during this run and go to the decisions file's `### 4.11`.
- **Behaviour = `docs/graph-layout.md`, byte for byte**, for the ported scope: integers only, total sort keys, floor division, no hash-order dependence, the budget's "stop the search" semantics. Greedy in both modes equals the Rust reference; the `compact` order equals the spike's Dart binary (it has no Rust reference).
- **Guardrails (hot paths in `lib/src/graph_layout/`):** flat typed arrays + CSR, no per-node objects or maps; NO `List.sort` / typed-list `.sort(` anywhere in `lib/src/graph_layout/` (hand-written monomorphic sorts with total keys); every tunable (`free` gap curve, κ/reach/rounds, default budget) is a request parameter or `const`, never a `static`/top-level `final` initializer; the worker stays `Isolate.spawn`ed. `compact_order`'s per-column segment lists and per-window scratch lists may stay growable `List<int>`s (per column/window, never per node; a byte-identical port beats a data-structure rewrite).
- **Engine purity:** the engine core files import only `dart:typed_data`, `package:meta` and each other — no `dart:ffi`, `dart:io`, `dart:convert`, `dart:isolate`, Flutter. Only the input builder and the worker glue may import `GraphTopologyView` (`lib/src/ffi/graph.dart`). The engine is private to the worker (only the worker and tests/benchmarks import it); `GraphGridView`, `LayoutMode`, `LaneOrder`, the `default*` pre-fills and `LayoutContractException` are public API but NOT added to the barrel (10.12 exports them).
- **Contract violations** (V1/V2/V3/V4 on engine input) throw `LayoutContractException(rule, message)` — never a partial or silently repaired layout. The input builder copies topology values verbatim (it never repairs or rejects); the engine validates before laying out.
- **One copy each across the isolate boundary:** the grid's arrays share ONE buffer, sent as one `TransferableTypedData`; the topology crosses in the same reply under 4.12's one-copy rule; `materialize()` on the UI side is zero-copy; no per-node objects on either side. Precondition + warnings of the topology call reach the caller (`lastPrecondition`, `topology.warnings`).
- **No worker state between commands (ADR-0002):** every `graphLayout` request re-runs the topology call; timestamps are requested iff `mode == free`.
- **Quality bar:** SPDX first line on every `.dart`/`.rs`/`.mjs` file the run creates; `///` docs on every public member; `dart analyze --fatal-infos --fatal-warnings` + `dart format` (page width 120) clean for the whole `packages/zanshin_core` incl. `test/` and `benchmark/`; scenario-named tests; no `skip:`; no timing assertions; lints as configured (`no_default_cases`, `avoid_catching_errors`, `always_put_required_named_parameters_first`, `unreachable_from_main`, …).
- **Repo conventions:** fixtures never regenerated; the spike's `inputs/`/`outputs/` stay gitignored (goldens are COPIED into `packages/zanshin_core/test/graph_layout/goldens/` and committed); no new pub dependency (the golden hash is hand-written FNV-1a 64); commits on `main` with `--no-gpg-sign` and the `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` trailer; `sprint-status.yaml` — only the `4-11-…` status value + `last_updated`, never `sprint_plan.py generate`; `epic-4-context.md` edited LAST; every deferral goes to the spec's `deferred:` AND `deferred-work.md` § "Surfaced in Story 4.11 (bmad-build-auto, 2026-10-01)".

**Never:**
- No stack logic (4.13); no `time` mode, Time+gaps, `optimized` order or `nowMs` in the product (they stay in the spike as reference); no lane-order stability hint; no D8/D9 fix; no second layout isolate; no greedy-first pair; no lane cap, row-range API, op-log graph or persisted layout.
- No product Rust, no extern, no `schemas/envelope.fbs` change, no coverage-baseline edit by hand; no Flutter UI (`app/` untouched); no type named `GraphLayout` or `GraphRef` anywhere in `packages/`; no barrel export.
- No edits to other stories' planning text beyond the dated notes listed in the Code Map; no rewrite of accepted SPEC text (amendments are dated additions or dated replacements that quote the old rule).

## I/O & Edge-Case Matrix

Fixture facts: **tiny-3-commits** `all()` = `[@, c3, c2, c1, root]` (`@` → root; root ← c1 ← c2 ← c3), anchors `[trunk(), present(@)]` → `[[4], [0]]`. **medium-1k-commits** 1002 nodes, one octopus merge. **large-10k-commits** 10,002 nodes, loose objects. The spike dumper's fixture dumps use prioritize `present(@)`, short prefixes `''`, `utc_offset_min` 120, `now_ms` = newest ts + 60 s; NARROW = `(description(glob:"Branch[AB]-*") | merge::) ~ description(glob:"*[37]")`.

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fixture parity (e2e) | `RepoHandle.graphLayout` on tiny `all()`, medium NARROW, medium `all()`, large-10k `all()`; anchors `defaultGraphAnchors`, prioritize `present(@)`, shortPrefixes `''`, utcOffsetMin 120; every mode × order | the grid's SPEC §3 canonical form == the golden (committed files: tiny, medium NARROW; FNV-1a 64 + byte length: medium `all()`, large-10k); the `free` request's builder input in SPEC §2 canonical form (golden `now_ms`, `id` = commit hex) == the dumper's input | — |
| Timestamps by mode | tiny, `compact` vs `free` | `compact`: `topology.hasTimestamps` false, grid has no buckets; `free`: `hasTimestamps` true | — |
| Free day buckets | engine cases: two non-root nodes < 1 min apart across local midnight; the root; a non-root node with null ts; utcOffsetMin −300 / 0 / 330 / ±1440 | one `day` bucket per local day of the clamped T(i), ascending, `value` = local-midnight epoch ms (`((T + off) div 86400000)·86400000 − off`), `start`/`end` = min/max y of its members (1/U units), neighbouring ranges may share one row (`end_k == start_{k+1}`), the `is_root` node in none, a null-ts non-root node counted by its T; `compact` → no buckets | — |
| Repeated targets (builder) | synthetic topology, one child's edges: (a) [Ind→A, Dir→B, Dir→A]; (b) [Dir→A, Ind→A]; (c) [Ind→A, Ind→A]; (d) [Missing, Dir→A, Missing] | (a) [A direct, B direct]; (b) [A direct]; (c) [A indirect]; (d) [missing, A direct, missing] — Missing kept (idx −1), never deduped; fp and pos follow the first occurrence | — |
| Priority classes (builder) | tiny anchors `[[4],[0]]`; anchors `[]`; an empty anchor; 3 anchors; an anchor-1 node already class 0; chain through an Indirect first parent | tiny → `[1, 2, 2, 2, 0]`; `[]` → every node 0; class k = anchor k's nodes + their first-parent chains (first non-Missing parent) up to the first node of a lower class; rest = number of anchors | — |
| Contract violations | hand-built topology: Direct edge with target −1 (V1); Missing edge with target ≥ 0 (V1); a target ≤ its child or ≥ n (V2); hand-built `LayoutInput`: a repeated idx (V3); ts beyond ±2^53, priority < 0 or ≥ 2^31, \|utcOffsetMin\| > 1440 (V4) | — | `LayoutContractException` with `rule` `V1`/`V2`/`V3`/`V4`; no grid: `layOutTopology` returns the violation and no grid, `decodeGraphLayoutReply` rethrows it |
| Empty revset | `none()`, every mode × order | n = 0: `rows` = `lanes` = 0, no edges, no buckets | — |
| jj error | revset `(` | — | `ZanshinFfiException('jj.revset_parse_error')` carrying the precondition; `lastPrecondition` updated |
| Calling side | NUL in revset / prioritize / shortPrefixes / an anchor; utcOffsetMin ±1441; budget −1; closed handle; unknown handle id | — | `ArgumentError` before `send`; `StateError`; `ZanshinFfiException('ffi.invalid_handle')` |
| Transfer + determinism | `sendRaw((id) => GraphLayoutCommand(…))`; the same request twice | a `GraphLayoutResult` with two `TransferableTypedData`; the materialized grid backs a `GraphGridView` with no copy; identical grid bytes both times | — |
| Grid decode contract | Dart-built grid buffers | header slots, 8-aligned offsets, lengths and enum codes as Design Notes § Grid buffer; wrong version, unknown mode/order code, short buffer, length mismatch, out-of-bounds or unaligned array offset → `FormatException`; a buffer whose start is not 8-aligned is copied once, values equal | — |
| Design + fuzz goldens | `design-default` / `design-all`; ≥ 100 seeded fuzz cases | `compact` mode greedy == the design's `computeLayout` (oracle files) byte for byte; all 8 design outputs (2 revsets × 2 modes × 2 orders) == the references; `free` greedy `rows` 209 / 377 with 4 lanes; every fuzz case's 4 outputs == their golden hashes | — |

</intent-contract>

## Code Map

**SPEC — move and dated amendments (do first)**
- `spikes/graph-layout-ab/SPEC.md` → `git mv` to `docs/graph-layout.md`; recreate `spikes/graph-layout-ab/SPEC.md` as a ≤ 10-line pointer (moved 2026-10-01, Story 4.11; link `../../docs/graph-layout.md`).
- `docs/graph-layout.md` amendments, each `*(Amended 2026-10-01, Story 4.11: …)*` or a dated sub-paragraph, old rule quoted where replaced: top (after the title line) — the file's new home, spike-relative paths (`rust/`, `dart/`, `tools/`, `inputs/`, `outputs/`) mean `spikes/graph-layout-ab/…`, the product engine `packages/zanshin_core/lib/src/graph_layout/` is a third implementation of the shipped scope only (§12); §2 table `:76` (`utc_offset_min` read by `time` AND `free`); §2 "What the dumper writes" `:119-136` (nodes/edges from `Repo::graph_topology`, not `walk_graph`; jj DOES yield repeated targets (Direct + Indirect to one parent) → producers keep one parent per (child, target) at the first occurrence's position, kind `direct` if any is direct, V3 stays; `priority` = §11.2's rule, no longer a stand-in); §3 `:167` (buckets filled in `time` and `free`; `free` emits `day` only); §4.2 free `:224-249` — new step 4 "Day buckets" (Design Notes § Free day buckets); §4.3 `:263-266` (other first-parent children leave through the stub above the card's centre; reservation unchanged); §4.5 `:315-318` (`branch_off` leaves the parent's top at pcx; text from §12 `:794-801`); §7.3 I5 `:625-627` (free variant, Design Notes); §11.2 `:760-761` (the anchors rule is normative — Design Notes § Priority rule); §12 `:791-814` (the planned §4.5 change is now made); new §13 "Product engine (Story 4.11)" — location, scope, input builder rules, the grid buffer pointer (`GraphGridView`'s doc), `LayoutContractException`.

**Spike references — free day buckets (`spikes/graph-layout-ab/`, before any golden)**
- `rust/src/layout.rs` — `layer_free` `:398-442`: `t` (clamped T) is complete after `:419`, walk `:425-436`; after the walk, one pass over `ord` emitting buckets (skip `is_root`); replace `buckets: Vec::new()` `:440`; factor `day_key(t, off)` out of `bucket_key` `:280-281` (do NOT call `bucket_key`/`bucket_of_key` from free — they apply the `now_ms` ladder); docs `:138`, `:258`, `lib.rs:9`, `input.rs:36-39`; tests `:969-1011` gain bucket assertions + a two-days-one-row case.
- `rust/src/checks.rs:142-165` — replace `:143`'s `buckets.is_empty()` with the free I5 (reuse the `t` it computes `:144-159`).
- `dart/lib/src/layout.dart` — `_layerFree` `:330-376` keeps `t` (`:345-353`) and reads `input.utcOffsetMin`; reuse `bucketDay`/`floorDiv` (`:24`, `:40`) and the day formula (`:48-49`); same pass inside the timed layering phase.
- `dart/test/layout_test.dart` — `checkInvariants` I5 `:1095-1122` (`:1097` asserts no buckets outside `time`) → free I5; add free-bucket unit tests.
- `tools/compare.mjs:90-117` (`:117` fails any bucket outside `time`) → free I5 reusing `T` from `:120-123`. `tools/fuzz.mjs` — naive reference free branch `:128-139` + `:215` emit free day buckets; export `genInput` (`:50-87`) without changing the CLI. `tools/payload.mjs:17` comment ("time and free").
- Rebuild + verify: `cargo build --release --manifest-path rust/Cargo.toml`, `dart compile exe dart/bin/graph_layout.dart -o dart/build/graph_layout`, `cargo test --release --manifest-path rust/Cargo.toml`, `(cd dart && dart run test/layout_test.dart)`, `node tools/compare.mjs --digest`, `node tools/fuzz.mjs --cases 300`, `node tools/js_oracle.mjs --fuzz 300` (README `## Run` `:66-99`).

**Spike dumper (`rust-inputs/`, item 10; detached crate, outside the gate)**
- `src/jj_dump.rs:36-139` — replace the two `walk_graph` walks with ONE `repo.graph_topology(revset, DEFAULT_GRAPH_PRIORITIZE, short_prefixes, &["trunk()".into(), "present(@)".into()], true)` (`crates/zanshin-jj/src/repo.rs:827-846`; types `topology.rs:31-109`: `GraphTopology { operation_id, nodes, anchors: Vec<Vec<usize>>, all_count }`, `TopologyNode { commit_id, edges, meta, committer_timestamp_ms }`, `TopologyEdge { target: Option<usize>, kind }`); targets are already node indices; dedupe `:95-113` → the amended rule (kept edge `direct` if any duplicate is direct; dropped ones still recorded); `ts_ms` = `committer_timestamp_ms`; priorities from `topo.anchors`; `Dump.trunk` from anchor 0 (only "in graph or not" is knowable now). Sidecar `meta_json` `:143-186` keeps its keys: view half from `TopologyMeta`, object half from `repo.commit_contents(&topo.operation_id, &ids)` (`repo.rs:875-881`; `CommitContent` `commit_content.rs:34-51`; `description` = first line of the full description; `author` = `author_name`; `committer_ts_ms`/`committer_tz_min` from `committer_timestamp`). Doc `:1-4`.
- `src/input.rs:140-165` — `assign_priorities(nodes, anchors: &[Vec<usize>])` per Design Notes § Priority rule; inline `#[cfg(test)]` cases mirroring the Dart builder tests (priority + dedupe); `src/synth.rs:393` → `&[vec![trunk], vec![wc]]` (same output).
- `src/main.rs:58-62` — add `fixture-tiny-all.json` (tiny-3-commits, `all()`) to `FIXTURES`; `src/manifest.rs:24-26`, `:200` and `Cargo.toml:19-20` strings → the topology call / `docs/graph-layout.md`.
- Re-dump (`node tools/design-input.mjs`; `CARGO_TARGET_DIR=rust-inputs/target cargo run --release --manifest-path rust-inputs/Cargo.toml -- all`); before that, copy the current `inputs/*.json` aside (scratchpad) and `cmp` afterwards: every pre-existing input must be byte-identical (the fixtures have no repeated targets); a difference is a bug to explain, not to accept. Run the dumper twice: identical bytes (proves the precondition snapshot rewrites nothing).

**Goldens tool (NEW `spikes/graph-layout-ab/tools/goldens.mjs`)**
- Needs both reference binaries and the regenerated inputs; writes into `packages/zanshin_core/test/graph_layout/goldens/` (Design Notes § Goldens): seeded fuzz inputs via `fuzz.mjs`'s exported generator, greedy outputs from `rust/target/release/graph-layout`, `compact`-order outputs from `dart/build/graph_layout`, oracle files from `outputs/oracle/` (run `js_oracle.mjs` first), FNV-1a 64 via `BigInt`. Deterministic: a second run leaves `git status` clean.

**Product engine (NEW, `packages/zanshin_core/lib/src/graph_layout/`)** — sources in `spikes/graph-layout-ab/dart/lib/src/`:
- `layout_request.dart` (public): `enum LayoutMode { compact, free }`, `enum LaneOrder { greedy, compact }` (names are the SPEC wire strings), `const defaultLayoutMode = LayoutMode.free`, `const defaultLaneOrder = LaneOrder.compact`, `const int defaultLayoutBudget = 2000000`, `final class LayoutContractException implements Exception { final String rule; final String message; }` (`toString` names both).
- `layout_input.dart` (engine): `LayoutInput` = spike `input.dart:28-59` minus `nowMs` (n, `ts` Int64List, `hasTs`/`isRoot` Uint8List, `priority` Int32List, `parStart`/`parIdx` Int32List, `parKind` Uint8List 0 direct / 1 indirect / 2 missing, `utcOffsetMin`) + `validateLayoutInput` (V1–V4 value checks of `input.dart:115-151` over typed arrays: V1, V2 `i < idx < n`, V3 via a stamp array, V4 ts/priority/offset) throwing `LayoutContractException`; no JSON.
- `layout_engine.dart` (engine): spike `layout.dart` (677 lines) MINUS `Mode.time`, `ladderMinutes`, `rootKey`, `timeBucketKey` `:43-50`, `_layerTime` `:250-328`, `_lowerBound` `:666-677`, `LaneOrder.optimized`, `buildSifter` `:567-635`, the optimized case `:546-552` and the `lane_order.dart` import; the internal class `GraphLayout` (`:123`) is RENAMED (e.g. `LayoutEngine`); keeps `freeGap` (literals inline), `floorDiv`, `_prep`, `_layerCompact`, `_layerFree` (+ day buckets), `packLanes` (+ `_adoptLanes`), `markBlocked`, `route`, `orderLanes` (greedy / compact incl. the re-run of blocked + routing `:553-562`), the `onPhaseEnd` hook; entry `Uint8List computeGraphGrid(LayoutInput input, {required LayoutMode mode, required LaneOrder order, required int budget, void Function()? onPhaseEnd})` validates first, then writes the result in the grid format (§ Grid buffer).
- `compact_order.dart` (engine): spike `compact_order.dart` (493 lines) verbatim except: the budget comes from the request (`CompactOrder(…, budget:)`), the three closure/typed-list sorts (`:45-49` segments by (a, index), `:260-261` per-segment lo/hi, `:293-297` horizontals by (level, index)) become monomorphic.
- `sort.dart` (engine): the monomorphic sorts (index arrays by inline multi-key comparisons; `Int64List` ascending) for the free walk (T asc, i desc; spike `:359-363`), the packing visit order ((y, priority, i); `:398-404`) and the three compact sites.
- `graph_grid_view.dart` (public): `GraphGridView` + the format constants + enum codes + a small writer used by the engine (§ Grid buffer).
- `input_builder.dart` (worker): `LayoutInput buildLayoutInput(GraphTopologyView topology, {required int utcOffsetMin})` from the typed views `flags` (`GraphTopologyView.flagRoot`), `timestamps` (`Int64List?`, root slot 0), `edgeStarts` (Uint32List n+1), `edgeTargets` (Int32List, −1 for Missing), `edgeKinds` (Int8List 0/1/2), `anchorStarts`/`anchorNodesFlat` (Uint32List) (`lib/src/ffi/graph.dart:382-407`); repeated-target rule; priority rule; `hasTs[i]` = timestamps present AND not root. O(n + E), stamp arrays, no maps; out-of-range targets copied unchanged (no indexing with them) so validation names the rule; an edge-kind byte other than 0/1/2 → `ZanshinFfiException('ffi.unknown', …)` like `GraphTopologyView.edgeKind`.
- `layout_reply.dart` (worker glue): the worker-side `layOutTopology(Uint8List topologyEnvelope, {mode, order, utcOffsetMin, budget})` → `(Uint8List? grid, LayoutContractException? violation)` — no layout when the envelope is not `ok` or the view fails to construct (the caller's decode reproduces that error); and the caller-side `@visibleForTesting decodeGraphLayoutReply(Uint8List topologyBytes, GraphLayoutResult reply)` → `({GraphTopologyView topology, GraphGridView grid})`, throwing the topology's `ZanshinFfiException` first, then the violation.

**Worker + handle (`packages/zanshin_core/lib/src/worker/`)**
- `commands.dart` — `GraphLayoutCommand extends WorkerCommand implements HandleScopedCommand` (handleId, revset, prioritize, shortPrefixes, `List<String> anchors`, `LayoutMode mode`, `LaneOrder order`, `int utcOffsetMin`, `int budget`); template `GraphTopologyCommand` `:178-219`.
- `responses.dart` — `final class GraphLayoutResult extends WorkerResponse { final TransferableTypedData topology; final TransferableTypedData? grid; final LayoutContractException? violation; }` (template `TransferResult` `:57-62`; doc: both materialize once, zero-copy).
- `isolate.dart` — new arm in each exhaustive response switch (`openRepo` `:373-383`, `_createdOrThrow` `:431-441`, `send` `:457-463`, `closeRepo` `:579-590`: `StateError`); `ZanshinWorker.graphLayout(int handleId, {…})` (template `graphTopology` `:646-673`): calling-side guards (`rejectInteriorNul`/`rejectInteriorNuls`, `request_bytes.dart:69`/`:81`; `RangeError`/`ArgumentError` for |utcOffsetMin| > 1440 and budget < 0) → `_sendCommand` (`:494-501`, NOT `send()`); `GraphLayoutResult` → materialize the topology, `_recordPrecondition(cmd, bytes)` (`:479-487`), `decodeGraphLayoutReply`; `BufferResult` (invalid handle) → record + throw its error. Worker dispatch arm (template `:1832-1863`): unknown handle → `BufferResult(_invalidHandleEnvelope(…))` (`:2419-2425`); else `zanshinGraphTopology(…, withTimestamps: mode == LayoutMode.free)`, then inside `try { … } finally { buf.dispose(); }`: copy the topology once into a `TransferableTypedData`, run `layOutTopology(buf.bytes, …)` (the view reads native memory, so BEFORE dispose), copy the grid once; reply `GraphLayoutResult`. Catch `LayoutContractException` inside the arm (the generic `catch` `:2397-2407` would stringify it).
- `handle.dart` — `RepoHandle.graphLayout({required String revset, required List<String> anchors, required int utcOffsetMin, String prioritize = defaultGraphPrioritize, String shortPrefixes = defaultShortPrefixes, LayoutMode mode = defaultLayoutMode, LaneOrder order = defaultLaneOrder, int budget = defaultLayoutBudget})` → `Future<({GraphTopologyView topology, GraphGridView grid})>`, `_closed` guard (template `:152-169`); doc names `defaultGraphAnchors` and `logDefaults()` as the pre-fills and that `utcOffsetMin` is ignored in `compact`.

**Tests (NEW, `packages/zanshin_core/test/`)**
- `graph_layout/support/spec_json.dart` — SPEC §2 parser (JSON + type checks, then `validateLayoutInput`) → `(LayoutInput, int nowMs)`; SPEC §2 canonical input writer (`now_ms`, ids supplied); SPEC §3 canonical output writer from a `GraphGridView`; §8.4 digest; `fnv1a64Hex(List<int>)`. Spike sources `input.dart:66-171`, `output.dart:5-77`.
- `graph_layout/engine_test.dart` — the spike's unit tests (`dart/test/layout_test.dart`) ported to `package:test` per Design Notes § Test port, plus free-day-bucket cases; reaches engine internals like the spike tests do.
- `graph_layout/invariants.dart` (helper) + `graph_layout/invariants_test.dart` — I1–I6 with the amended free I5 (spike `checkInvariants` `:1043-1142` minus `time`/`optimized`) over ≥ 1,000 seeded Dart-generated DAGs × 2 modes × 2 orders (spike `randomGraph` `:797-825` shapes: Missing/Indirect parents, priority ties, non-monotonic and null ts, several roots, utcOffsetMin spread) and over every golden output; compact-vs-greedy checks (same rows/buckets/edge order/routes, `col = lane`, trunk lane 0 fixed, lanes ≤ greedy's, model cost ≤ greedy's).
- `graph_layout/golden_test.dart` — the design oracle, the 8 design outputs, §7.2's free rows, the fuzz hashes.
- `graph_layout/input_builder_test.dart` — synthetic topology envelopes (pattern `test/ffi/graph_test.dart:44-103`, `fbs.GraphTopologyObjectBuilder`): the repeated-target, priority, timestamp-presence and contract-violation matrix rows; `layOutTopology`/`decodeGraphLayoutReply` incl. an error envelope and a violation.
- `graph_layout/grid_view_test.dart` — the decode-contract row.
- `worker/graph_layout_test.dart` — real cdylib (templates `test/worker/graph_test.dart:44-54`, `:118-140`; fixture extraction `test/worker/graph_ids_test.dart:47-54` via `tar`, `Timeout(Duration(minutes: 10))` for large): fixture parity, timestamps by mode, transfer + determinism, empty revset, jj error, calling side, `lastPrecondition`; one extraction + one worker per fixture (`setUpAll`).

**Goldens (NEW, committed, `packages/zanshin_core/test/graph_layout/goldens/`)** — layout in Design Notes § Goldens.

**Dev tools (outside `test/`, not in the gate)**
- `packages/zanshin_core/benchmark/graph_layout_cli.dart` — SPEC §6 subset for the product engine: `layout --mode compact|free --order greedy|compact <in> <out>`, `bench … [--runs N] [--warmup W] <in>` (one §8.4 JSON line, `impl` `dart-core-aot`/`dart-core-jit`, per-phase median/min via `onPhaseEnd`); exit 2 on usage/invalid input; imports `../test/graph_layout/support/spec_json.dart`; imports no `dart:ffi`-reaching file.
- `spikes/graph-layout-ab/tools/compare.mjs` — `--core <binary>` adds the product engine as a third implementation over every manifest input × {compact, free} × {greedy, compact}: greedy byte-equal to the Rust output, `compact` byte-equal to the spike Dart output, invariants on each; without `--core` unchanged.
- `packages/zanshin_core/benchmark/graph_layout_occupancy.dart` — real worker on large-10k loose + a `git gc`-packed copy (pattern `benchmark/graph_wire.dart`): latency of a 60-id `commitContents` page alone, queued behind a `graphLayout(free, compact)` and behind a timestamped `graphTopology`; prints numbers only.

**Docs, planning, tracking**
- `spikes/graph-layout-ab/` — every path citation of `SPEC.md` in `README.md`, `SPEC_NOTES_{DART,RUST}.md`, `tools/*.mjs`, `dart/`, `rust/`, `rust-inputs/` → `docs/graph-layout.md` (links `../../docs/graph-layout.md`, anchors kept); historical statements may stay if dated. README `## Status` gains item 9 (the port, the move, free day buckets, the dumper switch); `## Run` gains `node tools/goldens.mjs` and the `--core` compare.
- `_bmad-output/planning-artifacts/architecture.md:32` and `:439` — dated notes `(2026-10-01, Story 4.11: the FR-GR-1 layout lives in packages/zanshin_core/lib/src/graph_layout/ (Dart, worker isolate); contract docs/graph-layout.md)`, style of `:601`.
- `_bmad-output/project-context.md:267-270` — dated note: `RepoHandle.graphLayout`'s reply carries the topology AND the grid as two `TransferableTypedData` (`GraphGridView`).
- `_bmad-output/planning-artifacts/epics.md` — `> **Delivered (2026-10-01, Story 4.11 done):** …` after `:3854` (format of `:4009-4014`).
- `_bmad-output/implementation-artifacts/decisions-review-4-10-to-4-13.md` — `### 4.11` after the `### 4.12` table (end of file).
- `_bmad-output/implementation-artifacts/deferred-work.md` — section at the end (format of `:846-859`).
- `_bmad-output/implementation-artifacts/sprint-status.yaml:51` — `backlog` → `done`, comment kept; `last_updated`.
- `_bmad-output/implementation-artifacts/epic-4-context.md` — LAST: `:21` 4.11 → done; `:46` the engine line names `GraphGridView`/`graphLayout`.

## Tasks & Acceptance

**Execution:**
- [x] `docs/graph-layout.md` (moved) + `spikes/graph-layout-ab/SPEC.md` pointer -- the move and every dated amendment of the Code Map -- SPEC first.
- [x] `spikes/graph-layout-ab/{rust/src/layout.rs,rust/src/checks.rs,rust/src/lib.rs,rust/src/input.rs,dart/lib/src/layout.dart,dart/test/layout_test.dart,tools/compare.mjs,tools/fuzz.mjs,tools/payload.mjs}` -- free day buckets in both references + their invariant checks + the fuzz reference; rebuild; the spike verification suite green -- amendments before goldens.
- [x] `spikes/graph-layout-ab/rust-inputs/src/{jj_dump,input,synth,main,manifest}.rs`, `Cargo.toml` -- topology + contents switch, amended dedupe, anchors priority rule, tiny fixture entry, inline tests; re-dump; `cmp` against the old inputs; dump twice -- item 10.
- [x] `spikes/graph-layout-ab/tools/goldens.mjs` -- generate the goldens; run twice -- committed goldens.
- [x] `packages/zanshin_core/lib/src/graph_layout/{layout_request,layout_input,layout_engine,compact_order,sort,graph_grid_view,input_builder,layout_reply}.dart` -- the port, monomorphic sorts, day buckets, grid format, builder, glue -- items 1-6.
- [x] `packages/zanshin_core/test/graph_layout/{support/spec_json,engine_test,invariants,invariants_test,golden_test,input_builder_test,grid_view_test}.dart` -- unit, invariant, golden, builder, decode-contract tests -- the engine's safety net.
- [x] `packages/zanshin_core/lib/src/worker/{commands,responses,isolate,handle}.dart` + `test/worker/graph_layout_test.dart` -- the layout command end to end -- item 9.
- [x] `packages/zanshin_core/benchmark/{graph_layout_cli,graph_layout_occupancy}.dart`, `spikes/graph-layout-ab/tools/compare.mjs --core` -- dev tools; AOT-compile the CLI (`dart compile exe`, or `dart build cli` if the package's build hook blocks it) into `spikes/graph-layout-ab/outputs/bin/`; run the differential over every manifest input; run the benchmark (AOT + JIT, warm: defaults; cold: `--warmup 0 --runs 1`, median of 3 processes) on fixture-medium-all, fixture-large-all, synth-10k, synth-100k × 2 modes × 2 orders; run the occupancy script; record everything in Design Notes § Measurements -- dev tools.
- [x] spike `README.md`/notes/tools path sweep; `architecture.md`, `project-context.md`, `epics.md` notes; decisions `### 4.11`; `deferred-work.md` section (at least the two open items below); `sprint-status.yaml`; `epic-4-context.md` LAST -- docs and tracking.
- [x] from `packages/zanshin_core` with the `[tasks.test-core]` env (`Makefile.toml:126-136`): the whole `dart test`, `dart analyze --fatal-infos --fatal-warnings`, `dart format --output=none --set-exit-if-changed .` -- green; do NOT run `cargo make test` (the run's verification does) and do not commit.

**Acceptance Criteria:**
- Given the finished tree, when `grep -rn "\.sort(" packages/zanshin_core/lib/src/graph_layout`, `grep -rnE "static (late )?(final|var) " packages/zanshin_core/lib/src/graph_layout` and `grep -rnE "^(late |var |final )" packages/zanshin_core/lib/src/graph_layout | grep -v ":final class "` run, then none has a hit; the engine core files (`layout_request`, `layout_input`, `layout_engine`, `compact_order`, `sort`, `graph_grid_view`) import no `dart:ffi`/`dart:io`/`dart:convert`/`dart:isolate`; `grep -rnE "(class|enum|typedef|mixin) (GraphLayout|GraphRef)\b" packages/` has no hit; `lib/zanshin_core.dart` is unchanged.
- Given a fresh-init repo, when `RepoHandle.graphLayout(revset: 'all()', anchors: defaultGraphAnchors, utcOffsetMin: 0)` runs through the real cdylib, then it returns a topology with 2 nodes and `hasTimestamps` true and a grid with `mode` free, `order` compact, `nodeCount` 2, `lanes` 1, one `day` bucket whose range holds `@`'s row and not the root's, and `lastPrecondition` is set.
- Given the amended spike, when `node tools/compare.mjs --digest`, `node tools/fuzz.mjs --cases 300`, `node tools/js_oracle.mjs --fuzz 300`, `cargo test --release --manifest-path rust/Cargo.toml` and `dart run test/layout_test.dart` (in `dart/`) run, then each exits 0; and `node tools/compare.mjs --core <binary>` reports every product cell byte-equal with no invariant failure.
- Given the finished tree, when `docs/graph-layout.md` is read, then it carries the dated §2/§3/§4.2/§4.3/§4.5/§7.3/§11.2/§12 amendments and §13, the spike's `SPEC.md` is only a pointer, and `git grep -n "SPEC\.md" -- spikes/graph-layout-ab` hits only the pointer file and dated historical lines.
- Given the finished tree, when `cargo make test` runs unpiped, then it exits 0 with `extern-coverage: OK` and `coverage-check: OK` (no Rust file changed coverage), and `git status` is clean after the finalization commit.

## Spec Change Log

## Review Triage Log

### 2026-10-01 — Review pass
- verdicts: 34 findings — high 0, medium 1, low 17, false 16, maybe-false 0
- findings:
  - `medium` `patch` [verification-gap] No `graphLayout` call passes non-default `anchors` and checks something that depends on them; a baked-in default at any hop (handle → command → topology call) would pass every test. — Added `the_anchors_reach_the_topology_call_as_given` (test/worker/graph_layout_test.dart): `anchors: ['present(@)']` gives `anchorCount` 1 and builder priorities `[0, 0]` (defaults give `[1, 0]`); `['nonexistent-bookmark-xyz']` fails with `jj.revset_resolution_error`.
  - `low` `patch` [verification-gap] Four files the suite needs are untracked (three `goldens/design/*.budget-*.json`, `test/graph_layout/support/topology_envelope.dart`); a commit of tracked/intent-to-add paths only would break the suite. — Finalization stages every file of the story explicitly (the four included, `goldens/README.md` at its working-tree version) and checks the tree is clean.
  - `low` `reject` [intent-alignment §3.1] The budget-bound many-lane regime (synth-10k/50k/100k at the default budget) is checked only by the manual `compare.mjs --core` differential, not by the gate. — The gate covers the "stop the search" semantics through the three budget-cut design goldens and the worker's budget-0 case; gating synth-scale outputs would add large goldens, and a regression there also changes the cut goldens. Rerun this pass: 44/44 core cells byte-equal.
  - `false` `reject` [intent-alignment §3.2] The free day buckets in the spike references are verified outside the gate. — The intent asks for the amendment in `rust/` and `dart/` before the goldens, which holds (both suites green, rerun this pass); the spike crates are deliberately outside the gate, and the product checks I5 itself in `invariants_test.dart`.
  - `false` `reject` [intent-alignment §3.3] Only one V1 case crosses the glue; no violation crosses a real `SendPort`. — `layOutTopology` catches `LayoutContractException` independent of its rule, so one glue case covers every rule; the worker is `Isolate.spawn`ed in the same group, where an object of two `String` fields is sendable, so the crossing cannot fail.
  - `false` `reject` [intent-alignment §3.4] The fixture-parity row re-runs the builder on the caller instead of observing the worker's input. — The builder is a pure function of the topology bytes, and the caller holds the one copy of exactly the bytes the worker laid out; compact parity is observed directly at the grid (byte-equal to the goldens), so not reading timestamps in `compact` is checked.
  - `low` `reject` [intent-alignment §3.5] `priority` ≥ 2^31 cannot reach V4 on a hand-built `LayoutInput`: an `Int32List` wraps 2^32 to 0. — Only a hand-written test input could hold it (the builder's classes are < anchor count + 1; the support parser rejects ≥ 2^31 itself); widening the type is more than a direct correction.
  - `false` `reject` [intent-alignment §3.6] The builder rejects an anchor node ≥ n, against "never rejects". — "Copied verbatim" is about engine input values (edge targets, which it copies); anchors are no engine input, and indexing with an out-of-range anchor would crash. Recorded in the decisions file (### 4.11, "Corrupt topology values").
  - `false` `reject` [intent-alignment §3.7] Calling-side errors are `RangeError`, the guard applies in every mode. — `RangeError` is an `ArgumentError` (tests use `throwsArgumentError`); the matrix row asks for ±1441 → `ArgumentError` without a mode qualifier.
  - `low` `patch` [intent-alignment §3.8] The spike reference surface widened beyond the Code Map: `--budget` on the spike Dart CLI and budget-cut goldens the matrix does not list (untracked). — Same root as the blind hunter's `--budget` finding: docs/graph-layout.md §6 gains a dated 2026-10-01 line for `--budget`; the decision is recorded in the decisions file (### 4.11); the files are committed at finalization.
  - `false` `reject` [intent-alignment §3.9] `docs/ffi-abi.md` notes are outside the Code Map; architecture.md adds a "removed in 4.12" clause. — Both are accurate dated additions (project-context.md records the crate's removal); docs/ffi-abi.md is the living FFI doc later stories extend, not another story's planning text.
  - `false` `reject` [intent-alignment §3.10] The hot-reload guardrail is checked only structurally. — No defect claimed beyond the recorded deferral (`deferred:` item 1, deferred-work.md); the structural precondition (AC 1 greps) holds, rerun this pass.
  - `low` `patch` [intent-alignment §3.11] `writeGraphGrid`, an engine-internal writer, is a public top-level function in `graph_grid_view.dart`, the file 10.12 will export. — Annotated `@internal` (package:meta) with a doc line; `dart analyze --fatal-infos` clean.
  - `false` `reject` [intent-alignment §3.12] Tracking files say done while the spec is in review and the gate has not run. — The finalization commits tracking and the spec's `done` together after `cargo make test` passes; a blocked halt would revert the tracking first.
  - `false` `reject` [edge-case] A non-monotone `edge_start` CSR gives a `RangeError`, not `ffi.unknown`. — The topology comes from this repo's Rust producer, which writes `edge_start` monotone by construction; a corrupt buffer still fails loudly (`internal.dispatch_error`).
  - `false` `reject` [edge-case] A non-monotone `anchor_start` CSR gives a `RangeError`. — Same producer guarantee as above; loud failure on an unreachable state.
  - `false` `reject` [edge-case] A throw other than `LayoutContractException`/`ZanshinFfiException` in `layOutTopology` becomes `internal.dispatch_error` and drops warnings/precondition. — No valid input reaches such a throw (only the corrupt producer states above or an engine bug), and the outcome is loud.
  - `low` `reject` [edge-case] Topology warnings are lost when the engine reports a `LayoutContractException`. — Real jj data reaches a violation only with committer timestamps beyond ±2^53 ms (year 285,000+); the call fails anyway, and carrying warnings would add a field to the public exception.
  - `false` `reject` [edge-case] `free` over a topology without timestamps collapses silently into one 1970 bucket. — The worker requests timestamps iff `mode == free`; a direct builder call without them is §2's defined null-ts behaviour (T clamped), not a corruption.
  - `low` `patch` [edge-case] `graph_layout_cli foo` reports a flag error instead of the unknown command. — The command is resolved before the flags are parsed (`switch` expression); `graph_layout_core foo` now prints `unknown command "foo"`, exit 2.
  - `low` `reject` [edge-case] `compare.mjs --core` as the last argument throws a `TypeError`. — A spike dev tool's misuse that already fails loudly; the fix is an extra guard.
  - `low` `reject` [edge-case] `tools/goldens.mjs` wipes the goldens before its precondition checks. — The goldens are committed, so a failed regeneration shows in `git status` and restores with git; the fix restructures the tool (temp dir + rename).
  - `false` `reject` [blind] Story 4.11 is marked done in tracking before its verification. — As above: the finalization commit carries tracking and the spec's `done` only after the gate passed; the gate result goes to `## Auto Run Result`.
  - `low` `patch` [blind] Staged, intent-to-add and untracked files are mixed; a partial commit breaks the suite. — Same root as the verification-gap finding on untracked files; handled by the finalization commit.
  - `low` `patch` [blind] The spike's `--budget` flag has no contract in docs/graph-layout.md §6 (the Rust binary rejects it; the product CLI has none). — Added the dated `Dart-only (2026-10-01, Story 4.11)` line to §6; the product CLI keeps the default (the budget-cut goldens cross-check the product engine in `golden_test.dart`).
  - `low` `reject` [blind] The spec's records are stale after the budget goldens (26 vs 29 files, Design Notes/matrix silent, determinism not re-established). — The fix edits this build's spec; determinism was re-established this pass (two `goldens.mjs` runs, every golden byte-identical incl. the budget files), noted in `## Auto Run Result`.
  - `low` `patch` [blind] Decision traceability: three late choices (budget-cut goldens, spike `--budget`, the CUT budgets) are recorded nowhere. — Appended a row to decisions-review-4-10-to-4-13.md ### 4.11 (plus a row summarising this review pass); the spec-side half would edit this spec.
  - `low` `defer` [blind] project-context.md carries no rules for the new engine (guardrails, goldens home). — An agent-context edit: `deferred:` item 6 + deferred-work.md.
  - `low` `defer` [blind] The barrel-export hand-off to 10.12 is untracked in 10.12's entry; the writer leaks; rows/y narrow to int32 without assert. — Hand-off: `deferred:` item 5 + deferred-work.md (the intent limits sprint-status edits to 4.11's line). Writer: patched via the `@internal` finding. int32: rejected — y ≤ 48·(n − 1) overflows only past ~44 M nodes.
  - `low` `reject` [blind] The caller re-derives the worker's builder error by re-running the builder with `utcOffsetMin: 0`. — Correct today (the builder's refusals depend on the bytes only, and the caller holds the same bytes); trouble only for a future parameter-dependent check, and the fix adds reply fields.
  - `false` `reject` [blind] `validateLayoutInput` checks values, not array structure. — Structure is not a §2 V-rule (the JSON layer and the builder produce well-formed arrays by construction); a malformed hand-built input fails loudly with a `RangeError`.
  - `false` `reject` [blind] The dumper's `meta_json` zips metas with empty contents silently when dumped without contents. — Its only caller (`main.rs:178-181`) dumps with `with_contents = true`.
  - `low` `patch` [blind] Several documented behaviours have no test. — Added: an anchor chain into a target beyond n (priorities `[0, 1]`, then V2), two out-of-range edges to one target (copied verbatim, V2 not V3), an unknown parent kind (V1), a `graphLayout` after the worker closes (`StateError`). The `SendPort` crossing is rejected as above.
  - `false` `reject` [blind] `graph_layout/` and `worker/` import each other; `layout_reply.dart` belongs in `worker/`. — Dart tolerates the import cycle; the engine core files (what 4.13 extends and 10.12 exports) import neither `worker/` nor `ffi/` (AC 1), only the two glue files do, which is the spec's partition.

## Design Notes

**Free day buckets (SPEC §4.2 free, new step 4).** After the walk: for every node i with `is_root` false — a non-root node with a null ts is a member by its clamped T(i) — dk(i) = ((T(i) + off) div 86400000)·86400000 − off, off = utc_offset_min·60000. One bucket per distinct dk, ascending, `kind` = `day`, `value` = dk, `start`/`end` = min/max y over its members (1/U units). In walk order (T asc, i desc) both T and y are non-decreasing, so one pass emits them in order with no sort. The root is in no bucket; no `root`/`age` bucket in `free`. Free I5: kinds all `day`; values strictly ascending; `start ≤ end`; `end_k ≤ start_{k+1}` (a row may hold two days; ranges are not contiguous and need not start at 0 or end at rows − U); every non-root node lies in the bucket of dk(i); `start`/`end` equal its members' min/max y; no bucket iff no non-root node. `compact` I5: no buckets.

**Priority rule (SPEC §11.2, normative).** A = number of anchors; class(i) = A for all; for k = 0 … A−1, for each node a of anchor k (ascending): cur = a; while cur exists and class(cur) > k: class(cur) = k, cur = first layout parent of cur (first non-Missing parent after the repeated-target rule; may be Indirect). With the pre-fill `[trunk(), present(@)]` this is exactly 4.11 item 6 (0 trunk chain, 1 @ chain up to the first class-0 node, 2 the rest); the result does not depend on iteration order. Ties by index (D3). The dumper's `assign_priorities` is the reference.

**Grid buffer (`GraphGridView`).** Little-endian. Header: 33 × int32 at byte 0 — [0] format version = 1, [1] mode (`LayoutMode.index`: 0 compact, 1 free), [2] order (`LaneOrder.index`: 0 greedy, 1 compact), [3] unit (1 | 16), [4] rows, [5] lanes, [6] n, [7] E, [8] B, then 12 × (byte offset, element length) for, in order: node row, node lane, node col (int32 × n), edge from, edge to (int32 × E), edge kind, edge route, edge blocked (uint8 × E), bucket kind (uint8 × B), bucket value (int64 × B), bucket start, bucket end (int32 × B). Each array starts at the next multiple of 8 after the previous one (the first at 136). Enum codes (public `static const`): edge kind 0 direct / 1 indirect (Missing never appears); route 0 straight / 1 merge / 2 branch_off (§8.4's r); bucket kind 2 day (0/1 are SPEC §3's `root`/`age`, `time` only, not ported); blocked 0/1. Edges in SPEC §3 order (child asc, then parent position). Rows fit int32: in `free` y ≤ 48·(n − 1). `GraphGridView.fromBytes(Uint8List)` validates header, counts, offsets (8-aligned, in bounds) and lengths (→ `FormatException`), copies once only when `bytes.offsetInBytes % 8 != 0` (`@visibleForTesting bool get copied`), and exposes `bytes` (unmodifiable), the header getters (`mode`, `order`, `unit`, `rows`, `lanes`, `nodeCount`, `edgeCount`, `bucketCount`) and unmodifiable typed views (`nodeRows`, `nodeLanes`, `nodeCols`, `edgeFroms`, `edgeTos`, `edgeKinds`, `edgeRoutes`, `edgeBlocked`, `bucketKinds`, `bucketValues`, `bucketStarts`, `bucketEnds`).

**Goldens (`test/graph_layout/goldens/`).** `README.md` (the regeneration command, seeds, the `57f259c` pin, FNV-1a 64 = offset basis `0xcbf29ce484222325`, prime `0x100000001b3`, over the canonical UTF-8 bytes incl. the trailing `\n`, 16 lowercase hex digits); `design/design-{default,all}.json` (inputs), `design/design-{default,all}.{compact,free}.{greedy,compact}.json` (8 outputs), `design/oracle/design-{default,all}.compact.greedy.json`; `fuzz/cases.jsonl` (≥ 100 seeded canonical inputs, one per line, total a few hundred KB at most) + `fuzz/expected.json` (per case × mode × order: hash + byte length); `fixtures/tiny-all.input.json` + `.{mode}.{order}.json` (4), `fixtures/medium-narrow.input.json` + 4 outputs; `fixtures/hashes.json` (medium-all, large-all: revset, `now_ms`, `utc_offset_min`, input + 4 output hashes and byte lengths; `now_ms` for every fixture case). Mode × order names as in SPEC §3 (`compact`, `free`; `greedy`, `compact`).

**Test port (spike `dart/test/layout_test.dart`, numbers = the spike's test order).** Port: 1 floorDiv; 2 free gap table; 4 day key with offsets/negative ts (re-pointed at the free day-key helper); 5, 6 compact layering; 10, 11, 12 free layering; 13–17 lane packing; 18 packing vs the design-literal scan (2 modes); 24 compact window swap (drop its `optimized` sub-assertion); 25, 26, 27 compact order (2 modes); 28 canonical output + digest (re-derived as a `free` case with day buckets from the amended spike Dart binary); 29 empty graph (2 × 2); 31's value-range cases (V1 × 2, V2 × 2, V3, priority 2^31, ts beyond 2^53, negative priority, 2^53 accepted) as `LayoutContractException`; 32 utcOffsetMin ±1440; 34 invariants (2 × 2, ≥ 1,000 graphs in `invariants_test.dart`). Drop: 3, 7, 8, 9 (`time`), 19–23 (`optimized`), 30, 33 and 31's JSON/type cases (JSON-only; the support parser still rejects them).

**Taken during this run** (also appended to the decisions file's `### 4.11`): (1) anchors lists of any length → the generalised rule above (reduces to item 6 for two anchors); (2) free day-bucket membership = every non-`is_root` node by its clamped T (the spike viewer's reading); (3) names: `GraphGridView` (result view), `GraphLayoutCommand`/`GraphLayoutResult` (worker-internal), `LayoutContractException`, `LayoutMode`/`LaneOrder`; `RepoHandle.graphLayout` returns a record `(topology, grid)`; `mode`/`order`/`budget` default to the Dart pre-fills (free, compact, 2,000,000), `utcOffsetMin` is required; (4) a contract violation crosses as the exception object in `GraphLayoutResult`, not as an error envelope code (no new error code); (5) golden hashes are FNV-1a 64 (no new dependency).

**Open for Ralph (not doable unattended) — record in `deferred:` and `deferred-work.md`:** the "Manual check, once" (`flutter run` on Zanshin, edit the gap function and one tunable `const`, hot reload, a debug relayout must use the new code and value); real-repo dumps and numbers (no repo path given).

### Measurements

*(Written 2026-10-01 by the implementation run.)* Apple M4 Pro (14 cores, 24 GB), macOS 27.0.1 (26A434), on AC power, otherwise idle; Dart SDK 3.14.0-271.0.dev (macos_arm64), rustc 1.95.0, node v26.10.0. The product engine's CLI `packages/zanshin_core/benchmark/graph_layout_cli.dart` (§8.4 bench lines): AOT = `dart compile exe` (`dart build cli` was not needed), JIT = `dart <kernel>.dill` (`dart compile kernel`). Warm = one process with the defaults (W = 10, N = 31); cold = `--warmup 0 --runs 1`, median of 3 processes. `layering` includes the engine's own V1–V4 pass (the CLI's `parse` already validates once); building the grid is not timed.

**Total, median (min) — warm; cold:**

| input | mode / order | n / lanes | AOT warm | AOT cold | JIT warm | JIT cold |
|---|---|---|---|---|---|---|
| fixture-medium-all | compact / greedy | 1002 / 3 | 58 µs (57 µs) | 80 µs | 73 µs (67 µs) | 4.05 ms |
| fixture-medium-all | compact / compact | 1002 / 3 | 105 µs (93 µs) | 149 µs | 166 µs (142 µs) | 9.13 ms |
| fixture-medium-all | free / greedy | 1002 / 4 | 79 µs (68 µs) | 104 µs | 103 µs (94 µs) | 4.48 ms |
| fixture-medium-all | free / compact | 1002 / 4 | 130 µs (112 µs) | 171 µs | 187 µs (160 µs) | 9.81 ms |
| fixture-large-all | compact / greedy | 10002 / 3 | 614 µs (604 µs) | 687 µs | 642 µs (625 µs) | 10.80 ms |
| fixture-large-all | compact / compact | 10002 / 3 | 1.07 ms (1.04 ms) | 1.22 ms | 1.18 ms (1.15 ms) | 26.24 ms |
| fixture-large-all | free / greedy | 10002 / 4 | 835 µs (797 µs) | 838 µs | 1.25 ms (1.20 ms) | 15.41 ms |
| fixture-large-all | free / compact | 10002 / 4 | 1.25 ms (1.23 ms) | 1.46 ms | 1.70 ms (1.63 ms) | 30.12 ms |
| synth-10k | compact / greedy | 9890 / 134 | 838 µs (802 µs) | 1.09 ms | 867 µs (813 µs) | 11.93 ms |
| synth-10k | compact / compact | 9890 / 134 | 28.35 ms (27.75 ms) | 30.76 ms | 21.36 ms (21.01 ms) | 49.83 ms |
| synth-10k | free / greedy | 9890 / 168 | 1.01 ms (969 µs) | 1.11 ms | 1.36 ms (1.31 ms) | 15.64 ms |
| synth-10k | free / compact | 9890 / 168 | 29.76 ms (28.99 ms) | 29.99 ms | 22.44 ms (21.81 ms) | 57.27 ms |
| synth-100k | compact / greedy | 98842 / 147 | 10.75 ms (10.52 ms) | 10.89 ms | 16.11 ms (14.15 ms) | 58.74 ms |
| synth-100k | compact / compact | 98842 / 147 | 55.51 ms (52.35 ms) | 53.98 ms | 47.41 ms (46.22 ms) | 132.98 ms |
| synth-100k | free / greedy | 98842 / 173 | 14.62 ms (13.17 ms) | 15.11 ms | 18.32 ms (17.70 ms) | 75.55 ms |
| synth-100k | free / compact | 98842 / 173 | 51.07 ms (50.13 ms) | 50.80 ms | 51.79 ms (49.58 ms) | 142.51 ms |

(`lanes` is greedy's; the `compact` order ends with ≤ greedy's.)

**Per phase, AOT warm median** (layering / lanes / blocked / routing / ordering):

| input | mode / order | layering | lanes | blocked | routing | ordering |
|---|---|---|---|---|---|---|
| fixture-medium-all | compact / greedy | 11 µs | 44 µs | 1 µs | 1 µs | 0 µs |
| fixture-medium-all | compact / compact | 12 µs | 43 µs | 1 µs | 1 µs | 45 µs |
| fixture-medium-all | free / greedy | 29 µs | 46 µs | 1 µs | 1 µs | 0 µs |
| fixture-medium-all | free / compact | 29 µs | 47 µs | 1 µs | 1 µs | 50 µs |
| fixture-large-all | compact / greedy | 99 µs | 491 µs | 13 µs | 12 µs | 1 µs |
| fixture-large-all | compact / compact | 100 µs | 492 µs | 12 µs | 12 µs | 433 µs |
| fixture-large-all | free / greedy | 292 µs | 511 µs | 12 µs | 12 µs | 1 µs |
| fixture-large-all | free / compact | 284 µs | 494 µs | 12 µs | 12 µs | 442 µs |
| synth-10k | compact / greedy | 116 µs | 656 µs | 50 µs | 22 µs | 1 µs |
| synth-10k | compact / compact | 118 µs | 744 µs | 75 µs | 29 µs | 27.39 ms |
| synth-10k | free / greedy | 354 µs | 588 µs | 42 µs | 22 µs | 1 µs |
| synth-10k | free / compact | 369 µs | 634 µs | 73 µs | 28 µs | 28.67 ms |
| synth-100k | compact / greedy | 1.40 ms | 8.19 ms | 822 µs | 294 µs | 23 µs |
| synth-100k | compact / compact | 1.59 ms | 8.66 ms | 867 µs | 319 µs | 44.02 ms |
| synth-100k | free / greedy | 4.92 ms | 8.18 ms | 951 µs | 357 µs | 29 µs |
| synth-100k | free / compact | 4.39 ms | 7.46 ms | 837 µs | 297 µs | 37.97 ms |

**Per phase, the other three runs** (layering / lanes / blocked / routing / ordering), fixture-large-all and synth-100k:

| input | mode / order | AOT cold | JIT warm | JIT cold |
|---|---|---|---|---|
| fixture-large-all | compact / greedy | 115 / 544 / 13 / 13 / 1 µs | 95 / 517 / 15 / 12 / 1 µs | 3.38 / 6.64 / 0.39 / 0.29 / 0.07 ms |
| fixture-large-all | compact / compact | 117 / 573 / 14 / 13 / 497 µs | 94 / 604 / 15 / 12 / 462 µs | 3.49 / 6.66 / 0.40 / 0.32 / 15.44 ms |
| fixture-large-all | free / greedy | 316 / 512 / 13 / 12 / 1 µs | 434 / 774 / 15 / 12 / 2 µs | 8.42 / 6.28 / 0.37 / 0.29 / 0.07 ms |
| fixture-large-all | free / compact | 342 / 574 / 14 / 14 / 511 µs | 430 / 772 / 15 / 12 / 453 µs | 8.21 / 6.30 / 0.36 / 0.31 / 14.94 ms |
| synth-100k | compact / greedy | 1.41 / 8.29 / 0.82 / 0.29 / 0.02 ms | 1.65 / 12.91 / 1.15 / 0.39 / 0.03 ms | 10.86 / 44.82 / 1.77 / 1.16 / 0.13 ms |
| synth-100k | compact / compact | 1.47 / 8.70 / 0.84 / 0.30 / 42.82 ms | 1.39 / 10.61 / 0.92 / 0.31 / 33.87 ms | 9.98 / 42.49 / 1.71 / 1.11 / 78.00 ms |
| synth-100k | free / greedy | 5.12 / 8.59 / 1.01 / 0.38 / 0.03 ms | 6.33 / 10.54 / 0.94 / 0.32 / 0.03 ms | 40.69 / 31.90 / 1.76 / 1.10 / 0.12 ms |
| synth-100k | free / compact | 4.24 / 7.37 / 0.82 / 0.30 / 38.07 ms | 6.16 / 10.53 / 0.91 / 0.31 / 33.62 ms | 37.99 / 30.14 / 1.58 / 1.00 / 71.84 ms |

The full 16-row per-phase tables for all four runs were produced by a scratch driver over the CLI (not committed); every bench line's digest equals the one `compare.mjs --digest` recomputes from the outputs. For scale: the spike README's review measured the spike Dart AOT with monomorphic sorts at 614 µs for fixture-large-all compact/greedy; the product engine measures 614 µs. The `compact` order's search is budget-bound on synth-10k and synth-100k (the 2,000,000-unit default), as the spike reported.

**Differential** (`node tools/compare.mjs --digest --core outputs/bin/graph_layout_core`, after the dumper switch): the spike matrix 66 cells (11 inputs × 3 modes × 2 orders: the 8 earlier inputs, `fixture-tiny-all`, and the two `design-e243dd2-*` ad-hoc inputs the manifest lists as unregistered) — all identical and invariant-clean, bench digests checked; the core matrix 44 cells (11 inputs × {compact, free} × {greedy, compact}) — all byte-equal to the Rust output (greedy) or the spike Dart output (`compact` order) and invariant-clean, synth-50k and synth-100k (where the budget binds) included. `node tools/fuzz.mjs --cases 300`: 54 input × 2 modes + 14 CLI probes as expected, 1,800 random runs rust = dart = reference. `node tools/js_oracle.mjs --fuzz 300`: identical to the design; §7.2's expectations hold (free rows 209 / 377, 4 lanes). `cargo test --release` (spike `rust/`): 32 passed; `dart run test/layout_test.dart` (spike `dart/`): 37 passed; `rust-inputs` inline tests: 2 passed.

**Dumper switch.** Re-dumped twice: every pre-existing input byte-identical to the `walk_graph` dumps (only `manifest.json` changed — its source strings and the new entries), both runs byte-identical to each other; `fixture-tiny-all.json` is new (priorities `[1, 2, 2, 2, 0]`).

**Occupancy** (`dart run benchmark/graph_layout_occupancy.dart`, JIT worker, release cdylib; µs from issuing a 60-id `commitContents` page to its reply; min / median of 7 after 1 warm-up):

| store | page alone | behind `graphLayout(free, compact)` | behind `graphTopology(withTimestamps: true)` |
|---|---|---|---|
| large-10k loose | 1,062 / 1,178 | 1,217,481 / 1,239,237 | 1,212,448 / 1,227,730 |
| large-10k packed (`git gc`) | 948 / 980 | 58,505 / 59,125 | 57,350 / 57,817 |

So a page queued behind a layout waits for the topology call's timestamp loads (~1.2 s loose, ~57 ms packed); the layout itself — input builder, engine, grid write and its copy — adds ~1.3 ms at 10k packed (~11 ms on the noisier loose rows). The first timestamped call on the fresh loose copy took ~20 s (cold object reads); it is the warm-up run and not in the table.

**Goldens:** 836,113 bytes in 26 files under `packages/zanshin_core/test/graph_layout/goldens/` (fuzz cases 432 KB, medium NARROW input + 4 outputs ~324 KB); a second `node tools/goldens.mjs` run rewrote them byte-identically.

## Verification

**Commands:**
- spike (from `spikes/graph-layout-ab/`): the rebuild + `cargo test --release --manifest-path rust/Cargo.toml`, `(cd dart && dart run test/layout_test.dart)`, `node tools/compare.mjs --digest`, `node tools/fuzz.mjs --cases 300`, `node tools/js_oracle.mjs --fuzz 300`, `node tools/compare.mjs --core <binary>` -- expected: exit 0, every cell `=`.
- `node tools/goldens.mjs` twice -- expected: the second run leaves `git status --porcelain packages/zanshin_core/test/graph_layout/goldens` empty.
- from `packages/zanshin_core` with the `[tasks.test-core]` env: `dart test test/graph_layout test/worker/graph_layout_test.dart`, then `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` -- expected: green, no issues.
- the AC 1 greps -- expected: no hits.
- `cargo make test` (`nohup … > <scratchpad>/gate.log 2>&1 &`, then `caffeinate -w <pid>` in the same turn; exit code from the log) -- expected: exit 0, `extern-coverage: OK`, `coverage-check: OK`.

**Manual checks:**
- `packages/zanshin_core/test/graph_layout/goldens/` totals well under 1 MB; no file under `spikes/graph-layout-ab/{inputs,outputs}` is tracked.
- `epic-4-context.md` is newer than every file in `_bmad-output/planning-artifacts/` and still starts with `# Epic 4 Context:`.

## Auto Run Result

Status: done
Blocking condition: none

**Summary.** The spike's Dart layout engine is ported, for the shipped scope only (modes `compact` | `free`, lane orders `greedy` | `compact`), into `packages/zanshin_core/lib/src/graph_layout/`: flat typed arrays, monomorphic sorts, `const` tunables, the budget a request parameter, `free` emitting day buckets, V1–V4 as `LayoutContractException`. Around it: the input builder (topology → engine input, with the repeated-target rule and the anchors priority rule), the worker's `GraphLayoutCommand` behind `RepoHandle.graphLayout(…)`, which replies with the topology and a one-buffer grid (`GraphGridView`), one `TransferableTypedData` each. SPEC moved to `docs/graph-layout.md` with dated amendments, and §13 is new. Free day buckets went into the spike's Rust and Dart references first. The spike dumper switched to `Repo::graph_topology` + `Repo::commit_contents`. 29 committed goldens (843,707 bytes) come from the references via the new `tools/goldens.mjs`. Docs and tracking were updated. Implemented by the first run (cut off by HTTP 429 in its review step); this resumed run did the review pass, its patches, the verification and the gate.

**Files changed** (vs `2e7a64d`):
- `docs/graph-layout.md`: the SPEC's new home (moved from the spike), with dated §2/§3/§4.2/§4.3/§4.5/§6/§7.3/§11.2/§12 amendments and §13 "Product engine".
- `spikes/graph-layout-ab/SPEC.md`: now a pointer.
- Spike README / notes, `tools/*.mjs`, `dart/`, `rust/`: path sweep; README status item 9.
- `spikes/graph-layout-ab/rust/src/{layout,checks,lib,input}.rs`, `dart/lib/src/{layout,compact_order}.dart`, `dart/bin/graph_layout.dart`, `dart/test/layout_test.dart`, `tools/{compare,fuzz,payload}.mjs`: free day buckets in both references, the free I5 check, the fuzz reference's free branch, the Dart CLI's `--budget`, and `compare.mjs --core`.
- `spikes/graph-layout-ab/rust-inputs/src/{jj_dump,input,synth,main,manifest}.rs`, `Cargo.toml`: the dumper on the topology + contents calls, the amended dedupe, the anchors priority rule, the tiny fixture entry, inline tests.
- `spikes/graph-layout-ab/tools/goldens.mjs` (new): writes the goldens (fuzz, design, oracle, fixtures, budget-cut) with FNV-1a 64.
- `packages/zanshin_core/lib/src/graph_layout/` (new):
  - `layout_request.dart`: the public request enums, defaults and `LayoutContractException`.
  - `layout_input.dart`: `LayoutInput` and the V1–V4 validation.
  - `layout_engine.dart`: the engine and `computeGraphGrid`.
  - `compact_order.dart`: the `compact` lane order.
  - `sort.dart`: the monomorphic sorts.
  - `graph_grid_view.dart`: `GraphGridView` and the `@internal` writer.
  - `input_builder.dart`: topology → `LayoutInput`.
  - `layout_reply.dart`: the worker/caller glue.
- `packages/zanshin_core/lib/src/worker/{commands,responses,isolate,handle}.dart`: `GraphLayoutCommand`, `GraphLayoutResult`, `ZanshinWorker.graphLayout` with the dispatch arm, and `RepoHandle.graphLayout`.
- `packages/zanshin_core/test/graph_layout/` (new):
  - `engine_test.dart`, `invariants.dart`, `invariants_test.dart`, `golden_test.dart`, `input_builder_test.dart`, `grid_view_test.dart`;
  - `support/{spec_json,topology_envelope}.dart`;
  - `goldens/` (29 files).
- `packages/zanshin_core/test/worker/graph_layout_test.dart` (new): the real-cdylib end-to-end tests.
- `packages/zanshin_core/benchmark/{graph_layout_cli,graph_layout_occupancy}.dart` (new): the product CLI (§6 subset) and the worker occupancy benchmark.
- `docs/ffi-abi.md`, `_bmad-output/planning-artifacts/{architecture,epics}.md`, `_bmad-output/project-context.md`: dated notes.
- `_bmad-output/implementation-artifacts/`:
  - `decisions-review-4-10-to-4-13.md`: `### 4.11`, 11 rows.
  - `deferred-work.md`: "Surfaced in Story 4.11", 6 items.
  - `sprint-status.yaml`: 4-11 → `done`.
  - `epic-4-context.md`: 4.11 done, the engine line, the export hint.
  - this spec.

**Review findings** (one pass, 34 findings: medium 1, low 17, false 16; details in § Review Triage Log):
- **Patches applied** (7 entries; by entry verdict medium 1, low 6):
  - the non-default `anchors` pass-through test (medium);
  - the four untracked files committed with the story;
  - `--budget` documented in §6 (dated);
  - `writeGraphGrid` marked `@internal`;
  - the product CLI names an unknown command before parsing flags;
  - a decisions row for the budget-cut goldens and `--budget`, plus a review-pass row;
  - four missing tests: an anchor chain into an out-of-range target, two out-of-range edges to one target, an unknown parent kind, and `graphLayout` after the worker closes.
- **Deferred** (2, low, in `deferred:` and `deferred-work.md`):
  - the barrel-export hand-off to 10.12 is untracked in 10.12's entry;
  - `project-context.md` has no engine rules (an agent-context edit).
- **Rejected as low:**
  - the budget-bound synth regime is not in the gate (covered by the budget-cut goldens and the differential);
  - an `Int32List` wraps a priority ≥ 2^31 (hand-built inputs only);
  - warnings are lost on a contract violation (reachable only with timestamps beyond ±2^53 ms; the fix adds public surface);
  - `compare.mjs --core` with no value (a dev tool that already fails loudly);
  - `goldens.mjs` wipes before its checks (git restores the goldens);
  - stale spec records (the fix edits this spec; determinism re-established below);
  - the caller re-derives the builder error (correct today; the fix adds reply fields);
  - the int32 narrowing of y (overflows only past ~44 M nodes).
- **Rejected as false (16):** each with its refutation in the Triage Log.

**Follow-up review recommended:** false. One medium entry was patched and no high, so this first pass does not meet the threshold (a high, or two or more medium).

**Verification (this run, after the patches):**
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed` over `packages/zanshin_core`: clean (113 files).
- `dart test test/graph_layout test/worker/graph_layout_test.dart` with the `[tasks.test-core]` env: 118 passed.
- Spike, all exit 0:
  - rebuild of both references;
  - `cargo test --release` (`rust/`) and `dart run test/layout_test.dart`;
  - `node tools/fuzz.mjs --cases 300` and `node tools/js_oracle.mjs --fuzz 300`;
  - `node tools/compare.mjs --digest --core outputs/bin/graph_layout_core` with the CLI recompiled: 66 spike cells identical and invariant-clean, 44/44 core cells byte-equal and invariant-clean;
  - `graph_layout_core foo` → `unknown command "foo"`, exit 2.
- `node tools/goldens.mjs` twice: all 29 golden files byte-identical to the tree before, including the three budget-cut files (843,707 bytes total).
- AC 1 greps: no hits. `lib/zanshin_core.dart`, `app/`, `crates/`, `schemas/` and `coverage-baseline.txt` are unchanged; nothing under the spike's `inputs/` or `outputs/` is tracked.
- **Gate:** `cargo make test` (unpiped, log in the scratchpad), `GATE_EXIT=0` in 1,297 s:
  - `coverage-check: OK — coverage held at 99.47% (14553/14631 lines)`;
  - `extern-coverage: OK — every zanshin-ffi extern "C" fn is covered (allow: zanshin_buffer_free)`;
  - the baseline is unchanged (no Rust file changed).
- During the review layers some files' mtimes changed but not their content (checked against the diff staged before the layers ran). `epic-4-context.md` was edited last, so it is again newer than every planning artifact.

**Residual risks:**
- The hot-reload manual check and real-repo numbers stay open for Ralph (`deferred:` items 1–2).
- A layout on a loose store holds the worker for its timestamps (~1.2 s at 10k; item 3).
- The large-10k `free` worker test is slow on a cold copy (item 4).
- 10.12 must add the barrel export (item 5).
