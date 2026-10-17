// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';

/// Makes focus highlights follow macOS for the file's tests: the highlight mode is always "traditional" there
/// (RC §4), whatever input the test sends; and ends the tooltips' shared warm window after each test.
void useMacFocus() {
  setUp(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional);
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    ZsTooltip.resetWarmWindow();
  });
}

/// A mouse over the centre of [finder] (or [at]), so hover states and cursors show.
Future<TestGesture> hover(WidgetTester tester, Finder finder, {Offset? at}) async {
  final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  addTearDown(mouse.removePointer);
  await mouse.moveTo(at ?? tester.getCenter(finder));
  await tester.pump();
  return mouse;
}

/// The cursor the first mouse shows.
MouseCursor? activeCursor() => RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1);

/// Whether [actual], read back from a `Paint`, is [expected].
bool sameColor(Color actual, Color expected) =>
    (actual.a - expected.a).abs() < 1e-3 &&
    (actual.r - expected.r).abs() < 1e-3 &&
    (actual.g - expected.g).abs() < 1e-3 &&
    (actual.b - expected.b).abs() < 1e-3;

/// Matches a `drawRRect` of [color] whose rect has [size] (any position).
PaintPatternPredicate rrectOf({required Color color, Size? size}) => (method, arguments) {
  if (method != #drawRRect) {
    return false;
  }
  final rrect = arguments[0] as RRect;
  final paint = arguments[1] as Paint;
  return sameColor(paint.color, color) && (size == null || rrect.outerRect.size == size);
};

/// Matches a `drawDRRect` of [color], the inner rect [inset] inside the outer one.
PaintPatternPredicate ringOf({required Color color, double? inset}) => (method, arguments) {
  if (method != #drawDRRect) {
    return false;
  }
  final outer = arguments[0] as RRect;
  final inner = arguments[1] as RRect;
  final paint = arguments[2] as Paint;
  return sameColor(paint.color, color) && (inset == null || (inner.left - outer.left - inset).abs() < 1e-6);
};

/// Matches a `drawRRect` of exactly [rrect], in [color] when given.
PaintPatternPredicate rrectAt(RRect rrect, {Color? color}) =>
    (method, arguments) =>
        method == #drawRRect &&
        arguments[0] == rrect &&
        (color == null || sameColor((arguments[1] as Paint).color, color));

/// Matches a `drawCircle` of [radius], in [color] when given.
PaintPatternPredicate circleOf({double? radius, Color? color}) =>
    (method, arguments) =>
        method == #drawCircle &&
        (radius == null || ((arguments[1] as double) - radius).abs() < 1e-6) &&
        (color == null || sameColor((arguments[2] as Paint).color, color));
