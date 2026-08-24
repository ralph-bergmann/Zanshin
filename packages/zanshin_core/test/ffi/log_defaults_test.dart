// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeLogDefaultsEnvelope] using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required — these tests exercise the Dart-side decode logic in isolation.
//
// Overridden values (a non-default `revsets.log`, a disabled `short-prefixes`)
// are exercised here because [tasks.test-core] pins `JJ_CONFIG=""` and Dart
// cannot set process env in-process, so the live cdylib path can only produce
// the builtin defaults (covered by test/worker/log_defaults_test.dart).

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/log_defaults.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('decodeLogDefaultsEnvelope decode contract', () {
    // ── Error envelope ────────────────────────────────────────────────────────

    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.config_error',
          context: '/r/.jj/repo/config.toml: bad TOML',
        ),
      ).toBytes();

      expect(
        () => decodeLogDefaultsEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.config_error')
              .having((e) => e.context, 'context', '/r/.jj/repo/config.toml: bad TOML'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-LogDefaults payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeLogDefaultsEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── Full field equality ───────────────────────────────────────────────────

    test('decodes every field equal to the builder input', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.LogDefaults,
        data: fbs.LogDefaultsObjectBuilder(
          log: '@ | trunk()',
          logGraphPrioritize: 'none()',
          shortPrefixes: 'trunk()',
          syntheticElided: false,
        ),
      ).toBytes();

      final LogDefaults defaults = decodeLogDefaultsEnvelope(bytes);

      expect(defaults.log, equals('@ | trunk()'));
      expect(defaults.logGraphPrioritize, equals('none()'));
      expect(defaults.shortPrefixes, equals('trunk()'));
      expect(defaults.syntheticElided, isFalse);
    });

    // ── Empty short-prefixes is meaningful, not absent ────────────────────────

    test('an empty shortPrefixes survives decoding as an empty string', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.LogDefaults,
        data: fbs.LogDefaultsObjectBuilder(
          log: 'all()',
          logGraphPrioritize: 'present(@)',
          shortPrefixes: '',
          syntheticElided: true,
        ),
      ).toBytes();

      final LogDefaults defaults = decodeLogDefaultsEnvelope(bytes);

      // '' means "prefix disambiguation disabled" — it must not be confused with
      // an absent field or coerced into the log revset.
      expect(defaults.shortPrefixes, equals(''));
      expect(defaults.log, equals('all()'));
      expect(defaults.syntheticElided, isTrue);
    });
  });
}
