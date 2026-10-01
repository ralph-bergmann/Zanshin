// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'layout_engine.dart';
import 'sort.dart';

// The `compact` lane order (docs/graph-layout.md §4.7), ported from the spike's Dart reference
// (spikes/graph-layout-ab/dart/lib/src/compact_order.dart) byte for byte; only the budget comes
// from the request and the sorts are the monomorphic ones of sort.dart.

/// κ: the cost per column per row pitch of a segment's reservation (§4.7).
const compactGravity = 24;

/// Exchanges pair column c with c + 1 … c + [compactReach] (§4.7).
const compactReach = 8;

/// At most this many exchange rounds (§4.7).
const compactRounds = 16;

/// The `compact` lane order (§4.7): the new lane (= column) of every node of the greedy layout
/// [engine]. The search stops at the first window after the work units it has spent exceed
/// [budget] (§4.7, "stop the search"), so it may overshoot [budget] by one window.
///
/// It starts from greedy's packing and keeps greedy's continuation chains ("segments") intact,
/// but it does not move whole lanes: it exchanges the segments of two columns inside one time
/// window at a time, where a window is a connected group of overlapping reservations of the two
/// columns. An exchange stays when it lowers U·(400·X + 4·Len) + κ·Σ column·(reservation length)
/// over the segments involved, with X and Len the crossings and horizontal run lengths of §4.6's
/// tick model. Lane 0's segments stay in column 0; columns left empty are dropped at the end.
///
/// Needs [LayoutEngine.packLanes], [LayoutEngine.markBlocked] and [LayoutEngine.route] to have run.
Int32List compactColumns(LayoutEngine engine, {required int budget}) => CompactOrder(engine, budget: budget).run();

/// The search state of [compactColumns]. Public for the engine's tests.
final class CompactOrder {
  /// The search over the greedy layout [g], with the request's [budget] and the §4.7 constants;
  /// [skip] is false only in the tests.
  CompactOrder(
    this.g, {
    required this.budget,
    this.gravity = compactGravity,
    this.reach = compactReach,
    this.rounds = compactRounds,
    this.skip = true,
  }) : n = g.n,
       u = g.unit {
    if (n == 0) {
      segCount = 0;
      return;
    }
    _segments();
    _geometry();
    // Start: greedy's lanes, each column's segments ascending by reservation start.
    final bySegA = Int32List(segCount);
    for (var s = 0; s < segCount; s++) {
      bySegA[s] = s;
    }
    sortIndicesStable(bySegA, segA);
    colOf = Int32List(segCount);
    for (var c = 0; c < g.laneCount; c++) {
      colSegs.add(<int>[]);
    }
    for (final s in bySegA) {
      final int c = g.lane[segHead[s]];
      colSegs[c].add(s);
      colOf[s] = c;
    }
  }

  /// The greedy layout the search starts from.
  final LayoutEngine g;

  /// The node count.
  final int n;

  /// U.
  final int u;

  /// The work units the search may spend before it stops.
  final int budget;

  /// κ.
  final int gravity;

  /// The largest column distance of an exchange.
  final int reach;

  /// The most rounds.
  final int rounds;

  /// Skip windows that no kept exchange can have changed (§4.7 "Skipping"); false only in the tests.
  final bool skip;

  /// The segment of every node.
  late final Int32List seg;

  /// The number of segments.
  late final int segCount;

  /// Each segment's head (lowest node).
  late final Int32List segHead;

  /// Each segment's reservation start a.
  late final Int64List segA;

  /// Each segment's reservation end b.
  late final Int64List segB;

  /// Per segment, the lowest level of any term of its cost: 10·a − 3U, or lower for the horizontal
  /// of a blocked merge (D9) into it, which sits at up(p) below its clipped vertical.
  late final Int64List segLo;

  /// The number of horizontals (the non-straight edges).
  late final int hCount;

  /// Each horizontal's parent-side segment.
  late final Int32List hPar;

  /// Each horizontal's child-side segment.
  late final Int32List hChild;

  /// Each horizontal's level in ticks.
  late final Int64List hLevel;

  /// The horizontals ascending by (level, index).
  late final Int32List byLevel;

  /// The levels of [byLevel], in its order.
  late final Int64List levelSorted;

  /// Per segment its incident horizontals (either side), CSR offsets (segCount + 1).
  late final Int32List incStart;

  /// The incident horizontals of every segment.
  late final Int32List incH;

  /// Per segment its verticals, CSR offsets (segCount + 1).
  late final Int32List vStart;

  /// The verticals' lower ends, sorted per segment.
  late final Int64List vLo;

  /// The verticals' upper ends, sorted per segment.
  late final Int64List vHi;

  /// Each segment's lowest vertical lower end (0 without verticals).
  late final Int64List vMin;

