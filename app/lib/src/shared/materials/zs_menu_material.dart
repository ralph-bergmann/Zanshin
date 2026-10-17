// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import 'zs_surface.dart';

/// The one menu material, for everything that floats for a moment (DS readme.md:90, :284; tokens/effects.css:17,
/// :27): `--fl-sheen` over `--fl-bg-solid`, a 1 px `--fl-border`, `--shadow-menu`, radius `--radius-popover`, no
/// blur, painted by [ZsSurface].
///
/// Its users: the context, project, drop, search and text menus (DS components/menus/menus.css:6, :40), the popover
/// (components/surfaces/surfaces.css:9), the callout (:16), the select and suggestion lists, the peek, the stack
/// list and the gap legend. Their contents, rows and placement are theirs; the entrance and exit are
/// `ZsSurfaceTransition`'s.
class ZsMenuMaterial extends StatelessWidget {
  /// Paints [child] on the menu material.
  const ZsMenuMaterial({required this.child, this.padding = EdgeInsets.zero, this.arrow = false, super.key});

  /// The space between the border and the child (the menu's 5 px, the popover's 6 8 10; DS
  /// components/menus/menus.css:6; components/surfaces/surfaces.css:9).
  final EdgeInsetsGeometry padding;

  /// Whether to paint the callout's 10 px arrow on the left edge, its tip 22 px from the top, in `--fl-bg-solid`
  /// with `--fl-border` on its two outer edges (DS components/surfaces/surfaces.css:17-18). It is painted outside the
  /// box and takes no pointer (Claude's proposal); flipping it to another side is 11.3's.
  final bool arrow;

  /// The material's content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return ZsSurface(
      fill: colors.flBgSolid,
      sheen: colors.flSheen,
      border: colors.flBorder,
      shadow: ZsElevation.of(context).shadowMenu,
      radius: ZsMetrics.of(context).radiusPopover,
      padding: padding,
      arrow: arrow,
      child: child,
    );
  }
}
