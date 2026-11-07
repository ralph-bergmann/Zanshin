// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_cuts.dart';

void main() {
  test('a long stack: a gap of 1760 above row 40 shortens to 24', () {
    final rows = <int>[0, 16, 40, 1800, 1816];
    final cuts = GraphCuts.compute(rows, 16);
    expect(<int>[for (final r in rows) cuts.map(r)], <int>[0, 16, 40, 64, 80]);
  });

  test('a stretch of exactly 3 pitches stays; one unit more is cut to 1½ pitches', () {
    expect(GraphCuts.compute(const <int>[0, 48, 64], 16).map(64), 64, reason: "Free's longest real pause");
    expect(GraphCuts.compute(const <int>[0, 49], 16).map(49), 24);
  });

  test('several cuts accumulate their savings and keep the rows strictly ordered', () {
    final rows = <int>[0, 200, 216, 600, 616];
    final cuts = GraphCuts.compute(rows, 16);
    final mapped = <int>[for (final r in rows) cuts.map(r)];
    expect(mapped, <int>[0, 24, 40, 64, 80]);
    for (var i = 1; i < mapped.length; i++) {
      expect(mapped[i], greaterThan(mapped[i - 1]));
    }
  });

  test('a row inside a cut stretch stays below the upper row; a folded member (−1) stays −1', () {
    final cuts = GraphCuts.compute(const <int>[0, 400, -1], 16);
    expect(cuts.map(-1), -1);
    expect(cuts.map(8), 8);
    expect(cuts.map(300), 23, reason: 'clamped under the upper row');
    expect(cuts.map(400), 24);
    expect(cuts.map(416), 40);
  });

  test('no cuts: the identity', () {
    expect(GraphCuts.none.map(1234), 1234);
    expect(GraphCuts.compute(const <int>[], 16).map(7), 7);
  });
}
