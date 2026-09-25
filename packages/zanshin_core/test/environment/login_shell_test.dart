// SPDX-License-Identifier: MIT

// Story 9.36's login-shell reader (`readLoginShellEnvironment`) against fake
// login shells: `#!/bin/sh` scripts invoked as `<script> -l -i -c <cmd>`, so
// `$4` is the command Zanshin asks the shell to run.
//
// NEVER a successful ADOPTION here: dart_test.yaml runs every zanshin_core test
// file in ONE process against ONE cdylib, so handing a map to Rust would replace
// the environment every later file reads — the pinned JJ_CONFIG and
// XDG_CONFIG_HOME included. Reading is harmless (no FFI); only the adoption's
// failure path, which calls nothing, runs through `adoptLoginShellEnvironment`.

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/environment/login_shell.dart';
import 'package:zanshin_core/src/ffi/environment.dart';
import 'package:zanshin_core/src/ffi/warning.dart';

/// A shell that cannot even start.
const _missingShell = '/nonexistent/zanshin-shell';

const _fiveSeconds = Duration(seconds: 5);

/// The message of a read that failed for [reason] with [shell].
String _expected(String shell, String reason) =>
    'Could not read the login-shell environment from $shell: $reason. '
    'Using the environment Zanshin was started with.';

/// The variables of [variables] by name, values as raw bytes.
Map<String, Uint8List> _byName(List<EnvironmentVariable> variables) => {
  for (final EnvironmentVariable variable in variables) String.fromCharCodes(variable.name): variable.value,
};

/// The variables [read] carries; fails the test when it is a failure.
List<EnvironmentVariable> _variables(LoginShellRead read) => switch (read) {
  LoginShellVariables(:final List<EnvironmentVariable> variables) => variables,
  LoginShellUnresolved(:final ZanshinWarning warning) => fail('expected an environment, got: $warning'),
};

