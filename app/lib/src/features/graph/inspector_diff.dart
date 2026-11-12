// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart' show RenderParagraph, RenderProxyBox, SemanticsProperties, TextSelection;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';

/// [hunk]'s range in git's notation, `@@ −l,n +r,m @@` with U+2212 for the minus — the color-words format has no
/// header of its own, so Zanshin labels each hunk this way: a line number is the range's 1-based start, or its 0-based
/// start when it is empty (jj's `to_line_number`, cli/src/diff_util.rs @ v0.47.0), the count its length.
String hunkHeader(Hunk hunk) {
  int line(({int start, int end}) range) => range.end > range.start ? range.start + 1 : range.start;
  final ({int start, int end}) l = hunk.before;
  final ({int start, int end}) r = hunk.after;
  return '@@ −${line(l)},${l.end - l.start} +${line(r)},${r.end - r.start} @@'; // l10n-ignore: jj's hunk header
}

/// The side-by-side rows of [lines] (Story 5.10), rebuilt from the color-words lines so each side shows whole lines:
/// a context line is one row (left cell its equal and removed runs with its left number, right cell its equal and
/// added runs with its right number); a run of removed, added and changed lines up to the next context or header line
/// gives one left cell per distinct left number (the equal and removed runs of the lines carrying it, joined) and one
/// right cell per distinct right number likewise, paired row by row, the shorter side's cells null; a conflict header
/// line is one full-width row (the same line in both cells). Cells are [HunkLine]s: a left cell has kind removed (or
/// context) and only a left number, a right cell kind added (or context) and only a right number. Under a `-------`
/// conflict term the left side's runs are the added ones.
List<(HunkLine?, HunkLine?)> pairSideBySide(List<HunkLine> lines) {
  final rows = <(HunkLine?, HunkLine?)>[];
  var swapped = false;
  // The cell of [side]'s runs of [group], numbered [number].
  HunkLine cell(List<HunkLine> group, HunkLineKind kind, {required bool left, required int? number}) {
    final SegmentKind own = left == !swapped ? SegmentKind.removed : SegmentKind.added;
    final segments = <Segment>[];
    for (final line in group) {
      for (final Segment segment in line.segments) {
        if (segment.kind != SegmentKind.equal && segment.kind != own) {
          continue;
        }
        if (segments.isNotEmpty && segments.last.kind == segment.kind) {
          segments.last = Segment(kind: segment.kind, text: segments.last.text + segment.text);
        } else {
          segments.add(segment);
        }
      }
    }
    return HunkLine(
      kind: kind,
      text: segments.map((s) => s.text).join(),
      segments: segments,
      left: left ? number : null,
      right: left ? null : number,
    );
  }

  // The cells of [run]'s distinct numbers on one side, in order.
  List<HunkLine> cells(List<HunkLine> run, {required bool left}) {
    final numbers = <int>[];
    final groups = <int, List<HunkLine>>{};
    for (final line in run) {
      if ((left ? line.left : line.right) case final int number) {
        if (groups[number] case final List<HunkLine> group) {
          group.add(line);
        } else {
          numbers.add(number);
          groups[number] = <HunkLine>[line];
        }
      }
    }
    final HunkLineKind kind = left ? HunkLineKind.removed : HunkLineKind.added;
    return <HunkLine>[for (final int number in numbers) cell(groups[number]!, kind, left: left, number: number)];
  }

  var i = 0;
  while (i < lines.length) {
    final HunkLine line = lines[i];
    if (line.kind == HunkLineKind.conflictHeader) {
      swapped = line.text.startsWith('-------'); // l10n-ignore: jj's conflict term marker
      rows.add((line, line));
      i++;
      continue;
    }
    if (line.kind == HunkLineKind.context) {
      rows.add((
        line.left == null ? null : cell(<HunkLine>[line], HunkLineKind.context, left: true, number: line.left),
        line.right == null ? null : cell(<HunkLine>[line], HunkLineKind.context, left: false, number: line.right),
      ));
      i++;
      continue;
    }
    final run = <HunkLine>[];
    while (i < lines.length && lines[i].kind != HunkLineKind.context && lines[i].kind != HunkLineKind.conflictHeader) {
      run.add(lines[i++]);
    }
    final List<HunkLine> lefts = cells(run, left: true);
    final List<HunkLine> rights = cells(run, left: false);
    for (var k = 0; k < math.max(lefts.length, rights.length); k++) {
      rows.add((k < lefts.length ? lefts[k] : null, k < rights.length ? rights[k] : null));
    }
  }
  return rows;
}

