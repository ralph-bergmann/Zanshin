# Windowing-API app start — design

**Status:** shipped 2026-09-12. This is the app's only boot path: `main.dart` runs it,
there is no second entrypoint and no flag. Started as a proof of concept on 2026-09-11
(`lib/main2.dart` behind a `--windowing` process argument); the "What the engine actually
does" findings below are from that POC and still hold.

**Prerequisite:** `flutter config --enable-windowing` (machine-global, compiled into the
app). Without it the app builds but comes up with no window at all.

## Goal

Use Flutter's desktop windowing API for the app start: a splash window while the boot is
slow, then the real main window — both created from Dart, both carrying the app's own
chrome. The runner owns no window any more.

## What the engine actually does on macOS

Read at the installed SDK (master, 3.48.0-1.0.pre-713), engine file
`shell/platform/darwin/macos/framework/Source/FlutterWindowController.mm`:

| Dart controller | NSWindow the engine creates |
|---|---|
| `WindowController` (regular) | `titled \| closable \| miniaturizable (\| resizable)`, shown on first frame |
| `DialogWindowController`, `parent == null` | `titled \| closable (\| resizable)`, shown on first frame |
| `DialogWindowController`, `parent != null` | same window, but presented as a **sheet** of the parent (`beginCriticalSheet`) |
| `TooltipWindowController` / `PopupWindowController` | **borderless**, transparent, child window of a required parent; popups close when the parent loses key |

Consequences:

- **"Modal" is a sheet.** A modal dialog needs a visible parent to hang from. An invisible
  or zero-size parent has no title bar to attach a sheet to, and `Size.zero` is not
  invisible anyway: AppKit clamps a titled window to its title bar.
- **No borderless top-level window type.** Only tooltips and popups are borderless, and both
  need a parent window and cannot become key.
- **Multi-view is all or nothing.** `FlutterEngine.enableMultiView` asserts that no view
  controller exists yet, so the runner must attach none. `MainFlutterWindow.swift` and the
  nib's window object are gone; `AppDelegate` runs a view-less `FlutterEngine` and Dart
  creates every window — the shape of the upstream `examples/multiple_windows` runner.
- **Escape hatch.** The macOS controllers expose the `NSWindow` pointer
  (`BaseWindowControllerMacOS.windowHandle`) so native code can customise a window the
  engine owns. Everything native below goes through that handle.

## Design

```
boot (openSettings → startApp) starts before any window, racing a 500 ms timer
  ├─ boot wins  → runWidget(WindowManager(initialWindows: [ main ]))   ← no splash exists
  └─ timer wins → runWidget(WindowManager(initialWindows: [ splash ]))
                    ├─ main window opens at max(boot end, 500 ms + 1000 ms)
                    └─ splash fades out natively, unregisters itself, is destroyed
a destroyed window unregisters itself; the last one exits the process
```

### The splash race (and why)

The boot starts *before* `runWidget`, and whichever of the two — boot or timer — wins
decides which window is handed to `runWidget`. That matters because **the first window has
to be part of the engine's warm-up frame**: the engine only shows a window once it has
presented a frame, and only the warm-up frame is timer-driven — every later frame waits for
the display link of a view that does not exist yet. A window created after `runWidget` on a
view-less engine is created but stays invisible (verified in the POC).

The documented fallback — always create the splash and hold it at native `alphaValue = 0`
on a fast boot — was **not needed**: the engine is happy to take whichever window exists at
`runWidget` time, so a fast boot never creates a splash object at all.

### Min-show semantics translate, they do not survive literally

The old in-window splash (`2026-09-07-app-bootstrap-splash-design.md`, superseded) faded an
opaque overlay off a mounted app. With two windows the main window is visible the moment it
opens, so it opens at `max(boot end, delay + minShow)` instead — otherwise a 1000×700 window
would pop up around the 320×320 splash for a second. Unchanged: nothing before 500 ms, at
least 1000 ms once shown, a 200 ms fade, no splash at all on a fast boot, the failure page,
the `SEVERE` record on `zanshin.bootstrap`, and reduced motion.

### Components

