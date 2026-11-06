// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_field_list.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/icons/zanshin_icon.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

Widget _row({bool active = false, bool shown = false, ZsAppearance appearance = const ZsAppearance()}) => zsHost(
  SizedBox(
    width: 300,
    child: ZsFieldListRow(
      active: active,
      shown: shown,
      icon: ZI.bookmark,
      onPressed: () {},
      semanticLabel: 'main',
      child: const Text('main'),
    ),
  ),
  appearance: appearance,
  icons: true,
);

void main() {
  setUpIconRegistry();
  const ZsColors c = ZsColors.night;

  group('ZsFieldListController', () {
    test('↓ ↑ wrap and skip disabled rows; Home End the first and last enabled; ↩ runs the row', () {
      final list = ZsFieldListController();
      addTearDown(list.dispose);
      final activated = <int>[];
      list.attach(count: 4, enabled: (i) => i != 0 && i != 3, onActivate: activated.add);
      expect(list.activate(), isFalse, reason: 'no keyboard row yet');
      list.next();
      expect(list.active, 1);
      list
        ..next()
        ..next();
      expect(list.active, 1, reason: 'wrapped past the disabled ends');
      list.previous();
      expect(list.active, 2);
      list.first();
      expect(list.active, 1);
      list.last();
      expect(list.active, 2);
      expect(list.activate(), isTrue);
      expect(activated, <int>[2]);
      list.detach();
      expect(list.attached, isFalse);
      expect(list.active, -1);
    });

    test('with no enabled row the keys keep the list on no row', () {
      final list = ZsFieldListController();
      addTearDown(list.dispose);
      final asked = <int>[];
      list
        ..attach(
          count: 3,
          enabled: (i) {
            asked.add(i);
            return false;
          },
        )
        ..next()
        ..previous()
        ..first()
        ..last();
      expect(list.active, -1);
      expect(list.activate(), isFalse);
      expect(asked.every((i) => i >= 0 && i < 3), isTrue, reason: 'only rows that exist are asked about');
    });
  });

  group('ZsFieldListRow', () {
    testWidgets('the keyboard row is --accent-soft with its icon in --accent-text', (tester) async {
      await tester.pumpWidget(_row(active: true));
      expect(find.byType(ZsFieldListRow), paints..something(rrectOf(color: c.accentSoft)));
      expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon)).color, c.accentText);
      expect(tester.getSize(find.byType(ZsFieldListRow)).height, greaterThanOrEqualTo(34));
    });

    testWidgets('a one-line row is 34 high, 40 at comfy density (Story 11.20)', (tester) async {
      // In a list, as the field's list has it: the row takes its own height.
      Widget listed(ZsDensity density) => zsHost(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 300,
              child: ZsFieldListRow(icon: ZI.bookmark, onPressed: () {}, child: const Text('main')),
            ),
          ],
        ),
        appearance: ZsAppearance(density: density),
        icons: true,
      );
      await tester.pumpWidget(listed(ZsDensity.compact));
      expect(tester.getSize(find.byType(ZsFieldListRow)).height, 34);
      await tester.pumpWidget(listed(ZsDensity.comfy));
      expect(tester.getSize(find.byType(ZsFieldListRow)).height, 40);
    });

    testWidgets('hover is --fl-hover and never the keyboard row', (tester) async {
      await tester.pumpWidget(_row());
      await hover(tester, find.byType(ZsFieldListRow));
      await tester.pumpAndSettle();
      expect(find.byType(ZsFieldListRow), paints..something(rrectOf(color: c.flHover)));
      expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon)).color, c.textDim);
    });

    testWidgets('what the list shows carries a check, never a fill', (tester) async {
      await tester.pumpWidget(_row(shown: true));
      expect(find.byType(ZanshinIcon), findsNWidgets(2));
      expect(tester.widget<ZanshinIcon>(find.byType(ZanshinIcon).last).color, c.accentText);
      expect(find.byType(ZsFieldListRow), isNot(paints..something(rrectOf(color: c.accentSoft))));
    });

    testWidgets('increased contrast edges the keyboard row with --accent-line', (tester) async {
      const contrast = ZsAppearance(increasedContrast: true);
      await tester.pumpWidget(_row(active: true, appearance: contrast));
      expect(
        find.byType(ZsFieldListRow),
        paints..something(ringOf(color: ZsColors.resolve(contrast).accentLine, inset: 1)),
      );
    });

    testWidgets('a leading widget takes the icon column instead of the glyph', (tester) async {
      await tester.pumpWidget(
        zsHost(
          const SizedBox(
            width: 300,
            child: ZsFieldListRow(
              icon: ZI.bookmark,
              leading: SizedBox(key: ValueKey<String>('lead'), width: 18, height: 18),
              child: Text('main'),
            ),
          ),
          icons: true,
        ),
      );
      expect(find.byKey(const ValueKey<String>('lead')), findsOneWidget);
      expect(find.byType(ZanshinIcon), findsNothing);
    });

    testWidgets('it takes no focus', (tester) async {
      await tester.pumpWidget(_row());
      expect(find.descendant(of: find.byType(ZsFieldListRow), matching: find.byType(Focus)), findsNothing);
    });
  });
}
