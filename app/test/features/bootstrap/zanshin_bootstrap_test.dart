// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:lottie/lottie.dart';
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

  /// Runs the microtask of a just-completed boot step and draws the frame its
  /// `setState` scheduled (a single pump only flushes the microtask).
  Future<void> pumpStep(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  /// Target opacity of the splash overlay — the outermost `AnimatedOpacity`
  /// (the loader's own fade-in sits inside it).
  double splashTargetOpacity(WidgetTester tester) =>
      tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity).first).opacity;

  testWidgets('a fast boot swaps to the app as soon as both steps are done', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    expect(find.byType(ColoredBox), findsOneWidget);
    expect(find.byType(AppMarker), findsNothing);

    settings.complete(store);
    await pumpStep(tester);
    app.complete(const AppMarker());
    await pumpStep(tester);

    expect(find.byType(AppMarker), findsOneWidget);
    expect(find.byType(ColoredBox), findsNothing);
    expect(find.byType(LottieBuilder), findsNothing);
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
    await pumpStep(tester);

    expect(splashColor(tester), yaruDark.scaffoldBackgroundColor);

    app.complete(const AppMarker());
    await pumpStep(tester);
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
    await pumpStep(tester);

    expect(splashColor(tester), yaruDark.scaffoldBackgroundColor);

    app.complete(const AppMarker());
    await pumpStep(tester);
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
    await pumpStep(tester);

    expect(splashColor(tester), yaruLight.scaffoldBackgroundColor);

    app.complete(const AppMarker());
    await pumpStep(tester);
  });

  testWidgets('the loader appears after 500 ms and stays at least 1 s before the app fades in', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    await tester.pump(const Duration(milliseconds: 499));
    expect(find.byType(LottieBuilder), findsNothing);

    await tester.pump(const Duration(milliseconds: 1)); // t = 500 ms
    expect(find.byType(LottieBuilder), findsOneWidget);
    expect(tester.widget<LottieBuilder>(find.byType(LottieBuilder)).animate, isTrue);

    await tester.pump(const Duration(milliseconds: 100)); // t = 600 ms
    app.complete(const AppMarker());
    await pumpStep(tester);
    // The app is built under the still fully opaque splash.
    expect(find.byType(AppMarker), findsOneWidget);
    expect(splashTargetOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 899)); // t = 1499 ms
    expect(splashTargetOpacity(tester), 1);

    await tester.pump(const Duration(milliseconds: 1)); // t = 1500 ms: minimum over, fade starts
    expect(splashTargetOpacity(tester), 0);
    expect(find.byType(LottieBuilder), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 200)); // t = 1700 ms: fade at its end value
    await tester.pump(const Duration(milliseconds: 1)); // an animation completes on the tick after its duration
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
    await pumpStep(tester);
    expect(splashTargetOpacity(tester), 0);

    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 1));
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

  testWidgets('a failed boot shows the error page and logs at SEVERE', (tester) async {
    final records = <LogRecord>[];
    final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
    addTearDown(logs.cancel);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    await pumpBootstrap(tester, settings: settings, app: app);

    app.completeError(StateError('worker refused to start'));
    await pumpStep(tester);

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
    // Minimum show over at 1500 ms; the fade-out then runs 200 ms and
    // completes on the tick after its duration.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(LottieBuilder), findsNothing);
  });
}
