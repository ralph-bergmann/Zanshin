// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/rendering.dart' show RenderParagraph, RenderProxyBox, SemanticsProperties, TextSelection;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show SelectionArea;
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, DiffWhitespaceSetting;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'hatch_swatch.dart';
import 'inspector_check_reveal.dart';
import 'inspector_path_label.dart';
import 'project_files.dart' show announceCopied;

/// The widest the inspector's context menus grow (design inspector-study.css:202 `max-width:380px`).
const double inspectorMenuMaxWidth = 380;

/// The widest a context menu row's hint grows before it ends in an ellipsis: the label keeps its room.
const double inspectorMenuHintMaxWidth = 190;

/// The new-side line number of [hunk]'s line at [index] (Story 10.39): its right number; a line without one (removed)
/// takes the next line's, the place where it stood; after the hunk's last such line the last one + 1, or the hunk's
/// new start without any.
int diffNewLineAt(Hunk hunk, int index) {
  final List<HunkLine> lines = hunk.lines;
  for (var i = index; i < lines.length; i++) {
    if (lines[i].right case final int right) {
      return right;
    }
  }
  for (int i = index - 1; i >= 0; i--) {
    if (lines[i].right case final int right) {
      return right + 1;
    }
  }
  return hunk.after.start + 1;
}

/// [diffNewLineAt] of [line], found in [hunk] by identity, else (a rebuilt cell) by its left number.
int diffNewLineOf(Hunk hunk, HunkLine line) {
  if (line.right case final int right) {
    return right;
  }
  int index = hunk.lines.indexOf(line);
  if (index < 0) {
    index = hunk.lines.indexWhere((l) => l.left != null && l.left == line.left);
  }
  return diffNewLineAt(hunk, math.max(0, index));
}

/// The diff header's path (Story 10.39; design inspector-study.css:190-194): the name (500) then the folder dimmed,
/// cut as a file row's. With [copyPath] a flat button — "Click to copy …" its tooltip — that copies it and shows
/// "Copied" in `--add` for 1.3 s; without, plain text.
class _DiffPath extends StatefulWidget {
  const _DiffPath({required this.path, required this.copyPath});

  final String path;
  final String? copyPath;

  @override
  State<_DiffPath> createState() => _DiffPathState();
}

class _DiffPathState extends State<_DiffPath> {
  Timer? _timer;
  var _copied = false;

