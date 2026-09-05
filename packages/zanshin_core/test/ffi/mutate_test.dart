// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeMutationResultEnvelope] and
// [decodeAbsorbResultEnvelope] using synthetic FlatBuffers buffers built via the
// generated `*ObjectBuilder`s. No real cdylib required — these tests exercise the
// Dart-side decode logic in isolation and mirror the Rust round-trips in
// crates/zanshin-ffi/src/envelope.rs::{ok_mutation_result, ok_absorb_result}
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

  // ── AbsorbResult decode contract (Story 9.3) ──────────────────────────────

  group('decodeAbsorbResultEnvelope decode contract', () {
    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.revset_parse_error', context: 'unknown function'),
      ).toBytes();

      expect(
        () => decodeAbsorbResultEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.context, 'context', 'unknown function'),
        ),
      );
    });

    test('throws ffi.unknown on ok envelope with non-AbsorbResult payload', () {
      // A plain MutationResult is what `restore` returns; absorb's decoder must not
      // silently accept it.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'abc', workingCopyChangeId: 'qpvuntsm'),
      ).toBytes();

      expect(
        () => decodeAbsorbResultEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes a fully-populated AbsorbResult including the nested MutationResult', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.AbsorbResult,
        data: fbs.AbsorbResultObjectBuilder(
          mutation: fbs.MutationResultObjectBuilder(
            newOpId: 'op99',
            newChangeIds: const [],
            abandonedChangeIds: const [],
            workingCopyChangeId: 'qpvuntsm',
          ),
          rewrittenChangeIds: ['rlvkpnrz', 'zsuskuln'],
          sourceChangeId: 'kkmpptxz',
          numRebased: 3,
          skippedPaths: [fbs.SkippedPathObjectBuilder(path: 'dir/link', reason: 'Is a symlink')],
        ),
      ).toBytes();

      final AbsorbResult result = decodeAbsorbResultEnvelope(bytes);

      expect(result.mutation.newOpId, equals('op99'));
      expect(result.mutation.workingCopyChangeId, equals('qpvuntsm'));
      expect(result.rewrittenChangeIds, equals(['rlvkpnrz', 'zsuskuln']));
      expect(result.sourceChangeId, equals('kkmpptxz'));
      expect(result.numRebased, equals(3));
      expect(result.skippedPaths, hasLength(1));
      expect(result.skippedPaths.single.path, equals('dir/link'));
      expect(result.skippedPaths.single.reason, equals('Is a symlink'));
    });

    test('decodes the nothing-absorbed shape with absent fields', () {
      // `sourceChangeId` absent is null-for-absence: the source was abandoned, or nothing
      // moved. It must decode to null, never to ''.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.AbsorbResult,
        data: fbs.AbsorbResultObjectBuilder(
          mutation: fbs.MutationResultObjectBuilder(newOpId: 'op1', workingCopyChangeId: 'qpvuntsm'),
        ),
      ).toBytes();

      final AbsorbResult result = decodeAbsorbResultEnvelope(bytes);

      expect(result.rewrittenChangeIds, isEmpty);
      expect(result.sourceChangeId, isNull);
      expect(result.numRebased, equals(0));
      expect(result.skippedPaths, isEmpty);
      expect(result.mutation.newChangeIds, isEmpty);
      expect(result.mutation.abandonedChangeIds, isEmpty);
    });

    test('decodes an AbsorbResult whose nested MutationResult is absent', () {
      // Rust never builds this shape, but the schema allows it — the decoder must degrade
      // rather than throw on a null nested table.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.AbsorbResult,
        data: fbs.AbsorbResultObjectBuilder(numRebased: 1),
      ).toBytes();

      final AbsorbResult result = decodeAbsorbResultEnvelope(bytes);

      expect(result.mutation.newOpId, isEmpty);
      expect(result.mutation.workingCopyChangeId, isEmpty);
      expect(result.numRebased, equals(1));
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

    test('zanshinRestore_rejects_interior_nul_in_from', () {
      expect(() => zanshinRestore(0, from: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinRestore_rejects_interior_nul_in_into', () {
      expect(() => zanshinRestore(0, into: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinRestore_rejects_interior_nul_in_changesIn', () {
      expect(() => zanshinRestore(0, changesIn: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinRestore_rejects_interior_nul_in_a_path', () {
      expect(
        () => zanshinRestore(0, paths: ['a${String.fromCharCode(0)}.txt']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
    });

    test('zanshinAbsorb_rejects_interior_nul_in_from', () {
      expect(() => zanshinAbsorb(0, from: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinAbsorb_rejects_interior_nul_in_into', () {
      expect(() => zanshinAbsorb(0, into: 'mutable${String.fromCharCode(0)}()'), throwsArgumentError);
    });

    test('zanshinAbsorb_rejects_interior_nul_in_a_path', () {
      expect(
        () => zanshinAbsorb(0, paths: ['a${String.fromCharCode(0)}.txt']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
    });
  });
}
