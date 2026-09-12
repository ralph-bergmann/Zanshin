// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/bootstrap/boot_failure.dart';
import 'package:zanshin/src/features/bootstrap/splash_card.dart';
import 'package:zanshin/src/features/bootstrap/splash_card_render.dart';
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
  FakeBootWindowHost({this.failOnOpenMain = false});

  /// Stands in for a window layer that cannot open a window at all.
  final bool failOnOpenMain;

  final calls = <String>[];

  /// What [openMain] was handed.
  Widget? content;

  /// What [dismissSplash] was handed.
  Duration? fade;

  /// The listenables the splash card would have been built with.
  ValueListenable<String>? status;
  ValueListenable<SplashVersion?>? version;

  @override
  Future<void> openSplash({
    required ValueListenable<String> status,
    required ValueListenable<SplashVersion?> version,
  }) async {
    this.status = status;
    this.version = version;
    calls.add('splash');
  }

  @override
  Future<void> openMain(Widget content) async {
    this.content = content;
    calls.add('main');
    if (failOnOpenMain) {
      throw StateError('the engine refused the window');
    }
  }

  @override
  Future<void> dismissSplash(Duration fade) async {
    this.fade = fade;
    calls.add('dismiss');
  }
}

/// One fake-clock tick, for the timing tests' off-by-one edges.
const _tick = Duration(milliseconds: 1);

// The design grid the footer is asserted against; see `SPLASH-SPEC.md` § 1.
const double _cardPadding = 36;
const double _statusRight = 524;
const double _footerBaseline = 276;

/// Where a line carrying [span] has to start so that its alphabetic baseline
/// lands on the footer baseline.
double _topForBaseline(InlineSpan span) {
  final painter = TextPainter(text: span, textDirection: TextDirection.ltr)..layout();
  final double top = _footerBaseline - painter.computeDistanceToActualBaseline(TextBaseline.alphabetic);
  painter.dispose();
  return top;
}

String _statusText(WidgetTester tester) =>
    (tester.widget<RichText>(find.byKey(splashStatusKey)).text as TextSpan).text ?? '';

/// Pumps a [SplashCard] on a surface the size of the card, so the assertions
/// can be written in the design's own coordinates.
Future<void> _pumpCard(WidgetTester tester, {required String status, required SplashVersion? version}) {
  final statusNotifier = ValueNotifier<String>(status);
  addTearDown(statusNotifier.dispose);
  final versionNotifier = ValueNotifier<SplashVersion?>(version);
  addTearDown(versionNotifier.dispose);
  return _pumpCardWith(tester, status: statusNotifier, version: versionNotifier);
}

