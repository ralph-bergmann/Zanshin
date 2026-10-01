// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'compact_order.dart';
import 'graph_grid_view.dart';
import 'layout_input.dart';
import 'layout_request.dart';
import 'sort.dart';
import 'stacks.dart';

// The product layout engine (Story 4.11): docs/graph-layout.md §4 for the shipped scope — the
// modes compact | free and the lane orders greedy | compact — ported from the spike's Dart
// reference (spikes/graph-layout-ab/dart/lib/src/layout.dart) and byte-identical to it. Flat
// typed arrays and CSR adjacency, no per-node objects, monomorphic sorts (sort.dart).

/// Stands in for −∞ in the lane packing (every real value is ≥ 0).
const _negInf = -0x4000000000000000;

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

/// Lays out [input] (docs/graph-layout.md §4) in [mode] with the lane [order], whose `compact`
/// search may spend [budget] work units, and returns the grid buffer [GraphGridView] reads.
///
/// With [stacks] (Story 4.13) the finished layout's linear runs are grouped by §4.8 — the columns
/// stay, only rows move — and the grid has format version [GraphGridView.stackFormatVersion];
/// without it the result is 4.11's, format version 1, byte for byte.
///
/// Validates first ([validateLayoutInput], then [validateStackInput]): a contract violation
/// throws [LayoutContractException] and lays out nothing. [onPhaseEnd] runs after each of the
/// five timed phases (layering, lanes, blocked, routing, ordering; §8.2) and, with [stacks], after
/// the sixth (stacks); writing the grid is not timed.
Uint8List computeGraphGrid(
  LayoutInput input, {
  required LayoutMode mode,
  required LaneOrder order,
  required int budget,
  StackInput? stacks,
  void Function()? onPhaseEnd,
}) {
  validateLayoutInput(input);
  if (stacks != null) {
    validateStackInput(stacks, input.n);
  }
  final engine = LayoutEngine(input, mode)..layering();
  onPhaseEnd?.call();
  engine.packLanes();
  onPhaseEnd?.call();
  engine.markBlocked();
  onPhaseEnd?.call();
  engine.route();
  onPhaseEnd?.call();
  engine.orderLanes(order, budget: budget);
  onPhaseEnd?.call();
  if (stacks == null) {
    return engine.toGrid(order);
  }
  final grouped = StackLayout(engine, stacks)..run();
  onPhaseEnd?.call();
  return grouped.toGrid(order);
}