  @override
  void didUpdateWidget(_DiffPath oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _timer?.cancel();
      _copied = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException {
      return;
    }
    if (!mounted) {
      return;
    }
    announceCopied(context);
    _timer?.cancel();
    setState(() => _copied = true);
    _timer = Timer(const Duration(milliseconds: 1300), () {
      if (mounted) {
        setState(() => _copied = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final ({String name, String head, String tail}) parts = inspectorPathParts(widget.path);
    final TextStyle style = ZsType.id.copyWith(fontSize: ZsType.fsXs);
    final Widget label = InspectorPathLabel(
      name: parts.name,
      head: parts.head,
      tail: parts.tail,
      nameStyle: style.copyWith(
        color: colors.text,
        fontWeight: FontWeight.w500,
        fontVariations: const <FontVariation>[FontVariation.weight(500)],
      ),
      folderStyle: style.copyWith(color: colors.textFaint),
    );
    final String? copyPath = widget.copyPath;
    if (copyPath == null) {
      return label;
    }
    final AppLocalizations strings = context.l10n;
    return ZsTooltip(
      message: strings.inspectorCopyPath(copyPath),
      child: ZsControlCore(
        identifier: 'inspector-diff-path',
        onActivate: () => unawaited(_copy(copyPath)),
        cursor: SystemMouseCursors.click,
        ring: ZsRingPlacement.inside,
        ringRadius: 6,
        semantics: SemanticsProperties(button: true, label: widget.path, hint: strings.inspectorCopyPathHint),
        builder: (context, status) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: status.hovered ? colors.flHover : colors.flHover.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: 8,
            children: <Widget>[
              Flexible(child: label),
              if (_copied)
                Text(
                  strings.inspectorIdCopied,
                  key: const ValueKey<String>('inspector-diff-path-copied'),
                  style: ZsType.secondary.copyWith(fontSize: 11, color: colors.add),
                ),
            ],
          ),
        ),
      ),
    );
  }
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
/// Without [wordMarks] (Settings › Changed words off, Story 5.14) only a changed line keeps its runs, with no fill and
/// their side's hue as text colour ([ZsColors.rem] / [ZsColors.add]); every other line, side-by-side cells included, is
/// its plain text in [ink].
Widget _lineText(ZsColors colors, HunkLine line, Color ink, {required bool wordMarks, bool cell = false}) {
  final String text = _text(line);
  final TextStyle style = ZsType.code.copyWith(color: ink);
  final int? maxLines = cell ? 1 : null;
  final TextOverflow? overflow = cell ? TextOverflow.clip : null;
  final List<DiffWordMark> marks = wordMarks || line.kind == HunkLineKind.changed
      ? diffWordMarks(line)
      : const <DiffWordMark>[];
  if (marks.isEmpty) {
    return Text(text, maxLines: maxLines, softWrap: false, overflow: overflow, style: style);
  }
  final strong = TextStyle(color: colors.text);
  final spans = <TextSpan>[];
  var at = 0;
  for (final (:TextRange range, :SegmentKind kind) in marks) {
    if (range.start > at) {
      spans.add(TextSpan(text: text.substring(at, range.start)));
    }
    final runStyle = wordMarks ? strong : TextStyle(color: kind == SegmentKind.added ? colors.add : colors.rem);
    spans.add(TextSpan(text: range.textInside(text), style: runStyle));
    at = range.end;
  }
  if (at < text.length) {
    spans.add(TextSpan(text: text.substring(at)));
  }
  final paragraph = Text.rich(
    TextSpan(children: spans),
    maxLines: maxLines,
    softWrap: false,
    overflow: overflow,
    style: style,
  );
  if (!wordMarks) {
    return paragraph;
  }
  return DiffWordMarks(
    marks: <PaintedWordMark>[
      for (final (:TextRange range, :SegmentKind kind) in marks)
        (range: range, color: kind == SegmentKind.added ? colors.addWordBg : colors.remWordBg),
    ],
    child: paragraph,
  );
}

/// The part of a hunk [line] belongs to (Story 10.38, DESIGN-SYSTEM-SYNC #26): the index of the first of [sections]
/// (jj's builtin diff-editor sections, 0-based starts) whose left range holds the line's left number − 1 or whose
/// right range holds its right number − 1; null for a context line, a conflict header and a line in no section.
int? hunkPartOf(List<HunkKey> sections, HunkLine line) {
  if (line.kind == HunkLineKind.context || line.kind == HunkLineKind.conflictHeader) {
    return null;
  }
  return partAt(sections, line.left, line.right);
}

/// The index of the first of [sections] whose left range holds [left] − 1 or whose right range holds [right] − 1;
/// null for none.
int? partAt(List<HunkKey> sections, int? left, int? right) {
  bool inside(int? number, int start, int count) => number != null && number - 1 >= start && number - 1 < start + count;
  for (var i = 0; i < sections.length; i++) {
    final HunkKey s = sections[i];
    if (inside(left, s.oldStart, s.oldCount) || inside(right, s.newStart, s.newCount)) {
      return i;
    }
  }
  return null;
}

/// The diff read's whitespace mode for [setting] (Story 10.33).
DiffWhitespace diffWhitespaceOf(DiffWhitespaceSetting setting) => switch (setting) {
  DiffWhitespaceSetting.showAll => DiffWhitespace.exact,
  DiffWhitespaceSetting.ignoreChangesInAmount => DiffWhitespace.ignoreSpaceChange,
  DiffWhitespaceSetting.ignoreAll => DiffWhitespace.ignoreAllSpace,
};

bool _isChange(HunkLine line) =>
    line.kind == HunkLineKind.removed || line.kind == HunkLineKind.added || line.kind == HunkLineKind.changed;

/// Whether a listed line ([FileDiff.whitespaceLines]) changed only in whitespace: the backend marks it; an identical
/// line between two such lines has one equal segment.
bool _whitespaceOnly(HunkLine line) => line.segments.any((segment) => segment.kind != SegmentKind.equal);

/// The ignoring read's entry for [path] (Story 10.41): [listed], or an empty file with the path when the read does not
/// list it.
FileDiff ignoringOf(String path, FileDiff? listed) =>
    listed ??
    FileDiff(
      path: path,
      kind: FileChangeKind.modified,
      fromPath: null,
      binary: false,
      modeChange: false,
      sections: const <HunkKey>[],
      hunks: const <Hunk>[],
      removed: 0,
      added: 0,
      fingerprint: '',
    );

/// One exact hunk while whitespace is ignored (Story 10.41): the ignoring read's lines and the whitespace-only lines
/// that belong to it. Rust stays the only place that compares lines: everything here is matched by numbers.
@immutable
class DiffBlock {
  const DiffBlock._(this.exact, this.hunk, this.lines, this.whitespaceLines, this.parts, this.foldParts, this._partOf);

  /// The exact read's hunk.
  final Hunk exact;

  /// What the block shows as its hunk: [exact]'s ranges and symbol (a pure addition's gap row anchors at its range),
  /// its lines [lines], its sections every section of every one of [parts] (so every section of [exact]), its counts
  /// the distinct left / right numbers on the ignoring read's changed lines.
  final Hunk hunk;

  /// The ignoring read's lines that belong to it, in order.
  final List<HunkLine> lines;

  /// The listed lines ([FileDiff.whitespaceLines]: whitespace-only lines and the identical lines between them) that
  /// belong to it, in file order.
  final List<HunkLine> whitespaceLines;

  /// Its pickable parts, in the order of their first section: the exact sections its rows touch, tied into one part
  /// where one listed line touches two (by its left number and by its right number), so a pick never takes half of a
  /// line the view shows as one. When a section is touched by no row, all of [exact]'s sections form one part, so a
  /// pick never takes half of a move the ignoring read shows as unchanged.
  final List<List<HunkKey>> parts;

  /// The indices in [parts] of its whitespace-only parts: no ignoring changed line touches them, listed lines do.
  final Set<int> foldParts;

  /// The index in [parts] of each touched section, by its index in [exact]'s sections.
  final Map<int, int> _partOf;

  /// The index in [parts] of [line]: a changed line's by [hunkPartOf], a listed line's by the section holding its left
  /// number, else its right; null for none.
  int? partOf(HunkLine line, {required bool listed}) {
    final List<HunkKey> all = exact.sections;
    final int? section = listed
        ? partAt(all, line.left, null) ?? partAt(all, null, line.right)
        : (_isChange(line) ? hunkPartOf(all, line) : null);
    return section == null ? null : _partOf[section];
  }
}

/// The blocks of [exact] while whitespace is ignored (Story 10.41): one per exact hunk. An ignoring line and a
/// whitespace line belong to the last exact hunk starting at or before it (by its left number, else its right; before
/// the first, the first; a line without numbers stays with the line before it). A block with no line and no whitespace
/// line goes; none left means only whitespace changed. A block's parts together always hold every exact section of its
/// hunk ([DiffBlock.parts]).
List<DiffBlock> diffBlocks(FileDiff exact, FileDiff ignoring) {
  final List<Hunk> hunks = exact.hunks;
  if (hunks.isEmpty) {
    return const <DiffBlock>[];
  }
  var previous = 0;
  int blockOf(HunkLine line) {
    final int? number = line.left ?? line.right;
    if (number == null) {
      return previous;
    }
    var at = 0;
    for (var i = 0; i < hunks.length; i++) {
      final int start = line.left != null ? hunks[i].before.start : hunks[i].after.start;
      if (start <= number - 1) {
        at = i;
      }
    }
    return previous = at;
  }

  final lines = <List<HunkLine>>[for (final _ in hunks) <HunkLine>[]];
  final spaces = <List<HunkLine>>[for (final _ in hunks) <HunkLine>[]];
  for (final Hunk hunk in ignoring.hunks) {
    for (final HunkLine line in hunk.lines) {
      lines[blockOf(line)].add(line);
    }
  }
  for (final HunkLine line in ignoring.whitespaceLines) {
    spaces[blockOf(line)].add(line);
  }
  final blocks = <DiffBlock>[];
  for (var b = 0; b < hunks.length; b++) {
    if (lines[b].isEmpty && spaces[b].isEmpty) {
      continue;
    }
    final List<HunkKey> all = hunks[b].sections;
    final changed = <int>{
      for (final HunkLine line in lines[b])
        if (_isChange(line))
          if (hunkPartOf(all, line) case final int section) section,
    };
    // Sections one listed line touches by both numbers are tied (a small union-find).
    final tie = <int>[for (var i = 0; i < all.length; i++) i];
    int root(int i) => tie[i] == i ? i : tie[i] = root(tie[i]);
    final touched = <int>{...changed};
    for (final HunkLine line in spaces[b]) {
      final int? left = partAt(all, line.left, null);
      final int? right = partAt(all, null, line.right);
      touched.addAll(<int>[?left, ?right]);
      if (left != null && right != null) {
        tie[root(left)] = root(right);
      }
    }
    // A section no row touches holds lines the ignoring read matched elsewhere (half of a move the exact read anchors
    // across); picking only the touched sections would commit that move half. So all sections form one part, and it
    // is never a fold: its pick may commit a moved line.
    // shortcut: finer picks in such a block need the exact view; tying each untouched section to the section of its
    // partner in the ignoring read would keep them, but needs that read's old-to-new number map in Dart. Upgrade when
    // part picks in such blocks matter.
    final bool merged = touched.length < all.length;
    if (merged) {
      for (var i = 0; i < all.length; i++) {
        tie[root(i)] = root(0);
        touched.add(i);
      }
    }
    final groups = <int, List<int>>{};
    for (var i = 0; i < all.length; i++) {
      if (touched.contains(i)) {
        groups.putIfAbsent(root(i), () => <int>[]).add(i);
      }
    }
    final List<List<int>> parts = groups.values.toList();
    final partOf = <int, int>{
      for (var p = 0; p < parts.length; p++)
        for (final int section in parts[p]) section: p,
    };
    int distinct(int? Function(HunkLine line) side) => <int>{
      for (final HunkLine line in lines[b])
        if (_isChange(line)) ?side(line),
    }.length;
    blocks.add(
      DiffBlock._(
        hunks[b],
        Hunk(
          before: hunks[b].before,
          after: hunks[b].after,
          symbol: hunks[b].symbol,
          sections: <HunkKey>[
            for (final List<int> part in parts)
              for (final int section in part) all[section],
          ],
          removed: distinct((line) => line.left),
          added: distinct((line) => line.right),
          lines: lines[b],
        ),
        lines[b],
        spaces[b],
        <List<HunkKey>>[
          for (final List<int> part in parts) <HunkKey>[for (final int section in part) all[section]],
        ],
        <int>{
          for (var p = 0; p < parts.length; p++)
            if (!merged && !parts[p].any(changed.contains)) p,
        },
        partOf,
      ),
    );
  }
  return blocks;
}

/// One row a hunk shows: a line, or a run of hidden whitespace-only lines (Story 10.41).
sealed class DiffRow {
  const DiffRow();
}

/// A line of a hunk and its [part] ([hunkPartOf]; in a block, [DiffBlock.partOf]): the part's checkbox goes on its
/// first shown row.
final class DiffLineRow extends DiffRow {
  /// A row showing [line].
  const DiffLineRow(this.line, {this.part});

  /// The line.
  final HunkLine line;

  /// The index of its part in the hunk's parts ([InspectorDiffHunk.parts]); null for none.
  final int? part;
}

/// A run of whitespace-only lines the ignoring read does not show, in one row at their place (Story 10.41): closed
/// "N more lines with only whitespace changes" with Show; [open], it stays above its lines with Hide. A run of a
/// whitespace-only [part] is that part's fold (hatched, its checkbox). Without [hideable] (a pick keeps it open) it has
/// no button.
final class DiffGapRow extends DiffRow {
  /// The row of [lines].
  const DiffGapRow(this.lines, {required this.open, required this.hideable, this.part, this.owner});

  /// The one part its lines belong to, null for none or several (Story 10.43): the row carries that part's pick edge,
  /// so a part's edge runs unbroken across it.
  final int? owner;

  /// The hidden lines, in file order: whitespace-only lines and the identical lines between them.
  final List<HunkLine> lines;

  /// How many of [lines] changed only in whitespace: those with an added or removed segment. The identical lines
  /// between them do not count.
  int get count => lines.where(_whitespaceOnly).length;

  /// Whether its lines show below it.
  final bool open;

  /// Whether it offers Show / Hide.
  final bool hideable;

  /// The index of the whitespace-only part it folds; null for a plain gap.
  final int? part;

  /// Its key in the open gaps: its first line's left number.
  int get key => lines.first.left ?? 0;
}

/// The rows of an exact [hunk] (Show all whitespace): every line with its part.
List<DiffRow> exactRows(Hunk hunk) => <DiffRow>[
  for (final HunkLine line in hunk.lines) DiffLineRow(line, part: hunkPartOf(hunk.sections, line)),
];

/// A run of unchanged lines the diff does not show, in one quiet row at its place (Story 10.43): "N unchanged lines"
/// with controls that open part or all of it. Numbers are left line numbers, 0-based, half-open.
final class DiffUnchangedRow extends DiffRow {
  /// The row of the gap [key] to [end], of which [from] to [to] are still hidden.
  const DiffUnchangedRow({
    required this.key,
    required this.end,
    required this.from,
    required this.to,
    this.top = false,
    this.bottom = false,
  });

  /// The gap's first line: its identity while parts of it open.
  final int key;

  /// Past the gap's last line: [key] to [end] is what one read fetches.
  final int end;

  /// The first still hidden line.
  final int from;

  /// Past the last still hidden line.
  final int to;

  /// Whether the gap stands before the file's first row (nothing above to show lines below).
  final bool top;

  /// Whether the gap runs to the file's end (nothing below to show lines above).
  final bool bottom;

  /// How many lines are still hidden.
  int get count => to - from;
}

/// How many lines ↓ / ↑ open on a gap row, and the largest gap one ↕ opens whole (design calm-study.jsx `STEP`).
const diffGapStep = 20;

/// What a gap row's control opens: its first [diffGapStep] lines (↓), its last (↑), or all.
enum DiffGapExpand {
  /// The first lines, below the row above.
  down,

  /// The last lines, above the row below.
  up,

  /// Every line.
  all,
}

/// How much of one unchanged gap is open (Story 10.43): [down] lines from its top, [up] from its bottom, and the lines
/// the gap's one read returned.
@immutable
class DiffGapOpen {
  /// A gap opened by [down] and [up] lines, read as [lines].
  const DiffGapOpen({this.down = 0, this.up = 0, this.lines = const <HunkLine>[]});

  /// Lines shown from the gap's top.
  final int down;

  /// Lines shown from the gap's bottom.
  final int up;

  /// The gap's lines as the read returned them: context lines with both numbers.
  final List<HunkLine> lines;
}

/// The rows of a file's [hunks] with its unchanged gaps (Story 10.43): the rows are walked in order, and every run of
/// left line numbers that no row holds is one gap — before the first row, between two rows that are not adjacent on
/// the left side (between hunks or blocks, and inside a block) and after the last row up to [leftLineCount]. A row
/// holds its line's left number, a whitespace gap row ([DiffGapRow]) every left number of its lines; rows without one
/// are skipped, and a hunk without any anchors at its [anchors]' `before.start`. A gap that stands at a hunk's start
/// goes first in that hunk's rows (`gapBefore`), the bottom gap last in the last hunk's. [open] says how much of each
/// gap (by [DiffUnchangedRow.key]) is open: its opened lines become plain context rows (no part), and a gap opened
/// whole leaves no row. With no left lines (an added file) there are no gaps.
List<({List<DiffRow> rows, bool gapBefore})> diffUnchangedRows(
  List<List<DiffRow>> hunks, {
  required List<Hunk> anchors,
  required int leftLineCount,
  Map<int, DiffGapOpen> open = const <int, DiffGapOpen>{},
}) {
  List<int> held(DiffRow row) => switch (row) {
    DiffLineRow(:final HunkLine line) => <int>[?line.left],
    DiffGapRow(:final List<HunkLine> lines) => <int>[for (final HunkLine line in lines) ?line.left],
    DiffUnchangedRow() => const <int>[],
  };
  final result = <({List<DiffRow> rows, bool gapBefore})>[];
  var next = 0;
  List<DiffRow> gap(int from, int to, {bool top = false, bool bottom = false}) {
    final DiffGapOpen state = open[from] ?? const DiffGapOpen();
    final int count = to - from;
    final int down = math.min(state.down, count);
    final int up = math.min(state.up, count - down);
    List<DiffRow> shown(int start, int end) => <DiffRow>[
      for (final HunkLine line in state.lines)
        if (line.left case final int left when left - 1 >= start && left - 1 < end) DiffLineRow(line),
    ];
    return <DiffRow>[
      ...shown(from, from + down),
      if (down + up < count)
        DiffUnchangedRow(key: from, end: to, from: from + down, to: to - up, top: top, bottom: bottom),
      ...shown(to - up, to),
    ];
  }

  for (var h = 0; h < hunks.length; h++) {
    final rows = <DiffRow>[];
    final int start = hunks[h].map(held).expand((lefts) => lefts).firstOrNull ?? anchors[h].before.start + 1;
    final bool gapBefore = leftLineCount > 0 && start - 1 > next;
    if (gapBefore) {
      rows.addAll(gap(next, start - 1, top: h == 0));
    }
    next = math.max(next, start - 1);
    for (final DiffRow row in hunks[h]) {
      final List<int> lefts = held(row);
      if (lefts.isNotEmpty) {
        final int first = lefts.reduce(math.min);
        if (leftLineCount > 0 && first - 1 > next) {
          rows.addAll(gap(next, first - 1));
        }
        next = math.max(next, lefts.reduce(math.max));
      }
      rows.add(row);
    }
    if (h == hunks.length - 1 && leftLineCount > next) {
      rows.addAll(gap(next, leftLineCount, top: rows.isEmpty, bottom: true));
    }
    result.add((rows: rows, gapBefore: gapBefore));
  }
  return result;
}

/// The rows of [block] (Story 10.41): the ignoring read's lines in order — a whitespace-only line among them (inside
/// the context) always shows, with its marks — and every other listed line hidden: each run of them between two
/// shown rows (or before the first / after the last) is one [DiffGapRow] at its place, split where a whitespace-only
/// part's lines start or end. A run with no whitespace-only line (only identical lines) gets no row and stays hidden,
/// as jj's "..." between hunks. A gap whose key is in [opened], or every gap when [revealed] (a pick), is open: its
/// lines follow it.
List<DiffRow> diffBlockRows(DiffBlock block, {Set<int> opened = const <int>{}, bool revealed = false}) {
  // A listed line shows when an ignoring line has its left or its right number (a context pair the CLI split over the
  // alternation limit shows as a left-only and a right-only line).
  final byLeft = <int, HunkLine>{
    for (final HunkLine line in block.whitespaceLines)
      if (line.left case final int left) left: line,
  };
  final byRight = <int, HunkLine>{
    for (final HunkLine line in block.whitespaceLines)
      if (line.right case final int right) right: line,
  };
  final shownLeft = <int>{for (final HunkLine line in block.lines) ?line.left};
  final shownRight = <int>{for (final HunkLine line in block.lines) ?line.right};
  final hidden = <HunkLine>[
    for (final HunkLine line in block.whitespaceLines)
      if (!shownLeft.contains(line.left) && !shownRight.contains(line.right)) line,
  ];
  final rows = <DiffRow>[];
  var run = <HunkLine>[];
  int? runPart;
  void flush() {
    if (run.isEmpty) {
      return;
    }
    final owners = <int>{for (final HunkLine line in run) ?block.partOf(line, listed: true)};
    final gap = DiffGapRow(
      run,
      open: revealed || opened.contains(run.first.left),
      hideable: !revealed,
      part: runPart,
      owner: owners.length == 1 ? owners.single : null,
    );
    if (gap.count > 0) {
      rows.add(gap);
      if (gap.open) {
        rows.addAll(<DiffRow>[
          for (final HunkLine line in run) DiffLineRow(line, part: block.partOf(line, listed: true)),
        ]);
      }
    }
    run = <HunkLine>[];
  }

  void hide(HunkLine line) {
    // An identical line stays in the run it sits in, so a revealed part keeps its lines contiguous.
    if (_whitespaceOnly(line)) {
      final int? part = block.partOf(line, listed: true);
      final int? fold = part != null && block.foldParts.contains(part) ? part : null;
      if (run.any(_whitespaceOnly) && fold != runPart) {
        flush();
      }
      runPart = fold;
    }
    run.add(line);
  }

  // Both lists are in file order; a whitespace line carries both numbers.
  bool before(HunkLine space, HunkLine line) => switch ((line.left, line.right)) {
    (final int left, _) => space.left! < left,
    (null, final int right) => space.right! < right,
    _ => false,
  };
  var h = 0;
  for (final HunkLine line in block.lines) {
    while (h < hidden.length && before(hidden[h], line)) {
      hide(hidden[h++]);
    }
    flush();
    final HunkLine? listed = _isChange(line) ? null : byLeft[line.left] ?? byRight[line.right];
    rows.add(
      DiffLineRow(line, part: listed == null ? block.partOf(line, listed: false) : block.partOf(listed, listed: true)),
    );
  }
  while (h < hidden.length) {
    hide(hidden[h++]);
  }
  flush();
  return rows;
}

/// The diff options menu's rows (Story 10.33, design `inspector-study.jsx`): Whitespace — show all (`jj diff`),
/// ignore changes in amount (`-b`), ignore all (`-w`); Context lines — 0, 1, 2, 3 ("jj's default"), 5, 10, 20 plus
/// [contextLines] in order when it is off that list, none checked when null (jj cannot read it), and with
/// [contextFromRepo] the note that the repository's config wins (Story 10.40); then the note.
List<ZsMenuEntry> diffOptionsEntries(
  AppLocalizations strings, {
  required DiffWhitespaceSetting whitespace,
  required ValueChanged<DiffWhitespaceSetting> onWhitespaceChanged,
  required int? contextLines,
  required ValueChanged<int>? onContextLinesChanged,
  bool contextFromRepo = false,
}) {
  final List<int> choices = <int>{...diffContextChoices, ?contextLines}.toList()..sort();
  return <ZsMenuEntry>[
    ZsMenuHeader(strings.diffWhitespaceHead),
    for (final DiffWhitespaceSetting setting in DiffWhitespaceSetting.values)
      ZsMenuItem(
        label: diffWhitespaceLabel(strings, setting),
        cmd: switch (setting) {
          DiffWhitespaceSetting.showAll => 'jj diff', // l10n-ignore: jj's command
          DiffWhitespaceSetting.ignoreChangesInAmount => 'jj diff -b', // l10n-ignore: jj's command
          DiffWhitespaceSetting.ignoreAll => 'jj diff -w', // l10n-ignore: jj's command
        },
        checked: setting == whitespace,
        radio: true,
        identifier: 'diff-options-whitespace-${setting.name}',
        onSelected: () => onWhitespaceChanged(setting),
      ),
    const ZsMenuSeparator(),
    ZsMenuHeader(strings.diffContextHead),
    for (final int n in choices)
      ZsMenuItem(
        label: '$n',
        shortcut: n == 3 ? strings.diffContextDefault : null,
        checked: n == contextLines,
        radio: true,
        identifier: 'diff-options-context-$n',
        onSelected: onContextLinesChanged == null ? null : () => onContextLinesChanged(n),
      ),
    if (contextFromRepo) ZsMenuNote(strings.diffContextFromRepo),
    const ZsMenuSeparator(),
    ZsMenuNote(strings.diffOptionsNote),
  ];
}

/// The context-line choices of the diff options menu and Settings › General › Diffs.
const diffContextChoices = <int>[0, 1, 2, 3, 5, 10, 20];

/// [setting]'s label in the diff options menu and Settings.
String diffWhitespaceLabel(AppLocalizations strings, DiffWhitespaceSetting setting) => switch (setting) {
  DiffWhitespaceSetting.showAll => strings.diffWhitespaceShowAll,
  DiffWhitespaceSetting.ignoreChangesInAmount => strings.diffWhitespaceIgnoreAmount,
  DiffWhitespaceSetting.ignoreAll => strings.diffWhitespaceIgnoreAll,
};

/// What a unified hunk needs to keep its numbers in view (Story 10.38, deferred-work I1): the file's horizontal
/// scroll and the number columns' digits and width (the file's largest number).
@immutable
class DiffPin {
  /// The pin of one file's unified lines.
  const DiffPin({required this.horizontal, required this.digits, required this.numberWidth});

  /// The file's horizontal scroll; null when the lines do not scroll (nothing moves).
  final ScrollController? horizontal;

  /// A number column's width in digits.
  final int digits;

  /// A number column's width in points.
  final double numberWidth;
}

/// Moves [child] right by [controller]'s offset, so it stays at the visible left edge of a horizontal scroll.
class _Pinned extends StatelessWidget {
  const _Pinned({required this.controller, required this.child});

  final ScrollController? controller;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ScrollController? controller = this.controller;
    if (controller == null) {
      return child;
    }
    return AnimatedBuilder(
      animation: controller,
      child: child,
      builder: (context, child) => Transform.translate(
        offset: Offset(controller.hasClients ? math.max(0, controller.offset) : 0, 0),
        child: child,
      ),
    );
  }
}

/// The focused file's diff block (Story 10.24; DS components/content/DiffView, content.css:22-46): the code well with
/// a bar (the path, the layout toggle, Viewed) over its hunks, the refusal text or a one-line placeholder; a viewed
/// file folds into one green row whose click unfolds it and clears Viewed. Without [onViewedChanged] there is no Viewed
/// toggle and nothing folds (Story 10.29's operation view). With [partPicked] every part of a hunk gets one checkbox,
/// on its first row (Stories 10.38, 10.43), and with [modePicked] the mode-change note does (Story 10.26); without them
/// there is none. Hunks have no header (Story 10.43): they follow each other with a 1 px line between them, and every
/// run of unchanged lines the diff does not show is a gap row ([diffUnchangedRows]) whose controls open lines that
/// [readLines] reads on demand; without [readLines] a gap row shows its count only. With [onWhitespaceChanged] the bar
/// ends in the diff options menu (Story 10.33): whitespace and context lines; with [ignoring] each exact hunk shows the ignoring read's
/// lines with gap rows for the hidden whitespace-only lines ([diffBlocks], [diffBlockRows], Story 10.41), and a file
/// left with none reads "Only whitespace changed in this file."
///
/// Story 10.39: the bar's path shows the name first and its folder dimmed; with [copyPath] a click copies the absolute
/// path. With [lineMenu] a right-click on a line (either layout) opens its context menu in place of the selection's.
///
/// **Scrolling** (Story 10.38). The unified lines of the whole file scroll sideways as one unit, every line as wide as
/// the widest; the number columns stay in view ([DiffPin]). With a bounded height (the inspector)
/// the body fills it and scrolls both ways in one [ZsScrollArea]; with an unbounded one (the Undo Timeline's operation
/// view, the catalogue) it keeps the height of its content and scrolls only sideways.
class InspectorDiffView extends StatelessWidget {
  /// The block of [path].
  const InspectorDiffView({
    required this.path,
    required this.diff,
    required this.error,
    required this.layout,
    required this.onLayoutChanged,
    this.wordMarks = true,
    this.viewed = false,
    this.onViewedChanged,
    this.readLines,
    this.linesRevision,
    this.partPicked,
    this.onPartToggled,
    this.modePicked,
    this.onModeToggled,
    this.whitespace = DiffWhitespaceSetting.showAll,
    this.onWhitespaceChanged,
    this.ignoring,
    this.revealAll = false,
    this.contextLines,
    this.contextFromRepo = false,
    this.onContextLinesChanged,
    this.copyPath,
    this.lineMenu,
    super.key,
  });

  /// [path] as an absolute path (Story 10.39): the header's path becomes a button that copies it; null shows plain
  /// text (no workspace root).
  final String? copyPath;

  /// The context menu of a line (Story 10.39), built when it opens for the line's new-side number ([diffNewLineOf]);
  /// null: no menu.
  final List<ZsMenuEntry> Function(BuildContext context, int line)? lineMenu;

  /// The whitespace mode the menu checks (Story 10.33).
  final DiffWhitespaceSetting whitespace;

  /// Changes the whitespace mode; null: no diff options menu.
  final ValueChanged<DiffWhitespaceSetting>? onWhitespaceChanged;

  /// The file as the read at the whitespace mode lists it ([ignoringOf]); null shows the exact lines.
  final FileDiff? ignoring;

  /// Whether every gap is open without Hide: the file is picked whole (a pick never takes a line the user did not
  /// see).
  final bool revealAll;

  /// `diff.color-words.context`, which the menu checks; null when jj cannot read it.
  final int? contextLines;

  /// Whether the repo or the workspace config sets [contextLines]: the menu says that config wins (Story 10.40).
  final bool contextFromRepo;

  /// Writes `diff.color-words.context` at user scope.
  final ValueChanged<int>? onContextLinesChanged;

  /// Reads the file's unchanged lines whose left number − 1 lies in `start` to `end` (0-based, half-open), as the diff
  /// prints them as context (Story 10.43): what a gap row opens. Null: gap rows show their count only.
  final Future<List<HunkLine>> Function(int start, int end)? readLines;

  /// The revision [readLines] reads at (the inspector: commit and whitespace mode). When it changes while the diff's
  /// fingerprint and ranges stay, every open gap reads its lines again and stays as far open; null: never changes.
  final Object? linesRevision;

  /// Whether a part (a section) is picked; null: no part checkboxes.
  final bool Function(HunkKey part)? partPicked;

  /// Toggles a part's pick.
  final ValueChanged<HunkKey>? onPartToggled;

  /// Whether the mode change is picked; null: no mode checkbox.
  final bool? modePicked;

  /// Toggles the mode change's pick.
  final VoidCallback? onModeToggled;

  /// The focused path.
  final String path;

  /// Its diff; null while it loads, after a refusal, or when the reply has no entry for it.
  final FileDiff? diff;

  /// Whether changed words inside a line get their fill (Settings › General › Diffs › "Changed words", Story 5.14);
  /// off, only a changed line still shows them, in their side's hue as text colour.
  final bool wordMarks;

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
  Widget build(BuildContext context) =>
      LayoutBuilder(builder: (context, constraints) => _build(context, bounded: constraints.hasBoundedHeight));

  Widget _build(BuildContext context, {required bool bounded}) {
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
      final Widget mode = modePicked == null
          ? _note(context, strings.inspectorDiffModeChange)
          : Padding(
              padding: const EdgeInsets.only(left: 10),
              child: Row(
                children: <Widget>[
                  InspectorCheck(
                    value: modePicked,
                    child: ZsCheckbox(
                      value: modePicked,
                      onChanged: (_) => onModeToggled?.call(),
                      label: strings.inspectorModeCheck,
                      size: ZsCheckboxSize.sm,
                      identifier: 'inspector-mode-check',
                    ),
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
          : _DiffBody(
              // A new file starts at the top and the left; its opened parts reset with the file and the mode.
              key: ValueKey<(String, DiffWhitespaceSetting)>((path, whitespace)),
              diff: diff,
              ignoring: ignoring,
              revealAll: revealAll,
              mode: diff.modeChange ? mode : null,
              layout: layout,
              wordMarks: wordMarks,
              bounded: bounded,
              readLines: readLines,
              linesRevision: linesRevision,
              partPicked: partPicked,
              onPartToggled: onPartToggled,
              lineMenu: lineMenu,
            );
    } else {
      body = const SizedBox.shrink();
    }
    // The notes and the folded row sit at the top of a bounded body; the lines scroll there themselves.
    final scrolls = body is _DiffBody;
    return Container(
      key: const ValueKey<String>('inspector-diff'),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colors.codeBg,
        border: Border.all(color: viewed ? colors.addEdge : colors.flBorder),
        borderRadius: BorderRadius.circular(metrics.radiusWell),
      ),
      child: Column(
        mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
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
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _DiffPath(path: path, copyPath: copyPath),
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
                if (onWhitespaceChanged case final ValueChanged<DiffWhitespaceSetting> onWhitespaceChanged)
                  _optionsMenu(strings, onWhitespaceChanged),
              ],
            ),
          ),
          if (!bounded)
            body
          else if (scrolls)
            Expanded(child: body)
          else
            Expanded(child: SingleChildScrollView(child: body)),
        ],
      ),
    );
  }

