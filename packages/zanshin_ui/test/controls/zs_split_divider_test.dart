// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_split_divider.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

/// What a divider reported.
class _Log {
  final changes = <double>[];
  final ends = <double>[];
}

/// A divider along [axis] (min 100, max [max], default 200, total 600) at [start], its value following
/// [ZsSplitDivider.onChanged], with a focusable box before it.
Widget _divider(_Log log, {Axis axis = Axis.horizontal, double start = 200, double max = 400, FocusNode? before}) {
  var value = start;
  return zsHost(
    StatefulBuilder(
      builder: (context, setState) => Flex(
        direction: axis,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (before != null) Focus(focusNode: before, child: const SizedBox.square(dimension: 10)),
          SizedBox(
            width: axis == Axis.horizontal ? null : 300,
            height: axis == Axis.horizontal ? 300 : null,
            child: ZsSplitDivider(
              axis: axis,
              value: value,
              min: 100,
              max: max,
              defaultValue: 200,
              total: 600,
              label: 'Files and diff',
              identifier: 'divider',
              onChanged: (v) => setState(() => log.changes.add(value = v)),
              onChangeEnd: log.ends.add,
            ),
          ),
        ],
      ),
    ),
    overlay: true,
  );
}

Finder get _band => find.byType(ZsSplitDivider);

/// Whether the band paints a rounded rect in [color].
PaintPattern _paints(Color color) => paints
  ..something((method, arguments) {
    if (method != #drawRRect) {
      return false;
    }
    final Color c = (arguments[1] as Paint).color;
    return (c.r - color.r).abs() < 1e-3 && (c.g - color.g).abs() < 1e-3 && (c.b - color.b).abs() < 1e-3;
  });

Future<void> _settleTaps(WidgetTester tester) => tester.pump(const Duration(milliseconds: 500));

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('side by side: a 12 px band, a drag follows the pointer, clamps, and commits once on release', (
    tester,
  ) async {
    final log = _Log();
    await tester.pumpWidget(_divider(log));
    expect(tester.getSize(_band), const Size(12, 300));
    expect(_band, _paints(c.flBorder), reason: 'the grip at rest');
    final TestGesture drag = await tester.startGesture(tester.getCenter(_band), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(30, 0));
    await tester.pump();
    expect(log.changes.last, 230);
    expect(_band, _paints(c.accent), reason: 'the accent line while dragging');
    await drag.moveBy(const Offset(900, 0));
    await tester.pump();
    expect(log.changes.last, 400, reason: 'clamped to the maximum');
    await drag.moveBy(const Offset(-1100, 0));
    await tester.pump();
    expect(log.changes.last, 100, reason: 'clamped to the minimum');
    expect(log.ends, isEmpty, reason: 'nothing is committed during the drag');
    await drag.up();
    await tester.pump();
    expect(log.ends, <double>[100]);
    await _settleTaps(tester);
  });

  testWidgets('stacked: the band is 12 high and a vertical drag moves it', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_divider(log, axis: Axis.vertical));
    expect(tester.getSize(_band), const Size(300, 12));
    await tester.dragFrom(tester.getCenter(_band), const Offset(0, -40), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(log.ends, <double>[160]);
    await _settleTaps(tester);
  });

  testWidgets('a drag that ends back at its start still reports its end', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_divider(log));
    final TestGesture drag = await tester.startGesture(tester.getCenter(_band), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(40, 0));
    await tester.pump();
    await drag.moveBy(const Offset(-40, 0));
    await tester.pump();
    await drag.up();
    await tester.pump();
    expect(log.changes, isNotEmpty);
    expect(log.ends, <double>[log.changes.last], reason: 'the host ends its drag state');
    await _settleTaps(tester);
  });

  testWidgets('when the maximum is below the minimum, the maximum wins (the other pane keeps its room)', (
    tester,
  ) async {
    final log = _Log();
    await tester.pumpWidget(_divider(log, start: 60, max: 60));
    await tester.dragFrom(tester.getCenter(_band), const Offset(50, 0), kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(log.changes, isEmpty);
    await _settleTaps(tester);
  });

  testWidgets('a double-click resets to the default and commits it', (tester) async {
    final log = _Log();
    await tester.pumpWidget(_divider(log, start: 320));
    await tester.tap(_band);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_band);
    await tester.pump();
    expect(log.ends, <double>[200]);
    await _settleTaps(tester);
    // At the default already: nothing to report, so the host writes nothing.
    await tester.tap(_band);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(_band);
    await tester.pump();
    expect(log.ends, <double>[200]);
    expect(log.changes, <double>[200]);
    await _settleTaps(tester);
  });

  testWidgets('keys: → 10, ⇧→ 50, ← back, ↩ resets; stacked uses ↑ ↓', (tester) async {
    final log = _Log();
    final before = FocusNode();
    addTearDown(before.dispose);
    await tester.pumpWidget(_divider(log, before: before));
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(log.ends, <double>[210, 260, 250, 200]);

    final stacked = _Log();
    await tester.pumpWidget(_divider(stacked, axis: Axis.vertical, before: before));
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(stacked.ends, <double>[210, 200, 190]);
  });

  testWidgets('VoiceOver: an adjustable slider named "Files and diff", its value the share in percent', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final log = _Log();
    await tester.pumpWidget(_divider(log, start: 150));
    final SemanticsNode node = tester.getSemantics(find.bySemanticsIdentifier('divider'));
    expect(node.label, 'Files and diff');
    expect(node.value, '25%');
    expect(node.increasedValue, '27%');
    expect(node.getSemanticsData().hasAction(SemanticsAction.increase), isTrue);
    tester.semantics.performAction(
      find.semantics.byPredicate((node) => node.identifier == 'divider'),
      SemanticsAction.increase,
    );
    await tester.pump();
    expect(log.ends, <double>[160]);
    handle.dispose();
  });
}
