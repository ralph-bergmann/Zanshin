// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_checkbox.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _box({
  required bool? value,
  ValueChanged<bool>? onChanged,
  ZsCheckboxSize size = ZsCheckboxSize.md,
  ZsCheckboxTone tone = ZsCheckboxTone.accent,
  ZsAppearance appearance = const ZsAppearance(),
  Set<WidgetState> states = const <WidgetState>{},
  FocusNode? focusNode,
}) {
  final controller = WidgetStatesController(states);
  addTearDown(controller.dispose);
  return zsHost(
    ZsCheckbox(
      value: value,
      tristate: true,
      onChanged: onChanged ?? (_) {},
      label: 'Select hunk',
      size: size,
      tone: tone,
      statesController: controller,
      focusNode: focusNode,
      identifier: 'box',
    ),
    appearance: appearance,
    overlay: true,
  );
}

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;
  final md = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 15, 15), const Radius.circular(4.5));

  testWidgets('rest: a 1.5 px --text-faint edge; hover --text-muted; pressed --fl-on under it', (tester) async {
    await tester.pumpWidget(_box(value: false));
    expect(find.byType(ZsCheckbox), paints..drrect(outer: md, inner: md.deflate(1.5), color: c.textFaint));
    await tester.pumpWidget(_box(value: false, states: <WidgetState>{WidgetState.pressed}));
    await tester.pumpAndSettle();
    expect(
      find.byType(ZsCheckbox),
      paints
        ..rrect(rrect: md, color: c.flOn)
        ..drrect(color: c.textMuted),
    );
  });

  testWidgets('on: --accent, an --accent-line edge and the --accent-ink check; on + hover veils it', (tester) async {
    await tester.pumpWidget(_box(value: true, states: <WidgetState>{WidgetState.hovered}));
    expect(
      find.byType(ZsCheckbox),
      paints
        ..rrect(rrect: md, color: c.accent)
        ..rrect(rrect: md.deflate(1.5), color: c.fillOnHover)
        ..drrect(color: c.accentLine)
        ..path(color: c.accentInk),
    );
  });

  testWidgets('sm is 13 at radius 3.5; the add tone fills --add with an --add-ink mark', (tester) async {
    await tester.pumpWidget(_box(value: true, size: ZsCheckboxSize.sm, tone: ZsCheckboxTone.add));
    expect(tester.getSize(find.byType(ZsCheckbox)), const Size.square(13));
    expect(
      find.byType(ZsCheckbox),
      paints
        ..rrect(
          rrect: RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 13, 13), const Radius.circular(3.5)),
          color: c.add,
        )
        ..path(color: c.addInk),
    );
  });

  testWidgets('the check draws in on --dur-toggle; unchecking clears it at once', (tester) async {
    await tester.pumpWidget(_box(value: false));
    await tester.pumpWidget(_box(value: true));
    await tester.pump();
    expect(find.byType(ZsCheckbox), isNot(paints..path()));
    await tester.pump(ZsMotion.full.durToggle ~/ 2);
    expect(find.byType(ZsCheckbox), paints..path());
    await tester.pump(ZsMotion.full.durToggle);
    await tester.pumpWidget(_box(value: false));
    await tester.pump();
    expect(find.byType(ZsCheckbox), isNot(paints..path()));
  });

  testWidgets('under reduce motion the check is simply there', (tester) async {
    const reduced = ZsAppearance(reduceMotion: true);
    await tester.pumpWidget(_box(value: false, appearance: reduced));
    await tester.pumpWidget(_box(value: true, appearance: reduced));
    await tester.pump();
    expect(find.byType(ZsCheckbox), paints..path(color: c.accentInk));
  });

  testWidgets('a click on a mixed box selects all; Space toggles', (tester) async {
    final values = <bool>[];
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(_box(value: null, onChanged: values.add, focusNode: node));
    await tester.tap(find.byType(ZsCheckbox));
    expect(values, <bool>[true]);
    await tester.pumpWidget(_box(value: true, onChanged: values.add, focusNode: node));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(values, <bool>[true, false]);
  });

  testWidgets('VoiceOver: checked, and mixed when partial', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_box(value: null));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('box')),
      isSemantics(label: 'Select hunk', hasCheckedState: true, isCheckStateMixed: true),
    );
    await tester.pumpWidget(_box(value: true));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('box')),
      isSemantics(hasCheckedState: true, isChecked: true),
    );
    handle.dispose();
  });

  testWidgets('a presentational box takes no pointer and is hidden from VoiceOver', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(zsHost(const ZsCheckbox(value: true, presentational: true, label: 'Viewed')));
    expect(find.bySemanticsLabel('Viewed'), findsNothing);
    await hover(tester, find.byType(ZsCheckbox));
    expect(activeCursor(), SystemMouseCursors.basic);
    handle.dispose();
  });
}
