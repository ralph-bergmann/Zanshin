// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_disclosure.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

Widget _disclosure({
  FocusNode? inside,
  ValueChanged<bool>? onToggle,
  ZsAppearance appearance = const ZsAppearance(),
}) => zsHost(
  SizedBox(
    width: 300,
    child: ZsDisclosure(
      label: 'Conflicts',
      meta: '3',
      onToggle: onToggle,
      identifier: 'disclosure',
      child: Focus(
        focusNode: inside,
        child: const SizedBox(height: 120, child: Text('body')),
      ),
    ),
  ),
  appearance: appearance,
  icons: true,
);

void main() {
  setUpIconRegistry();
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('a click opens the section on --dur-expand; a closed body takes no focus and is hidden', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final inside = FocusNode();
    addTearDown(inside.dispose);
    final toggles = <bool>[];
    await tester.pumpWidget(_disclosure(inside: inside, onToggle: toggles.add));
    expect(tester.getSize(find.byType(ZsDisclosure)).height, 30);
    expect(find.bySemanticsLabel('body'), findsNothing);
    inside.requestFocus();
    await tester.pump();
    expect(inside.hasFocus, isFalse);
    await tester.tap(find.text('Conflicts'));
    await tester.pump();
    await tester.pump(ZsMotion.full.durExpand ~/ 2);
    final double half = tester.getSize(find.byType(ZsDisclosure)).height;
    expect(half, greaterThan(30));
    expect(half, lessThan(150));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ZsDisclosure)).height, 150);
    expect(toggles, <bool>[true]);
    expect(find.bySemanticsLabel('body'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('→ opens, ← closes, Space toggles', (tester) async {
    final toggles = <bool>[];
    await tester.pumpWidget(_disclosure(onToggle: toggles.add));
    Focus.of(tester.element(find.text('Conflicts'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(toggles, <bool>[true, false, true]);
  });

  testWidgets('under reduce motion the height jumps', (tester) async {
    await tester.pumpWidget(_disclosure(appearance: const ZsAppearance(reduceMotion: true)));
    await tester.tap(find.text('Conflicts'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(tester.getSize(find.byType(ZsDisclosure)).height, 150);
  });

  testWidgets('hover is --fl-hover with the label --text', (tester) async {
    await tester.pumpWidget(_disclosure());
    expect(tester.widget<Text>(find.text('Conflicts')).style?.color, c.textMuted);
    await hover(tester, find.text('Conflicts'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('Conflicts')).style?.color, c.text);
    expect(find.byType(ZsDisclosure), paints..something(rrectOf(color: c.flHover)));
  });

  testWidgets('VoiceOver: a button, collapsed then expanded, with its count', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_disclosure());
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('disclosure')),
      isSemantics(label: 'Conflicts', value: '3', isButton: true, hasExpandedState: true, isExpanded: false),
    );
    await tester.tap(find.text('Conflicts'));
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('disclosure')),
      isSemantics(isExpanded: true),
    );
    handle.dispose();
  });
}
