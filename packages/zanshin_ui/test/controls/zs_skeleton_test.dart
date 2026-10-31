// SPDX-License-Identifier: MIT

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_skeleton.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

Widget _skeleton({ZsSkeletonKind kind = ZsSkeletonKind.bar, ZsAppearance appearance = const ZsAppearance()}) =>
    zsHost(ZsSkeleton(kind: kind, width: 120), appearance: appearance);

void main() {
  const ZsColors c = ZsColors.night;
  final Duration delay = ZsMotion.full.delaySkeleton;

  testWidgets('nothing is painted before --delay-skeleton, then --skeleton bars with a sweep', (tester) async {
    await tester.pumpWidget(_skeleton());
    await tester.pump(delay - const Duration(milliseconds: 1));
    expect(find.byType(CustomPaint), findsNothing);
    await tester.pump(const Duration(milliseconds: 2));
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      find.byType(ZsSkeleton),
      paints
        ..something(rrectOf(color: c.skeleton, size: const Size(120, 10)))
        ..something((method, arguments) => method == #drawRect && (arguments[1] as Paint).shader != null),
    );
  });

  test('each sweep crosses the whole bar: the band starts and ends off it, so the loop does not jump', () {
    const size = Size(120, 10);
    expect(zsSkeletonBand(size, 0, 1).right, lessThanOrEqualTo(0));
    expect(zsSkeletonBand(size, 1, 1).left, greaterThanOrEqualTo(size.width));
    expect(zsSkeletonBand(size, .5, 1).center.dx, size.width / 2);
    expect(zsSkeletonBand(size, .7, 0).right, lessThanOrEqualTo(0), reason: 'reduce motion: no sweep');
  });

  testWidgets('the card stands on --card-solid with a --border-strong edge, 240 × 62', (tester) async {
    await tester.pumpWidget(_skeleton(kind: ZsSkeletonKind.card));
    await tester.pump(delay + const Duration(milliseconds: 1));
    final Finder card = find.descendant(of: find.byType(ZsSkeleton), matching: find.byType(DecoratedBox));
    final decoration = tester.widget<DecoratedBox>(card).decoration as BoxDecoration;
    expect(decoration.color, c.cardSolid);
    expect((decoration.border! as Border).top.color, c.borderStrong);
    expect(tester.getSize(card), const Size(240, 62));
  });

  testWidgets('a row is 30 high', (tester) async {
    await tester.pumpWidget(_skeleton(kind: ZsSkeletonKind.row));
    await tester.pump(delay + const Duration(milliseconds: 1));
    expect(tester.getSize(find.byType(ZsSkeleton)).height, 30);
  });

  testWidgets('under reduce motion no sweep: the bars pulse', (tester) async {
    await tester.pumpWidget(_skeleton(appearance: const ZsAppearance(reduceMotion: true)));
    await tester.pump(delay + const Duration(milliseconds: 1));
    await tester.pump(ZsMotion.full.durShimmer ~/ 2);
    expect(
      find.byType(ZsSkeleton),
      isNot(paints..something((method, arguments) => method == #drawRect && (arguments[1] as Paint).shader != null)),
    );
    expect(
      find.byType(ZsSkeleton),
      paints..something(
        (method, arguments) =>
            method == #drawRRect && ((arguments[1] as Paint).color.a - c.skeleton.a * .55).abs() < .02,
      ),
    );
  });

  for (final motion in <double>[0, 1]) {
    testWidgets('paintZsSkeletonBar at motion $motion: the --skeleton bar, a band only with motion', (tester) async {
      await tester.pumpWidget(
        Center(
          child: CustomPaint(size: const Size(80, 9), painter: _BarPainter(motion)),
        ),
      );
      bool band(Symbol method, List<dynamic> arguments) =>
          method == #drawRect && (arguments[1] as Paint).shader != null;
      expect(find.byType(CustomPaint), paints..something(rrectOf(color: c.skeleton, size: const Size(80, 9))));
      if (motion == 0) {
        expect(find.byType(CustomPaint), isNot(paints..something(band)));
      } else {
        expect(find.byType(CustomPaint), paints..something(band));
      }
    });
  }

  testWidgets('paintZsSkeletonBar off the origin: the band lies at the rect, not at the origin', (tester) async {
    const rect = Rect.fromLTWH(30, 20, 80, 9);
    // A transparent base and an opaque highlight: the pixels show the band alone. At t .5 it peaks at the bar's centre.
    final recorder = ui.PictureRecorder();
    paintZsSkeletonBar(
      Canvas(recorder),
      rect,
      t: .5,
      base: const Color(0x00000000),
      high: const Color(0xFFFFFFFF),
      radius: 0,
      motion: 1,
    );
    final ui.Image image = recorder.endRecording().toImageSync(160, 40);
    final ByteData bytes = (await tester.runAsync<ByteData?>(image.toByteData))!;
    int alphaAt(int x, int y) => bytes.getUint8((y * 160 + x) * 4 + 3);
    expect(alphaAt(rect.center.dx.toInt(), 24), greaterThan(240), reason: 'the peak at the bar centre');
    expect(alphaAt(40, 24), lessThan(200), reason: 'an unshifted band would peak at x 40');
    image.dispose();
  });

  testWidgets('hidden from VoiceOver', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(zsHost(const ZsSkeleton(identifier: 'skeleton', width: 100)));
    await tester.pump(delay + const Duration(milliseconds: 1));
    // Marionette matches the `Semantics` widget, not the node.
    expect(
      find.byWidgetPredicate((widget) => widget is Semantics && widget.properties.identifier == 'skeleton'),
      findsOneWidget,
    );
    expect(find.semantics.byPredicate((node) => node.identifier == 'skeleton'), findsNothing);
    handle.dispose();
  });
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.motion);

  final double motion;

  @override
  void paint(Canvas canvas, Size size) => paintZsSkeletonBar(
    canvas,
    Offset.zero & size,
    // t 0 puts the pulse at full opacity, so the base colour is exact.
    t: 0,
    base: ZsColors.night.skeleton,
    high: ZsColors.night.skeletonHi,
    radius: 3,
    motion: motion,
  );

  @override
  bool shouldRepaint(_BarPainter oldDelegate) => false;
}
