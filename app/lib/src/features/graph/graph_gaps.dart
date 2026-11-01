// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:zanshin_core/zanshin_core.dart' show RouteGeometry;
import 'package:zanshin_ui/zanshin_ui.dart';

import 'graph_edges.dart';
import 'graph_layout.dart';
import 'vertical_layout.dart';

// Hidden history (Story 10.19): the `//` markers on dashed (Indirect) edges, the end stubs of Missing edges, their
// placement over router B's geometry and their painting in the edge layer. Placement follows the export's scan
// (design/graph-gaps.jsx:10-75) against whole-layout indexes; it runs once per layout, card size and clearance.

/// What a gap is.
enum GraphGapKind {
  /// One Indirect edge: commits hidden between two shown changes.
  indirect,

  /// A node with one real parent and ≥ 2 Indirect edges: its hidden parent is a merge; one shared marker.
  hiddenMerge,

  /// A Missing edge: a parent with no shown ancestor; an end stub.
  missing,
}

/// Where an end stub's "~ elided" goes.
enum GraphGapLabel {
  /// Right of the glyph.
  right,

  /// Left of the glyph.
  left,
}

/// The end stub's label box width: "~ elided" in 11 px JetBrains Mono (8 glyphs at its .6 em advance).
// shortcut: a fixed width for the English label, measure it once a translation lands.
const double _labelWidth = 53;

/// The end stub's `//` centre below the card: 12 px of visible lead, then the cut (Claude's proposal, 2026-10-14).
const double _stubGlyph = 16;

/// The extra plane height below the oldest row when it holds a stubbed node.
const double graphGapsBottomExtra = 44;

/// One gap, placed (plane coordinates).
@immutable
class GraphGap {
  /// A placed gap.
  const GraphGap({
    required this.kind,
    required this.node,
    required this.edges,
    required this.x,
    required this.y,
    this.vertical = true,
    this.fallback = false,
    this.top = 0,
    this.label,
  });

  /// Its kind.
  final GraphGapKind kind;

  /// The child node: the dashed edges' child, or the stubbed node.
  final int node;

  /// Its Indirect edges (one, or a hidden merge's group); empty for a stub.
  final List<int> edges;

  /// The `//`'s centre.
  final double x;

  /// The `//`'s centre.
  final double y;

  /// Whether the mark crosses a vertical run (its cuts slant across it).
  final bool vertical;

  /// A marker placed by the fallback (the middle of the longest free run), not by the clearance scan.
  final bool fallback;

  /// A stub's lead top: its card's bottom.
  final double top;

  /// A stub's label side; null when omitted (or a marker).
  final GraphGapLabel? label;

  /// Whether this is an end stub.
  bool get isStub => kind == GraphGapKind.missing;

  /// The mark's centre.
  Offset get point => Offset(x, y);

  /// A stub's label box.
  Rect? get labelBox => switch (label) {
    GraphGapLabel.right => Rect.fromLTWH(x + 11, top + _stubGlyph - 6, _labelWidth, 12),
    GraphGapLabel.left => Rect.fromLTWH(x - 11 - _labelWidth, top + _stubGlyph - 6, _labelWidth, 12),
    null => null,
  };

  /// The hover target: a 26×26 box around a marker; a stub's lead, glyph and label.
  Rect get box {
    if (!isStub) {
      return Rect.fromCenter(center: point, width: 26, height: 26);
    }
    final glyph = Rect.fromLTRB(x - 7, top, x + 7, top + _stubGlyph + 7);
    final Rect? label = labelBox;
    return label == null ? glyph : glyph.expandToInclude(label);
  }
}

/// Whether [node]'s Indirect edges form a hidden merge: one real parent and at least two Indirect edges. A node with
/// several real parents never groups (jj reports no `via`).
bool graphHiddenMerge(GraphLayout layout, int node) {
  if (layout.parentCountOf(node) != 1) {
    return false;
  }
  final (:int start, :int end) = layout.parentEdges(node);
  var indirect = 0;
  for (var e = start; e < end; e++) {
    if (layout.kindOf(e) == GraphEdgeKind.indirect) {
      indirect++;
    }
  }
  return indirect >= 2;
}

