// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.getChange] and [RepoHandle.getChange].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors the patterns from
// app/test/worker/status_test.dart.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart';
import 'package:zanshin_core/src/ffi/status.dart' show WorkingCopyStatus;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.getChange round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_change_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('getChange_on_fresh_init_returns_valid_wc_change', () async {
      // Init a fresh repo, get the WC change id via status, then read it as a Change.
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // Obtain the WC change id via status (not hard-coding a fixture id).
      final WorkingCopyStatus status = await handle.status();
      final String wcChangeId = status.workingCopyChangeId;
      expect(wcChangeId, isNotEmpty, reason: 'workingCopyChangeId must be non-empty');

      // Read the change metadata for the WC change.
      final Change change = await handle.getChange(wcChangeId);

      // The returned id must match what we requested.
      expect(change.id, equals(wcChangeId), reason: 'returned id must match the requested change id');
      // Value-check the decoded fields against an oracle (project rule: assert
      // EQUALITY, not mere non-emptiness). A fresh-init WC commit is anonymous,
      // conflict-free, non-divergent, unsigned, with an empty description and the
      // root as its sole parent.
      expect(change.parents, isNotEmpty, reason: 'WC change must have a parent');
      expect(
        change.parents.first,
        equals(status.parentChangeId),
        reason: 'first parent must match status.parentChangeId',
      );
      expect(change.description, equals(''), reason: 'fresh-init WC commit has empty description');
      expect(change.isAnonymous, isTrue, reason: 'fresh-init WC commit is anonymous');
      expect(change.divergent, isFalse, reason: 'fresh-init WC commit is not divergent');
      expect(change.conflict, equals(ConflictState.clean), reason: 'fresh-init WC commit is conflict-free');
      expect(change.conflictedPaths, isEmpty, reason: 'clean change has no conflicted paths');
      expect(change.isSigned, isFalse, reason: 'fresh-init WC commit is unsigned');
      expect(
        change.committer.name,
        equals(change.author.name),
        reason: 'fresh commit author and committer identity match',
      );

      await handle.close();
    });

    test('getChange_on_not_found_id_surfaces_jj_change_not_found', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.getChange('nonexistentchangeid'),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.change_not_found',
          ),
        ),
      );

      await handle.close();
    });

    test('getChange_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      // Init a repo, get a change id, close the handle, then bypass the
      // RepoHandle guard and call the worker directly — mirrors the
      // closed-handle test in status_test.dart.
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();
      final String wcChangeId = status.workingCopyChangeId;
      await handle.close();

      // Direct worker call with the now-unknown handleId.
      await expectLater(
        worker.getChange(handle.handleId, wcChangeId),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'ffi.invalid_handle',
          ),
        ),
      );
    });
  });

  // ── RepoHandle.getChange guard ────────────────────────────────────────────

  group('RepoHandle.getChange closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_change_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('getChange_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.getChange() must throw StateError before reaching the worker.
      expect(
        () => handle.getChange('qpvuntsm'),
        throwsA(isA<StateError>()),
      );
    });
  });
}
