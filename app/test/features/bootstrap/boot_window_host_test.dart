// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/bootstrap/boot_window_host.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show IconRegistry, IconRegistryScope;

import '../../helpers/fake_windows.dart';
import '../../helpers/icon_registry.dart';

const _projectsContent = SizedBox(key: ValueKey<String>('projects content'));
const _projectContent = SizedBox(key: ValueKey<String>('project content'));

void main() {
  setUpIconRegistry();
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

  testWidgets('Projects first: its request, its content through runWidget, then the project window beside it', (
    tester,
  ) async {
    final factory = FakeWindowFactory();
    final exits = <String>[];
    // The exit is injected because `flutter_test`'s binding throws on a
    // required application exit rather than recording it.
    final windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'));
    final icons = ValueNotifier<IconRegistry?>(null);
    addTearDown(icons.dispose);
    addTearDown(() {
      for (final key in <String>[mainWindowKey, projectsWindowKey]) {
        windows.controllerOf(key)?.destroy();
      }
    });
    final host = ZanshinWindowHost(windows: windows, icons: icons);

    await host.openProjects(_projectsContent);

    final AppWindowRequest request = factory.requests.single;
    expect(request.key, projectsWindowKey);
    expect(request.title, 'Projects');
    // The spec's plan is pinned in app_windows_test.dart; the host's part is handing over this spec.
    expect(request.dialog, same(projectsWindowSpec));

    await tester.pump();
    expect(find.byKey(_projectsContent.key!), findsOneWidget, reason: 'the first window is the one runWidget got');
    final WindowRegistry registry = WindowRegistry.of(tester.element(find.byKey(_projectsContent.key!)));
    expect(registry.windows.single.controller, same(windows.controllerOf(projectsWindowKey)));
    expect(IconRegistryScope.maybeOf(tester.element(find.byKey(_projectsContent.key!))), isNull, reason: 'not loaded');

    await host.openMain(_projectContent);
    await tester.pump();

    expect(factory.requests.map((request) => request.key), <String>[projectsWindowKey, mainWindowKey]);
    expect(factory.requests.last.title, mainWindowTitle);
    expect(factory.requests.last.dialog, isNull);
    expect(
      registry.windows.map((entry) => entry.controller),
      <BaseWindowController?>[windows.controllerOf(projectsWindowKey), windows.controllerOf(mainWindowKey)],
      reason: 'the later window goes through the registry, beside the first',
    );
    expect(find.byKey(_projectContent.key!), findsOneWidget);
    expect(find.byKey(_projectsContent.key!), findsOneWidget);

    // The icons arrive through the listenable; every window sees them once they are there.
    icons.value = testIconRegistry;
    await tester.pump();
    for (final content in <Finder>[find.byKey(_projectsContent.key!), find.byKey(_projectContent.key!)]) {
      expect(IconRegistryScope.maybeOf(tester.element(content)), same(testIconRegistry));
    }
    expect(exits, isEmpty);
  });
}
