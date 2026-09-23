// SPDX-License-Identifier: MIT

// Decoder tests for Story 9.26's pre-verb snapshot report, using synthetic
// FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real cdylib
// required — these pin every `Precondition` / `FinishFacts` field through the
// decoders, null for absence on the optional tables, the report on an ERROR
// envelope, and `MutationResult.finish`, mirroring
// crates/zanshin-ffi/src/snapshot.rs.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/file_ops.dart' show FileTooLarge;
import 'package:zanshin_core/src/ffi/git.dart' show GitRefUpdateKind;
import 'package:zanshin_core/src/ffi/mutate.dart';
import 'package:zanshin_core/src/ffi/precondition.dart';
import 'package:zanshin_core/src/worker/responses.dart';

fbs.FinishFactsObjectBuilder finishFacts() => fbs.FinishFactsObjectBuilder(
  workingCopyBecameImmutable: true,
  gitHeadUpdateFailed: true,
  exportFailedBookmarks: [fbs.GitExportFailureObjectBuilder(name: 'foo', remote: 'git', reason: 'Failed to set')],
  exportFailedTags: [fbs.GitExportFailureObjectBuilder(name: 'v1', remote: 'git', reason: 'Tag clash')],
);

void expectFinishDecoded(FinishFacts? f) {
  expect(f, isNotNull);
  expect(f!.workingCopyBecameImmutable, isTrue);
  expect(f.gitHeadUpdateFailed, isTrue);
  expect(f.exportFailedBookmarks.single.name, 'foo');
  expect(f.exportFailedBookmarks.single.remote, 'git');
  expect(f.exportFailedBookmarks.single.reason, 'Failed to set');
  expect(f.exportFailedTags.single.name, 'v1');
  expect(f.exportFailedTags.single.reason, 'Tag clash');
}

/// A `Precondition` with every field away from its default.
fbs.PreconditionObjectBuilder fullPrecondition() => fbs.PreconditionObjectBuilder(
  wasSnapshotTaken: true,
  snapshotStats: fbs.SnapshotStatsObjectBuilder(
    untracked: [
      fbs.UntrackedPathObjectBuilder(
        path: 'big.bin',
        reasonType: fbs.UntrackedReasonTypeId.FileTooLarge,
        reason: fbs.FileTooLargeObjectBuilder(size: 20, maxSize: 10),
      ),
    ],
    invalidUtf8Paths: ['dir/a\u{fffd}b'],
  ),
  gitHeadImported: true,
  gitHeadReset: true,
  gitHeadRebased: 3,
  snapshotRebased: 4,
  workingCopyImmutableNewCommit: true,
  gitRefs: fbs.GitImportResultObjectBuilder(
    mutation: fbs.MutationResultObjectBuilder(newOpId: 'op-refs', workingCopyChangeId: 'qpvuntsm'),
    changedBookmarks: [
      fbs.GitRefUpdateObjectBuilder(name: 'main', remote: 'git', kind: fbs.GitRefUpdateKind.Updated, tracked: true),
    ],
    changedTags: const <fbs.GitRefUpdateObjectBuilder>[],
    abandonedChangeIds: ['zzzz'],
    numRewritten: 2,
    failedRefNames: ['refs/remotes/git/x'],
  ),
  gitRefsRebased: 5,
  jjconflictFilesPresent: true,
  finish: finishFacts(),
);

void expectFullPreconditionDecoded(Precondition p) {
  expect(p.wasSnapshotTaken, isTrue);
  expect(p.snapshotStats.untracked.single.path, 'big.bin');
  expect(p.snapshotStats.untracked.single.reason, isA<FileTooLarge>().having((r) => r.maxSize, 'maxSize', 10));
  expect(p.snapshotStats.invalidUtf8Paths, ['dir/a\u{fffd}b']);
  expect(p.gitHeadImported, isTrue);
  expect(p.gitHeadReset, isTrue);
  expect(p.gitHeadRebased, 3);
  expect(p.snapshotRebased, 4);
  expect(p.workingCopyImmutableNewCommit, isTrue);
  expect(p.gitRefs, isNotNull);
  expect(p.gitRefs!.mutation.newOpId, 'op-refs');
  expect(p.gitRefs!.changedBookmarks.single.name, 'main');
  expect(p.gitRefs!.changedBookmarks.single.kind, GitRefUpdateKind.updated);
  expect(p.gitRefs!.changedBookmarks.single.tracked, isTrue);
  expect(p.gitRefs!.abandonedChangeIds, ['zzzz']);
  expect(p.gitRefs!.numRewritten, 2);
  expect(p.gitRefs!.failedRefNames, ['refs/remotes/git/x']);
  expect(p.gitRefsRebased, 5);
  expect(p.jjconflictFilesPresent, isTrue);
  expectFinishDecoded(p.finish);
}

