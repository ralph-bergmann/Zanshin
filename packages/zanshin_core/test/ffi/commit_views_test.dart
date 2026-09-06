// SPDX-License-Identifier: MIT

// Decode-contract tests for Story 9.6's three commit-view decoders, using
// synthetic FlatBuffers buffers built via the generated `*ObjectBuilder`s. No real
// cdylib required - these tests exercise the Dart-side decode logic in isolation
// and mirror the Rust round-trips in crates/zanshin-ffi/src/commit_views.rs
// (AR-P-7 parity).
//
// Also covers the adapters' interior-NUL guards, which fire BEFORE any FFI call,
// so a raw handle of 0 never reaches the cdylib.
//
// Mirrors packages/zanshin_core/test/ffi/file_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/status.dart' show FileChangeKind;
import 'package:zanshin_core/src/worker/responses.dart';

/// An error envelope carrying [code].
Uint8List errorEnvelope(String code, String context) => fbs.EnvelopeObjectBuilder(
  ok: false,
  error: fbs.FfiErrorObjectBuilder(code: code, context: context),
).toBytes();

/// An ok envelope whose union variant is deliberately the WRONG one.
Uint8List wrongPayload() => fbs.EnvelopeObjectBuilder(
  ok: true,
  dataType: fbs.PayloadTypeId.RepoHandle,
  data: fbs.RepoHandleObjectBuilder(handle: 0),
).toBytes();

/// A minimal `Change` table — every field the shared `mapChangeTable` reads.
fbs.ChangeObjectBuilder changeBuilder({String id = 'qpvuntsm', String commitId = 'abc123'}) => fbs.ChangeObjectBuilder(
  id: id,
  commitId: commitId,
  parents: ['parent'],
  description: 'a description',
  author: fbs.SignatureObjectBuilder(
    name: 'zanshin',
    email: 'zanshin@localhost',
    timestampMillis: 42,
    tzOffsetMinutes: 60,
  ),
  committer: fbs.SignatureObjectBuilder(
    name: 'zanshin',
    email: 'zanshin@localhost',
    timestampMillis: 42,
    tzOffsetMinutes: 60,
  ),
  conflict: fbs.ConflictState.Clean,
  divergent: true,
);

