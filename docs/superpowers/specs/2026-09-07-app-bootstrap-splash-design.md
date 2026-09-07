# App bootstrap widget with delayed splash — Design

**Date:** 2026-09-07
**Status:** implemented 2026-09-07 (plan: `docs/superpowers/plans/2026-09-07-app-bootstrap-splash.md`)
**Scope:** `app/lib/main.dart` and a new bootstrap widget in `app/`; the Lottie
loader asset and the `lottie` dependency. No change to `packages/*`, the DI
graph, or `ZanshinApp`.

## Goal

Call `runApp` immediately and do the asynchronous app initialisation (settings
file, DI graph, worker isolate) *behind* the first frame, inside a bootstrap
widget. While it runs, the window shows the app's background colour; only when
booting takes noticeably long does the Nami loader animation appear, and once
shown it stays long enough not to flicker. When the boot fails, the same widget
shows an error page instead of leaving the window empty.

## Context

- Today `main()` (`app/lib/main.dart`) awaits `SettingsStore.open()` and
  `mainComponent.worker` (isolate spawn + cdylib load) before `runApp`, so the
  window sits on the native `NSVisualEffectView` blur until everything is up.
- The DI graph (`MainComponent`) needs the loaded `SettingsStore` at creation
  (`SettingsModule(store:)`, see the settings spec), so `ZanshinApp` cannot
  exist before the settings file is read.
