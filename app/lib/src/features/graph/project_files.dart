// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/semantics.dart' show SemanticsService;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart' show adoptedLoginShellEnvironment;
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../shell/shell_toast.dart';

final _log = Logger('zanshin.project_files');

/// Starts [executable] with [arguments] and the whole [environment], detached; throws [ProcessException] when it cannot
/// start. [startDetached] in the app, a recording stand-in in tests.
typedef StartProcess = Future<void> Function(
  String executable,
  List<String> arguments,
  Map<String, String> environment,
);

/// The app's [StartProcess]: a detached child (project-context.md § Dart) with exactly [environment].
Future<void> startDetached(String executable, List<String> arguments, Map<String, String> environment) async {
  await Process.start(
    executable,
    arguments,
    environment: environment,
    includeParentEnvironment: false,
    mode: ProcessStartMode.detached,
  );
}

/// The environment programs Zanshin starts get: the login shell's (Story 9.36), else the process's — a Finder launch's
/// `PATH` never holds an editor's launcher.
Map<String, String> loginEnvironment() => adoptedLoginShellEnvironment() ?? Platform.environment;

/// Tells VoiceOver a copy landed, as an inspector id's copy does: the bubble or menu that shows it is outside the
/// focused node.
void announceCopied(BuildContext context) => unawaited(
  SemanticsService.sendAnnouncement(View.of(context), context.l10n.inspectorIdCopied, Directionality.of(context)),
);

/// The editor launchers Settings › General › Editor offers, in their order.
const editorLaunchers = <String>['idea', 'code', 'zed'];

/// The program and arguments that open [file] (at [line], else at its start) with [editor]: a launcher's own form, or
/// a custom command line split by [splitCommandLine] with `{file}` and `{line}` (1 without a line) replaced in each
/// word. Null for a custom command without `{file}` or without words.
({String program, List<String> arguments})? editorCommand(String editor, String file, {int? line}) {
  switch (editor) {
    case 'idea':
      return (
        program: 'idea',
        arguments: <String>[
          if (line != null) ...<String>['--line', '$line'],
          file,
        ],
      );
    case 'code':
      return (
        program: 'code',
        arguments: <String>[
          if (line == null) file else ...<String>['--goto', '$file:$line'],
        ],
      );
    case 'zed':
      return (
        program: 'zed',
        arguments: <String>[if (line == null) file else '$file:$line'],
      );
  }
  final List<String> words = splitCommandLine(editor);
  if (words.isEmpty || !editor.contains('{file}')) {
    return null;
  }
  final replaced = <String>[
    for (final String word in words) word.replaceAll('{file}', file).replaceAll('{line}', '${line ?? 1}'),
  ];
  return (program: replaced.first, arguments: replaced.sublist(1));
}

/// What a menu shows for [editor] at [line]: the program and its arguments without the file (`idea --line 12`,
/// `code --goto :12`); null like [editorCommand].
String? editorHint(String editor, {int? line}) {
  // A file name no argument holds otherwise: it marks where the file goes, and what an argument keeps besides it.
  const marker = '\u0000';
  final ({String program, List<String> arguments})? command = editorCommand(editor, marker, line: line);
  if (command == null) {
    return null;
  }
  return <String>[
    command.program,
    for (final String argument in command.arguments)
      if (argument.replaceAll(marker, '') case final String rest when rest.isNotEmpty) rest,
  ].join(' ');
}

/// [command] as a shell splits a word list: words between spaces, `'…'` and `"…"` quote (the quotes go, an empty pair
/// is an empty word). No escapes, no expansion; an unclosed quote runs to the end.
List<String> splitCommandLine(String command) {
  final words = <String>[];
  final word = StringBuffer();
  var started = false;
  String? quote;
  for (final String char in command.split('')) {
    if (quote != null) {
      if (char == quote) {
        quote = null;
      } else {
        word.write(char);
      }
    } else if (char == "'" || char == '"') {
      quote = char;
      started = true;
    } else if (char.trim().isEmpty) {
      if (started) {
        words.add(word.toString());
        word.clear();
        started = false;
      }
    } else {
      word.write(char);
      started = true;
    }
  }
  if (started) {
    words.add(word.toString());
  }
  return words;
}

