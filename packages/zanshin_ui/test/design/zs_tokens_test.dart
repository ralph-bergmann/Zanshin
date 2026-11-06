// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:typed_data' show ByteData;

import 'package:flutter/services.dart' show FontLoader;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show AccentSource;
import 'package:zanshin_shell/zanshin_shell.dart' show ShellTheme;
import 'package:zanshin_ui/src/design/zs_accents.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_elevation.dart';
import 'package:zanshin_ui/src/design/zs_metrics.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/design/zs_type.dart';
import 'package:zanshin_ui/src/design/zs_values.dart';

const _accentNames = <String>[
  '--accent',
  '--accent-ink',
  '--accent-line',
  '--accent-text',
  '--accent-soft',
  '--accent-soft-hi',
  '--accent-ring',
  '--accent-select',
  '--accent-live-line',
  '--accent-live-ring',
  '--accent-live-text',
];

ShellTheme _shell({int? appleAccentColor, Color accentColor = const Color(0xFF007AFF)}) =>
    ShellTheme(brightness: Brightness.dark, accentColor: accentColor, appleAccentColor: appleAccentColor);

ZsAccentFamily _family({AccentSource source = AccentSource.followMacOS, ShellTheme? shell}) =>
    ZsAccentFamily.resolve(source: source, shell: shell);

