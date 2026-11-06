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
/// else the day through `intl` at the strings' locale, `MMMd` ("Sep 23") — on the axis never a year (Story 10.31, DS
/// sync #22: years get labels of their own). A card ([withYear]) keeps `yMMMd` ("Sep 23, 2025") when the year is not
/// the current one: it has no year label beside it.
String graphDayLabel(
  AppLocalizations strings,
  int dayMs, {
  required int nowMs,
  required int utcOffsetMinutes,
  bool withYear = false,
}) {
  final int off = utcOffsetMinutes * 60000;
  final int local = nowMs + off;
  final int today = local - local % _dayMs - off;
  if (dayMs >= today) {
    return strings.dayToday;
  }
  if (dayMs == today - _dayMs) {
    return strings.dayYesterday;
  }
  ensureDateFormatting();
  final day = DateTime.fromMillisecondsSinceEpoch(dayMs + off, isUtc: true);
  final bool year = withYear && day.year != DateTime.fromMillisecondsSinceEpoch(local, isUtc: true).year;
  return (year ? DateFormat.yMMMd(strings.localeName) : DateFormat.MMMd(strings.localeName)).format(day);
}

/// The calendar year of [ms] at the fixed offset [utcOffsetMinutes].
int graphYearOf(int ms, {required int utcOffsetMinutes}) =>
    DateTime.fromMillisecondsSinceEpoch(ms + utcOffsetMinutes * 60000, isUtc: true).year;

/// The label of a break between [first] and [second] (epoch ms, read at the fixed offset) in [strings] (Story 10.31, DS
/// `GraphBreak.label`): "‹length› · ‹range›" — "6 years · Sep 2019 – May 2025", "8 months · Jun – Dec 2025",
/// "3 weeks · Jun 3 – 24", "1 day · Jun 3" (one day); null when either time is missing. The pair is read oldest first
/// (raw committer times need not follow the rows).
String? graphBreakLabel(AppLocalizations strings, int? first, int? second, {required int utcOffsetMinutes}) {
  if (first == null || second == null) {
    return null;
  }
  final int t0 = math.min(first, second);
  final int t1 = math.max(first, second);
  final double d = (t1 - t0) / _dayMs;
  final String length = d >= 548
      ? strings.graphBreakYears((d / 365).round())
      : d >= 60
      ? strings.graphBreakMonths((d / 30.4).round())
      : d >= 14
      ? strings.graphBreakWeeks((d / 7).round())
      : strings.graphBreakDays(math.max(1, d.round()));
  final int off = utcOffsetMinutes * 60000;
  final a = DateTime.fromMillisecondsSinceEpoch(t0 + off, isUtc: true);
  final b = DateTime.fromMillisecondsSinceEpoch(t1 + off, isUtc: true);
  ensureDateFormatting();
  final String locale = strings.localeName;
  final String range = a.year != b.year
      ? strings.graphBreakRange(DateFormat.yMMM(locale).format(a), DateFormat.yMMM(locale).format(b))
      : a.month != b.month
      ? strings.graphBreakRange(DateFormat.MMM(locale).format(a), DateFormat.yMMM(locale).format(b))
      : a.day != b.day
      ? strings.graphBreakRange(DateFormat.MMMd(locale).format(a), DateFormat.d(locale).format(b))
      : DateFormat.MMMd(locale).format(a);
  return strings.graphBreakLabel(length, range);
}

/// [year] as a label in [strings]' locale (`intl` `y`), as the day and break labels are.
String graphYearLabel(AppLocalizations strings, int year) {
  ensureDateFormatting();
  return DateFormat.y(strings.localeName).format(DateTime.utc(year));
}

/// A year boundary of the day axis (Story 10.31, DS `DayAxis years`): at a divider between two days of different
/// years, [year] the newer, [below] the older (null for the oldest day, which opens the history's first year).
@immutable
class GraphAxisYear {
  /// A boundary at [y].
  const GraphAxisYear({required this.y, required this.year, this.below, this.inBand = false});

  /// The day label's centre y (the divider's for a boundary inside a break: the band's top).
  final double y;

  /// The year above the boundary.
  final int year;

  /// The year below it, null at the oldest day.
  final int? below;

  /// Whether the boundary lies inside a break, where the canvas shows no year.
  final bool inBand;
}

