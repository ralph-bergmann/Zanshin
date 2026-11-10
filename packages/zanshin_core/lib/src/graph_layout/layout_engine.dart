// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'graph_grid_view.dart';
import 'layout_input.dart';
import 'layout_request.dart';
import 'sort.dart';
import 'stacks.dart';

// The product layout engine: docs/graph-layout.md §4 for the shipped scope. The rows are §4.2's,
// and the columns are §4.3's branch columns (amended 2026-11-10): the graph layout lab's rule
// (spikes/graph-layout-lab/lib/columns.dart) on the requested mode's rows. Flat typed arrays and CSR
// adjacency, no per-node objects, monomorphic sorts (sort.dart).

/// U of each vertical model (§4.2): model 0 is `compact`, model 1 is `free`.
const modelUnits = <int>[1, 16];

const _minute = 60000;
const _day = 86400000;

/// A route (§4.5): the parent's lane continues into the child.
const int routeStraight = GraphGridView.routeStraight;

/// A route (§4.5): a non-first parent in another lane, not blocked.
const int routeMerge = GraphGridView.routeMerge;

/// A route (§4.5): a first parent in another lane, or a blocked merge (D9).
const int routeBranchOff = GraphGridView.routeBranchOff;

/// U, the units per row pitch, of [mode] (docs/graph-layout.md §1).
int unitOf(LayoutMode mode) => switch (mode) {
  LayoutMode.compact => 1,
  LayoutMode.free => 16,
};

/// Floor division for b > 0 (docs/graph-layout.md §1): Dart's `%` is already non-negative.
int floorDiv(int a, int b) => (a - a % b) ~/ b;

/// The local-midnight instant (epoch ms) of the calendar day holding [t] at the fixed UTC offset
/// (D7): `free`'s day key, ((t + off) div 86400000)·86400000 − off (§4.2 free, step 4).
int dayKey(int t, int utcOffsetMin) {
  final int off = utcOffsetMin * _minute;
  return floorDiv(t + off, _day) * _day - off;
}

/// `free`'s gap in 1/16-pitch units for g ≥ 0 elapsed ms (§4.2 free, step 3):
/// min(48, 2·L2(1 + g div 60000) div 256), L2 a piecewise-linear fixed-point log2.
int freeGap(int g) {
  final int x = 1 + floorDiv(g, _minute);
  final int k = x.bitLength - 1;
  final int l2 = 256 * k + ((x - (1 << k)) * 256) ~/ (1 << k);
  final int gap = (2 * l2) ~/ 256;
  return gap < 48 ? gap : 48;
}

/// `free`'s walk step in units between consecutive walk nodes with clamped T [tPrev] ≤ [t]
/// (§4.2 free, step 3, amended 2026-10-31, Story 4.16): [freeGap], but at least one pitch (16)
/// across a day change, so no card sits in the band around a day divider.
int freeStep(int tPrev, int t, int utcOffsetMin) {
  final int gap = freeGap(t - tPrev);
  final int pitch = modelUnits[1];
  if (gap >= pitch || dayKey(tPrev, utcOffsetMin) == dayKey(t, utcOffsetMin)) {
    return gap;
  }
  return pitch;
}

/// Lays out [input] (docs/graph-layout.md §4) in [mode] and returns the grid buffer [GraphGridView]
/// reads.
///
/// The columns are the branch columns of §4.3 (amended 2026-11-10), chosen on [mode]'s rows, so a
/// `compact` and a `free` grid of one input may differ in lanes and columns. Every grid carries each
/// node's local day key ([GraphGridView.nodeDays]).
///
/// With [stacks] (Story 4.13) the finished layout's linear runs are grouped by §4.8 — the columns
/// stay, only rows move — and the grid has format version [GraphGridView.stackFormatVersion];
/// without it, format version [GraphGridView.formatVersion].
///
/// Validates first ([validateLayoutInput], then [validateStackInput]): a contract violation
/// throws [LayoutContractException] and lays out nothing. [onPhaseEnd] runs after each of the
/// four timed phases (layering, lanes, blocked, routing; §8.2) and, with [stacks], after the fifth
/// (stacks); writing the grid is not timed.
Uint8List computeGraphGrid(
  LayoutInput input, {
  required LayoutMode mode,
  StackInput? stacks,
  void Function()? onPhaseEnd,
}) {
  validateLayoutInput(input);
  if (stacks != null) {
    validateStackInput(stacks, input.n);
  }
  final engine = LayoutEngine(input, mode)..layering();
  onPhaseEnd?.call();
  engine.chooseColumns();
  onPhaseEnd?.call();
  engine.markBlocked();
  onPhaseEnd?.call();
  engine.route();
  onPhaseEnd?.call();
  if (stacks == null) {
    return engine.toGrid();
  }
  final grouped = StackLayout(engine, stacks)..run();
  onPhaseEnd?.call();
  return grouped.toGrid();
}

