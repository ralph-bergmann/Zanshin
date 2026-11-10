import 'dart:typed_data';

import 'package:zanshin_core/src/graph_layout/layout_engine.dart';

/// Where [chooseColumns] put every branch.
final class Placement {
  Placement(this.column, this.chainOf, this.main, this.columnOf, this.lo, this.hi);

  /// The column of every node.
  final Int32List column;

  /// The branch (first-parent chain) of every node.
  final Int32List chainOf;

  /// The main branch.
  final int main;

  /// The column of every branch.
  final Int32List columnOf;

  /// What every branch takes in its column: the rows [lo] … [hi] of the requested mode.
  final Int64List lo;
  final Int64List hi;
}

/// The lab's column choice (README, steps 1 and 2).
///
/// 1. The main branch is in column 0, and nothing else is.
/// 2. A branch (a first-parent chain) gets one column for its whole life.
/// 3. A column is taken only where the branch has cards — or, with [reserveToMerge], from its fork
///    up to its last merge, so its lines run straight.
/// 4. Branches are placed oldest first, each in the free column nearest to the column it docks to
///    (the left one on a tie). With [shortFirst] the shortest branch is placed first, each in the
///    free column nearest to the main branch: a short branch sits inside, a long one runs around it.
///
/// Reads the engine's rows ([LayoutEngine.layering] must have run). Plain code on purpose: every
/// placement scans its candidate columns.
///
/// With [sameColumns] the result is the same in both modes, as the product engine guaranteed
/// before columns per mode: a column is free for a branch only if it is free in Compact's rows and in Free's, and
/// Free's rows decide the order and the main branch. (With Compact's rows deciding, Free gets
/// many more crossings: README, step 8.)
///
/// With [endsFirst] (and [shortFirst]) the branch that ends first is placed first, and of two that
/// end on one row the shorter. A branch inside another still sits nearer to the main branch; of
/// two that overlap in part, the one that merges first does, whichever is shorter (README, step 9).
///
/// With [fewestSkipped] (and [shortFirst]) the branch that skips the fewest cards is placed before
/// all that: the cards of the branch it forks from that lie between its fork and its end.
///
/// With [dockToParent] (and [shortFirst]) a side branch sits next to its branch: a branch that
/// forks from another branch than the main one and merges into no third branch takes the free
/// column nearest to that branch (the left one on a tie). Such branches are placed after the
/// branch they fork from (README, step 11).
Placement chooseColumns(
  LayoutEngine e, {
  required bool reserveToMerge,
  required bool shortFirst,
  required bool sameColumns,
  required bool endsFirst,
  required bool fewestSkipped,
  required bool dockToParent,
}) {
  final int n = e.n;
  final int own = e.requestedModel;
  final int lead = sameColumns ? 1 : own; // the model whose rows order the branches
  final List<int> models = sameColumns ? const [0, 1] : [own];
  final Int64List y = e.modelY[lead];
  final Int32List fp = e.fp;
  final Int32List priority = e.input.priority;
  final Int32List cont = e.continuations();

  // Chains. Parents have larger indices, so a descending scan meets a chain's bottom card first.
  final chainOf = Int32List(n);
  final bottoms = <int>[];
  for (int i = n - 1; i >= 0; i--) {
    final int f = fp[i];
    if (f >= 0 && cont[f] == i) {
      chainOf[i] = chainOf[f];
    } else {
      chainOf[i] = bottoms.length;
      bottoms.add(i);
    }
  }
  final int chains = bottoms.length;

  /// What each chain takes in its column in model [m]: [lo, hi], in that model's rows.
  (Int64List, Int64List) spans(int m) {
    final Int64List y = e.modelY[m];
    final int u = modelUnits[m];
    final lo = Int64List(chains);
    final hi = Int64List(chains);
    for (var c = 0; c < chains; c++) {
      lo[c] = y[bottoms[c]];
      hi[c] = y[bottoms[c]];
    }
    for (var i = 0; i < n; i++) {
      final int c = chainOf[i];
      if (y[i] > hi[c]) {
        hi[c] = y[i];
      }
    }
    if (reserveToMerge) {
      for (var c = 0; c < chains; c++) {
        final int f = fp[bottoms[c]];
        if (f >= 0 && y[f] + u < lo[c]) {
          lo[c] = y[f] + u;
        }
      }
      for (var k = 0; k < e.edgeCount; k++) {
        final int child = e.edgeChild[k];
        if (k == e.lpStart[child]) {
          continue; // a first parent: no merge
        }
        final int c = chainOf[e.edgeParent[k]];
        if (y[child] - u > hi[c]) {
          hi[c] = y[child] - u;
        }
      }
    }
    return (lo, hi);
  }

  final spanOf = <int, (Int64List, Int64List)>{
    for (final int m in {...models, own}) m: spans(m),
  };
  final (Int64List lo, Int64List hi) = spanOf[lead]!;

  // The main branch: the chain of the node with the least (priority, row, index).
  var best = 0;
  for (var i = 1; i < n; i++) {
    if (priority[i] < priority[best] || (priority[i] == priority[best] && y[i] <= y[best])) {
      best = i;
    }
  }
  final int main = n == 0 ? -1 : chainOf[best];

  // Per branch, the branch it forks from (the main branch for one without a parent), and how many
  // forks lie between it and the main branch. A parent has a larger index than its child, so the
  // branch a branch forks from has a smaller number and is done first.
  final from = Int32List(chains);
  final depth = Int32List(chains);
  // Whether a branch merges into another branch than the one it forks from: then it docks to the
  // main branch, like the branches that fork from it.
  final elsewhere = List<bool>.filled(chains, false);
  for (var c = 0; c < chains; c++) {
    final int f = fp[bottoms[c]];
    from[c] = f >= 0 ? chainOf[f] : main;
  }
  for (var k = 0; k < e.edgeCount; k++) {
    final int child = e.edgeChild[k];
    final int c = chainOf[e.edgeParent[k]];
    if (k != e.lpStart[child] && chainOf[child] != from[c]) {
      elsewhere[c] = true;
    }
  }
  for (var c = 0; c < chains; c++) {
    final bool toMain = c == main || from[c] == main || elsewhere[c];
    depth[c] = c == main ? 0 : (toMain ? 1 : depth[from[c]] + 1);
  }

  // Per branch, the cards it skips: those of the branch it forks from that lie between its fork and its end.
  final skipped = Int32List(chains);
  if (fewestSkipped) {
    final rowsOf = List.generate(chains, (_) => <int>[]);
    for (var i = 0; i < n; i++) {
      rowsOf[chainOf[i]].add(y[i]);
    }
    for (var c = 0; c < chains; c++) {
      if (from[c] == c) {
        continue;
      }
      for (final int row in rowsOf[from[c]]) {
        if (row >= lo[c] && row <= hi[c]) {
          skipped[c]++;
        }
      }
    }
  }

  // The main branch before everything; then the branch that skips the fewest cards, ends first, is
  // the shortest, or has the oldest bottom card.
  final order = [for (var c = 0; c < chains; c++) c]
    ..sort((a, b) {
      if (a == main || b == main) {
        return a == b ? 0 : (a == main ? -1 : 1);
      }
      // A branch docks to the branch it forks from, so that one has to be placed first.
      if (shortFirst && dockToParent && depth[a] != depth[b]) {
        return depth[a].compareTo(depth[b]);
      }
      if (shortFirst && fewestSkipped && skipped[a] != skipped[b]) {
        return skipped[a].compareTo(skipped[b]);
      }
      if (shortFirst && endsFirst && hi[a] != hi[b]) {
        return hi[a].compareTo(hi[b]);
      }
      if (shortFirst && hi[a] - lo[a] != hi[b] - lo[b]) {
        return (hi[a] - lo[a]).compareTo(hi[b] - lo[b]);
      }
      final int ia = bottoms[a];
      final int ib = bottoms[b];
      if (y[ia] != y[ib]) {
        return y[ia].compareTo(y[ib]);
      }
      return priority[ia] != priority[ib] ? priority[ia].compareTo(priority[ib]) : ia.compareTo(ib);
    });

  final columnOf = Int32List(chains);
  final columns = <List<int>>[<int>[]]; // per column, the chains in it; column 0 is the main branch's
  bool free(int k, int c) {
    if (k >= columns.length) {
      return true;
    }
    for (final int m in models) {
      final (Int64List lo, Int64List hi) = spanOf[m]!;
      final int u = modelUnits[m];
      for (final int o in columns[k]) {
        // Two cards of one column must be at least one pitch apart.
        if (lo[o] < hi[c] + u && lo[c] < hi[o] + u) {
          return false;
        }
      }
    }
    return true;
  }

  for (final int c in order) {
    var k = 0;
    if (c != main) {
      // With shortFirst a branch may come before the branch it forks from, so it docks to the main
      // branch; with dockToParent the order puts that branch first.
      final int dock = shortFirst && (!dockToParent || elsewhere[c]) ? 0 : columnOf[from[c]];
      for (var d = 0; ; d++) {
        if (dock - d >= 1 && free(dock - d, c)) {
          k = dock - d;
          break;
        }
        if (d > 0 && free(dock + d, c)) {
          k = dock + d;
          break;
        }
      }
    }
    while (columns.length <= k) {
      columns.add(<int>[]);
    }
    columns[k].add(c);
    columnOf[c] = k;
  }

  final column = Int32List(n);
  for (var i = 0; i < n; i++) {
    column[i] = columnOf[chainOf[i]];
  }
  return Placement(column, chainOf, main, columnOf, spanOf[own]!.$1, spanOf[own]!.$2);
}
