---
title: "Story 10.6 — Selection, double-click edit, hover focus path, the commit callout, the @ locator, go-to reveal and pulse, keyboard"
type: 'feature'
created: '2026-10-31'
status: 'done'
baseline_revision: 'e403a5185e7c5f67bde91df5cf9dfe8b1220d3b9'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-10-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      The peek, the affordance tooltips, the focus path and the @ pill were not checked visually (Marionette) in the running catalogue.
    evidence: |-
      The unattended run cannot hold a `flutter run -d macos -t widgetbook/main.dart` session; widget tests and the smoke test cover `graph/peek/open` and `graph/@-pill/directions`.
    location: >-
      app/widgetbook/folders/graph.dart
    severity: low
  - summary: >-
      The peek's IMMUTABLE eyebrow shows no reason yet.
    evidence: |-
      The reason needs one `revsetCounts` call per `immutable_heads()` term in 11.7's term order (epics 2026-10-26 note); `GraphSource` has no such port.
    location: >-
      app/lib/src/features/graph/graph_peek.dart
    severity: low
  - summary: >-
      A double-click edit has no in-flight guard, so a second double-click while `jj edit` runs starts another run and reload.
    evidence: |-
      `GraphViewModel.edit` awaits `run` with no busy flag; no real `GraphActions` exists yet (test fakes only), so whether 10.9's runner serialises jj calls is unsettled. Settle it when 10.9 wires the real port: two overlapping edits must not run concurrently.
    location: >-
      app/lib/src/features/graph/graph_view_model.dart:271
    severity: medium (unverified)
---

<intent-contract>

## Intent

