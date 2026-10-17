// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_radio.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

const _options = <ZsRadioOption<String>>[
  ZsRadioOption(value: 'new', label: 'Start a new change', hint: 'jj new'),
  ZsRadioOption(value: 'squash', label: 'Squash into @', hint: 'jj squash'),
  ZsRadioOption(value: 'ask', label: 'Ask every time', disabledReason: 'Needs Zanshin 0.25'),
];

Widget _group(
  String? value,
  ValueChanged<String> onChanged, {
  FocusNode? before,
  ZsAppearance appearance = const ZsAppearance(),
}) => zsHost(
  appearance: appearance,
  Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      if (before != null) Focus(focusNode: before, child: const SizedBox(width: 10, height: 10)),
      ZsRadioGroup<String>(options: _options, value: value, onChanged: onChanged, label: 'When @ has changes'),
    ],
  ),
  overlay: true,
);

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('a 15 px circle: rest edge --text-faint; on --accent with the 6 px --accent-ink dot', (tester) async {
    await tester.pumpWidget(_group('new', (_) {}));
    final Finder radios = find.byType(ZsRadio<String>);
    expect(tester.getSize(radios.first), const Size.square(15));
    expect(
      radios.first,
      paints
        ..something(circleOf(radius: 7.5, color: c.accent))
        ..something(circleOf(color: c.accentLine))
        ..something(circleOf(radius: 3, color: c.accentInk)),
    );
    expect(radios.at(1), paints..something(circleOf(radius: 6.75, color: c.textFaint)));
  });

  testWidgets('the dot grows in on --dur-toggle', (tester) async {
    var value = 'new';
    await tester.pumpWidget(_group(value, (v) => value = v));
    await tester.tap(find.text('Squash into @'));
    await tester.pumpWidget(_group(value, (v) => value = v));
    await tester.pump();
    await tester.pump(ZsMotion.full.durToggle ~/ 2);
    expect(find.byType(ZsRadio<String>).at(1), isNot(paints..something(circleOf(radius: 3))));
    await tester.pump(ZsMotion.full.durToggle);
    expect(find.byType(ZsRadio<String>).at(1), paints..something(circleOf(radius: 3)));
  });

  testWidgets('under reduce motion the dot is there at full size on the next frame', (tester) async {
    const reduced = ZsAppearance(reduceMotion: true);
    var value = 'new';
    await tester.pumpWidget(_group(value, (v) => value = v, appearance: reduced));
    await tester.tap(find.text('Squash into @'));
    await tester.pumpWidget(_group(value, (v) => value = v, appearance: reduced));
    expect(find.byType(ZsRadio<String>).at(1), paints..something(circleOf(radius: 3)));
  });

  testWidgets('a click on the label chooses', (tester) async {
    final chosen = <String>[];
    await tester.pumpWidget(_group('new', chosen.add));
    await tester.tap(find.text('Squash into @'));
    expect(chosen, <String>['squash']);
  });

  testWidgets('one Tab stop on the chosen radio; the arrows move, wrap and skip the disabled option', (tester) async {
    var value = 'squash';
    final before = FocusNode();
    addTearDown(before.dispose);
    await tester.pumpWidget(_group(value, (v) => value = v, before: before));
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(value, 'new', reason: 'past the disabled "ask", wrapping to the first');
    await tester.pumpWidget(_group(value, (v) => value = v, before: before));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(value, 'squash');
  });

  testWidgets('a disabled option sits at .4 and carries its reason', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_group('new', (_) {}));
    expect(find.byType(ZsTooltip), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsLabel('Ask every time')),
      isSemantics(hint: 'Needs Zanshin 0.25', hasEnabledState: true, isEnabled: false),
    );
    handle.dispose();
  });

  testWidgets('VoiceOver: a radio group of radios, the chosen one checked', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_group('new', (_) {}));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Start a new change')),
      isSemantics(isInMutuallyExclusiveGroup: true, hasCheckedState: true, isChecked: true),
    );
    expect(find.bySemanticsLabel('When @ has changes'), findsOneWidget);
    handle.dispose();
  });
}
