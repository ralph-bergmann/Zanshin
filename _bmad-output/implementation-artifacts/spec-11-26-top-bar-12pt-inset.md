---
title: 'Story 11.26 — The top bar keeps 12 pt to the window edge; the traffic lights move down with it'
type: 'feature'
created: '2026-11-16'
status: 'done'
baseline_revision: '34b15a13efcccc157d6a946533cc4435c9279333'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/_bmad-output/project-context.md'
  - '{project-root}/_bmad-output/implementation-artifacts/epic-11-context.md'
warnings: ['oversized']
deferred:
  - summary: >-
      Under a Settings zoom other than 100 % the top bar does not keep 12·zoom to the top edge: its native top is 34 − 22·zoom (1 pt at 150 %, about 14 at 90 %).
    evidence: |-
      zanshin_window_root.dart:94,110 divides the measured block by the zoom while chromeH and chromeInset scale with it; the runner moves the lights to a fixed 34 pt. Pre-existing interplay (before this story 26 − 22·zoom, −7 at 150 %). A fix needs the zoom on the native side, and a block centred at 34·zoom (51 at 150 %) no longer fits the 52 pt titlebar.
    location: >-
      app/macos/Runner/MainWindowChrome.swift (buttonMidY); app/lib/src/features/window/zanshin_window_root.dart:94
    severity: medium
    resolved: >-
      2026-11-16 — fixed (spec-11-27-traffic-lights-hover-and-zoom, commit 73d56a4a): Ralph chose 12 × zoom; the lights move to tlMidY × zoom (Dart sends the line) and the bar keeps the reference line.
  - summary: >-
      The top bar may jump for one frame when AppKit lays the titlebar out again, because WindowChromeHost reports the system block (or a mixed block while the buttons move one by one) before the runner's move.
    evidence: |-
      MainWindowChrome and WindowChromeHost both observe the buttons' frame changes synchronously; the host sends every differing report. Whether a frame paints between the reports is unverified; settle by watching resize and a theme switch in the running app.
    location: >-
      packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/WindowChromeHost.swift (update); app/macos/Runner/MainWindowChrome.swift (placeWindowButtons)
    severity: medium (unverified)
    resolved: >-
      2026-11-16 — fixed (spec-11-27-traffic-lights-hover-and-zoom, commit 73d56a4a): verified real (4 reports per hover); the bar no longer reads the block's y, and the buttons are no longer moved inside their own frame notifications.
  - summary: >-
      The native button move is only partly tested: leaving full screen (including the exit animation), becoming key, AppKit replacing the buttons, the reported block, and clicks on the moved buttons have no automated witness.
    evidence: |-
      The two new XCTests cover open, resize, an appearance switch, a hand reset and the dialog kind on a never-shown window; full-screen transitions do not run headless. The console session's Marionette and native-screenshot check covers the rest.
    location: >-
      app/macos/RunnerTests/RunnerTests.swift
    severity: medium
  - summary: >-
      The runner's XCTests, now including the Story 11.26 button placement, still run in no gate step.
    evidence: |-
      No Makefile.toml task or gate_plan.rs rule runs xcodebuild test (already recorded for Story 11.17 in deferred-work.md); this run ran them by hand (4 passed).
    location: >-
      Makefile.toml; crates/xtask/src/tasks/gate_plan.rs
    severity: medium
---

<intent-contract>

## Intent

**Problem:** In the project window the top bar sits 4 pt from the top edge, while the rail, the inspector and the bottom keep 12 pt. The bar is derived from the traffic-light block (`chromeBarY = tlMidY − 22`), and macOS puts the block's centre at y 26 under the app's empty toolbar.

**Approach:** The runner moves the project window's three standard buttons down so their centre line sits at y 34 (= `chromeInset` 12 + `chromeH` 44 / 2) and keeps them there. Dart keeps deriving the bar from the measured block, so the bar lands at 12 and the content at 68 without new Dart layout rules. The Dart reference (`ZsMetrics.standard.tlMidY`) and the DS `--tl-mid-y` become 34; dialog windows keep the system's position (centre 26).

## Boundaries & Constraints

