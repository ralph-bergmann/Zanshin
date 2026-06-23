// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/diagnostics.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/worker/responses.dart';

/// Tests the [ZanshinDiagnosticsModule] seam against the real compiled cdylib.
///
/// No mocked FFI — testing rules require a real cdylib build (`cargo make build`
/// must precede `flutter test`; `cargo make test` gates this).
///
/// `log_path` assertion is env-aware: under `cargo make test` the harness sets
/// `ZANSHIN_LOG_DIR=…/target/test-logs`; a hardcoded `Library/Logs/Zanshin`
/// suffix would fail in that context (AC-10).
void main() {
  group('zanshin_diagnostics FFI seam', () {
    late Diagnostics diag;

    setUpAll(() {
      final GetDiagnostics getDiagnostics = ZanshinDiagnosticsModule().zanshinDiagnostics();
      diag = getDiagnostics();
    });

    test('appVersion is non-empty', () {
      expect(diag.appVersion, isNotEmpty);
    });

    test('gitSha is non-empty', () {
      expect(diag.gitSha, isNotEmpty);
    });

    test('logPath is a non-empty absolute path', () {
      expect(diag.logPath, isNotEmpty);
      expect(diag.logPath.startsWith('/'), isTrue, reason: 'logPath must be an absolute path');
    });

    test('logPath matches ZANSHIN_LOG_DIR when set', () {
      final String? logDir = Platform.environment['ZANSHIN_LOG_DIR'];
      if (logDir != null) {
        expect(diag.logPath, equals(logDir));
      }
    });
  });

  group('decodeDiagnosticsEnvelope decode contract', () {
    test('throws ZanshinFfiException on ok envelope with non-Diagnostics payload', () {
      // ok == true but the union variant is RepoHandle, not Diagnostics: the
      // discriminant guard must surface a typed ZanshinFfiException, not a raw
      // Dart TypeError from an unguarded `env.data as fbs.Diagnostics` cast.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeDiagnosticsEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });
  });
}