  /// The diff options menu (Story 10.33): the last control, its glyph `--accent` while a value is off its default.
  Widget _optionsMenu(AppLocalizations strings, ValueChanged<DiffWhitespaceSetting> onWhitespaceChanged) {
    final String mode = diffWhitespaceLabel(strings, whitespace);
    final int? lines = contextLines;
    return ZsMenuButton(
      label: lines == null ? strings.inspectorDiffOptionsUnreadable(mode) : strings.inspectorDiffOptions(mode, lines),
      icon: ZI.viewOptions,
      iconOnly: true,
      active: whitespace != DiffWhitespaceSetting.showAll || lines != 3,
      variant: ZsButtonVariant.ghost,
      identifier: 'inspector-diff-options',
      entries: diffOptionsEntries(
        strings,
        whitespace: whitespace,
        onWhitespaceChanged: onWhitespaceChanged,
        contextLines: lines,
        contextFromRepo: contextFromRepo,
        onContextLinesChanged: onContextLinesChanged,
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

/// A folded whitespace-only row's hatch (design inspector-study.css `.isd-foldrow`): `paintGraphHatch` every 6 px.
class _FoldHatchPainter extends CustomPainter {
  const _FoldHatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      paintGraphHatch(canvas, RRect.fromRectXY(Offset.zero & size, 0, 0), period: 6, color: color);

  @override
  bool shouldRepaint(_FoldHatchPainter oldDelegate) => oldDelegate.color != color;
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

/// The lines of one file's hunks with their scrolling (see [InspectorDiffView]): keyed by the path, so a new file
/// starts at the top and the left.
class _DiffBody extends StatefulWidget {
  const _DiffBody({
    required this.diff,
    required this.ignoring,
    required this.revealAll,
    required this.mode,
    required this.layout,
    required this.wordMarks,
    required this.bounded,
    required this.readLines,
    required this.linesRevision,
    required this.partPicked,
    required this.onPartToggled,
    required this.lineMenu,
    super.key,
  });

  final FileDiff diff;
  final FileDiff? ignoring;
  final bool revealAll;
  final Widget? mode;
  final DiffLayoutSetting layout;
  final bool wordMarks;
  final bool bounded;
  final Future<List<HunkLine>> Function(int start, int end)? readLines;
  final Object? linesRevision;
  final bool Function(HunkKey part)? partPicked;
  final ValueChanged<HunkKey>? onPartToggled;
  final List<ZsMenuEntry> Function(BuildContext context, int line)? lineMenu;

  @override
  State<_DiffBody> createState() => _DiffBodyState();
}

class _DiffBodyState extends State<_DiffBody> {
  // Unbounded, the vertical controller stays unattached: the body scrolls only sideways, its host scrolls it down.
  final _vertical = ScrollController();
  final _horizontal = ScrollController();

  // The line menu (Story 10.39): its rows are built for the line it opens on, when it opens.
  final _menu = ZsMenuController();
  var _menuEntries = const <ZsMenuEntry>[];

  void _openLineMenu(int line, Offset global) {
    final List<ZsMenuEntry> Function(BuildContext context, int line)? build = widget.lineMenu;
    final box = context.findRenderObject() as RenderBox?;
    if (build == null || box == null) {
      return;
    }
    setState(() => _menuEntries = build(context, line));
    _menu.open(position: box.globalToLocal(global));
  }

  // The gaps the user opened, by their first left number (Story 10.41); the key resets them with the file and the mode.
  final _opened = <int>{};

  void _toggleGap(int key) => setState(() => _opened.remove(key) || _opened.add(key));

  // The unchanged gaps the user opened (Story 10.43), by their first left line; the key resets them with the file and
  // the mode, a new diff (another fingerprint) here, and a new lines revision reads them again. A read in flight belongs
  // to its generation.
  final _gaps = <int, DiffGapOpen>{};
  final _reading = <int>{};
  var _generation = 0;

  // The part whose checkbox the pointer rests on: its rows show the pick edge.
  ({int hunk, int part})? _hot;

  @override
  void didUpdateWidget(_DiffBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    final FileDiff old = oldWidget.diff;
    final FileDiff now = widget.diff;
    // The fingerprint ignores line numbers: a reload that only shifts the hunks moves every gap too.
    final bool moved =
        old.leftLineCount != now.leftLineCount ||
        old.hunks.length != now.hunks.length ||
        Iterable<int>.generate(now.hunks.length).any(
          (i) => old.hunks[i].before != now.hunks[i].before || old.hunks[i].after != now.hunks[i].after,
        );
    if (old.fingerprint != now.fingerprint || moved) {
      _gaps.clear();
      _reading.clear();
      _generation++;
      // A box that unmounts under the pointer reports no exit.
      _hot = null;
    } else if (oldWidget.linesRevision != widget.linesRevision) {
      // Same changes at another revision (a rewrite): the unchanged lines may differ, so open gaps read again.
      _reading.clear();
      _generation++;
      for (final MapEntry<int, DiffGapOpen>(:key, :value) in _gaps.entries.toList()) {
        unawaited(_reread(key, value));
      }
    }
    if (widget.partPicked == null) {
      _hot = null;
    }
  }

  /// Reads the open gap at [key] again over its range and keeps its [open] extent; meanwhile its old lines show and its
  /// controls are inert. A refusal or an empty read closes it.
  Future<void> _reread(int key, DiffGapOpen open) async {
    final Future<List<HunkLine>> Function(int start, int end)? read = widget.readLines;
    final int? end = open.lines.lastOrNull?.left;
    if (read == null || end == null) {
      _gaps.remove(key);
      return;
    }
    final int generation = _generation;
    _reading.add(key);
    List<HunkLine>? lines;
    try {
      lines = await read(key, end);
    } on ZanshinFfiException {
      // The read already logged it.
    }
    if (!mounted || generation != _generation) {
      return;
    }
    setState(() {
      _reading.remove(key);
      if (lines == null || lines.isEmpty) {
        _gaps.remove(key);
      } else {
        _gaps[key] = DiffGapOpen(down: open.down, up: open.up, lines: lines);
      }
    });
  }

  /// Opens [gap] by [how]: its first 20 lines, its last 20, or all of them. The first use reads the gap's whole range
  /// once; while it runs the gap's controls are inert, and a refusal leaves it closed.
  Future<void> _expand(DiffUnchangedRow gap, DiffGapExpand how) async {
    final Future<List<HunkLine>> Function(int start, int end)? read = widget.readLines;
    if (read == null || _reading.contains(gap.key)) {
      return;
    }
    DiffGapOpen state = _gaps[gap.key] ?? const DiffGapOpen();
    if (!_gaps.containsKey(gap.key)) {
      final int generation = _generation;
      setState(() => _reading.add(gap.key));
      List<HunkLine>? lines;
      try {
        lines = await read(gap.key, gap.end);
      } on ZanshinFfiException {
        // A refusal leaves the gap closed; the read already logged it.
      } finally {
        // Any failure frees the controls again, so a later click retries.
        if (mounted && generation == _generation) {
          setState(() => _reading.remove(gap.key));
        }
      }
      if (lines == null || !mounted || generation != _generation) {
        return;
      }
      state = DiffGapOpen(lines: lines);
    }
    final DiffGapOpen opened = switch (how) {
      DiffGapExpand.down => DiffGapOpen(down: state.down + diffGapStep, up: state.up, lines: state.lines),
      DiffGapExpand.up => DiffGapOpen(down: state.down, up: state.up + diffGapStep, lines: state.lines),
      DiffGapExpand.all => DiffGapOpen(down: gap.end - gap.key - state.up, up: state.up, lines: state.lines),
    };
    setState(() => _gaps[gap.key] = opened);
  }

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// The number columns' width in digits: the largest number the file can show, so every hunk's numbers line up and a
  /// gap that opens keeps them in place.
  int get _digits {
    var largest = 0;
    final FileDiff? ignoring = widget.ignoring;
    final Iterable<HunkLine> lines = ignoring == null
        ? widget.diff.hunks.expand((hunk) => hunk.lines)
        : ignoring.hunks.expand((hunk) => hunk.lines).followedBy(ignoring.whitespaceLines);
    for (final line in lines) {
      largest = math.max(largest, math.max(line.left ?? 0, line.right ?? 0));
    }
    // A gap row can open the file's last lines: its last left number, and its right one shifted by the changes.
    final FileDiff diff = widget.diff;
    largest = math.max(largest, diff.leftLineCount + math.max(0, diff.added - diff.removed));
    return '$largest'.length;
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final unified = widget.layout == DiffLayoutSetting.unified;
    final bool Function(HunkKey part)? partPicked = widget.partPicked;
    final hunks = <Hunk>[];
    final base = <List<DiffRow>>[];
    final parts = <List<List<HunkKey>>?>[];
    if (widget.ignoring case final FileDiff ignoring) {
      for (final DiffBlock block in diffBlocks(widget.diff, ignoring)) {
        // Any picked part of the exact hunk opens every gap, without Hide: a pick never takes a line not seen.
        final bool revealed = widget.revealAll || block.exact.sections.any((part) => partPicked?.call(part) ?? false);
        hunks.add(block.hunk);
        base.add(diffBlockRows(block, opened: _opened, revealed: revealed));
        parts.add(block.parts);
      }
    } else {
      for (final Hunk hunk in widget.diff.hunks) {
        hunks.add(hunk);
        base.add(exactRows(hunk));
        parts.add(null);
      }
    }
    final List<({List<DiffRow> rows, bool gapBefore})> shown = diffUnchangedRows(
      base,
      anchors: hunks,
      // A file that changed only in whitespace has no hunk at `-w`: jj prints no context for it, so a gap could not
      // open; it gets none.
      leftLineCount: widget.ignoring?.hunks.isEmpty ?? false ? 0 : widget.diff.leftLineCount,
      open: _gaps,
    );
    final Future<List<HunkLine>> Function(int start, int end)? readLines = widget.readLines;
    if (hunks.isEmpty) {
      return Align(
        alignment: Alignment.topLeft,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ?widget.mode,
            InspectorDiffView._note(context, context.l10n.inspectorDiffOnlyWhitespace),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final int digits = _digits;
        final painter = TextPainter(
          text: TextSpan(text: '0' * digits, style: ZsType.code),
          textDirection: TextDirection.ltr,
          textScaler: MediaQuery.maybeTextScalerOf(context) ?? TextScaler.noScaling,
        )..layout();
        final double numberWidth = painter.width.ceilToDouble();
        painter.dispose();
        final pin = DiffPin(
          horizontal: unified ? _horizontal : null,
          digits: digits,
          numberWidth: numberWidth,
        );
        // 4 points above the first row and below the last, as the hunks had before their header went: the overlay
        // scroll bar stays off the last row.
        final Widget all = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const SizedBox(height: 4),
            for (var i = 0; i < hunks.length; i++)
              DecoratedBox(
                // Where a gap row (or the lines it opened) sits between two hunks, it is the separator.
                decoration: BoxDecoration(
                  border: i == 0 || shown[i].gapBefore ? null : Border(top: BorderSide(color: colors.flBorder)),
                ),
                child: InspectorDiffHunk(
                  hunk: hunks[i],
                  rows: shown[i].rows,
                  parts: parts[i],
                  onGapToggled: _toggleGap,
                  onExpand: readLines == null ? null : (gap, how) => unawaited(_expand(gap, how)),
                  reading: _reading,
                  layout: widget.layout,
                  pin: pin,
                  wordMarks: widget.wordMarks,
                  partPicked: widget.partPicked,
                  onPartToggled: widget.onPartToggled,
                  hotPart: _hot?.hunk == i ? _hot?.part : null,
                  onHotPart: (part) => setState(() => _hot = part == null ? null : (hunk: i, part: part)),
                  onLineMenu: widget.lineMenu == null ? null : _openLineMenu,
                ),
              ),
            const SizedBox(height: 4),
          ],
        );
        // Unified: one horizontal unit for the whole file, every line as wide as the widest.
        final Widget lines = unified
            ? SingleChildScrollView(
                controller: _horizontal,
                scrollDirection: Axis.horizontal,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minWidth: constraints.maxWidth),
                  child: IntrinsicWidth(child: all),
                ),
              )
            : all;
        final Widget? mode = widget.mode;
        Widget content = mode == null
            ? lines
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: <Widget>[mode, lines]);
        if (widget.bounded) {
          content = ZsScrollArea(
            controller: _vertical,
            horizontalController: unified ? _horizontal : null,
            identifier: 'inspector-diff-body',
            child: SingleChildScrollView(controller: _vertical, child: content),
          );
        } else if (unified) {
          content = ZsScrollArea(controller: _vertical, horizontalController: _horizontal, child: content);
        }
        if (widget.lineMenu == null) {
          return SelectionArea(child: content);
        }
        // The line menu replaces the selection's own right-click menu.
        return ZsMenuAnchor(
          controller: _menu,
          entries: _menuEntries,
          identifier: 'inspector-line-menu',
          maxWidth: inspectorMenuMaxWidth,
          cmdMaxWidth: inspectorMenuHintMaxWidth,
          // A right-click no line answers (a gap row) gets an empty menu: a null builder throws.
          builder: (context, _) => SelectionArea(contextMenuBuilder: (_, _) => const SizedBox.shrink(), child: content),
        );
      },
    );
  }
}