/// The layout state of docs/graph-layout.md §4, one phase per method; the phases run in order:
/// [layering], [chooseColumns], [markBlocked], [route]. Public for the engine's tests and the
/// graph layout lab; callers use [computeGraphGrid].
final class LayoutEngine {
  /// The state for laying out [input] — which must be valid ([validateLayoutInput]) — in [mode].
  LayoutEngine(this.input, this.mode) : n = input.n, unit = unitOf(mode);

  /// The input.
  final LayoutInput input;

  /// The vertical model.
  final LayoutMode mode;

  /// The node count.
  final int n;

  /// U (§1).
  final int unit;

  /// The model index of [mode] (0 `compact`, 1 `free`; [modelUnits]).
  int get requestedModel => mode == LayoutMode.compact ? 0 : 1;

  /// Per model its y — the requested one is [y] itself — set by [layering]. [chooseColumns] reads only
  /// the requested model's; the free model also gives a `compact` request its day keys (§4.2 free step
  /// 4), and the graph layout lab reads both.
  late final List<Int64List> modelY;

  /// §4.2 free's clamped T(i) of every node, in both modes: the day key's time (Story 4.14).
  late final Int64List clampedT;

  // ---- §4.1 graph prep: layout parents LP (CSR, one entry per layout edge), fp, children C.

  /// E, the number of layout edges.
  late final int edgeCount;

  /// LP's CSR offsets (n + 1): node i's layout edges are `lpStart[i] ..< lpStart[i + 1]`.
  late final Int32List lpStart;

  /// Each layout edge's parent; the edges are ordered by (child, pos), §3's output order.
  late final Int32List edgeParent;

  /// Each layout edge's child.
  late final Int32List edgeChild;

  /// Each layout edge's kind ([parentDirect] or [parentIndirect]).
  late final Uint8List edgeKind;

  /// fp(i), the first layout parent, or −1 when LP(i) is empty.
  late final Int32List fp;

  /// C's CSR offsets (n + 1).
  late final Int32List chStart;

  /// The children of every node, ascending per node.
  late final Int32List chIdx;

  // ---- §4.2

  /// y(i), in rows (`compact`) or 1/U pitch units (`free`).
  late final Int64List y;

  /// `free`'s day buckets (§4.2 free, step 4): each bucket's value; empty in `compact`.
  var bucketValue = Int64List(0);

  /// Each bucket's least member y.
  var bucketStart = Int64List(0);

  /// Each bucket's largest member y.
  var bucketEnd = Int64List(0);

  /// `free`'s walk W (§4.2 free, step 3): every node by (T ascending, i descending); `null` in
  /// `compact`. The stack pass (§4.8) reads it.
  Int32List? freeOrder;

  /// `free`'s clamped T(i) (§4.2 free, step 2); `null` in `compact`.
  Int64List? freeT;

  // ---- §4.3

  /// lane(i).
  late Int32List lane;

  /// L, the largest lane + 1.
  late int laneCount;

  /// The per-lane y-lists' CSR offsets (L + 1).
  late Int32List laneYStart;

  /// The y values of every lane's nodes, ascending per lane.
  late Int64List laneYs;

  /// The requested model's visit order: (y, priority, i) ascending.
  late final Int32List visitOrder;

  // ---- §4.4 / §4.5

  /// `blocked` per layout edge (0 or 1).
  late Uint8List blocked;

  /// The route per layout edge ([routeStraight], [routeMerge] or [routeBranchOff]).
  late Uint8List routes;

  // ---- §4.6

  /// col(i), which equals lane(i) (§4.3, amended 2026-11-10). The graph layout lab replaces it.
  late Int32List col;

