import 'dart:typed_data';

import 'compact_order.dart';
import 'input.dart';
import 'lane_order.dart';
import 'stacks.dart';

/// Vertical model (SPEC §0).
enum Mode { compact, time, free }

/// Lane → column mapping (SPEC §4.6). `compact` (SPEC §4.7) is Dart-only: it re-assigns greedy's
/// continuation chains to columns, so its lanes, and possibly its `blocked` flags, differ from
/// greedy's; its col = lane.
enum LaneOrder { greedy, optimized, compact }

/// Edge routes (SPEC §4.5); the indices are the digest's r (SPEC §8.4).
const int routeStraight = 0;
const int routeMerge = 1;
const int routeBranchOff = 2;
const List<String> routeNames = ['straight', 'merge', 'branch_off'];

/// Bucket kinds (SPEC §3).
const int bucketRoot = 0;
const int bucketAge = 1;
const int bucketDay = 2;
const List<String> bucketKindNames = ['root', 'age', 'day'];

/// The age ladder in minutes (SPEC §4.2 time.1).
const List<int> ladderMinutes = [10, 20, 40, 60, 120, 240, 480, 720];

/// ROOT bucket key: below every real key (real keys lie within about ±2^54).
const int rootKey = -0x7FFFFFFFFFFFFFFF - 1;

/// Stands in for −∞ in the lane packing (every real value is ≥ 0).
const int _negInf = -0x4000000000000000;

const int _minute = 60000;
const int _day = 86400000;

/// Floor division for b > 0 (SPEC §1): Dart's `%` is already non-negative.
int floorDiv(int a, int b) => (a - a % b) ~/ b;

/// The time bucket key b(i) of one timestamp (SPEC §4.2 time.1), for a node that is not ROOT.
int timeBucketKey(int ts, int nowMs, int utcOffsetMin) {
  final age = nowMs - ts;
  for (final m in ladderMinutes) {
    if (age <= m * _minute) return nowMs - m * _minute;
  }
  return dayKey(ts, utcOffsetMin);
}

/// The local-midnight instant (epoch ms) of the calendar day holding [t] at the fixed offset (D7).
/// Shared by `time` (step 1) and `free`'s day buckets (step 4, amended 2026-10-01), which must not
/// go through [timeBucketKey]'s `now_ms` ladder.
int dayKey(int t, int utcOffsetMin) {
  final off = utcOffsetMin * _minute;
  return floorDiv(t + off, _day) * _day - off;
}

/// `free` mode gap in units (SPEC §4.2 free.3), g ≥ 0.
int freeGap(int g) {
  final x = 1 + floorDiv(g, _minute);
  final k = x.bitLength - 1;
  final l2 = 256 * k + ((x - (1 << k)) * 256) ~/ (1 << k);
  final gap = (2 * l2) ~/ 256;
  return gap < 48 ? gap : 48;
}

/// The result, index-aligned with the input (SPEC §3).
final class LayoutResult {
  LayoutResult({
    required this.mode,
    required this.order,
    required this.unit,
    required this.rows,
    required this.lanes,
    required this.row,
    required this.lane,
    required this.col,
    required this.edgeFrom,
    required this.edgeTo,
    required this.edgeKind,
    required this.edgeRoute,
    required this.edgeBlocked,
    required this.bucketKind,
    required this.bucketValue,
    required this.bucketStart,
    required this.bucketEnd,
    this.stackCount = 0,
    this.nodeRun,
    this.runState,
    this.runNode,
    this.runStart,
    this.runMembers,
  });

  final Mode mode;
  final LaneOrder order;
  final int unit;
  final int rows;
  final int lanes;

  final Int64List row;
  final Int32List lane;
  final Int32List col;

  final Int32List edgeFrom;
  final Int32List edgeTo;
  final Uint8List edgeKind;
  final Uint8List edgeRoute;
  final Uint8List edgeBlocked;

  final Uint8List bucketKind;
  final Int64List bucketValue;
  final Int64List bucketStart;
  final Int64List bucketEnd;

  // ---- With a stack request (SPEC §4.8, Story 4.13); otherwise 0 / null. The node arrays above
  // then hold n + stackCount entries (−1 for a hidden member) and the edges are the grouped ones.
  final int stackCount;

  /// Per input node, its run or −1.
  final Int32List? nodeRun;

  /// Per run, [runExpanded] or [runCollapsed].
  final Uint8List? runState;

  /// Per run, its stack node or −1.
  final Int32List? runNode;

  /// The runs' member CSR (R + 1 offsets); members oldest first.
  final Int32List? runStart;
  final Int32List? runMembers;
}