/// The gaps of [layout] by kind, without geometry: `dashed` counts one per Indirect edge (a hidden merge once),
/// `ends` one per Missing edge of a shown node.
({int dashed, int ends}) graphGapCounts(GraphLayout layout) {
  var dashed = 0;
  var ends = 0;
  for (var node = 0; node < layout.nodeCount; node++) {
    if (layout.rowOf(node) < 0) {
      continue;
    }
    ends += layout.missingCountOf(node);
    if (graphHiddenMerge(layout, node)) {
      dashed++;
      continue;
    }
    final (:int start, :int end) = layout.parentEdges(node);
    for (var e = start; e < end; e++) {
      if (layout.kindOf(e) == GraphEdgeKind.indirect) {
        dashed++;
      }
    }
  }
  return (dashed: dashed, ends: ends);
}

/// The plane's extra height below the oldest card: [graphGapsBottomExtra] when the lowest row holds a stubbed node.
double graphGapsBottomExtraOf(GraphLayout layout) {
  int? lowest;
  for (var node = 0; node < layout.nodeCount; node++) {
    final int row = layout.rowOf(node);
    if (row >= 0 && (lowest == null || row < lowest)) {
      lowest = row;
    }
  }
  for (var node = 0; node < layout.nodeCount; node++) {
    if (layout.rowOf(node) == lowest && layout.missingCountOf(node) > 0) {
      return graphGapsBottomExtra;
    }
  }
  return 0;
}

/// One layout's placed gaps for one geometry and card size (Story 10.19).
///
/// **Placement** (once, deterministic, independent of any window): stubs first, then markers in edge-index order,
/// each clear of the marks placed before it.
/// - **Marker** (the export's scan, design/graph-gaps.jsx:20-56): vertical runs first, each edge's runs from the
///   child's end. A run's blocked parts: every card the line meets ± (clearance − 4), every crossing or T junction of
///   another edge ± (clearance − 1), every collinear run of another edge within 3 px ± 5, every earlier mark within
///   the clearance across ± 3. It needs 2·clearance + 2 px of free run on a vertical, + 6 on a horizontal, margins
///   clearance − 4 at a segment end on a card and clearance at a bend, and takes `lo + min((hi − lo)/2, need/2 + 6)`.
///   At clearance 12 these are the export's 8, 11, 5, 26, 30, 8 and 12. Without room: the middle of the longest
///   free run ([GraphGap.fallback]).
/// - **Hidden merge:** one marker on the shared stem, 16–22 px under the card when the stem is ≥ 32 px, else
///   mid-stem (clearance + 4 and 2·(clearance + 4) in general).
/// - **Stub:** per Missing edge, the first slot (with a parent edge +.28, −.28, +.14, −.14, +.4, −.4·W; without one
///   0, ±.28, ±.14·W) ≥ 14 px from every entry port of the node and from its stubs before; else the slot farthest
///   from them. Its label goes right of the glyph where that box is free, else left, else nowhere.
///
/// Cost: O(D · k log E) for D dashed edges and k runs, cards and marks near each run (binary searches over router
/// B's sorted run indexes and the y-sorted card index), never a scan of every edge per dashed edge.
class GraphGaps {
  /// Places [layout]'s gaps over [geometry] (router B's output for it) with [rows]' card rects.
  factory GraphGaps.compute({
    required GraphLayout layout,
    required RouteGeometry geometry,
    required VerticalLayout rows,
    double clearance = 12,
  }) => _Placer(layout, geometry, rows, clearance).place();

  GraphGaps._(this.layout, this.geometry, this.clearance, this.gaps, this.cuts, this._gapOfEdge) {
    final order = List<int>.generate(gaps.length, (i) => i)..sort((a, b) => gaps[a].box.top.compareTo(gaps[b].box.top));
    _order = Int32List.fromList(order);
    _tops = Float64List.fromList(<double>[for (final int i in order) gaps[i].box.top]);
  }

  /// The layout placed.
  final GraphLayout layout;

  /// The geometry placed on.
  final RouteGeometry geometry;

  /// The clearance placed with.
  final double clearance;

  /// Every gap: the stubs, then the markers in edge-index order.
  final List<GraphGap> gaps;

  /// Per dashed edge, its marker's cut ([GraphEdgePainter.gapCuts]).
  final Map<int, List<GraphEdgeCut>> cuts;

  final Int32List _gapOfEdge;
  late final Int32List _order;
  late final Float64List _tops;

  /// The tallest gap box: a marker's 26 px (a stub's is _stubGlyph + 7 = 23 px, its label inside that height).
  static const double _tallest = 26;

