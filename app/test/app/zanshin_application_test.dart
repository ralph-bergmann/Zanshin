// SPDX-License-Identifier: MIT

import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart' show MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/app/boot/zanshin_bootstrap.dart';
import 'package:zanshin/src/app/zanshin_application.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/remembered_window_controller.dart' show windowFramesChannel;
import 'package:zanshin/src/features/window/zanshin_window_root.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';
import '../helpers/test_component.dart';

void main() {
  setUpIconRegistry();
  setUpTestWorker();

  testWidgets(
    'start binds the stored zoom, mirrors the theme once, answers ⌘Q through the close guards once and returns the '
    "coordinator's first window",
    (tester) async {
      final shell = RecordingShell();
      ZanshinShellPlatform.instance = shell;
      addTearDown(shell.close);
      final TestComponent graph = await testComponent(
        tester,
        settingsJson: '{"appearance": {"zoom": 125, "themeMode": "dark"}}',
      );
      final ZanshinApplication app = graph.application;
      addTearDown(graph.tracker.dispose);
      addTearDown(app.menu.dispose);
      addTearDown(() => windowFramesChannel.setMethodCallHandler(null));
      var asked = 0;
      graph.windows.addCloseGuard(() async {
        asked++;
        return false;
      });
      List<String> appearances() => <String>[
        for (final String call in shell.calls)
          if (call.startsWith('setWindowAppearance')) call,
      ];

      final fonts = <String>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('zanshin/fonts'), (
        call,
      ) async {
        fonts.add(call.method);
        return null;
      });
      addTearDown(
        () =>
            tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('zanshin/fonts'), null),
      );

      final BootFirstWindow first = app.start();

      expect(fonts, <String>['monospacedFamilies'], reason: 'the code fonts are read at start');
      expect(graph.windows.zoom, 1.25, reason: 'the first window is created at the stored zoom');
      expect(appearances(), <String>['setWindowAppearance:dark']);
      expect(first.kind, BootWindowKind.projects, reason: 'nothing stored to reopen');
      final Widget root = (first.content as AppWindowActionsScope).child;
      expect((first.content as AppWindowActionsScope).actions, same(graph.coordinator));
      expect(root, isA<ZanshinWindowRoot>().having((root) => root.windowKey, 'windowKey', projectsWindowKey));
      expect((root as ZanshinWindowRoot).child, isA<ProjectsWindow>());

      expect(await tester.binding.handleRequestAppExit(), AppExitResponse.cancel, reason: 'the guard refuses');
      expect(asked, 1, reason: 'one exit listener');

      await tester.runAsync(() => graph.settings.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light)));
      expect(appearances(), <String>['setWindowAppearance:dark', 'setWindowAppearance:light'], reason: 'one mirror');
      await tester.runAsync(() => graph.settings.update((s) => s.copyWith.appearance(zoom: 100)));
      expect(graph.windows.zoom, 1, reason: 'the zoom stays bound');
    },
  );
}
