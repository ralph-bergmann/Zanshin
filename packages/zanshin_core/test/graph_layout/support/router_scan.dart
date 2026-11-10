// SPDX-License-Identifier: MIT

// Checks over a router geometry for the tests and the router CLI: the polyline segments that pass
// through a card that is neither of their ends, and the line gate (the `line gate` group of router_test.dart).

import 'package:zanshin_core/src/graph_layout/router.dart';

/// One polyline segment inside a card that is neither of its edge's ends.
typedef CardHit = ({int edge, int segment, int node, bool vertical});

/// The card hits of [g]: every segment (consecutive points q − 1, q of an edge's polyline) that
/// overlaps a visible card's interior inset by 1 px, the card being neither the edge's parent nor
/// its child. In edge order, then segment, then column, then row.
List<CardHit> cardHits(RouteGeometry g) {
  final RouteClasses c = g.classes;
  final RouteMetrics m = g.metrics;
  final double w = m.width;
  final double h = m.height;
  final double colW = w + m.gapX;
  final double pitch = h + m.gapY;
  double yOf(int node) => m.pad + (c.maxRow - c.nodeRows[node]) / c.unit * pitch;
  final hits = <CardHit>[];
  for (var k = 0; k < c.edgeCount; k++) {
    final int from = c.edgeFroms[k];
    final int to = c.edgeTos[k];
    for (int q = g.pointStarts[k] + 1; q < g.pointStarts[k + 1]; q++) {
      final double x1 = g.points[2 * q - 2];
      final double y1 = g.points[2 * q - 1];
      final double x2 = g.points[2 * q];
      final double y2 = g.points[2 * q + 1];
      final xa = x1 < x2 ? x1 : x2;
      final xb = x1 < x2 ? x2 : x1;
      final ya = y1 < y2 ? y1 : y2;
      final yb = y1 < y2 ? y2 : y1;
      int colLo = ((xa - w - m.pad) / colW).floor();
      int colHi = ((xb - m.pad) / colW).ceil();
      if (colLo < 0) {
        colLo = 0;
      }
      if (colHi > c.columns - 1) {
        colHi = c.columns - 1;
      }
      for (var col = colLo; col <= colHi; col++) {
        final double ox = m.pad + col * colW;
        if (!(xa < ox + w - 1 && xb > ox + 1)) {
          continue;
        }
        for (int s = c.columnStarts[col]; s < c.columnStarts[col + 1]; s++) {
          final int node = c.columnNodes[s];
          if (node == from || node == to) {
            continue;
          }
          final double oy = yOf(node);
          if (ya < oy + h - 1 && yb > oy + 1) {
            hits.add((edge: k, segment: q - g.pointStarts[k], node: node, vertical: x1 == x2));
          }
        }
      }
    }
  }
  return hits;
}

/// Tolerance for comparing computed coordinates.
const _eps = 1e-9;

/// The gate's checks that hold on every input: right angles, the ends on their card edges, and a y
/// that never rises along a line. One message per failure.
List<String> polylineFailures(RouteGeometry g) {
  final RouteClasses c = g.classes;
  final RouteMetrics m = g.metrics;
  final double colW = m.width + m.gapX;
  final double pitch = m.height + m.gapY;
  double left(int node) => m.pad + c.nodeCols[node] * colW;
  double top(int node) => m.pad + (c.maxRow - c.nodeRows[node]) / c.unit * pitch;
  final fails = <String>[];
  for (var k = 0; k < c.edgeCount; k++) {
    final int start = g.pointStarts[k];
    final int end = g.pointStarts[k + 1];
    final int count = end - start;
    if (count != 2 && count != 4 && count != 6 && count != 8) {
      fails.add('line $k has $count points');
    }
    for (int q = start + 1; q < end; q++) {
      final double dx = g.points[2 * q] - g.points[2 * q - 2];
      final double dy = g.points[2 * q + 1] - g.points[2 * q - 1];
      if (dx.abs() > _eps && dy.abs() > _eps) {
        fails.add('line $k has a slanted run at point ${q - start}');
      }
      if (dy > _eps) {
        fails.add('line $k climbs back down at point ${q - start}');
      }
    }
    final int p = c.edgeFroms[k];
    final int ch = c.edgeTos[k];
    bool onEdge(int node, double x) => left(node) + 18 - _eps <= x && x <= left(node) + m.width - 18 + _eps;
    if (!onEdge(p, g.points[2 * start]) || (g.points[2 * start + 1] - top(p)).abs() > _eps) {
      fails.add('line $k does not start on its parent\'s top edge');
    }
    if (!onEdge(ch, g.points[2 * end - 2]) || (g.points[2 * end - 1] - top(ch) - m.height).abs() > _eps) {
      fails.add('line $k does not end on its child\'s bottom edge');
    }
  }
  return fails;
}