/// The message of the one `env.login_shell_unresolved` warning [read] carries.
String _message(LoginShellRead read) {
  expect(read, isA<LoginShellUnresolved>());
  final ZanshinWarning warning = (read as LoginShellUnresolved).warning;
  expect(warning.code, ZanshinWarningCode.loginShellUnresolved);
  return warning.message;
}

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('zanshin_login_shell_test_');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  /// Writes an executable fake login shell with [body].
  String fakeShell(String name, String body) {
    final script = File('${tempDir.path}/$name')..writeAsStringSync('#!/bin/sh\n$body\n');
    expect(Process.runSync('chmod', ['755', script.path]).exitCode, 0);
    return script.path;
  }

  test('a login shell that prints its environment is read despite rc noise and a background job', () async {
    final String shell = fakeShell('noisy', r'''
echo welcome
sleep 30 >&1 &
ZANSHIN_TEST_MARK=present
ODD_VALUE='a=b
c'
RAW_VALUE=$(printf 'x\377y')
export ZANSHIN_TEST_MARK ODD_VALUE RAW_VALUE
exec /bin/sh -c "$4"''');
    final watch = Stopwatch()..start();

    final Map<String, Uint8List> variables = _byName(_variables(await readLoginShellEnvironment(shell: shell)));

    expect(watch.elapsed, lessThan(_fiveSeconds), reason: 'the end marker, not EOF, ends the read');
    expect(variables['ZANSHIN_TEST_MARK'], 'present'.codeUnits);
    expect(variables['ODD_VALUE'], 'a=b\nc'.codeUnits);
    expect(variables['RAW_VALUE'], [0x78, 0xff, 0x79], reason: 'a non-UTF-8 value is kept as raw bytes');
    expect(variables['PATH'], Platform.environment['PATH']!.codeUnits, reason: 'the shell inherits the process');
  });

  test('a shell that never prints the end marker times out and is killed', () async {
    // A sleep only THIS test process starts: its duration carries our pid, so
    // `pgrep` cannot mistake another process's sleeper for ours.
    final sleep = 'sleep 30.$pid';
    final String shell = fakeShell('sleeper', 'exec $sleep');
    final watch = Stopwatch()..start();

    final LoginShellRead read = await readLoginShellEnvironment(
      shell: shell,
      timeout: const Duration(milliseconds: 200),
    );

    expect(watch.elapsed, lessThan(_fiveSeconds));
    expect(_message(read), _expected(shell, 'timed out after 200 ms'));
    // The kill is a signal: give the detached sleeper a moment to be gone.
    var alive = true;
    for (var i = 0; alive && i < 50; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      alive = Process.runSync('pgrep', ['-f', sleep]).exitCode == 0;
    }
    expect(alive, isFalse, reason: 'the timed-out shell was killed');
  });

  test('every failure names its reason', () async {
    final String quiet = fakeShell('quiet', 'echo hello');
    // Both markers, nothing between them: `env -0` swapped for a no-op.
    final String empty = fakeShell('empty', r'''eval "$(printf '%s' "$4" | sed 's#/usr/bin/env -0#:#')"''');

    final String cannotStart = _message(await readLoginShellEnvironment(shell: _missingShell));
    expect(
      cannotStart,
      startsWith('Could not read the login-shell environment from $_missingShell: could not start it: '),
    );
    expect(cannotStart, endsWith('. Using the environment Zanshin was started with.'));
    expect(_message(await readLoginShellEnvironment(shell: quiet)), _expected(quiet, 'it printed no environment'));
    expect(_message(await readLoginShellEnvironment(shell: empty)), _expected(empty, 'it printed no environment'));
  });

  test('the default timeout waits for a slow shell', () async {
    final String shell = fakeShell('slow-failure', 'sleep 1\nexit 3');

    final LoginShellRead read = await readLoginShellEnvironment(shell: shell);

    expect(_message(read), _expected(shell, 'it printed no environment'));
  });

  test('a null or empty shell falls back to SHELL, and without one there is nothing to run', () async {
    const noShell =
        'Could not read the login-shell environment: SHELL is not set. '
        'Using the environment Zanshin was started with.';
    final String quiet = fakeShell('quiet', 'echo hello');

    for (final environment in const [
      <String, String>{},
      {'SHELL': ''},
    ]) {
      for (final String? shell in [null, '']) {
        expect(
          _message(
            await readLoginShellEnvironmentInternal(shell: shell, timeout: _fiveSeconds, environment: environment),
          ),
          noShell,
        );
      }
    }
    expect(
      _message(
        await readLoginShellEnvironmentInternal(shell: '', timeout: _fiveSeconds, environment: {'SHELL': quiet}),
      ),
      _expected(quiet, 'it printed no environment'),
    );
  });

  test('a failed read adopts nothing and reports one warning', () async {
    final LoginShellEnvironmentResult result = await adoptLoginShellEnvironment(shell: _missingShell);

    expect(result.warnings, hasLength(1));
    expect(result.warnings.single.code, ZanshinWarningCode.loginShellUnresolved);
    expect(result.warnings.single.message, contains('$_missingShell: could not start it: '));
  });

  test('bad arguments are refused before anything runs', () async {
    for (final Future<Object> Function({String? shell, Duration timeout}) call in [
      readLoginShellEnvironment,
      adoptLoginShellEnvironment,
    ]) {
      await expectLater(call(shell: 'a\u0000'), throwsArgumentError);
      for (final timeout in const [
        Duration(milliseconds: -1),
        Duration(microseconds: -500),
        Duration(milliseconds: 0x100000000),
      ]) {
        await expectLater(call(shell: _missingShell, timeout: timeout), throwsArgumentError);
      }
    }
  });

  test('the dump parser keeps raw values and skips malformed entries', () {
    final dump = Uint8List.fromList([
      ...'A=b=c\u0000NL=x\ny\u0000RAW='.codeUnits,
      0xff,
      ...'\u0000NOEQ\u0000=lead\u0000EMPTY=\u0000'.codeUnits,
    ]);

    final Map<String, Uint8List> variables = _byName(parseEnvironmentDumpInternal(dump));

    expect(variables.keys, unorderedEquals(['A', 'NL', 'RAW', 'EMPTY']), reason: '`NOEQ` and `=lead` are skipped');
    expect(variables['A'], 'b=c'.codeUnits);
    expect(variables['NL'], 'x\ny'.codeUnits);
    expect(variables['RAW'], [0xff]);
    expect(variables['EMPTY'], isEmpty);
  });
}
