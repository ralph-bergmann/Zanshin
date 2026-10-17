// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_elevation.dart';
import 'package:zanshin/src/shared/design/zs_values.dart';
import 'package:zanshin/src/shared/materials/zs_menu_material.dart';
import 'package:zanshin/src/shared/materials/zs_surface.dart';

import '../../helpers/material_paints.dart';
import '../../helpers/zs_host.dart';

const _box = Size(290, 120);

void main() {
  for (final ZsTheme theme in ZsTheme.values) {
    final ZsColors colors = theme == ZsTheme.night ? ZsColors.night : ZsColors.paper;
    final ZsElevation elevation = theme == ZsTheme.night ? ZsElevation.night : ZsElevation.paper;

    for (final arrow in <bool>[false, true]) {
      testWidgets('the menu material paints the DS values on ${theme.name}${arrow ? ', with the arrow' : ''}', (
        tester,
      ) async {
        await tester.pumpWidget(
          zsHost(
            ZsMenuMaterial(
              arrow: arrow,
              child: SizedBox(width: _box.width - 2, height: _box.height - 2),
            ),
            appearance: ZsAppearance(theme: theme),
          ),
        );
        final Finder surface = find.byType(ZsSurface);
        expect(tester.getSize(surface), _box);
        expect(find.byType(BackdropFilter), findsNothing);
        expect(elevation.shadowMenu.inset, isEmpty, reason: 'the menu material has no highlight');
        final RRect outer = outerShape(_box, 13);
        expectWithShadows(
          surface,
          surfacePaints(
            outer: outer,
            fill: colors.flBgSolid,
            border: colors.flBorder,
            drops: elevation.shadowMenu.parts,
          ),
        );
        if (arrow) {
          // The diamond's tip at (−7.07, 22); its two outer edges, half a pixel in, in --fl-border.
          expect(
            surface,
            paints
              ..drrect()
              ..path(
                color: colors.flBgSolid,
                includes: const <Offset>[Offset(-6.9, 22), Offset(0, 15.2), Offset(0, 28.8), Offset(6.9, 22)],
                excludes: const <Offset>[Offset(-7.3, 22), Offset(0, 14.7), Offset(0, 29.3)],
              )
              ..path(
                color: colors.flBorder,
                includes: const <Offset>[Offset(-3.18, 18.82), Offset(-3.18, 25.18), Offset(-6.9, 22)],
                excludes: const <Offset>[Offset(0, 22), Offset(3.18, 18.82), Offset(3.18, 25.18)],
              ),
          );
        } else {
          expect(surface, isNot(paints..path()));
        }
      });
    }
  }

  testWidgets('the arrow takes no shadow beneath it', (tester) async {
    await tester.pumpWidget(zsHost(const ZsMenuMaterial(arrow: true, child: SizedBox(width: 288, height: 118))));
    expect(
      find.byType(ZsSurface),
      paints..clipPath(
        pathMatcher: isPathThat(
          includes: const <Offset>[Offset(-20, 22), Offset(145, 130)],
          excludes: const <Offset>[Offset(-6, 22), Offset(145, 60)],
        ),
      ),
    );
  });

  testWidgets('the menu material keeps its padding inside the border', (tester) async {
    await tester.pumpWidget(
      zsHost(
        const ZsMenuMaterial(
          padding: EdgeInsets.all(5),
          child: SizedBox(key: Key('row'), width: 240, height: 30),
        ),
      ),
    );
    expect(tester.getSize(find.byType(ZsSurface)), const Size(252, 42));
    expect(
      tester.getTopLeft(find.byKey(const Key('row'))) - tester.getTopLeft(find.byType(ZsSurface)),
      const Offset(6, 6),
    );
  });

  testWidgets('the menu material shows the arrow cursor over a grab region', (tester) async {
    await tester.pumpWidget(
      zsHost(
        const MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: SizedBox.expand(
            child: Center(child: ZsMenuMaterial(child: SizedBox(width: 200, height: 100))),
          ),
        ),
      ),
    );
    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await gesture.addPointer(location: tester.getCenter(find.byType(ZsSurface)));
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.basic);
  });

  testWidgets('text and icons on a material default to --text, not the colour around it', (tester) async {
    late BuildContext probe;
    await tester.pumpWidget(
      zsHost(
        DefaultTextStyle.merge(
          style: TextStyle(color: ZsColors.night.textFaint),
          child: IconTheme.merge(
            data: IconThemeData(color: ZsColors.night.textFaint),
            child: ZsMenuMaterial(
              child: Builder(
                builder: (context) {
                  probe = context;
                  return const Text('Row');
                },
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.widget<RichText>(find.byType(RichText)).text.style?.color, ZsColors.night.text);
    expect(IconTheme.of(probe).color, ZsColors.night.text);
  });

  test('the menu material tokens are the DS values', () {
    expect(
      ZsElevation.night.shadowMenu,
      const ZsShadowStack(<ZsShadow>[
        ZsShadow(dx: 0, dy: 24, blur: 60, spread: -16, color: Color.fromRGBO(0, 0, 0, .6)),
        ZsShadow(dx: 0, dy: 2, blur: 8, spread: 0, color: Color.fromRGBO(0, 0, 0, .2)),
      ]),
    );
    expect(ZsColors.night.flBgSolid, const Color(0xFF1A1F35));
    expect(ZsColors.paper.flBgSolid, const Color(0xFFFFFDFA));
  });
}
