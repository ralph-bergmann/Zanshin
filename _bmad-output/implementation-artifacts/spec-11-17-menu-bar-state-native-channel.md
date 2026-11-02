---
title: 'Story 11.17 — Menu bar state: checkmarks and greyed window items via a native channel'
type: 'feature'
created: '2026-11-02'
status: 'done'
baseline_revision: 'a95cb0156fa1e67e341b0819626961beb0de6965'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      While the project window is in full screen, Minimize and Zoom stay enabled and the item keeps the title "Enter Full Screen".
    evidence: |-
      The engine's submenus have autoenablesItems = NO (FlutterMenuPlugin.mm:372), so NSWindow's validateMenuItem never greys them or retitles toggleFullScreen:; pre-existing since 11.13, windowItemsEnabled sees only the key window.
    location: >-
      app/lib/src/features/shell/app_menu.dart (AppMenuModel.windowItemsEnabled)
    severity: low
  - summary: >-
      The runner's XCTests (MenuStateChannel) run in no gate step.
    evidence: |-
      No Makefile.toml task or gate_plan.rs rule runs xcodebuild test; this run ran it by hand (2 passed).
    location: >-
      app/macos/RunnerTests/RunnerTests.swift
    severity: low
---

<intent-contract>

## Intent

**Problem:** 11.13's Dart menu bar cannot show a checkmark (`PlatformMenuItem` has no state), cannot grey Minimize, Zoom and Enter Full Screen for the dialog windows (the engine copies the system items and ignores `PlatformProvidedMenuItem.enabled`; its submenus have `autoenablesItems = NO`, so AppKit never validates them either), and the Window menu lists no windows (the engine never sets `NSApp.windowsMenu`). Deferred-work I1 and I2.

**Approach:** After every menu-bar build, `AppMenuBar` sends the state the engine cannot express on a new runner channel `zanshin/menu_state` (`apply`): the toggles' checked state, addressed by top-menu title + item title (the Dart labels), and the enabled state of the three system items, addressed by their AppKit selector. The runner applies it to the current `NSApp.mainMenu` and points `NSApp.windowsMenu` at the submenu holding `arrangeInFront:`.

## Boundaries & Constraints

