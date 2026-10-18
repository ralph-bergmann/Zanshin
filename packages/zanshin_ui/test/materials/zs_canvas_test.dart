// SPDX-License-Identifier: MIT

import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/materials/zs_canvas.dart';

import '../helpers/zs_host.dart';

/// The canvas box of the tests.
const _size = Size(1000, 800);

/// Paints the night canvas's linear base alone.
class _LinearOnly extends CustomPainter {
  const _LinearOnly();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Offset.zero & size;
    canvas.drawRect(box, Paint()..shader = ZsColors.night.canvas.linear.createShader(box));
  }

  @override
  bool shouldRepaint(_LinearOnly oldDelegate) => false;
}

/// Matches a rect filling [box] with a shader.
PaintPatternPredicate _shaded(Rect box) =>
    (method, arguments) => method == #drawRect && arguments[0] == box && (arguments[1] as Paint).shader != null;

void main() {
  void useCanvasWindow(WidgetTester tester) {
    tester.view
      ..physicalSize = _size
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  for (final (ZsTheme theme, ZsColors colors) in <(ZsTheme, ZsColors)>[
    (ZsTheme.night, ZsColors.night),
    (ZsTheme.paper, ZsColors.paper),
  ]) {
    testWidgets('the ${theme.name} canvas paints the linear base, then the radial lift, over its whole box', (
      tester,
    ) async {
      useCanvasWindow(tester);
      await tester.pumpWidget(zsHost(const ZsCanvas(), appearance: ZsAppearance(theme: theme), group: false));

      final Finder canvas = find.byType(ZsCanvas);
      expect(tester.getRect(canvas), Offset.zero & _size);
      expect(tester.renderObject<RenderZsCanvas>(canvas).gradient, colors.canvas);
      final Rect box = Offset.zero & _size;
      expect(
        canvas,
        paints
          ..something(_shaded(box))
          ..something(_shaded(box)),
      );
      expect(canvas, paintsExactlyCountTimes(#drawRect, 2));
    });
  }

  testWidgets('pixels: the lift brightens the top left and leaves the far corner and the region outside its ellipse', (
    tester,
  ) async {
    useCanvasWindow(tester);
    const boundary = Key('boundary');

    /// Renders [child] in a repaint boundary and returns its RGBA bytes.
    Future<ByteData> render(Widget child) async {
      await tester.pumpWidget(zsHost(RepaintBoundary(key: boundary, child: child), group: false));
      final RenderRepaintBoundary box = tester.renderObject(find.byKey(boundary));
      return (await tester.runAsync(() async {
        final ui.Image image = await box.toImage();
        expect(<int>[image.width, image.height], <int>[1000, 800]);
        final ByteData? bytes = await image.toByteData();
        image.dispose();
        return bytes;
      }))!;
    }

    final ByteData canvas = await render(const ZsCanvas());
    final ByteData linear = await render(const CustomPaint(painter: _LinearOnly(), size: _size));
    List<int> pixel(ByteData bytes, int x, int y) => <int>[
      for (var channel = 0; channel < 4; channel++) bytes.getUint8((y * 1000 + x) * 4 + channel),
    ];
    bool same(List<int> a, List<int> b) => <int>[for (var i = 0; i < 4; i++) (a[i] - b[i]).abs()].every((d) => d <= 1);

    expect(same(pixel(canvas, 100, 10), pixel(linear, 100, 10)), isFalse, reason: 'the lift near its centre');
    expect(pixel(canvas, 999, 799), _sameAs(pixel(linear, 999, 799)), reason: 'the far corner, past the lift');
    // Inside the unscaled 1150 circle (0.43 of its radius) but outside the ellipse (0.73 of 680): only the matrix
    // keeps the lift away from here.
    expect(pixel(canvas, 100, 400), _sameAs(pixel(linear, 100, 400)), reason: 'outside the ellipse');
  });

  testWidgets('an empty canvas paints nothing', (tester) async {
    await tester.pumpWidget(zsHost(const SizedBox.shrink(child: ZsCanvas()), group: false));
    expect(find.byType(ZsCanvas), paintsNothing);
  });

  testWidgets('a press on the canvas reaches it', (tester) async {
    useCanvasWindow(tester);
    await tester.pumpWidget(zsHost(const ZsCanvas(), group: false));
    final RenderObject canvas = tester.renderObject(find.byType(ZsCanvas));
    expect(tester.hitTestOnBinding(const Offset(500, 400)).path.any((entry) => entry.target == canvas), isTrue);
  });

  testWidgets('a theme switch repaints the canvas with the lerped gradient, then the new one', (tester) async {
    useCanvasWindow(tester);
    await tester.pumpWidget(zsHost(const ZsCanvas(), group: false));
    final RenderZsCanvas canvas = tester.renderObject<RenderZsCanvas>(find.byType(ZsCanvas));
    expect(canvas.gradient, ZsColors.night.canvas);

    await tester.pumpWidget(
      zsHost(const ZsCanvas(), appearance: const ZsAppearance(theme: ZsTheme.paper), group: false),
    );
    await tester.pump(const Duration(milliseconds: 100), EnginePhase.layout);
    expect(canvas.debugNeedsPaint, isTrue, reason: 'the lerped gradient is not painted yet');
    expect(canvas.gradient, isNot(ZsColors.night.canvas));
    expect(canvas.gradient, isNot(ZsColors.paper.canvas));

    await tester.pumpAndSettle();
    expect(canvas.debugNeedsPaint, isFalse);
    expect(canvas.gradient, ZsColors.paper.canvas);
  });
}

/// Matches an RGBA pixel within 1/255 per channel of [expected].
Matcher _sameAs(List<int> expected) => pairwiseCompare<int, int>(expected, (e, a) => (e - a).abs() <= 1, 'within 1 of');
