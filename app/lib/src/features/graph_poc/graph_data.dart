// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';

/// One row of an already laid-out commit graph (lane assignment is done
/// upstream, e.g. by the Rust side). Pure data — no pixels in here.
@immutable
class GraphRow {
  const GraphRow({
    required this.lane,
    required this.colorIndex,
    required this.passThrough,
    required this.parentLanes,
  });

  /// Lane of this row's commit node (and therefore its card).
  final int lane;

  /// Palette index for the node and its outgoing edges.
  final int colorIndex;

  /// Lanes that cross this row top-to-bottom without a node.
  final List<int> passThrough;

  /// Outgoing parent edges: node -> top of the next row at that lane.
  final List<int> parentLanes;
}

/// Immutable graph: rows plus the lane count, both known before any layout.
@immutable
class CommitGraphData {
  CommitGraphData(List<GraphRow> rows) : rows = List<GraphRow>.unmodifiable(rows), laneCount = _laneCount(rows);

  /// Deterministic fake graph with [lanes] parallel lanes and a merge edge
  /// every 7th row.
  factory CommitGraphData.fake(int count, {int lanes = 6}) {
    final passByLane = <List<int>>[
      for (var lane = 0; lane < lanes; lane++)
        List<int>.unmodifiable(<int>[
          for (var l = 0; l < lanes; l++)
            if (l != lane) l,
        ]),
    ];
    return CommitGraphData(
      List<GraphRow>.generate(count, (i) {
        final int lane = ((i * 1103515245 + 12345) >> 8) % lanes;
        return GraphRow(
          lane: lane,
          colorIndex: lane,
          passThrough: passByLane[lane],
          parentLanes: i == count - 1
              ? const <int>[]
              : List<int>.unmodifiable(<int>[lane, if (i % 7 == 3) (lane + 2) % lanes]),
        );
      }, growable: false),
    );
  }

  final List<GraphRow> rows;
  final int laneCount;

  static int _laneCount(List<GraphRow> rows) {
    var max = -1;
    for (final row in rows) {
      if (row.lane > max) {
        max = row.lane;
      }
      for (final int lane in row.passThrough) {
        if (lane > max) {
          max = lane;
        }
      }
      for (final int lane in row.parentLanes) {
        if (lane > max) {
          max = lane;
        }
      }
    }
    return max + 1;
  }
}
