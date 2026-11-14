// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/inspector_file_tree.dart';
import 'package:zanshin/src/features/graph/inspector_path_label.dart';
import 'package:zanshin_core/zanshin_core.dart';

FileChange _file(String path) => FileChange(path: path, kind: FileChangeKind.modified);

/// Each row as `d<depth> name (count) open|closed` or `f<depth> path`.
List<String> _shape(List<InspectorListRow> rows) => <String>[
  for (final InspectorListRow row in rows)
    switch (row) {
      InspectorFolderListRow(:final String name, :final List<FileChange> files, :final bool open) =>
        'd${row.depth} $name (${files.length}) ${open ? 'open' : 'closed'}',
      InspectorFileListRow() => 'f${row.depth} ${row.path}',
    },
];

void main() {
  test('the flat list keeps jj order', () {
    final files = <FileChange>[_file('b/z.dart'), _file('a.dart')];
    expect(_shape(inspectorFlatRows(files)), <String>['f0 b/z.dart', 'f0 a.dart']);
  });

  test('the tree sorts folders by name, then files by name, ignoring case first', () {
    final files = <FileChange>[
      _file('zeta.txt'),
      _file('src/b.dart'),
      _file('Alpha.txt'),
      _file('lib/x.dart'),
      _file('src/A.dart'),
    ];
    expect(_shape(inspectorTreeRows(files, const <String>{})), <String>[
      'd0 lib (1) open',
      'f1 lib/x.dart',
      'd0 src (2) open',
      'f1 src/A.dart',
      'f1 src/b.dart',
      'f0 Alpha.txt',
      'f0 zeta.txt',
    ]);
  });

  test('a chain of folders holding one folder each joins into one row', () {
    final files = <FileChange>[
      _file('packages/logic_designer/lib/src/presentation/a.dart'),
      _file('packages/logic_designer/lib/src/data/b.dart'),
    ];
    final List<InspectorListRow> rows = inspectorTreeRows(files, const <String>{});
    expect(_shape(rows), <String>[
      'd0 packages/logic_designer/lib/src (2) open',
      'd1 data (1) open',
      'f2 packages/logic_designer/lib/src/data/b.dart',
      'd1 presentation (1) open',
      'f2 packages/logic_designer/lib/src/presentation/a.dart',
    ]);
    expect(rows.first.path, 'packages/logic_designer/lib/src', reason: 'the deepest folder of the chain');
  });

  test('a collapsed folder hides its rows and keeps its count', () {
    final files = <FileChange>[_file('src/a.dart'), _file('src/b/c.dart'), _file('top.txt')];
    expect(_shape(inspectorTreeRows(files, const <String>{'src'})), <String>['d0 src (2) closed', 'f0 top.txt']);
    expect(_shape(inspectorTreeRows(files, const <String>{'src/b'})), <String>[
      'd0 src (2) open',
      'd1 b (1) closed',
      'f1 src/a.dart',
      'f0 top.txt',
    ]);
  });

  testWidgets('the label cuts the head first, then the last folder, then the name', (tester) async {
    // The test font draws every glyph 1 em wide: at 10 px a character is 10 px.
    const style = TextStyle(fontSize: 10, height: 1);
    final ({String name, String head, String tail}) parts = inspectorPathParts(
      'packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart',
    );
    Future<List<double>> widths(double width) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: InspectorPathLabel(
                name: parts.name,
                head: parts.head,
                tail: parts.tail,
                nameStyle: style,
                folderStyle: style,
              ),
            ),
          ),
        ),
      );
      return <double>[
        for (final String text in <String>[parts.name, parts.head, parts.tail]) tester.getSize(find.text(text)).width,
      ];
    }

    // 460: the name (29 characters) and the tail (8) whole, the head gets the rest after the 8 px gap.
    expect(await widths(460), <double>[290, 460 - 290 - 8 - 80, 80]);
    // Below the name's width: the folder gets nothing, the name is cut.
    expect(await widths(200), <double>[200, 0, 0]);
  });

  test('a path splits into its name, its folder head and its last folder', () {
    expect(inspectorPathParts('packages/logic_designer/lib/src/presentation/widgets/automation_overview_page.dart'), (
      name: 'automation_overview_page.dart',
      head: 'packages/logic_designer/lib/src/presentation/',
      tail: 'widgets/',
    ));
    expect(inspectorPathParts('src/a.dart'), (name: 'a.dart', head: '', tail: 'src/'));
    expect(inspectorPathParts('a.dart'), (name: 'a.dart', head: '', tail: ''));
  });
}