/// [program]'s executable file: [program] itself when it holds a `/`, else the first `<dir>/<program>` along [path]
/// (`:`-separated) that is an executable file; null when there is none.
String? findOnPath(String program, String path) {
  bool executable(String candidate) {
    final FileStat stat = FileStat.statSync(candidate);
    // Any of the three execute bits, as `which` reads them.
    return stat.type == FileSystemEntityType.file && stat.mode & 0x49 != 0;
  }

  if (program.contains('/')) {
    return executable(program) ? program : null;
  }
  for (final String dir in path.split(':')) {
    if (dir.isEmpty) {
      continue;
    }
    final candidate = '$dir/$program';
    if (executable(candidate)) {
      return candidate;
    }
  }
  return null;
}

/// The [editorLaunchers] on [path], in their order.
List<String> detectEditors(String path) => <String>[
  for (final String launcher in editorLaunchers)
    if (findOnPath(launcher, path) != null) launcher,
];

List<String>? _detected;

/// The launchers on the login shell's `PATH`, scanned once per process (Settings › General › Editor); a few `stat`
/// calls, so on the calling isolate.
List<String> detectedEditors() => _detected ??= detectEditors(loginEnvironment()['PATH'] ?? '');

/// The open repository's files on disk (Story 10.39): absolute paths from the workspace [root], the clipboard, Open in
/// Editor with the editor of Settings › General › Editor, and Reveal in Finder. A program is found on the login
/// shell's `PATH` and started detached with that environment; a program not found, or a failed start, shows an error
/// toast "Could not start …". Never the macOS default app.
class ProjectFiles {
  /// The files under [root], the editor read from [settings], failures shown in [toasts].
  ProjectFiles({
    required this.root,
    required this.settings,
    required this.toasts,
    this.start = startDetached,
    this.environment = loginEnvironment,
  });

  /// The workspace root (`@projectRoot`).
  final String root;

  /// The app settings: `general.editor`.
  final SettingsStore settings;

  /// The project window's toasts.
  final ShellToasts toasts;

  /// Starts a program.
  final StartProcess start;

  /// The environment a program starts with, its `PATH` the one searched.
  final Map<String, String> Function() environment;

  /// [path] (a repo path) as an absolute path.
  String absolute(String path) => '$root/$path';

  /// Whether [path] (a file or a folder) is in the working copy on disk.
  bool exists(String path) => FileSystemEntity.typeSync(absolute(path)) != FileSystemEntityType.notFound;

  /// The chosen editor: null for none, a launcher of [editorLaunchers], else a custom command.
  String? get editor => settings.value.general.editor;

  /// Writes [text] to the clipboard and, through [context] while it is mounted, tells VoiceOver "Copied"
  /// ([announceCopied]); a failed write is logged.
  Future<void> copy(String text, BuildContext context) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
    } on PlatformException catch (error) {
      _log.warning('clipboard write failed: ${error.code}');
      return;
    }
    if (context.mounted) {
      announceCopied(context);
    }
  }

  /// Opens [path] in the chosen editor, at [line] when given; nothing without an editor or with a custom command
  /// without `{file}`.
  Future<void> openInEditor(String path, {int? line}) async {
    final String? editor = this.editor;
    final ({String program, List<String> arguments})? command = editor == null
        ? null
        : editorCommand(editor, absolute(path), line: line);
    if (command == null) {
      return;
    }
    await _run(command.program, command.arguments);
  }

  /// Shows [path] selected in a Finder window (`open -R`).
  Future<void> reveal(String path) => _run('/usr/bin/open', <String>['-R', absolute(path)]);

  Future<void> _run(String program, List<String> arguments) async {
    final Map<String, String> environment = this.environment();
    // A custom command's `~/program`, as the shell would expand it.
    final String? home = environment['HOME'];
    final resolved = program.startsWith('~/') && home != null ? '$home${program.substring(1)}' : program;
    final String? executable = findOnPath(resolved, environment['PATH'] ?? '');
    if (executable == null) {
      _failed(program, null);
      return;
    }
    try {
      await start(executable, arguments, environment);
    } on ProcessException catch (error) {
      _failed(program, error.message);
    }
  }

  void _failed(String program, String? reason) {
    // The program's name only: a custom command's full path may name the user's folders.
    _log.warning('could not start ${program.split('/').last}: ${reason ?? 'not found on PATH'}');
    toasts.show(
      ShellToastEntry(
        tone: ZsToastTone.error,
        build: (context, dismiss) => ZsToast(
          tone: ZsToastTone.error,
          message: TextSpan(
            text: context.l10n.filesStartFailed(program, reason ?? context.l10n.filesStartNotFound),
          ),
          onDismiss: dismiss,
          identifier: 'files-toast',
        ),
      ),
    );
  }
}