- **`ZanshinBootSequence`** (`lib/src/features/bootstrap/zanshin_bootstrap.dart`) — the
  sequencer: runs the two boot steps, races the timers, and drives a `BootWindowHost`
  (`openSplash` / `openMain(Widget)` / `dismissSplash(Duration)`). The interface carries no
  windowing type, so `flutter test` drives the whole matrix against a fake while
  `tester.pump(Duration)` owns the clock. Timing comes from `Timer`s only, never from
  reading a clock.
- **`ZanshinWindowHost`** (`lib/src/features/bootstrap/boot_window_host.dart`) — the real
  host and the only place that calls `runWidget`. Not unit-tested; covered by the runtime
  smoke check.
- **`AppWindows`** (`lib/src/features/window/app_windows.dart`) — the key → `WindowEntry`
  map over the `WindowRegistry`, with `openOrActivate` (re-opening a key activates the open
  window instead), the lifecycle delegate that unregisters a destroyed window, and the
  exit-when-empty rule. `WindowManager` keeps its registry private, so `AppWindows` wraps
  every window builder and captures it from the first build (`WindowRegistry.of(context)`).
  Nothing here assumes a single window: the later project windows open through exactly
  `openOrActivate`.
- **`SplashWindowController`** (`lib/src/features/window/splash_window_controller.dart`) —
  subclasses the engine's `DialogWindowControllerMacOS` (parentless, `resizable: false`)
  and, before the engine shows the window, asks the runner over the `zanshin/splash_window`
  channel to strip the chrome: borderless, transparent background, fixed size, centred,
  floating, not movable. `create()` is async because the chrome must be gone before the
  first frame makes the window visible. `fadeOut()` animates the window's alpha natively so
  the shadow fades with the content; `Duration.zero` is what "reduce motion" passes.
- **`RememberedWindowController`** (`lib/src/features/window/remembered_window_controller.dart`)
  — a regular window remembered under a key (`main`, later `project:<path>`). Subclasses the
  engine's `WindowControllerMacOS`; `create()` asks the runner over `zanshin/window_frames`
  to apply the chrome and restore the saved frame before the first frame shows the window.
  The windowing API has a content size but no position, hence native.
- **`MainWindowChrome.swift`** (`macos/Runner/`) — the app's chrome, ported from the deleted
  `MainFlutterWindow`: `.fullSizeContentView` style mask, transparent titlebar, hidden
  title, clear non-opaque background, `minSize` 900×600, `isRestorable = false`, the toolbar
  + drag-interceptor accessory, the `NSVisualEffectView`, and `TrafficLightOverlayView`.
- **`WindowFrameStore.swift`** (`macos/Runner/`) — native half of `zanshin/window_frames`.
  Applies the chrome (when the `chrome` argument is set), *then* the frame, then keeps
  saving position, size and the display (id, offset, size) per key in the UserDefaults suite
  `<bundle id>.window_frames` on every move and resize, restoring only when that display is
  still connected (exact match, else same display id at the same x offset). The old
  single-window `<bundle id>.app_position` suite is dead; nothing reads it and there is no
  migration.
- **`WindowingBootstrap.swift`** (`macos/Runner/`) — the view-less `FlutterEngine` with the
  generated plugins, `SplashWindowHost` (channel `zanshin/splash_window`: `configure`,
  `fadeOut`), the frame store, app activation, and the hot-restart workaround (below).
- **`AppDelegate.swift`** — starts the engine and returns `false` from
  `applicationShouldTerminateAfterLastWindowClosed`: AppKit runs that check deferred, so the
  transient gap between the main window opening and the splash being destroyed would quit
  the app. Dart's registry owns the rule instead.
- **`zanshin_shell_macos`** — with a view-less engine `registrar.view` is nil for good and
  `NSApp.mainWindow` is nil until a window becomes key, so the plugin resolves its window
  from `NSApp.windows`, filtered to a `FlutterViewController` window that is `.titled` —
  which is exactly "an app window, never the borderless splash".

### Chrome on a window the engine owns

Two things had to change when the chrome moved off an `NSWindow` subclass:

- **Ordering.** The chrome must be applied *before* the saved frame. With
  `.fullSizeContentView` the frame is the content size; applying a frame under a
  non-final style mask shaves the titlebar height off the window on every launch. Both
  happen in the one `restore` round-trip, chrome first.