Future<void> _pumpCardWith(
  WidgetTester tester, {
  required ValueListenable<String> status,
  required ValueListenable<SplashVersion?> version,
}) async {
  tester.view
    ..physicalSize = splashWindowSize
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(SplashCard(status: status, version: version));
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

  testWidgets('the splash appears after the indicator delay and the main window waits out its minimum show', (
    tester,
  ) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>()..complete(store);
    final app = Completer<Widget>();
    final FakeBootWindowHost host = await startSequence(tester, settings: settings, app: app);

    await tester.pump(splashIndicatorDelay - _tick);
    expect(host.calls, isEmpty);

    await tester.pump(_tick); // t = delay
    expect(host.calls, <String>['splash']);

    await tester.pump(const Duration(milliseconds: 100));
    app.complete(const AppMarker());
    await flush(tester);
    // The boot is done, but the splash has not had its minimum yet.
    expect(host.calls, <String>['splash']);

    await tester.pump(splashIndicatorMinShow - const Duration(milliseconds: 101));
    expect(host.calls, <String>['splash']);

    await tester.pump(_tick); // t = delay + minShow
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

    await tester.pump(splashIndicatorDelay + splashIndicatorMinShow + _tick);
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

    await tester.pump(splashIndicatorDelay + const Duration(milliseconds: 100));
    expect(host.calls, <String>['splash']);

    app.completeError(StateError('worker refused to start'));
    await flush(tester);
    expect(host.calls, <String>['splash']);

    await tester.pump(splashIndicatorMinShow - const Duration(milliseconds: 100));
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

    await tester.pump(splashIndicatorDelay + splashIndicatorMinShow + _tick);
    app.complete(const AppMarker());
    await flush(tester);

    expect(host.calls, <String>['splash', 'main', 'dismiss']);
    expect(host.fade, Duration.zero);
  });

  testWidgets('a host that cannot open a window logs at SEVERE and still finishes the boot', (tester) async {
    final records = <LogRecord>[];
    final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
    addTearDown(logs.cancel);
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final app = Completer<Widget>();
    await tester.pumpWidget(const SizedBox.shrink());
    final host = FakeBootWindowHost(failOnOpenMain: true);
    var finished = false;
    unawaited(
      ZanshinBootSequence(
        host: host,
        openSettings: () async => store,
        startApp: (_) => app.future,
      ).run().then((_) => finished = true),
    );

    app.complete(const AppMarker());
    await flush(tester);

    // `main` awaits run(); a host error must not leave it hanging with no
    // window and — AppKit no longer quitting on the last one — no way out.
    expect(host.calls, <String>['main']);
    expect(finished, isTrue);
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

  testWidgets('the boot steps show up in the splash status line, and a failure leaves the last one standing', (
    tester,
  ) async {
    final SettingsStore store = await storeWith(tester, ThemeMode.system);
    final settings = Completer<SettingsStore>();
    final app = Completer<Widget>();
    await tester.pumpWidget(const SizedBox.shrink());
    final host = FakeBootWindowHost();
    final sequence = ZanshinBootSequence(
      host: host,
      openSettings: () => settings.future,
      startApp: (_) => app.future,
    );
    final seen = <String>[];
    sequence.status.addListener(() => seen.add(sequence.status.value));

    unawaited(sequence.run());
    settings.complete(store);
    await flush(tester);
    app.completeError(StateError('worker refused to start'));
    await flush(tester);

    expect(seen, <String>['lade Settings…', 'starte App…']);
    expect(sequence.status.value, 'starte App…');
  });

  testWidgets('the splash card lays its footer out on the design grid', (tester) async {
    await _pumpCard(tester, status: 'lade Settings…', version: (version: '2026.9.1', build: '1'));

    expect(tester.getSize(find.byType(SplashCardBody)), splashWindowSize);
    expect(tester.getTopLeft(find.byKey(splashVersionKey)).dx, _cardPadding);
    expect(tester.getTopRight(find.byKey(splashStatusKey)).dx, _statusRight);
    expect(
      tester.getTopLeft(find.byKey(splashVersionKey)).dy,
      closeTo(_topForBaseline(const TextSpan(text: '2026.9.1 · Build 1', style: splashVersionStyle)), 0.01),
    );
    expect(
      tester.getTopLeft(find.byKey(splashStatusKey)).dy,
      closeTo(_topForBaseline(const TextSpan(text: 'lade Settings…', style: splashStatusStyle)), 0.01),
    );
  });

  testWidgets('the status line follows its listenable and stays right-aligned', (tester) async {
    final status = ValueNotifier<String>('lade Settings…');
    addTearDown(status.dispose);
    final version = ValueNotifier<SplashVersion?>(null);
    addTearDown(version.dispose);
    await _pumpCardWith(tester, status: status, version: version);

    status.value = 'starte App…';
    await tester.pump();

    expect(_statusText(tester), 'starte App…');
    expect(tester.getTopRight(find.byKey(splashStatusKey)).dx, _statusRight);
  });

  testWidgets('an empty status and an unknown version still paint the card', (tester) async {
    await _pumpCard(tester, status: '', version: null);

    expect(tester.takeException(), isNull);
    expect(_statusText(tester), isEmpty);
    expect(tester.getSize(find.byKey(splashStatusKey)).width, 0);
    expect(tester.getTopRight(find.byKey(splashStatusKey)).dx, _statusRight);
    expect(tester.getSize(find.byKey(splashVersionKey)).width, 0);
  });

  testWidgets('the splash card runs a ticker, and schedules nothing at all with reduced motion', (tester) async {
    await _pumpCard(tester, status: 'lade Settings…', version: null);
    expect(SchedulerBinding.instance.transientCallbackCount, 1);

    tester.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await tester.pumpWidget(const SizedBox.shrink());
    await _pumpCard(tester, status: 'lade Settings…', version: null);

    expect(SchedulerBinding.instance.transientCallbackCount, 0);
  });

  testWidgets('the failure page shows the headline and the error text', (tester) async {
    await tester.pumpWidget(const BootFailure(error: 'worker refused to start', mode: ThemeMode.system));

    expect(find.text('Zanshin could not start.'), findsOneWidget);
    expect(find.textContaining('worker refused to start'), findsOneWidget);
  });
}
