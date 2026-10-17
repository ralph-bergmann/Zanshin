// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_badge.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _badge(Object? count, {ZsBadgeTone tone = ZsBadgeTone.accent, ZsAppearance appearance = const ZsAppearance()}) =>
    zsHost(
      ZsBadge(count: count, tone: tone),
      appearance: appearance,
    );

void main() {
  const ZsColors night = ZsColors.night;

  testWidgets('accent: --accent with an inset --accent-line edge and a 2 px --fl-bg-solid cut-out', (tester) async {
    await tester.pumpWidget(_badge(3));
    await tester.pump(ZsMotion.full.durPop);
    expect(tester.getSize(find.byType(ZsBadge)).height, 15);
    expect(tester.getSize(find.byType(ZsBadge)).width, greaterThanOrEqualTo(15));
    expect(
      find.byType(ZsBadge),
      paints
        ..something(ringOf(color: night.flBgSolid))
        ..something(rrectOf(color: night.accent))
        ..something(ringOf(color: night.accentLine, inset: 1)),
    );
    expect(tester.widget<Text>(find.text('3')).style?.color, night.accentInk);
  });

  testWidgets('neutral: --fl-on with --text-muted and no ring', (tester) async {
    await tester.pumpWidget(_badge(12, tone: ZsBadgeTone.neutral));
    await tester.pump(ZsMotion.full.durPop);
    expect(find.byType(ZsBadge), paints..something(rrectOf(color: night.flOn)));
    expect(find.byType(ZsBadge), isNot(paints..something(ringOf(color: night.flBgSolid))));
    expect(tester.widget<Text>(find.text('12')).style?.color, night.textMuted);
  });

  testWidgets('above max it shows max+; true is an 8 px dot', (tester) async {
    await tester.pumpWidget(_badge(120));
    expect(find.text('99+'), findsOneWidget);
    await tester.pumpWidget(_badge(true));
    expect(tester.getSize(find.byType(ZsBadge)), const Size(8, 8));
  });

  testWidgets('an inactive window turns the accent badge neutral through the tokens', (tester) async {
    const inactive = ZsAppearance(inactive: true);
    await tester.pumpWidget(_badge(3, appearance: inactive));
    await tester.pump(ZsMotion.full.durPop);
    expect(find.byType(ZsBadge), paints..something(rrectOf(color: ZsColors.resolve(inactive).accent)));
  });

  testWidgets('0 hides it with its exit; it scales in from .6 with a fade', (tester) async {
    await tester.pumpWidget(_badge(3));
    expect(tester.widget<Opacity>(find.byType(Opacity).first).opacity, 0);
    await tester.pump(ZsMotion.full.durPop);
    await tester.pumpWidget(_badge(0));
    await tester.pump();
    await tester.pump(ZsMotion.full.durExit ~/ 2);
    expect(find.text('3'), findsOneWidget, reason: 'the last value stays for the exit');
    await tester.pump(ZsMotion.full.durExit);
    expect(find.text('3'), findsNothing);
  });

  testWidgets('under reduce motion it only fades: no scale', (tester) async {
    await tester.pumpWidget(_badge(3, appearance: const ZsAppearance(reduceMotion: true)));
    await tester.pump(ZsMotion.full.durPop ~/ 2);
    final Transform scale = tester.widget(find.byType(Transform).first);
    expect(scale.transform.getMaxScaleOnAxis(), 1);
  });

  testWidgets('it is hidden from VoiceOver and takes no pointer', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_badge(3));
    expect(find.bySemanticsLabel('3'), findsNothing);
    expect(find.byType(IgnorePointer), findsWidgets);
    handle.dispose();
  });
}