/// One hunk (DS components/content/DiffHunk): its color-words lines (Story 5.10), unified (a left and a right
/// line-number column) or side by side (two clipped cells per row, each with its number, whole lines rebuilt by
/// [pairSideBySide]), with no header (Story 10.43). Unified, the lines scroll sideways with the whole file ([pin]): the
/// numbers (and the part gutter) stay at the visible left edge, painted over the text on an opaque backing (the well
/// colour plus the line's fill) (Story 10.38, deferred-work I1). Story 10.32: a line's changed words carry
/// [DiffWordMarks] in both layouts.
///
/// Parts (Stories 10.38, 10.43; design calm-study.css): with [partPicked], every part of the hunk ([hunkPartOf], or
/// [parts]) gets one 13 px checkbox in a 22 px gutter before the numbers (side by side: leading the row), on the part's
/// first shown row; a (partly) picked part's rows carry a 2 px `--accent-line` edge on the gutter, and so do the rows of
/// the part whose box the pointer rests on ([hotPart]).
///
/// Story 10.41 (design `Whitespace Study.html`): it shows [rows] ([diffBlockRows]; [exactRows] without them). A
/// whitespace-only line shows with jj's marks, nothing is dimmed. Gap rows (Story 10.43, calm-study.css `.cs-gap`) are a
/// 26 px `--fl-hover` band: an empty gutter (but a fold's part checkbox), the arrow columns, the text in
/// `--text-faint`, then its button. A [DiffUnchangedRow] reads "N unchanged lines"; while the code pane is revealed
/// ([InspectorCheckReveal]) and [onExpand] is set, ↕ (at most [diffGapStep] lines) or ↓ (not on the top gap), ↑ (not
/// on the bottom gap) and Show all open its lines. A [DiffGapRow] has empty arrow columns and its Show / Hide pill
/// (while revealed); closed, a whitespace-only part's run is its hatched fold row, "⋯ N lines changed whitespace only"
/// with the same Show, and the part's checkbox in the gutter while picks are possible (open, the band, still hatched,
/// with the checkbox).
class InspectorDiffHunk extends StatelessWidget {
  /// [hunk] in [layout].
  const InspectorDiffHunk({
    required this.hunk,
    required this.layout,
    required this.pin,
    this.rows,
    this.parts,
    this.onGapToggled,
    this.onExpand,
    this.reading = const <int>{},
    this.wordMarks = true,
    this.partPicked,
    this.onPartToggled,
    this.hotPart,
    this.onHotPart,
    this.onLineMenu,
    super.key,
  });

