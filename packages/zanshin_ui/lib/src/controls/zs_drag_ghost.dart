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

  /// A change of the graph (Story 10.10): the `@` badge on the working copy, the id, then the subject.
  change,

  /// A local bookmark (Story 10.10): the bookmark glyph, then its name in mono, on a pill.
  bookmark,
}

/// The chip that follows the pointer while a row is dragged (Story 11.15 item 8; DS
/// components/overlays/DragGhost.{prompt.md,jsx}; overlays.css:41-60).
///
/// **The chip** (`.zs-ghost-card`, overlays.css:44): 34 high, padding 0 12, gap 8, at most 280 wide, radius
/// `--radius-card`, `--card-solid-hi` with a 1 px `--accent-line` border and `--shadow-drag` (which holds the 3 px
/// `--accent-ring`), the [label] in `--fs-control` 500 `--text`, ellipsized; tilted −1.5° × `--motion`, so it is
/// upright under Reduce motion. A [ZsDragGhostKind.project] leads with its 7 px status [dot] (none when null), a
/// [ZsDragGhostKind.group] with the md folder in `--text-dim`. A [ZsDragGhostKind.change] (Story 10.10) leads with the
/// `@` badge when [workingCopy], then [changeId] — its first [prefix] characters bold, max([prefix], 8) shown, one
/// `Text.rich` — then the subject [label]; a [ZsDragGhostKind.bookmark] is the pill (`.is-bm`, overlays.css:48-50): 28
/// high, padding 0 12 0 9, gap 6, the bookmark glyph in `--text-muted`, the name in 600 `--fs-md` mono.
///
/// **The words** (`.zs-ghost-cmd`, overlays.css:57-59): 8 below the chip, at most 340 wide, padding 7 10, radius
/// `--radius-chip`, `--tooltip-bg` with `--shadow-tooltip`. A [command] (the jj command a drop would run) is
/// `--fs-id` mono `--text` with an `--accent-line` border; else the [target] ("Into Backend") the same in `--fs-sm`
/// sans; else the [hint] with a `--tooltip-border` border and `--text-dim`. None (or [hideWords]): no words. A
/// [warning] adds a `--warn` line under them.
///
/// [muted] fades the ghost to .3 on `--dur-hover` (`.zs-ghost.is-muted`, overlays.css:43): the pointer is over the drop
/// menu. It is hidden from VoiceOver and takes no pointer (`.zs-ghost{pointer-events:none}`, overlays.css:42).
class ZsDragGhost extends StatelessWidget {
  /// The ghost of a [kind] row named [label].
  const ZsDragGhost({
    required this.kind,
    required this.label,
    this.dot,
    this.target,
    this.hint,
    this.command,
    this.warning,
    this.changeId,
    this.prefix = 0,
    this.workingCopy = false,
    this.muted = false,
    this.hideWords = false,
    this.chipKey,
    super.key,
  });

  /// A key on the chip alone (not the words): its render box is the chip's rect (Story 10.10's drop origin).
  final Key? chipKey;

  /// What is dragged.
  final ZsDragGhostKind kind;

  /// The dragged row's name: a change's subject, a bookmark's name.
  final String label;

  /// A project's status colour; null shows no dot. Groups show none.
  final Color? dot;

  /// Where a drop lands, in words; it wins over [hint].
  final String? target;

  /// What to do while nothing valid is under the pointer.
  final String? hint;

  /// The jj command a drop would run; it wins over [target] and [hint].
  final String? command;

  /// A line under the words in `--warn` sans `--fs-sm`: what the drop does that the command does not say (a
  /// backwards bookmark move). Hidden with the words.
  final String? warning;

  /// A change's full id ([ZsDragGhostKind.change]).
  final String? changeId;

  /// jj's shortest unique prefix length of [changeId].
  final int prefix;

  /// Whether the change is the working copy: the `@` badge leads.
  final bool workingCopy;

  /// Whether the ghost fades to .3 (the pointer is over the drop menu).
  final bool muted;

  /// Whether the words hide (the drop menu is open).
  final bool hideWords;

  /// The chip's height (overlays.css:44).
  static const double height = 34;

  /// A bookmark pill's height (overlays.css:48).
  static const double bookmarkHeight = 28;

  /// The chip's widest (overlays.css:44).
  static const double maxWidth = 280;

  /// The words' widest (overlays.css:57).
  static const double wordsMaxWidth = 340;