/// A break band of the day axis in plane coordinates (Story 10.31): the upper card's bottom to the lower card's top.
@immutable
class GraphAxisBreak {
  /// A band from [top] to [bottom] spanning [t0]–[t1].
  const GraphAxisBreak({required this.top, required this.bottom, this.t0, this.t1});

  /// The band's top y.
  final double top;

  /// The band's bottom y.
  final double bottom;

  /// The lower card's newest time.
  final int? t0;

  /// The upper card's oldest time.
  final int? t1;

  /// The band's centre y.
  double get centre => (top + bottom) / 2;

  /// Whether [y] lies inside the band (a pixel of slack either side).
  bool contains(double y) => y > top - 1 && y < bottom + 1;
}

/// Free's day axis in plane coordinates (Story 10.2): one label per day bucket and a divider between two days, read
/// from the layout's buckets through [VerticalLayout] (design graph-layout.jsx:586-603). Empty unless the layout is
/// free. A day whose divider falls inside a break is left out (Story 10.31); [years] and [breaks] come with it.
@immutable
class GraphDayAxis {
  const GraphDayAxis._(
    this.values,
    this.labelYs,
    this.guideYs,
    this.years,
    this.breaks,
    this.droppedValues,
    this.droppedYs,
  );

  /// The axis of [layout] mapped by [vertical]: O(#days + #breaks), one cursor over the breaks.
  factory GraphDayAxis.of(GraphLayout layout, VerticalLayout vertical) {
    final int days = layout.bucketCount;
    if (layout.mode != GraphMode.free || days == 0 || layout.nodeCount == 0) {
      return empty;
    }
    final double h = vertical.metrics.cardHeight;
    final breaks = <GraphAxisBreak>[
      for (final GraphBreak b in layout.breaks)
        GraphAxisBreak(
          top: vertical.topOfRow(b.upperRow) + h,
          bottom: vertical.topOfRow(b.lowerRow),
          t0: b.t0,
          t1: b.t1,
        ),
    ];
    // The dividers come oldest first (y decreasing), the breaks lowest first: one cursor walks both.
    var cursor = 0;
    GraphAxisBreak? bandAt(double y) {
      while (cursor < breaks.length && y <= breaks[cursor].top - 1) {
        cursor++;
      }
      return cursor < breaks.length && breaks[cursor].contains(y) ? breaks[cursor] : null;
    }

    final int off = layout.utcOffsetMinutes;
    final int? root = layout.rootIndex;
    final values = <int>[];
    final labelYs = <double>[];
    final guideYs = <double>[];
    final droppedValues = <int>[];
    final droppedYs = <double>[];
    final years = <GraphAxisYear>[];
    double last = double.infinity;
    int? prevYear;
    for (var b = 0; b < days; b++) {
      final int value = layout.bucketValueOf(b);
      final int year = graphYearOf(value, utcOffsetMinutes: off);
      final double lo = vertical.topOfRow(layout.bucketFirstRowOf(b));
      final double floor = b > 0
          ? vertical.topOfRow(layout.bucketLastRowOf(b - 1))
          : root != null
          ? vertical.top(root)
          : lo + h + vertical.metrics.gapY;
      final double g = (floor + lo + h) / 2;
      final double y = math.min(g, last - minLabelGap);
      final GraphAxisBreak? band = b > 0 ? bandAt(g) : null;
      if (prevYear != year) {
        years.add(GraphAxisYear(y: band?.top ?? y, year: year, below: prevYear, inBand: band != null));
      }
      if (band == null) {
        values.add(value);
        labelYs.add(y);
        if (b > 0) {
          guideYs.add(g);
        }
      } else {
        droppedValues.add(value);
        droppedYs.add(band.top);
      }
      last = y;
      prevYear = year;
    }
    return GraphDayAxis._(
      Int64List.fromList(values),
      Float64List.fromList(labelYs),
      Float64List.fromList(guideYs),
      years,
      breaks,
      Int64List.fromList(droppedValues),
      Float64List.fromList(droppedYs),
    );
  }

  /// The axis with no days.
  static final empty = GraphDayAxis._(
    Int64List(0),
    Float64List(0),
    Float64List(0),
    const <GraphAxisYear>[],
    const <GraphAxisBreak>[],
    Int64List(0),
    Float64List(0),
  );