**Problem:** The graph (10.1–10.5) selects on the first click, has no double-click `jj edit`, no hover focus path, no commit callout (peek), no @ locator pill, no go-to pulse, no keyboard focus or Esc, and its card affordances (•••, `+N`) carry no tooltips. Open items I1 (affordance tooltips), I2 (the callout arrow side) and I3 (@'s off-screen direction) name 10.6.

**Approach:** Build epics.md Story 10.6 (`_bmad-output/planning-artifacts/epics.md:9367-9576`, with its 2026-09-28, 2026-09-30, 2026-10-14, 2026-10-16 and 2026-10-26 notes; the latest note wins) on the existing card controller, viewport hooks and view model, as far as its consumers exist today; hand the parts that need a later story's data or UI to that story.

## Boundaries & Constraints

**Always:**
- **Paint-only interaction:** hover, focus path, focus ring, selection, pulse and the dim fade build 0 cards (listeners/repaints, as 10.3 set up); only an opening peek/tooltip builds widgets. No `setState` per hover in the cards; no per-build closures handed to cards.
- **Click / double-click** (item 2; GV:550-558): a primary click on a card body selects only after the double-click window `graphDoubleClickWindow` = 220 ms (the prototype's); a second click inside it cancels the select and, on a mutable card, runs `edit` (`GraphAction('edit', ids: [key])`) through `GraphViewModel` (no confirmation; a no-op when the model has no `GraphActions`); on an immutable card (root included) a double-click does nothing (design question (a)). Affordance clicks never select (as today). VoiceOver's tap selects at once.
- **Select scroll** (2026-10-14 item 2): after a user select, the canvas scrolls only when the card is not wholly inside the unobscured area (the insets), then centres it there (animated). A new `GraphRevealAlignment.covered` does this.
- **Reveal distance** (decision (g)): an animated reveal animates only when both axes' distance is ≤ 3 × the viewport's extent on that axis; otherwise it jumps. Reduce motion jumps (as today).
- **Hover** (item 4, 2026-10-14): hover is the card under the pointer, keyed. Leaving a card clears the hover after `graphHoverIntent` = 140 ms unless the pointer enters another card or the open peek. Hover is cleared and ignored while the shell is calm (`ShellScope.maybeOf(context)?.calm.value.calm`), and while the window is inactive (cleared on resign key).
- **Focus path** (always on; tokens graph.css:10, :65): the focus set = hovered node + all ancestors + all descendants (via `parentEdges`/`childEdges`), a `Uint8List` bitset computed once per hovered key (cached), O(n+E). Cards outside it paint at opacity .4 through `GraphViewport.opacityOf`, edges through `GraphEdgeHighlight(focus:, dim:)`; the dim fades on `ZsMotion.durHover` (the "owner's 160 ms fade"; under reduce motion colour/opacity keep their duration). No dim while inactive or with no hover.
- **Esc** (item 5, 2026-10-14 order, 2026-10-16 scope): handled only by the graph's focus node: an open card menu (`menuOpen`) closes first, then the selection clears; otherwise the key is not handled. No window-level listener.
- **Keyboard** (item 8): one focus node for the graph, a Tab stop (no tab stop per card). While it has focus, `cards.focused` = the selection, else @, else null (the card paints its existing ring, keyboard-only via `zsRingFollowsInput`/highlight mode); gaining focus reveals that card minimally; Enter or Space selects the focused card. The arrow-key map stays NEEDS DESIGN (design question (c)); Go › Parent/Child are 11.13's.
- **@ pill** (item 6, 2026-10-14/16; DS components/actions/AtPill.*, actions.css:47-54): the canvas publishes @'s direction against the unobscured area deflated by 8 px — null while any part of @ meets it (or no @); else up/down when @ lies wholly above/below, otherwise left/right — into `GraphViewModel.workingCopyDirection` (`ValueListenable<GraphDirection?>`). `GraphView.atPill(model)` is the shell's `atPill` slot content: an `AtPill` (36 px = `--control-lg`, pill radius, 11.2 glass fill with a 1 px `--at-chrome-edge`, padding 0 12 0 9, gap 8, the @ badge, "Working copy" in `--type-control`, `ZI.arrowUp` in `--text-dim` rotated toward @ on `durToggle`/glide); in: fade + 10 px rise on `durSlide`/glide, out: fade on `durExit` (rise and turn × `--motion`); the arrow keeps its last direction while fading out. Click/Enter/Space = `model.scrollToWorkingCopy()` (the selection stays). Tooltip "Scroll to the working copy" with shortcut "⇧⌘J". Semantics: button "Working copy, below|above|left|right", a Tab stop only while shown. The shell already positions it, hides it during calm and under a toast.
- **Peek (commit callout)** (item 7; DS components/overlays/PeekCard.*, overlays.css:24-39): opens after `ZsMotion.delayPeek` (450 ms) of hover on a card body; never while the pointer is on an affordance (•••, bookmark control/legend, `+N`), while any card menu is open, while calm, panning, or the window is inactive; closes when the hover clears (so moving into the peek keeps it: the peek counts as hovering its card, and the 140 ms intent bridges the gap). Content: for an immutable non-root card the eyebrow (`HatchSwatch` + IMMUTABLE in `--type-caps`/`--text-muted`; no reason yet), the full subject (wrapped; "no description" when empty; `root()` on the root), meta row (change id as one `Text.rich`: jj's prefix bold + rest up to max(prefix, 8); the author's full name, else the email; the relative date in `--text-faint` mono), and the hint line (`--fs-sm`, `--text-dim`, top border `--border`): mutable "Click: details · Double-click: jj edit", immutable "Click: details", @ "Working copy (@) · Click for details", root none. Material: `ZsMenuMaterial`, width 340, padding 12 14 10, gap 8, no arrow. Placement: 8 px right of the card, flipped to the left when it would cross the unobscured area's right edge, its top at the card's top, shifted up to stay inside the unobscured bottom edge; clamped inside the unobscured area. Fades in (`durHover`), leaves with fade + mirrored drift × `--motion` on `durExitLg`/`easeExit` (`ZsSurfaceTransition`/`ZsPresence` where they fit). The hovered card stays pinned while its peek is open.
- **Affordance tooltips (I1):** in the same layer, after `delayTooltip` of rest over •••: "Actions (or right-click the card)" (GV:320); over the `+N` tag: the folded workspace names, comma-separated; over the bookmark control: 10.3's label (`cardAddBookmark` / `cardBookmarks`). The bubble is zanshin_ui's tooltip bubble, made public as `ZsTooltipBubble`; it sits 8 px above the affordance (below when it would leave the unobscured area), takes no pointer and is not in the semantics tree.
- **Go-to and pulse** (items 11–12, 2026-10-14/16): `GraphViewModel.goTo(key)` selects the key, reveals it centred (animated, with the distance rule) and arms a pulse for it (10.21 calls it). The canvas pulses the card 3 × 650 ms ease-out: an accent-role ring (`ZsColors.accent`) growing 2 → 22 px beyond the card while fading 80 % → 0 %, painted in the viewport's overlay hook at the card rect, the card raised and pinned while it runs; a new goTo restarts it. Under reduce motion (`ZsMotion.motion == 0`) the ring keeps 2 px and only the opacity runs, three times. Paint-only, one ticker.
- Strings in `app/lib/l10n/app_en.arb` (regenerate with `flutter gen-l10n`), no hard-coded UI strings (the hard-coded-strings test).

**Never:** arrow-key navigation, Go › Parent/Child or shortcuts (11.13); the immutable reason's `revsetCounts` call (needs 11.7's term order); the peek's description, commit id, and loading content on hover (10.11/10.12 own the content); stack popover/row callouts (10.17), the gap callout and 10.19's flash; describe/drag/hunk Esc steps (10.8/10.10/10.26 add theirs); the inspector's covered-selection scroll when it opens (10.8); multi-select; a context menu (10.15); the search field (10.21); any Rust/FFI change; golden tests.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Click | one click on a body | selected after 220 ms, not before | — |
| Double-click mutable | two clicks within 220 ms | `edit` with `[key]` once; selection unchanged | no actions port → nothing |
| Double-click immutable | root or immutable card | nothing; selection unchanged | — |
| Covered select | card under the left inset | reveal centres it in the unobscured area | wholly visible → no scroll |
| Far reveal | target 5 viewports away, animate | jumps | — |
| Hover | pointer over a card | others painted at .4, edges dimmed; 0 card builds | — |
| Leave | pointer to empty canvas | hover clears 140 ms later | re-entry within 140 ms keeps it |
| Esc | menu open, selection set | first Esc closes the menu, second clears the selection | graph unfocused → not handled |
| @ below | @ wholly below the unobscured area | direction `down`; pill "Working copy, below" | @ partly visible → null |
| Peek | hover 450 ms on a body | peek with subject, id, author, date, hint | over ••• / menu open / calm → none |
| Tooltip | rest on ••• | "Actions (or right-click the card)" | — |
| Go-to | `goTo(k)` | k selected, centred, one pulse 3 × 650 ms, then idle | k absent → nothing |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:9367-9576` -- Story 10.6 and its notes; witnesses :9383, :9447-9454, :9462, :9563-9576.
- `app/lib/src/features/graph/graph_card.dart:18-67` -- `GraphCardController` (`hovered`, `selected`, `focused`, `menuOpen`, `select`, `openMenu`, `openBookmarks`): add the click/double-click timer, hover intent, `hoverArea`, an `onEdit` hook, `hoverEnabled`; dispose timers.
- `app/lib/src/features/graph/graph_card_render.dart:993-1077` -- `_areaAt`, `handleEvent` (hover tracks `_pointerOnMore/_pointerOnAdd`), `_onTapUp` (selects at once today), `_enter`/`_exit`; `_items` with `GraphCardSlot.moreTag` rects (:25-60, `debugSlots` :447); `_global` for global rects; semantics :1085-1117.
- `app/lib/src/features/graph/graph_canvas.dart:177-221` -- the viewport composition: `ListenableBuilder` over the card controller, `GraphEdgeHighlight(hoveredNode:)`, `pinnedKeys`, `paintOverlay` (day labels). Add focus set + dim animation + `opacityOf`, the pulse overlay, @ direction reporting (listen to `_vertical`/`_horizontal`), a `GraphViewportController` for the covered reveal, and the peek/tooltip layer in a `Stack` above the viewport.
- `app/lib/src/features/graph/graph_viewport_render.dart:31-58,483-534` -- `GraphRevealAlignment` (add `covered`), `_unobscured`, `_revealTarget`, `_revealNow` (distance rule); :538-547 z-order (pinned on top); :596 overlay hook; `GraphViewport` widget params in `graph_viewport.dart:30-130` (`opacityOf`, `pinnedKeys`, `controller`).
- `app/lib/src/features/graph/graph_edges.dart:262-278` -- `GraphEdgeHighlight(focus: Uint8List?, dim: double)` already consumed by the painter.
- `app/lib/src/features/graph/graph_layout.dart:214-236` -- `parentEdges`, `childEdges`, `childEdgeAt`, `parentOf`, `childOf` for the focus set; `workingCopyIndex`, `rootIndex`, `isImmutable`.
- `app/lib/src/features/graph/graph_view_model.dart:237-352` -- `select`, `revealKey`, `scrollToWorkingCopy`, `_revealExplicit` (animate: true), `run`; add `edit(key)`, `goTo(key)` + a pulse listenable, `workingCopyDirection`.
- `app/lib/src/features/graph/graph_view.dart` -- binds model ↔ cards; add the focus node (Tab stop, Esc/Enter/Space), calm and inactive hover clearing, `onEdit` wiring, `atPill(model)` static builder like `staleNotice`.
- `app/lib/src/features/graph/hatch_swatch.dart` -- `HatchSwatch` for the peek eyebrow; `graph_card.dart:172-196` `idParts`, `author`; `graphRelativeDate` :206.
- `app/lib/src/features/shell/floating_shell.dart:73,113,412-418` -- the `atPill` slot (positioned, calm fade, toast precedence); `shell_scope.dart` `maybeOf`; `shell_controller.dart:76` `calm` (`CalmController`, `.value.calm`).
- `packages/zanshin_ui/lib/src/controls/zs_tooltip.dart:221-340` -- private `_Bubble`: make it public `ZsTooltipBubble` (export in `zanshin_ui.dart:42`), `ZsTooltip` keeps using it.
- `packages/zanshin_ui`: `ZsMenuMaterial` (no arrow for the peek), `ZsGlass`, `ZsPresence`, `ZsSurfaceTransition`, `ZsMotion` (`delayPeek`, `delayTooltip`, `durHover`, `durExit`, `durExitLg`, `durSlide`, `durToggle`, `durMove`, `easeGlide`, `easeExit`, `motion`), `ZsColors` (`atChromeEdge`, `accent`, `textDim`, `textFaint`, `textMuted`, `border`), `ZsType`, `ZI.arrowUp`.
- DS: `_bmad-output/implementation-artifacts/design_system/components/overlays/PeekCard.{prompt.md,jsx}`, `overlays.css:24-39`; `components/actions/AtPill.{prompt.md,jsx}`, `actions.css:47-54`; `components/surfaces/surfaces.css:17-18` (the callout arrow — the peek is not a `.zs-callout`).
- `app/lib/l10n/app_en.arb:298-330` -- card strings; add the peek hints, IMMUTABLE eyebrow, the pill's label/tooltip/semantics, the ••• tooltip.
- Tests: `app/test/features/graph/graph_harness.dart` (`handLayout`, `chainLayout`, `surface`), `graph_card_test.dart`, `graph_view_test.dart`, `graph_viewport_test.dart` (`syntheticLayout(100000)` from `widgetbook/graph/synthetic_layout.dart`), `graph_view_model_test.dart`, `test/helpers/scripted_graph_source.dart`; `app/test/widgetbook/catalogue_smoke_test.dart`.
- Catalogue: `app/widgetbook/folders/graph.dart` -- add use cases showing the peek open and the @ pill (all four directions), and the View model use case's pill.
- Open items: `_bmad-output/implementation-artifacts/deferred-work.md` sections "Surfaced in Story 10.3 (bmad-build-auto, 2026-10-30)" (I1), "Surfaced in Story 11.2 (bmad-build-auto, 2026-10-17)" (I2), "Surfaced in Story 10.5 (bmad-build-auto, 2026-10-30)" (I3).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/controls/zs_tooltip.dart`, `packages/zanshin_ui/lib/zanshin_ui.dart` -- `_Bubble` → public `ZsTooltipBubble` (same behaviour), exported.
- `app/lib/src/features/graph/graph_viewport_render.dart`, `graph_viewport.dart` -- `GraphRevealAlignment.covered`; the 3-viewport distance rule in `_revealNow`.
- `app/lib/src/features/graph/graph_card.dart` -- controller: `click(key, {required bool editable})` with the 220 ms window, `onEdit`, hover intent (`enter`, `leave` with 140 ms), `hoverEnabled`, `hoverArea` (`GraphCardHoverArea` body/more/bookmarks/moreTag + global rect), `holdHover` for the peek; timers cancelled in `dispose`.
- `app/lib/src/features/graph/graph_card_render.dart` -- body tap → `controller.click`; hover reports `hoverArea` (incl. the `+N` rect); `_enter`/`_exit` through the controller's intent; semantics tap selects at once.
- `app/lib/src/features/graph/graph_focus.dart` (new) -- `graphFocusSet(GraphLayout, int node) → Uint8List`.
- `app/lib/src/features/graph/graph_canvas.dart` -- focus set cache + dim `AnimationController` → `opacityOf` and `GraphEdgeHighlight`; pinned peek/pulse keys; pulse ticker + overlay paint; @ direction → `onWorkingCopyDirection`; covered reveal on user select; the peek/tooltip layer.
- `app/lib/src/features/graph/graph_peek.dart` (new) -- `GraphPeek` content widget and its placement helper.
- `app/lib/src/features/graph/at_pill.dart` (new) -- `GraphDirection`, `AtPill`.
- `app/lib/src/features/graph/graph_view_model.dart` -- `edit`, `goTo` + `pulse` (`ValueListenable<GraphPulse?>`, key + serial), `workingCopyDirection` + setter used by the view.
- `app/lib/src/features/graph/graph_view.dart` -- focus node, Esc/Enter/Space, calm/inactive hover clearing, `onEdit`, `atPill(model)`.
- `app/lib/l10n/app_en.arb` (+ regenerated `app_localizations*.dart`) -- new strings.
- `app/widgetbook/folders/graph.dart` -- "Peek" (open, mutable/immutable/@/root) and "@ pill" (four directions) use cases; the View model use case passes `GraphView.atPill`.
- Tests: `graph_card_test.dart` (click after 220 ms, double-click edit/immutable, hover intent, hover areas, 0 builds on select), `graph_focus_test.dart` (set = node + ancestors + descendants on a hand layout; 100k timing printed, not gated), `graph_view_test.dart` (Esc order and scope, Tab focus + Enter selects, covered select scroll, calm/inactive clear hover, @ direction + pill semantics, peek opens after 450 ms with the texts and stays closed over •••/menu/calm, eyebrow on immutable non-root only, the ••• tooltip and `+N` names, dim painted as opacity with 0 card builds, goTo pulse runs 3 × 650 ms then idle and restarts, reduce motion keeps spread), `graph_viewport_test.dart` (covered alignment, far animated reveal jumps; a far goTo on 100k builds no card in between), `graph_view_model_test.dart` (edit, goTo), zanshin_ui tooltip test still green; `catalogue_smoke_test.dart` pumps the new use cases.
- `_bmad-output/planning-artifacts/epics.md` -- a dated "Built 2026-10-31" note under Story 10.6: what shipped, what is handed to 10.8/10.10/10.11/10.15/10.17/10.19/10.21/11.7/11.13; `deferred-work.md` -- "Resolved in Story 10.6" sub-bullets on I1–I3.

**Acceptance Criteria:**
- Given a graph, when the user clicks card A then card B (each followed by 220 ms), then B is selected and no card was rebuilt.
- Given a mutable card, when it is double-clicked, then the actions fake received one `edit` for its key and the selection did not change; given the root, nothing is run.
- Given the hovered card X, when the viewport paints, then every card outside X's ancestors/descendants is painted through an opacity layer of .4 and no card was built.
- Given the graph focused with a selection and an open card menu, when Esc is pressed twice, then the menu closes, then the selection clears; given focus elsewhere, Esc leaves the selection.
- Given @ scrolled wholly below the visible area, when the shell builds, then the @ pill shows with semantics "Working copy, below", and tapping it reveals @ without changing the selection.
- Given a hover rest of 450 ms on a mutable card body, then a peek shows its subject, its change id, author and "Click: details · Double-click: jj edit"; given the pointer on •••, then no peek but after the tooltip delay "Actions (or right-click the card)".
- Given `goTo(k)`, then k is selected and centred and its pulse ends after 3 × 650 ms (`pumpAndSettle` completes).
- Given the catalogue, when every Graph use case is pumped, then none throws.

## Spec Change Log

## Review Triage Log

### 2026-10-31 — Review pass
- verdicts: 41 findings — high 0, medium 2, low 26, false 7, maybe-false 0 (blind 16, edge 13, verification-gap 6, intent-alignment 6)
- findings:
  - `[medium]` `[patch]` (blind #1) Esc clears the selection, the focus card falls back to @ and the keyboard-mode minimal reveal scrolls to @. Patched: the focus card keeps the last focused key when the selection clears; the Esc test asserts no scroll.
  - `[medium]` `[patch]` (blind #2, grouped with edge #1 and verification-gap other #2) A pending 220 ms click re-selects after Esc. Patched: `select()` cancels a pending click, `cancelClick()` runs before Esc clears; a test covers click → Esc → no selection.
  - `[low]` `[reject]` (blind #3) A triple-click edits, then selects. Rare gesture; the fix adds a post-edit guard window.
  - `[false]` `[reject]` (blind #4, grouped with edge #4) "@ direction stays set when the canvas unmounts." `GraphView` mounts the canvas once a layout exists and the model never drops its last layout (empty/error/stale keep it), so the canvas only leaves with `GraphView` itself.
  - `[low]` `[reject]` (blind #5) The pill's tooltip names ⇧⌘J before 11.13 binds it. The epic's 2026-10-16 note decides the tooltip names it (Claude's proposal accepted); 11.13 binds it.
  - `[low]` `[reject]` (blind #6, grouped with edge #9) A tooltip flipped below drifts in from above. A 2 px drift direction on a rare flip; the bubble does not know the layout's side before it is laid out.
  - `[low]` `[reject]` (blind #7) The affordance tooltip has no exit fade and skips the warm window. Cosmetic; the fix needs a presence state per tip.
  - `[low]` `[reject]` (blind #8, grouped with edge #2) A refused or failed double-click `edit` is only logged. Showing refusals is 10.9's action runner and 10.23's toast (epics); the ports throw only `ZanshinFfiException` (10.5 triage).
  - `[low]` `[patch]` (blind #9) The model imported `GraphDirection` from a widget file. Patched: the enum moved into graph_view_model.dart.
  - `[low]` `[patch]` (blind #10, grouped with verification-gap #3 and intent #3) `graphPeekPosition` / `graphTooltipPosition` were untested. Patched: graph_peek_test.dart covers the flip, the shift-up, the clamp and the below fallback.
  - `[low]` `[patch]` (blind #11) No test moved the pointer from the card into its peek. Patched: a test holds the hover in the peek and clears it after leaving.
  - `[low]` `[reject]` (blind #12) The peek's drift side repeats the flip test. Both read the same constants in one file; the layout delegate does not hand its result back to the child.
  - `[false]` `[reject]` (blind #13) "`pinnedKeys` re-lays out every dim/pulse frame." The setter compares with `setEquals` (graph_viewport_render.dart:230).
  - `[low]` `[reject]` (blind #14) With no selection and no @ the focused graph shows no ring. Only for a revset without @; the fix needs a fallback node choice the design leaves to (c).
  - `[low]` `[patch]` (blind #15) The peek was in the semantics tree (DS: not announced). Patched: `ExcludeSemantics`.
  - `[low]` `[reject]` (blind #16) The Marionette check is not recorded. Its fix is this spec's notes; recorded under Verification and deferred as before.
  - `[low]` `[patch]` (verification-gap #1) Edge dimming through the canvas was untested. Patched: the hover test checks the edge highlight's focus set and dim.
  - `[low]` `[patch]` (verification-gap #2, grouped with intent #5) Only `down` was tested for @'s direction. Patched: up, left, right and the 8 px margin.
  - `[low]` `[patch]` (verification-gap #3) Grouped with blind #10.
  - `[low]` `[patch]` (verification-gap #4) Space and the keyboard-focus minimal reveal were untested. Patched: both tested.
  - `[low]` `[reject]` (verification-gap other #1) `_shownPeekKey` is never reset, so an empty overlay stack rebuilds on scroll after the first peek. An empty `Stack` with a closed presence; no user-visible cost.
  - `[medium]` `[patch]` (verification-gap other #2) Grouped with blind #2.
  - `[medium]` `[patch]` (edge #1) Grouped with blind #2.
  - `[low]` `[reject]` (edge #2) Grouped with blind #8.
  - `[false]` `[reject]` (edge #3) "goTo after dispose throws." Calling a disposed model is a caller bug that fails loudly, as every other method does.
  - `[false]` `[reject]` (edge #4) Grouped with blind #4.
  - `[low]` `[reject]` (edge #5) A peek timer that fires during a pan is not re-armed until the pointer moves. Inside the shell a pan turns calm on, which clears the hover; outside it rare, and the next move re-arms.
  - `[false]` `[reject]` (edge #6) "A reload that drops the peeked key leaves the peek open forever." The dropped card detaches, its render box clears its hover after the frame (graph_card_render.dart detach), `_syncPeek` then closes the peek; an absent pinned key is ignored by the viewport.
  - `[low]` `[reject]` (edge #7) In an area narrower than card + peek on both sides, the clamped peek covers the card. Only with a very narrow visible area; the pointer is then in the peek, which holds the hover.
  - `[low]` `[reject]` (edge #8) A tooltip flipped below a target near the bottom may leave the area. Needs a visible area shorter than two bubbles; cosmetic.
  - `[low]` `[reject]` (edge #9) Grouped with blind #6.
  - `[low]` `[patch]` (edge #10) Switching directly between affordance tooltips reused the bubble's State (no fade-in). Patched: the bubble is keyed by key and part.
  - `[low]` `[reject]` (edge #11) Re-enabling hover while the pointer rests shows no hover until it moves. The fix needs a re-hit-test of the last pointer position; the next move restores it.
  - `[false]` `[reject]` (edge #12) "A double-click on an immutable card swallows both clicks." That is the spec's I/O row: nothing, selection unchanged (design question (a)).
  - `[low]` `[reject]` (edge #13) `hoverArea.rect` is card-relative while the Tasks text says global. Internal API, documented in code and used consistently by its one consumer.
  - `[false]` `[reject]` (intent #1) "No `## Auto Run Result` with commit hashes." It is written at finalisation, after the commit.
  - `[low]` `[patch]` (intent #2) The `+N` bubble was never rendered in a test. Patched with blind #11's test work: the tooltip test renders it.
  - `[low]` `[patch]` (intent #3) Grouped with blind #10.
  - `[low]` `[reject]` (intent #4) `GraphView`/the pill are not mounted in the app's shell. The real-repo host is 10.12's (epics 10.5 note); 10.6 provides the slot content.
  - `[low]` `[patch]` (intent #5) Grouped with verification-gap #2.
  - `[low]` `[reject]` (intent #6) deferred-work strikes only I1's heading. I2 and I3 stay open for 10.19 and 10.8, so their headings stay unstruck by design.

### 2026-10-31 — Review pass (follow-up)
- verdicts: 28 findings — high 0, medium 4, low 20, false 3, maybe-false 1 (blind 12, edge 9, verification-gap 2, intent-alignment 5)
- findings:
  - `[medium]` `[patch]` (blind #1, grouped with edge #1, verification-gap gap and other #1) On macOS the highlight mode stays `traditional` under a mouse, so a press that gives the graph focus set the focus card to the old selection, glided to it and painted the keyboard ring; tests only tapped with touch. Patched: `GraphView` marks focus that came from a press (`_pointerFocus`) and keeps no focus card until Enter/Space or focus leaves; a macOS-variant mouse-press test asserts no scroll and no focus card (fails without the fix), then Enter brings the focus card back.
  - `[low]` `[reject]` (blind #2) The pill's arrow turns the long way between left and up. Needs a running turn count in a stateless widget; a rare direction pair.
  - `[maybe-false]` `[defer]` (blind #3) `edit()` has no in-flight guard, so a second double-click starts a second `jj edit` while one runs. No real `GraphActions` exists yet (only test fakes); whether the 10.9 runner serialises is unknown. If true medium (unverified).
  - `[low]` `[reject]` (blind #4) The ARB `select` keys follow `GraphDirection`'s Dart names. A rename is unlikely; the fix adds a mapping.
  - `[false]` `[reject]` (blind #5) "Working copy, left/right" reads unevenly. That is the intent's wording ("Working copy, below|above|left|right").
  - `[low]` `[reject]` (blind #6) The peek fades through `Opacity`, not `ZsFade`. Cosmetic, no visible defect named.
  - `[low]` `[reject]` (blind #7) An open peek's relative date does not tick. A peek open across a minute boundary is rare; the card beneath updates.
  - `[low]` `[reject]` (blind #8) `_paintPulse` computes the card rect itself. Matches the cards today (the pulse test checks the ring at the card); harm only on a future `cardRect` change.
  - `[low]` `[reject]` (blind #9) The pan path closing peek/tooltip is untested. Test-only gap on a guard that a pan in the shell also covers through calm.
  - `[low]` `[patch]` (blind #10, grouped with intent #2) No test drove a double-click through `GraphView` to the actions port. Patched: `graph_view_test` double-clicks @ and asserts one `edit r100`, selection unchanged.
  - `[low]` `[reject]` (blind #11) The relayout copy of the 3-viewport jump rule is untested. Test-only gap; the same rule is tested on the reveal path.
  - `[low]` `[reject]` (blind #12) `ZsTooltipBubble` has no zanshin_ui test of its own; the graph host never reports to the warm window. `ZsTooltip`'s tests run the bubble; the warm window is carried (first pass blind #7).
  - `[low]` `[reject]` (edge #2) carried — a refused edit is only logged (first pass blind #8).
  - `[false]` `[reject]` (edge #3) carried — ports throw only `ZanshinFfiException` (first pass blind #8 / 10.5 triage).
  - `[low]` `[reject]` (edge #4) carried — a tooltip flipped below near the bottom (first pass edge #8).
  - `[low]` `[reject]` (edge #5) carried — narrow-area peek clamp (first pass edge #7).
  - `[low]` `[reject]` (edge #6) An unobscured area under 16 px inverts the deflated rect. Only with a near-zero viewport; no user-visible case.
  - `[false]` `[reject]` (edge #7) carried — a double-click on an immutable card does nothing (first pass edge #12).
  - `[low]` `[reject]` (edge #8) carried — `hoverArea.rect` is card-relative (first pass edge #13).
  - `[low]` `[reject]` (edge #9) `GraphDirection` lives in graph_view_model.dart, not at_pill.dart as Tasks says. Moved there by the first pass's patch; the fix would edit this spec.
  - `[medium]` `[patch]` (edge #1) Grouped with blind #1.
  - `[medium]` `[patch]` (verification-gap gap) Grouped with blind #1.
  - `[medium]` `[patch]` (verification-gap other #1) Grouped with blind #1.
  - `[low]` `[reject]` (intent #1) carried — the pill is not mounted in `FloatingShell` (first pass intent #4; 10.12's host).
  - `[low]` `[patch]` (intent #2) Grouped with blind #10.
  - `[low]` `[reject]` (intent #3) No real Tab traversal is sent in tests and the keyboard-only ring is not asserted. The new mouse-press test now asserts no focus card after a press; `requestFocus` is what Tab traversal calls.
  - `[low]` `[reject]` (intent #4) The peek's `ExcludeSemantics` is untested. One wrapper line; test-only gap.
  - `[low]` `[reject]` (intent #5) VoiceOver's tap-selects-at-once has no new test. The path (`_semanticSelect` → `select`) is unchanged by this story.

## Design Notes

- **The peek counts as hovering its card.** Entering the peek holds the card's hover (cancels the 140 ms intent), leaving it starts the intent again, so the card→peek gap needs no extra bridge and the card stays pinned and undimmed while the peek is open. 10.17/10.19 extend the same layer.
- **I2 for 10.6:** the peek has no arrow in the DS (`.zs-peek` in overlays.css:24-39 has no `::before`; only `.zs-callout` in surfaces.css:16-18 has the left arrow), so a flipped peek needs no other arrow side → rejected for 10.6's part; 10.19's gap callout stays open.
- **Focus card:** without the arrow map the roving focus cannot move by itself; it rests on the selection (else @), which 11.13's Go › Parent/Child and 10.21's go-to move.

## Verification

Gate rule for this run: no `cargo make test` / `test-full` / `coverage`.

**Commands:**
- `flutter test test/features/graph test/features/shell test/widgetbook test/l10n` (in `app`, with the env pins of Makefile.toml's test-flutter task) -- expected: all pass.
- `flutter test` in `packages/zanshin_ui` -- expected: all pass.
- `dart analyze --fatal-infos app packages/zanshin_ui` -- expected: no issues.
- `dart format --set-exit-if-changed app packages/zanshin_ui` -- expected: exit 0.

**Manual checks (if no CLI):**
- Best-effort Marionette check of the "Peek" and "@ pill" use cases; record the outcome or why it could not run.

**Verification notes (2026-10-31):**
- `flutter test --reporter=failures-only test/features/graph test/features/shell test/widgetbook test/l10n` (app; JJ_CONFIG, GIT_CONFIG_GLOBAL, JJ_USER/EMAIL/OP_* pinned): 712 passed after implementation, 724 passed after the review patches.
- `flutter test` in `packages/zanshin_ui`: 425 passed (both rounds).
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues (both rounds). `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed.
- `test/features/projects` (not in the list; run as a dependent check): 5–6 `worker_project_repos_test.dart` real-worker tests fail with "XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make" — the test's own environment guard, not this change; the loop's gate runs them under cargo make.
- No Rust, FFI, schema or jj verb changed: no cargo test, clippy, codegen or parity oracle. No full gate, per this run's gate rule.
- Marionette check: not run — the unattended synchronous run cannot hold a `flutter run` catalogue session. Deferred (frontmatter, deferred-work.md "Surfaced in Story 10.6").

**Verification notes (follow-up review, 2026-10-31):**
- `flutter test --reporter=failures-only test/features/graph test/features/shell test/widgetbook test/l10n` (app, same env pins): 726 passed.
- The new macOS mouse-press test fails with `graph_view.dart` stashed to its pre-patch state (proves it witnesses the fix).
- `dart analyze --fatal-infos app packages/zanshin_ui`: no issues. `dart format --set-exit-if-changed app packages/zanshin_ui`: 0 changed.
- zanshin_ui untouched in this pass: its suite not re-run. No Rust/FFI/jj change: no cargo checks. No full gate, per this run's gate rule.

## Auto Run Result

Status: done. Code commit `1d6e63dd7871978bb871b93ba34da03f4ebce2a0` (implementation plus the review patches), plus the follow-up commit carrying this spec, `deferred-work.md`, `epics.md`, `epic-10-context.md` and `sprint-status.yaml`.

**Items from the dispatch:**
- **I1** (no tooltips on ••• and `+N`): **fixed in `1d6e63dd7871978bb871b93ba34da03f4ebce2a0`.** The card reports the part under the pointer (`GraphCardHoverArea`), and `GraphCanvas`'s layer shows zanshin_ui's now public `ZsTooltipBubble` after `--delay-tooltip`: ••• "Actions (or right-click the card)", `+N` the folded workspace names, the bookmark control 10.3's label. deferred-work.md: heading struck, "Resolved in Story 10.6".
- **I2** (the callout arrow side for 10.6's commit callout): **rejected for 10.6's part.** The commit callout is the DS peek (`.zs-peek`, overlays.css:24-39), which draws no arrow — only `.zs-callout` (surfaces.css:16-18) has one — so the peek's flip to the card's left needs no other arrow side; `GraphPeek` uses `ZsMenuMaterial` without an arrow. 10.19's gap callout stays open (deferred-work.md sub-bullet).
- **I3** (@'s off-screen direction for the pill, 10.6's part): **fixed in `1d6e63dd7871978bb871b93ba34da03f4ebce2a0`.** `GraphCanvas` publishes @'s direction against the unobscured area deflated by 8 px (up/down first, then left/right) into `GraphViewModel.workingCopyDirection`; `GraphView.atPill(model)` is the shell slot's pill. 10.8's inspector scroll stays open (deferred-work.md sub-bullet).

**Summary.** Epics Story 10.6 as far as its consumers exist: click selects after the 220 ms double-click window; a double-click on a mutable card runs `edit` through `GraphViewModel.edit` (immutable and root: nothing); a user select centres a covered card (`GraphRevealAlignment.covered`); animated reveals jump beyond 3 viewports; hover with a 140 ms intent, off while calm or inactive; the always-on focus path (`graphFocusSet`, cached bitset; cards at .4 by opacity layers, edges dimmed; 0 card builds; ~3 ms from the root at 100k); Esc (menu, then selection; pending click cancelled) on the graph's one Tab stop, Enter/Space select the focus card (selection, else the last focus card, else @); the @ pill; the commit peek (IMMUTABLE eyebrow, subject, jj's prefix-bold id, author, date, hint; hoverable; flips inside the unobscured area; not in semantics); `goTo` with the 3 × 650 ms accent pulse (spread held under reduce motion). Catalogue: `graph/peek/open`, `graph/@-pill/directions`, the pill in the View model use case.

**Files:**
- `app/lib/src/features/graph/graph_card.dart`, `graph_card_render.dart`: click/double-click, hover intent, hover areas, `cancelClick`.
- `app/lib/src/features/graph/graph_canvas.dart`: focus path + dim, peek/tooltip layer, pulse, @ direction, covered/keyboard reveals.
- `app/lib/src/features/graph/graph_view.dart`, `graph_view_model.dart`: focus node, Esc/Enter/Space, hover gate, `edit`, `goTo`/`pulse`, `workingCopyDirection`, `GraphDirection`, `atPill`.
- `app/lib/src/features/graph/graph_viewport_render.dart`: `covered` alignment, 3-viewport rule, controller accessors.
- `app/lib/src/features/graph/at_pill.dart`, `graph_peek.dart`, `graph_focus.dart` (new).
- `packages/zanshin_ui/lib/src/controls/zs_tooltip.dart`, `zanshin_ui.dart`: `ZsTooltipBubble` public.
- `app/lib/l10n/app_en.arb` + generated localisations; `app/widgetbook/folders/graph.dart`.
- Tests: `graph_focus_test.dart`, `graph_peek_test.dart` (new); `graph_card_test.dart`, `graph_view_test.dart`, `graph_view_model_test.dart`, `graph_viewport_test.dart`, `graph_anchor_test.dart`, `catalogue_smoke_test.dart`.
- Docs: `epics.md` ("Built 2026-10-31" note under 10.6), `deferred-work.md` (I1–I3 notes, new "Surfaced in Story 10.6" section), `sprint-status.yaml`, `epic-10-context.md` (recompiled).

**Review.** 41 findings: 0 high, 2 medium, 26 low, 7 false.
- Patched (2 medium, 10 low entries): a pending click re-selecting after Esc; Esc scrolling to @ via the focus fallback; `GraphDirection` moved out of the widget file; the peek excluded from semantics; tooltip bubbles keyed per affordance; tests for the placement helpers, all four @ directions and the 8 px margin, edge dimming through the canvas, Space and the keyboard-focus reveal, the card → peek pointer path and the `+N` bubble.
- Deferred (2, low, mirrored to deferred-work.md): the Marionette check; the immutable reason (11.7's term order + a `revsetCounts` port).
- Rejected, each with its reason in the Review Triage Log: triple-click, the ⇧⌘J tooltip before 11.13, a flipped tooltip's drift side, no exit fade/warm window for tips, silent refused edit (10.9/10.23), the drift side duplicate, no ring without selection and @, the peek overlay not unmounting, pan-time peek re-arm, narrow-area clamp, tooltip bottom overflow, hover re-enable without a move, the card-relative rect, the shell not mounting the graph (10.12), the struck-heading convention, and 7 false.
- Follow-up review recommended: **true** — first pass with two medium entries patched (Esc vs the pending click; Esc vs the focus fallback). The unverified risk: the keyboard/Esc/focus interplay (focus card fallback, `cancelClick`, keyboard-mode reveals) has been witnessed only by the tests written alongside the patches.

**Residual risks:**
- Nobody has looked at the peek, the tooltips, the dimming or the pill on screen (deferred Marionette check).
- `GraphView` and the pill are not mounted in the app yet (10.12's host), so the behaviour is proven on fakes and widget tests only.
- The roving focus cannot move by keyboard until 11.13 binds Go › Parent/Child (arrow map still design question (c)).

### Follow-up review pass (2026-10-31)

**Summary.** A follow-up review of the shipped 10.6 diff found one real defect: on macOS a mouse press that gives the graph focus showed the keyboard ring on the old selection and glided to it (the highlight mode stays `traditional` under a mouse, so the canvas's keyboard-only guard never held). `GraphView` now tracks focus that came from a press and keeps no focus card until Enter/Space or until focus leaves.

**Files:**
- `app/lib/src/features/graph/graph_view.dart`: `_pointerFocus`; the press sets it, `_focusChanged` keeps no focus card while it holds, Enter/Space clear it.
- `app/test/features/graph/graph_view_test.dart`: macOS mouse-press test (no scroll, no focus card, Enter restores it); double-click through `GraphView` runs `edit` on the actions port; `create(actions:)` + `_Actions` fake.

**Review.** 28 findings: 0 high, 4 medium, 20 low, 3 false, 1 maybe-false.
- Patched: 1 medium entry (the press-focus ring/scroll; 4 members), 1 low entry (double-click through the view untested).
- Deferred (1, mirrored to deferred-work.md): no in-flight guard on a double-click edit (medium, unverified; settles with 10.9's real port).
- Rejected, each with its reason in the triage log: the pill arrow's long turn, ARB keys tied to enum names, the peek's `Opacity` fade, the frozen peek date, the pulse's own rect math, the untested pan path and relayout jump copy, `ZsTooltipBubble`'s own tests, a sub-16 px area, the `GraphDirection` file in Tasks, no real Tab traversal, the peek's `ExcludeSemantics` test, the VoiceOver tap; seven carried from the first pass; three false.
- Follow-up review recommended: **false** — a follow-up pass that patched no high (patched by verdict: 1 medium, 1 low).

**Commits:** listed in the run report (the follow-up commit carrying this spec, the code fix and deferred-work.md).

**Residual risks:** unchanged from the first pass (no on-screen check; the graph is not mounted in the app until 10.12).
