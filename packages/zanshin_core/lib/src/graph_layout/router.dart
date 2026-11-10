// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'graph_grid_view.dart';
import 'sort.dart';

// The line router (docs/graph-layout.md §14): one line per parent → child layout edge, by the graph layout lab's
// rules (`labLines` in spikes/graph-layout-lab/lib/lines.dart, every switch on). The per-layout stage runs once in
// grid units; the geometry stage runs per card size in pixels. Indexes replace the lab's scans; §14.6 lists every
// other difference from the lab.

/// The largest number of visible nodes for which the caller runs both stages synchronously on the
/// UI isolate; above it, in `Isolate.run` (docs/graph-layout.md §14.5: the largest n whose measured
/// per-layout + geometry time stays within one 8 ms frame, AOT).
const routeSyncNodeLimit = 7000;

/// The least room a bridge leaves, and how far a deep run keeps from the far side of its row gap.
const double _clear = 12;

/// The port fan-out at both card edges: offsets from the centre of the lines that do not take it.
const double _entryFirst = 24;
const double _entryStep = 16;
const double _entryMin = 8;
const double _entryInset = 18;

/// The most placements of the ports while lines on one x are separated ([_GeometryBuilder._banCollisions]).
const _settlePasses = 8;

/// How far a horizontal run sits from the card it belongs to, as a share of the row gap.
const _lift = 0.4;

/// How far a horizontal run stays from any card.
const double _cardClear = 8;

/// The distance of runs of one fan and of lines in one gutter.
const double _track = 6;

/// A crossing must lie this far inside both runs.
const double _crossMargin = 1;

/// A bridge's half width along its run, and the room a run keeps to its ends.
const double _cutHalf = 6;

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;

/// The per-layout stage of the line router (docs/graph-layout.md §14.2), in grid units with no card
/// size: per column its visible nodes by row, per node its place in that list and whether its branch
/// goes on, per layout edge its entry slot, its `deep` flag and whether it is its child's first
/// parent. [RouteGeometry] turns it into pixels for one [RouteMetrics]; a card-size change re-runs
/// only that stage.
///
/// The input arrays are kept by reference and must not change while this object is used.
final class RouteClasses {
  RouteClasses._({
    required this.nodeRows,
    required this.nodeCols,
    required this.unit,
    required this.edgeFroms,
    required this.edgeTos,
    required this.maxRow,
    required this.columns,
    required this.slots,
    required this.deep,
    required this.firstParents,
    required this.goesOn,
    required this.columnStarts,
    required this.columnNodes,
    required this.columnPos,
    required this._inStarts,
    required this._inEdges,
    required this._outStarts,
    required this._outEdges,
  });

  /// Prepares the layout edges of a grid, as `GraphGridView` exposes it: per node its row
  /// ([nodeRows], −1 for a hidden stack member, which is skipped) and column ([nodeCols]), [unit]
  /// rows per pitch (16 in `free`, 1 in `compact`), and per layout edge its parent ([edgeFroms]),
  /// child ([edgeTos]) and kind ([edgeKinds]; `GraphGridView`'s codes), in docs/graph-layout.md §3's
  /// order (a child's first edge is its first parent). [parentCounts] is the topology's real parent
  /// count per topology node; a node index at or past its length (a stack node) counts as not
  /// single-parent.
  ///
  /// Throws [ArgumentError] when the node arrays or the edge arrays differ in length, [unit] ≤ 0, a
  /// visible node has a negative column, or an edge names a node out of range or a hidden one.
  factory RouteClasses.compute({
    required Int32List nodeRows,
    required Int32List nodeCols,
    required int unit,
    required Int32List edgeFroms,
    required Int32List edgeTos,
    required Uint8List edgeKinds,
    required Int32List parentCounts,
  }) {
    final int n = nodeRows.length;
    final int e = edgeFroms.length;
    if (nodeCols.length != n) {
      throw ArgumentError('nodeCols has ${nodeCols.length} entries, nodeRows $n');
    }
    if (edgeTos.length != e || edgeKinds.length != e) {
      throw ArgumentError('edge arrays differ in length: ${edgeFroms.length}, ${edgeTos.length}, ${edgeKinds.length}');
    }
    if (unit <= 0) {
      throw ArgumentError.value(unit, 'unit', 'must be positive');
    }
    var maxRow = 0;
    var maxCol = -1;
    for (var i = 0; i < n; i++) {
      final int row = nodeRows[i];
      if (row < 0) {
        continue;
      }
      final int col = nodeCols[i];
      if (col < 0) {
        throw ArgumentError('node $i is visible (row $row) with column $col');
      }
      if (row > maxRow) {
        maxRow = row;
      }
      if (col > maxCol) {
        maxCol = col;
      }
    }
    for (var k = 0; k < e; k++) {
      final int p = edgeFroms[k];
      final int c = edgeTos[k];
      if (p < 0 || p >= n || c < 0 || c >= n) {
        throw ArgumentError('edge $k ($p → $c) names a node outside [0, $n)');
      }
      if (nodeRows[p] < 0 || nodeRows[c] < 0) {
        throw ArgumentError('edge $k ($p → $c) touches a hidden node');
      }
    }
    final int columns = maxCol + 1;

    // Per column its visible nodes by row (a CSR over columns).
    final columnStarts = Int32List(columns + 1);
    var visible = 0;
    for (var i = 0; i < n; i++) {
      if (nodeRows[i] >= 0) {
        columnStarts[nodeCols[i] + 1]++;
        visible++;
      }
    }
    for (var c = 0; c < columns; c++) {
      columnStarts[c + 1] += columnStarts[c];
    }
    final columnNodes = Int32List(visible);
    final colKey = Int64List(n);
    var v = 0;
    for (var i = 0; i < n; i++) {
      if (nodeRows[i] >= 0) {
        columnNodes[v++] = i;
        colKey[i] = nodeCols[i];
      }
    }
    sortIndicesStable(columnNodes, colKey, second: nodeRows);
    final columnPos = Int32List(n);
    for (var q = 0; q < visible; q++) {
      columnPos[columnNodes[q]] = q;
    }

    // In- and out-edges per node, in edge order (CSR).
    final inStarts = Int32List(n + 1);
    final outStarts = Int32List(n + 1);
    for (var k = 0; k < e; k++) {
      inStarts[edgeTos[k] + 1]++;
      outStarts[edgeFroms[k] + 1]++;
    }
    for (var i = 0; i < n; i++) {
      inStarts[i + 1] += inStarts[i];
      outStarts[i + 1] += outStarts[i];
    }
    final inEdges = Int32List(e);
    final outEdges = Int32List(e);
    final inFill = Int32List.fromList(inStarts);
    final outFill = Int32List.fromList(outStarts);
    for (var k = 0; k < e; k++) {
      inEdges[inFill[edgeTos[k]]++] = k;
      outEdges[outFill[edgeFroms[k]]++] = k;
    }

    final firstParents = Uint8List(e);
    final goesOn = Uint8List(n);
    for (var k = 0; k < e; k++) {
      if (inEdges[inStarts[edgeTos[k]]] == k) {
        firstParents[k] = 1;
        if (nodeCols[edgeFroms[k]] == nodeCols[edgeTos[k]]) {
          goesOn[edgeFroms[k]] = 1;
        }
      }
    }

    // Entry slots: the Indirect edges into a single-parent node with ≥ 2 of them share one.
    final slots = Int32List(e);
    final deep = Uint8List(e);
    for (var k = 0; k < e; k++) {
      slots[k] = k;
    }
    final int counted = parentCounts.length < n ? parentCounts.length : n;
    for (var c = 0; c < counted; c++) {
      if (parentCounts[c] != 1) {
        continue;
      }
      var rep = -1;
      var indirect = 0;
      for (int q = inStarts[c]; q < inStarts[c + 1]; q++) {
        final int k = inEdges[q];
        if (edgeKinds[k] == GraphGridView.edgeKindIndirect) {
          if (rep < 0) {
            rep = k;
          }
          indirect++;
        }
      }
      if (indirect < 2) {
        continue;
      }
      for (int q = inStarts[c]; q < inStarts[c + 1]; q++) {
        final int k = inEdges[q];
        if (edgeKinds[k] == GraphGridView.edgeKindIndirect) {
          slots[k] = rep;
          deep[k] = 1;
        }
      }
    }

    return RouteClasses._(
      nodeRows: nodeRows,
      nodeCols: nodeCols,
      unit: unit,
      edgeFroms: edgeFroms,
      edgeTos: edgeTos,
      maxRow: maxRow,
      columns: columns,
      slots: slots,
      deep: deep,
      firstParents: firstParents,
      goesOn: goesOn,
      columnStarts: columnStarts,
      columnNodes: columnNodes,
      columnPos: columnPos,
      inStarts: inStarts,
      inEdges: inEdges,
      outStarts: outStarts,
      outEdges: outEdges,
    );
  }

  /// Each node's row (the input), −1 for a hidden node.
  final Int32List nodeRows;

  /// Each node's column (the input).
  final Int32List nodeCols;

  /// U, the rows per pitch (the input).
  final int unit;

  /// Each layout edge's parent (the input).
  final Int32List edgeFroms;

  /// Each layout edge's child (the input).
  final Int32List edgeTos;

  /// The largest visible row, 0 for none.
  final int maxRow;

  /// The number of columns: the largest visible column plus 1.
  final int columns;

  /// Each edge's entry slot: the index of the slot's first edge (its own index unless it shares).
  final Int32List slots;

  /// Each edge's `deep` flag (1 for the Indirect edges of a shared slot): the run that ends at its
  /// child sits farther from the child, so the shared stem keeps its length.
  final Uint8List deep;

  /// Whether each edge is its child's first parent (1) or not (0).
  final Uint8List firstParents;

  /// Per node, 1 where a first-parent child sits in its column: its branch goes on, so a merge line
  /// from it can bend at it (docs/graph-layout.md §14.3).
  final Uint8List goesOn;

  /// The column CSR offsets ([columns] + 1): column c's visible nodes are
  /// `columnNodes[columnStarts[c] ..< columnStarts[c + 1]]`.
  final Int32List columnStarts;

