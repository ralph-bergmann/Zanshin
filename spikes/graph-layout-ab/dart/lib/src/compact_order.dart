import 'dart:typed_data';

import 'layout.dart';

/// Constants of the `compact` lane order (SPEC §4.7, Dart-only).
const int compactGravity = 24; // κ: cost per column per row pitch of a segment's reservation
const int compactReach = 8; // swaps pair column c with c + 1 … c + reach
const int compactRounds = 16; // at most this many swap rounds
const int compactBudget = 2000000; // work units; the search stops when they are spent

/// The `compact` lane order (SPEC §4.7). Returns the new lane (= column) of every node.
///
/// It starts from greedy's packing and keeps greedy's continuation chains ("segments") intact,
/// but it does not move whole lanes: it exchanges the segments of two columns inside one time
/// window at a time, where a window is a connected group of overlapping reservations of the two
/// columns. A swap stays when it lowers U·(400·X + 4·Len) + κ·Σ column·(reservation length) over
/// the segments involved, with X and Len the crossings and horizontal run lengths of §4.6's tick
/// model. Lane 0's segments stay in column 0; columns left empty are dropped at the end.
///
/// Needs [GraphLayout.packLanes], [GraphLayout.markBlocked] and [GraphLayout.route] to have run.
Int32List compactColumns(GraphLayout g, {int budget = compactBudget}) => CompactOrder(g, budget: budget).run();