Uint8List snapshotOk(fbs.PreconditionObjectBuilder? precondition) =>
    fbs.EnvelopeObjectBuilder(ok: true, precondition: precondition).toBytes();

void main() {
  group('Precondition decoders', () {
    test('a snapshot envelope decodes every Precondition field', () {
      expectFullPreconditionDecoded(decodeSnapshotEnvelope(snapshotOk(fullPrecondition())));
    });

    test('absent optional tables decode as null and the rest as defaults', () {
      final Precondition p = decodeSnapshotEnvelope(snapshotOk(fbs.PreconditionObjectBuilder()));

      expect(p.wasSnapshotTaken, isFalse);
      expect(p.snapshotStats.untracked, isEmpty);
      expect(p.snapshotStats.invalidUtf8Paths, isEmpty);
      expect(p.gitHeadImported, isFalse);
      expect(p.gitHeadReset, isFalse);
      expect(p.gitHeadRebased, 0);
      expect(p.snapshotRebased, 0);
      expect(p.workingCopyImmutableNewCommit, isFalse);
      expect(p.gitRefs, isNull, reason: 'null for absence: the refs import did not run');
      expect(p.gitRefsRebased, 0);
      expect(p.jjconflictFilesPresent, isFalse);
      expect(p.finish, isNull, reason: 'null for absence: every finish fact at its default');
    });

    test('an ok snapshot envelope without a report is refused, not guessed', () {
      expect(
        () => decodeSnapshotEnvelope(snapshotOk(null)),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('a stale refusal travels through with its three-line context', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.stale_working_copy', context: 'stale\nwc-op\nrepo-op'),
        precondition: fbs.PreconditionObjectBuilder(),
      ).toBytes();

      expect(
        () => decodeSnapshotEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.stale_working_copy')
              .having((e) => e.context, 'context', 'stale\nwc-op\nrepo-op'),
        ),
      );
    });

    test('decodeEnvelopePrecondition reads the report off ANY envelope, error included', () {
      final Uint8List error = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.change_not_found', context: 'zzzz'),
        precondition: fullPrecondition(),
      ).toBytes();
      final Uint8List read = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op1'),
        precondition: fbs.PreconditionObjectBuilder(wasSnapshotTaken: true),
      ).toBytes();

      expectFullPreconditionDecoded(decodeEnvelopePrecondition(error)!);
      expect(decodeEnvelopePrecondition(read)!.wasSnapshotTaken, isTrue);
    });

    test('an envelope of a no-precondition call decodes as null', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'ffi.invalid_handle'),
      ).toBytes();

      expect(decodeEnvelopePrecondition(bytes), isNull);
    });
  });

  group('MutationResult.finish', () {
    test('a present FinishFacts table decodes every field', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op1', finish: finishFacts()),
      ).toBytes();

      expectFinishDecoded(decodeMutationResultEnvelope(bytes).finish);
    });

    test('an absent FinishFacts table is null, never a value of defaults', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: fbs.MutationResultObjectBuilder(newOpId: 'op1'),
      ).toBytes();

      expect(decodeMutationResultEnvelope(bytes).finish, isNull);
    });

    test('the nested mutation of an AbsorbResult carries finish too', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.AbsorbResult,
        data: fbs.AbsorbResultObjectBuilder(
          mutation: fbs.MutationResultObjectBuilder(newOpId: 'op1', finish: finishFacts()),
        ),
      ).toBytes();

      expectFinishDecoded(decodeAbsorbResultEnvelope(bytes).mutation.finish);
    });
  });
}
