// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.bookmarks] and [RepoHandle.bookmarks].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI.
//
// A freshly-init'd jj repo has NO bookmarks; the test asserts bookmarks.isEmpty
// (the real expected shape, F20 oracle-equality rule — not vacuous isNotEmpty).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.bookmarks round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmarks_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('bookmarks_on_fresh_init_returns_empty_list', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Bookmark> bms = await handle.bookmarks();

      // A freshly initialised repo has no bookmarks — isEmpty is the real
      // expected shape (F20 oracle-equality rule).
      expect(bms, isEmpty, reason: 'fresh init repo must have no bookmarks');

      await handle.close();
    });

    test('bookmarks_stable_across_two_calls_on_fresh_repo', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // A fresh repo has no bookmarks, and this read-only slice exposes no
      // bookmark-mutation FFI, so both calls must return the real expected shape
      // (empty) — asserted concretely, not via a vacuous per-element loop (F20).
      // Populated per-field equality is covered Rust-side
      // (bookmarks_medium_returns_29_local_entries) and by the synthetic decode
      // contract test (test/ffi/bookmarks_test.dart).
      final List<Bookmark> first = await handle.bookmarks();
      final List<Bookmark> second = await handle.bookmarks();
      expect(first, isEmpty, reason: 'fresh repo: first call must be empty');
      expect(second, isEmpty, reason: 'fresh repo: second call must be empty');

      await handle.close();
    });

    test('bookmarks_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Direct worker call with the now-unknown handleId bypasses the closed guard.
      await expectLater(
        worker.bookmarks(handle.handleId),
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

  // ── RepoHandle.bookmarks guard ────────────────────────────────────────────

  group('RepoHandle.bookmarks closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmarks_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('bookmarks_on_explicitly_closed_handle_throws_state_error_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.bookmarks() must throw StateError synchronously before reaching the worker.
      expect(
        handle.bookmarks,
        throwsA(isA<StateError>()),
      );
    });
  });
}
