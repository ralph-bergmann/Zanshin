---
title: "Story 10.2 — Canvas and Free's day axis: the window canvas, day labels on the dividers, no gutter"
type: 'feature'
created: '2026-10-30'
status: 'done'
baseline_revision: 'f22423ff5680e78c8b32045e3787c86d1d2a9caa'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Nothing yet refreshes the day axis's "now" on window focus or at local midnight; the axis only re-formats when its owner passes a new nowMs.
    evidence: |-
      Design question (a), Claude's proposal: freeze "now" per reload, re-format on window focus and at midnight (a repaint). 10.2 exposes nowMs as a paint-only input and witnesses the repaint; the clock and the reload belong to 10.5's view model, whose story text names neither trigger.
    location: >-
      app/lib/src/features/graph/day_axis.dart (GraphDayAxisPainter.nowMs)
    severity: low
    resolved: >-
      2026-10-30 — fixed (spec-10-5-graph-view-model-repo-wiring, commit 5d5548c): GraphViewModel.now is fresh on every reload and on window focus and ticks on each minute boundary, so midnight lands on time.
  - summary: >-
      Day labels are excluded from semantics, so the card's own semantics label must carry its date (design question (d), Claude's proposal); the placeholder cards carry none.
    evidence: |-
      The axis paints only (no semantics node). Cards and their semantics label are Story 10.3's.
    location: >-
      app/lib/src/features/graph/day_axis.dart
    severity: low
    resolved: >-
      2026-10-30 — fixed (spec-10-3-commit-cards, commit ecfa75e): the card's label ends with the spoken relative date and the axis's day label, refreshed on the minute tick.
  - summary: >-
      The day axis was not checked visually (Marionette) in the running catalogue.
    evidence: |-
      The unattended loop cannot hold a `flutter run -d macos -t widgetbook/main.dart` session; widget tests cover placement, paint order, stickiness and pass-through, the smoke test covers building.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
    resolved: >-
      2026-10-31 — fixed (console session, Marionette): dividers and pills in the Scale case match days.card.html; the pill has the CSS geometry (2 × 7, 1 px border, radius 5), its rounding moves it at most 0.5 px. The midnight crossing went to Story 4.16 (Ralph).
---

<intent-contract>

## Intent

**Problem:** The graph viewport (10.1) shows cards on an empty plane. Free, the default layout, has no day axis, so nothing on the graph tells you which calendar day a commit falls on.

**Approach:** Build the day axis that `_bmad-output/planning-artifacts/epics.md:8632-8776` specifies. The 2026-10-14 and 2026-10-16 notes win over items 1–10. Its parts:
- the axis's positions, computed from the layout's day buckets through `VerticalLayout`;
- the dashed dividers, painted in 10.1's background hook;
- the sticky label pills, painted in the overlay hook;
- the label text ("Today", "Yesterday", "Sep 23", "Dec 29, 2025");
- `GraphTheme`'s day-axis roles.

The window canvas is already `ZsCanvas` in the shell's canvas slot (11.4, `app/lib/src/features/home/home_page.dart:52`). So the viewport stays transparent, and the Graph folder puts the viewport over `ZsCanvas`.

## Boundaries & Constraints

