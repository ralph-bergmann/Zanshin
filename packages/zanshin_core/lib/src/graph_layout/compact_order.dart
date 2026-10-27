// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'layout_engine.dart';
import 'sort.dart';

// The `compact` lane order on the joint packing (docs/graph-layout.md §4.7, amended 2026-10-27,
// Story 4.14), ported from the spike's Dart reference (spikes/graph-layout-ab/dart/lib/src/
// compact_order.dart, `JointCompactOrder`) byte for byte; only the budget comes from the request
// and the sorts are the monomorphic ones of sort.dart.

/// κ: the cost per column per row pitch of a segment's reservation (§4.7).
const compactGravity = 24;

/// Exchanges pair column c with c + 1 … c + [compactReach] (§4.7).
const compactReach = 8;

/// At most this many exchange rounds (§4.7).
const compactRounds = 16;

/// The weight of each model's cost (§4.7, amended 2026-10-27): joint cost = 16·cost_compact +
/// cost_free, both models' per-pitch costs scaled to stay integer.
const modelWeights = <int>[16, 1];

/// The `compact` lane order (§4.7, amended 2026-10-27): the new lane (= column) of every node of
/// the joint greedy layout [engine]. The search stops at the first window after the work units it
/// has spent exceed [budget] (§4.7, "stop the search"), so it may overshoot [budget] by one window.
///
/// It keeps the joint packing's continuation chains ("segments") intact and exchanges the segments
/// of two columns inside one window at a time, where a window is a connected component of the two
/// columns' segments under "reservations overlap in some model". An exchange stays when it lowers
/// Σ weight·(U·(400·X + 4·Len) + κ·Σ column·(reservation length)) over both vertical models, with
/// X and Len the crossings and horizontal run lengths of §4.6's tick model in that model. Lane 0's
/// segments stay in column 0; columns left empty are dropped at the end. The result does not
/// depend on the engine's mode.
///
/// Needs [LayoutEngine.packLanes], [LayoutEngine.markBlocked] and [LayoutEngine.route] to have run.
Int32List compactColumns(LayoutEngine engine, {required int budget}) => CompactOrder(engine, budget: budget).run();

/// The search state of [compactColumns]. Public for the engine's tests.
final class CompactOrder {
  /// The search over the joint greedy layout [g], with the request's [budget] and the §4.7
  /// constants; [skip] is false only in the tests.
  CompactOrder(
    this.g, {
    required this.budget,
    this.gravity = compactGravity,
    this.reach = compactReach,
    this.rounds = compactRounds,
    this.skip = true,
  }) : n = g.n {
    if (n == 0) {
      segCount = 0;
      return;
    }
    _segments();
    colOf = Int32List(segCount);
    for (var s = 0; s < segCount; s++) {
      colOf[s] = g.lane[segHead[s]];
    }
    for (var k = 0; k < 2; k++) {
      models.add(CompactModel._(this, g.modelY[k], modelUnits[k], g.routesOf(k), modelWeights[k]));
    }
  }

  /// The joint greedy layout the search starts from.
  final LayoutEngine g;

  /// The node count.
  final int n;

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

  /// The two models, `compact` first (its reservation starts order the windows).
  final List<CompactModel> models = [];

  /// cont(j) of §4.3.
  late final Int32List cont;

  /// The segment of every node.
  late final Int32List seg;

  /// The number of segments.
  late final int segCount;

  /// Each segment's head (lowest node).
  late final Int32List segHead;

  /// The column of every segment.
  late final Int32List colOf;

  var _spent = 0;

  /// Per model k, the members of every window of the current column pair ascending by model k's
  /// reservation start, CSR offsets ([_components]).
  final List<Int32List> _compStart = [];

  /// Per model k, the windows' members (see [_compStart]).
  final List<Int32List> _compMembers = [];

  /// Scratch: the model-0 window of every segment of the current column pair.
  late final _window0 = Int32List(segCount);

  /// Runs the search; returns the new lane of every node.
  Int32List run() {
    if (n == 0) {
      return Int32List(0);
    }
    final inM = Uint8List(segCount);
    List<List<int>>? previous; // per model, the level spans of the exchanges the previous round kept
    for (var r = 0; r < rounds; r++) {
      final List<List<int>> kept = [for (var k = 0; k < models.length; k++) <int>[]];
      if (!_swapRound(inM, skip ? previous : null, kept)) {
        break;
      }
      previous = kept;
    }
    // Drop empty columns, keeping the order of the others (no crossing or run can grow).
    final List<List<int>> columns = models[0].colSegs;
    final newCol = Int32List(columns.length);
    var next = 0;
    for (var c = 0; c < columns.length; c++) {
      newCol[c] = columns[c].isEmpty && c > 0 ? -1 : next++;
    }
    final lane = Int32List(n);
    for (var i = 0; i < n; i++) {
      lane[i] = newCol[colOf[seg[i]]];
    }
    return lane;
  }