/// Runs the whole layout; [onPhaseEnd] is called after each of the five timed phases
/// (layering, lanes, blocked, routing, ordering; SPEC §8.2) and, with [stacks], after the sixth
/// (stacks, SPEC §4.8). [budget] is the `compact` order's search budget (SPEC §4.7; a request
/// parameter in the product, 2026-10-01). With [stacks] (Story 4.13) the result is the grouped
/// layout of SPEC §4.8 over the finished ungrouped one.
LayoutResult computeLayout(
  LayoutInput input,
  Mode mode,
  LaneOrder order, {
  void Function()? onPhaseEnd,
  int budget = compactBudget,
  StackInput? stacks,
}) {
  final g = GraphLayout(input, mode);
  g.layering();
  onPhaseEnd?.call();
  g.packLanes();
  onPhaseEnd?.call();
  g.markBlocked();
  onPhaseEnd?.call();
  g.route();
  onPhaseEnd?.call();
  g.orderLanes(order, budget: budget);
  onPhaseEnd?.call();
  if (stacks == null) return g.result(order);
  final grouped = StackLayout(g, stacks)..run();
  onPhaseEnd?.call();
  return grouped.result(order);
}

/// The layout state, one phase per method (SPEC §4). Phases must run in order.
final class GraphLayout {
  GraphLayout(this.input, this.mode) : n = input.n, unit = mode == Mode.free ? 16 : 1;

  final LayoutInput input;
  final Mode mode;
  final int n;

  /// U (SPEC §1).
  final int unit;

  // ---- 4.1 graph prep: layout parents LP (CSR, one entry per layout edge), fp, children C.
  late final int edgeCount;
  late final Int32List lpStart; // n + 1
  late final Int32List edgeParent; // LP entries = layout edges, ordered by (child, pos)
  late final Int32List edgeChild;
  late final Uint8List edgeKind;
  late final Int32List fp; // −1 if LP(i) = ∅
  late final Int32List chStart; // n + 1
  late final Int32List chIdx; // children, ascending
  late final Int32List chPos; // pos(j, child)

  // ---- 4.2
  late final Int64List y;
  Uint8List bucketKind = Uint8List(0);
  Int64List bucketValue = Int64List(0);
  Int64List bucketStart = Int64List(0);
  Int64List bucketEnd = Int64List(0);

  /// `free`'s walk W (T ascending, i descending) and clamped T; null otherwise. SPEC §4.8 reads them.
  Int32List? freeOrder;
  Int64List? freeT;

  // ---- 4.3 (re-assigned by the `compact` order, SPEC §4.7)
  late Int32List lane;
  late int laneCount;
  late Int32List laneYStart; // laneCount + 1
  late Int64List laneYs; // per lane, ascending
  late final Int32List visitOrder; // (y, priority, i) ascending

  // ---- 4.4 / 4.5 (recomputed by the `compact` order)
  late Uint8List blocked;
  late Uint8List routes;

  // ---- 4.6
  late final Int32List col;

  /// SPEC §4.1 + §4.2 [layering].
  void layering() {
    _prep();
    y = Int64List(n);
    switch (mode) {
      case Mode.compact:
        _layerCompact();
      case Mode.time:
        _layerTime();
      case Mode.free:
        _layerFree();
    }
  }

