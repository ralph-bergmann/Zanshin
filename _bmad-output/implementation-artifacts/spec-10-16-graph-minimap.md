---
title: 'Story 10.16: Minimap — the whole graph in dots with day labels, the current-day pill and the viewport band, click-and-drag navigation'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: '697d0a726491ca9f3c28ba2f217d04c6b2cc34d8'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The graph has no scrollbars, so on a big repo nothing shows where the viewport is or lets the user jump. The shell already reserves a 134 px minimap slot (`FloatingShell.minimap`, `_MinimapMotion`, the 158 px right inset), but nothing fills it, and View › Show Minimap is a grey menu item. Three ledger items name this story: I1 (Compact's day labels), I2 (the minimap's glass fades only through `ZsFade`) and I3 (which day a Compact label reads).

**Approach:** Build the design's minimap (graph-view.jsx:440-541, DS ui_kits/desktop/kit.css:155-172; epics.md Story 10.16 notes 2026-10-14 and 2026-10-16) as a `GraphMinimap` widget in the shell's slot.
- The dots and dotted edges are rasterised once per layout by a pure-Dart function (no `dart:ui`) run through `Isolate.run` (option A). The raster comes back as an RGBA buffer, is decoded to `ui.Image`s once, and is painted inside its own `RepaintBoundary`.
- A separate overlay painter, repainting from the scroll controllers, draws the band, the @ and selection dots, the labels and the pills.
- The canvas publishes its geometry and scroll controllers through a small notifier on `GraphViewModel`.
- An app-global `showMinimap` preference (default on) drives the slot and the menu item.

## Boundaries & Constraints

**Always:**
- The view computes no layout. It maps the layout's columns and rows to strip pixels only:
  - x is the plane centre `metrics.x(col) + cardWidth / 2`;
  - y is `rows.top(node) + cardHeight / 2`, with the canvas's own `VerticalLayout` (`UniformRows(layout, metrics, bottomExtra: graphGapsBottomExtraOf(layout))`, `graph_canvas.dart:1118-1125`);
  - edges use `RouteGeometry`'s polylines (`pointStarts`/`points`, from the parent's top edge to the child's bottom edge). Indirect edges (`GraphEdgeKind.indirect`) are dotted sparser (every 6 px instead of 3).
- Strip geometry, all CSS px. These are the design's constants, kept as named constants in the minimap file:
  - the strip is the card inset 12 top/bottom and 8 left/right, so it is 118 wide and `cardHeight − 24` tall;
  - `SPLIT = 58`; the graph's right edge `gr = 114`; at most 48 px of graph width (`GL = 66`); `KX = 0.04`;
  - `k = stripH / (contentHeight + insets.top + insets.bottom)`, `my(y) = (y + insets.top) · k`;
  - `kx = x1 > x0 ? min((gr − GL) / (x1 − x0), KX) : 0`, `mx(x) = gr − (x1 − x) · kx`, where x0 and x1 are the min and max node centre x.
- Raster layers, in one isolate call returning one `Uint8List` with both layers, unpremultiplied RGBA at the strip's device size (CSS size × `MediaQuery.devicePixelRatioOf`):
  - the **out** layer: nodes and edges in `--text-faint`, painted at 60 % (a `Paint` alpha, not an `Opacity` widget);
  - the **in** layer: nodes in `--text`, edges in `--text-muted`, painted at full strength clipped to the band (x from −8 to strip width + 16);
  - a node is an anti-aliased disc of r 2, a collapsed stack (`isStackNode`) a ring of r 2.6 with stroke 1.2;
  - an edge is round dots of diameter 1.5 every 3 px (indirect: every 6 px) along its polyline;
  - coverage per pixel is the max over its stamps; a node composites over an edge;
  - folded nodes (`isFolded`) are skipped.