**Always:**
- Checked: View › Detailed Cards = `preferences.options.detailedCards`, View › Group Stacks = `preferences.groupStacks` while a graph is bound; unchecked while none is. Show Minimap stays unchecked (no state until 10.16).
- Greying per epics.md 11.13 scope 3, following the key window: Minimize (`performMiniaturize:`) grey for Settings, Projects, Configurations; Zoom (`performZoom:`) grey for Settings; Enter Full Screen (`toggleFullScreen:`) grey for Settings, Projects, Configurations. All three grey with no key window (what AppKit's own validation does). Enabled for the project window.
- Sent after the frame (post-frame callback), so it lands after the engine's `Menu.setMenus` of the same build on the same messenger; a missing native handler (tests, other platforms) is ignored.
- Native argument parsing is strict like `WindowFrameStore` (`bad-args` on a malformed payload); an item that is not found is skipped.
- The native class lives in `WindowingBootstrap.swift` beside the other window channels (no new Xcode file).

**Never:** an engine fork or patched `FlutterMenuPlugin`; `autoenablesItems = YES` (it would re-enable the Dart-greyed items); new menu items or labels; titles of the system items changed.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Project window key | key = main, graph bound, detailedCards on | Detailed Cards ✓, Group Stacks per pref; all three system items enabled | — |
| Projects key | key = projects | Minimize and Full Screen grey, Zoom enabled | — |
| Settings key | key = settings | all three grey | — |
| Configurations key | key = revset-configs | Minimize and Full Screen grey, Zoom enabled | — |
| No key window | before the first focus event | all three grey; toggles unchecked | — |
| No native handler | `flutter test` | nothing happens | `MissingPluginException` swallowed |
| Malformed payload | native receives a wrong shape | nothing changes | `FlutterError(bad-args)` |

</intent-contract>

## Code Map

- `app/lib/src/features/shell/app_menu.dart:266-579` -- `AppMenuModel.menus`; `_keyWindow` (:140) is the key window; View toggles :436-449; `preferences` = `_ready?.preferences` (:325). `AppMenuBar` (:616-638) builds `PlatformMenuBar` in a `ListenableBuilder` — the send hook.
- `app/lib/src/features/window/app_windows.dart:25-34` -- `mainWindowKey`, `projectsWindowKey`, `settingsWindowKey`, `revsetConfigsWindowKey`.
- `app/lib/src/features/window/remembered_window_controller.dart:61` -- `windowFramesChannel` const: the pattern for a top-level channel const.
- `app/macos/Runner/WindowingBootstrap.swift:33-39` -- `start()` registers the channel hosts on `engine.binaryMessenger`; `SplashWindowHost` (:72) the class pattern.
- `app/macos/Runner/WindowFrameStore.swift:110-138` -- strict argument parsing pattern.
- Read-only: `~/development/sdks/flutter/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterMenuPlugin.mm` -- `setMenus` (:401) builds a fresh `NSMenu` and sets `NSApp.mainMenu`; provided items are copies found by selector (:273-308, selectors :112-130); submenus `autoenablesItems = NO` (:372); top-level items titled with the Dart label (:345).
- Read-only: `packages/flutter/lib/src/widgets/platform_menu_bar.dart:515-533` -- `didUpdateWidget` re-sends `Menu.setMenus` whenever the items are new instances (every rebuild).
- `app/test/features/shell/app_menu_test.dart` -- `_Rig` (:156), `menuBar: true` mounts `AppMenuBar`, `focus(key)`, `bindGraph`.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/shell/app_menu.dart` -- add `menuStateChannel` (`MethodChannel('zanshin/menu_state')`), `AppMenuModel.windowItemsEnabled(String? key)` (static: selector → enabled), `AppMenuModel.nativeState(AppLocalizations s)` (`{'checked': [{'menu','item','checked'}…], 'enabled': {selector: bool}}`), and in `AppMenuBar`'s builder a post-frame `apply` of the model's state (none during the boot) ignoring `MissingPluginException` -- I1's Dart half.
- `app/macos/Runner/WindowingBootstrap.swift` -- `MenuStateChannel` (strict `apply`: set `state` on the titled items, `isEnabled` on the selector items, `NSApp.windowsMenu` = the menu holding `arrangeInFront:`); created in `start()` -- I1's native half and I2.
- `app/test/features/shell/app_menu_test.dart` -- witnesses below.

**Acceptance Criteria:**
- Given each key (null, main, projects, settings, revset-configs), when `windowItemsEnabled` is read, then it matches the matrix.
- Given a bound graph with Detailed Cards on and Group Stacks off, when `nativeState` is read, then View › Detailed Cards is checked, Group Stacks and Show Minimap unchecked; after unbinding all three are unchecked.
- Given the mounted `AppMenuBar` and a mock `zanshin/menu_state` handler, when the project window becomes key, then an `apply` arrives whose enabled map has all three selectors true; when Projects becomes key, Minimize and Full Screen are false.
- Given the runner, when built (`flutter build macos --debug`), then it compiles.

## Review Triage Log

### 2026-11-02 — Review pass
- verdicts: 24 findings — high 0, medium 0, low 14, false 8, maybe-false 2
- findings:
  - `[low]` `[patch]` blind: a `PlatformException` (bad-args) from `apply` escapes `unawaited` as an uncaught error — `_apply` now also catches `PlatformException` and logs a warning.
  - `[low]` `[reject]` blind: the strict parse accepts 0/1 as Bool — Dart only ever sends bools; a CFBoolean check adds code for an unseen payload.
  - `[low]` `[defer]` blind: in full screen Minimize/Zoom stay enabled and the title stays "Enter Full Screen" — pre-existing since 11.13 (no validation with `autoenablesItems = NO`); deferred, mirrored.
  - `[false]` `[reject]` blind: unknown window keys get everything enabled — every window the app opens has one of the four keys (`app_windows.dart:25-34`); the splash is never key in the tracker's sense of an `AppWindows` key, and `keyOfView` returns null for it (all grey).
  - `[low]` `[reject]` blind: no test that nothing is applied during the boot — one `if (model case …)`; the boot shows only the splash.
  - `[low]` `[patch]` blind: no test shows a preference change reaching the channel — the mounted-bar test now toggles Detailed Cards and asserts the last `apply`'s checked entry each time.
  - `[low]` `[reject]` blind: the boot menu bar gets no native state — the model attaches right after the boot; the splash window has no menu-driven work.
  - `[low]` `[defer]` blind: the native XCTests run in no gate step — ran by hand here (`xcodebuild test … -only-testing:RunnerTests`, 2 passed); a gate step is a gate change for Ralph; mirrored.
  - `[low]` `[reject]` blind: `handle(_:result:)` untested — after the parent's refactor it is glue over the tested `Payload` and `apply(_:to:)`.
  - `[low]` `[patch]` blind: the Show Minimap entry is a no-op — deleted with its comment; tests updated.
  - `[false]` `[reject]` blind: top-menu title lookup ambiguous — the eight top labels and the View items are distinct ARB strings; the same labels the engine titles the items with.
  - `[low]` `[patch]` edge: `PlatformException` uncaught — same fix as the first row.
  - `[maybe-false]` `[reject]` edge: AppKit-inserted Window items (tiling) stay enabled once `windowsMenu` is set — would need the running app to see whether AppKit inserts them into a non-autoenabling menu; if true only low.
  - `[false]` `[reject]` edge: the model returning to null leaves stale state — `menu.value` is set once in `main.dart` and never cleared.
  - `[low]` `[reject]` edge: toggles stay checked with no key window while a graph is bound — the graph binds only once the project window is up and focused; a key-window branch would add code for an unreached state.
  - `[low]` `[patch]` verification-gap: native XCTests never executed — the parent ran them (`** TEST SUCCEEDED **`, both cases passed); recorded under verification.
  - `[low]` `[patch]` verification-gap: no test of a toggle change reaching `apply` — same test as above.
  - `[low]` `[patch]` verification-gap: no test that `apply` follows `setMenus` — a shared event log in the rig; the test asserts the last `apply` comes after the last `setMenus`.
  - `[false]` `[reject]` verification-gap (other): checkmarks shown while the items are grey (sheet/busy) — intended: a checkmark shows the preference, greying shows availability; the spec says "while a graph is bound".
  - `[false]` `[reject]` intent: no Dart-assigned identifier — the engine carries none to the native side (`tag` is a per-build serial, `FlutterMenuPlugin.mm:357`); the Dart labels and the selectors are the stable addresses (Design Notes).
  - `[maybe-false]` `[reject]` intent: witnesses exercised on a mock and a hand-built `NSMenu`, not the engine's menu — the running-app check is recorded as open; native tests can not drive the engine's menu unattended.
  - `[false]` `[reject]` intent: Show Minimap should default on — the item has no handler and no state until 10.16; it stays grey and unchecked.
  - `[false]` `[reject]` intent: `windowsMenu` set "when differs" rather than "if unset" — each `Menu.setMenus` replaces the menu, so "if unset" would leave it pointing at a dead menu; I2 asks for "after each `Menu.setMenus`".
  - `[false]` `[reject]` intent: no-key-window greying not in the table — what AppKit's own validation does without a key window; the spec's matrix states it.

## Design Notes

Addressing: the engine assigns no stable id a native side could see (`tag` is a per-build serial), so toggles are found by top-menu title + item title (Dart's own labels, unique within a menu) and system items by selector (title-independent). The Window submenu is found by `arrangeInFront:`, so `windowsMenu` follows every rebuilt menu. `NSApp.windowsMenu` is reassigned only when it differs.

## Verification

**Commands:**
- `flutter test test/features/shell/app_menu_test.dart` in `app/` -- passes; then full `flutter test` in `app/`
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed .` in `app/` -- clean
- `flutter build macos --debug` in `app/` -- builds

**Manual checks (if no CLI):**
- The running app: checkmarks, greying and the Window list — not reachable unattended (Marionette cannot see the native menu); recorded as open.

## Auto Run Result

Status: done. Code commit `b131abd3fc2a458202ff287123860dcc8c2a6f15`.

**Summary.** After every menu-bar build, `AppMenuBar` sends `apply` on the new channel `zanshin/menu_state` (post-frame, so behind the engine's `Menu.setMenus` on the same messenger): View › Detailed Cards and Group Stacks with their checked state from the bound graph's preferences, and the enabled state of Minimize, Zoom and Enter Full Screen by AppKit selector, following the key window (11.13's greying table; all grey with no key window). The runner's `MenuStateChannel` parses the payload strictly, sets `state` / `isEnabled` on the current `NSApp.mainMenu` and points `NSApp.windowsMenu` at the submenu holding `arrangeInFront:`.

**Files.**
- `app/lib/src/features/shell/app_menu.dart` — `menuStateChannel`, `AppMenuModel.windowItemsEnabled`, `AppMenuModel.nativeState`, `AppMenuBar`'s post-frame `apply` (missing handler ignored, `PlatformException` logged).
- `app/macos/Runner/WindowingBootstrap.swift` — `MenuStateChannel` (`Payload`, static `apply(_:to:)`, `windowsMenu`), registered in `start()`.
- `app/macos/RunnerTests/RunnerTests.swift` — XCTests for `apply` on an engine-shaped menu and for malformed payloads.
- `app/test/features/shell/app_menu_test.dart` — `windowItemsEnabled` per key, `nativeState` checkmarks, the mounted bar's `apply` (key window, preference toggle, after `setMenus`).

**Deferred-work items.**
- I1 — fixed (`b131abd3`): the toggles carry checkmarks and Minimize, Zoom and Enter Full Screen grey per the DS table for the dialog windows, through the native channel. Show Minimap stays unchecked and grey until 10.16 gives it state and a handler. The running-app look is unchecked (see below).
- I2 — partly done (`b131abd3`): `NSApp.windowsMenu` is set to the Window submenu after each menu build, so AppKit has a menu to list the windows in; what is left is the visual check in the running app (not possible unattended).

**Review.** One pass, 24 findings (high 0, medium 0, low 14, false 8, maybe-false 2). Patches (all low): `PlatformException` caught and logged; Show Minimap no-op entry removed; tests for a preference change reaching `apply` and for `apply` following `setMenus`; native XCTests run. Deferred (2, mirrored to deferred-work.md): full screen does not grey/retitle (pre-existing engine validation gap); the runner's XCTests are in no gate step. Rejected with reasons in the triage log: integer-as-Bool parsing, unknown keys, boot apply test, boot state, `handle` test, title ambiguity, AppKit tiling items (maybe-false), model back to null, toggles with no key window, checkmarks on grey items, Dart-assigned ids, mock-level witnesses (maybe-false), Show Minimap default on, "if unset", no-key greying. Follow-up review recommended: false (patched entries: high 0, medium 0, low 5).

**Verification notes** (gate rule of this run: no `cargo make test`).
- `flutter test test/features/shell/app_menu_test.dart` in `app/`: 19 passed.
- `flutter test` in `app/`: 1813 passed, 5 failed — all in `worker_project_repos_test.dart` (XDG_CONFIG_HOME is pinned only under `cargo make`), untouched by this change.
- `dart analyze --fatal-infos --fatal-warnings` in `app/`: no issues. `dart format --set-exit-if-changed .` in `app/`: 0 changed.
- `flutter build macos --debug` in `app/`: built.
- `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -configuration Debug -only-testing:RunnerTests` in `app/macos/`: TEST SUCCEEDED, both new cases passed.
- No Rust, FFI or jj verb touched: no cargo checks, codegen or parity oracle needed.
- Not checked: the running app's native menu bar (checkmarks, greying, the Window list) — Marionette cannot reach it; open for a visual check.

**Residual risks.** The `setMenus` → `apply` order rests on both channels sharing the default messenger (FIFO); the Dart-side order is tested, the native arrival is not. Whether AppKit fills the reassigned `windowsMenu` with the already-open windows is unverified.
