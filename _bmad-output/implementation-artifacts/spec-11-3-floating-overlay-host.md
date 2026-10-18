---
title: 'Story 11.3 — Floating overlay host: top-bar grid Place · View · Action, rail with hover previews and pins, pinned-panel host, insets provider, calm scrolling'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_revision: 'c0ff2862e32356341f68d1b23dcbf50fdb935df3'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: 'The calm state machine and the graph insets reach Epic 10 in a shape 10.5''s text does not yet describe: the host counts wheel and trackpad scrolling over the graph layer itself, takes pans, flings and minimap scrolling through a report call, and hands the insets down through an inherited scope.'
    evidence: 'epics.md Story 10.5 items 14-15 (":8907-8920", ":8943-8949") say the view model publishes `calm` and takes `GraphInsets` "as a listenable"; 11.3''s witnesses (epics.md:12076-12080, :12172-12176) need the 30 px / 650 ms machine before 10.5 exists, so this spec builds it in `CalmController` (Design Notes "Calm"). A fling''s ballistic glide after the fingers lift sends no pointer events, so calm can end while the graph still glides.'
    location: 'app/lib/src/features/shell/calm_controller.dart'
    severity: low
  - summary: 'The project window keeps two stand-ins for Story 11.4 until it lands: a WindowDragArea over the bar row and a canvasBase fill under the graph.'
    evidence: 'epics.md Story 11.3 item 1 and Story 11.4 own the drag region and the canvas; without the stand-ins the new home could not be moved (the Yaru page''s WindowDragArea AppBar, zanshin_app.dart:155, goes) and the vibrancy view would show through (MainWindowChrome.swift:90-110).'
    location: 'app/lib/src/features/home/home_page.dart'
    severity: low
  - summary: 'The in-app theme switch disappears with the Yaru test page until Story 11.7 adds Theme to Settings; the app then follows the stored mode, System by default.'
    evidence: 'zanshin_app.dart:161-183 (the SegmentedButton is the only UI caller of ZanshinAppViewModel.setThemeMode); epics.md Story 11.3 item 1 replaces the page; 11.7 owns General › Theme.'
    location: 'app/lib/src/features/app/zanshin_app.dart'
    severity: low
  - summary: 'The pinned panel''s title takes the token --type-panel-title (15/600) while the desktop kit draws 13/600; a design question for the next DS round.'
    evidence: 'DS tokens/typography.css:29 against DS ui_kits/desktop/kit.css:84-86 and the export''s 13 px h3 (app.css:1174-1179); both are DS tokens or CSS, the same tier of precedence.'
    location: 'app/lib/src/features/shell/pinned_panel.dart'
    severity: low
  - summary: 'A rail button loses its hover fill while the pointer is inside its preview, where the kit keeps it (.is-hov).'
    evidence: 'DS ui_kits/desktop/kit.css:66; ZsControlCore._syncHover (packages/zanshin_ui/lib/src/controls/zs_control_core.dart:252) rewrites WidgetState.hovered from the pointer, so no external hovered state survives; the epics list only --fl-hover and --fl-on (epics.md:12107).'
    location: 'packages/zanshin_ui/lib/src/controls/zs_control_core.dart:252'
    severity: low
  - summary: >-
      No Zs menu, popover, select or sheet takes the shell's calm hold by itself, and ZsSelect and ZsPopover expose no open callback, so a slot whose story forgets `ShellScope.of(context).openSurface()` lets calm scrolling fade an open menu.
    evidence: |-
      Review pass 2026-10-18 (blind hunter, intent auditor): the hold is an explicit call (`ShellController.openSurface`, named in `shell_scope.dart` and in `FloatingShell`'s "What a slot must bring"); `ZsMenuAnchor` has onOpen/onClose (packages/zanshin_ui/lib/src/controls/zs_menu.dart:186-190), `ZsPopover` only onClosed, `ZsSelect` none (zs_select.dart). An overlay child inherits its island's `ZsFade`, so an unheld menu fades with the island while it stays interactive.
    location: >-
      app/lib/src/features/shell/shell_scope.dart
    severity: medium
  - summary: >-
      A resize edge removed during its own drag never reports the drag's end, so the shell would keep its calm hold and its edge-drag flag until the window closes.
    evidence: |-
      Unverified (review pass 2026-10-18, edge-case hunter): `ZsResizeEdge` calls onDragEnd only from the recognizer's end and cancel, and a recognizer disposed with its widget fires neither. In 11.3 nothing removes the panel edge during a mouse drag (a window resize, the inspector opening and an unpin each need a second input). What would settle it: a path that collapses or unpins the panel, or closes 10.8's inspector, while its edge is being dragged.
    location: >-
      packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart
    severity: medium (unverified)
  - summary: >-
      HomePage injects ZanshinFfiVersion and never reads it.
    evidence: |-
      Pre-existing (review pass 2026-10-18, blind hunter): app/lib/src/features/home/home_page.dart:22-27; before this story HomePage returned `const AppShell()` and did not read it either.
    location: >-
      app/lib/src/features/home/home_page.dart:27
    severity: low
---

<intent-contract>

## Intent

**Problem:** The project window has no home for the floating client: the app's home is still the Yaru test page, nothing places 11.2's islands, nothing runs the rail's previews and pins, the graph has no insets to stay clear of the chrome, and nothing steps the chrome aside while the user scrolls. Epic 10 and the later Epic 11 stories need these slots and this contract before they can land.

**Approach:** Build the host in `app/lib/src/features/shell/` — `FloatingShell` with named slots, a `ShellController` (pins, preview, flyout, holds, widths, calm), a pure width model with the collapse rule, a `CalmController`, and a `ShellScope` that hands `GraphInsets` and the controller to the slots — plus `ZsResizeEdge` and a glass fade (`ZsFade`) in `zanshin_ui`, the `layout` and `general` settings, a `FloatingShellViewModel`, and catalogue use cases. Every slot holds an empty island or nothing until its story lands.

## Boundaries & Constraints

**Always:**
- epics.md Story 11.3 (:12003-12179) is the requirement; its "Design update 2026-10-16" (:12006-12083) supersedes the items it names; decisions 16.x (:11535-11624) apply. DS = `_bmad-output/implementation-artifacts/design_system/`. Precedence: epics decisions > DS tokens/CSS > DS prose/cards > the floating export.
- Every geometry value, colour, duration and curve comes from 11.1's tokens (`ZsMetrics`, `ZsMotion`, `ZsColors`, `ZsType`, `ZsElevation`; `.of(context)` in widgets; the calm and callout waits from `ZsMotion.full` in the controllers, as reduce motion leaves them unchanged — DS tokens/motion.css:70-71). Literals only for DS values that are not tokens, each with its `DS <file>:<line>` in a doc comment: the calm drifts −6 / −8 / +16, the panel slide 8, the minimap slide 18, the callout's x 76 and −22 and width 290, the 30 px trigger, the 24 and 158 of the right inset, the 20 px of the bottom slot.
- Glass is faded only through `ZsFade` (never an `Opacity`/`FadeTransition` above a `BackdropFilter`); drifts are `Transform.translate` × `ZsMotion.motion`; fades keep their durations under reduce motion.
- The controls are 11.11's (`ZsIconButton`, `ZsScrollArea`, `ZsControlCore`); widgets-layer imports only in `zanshin_ui`; the app imports only `package:zanshin_ui/zanshin_ui.dart` and Material types from `material_ui`. SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` clean, every open default marked "Claude's proposal" in a doc comment.
- Every interactive element carries a Semantics identifier or a `ValueKey<String>` (Marionette); hover-only surfaces get catalogue use cases that show them open.

**Never:**
- No slot content: capsule (11.5), View capsule content and New change (10.7), search (10.21), sync group (11.8), Bookmarks (10.14) and Undo Timeline (11.9) items, inspector (10.8), minimap (10.16), @ pill (10.6), toast (10.23), StaleNotice (10.5). No Reviews item.
- No native work: traffic lights, drag region, canvas, full-screen and key-window drivers (11.4, 11.12); no menu bar or ⌘J (11.13); no Settings UI for Hide controls (11.7); no profile measurement (the 11.2 ledger item, still waiting for 10.1).
- No golden tests; no edits under `design/` or `design_system/`; no token value changes; no change to `ZsSheet`, menus or tooltips beyond what the Tasks name; never lower the coverage baseline.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Bar narrows | W 1440 → 880, PLACE 200, VIEW 500, ACTION 238 max-content | VIEW 500 → 435 (W 1000) → 315 (W 880); PLACE/ACTION keep their widths | sides wider than the bar overflow right, no exception |
| Wheel trigger | 30 px, then one more px of wheel over the graph | nothing at 30; calm at 31 | — |
| ⌃-wheel / pinch | wheel with Control held; trackpad pan-zoom with scale ≠ 1 | never counted | — |
| Programmatic scroll | `animateTo` on the graph's scrollable | never counted | — |
| Blocked | an open hold (preview, flyout, menu, edge or item drag) or Hide controls off | events ignored, no phase | a hold taken during a phase does not end it |
| Return | last counted event at t | calm off at t + 650; back from t + 710 to t + 1050 | a new event restarts the wait |
| Inspector pin | a text field in the inspector has focus when a phase starts | inspector stays for the whole phase | focus leaving mid-phase changes nothing |
| Collapse | pinned, inspector open, remembered 300 / 460, W falling | 1192 both; 1112 inspector 380; 1052 panel 240; < 1052 collapsed (pin kept); returns at 1112 | — |
| Stored width out of range | settings hold panelWidth 900 | used as 440; the stored value is not rewritten until the user resizes | — |
| Rail without items | `railItems` empty | no rail island | — |
| Flyout | pinned item collapsed, rail click on an unpinned item | that item becomes pinned (collapsed) and shows as flyout at its remembered width; insets unchanged | Esc / click outside close it, pin kept |
| Esc order | preview and flyout both open | first Esc closes the preview, the second the flyout | Esc with neither open is not handled |
| Inactive window | `ZsAppearance.inactive` true | no preview opens; an open one closes; no edge hover line | — |
| Glass at opacity 0 | `ZsFade(opacity: 0)` | no `BackdropFilter` in the subtree | — |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:12003-12179` -- Story 11.3 (read the 2026-10-16 update :12006-12083 first: geometry from the measured block, rail items, preview keyboard, panel entrance/exit, live insets, calm tokens, items 11-13); `:8907-8920`, `:8943-8949` 10.5 items 14-15 (the other side of the contract); `:11535-11624` decisions 16.4, 16.22-16.24, 16.40, 16.42 (i)(k)(l)(q), 16.45.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart:332-389` -- `chromeInset` 12, `chromeH` 44, `chromeRailBtn` 40, `chromeCol` 52, `chromeFirstX` 91, `chromeBarY` 4, `chromeTop` 60 (68 under `fullScreen`, `resolve` :127-138), `chromeLeft` 76, `inspectorW/Min/Max`, `panelW/Min/Max`, `graphMinW`, `resizeHit`/`resizeHitOut`, `minimapW`; radii :425-458; z ints :461-479; `ZsIconSize.rail/lg/md` :8-32.
- `packages/zanshin_ui/lib/src/design/zs_motion.dart:159-294` -- `of` (reduced iff `disableAnimations`), curves :162-168, `motion` :177, `durHover/Pop/Exit/ExitLg/Panel/Slide/Expand`, `delayCallout/CalloutOut/Resize`, `durCalmOut/In`, `delayCalmIn/Return`.
- `packages/zanshin_ui/lib/src/design/zs_colors.dart` -- `flHover` :818, `flOn` :821, `textMuted` :840, `textDim` :843, `edgeHov` :854, `canvasBase` :769; `ZsType.panelTitle` (`zs_type.dart:153-161`), `fsSm` 11, `fsBase` 13.
- `packages/zanshin_ui/lib/src/materials/zs_surface.dart:91-131` -- `_ZsSurfaceState.build`: box → `ClipRRect` + `BackdropFilter.grouped(filter.toImageFilter())` → `_SurfaceShadow` (an ancestor of the filter: its drops must fade by colour, not by a layer); `_RenderSurfaceShadow.paint` :235-270; the GlobalKey :93 keeps state across filter changes.
- `packages/zanshin_ui/lib/src/design/zs_values.dart:350-378` -- `ZsGlassFilter.toImageFilter({alpha})`, `saturateMatrix`; `packages/zanshin_ui/lib/src/materials/zs_sheet.dart:215-258` -- the scrim's filter-alpha fade, formula f = a(1 − Lα)/(1 − a·Lα) at :244 (the pattern `ZsFade` generalises).
- `packages/zanshin_ui/lib/src/materials/zs_glass.dart:46-169` -- `ZsGlass`, nesting assert :78-81 (stays on the element tree, item I3), `ZsIsland` shapes (bar hugs its content, rail pad 5/gap 4, panel strong + clip); `zs_menu_material.dart:18-48` (callout material, left arrow tip at y 22).
- `packages/zanshin_ui/lib/src/controls/zs_button.dart:316-445` -- `ZsIconButton` (lg = 40, rail icon, ring inside, `active` = `--fl-on`; always wraps `ZsTooltip` at :435-439 — gains `tooltip`); `zs_control_core.dart:75-97` (`shortcuts`, `actions`, `cursor`, `ring`, `semantics`, `identifier`, `activateOnKeys`, `activateOnTap`), `_syncHover` :252; `zs_presence.dart:13-71`; `zs_surface_transition.dart` (callout motion: `durPop`, dx −4 × motion; exit `durExit`); `zs_scroll_area.dart:45-53`; `zs_slider.dart` (semantics pattern for an adjustable value).
- `packages/zanshin_ui/lib/zanshin_ui.dart:11-55` -- exports; tests: `packages/zanshin_ui/test/helpers/{zs_host.dart:18 (group, overlay), controls.dart (hover, activeCursor, ringOf, useMacFocus), material_paints.dart, icon_registry.dart}`, patterns `test/materials/zs_sheet_test.dart:118-138` (filter alpha), `zs_glass_test.dart:206` (shared group key), `:235` (nesting assert).
- `app/lib/src/features/app/zanshin_app.dart:77-190` -- `_ExampleHome`/`_Example`/`CheckboxPage` (the Yaru test page; home at :143, `WindowDragArea` AppBar :155); `_homePageFactory` :27-29 unused today; Linux `YaruTheme` branch :83-93.
- `app/lib/src/features/home/home_page.dart:13-22` (+ `home_page.factory.dart`) -- `@assistedInject`, returns `const AppShell()` today; DI: `main.dart:108-139` (`MainComponent`, modules), `ViewModelFactory` pattern at `zanshin_app.dart:78-80`, `zanshin_app_view_model.dart:16-84` (`@inject` + `SettingsStore` listener, `s.copyWith.appearance(...)`). Regenerate with `dart run build_runner build --delete-conflicting-outputs` in `app/`.
- `app/lib/src/features/shell/` -- holds the docked mock (`app_shell.dart`, `main_nav_rail.dart`, `status_bar.dart`, `window_title_bar.dart`); leave them for 11.10.
- `packages/zanshin_shell/lib/src/window_drag_area.dart:15-31` -- `WindowDragArea` (pan → startWindowDrag, double-tap → titlebar action).
- `packages/zanshin_settings/lib/src/model/{app_settings.dart,appearance_settings.dart}` -- `@freezed` + json with `@Default`, no-migration rule; `settings_store.dart:22-92` (`ValueListenable<AppSettings>`, `update`); `build.yaml` (header width marker); tests that pin the JSON shape: `test/model/app_settings_test.dart:18-40`, `test/settings_store_test.dart:16, :109, :134`. Regenerate with build_runner in `packages/zanshin_settings`.
- `app/widgetbook/catalogue.dart:22-32` (folders, paths), `folders/materials.dart:12-54` (`_overCanvas` = `BackdropGroup` + busy canvas, knobs), `folders/windows.dart:13-84` (`CatalogueWindows.openOrActivate`), `appearance_addon.dart` (no fullScreen field); `app/test/widgetbook/catalogue_smoke_test.dart:27` pins the folder list; `app/test/helpers/{catalogue.dart,icon_registry.dart,recording_shell.dart}`.
- `app/test/features/app/zanshin_app_test.dart:18-22, :96, :167` -- throwing home factory, `find.byType(Scaffold)` probes, 800 × 600 surface: update with the new home.
- DS: `tokens/spacing.css:25-52`, `tokens/motion.css:51-67`, `tokens/effects.css:40-48`, `components/surfaces/surfaces.css:2-6, :14-24, :56-69`, `components/surfaces/{ResizeEdge.jsx:14-43, ResizeEdge.prompt.md:1-13, Callout.prompt.md:1-11, Island.prompt.md:13-15}`, `components/actions/actions.css:34-45`, `ui_kits/desktop/kit.css:28-35, :62-67, :82-90, :147-148, :177-187`, `ui_kits/desktop/chrome.jsx:7-17, :140-166`, `ui_kits/desktop/app.jsx:168-178, :426-429`, `readme.md:84, :100, :104, :131-135, :193-194, :225`, `components/overlays/StaleNotice.prompt.md:8-13`.
- `_bmad-output/implementation-artifacts/deferred-work.md:1233-1255` -- "Surfaced in Story 11.2" (items I1-I3); new section `## Surfaced in Story 11.3 (bmad-build-auto, 2026-10-18)` in that shape.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_ui/lib/src/materials/zs_fade.dart` -- `ZsFade({required double opacity, required Widget child})`, an `InheritedWidget`; `ZsFade.of(context)` = the product of every enclosing `ZsFade` (1 without one) -- the one way to fade glass (I1).
- `packages/zanshin_ui/lib/src/materials/zs_surface.dart` -- read a = `ZsFade.of(context)`: a < 1 wraps the box (inside the `BackdropFilter`) in `Opacity(a)`, gives the filter `toImageFilter(alpha: a(1 − Lα)/(1 − a·Lα))` with Lα = `fill.a`, and scales the drops' colours by a in `_RenderSurfaceShadow`; at a = 0 the filter and its clip are left out (state kept by the GlobalKey). Doc: never fade a surface through an `Opacity` ancestor.
- `packages/zanshin_ui/lib/src/materials/zs_glass.dart` -- doc only: the nesting check stays on the element tree; glass must not mount through an `OverlayPortal` under other glass (11.3 settles I3: no host surface does).
- `packages/zanshin_ui/lib/src/controls/zs_button.dart` -- `ZsIconButton.tooltip` (bool, default true): false returns the button without `ZsTooltip` (the rail's preview replaces it, DS ui_kits/desktop/chrome.jsx:152); the label stays the semantics name.
- `packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart` -- `enum ZsResizeSide {left, right}` (the island side the edge is on) and `ZsResizeEdge({required side, required value, required min, required max, required defaultValue, required label, required onChanged, onChangeEnd, onDragStart, onDragEnd, inert = false, identifier})` on `ZsControlCore` (Design Notes "Resize edge"); export it and `ZsFade` from `lib/zanshin_ui.dart`.
- `packages/zanshin_ui/test/materials/zs_fade_test.dart`, `test/controls/zs_resize_edge_test.dart`, `test/controls/zs_button_test.dart` (the `tooltip: false` case) -- the ACs below for these units.
- `packages/zanshin_settings/lib/src/model/layout_settings.dart`, `general_settings.dart` (+ generated) -- `LayoutSettings {inspectorWidth = 460, panelWidth = 300}` (doubles, int literals) and `GeneralSettings {hideControls = true}` (Claude's proposal: the key `general`, after Settings › General, 11.7); `app_settings.dart` gains `layout` and `general` with `@Default`; export both; regenerate; update the JSON-shape tests and add default / missing-key / round-trip cases.
- `app/lib/src/features/shell/graph_insets.dart` -- `GraphInsets {top, left, right, bottom, inspectorWidth, minimapWidth}` value class (==, hashCode, toString) with the rules in Design Notes "Insets".
- `app/lib/src/features/shell/shell_layout.dart` -- pure `ShellLayout.resolve(...)` → effective panel and inspector widths, `collapsed`, `GraphInsets`, and the drag limits, from window width, `fullScreen` metrics, pinned, inspector open, minimap shown, the remembered widths (clamped to their token ranges) and the previous `collapsed` (Design Notes "Width model").
- `app/lib/src/features/shell/calm_controller.dart` -- `CalmController` (`ValueListenable<CalmPhase>`, `CalmPhase {calm, inspectorPinned}`): `addUserScroll(double)`, `hold()` → `CalmHold.release()`, `hideControls` setter, a `decideInspectorPinned` callback, timers per Design Notes "Calm".
- `app/lib/src/features/shell/shell_controller.dart` -- `ShellController` (`ChangeNotifier`): `pinnedId`, preview state machine, flyout, holds (`openSurface()`, `startItemDrag()`, the edge drag), remembered widths in memory with `onPanelWidthCommitted`/`onInspectorWidthCommitted` callbacks, `hideControls`, the `CalmController`; `ShellRailItem {id, label, icon, count, preview, panel}`.
- `app/lib/src/features/shell/shell_scope.dart` -- `ShellScope` (`InheritedWidget`): `insetsOf(context)`, `of(context)` → the controller (`openSurface`, `startItemDrag`, `reportUserScroll`, `calm`).
- `app/lib/src/features/shell/top_bar.dart` -- the bar: a custom multi-child `RenderBox` for the grid (Design Notes "Top bar"); PLACE gap 12, ACTION gap 8; the VIEW island built here around the `view` slot.
- `app/lib/src/features/shell/rail.dart`, `rail_preview.dart` -- the rail island (`ZsIsland.rail`, `ZsIconButton.lg`, `tooltip: false`, `active` = pinned, identifier `rail-<id>`), hover intent, the callout (Design Notes "Rail").
- `app/lib/src/features/shell/pinned_panel.dart` -- panel host: header, scrolling body, the right-side `ZsResizeEdge`, entrance/exit, and the flyout variant (Design Notes "Panel").
- `app/lib/src/features/shell/floating_shell.dart` -- `FloatingShell({required controller, railItems = const [], canvas, graph, barRow, projectCapsule, view, syncGroup, newChange, inspector, minimap, atPill, toast, staleNotice})`: the window's `BackdropGroup`, layers, `LayoutBuilder` → `ShellLayout` → `ShellScope`, the graph `Listener` for calm, calm motion per group, the stale and bottom slots, Esc, inactive handling (Design Notes "Shell").
- `app/lib/src/features/shell/floating_shell_view_model.dart` -- `@inject FloatingShellViewModel` (`SettingsStore`): owns the `ShellController` seeded from `layout`/`general`, follows `general.hideControls` live, writes committed widths through a 400 ms trailing debounce (flushed on dispose).
- `app/lib/src/features/home/home_page.dart` -- inject `ViewModelFactory<FloatingShellViewModel>`; build `FloatingShell(controller: vm.shell, barRow: WindowDragArea(child: SizedBox.expand()))` with every other slot empty (Claude's proposal, until 11.4 / the slot stories); regenerate DI.
- `app/lib/src/features/app/zanshin_app.dart` -- `home` becomes `_homePageFactory.create()`, title `'Zanshin'`; remove `_Example`, `CheckboxPage` and the `selectedMode`/`onModeChanged` plumbing this change orphans; keep the Linux `YaruTheme` branch on the same home.
- `app/test/features/shell/{graph_insets,shell_layout,calm_controller,shell_controller,top_bar,rail,pinned_panel,floating_shell,floating_shell_view_model}_test.dart`, `app/test/features/home/home_page_test.dart` -- the ACs and every I/O-matrix row (fake_async / `tester` clocks; a test host with `ZsRoot`, `IconRegistryScope`, an `Overlay` and `TapRegionSurface`, at 1440 × 900 unless a row says otherwise).
- `app/test/features/app/zanshin_app_test.dart` -- fake home factory, probes that do not rely on `Scaffold`, a 1440 × 900 surface.
- `app/widgetbook/folders/shell.dart` (+ `catalogue.dart`, smoke-test folder list) -- folder "Shell": "Floating shell" use cases Layout, Preview open, Pinned panel, Flyout, Calm, Slots (demo islands for every slot, demo rail items with the kit's glyphs `ZI.branch` / `ZI.undo`, a stand-in scrollable graph), a width knob (880-1440, the shell in a `FittedBox`) and a full-screen knob (`ZsAppearanceOverride`); `folders/controls.dart` "Resize edge" state matrix; `folders/materials.dart` "Island › Fade" with an opacity knob; `folders/windows.dart` "Floating shell" opening a real 1440 × 900 window with the demo slots.
- `_bmad-output/implementation-artifacts/deferred-work.md` -- the section `## Surfaced in Story 11.3 (bmad-build-auto, 2026-10-18)` mirroring this spec's `deferred:` items, in the same commit as the spec.

**Acceptance Criteria:**
- Given a running app, when the project window opens, then `ZanshinApp`'s home is `HomePage` → `FloatingShell`: a `canvasBase` fill, the bar row a `WindowDragArea`, empty 44 × 44 bar islands for the capsule, View, sync and New change slots, no rail, no panel; the Yaru page is gone.
- Given demo slots of max-content 200 (PLACE), 500 (VIEW) and 238 (ACTION), when the shell lays out at 1440, 1000 and 880 px, then the bar's top is 4 (12 in full screen), PLACE starts at x 91 (12 in full screen), ACTION ends at W − 12, the islands are 12 apart, VIEW is 500 / 435 / 315 wide and centred in the middle track, and PLACE and ACTION keep their widths.
- Given the rail with two items, when the pointer enters a button, then the preview opens 90 ms later (not at 89), at x 76 with its arrow tip on the button's centre, 290 wide, with icon, label and count; moving to the other button switches at once; leaving both closes it 200 ms later, entering the preview cancels that; the pinned item shows none; a click pins (button active, panel shown, preview closed), a click on the other moves the pin, a click on the pinned one unpins.
- Given keyboard focus, when Tab moves through the rail, then each button takes focus with its ring inside, no preview opens, and ↩ (and Space) toggles the pin; the pinned panel's region is announced (`liveRegion`) and the preview is excluded from semantics.
- Given a pin, when the panel enters, then it fades in over 200 ms and slides from −8 px on the glide curve (no slide under `disableAnimations`, the fade unchanged); its close button unpins; on unpin it fades out over 180 ms drifting −8 px × motion; switching the pin replaces the panel and replays the entrance.
- Given the panel edge, when dragged, then the width follows the pointer with no tween, stops at 440 and where 320 px of graph would remain, the left inset follows in the same frame, the cursor is `resizeColumn` (`resizeRight` at the minimum, `resizeLeft` at the maximum) and stays so over the whole window during the drag; the stored `layout.panelWidth` is written once after release, never during the drag; a double-click resets to 300 over 200 ms (a jump under reduce motion); ←/→ ±10, ⇧ ±50, Home/End min/max, ↩ the default; a 2 px `--edge-hov` line shows 150 ms after hover; `matchesSemantics(isSlider: true, label: 'Panel width', value: '300 points')` and increase → 310.
- Given window widths 1192, 1150, 1112, 1080, 1052 and 1051 with a pin, the inspector open and remembered 300 / 460, when laid out, then the effective widths follow the collapse rule (Design Notes), below 1052 the panel collapses with its pin and active rail button and left inset 76, widening it stays collapsed until 1112 and returns at 300; a narrow window never changes the stored widths.
- Given 1000 px with a pin and the inspector open, when an unpinned rail button is clicked, then it becomes the pin, collapsed, and shows as the flyout at its remembered width beside the rail with the insets unchanged; Esc or a click outside closes the flyout and keeps the pin; a click on its button while it shows closes it and unpins.
- Given the shell, when insets are read through `ShellScope.insetsOf`, then they are top 60 (68 full screen), left 76 or 76 + effective panel + 12, right effective inspector + 24 with the inspector, else 158 with a minimap, else 12, bottom 12; the @ pill and toast centre on the visible rect 20 px above the bottom, and the pill is hidden while a toast shows.
- Given Hide controls on and nothing open, when 31 px of wheel scrolling reach the graph layer, then within 180 ms the PLACE, VIEW and ACTION groups reach opacity 0 at −6 px, the rail and panel at −8 px, the inspector at +16 px, the @ pill fades out in 120 ms, a preview closes outright, the edges hide, the stepped-aside groups ignore the pointer, and the toast, stale notice and minimap stay (the minimap comes forward while the inspector is aside); 650 ms after the last event they return over 340 ms after a 60 ms wait.
- Given each blocking state (30 px only, ⌃-wheel, trackpad pinch, a programmatic `animateTo`, Hide controls off, an open preview, flyout, `openSurface()` hold, edge drag or item drag), when the same scrolling happens, then nothing moves; given `disableAnimations`, the groups fade with no translation; given a focused text field in the inspector at phase start, the inspector stays for the whole phase; given focus inside the View island, it stays while focus is there; an open Settings window blocks nothing (no hold is taken outside this window).
- Given a stale notice slot, when it appears and leaves, then it fades in over 200 ms with no movement at top 60, centred, and fades out over 180 ms.
- Given an inactive window, when the pointer enters a rail button or an edge, then no preview opens and no edge line shows; an open preview closes when the window turns inactive.
- Given below the bar row, when the primary button presses between islands, then the graph layer receives it (a pan starts); on an island it does not.
- Given `ZsFade(opacity: .5)` over `ZsGlass`, when pumped, then its `BackdropFilter` equals compose(saturate 1.4 with alpha a(1 − Lα)/(1 − a·Lα), blur σ 18), the box sits under an `Opacity(.5)` below the filter, the drops paint at half alpha, and no `Opacity`/`FadeTransition` is an ancestor of any `BackdropFilter` in the shell during calm, the panel entrance or the flyout; at opacity 0 the subtree holds no `BackdropFilter`; under reduce transparency the box fades by the same `Opacity`.
- Given a pinned panel, an open flyout, an open preview and glass demo slots, when the shell is pumped in debug mode, then the glass nesting assertion does not fire.
- Given the settings store, when `layout`/`general` are missing, partial or round-tripped, then defaults 460 / 300 / true apply and values survive; when Hide controls is switched off in the store, the running shell stops stepping aside without a restart.
- Given the catalogue, when the smoke test runs, then every Shell, Resize edge, Fade and Windows use case pumps in night and paper and with every appearance flag.
- Given the change, when `cargo make test` runs unpiped, then it passes.

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 55 findings — high 0, medium 11, low 39, false 3, maybe-false 2
- findings:
  - `[low]` `[patch]` (blind 1) The inspector slot is exactly the inspector's width, so 10.8 cannot put its edge inside it, and nothing tells 10.8 where it goes — patched: `FloatingShell` ("What a slot must bring") and `ShellScope` docs say 10.8 adds the edge as a host sibling like the panel's and name its hooks.
  - `[medium]` `[defer]` (blind 2) Nothing connects a slot's menus, popovers, selects and sheets to the calm hold; `ZsSelect` has no open callback — deferred (the slot stories 10.7, 10.21, 11.5, 11.8 take the holds), mirrored.
  - `[medium]` `[patch]` (blind 3) Calm fades only Zs surfaces, so the panel edge's line and focus ring stay visible while the panel steps aside, and the slot contract never says content must be a material — patched: the edge sits in an `Opacity` of `ZsFade.of` in `ShellPanels`; the slot doc states the rule; a test pins a focused edge at opacity 0 during calm and back at 1.
  - `[medium]` `[patch]` (blind 4) A drag that ends where it started or stays clamped commits the effective width, overwriting the remembered one — patched: `ZsResizeEdge` commits a drag, a key step or Home/End only when the width changed, and a reset goes to the default itself; two tests.
  - `[low]` `[reject]` (blind 5) Interrupted panel and stale-notice animations restart from 0/1 instead of reversing; two similar state machines — a pin undone within 200 ms is rare, and a reversal from mid-value also needs a curve hand-over, more than a direct correction.
  - `[low]` `[patch]` (blind 6) A swapped controller keeps `inactive == false` — patched: `didUpdateWidget` pushes the window's inactive flag into the new controller.
  - `[low]` `[reject]` (blind 7) `layoutFor` updates `collapsed` and closes the flyout during build without notifying — every current reader is built in the same pass and `ShellScope.layoutOf` carries `collapsed`; no outside listener exists, and a post-frame notify is more than a correction.
  - `[low]` `[patch]` (blind 8) The bar measures slots with `getMaxIntrinsicWidth`, so a `LayoutBuilder` in a bar slot throws — patched: the slot doc states the requirement for 10.7, 10.21, 11.5 and 11.8.
  - `[low]` `[patch]` (blind 9) The bar-row stand-in is translucent, so presses in the bar row also reach the graph — patched: `HomePage`'s stand-in holds an opaque transparent `ColoredBox`; the home test hit-tests the bar row (no canvas) and below it (canvas).
  - `[low]` `[reject]` (blind 10) An item-drag hold released after the controller is disposed notifies a disposed notifier — no item drag exists before 10.10, the controller lives as long as the window, and the fix is a guard for an undemonstrated state.
  - `[low]` `[reject]` (blind 11) Groups aside keep keyboard focus; an inert edge still takes keys — the DS kit hides them with `pointer-events` only too; `ExcludeFocus` would take focus away from the focused control on every scroll; keys during a card drag on a focused edge is contrived.
  - `[low]` `[reject]` (blind 12a) The recompiled epic-11-context.md drops rules the old one carried (worker-isolate handles, package dependencies, font prefix) — the compile rules keep it to what is not derivable from the code; project-context.md stays canonical and every spec loads it.
  - `[low]` `[patch]` (blind 12b) epic-11-context.md still lists I1–I3 as hand-offs to 11.3 — patched: the line says 11.3 settled them and names what stays open (other arrow sides for 10.6/10.19, the glass cost).
  - `[low]` `[reject]` (blind 13a) The docked mock UI is now unreachable — its retirement is Story 11.10's scope by the epics' sequencing, which this story's intent keeps.
  - `[low]` `[defer]` (blind 13b) `HomePage` injects `ZanshinFfiVersion` and never reads it — pre-existing (it was unread before too); deferred, mirrored.
  - `[low]` `[reject]` (blind 14) 300/460 controller defaults and the rail's padding 5 repeat values — the settings package cannot read the UI tokens, so the widths exist in three places by necessity; the rail padding is a DS literal, not a token; the app always passes stored widths.
  - `[low]` `[reject]` (blind 15) The panel and preview headers are `Row`/`Column` trees and the preview title style is hand-built — 11.11's popover, menu and dialog headers use the same `Row` build; the house rule targets designed visuals such as cards; the DS gives the callout header raw values, not a type token.
  - `[low]` `[patch]` (blind 16) The view-model tests wait on the real clock for the file write — patched: they count the store's synchronous notifications and drain its write queue before tearDown; no assertion waits on the disk.
  - `[low]` `[reject]` (blind 17a) No test that an open Settings window blocks nothing — holds exist per shell controller only, so another window cannot take one; a real second window is 11.12's.
  - `[low]` `[patch]` (blind 17b) No test of the Tab order panel controls → edge — patched: a pinned-panel test tabs through and checks the edge follows the panel's own controls.
  - `[low]` `[reject]` (blind 17c) No test of `ShellScope`'s assert outside a shell — an assert message, nothing to observe in a widget test that a reviewer would act on.
  - `[low]` `[patch]` (blind 17d) No test of `reportUserScroll` through `ShellScope` — patched with verification-gap 1: the edge-drag case reports through `ShellScope.of(context)`.
  - `[low]` `[reject]` (blind 17e) No test of inert edges ignoring keys — the behaviour is rejected with blind 11.
  - `[medium]` `[patch]` (edge 1) The shell's conditional `Positioned` children are unkeyed, so the inspector or minimap coming and going remounts the rail and the pinned panel (state, scroll and focus lost, entrance replayed) — patched: every child of the shell's stacks is keyed; a test keeps the same `ShellPanels` and `PinnedPanel` states across an inspector toggle (it fails without the keys).
  - `[low]` `[patch]` (edge 2) The panel stack's edge shifts the flyout's element, so the flyout vanishes without its exit — patched with edge 1: the panel, edge and flyout are keyed.
  - `[maybe-false]` `[defer]` (edge 3) An edge removed mid-drag never ends its drag, keeping the calm hold — no 11.3 path removes the edge during a mouse drag; if true medium; deferred unverified with what would settle it, mirrored.
  - `[low]` `[patch]` (edge 4) A swapped controller is not told the inactive state — patched with blind 6.
  - `[low]` `[patch]` (edge 5) The view model's dispose flush notifies the store's listeners while the tree unmounts (a locked-tree error in debug) — patched: the flush runs in a microtask; the dispose test checks the value only after it.
  - `[maybe-false]` `[reject]` (edge 6) A pinch's first updates at scale 1 might count — macOS sends a magnify gesture's updates with the scale changing and no pan; if true only low (the chrome fades during a pinch).
  - `[low]` `[reject]` (edge 7) A pin whose item is not in `railItems` keeps the panel's inset — rail items are fixed per shell in 11.3 and pins are not persisted; the guard covers an undemonstrated state.
  - `[medium]` `[patch]` (edge 8) Non-material group content is not faded — patched with blind 3.
  - `[low]` `[reject]` (edge 9) Interrupted entrance and exit snap — rejected with blind 5.
  - `[low]` `[reject]` (edge 10) Item-drag hold release after dispose — rejected with blind 10.
  - `[low]` `[patch]` (edge 11) Bar slots need intrinsic widths — patched with blind 8 (doc).
  - `[medium]` `[patch]` (edge 12) The edge commits the effective width (End, reset, a capped step) — patched with blind 4.
  - `[medium]` `[patch]` (edge 13) The edges do not hide during calm — patched with blind 3.
  - `[low]` `[reject]` (edge 14) `AppShell` and its parts are dead code — rejected with blind 13a (Story 11.10).
  - `[low]` `[patch]` (verification-gap 1) The blocking-states test's edge-drag case cannot fail: the drag's window-wide cursor region swallows the wheel — patched: the case asserts `edgeDragging` and `calm.held` during the drag and after release, and reports the scroll through `ShellScope`.
  - `[low]` `[patch]` (verification-gap 2) Only the positive inspector-pin case is tested — patched: a text field focused in the View slot at the phase start pins nothing (inspector aside, minimap forward).
  - `[low]` `[patch]` (verification-gap 3) The flyout clamps the remembered width itself and no test gives it one out of range — patched: the flyout takes the layout's clamped panel width; a test shows 900 → 440 and 100 → 240.
  - `[medium]` `[patch]` (verification-gap other 1) A keyboard-focused panel edge keeps painting its ring during calm — patched with blind 3.
  - `[false]` `[reject]` (intent 1) The Mac confirmation of I1 is not evidenced — the implementation run confirmed it in the running catalogue through Marionette (the backdrop stays blurred through `ZsFade` at .9 and turns sharp under a throwaway `Opacity` ancestor); recorded under Auto Run Result.
  - `[medium]` `[patch]` (intent 2) `ZsFade` fades only materials, not the edge or other non-material content — patched with blind 3.
  - `[false]` `[reject]` (intent 3) I2's broad reading (a general arrow side and flip from 11.3) — 11.3's items scope placement to its own preview (item 5); 10.17's popover flips itself against the unobscured area 11.3 provides (epics.md:10455, `GraphInsets.visibleRect`); the ledger entry keeps 10.6's and 10.19's part.
  - `[low]` `[reject]` (intent 4) I3's suspected false positive is neither reproduced nor ruled out — the framework makes an `OverlayPortal`'s overlay child an element child of the portal, so it would fire; 11.3 decided no glass mounts that way, documented on `ZsGlass`, and a shell test with panel, flyout, preview and glass in every slot stays quiet.
  - `[low]` `[reject]` (intent 5) The running app shows only empty islands — item 1 ties the running-app review to 10.5's fake ports, which do not exist; the catalogue's Windows › Floating shell opens a real window with the demo slots.
  - `[low]` `[patch]` (intent 6a) The bar is not tested at 1100 and 920 px — patched: the layout test runs 1440, 1100, 1000, 920 and 880.
  - `[low]` `[reject]` (intent 6b) The slot breakpoints (count at 1040, New change at 920, search at 880) are not exercised — slot content is out of scope (the epics' non-goal "What fills the slots"); the owners read the width.
  - `[low]` `[reject]` (intent 6c) Pans and minimap scrolling have no caller of `reportUserScroll` — already deferred (item 1).
  - `[medium]` `[defer]` (intent 6d) "An open menu blocks calm" runs only through a manual hold — deferred with blind 2.
  - `[low]` `[reject]` (intent 6e) No real Settings window in the calm test — rejected with blind 17a.
  - `[low]` `[reject]` (intent 6f) The inactive witnesses (no island hover, no Tab ring) wait for 11.12 — the host's part (no preview, no edge line) is tested under `ZsAppearanceOverride(inactive)`; island hover and rings are 11.11's controls, tested there.
  - `[medium]` `[defer]` (intent 7) The hold contract is only a doc comment, not in the deferred list — deferred with blind 2.
  - `[low]` `[patch]` (intent 8) No Auto Run Result yet and the ledger's I1–I3 entries are unchanged — patched at finalize: the Auto Run Result lists I1–I3 and the ledger marks them.
  - `[false]` `[reject]` (intent 9) The epic-11-context.md rewrite is outside the intent — step 1 of this workflow recompiles the epic context whenever the planning artifacts are newer (epics.md changed at 8b6b68d), and the run commits it.

## Design Notes

**Top bar** (DS ui_kits/desktop/kit.css:32; readme.md:84). Box: x from `chromeFirstX` to W − `chromeInset`, y `chromeBarY`, height `chromeH`. Columns with the max-content widths L, C, R (intrinsics), A = box width: `free = A − 24 − L − R`, `col2 = clamp(free, 0, C)`, `S = A − 24 − col2`; col1 = max(L, S/2) unless R > S/2, then col1 = S − R; col3 = S − col1 (CSS grid's fr resolution for `minmax(max-content,1fr) minmax(0,max-content) minmax(max-content,1fr)`). PLACE starts its column, VIEW is centred in its column and laid out at maxWidth col2, ACTION ends its column. Breakpoint looks (count, New change, search) are the slot owners'; they read the width themselves.

**Width model** (decisions 16.22-16.23; epics.md:12044-12056). rightSide = inspector ? effInsp + 24 : (minimap ? 158 : 12); need(p, r) = 88 + p + r + 320. Not pinned: effInsp = min(Ri, max(380, W − 420)). Pinned: minRight = inspector ? 404 : rightSide; collapsed = wasCollapsed ? need(Rp, minRight) > W : need(240, minRight) > W. Collapsed: as not pinned, left inset 76. Else without inspector: effPanel = min(Rp, W − 88 − rightSide − 320). Else with inspector: both remembered if need(Rp, Ri + 24) ≤ W; else effInsp = max(380, W − 88 − Rp − 24 − 320) with panel Rp while that is ≥ 380; else inspector 380 and effPanel = W − 812. Drag limits: panel hi = max(240, min(440, W − 88 − rightSide − 320)); inspector hi = max(380, min(720, W − leftInset − 24 − 320)). Unpinning clears `collapsed`. **Insets** (epics.md:12023-12026, :8943-8948): top `chromeTop`; left = pinned && !collapsed ? `chromeLeft` + effPanel + 12 : `chromeLeft`; right = rightSide; bottom 12; `inspectorWidth` = effInsp; `minimapWidth` = minimap ? `minimapW` : 0. Calm never changes them.

**Calm** (decisions 16.4, 16.45; DS tokens/motion.css:63-67; kit.css:177-187). The shell's `Listener` around canvas + graph counts `PointerScrollEvent` |dx| + |dy| and `PointerPanZoomUpdateEvent` |panDelta.dx| + |panDelta.dy| while scale is 1 and rotation 0, never with Control held; 10.1/10.16 add pans, flings and the minimap through `ShellScope.of(context).reportUserScroll` (deferred item 1). Ignored while a hold exists or Hide controls is off; the sum turns calm on once > 30; each counted event restarts `delayCalmReturn`; when it fires, calm ends and the sum resets. At phase start `decideInspectorPinned` (focus inside the inspector slot on an `EditableText`) fixes `inspectorPinned`. Motion per group (one controller, t 0 = rest → 1 = aside): out `durCalmOut` on `easeExit` for opacity and drift; back after `delayCalmIn` over `durCalmIn`, opacity on `easeState`, drift on `easeGlide` (reverse curves `.flipped`, so the back phase follows the curve in time like CSS). @ pill: out `durExit` on `easeExit`, back as the others. Minimap visible = slot set && (!inspector || (calm && !inspectorPinned)); in: opacity `durPanel`, slide from +18 × motion over `durSlide` on glide; out: opacity `durExitLg` on `easeExit`, +18 × motion, ignored by the pointer and gone after `durSlide`. Previews close outright; groups aside ignore the pointer.

**Rail** (DS chrome.jsx:140-157; Callout.prompt.md:9-11; surfaces.css:16-24; kit.css:65-67). Rail at (12, chromeTop), `ZsIsland.rail`, hidden without items; button i's centre y = chromeTop + 1 + 5 + i·44 + 20. Hover intent per button and preview: enter → cancel timers; pinned item → close and stop; a preview open → switch at once; else open after `delayCallout`; leave → close after `delayCalloutOut`; preview enter cancels; click → cancel, close, toggle the pin (flyout rules below). No preview while inactive, during a drag, or during calm. The preview: `ZsPresence` + `ZsSurfaceTransition(callout)` + `ZsMenuMaterial(arrow: true)`, at left `chromeLeft`, top = centre − 22, width 290, maxHeight = H − 12 − top; header padding 11 14 8, gap 8, icon md `textMuted`, label 13/600, count mono `fsSm` `textDim` at the end; body padding-bottom 8; an open preview holds calm. Its arrow never needs another side or offset in 11.3 (fixed placement, bounded height; item I2).

**Panel** (kit.css:82-87; chrome.jsx:164-166; decision 16.40). `ZsIsland.panel` at (chromeLeft, chromeTop), bottom 12, width effPanel; header padding 14 12 12 16, gap 8, icon lg `textMuted`, title `ZsType.panelTitle` (deferred item 4), `ZsIconButton.sm` close "Close"; body `ZsScrollArea`, padding-bottom 10. Entrance: `ZsFade` 0 → 1 and dx −8 × motion → 0 over `durPanel` on glide; exit: 1 → 0 and 0 → −8 × motion over `durExitLg` on `easeExit` (kept mounted by `ZsPresence`). Edge: `ZsResizeEdge(side: right)` at x = chromeLeft + effPanel − 3, top chromeTop + 16, bottom 12 + 16, width 10, after the panel's controls in traversal; label "Panel width". Collapsed: no panel, no edge, no inset. Flyout (Claude's proposal): with no room, a click on an unpinned item pins it and shows it as the flyout (same build, remembered width clamped to 240-440, no edge, its own `BackdropGroup`, a `TapRegion` with the rail as its group); a click on the pinned item while collapsed shows the flyout; a click on it while the flyout shows closes it and unpins; Esc and an outside tap close it, pin kept; an open flyout holds calm.

**Resize edge** (DS ResizeEdge.jsx, surfaces.css:61-69). `ZsControlCore` with `activateOnKeys/OnTap: false`, `shortcuts`/`actions` for the keys (side right: → wider; side left: → narrower; Home min, End max, ↩ animated reset), `ring` outside, `cursor` as in the ACs (side left mirrors: `resizeLeft` at the minimum), semantics slider with increase = wider. Line: 2 px pill in `edgeHov` at x 1.5-3.5 of the strip (side right; mirrored for left), the full strip height; it fades in over `durHover` once the hover has lasted `delayResize` (150), shows at once while dragging, and fades out over `durHover` on exit. Drag: horizontal drag recognizer + double-tap; `onChanged` per move clamped [min, max]; `onChangeEnd` on release, reset end and each key step; the window-wide cursor through an `OverlayPortal` full-overlay `MouseRegion` while dragging (skipped without an `Overlay`). `inert`: `IgnorePointer`, no line.

**Shell** layers, bottom to top: canvas (default `ColoredBox(canvasBase)`), graph (inside the calm `Listener`), `barRow` (0 → chromeTop), the chrome layer (bar, rail, panel + edge, flyout, inspector at right 12 / width effInsp and minimap at right 12 / width `minimapW`, both from `chromeTop` to bottom 12, stale notice at top `chromeTop` centred in the window and faded through `ZsFade` (in over `durPanel` on `easeState`, out over `durExitLg` on `easeExit`, kept by `ZsPresence`), @ pill and toast; `zChrome`), the preview layer (`zPreview`); sheets, menus and tooltips mount through the window's `Overlay` above. One `BackdropGroup` wraps it all. Focus nodes around the View island and the inspector slot drive "View in use" and `decideInspectorPinned`. A root `Focus(autofocus, skipTraversal)` handles Esc: preview, then flyout, else ignored. Inactive (`ZsAppearance.inactive`) closes the preview and blocks hover intent. `HomePage`'s `barRow` and the canvas fill are stand-ins for 11.4 (deferred item 2).

## Verification

**Commands:**
- `dart run build_runner build --delete-conflicting-outputs` in `packages/zanshin_settings` and in `app/` -- expected: generated files updated, nothing else changed.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_ui`, `packages/zanshin_settings` and `app/` -- expected: clean.
- `flutter test` in `packages/zanshin_ui`, `packages/zanshin_settings` and `app/` -- expected: all pass.
- `cargo make test` (repo root, unpiped, `PATH` with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, coverage baseline unchanged.

**Manual checks (if no CLI):**
- Claude's visual check (house rule, project-context.md:562-569): run the catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`), connect Marionette, open `shell/floating-shell/*`, `controls/resize-edge/*` and `materials/island/fade` with `zanshinCatalogue.open` in night and paper, screenshot, and compare with the DS cards (`components/surfaces/surfaces.card.html` callout and rail, the ResizeEdge card, `ui_kits/desktop`) rendered through the `design-system-preview` server; on the same run confirm I1 on the Mac: an island at opacity .5 through `ZsFade` keeps its blur (and, as a throwaway comparison not committed, through an `Opacity` ancestor). Record what was and was not seen in the Auto Run Result.
- Ralph: the running app shows the empty bar and moves by the bar row; the Windows › Floating shell window resizes through the collapse widths.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none.

**Summary.** The project window's home is now the floating overlay host. `FloatingShell` (`app/lib/src/features/shell/`) lays out the canvas, the graph slot inside the calm listener, the bar row and the chrome on one `BackdropGroup`: the top bar Place · View · Action as one grid render box (the centre gives way first), the rail of `ZsIconButton.lg` buttons with hover previews (90 / 200 ms, instant switch, none for the pinned item) and pins, the pinned panel with its entrance and exit and its `ZsResizeEdge`, the flyout for a collapsed pin, the inspector, minimap, stale-notice and bottom slots, Esc (preview, then flyout) and the inactive window. `ShellLayout` is the width model with the collapse rule and the drag limits; it publishes `GraphInsets` through `ShellScope`. `CalmController` is the 30 px / 650 ms machine with holds and the inspector pin decided at phase start; the shell counts wheel and trackpad scrolling over the graph, and every group steps aside through `ZsFade` and a drift × `--motion`. `zanshin_ui` gains `ZsFade` (glass fades through the filter's alpha, an `Opacity` inside the filter and the drops' colour), `ZsResizeEdge` and `ZsIconButton.tooltip`. `zanshin_settings` gains `layout` {460, 300} and `general` {hideControls: true}; `FloatingShellViewModel` seeds the shell from them, follows Hide controls live and writes committed widths after a 400 ms debounce. The catalogue gains the Shell folder, Controls › Resize edge, Materials › Island › Fade and Windows › Floating shell. Every slot is empty in the app until its story lands.

**Ledger items I1–I3** (deferred-work.md, "Surfaced in Story 11.2"):
- **I1 — fixed** (commit COMMIT_1): `ZsFade` is the one way to fade glass; every `ZsSurface` under it puts its box under an `Opacity` inside the `BackdropFilter`, gives the filter the alpha a(1 − Lα)/(1 − a·Lα) and paints its drops at a times their alpha, and drops the filter at 0. Calm scrolling, the panel's entrance and exit, the flyout, the minimap's motion and the stale notice fade through it; 10.16 and 10.23 use the same scope. Confirmed on the Mac in the running catalogue through Marionette (implementation run): at opacity .9 through `ZsFade` the panel's backdrop stays blurred, while a throwaway `Opacity` ancestor (reverted) left it sharp, as the engine reading said.
- **I2 — rejected for 11.3's part**: 11.3's one callout, the rail preview, sits at a fixed place (x 76, its arrow tip on the button's centre) with its height bounded by the window, so it never flips or shifts and needs no other side or offset. The entry stays open for the commit and gap callouts of 10.6 and 10.19 (annotated in the ledger, not mirrored again).
- **I3 — rejected (settled by decision)**: no glass in the host mounts through an `OverlayPortal` inside an island — the preview is the menu material and the flyout a sibling of the rail in the shell's stack — so the nesting check stays on the element tree; `ZsGlass`'s doc states the rule, and a shell test with a pinned panel, the flyout, an open preview and glass in every slot pumps without the assertion (commit COMMIT_1).

**Files changed** (one line each):
- `packages/zanshin_ui/lib/src/materials/zs_fade.dart` -- the inherited glass fade.
- `packages/zanshin_ui/lib/src/materials/zs_surface.dart` -- surfaces fade through `ZsFade` (box opacity inside the filter, filter alpha, drop alpha).
- `packages/zanshin_ui/lib/src/materials/zs_glass.dart` -- doc: the nesting rule against `OverlayPortal`, fade only through `ZsFade`.
- `packages/zanshin_ui/lib/src/controls/zs_resize_edge.dart` -- the resize edge (drag, reset, keys, cursors, line, slider semantics, inert, commits only real changes).
- `packages/zanshin_ui/lib/src/controls/zs_button.dart` -- `ZsIconButton.tooltip`.
- `packages/zanshin_ui/lib/zanshin_ui.dart` -- exports.
- `packages/zanshin_ui/test/{materials/zs_fade_test.dart,controls/zs_resize_edge_test.dart,controls/zs_button_test.dart}` -- their witnesses.
- `packages/zanshin_settings/lib/src/model/{layout_settings,general_settings,app_settings}.dart` (+ generated), `lib/zanshin_settings.dart`, `test/{model/app_settings_test.dart,settings_store_test.dart}` -- the `layout` and `general` sub-models.
- `app/lib/src/features/shell/{floating_shell,shell_controller,calm_controller,shell_layout,graph_insets,shell_scope,top_bar,rail,rail_preview,pinned_panel,floating_shell_view_model}.dart` -- the host.
- `app/lib/src/features/home/home_page.dart`, `app/lib/src/features/app/zanshin_app.dart`, `app/lib/main.inject.dart` -- the new home; the Yaru test page goes.
- `app/test/features/shell/*_test.dart`, `app/test/features/home/home_page_test.dart`, `app/test/helpers/shell_host.dart`, `app/test/features/app/zanshin_app_test.dart` -- the witnesses and every I/O-matrix row.
- `app/widgetbook/{catalogue.dart,folders/shell.dart,folders/controls.dart,folders/materials.dart,folders/windows.dart}`, `app/test/widgetbook/catalogue_smoke_test.dart` -- the catalogue use cases.
- Tracking: this spec, `epic-11-context.md` (recompiled at step 1; its hand-off line updated), `deferred-work.md` ("Surfaced in Story 11.3", eight items; I1–I3 marked), `sprint-status.yaml` (11-3 done).

**Review findings.** 55 findings (high 0, medium 11, low 39, false 3, maybe-false 2). Patched (16 entries; 3 medium, 13 low): every child of the shell's and the panel's stacks keyed, so the inspector coming and going no longer remounts the rail and the pinned panel (medium); the panel edge fades with its group, its focus ring included (medium); `ZsResizeEdge` commits only real changes and a reset goes to the default, so a narrow window no longer overwrites the remembered width (medium); a swapped controller gets the inactive flag; the bar-row stand-in is an opaque target; the view model's dispose flush runs in a microtask; the flyout takes the layout's clamped width; docs for the slot contract (holds, intrinsic widths, non-material content, the inspector edge for 10.8); the epic context's hand-off line; tests for the edge-drag hold, the negative inspector pin, the flyout clamp, the Tab order, the bar at 1100 and 920, the view model without disk waits. Deferred (new, mirrored in deferred-work.md): the slot stories must take calm holds for their surfaces (medium); an edge removed mid-drag never ends its drag (medium, unverified); the unused `ZanshinFfiVersion` on `HomePage` (low, pre-existing). Rejected, with reasons in the triage log: interrupted entrance/exit snaps, the build-time `layoutFor` state, the post-dispose item-drag release, keyboard focus in groups aside and inert edges' keys, the epic context's dropped rules, the docked mock's dead code (11.10), the repeated 300/460 and rail padding, `Row` headers, the untestable Settings-window and assert cases, a pinch at scale 1, a pin without its item, the running app's empty islands, slot breakpoints, pans and minimap (already deferred), the inactive witnesses (11.12/11.11), and the 3 false findings.

**Follow-up review recommendation:** true — this first pass patched 3 medium entries (0 high, 13 low). The unverified risk: the three medium fixes (the keyed stacks, the edge's commit rules and its fade during calm) landed after the visual check and were verified in widget tests only — not in the running catalogue on the Mac, where an inspector toggle, a reset at a narrow width and a calm phase with a focused edge are worth one look.

**Verification.**
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_ui`, `packages/zanshin_settings` and `app/` -- clean, before and after the review patches.
- `flutter test` -- `zanshin_ui` 365 → 367 tests, `zanshin_settings` 28, app 416 → 423, all passed.
- `dart run build_runner build --delete-conflicting-outputs` in `packages/zanshin_settings` and `app/` -- idempotent (diff hash unchanged); the inject warning about an unused binding concerns the existing `GetDiagnostics`/`IconRegistry` bindings.
- `cargo make test` (repo root, output to a file, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- exit 0 after the patches; the change-aware plan ran 6 of 27 steps (app and `zanshin_ui` Flutter test, analyze, format); no Rust changed, so coverage did not run and `coverage-baseline.txt` is unchanged.
- Matrix audit: every I/O-matrix row has a passing test (bar narrows and overflow in `top_bar_test`; trigger, return, holds, Hide controls and the inspector pin in `calm_controller_test` and `floating_shell_test`; ⌃-wheel, pinch and programmatic scroll in `floating_shell_test`; collapse in `shell_layout_test` and `pinned_panel_test`; out-of-range width in `shell_layout_test` and `floating_shell_view_model_test`; no items in `rail_test` and `home_page_test`; flyout and Esc order in `shell_controller_test` and `pinned_panel_test`; inactive window in `rail_test`, `shell_controller_test` and `zs_resize_edge_test`; opacity 0 in `zs_fade_test`).
- Visual check (house rule, implementation run): the catalogue ran on the Mac with Marionette; Shell › Slots, Preview open, Flyout and Calm (night), Pinned panel and Layout (paper), Controls › Resize edge and Materials › Island › Fade (night) were compared with the DS desktop kit, surfaces card and resize card. Not checked visually: the full-screen knob, an inactive window, increased contrast, Resize edge › Interactive, the real Windows › Floating shell window, and the review patches.

**Residual risks.**
- The review patches were not re-checked in the running catalogue (see the follow-up recommendation).
- The app shows only empty islands until the slot stories land; Ralph reviews the shell through the catalogue's Windows › Floating shell.
- No surface of a later story takes a calm hold yet; the contract is a doc and a deferred item.