  /// §4.1 + §4.2, bench phase `layering`: the requested mode's rows (and `free`'s buckets), then
  /// the other model's rows.
  void layering() {
    _prep();
    y = Int64List(n);
    final other = Int64List(n);
    switch (mode) {
      case LayoutMode.compact:
        _compactRows(y);
        final (_, Int64List t) = _freeRows(other);
        clampedT = t;
        modelY = [y, other];
      case LayoutMode.free:
        _layerFree();
        clampedT = freeT!;
        _compactRows(other);
        modelY = [other, y];
    }
  }

  /// Every node's local day key (§4.2 free, step 4's dk of its clamped T at the input's UTC
  /// offset; Story 4.14), [GraphGridView.noDay] for a root.
  Int64List nodeDays() {
    final days = Int64List(n);
    final Uint8List isRoot = input.isRoot;
    final int utcOffsetMin = input.utcOffsetMin;
    for (var i = 0; i < n; i++) {
      days[i] = isRoot[i] != 0 ? GraphGridView.noDay : dayKey(clampedT[i], utcOffsetMin);
    }
    return days;
  }

  void _prep() {
    final Int32List parStart = input.parStart;
    final Int32List parIdx = input.parIdx;
    final Uint8List parKind = input.parKind;
    final lpStart = Int32List(n + 1);
    var e = 0;
    for (var i = 0; i < n; i++) {
      lpStart[i] = e;
      for (int k = parStart[i]; k < parStart[i + 1]; k++) {
        if (parIdx[k] >= 0) {
          e++;
        }
      }
    }
    lpStart[n] = e;
    final edgeCount = e;
    final edgeParent = Int32List(edgeCount);
    final edgeChild = Int32List(edgeCount);
    final edgeKind = Uint8List(edgeCount);
    final fp = Int32List(n);
    final childCount = Int32List(n + 1);
    e = 0;
    for (var i = 0; i < n; i++) {
      fp[i] = -1;
      for (int k = parStart[i]; k < parStart[i + 1]; k++) {
        final int p = parIdx[k];
        if (p < 0) {
          continue;
        }
        if (fp[i] < 0) {
          fp[i] = p;
        }
        edgeParent[e] = p;
        edgeChild[e] = i;
        edgeKind[e] = parKind[k];
        childCount[p]++;
        e++;
      }
    }
    // Children CSR: a scan over the edges, which are ordered by child, keeps every C(j) ascending.
    final chStart = Int32List(n + 1);
    var sum = 0;
    for (var j = 0; j < n; j++) {
      chStart[j] = sum;
      sum += childCount[j];
    }
    chStart[n] = sum;
    final cursor = Int32List.fromList(chStart);
    final chIdx = Int32List(edgeCount);
    for (var e = 0; e < edgeCount; e++) {
      chIdx[cursor[edgeParent[e]]++] = edgeChild[e];
    }
    this.edgeCount = edgeCount;
    this.lpStart = lpStart;
    this.edgeParent = edgeParent;
    this.edgeChild = edgeChild;
    this.edgeKind = edgeKind;
    this.fp = fp;
    this.chStart = chStart;
    this.chIdx = chIdx;
  }

  /// §4.2 compact into [y].
  void _compactRows(Int64List y) {
    final Int32List lpStart = this.lpStart;
    final Int32List edgeParent = this.edgeParent;
    for (int i = n - 1; i >= 0; i--) {
      var r = 0;
      for (int e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final int v = y[edgeParent[e]] + 1;
        if (v > r) {
          r = v;
        }
      }
      y[i] = r;
    }
  }

  void _layerFree() {
    final (Int32List order, Int64List t) = _freeRows(y);
    _freeDayBuckets(order, t);
    freeOrder = order;
    freeT = t;
  }

