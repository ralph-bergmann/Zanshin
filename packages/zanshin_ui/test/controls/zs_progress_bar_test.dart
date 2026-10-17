// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_progress_bar.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _bar({double? value, ZsAppearance appearance = const ZsAppearance()}) => zsHost(
  ZsProgressBar(value: value, label: 'Fetching', identifier: 'bar'),
  appearance: appearance,
);

/// Matches the fill: a `drawRRect` of [color] [width] wide (within a pixel).
PaintPatternPredicate _fill(Color color, double width) =>
    (method, arguments) =>
        method == #drawRRect &&
        sameColor((arguments[1] as Paint).color, color) &&
        ((arguments[0] as RRect).width - width).abs() < 1;

void main() {
  const ZsColors c = ZsColors.night;

  testWidgets('a 4 px --progress-track groove with an --accent-live-line fill that moves on --dur-expand', (
    tester,
  ) async {
    await tester.pumpWidget(_bar(value: .25));
    await tester.pump();
    await tester.pump(ZsMotion.full.durExpand + const Duration(milliseconds: 1));
    expect(tester.getSize(find.byType(ZsProgressBar)), const Size(200, 4));
    expect(
      find.byType(ZsProgressBar),
      paints
        ..something(_fill(c.progressTrack, 200))
        ..something(_fill(c.accentLiveLine, 50)),
    );
    await tester.pumpWidget(_bar(value: .75));
    await tester.pump();
    await tester.pump(ZsMotion.full.durExpand ~/ 2);
    expect(find.byType(ZsProgressBar), isNot(paints..something(_fill(c.accentLiveLine, 150))));
    await tester.pump(ZsMotion.full.durExpand);
    expect(find.byType(ZsProgressBar), paints..something(_fill(c.accentLiveLine, 150)));
  });

  testWidgets('an inactive window keeps the live line', (tester) async {
    const inactive = ZsAppearance(inactive: true);
    await tester.pumpWidget(_bar(value: 1, appearance: inactive));
    await tester.pumpAndSettle();
    expect(ZsColors.resolve(inactive).accentLiveLine, c.accentLiveLine);
    expect(find.byType(ZsProgressBar), paints..something(_fill(c.accentLiveLine, 200)));
  });

  testWidgets('under reduce motion a new value jumps', (tester) async {
    const reduced = ZsAppearance(reduceMotion: true);
    await tester.pumpWidget(_bar(value: 0, appearance: reduced));
    await tester.pumpWidget(_bar(value: .5, appearance: reduced));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byType(ZsProgressBar), paints..something(_fill(c.accentLiveLine, 100)));
  });

  testWidgets('indeterminate: a 32 % segment sweeps', (tester) async {
    await tester.pumpWidget(_bar());
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(ZsProgressBar), paints..something(_fill(c.accentLiveLine, 64)));
  });

  testWidgets('indeterminate under reduce motion: the full fill pulses down to .45 halfway', (tester) async {
    await tester.pumpWidget(_bar(appearance: const ZsAppearance(reduceMotion: true)));
    await tester.pump();
    await tester.pump(ZsMotion.full.durShimmer ~/ 2);
    expect(
      find.byType(ZsProgressBar),
      paints..something(
        (method, arguments) =>
            method == #drawRRect &&
            (arguments[0] as RRect).width == 200 &&
            ((arguments[1] as Paint).color.a - c.accentLiveLine.a * .45).abs() < .02,
      ),
    );
  });

  testWidgets('increased contrast edges the groove with --border-strong', (tester) async {
    const contrast = ZsAppearance(increasedContrast: true);
    await tester.pumpWidget(_bar(value: .5, appearance: contrast));
    await tester.pumpAndSettle();
    expect(find.byType(ZsProgressBar), paints..something(ringOf(color: ZsColors.resolve(contrast).borderStrong)));
  });

  testWidgets('VoiceOver: its name and the value in percent, or "in progress"', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_bar(value: .42));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('bar')),
      isSemantics(label: 'Fetching', value: '42%'),
    );
    await tester.pumpWidget(_bar());
    expect(tester.getSemantics(find.bySemanticsIdentifier('bar')), isSemantics(value: 'in progress'));
    handle.dispose();
  });
}
