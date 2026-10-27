// SPDX-License-Identifier: MIT

// Story 4.15: checks over a router geometry for the tests and the router CLI — the polyline
// segments that pass through a card that is neither of their ends (GL's `throughCards`,
// graph-layout.jsx:303-310 at e74ced3), with the reported cases they belong to.

import 'dart:typed_data';

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

/// Per edge, whether it sits on a gutter with more than 9 lines (reported as `overfullGutters`).
Uint8List overfullGutterEdges(RouteClasses c) {
  final lines = <int, int>{};
  for (var k = 0; k < c.edgeCount; k++) {
    if (c.kinds[k] == RouteClasses.kindGutter) {
      lines[c.gutters[k]] = (lines[c.gutters[k]] ?? 0) + 1;
    }
  }
  final out = Uint8List(c.edgeCount);
  for (var k = 0; k < c.edgeCount; k++) {
    if (c.kinds[k] == RouteClasses.kindGutter && lines[c.gutters[k]]! > 9) {
      out[k] = 1;
    }
  }
  return out;
}