  /// §4.2 free, steps 1–3, into [y] (U = 16 whatever [mode] is); returns the walk and the clamped T.
  (Int32List, Int64List) _freeRows(Int64List y) {
    final Int32List lpStart = this.lpStart;
    final Int32List edgeParent = this.edgeParent;
    final Int64List ts = input.ts;
    final Uint8List hasTs = input.hasTs;
    final Uint8List isRoot = input.isRoot;
    final int u = modelUnits[1];

    // 1: tmin over every non-null ts.
    var tmin = 0;
    var found = false;
    for (var i = 0; i < n; i++) {
      if (hasTs[i] != 0 && (!found || ts[i] < tmin)) {
        tmin = ts[i];
        found = true;
      }
    }
    // 2: clamp.
    final t = Int64List(n);
    for (int i = n - 1; i >= 0; i--) {
      int v = (isRoot[i] != 0 || hasTs[i] == 0) ? tmin : ts[i];
      for (int e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final int w = t[edgeParent[e]];
        if (w > v) {
          v = w;
        }
      }
      t[i] = v;
    }
    // 3: walk by (T asc, i desc): indices start descending, the stable sort keeps them so on ties.
    final order = Int32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = n - 1 - i;
    }
    sortIndicesStable(order, t);
    var prevY = 0;
    var prevT = 0;
    for (var k = 0; k < n; k++) {
      final int i = order[k];
      int r = k == 0 ? 0 : prevY + freeStep(prevT, t[i], input.utcOffsetMin);
      for (int e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final int v = y[edgeParent[e]] + u;
        if (v > r) {
          r = v;
        }
      }
      y[i] = r;
      prevY = r;
      prevT = t[i];
    }
    return (order, t);
  }

  /// Step 4 of §4.2 free: one `day` bucket per local day of the clamped T of every non-root node.
  /// T and y never decrease in the walk [order], so a bucket's members are consecutive there
  /// (roots skipped): one pass counts the buckets, one fills them, ascending, with no sort.
  void _freeDayBuckets(Int32List order, Int64List t) {
    final Int64List y = this.y;
    final Uint8List isRoot = input.isRoot;
    final int utcOffsetMin = input.utcOffsetMin;
    var count = 0;
    var last = 0;
    for (var k = 0; k < n; k++) {
      final int i = order[k];
      if (isRoot[i] != 0) {
        continue;
      }
      final int key = dayKey(t[i], utcOffsetMin);
      if (count == 0 || key != last) {
        count++;
        last = key;
      }
    }
    final bucketValue = Int64List(count);
    final bucketStart = Int64List(count);
    final bucketEnd = Int64List(count);
    var b = -1;
    for (var k = 0; k < n; k++) {
      final int i = order[k];
      if (isRoot[i] != 0) {
        continue;
      }
      final int key = dayKey(t[i], utcOffsetMin);
      if (b < 0 || key != bucketValue[b]) {
        b++;
        bucketValue[b] = key;
        bucketStart[b] = y[i];
      }
      bucketEnd[b] = y[i];
    }
    this.bucketValue = bucketValue;
    this.bucketStart = bucketStart;
    this.bucketEnd = bucketEnd;
  }

  /// §4.3 (Branch columns, amended 2026-11-10), bench phase `lanes`: every branch's column on the
  /// requested mode's rows, which sets lane and col. The graph layout lab's `chooseColumns` at its
  /// defaults, in typed arrays.
  void chooseColumns() {
    final Int64List y = this.y;
    final int u = unit;
    final Int32List fp = this.fp;
    final Int32List priority = input.priority;
    final Int32List cont = continuations();

    // Parents have larger indices, so this descending scan numbers a branch at its bottom card: the
    // branch a branch forks from has the smaller number.
    final branchOf = Int32List(n);
    final bottom = Int32List(n);
    var branches = 0;
    for (int i = n - 1; i >= 0; i--) {
      final int f = fp[i];
      if (f >= 0 && cont[f] == i) {
        branchOf[i] = branchOf[f];
      } else {
        bottom[branches] = i;
        branchOf[i] = branches++;
      }
    }

    // The node with the least (priority, y); of several, the highest index.
    var best = 0;
    for (var i = 1; i < n; i++) {
      if (priority[i] < priority[best] || (priority[i] == priority[best] && y[i] <= y[best])) {
        best = i;
      }
    }
    final int main = n == 0 ? -1 : branchOf[best];

    final lo = Int64List(branches);
    final hi = Int64List(branches);
    final from = Int32List(branches);
    for (var b = 0; b < branches; b++) {
      final int bot = bottom[b];
      final int f = fp[bot];
      lo[b] = f >= 0 ? y[f] + u : y[bot];
      hi[b] = y[bot];
      from[b] = f >= 0 ? branchOf[f] : main;
    }
    for (var i = 0; i < n; i++) {
      final int b = branchOf[i];
      if (y[i] > hi[b]) {
        hi[b] = y[i];
      }
    }
    final elsewhere = Uint8List(branches);
    for (var e = 0; e < edgeCount; e++) {
      final int child = edgeChild[e];
      if (e == lpStart[child]) {
        continue;
      }
      final int b = branchOf[edgeParent[e]];
      if (y[child] - u > hi[b]) {
        hi[b] = y[child] - u;
      }
      if (branchOf[child] != from[b]) {
        elsewhere[b] = 1;
      }
    }

    final depth = Int64List(branches);
    final length = Int64List(branches);
    final bottomY = Int64List(branches);
    final bottomPriority = Int32List(branches);
    final order = Int32List(branches);
    for (var b = 0; b < branches; b++) {
      if (b != main) {
        depth[b] = from[b] == main || elsewhere[b] != 0 ? 1 : depth[from[b]] + 1;
      }
      length[b] = hi[b] - lo[b];
      bottomY[b] = y[bottom[b]];
      bottomPriority[b] = priority[bottom[b]];
      order[b] = branches - 1 - b; // ascending bottom card index, the sorts' last tie-break
    }
    // Only the main branch has depth 0, so it comes first with no special key.
    sortIndicesStable(order, bottomY, second: bottomPriority);
    sortIndicesStable(order, length);
    sortIndicesStable(order, hi);
    sortIndicesStable(order, depth);

    // Column 0 is the main branch's: the scan never returns it for another branch.
    final intervals = LaneIntervals(branches + 1);
    final columnOf = Int32List(branches);
    for (var k = 0; k < branches; k++) {
      final int b = order[k];
      if (b == main) {
        continue;
      }
      final int start = lo[b];
      final int end = hi[b] + u;
      final int dock = elsewhere[b] != 0 ? 0 : columnOf[from[b]];
      var column = -1;
      // shortcut: the scan walks outward over the occupied columns, so C branches over K columns cost O(C·K) probes;
      // a skip structure over the columns would help if a wide real history ever shows it (§5, amended 2026-11-10).
      for (var d = 0; column < 0; d++) {
        if (dock - d >= 1 && !intervals.overlaps(dock - d, start, end)) {
          column = dock - d;
        } else if (d > 0 && !intervals.overlaps(dock + d, start, end)) {
          column = dock + d;
        }
      }
      intervals.insert(column, start, end);
      columnOf[b] = column;
    }

    final lane = Int32List(n);
    var laneCount = 0;
    for (var i = 0; i < n; i++) {
      final int column = columnOf[branchOf[i]];
      lane[i] = column;
      if (column >= laneCount) {
        laneCount = column + 1;
      }
    }
    visitOrder = _visitOrder(y);
    _adoptLanes(lane, laneCount);
    col = lane;
  }

  /// cont(j) of §4.3: the child with fp = j and the least key (priority, index), or −1.
  Int32List continuations() {
    final Int32List priority = input.priority;
    final cont = Int32List(n)..fillRange(0, n, -1);
    for (var i = 0; i < n; i++) {
      final int f = fp[i];
      if (f < 0) {
        continue;
      }
      final int c = cont[f];
      if (c < 0 || priority[i] < priority[c]) {
        cont[f] = i;
      }
    }
    return cont;
  }

  /// The nodes by (y, priority, i) ascending.
  Int32List _visitOrder(Int64List y) {
    final order = Int32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = i;
    }
    sortIndicesStable(order, y, second: input.priority);
    return order;
  }

  /// Sets [lane] and builds the per-lane y-lists; the visit order is ascending in y, so each list
  /// comes out sorted.
  void _adoptLanes(Int32List lane, int laneCount) {
    final (Int32List laneYStart, Int64List laneYs) = _laneYLists(lane, laneCount, visitOrder, y);
    this.lane = lane;
    this.laneCount = laneCount;
    this.laneYStart = laneYStart;
    this.laneYs = laneYs;
  }

  /// Per lane the values of [y], ascending ([order] is ascending in y); CSR.
  (Int32List, Int64List) _laneYLists(Int32List lane, int laneCount, Int32List order, Int64List y) {
    final laneYStart = Int32List(laneCount + 1);
    for (var i = 0; i < n; i++) {
      laneYStart[lane[i] + 1]++;
    }
    for (var l = 0; l < laneCount; l++) {
      laneYStart[l + 1] += laneYStart[l];
    }
    final cursor = Int32List.fromList(laneYStart);
    final laneYs = Int64List(n);
    for (var k = 0; k < n; k++) {
      final int i = order[k];
      laneYs[cursor[lane[i]]++] = y[i];
    }
    return (laneYStart, laneYs);
  }

  /// §4.4, bench phase `blocked`.
  void markBlocked() {
    blocked = _blockedFrom(y, laneYStart, laneYs);
  }

  Uint8List _blockedFrom(Int64List y, Int32List laneYStart, Int64List laneYs) {
    final blocked = Uint8List(edgeCount);
    final Int32List lane = this.lane;
    for (var e = 0; e < edgeCount; e++) {
      final int p = edgeParent[e];
      final int i = edgeChild[e];
      final int lp = lane[p];
      if (lane[i] == lp) {
        continue;
      }
      // First y > y(p) in lane(p)'s y-list.
      final int yp = y[p];
      int lo = laneYStart[lp];
      int hi = laneYStart[lp + 1];
      final end = hi;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (laneYs[mid] <= yp) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      if (lo < end && laneYs[lo] <= y[i]) {
        blocked[e] = 1;
      }
    }
    return blocked;
  }

  /// §4.5, bench phase `routing`.
  void route() {
    routes = _routesFrom(blocked);
  }

  Uint8List _routesFrom(Uint8List blocked) {
    final routes = Uint8List(edgeCount);
    final Int32List lane = this.lane;
    for (var e = 0; e < edgeCount; e++) {
      final int p = edgeParent[e];
      final int i = edgeChild[e];
      if (lane[p] == lane[i]) {
        routes[e] = routeStraight;
      } else if (e - lpStart[i] >= 1 && blocked[e] == 0) {
        routes[e] = routeMerge;
      } else {
        routes[e] = routeBranchOff;
      }
    }
    return routes;
  }

  /// The grid buffer of the finished layout.
  Uint8List toGrid() {
    var maxRow = 0;
    var maxLane = 0;
    for (var i = 0; i < n; i++) {
      if (y[i] > maxRow) {
        maxRow = y[i];
      }
      if (lane[i] > maxLane) {
        maxLane = lane[i];
      }
    }
    return writeGraphGrid(
      mode: mode,
      unit: unit,
      rows: n == 0 ? 0 : maxRow + unit,
      lanes: n == 0 ? 0 : maxLane + 1,
      nodeRows: y,
      nodeLanes: lane,
      nodeCols: col,
      nodeDays: nodeDays(),
      edgeFroms: edgeParent,
      edgeTos: edgeChild,
      edgeKinds: edgeKind,
      edgeRoutes: routes,
      edgeBlocked: blocked,
      bucketValues: bucketValue,
      bucketStarts: bucketStart,
      bucketEnds: bucketEnd,
    );
  }
}

