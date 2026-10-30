// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:zanshin_core/zanshin_core.dart'
    show RouteBridges, RouteClasses, RouteGeometry, RouteMetrics, routeSyncNodeLimit;
import 'package:zanshin_ui/zanshin_ui.dart';

import 'graph_layout.dart';
import 'graph_metrics.dart';

// The graph's edge layer (Story 10.4): 4.15's router B polylines (docs/graph-layout.md §14) stroked with rounded
// corners, dashed Indirect edges, bridges, the @ lineage, hover and dim. The view computes no route.
//
// Edge identity: an edge is its index within one layout; across layouts it is (child key, parent key).

/// The router metrics of [metrics]: W, H, gapX, gapY and pad.
RouteMetrics graphRouteMetrics(GraphMetrics metrics) => RouteMetrics(
  width: metrics.cardWidth,
  height: metrics.cardHeight,
  gapX: metrics.gapX,
  gapY: metrics.gapY,
  pad: metrics.pad,
);

/// The router's class-stage input, read from a [GraphLayout]'s accessors into typed arrays.
typedef _RouteInput = ({
  Int32List rows,
  Int32List cols,
  int unit,
  bool free,
  Int32List froms,
  Int32List tos,
  Uint8List kinds,
  Int32List parentCounts,
});

_RouteInput _routeInput(GraphLayout layout) {
  final int n = layout.nodeCount;
  final int e = layout.edgeCount;
  final rows = Int32List(n);
  final cols = Int32List(n);
  final parentCounts = Int32List(n);
  for (var i = 0; i < n; i++) {
    rows[i] = layout.rowOf(i);
    cols[i] = layout.colOf(i);
    parentCounts[i] = layout.parentCountOf(i);
  }
  final froms = Int32List(e);
  final tos = Int32List(e);
  final kinds = Uint8List(e);
  for (var k = 0; k < e; k++) {
    froms[k] = layout.parentOf(k);
    tos[k] = layout.childOf(k);
    // GraphGridView's codes: 0 Direct, 1 Indirect.
    kinds[k] = layout.kindOf(k) == GraphEdgeKind.indirect ? 1 : 0;
  }
  return (
    rows: rows,
    cols: cols,
    unit: layout.unit,
    free: layout.mode == GraphMode.free,
    froms: froms,
    tos: tos,
    kinds: kinds,
    parentCounts: parentCounts,
  );
}

RouteClasses _classesOf(_RouteInput input) => RouteClasses.compute(
  nodeRows: input.rows,
  nodeCols: input.cols,
  unit: input.unit,
  free: input.free,
  edgeFroms: input.froms,
  edgeTos: input.tos,
  edgeKinds: input.kinds,
  parentCounts: input.parentCounts,
);

RouteGeometry _geometryOf(_RouteInput input, RouteMetrics metrics) => RouteGeometry.compute(_classesOf(input), metrics);

/// Router B's class stage for [layout] (once per layout; a card-size change keeps it).
RouteClasses graphRouteClasses(GraphLayout layout) => _classesOf(_routeInput(layout));

/// Router B's geometry for [layout] at [metrics], reusing [classes] (from this layout) when given. Synchronous up to
/// [routeSyncNodeLimit] nodes; above it both stages run in `Isolate.run` over typed arrays (docs/graph-layout.md
/// §14.5), and the result's `classes` is a copy of [classes].
FutureOr<RouteGeometry> routeGraph(GraphLayout layout, GraphMetrics metrics, {RouteClasses? classes}) {
  final RouteMetrics route = graphRouteMetrics(metrics);
  if (layout.nodeCount <= routeSyncNodeLimit) {
    return RouteGeometry.compute(classes ?? graphRouteClasses(layout), route);
  }
  if (classes != null) {
    return Isolate.run(() => RouteGeometry.compute(classes, route));
  }
  final _RouteInput input = _routeInput(layout);
  return Isolate.run(() => _geometryOf(input, route));
}