  /// Every visible node, by column, then by row ascending.
  final Int32List columnNodes;

  /// Per visible node, its index in [columnNodes].
  final Int32List columnPos;

  final Int32List _inStarts;
  final Int32List _inEdges;
  final Int32List _outStarts;
  final Int32List _outEdges;

  /// The number of layout edges.
  int get edgeCount => edgeFroms.length;
}

/// The card size and spacing the geometry stage lays lines out for (docs/graph-layout.md §14.3), in
/// logical pixels: card [width] W and [height] H, column gap [gapX], row gap [gapY], plane padding
/// [pad].
final class RouteMetrics {
  /// Metrics for cards of [width] × [height] with the design's gaps and padding.
  const RouteMetrics({required this.width, required this.height, this.gapX = 56, this.gapY = 48, this.pad = 56});

  /// W, the card width.
  final double width;

  /// H, the card height.
  final double height;

  /// The gap between two columns of cards.
  final double gapX;

  /// The gap between two rows of cards (one pitch is H + [gapY]).
  final double gapY;

  /// The plane's padding around the cards.
  final double pad;
}

/// The geometry stage of the line router (docs/graph-layout.md §14.3): one [RouteClasses] laid out
/// for one [RouteMetrics]. Every edge's polyline (2, 4, 6 or 8 points, from the parent's top edge to
/// the child's bottom edge), every node's entry ports, and the run indexes [bridges] queries — all
/// in typed arrays. Deterministic: the same classes and metrics give the same arrays.
final class RouteGeometry {
  RouteGeometry._({
    required this.classes,
    required this.metrics,
    required this.pointStarts,
    required this.points,
    required this.portStarts,
    required this.portXs,
    required this.verticalXs,
    required this.verticalTops,
    required this.verticalBottoms,
    required this.verticalEdges,
    required this.horizontalYs,
    required this.horizontalLefts,
    required this.horizontalRights,
    required this.horizontalEdges,
    required this.behindCards,
    required this.behindEdges,
    required this.sharedStretches,
    required this.sharedEdges,
    required this.tightFans,
    required this.unavoidableCrossings,
    required this.unsettledPorts,
  });

  /// Lays [classes] out for [metrics].
  factory RouteGeometry.compute(RouteClasses classes, RouteMetrics metrics) =>
      _GeometryBuilder(classes, metrics).build();

  /// The per-layout stage this geometry was computed from.
  final RouteClasses classes;

  /// The metrics this geometry was computed for.
  final RouteMetrics metrics;

  /// The polyline CSR offsets (E + 1, in points): edge k's points run from `pointStarts[k]` up to
  /// `pointStarts[k + 1]`.
  final Int32List pointStarts;

  /// Every polyline's points as x, y pairs (point q at `points[2q]`, `points[2q + 1]`); the points
  /// are the bends.
  final Float64List points;

  /// The entry-port CSR offsets (one per node, + 1): node i's ports are `portXs` from
  /// `portStarts[i]` up to `portStarts[i + 1]`.
  final Int32List portStarts;

  /// Every node's distinct entry x's on its bottom edge, in edge order.
  final Float64List portXs;

  /// The vertical runs' x, sorted ascending (ties in polyline order).
  final Float64List verticalXs;

  /// The vertical runs' upper y.
  final Float64List verticalTops;

  /// The vertical runs' lower y.
  final Float64List verticalBottoms;

  /// The vertical runs' edges.
  final Int32List verticalEdges;

  /// The horizontal runs' y, sorted ascending (ties in polyline order).
  final Float64List horizontalYs;

  /// The horizontal runs' left x.
  final Float64List horizontalLefts;

  /// The horizontal runs' right x.
  final Float64List horizontalRights;

  /// The horizontal runs' edges.
  final Int32List horizontalEdges;

  /// Reported: the number of lines that still pass behind a card that is neither of their ends.
  final int behindCards;

  /// Per edge, 1 where it is one of the [behindCards] lines.
  final Uint8List behindEdges;

  /// Reported: the pairs of runs of two lines that share a stretch of more than 1 px on one x or one
  /// y, not counting two lines of one slot or two lines on one port of one card edge.
  final int sharedStretches;

  /// Per edge, 1 where it takes part in one of the [sharedStretches].
  final Uint8List sharedEdges;

  /// Reported: the fans (runs of one card edge to one side) whose runs come closer than 2 px.
  final int tightFans;

  /// Reported: pairs of runs in one cluster that each must lie above the other; they cross.
  final int unavoidableCrossings;

  /// Reported: pairs of lines still sharing an upright stretch at their card edges after the last of
  /// the port passes (0 when the passes settled); the longer-straight tie-break would move one of each pair.
  final int unsettledPorts;

  /// The bridges whose crossing point lies in [x0, x1) × [y0, y1) (docs/graph-layout.md §14.4), by
  /// horizontal run index, then vertical run index. Any two edges bridge, also two that share a node
  /// (Ralph 2026-11-07; GL skips those).
  ///
  /// A break reaches 6 px around its crossing point, so a caller that paints tiles queries each
  /// tile's window grown by 6 px on every side and drops the crossings it already painted.
  ///
  /// Cost: a binary search per axis, then a scan of every vertical run whose x lies in the window's
  /// x-strip — over the whole plane height, so a long linear history (many verticals at one x) makes
  /// even a small window scan them all — then a test of each horizontal in the window against the
  /// verticals that overlap it.
  RouteBridges bridges(double x0, double y0, double x1, double y1) {
    final int hFrom = _lowerBound(horizontalYs, y0);
    final int hTo = _lowerBound(horizontalYs, y1);
    final int vFrom = _lowerBound(verticalXs, x0);
    final int vTo = _lowerBound(verticalXs, x1);
    final out = _BridgeBuffer();
    if (hFrom >= hTo || vFrom >= vTo) {
      return out.finish();
    }
    // shortcut: a linear scan of the window's x-strip; group the verticals per x and sort each group
    // by y (or index them by y) if a strip of a long history shows in 10.4's frame time.
    final candidates = Int32List(vTo - vFrom);
    var count = 0;
    for (var q = vFrom; q < vTo; q++) {
      if (verticalTops[q] + _crossMargin < y1 && verticalBottoms[q] - _crossMargin > y0) {
        candidates[count++] = q;
      }
    }
    for (var h = hFrom; h < hTo; h++) {
      final double hy = horizontalYs[h];
      final double ha = horizontalLefts[h];
      final double hb = horizontalRights[h];
      final int he = horizontalEdges[h];
      for (var c = 0; c < count; c++) {
        final int q = candidates[c];
        final double vx = verticalXs[q];
        final double va = verticalTops[q];
        final double vb = verticalBottoms[q];
        if (!(vx > ha + _crossMargin && vx < hb - _crossMargin && hy > va + _crossMargin && hy < vb - _crossMargin)) {
          continue;
        }
        final int ve = verticalEdges[q];
        if (he == ve) {
          continue;
        }
        final double hRoom = _min(vx - _cutHalf - ha, hb - vx - _cutHalf);
        final double vRoom = _min(hy - _cutHalf - va, vb - hy - _cutHalf);
        out.add(vx, hy, he, ve, vertical: hRoom < _clear && vRoom > hRoom);
      }
    }
    return out.finish();
  }

  /// The first index of the ascending [list] whose value is ≥ [x].
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

/// The bridges of one window ([RouteGeometry.bridges]): per crossing its point, the two edges and
/// which of them breaks. A horizontal break covers (x − 6, y − 5, 12, 10), a vertical one
/// (x − 5, y − 6, 10, 12).
final class RouteBridges {
  RouteBridges._(this.length, this.xs, this.ys, this.horizontalEdges, this.verticalEdges, this.verticalBreaks);

  /// The number of bridges.
  final int length;

  /// Each crossing's x (the vertical run's).
  final Float64List xs;

  /// Each crossing's y (the horizontal run's).
  final Float64List ys;

  /// Each crossing's horizontal edge.
  final Int32List horizontalEdges;

  /// Each crossing's vertical edge.
  final Int32List verticalEdges;

  /// 1 where the vertical breaks (10 × 12), 0 where the horizontal breaks (12 × 10).
  final Uint8List verticalBreaks;
}

/// A growable bridge list.
final class _BridgeBuffer {
  var _n = 0;
  var _xs = Float64List(16);
  var _ys = Float64List(16);
  var _h = Int32List(16);
  var _v = Int32List(16);
  var _b = Uint8List(16);

  void add(double x, double y, int h, int v, {required bool vertical}) {
    if (_n == _xs.length) {
      final int size = 2 * _n;
      _xs = Float64List(size)..setAll(0, _xs);
      _ys = Float64List(size)..setAll(0, _ys);
      _h = Int32List(size)..setAll(0, _h);
      _v = Int32List(size)..setAll(0, _v);
      _b = Uint8List(size)..setAll(0, _b);
    }
    _xs[_n] = x;
    _ys[_n] = y;
    _h[_n] = h;
    _v[_n] = v;
    _b[_n] = vertical ? 1 : 0;
    _n++;
  }

  RouteBridges finish() => RouteBridges._(
    _n,
    Float64List.sublistView(_xs, 0, _n),
    Float64List.sublistView(_ys, 0, _n),
    Int32List.sublistView(_h, 0, _n),
    Int32List.sublistView(_v, 0, _n),
    Uint8List.sublistView(_b, 0, _n),
  );
}

/// The runs the shape phase records, in edge order; the runs of one shape are consecutive, from the
/// parent's end. A taken detour points its edge at its own two runs, so nothing is moved.
final class _RunBuffer {
  _RunBuffer(int capacity)
    : edge = Int32List(capacity),
      down = Int32List(capacity),
      up = Int32List(capacity),
      level = Float64List(capacity),
      lo = Float64List(capacity),
      hi = Float64List(capacity),
      wish = Float64List(capacity);

  Int32List edge;
  Int32List down;
  Int32List up;
  Float64List level;
  Float64List lo;
  Float64List hi;
  Float64List wish;
  var count = 0;

