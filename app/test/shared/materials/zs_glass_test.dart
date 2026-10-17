// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_elevation.dart';
import 'package:zanshin/src/shared/design/zs_values.dart';
import 'package:zanshin/src/shared/materials/zs_glass.dart';
import 'package:zanshin/src/shared/materials/zs_sheet.dart';
import 'package:zanshin/src/shared/materials/zs_surface.dart';

import '../../helpers/material_paints.dart';
import '../../helpers/zs_host.dart';

/// One glass build of the DS and what it should paint around a child.
typedef _Glass = ({String name, Widget Function(Widget child) build, Size size, double radius, bool strong});

/// The six glass builds: the four island shapes, the minimap and the toast, around children whose boxes give
/// their sizes. The radius tokens are 14 (island), 16 (panel) and 999 (pill, clamped to 18 on the 36 px toast).
final _glasses = <_Glass>[
  (
    name: 'bar',
    build: (child) => ZsIsland(child: child),
    // 100 + 2 × (1 border + 4 padding) wide, --chrome-h high.
    size: const Size(110, 44),
    radius: 14,
    strong: false,
  ),
  (
    name: 'rail',
    build: (child) => ZsIsland(shape: ZsIslandShape.rail, child: child),
    // 100 × 40 + 2 × (1 + 5).
    size: const Size(112, 52),
    radius: 16,
    strong: false,
  ),
  (
    name: 'panel',
    build: (child) => ZsIsland(shape: ZsIslandShape.panel, child: child),
    size: const Size(102, 42),
    radius: 16,
    strong: true,
  ),
  (
    name: 'free',
    build: (child) => ZsIsland(shape: ZsIslandShape.free, child: child),
    size: const Size(102, 42),
    radius: 14,
    strong: false,
  ),
  (
    name: 'minimap',
    build: (child) => ZsGlass(fill: ZsGlassFill.strong, blur: ZsGlassBlur.strong, radius: 14, child: child),
    size: const Size(102, 42),
    radius: 14,
    strong: true,
  ),
  (
    name: 'toast',
    build: (child) => ZsGlass(fill: ZsGlassFill.strong, radius: 999, child: child),
    // A 34 px child in a 1 px border: the 36 px --control-lg pill.
    size: const Size(102, 36),
    radius: 18,
    strong: true,
  ),
];

Widget _content(String name) => SizedBox(
  width: 100,
  height: switch (name) {
    'toast' => 34,
    'bar' => 20,
    _ => 40,
  },
);

/// The descendant [T] widget of the widget keyed [name].
T _inside<T extends Widget>(WidgetTester tester, String name) =>
    tester.widget<T>(find.descendant(of: find.byKey(ValueKey<String>(name)), matching: find.byType(T)));

ImageFilter _glassFilter(double sigma) => ImageFilter.compose(
  outer: ColorFilter.matrix(ZsGlassFilter.saturateMatrix(1.4)),
  inner: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
);

/// Every glass build, keyed by name, plus a sheet over them, with a [_Probe] in the bar and in the sheet.
Widget _everything(ZsAppearance appearance) => zsHost(
  SizedBox.expand(
    child: Stack(
      children: <Widget>[
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: <Widget>[
            for (final _Glass glass in _glasses)
              KeyedSubtree(
                key: ValueKey<String>(glass.name),
                child: glass.build(glass.name == 'bar' ? const _Probe() : _content(glass.name)),
              ),
          ],
        ),
        ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: const _Probe()),
      ],
    ),
  ),
  appearance: appearance,
);

/// A stateful leaf, to prove that content keeps its state when the glass turns solid and back.
class _Probe extends StatefulWidget {
  const _Probe();

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  Widget build(BuildContext context) => const SizedBox(width: 100, height: 20);
}

