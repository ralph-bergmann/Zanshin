// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_slider.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _slider(
  double value,
  ValueChanged<double> onChanged, {
  FocusNode? node,
  Set<WidgetState> states = const <WidgetState>{},
}) {
  final controller = WidgetStatesController(states);
  addTearDown(controller.dispose);
  return zsHost(
    ZsSlider(
      value: value,
      onChanged: onChanged,
      label: 'Card width',
      unit: 'px',
      focusNode: node,
      statesController: controller,
      identifier: 'slider',
    ),
  );
}

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('Page Up and Down move ten steps, clamped; Home End the ends; arrows one step; all at once', (
    tester,
  ) async {
    double value = 95;
    final node = FocusNode();
    addTearDown(node.dispose);
    Future<void> press(LogicalKeyboardKey key) async {
      await tester.pumpWidget(_slider(value, (v) => value = v, node: node));
      node.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(key);
    }

    await press(LogicalKeyboardKey.pageUp);
    expect(value, 100);
    await press(LogicalKeyboardKey.pageDown);
    expect(value, 90);
    value = 95;
    await press(LogicalKeyboardKey.pageDown);
    expect(value, 85);
    await press(LogicalKeyboardKey.home);
    expect(value, 0);
    await press(LogicalKeyboardKey.end);
    expect(value, 100);
    await press(LogicalKeyboardKey.arrowLeft);
    expect(value, 99);
    await press(LogicalKeyboardKey.arrowUp);
    expect(value, 100);
  });

  testWidgets('a press on the track jumps there at once and the drag follows', (tester) async {
    final values = <double>[];
    double value = 50;
    await tester.pumpWidget(
      zsHost(
        StatefulBuilder(
          builder: (context, setState) => ZsSlider(
            value: value,
            onChanged: (v) => setState(() => values.add(value = v)),
          ),
        ),
      ),
    );
    final Rect track = tester.getRect(find.byType(ZsSlider)).topLeft & const Size(120, 18);
    final TestGesture gesture = await tester.startGesture(Offset(track.left + 7, track.center.dy));
    await tester.pump();
    expect(values.last, 0, reason: 'the thumb centre at the left end');
    await gesture.moveTo(Offset(track.left + 7 + 53, track.center.dy));
    await tester.pump();
    expect(values.last, 50);
    await gesture.moveTo(Offset(track.right, track.center.dy));
    await tester.pump();
    expect(values.last, 100);
    await gesture.up();
  });

  testWidgets('the fill is --accent-line, the rest --track; the readout turns --text while dragging', (tester) async {
    await tester.pumpWidget(_slider(50, (_) {}));
    expect(
      find.byType(ZsSlider),
      paints
        ..something(rrectOf(color: c.track))
        ..something(rrectOf(color: c.accentLine)),
    );
    expect(tester.widget<Text>(find.text('50px')).style?.color, c.textDim);
    await tester.pumpWidget(_slider(50, (_) {}, states: <WidgetState>{WidgetState.pressed}));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('50px')).style?.color, c.text);
    expect(find.byType(ZsSlider), paints..something(circleOf(radius: 12, color: c.accentRing)));
  });

  testWidgets('focus is the ring around the thumb: a transparent --focus-offset gap, then --focus-w', (tester) async {
    await tester.pumpWidget(_slider(0, (_) {}, states: <WidgetState>{WidgetState.focused}));
    // r 7 + edge 1 + gap 2 = 10, the 2 px stroke centred at 11.
    expect(find.byType(ZsSlider), paints..something(circleOf(radius: 11, color: c.focusRing)));
  });

  testWidgets('VoiceOver: a slider with its value and unit, increase and decrease', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_slider(40, (_) {}));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('slider')),
      isSemantics(
        label: 'Card width',
        value: '40px',
        isSlider: true,
        hasIncreaseAction: true,
        hasDecreaseAction: true,
      ),
    );
    handle.dispose();
  });
}