  /// The gap of dashed [edge], or null.
  int? gapOfEdge(int edge) => _gapOfEdge[edge] < 0 ? null : _gapOfEdge[edge];

  /// The gaps whose box meets [window], ascending.
  List<int> gapsIn(Rect window) {
    var lo = 0;
    int hi = _tops.length;
    final double from = window.top - _tallest;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (_tops[mid] < from) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final out = <int>[];
    for (var q = lo; q < _tops.length && _tops[q] <= window.bottom; q++) {
      if (gaps[_order[q]].box.overlaps(window)) {
        out.add(_order[q]);
      }
    }
    return out..sort();
  }

  /// The gap whose target holds [point]: a marker's or a stub's box, else a 12 px band along a dashed edge (through
  /// [edges]' hit lookup, 6 px either side); null when none.
  int? gapAt(Offset point, GraphEdgePainter edges) {
    for (final int g in gapsIn(Rect.fromCenter(center: point, width: 1, height: 1))) {
      if (gaps[g].box.contains(point)) {
        return g;
      }
    }
    for (final int e in edges.edgesAt(point, tolerance: 6)) {
      if (gapOfEdge(e) case final int g) {
        return g;
      }
    }
    return null;
  }

  /// Paints the gaps meeting [visible] at [origin] (where the plane's (0, 0) paints) in [edges]' tones under
  /// [highlight]; [hovered] paints in the hover tone; [label] is the stubs' "~ elided".
  void paint(
    Canvas canvas,
    Offset origin,
    Rect visible, {
    required GraphEdgePainter edges,
    required String label,
    GraphEdgeHighlight highlight = const GraphEdgeHighlight(),
    int? hovered,
  }) {
    final List<int> shown = gapsIn(visible.inflate(8));
    if (shown.isEmpty) {
      return;
    }
    final GraphTheme theme = edges.theme;
    final double fade = 1 - GraphEdgePainter.dimDrop * highlight.dim.clamp(0, 1);
    Color faded(Color color, bool dimmed) => dimmed ? color.withValues(alpha: color.a * fade) : color;
    for (final g in shown) {
      final GraphGap gap = gaps[g];
      final bool lineage;
      final bool hover;
      final bool dimmed;
      if (gap.isStub) {
        final Uint8List? focus = highlight.focus;
        lineage = highlight.lineage && edges.inLineage(gap.node);
        hover = g == hovered || (focus != null ? focus[gap.node] != 0 : highlight.hoveredNode == gap.node);
        dimmed = g != hovered && focus != null && focus[gap.node] == 0;
      } else {
        final styles = <GraphEdgeStyle>[for (final e in gap.edges) edges.classify(e, highlight)];
        lineage = styles.any((s) => s.tone == GraphEdgeTone.lineage);
        hover = g == hovered || styles.any((s) => s.tone == GraphEdgeTone.hovered);
        dimmed = g != hovered && styles.every((s) => s.dimmed);
      }
      final Color cut = faded(
        lineage
            ? theme.lineage
            : hover
            ? theme.gapCutHover
            : theme.gapCut,
        dimmed,
      );
      final double x = origin.dx + gap.x;
      final double y = origin.dy + gap.y;
      if (gap.isStub) {
        final double top = origin.dy + gap.top;
        final lead = Path();
        for (var at = 0.0; at < _stubGlyph - 4; at += GraphEdgePainter.dashPeriod) {
          lead
            ..moveTo(x, top + at)
            ..lineTo(x, top + math.min(at + GraphEdgePainter.dashOn, _stubGlyph - 4));
        }
        Paint stroke(Color color, double width) => Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = width
          ..color = faded(color, dimmed);
        if (lineage) {
          canvas
            ..drawPath(
              lead,
              stroke(theme.lineageGlow, GraphEdgePainter.lineageWidth)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, GraphEdgePainter.glowSigma),
            )
            ..drawPath(lead, stroke(theme.lineage, GraphEdgePainter.lineageWidth));
        } else {
          canvas.drawPath(lead, stroke(hover ? theme.edgeHover : theme.edge, GraphEdgePainter.lineWidth));
        }
        if (gap.labelBox case final Rect box) {
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: ZsType.code.copyWith(
                fontSize: ZsType.fsSm,
                height: 1,
                color: faded(hover ? theme.gapTextHover : theme.gapText, dimmed),
              ),
            ),
            textDirection: TextDirection.ltr,
            maxLines: 1,
          )..layout();
          final double left = gap.label == GraphGapLabel.right ? box.left : box.right - painter.width;
          painter
            ..paint(canvas, Offset(origin.dx + left, y - painter.height / 2))
            ..dispose();
        }
      }
      graphPaintGapCuts(canvas, Offset(x, y), cut, vertical: gap.vertical);
    }
  }
}