- One raster in flight: a key change while it runs re-rasters once after it, with the latest inputs, and superseded results are dropped. The key is the layout, the rows, the metrics, the route geometry, insets top and bottom, the strip device size and the colours.
- A theme switch, a strip resize, a card-size or card-width change and a new layout each re-raster. Scrolling, hover and a selection change never re-raster; they repaint only the overlay.
- The overlay (graph-view.jsx:494-537; kit.css:166-172), with `vTop = (offset + top) · k`, `vBot = (offset + viewportExtent − bottom) · k` and `cy = (vTop + vBot) / 2`:
  - the band: an `--fl-hover` rounded rect (r 4) at x `SPLIT + 2`, width `118 − SPLIT + 2`, height at least 4;
  - the selection dot (r 3.2, `--accent-line`) and the @ dot (r 3.2, `--co`) at their nodes. The selection maps through `layout.placeOfKey(model.selected)`; @ is `layout.workingCopyIndex`;
  - the hover line: dashed 2/2, `--text-dim`, 1 px, from `SPLIT` to 118;
  - the connector: an `--at-chrome` 1 px line from `SPLIT` to 118 at `cy`;
  - the day labels: mono `fsXs` (10.5) in `--text-dim`, right edge at `SPLIT − 4`, vertically centred;
  - the hover pill: border `--border-strong`, text `--text-muted`, weight 400, no shadow;
  - the current-day pill: border `--at-chrome`, fill `--fl-bg-solid`, mono 600 11.5 in `--text`, padding 3/9, fully rounded, shadow `0 4 14 −4 rgba(0,0,0,.5)`. Both pills have their right edge at `SPLIT` and are centred on their y.
- Labels and the day lookup (graph-view.jsx:445-459, :495-504):
  - **Free:** one label per `GraphDayAxis.of(layout, rows)` bucket at its `labelYs`, text `graphDayLabel(values[b])`. The pill's day is the first label with `y ≥ planeY − 1`, else the last.
  - **Compact:** per row (`rowOf`), take the newest `timestampOf` among its laid-out nodes, excluding the root and nodes without a timestamp. Its day is `graphLocalDay(ts, utcOffsetMinutes)`. A row gets a label at `rowTop + cardHeight / 2` only when its day is older than the last label's. The pill's day is the last label with `y ≤ planeY + 1`.
  - Labels are hidden when they are less than 18 px below the previously shown label, within 15 px of `cy`, or within 13 px of the hover y.
  - `now` comes from `model.now`.
- Interaction:
  - a primary press or drag jumps instantly and vertically only: `vertical.jumpTo(clamp(sy / k − (top + (extent − top − bottom) / 2), 0, maxScrollExtent))`;
  - the wheel and trackpad pan over the strip scroll both axes by the event's delta (`PointerScrollEvent.scrollDelta`, −`PointerPanZoomUpdateEvent.panDelta`);
  - every press, drag move and wheel reports to `ShellScope.maybeOf(context)?.reportUserScroll`: 40 per drag move, the delta's |dx| + |dy| for a wheel;
  - nothing is selected; the cursor is `SystemMouseCursors.basic`; the hover is cleared while dragging and on exit.
- Glass: `ZsGlass(fill: ZsGlassFill.strong, blur: ZsGlassBlur.strong, radius: metrics.radiusIsland)` (zs_glass.dart:47). It fades only through the shell's existing `_MinimapMotion`/`ZsFade`; no `Opacity` or `FadeTransition` sits above it (I2).
- VoiceOver: one container node labelled "Minimap" (new ARB key), excluded from semantics while `_MinimapMotion` is hidden.
- Preference: `GraphSettings.showMinimap` (`@Default(true)`), with `GraphPreferences.showMinimap` and `setShowMinimap`. View › Show Minimap toggles it and shows its check state (`nativeState`). While it is off, the slot is null, so the right inset is 12 (already in `ShellLayout`).
- Strings go through `app_en.arb` plus `flutter gen-l10n`. Theme colours come from `ZsColors.of(context)`.

**Never:**
- No bookmark blue, no @ lineage, no focus path, no go-to hits, no subject tooltip, no selection on click.
- No backend, FFI or `zanshin_core` change.
- No day bucketing in the view beyond `graphLocalDay` of a timestamp.
- No `Opacity` above the glass.
- No per-frame raster or decode.
- Don't redraw the raster on scroll.
- No golden tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Hand-made layout raster | 3 nodes (one a stack), 2 edges (one indirect), small strip | Disc and ring pixels at the mapped centres; edge dots every 3 vs 6 px; stack ring hollow at its centre | — |
| Same layout, UniformRows vs equivalent PerNodeTops | identical tops | byte-identical buffers | — |
| Free labels | 3 day buckets, fixed `now` | Today / Yesterday / MMMd at the buckets' `labelYs`; the pill names the band centre's day, and its day changes exactly where a bucket's label y passes `cy` | — |
| Compact labels | rows with mixed days; root; a node without a ts | a label only where the day is older than the previous label; root and the ts-less node give none | — |
| Click / drag | press at strip y | vertical offset = the formula; horizontal unchanged; `model.selected` unchanged; `reportUserScroll` called | clamped to `[0, max]` |
| Empty layout / no routes yet | 0 nodes or geometry null | empty raster (or nodes without edges), no crash; re-raster when the routes arrive | — |
| Preference off | `showMinimap = false` | no minimap widget; right inset 12; menu item unchecked | — |

