// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_elevation.dart';
import 'package:zanshin_ui/src/design/zs_values.dart';
import 'package:zanshin_ui/src/materials/zs_fade.dart';
import 'package:zanshin_ui/src/materials/zs_glass.dart';
import 'package:zanshin_ui/src/materials/zs_menu_material.dart';
import 'package:zanshin_ui/src/materials/zs_surface.dart';

import '../helpers/material_paints.dart';
import '../helpers/zs_host.dart';

/// A stateful probe that counts its own `initState`s, so a test sees whether the content kept its state.
class _Probe extends StatefulWidget {
  const _Probe();

  static var inits = 0;

  @override
  State<_Probe> createState() => _ProbeState();
}

class _ProbeState extends State<_Probe> {
  @override
  void initState() {
    super.initState();
    _Probe.inits++;
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 100, height: 40);
}

Widget _faded(double opacity, {ZsAppearance appearance = const ZsAppearance()}) => zsHost(
  ZsFade(
    opacity: opacity,
    child: const ZsGlass(radius: 14, child: _Probe()),
  ),
  appearance: appearance,
);

/// Matches one outer shadow part drawn at [fade] times its alpha.
PaintPatternPredicate _fadedDrop(RRect outer, ZsShadow part, double fade) {
  final BoxShadow shadow = part.toBoxShadow();
  final RRect bounds = outer.shift(shadow.offset).inflate(shadow.spreadRadius);
  return (method, arguments) {
    if (method != #drawRRect || arguments[0] != bounds) {
      return false;
    }
    final Color color = (arguments[1] as Paint).color;
    return (color.a - part.color.a * fade).abs() < 1e-3 && (color.r - part.color.r).abs() < 1e-3;
  };
}

void main() {
  testWidgets('of is 1 without a fade, and nested fades multiply', (tester) async {
    late double outside;
    late double nested;
    await tester.pumpWidget(
      Column(
        children: <Widget>[
          Builder(
            builder: (context) {
              outside = ZsFade.of(context);
              return const SizedBox.shrink();
            },
          ),
          ZsFade(
            opacity: .5,
            child: ZsFade(
              opacity: .4,
              child: Builder(
                builder: (context) {
                  nested = ZsFade.of(context);
                  return const SizedBox.shrink();
                },
              ),
            ),
          ),
        ],
      ),
    );
    expect(outside, 1);
    expect(nested, closeTo(.2, 1e-9));
  });

  testWidgets('a change to an outer fade rebuilds what reads it', (tester) async {
    final seen = <double>[];
    Widget tree(double outer) => ZsFade(
      opacity: outer,
      child: ZsFade(
        opacity: .5,
        child: Builder(
          builder: (context) {
            seen.add(ZsFade.of(context));
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    await tester.pumpWidget(tree(1));
    await tester.pumpWidget(tree(.5));
    expect(seen, <double>[.5, .25]);
  });

  testWidgets('glass at .5 fades its blur through the filter alpha, its box through an Opacity inside the filter', (
    tester,
  ) async {
    await tester.pumpWidget(_faded(.5));
    final Finder filter = find.byType(BackdropFilter);
    final double fill = ZsColors.night.flBg.a;
    const a = .5;
    expect(
      tester.widget<BackdropFilter>(filter).filter,
      const ZsGlassFilter(blur: 18, saturate: 1.4).toImageFilter(alpha: a * (1 - fill) / (1 - a * fill)),
    );
    final Finder box = find.descendant(of: filter, matching: find.byType(Opacity));
    expect(box, findsOneWidget);
    expect(tester.widget<Opacity>(box).opacity, a);
    expect(find.ancestor(of: filter, matching: find.byType(Opacity)), findsNothing);
    expect(find.ancestor(of: filter, matching: find.byType(FadeTransition)), findsNothing);

    final RRect outer = outerShape(tester.getSize(find.byType(ZsSurface)), 14);
    final PaintPattern drops = paints;
    for (final ZsShadow part in ZsElevation.night.flShadow.parts.where((part) => !part.inset)) {
      drops.something(_fadedDrop(outer, part, a));
    }
    expectWithShadows(find.byType(ZsSurface), drops);
  });

  testWidgets('at opacity 0 the subtree holds no BackdropFilter, and the content keeps its state both ways', (
    tester,
  ) async {
    _Probe.inits = 0;
    await tester.pumpWidget(_faded(1));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.byType(Opacity), findsNothing, reason: 'an unfaded surface adds no Opacity');
    await tester.pumpWidget(_faded(0));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0);
    await tester.pumpWidget(_faded(.5));
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(_Probe.inits, 1);
  });

  testWidgets('under reduce transparency the solid box fades by the same Opacity', (tester) async {
    await tester.pumpWidget(_faded(.5, appearance: const ZsAppearance(reduceTransparency: true)));
    expect(find.byType(BackdropFilter), findsNothing);
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, .5);
  });

  testWidgets('the menu material fades by its Opacity too', (tester) async {
    await tester.pumpWidget(
      zsHost(
        const ZsFade(
          opacity: .25,
          child: ZsMenuMaterial(child: SizedBox(width: 100, height: 40)),
        ),
      ),
    );
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, .25);
  });
}
