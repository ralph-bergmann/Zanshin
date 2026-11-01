// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show clampDouble;
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show ShowEntry;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card.dart';
import 'graph_content.dart';
import 'graph_gaps.dart';
import 'graph_layout.dart';

/// The gap callout's width (design/graph.css:317).
const double graphGapCalloutWidth = 320;

/// Where a gap callout of [size] goes for the target [point] inside [area] (Story 10.19): its top-left 18 px right of
/// the point and 22 px above it, flipped to the point's left when it would cross [area]'s right edge; clamped inside
/// [area]. It draws no arrow (item I1), so a flip only mirrors its x.
Offset graphGapCalloutPosition(Offset point, Size size, Rect area) {
  final bool flipped = point.dx + 18 + size.width > area.right;
  final double x = flipped ? point.dx - 18 - size.width : point.dx + 18;
  final double y = point.dy - 22;
  return Offset(
    clampDouble(x, area.left, math.max(area.left, area.right - size.width)),
    clampDouble(y, area.top, math.max(area.top, area.bottom - size.height)),
  );
}

/// The gap callout (Story 10.19; design/graph-gaps.jsx:159-193, without the count) on the one menu material, no
/// arrow: the title per kind; the chain — the child's row (its change id with jj's prefix bold, max(prefix, 8)
/// characters, its subject, the member count of a stack), the glyph with "Hidden commits" or "Older history not
/// shown", then the shown ancestors' rows, or for a Missing edge the hidden parents' ids (from one [show] of the
/// child, a skeleton while it loads) with "parent, not in revset"; the description; "Show in `all()`" with its hint.
class GraphGapCallout extends StatefulWidget {
  /// The callout of [gap] in [layout].
  const GraphGapCallout({required this.layout, required this.gap, this.content, this.show, this.onShow, super.key});

  /// The layout shown.
  final GraphLayout layout;

  /// The gap.
  final GraphGap gap;

  /// The rows' content cache (Story 10.11).
  final GraphContent? content;

  /// `jj show` of a commit id: a Missing edge's hidden parents; null shows none.
  final Future<ShowEntry> Function(String commitId)? show;

  /// "Show in `all()`"; null disables it.
  final VoidCallback? onShow;

  @override
  State<GraphGapCallout> createState() => _GraphGapCalloutState();
}

/// The node whose commit a gap of [node] leaves from: a stack node's oldest member.
int graphGapCommitNode(GraphLayout layout, int node) =>
    layout.isStackNode(node) ? layout.runMembersOf(layout.runOf(node)!).first : node;

class _GraphGapCalloutState extends State<GraphGapCallout> {
  Future<List<String>>? _hidden;

