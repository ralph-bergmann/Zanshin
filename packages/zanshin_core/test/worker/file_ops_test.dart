// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.22's two working-copy tracking verbs
// (fileTrack / fileUntrack) on both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits
// zanshin_file_track and zanshin_file_untrack in the coverage ratchet's
// extern-fn guard: cargo-llvm-cov does not attribute a #[no_mangle] extern fn
// hit from a Rust integration test to the cdylib, so each extern fn needs a
// packages/zanshin_core test calling it through the library
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite"). The file
// names below are deliberately unusual so a developer's global git excludes
// file cannot ignore them.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/file.dart' show FileEntry;
import 'package:zanshin_core/src/ffi/file_ops.dart' show TrackResult, UntrackResult;
import 'package:zanshin_core/src/ffi/op_log.dart' show Operation;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// `(id, description)` of the head operation.
Future<(String, String)> headOp(RepoHandle handle) async {
  final List<Operation> ops = await handle.opLog(limit: 1);
  return (ops.single.id, ops.single.description);
}

void main() {
  group('ZanshinWorker working-copy tracking (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    // The Makefile's XDG_CONFIG_HOME pin: the legacy repo configs written below are migrated
    // by the next verb's start-up fix-up (Story 9.37) — refuse before they land under the
    // developer's real ~/.config/jj.
    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_file_ops_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('track_round_trips_through_the_real_cdylib', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/zanshin_track_me.dat').writeAsStringSync('tracked');
      final String wcBefore = (await handle.status()).workingCopyChangeId;
      final (String before, _) = await headOp(handle);

      final TrackResult result = await handle.fileTrack(['zanshin_track_me.dat']);

      final (String head, String description) = await headOp(handle);
      expect(head, isNot(before), reason: 'the operation is written unconditionally');
      expect(description, 'track paths');
      expect(result.mutation.newOpId, head);
      expect(result.mutation.workingCopyChangeId, wcBefore, reason: '`@` is unchanged (GH #8298)');
      expect(result.numRebased, 0);
      expect(result.snapshotStats.untracked, isEmpty);
      expect(result.snapshotStats.invalidUtf8Paths, isEmpty);

      await handle.close();
    });

    // Without this, `includeIgnored` never crosses the adapter / command / isolate
    // seam: hard-coding `false` anywhere on that path would pass every other test.
    test('track_with_includeIgnored_forces_a_too_large_file', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // The repo layer (a fresh repo has no config-id, so this legacy file IS it); the
      // effective config is re-read per call.
      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync('snapshot.max-new-file-size = 5\n');
      File('${tempDir.path}/zanshin_big.dat').writeAsStringSync('0123456789');
      // Control: unforced, the file is refused as too large (and nothing is recorded, so the
      // working-copy state still matches `@` for the second call).
      final TrackResult unforced = await handle.fileTrack(['zanshin_big.dat']);
      expect(unforced.snapshotStats.untracked.map((u) => u.path), contains('zanshin_big.dat'));

      final TrackResult result = await handle.fileTrack(['zanshin_big.dat'], includeIgnored: true);

      expect(
        result.snapshotStats.untracked.map((u) => u.path),
        isNot(contains('zanshin_big.dat')),
        reason: 'a forced file is tracked, not reported as too large',
      );

      await handle.close();
    });

    test('untrack_of_an_unmatched_path_writes_the_op_and_reports_it', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final (String before, _) = await headOp(handle);

      final UntrackResult result = await handle.fileUntrack(['zanshin_nope.dat']);

      final (String head, String description) = await headOp(handle);
      expect(head, isNot(before));
      expect(description, 'untrack paths');
      expect(result.mutation.newOpId, head);
      expect(result.unmatchedPaths, ['zanshin_nope.dat']);
      expect(result.numRebased, 0);
      expect(result.failedBookmarks, isEmpty);
      expect(result.failedTags, isEmpty);

      await handle.close();
    });

    // AC-5 (Story 9.26): the path `fileTrack` recorded lives only in the
    // working-copy state until the NEXT call's pre-verb snapshot moves it into
    // `@` — so a second track, then describe, then newChange all succeed. With
    // `snapshot.auto-track = "none()"` only the explicit track records the file.
    test('verbs_right_after_track_succeed_and_see_the_tracked_path', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync('snapshot.auto-track = "none()"\n');
      File('${tempDir.path}/zanshin_track_me.dat').writeAsStringSync('tracked');
      await handle.fileTrack(['zanshin_track_me.dat']);

      await handle.fileTrack(['zanshin_track_me.dat']);

      expect(handle.lastPrecondition?.wasSnapshotTaken, isTrue, reason: 'the pre-verb snapshot moved it into `@`');
      final List<FileEntry> entries = await handle.fileList();
      expect(entries.map((e) => e.path), contains('zanshin_track_me.dat'));
      final String wc = (await handle.status()).workingCopyChangeId;
      await handle.describe(changeId: wc, description: 'tracked');
      await handle.newChange([wc]);

      await handle.close();
    });

    test('an_empty_path_list_surfaces_jj_invalid_input_for_both_verbs', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.fileTrack(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      await expectLater(
        handle.fileUntrack(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('both_verbs_on_a_closed_handle_surface_ffi_invalid_handle_through_the_worker', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.fileTrack(handle.handleId, ['a']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.fileUntrack(handle.handleId, ['a']),
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
        () => handle.fileTrack(['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );
      expect(
        () => handle.fileUntrack(['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'paths')),
      );

      await handle.close();
    });
  });

  // ── RepoHandle closed-handle guards ───────────────────────────────────────

  group('RepoHandle working-copy tracking methods closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_file_ops_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('fileTrack_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.fileTrack(['a']), throwsA(isA<StateError>()));
    });

    test('fileUntrack_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.fileUntrack(['a']), throwsA(isA<StateError>()));
    });
  });
}