  /// Each segment's highest vertical upper end (0 without verticals).
  late final Int64List vMax;

  /// The column of every segment.
  late final Int32List colOf;

  /// Per column, its segments ascending by reservation start (disjoint reservations).
  final List<List<int>> colSegs = [];

  var _spent = 0;

  /// Runs the search; returns the new lane of every node.
  Int32List run() {
    if (n == 0) {
      return Int32List(0);
    }
    final inM = Uint8List(segCount);
    List<int>? previous; // level spans of the exchanges the previous round kept
    for (var r = 0; r < rounds; r++) {
      final kept = <int>[];
      if (!_swapRound(inM, skip ? previous : null, kept)) {
        break;
      }
      previous = kept;
    }
    // Drop empty columns, keeping the order of the others (no crossing or run can grow).
    final newCol = Int32List(colSegs.length);
    var next = 0;
    for (var c = 0; c < colSegs.length; c++) {
      newCol[c] = colSegs[c].isEmpty && c > 0 ? -1 : next++;
    }
    final lane = Int32List(n);
    for (var i = 0; i < n; i++) {
      lane[i] = newCol[colOf[seg[i]]];
    }
    return lane;
  }

  /// The model cost of the current columns: [localCost] over every segment.
  int totalCost() {
    if (n == 0) {
      return 0;
    }
    final all = List<int>.generate(segCount, (s) => s);
    return localCost(all, Uint8List(segCount)..fillRange(0, segCount, 1));
  }

