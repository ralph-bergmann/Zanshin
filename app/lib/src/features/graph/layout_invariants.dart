// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteClasses, RouteGeometry;

import 'graph_layout.dart';
import 'vertical_layout.dart';

/// A hard invariant every fixture passes (Story 10.1 item 14).
enum LayoutInvariant {
  /// Node keys are unique.
  uniqueKeys,

  /// Every edge references existing nodes.
  noDanglingEdge,

  /// No (child, parent) pair appears twice.
  noDuplicateEdge,

  /// Every child sits at least one pitch above each parent: rowOf(child) ≥ rowOf(parent) + U.
  childAboveParent,

  /// No two cards in one column overlap: in the row modes no two nodes closer than one pitch (at U = 1, no shared
  /// (row, col) cell); for [PerNodeTops], no vertical overlap.
  noOverlappingCards,

  /// Free's day band is card-free (Story 4.16): consecutive buckets keep one pitch, bucketLastRowOf(b − 1) + U ≤
  /// bucketFirstRowOf(b). Checked in the row model only (not for [PerNodeTops]).
  dayBandClear,
}

/// One violated invariant, with what violates it.
@immutable
class LayoutViolation {
  /// Creates a violation.
  const LayoutViolation(this.invariant, this.message);

  /// The violated invariant.
  final LayoutInvariant invariant;

  /// What violates it.
  final String message;

  @override
  String toString() => '${invariant.name}: $message';
}

/// The hard invariants [layout] violates (test/debug only; a violation is an engine or recording bug, never patched
/// in the view). With a [vertical] [PerNodeTops], the card checks use its pixel tops instead of the rows. Folded stack
/// members (Story 10.17) have no card and are skipped by the card checks.
List<LayoutViolation> checkLayoutInvariants(GraphLayout layout, {VerticalLayout? vertical}) {
  final violations = <LayoutViolation>[];
  final int n = layout.nodeCount;
  final int u = layout.unit;
  for (var i = 0; i < n; i++) {
    final String key = layout.keyOf(i);
    if (layout.indexOfKey(key) != i) {
      violations.add(LayoutViolation(LayoutInvariant.uniqueKeys, 'key $key is not unique (node $i)'));
    }
  }
  final pairs = <(int, int)>{};
  final PerNodeTops? tops = vertical is PerNodeTops ? vertical : null;
  for (var e = 0; e < layout.edgeCount; e++) {
    final int child = layout.childOf(e);
    final int parent = layout.parentOf(e);
    if (child < 0 || child >= n || parent < 0 || parent >= n) {
      violations.add(LayoutViolation(LayoutInvariant.noDanglingEdge, 'edge $e ($child ← $parent) leaves the layout'));
      continue;
    }
    if (!pairs.add((child, parent))) {
      violations.add(LayoutViolation(LayoutInvariant.noDuplicateEdge, 'edge $e repeats ($child ← $parent)'));
    }
    final bool above = tops == null
        ? layout.rowOf(child) >= layout.rowOf(parent) + u
        : tops.top(child) + tops.metrics.cardHeight + tops.metrics.gapY <= tops.top(parent);
    if (!above) {
      violations.add(
        LayoutViolation(
          LayoutInvariant.childAboveParent,
          'edge $e: child ${layout.keyOf(child)} is not a pitch above parent ${layout.keyOf(parent)}',
        ),
      );
    }
  }
  // Per column, consecutive cards by their vertical position; a folded stack member has no card.
  final byCol = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    if (!layout.isFolded(i)) {
      (byCol[layout.colOf(i)] ??= <int>[]).add(i);
    }
  }
  for (final MapEntry<int, List<int>>(key: col, value: nodes) in byCol.entries) {
    if (tops == null) {
      nodes.sort((a, b) => layout.rowOf(a).compareTo(layout.rowOf(b)));
    } else {
      nodes.sort((a, b) => tops.top(a).compareTo(tops.top(b)));
    }
    for (var k = 1; k < nodes.length; k++) {
      final int a = nodes[k - 1];
      final int b = nodes[k];
      final bool apart = tops == null
          ? layout.rowOf(b) - layout.rowOf(a) >= u
          : tops.top(b) - tops.top(a) >= tops.metrics.cardHeight;
      if (!apart) {
        violations.add(
          LayoutViolation(
            LayoutInvariant.noOverlappingCards,
            'column $col: ${layout.keyOf(a)} and ${layout.keyOf(b)} overlap',
          ),
        );
      }
    }
  }
  if (tops == null && layout.mode == GraphMode.free) {
    for (var b = 1; b < layout.bucketCount; b++) {
      if (layout.bucketLastRowOf(b - 1) + u > layout.bucketFirstRowOf(b)) {
        violations.add(
          LayoutViolation(LayoutInvariant.dayBandClear, 'day bucket $b is less than a pitch above bucket ${b - 1}'),
        );
      }
    }
  }
  return violations;
}