String _text(HunkLine line) {
  final String text = line.text.endsWith('\n') ? line.text.substring(0, line.text.length - 1) : line.text;
  return text.endsWith('\r') ? text.substring(0, text.length - 1) : text;
}

/// One word mark: a range of a line's shown text and the side its run is on.
typedef DiffWordMark = ({TextRange range, SegmentKind kind});

/// The word marks of [line] (Story 10.32, Story 5.10): its [SegmentKind.removed] / [SegmentKind.added] segments (the
/// CLI's coloured tokens) as ranges of its shown text, each cut at that text's end, so a line break is never marked.
/// A changed line always marks them. Any other line marks none when its equal segments hold no visible character (an
/// inserted line, a block over the inline limit's own new lines, a new or deleted file): its fill already says it
/// all. A conflict header line marks none.
List<DiffWordMark> diffWordMarks(HunkLine line) {
  if (line.kind == HunkLineKind.conflictHeader ||
      (line.kind != HunkLineKind.changed &&
          !line.segments.any((s) => s.kind == SegmentKind.equal && s.text.trim().isNotEmpty))) {
    return const <DiffWordMark>[];
  }
  final int shown = _text(line).length;
  final marks = <DiffWordMark>[];
  var start = 0;
  for (final Segment segment in line.segments) {
    final int end = start + segment.text.length;
    if (segment.kind != SegmentKind.equal && start < shown) {
      marks.add((range: TextRange(start: start, end: math.min(end, shown)), kind: segment.kind));
    }
    start = end;
  }
  return marks;
}

/// A line's look: its fill, its text ink and its left / right number inks.
typedef _Look = ({Color fill, Color ink, Color left, Color right});

/// One painted word mark: a range of the paragraph's text and its fill.
typedef PaintedWordMark = ({TextRange range, Color color});

/// Paints [marks], ranges of the text of the paragraph below it (a [Text], behind the proxies a `SelectionArea` adds),
/// each as blocks of its colour the paragraph's full height under its glyphs' boxes, clipped to itself — then the
/// paragraph. Painted under it, the paragraph's selection highlight lies over a mark (Story 10.32; DS content.css
/// `.w`). A changed line carries marks of both colours (Story 5.10).
class DiffWordMarks extends SingleChildRenderObjectWidget {
  /// [marks] under [child].
  const DiffWordMarks({required this.marks, required Widget super.child, super.key});

  /// The marked ranges of the paragraph's text and their fills.
  final List<PaintedWordMark> marks;

  @override
  RenderDiffWordMarks createRenderObject(BuildContext context) => RenderDiffWordMarks(marks: marks);

  @override
  void updateRenderObject(BuildContext context, RenderDiffWordMarks renderObject) => renderObject.marks = marks;
}

/// [DiffWordMarks]'s render box.
class RenderDiffWordMarks extends RenderProxyBox {
  /// A box painting [marks] under its paragraph.
  RenderDiffWordMarks({required this._marks});

