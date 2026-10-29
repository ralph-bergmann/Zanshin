// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../design/zs_colors.dart';
import '../design/zs_elevation.dart';
import '../design/zs_metrics.dart';
import '../design/zs_motion.dart';
import '../design/zs_type.dart';
import '../icons/zanshin_icon.dart';
import '../materials/zs_surface.dart';
import 'zs_control_text.dart';

/// What a [ZsDragGhost] carries (DS components/overlays/DragGhost.prompt.md:12). Story 10.10 adds the graph's kinds.
enum ZsDragGhostKind {
  /// A project of the Projects tree: its status dot, then its name.
  project,

  /// A group of the Projects tree: the folder glyph, then its name.
  group,
}

/// The chip that follows the pointer while a row is dragged (Story 11.15 item 8; DS
/// components/overlays/DragGhost.{prompt.md,jsx}; overlays.css:41-60).
///
/// **The chip** (`.zs-ghost-card`, overlays.css:44): 34 high, padding 0 12, gap 8, at most 280 wide, radius
/// `--radius-card`, `--card-solid-hi` with a 1 px `--accent-line` border and `--shadow-drag` (which holds the 3 px
/// `--accent-ring`), the [label] in `--fs-control` 500 `--text`, ellipsized; tilted −1.5° × `--motion`, so it is
/// upright under Reduce motion. A [ZsDragGhostKind.project] leads with its 7 px status [dot] (none when null), a
/// [ZsDragGhostKind.group] with the md folder in `--text-dim`.
///
/// **The words** (`.zs-ghost-cmd.is-words`, overlays.css:57-59): 8 below the chip, at most 340 wide, padding 7 10,
/// radius `--radius-chip`, `--tooltip-bg` with `--shadow-tooltip`, `--fs-sm` sans. The [target] ("Into Backend", "To
/// the top level") has an `--accent-line` border and `--text`; without one the [hint] has a `--tooltip-border` border
/// and `--text-dim`. Neither: no words.
///
/// It is hidden from VoiceOver and takes no pointer (`.zs-ghost{pointer-events:none}`, overlays.css:42).
class ZsDragGhost extends StatelessWidget {
  /// The ghost of a [kind] row named [label].
  const ZsDragGhost({required this.kind, required this.label, this.dot, this.target, this.hint, super.key});

  /// What is dragged.
  final ZsDragGhostKind kind;

  /// The dragged row's name.
  final String label;

  /// A project's status colour; null shows no dot. Groups show none.
  final Color? dot;

  /// Where a drop lands, in words; it wins over [hint].
  final String? target;

  /// What to do while nothing valid is under the pointer.
  final String? hint;

  /// The chip's height (overlays.css:44).
  static const double height = 34;

  /// The chip's widest (overlays.css:44).
  static const double maxWidth = 280;

  /// The words' widest (overlays.css:57).
  static const double wordsMaxWidth = 340;

  /// The tilt at full motion: −1.5° (`rotate:-1.5deg`, overlays.css:44).
  static const double tilt = -1.5 * math.pi / 180;

  /// The dot's side (`.zs-proj-dot{width:7px}`, DS components/content/content.css:88).
  static const double _dot = 7;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsElevation elevation = ZsElevation.of(context);
    final Color? dot = this.dot;
    final String? words = target ?? hint;
    final Widget chip = Transform.rotate(
      angle: tilt * ZsMotion.of(context).motion,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(
          height: height,
          child: ZsSurface(
            fill: colors.cardSolidHi,
            border: colors.accentLine,
            shadow: elevation.shadowDrag,
            radius: metrics.radiusCard,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 8,
              children: <Widget>[
                if (kind == ZsDragGhostKind.group)
                  ZanshinIcon(ZI.folder, size: ZsIconSize.md, color: colors.textDim)
                else if (dot != null)
                  SizedBox.square(
                    dimension: _dot,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
                  ),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.ellipsis,
                    style: zsSans(ZsType.fsControl, weight: FontWeight.w500, height: 1.2).copyWith(color: colors.text),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 8,
          children: <Widget>[
            chip,
            if (words != null)
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: wordsMaxWidth),
                child: ZsSurface(
                  fill: colors.tooltipBg,
                  border: target != null ? colors.accentLine : colors.tooltipBorder,
                  shadow: elevation.shadowTooltip,
                  radius: metrics.radiusChip,
                  padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
                  child: Text(
                    words,
                    style: zsSans(
                      ZsType.fsSm,
                      height: 1.2,
                    ).copyWith(color: target != null ? colors.text : colors.textDim),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
