// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:ui' show PointMode;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:intl/intl.dart' show DateFormat;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_layout.dart';
import 'vertical_layout.dart';

const _dayMs = 86400000;

/// The label of the day starting at [dayMs] (a local midnight, epoch ms) seen at [nowMs], both read at the layout's
/// fixed offset, in [strings] (Story 10.2; design graph-layout.jsx:36-45): "Today" for today and later, "Yesterday",
/// else the day through `intl` at the strings' locale — `MMMd` ("Sep 23"), `yMMMd` ("Sep 23, 2025") when the year is
/// not the current one.
String graphDayLabel(AppLocalizations strings, int dayMs, {required int nowMs, required int utcOffsetMinutes}) {
  final int off = utcOffsetMinutes * 60000;
  final int local = nowMs + off;
  final int today = local - local % _dayMs - off;
  if (dayMs >= today) {
    return strings.dayToday;
  }
  if (dayMs == today - _dayMs) {
    return strings.dayYesterday;
  }
  final day = DateTime.fromMillisecondsSinceEpoch(dayMs + off, isUtc: true);
  ensureDateFormatting();
  final thisYear = day.year == DateTime.fromMillisecondsSinceEpoch(local, isUtc: true).year;
  return (thisYear ? DateFormat.MMMd(strings.localeName) : DateFormat.yMMMd(strings.localeName)).format(day);
}

/// Free's day axis in plane coordinates (Story 10.2): one label per day bucket and a divider between two days, read
/// from the layout's buckets through [VerticalLayout] (design graph-layout.jsx:586-603). Empty unless the layout is
/// free.
@immutable
class GraphDayAxis {
  const GraphDayAxis._(this.values, this.labelYs, this.guideYs);

  /// The axis of [layout] mapped by [vertical]: O(#days).
  factory GraphDayAxis.of(GraphLayout layout, VerticalLayout vertical) {
    final int days = layout.bucketCount;
    if (layout.mode != GraphMode.free || days == 0 || layout.nodeCount == 0) {
      return empty;
    }
    final double h = vertical.metrics.cardHeight;
    final int? root = layout.rootIndex;
    final values = Int64List(days);
    final labelYs = Float64List(days);
    final guideYs = Float64List(days - 1);
    double last = double.infinity;
    for (var b = 0; b < days; b++) {
      values[b] = layout.bucketValueOf(b);
      final double lo = vertical.topOfRow(layout.bucketFirstRowOf(b));
      final double floor = b > 0
          ? vertical.topOfRow(layout.bucketLastRowOf(b - 1))
          : root != null
          ? vertical.top(root)
          : lo + h + vertical.metrics.gapY;
      final double g = (floor + lo + h) / 2;
      last = labelYs[b] = math.min(g, last - minLabelGap);
      if (b > 0) {
        guideYs[b - 1] = g;
      }
    }
    return GraphDayAxis._(values, labelYs, guideYs);
  }

  /// The axis with no days.
  static final empty = GraphDayAxis._(Int64List(0), Float64List(0), Float64List(0));

  /// The least distance between two label centres: a newer label is pushed up to it.
  static const double minLabelGap = 22;

  /// Each day's bucket value, oldest first.
  final Int64List values;

  /// Each day's label centre y, strictly decreasing.
  final Float64List labelYs;

  /// The divider y below day `b`, at `b − 1` (the oldest day has none), decreasing.
  final Float64List guideYs;

  /// The number of days.
  int get length => values.length;

  /// The labels whose centre lies in [top]–[bottom]: indices `start` until `end`.
  ({int start, int end}) labelsBetween(double top, double bottom) => _between(labelYs, top, bottom);

  /// The dividers in [top]–[bottom]: [guideYs] indices `start` until `end`.
  ({int start, int end}) guidesBetween(double top, double bottom) => _between(guideYs, top, bottom);

  static ({int start, int end}) _between(Float64List ys, double top, double bottom) =>
      (start: _first(ys, (y) => y <= bottom), end: _first(ys, (y) => y < top));

  /// The first index of descending [ys] that satisfies the monotone [test].
  static int _first(Float64List ys, bool Function(double y) test) {
    var lo = 0;
    int hi = ys.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (test(ys[mid])) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }
}

