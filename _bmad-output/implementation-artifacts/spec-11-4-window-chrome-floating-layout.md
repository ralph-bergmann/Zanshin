---
title: 'Story 11.4 — Window chrome for the floating layout: traffic lights in the bar row, drag region, canvas background, minimum size'
type: 'feature'
created: '2026-10-18'
status: 'done'
baseline_revision: '85d52896aa8487d306e0880541ba738536a616ba'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['multiple-goals', 'oversized']
deferred:
  - summary: >-
      AppKit posts no didFailToEnterFullScreen notification: WindowChromeHost clears its entering flag on didEnter/didExit or after a 2 s fallback (deferred-work.md, Surfaced in Story 11.4).
    evidence: |-
      NSWindow has no such notification; only the window delegate (the engine's) hears windowDidFailToEnterFullScreen(_:), and flutter build macos failed on the name. The host takes an entry that has not arrived after enterFullScreenTimeout (2 s, Claude's proposal) as failed.
    location: >-
      packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/WindowChromeHost.swift
    severity: low
  - summary: >-
      The native half (rings and their theme switch, full screen, the opaque rounded window, the 880 x 560 drag stop, Multicolor tint) is unseen from this seat: Ralph's manual checks (deferred-work.md, Surfaced in Story 11.4).
    evidence: |-
      No Swift test target exists and cargo make test never compiles Swift; this seat has neither screen recording nor accessibility and runs the Orange accent. The live run saw one block report (x 19-79, centre y 26) and Marionette's bar geometry only. Review pass 2026-10-18 (verification gap, intent auditor): the measurement's flip, number types, entering flag and change-only sends are exercised by no test.
    location: >-
      app/macos/Runner/MainWindowChrome.swift; packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/WindowChromeHost.swift
    severity: medium
  - summary: >-
      The catalogue's windows wear the app's chrome but their roots have no WindowChromeBuilder, so the real Windows › Floating shell window lays the bar out from the reference geometry and ignores full screen.
    evidence: |-
      Review pass 2026-10-18 (blind hunter, verification gap): app/widgetbook/folders/windows.dart opens the window through AppWindows.create (chrome: true, app/lib/src/features/window/app_windows.dart), and its root is catalogueAppBuilder, a ZsRoot without the builder (app/widgetbook/catalogue.dart); in full screen there the first island stays at 91 / 4 and the drag row at 60. On this Mac the measured block equals the reference, so the catalogue check could not tell the two apart.
    location: >-
      app/widgetbook/catalogue.dart
    severity: low
---

<intent-contract>

## Intent

**Problem:** The project window still wears the docked design's chrome: a vibrancy view under a transparent Flutter view supplies background and corners, the grey rings are `NSColor.gray`, the minimum is 900 × 600, the runner has no AccentColor asset (so a Multicolor Mac resolves to Blue, ledger I1), Dart lays the bar out from the DS reference geometry instead of the measured traffic lights, nothing drives `ZsAppearance.fullScreen` (I2), and `HomePage` carries 11.3's two stand-ins — the drag row and a flat `--canvas-base` fill (I3).

**Approach:** `zanshin_shell` measures each Flutter view's standard window buttons and full-screen state and reports changes; a window-root builder feeds the report into `ZsAppearance` (`fullScreen` plus the measured block), whose metrics derive the bar, so 11.3's shell follows. `zanshin_ui` gains `ZsCanvas`, the DS's two static shaders, which `HomePage` passes as the canvas beside its permanent drag row. The runner drops the vibrancy view for an opaque window the system rounds, strokes the rings in `--tl-ring` per appearance, moves the minimum to 880 × 560 and ships the AccentColor colour set.

## Boundaries & Constraints

**Always:**
- epics.md Story 11.4 (:12183-12257) is the requirement; its "Design update 2026-10-16" (:12186-12213) supersedes items 1, 2, 4, 5, the witnesses and the design status it names; decisions 16.2, 16.5, 16.37 (:11545, :11548, :11597) apply. DS = `_bmad-output/implementation-artifacts/design_system/`. Precedence: epics decisions > DS tokens/CSS > DS prose/cards > the floating export.
- The native buttons are never moved or resized; the toolbar and the titlebar accessory that place them (MainWindowChrome.swift:66-72) stay. The bar derives from the measured block: first island at block end + 12, bar centred on the block's centre line, content top at bar bottom + 12 (DS tokens/spacing.css:25-39).
- Every colour comes from 11.1's tokens. A colour the runner needs natively (accent, ring, window background) lives in an asset-catalogue colour set whose values a Dart test checks against the token; Swift never writes a colour literal.
- Channel style as the folder drops: `bad-args` for malformed calls, `unknown-view` for an id no attached Flutter view has; absence is null, never a sentinel.
- SPDX first line, page width 120, `dart analyze --fatal-infos --fatal-warnings` clean in every touched package; every open default carries "Claude's proposal" in a doc comment; DS literals cite `DS <file>:<line>`.
- The app imports only `package:zanshin_ui/zanshin_ui.dart` and `package:zanshin_shell/zanshin_shell.dart` (no `src/` imports).

