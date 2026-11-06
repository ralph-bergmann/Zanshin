// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_resize_edge.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

/// What an edge reported.
class _Log {
  final changes = <double>[];
  final ends = <double>[];
  final events = <String>[];
}

/// A panel edge (side right, 240–440, default 300) at [start] inside a 200 px high strip, its value following
/// [ZsResizeEdge.onChanged].
Widget _edge(
  _Log log, {
  double start = 300,
  double max = 440,
  ZsResizeSide side = ZsResizeSide.right,
  bool inert = false,
  ZsAppearance appearance = const ZsAppearance(),
  FocusNode? before,
}) {
  var value = start;
  return zsHost(
    StatefulBuilder(
      builder: (context, setState) => Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (before != null) Focus(focusNode: before, child: const SizedBox.square(dimension: 10)),
          SizedBox(
            height: 200,
            child: ZsResizeEdge(
              side: side,
              value: value,
              min: 240,
              max: max,
              defaultValue: 300,
              label: 'Panel width',
              identifier: 'edge',
              inert: inert,
              onChanged: (v) => setState(() => log.changes.add(value = v)),
              onChangeEnd: log.ends.add,
              onDragStart: () => log.events.add('start'),
              onDragEnd: () => log.events.add('end'),
            ),
          ),
        ],
      ),
    ),
    appearance: appearance,
    overlay: true,
  );
}

Finder get _strip => find.byType(ZsResizeEdge);

/// Whether the edge's line paints in `--edge-hov` (any opacity above 0).
PaintPattern _line(ZsColors colors) => paints
  ..something((method, arguments) {
    if (method != #drawRRect) {
      return false;
    }
    final Color color = (arguments[1] as Paint).color;
    return color.a > 0 && (color.r - colors.edgeHov.r).abs() < 1e-3 && (color.g - colors.edgeHov.g).abs() < 1e-3;
  });

Future<void> _pumpMs(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

/// Pumps [edge] built with a focusable box before it, focuses that box and tabs onto the edge.
Future<void> _tabTo(WidgetTester tester, Widget Function(FocusNode before) edge) async {
  final before = FocusNode();
  addTearDown(before.dispose);
  await tester.pumpWidget(edge(before));
  before.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.tab);
  await tester.pump();
}

