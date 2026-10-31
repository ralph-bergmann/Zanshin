// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the l10n house rule (Story 11.16): user-facing text in `app/lib` comes from the ARB (`lib/l10n/app_en.arb`),
/// never a hard-coded literal. It scans `app/lib/**/*.dart` — the generated `lib/l10n/`, `*.g.dart`, `*.inject.dart`
/// and `*.factory.dart` skipped — for a string literal with a letter outside its interpolations in a UI position:
/// `Text('…'`, `SelectableText('…'`, `ZsMenuHeader('…'` (raw `r'…'` too) or a `text`, `label`, `message`, `tooltip`, `placeholder`, `title`,
/// `semanticLabel`, `semanticsLabel`, `hint`, `prompt`, `cancelLabel`, `confirmLabel`, `value`, `dotLabel`,
/// `increasedValue` or `decreasedValue` argument. A line marked
/// `// l10n-ignore: <reason>` (jj's own words, the product name) passes, and so do comment lines.
// shortcut: line-based scan, upgrade to an analyzer-based check if literals slip through. Not caught: a literal
// passed positionally on its own line, one after a `?`, and positional literals passed to other helpers on the same
// line (`_note('…')`, `_Question('…', …)`, `log('…')`).
void main() {
  group('the scanner', () {
    test('reports a planted literal with its line', () {
      expect(uiLiteralLines("a();\n    label: 'Planted',\n"), <int>[2]);
      expect(uiLiteralLines("const Text('Hello')"), <int>[1]);
      expect(uiLiteralLines('TextSpan(text: "Hi there")'), <int>[1]);
      expect(uiLiteralLines("TextSpan(style: s, text: 'Hi')"), <int>[1]);
      expect(uiLiteralLines("SelectableText('Hi')"), <int>[1]);
      expect(uiLiteralLines("label: r'Raw'"), <int>[1]);
      expect(uiLiteralLines("ZsMenuHeader('Recent')"), <int>[1]);
      expect(uiLiteralLines(r"tooltip: '${a.b} items'"), <int>[1]);
      expect(uiLiteralLines("value: widget.busy ? s.v : null,\n      value: 'busy',"), <int>[2]);
    });

    test('skips marked lines, comments, letterless literals and other positions', () {
      expect(uiLiteralLines("'root()', // l10n-ignore: jj's text"), isEmpty);
      expect(uiLiteralLines("label: 'root()', // l10n-ignore: jj's text"), isEmpty);
      expect(uiLiteralLines("/// label: 'Doc example'"), isEmpty);
      expect(uiLiteralLines("label: '·'"), isEmpty);
      expect(uiLiteralLines(r"label: '${widget.name}@$remote'"), isEmpty);
      expect(uiLiteralLines("identifier: 'projects-window'"), isEmpty);
      expect(uiLiteralLines('label: context.l10n.panelClose'), isEmpty);
    });
  });

  test('app/lib has no unmarked hard-coded UI string', () {
    final List<File> files =
        Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((file) => file.path.endsWith('.dart') && !_skipped(file.path))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    expect(files, isNotEmpty, reason: 'run from app/');
    final found = <String>[
      for (final File file in files)
        for (final int line in uiLiteralLines(file.readAsStringSync()))
          '${file.path}:$line: ${file.readAsLinesSync()[line - 1].trim()}',
    ];
    expect(found, isEmpty, reason: 'move these strings into lib/l10n/app_en.arb, or mark jj\'s words // l10n-ignore');
  });
}

bool _skipped(String path) =>
    path.startsWith('lib/l10n/') ||
    path.endsWith('.g.dart') ||
    path.endsWith('.inject.dart') ||
    path.endsWith('.factory.dart');

/// A UI position followed by a string literal; group 1 is the literal's body.
final _uiLiteral = RegExp(
  r'''(?:\b(?:Text|SelectableText|ZsMenuHeader)\(\s*|\b(?:text|label|message|tooltip|placeholder|title|semanticLabel|semanticsLabel|hint|prompt|cancelLabel|confirmLabel|value|dotLabel|increasedValue|decreasedValue):\s*)r?(?:'((?:[^'\\]|\\.)*)'|"((?:[^"\\]|\\.)*)")''',
);

final _interpolation = RegExp(r'\$\{[^}]*\}|\$\w+');
final _letter = RegExp('[A-Za-z]');

/// The 1-based lines of [source] that pass a hard-coded UI string.
List<int> uiLiteralLines(String source) {
  final List<String> lines = source.split('\n');
  return <int>[
    for (var i = 0; i < lines.length; i++)
      if (_flags(lines[i])) i + 1,
  ];
}

bool _flags(String line) {
  if (line.trimLeft().startsWith('//') || line.contains('// l10n-ignore')) {
    return false;
  }
  return _uiLiteral
      .allMatches(line)
      .any((match) => _letter.hasMatch((match[1] ?? match[2] ?? '').replaceAll(_interpolation, '')));
}