- **The vibrancy view is a sibling now.** It used to be the window's content view, with the
  Flutter view as its subview (`WrapperViewController`). The engine owns the
  `contentViewController` of a window it created, so the `NSVisualEffectView`
  (`.behindWindow`, `.active`, corner radius 20) is inserted into the frame view directly
  *below* `window.contentView`, and re-stacked from the same notifications that re-attach
  the traffic-light overlay (key, exit-fullscreen), because a titlebar rebuild can orphan
  it. The Flutter view keeps drawing on top and unclipped.

### Activation

`flutter run` foregrounds the app with `open <bundle>` only after attaching a VM service,
i.e. never in `--release` (flutter_tools `desktop_device.dart:139`, `macos_device.dart:86-89`);
exec'd directly the process starts inactive behind the terminal. Under cooperative
activation (macOS 14+) a bare `NSApp.activate()` is only honoured after the frontmost app
yielded, which a terminal never does; the soft-deprecated `activate(ignoringOtherApps: true)`
still is (Neovide #2799, Electron #40570), and is issued twice because macOS 26 drops
requests at random (Apple FB21087054).

### Hot-restart workaround

The engine's `closeAllWindows` (run on hot restart) disposes each view controller and closes
the window without detaching the window delegate, unlike `destroyWindow`; closing the *key*
window then calls `viewIdentifier` on the disposed controller and the debug build dies with
`NSInternalInconsistencyException`. The runner detaches the delegate on
`NSWindow.willCloseNotification` for Flutter windows. Worth an upstream issue.

## Verified at runtime (2026-09-12, debug build)

- Fast (warm) boot: exactly one window, no splash object ever created.
- Slow boot (temporarily delayed by 3 s): a 320×320 borderless window at
  `NSFloatingWindowLevel`, centred; the main window then opens and the splash disappears.
- Remembered frame: a frame seeded under `main` is restored verbatim (1000×700 at 120,140),
  and the Flutter view measures 1000×700 — equal to the window frame, which is only true
  with `.fullSizeContentView`, i.e. the chrome is applied before the frame.
- Hot restart twice in a row: the app survives, the window comes back at the same frame, and
  the stored frame does not drift.
- `q` in `flutter run` quits cleanly, no process left behind.

Not verified at runtime (no screen-recording permission in that session): the *visual*
result of the chrome — vibrancy, rounded corners, the gray traffic-light rings and their
hover cross-fade — and closing the last window by hand. The exit rule is unit-tested.

## Still open

- A Window menu, and a project-list window: closing the main window today leaves no way
  back. `AppWindows.openOrActivate` is the seam both will use.
- **Closing the last window skips the worker's graceful shutdown.** The registry exits with
  `AppExitType.required`, which the framework documents as exiting immediately without
  querying the application, so `AppLifecycleListener.onExitRequested` — and with it
  `ZanshinWorker.close()` — does not run. ⌘Q still goes through `onExitRequested` and shuts
  the worker down cleanly. Deliberate for now (the OS reclaims the process either way);
  revisit if the worker ever holds state that must be flushed.
- **`openOrActivate` is not re-entrant per key.** Two concurrent calls for the same key can
  both miss the lookup before the first one's `await` resolves and end up creating two
  native windows. No caller does this today (the main window is opened once, from the boot
  sequence); the project-list window will need a per-key in-flight guard.
- A full-screen frame is not saved; the last normal one is restored.
- Reset the remembered frames with `defaults delete de.dasralph.zanshin.window_frames`
  (it still holds the POC's dead `start` and `project:*` keys).
- The cross-fade is timed by the Dart frame that renders the main window (`endOfFrame`), not
  by the window actually appearing; the engine shows it a few milliseconds later, well
  inside the 200 ms fade. A very slow first raster would let the splash fade before the
  window shows.
- The splash floats only while this app is active and is a normal window otherwise (the
  floating level is global; `hidesOnDeactivate` raced the activation at start and left the
  splash invisible).
- The windowing API is `@internal` and will break; every use of it is behind
  `invalid_use_of_internal_member` / `implementation_imports` ignores in four files.
