# App bootstrap widget with delayed splash — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `runApp` is called immediately; the settings file, the DI graph and the worker isolate are booted behind the first frame by a root `ZanshinBootstrap` widget that shows the app's background colour, the Nami loader animation only for slow boots (after 500 ms, then at least 1 s), and an error page when the boot fails.

**Architecture:** `ZanshinBootstrap` (`StatefulWidget`, root of the tree) takes two injected boot steps — `openSettings()` and `startApp(settings)` — runs them in `initState`, and overlays a `_SplashScreen` (opaque `ColoredBox` in the yaru scaffold colour, optional `Lottie` loader) on top of the finished app until the minimum-show rule allows a 200 ms fade-out. Timing is driven by two `Timer`s (delay, minimum show) and flags — never by reading the clock — so `flutter test`'s fake time controls it fully. `main.dart` keeps the synchronous setup and passes `SettingsStore.open` and a `_startApp` function (DI graph + worker + `zanshinAppFactory.create()`).

**Tech Stack:** Flutter master (3.48 pre) / Dart 3.14 pub workspace, `package:material_ui` (the app's Material library; re-exports `flutter/widgets.dart`), `package:yaru` (path dep `../../yaru.dart`, `yaruLight`/`yaruDark`), `lottie` 3.5.1 (MIT, pure Dart), `zanshin_settings` (`SettingsStore`, `ThemeMode` from material_ui), `logging` 1.3, `flutter_test`.

Spec: `docs/superpowers/specs/2026-09-07-app-bootstrap-splash-design.md` (read it first).

## Global Constraints

- Every new hand-written Dart file starts with `// SPDX-License-Identifier: MIT` on line 1.
- Lints: `linter/rules.yaml` (page width 120; `prefer_relative_imports` inside `lib/`; `avoid_catching_errors` — a plain `catch (error, stackTrace)` without `on` is allowed; `specify_nonobvious_local_variable_types` / `omit_obvious_local_variable_types` — annotate locals initialised from a call, omit the annotation for literals and constructors; `require_trailing_commas`; `sort_constructors_first`; `always_put_control_body_on_new_line`; `prefer_expression_function_bodies`; `unawaited_futures`/`discarded_futures`; `sort_pub_dependencies`). The gate runs `dart analyze --fatal-infos --fatal-warnings` and `dart format --output=none --set-exit-if-changed .` in `app/` — infos fail the build.
- Material types (`MaterialApp`, `Scaffold`, `SelectableText`, `Text`, `ThemeMode`, `Brightness`, `Color`, every widget) come from `package:material_ui/material_ui.dart` — never import `package:flutter/material.dart`. Its `ThemeMode` is the type `AppSettings.appearance.themeMode` stores.
- Verify with the CLI commands given in each step (not an IDE/MCP analyzer, which can be stale). Run commands one at a time, from the directory stated, without `&&` chains and without piping to `tail`/`head` (that masks the exit code).
- Comments and docs in English; `///` on every exported item; comments explain WHY, not WHAT.
- No `dart:ffi`, no `Isolate.run`, no telemetry, no new non-permissive-license dependency (lottie is MIT).
- Logging: `package:logging` only (`Logger('zanshin.bootstrap')`); the boot failure is logged at `SEVERE` with the error and stack trace as the record's error/stackTrace fields.
- Commits: `git commit --no-gpg-sign` (1Password signing is unavailable unattended); subject imperative, ≤ ~60 chars; body ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Direct commits to `main` are allowed. Never `git add` the untracked design export `Zanshin/` (Ralph's Claude Design folder) — add files by explicit path.
- `cargo make test` (repo root) is the definition of done; it ends with the Rust coverage ratchet. Rust is untouched here, so `coverage-baseline.txt` must not change — never edit it.
- Do not run `flutter run`; the native compile check is `flutter build macos --debug` (Task 6).
- Do not touch `app/lib/src/features/home/`, `app/lib/src/features/shell/`, `zanshin_app.dart`, the view model, `main.inject.dart` or any `packages/*` file. Only `main.dart`, the new bootstrap file, its test, `app/pubspec.yaml`, `pubspec.lock` and `app/assets/lottie/` change.
- Widget tests: real file IO (`SettingsStore.load`) must run inside `tester.runAsync(...)` — the widget-test body runs in a fake-async zone where dart:io completions never arrive. Every test must end with the boot finished or the widget pumped away (`tester.pumpWidget(const SizedBox())`), otherwise a pending `Timer` fails the test.

---

### Task 1: The `lottie` dependency and the loader assets

**Files:**
- Modify: `app/pubspec.yaml`
- Modify: `pubspec.lock` (workspace lock at the repo root, updated by pub)
- Create: `app/assets/lottie/nami_loader.json`, `app/assets/lottie/nami_loader_transparent.json`, `app/assets/lottie/README.md` (copies from `Zanshin/lottie/`)

**Interfaces:**
- Produces: the asset keys `assets/lottie/nami_loader.json` and `assets/lottie/nami_loader_transparent.json`, and `package:lottie/lottie.dart` (`Lottie.asset(...)` returning a `LottieBuilder` with the fields `animate`, `repeat`, `width`, `height`).

- [ ] **Step 1: Add the dependency**

Run in `app/`:

```bash
flutter pub add lottie
```

Expected: `pubspec.yaml` gains `lottie: ^3.5.1` (or the newest 3.x) and the root `pubspec.lock` gains `lottie`, `archive` (its only transitive dependency besides `vector_math`, both already present or permissive). Open `app/pubspec.yaml` and make sure the `dependencies:` block is still alphabetical — `lottie` must sit between `logging` and `material_ui`:

```yaml
dependencies:
  ffi: ^2.2.0
  flat_buffers: ^25.9.23
  flutter:
    sdk: flutter
  flutter_svg: ^2.3.0
  inject_annotation: ^1.2.1
  inject_flutter: ^1.2.1
  logging: ^1.3.0
  lottie: ^3.5.1
  # theme_tailor_annotation: ^3.1.3
  material_ui: ^1.1.0
```

If pub appended it elsewhere, move the line by hand (`sort_pub_dependencies` fails the gate otherwise).

- [ ] **Step 2: Copy the assets**

Run from the repo root, one command at a time:

```bash
mkdir -p app/assets/lottie
```

```bash
cp Zanshin/lottie/nami_loader.json app/assets/lottie/nami_loader.json
```

```bash
cp Zanshin/lottie/nami_loader_transparent.json app/assets/lottie/nami_loader_transparent.json
```

```bash
cp Zanshin/lottie/README.md app/assets/lottie/README.md
```

`nami_loader_pulse.json` is deliberately not copied. The design export `Zanshin/` stays untouched.

- [ ] **Step 3: Register the two JSON files (never the directory — the README must not be bundled)**

In `app/pubspec.yaml` replace the `flutter:` block with:

```yaml
flutter:
  uses-material-design: true
  assets:
    - assets/icons/svg/
    - assets/lottie/nami_loader.json
    - assets/lottie/nami_loader_transparent.json
```

- [ ] **Step 4: Resolve and verify**

Run in `app/`, one at a time:

```bash
flutter pub get
```

```bash
dart analyze --fatal-infos --fatal-warnings
```

```bash
flutter test
```

Expected: pub resolves without errors; analyze reports "No issues found!"; the two existing test files pass.

- [ ] **Step 5: Commit**

Run from the repo root:

```bash
git add app/pubspec.yaml pubspec.lock app/assets/lottie/nami_loader.json app/assets/lottie/nami_loader_transparent.json app/assets/lottie/README.md
```

```bash
git commit --no-gpg-sign -m "build(app): add lottie and the Nami loader assets

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: `ZanshinBootstrap` — boot sequence, splash colour, immediate swap

**Files:**
- Create: `app/lib/src/features/bootstrap/zanshin_bootstrap.dart`
- Create: `app/test/features/bootstrap/zanshin_bootstrap_test.dart`

**Interfaces:**
- Consumes: `SettingsStore.load(File)` / `.value.appearance.themeMode` (`package:zanshin_settings`), `yaruLight`/`yaruDark` (`package:yaru/yaru.dart`, `ThemeData.scaffoldBackgroundColor`).
- Produces: `ZanshinBootstrap({required Future<SettingsStore> Function() openSettings, required Future<Widget> Function(SettingsStore settings) startApp, Key? key})` exported from `package:zanshin/src/features/bootstrap/zanshin_bootstrap.dart`. Tasks 3–6 extend this file and its test.

- [ ] **Step 1: Write the failing tests**

Create `app/test/features/bootstrap/zanshin_bootstrap_test.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin/src/features/bootstrap/zanshin_bootstrap.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Stands in for the app widget `startApp` returns.
class AppMarker extends StatelessWidget {
  const AppMarker({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

void main() {
  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_bootstrap_test');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  /// A store persisted with [mode]. Real file IO must run outside the widget
  /// test's fake-async zone, hence `runAsync`.
  Future<SettingsStore> storeWith(WidgetTester tester, ThemeMode mode) async {
    final SettingsStore? store = await tester.runAsync(() async {
      await file.writeAsString('{"appearance": {"themeMode": "${mode.name}"}}');
      return SettingsStore.load(file);
    });
    return store!;
  }

  /// Pumps a bootstrap whose two steps complete through [settings] and [app].
  Future<void> pumpBootstrap(
    WidgetTester tester, {
    required Completer<SettingsStore> settings,
    required Completer<Widget> app,
  }) => tester.pumpWidget(
    ZanshinBootstrap(openSettings: () => settings.future, startApp: (_) => app.future),
  );

  /// The splash background; exactly one `ColoredBox` exists while it shows.
  Color splashColor(WidgetTester tester) => tester.widget<ColoredBox>(find.byType(ColoredBox)).color;

  testWidgets('a fast boot swaps to the app as soon as both steps are done', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    expect(find.byType(ColoredBox), findsOneWidget);
    expect(find.byType(AppMarker), findsNothing);

    settings.complete(store);
    await tester.pump();
    app.complete(const AppMarker());
    await tester.pump();

    expect(find.byType(AppMarker), findsOneWidget);
    expect(find.byType(ColoredBox), findsNothing);
  });

  testWidgets('system mode follows the platform brightness before and after the settings are read', (
    tester,
  ) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    expect(splashColor(tester), yaruDark.scaffoldBackgroundColor);

    settings.complete(store);
    await tester.pump();

    expect(splashColor(tester), yaruDark.scaffoldBackgroundColor);

    app.complete(const AppMarker());
    await tester.pump();
  });

  testWidgets('a persisted dark mode overrides a light platform once the settings are read', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final SettingsStore store = await storeWith(tester, ThemeMode.dark);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    expect(splashColor(tester), yaruLight.scaffoldBackgroundColor);

    settings.complete(store);
    await tester.pump();

    expect(splashColor(tester), yaruDark.scaffoldBackgroundColor);

    app.complete(const AppMarker());
    await tester.pump();
  });

  testWidgets('a persisted light mode overrides a dark platform once the settings are read', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    final SettingsStore store = await storeWith(tester, ThemeMode.light);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    expect(splashColor(tester), yaruDark.scaffoldBackgroundColor);

    settings.complete(store);
    await tester.pump();

    expect(splashColor(tester), yaruLight.scaffoldBackgroundColor);

    app.complete(const AppMarker());
    await tester.pump();
  });
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run in `app/`:

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

Expected: compilation error — `package:zanshin/src/features/bootstrap/zanshin_bootstrap.dart` does not exist.

- [ ] **Step 3: Write the widget**

Create `app/lib/src/features/bootstrap/zanshin_bootstrap.dart`:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Root widget of the app: runs the asynchronous boot behind the first frame.
///
/// Paints the app's background colour immediately and swaps to the widget
/// [startApp] returned once both boot steps are done.
class ZanshinBootstrap extends StatefulWidget {
  const ZanshinBootstrap({required this.openSettings, required this.startApp, super.key});

  /// First boot step: the persisted settings, needed by the DI graph and by
  /// the splash colour.
  final Future<SettingsStore> Function() openSettings;

  /// Second boot step: builds the DI graph over the loaded settings, starts
  /// the worker and returns the app widget.
  final Future<Widget> Function(SettingsStore settings) startApp;

  @override
  State<ZanshinBootstrap> createState() => _ZanshinBootstrapState();
}

class _ZanshinBootstrapState extends State<ZanshinBootstrap> {
  /// Persisted theme choice; `system` until [ZanshinBootstrap.openSettings]
  /// answered, which follows the platform brightness either way.
  var _persistedMode = ThemeMode.system;

  /// The finished app.
  Widget? _content;

  var _splashDismissed = false;

  @override
  void initState() {
    super.initState();
    unawaited(_boot());
  }

  Future<void> _boot() async {
    final SettingsStore settings = await widget.openSettings();
    if (!mounted) {
      return;
    }
    setState(() => _persistedMode = settings.value.appearance.themeMode);
    final Widget app = await widget.startApp(settings);
    if (!mounted) {
      return;
    }
    setState(() {
      _content = app;
      _splashDismissed = true;
    });
  }

  @override
  Widget build(BuildContext context) => Directionality(
    // Stack's default alignment is directional, and no MaterialApp exists yet.
    textDirection: TextDirection.ltr,
    child: MediaQuery.fromView(
      // Platform brightness (and later accessibility flags) without a MaterialApp.
      view: View.of(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_content != null) _content!,
          if (!_splashDismissed) IgnorePointer(child: _SplashScreen(mode: _persistedMode)),
        ],
      ),
    ),
  );
}

