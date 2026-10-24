// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.18's `revert` on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/metaedit_duplicate_fix_test.dart. They are also what credits the
// zanshin_revert extern "C" function in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelope decodes, and that a
// refusal surfaces as a ZanshinFfiException. The verb's semantics are witnessed
// by the Rust suite (crates/zanshin-jj/tests/it/revert.rs) and against the
// stock CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart' show Change;
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle.revert round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change ids of `A (a.txt) → B (b.txt) → C (c.txt) = @`.
    late List<String> ids;

    Future<Change> change(String changeId) => repo.getChange(changeId);

    Future<String> headOp() async => (await repo.opLog(limit: 1)).single.id;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_revert_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      ids = [];
      for (final (path, description) in [('a.txt', 'A\n'), ('b.txt', 'B\n'), ('c.txt', 'C\n')]) {
        if (ids.isNotEmpty) {
          await repo.newChange([ids.last]);
        }
        File('${tempDir.path}/$path').writeAsStringSync('x\n');
        final String at = (await repo.status()).workingCopyChangeId!;
        await repo.describe(changeId: at, description: description);
        ids.add(at);
      }
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a_revert_at_each_location_flag_yields_one_new_change', () async {
      final MutationResult onto = await repo.revert(revisions: [ids[1]], onto: [ids[2]]);
      expect(onto.newOpId, await headOp());
      final Change reverse = await change(onto.newChangeIds.single);
      expect(reverse.parents, [ids[2]]);
      expect(reverse.description, startsWith('Revert "B"\n\nThis reverts commit '));

      final MutationResult after = await repo.revert(revisions: [ids[2]], insertAfter: [ids[0]]);
      expect((await change(after.newChangeIds.single)).parents, [ids[0]]);
      expect((await change(ids[1])).parents, [after.newChangeIds.single]);

      final MutationResult before = await repo.revert(revisions: [ids[0]], insertBefore: [ids[2]]);
      expect((await change(ids[2])).parents, [before.newChangeIds.single]);
    });

    test('onto_with_insert_after_refuses_invalid_input_and_writes_nothing', () async {
      final String before = await headOp();
      await expectLater(
        repo.revert(revisions: [ids[1]], onto: [ids[2]], insertAfter: [ids[0]]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      expect(await headOp(), before);
    });
  });
}