  /// The joint model cost of the current columns: Σ weight·[CompactModel.localCost] over every
  /// segment.
  int totalCost() {
    if (n == 0) {
      return 0;
    }
    final all = List<int>.generate(segCount, (s) => s);
    return _cost(all, Uint8List(segCount)..fillRange(0, segCount, 1));
  }

  int _cost(List<int> members, Uint8List inM) {
    var sum = 0;
    for (final CompactModel m in models) {
      sum += m.weight * m.localCost(members, inM);
    }
    return sum;
  }

  /// Segments = maximal chains of straight edges of the joint packing (lane(fp(i)) = lane(i)).
  void _segments() {
    final Int32List fp = g.fp;
    final Int32List lane = g.lane;
    cont = g.continuations();
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
    this.seg = seg;
    segCount = count;
    segHead = Int32List.sublistView(heads, 0, count);
  }

  /// The windows of columns [cl] and [cr]: per model the §4.7 sweep cuts windows where no
  /// reservation reaches the next start; a union-find joins the model-0 windows that share a segment
  /// with one window of the other model. The components are numbered by their least model-0 start.
  /// Returns their count.
  int _components(int cl, int cr) {
    final int mc = models.length;
    final int pairSize = models[0].colSegs[cl].length + models[0].colSegs[cr].length;
    final seqs = <Int32List>[];
    final groupStart = <List<int>>[];
    for (final CompactModel m in models) {
      final (Int32List seq, List<int> starts) = m.sweep(cl, cr);
      seqs.add(seq);
      groupStart.add(starts);
    }
    final List<int> g0 = groupStart[0];
    final int g0Count = g0.length - 1;
    final parent = Int32List(g0Count);
    for (var k = 0; k < g0Count; k++) {
      parent[k] = k;
    }
    int find(int x) {
      var r = x;
      while (parent[r] != r) {
        parent[r] = parent[parent[r]];
        r = parent[r];
      }
      return r;
    }

    final Int32List seq0 = seqs[0];
    for (var w = 0; w < g0Count; w++) {
      for (int p = g0[w]; p < g0[w + 1]; p++) {
        _window0[seq0[p]] = w;
      }
    }
    for (var k = 1; k < mc; k++) {
      final List<int> starts = groupStart[k];
      final Int32List seq = seqs[k];
      for (var w = 0; w + 1 < starts.length; w++) {
        // Join every model-0 window this window touches; a root is always its set's least window.
        int root = find(_window0[seq[starts[w]]]);
        for (int p = starts[w] + 1; p < starts[w + 1]; p++) {
          final int r = find(_window0[seq[p]]);
          if (r < root) {
            parent[root] = r;
            root = r;
          } else if (r > root) {
            parent[r] = root;
          }
        }
      }
    }
    final compOf = Int32List(g0Count)..fillRange(0, g0Count, -1);
    var count = 0;
    for (var w = 0; w < g0Count; w++) {
      final int r = find(w);
      if (compOf[r] < 0) {
        compOf[r] = count++;
      }
      compOf[w] = compOf[r];
    }
    _compStart.clear();
    _compMembers.clear();
    for (var k = 0; k < mc; k++) {
      final Int32List seq = seqs[k];
      final start = Int32List(count + 1);
      for (var p = 0; p < pairSize; p++) {
        start[compOf[_window0[seq[p]]] + 1]++;
      }
      for (var c = 0; c < count; c++) {
        start[c + 1] += start[c];
      }
      final cursor = Int32List.fromList(start);
      final members = Int32List(pairSize);
      for (var p = 0; p < pairSize; p++) {
        members[cursor[compOf[_window0[seq[p]]]]++] = seq[p];
      }
      _compStart.add(start);
      _compMembers.add(members);
    }
    return count;
  }

  /// Whether some span of [spans] (pairs lo, hi) meets [lo, hi); charges half the list's length.
  bool _touched(List<int> spans, int lo, int hi) {
    _spent += spans.length >> 1; // the skip test is charged to the budget too
    for (var k = 0; k < spans.length; k += 2) {
      if (spans[k] < hi && lo < spans[k + 1]) {
        return true;
      }
    }
    return false;
  }

