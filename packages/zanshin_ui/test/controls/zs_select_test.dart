// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_menu.dart';
import 'package:zanshin_ui/src/controls/zs_select.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

const ZsMotion _m = ZsMotion.full;

List<ZsSelectEntry<String>> _options(int count) => <ZsSelectEntry<String>>[
  for (var i = 0; i < count; i++) ZsSelectOption<String>(value: 'r$i', label: 'remote-$i'),
];

Widget _select({
  required String value,
  required ValueChanged<String> onChanged,
  int count = 5,
  List<ZsSelectEntry<String>>? options,
  Alignment alignment = Alignment.center,
  FocusNode? focusNode,
  ZsSelectPlacement placement = ZsSelectPlacement.over,
  ZsAppearance appearance = const ZsAppearance(),
}) => zsHost(
  appearance: appearance,
  // An opaque window background, as the app's window fill is: the outside click needs something to hit.
  ColoredBox(
    color: const Color(0x00000000),
    child: SizedBox.expand(
      child: Stack(
        children: <Widget>[
          Align(
            alignment: alignment,
            child: ZsSelect<String>(
              options: options ?? _options(count),
              value: value,
              onChanged: onChanged,
              label: 'Fetch from',
              focusNode: focusNode,
              placement: placement,
              identifier: 'select',
            ),
          ),
        ],
      ),
    ),
  ),
  overlay: true,
  icons: true,
);

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(_m.durMenu + const Duration(milliseconds: 1));
}

/// The trigger's up-down chevron.
Finder _chevron() => find.descendant(of: find.byType(ZsSelect<String>), matching: find.byType(ZanshinIcon));

