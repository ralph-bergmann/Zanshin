---
title: 'Story 11.28 — View › Enter Full Screen reads "Exit Full Screen" in full screen; Minimize and Zoom grey there'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: '102f039e43262bd30b11cf7c8fe9826eb145083e'
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

**Problem:** In full screen the View menu still reads "Enter Full Screen", and Window › Minimize and Zoom stay enabled. AppKit retitles and greys these items only while it validates them, and the engine builds every submenu with `autoenablesItems = NO`, so no validation runs (deferred-work I1, from Story 11.17).

**Approach:** The menu model follows the key window's full-screen state from the shell's window-chrome reports. `zanshin/menu_state`'s `apply` carries the full-screen item's title by selector beside `enabled` (Dart's ARB labels), and greys Minimize and Zoom for a key window in full screen. The runner sets the title the way it sets `isEnabled`.

## Boundaries & Constraints

**Always:**
- Title of `toggleFullScreen:`: "Exit Full Screen" while the key window is in full screen, else "Enter Full Screen". Both are ARB strings in `app/lib/l10n/app_en.arb`; Dart sends one of them with every `apply`, so the item carries Dart's label after each menu rebuild.
- In full screen, Minimize (`performMiniaturize:`) and Zoom (`performZoom:`) are grey; Enter/Exit Full Screen stays enabled. Every other rule of `windowItemsEnabled` is unchanged.
- The key window's full-screen state comes from `ZanshinShell.onWindowChromeChanged` (the window roots watch their views; the report says full screen from `willEnterFullScreen` to `didExitFullScreen`). The model re-sends its state when the key window's state changes, on a key-window change, and after every menu build (today's post-frame `apply`).
- Native parsing stays strict: `titles` is a required `{selector: String}` map; a malformed payload changes nothing (`bad-args`). An item not found is skipped.

**Never:** an engine fork or patch; `autoenablesItems = YES`; a menu label in Swift; titles for other validation-driven items; changes to the other selector items' rules.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Project window key, windowed | key = main, not full screen | title "Enter Full Screen"; all three enabled | — |
| Project window key, full screen | key = main, report `fullScreen: true` | title "Exit Full Screen"; Minimize and Zoom grey, full screen enabled | — |
| Leaves full screen | report `fullScreen: false` for main | title "Enter Full Screen"; all three enabled again | — |
| Dialog key over a full-screen project window | key = revset-configs, main in full screen | title "Enter Full Screen"; the dialog's own rules (Minimize and Full Screen grey, Zoom enabled) | — |
| No key window | none | title "Enter Full Screen"; all three grey | — |
| Menu rebuild in full screen | e.g. Show Minimap toggled | `apply` after the new `setMenus` again carries "Exit Full Screen" | — |
| Malformed `titles` | missing, or a non-string value | nothing changes | `FlutterError(bad-args)` |

</intent-contract>

## Code Map

- `app/lib/src/app/menu/app_menu.dart` -- `menuStateChannel` (:30); selectors `_minimize`, `_zoom`, `_fullScreen` (:33-35); constructor listeners (:60-78); `_changed` (:120, microtask-coalesced `notifyListeners`); `_keyWindow` (:134, from `_tracker.keyView`); `windowItemsEnabled(String? key)` (:641-645); `nativeState` (:649-664, `{'checked', 'enabled'}`); `dispose` (:686-698); `AppMenuBar` (:703-740) applies `nativeState` post-frame after each build.
- `packages/zanshin_shell/lib/src/zanshin_shell.dart:41` -- `ZanshinShell.onWindowChromeChanged` (`WindowChromeChange = ({int viewId, WindowChrome chrome})`, `packages/zanshin_shell_platform_interface/lib/src/window_chrome.dart:32`). The `zanshin_shell` import already brings both (`app/lib/src/features/window/window_chrome_builder.dart` uses them).
- Read-only: `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/WindowChromeHost.swift` -- sends `changed` only when the report differs; `measure()` (:252) reports full screen from `willEnterFullScreen` (or `styleMask .fullScreen`) on. Each window root watches its view on its first frame (`window_chrome_builder.dart:51-61`), before a user can enter full screen, so the stream alone sees every transition.
- Read-only: `~/development/sdks/flutter/engine/src/flutter/shell/platform/darwin/macos/framework/Source/FlutterEngine.mm:1083` -- view ids only increase (`_nextViewIdentifier++`), so a closed window's id never comes back; stale ids in a set are harmless.
- `app/macos/Runner/WindowingBootstrap.swift` -- `MenuStateChannel` (:77-151): `handle` bad-args message (:96), `Payload` (:110-129), static `apply(_:to:)` (:134-150, `enabled` loop over submenus by `NSSelectorFromString`).
- Read-only: `app/macos/Runner/Base.lproj/MainMenu.xib:254` -- the `toggleFullScreen:` item the engine copies into every build (title "Enter Full Screen").
- `app/macos/RunnerTests/RunnerTests.swift` -- `menuBar()` (:10-27), `testApplySetsCheckmarksEnabledStateAndFindsTheWindowMenu` (:29), `testAMalformedPayloadIsRejected` (:52).
- `app/lib/l10n/app_en.arb` -- View strings (:1175-1184); `flutter gen-l10n` in `app/` regenerates `app/lib/l10n/app_localizations*.dart`.
- `app/test/app/menu/app_menu_test.dart` -- `_Rig` (:192, menu made at :242), `focus` (:277), `windowItemsEnabled` test (:964), `nativeState` test (:980), mounted `AppMenuBar` apply test (:1004).
- `app/test/helpers/recording_shell.dart` -- fake shell; `chromeChanges` (:29) feeds `onWindowChromeChanged`; install with `ZanshinShellPlatform.instance = shell`.
- Tests that build an `AppMenuModel` and need a fake shell installed first: `app/test/app/boot/boot_window_host_test.dart:116`, and every test that reads `TestComponent.application` (`zanshin_app_test`, `zanshin_application_test`, `home_page_test`, `projects_window_test`, `zanshin_window_root_test`, `project_graph_host_test`; most install `RecordingShell` already).
- `_bmad-output/implementation-artifacts/design_system/readme.md` -- MENU BAR: View (:247 "Enter Full Screen ⌃⌘F"), Window (:250 Minimize/Zoom greying); `_bmad-output/implementation-artifacts/design/DESIGN-SYSTEM-SYNC.md` (last entry #28, :289).

## Tasks & Acceptance

**Execution:**
- `app/lib/l10n/app_en.arb` -- add `menuEnterFullScreen` "Enter Full Screen" and `menuExitFullScreen` "Exit Full Screen" with descriptions; run `flutter gen-l10n` in `app/` -- Dart owns the labels.
- `app/lib/src/app/menu/app_menu.dart` -- the model subscribes to `ZanshinShell.onWindowChromeChanged` in its constructor and keeps the set of full-screen view ids (add/remove per report; `_changed()` only when the set changed), cancelled in `dispose`; `windowItemsEnabled(String? key, {bool fullScreen = false})` greys Minimize and Zoom when `fullScreen`; `nativeState` passes the key view's state and adds `'titles': {toggleFullScreen: Exit/Enter label}`; update the doc comments (channel, `windowItemsEnabled`, `nativeState`) -- the Dart half.
- `app/macos/Runner/WindowingBootstrap.swift` -- `Payload.titles: [String: String]` (required, strict); `apply` sets `title` on the items whose action matches, like `isEnabled`; bad-args message and class doc name titles -- the native half.
- `app/macos/RunnerTests/RunnerTests.swift` -- payloads carry `titles`; the apply test asserts "Exit Full Screen" set on the `toggleFullScreen:` item; the malformed test rejects a missing `titles` and a non-string title -- native witnesses.
- `app/test/app/menu/app_menu_test.dart` -- the rig installs a `RecordingShell` before the menu is made and gets a helper that pushes a full-screen report for a window; `windowItemsEnabled` test gains the full-screen cases; a `nativeState` test for title and greying in and out of full screen, and for a dialog key over a full-screen project window; the mounted-bar test checks `titles` on the apply after entering full screen and after a rebuild (a preference toggle) while in full screen -- Dart witnesses.
- Tests that build the menu without a fake shell (`boot_window_host_test.dart`, others found by the full `flutter test` run) -- install a `RecordingShell` first.
- `design_system/readme.md` :247 and :250 + `design/DESIGN-SYSTEM-SYNC.md` #29 -- the DS menu list says the item reads "Exit Full Screen" in full screen and Minimize and Zoom grey there; publishing waits for a console session.

**Acceptance Criteria:**
- Given the project window is key and enters full screen, when the menu applies its state, then `apply` carries `titles: {toggleFullScreen:: "Exit Full Screen"}` and Minimize and Zoom `false`; after it leaves full screen, "Enter Full Screen" and all three `true`.
- Given the project window is in full screen, when the menu is rebuilt (a preference toggle), then the `apply` that follows the new `setMenus` again carries "Exit Full Screen".
- Given a payload with `titles`, when the runner applies it to an engine-shaped menu, then the `toggleFullScreen:` item's title is the given one; given a payload without `titles` or with a non-string title, then it is rejected.
- Given the runner, when built (`flutter build macos --debug`), then it compiles and the runner XCTests pass.

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 20 findings — high 0, medium 2, low 10, false 5, maybe-false 3
- findings:
  - `[low]` `[patch]` (verification-gap) The runner apply test sends `toggleFullScreen: true` to an item already enabled by default, so it no longer proves the enabled write reaches the View submenu — the fixture's full-screen item now starts disabled, so the `true` assertion proves the write.
  - `[medium]` `[patch]` (blind) `zanshin_app_test` tests at :108, :126, :144, :194 build `AppMenuModel` without a shell and pass only on a shell an earlier test left; run alone one failed with `StateError: No ZanshinShellPlatform registered` (reproduced here) — a top-level `setUp` installs a fresh `RecordingShell`.
  - `[low]` `[patch]` (blind) The DS readme still says "Synced through #28" and its dated list has no #29 line — marker raised to #29 and a dated line added; #29 names the Sync section.
  - `[low]` `[patch]` (blind) The add/remove guard in `_chromeChanged` (no rebuild when the full-screen set is unchanged) has no test — the mounted-bar test pushes reports that change nothing and asserts no new `setMenus`.
  - `[low]` `[patch]` (blind) `nativeState` read full screen from the raw key view but `enabled` from `_keyWindow`; a key view without a live window could read "Exit Full Screen" with all items grey — full screen now counts only with a live key window; the nativeState test covers a key view with no window.
  - `[low]` `[patch]` (blind) Closed windows' ids stay in `_fullScreenViews` and the comment does not say why that is safe — same root cause as the row above; the comment now says the engine never reuses a view id, and the live-key check ignores closed windows.
  - `[low]` `[patch]` (blind) The comment names only half the ordering assumption (the model must exist before any window can be in full screen; true today, `lib/main.dart` builds `component.application` before `app.start()`) — comment extended.
  - `[false]` `[reject]` (blind) Bookkeeping not updated (deferred-work I1 bullet, sprint-status) — the dispatch reserves the I1 bullet for the loop; finalize sets sprint-status.
  - `[low]` `[patch]` (blind) DS readme menu lines put the full-screen rule inside Zoom's parentheses and omit Enter Full Screen's greying for the dialogs and Zoom's for Settings — :247 and :250 reworded to match `windowItemsEnabled`.
  - `[low]` `[patch]` (blind) The `missingSelector:` title is sent in the runner test but never asserted skipped — the test asserts no submenu item is titled "Missing".
  - `[low]` `[patch]` (edge) A closed full-screen window's id stays in the set; a lingering key view would read "Exit Full Screen" — same root cause and fix as the two-key-sources row.
  - `[maybe-false]` `[reject]` (edge) AppKit-inserted Window tiling items (Fill, Center, Move & Resize) stay enabled in full screen — needs the running app to see whether AppKit inserts them into the engine's non-validating Window menu; if true only low (the intent names Minimize and Zoom; same item 11.17 rejected).
  - `[low]` `[reject]` (intent) The title switches at `willEnterFullScreen` / `didExitFullScreen` rather than at menu-open time — the transition lasts under a second and the menu bar is not in use during it; a fix needs native timing code.
  - `[false]` `[reject]` (intent) No test checks the watch-order assumption — the bad outcome (a window in full screen before the model listens) cannot happen: the model is made before the first window opens and a root watches its view on its first frame; the comment now states both.
  - `[false]` `[reject]` (intent) The runner test never checks that the engine's real `toggleFullScreen:` item is found by action — the engine finds the xib item by action and returns `[found copy]` (`FlutterMenuPlugin.mm` `createPlatformProvidedMenu`), so the copy keeps the action; 11.17's enabled write uses the same lookup.
  - `[false]` `[reject]` (intent) "A malformed payload changes nothing" is tested only as `Payload(...) == nil` — `handle` returns `bad-args` before `apply` when `Payload` is nil (`WindowingBootstrap.swift:92-99`).
  - `[maybe-false]` `[reject]` (intent) The running-app witness is open — the native menu is not reachable unattended (Marionette cannot see it); the check is handed to the console session and recorded under Auto Run Result.
  - `[medium]` `[patch]` (intent) The model subscribes without a platform guard, so every test that builds it needs a fake shell — same root cause as the `zanshin_app_test` row; fixed there (a guard would not help: tests run on macOS).
  - `[false]` `[reject]` (intent) Reading D incomplete (no Auto Run Result, outcomes or hash yet) — finalize writes them.
  - `[maybe-false]` `[reject]` (intent) The payload sends the full-screen state's result (title, enabled) rather than a raw flag — matches epics.md 11.28 scope 2 ("titles by selector, beside enabled"); I1's "send the full-screen state" is met by its consequence; if anything only low.

## Design Notes

Why a set of full-screen view ids in the model rather than a value per window root: the menu model is a singleton that already follows the key view (`ActiveWindowTracker`); the shell's change stream carries every view's report, and the key view picks the one that counts. `watch` answers are not on the stream, but no window is in full screen when its root first watches it, so the stream sees every entry and exit.

## Verification

**Commands:**
- `flutter gen-l10n` in `app/` -- regenerates without errors
- `flutter test test/app/menu/app_menu_test.dart` in `app/` (pinned env) -- passes; then full `flutter test` in `app/` (pinned env) -- no new failures
- `dart analyze --fatal-infos --fatal-warnings` and `dart format --set-exit-if-changed .` in `app/` -- clean
- `cargo make --allow-private test-runner` from the repo root -- TEST SUCCEEDED (builds the app and runs the runner XCTests with a throwaway home)

**Manual checks (if no CLI):**
- The running app: View reads "Exit Full Screen" in full screen and "Enter Full Screen" after leaving, also after toggling Show Minimap in full screen; Minimize and Zoom grey in full screen. Not reachable unattended (Marionette cannot see the native menu); open for a console session.

## Auto Run Result

Status: done. Code commit `08723bd4450c4704ca976685393960afd19a6327`.

**Summary.** The menu bar now follows full screen. `AppMenuModel` listens to `ZanshinShell.onWindowChromeChanged` and keeps the set of full-screen view ids; full screen counts only for a live key window. `windowItemsEnabled(key, fullScreen:)` greys Minimize and Zoom in full screen (Enter/Exit Full Screen keeps its rule). `nativeState` adds `titles: {toggleFullScreen:: "Exit Full Screen" | "Enter Full Screen"}` (ARB strings `menuExitFullScreen` / `menuEnterFullScreen`), sent with every post-frame `apply`, so the title holds after each menu rebuild. The runner's `MenuStateChannel` parses `titles` strictly (required, strings only) and sets `title` by selector the way it sets `isEnabled`.

**Files.**
- `app/lib/l10n/app_en.arb` (+ generated `app_localizations*.dart`) — `menuEnterFullScreen`, `menuExitFullScreen`.
- `app/lib/src/app/menu/app_menu.dart` — the full-screen set from the shell's chrome stream, `windowItemsEnabled(…, fullScreen:)`, `nativeState` titles, one key source.
- `app/macos/Runner/WindowingBootstrap.swift` — `Payload.titles`, `apply` sets titles, bad-args message and class doc.
- `app/macos/RunnerTests/RunnerTests.swift` — apply sets the title and the enabled write (fixture starts disabled), an unknown selector's title is skipped; missing or non-string `titles` refused.
- `app/test/app/menu/app_menu_test.dart` — the rig installs a `RecordingShell`; full-screen cases for `windowItemsEnabled`; a `nativeState` walk (no key, project window, full screen, Configurations over it, back, leaving, a key view without a window); the mounted bar's `titles` after entering full screen, after a Show Minimap rebuild, no rebuild for reports that change nothing, and after leaving.
- `app/test/app/boot/boot_window_host_test.dart`, `app/test/app/zanshin_app_test.dart` — install a `RecordingShell` before the menu model is made.
- `_bmad-output/implementation-artifacts/design_system/readme.md` (Sync marker #29, dated line, View and Window menu lines) and `design/DESIGN-SYSTEM-SYNC.md` #29. Not published (waits for a console session).

**Deferred-work items.**
- I1 — fixed (`08723bd4`): in full screen the item reads "Exit Full Screen" and Minimize and Zoom are grey, over `zanshin/menu_state` with ARB labels; leaving full screen restores "Enter Full Screen" and today's rules. The running-app look is unchecked (see below).

**Review.** One pass, 20 findings (high 0, medium 2, low 10, false 5, maybe-false 3). Patched entries: medium 1 (order-dependent `zanshin_app_test` tests without a shell, reproduced alone; the platform-guard row shares it), low 7 (the runner test's enabled write, the `missingSelector:` assertion, the DS Sync marker, the DS menu lines, the `_chromeChanged` guard test, one key source for full screen with the stale-id comment, the ordering comment). Deferred: none. Rejected with reasons in the triage log: bookkeeping (false), AppKit tiling items (maybe-false, low if true), transition timing (low), watch-order test (false), engine item lookup (false), malformed payload through `handle` (false), running-app witness (handed to a console session), Reading D (false), derived payload vs a raw flag (maybe-false, low if true). Follow-up review recommended: false (one medium and no high entry patched).

**Verification notes** (gate rule of this run: no `cargo make test`, `test-full` or `coverage`).
- `flutter gen-l10n` in `app/`: regenerated, no errors.
- `dart analyze --fatal-infos --fatal-warnings` in `app/`: no issues. `dart format --set-exit-if-changed .` in `app/`: 0 changed (before and after the patches).
- `flutter test` in `app/`, pinned env: 2589 passed, before and after the review patches.
- `flutter test test/app/zanshin_app_test.dart --plain-name …` alone for the four tests that build the menu through `component()`: each passes (failed with `StateError` before the patch).
- `cargo make --allow-private test-runner` (throwaway home): built, 6/6 runner XCTests passed, before and after the patches.
- No Rust, FFI, schema or jj verb touched: no cargo checks, codegen or parity oracle needed.
- Not checked: the running app's native menu in and out of full screen and after a rebuild there — Marionette cannot reach it unattended; open for a console session.

**Residual risks.** The model learns full screen only from the change stream, never from `watch` answers; this holds because the model is made before the first window and each root watches its view on its first frame. The title switches with the chrome report (from `willEnterFullScreen` to `didExitFullScreen`), not at menu-open time. AppKit's own tiling items in the Window menu are not greyed in full screen (unverified whether AppKit inserts them there).