/// One view's current route (Story 10.4): the class stage kept per layout, the geometry per metrics. [geometryFor]
/// answers at once up to [routeSyncNodeLimit] nodes; above it it starts [routeGraph] on another isolate, answers null
/// until that completes, then calls [onRouted]. A result superseded by a newer request, or arriving after [dispose],
/// is dropped.
class GraphRouteCache {
  /// A cache that calls [onRouted] when an asynchronous route becomes current.
  GraphRouteCache({required this.onRouted});

  /// Called when an asynchronous route becomes current (the owner repaints).
  final VoidCallback onRouted;

  RouteGeometry? _geometry;
  GraphLayout? _layout;
  GraphMetrics? _metrics;
  (GraphLayout, GraphMetrics)? _routing;
  final _inFlight = <Future<void>>{};
  var _disposed = false;

  /// [layout]'s geometry at [metrics], or null while it is being routed.
  RouteGeometry? geometryFor(GraphLayout layout, GraphMetrics metrics) {
    if (identical(_layout, layout) && _metrics == metrics) {
      return _geometry;
    }
    final (GraphLayout, GraphMetrics)? routing = _routing;
    if (routing != null && identical(routing.$1, layout) && routing.$2 == metrics) {
      return null;
    }
    _routing = (layout, metrics);
    final RouteClasses? classes = identical(_layout, layout) ? _geometry?.classes : null;
    final FutureOr<RouteGeometry> result = routeGraph(layout, metrics, classes: classes);
    if (result is RouteGeometry) {
      _accept(layout, metrics, result);
      return result;
    }
    bool current() {
      final (GraphLayout, GraphMetrics)? routing = _routing;
      return routing != null && identical(routing.$1, layout) && routing.$2 == metrics;
    }

    late final Future<void> done;
    done = result
        .then(
          (geometry) {
            if (_disposed || !current()) {
              return;
            }
            _accept(layout, metrics, geometry);
            onRouted();
          },
          onError: (Object error, StackTrace stack) {
            // A failed route is no longer in flight; a later request may retry it.
            if (current()) {
              _routing = null;
            }
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: 'graph edges',
                context: ErrorDescription('while routing the graph'),
              ),
            );
          },
        )
        .whenComplete(() => _inFlight.remove(done));
    _inFlight.add(done);
    return null;
  }

  void _accept(GraphLayout layout, GraphMetrics metrics, RouteGeometry geometry) {
    _geometry = geometry;
    _layout = layout;
    _metrics = metrics;
    _routing = null;
  }

  /// Completes when every route in flight has completed (accepted or dropped).
  @visibleForTesting
  Future<void> settled() => Future.wait(_inFlight.toList());

  /// Drops every later result.
  void dispose() => _disposed = true;
}

/// The points `start` until `end` of [points] (point q at `points[2q]`, `points[2q + 1]`) without consecutive equal
/// points.
Float64List _distinct(Float64List points, int start, int end) {
  final out = Float64List(2 * (end - start));
  var m = 0;
  for (var q = start; q < end; q++) {
    final double x = points[2 * q];
    final double y = points[2 * q + 1];
    if (m == 0 || x != out[2 * m - 2] || y != out[2 * m - 1]) {
      out[2 * m] = x;
      out[2 * m + 1] = y;
      m++;
    }
  }
  return Float64List.sublistView(out, 0, 2 * m);
}

/// A corner's radius (DS GraphEdge.jsx:47-48): at most [radius], at most half of each adjacent segment.
double _cornerRadius(double radius, double l1, double l2) => math.min(radius, math.min(l1 / 2, l2 / 2));

Path _rounded(Float64List p, double radius, double dx, double dy) {
  final path = Path();
  final int m = p.length ~/ 2;
  if (m == 0) {
    return path;
  }
  path.moveTo(p[0] - dx, p[1] - dy);
  for (var i = 1; i < m - 1; i++) {
    final double x0 = p[2 * i - 2];
    final double y0 = p[2 * i - 1];
    final double x1 = p[2 * i];
    final double y1 = p[2 * i + 1];
    final double x2 = p[2 * i + 2];
    final double y2 = p[2 * i + 3];
    final double l1 = math.sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0));
    final double l2 = math.sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1));
    final double r = _cornerRadius(radius, l1, l2);
    path
      ..lineTo(x1 - (x1 - x0) / l1 * r - dx, y1 - (y1 - y0) / l1 * r - dy)
      ..quadraticBezierTo(x1 - dx, y1 - dy, x1 + (x2 - x1) / l2 * r - dx, y1 + (y2 - y1) / l2 * r - dy);
  }
  return path..lineTo(p[2 * m - 2] - dx, p[2 * m - 1] - dy);
}

