// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:lottie/lottie.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/bootstrap/boot_failure.dart';
import 'package:zanshin/src/features/bootstrap/splash_card.dart';
import 'package:zanshin/src/features/bootstrap/zanshin_bootstrap.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

/// Stands in for the app widget `startApp` returns.
class AppMarker extends StatelessWidget {
  const AppMarker({super.key});

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

/// Records the window calls the sequence makes, in order.
///
/// The real host is the only thing that touches `runWidget` and the macOS
/// window controllers, none of which a widget test can reach — the interface
/// exists so the sequencing can be tested without them.
class FakeBootWindowHost implements BootWindowHost {
  final calls = <String>[];

  /// What [openMain] was handed.
  Widget? content;

  /// What [dismissSplash] was handed.
  Duration? fade;

  @override
  Future<void> openSplash() async => calls.add('splash');

  @override
  Future<void> openMain(Widget content) async {
    this.content = content;
    calls.add('main');
  }

  @override
  Future<void> dismissSplash(Duration fade) async {
    this.fade = fade;
    calls.add('dismiss');
  }
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

  /// Starts a sequence whose two boot steps complete through [settings] and
  /// [app], on an otherwise empty tree.
  Future<FakeBootWindowHost> startSequence(
    WidgetTester tester, {
    required Completer<SettingsStore> settings,
    required Completer<Widget> app,
  }) async {
    await tester.pumpWidget(const SizedBox.shrink());
    final host = FakeBootWindowHost();
    unawaited(
      ZanshinBootSequence(
        host: host,
        openSettings: () => settings.future,
        startApp: (_) => app.future,
      ).run(),
    );
    return host;
  }

  /// Runs the microtasks a just-completed boot step queued, without moving the
  /// fake clock.
  Future<void> flush(WidgetTester tester) async {
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a fast boot opens the main window as the only window', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    expect(host.calls, isEmpty);

    settings.complete(store);
    await flush(tester);
    app.complete(const AppMarker());
    await flush(tester);

    expect(host.calls, <String>['main']);
    expect(host.content, isA<AppMarker>());
  });

  testWidgets('the splash appears after 500 ms and the main window waits out its minimum show', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    await tester.pump(const Duration(milliseconds: 499));
    expect(host.calls, isEmpty);

    await tester.pump(const Duration(milliseconds: 1)); // t = 500 ms
    expect(host.calls, <String>['splash']);

    await tester.pump(const Duration(milliseconds: 100)); // t = 600 ms
    app.complete(const AppMarker());
    await flush(tester);
    // The boot is done, but the splash has not had its second yet.
    expect(host.calls, <String>['splash']);

    await tester.pump(const Duration(milliseconds: 899)); // t = 1499 ms
    expect(host.calls, <String>['splash']);

    await tester.pump(const Duration(milliseconds: 1)); // t = 1500 ms
    await flush(tester);
    expect(host.calls, <String>['splash', 'main', 'dismiss']);
    expect(host.content, isA<AppMarker>());
    expect(host.fade, splashFadeOut);
  });

  testWidgets('a boot that outlasts the minimum show opens the main window right away', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    await tester.pump(const Duration(seconds: 3));
    expect(host.calls, <String>['splash']);

    app.complete(const AppMarker());
    await flush(tester);

    expect(host.calls, <String>['splash', 'main', 'dismiss']);
  });

  testWidgets('a boot that fails before the delay opens the main window with the failure page', (tester) async {
    final records = <LogRecord>[];
    final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
    addTearDown(logs.cancel);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    app.completeError(StateError('worker refused to start'));
    await flush(tester);

    expect(host.calls, <String>['main']);
    expect(host.content, isA<BootFailure>());
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

  testWidgets('a boot that fails after the splash still honours the minimum show', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    await tester.pump(const Duration(milliseconds: 600));
    expect(host.calls, <String>['splash']);

    app.completeError(StateError('worker refused to start'));
    await flush(tester);
    expect(host.calls, <String>['splash']);

    await tester.pump(const Duration(milliseconds: 900)); // t = 1500 ms
    await flush(tester);

    expect(host.calls, <String>['splash', 'main', 'dismiss']);
    expect(host.content, isA<BootFailure>());
  });

  testWidgets('the failure page follows the persisted theme mode', (tester) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.dark);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    app.completeError(StateError('worker refused to start'));
    await flush(tester);

    expect((host.content! as BootFailure).mode, ThemeMode.dark);
  });

  testWidgets('a failure before the settings were read falls back to the system theme', (tester) async {
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    settings.completeError(const FileSystemException('unreadable'));
    await flush(tester);

    expect((host.content! as BootFailure).mode, ThemeMode.system);
  });

  testWidgets('with reduced motion the splash is dismissed without a fade', (tester) async {
    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    await tester.pump(const Duration(seconds: 2));
    app.complete(const AppMarker());
    await flush(tester);

    expect(host.calls, <String>['splash', 'main', 'dismiss']);
    expect(host.fade, Duration.zero);
  });

  testWidgets('the splash card animates the loader, and holds its first frame with reduced motion', (tester) async {
    await tester.pumpWidget(const SplashCard());
    expect(tester.widget<LottieBuilder>(find.byType(LottieBuilder)).animate, isTrue);

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(const SplashCard());

    expect(tester.widget<LottieBuilder>(find.byType(LottieBuilder)).animate, isFalse);
  });

  testWidgets('the failure page shows the headline and the error text', (tester) async {
    await tester.pumpWidget(const BootFailure(error: 'worker refused to start', mode: ThemeMode.system));

    expect(find.text('Zanshin could not start.'), findsOneWidget);
    expect(find.textContaining('worker refused to start'), findsOneWidget);
  });
}