  /// The tilt at full motion: −1.5° (`rotate:-1.5deg`, overlays.css:44).
  static const double tilt = -1.5 * math.pi / 180;

  /// The opacity of a [muted] ghost (overlays.css:43).
  static const mutedOpacity = .3;

  /// The dot's side (`.zs-proj-dot{width:7px}`, DS components/content/content.css:88).
  static const double _dot = 7;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsElevation elevation = ZsElevation.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final Color? dot = this.dot;
    final bookmark = kind == ZsDragGhostKind.bookmark;
    final String? words = hideWords ? null : command ?? target ?? hint;
    final bool on = command != null || target != null;
    final TextStyle labelStyle = bookmark
        ? zsMono(ZsType.fsMd, weight: FontWeight.w600, height: 1.2).copyWith(color: colors.text)
        : zsSans(ZsType.fsControl, weight: FontWeight.w500, height: 1.2).copyWith(color: colors.text);
    final Widget chip = Transform.rotate(
      key: chipKey,
      angle: tilt * motion.motion,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: maxWidth),
        child: SizedBox(
          height: bookmark ? bookmarkHeight : height,
          child: ZsSurface(
            fill: colors.cardSolidHi,
            border: colors.accentLine,
            shadow: elevation.shadowDrag,
            radius: bookmark ? metrics.radiusPill : metrics.radiusCard,
            padding: bookmark ? const EdgeInsets.fromLTRB(9, 0, 12, 0) : const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: bookmark ? 6 : 8,
              children: <Widget>[
                if (kind == ZsDragGhostKind.group)
                  ZanshinIcon(ZI.folder, size: ZsIconSize.md, color: colors.textDim)
                else if (bookmark)
                  ZanshinIcon(ZI.bookmark, size: ZsIconSize.sm, color: colors.textMuted)
                else if (dot != null)
                  SizedBox.square(
                    dimension: _dot,
                    child: DecoratedBox(
                      decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
                    ),
                  ),
                if (kind == ZsDragGhostKind.change && workingCopy) _AtBadge(colors: colors, radius: metrics.radiusXs),
                if (kind == ZsDragGhostKind.change && changeId != null) _id(colors, changeId!),
                Flexible(
                  child: Text(label, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: labelStyle),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return IgnorePointer(
      child: ExcludeSemantics(
        child: AnimatedOpacity(
          opacity: muted ? mutedOpacity : 1,
          duration: motion.durHover,
          curve: motion.easeState,
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
                    border: on ? colors.accentLine : colors.tooltipBorder,
                    shadow: elevation.shadowTooltip,
                    radius: metrics.radiusChip,
                    padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 10),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 4,
                      children: <Widget>[
                        Text(
                          words,
                          style: (command != null ? zsMono(ZsType.fsId, height: 1.3) : zsSans(ZsType.fsSm, height: 1.2))
                              .copyWith(color: on ? colors.text : colors.textDim),
                        ),
                        if (warning case final String warning)
                          Text(warning, style: zsSans(ZsType.fsSm, height: 1.3).copyWith(color: colors.warn)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The id as menus and the card show it: the prefix bold, max(prefix, 8) characters, one `Text.rich`.
  Widget _id(ZsColors colors, String id) {
    final int bold = prefix.clamp(0, id.length);
    final int shown = math.max(bold, 8).clamp(0, id.length);
    final TextStyle style = zsMono(ZsType.fsId, height: 1.2).copyWith(color: colors.textFaint);
    return Text.rich(
      TextSpan(
        style: style,
        children: <InlineSpan>[
          TextSpan(
            text: id.substring(0, bold),
            style: style.copyWith(fontWeight: FontWeight.w600, color: colors.text),
          ),
          TextSpan(text: id.substring(bold, shown)),
        ],
      ),
      maxLines: 1,
      softWrap: false,
    );
  }
}

/// The card's `@` badge (graph.css's `.zs-at`): `--co` fill, `@` in mono `--co-ink`.
class _AtBadge extends StatelessWidget {
  const _AtBadge({required this.colors, required this.radius});

  final ZsColors colors;
  final double radius;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(color: colors.co, borderRadius: BorderRadius.circular(radius)),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      child: Text(
        '@', // l10n-ignore: jj's working-copy symbol
        style: zsMono(ZsType.fsId, weight: FontWeight.w700, height: 1.2).copyWith(color: colors.coInk),
      ),
    ),
  );
}
