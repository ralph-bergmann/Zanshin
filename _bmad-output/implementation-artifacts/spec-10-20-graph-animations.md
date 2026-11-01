---
title: 'Story 10.20 — Graph animations (FLIP): moved cards glide, a born change grows out of its anchor, changed cards flash'
type: 'feature'
created: '2026-11-01'
status: 'done'
baseline_revision: '8cc81ae17bea493e45ec9e4f2d9b95ef95c060ac'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      A dropped change's glide from the drag ghost's rect, and the runner hints of verbs that do not exist yet
      (rebase, insert, duplicate, split, commit), are not built.
    evidence: |-
      The 2026-10-14 note's drop origin depends on 10.10 (drag-and-drop), which is not built; GraphAction has no
      rebase/insert/duplicate/split/commit verbs (graph_ports.dart), so their anchor/flash/born hints have no source.
    location: >-
      app/lib/src/features/graph/graph_view_model.dart (_plan, _succeeded); app/lib/src/features/graph/graph_viewport_render.dart (GraphTransition)
    severity: low
  - summary: >-
      The animations were not checked in the running app or the Widgetbook catalogue (Marionette / by eye).
    evidence: |-
      Unattended run: only widget and unit tests (graph_transition_test.dart, graph_view_model_test.dart,
      graph_view_test.dart) witness the timings; the visual check of Graph / Viewport / Operation and a real
      operation in the app is open.
    location: >-
      app/widgetbook/folders/graph.dart (Viewport / Operation)
    severity: low
  - summary: >-
      A same-op reload landing inside the 720 ms transition ends it at once: the glide and edge fade snap to their
      end and a covered born card is never revealed.
    evidence: |-
      The own verb's OpHeadsChangedEvent (50 ms debouncer) requests a second reload; it lands with the same op id, so
      _land builds no transition, the canvas ends the running one and drops _bornReveal, and the model already took
      the born key out of reveal. Unverified: whether that event usually lands after the verb's own reload (then
      nearly every own verb snaps) or before it (the queued request absorbs it). Settle by logging in the running app
      when that reload lands relative to the transition.
    location: >-
      app/lib/src/features/graph/graph_canvas.dart:334-341; app/lib/src/features/graph/graph_view_model.dart:890-894, 1067-1070
    severity: high (unverified)
---

<intent-contract>

## Intent

**Problem:** After every operation the graph swaps its picture in one frame: the anchor keeps the viewport still, but the user has to find what moved, what was born and what changed (epics.md Story 10.20, the binding text is its 2026-10-14 FLIP note as amended on 2026-10-16 and 2026-10-26; the older items 1–3 and their witnesses are superseded).

