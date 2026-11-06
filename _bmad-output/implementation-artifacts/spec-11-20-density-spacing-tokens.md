---
title: 'Story 11.20 — Density with an effect: spacing tokens per density, plus Zoom'
type: 'feature'
created: '2026-11-06'
status: 'done'
baseline_revision: 'e41e22ee120c4b98e89bb5eaa5a3a6a541ab79ef'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized', 'multiple-goals']
deferred:
  - summary: >-
      Density and Zoom were not checked in the running app, and their native window behaviour is untested.
    evidence: |-
      No Marionette run per density and zoom against the DS cards Density and Settings. Unexercised: native ⌘+ dispatch of CharacterActivator('+'), engine setConstraints/setSize growing windows on a zoom change, the removed native minSize, and the restored frame grown to contentMinSize (assumes the minimum is set before restore runs). Widget tests cover the Dart side only.
    location: >-
      app/lib/src/features/window/app_windows.dart, app/lib/src/features/shell/app_menu.dart, app/macos/Runner/MainWindowChrome.swift, app/macos/Runner/WindowFrameStore.swift
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Settings › Density (Compact · Balanced · Comfy) only scales the text (12.5 / 13 / 13.5, `zanshin_window_root.dart:58-84`); no token reads it (deferred-work I1 "Density has no tokens"). macOS's text size never reaches a Flutter window, so there is no way to make Zanshin bigger.

**Approach:** Build DESIGN-SYSTEM-SYNC #21. Density becomes air: `ZsMetrics` carries a set per density, and every listed row, the graph cards and the graph gaps follow it, live, in every window. Add **Zoom** (90 · 100 · 110 · 125 · 150 %) as `appearance.zoom`. It is a Settings › General pop-up and View › Zoom In / Zoom Out / Actual Size. It scales each window's whole content, and every window's minimum with it.

## Boundaries & Constraints

