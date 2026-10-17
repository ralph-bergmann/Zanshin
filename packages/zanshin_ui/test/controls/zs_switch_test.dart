// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_switch.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

final _pill = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 30, 18), const Radius.circular(9));

RRect _knob(double x, {double width = 12}) =>
    RRect.fromRectAndRadius(Rect.fromLTWH(x, 3, width, 12), const Radius.circular(6));

Widget _switch({
  required bool value,
  ValueChanged<bool>? onChanged,
  ZsAppearance appearance = const ZsAppearance(),
  Set<WidgetState> states = const <WidgetState>{},
  FocusNode? focusNode,
}) {
  final controller = WidgetStatesController(states);
  addTearDown(controller.dispose);
  return zsHost(
    ZsSwitch(
      value: value,
      onChanged: onChanged ?? (_) {},
      label: 'Group stacks',
      statesController: controller,
      focusNode: focusNode,
      identifier: 'switch',
    ),
    appearance: appearance,
  );
}

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('off: --bg-card-2 with a --border-strong edge and a --text-dim knob at 3', (tester) async {
    await tester.pumpWidget(_switch(value: false));
    expect(tester.getSize(find.byType(ZsSwitch)), const Size(30, 18));
    expect(
      find.byType(ZsSwitch),
      paints
        ..something(rrectAt(_pill, color: c.bgCard2))
        ..drrect(outer: _pill, inner: _pill.deflate(1), color: c.borderStrong)
        ..something(rrectAt(_knob(3), color: c.textDim)),
    );
  });

  testWidgets('hover borrows --edge-hov, the knob turns --text-muted', (tester) async {
    await tester.pumpWidget(_switch(value: false, states: <WidgetState>{WidgetState.hovered}));
    expect(
      find.byType(ZsSwitch),
      paints
        ..drrect(color: c.edgeHov)
        ..something(rrectAt(_knob(3), color: c.textMuted)),
    );
  });

  testWidgets('on: --accent with an --accent-line edge and an --accent-ink knob 12 to the right', (tester) async {
    await tester.pumpWidget(_switch(value: true));
    expect(
      find.byType(ZsSwitch),
      paints
        ..something(rrectAt(_pill, color: c.accent))
        ..drrect(color: c.accentLine)
        ..something(rrectAt(_knob(15), color: c.accentInk)),
    );
  });

  testWidgets('on + hover veils the fill with --fill-on-hover; pressed stretches the knob to 15 (on: at 12)', (
    tester,
  ) async {
    await tester.pumpWidget(_switch(value: true, states: <WidgetState>{WidgetState.hovered}));
    expect(find.byType(ZsSwitch), paints..something(rrectAt(_pill.deflate(1), color: c.fillOnHover)));
    await tester.pumpWidget(_switch(value: true, states: <WidgetState>{WidgetState.pressed}));
    await tester.pumpAndSettle();
    expect(find.byType(ZsSwitch), paints..something(rrectAt(_knob(12, width: 15), color: c.accentInk)));
  });

  testWidgets('the knob slides on --dur-toggle; under reduce motion it lands on the next frame', (tester) async {
    await tester.pumpWidget(_switch(value: false));
    await tester.pumpWidget(_switch(value: true));
    await tester.pump();
    await tester.pump(ZsMotion.full.durToggle ~/ 2);
    expect(find.byType(ZsSwitch), isNot(paints..something(rrectAt(_knob(15)))));
    await tester.pump(ZsMotion.full.durToggle);
    expect(find.byType(ZsSwitch), paints..something(rrectAt(_knob(15))));

    const reduced = ZsAppearance(reduceMotion: true);
    await tester.pumpWidget(_switch(value: false, appearance: reduced));
    await tester.pumpAndSettle();
    await tester.pumpWidget(_switch(value: true, appearance: reduced));
    await tester.pump();
    expect(find.byType(ZsSwitch), paints..something(rrectAt(_knob(15))), reason: 'movement is 0');
    expect(
      find.byType(ZsSwitch),
      isNot(paints..something(rrectAt(_pill, color: c.accent))),
      reason: 'the colour still fades on --dur-hover',
    );
  });

  testWidgets('an inactive window shows the neutral accent of the tokens', (tester) async {
    const inactive = ZsAppearance(inactive: true);
    await tester.pumpWidget(_switch(value: true, appearance: inactive));
    expect(find.byType(ZsSwitch), paints..something(rrectAt(_pill, color: ZsColors.resolve(inactive).accent)));
  });

  testWidgets('Space and ↩ toggle; VoiceOver reads a toggled switch named by its label', (tester) async {
    final values = <bool>[];
    final node = FocusNode();
    addTearDown(node.dispose);
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_switch(value: false, onChanged: values.add, focusNode: node));
    node.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(values, <bool>[true, true]);
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('switch')),
      isSemantics(
        identifier: 'switch',
        label: 'Group stacks',
        hasToggledState: true,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        isFocused: true,
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the arrow cursor', (tester) async {
    await tester.pumpWidget(_switch(value: false));
    await hover(tester, find.byType(ZsSwitch));
    expect(activeCursor(), SystemMouseCursors.basic);
  });
}