  /// One round (§4.7, amended 2026-10-27): for d = 1 … reach and c = 1, 2, …, try every window of
  /// the column pair (c, c + d) by its least `compact` start. True if an exchange stayed; [kept]
  /// collects, per model, the level span [lo, hi) of each exchange that stayed. After the first
  /// round ([previous] non-null) a window is skipped iff in both models its span meets no span kept
  /// since the previous round began.
  bool _swapRound(Uint8List inM, List<List<int>>? previous, List<List<int>> kept) {
    var moved = false;
    final int mc = models.length;
    final spanLo = List<int>.filled(mc, 0);
    final spanHi = List<int>.filled(mc, 0);
    for (var d = 1; d <= reach; d++) {
      for (var c = 1; c + d < models[0].colSegs.length; c++) {
        final int count = _components(c, c + d);
        for (var w = 0; w < count; w++) {
          if (_spent > budget) {
            return moved;
          }
          for (var k = 0; k < mc; k++) {
            final CompactModel m = models[k];
            final Int32List start = _compStart[k];
            final Int32List members = _compMembers[k];
            var lo = 0x3FFFFFFFFFFFFFFF;
            var end = -0x3FFFFFFFFFFFFFFF;
            for (int p = start[w]; p < start[w + 1]; p++) {
              final int s = members[p];
              if (m.segLo[s] < lo) {
                lo = m.segLo[s];
              }
              if (m.segB[s] > end) {
                end = m.segB[s];
              }
            }
            spanLo[k] = lo;
            spanHi[k] = 10 * end;
          }
          if (previous != null) {
            var touched = false;
            for (var k = 0; k < mc && !touched; k++) {
              touched = _touched(previous[k], spanLo[k], spanHi[k]) || _touched(kept[k], spanLo[k], spanHi[k]);
            }
            if (!touched) {
              continue;
            }
          }
          final members = Int32List.sublistView(_compMembers[0], _compStart[0][w], _compStart[0][w + 1]);
          for (final s in members) {
            inM[s] = 1;
          }
          final int before = _cost(members, inM);
          _exchange(w, c, c + d, inM);
          if (_cost(members, inM) < before) {
            moved = true;
            for (var k = 0; k < mc; k++) {
              kept[k]
                ..add(spanLo[k])
                ..add(spanHi[k]);
            }
          } else {
            _exchange(w, c, c + d, inM);
          }
          for (final s in members) {
            inM[s] = 0;
          }
        }
      }
    }
    return moved;
  }

  /// Moves every member of window [w] to the other column of the pair ([cl], [cr]) and rebuilds both
  /// columns' lists in every model.
  void _exchange(int w, int cl, int cr, Uint8List inM) {
    for (var k = 0; k < models.length; k++) {
      final CompactModel m = models[k];
      final members = Int32List.sublistView(_compMembers[k], _compStart[k][w], _compStart[k][w + 1]);
      final fromLeft = <int>[];
      final fromRight = <int>[];
      for (final s in members) {
        (colOf[s] == cl ? fromLeft : fromRight).add(s);
      }
      // Both leaving positions before either list changes: rebuilding one column moves the
      // arrivals' positions.
      final int leftFirst = fromLeft.isEmpty ? -1 : m.pos[fromLeft.first];
      final int rightFirst = fromRight.isEmpty ? -1 : m.pos[fromRight.first];
      _spent += m.rebuild(cl, leftFirst, fromRight, inM);
      _spent += m.rebuild(cr, rightFirst, fromLeft, inM);
    }
    for (final s in Int32List.sublistView(_compMembers[0], _compStart[0][w], _compStart[0][w + 1])) {
      colOf[s] = colOf[s] == cl ? cr : cl;
    }
  }
}

/// One vertical model's part of [CompactOrder]: its segment reservations, §4.6's tick model per
/// segment (§4.7) and every column's segments ascending by its reservation start.
final class CompactModel {
  CompactModel._(this._o, this.y, this.u, this.routes, this.weight) {
    _reservations();
    _geometry();
    _columns();
  }

  final CompactOrder _o;

  /// This model's y.
  final Int64List y;

  /// This model's U.
  final int u;

  /// This model's route per layout edge.
  final Uint8List routes;

  /// This model's cost weight ([modelWeights]).
  final int weight;

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

  /// Per column, its segments ascending by this model's reservation start (disjoint reservations).
  final List<List<int>> colSegs = [];

  /// Each segment's index in its column's [colSegs] list.
  late final Int32List pos;

  /// Reservations = the union of the segment's nodes' §4.3 intervals in this model.
  void _reservations() {
    final LayoutEngine g = _o.g;
    final int n = _o.n;
    final Int32List seg = _o.seg;
    final Int32List cont = _o.cont;
    final Int32List fp = g.fp;
    final Int32List chStart = g.chStart;
    final Int32List chIdx = g.chIdx;
    final Int32List chPos = g.chPos;
    final int count = _o.segCount;
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
    this.segA = segA;
    this.segB = segB;
  }