/// The search state of [compactColumns]. Public for the tests.
final class CompactOrder {
  CompactOrder(
    this.g, {
    this.gravity = compactGravity,
    this.reach = compactReach,
    this.rounds = compactRounds,
    this.budget = compactBudget,
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
    bySegA.sort((a, b) {
      final x = segA[a], y = segA[b];
      if (x != y) return x < y ? -1 : 1;
      return a - b;
    });
    colOf = Int32List(segCount);
    for (var c = 0; c < g.laneCount; c++) {
      colSegs.add(<int>[]);
    }
    for (final s in bySegA) {
      final c = g.lane[segHead[s]];
      colSegs[c].add(s);
      colOf[s] = c;
    }
  }

  final GraphLayout g;
  final int n;
  final int u;
  final int gravity;
  final int reach;
  final int rounds;
  final int budget;

  /// Skip windows that no kept exchange can have changed (§4.7 "Skipping"); false only in the tests.
  final bool skip;

  /// Segment of every node; per segment its head (lowest node) and reservation [segA, segB).
  late final Int32List seg;
  late final int segCount;
  late final Int32List segHead;
  late final Int64List segA;
  late final Int64List segB;

  /// Per segment, the lowest level of any term of its cost: 10·a − 3U, or lower for the horizontal
  /// of a blocked merge (D9) into it, which sits at up(p) below its clipped vertical.
  late final Int64List segLo;

  // Horizontals (the non-straight edges): parent-side and child-side segment, level in ticks;
  // byLevel / levelSorted list all of them ascending by (level, index).
  late final int hCount;
  late final Int32List hPar;
  late final Int32List hChild;
  late final Int64List hLevel;
  late final Int32List byLevel;
  late final Int64List levelSorted;

  // Per segment: incident horizontals (either side), CSR.
  late final Int32List incStart;
  late final Int32List incH;

  // Per segment: its verticals, lo[] and hi[] each sorted, CSR; plus the lowest lo, highest hi.
  late final Int32List vStart;
  late final Int64List vLo;
  late final Int64List vHi;
  late final Int64List vMin;
  late final Int64List vMax;

  /// Column of every segment.
  late final Int32List colOf;

  /// Per column, its segments ascending by reservation start (disjoint reservations).
  final List<List<int>> colSegs = [];

  int _spent = 0;

  /// Runs the search; returns the new lane of every node.
  Int32List run() {
    if (n == 0) return Int32List(0);
    final inM = Uint8List(segCount);
    List<int>? previous; // level spans of the exchanges the previous round kept
    for (var r = 0; r < rounds; r++) {
      final kept = <int>[];
      if (!_swapRound(inM, skip ? previous : null, kept)) break;
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
    if (n == 0) return 0;
    final all = List<int>.generate(segCount, (s) => s);
    return localCost(all, Uint8List(segCount)..fillRange(0, segCount, 1));
  }

  /// Segments = maximal chains of straight edges; reservations = the union of their nodes' §4.3
  /// intervals, recomputed exactly as the packing computed them.
  void _segments() {
    final y = g.y, fp = g.fp, lane = g.lane, priority = g.input.priority;
    final chStart = g.chStart, chIdx = g.chIdx, chPos = g.chPos;

    final cont = Int32List(n)..fillRange(0, n, -1);
    for (var i = 0; i < n; i++) {
      final f = fp[i];
      if (f < 0) continue;
      final c = cont[f];
      if (c < 0 || priority[i] < priority[c]) cont[f] = i;
    }

    // Parents have larger indices: a descending scan meets a segment's head first.
    final seg = Int32List(n);
    final heads = Int32List(n);
    var count = 0;
    for (var i = n - 1; i >= 0; i--) {
      final f = fp[i];
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
      var end = y[i];
      final c = cont[i];
      if (c >= 0 && y[c] - u > end) end = y[c] - u;
      for (var s = chStart[i]; s < chStart[i + 1]; s++) {
        if (chPos[s] >= 1 && y[chIdx[s]] - u > end) end = y[chIdx[s]] - u;
      }
      final f = fp[i];
      final a = f >= 0 ? y[f] + u : y[i];
      final b = end + 2 * u;
      final s = seg[i];
      if (a < segA[s]) segA[s] = a;
      if (b > segB[s]) segB[s] = b;
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
    final y = g.y, routes = g.routes, edgeParent = g.edgeParent, edgeChild = g.edgeChild;
    final edgeCount = g.edgeCount;
    final seg = this.seg, segCount = this.segCount, segA = this.segA;

    var hCount = 0;
    final vCount = Int32List(segCount + 1);
    for (var e = 0; e < edgeCount; e++) {
      final sp = seg[edgeParent[e]], si = seg[edgeChild[e]];
      switch (routes[e]) {
        case routeStraight:
          vCount[sp + 1]++;
        case routeMerge:
          vCount[sp + 1]++;
          vCount[si + 1]++;
          hCount++;
        default:
          vCount[si + 1]++;
          hCount++;
      }
    }
    for (var s = 0; s < segCount; s++) {
      vCount[s + 1] += vCount[s];
    }
    final vStart = vCount;
    final vTotal = vStart[segCount];
    final vLo = Int64List(vTotal), vHi = Int64List(vTotal);
    final cursor = Int32List.fromList(vStart);
    final hPar = Int32List(hCount), hChild = Int32List(hCount);
    final hLevel = Int64List(hCount);
    var h = 0;
    for (var e = 0; e < edgeCount; e++) {
      final p = edgeParent[e], i = edgeChild[e];
      final sp = seg[p], si = seg[i];
      final botP = 10 * y[p], botI = 10 * y[i];
      final top = botP + 5 * u;
      switch (routes[e]) {
        case routeStraight:
          final k = cursor[sp]++;
          vLo[k] = top;
          vHi[k] = botI;
        case routeMerge:
          final dn = botI - 2 * u;
          var k = cursor[sp]++;
          vLo[k] = top;
          vHi[k] = dn;
          k = cursor[si]++;
          vLo[k] = dn;
          vHi[k] = botI;
          hPar[h] = sp;
          hChild[h] = si;
          hLevel[h] = dn;
          h++;
        default:
          final up = botP + 7 * u;
          final floor = 10 * segA[si] - 3 * u;
          final k = cursor[si]++;
          vLo[k] = up > floor ? up : floor;
          vHi[k] = botI;
          hPar[h] = sp;
          hChild[h] = si;
          hLevel[h] = up;
          h++;
      }
    }
    final vMin = Int64List(segCount), vMax = Int64List(segCount);
    for (var s = 0; s < segCount; s++) {
      final lo = Int64List.sublistView(vLo, vStart[s], vStart[s + 1])..sort();
      final hi = Int64List.sublistView(vHi, vStart[s], vStart[s + 1])..sort();
      vMin[s] = lo.isEmpty ? 0 : lo.first;
      vMax[s] = hi.isEmpty ? 0 : hi.last;
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
      var lo = 10 * segA[s] - 3 * u;
      for (var r = incStart[s]; r < incStart[s + 1]; r++) {
        if (hLevel[incH[r]] < lo) lo = hLevel[incH[r]];
      }
      segLo[s] = lo;
    }

    final byLevel = Int32List(hCount);
    for (var k = 0; k < hCount; k++) {
      byLevel[k] = k;
    }
    byLevel.sort((a, b) {
      final la = hLevel[a], lb = hLevel[b];
      if (la != lb) return la < lb ? -1 : 1;
      return a - b;
    });
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

  /// m(s, λ): the number of segment s's verticals with lo < λ < hi.
  int m(int s, int level) {
    if (level <= vMin[s] || level >= vMax[s]) return 0;
    final vLo = this.vLo, vHi = this.vHi;
    final start = vStart[s], end = vStart[s + 1];
    var lo = start, hi = end;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (vLo[mid] < level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    final below = lo - start;
    lo = start;
    hi = end;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (vHi[mid] <= level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return below - (lo - start);
  }

  /// The verticals at level λ in column c. Reservations in a column are disjoint and a segment's
  /// verticals lie in [10·a − 3U, 10·(b − U)], so only the last segment with 10·a − 3U < λ can
  /// hold one.
  int mAt(int c, int level) {
    final list = colSegs[c], segA = this.segA, u3 = 3 * u;
    var lo = 0, hi = list.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (10 * segA[list[mid]] - u3 < level) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo == 0 ? 0 : m(list[lo - 1], level);
  }

  /// Exact model cost of everything that involves a segment in [members] ([inM] marks them):
  /// the crossings of their horizontals and of their verticals, their horizontals' run lengths,
  /// their gravity. Each crossing and each run is counted once.
  int localCost(List<int> members, Uint8List inM) {
    var x = 0, len = 0, grav = 0;
    for (final s in members) {
      final cs = colOf[s];
      grav += gravity * cs * (segB[s] - segA[s]);
      // Horizontals of s against every vertical between their ends.
      for (var r = incStart[s]; r < incStart[s + 1]; r++) {
        final h = incH[r];
        final other = hPar[h] == s ? hChild[h] : hPar[h];
        if (inM[other] != 0 && hPar[h] != s) continue; // counted from its parent side
        final xo = colOf[other];
        final lo = cs < xo ? cs : xo, hi = cs < xo ? xo : cs;
        len += hi - lo;
        final level = hLevel[h];
        for (var c = lo + 1; c < hi; c++) {
          x += mAt(c, level);
        }
        _spent += hi - lo;
      }
      // Horizontals of non-members that pass over s's column inside s's vertical extent.
      final from = vMin[s], to = vMax[s];
      if (to <= from) continue;
      var lo = 0, hi = hCount;
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (levelSorted[mid] <= from) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      for (var k = lo; k < hCount && levelSorted[k] < to; k++) {
        _spent++;
        final h = byLevel[k];
        final pa = hPar[h], ch = hChild[h];
        if (inM[pa] != 0 || inM[ch] != 0) continue;
        final xa = colOf[pa], xb = colOf[ch];
        if ((xa < cs && cs < xb) || (xb < cs && cs < xa)) x += m(s, levelSorted[k]);
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
    final segA = this.segA, segB = this.segB, segLo = this.segLo;
    bool touched(List<int> spans, int lo, int hi) {
      _spent += spans.length >> 1; // the skip test is charged to the budget too
      for (var k = 0; k < spans.length; k += 2) {
        if (spans[k] < hi && lo < spans[k + 1]) return true;
      }
      return false;
    }

    for (var d = 1; d <= reach; d++) {
      for (var c = 1; c + d < colSegs.length; c++) {
        final left = colSegs[c], right = colSegs[c + d];
        var i = 0, j = 0;
        while (i < left.length || j < right.length) {
          if (_spent > budget) return moved;
          // One window: from the earlier of the two next segments, while reservations overlap.
          final i0 = i, j0 = j;
          var end = -0x3FFFFFFFFFFFFFFF;
          while (true) {
            final takeLeft = i < left.length && (j >= right.length || segA[left[i]] <= segA[right[j]]);
            if (!takeLeft && j >= right.length) break;
            final t = takeLeft ? left[i] : right[j];
            if ((i > i0 || j > j0) && segA[t] >= end) break;
            if (segB[t] > end) end = segB[t];
            if (takeLeft) {
              i++;
            } else {
              j++;
            }
          }
          final fromLeft = left.sublist(i0, i), fromRight = right.sublist(j0, j);
          final members = [...fromLeft, ...fromRight];
          var spanLo = 0x3FFFFFFFFFFFFFFF;
          for (final s in members) {
            if (segLo[s] < spanLo) spanLo = segLo[s];
          }
          final spanHi = 10 * end;
          if (previous != null && !touched(previous, spanLo, spanHi) && !touched(kept, spanLo, spanHi)) continue;
          for (final s in members) {
            inM[s] = 1;
          }
          final before = localCost(members, inM);
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

  /// Replaces list[from, to) with [segs], all now in column c. Charges the shifted tail to the
  /// budget.
  void _place(List<int> list, int from, int to, List<int> segs, int c) {
    _spent += list.length - from;
    list.replaceRange(from, to, segs);
    for (final s in segs) {
      colOf[s] = c;
    }
  }
}
