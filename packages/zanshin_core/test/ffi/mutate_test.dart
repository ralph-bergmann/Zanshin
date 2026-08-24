// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeMutationResultEnvelope] using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required — these tests exercise the Dart-side decode logic in isolation and
// mirror the Rust round-trip in crates/zanshin-ffi/src/envelope.rs::ok_mutation_result
// (AR-P-7 parity).
//
// Mirrors packages/zanshin_core/test/ffi/graph_test.dart / change_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/mutate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('decodeMutationResultEnvelope decode contract', () {
    // ── Error envelope ────────────────────────────────────────────────────────

    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.invalid_input', context: 'empty parents'),
      ).toBytes();

      expect(
        () => decodeMutationResultEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'empty parents'),
        ),
      );
    });

    // ── Wrong payload type ────────────────────────────────────────────────────

    test('throws ffi.unknown on ok envelope with non-MutationResult payload', () {
      // ok == true but union variant is RepoHandle, not MutationResult: the
      // discriminant guard must surface ZanshinFfiException('ffi.unknown').
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeMutationResultEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown'),
        ),
      );
    });

    // ── Full round-trip field equality ────────────────────────────────────────

    test('decodes a fully-populated MutationResult', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(
          newOpId: 'abc123',
          newChangeIds: ['qpvuntsm'],
          abandonedChangeIds: ['rlvkpnrz', 'zsuskuln'],
          workingCopyChangeId: 'qpvuntsm',
        ),
      ).toBytes();

      final MutationResult result = decodeMutationResultEnvelope(bytes);

      expect(result.newOpId, equals('abc123'));
      expect(result.newChangeIds, equals(['qpvuntsm']));
      expect(result.abandonedChangeIds, equals(['rlvkpnrz', 'zsuskuln']));
      expect(result.workingCopyChangeId, equals('qpvuntsm'));
    });

    // ── describe/edit shape: nothing minted or abandoned ──────────────────────

    test('decodes empty newChangeIds/abandonedChangeIds as empty lists', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(
          newOpId: 'def456',
          newChangeIds: const [],
          abandonedChangeIds: const [],
          workingCopyChangeId: 'qpvuntsm',
        ),
      ).toBytes();

      final MutationResult result = decodeMutationResultEnvelope(bytes);

      expect(result.newChangeIds, isEmpty);
      expect(result.abandonedChangeIds, isEmpty);
    });

    // ── Absent (null) list fields decode as empty, not a crash ────────────────

    test('decodes an envelope with absent list fields as empty lists', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(
          newOpId: 'ghi789',
          workingCopyChangeId: 'qpvuntsm',
        ),
      ).toBytes();

      final MutationResult result = decodeMutationResultEnvelope(bytes);

      expect(result.newChangeIds, isEmpty);
      expect(result.abandonedChangeIds, isEmpty);
      expect(result.newOpId, equals('ghi789'));
      expect(result.workingCopyChangeId, equals('qpvuntsm'));
    });
  });

  // ── Adapter guards (no cdylib call; mirrors graph_test.dart) ──────────────

  group('mutate.dart adapters reject an interior NUL', () {
    test('zanshinDescribe_rejects_interior_nul_in_changeId', () {
      expect(
        () => zanshinDescribe(0, 'qpv${String.fromCharCode(0)}x', 'desc'),
        throwsArgumentError,
      );
    });

    test('zanshinDescribe_rejects_interior_nul_in_description', () {
      expect(
        () => zanshinDescribe(0, 'qpvuntsm', 'desc${String.fromCharCode(0)}x'),
        throwsArgumentError,
      );
    });

    test('zanshinEdit_rejects_interior_nul_in_changeId', () {
      expect(
        () => zanshinEdit(0, 'qpv${String.fromCharCode(0)}x'),
        throwsArgumentError,
      );
    });

    test('zanshinGitFetch_rejects_interior_nul_in_remoteName', () {
      expect(
        () => zanshinGitFetch(0, 'origin${String.fromCharCode(0)}x'),
        throwsArgumentError,
      );
    });
  });
}