/// The blank splash: the colour `ZanshinApp`'s scaffold paints first.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.mode});

  final ThemeMode mode;

  @override
  Widget build(BuildContext context) => ColoredBox(color: _scaffoldBackground(_resolveBrightness(context, mode)));
}

/// A persisted light/dark choice wins; `system` follows the platform.
Brightness _resolveBrightness(BuildContext context, ThemeMode mode) => switch (mode) {
  ThemeMode.light => Brightness.light,
  ThemeMode.dark => Brightness.dark,
  ThemeMode.system => MediaQuery.platformBrightnessOf(context),
};

/// The scaffold background of the yaru theme `ZanshinApp` uses for [brightness]
/// (independent of the accent colour, so it matches the real app theme).
Color _scaffoldBackground(Brightness brightness) =>
    (brightness == Brightness.dark ? yaruDark : yaruLight).scaffoldBackgroundColor;
```

- [ ] **Step 4: Run the tests to verify they pass**

Run in `app/`, one at a time:

```bash
dart format lib/src/features/bootstrap test/features/bootstrap
```

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
dart analyze --fatal-infos --fatal-warnings
```

Expected: 4 tests pass; analyze reports "No issues found!". If `dart format` reflowed a line, keep the formatted version.

- [ ] **Step 5: Commit**

