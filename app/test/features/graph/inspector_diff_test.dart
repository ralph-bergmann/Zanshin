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

HunkLine _ctx(String text) => HunkLine(kind: HunkLineKind.context, text: '$text\n');
HunkLine _rem(String text) => HunkLine(kind: HunkLineKind.removed, text: '$text\n');
HunkLine _add(String text) => HunkLine(kind: HunkLineKind.added, text: '$text\n');

/// A line in `hunks.rs`'s notation of jj's segments: a sigil (`-`, `+` or ` `), then the text with `[-…-]` around a
/// removed run and `{+…+}` around an added one; a context line is one equal segment.
HunkLine _marked(String line) {
  final HunkLineKind kind = switch (line[0]) {
    '-' => HunkLineKind.removed,
    '+' => HunkLineKind.added,
    _ => HunkLineKind.context,
  };
  final String body = line.substring(1);
  final List<String> parts = switch (kind) {
    HunkLineKind.removed => body.split(RegExp(r'\[-|-\]')),
    HunkLineKind.added => body.split(RegExp(r'\{\+|\+\}')),
    HunkLineKind.context => <String>[body],
  };
  final SegmentKind changed = kind == HunkLineKind.added ? SegmentKind.added : SegmentKind.removed;
  return HunkLine(
    kind: kind,
    text: parts.join(),
    segments: <Segment>[
      for (var i = 0; i < parts.length; i++)
        if (parts[i].isNotEmpty) Segment(kind: i.isOdd ? changed : SegmentKind.equal, text: parts[i]),
    ],
  );
}

