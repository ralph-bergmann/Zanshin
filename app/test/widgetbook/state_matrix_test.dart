// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import '../../widgetbook/folders/controls.dart';
import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

void main() {
  setUpIconRegistry();
  setUp(() => ZanshinShellPlatform.instance = RecordingShell());

  testWidgets('a matrix fits its state columns into the use-case area, so none hides behind a scroll', (tester) async {
    // Ralph's catalogue window (2238 pt wide): the checkbox matrix has seven state columns.
    tester.view
      ..physicalSize = const Size(2238, 1400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(catalogueAt('/?path=controls/checkbox/state-matrix'));
    await tester.pump();
    final Finder viewport = find.descendant(
      of: find.byType(StateMatrix),
      matching: find.byWidgetPredicate(
        (widget) => widget is SingleChildScrollView && widget.scrollDirection == Axis.horizontal,
      ),
    );
    expect(tester.getRect(find.text('DISABLED')).right, lessThanOrEqualTo(tester.getRect(viewport).right));
  });

  testWidgets('the tooltip matrix shows one bubble open, without a hover', (tester) async {
    useCatalogueWindow(tester);
    await tester.pumpWidget(catalogueAt('/?path=controls/tooltip/state-matrix'));
    await tester.pump();
    await tester.pumpAndSettle();
    // The jj command shows only in the bubble.
    expect(find.text('jj git fetch'), findsOneWidget);
  });
}