  /// Segments = maximal chains of straight edges; reservations = the union of their nodes' §4.3
  /// intervals, recomputed exactly as the packing computed them.
  void _segments() {
    final Int64List y = g.y;
    final Int32List fp = g.fp;
    final Int32List lane = g.lane;
    final Int32List priority = g.input.priority;
    final Int32List chStart = g.chStart;
    final Int32List chIdx = g.chIdx;
    final Int32List chPos = g.chPos;

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

    // Parents have larger indices: a descending scan meets a segment's head first.
    final seg = Int32List(n);
    final heads = Int32List(n);
    var count = 0;
    for (int i = n - 1; i >= 0; i--) {
      final int f = fp[i];
      if (f >= 0 && lane[f] == lane[i]) {
        seg[i] = seg[f];
      } else {
        heads[count] = i;
        seg[i] = count++;
      }
    }
    final segA = Int64List(count)..fillRange(0, count, 0x3FFFFFFFFFFFFFFF);
    final segB = Int64List(count)..fillRange(0, count, -0x3FFFFFFFFFFFFFFF);
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
      final int a = f >= 0 ? y[f] + u : y[i];
      final int b = end + 2 * u;
      final int s = seg[i];
      if (a < segA[s]) {
        segA[s] = a;
      }
      if (b > segB[s]) {
        segB[s] = b;
      }
    }
    this.seg = seg;
    segCount = count;
    segHead = Int32List.sublistView(heads, 0, count);
    this.segA = segA;
    this.segB = segB;
  }

  /// §4.6's tick model per segment. A blocked merge's vertical (D9) is clipped to its segment's
  /// reservation start 10·a − 3U, so every vertical of a segment lies in [10·a − 3U, 10·(b − U)].
  void _geometry() {
    final Int64List y = g.y;
    final Uint8List routes = g.routes;
    final Int32List edgeParent = g.edgeParent;
    final Int32List edgeChild = g.edgeChild;
    final int edgeCount = g.edgeCount;
    final Int32List seg = this.seg;
    final int segCount = this.segCount;
    final Int64List segA = this.segA;

    var hCount = 0;
    final vCount = Int32List(segCount + 1);
    for (var e = 0; e < edgeCount; e++) {
      final int sp = seg[edgeParent[e]];
      final int si = seg[edgeChild[e]];
      switch (routes[e]) {
        case routeStraight:
          vCount[sp + 1]++;
        case routeMerge:
          vCount[sp + 1]++;
          vCount[si + 1]++;
          hCount++;
        case _:
          vCount[si + 1]++;
          hCount++;
      }
    }
    for (var s = 0; s < segCount; s++) {
      vCount[s + 1] += vCount[s];
    }
    final vStart = vCount;
    final int vTotal = vStart[segCount];
    final vLo = Int64List(vTotal);
    final vHi = Int64List(vTotal);
    final cursor = Int32List.fromList(vStart);
    final hPar = Int32List(hCount);
    final hChild = Int32List(hCount);
    final hLevel = Int64List(hCount);
    var h = 0;
    for (var e = 0; e < edgeCount; e++) {
      final int p = edgeParent[e];
      final int i = edgeChild[e];
      final int sp = seg[p];
      final int si = seg[i];
      final int botP = 10 * y[p];
      final int botI = 10 * y[i];
      final int top = botP + 5 * u;
      switch (routes[e]) {
        case routeStraight:
          final int k = cursor[sp]++;
          vLo[k] = top;
          vHi[k] = botI;
        case routeMerge:
          final int dn = botI - 2 * u;
          int k = cursor[sp]++;
          vLo[k] = top;
          vHi[k] = dn;
          k = cursor[si]++;
          vLo[k] = dn;
          vHi[k] = botI;
          hPar[h] = sp;
          hChild[h] = si;
          hLevel[h] = dn;
          h++;
        case _:
          final int up = botP + 7 * u;
          final int floor = 10 * segA[si] - 3 * u;
          final int k = cursor[si]++;
          vLo[k] = up > floor ? up : floor;
          vHi[k] = botI;
          hPar[h] = sp;
          hChild[h] = si;
          hLevel[h] = up;
          h++;
      }
    }
    final vMin = Int64List(segCount);
    final vMax = Int64List(segCount);
    for (var s = 0; s < segCount; s++) {
      final int from = vStart[s];
      final int to = vStart[s + 1];
      sortInt64Range(vLo, from, to);
      sortInt64Range(vHi, from, to);
      vMin[s] = from == to ? 0 : vLo[from];
      vMax[s] = from == to ? 0 : vHi[to - 1];
    }

    final incStart = Int32List(segCount + 1);
    for (var k = 0; k < hCount; k++) {
      incStart[hPar[k] + 1]++;
      incStart[hChild[k] + 1]++;
    }
    for (var s = 0; s < segCount; s++) {
      incStart[s + 1] += incStart[s];
    }
    final incH = Int32List(2 * hCount);
    final incCursor = Int32List.fromList(incStart);
    for (var k = 0; k < hCount; k++) {
      incH[incCursor[hPar[k]]++] = k;
      incH[incCursor[hChild[k]]++] = k;
    }
    final segLo = Int64List(segCount);
    for (var s = 0; s < segCount; s++) {
      int lo = 10 * segA[s] - 3 * u;
      for (int r = incStart[s]; r < incStart[s + 1]; r++) {
        if (hLevel[incH[r]] < lo) {
          lo = hLevel[incH[r]];
        }
      }
      segLo[s] = lo;
    }

    final byLevel = Int32List(hCount);
    for (var k = 0; k < hCount; k++) {
      byLevel[k] = k;
    }
    sortIndicesStable(byLevel, hLevel);
    final levelSorted = Int64List(hCount);
    for (var k = 0; k < hCount; k++) {
      levelSorted[k] = hLevel[byLevel[k]];
    }

    this.hCount = hCount;
    this.hPar = hPar;
    this.hChild = hChild;
    this.hLevel = hLevel;
    this.byLevel = byLevel;
    this.levelSorted = levelSorted;
    this.incStart = incStart;
    this.incH = incH;
    this.segLo = segLo;
    this.vStart = vStart;
    this.vLo = vLo;
    this.vHi = vHi;
    this.vMin = vMin;
    this.vMax = vMax;
  }

  /// m(s, λ): the number of segment [s]'s verticals with lo < λ < hi, λ = [level].
  int m(int s, int level) {
    if (level <= vMin[s] || level >= vMax[s]) {
      return 0;
    }
    final Int64List vLo = this.vLo;
    final Int64List vHi = this.vHi;
    final int start = vStart[s];
    final int end = vStart[s + 1];
    var lo = start;
    var hi = end;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (vLo[mid] < level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final int below = lo - start;
    lo = start;
    hi = end;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (vHi[mid] <= level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return below - (lo - start);
  }

  /// The verticals at [level] in column [c]. Reservations in a column are disjoint and a segment's
  /// verticals lie in [10·a − 3U, 10·(b − U)], so only the last segment with 10·a − 3U < λ can
  /// hold one.
  int mAt(int c, int level) {
    final List<int> list = colSegs[c];
    final Int64List segA = this.segA;
    final int u3 = 3 * u;
    var lo = 0;
    int hi = list.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (10 * segA[list[mid]] - u3 < level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? 0 : m(list[lo - 1], level);
  }

  /// The exact model cost of everything that involves a segment in [members] ([inM] marks them):
  /// the crossings of their horizontals and of their verticals, their horizontals' run lengths,
  /// their gravity. Each crossing and each run is counted once.
  int localCost(List<int> members, Uint8List inM) {
    var x = 0;
    var len = 0;
    var grav = 0;
    for (final s in members) {
      final int cs = colOf[s];
      grav += gravity * cs * (segB[s] - segA[s]);
      // Horizontals of s against every vertical between their ends.
      for (int r = incStart[s]; r < incStart[s + 1]; r++) {
        final int h = incH[r];
        final int other = hPar[h] == s ? hChild[h] : hPar[h];
        if (inM[other] != 0 && hPar[h] != s) {
          continue; // counted from its parent side
        }
        final int xo = colOf[other];
        final lo = cs < xo ? cs : xo;
        final hi = cs < xo ? xo : cs;
        len += hi - lo;
        final int level = hLevel[h];
        for (int c = lo + 1; c < hi; c++) {
          x += mAt(c, level);
        }
        _spent += hi - lo;
      }
      // Horizontals of non-members that pass over s's column inside s's vertical extent.
      final int from = vMin[s];
      final int to = vMax[s];
      if (to <= from) {
        continue;
      }
      var lo = 0;
      int hi = hCount;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (levelSorted[mid] <= from) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      for (var k = lo; k < hCount && levelSorted[k] < to; k++) {
        _spent++;
        final int h = byLevel[k];
        final int pa = hPar[h];
        final int ch = hChild[h];
        if (inM[pa] != 0 || inM[ch] != 0) {
          continue;
        }
        final int xa = colOf[pa];
        final int xb = colOf[ch];
        if ((xa < cs && cs < xb) || (xb < cs && cs < xa)) {
          x += m(s, levelSorted[k]);
        }
      }
    }
    return u * (400 * x + 4 * len) + grav;
  }

  /// One round: for d = 1 … reach and c = 1, 2, …, try every window of the column pair (c, c + d)
  /// in time order. Exchanging the two columns' segments inside a window keeps both columns
  /// disjoint; the exchange stays when it lowers [localCost] of the window's segments. True if
  /// one stayed; [kept] collects the level span [lo, hi) of each exchange that stayed.
  ///
  /// A window's cost only involves levels in its span [min [segLo], 10·max b). After the first
  /// round ([previous] non-null), a window whose span meets no exchange kept since the previous
  /// round started ([previous], [kept]) was already rejected in the same context and is skipped.
  bool _swapRound(Uint8List inM, List<int>? previous, List<int> kept) {
    var moved = false;
    final Int64List segA = this.segA;
    final Int64List segB = this.segB;
    final Int64List segLo = this.segLo;
    bool touched(List<int> spans, int lo, int hi) {
      _spent += spans.length >> 1; // the skip test is charged to the budget too
      for (var k = 0; k < spans.length; k += 2) {
        if (spans[k] < hi && lo < spans[k + 1]) {
          return true;
        }
      }
      return false;
    }

    for (var d = 1; d <= reach; d++) {
      for (var c = 1; c + d < colSegs.length; c++) {
        final List<int> left = colSegs[c];
        final List<int> right = colSegs[c + d];
        var i = 0;
        var j = 0;
        while (i < left.length || j < right.length) {
          if (_spent > budget) {
            return moved;
          }
          // One window: from the earlier of the two next segments, while reservations overlap.
          final i0 = i;
          final j0 = j;
          var end = -0x3FFFFFFFFFFFFFFF;
          while (true) {
            final bool takeLeft = i < left.length && (j >= right.length || segA[left[i]] <= segA[right[j]]);
            if (!takeLeft && j >= right.length) {
              break;
            }
            final int t = takeLeft ? left[i] : right[j];
            if ((i > i0 || j > j0) && segA[t] >= end) {
              break;
            }
            if (segB[t] > end) {
              end = segB[t];
            }
            if (takeLeft) {
              i++;
            } else {
              j++;
            }
          }
          final List<int> fromLeft = left.sublist(i0, i);
          final List<int> fromRight = right.sublist(j0, j);
          final members = [...fromLeft, ...fromRight];
          var spanLo = 0x3FFFFFFFFFFFFFFF;
          for (final s in members) {
            if (segLo[s] < spanLo) {
              spanLo = segLo[s];
            }
          }
          final int spanHi = 10 * end;
          if (previous != null && !touched(previous, spanLo, spanHi) && !touched(kept, spanLo, spanHi)) {
            continue;
          }
          for (final s in members) {
            inM[s] = 1;
          }
          final int before = localCost(members, inM);
          _place(left, i0, i, fromRight, c);
          _place(right, j0, j, fromLeft, c + d);
          if (localCost(members, inM) < before) {
            moved = true;
            kept
              ..add(spanLo)
              ..add(spanHi);
            i = i0 + fromRight.length;
            j = j0 + fromLeft.length;
          } else {
            _place(left, i0, i0 + fromRight.length, fromLeft, c);
            _place(right, j0, j0 + fromLeft.length, fromRight, c + d);
          }
          for (final s in members) {
            inM[s] = 0;
          }
        }
      }
    }
    return moved;
  }

  /// Replaces `list[from ..< to]` with [segs], all now in column [c]. Charges the shifted tail to
  /// the budget.
  void _place(List<int> list, int from, int to, List<int> segs, int c) {
    _spent += list.length - from;
    list.replaceRange(from, to, segs);
    for (final s in segs) {
      colOf[s] = c;
    }
  }
}
