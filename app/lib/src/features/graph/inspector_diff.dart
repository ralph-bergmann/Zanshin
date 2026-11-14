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
import 'inspector_path_label.dart';
import 'project_files.dart' show announceCopied;

/// [hunk]'s range in git's notation, `@@ −l,n +r,m @@` with U+2212 for the minus — the color-words format has no
/// header of its own, so Zanshin labels each hunk this way: a line number is the range's 1-based start, or its 0-based
/// start when it is empty (jj's `to_line_number`, cli/src/diff_util.rs @ v0.47.0), the count its length.
String hunkHeader(Hunk hunk) {
  int line(({int start, int end}) range) => range.end > range.start ? range.start + 1 : range.start;
  final ({int start, int end}) l = hunk.before;
  final ({int start, int end}) r = hunk.after;
  return '@@ −${line(l)},${l.end - l.start} +${line(r)},${r.end - r.start} @@'; // l10n-ignore: jj's hunk header
}

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
  bool inside(int? number, int start, int count) => number != null && number - 1 >= start && number - 1 < start + count;
  for (var i = 0; i < sections.length; i++) {
    final HunkKey s = sections[i];
    if (inside(line.left, s.oldStart, s.oldCount) || inside(line.right, s.newStart, s.newCount)) {
      return i;
    }
  }
  return null;
}

/// [hunk]'s lines' parts ([hunkPartOf]), in line order.
List<int?> hunkLineParts(Hunk hunk) => <int?>[for (final HunkLine line in hunk.lines) hunkPartOf(hunk.sections, line)];

/// The diff read's whitespace mode for [setting] (Story 10.33).
DiffWhitespace diffWhitespaceOf(DiffWhitespaceSetting setting) => switch (setting) {
  DiffWhitespaceSetting.showAll => DiffWhitespace.exact,
  DiffWhitespaceSetting.ignoreChangesInAmount => DiffWhitespace.ignoreSpaceChange,
  DiffWhitespaceSetting.ignoreAll => DiffWhitespace.ignoreAllSpace,
};

bool _isChange(HunkLine line) =>
    line.kind == HunkLineKind.removed || line.kind == HunkLineKind.added || line.kind == HunkLineKind.changed;

/// What the read at `-b` / `-w` says about one file (Story 10.33): the left and right numbers of its changed lines and
/// its context lines by right number. Only numbers are matched; Rust stays the only place that compares lines.
@immutable
class IgnoredLines {
  /// The lines of [diff], the file as the ignoring read lists it; none when it does not list the file.
  factory IgnoredLines.of(FileDiff? diff) {
    final left = <int>{};
    final right = <int>{};
    final context = <int, HunkLine>{};
    for (final Hunk hunk in diff?.hunks ?? const <Hunk>[]) {
      for (final HunkLine line in hunk.lines) {
        if (_isChange(line)) {
          left.addAll(<int>[?line.left]);
          right.addAll(<int>[?line.right]);
        } else if (line.kind == HunkLineKind.context && line.right != null) {
          context[line.right!] = line;
        }
      }
    }
    return IgnoredLines._(left, right, context);
  }

  const IgnoredLines._(this.left, this.right, this.context);

  /// The left numbers of the changed lines.
  final Set<int> left;

  /// The right numbers of the changed lines.
  final Set<int> right;

  /// The context lines, by right number.
  final Map<int, HunkLine> context;

  /// Whether the changed [line] of the exact read changed only in whitespace: neither of its numbers changed here.
  bool whitespaceOnly(HunkLine line) => !left.contains(line.left) && !right.contains(line.right);
}

/// One row a hunk shows (Story 10.33): a line, or a part folded into one row.
sealed class DiffRow {
  const DiffRow();
}

/// A line of a hunk: its [part] ([hunkPartOf]) and whether it changed only in whitespace and shows because its part
/// is picked or opened ([whitespaceOnly]: dimmed).
final class DiffLineRow extends DiffRow {
  /// A row showing [line].
  const DiffLineRow(this.line, {this.part, this.whitespaceOnly = false});

  /// The line.
  final HunkLine line;

  /// The index of its part in the hunk's sections; null for none.
  final int? part;

  /// Whether it changed only in whitespace.
  final bool whitespaceOnly;
}

/// A part made only of whitespace changes, neither picked nor opened, folded into one row.
final class DiffFoldRow extends DiffRow {
  /// The fold of [part]'s [lines].
  const DiffFoldRow(this.part, this.lines);

