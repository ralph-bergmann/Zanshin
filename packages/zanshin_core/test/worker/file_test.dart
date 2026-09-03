// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.4's four `jj file` READ verbs: fileList /
// fileShow / fileAnnotate / fileSearch, on both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/mutate_test.dart and test/worker/status_test.dart. They are also
// what credits each zanshin_file_* extern "C" function in the coverage ratchet's
// extern-fn guard (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// SCOPE NOTE - why no committed file content here. Zanshin never snapshots the
// working copy (D2), and no shipped verb writes file content into a tree, so a
// repo reachable from Dart alone has only EMPTY trees. Every content-carrying row
// of the I/O matrix therefore lives in the Rust suites, which can build trees
// directly: crates/zanshin-jj/tests/file_reads.rs (behaviour) and
// crates/zanshin-ffi/tests/file_ffi.rs (payload bytes across the FFI). What these
// tests own is the DART half of the chain - that every request field is built and
// crosses the buffer, that the four envelopes decode, and that each error code
// surfaces as a ZanshinFfiException.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/file.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker file-read round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_file_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('fileList_on_a_fresh_repo_decodes_an_empty_ok_payload', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<FileEntry> entries = await handle.fileList();

      expect(entries, isEmpty, reason: "a fresh repo's @ has an empty tree");
      await handle.close();
    });

    test('fileList_carries_the_path_filter_through_the_request_buffer', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // A malformed prefix can only be refused if `paths` actually reached Rust -
      // a reader that dropped the field would return an empty ok payload instead.
      await expectLater(
        handle.fileList(paths: ['/absolute.txt']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('fileShow_with_an_absent_single_path_surfaces_jj_path_not_found', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.fileShow(paths: ['nope.txt']),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.path_not_found')
              .having((e) => e.context, 'context', 'nope.txt'),
        ),
      );

      await handle.close();
    });

    test('fileShow_with_no_paths_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // The CLI marks its FILESETS argument `required`; an empty list is refused.
      await expectLater(
        handle.fileShow(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('fileAnnotate_carries_the_path_and_refuses_an_absent_one', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.fileAnnotate(path: 'nope.txt'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.path_not_found')
              .having((e) => e.context, 'context', 'nope.txt'),
        ),
      );

      await handle.close();
    });

    test('fileSearch_on_a_fresh_repo_decodes_an_empty_ok_payload', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<SearchMatch> matches = await handle.fileSearch(pattern: 'needle', nameOnly: true);

      expect(matches, isEmpty, reason: 'no tracked files, so nothing matches');
      await handle.close();
    });

    test('fileSearch_carries_the_pattern_through_the_request_buffer', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // An unbalanced paren is only refused if `pattern` actually reached Rust.
      await expectLater(
        handle.fileSearch(pattern: '('),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('every_verb_carries_revision_and_refuses_a_bogus_one', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      const bogus = 'not-reverse-hex!';
      final Matcher matcher = throwsA(
        isA<ZanshinFfiException>()
            .having((e) => e.code, 'code', 'jj.change_not_found')
            .having((e) => e.context, 'context', bogus),
      );

      // An ABSENT revision means `@`, so each of these can only fail if the
      // supplied value crossed the buffer.
      await expectLater(handle.fileList(revision: bogus), matcher);
      await expectLater(handle.fileShow(revision: bogus, paths: ['a.txt']), matcher);
      await expectLater(handle.fileAnnotate(revision: bogus, path: 'a.txt'), matcher);
      await expectLater(handle.fileSearch(revision: bogus, pattern: 'x'), matcher);

      await handle.close();
    });

    // -- ffi.invalid_handle after close (the worker's synthesized envelope) ----

    test('fileList_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.fileList(handle.handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('fileShow_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.fileShow(handle.handleId, paths: ['a.txt']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('fileAnnotate_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.fileAnnotate(handle.handleId, path: 'a.txt'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('fileSearch_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.fileSearch(handle.handleId, pattern: 'x'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });
  });

  // -- RepoHandle closed-handle guards (synchronous StateError) ---------------

  group('RepoHandle file-read methods closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_file_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('every_file_read_on_an_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Non-async guards: the StateError is thrown synchronously, before any
      // Future is created.
      expect(handle.fileList, throwsA(isA<StateError>()));
      expect(() => handle.fileShow(paths: ['a.txt']), throwsA(isA<StateError>()));
      expect(() => handle.fileAnnotate(path: 'a.txt'), throwsA(isA<StateError>()));
      expect(() => handle.fileSearch(pattern: 'x'), throwsA(isA<StateError>()));
    });
  });
}