void main() {
  for (final ZsTheme theme in ZsTheme.values) {
    final ZsColors colors = theme == ZsTheme.night ? ZsColors.night : ZsColors.paper;
    final ZsElevation elevation = theme == ZsTheme.night ? ZsElevation.night : ZsElevation.paper;
    for (final _Glass glass in _glasses) {
      testWidgets('${glass.name} glass paints the DS values on ${theme.name}', (tester) async {
        await tester.pumpWidget(
          zsHost(glass.build(_content(glass.name)), appearance: ZsAppearance(theme: theme)),
        );
        final Finder surface = find.byType(ZsSurface);
        expect(tester.getSize(surface), glass.size);
        final Color fill = glass.strong ? colors.flBgStrong : colors.flBg;
        final RRect outer = outerShape(glass.size, glass.radius);
        // The blur is bounded by the clamped shape.
        expect(
          surface,
          paints
            ..clipRRect(rrect: outer)
            ..rrect(rrect: outer, color: fill),
        );
        final [ZsShadow highlight, ZsShadow drop, ZsShadow ambient] = elevation.flShadow.parts;
        expectWithShadows(
          surface,
          surfacePaints(
            outer: outer,
            fill: fill,
            border: colors.flBorder,
            inset: highlight,
            drops: <ZsShadow>[drop, ambient],
          ),
        );
        if (glass.name == 'panel') {
          // The panel clips its content inside the border, after painting the border.
          expect(
            surface,
            paints
              ..drrect()
              ..clipRRect(rrect: outerShape(glass.size, glass.radius).deflate(1)),
          );
        }
      });
    }

    test('the glass tokens on ${theme.name} are the DS values', () {
      final night = theme == ZsTheme.night;
      expect(colors.flBg, night ? const Color.fromRGBO(26, 31, 56, .66) : const Color.fromRGBO(255, 253, 250, .74));
      expect(
        colors.flBgStrong,
        night ? const Color.fromRGBO(24, 29, 52, .86) : const Color.fromRGBO(255, 253, 250, .9),
      );
      expect(elevation.flShadow.inset.single.color, Color.fromRGBO(255, 255, 255, night ? .05 : .8));
      final BoxShadow drop = elevation.flShadow.boxShadows.first;
      if (night) {
        expect(drop.offset, const Offset(0, 14));
        expect(drop.spreadRadius, -12);
        expect(drop.blurRadius, closeTo(30.31, .005));
        expect(drop.blurSigma, closeTo(18, 1e-9));
      }
    });
  }

  testWidgets('a toast pill on a 36 px box clamps its radius to 18 and its inner radius to 17', (tester) async {
    await tester.pumpWidget(zsHost(_glasses.last.build(_content('toast'))));
    expect(
      find.byType(ZsSurface),
      paints..drrect(
        outer: outerShape(const Size(102, 36), 18),
        inner: RRect.fromLTRBR(1, 1, 101, 35, const Radius.circular(17)),
      ),
    );
  });

  testWidgets('a bar centres its content vertically inside the border and the 4 px padding', (tester) async {
    await tester.pumpWidget(zsHost(const ZsIsland(child: SizedBox(key: Key('content'), width: 100, height: 20))));
    expect(
      tester.getTopLeft(find.byKey(const Key('content'))) - tester.getTopLeft(find.byType(ZsSurface)),
      const Offset(5, 12),
    );
  });

  testWidgets('grouped glass blurs at sigma 18 or 22 with saturate 1.4 and shares the window group', (tester) async {
    await tester.pumpWidget(_everything(const ZsAppearance()));
    for (final _Glass glass in _glasses) {
      final double sigma = glass.name == 'panel' || glass.name == 'minimap' ? 22 : 18;
      expect(_inside<BackdropFilter>(tester, glass.name).filter, _glassFilter(sigma), reason: glass.name);
    }
    expect(
      _inside<ZsSurface>(tester, 'toast').fill,
      ZsColors.night.flBgStrong,
      reason: 'the toast keeps the strong fill',
    );
    final keys = <BackdropKey?>[
      for (final String name in <String>['bar', 'rail', 'free'])
        tester
            .renderObject<RenderBackdropFilter>(
              find.descendant(of: find.byKey(ValueKey<String>(name)), matching: find.byType(BackdropFilter)),
            )
            .backdropKey,
    ];
    expect(keys.first, isNotNull);
    expect(keys.toSet(), hasLength(1));
  });

  testWidgets('glass without a backdrop group still blurs, ungrouped', (tester) async {
    await tester.pumpWidget(zsHost(ZsIsland(child: _content('bar')), group: false));
    expect(tester.widget<BackdropFilter>(find.byType(BackdropFilter)).filter, _glassFilter(18));
    expect(tester.renderObject<RenderBackdropFilter>(find.byType(BackdropFilter)).backdropKey, isNull);
  });

  testWidgets('glass inside glass fails an assertion', (tester) async {
    await tester.pumpWidget(zsHost(ZsIsland(child: ZsGlass(radius: 4, child: _content('free')))));
    expect(tester.takeException(), isAssertionError);
  });

  for (final ZsTheme theme in ZsTheme.values) {
    final night = theme == ZsTheme.night;
    for (final (String flag, ZsAppearance solid, Color scrim, Color border) in <(String, ZsAppearance, Color, Color)>[
      (
        'reduce transparency',
        ZsAppearance(theme: theme, reduceTransparency: true),
        night ? const Color.fromRGBO(7, 9, 20, .62) : const Color.fromRGBO(58, 46, 34, .28),
        night ? ZsColors.night.flBorder : ZsColors.paper.flBorder,
      ),
      (
        'increased contrast',
        ZsAppearance(theme: theme, increasedContrast: true),
        night ? const Color.fromRGBO(7, 9, 20, .7) : const Color.fromRGBO(58, 46, 34, .36),
        night ? const Color(0xFF78809C) : const Color(0xFF867E75),
      ),
    ]) {
      testWidgets('$flag on ${theme.name} paints every glass solid, and switching it at runtime swaps both ways', (
        tester,
      ) async {
        final ZsColors base = night ? ZsColors.night : ZsColors.paper;
        final translucent = ZsAppearance(theme: theme);

        Future<void> expectSolid({required bool solidNow}) async {
          await tester.pumpAndSettle();
          final Color scrimNow = tester
              .widget<ColoredBox>(find.descendant(of: find.byType(ZsSheet), matching: find.byType(ColoredBox)))
              .color;
          if (solidNow) {
            expect(find.byType(BackdropFilter), findsNothing);
            expect(
              find.byType(ClipRRect),
              findsNothing,
              reason: 'no clip unless the shape clips (the panel clips inside)',
            );
            expect(scrimNow, scrim);
          } else {
            expect(find.byType(BackdropFilter), findsNWidgets(_glasses.length + 1), reason: 'six glass + the scrim');
            expect(scrimNow, base.scrim);
          }
          for (final _Glass glass in _glasses) {
            final ZsSurface surface = _inside<ZsSurface>(tester, glass.name);
            final Color translucentFill = glass.strong ? base.flBgStrong : base.flBg;
            final Color fillNow = solidNow ? base.flBgSolid : translucentFill;
            final Color borderNow = solidNow ? border : base.flBorder;
            expect(surface.fill, fillNow, reason: glass.name);
            expect(surface.border, borderNow, reason: glass.name);
            expect(surface.filter, solidNow ? isNull : isNotNull, reason: glass.name);
            // What the render box paints, not only what the widget holds.
            expect(
              find.descendant(of: find.byKey(ValueKey<String>(glass.name)), matching: find.byType(ZsSurface)),
              paints
                ..rrect(rrect: outerShape(glass.size, glass.radius), color: fillNow)
                ..drrect(color: borderNow),
              reason: glass.name,
            );
          }
        }

        await tester.pumpWidget(_everything(solid));
        await expectSolid(solidNow: true);
        final List<State> probes = tester.stateList(find.byType(_Probe)).toList();
        expect(probes, hasLength(2));

        await tester.pumpWidget(_everything(translucent));
        await expectSolid(solidNow: false);
        await tester.pumpWidget(_everything(solid));
        await expectSolid(solidNow: true);
        expect(tester.stateList(find.byType(_Probe)).toList(), probes, reason: 'the content kept its state');
      });
    }
  }

  test('the island shapes carry the DS gaps', () {
    expect(<double>[for (final ZsIslandShape shape in ZsIslandShape.values) shape.gap], <double>[2, 4, 0, 2]);
  });

  testWidgets('a separator is a 1 x 20 --fl-border line in 4 px margins', (tester) async {
    await tester.pumpWidget(zsHost(const ZsIslandSeparator()));
    expect(tester.getSize(find.byType(ZsIslandSeparator)), const Size(9, 20));
    expect(
      find.byType(ZsIslandSeparator),
      paints..rect(rect: const Rect.fromLTWH(4, 0, 1, 20), color: ZsColors.night.flBorder),
    );
  });

  testWidgets('glass shows the arrow cursor over a grab region, and its rounded corners let the region through', (
    tester,
  ) async {
    await tester.pumpWidget(
      zsHost(
        MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: SizedBox.expand(
            child: Center(child: ZsIsland(child: _content('bar'))),
          ),
        ),
      ),
    );
    final Rect island = tester.getRect(find.byType(ZsSurface));
    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await gesture.addPointer(location: island.center);
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.basic);
    await gesture.moveTo(island.topLeft + const Offset(1, 1));
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.grab);
  });

  testWidgets('glass is a semantics container', (tester) async {
    await tester.pumpWidget(zsHost(ZsIsland(child: _content('bar'))));
    expect(
      tester.widget<Semantics>(find.descendant(of: find.byType(ZsSurface), matching: find.byType(Semantics)).first),
      isA<Semantics>().having((semantics) => semantics.container, 'container', isTrue),
    );
  });
}
