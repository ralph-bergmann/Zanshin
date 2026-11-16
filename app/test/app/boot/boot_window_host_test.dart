// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/app/boot/boot_window_host.dart';
import 'package:zanshin/src/app/menu/app_menu.dart';
import 'package:zanshin/src/features/graph/active_graph.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/projects/projects_search_focus.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart' show ZanshinShellPlatform;

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_window_actions.dart';
import '../../helpers/fake_windows.dart';
import '../../helpers/recording_shell.dart';

const _projectsContent = SizedBox(key: ValueKey<String>('projects content'));
const _projectContent = SizedBox(key: ValueKey<String>('project content'));

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

  testWidgets('Projects first: its request, its content through runWidget, then the project window beside it', (
    tester,
  ) async {
    final factory = FakeWindowFactory();
    final exits = <String>[];
    // The exit is injected because `flutter_test`'s binding throws on a
    // required application exit rather than recording it.
    final windows = AppWindows(createController: factory.call, exitProcess: () async => exits.add('exit'));
    addTearDown(() {
      for (final key in <String>[mainWindowKey, projectsWindowKey]) {
        windows.controllerOf(key)?.destroy();
      }
    });
    final menuCalls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, (call) async {
      menuCalls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, null));
    final host = ZanshinWindowHost(windows: windows);

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
    expect(
      tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar)).menus.map((menu) => (menu as PlatformMenu).label),
      <String>['Zanshin', 'Window'],
      reason: "the boot's menu bar holds the system's items until the model arrives",
    );
    expect(menuCalls.map((call) => call.method), contains('Menu.setMenus'));

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
    expect(exits, isEmpty);
    // The menu bar's system items exist on macOS only.
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

  testWidgets("showMenu hands the menu bar the app's menus in place of the boot's system items", (tester) async {
    final windows = AppWindows(createController: FakeWindowFactory().call, exitProcess: () async {});
    addTearDown(() => windows.controllerOf(projectsWindowKey)?.destroy());
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, (_) async => null);
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.menu, null));
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('boot_window_host_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    final session = ProjectSession(registry: ProjectRegistry(store), repos: FakeProjectRepos());
    addTearDown(session.dispose);
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);
    final graph = ActiveGraph();
    addTearDown(graph.dispose);
    // The menu follows the windows' full screen through the shell.
    final shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final model = AppMenuModel(
      tracker,
      session,
      store,
      graph,
      ProjectsSearchFocus(),
      windows,
      FakeWindowActions(),
      (_) async {},
    );
    addTearDown(model.dispose);
    final host = ZanshinWindowHost(windows: windows);
    await host.openProjects(_projectsContent);
    await tester.pump();
    List<String> labels() => <String>[
      for (final PlatformMenuItem menu in tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar)).menus)
        menu.label,
    ];
    expect(labels(), <String>['Zanshin', 'Window'], reason: "the boot's system items");

    host.showMenu(model);
    await tester.pump();

    expect(labels(), <String>['Zanshin', 'File', 'Edit', 'View', 'Change', 'Go', 'Window', 'Help']);
  }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
}