Run from the repo root:

```bash
git add app/lib/src/features/bootstrap/zanshin_bootstrap.dart app/test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
git commit --no-gpg-sign -m "feat(app): add ZanshinBootstrap with the blank splash

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Delayed loader, minimum show time, fade-out

**Files:**
- Modify: `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` (whole file replaced below)
- Modify: `app/test/features/bootstrap/zanshin_bootstrap_test.dart`

**Interfaces:**
- Consumes: `Lottie.asset(String, {double? width, double? height, bool? animate, ...})` → `LottieBuilder` (`package:lottie/lottie.dart`); `AnimatedOpacity({required double opacity, required Duration duration, VoidCallback? onEnd, Widget? child})`.
- Produces: the public constants `splashAnimationAsset` (`String`), `splashAnimationSize` (`double`), `splashIndicatorDelay`, `splashIndicatorMinShow`, `splashIndicatorFadeIn`, `splashFadeOut` (all `Duration`), plus the private `_SplashScreen({required ThemeMode mode, required bool showIndicator})` that Task 5 extends.

- [ ] **Step 1: Add the timing tests**

In `app/test/features/bootstrap/zanshin_bootstrap_test.dart` add the import (keep imports sorted):

```dart
import 'package:lottie/lottie.dart';
```

Add this helper after `splashColor`:

```dart
  /// Target opacity of the splash overlay — the outermost `AnimatedOpacity`
  /// (the loader's own fade-in sits inside it).
  double splashTargetOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first).opacity;