/// Every pair of runs of two lines that share a stretch of more than 1 px on one x or one y, not
/// counting two lines of one slot or two lines on one port of one card edge. The all-pairs oracle of
/// `RouteGeometry.sharedStretches`.
int sharedStretchOracle(RouteGeometry g) {
  final RouteClasses c = g.classes;
  double exitOf(int k) => g.points[2 * g.pointStarts[k]];
  double entryOf(int k) => g.points[2 * g.pointStarts[k + 1] - 2];
  bool exempt(int a, int b) =>
      c.slots[a] == c.slots[b] ||
      (c.edgeFroms[a] == c.edgeFroms[b] && exitOf(a) == exitOf(b)) ||
      (c.edgeTos[a] == c.edgeTos[b] && entryOf(a) == entryOf(b));
  var count = 0;
  void scan(List<double> at, List<double> from, List<double> to, List<int> edges) {
    for (var i = 0; i < at.length; i++) {
      for (int j = i + 1; j < at.length; j++) {
        if (at[i] == at[j] &&
            edges[i] != edges[j] &&
            (to[i] < to[j] ? to[i] : to[j]) - (from[i] > from[j] ? from[i] : from[j]) > 1 &&
            !exempt(edges[i], edges[j])) {
          count++;
        }
      }
    }
  }

  scan(g.verticalXs, g.verticalTops, g.verticalBottoms, g.verticalEdges);
  scan(g.horizontalYs, g.horizontalLefts, g.horizontalRights, g.horizontalEdges);
  return count;
}

/// Whether a vertical run of [p] crosses a horizontal run of [q] (flat x, y pairs), not just touches it.
bool _crosses(List<double> p, List<double> q) {
  for (var i = 0; i + 3 < p.length; i += 2) {
    if (p[i] != p[i + 2]) {
      continue;
    }
    final double top = p[i + 1] < p[i + 3] ? p[i + 1] : p[i + 3];
    final double bottom = p[i + 1] < p[i + 3] ? p[i + 3] : p[i + 1];
    for (var j = 0; j + 3 < q.length; j += 2) {
      final double left = q[j] < q[j + 2] ? q[j] : q[j + 2];
      final double right = q[j] < q[j + 2] ? q[j + 2] : q[j];
      if (q[j + 1] == q[j + 3] && left < p[i] && p[i] < right && top < q[j + 1] && q[j + 1] < bottom) {
        return true;
      }
    }
  }
  return false;
}

/// The line gate on [g], one message per failure: [polylineFailures];
/// every card hit on a line the router reports; at one card edge two lines on one port only on the
/// fan's overflow or as one shared entry; two lines that both turn within gapY of one card edge never
/// cross; the ports of a card edge other than the centre go, in x order, to non-decreasing columns;
/// and the report of shared stretches equals the all-pairs oracle.
List<String> lineFailures(RouteGeometry g) {
  final RouteClasses c = g.classes;
  final RouteMetrics m = g.metrics;
  final double colW = m.width + m.gapX;
  double centre(int node) => m.pad + c.nodeCols[node] * colW + m.width / 2;
  List<double> pts(int k) => g.points.sublist(2 * g.pointStarts[k], 2 * g.pointStarts[k + 1]);

  final List<String> fails = polylineFailures(g);
  for (final CardHit hit in cardHits(g)) {
    if (g.behindEdges[hit.edge] == 0) {
      fails.add('line ${hit.edge} runs behind card ${hit.node} and is not reported');
    }
  }

  // Per card edge (node, exit or entry) its lines.
  final atEdge = <(int, bool), List<int>>{};
  for (var k = 0; k < c.edgeCount; k++) {
    (atEdge[(c.edgeFroms[k], true)] ??= []).add(k);
    (atEdge[(c.edgeTos[k], false)] ??= []).add(k);
  }
  // The outermost fan slot, where the overflow of a fan lands.
  final double outermost = 24 + ((m.width / 2 - 18 - 24) / 8).floor() * 8;
  for (final MapEntry(key: (int node, bool exit), value: List<int> lines) in atEdge.entries) {
    double portOf(int k) => exit ? g.points[2 * g.pointStarts[k]] : g.points[2 * g.pointStarts[k + 1] - 2];
    for (var a = 0; a < lines.length; a++) {
      for (int b = a + 1; b < lines.length; b++) {
        if (portOf(lines[a]) != portOf(lines[b])) {
          continue;
        }
        final bool overflow = ((portOf(lines[a]) - centre(node)).abs() - outermost).abs() < _eps;
        if (!overflow && (exit || c.slots[lines[a]] != c.slots[lines[b]])) {
          fails.add('lines ${lines[a]} and ${lines[b]} share a port of card $node');
        }
      }
    }

    // Two lines that both turn within a row gap of this card edge do not cross.
    double reach(int k) {
      final List<double> p = pts(k);
      return exit ? p[1] - p[3] : p[p.length - 3] - p.last;
    }

    final List<int> turning = [
      for (final int k in lines)
        if (g.pointStarts[k + 1] - g.pointStarts[k] > 2 && reach(k) < m.gapY) k,
    ];
    for (final a in turning) {
      for (final b in turning) {
        if (a != b && _crosses(pts(a), pts(b))) {
          fails.add('lines $a and $b of card $node cross');
        }
      }
    }

    // The ports other than the centre, in x order, go to non-decreasing columns.
    final ports = <(double, int)>[
      for (final int k in lines)
        if ((portOf(k) - centre(node)).abs() > _eps) (portOf(k), c.nodeCols[exit ? c.edgeTos[k] : c.edgeFroms[k]]),
    ]..sort((a, b) => a.$1 != b.$1 ? a.$1.compareTo(b.$1) : a.$2.compareTo(b.$2));
    for (var i = 1; i < ports.length; i++) {
      if (ports[i - 1].$2 > ports[i].$2) {
        fails.add('the ports of card $node (${exit ? 'top' : 'bottom'}) are not in column order: $ports');
        break;
      }
    }
  }

  final int oracle = sharedStretchOracle(g);
  if (oracle != g.sharedStretches) {
    fails.add('sharedStretches is ${g.sharedStretches}, the all-pairs count $oracle');
  }
  return fails;
}