  /// Opens part of an unchanged gap; null: gap rows show their count only.
  final void Function(DiffUnchangedRow gap, DiffGapExpand how)? onExpand;

  /// The unchanged gaps being read, by [DiffUnchangedRow.key]: their controls do nothing meanwhile.
  final Set<int> reading;

  /// The part whose checkbox the pointer rests on: its rows show the pick edge.
  final int? hotPart;

  /// Reports the part whose checkbox the pointer enters, and null when it leaves.
  final ValueChanged<int?>? onHotPart;

  /// A right-click on a line (Story 10.39): its new-side number ([diffNewLineOf]) and the pointer; null: none.
  final void Function(int line, Offset global)? onLineMenu;

  /// [child] answering a right-click as [line]'s, when there is a line menu.
  Widget _menuOn(HunkLine line, Widget child) {
    final void Function(int line, Offset global)? onLineMenu = this.onLineMenu;
    return onLineMenu == null
        ? child
        : GestureDetector(
            behavior: HitTestBehavior.opaque,
            onSecondaryTapUp: (details) => onLineMenu(diffNewLineOf(hunk, line), details.globalPosition),
            child: child,
          );
  }

  /// The hunk.
  final Hunk hunk;

  /// What it shows; null: every line as it is.
  final List<DiffRow>? rows;