**Never:**
- No key-status / inactive plumbing, no per-window roots for dialog windows, no parameterised `MainWindowChrome` (11.12); no menu bar or Enter Full Screen item (11.13); no slot content (Epic 10, 11.5, 11.8); no change to 11.3's layout rules beyond the metrics they already read.
- No `NSVisualEffectView` or any other view below the Flutter view; no private AppKit API (e.g. a `_cornerRadius` key); no Swift colour literals.
- No golden tests; no edits under `design/` or `design_system/`; no token value change; never lower the coverage baseline.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Measured block | report `{fullScreen: false, trafficLights: Rect.fromLTWH(19, 19, 60, 14)}` | `chromeFirstX` 91, `chromeBarY` 4, `chromeTop` 60; first island x 91, bar 4–48, drag row 0–60 | — |
| Another block | `Rect.fromLTWH(20, 20, 60, 14)` (centre y 27) | first island 92, bar top 5, `chromeTop` and drag row 61 | — |
| Full screen | report `{fullScreen: true, trafficLights: null}` | first island 12, bar top 12, `chromeTop` and drag row 68; rail stays at left 12 | — |
| Full screen wins | `ZsAppearance(fullScreen: true, trafficLights: <any>)` | the full-screen values | — |
| No report | before the answer, off macOS, or `watch` failed | DS reference geometry (91 / 4 / 60) | failure logged at warning; chrome stays null |
| Foreign view | `changed` for another `viewId` | ignored | — |
| Equal report | the same report again | no rebuild (native emits only changes; Dart drops equals) | — |
| Unmount | the builder leaves the tree | stream cancelled, `unwatch(viewId)` sent; a late `watch` answer is dropped | — |
| Malformed push | `changed` without `viewId` or with a non-bool `fullScreen` | `PlatformException(bad-args)` reply | native ignores the reply |
| Unknown view | `watch` for an id with no attached controller | `PlatformException(unknown-view)` | the builder logs it; reference geometry |
| Canvas | `ZsCanvas` over a 1000 × 800 box, night | linear 165° base then the radial lift: centre (100, −96), radius 1150, y scaled by 680 / 1150 about the centre, stops 0 and .62 | an empty box paints nothing |

</intent-contract>

## Code Map