/// Paints a [GraphDayAxis] through the viewport's hooks (Story 10.2): [paintGuides] as the background hook (behind
/// the edges), [paintLabels] in the overlay hook (above the cards). Paint-only: it adds no hit target and no
/// semantics, and a new [nowMs] needs a new painter, a repaint, never a layout. The owner calls [dispose].
class GraphDayAxisPainter {
  /// A painter of [axis] in [theme]'s day-axis roles, labelling in [strings] against [nowMs] at [utcOffsetMinutes].
  GraphDayAxisPainter({
    required this.axis,
    required this.theme,
    required this.strings,
    required this.nowMs,
    required this.utcOffsetMinutes,
  });

  /// The axis painted.
  final GraphDayAxis axis;

  /// The labels' words.
  final AppLocalizations strings;

  /// The colours.
  final GraphTheme theme;

  /// "Now" for the labels, in epoch ms.
  final int nowMs;

  /// The layout's fixed offset, in minutes.
  final int utcOffsetMinutes;

  // The dash (DS graph.css:101 `stroke-dasharray: 2 6`).
  static const double _dash = 2;
  static const double _period = 8;

  // The pill (graph.css:103-104): padding 2 × 7, a 1 px border, the column's left edge at inset − 6 plus 2.
  static const double _padX = 7;
  static const double _padY = 2;
  static const double _border = 1;
  static const double _labelLeft = -4;

  // How far a label's pill reaches past its centre, generously: the paint query takes the labels that may show.
  static const double _labelReach = 24;

  final _labels = <int, TextPainter>{};

  /// Paints the visible dividers in one `drawRawPoints` call; the dash phase is anchored to plane x 0.
  void paintGuides(PaintingContext context, Offset origin, Rect visible) {
    final (:int start, :int end) = axis.guidesBetween(visible.top, visible.bottom);
    if (start >= end) {
      return;
    }
    final double from = (visible.left / _period).floorToDouble() * _period;
    final int dashes = ((visible.right - from) / _period).ceil();
    final points = Float32List((end - start) * dashes * 4);
    var k = 0;
    for (var b = start; b < end; b++) {
      // A 1 px line on a pixel's centre, so it covers one device row at dpr 1 instead of smearing over two.
      final double y = (origin.dy + axis.guideYs[b]).floorToDouble() + .5;
      for (var d = 0; d < dashes; d++) {
        final double x = origin.dx + from + d * _period;
        points
          ..[k++] = x
          ..[k++] = y
          ..[k++] = x + _dash
          ..[k++] = y;
      }
    }
    context.canvas.drawRawPoints(
      PointMode.lines,
      points,
      Paint()
        ..color = theme.dayGuide
        ..strokeWidth = 1,
    );
  }

  /// Paints the visible labels, sticky at viewport x [leftInset] − 4, each centred on its y.
  void paintLabels(PaintingContext context, Offset origin, Rect visible, {required double leftInset}) {
    final (:int start, :int end) = axis.labelsBetween(visible.top - _labelReach, visible.bottom + _labelReach);
    if (start >= end) {
      return;
    }
    final Canvas canvas = context.canvas;
    final fill = Paint()..color = theme.dayLabelFill;
    final stroke = Paint()
      ..color = theme.dayLabelBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = _border;
    final double left = (origin.dx + visible.left + leftInset + _labelLeft).roundToDouble();
    final radius = Radius.circular(ZsMetrics.standard.radiusTag);
    for (var b = start; b < end; b++) {
      final TextPainter text = _label(b);
      final double height = text.height + 2 * (_padY + _border);
      final rect = Rect.fromLTWH(
        left,
        (origin.dy + axis.labelYs[b] - height / 2).roundToDouble(),
        text.width + 2 * (_padX + _border),
        height,
      );
      final pill = RRect.fromRectAndRadius(rect, radius);
      canvas
        ..drawRRect(pill, fill)
        ..drawRRect(pill.deflate(_border / 2), stroke);
      text.paint(canvas, rect.topLeft + const Offset(_padX + _border, _padY + _border));
    }
  }

  TextPainter _label(int b) => _labels.putIfAbsent(
    b,
    () => TextPainter(
      text: TextSpan(
        text: graphDayLabel(strings, axis.values[b], nowMs: nowMs, utcOffsetMinutes: utcOffsetMinutes),
        style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: theme.dayLabelText),
      ),
      textDirection: TextDirection.ltr,
    )..layout(),
  );

  /// Releases the cached text.
  void dispose() {
    for (final TextPainter text in _labels.values) {
      text.dispose();
    }
    _labels.clear();
  }
}
