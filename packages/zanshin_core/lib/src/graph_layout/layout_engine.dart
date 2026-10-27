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
// typed arrays and CSR adjacency, no per-node objects, monomorphic sorts (sort.dart). Since Story
// 4.14 it always lays out joint columns (§4.3 / §4.7, amended 2026-10-27): the reference's
// `--columns joint`.

/// Stands in for −∞ in the lane packing (every real value is ≥ 0).
const _negInf = -0x4000000000000000;

/// U of each vertical model of the joint columns (§4.3, amended 2026-10-27): model 0 is `compact`,
/// model 1 is `free`.
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

/// Lays out [input] (docs/graph-layout.md §4) in [mode] with the lane [order], whose `compact`
/// search may spend [budget] work units, and returns the grid buffer [GraphGridView] reads.
///
/// Lanes and columns are joint (Story 4.14, §4.3 / §4.7 amended 2026-10-27): the same for both
/// modes, so a `compact` and a `free` grid of one input differ only in rows, routes, `blocked` and
/// buckets. Every grid carries each node's local day key ([GraphGridView.nodeDays]).
///
/// With [stacks] (Story 4.13) the finished layout's linear runs are grouped by §4.8 — the columns
/// stay, only rows move — and the grid has format version [GraphGridView.stackFormatVersion];
/// without it, format version [GraphGridView.formatVersion].
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

  /// The model index of [mode] (0 `compact`, 1 `free`; [modelUnits]).
  int get requestedModel => mode == LayoutMode.compact ? 0 : 1;

  /// Per model its y — the requested one is [y] itself — set by [layering] (§4.3, amended
  /// 2026-10-27: both models are laid out for the joint packing).
  late final List<Int64List> modelY;

  /// Per model its visit order (y, priority, i) ascending, set by [packLanes].
  late final List<Int32List> modelVisit;

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

  /// The requested model's visit order: (y, priority, i) ascending.
  late final Int32List visitOrder;

  // ---- §4.4 / §4.5 (recomputed by the `compact` order)

  /// `blocked` per layout edge (0 or 1).
  late Uint8List blocked;

  /// The route per layout edge ([routeStraight], [routeMerge] or [routeBranchOff]).
  late Uint8List routes;

  // ---- §4.6

  /// col(i).
  late final Int32List col;

  /// §4.1 + §4.2, bench phase `layering`: the requested mode's rows (and `free`'s buckets), then
  /// the other model's rows for the joint packing.
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

  /// §4.3, bench phase `lanes` — the joint packing (amended 2026-10-27, Story 4.14): a node fits a
  /// lane iff, in BOTH models, its interval is disjoint from every interval there except the
  /// excluded owner's. Packs once in each model's visit order and keeps the packing with fewer
  /// lanes, `compact`'s on a tie, so the lanes do not depend on [mode].
  void packLanes() {
    final Int32List cont = continuations();
    final ia = <Int64List>[];
    final ib = <Int64List>[];
    final visits = <Int32List>[];
    for (var k = 0; k < 2; k++) {
      final (Int64List a, Int64List b) = _intervals(modelY[k], modelUnits[k], cont);
      ia.add(a);
      ib.add(b);
      visits.add(_visitOrder(modelY[k]));
    }
    final (Int32List lane0, int count0) = _packVisit(0, visits[0], cont, ia, ib);
    final (Int32List lane1, int count1) = _packVisit(1, visits[1], cont, ia, ib);
    modelVisit = visits;
    visitOrder = visits[requestedModel];
    if (count0 <= count1) {
      _adoptLanes(lane0, count0);
    } else {
      _adoptLanes(lane1, count1);
    }
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

  /// Every node's §4.3 interval [a, b) over the rows [y] in units of [u].
  (Int64List, Int64List) _intervals(Int64List y, int u, Int32List cont) {
    final Int32List chStart = this.chStart;
    final Int32List chIdx = this.chIdx;
    final Int32List chPos = this.chPos;
    final a = Int64List(n);
    final b = Int64List(n);
    for (var i = 0; i < n; i++) {
      int end = y[i];
      final int c = cont[i];
      if (c >= 0 && y[c] - u > end) {
        end = y[c] - u;
      }
      for (int s = chStart[i]; s < chStart[i + 1]; s++) {
        if (chPos[s] >= 1 && y[chIdx[s]] - u > end) {
          end = y[chIdx[s]] - u;
        }
      }
      final int f = fp[i];
      a[i] = f >= 0 ? y[f] + u : y[i];
      b[i] = end + 2 * u;
    }
    return (a, b);
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

  /// One joint packing (§4.3, amended 2026-10-27), visiting [order] (model [v]'s). In model v every
  /// stored interval starts at or below the visited node's y, so the per-lane top-two b′ and the
  /// segment tree answer the overlap; the other model w needs [LaneIntervals]' general test. First
  /// fit walks "the least lane ≥ s whose largest b′ ≤ a" and moves past a lane w rejects.
  (Int32List, int) _packVisit(int v, Int32List order, Int32List cont, List<Int64List> ia, List<Int64List> ib) {
    final int w = 1 - v;
    final Int64List av = ia[v];
    final Int64List bv = ib[v];
    final Int64List aw = ia[w];
    final Int64List bw = ib[w];
    final max1 = Int64List(n)..fillRange(0, n, _negInf);
    final max2 = Int64List(n)..fillRange(0, n, _negInf);
    final own1 = Int32List(n)..fillRange(0, n, -1);
    var size = 1;
    while (size < n) {
      size <<= 1;
    }
    final tree = Int64List(2 * size)..fillRange(0, 2 * size, _negInf);
    final other = LaneIntervals(n);

    final lane = Int32List(n);
    var laneCount = 0;
    for (var k = 0; k < n; k++) {
      final int i = order[k];
      final int a = av[i];
      final int b = bv[i];
      var l = -1;
      final int f = fp[i];
      if (f >= 0 && cont[f] == i) {
        final int lf = lane[f];
        final int others = own1[lf] == f ? max2[lf] : max1[lf];
        if (others <= a && !other.overlaps(lf, aw[i], bw[i], f)) {
          l = lf;
        }
      }
      if (l < 0) {
        var s = 0;
        while (true) {
          l = leastLaneFrom(tree, size, s, a);
          if (!other.overlaps(l, aw[i], bw[i], -1)) {
            break;
          }
          s = l + 1;
        }
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
      other.insert(l, aw[i], bw[i], i);
      lane[i] = l;
      if (l >= laneCount) {
        laneCount = l + 1;
      }
    }
    return (lane, laneCount);
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

  /// The routes of model [k] (§4.4 + §4.5 over that model's y) on the current lanes; the requested
  /// model's are [routes]. The `compact` order reads both (§4.7, amended 2026-10-27).
  Uint8List routesOf(int k) {
    if (k == requestedModel) {
      return routes;
    }
    final (Int32List start, Int64List ys) = _laneYLists(lane, laneCount, modelVisit[k], modelY[k]);
    return _routesFrom(_blockedFrom(modelY[k], start, ys));
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

/// The least leaf ≥ [s] of the min-segment-tree [tree] (leaves from index [size]) whose value is
/// ≤ [a]. The caller guarantees one exists: an unused lane, value −∞, at or after [s].
int leastLaneFrom(Int64List tree, int size, int s, int a) {
  int node = size + s;
  while (tree[node] > a) {
    // The next subtree to the right: climb while a right child, then step to the right sibling.
    while (node & 1 == 1) {
      node >>= 1;
    }
    node++;
  }
  while (node < size) {
    node = tree[2 * node] <= a ? 2 * node : 2 * node + 1;
  }
  return node - size;
}

/// Per lane, its intervals [a, b) in the model the joint packing does not visit (§4.3, amended
/// 2026-10-27), ascending by start, each with the prefix's largest b (and its owner) and
/// second-largest b. [a, b) overlaps an interval of the lane other than x's iff, among the ones
/// starting before b, the largest end other than x's exceeds a. Intervals of one lane overlap only
/// for a node and its continuation child, so the prefix maximum (not the last end) is needed.
///
/// shortcut: an insert shifts the lane's tail, O(lane size); an array-backed balanced tree would
/// make it O(log n) if a measurement ever shows the shift (spec-4-14 § Measurements).
final class LaneIntervals {
  /// Empty lists for up to [n] lanes.
  LaneIntervals(int n) : _rec = List<Int64List?>.filled(n, null), _len = Int32List(n);

  /// Record layout: a, b, owner, prefix max b, its owner, prefix second-largest b.
  static const _w = 6;

  final List<Int64List?> _rec;
  final Int32List _len;

  /// Whether [a, b) overlaps an interval of [lane] not owned by [except].
  bool overlaps(int lane, int a, int b, int except) {
    final Int64List? r = _rec[lane];
    if (r == null) {
      return false;
    }
    final int before = _countBefore(r, _len[lane], b);
    if (before == 0) {
      return false;
    }
    final int base = (before - 1) * _w;
    return (r[base + 4] == except ? r[base + 5] : r[base + 3]) > a;
  }

  /// Stores [a, b), owned by [owner], in [lane].
  void insert(int lane, int a, int b, int owner) {
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
    r[pos * _w + 2] = owner;
    int m1 = pos == 0 ? _negInf : r[(pos - 1) * _w + 3];
    int o1 = pos == 0 ? -1 : r[(pos - 1) * _w + 4];
    int m2 = pos == 0 ? _negInf : r[(pos - 1) * _w + 5];
    for (var k = pos; k <= len; k++) {
      final int base = k * _w;
      final int bk = r[base + 1];
      if (bk > m1) {
        m2 = m1;
        m1 = bk;
        o1 = r[base + 2];
      } else if (bk > m2) {
        m2 = bk;
      }
      r[base + 3] = m1;
      r[base + 4] = o1;
      r[base + 5] = m2;
    }
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