  /// The index of the part in the hunk's sections.
  final int part;

  /// The folded lines.
  final List<HunkLine> lines;

  /// The larger of the lines' distinct left and right numbers' counts.
  int get count => math.max(
    <int>{for (final HunkLine line in lines) ?line.left}.length,
    <int>{for (final HunkLine line in lines) ?line.right}.length,
  );
}

/// The rows [hunk] (the exact read's) shows (Story 10.33). Without [ignored] every line as it is. With it, a changed
/// line [IgnoredLines.whitespaceOnly] shows dimmed when its part is in [revealed] (picked or opened); a part of only
/// such lines folds into one [DiffFoldRow]; any other such line gives way to the ignoring read's context line with its
/// right number (once), else to nothing — what `jj diff -w` shows there. Null when only context lines are left: the
/// hunk goes.
List<DiffRow>? whitespaceRows(Hunk hunk, IgnoredLines? ignored, {Set<HunkKey> revealed = const <HunkKey>{}}) {
  final List<int?> parts = hunkLineParts(hunk);
  if (ignored == null) {
    return <DiffRow>[for (var i = 0; i < hunk.lines.length; i++) DiffLineRow(hunk.lines[i], part: parts[i])];
  }
  bool whitespaceOnly(HunkLine line) => _isChange(line) && ignored.whitespaceOnly(line);
  // The parts with a real change: their whitespace-only lines never fold.
  final mixed = <int>{
    for (var i = 0; i < hunk.lines.length; i++)
      if (parts[i] case final int part when _isChange(hunk.lines[i]) && !whitespaceOnly(hunk.lines[i])) part,
  };
  final rows = <DiffRow>[];
  final substituted = <int>{};
  for (var i = 0; i < hunk.lines.length; i++) {
    final HunkLine line = hunk.lines[i];
    final int? part = parts[i];
    if (!whitespaceOnly(line)) {
      rows.add(DiffLineRow(line, part: part));
    } else if (part != null && revealed.contains(hunk.sections[part])) {
      rows.add(DiffLineRow(line, part: part, whitespaceOnly: true));
    } else if (part != null && !mixed.contains(part)) {
      if (rows.lastOrNull case DiffFoldRow(part: final int last, :final List<HunkLine> lines) when last == part) {
        lines.add(line);
      } else {
        rows.add(DiffFoldRow(part, <HunkLine>[line]));
      }
    } else if (ignored.context[line.right] case final HunkLine context when substituted.add(line.right!)) {
      rows.add(DiffLineRow(context));
    }
  }
  final bool changes = rows.any((row) => row is DiffFoldRow || (row is DiffLineRow && _isChange(row.line)));
  return changes ? rows : null;
}

