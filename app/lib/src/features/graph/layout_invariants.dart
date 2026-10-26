// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';

import 'graph_layout.dart';
import 'vertical_layout.dart';

/// A hard invariant every fixture passes (Story 10.1 item 14).
enum LayoutInvariant {
  /// Node keys are unique.
  uniqueKeys,

  /// Every edge references existing nodes.
  noDanglingEdge,

  /// No (child, parent) pair appears twice.
  noDuplicateEdge,

  /// Every child sits at least one pitch above each parent: rowOf(child) ≥ rowOf(parent) + U.
  childAboveParent,

  /// No two cards in one column overlap: in the row modes no two nodes closer than one pitch (at U = 1, no shared
  /// (row, col) cell); for [PerNodeTops], no vertical overlap.
  noOverlappingCards,
}

/// One violated invariant, with what violates it.
@immutable
class LayoutViolation {
  /// Creates a violation.
  const LayoutViolation(this.invariant, this.message);

  /// The violated invariant.
  final LayoutInvariant invariant;

  /// What violates it.
  final String message;

  @override
  String toString() => '${invariant.name}: $message';
}

/// The hard invariants [layout] violates (test/debug only; a violation is an engine or recording bug, never patched
/// in the view). With a [vertical] [PerNodeTops], the card checks use its pixel tops instead of the rows.
List<LayoutViolation> checkLayoutInvariants(GraphLayout layout, {VerticalLayout? vertical}) {
  final violations = <LayoutViolation>[];
  final int n = layout.nodeCount;
  final int u = layout.unit;
  for (var i = 0; i < n; i++) {
    final String key = layout.keyOf(i);
    if (layout.indexOfKey(key) != i) {
      violations.add(LayoutViolation(LayoutInvariant.uniqueKeys, 'key $key is not unique (node $i)'));
    }
  }
  final pairs = <(int, int)>{};
  final PerNodeTops? tops = vertical is PerNodeTops ? vertical : null;
  for (var e = 0; e < layout.edgeCount; e++) {
    final int child = layout.childOf(e);
    final int parent = layout.parentOf(e);
    if (child < 0 || child >= n || parent < 0 || parent >= n) {
      violations.add(LayoutViolation(LayoutInvariant.noDanglingEdge, 'edge $e ($child ← $parent) leaves the layout'));
      continue;
    }
    if (!pairs.add((child, parent))) {
      violations.add(LayoutViolation(LayoutInvariant.noDuplicateEdge, 'edge $e repeats ($child ← $parent)'));
    }
    final bool above = tops == null
        ? layout.rowOf(child) >= layout.rowOf(parent) + u
        : tops.top(child) + tops.metrics.cardHeight + tops.metrics.gapY <= tops.top(parent);
    if (!above) {
      violations.add(
        LayoutViolation(
          LayoutInvariant.childAboveParent,
          'edge $e: child ${layout.keyOf(child)} is not a pitch above parent ${layout.keyOf(parent)}',
        ),
      );
    }
  }
  // Per column, consecutive cards by their vertical position.
  final byCol = <int, List<int>>{};
  for (var i = 0; i < n; i++) {
    (byCol[layout.colOf(i)] ??= <int>[]).add(i);
  }
  for (final MapEntry<int, List<int>>(key: col, value: nodes) in byCol.entries) {
    if (tops == null) {
      nodes.sort((a, b) => layout.rowOf(a).compareTo(layout.rowOf(b)));
    } else {
      nodes.sort((a, b) => tops.top(a).compareTo(tops.top(b)));
    }
    for (var k = 1; k < nodes.length; k++) {
      final int a = nodes[k - 1];
      final int b = nodes[k];
      final bool apart = tops == null
          ? layout.rowOf(b) - layout.rowOf(a) >= u
          : tops.top(b) - tops.top(a) >= tops.metrics.cardHeight;
      if (!apart) {
        violations.add(
          LayoutViolation(
            LayoutInvariant.noOverlappingCards,
            'column $col: ${layout.keyOf(a)} and ${layout.keyOf(b)} overlap',
          ),
        );
      }
    }
  }
  return violations;
}