```

Extend the fast-boot test: after `expect(find.byType(ColoredBox), findsNothing);` add

```dart
    expect(find.byType(LottieBuilder), findsNothing);
```

Append these tests before the closing `}` of `main`:

```dart
  testWidgets('the loader appears after 500 ms and stays at least 1 s before the app fades in', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    await tester.pump(const Duration(milliseconds: 499));
    expect(find.byType(LottieBuilder), findsNothing);

    await tester.pump(const Duration(milliseconds: 1)); // t = 500 ms
    expect(find.byType(LottieBuilder), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 100)); // t = 600 ms
    app.complete(const AppMarker());
    await tester.pump();
    // The app is built under the still fully opaque splash.
    expect(find.byType(AppMarker), findsOneWidget);
    expect(splashTargetOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 899)); // t = 1499 ms
    expect(splashTargetOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 1)); // t = 1500 ms: minimum over, fade starts
    expect(splashTargetOpacity(tester), 0);
    expect(find.byType(LottieBuilder), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200)); // t = 1700 ms: fade done
    await tester.pump();
    expect(find.byType(ColoredBox), findsNothing);
    expect(find.byType(LottieBuilder), findsNothing);
    expect(find.byType(AppMarker), findsOneWidget);
  });

  testWidgets('a boot that outlasts the minimum show time fades out right away', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    await tester.pump(const Duration(seconds: 3));
    expect(find.byType(LottieBuilder), findsOneWidget);
    expect(splashTargetOpacity(tester), 1);

    app.complete(const AppMarker());
    await tester.pump();
    expect(splashTargetOpacity(tester), 0);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(ColoredBox), findsNothing);
    expect(find.byType(AppMarker), findsOneWidget);
  });

  testWidgets('disposing the bootstrap while booting cancels its timers and drops the late result', (
    tester,
  ) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);
    await tester.pump(const Duration(milliseconds: 600)); // loader shown, minimum-show timer running

    await tester.pumpWidget(const SizedBox());
    app.complete(const AppMarker());
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));

    expect(find.byType(AppMarker), findsNothing);
  });
