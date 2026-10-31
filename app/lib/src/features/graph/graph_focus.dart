// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'graph_layout.dart';

/// The hover focus path of [node] (Story 10.6 item 4): one byte per node, non-zero for [node], all its ancestors and
/// all its descendants along the layout's edges. Two walks, O(n + E).
Uint8List graphFocusSet(GraphLayout layout, int node) {
  const ancestor = 1;
  const descendant = 2;
  final set = Uint8List(layout.nodeCount);
  set[node] = ancestor | descendant;
  final stack = <int>[node];
  while (stack.isNotEmpty) {
    final int n = stack.removeLast();
    final (:int start, :int end) = layout.parentEdges(n);
    for (var edge = start; edge < end; edge++) {
      final int parent = layout.parentOf(edge);
      if (set[parent] & ancestor == 0) {
        set[parent] |= ancestor;
        stack.add(parent);
      }
    }
  }
  stack.add(node);
  while (stack.isNotEmpty) {
    final int n = stack.removeLast();
    final (:int start, :int end) = layout.childEdges(n);
    for (var slot = start; slot < end; slot++) {
      final int child = layout.childOf(layout.childEdgeAt(slot));
      if (set[child] & descendant == 0) {
        set[child] |= descendant;
        stack.add(child);
      }
    }
  }
  return set;
}