/// The `//` (DS components/graph/graph.css:73; design/graph-gaps.jsx:94-96): two slanted 1.5 px cuts with round caps
/// at ±3 px from [centre], 10 px across the run.
void graphPaintGapCuts(Canvas canvas, Offset centre, Color color, {bool vertical = true}) {
  final paint = Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = 1.5
    ..strokeCap = StrokeCap.round
    ..color = color;
  final double x = centre.dx;
  final double y = centre.dy;
  for (final d in const <double>[-3, 3]) {
    if (vertical) {
      canvas.drawLine(Offset(x - 5, y + d + 2.2), Offset(x + 5, y + d - 2.2), paint);
    } else {
      canvas.drawLine(Offset(x + d - 2.2, y + 5), Offset(x + d + 2.2, y - 5), paint);
    }
  }
}

/// The placement's working state.
final class _Placer {
  _Placer(this.layout, this.geometry, this.rows, this.clearance);

  final GraphLayout layout;
  final RouteGeometry geometry;
  final VerticalLayout rows;
  final double clearance;

  final _gaps = <GraphGap>[];
  final _cuts = <int, List<GraphEdgeCut>>{};

  // Router B's vertical runs per x, by top: a run lookup costs its strip's hits, not its whole plane height.
  late final _verticals = GraphVerticalRuns(geometry);

  // The marks placed so far, hashed into 64 px cells.
  static const double _cell = 64;
  final _marks = <int, List<Offset>>{};

  static int _cellKey(int cx, int cy) => cx * 1000003 + cy;

  void _mark(Offset point) =>
      (_marks[_cellKey((point.dx / _cell).floor(), (point.dy / _cell).floor())] ??= <Offset>[]).add(point);

  Iterable<Offset> _marksIn(Rect rect) sync* {
    for (int cx = (rect.left / _cell).floor(); cx <= (rect.right / _cell).floor(); cx++) {
      for (int cy = (rect.top / _cell).floor(); cy <= (rect.bottom / _cell).floor(); cy++) {
        for (final Offset p in _marks[_cellKey(cx, cy)] ?? const <Offset>[]) {
          if (rect.contains(p)) {
            yield p;
          }
        }
      }
    }
  }

  Rect _card(int node) => Rect.fromLTWH(
    rows.metrics.x(layout.colOf(node)),
    rows.top(node),
    rows.metrics.cardWidth,
    rows.metrics.cardHeight,
  );

  GraphGaps place() {
    final int e = layout.edgeCount;
    final gapOfEdge = Int32List(e)..fillRange(0, e, -1);
    for (var node = 0; node < layout.nodeCount; node++) {
      if (layout.rowOf(node) >= 0 && layout.missingCountOf(node) > 0) {
        _stubs(node);
      }
    }
    final grouped = <int>{};
    for (var k = 0; k < e; k++) {
      if (layout.kindOf(k) != GraphEdgeKind.indirect) {
        continue;
      }
      final int child = layout.childOf(k);
      if (graphHiddenMerge(layout, child)) {
        if (grouped.add(child)) {
          _group(child);
          for (final int edge in _gaps.last.edges) {
            gapOfEdge[edge] = _gaps.length - 1;
          }
        }
        continue;
      }
      _gaps.add(_spot(k));
      gapOfEdge[k] = _gaps.length - 1;
      final GraphGap gap = _gaps.last;
      (_cuts[k] ??= <GraphEdgeCut>[]).add((x: gap.x, y: gap.y, vertical: gap.vertical));
      _mark(gap.point);
    }
    return GraphGaps._(layout, geometry, clearance, List<GraphGap>.unmodifiable(_gaps), _cuts, gapOfEdge);
  }

  /// [edge]'s polyline without consecutive equal points, from the parent end.
  Float64List _points(int edge) {
    final Float64List p = geometry.points;
    final int start = geometry.pointStarts[edge];
    final int end = geometry.pointStarts[edge + 1];
    final out = <double>[];
    for (var q = start; q < end; q++) {
      final int m = out.length;
      if (m == 0 || p[2 * q] != out[m - 2] || p[2 * q + 1] != out[m - 1]) {
        out
          ..add(p[2 * q])
          ..add(p[2 * q + 1]);
      }
    }
    return Float64List.fromList(out);
  }

