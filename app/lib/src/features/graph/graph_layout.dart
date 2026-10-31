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

// revset.pest:24-29 @ v0.46.0: `identifier_part ~ (("." | "-"+ | "+") ~ identifier_part)*`.
final _identifier = RegExp(r'^[\p{XID_Continue}_*/]+(?:(?:\.|-+|\+)[\p{XID_Continue}_*/]+)*$', unicode: true);

/// [name] as jj prints a revset symbol (`format_symbol`, revset_parser.rs:676-710 @ v0.46.0): plain when it is a
/// revset `identifier`, otherwise quoted by [_formatString].
String jjRevsetSymbol(String name) => _identifier.hasMatch(name) ? name : _formatString(name);

// core/src/ref_name.rs `is_safe_identifier` @ v0.46.0: split on `.`, `-`, `+`; every part non-empty ASCII
// alphanumerics, `_` and `/`.
final _safeRefPart = RegExp(r'^[A-Za-z0-9_/]+$');

/// [name] as jj prints a ref or workspace name (`RefName::as_symbol()`'s Display, core/src/ref_name.rs @ v0.46.0):
/// plain when `is_safe_identifier` holds, otherwise quoted by [_formatString].
String jjRefSymbol(String name) =>
    name.split(RegExp('[.+-]')).every(_safeRefPart.hasMatch) ? name : _formatString(name);

/// jj's `format_string` (core/src/symbol_util.rs @ v0.46.0): double-quoted, with `\"` `\\` `\t` `\r` `\n` `\0` and
/// `\xHH` for the other ASCII controls.
String _formatString(String text) {
  final out = StringBuffer('"');
  for (final int c in text.runes) {
    switch (c) {
      case 0x22:
        out.write(r'\"');
      case 0x5C:
        out.write(r'\\');
      case 0x09:
        out.write(r'\t');
      case 0x0D:
        out.write(r'\r');
      case 0x0A:
        out.write(r'\n');
      case 0x00:
        out.write(r'\0');
      case < 0x20 || 0x7F:
        out.write('\\x${c.toRadixString(16).padLeft(2, '0')}');
      default:
        out.writeCharCode(c);
    }
  }
  return (out..write('"')).toString();
}

/// A bookmark ref on a commit, a view fact (Story 10.3): jj's `CommitRef` (commit_templater.rs @ v0.46.0).
@immutable
class GraphRef {
  /// A ref [name], on [remote] when it is a remote-tracking ref.
  const GraphRef(this.name, {this.remote, this.synced = true, this.conflicted = false});

  /// The bookmark's name.
  final String name;

  /// The remote, or null for a local ref.
  final String? remote;

  /// Whether a local ref is in sync with its tracked remotes.
  final bool synced;

  /// Whether the ref's target is conflicted.
  final bool conflicted;

  /// The ref as jj prints it: `name[@remote]`, each a revset symbol (`RefSymbolBuf`'s Display is `format_symbol`,
  /// commit_templater.rs:1815-1831, :2132-2136 @ v0.46.0), then `??` when conflicted, else `*` for an unsynced local
  /// ref (`impl Template for Rc<CommitRef>`).
  String get display {
    final String? remote = this.remote;
    final sigil = conflicted
        ? '??'
        : remote == null && !synced
        ? '*'
        : '';
    return '${jjRevsetSymbol(name)}${remote == null ? '' : '@${jjRevsetSymbol(remote)}'}$sigil';
  }

  @override
  bool operator ==(Object other) =>
      other is GraphRef &&
      other.name == name &&
      other.remote == remote &&
      other.synced == synced &&
      other.conflicted == conflicted;

  @override
  int get hashCode => Object.hash(name, remote, synced, conflicted);

  @override
  String toString() => 'GraphRef($display)';
}

/// A commit's content (Story 10.3), loaded lazily (10.11): null until it is.
@immutable
class GraphCommitContent {
  /// The content of one commit.
  const GraphCommitContent({
    required this.subject,
    this.authorName = '',
    this.authorEmail = '',
    this.empty = false,
    this.conflict = false,
    this.timestampMs,
  });

  /// The description's first line, `''` when the description is empty (jj's `description.first_line()`).
  final String subject;

  /// The author's name.
  final String authorName;

  /// The author's email.
  final String authorEmail;

  /// Whether the change is empty (jj's `empty()`).
  final bool empty;

  /// Whether the commit has a conflict (jj's `conflict()`).
  final bool conflict;

