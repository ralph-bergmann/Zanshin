// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';

/// Secondary text on a fill steps up a rung, so it keeps 4.5:1 on the fill (DS components/base.css:45-50;
/// readme.md:132, :141; decision 16.41): on hover the faint step reads as dim; on, pressed, selected and highlighted,
/// dim and faint read as muted. Every count, hash, path and shortcut inside the control takes [dim] and [faint]
/// from here instead of `--text-dim` and `--text-faint`.
///
/// A helper, not a token: it adds no name to the DS parity's `toCss`.
@immutable
class ZsTextRung {
  const ZsTextRung._({required this.dim, required this.faint});

  /// The rung for a control in [colors] that is [hovered] or [raised] (pressed, on, selected or highlighted; it wins
  /// over hover).
  factory ZsTextRung.of(ZsColors colors, {bool hovered = false, bool raised = false}) {
    if (raised) {
      return ZsTextRung._(dim: colors.textMuted, faint: colors.textMuted);
    }
    if (hovered) {
      return ZsTextRung._(dim: colors.textDim, faint: colors.textDim);
    }
    return ZsTextRung._(dim: colors.textDim, faint: colors.textFaint);
  }

  /// What the control's `--text-dim` reads as.
  final Color dim;

  /// What the control's `--text-faint` reads as.
  final Color faint;
}
