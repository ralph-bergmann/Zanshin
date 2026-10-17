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

  test('the folders are Controls, Materials, Windows and Icons, and every use case has its own path', () {
    expect(catalogueDirectories.map((node) => node.name), <String>['Controls', 'Materials', 'Windows', 'Icons']);
    expect(paths.toSet(), hasLength(paths.length));
    expect(paths, contains('controls/switch/state-matrix'));
    expect(catalogueUseCasePaths, paths.toSet());
  });

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
