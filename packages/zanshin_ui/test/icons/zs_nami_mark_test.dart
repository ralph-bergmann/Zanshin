// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_elevation.dart';
import 'package:zanshin_ui/src/icons/zs_nami_mark.dart';

import '../helpers/zs_host.dart';

/// The three waves' strokes in the 256-unit view box, at [heavy] (≤ 48 px) or the icon's.
PaintPattern _waves(PaintPattern pattern, {required bool heavy}) => pattern
  ..path(color: ZsColors.night.gold200, strokeWidth: heavy ? 13 : 9, style: PaintingStyle.stroke)
  ..path(color: ZsColors.night.gold400, strokeWidth: heavy ? 15 : 11, style: PaintingStyle.stroke)
  ..path(color: ZsColors.night.gold600, strokeWidth: heavy ? 17 : 13, style: PaintingStyle.stroke);

void main() {
  testWidgets('at 28 px: the tile with radius size × .2266, then the heavy waves 13 / 15 / 17', (tester) async {
    await tester.pumpWidget(zsHost(const ZsNamiMark()));
    final Finder mark = find.byType(ZsNamiMark);
    expect(tester.getSize(mark), const Size.square(28));
    final Rect box = Offset.zero & const Size.square(28);
    expect(
      mark,
      _waves(
        paints
          ..rrect(rrect: RRect.fromRectAndRadius(box, const Radius.circular(28 * 58 / 256)))
          ..rrect(rrect: RRect.fromRectAndRadius(box, const Radius.circular(28 * 58 / 256))),
        heavy: true,
      ),
    );
  });

  testWidgets('at 64 px the waves take the icon strokes 9 / 11 / 13', (tester) async {
    await tester.pumpWidget(zsHost(const ZsNamiMark(size: 64)));
    final Finder mark = find.byType(ZsNamiMark);
    expect(tester.getSize(mark), const Size.square(64));
    expect(
      mark,
      _waves(
        paints
          ..rrect()
          ..rrect(),
        heavy: false,
      ),
    );
  });

  for (final (ZsTheme theme, ZsElevation elevation) in <(ZsTheme, ZsElevation)>[
    (ZsTheme.night, ZsElevation.night),
    (ZsTheme.paper, ZsElevation.paper),
  ]) {
    testWidgets('a chip carries --shadow-mark in ${theme.name} (back part first); a bare mark none', (tester) async {
      final List<BoxShadow> parts = elevation.shadowMark.boxShadows;
      expect(parts, hasLength(2));
      await tester.pumpWidget(zsHost(const ZsNamiMark(chip: true), appearance: ZsAppearance(theme: theme)));
      final Finder mark = find.byType(ZsNamiMark);
      final tile = RRect.fromRectAndRadius(Offset.zero & const Size.square(28), const Radius.circular(28 * 58 / 256));
      expect(
        mark,
        paints
          ..rrect(rrect: tile.shift(parts[1].offset).inflate(parts[1].spreadRadius), color: parts[1].color)
          ..rrect(rrect: tile.shift(parts[0].offset).inflate(parts[0].spreadRadius), color: parts[0].color)
          ..rrect(rrect: tile),
      );

      await tester.pumpWidget(zsHost(const ZsNamiMark(), appearance: ZsAppearance(theme: theme)));
      expect(mark, isNot(paints..rrect(color: parts[1].color)));
    });
  }

  testWidgets('a box forced wider than tall keeps the square tile, centred', (tester) async {
    await tester.pumpWidget(zsHost(const SizedBox(width: 40, height: 28, child: ZsNamiMark())));
    expect(tester.getSize(find.byType(ZsNamiMark)), const Size(40, 28));
    expect(
      find.byType(ZsNamiMark),
      paints..rrect(
        rrect: RRect.fromRectAndRadius(const Rect.fromLTWH(6, 0, 28, 28), const Radius.circular(28 * 58 / 256)),
      ),
    );
  });

  testWidgets('a mark of size 0 paints nothing', (tester) async {
    await tester.pumpWidget(zsHost(const ZsNamiMark(size: 0, chip: true)));
    expect(tester.getSize(find.byType(ZsNamiMark)), Size.zero);
    expect(find.byType(ZsNamiMark), paintsNothing);
  });

  testWidgets('VoiceOver reads the image "Zanshin"; the box reports its size as its intrinsic width', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(zsHost(const ZsNamiMark(size: 40)));
    expect(tester.getSemantics(find.byType(ZsNamiMark)), isSemantics(label: 'Zanshin', isImage: true));
    final RenderBox box = tester.renderObject(find.byType(ZsNamiMark));
    expect(box.getMaxIntrinsicWidth(double.infinity), 40);
    expect(box.getMinIntrinsicHeight(double.infinity), 40);
    handle.dispose();
  });
}
