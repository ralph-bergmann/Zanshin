// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.8's two bookmark mutations
// (bookmarkCreate / bookmarkDelete) on both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits
// zanshin_bookmark_create and zanshin_bookmark_delete in the coverage ratchet's
// extern-fn guard: cargo-llvm-cov does not attribute a #[no_mangle] extern fn
// hit from a Rust integration test to the cdylib, so each extern fn needs a
// packages/zanshin_core test calling it through the library
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart' show Bookmark;
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// The three [MutationResult] fields neither bookmark verb ever fills, checked all the way
/// through the decoder — `newOpId` is otherwise the only one any test in this suite reads.
void expectNoChangeChurn(MutationResult result, String expectedWc) {
  expect(result.newChangeIds, isEmpty, reason: 'a bookmark verb mints no change');
  expect(result.abandonedChangeIds, isEmpty, reason: 'a bookmark verb abandons no change');
  expect(result.workingCopyChangeId, expectedWc, reason: '`@` does not move');
}

void main() {
  group('ZanshinWorker bookmark mutations (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmark_ops_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('create_then_delete_round_trips_through_the_real_cdylib', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // The oracle for `workingCopyChangeId`: neither verb ever moves `@`, so both results
      // must report exactly what `status()` does.
      final String expectedWc = (await handle.status()).workingCopyChangeId;

      final MutationResult created = await handle.bookmarkCreate(['feature']);
      expect(created.newOpId, isNotEmpty);
      expectNoChangeChurn(created, expectedWc);
      final List<Bookmark> afterCreate = await handle.bookmarks();
      expect(afterCreate.map((b) => b.name), ['feature']);

      final MutationResult deleted = await handle.bookmarkDelete(['exact:feature']);
      expect(deleted.newOpId, isNot(created.newOpId), reason: 'the delete writes its own operation');
      expectNoChangeChurn(deleted, expectedWc);
      expect(await handle.bookmarks(), isEmpty);

      await handle.close();
    });

    test('delete_matching_nothing_succeeds_and_writes_no_operation', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // A create first, so there IS a recent operation whose id can be compared.
      final MutationResult created = await handle.bookmarkCreate(['feature']);

      final MutationResult noop = await handle.bookmarkDelete(['nosuch']);

      expect(
        noop.newOpId,
        created.newOpId,
        reason: 'matching nothing returns the PRE-CALL head, the wire form of "No bookmarks to delete."',
      );
      // The no-op exit is supposed to report the same three fields as the committed one, so it
      // is asserted through the decoder here as well.
      expectNoChangeChurn(noop, (await handle.status()).workingCopyChangeId);
      expect(await handle.bookmarks(), hasLength(1), reason: 'nothing was deleted');

      await handle.close();
    });

    test('create_on_an_existing_name_surfaces_jj_bookmark_exists', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.bookmarkCreate(['feature']);

      await expectLater(
        handle.bookmarkCreate(['feature']),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.bookmark_exists')
              .having((e) => e.context, 'context', 'feature'),
        ),
      );

      await handle.close();
    });

    // Without this, `revision` never crosses the seam in a PASSING test: every other
    // create here either omits it or carries an interior NUL, which the calling-side
    // guard rejects before a buffer exists. Dropping `revision:` from the dispatch arm,
    // the command, or the ObjectBuilder would leave the whole gate green while a GUI
    // asking for `bookmark create v1 -r <commit>` silently got a bookmark on `@`.
    test('create_carries_revision_across_the_seam_and_refuses_a_bogus_one', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      const bogus = 'not-reverse-hex!';

      await expectLater(
        handle.bookmarkCreate(['feature'], revision: bogus),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', bogus),
        ),
      );
      expect(await handle.bookmarks(), isEmpty, reason: 'the refused create wrote nothing');

      await handle.close();
    });

    test('create_with_an_empty_name_list_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.bookmarkCreate(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('delete_with_an_empty_pattern_list_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.bookmarkDelete(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('both_verbs_on_a_closed_handle_surface_ffi_invalid_handle_through_the_worker', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.bookmarkCreate(handle.handleId, ['feature']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.bookmarkDelete(handle.handleId, ['feature']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    // The interior-NUL guard lives on the CALLING side precisely so it throws an
    // ArgumentError here rather than coming back as `internal.dispatch_error`
    // from inside the worker isolate.
    test('interior_NUL_is_rejected_as_an_ArgumentError_not_a_dispatch_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);

      expect(
        () => handle.bookmarkCreate(['fea${nul}ture']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => handle.bookmarkCreate(['feature'], revision: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'revision')),
      );
      expect(
        () => handle.bookmarkDelete(['fo${nul}o']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );

      await handle.close();
    });
  });

  // ── RepoHandle closed-handle guards ───────────────────────────────────────

  group('RepoHandle bookmark mutation methods closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmark_ops_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('bookmarkCreate_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.bookmarkCreate(['feature']), throwsA(isA<StateError>()));
    });

    test('bookmarkDelete_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.bookmarkDelete(['feature']), throwsA(isA<StateError>()));
    });
  });
}
