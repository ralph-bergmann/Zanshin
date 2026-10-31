// SPDX-License-Identifier: MIT

import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';

import 'graph_harness.dart';

/// The nodes whose inflated card rect meets [window], by a scan over every node.
Set<int> bruteForce(VerticalLayout vertical, Rect window, double overhang) {
  final GraphLayout layout = vertical.layout;
  final GraphMetrics m = vertical.metrics;
  return <int>{
    for (var i = 0; i < layout.nodeCount; i++)
      if (Rect.fromLTWH(
        m.x(layout.colOf(i)),
        vertical.top(i),
        m.cardWidth,
        m.cardHeight,
      ).inflate(overhang).overlaps(window))
        i,
  };
}

void expectQueryMatchesScan(VerticalLayout vertical, {int seed = 7}) {
  final rng = math.Random(seed);
  final double width = vertical.metrics.planeWidth(vertical.layout.colCount);
  final double height = vertical.contentHeight;
  for (var k = 0; k < 300; k++) {
    final window = Rect.fromLTWH(
      rng.nextDouble() * width - 200,
      rng.nextDouble() * height - 200,
      rng.nextDouble() * 1200,
      rng.nextDouble() * 900,
    );
    final double overhang = k.isEven ? 0 : 4;
    final List<int> found = vertical.visibleNodes(window, overhang);
    expect(found.toSet(), bruteForce(vertical, window, overhang), reason: 'window $window, overhang $overhang');
    expect(found, hasLength(found.toSet().length));
  }
}

void main() {
  group('UniformRows', () {
    test('maps rows with the design formulas at U = 1', () {
      final RecordedGraphLayout layout = recording('design-default compact greedy');
      final metrics = GraphMetrics();
      final rows = UniformRows(layout, metrics, bottomExtra: 30);
      for (var i = 0; i < layout.nodeCount; i++) {
        expect(rows.top(i), 56 + (layout.rows - 1 - layout.rowOf(i)) * (62 + 48));
      }
      expect(rows.contentHeight, 2 * 56 + 30 + layout.rows * (62 + 48) - 48);
    });

    test('maps the free output (U = 16) with the same formula, in 1/16 pitch', () {
      final RecordedGraphLayout layout = recording('design-default free compact');
      expect(layout.unit, 16);
      final metrics = GraphMetrics(detailedCards: false);
      final rows = UniformRows(layout, metrics);
      for (var i = 0; i < layout.nodeCount; i++) {
        expect(rows.top(i), 56 + (layout.rows - 16 - layout.rowOf(i)) * (40 + 48) / 16);
      }
      expect(rows.contentHeight, 2 * 56 + layout.rows / 16 * (40 + 48) - 48);
    });

    test('withMetrics remaps in place: the same tops as a fresh index', () {
      final RecordedGraphLayout layout = recording('design-all compact compact');
      final rows = UniformRows(layout, GraphMetrics());
      final UniformRows remapped = rows.withMetrics(GraphMetrics(cardWidth: 300, detailedCards: false));
      final fresh = UniformRows(layout, GraphMetrics(cardWidth: 300, detailedCards: false));
      for (var i = 0; i < layout.nodeCount; i++) {
        expect(remapped.top(i), fresh.top(i));
      }
      expect(remapped.contentHeight, fresh.contentHeight);
      expectQueryMatchesScan(remapped);
    });

    test('an empty layout is a 2·pad plane with no visible node', () {
      final rows = UniformRows(handLayout(const <(String, int, int)>[]), GraphMetrics());
      expect(rows.contentHeight, 2 * 56);
      expect(rows.visibleNodes(const Rect.fromLTWH(0, 0, 800, 600), 4), isEmpty);
    });

    test('(k) the visible query equals a brute-force scan over a compact recording', () {
      expectQueryMatchesScan(UniformRows(recording('medium-narrow compact compact'), GraphMetrics()));
      expectQueryMatchesScan(UniformRows(recording('design-all compact greedy'), GraphMetrics()));
    });

    test('(k) the visible query equals a brute-force scan over a free (U = 16) recording', () {
      expectQueryMatchesScan(UniformRows(recording('medium-narrow free compact'), GraphMetrics()));
      expectQueryMatchesScan(UniformRows(recording('design-all free compact'), GraphMetrics(detailedCards: false)));
    });
  });

  group('PerNodeTops', () {
    final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[
      ('a', 3, 0),
      ('b', 2, 1),
      ('c', 1, 0),
      ('d', 0, 2),
      ('e', 0, 1),
    ]);
    final tops = Float64List.fromList(<double>[56, 130, 250.5, 400, 190]);

    test('takes the given tops; its height is the largest top + H + pad + bottomExtra', () {
      final vertical = PerNodeTops(layout, GraphMetrics(), tops, bottomExtra: 12);
      expect(vertical.top(2), 250.5);
      expect(vertical.contentHeight, 400 + 62 + 56 + 12);
      expect(vertical.withMetrics(GraphMetrics(detailedCards: false)).contentHeight, 400 + 40 + 56 + 12);
    });

    test('(k) the visible query equals a brute-force scan', () {
      expectQueryMatchesScan(PerNodeTops(layout, GraphMetrics(), tops));
      final rng = math.Random(3);
      final RecordedGraphLayout big = recording('medium-narrow compact compact');
      final scattered = Float64List.fromList(<double>[
        for (var i = 0; i < big.nodeCount; i++) rng.nextDouble() * 20000,
      ]);
      expectQueryMatchesScan(PerNodeTops(big, GraphMetrics(), scattered), seed: 11);
    });
  });

  test('folded stack members (Story 10.17) are never in the visible query; their stack nodes are', () {
    final RecordedGraphLayout layout = stackRecording('design-default compact default', inlineContent: false);
    final metrics = GraphMetrics();
    const huge = Rect.fromLTWH(-1000000, -1000000, 2000000, 20000000);
    for (final vertical in <VerticalLayout>[
      UniformRows(layout, metrics),
      PerNodeTops(layout, metrics, Float64List.fromList(<double>[for (var i = 0; i < layout.nodeCount; i++) 80.0 * i])),
    ]) {
      final Set<int> shown = vertical.visibleNodes(huge, 0).toSet();
      expect(shown, <int>{
        for (var i = 0; i < layout.nodeCount; i++)
          if (!layout.isFolded(i)) i,
      });
    }
  });
}
