// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.5's six `jj git` verbs: gitImport, gitExport,
// gitRemoteAdd, gitRemoteRemove, gitRemoteRename and gitRemoteSetUrl, on both
// [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors test/worker/mutate_test.dart
// and test/worker/file_test.dart. They are also what credits each of the six new
// zanshin_git_* extern "C" functions in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// The behavioural rows live Rust-side, where a scenario can be built cheaply:
// crates/zanshin-jj/tests/it/git_sync.rs, crates/zanshin-jj/tests/it/git_remotes.rs and
// crates/zanshin-ffi/tests/it/git_ffi.rs. What is asserted here is the seam: a real
// cdylib call, a decoded payload, and the three refusal shapes a UI must handle.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/git.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/remotes.dart' show Remote;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker git round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late Directory remoteDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_git_test_');
      remoteDir = Directory.systemTemp.createTempSync('zanshin_git_remote_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      for (final dir in [tempDir, remoteDir]) {
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      }
    });

    // WHY the no-op path: a freshly-initialised git-backed workspace has no git ref
    // jj has not seen and no jj bookmark git has not seen, so both sync verbs
    // legitimately write nothing. Both are still REAL, successful calls through the
    // compiled cdylib — which is what credits `zanshin_git_import` and
    // `zanshin_git_export` in the extern-fn guard — and they assert the no-op
    // contract itself (a success carrying the pre-call op-log head, not an error).
    test('gitImport_on_a_fresh_git_workspace_is_a_no_op_success', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);

      final GitImportResult result = await handle.gitImport();

      expect(result.mutation.newOpId, isNotEmpty);
      expect(result.changedBookmarks, isEmpty);
      expect(result.changedTags, isEmpty);
      expect(result.abandonedChangeIds, isEmpty);
      expect(result.failedRefNames, isEmpty);
      expect(result.numRewritten, equals(0));

      await handle.close();
    });

    test('gitExport_on_a_fresh_git_workspace_is_a_no_op_success', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);

      final GitExportResult result = await handle.gitExport();

      expect(result.mutation.newOpId, isNotEmpty);
      expect(result.failedBookmarks, isEmpty);
      expect(result.failedTags, isEmpty);

      await handle.close();
    });

    // The whole point of Story 9.5's workspace reload: `remotes()` on the SAME
    // handle must reflect each config write with no reopen. Driving all four remote
    // verbs in one sequence also credits all four extern fns.
    test('the_four_remote_verbs_are_visible_through_the_same_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final String url = remoteDir.path;

      final MutationResult added = await handle.gitRemoteAdd(name: 'origin', url: url);
      expect(added.newOpId, isNotEmpty);
      expect((await handle.remotes()).map((r) => r.name), equals(['origin']));
      expect((await handle.remotes()).single.url, equals(url), reason: 'the url crosses verbatim');

      // Fetch-url only: a push url would make the remote nonstandard, and the rename and
      // remove below would then (correctly) refuse — see the dedicated push-url row.
      await handle.gitRemoteSetUrl(name: 'origin', url: '$url-elsewhere');
      expect((await handle.remotes()).single.url, equals('$url-elsewhere'));

      await handle.gitRemoteRename('origin', 'upstream');
      expect((await handle.remotes()).map((r) => r.name), equals(['upstream']));

      await handle.gitRemoteRemove('upstream');
      expect(await handle.remotes(), isEmpty);

      await handle.close();
    });

    // `gitRemoteSetUrl`'s optional pushUrl, which the sequence above deliberately cannot
    // carry. `remotes()` now reports the PUSH url too, so this is the end-to-end witness
    // through the real cdylib: the push url arrives and the fetch side is LEFT ALONE.
    test('gitRemoteSetUrl_with_only_a_push_url_leaves_the_fetch_url_alone', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      await handle.gitRemoteAdd(name: 'origin', url: remoteDir.path);
      expect(
        (await handle.remotes()).single.pushUrl,
        isNull,
        reason: 'a remote added without a push url pushes to its fetch url',
      );

      final MutationResult result = await handle.gitRemoteSetUrl(
        name: 'origin',
        pushUrl: '${remoteDir.path}-push',
      );

      expect(result.newOpId, isNotEmpty, reason: 'set-url never opens a transaction');
      final Remote listed = (await handle.remotes()).single;
      expect(listed.url, equals(remoteDir.path));
      expect(listed.pushUrl, equals('${remoteDir.path}-push'));

      await handle.close();
    });

    // One of the two error codes this story adds, surfacing as a real
    // ZanshinFfiException through the whole worker seam.
    test('gitRemoteAdd_duplicate_surfaces_jj_remote_exists', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      await handle.gitRemoteAdd(name: 'origin', url: remoteDir.path);

      await expectLater(
        handle.gitRemoteAdd(name: 'origin', url: remoteDir.path),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.remote_exists')
              .having((e) => e.context, 'context', 'origin'),
        ),
      );

      await handle.close();
    });

    // The other new code: jj-lib writes a `pushurl` key for a remote added WITH a
    // push url, and its own remove then refuses that remote.
    test('gitRemoteRemove_of_a_remote_added_with_a_push_url_surfaces_jj_remote_nonstandard_config', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      await handle.gitRemoteAdd(name: 'origin', url: remoteDir.path, pushUrl: '${remoteDir.path}-push');

      await expectLater(
        handle.gitRemoteRemove('origin'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.remote_nonstandard_config')),
      );

      await handle.close();
    });

    // The reused-but-widened code: a native workspace has no git backend at all.
    test('gitImport_on_a_native_workspace_surfaces_jj_not_a_git_repo', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.gitImport(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.not_a_git_repo')),
      );

      await handle.close();
    });

    test('gitRemoteRemove_of_a_missing_remote_surfaces_jj_remote_not_found', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);

      await expectLater(
        handle.gitRemoteRemove('nonexistent'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.remote_not_found')
              .having((e) => e.context, 'context', 'nonexistent'),
        ),
      );

      await handle.close();
    });

    // Model A: the worker's handle table is the only owner, so a command for a
    // closed handle is answered with a synthesized envelope, never a stale pointer.
    test('gitExport_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitExport(handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    // The other five git arms' unknown-handle reply, same synthesized envelope.
    test('gitImport_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitImport(handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('gitRemoteAdd_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitRemoteAdd(handleId, name: 'origin', url: remoteDir.path),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('gitRemoteRemove_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitRemoteRemove(handleId, 'origin'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('gitRemoteRename_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitRemoteRename(handleId, 'origin', 'upstream'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('gitRemoteSetUrl_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      await expectLater(
        worker.gitRemoteSetUrl(handleId, name: 'origin', url: remoteDir.path),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    // The RepoHandle close-guard is SYNCHRONOUS for every verb — a closed handle
    // must not even reach the worker.
    test('every_git_verb_throws_StateError_synchronously_after_close', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      await handle.close();

      expect(handle.gitImport, throwsStateError);
      expect(handle.gitExport, throwsStateError);
      expect(() => handle.gitRemoteAdd(name: 'origin', url: remoteDir.path), throwsStateError);
      expect(() => handle.gitRemoteRemove('origin'), throwsStateError);
      expect(() => handle.gitRemoteRename('origin', 'upstream'), throwsStateError);
      expect(() => handle.gitRemoteSetUrl(name: 'origin', url: remoteDir.path), throwsStateError);
      expect(handle.gitColocationStatus, throwsStateError);
      expect(handle.gitColocationEnable, throwsStateError);
      expect(handle.gitColocationDisable, throwsStateError);
    });

    // Story 9.45: enable, status, disable on ONE handle — the handle runs on the
    // reloaded workspace after each conversion, so status agrees without a reopen.
    test('gitColocation_enable_status_disable_round_trip_on_one_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);

      final GitColocationStatus before = await handle.gitColocationStatus();
      expect(before.colocated, isFalse);
      expect(before.workspaceName, equals('default'));
      expect(before.externalGitRepo, isFalse);
      expect(before.gitHead.isAbsent, isTrue);
      expect(before.hints, equals(['To enable colocation, run: `jj git colocation enable`']));

      final GitColocationResult enabled = await handle.gitColocationEnable();
      expect(enabled.converted, isTrue);
      expect(enabled.gitWorktreeRemoved, isFalse);
      expect(enabled.mutation.newOpId, isNotEmpty);
      expect(Directory('${tempDir.path}/.git').existsSync(), isTrue);

      final GitColocationStatus between = await handle.gitColocationStatus();
      expect(between.colocated, isTrue);
      expect(between.hints, equals(['To disable colocation, run: `jj git colocation disable`']));

      final GitColocationResult disabled = await handle.gitColocationDisable();
      expect(disabled.converted, isTrue);
      expect(Directory('${tempDir.path}/.git').existsSync(), isFalse);
      expect((await handle.gitColocationStatus()).colocated, isFalse);

      await handle.close();
    });

    test('gitColocationEnable_with_an_existing_dot_git_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      File('${tempDir.path}/.git/x').createSync(recursive: true);

      await expectLater(
        handle.gitColocationEnable(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('gitColocation_on_a_native_workspace_surfaces_jj_not_a_git_repo', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      for (final Future<Object> Function() call in [
        handle.gitColocationStatus,
        handle.gitColocationEnable,
        handle.gitColocationDisable,
      ]) {
        await expectLater(
          call(),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.not_a_git_repo')),
        );
      }

      await handle.close();
    });

    test('gitColocation_on_a_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final int handleId = handle.handleId;
      await handle.close();

      for (final Future<Object> Function(int) call in [
        worker.gitColocationStatus,
        worker.gitColocationEnable,
        worker.gitColocationDisable,
      ]) {
        await expectLater(
          call(handleId),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
        );
      }
    });
  });
}
