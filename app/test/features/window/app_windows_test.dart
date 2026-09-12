// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/app_windows.dart';

/// Stands in for `RememberedWindowController.create`, which needs the engine:
/// the generic controller `flutter_test`'s windowing owner provides is enough
/// to exercise the registry bookkeeping.
Future<WindowController> fakeController({
  required String key,
  required String title,
  required Size size,
  required BoxConstraints constraints,
  required WindowControllerDelegate delegate,
  required bool chrome,
}) async => WindowController(size: size, constraints: constraints, title: title, delegate: delegate);

Widget _nothing(BuildContext context) => const SizedBox.shrink();

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

  /// A registry, the windows over it and the log of process exits, with every
  /// window destroyed again when the test ends.
  (WindowRegistry, AppWindows, List<String>) newWindows() {
    final registry = WindowRegistry();
    final exits = <String>[];
    addTearDown(() {
      for (final WindowEntry entry in registry.windows) {
        entry.controller.destroy();
      }
    });
    // The exit is injected because `flutter_test`'s binding throws on a
    // required application exit rather than recording it.
    final windows = AppWindows(createController: fakeController, exitProcess: () async => exits.add('exit'))
      ..attach(registry);
    return (registry, windows, exits);
  }

  testWidgets('openOrActivate registers a new window', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _) = newWindows();

    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);

    expect(registry.windows, hasLength(1));
  });

  testWidgets('a second open of the same key activates the window instead of creating another', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _) = newWindows();
    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(key: 'project:/tmp/a', title: 'a', builder: _nothing);
    final main = registry.windows.first.controller as WindowController;

    // The window created last is the active one.
    expect(main.isActivated, isFalse);

    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);

    expect(registry.windows, hasLength(2));
    expect(main.isActivated, isTrue);
  });

  testWidgets('a destroyed window unregisters itself', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _) = newWindows();
    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(key: 'project:/tmp/a', title: 'a', builder: _nothing);

    registry.windows.first.controller.destroy();

    expect(registry.windows, hasLength(1));
  });

  testWidgets('a key freed by a destroyed window can be opened again', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _) = newWindows();
    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);
    registry.windows.single.controller.destroy();

    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);

    expect(registry.windows, hasLength(1));
  });

  testWidgets('closing the last window ends the process', (tester) async {
    final (WindowRegistry registry, AppWindows windows, List<String> exits) = newWindows();
    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);
    await windows.openOrActivate(key: 'project:/tmp/a', title: 'a', builder: _nothing);

    registry.windows.first.controller.destroy();
    expect(exits, isEmpty);

    registry.windows.single.controller.destroy();

    expect(exits, <String>['exit']);
  });

  testWidgets('create leaves the window out of the registry until it is registered', (tester) async {
    final (WindowRegistry registry, AppWindows windows, _) = newWindows();

    final WindowEntry entry = await windows.create(key: 'main', title: 'Zanshin', builder: _nothing);
    expect(registry.windows, isEmpty);

    windows.register(entry);

    expect(registry.windows, <WindowEntry>[entry]);
  });

  testWidgets('create refuses a key that is already open', (tester) async {
    final (WindowRegistry _, AppWindows windows, _) = newWindows();
    await windows.openOrActivate(key: 'main', title: 'Zanshin', builder: _nothing);

    await expectLater(
      windows.create(key: 'main', title: 'Zanshin', builder: _nothing),
      throwsA(isA<StateError>()),
    );
  });

  testWidgets('register and unregister fail loudly while no registry is captured', (tester) async {
    // No attach(): a dropped capture() must not silently leave a native window
    // unrendered, nor silently skip the exit-when-empty rule.
    final windows = AppWindows(createController: fakeController, exitProcess: () async {});
    final WindowEntry entry = await windows.create(key: 'main', title: 'Zanshin', builder: _nothing);

    expect(() => windows.register(entry), throwsA(isA<StateError>()));
    expect(() => windows.unregister(entry), throwsA(isA<StateError>()));

    // Tidy up the stand-in controller; its destroy path needs a registry.
    windows.attach(WindowRegistry());
    entry.controller.destroy();
  });
}
