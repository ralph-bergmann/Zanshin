// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.status] and [RepoHandle.status].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors the patterns from
// zanshin_worker_test.dart.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/ffi/status.dart';
import 'package:zanshin/src/worker/handle.dart';
import 'package:zanshin/src/worker/isolate.dart';
import 'package:zanshin/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.status round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_status_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('handle_status_on_fresh_init_returns_empty_files_and_non_empty_ids', () async {
      // Init a fresh repo (backend 0 = native/simple) and immediately read status.
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final WorkingCopyStatus s = await handle.status();

      // A freshly initialised repo has no working-copy changes.
      expect(s.files, isEmpty, reason: 'fresh init must have zero changed files');

      // Both change ids must be populated (root commit still has ids).
      expect(
        s.workingCopyChangeId,
        isNotEmpty,
        reason: 'workingCopyChangeId must be non-empty',
      );
      expect(
        s.parentChangeId,
        isNotEmpty,
        reason: 'parentChangeId must be non-empty',
      );

      await handle.close();
    });

    test('status_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      // Init a repo, close the handle, then bypass the RepoHandle guard and
      // call the worker directly — mirrors the close-unknown-handleId test
      // pattern in zanshin_worker_test.dart (AC-21).
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Direct worker call with the now-unknown handleId.
      await expectLater(
        worker.status(handle.handleId),
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

  // ── RepoHandle.status guard ───────────────────────────────────────────────

  group('RepoHandle.status closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_status_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('status_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.status() should throw StateError before reaching the worker.
      expect(handle.status, throwsA(isA<StateError>()));
    });
  });
}
