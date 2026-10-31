---
title: "Story 10.4 — Graph edges: router B's rounded lines from 4.15, dashed indirect edges, bridges per window, the @ lineage, hover and dim, hit lookup and the route report"
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_revision: 'e157c3f1418bdb406d4c3cea6f110bc1599c0e6b'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The graph edges were not checked visually (Marionette) in the running catalogue against the DS cards.
    evidence: |-
      The unattended loop cannot hold a `flutter run -d macos -t widgetbook/main.dart` session. Widget tests cover geometry, dashes, bridges, lineage, classification, culling, the hit lookup and paint order; the smoke tests show `graph/viewport/recording` and the 50k Scale case paint edges.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
    resolved: >-
      2026-10-31 — fixed (console session, Marionette): rounded routes, dashed indirect edges, tracks and bridges match lines.card.html (gap markers are 10.19's); a profile build scrolled 50k/100k nodes at ≤ 7.1 ms per frame, none over 8.3 ms.
---

<intent-contract>

## Intent

**Problem:** The graph viewport (10.1–10.3) paints cards but no lines. Its `paintEdges` hook is unused, and nothing turns 4.15's router B output into pixels, so the graph shows no parent → child relation, no hidden history, no @ lineage and no crossings.

**Approach:** Build the edge layer that `_bmad-output/planning-artifacts/epics.md:8985-9146` specifies, as amended by its 2026-09-30 and 2026-10-14 notes (the later note wins over items 1–11; item 5, the elided marker, is 10.19's). A `GraphEdgePainter` strokes 4.15's polylines (`RouteGeometry`) with r = 10 rounded corners, dashes Indirect edges, cuts the bridges of the visible window into the geometry, highlights @'s lineage, classifies hover and dim, answers point → edges, and is plugged into the viewport's `paintEdges` hook. A route report joins 10.1's checker. The open items I1 and I2 are settled below.

## Boundaries & Constraints

**Always:**
- **Routing is 4.15's.** The painter computes no route. Input to `RouteClasses.compute` comes from `GraphLayout` accessors: rows, cols, `unit`, `mode == free`, per edge parent/child/kind (`GraphEdgeKind.indirect` → 1, `direct` → 0: `GraphGridView`'s codes, not exported), and `parentCountOf`. `RouteMetrics` takes W, H, gapX, gapY, pad from `GraphMetrics`. The class stage runs once per layout; a W/H change re-runs only the geometry stage with the same `RouteClasses` (no layout request). Up to `routeSyncNodeLimit` nodes both stages run synchronously; above it, in `Isolate.run` over typed arrays (docs/graph-layout.md §14.5).
- **Coordinates.** Router geometry is in plane coordinates and equals `UniformRows` + `GraphMetrics.x` (y = pad + (maxRow − row)/U·pitch, x = pad + col·colW). The hook's `origin` maps plane → screen.
- **Path shape** (DS GraphEdge.jsx:42-53): consecutive equal points dropped; every inner bend gets a quadratic corner with r = min(10, half of each adjacent segment), control point at the bend. Each edge's path starts at its parent end (10.20 strokes it partially by length with `PathMetric.extractPath`). Edge identity: the edge index within a layout; across layouts (child key, parent key) — documented, no extra code.
- **Style** (DS graph.css:65-69, tokens via `GraphTheme`): 1.5 px `--edge`; hovered `--edge-hov`; lineage `--co` at 2.25 px over a `--co-glow` stroke blurred with σ 2 (drop-shadow 4 px); dimmed lines at opacity `1 − .72·dim` (dim ∈ [0, 1], the owner's 160 ms fade progress; .28 at 1). Indirect edges dashed 3 on, 5 off from the path's start (SVG dasharray phase), dashes made as geometry (`extractPath` intervals). Butt caps.
- **Classification** (design graph-view.jsx:1104-1108), per edge (p, c), given a `GraphEdgeHighlight` (hovered node or null, a per-node focus set or null = focus path off, dim progress, lineage on/off):
  - lineage iff lineage on and p and c are both in @'s lineage (the inclusive ancestors of `workingCopyIndex` over layout edges: a per-node bitset built once per painter in O(n + E));
  - hovered iff focus ≠ null ? p and c both in focus : p or c is the hovered node;
  - dimmed iff focus ≠ null and not hovered.
  - Paint: lineage beats hovered beats normal for colour; dimmed applies on top. Groups, each one `Path` and one `drawPath` (lineage: glow + stroke): normal, normal dimmed, hovered, lineage, lineage dimmed — painted in that order (normal, then hovered, then lineage).
- **Bridges.** Per paint, one `RouteGeometry.bridges` query over the visible window grown by 6 px. A horizontal break removes 6 px either side of the crossing x from the horizontal edge's run; a vertical break removes 6 px either side of the crossing y from the vertical edge's run; the cut is applied in arc length on the edge's rounded path, so the dash phase runs through it. Never masks or `saveLayer`. Edges sharing a node never bridge (the router's rule, design question (d)). Always on.
- **Virtualized.** Per painter: each edge's bounds from its points; an index sorted by top in blocks of 64 with each block's max bottom (O(E log E)). Per paint, the edges whose bounds meet the visible window grown by an 8 px margin (glow, cuts) — horizontally culled — are the only ones turned into paths. A straight edge spanning the window with both ends off-screen is drawn.
- **Hit lookup.** `edgesAt(planePoint, {tolerance = 4})` → the sorted edge indices whose polyline (unrounded) lies within the tolerance, via the same index. Router B overlaps lines only on a shared entry slot's stem and an overflowing shared exit, so only those return several.
- **Route report** (10.1's checker, `layout_invariants.dart`): from polylines and card rects, counts segments behind a card that is not one of the edge's endpoints (interior overlap beyond 0.5 px) and collinear overlaps (> 1 px) between lines router B does not share (shared = same entry slot, or same parent and same exit point). Behind-card hits on edges the router reports (its `fallbackEdges`, `overfullEdges`, or a gutter holding > 9 lines) are counted as explained. It passes iff there is no collinear overlap and, in Compact (a gate), no behind-card hit at all; in Free behind-card hits are only counted.
- **Hook wiring.** The painter paints through the viewport's existing `paintEdges` hook (behind the cards, inside 10.1's clip); no viewport change. Colours come only from `GraphTheme` (new roles `edge`, `edgeHover`, `lineage`, `lineageGlow`, derived in `fromColors` from `ZsColors.edge`, `edgeHov`, `co`, `coGlow`).

**Never:**
- A route computed in view code, or reading `GraphLayout.shapeOf` for geometry; an all-pairs crossing pass in production code (test oracles only).
- The elided stub, label, gap markers or their cuts, a legend, edge tooltips (10.19); the focus-set computation, the dim animation controller, hover-from-edges (10.6); motion (10.20); drop zones (10.10); lane colours; a Crossings option.
- Golden tests. Touching `graph_poc/`, `main2/3/4.dart`, `features/commits/` or `packages/zanshin_core`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Short segment | bend between segments of 8 and 30 px | corner radius 4 | — |
| Straight edge | 2-point polyline | one line, no corner | — |
| Indirect edge | `GraphEdgeKind.indirect` | dashes 3 long, 8 apart, starting at the parent end | — |
| Horizontal break | bridge with `verticalBreaks` 0 | the horizontal edge's path has a 12 px gap centred on the crossing; the vertical stays whole | — |
| Vertical break | bridge with `verticalBreaks` 1 | the vertical edge's path has a 12 px gap; the horizontal stays whole | — |
| Shared node | two lines of one parent cross | no cut | — |
| No @ in layout | `workingCopyIndex` null | no lineage edges | — |
| Focus off, hover c | hovered = c | edges touching c hovered; nothing dimmed | — |
| Focus on | focus {a, b} | edge a–b hovered, every other edge dimmed | — |
| Shared slot | node with `parentCountOf` 1 and 2 Indirect edges | `edgesAt` on the shared stem returns both | — |
| Empty layout | no nodes | the painter paints nothing; report passes | no exception |
| > 20k nodes | synthetic 50k | geometry via `Isolate.run`; edges appear when it completes | a superseded result is dropped |
| D11 (I2) | a fork whose child column holds a lower card between the rows | the router routes it through a gutter; the report finds no behind-card hit | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:8985-9146` -- Story 10.4 with its notes (:8988-9035); witnesses at :9030-9034, :9134-9146.
- **Router B** (`packages/zanshin_core/lib/src/graph_layout/router.dart`, exported by `lib/zanshin_core.dart:118`; read-only):
  - `RouteClasses.compute` :119-128 (inputs), fields :376-451 (`kinds`, `slots`, `deep`, `fallbackEdges`, `overfullGutters`, `gutters`, `directFallbacks`, `edgeFroms`/`edgeTos`, `nodeRows`/`nodeCols`).
  - `RouteMetrics` :522-540; `RouteGeometry` :546-624 (`pointStarts`/`points` polylines from the parent's top to the child's bottom, `overfullEdges`), `bridges(x0, y0, x1, y1)` :636-679 (window [x0,x1)×[y0,y1), horizontal break unless `verticalBreaks`); `RouteBridges` :700-720.
  - Positions `_positions` :802-815 — the same mapping as `UniformRows`.
  - Spec: `docs/graph-layout.md` §14 (:1462-1624); §14.4 bridges, §14.5 sync limit.
- **Design** (inspiration; DS tokens/CSS win): `_bmad-output/implementation-artifacts/design_system/components/graph/GraphEdge.jsx:42-53` (rounded path), :98-112 (cuts as holes); `graph.css:64-69` (style); `GraphEdge.d.ts:34-50` (constants); `_bmad-output/implementation-artifacts/design/graph-view.jsx:1096-1110` (focus set, classification, sort order).
- **App, graph feature** (`app/lib/src/features/graph/`):
  - `graph_viewport_render.dart:23-25` -- `GraphPaintHook(context, origin, visibleRect)`; :257-266 `paintEdges`; :568-589 paint order (background → edges → cards → overlay).
  - `graph_layout.dart:174-307` -- `GraphLayout` (edges ordered by child, then parent position; `parentEdges`, `childEdges`, `kindOf`, `parentCountOf`, `workingCopyIndex`, `mode`, `unit`, `rows`).
  - `graph_metrics.dart` -- W, H, gapX, gapY, pad.
  - `vertical_layout.dart:78-113` -- `UniformRows` (the router's y); `PerNodeTops` :116-156 is for hand fixtures only (see Design Notes).
  - `day_axis.dart:114-228` -- `GraphDayAxisPainter`, the house pattern for a hook painter (owner disposes; new inputs → new painter, repaint only).
  - `layout_invariants.dart` -- 10.1's checker; add the route report here.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart:14-288` -- add the four edge roles in all six places; `packages/zanshin_ui/lib/src/design/zs_colors.dart:863-880` (`edge`, `edgeHov`, `co`, `coGlow`); test `packages/zanshin_ui/test/design/graph_theme_test.dart`.
- **Catalogue:** `app/widgetbook/folders/graph.dart:160-271` -- `_GraphDemoState` (rows/axis caching pattern, `ListenableBuilder` over the card controller; add the edge painter and hover). `app/widgetbook/graph/synthetic_layout.dart` -- 10k–100k fixtures; `graph_recordings.g.dart` -- 16 recordings (`<sample> <free|compact> <compact|greedy>`).
- **Tests:** `app/test/features/graph/graph_harness.dart:27-81` (`handLayout`: edges sorted by child only — Dart's sort is not stable, so make it stable to keep first parents first; all edges direct — add an `indirect` option), :171 (`edges` hook); `layout_invariants_test.dart`; `app/test/widgetbook/catalogue_smoke_test.dart`.
- **Open items:** `_bmad-output/implementation-artifacts/deferred-work.md:687-690` (I1), :899-901 (I2); `docs/graph-layout.md:847-849` (§4.8 D11), :1238-1244 (§9 D11).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` (+ its test) -- add `edge` (`--edge`), `edgeHover` (`--edge-hov`), `lineage` (`--co`), `lineageGlow` (`--co-glow`) with DS citations, in ctor, `fromColors`, `copyWith`, `lerp`, `==`, `hashCode`.
- `app/lib/src/features/graph/graph_edges.dart` (new):
  - `RouteMetrics graphRouteMetrics(GraphMetrics)`; `RouteClasses graphRouteClasses(GraphLayout)`; `FutureOr<RouteGeometry> routeGraph(GraphLayout, GraphMetrics, {RouteClasses? classes})` (sync ≤ `routeSyncNodeLimit`, else `Isolate.run` over the extracted arrays).
  - `Path graphRoundedPath(Float64List points, int start, int end, {double radius = 10})` (points as x, y pairs).
  - `GraphEdgeHighlight` (immutable: `hoveredNode`, `focus` (`Uint8List?` per node), `dim`, `lineage = true`) and `GraphEdgeStyle classify(int edge, GraphEdgeHighlight)` on the painter (`normal`, `hovered`, `lineage`, plus a `dimmed` flag).
  - `GraphEdgePainter(layout, geometry, theme)`: lineage bitset, bounds index; `Path edgePath(int edge)`; `List<int> edgesIn(Rect window)` (the culled set paint uses); `Map<int, List<…>> cutsIn(Rect window)` (per edge its cuts from the bridge query); `List<int> edgesAt(Offset, {double tolerance = 4})`; `void paint(PaintingContext, Offset origin, Rect visible, {GraphEdgeHighlight highlight})`.
- `app/lib/src/features/graph/layout_invariants.dart` -- `RouteReport` (counts: `behindCard`, `behindCardExplained`, `collinear`, the router's `directFallbacks`, `overfullGutters`, `overfullClusters`; `gate`; `passes`) and `checkRouteLines({...raw arrays...})` plus `checkRoutes(RouteGeometry, {required bool gate})` building card rects and the explained flags from the geometry.
- `app/widgetbook/folders/graph.dart` -- `_GraphDemoState` keeps `RouteClasses` per layout and `RouteGeometry` per metrics (async above the limit, stale results dropped, disposed-safe) and passes `paintEdges` with `hoveredNode` from `_cards.hovered` (focus off, lineage on). Doc comment updated.
- `app/test/features/graph/graph_harness.dart` -- stable edge sort; `indirect` (set of edge-list positions) option.
- `app/test/features/graph/graph_edges_test.dart` (new) and `layout_invariants_test.dart` -- the matrix and the ACs.
- `docs/graph-layout.md` -- one dated sentence under §9 D11 (and §4.8's known limit): router B routes such an edge through a gutter in both modes, so no line passes behind the lower card (Story 10.4, I2).
- `_bmad-output/implementation-artifacts/deferred-work.md` -- mark I1 and I2 resolved in place (sub-bullet "Resolved in Story 10.4 (2026-10-30): …").

**Acceptance Criteria:**
- **Geometry.** Given the recordings at W 160 / 240 / 400 and H 40 / 62, when edges are painted, then every edge's path equals `graphRoundedPath` of 4.15's polyline for that edge; and given a W change, then the new geometry reuses the identical `RouteClasses` and the layout's `version` is unchanged.
- **Dashes.** Given an Indirect edge, when painted, then its contours are 3 px long (the last may be shorter) and begin at the parent end.
- **Bridges.** Given a recording or hand layout with a horizontal-break and a vertical-break crossing, when the window covers them, then the broken edge has a 12 px gap centred on the crossing and the other edge none; given random windows of the synthetic 10k fixture, `cutsIn` equals a test-only all-pairs oracle over the strokeable edges' polylines, including a crossing whose vertical starts off-screen; given a crossing of two lines sharing a node, then no cut.
- **Lineage.** Given a layout where @ descends from a merge, when painted, then every ancestor edge, the merged side branch included, is in the lineage group, drawn last with stroke width 2.25.
- **Classification.** Given a focus set, then exactly the edges inside it are hovered and all others dimmed; with focus off and a hovered node, its edges are hovered and none dimmed.
- **Virtualization.** Given the synthetic 100k fixture and a 800 × 600 window, then `edgesIn` returns exactly the edges whose bounds meet the window plus margin (checked against a brute-force scan), a long straight edge spanning the window with both ends off-screen is included, and a viewport paint issues one `drawPath` per non-empty group (lineage: two).
- **Hit lookup.** Given a shared entry slot, `edgesAt` on its stem returns both edges; elsewhere a single line returns one; away from lines, none.
- **Route report.** Every Compact recording passes; a Free recording or synthetic free layout reports its router fallbacks without failing; a hand-built gutter overflow (> 9 lines on one gutter) in Compact fails with its hits explained; a hand-built collinear overlap of unshared lines fails; the D11 case passes with 0 behind-card hits.
- **Catalogue.** Given every Graph use case pumped (smoke test), none throws; the recording use case paints edges.

## Spec Change Log

## Review Triage Log

### 2026-10-30 — Review pass
- verdicts: 34 findings — high 0, medium 3, low 29, false 2, maybe-false 0 (blind 14, edge 6, verification-gap 4, intent-alignment 10)
- findings:
  - `[low]` `[patch]` (blind #1, grouped with edge #1, #2 and verification-gap other) A failed `Isolate.run` route left `GraphRouteCache._routing` set forever (edges never appear for that request), kept the future in `_inFlight` and escaped as an unhandled error. The cache now removes the future on any outcome, clears `_routing` when it still names the failed request, and reports the error through `FlutterError.reportError`.
  - `[low]` `[patch]` (blind #2) `checkRoutes` explained every line of an overfull gutter, inner lines included, which cannot reach a card; a real behind-card hit there would have been hidden. Only lines whose offset `|gutterSteps|·6 ≥ gapX/2` are explained now.
  - `[low]` `[reject]` (blind #3) The gutter budget 9 is a literal copy of the router's private `_gutterBudget`. Exporting it means touching `packages/zanshin_core`, which this story must not; the comment names the source and the overflow test pins the behaviour.
  - `[low]` `[patch]` (blind #4) No test of a dashed edge through a bridge cut. Added: the dashes keep their 8 px grid on both sides of the 12 px gap and nothing is drawn inside it.
  - `[medium]` `[patch]` (blind #5, grouped with verification-gap #1 and intent #4) `paint`'s own output was never asserted: its translate/shift and its passing of each edge's cuts could break with every test green, and the geometry witness compared `edgePath` with the function it calls. Added a scrolled-viewport `paints` test that includes a point of a known polyline and excludes a known bridge crossing.
  - `[low]` `[reject]` (blind #6) Above the sync limit a W change copies `RouteClasses` into and out of the isolate. Only the geometry stage re-runs, as §14.5 says; the copy is the cost of `Isolate.run`, which the design mandates there.
  - `[low]` `[reject]` (blind #7) `_Arc` measures each corner of a dashed or cut edge with a fresh `Path` per paint. Only edges in view that are dashed or cut pay it; Skia's own measure keeps the cuts where `extractPath` expects them. No frame cost was observed.
  - `[low]` `[patch]` (blind #8, grouped with intent #8) The shared-exit branch of `checkRouteLines.shared` and `edgesAt` on an overflowing shared exit were untested. Added a raw-array shared-exit case and an `edgesAt` case at W 160.
  - `[low]` `[reject]` (blind #9) `edgesAt` hits the unrounded polyline and ignores bridge gaps. The spec defines the lookup on the unrounded polyline with a 4 px tolerance; the corner differs by at most 3 px and a gap is 12 px of an edge the pointer is plainly on.
  - `[low]` `[patch]` (blind #10) A fractional `dim` was untested. The paint test now asserts the alpha at `dim` .5.
  - `[low]` `[reject]` (blind #11, grouped with edge #4) `GraphEdgeHighlight.focus` is not checked against the layout's node count. A focus set of another layout is the owner's bug (10.6); indexing past it throws loudly, which is correct.
  - `[low]` `[reject]` (blind #12) The cache keeps one geometry, so toggling metrics on a > 20k layout re-routes. A catalogue convenience; 10.5 owns the product cache.
  - `[low]` `[reject]` (blind #13) The 50k smoke test polls real time and the 100k fixture is heavy. Both finish within the suite's normal run (524 tests green); the 100k case is the epic's witness.
  - `[false]` `[reject]` (blind #14) "sprint-status.yaml and the Marionette outcome are missing." Both are written at finalize, in the spec's commit.
  - `[low]` `[patch]` (edge #1) Grouped with blind #1; patched there.
  - `[low]` `[patch]` (edge #2) Grouped with blind #1 (the failed future stayed in `_inFlight`, so `settled()` rethrew); patched there.
  - `[low]` `[reject]` (edge #3) A synchronous `routeGraph` throws in `build` for invalid input. `RouteClasses.compute` throws only on input that breaks the layout contract, which the catalogue's fixtures pass `checkLayoutInvariants` for; a loud failure on impossible input is correct.
  - `[low]` `[reject]` (edge #4) Grouped with blind #11.
  - `[false]` `[reject]` (edge #5) "A NaN `dim` gives an undefined colour." `dim` comes from an animation value in [0, 1]; NaN is not reachable from any caller.
  - `[low]` `[reject]` (edge #6) A W change during the first async route of a > 20k layout re-runs the class stage in the isolate. Rare (a resize while the first route is in flight) and only costs time; the result is correct.
  - `[low]` `[patch]` (verification-gap #2) The cache's per-layout class reuse was untested. Added a two-layout case.
  - `[low]` `[patch]` (verification-gap #3) Dashes were tested only with a window covering the whole edge. Added a partial-window case.
  - `[low]` `[patch]` (verification-gap other) Grouped with blind #1.
  - `[medium]` `[patch]` (verification-gap #1) Grouped with blind #5; patched there.
  - `[low]` `[reject]` (intent #1) I2's witness is a hand stand-in, not a 4.13 stack layout. The app's `GraphLayout` carries no stacks until 10.17, and the router treats a stack node like any node (§14.1); the fork-or-gutter rule the witness exercises is the one D11's edge meets.
  - `[low]` `[patch]` (intent #2) The new D11 sentence said "in Compact no line passes behind the lower card" without the router's reported exception, an overfull gutter. The sentence now names it.
  - `[low]` `[reject]` (intent #3) The sprint-status 10-4 entry was not checked against I1. It was: the entry's 2026-09-30 note says item 5 moves to 10-19, which answers (a) "no counts".
  - `[medium]` `[patch]` (intent #4) The geometry witness compares `edgePath` with the function it calls. Grouped with blind #5; patched there.
  - `[low]` `[reject]` (intent #5) The W-change witness is class reuse plus an unchanged layout version, not a widget repaint. That is what "without a layout request" means; the repaint is the viewport's hook (10.1).
  - `[low]` `[reject]` (intent #6) Free fallback counts are asserted on a synthetic free layout, not a Free recording. The recordings pass the counted report; the synthetic layout is where the router actually reports fallbacks.
  - `[low]` `[reject]` (intent #7) The bridge oracle takes its edge set from `edgesIn`. The AC defines the oracle over the strokeable edges, and every edge with a crossing in the window is strokeable.
  - `[low]` `[patch]` (intent #8) The overflowing-shared-exit case of the hit lookup has no test. Grouped with blind #8; patched there.
  - `[low]` `[reject]` (intent #9) PerNodeTops, the five groups, the dim fade's owner and the run indexes diverge from the epic's older text. All are recorded in Design Notes; the run indexes are 4.15's `RouteGeometry` arrays, which 10.19 can use.
  - `[low]` `[defer]` (intent #10) The catalogue's hover wiring and the edges were not checked on screen (Marionette). The unattended run cannot hold `flutter run`; deferred like 10.2's and 10.3's checks.

## Design Notes

- **Superseded witnesses.** The 2026-10-14 note makes 4.15's router the geometry source; the older "same suite on a `PerNodeTops` fixture" cannot hold, since router B derives y from rows (= `UniformRows`). `PerNodeTops` stays a hand-fixture tool for 10.1's viewport tests; the edge layer serves every real source (Compact and Free are both uniform rows), recorded as Claude's proposal.
- **Groups instead of seven styles.** Dashes are geometry, so solid and dashed lines of one colour share a `Path`; the epic's seven styles collapse to five paint groups with no visual difference.
- **Dim fade owner.** The 160 ms fade animates `dim` in the owner that toggles the focus path (10.6); the painter only interpolates. The catalogue has no focus path until 10.6.
- **I1 settled.** The Epic 10 header (2026-09-30 note, epics.md:8988-8994) answers design question (a) with "no counts" and moves the elided marker to 10.19; no `elided_counts` call is needed.
- **I2 settled (Claude's proposal: the painter marks nothing).** Router B classifies a first-parent edge into another column as `fork` only when the child's column is free between the rows, else `gutter` (docs/graph-layout.md §14.2), so the D11 edge climbs a gutter instead of the stack's column. The route report's Compact gate (and a D11 hand case) proves it; a growing `rows` is not needed for the painter.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `flutter test test/features/graph test/widgetbook` (in `app`) -- expected: all pass.
- `flutter test test/design` (in `packages/zanshin_ui`) -- expected: all pass.
- `dart analyze --fatal-infos app packages/zanshin_ui` -- expected: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui` -- expected: exit 0.

**Manual checks (if no CLI):**
- Best-effort Marionette check of `graph/viewport/recording`; record the outcome or why it could not run.

**Verification notes (2026-10-30):**
- After implementation: `flutter test --reporter=failures-only test/features/graph test/widgetbook` (app) 521 passed; after the async-route follow-up 524; after the review patches 530 passed.
- `flutter test --reporter=failures-only test/design` (packages/zanshin_ui): 74 passed.
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues (each round).
- `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed (each round).
- Marionette check: not run — the unattended synchronous run cannot hold `flutter run -d macos -t widgetbook/main.dart`. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.4").
- No Rust, FFI, schema or jj verb changed: no cargo test, clippy, codegen or parity oracle applies. No full gate, per this run's gate rule.

## Auto Run Result

Status: done. Code commit `4ad948df4e444c0985e5e88ad251ea28c56987cf`, plus the follow-up commit that carries this spec, `deferred-work.md` and `sprint-status.yaml`.

**Items from the dispatch:**
- **I1** (the elided count N has no owner): **rejected — no longer applies.** The Epic 10 header's 2026-09-30 note (epics.md:8988-8994; sprint-status 10-4 entry) answers design question (a) with "no counts" and moves the elided marker to 10.19, so no `elided_counts` call or story is needed. deferred-work.md:687 carries a "Resolved in Story 10.4" note.
- **I2** (D11: a split run's stack node's parent edge unprotected below the card): **fixed (settled) in `4ad948df4e444c0985e5e88ad251ea28c56987cf`.** Claude's proposal: the painter marks nothing. Router B classifies a first-parent edge into another column as `fork` only when the child's column is free between the rows, else `gutter`, so the edge never climbs the stack's column; in Compact the route report's gate proves no line passes behind a card (except the router's reported overfull gutters), in Free a fully blocked gutter route is the router's reported fallback. Witness: "D11 (I2)" in `layout_invariants_test.dart`; docs/graph-layout.md §4.8 and §9 amended; deferred-work.md:899 carries a "Resolved in Story 10.4" note. The growing-`rows` alternative stays Ralph's, and 10.17 keeps its own part.

**Summary.** Story 10.4 with its 2026-09-30 and 2026-10-14 notes:
- `routeGraph` / `graphRouteClasses` / `graphRouteMetrics` feed 4.15's router B from `GraphLayout` (class stage once per layout, geometry per card size; sync up to `routeSyncNodeLimit`, `Isolate.run` above). `GraphRouteCache` keeps the current geometry, drops superseded, disposed and failed routes (errors reported).
- `GraphEdgePainter` on the viewport's `paintEdges` hook: `graphRoundedPath` (r 10 clamped), Indirect edges dashed 3/5 from the parent end as geometry, the window's bridges cut 12 px in arc length (horizontal or vertical break; none between lines sharing a node), the @ lineage bitset (`--co` 2.25 px over a σ 2 `--co-glow`), the hover/focus/dim classification of graph-view.jsx (dim = the owner's fade progress), a bounds index in blocks of 64 (only edges meeting the window + 8 px are stroked), five paint groups with one `drawPath` each (lineage: two), `edgesIn`, `cutsIn`, `edgesAt`, `edgePath`.
- `RouteReport` / `checkRouteLines` / `checkRoutes` in 10.1's checker: Compact gate, Free counted, router-reported hits explained; every recording passes.
- `GraphTheme` gains `edge`, `edgeHover`, `lineage`, `lineageGlow`. The catalogue's viewports paint edges with the hovered card's edges hovered.

**Files:**
- `app/lib/src/features/graph/graph_edges.dart` (new): routing entry points, `GraphRouteCache`, `graphRoundedPath`, `GraphEdgeHighlight`/`Tone`/`Style`/`Cut`, `GraphEdgePainter`.
- `app/lib/src/features/graph/layout_invariants.dart`: the route report.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` and its test: the four edge roles.
- `app/widgetbook/folders/graph.dart`: the edge painter and route cache in `_GraphDemo`.
- `app/test/features/graph/graph_edges_test.dart` (new), `layout_invariants_test.dart`, `graph_harness.dart` (stable edge order, `indirect`), `app/test/widgetbook/catalogue_smoke_test.dart`.
- `docs/graph-layout.md`: D11 notes (§4.8, §9).

**Review.** 34 findings: 0 high, 3 medium, 29 low, 2 false.
- Patched, 7 entries (1 medium, 6 low): `paint`'s own geometry and cut wiring asserted at a scrolled viewport, plus a fractional `dim` (medium); the route cache's error path; the overfull-gutter explanation limited to lines that can reach a card; tests for the cache across layouts, dashes in a partial window and through a cut, the shared-exit branches of the report and the hit lookup; the D11 doc sentence names the overfull-gutter exception.
- Deferred, 1, mirrored to deferred-work.md: the Marionette check.
- Rejected, each with its reason in the Review Triage Log: the gutter-budget literal (zanshin_core untouchable), class copies across the isolate, corner measuring per paint, the unrounded hit lookup (as specified), the focus-length and NaN-dim guards, the single-geometry cache, test cost, the sync throw on contract-breaking input, a resize during the first async route, I2's stand-in witness, the I1 sprint-status check (done), the W-change and Free-count witnesses, the oracle's edge set, the Design-Note divergences, and 2 false (bookkeeping at finalize, NaN dim).
- Follow-up review recommended: **false**. First pass; no high and only one medium entry was patched.

**Residual risks:**
- Nobody has looked at the edges on screen yet (the deferred Marionette check); stroke, glow and dash rendering are proven by `paints` matchers and geometry tests only.
- Paint frame time on 50k–100k layouts with many dashed or cut edges in view is unmeasured.
- The route report counts router B's own entry-port overflow (more than 9 non-first parents on one side at W 240) as a collinear overlap; no recording has it.
