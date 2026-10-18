---
title: 'Story 11.4 closing run — the catalogue''s real windows take the window chrome report'
type: 'bugfix'
created: '2026-10-18'
status: 'done'
baseline_revision: '03b2d4b94aaabfd695b9de3d345844d5b7859bf0'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** Ledger item 1 handed to this closing run (deferred-work.md "Surfaced in Story 11.4", review pass 2026-10-18, blind hunter), verified against the current code: the catalogue's Windows folder opens real windows through `AppWindows.openOrActivate` → `create`, which always passes `chrome: true` (`app/lib/src/features/window/app_windows.dart:100-110`), so they wear the project window's native chrome; but their root is `catalogueAppBuilder` (`app/widgetbook/catalogue.dart:149-168`), a `ZsRoot` whose appearance never carries `fullScreen` or `trafficLights`, so `ZsMetrics.resolve` falls back to the DS reference (first island 91, bar top 4, content top 60) whatever the window measures and in full screen too. On top, `FloatingShellDemo` pins `fullScreen: false` through its own `ZsAppearanceOverride` (`app/widgetbook/folders/shell.dart:75-81, :146-147`), so even a root that knew full screen would not reach the shell inside the window.

**Approach:** The Windows folder's windows build their root through one widget, `CatalogueWindowRoot`, which wraps `catalogueAppBuilder` in Story 11.4's `WindowChromeBuilder`; `catalogueAppBuilder` takes an optional `chrome` report and copies its full screen and block into its `ZsRoot`'s appearance exactly as `ZanshinApp`'s macOS root does. `FloatingShellDemo.fullScreen` becomes nullable — null keeps the window root's value, the Shell folder's knob still sets it. Widgetbook's previews pass no report and keep the reference geometry.

## Boundaries & Constraints