  void add(int k, int d, int u, double l, double bandLo, double bandHi, double w) {
    if (count == edge.length) {
      final int size = 2 * count;
      edge = Int32List(size)..setAll(0, edge);
      down = Int32List(size)..setAll(0, down);
      up = Int32List(size)..setAll(0, up);
      level = Float64List(size)..setAll(0, level);
      lo = Float64List(size)..setAll(0, lo);
      hi = Float64List(size)..setAll(0, hi);
      wish = Float64List(size)..setAll(0, wish);
    }
    edge[count] = k;
    down[count] = d;
    up[count] = u;
    level[count] = l;
    lo[count] = bandLo;
    hi[count] = bandHi;
    wish[count] = w;
    count++;
  }
}

/// One shape's stretches before tracks and ports: verticals (doubled position, top, bottom) and
/// horizontals (y, left, right position). At most 4 and 3.
final class _ShapeRuns {
  final vq = Int32List(4);
  final vTop = Float64List(4);
  final vBottom = Float64List(4);
  var verticals = 0;
  final hy = Float64List(3);
  final hLeft = Int32List(3);
  final hRight = Int32List(3);
  var horizontals = 0;

  void clear() {
    verticals = 0;
    horizontals = 0;
  }

  void vertical(int q, double top, double bottom) {
    if (top < bottom) {
      vq[verticals] = q;
      vTop[verticals] = top;
      vBottom[verticals++] = bottom;
    }
  }

  void horizontal(double y, int a, int b) {
    if (a != b) {
      hy[horizontals] = y;
      hLeft[horizontals] = a < b ? a : b;
      hRight[horizontals++] = a < b ? b : a;
    }
  }

  /// How many of this shape's stretches strictly cross a stretch of [o].
  int crossings(_ShapeRuns o) {
    var count = 0;
    for (var v = 0; v < verticals; v++) {
      for (var h = 0; h < o.horizontals; h++) {
        if (_crosses(vq[v], vTop[v], vBottom[v], o.hy[h], o.hLeft[h], o.hRight[h])) {
          count++;
        }
      }
    }
    for (var h = 0; h < horizontals; h++) {
      for (var v = 0; v < o.verticals; v++) {
        if (_crosses(o.vq[v], o.vTop[v], o.vBottom[v], hy[h], hLeft[h], hRight[h])) {
          count++;
        }
      }
    }
    return count;
  }

  static bool _crosses(int q, double top, double bottom, double y, int left, int right) =>
      left < q && q < right && top < y && y < bottom;
}

/// How many stretches a shape crosses: per doubled position the sorted y's of the horizontal runs
/// that strictly pass it and the sorted tops and bottoms of the vertical runs on it, built once from
/// the first shapes (docs/graph-layout.md §14.3, Detours).
final class _CrossingIndex {
  _CrossingIndex(_GeometryBuilder g)
    : hStarts = Int32List(2 * g.c.columns + 1),
      vStarts = Int32List(2 * g.c.columns + 1) {
    final int size = 2 * g.c.columns;
    final int e = g.e;
    var maxV = 0;
    var maxH = 0;
    for (var k = 0; k < e; k++) {
      final int half = g.shapePoints[k] >> 1;
      maxV += half;
      maxH += half - 1;
    }
    final vq = Int32List(maxV);
    final vt = Float64List(maxV);
    final vb = Float64List(maxV);
    final hy = Float64List(maxH);
    final hl = Int32List(maxH);
    final hr = Int32List(maxH);
    var nv = 0;
    var nh = 0;
    final shape = _ShapeRuns();
    for (var k = 0; k < e; k++) {
      g.shapeRuns(k, g.shapePoints[k], g.shapeRun[k], g.shapeGutter[k], shape);
      for (var v = 0; v < shape.verticals; v++) {
        vq[nv] = shape.vq[v];
        vt[nv] = shape.vTop[v];
        vb[nv++] = shape.vBottom[v];
      }
      for (var h = 0; h < shape.horizontals; h++) {
        hy[nh] = shape.hy[h];
        hl[nh] = shape.hLeft[h];
        hr[nh++] = shape.hRight[h];
      }
    }
    // Filling a position's list in ascending order of the whole set leaves it sorted.
    final hOrder = Int32List(nh);
    for (var r = 0; r < nh; r++) {
      hOrder[r] = r;
    }
    sortIndicesStableByDouble(hOrder, hy);
    for (var r = 0; r < nh; r++) {
      for (int q = hl[r] + 1; q < hr[r]; q++) {
        hStarts[q + 1]++;
      }
    }
    for (var q = 0; q < size; q++) {
      hStarts[q + 1] += hStarts[q];
    }
    hYs = Float64List(hStarts[size]);
    final hFill = Int32List.fromList(hStarts);
    for (var o = 0; o < nh; o++) {
      final int r = hOrder[o];
      for (int q = hl[r] + 1; q < hr[r]; q++) {
        hYs[hFill[q]++] = hy[r];
      }
    }
    for (var r = 0; r < nv; r++) {
      vStarts[vq[r] + 1]++;
    }
    for (var q = 0; q < size; q++) {
      vStarts[q + 1] += vStarts[q];
    }
    vTops = Float64List(nv);
    vBottoms = Float64List(nv);
    void fill(Float64List keys, Float64List out) {
      final order = Int32List(nv);
      for (var r = 0; r < nv; r++) {
        order[r] = r;
      }
      sortIndicesStableByDouble(order, keys);
      final at = Int32List.fromList(vStarts);
      for (var o = 0; o < nv; o++) {
        out[at[vq[order[o]]]++] = keys[order[o]];
      }
    }

    fill(vt, vTops);
    fill(vb, vBottoms);
  }

  final Int32List hStarts;
  late final Float64List hYs;
  final Int32List vStarts;
  late final Float64List vTops;
  late final Float64List vBottoms;

  /// How many runs of the first shapes strictly cross a run of [s].
  int count(_ShapeRuns s) {
    var total = 0;
    for (var v = 0; v < s.verticals; v++) {
      final int q = s.vq[v];
      total +=
          _bound(hYs, hStarts[q], hStarts[q + 1], s.vBottom[v], orEqual: false) -
          _bound(hYs, hStarts[q], hStarts[q + 1], s.vTop[v], orEqual: true);
    }
    for (var h = 0; h < s.horizontals; h++) {
      final double y = s.hy[h];
      for (int q = s.hLeft[h] + 1; q < s.hRight[h]; q++) {
        // Verticals with top < y, minus those that also end at or above y.
        total +=
            _bound(vTops, vStarts[q], vStarts[q + 1], y, orEqual: false) -
            _bound(vBottoms, vStarts[q], vStarts[q + 1], y, orEqual: true);
      }
    }
    return total;
  }