void main() {
  group('decodeShowViewEnvelope decode contract', () {
    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeShowViewEnvelope(errorEnvelope('jj.revset_parse_error', 'syntax error')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.context, 'context', 'syntax error'),
        ),
      );
    });

    test('throws ffi.unknown on an ok envelope with a non-ShowView payload', () {
      expect(
        () => decodeShowViewEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes the nested Change and the per-path change list', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.ShowView,
        data: fbs.ShowViewObjectBuilder(
          entries: [
            fbs.ShowEntryObjectBuilder(
              change: changeBuilder(),
              fileChanges: [
                fbs.FileChangeObjectBuilder(path: 'a.txt', kind: fbs.ChangeKind.Added),
                fbs.FileChangeObjectBuilder(
                  path: 'new.txt',
                  kind: fbs.ChangeKind.Renamed,
                  fromPath: 'old.txt',
                ),
              ],
            ),
          ],
        ),
      ).toBytes();

      final List<ShowEntry> entries = decodeShowViewEnvelope(bytes);

      expect(entries, hasLength(1));
      // The nested Change goes through change.dart's shared mapper, so every field
      // it decodes is available here without a second projection.
      expect(entries.single.change.id, 'qpvuntsm');
      expect(entries.single.change.commitId, 'abc123');
      expect(entries.single.change.description, 'a description');
      expect(entries.single.change.author.email, 'zanshin@localhost');
      expect(entries.single.change.divergent, isTrue);

      expect(entries.single.fileChanges, hasLength(2));
      expect(entries.single.fileChanges[0].path, 'a.txt');
      expect(entries.single.fileChanges[0].kind, FileChangeKind.added);
      expect(entries.single.fileChanges[0].fromPath, isNull, reason: 'from_path is null-for-absence');
      expect(entries.single.fileChanges[1].kind, FileChangeKind.renamed);
      expect(entries.single.fileChanges[1].fromPath, 'old.txt');
    });

    test('an empty entry list decodes to an empty list, not an error', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.ShowView,
        data: fbs.ShowViewObjectBuilder(entries: []),
      ).toBytes();

      expect(decodeShowViewEnvelope(bytes), isEmpty);
    });

    test('a ShowEntry missing its nested Change surfaces ffi.unknown, not a TypeError', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.ShowView,
        data: fbs.ShowViewObjectBuilder(entries: [fbs.ShowEntryObjectBuilder(fileChanges: [])]),
      ).toBytes();

      expect(
        () => decodeShowViewEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'ffi.unknown')
              .having((e) => e.context, 'context', contains('ShowEntry')),
        ),
      );
    });
  });

  group('decodeEvologViewEnvelope decode contract', () {
    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeEvologViewEnvelope(errorEnvelope('jj.config_error', 'not a table')),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_error')),
      );
    });

    test('throws ffi.unknown on an ok envelope with a non-EvologView payload', () {
      expect(
        () => decodeEvologViewEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('an absent operationId decodes to null, and its entry carries no predecessors', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.EvologView,
        data: fbs.EvologViewObjectBuilder(
          entries: [
            fbs.EvologEntryObjectBuilder(
              change: changeBuilder(commitId: 'cur'),
              predecessorCommitIds: ['prev'],
              operationId: 'op1',
            ),
            // The walk's flush tail: no recording operation, and therefore no
            // predecessors either.
            fbs.EvologEntryObjectBuilder(
              change: changeBuilder(commitId: 'prev'),
              predecessorCommitIds: [],
            ),
          ],
        ),
      ).toBytes();

      final List<EvologEntry> entries = decodeEvologViewEnvelope(bytes);

      expect(entries, hasLength(2));
      expect(entries[0].change.commitId, 'cur');
      expect(entries[0].predecessorCommitIds, ['prev']);
      expect(entries[0].operationId, 'op1');
      expect(entries[1].operationId, isNull, reason: 'null-for-absence marks a possibly truncated walk');
      expect(entries[1].predecessorCommitIds, isEmpty);
    });

    test('an empty entry list decodes to an empty list, not an error', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.EvologView,
        data: fbs.EvologViewObjectBuilder(entries: []),
      ).toBytes();

      expect(decodeEvologViewEnvelope(bytes), isEmpty);
    });

    test('an EvologEntry missing its nested Change surfaces ffi.unknown', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.EvologView,
        data: fbs.EvologViewObjectBuilder(entries: [fbs.EvologEntryObjectBuilder(predecessorCommitIds: [])]),
      ).toBytes();

      expect(
        () => decodeEvologViewEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'ffi.unknown')
              .having((e) => e.context, 'context', contains('EvologEntry')),
        ),
      );
    });
  });

  group('decodeInterdiffViewEnvelope decode contract', () {
    test('throws ZanshinFfiException on an error envelope', () {
      expect(
        () => decodeInterdiffViewEnvelope(errorEnvelope('jj.change_not_found', 'zzz')),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', 'zzz'),
        ),
      );
    });

    test('throws ffi.unknown on an ok envelope with a non-InterdiffView payload', () {
      expect(
        () => decodeInterdiffViewEnvelope(wrongPayload()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes the shared FileChange vocabulary', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.InterdiffView,
        data: fbs.InterdiffViewObjectBuilder(
          fileChanges: [
            fbs.FileChangeObjectBuilder(path: 'b.txt', kind: fbs.ChangeKind.Added),
            fbs.FileChangeObjectBuilder(path: 'gone.txt', kind: fbs.ChangeKind.Removed),
          ],
        ),
      ).toBytes();

      final InterdiffView view = decodeInterdiffViewEnvelope(bytes);

      expect(view.fileChanges.map((c) => c.path), ['b.txt', 'gone.txt']);
      expect(view.fileChanges.map((c) => c.kind), [FileChangeKind.added, FileChangeKind.removed]);
    });

    test('an empty change list decodes to an empty list, not an error', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.InterdiffView,
        data: fbs.InterdiffViewObjectBuilder(fileChanges: []),
      ).toBytes();

      expect(decodeInterdiffViewEnvelope(bytes).fileChanges, isEmpty);
    });

    test('baseHasConflicts decodes both arms, and an absent field is false', () {
      for (final flag in [false, true]) {
        final Uint8List bytes = fbs.EnvelopeObjectBuilder(
          ok: true,
          dataType: fbs.PayloadTypeId.InterdiffView,
          data: fbs.InterdiffViewObjectBuilder(fileChanges: [], baseHasConflicts: flag),
        ).toBytes();

        expect(decodeInterdiffViewEnvelope(bytes).baseHasConflicts, flag);
      }

      // A payload written before the field existed carries no slot for it. The
      // FlatBuffers default is `false` — "nothing conflicted", i.e. exactly the
      // pre-change meaning — never a null the model would have to represent.
      final Uint8List legacy = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.InterdiffView,
        data: fbs.InterdiffViewObjectBuilder(fileChanges: []),
      ).toBytes();

      expect(decodeInterdiffViewEnvelope(legacy).baseHasConflicts, isFalse);
    });
  });

  // ── Adapter guards (no cdylib call; mirrors mutate_test.dart) ──────────────

  group('commit_views.dart adapters reject an interior NUL', () {
    test('zanshinShow_rejects_interior_nul_in_revset', () {
      expect(() => zanshinShow(0, revset: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinEvolog_rejects_interior_nul_in_revset', () {
      expect(() => zanshinEvolog(0, revset: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinInterdiff_rejects_interior_nul_in_from', () {
      expect(() => zanshinInterdiff(0, from: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinInterdiff_rejects_interior_nul_in_to', () {
      expect(() => zanshinInterdiff(0, to: 'qpv${String.fromCharCode(0)}x'), throwsArgumentError);
    });

    test('zanshinInterdiff_rejects_interior_nul_in_a_path', () {
      expect(
        () => zanshinInterdiff(0, from: 'qpvuntsm', paths: ['a${String.fromCharCode(0)}.txt']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
    });

    test('zanshinEvolog_rejects_a_negative_limit', () {
      // The wire field is a `uint`; a negative value could only be a caller bug, and
      // silently wrapping it would produce a nonsensical limit rather than a refusal.
      expect(() => zanshinEvolog(0, limit: -1), throwsArgumentError);
    });

    test('zanshinShow_rejects_a_negative_limit', () {
      // Same guard, same reason: `show`'s limit rides the same `uint` field shape,
      // and both `0` and "no limit" are already spelled without it.
      expect(() => zanshinShow(0, limit: -1), throwsArgumentError);
    });
  });
}
