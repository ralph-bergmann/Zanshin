// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.26's pre-verb snapshot: `snapshot()` on
// both [ZanshinWorker] and [RepoHandle], and the `lastPrecondition` choke point
// every handle-scoped reply feeds.
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits
// zanshin_snapshot in the coverage ratchet's extern-fn guard: cargo-llvm-cov
// does not attribute a #[no_mangle] extern fn hit from a Rust integration test
// to the cdylib, so each extern fn needs a packages/zanshin_core test calling it
// through the library (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core] in
// Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/op_log.dart' show Operation;
import 'package:zanshin_core/src/ffi/precondition.dart' show Precondition;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// Descriptions of every operation, newest first.
Future<List<String>> opDescriptions(RepoHandle handle) async {
  final List<Operation> ops = await handle.opLog();
  return ops.map((o) => o.description).toList();
}

void main() {
  group('ZanshinWorker pre-verb snapshot (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    // The Makefile's XDG_CONFIG_HOME pin: the legacy repo config written below is migrated by
    // the next verb's start-up fix-up (Story 9.37) — refuse before it lands under the
    // developer's real ~/.config/jj.
    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_snapshot_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    // AC-4.
    test('snapshot_of_a_dirty_git_repo_is_taken_and_a_following_read_finds_nothing', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      expect(handle.lastPrecondition, isNull, reason: 'no reply has carried a report yet');
      File('${tempDir.path}/zanshin_dirty.dat').writeAsStringSync('dirty');

      final Precondition report = await handle.snapshot();

      expect(report.wasSnapshotTaken, isTrue);
      expect(report.snapshotStats.untracked, isEmpty);
      expect(report.gitRefs, isNull, reason: 'not colocated: the refs import does not run');
      expect(report.gitHeadImported, isFalse);
      expect(handle.lastPrecondition?.wasSnapshotTaken, isTrue, reason: 'snapshot feeds the choke point too');

      await handle.status();

      expect(handle.lastPrecondition, isNotNull);
      expect(handle.lastPrecondition!.wasSnapshotTaken, isFalse);
      expect((await opDescriptions(handle)).first, 'snapshot working copy');

      await handle.close();
    });

    test('a_clean_snapshot_writes_no_operation', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      final List<String> before = await opDescriptions(handle);

      final Precondition report = await worker.snapshot(handle.handleId);

      expect(report.wasSnapshotTaken, isFalse);
      expect(report.finish, isNull);
      expect(await opDescriptions(handle), before);

      await handle.close();
    });

    test('an_error_reply_still_records_the_precondition_that_ran_before_it', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      File('${tempDir.path}/zanshin_dirty.dat').writeAsStringSync('dirty');

      await expectLater(
        handle.getChange('yyyyyyyyyyyy'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.change_not_found')),
      );

      expect(handle.lastPrecondition?.wasSnapshotTaken, isTrue, reason: 'the error envelope carried the report');

      await handle.close();
    });

    test('a_wrong_typed_snapshot_knob_is_jj_config_error_with_a_partial_report', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      // The repo layer (a fresh repo has no config-id, so this legacy file IS it); the
      // effective config is re-read per call.
      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync('snapshot.auto-track = 5\n');

      await expectLater(
        handle.snapshot(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_error')),
      );

      expect(handle.lastPrecondition, isNotNull, reason: 'the partial report rides the error envelope');
      expect(handle.lastPrecondition!.wasSnapshotTaken, isFalse);

      await handle.close();
    });

    test('a_call_that_runs_no_precondition_leaves_the_last_report_standing', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      File('${tempDir.path}/zanshin_dirty.dat').writeAsStringSync('dirty');
      await handle.snapshot();

      await handle.logDefaults();
      await handle.workspaceRoot();

      expect(handle.lastPrecondition?.wasSnapshotTaken, isTrue);

      await handle.close();
    });

    test('snapshot_on_a_closed_handle_surfaces_ffi_invalid_handle_through_the_worker', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      await handle.close();

      await expectLater(
        worker.snapshot(handle.handleId),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      expect(worker.lastPreconditionOf(handle.handleId), isNull, reason: 'dropped on close');
    });
  });

  group('RepoHandle.snapshot closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_snapshot_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('snapshot_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
      await handle.close();

      expect(handle.snapshot, throwsA(isA<StateError>()));
    });
  });
}
