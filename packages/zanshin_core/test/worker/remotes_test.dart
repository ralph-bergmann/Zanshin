// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.remotes] and [RepoHandle.remotes].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI.
//
// A freshly-init'd jj repo has NO configured remotes; the test asserts
// remotes.isEmpty (the real expected shape, F20 oracle-equality rule — not
// vacuous isNotNull).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/remotes.dart';
import 'package:zanshin_core/src/ffi/warning.dart' show WarnedList;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.remotes round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_remotes_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('remotes_on_fresh_init_returns_empty_list', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Remote> rems = await handle.remotes();

      // A freshly initialised repo has no configured remotes — isEmpty is the
      // real expected shape (F20 oracle-equality rule).
      expect(rems, isEmpty, reason: 'fresh init repo must have no remotes');

      await handle.close();
    });

    test('remotes_stable_across_two_calls_on_fresh_repo', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // Both reads of a fresh repo must return isEmpty — concrete oracle
      // equality per F20 rule.
      final List<Remote> first = await handle.remotes();
      final List<Remote> second = await handle.remotes();
      expect(first, isEmpty, reason: 'fresh repo: first call must be empty');
      expect(second, isEmpty, reason: 'fresh repo: second call must be empty');

      await handle.close();
    });

    test('remotes_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Direct worker call with the now-unknown handleId bypasses the closed guard.
      await expectLater(
        worker.remotes(handle.handleId),
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

  // ── gitPushRemotes (Story 9.54) ───────────────────────────────────────────

  group('RepoHandle.gitPushRemotes round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_push_remotes_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('git_push_remotes_names_origin_among_several', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      expect(await handle.gitPushRemotes(), isEmpty, reason: 'no remote at all');
      await handle.gitRemoteAdd(name: 'upstream', url: 'https://example.invalid/upstream.git');
      await handle.gitRemoteAdd(name: 'origin', url: 'https://example.invalid/origin.git');

      final WarnedList<String> names = await handle.gitPushRemotes();

      expect(names, ['origin']);
      expect(names.warnings, isEmpty);
      await handle.close();
    });

    test('git_push_remotes_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(handle.gitPushRemotes, throwsA(isA<StateError>()));
      await expectLater(
        worker.gitPushRemotes(handle.handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });
  });

  // ── RepoHandle.remotes guard ──────────────────────────────────────────────

  group('RepoHandle.remotes closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_remotes_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('remotes_on_explicitly_closed_handle_throws_state_error_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.remotes() must throw StateError synchronously before reaching the worker.
      expect(
        handle.remotes,
        throwsA(isA<StateError>()),
      );
    });
  });
}