  /// The marked ranges of the paragraph's text and their fills.
  List<PaintedWordMark> get marks => _marks;
  List<PaintedWordMark> _marks;
  set marks(List<PaintedWordMark> value) {
    if (!listEquals(value, _marks)) {
      _marks = value;
      markNeedsPaint();
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    RenderObject? node = child;
    while (node is RenderProxyBox) {
      node = node.child;
    }
    if (node is RenderParagraph) {
      // A proxy lays its child out at its own origin, so the paragraph's boxes are this box's coordinates.
      final Rect bounds = offset & size;
      for (final (:TextRange range, :Color color) in _marks) {
        final paint = Paint()..color = color;
        for (final TextBox box in node.getBoxesForSelection(
          TextSelection(baseOffset: range.start, extentOffset: range.end),
        )) {
          final Rect block = Rect.fromLTRB(
            offset.dx + box.left,
            bounds.top,
            offset.dx + box.right,
            bounds.bottom,
          ).intersect(bounds);
          if (block.width > 0) {
            context.canvas.drawRect(block, paint);
          }
        }
      }
    }
    super.paint(context, offset);
  }
}

/// jj's marker after a last line without its newline (`jj diff --git`'s words, kept for the color-words lines).
const noNewlineMarker = r'\ No newline at end of file'; // l10n-ignore: jj's own words

/// The marker line under a line without its newline: faint mono, outside the selection like the sigils.
Widget _noNewline(ZsColors colors, EdgeInsets padding) => Padding(
  padding: padding,
  child: SelectionContainer.disabled(
    child: Text(noNewlineMarker, softWrap: false, style: ZsType.code.copyWith(color: colors.textFaint)),
  ),
);

/// [line]'s shown text in [ink], both layouts' one builder: its [diffWordMarks], if any, on the stronger fill of
/// their side's hue (removed runs `--rem-word-bg`, added runs `--add-word-bg`) with [ZsColors.text] glyphs (coloured
/// text on a stronger tint falls under 4.5:1, DS states.css). A side-by-side [cell] keeps one line, clipped.
Widget _lineText(ZsColors colors, HunkLine line, Color ink, {bool cell = false}) {
  final String text = _text(line);
  final TextStyle style = ZsType.code.copyWith(color: ink);
  final int? maxLines = cell ? 1 : null;
  final TextOverflow? overflow = cell ? TextOverflow.clip : null;
  final List<DiffWordMark> marks = diffWordMarks(line);
  if (marks.isEmpty) {
    return Text(text, maxLines: maxLines, softWrap: false, overflow: overflow, style: style);
  }
  final strong = TextStyle(color: colors.text);
  final spans = <TextSpan>[];
  var at = 0;
  for (final (:TextRange range, kind: _) in marks) {
    if (range.start > at) {
      spans.add(TextSpan(text: text.substring(at, range.start)));
    }
    spans.add(TextSpan(text: range.textInside(text), style: strong));
    at = range.end;
  }
  if (at < text.length) {
    spans.add(TextSpan(text: text.substring(at)));
  }
  return DiffWordMarks(
    marks: <PaintedWordMark>[
      for (final (:TextRange range, :SegmentKind kind) in marks)
        (range: range, color: kind == SegmentKind.added ? colors.addWordBg : colors.remWordBg),
    ],
    child: Text.rich(
      TextSpan(children: spans),
      maxLines: maxLines,
      softWrap: false,
      overflow: overflow,
      style: style,
    ),
  );
}

/// The focused file's diff block (Story 10.24; DS components/content/DiffView, content.css:22-46): the code well with
/// a bar (the path, the layout toggle, Viewed) over its hunks, the refusal text or a one-line placeholder; a viewed
/// file folds into one green row whose click unfolds it and clears Viewed. Without [onViewedChanged] there is no Viewed
/// toggle and nothing folds (Story 10.29's operation view). With [hunkPicked] each hunk with sections gets a checkbox,
/// with [modePicked] the mode-change note does (Story 10.26); without them there is none.
class InspectorDiffView extends StatelessWidget {
  /// The block of [path].
  const InspectorDiffView({
    required this.path,
    required this.diff,
    required this.error,
    required this.layout,
    required this.onLayoutChanged,
    this.viewed = false,
    this.onViewedChanged,
    this.hunkPicked,
    this.onHunkToggled,
    this.modePicked,
    this.onModeToggled,
    super.key,
  });

  /// A hunk's pick state (all, none, null for mixed); null: no hunk checkboxes.
  final bool? Function(Hunk hunk)? hunkPicked;

  /// Toggles a hunk's pick.
  final ValueChanged<Hunk>? onHunkToggled;

  /// Whether the mode change is picked; null: no mode checkbox.
  final bool? modePicked;

  /// Toggles the mode change's pick.
  final VoidCallback? onModeToggled;