/// The diff options menu's rows (Story 10.33, design `inspector-study.jsx`): Whitespace — show all (`jj diff`),
/// ignore changes in amount (`-b`), ignore all (`-w`); Context lines — 0, 1, 2, 3 ("jj's default"), 5, 10, 20 plus
/// [contextLines] in order when it is off that list, none checked when null (jj cannot read it); then the note.
List<ZsMenuEntry> diffOptionsEntries(
  AppLocalizations strings, {
  required DiffWhitespaceSetting whitespace,
  required ValueChanged<DiffWhitespaceSetting> onWhitespaceChanged,
  required int? contextLines,
  required ValueChanged<int>? onContextLinesChanged,
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
/// scroll, the visible width, and the number columns' digits and width (the file's largest number).
@immutable
class DiffPin {
  /// The pin of one file's unified lines.
  const DiffPin({required this.horizontal, required this.viewport, required this.digits, required this.numberWidth});

  /// The file's horizontal scroll; null when the lines do not scroll (nothing moves).
  final ScrollController? horizontal;

  /// The visible width: the hunk header's width.
  final double viewport;

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
/// toggle and nothing folds (Story 10.29's operation view). With [hunkPicked] each hunk with sections gets a checkbox,
/// with [modePicked] the mode-change note does (Story 10.26); without them there is none. With [partPicked] a hunk of
/// more than one part gets a checkbox per part (Story 10.38). With [onWhitespaceChanged] the bar ends in the diff
/// options menu (Story 10.33): whitespace and context lines; with [ignored] the hunks show [whitespaceRows], and a file
/// left with none reads "Only whitespace changed in this file."
///
/// Story 10.39: the bar's path shows the name first and its folder dimmed; with [copyPath] a click copies the absolute
/// path. With [lineMenu] a right-click on a line (either layout) opens its context menu in place of the selection's.
///
/// **Scrolling** (Story 10.38). The unified lines of the whole file scroll sideways as one unit, every line as wide as
/// the widest; the number columns and the hunk headers stay in view ([DiffPin]). With a bounded height (the inspector)
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
    this.hunkPicked,
    this.onHunkToggled,
    this.partPicked,
    this.onPartToggled,
    this.modePicked,
    this.onModeToggled,
    this.whitespace = DiffWhitespaceSetting.showAll,
    this.onWhitespaceChanged,
    this.ignored,
    this.contextLines,
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

  /// What the read at the whitespace mode says about the file; null shows the exact lines ([whitespaceRows]).
  final IgnoredLines? ignored;

  /// `diff.color-words.context`, which the menu checks; null when jj cannot read it.
  final int? contextLines;

  /// Writes `diff.color-words.context` at user scope.
  final ValueChanged<int>? onContextLinesChanged;

  /// A hunk's pick state (all, none, null for mixed); null: no hunk checkboxes.
  final bool? Function(Hunk hunk)? hunkPicked;

  /// Toggles a hunk's pick.
  final ValueChanged<Hunk>? onHunkToggled;

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
          : _DiffBody(
              // A new file starts at the top and the left; its opened parts reset with the file and the mode.
              key: ValueKey<(String, DiffWhitespaceSetting)>((path, whitespace)),
              diff: diff,
              ignored: ignored,
              mode: diff.modeChange ? mode : null,
              layout: layout,
              wordMarks: wordMarks,
              bounded: bounded,
              hunkPicked: hunkPicked,
              onHunkToggled: onHunkToggled,
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
    required this.ignored,
    required this.mode,
    required this.layout,
    required this.wordMarks,
    required this.bounded,
    required this.hunkPicked,
    required this.onHunkToggled,
    required this.partPicked,
    required this.onPartToggled,
    required this.lineMenu,
    super.key,
  });

  final FileDiff diff;
  final IgnoredLines? ignored;
  final Widget? mode;
  final DiffLayoutSetting layout;
  final bool wordMarks;
  final bool bounded;
  final bool? Function(Hunk hunk)? hunkPicked;
  final ValueChanged<Hunk>? onHunkToggled;
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

  // The whitespace-only parts the user opened (Story 10.33); the key resets them with the file and the mode.
  final _opened = <HunkKey>{};

  void _toggleOpened(HunkKey part) => setState(() => _opened.remove(part) || _opened.add(part));

  @override
  void dispose() {
    _vertical.dispose();
    _horizontal.dispose();
    super.dispose();
  }

  /// The number columns' width in digits: the file's largest number's, so every hunk's numbers line up.
  int get _digits {
    var largest = 0;
    for (final Hunk hunk in widget.diff.hunks) {
      for (final HunkLine line in hunk.lines) {
        largest = math.max(largest, math.max(line.left ?? 0, line.right ?? 0));
      }
    }
    return '$largest'.length;
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final unified = widget.layout == DiffLayoutSetting.unified;
    final bool? Function(Hunk hunk)? hunkPicked = widget.hunkPicked;
    final bool Function(HunkKey part)? partPicked = widget.partPicked;
    final hunks = <Hunk>[];
    final shown = <List<DiffRow>>[];
    for (final Hunk hunk in widget.diff.hunks) {
      final List<DiffRow>? rows = whitespaceRows(
        hunk,
        widget.ignored,
        revealed: <HunkKey>{
          for (final HunkKey part in hunk.sections)
            if (_opened.contains(part) || (partPicked?.call(part) ?? false)) part,
        },
      );
      if (rows != null) {
        hunks.add(hunk);
        shown.add(rows);
      }
    }
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
          viewport: constraints.maxWidth,
          digits: digits,
          numberWidth: numberWidth,
        );
        final Widget all = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (var i = 0; i < hunks.length; i++)
              DecoratedBox(
                decoration: BoxDecoration(
                  border: i == 0 ? null : Border(top: BorderSide(color: colors.flBorder)),
                ),
                child: InspectorDiffHunk(
                  hunk: hunks[i],
                  rows: shown[i],
                  opened: _opened,
                  onOpenToggled: _toggleOpened,
                  layout: widget.layout,
                  pin: pin,
                  wordMarks: widget.wordMarks,
                  selectable: hunkPicked != null && hunks[i].sections.isNotEmpty,
                  picked: hunkPicked == null ? false : hunkPicked(hunks[i]),
                  onToggle: () => widget.onHunkToggled?.call(hunks[i]),
                  partPicked: widget.partPicked,
                  onPartToggled: widget.onPartToggled,
                  onLineMenu: widget.lineMenu == null ? null : _openLineMenu,
                ),
              ),
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
          builder: (context, _) => SelectionArea(contextMenuBuilder: null, child: content),
        );
      },
    );
  }
}

