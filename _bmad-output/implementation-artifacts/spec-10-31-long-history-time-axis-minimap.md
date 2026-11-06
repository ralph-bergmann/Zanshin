---
title: 'Story 10.31 — Long histories: GraphBreak, year labels, a minimap sized and scrolled by its content'
type: 'feature'
created: '2026-11-06'
status: 'done'
baseline_revision: '871a3faa6251bf4cfb67f96974d9c25ee0e6647a'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      No test pins that the home page hands the graph's minimap card width to the floating shell.
    evidence: |-
      home_page.dart passes minimapWidth: graph.model?.minimapSource.cardWidth; the shell and minimap tests wire their own notifier, so dropping that argument would pin the card at 134 px unnoticed.
    location: >-
      app/lib/src/features/home/home_page.dart:116
    severity: low
  - summary: >-
      The Widgetbook catalogue cannot show a long history: breaks live in BackendGraphLayout, recorded layouts carry none.
    evidence: |-
      GraphLayout.breaks defaults to empty; RecordedGraphLayout and the synthetic fixtures keep their rows, so no catalogue use case renders a GraphBreak for a Marionette check.
    location: >-
      app/lib/src/features/graph/graph_layout.dart (breaks), recorded_graph_layout.dart
    severity: low
  - summary: >-
      The Marionette witness on dart-intellij-third-party against the DS card Long history was not run.
    evidence: |-
      The running app with that repository could not be started in the unattended run; widget tests cover the paint and the math only.
    location: >-
      design_system/components/graph/long-history.card.html
    severity: low
---

<intent-contract>

## Intent

**Problem:** On a long history (Ralph's `dart-intellij-third-party`, 4674 changes 2013–2025) Free leaves screens of empty canvas below collapsed stacks (they keep their hidden members' time below them; the largest left ≈ 64 screens), the minimap's day labels lose their left part ("Dec 16, 2015" in a 58 px column), and the fitted 118 px minimap squeezes twelve years into its height.

**Approach:** Build to DS sync #22 (`GraphBreak`, `DayAxis years`, card `design_system/components/graph/long-history.card.html`, readme › Long histories; prototype `design/graph-layout.jsx` `shortenFree`/`spanLabel`, `design/graph-view.jsx` `BreakBand`/`GraphMinimap`). Free shortens every card-free stretch taller than 8 pitches to 1½ pitches in the layout's rows (one mapping every view reads) and marks it with a torn strip and its span; day labels drop the year, years get labels of their own; the minimap's width follows the columns, keeps ≥ 2 px per pitch and scrolls with the canvas.

## Boundaries & Constraints

