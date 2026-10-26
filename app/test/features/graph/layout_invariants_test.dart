// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin/src/features/graph/vertical_layout.dart';

import '../../../widgetbook/graph/graph_recordings.g.dart';
import '../../../widgetbook/graph/synthetic_layout.dart';
import 'graph_harness.dart';

Set<LayoutInvariant> violated(GraphLayout layout, {VerticalLayout? vertical}) =>
    checkLayoutInvariants(layout, vertical: vertical).map((v) => v.invariant).toSet();

void main() {
  group('(p) every fixture passes the hard invariants', () {
    for (final String name in graphRecordingNames) {
      test(name, () => expect(checkLayoutInvariants(recording(name)), isEmpty));
    }
    for (final int size in syntheticSizes) {
      for (final free in <bool>[false, true]) {
        test('synthetic $size ${free ? 'free' : 'compact'}', () {
          final RecordedGraphLayout layout = syntheticLayout(size, free: free);
          expect(layout.nodeCount, size);
          expect(layout.unit, free ? 16 : 1);
          expect(layout.colCount, greaterThanOrEqualTo(100));
          expect(checkLayoutInvariants(layout), isEmpty);
          final ({bool merge, bool indirect, bool stub}) has = (
            merge: List<int>.generate(layout.edgeCount, (e) => e).any((e) => layout.shapeOf(e) == GraphEdgeShape.merge),
            indirect: List<int>.generate(
              layout.edgeCount,
              (e) => e,
            ).any((e) => layout.kindOf(e) == GraphEdgeKind.indirect),
            stub: List<int>.generate(layout.nodeCount, (i) => i).any(layout.elidedOf),
          );
          expect(has, (merge: true, indirect: true, stub: true));
        });
      }
    }
    test('the synthetic generator is deterministic', () {
      final RecordedGraphLayout a = syntheticLayout(10000);
      final RecordedGraphLayout b = syntheticLayout(10000);
      for (var i = 0; i < a.nodeCount; i += 97) {
        expect((b.keyOf(i), b.rowOf(i), b.colOf(i)), (a.keyOf(i), a.rowOf(i), a.colOf(i)));
      }
      expect(b.edgeCount, a.edgeCount);
    });
  });

  group('(p) the checker rejects hand-built violations', () {
    test("two nodes in one (row, col) cell: the prototype's r at 13:59 and k←r at 13:55", () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('k', 1, 0), ('r', 1, 0), ('base', 0, 0)],
        edges: const <(int, int)>[(0, 1), (1, 2)],
      );
      expect(violated(layout), contains(LayoutInvariant.noOverlappingCards));
    });

    test('a child placed below its parent', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 0, 0), ('parent', 1, 1)],
        edges: const <(int, int)>[(0, 1)],
      );
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.childAboveParent});
    });

    test('a duplicate (child, parent) edge', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 1, 0), ('parent', 0, 0)],
        edges: const <(int, int)>[(0, 1), (0, 1)],
      );
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.noDuplicateEdge});
    });

    test('a dangling edge', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 1, 0), ('parent', 0, 0)],
        edges: const <(int, int)>[(0, 1), (1, 7)],
      );
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.noDanglingEdge});
    });

    test('a repeated key', () {
      final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[('same', 1, 0), ('same', 0, 0)]);
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.uniqueKeys});
    });

    test('free cards closer than one pitch in a column', () {
      final RecordedGraphLayout layout = handLayout(const <(String, int, int)>[('a', 20, 0), ('b', 5, 0)], unit: 16);
      expect(violated(layout), <LayoutInvariant>{LayoutInvariant.noOverlappingCards});
      expect(violated(handLayout(const <(String, int, int)>[('a', 21, 0), ('b', 5, 0)], unit: 16)), isEmpty);
    });

    test('PerNodeTops: overlapping tops in a column, and a child less than a pitch above its parent', () {
      final RecordedGraphLayout layout = handLayout(
        const <(String, int, int)>[('child', 1, 0), ('parent', 0, 0), ('other', 0, 1)],
        edges: const <(int, int)>[(0, 1)],
      );
      final metrics = GraphMetrics();
      expect(
        violated(layout, vertical: PerNodeTops(layout, metrics, Float64List.fromList(<double>[56, 166, 56]))),
        isEmpty,
      );
      expect(
        violated(layout, vertical: PerNodeTops(layout, metrics, Float64List.fromList(<double>[56, 100, 56]))),
        <LayoutInvariant>{LayoutInvariant.childAboveParent, LayoutInvariant.noOverlappingCards},
      );
    });
  });
}