/// The layout state of docs/graph-layout.md §4, one phase per method; the phases run in order:
/// [layering], [packLanes], [markBlocked], [route], [orderLanes]. Public for the engine's tests;
/// callers use [computeGraphGrid].
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

  /// pos(j, child) per entry of [chIdx].
  late final Int32List chPos;

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

  // ---- §4.3 (re-assigned by the `compact` order, §4.7)

  /// lane(i).
  late Int32List lane;

  /// L, the largest lane + 1.
  late int laneCount;

  /// The per-lane y-lists' CSR offsets (L + 1).
  late Int32List laneYStart;

  /// The y values of every lane's nodes, ascending per lane.
  late Int64List laneYs;

  /// The packing's visit order: (y, priority, i) ascending.
  late final Int32List visitOrder;

  // ---- §4.4 / §4.5 (recomputed by the `compact` order)

  /// `blocked` per layout edge (0 or 1).
  late Uint8List blocked;

  /// The route per layout edge ([routeStraight], [routeMerge] or [routeBranchOff]).
  late Uint8List routes;

  // ---- §4.6

  /// col(i).
  late final Int32List col;

  /// §4.1 + §4.2, bench phase `layering`.
  void layering() {
    _prep();
    y = Int64List(n);
    switch (mode) {
      case LayoutMode.compact:
        _layerCompact();
      case LayoutMode.free:
        _layerFree();
    }
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
    final chPos = Int32List(edgeCount);
    for (var e = 0; e < edgeCount; e++) {
      final int p = edgeParent[e];
      final int c = edgeChild[e];
      final int slot = cursor[p]++;
      chIdx[slot] = c;
      chPos[slot] = e - lpStart[c];
    }
    this.edgeCount = edgeCount;
    this.lpStart = lpStart;
    this.edgeParent = edgeParent;
    this.edgeChild = edgeChild;
    this.edgeKind = edgeKind;
    this.fp = fp;
    this.chStart = chStart;
    this.chIdx = chIdx;
    this.chPos = chPos;
  }

  void _layerCompact() {
    final Int64List y = this.y;
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
    final Int64List y = this.y;
    final Int32List lpStart = this.lpStart;
    final Int32List edgeParent = this.edgeParent;
    final Int64List ts = input.ts;
    final Uint8List hasTs = input.hasTs;
    final Uint8List isRoot = input.isRoot;
    final int u = unit;

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
      int r = k == 0 ? 0 : prevY + freeGap(t[i] - prevT);
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
    _freeDayBuckets(order, t);
    freeOrder = order;
    freeT = t;
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

  /// §4.3, bench phase `lanes`.
  void packLanes() {
    final Int64List y = this.y;
    final Int32List fp = this.fp;
    final Int32List priority = input.priority;
    final Int32List chStart = this.chStart;
    final Int32List chIdx = this.chIdx;
    final Int32List chPos = this.chPos;
    final int u = unit;

    // cont(j): the child with fp = j and the least key (priority, index).
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

    // Visit order: (y, priority, i) ascending.
    final order = Int32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = i;
    }
    sortIndicesStable(order, y, second: priority);

    // Per lane: largest b′ (+ its owner) and second-largest b′; a min-segment-tree over the
    // lanes' largest b′ answers "least lane whose largest b′ ≤ a".
    final max1 = Int64List(n)..fillRange(0, n, _negInf);
    final max2 = Int64List(n)..fillRange(0, n, _negInf);
    final own1 = Int32List(n)..fillRange(0, n, -1);
    var size = 1;
    while (size < n) {
      size <<= 1;
    }
    final tree = Int64List(2 * size)..fillRange(0, 2 * size, _negInf);

    final lane = Int32List(n);
    var laneCount = 0;
    for (var k = 0; k < n; k++) {
      final int i = order[k];
      final int yi = y[i];
      var end = yi;
      final int c = cont[i];
      if (c >= 0) {
        final int v = y[c] - u;
        if (v > end) {
          end = v;
        }
      }
      for (int s = chStart[i]; s < chStart[i + 1]; s++) {
        if (chPos[s] >= 1) {
          final int v = y[chIdx[s]] - u;
          if (v > end) {
            end = v;
          }
        }
      }
      final int f = fp[i];
      final int a = f >= 0 ? y[f] + u : yi;
      final int b = end + 2 * u;

      var l = -1;
      if (f >= 0 && cont[f] == i) {
        final int lf = lane[f];
        final int others = own1[lf] == f ? max2[lf] : max1[lf];
        if (others <= a) {
          l = lf;
        }
      }
      if (l < 0) {
        // First fit: the leftmost leaf whose value is ≤ a (an unused lane always qualifies).
        var node = 1;
        while (node < size) {
          node = tree[2 * node] <= a ? 2 * node : 2 * node + 1;
        }
        l = node - size;
      }

      if (b > max1[l]) {
        max2[l] = max1[l];
        max1[l] = b;
        own1[l] = i;
        int node = size + l;
        tree[node] = b;
        node >>= 1;
        while (node >= 1) {
          final int left = tree[2 * node];
          final int right = tree[2 * node + 1];
          tree[node] = left < right ? left : right;
          node >>= 1;
        }
      } else if (b > max2[l]) {
        max2[l] = b;
      }
      lane[i] = l;
      if (l >= laneCount) {
        laneCount = l + 1;
      }
    }
    visitOrder = order;
    _adoptLanes(lane, laneCount);
  }

  /// Sets [lane] and builds the per-lane y-lists; the visit order is ascending in y, so each list
  /// comes out sorted.
  void _adoptLanes(Int32List lane, int laneCount) {
    final Int32List order = visitOrder;
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
    this.lane = lane;
    this.laneCount = laneCount;
    this.laneYStart = laneYStart;
    this.laneYs = laneYs;
  }

  /// §4.4, bench phase `blocked`.
  void markBlocked() {
    final blocked = Uint8List(edgeCount);
    final Int64List y = this.y;
    final Int32List lane = this.lane;
    final Int32List laneYStart = this.laneYStart;
    final Int64List laneYs = this.laneYs;
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
    this.blocked = blocked;
  }

  /// §4.5, bench phase `routing`.
  void route() {
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
    this.routes = routes;
  }

  /// §4.6 / §4.7, bench phase `ordering`; the `compact` order's search may spend [budget] work units.
  void orderLanes(LaneOrder order, {required int budget}) {
    switch (order) {
      case LaneOrder.greedy:
        col = Int32List.fromList(lane);
      case LaneOrder.compact:
        final Int32List newLane = compactColumns(this, budget: budget);
        var count = 0;
        for (var i = 0; i < n; i++) {
          if (newLane[i] >= count) {
            count = newLane[i] + 1;
          }
        }
        _adoptLanes(newLane, count);
        markBlocked();
        route();
        col = Int32List.fromList(lane);
    }
  }

  /// The grid buffer of the finished layout, laid out with [order] (the header echoes it).
  Uint8List toGrid(LaneOrder order) {
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
      order: order,
      unit: unit,
      rows: n == 0 ? 0 : maxRow + unit,
      lanes: n == 0 ? 0 : maxLane + 1,
      nodeRows: y,
      nodeLanes: lane,
      nodeCols: col,
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
