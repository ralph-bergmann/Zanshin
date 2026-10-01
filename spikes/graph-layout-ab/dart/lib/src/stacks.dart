// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'input.dart';
import 'layout.dart';

// Commit stacks (Story 4.13): docs/graph-layout.md §4.8 over a finished ungrouped layout — linear
// runs grouped into stack nodes, the columns kept, only the rows recomputed. Dart-only, like the
// `compact` order: the Rust reference has no stacks. The product engine
// (packages/zanshin_core/lib/src/graph_layout/stacks.dart) is the same code. Flat typed arrays and
// CSR, no per-node objects, and no sort: every order comes from the ungrouped visit order or the
// free walk.

/// A [StackInput.workingCopy] code: the node is no workspace's working copy.
const int workingCopyNone = 0;

/// A [StackInput.workingCopy] code: another workspace's working copy.
const int workingCopyOther = 1;

/// A [StackInput.workingCopy] code: this workspace's `@`.
const int workingCopyThis = 2;

/// Run states (§3 `"state"`).
const int runExpanded = 0;
const int runCollapsed = 1;
const List<String> runStateNames = ['expanded', 'collapsed'];

/// Request bits per node: named in `expanded`, `collapsed` or `keep_open`.
const int _markExpanded = 1;
const int _markCollapsed = 2;
const int _markKeepOpen = 4;

/// The stack request with the per-node facts the run rule reads (§2, amended), index-aligned with
/// the [LayoutInput]; the request is already resolved to node indices.
final class StackInput {
  StackInput({
    required this.immutable,
    required this.parentCount,
    required this.hasRef,
    required this.workingCopy,
    required this.expandedNodes,
    required this.collapsedNodes,
    required this.keepOpenNodes,
  });

  final Uint8List immutable;
  final Int32List parentCount;
  final Uint8List hasRef;

  /// [workingCopyNone], [workingCopyOther] or [workingCopyThis].
  final Uint8List workingCopy;
  final Int32List expandedNodes;
  final Int32List collapsedNodes;
  final Int32List keepOpenNodes;
}

/// The stack pass of docs/graph-layout.md §4.8 over [layout], a finished ungrouped layout (every
/// phase of [computeLayout] run): the runs and their state (steps 1–3), the grouped graph G′ with
/// the fixed columns (steps 4–5), its least rows (step 6), and its routes, `blocked` flags and
/// buckets (step 7).
final class StackLayout {
  StackLayout(this.layout, this.stacks) : n = layout.n, unit = layout.unit;

  final GraphLayout layout;
  final StackInput stacks;
  final int n;

  /// U (§1).
  final int unit;

  // ---- §4.8 steps 1–3: the runs and their state.
  late final int runCount;
  late final Int32List runStart; // R + 1; runs ordered by newest member
  late final Int32List runMembers; // oldest (m_1) first
  late final Uint8List runState; // runExpanded / runCollapsed
  late final Int32List runNode; // stack node or −1
  late final Int32List nodeRun; // n, run or −1
  late final int stackCount;
  late final Int32List stackRun; // S
  late final Uint8List hidden; // n
  late final Int32List image; // n: img(v)

  // ---- steps 4–5: the grouped graph G′ over n + S nodes.
  late final int nodeTotal;
  late final Int32List edgeStart; // n + S + 1, by child
  late final Int32List edgeFrom; // §3's order
  late final Int32List edgeTo;
  late final Uint8List edgeKind;
  late final Int32List childStart; // n + S + 1
  late final Int32List childIdx;
  late final Int32List childPos;
  late final Int32List laneOf; // −1 hidden
  late final Int32List colOf; // −1 hidden
  late final Uint8List split; // S

  // ---- steps 6–7.
  late final Int32List levelOrder; // the visit order through img, ascending in Y
  late final Int64List rowOf; // y′, −1 hidden
  late final Uint8List blocked;
  late final Uint8List routes;
  Int64List bucketValue = Int64List(0);
  Int64List bucketStart = Int64List(0);
  Int64List bucketEnd = Int64List(0);
  late final int rows;
  late final int lanes;

