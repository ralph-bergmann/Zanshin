// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../ffi/environment.dart';
import '../ffi/request_bytes.dart' show rejectInteriorNul;
import '../ffi/warning.dart';

// Story 9.36: a Zanshin started from Finder or the Dock inherits launchd's
// minimal environment, not the one a terminal `jj` gets from the user's login
// shell — `JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_USER`, … set in a shell rc file
// never reach the jj config stack, and the `git` subprocess of a fetch or clone
// misses the shell's `PATH`, `SSH_AUTH_SOCK` and `GIT_*`. This file reads the
// login shell's environment ONCE at start-up and hands it to Rust, which keeps
// it for every jj environment read (`crates/zanshin-jj/src/environment.rs`).
// The reader never touches FFI; only the adoption does.

/// Printed before the environment dump — opaque; only this file reads it.
const _begin = '__ZANSHIN_LOGIN_ENV_BEGIN__';

/// Printed after the environment dump. Reading it — not EOF — is what makes a
/// read succeed: a background job the rc file started may keep the pipe open
/// long after the shell is done.
const _end = '__ZANSHIN_LOGIN_ENV_END__';

/// What the login shell runs: the NUL-separated environment between the two
/// markers, so anything an rc file prints around it is skipped.
const _command = "printf '%s' '$_begin'; /usr/bin/env -0; printf '%s' '$_end'";

final List<int> _beginBytes = ascii.encode(_begin);
final List<int> _endBytes = ascii.encode(_end);

/// The second sentence of every `env.login_shell_unresolved` message.
const _fallback = 'Using the environment Zanshin was started with.';

/// The reason when the output ends before the end marker, or the dump holds no
/// variable at all: the shell is detached, so its exit status is never known.
const _noEnvironment = 'it printed no environment';

/// The largest timeout accepted, in milliseconds.
const _maxTimeoutMs = 0xFFFFFFFF;

/// What [readLoginShellEnvironment] found: the login shell's variables, or the
/// warning that says why they could not be read.
sealed class LoginShellRead {
  const LoginShellRead();
}

/// The login shell's whole environment, in the order it printed it.
final class LoginShellVariables extends LoginShellRead {
  const LoginShellVariables(this.variables);

  /// Every variable the login shell printed, names and values as raw bytes.
  final List<EnvironmentVariable> variables;
}

/// The login shell's environment could not be read.
final class LoginShellUnresolved extends LoginShellRead {
  const LoginShellUnresolved(this.warning);

  /// The one `env.login_shell_unresolved` warning that says why.
  final ZanshinWarning warning;
}

/// The result of [adoptLoginShellEnvironment] — the call returns nothing else,
/// so only its warnings: empty when the login shell's environment was adopted
/// (or one already had been), one `env.login_shell_unresolved` when it could not
/// be read and the environment Zanshin was started with stays in effect.
final class LoginShellEnvironmentResult {
  const LoginShellEnvironmentResult({this.warnings = const []});

  /// The call's warnings; empty when the environment was adopted.
  final List<ZanshinWarning> warnings;
}

/// Adopts the login shell's environment for every jj environment read (Story
/// 9.36): reads it with [readLoginShellEnvironment] and hands it to Rust, so
/// from then on the jj config stack (`JJ_CONFIG`, `XDG_CONFIG_HOME`, `JJ_USER`,
/// …) and the `git` subprocess of a fetch or clone see the environment a
/// terminal `jj` would — not the minimal one a Finder/Dock launch inherits. The
/// app calls it once at start-up, before any repo is opened; a call after a
/// successful one reads the shell again but changes nothing (the first
/// environment stays).
///
/// Handing the map over is cheap, so it runs on the CALLING isolate — no
/// worker needed. When the environment could not be read, nothing is handed
/// over, the environment Zanshin was started with stays in effect, and the
/// result carries the one `env.login_shell_unresolved` warning. A [shell] with
/// an interior NUL, or a negative [timeout] or one beyond `0xFFFFFFFF` ms,
/// throws [ArgumentError] before anything runs.
Future<LoginShellEnvironmentResult> adoptLoginShellEnvironment({
  String? shell,
  Duration timeout = const Duration(seconds: 10),
}) async {
  switch (await readLoginShellEnvironment(shell: shell, timeout: timeout)) {
    case LoginShellUnresolved(:final ZanshinWarning warning):
      return LoginShellEnvironmentResult(warnings: [warning]);
    case LoginShellVariables(:final List<EnvironmentVariable> variables):
      decodeEnvironmentAdoptEnvelopeInternal(zanshinEnvironmentAdopt(variables));
      return const LoginShellEnvironmentResult();
  }
}

/// Reads the login shell's environment (Story 9.36): runs `<shell> -l -i -c`
/// ([shell] null or empty: the process's `$SHELL`) with the inherited
/// environment and reads the `env -0` dump it prints within [timeout].
///
/// The shell runs DETACHED — in its own session, without a controlling
/// terminal — so an interactive `zsh -i` can never take over the terminal
/// Zanshin was started from; it is not this process's child, so it is left to
/// exit on its own once the dump is read, and killed only when it outlives
/// [timeout]. The end marker, not the end of the output, ends the read.
///
/// Never throws for a shell that fails: the result is then a
/// [LoginShellUnresolved] carrying one `env.login_shell_unresolved` warning. A
/// [shell] with an interior NUL, or a negative [timeout] or one beyond
/// `0xFFFFFFFF` ms, throws [ArgumentError] before anything runs.
Future<LoginShellRead> readLoginShellEnvironment({
  String? shell,
  Duration timeout = const Duration(seconds: 10),
}) => readLoginShellEnvironmentInternal(shell: shell, timeout: timeout, environment: Platform.environment);