/// One hunk (DS components/content/DiffHunk, content.css:48-55): the header band (`--hunk-bg`: the range in
/// `--hunk`, the symbol, +added / −removed) over its color-words lines (Story 5.10), unified (a left and a right
/// line-number column) or side by side (two clipped cells per row, each with its number, whole lines rebuilt by
/// [pairSideBySide]). Unified, the lines scroll sideways with the whole file ([pin]): the numbers (and the part gutter)
/// stay at the visible left edge, painted over the text on an opaque backing (the well colour plus the line's fill),
/// and the header is as wide as the visible area and stays in view (Story 10.38, deferred-work I1).
///
/// Story 10.26 (DS DiffHunk.prompt.md:8-11, content.css:58-59): a [selectable] hunk leads its header with a tristate
/// checkbox (its Tab stop, Space toggles); all picked puts the header on `--accent-soft-hi` with `--text`, some on
/// `--accent` at 12 %; a picked hunk's lines carry a 2 px `--accent-line` edge. Story 10.32: a line's changed words
/// carry [DiffWordMarks] in both layouts.
///
/// Story 10.38 (DESIGN-SYSTEM-SYNC #26): with [partPicked], a selectable hunk of more than one part ([hunkPartOf])
/// shows "N parts" in its header and a 22 px gutter before its numbers (side by side: leading the row) with a 13 px
/// checkbox on each part's first line; then only a picked part's lines carry the edge.
///
/// Story 10.33 (DESIGN-SYSTEM-SYNC #26): it shows [rows] ([whitespaceRows]). A whitespace-only line shows its text at
/// .62; unified, one with a right number carries the pill "whitespace only" — a button "whitespace only · Hide" while
/// its part is only opened. A folded part is one hatched row, "⋯ N lines changed whitespace only · Show", full width,
/// with the part's checkbox in the gutter while picks are possible.
class InspectorDiffHunk extends StatelessWidget {
  /// [hunk] in [layout].
  const InspectorDiffHunk({
    required this.hunk,
    required this.layout,
    required this.pin,
    this.rows,
    this.opened = const <HunkKey>{},
    this.onOpenToggled,
    this.wordMarks = true,
    this.selectable = false,
    this.picked = false,
    this.onToggle,
    this.partPicked,
    this.onPartToggled,
    this.onLineMenu,
    super.key,
  });

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

  /// The whitespace-only parts the user opened.
  final Set<HunkKey> opened;

  /// Opens or folds a whitespace-only part.
  final ValueChanged<HunkKey>? onOpenToggled;

  List<DiffRow> get _rows => rows ?? whitespaceRows(hunk, null)!;

  /// Whether rows lead with the part gutter: the hunk shows its parts, or a folded part takes a pick.
  bool _hasGutter(List<DiffRow> rows) => _parts || (_foldPicks && rows.any((row) => row is DiffFoldRow));

  /// Whether a folded row carries its part's checkbox.
  bool get _foldPicks => selectable && partPicked != null;

  /// Whether changed words inside a line get their fill ([InspectorDiffView.wordMarks]).
  final bool wordMarks;

  /// Unified or side by side.
  final DiffLayoutSetting layout;

  /// The file's number columns and, unified, its horizontal scroll.
  final DiffPin pin;

  /// Whether the header has a checkbox.
  final bool selectable;

  /// Its pick: all, none, or null for some of its sections.
  final bool? picked;

  /// Toggles [picked].
  final VoidCallback? onToggle;

  /// Whether a part is picked; null: no part checkboxes.
  final bool Function(HunkKey part)? partPicked;

  /// Toggles a part's pick.
  final ValueChanged<HunkKey>? onPartToggled;

  /// The part gutter's width (design inspector-study.css:170).
  static const double _gutter = 22;