/// The polyline of points `start` until `end` of [points] (x, y pairs; point q at `points[2q]`) as an orthogonal path
/// with rounded corners (DS GraphEdge.jsx:42-53): consecutive equal points dropped, every inner bend a quadratic
/// corner with radius min([radius], half of each adjacent segment) and its control point at the bend. It starts at the
/// first point (an edge's parent end). [shift] is subtracted from every point, so a path near a far plane position
/// keeps its float precision.
Path graphRoundedPath(Float64List points, int start, int end, {double radius = 10, Offset shift = Offset.zero}) =>
    _rounded(_distinct(points, start, end), radius, shift.dx, shift.dy);

/// An edge's colour (design graph-view.jsx:1104-1108): lineage beats hovered beats normal.
enum GraphEdgeTone {
  /// `--edge`.
  normal,

  /// `--edge-hov`: touches the hovered node, or lies inside the focus set.
  hovered,

  /// `--co` with its glow: both ends in @'s lineage.
  lineage,
}

/// An edge's paint style: its [GraphEdgeTone] and whether it is dimmed (focus path on, not hovered).
typedef GraphEdgeStyle = ({GraphEdgeTone tone, bool dimmed});

/// Where a bridge breaks an edge (Story 10.4): the crossing point (`x`, `y`) in plane coordinates, and whether the cut
/// runs along this edge's vertical run (`vertical`) or its horizontal run.
typedef GraphEdgeCut = ({double x, double y, bool vertical});

/// The highlight state the edges are painted in.
@immutable
class GraphEdgeHighlight {
  /// No hover, focus path off, nothing dimmed, lineage on.
  const GraphEdgeHighlight({this.hoveredNode, this.focus, this.dim = 0, this.lineage = true});

  /// The hovered node, or null.
  final int? hoveredNode;

  /// The focus set, one byte per node (non-zero = in it), or null when the focus path is off (10.6 computes it).
  final Uint8List? focus;

  /// The dim progress in [0, 1]: the owner's 160 ms fade (10.6); a dimmed line paints at opacity 1 − .72·[dim].
  final double dim;

  /// Whether @'s lineage is highlighted.
  final bool lineage;
}