**Always:**
- The break rule lives in the layout's row accessors (`BackendGraphLayout.rowOf`, `rows`, `bucketFirstRowOf`, `bucketLastRowOf`), in layout units (U = 16): over the distinct rows of laid-out nodes (`rowOf ≥ 0`, not folded), a step > `8·U` between consecutive rows is cut to `1.5·U` (= 24), every row above shifted down by the saving. Canvas, router B input (`graph_edges.dart` `_routeInput`), day axis, gap markers, go-to/scroll math (`VerticalLayout`) and minimap then agree with no further change. Free only; Compact untouched.
- Each break carries the lower card row's newest timestamp `t0` and the upper card row's oldest `t1` (`timestampOf`, nulls ignored); its label is "‹length› · ‹range›" read at the layout's fixed UTC offset: length = years (≥ 548 d, round d/365), months (≥ 60 d, round d/30.4), weeks (≥ 14 d, round d/7), else days (≥ 1); range = "Sep 2019 – May 2025" (years differ), "Jun – Dec 2025" (months differ), "Jun 3 – 24" (same month). No label when either time is missing. Strings through the ARB (plurals), intl month/day formats at the strings' locale.
- Canvas break (DS GraphBreak + graph.css `.zs-break*`): band = upper card's bottom to lower card's top; a strip across the visible plane width at the band's centre c: two zigzag edges (amplitude 3, every 9 px, phases 0/1, at c − 9 and c + 9, anchored to plane x 0), filled `--fl-bg-solid` at .92 between them, edges 1 px `--border-strong`; painted over the edges and gap marks, under the cards. Its label: a day-label pill (mono 11, `--card-solid` fill, 1 px `--border`, radius tag) in `--text-dim`, centred on c, at the day labels' sticky left.
- Day axis (`DayAxis` years): `graphDayLabel` never carries a year (Today · Yesterday · `MMMd`). A day whose divider falls inside a break band is dropped (label and divider). Where a year begins (a kept divider between two buckets of different years) the newer year is drawn as its own label 22 px above that day's label (600, `--fs-xs` 10.5 sans, `--tracking-pill` .08 em, `--text-muted`, at the label's left); none inside a break, none for a one-year history.
- Minimap (graph-view.jsx `minimapSize`/`GraphMinimap`, float.css `.gmini-*`): graph part `gw = clamp(span·0.04 + 16, 60, 160)` with span = max − min centre x of laid-out nodes, strip = 58 + gw, card = strip + 16, `kx = span > 0 ? min(0.04, (gw − 16)/span) : 0`, `mx(x) = strip − 4 − (x1 − x)·kx`. `k = max(stripH / total, 2 / pitch)` (total = `rows.contentHeight + insets.top + insets.bottom`, pitch = H + gapY); `over = max(0, total·k − stripH)`; offset `ms = over · clamp(pixels / max(1, maxScrollExtent), 0, 1)`; every strip y is `my(y) − ms`; a press/drag solves `pixels = (sy − c0·k) / (k − over/range)` with `c0 = top + (viewport − top − bottom)/2` (reduces to today's formula when over = 0), clamped.
- Minimap years (Free; Compact from its own labels): each year boundary heads the section below it — the older year's text top 3 px below the boundary y, right-aligned with the day labels (600 10.5 sans, .08 em, `--text-muted`); the top section's year sticks at strip top 0 as a header with a `--fl-bg-solid` background fading in over 8 px; no header when the whole history lies in this year. Day labels within 16 px of a year label, and above 22 px under a sticky header, are skipped. Each break draws a zigzag (amplitude 2, every 5 px, stroke 1.2 `--text-dim`) across the graph part (x from 58 + 4 to strip) at its centre.
- The shell takes the minimap's card width from the graph (default the token 134 with no frame): the minimap's `Positioned`, `ShellLayout`'s minimap column (card + 24) and `GraphInsets.minimapWidth` use it; the card width animates over 200 ms on `--ease-state` (zero under reduce motion).
- The raster stays one isolate job per key; when the content is taller than the strip it rasters a window of at most 3 strip heights around `ms` (key includes the window top) and re-requests when the visible strip leaves it; dots off the window are not stamped.

**Never:** a "show gap" control; a break or year in Compact's canvas; parsing the prototype's code at runtime; the day pill outside the card (item 6 dropped); changing `zanshin_core`'s engine, grid format or goldens; shortening `RecordedGraphLayout` fixtures (recorded rows stay as recorded).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Long stack | Free, rows …, 40, 1800, … (gap 1760 > 128) | upper row becomes 64; one break (lower 40, upper 64) | — |
| Gap at limit | step exactly 128 | not cut | — |
| Several cuts | two gaps > 128 | savings accumulate; rows stay strictly ordered | — |
| Compact | any | rows unchanged, no breaks | — |
| Missing time | upper row only a root / no timestamps | break kept, label null | — |
| One-year history | all buckets in one year | no canvas year; minimap header only if not this year | — |
| Short history | total·k ≤ stripH | ms = 0, no scrolling, raster covers the strip | — |
| Folded member | rowOf −1 | stays −1 | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_layout.dart` -- `GraphLayout` (accessors; add `breaks` default empty); new `GraphBreak` value.
- `app/lib/src/features/graph/backend_graph_layout.dart` -- production layout over `GraphGridView`; rows at :93, `rows` :44, buckets :161-164 — apply the cut map here (lazy, O(n log n)).
- `app/lib/src/features/graph/recorded_graph_layout.dart` -- fixtures; unchanged.
- `app/lib/src/features/graph/day_axis.dart` -- `graphDayLabel` :21-35 (drop the year), `GraphDayAxis.of` :45-71 (drop days in bands, add years + break bands), `GraphDayAxisPainter` (paint breaks, break labels, years).
- `app/lib/src/features/graph/graph_canvas.dart` -- `_axisFor` :1323, viewport hooks :1510-1535: breaks at the end of `paintEdges` (make it non-null when breaks exist), labels in `paintOverlay`.
- `app/lib/src/features/graph/graph_minimap.dart` -- constants :24-42, `_Mapping` :244-274, `minimapLabels` :168, raster input :297, `_jump` :621, `_bandOf` :749, painters :766-952.
- `app/lib/src/features/graph/minimap_raster.dart` -- `_dots` :155 (skip k outside the raster).
- `app/lib/src/features/shell/{floating_shell.dart :315, :415-423; shell_layout.dart :53-121; graph_insets.dart}` -- minimap width plumbing (`minimapShown` → width).
- `app/lib/src/features/home/home_page.dart :115`, `home/project_graph_host.dart :343`, `graph/graph_view_model.dart :386` -- pass the width listenable (`GraphMinimapSource`).
- `app/lib/l10n/app_en.arb` -- new strings; run `flutter gen-l10n`, commit generated files.
- `app/lib/src/features/graph/graph_stack_popover.dart :149` -- read-only: the stack list already caps at 8 rows (224 px ≤ 420) and scrolls; no change.
- Tests: `app/test/features/graph/{graph_minimap_test.dart (uses minimapStripWidth/minimapSplit :164-348), minimap_raster_test.dart, day_axis*_test.dart, backend_graph_layout*_test.dart}`, `app/test/features/shell/{shell_layout_test.dart, floating_shell_test.dart, graph_insets_test.dart}`.

## Tasks & Acceptance

**Execution:**
- `graph_layout.dart`, new `graph_breaks.dart` -- `GraphBreak {lowerRow, upperRow, t0?, t1?}`; `GraphBreaks.compute(rawRows, unit, timestampOf)` returning the monotone map + breaks; `GraphLayout.breaks` default `const []` -- one reusable pure helper, unit-tested.
- `backend_graph_layout.dart` -- free: map rows, `rows`, bucket rows; expose `breaks` -- the single mapping every view reads.
- `day_axis.dart` -- year-free day label; `graphBreakLabel`; axis drops in-band days, gains `years` (y, year, below, inBand) and `breaks` (top, bottom, label); painter paints strip/labels/years -- canvas witness.
- `graph_canvas.dart` -- wire the break paint and the painter's colours -- under cards, over lines.
- `graph_minimap.dart`, `minimap_raster.dart` -- width rule, density, scroll offset, windowed raster, year sections + sticky header, break zigzags, jump solve; publish the card width from `GraphMinimapSource` (a `ValueListenable<double>`, changes only on a new width) -- items 2–5.
- shell files + `home_page.dart` -- width from the graph, `AnimatedPositioned` 200 ms -- the graph keeps its right inset.
- `app_en.arb` (+ gen-l10n) -- break length plurals and range/label patterns.
- Tests -- breaks compute (matrix rows), backend mapping + invariants still hold (`layout_invariants.dart`), day label without year, axis drops/years/break bands, break label strings, minimap width/kx/k/ms/jump math, years + sticky, raster window, shell width plumbing; update tests pinned to 118/58.
- `DESIGN-SYSTEM-SYNC.md` -- one dated line under #22 that the app now follows it (no DS edit unless the app departs).

**Acceptance Criteria:**
- Given a Free layout whose stack leaves 110 card-free pitches, when the canvas shows it, then the stretch is 1½ pitches card to card with a torn strip and "N years · Mon YYYY – Mon YYYY", and the minimap, day axis and router read the same rows (a node's minimap y equals `my(rows.top + H/2) − ms`).
- Given a layout spanning 12 columns, when the minimap shows, then its card is 16 + 58 + clamp(span·0.04+16, 60, 160) wide, the shell's minimap column and graph right inset follow, and no day label exceeds the 58 px label column.
- Given a history taller than the strip at 2 px per pitch, when the canvas scrolls from top to bottom, then the minimap content scrolls from 0 to `over` in proportion, the band stays inside the strip, and a press at strip y centres the canvas so the band's centre lands at that y.
- Given buckets in 2023 and 2024, then the canvas shows "2024" above the first 2024 day's label, day labels show no year, and the minimap heads the 2023 section with "2023" and sticks the top section's year.

## Spec Change Log

## Review Triage Log

### 2026-11-06 — Review pass
- verdicts: 27 findings — high 0, medium 5, low 17, false 5, maybe-false 0
- findings:
  - `[medium]` `[patch]` (blind) the minimap's day pill names the day below a break for cards just above it (that day was dropped from the axis) — dropped days kept for the minimap's lookup only, at the band top; test added.
  - `[low]` `[reject]` (blind) a dropped day still advances `last` — same as the prototype (`lastY = y` always); the band is ≥ 1½ pitches minus a card (> 22 px), so the next label is never pushed.
  - `[low]` `[patch]` (blind) same-day break reads "Jun 3 – 3" — the range is the single date now; test updated.
  - `[low]` `[reject]` (blind) range shape by differing fields, not by length ("5 days · Jun – Jul 2025") — exactly the DS `GraphBreak.label` rule.
  - `[low]` `[reject]` (blind) `minimapJumpTarget` runs backwards when the band is taller than the strip — needs a strip under viewport·2/pitch (≈ 16 px); the strip is never that short.
  - `[low]` `[patch]` (blind) year labels painted as bare ints — `DateFormat.y(locale)` now.
  - `[low]` `[patch]` (blind) `GraphDayAxis.of` complexity comment wrong (break scan per day) — fixed.
  - `[low]` `[reject]` (blind) x extent computed twice (source cache + `minimapRasterInput`) — both read the same frame's layout and metrics, so they cannot disagree; the extra O(n) scan sits beside an O(n) raster.
  - `[low]` `[reject]` (blind) painters use the final strip width during the 200 ms card resize — cosmetic for 200 ms after a layout change; fixing needs the animated width plumbed into the painters.
  - `[low]` `[reject]` (blind) breaks/years add no semantics — the day axis is paint-only by design since Story 10.2 (labels carry none either); cards keep their own labels.
  - `[false]` `[reject]` (blind) `publish` could notify the shell during a build — the canvas publishes from a post-frame callback (`graph_canvas.dart` minimap block).
  - `[false]` `[reject]` (blind) tracking files not updated — sprint-status and the Auto Run Result are written at finalize; the I1 record lives under Auto Run Result (the loop annotates deferred-work.md).
  - `[false]` `[reject]` (blind) no test for a bucket whose rows straddle a cut — bucket first/last rows are node rows and a cut lies strictly between two consecutive node rows, so a bucket row is never inside one.
  - `[false]` `[reject]` (blind) no raster refresh when the strip width changes at a fixed offset — the raster key includes the width; `_request` runs on every build with the new mapping.
  - `[low]` `[patch]` (edge) t1 < t0 (raw committer times not row-ordered) gives a reversed range — the pair is ordered first.
  - `[low]` `[reject]` (edge) strip wider than the card while it animates / shell not wired — same as the 200 ms finding; the home page wires the width.
  - `[low]` `[patch]` (edge) a fast scroll shows blank strip until the window re-rasters — the window re-centres once the visible strip comes within half a strip of its edge.
  - `[false]` `[reject]` (edge) a stack at the upper row overstates the span end — the stack card sits at its newest member's time and the stretch below it is its hidden members' time, which the DS break names ("the time it skips").
  - `[medium]` `[patch]` (verification) no `GraphCanvas` test paints the break strip — canvas-level test added.
  - `[medium]` `[patch]` (verification) minimap years, sticky header and zigzags never asserted as painted — overlay paint test added.
  - `[medium]` `[patch]` (verification) previous-year card label not pinned (cards keep the year through `withYear`) — `graphCardLabel` test added; the default dropping the year on cards was caught in step 3 and restored.
  - `[low]` `[defer]` (verification) `HomePage` → `FloatingShell` minimap-width wiring not tested — a one-line pass-through; a test needs a full graph model in `home_page_test`.
  - `[medium]` `[patch]` (verification) `cardWidth` reset to 134 on retract untested — test added.
  - `[low]` `[defer]` (intent) break pass in `BackendGraphLayout`, not `zanshin_core`: recorded layouts (Widgetbook) never show a break — the catalogue has no long-history use case.
  - `[low]` `[defer]` (intent) Marionette witness on `dart-intellij-third-party` vs the DS card not done — the app could not be started unattended.
  - `[low]` `[reject]` (intent) no test that a minimap day label is not clipped — labels are right-aligned at x 54 and may run into the strip's 8 px card padding, which the glass does not clip; the longest (`Yesterday`, ≈ 57 px at 10.5 mono) still ends inside the card.
  - `[low]` `[reject]` (intent) no test that expanding a stack removes its break — expanding lays the members out as cards, so the rows hold no stretch > 8 pitches; the rule has no state of its own (covered by the compute tests).

## Design Notes

Shortening in the app layout rather than `zanshin_core`: the engine's output is byte-checked against the spike's goldens and its grid format would need a new section for breaks; every consumer in the app already reads rows only through `GraphLayout`, so one map there keeps canvas, router, axis, gaps and minimap in agreement. The windowed raster keeps a 12-year history's minimap (thousands of strip px) under one texture of ≤ 3 strip heights.

## Verification

**Commands (gate rule of this run — no `cargo make test`):**
- `flutter test` in `app/` (touched graph, shell, home tests at least; full suite preferred) -- expected: pass
- `dart analyze --fatal-infos` in `app/` -- expected: no issues
- `dart format --set-exit-if-changed lib test` in `app/` (width from the analysis_options include chain) -- expected: no change
- `flutter gen-l10n` in `app/` -- generated files committed

**Manual checks:**
- Marionette on the running app with `dart-intellij-third-party` vs the DS card *Long history*, if it can be started unattended; else record as not done.

**Verification notes (2026-11-06, after the review patches):**
- `dart analyze --fatal-infos lib test widgetbook` (app): no issues.
- `dart format --set-exit-if-changed lib test widgetbook` (app): 0 changed.
- `flutter gen-l10n` (app): run, generated files committed.
- `flutter test test/features/graph test/features/shell test/features/home` (app): 1108 passed. A first run had one `app_menu_test` failure ("View › Reload …") that passed alone and on the rerun (flake, unrelated).
- `flutter test` (whole app): 2097 passed, 6 failed — all in `worker_project_repos_test.dart` / `remote_sync_test.dart` with "XDG_CONFIG_HOME is not pinned … run via `cargo make test-app`" (invocation outside the gate's environment, not this change).
- Not run per the gate rule: `cargo make test` / `test-full` / `coverage`. No Rust, FFI or schema changed, so no cargo checks apply.
- Marionette witness: not done (deferred, Low).

## Auto Run Result

Status: done

**Summary.** Free shortens every card-free stretch taller than 8 pitches to 1½ pitches in `BackendGraphLayout`'s row accessors (new `graph_breaks.dart`), so canvas, router B, day axis, gap marks, scroll math and minimap read one mapping; the canvas paints the DS `GraphBreak` (torn strip over the lines, under the cards, span label "6 years · Sep 2019 – May 2025" through the ARB). Axis and minimap day labels lose the year (cards keep it); the canvas labels a year where it begins; the minimap heads year sections and sticks the top year. The minimap card follows the columns (58 + clamp(span·0.04+16, 60, 160) + 16), keeps ≥ 2 px per pitch and scrolls with the canvas (windowed raster ≤ 3 strip heights); the shell's minimap column and the graph's right inset follow its width (200 ms resize). The stack list was already capped (8 rows, 224 px ≤ 420) and scrolls — no change.

**Files.**
- `app/lib/src/features/graph/graph_breaks.dart` (new) — `GraphBreak`, `GraphBreaks.compute` / `map`.
- `app/lib/src/features/graph/graph_layout.dart`, `backend_graph_layout.dart` — `breaks`, shortened rows in Free.
- `app/lib/src/features/graph/day_axis.dart` — year-free day label (`withYear` for cards), `graphBreakLabel`, `graphYearLabel`, axis years / breaks / dropped days, `paintBreaks`, break and year labels.
- `app/lib/src/features/graph/graph_canvas.dart` — break strip in the edge hook.
- `app/lib/src/features/graph/graph_card.dart`, `graph_card_render.dart` — cards keep the year.
- `app/lib/src/features/graph/graph_minimap.dart`, `minimap_raster.dart` — width rule, density, scroll offset, jump solve, windowed raster, years + sticky header, zigzags, `cardWidth`.
- `app/lib/src/features/shell/{floating_shell,shell_controller,shell_layout}.dart`, `app/lib/src/features/home/home_page.dart` — minimap width plumbing.
- `app/lib/l10n/*` — break strings.
- Tests: `graph_breaks_test.dart` (new), `day_axis_test`, `graph_minimap_test`, `minimap_raster_test`, `graph_card_test`, `backend_graph_layout_test`, `graph_harness` (`BrokenLayout`), shell tests.
- `design/DESIGN-SYSTEM-SYNC.md` — dated line under #22.

**Review.** 27 findings: 11 patched (5 medium: day pill above a break, canvas strip test, minimap overlay paint test, previous-year card label test, card width reset test; 6 low: same-day / reversed break range, locale year text, complexity comment, early raster re-centre — counted with their rows), 3 deferred (Low: home-page width wiring test, catalogue long-history use case, Marionette witness — mirrored into deferred-work.md "Surfaced in Story 10.31"), 13 rejected with reasons in the triage log. Before review, a step-3 check caught that the year-free default also stripped the year from card dates; restored with `withYear`.

**Follow-up review:** false (no high patched; the five medium patches are a one-place lookup fix and four tests, each covered by its own test).

**Items.**
- I1 — fixed (commit 88e876f8a4ce4d435aa6d202f0775673988797ca): the empty screens (breaks), the clipped minimap labels (year-free short labels, years of their own) and the squeezed years (minimum density + scrolling minimap) are gone; item 6 (pill outside the card) dropped by the design round.

**Residual risks.** Compact minimap year boundaries sit midway between two labels (the prototype has none in Compact). No test pins the early raster re-centre on a fast scroll. Not checked in the running app.
