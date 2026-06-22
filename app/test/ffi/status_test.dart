// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeStatusEnvelope] using synthetic FlatBuffers
// buffers built via the generated `*ObjectBuilder`s. No real cdylib required —
// these tests exercise the Dart-side decode logic in isolation.
//
// Mirrors app/test/ffi/diagnostics_test.dart (decode-contract section).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin/src/ffi/status.dart';
import 'package:zanshin/src/worker/responses.dart';

void main() {
  group('decodeStatusEnvelope decode contract', () {
    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(
          code: 'ffi.invalid_handle',
          context: 'test error',
        ),
      ).toBytes();

      expect(
        () => decodeStatusEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'ffi.invalid_handle',
          ),
        ),
      );
    });

    test('throws ffi.unknown on ok envelope with non-Status payload', () {
      // ok == true but union variant is RepoHandle, not Status: the
      // discriminant guard must surface ZanshinFfiException('ffi.unknown'),
      // not a raw TypeError from an unguarded cast.
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeStatusEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'ffi.unknown',
          ),
        ),
      );
    });

    test('decodes Status payload with one of each ChangeKind correctly', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.Status,
        data: fbs.StatusObjectBuilder(
          workingCopyChangeId: 'qpvuntsm',
          parentChangeId: 'zzzzzzzz',
          files: [
            fbs.FileChangeObjectBuilder(
              path: 'added.rs',
              kind: fbs.ChangeKind.Added,
            ),
            fbs.FileChangeObjectBuilder(
              path: 'modified.rs',
              kind: fbs.ChangeKind.Modified,
            ),
            fbs.FileChangeObjectBuilder(
              path: 'removed.rs',
              kind: fbs.ChangeKind.Removed,
            ),
            fbs.FileChangeObjectBuilder(
              path: 'new_name.rs',
              kind: fbs.ChangeKind.Renamed,
              fromPath: 'old_name.rs',
            ),
            fbs.FileChangeObjectBuilder(
              path: 'copy.rs',
              kind: fbs.ChangeKind.Copied,
              fromPath: 'source.rs',
            ),
          ],
        ),
      ).toBytes();

      final WorkingCopyStatus status = decodeStatusEnvelope(bytes);

      expect(status.workingCopyChangeId, equals('qpvuntsm'));
      expect(status.parentChangeId, equals('zzzzzzzz'));
      expect(status.files, hasLength(5));

      final FileChange added = status.files[0];
      expect(added.path, equals('added.rs'));
      expect(added.kind, equals(FileChangeKind.added));
      expect(added.fromPath, isNull);

      final FileChange modified = status.files[1];
      expect(modified.path, equals('modified.rs'));
      expect(modified.kind, equals(FileChangeKind.modified));
      expect(modified.fromPath, isNull);

      final FileChange removed = status.files[2];
      expect(removed.path, equals('removed.rs'));
      expect(removed.kind, equals(FileChangeKind.removed));
      expect(removed.fromPath, isNull);

      final FileChange renamed = status.files[3];
      expect(renamed.path, equals('new_name.rs'));
      expect(renamed.kind, equals(FileChangeKind.renamed));
      expect(renamed.fromPath, equals('old_name.rs'));

      final FileChange copied = status.files[4];
      expect(copied.path, equals('copy.rs'));
      expect(copied.kind, equals(FileChangeKind.copied));
      expect(copied.fromPath, equals('source.rs'));
    });
  });
}
