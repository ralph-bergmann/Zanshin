// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/app/boot/boot_module.dart';
import 'package:zanshin/src/app/boot/zanshin_bootstrap.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';

/// Records what the boot reports, in [events] — shared with the test's seams, so one list shows the order.
class _Progress implements BootProgress {
  _Progress(this.events);

  final List<String> events;

  @override
  ThemeMode persistedTheme = ThemeMode.system;

  @override
  void log(String message) => events.add(message);
}

/// A worker that is only handed on; nothing of it is reached.
class _Worker implements ZanshinWorker {
  @override
  Object? noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  setUpIconRegistry();
  late Directory dir;

  setUp(() async => dir = await Directory.systemTemp.createTemp('boot_module_test'));

  tearDown(() => dir.delete(recursive: true));

  Future<SettingsStore> storeWith(ThemeMode mode) async {
    final file = File('${dir.path}/settings.json');
    await file.writeAsString('{"appearance": {"themeMode": "${mode.name}"}}');
    return SettingsStore.load(file);
  }

  test('a shell slower than the settings: its line shows, and the worker starts last, after the icons', () async {
    final SettingsStore store = await storeWith(ThemeMode.dark);
    final settings = Completer<SettingsStore>();
    final shell = Completer<void>();
    final icons = Completer<IconRegistry>();
    final worker = _Worker();
    final events = <String>[];
    final progress = _Progress(events);

    final Future<BootValues> values = loadBootValues(
      progress,
      openSettings: () {
        events.add('settings');
        return settings.future;
      },
      adoptShellEnvironment: () {
        events.add('shell');
        return shell.future;
      },
      loadIcons: () {
        events.add('icons');
        return icons.future;
      },
      startWorker: () async {
        events.add('worker');
        return worker;
      },
    );
    expect(events, <String>['Loading settings…', 'shell', 'icons', 'settings'], reason: 'all three start at once');

    settings.complete(store);
    await pumpEventQueue();
    expect(progress.persistedTheme, ThemeMode.dark, reason: 'reported as soon as the settings are read');
    expect(events.last, 'Reading the shell environment…', reason: 'the worker waits for the shell environment');

    shell.complete();
    await pumpEventQueue();
    expect(events.last, 'Reading the shell environment…', reason: 'the worker waits for the icons');

    icons.complete(testIconRegistry);
    final BootValues boot = await values;

    expect(events, <String>[
      'Loading settings…',
      'shell',
      'icons',
      'settings',
      'Reading the shell environment…',
      'Starting Zanshin…',
      'worker',
    ]);
    expect(boot.settings, same(store));
    expect(boot.icons, same(testIconRegistry));
    expect(boot.worker, same(worker));
  });

  test('a shell done before the settings shows no shell line', () async {
    final SettingsStore store = await storeWith(ThemeMode.system);
    final settings = Completer<SettingsStore>();
    final events = <String>[];

    final Future<BootValues> values = loadBootValues(
      _Progress(events),
      openSettings: () => settings.future,
      adoptShellEnvironment: () async {},
      loadIcons: () async => testIconRegistry,
      startWorker: () async => _Worker(),
    );
    await pumpEventQueue();
    settings.complete(store);
    await values;

    expect(events, <String>['Loading settings…', 'Starting Zanshin…']);
  });

  for (final (String step, bool shellFails) in const <(String, bool)>[
    ('a failed shell environment adoption', true),
    ('icons that fail to load', false),
  ]) {
    test('$step fails the boot: the worker never starts, the theme was reported', () async {
      final SettingsStore store = await storeWith(ThemeMode.dark);
      final settings = Completer<SettingsStore>();
      final progress = _Progress(<String>[]);
      var workerStarted = false;

      final Future<BootValues> values = loadBootValues(
        progress,
        openSettings: () => settings.future,
        adoptShellEnvironment: () async {
          if (shellFails) {
            throw StateError('the shell environment broke');
          }
        },
        loadIcons: () async {
          if (!shellFails) {
            throw StateError('an icon would not decode');
          }
          return testIconRegistry;
        },
        startWorker: () async {
          workerStarted = true;
          return _Worker();
        },
      );
      // The failure lands while the settings still load: it must not count as unhandled (that would fail this test),
      // only fail the boot once awaited.
      await pumpEventQueue();
      settings.complete(store);

      await expectLater(values, throwsA(isA<StateError>()));
      expect(workerStarted, isFalse);
      expect(progress.persistedTheme, ThemeMode.dark);
    });
  }

  test('a settings failure fails the boot: the worker never starts, the theme stays system, the steps still under way '
      'fail unheard', () async {
    final shell = Completer<void>();
    final icons = Completer<IconRegistry>();
    final progress = _Progress(<String>[]);
    var workerStarted = false;

    final Future<BootValues> values = loadBootValues(
      progress,
      openSettings: () async => throw const FileSystemException('unreadable'),
      adoptShellEnvironment: () => shell.future,
      loadIcons: () => icons.future,
      startWorker: () async {
        workerStarted = true;
        return _Worker();
      },
    );

    await expectLater(values, throwsA(isA<FileSystemException>()));
    // The shell and the icons fail after the boot did: that must not count as unhandled (it would fail this test).
    shell.completeError(StateError('the shell environment broke'));
    icons.completeError(StateError('an icon would not decode'));
    await pumpEventQueue();

    expect(workerStarted, isFalse);
    expect(progress.persistedTheme, ThemeMode.system);
  });

  test('a worker that fails to start fails the boot after the theme and the last line were reported', () async {
    final SettingsStore store = await storeWith(ThemeMode.dark);
    final events = <String>[];
    final progress = _Progress(events);

    final Future<BootValues> values = loadBootValues(
      progress,
      openSettings: () async => store,
      adoptShellEnvironment: () async {},
      loadIcons: () async => testIconRegistry,
      startWorker: () async => throw StateError('the worker refused to start'),
    );

    await expectLater(values, throwsA(isA<StateError>()));
    expect(progress.persistedTheme, ThemeMode.dark);
    expect(events.last, 'Starting Zanshin…');
  });
}
