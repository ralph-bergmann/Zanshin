// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/project_files.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZsToast, ZsToastTone;

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

/// One call of the recording [StartProcess].
typedef StartCall = ({String executable, List<String> arguments, Map<String, String> environment});

void main() {
  setUpIconRegistry();
  late Directory dir;
  late Directory bin;
  late String root;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('zanshin_project_files');
    bin = Directory('${dir.path}/bin')..createSync();
    root = '${dir.path}/repo';
    Directory('$root/src').createSync(recursive: true);
    File('$root/src/a.dart').writeAsStringSync('a');
  });

  tearDown(() => dir.deleteSync(recursive: true));

  /// An executable stand-in named [name] in [bin]; it never runs.
  String fakeProgram(String name) {
    final file = File('${bin.path}/$name')..writeAsStringSync('#!/bin/sh\nexit 1\n');
    Process.runSync('chmod', <String>['+x', file.path]);
    return file.path;
  }

  /// [editorCommand]'s program and arguments as one list; null for none.
  List<String>? command(String editor, String file, {int? line}) => switch (editorCommand(editor, file, line: line)) {
    (:final String program, :final List<String> arguments) => <String>[program, ...arguments],
    null => null,
  };

  group('the editor command', () {
    test('each launcher takes its own line form, and the plain file without a line', () {
      expect(command('idea', '/r/a.dart', line: 12), <String>['idea', '--line', '12', '/r/a.dart']);
      expect(command('idea', '/r/a.dart'), <String>['idea', '/r/a.dart']);
      expect(command('code', '/r/a.dart', line: 12), <String>['code', '--goto', '/r/a.dart:12']);
      expect(command('code', '/r/a.dart'), <String>['code', '/r/a.dart']);
      expect(command('zed', '/r/a.dart', line: 12), <String>['zed', '/r/a.dart:12']);
      expect(command('zed', '/r/a.dart'), <String>['zed', '/r/a.dart']);
    });

    test('a custom command replaces {file} and {line} in each word, line 1 without one', () {
      expect(command('subl {file}:{line}', '/r/a.dart', line: 12), <String>['subl', '/r/a.dart:12']);
      expect(command('subl {file}:{line}', '/r/a.dart'), <String>['subl', '/r/a.dart:1']);
      expect(command("'/Apps/My Editor' -g \"{file}\"", '/r/a b.dart'), <String>[
        '/Apps/My Editor',
        '-g',
        '/r/a b.dart',
      ]);
      expect(command('subl', '/r/a.dart'), isNull, reason: 'no {file}');
      expect(command('   ', '/r/a.dart'), isNull);
    });

    test('the hint is the program and its arguments without the file', () {
      expect(editorHint('idea', line: 12), 'idea --line 12');
      expect(editorHint('idea'), 'idea');
      expect(editorHint('code', line: 12), 'code --goto :12', reason: 'the line stays once the file is gone');
      expect(editorHint('code'), 'code');
      expect(editorHint('zed', line: 3), 'zed :3');
      expect(editorHint('subl -w {file}:{line}', line: 3), 'subl -w :3');
      expect(editorHint('subl'), isNull);
    });

    test('the command line splits at spaces; quotes group and go', () {
      expect(splitCommandLine('a  b\tc'), <String>['a', 'b', 'c']);
      expect(splitCommandLine("a 'b c' \"d 'e'\""), <String>['a', 'b c', "d 'e'"]);
      expect(splitCommandLine("a '' b"), <String>['a', '', 'b']);
      expect(splitCommandLine("a 'b c"), <String>['a', 'b c'], reason: 'an unclosed quote runs to the end');
      expect(splitCommandLine(''), isEmpty);
    });
  });

  group('the PATH', () {
    test('a program is the first executable file along PATH; a plain file is skipped', () {
      final String idea = fakeProgram('idea');
      final other = Directory('${dir.path}/other')..createSync();
      File('${other.path}/code').writeAsStringSync('not executable');
      final path = '${other.path}::${bin.path}';
      expect(findOnPath('idea', path), idea);
      expect(findOnPath('code', path), isNull);
      expect(findOnPath(idea, ''), idea, reason: 'a path with a / is taken as it is');
      expect(findOnPath('${bin.path}/zed', path), isNull);
    });

    test('detection lists the launchers found, in their order', () {
      fakeProgram('zed');
      fakeProgram('idea');
      expect(detectEditors(bin.path), <String>['idea', 'zed']);
      expect(detectEditors(''), isEmpty);
    });
  });

  group('ProjectFiles', () {
    late SettingsStore settings;
    late ShellToasts toasts;
    late List<StartCall> calls;
    late Map<String, String> environment;
    Object? fail;

    setUp(() async {
      settings = await SettingsStore.load(File('${dir.path}/settings.json'));
      toasts = ShellToasts();
      calls = <StartCall>[];
      environment = <String, String>{'PATH': bin.path, 'HOME': dir.path};
      fail = null;
    });

    tearDown(() async {
      await settings.settled;
      toasts.dispose();
    });

    ProjectFiles files() => ProjectFiles(
      root: root,
      settings: settings,
      toasts: toasts,
      environment: () => environment,
      start: (executable, arguments, environment) async {
        calls.add((executable: executable, arguments: arguments, environment: environment));
        if (fail case final Object error) {
          throw error;
        }
      },
    );

    test('a path is absolute from the root; existence is read on disk', () {
      final ProjectFiles project = files();
      expect(project.absolute('src/a.dart'), '$root/src/a.dart');
      expect(project.exists('src/a.dart'), isTrue);
      expect(project.exists('src'), isTrue, reason: 'a folder');
      expect(project.exists('src/gone.dart'), isFalse);
    });

    test('Open in IntelliJ at line 12 starts the idea on PATH with the login environment', () async {
      final String idea = fakeProgram('idea');
      await settings.update((s) => s.copyWith.general(editor: 'idea'));
      await files().openInEditor('src/a.dart', line: 12);
      expect(calls.single.executable, idea);
      expect(calls.single.arguments, <String>['--line', '12', '$root/src/a.dart']);
      expect(calls.single.environment, environment);
      expect(toasts.current, isNull);
    });

    test('a custom command gets the file and the line in its words', () async {
      final String subl = fakeProgram('subl');
      await settings.update((s) => s.copyWith.general(editor: 'subl {file}:{line}'));
      await files().openInEditor('src/a.dart', line: 12);
      expect(calls.single.executable, subl);
      expect(calls.single.arguments, <String>['$root/src/a.dart:12']);
    });

    test('without an editor nothing starts', () async {
      await files().openInEditor('src/a.dart');
      expect(calls, isEmpty);
    });

    test('a launcher not on PATH shows an error toast and starts nothing', () async {
      await settings.update((s) => s.copyWith.general(editor: 'zed'));
      await files().openInEditor('src/a.dart');
      expect(calls, isEmpty);
      expect(toasts.current?.tone, ZsToastTone.error);
    });

    test('Reveal in Finder runs open -R on the absolute path; a failed start shows an error toast', () async {
      await files().reveal('src');
      expect(calls.single.executable, '/usr/bin/open');
      expect(calls.single.arguments, <String>['-R', '$root/src']);
      expect(toasts.current, isNull);
      fail = const ProcessException('/usr/bin/open', <String>[], 'denied');
      await files().reveal('src');
      expect(toasts.current?.tone, ZsToastTone.error);
    });

    test('a custom program under ~/ is found from HOME', () async {
      final String subl = fakeProgram('subl');
      await settings.update((s) => s.copyWith.general(editor: '~/bin/subl {file}'));
      environment = <String, String>{'PATH': '', 'HOME': dir.path};
      await files().openInEditor('src/a.dart');
      expect(calls.single.executable, subl);
      expect(toasts.current, isNull);
    });

    testWidgets('the failure toast names the program and the reason', (tester) async {
      Future<String> toastText() async {
        await tester.pumpWidget(shellHost(Builder(builder: (context) => toasts.current!.build(context, () {}))));
        return tester.widget<ZsToast>(find.byType(ZsToast)).message.toPlainText();
      }

      fail = const ProcessException('/usr/bin/open', <String>[], 'denied');
      await files().reveal('src');
      expect(await toastText(), 'Could not start /usr/bin/open: denied');
      await tester.runAsync(() => settings.update((s) => s.copyWith.general(editor: 'zed')));
      await files().openInEditor('src/a.dart');
      expect(await toastText(), "Could not start zed: not found on the login shell's PATH");
    });
  });
}
