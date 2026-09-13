// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// Where a drop lands relative to the row under the pointer.
enum TreeDropPlacement {
  /// Before the row, as its sibling.
  before,

  /// Into the row, as its last child.
  inside,

  /// After the row, as its sibling — or as the first child of an expanded row
  /// that has children.
  after,
}

/// The placement for a pointer at [dy] (row-local) over a row of [rowExtent].
///
/// A row that [canHaveChildren] splits into quarters: the top quarter is
/// before, the bottom quarter after, the middle half inside. Any other row
/// splits into halves: before and after.
TreeDropPlacement treeDropPlacement({required double dy, required double rowExtent, required bool canHaveChildren}) {
  if (!canHaveChildren) {
    return dy < rowExtent / 2 ? TreeDropPlacement.before : TreeDropPlacement.after;
  }
  if (dy < rowExtent / 4) {
    return TreeDropPlacement.before;
  }
  return dy >= rowExtent * 3 / 4 ? TreeDropPlacement.after : TreeDropPlacement.inside;
}

/// Where dropped nodes go in a tree.
@immutable
class TreeInsertionPoint<T> {
  const TreeInsertionPoint({required this.parent, required this.index, required this.depth});

  /// The node that receives the new nodes as children; `null` for the top
  /// level.
  final TreeSliverNode<T>? parent;

  /// The position the first new node takes among [parent]'s children, or
  /// among the top-level nodes.
  final int index;

  /// The depth of the new nodes, 0 at the top level; also the indent of a
  /// drop indicator line.
  final int depth;

  @override
  bool operator ==(Object other) =>
      other is TreeInsertionPoint<T> && identical(other.parent, parent) && other.index == index && other.depth == depth;

  @override
  int get hashCode => Object.hash(parent, index, depth);

  @override
  String toString() => 'TreeInsertionPoint(parent: ${parent?.content}, index: $index, depth: $depth)';
}

/// Where nodes dropped with [placement] relative to [target] go.
///
/// [target] must be a node of [roots]. Its parent and depth are found by
/// walking [roots] instead of reading `TreeSliverNode.parent` and `depth`,
/// which only a mounted `TreeSliver` fills in.
TreeInsertionPoint<T> treeInsertionPoint<T>(
  List<TreeSliverNode<T>> roots,
  TreeSliverNode<T> target,
  TreeDropPlacement placement,
) {
  final _Location<T>? location = _locate(roots, target, null, 0);
  if (location == null) {
    throw ArgumentError.value(target, 'target', 'is not a node of roots');
  }
  return switch (placement) {
    TreeDropPlacement.before => TreeInsertionPoint(
      parent: location.parent,
      index: location.index,
      depth: location.depth,
    ),
    TreeDropPlacement.after when target.isExpanded && target.children.isNotEmpty => TreeInsertionPoint(
      parent: target,
      index: 0,
      depth: location.depth + 1,
    ),
    TreeDropPlacement.after => TreeInsertionPoint(
      parent: location.parent,
      index: location.index + 1,
      depth: location.depth,
    ),
    TreeDropPlacement.inside => TreeInsertionPoint(
      parent: target,
      index: target.children.length,
      depth: location.depth + 1,
    ),
  };
}

/// The end of the top level of [roots].
TreeInsertionPoint<T> treeAppendPoint<T>(List<TreeSliverNode<T>> roots) =>
    TreeInsertionPoint(parent: null, index: roots.length, depth: 0);

/// Inserts [nodes] at [point], keeping their order.
void insertTreeNodes<T>(List<TreeSliverNode<T>> roots, TreeInsertionPoint<T> point, List<TreeSliverNode<T>> nodes) =>
    (point.parent?.children ?? roots).insertAll(point.index, nodes);

typedef _Location<T> = ({TreeSliverNode<T>? parent, int index, int depth});

_Location<T>? _locate<T>(
  List<TreeSliverNode<T>> nodes,
  TreeSliverNode<T> target,
  TreeSliverNode<T>? parent,
  int depth,
) {
  for (final (int index, TreeSliverNode<T> node) in nodes.indexed) {
    if (identical(node, target)) {
      return (parent: parent, index: index, depth: depth);
    }
    if (_locate(node.children, target, node, depth + 1) case final _Location<T> found) {
      return found;
    }
  }
  return null;
}
