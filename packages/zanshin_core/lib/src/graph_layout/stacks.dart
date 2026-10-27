// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'graph_grid_view.dart';
import 'layout_engine.dart';
import 'layout_input.dart';
import 'layout_request.dart';

// Commit stacks (Story 4.13): docs/graph-layout.md §4.8 over a finished ungrouped layout — linear
// runs grouped into stack nodes, the columns kept, only the rows recomputed. The same code as the
// spike's Dart reference (spikes/graph-layout-ab/dart/lib/src/stacks.dart) and byte-identical to
// it. Flat typed arrays and CSR, no per-node objects, and no sort: every order comes from the
// ungrouped visit order or the free walk.

/// Request bits per node: named in `expanded`, `collapsed` or `keep_open`.
const _markExpanded = 1;
const _markCollapsed = 2;
const _markKeepOpen = 4;

/// The stack pass of docs/graph-layout.md §4.8 over [engine], a finished ungrouped layout (every
/// phase of `computeGraphGrid` run): the runs and their state (steps 1–3), the grouped graph G′
/// with the fixed columns (steps 4–5), its least rows (step 6), and its routes, `blocked` flags and
/// buckets (step 7). Public for the engine's tests; callers use `computeGraphGrid`.
final class StackLayout {
  /// The pass over [engine] with the facts and request of [stacks], which must be valid
  /// ([validateStackInput]); [run] computes it.
  StackLayout(this.engine, this.stacks) : n = engine.n, unit = engine.unit;

  /// The finished ungrouped layout.
  final LayoutEngine engine;

  /// The facts and the resolved request.
  final StackInput stacks;

  /// n, the topology nodes.
  final int n;

  /// U (§1).
  final int unit;

  // ---- §4.8 steps 1–3: the runs and their state.

  /// R, the runs.
  late final int runCount;

  /// The runs' member CSR offsets (R + 1); the runs are ordered by their newest member.
  late final Int32List runStart;

  /// Every run's members, oldest (m_1) first.
  late final Int32List runMembers;

  /// Each run's state: [GraphGridView.runExpanded] or [GraphGridView.runCollapsed].
  late final Uint8List runState;

  /// Each run's stack node, or −1 for an expanded run.
  late final Int32List runNode;

  /// Each topology node's run, or −1.
  late final Int32List nodeRun;

  /// S, the stack nodes n … n + S − 1 (the collapsed runs, in run order).
  late final int stackCount;

  /// Each stack node's run (S entries).
  late final Int32List stackRun;

  /// 1 for a hidden node (a member of a collapsed run).
  late final Uint8List hidden;

  /// img(v): v itself, or the stack node of a hidden node's run (n entries).
  late final Int32List image;

  // ---- steps 4–5: the grouped graph G′ over n + S nodes.

  /// n + S.
  late final int nodeTotal;

  /// The grouped edges' CSR offsets by child (n + S + 1); a hidden node has none.
  late final Int32List edgeStart;

  /// Each grouped edge's parent, in §3's order (child ascending, then position).
  late final Int32List edgeFrom;

  /// Each grouped edge's child.
  late final Int32List edgeTo;

  /// Each grouped edge's kind ([parentDirect] or [parentIndirect]).
  late final Uint8List edgeKind;

  /// The grouped children's CSR offsets (n + S + 1).
  late final Int32List childStart;

  /// The grouped children of every node, ascending per node.
  late final Int32List childIdx;

  /// The grouped edge's position among its child's grouped parents, per entry of [childIdx].
  late final Int32List childPos;

  /// Each grouped node's lane (a stack node: its newest member's); −1 for a hidden node.
  late final Int32List laneOf;

  /// Each grouped node's column (a stack node: its newest member's); −1 for a hidden node.
  late final Int32List colOf;

  /// 1 for the stack node of a split run (col(m_1) ≠ col(m_k)), per stack node (S entries).
  late final Uint8List split;

  // ---- steps 6–7: rows, routes, buckets.

  /// The grouped nodes in the ungrouped visit order through img: ascending in Y.
  late final Int32List levelOrder;

  /// y′, the grouped rows; −1 for a hidden node.
  late final Int64List rowOf;