  void _stubs(int node) {
    final Rect card = _card(node);
    final double w = card.width;
    final double cx = card.center.dx;
    final double bottom = card.bottom;
    final ports = <double>[
      for (int q = geometry.portStarts[node]; q < geometry.portStarts[node + 1]; q++) geometry.portXs[q],
    ];
    final (:int start, :int end) = layout.parentEdges(node);
    final fractions = start < end
        ? const <double>[.28, -.28, .14, -.14, .4, -.4]
        : const <double>[0, .28, -.28, .14, -.14];
    final xs = <double>[];
    for (var j = 0; j < layout.missingCountOf(node); j++) {
      double? chosen;
      double? best;
      double bestDistance = double.negativeInfinity;
      for (final f in fractions) {
        final double x = cx + f * w;
        double distance = double.infinity;
        for (final p in <double>[...ports, ...xs]) {
          distance = math.min(distance, (x - p).abs());
        }
        if (distance >= 14) {
          chosen = x;
          break;
        }
        if (distance > bestDistance) {
          bestDistance = distance;
          best = x;
        }
      }
      xs.add(chosen ?? best!);
    }
    for (final x in xs) {
      bool free(Rect box) {
        for (final p in <double>[...ports, ...xs]) {
          if (p != x && p >= box.left - 6 && p <= box.right + 6) {
            return false;
          }
        }
        return rows.visibleNodes(box, 0).isEmpty;
      }

      GraphGap stub(GraphGapLabel? label) => GraphGap(
        kind: GraphGapKind.missing,
        node: node,
        edges: const <int>[],
        x: x,
        y: bottom + _stubGlyph,
        top: bottom,
        label: label,
      );
      final GraphGap right = stub(GraphGapLabel.right);
      final GraphGap left = stub(GraphGapLabel.left);
      final GraphGap gap = free(right.labelBox!)
          ? right
          : free(left.labelBox!)
          ? left
          : stub(null);
      _gaps.add(gap);
      _mark(gap.point);
      _mark(Offset(x, bottom + 4));
      if (gap.labelBox case final Rect box) {
        _mark(box.center);
      }
    }
  }

  void _group(int child) {
    final (:int start, :int end) = layout.parentEdges(child);
    final edges = <int>[
      for (var k = start; k < end; k++)
        if (layout.kindOf(k) == GraphEdgeKind.indirect) k,
    ];
    double? stem;
    late double x;
    late double y;
    for (final k in edges) {
      final Float64List p = _points(k);
      final int m = p.length ~/ 2;
      if (m < 2) {
        continue;
      }
      x = p[2 * m - 2];
      y = p[2 * m - 1];
      final double length = (p[2 * m - 1] - p[2 * m - 3]).abs() + (p[2 * m - 2] - p[2 * m - 4]).abs();
      stem = stem == null ? length : math.min(stem, length);
    }
    final double near = clearance + 4;
    final double s = stem ?? 0;
    final double off = s >= 2 * near ? near + math.min(6, (s - 2 * near) / 2) : s / 2;
    final gap = GraphGap(kind: GraphGapKind.hiddenMerge, node: child, edges: edges, x: x, y: y + off);
    _gaps.add(gap);
    for (final k in edges) {
      (_cuts[k] ??= <GraphEdgeCut>[]).add((x: gap.x, y: gap.y, vertical: true));
    }
    _mark(gap.point);
  }

