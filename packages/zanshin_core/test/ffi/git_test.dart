// SPDX-License-Identifier: MIT

// Decode-contract tests for [decodeGitImportResultEnvelope] and
// [decodeGitExportResultEnvelope] using synthetic FlatBuffers buffers built via the
// generated `*ObjectBuilder`s. No real cdylib required — these tests exercise the
// Dart-side decode logic in isolation and mirror the Rust round-trips in
// crates/zanshin-ffi/src/git.rs::{git_import_result_to_envelope,
// git_export_result_to_envelope} (AR-P-7 parity).
//
// Mirrors packages/zanshin_core/test/ffi/mutate_test.dart / file_test.dart.

import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/envelope_zanshin.ffi_generated.dart' as fbs;
import 'package:zanshin_core/src/ffi/git.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// A literal NUL (U+0000), the character every adapter must refuse in a
/// caller-supplied string. `String.fromCharCode` is not a constant expression, so
/// this cannot be `const` — and a raw NUL byte has no business sitting in a source
/// file.
final _nul = String.fromCharCode(0);

void main() {
  group('decodeGitImportResultEnvelope decode contract', () {
    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.not_a_git_repo'),
      ).toBytes();

      expect(
        () => decodeGitImportResultEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.not_a_git_repo')),
      );
    });

    test('throws ffi.unknown on ok envelope with a non-GitImportResult payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeGitImportResultEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes a fully-populated GitImportResult, every ref-update kind included', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GitImportResult,
        data: fbs.GitImportResultObjectBuilder(
          mutation: fbs.MutationResultObjectBuilder(
            newOpId: 'op99',
            newChangeIds: const <String>[],
            abandonedChangeIds: const <String>[],
            workingCopyChangeId: 'qpvuntsm',
          ),
          changedBookmarks: [
            fbs.GitRefUpdateObjectBuilder(
              name: 'main',
              remote: 'origin',
              kind: fbs.GitRefUpdateKind.New,
              tracked: true,
            ),
            fbs.GitRefUpdateObjectBuilder(
              name: 'feature',
              remote: 'origin',
              kind: fbs.GitRefUpdateKind.Updated,
              tracked: false,
            ),
          ],
          changedTags: [
            fbs.GitRefUpdateObjectBuilder(
              name: 'v1',
              remote: 'origin',
              kind: fbs.GitRefUpdateKind.Deleted,
              tracked: true,
            ),
          ],
          abandonedChangeIds: ['rlvkpnrz'],
          numRewritten: 4,
          // The reserved-namespace case the CLI hints about.
          failedRefNames: ['refs/remotes/git/stolen'],
        ),
        warnings: [
          fbs.WarningObjectBuilder(
            code: ZanshinWarningCode.gitImportFailed,
            message: 'Failed to import some Git refs:\n  refs/remotes/git/stolen',
          ),
        ],
      ).toBytes();

      final GitImportResult result = decodeGitImportResultEnvelope(bytes);

      expect(result.mutation.newOpId, equals('op99'));
      expect(result.mutation.workingCopyChangeId, equals('qpvuntsm'));
      expect(result.warnings.single.code, equals('jj.git_import_failed'));
      expect(result.warnings.single.message, equals('Failed to import some Git refs:\n  refs/remotes/git/stolen'));
      expect(result.mutation.warnings, isEmpty, reason: 'a nested payload carries no warnings of its own');
      expect(result.changedBookmarks.map((u) => u.name), equals(['main', 'feature']));
      expect(result.changedBookmarks.first.remote, equals('origin'));
      expect(result.changedBookmarks.first.kind, equals(GitRefUpdateKind.created));
      expect(result.changedBookmarks.first.tracked, isTrue);
      expect(result.changedBookmarks.last.kind, equals(GitRefUpdateKind.updated));
      expect(result.changedBookmarks.last.tracked, isFalse);
      expect(result.changedTags.single.kind, equals(GitRefUpdateKind.deleted));
      expect(result.abandonedChangeIds, equals(['rlvkpnrz']));
      expect(result.numRewritten, equals(4));
      expect(result.failedRefNames, equals(['refs/remotes/git/stolen']));
    });

    // An import that changed nothing still decodes as a success — absent vectors are
    // empty lists, never a crash, and the no-op contract is a success by design.
    test('decodes an empty GitImportResult with absent vectors', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GitImportResult,
        data: fbs.GitImportResultObjectBuilder(numRewritten: 0),
      ).toBytes();

      final GitImportResult result = decodeGitImportResultEnvelope(bytes);

      expect(result.mutation.newOpId, isEmpty);
      expect(result.warnings, isEmpty, reason: 'an absent warnings vector reads as []');
      expect(result.changedBookmarks, isEmpty);
      expect(result.changedTags, isEmpty);
      expect(result.abandonedChangeIds, isEmpty);
      expect(result.failedRefNames, isEmpty);
    });
  });

  group('decodeGitExportResultEnvelope decode contract', () {
    test('throws ZanshinFfiException on error envelope', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: false,
        error: fbs.FfiErrorObjectBuilder(code: 'jj.jj_lib_error', context: 'boom'),
      ).toBytes();

      expect(
        () => decodeGitExportResultEnvelope(bytes),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.jj_lib_error')
              .having((e) => e.context, 'context', 'boom'),
        ),
      );
    });

    test('throws ffi.unknown on ok envelope with a non-GitExportResult payload', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.RepoHandle,
        data: fbs.RepoHandleObjectBuilder(handle: 0),
      ).toBytes();

      expect(
        () => decodeGitExportResultEnvelope(bytes),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.unknown')),
      );
    });

    test('decodes a GitExportResult carrying the flattened failure reason', () {
      final Uint8List bytes = fbs.EnvelopeObjectBuilder(
        ok: true,
        dataType: fbs.PayloadTypeId.GitExportResult,
        data: fbs.GitExportResultObjectBuilder(
          mutation: fbs.MutationResultObjectBuilder(
            newOpId: 'op7',
            newChangeIds: const <String>[],
            abandonedChangeIds: const <String>[],
            workingCopyChangeId: 'qpvuntsm',
          ),
          failedBookmarks: [
            fbs.GitExportFailureObjectBuilder(
              name: 'foo/bar',
              remote: 'git',
              reason: 'Failed to set: reference already exists',
            ),
          ],
          failedTags: const <fbs.GitExportFailureObjectBuilder>[],
        ),
        warnings: [
          fbs.WarningObjectBuilder(
            code: ZanshinWarningCode.gitExportFailed,
            message: 'Failed to export some bookmarks:\n  foo/bar@git: Failed to set: reference already exists',
          ),
        ],
      ).toBytes();

      final GitExportResult result = decodeGitExportResultEnvelope(bytes);

      expect(result.mutation.newOpId, equals('op7'));
      expect(result.warnings.map((w) => w.code), equals(['jj.git_export_failed']));
      expect(result.mutation.warnings, isEmpty);
      expect(result.failedBookmarks, hasLength(1));
      expect(result.failedBookmarks.single.name, equals('foo/bar'));
      expect(result.failedBookmarks.single.remote, equals('git'));
      expect(
        result.failedBookmarks.single.reason,
        equals('Failed to set: reference already exists'),
        reason: 'the whole source chain rides the wire, not just "Failed to set"',
      );
      expect(result.failedTags, isEmpty);
    });
  });

  // ── Adapter guards (no cdylib call; mirrors mutate_test.dart) ──────────────

  group('git.dart adapters reject an interior NUL', () {
    test('zanshinGitRemoteAdd_rejects_interior_nul_in_name', () {
      expect(() => zanshinGitRemoteAdd(0, name: 'ori${_nul}gin', url: '/tmp/x'), throwsArgumentError);
    });

    test('zanshinGitRemoteAdd_rejects_interior_nul_in_url', () {
      expect(() => zanshinGitRemoteAdd(0, name: 'origin', url: '/tmp$_nul/x'), throwsArgumentError);
    });

    test('zanshinGitRemoteAdd_rejects_interior_nul_in_pushUrl', () {
      expect(
        () => zanshinGitRemoteAdd(0, name: 'origin', url: '/tmp/x', pushUrl: '/tmp$_nul/y'),
        throwsArgumentError,
      );
    });

    test('zanshinGitRemoteRemove_rejects_interior_nul_in_name', () {
      expect(() => zanshinGitRemoteRemove(0, 'ori${_nul}gin'), throwsArgumentError);
    });

    test('zanshinGitRemoteRename_rejects_interior_nul_in_oldName', () {
      expect(() => zanshinGitRemoteRename(0, 'ori${_nul}gin', 'upstream'), throwsArgumentError);
    });

    test('zanshinGitRemoteRename_rejects_interior_nul_in_newName', () {
      expect(() => zanshinGitRemoteRename(0, 'origin', 'up${_nul}stream'), throwsArgumentError);
    });

    test('zanshinGitRemoteSetUrl_rejects_interior_nul_in_name', () {
      expect(() => zanshinGitRemoteSetUrl(0, name: 'ori${_nul}gin'), throwsArgumentError);
    });

    test('zanshinGitRemoteSetUrl_rejects_interior_nul_in_url', () {
      expect(() => zanshinGitRemoteSetUrl(0, name: 'origin', url: '/tmp$_nul/x'), throwsArgumentError);
    });

    test('zanshinGitRemoteSetUrl_rejects_interior_nul_in_pushUrl', () {
      expect(() => zanshinGitRemoteSetUrl(0, name: 'origin', pushUrl: '/tmp$_nul/y'), throwsArgumentError);
    });
  });
}
