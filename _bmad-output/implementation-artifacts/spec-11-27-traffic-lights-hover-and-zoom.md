---
title: 'Story 11.27 — The traffic lights hold still on hover and follow the zoom; the top bar keeps 12 × zoom'
type: 'bugfix'
created: '2026-11-16'
status: 'done'
baseline_revision: 'b6b202e719812ba73c7e9be479d6fb924439a7c4'
review_loop_iteration: 0
followup_review_recommended: true
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      At 150 % the project window's lights sit at 51 pt (44–58); on a macOS whose titlebar is shorter than about 59 pt they would leave their superview and be clipped.
    evidence: |-
      placeWindowButtons() puts the centre at window height − buttonMidY with no clamp to the button's superview; the deployment target is 12.0. The XCTest shows the buttons inside the titlebar at 51 on macOS 27 (66 pt titlebar); macOS 12–15 was not checked (an empty unified toolbar there may give 52 pt). Settle by running the app at 150 % on macOS 15 or reading the titlebar height there; if short, clamp or cap the zoom per OS.
    location: >-
      app/macos/Runner/MainWindowChrome.swift (placeWindowButtons)
    severity: medium (unverified)
  - summary: >-
      The runner's XCTests, which now witness the hover fix and the restore / placeButtons parsing, still run in no gate step.
    evidence: |-
      No Makefile.toml task or gate_plan.rs rule runs xcodebuild test (already recorded for Stories 11.17 and 11.26 in deferred-work.md); this run ran them by hand (6 passed). Reverting the frame observer to a synchronous move would pass the gate.
    location: >-
      Makefile.toml; crates/xtask/src/tasks/gate_plan.rs
    severity: medium
---

<intent-contract>

## Intent

**Problem:** Two faults of Story 11.26. Hovering the project window's traffic lights leaves the zoom button 8 pt high (centre 26) and the top bar jumps 4 pt with it: `MainWindowChrome` moves the buttons inside their own frame notifications, AppKit drops a move made there and lays the titlebar out again (about 25 rounds per hover), and the bar follows the measured block's centre. Under a Settings zoom other than 100 % the gap above the bar is 34 − 22 × zoom (1 pt at 150 %) instead of 12 × zoom, because the lights sit at a fixed 34 pt (inbound ledger items I1, I2).

**Approach:** (1) Dart sends the project window's button line, `ZsMetrics.standard.tlMidY × zoom` (30.6 / 34 / 37.4 / 42.5 / 51 pt at 90–150 %), with `restore` and on every zoom change; the runner keeps no constant. (2) A button frame notification only marks the placement pending and sets the overlay's `needsLayout`; the correction runs in `TrafficLightOverlayView.layout()` and in a main run-loop `beforeWaiting` observer at order 1_999_999 (probe-verified). (3) `ZsMetrics.resolve` takes only x and width from a measured block, so the project window's bar keeps the reference line 34 (zoomed units = 12 × zoom native); `ZsWindowScaffold` (dialogs) centres on the measured block's centre itself. (4) DS readme and a sync entry.

## Boundaries & Constraints

**Always:**
- Only the project window (`main` chrome) moves its buttons; x stays AppKit's. Dialog windows (Settings, Projects, Configurations) keep the system position and their header keeps the measured centre line (`ZsMetrics.dialogTlMidY` without a block). Full screen unchanged.
- The existing placement triggers stay: setup (init and the next run-loop turn), resize, key, leaving full screen, replaced buttons, button frame changes. None moves a button inside that button's own frame notification. A new line from Dart (`placeButtons`) moves at once — it never arrives inside a notification.
- The move stays idempotent (0.5 pt tolerance) and skips full screen and buttons in another window. The rings follow through their own frame observers.
- `restore` keeps its strict parsing: the `main` chrome requires a numeric `buttonMidY`; `secondary` takes none. `placeButtons` finds its window among the store's open chromes by handle, without dereferencing a handle that may have closed.
- `WindowChromeHost` keeps measuring and reporting the block unchanged.