void main() {
  group('of(context) without a window root', () {
    testWidgets('falls back to night, the standard metrics, full motion and the default appearance', (tester) async {
      late BuildContext probe;
      await tester.pumpWidget(
        Builder(
          builder: (context) {
            probe = context;
            return const SizedBox.shrink();
          },
        ),
      );
      expect(ZsColors.of(probe), same(ZsColors.night));
      expect(ZsElevation.of(probe), same(ZsElevation.night));
      expect(ZsMetrics.of(probe), ZsMetrics.standard);
      expect(ZsMotion.of(probe), ZsMotion.full);
      expect(ZsAppearance.maybeOf(probe), isNull);
      expect(ZsAppearance.of(probe), const ZsAppearance());
    });
  });

  group('lerp', () {
    test('a colour and a shadow reach the midpoint between night and paper', () {
      final ZsColors colors = ZsColors.night.lerp(ZsColors.paper, .5);
      expect(colors.cardSolid, Color.lerp(const Color(0xFF1A1F35), const Color(0xFFFFFDFA), .5));
      final ZsElevation elevation = ZsElevation.night.lerp(ZsElevation.paper, .5);
      final ZsShadow dialog = elevation.shadowDialog.parts.first;
      expect(dialog.dy, 40);
      expect(dialog.blur, 100);
      expect(dialog.spread, -26);
      expect(dialog.color, Color.lerp(const Color.fromRGBO(0, 0, 0, .72), const Color.fromRGBO(58, 46, 34, .34), .5));
    });

    test('two accent families reach the midpoint', () {
      final blue = ZsColors.resolve(const ZsAppearance(family: ZsAccentFamily.blue));
      final purple = ZsColors.resolve(const ZsAppearance(family: ZsAccentFamily.purple));
      expect(blue.lerp(purple, .5).accent, Color.lerp(const Color(0xFF67AFFD), const Color(0xFFD491DF), .5));
      expect(blue.lerp(null, .5), same(blue));
    });

    test('shadow lists of different lengths fade the extra part', () {
      const one = ZsShadowStack(<ZsShadow>[
        ZsShadow(dx: 0, dy: 0, blur: 0, spread: 3, color: Color(0xFF000000)),
      ]);
      final mid = ZsShadowStack.lerp(one, ZsElevation.night.shadowDrag, .5);
      expect(mid.parts, hasLength(2));
      expect(mid.parts.last.color.a, closeTo(.3, 1e-9));
    });
  });

  group('accent families', () {
    test('every family has 11 accent tokens per theme', () {
      for (final ZsAccentFamily family in ZsAccentFamily.values) {
        for (final ZsTheme theme in ZsTheme.values) {
          expect(family.tokensIn(theme).toCss().keys, _accentNames, reason: '${family.name} on ${theme.name}');
        }
      }
      expect(ZsAccentFamily.multicolor.tokensIn(ZsTheme.night).accent, const Color(0xFFAEBCEC));
      expect(ZsAccentFamily.multicolor.tokensIn(ZsTheme.paper).accent, const Color(0xFF4757A1));
      expect(ZsAccents.native, const Color(0xFF4757A1));
      expect(ZsAccents.nativeDark, const Color(0xFF5162AD));
    });

    test('--proj-stale exists in night and paper', () {
      expect(ZsColors.night.toCss()['--proj-stale'], const Color(0xFF22D3EE));
      expect(ZsColors.paper.toCss()['--proj-stale'], const Color(0xFF0E7490));
    });

    test('the I/O matrix picks the family', () {
      expect(_family(source: AccentSource.zanshin, shell: _shell(appleAccentColor: 4)), ZsAccentFamily.multicolor);
      expect(_family(), ZsAccentFamily.multicolor, reason: 'no shell yet');
      const named = <int, ZsAccentFamily>{
        -1: ZsAccentFamily.graphite,
        0: ZsAccentFamily.red,
        1: ZsAccentFamily.orange,
        2: ZsAccentFamily.yellow,
        3: ZsAccentFamily.green,
        4: ZsAccentFamily.blue,
        5: ZsAccentFamily.purple,
        6: ZsAccentFamily.pink,
      };
      for (final MapEntry<int, ZsAccentFamily>(:key, :value) in named.entries) {
        expect(
          _family(
            shell: _shell(appleAccentColor: key, accentColor: const Color(0xFF4757A1)),
          ),
          value,
        );
      }
      expect(_family(shell: _shell(accentColor: const Color(0xFF4757A1))), ZsAccentFamily.multicolor);
      expect(_family(shell: _shell(accentColor: const Color(0xFFF7821B))), ZsAccentFamily.orange);
      expect(
        _family(shell: _shell(appleAccentColor: 9, accentColor: const Color(0xFF4757A1))),
        ZsAccentFamily.multicolor,
        reason: 'an unknown key is treated as absent',
      );
      expect(_family(shell: _shell(appleAccentColor: 9, accentColor: const Color(0xFFF7821B))), ZsAccentFamily.orange);
    });

    test('"This Mac" maps a colour to the family of the nearest macOS hue anchor', () {
      const anchors = <int, ZsAccentFamily>{
        0xFFFF5257: ZsAccentFamily.red,
        0xFFF7821B: ZsAccentFamily.orange,
        0xFFFFC600: ZsAccentFamily.yellow,
        0xFF62BA46: ZsAccentFamily.green,
        0xFF007AFF: ZsAccentFamily.blue,
        0xFFA550A7: ZsAccentFamily.purple,
        0xFFF74F9E: ZsAccentFamily.pink,
        0xFF8C8C8C: ZsAccentFamily.graphite,
      };
      for (final MapEntry<int, ZsAccentFamily>(:key, :value) in anchors.entries) {
        expect(ZsAccentFamily.fromHue(Color(key)), value, reason: key.toRadixString(16));
      }
    });
  });

  group('type roles', () {
    test('every role carries the DS size, weight, line height and letter spacing', () {
      const expected = <String, (double, int, double, double)>{
        '--type-inspector-title': (18, 600, 1.3, ZsType.trackingTitle * 18),
        '--type-dialog-title': (17, 600, 1.3, ZsType.trackingDialog * 17),
        '--type-panel-title': (15, 600, 1.35, 0),
        '--type-card-subject': (13, 500, 1.35, 0),
        '--type-body': (13, 400, 1.55, 0),
        '--type-control': (12.5, 500, 1, 0),
        '--type-secondary': (12, 400, 1.5, 0),
        '--type-meta': (11, 400, 1.35, 0),
        '--type-caps': (10.5, 600, 1.2, ZsType.trackingCaps * 10.5),
        '--type-id': (11.5, 400, 1.35, 0),
        '--type-command': (12, 400, 1.35, 0),
        '--type-code': (11, 400, 1.65, 0),
      };
      expect(ZsType.roles.keys, expected.keys);
      for (final MapEntry<String, (double, int, double, double)>(:key, :value) in expected.entries) {
        final TextStyle style = ZsType.roles[key]!;
        final (double size, int weight, double height, double letterSpacing) = value;
        expect(style.fontSize, size, reason: key);
        expect(style.fontWeight, FontWeight.values.firstWhere((w) => w.value == weight), reason: key);
        expect(style.fontVariations, <FontVariation>[FontVariation.weight(weight.toDouble())], reason: key);
        expect(style.height, height, reason: key);
        expect(style.leadingDistribution, TextLeadingDistribution.even, reason: key);
        expect(style.letterSpacing, letterSpacing, reason: key);
        expect(style.color, isNull, reason: key);
        final bool mono = const <String>{'--type-id', '--type-command', '--type-code'}.contains(key);
        expect(style.fontFamily, mono ? 'packages/zanshin_ui/JetBrainsMono' : 'packages/zanshin_ui/Inter', reason: key);
        expect(style.fontFamilyFallback, mono ? <String>['packages/zanshin_ui/Inter'] : isNull, reason: key);
      }
      expect(ZsType.caps('Bookmarks'), 'BOOKMARKS');
      expect(ZsType.kanjiFamily, 'packages/zanshin_ui/ShipporiMincho');
    });

    test('the variable Inter font applies the weight axis: a 600 line is wider than a 400 line', () async {
      final loader = FontLoader(ZsType.sansFamily)
        ..addFont(
          File(
            'assets/fonts/Inter/Inter-VariableFont_opsz,wght.ttf',
          ).readAsBytes().then(ByteData.sublistView),
        );
      await loader.load();
      double width(TextStyle style) {
        final painter = TextPainter(
          text: TextSpan(text: 'Zanshin keeps watch over the graph', style: style),
          textDirection: TextDirection.ltr,
        )..layout();
        final double result = painter.width;
        painter.dispose();
        return result;
      }

      final double regular = width(ZsType.body);
      final double semibold = width(
        ZsType.body.copyWith(
          fontWeight: FontWeight.w600,
          fontVariations: const <FontVariation>[FontVariation.weight(600)],
        ),
      );
      expect(semibold, greaterThan(regular));
    });
  });

  group('elevation', () {
    test('the converter turns 0 14px 36px -12px into σ 18, blurRadius ≈ 30.3 and spread −12', () {
      const shadow = ZsShadow(dx: 0, dy: 14, blur: 36, spread: -12, color: Color.fromRGBO(0, 0, 0, .6));
      final BoxShadow box = shadow.toBoxShadow();
      expect(box.blurSigma, closeTo(18, 1e-9));
      expect(box.blurRadius, closeTo(30.3, .05));
      expect(box.spreadRadius, -12);
      expect(box.offset, const Offset(0, 14));
      expect(ZsShadow.blurRadiusFor(0), 0);
    });

    test('--fl-shadow hands its inset highlight to 11.2 and converts the rest', () {
      final ZsShadowStack island = ZsElevation.night.shadowIsland;
      expect(island, ZsElevation.night.flShadow);
      expect(island.inset, <ZsShadow>[
        const ZsShadow(dx: 0, dy: 1, blur: 0, spread: 0, color: Color.fromRGBO(255, 255, 255, .05), inset: true),
      ]);
      expect(island.boxShadows, hasLength(2));
      expect(island.boxShadows.first.spreadRadius, -12);
    });

    test('glass and scrim blurs go under increased contrast and reduce transparency', () {
      expect(ZsElevation.night.glassBlur, const ZsGlassFilter(blur: 18, saturate: 1.4));
      for (final appearance in const <ZsAppearance>[
        ZsAppearance(increasedContrast: true),
        ZsAppearance(reduceTransparency: true),
      ]) {
        final elevation = ZsElevation.resolve(appearance);
        expect(elevation.glassBlur, isNull);
        expect(elevation.glassBlurStrong, isNull);
        expect(elevation.scrimBlur, isNull);
      }
    });

    test('rings follow the accent family and the inactive window, the drop ring stays live', () {
      final graphite = ZsElevation.resolve(const ZsAppearance(family: ZsAccentFamily.graphite));
      expect(graphite.ringSelect.parts.single.color, const Color.fromRGBO(183, 183, 183, 0.3));
      final inactive = ZsElevation.resolve(const ZsAppearance(inactive: true));
      expect(inactive.ringSelect.parts.single.color, const Color.fromRGBO(231, 233, 242, .16));
      expect(inactive.ringDrop.parts.first.color, const Color.fromRGBO(174, 188, 236, .3));
    });
  });

  group('motion', () {
    test('reduced zeroes the factor and the five movement durations and keeps every fade', () {
      const ZsMotion full = ZsMotion.full;
      const ZsMotion reduced = ZsMotion.reduced;
      expect(full.motion, 1);
      expect(reduced.motion, 0);
      for (final movement in <Duration>[
        reduced.durNudge,
        reduced.durToggle,
        reduced.durExpand,
        reduced.durMove,
        reduced.durFlip,
      ]) {
        expect(movement, Duration.zero);
      }
      expect(full.durFlip, const Duration(milliseconds: 460));
      final Map<String, Object> fullCss = full.toCss();
      final Map<String, Object> reducedCss = reduced.toCss();
      const movement = <String>{'--motion', '--dur-nudge', '--dur-toggle', '--dur-expand', '--dur-move', '--dur-flip'};
      for (final String name in fullCss.keys) {
        if (!movement.contains(name)) {
          expect(reducedCss[name], fullCss[name], reason: name);
        }
      }
      expect(reduced.durDialog, const Duration(milliseconds: 220));
      expect(reduced.easeGlide, isA<Cubic>().having((c) => c.b, 'b', .72));
    });

    testWidgets('of(context) follows MediaQuery.disableAnimations', (tester) async {
      late BuildContext probe;
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: Builder(
            builder: (context) {
              probe = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      expect(ZsMotion.of(probe), ZsMotion.reduced);
    });
  });

  group('metrics', () {
    test('the chrome derives from the traffic-light block', () {
      const ZsMetrics metrics = ZsMetrics.standard;
      expect(metrics.chromeFirstX, 91);
      expect(metrics.chromeBarY, 4);
      expect(metrics.chromeTop, 60);
      expect(metrics.chromeLeft, 76);
      expect(metrics.focusW, 2);
      expect(metrics.disabledOpacity, .4);
      expect(ZsIconSize.values.map((s) => s.size), <double>[10, 12, 14, 16, 17, 19]);
    });

    test('increased contrast widens the focus ring and full screen moves the chrome', () {
      expect(ZsMetrics.resolve(const ZsAppearance(increasedContrast: true)).focusW, 3);
      final fullScreen = ZsMetrics.resolve(const ZsAppearance(fullScreen: true));
      expect(fullScreen.chromeFirstX, 12);
      expect(fullScreen.chromeBarY, 12);
      expect(fullScreen.chromeTop, 68);
      expect(fullScreen.chromeLeft, 76);
    });

    test('a measured traffic-light block places the chrome', () {
      final measured = ZsMetrics.resolve(const ZsAppearance(trafficLights: Rect.fromLTWH(19, 19, 60, 14)));
      expect(measured.chromeFirstX, 91);
      expect(measured.chromeBarY, 4);
      expect(measured.chromeTop, 60);
      expect(measured.tlSize, ZsMetrics.standard.tlSize);
      expect(measured.tlPitch, ZsMetrics.standard.tlPitch);
      // Another block, centre y 27: the bar's centre line and the first island follow it.
      final shifted = ZsMetrics.resolve(const ZsAppearance(trafficLights: Rect.fromLTWH(20, 20, 60, 14)));
      expect(shifted.chromeFirstX, 92);
      expect(shifted.chromeBarY, 5);
      expect(shifted.chromeBarY + shifted.chromeH / 2, 27);
      expect(shifted.chromeTop, 61);
    });

    test('full screen wins over a block; no report keeps the reference geometry', () {
      final fullScreen = ZsMetrics.resolve(
        const ZsAppearance(fullScreen: true, trafficLights: Rect.fromLTWH(20, 20, 60, 14)),
      );
      expect(fullScreen.chromeFirstX, 12);
      expect(fullScreen.chromeBarY, 12);
      expect(fullScreen.chromeTop, 68);
      expect(ZsMetrics.resolve(const ZsAppearance()), ZsMetrics.standard);
    });

    test('each density sets the row step, card heights and gaps; everything else stays', () {
      (double, double, double, double, double) set(ZsDensity density) {
        final m = ZsMetrics.resolve(ZsAppearance(density: density));
        return (m.rowStep, m.cardHCompact, m.cardHDetailed, m.graphGapX, m.graphGapY);
      }

      expect(set(ZsDensity.compact), (0, 40, 62, 56, 48));
      expect(set(ZsDensity.balanced), (3, 44, 68, 62, 54));
      expect(set(ZsDensity.comfy), (6, 48, 74, 68, 60));
      expect(ZsMetrics.resolve(const ZsAppearance()), ZsMetrics.standard);
      final comfy = ZsMetrics.resolve(const ZsAppearance(density: ZsDensity.comfy));
      expect(
        comfy.copyWith(rowStep: 0, cardHCompact: 40, cardHDetailed: 62, graphGapX: 56, graphGapY: 48),
        ZsMetrics.standard,
      );
    });
  });

  test('the token layer records the DS sync it mirrors', () {
    expect(dsSyncedThrough, 15);
  });
}
