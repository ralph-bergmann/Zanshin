// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:widgetbook/widgetbook.dart';
import 'package:zanshin/src/app/zanshin_marionette.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../widgetbook/catalogue.dart';
import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

/// The Zs controls with an accessible name of their own; decorations (badge, skeleton, spinner without a label,
/// separators, key caps) report none.
bool _named(Widget widget) => switch (widget) {
  ZsButton() ||
  ZsIconButton() ||
  ZsSwitch() ||
  ZsSegmented() ||
  ZsSlider() ||
  ZsTextField(label: String()) ||
  ZsSearchField() ||
  ZsSelect() ||
  ZsChip() ||
  ZsLink() ||
  ZsDisclosure() ||
  ZsOptionLink() => true,
  _ => false,
};

void main() {
  setUpIconRegistry();
  late RecordingShell shell;
  setUp(() => ZanshinShellPlatform.instance = shell = RecordingShell());
  tearDown(() => shell.close());

  testWidgets('a built-in widget keeps Marionette\'s own recognition', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: GestureDetector(child: const Text('plain')),
      ),
    );
    expect(zanshinMarionetteConfiguration.isElementInteractive(tester.element(find.byType(GestureDetector))), isTrue);
    expect(zanshinMarionetteConfiguration.extractTextFromWidget(tester.element(find.text('plain'))), 'plain');
    expect(zsControlLabel(tester.element(find.text('plain'))), isNull);
  });

  final controls = <String>[
    for (final WidgetbookUseCase useCase in WidgetbookRoot(
      children: catalogueDirectories,
    ).leaves.whereType<WidgetbookUseCase>())
      // ZsPresence only keeps a leaving child mounted; it is a helper, no control.
      if (useCase.path.startsWith('controls/') && !useCase.path.startsWith('controls/presence/')) useCase.path,
  ];

  for (final path in controls) {
    testWidgets('$path: every Zs control is interactive, and the named ones report their label', (tester) async {
      useCatalogueWindow(tester);
      await tester.pumpWidget(catalogueAt('/?path=$path'));
      await tester.pump();
      final List<Element> elements = find.byWidgetPredicate((widget) => widget is ZsControl).evaluate().toList();
      expect(elements, isNotEmpty);
      for (final element in elements) {
        expect(zanshinMarionetteConfiguration.isElementInteractive(element), isTrue, reason: '${element.widget}');
        if (_named(element.widget)) {
          expect(
            zanshinMarionetteConfiguration.extractTextFromWidget(element),
            isNotEmpty,
            reason: '${element.widget} reports its label',
          );
        }
      }
    });
  }

  testWidgets('a container names no control inside it, so a text match reaches that control', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ZsRoot(
          appearance: const ZsAppearance(),
          child: Center(
            child: SizedBox(
              width: 300,
              child: ZsOptionRow(
                label: 'Show bookmarks',
                child: ZsSwitch(value: true, onChanged: (_) {}, label: 'Show bookmarks'),
              ),
            ),
          ),
        ),
      ),
    );
    expect(zanshinMarionetteConfiguration.extractTextFromWidget(tester.element(find.byType(ZsOptionRow))), isNull);
    expect(
      zanshinMarionetteConfiguration.extractTextFromWidget(tester.element(find.byType(ZsSwitch))),
      'Show bookmarks',
    );
  });

  testWidgets('an icon button reports what VoiceOver reads', (tester) async {
    useCatalogueWindow(tester);
    await tester.pumpWidget(catalogueAt('/?path=controls/iconbutton/interactive'));
    await tester.pump();
    expect(
      zanshinMarionetteConfiguration.extractTextFromWidget(tester.element(find.byType(ZsIconButton))),
      'Bookmarks',
    );
  });
}
