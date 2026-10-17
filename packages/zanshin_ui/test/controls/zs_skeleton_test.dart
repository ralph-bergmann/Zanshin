// SPDX-License-Identifier: MIT

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