</intent-contract>

## Code Map

- `app/lib/src/features/shell/floating_shell.dart:415-423, 601-658` -- the minimap slot and `_MinimapMotion` (fade through `ZsFade` plus an 18 px slide). Add `ExcludeSemantics(excluding: !visible)` there.
- `app/lib/src/features/shell/shell_layout.dart:64,106,121` -- the inset logic (158 vs 12). Already done; read-only.
- `app/lib/src/features/home/project_graph_host.dart:27-47 (ProjectGraphSlots), :248-275` -- add a `minimap` slot: `graph.preferences.showMinimap ? GraphView.minimap(model) : null`.
- `app/lib/src/features/home/home_page.dart:101` -- `FloatingShell(... minimap: graph.minimap)`.
- `app/lib/src/features/graph/graph_view.dart:91 (GraphView.atPill pattern), :306-345 (insets, onUserScroll), :333 (GraphCanvas construction)` -- add the static `GraphView.minimap(model)` and pass `model.minimapSource` to the canvas.
- `app/lib/src/features/graph/graph_view_model.dart:1145 dispose` -- own a `GraphMinimapSource` (dispose it there).
- `app/lib/src/features/graph/graph_canvas.dart`:
  - `_vertical`/`_horizontal` are at `:179-180`, `_rowsFor` at `:1118`, `_routes.geometryFor` at `GraphRouteCache`, `widget.insets`;
  - publish a frame to the source after build (post-frame, only when it changed), and publish null on dispose.
