# Windowing-API splash POC — design

**Status:** proof of concept, 2026-09-11. Lives next to the real bootstrap; `main.dart`
is untouched.

## Goal

Try Flutter's experimental desktop windowing API (`flutter config --enable-windowing`,
master channel) for the app start: a splash window first, then the regular main window.
Ralph's sketch: an invisible root `Window`, a modal buttonless splash on top of it for a
few seconds, then a normal window.

## What the engine actually does on macOS

Read at the installed SDK (master, 3.48.0-1.0.pre-713), engine file
`shell/platform/darwin/macos/framework/Source/FlutterWindowController.mm`:

| Dart controller | NSWindow the engine creates |
|---|---|
| `WindowController` (regular) | `titled \| closable \| miniaturizable (\| resizable)`, shown on first frame |
| `DialogWindowController`, `parent == null` | `titled \| closable (\| resizable)`, shown on first frame |
| `DialogWindowController`, `parent != null` | same window, but presented as a **sheet** of the parent (`beginCriticalSheet`) |
| `TooltipWindowController` / `PopupWindowController` | **borderless**, transparent, child window of a required parent; popups close when the parent loses key |

Consequences for the sketch:

- **"Modal" is a sheet.** A modal dialog needs a visible parent to hang from. An invisible
  or zero-size parent has no title bar to attach a sheet to, and `Size.zero` is not
  invisible anyway: AppKit clamps a titled window to its title bar.
- **No borderless top-level window type.** Only tooltips and popups are borderless, and both
  need a parent window and cannot become key.
- **Multi-view is all or nothing.** `FlutterEngine.enableMultiView` asserts that no view
  controller exists yet. The runner's `MainFlutterWindow` attaches the implicit view in
  `awakeFromNib`, so with the current runner the first Dart-created window crashes.
  The upstream `examples/multiple_windows` runner has no `MainFlutterWindow.swift` at all:
  its `AppDelegate` runs a view-less `FlutterEngine` and Dart creates every window.
- **Escape hatch.** The macOS controllers expose the `NSWindow` pointer
  (`BaseWindowControllerMacOS.windowHandle`) so native code can customise a window the
  engine owns.

## Design

Splash first, then the start window (the project list), and a double-click on a project
opens that project in its own window. Every window except the splash remembers its frame.
No root window: `runWidget` needs no window at the root, the tree simply changes which
`View`s it contains. Not modal: the API's modal dialog is a sheet on a visible parent, so the
splash is a modeless dialog raised to the floating level instead — only while this app is
active, since the floating level is global; inactive it drops to the normal level rather than
hiding (`hidesOnDeactivate` raced the activation at start and left the splash invisible).
Nothing is lost — while the splash is up there is no other window to block, and once the
start window exists the splash only floats above it for the fade.

```
runWidget(WindowManager(initialWindows: [ splash ]))          ← the registry owns the windows
  ├─ splash content runs the boot (faked with a delay in the POC)
  ├─ registers the start window (remembered under `start`)    ← appears on its first frame
  ├─ splash fades out natively, unregisters itself, is destroyed
  └─ start window: double-click → registers `project:<path>` window; a destroyed window
     unregisters itself, the last one exits the process
```

### Components

- **`SplashWindowController`** (`lib/src/features/bootstrap/splash_window_controller.dart`)
  — the custom controller. Subclasses the engine's `DialogWindowControllerMacOS`
  (parentless, `resizable: false`) and, before the engine shows the window, asks the runner
  over the `zanshin/splash_window` channel to strip the chrome: borderless, transparent
  background, fixed size, centred, floating, not movable. `create()` is async because the
  chrome must be gone before the first frame makes the window visible. `fadeOut()` animates
  the window's alpha natively so the shadow fades with the content.
- **`RememberedWindowController`** (`lib/src/features/bootstrap/remembered_window_controller.dart`)
  — a regular window remembered under a key (`start`, `project:<path>`). Subclasses the
  engine's `WindowControllerMacOS`; `create()` asks the runner over `zanshin/window_frames`
  to restore the saved frame before the first frame shows the window. The windowing API has
  a content size but no position, hence native.
- **`WindowFrameStore.swift`** (`macos/Runner/`) — native half of that channel. Saves
  position, size and the display (id, offset, size) per key in the UserDefaults suite
  `<bundle id>.window_frames` on every move and resize, exactly like the pre-windowing
  `MainFlutterWindow.swift` did for its single window, and restores only when that display
  is still connected (exact match, else same display id at the same x offset).
- **`WindowingBootstrap.swift`** (`macos/Runner/`) — `WindowingMode.isEnabled` (the
  `--windowing` process argument), a view-less `FlutterEngine` with the generated plugins,
  `SplashWindowHost` (channel `zanshin/splash_window`: `configure`, `fadeOut`), the frame
  store, app activation, and a hot-restart workaround (below).