```

(The dispose test fails today with a pending-timer error only once timers exist; it is the regression guard for `dispose`. A `setState` after dispose would fail it too.)

- [ ] **Step 2: Run the tests to verify the new ones fail**

Run in `app/`:

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

Expected: the two timing tests fail (no `LottieBuilder` / no `AnimatedOpacity` found); the dispose test and the four Task 2 tests pass.

- [ ] **Step 3: Replace the widget file**

Replace the whole content of `app/lib/src/features/bootstrap/zanshin_bootstrap.dart` with:

```dart
// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Loader animation shown while the app boots. Swap for
/// `assets/lottie/nami_loader_transparent.json` to show the waves without the
/// indigo tile (both files are bundled).
const splashAnimationAsset = 'assets/lottie/nami_loader.json';

/// Edge length of the loader animation in logical pixels.
const double splashAnimationSize = 96;

/// How long a boot may take before the loader appears at all.
const splashIndicatorDelay = Duration(milliseconds: 500);

/// Once shown, the loader stays at least this long so it never just blinks.
const splashIndicatorMinShow = Duration(milliseconds: 1000);

/// Fade-in of the loader when [splashIndicatorDelay] elapses.
const splashIndicatorFadeIn = Duration(milliseconds: 150);

/// Fade-out of the whole splash over the finished app.
const splashFadeOut = Duration(milliseconds: 200);

/// Root widget of the app: runs the asynchronous boot behind the first frame.
///
/// Paints the app's background colour immediately, shows the loader only when
/// [openSettings] + [startApp] take longer than [splashIndicatorDelay] (and
/// then for at least [splashIndicatorMinShow]), and finally the widget
/// [startApp] returned.
class ZanshinBootstrap extends StatefulWidget {
  const ZanshinBootstrap({required this.openSettings, required this.startApp, super.key});

  /// First boot step: the persisted settings, needed by the DI graph and by
  /// the splash colour.
  final Future<SettingsStore> Function() openSettings;

  /// Second boot step: builds the DI graph over the loaded settings, starts
  /// the worker and returns the app widget.
  final Future<Widget> Function(SettingsStore settings) startApp;

  @override
  State<ZanshinBootstrap> createState() => _ZanshinBootstrapState();
}

class _ZanshinBootstrapState extends State<ZanshinBootstrap> {
  /// Persisted theme choice; `system` until [ZanshinBootstrap.openSettings]
  /// answered, which follows the platform brightness either way.
  var _persistedMode = ThemeMode.system;

  /// The finished app.
  Widget? _content;

  // Timing is driven by these two timers and the flags below, never by
  // reading a clock, so the fake time of widget tests controls it fully.
  late final Timer _delayTimer;
  Timer? _minShowTimer;

  var _indicatorVisible = false;
  var _minShowElapsed = false;
  var _bootFinished = false;
  var _fadingOut = false;
  var _splashDismissed = false;

  @override
  void initState() {
    super.initState();
    _delayTimer = Timer(splashIndicatorDelay, _showIndicator);
    unawaited(_boot());
  }

  @override
  void dispose() {
    _delayTimer.cancel();
    _minShowTimer?.cancel();
    super.dispose();
  }

  Future<void> _boot() async {
    final SettingsStore settings = await widget.openSettings();
    if (!mounted) {
      return;
    }
    setState(() => _persistedMode = settings.value.appearance.themeMode);
    final Widget app = await widget.startApp(settings);
    if (!mounted) {
      return;
    }
    setState(() {
      _content = app;
      _bootFinished = true;
    });
    _onBootFinished();
  }

  void _showIndicator() {
    setState(() => _indicatorVisible = true);
    _minShowTimer = Timer(splashIndicatorMinShow, _onMinShowElapsed);
  }

  void _onMinShowElapsed() {
    _minShowElapsed = true;
    if (_bootFinished) {
      _startFadeOut();
    }
  }

  void _onBootFinished() {
    if (!_indicatorVisible) {
      // Fast boot: nothing was ever shown, so nothing has to fade.
      _delayTimer.cancel();
      setState(() => _splashDismissed = true);
    } else if (_minShowElapsed) {
      _startFadeOut();
    }
    // Otherwise _onMinShowElapsed starts the fade when the minimum is over.
  }

  void _startFadeOut() => setState(() => _fadingOut = true);

  void _dismissSplash() => setState(() => _splashDismissed = true);

  @override
  Widget build(BuildContext context) => Directionality(
    // Stack's default alignment is directional, and no MaterialApp exists yet.
    textDirection: TextDirection.ltr,
    child: MediaQuery.fromView(
      // Platform brightness and accessibility flags without a MaterialApp.
      view: View.of(context),
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_content != null) _content!,
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
  );
}

