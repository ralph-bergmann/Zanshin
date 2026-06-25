// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.bookmarks] and [RepoHandle.bookmarks].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI.
//
// A freshly-init'd jj repo has NO bookmarks; the test asserts bookmarks.isEmpty
// (the real expected shape, F20 oracle-equality rule — not vacuous isNotEmpty).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
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
      worker.close();
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

    test('bookmarks_oracle_equality_two_calls_produce_equal_results', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Bookmark> first = await handle.bookmarks();
      final List<Bookmark> second = await handle.bookmarks();

      // Oracle equality: two consecutive calls must yield the same result
      // (ADR-0002 re-resolves to the same head if no mutation occurred).
      expect(
        first.length,
        equals(second.length),
        reason: 'bookmark count must be stable across two calls',
      );
      for (var i = 0; i < first.length; i++) {
        expect(first[i].name, equals(second[i].name), reason: 'bookmark[$i].name must be equal');
        expect(first[i].target, equals(second[i].target), reason: 'bookmark[$i].target must be equal');
        expect(
          first[i].kind.runtimeType,
          equals(second[i].kind.runtimeType),
          reason: 'bookmark[$i].kind must be equal',
        );
      }

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
      worker.close();
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