**Always:**
- Only the `main` chrome kind (project window) moves its buttons. x stays native (19–79); only y moves.
- The position holds through resize, full screen in and out, a theme change (`setWindowAppearance`) and the window becoming key. AppKit re-lays out the titlebar on each, so the runner re-applies the offset whenever a button's frame changes, and on resize, key and full-screen exit.
- The re-apply is idempotent: it moves a button only when its centre is off the target by more than 0.5 pt, so the frame-change notification it posts itself ends the loop.
- While the window is in full screen, or a button lives in another window (the full-screen reveal bar), the runner leaves the buttons alone.
- `WindowChromeHost` still measures and reports the block; the rings (`TrafficLightOverlayView`) follow through their own frame observers. Both need no logic change.
- Dialog windows (`ZsWindowScaffold`: Settings, Projects, Configurations) centre their header on the measured block; without a block (and not full screen) they use the dialog reference 26, not the project window's 34.
- DS updated in place: `--tl-mid-y` 34 (root), `.zs-win{--tl-mid-y:26px}` in `components/window/window.css`, the readme's chrome geometry and decision A2, the manifest value, and DESIGN-SYSTEM-SYNC entry #27.

**Never:**
- No new views in the titlebar or below the Flutter view (no hit-test risk); no window frame changes (the `isRestorable` / styleMask frame traps do not apply).
- No change to Settings, Projects or Configurations button positions, and none to full screen.
- No hard-coded "native" y: the move is relative to the window's top edge in window coordinates.
- Do not attempt the Marionette check, the native screenshot against the Refs Study, or the DS publish — they belong to the console session.
- This run is inside a story loop: never run `cargo make test`, `test-full` or `coverage`; run only the checks under Verification. Use absolute paths, never a bare `cd`; never run `jj` in a repo; edit files with Edit/Write only.

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Project window opens | main kind, native centre 26 | buttons centre at 34 (XCTest) | none |
| Moved block reaches Dart | block (19, 27, 60, 14) | first island 91, bar y 12, content 68 (Dart test) | none |
| Resize, appearance change, AppKit resets a button | window resized, `appearance` switched, a button's frame set back to native | every button centres at 34 again (XCTest) | none |
| Full screen | `fullScreen: true` appearance | bar 12, content 68 as before (Dart test); the native side is a console check | none |
| Dialog window | secondary kind | buttons stay at the native position (XCTest); header centres on 26 (Dart test) | none |
| No measured block | tests, mocks | project chrome uses reference 34 (bar 12, top 68); dialog header uses 26 (Dart tests) | none |

</intent-contract>

## Code Map

