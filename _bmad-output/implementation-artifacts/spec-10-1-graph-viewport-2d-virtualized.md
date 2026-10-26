---
title: 'Story 10.1 — Graph viewport: two-axis virtualized canvas over positioned nodes, extents from data, pan-by-drag'
type: 'feature'
created: '2026-10-26'
status: 'done'
baseline_revision: '8d12f999bba530e6e1fb6c13d14efcbacabd4ccd'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The Graph folder was not checked visually (Marionette) in the running catalogue.
    evidence: |-
      The unattended loop cannot hold a `flutter run -d macos -t widgetbook/main.dart` session; widget and smoke tests only prove every Graph use case builds and opens.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
  - summary: >-
      KeepAlive(keepAlive: pinned) is inert; pinned cards are laid out on every pass instead of resting in the keep-alive bucket.
    evidence: |-
      Flutter's 2D element loses a kept-alive off-screen child when a reload moves its vicinity ("Expected to re-use an element"), so _layoutNode clears parentData.keepAlive after layout; pinning holds through the node key and witness (o) passes.
    location: >-
      app/lib/src/features/graph/graph_viewport_render.dart (_layoutNode)
    severity: low
---

<intent-contract>

## Intent

**Problem:** Epic 10 has no production graph viewport. The POC (`app/lib/src/features/graph_poc/`) assumes one card per row, finds rows by index arithmetic, keys cards by slot, rebuilds every card on a parent `setState`, has no anchoring and no recorded layouts. The Widgetbook catalogue also has no "Graph" folder. Every later Epic 10 story plugs into this viewport.

**Approach:** Build the viewport that `_bmad-output/planning-artifacts/epics.md:8348-8610` (Story 10.1, with its dated notes 2026-09-28, 09-30, 10-14 and 10-16, which supersede the older items) specifies. Its parts:
- the `GraphLayout` contract, `GraphMetrics`, `VerticalLayout` (`UniformRows` + `PerNodeTops`) and the custom 2D viewport, delegate, anchor/reveal, input and semantics, all under `app/lib/src/features/graph/`;
- `GraphTheme` in the token layer;
- recorded layouts produced by a dev-only recorder from tracked spike/engine inputs, plus an in-test synthetic generator for scale;
- the invariant checker;
- the Widgetbook "Graph" folder as the only demo host.

## Boundaries & Constraints

**Always:**
- The view never computes rows, lanes, columns, route shapes, buckets, elided data or a y. Everything comes from the layout source. A recording that fails a hard invariant is an engine/recording bug, never patched in the view.
- `GraphLayout` is read only through accessors, and consumers add accessors, never backing objects.
  - A node key is the source's `key` (falling back to `id`): the change id, or the commit id for hidden/divergent commits.
  - There are no synthetic keys.
- Modes are `free` (U = 16, default) and `compact` (U = 1); there is no `time`. Lane order is `compact` (default) or `greedy`.
- Pixel rules:
  - x = insets.left + pad + col·(W + gapX); offX is 0 (no gutter).
  - Plane width = 2·pad + colCount·(W + gapX) − gapX.
  - `UniformRows`: top(i) = pad + (rows − U − rowOf(i))·(H + gapY)/U, and height = 2·pad + bottomExtra + (rows/U)·(H + gapY) − gapY.
  - The live insets (an `EdgeInsets`) add margins around the plane on both axes.
  - W is clamped to 160–400 (default 240). H is 62 detailed / 40 compact. gapX 56, gapY 48, pad 56, radius 10, all from `ZsMetrics`.
- Use `scrollCacheExtent` (default `ScrollCacheExtent.pixels(250)`), never the deprecated `cacheExtent`. Override only `layoutChildSequence` (never `performLayout`), and apply both extents before building any child, re-applying them once when `applyContentDimensions` returns false.
- The delegate:
  - keys the outermost widget, a `KeyedSubtree`, with the node key;
  - wraps `KeepAlive(keepAlive: pinned, child: RepaintBoundary(child: card))` below it, with no `AutomaticKeepAlive`;
  - has a versioned `shouldRebuild`;
  - returns `null` outside the layout;
  - passes no per-build closures to cards.
- Paint:
  - own `LayerHandle<ClipRectLayer>` via `context.pushClipRect(…, oldLayer:)`, disposed in `dispose`;
  - hook order is background → edges → visible cards in z-order (base, @, selected, hovered/pinned) at a paint-time opacity per node → overlay;
  - the painted plane covers max(content, viewport).
- Hit testing walks the paint order in reverse, and `hitTestSelf` is true.
- `describeSemanticsClip` = the viewport inflated by the cache extent; `describeApproximatePaintClip` = `Offset.zero & size` unless `Clip.none`.
- Input:
  - `DiagonalDragBehavior.weightedEvent`;
  - a wheel event carrying both dx and dy scrolls both axes; single-axis events and the framework's Shift flip stay with the framework;
  - pan-by-drag is primary-mouse only, starts only off every card, moves both offsets 1:1 and never selects;
  - `ScrollBehavior.dragDevices` is unchanged;
  - cursor is the arrow everywhere, `grabbing` only while a pan is held;
  - no scrollbars.