/// The splash: the colour `ZanshinApp`'s scaffold paints first, with the
/// loader fading in once [showIndicator] is set.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen({required this.mode, required this.showIndicator});

  final ThemeMode mode;
  final bool showIndicator;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: _scaffoldBackground(_resolveBrightness(context, mode)),
    child: Center(
      child: AnimatedOpacity(
        opacity: showIndicator ? 1 : 0,
        duration: splashIndicatorFadeIn,
        // Only in the tree once needed: a fast boot never loads the asset.
        child: showIndicator
            ? Lottie.asset(splashAnimationAsset, width: splashAnimationSize, height: splashAnimationSize)
            : null,
      ),
    ),
  );
}

/// A persisted light/dark choice wins; `system` follows the platform.
Brightness _resolveBrightness(BuildContext context, ThemeMode mode) => switch (mode) {
  ThemeMode.light => Brightness.light,
  ThemeMode.dark => Brightness.dark,
  ThemeMode.system => MediaQuery.platformBrightnessOf(context),
};

/// The scaffold background of the yaru theme `ZanshinApp` uses for [brightness]
/// (independent of the accent colour, so it matches the real app theme).
Color _scaffoldBackground(Brightness brightness) =>
    (brightness == Brightness.dark ? yaruDark : yaruLight).scaffoldBackgroundColor;
```

`Lottie.asset` loops by default (`repeat` defaults to true), so no `repeat:` argument.

- [ ] **Step 4: Run the tests to verify they pass**

Run in `app/`, one at a time:

```bash
dart format lib/src/features/bootstrap test/features/bootstrap
```

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
dart analyze --fatal-infos --fatal-warnings
```

Expected: 7 tests pass; "No issues found!". If a test reports an uncaught exception from `LottieBuilder` about the asset (it must not — `flutter test` bundles the pubspec assets), check that Task 1 Step 3 registered `assets/lottie/nami_loader.json` and that `flutter pub get` ran.

- [ ] **Step 5: Commit**

Run from the repo root:

```bash
git add app/lib/src/features/bootstrap/zanshin_bootstrap.dart app/test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
git commit --no-gpg-sign -m "feat(app): show the loader after a delay and keep it a minimum time

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: Error page and SEVERE log for a failed boot

**Files:**
- Modify: `app/lib/src/features/bootstrap/zanshin_bootstrap.dart`
- Modify: `app/test/features/bootstrap/zanshin_bootstrap_test.dart`

**Interfaces:**
- Consumes: `Logger` / `LogRecord` / `Level` (`package:logging`), `MaterialApp`, `Scaffold`, `Column`, `Text`, `SelectableText` (`package:material_ui`).
- Produces: `_BootFailure({required Object error, required ThemeMode mode})`; the logger name `zanshin.bootstrap`; the headline text `Zanshin could not start.`.

- [ ] **Step 1: Add the failure test**

In the test file add the import (keep imports sorted):

```dart
import 'package:logging/logging.dart';
```

Append before the closing `}` of `main`:

```dart
  testWidgets('a failed boot shows the error page and logs at SEVERE', (tester) async {
    final records = <LogRecord>[];
    final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
    addTearDown(logs.cancel);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    app.completeError(StateError('worker refused to start'));
    await tester.pump();

    expect(find.text('Zanshin could not start.'), findsOneWidget);
    expect(find.textContaining('worker refused to start'), findsOneWidget);
    expect(find.byType(LottieBuilder), findsNothing);
    expect(
      records,
      contains(
        isA<LogRecord>()
            .having((r) => r.level, 'level', Level.SEVERE)
            .having((r) => r.loggerName, 'loggerName', 'zanshin.bootstrap')
            .having((r) => r.error, 'error', isA<StateError>()),
      ),
    );
  });
```

- [ ] **Step 2: Run the tests to verify the new one fails**

Run in `app/`:

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

Expected: the failure test fails with an unhandled `StateError` ("worker refused to start") thrown out of `_boot`; the other 7 pass.

- [ ] **Step 3: Catch the failure, log it, show `_BootFailure`**

In `app/lib/src/features/bootstrap/zanshin_bootstrap.dart`:

Add the import (keep imports sorted — it goes before `package:lottie/lottie.dart`):

```dart
import 'package:logging/logging.dart';
```

Add after the `splashFadeOut` constant:

```dart
final _log = Logger('zanshin.bootstrap');
```

Replace the `_boot` method with these two methods:

```dart
  Future<void> _boot() async {
    Widget content;
    try {
      content = await _load();
    } catch (error, stackTrace) {
      // Process-level boundary: a failed boot may surface as an Error (FFI,
      // isolate spawn), so this deliberately catches everything.
      _log.severe('App boot failed', error, stackTrace);
      content = _BootFailure(error: error, mode: _persistedMode);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _content = content;
      _bootFinished = true;
    });
    _onBootFinished();
  }

  /// Both boot steps; the persisted mode reaches the splash between them.
  Future<Widget> _load() async {
    final SettingsStore settings = await widget.openSettings();
    if (mounted) {
      setState(() => _persistedMode = settings.value.appearance.themeMode);
    }
    return widget.startApp(settings);
  }