  /// The first index in [from, to) of the ascending [list] whose value is ≥ [x] (> [x] with [orEqual]).
  static int _bound(Float64List list, int from, int to, double x, {required bool orEqual}) {
    var lo = from;
    var hi = to;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (orEqual ? list[mid] <= x : list[mid] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

/// The geometry stage's working state: the phases of docs/graph-layout.md §14.3 for one W and H.
final class _GeometryBuilder {
  _GeometryBuilder(this.c, this.m)
    : w = m.width,
      h = m.height,
      gy = m.gapY,
      pitch = m.height + m.gapY,
      colW = m.width + m.gapX,
      lift = _lift * m.gapY,
      n = c.nodeRows.length,
      e = c.edgeFroms.length;

  final RouteClasses c;
  final RouteMetrics m;
  final double w;
  final double h;
  final double gy;
  final double pitch;
  final double colW;
  final double lift;
  final int n;
  final int e;

  late final y = Float64List(n);
  late final cx = Float64List(n);

  /// Per entry of the column CSR its card's top: descending within a column.
  late final tops = Float64List(c.columnNodes.length);

  /// Per edge its current shape: points (2, 4, 6 or 8), first run in [runs], gutter position.
  late final shapePoints = Uint8List(e);
  late final shapeRun = Int32List(e);
  late final shapeGutter = Int32List(e);

  late final runs = _RunBuffer(e + 16);

  /// The detours recorded by the shape phase, in edge order: edge, first run, gutter position.
  final _detourEdges = <int>[];
  final _detourRuns = <int>[];
  final _detourGutters = <int>[];

  /// The two ends of the band [_band] found last.
  double _bandLo = 0;
  double _bandHi = 0;

  /// The runs of the final shapes (a CSR by edge, from the parent's end) and their final levels.
  late final Int32List edgeRun;
  late final Int32List runEdge;
  late final Int32List runDown;
  late final Int32List runUp;
  late final Int32List runLeft;
  late final Int32List runRight;
  late final Float64List runLevel;
  late final Float64List runLo;
  late final Float64List runHi;
  late final Float64List runWish;
  late final Float64List runY;

  var unavoidableCrossings = 0;
  var tightFans = 0;

  /// Scratch of the cluster placement, grown to the largest cluster.
  var _rest = Int32List(16);
  var _order = Int32List(16);
  var _blocked = Int32List(16);
  var _done = Uint8List(16);
  var _share = Float64List(16);
  var _tight = Float64List(16);
  var _levels = Float64List(16);
  var _members = Int32List(16);

  /// Per edge: exit x, entry x, gutter x (with its slot).
  late final xo = Float64List(e);
  late final xi = Float64List(e);
  late final xg = Float64List(e);

  /// Scratch key and lists for the per-node sorts.
  late final key1 = Float64List(e);
  late final scratch = Int32List(e);
  late final sideScratch = Int32List(e);

  /// Per edge at its child's bottom ([reachIn], [towardIn]) and its parent's top ([reachOut], [towardOut]): how far
  /// it runs straight from that card edge to its first bend there (infinite for 2 points), and the x it turns toward;
  /// [tieIn] (the parent's row) orders equal entries, the exits keep their edge order ([tieOut] stays 0).
  late final reachIn = Float64List(e);
  late final towardIn = Float64List(e);
  late final tieIn = Float64List(e);
  late final reachOut = Float64List(e);
  late final towardOut = Float64List(e);
  late final tieOut = Float64List(e);

  /// Per edge at its child's bottom (…In) and its parent's top (…Out), set by [_banCollisions]: 1 where it lost the
  /// centre, and how many fan slots further out it sits, to a line that stays straight longer on its x.
  late final noCentreIn = Uint8List(e);
  late final noCentreOut = Uint8List(e);
  late final extraIn = Uint8List(e);
  late final extraOut = Uint8List(e);

  RouteGeometry build() {
    _positions();
    _shapes();
    _takeDetours();
    _finalRuns();
    _tracks();
    _monotoneLevels();
    _reaches();
    var passes = 0;
    do {
      _entries();
      _exits();
    } while (++passes < _settlePasses && _banCollisions() > 0);
    final int unsettled = passes == _settlePasses ? _banCollisions(apply: false) : 0;
    final (Int32List portStarts, Float64List portXs) = _ports();
    _gutterSlots();
    return _finish(portStarts, portXs, unsettled);
  }

  void _positions() {
    final Int32List rows = c.nodeRows;
    final Int32List cols = c.nodeCols;
    final int maxRow = c.maxRow;
    final int unit = c.unit;
    for (var i = 0; i < n; i++) {
      if (rows[i] < 0) {
        continue;
      }
      y[i] = m.pad + (maxRow - rows[i]) / unit * pitch;
      cx[i] = m.pad + cols[i] * colW + w / 2;
    }
    final Int32List nodes = c.columnNodes;
    for (var q = 0; q < nodes.length; q++) {
      tops[q] = y[nodes[q]];
    }
  }

  /// The first position of column [col] whose `top + offset` is above [limit] (tops descend with the position).
  int _firstAbove(int col, double offset, double limit) {
    int lo = c.columnStarts[col];
    int hi = c.columnStarts[col + 1];
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (tops[mid] + offset < limit) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// The first position of column [col] whose `top + offset` is above or at [limit].
  int _firstAtOrAbove(int col, double offset, double limit) {
    int lo = c.columnStarts[col];
    int hi = c.columnStarts[col + 1];
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (tops[mid] + offset <= limit) {
        hi = mid;
      } else {
        lo = mid + 1;
      }
    }
    return lo;
  }

  /// The first card of column [col] from position [from] upward other than the line's own cards [p] and [ch]: its
  /// position, or −1 when there is none or its bottom edge lies at or above [to] (the line ends before it).
  int _blocker(int col, int from, double to, int p, int ch) {
    final Int32List nodes = c.columnNodes;
    final int end = c.columnStarts[col + 1];
    var q = from;
    while (q < end && (nodes[q] == p || nodes[q] == ch)) {
      q++;
    }
    return q < end && tops[q] + h > to ? q : -1;
  }

  /// The level nearest to [start], between [start] and [end] (either order), at which a run over the columns
  /// [c0] … [c1] keeps [_cardClear] from every card but [p] and [ch]; NaN without one.
  double _freeLevel(int c0, int c1, double start, double end, int p, int ch) {
    final Int32List nodes = c.columnNodes;
    final bool down = end > start;
    var level = start;
    for (var moved = true; moved;) {
      moved = false;
      for (var col = c0; col <= c1; col++) {
        int q = _firstAbove(col, -_cardClear, level);
        final int to = c.columnStarts[col + 1];
        // The same two expressions as the jump below: a level on a card's edge must count as free of it.
        while (q < to && tops[q] + h + _cardClear > level) {
          if (nodes[q] != p && nodes[q] != ch) {
            level = down ? tops[q] + h + _cardClear : tops[q] - _cardClear;
            moved = true;
            break;
          }
          q++;
        }
      }
      if (down ? level > end : level < end) {
        return double.nan;
      }
    }
    return level;
  }

  /// A level for a run over the columns [c0] … [c1] in the room between [upper] and [lower], keeping [_cardClear]
  /// from both: the one nearest to [wish] on its way [up] or down, else the nearest on the other side; NaN without one.
  double _seek(int c0, int c1, double wish, double upper, double lower, int p, int ch, {required bool up}) {
    final double first = upper + _cardClear;
    final double last = lower - _cardClear;
    if (first > last) {
      return double.nan;
    }
    final start = wish < first ? first : (wish > last ? last : wish);
    final double found = _freeLevel(c0, c1, start, up ? first : last, p, ch);
    return found.isNaN ? _freeLevel(c0, c1, start, up ? last : first, p, ch) : found;
  }

  /// The free room around [level] for a run over the columns [c0] … [c1], no further than [lo] and [hi]: from the
  /// nearest card above it to the nearest card below it. Sets [_bandLo] and [_bandHi].
  void _band(int c0, int c1, double level, double lo, double hi, int p, int ch) {
    final Int32List nodes = c.columnNodes;
    var top = lo;
    var bottom = hi;
    for (var col = c0; col <= c1; col++) {
      final int begin = c.columnStarts[col];
      final int end = c.columnStarts[col + 1];
      int q = _firstAtOrAbove(col, h, level);
      while (q < end && (nodes[q] == p || nodes[q] == ch)) {
        q++;
      }
      if (q < end && tops[q] + h > top) {
        top = tops[q] + h;
      }
      q = _firstAbove(col, 0, level) - 1;
      if (q >= begin && tops[q] < bottom) {
        bottom = tops[q];
      }
    }
    _bandLo = top;
    _bandHi = bottom;
  }

  void _addRun(
    int k,
    int down,
    int up,
    double level,
    double lo,
    double hi, {
    required bool merge,
    bool endsAtChild = false,
  }) {
    final double half = (hi - lo) / 2;
    final double near = lift < half ? lift : half;
    double wish = merge ? lo + near : hi - near;
    if (merge && endsAtChild && c.deep[k] != 0) {
      // The lines of a hidden merge share their last stretch: keep it long enough to read as one stem.
      final double limit = (hi < lo + gy ? hi : lo + gy) - _clear;
      final double mid = lo + half;
      wish = mid > limit ? mid : limit;
    }
    runs.add(k, down, up, level, lo, hi, wish);
  }

  /// The run every line through a gutter ends with: from the gutter at [gutter] to the child, right below it. Its
  /// band spans the columns [c0] … [c1] strictly between the gutter and the child, up to the next card under the
  /// child, the parent and [cardBottom] (infinity for none).
  void _belowRun(int k, int p, int ch, int gutter, int c0, int c1, double cardBottom) {
    final int cc = c.nodeCols[ch];
    final int begin = c.columnStarts[cc];
    final double by = y[ch] + h;
    double hi = y[p];
    final int q = c.columnPos[ch] - 1;
    if (q >= begin && tops[q] < hi) {
      hi = tops[q];
    }
    if (cardBottom < hi) {
      hi = cardBottom;
    }
    final double below = by + lift;
    _band(c0, c1, below, by, hi, p, ch);
    _addRun(k, gutter, 2 * cc, below, _bandLo, _bandHi, merge: true, endsAtChild: true);
  }

  /// Phase 2: per edge its shape and levels (docs/graph-layout.md §14.3, Shapes).
  void _shapes() {
    final Int32List froms = c.edgeFroms;
    final Int32List tos = c.edgeTos;
    final Int32List cols = c.nodeCols;
    for (var k = 0; k < e; k++) {
      final int p = froms[k];
      final int ch = tos[k];
      shapeRun[k] = runs.count;
      if (cols[p] == cols[ch]) {
        _sameColumnShape(k, p, ch);
      } else if (c.firstParents[k] != 0) {
        _forkShape(k, p, ch);
      } else {
        _mergeShape(k, p, ch);
      }
    }
  }

  void _sameColumnShape(int k, int p, int ch) {
    final int col = c.nodeCols[p];
    final int card = _blocker(col, c.columnPos[p] + 1, y[ch] + h, p, ch);
    if (card < 0) {
      shapePoints[k] = 2;
      return;
    }
    final double cardBottom = tops[card] + h;
    final int q = 2 * col;
    final int gutter = q + 1;
    shapePoints[k] = 6;
    shapeGutter[k] = gutter;
    _addRun(k, q, gutter, cardBottom + lift, cardBottom, y[p], merge: true);
    _belowRun(k, p, ch, gutter, 1, 0, cardBottom);
  }

  void _forkShape(int k, int p, int ch) {
    final int pc = c.nodeCols[p];
    final int cc = c.nodeCols[ch];
    final int pq = 2 * pc;
    final int cq = 2 * cc;
    final double ay = y[p];
    final double by = y[ch] + h;
    final double above = ay - lift;
    // The run may climb the parent's column up to that column's next card, and no higher than the child.
    final int next = _blocker(pc, c.columnPos[p] + 1, double.negativeInfinity, p, ch);
    final double upper = next < 0 || tops[next] + h < by ? by : tops[next] + h;
    final int c0 = cc > pc ? pc + 1 : cc;
    final int c1 = cc > pc ? cc : pc - 1;
    final double found = _seek(c0, c1, above, upper, ay, p, ch, up: true);
    final level = found.isNaN ? above : found;
    _band(c0, c1, level, upper, ay, p, ch);
    final double lo = _bandLo;
    final double hi = _bandHi;
    final int card = _blocker(cc, _firstAbove(cc, 0, level), by, p, ch);
    if (card < 0) {
      shapePoints[k] = 4;
      _addRun(k, pq, cq, level, lo, hi, merge: false);
      return;
    }
    final double cardBottom = tops[card] + h;
    final int gutter = cq + (pc > cc ? 1 : -1);
    shapeGutter[k] = gutter;
    if (cardBottom + lift > level) {
      shapePoints[k] = 6;
      _addRun(k, pq, gutter, level, lo, hi, merge: false);
    } else {
      shapePoints[k] = 8;
      _addRun(k, pq, cq, level, lo, hi, merge: false);
      _addRun(k, cq, gutter, cardBottom + lift, cardBottom, ay, merge: true);
    }
    _belowRun(k, p, ch, gutter, 1, 0, cardBottom);
  }

  void _mergeShape(int k, int p, int ch) {
    final int pc = c.nodeCols[p];
    final int cc = c.nodeCols[ch];
    final int pq = 2 * pc;
    final int cq = 2 * cc;
    final double ay = y[p];
    final double by = y[ch] + h;
    final double below = by + lift;
    final side = cc > pc ? 1 : -1;
    final int nextUp = c.columnPos[p] + 1;
    final int card = _blocker(pc, nextUp, below, p, ch);
    final int underPos = c.columnPos[ch] - 1;
    final double under = underPos >= c.columnStarts[cc] ? tops[underPos] : double.infinity;
    final double upper = card < 0 ? by : tops[card] + h;
    final lower = under > ay ? ay : under;
    final int c0 = (cc > pc ? pc : cc) + 1;
    final int c1 = (cc > pc ? cc : pc) - 1;
    final goesOn = c.goesOn[p] != 0;
    // Where the parent's branch goes on and the child's column is free down to the parent, every line of the
    // parent's top edge bends at the card, so their tracks and ports follow the order of their children.
    final bool atParent = goesOn && under > ay;
    double level = atParent
        ? _seek(c0, c1, lower - lift, upper, lower, p, ch, up: true)
        : _seek(c0, c1, upper + lift, upper, lower, p, ch, up: false);
    // Above `below` the line climbs further up the parent's column than `card` was looked for.
    if (!level.isNaN && level < below && _blocker(pc, nextUp, level, p, ch) >= 0) {
      level = double.nan;
    }
    if (!level.isNaN) {
      _band(c0, c1, level, upper, lower, p, ch);
      shapePoints[k] = 4;
      _addRun(k, pq, cq, level, _bandLo, _bandHi, merge: !atParent, endsAtChild: true);
    } else if (card < 0) {
      _band(c0, c1, below, by, lower, p, ch);
      shapePoints[k] = 4;
      _addRun(k, pq, cq, below, _bandLo, _bandHi, merge: true, endsAtChild: true);
    } else {
      final double cardBottom = tops[card] + h;
      final int gutter = pq + side;
      shapePoints[k] = 6;
      shapeGutter[k] = gutter;
      _addRun(k, pq, gutter, cardBottom + lift, cardBottom, ay, merge: true);
      _belowRun(k, p, ch, gutter, c0, c1, cardBottom);
    }
    // Where the child's column is taken, the line can bend at the parent all the same and climb the gutter next to
    // the child's column. Whether it does is decided in phase 3, once every line has its usual shape.
    if (goesOn && !atParent) {
      final double at = _seek(c0, c1, ay - lift, upper, ay, p, ch, up: true);
      // Between two neighbouring rows the detour would be a zigzag.
      if (!at.isNaN && at - below >= h + gy) {
        _band(c0, c1, at, upper, ay, p, ch);
        final double floor = below + _cardClear;
        final double lo = _bandLo > floor ? _bandLo : floor;
        final int gutter = cq - side;
        _detourEdges.add(k);
        _detourRuns.add(runs.count);
        _detourGutters.add(gutter);
        _addRun(k, pq, gutter, at, lo, _bandHi, merge: false);
        _belowRun(k, p, ch, gutter, 1, 0, double.infinity);
      }
    }
  }

  /// The stretches of the shape ([points], first run [run], gutter position [gutter]) of edge [k], into [out].
  void shapeRuns(int k, int points, int run, int gutter, _ShapeRuns out) {
    final int p = c.edgeFroms[k];
    final int ch = c.edgeTos[k];
    final int q0 = 2 * c.nodeCols[p];
    final int q1 = 2 * c.nodeCols[ch];
    final double ay = y[p];
    final double by = y[ch] + h;
    final Float64List levels = runs.level;
    out.clear();
    switch (points) {
      case 2:
        out.vertical(q0, by, ay);
      case 4:
        final double l = levels[run];
        out
          ..vertical(q0, l, ay)
          ..horizontal(l, q0, q1)
          ..vertical(q1, by, l);
      case 6:
        final double t = levels[run];
        final double b = levels[run + 1];
        out
          ..vertical(q0, t, ay)
          ..horizontal(t, q0, gutter)
          ..vertical(gutter, b, t)
          ..horizontal(b, gutter, q1)
          ..vertical(q1, by, b);
      default:
        final double l = levels[run];
        final double t = levels[run + 1];
        final double b = levels[run + 2];
        out
          ..vertical(q0, l, ay)
          ..horizontal(l, q0, q1)
          ..vertical(q1, t, l)
          ..horizontal(t, q1, gutter)
          ..vertical(gutter, b, t)
          ..horizontal(b, gutter, q1)
          ..vertical(q1, by, b);
    }
  }

  /// Phase 3: a detour is taken if the line then crosses fewer lines; on a tie the line keeps its usual shape, which
  /// has two bends less. Then for the column order, whatever it crosses.
  void _takeDetours() {
    final int detours = _detourEdges.length;
    if (detours == 0) {
      return;
    }
    final index = _CrossingIndex(this);
    final firstPoints = Uint8List(detours);
    final firstRuns = Int32List(detours);
    final firstGutters = Int32List(detours);
    for (var d = 0; d < detours; d++) {
      final int k = _detourEdges[d];
      firstPoints[d] = shapePoints[k];
      firstRuns[d] = shapeRun[k];
      firstGutters[d] = shapeGutter[k];
    }
    final taken = <int>[];
    final shape = _ShapeRuns();
    final other = _ShapeRuns();
    // Crossings of [shape] with every other line, in the first shapes plus the detours taken so far.
    int crossings(int d) {
      final int k = _detourEdges[d];
      int total = index.count(shape);
      shapeRuns(k, firstPoints[d], firstRuns[d], firstGutters[d], other);
      total -= shape.crossings(other);
      for (final t in taken) {
        final int edge = _detourEdges[t];
        shapeRuns(edge, 6, _detourRuns[t], _detourGutters[t], other);
        total += shape.crossings(other);
        shapeRuns(edge, firstPoints[t], firstRuns[t], firstGutters[t], other);
        total -= shape.crossings(other);
      }
      return total;
    }

    void take(int d) {
      final int k = _detourEdges[d];
      shapePoints[k] = 6;
      shapeRun[k] = _detourRuns[d];
      shapeGutter[k] = _detourGutters[d];
    }

    final open = <int>[];
    for (var d = 0; d < detours; d++) {
      final int k = _detourEdges[d];
      shapeRuns(k, 6, _detourRuns[d], _detourGutters[d], shape);
      final int withDetour = crossings(d);
      shapeRuns(k, firstPoints[d], firstRuns[d], firstGutters[d], shape);
      if (withDetour < crossings(d)) {
        take(d);
        taken.add(d);
      } else {
        open.add(d);
      }
    }

    // The ports of a card edge follow how far each line runs straight: the longest innermost. So a line is out of
    // column order if a line of its card to the same side goes to a nearer column but turns nearer to the card.
    double firstBend(int k) => shapePoints[k] == 2 ? y[c.edgeTos[k]] + h : runs.level[shapeRun[k]];
    bool outOfOrder(int k) {
      final int p = c.edgeFroms[k];
      final int pc = c.nodeCols[p];
      final int far = c.nodeCols[c.edgeTos[k]] - pc;
      for (int q = c._outStarts[p]; q < c._outStarts[p + 1]; q++) {
        final int j = c._outEdges[q];
        final int near = c.nodeCols[c.edgeTos[j]] - pc;
        if (near.sign == far.sign && near.abs() < far.abs() && firstBend(j) > firstBend(k)) {
          return true;
        }
      }
      return false;
    }

    // Taking a detour changes where its line turns, so the pass repeats until nothing moves.
    for (var moved = true; moved;) {
      moved = false;
      for (var o = 0; o < open.length; o++) {
        final int d = open[o];
        if (d >= 0 && outOfOrder(_detourEdges[d])) {
          take(d);
          open[o] = -1;
          moved = true;
        }
      }
    }
  }

  /// The runs of the final shapes, in edge order, as flat arrays.
  void _finalRuns() {
    edgeRun = Int32List(e + 1);
    for (var k = 0; k < e; k++) {
      edgeRun[k + 1] = edgeRun[k] + (shapePoints[k] >> 1) - 1;
    }
    final int count = edgeRun[e];
    runEdge = Int32List(count);
    runDown = Int32List(count);
    runUp = Int32List(count);
    runLeft = Int32List(count);
    runRight = Int32List(count);
    runLevel = Float64List(count);
    runLo = Float64List(count);
    runHi = Float64List(count);
    runWish = Float64List(count);
    runY = Float64List(count);
    for (var k = 0; k < e; k++) {
      int from = shapeRun[k];
      for (int r = edgeRun[k]; r < edgeRun[k + 1]; r++, from++) {
        runEdge[r] = k;
        final int down = runs.down[from];
        final int up = runs.up[from];
        runDown[r] = down;
        runUp[r] = up;
        runLeft[r] = down < up ? down : up;
        runRight[r] = down < up ? up : down;
        runLevel[r] = runs.level[from];
        runLo[r] = runs.lo[from];
        runHi[r] = runs.hi[from];
        runWish[r] = runs.wish[from];
        runY[r] = runs.level[from];
      }
    }
  }

  /// Phase 4: the runs that pass side by side through each other's band form clusters; each cluster takes the order
  /// in which it does not cross and shares its room.
  void _tracks() {
    final int count = runEdge.length;
    if (count == 0) {
      return;
    }
    final root = Int32List(count);
    final order = Int32List(count);
    for (var r = 0; r < count; r++) {
      root[r] = r;
      order[r] = r;
    }
    int find(int r) {
      var x = r;
      while (root[x] != x) {
        x = root[x];
      }
      final top = x;
      x = r;
      while (root[x] != top) {
        final int next = root[x];
        root[x] = top;
        x = next;
      }
      return top;
    }

    sortIndicesStableByDouble(order, runLo);
    var active = Int32List(16);
    var live = 0;
    for (var o = 0; o < count; o++) {
      final int s = order[o];
      final double top = runLo[s];
      final double level = runLevel[s];
      final int left = runLeft[s];
      final int right = runRight[s];
      var kept = 0;
      for (var t = 0; t < live; t++) {
        final int other = active[t];
        if (runHi[other] <= top) {
          continue;
        }
        active[kept++] = other;
        if (left < runRight[other] &&
            runLeft[other] < right &&
            ((runLo[other] < level && level < runHi[other]) || (top < runLevel[other] && runLevel[other] < runHi[s]))) {
          final int rs = find(s);
          final int ro = find(other);
          if (rs != ro) {
            root[rs] = ro;
          }
        }
      }
      live = kept;
      if (live == active.length) {
        active = Int32List(2 * live)..setAll(0, active);
      }
      active[live++] = s;
    }
    // Members per cluster, ascending (a CSR over the roots): by edge, then from the parent's end.
    final starts = Int32List(count + 1);
    final rootOf = Int32List(count);
    for (var r = 0; r < count; r++) {
      rootOf[r] = find(r);
      starts[rootOf[r] + 1]++;
    }
    for (var r = 0; r < count; r++) {
      starts[r + 1] += starts[r];
    }
    final members = Int32List(count);
    final fill = Int32List.fromList(starts);
    for (var r = 0; r < count; r++) {
      members[fill[rootOf[r]]++] = r;
    }
    for (var r = 0; r < count; r++) {
      if (starts[r + 1] > starts[r]) {
        _placeCluster(members, starts[r], starts[r + 1]);
      }
    }
  }

  void _ensureScratch(int size) {
    if (_rest.length >= size) {
      return;
    }
    final int grown = 2 * size;
    _rest = Int32List(grown);
    _order = Int32List(grown);
    _blocked = Int32List(grown);
    _done = Uint8List(grown);
    _share = Float64List(grown);
    _tight = Float64List(grown);
    _levels = Float64List(grown);
    _members = Int32List(grown);
  }

  /// Run [a] must lie above run [b]: else the two cross (a line goes down at its parent's end and up at its child's).
  bool _above(int a, int b) {
    if (runEdge[a] == runEdge[b]) {
      return a > b; // Two runs of one line: the one nearer to the child.
    }
    final int upA = runUp[a];
    final int downB = runDown[b];
    return (runLeft[a] < downB && downB < runRight[a]) ||
        (runLeft[b] < upA && upA < runRight[b]) ||
        // A run that enters a column where another leaves it: else the two share a stretch of that column. Gutters
        // are separated by slots, not by levels.
        (upA == downB && upA.isEven);
  }

  /// Two runs keep a distance only where they pass side by side through bands that overlap.
  bool _meet(int a, int b) =>
      runLeft[a] < runRight[b] && runLeft[b] < runRight[a] && runLo[a] < runHi[b] && runLo[b] < runHi[a];

  /// Two runs that leave one card, or reach one card, in one direction.
  bool _siblings(int a, int b) =>
      (runUp[a] > runDown[a]) == (runUp[b] > runDown[b]) &&
      (c.edgeFroms[runEdge[a]] == c.edgeFroms[runEdge[b]] || c.edgeTos[runEdge[a]] == c.edgeTos[runEdge[b]]);

  /// Orders and places one cluster ([members] `from ..< to`, ascending by edge and run order): the lab's `spread`.
  ///
  /// shortcut: compares every pair of the cluster, O(size²); the measured clusters are small (≤ 17 on synth-100k), and
  /// [routeSyncNodeLimit] counts on that. Index the runs by level and x if a real layout shows clusters of thousands.
  void _placeCluster(Int32List members, int from, int to) {
    final int size = to - from;
    _ensureScratch(size);
    final Int32List rest = _rest;
    final Int32List order = _order;
    final Int32List blocked = _blocked;
    final Uint8List done = _done;
    final Float64List share = _share;
    final Float64List tight = _tight;
    final Float64List levels = _levels;
    final Int32List fan = _members;
    for (var i = 0; i < size; i++) {
      rest[i] = members[from + i];
      blocked[i] = 0;
      done[i] = 0;
    }
    if (size > 1) {
      // Stable, so runs of equal wish stay by edge and run order.
      sortIndicesStableByDouble(Int32List.sublistView(rest, 0, size), runWish);
    }
    for (var i = 0; i < size; i++) {
      for (int j = i + 1; j < size; j++) {
        final bool ij = _above(rest[i], rest[j]);
        final bool ji = _above(rest[j], rest[i]);
        if (ij && ji) {
          unavoidableCrossings++;
        } else if (ij) {
          blocked[j]++;
        } else if (ji) {
          blocked[i]++;
        }
      }
    }
    // Always the first run that no other remaining run must lie above; in a cycle the run that wants to sit highest.
    for (var step = 0; step < size; step++) {
      var pick = -1;
      var fallback = -1;
      for (var i = 0; i < size; i++) {
        if (done[i] != 0) {
          continue;
        }
        if (fallback < 0) {
          fallback = i;
        }
        if (blocked[i] == 0) {
          pick = i;
          break;
        }
      }
      if (pick < 0) {
        pick = fallback;
      }
      done[pick] = 1;
      final int run = rest[pick];
      order[step] = run;
      for (var j = 0; j < size; j++) {
        if (done[j] == 0 && _above(run, rest[j]) && !_above(rest[j], run)) {
          blocked[j]--;
        }
      }
    }

    // A run's even share of its band: the band over the runs it meets, plus one. At most `lift`.
    for (var k = 0; k < size; k++) {
      final int a = order[k];
      var others = 0;
      for (var j = 0; j < size; j++) {
        if (j != k && _meet(a, order[j]) && !_siblings(a, order[j])) {
          others++;
        }
      }
      final double even = (runHi[a] - runLo[a]) / (others + 2);
      share[k] = even < lift ? even : lift;
      tight[k] = _track;
    }
    // A fan with more lines than its room holds at 6 px shares that room evenly instead of lying on one level. The
    // room of a line and the lines of its fan above it ends at the lowest of their band tops.
    for (var k = 0; k < size; k++) {
      final int run = order[k];
      var count = 0;
      for (var j = 0; j < k; j++) {
        if (_siblings(order[j], run) && _meet(order[j], run)) {
          fan[count++] = j;
        }
      }
      fan[count++] = k;
      double top = runLo[run];
      for (var i = 0; i < count; i++) {
        final double lo = runLo[order[fan[i]]];
        top = lo > top ? lo : top;
      }
      final double room = runHi[run] - top - 2;
      if (room > 0 && (count - 1) * _track + share[k] > room) {
        final double fair = room / count;
        for (var i = 0; i < count; i++) {
          final int j = fan[i];
          tight[j] = fair < tight[j] ? fair : tight[j];
        }
      }
    }
    for (var k = 0; k < size; k++) {
      share[k] = tight[k] < share[k] ? tight[k] : share[k];
      if (tight[k] < 2) {
        var counted = false;
        for (var j = 0; j < k && !counted; j++) {
          counted = tight[j] < 2 && _siblings(order[j], order[k]);
        }
        if (!counted) {
          tightFans++;
        }
      }
    }

    // Every run sits where it wants to, unless the order pushes it: first down, then back up.
    for (var k = 0; k < size; k++) {
      final int run = order[k];
      final double floor = runLo[run] + share[k];
      double yy = runWish[run] > floor ? runWish[run] : floor;
      for (var j = 0; j < k; j++) {
        if (_meet(order[j], run)) {
          final double pushed = levels[j] + _sep(order, j, k);
          if (pushed > yy) {
            yy = pushed;
          }
        }
      }
      levels[k] = yy;
    }
    for (int k = size - 1; k >= 0; k--) {
      final int run = order[k];
      final double ceiling = runHi[run] - share[k];
      double yy = levels[k] < ceiling ? levels[k] : ceiling;
      for (int j = k + 1; j < size; j++) {
        if (_meet(run, order[j])) {
          final double pushed = levels[j] - _sep(order, k, j);
          if (pushed < yy) {
            yy = pushed;
          }
        }
      }
      // Whatever the pushes did, a run never leaves its band: there it passes no card.
      if (runHi[run] - runLo[run] > 4) {
        yy = yy < runLo[run] + 2 ? runLo[run] + 2 : (yy > runHi[run] - 2 ? runHi[run] - 2 : yy);
      }
      levels[k] = yy;
      runY[run] = yy;
    }
  }

  double _sep(Int32List order, int j, int k) {
    if (_siblings(order[j], order[k])) {
      return _tight[j] < _tight[k] ? _tight[j] : _tight[k];
    }
    return _share[j] < _share[k] ? _share[j] : _share[k];
  }

  /// Phase 5: each line climbs without retracing, whatever pushes did.
  void _monotoneLevels() {
    for (var k = 0; k < e; k++) {
      final int from = edgeRun[k];
      final int to = edgeRun[k + 1];
      double previous = y[c.edgeFroms[k]];
      for (var r = from; r < to; r++) {
        if (runY[r] > previous) {
          runY[r] = previous;
        }
        previous = runY[r];
      }
      double next = y[c.edgeTos[k]] + h;
      for (int r = to - 1; r >= from; r--) {
        if (runY[r] < next) {
          runY[r] = next;
        }
        next = runY[r];
      }
    }
  }

  /// m ports inner → outer: [step] apart while they fit, squeezed to [min], then the overflow shares the outermost
  /// port. Port [k] of [count].
  static double _fan(int count, double first, double step, double min, double max, int k) {
    if (count <= 1) {
      return first;
    }
    final double span = _max(0, max - first);
    final double st = _min(step, span / (count - 1));
    if (st >= min) {
      return first + k * st;
    }
    final int own = (span / min).floor();
    return first + (k < own ? k : own) * min;
  }

  /// Port [k] of [count] on one side of a card edge, top or bottom.
  double _portFan(int count, int k) => _fan(count, _entryFirst, _entryStep, _entryMin, w / 2 - _entryInset, k);

  /// Each line's reach and turning side at both card edges, from the final levels (phase 6).
  void _reaches() {
    final Int32List froms = c.edgeFroms;
    final Int32List tos = c.edgeTos;
    final double centre = m.pad + w / 2;
    for (var k = 0; k < e; k++) {
      final int p = froms[k];
      final int ch = tos[k];
      final int from = edgeRun[k];
      final int to = edgeRun[k + 1];
      if (shapePoints[k] >= 6) {
        xg[k] = centre + shapeGutter[k] * colW / 2;
      }
      if (from == to) {
        reachIn[k] = reachOut[k] = double.infinity;
      } else {
        reachOut[k] = y[p] - runY[from];
        reachIn[k] = runY[to - 1] - (y[ch] + h);
      }
      towardIn[k] = shapePoints[k] >= 6 ? xg[k] : cx[p];
      tieIn[k] = c.nodeRows[p].toDouble();
    }
  }

  /// The port rules at one card edge with centre [mid]: the lines are `scratch[from ..< from + count]` with their
  /// [reach] and [toward]; [tie] breaks ties; a line [banned] from the centre never takes it, a line with [extra]
  /// slots sits that many fan slots further out ([_banCollisions]). A line is vertical at the edge when it runs
  /// straight through the band next to it (reach ≥ gapY), else it turns there. One line takes the centre; of several,
  /// the vertical one that stays straight longest does, with none vertical the centre stays free. The rest fan to the
  /// side they turn to: vertical lines innermost (longest first), then the lines that turn at the edge, nearest turn
  /// first.
  void _place(
    int from,
    int count,
    double mid,
    Float64List out,
    Float64List reach,
    Float64List toward,
    Float64List tie,
    Uint8List banned,
    Uint8List extra,
  ) {
    var centre = -1;
    for (var q = from; q < from + count; q++) {
      final int k = scratch[q];
      if (banned[k] == 0 && (count == 1 || reach[k] >= gy && (centre < 0 || reach[k] > reach[centre]))) {
        centre = k;
      }
    }
    if (centre >= 0) {
      out[centre] = mid;
    }
    for (var s = -1; s <= 1; s += 2) {
      var sideCount = 0;
      var slotCount = 0;
      for (var q = from; q < from + count; q++) {
        final int k = scratch[q];
        if (k == centre || (toward[k] < mid ? -1 : 1) != s) {
          continue;
        }
        key1[k] = reach[k] >= gy ? -reach[k] : (toward[k] - mid).abs();
        sideScratch[from + sideCount++] = k;
        slotCount += 1 + extra[k];
      }
      if (sideCount == 0) {
        continue;
      }
      final list = Int32List.sublistView(sideScratch, from, from + sideCount);
      sortIndicesStableByDouble(list, key1, second: tie);
      var slot = 0;
      for (var q = 0; q < sideCount; q++) {
        slot += extra[list[q]];
        out[list[q]] = mid + s * _portFan(slotCount, slot++);
      }
    }
  }

  /// Entries on each child's bottom edge ([_place]'s rules). The lines are the slot owners; the other lines of a
  /// shared slot take its owner's x.
  void _entries() {
    final Int32List inStarts = c._inStarts;
    final Int32List inEdges = c._inEdges;
    final Int32List slots = c.slots;
    for (var node = 0; node < n; node++) {
      final int from = inStarts[node];
      final int to = inStarts[node + 1];
      var count = 0;
      for (var q = from; q < to; q++) {
        final int k = inEdges[q];
        if (slots[k] == k) {
          scratch[from + count++] = k;
        }
      }
      _place(from, count, cx[node], xi, reachIn, towardIn, tieIn, noCentreIn, extraIn);
      for (var q = from; q < to; q++) {
        final int k = inEdges[q];
        xi[k] = xi[slots[k]];
      }
    }
  }

  /// Exits on each parent's top edge ([_place]'s rules, as the entries').
  void _exits() {
    final Int32List outStarts = c._outStarts;
    final Int32List outEdges = c._outEdges;
    for (var node = 0; node < n; node++) {
      final int from = outStarts[node];
      final int to = outStarts[node + 1];
      for (var q = from; q < to; q++) {
        final int k = outEdges[q];
        // Its third point: the gutter, the child's column on an 8-point line, else its entry.
        towardOut[k] = shapePoints[k] == 6 ? xg[k] : (shapePoints[k] == 8 ? cx[c.edgeTos[k]] : xi[k]);
        scratch[q] = k;
      }
      _place(from, to - from, cx[node], xo, reachOut, towardOut, tieOut, noCentreOut, extraOut);
    }
  }

  /// Two lines of different card edges never share an upright stretch at their card edges: where the stretches (from
  /// the card edge to the line's first bend, exactly) of two lines overlap on one x, the one that stays straight
  /// longer keeps its port (tie: the lower edge index); the other leaves the centre, or sits one fan slot further out.
  /// Every line of a shared slot claims its own stretch and a loss moves the slot's owner, so the slot moves as one;
  /// a slot with a 2-point line claims nothing at its entry, because that line's x is the slot's port. Bans and extra
  /// slots only accumulate across passes, never reset, so the passes terminate. Returns how many lines moved (the
  /// ports are then placed again); with [apply] false it only counts the collisions and moves nothing.
  int _banCollisions({bool apply = true}) {
    final Int32List froms = c.edgeFroms;
    final Int32List tos = c.edgeTos;
    final slotStraight = Uint8List(e);
    for (var k = 0; k < e; k++) {
      if (shapePoints[k] == 2) {
        slotStraight[c.slots[k]] = 1;
      }
    }
    final claimEdge = Int32List(2 * e);
    final claimIn = Uint8List(2 * e);
    final at = Float64List(2 * e);
    final lo = Float64List(2 * e);
    final hi = Float64List(2 * e);
    final len = Float64List(2 * e);
    var count = 0;
    for (var k = 0; k < e; k++) {
      final double top = y[froms[k]];
      final double bottom = y[tos[k]] + h;
      final straight = shapePoints[k] == 2;
      claimEdge[count] = k;
      at[count] = xo[k];
      lo[count] = straight ? bottom : top - reachOut[k];
      hi[count] = top;
      len[count++] = reachOut[k];
      if (!straight && slotStraight[c.slots[k]] == 0) {
        claimEdge[count] = c.slots[k];
        claimIn[count] = 1;
        at[count] = xi[k];
        lo[count] = bottom;
        hi[count] = bottom + reachIn[k];
        len[count++] = reachIn[k];
      }
    }
    final order = Int32List(count);
    for (var q = 0; q < count; q++) {
      order[q] = q;
    }
    sortIndicesStableByDouble(order, at, second: lo);
    final movedIn = Uint8List(e);
    final movedOut = Uint8List(e);
    var moved = 0;
    for (var i = 0; i < count; i++) {
      final int a = order[i];
      for (int j = i + 1; j < count && at[order[j]] == at[a] && lo[order[j]] < hi[a]; j++) {
        final int b = order[j];
        final int ka = claimEdge[a];
        final int kb = claimEdge[b];
        final bool sameEdge =
            claimIn[a] == claimIn[b] && (claimIn[a] == 1 ? tos : froms)[ka] == (claimIn[a] == 1 ? tos : froms)[kb];
        if (ka == kb ||
            sameEdge || // one card edge's own lines (a shared outermost port)
            (claimIn[a] == 1 ? movedIn : movedOut)[ka] != 0 ||
            (claimIn[b] == 1 ? movedIn : movedOut)[kb] != 0) {
          continue; // a line that moves this pass is checked again on the next
        }
        final loser = len[a] < len[b] || len[a] == len[b] && ka > kb ? a : b;
        final int k = claimEdge[loser];
        final entry = claimIn[loser] == 1;
        if (apply) {
          if (at[loser] == cx[entry ? tos[k] : froms[k]]) {
            (entry ? noCentreIn : noCentreOut)[k] = 1;
          } else {
            (entry ? extraIn : extraOut)[k]++;
          }
        }
        (entry ? movedIn : movedOut)[k] = 1;
        moved++;
      }
    }
    return moved;
  }

  /// The distinct entry ports per child, in entry order.
  (Int32List, Float64List) _ports() {
    final Int32List inStarts = c._inStarts;
    final Int32List inEdges = c._inEdges;
    final portStarts = Int32List(n + 1);
    final ports = Float64List(e);
    var portCount = 0;
    for (var node = 0; node < n; node++) {
      portStarts[node] = portCount;
      for (int q = inStarts[node]; q < inStarts[node + 1]; q++) {
        final double port = xi[inEdges[q]];
        var seen = false;
        for (int p = portStarts[node]; p < portCount; p++) {
          if (ports[p] == port) {
            seen = true;
            break;
          }
        }
        if (!seen) {
          ports[portCount++] = port;
        }
      }
    }
    portStarts[n] = portCount;
    return (portStarts, Float64List.fromList(Float64List.sublistView(ports, 0, portCount)));
  }

  /// Phase 7: lines that share a gutter over one stretch sit 6 px apart. After the tracks, so the intervals are the
  /// final ones; sorted by top, only the last interval of a slot can overlap.
  void _gutterSlots() {
    var count = 0;
    for (var k = 0; k < e; k++) {
      if (shapePoints[k] >= 6) {
        count++;
      }
    }
    if (count == 0) {
      return;
    }
    final list = Int32List(count);
    final gutter = Float64List(e);
    final top = Float64List(e);
    final bottom = Float64List(e);
    var q = 0;
    for (var k = 0; k < e; k++) {
      if (shapePoints[k] >= 6) {
        list[q++] = k;
        final int last = edgeRun[k + 1] - 1;
        gutter[k] = shapeGutter[k].toDouble();
        top[k] = runY[last];
        bottom[k] = runY[last - 1];
      }
    }
    sortIndicesStableByDouble(list, gutter, second: top);
    var slotBottoms = Float64List(16);
    var slots = 0;
    var current = -1;
    for (var o = 0; o < count; o++) {
      final int k = list[o];
      if (shapeGutter[k] != current) {
        current = shapeGutter[k];
        slots = 0;
      }
      var slot = 0;
      while (slot < slots && top[k] < slotBottoms[slot]) {
        slot++;
      }
      if (slot == slots) {
        if (slots == slotBottoms.length) {
          slotBottoms = Float64List(2 * slots)..setAll(0, slotBottoms);
        }
        slots++;
      }
      slotBottoms[slot] = bottom[k];
      xg[k] += (slot.isOdd ? _track : -_track) * ((slot + 1) ~/ 2);
    }
  }

  RouteGeometry _finish(Int32List portStarts, Float64List portXs, int unsettledPorts) {
    final pointStarts = Int32List(e + 1);
    for (var k = 0; k < e; k++) {
      pointStarts[k + 1] = pointStarts[k] + shapePoints[k];
    }
    final points = Float64List(2 * pointStarts[e]);
    var q = 0;
    void put(double px, double py) {
      points[q++] = px;
      points[q++] = py;
    }

    for (var k = 0; k < e; k++) {
      final double top = y[c.edgeFroms[k]];
      final double bot = y[c.edgeTos[k]] + h;
      final int count = shapePoints[k];
      put(xo[k], top);
      if (count == 2) {
        put(xo[k], bot);
        continue;
      }
      final int r = edgeRun[k];
      put(xo[k], runY[r]);
      if (count == 4) {
        put(xi[k], runY[r]);
        put(xi[k], bot);
        continue;
      }
      var g = r;
      if (count == 8) {
        final double bx = cx[c.edgeTos[k]];
        put(bx, runY[r]);
        put(bx, runY[r + 1]);
        g = r + 1;
      }
      put(xg[k], runY[g]);
      put(xg[k], runY[g + 1]);
      put(xi[k], runY[g + 1]);
      put(xi[k], bot);
    }
    return _runIndexes(pointStarts, points, portStarts, portXs, unsettledPorts);
  }

  RouteGeometry _runIndexes(
    Int32List pointStarts,
    Float64List points,
    Int32List portStarts,
    Float64List portXs,
    int unsettledPorts,
  ) {
    var verticals = 0;
    var horizontals = 0;
    for (var k = 0; k < e; k++) {
      for (int q = pointStarts[k] + 1; q < pointStarts[k + 1]; q++) {
        final double x1 = points[2 * q - 2];
        final double y1 = points[2 * q - 1];
        final double x2 = points[2 * q];
        final double y2 = points[2 * q + 1];
        if (x1 == x2 && y1 == y2) {
          continue;
        }
        if (y1 == y2) {
          horizontals++;
        } else {
          verticals++;
        }
      }
    }
    final vx = Float64List(verticals);
    final vTop = Float64List(verticals);
    final vBottom = Float64List(verticals);
    final vEdge = Int32List(verticals);
    final hy = Float64List(horizontals);
    final hLeft = Float64List(horizontals);
    final hRight = Float64List(horizontals);
    final hEdge = Int32List(horizontals);
    var nv = 0;
    var nh = 0;
    for (var k = 0; k < e; k++) {
      for (int q = pointStarts[k] + 1; q < pointStarts[k + 1]; q++) {
        final double x1 = points[2 * q - 2];
        final double y1 = points[2 * q - 1];
        final double x2 = points[2 * q];
        final double y2 = points[2 * q + 1];
        if (x1 == x2 && y1 == y2) {
          continue;
        }
        if (y1 == y2) {
          hy[nh] = y1;
          hLeft[nh] = _min(x1, x2);
          hRight[nh] = _max(x1, x2);
          hEdge[nh++] = k;
        } else {
          vx[nv] = x1;
          vTop[nv] = _min(y1, y2);
          vBottom[nv] = _max(y1, y2);
          vEdge[nv++] = k;
        }
      }
    }
    final vOrder = Int32List(verticals);
    for (var q = 0; q < verticals; q++) {
      vOrder[q] = q;
    }
    sortIndicesStableByDouble(vOrder, vx);
    final hOrder = Int32List(horizontals);
    for (var q = 0; q < horizontals; q++) {
      hOrder[q] = q;
    }
    sortIndicesStableByDouble(hOrder, hy);
    Float64List byOrder(Float64List values, Int32List order) {
      final out = Float64List(order.length);
      for (var q = 0; q < order.length; q++) {
        out[q] = values[order[q]];
      }
      return out;
    }

    Int32List edgesByOrder(Int32List values, Int32List order) {
      final out = Int32List(order.length);
      for (var q = 0; q < order.length; q++) {
        out[q] = values[order[q]];
      }
      return out;
    }

    final Float64List verticalXs = byOrder(vx, vOrder);
    final Float64List verticalTops = byOrder(vTop, vOrder);
    final Float64List verticalBottoms = byOrder(vBottom, vOrder);
    final Int32List verticalEdges = edgesByOrder(vEdge, vOrder);
    final Float64List horizontalYs = byOrder(hy, hOrder);
    final Float64List horizontalLefts = byOrder(hLeft, hOrder);
    final Float64List horizontalRights = byOrder(hRight, hOrder);
    final Int32List horizontalEdges = edgesByOrder(hEdge, hOrder);

    final behindEdges = Uint8List(e);
    final int behindCards = _behind(pointStarts, points, behindEdges);
    final sharedEdges = Uint8List(e);
    final int sharedStretches =
        _shared(verticalXs, verticalTops, verticalBottoms, verticalEdges, sharedEdges) +
        _shared(horizontalYs, horizontalLefts, horizontalRights, horizontalEdges, sharedEdges);

    return RouteGeometry._(
      classes: c,
      metrics: m,
      pointStarts: pointStarts,
      points: points,
      portStarts: portStarts,
      portXs: portXs,
      verticalXs: verticalXs,
      verticalTops: verticalTops,
      verticalBottoms: verticalBottoms,
      verticalEdges: verticalEdges,
      horizontalYs: horizontalYs,
      horizontalLefts: horizontalLefts,
      horizontalRights: horizontalRights,
      horizontalEdges: horizontalEdges,
      behindCards: behindCards,
      behindEdges: behindEdges,
      sharedStretches: sharedStretches,
      sharedEdges: sharedEdges,
      tightFans: tightFans,
      unavoidableCrossings: unavoidableCrossings,
      unsettledPorts: unsettledPorts,
    );
  }

  /// Flags the lines that still pass behind a card and returns how many there are.
  int _behind(Int32List pointStarts, Float64List points, Uint8List flags) {
    var count = 0;
    for (var k = 0; k < e; k++) {
      final int p = c.edgeFroms[k];
      final int ch = c.edgeTos[k];
      var hit = false;
      for (int q = pointStarts[k] + 1; q < pointStarts[k + 1] && !hit; q++) {
        final double x1 = points[2 * q - 2];
        final double y1 = points[2 * q - 1];
        final double x2 = points[2 * q];
        final double y2 = points[2 * q + 1];
        if (y1 != y2) {
          hit = x1 == x2 && _verticalBehind(x1, _min(y1, y2), _max(y1, y2), p, ch);
        } else if (x1 != x2) {
          hit = _horizontalBehind(y1, _min(x1, x2), _max(x1, x2), p, ch);
        }
      }
      if (hit) {
        flags[k] = 1;
        count++;
      }
    }
    return count;
  }

  static const _inset = 0.5;

  bool _verticalBehind(double x, double top, double bottom, int p, int ch) {
    final int col = ((x - m.pad) / colW).floor();
    if (col < 0 || col >= c.columns) {
      return false;
    }
    final double left = m.pad + col * colW;
    if (x <= left + _inset || x >= left + w - _inset) {
      return false;
    }
    final Int32List nodes = c.columnNodes;
    final int end = c.columnStarts[col + 1];
    for (int q = _firstAbove(col, 0, bottom - _inset); q < end && tops[q] + h - _inset > top; q++) {
      if (nodes[q] != p && nodes[q] != ch) {
        return true;
      }
    }
    return false;
  }

  bool _horizontalBehind(double level, double left, double right, int p, int ch) {
    final int first = ((left - m.pad - w) / colW).floor();
    final int last = ((right - m.pad) / colW).ceil();
    final Int32List nodes = c.columnNodes;
    for (var col = first < 0 ? 0 : first; col <= last && col < c.columns; col++) {
      final double cardLeft = m.pad + col * colW;
      if (left >= cardLeft + w - _inset || right <= cardLeft + _inset) {
        continue;
      }
      final int end = c.columnStarts[col + 1];
      for (int q = _firstAbove(col, 0, level - _inset); q < end && tops[q] + h - _inset > level; q++) {
        if (nodes[q] != p && nodes[q] != ch) {
          return true;
        }
      }
    }
    return false;
  }

  /// Two lines are exempt from the report when they share a slot or one port of one card edge.
  bool _sharesPort(int a, int b) =>
      c.slots[a] == c.slots[b] ||
      (c.edgeFroms[a] == c.edgeFroms[b] && xo[a] == xo[b]) ||
      (c.edgeTos[a] == c.edgeTos[b] && xi[a] == xi[b]);

  /// Counts the runs (sorted by [at]) of two lines that overlap by more than 1 px on one [at], and flags those lines.
  /// Within one [at] the runs are ordered by their start, so a run meets only the following runs that start before it
  /// ends: every overlapping pair is seen once.
  int _shared(Float64List at, Float64List from, Float64List to, Int32List edges, Uint8List flags) {
    final int runCount = at.length;
    final order = Int32List(runCount);
    for (var r = 0; r < runCount; r++) {
      order[r] = r;
    }
    var count = 0;
    var i = 0;
    while (i < runCount) {
      int end = i + 1;
      while (end < runCount && at[end] == at[i]) {
        end++;
      }
      if (end - i > 1) {
        sortIndicesStableByDouble(Int32List.sublistView(order, i, end), from);
        for (var a = i; a < end; a++) {
          final int ra = order[a];
          for (int b = a + 1; b < end && from[order[b]] < to[ra] - 1; b++) {
            final int rb = order[b];
            final double overlap = (to[ra] < to[rb] ? to[ra] : to[rb]) - from[rb];
            if (overlap > 1 && edges[ra] != edges[rb] && !_sharesPort(edges[ra], edges[rb])) {
              count++;
              flags[edges[ra]] = 1;
              flags[edges[rb]] = 1;
            }
          }
        }
      }
      i = end;
    }
    return count;
  }
}
