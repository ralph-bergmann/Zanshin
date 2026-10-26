// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

/// Story 10.1's stand-in for a commit card (10.3 builds the real one): a token-coloured box with the node's key, the
/// working copy edged in gold.
class GraphPlaceholderCard extends StatelessWidget {
  /// The placeholder of [node] in [layout].
  const GraphPlaceholderCard({required this.layout, required this.node, super.key});

  /// The layout [node] belongs to.
  final GraphLayout layout;

  /// The node shown.
  final int node;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.cardSolid,
        border: Border.all(color: node == layout.workingCopyIndex ? colors.gold : colors.borderStrong),
        borderRadius: BorderRadius.circular(metrics.radiusCard),
      ),
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: metrics.cardPadX),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            layout.keyOf(node),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: ZsType.cardSubject.copyWith(color: colors.text),
          ),
        ),
      ),
    );
  }
}