```

Append at the end of the file (after `_scaffoldBackground`):

```dart
/// Shown instead of the app when the boot failed: same background, a headline
/// and the selectable error text. No retry — ⌘Q quits as usual.
class _BootFailure extends StatelessWidget {
  const _BootFailure({required this.error, required this.mode});

  final Object error;
  final ThemeMode mode;

  @override
  Widget build(BuildContext context) => MaterialApp(
    theme: yaruLight,
    darkTheme: yaruDark,
    themeMode: mode,
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            spacing: 12,
            children: [
              const Text('Zanshin could not start.'),
              SelectableText('$error'),
            ],
          ),
        ),
      ),
    ),
  );
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run in `app/`, one at a time:

```bash
dart format lib/src/features/bootstrap test/features/bootstrap
```

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
dart analyze --fatal-infos --fatal-warnings
```

Expected: 8 tests pass; "No issues found!".

- [ ] **Step 5: Commit**

Run from the repo root:

```bash
git add app/lib/src/features/bootstrap/zanshin_bootstrap.dart app/test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
git commit --no-gpg-sign -m "feat(app): show an error page when the boot fails

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: Reduced motion shows the static logo

**Files:**
- Modify: `app/lib/src/features/bootstrap/zanshin_bootstrap.dart`
- Modify: `app/test/features/bootstrap/zanshin_bootstrap_test.dart`

**Interfaces:**
- Consumes: `MediaQuery.disableAnimationsOf(BuildContext)`; `FakeAccessibilityFeatures` and `TestPlatformDispatcher.accessibilityFeaturesTestValue` (`package:flutter_test`).

- [ ] **Step 1: Add the reduced-motion test and the positive control**

In the timeline test of Task 3 (`the loader appears after 500 ms ...`), right after `expect(find.byType(LottieBuilder), findsOneWidget);` at t = 500 ms, add the positive control (it fails until Step 3 because `LottieBuilder.animate` is `null` when the argument is omitted):

```dart
    expect(tester.widget<LottieBuilder>(find.byType(LottieBuilder)).animate, isTrue);
```

Append before the closing `}` of `main` in the test file:

```dart
  testWidgets('with reduced motion the loader shows its first frame without animating', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    await tester.pump(const Duration(milliseconds: 500));
    expect(tester.widget<LottieBuilder>(find.byType(LottieBuilder)).animate, isFalse);

    app.complete(const AppMarker());
    // Minimum show over at 1500 ms; the fade-out then starts with the next
    // frame (an implicit animation ticks from the frame it was started in),
    // so advance 200 ms more before the overlay is gone.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byType(LottieBuilder), findsNothing);
  });
```

- [ ] **Step 2: Run the tests to verify the new checks fail**

Run in `app/`:

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

Expected: the reduced-motion test fails (`animate` is `null`, not `false`) and the timeline test fails at the positive control (`null` is not `true`); the other 7 pass.

- [ ] **Step 3: Pass the accessibility flag to the loader**

In `_SplashScreen.build` replace the `Lottie.asset(...)` call with:

```dart
            ? Lottie.asset(
                splashAnimationAsset,
                width: splashAnimationSize,
                height: splashAnimationSize,
                // "Reduce motion": the first frame is the static logo.
                animate: !MediaQuery.disableAnimationsOf(context),
              )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run in `app/`, one at a time:

```bash
dart format lib/src/features/bootstrap test/features/bootstrap
```

```bash
flutter test test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
dart analyze --fatal-infos --fatal-warnings
```

Expected: 9 tests pass; "No issues found!".

- [ ] **Step 5: Commit**

Run from the repo root:

```bash
git add app/lib/src/features/bootstrap/zanshin_bootstrap.dart app/test/features/bootstrap/zanshin_bootstrap_test.dart
```

```bash
git commit --no-gpg-sign -m "feat(app): respect reduced motion on the splash loader

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Wire `main.dart`, native build check, quality gate

**Files:**
- Modify: `app/lib/main.dart` (the `main` function and a new `_startApp`; `MainComponent` unchanged)

