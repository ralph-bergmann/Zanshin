// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'graph_grid_view.dart';
import 'sort.dart';

// Line router B (Story 4.15, docs/graph-layout.md §14): one line per parent → child layout edge,
// ported from the floating-client export `e74ced3`'s graph-layout.jsx (GL; `routeLines` GL:148-299,
// the bridges GL:57-82). The class stage runs once per layout in grid units; the geometry stage runs
// per card size in pixels, with GL's formulas and evaluation order in doubles. GL's all-pairs loops
// (clusters, a run's room, bridges) are replaced by indexes with the same results.

/// The largest number of visible nodes for which the caller runs both stages synchronously on the
/// UI isolate; above it, in `Isolate.run` (docs/graph-layout.md §14.5: the largest n whose measured
/// class + geometry time stays within one 8 ms frame, AOT, spec-4-15 § Measurements).
const routeSyncNodeLimit = 20000;

/// A run's band keeps this far off the cards; also the least room a bridge leaves (GL's CUT_CLEAR).
const double _clear = 12;

/// A card blocks a run's band within this distance of its edges (GL:167).
const double _cardMargin = 10;

/// A card counts for a run within this distance of the run's x-range (GL:166).
const double _cardReach = 4;

/// The port fan-out at both card edges (GL:13; since Story 10.30 the exits' too): offsets from the centre of the
/// lines that do not take it.
const double _entryFirst = 24;
const double _entryStep = 16;
const double _entryMin = 8;
const double _entryInset = 18;

/// Lines on one gutter step this many pixels apart (GL:196).
const _gutterStep = 6;

/// The most placements of the ports while vertical lines on one x are separated ([_GeometryBuilder._banCollisions]).
const _settlePasses = 8;

/// A gutter with more lines than this is reported (its outer lines reach into the cards).
const _gutterBudget = 9;

/// Free detours (§14.2): a card this many units or fewer off a run's band blocks it.
const _detourUnits = 12;

/// Runs whose x-ranges come within this distance share a cluster (GL:282).
const double _nearGap = 10;

/// assignTracks' "inside" margin (GL:88).
const _inside = 0.5;

/// placeTracks' spacing bounds (GL:124).
const _trackMin = 3.5;
const double _trackMax = 6;
const double _trackSpread = 24;

/// assignTracks' order key weight per open predecessor (GL:99).
const _openWeight = 100000;

/// A crossing must lie this far inside both runs (GL:58, E = 1).
const double _crossMargin = 1;

/// A bridge's half width along its run, and the room a run keeps to its ends (GL:77-79).
const double _cutHalf = 6;

double _min(double a, double b) => a < b ? a : b;

double _max(double a, double b) => a > b ? a : b;

/// The class stage of line router B (docs/graph-layout.md §14.2): per layout, in grid units, with no
/// card size. Per layout edge its kind, side, gutter and gutter step, entry slot, `deep` flag and
/// whether it is its child's first parent; per column its visible nodes by row. [RouteGeometry]
/// turns it into pixels for one [RouteMetrics]; a card-size change re-runs only that stage.
///
/// The input arrays are kept by reference and must not change while this object is used.
final class RouteClasses {
  RouteClasses._({
    required this.nodeRows,
    required this.nodeCols,
    required this.unit,
    required this.free,
    required this.edgeFroms,
    required this.edgeTos,
    required this.maxRow,
    required this.columns,
    required this.kinds,
    required this.sides,
    required this.gutters,
    required this.gutterSteps,
    required this.slots,
    required this.deep,
    required this.firstParents,
    required this.columnStarts,
    required this.columnNodes,
    required this.directFallbacks,
    required this.fallbackEdges,
    required this.overfullGutters,
    required this._inStarts,
    required this._inEdges,
    required this._outStarts,
    required this._outEdges,
  });