  /// Its pickable parts ([DiffBlock.parts]), each one or more of its sections that pick together; null: one part per
  /// section.
  final List<List<HunkKey>>? parts;

  /// Opens or closes a gap, by its [DiffGapRow.key].
  final ValueChanged<int>? onGapToggled;

  /// The sections of [part].
  List<HunkKey> _sectionsOf(int part) => parts?[part] ?? <HunkKey>[hunk.sections[part]];

  int get _partCount => parts?.length ?? hunk.sections.length;

  /// [part]'s pick: all its sections, none, or null for some.
  bool? _partState(int part) {
    final List<HunkKey> keys = _sectionsOf(part);
    final int n = keys.where(partPicked!).length;
    return n == 0 ? false : (n == keys.length ? true : null);
  }

  /// Toggles [part] as a hunk toggles: all picked → none, else → all.
  void _togglePart(int part) {
    final bool pick = !(_partState(part) ?? false);
    for (final HunkKey key in _sectionsOf(part)) {
      if (partPicked!(key) != pick) {
        onPartToggled?.call(key);
      }
    }
  }

  List<DiffRow> get _rows => rows ?? exactRows(hunk);

  /// Whether rows lead with the part gutter: the hunk shows its parts, or a whitespace-only part takes a pick.
  bool _hasGutter(List<DiffRow> rows) =>
      _parts || (_foldPicks && rows.any((row) => row is DiffGapRow && row.part != null));

  /// Whether a folded row carries its part's checkbox.
  bool get _foldPicks => partPicked != null;

  /// Whether changed words inside a line get their fill ([InspectorDiffView.wordMarks]).
  final bool wordMarks;

  /// Unified or side by side.
  final DiffLayoutSetting layout;

  /// The file's number columns and, unified, its horizontal scroll.
  final DiffPin pin;

  /// Whether a part is picked; null: no part checkboxes.
  final bool Function(HunkKey part)? partPicked;

  /// Toggles a part's pick.
  final ValueChanged<HunkKey>? onPartToggled;

  /// The part gutter's width (design inspector-study.css:170).
  static const double _gutter = 22;

  /// The opaque base of every pinned backing: the well colour on the solid window fill, so no text scrolled beneath
  /// shows through in either theme.
  static Color _pinBase(ZsColors colors) => Color.alphaBlend(colors.codeBg, colors.flBgSolid);

  /// Whether the hunk shows its parts: picks are possible and it has any.
  bool get _parts => partPicked != null && _partCount > 0;

