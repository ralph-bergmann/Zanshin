// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';

/// A shortened card-free stretch of a Free layout (Story 10.31, DS `GraphBreak`): no card in any column between the
/// card rows [lowerRow] and [upperRow] (both shortened rows, 1/U pitch units), which now lie 1½ pitches apart.
@immutable
class GraphBreak {
  /// A break between [lowerRow] and [upperRow], spanning [t0] (the lower row's newest time) to [t1] (the upper row's
  /// oldest), epoch ms, each null when that row carries no time.
  const GraphBreak({required this.lowerRow, required this.upperRow, this.t0, this.t1});

  /// The shortened row below the stretch.
  final int lowerRow;

  /// The shortened row above the stretch.
  final int upperRow;

  /// The newest timestamp of the lower row's cards.
  final int? t0;

  /// The oldest timestamp of the upper row's cards.
  final int? t1;

  @override
  bool operator ==(Object other) =>
      other is GraphBreak &&
      other.lowerRow == lowerRow &&
      other.upperRow == upperRow &&
      other.t0 == t0 &&
      other.t1 == t1;

  @override
  int get hashCode => Object.hash(lowerRow, upperRow, t0, t1);

  @override
  String toString() => 'GraphBreak($lowerRow–$upperRow, $t0–$t1)';
}

/// The Free layout's shortening (Story 10.31): over the distinct rows of laid-out nodes, a step taller than 8 pitches
/// is cut to 1½ pitches and every row above it moves down by the saving. One monotone row map every view reads.
@immutable
class GraphBreaks {
  /// The cuts of [rawRows] (one per node, −1 for a node not laid out) in 1/[unit] pitch units; [timestampOf] gives a
  /// node's time. O(n log n).
  factory GraphBreaks.compute(List<int> rawRows, int unit, int? Function(int node) timestampOf) {
    final int limit = 8 * unit;
    final int target = 3 * unit ~/ 2;
    final order = <int>[
      for (var i = 0; i < rawRows.length; i++)
        if (rawRows[i] >= 0) i,
    ]..sort((a, b) => rawRows[a].compareTo(rawRows[b]));
    final his = <int>[];
    final los = <int>[];
    final shifts = <int>[];
    final t0s = <int?>[];
    final t1s = <int?>[];
    var prevStart = 0;
    for (var k = 1; k <= order.length; k++) {
      if (k < order.length && rawRows[order[k]] == rawRows[order[prevStart]]) {
        continue;
      }
      // order[prevStart ..< k] is one row; the next group starts at k.
      if (k < order.length) {
        final int lo = rawRows[order[prevStart]];
        final int hi = rawRows[order[k]];
        if (hi - lo > limit) {
          int? newest;
          for (var j = prevStart; j < k; j++) {
            final int? t = timestampOf(order[j]);
            if (t != null && (newest == null || t > newest)) {
              newest = t;
            }
          }
          int? oldest;
          for (var j = k; j < order.length && rawRows[order[j]] == hi; j++) {
            final int? t = timestampOf(order[j]);
            if (t != null && (oldest == null || t < oldest)) {
              oldest = t;
            }
          }
          los.add(lo);
          his.add(hi);
          shifts.add((shifts.isEmpty ? 0 : shifts.last) + hi - lo - target);
          t0s.add(newest);
          t1s.add(oldest);
        }
      }
      prevStart = k;
    }
    if (his.isEmpty) {
      return none;
    }
    final breaks = <GraphBreak>[
      for (var c = 0; c < his.length; c++)
        GraphBreak(
          lowerRow: los[c] - (c == 0 ? 0 : shifts[c - 1]),
          upperRow: his[c] - shifts[c],
          t0: t0s[c],
          t1: t1s[c],
        ),
    ];
    return GraphBreaks._(Int32List.fromList(his), Int32List.fromList(los), Int32List.fromList(shifts), breaks);
  }

  const GraphBreaks._(this._his, this._los, this._shifts, this.breaks);

  /// No cuts: [map] is the identity.
  static const none = GraphBreaks._(null, null, null, <GraphBreak>[]);

  final Int32List? _his;
  final Int32List? _los;
  final Int32List? _shifts;

  /// The breaks, lowest first, in shortened rows.
  final List<GraphBreak> breaks;

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
