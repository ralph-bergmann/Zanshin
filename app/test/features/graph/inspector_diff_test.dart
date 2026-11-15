// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_check_reveal.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting, DiffWhitespaceSetting;
import 'package:zanshin_ui/zanshin_ui.dart'
    show
        ZI,
        ZanshinIcon,
        ZsAppearance,
        ZsCheckbox,
        ZsColors,
        ZsMenuButton,
        ZsMenuEntry,
        ZsMenuHeader,
        ZsMenuItem,
        ZsMenuNote,
        ZsMenuSeparator,
        ZsScrollArea,
        ZsTheme;

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';
import '../../helpers/word_marks.dart';

/// A line in `hunks.rs`' test notation of the color-words lines: a kind (` ` context, `-` removed, `+` added, `~`
/// changed, `#` conflict header), the left and the right number right-aligned in four columns (blank for none), `|`,
/// then the text with `[-…-]` around a removed run and `{+…+}` around an added one. The line's `\n` is an equal run
/// (it joins a last equal run) unless the text spells its `\n` out; [newline] false leaves it out.
HunkLine _line(String spec, {bool newline = true}) {
  final HunkLineKind kind = switch (spec[0]) {
    '-' => HunkLineKind.removed,
    '+' => HunkLineKind.added,
    '~' => HunkLineKind.changed,
    '#' => HunkLineKind.conflictHeader,
    _ => HunkLineKind.context,
  };
  int? number(String digits) => digits.trim().isEmpty ? null : int.parse(digits.trim());
  final String body = spec.substring(spec.indexOf('|') + 1);
  final segments = <Segment>[];
  for (final RegExpMatch match in RegExp(r'\[-([\s\S]*?)-\]|\{\+([\s\S]*?)\+\}|([^\[{]+|[\[{])').allMatches(body)) {
    final (SegmentKind segmentKind, String text) = match[1] != null
        ? (SegmentKind.removed, match[1]!)
        : match[2] != null
        ? (SegmentKind.added, match[2]!)
        : (SegmentKind.equal, match[3]!);
    if (segments.isNotEmpty && segments.last.kind == segmentKind) {
      segments.last = Segment(kind: segmentKind, text: segments.last.text + text);
    } else {
      segments.add(Segment(kind: segmentKind, text: text));
    }
  }
  if (newline && !body.contains('\n')) {
    segments.isEmpty || segments.last.kind != SegmentKind.equal
        ? segments.add(const Segment(kind: SegmentKind.equal, text: '\n'))
        : segments.last = Segment(kind: SegmentKind.equal, text: '${segments.last.text}\n');
  }
  return HunkLine(
    kind: kind,
    text: segments.map((s) => s.text).join(),
    segments: segments,
    left: kind == HunkLineKind.conflictHeader ? null : number(spec.substring(1, 5)),
    right: kind == HunkLineKind.conflictHeader ? null : number(spec.substring(6, 10)),
  );
}

// Ralph's jj example (commit 671e4eaca, lib/src/git.rs) as the pinned CLI prints it (`hunks.rs`' witness).
const _jj = <String>[
  ' 2453 2453|        .into_inner()',
  '~2454 2454|        .map_err(|err| {+{\n+}',
  '+     2455|{+            let (source, out) = err.into_parts();+}',
  '+     2456|{+            let path = out.get_ref().lock_path().to_owned();+}',
  '+     2457|{+            PathError { path, source }+}',
  '+     2458|{+        })+}',
  '~2454 2459|{+        .map_err(+}GitResetHeadError::from_git[-(err.into_error())-])?;',
  ' 2455 2460|    lock.commit()',
];

// The stepper.dart edits (10.32's demo data) and Ralph's widget-test block over the inline limit.
const _stepper = <String>[
  '~  12   12|    child: Text(isLastStep ? [-s.functionWizard_save-]{+saveLabel+} : s.functionWizard_next),',
  '~  42   44|  {+// Small side padding.+}',
  '~  42   45|{+  +}padding: Spacing.[-spacing8-]{+spacing2+},',
];
const _block = <String>[
  '-   9     |  [-// The-] phone [-layout-] on a [-device.-]',
  '-  10     |[-  testWidgets(\'shows Funktion speichern-]\', (tester) async {',
  '+        8|  // {+The+} {+tablet shows the long label.+}',
  '+        9|{+    await fillGeneralStep(tester);+}',
];

Hunk _hunk(List<HunkLine> lines, {({int start, int end}) before = (start: 4, end: 7), String? symbol}) => Hunk(
  before: before,
  after: (start: 4, end: 6),
  symbol: symbol,
  sections: const [],
  removed: lines.where((l) => l.kind == HunkLineKind.removed).length,
  added: lines.where((l) => l.kind == HunkLineKind.added).length,
  lines: lines,
);

FileDiff _file({
  List<Hunk> hunks = const <Hunk>[],
  bool binary = false,
  bool modeChange = false,
  String fingerprint = 'f',
}) => FileDiff(
  path: 'src/main.rs',
  kind: FileChangeKind.modified,
  fromPath: null,
  binary: binary,
  modeChange: modeChange,
  sections: const [],
  hunks: hunks,
  removed: 0,
  added: 0,
  fingerprint: fingerprint,
);

// Ralph's `text_field.dart` (Story 10.41): a `TextField` wrapped in `Semantics(`, as the pinned CLI prints it — old
// lines 6-32 without their six spaces of indentation.
const _textFieldFields = <String>[
  'controller: controller,',
  'enabled: enabled,',
  'style: textStyle,',
  'keyboardType: keyboardType,',
  'textInputAction: textInputAction,',
  'textCapitalization: textCapitalization,',
  'autocorrect: autocorrect,',
  'enableSuggestions: enableSuggestions,',
  'focusNode: focusNode,',
  'obscureText: obscureText,',
  'decoration: InputDecoration(',
  '  label: label,',
  '  hintText: hintText,',
  '  helperText: helperText,',
  '  error: error,',
  '  prefixIcon: prefixIcon != null ? Opacity(opacity: opacity, child: prefixIcon) : null,',
  '  suffixIcon: _buildTrailing(),',
  '  counterText: counterText,',
  '  alignLabelWithHint: alignLabelWithHint,',
  '),',
  'onChanged: onChanged,',
  'onSubmitted: onSubmitted,',
  'autofocus: autofocus,',
  'maxLength: maxLength,',
  'minLines: minLines,',
  'maxLines: maxLines,',
  'buildCounter: buildCounter,',
];

String _num(int? number) => '${number ?? ''}'.padLeft(4);

/// Field [i] moved right by two spaces: old 6 + [i] against new 8 + [i], the added spaces marked as jj marks them.
HunkLine _textFieldMoved(String kind, int i) {
  final String field = _textFieldFields[i];
  final String rest = field.trimLeft();
  return _line('$kind${_num(6 + i)} ${_num(8 + i)}|${' ' * (6 + field.length - rest.length)}{+  +}$rest');
}

const _textFieldSections = <HunkKey>[
  HunkKey(oldStart: 4, oldCount: 20, newStart: 4, newCount: 30),
  HunkKey(oldStart: 25, oldCount: 7, newStart: 35, newCount: 0),
];

List<HunkLine> _textFieldHead() => <HunkLine>[
  _line('    1    1|  Widget build(BuildContext context) {'),
  _line('    2    2|    final prefixIcon = this.prefixIcon;'),
  _line('    3    3|    final opacity = enabled ? 1.0 : 0.38;'),
  _line('    4    4|'),
  _line('~   5    5|    return {+Semantics(+}'),
  _line('+        6|{+      identifier: identifier,+}'),
  _line('~   5    7|{+      child: +}TextField('),
];

List<HunkLine> _textFieldTail() => <HunkLine>[
  _line('   33   36|    );'),
  _line('   34   37|  }'),
  _line('   35   38|}'),
];

/// The exact read: one hunk of two parts.
FileDiff _textFieldFile() => FileDiff(
  path: 'src/main.rs',
  kind: FileChangeKind.modified,
  fromPath: null,
  binary: false,
  modeChange: false,
  sections: _textFieldSections,
  hunks: <Hunk>[
    Hunk(
      before: (start: 0, end: 35),
      after: (start: 0, end: 38),
      symbol: null,
      sections: _textFieldSections,
      removed: 27,
      added: 30,
      lines: <HunkLine>[
        ..._textFieldHead(),
        for (var i = 0; i < 19; i++) _textFieldMoved('~', i),
        for (var i = 19; i < 27; i++) _line('+     ${_num(8 + i)}|{+        ${_textFieldFields[i]}+}'),
        _line('   25   35|      ),'),
        for (var i = 20; i < 27; i++) _line('-${_num(6 + i)}     |[-      ${_textFieldFields[i]}-]'),
        ..._textFieldTail(),
      ],
    ),
  ],
  removed: 27,
  added: 30,
  fingerprint: 'f',
);

/// The read at `-w`: its two hunks and the 27 lines that changed only in whitespace.
FileDiff _textFieldIgnoring() => FileDiff(
  path: 'src/main.rs',
  kind: FileChangeKind.modified,
  fromPath: null,
  binary: false,
  modeChange: false,
  sections: _textFieldSections,
  hunks: <Hunk>[
    Hunk(
      before: (start: 0, end: 8),
      after: (start: 0, end: 10),
      symbol: null,
      sections: const <HunkKey>[],
      removed: 1,
      added: 3,
      lines: <HunkLine>[..._textFieldHead(), for (var i = 0; i < 3; i++) _textFieldMoved(' ', i)],
    ),
    Hunk(
      before: (start: 29, end: 35),
      after: (start: 31, end: 38),
      symbol: null,
      sections: const <HunkKey>[],
      removed: 0,
      added: 1,
      lines: <HunkLine>[
        for (var i = 24; i < 27; i++) _textFieldMoved(' ', i),
        _line('+       35|{+      ),+}'),
        ..._textFieldTail(),
      ],
    ),
  ],
  removed: 1,
  added: 4,
  fingerprint: 'w',
  whitespaceLines: <HunkLine>[for (var i = 0; i < 27; i++) _textFieldMoved(' ', i)],
);

