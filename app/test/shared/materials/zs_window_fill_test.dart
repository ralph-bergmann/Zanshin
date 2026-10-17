// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_values.dart';
import 'package:zanshin/src/shared/materials/zs_sheet.dart';
import 'package:zanshin/src/shared/materials/zs_surface.dart';
import 'package:zanshin/src/shared/materials/zs_window_fill.dart';

import '../../helpers/material_paints.dart';
import '../../helpers/zs_host.dart';

void main() {
  for (final appearance in const <ZsAppearance>[
    ZsAppearance(),
    ZsAppearance(reduceTransparency: true),
    ZsAppearance(theme: ZsTheme.paper),
    ZsAppearance(theme: ZsTheme.paper, reduceTransparency: true),
    ZsAppearance(increasedContrast: true),
    ZsAppearance(theme: ZsTheme.paper, increasedContrast: true),
  ]) {
    testWidgets('the window fill paints the sheen over --fl-bg-solid edge to edge, $appearance', (tester) async {
      await tester.pumpWidget(
        zsHost(const ZsWindowFill(child: SizedBox.expand()), appearance: appearance, group: false),
      );
      final ZsColors colors = appearance.theme == ZsTheme.night ? ZsColors.night : ZsColors.paper;
      final Finder fill = find.byType(ZsSurface);
      final box = RRect.fromRectAndRadius(Offset.zero & const Size(800, 600), Radius.zero);
      expect(tester.getRect(fill), Offset.zero & const Size(800, 600));
      expect(
        fill,
        paints
          ..rrect(rrect: box, color: colors.flBgSolid)
          ..something(isSheen(box)),
      );
      expect(fill, isNot(paints..drrect()), reason: 'no border');
      expect(fill, isNot(paints..clipPath()), reason: 'no shadow');
      expect(fill, isNot(paints..path()), reason: 'no highlight');
      expect(find.byType(BackdropFilter), findsNothing);
    });
  }

  testWidgets('over the window fill, the only backdrop filter is the sheet scrim at sigma 12', (tester) async {
    await tester.pumpWidget(
      zsHost(
        SizedBox.expand(
          child: Stack(
            children: <Widget>[
              const ZsWindowFill(child: SizedBox.expand()),
              ZsSheet(
                semanticLabel: 'Discard changes?',
                onCancel: () {},
                child: const SizedBox(width: 300, height: 120),
              ),
            ],
          ),
        ),
        group: false,
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter,
      const ZsGlassFilter(blur: 12, saturate: 1.2).toImageFilter(),
    );
  });

  testWidgets('the window fill shows the arrow cursor over a grab region', (tester) async {
    await tester.pumpWidget(
      zsHost(
        const MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: ZsWindowFill(child: SizedBox.expand()),
        ),
        group: false,
      ),
    );
    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await gesture.addPointer(location: const Offset(400, 300));
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.basic);
  });
}