- `_bmad-output/planning-artifacts/epics.md:12183-12257` -- Story 11.4 (read the 2026-10-16 update :12186-12213 first: measured block, rings, drag to 60, minimum 880 × 560, full-screen geometry, items 7 and 8, amended witnesses); :11545 (16.2 accent), :11548 (16.5 traffic lights), :11597 (16.37 minimum).
- `app/macos/Runner/MainWindowChrome.swift` -- `setupWindowAppearance` :49-73 (`backgroundColor = .clear`, `isOpaque = false`, `minSize` 900 × 600 at :58, toolbar + `TitlebarAccessoryController` :66-72 keep); `installVibrancyView` :90-110 and its calls in `handleWindowDidBecomeKey` :210-213 and `handleWindowDidExitFullScreen` :223-227 (go); `TrafficLightOverlayView` :260-612 (ring stroke `NSColor.gray` :312, doc :254-259 "no theme handling"); `EventTransparentEffectView` :643-670 (orphaned once the vibrancy view goes).
- `app/macos/Runner/Assets.xcassets/` -- holds only `Contents.json`; a folder reference (`Runner.xcodeproj/project.pbxproj:73`), so new `.colorset` folders are picked up as they are.
- `app/macos/Runner.xcodeproj/project.pbxproj:496-499, :630-633, :652-655` -- the Runner target's Debug/Release/Profile settings with `ASSETCATALOG_COMPILER_APPICON_NAME = NamiIndigo;` (the accent setting goes beside it); deployment target 12.0 (:486).
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/ZanshinShellPlugin.swift` -- `init` :28-32 owns `FolderDropHost` (the new host sits beside it); class doc :6-12.
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FolderDropHost.swift` -- the pattern for a per-view host (channel, `bad-args`/`unknown-view`); its private `flutterViewController(_:)` :70-81 is the lookup the new host needs too.
- `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart` -- `ZanshinShellMacOS`: lazily installed handler for the theme channel :20-35, folder-drop channel :18, :83-116 (pattern for the window-chrome channel).
- `packages/zanshin_shell_platform_interface/lib/src/{zanshin_shell_platform.dart,shell_theme.dart}`, `lib/zanshin_shell_platform_interface.dart` -- the interface (`setWindowAppearance` doc :48 says "blur background"), value-class style of `ShellTheme` (==, hashCode, toString), the export list.
- `packages/zanshin_shell/lib/{zanshin_shell.dart,src/zanshin_shell.dart}` -- the facade (`setWindowAppearance` doc :21 says "blur background") and its export `show` list.
- Tests: `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart` (value class + unimplemented defaults), `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart` (mock `MethodChannel` pattern :8-33), `packages/zanshin_shell/test/zanshin_shell_test.dart` (`RecordingPlatform` :11-70).
- `packages/zanshin_ui/lib/src/design/zs_appearance.dart` -- `ZsAppearance` :151-253 (fields, `fromShell` :167-182 whose doc says full screen stays false, `copyWith`, ==, hashCode, toString); `ZsAppearanceOverride` :269-328 (unchanged).
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart:126-138` -- `ZsMetrics.resolve` (full screen sets `tlBlockW` 0, `tlX` 0, `tlMidY` 34); `chromeFirstX`/`chromeBarY`/`chromeTop` derive from `tlX`, `tlBlockW`, `tlMidY` (:346-353).
- `packages/zanshin_ui/lib/src/design/zs_values.dart` -- `ZsLinearGradient.resolve` :199-245 (stop-position rules) and `createShader` :249-252; `ZsRadialGradient` :267-317 (no paint maths yet); `ZsCanvasGradient` :320-345; `ZsColors.canvas`/`canvasBase`/`tlRing` (`zs_colors.dart:760-769`; night :326-347, paper :508-529); `ZsColors.toCss()` (:1712) has `--accent-native(-dark)`.
- `packages/zanshin_ui/lib/zanshin_ui.dart` -- exports (materials :48-54); tests `test/design/{zs_values_test.dart,zs_tokens_test.dart:320-327 (full-screen resolve)}`, `test/materials/zs_window_fill_test.dart` (a material test pattern), `test/helpers/material_paints.dart`.
- `app/lib/src/features/app/zanshin_app.dart:88-102` -- the macOS branch's `MaterialApp.builder` → `ZsRoot(appearance: …copyWith(theme: …), shellTheme: …)`, where the window's chrome report joins; `zanshin_app_view_model.dart:49-58` (doc "full screen … 11.4"), :75-84 (doc "blur background").
- `app/lib/src/features/home/home_page.dart` -- `FloatingShell(controller:, barRow: WindowDragArea(child: ColoredBox(transparent)))`, doc :14-16 calls both stand-ins.
- `app/lib/src/features/shell/floating_shell.dart` -- docs :22-23 (canvas "until 11.4", barRow "11.4's drag region"), :84-91; canvas default `ColoredBox(canvasBase)` :384; barRow positioned 0 → `chromeTop` :390-397; every chrome position reads `ZsMetrics.of(context)` (:251-350).
- `app/lib/src/features/window/app_windows.dart:17-21` -- `defaultWindowConstraints` 900 × 600 (default of `create`/`openOrActivate` :92, :123); `remembered_window_controller.dart:35` (doc lists the vibrancy background).
- `app/lib/src/features/bootstrap/boot_window_host.dart:68-70` -- `openMain` creates the project window (`main`, default size and constraints).
- `packages/zanshin_shell/lib/src/window_drag_area.dart:15-31` -- `WindowDragArea` (pan → `startWindowDrag`, double tap → `performTitlebarDoubleClickAction`).
- `app/test/helpers/recording_shell.dart` -- the app's fake shell (must answer the new methods); `app/test/features/app/zanshin_app_test.dart:89-116` (`pumpApp`, 1440 × 900), `app/test/features/home/home_page_test.dart` (expects the `canvasBase` `ColoredBox` and the 0–60 drag row), `app/test/features/window/app_windows_test.dart`.
- `app/widgetbook/folders/{materials.dart:10-56, shell.dart:146-168}` -- Materials folder (new Canvas component goes here), `FloatingShellDemo` (pass the canvas); `app/test/widgetbook/catalogue_smoke_test.dart`.
- DS: `tokens/spacing.css:25-39, :50-52`, `tokens/colors.css:22-26, :81-83`, `tokens/accents.css:55-57`, `components/window/TrafficLights.prompt.md:9-12`, `components/window/window.css:1-14`, `readme.md:76, :84, :88, :193`, `ui_kits/desktop/kit.css` (the canvas behind the kit).
- `_bmad-output/implementation-artifacts/deferred-work.md:1214-1219` (I1, I2), `:1332-1334` (I3), `:1226-1228` (the related, still-unverified exact-match item), `:1220-1222` (Swift is never compiled by the gate).

## Tasks & Acceptance

**Execution:**
- `packages/zanshin_shell_platform_interface/lib/src/window_chrome.dart` (+ export) -- `WindowChrome({bool fullScreen = false, Rect? trafficLights})` value class (==, hashCode, toString) and `typedef WindowChromeChange = ({int viewId, WindowChrome chrome})`; `ZanshinShellPlatform` gains `watchWindowChrome(int viewId) → Future<WindowChrome>`, `unwatchWindowChrome(int viewId) → Future<void>`, `onWindowChromeChanged → Stream<WindowChromeChange>`, each throwing `UnimplementedError` by default; fix the "blur background" doc on `setWindowAppearance`.
- `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart` -- channel `zanshin_shell/window_chrome`: `watch {viewId}` → decoded map, `unwatch {viewId}`; native `changed {viewId, fullScreen, trafficLights?}` decoded onto a broadcast stream whose first listener installs the handler (as the theme stream); malformed → `PlatformException(code: 'bad-args')` (Design Notes "Report").
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/FlutterViewLookup.swift` -- move `FolderDropHost`'s controller lookup here as an internal function both hosts call; `FolderDropHost.swift` uses it, unchanged otherwise.
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/WindowChromeHost.swift` -- native half of the channel (Design Notes "Measurement"); `ZanshinShellPlugin.swift` creates it beside `FolderDropHost` and its class doc names it.
- `packages/zanshin_shell/lib/src/zanshin_shell.dart`, `lib/zanshin_shell.dart` -- facade `watchWindowChrome`, `unwatchWindowChrome`, `onWindowChromeChanged`; export `WindowChrome`, `WindowChromeChange`; fix the "blur background" doc.
- `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart`, `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart` (mock the new channel: watch/unwatch arguments, decoding with and without a block, pushed changes on the stream, the bad-args cases), `packages/zanshin_shell/test/zanshin_shell_test.dart` (pass-through) -- their witnesses.
- `packages/zanshin_ui/lib/src/design/zs_appearance.dart` -- `ZsAppearance.trafficLights` (`Rect?`, default null) in the constructor, `copyWith`, ==, hashCode, toString; `fromShell`'s doc: full screen and the block come from the window's chrome report, key status stays 11.12's.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` -- `resolve`: full screen first (unchanged); else a measured block sets `tlX` = left, `tlBlockW` = width, `tlMidY` = centre y (`tlSize`/`tlPitch` keep the reference: only mocks draw them); doc cites DS tokens/spacing.css:25-30.
- `packages/zanshin_ui/lib/src/design/zs_values.dart` -- `ZsRadialGradient.resolve(Rect)` + `createShader(Rect)` (Design Notes "Canvas"); the stop-position rules move into one private helper both gradients use (the linear results unchanged).
- `packages/zanshin_ui/lib/src/materials/zs_canvas.dart` (+ export) -- `ZsCanvas`, a leaf render object painting `ZsColors.of(context).canvas` opaque over its whole box: the linear base, then the radial lift; repaints when the gradient changes (a theme switch lerps it).
- `packages/zanshin_ui/test/{design/zs_values_test.dart,design/zs_tokens_test.dart,design/zs_appearance_from_shell_test.dart,materials/zs_canvas_test.dart}` -- the radial maths of the matrix row "Canvas", the metric rows of the matrix, equality/copyWith of `trafficLights`, and the canvas paint (two rects with shaders over the box, nothing for an empty box, a repaint on a theme change).
- `app/lib/src/features/window/window_chrome_builder.dart` -- `WindowChromeBuilder({required Widget Function(BuildContext, WindowChrome?) builder})` (Design Notes "Report"); logs each applied report at FINE (`zanshin.window`), a failed watch at WARNING.
- `app/lib/src/features/app/zanshin_app.dart` -- the macOS branch's builder wraps `ZsRoot` in `WindowChromeBuilder` and copies `fullScreen` and `trafficLights` from the report into the root's appearance; `zanshin_app_view_model.dart` docs (`appearance`, `setThemeMode`) updated.
- `app/lib/src/features/home/home_page.dart` -- pass `canvas: const ZsCanvas()`; the bar row stays `WindowDragArea` over an opaque transparent box, documented as the drag region of design question (a) (decision (g)), no longer a stand-in.
- `app/lib/src/features/shell/floating_shell.dart` -- docs only: the canvas default is a plain `--canvas-base` fill for hosts that pass none (the project window passes `ZsCanvas`); the bar row is the window's drag region (11.4).
- `app/lib/src/features/window/app_windows.dart` -- `defaultWindowConstraints` = 880 × 560 (decision 16.37), doc: the project window's minimum; 11.12's dialog windows pass their own; `remembered_window_controller.dart:35` doc without the vibrancy background.
- `app/macos/Runner/Assets.xcassets/{AccentColor,CanvasBase,TrafficLightRing}.colorset/Contents.json` -- sRGB, any + dark (`luminosity dark`): AccentColor #4757a1 / #5162ad, CanvasBase paper #f0ece7 / night #12162a, TrafficLightRing paper rgba(58,46,34,.30) / night rgba(255,255,255,.26); 8-bit components as `0xNN` strings, alpha as a 3-decimal string.
- `app/macos/Runner.xcodeproj/project.pbxproj` -- `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor;` in the Runner target's Debug, Release and Profile settings (beside the app-icon line) (I1).
- `app/macos/Runner/MainWindowChrome.swift` -- Design Notes "Window": `minSize` 880 × 560; opaque window on `NSColor(named: "CanvasBase")`; the Flutter view stays clear; remove `installVibrancyView`, `vibrancyView`, their calls and `EventTransparentEffectView`; the overlay strokes `NSColor(named: "TrafficLightRing")` resolved in its `effectiveAppearance`, again on `viewDidChangeEffectiveAppearance` and on attach; class and overlay docs updated.
- `app/test/macos/runner_chrome_assets_test.dart` -- each colour set's any and dark colours equal their tokens (`ZsColors.paper`/`night` `canvasBase`, `tlRing`; `toCss()['--accent-native']`/`['--accent-native-dark']`) within 1/255; the build setting appears exactly three times.
- `app/test/helpers/recording_shell.dart` -- answers `watchWindowChrome` with a settable `WindowChrome` (default `const WindowChrome()`), records `watchWindowChrome:<id>` / `unwatchWindowChrome:<id>`, exposes a `chromeChanges` controller closed by `close()`.
- `app/test/features/window/window_chrome_builder_test.dart`, `app/test/features/app/zanshin_app_test.dart` (a measured block and full screen reach the shell's metrics and bar; the 0 → `chromeTop` drag row follows), `app/test/features/home/home_page_test.dart` (the canvas is `ZsCanvas`; pan → `startWindowDrag`, double tap → `performTitlebarDoubleClickAction`; under full screen the row is 68), `app/test/features/window/app_windows_test.dart` (the default constraints are 880 × 560) -- the ACs and the remaining matrix rows.
- `app/widgetbook/folders/materials.dart` -- component "Canvas", use case "Window canvas" (`ZsCanvas` full bleed); `app/widgetbook/folders/shell.dart` -- `FloatingShellDemo` passes `canvas: const ZsCanvas()`; the smoke test covers the new use case.
- Tracking: `deferred-work.md` (mark I1–I3 per the ledger's convention; a "Surfaced in Story 11.4" section for this spec's `deferred:` items, in the same commit as the spec), `epic-11-context.md` (the 11.4 hand-off line settled), `sprint-status.yaml` (11-4 done).

**Acceptance Criteria:**
- Given the project window on this Mac (macOS 27.0.1, the app's toolbar), when it opens, then the shell reports the block x 19–79 with centre y 26 for its view (app log), and the running app shows the first island at x 91, the bar at 4–48 and the content top and drag row at 60 (Marionette element bounds).
- Given any reported block, when the shell lays out, then the bar's centre line equals the block's centre within 1 px, the first island starts at block end + 12 and the content at bar bottom + 12; given full screen, the first island is at 12, the bar's top at 12 and content and drag row end at 68; after leaving full screen the block-derived geometry is back.
- Given the bar row, when the primary button pans in an empty part of it, then `startWindowDrag` runs; a double tap runs `performTitlebarDoubleClickAction` (zoom with the default `AppleActionOnDoubleClick`); a press below the row reaches the canvas.
- Given `HomePage`, when it builds, then the canvas is `ZsCanvas` painting `--canvas` (night and paper), it follows a theme switch without a restart (a repaint with the lerped gradient), and the runner installs no view below the Flutter view (no `NSVisualEffectView` left in `MainWindowChrome.swift`).
- Given the native window, when created, then it is opaque on `CanvasBase`, its minimum is 880 × 560 natively and in `defaultWindowConstraints`, and at 880 × 560 the bar's islands do not overlap (11.3's top-bar witnesses at 880 stay green).
- Given the rings, when the theme is night, paper or switches, then `TrafficLightOverlayView` strokes the `TrafficLightRing` colour of the window's appearance, still hides on hover and in full screen, and re-attaches after full screen as before.
- Given the built app, when its Info.plist is read, then `NSAccentColorName` is `AccentColor`, and the colour set holds #4757a1 (any) and #5162ad (dark) (I1); `ZsAccentFamily.resolve` maps a reported #4757a1 without `AppleAccentColor` to Multicolor (existing test stays).
- Given `ZanshinApp` on macOS, when the shell reports full screen for the window's view, then `ZsAppearance.of(<shell>).fullScreen` is true (I2), and a report for another view changes nothing.
- Given the change, when `cargo make test` runs unpiped and `flutter build macos --debug` runs in `app/`, then both pass.

## Spec Change Log

- 2026-10-18 (implementation): Design Notes "Measurement" named `didFailToEnterFullScreen` among the triggers, but `NSWindow` posts no such notification (only the engine-owned delegate hears `windowDidFailToEnterFullScreen(_:)`; `flutter build macos` failed on it). The host clears its entering flag on `didEnterFullScreen` / `didExitFullScreen` and, failing both, 2 s after `willEnterFullScreen` when `styleMask` still lacks `.fullScreen` (Claude's proposal; deferred-work.md "Surfaced in Story 11.4"). The intent contract is unchanged.

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 39 findings — high 0, medium 4, low 21, false 9, maybe-false 5
- findings:
  - `[low]` `[reject]` (blind 1) A watch is idempotent but not counted, so a remounted `WindowChromeBuilder` (new element's watch before the old one's unwatch) would stop receiving reports — no path remounts it: the builder sits at a fixed place under `MaterialApp.builder` in the project window's root; counting watchers adds state for an undemonstrated case.
  - `[low]` `[patch]` (blind 2) The 2 s full-screen fallback timer is not tied to its entry, so enter → exit → enter within 2 s lets the first timer clear `entering` mid-transition — patched: the pending check is a `DispatchWorkItem` cancelled on `didEnter`/`didExit`/`stop()` and replaced on each `willEnter`.
  - `[maybe-false]` `[reject]` (blind 3) No `willExitFullScreen` trigger, so the bar may sit at 12/12 while the buttons come back — the spec keeps full-screen geometry until `didExitFullScreen` on purpose (matrix row "Leaving full screen"); whether the gap is visible needs Ralph's ⌃⌘F check; if true only low.
  - `[low]` `[patch]` (blind 4) Swift names the colour sets by unchecked strings, so a rename silently drops the rings or the base — patched: `runner_chrome_assets_test.dart` checks that every `NSColor(named:)` in `MainWindowChrome.swift` has its `.colorset`.
  - `[low]` `[reject]` (blind 5) The native 880 × 560 minimum holds every chrome window, against the new doc that dialog windows pass their own — pre-existing (every chrome window was held at 900 × 600 before), epics item 4 names both places, and 11.12 parameterises `MainWindowChrome` with no forced minimum for secondary windows (sprint-status 11-12).
  - `[low]` `[reject]` (blind 6) The base and ring colours follow the stored theme only in the window `setWindowAppearance` targets — that mirror has always addressed one window; "zanshin_shell appearance for every window" is 11.12's scope; the project window's base shows only before its first frame, which the window never shows.
  - `[low]` `[reject]` (blind 7) `ZsAppearance.copyWith` cannot clear `trafficLights` — no caller passes a block-carrying base (`ZsAppearance.fromShell` never sets one); keep-on-null is every field's `copyWith` rule; a sentinel API is more than a correction.
  - `[low]` `[patch]` (blind 8) The canvas paint test cannot tell base from lift, their order or the ellipse — patched with verification-gap 1.
  - `[false]` `[reject]` (blind 9) Spec `in-review` while sprint-status says done — a mid-run state; finalize sets the spec done in the same commit.
  - `[low]` `[patch]` (blind 10) `epic-11-context.md` claims Multicolor resolves to moon though unverified, and its Order line still says "11.3 next" — patched: the hand-off names the pending Multicolor check; the Order line reads 11.0–11.4, 11.11 and 11.14 done, 11.12 next.
  - `[low]` `[reject]` (blind 11) The builder's off-macOS gate, its view-switch path and a push after a failed watch have no witness — the gate runs on macOS only, a window's view never changes under one element, and a push after a failed watch applies as designed; injecting the platform gate adds a parameter for tests alone.
  - `[low]` `[reject]` (blind 12) Error-code use on the new channel (a malformed reply as bad-args, unknown method without a viewId as bad-args, an orphan watch on a nil answer, `postsFrameChangedNotifications` left true) — bad-args for a malformed reply matches the channel's other decoders; the viewId-first order is `FolderDropHost`'s; a nil answer needs a controller without a window, which the lookup over `NSApp.windows` cannot return, and the builder unwatches on dispose anyway; `postsFrameChangedNotifications` is true by default and the runner's overlay sets it too.
  - `[low]` `[defer]` (blind 13) The catalogue's windows do not use `WindowChromeBuilder`, so the real Floating shell window keeps the reference geometry and ignores full screen — deferred to 11.12's per-window roots, mirrored in deferred-work.md.
  - `[maybe-false]` `[reject]` (blind 14) Measured values are not pixel-snapped — AppKit's button frames were integral here (19, 19, 60, 14); whether any Mac reports a half point is open; if true only low (soft island edges on 1x).
  - `[low]` `[reject]` (edge 1) Watch not reference-counted — same as blind 1.
  - `[low]` `[patch]` (edge 2) The fallback timer of an earlier entry ends a later one — patched with blind 2.
  - `[false]` `[reject]` (edge 3) An orphan watch stays after a nil answer — `flutterViewController(_:messenger:)` only returns a window's content view controller, so `measure()` has a window and never answers nil there.
  - `[maybe-false]` `[reject]` (edge 4) A titlebar container moving without a button frame change leaves the block stale — no such move was seen (the toolbar attach changes the buttons' frames); a resize, key change or full-screen event re-measures; if true only low.
  - `[maybe-false]` `[reject]` (edge 5) Buttons under a hidden ancestor would count as the block — the runner's overlay uses the same `isHidden` rule and no hidden titlebar ancestor was observed outside full screen, which is reported separately; if true only low.
  - `[false]` `[reject]` (edge 6) A synchronous `UnimplementedError` from the platform would escape `didChangeDependencies` — every registered platform (macOS, the test fakes) implements the methods; a missing one is a wiring error that should fail loudly.
  - `[low]` `[reject]` (edge 7) `copyWith` cannot clear `trafficLights` — same as blind 7.
  - `[maybe-false]` `[reject]` (edge 8) A block centred above y 22 (before the toolbar) puts the bar above the window — the toolbar attaches in `MainWindowChrome.init`, before Dart builds, and the live report was 19–79 / 26; a pre-toolbar report would be transient; clamping breaks the DS rule; if true only low.
  - `[false]` `[reject]` (edge 9) A right-to-left layout puts the buttons top right — the app is English-only (no RTL localisation), so AppKit lays the window out left to right.
  - `[false]` `[reject]` (edge 10) `createShader` on a zero-height box or a 0 % width gives a singular matrix — `RenderZsCanvas.paint` returns for an empty size before any shader, it is the only caller, and no DS token has a 0 % radius.
  - `[false]` `[reject]` (edge 11) Dropping the vibrancy calls stops re-applying the clear Flutter background on key and full-screen changes — the engine creates the window with its `FlutterViewController` as content view controller, so the assignment in `setupWindowAppearance` holds; the window shows only after its first frame.
  - `[low]` `[patch]` (edge 12) No test witnesses `FloatingShell`'s `--canvas-base` fallback since the home test moved to `ZsCanvas` — patched: a `floating_shell_test` case checks the fill without a canvas.
  - `[low]` `[patch]` (verification-gap 1) The canvas paint test cannot catch a swapped order, a doubled base or a lost matrix — patched: a pixel probe compares `ZsCanvas` with the linear base alone (the lift at (100, 10) differs; (999, 799) and (100, 400), inside the circle but outside the ellipse, match).
  - `[medium]` `[defer]` (verification-gap 2) The native measurement and chrome run in no test — already recorded (deferred-work.md "Surfaced in Story 11.4", the native-half item); needs a Swift test target or a runtime smoke check.
  - `[low]` `[defer]` (verification-gap other 1) The catalogue's Floating shell window ignores the measured chrome — deferred with blind 13.
  - `[medium]` `[defer]` (intent 1) The native witnesses (rings, corners, full screen, the minimum stop, zoom, window movement) are not observed — deferred with verification-gap 2 (Ralph's manual checks).
  - `[medium]` `[defer]` (intent 2) The drag and double-click witnesses run against fake calls, not window movement — deferred with verification-gap 2.
  - `[low]` `[reject]` (intent 3) The built Info.plist is checked by hand only — `flutter build macos --debug` plus `plutil` ran in this run (Verification); the gate never builds the app, so an automated built-plist check needs a build step in the gate.
  - `[low]` `[reject]` (intent 4) I1's runtime outcome (Multicolor resolves to moon) is not observed — this Mac runs Orange; the existing Story 11.1 ledger item on the exact #4757a1 match already tracks it, so nothing new is deferred.
  - `[low]` `[patch]` (intent 5) The canvas tests assert the token source, not what is painted — patched with verification-gap 1.
  - `[false]` `[reject]` (intent 6) "A press below 60 pans the graph" is only stood in for — no graph exists before 10.1; the press reaching the canvas is the only observable before it, and the 10.2 transparent mode is 10.2's.
  - `[false]` `[reject]` (intent 7) The drag region is reclassified, not replaced, and design question (a) treated as settled — the design update keeps (a)'s recommendation, decision (g), which the 11.3 stand-in already is (item 2: WindowDragArea under the islands, top edge to the content top).
  - `[medium]` `[defer]` (intent 8) The corner radius is not measured; the window server rounds the opaque window — Claude's proposal (Design Notes "Window"); not observed from this seat, deferred with verification-gap 2.
  - `[low]` `[reject]` (intent 9) The opaque base and native minimum apply to every chrome window — same as blind 5.
  - `[false]` `[reject]` (intent 10) The Auto Run Result lacks the per-item outcomes and hashes — written at finalize, which comes after this triage.

## Design Notes

**Measurement** (`WindowChromeHost`, Claude's proposal for the triggers). `watch {viewId}`: look the controller up (`FlutterViewLookup`), register per view (idempotent) observers on its window — `didResize`, `didBecomeKey`, `willEnterFullScreen` (sets an `entering` flag), `didEnterFullScreen`, `didExitFullScreen` and `didFailToEnterFullScreen` (clear it; AppKit has no such notification, so a 2 s fallback stands in — Spec Change Log), `willClose` (drops the watch) — and `NSView.frameDidChangeNotification` on the current standard buttons (re-subscribed whenever a measure finds other button instances, since AppKit replaces them on titlebar rebuilds); answer the current report and measure once more on the next run-loop turn (the toolbar attaches lazily, as `MainWindowChrome` assumes at :146-152). Every trigger re-measures and sends `changed` only when the report differs from the last one sent. Report: `fullScreen` = `entering || styleMask.contains(.fullScreen)`; `trafficLights` = null in full screen, else the union of the visible close/miniaturize/zoom buttons that still belong to this window, converted with `controller.view.convert(_:from:)` into the Flutter view's points with the origin top left (flip by the view's height unless `isFlipped`); null when none. `unwatch` removes every observer.

**Report** (Dart). `WindowChromeBuilder` reads `View.of(context).viewId` in `didChangeDependencies`; on macOS (the `ZanshinAppViewModel` guard) it first listens to `onWindowChromeChanged` filtered to its view, then calls `watchWindowChrome`; it `setState`s only for a mounted state and a changed report; `dispose` cancels and unwatches. In `ZanshinApp`: `appearance.copyWith(theme: …, fullScreen: chrome?.fullScreen, trafficLights: chrome?.trafficLights)`. One watcher per view (the window root); 11.12's per-window roots reuse the builder.

**Metrics.** `fullScreen` → `tlBlockW` 0, `tlX` 0, `tlMidY` 34 (DS :52); else a block → `tlX` = left, `tlBlockW` = width, `tlMidY` = centre y; else the reference 19 / 60 / 26. The derived `chromeFirstX`, `chromeBarY`, `chromeTop` and 11.3's whole layout follow without change.

**Canvas** (DS tokens/colors.css:25, :82; readme.md:76, :88). CSS `radial-gradient(W% H% at X% Y%, …)` over rect R: centre c = R.topLeft + (R.width·X/100, R.height·Y/100), rx = R.width·W/100, ry = R.height·H/100; `ui.Gradient.radial(c, rx, colors, stops, TileMode.clamp, m)` with m = translate(c)·scale(1, ry/rx)·translate(−c), column-major [1,0,0,0, 0,k,0,0, 0,0,1,0, 0,c.dy·(1−k),0,1], k = ry/rx; stop positions by the linear rules over the ray length rx, divided by rx. Paint order: linear base over the whole box, the radial on top; no dot grid, no blur, no noise (readme.md:88). Both stop colours of the lift share their RGB, so premultiplied versus straight interpolation does not matter.

**Window** (Claude's proposal, items 3 and 6). The window turns opaque on the `CanvasBase` colour set: the system then rounds and clips it with its own corner radius — the system's measure, no private API — and the colour set's appearance variants follow `setWindowAppearance` (paper = aqua, night = darkAqua), so a frame the Flutter view has not drawn yet shows the right base. The canvas paints everywhere, so nothing needs the vibrancy view; with no view below the Flutter view, the event-forwarding trap `EventTransparentEffectView` guarded against is gone. Rings: a `CGColor` does not follow appearance changes, so the overlay resolves the named colour inside `effectiveAppearance.performAsCurrentDrawingAppearance` on attach and in `viewDidChangeEffectiveAppearance`.

## Verification

**Commands:**
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `packages/zanshin_shell_platform_interface`, `packages/zanshin_shell_macos`, `packages/zanshin_shell`, `packages/zanshin_ui` and `app/` -- expected: clean.
- `flutter test` in the same five packages -- expected: all pass.
- `flutter build macos --debug` in `app/` (toolchain PATH as below) -- expected: success (the gate never compiles Swift); then `plutil -extract NSAccentColorName raw build/macos/Build/Products/Debug/zanshin.app/Contents/Info.plist` prints `AccentColor`.
- `cargo make test` (repo root, unpiped, `PATH` with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, coverage baseline unchanged.

**Manual checks (if no CLI):**
- Claude's check (house rule; project-context.md "UI tooling"): run the app (`flutter run -d macos` in `app/`), connect Marionette, screenshot the project window (canvas, empty islands at 91 / 4, drag row to 60) and read the reported block from the app log; run the catalogue and compare Materials › Canvas and Shell › Slots in night and paper with the DS desktop kit (`ui_kits/desktop`, `design-system-preview`); a CGWindowList probe shows the project window on screen at its frame. Record what was and was not seen in the Auto Run Result.
- Ralph (not reachable from this seat without screen recording or accessibility): the rounded corners, the ring colour in night and paper and after a theme switch, entering and leaving full screen (⌃⌘F), a drag below 880 × 560 that stops, and — on a Multicolor Mac (this one is on Orange) — native menus tinted in the deeper moon and the app showing the Multicolor family.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none. Code commit: fdd98174ef815c53453818fc2eab7fda7f685cb3.

**Summary.** The project window's chrome now follows the system's measured traffic lights. `zanshin_shell` measures each watched Flutter view's standard window buttons and full-screen state (`WindowChromeHost`, channel `zanshin_shell/window_chrome`: `watch` / `unwatch` / `changed`, `bad-args` / `unknown-view`; `WindowChrome` and `WindowChromeChange` through the platform interface, the macOS decoder and the facade). `WindowChromeBuilder` hands the report to the project window's root, which copies `fullScreen` and the new `ZsAppearance.trafficLights` into its appearance; `ZsMetrics.resolve` takes full screen first (12 / 12 / 68), then the measured block (first island at block end + 12, bar centred on the block, content at bar bottom + 12), else the DS reference. `zanshin_ui` gains `ZsRadialGradient.resolve` / `createShader` (the CSS ellipse; the stop rules are one helper for both gradients) and `ZsCanvas`, the two static `--canvas` shaders, which `HomePage` passes beside its `WindowDragArea` bar row, now documented as the window's drag region. The runner's window is opaque on the `CanvasBase` colour set (the vibrancy view and `EventTransparentEffectView` are gone), the rings stroke the `TrafficLightRing` colour set resolved per appearance, the minimum is 880 × 560 natively and in `defaultWindowConstraints`, and the `AccentColor` colour set ships with `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME`. A Dart test checks the colour sets against the tokens and the Swift names against the sets. The catalogue gains Materials › Canvas, and its shell demo paints the canvas.

**Ledger items** (deferred-work.md):
- **I1 — fixed** (commit fdd98174ef815c53453818fc2eab7fda7f685cb3): `app/macos/Runner/Assets.xcassets/AccentColor.colorset` holds #4757a1 (any) and #5162ad (dark), the Runner target sets `ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME = AccentColor` in Debug, Release and Profile, and the built Info.plist names `NSAccentColorName` = `AccentColor` (`plutil`); `runner_chrome_assets_test.dart` pins the values to `--accent-native(-dark)`. The runtime outcome on a real Multicolor Mac was not observable here (this Mac runs Orange); it stays with the existing Story 11.1 ledger item on the exact #4757a1 match, not mirrored again.
- **I2 — fixed for 11.4's part** (commit fdd98174ef815c53453818fc2eab7fda7f685cb3): the project window's root takes `fullScreen` (and the measured block) from the shell's chrome report through `WindowChromeBuilder`; `inactive` stays with 11.12, as the item says (the ledger entry stays open for that half).
- **I3 — fixed** (commit fdd98174ef815c53453818fc2eab7fda7f685cb3): `HomePage` passes `canvas: const ZsCanvas()`, and its bar row is the drag region of design question (a) (decision (g)): `WindowDragArea` under the islands from the window's top edge to the content top (60, 68 in full screen) — the 11.3 stand-in already had that shape, so it stays and is no longer a stand-in; `FloatingShell`'s plain `--canvas-base` fill remains only for hosts that pass no canvas.

**Files changed** (one line each):
- `packages/zanshin_shell_platform_interface/lib/src/{window_chrome.dart,zanshin_shell_platform.dart}`, `lib/zanshin_shell_platform_interface.dart` -- `WindowChrome`, `WindowChromeChange`, the three interface methods, doc fix.
- `packages/zanshin_shell_macos/lib/zanshin_shell_macos.dart` -- the window-chrome channel's encoder and decoder.
- `packages/zanshin_shell_macos/macos/.../{WindowChromeHost.swift,FlutterViewLookup.swift,FolderDropHost.swift,ZanshinShellPlugin.swift}` -- the native measurement, the shared view lookup, the host's registration.
- `packages/zanshin_shell/lib/{zanshin_shell.dart,src/zanshin_shell.dart}` -- the facade and its exports.
- `packages/zanshin_ui/lib/src/design/{zs_appearance.dart,zs_metrics.dart,zs_values.dart,zs_accents.dart}`, `lib/src/materials/zs_canvas.dart`, `lib/zanshin_ui.dart` -- `trafficLights`, the measured-block metrics, the radial gradient maths, `ZsCanvas`.
- `app/lib/src/features/window/{window_chrome_builder.dart,app_windows.dart,remembered_window_controller.dart}` -- the report builder, the 880 × 560 default, a doc fix.
- `app/lib/src/features/{app/zanshin_app.dart,app/zanshin_app_view_model.dart,home/home_page.dart,shell/floating_shell.dart}` -- the root's chrome report, `HomePage`'s canvas and drag region, docs.
- `app/macos/Runner/{MainWindowChrome.swift,Assets.xcassets/*.colorset}`, `app/macos/Runner.xcodeproj/project.pbxproj` -- opaque window, rings, minimum, colour sets, accent setting.
- `app/widgetbook/folders/{materials.dart,shell.dart,windows.dart}` -- Materials › Canvas, the demo's canvas, a redundant constraint dropped.
- Tests: `packages/zanshin_shell_platform_interface/test/zanshin_shell_platform_test.dart`, `packages/zanshin_shell_macos/test/zanshin_shell_macos_test.dart`, `packages/zanshin_shell/test/zanshin_shell_test.dart`, `packages/zanshin_ui/test/{design/zs_tokens_test.dart,design/zs_values_test.dart,design/zs_appearance_from_shell_test.dart,materials/zs_canvas_test.dart}`, `app/test/{features/window/window_chrome_builder_test.dart,features/window/app_windows_test.dart,features/app/zanshin_app_test.dart,features/home/home_page_test.dart,features/shell/floating_shell_test.dart,macos/runner_chrome_assets_test.dart,helpers/recording_shell.dart,widgetbook/catalogue_smoke_test.dart}`.
- Tracking: this spec, `deferred-work.md` (I1–I3 marked with the commit, "Surfaced in Story 11.4" with three items), `epic-11-context.md` (Order and hand-off lines), `sprint-status.yaml` (11-4 done).

**Review findings.** 39 findings (high 0, medium 4, low 21, false 9, maybe-false 5). Patched (5 entries, all low): the 2 s full-screen fallback is a `DispatchWorkItem` cancelled on did-enter/did-exit and replaced per entry; a test checks every `NSColor(named:)` in `MainWindowChrome.swift` against the colour sets; a pixel probe (not a golden) pins the canvas's order and ellipse against the linear base alone; a shell test witnesses the plain `--canvas-base` fallback; `epic-11-context.md` no longer claims Multicolor is confirmed and its Order line is current. Deferred (mirrored in deferred-work.md "Surfaced in Story 11.4"): the native half unseen from this seat, Ralph's manual checks (medium; covers the four medium findings), the catalogue windows without `WindowChromeBuilder` (low, 11.12), and the implementation's missing-notification fallback (low). Rejected, with reasons in the triage log: an uncounted watch with no remount path, the exit-side trigger kept by design, the shared native minimum and single-window appearance mirror (pre-existing, 11.12), `copyWith` keep-on-null, untestable off-macOS and view-switch paths, channel error-code nits, pixel snapping, a moving titlebar container, hidden ancestors, a pre-toolbar centre, the graph and design-question readings, the manual plist check and I1's runtime outcome (already tracked), and the 9 false findings.

**Follow-up review recommendation:** false — this pass patched 5 entries, all low (0 high, 0 medium); the unverified native behaviour is deferred to Ralph's manual checks, not a patch risk.

**Verification.**
- `cargo make test` (repo root, unpiped, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset): exit 0 before the review (15 of 27 steps planned) and after the patches (app 445, `zanshin_ui` 381, `zanshin_shell_macos` 16 and the other touched packages' tests, analyze and format); no Rust changed, so coverage did not run and `coverage-baseline.txt` is unchanged.
- `flutter build macos --debug` in `app/`: success after the implementation and again after the Swift patch; `plutil -extract NSAccentColorName raw build/macos/Build/Products/Debug/zanshin.app/Contents/Info.plist` prints `AccentColor`; `assetutil` showed the three colour sets with their any and darkAqua values.
- Matrix audit: every row has a passing test — measured and shifted block (`zs_tokens_test`, `zanshin_app_test`), full screen and full screen winning (`zs_tokens_test`, `zanshin_app_test`, `home_page_test`), no report (`window_chrome_builder_test` before the answer and after a failed watch; `zs_tokens_test` reference), foreign view, equal report and unmount (`window_chrome_builder_test`, `zanshin_app_test`), malformed push and unknown view (`zanshin_shell_macos_test`, `window_chrome_builder_test`), canvas maths and an empty box (`zs_values_test`, `zs_canvas_test`). The off-macOS half of "No report" cannot run on the macOS-only gate.
- Seen in the running app (implementation run; the debug build launched directly, Marionette over its VM service): the app log reported `Window view 2 reports WindowChrome(fullScreen: false, trafficLights: Rect.fromLTRB(19.0, 19.0, 79.0, 33.0))` — block x 19–79, centre y 26; Marionette's element bounds put the bar at left 91, top 4, height 44 and the drag row at 0–60; the screenshot shows the night canvas under four empty islands. The CGWindowList probe found the project window on screen at its remembered 900 × 899 frame.
- Seen in the catalogue: Materials › Canvas › Window canvas and Shell › Floating shell › Slots in night and paper, next to the DS desktop kit (`ui_kits/desktop/index.html` over `design-system-preview`): the same indigo and warm-paper bases with the lift at the top left.
- Not seen from this seat (no screen recording, no accessibility; this Mac runs Orange): the rounded corners of the opaque window, the rings' colour in night and paper and after a theme switch, entering and leaving full screen, the 880 × 560 drag stop, a real window drag and zoom, and Multicolor's native tint — Ralph's manual checks (§ Verification).

**Residual risks.**
- The opaque window replacing the vibrancy view is the riskiest native change; its rounded corners rest on the window server and were not seen.
- The native measurement has no automated test; on this Mac the measured block equals the reference, so a silent fallback to the reference would have looked the same.
- The review patches (a Swift timer, tests, a context line) were verified by tests and the build, not re-checked in the running app; none changes what the window shows.