  /// The days left out because their divider lies in a break, oldest first: never drawn, but the minimap's day lookup
  /// still names them for their cards, at the band's top ([droppedYs]).
  final Int64List droppedValues;

  /// Each dropped day's lookup y: its break band's top.
  final Float64List droppedYs;

  /// The least distance between two label centres: a newer label is pushed up to it.
  static const double minLabelGap = 22;

  /// How far above its day's label centre a year's label centre sits (DS graph.css `.zs-year-label`).
  static const double yearRaise = 22;

  /// Each shown day's bucket value, oldest first.
  final Int64List values;

  /// Each shown day's label centre y, strictly decreasing.
  final Float64List labelYs;

  /// The shown dividers, oldest first (the oldest day has none), decreasing.
  final Float64List guideYs;

  /// Every year boundary, oldest first: the oldest day's year (no [GraphAxisYear.below]) and each change of year.
  final List<GraphAxisYear> years;

  /// The break bands, lowest first.
  final List<GraphAxisBreak> breaks;

  /// The years the canvas labels: where a year begins, not inside a break, none for a one-year history.
  Iterable<GraphAxisYear> get canvasYears => years.where((y) => y.below != null && !y.inBand);

  /// The number of shown days.
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

/// The torn edge of a break (DS `GraphBreak`): a zigzag of [amp] every [step] px from [x0] to [x1] around [y], its
/// phase anchored to x 0 so the edge stays put while the plane scrolls; point `i` (x = i·step) lies at y + amp when
/// `i + phase` is even.
List<Offset> graphZigzag(double x0, double x1, double y, int phase, {double amp = 3, double step = 9}) {
  final int first = (x0 / step).floor();
  final int last = (x1 / step).ceil();
  return <Offset>[
    for (int i = first; i <= last; i++) Offset(i * step, y + ((i + phase).isEven ? amp : -amp)),
  ];
}

/// Paints a [GraphDayAxis] through the viewport's hooks (Story 10.2): [paintGuides] as the background hook (behind
/// the edges), [paintBreaks] after the edges (Story 10.31), [paintLabels] in the overlay hook (above the cards).
/// Paint-only: it adds no hit target and no semantics, and a new [nowMs] needs a new painter, a repaint, never a
/// layout. The owner calls [dispose].
class GraphDayAxisPainter {
  /// A painter of [axis] in [theme]'s day-axis roles and [colors] (breaks, years), labelling in [strings] against
  /// [nowMs] at [utcOffsetMinutes].
  GraphDayAxisPainter({
    required this.axis,
    required this.theme,
    required this.strings,
    required this.nowMs,
    required this.utcOffsetMinutes,
    this.colors = ZsColors.night,
  });

  /// The axis painted.
  final GraphDayAxis axis;

  /// The labels' words.
  final AppLocalizations strings;

  /// The colours.
  final GraphTheme theme;

  /// The token colours of the breaks and years.
  final ZsColors colors;

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

  // A break's torn edges sit this far either side of its centre (DS GraphBreak).
  static const double _breakEdge = 9;

  final _labels = <int, TextPainter>{};
  final _breakLabels = <int, TextPainter?>{};
  final _years = <int, TextPainter>{};

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

  /// Paints the visible breaks' torn strips across the visible plane width (DS `GraphBreak`, graph.css `.zs-break*`):
  /// over the edges and gap marks, under the cards.
  void paintBreaks(PaintingContext context, Offset origin, Rect visible) {
    final Canvas canvas = context.canvas;
    for (final GraphAxisBreak b in axis.breaks) {
      final double c = b.centre;
      if (c + _breakEdge + 3 < visible.top || c - _breakEdge - 3 > visible.bottom) {
        continue;
      }
      final List<Offset> up = graphZigzag(visible.left, visible.right, c - _breakEdge, 0);
      final List<Offset> lo = graphZigzag(visible.left, visible.right, c + _breakEdge, 1);
      final edgeUp = Path()..addPolygon(<Offset>[for (final p in up) p + origin], false);
      final edgeLo = Path()..addPolygon(<Offset>[for (final p in lo) p + origin], false);
      final fill = Path()
        ..addPolygon(<Offset>[for (final p in up) p + origin, for (final p in lo.reversed) p + origin], true);
      canvas
        ..drawPath(fill, Paint()..color = colors.flBgSolid.withValues(alpha: colors.flBgSolid.a * .92))
        ..drawPath(
          edgeUp,
          Paint()
            ..color = colors.borderStrong
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..strokeJoin = StrokeJoin.round,
        )
        ..drawPath(
          edgeLo,
          Paint()
            ..color = colors.borderStrong
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..strokeJoin = StrokeJoin.round,
        );
    }
  }

