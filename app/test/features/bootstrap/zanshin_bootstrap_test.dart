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

  /// Runs the microtask of a just-completed boot step and draws the frame its
  /// `setState` scheduled (a single pump only flushes the microtask).
  Future<void> pumpStep(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

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
}