  /// Classifies the layout edges of a grid, as `GraphGridView` exposes it: per node its row
  /// ([nodeRows], −1 for a hidden stack member, which is skipped) and column ([nodeCols]), [unit]
  /// rows per pitch (16 in `free`, 1 in `compact`), whether the grid is `free`, and per layout edge
  /// its parent ([edgeFroms]), child ([edgeTos]) and kind ([edgeKinds]; `GraphGridView`'s codes),
  /// in docs/graph-layout.md §3's order (a child's first edge is its first parent). [parentCounts]
  /// is the topology's real parent count per topology node (Story 4.10); a node index at or past its
  /// length (a stack node) counts as not single-parent.
  ///
  /// Throws [ArgumentError] when the node arrays or the edge arrays differ in length, [unit] ≤ 0, a
  /// visible node has a negative column, or an edge names a node out of range or a hidden one.
  factory RouteClasses.compute({
    required Int32List nodeRows,
    required Int32List nodeCols,
    required int unit,
    required bool free,
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

    final classifier = _Classifier(nodeRows, nodeCols, columnStarts, columnNodes, unit);
    final kinds = Uint8List(e);
    final sides = Int8List(e);
    final gutters = Int32List(e);
    final firstParents = Uint8List(e);
    final fallbackEdges = Uint8List(e);
    var directFallbacks = 0;
    for (var k = 0; k < e; k++) {
      final int p = edgeFroms[k];
      final int c = edgeTos[k];
      final first = inEdges[inStarts[c]] == k;
      firstParents[k] = first ? 1 : 0;
      final int cp = nodeCols[p];
      final int cc = nodeCols[c];
      final int rp = nodeRows[p];
      final int rc = nodeRows[c];
      var side = cc > cp ? 1 : (cc < cp ? -1 : 0);
      int kind;
      if (side == 0) {
        kind = first && classifier.columnFree(cp, rp, rc) ? kindStraight : kindGutter;
        side = 1;
      } else if (first) {
        kind = classifier.columnFree(cc, rp, rc) ? kindFork : kindGutter;
      } else if (rc == rp + unit) {
        kind = kindMergeAdjacent;
      } else {
        kind = classifier.columnFree(cp, rp, rc) ? kindMergeUp : kindGutter;
      }
      var j = 0;
      if (free && kind != kindStraight && cc != cp) {
        final int span = cc > cp ? cc - cp : cp - cc;
        // above: the farthest column (distance t from the child, 1 ≤ t < span) with a card 1–12
        // units above the parent, 0 if none; below: the nearest with a card 1–12 units below the
        // child, span if none. Gutter j is free iff above ≤ j < below.
        int? above;
        int? below;
        final bool blocked;
        if (kind == kindMergeUp) {
          below = classifier.firstBelow(cc, side, span, rc);
          blocked = below < span;
        } else if (kind == kindGutter) {
          blocked = false;
        } else {
          above = classifier.lastAbove(cc, side, span, rp);
          blocked = above > 0;
        }
        if (kind == kindGutter || blocked) {
          above ??= classifier.lastAbove(cc, side, span, rp);
          below ??= classifier.firstBelow(cc, side, span, rc);
          if (above < below) {
            kind = kindGutter;
            j = above;
          } else {
            // No free gutter: a direct kind stays direct (counted), a `gutter` takes j = 0; both may
            // pass behind a card, so both are flagged.
            if (kind != kindGutter) {
              directFallbacks++;
            }
            fallbackEdges[k] = 1;
          }
        }
      }
      kinds[k] = kind;
      sides[k] = side;
      if (kind == kindGutter) {
        gutters[k] = cc == cp ? 2 * cc + 1 : 2 * cc - side * (2 * j + 1);
      }
    }

    // Gutter steps, counted in edge order per gutter (GL:193-197).
    final gutterSteps = Int32List(e);
    final perGutter = Int32List(2 * columns + 2);
    var overfullGutters = 0;
    for (var k = 0; k < e; k++) {
      if (kinds[k] != kindGutter) {
        continue;
      }
      final int at = gutters[k] + 1;
      final int count = perGutter[at];
      final int half = (count + 1) ~/ 2;
      gutterSteps[k] = count.isOdd ? half : -half;
      perGutter[at] = count + 1;
      if (count == _gutterBudget) {
        overfullGutters++;
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
      free: free,
      edgeFroms: edgeFroms,
      edgeTos: edgeTos,
      maxRow: maxRow,
      columns: columns,
      kinds: kinds,
      sides: sides,
      gutters: gutters,
      gutterSteps: gutterSteps,
      slots: slots,
      deep: deep,
      firstParents: firstParents,
      columnStarts: columnStarts,
      columnNodes: columnNodes,
      directFallbacks: directFallbacks,
      fallbackEdges: fallbackEdges,
      overfullGutters: overfullGutters,
      inStarts: inStarts,
      inEdges: inEdges,
      outStarts: outStarts,
      outEdges: outEdges,
    );
  }

  /// A kind: same column, the first parent, and the column is free between the two rows.
  static const kindStraight = 0;

  /// A kind: the first parent in another column; turns above the parent, climbs the child's column.
  static const kindFork = 1;

  /// A kind: a non-first parent exactly one pitch below the child.
  static const kindMergeAdjacent = 2;

  /// A kind: a non-first parent whose column is free; climbs it and turns below the child.
  static const kindMergeUp = 3;

  /// A kind: turns above the parent, climbs a gutter between columns, turns below the child.
  static const kindGutter = 4;

  /// Each node's row (the input), −1 for a hidden node.
  final Int32List nodeRows;

  /// Each node's column (the input).
  final Int32List nodeCols;

  /// U, the rows per pitch (the input).
  final int unit;

  /// Whether the grid is `free` (the unit rule applies only there).
  final bool free;

  /// Each layout edge's parent (the input).
  final Int32List edgeFroms;

  /// Each layout edge's child (the input).
  final Int32List edgeTos;

  /// The largest visible row, 0 for none.
  final int maxRow;

  /// The number of columns: the largest visible column plus 1.
  final int columns;

  /// Each edge's kind ([kindStraight], [kindFork], [kindMergeAdjacent], [kindMergeUp] or
  /// [kindGutter]).
  final Uint8List kinds;

  /// Each edge's side: the sign of the child's column minus the parent's; 1 within one column.
  final Int8List sides;

  /// Each [kindGutter] edge's gutter in doubled column positions (column c's centre is 2c, the gutter
  /// between c and c + 1 is 2c + 1); 0 for the other kinds.
  final Int32List gutters;

  /// Each [kindGutter] edge's step on its gutter in multiples of 6 px (0, +1, −1, +2, …, in edge
  /// order per gutter); 0 for the other kinds.
  final Int32List gutterSteps;

  /// Each edge's entry slot: the index of the slot's first edge (its own index unless it shares).
  final Int32List slots;

  /// Each edge's `deep` flag (1 for the Indirect edges of a shared slot): its cluster sits as far
  /// from the child as it can.
  final Uint8List deep;

  /// Whether each edge is its child's first parent (1) or not (0).
  final Uint8List firstParents;

  /// The column CSR offsets ([columns] + 1): column c's visible nodes are
  /// `columnNodes[columnStarts[c] ..< columnStarts[c + 1]]`.
  final Int32List columnStarts;

  /// Every visible node, by column, then by row ascending.
  final Int32List columnNodes;

  /// Reported: edges whose direct run is blocked (unit rule) while every gutter is blocked too; they
  /// stay direct and may pass behind a card.
  final int directFallbacks;

  /// Per edge, 1 where the unit rule left it no free route: one of the [directFallbacks], or a
  /// `free` [kindGutter] line whose every gutter is blocked (it takes the gutter nearest the child);
  /// either may pass behind a card. 0 otherwise.
  final Uint8List fallbackEdges;

  /// Reported: gutters with more than 9 lines, whose outer lines may reach into the cards.
  final int overfullGutters;

  final Int32List _inStarts;
  final Int32List _inEdges;
  final Int32List _outStarts;
  final Int32List _outEdges;

  /// The number of layout edges.
  int get edgeCount => kinds.length;
}

/// Column queries of the class stage.
final class _Classifier {
  _Classifier(this.rows, this.cols, this.starts, this.nodes, this.unit);

  final Int32List rows;
  final Int32List cols;
  final Int32List starts;
  final Int32List nodes;
  final int unit;

  /// The first index in column [col]'s node list whose row is ≥ [row].
  int _lowerBound(int col, int row) {
    int lo = starts[col];
    int hi = starts[col + 1];
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (rows[nodes[mid]] < row) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// Whether column [col] holds no visible node with a row strictly between [r0] and [r1].
  bool columnFree(int col, int r0, int r1) {
    final int k = _lowerBound(col, r0 + 1);
    return k == starts[col + 1] || rows[nodes[k]] >= r1;
  }

  /// Whether column [col] holds a visible node with a row in [lo, hi].
  bool _any(int col, int lo, int hi) {
    final int k = _lowerBound(col, lo);
    return k < starts[col + 1] && rows[nodes[k]] <= hi;
  }

  /// The largest t in [1, span) such that column `child − side·t` has a card 1–12 units above the
  /// parent row [rp]; 0 if none.
  int lastAbove(int child, int side, int span, int rp) {
    for (int t = span - 1; t >= 1; t--) {
      if (_any(child - side * t, rp + 1, rp + _detourUnits)) {
        return t;
      }
    }
    return 0;
  }

  /// The least t in [1, span) such that column `child − side·t` has a card 1–12 units below the
  /// child row [rc]; [span] if none.
  int firstBelow(int child, int side, int span, int rc) {
    for (var t = 1; t < span; t++) {
      if (_any(child - side * t, rc - _detourUnits, rc - 1)) {
        return t;
      }
    }
    return span;
  }
}

/// The card size and spacing the geometry stage lays lines out for (docs/graph-layout.md §14.3), in
/// logical pixels: card [width] W and [height] H, column gap [gapX], row gap [gapY], plane padding
/// [pad].
///
/// The class stage's unit rule (docs/graph-layout.md §14.2) never routes a line directly where the
/// export's pixel test would detour only while a card 13 units off a band clears it:
/// 13·(H + gapY)/16 ≥ H + 22, i.e. H ≤ (13·gapY − 352)/3 (≈ 90 px at gapY 48). Taller cards keep
/// working, but a direct run may then pass a card 13 units off.
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

/// The geometry stage of line router B (docs/graph-layout.md §14.3): one [RouteClasses] laid out
/// for one [RouteMetrics]. Every edge's polyline (2, 4 or 6 points, from the parent's top edge to
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
    required this.overfullClusters,
    required this.overfullEdges,
    required this.unavoidableCrossings,
    required this.unsettledPorts,
  });