/// Lets a pending double-tap wait run out, so no timer outlives the test.
Future<void> _settleTaps(WidgetTester tester) => tester.pump(const Duration(milliseconds: 500));

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('a drag follows the pointer with no tween, clamps, and reports the end once after release', (
    tester,
  ) async {
    final log = _Log();
    await tester.pumpWidget(_edge(log));
    expect(tester.getSize(_strip), const Size(10, 200));
    final TestGesture drag = await tester.startGesture(tester.getCenter(_strip), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(25, 0));
    await tester.pump();
    expect(log.events, <String>['start']);
    expect(log.changes.last, 325);
    await drag.moveBy(const Offset(400, 0));
    await tester.pump();
    expect(log.changes.last, 440, reason: 'clamped to the maximum');
    await drag.moveBy(const Offset(-900, 0));
    await tester.pump();
    expect(log.changes.last, 240, reason: 'clamped to the minimum');
    expect(log.ends, isEmpty, reason: 'nothing is committed during the drag');
    await drag.up();
    await tester.pump();
    expect(log.ends, <double>[240]);
    expect(log.events, <String>['start', 'end']);
    await _settleTaps(tester);
  });

  testWidgets('under a window zoom of 1.25 a 50 px drag changes the width by 40 (Story 11.20)', (tester) async {
    final log = _Log();
    await tester.pumpWidget(Transform.scale(scale: 1.25, alignment: Alignment.topLeft, child: _edge(log)));
    final TestGesture drag = await tester.startGesture(tester.getCenter(_strip), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(50, 0));
    await tester.pump();
    expect(log.changes.last, 340);
    await drag.up();
    await tester.pump();
    await _settleTaps(tester);
  });

  testWidgets('an edge removed mid-drag still ends the drag and commits the width (Story 10.8 I3)', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_edge(log));
    final TestGesture drag = await tester.startGesture(tester.getCenter(_strip), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(25, 0));
    await tester.pump();
    expect(log.events, <String>['start']);
    await tester.pumpWidget(zsHost(const SizedBox(), overlay: true));
    await tester.pump();
    expect(log.events, <String>['start', 'end']);
    expect(log.ends, <double>[325]);
    await drag.up();
    await tester.pump();
    expect(log.events, <String>['start', 'end'], reason: 'the release after removal reports nothing');
    await _settleTaps(tester);
  });

  testWidgets('a drag back to its start, a drag held at a limit and a key against a limit commit nothing', (
    tester,
  ) async {
    final log = _Log();
    await tester.pumpWidget(_edge(log));
    TestGesture drag = await tester.startGesture(tester.getCenter(_strip), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(20, 0));
    await tester.pump();
    await drag.moveBy(const Offset(-20, 0));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(log.changes, <double>[320, 300]);
    expect(log.ends, isEmpty, reason: 'it ended where it started');
    await _settleTaps(tester);

    final held = _Log();
    await tester.pumpWidget(_edge(held, start: 280, max: 280));
    drag = await tester.startGesture(tester.getCenter(_strip), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(held.changes, isEmpty);
    expect(held.ends, isEmpty, reason: "a drag held at the limit must not store the limit as the user's width");
    await _settleTaps(tester);

    final keys = _Log();
    await _tabTo(tester, (before) => _edge(keys, start: 280, max: 280, before: before));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(keys.changes, isEmpty);
    expect(keys.ends, isEmpty);
  });

  testWidgets('a reset goes to the default even past the limit: the host limits what shows', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_edge(log, start: 260, max: 280, appearance: const ZsAppearance(reduceMotion: true)));
    await tester.tap(_strip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_strip);
    await tester.pump();
    expect(log.changes, <double>[300]);
    expect(log.ends, <double>[300]);
    await _settleTaps(tester);
  });

  testWidgets('the left side widens to the left', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_edge(log, side: ZsResizeSide.left));
    final TestGesture drag = await tester.startGesture(tester.getCenter(_strip), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(-30, 0));
    await tester.pump();
    expect(log.changes.last, 330);
    await drag.up();
    await _settleTaps(tester);
  });

  testWidgets('the cursor is resizeColumn, one-way at the limits, and holds over the whole window while dragging', (
    tester,
  ) async {
    for (final (double start, ZsResizeSide side, MouseCursor cursor) in <(double, ZsResizeSide, MouseCursor)>[
      (300, ZsResizeSide.right, SystemMouseCursors.resizeColumn),
      (240, ZsResizeSide.right, SystemMouseCursors.resizeRight),
      (440, ZsResizeSide.right, SystemMouseCursors.resizeLeft),
      (240, ZsResizeSide.left, SystemMouseCursors.resizeLeft),
      (440, ZsResizeSide.left, SystemMouseCursors.resizeRight),
    ]) {
      await tester.pumpWidget(_edge(_Log(), start: start, side: side));
      final TestGesture mouse = await hover(tester, _strip);
      expect(activeCursor(), cursor, reason: '$start on the ${side.name}');
      await mouse.removePointer();
      await tester.pumpWidget(const SizedBox.shrink());
    }

    await tester.pumpWidget(_edge(_Log()));
    final TestGesture drag = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await drag.addPointer(location: tester.getCenter(_strip));
    addTearDown(drag.removePointer);
    await tester.pump();
    await drag.down(tester.getCenter(_strip));
    await drag.moveBy(const Offset(20, 0));
    await tester.pump();
    await drag.moveTo(Offset(tester.getCenter(_strip).dx + 20, 5));
    await tester.pump();
    expect(activeCursor(), SystemMouseCursors.resizeColumn, reason: 'held far from the strip');
    await drag.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(activeCursor(), SystemMouseCursors.resizeRight, reason: 'clamped at the minimum');
    await drag.up();
    await tester.pump();
    expect(activeCursor(), isNot(SystemMouseCursors.resizeRight));
    await _settleTaps(tester);
  });

  testWidgets('a double-click resets to the default over --dur-expand; under reduce motion it jumps', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_edge(log, start: 400));
    await tester.tap(_strip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_strip);
    await tester.pump();
    await _pumpMs(tester, 100);
    expect(log.changes.last, allOf(greaterThan(300), lessThan(400)));
    expect(log.ends, isEmpty);
    await _pumpMs(tester, 120);
    expect(log.changes.last, 300);
    expect(log.ends, <double>[300]);

    final reduced = _Log();
    await tester.pumpWidget(_edge(reduced, start: 400, appearance: const ZsAppearance(reduceMotion: true)));
    await tester.tap(_strip);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_strip);
    await tester.pump();
    expect(reduced.changes, <double>[300]);
    expect(reduced.ends, <double>[300]);
    await _settleTaps(tester);
  });

  testWidgets('keys: arrows by 10, with shift by 50, Home and End, Return the default; each step is committed', (
    tester,
  ) async {
    final log = _Log();
    await _tabTo(tester, (before) => _edge(log, before: before));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(log.changes.last, 310);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    expect(log.changes.last, 300);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(log.changes.last, 350);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(log.changes.last, 440);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(log.changes.last, 240);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(log.changes.last, 300);
    expect(log.ends, <double>[310, 300, 350, 440, 240, 300]);

    final left = _Log();
    await _tabTo(tester, (before) => _edge(left, side: ZsResizeSide.left, before: before));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    expect(left.changes.last, 290, reason: 'on the left side → narrows: the edge follows the arrow');
  });

  testWidgets('keyboard focus draws the ring outside the strip', (tester) async {
    await _tabTo(tester, (before) => _edge(_Log(), before: before));
    await tester.pumpAndSettle();
    expect(_strip, paints..something(ringOf(color: c.focusRing)));
  });

  testWidgets('the line shows 150 ms into a hover, at once while dragging, never inert or in an inactive window', (
    tester,
  ) async {
    await tester.pumpWidget(_edge(_Log()));
    final TestGesture mouse = await hover(tester, _strip);
    await _pumpMs(tester, 149);
    expect(_strip, isNot(_line(c)));
    await _pumpMs(tester, 1);
    await _pumpMs(tester, 120);
    expect(_strip, _line(c));
    await mouse.moveTo(Offset.zero);
    await tester.pumpAndSettle();
    expect(_strip, isNot(_line(c)));

    await mouse.moveTo(tester.getCenter(_strip));
    await tester.pump();
    await mouse.down(tester.getCenter(_strip));
    await mouse.moveBy(const Offset(20, 0));
    await tester.pump();
    await _pumpMs(tester, 60);
    expect(_strip, _line(c), reason: 'no wait while dragging');
    await mouse.up();
    await tester.pumpAndSettle();

    await tester.pumpWidget(_edge(_Log(), appearance: const ZsAppearance(inactive: true)));
    await mouse.moveTo(Offset.zero);
    await mouse.moveTo(tester.getCenter(_strip));
    await tester.pumpAndSettle();
    expect(_strip, isNot(_line(c)), reason: 'an inactive window paints no hover');

    final inert = _Log();
    await tester.pumpWidget(_edge(inert, inert: true));
    await mouse.moveTo(Offset.zero);
    await mouse.moveTo(tester.getCenter(_strip));
    await tester.pumpAndSettle();
    expect(_strip, isNot(_line(c)));
    await mouse.down(tester.getCenter(_strip));
    await mouse.moveBy(const Offset(20, 0));
    await mouse.up();
    await tester.pump();
    expect(inert.changes, isEmpty, reason: 'an inert edge takes no pointer');
  });

  testWidgets('a forced hover or press (the state matrix) shows the line at once', (tester) async {
    for (final state in <WidgetState>[WidgetState.hovered, WidgetState.pressed]) {
      final states = WidgetStatesController(<WidgetState>{state});
      addTearDown(states.dispose);
      await tester.pumpWidget(
        zsHost(
          SizedBox(
            height: 200,
            child: ZsResizeEdge(
              side: ZsResizeSide.right,
              value: 300,
              min: 240,
              max: 440,
              defaultValue: 300,
              label: 'Panel width',
              onChanged: (_) {},
              statesController: states,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_strip, _line(c), reason: state.name);
    }
  });

  testWidgets('VoiceOver: an adjustable value in points; increase means wider', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final log = _Log();
    await tester.pumpWidget(_edge(log));
    final Finder edge = find.bySemanticsIdentifier('edge');
    expect(
      tester.getSemantics(edge),
      matchesSemantics(
        isSlider: true,
        label: 'Panel width',
        value: '300 points',
        increasedValue: '310 points',
        decreasedValue: '290 points',
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasIncreaseAction: true,
        hasDecreaseAction: true,
        hasFocusAction: true,
        identifier: 'edge',
      ),
    );
    tester.semantics.performAction(
      find.semantics.byPredicate((node) => node.identifier == 'edge'),
      SemanticsAction.increase,
    );
    await tester.pump();
    expect(log.changes.last, 310);
    handle.dispose();
  });
}
