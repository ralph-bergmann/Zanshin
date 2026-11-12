// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting;
import 'package:zanshin_ui/zanshin_ui.dart' show ZsAppearance, ZsColors, ZsScrollArea, ZsTheme;

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

    test('Words (Story 5.11): a mark exactly where a segment is not equal, the fill-only rule off', () {
      List<(String, SegmentKind)> words(String spec) {
        final HunkLine line = _line(spec);
        return <(String, SegmentKind)>[
          for (final m in diffWordMarks(line, marks: DiffMarks.words)) (m.range.textInside(line.text), m.kind),
        ];
      }

      // An added line with only indentation unchanged: marked, not fill-only.
      expect(words('+       10|    {+await openWizard(tester, size: phone);+}'), <(String, SegmentKind)>[
        ('await openWizard(tester, size: phone);', SegmentKind.added),
      ]);
      expect(marks('+       10|    {+await openWizard(tester, size: phone);+}'), isEmpty, reason: 'jj: fill only');
      expect(words("-  10     |  testWidgets('a step', (tester) async {"), isEmpty);
      expect(words('-   9     |  [-// The phone layout is checked on a device.-]'), <(String, SegmentKind)>[
        ('// The phone layout is checked on a device.', SegmentKind.removed),
      ]);
      // A blank line, and a line whose only unchanged text is blank, keep exactly their segments' marks.
      expect(words('+       12|'), isEmpty);
      expect(words('+        1|  {+x+}  '), <(String, SegmentKind)>[('x', SegmentKind.added)]);
      expect(words('#         |<<<<<<< Created conflict'), isEmpty);
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
    DiffMarks marks = DiffMarks.jj,
  }) => shellHost(
    SizedBox(
      width: 420,
      child: InspectorDiffView(
        path: 'src/main.rs',
        diff: diff,
        marks: marks,
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
      expect(ink(' 9'), colors.rem, reason: 'two columns: the hunk\'s largest number is 10');
      // A context line: faint numbers, muted text.
      expect(ink('2453'), colors.textFaint);
      expect(tester.widget<Text>(find.text('        .into_inner()')).style!.color, colors.textMuted);
      // No sigil column.
      expect(find.text('−'), findsNothing);
      expect(find.text('+'), findsNothing);
    });
  }

  testWidgets('Words (Story 5.11): the widget-test block draws one mark on the old and new testWidgets lines, whole '
      'new lines, no underline', (tester) async {
    const block = <String>[
      "-  10     |  testWidgets('shows Funktion speichern instead of Weiter on the last [-step',-] (tester) async {",
      '+       10|    {+await openWizard(tester, size: phone);+}',
      '+       12|',
      '+       13|    {+for (var i = 0; i < 3; i++) {+}',
      ("+       23|  testWidgets('shows Funktion speichern instead of Weiter on the last {+step on a tablet',+} (tester) "
          'async {'),
    ];
    final FileDiff file = _file(
      hunks: <Hunk>[
        _hunk(<HunkLine>[for (final s in block) _line(s)]),
      ],
    );
    await tester.pumpWidget(view(file, marks: DiffMarks.words));
    expect(paintedWordMarks(tester, ZsColors.resolve(const ZsAppearance())), <String, List<String>>{
      "  testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {": <String>[
        "-step',",
      ],
      '    await openWizard(tester, size: phone);': <String>['+await openWizard(tester, size: phone);'],
      '    for (var i = 0; i < 3; i++) {': <String>['+for (var i = 0; i < 3; i++) {'],
      "  testWidgets('shows Funktion speichern instead of Weiter on the last step on a tablet', (tester) async {":
          <String>["+step on a tablet',"],
    });
    for (final RichText text in tester.widgetList<RichText>(find.byType(RichText))) {
      expect(text.text.toStringDeep(), isNot(contains('underline')));
    }
    // Side by side draws the same marks from the same lines.
    await tester.pumpWidget(view(file, marks: DiffMarks.words, layout: DiffLayoutSetting.sideBySide));
    expect(paintedWordMarks(tester, ZsColors.resolve(const ZsAppearance())), <String, List<String>>{
      "  testWidgets('shows Funktion speichern instead of Weiter on the last step', (tester) async {": <String>[
        "-step',",
      ],
      '    await openWizard(tester, size: phone);': <String>['+await openWizard(tester, size: phone);'],
      '    for (var i = 0; i < 3; i++) {': <String>['+for (var i = 0; i < 3; i++) {'],
      "  testWidgets('shows Funktion speichern instead of Weiter on the last step on a tablet', (tester) async {":
          <String>["+step on a tablet',"],
    });
    // The jj style draws the same added lines fill-only.
    await tester.pumpWidget(view(file));
    expect(paintedWordMarks(tester, ZsColors.resolve(const ZsAppearance())).keys, hasLength(2));
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
    }
  });

  testWidgets('a picked hunk keeps its checkbox and accent header', (tester) async {
    await tester.pumpWidget(view(matrix(), hunkPicked: (_) => true));
    expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsNWidgets(0), reason: 'no sections');
    await tester.pumpWidget(
      view(
        _file(
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
        ),
        hunkPicked: (_) => true,
      ),
    );
    expect(find.bySemanticsIdentifier('inspector-hunk-check'), findsOneWidget);
    final Container header = tester.widget(find.byKey(const ValueKey<String>('inspector-hunk-header')));
    expect(header.color, ZsColors.night.accentSoftHi);
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
}
