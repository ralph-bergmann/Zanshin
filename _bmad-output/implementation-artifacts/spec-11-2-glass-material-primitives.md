---
title: 'Story 11.2 — Glass material primitives: islands in regular and strong glass, the menu material, the dialog sheet and scrim, the window fill, the solid fallback'
type: 'feature'
created: '2026-10-17'
status: 'done'
baseline_revision: '8adb7b30d1b97c9722321ad0e889fb7a8280b3cc'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: 'The cost of glass (design question (a)) is not measured: profile-mode frame times over a scrolling 10k graph with the six islands need 10.1''s synthetic recording and 11.3''s host.'
    evidence: 'epics.md Story 11.2 Design status (a) and the witness "In profile mode, frame build and raster times over a scrolling 10k graph with six islands are recorded, not gated"; sprint-status.yaml 10-1-graph-viewport-2d-virtualized and 11-3-floating-overlay-host are backlog, so neither the recording nor the islands'' host exists.'
    location: 'app/lib/src/shared/materials/zs_glass.dart'
    severity: medium
  - summary: 'Fading a glass surface through an Opacity ancestor drops its backdrop blur for the whole fade, and 11.3''s calm scrolling plus the panel, toast and minimap entrances fade glass.'
    evidence: 'Engine reading, not run on a device: Impeller opens an offscreen subpass for an opacity layer that holds a backdrop filter (engine/src/flutter/impeller/display_list/canvas.cc SaveLayer, :1830-1912), and FlipBackdrop reads only that subpass''s texture (render_passes_.back()), which is still empty. ZsSheet avoids it by fading its scrim through the filter''s alpha (this spec, Design Notes).'
    location: 'app/lib/src/shared/materials/zs_glass.dart'
    severity: medium
  - summary: 'The DS drop menu enters on its own keyframe (--dur-pop, scale .94), while the epics'' design update lists it among the command menus (--dur-menu, scale .97); 11.2 follows the epics.'
    evidence: 'DS components/menus/menus.css:40-42 (zs-drop-in) against epics.md Story 11.2 design update, item 3 Entrances ("context, project, drop and text menu ... --dur-menu 110 ... .97"); a decision recorded in the epic wins over the DS (Epic 10 house rule Design-system sync).'
    location: 'app/lib/src/shared/materials/zs_surface_transition.dart'
    severity: low
  - summary: 'The callout arrow exists only where the DS draws it (the left edge, 16 px from the top); a callout that 11.3 flips, or the commit and gap callouts of 10.6 and 10.19, may need another side.'
    evidence: 'DS components/surfaces/surfaces.css:17-18 defines only the left arrow and .no-arrow; flipping and anchoring are 11.3''s (epics.md Story 11.2 non-goals).'
    location: 'app/lib/src/shared/materials/zs_menu_material.dart'
    severity: low
  - summary: >-
      Focus goes nowhere after a sheet when the node that had focus as it opened has unmounted meanwhile, for example a sheet opened from a context-menu row whose menu then finishes its exit.
    evidence: |-
      Unverified (review pass 2026-10-17, edge-case hunter): ZsSheet records FocusManager.instance.primaryFocus in initState (zs_sheet.dart:116) and returns focus only to that node if it is still mounted (_returnFocus). If 11.11's Menu still holds focus in its row when the command opens a ConfirmDialog, that row unmounts after the menu's 120 ms exit and focus is lost on close. Settle it in 11.11: does the Menu return focus to its opener when it starts closing, before the command runs?
    location: >-
      app/lib/src/shared/materials/zs_sheet.dart:116
    severity: medium (unverified)
  - summary: >-
      The glass nesting assertion walks the element tree, so glass mounted through an OverlayPortal under an island (a panel pinned from a rail button) trips it although nothing overlaps.
    evidence: |-
      Unverified (review pass 2026-10-17, blind hunter): zs_glass.dart:79 uses context.findAncestorWidgetOfExactType<ZsGlass>(); an OverlayPortal's overlay child is an element child of the portal, so an island hosting the portal counts as an ancestor. Settle it in 11.3: does any glass surface mount through an OverlayPortal inside an island? If so, check nesting on the render tree instead.
    location: >-
      app/lib/src/shared/materials/zs_glass.dart:79
    severity: medium (unverified)
  - summary: >-
      An open sheet does not stop the window's other shortcuts and menu items, so a command could act on the project window behind an open ConfirmDialog or Push.
    evidence: |-
      Review pass 2026-10-17 (blind hunter): ZsSheet binds only Esc inside its FocusScope; key events bubble from the focused node to the Shortcuts above the sheet, and PlatformMenuBar items act regardless of focus. No window shortcut or menu item exists before 11.13, so nothing is reachable today.
    location: >-
      app/lib/src/shared/materials/zs_sheet.dart
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Every Epic 10/11 surface floats on a handful of DS materials — glass islands, strong glass, one menu material, the modal sheet on its scrim, the window fill — and none exists: 11.1 shipped only the tokens and left the inset highlight, the gradients and the glass filter unpainted. Without one implementation every later story rebuilds them and drifts.

**Approach:** Build each material once in `app/lib/src/shared/materials/` on 11.1's tokens: one shared surface paints the CSS box (fill, 46 px sheen, inset highlight, 1 px border, outer shadows); glass inserts a grouped `BackdropFilter` (blur + the CSS saturate matrix) that disappears under reduce transparency and increased contrast through the tokens; the menu material adds the callout arrow; `ZsSurfaceTransition` plays the DS entrances and exits with reduce motion by property; `ZsSheet` is the scrim (its own backdrop group, a fade through the filter's alpha) plus the 18 px sheet with Esc, busy, focus trap and focus return; `ZsWindowFill` is the opaque window surface.