  /// The focused path.
  final String path;

  /// Its diff; null while it loads, after a refusal, or when the reply has no entry for it.
  final FileDiff? diff;

  /// The read's refusal.
  final ZanshinFfiException? error;

  /// Whether the file is marked Viewed (ignored without [onViewedChanged]).
  final bool viewed;

  /// Toggles Viewed; null hides the toggle.
  final ValueChanged<bool>? onViewedChanged;

  /// Unified or side by side.
  final DiffLayoutSetting layout;

  /// Changes the layout.
  final ValueChanged<DiffLayoutSetting> onLayoutChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ValueChanged<bool>? onViewedChanged = this.onViewedChanged;
    final bool viewed = this.viewed && onViewedChanged != null;
    final Widget body;
    if (onViewedChanged != null && viewed) {
      body = _FlatButton(
        identifier: 'inspector-diff-folded',
        label: strings.inspectorViewedFolded,
        onPressed: () => onViewedChanged(false),
        builder: (status) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          color: status.hovered ? colors.addBgHi : colors.addBg,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 8,
            children: <Widget>[
              ZanshinIcon(ZI.check, size: ZsIconSize.sm, color: colors.add),
              Flexible(
                child: Text(
                  strings.inspectorViewedFolded,
                  style: ZsType.secondary.copyWith(fontSize: ZsType.fsSm, color: colors.add),
                ),
              ),
            ],
          ),
        ),
      );
    } else if (error case final ZanshinFfiException error?) {
      body = _note(context, error.context ?? error.code);
    } else if (diff case final FileDiff diff?) {
      final bool? Function(Hunk hunk)? hunkPicked = this.hunkPicked;
      final Widget mode = modePicked == null
          ? _note(context, strings.inspectorDiffModeChange)
          : Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: <Widget>[
                  ZsCheckbox(
                    value: modePicked,
                    onChanged: (_) => onModeToggled?.call(),
                    label: strings.inspectorModeCheck,
                    size: ZsCheckboxSize.sm,
                    identifier: 'inspector-mode-check',
                  ),
                  Expanded(child: _note(context, strings.inspectorDiffModeChange)),
                ],
              ),
            );
      body = diff.binary
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (diff.modeChange) mode,
                _note(context, strings.inspectorDiffBinary),
              ],
            )
          : diff.hunks.isEmpty
          ? (diff.modeChange ? mode : _note(context, strings.inspectorDiffNoLines))
          : SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (diff.modeChange) mode,
                  for (var i = 0; i < diff.hunks.length; i++)
                    DecoratedBox(
                      decoration: BoxDecoration(
                        border: i == 0 ? null : Border(top: BorderSide(color: colors.flBorder)),
                      ),
                      child: InspectorDiffHunk(
                        hunk: diff.hunks[i],
                        layout: layout,
                        selectable: hunkPicked != null && diff.hunks[i].sections.isNotEmpty,
                        picked: hunkPicked == null ? false : hunkPicked(diff.hunks[i]),
                        onToggle: () => onHunkToggled?.call(diff.hunks[i]),
                      ),
                    ),
                ],
              ),
            );
    } else {
      body = const SizedBox.shrink();
    }
    return Container(
      key: const ValueKey<String>('inspector-diff'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: viewed ? colors.addEdge : colors.flBorder),
        borderRadius: BorderRadius.circular(metrics.radiusWell),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(12, 7, 8, 7),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: colors.flBorder)),
            ),
            child: Row(
              spacing: 8,
              children: <Widget>[
                Expanded(
                  child: Text(
                    path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.text),
                  ),
                ),
                ZsSegmented<DiffLayoutSetting>(
                  size: ZsSegmentedSize.sm,
                  label: strings.inspectorDiffLayout,
                  identifier: 'inspector-diff-layout',
                  value: layout,
                  onChanged: onLayoutChanged,
                  segments: <ZsSegment<DiffLayoutSetting>>[
                    ZsSegment(
                      value: DiffLayoutSetting.unified,
                      icon: ZI.splitInline,
                      tooltip: strings.inspectorDiffUnified,
                    ),
                    ZsSegment(
                      value: DiffLayoutSetting.sideBySide,
                      icon: ZI.splitSide,
                      tooltip: strings.inspectorDiffSideBySide,
                    ),
                  ],
                ),
                if (onViewedChanged != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: _ViewedToggle(viewed: viewed, onChanged: onViewedChanged),
                  ),
              ],
            ),
          ),
          body,
        ],
      ),
    );
  }

  static Widget _note(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.fromLTRB(10, 6, 10, 8),
    child: Text(
      text,
      key: const ValueKey<String>('inspector-diff-note'),
      style: ZsType.code.copyWith(color: ZsColors.of(context).textDim),
    ),
  );
}