  /// The marker of Indirect [edge].
  GraphGap _spot(int edge) {
    final Float64List p = _points(edge);
    final int m = p.length ~/ 2;
    final int child = layout.childOf(edge);
    final double c = clearance;
    if (m < 2) {
      return GraphGap(kind: GraphGapKind.indirect, node: child, edges: <int>[edge], x: 0, y: 0, fallback: true);
    }
    final segments = <_Segment>[for (var i = 0; i + 1 < m; i++) _segment(edge, p, i)];
    GraphGap at(_Segment s, double u, {bool fallback = false}) => GraphGap(
      kind: GraphGapKind.indirect,
      node: child,
      edges: <int>[edge],
      x: s.x2 + s.ux * u,
      y: s.y2 + s.uy * u,
      vertical: !s.horizontal,
      fallback: fallback,
    );
    for (final wantHorizontal in const <bool>[false, true]) {
      for (int i = segments.length - 1; i >= 0; i--) {
        final _Segment s = segments[i];
        if (s.horizontal != wantHorizontal) {
          continue;
        }
        final double need = s.horizontal ? 2 * c + 6 : 2 * c + 2;
        final double m0 = i == segments.length - 1 ? c - 4 : c;
        final double m1 = i == 0 ? c - 4 : c;
        for (final (double f0, double f1) in s.free) {
          final double lo = math.max(f0, m0);
          final double hi = math.min(f1, s.length - m1);
          if (hi - lo >= need) {
            return at(s, lo + math.min((hi - lo) / 2, need / 2 + 6));
          }
        }
      }
    }
    _Segment? best;
    var bestU = 0.0;
    var longest = -1.0;
    for (final s in segments) {
      for (final (double f0, double f1) in s.free) {
        if (f1 - f0 > longest) {
          longest = f1 - f0;
          best = s;
          bestU = (f0 + f1) / 2;
        }
      }
    }
    if (best != null) {
      return at(best, bestU, fallback: true);
    }
    return GraphGap(
      kind: GraphGapKind.indirect,
      node: child,
      edges: <int>[edge],
      x: p[2 * m - 2],
      y: p[2 * m - 1] + c + 4,
      fallback: true,
    );
  }

  /// Segment [i] of [edge]'s polyline [p] with its free parts in u (from its child-side end).
  _Segment _segment(int edge, Float64List p, int i) {
    final double x1 = p[2 * i];
    final double y1 = p[2 * i + 1];
    final double x2 = p[2 * i + 2];
    final double y2 = p[2 * i + 3];
    final horizontal = y1 == y2;
    final double length = (x2 - x1).abs() + (y2 - y1).abs();
    final double ux = (x1 - x2) / length;
    final double uy = (y1 - y2) / length;
    double u(double x, double y) => (x - x2) * ux + (y - y2) * uy;
    final double c = clearance;
    final bad = <(double, double)>[];
    final RouteGeometry g = geometry;
    if (!horizontal) {
      final x = x1;
      final double ya = math.min(y1, y2);
      final double yb = math.max(y1, y2);
      // Crossings and T junctions of other edges' horizontal runs.
      for (int h = _lowerBound(g.horizontalYs, ya - 1); h < g.horizontalYs.length && g.horizontalYs[h] <= yb + 1; h++) {
        if (g.horizontalEdges[h] != edge && x >= g.horizontalLefts[h] - 1 && x <= g.horizontalRights[h] + 1) {
          final double at = u(x, g.horizontalYs[h]);
          bad.add((at - (c - 1), at + (c - 1)));
        }
      }
      for (final int q in _verticals.overlapping(x - 3, x + 3, ya, yb)) {
        if (g.verticalEdges[q] != edge) {
          final double a = u(x, g.verticalTops[q]);
          final double b = u(x, g.verticalBottoms[q]);
          bad.add((math.min(a, b) - 5, math.max(a, b) + 5));
        }
      }
      for (final int node in rows.visibleNodes(Rect.fromLTRB(x - 6, ya - 1, x + 6, yb + 1), 0)) {
        final Rect r = _card(node);
        final double a = u(x, r.top);
        final double b = u(x, r.bottom);
        bad.add((math.min(a, b) - (c - 4), math.max(a, b) + (c - 4)));
      }
      for (final Offset q in _marksIn(Rect.fromLTRB(x - c, ya - c, x + c, yb + c))) {
        final double at = u(x, q.dy);
        bad.add((at - 3, at + 3));
      }
    } else {
      final y = y1;
      final double xa = math.min(x1, x2);
      final double xb = math.max(x1, x2);
      for (final int q in _verticals.overlapping(xa - 1, xb + 1, y - 1, y + 1)) {
        if (g.verticalEdges[q] != edge) {
          final double at = u(g.verticalXs[q], y);
          bad.add((at - (c - 1), at + (c - 1)));
        }
      }
      for (int h = _lowerBound(g.horizontalYs, y - 3); h < g.horizontalYs.length && g.horizontalYs[h] <= y + 3; h++) {
        if (g.horizontalEdges[h] != edge && g.horizontalLefts[h] <= xb && g.horizontalRights[h] >= xa) {
          final double a = u(g.horizontalLefts[h], y);
          final double b = u(g.horizontalRights[h], y);
          bad.add((math.min(a, b) - 5, math.max(a, b) + 5));
        }
      }
      for (final int node in rows.visibleNodes(Rect.fromLTRB(xa - 1, y - 6, xb + 1, y + 6), 0)) {
        final Rect r = _card(node);
        final double a = u(r.left, y);
        final double b = u(r.right, y);
        bad.add((math.min(a, b) - (c - 4), math.max(a, b) + (c - 4)));
      }
      for (final Offset q in _marksIn(Rect.fromLTRB(xa - c, y - c, xb + c, y + c))) {
        final double at = u(q.dx, y);
        bad.add((at - 3, at + 3));
      }
    }
    bad.sort((a, b) => a.$1.compareTo(b.$1));
    final free = <(double, double)>[];
    var a = 0.0;
    for (final (double b0, double b1) in bad) {
      if (b0 > a) {
        free.add((a, math.min(b0, length)));
      }
      a = math.max(a, b1);
      if (a >= length) {
        break;
      }
    }
    if (a < length) {
      free.add((a, length));
    }
    return _Segment(x2, y2, ux, uy, length, horizontal: horizontal, free: free);
  }