**Always:**
- **DS is the source.** Use `design_system/components/density.css`, readme › *Density and zoom* (readme.md:100), the View menu (:219), Settings (:206), and the cards `components/settings/density.card.html` and `settings.card.html:31-32`.
- **Density sets** (`ZsDensity` compact / balanced / comfy; compact = today's tokens):

  | Density | rowStep | card height compact / detailed | gaps x × y |
  |---|---|---|---|
  | Compact | 0 | 40 / 62 | 56 × 48 |
  | Balanced | 3 | 44 / 68 | 62 × 54 |
  | Comfy | 6 | 48 / 74 | 68 × 60 |

  Text, controls, chrome, radii and window sizes stay. The text scale goes.
- **Rows.** A fixed-height row adds `rowStep`. A padded row adds `rowStep / 2` above and below. A settings row does both: min 46 + step, and padding 8 (stack 10) + step/2. A row's base value stays as the code has it today (the drop menu's 28 is not changed to the DS's 30).
- **The token move.** The DS token block (`:root{--row-step:0px}` plus the two `[data-density]` rules) moves from `components/density.css` into `tokens/spacing.css`. The row rules stay in `density.css`, and its header and readme:100 say the move happened. The parity reader learns `data-density`, and the parity matrix covers all three densities.
- **Zoom.**
  - Steps are `[90, 100, 110, 125, 150]`, default 100. A stored value off the list snaps to the nearest step.
  - Zoom In and Zoom Out move one step. Actual Size goes to 100. Each item is grey at its end (150 / 90 / 100).
  - Shortcuts: ⌘+ (menu `CharacterActivator('+', meta: true)`, and ⌘= also zooms in through a window-root shortcut), ⌘− and ⌘0.
- **Zoom scales a window's content by z = zoom / 100.**
  - Layout runs at size / z. Paint and hit testing are scaled by z.
  - The window's `MediaQuery` gets size, padding, viewPadding and viewInsets divided by z, and devicePixelRatio multiplied by z (rasters stay sharp).
  - The measured traffic-light rect is divided by z, so the bar rule holds in zoomed units. The native traffic lights never scale.
  - Live, app-wide, remembered. It multiplies with density.
- **Window minimums scale.**
  - Every open window with a minimum gets constraints = spec × z (min and max) on a zoom change. A window below its new minimum grows to it; a larger one keeps its frame.
  - A window created at zoom z is created with scaled constraints and a size of at least the scaled minimum.
  - Settings (content-sized) is scaled by its `SettingsHeightFollower`: minimum 620 × 420 × z, follow cap 740 × z, content height × z. While following, its width scales too.
  - The runner grows a restored full frame to the window's content minimum.
- **Coordinates under zoom.** Every site that mixes `localToGlobal` / `globalToLocal` / `event.position` with a local size, or that places an overlay from global coordinates, uses transforms. This keeps menus, selects, drags and hit tests aligned under zoom.
- **Strings** go in `app/lib/l10n/app_en.arb` and through `flutter gen-l10n`:
  - The Density hint: "Space between rows and cards. Text keeps its size."
  - The Zoom row: hint "Text and everything with it, in every window. ⌘+ ⌘− ⌘0"; options "90%" … "100% (Actual Size)" …
  - The menu items Zoom In, Zoom Out, Actual Size.

**Never:**
- Per-window density or zoom.
- A custom scale.
- Zooming the splash window, which shows before the settings load.
- Rust, FFI or `zanshin_core` changes.
- Changing control heights, island or bar sizes, radii or text sizes per density.
- Lowering a test's expectations to hide a misaligned overlay.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|---|---|---|---|
| Density Comfy | Settings › Density = Comfy | every window: menu rows 34, settings rows min 52 with padding 11, graph detailed cards 74 and gaps 68 × 60; text unchanged | — |
| Density back | Comfy → Compact | tokens equal `ZsMetrics.standard` again | — |
| Zoom In | zoom 100, ⌘+ | `appearance.zoom` = 110; every window renders ×1.1; minimums ×1.1 | — |
| Zoom at end | zoom 150 | Zoom In grey; ⌘+ does nothing | — |
| Stored 95 | settings file `"zoom": 95` | treated as 90 (nearest step; a tie goes to the lower step) | — |
| Window too small | project window 900 × 600, zoom 110 (min 968 × 616) | the window grows to 968 × 616 | — |
| Window large | 1400 × 900, zoom 125 | frame kept, content larger | — |
| Settings follows | zoom 125, tab content 500 high | window content height 625, width 775 | — |
| Tap under zoom | zoom 150, menu opened from a button | menu sits under the button; a click on a row hits that row | — |
| Restored small frame | saved 880 × 560 frame, zoom 125 | restored at ≥ 1100 × 700 | — |

</intent-contract>

## Code Map

- `packages/zanshin_ui/lib/src/design/zs_metrics.dart`
  - `ZsMetrics` is `@immutable` with a hand-written `copyWith` (:489), `toCss()` (:652, cards and gaps at :713-719), `==` and `hashCode`.
  - `resolve(ZsAppearance)` (:129-145) applies full screen, traffic lights and contrast. Add `rowStep` and the density set here.
  - `standard` is at :154. Card and gap fields are at :204-210.
- `packages/zanshin_ui/lib/src/design/zs_appearance.dart:152-230` -- `ZsAppearance` fields, `copyWith` and `==`. Add `ZsDensity density` (default compact). It is exported through `zanshin_ui.dart`.
- `packages/zanshin_ui/test/design/css_token_reader.dart`
  - `_attributes` :35-43 (add `data-density`).
  - `_matches` :245-257 (`'density' => appearance.density.name == value`).
  - `readFiles` :124-128 reads only the `tokens/` imports.
- `packages/zanshin_ui/test/design/ds_parity_test.dart:21-47,177` -- appearance matrix; add density.
- Rows in `zanshin_ui`:
  - `controls/zs_menu.dart` `_Row` `_height = 28` (:1068). Menu placement at :690 is `localToGlobal & size`.
  - `controls/zs_select.dart` `_row = 28` (:180). Hit check at :334 is `localToGlobal & row.size` vs `event.position`.
  - `controls/zs_skeleton.dart:149` (row 30).
  - `controls/zs_popover.dart` `ZsOptionRow._minHeight` :135, `ZsOptionLink._minHeight` :201 (36).
  - `controls/zs_field_list.dart` `ZsFieldListRow._minHeight` 34 (:173, applied :231).
  - Also `zs_slider.dart:152` (`globalToLocal`).
- Rows in the app:
  - `features/graph/graph_stack_popover.dart:17` `graphStackRowHeight = 28`.
  - `features/graph/graph_drop_menu.dart:19` `_rowH = 28`.
  - `features/projects/projects_window.dart:1197` `_NavRow` height `controlMd`.
  - `features/projects/projects_tree.dart:176,179` `groupHeight 28`, `projectHeight 44` (used by drag and drop math: `:715` `globalToLocal`, `:1101`).
  - `features/sync/push_sheet.dart:932` `_RowShell` padding vertical 7.
  - `features/settings/settings_widgets.dart` `SettingsRow` :165/:169 (46 / 8), stack :168 `fromLTRB(14,10,14,12)`, nav :199/:201.
  - `features/settings/remotes_group.dart:158,160`.
  - `features/graph/revset_configs/revset_configs_window.dart:730,732` (`.zs-rsd-opt`).
  - `features/graph/graph_inspector.dart:2345` `InspectorFileRow` padding vertical 6.
- `app/lib/src/features/graph/graph_canvas.dart`
  - `:1378` `GraphMetrics.fromOptions(widget.options)` (always `ZsMetrics.standard`). Pass `tokens: ZsMetrics.of(context)`.
  - `didUpdateWidget` :419-427 and `didChangeDependencies` :335 call `_scheduleContent()` when the tokens change.
  - `GraphRouteCache.geometryFor` (`graph_edges.dart:106-173`) already reroutes geometry only when the metrics change.
  - Card renderers read `ZsMetrics.of(context)` (`graph_stack_card.dart:169,484`, `graph_card_render.dart:559`).
  - Other global-coordinate sites: `graph_card_menu.dart:561`, `graph_gap_legend.dart:155`, `graph_drag.dart:673`, `graph_viewport_render.dart:210-216`.
- `app/lib/src/features/window/zanshin_window_root.dart:57-95`
  - Remove `textScaleOf` and the textScaler `MediaQuery`.
  - Pass the density into `ZsRoot`'s appearance.
  - Add the zoom box and its MediaQuery, divide the traffic lights by z, and add the ⌘= shortcut.
  - VM: `app/lib/src/features/app/zanshin_app_view_model.dart:35` (`density`). Add `zoom` and `setZoom`.
- `app/lib/src/features/window/app_windows.dart`
  - `create` :283-317 and `_create` :319-342 (scale constraints and size).
  - `_open` :229 (record the spec constraints and whether the window is content-sized).
  - `controllerOf` :269.
  - Engine: `WindowController` and `DialogWindowController` have `contentSize`, `setSize` and `setConstraints` (`flutter/lib/src/widgets/_window.dart:369-381, 693-705`).
- `app/lib/main.dart:129-201` -- `_startApp` and `appWindowCoordinator`. Bind the zoom before `coordinator.start()` and hand it to `appMenu.attach`.
- `app/lib/src/features/shell/app_menu.dart`
  - `AppMenuModel` :102, `attach` :131.
  - The View menu :458-516: add a Zoom group before the full-screen group.
  - Test: `app/test/features/shell/app_menu_test.dart`.
- `app/lib/src/features/settings/settings_window_sizer.dart:22-103` (`SettingsHeightFollower`) and its binding `settings_window.dart:196-235`.
- `app/lib/src/features/settings/general_tab.dart:94-109` -- Density row (`ZsSegmented`). The Zoom row goes after it, with `ZsSelect` (pattern in `project_tab.dart:228`).
- `packages/zanshin_settings/lib/src/model/appearance_settings.dart:46` -- add `@Default(100) int zoom` after `density`, then regenerate (`dart run build_runner build -d` in the package).
  - Tests: `test/model/app_settings_test.dart`, `test/settings_store_test.dart:17` (fixture).
- `app/macos/Runner/MainWindowChrome.swift:73` -- the hard-coded `minSize 880×560` would block 90 %. Remove it: the Dart constraints set the content minimum.
- `app/macos/Runner/WindowFrameStore.swift:168-171` -- `.full` restore: grow the saved size to `contentMinSize`.

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_settings/.../appearance_settings.dart` -- `zoom` field, regenerated code, tests (default, round trip, fixture).
- `packages/zanshin_ui/lib/src/design/` -- `ZsDensity`; `ZsAppearance.density`; `ZsMetrics.rowStep` (`toCss` `--row-step`); `resolve` applies the set.
- `packages/zanshin_ui` controls -- the rows above read `ZsMetrics.of(context).rowStep`, keeping geometry constants consistent (select or menu height math).
- `packages/zanshin_ui` coordinate sites -- `zs_menu.dart:690` and `zs_select.dart:334` (and any other site that mixes coordinates) use transforms.
- `packages/zanshin_ui` tests -- per-density resolve; rows grow by the step; parity test over the densities.
- DS -- move the token block to `tokens/spacing.css`; update the `density.css` header and readme:100. Add a one-line amendment to readme's sync #21 entry (:39).
- `app/lib/src/features/window/window_zoom.dart` (new):
  - `zoomSteps`, `zoomStepOf`, `zoomInFrom`, `zoomOutFrom`, `zoomScaleOf`.
  - `WindowZoomBox` (RenderBox: layout constraints / z, size × z, paint / hit test / `applyPaintTransform` scaled).
  - `bindWindowZoom(SettingsStore, AppWindows)` (initial value plus a listener; returns a dispose).
- `app/lib/src/features/window/app_windows.dart` -- the `zoom` getter and setter. The setter re-applies the scaled spec constraints to every open window that is not content-sized, growing any window below its minimum. `create` uses the scaled constraints and size.
- `app/lib/src/features/window/zanshin_window_root.dart` + VM:
  - Density goes into the appearance; the text scale is gone.
  - The zoom box and MediaQuery.
  - Traffic lights divided by z.
  - ⌘= zooms in, through `CallbackShortcuts`.
- `app/lib/src/features/settings/` -- the follower takes the zoom (from `SettingsWindow`'s store); Density hint; Zoom row (identifier `settings-zoom`).
- `app/lib/src/features/shell/app_menu.dart` -- Zoom In / Zoom Out / Actual Size, greyed at their ends, writing `appearance.zoom`. The model listens to the settings.
- The app's rows (Code Map) and coordinate sites -- the density step; transforms under zoom.
- `app/lib/src/features/graph/graph_canvas.dart` -- the metrics follow `ZsMetrics.of(context)`, and a change reschedules the content.
- `app/macos/Runner/*.swift` -- drop the native minSize; grow a restored frame to its minimum.
- `app/lib/l10n/app_en.arb` -- the strings above; `flutter gen-l10n`.
- Tests:
  - `window_zoom_test.dart` (steps and snap; the box's layout, paint size and a hit at a scaled position; `bindWindowZoom`).
  - `app_windows_test.dart` (scaled create; zoom change grows a small window, keeps a large one, skips Settings).
  - `zanshin_window_root_test.dart` (density reaches `ZsMetrics`, text scale 1; zoom scales content and MediaQuery; traffic lights divided).
  - `settings_window_sizer_test.dart` (zoomed minimum, cap and height).
  - `app_menu_test.dart` (items, shortcuts, grey at the ends, writes).
  - The settings General tab test (Zoom row, Density hint).
  - A graph test (detailed card height 74 and gap y 60 at comfy).
  - Row tests for settings rows and the menu under density.

**Acceptance Criteria:**
- Given any open window, when Density changes, then the named rows, graph card heights and gaps take the new set in that window without a restart, and text sizes stay.
- Given zoom 125 %, when any window shows, then its content is drawn 1.25× larger, the bar's first island sits at the traffic-light block's end + 12 zoomed units, and the native buttons are unscaled.
- Given zoom 150 %, when the View menu opens, then Zoom In is grey and Zoom Out and Actual Size are enabled.
- Given a menu or select opened under zoom 125 %, when it shows, then it is anchored at its trigger and a click on a row selects that row.
- Given the DS parity test, when it runs, then `--row-step`, cards and gaps match the DS for every density.

## Review Triage Log

### 2026-11-07 — Review pass
- verdicts: 31 findings — high 0, medium 6, low 17, false 3, maybe-false 5
- findings:
  - `[low]` `[patch]` (blind) `density.css:NN` citations in the new comments use pre-move line numbers (off by 6). Fixed: they now cite the selector.
  - `[low]` `[patch]` (blind) `tokens/spacing.css:56-58` is off by one. Fixed: corrected to :55-57.
  - `[low]` `[patch]` (blind) The readme's sync #21 entry contradicts its own amendment. Fixed: the parenthesis is rewritten.
  - `[low]` `[reject]` (blind) A window in `_creating` misses a zoom change. It needs a zoom change during the few ms a window is being created, and it corrects itself on the next change; the fix adds a branch.
  - `[low]` `[reject]` (blind) `AppWindows.zoom` compares sizes exactly. A same-size `setSize` is a no-op for AppKit, and the tolerance would add a helper.
  - `[medium]` `[patch]` (blind) ⌘= is a window-root `CallbackShortcuts`, so it never fires while the primary focus is `FocusManager.rootScope` (focus_manager.dart:2238 dispatches from the primary focus; with nothing focused that is the root scope above every window). Fixed: one app-wide `HardwareKeyboard` handler in `bindWindowZoom`, tested with nothing focused. This deviates from the spec's "window-root shortcut" mechanism; the outcome (⌘= zooms in) is the contract.
  - `[low]` `[reject]` (blind) A grown restored frame is not clamped to the screen. It only matters for a frame saved near the screen's bottom edge and restored at a higher zoom; the fix adds screen geometry.
  - `[low]` `[reject]` (blind) The menu rebuilds on every settings write. A rebuild re-sends an unchanged menu; a zoom-only filter adds state.
  - `[low]` `[patch]` (blind) The canvas reschedules on any token change. Fixed: it compares only the card heights and gaps.
  - `[false]` `[reject]` (blind) `ZsAppearanceOverride` has no density knob. The witnesses check one window per density in the running app, switched through Settings › Density; the catalogue is not needed for it.
  - `[low]` `[patch]` (blind) Density call sites are untested. Fixed: comfy-height tests for the field-list row, option row, skeleton row, project tree row and stack popover.
  - `[medium]` `[patch]` (blind) Zoom coordinate fixes are untested. Fixed: tests for `ZsResizeEdge` under scale and for the graph drag origin under `WindowZoomBox`.
  - `[low]` `[reject]` (blind) The zoom write is duplicated without a snap. The menu and the select only write step values (`zoomInFrom` / `zoomOutFrom` / the select's options), so nothing unsnapped is ever written.
  - `[low]` `[reject]` (blind) `zoomedMediaQuery` skips `systemGestureInsets` and `displayFeatures`. Both are empty on macOS, the only platform.
  - `[maybe-false]` `[defer]` (blind) The native minSize removal relies on Dart's constraints reaching the main window. To settle it: resize the running project window at 90 % and 100 %. Merged into the running-app deferred item.
  - `[low]` `[reject]` (edge) A window in `_creating` misses a zoom change. Same as the blind finding.
  - `[maybe-false]` `[reject]` (edge) A zoom change while following with no content height yet keeps the old height. `_content` is null only before the first frame's measure, which reports right after; low if real.
  - `[medium]` `[patch]` (edge) ⌘= without focus. Same fix as the blind finding.
  - `[low]` `[reject]` (edge) The visible region jumps after a density switch. The Detailed Cards and card-width toggles already behave this way (the same `_scheduleContent` remap); anchoring is a separate feature.
  - `[low]` `[reject]` (edge) Exact size compare. Same as the blind finding.
  - `[medium]` `[patch]` (verification-gap) Coordinate fixes are never exercised under a scale. Fixed: the same tests as the blind finding.
  - `[medium]` `[patch]` (verification-gap) The `DialogWindowController` zoom branch is unobserved. Fixed: Projects opened at 700 × 450 grows to 850 × 550 at 1.25.
  - `[medium]` `[patch]` (verification-gap) Settings store→follower zoom wiring is untested. Fixed: a test asserts min 775 × 525 at 125.
  - `[low]` `[patch]` (verification-gap) Per-row density is untested; the stack popover callout must align. Fixed: the comfy tests above.
  - `[low]` `[reject]` (verification-gap other) `_creating` misses a zoom. Same as the blind finding.
  - `[false]` `[reject]` (intent) The stacked settings row has 10/12 padding where the DS has 10/10. The spec keeps each row's base as the code has it and adds only the step; 10/12 predates this story.
  - `[false]` `[reject]` (intent) The push row has no `min-height: control-lg + step`. The code's row is padding-sized; the base is unchanged and the step is added as half above and half below, as for a padded row.
  - `[maybe-false]` `[defer]` (intent) Graph density is tested by injecting the appearance, not through Settings. The Settings → view model → `ZsMetrics` path is tested in `zanshin_window_root_test`; the end-to-end check belongs to the running-app item.
  - `[maybe-false]` `[defer]` (intent) Native menu dispatch of `CharacterActivator('+')` and the native window behaviour are unexercised. To settle it: the running app. Merged into the running-app item.
  - `[maybe-false]` `[defer]` (intent) No running-app check against the DS cards. Merged into the running-app item.
  - `[low]` `[reject]` (intent) Bookkeeping (sprint-status, deferred-work) is not in the diff. It is done in this run's docs commit.

## Design Notes

**Zoom as a render box, not a DPR override.** Pointer events are divided by the real `FlutterView.devicePixelRatio` in `GestureBinding`, which cannot be overridden per window. So the root wraps the content in a box that lays it out at size / z and paints it scaled. Global positions are then window coordinates, so local sizes must be mapped through transforms. Sketch:

```dart
performLayout: child.layout(constraints / z); size = constraints.constrain(child.size * z);
paint: context.pushTransform(needsCompositing, offset, Matrix4.diagonal3Values(z, z, 1), super.paint);
hitTestChildren: result.addWithPaintTransform(transform: Matrix4.diagonal3Values(z, z, 1), position: p, hitTest: ...);
```

A content-sized Settings window gets unbounded or max constraints; size = child × z reports the scaled content size.

**Who scales which minimum.** `AppWindows` owns the windows with a spec minimum. Settings' minimum is set by its follower after the first frame (content-sized creation refuses a minimum), so the follower scales it.

## Verification

**Commands** (gate rule: no `cargo make test`, `test-full` or `coverage`):
- `dart run build_runner build -d` (packages/zanshin_settings) -- regenerated and committed.
- `flutter test` + `dart analyze` + `dart format --set-exit-if-changed .` in `packages/zanshin_settings` and `packages/zanshin_ui` -- green.
- `flutter gen-l10n` (app/); `cargo make test-app test/features` -- green; `dart analyze .` and `dart format --set-exit-if-changed lib test widgetbook` (app/) -- clean.
- `xcrun swiftc -parse` on the two Swift files -- they parse.

**Manual checks:**
- Marionette per density and zoom vs the DS cards *Density* and *Settings* (needs the running app).

## Auto Run Result

Status: done

**Summary.**
- **Density** (Settings › General, Compact · Balanced · Comfy) adds space only.
  - `ZsAppearance.density` (new `ZsDensity`) switches the `ZsMetrics` set in every window, live: `rowStep` 0 / 3 / 6, cards 40/62 · 44/68 · 48/74, gaps 56×48 · 62×54 · 68×60.
  - The listed rows add the step: menu, select, drop menu, stack popover, skeleton, option rows, search field-list rows, settings / remotes / revset-option rows, the Projects nav and tree rows, inspector file rows and push rows.
  - The graph canvas takes its metrics from the context and reroutes the geometry when they change.
  - The 12.5 / 13 / 13.5 text scale is gone.
  - The DS token block moved from `components/density.css` to `tokens/spacing.css`. The parity reader knows `data-density`, and the matrix runs all three densities.
- **Zoom** is the new `appearance.zoom` setting, default 100; a value between steps snaps to the nearest step.
  - Steps 90 · 100 · 110 · 125 · 150, set from Settings › General › Zoom (`ZsSelect`, `settings-zoom`) or View › Zoom In ⌘+ / Zoom Out ⌘− / Actual Size ⌘0, each greyed at its end. ⌘= also zooms in, through an app-wide key handler.
  - Each window's content sits in a `WindowZoomBox`: it lays out at size ÷ z and paints and hit-tests at × z, with a zoomed `MediaQuery` (DPR × z). The traffic-light block is divided by z, so the native buttons stay as they are.
  - Window minimums scale and a smaller window grows: `AppWindows.zoom` for windows with a spec minimum, `SettingsHeightFollower` for Settings (620 × 420 × z, follow cap 740 × z).
  - The runner drops the hard-coded 880 × 560 `minSize` and grows a restored frame to the content minimum.
  - Global ↔ local coordinate sites now go through transforms: menu safe triangle, select drag-release, resize edge, drag ghost and drop origin, viewport mapping, gap legend.

**Files changed:**
- `packages/zanshin_settings`: `appearance_settings.dart` (+ generated), tests.
- `packages/zanshin_ui`:
  - `zs_appearance.dart`, `zs_metrics.dart`, `zanshin_ui.dart` (export).
  - Controls: `zs_menu`, `zs_select`, `zs_popover`, `zs_field_list`, `zs_skeleton`, `zs_resize_edge`.
  - Tests (tokens, parity reader + matrix, rows at comfy, zoomed menu / select / resize edge).
- Design system: `tokens/spacing.css`, `components/density.css`, `readme.md` (Density and zoom, sync #21 entry).
- `app/lib/src/features/window/`: `window_zoom.dart` (new: steps, `WindowZoomBox`, `zoomedMediaQuery`, `bindWindowZoom` + ⌘=), `app_windows.dart`, `zanshin_window_root.dart`.
- `app/lib/src/features/app/zanshin_app_view_model.dart`.
- `app/lib/main.dart`.
- `app/lib/src/features/shell/app_menu.dart`.
- `app/lib/src/features/settings/`: `general_tab.dart`, `settings_widgets.dart`, `remotes_group.dart`, `settings_window.dart`, `settings_window_sizer.dart`.
- Graph: `graph_canvas`, `graph_drag`, `graph_drop_menu`, `graph_gap_legend`, `graph_inspector`, `graph_stack_popover`, `graph_view`, `revset_configs_window`.
- Projects: `projects_tree`, `projects_window`.
- `app/lib/src/features/sync/push_sheet.dart`.
- l10n: `app_en.arb` + generated files.
- `app/macos/Runner/MainWindowChrome.swift`, `WindowFrameStore.swift`.
- App tests: `window_zoom_test`, `graph_density_test` (both new), `app_windows_test`, `zanshin_window_root_test`, `settings_window_sizer_test`, `settings_window_test`, `app_menu_test`, `graph_drag_test`, `graph_stacks_test`, `projects_window_test`, `fake_windows`.

**Review findings.** 31 findings: medium 6, low 17, false 3, maybe-false 5.
- **Patched** (13 rows; 4 medium entries after grouping, the rest low):
  - ⌘= now works without focus: a `HardwareKeyboard` handler replaces the window-root `CallbackShortcuts`. This deviates from the spec's stated mechanism; the outcome holds.
  - Stale CSS line citations corrected.
  - The readme sync #21 entry no longer contradicts itself.
  - The canvas reschedules only on card or gap changes.
  - Tests added: zoomed resize edge and drag origin, dialog-window zoom growth, Settings store→follower zoom, rows and stack popover at comfy.
- **Deferred:** 4 maybe-false rows, merged into one Medium item: the running-app and native check.
- **Rejected:** 12 low and 3 false, with reasons in the Review Triage Log. The low ones: a window in `_creating` missing a zoom change, the exact size compare, no screen clamp on the restored frame, the menu rebuilding on every settings write, the duplicated zoom write, `zoomedMediaQuery`'s partial fields, the follower's null content, scroll anchoring on a density switch, bookkeeping. The false ones: the catalogue density knob, the stacked-row 10/12 padding, the push-row minimum.

**Follow-up review recommendation:** false. This pass patched 4 medium entries and no high. The two code changes (the ⌘= handler and the canvas comparison) are each covered by a targeted test that ran green. The remaining risk is native and unverifiable here (the deferred item); no named unverified risk remains in the patched code.

**Deferred-work item I1** ("Density has no tokens"): fixed in commit 8b364e7a023bb624dd56f20413b2c4defc0a0b39.
- `ZsMetrics` carries a set per density and the listed components read it.
- The DS tokens live in `tokens/spacing.css` and are checked by the parity test.
- The client's density no longer changes the text size.

**Commits:** 8b364e7a023bb624dd56f20413b2c4defc0a0b39 (the story), plus this record's docs commit (spec, sprint-status, deferred-work).

**Verification** (gate rule of this run: no full gate):
- `dart run build_runner build -d` (packages/zanshin_settings): regenerated and committed.
- `flutter test` in packages/zanshin_ui: 459 passed. `dart analyze`: no issues.
- `flutter test` in packages/zanshin_settings: 44 passed. `dart analyze`: no issues.
- `flutter gen-l10n` (app/): ran.
- `cargo make test-app test/features`: 1694 passed. `flutter test test/l10n`: 5 passed.
- `dart analyze .` (app/): no issues.
- `dart format --set-exit-if-changed` over app lib/test/widgetbook and both packages: 0 changed.
- `xcrun swiftc -parse` on `MainWindowChrome.swift` and `WindowFrameStore.swift`: they parse.
- Not run: the Marionette and running-app check (deferred); the full gate (the loop runs it); no Rust touched.

**Residual risks.**
- AppKit's handling of `contentMinSize` once the native `minSize` is gone.
- Whether `CharacterActivator('+')` fires from the native menu on a real keyboard (⌘= is covered either way).
- Engine `setSize` / `setConstraints` ordering when a window grows on a zoom change.
- Overlay or coordinate code outside the audited sites that mixes global positions with local sizes would be misplaced at zoom ≠ 100 %.
- The catalogue has no density or zoom knob (`ZsAppearanceOverride`), so a per-density Marionette check goes through the app's Settings.