  /// The committer timestamp in epoch ms, when the content carries one: the card's date when the layout has none
  /// (Story 10.11).
  final int? timestampMs;
}

/// One computed layout of a revset (Story 10.1 item 2), read only through accessors so the backing store can be
/// swapped (10.12). Consumers add accessors, never backing objects.
///
/// Rows are in units of 1/[unit] pitch, row 0 is the oldest (at the bottom). A node's key is its change id, or its
/// commit id when the commit is hidden or divergent; the one synthetic key is a stack node's, [graphStackKey] of its
/// run's oldest member (never a jj id). Edges are ordered by child, then by the parent's position, so [parentEdges] is
/// a contiguous range.
///
/// **Stacks (Story 10.17, docs/graph-layout.md §4.8):** a grouped layout has [runCount] linear runs; a collapsed run's
/// members are [isFolded] (they stay in the node index, with `rowOf` and `colOf` −1, and are never laid out) and its
/// [stackNodeOf] node stands in for them. [shownCount] excludes the stack nodes, so folded members count as shown.
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

  /// The full change id of [node] (jj's `change_id()`, in jj's reverse-hex letters).
  String changeIdOf(int node);

  /// The full commit id of [node] (jj's `commit_id()`): the key content is cached and loaded by (Story 10.11).
  String commitIdOf(int node);

  /// The length of [node]'s shortest unique change-id prefix (jj's `shortest()`, commit_templater.rs:2295-2302 @
  /// v0.46.0, which honours `revsets.short-prefixes`).
  int changeIdPrefixLengthOf(int node);

  /// jj's `change_offset()` of [node]; non-null only when it is hidden or divergent (templates.toml
  /// `format_change_offset` @ v0.46.0).
  int? changeOffsetOf(int node);

  /// Whether [node] is in `immutable()` (the root included).
  bool isImmutable(int node);

  /// Whether [node] is hidden (jj's `hidden()`).
  bool isHidden(int node);

  /// Whether [node] is divergent (jj's `divergent()`).
  bool isDivergent(int node);

  /// The bookmarks on [node], in jj's order (`bookmarks()`).
  List<GraphRef> refsOf(int node);

  /// The workspace names whose working copy is [node] (jj's `working_copies()`): empty with at most one workspace
  /// (commit_templater.rs:1491-1503 @ v0.46.0).
  List<String> workingCopiesOf(int node);

  /// This workspace's name, when the source carries it.
  String? get workspaceName;

  /// [node]'s content, null until it is loaded.
  GraphCommitContent? contentOf(int node);

  /// Identifies this layout: two layouts with one version are the same layout (the delegate's `shouldRebuild`), so a
  /// version must be unique across every [GraphLayout] implementation, not only within one.
  int get version;

  /// The number of linear runs (Story 10.17); 0 in an ungrouped layout.
  int get runCount => 0;

  /// [run]'s members as node indices, oldest first (the engine's order).
  List<int> runMembersOf(int run) => throw RangeError.range(run, 0, runCount - 1, 'run');

  /// [run]'s stack node, or null while it is expanded.
  int? stackNodeOf(int run) => null;

  /// The run [node] is a member or the stack node of, or null.
  int? runOf(int node) => null;

  /// Whether [node] is a stack node.
  bool isStackNode(int node) {
    final int? run = runOf(node);
    return run != null && stackNodeOf(run) == node;
  }

  /// Whether [node] is a member of a collapsed run: it has no position and is never laid out.
  bool isFolded(int node) {
    final int? run = runOf(node);
    final int? stack = run == null ? null : stackNodeOf(run);
    return stack != null && stack != node;
  }

  /// Where [key] is shown: its node, or a folded member's stack node; null when the key is absent.
  int? placeOfKey(String key) {
    final int? node = indexOfKey(key);
    if (node == null || !isFolded(node)) {
      return node;
    }
    return stackNodeOf(runOf(node)!);
  }
}

/// A stack node's key (Story 10.17): `stack:` and its run's oldest member key, never a jj id.
String graphStackKey(String oldestMemberKey) => 'stack:$oldestMemberKey';

/// The member of [run] a stack toggle keeps in place (Story 10.17): the oldest in compact (where the stack sits at its
/// oldest member's row), the newest in free (where it keeps its newest member's time).
String graphStackAnchorKey(GraphLayout layout, int run) {
  final List<int> members = layout.runMembersOf(run);
  return layout.keyOf(layout.mode == GraphMode.compact ? members.first : members.last);
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
