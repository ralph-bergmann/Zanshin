// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'graph_insets.dart';

/// The width model of the project window (decisions 16.22, 16.23; epics.md Story 11.3 item 11, :12044-12056): from
/// the window width and the remembered widths, the effective widths of the pinned panel and the inspector, whether
/// the pinned panel collapses, the [GraphInsets] and the limits of the two resize edges.
///
/// **Remembered and effective.** The user's remembered widths (clamped to their token ranges, inspector 380–720,
/// panel 240–440) are what the user dragged; the effective widths are what the window allows. A narrow window never
/// changes the remembered ones.
///
/// **The collapse rule.** With r the right side (the effective inspector + 24 while the inspector is open, else the
/// minimap column 158 while a minimap shows, else 12) and need(p, r) = 88 + p + r + 320 the window width a panel p
/// needs beside it: when the remembered widths do not fit, the inspector shrinks first, down to 380, then the panel,
/// down to 240; when even those do not fit, the pinned panel collapses — its pin stays, the left inset falls back to
/// 76 — and it returns at its remembered width once need(remembered panel, 404 or the right side) fits. The inspector
/// then grows back toward its remembered width (decision 16.42 (a)). Unpinning clears the collapse.
///
/// With 300 / 460, pinned, the inspector open: 1192 both fit; down to 1112 the inspector shrinks to 380; down to 1052
/// the panel shrinks to 240; below 1052 the panel collapses; widening, it returns at 1112.
///
/// **Limits.** A drag stops where 320 px of graph would remain: the panel at max(240, min(440, W − 88 − r − 320)),
/// the inspector at max(380, min(720, W − left inset − 24 − 320)) (DS components/surfaces/ResizeEdge.prompt.md:5;
/// the panel's limit is Claude's proposal, r5out resize).
@immutable
class ShellLayout {
  /// A resolved layout; [ShellLayout.resolve] computes one.
  const ShellLayout({
    required this.panelWidth,
    required this.inspectorWidth,
    required this.collapsed,
    required this.insets,
    required this.panelMax,
    required this.inspectorMax,
  });

  /// The layout of a [windowWidth] wide window in [metrics] (`fullScreen` moves the top inset).
  ///
  /// [pinned] whether a panel is pinned, [inspectorOpen] whether the inspector shows, [minimapShown] whether the
  /// minimap slot holds a minimap, [rememberedPanel] and [rememberedInspector] the user's widths (clamped here),
  /// [wasCollapsed] the previous layout's [collapsed].
  factory ShellLayout.resolve({
    required double windowWidth,
    required ZsMetrics metrics,
    required bool pinned,
    required bool inspectorOpen,
    required bool minimapShown,
    required double rememberedPanel,
    required double rememberedInspector,
    required bool wasCollapsed,
  }) {
    final w = windowWidth;
    final double rp = rememberedPanel.clamp(metrics.panelWMin, metrics.panelWMax);
    final double ri = rememberedInspector.clamp(metrics.inspectorWMin, metrics.inspectorWMax);
    // The rail column and its gap: 76 + 12 (DS tokens/spacing.css:32, :40).
    final double railSide = metrics.chromeLeft + metrics.chromeInset;
    final double graph = metrics.graphMinW;
    final double withoutInspector = minimapShown ? _minimapColumn : metrics.chromeInset;
    double rightSide(double inspector) => inspectorOpen ? inspector + _inspectorGap : withoutInspector;
    double need(double panel, double right) => railSide + panel + right + graph;
    // The inspector without a pinned panel beside it: everything left of it but the rail and 320 of graph.
    final double alone = math.min(ri, math.max(metrics.inspectorWMin, w - metrics.chromeLeft - _inspectorGap - graph));

    var collapsed = false;
    var panel = rp;
    var inspector = alone;
    if (pinned) {
      final double minRight = inspectorOpen ? metrics.inspectorWMin + _inspectorGap : withoutInspector;
      collapsed = wasCollapsed ? need(rp, minRight) > w : need(metrics.panelWMin, minRight) > w;
      if (!collapsed) {
        if (!inspectorOpen) {
          panel = math.min(rp, w - railSide - withoutInspector - graph);
          inspector = ri;
        } else if (need(rp, ri + _inspectorGap) <= w) {
          inspector = ri;
        } else {
          final double shrunk = w - railSide - rp - _inspectorGap - graph;
          if (shrunk >= metrics.inspectorWMin) {
            inspector = shrunk;
          } else {
            inspector = metrics.inspectorWMin;
            panel = w - railSide - metrics.inspectorWMin - _inspectorGap - graph;
          }
        }
      }
    }
    final bool showsPanel = pinned && !collapsed;
    final double left = showsPanel ? railSide + panel : metrics.chromeLeft;
    final double right = rightSide(inspector);
    return ShellLayout(
      panelWidth: panel,
      inspectorWidth: inspector,
      collapsed: collapsed,
      insets: GraphInsets(
        top: metrics.chromeTop,
        left: left,
        right: right,
        bottom: metrics.chromeInset,
        inspectorWidth: inspectorOpen ? inspector : 0,
        minimapWidth: minimapShown ? metrics.minimapW : 0,
      ),
      panelMax: math.max(metrics.panelWMin, math.min(metrics.panelWMax, w - railSide - right - graph)),
      inspectorMax: math.max(
        metrics.inspectorWMin,
        math.min(metrics.inspectorWMax, w - left - _inspectorGap - graph),
      ),
    );
  }

  /// The inspector's right inset beyond its width: 12 to the window edge and the 12 gap (DS
  /// ui_kits/desktop/app.jsx:168, `insW + EDGE * 2`).
  static const double _inspectorGap = 24;

  /// The minimap's column: the minimap and its two 12 px gaps (DS ui_kits/desktop/app.jsx:6, :168, `MINI + EDGE`).
  static const double _minimapColumn = 158;

  /// The pinned panel's effective width (its remembered width, clamped, while it is not pinned).
  final double panelWidth;

  /// The inspector's effective width.
  final double inspectorWidth;

  /// Whether a pinned panel has no room and collapsed, keeping its pin.
  final bool collapsed;

  /// What the chrome covers.
  final GraphInsets insets;

  /// The panel edge's drag limit.
  final double panelMax;

  /// The inspector edge's drag limit.
  final double inspectorMax;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ShellLayout &&
          other.panelWidth == panelWidth &&
          other.inspectorWidth == inspectorWidth &&
          other.collapsed == collapsed &&
          other.insets == insets &&
          other.panelMax == panelMax &&
          other.inspectorMax == inspectorMax;

  @override
  int get hashCode => Object.hash(panelWidth, inspectorWidth, collapsed, insets, panelMax, inspectorMax);

  @override
  String toString() =>
      'ShellLayout(panel: $panelWidth, inspector: $inspectorWidth, collapsed: $collapsed, $insets, panelMax: '
      '$panelMax, inspectorMax: $inspectorMax)';
}
