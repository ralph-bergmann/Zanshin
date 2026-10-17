// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_chip.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

Widget _host(Widget chip, {ZsAppearance appearance = const ZsAppearance()}) =>
    zsHost(chip, appearance: appearance, icons: true);

Color? _textColor(WidgetTester tester, String label) => tester.widget<Text>(find.text(label)).style?.color;

void main() {
  setUpIconRegistry();
  useMacFocus();
  const ZsColors c = ZsColors.night;

  testWidgets('a toggle is neutral --fl-hover off and --accent-soft with --accent-text on; a click flips it', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(_host(ZsChip(label: 'Aa', onChanged: changes.add)));
    expect(find.byType(ZsChip), paints..something(rrectOf(color: c.flHover)));
    expect(_textColor(tester, 'Aa'), c.textMuted);
    expect(tester.getSize(find.byType(ZsChip)).height, 26);
    await tester.pumpWidget(_host(ZsChip(label: 'Aa', on: true, onChanged: changes.add)));
    await tester.pumpAndSettle();
    expect(find.byType(ZsChip), paints..something(rrectOf(color: c.accentSoft)));
    expect(_textColor(tester, 'Aa'), c.accentText);
    await tester.tap(find.byType(ZsChip));
    expect(changes, <bool>[false]);
  });

  testWidgets('a not chip that is on is red: --rem-bg with --rem, the label --text on hover', (tester) async {
    await tester.pumpWidget(_host(ZsChip(label: '~', kind: ZsChipKind.not, on: true, onChanged: (_) {})));
    expect(find.byType(ZsChip), paints..something(rrectOf(color: c.remBg)));
    expect(_textColor(tester, '~'), c.rem);
    await hover(tester, find.byType(ZsChip));
    await tester.pumpAndSettle();
    expect(find.byType(ZsChip), paints..something(rrectOf(color: c.remBgHover)));
    expect(_textColor(tester, '~'), c.text);
  });

  testWidgets('a filter chip: Backspace removes it; its ✕ is its own Tab stop named "Remove …"', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    var removed = 0;
    await tester.pumpWidget(
      _host(
        ZsChip(label: 'author: ralph', kind: ZsChipKind.filter, onRemove: () => removed++, identifier: 'chip'),
      ),
    );
    expect(find.byType(ZsChip), paints..something(rrectOf(color: c.flOn)));
    Focus.of(tester.element(find.text('author: ralph'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    expect(removed, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Remove author: ralph')),
      isSemantics(isButton: true, isFocused: true),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(removed, 2);
    await tester.tap(find.bySemanticsLabel('Remove author: ralph'));
    expect(removed, 3);
    handle.dispose();
  });

  testWidgets('an add chip is a dashed --border-strong pill that turns solid with --fl-hover', (tester) async {
    var added = 0;
    await tester.pumpWidget(_host(ZsChip(label: 'Add rule', kind: ZsChipKind.add, onPressed: () => added++)));
    expect(find.byType(ZsChip), paints..something((method, _) => method == #drawPath));
    await hover(tester, find.byType(ZsChip));
    await tester.pumpAndSettle();
    expect(
      find.byType(ZsChip),
      paints
        ..something(rrectOf(color: c.flHover))
        ..something(ringOf(color: c.borderStrong, inset: 1)),
    );
    await tester.tap(find.byType(ZsChip));
    expect(added, 1);
  });

  testWidgets('increased contrast edges a chip with --border-strong, a toggle that is on with --accent-line', (
    tester,
  ) async {
    const contrast = ZsAppearance(increasedContrast: true);
    final cc = ZsColors.resolve(contrast);
    await tester.pumpWidget(
      _host(
        ZsChip(label: 'Aa', onChanged: (_) {}),
        appearance: contrast,
      ),
    );
    expect(find.byType(ZsChip), paints..something(ringOf(color: cc.borderStrong, inset: 1)));
    await tester.pumpWidget(
      _host(
        ZsChip(label: 'Aa', on: true, onChanged: (_) {}),
        appearance: contrast,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ZsChip), paints..something(ringOf(color: cc.accentLine, inset: 1)));
  });

  testWidgets('VoiceOver: a toggle is a button with its toggled state', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(ZsChip(label: 'Aa', on: true, onChanged: (_) {}, identifier: 'chip')));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('chip')),
      isSemantics(label: 'Aa', isButton: true, hasToggledState: true, isToggled: true),
    );
    handle.dispose();
  });
}