- **Activation.** `flutter run` foregrounds the app with `open <bundle>` only after attaching
  a VM service, i.e. never in `--release` (flutter_tools `desktop_device.dart:139`,
  `macos_device.dart:86-89`); exec'd directly the process starts inactive behind the
  terminal. Under cooperative activation (macOS 14+) a bare `NSApp.activate()` is only
  honoured after the frontmost app yielded, which a terminal never does; the soft-deprecated
  `activate(ignoringOtherApps: true)` still is (Neovide #2799, Electron #40570), and is
  issued twice because macOS 26 drops requests at random. Verified with a direct exec: the
  app is frontmost within 2.5 s.
- **Hot-restart workaround.** The engine's `closeAllWindows` (run on hot restart) disposes
  each view controller and closes the window without detaching the window delegate, unlike
  `destroyWindow`; closing the *key* window then calls `viewIdentifier` on the disposed
  controller and the debug build dies with `NSInternalInconsistencyException`. The runner
  detaches the delegate on `NSWindow.willCloseNotification` for Flutter windows. Worth an
  upstream issue.
- **`zanshin_shell_macos`** — the engine runs the generated Dart plugin registrant before
  `main` (`runtime/dart_isolate.cc:927`), in every runner shape; the plugin installed its
  channel handler in the constructor and asserted without a binding. The handler is now
  installed on the first listener of `onThemeChanged`, `registerWith` is a pure instance
  assignment like every reference plugin. `main.dart`'s explicit
  `DartPluginRegistrant.ensureInitialized()` re-ran the registrant after the binding existed
  and masked the failure; it is now redundant (left untouched here).
- **Runner gate** — in windowing mode `MainFlutterWindow.awakeFromNib` attaches nothing and
  keeps the nib window invisible; `AppDelegate` closes it, starts the engine, and stops
  terminating on the last closed window only until a Dart window has appeared on screen
  (AppKit runs that check deferred, so the nib window's close would otherwise quit the app
  as soon as the still hidden splash exists); afterwards the usual macOS rule applies, and
  Dart's registry exits with its last window as well.
  Without the flag the runner behaves exactly as before.
- **`main2.dart`** — the flow above on the API's own `WindowManager`/`WindowRegistry`: a
  rounded splash card with the existing Lottie loader, the start window with a demo project
  list (1200×800 first launch, min 900×600), project windows per double-click, and a window
  delegate that unregisters a destroyed window and exits with the last one. Double-clicking a
  project that is already open brings its window to the front instead of opening a second.

### The switch

`flutter run` on desktop passes `--dart-entrypoint-args` as process arguments, so the runner
can read it from `CommandLine.arguments` (the global `flutter config --enable-windowing` flag
must be on as well; it is on this machine):

```bash
flutter run -d macos -t lib/main2.dart --dart-entrypoint-args=--windowing
```

The same works with `--release` (verified by exec'ing the release binary directly: the app
comes to the front on its own). One tool limitation: with `--release` the `flutter run`
prompt does not return when the app quits — the tool only finishes on a VM-service
disconnect or on `q` (`run_cold.dart`, `resident_runner.dart:_serviceDisconnected`), and a
release build has no VM service. Verified: in debug the prompt returns within a second of
the app quitting, in release it waits for `q`. `--profile` keeps the VM service, or run the
built bundle with `open`.

The macOS engine hands the same process arguments to Dart's `main`, so `main2.dart` detects
a forgotten flag and renders the run command into the runner's window instead of crashing in
the engine. (Checking `PlatformDispatcher.implicitView` does not work: the headless engine
reports an implicit view too.)

## Not covered (next steps if the POC convinces)

- The start and project windows are stock titled windows. The custom chrome of the real app
  (transparent title bar, traffic-light overlay) would need the same handle-based native
  treatment; the saved frame is done.
- A frame is saved on move and resize only; a window without a saved frame is centred on
  its screen, like the first launch before (the engine itself places new windows near the
  bottom-left corner). A full-screen frame is not saved; the last normal one is restored.
- Closing the start window while project windows are open leaves them running with no way
  back to the project list (a Window menu is the real app's job); the last window exits.
- Reset the remembered frames with `defaults delete de.dasralph.zanshin.window_frames`.
- Real boot (settings, DI, worker) instead of the delay; the error page on boot failure.
- Reduced motion: only the loader respects it, the native fade does not yet.
- The cross-fade is timed by the Dart frame that renders the start window (`endOfFrame`), not
  by the window actually appearing; the engine shows it a few milliseconds later, well inside
  the 250 ms fade. A very slow first raster would let the splash fade before the window shows.
- The splash floats only while this app is active and is a normal window otherwise; the app
  activates itself at start, see Activation above.
- The API is `@internal` and will break; this is not production code.
