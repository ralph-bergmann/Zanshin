// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 4.10's op-pinned batch content lookup,
// on both [ZanshinWorker] (through [RepoHandle]) and the real cdylib.
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits the
// zanshin_commit_contents extern "C" function in the coverage ratchet's
// extern-fn guard (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// The error ladder's every row and the pinned read's write-nothing contract live
// in the Rust suites (crates/zanshin-jj/tests/commit_contents.rs,
// crates/zanshin-ffi/tests/commit_contents_ffi.rs). What these tests own is the
// DART half of the chain: the request fields are built and cross the buffer, the
// payload decodes in request order, each jj error surfaces as a
// ZanshinFfiException, and the calling-side guards fire.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_contents.dart';
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/op_log.dart';
import 'package:zanshin_core/src/ffi/precondition.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// The head operation's full id (the op log runs the pre-verb snapshot, which
/// writes nothing on an unchanged tree).
Future<String> headOp(RepoHandle handle) async {
  final List<Operation> ops = await handle.opLog(limit: 1);
  return ops.single.id;
}

/// The working-copy commit id and the root commit id.
Future<(String, String)> wcAndRoot(RepoHandle handle) async {
  final GraphSlice slice = await handle.graphSlice(revset: 'all()');
  final String root = slice.rows.singleWhere((r) => r.meta?.root ?? false).commitId;
  final String wc = await handle.status().then((s) => handle.getChange(s.workingCopyChangeId)).then((c) => c.commitId);
  return (wc, root);
}

void main() {
  group('ZanshinWorker commitContents round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_commit_contents_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('commit_contents_answers_in_request_order_with_the_full_description', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final String wcChange = (await handle.status()).workingCopyChangeId;
      await handle.describe(changeId: wcChange, description: 'Subject\n\nBody\n');
      final (String wc, String root) = await wcAndRoot(handle);
      final String op = await headOp(handle);
      final Precondition? before = handle.lastPrecondition;

      final WarnedList<CommitContent> contents = await handle.commitContents(operationId: op, commitIds: [wc, root]);

      expect(contents.map((c) => c.commitId), [wc, root], reason: 'request order');
      expect(contents[0].description, 'Subject\n\nBody\n', reason: 'the FULL description');
      expect(contents[0].authorEmail, 'zanshin@localhost', reason: 'the pinned test identity (JJ_EMAIL)');
      expect(contents[0].committerTimestampMillis, greaterThan(0));
      expect(contents[0].empty, isTrue, reason: 'a described but otherwise untouched @ is empty');
      expect(contents[1].description, '', reason: 'the root has no description');
      expect(contents.warnings, isEmpty, reason: 'the pinned read records no warning');
      expect(handle.lastPrecondition, same(before), reason: 'the pinned read runs no precondition');

      await handle.close();
    });

    test('commit_contents_surfaces_each_jj_error_as_a_zanshin_ffi_exception', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final (String wc, _) = await wcAndRoot(handle);
      final String op = await headOp(handle);
      final String unknownOp = 'ab' * 64;
      // A full-length id (the native backend's ids are 128 hex digits) no commit carries.
      final String absent = 'f' * wc.length;

      await expectLater(
        handle.commitContents(operationId: unknownOp, commitIds: const []),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.operation_not_found')
              .having((e) => e.context, 'context', 'No operation ID matching "$unknownOp"')
              .having((e) => e.precondition, 'precondition', isNull),
        ),
      );
      await expectLater(
        handle.commitContents(operationId: 'xyz', commitIds: const []),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Operation ID "xyz" is not a valid hexadecimal prefix'),
        ),
      );
      await expectLater(
        handle.commitContents(operationId: op, commitIds: [absent]),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', absent),
        ),
      );
      expect(await handle.commitContents(operationId: op, commitIds: const []), isEmpty);

      await handle.close();
    });

    test('commit_contents_rejects_interior_nuls_on_the_calling_side', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);

      await expectLater(handle.commitContents(operationId: 'ab${nul}cd', commitIds: const []), throwsArgumentError);
      await expectLater(handle.commitContents(operationId: 'abcd', commitIds: ['a${nul}b']), throwsArgumentError);

      await handle.close();
    });

    test('commit_contents_on_a_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.commitContents(operationId: 'ab', commitIds: const []), throwsStateError);
    });
  });
}
