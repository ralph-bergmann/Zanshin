// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';
import 'warning.dart';

// This file owns the Dart half of Story 9.36: the app's start-up adoption of
// the login shell's environment (`zanshin_environment_adopt`) — the request
// builder, the result model and its decoder. HANDLE-LESS: it runs before any
// repo is opened. `dart:ffi` stays inside `ffi/` — only the worker isolate calls
// the adapter.
//
// The guards below are the DIRECT-CALLER backstop; the primary guard lives on
// the calling side, in `ZanshinWorker`.

/// The largest timeout the wire carries — its `timeout_ms` is a `uint`.
const _maxTimeoutMs = 0xFFFFFFFF;

/// The result of `adoptLoginShellEnvironment` (Story 9.36) — the call returns
/// nothing else, so only its warnings: empty when the login shell's environment
/// was adopted (or already had been), one `env.login_shell_unresolved` when it
/// could not be read and the environment Zanshin was started with stays in
/// effect.
final class LoginShellEnvironmentResult {
  const LoginShellEnvironmentResult({this.warnings = const []});

  /// The call's warnings; empty when the environment was adopted.
  final List<ZanshinWarning> warnings;
}

/// [timeout] in whole milliseconds as the wire carries it; a negative timeout
/// or one beyond `0xFFFFFFFF` ms throws [ArgumentError].
int loginShellTimeoutMillis(Duration timeout) {
  final int ms = timeout.inMilliseconds;
  // `isNegative`, not `ms < 0`: a negative sub-millisecond timeout truncates to 0 ms.
  if (timeout.isNegative || ms > _maxTimeoutMs) {
    throw ArgumentError.value(timeout, 'timeout', 'must be between 0 and $_maxTimeoutMs ms');
  }
  return ms;
}

/// `zanshin_environment_adopt` — adopt the login shell's environment. [shell]
/// null = the process's `$SHELL`.
Uint8List zanshinEnvironmentAdopt({required int timeoutMs, String? shell}) {
  rejectInteriorNul(shell, 'shell');
  RangeError.checkValueInInterval(timeoutMs, 0, _maxTimeoutMs, 'timeoutMs');
  final Uint8List request = fbs.EnvironmentAdoptRequestObjectBuilder(
    kind: fbs.RequestKind.EnvironmentAdopt,
    shell: shell,
    timeoutMs: timeoutMs,
  ).toBytes();
  return callWithRequest(request, zanshin_environment_adopt);
}

/// Decode a no-payload `zanshin_environment_adopt` envelope into its warnings.
LoginShellEnvironmentResult decodeLoginShellEnvironmentEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
  return LoginShellEnvironmentResult(warnings: decodeEnvelopeWarningsInternal(env));
}
