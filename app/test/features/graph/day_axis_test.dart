// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/src/features/graph/day_axis.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/synthetic_layout.dart';
import 'graph_harness.dart';

const _day = 86400000;
final macOS = TargetPlatformVariant.only(TargetPlatform.macOS);
final int _utcSep20 = DateTime.utc(2026, 9, 20).millisecondsSinceEpoch;

/// A free chain of [days] days, one card per day two pitches apart in column `k % 8`, the root below them: node 0 is
/// the newest day, node [days] the root. Day `k` (oldest first) is Sep 20 + k.
RecordedGraphLayout dayChain(int days) => handLayout(
  <(String, int, int)>[
    for (int k = days; k >= 1; k--) ('d$k', 32 * k, k % 8),
    ('root', 0, 0),
  ],
  unit: 16,
  root: days,
  buckets: <(int, int, int)>[for (var k = 1; k <= days; k++) (_utcSep20 + (k - 1) * _day, 32 * k, 32 * k)],
);

/// What one paint of the viewport drew.
typedef Painted = ({List<Symbol> calls, List<RRect> pills, List<double> guideYs});

Painted painted(WidgetTester tester, GraphHarness g) {
  final calls = <Symbol>[];
  final pills = <RRect>[];
  final guideYs = <double>{};
  expect(
    g.render(tester),
    paints..everything((method, arguments) {
      calls.add(method);
      if (method == #drawRRect && (arguments[1] as Paint).style == PaintingStyle.fill) {
        pills.add(arguments[0] as RRect);
      }
      if (method == #drawRawPoints) {
        final points = arguments[1] as Float32List;
        for (var i = 1; i < points.length; i += 2) {
          guideYs.add(points[i]);
        }
      }
      return true;
    }),
  );
  return (calls: calls, pills: pills, guideYs: guideYs.toList()..sort());
}

/// Wires a day-axis painter of [g]'s layout (on [g]'s vertical layout, or uniform rows) into its hooks.
GraphDayAxisPainter wireAxis(GraphHarness g, {required int nowMs}) {
  final VerticalLayout rows = g.verticalLayout ??= UniformRows(g.layout, g.metrics);
  final painter = GraphDayAxisPainter(
    axis: GraphDayAxis.of(g.layout, rows),
    theme: GraphTheme.night,
    strings: AppLocalizationsEn(),
    nowMs: nowMs,
    utcOffsetMinutes: g.layout.utcOffsetMinutes,
  );
  addTearDown(painter.dispose);
  g
    ..background = painter.paintGuides
    ..overlay = ((context, origin, visible) => painter.paintLabels(context, origin, visible, leftInset: g.insets.left));
  return painter;
}

