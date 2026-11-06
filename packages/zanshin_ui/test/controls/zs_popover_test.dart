// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_popover.dart';
import 'package:zanshin_ui/src/controls/zs_switch.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_type.dart';
import 'package:zanshin_ui/src/materials/zs_menu_material.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _popover({VoidCallback? onSettings, ZsAppearance appearance = const ZsAppearance()}) => zsHost(
  appearance: appearance,
  ZsPopover(
    label: 'View',
    identifier: 'popover',
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const ZsPopoverHeader('View'),
        ZsOptionRow(
          label: 'Show elided',
          child: ZsSwitch(value: true, onChanged: (_) {}, label: 'Show elided'),
        ),
        const ZsPopoverSeparator(),
        ZsOptionLink(label: 'More options', action: 'Settings…', shortcut: '⌘,', onPressed: onSettings),
      ],
    ),
  ),
);

void main() {
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('the menu material, 340 wide, padding 6 8 10; the header caps in --text-dim; rows 36 high', (
    tester,
  ) async {
    await tester.pumpWidget(_popover());
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ZsMenuMaterial)).width, 340);
    expect(tester.widget<ZsMenuMaterial>(find.byType(ZsMenuMaterial)).padding, const EdgeInsets.fromLTRB(8, 6, 8, 10));
    final Text header = tester.widget<Text>(find.text(ZsType.caps('View')));
    expect(header.style?.color, c.textDim);
    expect(tester.getSize(find.byType(ZsOptionRow)).height, 36);
    expect(tester.getSize(find.byType(ZsOptionLink)).height, 36);
  });

  testWidgets('at comfy density the option rows are 42 high (Story 11.20)', (tester) async {
    await tester.pumpWidget(_popover(appearance: const ZsAppearance(density: ZsDensity.comfy)));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(ZsOptionRow)).height, 42);
    expect(tester.getSize(find.byType(ZsOptionLink)).height, 42);
  });

  testWidgets('the option link: hover --fl-hover with --text; its faint shortcut steps up a rung', (tester) async {
    var opened = 0;
    await tester.pumpWidget(_popover(onSettings: () => opened++));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.text('Settings…')).style?.color, c.textDim);
    expect(tester.widget<Text>(find.text('⌘,')).style?.color, c.textFaint);
    await hover(tester, find.byType(ZsOptionLink));
    await tester.pumpAndSettle();
    expect(find.byType(ZsOptionLink), paints..something(rrectOf(color: c.flHover)));
    expect(tester.widget<Text>(find.text('More options')).style?.color, c.text);
    expect(tester.widget<Text>(find.text('Settings…')).style?.color, c.textDim);
    expect(tester.widget<Text>(find.text('⌘,')).style?.color, c.textDim, reason: 'faint steps up to dim');
    await tester.tap(find.byType(ZsOptionLink));
    expect(opened, 1);
  });

  testWidgets('VoiceOver: named by its header', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_popover());
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.bySemanticsIdentifier('popover')), isSemantics(label: 'View'));
    handle.dispose();
  });
}