  static int _lowerBound(Float64List list, double x) {
    var lo = 0;
    int hi = list.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (list[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// Router B's vertical runs ([RouteGeometry.verticalXs], sorted by x) grouped by x, each group ordered by top with
/// the running maximum of its bottoms, so the runs of an x range that overlap a y range are found without scanning
/// the group's other runs. The marker placement's lookup; public for its test only.
// shortcut: one long run early in a group keeps the running maximum high and the walk scans down to it; runs of one
// x rarely overlap (they would share a line), so an interval tree waits for a measured case.
@visibleForTesting
final class GraphVerticalRuns {
  /// The index of [geometry]'s vertical runs.
  GraphVerticalRuns(this.geometry) {
    final Float64List xs = geometry.verticalXs;
    final Float64List tops = geometry.verticalTops;
    final Float64List bottoms = geometry.verticalBottoms;
    final int n = xs.length;
    _byTop = Int32List(n);
    _tops = Float64List(n);
    _maxBottoms = Float64List(n);
    _groupEnds = Int32List(n);
    for (var start = 0; start < n;) {
      int end = start + 1;
      while (end < n && xs[end] == xs[start]) {
        end++;
      }
      final group = List<int>.generate(end - start, (i) => start + i)..sort((a, b) => tops[a].compareTo(tops[b]));
      double maxBottom = double.negativeInfinity;
      for (var i = 0; i < group.length; i++) {
        final int q = group[i];
        _byTop[start + i] = q;
        _tops[start + i] = tops[q];
        maxBottom = math.max(maxBottom, bottoms[q]);
        _maxBottoms[start + i] = maxBottom;
        _groupEnds[start + i] = end;
      }
      start = end;
    }
  }

  /// The routed geometry.
  final RouteGeometry geometry;
  late final Int32List _byTop;
  late final Float64List _tops;
  late final Float64List _maxBottoms;
  late final Int32List _groupEnds;

  /// The runs with x in [x0, x1] and top ≤ [y1] and bottom ≥ [y0].
  Iterable<int> overlapping(double x0, double x1, double y0, double y1) sync* {
    final Float64List xs = geometry.verticalXs;
    final Float64List bottoms = geometry.verticalBottoms;
    for (int start = _Placer._lowerBound(xs, x0); start < xs.length && xs[start] <= x1; start = _groupEnds[start]) {
      // The group's runs with top ≤ y1 end before lo; walking down, the running maximum says when no bottom reaches
      // y0. The order of the hits is no contract (callers sort).
      var lo = start;
      int hi = _groupEnds[start];
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (_tops[mid] <= y1) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      for (int k = lo - 1; k >= start && _maxBottoms[k] >= y0; k--) {
        if (bottoms[_byTop[k]] >= y0) {
          yield _byTop[k];
        }
      }
    }
  }
}

/// One segment of a dashed edge, measured from its child-side end ([x2], [y2]) toward its parent side.
final class _Segment {
  _Segment(this.x2, this.y2, this.ux, this.uy, this.length, {required this.horizontal, required this.free});

  final double x2;
  final double y2;
  final double ux;
  final double uy;
  final double length;
  final bool horizontal;
  final List<(double, double)> free;
}
