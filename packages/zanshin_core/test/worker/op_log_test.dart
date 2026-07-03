// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.opLog] and [RepoHandle.opLog].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/op_log.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.opLog round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_op_log_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('opLog_on_fresh_init_returns_non_empty_log_with_root_op_last', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Operation> ops = await handle.opLog();

      expect(ops, isNotEmpty, reason: 'op log must be non-empty for any repo');

      // Root op is last.
      final Operation root = ops.last;
      expect(root.rootOp, isTrue, reason: 'last op must have rootOp == true');
      expect(root.parentIds, isEmpty, reason: 'root op parentIds must be empty');
      expect(root.description, equals(''), reason: 'root op description must be empty');

      // Head op (first) is not the root.
      final Operation head = ops.first;
      expect(head.rootOp, isFalse, reason: 'head op must not be the root');
      expect(head.parentIds, isNotEmpty, reason: 'head op must have at least one parent');

      await handle.close();
    });

    test('opLog_limit_one_returns_exactly_one_op', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Operation> ops = await handle.opLog(limit: 1);

      expect(ops.length, equals(1), reason: 'limit 1 must return exactly one op');
      expect(ops.first.rootOp, isFalse, reason: 'limit-1 result must be the head op, not the root');

      await handle.close();
    });

    test('opLog_head_op_id_equals_across_two_calls_oracle_equality', () async {
      // Oracle equality: call opLog twice and assert the head op id is stable
      // across re-resolves (ADR-0002 guarantees same head if no mutation).
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Operation> all = await handle.opLog();
      final List<Operation> limited = await handle.opLog(limit: 1);

      expect(
        limited.first.id,
        equals(all.first.id),
        reason: 'limit-1 head id must equal full-log head id (oracle equality)',
      );

      // Cross-call equality: user/host must be stable across re-resolves. We do
      // NOT assert isNotNull on the non-nullable String fields (vacuously true,
      // F20) nor hard-code identity strings — the independent jj-lib oracle
      // equality check lives in the Rust integration test
      // (zanshin-jj/tests/op_log.rs::op_log_head_op_matches_oracle).
      final Operation head = all.first;
      expect(limited.first.user, equals(head.user), reason: 'user must be stable across calls');
      expect(limited.first.host, equals(head.host), reason: 'host must be stable across calls');

      await handle.close();
    });

    test('opLog_is_reverse_chronological', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Operation> ops = await handle.opLog();
      expect(ops.length, greaterThanOrEqualTo(2), reason: 'need at least 2 ops for ordering check');

      for (var i = 0; i < ops.length - 1; i++) {
        expect(
          ops[i].timestampMillis,
          greaterThanOrEqualTo(ops[i + 1].timestampMillis),
          reason: 'op[$i] must be at least as recent as op[${i + 1}]',
        );
      }

      await handle.close();
    });

    test('opLog_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Direct worker call with the now-unknown handleId bypasses the closed guard.
      await expectLater(
        worker.opLog(handle.handleId, -1),
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

  // ── RepoHandle.opLog guard ────────────────────────────────────────────────

  group('RepoHandle.opLog closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_op_log_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('opLog_on_explicitly_closed_handle_throws_state_error_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.opLog() must throw StateError synchronously before reaching the worker.
      expect(
        handle.opLog,
        throwsA(isA<StateError>()),
      );
    });
  });
}