  @override
  void initState() {
    super.initState();
    final Future<ShowEntry> Function(String commitId)? show = widget.show;
    if (widget.gap.isStub && show != null) {
      final GraphLayout layout = widget.layout;
      _hidden = show(layout.commitIdOf(graphGapCommitNode(layout, widget.gap.node))).then(
        (entry) => <String>[
          for (final String parent in entry.change.parents)
            if (layout.indexOfKey(parent) == null) parent,
        ],
      );
      // A failed read shows no rows; the future's error is consumed here.
      unawaited(_hidden!.then((_) {}, onError: (Object _) {}));
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final GraphLayout layout = widget.layout;
    final GraphGap gap = widget.gap;
    final TextStyle mid = ZsType.code.copyWith(fontSize: ZsType.fsSm, height: 1.2, color: colors.textDim);
    return SizedBox(
      width: graphGapCalloutWidth,
      child: ZsMenuMaterial(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: <Widget>[
            Text(
              switch (gap.kind) {
                GraphGapKind.indirect => strings.gapTitleIndirect,
                GraphGapKind.hiddenMerge => strings.gapTitleHiddenMerge,
                GraphGapKind.missing => strings.gapTitleMissing,
              },
              style: ZsType.cardSubject.copyWith(
                fontSize: ZsType.fsBase,
                fontWeight: FontWeight.w600,
                fontVariations: const <FontVariation>[FontVariation.weight(600)],
                color: colors.text,
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                border: Border.symmetric(horizontal: BorderSide(color: colors.border)),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 2,
                  children: <Widget>[
                    _row(context, gap.node),
                    Padding(
                      padding: const EdgeInsets.only(left: 10),
                      child: Row(
                        spacing: 8,
                        children: <Widget>[
                          CustomPaint(
                            size: const Size(16, 22),
                            painter: _GlyphPainter(stub: gap.isStub, line: colors.edge, cut: colors.textFaint),
                          ),
                          Text(gap.isStub ? strings.gapOlderHistory : strings.gapHiddenCommits, style: mid),
                        ],
                      ),
                    ),
                    if (gap.isStub)
                      FutureBuilder<List<String>>(
                        future: _hidden,
                        builder: (context, snapshot) {
                          if (_hidden != null && snapshot.connectionState != ConnectionState.done) {
                            return _skeletonRow(context);
                          }
                          return Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: <Widget>[
                              for (final String id in snapshot.data ?? const <String>[]) _hiddenRow(context, id),
                            ],
                          );
                        },
                      )
                    else
                      for (final int edge in gap.edges) _row(context, layout.parentOf(edge)),
                  ],
                ),
              ),
            ),
            Text(
              switch (gap.kind) {
                GraphGapKind.indirect => strings.gapDescIndirect,
                GraphGapKind.hiddenMerge => strings.gapDescHiddenMerge,
                GraphGapKind.missing => strings.gapDescMissing,
              },
              style: ZsType.meta.copyWith(fontSize: ZsType.fsMd, height: 1.45, color: colors.textDim),
            ),
            Wrap(
              spacing: 10,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                ZsButton(
                  label: strings.gapShowIn('all()'), // l10n-ignore: jj revset
                  onPressed: widget.onShow,
                  identifier: 'graph-gap-show-all',
                ),
                Text(
                  strings.gapShowInHint,
                  style: ZsType.meta.copyWith(fontSize: ZsType.fsSm, color: colors.textDim),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// A shown node's row: its id, subject and, for a stack, its member count (the newest member's facts).
  Widget _row(BuildContext context, int node) {
    final ZsColors colors = ZsColors.of(context);
    final GraphLayout layout = widget.layout;
    final int? run = layout.isStackNode(node) ? layout.runOf(node) : null;
    final List<int>? members = run == null ? null : layout.runMembersOf(run);
    final d = GraphCardData.of(layout, members?.last ?? node, content: widget.content);
    final int prefix = d.prefixLength.clamp(0, d.changeId.length);
    final int shown = math.max(prefix, 8).clamp(0, d.changeId.length);
    final String subject = d.content?.subject ?? '';
    return SizedBox(
      height: 22,
      child: Row(
        spacing: 8,
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
              ],
            ),
          ),
          Expanded(
            child: Text(
              subject,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZsType.meta.copyWith(fontSize: ZsType.fsMd, color: colors.text),
            ),
          ),
          if (members != null)
            Text(
              '${members.length}',
              style: ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textMuted),
            ),
        ],
      ),
    );
  }

  /// A hidden parent's row: its change id, max(8) characters without a bold prefix (its prefix length is unknown).
  Widget _hiddenRow(BuildContext context, String id) {
    final ZsColors colors = ZsColors.of(context);
    return SizedBox(
      height: 22,
      child: Row(
        spacing: 8,
        children: <Widget>[
          Text(id.substring(0, math.min(8, id.length)), style: ZsType.id.copyWith(color: colors.textDim)),
          Expanded(
            child: Text(
              context.l10n.gapParentNotInRevset,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ZsType.meta.copyWith(fontSize: ZsType.fsMd, fontStyle: FontStyle.italic, color: colors.textFaint),
            ),
          ),
        ],
      ),
    );
  }

  Widget _skeletonRow(BuildContext context) => SizedBox(
    key: const ValueKey<String>('gap-callout-skeleton'),
    height: 22,
    child: Align(
      alignment: AlignmentDirectional.centerStart,
      child: SizedBox(
        width: 140,
        height: 9,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: ZsColors.of(context).skeleton,
            borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusXs),
          ),
        ),
      ),
    ),
  );
}

/// The chain's glyph: a dashed line with the `//`, or an end stub's lead and `//`.
class _GlyphPainter extends CustomPainter {
  _GlyphPainter({required this.stub, required this.line, required this.cut});

  final bool stub;
  final Color line;
  final Color cut;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = line;
    final double x = size.width / 2;
    if (stub) {
      canvas
        ..drawLine(Offset(x, 1), Offset(x, 4), paint)
        ..drawLine(Offset(x, 9), Offset(x, 10), paint);
      graphPaintGapCuts(canvas, Offset(x, 14), cut);
    } else {
      canvas
        ..drawLine(Offset(x, 0), Offset(x, 3), paint)
        ..drawLine(Offset(x, 19), Offset(x, 22), paint);
      graphPaintGapCuts(canvas, Offset(x, 11), cut);
    }
  }

  @override
  bool shouldRepaint(_GlyphPainter oldDelegate) =>
      stub != oldDelegate.stub || line != oldDelegate.line || cut != oldDelegate.cut;
}
