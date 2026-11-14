// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_button.dart';
import 'package:zanshin_ui/src/controls/zs_menu.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

const ZsMotion _m = ZsMotion.full;

Widget _host({required FocusNode focus, String? disabledReason, VoidCallback? onSquash}) => zsHost(
  ColoredBox(
    color: const Color(0x00000000),
    child: SizedBox.expand(
      child: Align(
        child: ZsMenuButton(
          label: 'Squash',
          focusNode: focus,
          disabledReason: disabledReason,
          identifier: 'squash-menu',
          entries: <ZsMenuEntry>[
            ZsMenuItem(label: 'Squash into parent', cmd: 'jj squash -r abc', onSelected: onSquash),
            const ZsMenuItem(label: 'Absorb into ancestors', cmd: 'jj absorb --from abc'),
          ],
        ),
      ),
    ),
  ),
  overlay: true,
  icons: true,
);

Finder get _chevron => find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.chevronDown);

void main() {
  setUpIconRegistry();
  useMacFocus();

  late FocusNode focus;
  setUp(() => focus = FocusNode(debugLabel: 'menu button'));
  tearDown(() => focus.dispose());

  testWidgets('the chevron follows the label 5 apart and ends 8 before the edge, at 12', (tester) async {
    await tester.pumpWidget(_host(focus: focus));
    final Rect button = tester.getRect(find.byType(ZsMenuButton));
    final Rect label = tester.getRect(find.text('Squash'));
    final Rect chevron = tester.getRect(_chevron);
    expect(chevron.size, const Size(12, 12));
    expect(chevron.left - label.right, 5);
    expect(button.right - chevron.right, 8);
    expect(label.left - button.left, 12);
  });

  testWidgets('a click opens the menu 4 below the left edge; a row runs and closes it', (tester) async {
    var ran = 0;
    await tester.pumpWidget(_host(focus: focus, onSquash: () => ran++));
    await tester.tap(find.text('Squash'));
    await tester.pump();
    await tester.pump(_m.durMenu);
    final Rect button = tester.getRect(find.byType(ZsMenuButton));
    final Rect menu = tester.getRect(find.byType(ZsMenuPanel));
    expect(menu.left, button.left);
    expect(menu.top, button.bottom + 4);
    expect(find.text('jj absorb --from abc'), findsOneWidget);
    await tester.tap(find.text('Squash into parent'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(ran, 1);
    // The exit fade ends.
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.byType(ZsMenuPanel), findsNothing);
  });

  testWidgets('Space and Return open it from the keyboard', (tester) async {
    for (final key in <LogicalKeyboardKey>[LogicalKeyboardKey.space, LogicalKeyboardKey.enter]) {
      await tester.pumpWidget(_host(focus: focus));
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(_m.durMenu);
      expect(find.text('Absorb into ancestors'), findsOneWidget, reason: '$key');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ZsMenuPanel), findsNothing);
    }
  });

  testWidgets('icon-only: the glyph and the chevron 2 apart, 26 high, the label its name and tooltip', (tester) async {
    Widget host({required bool active, String? disabledReason}) => zsHost(
      Center(
        child: ZsMenuButton(
          label: 'Diff options',
          icon: ZI.viewOptions,
          iconOnly: true,
          active: active,
          disabledReason: disabledReason,
          variant: ZsButtonVariant.ghost,
          entries: const <ZsMenuEntry>[ZsMenuItem(label: 'Ignore all whitespace', checked: false, radio: true)],
        ),
      ),
      overlay: true,
      icons: true,
    );
    await tester.pumpWidget(host(active: false));
    final Finder glyph = find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.viewOptions);
    final Rect button = tester.getRect(find.byType(ZsMenuButton));
    expect(button.height, 26);
    expect(tester.getRect(glyph).size, const Size(14, 14));
    expect(tester.getRect(_chevron).left - tester.getRect(glyph).right, 2);
    expect(tester.getRect(glyph).left - button.left, 6);
    expect(button.right - tester.getRect(_chevron).right, 5);
    expect(find.text('Diff options'), findsNothing);
    expect(find.byWidgetPredicate((w) => w is ZsTooltip && w.message == 'Diff options'), findsOneWidget);
    expect(find.bySemanticsLabel('Diff options'), findsOneWidget);
    final Color rest = tester.widget<ZanshinIcon>(glyph).color!;

    await tester.pumpWidget(host(active: true));
    await tester.pumpAndSettle();
    final Color accent = tester.widget<ZanshinIcon>(glyph).color!;
    expect(accent, isNot(rest));
    expect(accent, ZsColors.of(tester.element(glyph)).accent);

    // Disabled, an active glyph keeps the button's ink, not the accent.
    await tester.pumpWidget(host(active: true, disabledReason: 'Another action runs'));
    await tester.pumpAndSettle();
    expect(tester.widget<ZanshinIcon>(glyph).color, isNot(accent));
    await tester.pumpWidget(host(active: true));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(ZsMenuButton));
    await tester.pump();
    await tester.pump(_m.durMenu);
    expect(find.text('Ignore all whitespace'), findsOneWidget);
  });

  testWidgets('a disabled reason disables it and is its tooltip', (tester) async {
    await tester.pumpWidget(_host(focus: focus, disabledReason: 'Another action runs'));
    expect(find.byWidgetPredicate((w) => w is ZsTooltip && w.message == 'Another action runs'), findsOneWidget);
    await tester.tap(find.text('Squash'), warnIfMissed: false);
    await tester.pump();
    await tester.pump(_m.durMenu);
    expect(find.byType(ZsMenuPanel), findsNothing);
  });
}
