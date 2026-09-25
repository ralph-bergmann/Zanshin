// SPDX-License-Identifier: MIT

import 'dart:typed_data';

import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'precondition.dart' show decodeEnvelopeErrorInternal;
import 'request_bytes.dart';

// This file owns the FFI half of Story 9.36: handing the login shell's
// environment — read by `environment/login_shell.dart` — to Rust
// (`zanshin_environment_adopt`), which keeps it for every jj environment read.
// HANDLE-LESS and cheap (Rust only stores the map), so it runs on the calling
// isolate at start-up, before any worker or repo exists. `dart:ffi` stays inside
// `ffi/`.

/// One environment variable as raw bytes — an environment is not guaranteed
/// UTF-8, and a non-UTF-8 value must reach Rust byte for byte.
typedef EnvironmentVariable = ({Uint8List name, Uint8List value});

/// `zanshin_environment_adopt` — install [variables] as the environment every jj
/// environment read sees; the first installed environment stays. `null` sends no
/// `variables` vector, which Rust refuses like an empty one (`jj.invalid_input`).
Uint8List zanshinEnvironmentAdopt(List<EnvironmentVariable>? variables) {
  final Uint8List request = fbs.EnvironmentAdoptRequestObjectBuilder(
    kind: fbs.RequestKind.EnvironmentAdopt,
    variables: variables == null
        ? null
        : [
            for (final EnvironmentVariable variable in variables)
              fbs.EnvironmentVariableObjectBuilder(name: variable.name, value: variable.value),
          ],
  ).toBytes();
  return callWithRequest(request, zanshin_environment_adopt);
}

/// Decode a `zanshin_environment_adopt` envelope: its success carries no
/// payload and no warnings, so there is nothing to return; a refusal throws
/// `ZanshinFfiException`.
void decodeEnvironmentAdoptEnvelopeInternal(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    throw decodeEnvelopeErrorInternal(env);
  }
}