- Anchor and reveal:
  - an anchor (node key + viewport offset on both axes) is re-applied via `correctBy` inside `layoutChildSequence` before the dimensions are applied, whenever layout, metrics or insets change;
  - a left-inset change shifts the horizontal offset by the same amount in the same frame;
  - a reveal request centres its key in the relayout it arrives with and is consumed once; if the key is absent, the anchor applies;
  - under `MediaQuery.disableAnimationsOf`, an animated reveal jumps.
- Production code lives in `app/lib/src/features/graph/`, tests in `app/test/features/graph/`. The app imports `zanshin_core` / `zanshin_ui` only through their barrels, and Material types only from `package:material_ui`.

**Never:**
- Real cards (10.3), edges (10.4), the background, day labels and canvas paint (10.2), the view model / `GraphInsets` / ports (10.5), selection, keyboard and click semantics (10.6), FLIP animation code (10.20), content paging (10.11), `GraphRef` and card content fields (10.3 / 10.11 define them).
- Any dependency on 4.10–4.12 runtime APIs.
- A single-RenderBox rewrite; reversed axes or RTL.
- Scrollbars.
- A `main*.dart` demo host.
- Touching `app/lib/src/features/graph_poc/`, `app/lib/main2.dart`, `main3.dart` or `main4.dart` (removing them is Story 11.10's).
- Committing the 10k–100k spike outputs.
- Golden tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Empty layout | `nodeCount == 0` | extents = 2·pad plane (+insets); no child built; paint hooks still run | no exception |
| Shrink while scrolled deep | 100k layout scrolled to the bottom, replaced by the design sample | offsets clamp into range; only valid vicinities are built | no exception |
| Overscroll (macOS) | bounce past both ends on both axes | children stay consistent; no out-of-range vicinity is built | no exception |
| Absent anchor key | reload where the anchor key no longer exists | offsets unchanged (clamped) | no exception |
| Absent reveal key | relayout carrying a reveal key not in the layout | falls back to the anchor | no exception |
| Invariant violation | hand-built layout: two nodes in one (row, col) cell (prototype `r` 13:59 / `k←r` 13:55), child below its parent, duplicate (child, parent), dangling edge | the checker reports the violated invariant | checker returns or throws a descriptive failure; never used to patch |
| Duplicate targets (deferred I3) | recordings from inputs whose topology had repeated targets | already merged upstream (one edge per (child, target), direct wins) → the "no duplicate (child, parent)" invariant passes | n/a |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:8348-8610` -- Story 10.1, the authoritative scope (items 1–14, witnesses a–p).
  - Dated notes win over item text:
    - item 7 (scrollbars), witness (h) and the grab cursor are gone;
    - item 1 → Graph folder;
    - item 12 registration → app theme;
    - the 2026-10-16 note adds live-inset witnesses.
  - Read it fully. The Epic 10 header house rules are summarized in `epic-10-context.md`.
- `app/lib/src/features/graph_poc/commit_graph_view.dart:14-254` -- POC to mirror, not edit.
  - Viewport/render boilerplate (`:75-115`).
  - `_cacheFor(ScrollCacheExtent)` via public `.style`/`.value` (`:149-150`).
  - `_applyExtent` double-apply (`:158-163`).
  - `layoutChildSequence` structure (`:166-192`).
  - Own clip + paint (`:195-216`).
- `app/test/features/graph_poc/commit_graph_view_test.dart:16-38,134-153` -- harness:
  - 800×600 at dpr 1 via `tester.view`, plus `addTearDown(tester.view.reset)`;
  - `skipOffstage: false` counting;
  - `paints..everything` call-order trick.
- Flutter SDK `/Users/ralph.bergmann/development/sdks/flutter/packages/flutter/lib/src/widgets/two_dimensional_viewport.dart` -- 3.50 pre:
  - `TwoDimensionalViewport` (`:142-161`) and `RenderTwoDimensionalViewport` (`:537-556`) take `scrollCacheExtent`;
  - the element reuses children by widget key across vicinities, which is why the key goes on the outermost widget;
  - keep-alive bucket.
  - `rendering/viewport.dart:42-71` -- `ScrollCacheExtent`.
  - `widgets/two_dimensional_scroll_view.dart:57-80` -- `TwoDimensionalScrollView` params.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart:204-218` -- `cardW` 240, `cardHCompact` 40, `cardHDetailed` 62, `graphGapX` 56, `graphGapY` 48, `graphPad` 56, `radiusCard` 10. `ZsMetrics.of(context)` is at `:148`.
- `packages/zanshin_ui/lib/src/design/zs_colors.dart:178,293,329-349,477,513-533,660` -- `canvas` (`ZsCanvasGradient`) / `canvasBase` per night/paper, `resolve`, and the `of` with night fallback (the pattern for `GraphTheme.of`).
- `packages/zanshin_ui/lib/src/design/zs_app_theme.dart:26,63` -- `ZsAppTheme.build`, whose `extensions:` list is where `GraphTheme` registers (once).
  - `ZsRoot` (`zs_root.dart:40-69`) uses it, so the catalogue's `appBuilder` and `AppearanceAddon` get it.
  - The barrel is `packages/zanshin_ui/lib/zanshin_ui.dart`.
- `app/widgetbook/catalogue.dart:23-37,117-189` -- `catalogueDirectories`:
  - the stale "no Graph folder yet" comment is at `:23-24`;
  - `catalogueUseCasePaths`, `catalogueAddons()` (`TimeDilationAddon` already present at `:146`), `catalogueAppBuilder` → `ZsRoot`.
- `app/widgetbook/folders/projects.dart:19-84` -- folder/component/use-case + knobs pattern (`context.knobs.boolean`, `.double.slider`, `.int.slider`, `.object.dropdown`).
- `app/widgetbook/catalogue_extension.dart:58-86` -- `zanshinCatalogue.open`. Paths are lower-case names joined by `/`, so `graph/...` resolves automatically.
- `app/test/widgetbook/catalogue_smoke_test.dart:19-32` -- pumps every leaf use case per theme. It hard-codes the folder list `['Controls','Materials','Shell','Projects','Windows','Icons']`, so 'Graph' must be added. Helpers are in `app/test/helpers/catalogue.dart`.
- `packages/zanshin_core/benchmark/graph_layout_cli.dart:8` -- the product engine CLI: `layout --mode compact|free --order greedy|compact <in> <out>`.
  - Verified: `dart run packages/zanshin_core/benchmark/graph_layout_cli.dart layout --mode free --order compact packages/zanshin_core/test/graph_layout/goldens/stacks/design-default.json <out>` is byte-identical to the untracked `spikes/graph-layout-ab/outputs/core/design-e243dd2-default.free.compact.json`.
- `packages/zanshin_core/test/graph_layout/goldens/stacks/design-{default,all}.json` -- tracked e243dd2 sample inputs (35 / ~52 nodes).
  - They carry view facts per node: `key`, `parent_count`, `working_copy` ("this"|"other"|null), `has_ref`, `immutable`, `ts_ms`, and parents with `idx`/`kind` (missing ⇒ idx null).
- `packages/zanshin_core/test/graph_layout/goldens/fixtures/medium-narrow.input.json` -- tracked (83 KB) dump from the switched dumper (`graph_topology`, deduped). Its revset yields indirect + Missing edges.
- `docs/graph-layout.md:77-244` -- §2 input and §3 output formats.
  - Output keys: `mode, order, unit, rows, lanes, nodes[{row,lane,col}], edges[{from(parent),to(child),kind,route: straight|merge|branch_off,blocked}], buckets[{kind:"day",value,start,end}]`.
  - `:148-158` is the dated §2 amendment: one edge per (child, target), direct wins (settles I3).
- `spikes/graph-layout-ab/rust-inputs/src/jj_dump.rs:52-53,78` / `input.rs:145-163` -- the dumper already calls `graph_topology` and dedupes (I3/I4 done by Story 4.11, see `spec-4-11-dart-layout-engine-worker-isolate.md:101,106,382,389`).
- `spikes/graph-layout-ab/tools/` -- `.mjs` tools. `inputs/` and `outputs/` are gitignored, so nothing large is committed.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` (+ export in the barrel, + registration in `ZsAppTheme.build`'s `extensions`) -- add the `GraphTheme` `ThemeExtension` with `night` / `paper` / `resolve(ZsAppearance)`, holding the canvas roles derived from `ZsColors`:
  - `canvas` (`ZsCanvasGradient`) and `canvasBase`;
  - `copyWith`, `lerp`;
  - `of(context)` falling back to `night`, with no force-unwrap.
  
  Add a unit test in `packages/zanshin_ui/test/design/` (fallback, night/paper values equal `ZsColors`', registered by `ZsAppTheme.build`). -- item 12; registers once.
- `app/lib/src/features/graph/graph_layout.dart` -- the abstract `GraphLayout`:
  - `mode` (`GraphMode.free|compact`), `unit`, `rows`, `colCount`, `nodeCount`;
  - `keyOf`, `indexOfKey`, `colOf`, `rowOf`, `timestampOf` (nullable), `parentCountOf`, `elidedOf` (has a Missing parent);
  - `edgeCount`, `childOf`, `parentOf`, `kindOf` (`GraphEdgeKind.direct|indirect`), `shapeOf` (`GraphEdgeShape.straight|merge|branchOff`), CSR `parentEdges(i)`/`childEdges(i)` ranges;
  - `bucketCount` + bucket accessors (kind, value, firstRow, lastRow);
  - `workingCopyIndex?`, `shownCount`, `totalCount?`, `operationId?`, and a `version`/identity used by `shouldRebuild`.
  
  Also add `GraphViewOptions` (immutable: `layout` = `GraphMode.free`, `laneOrder` = compact | greedy, `detailedCards` = true, `cardWidth` = 240). -- item 2.
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- an array-backed `GraphLayout` with:
  - a constructor from typed arrays (used by the synthetic generator);
  - `RecordedGraphLayout.fromSpec(inputJson, outputJson)`, which joins a §2 input (view facts: key ← `key` ?? `id`, `parent_count` ?? parents.length, `working_copy == "this"`, elided ← any missing parent, `ts_ms`) with a §3 output (rows/unit/lanes/col/edges/route/buckets).
  
  Edges in source order. -- item 13.
- `app/lib/src/features/graph/graph_metrics.dart` -- `GraphMetrics` (W clamped 160–400, H from `detailedCards`, gaps/pad/radius defaults from `ZsMetrics.standard`), `x(col)`, `planeWidth(colCount)`, equality. -- item 3.
- `app/lib/src/features/graph/vertical_layout.dart` -- `VerticalLayout` (`top(i)`, `contentHeight`, `bottomExtra`, `visibleNodes(Rect window, double overhang)`), implemented by `UniformRows` and `PerNodeTops`.
  - The index is a sorted `Float64List` of tops + an `Int32List` of node indices, with binary search and then an x filter.
  - Rebuild it O(n) when the order is unchanged.
  
  -- item 4.
- `app/lib/src/features/graph/layout_invariants.dart` -- `checkLayoutInvariants(GraphLayout, …)` with the hard invariants: unique keys, no dangling edge, no duplicate (child, parent), rowOf(child) ≥ rowOf(parent) + U, no overlapping cards in a column (no shared (row, col) cell in row modes; for `PerNodeTops`, no vertical overlap). It returns violations. -- item 14.
- `app/lib/src/features/graph/graph_viewport.dart` (split into `graph_viewport_render.dart` / `graph_child_delegate.dart` if large) -- `GraphViewport` (`TwoDimensionalScrollView`) + the viewport widget + `RenderGraphViewport` + the custom `TwoDimensionalChildDelegate`, per the Always rules.
  - Inputs:
    - `layout`, `metrics`, optional `verticalLayout` (default `UniformRows`);
    - both `ScrollController`s, required and passed explicitly;
    - a stable `cardBuilder(BuildContext, int node)`;
    - `insets` (`EdgeInsets`), `pinnedKeys`;
    - z-order keys (`selectedKey`, `hoveredKey`; @ from `workingCopyIndex`);
    - `opacityOf(int)` paint-time dim;
    - paint hooks (background / edges / overlay, `(PaintingContext/Canvas, Offset origin, Rect visibleContentRect)`);
    - `anchorKey?` (default rule until 10.5: the visible node nearest the viewport centre);
    - a `GraphReveal?` request object (key, alignment centre|minimal, animate), consumed once by identity;
    - `scrollCacheExtent`.
  - A `GraphViewportController` exposes `reveal(key, {alignment, animate})`, `jumpTo` and `animateTo`.
  - Wheel-both-axes: in the render object's `handleEvent`, register with `GestureBinding.instance.pointerSignalResolver` only when dx and dy are both non-zero (the viewport is deeper than the inner `Scrollable`s, so it wins), then `pointerScroll` both positions.
  - Pan: a mouse-only, primary-button pan recognizer that refuses to start when the down position is on a card (use the render object's visible-node query).
  
  -- items 5–11.
- `spikes/graph-layout-ab/tools/record-graph.mjs` -- a dev-only recorder that, from repo-tracked inputs only:
  - runs the product engine CLI for e243dd2 `design-{default,all}` (`goldens/stacks/design-*.json`, without `--stacks`) in {free, compact} × {compact, greedy};
  - runs it for `goldens/fixtures/medium-narrow.input.json` in {free, compact} × compact;
  - writes `app/widgetbook/graph/graph_recordings.g.dart` (a header naming the tool, `// ignore_for_file:` as needed, one const raw-string pair per recording, plus a name list);
  - then runs `dart format` on it.
  
  Document its command line in a header comment. -- item 13, I4.
- `app/widgetbook/graph/graph_recordings.g.dart` -- generated, committed.
- `app/widgetbook/graph/synthetic_layout.dart` -- a deterministic generator of `RecordedGraphLayout`s for scale:
  - n ∈ {10k, 50k, 100k}, ≥ 100 lanes;
  - merges, indirect edges, Missing stubs;
  - U = 1 and a U = 16 free variant;
  - a seeded RNG.
  
  It produces layout data directly (test/demo data, not a view engine) and must pass the invariant checker. -- item 13(b), Design Notes.
- `app/widgetbook/graph/placeholder_card.dart` + `app/widgetbook/folders/graph.dart` -- the "Graph" folder:
  - a component "Viewport", with use cases for the recordings (knobs: recording dropdown, every `GraphViewOptions` field — layout, lane order, detailed cards, card width 160–400 — plus left/right inset sliders);
  - a use case "Scale" (synthetic 10k/50k/100k);
  - placeholder cards (token-coloured box with the key).
  
  Debug-assert the invariant checker on every fixture. -- items 1, 13; I1, I2.
- `app/widgetbook/catalogue.dart` -- add `graphFolder` to `catalogueDirectories` and drop the stale comment. `app/test/widgetbook/catalogue_smoke_test.dart` -- add 'Graph' to the folder list. -- I1.
- `app/test/features/graph/*_test.dart` -- witnesses (a)–(g), (i)–(p) and the 2026-10-16 ones (drop (h)); see the AC list. Plus unit tests for `GraphMetrics`, `UniformRows`, `PerNodeTops`, `RecordedGraphLayout.fromSpec` and the invariant checker.

**Acceptance Criteria:**
- Given the 100k synthetic fixture at 800×600, when pumped, then the mounted cards are exactly those whose inflated rect intersects viewport ± cache extent. Both `maxScrollExtent`s equal the `GraphMetrics`/`UniformRows` formulas before any card builds (at U = 1, the design's formulas).
- Given a jump to the middle, then only nearby nodes mount, including every card of a multi-card row. Taps hit the right card before and after, including two cards in one row.
- Given a mostly-vertical trackpad pan, then x doesn't move. Given a diagonal drag or a wheel event with dx+dy, then both axes move. Given Shift+mouse-wheel, then it scrolls horizontally (macOS variant).
- Given a primary mouse drag on empty canvas, then both offsets move by the delta and nothing is selected. Given one starting on a card, then nothing pans.
- Given a ≥ 100-lane fixture, then at h = 0 far-right columns aren't built, and at max h column 0 isn't built.
- Given the `paints` matcher, then the order is clipRect → background hook → first edge `drawPath` → first card `drawParagraph` → overlay, and among cards base → @ → selected → hovered.
- Given a parent `setState`, then 0 cards build. A scroll bringing no new node builds 0; one entering node builds 1.
- Given anchoring:
  - a reload adding a head keeps the anchor's viewport offset;
  - a reload moving the anchor's column keeps it horizontally;
  - only entering nodes init State;
  - a reveal key centres its node (absent → anchor);
  - the next relayout (card-width change) keeps the anchor without re-centring.
- Given random windows, then the visible query equals a brute-force scan for `UniformRows` over a compact recording and over a `free` (U = 16) recording, and for `PerNodeTops`.
- Given a W or H change, then rows and columns are unchanged, extents are exact and the anchor holds.
- Given semantics, then a cache-extent card `isHidden` and a visible one isn't.
- Given a pinned key, then it survives scroll-out and a moving reload. Pinning a mounted card keeps its State.
- Given left/right insets driven per frame, then no card moves on screen while the corrected offset stays in range (both directions mid-range; growing at both ends). A flyout overlay changes no extent and no offset.
- Given `disableAnimations`, then an animated reveal lands in one frame.
- Given every recording and synthetic fixture, then the checker passes. It rejects the four hand-built violations.
- Given the catalogue, then the Graph folder exists, `graph/...` paths open via `zanshinCatalogue.open`, and the smoke test pumps every Graph use case without exception.

## Spec Change Log

## Review Triage Log

### 2026-10-26 — Review pass
- verdicts: 35 findings — high 0, medium 4, low 29, false 2, maybe-false 0
- findings:
  - `[medium]` `[patch]` (verification-gap) Reveal and pan-start gating are tested only with zero insets. Added a centre and a minimal reveal with left/right/top insets, plus inset variants of the pan / no-pan-on-card tests.
  - `[low]` `[patch]` (verification-gap) `GraphViewportController.animateTo` has no test. Added an animate-and-settle case.
  - `[medium]` `[patch]` (verification-gap) No viewport test passes an explicit `verticalLayout` (`PerNodeTops`). Added a mount/extent oracle test and a rebuild that swaps the tops.
  - `[low]` `[patch]` (verification-gap) `_applyAnchor`'s no-anchor branch (an inset change over a card-free window) is untested. Added a test.
  - `[low]` `[patch]` (verification-gap) The medium-narrow greedy fallback in `recordedLayout` is untested. Fixed at the root, grouped with blind #12: medium-narrow is now recorded in all four combinations and the fallback branch is deleted.
  - `[false]` `[reject]` (intent-alignment) There is no `## Auto Run Result` with I1–I4 outcomes. Finalize writes it after review; the commit hashes do not exist before the commit.
  - `[low]` `[reject]` (intent-alignment) I3 passes vacuously, because no committed recording input had a dropped duplicate. The rule lives in the input builders (`dedupe_parents`, `input_builder.dart:44-75`), which 4.11's tests cover. 10.1's part is that its recordings come from those inputs and pass the duplicate-edge gate, and they do.
  - `[medium]` `[patch]` (intent-alignment) Item 13 diverges in two ways:
    - (a) The CLI-faithful 13-commit design variant is missing. Patched: the recorder now derives it from the tracked 57f259c `design/design-default.json` (`wq` dropped, `vr`'s parent Missing) as `design-cli-default`.
    - (b) Scale witnesses run on a synthetic generator, not on spike recordings. Rejected, see Design Notes: the spike's 10k–100k outputs are gitignored, building them needs the Rust spike, and the non-goals forbid depending on 4.11's engine at runtime. The synthetic layouts pass the same hard invariants.
  - `[low]` `[patch]` (intent-alignment) The catalogue's non-default knobs are not exercised, and the medium-narrow greedy substitution is silent. Grouped with blind #12.
  - `[medium]` `[patch]` (blind #1) `GraphReveal` has a const constructor, but reveals are consumed by identity, so a second identical const reveal is skipped. Dropped `const` and added a reveal-twice test.
  - `[low]` `[reject]` (blind #2) Edge order is only asserted in `RecordedGraphLayout`. The inputs are generated by our own recorder or generator, and debug tests would trip the assert. Sorting or throwing adds a guard for input that cannot occur.
  - `[low]` `[reject]` (blind #3) The checker lacks range checks (col/row bounds, the @ index, buckets, parentCount). The story fixes the hard-invariant list (item 14), and the engine guarantees these. Adding them is new guard code for data that never violates them.
  - `[low]` `[patch]` (blind #4) `isOnCard` counts cards at opacity 0. Applied the `paintOrder` filter and added a test.
  - `[low]` `[reject]` (blind #5) The pan calls `jumpTo` per axis, which bursts scroll notifications. There is no consumer yet (the minimap is 10.16), and a drag `ScrollActivity` per axis is added complexity.
  - `[low]` `[reject]` (blind #6) Controller `jumpTo`/`animateTo` don't clamp and ignore reduce motion. This is the same contract as `ScrollController.jumpTo`/`animateTo`. Reduce motion is specified for `reveal(animate:)` only, and that path jumps.
  - `[low]` `[reject]` (blind #7) An explicit `verticalLayout` duplicates layout/metrics state, which only an assert checks. A mismatch is a caller bug that debug runs catch. The missing viewport test is covered by verification-gap #3.
  - `[low]` `[reject]` (blind #8) `paintOrder` allocates per paint/hit test. This is a few small lists over the mounted cards (dozens), so the cost is negligible, and caching adds invalidation state.
  - `[low]` `[reject]` (blind #9) The recorder leaks its temp dir on failure, and `dart` missing gives "exit null". It is a dev-only tool and fails rarely. The message still names the failing recording.
  - `[low]` `[reject]` (blind #10) No drift check ties `graph_recordings.g.dart` to the engine. The recordings are snapshots by design (fake data until 10.12), and the invariant gate covers their validity. Freshness against the engine is not a 10.1 requirement.
  - `[false]` `[reject]` (blind #11) The generated file is missing from the diff, and it has no ignore_for_file. It was excluded from the review diff for size only. It is committed, analyze-clean (`dart analyze --fatal-infos` reports no issues) and format-clean, so it needs no ignore.
  - `[low]` `[patch]` (blind #12) Two catalogue knobs are inert: Scale's lane order, and medium-narrow greedy. medium-narrow is now recorded in all four combinations and the fallback is deleted. The Scale use case drops the lane-order knob.
  - `[low]` `[reject]` (blind #13) Synthetic free layouts have no day buckets. No 10.1 consumer uses them; 10.2 owns day guides and extends the generator when it needs them.
  - `[low]` `[patch]` (blind #14) The local `free` shadows the mode parameter in `syntheticLayout`. Renamed it to `freeLanes`.
  - `[low]` `[reject]` (blind #15) `fromSpec` throws mixed error types. Its input comes only from our generated recordings, so a uniform `FormatException` adds wrapping for input that cannot occur.
  - `[low]` `[reject]` (blind #16) Test gaps: repaint-only z-order changes, a disappearing pinned key, and semantics dispose without `addTearDown`. The z-order setters only `markNeedsPaint`, a disappearing pinned key is skipped (`node != null`), and the handle leaks only on a failing test.
  - `[low]` `[reject]` (edge #1) `unit <= 0` divides by zero. The engine emits U ∈ {1, 16}, so this cannot occur on recorded or synthetic data.
  - `[low]` `[reject]` (edge #2) An out-of-range col/row in `fromSpec` is unguarded. Same reason as blind #3.
  - `[low]` `[reject]` (edge #3) Unsorted edges in release silently break the CSR. Same reason as blind #2.
  - `[low]` `[reject]` (edge #4) `byName` and the casts throw ArgumentError/TypeError. Same reason as blind #15.
  - `[low]` `[reject]` (edge #5) Controller `jumpTo` can overscroll. Same reason as blind #6, and identical to `ScrollController.jumpTo`.
  - `[low]` `[reject]` (edge #6) `animateTo` with `Duration.zero` asserts, and it glides under reduce motion. This is the same contract as `ScrollPosition.animateTo`. Reduce motion applies to reveal only.
  - `[low]` `[patch]` (edge #7) An opacity-0 card blocks the pan. Same fix as blind #4.
  - `[low]` `[reject]` (edge #8) A press on a card's exact left or top edge pixel both taps and pans. This is a single-pixel boundary race, so users will practically never meet it.
  - `[low]` `[reject]` (edge #9) Opacity-0 cards stay in semantics. The dim predicate's semantics belong to 10.6, which defines dimming, and nothing dims in 10.1.
  - `[low]` `[reject]` (edge #10) A geometry change during an overscroll bounce snaps it into range. This is rare (a reload mid-bounce), and the cards stay anchored. Keeping the overscroll adds a pre-correction range branch.

## Design Notes

- **Scale data deviation (item 13(b)).**
  - The spike's 10k–100k outputs are gitignored and 1–12 MB, so committed tests can't read them.
  - Tests and the catalogue use `synthetic_layout.dart`, which emits a valid layout directly and is gated by the checker. That is fake data, not view-side layout of a topology.
  - The real-data recordings committed are produced by the product engine CLI from tracked inputs, so the recorder is reproducible on a clean checkout. Each has 4 combos (review pass 2026-10-26: medium-narrow gained greedy, and the CLI variant was added):
    - the e243dd2 sample, both revsets;
    - medium-narrow, the switched dumper's output, with indirect and Missing edges;
    - `design-cli-default`, the CLI-faithful 13-commit variant derived from the 57f259c sample.
- **Insets at the scroll ends.** The no-move rule holds whenever the corrected offset is inside [0, max]. Where a shrinking margin at its own end would push the offset out of range, physics clamps it, as the design's `scrollLeft` does (GV:1065-1077). The witness covers growing at both ends and both directions mid-range.
- **`GraphTheme` lives in `zanshin_ui`** next to `ZsColors`/`ZsElevation`, because the "app theme" it registers through is `ZsAppTheme.build`, and `ZsRoot` (the catalogue `appBuilder`) uses it.
- **`GraphRef`/content** are left to 10.3/10.11, which define their fields (item 2: "10.3 defines the fields of both"). This story adds only the view-fact accessors with a meaning today (`parentCountOf`, `elidedOf`, `workingCopyIndex`).
- **Deferred items:**
  - I3 and I4 were done upstream by Story 4.11 (SPEC §2 amended at `docs/graph-layout.md:148-158`; the dumper uses `graph_topology` and `dedupe_parents`). 10.1's part is that its recordings come from those inputs and pass the duplicate-edge gate.
  - I2: the demo host is the Graph folder (no `main*.dart`); retiring `main2/3/4.dart` + `graph_poc/` is 11.10's.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `(builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/app && flutter test test/features/graph test/widgetbook)` (a subshell with `builtin cd` and an absolute path, never a bare `cd`) -- expected: all pass.
- `(builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/packages/zanshin_ui && flutter test)` -- expected: all pass.
- `dart analyze --fatal-infos app packages/zanshin_ui` -- expected: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui` -- expected: exit 0.
- `node spikes/graph-layout-ab/tools/record-graph.mjs` re-run -- expected: `git diff --exit-code app/widgetbook/graph/graph_recordings.g.dart` clean (deterministic).

**Manual checks (if no CLI):**
- Best-effort Marionette check: run the catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`), open `graph/viewport/...` via `zanshinCatalogue.open`, screenshot, and confirm placeholder cards at several per row and pan/scroll. Record the outcome or the reason it couldn't run.

**Verification notes (2026-10-26, after the review patches):**
- `flutter test --reporter=failures-only test/features/graph test/widgetbook` (app): 378 passed.
- `flutter test` (packages/zanshin_ui): 415 passed.
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed.
- The recorder was re-run twice: 16 recordings, byte-identical (`cmp`).
- The Marionette check was not run. An unattended synchronous run cannot hold `flutter run`. This is deferred (frontmatter `deferred`, deferred-work.md "Surfaced in Story 10.1").
- No Rust or FFI changed, so no cargo, codegen or parity check applies. The full gate is left to the story loop's end.

## Auto Run Result

Status: done. Commit `09c2f4e27e7d8670b5b8a69142c5765681354dad` (code), plus the follow-up commit carrying this spec, `epic-10-context.md`, deferred-work.md and sprint-status.yaml.

**Summary.** This adds the production graph viewport (Story 10.1 items 2–6 and 8–14, with the 2026-10-14 and 2026-10-16 notes; item 7, the scrollbars, is superseded):
- the `GraphLayout` contract and `GraphViewOptions`;
- `GraphMetrics`, and `VerticalLayout` (`UniformRows`, `PerNodeTops`, a binary-search visible query);
- `RenderGraphViewport`, which overrides `layoutChildSequence` only. Extents come from the data before any card is built. It owns its clip and paint order (background → edges → z-ordered cards with paint-time opacity → overlay), and hit testing walks that order in reverse. It also provides the semantics clips, weighted diagonal drag, wheel scrolling on both axes, primary-mouse canvas pan with the `grabbing` cursor, anchors via `correctBy` (including live insets), reveal requests consumed once, and `GraphViewportController`;
- the keyed child delegate;
- the layout invariant checker;
- `GraphTheme` in zanshin_ui, registered once in `ZsAppTheme.build`;
- the recorded layouts and the scale generator;
- the Widgetbook "Graph" folder as the only demo host.

**Files:**
- `app/lib/src/features/graph/graph_layout.dart`: the contract, enums and `GraphViewOptions`.
- `app/lib/src/features/graph/recorded_graph_layout.dart`: the array-backed layout and `fromSpec`.
- `app/lib/src/features/graph/graph_metrics.dart`: pixels in x.
- `app/lib/src/features/graph/vertical_layout.dart`: pixels in y and the visible query.
- `app/lib/src/features/graph/layout_invariants.dart`: the hard invariants.
- `app/lib/src/features/graph/graph_child_delegate.dart`: the keyed delegate with `KeepAlive` and `RepaintBoundary`.
- `app/lib/src/features/graph/graph_viewport.dart` and `graph_viewport_render.dart`: the widget, the render viewport, the reveal and the controller.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` (with its barrel export, its `ZsAppTheme` registration and `test/design/graph_theme_test.dart`): the canvas roles.
- `spikes/graph-layout-ab/tools/record-graph.mjs`: the dev-only recorder (product engine CLI, tracked inputs only).
- `app/widgetbook/graph/graph_recordings.g.dart`: 16 generated recordings.
- `app/widgetbook/graph/synthetic_layout.dart`: seeded 10k/50k/100k layouts with 120 lanes.
- `app/widgetbook/graph/placeholder_card.dart`, `app/widgetbook/folders/graph.dart`: the Graph folder.
- `app/widgetbook/catalogue.dart`: the folder is registered and the stale comment removed.
- `app/test/widgetbook/catalogue_smoke_test.dart`, `catalogue_extension_test.dart`: 'Graph' is added, and `graph/viewport/*` opens.
- `app/test/features/graph/*`: the harness, unit tests and witnesses (a)–(g), (i)–(p), plus the live-inset, flyout and reveal-motion witnesses.

**Review.** 35 findings: 0 high, 4 medium, 29 low, 2 false.
- 14 rows were patched, in 10 entries (grouped):
  - `GraphReveal` is no longer `const`, so a reveal is consumed by identity.
  - `isOnCard` skips opacity-0 cards.
  - The local `free` is renamed `freeLanes`.
  - medium-narrow is recorded in all 4 combinations, and the silent fallback is deleted.
  - The Scale use case lost its inert lane-order knob.
  - The CLI-faithful `design-cli-default` recording is added (item 13(a)).
  - New tests: reveal and pan with insets, `animateTo`, an explicit `PerNodeTops` in the viewport, the no-anchor inset shift, reveal twice, the CLI variant's shape.
- The other 21 were rejected, each with its reason in the Review Triage Log. Among them:
  - recorder freshness against the engine;
  - range guards in the checker and `fromSpec`;
  - controller clamping, which follows the `ScrollController` contract;
  - per-paint allocations;
  - the synthetic generator's missing day buckets (10.2's concern);
  - overscroll snapping on a geometry change.
- Deferred, both mirrored to deferred-work.md:
  - the Marionette visual check;
  - the inert `KeepAlive` flag, a Flutter 2D keep-alive limitation worked around by laying out pinned cards on every pass.
- Patched by verdict: 4 medium entries (inset reveal/pan tests, `PerNodeTops` viewport test, the CLI variant, `GraphReveal` const) and 6 low.
- Follow-up review recommended: **true**. The specific risk: the review-pass changes to `record-graph.mjs` (the CLI variant's re-indexing derivation) and to the reveal path in `graph_viewport_render.dart` were made after the reviewers read the diff and have not been re-reviewed.

**Deferred-work items:**
- **I1, fixed** (`09c2f4e27e7d8670b5b8a69142c5765681354dad`). The "Graph" folder is in `catalogueDirectories`. The smoke test expects it and pumps its use cases per theme and flags, and `catalogue_extension_test` opens `graph/viewport/*`. 10.1 landed after 11.11, so no new entrypoint was needed.
- **I2, fixed** (`09c2f4e27e7d8670b5b8a69142c5765681354dad`), as 10.1's part. The demo host is the Widgetbook Graph folder, and there is no `main*.dart` host. Removing `main2/3/4.dart` and `features/graph_poc/` remains Story 11.10's (item 4), as the item says.
- **I3, rejected: no longer applies** (done upstream by Story 4.11).
  - `docs/graph-layout.md:148-158` amends SPEC §2: one edge per (child, target) at the first position, direct wins.
  - The dumper and builders apply it (`rust-inputs/src/input.rs:145-163` `dedupe_parents`, `packages/zanshin_core/lib/src/graph_layout/input_builder.dart:44-75`).
  - 10.1's part is done in 09c2f4e2: every recording is built from those inputs, and the checker's no-duplicate-(child, parent) invariant passes on all of them.
  - The `tools/fuzz.mjs` follow-up belongs to the builder's tests, not 10.1.
- **I4, rejected: no longer applies** (done upstream by Story 4.11 item 10).
  - `jj_dump.rs:52-53` calls `Repo::graph_topology` and uses `commit_contents` for the sidecar, and `assign_priorities` follows the anchors rule.
  - 10.1's part is done in 09c2f4e2: its dump-based recording, medium-narrow, is the switched dumper's tracked output (`goldens/fixtures/medium-narrow.input.json`, re-dumped in Story 4.11), laid out by the product engine.

**Residual risks:**
- There is no visual check yet; the visuals still need Ralph's review in the catalogue.
- The scale fixtures are synthetic, not spike recordings (Design Notes).
- A reveal centres inside the insets.
- A geometry change during an overscroll bounce ends the bounce.