/// Paints one layout's edges from one [RouteGeometry] through the viewport's `paintEdges` hook (Story 10.4), behind the
/// cards. Per painter it builds @'s lineage (O(n + E)) and an index of the edges' bounds (O(E log E)); per paint it
/// strokes only the edges whose bounds meet the visible window (+ 8 px), cuts the window's bridges into them, and
/// issues one `drawPath` per non-empty group (the lineage two: its glow and its stroke). New inputs need a new
/// painter, a repaint, never a layout.
class GraphEdgePainter {
  /// A painter of [geometry] (router B's output for [layout]) in [theme]'s edge roles.
  GraphEdgePainter({required this.layout, required this.geometry, required this.theme})
    : assert(geometry.classes.edgeCount == layout.edgeCount, 'the geometry is not of this layout') {
    final int e = layout.edgeCount;
    final Int32List starts = geometry.pointStarts;
    final Float64List points = geometry.points;
    _bounds = Float64List(4 * e);
    _dashed = Uint8List(e);
    for (var k = 0; k < e; k++) {
      double left = double.infinity;
      double top = double.infinity;
      double right = double.negativeInfinity;
      double bottom = double.negativeInfinity;
      for (int q = starts[k]; q < starts[k + 1]; q++) {
        left = math.min(left, points[2 * q]);
        right = math.max(right, points[2 * q]);
        top = math.min(top, points[2 * q + 1]);
        bottom = math.max(bottom, points[2 * q + 1]);
      }
      _bounds
        ..[4 * k] = left
        ..[4 * k + 1] = top
        ..[4 * k + 2] = right
        ..[4 * k + 3] = bottom;
      _dashed[k] = layout.kindOf(k) == GraphEdgeKind.indirect ? 1 : 0;
    }
    final order = List<int>.generate(e, (k) => k)..sort((a, b) => _bounds[4 * a + 1].compareTo(_bounds[4 * b + 1]));
    _order = Int32List.fromList(order);
    _tops = Float64List(e);
    _blockBottoms = Float64List((e + _block - 1) ~/ _block)
      ..fillRange(0, (e + _block - 1) ~/ _block, double.negativeInfinity);
    for (var q = 0; q < e; q++) {
      final int k = order[q];
      _tops[q] = _bounds[4 * k + 1];
      _blockBottoms[q ~/ _block] = math.max(_blockBottoms[q ~/ _block], _bounds[4 * k + 3]);
    }
    _lineage = Uint8List(layout.nodeCount);
    final int? at = layout.workingCopyIndex;
    if (at != null) {
      _lineage[at] = 1;
      final stack = <int>[at];
      while (stack.isNotEmpty) {
        final (:int start, :int end) = layout.parentEdges(stack.removeLast());
        for (var k = start; k < end; k++) {
          final int parent = layout.parentOf(k);
          if (_lineage[parent] == 0) {
            _lineage[parent] = 1;
            stack.add(parent);
          }
        }
      }
    }
  }

  /// The layout painted.
  final GraphLayout layout;

  /// Router B's output for [layout].
  final RouteGeometry geometry;

  /// The colours.
  final GraphTheme theme;

  // DS graph.css:65-69 and GraphEdge.d.ts: widths, the dash (3 on, 5 off), the dim, the corner radius.
  static const _width = 1.5;
  static const _lineageWidth = 2.25;
  static const double _glowSigma = 2;
  static const double _dash = 3;
  static const double _period = 8;
  static const _dimDrop = .72;
  static const double _radius = 10;

  /// The paint query's margin around the visible window (the glow and the cuts reach past a line).
  static const double _margin = 8;

  /// A bridge's half width along its run (docs/graph-layout.md §14.4).
  static const double _cutHalf = 6;

  /// The bounds index's block size.
  static const _block = 64;

  /// Per edge: left, top, right, bottom of its polyline.
  late final Float64List _bounds;

  /// Edges by ascending top, their tops, and each block's largest bottom.
  late final Int32List _order;
  late final Float64List _tops;
  late final Float64List _blockBottoms;

  /// Per edge, 1 when Indirect (dashed).
  late final Uint8List _dashed;

  /// Per node, 1 when it is @ or one of its ancestors over the layout edges.
  late final Uint8List _lineage;

  /// Whether [node] is in @'s lineage (@ included).
  bool inLineage(int node) => _lineage[node] != 0;

  /// [edge]'s path: [graphRoundedPath] of its polyline, from its parent end.
  Path edgePath(int edge) =>
      graphRoundedPath(geometry.points, geometry.pointStarts[edge], geometry.pointStarts[edge + 1]);

  /// [edge]'s style under [highlight] (design graph-view.jsx:1104-1108).
  GraphEdgeStyle classify(int edge, GraphEdgeHighlight highlight) {
    final int parent = geometry.classes.edgeFroms[edge];
    final int child = geometry.classes.edgeTos[edge];
    final bool lineage = highlight.lineage && _lineage[parent] != 0 && _lineage[child] != 0;
    final Uint8List? focus = highlight.focus;
    final int? hovered = highlight.hoveredNode;
    final bool hover = focus != null
        ? focus[parent] != 0 && focus[child] != 0
        : hovered != null && (parent == hovered || child == hovered);
    return (
      tone: lineage
          ? GraphEdgeTone.lineage
          : hover
          ? GraphEdgeTone.hovered
          : GraphEdgeTone.normal,
      dimmed: focus != null && !hover,
    );
  }