void main() {
  setUpIconRegistry();

  group('diffUnchangedRows (Story 10.43)', () {
    /// Context lines [from] to [to] (1-based, inclusive) with equal numbers.
    List<HunkLine> context(int from, int to) => <HunkLine>[
      for (var n = from; n <= to; n++) _line('${'$n'.padLeft(5)} ${'$n'.padLeft(4)}|c$n'),
    ];

    /// A row as text: `L<left>` a line, `G<from>-<to>[t][b]` an unchanged gap row (0-based, half-open).
    List<String> shape(List<DiffRow> rows) => <String>[
      for (final DiffRow row in rows)
        switch (row) {
          DiffLineRow(:final HunkLine line) => 'L${line.left ?? '-'}',
          DiffUnchangedRow(:final int from, :final int to, :final bool top, :final bool bottom) =>
            'G$from-$to${top ? 't' : ''}${bottom ? 'b' : ''}',
          DiffGapRow() => 'W',
        },
    ];

    final Hunk first = _hunk(context(1, 8), before: (start: 0, end: 8));
    final Hunk second = _hunk(context(16, 24), before: (start: 15, end: 24));
    List<List<DiffRow>> rowsOf(List<Hunk> hunks) => <List<DiffRow>>[for (final Hunk hunk in hunks) exactRows(hunk)];

    test('two hunks of a 120-line file: no top gap, 7 lines between, 96 at the bottom', () {
      final List<({List<DiffRow> rows, bool gapBefore})> result = diffUnchangedRows(
        rowsOf(<Hunk>[first, second]),
        anchors: <Hunk>[first, second],
        leftLineCount: 120,
      );
      expect(shape(result[0].rows), <String>[for (var n = 1; n <= 8; n++) 'L$n']);
      expect(result[0].gapBefore, isFalse);
      expect(shape(result[1].rows), <String>['G8-15', for (var n = 16; n <= 24; n++) 'L$n', 'G24-120b']);
      expect(result[1].gapBefore, isTrue);
      final gap = result[1].rows.first as DiffUnchangedRow;
      expect((gap.count, gap.key, gap.end), (7, 8, 15));
      expect((result[1].rows.last as DiffUnchangedRow).count, 96);
    });

    test('a top gap; a pure addition anchors at its before.start; an added file (no left lines) has none', () {
      final Hunk added = _hunk(<HunkLine>[_line('+        6|{+new+}')], before: (start: 5, end: 5));
      final List<({List<DiffRow> rows, bool gapBefore})> result = diffUnchangedRows(
        <List<DiffRow>>[exactRows(added)],
        anchors: <Hunk>[added],
        leftLineCount: 9,
      );
      expect(shape(result.single.rows), <String>['G0-5t', 'L-', 'G5-9b']);
      expect(
        shape(
          diffUnchangedRows(<List<DiffRow>>[exactRows(added)], anchors: <Hunk>[added], leftLineCount: 0).single.rows,
        ),
        <String>['L-'],
      );
    });

    test('a hole inside a hunk is a gap too', () {
      final Hunk holed = _hunk(<HunkLine>[...context(1, 3), ...context(7, 8)], before: (start: 0, end: 8));
      expect(
        shape(diffUnchangedRows(rowsOf(<Hunk>[holed]), anchors: <Hunk>[holed], leftLineCount: 8).single.rows),
        <String>['L1', 'L2', 'L3', 'G3-6', 'L7', 'L8'],
      );
    });

    test(
      'open: down lines join the row above, up lines the row below, the count shrinks; opened whole the row goes',
      () {
        final List<HunkLine> read = context(9, 15);
        List<String> opened(DiffGapOpen open) => shape(
          diffUnchangedRows(
            rowsOf(<Hunk>[first, second]),
            anchors: <Hunk>[first, second],
            leftLineCount: 24,
            open: <int, DiffGapOpen>{8: open},
          )[1].rows,
        ).take(8).toList();
        expect(opened(DiffGapOpen(down: 2, lines: read)), <String>[
          'L9',
          'L10',
          'G10-15',
          'L16',
          'L17',
          'L18',
          'L19',
          'L20',
        ]);
        expect(opened(DiffGapOpen(up: 3, lines: read)), <String>[
          'G8-12',
          'L13',
          'L14',
          'L15',
          'L16',
          'L17',
          'L18',
          'L19',
        ]);
        expect(opened(DiffGapOpen(down: 20, lines: read)).take(8), <String>[
          for (var n = 9; n <= 16; n++) 'L$n',
        ], reason: 'a step past the gap opens it whole');
        final row =
            diffUnchangedRows(
                  rowsOf(<Hunk>[first, second]),
                  anchors: <Hunk>[first, second],
                  leftLineCount: 24,
                  open: <int, DiffGapOpen>{8: DiffGapOpen(down: 2, lines: read)},
                )[1].rows[2]
                as DiffUnchangedRow;
        expect((row.key, row.end, row.from, row.to, row.count), (8, 15, 10, 15, 5), reason: 'the key stays the gap\'s');
      },
    );

    test('whitespace gap rows hold their lines; an identical-only run no row holds is a gap', () {
      final rows = <DiffRow>[
        ...context(1, 2).map(DiffLineRow.new),
        DiffGapRow(context(3, 5), open: false, hideable: true),
        ...context(6, 6).map(DiffLineRow.new),
        ...context(9, 9).map(DiffLineRow.new),
      ];
      expect(
        shape(diffUnchangedRows(<List<DiffRow>>[rows], anchors: <Hunk>[first], leftLineCount: 9).single.rows),
        <String>['L1', 'L2', 'W', 'L6', 'G6-8', 'L9'],
      );
    });
  });

  group('pairSideBySide (Story 5.10)', () {
    (String?, int?) cell(HunkLine? line, {required bool left}) =>
        (line?.text, line == null ? null : (left ? line.left : line.right));

    test('the jj example shows old line 2454 once, whole, beside its six new lines', () {
      final List<(HunkLine?, HunkLine?)> rows = pairSideBySide(<HunkLine>[for (final s in _jj) _line(s)]);
      expect(rows.map((r) => cell(r.$1, left: true)), <(String?, int?)>[
        ('        .into_inner()\n', 2453),
        ('        .map_err(|err| GitResetHeadError::from_git(err.into_error()))?;\n', 2454),
        (null, null),
        (null, null),
        (null, null),
        (null, null),
        (null, null),
        ('    lock.commit()\n', 2455),
      ]);
      expect(rows.map((r) => cell(r.$2, left: false).$2), <int>[2453, 2454, 2455, 2456, 2457, 2458, 2459, 2460]);
      expect(rows[1].$2!.text, '        .map_err(|err| {\n');
      expect(rows[6].$2!.text, '        .map_err(GitResetHeadError::from_git)?;\n');
      expect((rows[1].$1!.kind, rows[1].$2!.kind), (HunkLineKind.removed, HunkLineKind.added));
      expect(rows[0].$1!.kind, HunkLineKind.context);
      expect(rows[1].$1!.segments.map((s) => s.kind), [SegmentKind.equal, SegmentKind.removed, SegmentKind.equal]);
    });

    test('a block over the limit pairs its removed and added lines row by row', () {
      final List<(HunkLine?, HunkLine?)> rows = pairSideBySide(<HunkLine>[
        for (final s in _block) _line(s),
        _line('-  11     |[-gone-]'),
      ]);
      expect(rows.map((r) => (cell(r.$1, left: true).$2, cell(r.$2, left: false).$2)), <(int?, int?)>[
        (9, 8),
        (10, 9),
        (11, null),
      ]);
    });

    test('a conflict header is one full-width row; under ------- the left side keeps the added runs', () {
      final HunkLine header = _line('#         |------- left base #1 to right');
      final List<(HunkLine?, HunkLine?)> rows = pairSideBySide(<HunkLine>[
        header,
        _line('~   1    1|{+b+}[-z-]'),
        _line('#         |>>>>>>> Conflict ends'),
        _line('~   2    2|[-x-]{+y+}'),
      ]);
      expect(identical(rows[0].$1, header) && identical(rows[0].$2, header), isTrue);
      expect((rows[1].$1!.text, rows[1].$2!.text), ('b\n', 'z\n'));
      expect((rows[3].$1!.text, rows[3].$2!.text), ('x\n', 'y\n'));
    });
  });

  group('diffWordMarks', () {
    List<(String, SegmentKind)> marks(String spec) {
      final HunkLine line = _line(spec);
      return <(String, SegmentKind)>[for (final m in diffWordMarks(line)) (m.range.textInside(line.text), m.kind)];
    }

    test('a changed line always marks both sides\' runs, even without visible unchanged text', () {
      expect(marks(_stepper[0]), <(String, SegmentKind)>[
        ('s.functionWizard_save', SegmentKind.removed),
        ('saveLabel', SegmentKind.added),
      ]);
      expect(marks(_jj[1]), <(String, SegmentKind)>[('{', SegmentKind.added)]);
      expect(marks('~   1    1|[-a-]{+b+}'), <(String, SegmentKind)>[
        ('a', SegmentKind.removed),
        ('b', SegmentKind.added),
      ]);
    });

    test('a removed or added line without visible unchanged text keeps only its fill (10.32)', () {
      expect(marks(_jj[2]), isEmpty);
      expect(marks(_block[3]), isEmpty);
      expect(marks(_block[0]), <(String, SegmentKind)>[
        ('// The', SegmentKind.removed),
        ('layout', SegmentKind.removed),
        ('device.', SegmentKind.removed),
      ]);
    });

    test('a context line, a header and a line without segments keep none', () {
      expect(marks(_jj[0]), isEmpty);
      expect(marks('#         |<<<<<<< Created conflict'), isEmpty);
      expect(
        diffWordMarks(const HunkLine(kind: HunkLineKind.added, text: 'x\n')),
        isEmpty,
        reason: 'segments: []',
      );
    });

    test('CRLF: the mark stops before \\r and \\n; trailing blanks are marked like any run', () {
      final HunkLine crlf = _line('+        1|a{+b\r+}');
      expect(diffWordMarks(crlf).single.range, const TextRange(start: 1, end: 2));
      expect(marks('+        1|x{+  +}'), <(String, SegmentKind)>[('  ', SegmentKind.added)]);
    });
  });

  Widget view(
    FileDiff? diff, {
    DiffLayoutSetting layout = DiffLayoutSetting.unified,
    ZsAppearance appearance = const ZsAppearance(),
    bool Function(HunkKey part)? partPicked,
    bool wordMarks = true,
  }) => shellHost(
    SizedBox(
      width: 420,
      child: InspectorDiffView(
        path: 'src/main.rs',
        diff: diff,
        wordMarks: wordMarks,
        error: null,
        onViewedChanged: (_) {},
        layout: layout,
        onLayoutChanged: (_) {},
        partPicked: partPicked,
        onPartToggled: (_) {},
      ),
    ),
    appearance: appearance,
  );

  FileDiff matrix() => _file(
    hunks: <Hunk>[
      _hunk(<HunkLine>[for (final s in _jj) _line(s)]),
      _hunk(<HunkLine>[for (final s in _stepper) _line(s)]),
      _hunk(<HunkLine>[for (final s in _block) _line(s)]),
    ],
  );

  for (final ZsTheme theme in ZsTheme.values) {
    testWidgets('unified on ${theme.name}: two number columns, the looks and the matrix\'s marks', (tester) async {
      final appearance = ZsAppearance(theme: theme);
      final colors = ZsColors.resolve(appearance);
      await tester.pumpWidget(view(matrix(), appearance: appearance));
      expect(paintedWordMarks(tester, colors), <String, List<String>>{
        '        .map_err(|err| {': <String>['+{'],
        '        .map_err(GitResetHeadError::from_git(err.into_error()))?;': <String>[
          '+${' ' * 8}.map_err(',
          '-(err.into_error())',
        ],
        '    child: Text(isLastStep ? s.functionWizard_savesaveLabel : s.functionWizard_next),': <String>[
          '-s.functionWizard_save',
          '+saveLabel',
        ],
        '  // Small side padding.': <String>['+// Small side padding.'],
        '  padding: Spacing.spacing8spacing2,': <String>['+  ', '-spacing8', '+spacing2'],
        '  // The phone layout on a device.': <String>['-// The', '-layout', '-device.'],
        '  testWidgets(\'shows Funktion speichern\', (tester) async {': <String>[
          '-  testWidgets(\'shows Funktion speichern',
        ],
        '  // The tablet shows the long label.': <String>['+The', '+tablet shows the long label.'],
      });

      Color fill(String text) =>
          tester
              .widget<Container>(
                find.ancestor(of: find.text(text, findRichText: true), matching: find.byType(Container)).first,
              )
              .color ??
          const Color(0x00000000);
      Color ink(String number) => tester.widget<Text>(find.text(number).first).style!.color!;

      // A changed line: no fill, both numbers in their hue, `--text` ink.
      const changed = '        .map_err(GitResetHeadError::from_git(err.into_error()))?;';
      expect(fill(changed).a, 0);
      expect(ink('2459'), colors.add);
      expect(tester.widget<Text>(find.text('2454').last).style!.color, colors.rem);
      // An added line: the green fill, its number green, the left column blank.
      expect(fill('            PathError { path, source }'), colors.addBg);
      expect(ink('2457'), colors.add);
      // A removed line of the block: the red fill, its number red.
      expect(fill('  // The phone layout on a device.'), colors.remBg);
      expect(ink('   9'), colors.rem, reason: 'four columns: the file\'s largest number is 2459');
      // A context line: faint numbers, muted text.
      expect(ink('2453'), colors.textFaint);
      expect(tester.widget<Text>(find.text('        .into_inner()')).style!.color, colors.textMuted);
      // No sigil column.
      expect(find.text('−'), findsNothing);
      expect(find.text('+'), findsNothing);
    });
  }

  group('Changed words off (Story 5.14)', () {
    // The shown [text]'s glyph colours, as runs of one colour each.
    List<(String, Color)> inks(WidgetTester tester, String text) {
      final RenderParagraph paragraph = tester.renderObject(
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text),
      );
      final Color ink = paragraph.text.style!.color!;
      final runs = <(String, Color)>[];
      for (var at = 0; at < text.length; at++) {
        final span = paragraph.text.getSpanForPosition(TextPosition(offset: at))! as TextSpan;
        final Color color = span.style?.color ?? ink;
        if (runs.isNotEmpty && runs.last.$2 == color) {
          runs.last = (runs.last.$1 + text[at], color);
        } else {
          runs.add((text[at], color));
        }
      }
      return runs;
    }

    const changed = '        .map_err(GitResetHeadError::from_git(err.into_error()))?;';
    const removed = '  // The phone layout on a device.';

    testWidgets('unified: no fill; a changed line keeps its runs in their hue, a removed line is all its ink', (
      tester,
    ) async {
      final colors = ZsColors.resolve(const ZsAppearance());
      await tester.pumpWidget(view(matrix()));
      expect(find.byType(DiffWordMarks), findsWidgets, reason: 'on: the fills');
      await tester.pumpWidget(view(matrix(), wordMarks: false));
      expect(find.byType(DiffWordMarks), findsNothing);
      expect(inks(tester, changed), <(String, Color)>[
        ('        .map_err(', colors.add),
        ('GitResetHeadError::from_git', colors.text),
        ('(err.into_error())', colors.rem),
        (')?;', colors.text),
      ]);
      expect(inks(tester, '        .map_err(|err| {'), <(String, Color)>[
        ('        .map_err(|err| ', colors.text),
        ('{', colors.add),
      ]);
      expect(inks(tester, removed), <(String, Color)>[(removed, colors.rem)]);
    });

    testWidgets('side by side: no fill; each cell is all its line ink', (tester) async {
      final colors = ZsColors.resolve(const ZsAppearance());
      await tester.pumpWidget(view(matrix(), layout: DiffLayoutSetting.sideBySide, wordMarks: false));
      expect(find.byType(DiffWordMarks), findsNothing);
      const left = '        .map_err(|err| GitResetHeadError::from_git(err.into_error()))?;';
      const right = '        .map_err(GitResetHeadError::from_git)?;';
      expect(inks(tester, left), <(String, Color)>[(left, colors.rem)]);
      expect(inks(tester, right), <(String, Color)>[(right, colors.add)]);
      expect(inks(tester, removed), <(String, Color)>[(removed, colors.rem)]);
    });

    testWidgets('side by side under a ------- term: each cell is all its ink, though it keeps the other side\'s runs', (
      tester,
    ) async {
      final colors = ZsColors.resolve(const ZsAppearance());
      final FileDiff file = _file(
        hunks: <Hunk>[
          _hunk(<HunkLine>[
            _line('#         |------- left base #1 to right'),
            _line('~   1    1|x {+b+}[-z-]'),
            _line('#         |>>>>>>> Conflict ends'),
          ]),
        ],
      );
      await tester.pumpWidget(view(file, layout: DiffLayoutSetting.sideBySide, wordMarks: false));
      expect(find.byType(DiffWordMarks), findsNothing);
      expect(inks(tester, 'x b'), <(String, Color)>[('x b', colors.rem)], reason: 'the left cell holds the added run');
      expect(inks(tester, 'x z'), <(String, Color)>[('x z', colors.add)]);
    });
  });

  testWidgets('a number column is as wide as the hunk\'s largest number', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('    9    9|a'), _line('+      100|b')]),
          ],
        ),
      ),
    );
    expect(find.text('  9'), findsNWidgets(2));
    expect(find.text('100'), findsOneWidget);
  });

  testWidgets('side by side shows each old line once, whole, with its number; marks in both layouts', (tester) async {
    await tester.pumpWidget(view(matrix(), layout: DiffLayoutSetting.sideBySide));
    expect(find.text('        .map_err(|err| GitResetHeadError::from_git(err.into_error()))?;'), findsOneWidget);
    expect(find.text('2454'), findsNWidgets(2), reason: 'the old line once on the left, the new line on the right');
    final Finder split = find.byKey(const ValueKey<String>('inspector-diff-split'));
    expect(find.descendant(of: split, matching: find.byType(IntrinsicHeight)), findsNWidgets(8 + 3 + 2));
    expect(
      paintedWordMarks(
        tester,
        ZsColors.night,
      )['        .map_err(|err| GitResetHeadError::from_git(err.into_error()))?;'],
      <String>[
        '-(err.into_error())',
      ],
    );
  });

  testWidgets('a conflict header is a dim full-width row without numbers', (tester) async {
    for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
      await tester.pumpWidget(
        view(
          _file(
            hunks: <Hunk>[
              _hunk(<HunkLine>[_line('#         |<<<<<<< Created conflict'), _line('+        1|{+x+}')]),
            ],
          ),
          layout: layout,
        ),
      );
      expect(tester.widget<Text>(find.text('<<<<<<< Created conflict')).style!.color, ZsColors.night.textDim);
      if (layout == DiffLayoutSetting.unified) {
        expect(
          tester.getTopLeft(find.text('<<<<<<< Created conflict')).dx,
          tester.getTopLeft(find.byType(InspectorDiffView)).dx + 1 + 10,
          reason: 'no number columns: the text starts at 10 inside the well\'s 1 px border',
        );
      }
    }
  });

  testWidgets('Story 10.43: no hunk header; a picked part keeps its checkbox on its row and the edge', (tester) async {
    await tester.pumpWidget(view(matrix(), partPicked: (_) => true));
    expect(find.bySemanticsIdentifier('inspector-part-check'), findsNothing, reason: 'no sections');
    expect(find.byKey(const ValueKey<String>('inspector-hunk-header')), findsNothing);
    final FileDiff picked = _file(
      hunks: <Hunk>[
        Hunk(
          before: (start: 0, end: 1),
          after: (start: 0, end: 1),
          symbol: null,
          sections: const [HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1)],
          removed: 1,
          added: 1,
          lines: <HunkLine>[_line('~   1    1|[-a-]{+b+}')],
        ),
      ],
    );
    await tester.pumpWidget(view(picked, partPicked: (_) => true));
    expect(find.bySemanticsIdentifier('inspector-part-check'), findsOneWidget, reason: 'one part, one box');
    expect(find.textContaining('@@'), findsNothing);
    const ZsColors colors = ZsColors.night;
    final Container pin = tester.widget(find.byKey(const ValueKey<String>('inspector-line-pin')));
    expect(
      ((pin.foregroundDecoration! as BoxDecoration).border! as Border).left,
      BorderSide(color: colors.accentLine, width: 2),
    );
    await tester.pumpWidget(view(picked, partPicked: (_) => true, layout: DiffLayoutSetting.sideBySide));
    expect(find.bySemanticsIdentifier('inspector-part-check'), findsOneWidget);
    expect(find.textContaining('@@'), findsNothing);
  });

  testWidgets('a new fill or new marks repaint the line; equal ones do not', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('+        1|  x = {+42+};')]),
          ],
        ),
      ),
    );
    final PaintedWordMark mark = (range: const TextRange(start: 6, end: 8), color: ZsColors.night.addWordBg);
    // The pumped line's own marks, set again.
    final RenderDiffWordMarks box = tester.renderObject<RenderDiffWordMarks>(find.byType(DiffWordMarks))
      ..marks = <PaintedWordMark>[mark];
    expect(box.debugNeedsPaint, isFalse, reason: 'the same marks');
    box.marks = <PaintedWordMark>[(range: mark.range, color: ZsColors.night.remWordBg)];
    expect(box.debugNeedsPaint, isTrue, reason: 'a new fill');
    await tester.pump();
    expect(box.debugNeedsPaint, isFalse);
    box.marks = <PaintedWordMark>[(range: const TextRange(start: 2, end: 3), color: ZsColors.night.remWordBg)];
    expect(box.debugNeedsPaint, isTrue, reason: 'new marks');
  });

  testWidgets('a side-by-side cell clips a mark at its edge', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('+        1|xxxxx{+${'y' * 60}+}z')]),
          ],
        ),
        layout: DiffLayoutSetting.sideBySide,
      ),
    );
    final RenderParagraph paragraph = tester.renderObject(
      find.descendant(of: find.byType(DiffWordMarks), matching: find.byType(RichText)),
    );
    final TextBox box = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 5, extentOffset: 65)).single;
    expect(box.left, lessThan(paragraph.size.width));
    expect(box.right, greaterThan(paragraph.size.width), reason: 'the run reaches past the cell');
    expect(
      tester.renderObject(find.byType(DiffWordMarks)),
      paints
        ..rect(
          rect: Rect.fromLTRB(box.left, 0, paragraph.size.width, paragraph.size.height),
          color: ZsColors.night.addWordBg,
        )
        ..paragraph(),
    );
  });

  testWidgets('a selection across a marked line paints over the mark; the glyphs keep their colours', (tester) async {
    // A line short enough to drag across inside the hunk's width.
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('+        1|  x = {+42+};')]),
          ],
        ),
      ),
    );
    final Finder marks = find.byType(DiffWordMarks);
    final RenderParagraph paragraph = tester.renderObject(find.descendant(of: marks, matching: find.byType(RichText)));
    final TextBox word = paragraph.getBoxesForSelection(const TextSelection(baseOffset: 6, extentOffset: 8)).single;
    final double middle = paragraph.size.height / 2;
    final TestGesture gesture = await tester.startGesture(
      paragraph.localToGlobal(Offset(1, middle)),
      kind: PointerDeviceKind.mouse,
    );
    addTearDown(gesture.removePointer);
    await tester.pump();
    await gesture.moveTo(paragraph.localToGlobal(Offset(paragraph.size.width - 1, middle)));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(
      tester.renderObject(marks),
      paints
        ..rect(rect: Rect.fromLTRB(word.left, 0, word.right, paragraph.size.height), color: ZsColors.night.addWordBg)
        ..something((method, arguments) {
          // A paint keeps its colour in 32-bit floats: compare it the way the canvas holds it.
          if (method != #drawRect || (arguments[1] as Paint).color.toARGB32() != paragraph.selectionColor!.toARGB32()) {
            return false;
          }
          final rect = arguments[0] as Rect;
          return rect.left <= word.left && rect.right >= word.right;
        })
        ..paragraph(),
    );
    expect(paintedWordMarks(tester, ZsColors.night), <String, List<String>>{
      '  x = 42;': <String>['+42'],
    });
  });

  testWidgets('Story 10.43: no hunk header — no range, no symbol, no counts; hunks follow each other with a line', (
    tester,
  ) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('-   5     |[-old-]'), _line('+        5|{+new+}')], symbol: 'fn main()'),
            _hunk(<HunkLine>[_line('    6    6|same')], before: (start: 9, end: 10)),
          ],
        ),
      ),
    );
    expect(find.text('fn main()'), findsNothing);
    expect(find.textContaining('@@'), findsNothing);
    expect(find.text('+1'), findsNothing);
    expect(find.text('−1'), findsNothing);
    expect(find.text('old'), findsOneWidget, reason: 'no trailing newline');
    expect(find.byKey(const ValueKey<String>('inspector-unchanged-text')), findsNothing, reason: 'no line count known');
  });

  /// A two-hunk file of 120 lines: hunks over left 1-8 and 16-24 (Story 10.43's matrix).
  FileDiff gapped({int leftLineCount = 120}) => FileDiff(
    path: 'src/main.rs',
    kind: FileChangeKind.modified,
    fromPath: null,
    binary: false,
    modeChange: false,
    sections: const <HunkKey>[],
    hunks: <Hunk>[
      _hunk(
        <HunkLine>[
          for (var n = 1; n <= 7; n++) _line('${'$n'.padLeft(5)} ${'$n'.padLeft(4)}|c$n'),
          _line('~   8    8|[-a-]{+b+}'),
        ],
        before: (start: 0, end: 8),
      ),
      _hunk(
        <HunkLine>[
          for (var n = 16; n <= 24; n++) _line('${'$n'.padLeft(5)} ${'$n'.padLeft(4)}|c$n'),
        ],
        before: (start: 15, end: 24),
      ),
    ],
    removed: 1,
    added: 1,
    fingerprint: 'g',
    leftLineCount: leftLineCount,
  );

  group('Story 10.43: unchanged gap rows', () {
    /// The view of [diff] with [read] as its gap read, the reads in [reads]; inside a reveal scope when [scoped].
    Widget gapView(
      FileDiff diff, {
      Future<List<HunkLine>> Function(int start, int end)? read,
      DiffLayoutSetting layout = DiffLayoutSetting.unified,
      bool scoped = false,
      Object? linesRevision,
    }) {
      final Widget view = InspectorDiffView(
        path: 'src/main.rs',
        diff: diff,
        error: null,
        layout: layout,
        onLayoutChanged: (_) {},
        readLines: read,
        linesRevision: linesRevision,
      );
      return shellHost(SizedBox(width: 520, child: scoped ? InspectorCheckReveal(child: view) : view));
    }

    List<HunkLine> lines(int start, int end) => <HunkLine>[
      for (var n = start + 1; n <= end; n++) _line('${'$n'.padLeft(5)} ${'$n'.padLeft(4)}|u$n'),
    ];

    testWidgets('two hunks: 7 lines between, 96 at the bottom, no top gap; ↕ on 7, ↓ and Show all on 96', (
      tester,
    ) async {
      for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
        await tester.pumpWidget(gapView(gapped(), read: (s, e) async => lines(s, e), layout: layout));
        expect(find.text('7 unchanged lines'), findsOneWidget, reason: '$layout');
        expect(find.text('96 unchanged lines'), findsOneWidget);
        expect(find.bySemanticsIdentifier('inspector-unchanged-show'), findsOneWidget, reason: 'the 7: one ↕');
        expect(find.bySemanticsIdentifier('inspector-unchanged-down'), findsOneWidget, reason: 'the 96: ↓');
        expect(find.bySemanticsIdentifier('inspector-unchanged-up'), findsNothing, reason: 'not on the bottom gap');
        expect(find.bySemanticsIdentifier('inspector-unchanged-all'), findsOneWidget);
        expect(find.bySemanticsLabel('Show 7 lines'), findsOneWidget);
        expect(find.bySemanticsLabel('Show 20 lines below'), findsOneWidget);
      }
    });

    testWidgets('↓ on 31 opens 20 below the hunk above; ↑ 20 above the hunk below; one read per gap', (tester) async {
      final reads = <(int, int)>[];
      final diff = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: <Hunk>[
          _hunk(<HunkLine>[_line('~   1    1|[-a-]{+b+}')], before: (start: 0, end: 1)),
          _hunk(<HunkLine>[_line('~  33   33|[-a-]{+b+}')], before: (start: 32, end: 33)),
        ],
        removed: 2,
        added: 2,
        fingerprint: 'g',
        leftLineCount: 33,
      );
      await tester.pumpWidget(
        gapView(
          diff,
          read: (s, e) async {
            reads.add((s, e));
            return lines(s, e);
          },
        ),
      );
      expect(find.text('31 unchanged lines'), findsOneWidget);
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-down'));
      await tester.pumpAndSettle();
      expect(reads, <(int, int)>[(1, 32)], reason: "the gap's whole range, once");
      expect(find.text('11 unchanged lines'), findsOneWidget);
      expect(find.text('u2'), findsOneWidget);
      expect(find.text('u21'), findsOneWidget);
      expect(find.text('u22'), findsNothing);
      expect(
        tester.getTopLeft(find.text('u21')).dy,
        lessThan(tester.getTopLeft(find.text('11 unchanged lines')).dy),
        reason: 'below the row above, above the gap row',
      );
      expect(find.bySemanticsIdentifier('inspector-unchanged-show'), findsOneWidget, reason: '11 ≤ 20: one ↕');
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pumpAndSettle();
      expect(reads, hasLength(1), reason: 'cached');
      expect(find.byKey(const ValueKey<String>('inspector-unchanged-text')), findsNothing, reason: 'joined');
      expect(find.text('u32'), findsOneWidget);
    });

    testWidgets('Show all opens a gap whole; a top gap offers ↑ and Show all, not ↓', (tester) async {
      final diff = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: <Hunk>[
          _hunk(<HunkLine>[_line('~  41   41|[-a-]{+b+}')], before: (start: 40, end: 41)),
        ],
        removed: 1,
        added: 1,
        fingerprint: 'g',
        leftLineCount: 81,
      );
      await tester.pumpWidget(gapView(diff, read: (s, e) async => lines(s, e)));
      expect(find.text('40 unchanged lines'), findsNWidgets(2), reason: 'top and bottom');
      expect(find.bySemanticsIdentifier('inspector-unchanged-up'), findsOneWidget, reason: 'the top gap');
      expect(find.bySemanticsIdentifier('inspector-unchanged-down'), findsOneWidget, reason: 'the bottom gap');
      expect(
        tester.getTopLeft(find.bySemanticsIdentifier('inspector-unchanged-up')).dy,
        lessThan(tester.getTopLeft(find.text('ab')).dy),
      );
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-all').first);
      await tester.pumpAndSettle();
      expect(find.text('40 unchanged lines'), findsOneWidget, reason: 'the top gap opened whole');
      expect(find.text('u1'), findsOneWidget);
      expect(find.text('u40'), findsOneWidget);
    });

    testWidgets('a refused read leaves the gap closed; a new diff (another fingerprint) closes every gap', (
      tester,
    ) async {
      await tester.pumpWidget(
        gapView(gapped(), read: (s, e) async => throw const ZanshinFfiException('jj.jj_lib_error')),
      );
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsOneWidget, reason: 'still closed');

      await tester.pumpWidget(gapView(gapped(), read: (s, e) async => lines(s, e)));
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsNothing);
      final reloaded = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: gapped().hunks,
        removed: 1,
        added: 1,
        fingerprint: 'another',
        leftLineCount: 120,
      );
      await tester.pumpWidget(gapView(reloaded, read: (s, e) async => lines(s, e)));
      expect(find.text('7 unchanged lines'), findsOneWidget, reason: 'the diff changed: closed again');
    });

    testWidgets('switching the file or the whitespace mode closes every gap', (tester) async {
      Widget view(String path, DiffWhitespaceSetting whitespace) => shellHost(
        SizedBox(
          width: 520,
          child: InspectorDiffView(
            path: path,
            diff: gapped(),
            error: null,
            layout: DiffLayoutSetting.unified,
            onLayoutChanged: (_) {},
            whitespace: whitespace,
            ignoring: whitespace == DiffWhitespaceSetting.showAll ? null : gapped(),
            readLines: (s, e) async => lines(s, e),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
        await tester.pumpAndSettle();
        expect(find.text('7 unchanged lines'), findsNothing, reason: 'opened');
      }

      await tester.pumpWidget(view('src/main.rs', DiffWhitespaceSetting.showAll));
      await open();
      await tester.pumpWidget(view('src/other.rs', DiffWhitespaceSetting.showAll));
      expect(find.text('7 unchanged lines'), findsOneWidget, reason: 'another file: closed again');
      await open();
      await tester.pumpWidget(view('src/other.rs', DiffWhitespaceSetting.ignoreAll));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsOneWidget, reason: 'another whitespace mode: closed again');
    });

    testWidgets('a read in flight: a second tap sends no second read; a new diff before it lands keeps the gap '
        'closed; a refusal then a retry reads again', (tester) async {
      final reads = <Completer<List<HunkLine>>>[];
      Future<List<HunkLine>> read(int start, int end) {
        final completer = Completer<List<HunkLine>>();
        reads.add(completer);
        return completer.future;
      }

      await tester.pumpWidget(gapView(gapped(), read: read));
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pump();
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pump();
      expect(reads, hasLength(1), reason: 'the controls are inert while the read runs');

      // The diff reloads with another fingerprint before the read lands: its lines must not show.
      final reloaded = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: gapped().hunks,
        removed: 1,
        added: 1,
        fingerprint: 'another',
        leftLineCount: 120,
      );
      await tester.pumpWidget(gapView(reloaded, read: read));
      reads.single.complete(lines(8, 15));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsOneWidget, reason: 'still closed');
      expect(find.text('u9'), findsNothing, reason: 'no stale lines');

      // A refusal leaves it closed and the controls live: a retry reads again.
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pump();
      reads.last.completeError(const ZanshinFfiException('jj.jj_lib_error'));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsOneWidget);
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pump();
      expect(reads, hasLength(3), reason: 'the retry reads again');
      reads.last.complete(lines(8, 15));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsNothing);
      expect(find.text('u9'), findsOneWidget);
    });

    testWidgets('a re-read in flight after a new lines revision: inert controls; a new diff before it lands closes '
        'the gap', (tester) async {
      final reads = <Completer<List<HunkLine>>>[];
      Future<List<HunkLine>> read(int start, int end) {
        final completer = Completer<List<HunkLine>>();
        reads.add(completer);
        return completer.future;
      }

      await tester.pumpWidget(gapView(gapped(), read: read, linesRevision: 'c'));
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-down'));
      await tester.pump();
      reads.single.complete(lines(24, 120));
      await tester.pumpAndSettle();
      expect(find.text('76 unchanged lines'), findsOneWidget, reason: '20 of the bottom 96 open');
      expect(find.text('u25'), findsOneWidget);

      // Same diff at another revision: the open gap reads again, its old lines show meanwhile.
      await tester.pumpWidget(gapView(gapped(), read: read, linesRevision: 'd'));
      expect(reads, hasLength(2), reason: 'the re-read');
      expect(find.text('u25'), findsOneWidget, reason: 'the old lines stay while it runs');
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-down'));
      await tester.pump();
      expect(reads, hasLength(2), reason: 'the controls are inert while the re-read runs');

      // The diff reloads with another fingerprint before the re-read lands: its lines must not show.
      final reloaded = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: gapped().hunks,
        removed: 1,
        added: 1,
        fingerprint: 'another',
        leftLineCount: 120,
      );
      await tester.pumpWidget(gapView(reloaded, read: read, linesRevision: 'd'));
      reads.last.complete(lines(24, 120));
      await tester.pumpAndSettle();
      expect(find.text('96 unchanged lines'), findsOneWidget, reason: 'closed');
      expect(find.text('u25'), findsNothing, reason: 'no stale lines');
    });

    testWidgets('↑ on a gap of more than 20 opens its last 20 lines above the hunk below', (tester) async {
      // A gap of 31 between line 1 and line 33.
      final diff = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: <Hunk>[
          _hunk(<HunkLine>[_line('~   1    1|[-a-]{+b+}')], before: (start: 0, end: 1)),
          _hunk(<HunkLine>[_line('~  33   33|[-c-]{+d+}')], before: (start: 32, end: 33)),
        ],
        removed: 2,
        added: 2,
        fingerprint: 'up',
        leftLineCount: 33,
      );
      await tester.pumpWidget(gapView(diff, read: (s, e) async => lines(s, e)));
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-up'));
      await tester.pumpAndSettle();
      expect(find.text('11 unchanged lines'), findsOneWidget);
      expect(find.text('u13'), findsOneWidget, reason: 'the first of the last 20 (lines 13-32)');
      expect(find.text('u32'), findsOneWidget);
      expect(find.text('u12'), findsNothing);
      expect(
        tester.getTopLeft(find.text('11 unchanged lines')).dy,
        lessThan(tester.getTopLeft(find.text('u13')).dy),
        reason: 'the opened lines sit below the gap row',
      );
      expect(tester.getTopLeft(find.text('u32')).dy, lessThan(tester.getTopLeft(find.text('cd')).dy));
    });

    testWidgets('the number columns are as wide as the last line the gaps can open: three digits for 120', (
      tester,
    ) async {
      await tester.pumpWidget(gapView(gapped(), read: (s, e) async => lines(s, e)));
      expect(find.text('  1'), findsNWidgets(2), reason: 'line 1 padded to three digits on both sides');
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-all'));
      await tester.pumpAndSettle();
      expect(find.text('120'), findsNWidgets(2));
    });

    testWidgets('side by side: ↕ on the 7-line gap opens its lines in both cells', (tester) async {
      await tester.pumpWidget(
        gapView(gapped(), read: (s, e) async => lines(s, e), layout: DiffLayoutSetting.sideBySide),
      );
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsNothing);
      expect(find.text('u9'), findsNWidgets(2), reason: 'the left and the right cell');
      expect(find.text('u15'), findsNWidgets(2));
    });

    testWidgets("a whitespace gap row's Show shows only while the pointer is in the code pane", (tester) async {
      await tester.pumpWidget(
        shellHost(
          SizedBox(
            width: 520,
            child: InspectorCheckReveal(
              child: InspectorDiffView(
                path: 'src/main.rs',
                diff: _textFieldFile(),
                error: null,
                layout: DiffLayoutSetting.unified,
                onLayoutChanged: (_) {},
                whitespace: DiffWhitespaceSetting.ignoreAll,
                ignoring: _textFieldIgnoring(),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      double opacity() => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.bySemanticsIdentifier('inspector-gap-show'),
                  matching: find.byKey(const ValueKey<String>('inspector-gap-control')),
                )
                .first,
          )
          .opacity;
      expect(find.text('21 more lines with only whitespace changes'), findsOneWidget, reason: 'the text always shows');
      expect(opacity(), 0);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.text('21 more lines with only whitespace changes')));
      await tester.pumpAndSettle();
      expect(opacity(), 1);
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(opacity(), 0);
    });

    testWidgets('a reload with the same fingerprint but moved hunks closes every gap', (tester) async {
      await tester.pumpWidget(gapView(gapped(), read: (s, e) async => lines(s, e)));
      await tester.tap(find.bySemanticsIdentifier('inspector-unchanged-show'));
      await tester.pumpAndSettle();
      expect(find.text('7 unchanged lines'), findsNothing);
      final FileDiff exact = gapped();
      final shifted = FileDiff(
        path: exact.path,
        kind: exact.kind,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: const <HunkKey>[],
        hunks: <Hunk>[
          exact.hunks.first,
          _hunk(
            <HunkLine>[
              for (var n = 18; n <= 26; n++) _line('${'$n'.padLeft(5)} ${'$n'.padLeft(4)}|c$n'),
            ],
            before: (start: 17, end: 26),
          ),
        ],
        removed: exact.removed,
        added: exact.added,
        fingerprint: exact.fingerprint,
        leftLineCount: 120,
      );
      await tester.pumpWidget(gapView(shifted, read: (s, e) async => lines(s, e)));
      expect(
        find.text('9 unchanged lines'),
        findsOneWidget,
        reason: 'the moved gap is closed, not read from the cache',
      );
      expect(find.text('u9'), findsNothing);
    });

    testWidgets('without readLines a gap row shows its count only', (tester) async {
      await tester.pumpWidget(gapView(gapped()));
      expect(find.text('7 unchanged lines'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-unchanged-show'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-unchanged-all'), findsNothing);
    });

    testWidgets('the pointer outside the code pane hides the controls, inside shows them; counts always show', (
      tester,
    ) async {
      await tester.pumpWidget(gapView(gapped(), read: (s, e) async => lines(s, e), scoped: true));
      await tester.pumpAndSettle();
      double opacity(String identifier) => tester
          .widget<AnimatedOpacity>(
            find
                .ancestor(
                  of: find.bySemanticsIdentifier(identifier),
                  matching: find.byKey(const ValueKey<String>('inspector-gap-control')),
                )
                .first,
          )
          .opacity;
      expect(find.text('7 unchanged lines'), findsOneWidget);
      expect(opacity('inspector-unchanged-show'), 0);
      expect(opacity('inspector-unchanged-all'), 0);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.text('c3')));
      await tester.pumpAndSettle();
      expect(opacity('inspector-unchanged-show'), 1);
      expect(opacity('inspector-unchanged-all'), 1);
      // The pointer leaves.
      await mouse.removePointer();
      await tester.pumpAndSettle();
      expect(opacity('inspector-unchanged-show'), 0);
    });
  });

  testWidgets('a unified line wider than the hunk scrolls in a ZsScrollArea; short lines leave nothing to scroll', (
    tester,
  ) async {
    double extent() =>
        tester.widget<ZsScrollArea>(find.byType(ZsScrollArea)).horizontalController!.position.maxScrollExtent;
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[
              _line('+        1|{+let message = "a line long enough to leave the inspector on its right edge";+}'),
            ]),
          ],
        ),
      ),
    );
    expect(extent(), greaterThan(0));

    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('+        1|{+short+}')]),
          ],
        ),
      ),
    );
    expect(extent(), 0);
  });

  testWidgets('a CRLF line loses its \\r; a last line without its newline gets jj\'s marker in both layouts', (
    tester,
  ) async {
    for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
      await tester.pumpWidget(
        view(
          _file(
            hunks: <Hunk>[
              _hunk(<HunkLine>[_line('-   1     |[-dos\r-]'), _line('+        1|{+end+}', newline: false)]),
            ],
          ),
          layout: layout,
        ),
      );
      expect(find.text('dos'), findsOneWidget, reason: '$layout');
      expect(find.text('end'), findsOneWidget);
      expect(find.text(noNewlineMarker), findsOneWidget, reason: '$layout');
      if (layout == DiffLayoutSetting.unified) {
        expect(
          tester.getTopLeft(find.text(noNewlineMarker)).dx,
          tester.getTopLeft(find.text('end')).dx,
          reason: 'the marker starts where the line text starts',
        );
      }
    }
  });

  testWidgets('a mode change with hunks shows the mode note above them', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          modeChange: true,
          hunks: <Hunk>[
            _hunk(<HunkLine>[_line('+        1|{+x+}')]),
          ],
        ),
      ),
    );
    expect(find.text('Executable bit changed'), findsOneWidget);
    expect(find.text('x'), findsOneWidget);
    expect(find.text(noNewlineMarker), findsNothing, reason: 'every line ends in its newline');
  });

  for (final (String name, FileDiff file, String text) in <(String, FileDiff, String)>[
    ('binary', _file(binary: true), 'Binary file'),
    ('mode-only', _file(modeChange: true), 'Executable bit changed'),
    ('hunk-less', _file(), 'No line changes'),
  ]) {
    testWidgets('a $name file shows "$text"', (tester) async {
      await tester.pumpWidget(view(file));
      expect(find.text(text), findsOneWidget);
    });
  }

  group('Story 10.38: parts and pinned numbers', () {
    const s1 = HunkKey(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1);
    const s2 = HunkKey(oldStart: 5, oldCount: 1, newStart: 5, newCount: 2);
    const s3 = HunkKey(oldStart: 9, oldCount: 0, newStart: 10, newCount: 1);
    Hunk parts(List<HunkKey> sections) => Hunk(
      before: (start: 0, end: 11),
      after: (start: 0, end: 12),
      symbol: null,
      sections: sections,
      removed: 2,
      added: 4,
      lines: <HunkLine>[
        _line('    1    1|c1'),
        _line('-   2     |[-old 2-]'),
        _line('+        2|{+new 2+}'),
        _line('    3    3|c3'),
        _line('-   6     |[-old 6-]'),
        _line('+        6|{+new 6a+}'),
        _line('+        7|{+new 6b+}'),
        _line('   10   10|c10'),
        _line('+       11|{+new 11+}'),
      ],
    );

    test('a line belongs to the section whose range holds its number − 1; context to none', () {
      List<int?> lineParts(Hunk hunk) => <int?>[for (final DiffRow row in exactRows(hunk)) (row as DiffLineRow).part];
      expect(lineParts(parts(const <HunkKey>[s1, s2, s3])), <int?>[null, 0, 0, null, 1, 1, 1, null, 2]);
      expect(lineParts(parts(const <HunkKey>[s1])), <int?>[null, 0, 0, null, null, null, null, null, null]);
    });

    Widget picks(
      List<HunkKey> sections, {
      Set<HunkKey> picked = const <HunkKey>{},
      DiffLayoutSetting layout = DiffLayoutSetting.unified,
      ValueChanged<HunkKey>? onPart,
      String fingerprint = 'f',
    }) => shellHost(
      SizedBox(
        width: 420,
        child: InspectorDiffView(
          path: 'src/main.rs',
          diff: _file(hunks: <Hunk>[parts(sections)], fingerprint: fingerprint),
          error: null,
          layout: layout,
          onLayoutChanged: (_) {},
          partPicked: picked.contains,
          onPartToggled: onPart ?? (_) {},
        ),
      ),
    );
    Finder partBoxes() => find.bySemanticsIdentifier('inspector-part-check');

    testWidgets('three parts: no header, one checkbox per part on its first changed row, the edge on the picked part', (
      tester,
    ) async {
      final toggled = <HunkKey>[];
      await tester.pumpWidget(picks(const <HunkKey>[s1, s2, s3], picked: <HunkKey>{s2}, onPart: toggled.add));
      expect(find.text('3 parts'), findsNothing);
      expect(find.byKey(const ValueKey<String>('inspector-hunk-header')), findsNothing);
      expect(partBoxes(), findsNWidgets(3));
      // Each box sits on its part's first changed row.
      for (final (int i, String text) in <(int, String)>[(0, 'old 2'), (1, 'old 6'), (2, 'new 11')]) {
        expect(
          tester.getCenter(partBoxes().at(i)).dy,
          closeTo(tester.getCenter(find.text(text)).dy, 2),
          reason: 'part ${i + 1} on "$text"',
        );
      }
      bool edged(String text) =>
          (tester
                      .widget<Container>(
                        find
                            .descendant(
                              of: find.ancestor(of: find.text(text), matching: find.byType(Stack)).first,
                              matching: find.byKey(const ValueKey<String>('inspector-line-pin')),
                            )
                            .first,
                      )
                      .foregroundDecoration!
                  as BoxDecoration)
              .border !=
          null;
      expect(
        <bool>[
          for (final t in <String>['c1', 'old 2', 'old 6', 'new 6b', 'c10', 'new 11']) edged(t),
        ],
        <bool>[
          false,
          false,
          true,
          true,
          false,
          false,
        ],
      );
      await tester.tap(partBoxes().at(2));
      await tester.pump();
      expect(toggled, <HunkKey>[s3]);

      toggled.clear();
      await tester.pumpWidget(
        picks(
          const <HunkKey>[s1, s2, s3],
          picked: <HunkKey>{s2},
          layout: DiffLayoutSetting.sideBySide,
          onPart: toggled.add,
        ),
      );
      expect(partBoxes(), findsNWidgets(3), reason: 'side by side: the gutter leads the row');
      expect(find.text('3 parts'), findsNothing);
      // Side by side the edge sits on each row; a row whose left cell is empty takes its right line's part.
      bool rowEdged(String text) =>
          (tester
                      .widget<DecoratedBox>(
                        find
                            .ancestor(
                              of: find.text(text),
                              matching: find.byWidgetPredicate(
                                (w) => w is DecoratedBox && w.position == DecorationPosition.foreground,
                              ),
                            )
                            .first,
                      )
                      .decoration
                  as BoxDecoration)
              .border !=
          null;
      expect(
        <bool>[
          for (final t in <String>['c1', 'old 2', 'old 6', 'new 6b', 'c10', 'new 11']) rowEdged(t),
        ],
        <bool>[false, false, true, true, false, false],
      );
      await tester.tap(partBoxes().at(1));
      await tester.pump();
      await tester.tap(partBoxes().at(2));
      await tester.pump();
      expect(toggled, <HunkKey>[s2, s3]);
    });

    testWidgets('one part: its one checkbox in the gutter, on its first changed row; no hunk checkbox', (tester) async {
      await tester.pumpWidget(picks(const <HunkKey>[s1]));
      expect(partBoxes(), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsNothing);
      expect(tester.getCenter(partBoxes()).dy, closeTo(tester.getCenter(find.text('old 2')).dy, 2));
    });

    testWidgets('the pointer on a part checkbox draws the edge on its rows; leaving removes it (both layouts)', (
      tester,
    ) async {
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
        await tester.pumpWidget(picks(const <HunkKey>[s1, s2, s3], layout: layout));
        bool on(String text) {
          final Finder pinned = find.descendant(
            of: find.ancestor(of: find.text(text), matching: find.byType(Stack)).first,
            matching: find.byKey(const ValueKey<String>('inspector-line-pin')),
          );
          final Decoration? decoration = layout == DiffLayoutSetting.unified
              ? tester.widget<Container>(pinned.first).foregroundDecoration
              : tester
                    .widget<DecoratedBox>(
                      find
                          .ancestor(
                            of: find.text(text),
                            matching: find.byWidgetPredicate(
                              (w) => w is DecoratedBox && w.position == DecorationPosition.foreground,
                            ),
                          )
                          .first,
                    )
                    .decoration;
          return (decoration! as BoxDecoration).border != null;
        }

        const texts = <String>['old 2', 'old 6', 'new 6b', 'c10'];
        expect(<bool>[for (final t in texts) on(t)], <bool>[false, false, false, false]);
        await mouse.moveTo(tester.getCenter(partBoxes().at(1)));
        await tester.pump();
        expect(<bool>[for (final t in texts) on(t)], <bool>[false, true, true, false], reason: '$layout: part 2');
        await mouse.moveTo(Offset.zero);
        await tester.pump();
        expect(<bool>[for (final t in texts) on(t)], <bool>[false, false, false, false], reason: '$layout: left');
      }
    });

    testWidgets('a reload under the pointer drops the hover edge: the hovered part index is not carried to new parts', (
      tester,
    ) async {
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      bool on(String text) =>
          (tester
                      .widget<Container>(
                        find
                            .descendant(
                              of: find.ancestor(of: find.text(text), matching: find.byType(Stack)).first,
                              matching: find.byKey(const ValueKey<String>('inspector-line-pin')),
                            )
                            .first,
                      )
                      .foregroundDecoration!
                  as BoxDecoration)
              .border !=
          null;
      await tester.pumpWidget(picks(const <HunkKey>[s1, s2, s3]));
      await mouse.moveTo(tester.getCenter(partBoxes().at(1)));
      await tester.pump();
      expect(on('new 6b'), isTrue, reason: 'part 2 hovered');
      // A new diff in which part index 1 is the run at line 11: no exit fires for the box that went.
      await tester.pumpWidget(picks(const <HunkKey>[s2, s3], fingerprint: 'g'));
      await tester.pump();
      expect(on('new 11'), isFalse, reason: 'the stale hover does not light the new part 2');
    });

    testWidgets('scrolled fully right, a short line keeps its numbers and part checkbox at the left edge', (
      tester,
    ) async {
      final toggled = <HunkKey>[];
      final FileDiff file = _file(
        hunks: <Hunk>[
          Hunk(
            before: (start: 0, end: 2),
            after: (start: 0, end: 2),
            symbol: null,
            sections: const <HunkKey>[
              HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1),
              HunkKey(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1),
            ],
            removed: 0,
            added: 2,
            lines: <HunkLine>[
              _line('+        1|{+let message = "a line long enough to leave the inspector on its right edge, far";+}'),
              _line('+        2|{+short+}'),
            ],
          ),
        ],
      );
      await tester.pumpWidget(
        shellHost(
          SizedBox(
            width: 420,
            height: 300,
            child: InspectorDiffView(
              path: 'src/main.rs',
              diff: file,
              error: null,
              layout: DiffLayoutSetting.unified,
              onLayoutChanged: (_) {},
              partPicked: (_) => false,
              onPartToggled: toggled.add,
            ),
          ),
        ),
      );
      final ScrollController horizontal = tester.widget<ZsScrollArea>(find.byType(ZsScrollArea)).horizontalController!;
      expect(horizontal.position.maxScrollExtent, greaterThan(0));
      final double left = tester.getTopLeft(find.byType(InspectorDiffView)).dx;
      final double numberAt = tester.getTopLeft(find.text('2')).dx;
      final double boxAt = tester.getTopLeft(partBoxes().at(1)).dx;
      horizontal.jumpTo(horizontal.position.maxScrollExtent);
      await tester.pump();
      expect(tester.getTopLeft(find.text('2')).dx, numberAt, reason: 'the number stays put');
      expect(tester.getTopLeft(partBoxes().at(1)).dx, boxAt, reason: 'the part checkbox too');
      expect(tester.getTopLeft(find.text('short')).dx, lessThan(numberAt), reason: 'the text scrolled under it');
      expect(numberAt, greaterThan(left), reason: 'inside the well');
      await tester.tap(partBoxes().at(1));
      await tester.pump();
      expect(
        toggled,
        <HunkKey>[const HunkKey(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1)],
        reason:
            'the pinned '
            'checkbox takes taps where it shows',
      );
    });

    testWidgets('in an unbounded column (the operation view) the view keeps its content height and scrolls sideways', (
      tester,
    ) async {
      await tester.pumpWidget(
        shellHost(
          SingleChildScrollView(
            child: SizedBox(
              width: 420,
              child: InspectorDiffView(
                path: 'src/main.rs',
                diff: _file(
                  hunks: <Hunk>[
                    _hunk(<HunkLine>[
                      _line(
                        '+        1|{+let message = "a line long enough to leave the inspector on its right edge";+}',
                      ),
                    ]),
                  ],
                ),
                error: null,
                layout: DiffLayoutSetting.unified,
                onLayoutChanged: (_) {},
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      final ZsScrollArea area = tester.widget(find.byType(ZsScrollArea));
      expect(area.controller.hasClients, isFalse, reason: 'no vertical scroll of its own');
      expect(area.horizontalController!.position.maxScrollExtent, greaterThan(0));
      expect(tester.getSize(find.byType(InspectorDiffView)).height, lessThan(200), reason: 'its content height');
    });
  });

  group('Story 10.33 / 10.41: whitespace ignored', () {
    // The file as the ignoring read lists it: [specs]' lines in one hunk, and the whitespace-only lines.
    FileDiff ignoring(List<String> specs, {List<String> spaces = const <String>[]}) => FileDiff(
      path: 'src/main.rs',
      kind: FileChangeKind.modified,
      fromPath: null,
      binary: false,
      modeChange: false,
      sections: const <HunkKey>[],
      hunks: <Hunk>[
        if (specs.isNotEmpty) _hunk(<HunkLine>[for (final String spec in specs) _line(spec)]),
      ],
      removed: 0,
      added: 0,
      fingerprint: 'w',
      whitespaceLines: <HunkLine>[for (final String spec in spaces) _line(spec)],
    );
    Hunk sectioned(List<String> specs, List<HunkKey> sections, {({int start, int end}) before = (start: 0, end: 10)}) =>
        Hunk(
          before: before,
          after: before,
          symbol: null,
          sections: sections,
          removed: 0,
          added: 0,
          lines: <HunkLine>[for (final String spec in specs) _line(spec)],
        );
    FileDiff exactFile(List<Hunk> hunks) => FileDiff(
      path: 'src/main.rs',
      kind: FileChangeKind.modified,
      fromPath: null,
      binary: false,
      modeChange: false,
      sections: <HunkKey>[for (final Hunk hunk in hunks) ...hunk.sections],
      hunks: hunks,
      removed: 0,
      added: 0,
      fingerprint: 'f',
    );
    // A line row as `kind left right [pN]`, a gap as `gap count[+identical] [open] [fixed] [pN]`.
    List<String> shape(List<DiffRow> rows) => <String>[
      for (final DiffRow row in rows)
        switch (row) {
          DiffLineRow(:final HunkLine line, :final int? part) =>
            '${line.kind.name} ${line.left} ${line.right}${part == null ? '' : ' p$part'}',
          DiffGapRow(:final List<HunkLine> lines, :final bool open, :final bool hideable, :final int? part) =>
            'gap ${row.count}${lines.length == row.count ? '' : '+${lines.length - row.count}'}'
                '${open ? ' open' : ''}${hideable ? '' : ' fixed'}${part == null ? '' : ' p$part'}',
          DiffUnchangedRow() => 'unchanged ${row.count}',
        },
    ];

    test('the modes map to the reads: show all exact, amount -b, all -w', () {
      expect(diffWhitespaceOf(DiffWhitespaceSetting.showAll), DiffWhitespace.exact);
      expect(diffWhitespaceOf(DiffWhitespaceSetting.ignoreChangesInAmount), DiffWhitespace.ignoreSpaceChange);
      expect(diffWhitespaceOf(DiffWhitespaceSetting.ignoreAll), DiffWhitespace.ignoreAllSpace);
    });

    test('text_field at -w: one block, the exact range, +4 −1, the ignoring read\'s rows with one gap of 21, one '
        'part', () {
      final FileDiff read = _textFieldIgnoring();
      final List<DiffBlock> blocks = diffBlocks(_textFieldFile(), read);
      final DiffBlock block = blocks.single;
      expect((block.hunk.before, block.hunk.after), ((start: 0, end: 35), (start: 0, end: 38)));
      expect((block.hunk.added, block.hunk.removed), (4, 1));
      // Old 26–32 (section 2) pair with new 28–34 (section 1): one part of both sections, one checkbox.
      expect(block.parts, <List<HunkKey>>[_textFieldSections]);
      expect(block.hunk.sections, _textFieldSections);
      expect(block.hunk.lines, <HunkLine>[for (final Hunk hunk in read.hunks) ...hunk.lines]);
      expect(block.foldParts, isEmpty);
      final List<String> rows = shape(diffBlockRows(block));
      expect(rows, <String>[
        'context 1 1',
        'context 2 2',
        'context 3 3',
        'context 4 4',
        'changed 5 5 p0',
        'added null 6 p0',
        'changed 5 7 p0',
        'context 6 8 p0',
        'context 7 9 p0',
        'context 8 10 p0',
        'gap 21',
        'context 30 32 p0',
        'context 31 33 p0',
        'context 32 34 p0',
        'added null 35',
        'context 33 36',
        'context 34 37',
        'context 35 38',
      ]);
      expect(rows.where((row) => row.startsWith('removed')), isEmpty, reason: 'nothing removed below buildCounter');
    });

    test('Show opens a gap: its row stays above old 9-29 / new 11-31; a pick opens every gap without Hide', () {
      final DiffBlock block = diffBlocks(_textFieldFile(), _textFieldIgnoring()).single;
      final List<DiffRow> open = diffBlockRows(block, opened: <int>{9});
      final int at = open.indexWhere((row) => row is DiffGapRow);
      expect(shape(open)[at], 'gap 21 open');
      expect(
        <(int?, int?)>[
          for (final DiffRow row in open.skip(at + 1).take(21)) ((row as DiffLineRow).line.left, row.line.right),
        ],
        <(int?, int?)>[for (var left = 9; left <= 29; left++) (left, left + 2)],
      );
      expect(shape(open)[at + 22], 'context 30 32 p0');
      expect(shape(diffBlockRows(block, opened: <int>{10})), contains('gap 21'), reason: 'keyed by its first line');
      expect(shape(diffBlockRows(block, revealed: true))[at], 'gap 21 open fixed');
    });

    test('a mixed part: the rows are the ignoring lines, a re-indent far from the change hides in a gap, the counts '
        'are the ignoring rows\'', () {
      const part = HunkKey(oldStart: 0, oldCount: 10, newStart: 0, newCount: 10);
      final List<DiffBlock> blocks = diffBlocks(
        exactFile(<Hunk>[
          sectioned(<String>['~   1    1|[-a-]{+A+}', '~   8    8|{+  +}h'], const <HunkKey>[part]),
        ]),
        ignoring(
          <String>['~   1    1|[-a-]{+A+}', '    2    2|b', '    3    3|c', '    4    4|d'],
          spaces: <String>['    8    8|{+  +}h'],
        ),
      );
      final DiffBlock block = blocks.single;
      expect((block.hunk.added, block.hunk.removed), (1, 1));
      expect(shape(diffBlockRows(block)), <String>[
        'changed 1 1 p0',
        'context 2 2',
        'context 3 3',
        'context 4 4',
        'gap 1',
      ]);
    });

    // `a b` → `a  b` five lines below a change: a whitespace-only part.
    const s1 = HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1);
    const s2 = HunkKey(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1);
    final Hunk farHunk = sectioned(<String>['~   1    1|[-x-]{+X+}', '~   6    6|a{+ +} b'], const <HunkKey>[s1, s2]);

    test('a whitespace-only part far from any change: its run is its fold, Show opens it', () {
      final DiffBlock block = diffBlocks(
        exactFile(<Hunk>[farHunk]),
        ignoring(<String>['~   1    1|[-x-]{+X+}'], spaces: <String>['    6    6|a{+ +} b']),
      ).single;
      expect(block.hunk.sections, <HunkKey>[s1, s2]);
      expect(block.foldParts, <int>{1});
      expect(shape(diffBlockRows(block)), <String>['changed 1 1 p0', 'gap 1 p1']);
      expect(shape(diffBlockRows(block, opened: <int>{6})), <String>[
        'changed 1 1 p0',
        'gap 1 open p1',
        'context 6 6 p1',
      ]);
    });

    test('a run splits where a whitespace-only part\'s lines start', () {
      const mixed = HunkKey(oldStart: 0, oldCount: 5, newStart: 0, newCount: 5);
      const only = HunkKey(oldStart: 5, oldCount: 1, newStart: 5, newCount: 1);
      final DiffBlock block = diffBlocks(
        exactFile(<Hunk>[
          sectioned(
            <String>['~   1    1|[-x-]{+X+}', '~   5    5|{+ +}e', '~   6    6|{+ +}f'],
            const <HunkKey>[mixed, only],
          ),
        ]),
        ignoring(<String>['~   1    1|[-x-]{+X+}'], spaces: <String>['    5    5|{+ +}e', '    6    6|{+ +}f']),
      ).single;
      expect(shape(diffBlockRows(block)), <String>['changed 1 1 p0', 'gap 1', 'gap 1 p1']);
    });

    // A change at line 1, then x and y re-indented far below it with a blank line between (Ralph, 2a).
    const whole = HunkKey(oldStart: 0, oldCount: 40, newStart: 0, newCount: 40);
    final FileDiff blankExact = exactFile(<Hunk>[
      sectioned(<String>['~   1    1|[-a-]{+A+}'], const <HunkKey>[whole], before: (start: 0, end: 40)),
    ]);
    const blankSpaces = <String>['   10   10|{+  +}x', '   11   11|', '   12   12|{+  +}y'];

    test('a blank line between re-indented lines is hidden with them, not counted, and shown by Show so the numbers '
        'run on', () {
      final DiffBlock block = diffBlocks(
        blankExact,
        ignoring(<String>['~   1    1|[-a-]{+A+}', '    2    2|b'], spaces: blankSpaces),
      ).single;
      expect(shape(diffBlockRows(block)), <String>['changed 1 1 p0', 'context 2 2', 'gap 2+1']);
      expect(shape(diffBlockRows(block, opened: <int>{10})), <String>[
        'changed 1 1 p0',
        'context 2 2',
        'gap 2+1 open',
        'context 10 10 p0',
        'context 11 11 p0',
        'context 12 12 p0',
      ]);
    });

    test('a hidden run of identical lines only gets no gap row', () {
      // Its whitespace-only neighbours show (a context pair the CLI split over the alternation limit).
      final DiffBlock block = diffBlocks(
        blankExact,
        ignoring(<String>['~   1    1|[-a-]{+A+}', '   10   10|{+  +}x', '   12   12|{+  +}y'], spaces: blankSpaces),
      ).single;
      expect(shape(diffBlockRows(block)), <String>['changed 1 1 p0', 'context 10 10 p0', 'context 12 12 p0']);
    });

    test('a listed line shows when an ignoring line has its left or its right number', () {
      final DiffBlock block = diffBlocks(
        blankExact,
        ignoring(
          <String>['~   1    1|[-a-]{+A+}', '   10     |x', '        10|{+  +}x', '   11   11|', '   12   12|{+  +}y'],
          spaces: blankSpaces,
        ),
      ).single;
      expect(diffBlockRows(block).whereType<DiffGapRow>(), isEmpty, reason: 'line 10 shows split, as left and right');
    });

    // A real change in section A; old 6–7 removed (B) pair with new 8–9 added (C): B and C are tied.
    const sA = HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1);
    const sB = HunkKey(oldStart: 5, oldCount: 2, newStart: 5, newCount: 0);
    const sC = HunkKey(oldStart: 7, oldCount: 0, newStart: 7, newCount: 2);
    final FileDiff tiedExact = exactFile(<Hunk>[
      sectioned(
        <String>['~   1    1|[-a-]{+A+}', '-   6     |[-  x-]', '-   7     |[-  y-]', '+        8|{+    x+}'],
        const <HunkKey>[sA, sB, sC],
        before: (start: 0, end: 20),
      ),
    ]);
    final FileDiff tiedIgnoring = ignoring(
      <String>['~   1    1|[-a-]{+A+}', '    2    2|b'],
      spaces: <String>['    6    8|  {+  +}x', '    7    9|  {+  +}y'],
    );

    test('a listed pair whose sides lie in two sections ties them into one part', () {
      final DiffBlock block = diffBlocks(tiedExact, tiedIgnoring).single;
      expect(block.parts, <List<HunkKey>>[
        <HunkKey>[sA],
        <HunkKey>[sB, sC],
      ]);
      expect(block.hunk.sections, <HunkKey>[sA, sB, sC], reason: 'the hunk checkbox picks every part');
      expect(block.foldParts, <int>{1});
      expect(shape(diffBlockRows(block)), <String>['changed 1 1 p0', 'context 2 2', 'gap 2 p1']);
    });

    // The ignoring read matched s1's line elsewhere, so no row touches it: a pick of s2 alone would commit half a move.
    test('a section no row touches joins every section into one part', () {
      final DiffBlock block = diffBlocks(
        exactFile(<Hunk>[farHunk]),
        ignoring(<String>['~   6    6|[-a-]{+A+}']),
      ).single;
      expect(block.parts, <List<HunkKey>>[
        <HunkKey>[s1, s2],
      ]);
      expect(block.hunk.sections, <HunkKey>[s1, s2]);
      expect(block.foldParts, isEmpty);
    });

    test('a block whose rows touch no section is one part of every section', () {
      final DiffBlock block = diffBlocks(
        exactFile(<Hunk>[farHunk]),
        ignoring(<String>['~   3    3|[-c-]{+C+}']),
      ).single;
      expect(block.parts, <List<HunkKey>>[
        <HunkKey>[s1, s2],
      ]);
      expect(block.hunk.sections, <HunkKey>[s1, s2]);
      expect(block.foldParts, isEmpty, reason: 'a merged part is never a fold');
    });

    test('blocks place a line by its left number, an added line by its right, a header with the line before — with '
        'old and new starts that differ', () {
      const first = Hunk(
        before: (start: 0, end: 4),
        after: (start: 0, end: 6),
        symbol: null,
        sections: <HunkKey>[],
        removed: 0,
        added: 0,
        lines: <HunkLine>[],
      );
      const second = Hunk(
        before: (start: 10, end: 14),
        after: (start: 14, end: 18),
        symbol: null,
        sections: <HunkKey>[],
        removed: 0,
        added: 0,
        lines: <HunkLine>[],
      );
      final List<DiffBlock> blocks = diffBlocks(
        exactFile(<Hunk>[first, second]),
        ignoring(<String>['+       12|{+n+}', '-  11     |[-o-]', '#         |%%%%%%%']),
      );
      expect(blocks.map((block) => block.exact), <Hunk>[first, second]);
      expect(blocks[0].lines.map((line) => line.right), <int?>[12], reason: 'new 12 is before new 15');
      expect(blocks[1].lines.map((line) => line.kind), <HunkLineKind>[
        HunkLineKind.removed,
        HunkLineKind.conflictHeader,
      ], reason: 'old 11 is at or after old 11; the header follows it');
    });

    test('lines go to the last exact hunk starting at or before them; a block with nothing goes; none left when '
        'only whitespace changed', () {
      final Hunk first = sectioned(<String>['~   2    2|[-a-]{+A+}'], const <HunkKey>[], before: (start: 0, end: 4));
      final Hunk second = sectioned(<String>['~  12   12|[-b-]{+B+}'], const <HunkKey>[], before: (start: 10, end: 14));
      final Hunk third = sectioned(<String>['~  22   22|{+ +}c'], const <HunkKey>[], before: (start: 20, end: 24));
      final List<DiffBlock> blocks = diffBlocks(
        exactFile(<Hunk>[first, second, third]),
        ignoring(<String>['~   2    2|[-a-]{+A+}', '~  12   12|[-b-]{+B+}'], spaces: <String>['   11   11|{+ +}z']),
      );
      expect(blocks.map((block) => block.exact), <Hunk>[first, second], reason: 'the third has nothing');
      expect(blocks[1].whitespaceLines.single.left, 11);
      expect(shape(diffBlockRows(blocks[1])), <String>['gap 1', 'changed 12 12']);
      expect(diffBlocks(exactFile(<Hunk>[first]), ignoringOf('src/main.rs', null)), isEmpty);
      expect(ignoringOf('src/main.rs', null).hunks, isEmpty);
    });

    test('without the ignoring read every exact line shows with its part', () {
      expect(shape(exactRows(farHunk)), <String>['changed 1 1 p0', 'changed 6 6 p1']);
    });

    test('the options menu: whitespace rows with jj\'s commands, the context choices with an off-list value in order, '
        'none checked while unreadable, then the note', () {
      final AppLocalizations strings = platformStrings();
      final changed = <Object>[];
      List<ZsMenuEntry> entries(int? context) => diffOptionsEntries(
        strings,
        whitespace: DiffWhitespaceSetting.ignoreChangesInAmount,
        onWhitespaceChanged: changed.add,
        contextLines: context,
        onContextLinesChanged: changed.add,
      );
      final List<ZsMenuItem> items = entries(7).whereType<ZsMenuItem>().toList();
      expect(
        <String?>[for (final ZsMenuItem item in items.take(3)) item.cmd],
        <String>[
          'jj diff',
          'jj diff -b',
          'jj diff -w',
        ],
      );
      expect(<bool?>[for (final ZsMenuItem item in items.take(3)) item.checked], <bool>[false, true, false]);
      expect(
        <String>[for (final ZsMenuItem item in items.skip(3)) item.label],
        <String>[
          '0',
          '1',
          '2',
          '3',
          '5',
          '7',
          '10',
          '20',
        ],
      );
      expect(items.firstWhere((item) => item.label == '7').checked, isTrue);
      expect(items.firstWhere((item) => item.label == '3').shortcut, "jj's default");
      expect(entries(7).last, isA<ZsMenuNote>());
      expect(entries(7).whereType<ZsMenuHeader>().map((h) => h.label), <String>['Whitespace', 'Context lines']);
      final List<ZsMenuItem> unreadable = entries(null).whereType<ZsMenuItem>().skip(3).toList();
      expect(unreadable.map((item) => item.label), <String>['0', '1', '2', '3', '5', '10', '20']);
      expect(unreadable.where((item) => item.checked ?? false), isEmpty);
      items[2].onSelected!();
      items.firstWhere((item) => item.label == '10').onSelected!();
      expect(changed, <Object>[DiffWhitespaceSetting.ignoreAll, 10]);
    });

    Widget wsView({
      Hunk? hunk,
      FileDiff? exact,
      FileDiff? ignoring,
      Set<HunkKey> picked = const <HunkKey>{},
      ValueChanged<HunkKey>? onPart,
      DiffLayoutSetting layout = DiffLayoutSetting.unified,
      DiffWhitespaceSetting whitespace = DiffWhitespaceSetting.ignoreAll,
      int? context = 3,
      ValueChanged<DiffWhitespaceSetting>? onWhitespace,
      ValueChanged<int>? onContext,
      bool picks = true,
      ZsAppearance appearance = const ZsAppearance(),
      List<ZsMenuEntry> Function(BuildContext context, int line)? lineMenu,
    }) => shellHost(
      appearance: appearance,
      SizedBox(
        width: 520,
        child: InspectorDiffView(
          path: 'src/main.rs',
          diff:
              exact ??
              FileDiff(
                path: 'src/main.rs',
                kind: FileChangeKind.modified,
                fromPath: null,
                binary: false,
                modeChange: false,
                sections: hunk!.sections,
                hunks: <Hunk>[hunk],
                removed: 1,
                added: 1,
                fingerprint: 'f',
              ),
          error: null,
          layout: layout,
          onLayoutChanged: (_) {},
          partPicked: picks ? picked.contains : null,
          onPartToggled: onPart ?? (_) {},
          whitespace: whitespace,
          onWhitespaceChanged: onWhitespace ?? (_) {},
          ignoring: whitespace == DiffWhitespaceSetting.showAll ? null : ignoring,
          contextLines: context,
          onContextLinesChanged: onContext ?? (_) {},
          lineMenu: lineMenu,
        ),
      ),
    );
    // `a b` → `a  b`: one part that changed only in whitespace; the ignoring read lists no line, only the pair.
    const s = HunkKey(oldStart: 1, oldCount: 1, newStart: 1, newCount: 1);
    final Hunk amount = sectioned(<String>['    1    1|x', '~   2    2|a{+ +} b', '    3    3|y'], const <HunkKey>[s]);
    final FileDiff unchanged = ignoring(const <String>[], spaces: <String>['    2    2|a{+ +} b']);
    // No text of a diff line is dimmed any more (Story 10.41).
    bool anyDimmed() => find.byType(Opacity).evaluate().any((element) => (element.widget as Opacity).opacity == .62);

    testWidgets('a whitespace-only part: one hatched row with its checkbox; Show opens it in place with Hide, still '
        'hatched with the checkbox; Hide folds it again', (tester) async {
      final toggled = <HunkKey>[];
      await tester.pumpWidget(wsView(hunk: amount, ignoring: unchanged, onPart: toggled.add));
      expect(find.text('⋯ 1 line changed whitespace only'), findsOneWidget);
      expect(find.text('a  b'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsOneWidget);
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-check'));
      await tester.pump();
      expect(toggled, <HunkKey>[s]);

      await tester.tap(find.bySemanticsIdentifier('inspector-fold-show'));
      await tester.pump();
      expect(find.text('a  b'), findsOneWidget);
      expect(anyDimmed(), isFalse);
      expect(find.text('1 line with only whitespace changes'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsOneWidget, reason: 'open, it keeps the checkbox');
      expect(
        tester.getTopLeft(find.text('1 line with only whitespace changes')).dy,
        lessThan(tester.getTopLeft(find.text('a  b')).dy),
        reason: 'the row stays above its lines',
      );
      await tester.tap(find.bySemanticsIdentifier('inspector-gap-hide'));
      await tester.pump();
      expect(find.text('a  b'), findsNothing);
      expect(find.text('⋯ 1 line changed whitespace only'), findsOneWidget);

      // Without picks the row has no checkbox; side by side it is a full-width row too.
      await tester.pumpWidget(
        wsView(hunk: amount, ignoring: unchanged, picks: false, layout: DiffLayoutSetting.sideBySide),
      );
      expect(find.text('⋯ 1 line changed whitespace only'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsNothing);
    });

    testWidgets('a file that changed only in whitespace has no unchanged gap at -w (jj prints no context for it); '
        'exact it has its gaps', (tester) async {
      final exact = FileDiff(
        path: 'src/main.rs',
        kind: FileChangeKind.modified,
        fromPath: null,
        binary: false,
        modeChange: false,
        sections: amount.sections,
        hunks: <Hunk>[amount],
        removed: 1,
        added: 1,
        fingerprint: 'f',
        leftLineCount: 10,
      );
      await tester.pumpWidget(wsView(exact: exact, ignoring: unchanged));
      expect(find.text('⋯ 1 line changed whitespace only'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('inspector-unchanged-text')), findsNothing);
      await tester.pumpWidget(wsView(exact: exact, whitespace: DiffWhitespaceSetting.showAll));
      expect(find.text('7 unchanged lines'), findsOneWidget, reason: 'lines 4 to 10');
    });

    testWidgets('text_field unified: the ignoring read\'s rows, one gap of 21 with Show, no header, one checkbox; Show '
        'and Hide', (tester) async {
      await tester.pumpWidget(wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring()));
      expect(find.textContaining('@@'), findsNothing);
      expect(find.text('+4'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-part-check'), findsOneWidget, reason: 'one part: one checkbox');
      expect(
        tester.getCenter(find.bySemanticsIdentifier('inspector-part-check')).dy,
        closeTo(tester.getCenter(find.text('    return Semantics(')).dy, 2),
        reason: 'on its first changed row',
      );
      expect(find.text('21 more lines with only whitespace changes'), findsOneWidget);
      expect(find.text('        controller: controller,'), findsOneWidget, reason: 'in the context, marked');
      expect(find.text('        focusNode: focusNode,'), findsNothing, reason: 'hidden in the gap');
      expect(find.text('11'), findsNothing);
      expect(find.text('      onChanged: onChanged,'), findsNothing, reason: 'no exact line mixed in');
      expect(paintedWordMarks(tester, ZsColors.night)['        controller: controller,'], <String>['+  ']);
      expect(anyDimmed(), isFalse);

      await tester.tap(find.bySemanticsIdentifier('inspector-gap-show'));
      await tester.pump();
      expect(find.text('21 lines with only whitespace changes'), findsOneWidget);
      expect(find.text('        focusNode: focusNode,'), findsOneWidget);
      expect(find.text('11'), findsNWidgets(2), reason: 'new 11 (old 9) and old 11 (new 13), with both numbers');
      await tester.tap(find.bySemanticsIdentifier('inspector-gap-hide'));
      await tester.pump();
      expect(find.text('21 more lines with only whitespace changes'), findsOneWidget);
      expect(find.text('        focusNode: focusNode,'), findsNothing);
    });

    testWidgets('text_field: the pointer on the one checkbox draws the edge to its last row, across the gap row', (
      tester,
    ) async {
      await tester.pumpWidget(wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring()));
      bool edged(String text) =>
          ((tester
                      .widget<Container>(
                        find
                            .descendant(
                              of: find.ancestor(of: find.text(text), matching: find.byType(Stack)).first,
                              matching: find.byKey(const ValueKey<String>('inspector-line-pin')),
                            )
                            .first,
                      )
                      .foregroundDecoration!
                  as BoxDecoration)
              .border !=
          null);
      const rows = <String>[
        '    return Semantics(',
        '21 more lines with only whitespace changes',
        '        buildCounter: buildCounter,',
        '  }',
      ];
      expect(<bool>[for (final row in rows) edged(row)], <bool>[false, false, false, false]);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(find.bySemanticsIdentifier('inspector-part-check')));
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(<bool>[for (final row in rows) edged(row)], <bool>[true, true, true, false]);
      await mouse.moveTo(tester.getCenter(find.text('  }')));
      await tester.pump();
      expect(<bool>[for (final row in rows) edged(row)], <bool>[false, false, false, false]);
    });

    testWidgets('text_field: the one checkbox picks both tied sections; a pick opens the gap without Hide', (
      tester,
    ) async {
      final toggled = <HunkKey>[];
      await tester.pumpWidget(wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring(), onPart: toggled.add));
      await tester.tap(find.bySemanticsIdentifier('inspector-part-check'));
      await tester.pump();
      expect(toggled, _textFieldSections, reason: 'the same sections the old header box picked');
      await tester.pumpWidget(
        wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring(), picked: <HunkKey>{_textFieldSections.first}),
      );
      expect(find.text('21 lines with only whitespace changes'), findsOneWidget);
      expect(find.text('        focusNode: focusNode,'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-gap-hide'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-gap-show'), findsNothing);
    });

    testWidgets('text_field side by side after Show: a whitespace-only line is a pair, the right cell marks the two '
        'spaces; the gap row is full width', (tester) async {
      await tester.pumpWidget(
        wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring(), layout: DiffLayoutSetting.sideBySide),
      );
      expect(find.byKey(const ValueKey<String>('inspector-gap-band')), findsOneWidget);
      await tester.tap(find.bySemanticsIdentifier('inspector-gap-show'));
      await tester.pump();
      expect(find.text('      focusNode: focusNode,'), findsOneWidget, reason: 'the left cell');
      expect(find.text('        focusNode: focusNode,'), findsOneWidget, reason: 'the right cell');
      expect(paintedWordMarks(tester, ZsColors.night)['        focusNode: focusNode,'], <String>['+  ']);
    });

    testWidgets('a blank line inside a re-indented run: the gap counts 2, Show reveals x, the blank line and y with '
        'numbers 10, 11, 12', (tester) async {
      await tester.pumpWidget(
        wsView(
          exact: blankExact,
          ignoring: ignoring(<String>['~   1    1|[-a-]{+A+}', '    2    2|b'], spaces: blankSpaces),
          picks: false,
        ),
      );
      expect(find.text('2 more lines with only whitespace changes'), findsOneWidget);
      expect(find.bySemanticsLabel('Show 2 lines with only whitespace changes'), findsOneWidget);
      expect(find.text('11'), findsNothing);
      await tester.tap(find.bySemanticsIdentifier('inspector-gap-show'));
      await tester.pump();
      expect(find.text('2 lines with only whitespace changes'), findsOneWidget);
      expect(find.bySemanticsLabel('Hide 2 lines with only whitespace changes'), findsOneWidget);
      for (final number in <String>['10', '11', '12']) {
        expect(find.text(number), findsNWidgets(2), reason: 'line $number with both numbers: no jump');
      }
      expect(find.text('  x'), findsOneWidget);
      expect(find.text('  y'), findsOneWidget);
    });

    testWidgets('a tied part: its checkbox is three-state over its sections and toggles them together; no "2 parts" '
        'pill', (tester) async {
      final toggled = <HunkKey>[];
      bool? fold() => tester
          .widget<ZsCheckbox>(find.byWidgetPredicate((w) => w is ZsCheckbox && w.identifier == 'inspector-fold-check'))
          .value;
      await tester.pumpWidget(
        wsView(exact: tiedExact, ignoring: tiedIgnoring, picked: <HunkKey>{sB}, onPart: toggled.add),
      );
      expect(find.text('2 parts'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-part-check'), findsOneWidget);
      expect(fold(), isNull, reason: 'one of its two sections');
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-check'));
      await tester.pump();
      expect(toggled, <HunkKey>[sC], reason: 'mixed → all');

      toggled.clear();
      await tester.pumpWidget(wsView(exact: tiedExact, ignoring: tiedIgnoring, onPart: toggled.add));
      expect(fold(), isFalse);
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-check'));
      await tester.pump();
      expect(toggled, <HunkKey>[sB, sC], reason: 'none → all');

      toggled.clear();
      await tester.pumpWidget(
        wsView(exact: tiedExact, ignoring: tiedIgnoring, picked: <HunkKey>{sB, sC}, onPart: toggled.add),
      );
      expect(fold(), isTrue);
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-check'));
      await tester.pump();
      expect(toggled, <HunkKey>[sB, sC], reason: 'all → none');
    });

    testWidgets('a tied part with a real change: its part checkbox names its new-side lines, is three-state over its '
        'sections and toggles them together', (tester) async {
      // B (old 6–7 removed) and C (new 8–10 added) tie through the pairs 6↔8 and 7↔9; new 10 is a real change in C.
      const sC3 = HunkKey(oldStart: 7, oldCount: 0, newStart: 7, newCount: 3);
      final FileDiff exact = exactFile(<Hunk>[
        sectioned(
          <String>[
            '~   1    1|[-a-]{+A+}',
            '-   6     |[-  x-]',
            '-   7     |[-  y-]',
            '+        8|{+    x+}',
            '+        9|{+    y+}',
            '+       10|{+z+}',
          ],
          const <HunkKey>[sA, sB, sC3],
          before: (start: 0, end: 20),
        ),
      ]);
      final FileDiff ignoringFile = ignoring(
        <String>['~   1    1|[-a-]{+A+}', '    2    2|b', '+       10|{+z+}'],
        spaces: <String>['    6    8|  {+  +}x', '    7    9|  {+  +}y'],
      );
      final DiffBlock block = diffBlocks(exact, ignoringFile).single;
      expect(block.parts, <List<HunkKey>>[
        <HunkKey>[sA],
        <HunkKey>[sB, sC3],
      ]);
      expect(block.foldParts, isEmpty, reason: 'the tied part holds a real change');

      final toggled = <HunkKey>[];
      final Finder tiedBox = find.byWidgetPredicate(
        (w) => w is ZsCheckbox && w.identifier == 'inspector-part-check' && w.label == 'Pick lines 8–10',
      );
      await tester.pumpWidget(wsView(exact: exact, ignoring: ignoringFile, picked: <HunkKey>{sB}, onPart: toggled.add));
      expect(find.text('2 parts'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-part-check'), findsNWidgets(2));
      expect(tester.widget<ZsCheckbox>(tiedBox).value, isNull, reason: 'one of its two sections');
      await tester.tap(tiedBox);
      await tester.pump();
      expect(toggled, <HunkKey>[sC3], reason: 'mixed → all');

      toggled.clear();
      await tester.pumpWidget(wsView(exact: exact, ignoring: ignoringFile, onPart: toggled.add));
      expect(tester.widget<ZsCheckbox>(tiedBox).value, isFalse);
      await tester.tap(tiedBox);
      await tester.pump();
      expect(toggled, <HunkKey>[sB, sC3], reason: 'none → all');
    });

    testWidgets('side by side with two parts: one gutter checkbox per part, Show adds none; a tap toggles its part', (
      tester,
    ) async {
      final toggled = <HunkKey>[];
      await tester.pumpWidget(
        wsView(exact: tiedExact, ignoring: tiedIgnoring, onPart: toggled.add, layout: DiffLayoutSetting.sideBySide),
      );
      expect(find.text('2 parts'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-part-check'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsOneWidget);
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-show'));
      await tester.pump();
      expect(find.text('    x'), findsOneWidget, reason: 'the revealed pair, right cell');
      expect(find.bySemanticsIdentifier('inspector-part-check'), findsOneWidget, reason: 'its part has its box');
      await tester.tap(find.bySemanticsIdentifier('inspector-part-check'));
      await tester.pump();
      expect(toggled, <HunkKey>[sA]);
    });

    testWidgets('without picks (the operation view) gap rows have Show and no checkboxes', (tester) async {
      await tester.pumpWidget(wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring(), picks: false));
      expect(find.text('21 more lines with only whitespace changes'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-gap-show'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsNothing);
    });

    testWidgets('Story 10.40: unified, every pinned backing is opaque in both themes — a context and an added line, '
        'the no-newline row, the fold row', (tester) async {
      final Hunk lines = _hunk(<HunkLine>[_line('    1    1|x'), _line('+        2|{+end+}', newline: false)]);
      Iterable<double> alphas() => <double>[
        for (final Element pin in find.byKey(const ValueKey<String>('inspector-line-pin')).evaluate())
          (pin.widget as Container).color!.a,
      ];
      // The opaque backing would hide the row's hatch, so the fold row's pin paints it again.
      final Finder hatchedPins = find.descendant(
        of: find.byKey(const ValueKey<String>('inspector-line-pin')),
        matching: find.byWidgetPredicate(
          (widget) => widget is CustomPaint && widget.painter.runtimeType.toString() == '_FoldHatchPainter',
        ),
      );
      for (final ZsTheme theme in ZsTheme.values) {
        final appearance = ZsAppearance(theme: theme);
        await tester.pumpWidget(
          wsView(hunk: lines, whitespace: DiffWhitespaceSetting.showAll, picks: false, appearance: appearance),
        );
        expect(find.text(noNewlineMarker), findsOneWidget);
        expect(find.byKey(const ValueKey<String>('inspector-line-pin')), findsNWidgets(3));
        expect(alphas(), everyElement(1.0), reason: '${theme.name}: the lines');
        expect(hatchedPins, findsNothing, reason: '${theme.name}: lines have no hatch');
        await tester.pumpWidget(wsView(hunk: amount, ignoring: unchanged, appearance: appearance));
        expect(find.text('⋯ 1 line changed whitespace only'), findsOneWidget);
        expect(alphas(), everyElement(1.0), reason: '${theme.name}: the fold row');
        expect(hatchedPins, findsOneWidget, reason: '${theme.name}: the hatch runs under the fold row\'s pin too');
      }
    });

    testWidgets('Story 10.40: with a line menu, a right-click on a fold row or a no-newline row throws nothing and '
        'opens nothing', (tester) async {
      final lines = <int>[];
      List<ZsMenuEntry> menu(BuildContext context, int line) {
        lines.add(line);
        return const <ZsMenuEntry>[ZsMenuItem(label: 'Line row')];
      }

      Future<void> rightClick(Finder finder) async {
        await tester.tap(finder, buttons: kSecondaryButton);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
        expect(find.text('Line row'), findsNothing);
      }

      await tester.pumpWidget(wsView(hunk: amount, ignoring: unchanged, picks: false, lineMenu: menu));
      await rightClick(find.text('⋯ 1 line changed whitespace only'));
      final Hunk end = _hunk(<HunkLine>[_line('+        1|{+end+}', newline: false)]);
      await tester.pumpWidget(
        wsView(hunk: end, whitespace: DiffWhitespaceSetting.showAll, picks: false, lineMenu: menu),
      );
      await rightClick(find.text(noNewlineMarker));
      expect(lines, isEmpty);
    });

    test('Story 10.40: the options menu notes the repo config under the context rows when it sets them', () {
      final AppLocalizations strings = platformStrings();
      List<ZsMenuEntry> entries({required bool fromRepo}) => diffOptionsEntries(
        strings,
        whitespace: DiffWhitespaceSetting.showAll,
        onWhitespaceChanged: (_) {},
        contextLines: 7,
        onContextLinesChanged: (_) {},
        contextFromRepo: fromRepo,
      );
      const note = "Set in this repository's config, which wins";
      final List<ZsMenuEntry> repo = entries(fromRepo: true);
      final int at = repo.indexWhere((entry) => entry is ZsMenuNote && entry.label == note);
      expect(repo[at - 1], isA<ZsMenuItem>().having((item) => item.label, 'label', '20'), reason: 'under the rows');
      expect(repo[at + 1], isA<ZsMenuSeparator>());
      expect(
        entries(fromRepo: false).whereType<ZsMenuNote>().where((n) => n.label == note),
        isEmpty,
      );
    });

    testWidgets('a picked whitespace-only part shows its line, its row open and checked, without Hide; nothing is '
        'dimmed', (tester) async {
      for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
        await tester.pumpWidget(wsView(hunk: amount, ignoring: unchanged, picked: <HunkKey>{s}, layout: layout));
        expect(find.text('a  b'), findsWidgets, reason: layout.name);
        expect(find.text('1 line with only whitespace changes'), findsOneWidget, reason: layout.name);
        expect(find.text('⋯ 1 line changed whitespace only'), findsNothing, reason: layout.name);
        expect(find.bySemanticsIdentifier('inspector-gap-hide'), findsNothing, reason: layout.name);
        expect(find.bySemanticsLabel('Unpick these whitespace-only lines'), findsOneWidget, reason: layout.name);
        expect(anyDimmed(), isFalse, reason: layout.name);
      }
    });

    testWidgets('a file left with no block reads "Only whitespace changed in this file."', (tester) async {
      final Hunk hunk = _hunk(<HunkLine>[_line('-   2     |[-  y-]'), _line('+        2|{+y+}')]);
      await tester.pumpWidget(wsView(hunk: hunk, ignoring: ignoring(const <String>[]), picks: false));
      expect(find.text('Only whitespace changed in this file.'), findsOneWidget);
      await tester.pumpWidget(wsView(hunk: hunk, picks: false, whitespace: DiffWhitespaceSetting.showAll));
      expect(find.text('Only whitespace changed in this file.'), findsNothing);
      expect(find.text('  y'), findsOneWidget);
      expect(find.text('y'), findsOneWidget);
    });

    testWidgets('the options button: last in the bar, named by the mode and context, accent off the defaults; its '
        'rows call back', (tester) async {
      final whitespaces = <DiffWhitespaceSetting>[];
      final contexts = <int>[];
      Finder button() => find.bySemanticsIdentifier('inspector-diff-options');
      Color glyph() => tester
          .widget<ZanshinIcon>(
            find.descendant(
              of: find.byType(ZsMenuButton),
              matching: find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.viewOptions),
            ),
          )
          .color!;
      await tester.pumpWidget(
        wsView(
          hunk: amount,
          whitespace: DiffWhitespaceSetting.showAll,
          onWhitespace: whitespaces.add,
          onContext: contexts.add,
        ),
      );
      expect(find.bySemanticsLabel('Diff options — Show all whitespace, 3 context lines'), findsOneWidget);
      expect(
        tester.getRect(button()).right,
        greaterThan(tester.getRect(find.bySemanticsIdentifier('inspector-diff-layout')).right),
        reason: 'the last control',
      );
      final Color rest = glyph();
      expect(rest, isNot(ZsColors.night.accent));
      // The menu's entrance, a row's activation blink and its exit run on timers.
      Future<void> settle() async {
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
      }

      await tester.tap(button());
      await settle();
      expect(find.text('jj diff -w'), findsOneWidget);
      await tester.tap(find.text('Ignore all whitespace'));
      await settle();
      expect(whitespaces, <DiffWhitespaceSetting>[DiffWhitespaceSetting.ignoreAll]);
      await tester.tap(button());
      await settle();
      await tester.tap(find.text('10'));
      await settle();
      expect(contexts, <int>[10]);

      await tester.pumpWidget(wsView(hunk: amount, ignoring: unchanged, context: 5));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Diff options — Ignore all whitespace, 5 context lines'), findsOneWidget);
      expect(glyph(), ZsColors.night.accent);
      await tester.pumpWidget(wsView(hunk: amount, whitespace: DiffWhitespaceSetting.showAll, context: null));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Diff options — Show all whitespace, context lines unreadable'), findsOneWidget);
    });

    testWidgets('side by side with picks, a folded part carries its checkbox; a tap toggles its part', (tester) async {
      final toggled = <HunkKey>[];
      await tester.pumpWidget(
        wsView(hunk: amount, ignoring: unchanged, onPart: toggled.add, layout: DiffLayoutSetting.sideBySide),
      );
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsOneWidget);
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-check'));
      await tester.pump();
      expect(toggled, <HunkKey>[s]);
    });

    testWidgets('the options glyph is accent at show all with 5 context lines', (tester) async {
      await tester.pumpWidget(wsView(hunk: amount, whitespace: DiffWhitespaceSetting.showAll, context: 5));
      await tester.pumpAndSettle();
      final ZanshinIcon glyph = tester.widget(
        find.descendant(
          of: find.byType(ZsMenuButton),
          matching: find.byWidgetPredicate((w) => w is ZanshinIcon && w.name == ZI.viewOptions),
        ),
      );
      expect(glyph.color, ZsColors.night.accent);
    });

    testWidgets('an opened fold folds again when the mode changes', (tester) async {
      await tester.pumpWidget(wsView(hunk: amount, ignoring: unchanged, picks: false));
      await tester.tap(find.bySemanticsIdentifier('inspector-fold-show'));
      await tester.pump();
      expect(find.text('a  b'), findsOneWidget);
      await tester.pumpWidget(
        wsView(
          hunk: amount,
          ignoring: unchanged,
          picks: false,
          whitespace: DiffWhitespaceSetting.ignoreChangesInAmount,
        ),
      );
      await tester.pump();
      expect(find.text('a  b'), findsNothing);
      expect(find.text('⋯ 1 line changed whitespace only'), findsOneWidget);
    });

    testWidgets('without onWhitespaceChanged there is no options menu', (tester) async {
      await tester.pumpWidget(view(_file(hunks: <Hunk>[amount])));
      expect(find.bySemanticsIdentifier('inspector-diff-options'), findsNothing);
    });
  });

  testWidgets('without onViewedChanged there is no Viewed toggle and a viewed file does not fold (Story 10.29)', (
    tester,
  ) async {
    Finder node(String identifier) => find.bySemanticsIdentifier(identifier);
    await tester.pumpWidget(view(_file()));
    expect(node('inspector-viewed'), findsOneWidget);
    await tester.pumpWidget(
      shellHost(
        SizedBox(
          width: 420,
          child: InspectorDiffView(
            path: 'src/main.rs',
            diff: _file(
              hunks: <Hunk>[
                _hunk(<HunkLine>[_line('+        1|{+x+}')]),
              ],
            ),
            error: null,
            viewed: true,
            layout: DiffLayoutSetting.unified,
            onLayoutChanged: (_) {},
          ),
        ),
      ),
    );
    expect(node('inspector-viewed'), findsNothing);
    expect(node('inspector-diff-folded'), findsNothing);
    expect(find.text('x'), findsOneWidget);
  });

  test('Story 10.39: a line\'s new-side number; a removed line takes where it stood', () {
    Hunk of(List<HunkLine> lines) => Hunk(
      before: (start: 39, end: 42),
      after: (start: 39, end: 41),
      symbol: null,
      sections: const <HunkKey>[],
      removed: 0,
      added: 0,
      lines: lines,
    );
    const context = HunkLine(kind: HunkLineKind.context, text: 'a\n', left: 40, right: 40);
    const removed = HunkLine(kind: HunkLineKind.removed, text: 'b\n', left: 41);
    const next = HunkLine(kind: HunkLineKind.context, text: 'c\n', left: 42, right: 41);
    expect(diffNewLineAt(of(const <HunkLine>[context, removed, next]), 1), 41, reason: 'the next line\'s');
    expect(diffNewLineAt(of(const <HunkLine>[context, removed]), 1), 41, reason: 'after the last: last new + 1');
    expect(diffNewLineAt(of(const <HunkLine>[removed]), 0), 40, reason: "no new line: the hunk's new start");
    expect(diffNewLineAt(of(const <HunkLine>[context, removed, next]), 0), 40);
    // A rebuilt side-by-side cell finds its line by its left number.
    const cell = HunkLine(kind: HunkLineKind.removed, text: 'b', left: 41);
    expect(diffNewLineOf(of(const <HunkLine>[context, removed, next]), cell), 41);
  });
}