**Never:**
- Retry what failed in the probe: shifting `NSTitlebarView`'s bounds, moving `NSTitlebarContainerView`, a taller `.top` titlebar accessory, a 68 pt toolbar item.
- Zoom steps above 150 % (titlebar 66 pt), new views in the titlebar or below the Flutter view, window frame changes, token changes in the DS.
- The Marionette check, native screenshots and the DS publish (console session). No `cargo make test` / `test-full` / `coverage` (story-loop gate rule). Absolute paths, never a bare `cd`; jj never in a real repo; edits via Edit/Write only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Project window opens at a zoom | zoom 1.5 | `restore` carries `buttonMidY` 51 (Dart test); the runner centres the buttons at 51 (XCTest) | none |
| Zoom changes | 1 → 1.1 → 1.5 with the project window and a dialog open | the project window gets `placeButtons` 37.4, then 51; dialogs get none (Dart test); the runner follows the new line (XCTest) | none |
| AppKit sets a button back | a button's frame moved 8 pt up by hand | right after the call the button is still where it was put (no move inside the notification); after the layout pass / run-loop turn it is back on the line (XCTest) | none |
| A block reaches the project window | blocks (19, 27), (19, 19), (20, 20), 60 × 14 | first island at block end + 12; bar 12, content 68 whatever the block's y (Dart tests) | none |
| A block reaches a dialog | block (20, 20, 60, 14) | header centres on 27; without a block on 26 (existing scaffold test) | none |
| Malformed runner call | `restore` main without `buttonMidY`; `placeButtons` with a bad or unknown handle | `bad-args` error; an unknown handle changes nothing | FlutterError `bad-args` |

</intent-contract>

## Code Map