  /// Whether the hunk shows its parts.
  bool get _parts => selectable && partPicked != null && hunk.sections.length > 1;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final AppLocalizations strings = context.l10n;
    final TextStyle head = ZsType.id.copyWith(fontSize: ZsType.fsSm);
    final String? symbol = hunk.symbol;
    final bool chosen = picked ?? true;
    final bool parts = _parts;
    final unified = layout == DiffLayoutSetting.unified;
    Widget header = Container(
      key: const ValueKey<String>('inspector-hunk-header'),
      constraints: const BoxConstraints(minHeight: 30),
      padding: const EdgeInsets.symmetric(horizontal: 10),
      color: switch (picked) {
        true => colors.accentSoftHi,
        null => Color.alphaBlend(colors.accent.withValues(alpha: .12), colors.codeBg),
        false => colors.hunkBg,
      },
      child: Row(
        spacing: 8,
        children: <Widget>[
          if (selectable)
            ZsCheckbox(
              value: picked,
              tristate: true,
              onChanged: (_) => onToggle?.call(),
              label: strings.inspectorHunkCheck(hunkHeader(hunk)),
              size: ZsCheckboxSize.sm,
              identifier: 'inspector-hunk-check',
            ),
          Text(hunkHeader(hunk), style: head.copyWith(color: chosen ? colors.text : colors.hunk)),
          if (parts)
            Container(
              key: const ValueKey<String>('inspector-hunk-parts'),
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 1),
              decoration: BoxDecoration(color: colors.flHover, borderRadius: BorderRadius.circular(999)),
              child: Text(
                strings.inspectorHunkParts(hunk.sections.length),
                style: ZsType.secondary.copyWith(fontSize: 10.5, color: colors.textDim),
              ),
            ),
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
          if (hunk.added > 0) Text('+${hunk.added}', style: head.copyWith(color: colors.add)), // l10n-ignore: a count
          if (hunk.removed > 0)
            Text('−${hunk.removed}', style: head.copyWith(color: colors.rem)), // l10n-ignore: a count
        ],
      ),
    );
    if (unified) {
      header = Align(
        alignment: Alignment.centerLeft,
        child: _Pinned(
          controller: pin.horizontal,
          child: SizedBox(width: pin.viewport, child: header),
        ),
      );
    }
    final Widget lines = unified ? _unified(context, colors) : _sideBySide(context, colors);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        header,
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          // Unified lines and rows with a gutter draw their edge per line; side by side the whole hunk's.
          child: unified || _hasGutter(_rows)
              ? lines
              : DecoratedBox(
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

  /// [part]'s checkbox.
  Widget _partBox(BuildContext context, int part) {
    final AppLocalizations strings = context.l10n;
    final HunkKey key = hunk.sections[part];
    final bool on = partPicked!(key);
    // The part's 1-based lines on the new side; a pure deletion has none there, so its old side.
    final (int start, int count) = key.newCount > 0 ? (key.newStart, key.newCount) : (key.oldStart, key.oldCount);
    final int end = start + count;
    return Center(
      child: ZsCheckbox(
        value: on,
        onChanged: (_) => onPartToggled?.call(key),
        label: on
            ? strings.inspectorPartUnpick(count, start + 1, end)
            : strings.inspectorPartPick(count, start + 1, end),
        size: ZsCheckboxSize.sm,
        identifier: 'inspector-part-check',
      ),
    );
  }

  /// Whether a line of [part] carries the edge: with parts, a picked part's lines; else every line of a picked hunk.
  bool _edged(int? part) => _parts ? part != null && partPicked!(hunk.sections[part]) : (picked ?? true);

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

  /// [part]'s checkbox on its folded row; a picked part never folds, so it is always unchecked and a pick opens the row.
  Widget _foldBox(BuildContext context, int part) {
    final HunkKey key = hunk.sections[part];
    return Center(
      child: ZsCheckbox(
        value: false,
        onChanged: (_) => onPartToggled?.call(key),
        label: context.l10n.inspectorFoldPick,
        size: ZsCheckboxSize.sm,
        identifier: 'inspector-fold-check',
      ),
    );
  }

  /// A folded part's row content: its text button, which opens it (design inspector-study.css `.isd-foldtxt`).
  Widget _foldText(BuildContext context, DiffFoldRow fold) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final String text = strings.inspectorFoldText(fold.count);
    return ZsTooltip(
      message: strings.inspectorFoldShowTooltip,
      child: SelectionContainer.disabled(
        child: _FlatButton(
          identifier: 'inspector-fold-show',
          label: text,
          onPressed: () => onOpenToggled?.call(hunk.sections[fold.part]),
          builder: (status) => Padding(
            padding: const EdgeInsets.fromLTRB(18, 0, 12, 0),
            child: Text(
              text,
              softWrap: false,
              style: ZsType.secondary.copyWith(
                fontSize: 11.5,
                height: 22 / 11.5,
                color: status.hovered ? colors.text : colors.textDim,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The hatch behind a folded row: 135° lines every 6 px in `--fl-hover`.
  Widget _hatched(ZsColors colors, Widget child) =>
      CustomPaint(painter: _FoldHatchPainter(colors.flHover), child: child);

  /// A whitespace-only line's text at .62.
  static Widget _dimmed(Widget text, {required bool dim}) => dim ? Opacity(opacity: .62, child: text) : text;

  /// The pill after a whitespace-only line with a right number (unified only): "whitespace only" while its part is
  /// picked, else the button "whitespace only · Hide" that folds the opened part again.
  Widget _tag(BuildContext context, HunkKey part) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    Widget pill(String text, {bool hovered = false}) => Container(
      margin: const EdgeInsets.only(left: 12),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: hovered ? colors.flOn : colors.flHover,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        softWrap: false,
        style: ZsType.secondary.copyWith(
          fontSize: 10.5,
          height: 16 / 10.5,
          color: hovered ? colors.text : colors.textDim,
        ),
      ),
    );
    final Widget tag = (partPicked?.call(part) ?? false)
        ? ZsTooltip(
            message: strings.inspectorWhitespaceOnlyTooltip,
            child: pill(strings.inspectorWhitespaceOnly),
          )
        : ZsTooltip(
            message: strings.inspectorWhitespaceHideTooltip,
            child: _FlatButton(
              identifier: 'inspector-whitespace-hide',
              label: strings.inspectorWhitespaceOnlyHide,
              radius: 999,
              onPressed: () => onOpenToggled?.call(part),
              builder: (status) => pill(strings.inspectorWhitespaceOnlyHide, hovered: status.hovered),
            ),
          );
    return SelectionContainer.disabled(child: tag);
  }

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
              padding: const EdgeInsets.only(left: 10),
              color: Color.alphaBlend(fill, colors.codeBg),
              // Always a decoration, so a toggle keeps the subtree (and a focused part checkbox) in place.
              foregroundDecoration: BoxDecoration(
                border: edge ? Border(left: BorderSide(color: colors.accentLine, width: 2)) : null,
              ),
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
      ],
    );
    final rows = <Widget>[];
    for (final entry in lines) {
      if (entry is DiffFoldRow) {
        shown.add(entry.part);
        rows.add(
          _hatched(
            colors,
            row(
              fill: none,
              text: Align(alignment: Alignment.centerLeft, child: _foldText(context, entry)),
              edge: _edged(entry.part),
              gutter: _foldPicks ? _foldBox(context, entry.part) : null,
            ),
          ),
        );
        continue;
      }
      final DiffLineRow(:HunkLine line, :bool whitespaceOnly) = entry as DiffLineRow;
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
      final Widget text = _dimmed(_lineText(colors, line, look.ink, wordMarks: wordMarks), dim: whitespaceOnly);
      final int? own = entry.part;
      rows.add(
        _menuOn(
          line,
          row(
            fill: look.fill,
            text: whitespaceOnly && own != null && line.right != null
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[text, _tag(context, hunk.sections[own])],
                  )
                : text,
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
    // The whitespace-only lines' numbers: their cells show dimmed.
    final dimLeft = <int>{};
    final dimRight = <int>{};
    for (final entry in entries) {
      if (entry case DiffLineRow(whitespaceOnly: true, :final HunkLine line)) {
        dimLeft.addAll(<int>[?line.left]);
        dimRight.addAll(<int>[?line.right]);
      }
    }
    int? partOf(HunkLine? line) => line == null ? null : hunkPartOf(hunk.sections, line);
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
                  Expanded(
                    child: _dimmed(
                      _lineText(colors, line, look.ink, wordMarks: wordMarks, cell: true),
                      dim:
                          line.kind != HunkLineKind.context &&
                          (left ? dimLeft : dimRight).contains(left ? line.left : line.right),
                    ),
                  ),
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
        case DiffFoldRow(:final int part):
          flush();
          shown.add(part);
          rows.add(
            IntrinsicHeight(
              child: lead(
                _hatched(colors, Align(alignment: Alignment.centerLeft, child: _foldText(context, entry))),
                part,
                _foldPicks ? _foldBox(context, part) : null,
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
