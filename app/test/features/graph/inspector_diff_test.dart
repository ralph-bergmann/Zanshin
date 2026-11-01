// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_diff.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show DiffLayoutSetting;

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

HunkLine _ctx(String text) => HunkLine(kind: HunkLineKind.context, text: '$text\n');
HunkLine _rem(String text) => HunkLine(kind: HunkLineKind.removed, text: '$text\n');
HunkLine _add(String text) => HunkLine(kind: HunkLineKind.added, text: '$text\n');

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

  Widget view(FileDiff? diff, {DiffLayoutSetting layout = DiffLayoutSetting.unified}) => shellHost(
    SizedBox(
      width: 420,
      child: InspectorDiffView(
        path: 'src/main.rs',
        diff: diff,
        error: null,
        viewed: false,
        onViewedChanged: (_) {},
        layout: layout,
        onLayoutChanged: (_) {},
      ),
    ),
  );

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
}