double textWidth(String text) {
  final painter = TextPainter(
    text: TextSpan(
      text: text,
      style: ZsType.id.copyWith(fontSize: ZsType.fsSm),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  addTearDown(painter.dispose);
  return painter.width;
}

void main() {
  group('graphDayLabel', () {
    final int now = DateTime.utc(2026, 9, 26, 10).millisecondsSinceEpoch;
    String label(DateTime day, {int at = 0, int offset = 0}) => graphDayLabel(
      AppLocalizationsEn(),
      day.millisecondsSinceEpoch,
      nowMs: at == 0 ? now : at,
      utcOffsetMinutes: offset,
    );

    test('today and a future day are "Today"', () {
      expect(label(DateTime.utc(2026, 9, 26)), 'Today');
      expect(label(DateTime.utc(2026, 9, 27)), 'Today');
    });

    test('the day before is "Yesterday"', () => expect(label(DateTime.utc(2026, 9, 25)), 'Yesterday'));

    test('an older day this year is "MMM d"', () {
      expect(label(DateTime.utc(2026, 9, 24)), 'Sep 24');
      expect(label(DateTime.utc(2026, 1, 3)), 'Jan 3');
    });

    test(
      'a previous-year day carries no year (Story 10.31: years get labels of their own)',
      () => expect(label(DateTime.utc(2015, 12, 16)), 'Dec 16'),
    );

    test('"Yesterday" crosses a year boundary', () {
      final int newYear = DateTime.utc(2027, 1, 1, 10).millisecondsSinceEpoch;
      expect(label(DateTime.utc(2026, 12, 31), at: newYear), 'Yesterday');
      expect(label(DateTime.utc(2026, 12, 30), at: newYear), 'Dec 30');
    });
  });

  group('graphBreakLabel (Story 10.31)', () {
    String? label(DateTime t0, DateTime t1, {int offset = 0}) => graphBreakLabel(
      AppLocalizationsEn(),
      t0.millisecondsSinceEpoch,
      t1.millisecondsSinceEpoch,
      utcOffsetMinutes: offset,
    );

    test('years, months, weeks and days, with the range by what differs', () {
      expect(label(DateTime.utc(2019, 9, 2), DateTime.utc(2025, 5, 20)), '6 years · Sep 2019 – May 2025');
      expect(label(DateTime.utc(2025, 4, 10), DateTime.utc(2025, 12, 2)), '8 months · Apr – Dec 2025');
      expect(label(DateTime.utc(2025, 6, 3), DateTime.utc(2025, 6, 24)), '3 weeks · Jun 3 – 24');
      expect(label(DateTime.utc(2025, 6, 3), DateTime.utc(2025, 6, 4)), '1 day · Jun 3 – 4');
      expect(
        label(DateTime.utc(2025, 6, 3, 9), DateTime.utc(2025, 6, 3, 10)),
        '1 day · Jun 3',
        reason: 'at least 1; one day names its date once',
      );
      expect(
        label(DateTime.utc(2025, 5, 20), DateTime.utc(2019, 9, 2)),
        '6 years · Sep 2019 – May 2025',
        reason: 'a reversed pair reads oldest first',
      );
      expect(label(DateTime.utc(2024, 1, 2), DateTime.utc(2025, 7, 2)), '18 months · Jan 2024 – Jul 2025');
    });

    test('the boundaries: 548 days are years, 60 months, 14 weeks', () {
      final t0 = DateTime.utc(2020, 2, 2);
      expect(label(t0, t0.add(const Duration(days: 548))), startsWith('2 years'));
      expect(label(t0, t0.add(const Duration(days: 547))), startsWith('18 months'));
      expect(label(t0, t0.add(const Duration(days: 60))), startsWith('2 months'));
      expect(label(t0, t0.add(const Duration(days: 59))), startsWith('8 weeks'));
      expect(label(t0, t0.add(const Duration(days: 14))), startsWith('2 weeks'));
      expect(label(t0, t0.add(const Duration(days: 13))), startsWith('13 days'));
    });

    test('read at the layout offset; null when a time is missing', () {
      // 23:30 UTC on Dec 31 is Jan 1 at +01:00.
      expect(label(DateTime.utc(2024, 12, 31, 23, 30), DateTime.utc(2025, 1, 30), offset: 60), '4 weeks · Jan 1 – 30');
      expect(graphBreakLabel(AppLocalizationsEn(), null, 1, utcOffsetMinutes: 0), isNull);
      expect(graphBreakLabel(AppLocalizationsEn(), 1, null, utcOffsetMinutes: 0), isNull);
    });
  });

  group('breaks and years (Story 10.31)', () {
    final metrics = GraphMetrics();
    final double h = metrics.cardHeight;
    int day(int y, int m, int d) => DateTime.utc(y, m, d).millisecondsSinceEpoch;

    // Four days, one card each: Aug 20 and Sep 1 2019, then (after a break) May 10 and May 12 2025.
    final GraphLayout inner = handLayout(
      const <(String, int, int)>[('n2', 88, 0), ('n1', 64, 0), ('o', 40, 0), ('b', 0, 0)],
      edges: const <(int, int)>[(0, 1), (1, 2), (2, 3)],
      unit: 16,
      timestamps: <int?>[day(2025, 5, 12), day(2025, 5, 10), day(2019, 9, 1), day(2019, 8, 20)],
      buckets: <(int, int, int)>[
        (day(2019, 8, 20), 0, 0),
        (day(2019, 9, 1), 40, 40),
        (day(2025, 5, 10), 64, 64),
        (day(2025, 5, 12), 88, 88),
      ],
    );
    final broken = BrokenLayout(inner, <GraphBreak>[
      GraphBreak(lowerRow: 40, upperRow: 64, t0: day(2019, 9, 1), t1: day(2025, 5, 10)),
    ]);

    test('the band runs from the upper card\'s bottom to the lower card\'s top; its day and year drop out', () {
      final rows = UniformRows(broken, metrics);
      final axis = GraphDayAxis.of(broken, rows);
      expect(axis.breaks, hasLength(1));
      final GraphAxisBreak band = axis.breaks.single;
      expect(band.top, rows.topOfRow(64) + h);
      expect(band.bottom, rows.topOfRow(40));
      expect(axis.length, 3, reason: 'May 10\'s divider lies in the band: no label, no divider');
      expect(axis.values, <int>[day(2019, 8, 20), day(2019, 9, 1), day(2025, 5, 12)]);
      expect(axis.guideYs, hasLength(2));
      for (final double g in axis.guideYs) {
        expect(band.contains(g), isFalse);
      }
      expect(axis.years.map((y) => (y.year, y.below, y.inBand)), <(int, int?, bool)>[
        (2019, null, false),
        (2025, 2019, true),
      ]);
      expect(axis.years.last.y, band.top, reason: 'a boundary in a break sits at the band\'s top');
      expect(axis.canvasYears, isEmpty, reason: 'no canvas year inside a break');
    });

    test('a year where it begins: the newer year at its first day\'s label; none for a one-year history', () {
      final GraphLayout layout = handLayout(
        const <(String, int, int)>[('c', 48, 0), ('b', 32, 0), ('a', 16, 0)],
        unit: 16,
        buckets: <(int, int, int)>[(day(2023, 12, 30), 16, 16), (day(2024, 1, 2), 32, 32), (day(2024, 1, 3), 48, 48)],
      );
      final axis = GraphDayAxis.of(layout, UniformRows(layout, metrics));
      expect(axis.length, 3);
      final List<GraphAxisYear> years = axis.canvasYears.toList();
      expect(years.map((y) => (y.year, y.below)), <(int, int?)>[(2024, 2023)]);
      expect(years.single.y, axis.labelYs[1], reason: 'the first 2024 day\'s label');

      final GraphLayout oneYear = handLayout(
        const <(String, int, int)>[('b', 32, 0), ('a', 16, 0)],
        unit: 16,
        buckets: <(int, int, int)>[(day(2024, 1, 2), 16, 16), (day(2024, 1, 3), 32, 32)],
      );
      expect(GraphDayAxis.of(oneYear, UniformRows(oneYear, metrics)).canvasYears, isEmpty);
    });

    testWidgets('the strip paints over the edges and under the cards; the break label and the year paint as labels', (
      tester,
    ) async {
      final g = GraphHarness(broken);
      final rows = UniformRows(broken, metrics);
      g.verticalLayout = rows;
      final painter = GraphDayAxisPainter(
        axis: GraphDayAxis.of(broken, rows),
        theme: GraphTheme.night,
        strings: AppLocalizationsEn(),
        nowMs: day(2026, 11, 6),
        utcOffsetMinutes: 0,
      );
      addTearDown(painter.dispose);
      g
        ..background = painter.paintGuides
        ..edges = ((context, origin, visible) {
          context.canvas.drawPath(Path(), Paint());
          painter.paintBreaks(context, origin, visible);
        })
        ..overlay = ((context, origin, visible) => painter.paintLabels(context, origin, visible, leftInset: 0));
      await pumpGraph(tester, g);
      final Painted p = painted(tester, g);
      final List<Symbol> calls = p.calls;
      // The edge hook's empty path, then the strip's fill and its two torn edges, then the cards, then the pills.
      expect(calls.where((m) => m == #drawPath), hasLength(4));
      expect(calls.lastIndexOf(#drawPath), lessThan(calls.indexOf(#drawRect)));
      expect(
        g.render(tester),
        paints
          ..path()
          ..path(color: ZsColors.night.flBgSolid.withValues(alpha: ZsColors.night.flBgSolid.a * .92))
          ..path(color: ZsColors.night.borderStrong, style: PaintingStyle.stroke)
          ..path(color: ZsColors.night.borderStrong, style: PaintingStyle.stroke),
      );
      final double centre = GraphDayAxis.of(broken, rows).breaks.single.centre;
      expect(
        p.pills.where((pill) => (pill.center.dy - (centre - g.v.offset)).abs() < 1),
        hasLength(1),
        reason: 'the break label pill sits on the band\'s centre',
      );
    });
  });

  group('graphDayLabel at an offset', () {
    String label(DateTime day, {required int at, int offset = 0}) =>
        graphDayLabel(AppLocalizationsEn(), day.millisecondsSinceEpoch, nowMs: at, utcOffsetMinutes: offset);

    test('with offset −420 a local-midnight value shows the local date', () {
      // 03:00 UTC on Sep 26 is 20:00 on Sep 25 at −07:00; local midnight of Sep 25 is 07:00 UTC on Sep 25.
      final int evening = DateTime.utc(2026, 9, 26, 3).millisecondsSinceEpoch;
      expect(label(DateTime.utc(2026, 9, 25, 7), at: evening, offset: -420), 'Today');
      expect(label(DateTime.utc(2026, 9, 24, 7), at: evening, offset: -420), 'Yesterday');
      expect(label(DateTime.utc(2026, 9, 23, 7), at: evening, offset: -420), 'Sep 23');
    });

    test('with offset 120 a local-midnight value shows the local date', () {
      // 23:00 UTC on Sep 25 is 01:00 on Sep 26 at +02:00; local midnight of Sep 25 is 22:00 UTC on Sep 24.
      final int late = DateTime.utc(2026, 9, 25, 23).millisecondsSinceEpoch;
      expect(label(DateTime.utc(2026, 9, 25, 22), at: late, offset: 120), 'Today');
      expect(label(DateTime.utc(2026, 9, 24, 22), at: late, offset: 120), 'Yesterday');
      expect(label(DateTime.utc(2026, 9, 23, 22), at: late, offset: 120), 'Sep 24');
      expect(label(DateTime.utc(2026, 9, 24, 22), at: late), 'Sep 24', reason: 'at UTC it is the day before');
    });
  });

  group('placement', () {
    // Day 0 {d0a, d0b}, day 1 {d1}, day 2 {d2} close above it, day 3 {d3a, d3b} sharing d2's row.
    const nodes = <(String, int, int)>[
      ('d3b', 52, 0),
      ('d3a', 36, 2),
      ('d2', 36, 1),
      ('d1', 34, 0),
      ('d0b', 32, 0),
      ('d0a', 16, 0),
      ('root', 0, 0),
    ];
    const buckets = <(int, int, int)>[(0, 16, 32), (_day, 34, 34), (2 * _day, 36, 36), (3 * _day, 36, 52)];
    final metrics = GraphMetrics();
    final double h = metrics.cardHeight;
    final RecordedGraphLayout withRoot = handLayout(nodes, unit: 16, buckets: buckets, root: 6);
    final RecordedGraphLayout withoutRoot = handLayout(nodes, unit: 16, buckets: buckets);
    final verticals = <String, VerticalLayout Function(GraphLayout)>{
      'UniformRows': (layout) => UniformRows(layout, metrics),
      'PerNodeTops': (layout) =>
          PerNodeTops(layout, metrics, Float64List.fromList(<double>[50, 320, 320, 330, 360, 500, 700])),
    };

    for (final MapEntry<String, VerticalLayout Function(GraphLayout)>(key: name, value: make) in verticals.entries) {
      test('on $name: dividers between the days, the oldest label to the root, pushes and the shared row', () {
        final VerticalLayout v = make(withRoot);
        final axis = GraphDayAxis.of(withRoot, v);
        expect(axis.length, 4);
        expect(axis.guideYs, hasLength(3), reason: 'the oldest day has no divider');
        expect(axis.guideYs[0], (v.top(4) + v.top(3) + h) / 2);
        expect(axis.guideYs[1], (v.top(3) + v.top(2) + h) / 2);
        expect(axis.guideYs[2], v.top(1) + h / 2, reason: 'a shared row puts the divider through the card');
        expect(axis.labelYs[0], (v.top(6) + v.top(5) + h) / 2, reason: 'midway to the root');
        expect(axis.labelYs[1], axis.guideYs[0]);
        expect(axis.guideYs[1], greaterThan(axis.labelYs[1] - GraphDayAxis.minLabelGap));
        expect(axis.labelYs[2], axis.labelYs[1] - GraphDayAxis.minLabelGap, reason: 'pushed up to exactly 22 px');
        expect(axis.labelYs[3], inInclusiveRange(v.top(1), v.top(1) + h), reason: 'inside the card (known limit)');

        final VerticalLayout bare = make(withoutRoot);
        expect(GraphDayAxis.of(withoutRoot, bare).labelYs[0], bare.top(5) + h + metrics.gapY / 2);
      });
    }

    test('a compact layout, an empty free layout and a free layout without buckets have no axis', () {
      final RecordedGraphLayout unbucketed = handLayout(const <(String, int, int)>[
        ('a', 16, 0),
        ('b', 0, 0),
      ], unit: 16);
      expect(GraphDayAxis.of(unbucketed, UniformRows(unbucketed, metrics)).length, 0);
      final RecordedGraphLayout compact = handLayout(
        const <(String, int, int)>[('a', 0, 0)],
        buckets: const <(int, int, int)>[(0, 0, 0)],
      );
      expect(GraphDayAxis.of(compact, UniformRows(compact, metrics)).length, 0);
      final RecordedGraphLayout empty = handLayout(const <(String, int, int)>[], unit: 16);
      expect(GraphDayAxis.of(empty, UniformRows(empty, metrics)).length, 0);
    });

    final free = <String, RecordedGraphLayout Function()>{
      for (final String name in graphRecordingNames)
        if (name.contains(' free ')) name: () => recording(name),
      'synthetic 10k free': () => syntheticLayout(10000, free: true),
    };
    for (final MapEntry<String, RecordedGraphLayout Function()>(key: name, value: make) in free.entries) {
      test('$name: one label per bucket, strictly decreasing, at least 22 px apart', () {
        final RecordedGraphLayout layout = make();
        final axis = GraphDayAxis.of(layout, UniformRows(layout, metrics));
        expect(layout.bucketCount, greaterThan(0));
        expect(axis.length, layout.bucketCount);
        for (var b = 1; b < axis.length; b++) {
          expect(axis.labelYs[b], lessThanOrEqualTo(axis.labelYs[b - 1] - GraphDayAxis.minLabelGap));
        }
      });
    }
  });

  group('painting', () {
    testWidgets('a free recording paints clip, one guide call, edges, cards, then the pills; compact paints none', (
      tester,
    ) async {
      final g = GraphHarness(recording('design-default free compact'))
        ..edges = ((context, origin, visible) => context.canvas.drawPath(Path(), Paint()));
      final GraphDayAxisPainter axis = wireAxis(g, nowMs: 1790344800000);
      await pumpGraph(tester, g);
      g.v.jumpTo(axis.axis.guideYs.last - surface.height / 2);
      await tester.pump();
      final Painted free = painted(tester, g);
      final List<Symbol> calls = free.calls;
      expect(calls.where((m) => m == #drawRawPoints), hasLength(1));
      expect(calls.indexOf(#clipRect), lessThan(calls.indexOf(#drawRawPoints)));
      expect(calls.indexOf(#drawRawPoints), lessThan(calls.indexOf(#drawPath)));
      expect(calls.indexOf(#drawPath), lessThan(calls.indexOf(#drawRect)));
      expect(free.pills, isNotEmpty);
      expect(calls.lastIndexOf(#drawRect), lessThan(calls.indexOf(#drawRRect)));

      g
        ..layout = recording('design-default compact compact')
        ..verticalLayout = null;
      wireAxis(g, nowMs: 1790344800000);
      await tester.pumpWidget(g.build());
      final Painted compact = painted(tester, g);
      expect(compact.calls, isNot(contains(#drawRawPoints)));
      expect(compact.calls, isNot(contains(#drawRRect)));
    });

    testWidgets('Free and Compact share the width and the columns; only Free paints the axis', (tester) async {
      final RecordedGraphLayout free = recording('design-all free compact');
      final RecordedGraphLayout compact = recording('design-all compact compact');
      expect(
        <int>[for (var i = 0; i < free.nodeCount; i++) free.colOf(i)],
        <int>[
          for (var i = 0; i < compact.nodeCount; i++) compact.colOf(i),
        ],
      );
      final g = GraphHarness(free);
      final GraphDayAxisPainter axis = wireAxis(g, nowMs: 1790344800000);
      await pumpGraph(tester, g);
      g.v.jumpTo(axis.axis.guideYs.last - surface.height / 2);
      await tester.pump();
      final double width = g.h.position.maxScrollExtent;
      final Painted inFree = painted(tester, g);
      expect(inFree.calls, contains(#drawRawPoints));
      expect(inFree.pills, isNotEmpty);
      g
        ..layout = compact
        ..verticalLayout = null;
      wireAxis(g, nowMs: 1790344800000);
      await tester.pumpWidget(g.build());
      expect(g.h.position.maxScrollExtent, width);
      final Painted inCompact = painted(tester, g);
      expect(inCompact.calls, isNot(contains(#drawRawPoints)));
      expect(inCompact.pills, isEmpty);
    });

    testWidgets('labels stay at inset − 4 under a horizontal scroll and move with a vertical one', (tester) async {
      final g = GraphHarness(dayChain(30))..insets = const EdgeInsets.only(left: 76);
      wireAxis(g, nowMs: _utcSep20 + 30 * _day);
      await pumpGraph(tester, g);
      g.v.jumpTo(1000);
      await tester.pump();
      final Painted before = painted(tester, g);
      expect(before.pills, isNotEmpty);
      expect(before.guideYs, isNotEmpty);
      expect(before.pills.map((p) => p.left), everyElement(72));

      g.h.jumpTo(300);
      await tester.pump();
      final Painted across = painted(tester, g);
      expect(across.pills.map((p) => p.left), everyElement(72));
      expect(across.pills.map((p) => p.center.dy), before.pills.map((p) => p.center.dy));
      expect(across.guideYs, before.guideYs);

      const d = 150.0;
      g.v.jumpTo(1000 + d);
      await tester.pump();
      final Painted down = painted(tester, g);
      final List<double> labelsDown = down.pills.map((p) => p.center.dy).toList();
      var kept = 0;
      for (final RRect pill in before.pills) {
        if (pill.center.dy - d > 30) {
          expect(labelsDown.any((y) => (y - (pill.center.dy - d)).abs() < 1e-6), isTrue, reason: '${pill.center}');
          kept++;
        }
      }
      for (final double y in before.guideYs) {
        if (y - d > 0) {
          expect(down.guideYs, contains(y - d));
          kept++;
        }
      }
      expect(kept, greaterThan(0));
    }, variant: macOS);

    testWidgets('the dashes keep their phase at plane x 0 and span the visible rect', (tester) async {
      final g = GraphHarness(dayChain(30))..insets = const EdgeInsets.only(left: 76);
      wireAxis(g, nowMs: _utcSep20 + 30 * _day);
      await pumpGraph(tester, g);
      g.v.jumpTo(1000);
      await tester.pump();
      for (final scroll in <double>[0, 301]) {
        g.h.jumpTo(scroll);
        await tester.pump();
        final double originX = g.insets.left - g.h.offset;
        final Rect visible = (g.scroll - g.insets.topLeft) & surface;
        final starts = <double, List<double>>{};
        expect(
          g.render(tester),
          paints..everything((method, arguments) {
            if (method == #drawRawPoints) {
              final points = arguments[1] as Float32List;
              for (var i = 0; i < points.length; i += 4) {
                expect(points[i + 2] - points[i], 2, reason: 'a dash is 2 px');
                (starts[points[i + 1]] ??= <double>[]).add(points[i] - originX);
              }
            }
            return true;
          }),
        );
        expect(starts, isNotEmpty);
        for (final List<double> line in starts.values) {
          expect(line.map((x) => x % 8), everyElement(0), reason: 'phase anchored to plane x 0 at scroll $scroll');
          expect(line.first, lessThanOrEqualTo(visible.left));
          expect(line.last + 8, greaterThanOrEqualTo(visible.right));
        }
      }
    }, variant: macOS);

    testWidgets('a left inset changed per frame moves the label column, no card and no divider', (tester) async {
      final g = GraphHarness(dayChain(30))..insets = const EdgeInsets.only(left: 76);
      wireAxis(g, nowMs: _utcSep20 + 30 * _day);
      await pumpGraph(tester, g);
      g.h.jumpTo(400);
      g.v.jumpTo(1000);
      await tester.pump();
      final List<double> guides = painted(tester, g).guideYs;
      final cards = <String, Offset>{for (final String key in g.mounted(tester)) key: g.screenOf(tester, key)};
      expect(cards, isNotEmpty);
      for (final inset in <double>[
        for (var step = 1; step <= 8; step++) 76 + 39.0 * step,
        for (var step = 7; step >= 0; step--) 76 + 39.0 * step,
      ]) {
        g.insets = EdgeInsets.only(left: inset);
        await tester.pumpWidget(g.build());
        final Painted now = painted(tester, g);
        expect(now.pills, isNotEmpty);
        expect(now.pills.map((p) => p.left), everyElement(inset - 4), reason: 'at $inset');
        expect(now.guideYs, guides, reason: 'at $inset');
        for (final MapEntry<String, Offset>(:key, :value) in cards.entries) {
          expect(g.screenOf(tester, key), value, reason: '$key at $inset');
        }
      }
    }, variant: macOS);

    testWidgets('a tap at a label over a card reaches the card', (tester) async {
      // a (older day) and b (newer day) share row 16: b's label sits on b's card, in column 0.
      final g = GraphHarness(
        handLayout(
          const <(String, int, int)>[('b', 16, 0), ('a', 16, 1), ('far', 16, 5), ('root', 0, 0)],
          unit: 16,
          root: 3,
          buckets: const <(int, int, int)>[(0, 16, 16), (_day, 16, 16)],
        ),
      )..insets = const EdgeInsets.only(left: 76);
      wireAxis(g, nowMs: _day);
      await pumpGraph(tester, g);
      g.h.jumpTo(60);
      await tester.pump();
      final List<RRect> pills = painted(tester, g).pills;
      final Offset centre = pills.reduce((a, b) => a.center.dy < b.center.dy ? a : b).center;
      expect(tester.getRect(find.byWidgetPredicate((w) => w is TestCard && w.nodeKey == 'b')).contains(centre), isTrue);
      await tester.tapAt(centre);
      expect(g.log.taps, <String>['b']);
    }, variant: macOS);

    testWidgets('"now" past midnight re-formats the labels with a repaint, no layout', (tester) async {
      final RecordedGraphLayout layout = dayChain(3);
      final g = GraphHarness(layout);
      final int noon = _utcSep20 + 2 * _day + 12 * 3600000;
      wireAxis(g, nowMs: noon);
      await pumpGraph(tester, g);
      double newestWidth() => painted(tester, g).pills.reduce((a, b) => a.center.dy < b.center.dy ? a : b).width;
      expect(newestWidth(), textWidth('Today') + 16);

      wireAxis(g, nowMs: noon + _day);
      await tester.pumpWidget(g.build(), phase: EnginePhase.build);
      expect(g.layout, same(layout));
      expect(g.render(tester).debugNeedsLayout, isFalse);
      expect(g.render(tester).debugNeedsPaint, isTrue);
      await tester.pump();
      expect(newestWidth(), textWidth('Yesterday') + 16);
    });
  });
}