/// [readLoginShellEnvironment] with the process [environment] it takes `SHELL`
/// from passed in — so a test can run it without one.
Future<LoginShellRead> readLoginShellEnvironmentInternal({
  required Duration timeout,
  required Map<String, String> environment,
  String? shell,
}) async {
  // `isNegative`, not `inMilliseconds < 0`: a negative sub-millisecond timeout
  // truncates to 0 ms.
  if (timeout.isNegative || timeout.inMilliseconds > _maxTimeoutMs) {
    throw ArgumentError.value(timeout, 'timeout', 'must be between 0 and $_maxTimeoutMs ms');
  }
  rejectInteriorNul(shell, 'shell');
  final String? program = (shell == null || shell.isEmpty) ? environment['SHELL'] : shell;
  if (program == null || program.isEmpty) {
    return _unresolved('Could not read the login-shell environment: SHELL is not set. $_fallback');
  }
  final Process process;
  try {
    process = await Process.start(program, const ['-l', '-i', '-c', _command], mode: .detachedWithStdio);
  } on ProcessException catch (e) {
    return _failed(program, 'could not start it: ${e.message}');
  }
  return _readDump(process, program, timeout);
}

/// Collects [process]'s stdout until the end marker follows the begin marker,
/// or the output ends, or [timeout] passes — whichever comes first.
Future<LoginShellRead> _readDump(Process process, String shell, Duration timeout) {
  final done = Completer<LoginShellRead>();
  final output = BytesBuilder(copy: false);
  // The shell reads nothing; its stderr (rc chatter, an interactive shell's
  // job-control notes) is discarded.
  process.stdin.close().ignore();
  final StreamSubscription<List<int>> errors = process.stderr.listen(null, onError: (_) {});
  late final StreamSubscription<List<int>> dump;
  late final Timer deadline;

  void finish(LoginShellRead read) {
    if (done.isCompleted) {
      return;
    }
    deadline.cancel();
    // Cancelling closes this end of both pipes, so an rc-started background job
    // that still holds them keeps nothing here alive.
    unawaited(dump.cancel());
    unawaited(errors.cancel());
    done.complete(read);
  }

  deadline = Timer(timeout, () {
    Process.killPid(process.pid, ProcessSignal.sigkill);
    finish(_failed(shell, 'timed out after ${timeout.inMilliseconds} ms'));
  });
  dump = process.stdout.listen(
    (chunk) {
      output.add(chunk);
      final Uint8List? between = _betweenMarkers(output.toBytes());
      if (between != null) {
        final List<EnvironmentVariable> variables = parseEnvironmentDumpInternal(between);
        finish(variables.isEmpty ? _failed(shell, _noEnvironment) : LoginShellVariables(variables));
      }
    },
    onError: (_) => finish(_failed(shell, _noEnvironment)),
    onDone: () => finish(_failed(shell, _noEnvironment)),
    cancelOnError: true,
  );
  return done.future;
}

/// The bytes between the first begin marker and the end marker after it —
/// anything an rc file printed before the begin marker is skipped.
Uint8List? _betweenMarkers(Uint8List output) {
  final int begin = _indexOf(output, _beginBytes, 0);
  if (begin < 0) {
    return null;
  }
  final int start = begin + _beginBytes.length;
  final int end = _indexOf(output, _endBytes, start);
  return end < 0 ? null : Uint8List.sublistView(output, start, end);
}

int _indexOf(Uint8List haystack, List<int> needle, int from) {
  for (var i = from; i + needle.length <= haystack.length; i++) {
    var j = 0;
    while (j < needle.length && haystack[i + j] == needle[j]) {
      j++;
    }
    if (j == needle.length) {
      return i;
    }
  }
  return -1;
}

/// Parses `env -0` output: NUL-separated `KEY=VALUE` entries, kept as raw
/// bytes. An entry splits at the first `=` after its first byte and is skipped
/// without one — the rule Rust's `std::env::vars_os` applies to a process's own
/// environment block.
List<EnvironmentVariable> parseEnvironmentDumpInternal(Uint8List dump) {
  final variables = <EnvironmentVariable>[];
  var start = 0;
  while (start < dump.length) {
    final int nul = dump.indexOf(0, start);
    final int end = nul < 0 ? dump.length : nul;
    final int equals = dump.indexOf(0x3D, start + 1);
    if (equals >= 0 && equals < end) {
      variables.add((name: dump.sublist(start, equals), value: dump.sublist(equals + 1, end)));
    }
    start = end + 1;
  }
  return variables;
}

LoginShellUnresolved _failed(String shell, String reason) =>
    _unresolved('Could not read the login-shell environment from $shell: $reason. $_fallback');

LoginShellUnresolved _unresolved(String message) =>
    LoginShellUnresolved(ZanshinWarning(code: ZanshinWarningCode.loginShellUnresolved, message: message));
