// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards project-context.md's Dart rule: Dart code starts a child process only
/// detached (`ProcessStartMode.detached` / `.detachedWithStdio`), or the process
/// is started from Rust. While a non-detached Dart child lives, the VM's
/// exit-code handler `waitpid`s ANY pid, so it can reap a child the cdylib
/// started (a `fix` tool, jj-lib's `git`) and that wait fails with ECHILD.
///
/// It scans every Dart `lib/` tree of the repository (`app/lib`,
/// `packages/*/lib`, generated files included) with comments and string
/// contents blanked, and names file:line for every `Process.run` /
/// `Process.runSync` reference and every `Process.start` without a detached
/// `mode:` (a tear-off included). Known limits: a spawn inside a string
/// interpolation is blanked with its string, and a detached `mode:` anywhere in
/// the argument text (a nested call's included) counts. Every package rule of
/// `cargo xtask gate-plan` plans this app's `test-flutter`, so a change to any
/// of those trees runs it.
void main() {
  group('the spawn matcher', () {
    test('flags a run, a runSync, a non-detached start and tear-offs', () {
      expect(_violations('final r = await Process.run("x", []);'), [
        (line: 1, reason: 'Process.run'),
      ]);
      expect(_violations('io.Process.runSync("x", const []);'), [
        (line: 1, reason: 'Process.runSync'),
      ]);
      expect(_violations('\n\nawait Process.start(\n  "x",\n  [],\n);'), [
        (line: 3, reason: 'Process.start without a detached mode'),
      ]);
      expect(_violations('Process.start("x", [], mode: ProcessStartMode.normal);'), [
        (line: 1, reason: 'Process.start without a detached mode'),
      ]);
      expect(_violations('final f = Process.start;\nfinal g = Process.run;'), [
        (line: 1, reason: 'Process.start tear-off'),
        (line: 2, reason: 'Process.run'),
      ]);
    });

    test('accepts a detached start, in every spelling', () {
      for (final source in [
        'Process.start("x", [], mode: ProcessStartMode.detached);',
        'io.Process.start(p, const [], mode: io.ProcessStartMode.detachedWithStdio);',
        'Process.start(program, const ["-c", "a(b)"], mode: .detachedWithStdio);',
        'Process.start(\n  p,\n  args,\n  mode: .detached,\n);',
      ]) {
        expect(_violations(source), isEmpty, reason: source);
      }
    });

    test('ignores comments and string contents', () {
      expect(
        _violations(
          '// Process.run("x", []);\n'
          '/* Process.start("x", []); /* nested */ Process.run */\n'
          '/// Uses [Process.runSync].\n'
          'final s = "Process.run(x)";\n'
          "final t = '''\nProcess.start('x', [])\n''';\n"
          "final u = r'Process.run';\n"
          'final url = "https://x"; Process.run("y", []);',
        ),
        [(line: 9, reason: 'Process.run')],
      );
    });
  });

  test('no Dart lib/ tree starts a child process non-detached', () {
    final Directory root = _repoRoot();
    final roots = <Directory>[
      Directory('${root.path}/app/lib'),
      for (final FileSystemEntity entry in Directory('${root.path}/packages').listSync()..sort(_byPath))
        if (entry is Directory && Directory('${entry.path}/lib').existsSync()) Directory('${entry.path}/lib'),
    ];
    final found = <String>[];
    var scanned = 0;
    for (final dir in roots) {
      final List<File> files =
          dir.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.dart')).toList()
            ..sort(_byPath);
      for (final file in files) {
        scanned++;
        final String relative = file.path.substring(root.path.length + 1);
        for (final _Violation v in _violations(file.readAsStringSync())) {
          found.add('$relative:${v.line}: ${v.reason}');
        }
      }
    }
    expect(scanned, greaterThan(0), reason: 'the scan found no Dart file under ${root.path}');
    expect(
      found,
      isEmpty,
      reason: 'start child processes only detached (project-context.md § Dart):\n${found.join('\n')}',
    );
  });
}

