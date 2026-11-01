// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/widgets.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card.dart';
import 'graph_layout.dart';
import 'hatch_swatch.dart';

/// The peek's width (DS components/overlays/overlays.css:25).
const double graphPeekWidth = 340;

/// The gap between a card and its peek, and between an affordance and its tooltip.
const double _gap = 8;

/// Where a peek of [size] goes beside [card] inside [area] (Story 10.6 item 7): 8 px right of the card, flipped to
/// its left when it would cross [area]'s right edge; its top at the card's top, shifted up to stay above [area]'s
/// bottom; clamped inside [area]. Returns the top-left and whether it was flipped.
({Offset topLeft, bool flipped}) graphPeekPosition(Rect card, Size size, Rect area) {
  final bool flipped = card.right + _gap + size.width > area.right;
  final double x = flipped ? card.left - _gap - size.width : card.right + _gap;
  final double y = math.min(card.top, area.bottom - size.height);
  return (
    topLeft: Offset(
      clampDouble(x, area.left, math.max(area.left, area.right - size.width)),
      clampDouble(y, area.top, math.max(area.top, area.bottom - size.height)),
    ),
    flipped: flipped,
  );
}

/// Where a tooltip of [size] goes for the affordance [target] inside [area]: centred 8 px above it, below when above
/// would leave [area]; clamped horizontally inside [area]. Returns the top-left and whether it sits below.
({Offset topLeft, bool below}) graphTooltipPosition(Rect target, Size size, Rect area) {
  final double above = target.top - _gap - size.height;
  final bool below = above < area.top;
  final double x = target.center.dx - size.width / 2;
  return (
    topLeft: Offset(
      clampDouble(x, area.left, math.max(area.left, area.right - size.width)),
      below ? target.bottom + _gap : above,
    ),
    below: below,
  );
}

/// The commit callout (Story 10.6 item 7; DS components/overlays/PeekCard.*, overlays.css:24-39) on the one menu
/// material, 340 wide, padding 12 14 10, gap 8:
/// - an immutable non-root change first shows the eyebrow: `HatchSwatch` and IMMUTABLE in `--type-caps` /
///   `--text-muted` (its reason is 11.7's);
/// - the full subject, wrapped ("no description" when empty, `root()` on the root); while a non-root change's content
///   loads, one static skeleton bar in its place (Story 10.12);
/// - the description's body below it (`.zs-peek-desc`: `--fs-md`, line height 1.45, `--text-dim`, its line breaks
///   kept);
/// - the meta row: the change id (jj's prefix bold, then the rest up to max(prefix, 8), one `Text.rich`), the commit
///   id (max(prefix, 8) hex in `--text-faint` mono), the author's full name (else the email), the relative date in
///   `--text-faint` mono;
/// - the hint line: mutable "Click: details · Double-click: jj edit", immutable "Click: details", @ "Working copy (@)
///   · Click for details", the root none.
class GraphPeek extends StatelessWidget {
  /// The peek of [data] at "now" [nowMs].
  const GraphPeek({required this.data, required this.nowMs, super.key});

  /// The change's facts.
  final GraphCardData data;

  /// "Now" for the relative date, epoch ms.
  final int nowMs;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final GraphCardData d = data;
    final GraphCommitContent? content = d.content;
    final TextStyle subjectStyle = ZsType.cardSubject.copyWith(
      fontSize: ZsType.fsBase,
      fontWeight: FontWeight.w600,
      fontVariations: const <FontVariation>[FontVariation.weight(600)],
      color: colors.text,
    );
    final Widget subject = d.isRoot
        ? Text(
            'root()', // l10n-ignore: jj's text
            style: subjectStyle.copyWith(fontFamily: ZsType.monoFamily, color: colors.textMuted),
          )
        : content == null
        // Loading (Story 10.12): one static bar in the subject's place, the card skeleton's colour and 58 %.
        ? Align(
            key: const ValueKey<String>('peek-skeleton'),
            alignment: AlignmentDirectional.centerStart,
            child: FractionallySizedBox(
              widthFactor: .58,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: SizedBox(
                  height: 9,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: colors.skeleton,
                      borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusXs),
                    ),
                  ),
                ),
              ),
            ),
          )
        : content.subject.isEmpty
        ? Text(
            strings.cardNoDescription,
            style: subjectStyle.copyWith(fontStyle: FontStyle.italic, color: colors.textDim),
          )
        : Text(content.subject, style: subjectStyle);
    final int prefix = d.prefixLength.clamp(0, d.changeId.length);
    final int shown = math.max(prefix, 8).clamp(0, d.changeId.length);
    final String? author = content == null
        ? null
        : content.authorName.trim().isNotEmpty
        ? content.authorName.trim()
        : content.authorEmail.trim().isEmpty
        ? null
        : content.authorEmail.trim();
    // The body below the subject: the description after its first line.
    final String body = switch (content?.description) {
      final String text when text.contains('\n') => text.substring(text.indexOf('\n') + 1).trim(),
      _ => '',
    };
    final String? commitId = d.commitId;
    final int? ts = d.timestampMs;
    final TextStyle meta = ZsType.meta.copyWith(fontSize: ZsType.fsId, color: colors.textDim);
    final String? hint = d.isRoot
        ? null
        : d.isWorkingCopy
        ? strings.peekHintWorkingCopy
        : d.immutable
        ? strings.peekHintImmutable
        : strings.peekHintMutable;
    return SizedBox(
      width: graphPeekWidth,
      child: ZsMenuMaterial(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: <Widget>[
            if (d.immutable && !d.isRoot)
              Row(
                spacing: 6,
                children: <Widget>[
                  const HatchSwatch(),
                  Text(
                    ZsType.caps(strings.peekImmutable),
                    style: ZsType.capsLabel.copyWith(color: colors.textMuted),
                  ),
                ],
              ),
            subject,
            if (body.isNotEmpty)
              Text(
                body,
                key: const ValueKey<String>('peek-description'),
                style: ZsType.meta.copyWith(fontSize: ZsType.fsMd, height: 1.45, color: colors.textDim),
              ),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                Text.rich(
                  TextSpan(
                    style: ZsType.id.copyWith(color: colors.textDim),
                    children: <InlineSpan>[
                      TextSpan(
                        text: d.changeId.substring(0, prefix),
                        style: ZsType.id.copyWith(
                          fontWeight: FontWeight.w700,
                          fontVariations: const <FontVariation>[FontVariation.weight(700)],
                          color: colors.text,
                        ),
                      ),
                      TextSpan(text: d.changeId.substring(prefix, shown)),
                      if (d.changeOffset != null) TextSpan(text: '/${d.changeOffset}'),
                    ],
                  ),
                ),
                // A recording carries no commit ids (prefix 0): its key stands in, so nothing shows.
                if (commitId != null && !d.isRoot && d.commitPrefixLength > 0)
                  Text(
                    commitId.substring(0, math.max(d.commitPrefixLength, 8).clamp(0, commitId.length)),
                    key: const ValueKey<String>('peek-commit'),
                    style: ZsType.id.copyWith(fontSize: ZsType.fsId, color: colors.textFaint),
                  ),
                if (author != null) Text(author, style: meta),
                if (ts != null)
                  Text(
                    graphRelativeDate(strings, ts, nowMs: nowMs, utcOffsetMinutes: d.utcOffsetMinutes),
                    style: ZsType.id.copyWith(fontSize: ZsType.fsId, color: colors.textFaint),
                  ),
              ],
            ),
            if (hint != null)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(top: BorderSide(color: colors.border)),
                ),
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(hint, style: ZsType.meta.copyWith(color: colors.textDim)),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
