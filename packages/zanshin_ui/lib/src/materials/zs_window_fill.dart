// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_values.dart';
import 'zs_surface.dart';

/// The opaque surface of a window of its own — Settings, Projects, jj log Configurations (DS readme.md:90, :189;
/// components/window/window.css:20-26): `--fl-sheen` over `--fl-bg-solid`, full-bleed, painted by [ZsSurface].
///
/// No border, radius, shadow, scrim, entrance or vibrancy: the system draws the window's corners, its shadow and its
/// appearing. Reduce transparency changes nothing; increased contrast takes the solid values the fill already has.
/// The header's hairline is 11.12's.
class ZsWindowFill extends StatelessWidget {
  /// Fills the window behind [child].
  const ZsWindowFill({required this.child, super.key});

  static const _noShadow = ZsShadowStack(<ZsShadow>[]);

  /// The window's content.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return ZsSurface(fill: colors.flBgSolid, sheen: colors.flSheen, shadow: _noShadow, radius: 0, child: child);
  }
}