/// What router B's lines do against the cards and each other (Story 10.4): the route report of this checker.
@immutable
class RouteReport {
  /// Creates a report.
  const RouteReport({
    required this.behindCard,
    required this.behindCardExplained,
    required this.collinear,
    required this.directFallbacks,
    required this.overfullGutters,
    required this.overfullClusters,
    required this.gate,
  });

  /// Segments behind a card that is not one of their edge's endpoints, on edges the router does not report.
  final int behindCard;

  /// Such segments on edges the router reports: a fallback, a run in an overfull cluster, or an outer line of a gutter
  /// with > 9 lines.
  final int behindCardExplained;

  /// Collinear overlaps (> 1 px) between segments of two lines router B does not share.
  final int collinear;

  /// The router's `directFallbacks`.
  final int directFallbacks;

  /// The router's `overfullGutters`.
  final int overfullGutters;

  /// The router's `overfullClusters`.
  final int overfullClusters;

  /// Whether a behind-card hit fails the report (Compact); otherwise hits are only counted (Free).
  final bool gate;

  /// No collinear overlap and, under [gate], no behind-card hit at all.
  bool get passes => collinear == 0 && (!gate || behindCard + behindCardExplained == 0);

  @override
  String toString() =>
      'RouteReport(behindCard: $behindCard, explained: $behindCardExplained, collinear: $collinear, '
      'directFallbacks: $directFallbacks, overfullGutters: $overfullGutters, overfullClusters: $overfullClusters, '
      'gate: $gate)';
}

/// One axis-parallel segment of an edge's polyline: the fixed coordinate `at` and the range `from`–`to` it covers.
typedef _Segment = ({int edge, double at, double from, double to});

/// The route report of raw polylines (test/debug only): per edge its points (`pointStarts`, `points` as x, y pairs,
/// from the parent), its parent, child and entry slot; per node its card's left and top (NaN for a hidden node) at
/// [cardWidth] × [cardHeight]; per edge whether the router reports it ([explained]). A segment is behind a card when
/// it overlaps the card's interior by more than 0.5 px and the card is not one of its edge's endpoints. Two lines are
/// shared (router B overlaps them) when they enter by one slot, or leave one parent at one exit point.
RouteReport checkRouteLines({
  required Int32List pointStarts,
  required Float64List points,
  required Int32List edgeFroms,
  required Int32List edgeTos,
  required Int32List slots,
  required Float64List cardLefts,
  required Float64List cardTops,
  required double cardWidth,
  required double cardHeight,
  required Uint8List explained,
  required bool gate,
  int directFallbacks = 0,
  int overfullGutters = 0,
  int overfullClusters = 0,
}) {
  const inset = .5;
  // Cards per column (by left edge), each column by top.
  final columns = <double, List<int>>{};
  for (var i = 0; i < cardLefts.length; i++) {
    if (!cardLefts[i].isNaN) {
      (columns[cardLefts[i]] ??= <int>[]).add(i);
    }
  }
  for (final List<int> nodes in columns.values) {
    nodes.sort((a, b) => cardTops[a].compareTo(cardTops[b]));
  }

  bool behind(_Segment s, {required bool horizontal}) {
    final int parent = edgeFroms[s.edge];
    final int child = edgeTos[s.edge];
    for (final MapEntry(key: double left, value: List<int> nodes) in columns.entries) {
      final double l = left + inset;
      final double r = left + cardWidth - inset;
      if (horizontal ? math.max(s.from, l) >= math.min(s.to, r) : (s.at <= l || s.at >= r)) {
        continue;
      }
      // Cards whose interior's y-range meets the segment's: top in (lowest, highest).
      final double lowest = (horizontal ? s.at : s.from) - cardHeight + inset;
      final double highest = (horizontal ? s.at : s.to) - inset;
      var lo = 0;
      int hi = nodes.length;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (cardTops[nodes[mid]] > lowest) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      for (var q = lo; q < nodes.length && cardTops[nodes[q]] < highest; q++) {
        final int node = nodes[q];
        if (node != parent && node != child) {
          return true;
        }
      }
    }
    return false;
  }

  final horizontals = <_Segment>[];
  final verticals = <_Segment>[];
  var hits = 0;
  var explainedHits = 0;
  for (var k = 0; k < edgeFroms.length; k++) {
    for (int q = pointStarts[k] + 1; q < pointStarts[k + 1]; q++) {
      final double x1 = points[2 * q - 2];
      final double y1 = points[2 * q - 1];
      final double x2 = points[2 * q];
      final double y2 = points[2 * q + 1];
      if (x1 == x2 && y1 == y2) {
        continue;
      }
      final horizontal = y1 == y2;
      final _Segment segment = horizontal
          ? (edge: k, at: y1, from: math.min(x1, x2), to: math.max(x1, x2))
          : (edge: k, at: x1, from: math.min(y1, y2), to: math.max(y1, y2));
      (horizontal ? horizontals : verticals).add(segment);
      if (behind(segment, horizontal: horizontal)) {
        if (explained[k] != 0) {
          explainedHits++;
        } else {
          hits++;
        }
      }
    }
  }

  bool shared(int a, int b) =>
      slots[a] == slots[b] ||
      edgeFroms[a] == edgeFroms[b] &&
          points[2 * pointStarts[a]] == points[2 * pointStarts[b]] &&
          points[2 * pointStarts[a] + 1] == points[2 * pointStarts[b] + 1];

  // Collinear overlaps: segments on one line (to 1e-6 px), swept by their start.
  int overlaps(List<_Segment> segments) {
    final lines = <int, List<_Segment>>{};
    for (final s in segments) {
      (lines[(s.at * 1e6).round()] ??= <_Segment>[]).add(s);
    }
    var count = 0;
    for (final List<_Segment> line in lines.values) {
      line.sort((a, b) => a.from.compareTo(b.from));
      for (var i = 0; i < line.length; i++) {
        for (int j = i + 1; j < line.length && line[j].from < line[i].to - 1; j++) {
          final double overlap = math.min(line[i].to, line[j].to) - line[j].from;
          if (overlap > 1 && line[i].edge != line[j].edge && !shared(line[i].edge, line[j].edge)) {
            count++;
          }
        }
      }
    }
    return count;
  }

  return RouteReport(
    behindCard: hits,
    behindCardExplained: explainedHits,
    collinear: overlaps(horizontals) + overlaps(verticals),
    directFallbacks: directFallbacks,
    overfullGutters: overfullGutters,
    overfullClusters: overfullClusters,
    gate: gate,
  );
}