void main() {
  setUpIconRegistry();
  useMacFocus();

  testWidgets('the chevron keeps to the trigger\'s right edge, however short the value', (tester) async {
    await tester.pumpWidget(_select(value: 'r2', onChanged: (_) {}));
    final Rect trigger = tester.getRect(find.byType(ZsSelect<String>));
    // `padding:0 5px 0 10px` inside the 1 px edge (DS components/forms/forms.css:112).
    expect(tester.getRect(_chevron()).right, trigger.right - 6);
  });

  testWidgets('a click opens the list over the trigger, the chosen row centred on it, its text at the trigger text', (
    tester,
  ) async {
    await tester.pumpWidget(_select(value: 'r2', onChanged: (_) {}));
    final Rect trigger = tester.getRect(find.byType(ZsSelect<String>));
    expect(trigger.height, 30);
    expect(trigger.width, greaterThanOrEqualTo(170));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    final Finder chosen = find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-2'));
    final Rect row = tester.getRect(chosen);
    expect((row.center.dy - trigger.center.dy).abs(), lessThanOrEqualTo(1));
    expect(row.left, trigger.left + 11, reason: 'the list starts 29 left of the trigger');
    final Rect panel = tester.getRect(find.byType(ZsMenuPanel));
    expect(panel.width, greaterThanOrEqualTo(trigger.width + 40));
    expect(panel.width, lessThanOrEqualTo(360));
  });

  testWidgets('with short labels the list is the trigger + 40 wide', (tester) async {
    final options = <ZsSelectEntry<String>>[
      for (final String name in const <String>['a', 'b', 'c']) ZsSelectOption<String>(value: name, label: name),
    ];
    await tester.pumpWidget(_select(value: 'b', onChanged: (_) {}, options: options));
    final Rect trigger = tester.getRect(find.byType(ZsSelect<String>));
    expect(trigger.width, 170, reason: 'the narrowest trigger');
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    expect(tester.getRect(find.byType(ZsMenuPanel)).width, trigger.width + 40);
  });

  testWidgets('with very long labels the list is at most 360 wide', (tester) async {
    final options = <ZsSelectEntry<String>>[
      const ZsSelectOption<String>(value: 'origin', label: 'origin'),
      ZsSelectOption<String>(value: 'long', label: 'a-remote-with-a-very-long-name-' * 4),
    ];
    await tester.pumpWidget(_select(value: 'origin', onChanged: (_) {}, options: options));
    expect(tester.getRect(find.byType(ZsSelect<String>)).width, 170);
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    expect(tester.getRect(find.byType(ZsMenuPanel)).width, 360);
  });

  testWidgets('near the top edge the whole list shifts down to stay 8 px inside the window', (tester) async {
    await tester.pumpWidget(_select(value: 'r4', onChanged: (_) {}, alignment: Alignment.topCenter));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    expect(tester.getRect(find.byType(ZsMenuPanel)).top, 8);
  });

  testWidgets('a list taller than the window scrolls so the chosen row stays at the trigger', (tester) async {
    await tester.pumpWidget(_select(value: 'r20', onChanged: (_) {}, count: 40));
    final Rect trigger = tester.getRect(find.byType(ZsSelect<String>));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    final Rect panel = tester.getRect(find.byType(ZsMenuPanel));
    expect(panel.top, greaterThanOrEqualTo(8));
    expect(panel.bottom, lessThanOrEqualTo(600 - 8));
    final Rect row = tester.getRect(find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-20')));
    expect((row.center.dy - trigger.center.dy).abs(), lessThanOrEqualTo(1));
  });

  testWidgets('press – drag – release picks the row under the pointer', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(_select(value: 'r2', onChanged: picked.add));
    final TestGesture gesture = await tester.startGesture(tester.getCenter(find.byType(ZsSelect<String>)));
    await _settle(tester);
    final Offset target = tester.getCenter(
      find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-4')),
    );
    await gesture.moveTo(target);
    await tester.pump();
    await gesture.up();
    await tester.pump(_m.durBlink * 2 + const Duration(milliseconds: 1));
    expect(picked, <String>['r4']);
  });

  testWidgets('at comfy density the rows are 34 high and the chosen one still sits on the trigger', (tester) async {
    await tester.pumpWidget(
      _select(
        value: 'r3',
        onChanged: (_) {},
        appearance: const ZsAppearance(density: ZsDensity.comfy),
      ),
    );
    final Rect trigger = tester.getRect(find.byType(ZsSelect<String>));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    final Rect row = tester.getRect(find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-3')));
    expect((row.center.dy - trigger.center.dy).abs(), lessThanOrEqualTo(1));
    final Rect next = tester.getRect(find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-4')));
    expect(next.center.dy - row.center.dy, 34 + 1, reason: 'a 34 row and the 1 gap');
  });

  testWidgets('under a window zoom, press – drag – release picks the row under the pointer', (tester) async {
    final picked = <String>[];
    await tester.pumpWidget(
      Transform.scale(
        scale: 1.5,
        alignment: Alignment.topLeft,
        child: _select(value: 'r0', onChanged: picked.add),
      ),
    );
    final TestGesture gesture = await tester.startGesture(tester.getCenter(find.byType(ZsSelect<String>)));
    await _settle(tester);
    // The label's lower right: inside the row as drawn, outside its unscaled size.
    final Finder label = find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-3'));
    await gesture.moveTo(tester.getBottomRight(label) - const Offset(1, 1));
    await tester.pump();
    await gesture.up();
    await tester.pump(_m.durBlink * 2 + const Duration(milliseconds: 1));
    expect(picked, <String>['r3']);
  });

  testWidgets('a click on the open trigger closes it', (tester) async {
    await tester.pumpWidget(_select(value: 'r2', onChanged: (_) {}, placement: ZsSelectPlacement.below));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    expect(find.byType(ZsMenuPanel), findsOneWidget);
    await tester.tap(find.byType(ZsSelect<String>));
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byType(ZsMenuPanel), findsNothing);
  });

  testWidgets('↓ opens it with the highlight on the chosen row; ↩ picks; Esc closes and refocuses the trigger', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final picked = <String>[];
    await tester.pumpWidget(_select(value: 'r2', onChanged: picked.add, focusNode: focus));
    focus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _settle(tester);
    final Finder chosen = find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('remote-2'));
    expect(chosen, findsOneWidget);
    expect(tester.getSemantics(find.bySemanticsLabel('remote-2').last), isSemantics(isSelected: true));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byType(ZsMenuPanel), findsNothing);
    expect(focus.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await _settle(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(_m.durBlink * 2 + const Duration(milliseconds: 1));
    expect(picked, <String>['r3']);
    handle.dispose();
  });

  testWidgets('a click outside closes it without refocusing the trigger', (tester) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(_select(value: 'r2', onChanged: (_) {}, focusNode: focus));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.byType(ZsMenuPanel), findsNothing);
    expect(focus.hasPrimaryFocus, isFalse);
  });

  testWidgets('below: 4 under the trigger, at least its width', (tester) async {
    await tester.pumpWidget(_select(value: 'r2', onChanged: (_) {}, placement: ZsSelectPlacement.below));
    final Rect trigger = tester.getRect(find.byType(ZsSelect<String>));
    await tester.tap(find.byType(ZsSelect<String>));
    await _settle(tester);
    final Rect panel = tester.getRect(find.byType(ZsMenuPanel));
    expect(panel.top, trigger.bottom + 4);
    expect(panel.left, trigger.left);
    expect(panel.width, greaterThanOrEqualTo(trigger.width));
  });

  testWidgets('VoiceOver: a button named "label: value", expanded while open', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_select(value: 'r2', onChanged: (_) {}));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('select')),
      isSemantics(label: 'Fetch from: remote-2', isButton: true, hasExpandedState: true, isExpanded: false),
    );
    handle.dispose();
  });
}
