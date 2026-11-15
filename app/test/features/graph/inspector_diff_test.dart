// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
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

FileDiff _file({List<Hunk> hunks = const <Hunk>[], bool binary = false, bool modeChange = false}) => FileDiff(
  path: 'src/main.rs',
  kind: FileChangeKind.modified,
  fromPath: null,
  binary: binary,
  modeChange: modeChange,
  sections: const [],
  hunks: hunks,
  removed: 0,
  added: 0,
  fingerprint: 'f',
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

  group('hunkHeader', () {
    test('1-based starts and lengths, U+2212 for the minus', () {
      expect(hunkHeader(_hunk(const <HunkLine>[])), '@@ −5,3 +5,2 @@');
    });

    test('an empty range keeps its 0-based start (jj\'s to_line_number)', () {
      expect(hunkHeader(_hunk(const <HunkLine>[], before: (start: 0, end: 0))), '@@ −0,0 +5,2 @@');
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
    bool? Function(Hunk hunk)? hunkPicked,
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
        hunkPicked: hunkPicked,
        onHunkToggled: (_) {},
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

  testWidgets('a picked hunk keeps its checkbox and accent header', (tester) async {
    await tester.pumpWidget(view(matrix(), hunkPicked: (_) => true));
    expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsNWidgets(0), reason: 'no sections');
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
    await tester.pumpWidget(view(picked, hunkPicked: (_) => true));
    expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsOneWidget);
    Color? headerColor() => tester.widget<Container>(find.byKey(const ValueKey<String>('inspector-hunk-header'))).color;
    const ZsColors colors = ZsColors.night;
    // Unified, the pinned header sits on the opaque base (Story 10.40).
    expect(headerColor(), Color.alphaBlend(colors.accentSoftHi, Color.alphaBlend(colors.codeBg, colors.flBgSolid)));
    // Side by side does not pin: the band stays as the DS draws it.
    await tester.pumpWidget(view(picked, hunkPicked: (_) => true, layout: DiffLayoutSetting.sideBySide));
    expect(headerColor(), colors.accentSoftHi);
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

  testWidgets('the hunk header shows the symbol when set, nothing after the range when null', (tester) async {
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
    expect(find.text('fn main()'), findsOneWidget);
    expect(find.text('@@ −5,3 +5,2 @@'), findsOneWidget);
    expect(find.text('@@ −10,1 +5,2 @@'), findsOneWidget);
    expect(find.text('+1'), findsOneWidget);
    expect(find.text('−1'), findsOneWidget);
    expect(find.text('old'), findsOneWidget, reason: 'no trailing newline');
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
    }) => shellHost(
      SizedBox(
        width: 420,
        child: InspectorDiffView(
          path: 'src/main.rs',
          diff: _file(hunks: <Hunk>[parts(sections)]),
          error: null,
          layout: layout,
          onLayoutChanged: (_) {},
          hunkPicked: (_) => picked.isEmpty ? false : (picked.length == sections.length ? true : null),
          onHunkToggled: (_) {},
          partPicked: picked.contains,
          onPartToggled: onPart ?? (_) {},
        ),
      ),
    );
    Finder partBoxes() => find.bySemanticsIdentifier('inspector-part-check');

    testWidgets('three parts: the pill, one checkbox per part, the mixed header and the edge on the picked part', (
      tester,
    ) async {
      final toggled = <HunkKey>[];
      await tester.pumpWidget(picks(const <HunkKey>[s1, s2, s3], picked: <HunkKey>{s2}, onPart: toggled.add));
      expect(find.text('3 parts'), findsOneWidget);
      expect(partBoxes(), findsNWidgets(3));
      const ZsColors colors = ZsColors.night;
      final Container header = tester.widget(find.byKey(const ValueKey<String>('inspector-hunk-header')));
      expect(
        header.color,
        Color.alphaBlend(
          Color.alphaBlend(colors.accent.withValues(alpha: .12), colors.codeBg),
          Color.alphaBlend(colors.codeBg, colors.flBgSolid),
        ),
        reason: 'some; pinned, on the opaque base',
      );
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
      expect(find.text('3 parts'), findsOneWidget);
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

      // Without parts, side by side keeps one edge for the whole hunk, on when picked.
      for (final (Set<HunkKey> picked, bool on) in <(Set<HunkKey>, bool)>[
        (<HunkKey>{s1}, true),
        (<HunkKey>{}, false),
      ]) {
        await tester.pumpWidget(picks(const <HunkKey>[s1], picked: picked, layout: DiffLayoutSetting.sideBySide));
        final DecoratedBox edge = tester.widget(find.byKey(const ValueKey<String>('inspector-hunk-edge')));
        expect((edge.decoration as BoxDecoration).border != null, on);
      }
    });

    testWidgets('one part: no pill, no gutter, the hunk checkbox as before', (tester) async {
      await tester.pumpWidget(picks(const <HunkKey>[s1]));
      expect(find.byKey(const ValueKey<String>('inspector-hunk-parts')), findsNothing);
      expect(partBoxes(), findsNothing);
      expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsOneWidget);
    });

    testWidgets('scrolled fully right, a short line keeps its numbers and part checkbox at the left edge; the header '
        'stays in view', (tester) async {
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
              hunkPicked: (_) => false,
              onHunkToggled: (_) {},
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
      final Rect header = tester.getRect(find.byKey(const ValueKey<String>('inspector-hunk-header')));
      expect(header.left, closeTo(left + 1, 1), reason: 'the header stays in view');
      expect(
        header.width,
        closeTo(tester.getSize(find.byType(InspectorDiffView)).width - 2, 1),
        reason: 'as wide as the visible area (the well less its 1 px border on each side)',
      );
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
      expect(hunkHeader(block.hunk), '@@ −1,35 +1,38 @@');
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
      ValueChanged<Hunk>? onHunk,
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
          hunkPicked: picks
              ? (hunk) =>
                    hunk.sections.every(picked.contains) ? true : (hunk.sections.any(picked.contains) ? null : false)
              : null,
          onHunkToggled: onHunk ?? (_) {},
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
      expect(find.text('⋯ 1 line changed whitespace only · Show'), findsOneWidget);
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
      expect(find.text('⋯ 1 line changed whitespace only · Show'), findsOneWidget);

      // Without picks the row has no checkbox; side by side it is a full-width row too.
      await tester.pumpWidget(
        wsView(hunk: amount, ignoring: unchanged, picks: false, layout: DiffLayoutSetting.sideBySide),
      );
      expect(find.text('⋯ 1 line changed whitespace only · Show'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-fold-check'), findsNothing);
    });

    testWidgets('text_field unified: the ignoring read\'s rows, one gap of 21 with Show, +4 −1, one checkbox; Show and '
        'Hide', (tester) async {
      await tester.pumpWidget(wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring()));
      expect(find.text('@@ −1,35 +1,38 @@'), findsOneWidget);
      expect(find.text('+4'), findsOneWidget);
      expect(find.text('−1'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsOneWidget);
      expect(find.bySemanticsIdentifier('inspector-part-check'), findsNothing, reason: 'one part: no part checkboxes');
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

    testWidgets('text_field: the one checkbox picks both tied sections; a pick opens the gap without Hide', (
      tester,
    ) async {
      final toggled = <Hunk>[];
      await tester.pumpWidget(wsView(exact: _textFieldFile(), ignoring: _textFieldIgnoring(), onHunk: toggled.add));
      await tester.tap(find.bySemanticsIdentifier('inspector-hunk-check'));
      await tester.pump();
      expect(toggled.single.sections, _textFieldSections);
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

    testWidgets('a tied part: its checkbox is three-state over its sections and toggles them together; two parts '
        'show "2 parts"', (tester) async {
      final toggled = <HunkKey>[];
      bool? fold() => tester
          .widget<ZsCheckbox>(find.byWidgetPredicate((w) => w is ZsCheckbox && w.identifier == 'inspector-fold-check'))
          .value;
      await tester.pumpWidget(
        wsView(exact: tiedExact, ignoring: tiedIgnoring, picked: <HunkKey>{sB}, onPart: toggled.add),
      );
      expect(find.text('2 parts'), findsOneWidget);
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
      expect(find.text('2 parts'), findsOneWidget);
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
      expect(find.text('2 parts'), findsOneWidget);
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
        'the no-newline row, the fold row, the hunk header', (tester) async {
      final Hunk lines = _hunk(<HunkLine>[_line('    1    1|x'), _line('+        2|{+end+}', newline: false)]);
      Iterable<double> alphas() => <double>[
        for (final Element pin in find.byKey(const ValueKey<String>('inspector-line-pin')).evaluate())
          (pin.widget as Container).color!.a,
        tester.widget<Container>(find.byKey(const ValueKey<String>('inspector-hunk-header'))).color!.a,
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
        expect(find.text('⋯ 1 line changed whitespace only · Show'), findsOneWidget);
        expect(alphas(), everyElement(1.0), reason: '${theme.name}: the fold row');
        expect(hatchedPins, findsOneWidget, reason: '${theme.name}: the hatch runs under the fold row\'s pin too');
      }
    });

    testWidgets('Story 10.40: with a line menu, a right-click on a fold row, a no-newline row or the hunk header '
        'throws nothing and opens nothing', (tester) async {
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
      await rightClick(find.text('⋯ 1 line changed whitespace only · Show'));
      await rightClick(find.byKey(const ValueKey<String>('inspector-hunk-header')));
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
        expect(find.text('⋯ 1 line changed whitespace only · Show'), findsNothing, reason: layout.name);
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
      expect(find.text('⋯ 1 line changed whitespace only · Show'), findsOneWidget);
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