  void _prep() {
    final parStart = input.parStart, parIdx = input.parIdx, parKind = input.parKind;
    final lpStart = Int32List(n + 1);
    var e = 0;
    for (var i = 0; i < n; i++) {
      lpStart[i] = e;
      for (var k = parStart[i]; k < parStart[i + 1]; k++) {
        if (parIdx[k] >= 0) e++;
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
      for (var k = parStart[i]; k < parStart[i + 1]; k++) {
        final p = parIdx[k];
        if (p < 0) continue;
        if (fp[i] < 0) fp[i] = p;
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
      final p = edgeParent[e], c = edgeChild[e];
      final slot = cursor[p]++;
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
    final y = this.y, lpStart = this.lpStart, edgeParent = this.edgeParent;
    for (var i = n - 1; i >= 0; i--) {
      var r = 0;
      for (var e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final v = y[edgeParent[e]] + 1;
        if (v > r) r = v;
      }
      y[i] = r;
    }
  }

  void _layerTime() {
    final y = this.y, lpStart = this.lpStart, edgeParent = this.edgeParent;
    final ts = input.ts, hasTs = input.hasTs, isRoot = input.isRoot;
    final nowMs = input.nowMs, utcOffsetMin = input.utcOffsetMin;

    // 1 + 2: bucket key and topological clamp eb(i).
    final eb = Int64List(n);
    for (var i = n - 1; i >= 0; i--) {
      var key = (isRoot[i] != 0 || hasTs[i] == 0) ? rootKey : timeBucketKey(ts[i], nowMs, utcOffsetMin);
      for (var e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final v = eb[edgeParent[e]];
        if (v > key) key = v;
      }
      eb[i] = key;
    }

    // 3: distinct keys ascending = the buckets.
    final sorted = Int64List.fromList(eb)..sort();
    var bucketCount = 0;
    for (var k = 0; k < n; k++) {
      if (k == 0 || sorted[k] != sorted[k - 1]) sorted[bucketCount++] = sorted[k];
    }
    final keys = Int64List.sublistView(sorted, 0, bucketCount);

    // Members per bucket, each in descending index (a counting sort over the bucket ids).
    final bucketOf = Int32List(n);
    final memberStart = Int32List(bucketCount + 1);
    for (var i = 0; i < n; i++) {
      final b = _lowerBound(keys, 0, bucketCount, eb[i]);
      bucketOf[i] = b;
      memberStart[b + 1]++;
    }
    for (var b = 0; b < bucketCount; b++) {
      memberStart[b + 1] += memberStart[b];
    }
    final cursor = Int32List.fromList(memberStart);
    final members = Int32List(n);
    for (var i = n - 1; i >= 0; i--) {
      members[cursor[bucketOf[i]]++] = i;
    }

    final bucketKind = Uint8List(bucketCount);
    final bucketValue = Int64List(bucketCount);
    final bucketStart = Int64List(bucketCount);
    final bucketEnd = Int64List(bucketCount);
    final oldestAgeKey = nowMs - ladderMinutes.last * _minute;
    var next = 0;
    for (var b = 0; b < bucketCount; b++) {
      final start = next;
      var end = start;
      for (var m = memberStart[b]; m < memberStart[b + 1]; m++) {
        final i = members[m];
        var r = start;
        for (var e = lpStart[i]; e < lpStart[i + 1]; e++) {
          final v = y[edgeParent[e]] + 1;
          if (v > r) r = v;
        }
        y[i] = r;
        if (r > end) end = r;
      }
      final key = keys[b];
      if (key == rootKey) {
        bucketKind[b] = bucketRoot;
      } else if (key >= oldestAgeKey) {
        bucketKind[b] = bucketAge;
        bucketValue[b] = (nowMs - key) ~/ _minute;
      } else {
        bucketKind[b] = bucketDay;
        bucketValue[b] = key;
      }
      bucketStart[b] = start;
      bucketEnd[b] = end;
      next = end + 1;
    }
    this.bucketKind = bucketKind;
    this.bucketValue = bucketValue;
    this.bucketStart = bucketStart;
    this.bucketEnd = bucketEnd;
  }

  void _layerFree() {
    final y = this.y, lpStart = this.lpStart, edgeParent = this.edgeParent;
    final ts = input.ts, hasTs = input.hasTs, isRoot = input.isRoot;
    final u = unit;

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
    for (var i = n - 1; i >= 0; i--) {
      var v = (isRoot[i] != 0 || hasTs[i] == 0) ? tmin : ts[i];
      for (var e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final w = t[edgeParent[e]];
        if (w > v) v = w;
      }
      t[i] = v;
    }
    // 3: walk by (T asc, i desc).
    final order = Int32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = i;
    }
    order.sort((a, b) {
      final ta = t[a], tb = t[b];
      if (ta != tb) return ta < tb ? -1 : 1;
      return b - a;
    });
    var prevY = 0, prevT = 0;
    for (var k = 0; k < n; k++) {
      final i = order[k];
      var r = k == 0 ? 0 : prevY + freeGap(t[i] - prevT);
      for (var e = lpStart[i]; e < lpStart[i + 1]; e++) {
        final v = y[edgeParent[e]] + u;
        if (v > r) r = v;
      }
      y[i] = r;
      prevY = r;
      prevT = t[i];
    }
    _freeDayBuckets(order, t);
    freeOrder = order;
    freeT = t;
  }

  /// Step 4 of SPEC §4.2 free (amended 2026-10-01): one `day` bucket per local day of the clamped
  /// T of every non-root node. T and y never decrease in the walk [order], so a bucket's members
  /// are consecutive there (roots skipped) and one pass emits the buckets ascending.
  void _freeDayBuckets(Int32List order, Int64List t) {
    final y = this.y, isRoot = input.isRoot, utcOffsetMin = input.utcOffsetMin;
    var count = 0;
    var last = 0;
    for (var k = 0; k < n; k++) {
      final i = order[k];
      if (isRoot[i] != 0) continue;
      final key = dayKey(t[i], utcOffsetMin);
      if (count == 0 || key != last) {
        count++;
        last = key;
      }
    }
    final bucketKind = Uint8List(count)..fillRange(0, count, bucketDay);
    final bucketValue = Int64List(count);
    final bucketStart = Int64List(count);
    final bucketEnd = Int64List(count);
    var b = -1;
    for (var k = 0; k < n; k++) {
      final i = order[k];
      if (isRoot[i] != 0) continue;
      final key = dayKey(t[i], utcOffsetMin);
      if (b < 0 || key != bucketValue[b]) {
        b++;
        bucketValue[b] = key;
        bucketStart[b] = y[i];
      }
      bucketEnd[b] = y[i];
    }
    this.bucketKind = bucketKind;
    this.bucketValue = bucketValue;
    this.bucketStart = bucketStart;
    this.bucketEnd = bucketEnd;
  }

  /// SPEC §4.3 [lanes].
  void packLanes() {
    final y = this.y, fp = this.fp, priority = input.priority;
    final chStart = this.chStart, chIdx = this.chIdx, chPos = this.chPos;
    final u = unit;

    // cont(j): the child with fp = j and the least key (priority, index).
    final cont = Int32List(n)..fillRange(0, n, -1);
    for (var i = 0; i < n; i++) {
      final f = fp[i];
      if (f < 0) continue;
      final c = cont[f];
      if (c < 0 || priority[i] < priority[c]) cont[f] = i;
    }

    // Visit order: (y, priority, i) ascending.
    final order = Int32List(n);
    for (var i = 0; i < n; i++) {
      order[i] = i;
    }
    order.sort((a, b) {
      final ya = y[a], yb = y[b];
      if (ya != yb) return ya < yb ? -1 : 1;
      final pa = priority[a], pb = priority[b];
      if (pa != pb) return pa - pb;
      return a - b;
    });

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
      final i = order[k];
      final yi = y[i];
      var end = yi;
      final c = cont[i];
      if (c >= 0) {
        final v = y[c] - u;
        if (v > end) end = v;
      }
      for (var s = chStart[i]; s < chStart[i + 1]; s++) {
        if (chPos[s] >= 1) {
          final v = y[chIdx[s]] - u;
          if (v > end) end = v;
        }
      }
      final f = fp[i];
      final a = f >= 0 ? y[f] + u : yi;
      final b = end + 2 * u;

      var l = -1;
      if (f >= 0 && cont[f] == i) {
        final lf = lane[f];
        final others = own1[lf] == f ? max2[lf] : max1[lf];
        if (others <= a) l = lf;
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
        var node = size + l;
        tree[node] = b;
        node >>= 1;
        while (node >= 1) {
          final left = tree[2 * node], right = tree[2 * node + 1];
          tree[node] = left < right ? left : right;
          node >>= 1;
        }
      } else if (b > max2[l]) {
        max2[l] = b;
      }
      lane[i] = l;
      if (l >= laneCount) laneCount = l + 1;
    }
    visitOrder = order;
    _adoptLanes(lane, laneCount);
  }

  /// Sets [lane] and builds the per-lane y-lists; the visit order is ascending in y, so each list
  /// comes out sorted.
  void _adoptLanes(Int32List lane, int laneCount) {
    final order = visitOrder;
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
      final i = order[k];
      laneYs[cursor[lane[i]]++] = y[i];
    }
    this.lane = lane;
    this.laneCount = laneCount;
    this.laneYStart = laneYStart;
    this.laneYs = laneYs;
  }

