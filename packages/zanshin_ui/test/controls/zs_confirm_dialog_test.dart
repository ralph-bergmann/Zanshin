// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_button.dart';
import 'package:zanshin_ui/src/controls/zs_confirm_dialog.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';
import 'package:zanshin_ui/src/materials/zs_sheet.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

/// The calls the dialog made, in order.
final _calls = <String>[];

Widget _dialog({ZsConfirmTone tone = ZsConfirmTone.destructive, bool busy = false}) => zsHost(
  SizedBox.expand(
    child: Stack(
      children: <Widget>[
        ZsConfirmDialog(
          title: 'Clear the operation history?',
          body: const Text('Undo can no longer reach the operations before now.'),
          cmd: 'jj op abandon ..@-',
          confirmLabel: 'Clear history',
          tone: tone,
          busy: busy,
          onConfirm: () => _calls.add('confirm'),
          onCancel: () => _calls.add('cancel'),
          identifier: 'confirm',
        ),
      ],
    ),
  ),
  icons: true,
);

FocusNode _buttonFocus(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.descendant(of: find.widgetWithText(ZsButton, label), matching: find.text(label))));

Future<void> _cmdEnter(WidgetTester tester) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
}

void main() {
  setUpIconRegistry();
  useMacFocus();
  setUp(_calls.clear);
  const ZsColors c = ZsColors.night;

  testWidgets('destructive: 420 wide, focus starts on Cancel, ↩ presses it, ⌘↩ confirms', (tester) async {
    await tester.pumpWidget(_dialog());
    await tester.pump();
    expect(tester.widget<ZsSheet>(find.byType(ZsSheet)).width, 420);
    expect(find.text('⌘↩ confirms'), findsOneWidget);
    expect(_buttonFocus(tester, 'Cancel').hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(_calls, <String>['cancel']);
    await _cmdEnter(tester);
    expect(_calls, <String>['cancel', 'confirm']);
    expect(
      tester.widget<ZsButton>(find.widgetWithText(ZsButton, 'Clear history')).variant,
      ZsButtonVariant.destructive,
    );
  });

  testWidgets('standard: the gold primary has focus and ↩ confirms; ⌘↩ is the destructive key only', (tester) async {
    await tester.pumpWidget(_dialog(tone: ZsConfirmTone.standard));
    await tester.pump();
    expect(_buttonFocus(tester, 'Clear history').hasPrimaryFocus, isTrue);
    expect(find.text('⌘↩ confirms'), findsNothing);
    expect(tester.widget<ZsButton>(find.widgetWithText(ZsButton, 'Clear history')).variant, ZsButtonVariant.primary);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(_calls, <String>['confirm']);
  });

  testWidgets('warn puts the conflict mark in --warn before the title', (tester) async {
    await tester.pumpWidget(_dialog(tone: ZsConfirmTone.warn));
    final ZanshinIcon mark = tester.widget<ZanshinIcon>(find.byType(ZanshinIcon));
    expect(mark.color, c.warn);
  });

  testWidgets('Esc cancels', (tester) async {
    await tester.pumpWidget(_dialog());
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    expect(_calls, <String>['cancel']);
  });

  testWidgets('while busy ⌘↩, ↩, Esc and Cancel do nothing', (tester) async {
    await tester.pumpWidget(_dialog(busy: true));
    await tester.pump();
    await _cmdEnter(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.tap(find.text('Cancel'));
    expect(_calls, isEmpty);
  });

  testWidgets('VoiceOver: the sheet is named by the title', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_dialog());
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Clear the operation history?')),
      isSemantics(label: 'Clear the operation history?', scopesRoute: true, namesRoute: true),
    );
    handle.dispose();
  });
}