  /// §4.6's tick model per segment over this model's y, U and routes. A blocked merge's vertical
  /// (D9) is clipped to its segment's reservation start 10·a − 3U, so every vertical of a segment
  /// lies in [10·a − 3U, 10·(b − U)].
  void _geometry() {
    final LayoutEngine g = _o.g;
    final Int32List edgeParent = g.edgeParent;
    final Int32List edgeChild = g.edgeChild;
    final int edgeCount = g.edgeCount;
    final Int32List seg = _o.seg;
    final int segCount = _o.segCount;
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

  /// Every column's segments ascending by reservation start.
  void _columns() {
    final int segCount = _o.segCount;
    final Int32List colOf = _o.colOf;
    final bySegA = Int32List(segCount);
    for (var s = 0; s < segCount; s++) {
      bySegA[s] = s;
    }
    sortIndicesStable(bySegA, segA);
    for (var c = 0; c < _o.g.laneCount; c++) {
      colSegs.add(<int>[]);
    }
    pos = Int32List(segCount);
    for (final s in bySegA) {
      final List<int> list = colSegs[colOf[s]];
      pos[s] = list.length;
      list.add(s);
    }
  }

  /// The segments of columns [cl] and [cr] ascending by reservation start (left first on a tie),
  /// and the start of each §4.7 window in that sequence (plus the end): a window grows while the
  /// next segment starts before its largest b.
  (Int32List, List<int>) sweep(int cl, int cr) {
    final List<int> left = colSegs[cl];
    final List<int> right = colSegs[cr];
    final seq = Int32List(left.length + right.length);
    final starts = <int>[];
    var i = 0;
    var j = 0;
    var p = 0;
    var end = -0x3FFFFFFFFFFFFFFF;
    while (i < left.length || j < right.length) {
      final bool takeLeft = i < left.length && (j >= right.length || segA[left[i]] <= segA[right[j]]);
      final int t = takeLeft ? left[i++] : right[j++];
      if (p == 0 || segA[t] >= end) {
        starts.add(p);
        end = segB[t];
      } else if (segB[t] > end) {
        end = segB[t];
      }
      seq[p++] = t;
    }
    starts.add(p);
    return (seq, starts);
  }

  /// Rebuilds column [c]'s list: its window members (marked in [inM]; the first at index
  /// [leaveFirst], or −1 for none) go, [arrive] (ascending start) come. Returns the work: the list's
  /// length minus its first changed index.
  int rebuild(int c, int leaveFirst, List<int> arrive, Uint8List inM) {
    final List<int> list = colSegs[c];
    final int oldLen = list.length;
    var first = leaveFirst < 0 ? oldLen : leaveFirst;
    if (arrive.isNotEmpty) {
      final int a = segA[arrive.first];
      var lo = 0;
      var hi = first;
      while (lo < hi) {
        final int mid = (lo + hi) >> 1;
        if (segA[list[mid]] < a) {
          lo = mid + 1;
        } else {
          hi = mid;
        }
      }
      first = lo;
    }
    final List<int> tail = list.sublist(first);
    list.length = first;
    var r = 0;
    for (final s in tail) {
      if (inM[s] != 0) {
        continue;
      }
      while (r < arrive.length && segA[arrive[r]] < segA[s]) {
        pos[arrive[r]] = list.length;
        list.add(arrive[r++]);
      }
      pos[s] = list.length;
      list.add(s);
    }
    while (r < arrive.length) {
      pos[arrive[r]] = list.length;
      list.add(arrive[r++]);
    }
    return oldLen - first;
  }

  /// m(s, λ): the number of segment [s]'s verticals with lo < λ < hi, λ = [level].
  int m(int s, int level) {
    if (level <= vMin[s] || level >= vMax[s]) {
      return 0;
    }
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

  /// The exact model cost in this model of everything that involves a segment in [members] ([inM]
  /// marks them): the crossings of their horizontals and of their verticals, their horizontals'
  /// run lengths, their gravity. Each crossing and each run is counted once.
  int localCost(List<int> members, Uint8List inM) {
    final Int32List colOf = _o.colOf;
    final int gravity = _o.gravity;
    var x = 0;
    var len = 0;
    var grav = 0;
    var spent = 0;
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
        spent += hi - lo;
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
        spent++;
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
    _o._spent += spent;
    return u * (400 * x + 4 * len) + grav;
  }
}