**Always:**
- Mirror `ZanshinApp`'s root (`app/lib/src/features/app/zanshin_app.dart:93-108`): the report joins only the `ZsRoot`'s appearance (`theme` from the `MaterialApp`'s brightness, then `fullScreen: chrome?.fullScreen`, `trafficLights: chrome?.trafficLights`); the `MaterialApp`'s `theme`/`darkTheme` stay chrome-free.
- `appBuilder: catalogueAppBuilder` (Widgetbook 3.25.0's `AppBuilder = Widget Function(BuildContext, Widget)`) keeps compiling unchanged; without a report every preview resolves exactly as today.
- `WindowChromeBuilder` is reused as it is — one per window root, here one per catalogue window.
- SPDX first line, page width 120; `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean in `app/`.

**Never:**
- No change to Story 11.4's production code beyond this item: `WindowChromeBuilder`, `ZanshinApp`, `zanshin_ui`, `zanshin_shell*`, the Swift runner stay untouched.
- No change to the catalogue's own window (`ZanshinCatalogue`, `catalogue.dart:96-127`): its header strip reads only `windowHdH`, a fixed token, and its use cases are previews in Widgetbook's frame, not window roots.
- No drag row added to the demo window, no new use cases, no 11.12 work (the app's dialog-window roots, the inactive delta).
- No golden tests; no edits under `design/` or `design_system/`; no change to existing deferred-work.md bullets, `epic-11-context.md`, `epics.md`, `sprint-status.yaml` or the Story 11.4 spec; never lower `coverage-baseline.txt`.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Measured block | the builder Windows › Floating shell's button hands to `openOrActivate`, pumped at 1440 × 900; watch answers `WindowChrome(trafficLights: Rect.fromLTWH(20, 20, 60, 14))` | it builds `CatalogueWindowRoot`; `watchWindowChrome:<viewId>` recorded; at the `FloatingShell`: `trafficLights` is the block, metrics 92 / 5 / 61; `ShellTopBar` at (92, 5), `ShellRail` top 61 | — |
| Full screen | `changed` for the view with `WindowChrome(fullScreen: true)` | `ZsAppearance.fullScreen` true at the `FloatingShell`; `ShellTopBar` at (12, 12), `ShellRail` top 68 | — |
| Leaving full screen | `changed` back to the block | the block geometry (92 / 5 / 61) returns | — |
| No report | watch answer still pending | reference: `ShellTopBar` at (91, 4), `ShellRail` top 60 | — |
| Unmount | the window root leaves the tree | `unwatchWindowChrome:<viewId>` recorded | — |
| Window fill | the builder Windows › Window fill's button hands to `openOrActivate`, pumped | it builds `CatalogueWindowRoot` over a `ZsWindowFill`; `watchWindowChrome:<viewId>` recorded | — |
| Preview | catalogue at `shell/floating-shell/slots`, and at the two Windows use cases before a press (no report) | no `watchWindowChrome` call in any of the three; the slots preview's `FloatingShell` resolves the reference metrics 91 / 4 / 60 | — |
| Knob | `FloatingShellDemo(state: layout, fullScreen: true)` under `catalogueAppBuilder` without a report | `ShellTopBar` at (12, 12) | — |

</intent-contract>

## Code Map

- `app/widgetbook/catalogue.dart:147-168` -- `catalogueAppBuilder(BuildContext, Widget)`: `MaterialApp` with token themes, `builder:` → `ZsRoot(appearance: appearance.copyWith(theme: ZsTheme.of(Theme.of(context).brightness)), shellTheme: shell, …)`; used by Widgetbook (`:120`) and both Windows-folder windows. `:170-174` `_appearance`. `zanshin_shell` is already imported (`:10`) and exports `WindowChrome`. `:96-127` the catalogue's own window (out of scope).
- `app/widgetbook/folders/windows.dart:60-94` `_OpenWindowFill`, `:96-126` `_OpenFloatingShell` -- each builder is `ZsShellScope(shellTheme: shell?.shellTheme, child: Builder(builder: (context) => catalogueAppBuilder(context, <content>)))`; already imports `package:zanshin/src/features/window/app_windows.dart` (the same import style serves `window_chrome_builder.dart`). `:13-30` `CatalogueWindows`.
- `app/widgetbook/folders/shell.dart:72-85` `FloatingShellDemo({required state, this.fullScreen = false})`, `:146-150` `ZsAppearanceOverride(fullScreen: widget.fullScreen, child: Builder(→ ZsRoot(appearance: ZsAppearance.of(context), …)))`; `:28-44` the Shell folder passes `context.knobs.boolean(label: 'full screen')`.
- `app/lib/src/features/window/window_chrome_builder.dart:20-29` -- `WindowChromeBuilder({required builder(BuildContext, WindowChrome?)})`: listens, watches `View.of(context).viewId`, unwatches on dispose (macOS only — the gate runs on macOS).
- `app/lib/src/features/app/zanshin_app.dart:93-108` -- the pattern to mirror.
- `packages/zanshin_ui/lib/src/design/{zs_appearance.dart:263-337 (ZsAppearanceOverride; null fields keep the base), zs_root.dart:41 (the override applies at the inner root), zs_metrics.dart:128-143 (resolve)}` -- read-only.
- `app/lib/src/features/shell/floating_shell.dart:278-330` -- `ShellTopBar` positioned at (`chromeFirstX`, `chromeBarY`), `ShellRail` at top `chromeTop`; classes in `shell/top_bar.dart:32`, `shell/rail.dart:15`.
- Tests: `app/test/helpers/recording_shell.dart:20-26, :57-69` (settable `chrome`, `chromeAnswer`, `chromeChanges`, calls `watchWindowChrome:<id>` / `unwatchWindowChrome:<id>`); `app/test/helpers/{catalogue.dart (catalogueAt, useCatalogueWindow), icon_registry.dart (setUpIconRegistry, testIconRegistry)}`; `app/test/features/app/zanshin_app_test.dart:208-271` (the chrome-geometry test pattern); `app/test/widgetbook/catalogue_smoke_test.dart` (setUp/tearDown with `RecordingShell`).
- Gate: app-only Dart change → the change-aware plan runs the app's Flutter test, analyze and format steps; no Rust or `zanshin_core` change, so coverage does not run.

## Tasks & Acceptance

**Execution:**
- `app/widgetbook/catalogue.dart` -- `catalogueAppBuilder(BuildContext context, Widget child, {WindowChrome? chrome})`; its `ZsRoot` appearance adds `fullScreen: chrome?.fullScreen, trafficLights: chrome?.trafficLights`; doc: a window root passes its chrome report (Story 11.4), the previews pass none and keep the reference geometry -- the item's root half.
- `app/widgetbook/folders/windows.dart` -- public `CatalogueWindowRoot({required ShellTheme? shellTheme, required Widget child})`: `ZsShellScope(shellTheme:)` → `WindowChromeBuilder` → `catalogueAppBuilder(context, child, chrome: chrome)`; both windows' builders use it (their inline `ZsShellScope`/`Builder` go); docs name the chrome report -- one root for every catalogue window.
- `app/widgetbook/folders/shell.dart` -- `FloatingShellDemo.fullScreen` becomes `bool?` with no default; doc: null keeps the window root's (the Windows folder's real window), the Shell folder's knob sets it -- otherwise the demo hides the root's full screen.
- `app/test/helpers/catalogue.dart` -- `catalogueAt` takes an optional `AppWindows windows` (default as today) -- so a test can hand the catalogue a recording `AppWindows`.
- `app/test/widgetbook/catalogue_windows_test.dart` -- every matrix row (RecordingShell, `setUpIconRegistry`, 1440 × 900 at ratio 1); a private `AppWindows` subclass overrides `openOrActivate` to record the `builder` instead of opening a window; the test presses the use case's button (`open-floating-shell` / `open-window-fill`), then pumps the recorded builder under `IconRegistryScope` as the window's content.

**Acceptance Criteria:**
- Given the catalogue at `windows/floating-shell/floating-shell` (resp. `windows/window-fill/window-fill`), when the button is pressed, then the builder handed to `openOrActivate` builds `CatalogueWindowRoot` over the demo (resp. the window fill), whose root watches its view's chrome report and lays the shell out per the matrix.
- Given the change, when `flutter test`, `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` run in `app/`, then all pass, `catalogue_smoke_test.dart` included.
- Given the change, when `cargo make test` runs unpiped from the repo root, then it exits 0 and `coverage-baseline.txt` is unchanged.
- Given the running catalogue (`flutter run -d macos -t widgetbook/main.dart` in `app/`, Marionette), when Windows › Floating shell's button opens the window, then the shell shows there as before, its islands at 91 / 4 (on this Mac the measured block equals the reference); full screen and another block are not reachable from this seat and are recorded as not seen.

## Spec Change Log

## Review Triage Log

### 2026-10-18 — Review pass
- verdicts: 19 findings — high 0, medium 0, low 12, false 7, maybe-false 0
- findings:
  - `[low]` `[patch]` (blind 1) The watch assertions use `contains`, so a second watch, or one made in the catalogue's view before the press, would pass — patched: `openWindow` expects no watch after the press and before the window builds, the window tests expect exactly one `watchWindowChrome:<viewId>`, the unmount test exactly one `unwatchWindowChrome:<viewId>`.
  - `[low]` `[patch]` (blind 2) The shell-theme hand-off `CatalogueWindowRoot` now owns is never tested (`shell.theme` is never completed, so the captured theme is null everywhere) — grouped with verification-gap 1; patched there.
  - `[low]` `[reject]` (blind 3) `CatalogueWindowRoot` freezes the shell theme at the moment the window opens — pre-existing and documented: both inline builders already passed `shell?.shellTheme` read at press time ("it takes the shell theme as it is now", windows.dart before this run); a system appearance change while a catalogue window is open is rare, and following it needs a theme subscription in the root (11.12's per-window roots install the ambient defaults).
  - `[low]` `[reject]` (blind 4) The knob test builds `FloatingShellDemo(fullScreen: true)` directly instead of through Widgetbook's knob, and an explicit `false` under a full-screen root is untested — the knob line (`shell.dart:41`) is untouched by this diff, and no Shell-folder root carries a chrome report, so `false` under a full-screen root has no caller; more tests for an unreachable combination are not worth it.
  - `[false]` `[reject]` (blind 5) The recorded window content is laid out at 1440 × 900, not each window's requested size, and size/constraints go unasserted — the floating shell's window asks for exactly 1440 × 900; the window fill's only assertion (the watch) does not depend on its size; neither window's size or constraints changed in this diff.
  - `[low]` `[reject]` (blind 6) `WindowChromeBuilder` sits above `catalogueAppBuilder`, so a report rebuilds the whole `MaterialApp`, not only the `ZsRoot` as in `ZanshinApp` — true, but the native side sends `changed` only for a different report (full screen in or out), so the extra rebuild happens a handful of times per session in a review tool; moving the builder inside needs a flag on `catalogueAppBuilder`, and the appearance fields (the spec's rule) are mirrored.
  - `[low]` `[patch]` (blind 7) `catalogueAppBuilder`'s doc still calls [child] a use case the addons wrap, and "its root" is ambiguous — patched: [child] is a use case or a catalogue window's content, and the builder's `ZsRoot` takes full screen and the block.
  - `[low]` `[patch]` (blind 8) Nothing points later windows (11.12, 11.6, 11.7, 10.22) at `CatalogueWindowRoot` — patched: the `windowsFolder` doc says each window's builder returns a `CatalogueWindowRoot`; a test iterating every Windows use case was not added (more than a correction for windows that do not exist yet).
  - `[low]` `[patch]` (blind 9) The preview loop is vacuous for the two `windows/` paths and hides two contracts behind one branch — grouped with edge 1; patched there (splitting the test was not needed once the branch asserts what renders).
  - `[low]` `[reject]` (blind 10) The unanswered-watch test never completes the answer, and the full-screen step checks positions, not `chromeOf` — the late-answer transition is `WindowChromeBuilder`'s own, witnessed by `window_chrome_builder_test.dart:47-64`, which this root reuses unchanged; in full screen the asserted top-bar and rail positions are the metrics' observable result.
  - `[low]` `[patch]` (edge 1) The `windows/` preview cases never show the use case rendered, so an empty preview passes — patched: the branch also expects the use case's button (`open-window-fill` / `open-floating-shell`).
  - `[low]` `[patch]` (verification-gap 1) Regression gap: dropping `CatalogueWindowRoot`'s `ZsShellScope`, or passing `shellTheme: null`, keeps every test green, and the windows would lose the shell's mode, accent family and accessibility flags — patched: a test completes `shell.theme` with a light theme before the press and asserts the window's `ZsShellScope` theme and the paper `ZsAppearance` at its `FloatingShell` (grouped with blind 2).
  - `[low]` `[reject]` (intent a) The live native window — full screen, a block other than the reference — is observed by no check; the tests run the wiring at the widget layer with a fake report — true and not reachable from this seat (no accessibility for ⌃⌘F; this Mac's block equals the reference); the native report is the one Story 11.4's ledger item already sends to Ralph's manual checks (deferred-work.md "Surfaced in Story 11.4", the native-half item), and the catalogue window differs from the project window only in widget composition, which the tests cover with the same `WindowChromeBuilder`; nothing new to fix or record.
  - `[false]` `[reject]` (intent b) The evidence's "drag row at 60" is only covered through the rail's top — the catalogue's Floating shell window has no drag row (`FloatingShellDemo` passes no `barRow`, `floating_shell.dart:391-398`), so "60" there is the content top `chromeTop`, which the rail's top witnesses.
  - `[false]` `[reject]` (intent c) The Window fill window gets a watch with no layout effect, and the catalogue's own window gets none — the item names "the catalogue's windows"; `ZsWindowFill` reads no chrome metric, so its watch costs one channel call and keeps one root for every catalogue window; the catalogue's own root reads only `windowHdH`, which `ZsMetrics.resolve` never changes (`zs_metrics.dart:128-143`).
  - `[false]` `[reject]` (intent d) How this relates to 11.12's later per-window roots is unsettled and the ledger bullet is not edited — the orchestrating loop closes handed-over ledger items after the run (precedent `03b2d4b` for Story 11.4's own); 11.12 can reuse or replace `CatalogueWindowRoot`, which is catalogue-local.
  - `[false]` `[reject]` (intent e) The spec and its Auto Run Result are missing from the reviewed diff — both are written and committed at finalize; the review diff covers the code only.
  - `[false]` `[reject]` (intent f) The diff edits Story 11.3's `FloatingShellDemo` and 11.11's `catalogueAppBuilder` — the intent limits changes to Story 11.4's code "as far as an item needs"; the item's own Location names `catalogue.dart`, and the demo's pinned `fullScreen: false` is part of the item's "ignores full screen".
  - `[false]` `[reject]` (intent g) The watch assertions hold only on a macOS host — every chrome test of Story 11.4 (`zanshin_app_test.dart`, `window_chrome_builder_test.dart`) has the same dependency, and the gate runs only on macOS.

## Design Notes

**Why the previews keep the reference.** A Widgetbook use case is drawn inside Widgetbook's preview frame of the catalogue window, scaled by `FittedBox` in the Shell folder; that window's traffic lights sit in the catalogue's header strip, not at the preview's top left, so its block or full screen would misplace a preview. The Shell folder's full-screen knob is how a reviewer sees that geometry there.

**Why the demo's override turns nullable.** `ZsAppearanceOverride` replaces every non-null field at the next `ZsRoot`; with `fullScreen: false` the demo's inner root would always lay out windowed, hiding the real window's full screen. Null keeps what the outer root resolved; the measured block already passes through, since the override has no `trafficLights` field.

## Verification

**Commands:**
- `flutter test` in `app/` -- expected: all pass.
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` -- expected: clean.
- `cargo make test` (repo root, unpiped; PATH with `~/development/sdks/flutter/bin` and `~/development/sdks/cargo/bin`, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset) -- expected: exit 0, coverage baseline unchanged.

**Manual checks (if no CLI):**
- Claude's check (project-context.md "UI tooling"): run the catalogue, connect Marionette, open Windows › Floating shell, press its button and screenshot the new window (islands at 91 / 4 on this Mac); record what was and was not seen (full screen, another block) in the Auto Run Result.

## Auto Run Result

Status: done (2026-10-18). Blocking condition: none. Code commit: 84a47affb3bebdeab9c0fb74280c2947a682b62a.

**Items handed to this closing run.**
1. **The catalogue's windows wear the app's chrome but their roots have no `WindowChromeBuilder` — fixed** (commit `84a47affb3bebdeab9c0fb74280c2947a682b62a`).
   - Verified first: `AppWindows.create` always passes `chrome: true` (`app/lib/src/features/window/app_windows.dart:100-110`), and both Windows-folder windows had `catalogueAppBuilder` as their root, whose `ZsRoot` carried neither `fullScreen` nor `trafficLights`, so `ZsMetrics.resolve` took the DS reference; and `FloatingShellDemo` additionally pinned `fullScreen: false` through its own `ZsAppearanceOverride`, so even a knowing root would not have reached the shell.
   - Both windows now build `CatalogueWindowRoot` (`ZsShellScope` → `WindowChromeBuilder` → `catalogueAppBuilder(…, chrome:)`); `catalogueAppBuilder`'s `ZsRoot` copies `fullScreen` and `trafficLights` from the report as `ZanshinApp`'s root does; `FloatingShellDemo.fullScreen` is nullable (null keeps the window root's value). Story 11.4's production code is untouched.
   - The ledger's own follow-up ("11.12's per-window roots … the catalogue's included") is done for the catalogue's windows here; the catalogue's own window keeps its root (it reads only `windowHdH`, which no report changes).

**Summary.** One item, fixed: the catalogue's real windows (Windows › Floating shell and Windows › Window fill) watch their view's chrome report, and the floating shell inside follows the measured traffic-light block and full screen, as the project window does. Widgetbook's previews pass no report and keep the reference geometry; the Shell folder's full-screen knob still sets full screen there.

**Files changed:**
- `app/widgetbook/catalogue.dart` — `catalogueAppBuilder` takes an optional `WindowChrome? chrome` for its `ZsRoot`; doc names both callers.
- `app/widgetbook/folders/windows.dart` — public `CatalogueWindowRoot`, used by both windows' builders; the folder doc points later windows at it.
- `app/widgetbook/folders/shell.dart` — `FloatingShellDemo.fullScreen` is `bool?` (null keeps the window root's value).
- `app/test/helpers/catalogue.dart` — `catalogueAt` takes an optional `AppWindows`.
- `app/test/widgetbook/catalogue_windows_test.dart` — new: the button's recorded `openOrActivate` builder pumped as the window's content; every matrix row plus the shell-theme hand-off.
- Tracking: this spec. No new deferral, so `deferred-work.md` gets no new section.

**Review findings.** 19 findings (high 0, medium 0, low 12, false 7).
- **Patched, 5 entries (all low):** exact watch / unwatch counts and no watch before the window builds; a test for the shell-theme hand-off `CatalogueWindowRoot` owns (blind 2 + verification-gap 1); the `windows/` preview cases assert their button renders (blind 9 + edge 1); `catalogueAppBuilder`'s doc names both kinds of [child] and its `ZsRoot`; the Windows folder doc points later windows at `CatalogueWindowRoot`.
- **Deferred:** none.
- **Rejected, low:** the window's shell theme is a snapshot taken at the press (pre-existing and documented; following live changes needs a subscription, 11.12's ground); the knob test bypasses Widgetbook's knob and explicit `false` under a full-screen root is untested (knob line untouched; that combination has no caller); `WindowChromeBuilder` above the `MaterialApp` rebuilds it per report (reports come only on full-screen transitions in a review tool; moving it needs a flag); the late-answer transition and full-screen metrics in this file (the transition is `WindowChromeBuilder`'s own, witnessed by `window_chrome_builder_test.dart:47-64`); the live full screen and another block are unobserved (not reachable from this seat; the native report is already Story 11.4's ledger item for Ralph's manual checks).
- **False, 7:** the window-fill size in the test, the "drag row at 60" (the window has no drag row; 60 is `chromeTop`), the breadth of the fix, the ledger relation to 11.12, the bookkeeping written at finalize, edits outside 11.4's own code being what the item needs, and the macOS-only watch (the gate runs on macOS).

**Follow-up review recommendation:** false — this pass patched 5 entries, all low (0 high, 0 medium).

**Verification:**
- `flutter test` in `app/` — 455 passed after the patches (454 before), including `catalogue_windows_test.dart` (10) and `catalogue_smoke_test.dart`; `dart analyze --fatal-infos --fatal-warnings` — no issues; `dart format --output=none --set-exit-if-changed .` — 0 changed.
- `cargo make test` (repo root, unpiped to a log, `CARGO_HOME=~/development/sdks/cargo`, `RUSTUP_HOME` unset): exit 0 in the implementation run and again after the patches (the change-aware plan ran 3 of 27 steps: test-flutter, test-dart-analyze, test-dart-format); no Rust or `zanshin_core` change, so coverage did not run and `coverage-baseline.txt` is unchanged.
- Matrix audit: every row has a passing test — measured block, full screen in and out, no report, unmount, window fill, preview (three paths) and knob (`catalogue_windows_test.dart`). Two deliberate breaks in the implementation run (dropping `chrome: chrome`; restoring the `false` default) failed the block and full-screen tests; forcing the root's `shellTheme` to null failed the new theme test.
- Seen in the running catalogue (implementation run; `flutter run -d macos -t widgetbook/main.dart`, Marionette): `zanshinCatalogue.open` at `windows/floating-shell/floating-shell`, a tap on `open-floating-shell` opened the real window with the shell rendered; Marionette put the `shell-bar` at left 91 / top 4 and `shell-rail` at top 60 — the geometry this Mac's measured block (equal to the reference) gives.
- Not seen from this seat: full screen in the catalogue window and any block other than the reference (no accessibility for ⌃⌘F; this Mac's block equals the reference), the native traffic lights themselves (Marionette shows the Flutter layer only), and the watch call in the live run (the catalogue has no log forwarding).

**Residual risks:**
- In the live catalogue window, a received report and a missing one look the same on this Mac; the widget tests are the witness that the report is watched and applied.
- The review patches changed tests and docs only; the window's rendering was not re-checked after them.
