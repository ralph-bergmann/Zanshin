// SPDX-License-Identifier: MIT

import 'dart:typed_data';
import 'dart:ui';

import 'graph_layout.dart';
import 'graph_metrics.dart';

/// The graph's pixels in y and the visible query (Story 10.1 item 4), in plane coordinates.
///
/// The query runs over a sorted index of the card tops (a binary search, then an x filter), one mechanism for rows
/// and free y, with no row arithmetic.
abstract class VerticalLayout {
  VerticalLayout._(this.layout, this.metrics, this.bottomExtra, Float64List tops, Int32List order)
    : _tops = tops,
      _order = order;

  /// The layout this maps.
  final GraphLayout layout;

  /// The metrics this maps with.
  final GraphMetrics metrics;

  /// Extra height below the oldest card.
  final double bottomExtra;

  /// The tops, ascending.
  final Float64List _tops;

  /// The node of each entry of [_tops].
  final Int32List _order;

  /// The top edge of [node]'s card.
  double top(int node);

  /// The top edge of a card at [row] (in 1/U pitch units) in O(1); defined for rows that hold a node.
  double topOfRow(int row);

  /// The plane's height.
  double get contentHeight;

  /// This mapping for [metrics] over the same layout: O(n), the order of the tops is kept.
  VerticalLayout withMetrics(GraphMetrics metrics);

  /// The nodes whose card rect, inflated by [overhang], intersects [window] (an open intersection: a card that only
  /// touches the window is not in it), in ascending top order.
  List<int> visibleNodes(Rect window, double overhang) {
    final double h = metrics.cardHeight;
    final double w = metrics.cardWidth;
    final double lowest = window.top - h - overhang;
    // First entry with top > lowest.
    var lo = 0;
    int hi = _tops.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (_tops[mid] > lowest) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    final double highest = window.bottom + overhang;
    final result = <int>[];
    for (var k = lo; k < _tops.length && _tops[k] < highest; k++) {
      final int node = _order[k];
      final double x = metrics.x(layout.colOf(node));
      if (x - overhang < window.right && x + w + overhang > window.left) {
        result.add(node);
      }
    }
    return result;
  }
}

/// Uniform rows (Story 10.1 item 4): top(i) = pad + (rows − U − rowOf(i))·(H + gapY)/U, height = 2·pad + bottomExtra +
/// (rows/U)·(H + gapY) − gapY. With U = 1 these are the design's formulas; with `free` output (U = 16) the same
/// mapping yields the free layout.
class UniformRows extends VerticalLayout {
  /// Indexes [layout]'s rows: O(n log n).
  factory UniformRows(GraphLayout layout, GraphMetrics metrics, {double bottomExtra = 0}) {
    final int n = layout.nodeCount;
    // Ascending top = descending row; ties keep the node order. A folded stack member (row −1) is never laid out.
    final sorted =
        <int>[
          for (var i = 0; i < n; i++)
            if (layout.rowOf(i) >= 0) i,
        ]..sort((a, b) {
          final int byRow = layout.rowOf(b).compareTo(layout.rowOf(a));
          return byRow != 0 ? byRow : a.compareTo(b);
        });
    return UniformRows._(layout, metrics, bottomExtra, Int32List.fromList(sorted));
  }

  UniformRows._(GraphLayout layout, GraphMetrics metrics, double bottomExtra, Int32List order)
    : super._(layout, metrics, bottomExtra, Float64List(order.length), order) {
    for (var k = 0; k < order.length; k++) {
      _tops[k] = top(order[k]);
    }
  }

  double get _step => (metrics.cardHeight + metrics.gapY) / layout.unit;

  @override
  double top(int node) => topOfRow(layout.rowOf(node));

  @override
  double topOfRow(int row) => metrics.pad + (layout.rows - layout.unit - row) * _step;

  @override
  double get contentHeight => layout.nodeCount == 0
      ? 2 * metrics.pad + bottomExtra
      : 2 * metrics.pad + bottomExtra + layout.rows / layout.unit * (metrics.cardHeight + metrics.gapY) - metrics.gapY;

  @override
  UniformRows withMetrics(GraphMetrics metrics) => UniformRows._(layout, metrics, bottomExtra, _order);
}

/// Per-node tops (Story 10.1 item 4), for hand-made fixtures; its height is the largest top + H + pad + bottomExtra.
class PerNodeTops extends VerticalLayout {
  /// Indexes [tops] (one per node): O(n log n).
  factory PerNodeTops(GraphLayout layout, GraphMetrics metrics, Float64List tops, {double bottomExtra = 0}) {
    assert(tops.length == layout.nodeCount);
    final sorted =
        <int>[
          for (var i = 0; i < tops.length; i++)
            if (layout.rowOf(i) >= 0) i,
        ]..sort((a, b) {
          final int byTop = tops[a].compareTo(tops[b]);
          return byTop != 0 ? byTop : a.compareTo(b);
        });
    return PerNodeTops._(layout, metrics, bottomExtra, tops, Int32List.fromList(sorted));
  }

  PerNodeTops._(GraphLayout layout, GraphMetrics metrics, double bottomExtra, this._byNode, Int32List order)
    : super._(
        layout,
        metrics,
        bottomExtra,
        Float64List.fromList(<double>[for (final int i in order) _byNode[i]]),
        order,
      );

  final Float64List _byNode;

  @override
  double top(int node) => _byNode[node];

  /// The top of the first node at each row, built once on first use.
  late final _byRow = <int, double>{
    for (int node = _byNode.length - 1; node >= 0; node--)
      if (layout.rowOf(node) >= 0) layout.rowOf(node): _byNode[node],
  };

  @override
  double topOfRow(int row) => _byRow[row]!;

  @override
  double get contentHeight =>
      (_tops.isEmpty ? metrics.pad : _tops.last + metrics.cardHeight) + metrics.pad + bottomExtra;

  @override
  PerNodeTops withMetrics(GraphMetrics metrics) => PerNodeTops._(layout, metrics, bottomExtra, _byNode, _order);
}