**Interfaces:**
- Consumes: `ZanshinBootstrap` (Task 2), `SettingsStore.open` (static, `Future<SettingsStore> Function()`), `MainComponent.create(settingsModule:)`, `mainComponent.worker`, `mainComponent.zanshinAppFactory.create()`.

- [ ] **Step 1: Move the asynchronous boot out of `main()`**

In `app/lib/main.dart` add the import (relative imports, sorted — after `src/features/app/zanshin_app.dart`, which stays: `MainComponent` still names `ZanshinAppFactory`):

```dart
import 'src/features/bootstrap/zanshin_bootstrap.dart';
```

Replace the `main` function (everything from `Future<void> main() async {` to its closing `}`) with:

```dart
void main() {
  // All initialization inside the same zone as runApp to avoid zone mismatch;
  // the asynchronous boot runs inside ZanshinBootstrap, i.e. in this zone too.
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // The macOS engine does not invoke the generated Dart plugin registrant
      // on its own, so dartPluginClass-based plugins (zanshin_shell_macos)
      // would never register their platform instance. Idempotent.
      DartPluginRegistrant.ensureInitialized();
      SemanticsBinding.instance.ensureSemantics();

      initLogForwarding(level: .ALL);

      FlutterError.onError = (details) {
        forwardLogRecord(
          LogRecord(
            .SEVERE,
            details.exception.toString(),
            details.library ?? 'FlutterError',
            details.exception,
            details.stack,
          ),
        );
        FlutterError.presentError(details);
      };

      // First frame right away; settings, DI graph and worker boot behind it.
      runApp(ZanshinBootstrap(openSettings: SettingsStore.open, startApp: _startApp));
    },
    (error, stackTrace) {
      developer.log(
        'Uncaught zone error: $error',
        stackTrace: stackTrace,
        name: 'zanshin',
      );
    },
  );
}

/// Second boot step: the DI graph over the loaded settings (resolved before
/// the graph so the DI chain stays synchronous — no @asynchronous provider),
/// then the worker, whose provision listener wires the AppLifecycleListener
/// for graceful shutdown on macOS, then the app widget.
Future<Widget> _startApp(SettingsStore settings) async {
  // ignore: specify_nonobvious_local_variable_types
  final mainComponent = MainComponent.create(settingsModule: SettingsModule(store: settings));
  await mainComponent.worker;
  return mainComponent.zanshinAppFactory.create();
}
```

Keep every other line of the file (SPDX header, the other imports, `MainComponent`) as it is. `dart:async` stays imported (`runZonedGuarded`).

- [ ] **Step 2: Analyzer, format, tests**

Run in `app/`, one at a time:

```bash
dart format lib/main.dart
```

```bash
dart analyze --fatal-infos --fatal-warnings
```

```bash
flutter test
```

Expected: "No issues found!"; all app tests pass (the 9 bootstrap tests + the existing two files).

- [ ] **Step 3: Native compile check**

Run in `app/`:

```bash
flutter build macos --debug
```

Expected: the build succeeds (the Dart hook builds the Rust cdylib; the two Lottie assets appear under `build/macos/Build/Products/Debug/Zanshin.app/Contents/Frameworks/App.framework/Resources/flutter_assets/assets/lottie/`). Do not launch the app.

- [ ] **Step 4: The full quality gate**

Run from the repo root (slow — instrumented Rust rebuild and the coverage ratchet at the end; run it unpiped):

```bash
cargo make test
```

Expected: every step passes and `coverage-baseline.txt` is unchanged (`git status` must not list it). If a Dart format or analyze step fails, fix the finding in the new files only and rerun; never touch the baseline.

- [ ] **Step 5: Commit**

Run from the repo root:

```bash
git add app/lib/main.dart
```

```bash
git commit --no-gpg-sign -m "refactor(app): run the boot behind the first frame

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

- [ ] **Step 6: Record the outcome**

Set the spec's status line (`docs/superpowers/specs/2026-09-07-app-bootstrap-splash-design.md`) to `**Status:** implemented 2026-09-07` and note any deviation from this plan as a blockquote under the plan header (as the settings plan did). Commit both docs:

```bash
git add docs/superpowers/specs/2026-09-07-app-bootstrap-splash-design.md docs/superpowers/plans/2026-09-07-app-bootstrap-splash.md
```

```bash
git commit --no-gpg-sign -m "docs(bootstrap): mark the splash design as implemented

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

Hand-off note for Ralph: the visual check (`flutter run -d macos` after `cargo make build`) is his — a normal start should show no loader at all; to see it, temporarily add `await Future<void>.delayed(const Duration(seconds: 3));` at the top of `_startApp`.
