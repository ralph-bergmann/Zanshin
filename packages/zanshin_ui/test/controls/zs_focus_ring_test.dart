// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_focus_ring.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/zs_host.dart';

const _size = Size(80, 30);
final _box = RRect.fromRectAndRadius(Offset.zero & _size, const Radius.circular(8));

Widget _ring(ZsRingPlacement placement, {bool visible = true, ZsAppearance appearance = const ZsAppearance()}) =>
    zsHost(
      ZsFocusRing(
        visible: visible,
        placement: placement,
        radius: 8,
        child: SizedBox.fromSize(size: _size),
      ),
      appearance: appearance,
    );

void main() {
  testWidgets('outside: 2 px of --focus-ring, 2 px out, the radius grown with it', (tester) async {
    await tester.pumpWidget(_ring(ZsRingPlacement.outside));
    expect(
      find.byType(ZsFocusRing),
      paints..drrect(outer: _box.inflate(4), inner: _box.inflate(2), color: ZsColors.night.focusRing),
    );
  });

  testWidgets('inside: between −2 and the edge, for rows, flush segments and clipping wells', (tester) async {
    await tester.pumpWidget(_ring(ZsRingPlacement.inside));
    expect(find.byType(ZsFocusRing), paints..drrect(outer: _box, inner: _box.deflate(2)));
  });

  testWidgets('card: 3 px out, clear of the selection halo', (tester) async {
    await tester.pumpWidget(_ring(ZsRingPlacement.card));
    expect(find.byType(ZsFocusRing), paints..drrect(outer: _box.inflate(5), inner: _box.inflate(3)));
  });

  testWidgets('increased contrast: 3 px; an inside ring at −3 lies within the bounds', (tester) async {
    await tester.pumpWidget(_ring(ZsRingPlacement.inside, appearance: const ZsAppearance(increasedContrast: true)));
    expect(find.byType(ZsFocusRing), paints..drrect(outer: _box, inner: _box.deflate(3)));
    await tester.pumpWidget(_ring(ZsRingPlacement.outside, appearance: const ZsAppearance(increasedContrast: true)));
    expect(find.byType(ZsFocusRing), paints..drrect(outer: _box.inflate(5), inner: _box.inflate(2)));
  });

  testWidgets('an inactive window shows no ring (--focus-ring is transparent)', (tester) async {
    await tester.pumpWidget(_ring(ZsRingPlacement.outside, appearance: const ZsAppearance(inactive: true)));
    expect(find.byType(ZsFocusRing), isNot(paints..drrect()));
  });

  testWidgets('it settles from 3 px further out and leaves at once', (tester) async {
    await tester.pumpWidget(_ring(ZsRingPlacement.outside, visible: false));
    expect(find.byType(ZsFocusRing), isNot(paints..drrect()));
    await tester.pumpWidget(_ring(ZsRingPlacement.outside));
    await tester.pump(const Duration(milliseconds: 1));
    final double t = ZsMotion.full.easeState.transform(1 / ZsMotion.full.durFocus.inMilliseconds);
    final double at = 2 + 3 * (1 - t);
    expect(find.byType(ZsFocusRing), paints..drrect(outer: _box.inflate(at + 2), inner: _box.inflate(at)));
    await tester.pump(ZsMotion.full.durFocus);
    await tester.pumpWidget(_ring(ZsRingPlacement.outside, visible: false));
    expect(find.byType(ZsFocusRing), isNot(paints..drrect()));
  });

  testWidgets('under reduce motion the ring fades at its resting offset', (tester) async {
    const reduced = ZsAppearance(reduceMotion: true);
    await tester.pumpWidget(_ring(ZsRingPlacement.outside, visible: false, appearance: reduced));
    await tester.pumpWidget(_ring(ZsRingPlacement.outside, appearance: reduced));
    await tester.pump(const Duration(milliseconds: 40));
    expect(find.byType(ZsFocusRing), paints..drrect(outer: _box.inflate(4), inner: _box.inflate(2)));
  });
}