- `ZanshinApp` builds a `MaterialApp` (`package:material_ui`) with the yaru
  themes; the scaffold background is `yaruLight`/`yaruDark.scaffoldBackgroundColor`
  (= yaru's `lightBaseColor`/`darkBaseColor`, independent of the accent colour).
- The macOS window is transparent (`backgroundColor = .clear`, blur behind).
  Anything Flutter does not paint shows the blur.
- The loader animation is the Claude Design export in `Zanshin/lottie/`
  (untracked design folder): `nami_loader.json` (waves + indigo tile),
  `nami_loader_transparent.json` (waves only), `nami_loader_pulse.json`.
  Re-baked 2026-09-07 with the final values: hub 20.5, spread 40, sweep 1.30 s,
  pause 0.55 s → 56 frames @ 30 fps = 1.867 s, seamless loop.

## Decisions (with rationale)

| Decision | Choice | Why |
|---|---|---|
| Where the gate lives | A root `ZanshinBootstrap` widget passed to `runApp`; it swaps to `ZanshinApp` when ready | The only place that can exist before settings/DI. Putting the splash inside `ZanshinApp` (as `home`) would still need the graph before `runApp`. |
| What stays in `main()` | Binding, plugin registrant, semantics, log forwarding, `FlutterError.onError`, the `runZonedGuarded` zone | All synchronous and cheap; they do not delay the first frame. |
| Indicator pattern | Android `ContentLoadingProgressBar` semantics: show only after a minimum delay, then keep for a minimum time | Fast boots never flash a loader; slow boots never blink one. |
| Timings | delay **500 ms**, minimum show **1000 ms**, fade-out **200 ms**, indicator fade-in **150 ms** | Ralph's choice (500/1000). The fades keep the icon from popping in or being cut mid-sweep. |
| Animation | `package:lottie` (MIT), `nami_loader.json` at 96 px, native loop duration | Ralph wants the baked Lottie files; the timing lives in the file, the widget does not care about it. The `CustomPainter` alternative in `Zanshin/rive/nami_wave.dart` was rejected (Ralph wants to swap between the baked variants). |
| Swappable variant | One top-level constant holds the asset path; both `nami_loader.json` and `nami_loader_transparent.json` are bundled | Swapping to the transparent variant is a one-line edit, no pubspec change. |
| Splash colour | The scaffold background of the yaru theme for the resolved brightness | Identical to the colour the app paints first, so the app appearing is invisible in the background. |
| Brightness resolution | Platform brightness (`MediaQuery.fromView`) until the settings are read; then a persisted `light`/`dark` wins, `system` keeps following the platform | A forced mode is known after the very first boot step (a few ms), so the splash is right for all but the first frame. |
| Transition | The app is built *under* the splash; the splash fades out on top and is then removed | A cross-fade of two siblings would let the window blur bleed through while both are semi-transparent. The overlay also hides `ZanshinApp`'s own first frames (shell theme still pending). No fade when the indicator was never shown — the app just appears. |
| Failure | Error page with a headline and the selectable error text, same background; logged at `SEVERE` | Ralph's choice. Replaces today's silent empty window. |
| Reduce motion | With `MediaQuery.disableAnimationsOf(context)` the loader shows its first frame (the static logo) instead of animating | Platform accessibility convention; one boolean on `Lottie.asset`. |
| Boot steps injected | `ZanshinBootstrap` takes `openSettings` and `startApp` functions | Tests drive the widget with fakes; `main.dart` passes `SettingsStore.open` and the DI/worker sequence. Two functions because the splash needs the settings *between* the steps. |

## `main.dart`

```dart
Future<void> main() async {
  await runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();
      DartPluginRegistrant.ensureInitialized();          // unchanged
      SemanticsBinding.instance.ensureSemantics();        // unchanged
      initLogForwarding(level: .ALL);                     // unchanged
      FlutterError.onError = ...;                         // unchanged
      runApp(ZanshinBootstrap(openSettings: SettingsStore.open, startApp: _startApp));
    },
    (error, stackTrace) => developer.log(...),           // unchanged
  );
}

/// Builds the DI graph over the loaded settings, starts the worker (which also
/// installs the AppLifecycleListener via the provision listener) and returns
/// the app widget.
Future<Widget> _startApp(SettingsStore settings) async {
  // ignore: specify_nonobvious_local_variable_types
  final mainComponent = MainComponent.create(settingsModule: SettingsModule(store: settings));
  await mainComponent.worker;
  return mainComponent.zanshinAppFactory.create();
}
```

`MainComponent` (annotation, getters) and `main.inject.dart` do not change.
The boot runs inside the widget, which lives inside the zone `runApp` was
called in, so the "same zone" rule still holds.

## `ZanshinBootstrap`

`app/lib/src/features/bootstrap/zanshin_bootstrap.dart` — one file: the public
widget plus private `_SplashScreen` and `_BootFailure` (private widget helpers
stay in the same file, per the app conventions). Tunables at the top of the file:

```dart
/// Loader animation. Swap for `assets/lottie/nami_loader_transparent.json`
/// to show the waves without the indigo tile.
const splashAnimationAsset = 'assets/lottie/nami_loader.json';
const splashAnimationSize = 96.0;
const splashIndicatorDelay = Duration(milliseconds: 500);
const splashIndicatorMinShow = Duration(milliseconds: 1000);
const splashIndicatorFadeIn = Duration(milliseconds: 150);
const splashFadeOut = Duration(milliseconds: 200);
```

```dart
/// Root widget: shows the splash while [openSettings] and [startApp] run,
/// then the widget [startApp] returned (or an error page).
class ZanshinBootstrap extends StatefulWidget {
  const ZanshinBootstrap({required this.openSettings, required this.startApp, super.key});

  final Future<SettingsStore> Function() openSettings;
  final Future<Widget> Function(SettingsStore settings) startApp;
}
```

State and flow (`_ZanshinBootstrapState`):

1. `initState`: start `Timer(splashIndicatorDelay, _showIndicator)` and the boot
   (`unawaited(_boot())`).
2. `_boot`: `settings = await openSettings()` → `setState` with the persisted
   `ThemeMode` (splash may re-colour) → `app = await startApp(settings)` →
   `setState` with the app widget. Any thrown object (a plain `catch`, since
   worker/FFI failures may be `Error`s and this is the process-level boundary)
   is logged at `SEVERE` on `Logger('zanshin.bootstrap')` and stored as the
   error. Either way `_onBootFinished()` runs.
3. `_showIndicator` (delay elapsed, boot still running): `setState` indicator
   visible; remember when.
4. `_onBootFinished`:
   - indicator never shown → cancel the delay timer, drop the splash at once
     (no fade);
   - indicator shown → wait until `splashIndicatorMinShow` has elapsed since it
     appeared (a second `Timer`, zero if already elapsed), then start the
     fade-out; when `AnimatedOpacity.onEnd` fires, drop the splash.
5. `dispose`: cancel both timers.
6. `build`:

```dart
Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery.fromView(
    view: View.of(context),
    child: Stack(
      fit: StackFit.expand,
      children: [
        if (_app != null) _app!
        else if (_error != null) _BootFailure(error: _error!, mode: _persistedMode),
        if (!_splashDismissed)
          IgnorePointer(
            child: AnimatedOpacity(
              opacity: _fadingOut ? 0 : 1,
              duration: splashFadeOut,
              onEnd: _dismissSplash,
              child: _SplashScreen(mode: _persistedMode, showIndicator: _indicatorVisible),
            ),
          ),
      ],
    ),
  ),
)
```

Both private widgets resolve their brightness from *their own* context (which
sits below the `MediaQuery.fromView`) through one file-private helper:
persisted `ThemeMode.light`/`dark` → that brightness; `system` or not yet
loaded (`null`) → `MediaQuery.platformBrightnessOf(context)`.

The `Directionality` is required by `Stack`'s default directional alignment
and by the text on the error page; `MediaQuery.fromView` provides platform
brightness and `disableAnimations` outside of any `MaterialApp`.

Material types (`MaterialApp`, `Scaffold`, `SelectableText`, `ThemeMode`)
come from `package:material_ui`, the app's Material library — its `ThemeMode`
is the type the settings model stores, distinct from Flutter's.

### `_SplashScreen`

`ColoredBox` filling the window with
`(brightness == Brightness.dark ? yaruDark : yaruLight).scaffoldBackgroundColor`,
a centred `AnimatedOpacity` (`splashIndicatorFadeIn`, opacity 0 → 1 when
`showIndicator`) around

```dart
Lottie.asset(
  splashAnimationAsset,
  width: splashAnimationSize,
  height: splashAnimationSize,
  repeat: true,
  animate: !MediaQuery.disableAnimationsOf(context),
)
```

The `Lottie` widget is only in the tree while `showIndicator` is true, so a
fast boot never even loads the asset.

### `_BootFailure`

A minimal `MaterialApp(theme: yaruLight, darkTheme: yaruDark, themeMode: <from brightness>)`
whose home is a `Scaffold` with a centred column: headline
"Zanshin could not start." and a `SelectableText('$error')`. No retry, no
button (⌘Q quits as usual). It sits under the splash like the app does, so the
minimum-show/fade rules apply unchanged.

## Assets and dependency

- `app/pubspec.yaml`: `lottie: ^3.5.1` (MIT; pure Dart; added with
  `flutter pub add lottie` in `app/`, workspace lock at the repo root updates).
- Copy from the design export (which stays untouched — it is Ralph's untracked
  Claude Design folder and its README references sibling files):
  - `Zanshin/lottie/nami_loader.json` → `app/assets/lottie/nami_loader.json`
  - `Zanshin/lottie/nami_loader_transparent.json` → `app/assets/lottie/nami_loader_transparent.json`
  - `Zanshin/lottie/README.md` → `app/assets/lottie/README.md` (values and
    equations; not bundled)
- `flutter.assets` lists the two JSON files individually (never the directory,
  so the README is not bundled). `nami_loader_pulse.json` is not copied.

## Testing

`app/test/features/bootstrap/zanshin_bootstrap_test.dart` (`flutter test`, fake
time via `tester.pump(Duration)`; settings via `SettingsStore.load` on a temp
file like the view-model test; `startApp` fakes return a `Completer` future and
a marker widget):

- fast boot (completes at 100 ms): no `Lottie` at any point, the marker widget
  is visible right after completion, no fade (splash gone on the next frame)
- slow boot: no `Lottie` at 499 ms, `Lottie` at 500 ms; boot completes at
  600 ms → the marker widget is in the tree under the splash, the splash is
  still fully opaque at 1499 ms, fading at 1500 ms, gone after 1700 ms
- boot completes long after the minimum (at 3 s): fade starts immediately
- failure (`startApp` throws): the error page shows "Zanshin could not start."
  and the error text after the same min-show rule; a `SEVERE` record is logged
- brightness: persisted `dark` under a light platform → dark scaffold colour
  once the settings step completed; `system` → platform brightness;
  persisted `light` under a dark platform → light
- reduce motion (`accessibilityFeaturesTestValue` with `disableAnimations`):
  the `Lottie` widget has `animate == false`
- dispose while booting: no exception, no `setState` after dispose (pump the
  widget away, then complete the future)

`main.dart` stays untested (as today). The Rust `coverage-baseline.txt` does
not change.

## Non-goals

- A native AppKit launch screen or window-level placeholder.
- Progress reporting per boot step, a retry or quit button.
- Mirroring the persisted theme onto the native window chrome before
  `ZanshinAppViewModel.init` does it (the splash covers the whole window
  including the title-bar strip, so nothing native is visible meanwhile).
- Using the loader anywhere else than at app start.
- Localisation of the two error-page strings.

## Files touched

- `app/lib/main.dart` (boot moved into `_startApp`, `runApp(ZanshinBootstrap(...))`)
- `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` (new)
- `app/test/features/bootstrap/zanshin_bootstrap_test.dart` (new)
- `app/pubspec.yaml` (dependency + assets), `pubspec.lock` (workspace)
- `app/assets/lottie/` (new: two JSON files + README)
