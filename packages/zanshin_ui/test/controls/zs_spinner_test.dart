// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_spinner.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_metrics.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/zs_host.dart';

void main() {
  testWidgets('a ring at .22 and a quarter arc, one turn per --dur-spin', (tester) async {
    await tester.pumpWidget(zsHost(const ZsSpinner(color: Color(0xFFFFFFFF))));
    expect(tester.getSize(find.byType(ZsSpinner)), const Size.square(14));
    expect(
      find.byType(ZsSpinner),
      paints
        ..rotate(angle: 0)
        ..circle(radius: 6, color: const Color(0xFFFFFFFF).withValues(alpha: .22))
        ..arc(startAngle: -math.pi / 2, sweepAngle: math.pi / 2),
    );
    await tester.pump(ZsMotion.full.durSpin ~/ 4);
    expect(find.byType(ZsSpinner), paints..rotate(angle: math.pi / 2));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('it keeps turning under reduce motion', (tester) async {
    await tester.pumpWidget(zsHost(const ZsSpinner(), appearance: const ZsAppearance(reduceMotion: true)));
    await tester.pump(ZsMotion.reduced.durSpin ~/ 2);
    expect(find.byType(ZsSpinner), paints..rotate(angle: math.pi));
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('hidden from VoiceOver unless it stands alone with a label', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(zsHost(const ZsSpinner(size: ZsIconSize.lg)));
    expect(find.bySemanticsLabel('Fetching'), findsNothing);
    await tester.pumpWidget(zsHost(const ZsSpinner(label: 'Fetching', identifier: 'spin')));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('spin')),
      isSemantics(label: 'Fetching', value: 'busy'),
    );
    await tester.pumpWidget(const SizedBox());
    handle.dispose();
  });
}