  /// Paints the visible labels, sticky at viewport x [leftInset] − 4, each centred on its y: the days, the breaks'
  /// spans and the years where they begin (Story 10.31).
  void paintLabels(PaintingContext context, Offset origin, Rect visible, {required double leftInset}) {
    final Canvas canvas = context.canvas;
    final double left = (origin.dx + visible.left + leftInset + _labelLeft).roundToDouble();
    final (:int start, :int end) = axis.labelsBetween(visible.top - _labelReach, visible.bottom + _labelReach);
    for (var b = start; b < end; b++) {
      _pill(canvas, _label(b), left, origin.dy + axis.labelYs[b]);
    }
    for (var i = 0; i < axis.breaks.length; i++) {
      final double c = axis.breaks[i].centre;
      if (c < visible.top - _labelReach || c > visible.bottom + _labelReach) {
        continue;
      }
      final TextPainter? text = _breakLabel(i);
      if (text != null) {
        _pill(canvas, text, left, origin.dy + c);
      }
    }
    for (final GraphAxisYear y in axis.canvasYears) {
      final double centre = y.y - GraphDayAxis.yearRaise;
      if (centre < visible.top - _labelReach || centre > visible.bottom + _labelReach) {
        continue;
      }
      final TextPainter text = _year(y.year);
      // At the day label's left: the pill's text starts past its padding and border.
      text.paint(
        canvas,
        Offset(left + _padX + _border, (origin.dy + centre - text.height / 2).roundToDouble()),
      );
    }
  }

  void _pill(Canvas canvas, TextPainter text, double left, double centre) {
    final double height = text.height + 2 * (_padY + _border);
    final rect = Rect.fromLTWH(left, (centre - height / 2).roundToDouble(), text.width + 2 * (_padX + _border), height);
    final pill = RRect.fromRectAndRadius(rect, Radius.circular(ZsMetrics.standard.radiusTag));
    canvas
      ..drawRRect(pill, Paint()..color = theme.dayLabelFill)
      ..drawRRect(
        pill.deflate(_border / 2),
        Paint()
          ..color = theme.dayLabelBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = _border,
      );
    text.paint(canvas, rect.topLeft + const Offset(_padX + _border, _padY + _border));
  }

  TextPainter _text(String text, TextStyle style) => TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
  )..layout();

  TextPainter _label(int b) => _labels.putIfAbsent(
    b,
    () => _text(
      graphDayLabel(strings, axis.values[b], nowMs: nowMs, utcOffsetMinutes: utcOffsetMinutes),
      ZsType.id.copyWith(fontSize: ZsType.fsSm, color: theme.dayLabelText),
    ),
  );

  TextPainter? _breakLabel(int i) => _breakLabels.putIfAbsent(i, () {
    final GraphAxisBreak b = axis.breaks[i];
    final String? label = graphBreakLabel(strings, b.t0, b.t1, utcOffsetMinutes: utcOffsetMinutes);
    return label == null ? null : _text(label, ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textDim));
  });

  TextPainter _year(int year) => _years.putIfAbsent(
    year,
    () => _text(graphYearLabel(strings, year), graphYearStyle(colors)),
  );

  /// Releases the cached text.
  void dispose() {
    for (final text in <TextPainter?>[..._labels.values, ..._breakLabels.values, ..._years.values]) {
      text?.dispose();
    }
    _labels.clear();
    _breakLabels.clear();
    _years.clear();
  }
}

/// A year label's style (DS graph.css `.zs-year-label`, float.css `.gmini-year`): 600 `--fs-xs` sans, tracked
/// `--tracking-pill`, line height 1, `--text-muted`.
TextStyle graphYearStyle(ZsColors colors) => ZsType.capsLabel.copyWith(
  height: 1,
  letterSpacing: ZsType.trackingPill * ZsType.fsXs,
  color: colors.textMuted,
);