/// Per column, its reservations as disjoint half-open intervals [a, b), ascending by start (§4.3,
/// Branch columns). Because they are disjoint, [a, b) overlaps one of them iff the last one starting
/// before b ends after a.
///
/// shortcut: an insert shifts the column's tail, O(column size); an array-backed balanced tree would
/// make it O(log n) if a measurement ever shows the shift (spec-4-17 § Measurements).
final class LaneIntervals {
  /// Empty lists for up to [n] columns.
  LaneIntervals(int n) : _rec = List<Int64List?>.filled(n, null), _len = Int32List(n);

  /// Record layout: a, b.
  static const _w = 2;

  final List<Int64List?> _rec;
  final Int32List _len;

  /// Whether [a, b) overlaps an interval of [lane].
  bool overlaps(int lane, int a, int b) {
    final Int64List? r = _rec[lane];
    if (r == null) {
      return false;
    }
    final int before = _countBefore(r, _len[lane], b);
    return before > 0 && r[(before - 1) * _w + 1] > a;
  }

  /// Stores [a, b) in [lane]; it must overlap no stored interval.
  void insert(int lane, int a, int b) {
    final int len = _len[lane];
    Int64List? r = _rec[lane];
    if (r == null || (len + 1) * _w > r.length) {
      final grown = Int64List((len < 4 ? 8 : 2 * len) * _w);
      if (r != null) {
        grown.setRange(0, len * _w, r);
      }
      _rec[lane] = r = grown;
    }
    final int pos = _countBefore(r, len, a);
    r.setRange((pos + 1) * _w, (len + 1) * _w, r, pos * _w);
    r[pos * _w] = a;
    r[pos * _w + 1] = b;
    _len[lane] = len + 1;
  }

  /// The number of the first [len] records of [r] whose start is below [x].
  static int _countBefore(Int64List r, int len, int x) {
    var lo = 0;
    var hi = len;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (r[mid * _w] < x) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