- `app/lib/src/features/graph/graph_layout.dart` -- the accessors: `colOf`, `rowOf`, `timestampOf`, `isStackNode`, `isFolded`, `rootIndex`, `workingCopyIndex`, `placeOfKey`, `edgeCount`/`kindOf`, `utcOffsetMinutes`, `mode`.
- `app/lib/src/features/graph/day_axis.dart:21 graphDayLabel, :41 GraphDayAxis.of` -- reused. `graph_card.dart:428 graphLocalDay` is reused for Compact.
- `app/lib/src/features/graph/graph_edges.dart:95-125` -- the `routeGraph`/`GraphRouteCache` `Isolate.run` pattern to follow.
- `packages/zanshin_core/lib/src/graph_layout/router.dart:542-580` -- `RouteGeometry.pointStarts`/`points`.
- `packages/zanshin_settings/lib/src/model/graph_settings.dart:30` -- the freezed `GraphSettings`; add `showMinimap`, then regenerate with build_runner.
- `app/lib/src/features/graph/graph_preferences.dart:40,89` -- the getter/setter pattern.
- `app/lib/src/features/shell/app_menu.dart:84, :453-466, :600-613` -- the toggle pattern (Group Stacks) and `nativeState`.
- `packages/zanshin_ui/lib/src/materials/zs_glass.dart:47`, `zs_fade.dart` -- the glass card and the fade.
- `app/test/features/shell/shell_toast_test.dart:31,192` -- the "fades through ZsFade, never an Opacity above it" test to mirror.
- `app/test/features/graph/graph_harness.dart:81 handLayout, :226 GraphHarness` -- test fixtures.
- `app/widgetbook/folders/graph.dart:79` -- the graph folder; add a Minimap component. `app/widgetbook/folders/shell.dart:266` `_DemoMinimap` stays.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/minimap_raster.dart` (new) -- a pure-Dart `MinimapRasterInput` (typed arrays: node x/y plane centres, a stack flag, edge point CSR + an indirect flag, the linear map to device px, dpr, size, four colour ints) and `Uint8List rasterMinimap(MinimapRasterInput)`, which returns both layers. No `dart:ui` import -- it runs inside `Isolate.run`.
- `app/lib/src/features/graph/graph_minimap.dart` (new):
  - `GraphMinimapSource` (a `ChangeNotifier` holding a frame: layout, rows, metrics, geometry, insets, vertical/horizontal controllers);
  - `GraphMinimap` (glass card, strip, `RepaintBoundary` raster painter, overlay painter, `Listener`/`MouseRegion` interaction, semantics). Its raster runner is injectable, defaulting to `Isolate.run`;
  - the pure label helpers `minimapLabels(...)` / `minimapDayAt(...)`.
- `app/lib/src/features/graph/graph_canvas.dart`, `graph_view.dart`, `graph_view_model.dart` -- the source wiring and `GraphView.minimap(model)`.
- `app/lib/src/features/home/project_graph_host.dart`, `home_page.dart` -- the slot.
- `app/lib/src/features/shell/floating_shell.dart` -- semantics excluded while hidden.
- `packages/zanshin_settings/...graph_settings.dart` (+ generated), `app/lib/src/features/graph/graph_preferences.dart`, `app/lib/src/features/shell/app_menu.dart` -- the preference and the menu item.
- `app/lib/l10n/app_en.arb` (+ gen-l10n) -- `graphMinimap: "Minimap"`.
- Tests:
  - `app/test/features/graph/minimap_raster_test.dart` -- the raster matrix rows;
  - `app/test/features/graph/graph_minimap_test.dart` -- labels/pill in Free and Compact on a fixed clock, the pill boundary, click/drag offsets with nothing selected, reportUserScroll, wheel, a scroll that does not re-raster (runner call count), a selection change that does not re-raster, a strip resize that re-rasters once, the glass under `ZsFade` with no `Opacity`/`FadeTransition` ancestor, the semantics label;
  - the menu and preference tests (`app_menu_test.dart`, settings tests, `project_graph_host`/home tests if they assert the slots);
  - a shell test: the minimap hides with the inspector, shows during calm, and only fades under reduce motion. Check `floating_shell_test.dart` first; add only what is missing.
- `app/widgetbook/folders/graph.dart` -- a "Minimap" use case beside the recorded graph.
- `_bmad-output/implementation-artifacts/design/DESIGN-SYSTEM-SYNC.md` -- a dated line only if the build departs from DS kit.css:155-172. If it does not depart, no line.

**Acceptance Criteria:**
- Given a project with the default settings, when the graph shows, then the minimap card sits at right 12 from `--chrome-top` to 12 above the bottom, draws the whole graph fitted, and shows the band, @ and the current-day pill.
- Given the inspector opens, when it is open, then the minimap hides (fade plus slide; fade only under reduce motion), and it returns during calm scrolling.
- Given View › Show Minimap, when it is chosen, then the preference flips, persists, and the item's check follows it. When it is off, the right inset is 12 without an inspector.
- Given a 240-frame scroll, when the user scrolls, then no raster runs and no card is built through the minimap; only the overlay repaints.
- Given a scrub on the strip, when it moves, then the graph scrolls vertically only, the selection is unchanged, and calm scrolling is fed.
- Given ledger items I1-I3, then Compact rows are labelled (I1), the glass fades only through `ZsFade` (I2, test), and Compact labels read the raw commit timestamp's day (I3 settled; see Design Notes).

## Spec Change Log

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 28 findings — high 0, medium 3, low 12, false 13, maybe-false 0 (four low rows share one root cause, the `onError` re-pump, and are patched; the other eight lows are rejected as unlikely, or because their fix would add guards)
- findings:
  - **verification-gap layer**
    - `[medium]` `[patch]` No test covers a canvas going away while the minimap stays (`retract`). Added "the canvas going away retracts its frame; the minimap shows an empty card": the frame becomes null and nothing throws.
    - `[medium]` `[patch]` The path "one raster in flight, a superseded result dropped" never runs, because the test runner finishes at once. Added a held-`Completer` runner test: two resizes during a raster coalesce into one raster at the latest size.
    - `[medium]` `[patch]` Nothing checks what the overlay draws. Added a `paints` test that pins the band's rrect, the selection (`--accent-line`) and @ (`--co`) dots at their mapped centres, and the connector at `cy`.
    - `[low]` `[patch]` (other finding) On error, `_pump` is not called again, so a key requested while the failing raster ran is never rastered. Fixed: `if (mounted) _pump();` in `onError`. The held-runner test witnesses it: runs 2 → 3, and a failed key is not retried.
  - **intent-alignment layer**
    - `[false]` `[reject]` I1/I3: the day key is computed in the view, not by the engine (`nodeDays`). The intent hands the I3 decision to this story ("Story 10.16 decides"). The raw-timestamp day is the design's `Date.parse(c.ts)`. `graphLocalDay` is the card's existing day key of one timestamp, not bucketing, and `RecordedGraphLayout` has no `nodeDays`. Recorded in Design Notes.
    - `[false]` `[reject]` I1: a stack's day may not be its newest member's. `timestampOf(stack)` is `runMembersOf(...).last`, and `runMembersOf` is "oldest first" (`graph_layout.dart:309`), so `.last` is the newest.
    - `[false]` `[reject]` I2: the change is only a witness, at the widget-tree level. That is the ledger's own follow-up ("a test like 10.23's"). The fade path already went through `ZsFade`.
    - `[false]` `[reject]` There is no `## Auto Run Result` and no ledger edit yet. That section is written at finalize, below.
  - **blind-hunter layer**
    - `[low]` `[patch]` The error path drops the newest request. Same root cause as the `onError` row above; same fix.
    - `[false]` `[reject]` The band is drawn 4 px past the strip (x 60, width 62). That is the design's own rect (graph-view.jsx:527 `x={MINI_SPLIT + 2} width={MINI_W - MINI_SPLIT + 2}`, svg `overflow:visible`), and it stays inside the card's 8 px padding.
    - `[false]` `[reject]` The canvas never retracts from an old source after a `minimapSource` swap. `GraphView` is keyed `ObjectKey(graph)` per graph set (project_graph_host.dart), so a new model mounts a fresh canvas state.
    - `[low]` `[reject]` The canvas does minimap work on every build. `geometryFor` is cached, the frame is a few references, and `publish` drops equal frames. The canvas does not rebuild per scroll frame: the scroll test shows no re-raster.
    - `[low]` `[reject]` Edge truncation hides a mismatch between the geometry and the layout. The geometry is routed from this layout (the same `GraphRouteCache` the edge painter uses, edge e is edge e). An assert would add complexity for a case not shown to be reachable.
    - `[false]` `[reject]` The label cache ignores the layout. The cache keys on `rows` identity, and the canvas rebuilds `rows` whenever the layout changes (`_rowsFor`: `rows.layout == widget.layout`).
    - `[low]` `[reject]` The text-painter cache only grows. It is bounded by the distinct day labels plus pills, a few hundred strings at most, and is cleared on a theme change.
    - `[low]` `[reject]` An inset change re-rasters. Top and bottom change only when the app enters or leaves full screen, which is rare. A re-raster is a few ms off the UI isolate.
    - `[false]` `[reject]` The premultiplied alpha is unverified. The engine reads raw `rgba8888` as premultiplied (engine `image_descriptor.cc:166-168`, cited by the implementation), so the code is right and the spec's "unpremultiplied" wording is wrong. The fix would edit this build's spec, so the finding is rejected; it is noted under Auto Run Result.
    - `[low]` `[reject]` Several paths are untested: the theme switch, the trackpad pan, the hover pill, the Compact pill under scroll. The theme switch takes the same key path as a resize, which is tested. The pan and hover paths are thin `Listener`/`MouseRegion` adapters. The Compact pill's day lookup is unit-tested.
    - `[false]` `[reject]` The minimap is only a label for VoiceOver. That is the epic's decision (g) and Claude's recorded proposal: one labelled node, no adjustable value; locate @ and go-to-change serve keyboard users.
    - `[low]` `[reject]` `_jump` clamps at 0, not `minScrollExtent`. The canvas's `minScrollExtent` is always 0.
    - `[false]` `[reject]` The hover stays hidden after a drag. The design does the same: graph-view.jsx:520 clears `hov` on pointerdown and restores it only on the next move.
    - `[false]` `[reject]` Show Minimap has no shortcut. The menu bar (11.13, decision 16.42) assigns none to it, and the spec asks for none.
  - **edge-case-hunter layer**
    - `[low]` `[patch]` `onError` does not re-pump. Same root cause as above; same fix.
    - `[low]` `[reject]` `runRaster` or `input()` throwing synchronously would leave `_running` stuck. `Isolate.run` reports errors through its future. `minimapRasterInput` throws only on a programming error, which should fail loudly.
    - `[false]` `[reject]` The canvas `didUpdateWidget` source swap. Refuted as above: `ObjectKey(graph)` remounts.
    - `[low]` `[reject]` A press before the position has dimensions. The strip is built only with a published frame, which the canvas publishes after layout, and `_bandOf` already guards painting.
    - `[false]` `[reject]` The spec says unpremultiplied but the code writes premultiplied. The code matches the engine. Same as the blind-hunter row: the fix would edit this spec.
    - `[low]` `[patch]` The error path skips the latest key. Same root cause and fix as the `onError` rows.