  /// The edges whose bounds meet [rect] (closed), ascending.
  List<int> _query(Rect rect) {
    // The number of edges whose top is ≤ rect.bottom.
    var lo = 0;
    int hi = _tops.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (_tops[mid] <= rect.bottom) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final upto = lo;
    final out = <int>[];
    for (var b = 0; b * _block < upto; b++) {
      if (_blockBottoms[b] < rect.top) {
        continue;
      }
      final int end = math.min(upto, (b + 1) * _block);
      for (int q = b * _block; q < end; q++) {
        final int k = _order[q];
        if (_bounds[4 * k + 3] >= rect.top && _bounds[4 * k] <= rect.right && _bounds[4 * k + 2] >= rect.left) {
          out.add(k);
        }
      }
    }
    return out..sort();
  }

  /// The edges a paint of [window] strokes: those whose bounds meet [window] grown by 8 px, ascending.
  List<int> edgesIn(Rect window) => _query(window.inflate(_margin));

  /// Per edge, the cuts of the bridges whose crossing lies in [window] grown by 6 px (one `RouteGeometry.bridges`
  /// query); each bridge cuts the edge that breaks.
  Map<int, List<GraphEdgeCut>> cutsIn(Rect window) {
    final Rect grown = window.inflate(_cutHalf);
    final RouteBridges bridges = geometry.bridges(grown.left, grown.top, grown.right, grown.bottom);
    final out = <int, List<GraphEdgeCut>>{};
    for (var i = 0; i < bridges.length; i++) {
      final vertical = bridges.verticalBreaks[i] != 0;
      final int edge = vertical ? bridges.verticalEdges[i] : bridges.horizontalEdges[i];
      (out[edge] ??= <GraphEdgeCut>[]).add((x: bridges.xs[i], y: bridges.ys[i], vertical: vertical));
    }
    return out;
  }

  /// The edges whose polyline (unrounded) lies within [tolerance] of [point] (plane coordinates), ascending.
  List<int> edgesAt(Offset point, {double tolerance = 4}) {
    final Int32List starts = geometry.pointStarts;
    final Float64List p = geometry.points;
    final double t2 = tolerance * tolerance;
    return <int>[
      for (final int k in _query(Rect.fromCenter(center: point, width: 2 * tolerance, height: 2 * tolerance)))
        if (_near(p, starts[k], starts[k + 1], point, t2)) k,
    ];
  }

  static bool _near(Float64List p, int start, int end, Offset point, double t2) {
    for (int q = start + 1; q < end; q++) {
      final double x1 = p[2 * q - 2];
      final double y1 = p[2 * q - 1];
      final double x2 = p[2 * q];
      final double y2 = p[2 * q + 1];
      final double dx = point.dx - point.dx.clamp(math.min(x1, x2), math.max(x1, x2));
      final double dy = point.dy - point.dy.clamp(math.min(y1, y2), math.max(y1, y2));
      if (dx * dx + dy * dy <= t2) {
        return true;
      }
    }
    return false;
  }

  /// [edge]'s stroked geometry for a paint of [window]: its rounded path, dashed when Indirect (3 on, 5 off from the
  /// parent end; only the dashes near [window]), with [cuts] removed in arc length, minus [shift].
  @visibleForTesting
  Path strokePath(int edge, Rect window, {List<GraphEdgeCut>? cuts, Offset shift = Offset.zero}) {
    final out = Path();
    _addStroke(out, edge, window.inflate(_margin), cuts, shift.dx, shift.dy);
    return out;
  }