/// The route report of [geometry] (test/debug only): the cards at the router's own positions, an edge explained when
/// the router reports it (`fallbackEdges`, `overfullEdges`, or an outer line of a gutter holding more than 9 lines:
/// one offset at least gapX / 2 from the gutter's centre). [gate] is Compact.
RouteReport checkRoutes(RouteGeometry geometry, {required bool gate}) {
  final RouteClasses classes = geometry.classes;
  final int n = classes.nodeRows.length;
  final int e = classes.edgeCount;
  final double pitch = geometry.metrics.height + geometry.metrics.gapY;
  final double colW = geometry.metrics.width + geometry.metrics.gapX;
  final double pad = geometry.metrics.pad;
  final lefts = Float64List(n);
  final tops = Float64List(n);
  for (var i = 0; i < n; i++) {
    final int row = classes.nodeRows[i];
    lefts[i] = row < 0 ? double.nan : pad + classes.nodeCols[i] * colW;
    tops[i] = row < 0 ? double.nan : pad + (classes.maxRow - row) / classes.unit * pitch;
  }
  // The router's gutter budget (router.dart `_gutterBudget`).
  const gutterBudget = 9;
  final perGutter = <int, int>{};
  for (var k = 0; k < e; k++) {
    if (classes.kinds[k] == RouteClasses.kindGutter) {
      perGutter.update(classes.gutters[k], (count) => count + 1, ifAbsent: () => 1);
    }
  }
  final explained = Uint8List(e);
  for (var k = 0; k < e; k++) {
    // Only a line of an overfull gutter whose offset (6 px per step) reaches the neighbouring cards.
    final bool overfullGutter =
        classes.kinds[k] == RouteClasses.kindGutter &&
        perGutter[classes.gutters[k]]! > gutterBudget &&
        classes.gutterSteps[k].abs() * 6 >= geometry.metrics.gapX / 2;
    explained[k] = classes.fallbackEdges[k] != 0 || geometry.overfullEdges[k] != 0 || overfullGutter ? 1 : 0;
  }
  return checkRouteLines(
    pointStarts: geometry.pointStarts,
    points: geometry.points,
    edgeFroms: classes.edgeFroms,
    edgeTos: classes.edgeTos,
    slots: classes.slots,
    cardLefts: lefts,
    cardTops: tops,
    cardWidth: geometry.metrics.width,
    cardHeight: geometry.metrics.height,
    explained: explained,
    gate: gate,
    directFallbacks: classes.directFallbacks,
    overfullGutters: classes.overfullGutters,
    overfullClusters: geometry.overfullClusters,
  );
}
