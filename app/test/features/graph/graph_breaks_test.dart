// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_breaks.dart';

void main() {
  int? noTime(int node) => null;

  test('a long stack: a gap of 1760 above row 40 shortens to 24; one break (40, 64)', () {
    final rows = <int>[0, 16, 40, 1800, 1816];
    final cuts = GraphBreaks.compute(rows, 16, (node) => 1000 * node);
    expect(<int>[for (final r in rows) cuts.map(r)], <int>[0, 16, 40, 64, 80]);
    expect(cuts.breaks, <GraphBreak>[const GraphBreak(lowerRow: 40, upperRow: 64, t0: 2000, t1: 3000)]);
  });

  test('a gap of exactly 8 pitches is not cut', () {
    final cuts = GraphBreaks.compute(const <int>[0, 128, 144], 16, noTime);
    expect(cuts.breaks, isEmpty);
    expect(cuts.map(128), 128);
  });

  test('several cuts accumulate their savings and keep the rows strictly ordered', () {
    final rows = <int>[0, 200, 216, 600, 616];
    final cuts = GraphBreaks.compute(rows, 16, noTime);
    final mapped = <int>[for (final r in rows) cuts.map(r)];
    expect(mapped, <int>[0, 24, 40, 64, 80]);
    for (var i = 1; i < mapped.length; i++) {
      expect(mapped[i], greaterThan(mapped[i - 1]));
    }
    expect(cuts.breaks.map((b) => (b.lowerRow, b.upperRow)), <(int, int)>[(0, 24), (40, 64)]);
  });

  test('a row inside a cut stretch stays below the upper row; a folded member (−1) stays −1', () {
    final cuts = GraphBreaks.compute(const <int>[0, 400, -1], 16, noTime);
    expect(cuts.map(-1), -1);
    expect(cuts.map(8), 8);
    expect(cuts.map(300), 23, reason: 'clamped under the upper row');
    expect(cuts.map(400), 24);
    expect(cuts.map(416), 40);
  });

  test('the times: the lower row\'s newest and the upper row\'s oldest, nulls ignored; none at all: null', () {
    // Two cards on each side of the gap.
    final rows = <int>[0, 0, 500, 500];
    final times = <int?>[5, 9, null, 20];
    final cuts = GraphBreaks.compute(rows, 16, (node) => times[node]);
    expect(cuts.breaks.single, const GraphBreak(lowerRow: 0, upperRow: 24, t0: 9, t1: 20));
    final bare = GraphBreaks.compute(rows, 16, noTime);
    expect(bare.breaks.single.t0, isNull);
    expect(bare.breaks.single.t1, isNull);
  });

  test('no cuts: the identity', () {
    expect(GraphBreaks.none.map(1234), 1234);
    expect(GraphBreaks.compute(const <int>[], 16, noTime).breaks, isEmpty);
  });
}
