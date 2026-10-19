// SPDX-License-Identifier: MIT

// Worker round-trip tests for the whole mutation surface: Story 6.5's describe /
// newChange / edit / abandon / undo / gitFetch and Story 9.3's restore / absorb, on
// both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors test/worker/change_test.dart
// and test/worker/graph_test.dart. They are also what credits each mutation
// zanshin_* extern "C" function in the coverage ratchet's extern-fn guard
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

    /// `A → B = @`, both described (so neither is discardable): `(A, B)`.
    Future<(String, String)> describedPair(RepoHandle handle) async {
      final String a = (await handle.status()).workingCopyChangeId;
      await handle.describe(changeId: a, description: 'A');
      final String b = (await handle.newChange([a])).newChangeIds.single;
      await handle.describe(changeId: b, description: 'B');
      return (a, b);
    }

    test('newChange_insertAfter_puts_the_new_change_between_target_and_child', () async {
      // Story 9.48: `jj new -A A` on A → B.
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final (String a, String b) = await describedPair(handle);

      final MutationResult result = await handle.newChange(const [], insertAfter: [a]);

      final String n = result.newChangeIds.single;
      expect(result.workingCopyChangeId, n, reason: 'the new change is @');
      expect((await handle.getChange(n)).parents, [a]);
      expect((await handle.getChange(b)).parents, [n], reason: "A's child is rebased onto it");

      await handle.close();
    });

    test('newChange_insertBefore_puts_the_new_change_under_the_target', () async {
      // Story 9.48: `jj new -B B` on A → B.
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final (String a, String b) = await describedPair(handle);

      final MutationResult result = await handle.newChange(const [], insertBefore: [b]);

      final String n = result.newChangeIds.single;
      expect(result.workingCopyChangeId, n, reason: 'the new change is @');
      expect((await handle.getChange(n)).parents, [a]);
      expect((await handle.getChange(b)).parents, [n]);

      await handle.close();
    });

    test('newChange_parents_with_insertAfter_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final (String a, String b) = await describedPair(handle);

      await expectLater(
        handle.newChange([b], insertAfter: [a]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('newChange_rejects_an_interior_nul_in_any_list', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);

      expect(
        () => handle.newChange(['qpv${nul}untsm']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'parents')),
      );
      expect(
        () => handle.newChange(const [], insertAfter: ['qpv${nul}untsm']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'insertAfter')),
      );
      expect(
        () => handle.newChange(const [], insertBefore: ['qpv${nul}untsm']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'insertBefore')),
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

    test('undo_twice_goes_further_back_and_carries_allow_cross_workspace', () async {
      // Story 9.39: the undo stack — the 2nd undo goes further back instead of
      // redoing the 1st — and the CLI's `--allow-cross-workspace` reaches Rust
      // (the refusal itself is pinned by crates/zanshin-ffi/tests/repo_write_ffi.rs).
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final String wc = (await handle.status()).workingCopyChangeId;
      await handle.describe(changeId: wc, description: 'A');
      await handle.describe(changeId: wc, description: 'B');

      await handle.undo();
      expect((await handle.getChange(wc)).description, 'A');
      await handle.undo(allowCrossWorkspace: true);
      expect((await handle.getChange(wc)).description, isEmpty, reason: 'one further back, not a redo');

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
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);

      await expectLater(
        handle.gitFetch('nonexistent'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.remote_not_found')),
      );

      await handle.close();
    });

    // WHY these two exercise the NO-OP path: a freshly-initialised repo's `@` is empty and
    // its parent is the root commit, so restoring `@` from its parent selects a tree that
    // already equals `@`'s, and there is nothing for absorb to move. Both are real,
    // successful calls through the compiled cdylib — which is what credits `zanshin_restore`
    // and `zanshin_absorb` in the coverage ratchet's extern-fn guard — and they assert the
    // no-op contract itself (a success carrying the PRE-CALL op-log head, not an error).
    // Building a multi-commit content scenario is Rust-side work; the behavioural rows live
    // in crates/zanshin-jj/tests/content_ops.rs and crates/zanshin-ffi/tests/repo_write_ffi.rs.
    test('restore_with_no_arguments_is_a_no_op_and_returns_a_mutation_result', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      final MutationResult result = await handle.restore();

      expect(result.newOpId, isNotEmpty);
      expect(result.workingCopyChangeId, equals(status.workingCopyChangeId), reason: '@ did not move');
      expect(result.newChangeIds, isEmpty, reason: 'restore mints nothing');
      expect(result.abandonedChangeIds, isEmpty, reason: 'restore abandons nothing');

      await handle.close();
    });

    test('restore_changes_in_with_from_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final WorkingCopyStatus status = await handle.status();

      await expectLater(
        handle.restore(from: status.workingCopyChangeId, changesIn: status.workingCopyChangeId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('absorb_with_nothing_absorbable_returns_an_empty_absorb_result', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final AbsorbResult result = await handle.absorb();

      expect(result.rewrittenChangeIds, isEmpty, reason: 'an empty @ has no hunks to absorb');
      expect(result.sourceChangeId, isNull, reason: 'null-for-absence: nothing moved');
      expect(result.numRebased, equals(0));
      expect(result.skippedPaths, isEmpty);
      expect(result.mutation.newOpId, isNotEmpty, reason: 'the PRE-CALL op-log head');

      await handle.close();
    });

    test('absorb_with_a_bogus_destination_revset_surfaces_jj_revset_parse_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.absorb(into: 'bogus_function()'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_parse_error')),
      );

      await handle.close();
    });

    test('restore_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.restore(handle.handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('absorb_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.absorb(handle.handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    // The remaining mutation arms' unknown-handle reply. A closed handle is
    // rejected by the worker's own handle-table lookup BEFORE any FFI call — so
    // `gitFetch` here spawns no `git` subprocess and the caveat above
    // `gitFetch_unknown_remote_surfaces_jj_remote_not_found` does not apply.
    test('describe_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.describe(handleId, changeId: '@', description: 'x'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('newChange_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.newChange(handleId, const <String>[]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('edit_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.edit(handleId, '@'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('abandon_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.abandon(handleId, const <String>['@']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('gitFetch_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitFetch(handleId, 'origin'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
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

    test('restore_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(handle.restore, throwsA(isA<StateError>()));
    });

    test('absorb_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(handle.absorb, throwsA(isA<StateError>()));
    });
  });
}