## Design Notes

- **Dots, not a density raster.** The 2026-10-14 design note makes the dots-and-dotted-lines look final, while the raster stays the implementation. So the raster stamps the design's dots instead of the 2026-09-26 difference-array card rectangles. At 100k nodes in about 1,500 px the dots saturate into density anyway. The cost is O(n + total edge length in strip px + pixels).
- **I3 decision.** Compact labels read `graphLocalDay(timestampOf(node))`, the raw commit timestamp's day, and show nothing without a timestamp. That is exactly the design's `Date.parse(c.ts)` (graph-view.jsx:449-455). The view does no bucketing, only the day key of a timestamp, as the cards already do. `GraphGridView.nodeDays`, the clamped day, stays Free's bucket source and is not used here. `RecordedGraphLayout` has no grid, so raw timestamps also cover recorded layouts.
- **Two layers baked, not tinted.** A theme switch re-rasters through the same path (epic item 6 allows this). Painting the out layer at 60 % everywhere and the in layer clipped to the band reproduces `.zk-mini-g` / `.zk-mini-g.in`.
- **The source on the model.** The minimap lives in a sibling shell slot, so it cannot reach the canvas's private controllers. The canvas publishes a frame record to `model.minimapSource` after each build that changed it, the way it already publishes `onWorkingCopyDirection`.