  /// Lays [classes] out for [metrics].
  factory RouteGeometry.compute(RouteClasses classes, RouteMetrics metrics) =>
      _GeometryBuilder(classes, metrics).build();

  /// The class stage this geometry was computed from.
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

  /// Reported: clusters of runs with more tracks than their bands' free parts hold; they keep their
  /// spacing, centred, and may reach into a card.
  final int overfullClusters;

  /// Per edge, whether one of its runs lies in one of the [overfullClusters] (1) or not (0).
  final Uint8List overfullEdges;

  /// Reported: pairs of runs in one cluster that each must lie above the other; they cross.
  final int unavoidableCrossings;

  /// Reported: pairs of vertical lines still sharing an x after the last of the port passes (0 when the
  /// passes settled); the longer-straight tie-break would move one of each pair.
  final int unsettledPorts;

  /// The bridges whose crossing point lies in [x0, x1) × [y0, y1) (docs/graph-layout.md §14.4), by
  /// horizontal run index, then vertical run index. Only edges that share no node bridge.
  ///
  /// A break reaches 6 px around its crossing point, so a caller that paints tiles queries each
  /// tile's window grown by 6 px on every side and drops the crossings it already painted.
  ///
  /// Cost: a binary search per axis, then a scan of every vertical run whose x lies in the window's
  /// x-strip — over the whole plane height, so a long linear history (many verticals at one x) makes
  /// even a small window scan them all — then a test of each horizontal in the window against the
  /// verticals that overlap it.
  RouteBridges bridges(double x0, double y0, double x1, double y1) {
    final Int32List froms = classes.edgeFroms;
    final Int32List tos = classes.edgeTos;
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
        if (froms[he] == froms[ve] || tos[he] == tos[ve] || froms[he] == tos[ve] || tos[he] == froms[ve]) {
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

/// The geometry stage's working state (GL:151-299 for one W and H).
final class _GeometryBuilder {
  _GeometryBuilder(this.c, this.m)
    : w = m.width,
      h = m.height,
      gy = m.gapY,
      pitch = m.height + m.gapY,
      colW = m.width + m.gapX,
      n = c.nodeRows.length,
      e = c.kinds.length;

  final RouteClasses c;
  final RouteMetrics m;
  final double w;
  final double h;
  final double gy;
  final double pitch;
  final double colW;
  final int n;
  final int e;

  late final x = Float64List(n);
  late final y = Float64List(n);
  late final cx = Float64List(n);

  /// Per edge: exit x, entry x, gutter x (with its step).
  late final xo = Float64List(e);
  late final xi = Float64List(e);
  late final xg = Float64List(e);

  /// Scratch key and lists for the per-node sorts.
  late final key1 = Float64List(e);
  late final scratch = Int32List(e);
  late final sideScratch = Int32List(e);

  /// Per edge at its child's bottom ([reachIn], [towardIn]) and its parent's top ([reachOut], [towardOut]): how far
  /// it runs straight from that card edge to the near side of the band it first turns in (infinite for a straight
  /// line), and the x it turns toward (its side); [tieIn] (the parent's row) orders equal entries, the exits keep
  /// their edge order ([tieOut] stays 0).
  late final reachIn = Float64List(e);
  late final towardIn = Float64List(e);
  late final tieIn = Float64List(e);
  late final reachOut = Float64List(e);
  late final towardOut = Float64List(e);
  late final tieOut = Float64List(e);

  /// Per edge at its child's bottom (…In) and its parent's top (…Out), set by [_banCollisions]: 1 where it lost the
  /// centre, and how many fan slots further out it sits, to a vertical line that stays straight longer on its x.
  late final noCentreIn = Uint8List(e);
  late final noCentreOut = Uint8List(e);
  late final extraIn = Uint8List(e);
  late final extraOut = Uint8List(e);

  RouteGeometry build() {
    _positions();
    _gutterXs();
    _reaches();
    var passes = 0;
    do {
      _entries();
      _exits();
    } while (++passes < _settlePasses && _banCollisions() > 0);
    final int unsettled = passes == _settlePasses ? _banCollisions(apply: false) : 0;
    final (Int32List portStarts, Float64List portXs) = _ports();
    final runs = _Runs(this)..place();
    return _finish(runs, portStarts, portXs, unsettled);
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
      x[i] = m.pad + cols[i] * colW;
      cx[i] = x[i] + w / 2;
    }
  }

  void _gutterXs() {
    for (var k = 0; k < e; k++) {
      if (c.kinds[k] != RouteClasses.kindGutter) {
        continue;
      }
      final int child = c.edgeTos[k];
      final int cc = c.nodeCols[child];
      final int side = c.sides[k];
      final double gx;
      if (cc == c.nodeCols[c.edgeFroms[k]]) {
        gx = cx[child] + side * colW / 2;
      } else {
        final int j = (side * (2 * cc - c.gutters[k]) - 1) ~/ 2;
        gx = cx[child] - side * colW * (j + 0.5);
      }
      xg[k] = gx + _gutterStep * c.gutterSteps[k];
    }
  }

  /// m ports inner → outer (GL:199-205): [step] apart while they fit, squeezed to [min], then the
  /// overflow shares the outermost port. Port [k] of [count].
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

  /// Port [k] of [count] on one side of a card edge, top or bottom (Story 10.30: the entry fan at both ends).
  double _portFan(int count, int k) => _fan(count, _entryFirst, _entryStep, _entryMin, w / 2 - _entryInset, k);

  /// Each line's reach at both card edges: at the child's bottom a fork climbs the child's column from the band
  /// above its parent, the other bending kinds turn in the band right below the child; at the parent's top a
  /// merge-up climbs the parent's column to the band right below its child, the other bending kinds turn in the
  /// band right above the parent.
  void _reaches() {
    final Int32List froms = c.edgeFroms;
    final Int32List tos = c.edgeTos;
    final Uint8List kinds = c.kinds;
    for (var k = 0; k < e; k++) {
      final int kind = kinds[k];
      final double top = y[froms[k]];
      final double bottom = y[tos[k]] + h;
      reachIn[k] = kind == RouteClasses.kindStraight
          ? double.infinity
          : kind == RouteClasses.kindFork
          ? top - gy - bottom
          : 0;
      reachOut[k] = kind == RouteClasses.kindStraight
          ? double.infinity
          : kind == RouteClasses.kindMergeUp
          ? top - gy - bottom
          : 0;
      towardIn[k] = kind == RouteClasses.kindGutter ? xg[k] : cx[froms[k]];
      tieIn[k] = c.nodeRows[froms[k]].toDouble();
    }
  }

  /// The port rules at one card edge with centre [mid] (Story 10.30, by local direction since the follow-up of
  /// 2026-11-02): the lines are `scratch[from ..< from + count]` with their [reach] and [toward]; [tie] breaks
  /// ties; a line [banned] from the centre never takes it, a line with [extra] slots sits that many fan slots
  /// further out ([_banCollisions]). A line is vertical at the edge when it runs straight through the band next to
  /// it (reach ≥ gapY), else it turns there. One line takes the centre; of several, the vertical one that stays
  /// straight longest does, with none vertical the centre stays free. The rest fan to the side they turn to:
  /// vertical lines innermost (longest first), then the lines that turn at the edge, nearest turn first.
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

  /// Entries on each child's bottom edge (GL:206-221; [_place]'s rules). The lines are the slot owners; the other
  /// lines of a shared slot take its owner's x.
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

  /// Exits on each parent's top edge (GL:222-250; variant B; [_place]'s rules, as the entries').
  void _exits() {
    final Int32List outStarts = c._outStarts;
    final Int32List outEdges = c._outEdges;
    final Uint8List kinds = c.kinds;
    for (var node = 0; node < n; node++) {
      final int from = outStarts[node];
      final int to = outStarts[node + 1];
      for (var q = from; q < to; q++) {
        final int k = outEdges[q];
        towardOut[k] = kinds[k] == RouteClasses.kindGutter ? xg[k] : xi[k];
        scratch[q] = k;
      }
      _place(from, to - from, cx[node], xo, reachOut, towardOut, tieOut, noCentreOut, extraOut);
    }
  }

  /// Two vertical lines never share an x — the port rule's tie-break, carried from one card edge to the column:
  /// where the straight stretches (from the card edge through the band the line first turns in) of two lines of
  /// different card edges overlap on one x (a line climbing its column past another card's port), the one that
  /// stays straight longer keeps its port (tie: the lower edge index); the other leaves the centre, or sits one fan
  /// slot further out; two lines that both turn at their edges (reach < gapY) are left to the tracks. Bans and extra
  /// slots only accumulate across passes, never reset, so the passes terminate. Returns how many lines moved (the
  /// ports are then placed again); with [apply] false it only counts the collisions and moves nothing.
  int _banCollisions({bool apply = true}) {
    final Int32List froms = c.edgeFroms;
    final Int32List tos = c.edgeTos;
    final Uint8List kinds = c.kinds;
    final claimEdge = Int32List(2 * e);
    final claimIn = Uint8List(2 * e);
    final at = Float64List(2 * e);
    final lo = Float64List(2 * e);
    final hi = Float64List(2 * e);
    final len = Float64List(2 * e);
    var count = 0;
    for (var k = 0; k < e; k++) {
      final int p = froms[k];
      final int ch = tos[k];
      final double top = y[p];
      final double bottom = y[ch] + h;
      // Every line's stretch at both card edges; one that turns at the edge has its band (reach 0).
      {
        claimEdge[count] = k;
        at[count] = xo[k];
        lo[count] = kinds[k] == RouteClasses.kindStraight ? bottom : top - reachOut[k] - gy;
        hi[count] = top;
        len[count++] = reachOut[k];
      }
      if (kinds[k] != RouteClasses.kindStraight && c.slots[k] == k) {
        claimEdge[count] = k;
        claimIn[count] = 1;
        at[count] = xi[k];
        lo[count] = bottom;
        hi[count] = bottom + reachIn[k] + gy;
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
            len[a] < gy && len[b] < gy || // two lines turning at their edges: the tracks keep them apart
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

  RouteGeometry _finish(_Runs runs, Int32List portStarts, Float64List portXs, int unsettledPorts) {
    final Uint8List kinds = c.kinds;
    final pointStarts = Int32List(e + 1);
    for (var k = 0; k < e; k++) {
      final int kind = kinds[k];
      pointStarts[k + 1] =
          pointStarts[k] +
          (kind == RouteClasses.kindStraight
              ? 2
              : kind == RouteClasses.kindGutter
              ? 6
              : 4);
    }
    final points = Float64List(2 * pointStarts[e]);
    for (var k = 0; k < e; k++) {
      final double top = y[c.edgeFroms[k]];
      final double bot = y[c.edgeTos[k]] + h;
      int q = 2 * pointStarts[k];
      void put(double px, double py) {
        points[q++] = px;
        points[q++] = py;
      }

      final int kind = kinds[k];
      if (kind == RouteClasses.kindStraight) {
        put(xo[k], top);
        put(xo[k], bot);
        continue;
      }
      final int seg = runs.edgeSeg[k];
      final double y0 = runs.segY[seg];
      put(xo[k], top);
      put(xo[k], y0);
      if (kind == RouteClasses.kindGutter) {
        final double y1 = runs.segY[seg + 1];
        put(xg[k], y0);
        put(xg[k], y1);
        put(xi[k], y1);
        put(xi[k], bot);
      } else {
        put(xi[k], y0);
        put(xi[k], bot);
      }
    }
    return _runIndexes(pointStarts, points, portStarts, portXs, runs, unsettledPorts);
  }

  RouteGeometry _runIndexes(
    Int32List pointStarts,
    Float64List points,
    Int32List portStarts,
    Float64List portXs,
    _Runs runs,
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

    return RouteGeometry._(
      classes: c,
      metrics: m,
      pointStarts: pointStarts,
      points: points,
      portStarts: portStarts,
      portXs: portXs,
      verticalXs: byOrder(vx, vOrder),
      verticalTops: byOrder(vTop, vOrder),
      verticalBottoms: byOrder(vBottom, vOrder),
      verticalEdges: edgesByOrder(vEdge, vOrder),
      horizontalYs: byOrder(hy, hOrder),
      horizontalLefts: byOrder(hLeft, hOrder),
      horizontalRights: byOrder(hRight, hOrder),
      horizontalEdges: edgesByOrder(hEdge, hOrder),
      overfullClusters: runs.overfullClusters,
      overfullEdges: runs.overfullEdges,
      unavoidableCrossings: runs.unavoidableCrossings,
      unsettledPorts: unsettledPorts,
    );
  }
}

/// The horizontal runs of one geometry, their room, clusters and tracks (GL:251-290, :84-132).
final class _Runs {
  _Runs(this.g) : edgeSeg = Int32List(g.e), overfullEdges = Uint8List(g.e);

  final _GeometryBuilder g;

  /// Each edge's first run (gutter edges have two, consecutive); unused for `straight`.
  final Int32List edgeSeg;

  /// Per edge, whether a run of it lies in an overfull cluster.
  final Uint8List overfullEdges;

  late final Int32List segEdge;

  late final int count;
  late final Float64List band0;
  late final Float64List band1;
  late final Float64List down;
  late final Float64List up;
  late final Float64List a;
  late final Float64List b;
  late final Uint8List deep;
  late final Float64List lo;
  late final Float64List hi;
  late final Float64List segY;

  var overfullClusters = 0;
  var unavoidableCrossings = 0;

  void place() {
    _collect();
    _rooms();
    _clusters();
  }

  void _collect() {
    final RouteClasses c = g.c;
    final Uint8List kinds = c.kinds;
    var total = 0;
    for (var k = 0; k < g.e; k++) {
      final int kind = kinds[k];
      edgeSeg[k] = total;
      total += kind == RouteClasses.kindStraight ? 0 : (kind == RouteClasses.kindGutter ? 2 : 1);
    }
    count = total;
    segEdge = Int32List(total);
    band0 = Float64List(total);
    band1 = Float64List(total);
    down = Float64List(total);
    up = Float64List(total);
    a = Float64List(total);
    b = Float64List(total);
    deep = Uint8List(total);
    lo = Float64List(total);
    hi = Float64List(total);
    segY = Float64List(total);
    final double gy = g.gy;
    final double h = g.h;
    for (var k = 0; k < g.e; k++) {
      final int kind = kinds[k];
      if (kind == RouteClasses.kindStraight) {
        continue;
      }
      final int s = edgeSeg[k];
      final double py = g.y[c.edgeFroms[k]];
      final double ny = g.y[c.edgeTos[k]];
      final isDeep = c.deep[k] != 0;
      void run(int q, double top, double bottom, double d, double u, {required bool deepRun}) {
        segEdge[q] = k;
        band0[q] = top;
        band1[q] = bottom;
        down[q] = d;
        up[q] = u;
        a[q] = _min(d, u);
        b[q] = _max(d, u);
        deep[q] = deepRun ? 1 : 0;
      }

      switch (kind) {
        case RouteClasses.kindMergeUp:
          run(s, ny + h, ny + h + gy, g.xo[k], g.xi[k], deepRun: isDeep);
        case RouteClasses.kindGutter:
          run(s, py - gy, py, g.xo[k], g.xg[k], deepRun: false);
          run(s + 1, ny + h, ny + h + gy, g.xg[k], g.xi[k], deepRun: isDeep);
        case _:
          run(s, py - gy, py, g.xo[k], g.xi[k], deepRun: isDeep && kind == RouteClasses.kindMergeAdjacent);
      }
    }
  }

  /// Each run's free part (GL:163-171, :274-280): its band's inner part, in `free` minus the cards
  /// near its x-range; the interval nearest the band's middle.
  void _rooms() {
    final RouteClasses c = g.c;
    final bool free = c.free;
    final double w = g.w;
    final double h = g.h;
    final double pad = g.m.pad;
    final double colW = g.colW;
    final int columns = c.columns;
    final Int32List starts = c.columnStarts;
    final Int32List nodes = c.columnNodes;
    final Float64List y = g.y;
    var c0s = Float64List(16);
    var c1s = Float64List(16);
    for (var q = 0; q < count; q++) {
      final double l = band0[q] + _clear;
      final double top = band1[q] - _clear;
      final double mid = (band0[q] + band1[q]) / 2;
      var cards = 0;
      if (free && columns > 0) {
        final double ra = a[q];
        final double rb = b[q];
        int colLo = ((ra - _cardReach - w - pad) / colW).floor();
        int colHi = ((rb + _cardReach - pad) / colW).ceil();
        if (colLo < 0) {
          colLo = 0;
        }
        if (colHi > columns - 1) {
          colHi = columns - 1;
        }
        for (var col = colLo; col <= colHi; col++) {
          final double ox = pad + col * colW;
          if (ox >= rb + _cardReach || ox + w <= ra - _cardReach) {
            continue;
          }
          // Rows ascend, so y descends: the cards with c0 < top form a suffix, those with c1 > l a
          // prefix.
          int from = starts[col];
          int to = starts[col + 1];
          while (from < to) {
            final int midIndex = (from + to) >> 1;
            if (y[nodes[midIndex]] - _cardMargin < top) {
              to = midIndex;
            } else {
              from = midIndex + 1;
            }
          }
          for (var k = from; k < starts[col + 1]; k++) {
            final double oy = y[nodes[k]];
            final double c1 = oy + h + _cardMargin;
            if (c1 <= l) {
              break;
            }
            if (cards == c0s.length) {
              c0s = Float64List(2 * cards)..setAll(0, c0s);
              c1s = Float64List(2 * cards)..setAll(0, c1s);
            }
            c0s[cards] = oy - _cardMargin;
            c1s[cards++] = c1;
          }
        }
      }
      if (cards == 0) {
        lo[q] = l;
        hi[q] = top;
        continue;
      }
      // Ascending by c0 (few cards: insertion sort), then sweep the closed intervals left over.
      for (var i = 1; i < cards; i++) {
        final double k0 = c0s[i];
        final double k1 = c1s[i];
        int j = i - 1;
        while (j >= 0 && c0s[j] > k0) {
          c0s[j + 1] = c0s[j];
          c1s[j + 1] = c1s[j];
          j--;
        }
        c0s[j + 1] = k0;
        c1s[j + 1] = k1;
      }
      double bestD = double.infinity;
      var bestL = mid;
      var bestH = mid;
      void consider(double il, double ih) {
        final double d = mid < il ? il - mid : (mid > ih ? mid - ih : 0);
        if (d < bestD) {
          bestD = d;
          bestL = il;
          bestH = ih;
        }
      }

      var cur = l;
      for (var i = 0; i < cards; i++) {
        if (c0s[i] >= cur) {
          consider(cur, c0s[i]);
        }
        if (c1s[i] > cur) {
          cur = c1s[i];
        }
      }
      if (top >= cur) {
        consider(cur, top);
      }
      lo[q] = bestL;
      hi[q] = bestH;
    }
  }

  bool _near(int i, int j) => a[i] < b[j] + _nearGap && a[j] < b[i] + _nearGap;

  /// Clusters (GL:281-290): runs whose bands overlap and whose x-ranges come within 10 px, joined
  /// transitively; each placed by [_placeTracks] with its runs in index order.
  void _clusters() {
    final root = Int32List(count);
    for (var q = 0; q < count; q++) {
      root[q] = q;
    }
    int find(int q) {
      var r = q;
      while (root[r] != r) {
        r = root[r];
      }
      var x = q;
      while (root[x] != r) {
        final int next = root[x];
        root[x] = r;
        x = next;
      }
      return r;
    }

    final order = Int32List(count);
    for (var q = 0; q < count; q++) {
      order[q] = q;
    }
    sortIndicesStableByDouble(order, band0);
    var active = Int32List(16);
    var live = 0;
    for (var o = 0; o < count; o++) {
      final int s = order[o];
      final double s0 = band0[s];
      var kept = 0;
      for (var t = 0; t < live; t++) {
        final int other = active[t];
        if (band1[other] <= s0) {
          continue;
        }
        active[kept++] = other;
        if (_near(s, other)) {
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
    // Members per cluster, in run index order (a CSR over the roots).
    final starts = Int32List(count + 1);
    final rootOf = Int32List(count);
    for (var q = 0; q < count; q++) {
      rootOf[q] = find(q);
      starts[rootOf[q] + 1]++;
    }
    for (var q = 0; q < count; q++) {
      starts[q + 1] += starts[q];
    }
    final members = Int32List(count);
    final fill = Int32List.fromList(starts);
    for (var q = 0; q < count; q++) {
      members[fill[rootOf[q]]++] = q;
    }
    for (var r = 0; r < count; r++) {
      if (starts[r + 1] > starts[r]) {
        _placeTracks(Int32List.sublistView(members, starts[r], starts[r + 1]));
      }
    }
  }

  /// GL's `assignTracks` + `placeTracks` (GL:87-132) for one cluster, [segs] in run index order.
  void _placeTracks(Int32List segs) {
    final int size = segs.length;
    if (size == 1 && lo[segs[0]] <= hi[segs[0]] + 0.01) {
      // One run, one track: what the general path computes with spacing 0.
      final int q = segs[0];
      final double lam = deep[q] != 0 ? 1 : 0.5;
      segY[q] = lo[q] + lam * (hi[q] - lo[q]);
      return;
    }
    // pred[j] ∋ i (i must run above j): row j, bit i.
    // shortcut: O(size²) time and size²/8 bytes per cluster, as GL's assignTracks; the measured
    // layouts (up to synth-100k) keep clusters small. Index the relation if a real layout shows a
    // cluster of thousands of runs.
    final int words = (size + 31) >> 5;
    final pred = Uint32List(size * words);
    bool has(int j, int i) => (pred[j * words + (i >> 5)] >> (i & 31)) & 1 != 0;
    void set(int j, int i) => pred[j * words + (i >> 5)] |= 1 << (i & 31);
    void clear(int j, int i) => pred[j * words + (i >> 5)] &= ~(1 << (i & 31));
    bool inside(int s, double xv) => xv > a[s] + _inside && xv < b[s] - _inside;
    for (var i = 0; i < size; i++) {
      final int si = segs[i];
      for (var j = 0; j < size; j++) {
        if (i == j) {
          continue;
        }
        final int sj = segs[j];
        if (inside(si, down[sj]) || inside(sj, up[si])) {
          set(j, i);
        }
      }
    }
    for (var i = 0; i < size; i++) {
      for (var j = 0; j < size; j++) {
        if (j != i && has(i, j) && has(j, i)) {
          clear(i, j);
          clear(j, i);
          unavoidableCrossings++;
        }
      }
    }
    // Order: fewest open predecessors, then the longest run, then the index (GL:94-103).
    final open = Int32List(size);
    for (var j = 0; j < size; j++) {
      for (var i = 0; i < size; i++) {
        if (has(j, i)) {
          open[j]++;
        }
      }
    }
    final done = Uint8List(size);
    final pos = Int32List(size);
    final order = Int32List(size);
    for (var step = 0; step < size; step++) {
      var pick = -1;
      double best = double.infinity;
      for (var i = 0; i < size; i++) {
        if (done[i] != 0) {
          continue;
        }
        final double key = open[i] * _openWeight - (b[segs[i]] - a[segs[i]]);
        if (key < best) {
          best = key;
          pick = i;
        }
      }
      done[pick] = 1;
      pos[pick] = step;
      order[step] = pick;
      for (var j = 0; j < size; j++) {
        if (done[j] == 0 && has(j, pick)) {
          open[j]--;
        }
      }
    }
    // Tracks: after every placed predecessor, then the first track with no near run (GL:104-111).
    final track = Int32List(size);
    var tracks = 0;
    for (var step = 0; step < size; step++) {
      final int i = order[step];
      var t = 0;
      for (var k = 0; k < size; k++) {
        if (has(i, k) && pos[k] < pos[i] && track[k] + 1 > t) {
          t = track[k] + 1;
        }
      }
      final int si = segs[i];
      var clash = true;
      while (clash) {
        clash = false;
        for (var q = 0; q < step; q++) {
          final int other = order[q];
          if (track[other] == t && a[segs[other]] < b[si] + _nearGap && a[si] < b[segs[other]] + _nearGap) {
            clash = true;
            t++;
            break;
          }
        }
      }
      track[i] = t;
      if (t + 1 > tracks) {
        tracks = t + 1;
      }
    }
    // `ord`: by track, then index (GL:117).
    final byTrack = Int32List(size);
    final trackKey = Int64List(size);
    for (var i = 0; i < size; i++) {
      byTrack[i] = i;
      trackKey[i] = track[i];
    }
    sortIndicesStable(byTrack, trackKey);
    final count = tracks < 1 ? 1 : tracks;
    var lam = 0.5;
    for (var i = 0; i < size; i++) {
      if (deep[segs[i]] != 0) {
        lam = 1;
      }
    }
    final top = Float64List(size);
    final bot = Float64List(size);
    bool pack(double sp) {
      for (var o = 0; o < size; o++) {
        final int i = byTrack[o];
        double t = lo[segs[i]];
        for (var p = 0; p < size; p++) {
          final int j = byTrack[p];
          if (track[j] < track[i] && _near(segs[i], segs[j])) {
            t = _max(t, top[j] + sp);
          }
        }
        top[i] = t;
      }
      for (int o = size - 1; o >= 0; o--) {
        final int i = byTrack[o];
        double t = hi[segs[i]];
        for (var p = 0; p < size; p++) {
          final int j = byTrack[p];
          if (track[j] > track[i] && _near(segs[i], segs[j])) {
            t = _min(t, bot[j] - sp);
          }
        }
        bot[i] = t;
      }
      for (var i = 0; i < size; i++) {
        if (!(top[i] <= bot[i] + 0.01)) {
          return false;
        }
      }
      return true;
    }

    final double sp0 = count > 1 ? _max(_trackMin, _min(_trackMax, _trackSpread / (count - 1))) : 0;
    bool ok = pack(sp0);
    if (!ok && sp0 > _trackMin) {
      ok = pack(_trackMin);
    }
    if (ok) {
      for (var i = 0; i < size; i++) {
        segY[segs[i]] = top[i] + lam * (bot[i] - top[i]);
      }
      return;
    }
    // More lines than room: keep order and spacing, centre the block on the bands (GL:128-131).
    overfullClusters++;
    var sum = 0.0;
    for (var i = 0; i < size; i++) {
      sum = sum + (lo[segs[i]] + hi[segs[i]]) / 2;
    }
    final double mid = sum / size;
    double least = top[0];
    double most = top[0];
    for (var i = 1; i < size; i++) {
      least = _min(least, top[i]);
      most = _max(most, top[i]);
    }
    final double shift = mid - (least + most) / 2;
    for (var i = 0; i < size; i++) {
      segY[segs[i]] = top[i] + shift;
      overfullEdges[segEdge[segs[i]]] = 1;
    }
  }
}