  void _addStroke(Path into, int edge, Rect clip, List<GraphEdgeCut>? cuts, double dx, double dy) {
    final Float64List p = _distinct(geometry.points, geometry.pointStarts[edge], geometry.pointStarts[edge + 1]);
    final Path path = _rounded(p, _radius, dx, dy);
    final dashed = _dashed[edge] != 0;
    if (!dashed && cuts == null) {
      into.addPath(path, Offset.zero);
      return;
    }
    final PathMetric? metric = path.computeMetrics().firstOrNull;
    if (metric == null) {
      return;
    }
    final double total = metric.length;
    final arc = _Arc(p, _radius);
    final holes = <(double, double)>[
      for (final GraphEdgeCut cut in cuts ?? const <GraphEdgeCut>[]) ?arc.cut(cut, _cutHalf),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    void piece(double a, double b) {
      var from = a;
      for (final (double start, double end) in holes) {
        if (end <= from) {
          continue;
        }
        if (start >= b) {
          break;
        }
        if (start > from) {
          into.addPath(metric.extractPath(from, start), Offset.zero);
        }
        from = math.max(from, end);
        if (from >= b) {
          return;
        }
      }
      into.addPath(metric.extractPath(from, b), Offset.zero);
    }

    if (!dashed) {
      piece(0, total);
      return;
    }
    final (double lo, double hi) = arc.visible(clip);
    for (double at = (lo / _period).floorToDouble() * _period; at < math.min(hi, total); at += _period) {
      piece(at, math.min(at + _dash, total));
    }
  }

  /// Paints the edges visible in [visible] (plane coordinates) at [origin] (where the plane's (0, 0) paints): normal,
  /// normal dimmed, hovered, lineage, lineage dimmed, one path each.
  void paint(
    PaintingContext context,
    Offset origin,
    Rect visible, {
    GraphEdgeHighlight highlight = const GraphEdgeHighlight(),
  }) {
    final List<int> edges = edgesIn(visible);
    if (edges.isEmpty) {
      return;
    }
    final Map<int, List<GraphEdgeCut>> cuts = cutsIn(visible);
    final Rect clip = visible.inflate(_margin);
    // Paths relative to the window's corner, so a far plane position keeps its float precision.
    final double dx = visible.left;
    final double dy = visible.top;
    final groups = List<Path?>.filled(5, null);
    for (final k in edges) {
      final (:GraphEdgeTone tone, :bool dimmed) = classify(k, highlight);
      final int group = switch (tone) {
        GraphEdgeTone.normal => dimmed ? 1 : 0,
        GraphEdgeTone.hovered => 2,
        GraphEdgeTone.lineage => dimmed ? 4 : 3,
      };
      _addStroke(groups[group] ??= Path(), k, clip, cuts[k], dx, dy);
    }
    final double fade = 1 - _dimDrop * highlight.dim.clamp(0, 1);
    Paint stroke(Color color, double width, {bool dimmed = false}) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeWidth = width
      ..color = dimmed ? color.withValues(alpha: color.a * fade) : color;
    final Canvas canvas = context.canvas
      ..save()
      ..translate(origin.dx + dx, origin.dy + dy);
    for (var g = 0; g < groups.length; g++) {
      final Path? path = groups[g];
      if (path == null) {
        continue;
      }
      switch (g) {
        case 0 || 1:
          canvas.drawPath(path, stroke(theme.edge, _width, dimmed: g == 1));
        case 2:
          canvas.drawPath(path, stroke(theme.edgeHover, _width));
        default:
          canvas
            ..drawPath(
              path,
              stroke(theme.lineageGlow, _lineageWidth, dimmed: g == 4)
                ..maskFilter = const MaskFilter.blur(BlurStyle.normal, _glowSigma),
            )
            ..drawPath(path, stroke(theme.lineage, _lineageWidth, dimmed: g == 4));
      }
    }
    canvas.restore();
  }
}

/// One edge's deduplicated polyline and the map from its arc length to its rounded path's arc length: identity on the
/// straight parts, linear inside each corner, whose length is Skia's own (so `extractPath` lands where it should).
final class _Arc {
  _Arc(this.p, double radius) {
    final int m = p.length ~/ 2;
    _s = Float64List(m);
    for (var i = 1; i < m; i++) {
      _s[i] = _s[i - 1] + _length(i);
    }
    var u = 0.0;
    var s = 0.0;
    _knotS.add(0);
    _knotU.add(0);
    for (var i = 1; i < m - 1; i++) {
      final double l1 = _length(i);
      final double l2 = _length(i + 1);
      final double r = _cornerRadius(radius, l1, l2);
      final double x = p[2 * i];
      final double y = p[2 * i + 1];
      final double corner =
          (Path()
                ..moveTo((p[2 * i - 2] - x) / l1 * r, (p[2 * i - 1] - y) / l1 * r)
                ..quadraticBezierTo(0, 0, (p[2 * i + 2] - x) / l2 * r, (p[2 * i + 3] - y) / l2 * r))
              .computeMetrics()
              .first
              .length;
      u += _s[i] - r - s;
      s = _s[i] - r;
      _knotS.add(s);
      _knotU.add(u);
      u += corner;
      s = _s[i] + r;
      _knotS.add(s);
      _knotU.add(u);
    }
  }

