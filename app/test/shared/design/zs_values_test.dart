// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_values.dart';

/// Matches a colour matrix entry by entry within 1e-9.
Matcher _matrix(List<double> expected) => pairwiseCompare<double, double>(
  expected,
  (expected, actual) => (expected - actual).abs() < 1e-9,
  'within 1e-9 of',
);

void main() {
  test('saturate 1.4 is the CSS Filter Effects matrix', () {
    expect(
      ZsGlassFilter.saturateMatrix(1.4),
      _matrix(<double>[
        ...<double>[1.3148, -.286, -.0288, 0, 0],
        ...<double>[-.0852, 1.114, -.0288, 0, 0],
        ...<double>[-.0852, -.286, 1.3712, 0, 0],
        ...<double>[0, 0, 0, 1, 0],
      ]),
    );
  });

  test('saturate 1.2 is the CSS Filter Effects matrix, and alpha scales only the alpha row', () {
    expect(
      ZsGlassFilter.saturateMatrix(1.2, alpha: .25),
      _matrix(<double>[
        ...<double>[1.1574, -.143, -.0144, 0, 0],
        ...<double>[-.0426, 1.057, -.0144, 0, 0],
        ...<double>[-.0426, -.143, 1.1856, 0, 0],
        ...<double>[0, 0, 0, .25, 0],
      ]),
    );
  });

  test('a glass filter blurs first, at sigma = blur, then saturates', () {
    const filter = ZsGlassFilter(blur: 18, saturate: 1.4);
    expect(
      filter.toImageFilter(),
      ImageFilter.compose(
        outer: ColorFilter.matrix(ZsGlassFilter.saturateMatrix(1.4)),
        inner: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      ),
    );
    expect(
      filter.toImageFilter(alpha: .5),
      ImageFilter.compose(
        outer: ColorFilter.matrix(ZsGlassFilter.saturateMatrix(1.4, alpha: .5)),
        inner: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
      ),
    );
  });

  for (final (ZsTheme theme, ZsLinearGradient sheen) in <(ZsTheme, ZsLinearGradient)>[
    (ZsTheme.night, ZsColors.night.flSheen),
    (ZsTheme.paper, ZsColors.paper.flSheen),
  ]) {
    test('--fl-sheen on ${theme.name} runs from the top 46 px down in a tall and in a short box', () {
      for (final rect in <Rect>[const Rect.fromLTWH(0, 0, 100, 120), const Rect.fromLTWH(0, 0, 100, 36)]) {
        final ({Offset from, Offset to, List<Color> colors, List<double> stops}) line = sheen.resolve(rect);
        expect(line.from.dx, closeTo(50, 1e-9), reason: '$rect');
        expect(line.from.dy, closeTo(0, 1e-9), reason: '$rect');
        expect(line.to.dx, closeTo(50, 1e-9), reason: '$rect');
        expect(line.to.dy, closeTo(46, 1e-9), reason: '$rect');
        expect(line.colors, <Color>[sheen.stops.first.color, sheen.stops.last.color]);
        expect(line.stops, <double>[0, 1]);
      }
    });
  }

  test('a gradient line follows the CSS angle, and unpositioned stops take 0 %, 100 % and the even spread', () {
    const red = Color(0xFFFF0000);
    const green = Color(0xFF00FF00);
    const blue = Color(0xFF0000FF);
    const gradient = ZsLinearGradient(
      angle: 90,
      stops: <ZsGradientStop>[
        ZsGradientStop(red),
        ZsGradientStop(green),
        ZsGradientStop(blue, percent: 60),
        ZsGradientStop(red, px: 100),
        ZsGradientStop(green),
      ],
    );
    final ({Offset from, Offset to, List<Color> colors, List<double> stops}) line = gradient.resolve(
      const Rect.fromLTWH(10, 20, 200, 80),
    );
    expect(line.from.dx, closeTo(10, 1e-9));
    expect(line.from.dy, closeTo(60, 1e-9));
    expect(line.to.dx, closeTo(210, 1e-9));
    expect(line.to.dy, closeTo(60, 1e-9));
    expect(line.colors, <Color>[red, green, blue, red, green]);
    expect(line.stops, pairwiseCompare<double, double>(<double>[0, .3, .6, .6, 1], (e, a) => (e - a).abs() < 1e-9, ''));
  });

  test('the shader covers its rect', () {
    expect(ZsColors.night.flSheen.createShader(const Rect.fromLTWH(0, 0, 100, 120)), isA<Shader>());
  });
}