  /// `blocked` per grouped edge (0 or 1).
  late final Uint8List blocked;

  /// The route per grouped edge.
  late final Uint8List routes;

  /// `free`'s day buckets over W′: each bucket's value; empty in `compact`.
  var bucketValue = Int64List(0);

  /// Each bucket's least member y′.
  var bucketStart = Int64List(0);

  /// Each bucket's largest member y′.
  var bucketEnd = Int64List(0);

  /// max y′ + U, or 0 without nodes.
  late final int rows;

  /// The ungrouped `lanes`.
  late final int lanes;

  // (C)'s constraints by target while they are built: counted, then filled.
  late Int32List _cStart;
  Int32List? _cCursor;
  late Int32List _cSource;
  late Int64List _cDelta;

  /// §4.8 steps 1–7, bench phase `stacks`.
  void run() {
    _runs();
    _state();
    _graph();
    _rows();
    _route();
    _buckets();
  }

  /// The newest member m_k of run [r].
  int _newest(int r) => runMembers[runStart[r + 1] - 1];

  /// The first grouped parent fp′([v]), or −1.
  int _firstParent(int v) => edgeStart[v] < edgeStart[v + 1] ? edgeFrom[edgeStart[v]] : -1;

  /// Steps 1–2: the candidates, the links and the runs, numbered by newest member ascending.
  void _runs() {
    final LayoutInput input = engine.input;
    final Uint8List isRoot = input.isRoot;
    final Int32List parStart = input.parStart;
    final Uint8List parKind = input.parKind;
    final Int32List chStart = engine.chStart;
    final Int32List chIdx = engine.chIdx;
    final Int32List fp = engine.fp;
    final Uint8List immutable = stacks.immutable;
    final Int32List parentCount = stacks.parentCount;
    final Uint8List hasRef = stacks.hasRef;
    final Uint8List workingCopy = stacks.workingCopy;

    final cand = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (isRoot[i] == 0 &&
          workingCopy[i] == workingCopyNone &&
          hasRef[i] == 0 &&
          parentCount[i] == 1 &&
          parStart[i + 1] - parStart[i] == 1 &&
          parKind[parStart[i]] == parentDirect &&
          chStart[i + 1] - chStart[i] == 1) {
        cand[i] = 1;
      }
    }
    // link(i) = c; linked[c] = 1 ⇔ c is some node's link, whose only layout parent is then fp(c).
    final next = Int32List(n)..fillRange(0, n, -1);
    final linked = Uint8List(n);
    for (var i = 0; i < n; i++) {
      if (cand[i] == 0) {
        continue;
      }
      final int c = chIdx[chStart[i]];
      if (cand[c] != 0 && (immutable[c] != 0) == (immutable[i] != 0)) {
        next[i] = c;
        linked[c] = 1;
      }
    }
    // A run's newest member is linked and links on to nothing: ascending i numbers the runs.
    var runCount = 0;
    var memberCount = 0;
    for (var i = 0; i < n; i++) {
      if (linked[i] == 0 || next[i] >= 0) {
        continue;
      }
      runCount++;
      memberCount++;
      for (var v = i; linked[v] != 0; v = fp[v]) {
        memberCount++;
      }
    }
    final runStart = Int32List(runCount + 1);
    final runMembers = Int32List(memberCount);
    final nodeRun = Int32List(n)..fillRange(0, n, -1);
    var r = 0;
    var m = 0;
    for (var i = 0; i < n; i++) {
      if (linked[i] == 0 || next[i] >= 0) {
        continue;
      }
      var k = 1;
      for (var v = i; linked[v] != 0; v = fp[v]) {
        k++;
      }
      runStart[r] = m;
      // Oldest first: m_k = i goes last, m_1 (the largest index) first.
      var v = i;
      for (int j = m + k - 1; j >= m; j--) {
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
    final Int32List lpStart = engine.lpStart;
    final Int32List edgeParent = engine.edgeParent;
    final Uint8List immutable = stacks.immutable;
    final Uint8List workingCopy = stacks.workingCopy;

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
      final int v = work[--top];
      for (int e = lpStart[v]; e < lpStart[v + 1]; e++) {
        final int p = edgeParent[e];
        if (inA[p] == 0 && immutable[p] == 0) {
          inA[p] = 1;
          work[top++] = p;
        }
      }
    }
    final marks = Uint8List(n);
    for (final int v in stacks.expandedNodes) {
      marks[v] |= _markExpanded;
    }
    for (final int v in stacks.collapsedNodes) {
      marks[v] |= _markCollapsed;
    }
    for (final int v in stacks.keepOpenNodes) {
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
      final int m1 = runMembers[runStart[r]];
      var expanded = false;
      for (int j = runStart[r]; j < runStart[r + 1]; j++) {
        if (marks[runMembers[j]] & _markKeepOpen != 0) {
          expanded = true;
        }
      }
      if (!expanded) {
        if (marks[m1] & _markExpanded != 0) {
          expanded = true;
        } else if (marks[m1] & _markCollapsed == 0) {
          expanded = inA[_newest(r)] != 0;
        }
      }
      if (expanded) {
        runState[r] = GraphGridView.runExpanded;
        continue;
      }
      runState[r] = GraphGridView.runCollapsed;
      final int s = n + stackCount++;
      runNode[r] = s;
      for (int j = runStart[r]; j < runStart[r + 1]; j++) {
        hidden[runMembers[j]] = 1;
        image[runMembers[j]] = s;
      }
    }
    final stackRun = Int32List(stackCount);
    for (var r = 0; r < runCount; r++) {
      if (runNode[r] >= 0) {
        stackRun[runNode[r] - n] = r;
      }
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
    final Int32List lpStart = engine.lpStart;
    final Int32List edgeParent = engine.edgeParent;
    final Uint8List kinds = engine.edgeKind;
    final Int32List fp = engine.fp;
    final Int32List lane = engine.lane;
    final Int32List col = engine.col;
    final int total = n + stackCount;

    int edgeTotal = stackCount;
    for (var v = 0; v < n; v++) {
      if (hidden[v] == 0) {
        edgeTotal += lpStart[v + 1] - lpStart[v];
      }
    }
    final edgeStart = Int32List(total + 1);
    final edgeFrom = Int32List(edgeTotal);
    final edgeTo = Int32List(edgeTotal);
    final edgeKind = Uint8List(edgeTotal);
    var e = 0;
    for (var v = 0; v < n; v++) {
      edgeStart[v] = e;
      if (hidden[v] != 0) {
        continue;
      }
      for (int k = lpStart[v]; k < lpStart[v + 1]; k++) {
        edgeFrom[e] = image[edgeParent[k]];
        edgeTo[e] = v;
        edgeKind[e] = kinds[k];
        e++;
      }
    }
    for (var s = 0; s < stackCount; s++) {
      final int r = stackRun[s];
      edgeStart[n + s] = e;
      edgeFrom[e] = image[fp[runMembers[runStart[r]]]];
      edgeTo[e] = n + s;
      edgeKind[e] = parentDirect;
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
      final int slot = cursor[edgeFrom[k]]++;
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
      final int r = stackRun[s];
      final int newest = _newest(r);
      laneOf[n + s] = lane[newest];
      colOf[n + s] = col[newest];
      if (col[runMembers[runStart[r]]] != col[newest]) {
        split[s] = 1;
      }
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
    final int total = nodeTotal;
    final Int64List y = engine.y;
    final Int32List visitOrder = engine.visitOrder;

    // Y, and the visit order through img (ascending in Y): every grouped node once — the n + S
    // indices less the hidden ones.
    final level = Int64List(total);
    final visit = Int32List(total);
    var k = 0;
    for (var j = 0; j < n; j++) {
      final int v = visitOrder[j];
      if (hidden[v] == 0) {
        level[v] = y[v];
        visit[k++] = v;
      } else if (_newest(nodeRun[v]) == v) {
        final int s = image[v];
        level[s] = y[v];
        visit[k++] = s;
      }
    }
    final order = Int32List.sublistView(visit, 0, k);
    levelOrder = order;
    final int count = order.length;

    // (C): the grouped nodes per column, ascending in Y (a counting sort of [order] by column).
    var columns = 0;
    for (var v = 0; v < total; v++) {
      if (colOf[v] >= columns) {
        columns = colOf[v] + 1;
      }
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
      final int v = order[j];
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
    final Int32List? walk = engine.freeOrder;
    final Int64List? t = engine.freeT;
    if (walk != null && t != null) {
      var x = 0;
      var prev = -1;
      var prevX = 0;
      for (var j = 0; j < n; j++) {
        final int w = walk[j];
        if (j > 0) {
          x += freeGap(t[w] - t[walk[j - 1]]);
        }
        if (hidden[w] != 0 && _newest(nodeRun[w]) != w) {
          continue;
        }
        final int v = image[w];
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
      final int y0 = level[order[start]];
      int end = start + 1;
      while (end < count && level[order[end]] == y0) {
        end++;
      }
      var forward = true;
      var changed = true;
      var passes = 0;
      while (changed) {
        // §4.8 step 6: at most |group| + 1 passes (only δ = 0 constraints inside a group).
        assert(++passes <= end - start + 1, 'a group of equal Y did not settle');
        changed = false;
        for (var j = 0; j < end - start; j++) {
          final int v = order[forward ? start + j : end - 1 - j];
          final int value = _least(v, rowOf, walkPrev, walkDelta);
          if (value != rowOf[v]) {
            rowOf[v] = value;
            changed = true;
          }
        }
        forward = !forward;
      }
      start = end;
    }
    var maxRow = 0;
    for (var v = 0; v < total; v++) {
      if (rowOf[v] > maxRow) {
        maxRow = rowOf[v];
      }
    }
    var maxLane = 0;
    for (var i = 0; i < n; i++) {
      if (engine.lane[i] > maxLane) {
        maxLane = engine.lane[i];
      }
    }
    this.rowOf = rowOf;
    rows = n == 0 ? 0 : maxRow + unit;
    lanes = n == 0 ? 0 : maxLane + 1;
  }

  /// The value of [v] in one pass: the maximum of 0 and of y′(source) + δ over every constraint on
  /// [v] whose source is set (≥ 0 in [rowOf]).
  int _least(int v, Int64List rowOf, Int32List walkPrev, Int64List walkDelta) {
    var value = 0;
    for (int e = edgeStart[v]; e < edgeStart[v + 1]; e++) {
      final int p = rowOf[edgeFrom[e]];
      if (p >= 0 && p + unit > value) {
        value = p + unit;
      }
    }
    final int u = walkPrev[v];
    if (u >= 0 && rowOf[u] >= 0 && rowOf[u] + walkDelta[v] > value) {
      value = rowOf[u] + walkDelta[v];
    }
    for (int c = _cStart[v]; c < _cStart[v + 1]; c++) {
      final int s = rowOf[_cSource[c]];
      if (s >= 0 && s + _cDelta[c] > value) {
        value = s + _cDelta[c];
      }
    }
    return value;
  }

  /// (C) of step 6 over the per-column lists [colNodes] (CSR [colStart]): for each two adjacent
  /// segments, S below (top u) and T above (lowest h), y′(t) ≥ y′(u) + δ₁ and y′(t) ≥ y′(c) + δ₂
  /// for every grouped edge (x, c) with x in S and pos ≥ 1. Counts per target while [_cCursor] is
  /// null, fills afterwards.
  void _segmentConstraints(Int32List colStart, Int32List colNodes) {
    final int columns = colStart.length - 1;
    for (var c = 0; c < columns; c++) {
      int segment = colStart[c];
      for (int j = colStart[c] + 1; j < colStart[c + 1]; j++) {
        final int h = colNodes[j];
        final int parent = _firstParent(h);
        if (parent == colNodes[j - 1]) {
          continue;
        }
        final bool fromCard = parent < 0 || (h >= n && split[h - n] != 0);
        final target = fromCard ? h : parent;
        final int below = fromCard ? 2 * unit : unit;
        final int merges = fromCard ? unit : 0;
        _addConstraint(target, colNodes[j - 1], below);
        for (var x = segment; x < j; x++) {
          final int node = colNodes[x];
          for (int s = childStart[node]; s < childStart[node + 1]; s++) {
            if (childPos[s] >= 1) {
              _addConstraint(target, childIdx[s], merges);
            }
          }
        }
        segment = j;
      }
    }
  }

  void _addConstraint(int target, int source, int delta) {
    final Int32List? cursor = _cCursor;
    if (cursor == null) {
      _cStart[target + 1]++;
      return;
    }
    final int slot = cursor[target]++;
    _cSource[slot] = source;
    _cDelta[slot] = delta;
  }

  /// Step 7: §4.4 `blocked` over per-lane y′ lists and §4.5 routes on G′, with the fixed lanes.
  void _route() {
    final int total = nodeTotal;
    final Int32List order = levelOrder;
    final int count = order.length;
    var laneCount = 0;
    for (var v = 0; v < total; v++) {
      if (laneOf[v] >= laneCount) {
        laneCount = laneOf[v] + 1;
      }
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
      final int v = order[j];
      laneYs[cursor[laneOf[v]]++] = rowOf[v];
    }
    final int edgeTotal = edgeFrom.length;
    final blocked = Uint8List(edgeTotal);
    final routes = Uint8List(edgeTotal);
    for (var e = 0; e < edgeTotal; e++) {
      final int p = edgeFrom[e];
      final int i = edgeTo[e];
      final int lp = laneOf[p];
      if (laneOf[i] == lp) {
        routes[e] = routeStraight;
        continue;
      }
      // First y′ > y′(p) in lane(p)'s list.
      final int yp = rowOf[p];
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
      if (lo < end && laneYs[lo] <= rowOf[i]) {
        blocked[e] = 1;
      }
      routes[e] = e - edgeStart[i] >= 1 && blocked[e] == 0 ? routeMerge : routeBranchOff;
    }
    this.blocked = blocked;
    this.routes = routes;
  }

  /// Step 7, `free` only: §4.2 step 4's day buckets over W′ — the visible non-root nodes and the
  /// stack nodes, a stack node in the day of T(m_k). T and y′ never decrease along W′.
  void _buckets() {
    final Int32List? walk = engine.freeOrder;
    final Int64List? t = engine.freeT;
    if (walk == null || t == null) {
      return;
    }
    final Uint8List isRoot = engine.input.isRoot;
    final int utcOffsetMin = engine.input.utcOffsetMin;
    var count = 0;
    var last = 0;
    for (var j = 0; j < n; j++) {
      final int w = walk[j];
      if (isRoot[w] != 0 || (hidden[w] != 0 && _newest(nodeRun[w]) != w)) {
        continue;
      }
      final int key = dayKey(t[w], utcOffsetMin);
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
      final int w = walk[j];
      if (isRoot[w] != 0 || (hidden[w] != 0 && _newest(nodeRun[w]) != w)) {
        continue;
      }
      final int key = dayKey(t[w], utcOffsetMin);
      final int y = rowOf[image[w]];
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

  /// The grid buffer of the grouped layout (format version [GraphGridView.stackFormatVersion]),
  /// laid out with [order] (the header echoes it).
  Uint8List toGrid(LaneOrder order) => writeStackGrid(
    mode: engine.mode,
    order: order,
    unit: unit,
    rows: rows,
    lanes: lanes,
    nodeRows: rowOf,
    nodeLanes: laneOf,
    nodeCols: colOf,
    nodeDays: _nodeDays(),
    edgeFroms: edgeFrom,
    edgeTos: edgeTo,
    edgeKinds: edgeKind,
    edgeRoutes: routes,
    edgeBlocked: blocked,
    bucketValues: bucketValue,
    bucketStarts: bucketStart,
    bucketEnds: bucketEnd,
    nodeRuns: nodeRun,
    runStates: runState,
    runNodes: runNode,
    runStarts: runStart,
    runMembers: runMembers,
  );

  /// The day key of every grouped node (Story 4.14): an input node's own — hidden ones included —
  /// and a stack node its newest member's.
  Int64List _nodeDays() {
    final Int64List own = engine.nodeDays();
    final days = Int64List(rowOf.length)..setRange(0, n, own);
    for (var r = 0; r < runNode.length; r++) {
      if (runNode[r] >= 0) {
        days[runNode[r]] = own[runMembers[runStart[r + 1] - 1]];
      }
    }
    return days;
  }
}
