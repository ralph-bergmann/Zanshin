// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_control_core.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

const ZsMotion _m = ZsMotion.full;

/// A 60 × 30 Zs control at [at] inside an 800 × 600 window.
Widget _window({
  required Offset at,
  ZsTooltipPlacement placement = ZsTooltipPlacement.below,
  String message = 'New change',
  FocusNode? focusNode,
  VoidCallback? onActivate,
}) => zsHost(
  SizedBox.expand(
    child: Stack(
      children: <Widget>[
        Positioned(
          left: at.dx,
          top: at.dy,
          child: ZsTooltip(
            message: message,
            shortcut: '⌘N',
            cmd: 'jj new',
            placement: placement,
            child: ZsControlCore(
              identifier: 'control',
              focusNode: focusNode,
              onActivate: onActivate ?? () {},
              semantics: const SemanticsProperties(button: true, label: 'New'),
              builder: (context, status) => const SizedBox(width: 60, height: 30),
            ),
          ),
        ),
      ],
    ),
  ),
  overlay: true,
);

/// Lets a fade of [duration] finish: an animation is done only once more than its duration has passed.
Future<void> _fade(WidgetTester tester, Duration duration) async {
  await tester.pump();
  await tester.pump(duration + const Duration(milliseconds: 1));
  await tester.pump();
}

Rect _bubble(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.text('New change'), matching: find.byType(ConstrainedBox)).first);

void main() {
  useMacFocus();

  testWidgets('it shows after --delay-tooltip of rest, label, shortcut and command', (tester) async {
    await tester.pumpWidget(_window(at: const Offset(300, 200)));
    final TestGesture mouse = await hover(tester, find.byType(ZsControlCore));
    await tester.pump(_m.delayTooltip - const Duration(milliseconds: 10));
    expect(find.text('New change'), findsNothing);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump(_m.durHover);
    expect(find.text('New change'), findsOneWidget);
    expect(find.text('⌘N'), findsOneWidget);
    expect(find.text('jj new'), findsOneWidget);
    await mouse.moveTo(Offset.zero);
    await tester.pump(_m.durExit);
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets('within the warm window the next one shows at once', (tester) async {
    await tester.pumpWidget(_window(at: const Offset(300, 200)));
    final TestGesture mouse = await hover(tester, find.byType(ZsControlCore));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    await mouse.moveTo(Offset.zero);
    await _fade(tester, _m.durExit);
    expect(find.text('New change'), findsNothing);
    await mouse.moveTo(tester.getCenter(find.byType(ZsControlCore)));
    await tester.pump();
    await tester.pump(_m.durHover);
    expect(find.text('New change'), findsOneWidget, reason: 'warm: no --delay-tooltip');
    await mouse.moveTo(Offset.zero);
    await tester.pump(_m.durExit);
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets('Esc hides it; pressing the control hides it', (tester) async {
    await tester.pumpWidget(_window(at: const Offset(300, 200)));
    final TestGesture mouse = await hover(tester, find.byType(ZsControlCore));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(find.text('New change'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _fade(tester, _m.durExit);
    expect(find.text('New change'), findsNothing);
    await tester.pump(_m.durTooltipWarm);
    await mouse.moveTo(Offset.zero);
    await mouse.moveTo(tester.getCenter(find.byType(ZsControlCore)));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(find.text('New change'), findsOneWidget);
    await mouse.down(tester.getCenter(find.byType(ZsControlCore)));
    await _fade(tester, _m.durExit);
    expect(find.text('New change'), findsNothing, reason: 'a press hides it');
    await mouse.up();
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets('below by default, 8 px from the control', (tester) async {
    await tester.pumpWidget(_window(at: const Offset(300, 200)));
    await hover(tester, find.byType(ZsControlCore));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    final Rect control = tester.getRect(find.byType(ZsControlCore));
    expect(_bubble(tester).top, control.bottom + 8);
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets(
    'at the bottom edge it flips above; at the right edge it is clamped 8 px inside, never over its control',
    (tester) async {
      await tester.pumpWidget(_window(at: const Offset(735, 565)));
      await hover(tester, find.byType(ZsControlCore));
      await tester.pump(_m.delayTooltip);
      await tester.pump(_m.durHover);
      final Rect control = tester.getRect(find.byType(ZsControlCore));
      final Rect bubble = _bubble(tester);
      expect(bubble.bottom, control.top - 8);
      expect(bubble.right, 800 - 8);
      expect(bubble.overlaps(control), isFalse);
      await tester.pump(_m.durTooltipWarm);
    },
  );

  testWidgets('right of a rail button flips left at the window edge', (tester) async {
    await tester.pumpWidget(_window(at: const Offset(735, 200), placement: ZsTooltipPlacement.right));
    await hover(tester, find.byType(ZsControlCore));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    final Rect control = tester.getRect(find.byType(ZsControlCore));
    expect(_bubble(tester).right, control.left - 8);
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets('keyboard focus shows it after the same delay, blur hides it', (tester) async {
    final node = FocusNode();
    addTearDown(node.dispose);
    await tester.pumpWidget(_window(at: const Offset(300, 200), focusNode: node));
    node.requestFocus();
    await tester.pump();
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(find.text('New change'), findsOneWidget);
    node.unfocus();
    await tester.pump();
    await _fade(tester, _m.durExit);
    expect(find.text('New change'), findsNothing);
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets("its text joins the control's semantics node, not a node of its own", (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_window(at: const Offset(300, 200)));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('control')),
      isSemantics(label: 'New', tooltip: 'New change\njj new'),
    );
    handle.dispose();
  });
}
