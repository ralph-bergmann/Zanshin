// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../widgetbook/catalogue.dart';
import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

void main() {
  setUpIconRegistry();
  late RecordingShell shell;
  setUp(() => ZanshinShellPlatform.instance = shell = RecordingShell());
  tearDown(() => shell.close());

  final paths = <String>[
    for (final WidgetbookUseCase useCase in WidgetbookRoot(
      children: catalogueDirectories,
    ).leaves.whereType<WidgetbookUseCase>())
      useCase.path,
  ];

  test(
    'the folders are Controls, Materials, Shell, Projects, Windows, Icons and Graph, and every use case has its own path',
    () {
      expect(
        catalogueDirectories.map((node) => node.name),
        <String>['Controls', 'Materials', 'Shell', 'Projects', 'Windows', 'Icons', 'Graph'],
      );
      expect(paths.toSet(), hasLength(paths.length));
      expect(paths, contains('controls/switch/state-matrix'));
      expect(
        paths,
        containsAll(<String>[
          'shell/floating-shell/layout',
          'shell/floating-shell/preview-open',
          'shell/floating-shell/pinned-panel',
          'shell/floating-shell/flyout',
          'shell/floating-shell/calm',
          'shell/floating-shell/slots',
          'projects/project-capsule/states',
          'projects/project-capsule/menu-open',
          'controls/resize-edge/state-matrix',
          'materials/island/fade',
          'materials/canvas/window-canvas',
          'windows/floating-shell/floating-shell',
          'projects/projects-window/tree',
          'projects/projects-window/search',
          'projects/projects-window/no-results',
          'projects/projects-window/empty',
          'projects/projects-window/narrow',
          'projects/projects-window/convert-offer',
          'projects/projects-window/clone-form',
          'projects/projects-window/drop-hint',
          'projects/projects-window/no-identity',
          'windows/projects-window/projects-window',
          'windows/window-fill/window-fill',
          'windows/window-scaffold/resizable',
          'windows/window-scaffold/content-sized',
          'windows/window-scaffold/floating',
          'graph/viewport/recording',
          'graph/viewport/scale',
        ]),
      );
      expect(catalogueUseCasePaths, paths.toSet());
    },
  );

  for (final path in paths) {
    for (final ZsTheme theme in ZsTheme.values) {
      testWidgets('$path builds in ${theme.name}', (tester) async {
        useCatalogueWindow(tester);
        await tester.pumpWidget(catalogueAt('/?path=$path&appearance={theme:${theme.name}}'));
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(canvasOf(theme), findsWidgets, reason: 'the use case shows under the Appearance addon');
      });
    }

    testWidgets('$path builds with every system flag and the inactive window', (tester) async {
      useCatalogueWindow(tester);
      await tester.pumpWidget(
        catalogueAt(
          '/?path=$path&appearance={accent:green,contrast:true,reduceMotion:true,reduceTransparency:true,'
          'inactive:true}',
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}