## Boundaries & Constraints

**Always:**
- epics.md Story 11.2 (:11857-11993) is the requirement; its "Design update 2026-10-16" (:11860-11901) supersedes the older items it names; decisions 16.x (:11529-11618) apply. DS = `_bmad-output/implementation-artifacts/design_system/` (downloaded 2026-10-16, synced through #9). Precedence: epics decisions > DS tokens/CSS > DS prose/cards.
- Every colour, shadow, blur, radius, height, duration and curve is read from 11.1's `ZsColors`/`ZsElevation`/`ZsMetrics`/`ZsMotion` `.of(context)`. Literals only for CSS geometry the DS does not tokenise (keyframe distances/scales, the callout arrow, the 48 px sheet margin, the separator, island paddings); each doc comment cites its `DS <file>:<line>`.
- Reduce transparency and increased contrast act only through the resolved tokens (`ZsElevation` blurs are null, `ZsColors` fills and scrim are the solid/contrast values); the materials read no flag. Reduce motion acts only through `ZsMotion.of`: durations unchanged, every distance and scale step × `motion`.
- Every material shows `SystemMouseCursors.basic`, hit-tests opaque inside its shape (the rounded corners pass through) and is a semantics container.
- Widgets-layer imports only (`flutter/widgets.dart`, rendering, painting, services, `dart:ui`); no Material import. SPDX first line; page width 120; `dart analyze --fatal-infos --fatal-warnings` clean. Mark every default the story leaves open "Claude's proposal" in a doc comment.

**Never:**
- No placement, anchoring, flipping, outside tap, calm scrolling, z-order or the per-window `BackdropGroup` mount (11.3); no window chrome, canvas or vibrancy (11.4); no window of its own, its chrome or header hairline (11.12); no controls, menu/popover/callout/sheet contents, Presence or Widgetbook (11.11); no toast layout (10.23), minimap (10.16) or Push content (11.8).
- No `Opacity`/`FadeTransition` above a `BackdropFilter` (deferred risk 2). No golden tests, no edits under `design/` or `design_system/`, no in-app reduce-transparency switch, no token value change (the DS parity test stays green). No profile-mode measurement (deferred 1).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Glass, default | `ZsIsland(bar)` under a `BackdropGroup` | grouped `BackdropFilter` = compose(saturate 1.4, blur σ 18); `--fl-bg` fill | — |
| No group | glass without a `BackdropGroup` ancestor | still blurs, ungrouped (key null) | — |
| Solid fallback | `reduceTransparency` or `increasedContrast` | no `BackdropFilter`, no clip unless the shape clips; fill = `--fl-bg-solid` value; contrast border with contrast | — |
| Nested glass | a `ZsGlass` below another `ZsGlass` | — | debug assertion (DS Island.prompt.md:13; nested grouped backdrops would overlap) |
| Pill on a short box | toast glass, `--radius-pill` 999, 36 px high | radii clamp to half the shorter side (18), inner radius 17 | — |
| Short sheen | a box under 46 px | the band keeps its 46 px scale (colour at the bottom interpolated) | — |
| Close during entrance | `closing` turns true mid-entrance | exit starts from rest (CSS replaces the animation) | — |
| Reopen during exit | `closing` turns false mid-exit | entrance restarts from its start state | — |
| Disposed mid-exit | surface removed before the exit ends | `onClosed` never fires | — |
| Scrim tap | pointer down/up on the scrim | nothing; nothing beneath receives it | — |
| Esc | sheet open / busy / closing | `onCancel` once / nothing / nothing | — |
| No control in the sheet | sheet content has no focusable node | the sheet's scope holds focus; Tab/Shift+Tab stay | — |
| Opener gone | the node focused before the sheet was disposed | no focus request | no throw |
| Scrim over islands | sheet over grouped islands | scrim in a backdrop group of its own (key ≠ the islands') | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:11857-11993` -- Story 11.2 (read the design update :11860-11901 first: one menu material, two sheets, window fill, reduce motion by property, amended witnesses); `:12833-12908` 11.11 (Presence, Widgetbook, ConfirmDialog content are its); `:7982-8037` Epic 10 house rules (Visuals, Tests: no goldens, Design-system sync).
- `DS components/base.css:7` `.zs-glass`; `:52-63` keyframes (`zs-pop`, `zs-menu-in`, `zs-callout-in`, `zs-dialog-in`, `zs-fade`, `zs-out`, `zs-pop-out`, `zs-dialog-out`); `:2` border-box.
- `DS components/surfaces/surfaces.css:2-6` island shapes (bar 44/`0 4px`/gap 2, panel strong + `overflow:hidden`, rail `5px`/gap 4, separator 1×20 + `0 4px`); `:9` popover (origin top right); `:16-18` callout + arrow; `:26-30` scrim/sheet; `:57-60` exits. `Island.jsx` = `zs-island zs-glass` + shape (bar/rail/panel/free); `Dialog.jsx:9-24` `useSheetFocus`; `Dialog.prompt.md:7-8`.
- `DS components/menus/menus.css:6-7` menu (padding 5, origin top left, `zs-menu-in` `--dur-menu`); `:40-42` drop menu (deferred 3). `DS components/overlays/overlays.css:4` toast (strong fill, regular blur, pill, `--fl-shadow`). `DS ui_kits/desktop/kit.css:147` minimap (strong/strong, `--radius-island`). `DS components/window/window.css:20-26` window fill. `DS tokens/effects.css:17-38`, `tokens/motion.css:14-32`, `tokens/transparency.css:9-10`, `tokens/contrast.css:21-22`; `readme.md:90`, `:145`, `:187`.
- `app/lib/src/shared/design/zs_values.dart:14-138` `ZsShadow`/`ZsShadowStack` (`boxShadows` :119 with the σ converter, `inset` :125 left for 11.2); `:177-200` `ZsLinearGradient` (no shader yet); `:287-314` `ZsGlassFilter` (blur = σ, saturate; null = `none`).
- `app/lib/src/shared/design/zs_elevation.dart:39-70` `resolve` (blurs null when solid), fields `flShadow`/`shadowMenu`/`shadowDialog`/`glassBlur`/`glassBlurStrong`/`scrimBlur`, `of` :195. `zs_colors.dart:798-815` `scrim`/`flBg`/`flBgStrong`/`flBgSolid`/`flBorder`/`flSheen` (`flSheen` night :361-367: unpositioned .045 white → transparent at `px: 46`), `of` :654.
- `zs_metrics.dart:140-143` `of`; radii :413-458 (`radiusPopover` 13, `radiusIsland` 14, `radiusPanel` 16, `radiusDialog` 18, `radiusPill` 999); `chromeH` :335 (= `controlXl` 44). `zs_motion.dart:159` `of` (reduced iff `disableAnimations`); `easeState/Glide/Exit` :162-168, `motion` :177, `durMenu/Pop/Exit/ExitLg/Dialog` :192-207.
- `zs_root.dart:21-60` window root (AnimatedTheme, `MediaQuery.disableAnimations/highContrast`); `zs_appearance.dart:153-161` `ZsAppearance` flags. Test patterns: `app/test/shared/design/zs_root_test.dart:24-37` (`_probe`), `app/test/shared/widgets/zanshin_icon_test.dart:11-22` (host, `paints..something`).
- Flutter SDK (`~/development/sdks/flutter`, main): `packages/flutter/lib/src/widgets/basic.dart:471` `BackdropGroup`, `:682` `BackdropFilter.grouped`, `:518-526` "overlapping filters must not share a key"; `rendering/layer.dart:2307` `BackdropKey`; `widgets/transitions.dart:271` `MatrixTransition`; `dart:ui` `ColorFilter implements ImageFilter`, `ImageFilter.compose(outer:, inner:)` = outer(inner(src)), equality on blur/compose/matrix.
- `_bmad-output/implementation-artifacts/deferred-work.md:1211` -- "Surfaced in Story 11.1" (shape of the mirror section).

## Tasks & Acceptance

**Execution:**
- `app/lib/src/shared/design/zs_values.dart` -- add `ZsGlassFilter.saturateMatrix(double s, {double alpha = 1})` (the CSS matrix, Design Notes) and `toImageFilter({double alpha = 1})` = `ImageFilter.compose(outer: ColorFilter.matrix(saturateMatrix(saturate, alpha: alpha)), inner: ImageFilter.blur(sigmaX: blur, sigmaY: blur))`; add `ZsLinearGradient.resolve(Rect)` (CSS gradient line through the centre at the angle, length |w·sinθ| + |h·cosθ|; stops by percent of the line, px along it, unpositioned spread evenly, first 0 %, last 100 %) returning from/to points at the first and last stop plus colours and normalised stops, and `createShader(Rect)` (clamp) -- the paint inputs 11.1 left open; `resolve` is pure for testing.
- `app/lib/src/shared/materials/zs_surface.dart` -- `ZsSurface` (fill, sheen?, border colour?, `ZsShadowStack` shadow, radius, `ZsGlassFilter? filter`, `clip`, `padding`, `arrow`, child) and its render objects: the CSS box in one `RenderBox` (Design Notes paint order and geometry), the outer shadows after the surface clipped outside it, `ClipRRect` + `BackdropFilter.grouped(filter.toImageFilter())` between them only when `filter` is non-null; arrow cursor, opaque hit test inside the rrect, `Semantics(container: true)` -- the one paint path every material shares.
- `app/lib/src/shared/materials/zs_glass.dart` -- `enum ZsGlassFill {regular, strong}` (`--fl-bg`/`--fl-bg-strong`), `enum ZsGlassBlur {regular, strong}` (`--glass-blur`/`--glass-blur-strong`); `ZsGlass({fill, blur, required radius, clip, padding, child})` with `--fl-sheen`, `--fl-border`, `--fl-shadow` and a debug assert against a `ZsGlass` ancestor; `enum ZsIslandShape {bar, rail, panel, free}` with its DS `gap` (2/4/0/2) and `ZsIsland(shape, child)`: bar = 44 px (`chromeH`) high, padding 0 4, child centred vertically, `radiusIsland`; rail = padding 5, `radiusPanel`; panel = strong fill + strong blur, `radiusPanel`, clipped; free = `radiusIsland`; `ZsIslandSeparator` (leaf `RenderBox`, 1 × 20 `--fl-border` with 4 px margins = 9 × 20). Doc: the toast is `ZsGlass(fill: strong, blur: regular, radius: radiusPill)`, the minimap `ZsGlass(fill: strong, blur: strong, radius: radiusIsland)` -- items 1, 2, 5, 6.
- `app/lib/src/shared/materials/zs_menu_material.dart` -- `ZsMenuMaterial({padding = EdgeInsets.zero, arrow = false, child})`: `--fl-sheen` over `--fl-bg-solid`, `--fl-border`, `--shadow-menu`, `radiusPopover`, no filter; doc lists its users (menus, popover, callout, select/suggestion lists, peek, stack list, gap legend, drop/project/search menus) -- item 3.
- `app/lib/src/shared/materials/zs_surface_transition.dart` -- `enum ZsSurfaceMotion {menu, popover, callout, sheet}` (table in Design Notes) and `ZsSurfaceTransition({motion, closing = false, onClosed, origin, child})`: entrance on mount, exit while `closing`, `onClosed` once when an exit completes, `IgnorePointer` while closing; `FadeTransition` + `MatrixTransition` on one curve per phase; doc: never wrap glass (deferred 2) -- items 3, 4, 7.
- `app/lib/src/shared/materials/zs_sheet.dart` -- `ZsSheet({child, semanticLabel, onCancel, busy = false, closing = false, onClosed, initialFocus, width, height})`: fills its parent; scrim + sheet structure, fade, focus and keys as in Design Notes; sheet = `ZsSurface` (`--fl-sheen` over `--fl-bg-solid`, `--fl-border`, `--shadow-dialog`, `radiusDialog`, clipped) in `ZsSurfaceTransition(sheet)`, centred, `width`/`height` clamped to the parent − 48 per axis -- item 4.
- `app/lib/src/shared/materials/zs_window_fill.dart` -- `ZsWindowFill(child)`: `ZsSurface` with `--fl-sheen` over `--fl-bg-solid`, no border, radius 0, empty shadow, no filter; no entrance -- item 9.
- `app/test/helpers/zs_host.dart` -- host: `Directionality` + `ZsRoot(appearance)` + optional `BackdropGroup` + default `Shortcuts`/`Actions` (Tab traversal) + a centred child.
- `app/test/shared/design/zs_values_test.dart` -- saturate matrix entries for 1.4 and 1.2 against the spec numbers (`closeTo` 1e-9) and the alpha row; `toImageFilter` equals compose(matrix, blur σ) built in the test; `--fl-sheen` resolved for a 100 × 120 and a 100 × 36 rect (from y 0 to y 46, two stops).
- `app/test/shared/materials/zs_glass_test.dart`, `zs_menu_material_test.dart`, `zs_surface_transition_test.dart`, `zs_sheet_test.dart`, `zs_window_fill_test.dart` -- the acceptance criteria below and every I/O-matrix row.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- new section `## Surfaced in Story 11.2 (bmad-build-auto, 2026-10-17)` mirroring this spec's `deferred:` items in the dispatch's shape, in the same commit as the spec.

**Acceptance Criteria:**
- Given night and paper, when `ZsIsland` bar, rail, panel, free and the toast's and minimap's `ZsGlass` are pumped, then each paints (`paints` matcher) its fill (`--fl-bg`; `--fl-bg-strong` for panel, minimap, toast) over the border box, a shader-painted sheen, the highlight path (white .05 / paper .8), a 1 px `--fl-border` DRRect, and the two `--fl-shadow` drops as `BoxShadow`s with σ = blur/2 (night drop: offset (0, 14), blurRadius ≈ 30.31, spread −12) inside an outside-the-shape clip, at radius 14 (bar, free, minimap), 16 (rail, panel) and 18 (the 36 px toast's clamped pill).
- Given islands under one `BackdropGroup`, when pumped, then bar, rail and free each hold a `BackdropFilter` whose filter equals compose(saturate 1.4, blur σ 18), panel and minimap σ 22, the toast σ 18 with the strong fill, and three islands report the same non-null backdrop key.
- Given night and paper, when `ZsMenuMaterial` is pumped with and without `arrow`, then it paints radius 13, the sheen over `--fl-bg-solid`, `--fl-border`, `--shadow-menu`, holds no `BackdropFilter`, and with `arrow` paints the arrow's diamond (tip at x ≈ −7.07, y 22) in `--fl-bg-solid` with its two border edges.
- Given each `ZsSurfaceMotion`, when mounted then set `closing`, then the entrance starts at opacity 0 and its start transform and reaches rest at exactly 110 (menu), 160 (popover), 160 (callout), 220 (sheet) ms and not 1 ms earlier; the exit reaches opacity 0 and its end transform at 120 (menu, popover, callout) and 180 (sheet) ms, and `onClosed` fires once; a `ZsSheet`'s scrim fade completes at 160 ms in and 180 ms out.
- Given `reduceMotion`, when the same runs, then the durations are unchanged, the transform stays identity throughout and the opacity still animates; the scrim still fades over 160 / 180 ms.
- Given `reduceTransparency`, when glass, panel, toast and a sheet are pumped, then the tree holds no `BackdropFilter`, every glass fill equals `--fl-bg-solid` and the scrim is rgba(7,9,20,.62) (paper rgba(58,46,34,.28)); given `increasedContrast` the same with the scrim .7 (paper .36) and the contrast `--fl-border`; when either flag is toggled at runtime and the frame settles, every visible surface switches, in both directions.
- Given an open `ZsSheet`, when the scrim is tapped, then it stays open, `onCancel` is not called and a `GestureDetector` beneath receives nothing; when Esc is pressed, `onCancel` runs once, and not while `busy` or `closing`.
- Given a sheet with `initialFocus`, when it opens, then that node has focus after the first frame; without it, the first control; Tab from the last control reaches the first; Shift+Tab while the sheet's own scope holds focus lands on a control inside; when `closing` turns true, focus returns to the node that had it before the sheet opened.
- Given a sheet over grouped islands, when its entrance has settled, then the scrim's filter equals compose(saturate 1.2, blur σ 12), its backdrop key is non-null and differs from the islands'; while it fades in, the filter's alpha row follows the fade.
- Given `ZsWindowFill`, when pumped (also under `reduceTransparency`), then it paints the sheen over `--fl-bg-solid` across its box with no border, radius 0, no shadow and holds no `BackdropFilter`; with a `ZsSheet` over it the only `BackdropFilter` is the scrim's σ 12.
- Given each material and the scrim above a `MouseRegion(cursor: SystemMouseCursors.grab)`, when the mouse hovers it, then the active cursor is `SystemMouseCursors.basic`.
- Given an open sheet with `semanticLabel` over other content, when the semantics tree is read, then it has a route scope named by the label and nothing beneath the scrim.
- Given the change, when `cargo make test` runs unpiped, then it passes.

## Spec Change Log

## Review Triage Log

### 2026-10-17 — Review pass
- verdicts: 45 findings — high 0, medium 3, low 32, false 8, maybe-false 2
- findings:
  - `[low]` `[patch]` (blind 1) The transition doc puts the search menu on `menu`, but the DS gives `.zs-gs-menu`/`.zs-gs-pop` the popover keyframes with a top-left origin (search.css:41, surfaces.css:57) — patched: the doc sends the search menu and popover to `popover` with `origin: Alignment.topLeft`.
  - `[low]` `[reject]` (blind 2) `ZsMenuMaterial` has no `clip` for the search popover's `overflow:hidden`/`auto` (search.css:43, :84) — no consumer exists before 10.21, which can clip its scrolling list itself or add the flag; the fix adds public surface.
  - `[low]` `[patch]` (blind 3) The @ pill (its own `--at-chrome-edge` border) and the large primary (a gold layer over the glass) cannot be built on `ZsGlass`, while `ZsSurface`'s doc says "nothing else paints a material" — patched: the doc says their stories compose or extend `ZsSurface`; building them stays theirs (item 5 asks only that they turn solid through the tokens).
  - `[low]` `[reject]` (blind 4) The unbounded blur samples content outside the island, where CSS mirrors the edge — a subtle edge difference at σ 18, and a bounded blur gives up the single-pass merge that design question (a) chose grouping for; settle at the cost measurement (deferred 1).
  - `[low]` `[reject]` (blind 5) A group's single capture lets a later island paint over an earlier island's shadow — at the 12 px gap the drop's alpha there is about .05, and the shared capture is what the epics' grouped backdrops (item 6) are.
  - `[low]` `[patch]` (blind 6) Each scrim-fade frame repaints everything up to the nearest repaint boundary above the sheet — patched: the sheet's root sits in a `RepaintBoundary`.
  - `[low]` `[patch]` (blind 7) The filter-alpha fade differs from CSS opacity by a(1−a)·Lα·(blur − backdrop) mid-fade (≈12 % at a = .5) — patched: filter alpha f = a(1 − Lα)/(1 − a·Lα), exact over the scrim; doc and test follow.
  - `[maybe-false]` `[defer]` (blind 8) The nesting assertion walks the element tree, so glass mounted through an `OverlayPortal` under an island trips it — if true medium; settle in 11.3 (does any glass mount through a portal inside an island); deferred, unverified, mirrored.
  - `[low]` `[patch]` (blind 9) A closing menu, popover or callout still takes keys for 120 ms (only `IgnorePointer`) — patched: `ExcludeFocus(excluding: closing)` in `ZsSurfaceTransition`.
  - `[low]` `[patch]` (blind 10) No material sets the CSS `color:var(--text)` of every DS surface, so content in an `OverlayPortal` inherits its anchor's colours — patched: `ZsSurface` merges `--text` into the content's `DefaultTextStyle` and `IconTheme`, with a test.
  - `[low]` `[patch]` (blind 11) The sheen's paint geometry is never tested — grouped with verification-gap 8; patched there.
  - `[low]` `[patch]` (blind 12) `ZsSheet`'s own exit paths (reopen mid-exit, removal mid-exit, once per exit) are untested — patched: three sheet tests.
  - `[low]` `[patch]` (blind 13) The window fill has no increased-contrast test — patched: a contrast case.
  - `[medium]` `[defer]` (blind 14) An open sheet does not stop the window's other shortcuts and menu items — no shortcut or menu item exists before 11.13, so nothing is reachable today; deferred to 11.13, mirrored.
  - `[low]` `[reject]` (blind 15) `createShader` interpolates unpremultiplied while CSS interpolates premultiplied — no token gradient has a transparent-black stop (the sheen fades white to white); converting stops is new code for an undemonstrated input.
  - `[false]` `[reject]` (edge 1) An empty `stops` list makes `resolve` throw — every `ZsLinearGradient` is a token with at least two stops; no path constructs an empty one.
  - `[low]` `[reject]` (edge 2) Glass inside a `ZsSheet` or a `ZsSurfaceTransition` asserts nothing — no DS surface puts glass in a sheet or a menu; the transition's doc forbids wrapping glass; an assert guards an undemonstrated state.
  - `[low]` `[reject]` (edge 3) With a filter, the `ClipRRect` also clips content that overflows the island — no DS island content overflows (rail rings are inside; a bar control's 2 px ring at offset 2 ends on the island's edge, inside its rounded corners); the fix restructures the composition.
  - `[low]` `[reject]` (edge 4) An opaque surface's drops paint over child content that overflows it — no menu-material content overflows (submenus are surfaces of their own; row rings are inside); the fix adds a paint-order branch.
  - `[maybe-false]` `[defer]` (edge 5) Focus is lost on close when the node that had focus at open (a closing menu row) has unmounted — if true medium; settle in 11.11 (does the Menu return focus to its opener when it starts closing); deferred, unverified, mirrored.
  - `[low]` `[reject]` (edge 6) Another modal taking focus in the frame a sheet closes is overridden by the return — sheets never stack (DS readme.md:187); the guard covers an undemonstrated state.
  - `[low]` `[reject]` (edge 7) An `initialFocus` node outside the sheet's scope starts focus beneath the scrim — a caller error with no caller yet; the guard covers an undemonstrated input.
  - `[low]` `[patch]` (edge 8) While closing, `BlockSemantics` still hides the opener that has focus back — patched: `BlockSemantics(blocking: !closing)`, the leaving sheet excluded from semantics, with a test.
  - `[low]` `[patch]` (verification-gap 1) The `ClipRRect` bounding each glass blur is never asserted — patched: the glass paint pattern expects the clamped outer `clipRRect`.
  - `[low]` `[patch]` (verification-gap 2) The non-arrow shadow clip path is unchecked — patched: `surfacePaints` matches the clip path (outside included, centre excluded).
  - `[medium]` `[patch]` (verification-gap 3) The runtime solid/translucent switch test reads widget fields, not what is painted — patched: after each switch a surface's painted fill and border are asserted.
  - `[low]` `[patch]` (verification-gap 4) Only the end points of each curve are pinned — patched: half-phase `closeTo` checks against glide, exit (flipped) and ease-state.
  - `[low]` `[patch]` (verification-gap 5) Nothing pins that no opacity sits above the scrim's `BackdropFilter` — patched: ancestor checks for `FadeTransition` and `Opacity`.
  - `[low]` `[patch]` (verification-gap 6) A closing sheet's focus exclusion and pointer release are unpinned — patched: after `closing` the sheet's control cannot take focus and a scrim tap reaches the detector beneath.
  - `[low]` `[patch]` (verification-gap 7) The bar island's vertical centring is untested — patched: a 100 × 20 child sits at (5, 12).
  - `[low]` `[patch]` (verification-gap 8) The sheen's padding-box clip is unasserted — patched: `surfacePaints` expects the `clipRect` from y 1 before the sheen.
  - `[low]` `[patch]` (verification-gap 9) The sheet's own Esc binding is masked by the test host's default shortcuts — patched: an Esc test on a host without them.
  - `[false]` `[reject]` (intent 1) Runtime switching is tested through `ZsRoot`, not from the system setting — the system → `ZsAppearance` leg is 11.1's (its own deferred entry); 11.2's surface is appearance → materials, which the tests switch live.
  - `[false]` `[reject]` (intent 2) The window-level witnesses run on a composition, not a real window — windows of their own are 11.12's and 10.22's (intent non-goals); the composition is the outermost surface this story owns.
  - `[false]` `[reject]` (intent 3) With a sheet open the project window holds two backdrop groups, not one — sharing the islands' key would be a defect (overlapping filters must not share one, basic.dart:518-526, and the scrim's capture would miss the islands); item 6's own Configurations clause describes the scrim's group; Claude's proposal in code and spec.
  - `[low]` `[reject]` (intent 4) Nothing checks the blur's look or the fade on pixels — the house rule bars golden tests; Ralph's visual check in 11.11's Materials folder is the spec's manual check.
  - `[medium]` `[defer]` (intent 5) The profile measurement is deferred — already deferred at planning (item 1); not added twice.
  - `[low]` `[reject]` (intent 6) The toast and minimap witnesses check the tests' own `ZsGlass` builds — the toast and minimap widgets are 10.23's and 10.16's (intent non-goals); the tests pin the builds `ZsGlass` documents for them.
  - `[false]` `[reject]` (intent 7) Rows of radius 8 and the tooltip exit are not built — menu rows and the tooltip are 11.11's controls (intent non-goal "Controls, and the contents of menus").
  - `[false]` `[reject]` (intent 8) Esc calls `onCancel` rather than closing the sheet — the owner closes it and Presence (11.11) keeps it mounted for the exit, as the DS Dialog's `onClose` does.
  - `[false]` `[reject]` (intent 9) The island takes one child with `gap` metadata and adds a `free` shape — `free` is the DS Island's own (Island.jsx:4); laying out the controls is the consumer's (Claude's proposal, contents are a non-goal).
  - `[low]` `[defer]` (intent 10) The callout arrow is fixed on the left — already deferred at planning (item 4); not added twice.
  - `[low]` `[patch]` (intent 11) The @ pill and the large primary cannot be built on `ZsGlass` — grouped with blind 3; patched there.
  - `[low]` `[defer]` (intent 12) The drop menu follows the epics over the DS keyframe — already deferred at planning (item 3); not added twice.
  - `[false]` `[reject]` (intent 13) "Same commit as the spec" cannot be confirmed — nothing is committed yet; spec, deferred-work.md and code land in one commit at finalize.

## Design Notes

**The CSS box, one paint path** (`ZsSurface`; DS base.css:2,7; CSS Backgrounds 3). Outer rrect = the box at radius r, each corner clamped to half the shorter side; padding box = deflated by the border (1 px; 0 for the window fill), radius max(0, r − 1). Order: (1) fill colour over the outer rrect; (2) sheen shader from the padding-box top 46 px down, over the outer rrect, nothing above the padding-box top; (3) each inset shadow part: padding box minus (padding box moved by (dx, dy), deflated by spread), σ = blur/2 when blur > 0, clipped to the padding box — for `inset 0 1px 0` a 1 px line along the top that thins along the corner arcs (Claude's proposal for "painted as a line"); (4) border DRRect(outer, padding box); (5) callout arrow; (6) child, clipped to the padding box when `clip`. Outer shadow parts (`boxShadows`, σ = blur/2) paint after the surface — so a glass surface's own backdrop never samples its shadow — clipped to outside the outer rrect and the arrow (CSS never paints an outer box-shadow under the box; the glass is translucent). Glass: `ClipRRect(outer)` → `BackdropFilter.grouped` between the shadow painter and the box.

**Callout arrow** (surfaces.css:17, base.css:2). In border-box coordinates a 10 × 10 square at x −5…5, y 17…27, rotated 45° clockwise about (0, 22): `--fl-bg-solid`, no sheen; 1 px `--fl-border` along its left and bottom edges, which after the rotation are the two edges meeting at the tip (−7.07, 22). Painted after the border, which it covers where they overlap.

**Glass filter.** CSS `blur(N)` takes σ = N; `saturate(s)` is the Filter Effects matrix, rows `[.213+.787s, .715−.715s, .072−.072s, 0, 0]`, `[.213−.213s, .715+.285s, .072−.072s, 0, 0]`, `[.213−.213s, .715−.715s, .072+.928s, 0, 0]`, `[0, 0, 0, a, 0]`; blur first, then saturate (`compose(outer: saturate, inner: blur)`).

**Motion** (base.css:53-62, motion.css:14-32; m = `ZsMotion.motion`; one curve per phase, opacity included; exit always starts from rest, entrance always from its start):

| motion | in | out | origin |
|---|---|---|---|
| menu | `durMenu`, glide, scale 1 − .03m | `durExit`, exit, fade | top-left (`origin` overrides, e.g. a flipped submenu) |
| popover | `durPop`, glide, dy −4m, scale 1 − .02m | `durExit`, exit, dy −2m, scale 1 − .01m | top-right |
| callout | `durPop`, glide, dx −4m | `durExit`, exit, fade | — |
| sheet | `durDialog`, glide, dy +8m, scale 1 − .015m | `durExitLg`, exit, dy +4m, scale 1 − .01m | centre |

**ZsSheet structure.** `ClipRect` → `BackdropGroup` of its own → `BackdropFilter.grouped(scrimBlur.toImageFilter(alpha: fade))` (absent when `scrimBlur` is null) → `FadeTransition(fade)` → [`BlockSemantics` + the `--scrim` colour box, opaque hit test, arrow cursor; the centred sheet]. `fade`: 160 ms (`durPop`) on ease-state in, 180 ms (`durExitLg`) on ease-exit out. The alpha in the filter's matrix fades the blur the way CSS opacity does (result = a·blur + (1 − a)·backdrop) without an opacity layer above the filter; the `FadeTransition` inside multiplies the sheet's own fade, as the scrim's CSS opacity does for its child. Its own group (Claude's proposal): the scrim overlaps every island, and filters that overlap must not share a key (BackdropFilter docs) — this also gives a window of its own "a group for the scrim while the sheet shows" (item 6). Keys: a `Shortcuts` {Esc → `DismissIntent`} + `Actions` inside the sheet (works without `WidgetsApp`); `FocusScope` (closed loop) traps Tab; initial focus after the first frame; `closing` → `IgnorePointer` + `ExcludeFocus` and focus back to the opener (Claude's proposal: at the start of the exit rather than the DS's unmount, so no key reaches a leaving sheet), or in `dispose` if it never closed; sheet semantics `scopesRoute`, `namesRoute`, `explicitChildNodes`, label.

**Claude's proposals** (mark in code): the `materials/` folder; the highlight geometry; shadows after the surface; the scrim's own group and filter-alpha fade; focus return at exit start; the island `gap` metadata with a single child (consumers lay out their controls); `ZsGlassFill`/`ZsGlassBlur` as the toast's and minimap's build.

## Verification

**Commands:**
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` (in `app/`) -- expected: clean.
- `flutter test test/shared/materials test/shared/design` (in `app/`) -- expected: all pass.
- `cargo make test` (repo root, unpiped, `PATH` with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset so the coverage step finds `llvm-tools` in `~/.rustup`) -- expected: exit 0, coverage baseline unchanged (Dart is unmeasured).

**Manual checks (if no CLI):**
- Ralph, in 11.11's Materials folder: the glass reads as the DS's over a busy canvas in night and paper, and the scrim's blur fades in rather than popping.

## Auto Run Result

Status: done (2026-10-17). Blocking condition: none.

**Summary.** The DS materials now exist once, in `app/lib/src/shared/materials/`, on 11.1's tokens. `ZsSurface` is the one paint path: the CSS box (fill over the border box, the 46 px `--fl-sheen` from the padding-box top, the inset highlight as the exact `inset 0 1px 0` line, the 1 px border, the callout arrow) in one render box, the outer shadows painted after it and clipped outside its shape, `--text` as the content's colour, the arrow cursor, a hit test inside the rounded shape and a semantics container. Glass (`ZsGlass`, `ZsIsland` bar/rail/panel/free, `ZsIslandSeparator`) adds a `ClipRRect` and a grouped `BackdropFilter` (blur σ + the CSS saturate matrix) that disappears with its clip under reduce transparency and increased contrast through the tokens, keeping the content's state. `ZsMenuMaterial` is the one menu material. `ZsSurfaceTransition` plays the DS entrances and exits (menu, popover, callout, sheet) with reduce motion by property. `ZsSheet` is the scrim (its own backdrop group, σ 12, faded through the filter's alpha so no opacity sits above the filter) plus the 18 px sheet with an inert scrim, Esc/busy, the focus trap, initial focus, focus return and `BlockSemantics`. `ZsWindowFill` is the opaque window surface. `ZsGlassFilter.toImageFilter`/`saturateMatrix` and `ZsLinearGradient.resolve`/`createShader` complete 11.1's value types.

**Files changed** (paths under `app/` unless noted):
- `lib/src/shared/design/zs_values.dart` -- the CSS saturate matrix and glass `ImageFilter`; CSS linear-gradient resolution and shader.
- `lib/src/shared/materials/zs_surface.dart` -- the shared paint path and its render objects.
- `lib/src/shared/materials/zs_glass.dart` -- glass fills/blurs, `ZsGlass`, island shapes, `ZsIsland`, the separator.
- `lib/src/shared/materials/zs_menu_material.dart` -- the menu material with the callout arrow.
- `lib/src/shared/materials/zs_surface_transition.dart` -- entrances and exits.
- `lib/src/shared/materials/zs_sheet.dart` -- scrim and sheet.
- `lib/src/shared/materials/zs_window_fill.dart` -- the window surface.
- `test/helpers/zs_host.dart`, `test/helpers/material_paints.dart` -- test host and paint patterns.
- `test/shared/design/zs_values_test.dart`, `test/shared/materials/{zs_glass,zs_menu_material,zs_surface_transition,zs_sheet,zs_window_fill}_test.dart` -- the witnesses and every I/O-matrix row.
- Tracking: this spec, `_bmad-output/implementation-artifacts/deferred-work.md` ("Surfaced in Story 11.2", 7 items), `_bmad-output/implementation-artifacts/sprint-status.yaml` (11-2 done).

**Review findings.** 45 findings (high 0, medium 3, low 32, false 8, maybe-false 2). Patched (one medium, the rest low): the scrim's filter alpha made exact CSS opacity (f = a(1 − Lα)/(1 − a·Lα)); a `RepaintBoundary` around the sheet; semantics released while a sheet closes; `ExcludeFocus` on closing transitions; the search menu's motion doc; `--text` as every material's content colour; the `ZsSurface` doc on the @ pill and large primary; tests for the glass clip, the outside-only shadow clip, the sheen clip, the painted colours after a runtime switch (medium), the curves at half phase, no opacity above the scrim filter, a closing sheet's focus and pointer release, the bar's centring, Esc without default shortcuts, the sheet's own exit paths, and the window fill under increased contrast. Deferred (new, mirrored): focus return when the opener unmounts (medium, unverified; 11.11), the nesting assertion vs `OverlayPortal` (medium, unverified; 11.3), window shortcuts and menu items behind an open sheet (medium; 11.13); three intent findings were already deferred at planning (items 1, 3, 4). Rejected, with reasons in the triage log: the menu material's clip (10.21), the unbounded blur's edge (settle at the cost measurement), a group's shared capture over a neighbour's shadow (≈ .05 alpha at 12 px), premultiplied gradient stops (no such token), the edge-case guards for undemonstrated states (empty stops, glass in a sheet or fade, overflowing content, stacked modals, an outside `initialFocus`), no pixel checks (no goldens by house rule), the toast/minimap and menu-row surfaces (their stories), and the 8 false findings.

**Follow-up review recommendation:** false — this first pass patched 0 high and 1 medium entry (17 low entry groups); no named unverified risk calls for another pass.

**Verification.**
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` -- clean, before and after the review patches.
- `flutter test test/shared/materials test/shared/design` in `app/` -- 120 tests passed before the patches, 130 after.
- `cargo make test` (repo root, unpiped, `PATH` with the Flutter and cargo SDK bins, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- exit 0 before (1089 s) and after (1080 s) the review patches; coverage held at 99.49 % with extern-coverage OK; `coverage-baseline.txt` unchanged (Dart is unmeasured).
- Matrix audit: every I/O-matrix row has a passing test (glass default/no group/solid/nested/pill in `zs_glass_test`; short sheen in `zs_values_test`; close/reopen/dispose in `zs_surface_transition_test` and `zs_sheet_test`; scrim tap, Esc states, no control, opener gone, scrim group in `zs_sheet_test`).

**Residual risks.**
- Nothing ran on a real Mac: the blur's look, the scrim's alpha fade and the engine reading behind deferred item 2 need Ralph's visual check in 11.11's Materials folder.
- No reachable widget uses the materials before 11.3 and 11.11; the per-window `BackdropGroup` is 11.3's.
- The cost of glass is unmeasured until 10.1 and 11.3 exist (deferred 1).