## Verification

**Commands:**
- `cd app && flutter test test/features/graph/minimap_raster_test.dart test/features/graph/graph_minimap_test.dart test/features/shell test/features/home test/features/graph` -- expected: all pass
- `dart analyze app packages/zanshin_settings` -- expected: no issues
- `dart format --set-exit-if-changed app packages/zanshin_settings` (`-l` per the package's analysis options) -- expected: exit 0
- `cd packages/zanshin_settings && flutter test` (or `dart test`) -- expected: all pass
- `cd app && flutter test widgetbook` (catalogue smoke, if present) -- expected: pass

**Manual checks:**
- Marionette in the Widgetbook catalogue: the Minimap use case compared with the DS kit render of `.zk-mini`.

## Auto Run Result

Status: done. Code commit `953bd69a14a61b59a26152c0a3c6d892ad2efe31`.

**What was built**

The minimap fills the shell's existing slot.
- **Raster.** A pure-Dart raster function (`minimap_raster.dart`, no `dart:ui`) runs through `Isolate.run`. It draws the dots, the collapsed-stack rings and the dotted edges, every 3 px for direct edges and every 6 px for indirect ones, in two layers. Only one raster runs at a time: a superseded result is dropped, and the latest key is rastered once afterwards. The result is decoded once into two images.
- **Painting** (`graph_minimap.dart`):
  - the out layer at 60 % inside a `RepaintBoundary`;
  - a band painter;
  - an overlay with the in layer clipped to the band, the selection dot (`--accent-line`), the @ dot (`--co`), the hover line, the `--at-chrome` connector, the day labels, and the current-day and hover pills.
- **Interaction.** A press or drag jumps the graph vertically and selects nothing. The wheel and trackpad scroll both axes. Every press, drag move and wheel event feeds calm scrolling.
- **VoiceOver.** One node, "Minimap", excluded while the minimap is hidden.
- **Wiring.** The canvas publishes a `GraphMinimapFrame` on `GraphViewModel.minimapSource`, and `ProjectGraphSlots.minimap` passes the minimap to `FloatingShell`.
- **Preference.** `GraphSettings.showMinimap` (default true). View › Show Minimap toggles it and shows its check.

**Files changed**

| File | Change |
|---|---|
| `app/lib/src/features/graph/minimap_raster.dart` (new) | The raster input and `rasterMinimap`. |
| `app/lib/src/features/graph/graph_minimap.dart` (new) | The frame, the source, the label helpers and the `GraphMinimap` widget. |
| `app/lib/src/features/graph/graph_canvas.dart`, `graph_view.dart`, `graph_view_model.dart` | Publish the frame; `GraphView.minimap`. |
| `app/lib/src/features/home/project_graph_host.dart`, `home_page.dart` | The minimap slot. |
| `app/lib/src/features/shell/floating_shell.dart` | Semantics excluded while the minimap is hidden. |
| `app/lib/src/features/shell/app_menu.dart`, `graph_preferences.dart`, `packages/zanshin_settings/lib/src/model/graph_settings.dart` (+ generated) | The preference and the menu toggle. |
| `app/lib/l10n/*` | The `graphMinimap` string. |
| `app/widgetbook/folders/graph.dart` | A "Graph › Minimap › Recording" use case. |
| `app/test/features/graph/minimap_raster_test.dart`, `graph_minimap_test.dart` (new) | Tests for the raster and the widget. |
| `app_menu_test.dart`, `floating_shell_test.dart`, `project_graph_host_test.dart`, settings tests | Updated or extended. |

**Deferred-work items**

- **I1 — fixed** (`953bd69a14a61b59a26152c0a3c6d892ad2efe31`). Compact rows are labelled with their newest commit's day, shown only when that day is older than the label above, as the design's minimap does (graph-view.jsx:445-459). See `minimapLabels`, tested by "Compact: a label only where a row is older than the last label …".
- **I2 — fixed** (`953bd69a14a61b59a26152c0a3c6d892ad2efe31`). The minimap's glass fades only through the shell's `_MinimapMotion`/`ZsFade`. The test "the glass fades only through ZsFade, with no Opacity or FadeTransition above it" mirrors 10.23's.
- **I3 — settled** (`953bd69a14a61b59a26152c0a3c6d892ad2efe31`). Compact labels read the raw commit timestamp's day (`graphLocalDay(timestampOf)`), and a node without a timestamp shows nothing, as in the design's `Date.parse(c.ts)`. The clamped `GraphGridView.nodeDays` stays Free's bucket source, and the minimap does not use it. No engine change was needed, and recorded layouts, which have no grid, are covered too. A stack's timestamp is its newest member's (`runMembersOf` is oldest first).

**Review findings.** 28 in total:
- 3 medium test gaps, patched with new tests: the canvas retracting its frame, a raster in flight being coalesced, and the overlay's paints.
- 1 low root cause, the error path not re-pumping, patched. Four rows reported it.
- 8 low rejected and 13 false, each with its reason in the triage log.
- None deferred, so nothing was mirrored into deferred-work.md.

**Follow-up review recommended:** false. The patched entries were 3 medium test-only additions and 1 low; there was no high, and the medium fixes add tests only.

**Spec deviations recorded**
- The raster bytes are *premultiplied* RGBA, against the spec's "unpremultiplied". The engine reads raw `rgba8888` as premultiplied (`image_descriptor.cc:166-168`), so the code is right.
- The strip inset 12/8 is measured from the card's outer edge.
- The @ dot maps through `placeOfKey(keyOf(@))`, so @ inside a collapsed stack lands on the stack card.

**Verification** (targeted checks, per this run's gate rule; no `cargo make test`, `test-full` or `coverage`):
- `flutter test test/features/graph test/features/shell test/features/home test/widgetbook` (app): +1363, all passed. The minimap file alone, after the review patches: +12, all passed.
- `flutter test` in `packages/zanshin_settings`: +41, all passed.
- `dart analyze --fatal-infos` on app and zanshin_settings: no issues.
- `dart format --set-exit-if-changed`: 0 changed.
- Not run: the full app suite. A previous run showed 5 failures in `worker_project_repos_test.dart`; those need the pinned environment that `cargo make` provides, and this story does not touch them.
- No Rust, FFI or schema change, so no cargo, codegen or parity run.

**Residual risks**
- The Marionette visual check in the catalogue against the DS kit was not done in this unattended run.
- The decoded images are not asserted in widget tests: the decode needs real async, so the tests count raster runs and check paints only.
- The Compact label pass is O(n) on the UI isolate, once per layout or per change of "now".
