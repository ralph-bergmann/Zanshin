---
title: 'Promote the windowing-API splash POC into the real app entrypoint'
type: 'refactor'
created: '2026-09-12'
status: 'done'
baseline_revision: '0a11a1795b032c3e1eb0beb3617e305f8b37e9c0'
review_loop_iteration: 0
followup_review_recommended: false
context:
  - '{project-root}/docs/superpowers/specs/2026-09-11-windowing-splash-poc-design.md'
  - '{project-root}/docs/superpowers/specs/2026-09-07-app-bootstrap-splash-design.md'
warnings: ['oversized']
deferred: []
---

<intent-contract>

## Intent

**Problem:** The app boots through an in-window splash (`ZanshinBootstrap` stacked inside the runner's nib window), while a parallel proof of concept (`app/lib/main2.dart`, gated behind a `--windowing` process flag) shows the shape Ralph wants: a floating splash window, then a real main window, both created from Dart via Flutter's windowing API. Two entrypoints, a process flag, and a nib window that must not exist in windowing mode cannot all survive.

**Approach:** Make the POC the only boot path. `main.dart` runs the real boot (settings → DI graph → worker → `zanshinAppFactory.create()`) behind a timer-driven sequencer that opens a splash window only when the boot is slow, then the main window. The runner always runs a view-less `FlutterEngine`; `MainFlutterWindow.swift`, the nib window and `WindowingMode` are deleted, and the main window's custom chrome is re-applied natively to the Dart-created window through the existing `zanshin/window_frames` channel.

## Boundaries & Constraints

**Always:**
- Owner decisions 1–7 of the invocation intent are settled; implement them, do not re-open them.
- The first Dart-created window must exist before `runWidget` (warm-up-frame invariant); the engine only shows a window after its first frame.
- Boot timing is driven by `Timer`s, never by reading a clock, so `flutter test` fake time controls it fully.
- The main window's chrome must be applied **before** its saved frame (`.fullSizeContentView` makes the frame the content size; applying a frame under a non-final style mask shaves the titlebar height off every launch).
- `isRestorable = false` on the main window is mandatory.
- SPDX first line on every new/edited Dart file; `dart analyze --fatal-infos --fatal-warnings` and `dart format` clean under `app/linter/rules.yaml` (page width 120).
- Preserve verbatim the hard-won AppKit explanatory comments when moving Swift code (titlebar rebuilds, `isRestorable`/AppKit restore race, frame under the final style mask, `self.frame` unusable after attaching the content view controller, the traffic-light overlay's transparent-interior dead end, the tracking-area re-assert, the toolbar/drag-interceptor rationale, the hot-restart delegate workaround).

**Block If:**
- The engine refuses the "create the first window only once the race resolves" design and neither it nor the documented `alphaValue = 0` fallback can produce a visible first window.
- Porting the chrome to a Dart-created window turns out to require changing engine-owned view ownership in a way that breaks the Flutter view (no equivalent to `WrapperViewController` exists).

**Never:**
- No Rust workspace, FFI, `packages/zanshin_core`, or Flutter UI changes beyond `main.dart`, the bootstrap/window feature, the macOS runner and `zanshin_shell_macos`'s window lookup.
- No new features: no project-list window, no `_ProjectWindow`, no Window menu, no migration of the old `app_position`/`WindowState` defaults.
- No `--windowing` flag, no `WindowingMode`, no `_MissingWindowingFlag`, no `main2.dart`.
- Do not lower the coverage baseline (this change adds no Rust code; the baseline must stay untouched).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Fast boot | boot completes before `splashIndicatorDelay` (500 ms) | No splash window is ever created; the main window is the first and only window | No error expected |
| Slow boot | boot still running at 500 ms | Splash window appears; main window opens at `max(boot end, 500 ms + splashIndicatorMinShow)`, then the splash fades out and is destroyed | No error expected |
| Boot fails fast | `openSettings`/`startApp` throws before 500 ms | Main window opens with the boot-failure page, themed by the persisted mode (`ThemeMode.system` when settings never loaded) | Logged `SEVERE` on `zanshin.bootstrap`; no splash |
| Boot fails slow | throws after the splash is up | Splash honours the min-show, then the main window opens with the failure page and the splash fades | Logged `SEVERE` on `zanshin.bootstrap` |
| Reduced motion | `disableAnimations` is set | Lottie loader shows its static first frame **and** the native splash fade runs with duration 0 | No error expected |
| Re-open a window key | a window with the same key is already open | That window is activated, no second window is created | No error expected |
| Last window closed | user closes the last window | Process exits via `exitApplication(AppExitType.required)` | No error expected |

</intent-contract>

## Code Map

Dart — to change:
- `app/lib/main.dart` — entrypoint. Keeps `runZonedGuarded`, `initLogForwarding`, `FlutterError.onError`, `SemanticsBinding.instance.ensureSemantics()`, `MainComponent`, `_startApp`. Drops `DartPluginRegistrant.ensureInitialized()` (redundant: the engine runs the registrant before `main`, `runtime/dart_isolate.cc:927`) and `runApp(...)` in favour of the sequencer + window host. `main()` becomes `Future<void>`.
- `app/lib/main2.dart` — **delete** (its `_openWindow`, `_WindowLifecycle`, `_exitIfNoWindows` and splash-card widget are promoted; `_StartWindow`, `_ProjectWindow`, `_MissingWindowingFlag`, `demoProjects`, `fakeBootDuration` are dropped).
- `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` — L14-29 hold the constants to keep (`splashAnimationAsset`, `splashAnimationSize`, `splashIndicatorDelay` 500 ms, `splashIndicatorMinShow` 1000 ms, `splashFadeOut` 200 ms; `splashIndicatorFadeIn` becomes unused — drop it). `_ZanshinBootstrapState` L54-167 is the timer logic to re-shape; `_BootFailure` L213-240 is kept (made public); `_SplashScreen`/`_resolveBrightness`/`_scaffoldBackground` L171-209 are replaced by the fixed dark card.
- `app/lib/src/features/bootstrap/remembered_window_controller.dart`, `splash_window_controller.dart` — POC controllers; move to the new window feature folder, drop the "POC / not wired into the real boot" header comments. `RememberedWindowController.create` (L37-56) already awaits the native `restore` round-trip — that is the seam for the chrome.
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` — 9 tests to rewrite (see Design Notes for the semantics that must survive).

Swift — to change (`app/macos/Runner/`):
- `MainFlutterWindow.swift` (792 lines) — **delete after porting**. Chrome lives in `setupWindowAppearance()` L109-131 (styleMask+`.fullSizeContentView` L110, `titlebarAppearsTransparent` L111, `titleVisibility = .hidden` L112, `backgroundColor = .clear` L113, `isOpaque = false` L114, `hasShadow = true` L115, `minSize 900×600` L116, `isRestorable = false` L122, `NSToolbar` + `TitlebarAccessoryController` L125-130), `setupWindowButtons()` L136-166 + `installTrafficLightOverlay()` L178-217 + the key/full-screen observers L221-235, `TrafficLightOverlayView` L364-716, `WrapperViewController` L720-761 (`NSVisualEffectView`, `.behindWindow`, `.active`, `cornerRadius = 20`), `TitlebarAccessoryController` L768-772 and `DragInterceptorView` L774-792. Dropped, not ported: the file-scope `bundleId`/`defaults` globals L4-5, `struct WindowState` L9-27, `saveAndRestoreWindowFrame`/`saveWindowState`/`loadWindowState`/`defaultFrame` L78-101/L244-325 (superseded by `WindowFrameStore`), the `--windowing` gate L38-46.
- `WindowFrameStore.swift` — channel `zanshin/window_frames`, single method `restore` (args `window: Int`, `key: String`) L37-56, `restore(_:key:)` L58-81 applies the frame then installs move/resize/close observers. Extension point for the chrome.
- `WindowingBootstrap.swift` — `WindowingMode` L14-16 (**delete**), `WindowingBootstrap` L19-82 (view-less engine L27, `hasShownWindow` L25 + occlusion observer L28-36 → **delete**, `willCloseNotification` delegate-nil workaround L41-54 → **keep**, `start()` L56-62, `activate()` L64-81 → **keep**), `SplashWindowHost` L89-169 → keep unchanged.
- `AppDelegate.swift` (28 lines) — drop the `WindowingMode` guard and `mainFlutterWindow?.close()` L9-16; `applicationShouldTerminateAfterLastWindowClosed` L18-23 → `false`.
- `Base.lproj/MainMenu.xib` — delete the `<window …id="QvC-M9-y7g" customClass="MainFlutterWindow"…>` element **L333-341** and the outlet line **L19** (`mainFlutterWindow` → `QvC-M9-y7g`); keep L18 (`applicationMenu`) and the enclosing `<connections>`. No other reference to that id exists; all window menu items target First Responder.
- `Runner.xcodeproj/project.pbxproj` — `MainFlutterWindow.swift`: PBXBuildFile **L29** (`33CC11132044BFA00003C045`), PBXFileReference **L76** (`33CC11122044BFA00003C045`), group child **L177**, Sources phase **L367**. Follow the existing one-line-per-entry, tab-indented format; new files reuse the `7A9C2E…2E7B10A100C0FFEE` UUID family.
- `packages/zanshin_shell_macos/macos/.../ZanshinShellPlugin.swift` — window lookup L61-63 is `view?.window ?? NSApp.mainWindow`; `registrar.view` is nil with a view-less engine.

Read-only evidence:
- Flutter SDK `3.48.0-1.0.pre-713` (master). `WindowManager({required List<WindowEntry> initialWindows})` has no `child`; it reads `initialWindows` once in `initState` and owns a private `WindowRegistry` reachable only via `WindowRegistry.of(context)` from window content. `WindowRegistry()` has a public constructor; `register`/`unregister`/`windows` are public. The regular-window widget is `Window`, **not** `RegularWindow`. `WindowController.activate()` exists. `WindowingOwnerMacOS.createWindowController` silently drops `constraints` — pass them to the concrete controller ctor.
- `flutter test` installs a `_TestWindowingOwner`, so generic `WindowController`/`DialogWindowController`/`WindowEntry`/`WindowRegistry`/`WindowManager` **are** constructible in widget tests — but `RememberedWindowController`/`SplashWindowController` are **not** (they cast `windowingOwner as WindowingOwnerMacOS` and hit FFI + method channels).
- `isWindowingEnabled` comes from the machine-global `flutter config --enable-windowing` via `FLUTTER_ENABLED_FEATURE_FLAGS`; it cannot be set from the repo.
- `settings.value.appearance.themeMode` is `material_ui`'s `ThemeMode`; `SettingsStore.open` is a zero-arg static.

## Tasks & Acceptance

**Execution:**
- `app/lib/src/features/window/remembered_window_controller.dart` -- move from `features/bootstrap/`, make production-grade (doc comments, no POC disclaimer), add a named `bool chrome = false` (or equivalent) that the `restore` invocation forwards -- the main window needs its chrome applied before its frame, in one native round-trip.
- `app/lib/src/features/window/splash_window_controller.dart` -- move from `features/bootstrap/`, drop the POC disclaimer, keep `configure`/`fadeOut`; `fadeOut` must accept `Duration.zero` -- reduced motion must skip the native fade.
- `app/lib/src/features/window/app_windows.dart` -- new: public `AppWindows` owning the key→`WindowEntry` map over a `WindowRegistry`, with `openOrActivate({key, title, builder})`, an injectable controller factory (default `RememberedWindowController.create`), the lifecycle delegate that unregisters a destroyed window, and the exit-when-empty rule -- promotes `_openWindow`/`_WindowLifecycle`/`_exitIfNoWindows`, stays multi-window, and is testable without the macOS controllers.
- `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` -- rewrite: keep the four timing/asset constants, add the `BootWindowHost` interface and the timer-driven sequencer that runs the boot, races `splashIndicatorDelay`, honours `splashIndicatorMinShow`, and drives host calls -- the sequencing must be testable where the windowing API cannot create windows.
- `app/lib/src/features/bootstrap/splash_card.dart` -- new: the splash content — fixed `yaruDark.scaffoldBackgroundColor` card, rounded corners, Lottie loader at `splashAnimationSize`, `animate: !MediaQuery.disableAnimationsOf(context)` -- uniform theming, no light/dark distinction.
- `app/lib/src/features/bootstrap/boot_failure.dart` -- new: the former `_BootFailure`, public, themed by the persisted `ThemeMode` -- it is now the main window's content on failure.
- `app/lib/src/features/bootstrap/boot_window_host.dart` -- new: the real `BootWindowHost` — creates the splash/main controllers, calls `runWidget(WindowManager(...))` exactly once with whichever window is first, captures the registry for later opens, and fades+destroys the splash -- upholds the warm-up-frame invariant.
- `app/lib/main.dart` -- rewrite the boot: keep zone/logging/semantics/DI, drop `DartPluginRegistrant.ensureInitialized()`, run the sequencer against the real host -- single entrypoint.
- `app/lib/main2.dart` -- delete.
- `app/macos/Runner/MainWindowChrome.swift` -- new: the ported chrome (style mask, transparent titlebar, clear/non-opaque background, `NSVisualEffectView` `.behindWindow` with corner radius 20 inserted so it sits **behind** the engine's Flutter view, `TrafficLightOverlayView`, `TitlebarAccessoryController`/`DragInterceptorView` toolbar, `minSize` 900×600, `isRestorable = false`), applied to an engine-created `NSWindow` -- `contentViewController = WrapperViewController(...)` is not available for Dart-created windows.
- `app/macos/Runner/WindowFrameStore.swift` -- invoke the chrome from the `restore` handler before the frame is applied, driven by the new argument -- ordering is load-bearing.
- `app/macos/Runner/WindowingBootstrap.swift` -- delete `WindowingMode` and the `hasShownWindow` occlusion observer; always start the view-less engine; keep the hot-restart delegate workaround and the double `activate(ignoringOtherApps:)`.
- `app/macos/Runner/AppDelegate.swift` -- always bootstrap; `applicationShouldTerminateAfterLastWindowClosed` returns `false`.
- `app/macos/Runner/MainFlutterWindow.swift` -- delete.
- `app/macos/Runner/Base.lproj/MainMenu.xib` -- delete the window object and the `mainFlutterWindow` outlet.
- `app/macos/Runner.xcodeproj/project.pbxproj` -- remove every `MainFlutterWindow.swift` entry, add `MainWindowChrome.swift` in the same four places.
- `packages/zanshin_shell_macos/macos/.../ZanshinShellPlugin.swift` -- widen the window lookup so it resolves the app's titled Flutter window even before it is key, and never the borderless splash -- `registrar.view` is nil with a view-less engine.
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` -- rewrite against a fake `BootWindowHost`, covering every row of the I/O matrix that timers can drive -- carries the old file's semantics forward.
- `app/test/features/window/app_windows_test.dart` -- new: open, activate-instead-of-reopen, unregister on destroy, exit on last window.
- `docs/development-setup.md`, `README.md` -- document `flutter config --enable-windowing` as a hard prerequisite -- the app no longer builds a usable window without it.
- `docs/superpowers/specs/2026-09-11-windowing-splash-poc-design.md` -- rewrite as the shipped design (status, what changed vs the POC, what is still open, why the chosen splash-race design).
- `docs/superpowers/specs/2026-09-07-app-bootstrap-splash-design.md` -- mark superseded, point at the shipped design.

**Acceptance Criteria:**
- Given a checkout with windowing enabled, when `flutter run -d macos` is started from `app/` with no extra arguments, then the app comes up with a main window and no `--windowing` flag exists anywhere in the tree (`grep -r "windowing" app/macos app/lib` finds no flag/`WindowingMode`).
- Given the built debug bundle, when it is launched, then the main window shows the ported chrome — transparent full-size-content titlebar, vibrancy background, rounded corners, gray traffic-light rings that cross-fade to the native buttons on hover — and dragging works in the Flutter title-bar area.
- Given the main window is moved and resized and the app is restarted, when it launches again, then the window reappears at the remembered frame from the `<bundle id>.window_frames` suite under the main window's key, and nothing reads `<bundle id>.app_position`.
- Given a debug run, when a hot restart is triggered, then the app survives it, and when the last window is closed, then the process exits.
- Given `cargo make test`, when it runs, then it passes with `coverage-baseline.txt` unchanged.
- Given `flutter build macos --debug` from `app/`, when it runs, then it succeeds — proving the Swift sources and the Xcode project agree after the file deletions and additions.

## Spec Change Log

2026-09-12 — implementation deviations, all within the intent:

- `RememberedWindowController.create` takes `chrome` as a **required** named parameter, not
  `bool chrome = false`. Every app window wears the chrome and `AppWindows` passes `true`
  unconditionally, so a default nobody uses would have been a dead knob. The splash does not
  go through this controller at all; it is configured over `zanshin/splash_window`.
- `AppWindows` has a second injected seam besides the controller factory: `exitProcess`.
  `TestWidgetsFlutterBinding.exitApplication` **throws** on `AppExitType.required`
  (`flutter_test/src/binding.dart:1428`), so the exit-when-empty rule is untestable without
  it — a mock method-call handler on `SystemChannels.platform` does not help, the binding
  never reaches the channel.
- `BootWindowHost.dismissSplash` takes the fade `Duration`; the sequencer resolves reduced
  motion from `platformDispatcher.accessibilityFeatures.disableAnimations`. Had the host
  resolved it, the reduced-motion row of the matrix would have been unreachable from a test
  (the real host is not unit-tested).
- The splash race worked as designed: the `alphaValue = 0` fallback was **not** needed, and
  the shipped design doc records that.
- The old test file's two widget-level assertions (the loader's reduced-motion frame, the
  failure page's text) moved into the rewritten `zanshin_bootstrap_test.dart` as small
  `SplashCard` / `BootFailure` tests rather than into new files, keeping the two test files
  the plan names.
- Constant placement: `splashWindowSize` / `splashCardRadius` in `splash_card.dart`,
  `mainWindowKey` / `mainWindowTitle` in `boot_window_host.dart`,
  `defaultWindowSize` / `defaultWindowConstraints` in `app_windows.dart`.
- `WindowFrameStore` keeps the `MainWindowChrome` instance per window (alive as long as the
  window, dropped in `forget`), since the chrome owns the traffic-light overlay and the
  notification observers that used to belong to the `NSWindow` subclass.

## Review Triage Log

## Design Notes

**Splash race (chosen design, per the intent's recommendation).** The boot (`openSettings` → `startApp`) starts *before* `runWidget`, racing a `Timer(splashIndicatorDelay)`. Boot wins → create the main `RememberedWindowController` and `runWidget` with it as the only initial window; no splash object ever exists. Timer wins → create the `SplashWindowController` and `runWidget` with it. Either way the first window is part of the warm-up frame. The documented fallback (always create the splash, hold it at native `alphaValue = 0`) is only for an engine constraint that blocks this; record whichever was used in the design doc.

**Min-show semantics translate, they do not survive literally.** In the old single-window splash the finished app was already mounted *behind* an opaque splash, so `AppMarker` was findable at boot-end while the splash still covered it. With two windows the main window is visible the moment it opens, so it must open at `max(boot end, delay + minShow)` — otherwise a 1200×800 window would pop up around the 320×320 splash for a second. The invariants that carry over unchanged: nothing before 500 ms, at least 1000 ms once shown, a `splashFadeOut` cross-fade, no splash at all on a fast boot, the failure page, the `SEVERE` log on `zanshin.bootstrap`, and reduced motion.

**Test seam.** `BootWindowHost` is a plain interface (`openSplash()`, `openMain(Widget)`, `dismissSplash()` or equivalent) with no windowing type in its signature, so the fake in `flutter test` records call order and timestamps while `tester.pump(Duration)` drives the timers. The real host is the only place that touches `runWidget`/`WindowManager`/the macOS controllers, and is not unit-tested — it is covered by the runtime smoke check.

**Registry capture.** `WindowManager` owns its `WindowRegistry` privately; the only way in is `WindowRegistry.of(context)` from window content. The host therefore captures it from the first window's builder (guarded so it completes once) and hands it to `AppWindows`, which keys the windows. Keep `AppWindows` free of any single-window assumption: the later project-list window opens project windows through exactly `openOrActivate`.

**Chrome placement.** The ported chrome goes into a new `MainWindowChrome.swift` beside `WindowFrameStore.swift` rather than inside it — `TrafficLightOverlayView` alone is ~350 lines and would drown the frame store. It is still invoked from the `zanshin/window_frames` handler, so the intent's "applied from the runner's window channel, before the frame" holds. The `NSVisualEffectView` cannot be a parent view controller any more (the engine owns the window's `contentViewController`); insert it as a sibling behind `window.contentView` (`contentView.superview`, positioned `.below`) or an equivalent that keeps the Flutter view on top and unclipped, and verify the result looks identical to today.

**Main window key.** `main` in the `<bundle id>.window_frames` suite (the POC's `start` belonged to the deleted project-list window). No migration from `<bundle id>.app_position`.

## Verification

**Commands:**
- `cargo make test` -- expected: passes end to end (Rust, clippy, fmt, `flutter test`, `dart analyze`, `dart format`, cargo deny, coverage ratchet) with `coverage-baseline.txt` unchanged. Run unpiped, timeout ≥ 600000 ms.
- `flutter build macos --debug` (from `app/`) -- expected: succeeds; this is the only proof that the Swift sources and `project.pbxproj` agree after deleting `MainFlutterWindow.swift` and adding `MainWindowChrome.swift`.
- `git grep -n -- "--windowing\|WindowingMode\|main2.dart\|app_position\|MainFlutterWindow"` -- expected: no hits outside the design docs' historical prose.

**Manual checks (if no CLI):**
- Runtime smoke: launch `app/build/macos/Build/Products/Debug/zanshin.app` (or `flutter run -d macos --profile` with a bounded timeout) and confirm a main window appears with the custom chrome, that it quits cleanly, and — in a debug run — that hot restart survives. Use the CGWindowList probe / VM-service screenshot from `project-verify-macos-ui-without-screen-permission` (no screen-recording permission needed). Report precisely which runtime checks ran and which could not.
- Confirm the splash path by temporarily slowing the boot (or by observing a cold first launch); confirm a warm launch shows no splash at all.