typedef _Violation = ({int line, String reason});

int _byPath(FileSystemEntity a, FileSystemEntity b) => a.path.compareTo(b.path);

/// The directory holding `Cargo.toml` and `app/`, walking up from the current one.
Directory _repoRoot() {
  Directory dir = Directory.current.absolute;
  while (true) {
    if (File('${dir.path}/Cargo.toml').existsSync() && Directory('${dir.path}/app').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      throw StateError('no repository root above ${Directory.current.path}');
    }
    dir = parent;
  }
}

final _reference = RegExp(r'\bProcess\s*\.\s*(runSync|run|start)\b');
final _detachedMode = RegExp(
  r'\bmode\s*:\s*(?:(?:\w+\s*\.\s*)?ProcessStartMode\s*)?\.\s*(?:detachedWithStdio|detached)\b',
);

/// Every spawn [source] makes that the rule forbids, in source order.
List<_Violation> _violations(String source) {
  final String code = _blankCommentsAndStrings(source);
  final violations = <_Violation>[];
  for (final RegExpMatch match in _reference.allMatches(code)) {
    final int line = '\n'.allMatches(code.substring(0, match.start)).length + 1;
    final String verb = match.group(1)!;
    if (verb != 'start') {
      violations.add((line: line, reason: 'Process.$verb'));
      continue;
    }
    final String? arguments = _callArguments(code, match.end);
    if (arguments == null) {
      violations.add((line: line, reason: 'Process.start tear-off'));
    } else if (!_detachedMode.hasMatch(arguments)) {
      violations.add((line: line, reason: 'Process.start without a detached mode'));
    }
  }
  return violations;
}

/// The text between the parentheses of the call starting at [from] (after
/// whitespace), or null when no `(` follows — a tear-off.
String? _callArguments(String code, int from) {
  var i = from;
  while (i < code.length && code[i].trim().isEmpty) {
    i++;
  }
  if (i >= code.length || code[i] != '(') {
    return null;
  }
  var depth = 0;
  for (var j = i; j < code.length; j++) {
    if (code[j] == '(') {
      depth++;
    } else if (code[j] == ')') {
      depth--;
      if (depth == 0) {
        return code.substring(i + 1, j);
      }
    }
  }
  return code.substring(i + 1);
}

/// [source] with every comment and every string literal's contents replaced by
/// spaces, newlines kept, so offsets and line numbers stay those of [source].
/// Interpolations are blanked with their string.
String _blankCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  void blank(int end) {
    for (; i < end; i++) {
      out.write(source[i] == '\n' ? '\n' : ' ');
    }
  }

  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final int end = source.indexOf('\n', i);
      blank(end < 0 ? source.length : end);
    } else if (source.startsWith('/*', i)) {
      var depth = 0;
      var j = i;
      while (j < source.length) {
        if (source.startsWith('/*', j)) {
          depth++;
          j += 2;
        } else if (source.startsWith('*/', j)) {
          depth--;
          j += 2;
          if (depth == 0) {
            break;
          }
        } else {
          j++;
        }
      }
      blank(j);
    } else if (source[i] == "'" || source[i] == '"' || (source[i] == 'r' && _quoteAt(source, i + 1))) {
      final raw = source[i] == 'r';
      final int start = raw ? i + 1 : i;
      final String quote = source.startsWith(source[start] * 3, start) ? source[start] * 3 : source[start];
      int j = start + quote.length;
      while (j < source.length && !source.startsWith(quote, j)) {
        if (quote.length == 1 && source[j] == '\n') {
          break;
        }
        j += (!raw && source[j] == r'\') ? 2 : 1;
      }
      j = j < source.length && source.startsWith(quote, j) ? j + quote.length : j;
      out.write(source.substring(i, start + quote.length));
      i = start + quote.length;
      blank(j);
    } else {
      out.write(source[i]);
      i++;
    }
  }
  return out.toString();
}

bool _quoteAt(String source, int i) => i < source.length && (source[i] == "'" || source[i] == '"');