- `app/macos/Runner/MainWindowChrome.swift` -- the chrome per window kind (`main`/`secondary`), the empty toolbar, `installTrafficLightOverlay()` (idempotent, runs on init, next turn, key, full-screen exit) and the window observers (:100-215). Add the button move here, for `.main` only.
- `app/macos/Runner/MainWindowChrome.swift` `TrafficLightOverlayView.observeButtonFrames()` (:485) -- pattern for button frame observers; the rings resync on every button frame change, so they follow the move for free.
- `packages/zanshin_shell_macos/macos/zanshin_shell_macos/Sources/zanshin_shell_macos/WindowChromeHost.swift` -- measures the block (`measure()`, :241) on resize/key/full-screen and on button frame changes; doc comment (:12) says "The buttons are only read, never moved" — reword: this host only reads them; the runner's project-window chrome moves them.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` -- `standard.tlMidY: 26` (:204) → 34; `resolve()` (:128-161) already takes the block's centre; the doc comments on `chromeBarY`/`chromeTop` (:371-375) and the comment at :152.
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` -- `_header` shift `metrics.tlMidY - metrics.windowHdH / 2` (:178); needs the dialog reference 26 when the appearance has no block and is not full screen.
- `packages/zanshin_ui/test/design/zs_tokens_test.dart` (:369-412) -- standard expects bar 4 / top 60; update to 12 / 68; keep measured-block cases.
- `packages/zanshin_ui/test/materials/zs_window_scaffold_test.dart` (:38-41) -- reference case expects midY 26 — stays 26 (proves the dialog reference).
- `packages/zanshin_ui/test/design/ds_parity_test.dart` + `css_token_reader.dart` -- compare Dart metrics with `design_system/tokens/*.css` (only token files, so the `.zs-win` scope in `components/window/window.css` is outside it).
- `app/test/macos/runner_chrome_assets_test.dart` -- Dart tests that read `MainWindowChrome.swift` source; add a pin that the Swift centre-line constant equals `ZsMetrics.standard.tlMidY`.
- `_bmad-output/implementation-artifacts/design_system/tokens/spacing.css` (:25-52) -- `--tl-mid-y:26px` → 34 and the calc comments (4 → 12, 60 → 68); `components/window/window.css` (:20-43); `readme.md` (:122, :309 A2); `_ds_manifest.json` (`{"name":"--tl-mid-y","value":"26px",…}` root entry).
- `_bmad-output/implementation-artifacts/design/DESIGN-SYSTEM-SYNC.md` -- last entry #26; append #27.
- Read-only: `app/lib/src/features/shell/floating_shell.dart` (:351 `top: metrics.chromeBarY`), `app/lib/src/features/window/zanshin_window_root.dart` (:94 zoomed block) — follow automatically.

## Tasks & Acceptance

**Execution:**
- `app/macos/Runner/MainWindowChrome.swift` -- for `.main`: a `static let buttonMidY: CGFloat = 34` (the top bar's centre line, `--tl-mid-y`); `placeWindowButtons()` that, unless in full screen, sets each visible button whose `window === self.window` so its centre in window coordinates is `window.frame.height - buttonMidY` (convert through the button's superview, honour `isFlipped`; skip when within 0.5 pt); button frame observers (re-created when AppKit replaces the buttons) that call it; call it from init (and the next run-loop turn), `handleWindowDidResize`, `handleWindowDidBecomeKey`, `handleWindowDidExitFullScreen` before the overlay sync. Update the class doc (buttons are moved for the project window). -- the native half of the story.
- `packages/zanshin_shell_macos/.../WindowChromeHost.swift` -- reword the doc comment only. -- keeps the comment true.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` -- `standard.tlMidY` 34; add `static const double dialogTlMidY = 26` (window.css `.zs-win`); update comments. -- Dart reference follows the new geometry.
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` -- use `dialogTlMidY` when `ZsAppearance.maybeOf(context)` has no block and is not full screen. -- dialogs unchanged.
- `packages/zanshin_ui/test/design/zs_tokens_test.dart` -- standard bar 12 / top 68; add a measured case for the moved block (19, 27, 60, 14) → 91 / 12 / 68. -- witnesses.
- `app/macos/RunnerTests/RunnerTests.swift` -- XCTests (the target already exists, `@testable import zanshin`): a titled, resizable, `.fullSizeContentView` `NSWindow` with `MainWindowChrome(window:kind: .main)` centres all three buttons at 34 from the window's top (after `layoutSubtreeIfNeeded` and one run-loop turn); after `setFrame` to another size, after switching `appearance` (aqua ↔ darkAqua) and after setting a button's frame origin back by hand they centre at 34 again; with `.secondary` the buttons keep the position a plain toolbar window gives them. -- the native witnesses.
- `app/test/macos/runner_chrome_assets_test.dart` -- pin `buttonMidY` in the Swift source to `ZsMetrics.standard.tlMidY` and to `chromeInset + chromeH / 2`. -- keeps native and Dart in step.
- Fix any other test that pinned the old reference (bar 4 / top 60 without a block).
- DS files and the sync entry as listed in the Code Map. -- the DS stays the reference.

**Acceptance Criteria:**
- Given the project window in a window (not full screen), when it opens, resizes, becomes key, changes theme or leaves full screen, then its traffic lights centre at y 34 and the reported block's centre is 34, so the top bar sits 12 pt from the top and content starts at 68.
- Given Settings, Projects or Configurations, when shown, then their buttons stay at the system position (block 19/19, centre 26) and their header centres on it, with or without a measured block.
- Given no measured block (tests, catalogue mocks), when the project chrome resolves, then bar y is 12 and content top is 68; the DS tokens and the Dart metrics agree (`ds_parity_test`).
- Given the app runs, when the user clicks, hovers or uses the zoom button's menu, then the moved buttons and the rings behave as before (console-session check).

## Spec Change Log

## Review Triage Log

### 2026-11-16 — Review pass
- verdicts: 25 findings — high 0, medium 8, low 8, false 5, maybe-false 4
- findings:
  - `[medium]` `[defer]` (edge) Under the Settings zoom the bar's top inset is `34 − 22·zoom` (1 pt at 150 %, ~14 at 90 %), not `12·zoom` — verified: `zanshin_window_root.dart:94,110` divides the block by the zoom while `chromeH`/`chromeInset` scale. Pre-existing (before: `26 − 22·zoom`, −7 at 150 %); a fix needs the zoom on the native side and a titlebar that holds a lower block. Deferred.
  - `[maybe-false]` `[defer]` (edge) Buttons move one at a time, each frame change makes `WindowChromeHost` send a mixed block — real messages, but they arrive in one run-loop turn; whether a frame paints in between is open. Settle: watch the bar on resize/theme in the running app (console). Grouped with the one-frame-jump entry.
  - `[false]` `[reject]` (edge) AppKit replaces the buttons without resize/key/full-screen exit, leaving them unobserved — the app changes the style mask only at setup and through full screen; the lazy toolbar attach is covered by the next-turn call and `didBecomeKey`, and `observeFrames` re-subscribes on every call.
  - `[low]` `[patch]` (edge) `buttons(window)[0]` traps the test process when no button exists — replaced by `guard let close = buttons(window).first else { return XCTFail(…) }`; XCTests re-run, 4 passed.
  - `[medium]` `[defer]` (edge, claim) AC1 "12 pt from the top" fails at any zoom but 100 % — same root cause as the zoom row; deferred with it.
  - `[medium]` `[defer]` (verification-gap) The new XCTests run in no gate step — pre-existing (deferred-work.md "The runner's XCTests … run in no gate step"); epic context now tells runs to run them by hand under `app/macos/`. Deferred.
  - `[medium]` `[defer]` (verification-gap) Leaving full screen, becoming key and replaced buttons are not exercised by any test — full-screen transitions do not run headless; the console session's native check covers them. Deferred.
  - `[maybe-false]` `[defer]` (verification-gap, other) `WindowChromeHost` may report the native block one layout before the move (one-frame jump) — named in the spec's Design Notes; settle in the console session. Grouped with the mixed-block row.
  - `[medium]` `[defer]` (blind) Zoom breaks the 12 pt rule — same root cause as the edge zoom row.
  - `[medium]` `[patch]` (blind) DS prose and cards still describe the unmoved geometry (`TrafficLights.prompt.md` "never moves them" / centre 26 / content 60, `TrafficLights.jsx`, `window.card.html` y 26 / top 4 / 60) — updated to y 34, bar 12, content 68, dialogs at 26.
  - `[medium]` `[patch]` (blind) UI kit `ui_kits/desktop/app.jsx` keeps `TOP = 60` while `--chrome-top` is 68 — set to 68 with its comment; `_ds_bundle.js` is rebuilt by the publish (noted in DESIGN-SYSTEM-SYNC #27). Same root cause as the row above.
  - `[low]` `[reject]` (blind) The dialog value 26 is pinned against no CSS — the parity test reads only token files; adding a component-CSS reader is more than a direct fix for a drift nobody meets in everyday use.
  - `[low]` `[reject]` (blind) 34 hard-coded in several places, `[data-fullscreen]` overrides now redundant — harmless duplicates; the Swift↔Dart pin test and the parity test catch drift.
  - `[maybe-false]` `[defer]` (blind) No witness that the moved buttons still take clicks — the 14 pt button at 27–41 sits inside the 52 pt titlebar; settle with a click and the zoom menu in the running app (console). Grouped with the untested-native-paths entry.
  - `[medium]` `[defer]` (blind) The reported block, the observer swap and `didBecomeKey` are untested — grouped with the untested-native-paths entry.
  - `[maybe-false]` `[defer]` (blind) Observer order may make the bar jump for one frame — grouped with the one-frame-jump entry.
  - `[low]` `[defer]` (blind) The lights may sit at 26 during the full-screen exit animation and jump to 34 at its end — `placeWindowButtons` skips while `.fullScreen` is set; whether it shows is open (console check). Grouped with the untested-native-paths entry.
  - `[false]` `[reject]` (blind) The minimap fix has no test of its own — `graph_minimap_test.dart` "never trades a day label" failed deterministically before the fix and passes after; it is the witness.
  - `[low]` `[patch]` (blind) `epic-11-context.md` dropped still-valid rules — restored the `zanshin_ffi_version` coverage credit, the menu-reach and ⌘, rules, and added the by-hand RunnerTests rule.
  - `[low]` `[patch]` (blind) `sprint-status.yaml` still says `backlog` — set to `done` at finalize.
  - `[low]` `[reject]` (blind) The flip sign is computed by hand instead of `host.convert(_, from: nil)` — works in both coordinate systems and the XCTests pass; a style change only.
  - `[false]` `[reject]` (intent) Configurations treated as a dialog is an inference — it uses the `secondary` chrome kind and `ZsWindowScaffold`, has no floating top bar, so item 1 does not reach it.
  - `[false]` `[reject]` (intent) The minimap change is outside the intent — the new insets exposed it through an existing test; leaving it would leave a red test.
  - `[false]` `[reject]` (intent) The theme path `setWindowAppearance` is untested — it sets `window.appearance` (`ZanshinShellPlugin.swift:132,293`), the path the XCTest switches.
  - `[low]` `[reject]` (intent) The bar follows the measured block (R1), so a transient report moves it — the chosen reading; its one-frame risk is deferred with the jump entry.

## Design Notes

Why move the buttons rather than the bar: the story asks for 12 pt on every side and the lights centred on the bar; Dart's rule "the bar centres on the measured block" stays, so only the native position changes. The titlebar under the unified empty toolbar is 52 pt tall; a 14 pt button centred at 34 spans 27–41, inside it, so no container resize is needed (unlike Electron's `trafficLightPosition`, which enlarges the titlebar container).

Re-apply sketch (window coordinates, origin bottom left):

```swift
let inWindow = button.convert(button.bounds, to: nil)
let dy = (window.frame.height - Self.buttonMidY) - inWindow.midY
guard abs(dy) > 0.5, let host = button.superview else { continue }
button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY + (host.isFlipped ? -dy : dy)))
```

Known risk for the console check: when AppKit relays the titlebar, `WindowChromeHost` may report the native block (centre 26) a moment before the move, so the bar could jump for one frame.

## Verification

**Commands:**
- `flutter test` in `packages/zanshin_ui` -- expected: pass
- `flutter test test/macos test/widgetbook test/app test/features/window test/features/shell test/features/projects` in `app` -- expected: pass
- `dart analyze` and `dart format --set-exit-if-changed .` in `packages/zanshin_ui` and `app` -- expected: clean
- `flutter build macos --debug` in `app` -- expected: the runner compiles
- `xcodebuild test -workspace Runner.xcworkspace -scheme Runner -configuration Debug -only-testing:RunnerTests` in `app/macos` -- expected: TEST SUCCEEDED, the new cases included (no gate step runs it; deferred-work.md already records that)

**Manual checks (console session, not this run):**
- Marionette check of the running app and a native screenshot against `design/Refs Study.html` section 9: 12 pt from the top to the bar, lights centred on it; resize, full screen in/out, theme switch, key change keep them; drag region and buttons work.
- DS publish (skill `design-artifacts`).

**Verification notes (step 3, story-loop gate rule: no `cargo make test` / `test-full` / `coverage`):**
- `flutter test` in `packages/zanshin_ui`: 476 passed (incl. `ds_parity_test`). `dart analyze`: no issues. `dart format --set-exit-if-changed .`: 0 changed.
- `flutter test test/macos test/widgetbook test/app test/features` in `app`: first run red — `home_page_test` still pinned the old no-block geometry (drag row 60, first island 91/4; two `ActiveGraph` failures were cascades) and `graph_minimap_test` "never trades a day label" failed. Both fixed (below); `test/features/home` 39 passed, `test/features/graph` 1176 passed. The remaining red tests (`worker_project_repos_test`, `remote_sync_test` sign-on-push) need the pinned `XDG_CONFIG_HOME`: `cargo make test-app` on both files, 38 passed.
- The minimap failure was a real product bug the new insets exposed: the label thinning compared the year-line clearance in strip y (after subtracting the scroll offset), so a label exactly `_yearClear` (16) from a year line flipped with floating-point rounding at some scroll offsets (15.999999999999886 at step 15) and every later label traded for its neighbour. Fixed in `app/lib/src/features/graph/graph_minimap.dart` (~:1255) by comparing in content y, like the 18 px spacing check; the test is unchanged.
- `dart analyze` in `app`: no issues. `dart format --set-exit-if-changed lib test widgetbook`: 0 changed.
- `flutter build macos --debug` in `app`: built.
- `xcodebuild test … -only-testing:RunnerTests` in `app/macos`: TEST SUCCEEDED, 4 cases (the 2 new: `testTheProjectWindowCentresItsButtonsOnTheTopBar`, `testADialogWindowKeepsTheSystemPosition`).
- Matrix audit: open / resize / appearance / reset / dialog native rows → the two XCTests; moved block, full screen, no block → `zs_tokens_test`; dialog header 26 → `zs_window_scaffold_test` reference case; pin Swift ↔ Dart → `runner_chrome_assets_test`.
- After the review patches: `xcodebuild test … -only-testing:RunnerTests` again TEST SUCCEEDED (4 passed). The other patches touched DS files and the epic context only, which no Dart test reads (`ds_parity_test` reads `tokens/` only).

## Auto Run Result

Status: done

**Summary.** The project window now moves its traffic lights down so their centre sits at y 34; the top bar, still derived from the measured block, sits 12 pt from the top and content starts at 68, as in full screen. Dialog windows (Settings, Projects, Configurations) keep the system's position (centre 26). The Dart reference and the DS follow (`--tl-mid-y` 34, `.zs-win` 26). The new insets exposed a minimap label bug, fixed on the way.

**Files changed:**
- `app/macos/Runner/MainWindowChrome.swift` -- `buttonMidY` 34, `placeWindowButtons()` and button frame observers for the `main` kind; called on init, next turn, resize, key, full-screen exit.
- `app/macos/RunnerTests/RunnerTests.swift` -- two XCTests: project window at 34 (open, resize, appearance, reset); dialog at the system position.
- `packages/zanshin_shell_macos/.../WindowChromeHost.swift` -- doc comment only.
- `packages/zanshin_ui/lib/src/design/zs_metrics.dart` -- `standard.tlMidY` 34, `dialogTlMidY` 26.
- `packages/zanshin_ui/lib/src/materials/zs_window_scaffold.dart` -- the dialog header uses 26 without a measured block.
- `app/lib/src/features/graph/graph_minimap.dart` -- the year-line clearance compares content y (scroll-independent thinning).
- `app/lib/src/features/shell/graph_insets.dart` -- doc comment (top 68).
- Tests pinned to the old no-block geometry (`zs_tokens_test`, `zanshin_app_test`, `home_page_test`, `catalogue_*`, `rail_test`, `pinned_panel_test`, `top_bar_test`, `shell_layout_test`, `floating_shell_test`, `project_capsule_test`) and a Swift↔Dart pin in `runner_chrome_assets_test`.
- DS: `tokens/spacing.css`, `components/window/window.css`, `readme.md`, `_ds_manifest.json`, `components/window/window.card.html`, `TrafficLights.prompt.md`, `TrafficLights.jsx`, `ui_kits/desktop/app.jsx`; `design/DESIGN-SYSTEM-SYNC.md` entry #27.
- `epic-11-context.md` -- recompiled for 11.26 (planning docs were newer), still-valid rules restored at review.

**Review.** 25 findings. Patched: the stale DS geometry in prose, card and UI kit (medium, one root cause), the XCTest index trap (low), the epic context's dropped rules (low), sprint status (low). Deferred (4, mirrored to deferred-work.md): zoom vs. the 12 pt rule (medium), the possible one-frame bar jump (medium, unverified), untested native paths incl. full-screen exit and clicks (medium), the XCTests outside the gate (medium). Rejected: replaced-button observer gap (false: style mask changes only at setup and in full screen, both covered), minimap fix lacking a test (false: the existing test is its witness), Configurations as a dialog (false: no floating top bar), minimap outside the intent (false: exposed by this change), untested theme path (false: `setWindowAppearance` sets `window.appearance`, the tested path), dialog 26 not pinned against CSS (low, needs a new CSS reader), 34 repeated in several places (low, pinned by tests), hand-computed flip sign (low, style only), R1 transient (low, the chosen reading; risk deferred).

**Follow-up review recommended:** false — one medium entry and three low entries patched, no high.

**Verification:** see Verification notes above (zanshin_ui 476 passed; app test folders green, env-pinned files via `cargo make test-app`; analyze and format clean; `flutter build macos --debug` built; RunnerTests 4 passed). No `cargo make test` / `test-full` / `coverage` (story-loop gate rule).

**Left to the console session (not attempted):** the Marionette check and a native screenshot against `design/Refs Study.html` section 9 (12 pt to the bar, lights centred; resize, full screen in and out, theme switch, key change; drag region, buttons and the zoom menu work), and the DS publish (`design-artifacts`), which also rebuilds `_ds_bundle.js`.

**Residual risks:** a one-frame bar jump on titlebar relayout; the lights may sit at 26 during the full-screen exit animation; the bar does not keep 12·zoom under a non-default zoom.
