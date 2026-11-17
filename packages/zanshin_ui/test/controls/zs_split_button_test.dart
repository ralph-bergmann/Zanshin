// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_button.dart';
import 'package:zanshin_ui/src/controls/zs_menu.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

const ZsMotion _m = ZsMotion.full;

Widget _host({
  VoidCallback? onSplit,
  VoidCallback? onCommit,
  String? disabledReason,
  ZsSplitButtonSize? size,
  FocusNode? before,
}) => zsHost(
  ColoredBox(
    color: const Color(0x00000000),
    child: SizedBox.expand(
      child: Align(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Focus(focusNode: before, child: const SizedBox.square(dimension: 4)),
            ZsSplitButton(
              label: 'Split',
              variant: ZsButtonVariant.primary,
              size: size ?? ZsSplitButtonSize.md,
              onPressed: onSplit ?? () {},
              disabledReason: disabledReason,
              identifier: 'composer-run',
              entries: <ZsMenuEntry>[
                ZsMenuItem(label: 'Commit', cmd: 'jj commit', onSelected: onCommit),
              ],
            ),
          ],
        ),
      ),
    ),
  ),
  overlay: true,
  icons: true,
);

Finder _part(String identifier) =>
    find.byWidgetPredicate((w) => w is Semantics && w.properties.identifier == identifier);

Future<void> _settleMenu(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(_m.durMenu);
}

void main() {
  setUpIconRegistry();
  useMacFocus();

  testWidgets('a click on the label runs it; the chevron opens the menu below the button', (tester) async {
    var split = 0;
    var commit = 0;
    await tester.pumpWidget(_host(onSplit: () => split++, onCommit: () => commit++));
    await tester.tap(find.text('Split'));
    await tester.pump();
    expect(split, 1);
    expect(find.byType(ZsMenuPanel), findsNothing);

    await tester.tap(_part('composer-run-more'));
    await _settleMenu(tester);
    final Rect button = tester.getRect(find.byType(ZsSplitButton));
    final Rect menu = tester.getRect(find.byType(ZsMenuPanel));
    expect(menu.left, button.left);
    expect(menu.top, button.bottom + 4);
    await tester.tap(find.text('Commit'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(commit, 1);
    expect(split, 1);
  });

  testWidgets('30 high at md, 26 at sm', (tester) async {
    await tester.pumpWidget(_host());
    expect(tester.getSize(find.byType(ZsSplitButton)).height, 30);
    await tester.pumpWidget(_host(size: ZsSplitButtonSize.sm));
    expect(tester.getSize(find.byType(ZsSplitButton)).height, 26);
  });

  testWidgets('Tab reaches the label, then the chevron; Space and Return on the chevron open the menu', (tester) async {
    for (final key in <LogicalKeyboardKey>[LogicalKeyboardKey.space, LogicalKeyboardKey.enter]) {
      var split = 0;
      final before = FocusNode();
      addTearDown(before.dispose);
      await tester.pumpWidget(_host(onSplit: () => split++, before: before));
      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pump();
      expect(split, 1, reason: 'the label has focus first ($key)');
      expect(find.byType(ZsMenuPanel), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.sendKeyEvent(key);
      await _settleMenu(tester);
      expect(split, 1);
      expect(find.text('Commit'), findsOneWidget, reason: '$key');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ZsMenuPanel), findsNothing);
    }
  });

  testWidgets('a disabled label keeps the chevron working', (tester) async {
    var split = 0;
    await tester.pumpWidget(_host(onSplit: () => split++, disabledReason: 'Another action runs'));
    await tester.tap(find.text('Split'), warnIfMissed: false);
    await tester.pump();
    expect(split, 0);
    await tester.tap(_part('composer-run-more'));
    await _settleMenu(tester);
    expect(find.text('Commit'), findsOneWidget);
  });

  testWidgets('VoiceOver: the label is a button named by it, the chevron "More Split actions"', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(_host());
    expect(
      tester.getSemantics(_part('composer-run')),
      matchesSemantics(
        label: 'Split',
        isButton: true,
        isEnabled: true,
        hasEnabledState: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    expect(tester.getSemantics(_part('composer-run-more')).label, 'More Split actions');
    semantics.dispose();
  });
}