**Always:**
- Positions come from the layout. The view reads the buckets (`bucketValueOf`, `bucketFirstRowOf`, `bucketLastRowOf`, ascending oldest first) and `VerticalLayout`. It never computes T, the days, or a bucket. It is O(#days) per layout/metrics change, plus a binary search per paint.
- Placement, in content (plane) coordinates. H is the card height. Days are indexed b = 0 (oldest) … B−1:
  - `lo(b)` = `topOfRow(bucketFirstRowOf(b))`, the top of the day's oldest card.
  - `floor(b)`:
    - for b > 0: `topOfRow(bucketLastRowOf(b−1))`;
    - for b = 0 with the root in the layout: `top(rootIndex)`;
    - otherwise: `lo(0) + H + gapY`.
  - `g(b) = (floor(b) + lo(b) + H) / 2`.
  - The label centre is `y(b) = min(g(b), y(b−1) − 22)`, with `y(−1) = +∞`. A newer label is pushed up, never down.
  - The divider is at `g(b)` for b > 0. The oldest day has none.
  - This is the design's own algorithm (`design/graph-layout.jsx:586-603`).
- Only `GraphMode.free` shows an axis. Compact shows no labels and no guides, and keeps the same width and columns. There is no gutter and no fade, and offX stays 0.
- Guides:
  - 1 px in `--border-strong`, dash 2 6, with the phase anchored to content x 0;
  - horizontally across the whole visible rect;
  - all visible guides in **one** `drawRawPoints(PointMode.lines, …)` call, in the background hook (behind the edges).
- Labels:
  - a pill of 11 px JetBrains Mono (`ZsType.id` at `ZsType.fsSm`) in `--text-muted`;
  - a `--card-solid` fill, a 1 px `--border`, padding 2 × 7, radius 5 (`radiusTag`);
  - vertically centred on `y(b)`;
  - its left edge at viewport x = `insets.left − 4` (stickyLeft = inset − 6, labelLeft = 2), so it is sticky horizontally and scrolls vertically with its divider;
  - painted in the overlay hook, above the cards.
  - Cached `TextPainter`s are never measured into the geometry.
  - Hits pass through: the axis is paint-only.
- Label text from the bucket value v (local midnight, epoch ms) at the layout's fixed offset `off = utcOffsetMinutes · 60000`, against `nowMs`:
  - `today = dk(nowMs)`, where `dk(t) = (t + off) − (t + off) mod 86400000 − off`;
  - v ≥ today → "Today" (future days too);
  - v = today − 86400000 → "Yesterday";
  - else "MMM d" (en-US abbreviations), plus ", yyyy" when the year of v + off ≠ the year of nowMs + off (both read as UTC).
  - Hard-coded English; there is no intl dependency (the localisation question is open, deferred-work.md:764).
- `nowMs` is a paint-only input. A new value re-formats the labels with a repaint, never a layout request.
- Colours come from `GraphTheme`, which derives them from `ZsColors` (no colour typed twice). The app imports `zanshin_ui` only through its barrel.

**Never:**
- Bucketing, rows, or computing days in the view.
- The dot grid, the 88 px gutter, its gradient, a pinned current-day label, Time/age labels.
- A second canvas painter in the viewport.
- The clock policy's triggers (window focus, midnight timer) and "now" ownership (10.5).
- Cards and edges (10.3/10.4), the minimap's pill (10.16), the Layout control (10.7).
- An intl/l10n dependency.
- Golden tests.
- Touching `graph_poc/` or `main2/3/4.dart`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| No buckets | compact layout, or free with 0 buckets / n = 0 | empty axis; hooks paint nothing | no exception |
| Root shown | free, `rootIndex` set | oldest label midway between the oldest card's bottom and the root's top; no divider | — |
| Root not shown | `rootIndex` null | oldest label at `lo(0) + H + gapY/2` | — |
| Two days share a row | `lastRow(b−1) == firstRow(b)` | `g = top + H/2`, which crosses the card (known limit, defect 45, accepted); labels ≥ 22 px apart | — |
| Close dividers | g(b) > y(b−1) − 22 | y(b) = y(b−1) − 22; the divider stays at g(b) | — |
| Offset ≠ 0 | utc_offset_min 120, v = local midnight | the label shows the local date of v + off | — |
| Previous year | v in 2025, now in 2026 | "Dec 29, 2025" | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:8632-8776` -- Story 10.2. The 2026-10-14 note (`:8640-8670`) and the 2026-10-16 note (`:8672-8676`) supersede items 1, 2 and 9's placement and pin. The witnesses at `:8762-8776` are amended by `:8664-8669`.
- Design (inspiration; tokens/CSS win over prose):
  - `_bmad-output/implementation-artifacts/design/graph-layout.jsx:36-45` -- `dayBucket` label rules: Today if key ≥ today, Yesterday, `en-US` `{month:"short", day:"numeric"}`, plus the year when it is not the current year.
  - `_bmad-output/implementation-artifacts/design/graph-layout.jsx:586-603` -- the placement algorithm above.
  - `_bmad-output/implementation-artifacts/design_system/components/graph/DayAxis.prompt.md:14-19` and `DayAxis.jsx` -- sticky column, `stickyLeft = inset − 6`, `labelLeft = 2`, `aria-hidden`.
  - `_bmad-output/implementation-artifacts/design_system/components/graph/graph.css:98-104` -- the guide is `stroke var(--border-strong) 1 dasharray 2 6`; the label is `font var(--fs-sm) var(--font-mono)`, `--text-muted`, padding 2 7, `--radius-tag`, `--card-solid`, 1 px `--border`, `translateY(-50%)`.
- `app/lib/src/features/graph/graph_layout.dart:45-150`:
  - `GraphBucketKind.day`, the bucket accessors (first/last row = least/largest y in 1/U units, `docs/graph-layout.md:231-238, :341-362`);
  - "consumers add accessors". Add `utcOffsetMinutes` and `rootIndex` here.
- `app/lib/src/features/graph/recorded_graph_layout.dart:14-48, :88-168`:
  - the constructor and `fromSpec`. The §2 input (embedded in the recordings) carries `utc_offset_min` and a per-node `is_root`;
  - read both. Only `design-all` has a root (`is_root:true`); medium-narrow has offset 120.
- `app/lib/src/features/graph/vertical_layout.dart:13-142` -- `VerticalLayout` and its two implementations.
  - `UniformRows.top` = `pad + (rows − U − row)·step`.
  - `PerNodeTops` keeps `_byNode`.
  - Add `topOfRow(int row)` to both.
- `app/lib/src/features/graph/graph_viewport_render.dart:22` -- `GraphPaintHook(PaintingContext, Offset origin, Rect visibleRect)`.
  - `_paintContents` (`:565-586`): `origin = offset + insets.topLeft − scroll`, `visible = (scroll − insets.topLeft) & size` in content coordinates.
  - Viewport left edge on screen = `origin.dx + visible.left`.
  - Hook setters only `markNeedsPaint` (`:247-275`).
  - The order is background → edges → cards → overlay.
- `app/lib/src/features/graph/graph_viewport.dart:32-58` -- `paintBackground` / `paintOverlay` / `insets` / `verticalLayout` params.
- `app/lib/src/features/graph/graph_metrics.dart` -- `cardHeight`, `gapY`, `pad`.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart:15-61` -- `GraphTheme` (canvas roles from 10.1); add the day-axis roles. The test is `packages/zanshin_ui/test/design/graph_theme_test.dart`.
- `packages/zanshin_ui/lib/src/design/zs_colors.dart:783-852` -- `cardSolid`, `border`, `borderStrong`, `textMuted`.
- `zs_type.dart:24,58` -- `ZsType.monoFamily`, `fsSm` = 11; `ZsType.id` (mono role).
- `zs_metrics.dart:213` -- `radiusTag` = 5.
- `packages/zanshin_ui/lib/src/materials/zs_canvas.dart` -- `ZsCanvas`, the window canvas (exported), already the shell's canvas (`app/lib/src/features/shell/floating_shell.dart:385`, `home_page.dart:52`).
- `app/widgetbook/folders/graph.dart:18-147`:
  - the Graph folder, `_GraphDemo` (owns its controllers), `recordedLayout`;
  - the left-inset knob defaults to 0 today; the design's rail inset is 76.
- `app/widgetbook/graph/synthetic_layout.dart:17-159` -- `syntheticLayout(n, free:)`. Free emits no buckets today (10.1 review: "10.2 extends the generator"). Id 0 (node index n−1) is the root, at row index 0.
- `app/test/features/graph/graph_harness.dart` -- the harness:
  - `surface` 800×600;
  - `recording(name)`;
  - `handLayout(nodes, edges, unit, workingCopy)`, which needs optional buckets/root/offset;
  - `GraphHarness` (with `background`/`overlay` hooks, `insets`, `verticalLayout`, `v`/`h` controllers, `log.taps`);
  - `pumpGraph`.
- `app/test/widgetbook/catalogue_smoke_test.dart` -- pumps every Graph use case.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_layout.dart` -- add `int get utcOffsetMinutes` (the fixed offset the days were cut at) and `int? get rootIndex` (the `root()` commit, when in the layout). -- the label and the oldest-day rule need them.
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- add the constructor params `utcOffsetMinutes = 0` and `rootIndex`. `fromSpec` reads `input['utc_offset_min']` (default 0) and the node whose `is_root == true`. -- data the input already carries.
- `app/lib/src/features/graph/vertical_layout.dart` -- add `double topOfRow(int row)`:
  - `UniformRows`: the formula of `top` with the given row (and `top` delegates to it);
  - `PerNodeTops`: the top of the first node at that row (a row→top map built once). It is documented for rows that hold a node.
  -- O(1) divider positions.
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` -- add `dayGuide` (borderStrong), `dayLabelText` (textMuted), `dayLabelFill` (cardSolid), `dayLabelBorder` (border) to the ctor, `fromColors`, `copyWith`, `lerp`, `==`, `hashCode`. Extend `graph_theme_test.dart` (night/paper equal `ZsColors`', lerp). -- the token rule.
- `app/lib/src/features/graph/day_axis.dart` (new):
  - `String graphDayLabel(int dayMs, {required int nowMs, required int utcOffsetMinutes})`.
  - `GraphDayAxis`, an immutable model: `GraphDayAxis.of(GraphLayout, VerticalLayout)` builds `values`, `labelYs`, `guideYs` per the Always rules (empty unless free). It has a `length`, and range queries over the descending y arrays by binary search.
  - `GraphDayAxisPainter({axis, theme, nowMs, utcOffsetMinutes})`:
    - `paintGuides(context, origin, visible)`;
    - `paintLabels(context, origin, visible, {required double leftInset})`;
    - a per-label `TextPainter` cache, and `dispose()`.
- `app/widgetbook/graph/synthetic_layout.dart` -- in `free`, emit one day bucket per 25 row indices (row index ≥ 1; the root at row index 0 is in none). The value is a fixed base midnight + d·86400000, with start/end the y of the day's first and last row index. Set `rootIndex` = n − 1. -- the Scale case shows the axis at 100k.
- `app/widgetbook/folders/graph.dart` -- `_GraphDemo`:
  - a `Stack` of `ZsCanvas` and the viewport;
  - builds `UniformRows` once per layout/metrics and passes it to the viewport and the axis;
  - wires the background and overlay hooks to a `GraphDayAxisPainter`, held in state and recreated (the old one disposed) when the layout, vertical layout, theme or now changes;
  - `nowMs` is the recording input's `now_ms`; for synthetic layouts it is the newest bucket value + 12 h;
  - the left-inset knob defaults to 76.
- `app/test/features/graph/graph_harness.dart` -- `handLayout` gains optional `buckets` (`List<(int value, int first, int last)>`), `root`, `utcOffsetMinutes`.
- `app/test/features/graph/day_axis_test.dart` (new) -- the witnesses below. Scroll cases run under `TargetPlatformVariant.only(TargetPlatform.macOS)`.

**Acceptance Criteria:**
- Given `graphDayLabel` with fixed now and offset, then:
  - today and a future day → "Today";
  - the day before → "Yesterday";
  - "Sep 24";
  - a previous-year day → "Dec 29, 2025";
  - with offset 120, a local-midnight value shows the local date.
- Given a free hand layout, on `UniformRows` and on a `PerNodeTops` fixture, then:
  - each divider sits at `(top(newest card of the older day) + bottom(oldest card of this day)) / 2`;
  - the oldest day's label sits midway to the root's top with a root, or `H + gapY/2` below its oldest card's top without one, with no divider;
  - a newer label closer than 22 px is pushed up to exactly 22 px;
  - a shared row puts its label inside the card (known limit).
- Given every free recording (and the 10k synthetic free layout), then label ys strictly decrease with the bucket order, every label is ≥ 22 px from the next, and there is one label per bucket.
- Given the `paints` matcher on a free recording, then the order is clipRect → the guides' single `drawRawPoints` (background hook) → edges hook → cards → label `drawRRect`s (overlay hook). A compact recording paints no guide points and no pill.
- Given the design recording switched Free ↔ Compact, then the horizontal max scroll extent and every `colOf` are equal, and only Free paints labels and guides.
- Given a horizontal scroll, then every label's screen left stays at `insets.left − 4`. Given a vertical scroll by d, then labels and dividers move by −d on screen.
- Given the left inset changed per frame (76 → 388 → 76, a panel drag or collapse), then:
  - the label column follows `inset − 4` in the same frame;
  - no card's screen rect moves;
  - no divider's screen y moves.
- Given a tap at a label's centre over a card (shared-row layout, scrolled under the column), then the card receives the tap.
- Given `nowMs` moved past midnight, then the labels re-format ("Today" → "Yesterday") with no new `GraphLayout` and no layout pass of the viewport (`debugNeedsLayout` false after the hook swap, repaint only).
- Given the catalogue, then the Graph folder's use cases pump without exception (smoke test), with the canvas behind the viewport.

## Spec Change Log

## Review Triage Log

### 2026-10-30 — Review pass
- verdicts: 31 findings — high 0, medium 2, low 24, false 5, maybe-false 0 (the intent-alignment divergences count as findings)
- findings:
  - `[low]` `[reject]` (blind #1) The label cache keyed by bucket index never shrinks. At 100k, after scrolling the whole history, that is about 1,600 small `TextPainter`s, freed on dispose. Keying by string does not bound it, since dates are unique, and eviction adds state.
  - `[low]` `[reject]` (blind #2) The demo disposes the old painter in `build`, and a disposed painter can repaint. In the same build the new closures replace the old ones through `updateRenderObject`, and Flutter does not discard a completed build. It is catalogue-only code; 10.5 owns the product's lifetime logic.
  - `[low]` `[patch]` (blind #3) No test pins the dash phase or the guides' horizontal extent, and the `Set` hides double draws. Added a test of the dash x starts in plane coordinates before and after a horizontal scroll, and of the coverage of the visible rect.
  - `[medium]` `[patch]` (blind #4, grouped with verification-gap #1) `fromSpec`'s `is_root` / `utc_offset_min` parsing is untested. The `fromSpec` test's input now carries offset 120 and asserts `utcOffsetMinutes` and `rootIndex`.
  - `[low]` `[reject]` (blind #5) No bucket validation; `PerNodeTops.topOfRow` throws on a row without a node, while `UniformRows` returns a y. Buckets come from the engine, whose I5 guarantees sorted, member-bearing ranges (docs/graph-layout.md:1105-1112); `topOfRow` documents the contract. Adding a checker rule is new guard code for data that cannot violate it.
  - `[low]` `[patch]` (blind #6) Untested edges: a free layout with nodes and zero buckets, a negative offset, Yesterday across a year boundary. Added the three tests. The past year at a non-zero offset is covered by the offset and previous-year cases together.
  - `[low]` `[patch]` (blind #7) The synthetic timestamps contradict the new day buckets. Timestamps are now derived from the row's day: half-hour steps inside the day of the 25-row block.
  - `[low]` `[patch]` (blind #8) Guides and pills are not pixel-aligned, so 1 px dashes smear. The guide y snaps to `floor + 0.5`, and the pill rects are rounded.
  - `[low]` `[reject]` (blind #9) `leftInset` duplicates the viewport's inset. `GraphPaintHook` (10.1) carries no insets, and widening the typedef changes the viewport API; each owner passes the inset it gives the viewport, and in one place.
  - `[low]` `[reject]` (blind #10, grouped with edge #4) The pill is clipped by 4 px at left inset < 4. The design places it at inset − 6 + 2 (DayAxis.prompt.md:16), and the product inset is ≥ 76 (the rail); only the test harness and a catalogue knob reach 0.
  - `[low]` `[reject]` (blind #11) `_labelReach = 24` is a magic number. The pill is about 19 px tall (11 px mono, height 1.35 + 6), so the reach covers it with margin; the font size is fixed.
  - `[low]` `[reject]` (blind #12) `recordedNowMs` decodes the input a second time. It is catalogue-only and cached per sample; `GraphLayout` deliberately carries no "now" (the clock is the view's).
  - `[false]` `[reject]` (blind #13) The deferred items are not mirrored into deferred-work.md. Finalize writes the mirror in the commit with the spec, as the run's rule asks; it is done ("Surfaced in Story 10.2").
  - `[low]` `[reject]` (edge #1) `PerNodeTops.topOfRow` hits a null-check on a bucket row without a node. This is the same contract as blind #5; `PerNodeTops` serves hand fixtures only.
  - `[low]` `[reject]` (edge #2) Same-row nodes with different tops in `PerNodeTops` give order-dependent dividers. Fixtures and 10.13's variant give one top per row; nothing builds such a fixture.
  - `[low]` `[reject]` (edge #3) Cumulative push-up drift over many days closer than 22 px. This is the design's own algorithm (graph-layout.jsx:599). In free, a day apart is ≥ 20 units (1.25 pitch, about 69 px), so only midnight-straddling commits get close, and runs of them do not occur.
  - `[low]` `[reject]` (edge #4) A left inset < 4 clips the pill. Grouped with blind #10.
  - `[low]` `[reject]` (edge #5) Labels ignore the text scaler. Flutter on macOS gets no system text scale (it stays 1.0), and the label size is the DS token; threading a scaler adds a parameter for a case macOS does not produce.
  - `[low]` `[reject]` (edge #6) The radius comes from `ZsMetrics.standard`, not the theme's metrics. This is consistent with `GraphMetrics`, which takes every graph metric from `ZsMetrics.standard` (10.1); no theme overrides metrics.
  - `[false]` `[reject]` (edge #7) Yesterday renders as a date when the bucket value is not exactly the offset's local midnight. The engine's dk is exact by construction, `((T + off) div 86400000)·86400000 − off` (docs/graph-layout.md:344), so the trigger cannot occur.
  - `[medium]` `[patch]` (verification-gap #1) `fromSpec`'s new fields are untested. Grouped with blind #4; patched.
  - `[low]` `[patch]` (verification-gap #2) The smoke test cannot see the demo's `ZsCanvas`. The smoke test now expects one `ZsCanvas` for `graph/` use cases.
  - `[false]` `[reject]` (intent-alignment, canvas) The graph view does not paint the canvas. The window canvas is `ZsCanvas` in the shell's slot (11.4, home_page.dart:52), and no production graph view exists yet; the transparent viewport is the epic's transparent mode (Design Notes).
  - `[low]` `[reject]` (intent-alignment, delivery surface) The axis is wired only in the catalogue. The intent's non-goals put the view model, the clock and real buckets in 10.5 and 10.12; the Graph folder is Epic 10's only demo host.
  - `[low]` `[reject]` (intent-alignment, Free ↔ Compact) The switch is tested by swapping recordings, not through a view model. No switch surface exists before 10.7's Layout control; the property witnessed (same width, same columns, axis only in Free) is the intent's.
  - `[low]` `[reject]` (intent-alignment, panel drag) The inset witness sets insets rather than dragging a panel. The panel and its 320 px rule are 10.5's and 11's; the axis's surface is the live left inset.
  - `[low]` `[reject]` (intent-alignment, midnight) Midnight is simulated with a new `nowMs`. The trigger is deferred to 10.5 (frontmatter `deferred`, deferred-work.md).
  - `[low]` `[reject]` (intent-alignment, clamped child) No recording is shown to contain a clamped child. The view never sees T: it reads bucket order, and labels follow it on every free recording and on synthetic 10k. The clamping is the engine's (4.11), with its own goldens.
  - `[low]` `[reject]` (intent-alignment, semantics) Each card's date in its semantics label is missing. Deferred to 10.3, which owns card semantics.
  - `[false]` `[reject]` (intent-alignment, mirror) The deferred mirror is absent. It is written at finalize, in the spec's commit.
  - `[false]` `[reject]` (intent-alignment, verification notes) No outcomes are recorded. Finalize records them under Verification notes.

## Design Notes

- **Canvas.** Claude's proposal at plan time was that the graph view paints the canvas and a transparent mode lets 11.4 paint the window. 11.4 has since shipped `ZsCanvas` in the shell's canvas slot. So the viewport stays transparent, which is the transparent mode, and adds no second painter.
- **Why `topOfRow`.** The epic places divider k from the tops of rows `end(k−1)` and `start(k)` "through 10.1's `VerticalLayout`" in O(#days). Node-based tops would need an O(n) scan per layout. `PerNodeTops` maps rows to tops only for hand fixtures and 10.13's variant.
- **Painter lifetime.** The hooks are closures over one painter instance. A rebuild with the same painter still swaps the closure. That costs a repaint, never a layout or a card build (10.1's witness (i) counts builds, not paints).

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `(builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/app && flutter test test/features/graph test/widgetbook)` -- expected: all pass.
- `(builtin cd /Users/ralph.bergmann/development/projects/privat/Zanshin/packages/zanshin_ui && flutter test test/design)` -- expected: all pass.
- `dart analyze --fatal-infos app packages/zanshin_ui` -- expected: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui` -- expected: exit 0.

**Manual checks (if no CLI):**
- Best-effort Marionette check of `graph/viewport/recording` in the catalogue (labels on the dividers, sticky at the inset). Record the outcome, or the reason it could not run.

**Verification notes (2026-10-30, after the review patches):**
- `flutter test --reporter=failures-only test/features/graph test/widgetbook` (app): 417 passed (414 before the review patches).
- `flutter test --reporter=failures-only test/design` (packages/zanshin_ui): 72 passed.
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed.
- Marionette check: not run. The unattended synchronous run cannot hold `flutter run -d macos -t widgetbook/main.dart`. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.2").
- No Rust, FFI, schema or jj verb changed, so no cargo, clippy, codegen or parity check applies. The full gate (`cargo make test`) is left to the story loop's end, per this run's gate rule.

## Auto Run Result

Status: done. Code commit `6b647c38b54d8b27874c9c14819ce35689d80f9b`, plus the follow-up commit that carries this spec, `epic-10-context.md` (recompiled), `deferred-work.md` and `sprint-status.yaml`.

**Summary.** This adds Free's day axis (Story 10.2, with its 2026-10-14 and 2026-10-16 notes):
- `GraphDayAxis` places one label per engine day bucket on the divider below that day's oldest card. The oldest day's label goes midway to the root, or half a gap below. Newer labels are pushed up to stay 22 px apart. Every y comes through `VerticalLayout.topOfRow`, in O(#days), and the axis is empty in Compact.
- `GraphDayAxisPainter` paints the dashed guides in a single `drawRawPoints` call in the background hook, with the phase anchored to plane x 0 and the line snapped to the pixel. It paints the sticky pills at viewport x `inset − 4` in the overlay hook. It only paints: hits pass through, and it adds no semantics. A new `nowMs` costs a repaint, never a layout.
- `graphDayLabel` returns "Today" (future days too), "Yesterday", "Sep 23", or "Dec 29, 2025", at the layout's fixed offset, in hard-coded en-US.
- `GraphLayout` gains `utcOffsetMinutes` and `rootIndex`, which `fromSpec` reads from the §2 input. `GraphTheme` gains four day-axis roles taken from `ZsColors`.
- The canvas was already there: the shell's `ZsCanvas` from 11.4. The viewport stays transparent, and the Graph folder stacks `ZsCanvas` behind it.

**Files:**
- `app/lib/src/features/graph/day_axis.dart` (new): the label text, the axis model and the painter.
- `app/lib/src/features/graph/graph_layout.dart`: the accessors `utcOffsetMinutes` and `rootIndex`.
- `app/lib/src/features/graph/recorded_graph_layout.dart`: the constructor params; `fromSpec` reads `utc_offset_min` and `is_root`.
- `app/lib/src/features/graph/vertical_layout.dart`: `topOfRow` (`UniformRows` by its formula, `PerNodeTops` through a row→top map).
- `packages/zanshin_ui/lib/src/design/graph_theme.dart` and `test/design/graph_theme_test.dart`: `dayGuide`, `dayLabelText`, `dayLabelFill` and `dayLabelBorder`.
- `app/widgetbook/folders/graph.dart`: `ZsCanvas` behind the viewport, the rows and the axis painter held in state, "now" from the recording, the left inset defaulting to 76.
- `app/widgetbook/graph/synthetic_layout.dart`: free day buckets (one per 25 rows), `rootIndex`, and timestamps inside their day.
- `app/test/features/graph/day_axis_test.dart` (new), `graph_harness.dart` (`handLayout` gains buckets, root and offset), `recorded_graph_layout_test.dart`, `app/test/widgetbook/catalogue_smoke_test.dart`: the witnesses.

**Review.** 31 findings: 0 high, 2 medium, 24 low, 5 false.
- Patched, 6 entries (1 medium, 5 low):
  - `fromSpec`'s offset and root are now asserted (medium; blind #4 and verification-gap #1);
  - the smoke test checks the `ZsCanvas` behind the Graph use cases;
  - a test pins the dash phase and its extent;
  - new edge tests: free with nodes but no buckets, Yesterday across a year boundary, a negative offset;
  - the synthetic timestamps now fall inside their day;
  - the guides and pills are snapped to the pixel.
- Deferred, 3, mirrored to deferred-work.md:
  - refreshing "now" on window focus and at midnight (10.5);
  - the card's date in its semantics label (10.3);
  - the Marionette visual check.
- Rejected, 24 rows (7 rows were patched in 6 entries), each with its reason in the Review Triage Log. Among them:
  - the unbounded label cache;
  - disposing the painter during build in the demo;
  - bucket validation (guaranteed by the engine's I5);
  - `leftInset` as a separate argument;
  - clipping when the inset is below 4;
  - the text scaler, which macOS keeps at 1.0;
  - push-up drift, which is the design's own algorithm;
  - the intent-alignment divergences: canvas, product wiring, mode switch, panel drag, midnight, clamped child. Each is owned by 10.5, 10.7, 10.12 or 10.3, or is settled in the Design Notes.
- Follow-up review recommended: **false**. This was the first pass; no high was patched and only one medium (patched by verdict: medium 1, low 5).

**Residual risks:**
- Nobody has looked at the axis on screen yet, so the pill height can be off by about a pixel against the DS card. `ZsType.id`'s line height of 1.35 stands in for CSS `normal`.
- Two commits straddling midnight closer than about 25 minutes put their divider and label across a card (the known limit, deferred-work.md:964).
- The label strings are English-only until the app-wide localisation question is decided.
