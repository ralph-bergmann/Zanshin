// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/app_windows.dart';

import '../../helpers/fake_windows.dart';

Widget _nothing(BuildContext context) => const SizedBox.shrink();

const _settings = DialogWindowSpec(
  constraints: BoxConstraints(maxWidth: 620, maxHeight: 740),
  resizable: false,
  frame: WindowFrameMode.position,
);

const _configurations = DialogWindowSpec(
  size: Size(880, 580),
  constraints: BoxConstraints(minWidth: 820, minHeight: 460),
  level: WindowLevel.floatingWhileActive,
);

void main() {
  late bool windowingWasEnabled;

  setUp(() {
    // The machine-global `flutter config --enable-windowing` decides this at
    // compile time; pin it so the test does not depend on the machine.
    windowingWasEnabled = isWindowingEnabled;
    isWindowingEnabled = true;
  });

  tearDown(() {
    isWindowingEnabled = windowingWasEnabled;
  });

  /// A registry, the windows over it, their factory and the log of process exits, with every window destroyed again
  /// when the test ends.
  (WindowRegistry, AppWindows, FakeWindowFactory, List<String>) newWindows() {
    final registry = WindowRegistry();
    final exits = <String>[];
    final factory = FakeWindowFactory();
    // The exit is injected because `flutter_test`'s binding throws on a
    // required application exit rather than recording it.
    final windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'))
      ..attach(registry);
    addTearDown(() {
      for (final WindowEntry entry in registry.windows) {
        entry.controller.destroy();
      }
    });
    return (registry, windows, factory, exits);
  }

  testWidgets("a project window created without constraints gets the project window's minimum, 880 × 560", (
    tester,
  ) async {
    final (_, AppWindows windows, FakeWindowFactory factory, _) = newWindows();
    windows.register(await windows.create(key: mainWindowKey, title: 'Zanshin', builder: _nothing));

    expect(defaultWindowConstraints, const BoxConstraints(minWidth: 880, minHeight: 560));
    expect(factory.requests.single.constraints, defaultWindowConstraints);
    expect(factory.requests.single.size, defaultWindowSize);
    expect(factory.requests.single.dialog, isNull);
  });

  testWidgets('each dialog controller receives exactly the constraints it passed, never the project window minimum', (
    tester,
  ) async {
    final (WindowRegistry registry, AppWindows windows, FakeWindowFactory factory, _) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: projectsWindowTitle,
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    await windows.openOrActivate(key: settingsWindowKey, title: 'General', builder: _nothing, dialog: _settings);
    await windows.openOrActivate(
      key: revsetConfigsWindowKey,
      title: 'jj log Configurations',
      builder: _nothing,
      dialog: _configurations,
    );

    expect(
      factory.requests.map((request) => request.constraints),
      <BoxConstraints>[
        defaultWindowConstraints,
        const BoxConstraints(minWidth: 680, minHeight: 440),
        const BoxConstraints(maxWidth: 620, maxHeight: 740),
        const BoxConstraints(minWidth: 820, minHeight: 460),
      ],
    );
    expect(factory.requests.map((request) => request.size), <Size?>[
      defaultWindowSize,
      const Size(900, 640),
      null,
      const Size(880, 580),
    ]);
    expect(registry.windows.first.controller, isA<WindowController>());
    expect(registry.windows.skip(1).map((entry) => entry.controller), everyElement(isA<DialogWindowController>()));
    expect(projectsWindowSpec.size, const Size(900, 640));
    expect(projectsWindowSpec.resizable, isTrue);
    expect(projectsWindowSpec.frame, WindowFrameMode.full);
    expect(projectsWindowSpec.level, WindowLevel.normal);
    expect(projectsWindowSpec.keepsAppAlive, isTrue);
  });

  testWidgets('a dialog window takes its size and constraints from its spec only', (tester) async {
    final (_, AppWindows windows, _, _) = newWindows();

    await expectLater(
      windows.create(
        key: settingsWindowKey,
        title: 'General',
        builder: _nothing,
        size: const Size(1, 1),
        dialog: _settings,
      ),
      throwsArgumentError,
    );
    await expectLater(
      windows.create(
        key: settingsWindowKey,
        title: 'General',
        builder: _nothing,
        constraints: const BoxConstraints(),
        dialog: _settings,
      ),
      throwsArgumentError,
    );
  });

  testWidgets('a window sized to its content takes no minimum: its first, empty view would be refused', (tester) async {
    final (_, AppWindows windows, FakeWindowFactory factory, _) = newWindows();

    await expectLater(
      windows.create(
        key: settingsWindowKey,
        title: 'General',
        builder: _nothing,
        dialog: const DialogWindowSpec(constraints: BoxConstraints(minWidth: 620, maxWidth: 620, maxHeight: 740)),
      ),
      throwsArgumentError,
    );
    expect(factory.requests, isEmpty);
    expect(windows.isOpen(settingsWindowKey), isFalse);
  });

  testWidgets('openOrActivate registers a new window', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _, _) = newWindows();

    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );

    expect(registry.windows, hasLength(1));
    expect(windows.isOpen(projectsWindowKey), isTrue);
    expect(windows.controllerOf(projectsWindowKey), isA<DialogWindowController>());
  });

  testWidgets('a second open of the same key activates the window instead of creating another', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _, _) = newWindows();
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    await windows.openOrActivate(key: settingsWindowKey, title: 'General', builder: _nothing, dialog: _settings);
    final projects = windows.controllerOf(projectsWindowKey)! as DialogWindowController;

    // The window created last is the active one.
    expect(projects.isActivated, isFalse);

    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );

    expect(registry.windows, hasLength(2));
    expect(projects.isActivated, isTrue);
  });

  testWidgets('two opens of one key at once make one window', (tester) async {
    final (WindowRegistry registry, AppWindows windows, FakeWindowFactory factory, _) = newWindows();

    await Future.wait(<Future<void>>[
      windows.openOrActivate(key: projectsWindowKey, title: 'Projects', builder: _nothing, dialog: projectsWindowSpec),
      windows.openOrActivate(key: projectsWindowKey, title: 'Projects', builder: _nothing, dialog: projectsWindowSpec),
    ]);

    expect(factory.requests, hasLength(1));
    expect(registry.windows, hasLength(1));
  });

  testWidgets('a destroyed window unregisters itself and its key opens again', (tester) async {
    final (WindowRegistry registry, AppWindows windows, FakeWindowFactory factory, _) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );

    windows.controllerOf(projectsWindowKey)!.destroy();

    expect(registry.windows, hasLength(1));
    expect(windows.isOpen(projectsWindowKey), isFalse);

    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );

    expect(registry.windows, hasLength(2));
    expect(factory.requests, hasLength(3));
  });

  testWidgets('close destroys the window of a key; a key that is not open is left alone', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _, _) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(key: settingsWindowKey, title: 'General', builder: _nothing, dialog: _settings);

    windows
      ..close(settingsWindowKey)
      ..close(revsetConfigsWindowKey);

    expect(registry.windows, hasLength(1));
    expect(windows.isOpen(settingsWindowKey), isFalse);
  });

  testWidgets("a close request runs the key's handler instead of destroying; without one the window goes", (
    tester,
  ) async {
    final (WindowRegistry registry, AppWindows windows, FakeWindowFactory factory, _) = newWindows();
    var requests = 0;
    windows.setCloseHandler(mainWindowKey, () async => requests++);
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    final BaseWindowController main = windows.controllerOf(mainWindowKey)!;
    final BaseWindowController projects = windows.controllerOf(projectsWindowKey)!;

    factory.requestClose(main);
    await tester.pump();

    expect(requests, 1);
    expect(windows.isOpen(mainWindowKey), isTrue);

    windows.setCloseHandler(mainWindowKey, null);
    factory.requestClose(main);
    expect(windows.isOpen(mainWindowKey), isFalse);

    factory.requestClose(projects);
    expect(windows.isOpen(projectsWindowKey), isFalse);
    expect(registry.windows, isEmpty);
  });

  testWidgets('the close guards are asked in order and the first refusal wins; a removed guard is not asked', (
    tester,
  ) async {
    final (_, AppWindows windows, _, _) = newWindows();
    final asked = <String>[];
    expect(await windows.mayClose(), isTrue, reason: 'no guard');

    final VoidCallback removeFirst = windows.addCloseGuard(() async {
      asked.add('first');
      return true;
    });
    windows
      ..addCloseGuard(() async {
        asked.add('second');
        return false;
      })
      ..addCloseGuard(() async {
        asked.add('third');
        return true;
      });

    expect(await windows.mayClose(), isFalse);
    expect(asked, <String>['first', 'second']);

    removeFirst();
    asked.clear();
    expect(await windows.mayClose(), isFalse);
    expect(asked, <String>['second']);
  });

  testWidgets('the process exits when no window that keeps the app alive is left', (tester) async {
    final (_, AppWindows windows, _, List<String> exits) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(key: settingsWindowKey, title: 'General', builder: _nothing, dialog: _settings);
    await windows.openOrActivate(
      key: revsetConfigsWindowKey,
      title: 'jj log Configurations',
      builder: _nothing,
      dialog: _configurations,
    );

    windows
      ..close(settingsWindowKey)
      ..close(revsetConfigsWindowKey);
    expect(exits, isEmpty, reason: 'Settings and Configurations close; the project window keeps the app alive');

    await windows.openOrActivate(key: settingsWindowKey, title: 'General', builder: _nothing, dialog: _settings);
    windows.close(mainWindowKey);

    expect(exits, <String>['exit'], reason: 'Settings alone does not keep the app alive');
  });

  testWidgets('closing Projects with no project window exits, even with Settings open; with one it does not', (
    tester,
  ) async {
    final (_, AppWindows windows, _, List<String> exits) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );

    windows.close(projectsWindowKey);
    expect(exits, isEmpty);

    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    await windows.openOrActivate(key: settingsWindowKey, title: 'General', builder: _nothing, dialog: _settings);
    windows.close(mainWindowKey);
    expect(exits, isEmpty, reason: 'Projects keeps the app alive');

    windows.close(projectsWindowKey);
    expect(exits, <String>['exit']);
  });

  testWidgets('opening Projects before the project window goes never counts zero lifelines', (tester) async {
    final (_, AppWindows windows, _, List<String> exits) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);

    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    windows.close(mainWindowKey);

    expect(exits, isEmpty);
  });

  testWidgets('a project window still being created keeps the app alive when Projects closes', (tester) async {
    final (WindowRegistry registry, AppWindows windows, FakeWindowFactory factory, List<String> exits) = newWindows();
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    final Completer<void> gate = factory.gate = Completer<void>();
    final Future<void> opening = windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await tester.pump();
    expect(windows.isOpen(mainWindowKey), isTrue, reason: 'on its way');

    windows.close(projectsWindowKey);
    expect(exits, isEmpty, reason: 'the project window on its way counts');

    gate.complete();
    await opening;

    expect(registry.windows.single.controller, same(windows.controllerOf(mainWindowKey)));
    expect(exits, isEmpty);
  });

  testWidgets('a window unregistered twice (destroy called again) unregisters once', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _, List<String> exits) = newWindows();
    await windows.openOrActivate(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );
    windows.controllerOf(projectsWindowKey)!
      ..destroy()
      ..destroy();

    expect(registry.windows, hasLength(1));
    expect(exits, isEmpty);
  });

  testWidgets('create leaves the window out of the registry until it is registered', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _, _) = newWindows();

    final WindowEntry entry = await windows.create(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    expect(registry.windows, isEmpty);

    windows.register(entry);

    expect(registry.windows, <WindowEntry>[entry]);
  });

  testWidgets('create refuses a key that is already open', (tester) async {
    final (WindowRegistry _, AppWindows windows, _, _) = newWindows();
    await windows.openOrActivate(
      key: projectsWindowKey,
      title: 'Projects',
      builder: _nothing,
      dialog: projectsWindowSpec,
    );

    await expectLater(
      windows.create(key: projectsWindowKey, title: 'Projects', builder: _nothing, dialog: projectsWindowSpec),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('register and unregister fail loudly while no registry is captured', (tester) async {
    // No attach(): a dropped capture() must not silently leave a native window
    // unrendered, nor silently skip the exit rule.
    final factory = FakeWindowFactory();
    final windows = AppWindows(createController: factory.call, exitProcess: () async {});
    final WindowEntry entry = await windows.create(key: mainWindowKey, title: 'Zanshin', builder: _nothing);
    var attached = false;
    windows.attached.then((_) => attached = true).ignore();
    await tester.pump();
    expect(attached, isFalse);

    expect(() => windows.register(entry), throwsA(isA<StateError>()));
    expect(() => windows.unregister(entry), throwsA(isA<StateError>()));

    // Tidy up the stand-in controller; its destroy path needs a registry.
    windows.attach(WindowRegistry());
    await tester.pump();
    expect(attached, isTrue, reason: 'attached completes with the first registry');
    entry.controller.destroy();
  });
}
