// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';

/// The Free layout's shortening (Story 10.31; changed 2026-11-07, Ralph: no tear): over the distinct rows of laid-out
/// nodes, a step taller than 3 pitches — taller than any real pause Free draws, so only a collapsed stack's folded
/// members leave one — is cut to 1½ pitches, and every row above it moves down by the saving. Nothing marks a cut.
/// One monotone row map every view reads.
@immutable
class GraphCuts {
  /// The cuts of [rawRows] (one per node, −1 for a node not laid out) in 1/[unit] pitch units. O(n log n).
  factory GraphCuts.compute(List<int> rawRows, int unit) {
    final int limit = 3 * unit;
    final int target = 3 * unit ~/ 2;
    final List<int> rows = <int>{
      for (final int row in rawRows)
        if (row >= 0) row,
    }.toList()..sort();
    final his = <int>[];
    final los = <int>[];
    final shifts = <int>[];
    for (var k = 1; k < rows.length; k++) {
      if (rows[k] - rows[k - 1] > limit) {
        los.add(rows[k - 1]);
        his.add(rows[k]);
        shifts.add((shifts.isEmpty ? 0 : shifts.last) + rows[k] - rows[k - 1] - target);
      }
    }
    if (his.isEmpty) {
      return none;
    }
    return GraphCuts._(Int32List.fromList(his), Int32List.fromList(los), Int32List.fromList(shifts));
  }

  const GraphCuts._(this._his, this._los, this._shifts);

  /// No cuts: [map] is the identity.
  static const none = GraphCuts._(null, null, null);

  final Int32List? _his;
  final Int32List? _los;
  final Int32List? _shifts;

  /// [row] shortened: a row inside a cut stretch stays below the stretch's upper row. Rows < 0 stay as they are.
  /// O(log #cuts).
  int map(int row) {
    final Int32List? his = _his;
    if (his == null || row < 0) {
      return row;
    }
    // The number of cuts whose upper row is ≤ row.
    var lo = 0;
    int hi = his.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (his[mid] <= row) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final int shift = lo == 0 ? 0 : _shifts![lo - 1];
    final int mapped = row - shift;
    if (lo < his.length && row > _los![lo]) {
      final int upper = his[lo] - _shifts![lo] - 1;
      return mapped < upper ? mapped : upper;
    }
    return mapped;
  }
}