  /// [box] reporting the pointer resting on it as [part]'s hover (the rows of the part show the pick edge).
  Widget _hovering(int part, Widget box) => MouseRegion(
    onEnter: (_) => onHotPart?.call(part),
    onExit: (_) => onHotPart?.call(null),
    child: box,
  );

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return layout == DiffLayoutSetting.unified ? _unified(context, colors) : _sideBySide(context, colors);
  }

  /// [part]'s checkbox: three-state over its sections when they are tied ([parts]).
  Widget _partBox(BuildContext context, int part) {
    final AppLocalizations strings = context.l10n;
    final List<HunkKey> keys = _sectionsOf(part);
    final bool? on = _partState(part);
    // The part's 1-based lines on the new side; a pure deletion has none there, so its old side.
    final bool newSide = keys.any((key) => key.newCount > 0);
    final spans = <(int, int)>[
      for (final HunkKey key in keys)
        if (!newSide) (key.oldStart, key.oldCount) else if (key.newCount > 0) (key.newStart, key.newCount),
    ];
    final int start = spans.map((span) => span.$1).reduce(math.min);
    final int end = spans.map((span) => span.$1 + span.$2).reduce(math.max);
    final int count = spans.fold(0, (sum, span) => sum + span.$2);
    return Center(
      child: _hovering(
        part,
        InspectorCheck(
          value: on,
          child: ZsCheckbox(
            value: on,
            tristate: parts != null,
            onChanged: (_) => _togglePart(part),
            label: on ?? false
                ? strings.inspectorPartUnpick(count, start + 1, end)
                : strings.inspectorPartPick(count, start + 1, end),
            size: ZsCheckboxSize.sm,
            identifier: 'inspector-part-check',
          ),
        ),
      ),
    );
  }

  /// Whether a row of [part] carries the edge: a (partly) picked part's rows, and the rows of the part whose checkbox
  /// the pointer rests on — picked and hovered look the same.
  bool _edged(int? part) => part != null && partPicked != null && (part == hotPart || (_partState(part) ?? true));

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

  /// A line number right-aligned in the file's number column, outside the selection; blank for none.
  Widget _number(int? number, Color ink) => SizedBox(
    width: pin.numberWidth,
    child: SelectionContainer.disabled(
      child: Text(
        '${number ?? ''}'.padLeft(pin.digits),
        softWrap: false,
        textAlign: TextAlign.right,
        overflow: TextOverflow.clip,
        style: ZsType.code.copyWith(color: ink),
      ),
    ),
  );

  /// A whitespace-only [part]'s checkbox on its gap row; a pick opens the row.
  Widget _foldBox(BuildContext context, int part) {
    final bool? on = _partState(part);
    return Center(
      child: _hovering(
        part,
        InspectorCheck(
          value: on,
          child: ZsCheckbox(
            value: on,
            tristate: true,
            onChanged: (_) => _togglePart(part),
            label: on ?? false ? context.l10n.inspectorFoldUnpick : context.l10n.inspectorFoldPick,
            size: ZsCheckboxSize.sm,
            identifier: 'inspector-fold-check',
          ),
        ),
      ),
    );
  }

  /// A closed whitespace-only part's row content (design inspector-study.css `.isd-foldtxt`): its text, then the same
  /// on-demand Show as a plain gap row's.
  Widget _foldText(BuildContext context, DiffGapRow gap) =>
      _gapText(context, gap, text: context.l10n.inspectorFoldText(gap.count), showIdentifier: 'inspector-fold-show');

  /// The hatch behind a folded row: 135° lines every 6 px in `--fl-hover`.
  Widget _hatched(ZsColors colors, Widget child) =>
      CustomPaint(painter: _FoldHatchPainter(colors.flHover), child: child);

  /// A gap row's content (design whitespace-study.css `.wss-gaptxt`, `.isd-wstag`): its text in `--text-faint`, then,
  /// while [DiffGapRow.hideable], the pill button Show (closed) or Hide (open). A fold row passes its own [text] and
  /// its Show's [showIdentifier].
  Widget _gapText(
    BuildContext context,
    DiffGapRow gap, {
    String? text,
    String showIdentifier = 'inspector-gap-show',
  }) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final int count = gap.count;
    final String label = gap.open ? strings.inspectorGapHide : strings.inspectorGapShow;
    Widget pill({required bool hovered}) => Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: hovered ? colors.flOn : colors.flHover,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        softWrap: false,
        style: ZsType.secondary.copyWith(
          fontSize: 10.5,
          height: 16 / 10.5,
          color: hovered ? colors.text : colors.textDim,
        ),
      ),
    );
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(left: 18, right: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: <Widget>[
            Text(
              text ?? (gap.open ? strings.inspectorGapOpen(count) : strings.inspectorGapClosed(count)),
              key: const ValueKey<String>('inspector-gap-text'),
              softWrap: false,
              style: ZsType.secondary.copyWith(fontSize: 11.5, height: 22 / 11.5, color: colors.textFaint),
            ),
            if (gap.hideable)
              _onDemand(
                context,
                ZsTooltip(
                  message: gap.open ? strings.inspectorGapHideTooltip : strings.inspectorFoldShowTooltip,
                  child: _FlatButton(
                    identifier: gap.open ? 'inspector-gap-hide' : showIdentifier,
                    label: gap.open ? strings.inspectorGapHideLabel(count) : strings.inspectorGapShowLabel(count),
                    radius: 999,
                    onPressed: () => onGapToggled?.call(gap.key),
                    builder: (status) => pill(hovered: status.hovered),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// [child], a gap row's control, shown only while the code pane is revealed ([InspectorCheckReveal.revealedOf]).
  /// Hidden, only its opacity changes, as an [InspectorCheck]'s: no row shifts, VoiceOver and Tab still reach it.
  static Widget _onDemand(BuildContext context, Widget child) => AnimatedOpacity(
    key: const ValueKey<String>('inspector-gap-control'),
    opacity: InspectorCheckReveal.revealedOf(context) ? 1 : 0,
    duration: ZsMotion.of(context).durHover,
    alwaysIncludeSemantics: true,
    child: child,
  );

  /// The width of a gap row's arrow columns: [numbers], the number columns they stand over, and at least two arrow
  /// buttons wide when the diff can open gaps ([arrows]) — on every gap row of it, so their texts line up.
  static double _arrowWidth(double numbers, {required bool arrows}) => arrows ? math.max(numbers, 2 * 24 + 4) : numbers;

  /// An unchanged gap row's arrows (design calm-study.css `.cs-gnums`, `.cs-gbtn`): ↕ for a gap of at most
  /// [diffGapStep] lines, else ↓ (not on the top gap) and ↑ (not on the bottom gap); none without [onExpand].
  Widget _arrows(BuildContext context, DiffUnchangedRow gap) {
    final void Function(DiffUnchangedRow gap, DiffGapExpand how)? onExpand = this.onExpand;
    if (onExpand == null) {
      return const SizedBox.shrink();
    }
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final bool busy = reading.contains(gap.key);
    Widget arrow(String icon, String label, String identifier, DiffGapExpand how) => ZsTooltip(
      message: label,
      child: _FlatButton(
        identifier: identifier,
        label: label,
        radius: 5,
        onPressed: () {
          if (!busy) {
            onExpand(gap, how);
          }
        },
        builder: (status) => Container(
          width: 24,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: status.hovered ? colors.flOn : colors.flOn.withValues(alpha: 0),
            borderRadius: BorderRadius.circular(5),
          ),
          child: ZanshinIcon(icon, size: ZsIconSize.sm, color: status.hovered ? colors.text : colors.textDim),
        ),
      ),
    );
    final int count = gap.count;
    return _onDemand(
      context,
      SelectionContainer.disabled(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 4,
          children: count <= diffGapStep
              ? <Widget>[
                  arrow(
                    ZI.updown,
                    strings.inspectorUnchangedShow(count),
                    'inspector-unchanged-show',
                    DiffGapExpand.all,
                  ),
                ]
              : <Widget>[
                  if (!gap.top)
                    arrow(
                      ZI.chevronDown,
                      strings.inspectorUnchangedShowBelow(diffGapStep),
                      'inspector-unchanged-down',
                      DiffGapExpand.down,
                    ),
                  if (!gap.bottom)
                    arrow(
                      ZI.chevronUp,
                      strings.inspectorUnchangedShowAbove(diffGapStep),
                      'inspector-unchanged-up',
                      DiffGapExpand.up,
                    ),
                ],
        ),
      ),
    );
  }

  /// An unchanged gap row's text (design calm-study.css `.cs-gtxt`, `.cs-gall`): "N unchanged lines", then Show all
  /// for a gap of more than [diffGapStep] lines while [onExpand] is set.
  Widget _unchangedText(BuildContext context, DiffUnchangedRow gap) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final void Function(DiffUnchangedRow gap, DiffGapExpand how)? onExpand = this.onExpand;
    final bool busy = reading.contains(gap.key);
    final TextStyle style = ZsType.secondary.copyWith(fontSize: 11.5, height: 22 / 11.5);
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(left: 18, right: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 10,
          children: <Widget>[
            Text(
              strings.inspectorUnchangedLines(gap.count),
              key: const ValueKey<String>('inspector-unchanged-text'),
              softWrap: false,
              style: style.copyWith(color: colors.textFaint),
            ),
            if (onExpand != null && gap.count > diffGapStep)
              _onDemand(
                context,
                _FlatButton(
                  identifier: 'inspector-unchanged-all',
                  label: strings.inspectorUnchangedShowAll,
                  radius: 5,
                  onPressed: () {
                    if (!busy) {
                      onExpand(gap, DiffGapExpand.all);
                    }
                  },
                  builder: (status) => Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7),
                    decoration: BoxDecoration(
                      color: status.hovered ? colors.flOn : colors.flOn.withValues(alpha: 0),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Text(
                      strings.inspectorUnchangedShowAll,
                      softWrap: false,
                      style: style.copyWith(color: status.hovered ? colors.text : colors.textDim),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// A gap row's band (design calm-study.css `.cs-gap`): 26 px of `--fl-hover` between two faint lines.
  static BoxDecoration _band(ZsColors colors) => BoxDecoration(
    color: colors.flHover,
    border: Border.symmetric(
      horizontal: BorderSide(color: colors.flBorder.withValues(alpha: colors.flBorder.a * .6)),
    ),
  );

  /// The height of a gap row.
  static const double _gapHeight = 26;

  /// Whether [gap] shows as its part's hatched fold row: a closed whitespace-only part.
  static bool _folded(DiffGapRow gap) => gap.part != null && !gap.open;

  Widget _unified(BuildContext context, ZsColors colors) {
    final List<DiffRow> lines = _rows;
    final bool gutters = _hasGutter(lines);
    final shown = <int>{};
    // The pinned group: 10 padding, the gutter, the two number columns 8 apart, 8 before the text.
    final double pinWidth = 10 + (gutters ? _gutter : 0) + pin.numberWidth * 2 + 16;
    final Color none = colors.textMuted.withValues(alpha: 0);
    // The text runs under the pinned group, which paints after it on the well colour plus the line's fill.
    Widget row({
      required Color fill,
      required Widget text,
      required bool edge,
      int? left,
      int? right,
      Color? leftInk,
      Color? rightInk,
      Widget? gutter,
    }) => Stack(
      fit: StackFit.passthrough,
      children: <Widget>[
        Container(
          color: fill,
          padding: EdgeInsets.only(left: pinWidth, right: 10),
          child: text,
        ),
        Positioned(
          left: 0,
          top: 0,
          bottom: 0,
          width: pinWidth,
          child: _Pinned(
            controller: pin.horizontal,
            child: Container(
              key: const ValueKey<String>('inspector-line-pin'),
              color: Color.alphaBlend(fill, _pinBase(colors)),
              // Always a decoration, so a toggle keeps the subtree (and a focused part checkbox) in place.
              foregroundDecoration: BoxDecoration(
                border: edge ? Border(left: BorderSide(color: colors.accentLine, width: 2)) : null,
              ),
              child: Padding(
                padding: const EdgeInsets.only(left: 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (gutters) SizedBox(width: _gutter, child: gutter),
                    _number(left, leftInk ?? none),
                    const SizedBox(width: 8),
                    _number(right, rightInk ?? none),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
    // A gap row (calm-study.css `.cs-gap`): the band, then pinned the gutter (a fold's checkbox) and the arrow columns.
    Widget gapRow({
      required Widget text,
      required bool edge,
      Widget? gutter,
      Widget? arrows,
      bool fold = false,
      bool hatch = false,
    }) {
      final double arrowWidth = _arrowWidth(pin.numberWidth * 2 + 8, arrows: onExpand != null);
      final double gapPin = 10 + (gutters ? _gutter : 0) + arrowWidth;
      // A closed fold is its hatch alone, as before; every other gap row is the band.
      final Color fill = fold ? none : colors.flHover;
      final Widget band = Stack(
        fit: StackFit.passthrough,
        children: <Widget>[
          Container(
            height: _gapHeight,
            decoration: _band(colors).copyWith(color: fill),
            padding: EdgeInsets.only(left: gapPin, right: 10),
            alignment: Alignment.centerLeft,
            child: text,
          ),
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: gapPin,
            child: _Pinned(
              controller: pin.horizontal,
              child: Container(
                key: const ValueKey<String>('inspector-line-pin'),
                color: Color.alphaBlend(fill, _pinBase(colors)),
                foregroundDecoration: BoxDecoration(
                  border: edge ? Border(left: BorderSide(color: colors.accentLine, width: 2)) : null,
                ),
                // The opaque backing hides the row's hatch, so a fold row repeats it here (full width, as the DS draws).
                child: CustomPaint(
                  painter: hatch ? _FoldHatchPainter(colors.flHover) : null,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 10),
                    child: Row(
                      children: <Widget>[
                        if (gutters) SizedBox(width: _gutter, child: gutter),
                        SizedBox(
                          width: arrowWidth,
                          child: Center(child: arrows),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
      return hatch ? _hatched(colors, band) : band;
    }

    final rows = <Widget>[];
    for (final entry in lines) {
      if (entry is DiffUnchangedRow) {
        rows.add(
          KeyedSubtree(
            key: ValueKey<String>('inspector-unchanged-${entry.key}'),
            child: gapRow(
              text: _unchangedText(context, entry),
              edge: false,
              arrows: onExpand == null ? null : _arrows(context, entry),
            ),
          ),
        );
        continue;
      }
      if (entry is DiffGapRow) {
        final int? fold = entry.part;
        final Widget? box = fold != null && _foldPicks && shown.add(fold) ? _foldBox(context, fold) : null;
        rows.add(
          gapRow(
            text: _folded(entry) ? _foldText(context, entry) : _gapText(context, entry),
            edge: _edged(fold ?? entry.owner),
            gutter: box,
            fold: _folded(entry),
            hatch: fold != null,
          ),
        );
        continue;
      }
      final DiffLineRow(:HunkLine line) = entry as DiffLineRow;
      final _Look look = _look(colors, line.kind);
      final int? part = _parts ? entry.part : null;
      final bool edge = _edged(part);
      if (line.kind == HunkLineKind.conflictHeader) {
        // A dim full-width row without number columns, its text at 10.
        rows.add(
          Container(
            color: look.fill,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _lineText(colors, line, look.ink, wordMarks: wordMarks),
          ),
        );
        continue;
      }
      rows.add(
        _menuOn(
          line,
          row(
            fill: look.fill,
            text: _lineText(colors, line, look.ink, wordMarks: wordMarks),
            edge: edge,
            left: line.left,
            right: line.right,
            leftInk: look.left,
            rightInk: look.right,
            gutter: part != null && shown.add(part) ? _partBox(context, part) : null,
          ),
        ),
      );
      // Blank number columns put the marker where the line's text starts.
      if (!line.text.endsWith('\n')) {
        rows.add(row(fill: none, text: _noNewline(colors, EdgeInsets.zero), edge: edge));
      }
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }

  Widget _sideBySide(BuildContext context, ZsColors colors) {
    final List<DiffRow> entries = _rows;
    final bool gutters = _hasGutter(entries);
    final shown = <int>{};
    // A row's part: its line's (a rebuilt cell finds it by its number); a whitespace line's by either number.
    final partByLeft = <int, int>{};
    final partByRight = <int, int>{};
    for (final entry in entries) {
      if (entry case DiffLineRow(:final HunkLine line, :final int part)) {
        if (line.left case final int left) {
          partByLeft.putIfAbsent(left, () => part);
        }
        if (line.right case final int right) {
          partByRight.putIfAbsent(right, () => part);
        }
      }
    }
    int? partOf(HunkLine? line) => line == null ? null : (partByLeft[line.left] ?? partByRight[line.right]);
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
      // A cell is rebuilt (pairSideBySide): its side's number finds its line in the hunk.
      final HunkLine source = left
          ? hunk.lines.firstWhere((l) => l.left != null && l.left == line.left, orElse: () => line)
          : line;
      return _menuOn(
        source,
        Container(
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
                    _number(left ? line.left : line.right, left ? look.left : look.right),
                  Expanded(child: _lineText(colors, line, look.ink, wordMarks: wordMarks, cell: true)),
                ],
              ),
              if (!line.text.endsWith('\n')) _noNewline(colors, EdgeInsets.zero),
            ],
          ),
        ),
      );
    }

    // The gutter leading [content]: [box] in it; the edge when [part]'s lines carry it.
    Widget lead(Widget content, int? part, Widget? box) {
      if (!gutters) {
        return content;
      }
      // Always a decoration, so a toggle keeps the subtree (and a focused part checkbox) in place.
      return DecoratedBox(
        position: DecorationPosition.foreground,
        decoration: BoxDecoration(
          border: _edged(part) ? Border(left: BorderSide(color: colors.accentLine, width: 2)) : null,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(width: _gutter, color: colors.codeBg, child: box),
            Expanded(child: content),
          ],
        ),
      );
    }

    // A gap row spanning both sides (calm-study.css `.cs-gap`): the arrows over the left cell's numbers, then its text.
    Widget gapBand({required Widget text, required Color fill, Widget? arrows}) => Container(
      key: const ValueKey<String>('inspector-gap-band'),
      height: _gapHeight,
      decoration: _band(colors).copyWith(color: fill),
      padding: const EdgeInsets.only(left: 8),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _arrowWidth(pin.numberWidth, arrows: onExpand != null),
            child: Center(child: arrows),
          ),
          Flexible(child: text),
        ],
      ),
    );

    final rows = <Widget>[];
    var run = <HunkLine>[];
    void flush() {
      for (final (HunkLine? left, HunkLine? right) in pairSideBySide(run)) {
        final bool header = left != null && left.kind == HunkLineKind.conflictHeader;
        final Widget content = header
            ? cell(left, left: false)
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(child: cell(left, left: true)),
                  Expanded(child: cell(right, left: false)),
                ],
              );
        final int? part = !_parts || header ? null : partOf(left) ?? partOf(right);
        rows.add(
          IntrinsicHeight(child: lead(content, part, part != null && shown.add(part) ? _partBox(context, part) : null)),
        );
      }
      run = <HunkLine>[];
    }

    for (final entry in entries) {
      switch (entry) {
        case DiffLineRow(:final HunkLine line):
          run.add(line);
        case DiffGapRow(part: final int? fold):
          flush();
          final Widget? box = fold != null && _foldPicks && shown.add(fold) ? _foldBox(context, fold) : null;
          final bool folded = _folded(entry);
          final Widget band = gapBand(
            text: folded ? _foldText(context, entry) : _gapText(context, entry),
            fill: folded ? colors.flHover.withValues(alpha: 0) : colors.flHover,
          );
          rows.add(
            IntrinsicHeight(child: lead(fold != null ? _hatched(colors, band) : band, fold ?? entry.owner, box)),
          );
        case DiffUnchangedRow():
          flush();
          rows.add(
            IntrinsicHeight(
              key: ValueKey<String>('inspector-unchanged-${entry.key}'),
              child: lead(
                gapBand(
                  text: _unchangedText(context, entry),
                  fill: colors.flHover,
                  arrows: onExpand == null ? null : _arrows(context, entry),
                ),
                null,
                null,
              ),
            ),
          );
      }
    }
    flush();
    return Column(
      key: const ValueKey<String>('inspector-diff-split'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}
