// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'graph_layout.dart';

/// Builds the card of `node`; it must be stable (no per-build closure), since the delegate compares it.
typedef GraphCardBuilder = Widget Function(BuildContext context, int node);

/// The graph's child delegate (Story 10.1 item 9): a child's vicinity is (col, node index), its identity is its key.
///
/// The key sits on the outermost widget, so the viewport's element reuses a card across vicinities (a reload moves
/// it); `KeepAlive` below it keeps a pinned card when it scrolls out, and flipping the flag updates the element in
/// place. [shouldRebuild] compares the layout's version, the pinned keys and the builder, so a parent rebuild builds
/// no card.
class GraphChildDelegate extends TwoDimensionalChildDelegate {
  /// A delegate over [layout].
  GraphChildDelegate({required this.layout, required this.cardBuilder, this.pinnedKeys = const <String>{}});

  /// The layout whose nodes are the children.
  final GraphLayout layout;

  /// Builds a node's card.
  final GraphCardBuilder cardBuilder;

  /// The keys kept alive while scrolled out (an open popup, a drag).
  final Set<String> pinnedKeys;

  @override
  Widget? build(BuildContext context, ChildVicinity vicinity) {
    final int node = vicinity.yIndex;
    if (node < 0 || node >= layout.nodeCount || layout.colOf(node) != vicinity.xIndex) {
      return null;
    }
    final String key = layout.keyOf(node);
    return KeyedSubtree(
      key: ValueKey<String>(key),
      child: KeepAlive(
        keepAlive: pinnedKeys.contains(key),
        child: RepaintBoundary(child: cardBuilder(context, node)),
      ),
    );
  }

  @override
  bool shouldRebuild(GraphChildDelegate oldDelegate) =>
      layout.version != oldDelegate.layout.version ||
      cardBuilder != oldDelegate.cardBuilder ||
      !setEquals(pinnedKeys, oldDelegate.pinnedKeys);
}
