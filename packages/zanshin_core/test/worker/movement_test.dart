// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.10's two calls: moveWorkingCopy and
// movementTargets, on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/metaedit_duplicate_fix_test.dart. They are also what credits the
// zanshin_move_working_copy / zanshin_movement_targets extern "C" functions in
// the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelopes decode, and that a
// refusal surfaces as a ZanshinFfiException. The verbs' semantics are witnessed
// by the Rust suites (crates/zanshin-jj/tests/it/movement.rs) and against the
// stock CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart' show Change;
import 'package:zanshin_core/src/ffi/movement.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle moveWorkingCopy / movementTargets round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change ids of `A (a.txt) → B (b.txt) → C (c.txt) = @`.
    late List<String> ids;

    Future<Change> change(String changeId) => repo.getChange(changeId);

    Future<String> at() async => (await repo.status()).workingCopyChangeId!;

    Future<String> headOp() async => (await repo.opLog(limit: 1)).single.id;

    Matcher ffiCode(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_movement_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      ids = [];
      for (final (path, description) in [('a.txt', 'A\n'), ('b.txt', 'B\n'), ('c.txt', 'C\n')]) {
        if (ids.isNotEmpty) {
          await repo.newChange([ids.last]);
        }
        File('${tempDir.path}/$path').writeAsStringSync('x\n');
        final String wc = await at();
        await repo.describe(changeId: wc, description: description);
        ids.add(wc);
      }
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('every_move_field_crosses_the_buffer', () async {
      final MutationResult back = await repo.moveWorkingCopy(direction: MovementDirection.prev, edit: true, offset: 2);
      expect(back.newOpId, await headOp());
      expect(back.workingCopyChangeId, ids[0], reason: 'prev --edit 2');

      await repo.moveWorkingCopy(edit: true, offset: 2);
      expect(await at(), ids[2], reason: 'next --edit 2');

      // The only candidate of `prev` (non-edit) is A; C is stale.
      final String cCommit = (await change(ids[2])).commitId;
      await expectLater(
        repo.moveWorkingCopy(direction: MovementDirection.prev, target: cCommit),
        ffiCode('jj.stale_selection'),
      );
      final String aCommit = (await change(ids[0])).commitId;
      await repo.moveWorkingCopy(direction: MovementDirection.prev, target: aCommit);
      expect((await change(await at())).parents, [ids[0]], reason: 'a new @ on the chosen A');

      final String before = await headOp();
      await expectLater(
        repo.moveWorkingCopy(direction: MovementDirection.prev, conflict: true),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'The working copy parent(s) have no ancestors with conflicts')
              .having((e) => e.hints, 'hints', hasLength(1)),
        ),
      );
      await expectLater(
        repo.moveWorkingCopy(edit: true, noEdit: true),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', "the argument '--edit' cannot be used with '--no-edit'"),
        ),
        reason: 'clap: --edit with --no-edit',
      );
      await expectLater(repo.moveWorkingCopy(offset: -1), throwsArgumentError);
      await expectLater(repo.movementTargets(offset: -1), throwsArgumentError);
      expect(await headOp(), before, reason: 'no refusal wrote an operation');
    });

    test('every_targets_field_crosses_the_buffer', () async {
      final MovementTargets plain = await repo.movementTargets(direction: MovementDirection.prev);
      expect(plain.edit, isFalse);
      expect(plain.targets.map((t) => t.changeId), [ids[0]]);
      expect(plain.targets.single.commitId, (await change(ids[0])).commitId);

      final MovementTargets two = await repo.movementTargets(direction: MovementDirection.prev, edit: true, offset: 2);
      expect(two.edit, isTrue);
      expect(two.targets.map((t) => t.changeId), [ids[0]]);

      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync('[ui.movement]\nedit = true\n');
      expect((await repo.movementTargets(direction: MovementDirection.prev)).edit, isTrue);
      expect((await repo.movementTargets(direction: MovementDirection.prev, noEdit: true)).edit, isFalse);

      await expectLater(
        repo.movementTargets(direction: MovementDirection.prev, conflict: true, offset: 1),
        ffiCode('jj.invalid_input'),
        reason: 'clap: an offset with --conflict',
      );
    });
  });
}