  // (C)'s constraints by target while they are built: counted, then filled.
  late Int32List _cStart;
  Int32List? _cCursor;
  late Int32List _cSource;
  late Int64List _cDelta;

  /// §4.8 steps 1–7 [stacks].
  void run() {
    _runs();
    _state();
    _graph();
    _rows();
    _route();
    _buckets();
  }

  int _newest(int r) => runMembers[runStart[r + 1] - 1];

  int _firstParent(int v) => edgeStart[v] < edgeStart[v + 1] ? edgeFrom[edgeStart[v]] : -1;

  /// Steps 1–2: the candidates, the links and the runs, numbered by newest member ascending.
  void _runs() {
    final input = layout.input;
    final isRoot = input.isRoot, parStart = input.parStart, parKind = input.parKind;
    final chStart = layout.chStart, chIdx = layout.chIdx, fp = layout.fp;
    final immutable = stacks.immutable, parentCount = stacks.parentCount;
    final hasRef = stacks.hasRef, workingCopy = stacks.workingCopy;

    final cand = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (isRoot[i] == 0 &&
          workingCopy[i] == workingCopyNone &&
          hasRef[i] == 0 &&
          parentCount[i] == 1 &&
          parStart[i + 1] - parStart[i] == 1 &&
          parKind[parStart[i]] == kindDirect &&
          chStart[i + 1] - chStart[i] == 1) {
        cand[i] = 1;
      }
    }
    // link(i) = c; linked[c] = 1 ⇔ c is some node's link, whose only layout parent is then fp(c).
    final next = Int32List(n)..fillRange(0, n, -1);
    final linked = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (cand[i] == 0) continue;
      final c = chIdx[chStart[i]];
      if (cand[c] != 0 && (immutable[c] != 0) == (immutable[i] != 0)) {
        next[i] = c;
        linked[c] = 1;
      }
    }
    // A run's newest member is linked and links on to nothing: ascending i numbers the runs.
    var runCount = 0, memberCount = 0;
    for (var i = 0; i < n; i++) {
      if (linked[i] == 0 || next[i] >= 0) continue;
      runCount++;
      memberCount++;
      for (var v = i; linked[v] != 0; v = fp[v]) {
        memberCount++;
      }
    }
    final runStart = Int32List(runCount + 1);
    final runMembers = Int32List(memberCount);
    final nodeRun = Int32List(n)..fillRange(0, n, -1);
    var r = 0, m = 0;
    for (var i = 0; i < n; i++) {
      if (linked[i] == 0 || next[i] >= 0) continue;
      var k = 1;
      for (var v = i; linked[v] != 0; v = fp[v]) {
        k++;
      }
      runStart[r] = m;
      // Oldest first: m_k = i goes last, m_1 (the largest index) first.
      var v = i;
      for (var j = m + k - 1; j >= m; j--) {
        runMembers[j] = v;
        nodeRun[v] = r;
        v = fp[v];
      }
      m += k;
      r++;
    }
    runStart[runCount] = m;
    this.runCount = runCount;
    this.runStart = runStart;
    this.runMembers = runMembers;
    this.nodeRun = nodeRun;
  }

  /// Step 3: every run's state from the request and the default, the stack nodes and img.
  void _state() {
    final lpStart = layout.lpStart, edgeParent = layout.edgeParent;
    final immutable = stacks.immutable, workingCopy = stacks.workingCopy;

    // A: this workspace's @ and every node reached from it through mutable layout parents.
    final inA = Uint8List(n);
    final work = Int32List(n);
    var top = 0;
    for (var i = 0; i < n; i++) {
      if (workingCopy[i] == workingCopyThis) {
        inA[i] = 1;
        work[top++] = i;
      }
    }
    while (top > 0) {
      final v = work[--top];
      for (var e = lpStart[v]; e < lpStart[v + 1]; e++) {
        final p = edgeParent[e];
        if (inA[p] == 0 && immutable[p] == 0) {
          inA[p] = 1;
          work[top++] = p;
        }
      }
    }
    final marks = Uint8List(n);
    for (final v in stacks.expandedNodes) {
      marks[v] |= _markExpanded;
    }
    for (final v in stacks.collapsedNodes) {
      marks[v] |= _markCollapsed;
    }
    for (final v in stacks.keepOpenNodes) {
      marks[v] |= _markKeepOpen;
    }

    final runState = Uint8List(runCount);
    final runNode = Int32List(runCount)..fillRange(0, runCount, -1);
    final hidden = Uint8List(n);
    final image = Int32List(n);
    for (var i = 0; i < n; i++) {
      image[i] = i;
    }
    var stackCount = 0;
    for (var r = 0; r < runCount; r++) {
      final m1 = runMembers[runStart[r]];
      var expanded = false;
      for (var j = runStart[r]; j < runStart[r + 1]; j++) {
        if (marks[runMembers[j]] & _markKeepOpen != 0) expanded = true;
      }
      if (!expanded) {
        if (marks[m1] & _markExpanded != 0) {
          expanded = true;
        } else if (marks[m1] & _markCollapsed == 0) {
          expanded = inA[_newest(r)] != 0;
        }
      }
      if (expanded) {
        runState[r] = runExpanded;
        continue;
      }
      runState[r] = runCollapsed;
      final s = n + stackCount++;
      runNode[r] = s;
      for (var j = runStart[r]; j < runStart[r + 1]; j++) {
        hidden[runMembers[j]] = 1;
        image[runMembers[j]] = s;
      }
    }
    final stackRun = Int32List(stackCount);
    for (var r = 0; r < runCount; r++) {
      if (runNode[r] >= 0) stackRun[runNode[r] - n] = r;
    }
    this.runState = runState;
    this.runNode = runNode;
    this.hidden = hidden;
    this.image = image;
    this.stackCount = stackCount;
    this.stackRun = stackRun;
  }

  /// Steps 4–5: the grouped edges in §3's order, their children, and the fixed columns.
  void _graph() {
    final lpStart = layout.lpStart, edgeParent = layout.edgeParent, kinds = layout.edgeKind;
    final fp = layout.fp, lane = layout.lane, col = layout.col;
    final total = n + stackCount;

    var edgeTotal = stackCount;
    for (var v = 0; v < n; v++) {
      if (hidden[v] == 0) edgeTotal += lpStart[v + 1] - lpStart[v];
    }
    final edgeStart = Int32List(total + 1);
    final edgeFrom = Int32List(edgeTotal);
    final edgeTo = Int32List(edgeTotal);
    final edgeKind = Uint8List(edgeTotal);
    var e = 0;
    for (var v = 0; v < n; v++) {
      edgeStart[v] = e;
      if (hidden[v] != 0) continue;
      for (var k = lpStart[v]; k < lpStart[v + 1]; k++) {
        edgeFrom[e] = image[edgeParent[k]];
        edgeTo[e] = v;
        edgeKind[e] = kinds[k];
        e++;
      }
    }
    for (var s = 0; s < stackCount; s++) {
      final r = stackRun[s];
      edgeStart[n + s] = e;
      edgeFrom[e] = image[fp[runMembers[runStart[r]]]];
      edgeTo[e] = n + s;
      edgeKind[e] = kindDirect;
      e++;
    }
    edgeStart[total] = e;

    // Children CSR: a scan over the edges, which are ordered by child, keeps every list ascending.
    final childStart = Int32List(total + 1);
    for (var k = 0; k < edgeTotal; k++) {
      childStart[edgeFrom[k] + 1]++;
    }
    for (var v = 0; v < total; v++) {
      childStart[v + 1] += childStart[v];
    }
    final cursor = Int32List.fromList(childStart);
    final childIdx = Int32List(edgeTotal);
    final childPos = Int32List(edgeTotal);
    for (var k = 0; k < edgeTotal; k++) {
      final slot = cursor[edgeFrom[k]]++;
      childIdx[slot] = edgeTo[k];
      childPos[slot] = k - edgeStart[edgeTo[k]];
    }

    final laneOf = Int32List(total);
    final colOf = Int32List(total);
    for (var v = 0; v < n; v++) {
      laneOf[v] = hidden[v] != 0 ? -1 : lane[v];
      colOf[v] = hidden[v] != 0 ? -1 : col[v];
    }
    final split = Uint8List(stackCount);
    for (var s = 0; s < stackCount; s++) {
      final r = stackRun[s];
      final newest = _newest(r);
      laneOf[n + s] = lane[newest];
      colOf[n + s] = col[newest];
      if (col[runMembers[runStart[r]]] != col[newest]) split[s] = 1;
    }
    nodeTotal = total;
    this.edgeStart = edgeStart;
    this.edgeFrom = edgeFrom;
    this.edgeTo = edgeTo;
    this.edgeKind = edgeKind;
    this.childStart = childStart;
    this.childIdx = childIdx;
    this.childPos = childPos;
    this.laneOf = laneOf;
    this.colOf = colOf;
    this.split = split;
  }

  /// Step 6: the least rows y′ under (E), (F) and (C), level by level in Y.
  void _rows() {
    final total = nodeTotal;
    final y = layout.y, visitOrder = layout.visitOrder;

    // Y, and the visit order through img (ascending in Y): every grouped node once — the n + S
    // indices less the hidden ones.
    final level = Int64List(total);
    final visit = Int32List(total);
    var k = 0;
    for (var j = 0; j < n; j++) {
      final v = visitOrder[j];
      if (hidden[v] == 0) {
        level[v] = y[v];
        visit[k++] = v;
      } else if (_newest(nodeRun[v]) == v) {
        final s = image[v];
        level[s] = y[v];
        visit[k++] = s;
      }
    }
    final order = Int32List.sublistView(visit, 0, k);
    levelOrder = order;
    final count = order.length;

    // (C): the grouped nodes per column, ascending in Y (a counting sort of [order] by column).
    var columns = 0;
    for (var v = 0; v < total; v++) {
      if (colOf[v] >= columns) columns = colOf[v] + 1;
    }
    final colStart = Int32List(columns + 1);
    for (var j = 0; j < count; j++) {
      colStart[colOf[order[j]] + 1]++;
    }
    for (var c = 0; c < columns; c++) {
      colStart[c + 1] += colStart[c];
    }
    final colCursor = Int32List.fromList(colStart);
    final colNodes = Int32List(count);
    for (var j = 0; j < count; j++) {
      final v = order[j];
      colNodes[colCursor[colOf[v]]++] = v;
    }
    _cStart = Int32List(total + 1);
    _cCursor = null;
    _segmentConstraints(colStart, colNodes);
    for (var v = 0; v < total; v++) {
      _cStart[v + 1] += _cStart[v];
    }
    _cSource = Int32List(_cStart[total]);
    _cDelta = Int64List(_cStart[total]);
    _cCursor = Int32List.fromList(_cStart);
    _segmentConstraints(colStart, colNodes);

    // (F), `free` only: each node's predecessor in W′ and the summed gaps of the ungrouped walk.
    final walkPrev = Int32List(total)..fillRange(0, total, -1);
    final walkDelta = Int64List(total);
    final walk = layout.freeOrder, t = layout.freeT;
    if (walk != null && t != null) {
      var x = 0, prev = -1, prevX = 0;
      for (var j = 0; j < n; j++) {
        final w = walk[j];
        if (j > 0) x += freeGap(t[w] - t[walk[j - 1]]);
        if (hidden[w] != 0 && _newest(nodeRun[w]) != w) continue;
        final v = image[w];
        if (prev >= 0) {
          walkPrev[v] = prev;
          walkDelta[v] = x - prevX;
        }
        prev = v;
        prevX = x;
      }
    }

    // The least solution, one group of equal Y at a time; within a group, passes until nothing
    // changes (the direction alternates: it changes only the number of passes, never the result).
    final rowOf = Int64List(total)..fillRange(0, total, -1);
    var start = 0;
    while (start < count) {
      final y0 = level[order[start]];
      var end = start + 1;
      while (end < count && level[order[end]] == y0) {
        end++;
      }
      var forward = true, changed = true;
      var passes = 0;
      while (changed) {
        // SPEC §4.8 step 6: at most |group| + 1 passes (only δ = 0 constraints inside a group).
        assert(++passes <= end - start + 1, 'a group of equal Y did not settle');
        changed = false;
        for (var j = 0; j < end - start; j++) {
          final v = order[forward ? start + j : end - 1 - j];
          final value = _least(v, rowOf, walkPrev, walkDelta);
          if (value != rowOf[v]) {
            rowOf[v] = value;
            changed = true;
          }
        }
        forward = !forward;
      }
      start = end;
    }
    var maxRow = 0, maxLane = 0;
    for (var v = 0; v < total; v++) {
      if (rowOf[v] > maxRow) maxRow = rowOf[v];
    }
    for (var i = 0; i < n; i++) {
      if (layout.lane[i] > maxLane) maxLane = layout.lane[i];
    }
    this.rowOf = rowOf;
    rows = n == 0 ? 0 : maxRow + unit;
    lanes = n == 0 ? 0 : maxLane + 1;
  }

  /// The value of [v] in one pass: the maximum of 0 and of y′(source) + δ over every constraint on
  /// [v] whose source is set (≥ 0 in [rowOf]).
  int _least(int v, Int64List rowOf, Int32List walkPrev, Int64List walkDelta) {
    var value = 0;
    for (var e = edgeStart[v]; e < edgeStart[v + 1]; e++) {
      final p = rowOf[edgeFrom[e]];
      if (p >= 0 && p + unit > value) value = p + unit;
    }
    final u = walkPrev[v];
    if (u >= 0 && rowOf[u] >= 0 && rowOf[u] + walkDelta[v] > value) value = rowOf[u] + walkDelta[v];
    for (var c = _cStart[v]; c < _cStart[v + 1]; c++) {
      final s = rowOf[_cSource[c]];
      if (s >= 0 && s + _cDelta[c] > value) value = s + _cDelta[c];
    }
    return value;
  }

  /// (C) of step 6 over the per-column lists: for each two adjacent segments, S below (top u) and
  /// T above (lowest h), y′(t) ≥ y′(u) + δ₁ and y′(t) ≥ y′(c) + δ₂ for every grouped edge (x, c)
  /// with x in S and pos ≥ 1. Counts per target while [_cCursor] is null, fills afterwards.
  void _segmentConstraints(Int32List colStart, Int32List colNodes) {
    final columns = colStart.length - 1;
    for (var c = 0; c < columns; c++) {
      var segment = colStart[c];
      for (var j = colStart[c] + 1; j < colStart[c + 1]; j++) {
        final h = colNodes[j];
        final parent = _firstParent(h);
        if (parent == colNodes[j - 1]) continue;
        final fromCard = parent < 0 || (h >= n && split[h - n] != 0);
        final target = fromCard ? h : parent;
        final below = fromCard ? 2 * unit : unit;
        final merges = fromCard ? unit : 0;
        _addConstraint(target, colNodes[j - 1], below);
        for (var x = segment; x < j; x++) {
          final node = colNodes[x];
          for (var s = childStart[node]; s < childStart[node + 1]; s++) {
            if (childPos[s] >= 1) _addConstraint(target, childIdx[s], merges);
          }
        }
        segment = j;
      }
    }
  }

  void _addConstraint(int target, int source, int delta) {
    final cursor = _cCursor;
    if (cursor == null) {
      _cStart[target + 1]++;
      return;
    }
    final slot = cursor[target]++;
    _cSource[slot] = source;
    _cDelta[slot] = delta;
  }

  /// Step 7: §4.4 `blocked` over per-lane y′ lists and §4.5 routes on G′, with the fixed lanes.
  void _route() {
    final total = nodeTotal;
    final order = levelOrder;
    final count = order.length;
    var laneCount = 0;
    for (var v = 0; v < total; v++) {
      if (laneOf[v] >= laneCount) laneCount = laneOf[v] + 1;
    }
    // [order] is ascending in Y, and within a lane y′ ascends with Y, so each list comes out sorted.
    final laneYStart = Int32List(laneCount + 1);
    for (var j = 0; j < count; j++) {
      laneYStart[laneOf[order[j]] + 1]++;
    }
    for (var l = 0; l < laneCount; l++) {
      laneYStart[l + 1] += laneYStart[l];
    }
    final cursor = Int32List.fromList(laneYStart);
    final laneYs = Int64List(count);
    for (var j = 0; j < count; j++) {
      final v = order[j];
      laneYs[cursor[laneOf[v]]++] = rowOf[v];
    }
    final edgeTotal = edgeFrom.length;
    final blocked = Uint8List(edgeTotal);
    final routes = Uint8List(edgeTotal);
    for (var e = 0; e < edgeTotal; e++) {
      final p = edgeFrom[e], i = edgeTo[e];
      final lp = laneOf[p];
      if (laneOf[i] == lp) {
        routes[e] = routeStraight;
        continue;
      }
      // First y′ > y′(p) in lane(p)'s list.
      final yp = rowOf[p];
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
      if (lo < end && laneYs[lo] <= rowOf[i]) blocked[e] = 1;
      routes[e] = e - edgeStart[i] >= 1 && blocked[e] == 0 ? routeMerge : routeBranchOff;
    }
    this.blocked = blocked;
    this.routes = routes;
  }

  /// Step 7, `free` only: §4.2 step 4's day buckets over W′ — the visible non-root nodes and the
  /// stack nodes, a stack node in the day of T(m_k). T and y′ never decrease along W′.
  void _buckets() {
    final walk = layout.freeOrder, t = layout.freeT;
    if (walk == null || t == null) return;
    final isRoot = layout.input.isRoot, utcOffsetMin = layout.input.utcOffsetMin;
    var count = 0, last = 0;
    for (var j = 0; j < n; j++) {
      final w = walk[j];
      if (isRoot[w] != 0 || (hidden[w] != 0 && _newest(nodeRun[w]) != w)) continue;
      final key = dayKey(t[w], utcOffsetMin);
      if (count == 0 || key != last) {
        count++;
        last = key;
      }
    }
    final bucketValue = Int64List(count);
    final bucketStart = Int64List(count);
    final bucketEnd = Int64List(count);
    var b = -1;
    for (var j = 0; j < n; j++) {
      final w = walk[j];
      if (isRoot[w] != 0 || (hidden[w] != 0 && _newest(nodeRun[w]) != w)) continue;
      final key = dayKey(t[w], utcOffsetMin);
      final y = rowOf[image[w]];
      if (b < 0 || key != bucketValue[b]) {
        b++;
        bucketValue[b] = key;
        bucketStart[b] = y;
      }
      bucketEnd[b] = y;
    }
    this.bucketValue = bucketValue;
    this.bucketStart = bucketStart;
    this.bucketEnd = bucketEnd;
  }

  /// The grouped result (§3 with stacks), laid out with [order].
  LayoutResult result(LaneOrder order) {
    final bucketKind = Uint8List(bucketValue.length)..fillRange(0, bucketValue.length, bucketDay);
    return LayoutResult(
      mode: layout.mode,
      order: order,
      unit: unit,
      rows: rows,
      lanes: lanes,
      row: rowOf,
      lane: laneOf,
      col: colOf,
      edgeFrom: edgeFrom,
      edgeTo: edgeTo,
      edgeKind: edgeKind,
      edgeRoute: routes,
      edgeBlocked: blocked,
      bucketKind: bucketKind,
      bucketValue: bucketValue,
      bucketStart: bucketStart,
      bucketEnd: bucketEnd,
      stackCount: stackCount,
      nodeRun: nodeRun,
      runState: runState,
      runNode: runNode,
      runStart: runStart,
      runMembers: runMembers,
    );
  }
}