// Story 10.32's I/O matrix: the segments jj-lib gave Ralph's three examples before lines were paired (the comment's
// second line as `jj diff --git` 0.47.0 underlines it). They test the drawing rule, not what the backend sends today.
const _expression = <String>[
  '-    child: Text(isLastStep ? [-s.functionWizard_save-] : s.functionWizard_next),\n',
  '+    child: Text(isLastStep ? {+saveLabel+} : s.functionWizard_next),\n',
];
const _split = <String>[
  '-    Expanded(child: _Line(color: isFirst ? null : lineColor)),\n',
  '+    Expanded({+\n+}',
  '+{+      +}child: _Line(color: isFirst ? null : lineColor){+,\n+}',
  '+{+    +}),\n',
  '     DecoratedBox(\n',
];
const _comment = <String>[
  '-  padding: Spacing.[-spacing8-],\n',
  '+  {+// Small side padding.\n+}',
  '+{+  +}padding: Spacing.{+spacing2+},\n',
  '   child: label,\n',
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

  group('pairSideBySide', () {
    test('3 removed then 2 added: 3 rows, the 3rd right cell empty', () {
      final List<(HunkLine?, HunkLine?)> rows = pairSideBySide(<HunkLine>[
        _rem('a'),
        _rem('b'),
        _rem('c'),
        _add('x'),
        _add('y'),
      ]);
      expect(rows, hasLength(3));
      expect(rows.map((r) => (r.$1?.text, r.$2?.text)), <(String?, String?)>[
        ('a\n', 'x\n'),
        ('b\n', 'y\n'),
        ('c\n', null),
      ]);
    });

    test('a context line fills both cells; an added run without removals has empty left cells', () {
      final HunkLine context = _ctx('k');
      final List<(HunkLine?, HunkLine?)> rows = pairSideBySide(<HunkLine>[context, _add('x'), context]);
      expect(rows, hasLength(3));
      expect(rows[0], (context, context));
      expect(rows[1].$1, isNull);
      expect(rows[1].$2!.text, 'x\n');
    });
  });

  group('diffWordMarks (Story 10.32)', () {
    List<TextRange> marks(String line) => diffWordMarks(_marked(line));

    test('a rewritten expression marks exactly the changed expression on each side', () {
      expect(marks(_expression[0]), const <TextRange>[TextRange(start: 29, end: 50)]);
      expect(marks(_expression[1]), const <TextRange>[TextRange(start: 29, end: 38)]);
      final HunkLine removed = _marked(_expression[0]);
      expect(diffWordMarks(removed).single.textInside(removed.text), 's.functionWizard_save');
    });

    test('a call split over three lines marks only the new indentation and the comma, never a line break', () {
      expect(marks(_split[0]), isEmpty, reason: 'the removed line has no changed run');
      expect(marks(_split[1]), isEmpty, reason: 'its changed run is only the line break');
      expect(marks(_split[2]), const <TextRange>[TextRange(start: 0, end: 6), TextRange(start: 53, end: 54)]);
      expect(marks(_split[3]), const <TextRange>[TextRange(start: 0, end: 4)]);
      expect(marks(_split[4]), isEmpty, reason: 'a context line');
    });

    test('an inserted comment line keeps no marks; the line below marks its indentation and the word', () {
      expect(marks(_comment[0]), const <TextRange>[TextRange(start: 19, end: 27)]);
      expect(marks(_comment[1]), isEmpty, reason: 'its unchanged text is only blanks');
      expect(marks(_comment[2]), const <TextRange>[TextRange(start: 0, end: 2), TextRange(start: 19, end: 27)]);
    });

    test('a context line, a line without segments and a new or deleted file\'s line keep none', () {
      expect(marks(' x\n'), isEmpty);
      expect(diffWordMarks(_add('x')), isEmpty, reason: 'segments: []');
      expect(marks('+{+fn main() {\n+}'), isEmpty);
      expect(marks('-[-fn main() {\n-]'), isEmpty);
    });

    test('CRLF: the mark stops before \\r and \\n', () {
      expect(marks('+a{+b\r\n+}'), const <TextRange>[TextRange(start: 1, end: 2)]);
    });

    test('a changed run of trailing blanks is marked like any run', () {
      expect(marks('+x{+  +}\n'), const <TextRange>[TextRange(start: 1, end: 3)]);
    });
  });

  Widget view(
    FileDiff? diff, {
    DiffLayoutSetting layout = DiffLayoutSetting.unified,
    ZsAppearance appearance = const ZsAppearance(),
  }) => shellHost(
    SizedBox(
      width: 420,
      child: InspectorDiffView(
        path: 'src/main.rs',
        diff: diff,
        error: null,
        onViewedChanged: (_) {},
        layout: layout,
        onLayoutChanged: (_) {},
      ),
    ),
    appearance: appearance,
  );

  // Every matrix row in one file; the context line without segments shows the 10.24 look.
  FileDiff matrix() => _file(
    hunks: <Hunk>[
      _hunk(<HunkLine>[for (final String line in _expression) _marked(line)]),
      _hunk(<HunkLine>[for (final String line in _split) _marked(line)]),
      _hunk(<HunkLine>[
        for (final String line in _comment) _marked(line),
        _ctx('no segments'),
        _marked('+a{+b\r\n+}'),
        _marked('+x{+  +}\n'),
      ]),
    ],
  );

  for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
    for (final ZsTheme theme in ZsTheme.values) {
      testWidgets('Story 10.32: $layout on ${theme.name} paints exactly the matrix\'s word marks', (tester) async {
        final appearance = ZsAppearance(theme: theme);
        await tester.pumpWidget(view(matrix(), layout: layout, appearance: appearance));
        expect(paintedWordMarks(tester, ZsColors.resolve(appearance)), <String, List<String>>{
          '    child: Text(isLastStep ? s.functionWizard_save : s.functionWizard_next),': <String>[
            's.functionWizard_save',
          ],
          '    child: Text(isLastStep ? saveLabel : s.functionWizard_next),': <String>['saveLabel'],
          '      child: _Line(color: isFirst ? null : lineColor),': <String>['      ', ','],
          '    ),': <String>['    '],
          '  padding: Spacing.spacing8,': <String>['spacing8'],
          '  padding: Spacing.spacing2,': <String>['  ', 'spacing2'],
          'ab': <String>['b'],
          'x  ': <String>['  '],
        });
        final Finder comment = find.text('  // Small side padding.');
        expect(comment, findsOneWidget);
        expect(
          find.ancestor(of: comment, matching: find.byType(DiffWordMarks)),
          findsNothing,
          reason: 'a plain line',
        );
        // The trailing blanks lie inside their paragraph, so clipping to it hides none of their mark.
        final RenderParagraph trailing = tester.renderObject(
          find.descendant(
            of: find.ancestor(of: find.text('x  '), matching: find.byType(DiffWordMarks)),
            matching: find.byType(RichText),
          ),
        );
        expect(
          trailing.getBoxesForSelection(const TextSelection(baseOffset: 1, extentOffset: 3)).single.right,
          lessThanOrEqualTo(trailing.size.width),
        );
      });
    }
  }

  testWidgets('Story 10.32: a new fill or new marks repaint the line; equal ones do not', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_marked('+  x = {+42+};\n')]),
          ],
        ),
      ),
    );
    // The pumped line's own fill and marks, set again.
    final RenderDiffWordMarks box = tester.renderObject<RenderDiffWordMarks>(find.byType(DiffWordMarks))
      ..color = ZsColors.night.addWordBg
      ..marks = const <TextRange>[TextRange(start: 6, end: 8)];
    expect(box.debugNeedsPaint, isFalse, reason: 'the same fill and marks');
    box.color = ZsColors.night.remWordBg;
    expect(box.debugNeedsPaint, isTrue, reason: 'a new fill');
    await tester.pump();
    expect(box.debugNeedsPaint, isFalse);
    box.marks = const <TextRange>[TextRange(start: 2, end: 3)];
    expect(box.debugNeedsPaint, isTrue, reason: 'new marks');
  });

  testWidgets('Story 10.32: a side-by-side cell clips a mark at its edge', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_marked('+xxxxx{+${'y' * 60}+}z\n')]),
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

  testWidgets('Story 10.32: a selection across a marked line paints over the mark; the glyphs keep their colours', (
    tester,
  ) async {
    // A line short enough to drag across inside the hunk's width.
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_marked('+  x = {+42+};\n')]),
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
      '  x = 42;': <String>['42'],
    });
  });

  testWidgets('the hunk header shows the symbol when set, nothing after the range when null', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_rem('old'), _add('new')], symbol: 'fn main()'),
            _hunk(<HunkLine>[_ctx('same')], before: (start: 9, end: 10)),
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
            _hunk(<HunkLine>[_add('let message = "a line long enough to leave the inspector on its right edge";')]),
          ],
        ),
      ),
    );
    expect(extent(), greaterThan(0));

    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_add('short')]),
          ],
        ),
      ),
    );
    expect(extent(), 0);
  });

  testWidgets('side by side draws one row per pair', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          hunks: <Hunk>[
            _hunk(<HunkLine>[_rem('a'), _rem('b'), _rem('c'), _add('x'), _add('y')]),
          ],
        ),
        layout: DiffLayoutSetting.sideBySide,
      ),
    );
    final Finder split = find.byKey(const ValueKey<String>('inspector-diff-split'));
    expect(find.descendant(of: split, matching: find.byType(IntrinsicHeight)), findsNWidgets(3));
    expect(find.text('c'), findsOneWidget);
  });

  testWidgets('a CRLF line loses its \\r; a last line without its newline gets jj\'s marker in both layouts', (
    tester,
  ) async {
    const crlf = HunkLine(kind: HunkLineKind.removed, text: 'dos\r\n');
    const last = HunkLine(kind: HunkLineKind.added, text: 'end');
    for (final DiffLayoutSetting layout in DiffLayoutSetting.values) {
      await tester.pumpWidget(
        view(
          _file(
            hunks: <Hunk>[
              _hunk(const <HunkLine>[crlf, last]),
            ],
          ),
          layout: layout,
        ),
      );
      expect(find.text('dos'), findsOneWidget, reason: '$layout');
      expect(find.text('end'), findsOneWidget);
      expect(find.text(noNewlineMarker), findsOneWidget, reason: '$layout');
    }
  });

  testWidgets('a mode change with hunks shows the mode note above them', (tester) async {
    await tester.pumpWidget(
      view(
        _file(
          modeChange: true,
          hunks: <Hunk>[
            _hunk(<HunkLine>[_add('x')]),
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
                _hunk(<HunkLine>[_add('x')]),
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
