// SPDX-License-Identifier: MIT

import 'dart:ffi' as ffi;
import 'dart:typed_data';

import 'package:inject_annotation/inject_annotation.dart';
import 'package:meta/meta.dart';

import '../worker/responses.dart';
import 'bindings.dart';
import 'envelope_zanshin.ffi_generated.dart' as fbs;
import 'ffi_buffer.dart';

/// Build-stamp and log-location diagnostics returned by [zanshin_diagnostics].
final class Diagnostics {
  const Diagnostics({
    required this.appVersion,
    required this.gitSha,
    required this.logPath,
  });

  /// Version from `[workspace.package]` — e.g. `"0.1.0"`.
  final String appVersion;

  /// Git SHA injected at compile time by `build.rs` — e.g. `"abc1234abcde"`.
  final String gitSha;

  /// Absolute directory path the tracing file sink writes to.
  final String logPath;
}

/// Typedef for the DI-provided factory that calls the Rust diagnostics FFI.
typedef GetDiagnostics = Diagnostics Function();

/// DI module that provides the [GetDiagnostics] factory as a singleton.
///
/// The factory calls [zanshin_diagnostics] (handle-free, main-isolate safe),
/// decodes the returned `Envelope`, and returns a [Diagnostics] value.
/// Modelled on `ZanshinFfiModule` (see `zanshin_version.dart`) but decodes a
/// FlatBuffers `Envelope` instead of a lone C string (ADR-0001). See also
/// `repo.dart` for the [FfiBuffer] decode pattern.
@module
class ZanshinDiagnosticsModule {
  /// Returns a factory that calls the Rust diagnostics FFI and decodes the
  /// result. The factory is a singleton — inject it anywhere a [GetDiagnostics]
  /// is needed and call it on demand.
  @provides
  @singleton
  GetDiagnostics zanshinDiagnostics() => _callDiagnostics;
}

Diagnostics _callDiagnostics() {
  final ffi.Pointer<ZanshinBuf> token = zanshin_diagnostics();
  final buf = FfiBuffer.fromToken(token);
  try {
    return decodeDiagnosticsEnvelope(Uint8List.fromList(buf.bytes));
  } finally {
    buf.dispose();
  }
}

/// Decodes a diagnostics `Envelope` buffer into a [Diagnostics] model.
///
/// Throws [ZanshinFfiException] on `!ok`, or when the payload is not a
/// `Diagnostics` table — guarding the union discriminant before the cast, the
/// same way `worker/isolate.dart` guards `dataType` before reading a
/// `RepoHandle`. A non-`Diagnostics` or absent payload yields the `ffi.unknown`
/// sentinel (the FFI returned something the seam cannot interpret) rather than a
/// raw `TypeError`. Exposed for decode-contract tests with synthetic buffers;
/// production calls go through [GetDiagnostics].
@visibleForTesting
Diagnostics decodeDiagnosticsEnvelope(Uint8List bytes) {
  final env = fbs.Envelope(bytes);
  if (!env.ok) {
    final fbs.FfiError? err = env.error;
    throw ZanshinFfiException(err?.code ?? 'ffi.unknown', err?.context);
  }
  final Object? payload = env.data;
  if (payload is! fbs.Diagnostics) {
    throw ZanshinFfiException(
      'ffi.unknown',
      'expected Diagnostics payload, got ${env.dataType}',
    );
  }
  return Diagnostics(
    appVersion: payload.appVersion ?? '',
    gitSha: payload.gitSha ?? '',
    logPath: payload.logPath ?? '',
  );
}
