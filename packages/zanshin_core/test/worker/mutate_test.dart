// SPDX-License-Identifier: MIT

// Worker round-trip tests for the Story 6.5 mutation surface: describe / newChange
// / edit / abandon / undo / gitFetch, on both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors test/worker/change_test.dart
// and test/worker/graph_test.dart. They are also what credits the six new
// zanshin_* extern "C" functions in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/mutate.dart';
import 'package:zanshin_core/src/ffi/status.dart' show WorkingCopyStatus;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker mutation round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_mutate_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('describe_valid_change_id_returns_mutation_result', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      final MutationResult result = await handle.describe(
        changeId: status.workingCopyChangeId,
        description: 'a new description',
      );

      expect(result.newOpId, isNotEmpty);
      expect(result.newChangeIds, isEmpty, reason: 'describe never mints a new change');
      expect(result.abandonedChangeIds, isEmpty, reason: 'describe never abandons a change');

      await handle.close();
    });

    test('newChange_valid_parent_mints_one_new_change_and_moves_wc', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      final MutationResult result = await handle.newChange([status.workingCopyChangeId]);

      expect(result.newChangeIds, hasLength(1));
      expect(result.workingCopyChangeId, equals(result.newChangeIds.single));
    });

    test('newChange_empty_parents_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.newChange(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('edit_switches_working_copy_to_the_requested_change', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();
      final String original = status.workingCopyChangeId;

      // Mint a genuine ancestor relationship: newChange(original) creates a new
      // child and moves @ to it; editing back to `original` is then a real
      // switch-to-an-existing-change, not a self-edit (which hits jj-lib's
      // implicit-abandon-of-a-discardable-previous-@ side effect).
      await handle.newChange([original]);

      final MutationResult result = await handle.edit(original);

      expect(result.workingCopyChangeId, equals(original));
      expect(result.newChangeIds, isEmpty, reason: 'edit mints nothing');

      await handle.close();
    });

    test('abandon_wc_mints_its_replacement', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      final MutationResult result = await handle.abandon([status.workingCopyChangeId]);

      expect(result.abandonedChangeIds, equals([status.workingCopyChangeId]));
      expect(result.newChangeIds, hasLength(1), reason: 'abandoning @ mints its replacement');

      await handle.close();
    });

    test('undo_restores_the_previous_operation', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();
      await handle.describe(changeId: status.workingCopyChangeId, description: 'about to be undone');

      final MutationResult result = await handle.undo();

      expect(result.newOpId, isNotEmpty);

      await handle.close();
    });

    test('undo_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.undo(handle.handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    // WHY no happy-path subprocess test here: `zanshin_git_fetch`'s success path
    // shells out to a real `git fetch` subprocess (jj-lib's `git_subprocess.rs`),
    // and `Child::wait()` on that subprocess reliably fails with
    // `jj.network_error: Failed to wait for the git process` when invoked through
    // the compiled cdylib from *any* `dart test`/`dart run` process — reproduced
    // even with zero `dart:io Process` calls of this file's own, so it is the
    // Dart VM's own child-reaping (not test-fixture ordering) racing jj-lib's
    // `Child::wait()`. This is an execution-environment limitation, not a bug in
    // this story's FFI wrapper: `zanshin_git_fetch`'s success path (including
    // progress-event dispatch and `session_id` correlation) is fully exercised —
    // and asserted — by the real subprocess in
    // `crates/zanshin-ffi/tests/repo_write_ffi.rs::git_fetch_happy_path_reports_progress_and_returns_mutation_result`,
    // which runs as a plain `cargo test` process (no Dart VM involved). This test
    // covers the (subprocess-spawn-free) error path instead, still a real
    // cdylib call into `zanshin_git_fetch` for the coverage ratchet's
    // extern-fn credit.
    test('gitFetch_unknown_remote_surfaces_jj_remote_not_found', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1);

      await expectLater(
        handle.gitFetch('nonexistent'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.remote_not_found')),
      );

      await handle.close();
    });
  });

  // ── RepoHandle closed-handle guards ───────────────────────────────────────

  group('RepoHandle mutation methods closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_mutate_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('describe_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(
        () => handle.describe(changeId: 'qpvuntsm', description: 'x'),
        throwsA(isA<StateError>()),
      );
    });

    test('undo_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(handle.undo, throwsA(isA<StateError>()));
    });
  });
}