/// The Viewed toggle (DS content.css:40-44): a checkbox role around a presentational add-tone [ZsCheckbox] and
/// "Viewed".
class _ViewedToggle extends StatelessWidget {
  const _ViewedToggle({required this.viewed, required this.onChanged});

  final bool viewed;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    return ZsTooltip(
      message: viewed ? strings.inspectorMarkNotViewed : strings.inspectorMarkViewed,
      child: _FlatButton(
        identifier: 'inspector-viewed',
        label: strings.inspectorViewed,
        checked: viewed,
        radius: metrics.radiusTag,
        onPressed: () => onChanged(!viewed),
        builder: (status) {
          final (Color fill, Color edge, Color ink) = viewed
              ? (status.hovered ? colors.addBgHi : colors.addBg, colors.addRing, colors.add)
              : status.hovered
              ? (colors.flHover, colors.borderStrong, colors.text)
              : (colors.flHover.withValues(alpha: 0), colors.border, colors.textMuted);
          return Container(
            padding: const EdgeInsets.fromLTRB(6, 3, 8, 3),
            decoration: BoxDecoration(
              color: fill,
              border: Border.all(color: edge),
              borderRadius: BorderRadius.circular(metrics.radiusTag),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: 6,
              children: <Widget>[
                ZsCheckbox(
                  value: viewed,
                  presentational: true,
                  size: ZsCheckboxSize.sm,
                  tone: ZsCheckboxTone.add,
                ),
                Text(
                  strings.inspectorViewed,
                  style: ZsType.control.copyWith(fontSize: ZsType.fsXs, color: ink),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A flat button on [ZsControlCore]: a click or ↩ / Space runs [onPressed]; [builder] paints it per state.
class _FlatButton extends StatelessWidget {
  const _FlatButton({
    required this.identifier,
    required this.label,
    required this.onPressed,
    required this.builder,
    this.checked,
    this.radius = 0,
  });

  final String identifier;
  final String label;
  final VoidCallback onPressed;
  final Widget Function(ZsControlStatus status) builder;
  final bool? checked;
  final double radius;

  @override
  Widget build(BuildContext context) => ZsControlCore(
    identifier: identifier,
    onActivate: onPressed,
    ring: ZsRingPlacement.inside,
    ringRadius: radius,
    semantics: SemanticsProperties(button: checked == null, checked: checked, label: label),
    builder: (context, status) => builder(status),
  );
}

/// A small text button in the Changes header, "Mark all" / "Reset" (DS kit.css:121-122): padding 2 7, radius 6,
/// `--text-muted`, hover `--fl-hover` and `--text`.
class InspectorTextButton extends StatelessWidget {
  /// A button reading [label].
  const InspectorTextButton({required this.label, required this.onPressed, required this.identifier, super.key});

  /// The text.
  final String label;

  /// Runs on activation.
  final VoidCallback onPressed;

  /// The node's identifier.
  final String identifier;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return _FlatButton(
      identifier: identifier,
      label: label,
      radius: 6,
      onPressed: onPressed,
      builder: (status) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: status.hovered ? colors.flHover : colors.flHover.withValues(alpha: 0),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          label,
          style: ZsType.secondary.copyWith(
            fontSize: 11.5,
            color: status.hovered ? colors.text : colors.textMuted,
          ),
        ),
      ),
    );
  }
}

/// One hunk (DS components/content/DiffHunk, content.css:48-55): the header band (`--hunk-bg`: the range in
/// `--hunk`, the symbol, +added / −removed) over its color-words lines (Story 5.10), unified (a left and a right
/// line-number column, scrolling horizontally on its own) or side by side (two clipped cells per row, each with its
/// number, whole lines rebuilt by [pairSideBySide]). The unified lines sit in a [ZsScrollArea]: its bar along the bottom
/// shows a cut line while scrolling or hovered, ←/→ scroll it when focused. Story 10.26 (DS DiffHunk.prompt.md:8-11,
/// content.css:58-59): a [selectable] hunk leads its header with a tristate checkbox (its Tab stop, Space toggles);
/// a picked one (all or mixed) has its header on `--accent-soft-hi` with `--text` and a 2 px `--accent-line` edge
/// along its lines. Story 10.32: a line's changed words carry [DiffWordMarks] in both layouts.
class InspectorDiffHunk extends StatefulWidget {
  /// [hunk] in [layout].
  const InspectorDiffHunk({
    required this.hunk,
    required this.layout,
    this.selectable = false,
    this.picked = false,
    this.onToggle,
    super.key,
  });

  /// The hunk.
  final Hunk hunk;

  /// Unified or side by side.
  final DiffLayoutSetting layout;

  /// Whether the header has a checkbox.
  final bool selectable;

  /// Its pick: all, none, or null for some of its sections.
  final bool? picked;

  /// Toggles [picked].
  final VoidCallback? onToggle;

  @override
  State<InspectorDiffHunk> createState() => _InspectorDiffHunkState();
}

class _InspectorDiffHunkState extends State<InspectorDiffHunk> {
  // The area's vertical controller stays unattached: the hunk scrolls only sideways, the inspector scrolls it down.
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  Hunk get hunk => widget.hunk;

  DiffLayoutSetting get layout => widget.layout;

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final TextStyle head = ZsType.id.copyWith(fontSize: ZsType.fsSm);
    final String? symbol = hunk.symbol;
    final bool chosen = widget.picked ?? true;
    final Widget lines = layout == DiffLayoutSetting.unified ? _unified(colors) : _sideBySide(colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Container(
          key: const ValueKey<String>('inspector-hunk-header'),
          constraints: const BoxConstraints(minHeight: 30),
          padding: const EdgeInsets.symmetric(horizontal: 10),
          color: chosen ? colors.accentSoftHi : colors.hunkBg,
          child: Row(
            spacing: 8,
            children: <Widget>[
              if (widget.selectable)
                ZsCheckbox(
                  value: widget.picked,
                  tristate: true,
                  onChanged: (_) => widget.onToggle?.call(),
                  label: context.l10n.inspectorHunkCheck(hunkHeader(hunk)),
                  size: ZsCheckboxSize.sm,
                  identifier: 'inspector-hunk-check',
                ),
              Text(hunkHeader(hunk), style: head.copyWith(color: chosen ? colors.text : colors.hunk)),
              Expanded(
                child: symbol == null
                    ? const SizedBox.shrink()
                    : Text(
                        symbol,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: head.copyWith(color: colors.textMuted),
                      ),
              ),
              if (hunk.added > 0)
                Text('+${hunk.added}', style: head.copyWith(color: colors.add)), // l10n-ignore: a count
              if (hunk.removed > 0)
                Text('−${hunk.removed}', style: head.copyWith(color: colors.rem)), // l10n-ignore: a count
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          // Always there (no edge: none drawn), so a toggle keeps the lines' scroll position.
          child: DecoratedBox(
            key: const ValueKey<String>('inspector-hunk-edge'),
            position: DecorationPosition.foreground,
            decoration: BoxDecoration(
              border: chosen ? Border(left: BorderSide(color: colors.accentLine, width: 2)) : null,
            ),
            child: lines,
          ),
        ),
      ],
    );
  }

  /// A line's look (Story 5.10): its fill, its text ink and its left / right number inks. Context: faint numbers,
  /// muted text. Removed / added: the side's hue for its number and text on the side's fill. Changed: both numbers
  /// in their hue, no fill, `--text` ink. A conflict header: `--text-dim`, no numbers.
  _Look _look(ZsColors colors, HunkLineKind kind) {
    final Color none = colors.textMuted.withValues(alpha: 0);
    return switch (kind) {
      HunkLineKind.context => (fill: none, ink: colors.textMuted, left: colors.textFaint, right: colors.textFaint),
      HunkLineKind.added => (fill: colors.addBg, ink: colors.add, left: colors.add, right: colors.add),
      HunkLineKind.removed => (fill: colors.remBg, ink: colors.rem, left: colors.rem, right: colors.rem),
      HunkLineKind.changed => (fill: none, ink: colors.text, left: colors.rem, right: colors.add),
      HunkLineKind.conflictHeader => (fill: none, ink: colors.textDim, left: none, right: none),
    };
  }

  /// A line number right-aligned in [digits] columns of the mono face, outside the selection; blank for none.
  Widget _number(int? number, int digits, Color ink) => SelectionContainer.disabled(
    child: Text(
      '${number ?? ''}'.padLeft(digits),
      softWrap: false,
      style: ZsType.code.copyWith(color: ink),
    ),
  );

  /// The number columns' width in digits: the hunk's largest number's.
  int get _digits {
    var largest = 0;
    for (final HunkLine line in hunk.lines) {
      largest = math.max(largest, math.max(line.left ?? 0, line.right ?? 0));
    }
    return '$largest'.length;
  }

  Widget _unified(ZsColors colors) {
    final int digits = _digits;
    return LayoutBuilder(
      builder: (context, constraints) => ZsScrollArea(
        controller: _vertical,
        horizontalController: _horizontal,
        child: SingleChildScrollView(
          controller: _horizontal,
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: constraints.maxWidth),
            child: IntrinsicWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  for (final HunkLine line in hunk.lines) ...<Widget>[
                    Builder(
                      builder: (context) {
                        final _Look look = _look(colors, line.kind);
                        final header = line.kind == HunkLineKind.conflictHeader;
                        return Container(
                          color: look.fill,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            spacing: 8,
                            children: <Widget>[
                              if (!header) ...<Widget>[
                                _number(line.left, digits, look.left),
                                _number(line.right, digits, look.right),
                              ],
                              _lineText(colors, line, look.ink),
                            ],
                          ),
                        );
                      },
                    ),
                    // Blank number columns put the marker where the line's text starts.
                    if (!line.text.endsWith('\n'))
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          spacing: 8,
                          children: <Widget>[
                            _number(null, digits, colors.textFaint),
                            _number(null, digits, colors.textFaint),
                            _noNewline(colors, EdgeInsets.zero),
                          ],
                        ),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _sideBySide(ZsColors colors) {
    final int digits = _digits;
    Widget cell(HunkLine? line, {required bool left}) {
      final BorderSide edge = left ? BorderSide(color: colors.flBorder) : BorderSide.none;
      if (line == null) {
        return Container(
          constraints: const BoxConstraints(minHeight: 17),
          decoration: BoxDecoration(
            color: colors.flHover.withValues(alpha: colors.flHover.a * .4),
            border: Border(right: edge),
          ),
        );
      }
      final _Look look = _look(colors, line.kind);
      return Container(
        constraints: const BoxConstraints(minHeight: 17),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: look.fill,
          border: Border(right: edge),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              spacing: 8,
              children: <Widget>[
                if (line.kind != HunkLineKind.conflictHeader)
                  _number(left ? line.left : line.right, digits, left ? look.left : look.right),
                Expanded(child: _lineText(colors, line, look.ink, cell: true)),
              ],
            ),
            if (!line.text.endsWith('\n')) _noNewline(colors, EdgeInsets.zero),
          ],
        ),
      );
    }

    return Column(
      key: const ValueKey<String>('inspector-diff-split'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        for (final (HunkLine? left, HunkLine? right) in pairSideBySide(hunk.lines))
          IntrinsicHeight(
            child: left != null && left.kind == HunkLineKind.conflictHeader
                ? cell(left, left: false)
                : Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      Expanded(child: cell(left, left: true)),
                      Expanded(child: cell(right, left: false)),
                    ],
                  ),
          ),
      ],
    );
  }
}
