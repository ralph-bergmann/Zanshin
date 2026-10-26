// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'graph_layout.dart';

/// The graph's pixels in x and the card size (Story 10.1 item 3; DS tokens/spacing.css:18-19, effects.css:10).
///
/// x(col) = pad + col·(W + gapX) in plane coordinates (no gutter: offX is 0 in both modes); the viewport adds the
/// live insets. W and H never change rows or columns, so a change is a remap, never a layout request.
@immutable
class GraphMetrics {
  /// Metrics for [cardWidth] (clamped to [minCardWidth]–[maxCardWidth]) and [detailedCards], the rest from [tokens].
  factory GraphMetrics({double cardWidth = 240, bool detailedCards = true, ZsMetrics tokens = ZsMetrics.standard}) =>
      GraphMetrics._(
        cardWidth: cardWidth.clamp(minCardWidth, maxCardWidth),
        cardHeight: detailedCards ? tokens.cardHDetailed : tokens.cardHCompact,
        gapX: tokens.graphGapX,
        gapY: tokens.graphGapY,
        pad: tokens.graphPad,
        radius: tokens.radiusCard,
      );

  /// The metrics [options] ask for.
  factory GraphMetrics.fromOptions(GraphViewOptions options, {ZsMetrics tokens = ZsMetrics.standard}) =>
      GraphMetrics(cardWidth: options.cardWidth, detailedCards: options.detailedCards, tokens: tokens);

  const GraphMetrics._({
    required this.cardWidth,
    required this.cardHeight,
    required this.gapX,
    required this.gapY,
    required this.pad,
    required this.radius,
  });

  /// The narrowest card.
  static const double minCardWidth = 160;

  /// The widest card.
  static const double maxCardWidth = 400;

  /// W.
  final double cardWidth;

  /// H: 62 with detailed cards, 40 without.
  final double cardHeight;

  /// The gap between columns.
  final double gapX;

  /// The gap between rows.
  final double gapY;

  /// The plane's padding on every side.
  final double pad;

  /// The card's corner radius.
  final double radius;

  /// The left edge of column [col] in plane coordinates.
  double x(int col) => pad + col * (cardWidth + gapX);

  /// The plane's width for [colCount] columns; 2·pad when empty.
  double planeWidth(int colCount) => colCount == 0 ? 2 * pad : 2 * pad + colCount * (cardWidth + gapX) - gapX;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphMetrics &&
          other.cardWidth == cardWidth &&
          other.cardHeight == cardHeight &&
          other.gapX == gapX &&
          other.gapY == gapY &&
          other.pad == pad &&
          other.radius == radius;

  @override
  int get hashCode => Object.hash(cardWidth, cardHeight, gapX, gapY, pad, radius);
}