  final Float64List p;
  late final Float64List _s;
  final _knotS = <double>[];
  final _knotU = <double>[];

  double _length(int i) {
    final double dx = p[2 * i] - p[2 * i - 2];
    final double dy = p[2 * i + 1] - p[2 * i - 1];
    return math.sqrt(dx * dx + dy * dy);
  }

  /// The rounded path's arc length at the polyline's arc length [s].
  double map(double s) {
    var j = 0;
    while (j + 1 < _knotS.length && _knotS[j + 1] <= s) {
      j++;
    }
    if (j + 1 == _knotS.length || _knotS[j + 1] == _knotS[j]) {
      return _knotU[j] + (s - _knotS[j]);
    }
    final double t = (s - _knotS[j]) / (_knotS[j + 1] - _knotS[j]);
    return _knotU[j] + t * (_knotU[j + 1] - _knotU[j]);
  }

  /// The rounded arc-length interval [cut] removes ([half] either side of the crossing along its run), or null when
  /// no run of this polyline carries it.
  (double, double)? cut(GraphEdgeCut cut, double half) {
    for (var i = 1; i < p.length ~/ 2; i++) {
      final double x1 = p[2 * i - 2];
      final double y1 = p[2 * i - 1];
      final double x2 = p[2 * i];
      final double y2 = p[2 * i + 1];
      final double along;
      if (cut.vertical) {
        if (x1 != x2 || x1 != cut.x || cut.y <= math.min(y1, y2) || cut.y >= math.max(y1, y2)) {
          continue;
        }
        along = (cut.y - y1).abs();
      } else {
        if (y1 != y2 || y1 != cut.y || cut.x <= math.min(x1, x2) || cut.x >= math.max(x1, x2)) {
          continue;
        }
        along = (cut.x - x1).abs();
      }
      final double at = _s[i - 1] + along;
      return (map(at - half), map(at + half));
    }
    return null;
  }

  /// The rounded arc-length range of the parts of the polyline inside [rect] ((0, 0) when none).
  (double, double) visible(Rect rect) {
    double lo = double.infinity;
    double hi = double.negativeInfinity;
    for (var i = 1; i < p.length ~/ 2; i++) {
      final double x1 = p[2 * i - 2];
      final double y1 = p[2 * i - 1];
      final double x2 = p[2 * i];
      final double y2 = p[2 * i + 1];
      // An axis-parallel segment: clip its moving coordinate to the rect, after checking the fixed one.
      final horizontal = y1 == y2;
      final fixed = horizontal ? y1 : x1;
      if (horizontal ? (fixed < rect.top || fixed > rect.bottom) : (fixed < rect.left || fixed > rect.right)) {
        continue;
      }
      final a = horizontal ? x1 : y1;
      final b = horizontal ? x2 : y2;
      final double min = horizontal ? rect.left : rect.top;
      final double max = horizontal ? rect.right : rect.bottom;
      if (math.max(a, b) < min || math.min(a, b) > max) {
        continue;
      }
      final double from = a.clamp(min, max);
      final double to = b.clamp(min, max);
      final double s1 = _s[i - 1] + (from - a).abs();
      final double s2 = _s[i - 1] + (to - a).abs();
      lo = math.min(lo, math.min(s1, s2));
      hi = math.max(hi, math.max(s1, s2));
    }
    return lo > hi ? (0, 0) : (map(lo), map(hi));
  }
}
