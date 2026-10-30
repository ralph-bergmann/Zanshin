// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';

/// How a layout spaces its rows (docs/graph-layout.md §4.2): `free` follows compressed commit time (U = 16, the
/// default), `compact` the dependency depth (U = 1).
enum GraphMode {
  /// Rows in 1/16 pitch units, from commit time.
  free,

  /// One row per pitch, from dependency depth.
  compact,
}

/// The lane order (docs/graph-layout.md §4.6): a request knob, not a user control.
enum GraphLaneOrder {
  /// The bounded crossing heuristic, the default.
  compact,

  /// Lanes as assigned.
  greedy,
}

/// jj's edge kinds that the layout keeps; Missing parents are not layout edges ([GraphLayout.elidedOf]).
enum GraphEdgeKind {
  /// The parent is the commit's real parent.
  direct,

  /// The parent is an ancestor reached through commits outside the revset.
  indirect,
}

/// An edge's route class (docs/graph-layout.md §3 `route`).
enum GraphEdgeShape {
  /// Parent and child share the lane.
  straight,

  /// The child joins a second (or later) parent's lane.
  merge,

  /// The child leaves its parent's lane.
  branchOff,
}

/// A time bucket's kind; the decided modes emit day buckets only (`free`).
enum GraphBucketKind {
  /// A calendar day; its value is the local-midnight instant in epoch ms.
  day,
}

/// One computed layout of a revset (Story 10.1 item 2), read only through accessors so the backing store can be
/// swapped (10.12). Consumers add accessors, never backing objects.
///
/// Rows are in units of 1/[unit] pitch, row 0 is the oldest (at the bottom). A node's key is its change id, or its
/// commit id when the commit is hidden or divergent; there are no synthetic keys. Edges are ordered by child, then by
/// the parent's position, so [parentEdges] is a contiguous range.
abstract class GraphLayout {
  /// Abstract constructor for implementers.
  const GraphLayout();

  /// The layout mode.
  GraphMode get mode;

  /// U: rows are in units of 1/U pitch.
  int get unit;

  /// Max row + U; 0 when empty.
  int get rows;

  /// The number of columns; 0 when empty.
  int get colCount;

  /// The number of nodes.
  int get nodeCount;

  /// The key of [node].
  String keyOf(int node);

  /// The node carrying [key], or null.
  int? indexOfKey(String key);

  /// The column of [node].
  int colOf(int node);

  /// The row of [node], in 1/U pitch units.
  int rowOf(int node);

  /// The committer timestamp of [node] in epoch ms, when the source carries one.
  int? timestampOf(int node);

  /// The commit's real parent count, Missing parents included (not the edge count).
  int parentCountOf(int node);

  /// Whether [node] has a Missing parent (an elided stub).
  bool elidedOf(int node);

  /// The number of layout edges.
  int get edgeCount;

  /// The child node of [edge].
  int childOf(int edge);

  /// The parent node of [edge].
  int parentOf(int edge);

  /// The kind of [edge].
  GraphEdgeKind kindOf(int edge);

  /// The route class of [edge].
  GraphEdgeShape shapeOf(int edge);

  /// The edges whose child is [node]: edge indices `start` until `end`.
  ({int start, int end}) parentEdges(int node);

  /// The edges whose parent is [node]: slots `start` until `end` for [childEdgeAt].
  ({int start, int end}) childEdges(int node);

  /// The edge at [slot] of a [childEdges] range.
  int childEdgeAt(int slot);

  /// The number of time buckets.
  int get bucketCount;

  /// The kind of [bucket].
  GraphBucketKind bucketKindOf(int bucket);

  /// The value of [bucket] (for a day, its local-midnight instant in epoch ms).
  int bucketValueOf(int bucket);

  /// The first row of [bucket], in 1/U pitch units.
  int bucketFirstRowOf(int bucket);

  /// The last row of [bucket], in 1/U pitch units.
  int bucketLastRowOf(int bucket);

  /// The fixed UTC offset, in minutes, the day buckets were cut at.
  int get utcOffsetMinutes;

  /// The `root()` commit, when it is in the layout.
  int? get rootIndex;

  /// This workspace's `@`, when it is in the layout.
  int? get workingCopyIndex;

  /// The number of commits shown.
  int get shownCount;

  /// `|all()|`, when the source provides it.
  int? get totalCount;

  /// The operation the layout was computed at, when the source carries it.
  String? get operationId;

  /// Identifies this layout: two layouts with one version are the same layout (the delegate's `shouldRebuild`), so a
  /// version must be unique across every [GraphLayout] implementation, not only within one.
  int get version;
}

/// The view's options (Story 10.1 item 2); every field is a knob of the catalogue's Graph folder.
@immutable
class GraphViewOptions {
  /// Creates options; the defaults are the design's.
  const GraphViewOptions({
    this.layout = GraphMode.free,
    this.laneOrder = GraphLaneOrder.compact,
    this.detailedCards = true,
    this.cardWidth = 240,
  });

  /// The layout mode.
  final GraphMode layout;

  /// The lane order.
  final GraphLaneOrder laneOrder;

  /// Detailed (62 px) or compact (40 px) cards.
  final bool detailedCards;

  /// The card width, 160–400 (`GraphMetrics` clamps it).
  final double cardWidth;

  /// These options with the given fields replaced.
  GraphViewOptions copyWith({GraphMode? layout, GraphLaneOrder? laneOrder, bool? detailedCards, double? cardWidth}) =>
      GraphViewOptions(
        layout: layout ?? this.layout,
        laneOrder: laneOrder ?? this.laneOrder,
        detailedCards: detailedCards ?? this.detailedCards,
        cardWidth: cardWidth ?? this.cardWidth,
      );

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphViewOptions &&
          other.layout == layout &&
          other.laneOrder == laneOrder &&
          other.detailedCards == detailedCards &&
          other.cardWidth == cardWidth;

  @override
  int get hashCode => Object.hash(layout, laneOrder, detailedCards, cardWidth);
}
