// SPDX-License-Identifier: MIT

// Tests for [ZanshinWorker] — the single long-running worker isolate.
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled
// cdylib via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing").
//
// AC-17: this is the first Dart test suite that calls the real cdylib. The
// native asset must be built before flutter test runs. [flutter test] invokes
// hook/build.dart which calls native_toolchain_rust to compile the cdylib;
// with pre-built artifacts in target/ this is a fast no-op.
// See Dev Agent Record for findings.
//
// NOTE on JJ_CONFIG / GIT_CONFIG_GLOBAL: Dart cannot set process env vars in
// itself (Platform.environment is read-only), so determinism is pinned
// externally — `[tasks.test-flutter]` in Makefile.toml exports JJ_CONFIG="" and
// GIT_CONFIG_GLOBAL="" (matching the Rust suites), so this suite never reads a
// developer's global jj/git config (project-context "Property of every test
// suite"; AC-16). User identity for `init` is supplied by zanshin-jj
// make_settings(), not the environment, so both backends work without it.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ─────────────────────────────────────────────────────────────

  group('ZanshinWorker round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_worker_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('worker_init_open_close_round_trip', () async {
      // Init a fresh jj repo in a temp dir (backend 0 = native/simple, per AC-16).
      final RepoHandle initHandle = await worker.initRepo(tempDir.path, backend: 0);
      // First handle should be dense id 0.
      expect(initHandle.handleId, 0);

      // Open the same repo — should succeed with a new handle id.
      final RepoHandle openHandle = await worker.openRepo(tempDir.path);
      expect(openHandle.handleId, 1);

      // Explicit close should complete without error.
      await initHandle.close();
      await openHandle.close();
    });
  });

  // ── FFI error propagation ─────────────────────────────────────────────────

  group('ZanshinWorker FFI error propagation', () {
    late ZanshinWorker worker;

    setUp(() async {
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
    });

    test('worker_open_nonexistent_path_throws_ffi_exception', () async {
      await expectLater(
        worker.openRepo('/no/such/path/does/not/exist'),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.path_not_found',
          ),
        ),
      );
    });

    test('worker_open_non_repo_dir_throws_ffi_exception', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_norepo_test_');
      addTearDown(() {
        if (tmp.existsSync()) {
          tmp.deleteSync(recursive: true);
        }
      });
      // Directory exists but is not a jj repo.
      await expectLater(
        worker.openRepo(tmp.path),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.repo_not_found',
          ),
        ),
      );
    });
  });

  // ── Model A: invalid handleId ─────────────────────────────────────────────

  group('ZanshinWorker Model A handle validation', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_handle_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('worker_close_unknown_handle_id_returns_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // First close: removes the handleId from the worker table.
      await handle.close();

      // Second close via internal path (bypasses RepoHandle guard) — the worker
      // no longer knows this handleId, so it must reject with ffi.invalid_handle.
      await expectLater(
        worker.closeRepo(handle.handleId),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'ffi.invalid_handle',
          ),
        ),
      );
    });

    test('repo_handle_double_close_is_idempotent', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // First close releases the worker-side handle-table entry.
      await handle.close();

      // Second + third close via the public RepoHandle API must be silent
      // no-ops: the `_closed` guard short-circuits before reaching the worker,
      // so they do NOT surface the `ffi.invalid_handle` the raw worker path
      // returns (cf. worker_close_unknown_handle_id_returns_invalid_handle).
      // Together those two tests secure the double-close / stale-handle path:
      // no crash and no FFI call with a freed pointer (Model-A use-after-free
      // guarantee, ADR-0002).
      await expectLater(handle.close(), completes);
      await expectLater(handle.close(), completes);
    });
  });

  // ── Command after close ───────────────────────────────────────────────────

  group('ZanshinWorker command after close', () {
    test('worker_send_after_close_throws_state_error', () async {
      final ZanshinWorker worker = await ZanshinWorker.start();
      await worker.close();

      await expectLater(
        worker.openRepo('/tmp/any'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'Worker is closed',
          ),
        ),
      );
    });
  });

  // ── Shutdown ──────────────────────────────────────────────────────────────

  group('ZanshinWorker shutdown', () {
    test('worker_close_completes_cleanly', () async {
      final ZanshinWorker worker = await ZanshinWorker.start();
      // Should complete cleanly without throwing; idempotent.
      await worker.close();
      await worker.close();
    });

    test('worker_close_fails_in_flight_commands', () async {
      final ZanshinWorker worker = await ZanshinWorker.start();

      // Fire an open command, then close immediately after — no await between
      // the two, so both are sent to the worker before this isolate yields.
      // Whether the worker answers it first (FIFO) or close()'s failAll
      // backstop does, the in-flight future must complete with an error, not
      // hang. The expectation is attached to `inFlight` BEFORE awaiting
      // close() (which now does real asynchronous shutdown work) so it always
      // has a listener before it settles — otherwise a same-turn completion
      // during the shutdown wait would be reported as an unhandled error
      // instead of satisfying this expectation.
      final Future<RepoHandle> inFlight = worker.openRepo('/tmp/any');
      final Future<void> expectation = expectLater(inFlight, throwsA(isA<Object>()));
      await worker.close();
      await expectation;
    });
  });
}