  /// SPEC §4.4 [blocked].
  void markBlocked() {
    final blocked = Uint8List(edgeCount);
    final y = this.y, lane = this.lane, laneYStart = this.laneYStart, laneYs = this.laneYs;
    for (var e = 0; e < edgeCount; e++) {
      final p = edgeParent[e], i = edgeChild[e];
      final lp = lane[p];
      if (lane[i] == lp) continue;
      // First y > y(p) in lane(p)'s y-list.
      final yp = y[p];
      var lo = laneYStart[lp], hi = laneYStart[lp + 1];
      final end = hi;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (laneYs[mid] <= yp) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      if (lo < end && laneYs[lo] <= y[i]) blocked[e] = 1;
    }
    this.blocked = blocked;
  }

  /// SPEC §4.5 [routing].
  void route() {
    final routes = Uint8List(edgeCount);
    final lane = this.lane;
    for (var e = 0; e < edgeCount; e++) {
      final p = edgeParent[e], i = edgeChild[e];
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

  /// SPEC §4.6 / §4.7 [ordering]; [budget] bounds the `compact` order's search.
  void orderLanes(LaneOrder order, {int budget = compactBudget}) {
    final col = Int32List(n);
    switch (order) {
      case LaneOrder.greedy:
        col.setAll(0, lane);
      case LaneOrder.optimized:
        final sifter = buildSifter();
        sifter.run();
        final pos = sifter.pos;
        for (var i = 0; i < n; i++) {
          col[i] = pos[lane[i]];
        }
      case LaneOrder.compact:
        final newLane = compactColumns(this, budget: budget);
        var count = 0;
        for (var i = 0; i < n; i++) {
          if (newLane[i] >= count) count = newLane[i] + 1;
        }
        _adoptLanes(newLane, count);
        markBlocked();
        route();
        col.setAll(0, lane);
    }
    this.col = col;
  }

  /// The geometry model of SPEC §4.6 over the current routes, with π = identity.
  LaneSifter buildSifter() {
    final y = this.y, lane = this.lane, routes = this.routes;
    final u = unit;
    var hCount = 0;
    final vCount = Int32List(laneCount + 1);
    for (var e = 0; e < edgeCount; e++) {
      final p = edgeParent[e], i = edgeChild[e];
      switch (routes[e]) {
        case routeStraight:
          vCount[lane[p] + 1]++;
        case routeMerge:
          vCount[lane[p] + 1]++;
          vCount[lane[i] + 1]++;
          hCount++;
        default:
          vCount[lane[i] + 1]++;
          hCount++;
      }
    }
    for (var l = 0; l < laneCount; l++) {
      vCount[l + 1] += vCount[l];
    }
    final vStart = vCount;
    final vTotal = vStart[laneCount];
    final vLo = Int64List(vTotal), vHi = Int64List(vTotal);
    final cursor = Int32List.fromList(vStart);
    final hA = Int32List(hCount), hB = Int32List(hCount);
    final hLevel = Int64List(hCount);
    var h = 0;
    for (var e = 0; e < edgeCount; e++) {
      final p = edgeParent[e], i = edgeChild[e];
      final lp = lane[p], li = lane[i];
      final botP = 10 * y[p], botI = 10 * y[i];
      final top = botP + 5 * u; // top(p)
      switch (routes[e]) {
        case routeStraight:
          final s = cursor[lp]++;
          vLo[s] = top;
          vHi[s] = botI;
        case routeMerge:
          final dn = botI - 2 * u; // dn(i)
          var s = cursor[lp]++;
          vLo[s] = top;
          vHi[s] = dn;
          s = cursor[li]++;
          vLo[s] = dn;
          vHi[s] = botI;
          hA[h] = lp;
          hB[h] = li;
          hLevel[h] = dn;
          h++;
        default:
          final up = botP + 7 * u; // up(p)
          final s = cursor[li]++;
          vLo[s] = up;
          vHi[s] = botI;
          hA[h] = lp;
          hB[h] = li;
          hLevel[h] = up;
          h++;
      }
    }
    for (var l = 0; l < laneCount; l++) {
      Int64List.sublistView(vLo, vStart[l], vStart[l + 1]).sort();
      Int64List.sublistView(vHi, vStart[l], vStart[l + 1]).sort();
    }
    return LaneSifter(laneCount: laneCount, hA: hA, hB: hB, hLevel: hLevel, vStart: vStart, vLo: vLo, vHi: vHi);
  }

  LayoutResult result(LaneOrder order) {
    var maxRow = 0, maxLane = 0;
    for (var i = 0; i < n; i++) {
      if (y[i] > maxRow) maxRow = y[i];
      if (lane[i] > maxLane) maxLane = lane[i];
    }
    final edgeRoute = routes;
    return LayoutResult(
      mode: mode,
      order: order,
      unit: unit,
      rows: n == 0 ? 0 : maxRow + unit,
      lanes: n == 0 ? 0 : maxLane + 1,
      row: y,
      lane: lane,
      col: col,
      edgeFrom: edgeParent,
      edgeTo: edgeChild,
      edgeKind: edgeKind,
      edgeRoute: edgeRoute,
      edgeBlocked: blocked,
      bucketKind: bucketKind,
      bucketValue: bucketValue,
      bucketStart: bucketStart,
      bucketEnd: bucketEnd,
    );
  }
}

/// Index of the first element ≥ [value] in the sorted range [lo, hi).
int _lowerBound(Int64List list, int lo, int hi, int value) {
  while (lo < hi) {
    final mid = (lo + hi) >> 1;
    if (list[mid] < value) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
