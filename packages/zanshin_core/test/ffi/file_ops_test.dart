// SPDX-License-Identifier: MIT

// Wire-shape, decoder and guard tests for Story 9.22's two working-copy
// tracking adapters, using synthetic FlatBuffers buffers built via the
// generated `*ObjectBuilder`s. No real cdylib required — these pin the
// request encoding, BOTH `UntrackedReason` union arms through the decoder, and
// the adapters' NUL backstop, mirroring crates/zanshin-ffi/src/file_ops.rs.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/file_ops.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/worker/responses.dart';

fbs.MutationResultObjectBuilder mutation() => fbs.MutationResultObjectBuilder(
  newOpId: 'op1',
  newChangeIds: const <String>[],
  abandonedChangeIds: const <String>[],
  workingCopyChangeId: 'qpvuntsm',
  // The verbs never SET it (the CLI's track/untrack skip finish_transaction), but the wire
  // field exists on the shared table, so the decoder must still carry it.
  identityMissing: fbs.IdentityMissingObjectBuilder(name: true, email: false),
);

void expectIdentityMissingDecoded(MutationResult m) {
  expect(m.identityMissing, isNotNull);
  expect(m.identityMissing!.name, isTrue);
  expect(m.identityMissing!.email, isFalse);
}

/// A `SnapshotStats` carrying one entry per union arm plus one invalid-UTF-8 name.
fbs.SnapshotStatsObjectBuilder stats() => fbs.SnapshotStatsObjectBuilder(
  untracked: [
    fbs.UntrackedPathObjectBuilder(
      path: 'big.bin',
      reasonType: fbs.UntrackedReasonTypeId.FileTooLarge,
      reason: fbs.FileTooLargeObjectBuilder(size: 20, maxSize: 10),
    ),
    fbs.UntrackedPathObjectBuilder(
      path: 'other.txt',
      reasonType: fbs.UntrackedReasonTypeId.FileNotAutoTracked,
      reason: fbs.FileNotAutoTrackedObjectBuilder(),
    ),
  ],
  invalidUtf8Paths: ['dir/a\u{fffd}b'],
);

void expectBothArms(SnapshotStats s) {
  expect(s.untracked.map((u) => u.path), ['big.bin', 'other.txt']);
  final UntrackedReason big = s.untracked[0].reason;
  expect(big, isA<FileTooLarge>().having((r) => r.size, 'size', 20).having((r) => r.maxSize, 'maxSize', 10));
  expect(s.untracked[1].reason, isA<FileNotAutoTracked>());
  expect(s.invalidUtf8Paths, ['dir/a\u{fffd}b']);
}

Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

void main() {
  group('request wire shape', () {
    test('FileTrackRequest carries its tag, the paths in order, and the flag', () {
      final req = fbs.FileTrackRequest(
        fbs.FileTrackRequestObjectBuilder(
          kind: fbs.RequestKind.FileTrack,
          paths: ['b', 'a/'],
          includeIgnored: true,
        ).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.FileTrack);
      expect(req.paths, ['b', 'a/']);
      expect(req.includeIgnored, isTrue);
    });

    test('an absent include_ignored reads back false - the CLI default', () {
      final req = fbs.FileTrackRequest(
        fbs.FileTrackRequestObjectBuilder(kind: fbs.RequestKind.FileTrack, paths: ['a']).toBytes(),
      );
      expect(req.includeIgnored, isFalse);
    });

    test('FileUntrackRequest carries its own tag', () {
      final req = fbs.FileUntrackRequest(
        fbs.FileUntrackRequestObjectBuilder(kind: fbs.RequestKind.FileUntrack, paths: ['c.log']).toBytes(),
      );
      expect(req.kind, fbs.RequestKind.FileUntrack);
      expect(req.paths, ['c.log']);
    });
  });

  group('decoders', () {
    test('a TrackResult envelope decodes both UntrackedReason arms', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.TrackResult,
        data: fbs.TrackResultObjectBuilder(mutation: mutation(), numRebased: 0, snapshotStats: stats()),
      ).toBytes();

      final TrackResult result = decodeTrackResultEnvelope(bytes);

      expect(result.mutation.newOpId, 'op1');
      expect(result.mutation.workingCopyChangeId, 'qpvuntsm');
      expectIdentityMissingDecoded(result.mutation);
      expect(result.numRebased, 0);
      expectBothArms(result.snapshotStats);
    });

    test('an UntrackResult envelope decodes every field', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.UntrackResult,
        data: fbs.UntrackResultObjectBuilder(
          mutation: mutation(),
          numRebased: 2,
          unmatchedPaths: ['nope.txt'],
          snapshotStats: stats(),
          failedBookmarks: [fbs.GitExportFailureObjectBuilder(name: 'foo', remote: 'git', reason: 'Failed to set')],
          failedTags: const <fbs.GitExportFailureObjectBuilder>[],
        ),
      ).toBytes();

      final UntrackResult result = decodeUntrackResultEnvelope(bytes);

      expectIdentityMissingDecoded(result.mutation);
      expect(result.numRebased, 2);
      expect(result.unmatchedPaths, ['nope.txt']);
      expectBothArms(result.snapshotStats);
      expect(result.failedBookmarks.single.name, 'foo');
      expect(result.failedBookmarks.single.remote, 'git');
      expect(result.failedBookmarks.single.reason, 'Failed to set');
      expect(result.failedTags, isEmpty);
    });

    test('an UntrackedPath without a reason arm is refused, not guessed', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.TrackResult,
        data: fbs.TrackResultObjectBuilder(
          mutation: mutation(),
          snapshotStats: fbs.SnapshotStatsObjectBuilder(untracked: [fbs.UntrackedPathObjectBuilder(path: 'x')]),
        ),
      ).toBytes();

      expect(
        () => decodeTrackResultEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('a payload of the wrong type is refused by both decoders', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.MutationResult,
        data: mutation(),
      ).toBytes();

      expect(() => decodeTrackResultEnvelope(bytes), throwsA(isA<ZanshinFfiException>()));
      expect(() => decodeUntrackResultEnvelope(bytes), throwsA(isA<ZanshinFfiException>()));
    });

    test('the new error codes travel through with their context', () {
      expect(
        () => decodeUntrackResultEnvelope(errorEnvelope('jj.path_not_ignored', 'a.txt\nb.txt')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.path_not_ignored')
              .having((e) => e.context, 'context', 'a.txt\nb.txt'),
        ),
      );
      expect(
        () => decodeTrackResultEnvelope(errorEnvelope('jj.concurrent_working_copy', '')),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.concurrent_working_copy')),
      );
    });
  });

  group('adapter guards', () {
    // A raw handle of 0 would be `ffi.invalid_handle` if the call went through -
    // the NUL guard has to fire first.
    final nul = String.fromCharCode(0);

    test('zanshinFileTrack rejects an interior NUL in a path', () {
      expect(
        () => zanshinFileTrack(0, ['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
    });

    test('zanshinFileUntrack rejects an interior NUL in a path', () {
      expect(
        () => zanshinFileUntrack(0, ['ok', 'a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
    });
  });
}
