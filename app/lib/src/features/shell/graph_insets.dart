// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// The margins of the project window that the floating chrome covers (epics.md Story 11.3 item 7; Story 10.5
/// items 14, :8943-8948): the graph takes them from `ShellScope.insetsOf` and keeps its cards clear of them.
///
/// `ShellLayout` computes them:
/// - [top] `--chrome-top` (60, 68 in full screen);
/// - [left] `--chrome-left` (76), or 76 + the pinned panel's effective width + 12 while a panel is pinned and not
///   collapsed;
/// - [right] the inspector's effective width + 24 while the inspector is open, else the minimap column 158 while a
///   minimap shows, else 12;
/// - [bottom] 12;
/// - [inspectorWidth] the inspector's effective width, [minimapWidth] `--minimap-w` (134) while a minimap shows,
///   else 0.
///
/// Calm scrolling never changes them; a flyout changes none of them.
@immutable
class GraphInsets {
  /// Creates insets.
  const GraphInsets({
    required this.top,
    required this.left,
    required this.right,
    required this.bottom,
    required this.inspectorWidth,
    required this.minimapWidth,
  });

  /// The covered band along the top: the bar's row.
  final double top;

  /// The covered band on the left: the rail, and a pinned panel.
  final double left;

  /// The covered band on the right: the inspector or the minimap.
  final double right;

  /// The covered band along the bottom.
  final double bottom;

  /// The inspector's effective width.
  final double inspectorWidth;

  /// The minimap's width, 0 without one.
  final double minimapWidth;

  /// The part of a [viewport]-sized window the chrome leaves free: the visible rect (Story 10.5 item 14).
  Rect visibleRect(Size viewport) => Rect.fromLTRB(left, top, viewport.width - right, viewport.height - bottom);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphInsets &&
          other.top == top &&
          other.left == left &&
          other.right == right &&
          other.bottom == bottom &&
          other.inspectorWidth == inspectorWidth &&
          other.minimapWidth == minimapWidth;

  @override
  int get hashCode => Object.hash(top, left, right, bottom, inspectorWidth, minimapWidth);

  @override
  String toString() =>
      'GraphInsets(top: $top, left: $left, right: $right, bottom: $bottom, inspectorWidth: $inspectorWidth, '
      'minimapWidth: $minimapWidth)';
}