- `app/macos/Runner/MainWindowChrome.swift` -- `buttonMidY` static 34 (:46) → instance line from Dart; `placeWindowButtons()` (:166, guard `kind == .main`), `observeFrames(of:)` (:190, the observer that moves synchronously — the root cause), `installTrafficLightOverlay()` (:218, both reuse and create paths), handlers (:263-286); `TrafficLightOverlayView` (:318) needs a `layout()` override with a callback. Probe diff (reference only): `/private/tmp/claude-502/-Users-ralph-bergmann-development-projects-privat-Zanshin/6ee27237-6c64-4675-922a-fb4c6a369ccc/scratchpad/hover/probe.diff`.
- `app/macos/Runner/WindowFrameStore.swift` -- `handle(_:result:)` (:116) accepts only `restore`; `restore(...)` (:154) builds `MainWindowChrome(window:kind:)`; `chrome` dict (:98) keyed by `ObjectIdentifier`.
- `app/macos/RunnerTests/RunnerTests.swift` -- 11.26's two XCTests (:95, :123) use `MainWindowChrome.buttonMidY`; helpers `plainWindow`, `settle`, `midsFromTop`, `assertCentred`.
- `app/lib/src/features/window/remembered_window_controller.dart` -- `ProjectWindowPlan` (:107), `NativeWindowPlan.runnerArguments` (:101), `windowFramesChannel` (:61), `RememberedWindowController` (:145, has `windowHandle`).
- `app/lib/src/features/window/app_windows.dart` -- `AppWindowRequest` (:125), `planNativeWindow` (:167), `AppWindows` ctor (:223, seams `createController`/`exitProcess`), `zoom` setter (:282, `case final WindowController window` is the project window), `_create` (:373).
- `app/lib/src/features/window/zanshin_window_root.dart` -- comment at :92-93 ("the native buttons themselves never scale") becomes stale; logic unchanged.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` -- `resolve()` (:147-156) sets `tlMidY: block.center.dy`; doc of `tlMidY` (:351).
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` -- `midY` (:179-182) reads `metrics.tlMidY`.
- Tests pinning the old block-derived bar: `packages/zanshin_ui/test/design/zs_tokens_test.dart` (:391-409), `app/test/app/zanshin_app_test.dart` (:302-329, :346-347), `app/test/widgetbook/catalogue_windows_test.dart` (:111-112, :130-131); `app/test/features/window/app_windows_test.dart` (:157 exact restore map, :596 zoom at creation, :620 zoom change); `app/test/macos/runner_chrome_assets_test.dart` (:87-95 pins the Swift constant `static let buttonMidY`).
- DS: `_bmad-output/implementation-artifacts/design_system/readme.md` (:122 Space & layout, :126 Density and zoom "the traffic lights stay"), `design_system/tokens/spacing.css` (:25-27 comment "bar centre y = the block's centre"), `design/DESIGN-SYSTEM-SYNC.md` (last entry #27, :281).
- Read-only: `packages/zanshin_shell_macos/.../WindowChromeHost.swift` (reports the union; x/width do not change when only y moves), `app/lib/src/features/window/window_zoom.dart` (`bindWindowZoom` sets `AppWindows.zoom` before the first window).

## Tasks & Acceptance

**Execution:**
- `app/macos/Runner/MainWindowChrome.swift` -- replace the static constant with `var buttonMidY: CGFloat?` (init parameter, nil for dialogs; `didSet` places at once); `placeWindowButtons()` guards on it and clears a `placementPending` flag; the button frame observer only sets `placementPending` and `trafficLightOverlay?.needsLayout = true`; the overlay gets `var onLayout` called from `override func layout()`, wired to `placeWindowButtons()` on both install paths; a `CFRunLoopObserver` (`beforeWaiting`, repeats, order 1_999_999, `.commonModes`, invalidated in `deinit`) places when pending; update the class doc. -- scope 1 + 2.
- `app/macos/Runner/WindowFrameStore.swift` -- `restore` parses `buttonMidY` (required for `main`) and passes it to the chrome; new method `placeButtons {window, buttonMidY}` sets the line on the matching open chrome (matched by handle). Doc comment names both. -- the native end of the line.
- `app/macos/RunnerTests/RunnerTests.swift` -- construct with `buttonMidY: 34`; after the hand reset assert the button is still off the line before `settle` (no move inside the notification), then on the line; new test: the line follows `buttonMidY` = 51 and 30.6 (and the button stays inside its superview's bounds at 51); the dialog test compares against 34. -- native witnesses.
- `app/lib/src/features/window/remembered_window_controller.dart` -- `ProjectWindowPlan.buttonMidY` (required) added to its `runnerArguments`; `RememberedWindowController.placeButtons(double midY)` invokes `placeButtons` on `windowFramesChannel`. -- Dart end of the line.
- `app/lib/src/features/window/app_windows.dart` -- `projectButtonMidY(double zoom) => ZsMetrics.standard.tlMidY * zoom`; `AppWindowRequest.zoom` (default 1, set from `_zoom` in `_create`); `planNativeWindow` passes `projectButtonMidY(request.zoom)`; a `WindowButtonPlacer` seam (default calls `placeButtons` on a `RememberedWindowController`) called for each project window in the `zoom` setter. -- the zoom path.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` -- `resolve()` takes `tlX`/`tlBlockW` from the block, keeps `tlMidY`; docs say why (transient reports never move the bar; the runner puts the lights on the line). -- scope 3.
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` -- `midY` = full screen ? `metrics.tlMidY` : block centre ?? `dialogTlMidY`. -- dialogs keep the measured line.
- `app/lib/src/features/window/zanshin_window_root.dart` -- fix the stale comment only.
- Tests: `zs_tokens_test` (blocks at any y → bar 12, top 68, x/width from the block), `zanshin_app_test` (rows → bar 12, top 68, island centre on 34; full-screen-exit case 91/12/68), `catalogue_windows_test` (92/12/68), `app_windows_test` (restore map with `buttonMidY` 34.0; at zoom 1.5 the plan's 51; a zoom change records 37.4 / 51 for the project window only), `runner_chrome_assets_test` (replace the constant pin with a pin that the Swift store reads `buttonMidY` and answers `placeButtons`). -- witnesses.
- DS readme :122 and :126, `tokens/spacing.css` comment, `DESIGN-SYSTEM-SYNC.md` #28 (+ app note). -- scope 4.

**Acceptance Criteria:**
- Given the project window at zoom Z in {0.9, 1, 1.1, 1.25, 1.5}, when it opens or the zoom changes, then the runner is told the line 34 × Z and the Flutter bar sits 12 × Z native pt from the top edge, centred on that line.
- Given a project window whose buttons AppKit lays out again (hover, key, resize, theme), when a button's frame changes, then no button is moved inside that notification and the buttons are back on the line before the next commit.
- Given any block report in the project window, when Dart resolves the chrome, then the bar's y and the content top do not change; only the first island's x follows the block.
- Given a dialog window, then its buttons and header behave as before.

## Spec Change Log

- **2026-11-16 — follow-up from a console session (Ralph's fork): the hover symbols.** After this story the lights sat right, but hovering showed coloured buttons without × − +.
  - Cause (measured in a scratch AppKit app with a copy of `MainWindowChrome` and in the real app): AppKit answers "pointer in the button group" (`NSThemeFrame` `_mouseInGroup:`) from its own titlebar layout, not from where the buttons stand. With the deferred move that area stayed 8 pt above the buttons. 11.26 showed the symbols only because it moved inside AppKit's layout (the ping-pong).
  - Fix: `placeWindowButtons()` also sets the titlebar container (`button.superview.superview`) to twice the line high, pinned to the window's top edge, before moving the buttons (as Electron's `window_buttons_proxy.mm`). AppKit resets the container with the buttons on hover; the deferred correction restores both. The class doc names the fallback: own buttons from `NSWindow.standardWindowButton(_:for:)` with `_mouseInGroup:` (private API).
  - Decided by Ralph the same day: stay with moving the system buttons; keep own buttons documented as the fallback. Rejected in the probes: a 74 pt container without moving the buttons (hover stops reacting).
  - Witnesses: `RunnerTests` `assertContainerFollows` at 90 / 100 / 150 %, after a resize and after AppKit resets the container (6/6 green by hand); `cargo make test` green; real app at 100 % and 150 %: symbols shown, lights centred, the project menu in the bar clickable, the zoom button's Move & Resize menu, full screen in and out. Not checked: 90 % in the app, an appearance switch, focus changes between two windows.

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 27 findings — high 0, medium 5, low 12, false 6, maybe-false 4
- findings:
  - `[medium]` `[patch]` (blind) DS prose still says the bar centres on the block / lights at a fixed y 34: readme decision A2 (:309), `window.css` header comment, `TrafficLights.prompt.md` :1 and :8 — reworded to the 11.27 rule (line `--tl-mid-y` × zoom, bar on `--tl-mid-y`, block gives x, dialogs on the measured block) and listed in sync #28.
  - `[low]` `[patch]` (blind) `epic-11-context.md` says the runner keeps a start value; it keeps none (`restore` requires `buttonMidY` for main) — phrase corrected.
  - `[low]` `[reject]` (blind) A zoom change while the project window is being created leaves its lights on the old line — real (`_create` awaits `restore` before `_open` holds the window; the setter walks `_open` only), but it needs ⌘+/⌘− inside one channel round trip at window creation, never met in everyday use, and the fix adds a re-check branch; the window's constraints share the gap since 11.20.
  - `[maybe-false]` `[defer]` (blind) No clamp keeps the 150 % line (51 pt) inside a shorter titlebar on older macOS — the XCTest proves the buttons inside a 66 pt titlebar on macOS 27 only; settle on macOS 15 (titlebar height at 150 %). Deferred, medium (unverified).
  - `[low]` `[reject]` (blind) Each placement re-flags itself (its own `setFrameOrigin` posts a frame notification that sets `placementPending` and the overlay's `needsLayout`, even from inside `layout()`) — real, costs one extra no-op layout pass; no AppKit layout warning showed in the XCTest log; nobody meets it, and the fix adds a guard flag.
  - `[low]` `[patch]` (blind) The reuse path of `installTrafficLightOverlay()` sets `onLayout` again although the overlay is only made in the create path with the same closure — line deleted.
  - `[medium]` `[patch]` (blind) No Dart test runs the real placer or pins the `placeButtons` method and keys — grouped with the verification-gap row below; fix there.
  - `[low]` `[patch]` (blind) `runner_chrome_assets_test`'s `contains('args["buttonMidY"]')` passes on `restore` alone; redundant `(static )?` — now expects two reads (restore, placeButtons) and a plain `let buttonMidY` pattern.
  - `[low]` `[patch]` (blind) No Dart test shows the bar on the runner's line at a zoom other than 100 % — the 125 % window-root test now asserts bar 12 / top 68 in zoomed units and `(chromeBarY + chromeH / 2) × 1.25 == projectButtonMidY(1.25)` (42.5).
  - `[low]` `[reject]` (blind) The spec's Code Map cites the probe diff under the scratchpad, which a reboot clears — the fix edits this build's spec; the parts that matter are in Design Notes.
  - `[low]` `[reject]` (blind) The spec names I1 and I2 without defining them — the fix edits this build's spec; the Auto Run Result names both items with their deferred-work.md titles.
  - `[false]` `[reject]` (blind) Bookkeeping out of step (sprint-status `ready-for-dev`, inbound bullets unmarked) — finalize sets sprint-status; the dispatch reserves the inbound bullets for the main session.
  - `[false]` `[reject]` (blind) `resolve()`'s full-screen `tlMidY: 34` and the scaffold's full-screen branch are dead — they mirror the DS's own `[data-fullscreen]{--tl-mid-y:34px}` re-declaration, a separate token; no wrong value results.
  - `[low]` `[reject]` (edge) Zoom during creation: re-send the line once `_open` holds the window — same root cause as the blind row; rejected there.
  - `[maybe-false]` `[defer]` (edge) Clamp the line to the host's bounds — same root cause as the clamp row; deferred there.
  - `[low]` `[reject]` (edge) An `isPlacing` guard against self-posted notifications — same root cause as the re-flag row; rejected there.
  - `[false]` `[reject]` (edge) An injected placer that throws synchronously escapes the zoom setter — the real placer is `async` and cannot throw synchronously; only tests inject placers, and they return futures.
  - `[low]` `[patch]` (edge) `restoreArguments(chrome: main)` builds a payload the runner now refuses (no `buttonMidY`) while its doc calls it the full payload — `restoreArguments` takes an optional `buttonMidY`, documents that main requires it, and `ProjectWindowPlan.runnerArguments` passes it through it.
  - `[low]` `[reject]` (edge, claim) AC1 "when the zoom changes, the runner is told" fails for a change during creation — same root cause as the zoom-during-creation row.
  - `[maybe-false]` `[defer]` (edge, claim) "the 66 pt titlebar holds 150 %" checked on macOS 27 only — same root cause as the clamp row.
  - `[medium]` `[patch]` (verification-gap) The Dart sender of `placeButtons` and the default placer are never executed or pinned — pure `placeButtonsArguments({window, buttonMidY})` next to `restoreArguments`, used by `RememberedWindowController.placeButtons`, pinned with the main `restoreArguments(buttonMidY:)` map in `remembered_window_args_test`; `AppWindows().placeButtons` pinned `same(placeRememberedWindowButtons)`.
  - `[medium]` `[defer]` (verification-gap) The runner XCTests run in no gate step — pre-existing (deferred-work.md, Stories 11.17 and 11.26); this story adds witnesses to it. Deferred.
  - `[medium]` `[patch]` (verification-gap) `settle()` runs both correction paths, so neither is pinned alone — the centring XCTest now sets a button back and calls only `layoutSubtreeIfNeeded()` (layout path), then with the overlay's `onLayout` cleared sets one back and turns only the run loop (observer path).
  - `[false]` `[reject]` (intent) The per-item outcomes and commit hashes (I1, I2) are missing — the diff was reviewed before finalize, which writes them under Auto Run Result.
  - `[maybe-false]` `[reject]` (intent) The hover test is a hand-made frame change, not AppKit's hover, the zoom button or the tiling menu — the dispatch hands the running-app check (hover, tiling menu, zoom 90–150 %) to the main session.
  - `[false]` `[reject]` (intent) I2 is settled through the bar ignoring the block's y, with no test of a transient or mixed block — a mixed or transient block differs only in y (the union's x span and width are the system's), and `zs_tokens_test` / `zanshin_app_test` / `catalogue_windows_test` feed blocks at y 19, 20, 27, 40 with the bar fixed.
  - `[false]` `[reject]` (intent) `ZsMetrics.of` in a dialog now reports 34 / 12 / 68 — `ZsWindowScaffold` is the only dialog-side reader and centres on the block itself (`zs_window_scaffold_test`: measured 27, none 26); nothing visible changes.

## Design Notes

Why the bar ignores the block's y rather than filtering reports: every transient (AppKit's re-layout mid-move, a zoom change that reaches the runner a frame later) only moves y; x and width come from the system and stay. The runner puts the lights on the reference line, so the reference is the truth and the block confirms x.

Correction sketch (the probe's working parts):

```swift
// frame observer
self?.placementPending = true
self?.trafficLightOverlay?.needsLayout = true
// run-loop observer, just before Core Animation's commit (2_000_000)
CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, 1_999_999) { [weak self] _, _ in
    guard let self, self.placementPending else { return }
    self.placeWindowButtons()
}
```

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` -- expected: pass
- `flutter test test/features/window test/app test/widgetbook test/macos test/features/projects test/features/shell` in `app` -- expected: pass
- `dart analyze` and `dart format --set-exit-if-changed .` in `packages/zanshin_ui` and `app` -- expected: clean
- `flutter build macos --debug` in `app` -- expected: the runner compiles
- `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -configuration Debug -only-testing:RunnerTests` in `app/macos` -- expected: TEST SUCCEEDED, new cases included

**Manual checks (console session, not this run):**
- Native screenshots at 90, 100, 110, 125 and 150 %: 12 × zoom pt from the top edge to the bar, lights centred; hover, the zoom button's tiling menu, resize, full screen in/out, key changes and a theme switch keep all three on one line and the bar still; dialogs unchanged. DS publish.

**Verification notes (step 3, story-loop gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `flutter test` in `packages/zanshin_ui`: 479 passed (incl. `zs_tokens_test`, `zs_window_scaffold_test`, `ds_parity_test`). `dart analyze`: no issues. `dart format --set-exit-if-changed .`: 0 changed.
- `flutter test test/features/window test/app test/widgetbook test/macos test/features/projects test/features/shell` in `app`: 1067 passed, 5 failed — all 5 in `worker_project_repos_test.dart`, which needs the pinned `XDG_CONFIG_HOME`; `cargo make test-app test/features/projects/worker_project_repos_test.dart`: 35 passed. The file is untouched by this story.
- `dart analyze` in `app`: no issues. `dart format --set-exit-if-changed lib test widgetbook`: 0 changed.
- `flutter build macos --debug` in `app`: built.
- `xcodebuild test … -only-testing:RunnerTests`: TEST SUCCEEDED, 6 cases. New: `testTheButtonsFollowTheLineDartSends` (51 inside the titlebar, 30.6) and `testTheStoreTakesTheLineWithRestoreAndPlaceButtons` (added at the matrix audit: `restore` main without or with a mistyped `buttonMidY` → `bad-args`; restore at 34, `placeButtons` 51, `placeButtons` without a line → `bad-args`, an unknown handle → nil and nothing moves; through a fake messenger and the real channel codec). `testTheProjectWindowCentresItsButtonsOnTheTopBar` now also asserts the set-back button is still at 26 right after its frame notification.
- Matrix audit: open at a zoom → `app_windows_test` (plan 51) + the store XCTest (restore 34) + follow-the-line XCTest (51); zoom change → `app_windows_test` (37.4, 51, project window only) + the XCTests; set back → the centring XCTest; block in the project window → `zs_tokens_test`, `zanshin_app_test`, `catalogue_windows_test`; block in a dialog → `zs_window_scaffold_test` (measured 27, none 26); malformed calls → the store XCTest.

**Verification notes (step 4, after the review patches):**
- `flutter test` in `packages/zanshin_ui`: 479 passed; `dart analyze` no issues; `dart format`: 0 changed.
- `flutter test test/features/window test/app test/widgetbook test/macos test/features/projects test/features/shell` in `app`: 1069 passed, the same 5 env-pinned `worker_project_repos_test` cases failed (35 passed under `cargo make test-app` earlier; the file is untouched). `dart analyze` no issues; `dart format`: 0 changed.
- `flutter build macos --debug`: built. `xcodebuild test … -only-testing:RunnerTests`: TEST SUCCEEDED, 6 cases (the centring test now pins the layout path and the run-loop observer path one at a time).

## Auto Run Result

Status: done

**Summary.** The project window's traffic lights now sit at `--tl-mid-y` × zoom from the top edge (30.6 · 34 · 37.4 · 42.5 · 51 pt at 90–150 %); Dart sends the line with `restore` and as `placeButtons` on every zoom change, and the runner keeps no constant. A button frame notification only marks the placement pending; the move runs in `TrafficLightOverlayView.layout()` and in a main run-loop `beforeWaiting` observer (order 1_999_999), never inside the notification that AppKit drops a move from. `ZsMetrics.resolve` takes only x and width from the measured block, so the project window's bar keeps 12 × zoom to the top edge whatever a report says; `ZsWindowScaffold` centres dialog headers on the measured block itself. DS readme, A2, window.css, TrafficLights.prompt.md, spacing.css comments and DESIGN-SYSTEM-SYNC #28 follow (no token change, not published).

**Inbound items:**
- **I1** (zoom: the top gap is 34 − 22 × zoom) — fixed (73d56a4a2a37548e1b34222a444b1fffd616cbef): the lights move to `tlMidY × zoom` (Ralph's rule) and the bar keeps the reference line, 12 × zoom native. The native screenshots at 90–150 % are the console session's.
- **I2** (the bar may jump for one frame on a titlebar re-layout) — fixed (73d56a4a2a37548e1b34222a444b1fffd616cbef): the bar no longer reads the block's y, so a transient or mixed report (which differs only in y) cannot move it, and the runner stops the ping-pong that produced the extra reports. The host still reports every change; no next-turn measuring was needed. The running-app check (hover, resize, theme switch) is the console session's.

**Files changed:**
- `app/macos/Runner/MainWindowChrome.swift` -- `buttonMidY` from Dart (nil for dialogs); pending flag + overlay `needsLayout` in the frame observer; `TrafficLightOverlayView.onLayout` / `layout()`; the before-commit run-loop observer.
- `app/macos/Runner/WindowFrameStore.swift` -- `restore` requires `buttonMidY` for main; new `placeButtons`, matched by address.
- `app/macos/RunnerTests/RunnerTests.swift` -- no move inside the notification; each correction path alone; the line follows 51 / 30.6 inside the titlebar; `restore` / `placeButtons` through the real channel codec.
- `app/lib/src/features/window/remembered_window_controller.dart` -- `restoreArguments(buttonMidY:)`, `placeButtonsArguments`, `ProjectWindowPlan.buttonMidY`, `RememberedWindowController.placeButtons`.
- `app/lib/src/features/window/app_windows.dart` -- `projectButtonMidY`, `AppWindowRequest.zoom`, the `WindowButtonPlacer` seam called on zoom changes.
- `app/lib/src/features/window/zanshin_window_root.dart` -- comment.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart`, `.../materials/zs_window_scaffold.dart` -- the bar ignores the block's y; dialogs centre on the block.
- Tests: `zs_tokens_test`, `zanshin_app_test`, `catalogue_windows_test`, `app_windows_test`, `remembered_window_args_test`, `zanshin_window_root_test`, `runner_chrome_assets_test`.
- DS: `design_system/readme.md`, `tokens/spacing.css`, `components/window/window.css`, `components/window/TrafficLights.prompt.md`; `design/DESIGN-SYSTEM-SYNC.md` #28.
- `epic-11-context.md` -- recompiled for 11.27 (planning docs were newer); one phrase fixed at review.

**Review.** 27 findings (medium 5, low 12, false 6, maybe-false 4). Patched: stale DS prose (medium), the untested Dart `placeButtons` sender and default placer (medium), the two correction paths pinned one at a time (medium), the epic context phrase, the redundant `onLayout` line, `restoreArguments` carrying `buttonMidY`, the weak source pin, the 125 % bar-line test (low). Deferred (mirrored to deferred-work.md): the 150 % line on a shorter titlebar of older macOS (medium, unverified), the XCTests outside the gate (medium, pre-existing). Rejected: a zoom change during the project window's creation (low, needs ⌘+ inside one round trip; the fix adds a branch; constraints share it since 11.20), self re-flagging after each placement (low, one no-op layout pass, no warning seen; the fix adds a guard), the scratchpad probe path and undefined I1/I2 in the spec (fixes edit this spec), bookkeeping (false: finalize / the main session), the redundant full-screen `tlMidY` (false: mirrors `[data-fullscreen]`), a synchronously throwing placer (false: the real one is async), missing per-item outcomes (false: written here), the synthetic hover test (the running-app check is the main session's by the dispatch), transient blocks (false: they differ only in y), dialog `ZsMetrics.of` (false: only the scaffold reads it).

**Follow-up review recommended:** true — three medium entries were patched (high 0, medium 3, low 5). The named unverified risk: the native correction runs from two new paths (overlay layout pass, before-commit observer) that are proven only in a never-shown XCTest window; real hover, the zoom button's tiling menu, key changes and leaving full screen in the running app are unchecked.

**Verification:** see the verification notes above (zanshin_ui 479 passed; app folders green except the 5 env-pinned cases, which pass under `cargo make test-app`; analyze and format clean; `flutter build macos --debug` built; RunnerTests 6 passed). No `cargo make test` / `test-full` / `coverage` (story-loop gate rule).

**Left to the console session (not attempted):** native screenshots at 90, 100, 110, 125 and 150 % (12 × zoom to the bar, lights centred); hover, the tiling menu, resize, full screen in and out, key changes and a theme switch; dialogs unchanged; the DS publish (`design-artifacts`).

**Residual risks:** the hover fix is proven on synthetic frame changes only; at 150 % on an older macOS the lights may leave a shorter titlebar; a zoom change during the project window's creation leaves the lights on the old line until the next change.
