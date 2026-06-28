// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeRepoDetectEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side decode logic in isolation.
//
// Real cdylib coverage for the extern fn bodies is provided by the worker
// round-trip tests in test/worker/detect_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/repo_detect.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('decodeRepoDetectEnvelope decode contract', () {
    // ── Error envelope ────────────────────────────────────────────────────────

    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'jj.detect_failed',
          context: 'permission denied',
        ),
      ).toBytes();

      expect(
        () => decodeRepoDetectEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.detect_failed')
              .having((e) => e.context, 'context', 'permission denied'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-RepoDetect payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeRepoDetectEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── RepoKind variants ─────────────────────────────────────────────────────

    test('decodes RepoKind.Jj to RepoKind.jj', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoDetect,
        data: fbs.RepoDetectObjectBuilder(kind: fbs.RepoKind.Jj),
      ).toBytes();

      final RepoDetectResult result = decodeRepoDetectEnvelope(bytes);
      expect(result.kind, equals(RepoKind.jj));
      expect(result.suggestedRoot, isNull);
      expect(result.suggestedKind, isNull);
    });

    test('decodes RepoKind.Git to RepoKind.git', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoDetect,
        data: fbs.RepoDetectObjectBuilder(kind: fbs.RepoKind.Git),
      ).toBytes();

      final RepoDetectResult result = decodeRepoDetectEnvelope(bytes);
      expect(result.kind, equals(RepoKind.git));
      expect(result.suggestedRoot, isNull);
      expect(result.suggestedKind, isNull);
    });

    test('decodes RepoKind.Neither to RepoKind.neither', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoDetect,
        data: fbs.RepoDetectObjectBuilder(kind: fbs.RepoKind.Neither),
      ).toBytes();

      final RepoDetectResult result = decodeRepoDetectEnvelope(bytes);
      expect(result.kind, equals(RepoKind.neither));
      expect(result.suggestedRoot, isNull);
      expect(result.suggestedKind, isNull);
    });

    test('decodes RepoKind.PathNotFound to RepoKind.pathNotFound', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoDetect,
        data: fbs.RepoDetectObjectBuilder(kind: fbs.RepoKind.PathNotFound),
      ).toBytes();

      final RepoDetectResult result = decodeRepoDetectEnvelope(bytes);
      expect(result.kind, equals(RepoKind.pathNotFound));
      expect(result.suggestedRoot, isNull);
      expect(result.suggestedKind, isNull);
    });

    // ── Suggestion field semantics (D4) ───────────────────────────────────────

    test('suggestedRoot present populates suggestedKind', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoDetect,
        data: fbs.RepoDetectObjectBuilder(
          kind: fbs.RepoKind.Neither,
          suggestedRoot: '/home/user/myrepo',
          suggestedKind: fbs.RepoKind.Jj,
        ),
      ).toBytes();

      final RepoDetectResult result = decodeRepoDetectEnvelope(bytes);
      expect(result.kind, equals(RepoKind.neither));
      expect(result.suggestedRoot, equals('/home/user/myrepo'));
      expect(result.suggestedKind, equals(RepoKind.jj));
    });

    test('suggestedRoot absent leaves suggestedKind null regardless of wire value', () {
      // When suggestedRoot is null, suggestedKind must always be null —
      // presence of suggestedRoot is the suggestion flag (D4).
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoDetect,
        data: fbs.RepoDetectObjectBuilder(
          kind: fbs.RepoKind.PathNotFound,
          // suggestedRoot omitted → null on wire
          suggestedKind: fbs.RepoKind.Git,
        ),
      ).toBytes();

      final RepoDetectResult result = decodeRepoDetectEnvelope(bytes);
      expect(result.suggestedRoot, isNull);
      expect(result.suggestedKind, isNull, reason: 'suggestedKind must be null when suggestedRoot is absent');
    });
  });
}