**Approach:** The view model marks a landed layout that carries a new operation (its `operationId` differs from the shown layout's, and no revset/mode/lane-order switch asked for it) as a `GraphTransition` {from, to, anchor, born, flash}. The canvas runs one ticker per transition; the viewport, paint-only, glides kept cards from their old screen rect, grows the born card out of the anchor's old rect, fades other new cards, keeps cards gliding out laid out until they land; the canvas hides and fades back the edge layer, draws the born card's edges in, flashes the flash keys through 10.19's flash, and reveals an off-screen born card after the glide.

## Boundaries & Constraints

**Always:**
- Trigger = a landed layout whose `operationId` differs from the previous layout's (both non-null) and that no `setRevset`/`setMode`/`setLaneOrder` switch requested (`_recentre`). Covers Zanshin's verbs, external `jj` (`OpHeadsChangedEvent`), undo/redo/op restore. A stack toggle, `configChanged`, `reload` without a new op, card-size and Detailed switches never animate (same op id or no request).
- Identity = node key (`layout.keyOf`, folded member → its stack via `placeOfKey`). A describe (same keys, same rects) moves nothing.
- Values (ZsMotion tokens, never literals for tokened values): glide `durFlip` 460 on `easeGlide`; birth `durBirth` 540 from scale .94, opacity 0→1 reached at 30 % of the birth, growing from the anchor's OLD rect; other new cards fade 240 ms after 220 ms; removed cards vanish; edge layer hidden for `durFlip`, fades back over `durSlide` on `easeState`; born change's edges draw in from the parent end over 520 ms after 140 ms; flash = existing 10.19 painter (`durFlash` 2400, `accentLiveLine`/`accentLiveRing`).
- Anchor: the anchor card (runner hint, else the viewport's existing anchor rule) does not move on screen — glide deltas are screen-space: (old rect − old scroll) − (new rect − new scroll).
- Only cards laid out (viewport + cache) animate; a card visible before whose new rect is out of the window stays laid out until the transition ends. A new transition finishes the running one (its end state is the start).
- Reduce motion (`ZsMotion.reduced`: `durFlip` 0, `motion` 0): moved cards jump, the born card fades over `durBirth` without growth, other new cards still fade, the edge layer still fades back, the born edges don't draw in (they arrive with the layer), the flash fades at a held spread.
- Paint-only: transition ticks rebuild no card (the delegate rebuilds only on a new layout, once). Hit testing follows the glide offset.
- Hover callouts (peek) wait until the transition ends; scrolling and panning continue.
- The born card's covered reveal fires after the glide (at `durFlip`), not with the layout.

**Never:**
- No animated revset/layout/card-size/Detailed switches; no stack-toggle animation beyond 10.17's fade; no animated scrolling beyond 10.6's reveal rules.
- No new jj verbs or runner hints for verbs that do not exist yet (rebase, insert, duplicate, split, commit, drop origin — 10.10/10.25 add them with their hints).
- No 1.5 s cap and no 30-card limit: dropped as moot by the 2026-10-14 note (durations fixed, at most 720 ms + the 2.4 s flash).
- No golden tests; no editing `design/`/`design_system/`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Rebase-like reload | op A→B, kept keys change rows | kept cards glide 460 ms, anchor still, edges hidden then fade | — |
| `jj new` | op A→B, born key, anchor = parent | born grows from the parent's old rect (540 ms), its edges draw in after 140 ms | anchor absent in old layout → born fades like a new card |
| Abandon | key gone | it vanishes, the rest glide | — |
| Undo / external | no outcome / no anchor | glide with the viewport's own anchor | — |
| Describe | same keys and rects | nothing moves (zero deltas) | — |
| Revset / mode switch | `_recentre` | no transition | — |
| Second op mid-transition | new transition | the first ends at once, the second starts from the landed state | — |
| Reduce motion | `ZsMotion.reduced` | jumps; born fades without growth; edges fade back | — |
| Born off-screen | born outside unobscured area | revealed (covered, animated) after `durFlip` | — |

</intent-contract>

## Code Map

- `app/lib/src/features/graph/graph_viewport_render.dart` -- `RenderGraphViewport`: `layoutChildSequence` (:415, anchor `_applyAnchor` :492 before extents, nodes laid out :456, pinned loop :461 — reuse for glide-out keys), `_layoutNode` :475, `cardRect` :390, paint `_paintContents` :643 (opacity via `pushOpacity`), `paintOrder` :616 (filters opacity 0), hit test :674 (`addWithPaintOffset` — add the glide shift). Add the transition: snapshot of the last pass (layout, vertical, metrics, insets, scroll, visible keys) at the end of every layout; on a new transition compute per-key screen deltas, born delta/scale, arriving keys, glide-out keys; `transitionElapsed` setter → `markNeedsPaint` only.
- `app/lib/src/features/graph/graph_viewport.dart` -- widget plumbing (`GraphViewport` params, `_GraphViewportWidget` create/update); export the new types.
- `app/lib/src/features/graph/graph_child_delegate.dart` -- `shouldRebuild` only on `layout.version` (:47) — transition ticks keep the same layout, so no change needed; witness it.
- `app/lib/src/features/graph/graph_edges.dart` -- `GraphEdgePainter.paint` (:563) groups edges; `_addStroke` (:521) already uses `computeMetrics`/`extractPath`; add `only`/`except` edge sets and a `drawn` fraction (parent end first).
- `app/lib/src/features/graph/graph_canvas.dart` -- `_GraphCanvasState` (TickerProviderStateMixin; flash pattern `_flash` :174, `_flashChanged` :779, `_paintFlash` :798); viewport build in the `ListenableBuilder` (:1061–1130): add the transition controller to the merge, pass transition + elapsed, wrap `paintEdges` (layer alpha + born edges), reveal the born after `durFlip`, peek waits in `_openPeek` (:461). Motion read in `didChangeDependencies` (:258).
- `app/lib/src/features/graph/graph_view_model.dart` -- `_land` (:989) overwrites `_layout`; `_recentre` (:226) marks switches; `_execute`/`_succeeded` (:690–830) publish `GraphOutcome` before `_requestLayout`; `_explicit` born reveal (:806) must yield to the transition's after-glide reveal; `_flash`/`GraphFlash` (:132) feeds the flash painter. Add `GraphTransition? get transition`, a pending outcome consumed by the first new-op land.
- `app/lib/src/features/graph/graph_ports.dart` -- `GraphOutcome` (:649: `anchor`, `flash`, `born`); doc already names 10.20.
- `app/lib/src/features/graph/graph_view.dart` -- passes model state into `GraphCanvas` (:333); add `transition: model.transition`.
- `packages/zanshin_ui/lib/src/design/zs_motion.dart` -- tokens `durFlip`, `durBirth`, `durFlash`, `durSlide`, `easeGlide`, `easeState`, `motion` (full/reduced); read-only.
- `app/test/features/graph/graph_harness.dart` -- `GraphHarness`, `pumpGraph`, `chainLayout`, `handLayout(operationId:)`, `CardLog` build counter, `TestCard` colour = node; extend the harness with a transition input.
- `app/test/features/graph/graph_viewport_test.dart`, `graph_anchor_test.dart`, `graph_view_model_test.dart` (fake `_Actions` :1346, outcome tests :631–778), `graph_edges_test.dart` -- where the new witnesses go (or a new `graph_transition_test.dart`).
- `app/widgetbook/folders/graph.dart` -- Graph folder ("Viewport" use cases :77–146, `_GraphDemo` with `GraphCanvas` :366, `recordedLayout` :247, `_fixture`); `app/widgetbook/catalogue.dart:150` has `TimeDilationAddon`. `app/widgetbook/graph/synthetic_layout.dart` -- keys `n<id>` stable, `syntheticLayout(n+1)` = `syntheticLayout(n)` + one newest node.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/graph/graph_viewport_render.dart` -- add `GraphTransition` (immutable: `from`, `to`, `anchor`, `born`, `flash`), viewport `transition` + `transitionElapsed`, the last-pass snapshot, delta/born/arriving/glide-out computation in `layoutChildSequence` after the anchor and extents, per-card shift/scale/alpha in paint and shift in hit test; constants for the 220/240 fade and .94/30 % birth -- the FLIP core, paint-only.
- `app/lib/src/features/graph/graph_viewport.dart` -- plumb and export -- widget surface.
- `app/lib/src/features/graph/graph_edges.dart` -- `paint(..., only, except, drawn)` -- born edges draw in, layer split.
- `app/lib/src/features/graph/graph_canvas.dart` -- `transition` param, transition controller (duration = longest part), edge-layer alpha + born draw-in, after-glide born reveal, peek waits -- canvas orchestration.
- `app/lib/src/features/graph/graph_view_model.dart` -- build `GraphTransition` in `_land` (trigger rule above), consume the pending outcome (anchor, born, flash), flash via `_flash`, born reveal deferred to the transition -- runner contract to the view.
- `app/lib/src/features/graph/graph_view.dart` -- pass `model.transition`.
- `app/test/features/graph/graph_transition_test.dart` (+ harness) -- viewport/canvas witnesses: glide 460 ms with the anchor still, born grows from the anchor's old rect, new card fade, vanish, glide-out stays laid out, describe moves nothing, second transition finishes the first, reduce motion, hit test follows the shift, 0 card builds during the ticks, edge layer hidden then fading, born edges partial, large synthetic pair (10k → 10k+1) builds only window cards and settles within the fixed duration.
- `app/test/features/graph/graph_view_model_test.dart` -- trigger set: own verb (anchor/born/flash from the outcome), external op event, undo, no transition for revset/mode switch, stack toggle, same-op reload; born reveal not in `reveal` when a transition carries it.
- `app/test/features/graph/graph_edges_test.dart` -- `drawn` fraction and `only`/`except`.
- `app/widgetbook/folders/graph.dart` -- "Viewport / Operation" use case: a recording pair (design-default ⇄ design-all, design-cli-default ⇄ design-all) and the synthetic pair, a "Run operation" toggle that swaps them with a `GraphTransition` (born = a key new in the target with an anchor parent), knobs for the pair and born on/off; slow motion through the existing TimeDilation addon -- I1's demo host.

**Acceptance Criteria:**
- Given a shown layout and a new layout with another op id from a verb, when it lands, then kept cards whose rect moved paint at their old screen rect and reach the new one after 460 ms on `easeGlide`, and the anchor card's screen rect never changes.
- Given a `jj new` outcome with an anchor, when the layout lands, then the born card starts centred on the anchor's old rect at scale .94 and opacity 0, is opaque at 162 ms and at rest at 540 ms; its edges paint partially from 140 ms and fully at 660 ms while the other edges are hidden until 460 ms and fade back by 720 ms.
- Given a flash key in the outcome, when the layout lands, then 10.19's ring paints on it for 2.4 s.
- Given any transition, when its ticker runs, then no card builds (CardLog unchanged after the landing frame).
- Given reduced motion, when a transition runs, then moved cards stand at their new rect in the first frame, the born card is at its own rect fading over 540 ms, and the edge layer fades in over 260 ms.
- Given the Widgetbook Graph folder, when "Viewport / Operation" runs an operation with TimeDilation ×5, then the glide, birth, fade and edge timings play slowed (manual check, Ralph).

## Spec Change Log

## Review Triage Log

### 2026-11-01 — Review pass
- verdicts: 31 findings — high 0, medium 7, low 15, false 3, maybe-false 6
- findings:
  - (verification-gap) `[low]` `[patch]` GraphView never tested to hand `model.transition` to the canvas — added a `graph_view_test.dart` case: a moving new op lands, the viewport's transition is the model's instance and the moved card has a running effect.
  - (verification-gap) `[low]` `[patch]` no test for a layout without a transition ending a running one — added a canvas test: edges full at once, waiting peek opens, no later reveal.
  - (verification-gap) `[medium]` `[patch]` a pending born reveal survives a layout change — the Timer is gone; the reveal fires from the transition ticker at `durFlip` only while that transition runs; the no-transition branch clears it and `_bornEdges`.
  - (verification-gap) `[medium]` `[patch]` own-op hints stay pending and attach to a later op — `_land` drops `_landing` on every new-op land; test added.
  - (edge-case) `[medium]` `[patch]` born-reveal timer after a revset/mode switch — same root and fix as the pending-reveal row.
  - (edge-case) `[false]` `[reject]` a new transition without flash leaves the previous flash ringing on moved cards — the flash paints at each key's rect in the current layout, so it rings where the card lands; it is the earlier operation's 2.4 s flash, which blocks nothing by design.
  - (edge-case) `[medium]` `[patch]` `_landing` never consumed under `_recentre` — same root and fix as the hint-leak row.
  - (edge-case) `[maybe-false]` `[reject]` a reload in flight before the verb finished lands its layout with the verb's hints — would need a request started before `run` returned to land after it; its layout lacks the born key, so at worst no birth; if real, low.
  - (edge-case) `[low]` `[reject]` the visibility test of a scaled born card uses its unscaled rect — a few pixels at the window edge for 540 ms; a scaled-rect test adds a branch for no visible effect.
  - (edge-case) `[maybe-false]` `[reject]` a gap's Show in all() or a hidden go-to switch the revset with `_recentre` false, so a concurrent external op could animate across views — needs an external op landing in the same request; if real, low.
  - (blind) `[medium]` `[patch]` every new op (describe, snapshot) hides and re-fades the edges with nothing moving — a transition is built only when something is born or a node's key/col/row (or the count) changed; flash-only ops flash through `GraphFlash`; tests added.
  - (blind) `[medium]` `[patch]` `_landing` leaks into a later op — same root and fix as the hint-leak row.
  - (blind) `[false]` `[reject]` the born reveal is lost when the canvas does not start the transition, and an explicit alignment is ignored — `GraphView` always passes the model's transition with its own layout (`identical(to, layout)` holds; now witnessed by the GraphView test), and the only explicit reveal of a born key is the runner's `covered` one, which the canvas uses.
  - (blind) `[medium]` `[patch]` cancelling a running transition leaves its timer and edge set — same root and fix as the pending-reveal row.
  - (blind) `[low]` `[patch]` the born reveal runs on a wall-clock Timer, out of step under TimeDilation — now driven by the ticker.
  - (blind) `[low]` `[patch]` born edges and born card use different "born" rules — `_bornEdges` now uses the viewport's rule (absent from `from`, anchor resolves in `from`).
  - (blind) `[low]` `[reject]` an operation's flash cuts a running gap flash — both at once needs a gap reveal and an operation within 2.4 s; deciding a merge adds state for a rare overlap.
  - (blind) `[low]` `[patch]` claims without tests (no-transition branch, lane-order switch, recentred `_landing`, explicit born reveal) — tests added for the first three; the fourth is the reveal row's `graph_view_model_test` case (born not in `reveal`).
  - (blind) `[false]` `[reject]` a second transition makes mid-glide cards jump to their landed rects — the story's rule: "a new operation finishes the running transition" (2026-10-14 note, item 3).
  - (blind) `[low]` `[patch]` the Widgetbook doc line exceeds the 120-column wrap — rewrapped.
  - (blind) `[low]` `[patch]` the demo cannot show the flash — "flash" knob added (flashes the first key both layouts show).
  - (intent) `[low]` `[reject]` no knobs for the cap, the count limit or the trigger set (I1) — the 2026-10-14 note dropped the cap and the count as moot (fixed durations); the trigger set is a rule, not a value, and is pinned by the view-model tests; I1 is reported partly done.
  - (intent) `[low]` `[reject]` the Operation demo builds its transition itself, bypassing the view model's trigger set — the demo host is for timing by eye; the trigger set is witnessed in `graph_view_model_test.dart` and now through `GraphView`.
  - (intent) `[low]` `[reject]` the demo's recording pairs are revset views, not operations — they are the only real-data pairs with shared keys; the synthetic pair is the operation-like one; real operations are Ralph's manual check.
  - (intent) `[maybe-false]` `[reject]` no test that `GraphTransition.anchor` equals the viewport's 10.5 anchor in the app — the viewport anchors on `anchorHint` recorded while the verb runs (10.9's tests); settling needs an app-level glide assertion; if real, low.
  - (intent) `[low]` `[reject]` abandon: removal and glide are tested separately, not in one case — the two effects are independent per key in `_syncTransition`.
  - (intent) `[maybe-false]` `[reject]` undo's anchorless glide is witnessed only at the view-model level — the viewport has no undo-specific path (no anchor = the general glide, tested); if real, low.
  - (intent) `[low]` `[patch]` the 2026-10-26 revert witness has no test — added: a revert's transition carries anchor = the reverted change and born = the new change (the viewport's birth-from-anchor is tested).
  - (intent) `[maybe-false]` `[defer]` the drop origin (10.10) and hints of verbs not yet built — depends on 10.10/10.25; deferred.
  - (intent) `[low]` `[defer]` no running-app or Marionette check — unattended run; deferred as a manual check.
  - (intent) `[maybe-false]` `[reject]` the flash's held spread under reduce motion is not re-tested — it is 10.19's unchanged painter (`size = motion == 0 ? 1 : fade`), tested there; if real, low.

### 2026-11-01 — Review pass (follow-up)
- verdicts: 30 findings — high 0, medium 0, low 15, false 8, maybe-false 7
- findings:
  - (verification-gap) `[low]` `[patch]` a gliding-out card's paint/hit visibility (`paintOrder`'s shifted-rect check) is untested — the glide-out test now taps r10's old rect mid-glide and expects the tap; reverting the check to `data.isVisible` fails it (mutation run).
  - (verification-gap) `[low]` `[patch]` the reduce-motion born reveal (post-frame path in `_startTransition`) is untested — added "reduce motion: a covered born card is revealed after its landing frame"; removing the post-frame callback fails it (mutation run).
  - (verification-gap) `[low]` `[reject]` the born card's child edges drawing in are never exercised — cosmetic timing; the parent-edge path shares the mechanism and is pinned; a new fixture with a born child is more than a direct correction.
  - (verification-gap) `[low]` `[reject]` the covered-born reveal test bounds the reveal only from below — a weak bound, not a defect.
  - (blind) `[false]` `[reject]` stale hints after a failed reload attach to a later op — the next new-op layout is the first to show the verb's result, so its anchor, born and flash still describe shown → new.
  - (blind) `[false]` `[reject]` hints go to the first new op, not the verb's op — a layout landing after the verb ran contains the verb's effects, so the hints still apply; the pre-verb in-flight race is the carried 2026-11-01 maybe-false row.
  - (blind) `[low]` `[reject]` cards laid out after the transition's first pass get no effect — effects are computed once per transition; a covered born revealed at 460 ms is 85 % into its birth; recomputing per pass adds state for a near-invisible case.
  - (blind) `[low]` `[reject]` the born card can grow out of an off-screen anchor — verbs run from a visible card, whose anchor the viewport keeps still; an on-screen check in two places adds branches for a rare case.
  - (blind) `[low]` `[reject]` the "does the born card grow" rule is written twice (canvas, viewport) — the two agree today (aligned in the first pass); the harm is conditional on a future one-sided edit.
  - (blind) `[false]` `[reject]` the draw-in fraction is of the clipped stroke for every edge — `_addStroke` clips only dashed edges (`graph_edges.dart:517-519` adds a solid edge's whole path); the `shortcut:` comment names exactly that limit.
  - (blind) `[maybe-false]` `[defer]` the born reveal is dropped when a layout arrives mid-transition — same root as the same-op-reload row below; deferred with it.
  - (blind) `[false]` `[reject]` the two transition end paths clean up differently — `_bornEdges`/`_bornReveal` left after completion are gated by `_moving`/`elapsed`, so nothing paints or reveals from them.
  - (blind) `[low]` `[reject]` redo, undoOperation, restoreOperation untested — all route through `_execute` (`graph_view_model.dart:661-696`), the path the own-verb and undo tests pin.
  - (blind) `[low]` `[reject]` `_moved` ignores edge-only changes — such an op snaps its edges with no card moving; animating it adds an edge comparison for a rare case.
  - (blind) `[low]` `[reject]` the model keeps `transition.from` alive until the next land — one extra layout in memory; clearing it needs a timer.
  - (blind) `[low]` `[reject]` no direct test of `graphTransitionDuration` — exercised by the canvas tests and the 10k test; not a defect.
  - (blind) `[low]` `[reject]` only the first born change grows — today's verbs create one change; the rest fade as arrivals.
  - (edge-case) `[false]` `[reject]` `_landing` survives `_fail` — same refutation as the stale-hints row.
  - (edge-case) `[maybe-false]` `[reject]` a null `operationId` leaves hints pending — would need a layout without an op id after a verb; if real, low.
  - (edge-case) `[maybe-false]` `[defer]` a same-op reload (the watcher's event for the own verb) landing within 720 ms ends the running transition and drops the born reveal — the code path is verified (`graph_canvas.dart:334-341`, `graph_view_model.dart:890-894`, `:1067-1070`); whether the event lands after the verb's reload depends on runtime timing (50 ms debouncer); if true, high; deferred with a logging check in the running app.
  - (edge-case) `[maybe-false]` `[reject]` the viewport's last pass is not `transition.from` (two lands before one layout pass) — needs two layouts landing in one frame; if real, low.
  - (edge-case) `[low]` `[reject]` a second own verb before the first's layout lands overwrites `_landing` — the layout that lands shows both; only the first's flash is lost; queueing outcomes adds state for a rare overlap.
  - (edge-case) `[false]` `[reject]` claim: `_landing` survives failed reloads and attaches to a different later op — same refutation as the stale-hints row.
  - (intent) `[false]` `[reject]` a stack toggle or `configChanged` landing with a different op id would animate — the intent's trigger is the op id; a new op is an operation, whatever request fetched it.
  - (intent) `[maybe-false]` `[reject]` "no card builds" is proven at render level, not through `GraphCanvas` — the canvas rebuilds the viewport widget per tick, but `GraphChildDelegate.shouldRebuild` keys on `layout.version`; if real, low.
  - (intent) `[false]` `[reject]` 140/520/220/240 and .94/.3 are module constants, not tokens — `ZsMotion` has no such tokens; the intent requires tokens only for tokened values.
  - (intent) `[maybe-false]` `[reject]` a child edge's draw direction ("from the parent end") is unverified — needs the edge path's start for a child edge; if real, low.
  - (intent) `[low]` `[reject]` carried: the Widgetbook demo animates revset-like pairs — the only real-data pairs with shared keys; demo only.
  - (intent) `[maybe-false]` `[reject]` carried: external/undo's anchorless glide witnessed only at view-model level — no undo-specific viewport path; if real, low.
  - (intent) `[low]` `[reject]` hit testing is checked only at elapsed 0 — the shift is the same effect paint uses, tested over time; plus the new mid-glide glide-out tap.

## Design Notes

- Why a last-pass snapshot instead of `transition.from`'s geometry: the viewport must glide from what was on screen (old vertical, metrics, insets and scroll), and a running transition is "finished" by taking the landed rects, not the painted ones. `transition.to` must be the layout being laid out; a transition for another layout is ignored.
- "Kept cards build 0 times" is read as: no card builds during the transition's frames. The landing frame rebuilds mounted cards once because `GraphChildDelegate.shouldRebuild` keys on `layout.version` and cards take `layout`/`node` (node indices change per layout) — that is 10.5's existing reload cost, not a transition cost.
- Item I1 (deferred-work): the cap and the count limit are moot (dropped 2026-10-14); the trigger set is pinned by view-model tests; the demo host gets the Operation use case for the by-eye tuning on real data, which stays Ralph's.

## Verification

**Commands (gate rule of this run: no `cargo make test`):**
- `flutter test test/features/graph` (from `app/`) -- expected: all pass
- `dart analyze --fatal-infos app` and `dart format --set-exit-if-changed app` -- expected: clean
- `flutter test` in `app/` (whole app suite) -- expected: all pass

**Manual checks (if no CLI):**
- Ralph: Widgetbook "Graph / Viewport / Operation" with TimeDilation ×5 on real data (by-eye tuning of I1); a Marionette visual check of the running app.

**Verification notes (2026-11-01, gate rule: no `cargo make test`; no Rust, FFI or schema touched, so no cargo/codegen/oracle checks apply):**
- `flutter test test/features/graph` (app/) — 690 passed (before the review patches).
- `dart analyze --fatal-infos .` (app/) — no issues (before and after the patches).
- `dart format --set-exit-if-changed lib test widgetbook` (app/) — 0 changed (before and after).
- `flutter test` (app/, whole suite) with the gate's test environment (`JJ_CONFIG=""`, `GIT_CONFIG_GLOBAL=""`, `JJ_USER/JJ_EMAIL/JJ_OP_*`, `ZANSHIN_LOG_DIR`, `XDG_CONFIG_HOME=target/test-xdg-config`) — 1652 passed before the patches, 1657 after. Without that environment `worker_project_repos_test.dart` refuses ("XDG_CONFIG_HOME is not pinned") by design.
- Matrix audit: every I/O row has a passing test — rebase-like glide, `jj new` birth (+ no-old-anchor fade), abandon vanish, describe, revset/mode/lane-order switch (no transition), second op, reduce motion, born off-screen reveal (`graph_transition_test.dart`, `graph_view_model_test.dart`); undo/external at the view-model level.
- Not run: the Marionette / Widgetbook visual check (deferred, Ralph).

**Verification notes (2026-11-01, follow-up review; gate rule: no `cargo make test`; only `app/test/features/graph/graph_transition_test.dart` changed, no Rust/FFI/schema, so no cargo/codegen/oracle checks apply):**
- `flutter test test/features/graph/graph_transition_test.dart` (app/) — 18 passed.
- Mutation runs: the reduce-motion post-frame reveal removed → the new reduce-motion reveal test fails; `paintOrder`'s visibility reverted to `data.isVisible` → the glide-out test fails at the new tap. Both mutations reverted.
- `flutter test test/features/graph` (app/) — 696 passed.
- `dart analyze --fatal-infos .` (app/) — no issues.
- `dart format --set-exit-if-changed lib test widgetbook` (app/) — 0 changed.
- `flutter test` (app/, whole suite, the gate's test environment as above) — 1658 passed.

## Auto Run Result

Status: done

**Summary.** Story 10.20's FLIP model (epics.md 2026-10-14 note as amended 2026-10-16 / 2026-10-26): after every reload with a new operation in which something moved or was born (Zanshin's verbs, external `jj`, undo/redo/op restore; never a revset/mode/lane-order switch, stack toggle or same-op reload), kept cards glide 460 ms on `--ease-glide` with the anchor still, the born change grows out of the anchor's old rect (540 ms, from .94, opaque at 30 %), other new cards fade in (240 ms after 220 ms), removed cards vanish, cards gliding out stay laid out until they land, the edge layer hides for `--dur-flip` and fades back on `--dur-slide`/`--ease-state` while the born edges draw in (140 ms + 520 ms), the outcome's flash keys ring through 10.19's flash, an off-screen born card is revealed after the glide, peeks wait for the end; reduce motion by property; paint-only (no card builds during the ticks). Commit `6d9b21e613961d9aeda12a6278fb94f582a25094`.

**Files.**
- `app/lib/src/features/graph/graph_viewport_render.dart` — `GraphTransition`, last-pass snapshot, per-node glide/birth/arrival effects in paint, hit test and `applyPaintTransform`, glide-out layout.
- `app/lib/src/features/graph/graph_viewport.dart` — plumbing and exports.
- `app/lib/src/features/graph/graph_edges.dart` — `paint(only, except, drawn)`.
- `app/lib/src/features/graph/graph_canvas.dart` — transition ticker, edge layer alpha, born draw-in, flash, ticker-driven born reveal, peek wait.
- `app/lib/src/features/graph/graph_view_model.dart` — the trigger rule in `_land`, pending own-op hints consumed by the next new-op land, flash-only ops through `GraphFlash`, born reveal handed to the canvas.
- `app/lib/src/features/graph/graph_view.dart` — passes `model.transition`.
- `app/widgetbook/folders/graph.dart` — "Graph / Viewport / Operation" (pairs: design-default ⇄ design-all, design-cli-default ⇄ design-all, synthetic 10k ⇄ 10k+1; knobs run operation, born, flash).
- Tests: `graph_transition_test.dart` (new, 17), `graph_view_model_test.dart`, `graph_view_test.dart`, `graph_edges_test.dart`, `graph_harness.dart`.

**Review.** 31 findings: 14 rows patched (7 medium, 7 low; grouped into 11 fixes), 2 deferred, 15 rejected (reasons in the triage log). Follow-up review recommended: **true** — two or more medium entries were patched; the unverified risk is the reworked trigger (`_moved` rule + flash-only fallback) and the ticker-driven born reveal, witnessed only by widget tests, not in the running app.

**Deferred items:** the drop origin and hints of verbs not built yet (10.10/10.25); the running-app / Marionette check.

**Items.**
- **I1 — partly done.** The 1.5 s cap and the 30-card limit are rejected: the 2026-10-14 design note dropped both as moot (durations are fixed, at most 720 ms plus the 2.4 s flash), so there is nothing to make tunable. The trigger set is implemented and pinned by tests (own verb, external op, undo, revert; no transition for revset/mode/lane-order switches, stack toggles, same-op reloads or ops that move nothing) in commit `6d9b21e613961d9aeda12a6278fb94f582a25094`; a synthetic 10k → 10k+1 test checks that only window cards build and every effect rests within the fixed duration. The demo host has "Graph / Viewport / Operation" for the TimeDilation addon. Left: Ralph's by-eye tuning on real data (manual check).

**Follow-up review (2026-11-01).** 30 findings (high 0, medium 0, low 15, false 8, maybe-false 7): 2 low test gaps patched in `app/test/features/graph/graph_transition_test.dart` (a mid-glide tap on a gliding-out card; the reduce-motion covered-born reveal), each proven by a mutation run; 1 entry deferred (2 rows): a same-op reload — likely the watcher's event for Zanshin's own verb — landing inside the 720 ms ends the running transition and drops the born reveal, high if the timing holds, unverified (mirrored in deferred-work.md); 27 rejected with the reasons in the triage log. Patched: high 0, medium 0, low 2. Follow-up review recommended: **false** — a follow-up pass that patched no high has converged. Verification: see the follow-up verification notes.

**Residual risks.** The deferred same-op-reload snap (above) is the main open risk for the running app. Glide deltas are fixed in screen space when the layout lands, so a user scroll during the 460 ms glide moves the gliding cards with the content; the flash ring sits at the destination while its card glides in; a dashed born edge's draw-in fraction counts only the dashes near the window (`shortcut:` comment in `graph_edges.dart`).
