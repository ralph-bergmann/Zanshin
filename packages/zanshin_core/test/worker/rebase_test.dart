// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.16's three calls: rebase, parallelize
// and arrange, on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/squash_split_test.dart. They are also what credits each
// zanshin_rebase / zanshin_parallelize / zanshin_arrange extern "C" function in
// the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelopes decode, and that a
// refusal surfaces as a ZanshinFfiException. The verbs' semantics are witnessed
// by the Rust suites (crates/zanshin-jj/tests/it/rebase.rs,
// parallelize_arrange.rs) and, for rebase and parallelize, against the stock
// CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/rebase.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle rebase / parallelize / arrange round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change ids of `A (a.txt) → B (b.txt) → C (c.txt) = @`.
    late List<String> ids;

    Future<List<String>> parents(String changeId) async => (await repo.getChange(changeId)).parents;

    Future<String> headOp() async => (await repo.opLog(limit: 1)).single.id;

    /// A new commit on [parents] writing [files], described [description]; `@` ends on it.
    Future<String> add(List<String> parents, Map<String, String> files, String description) async {
      await repo.newChange(parents);
      files.forEach((path, text) => File('${tempDir.path}/$path').writeAsStringSync(text));
      final String at = (await repo.status()).workingCopyChangeId!;
      await repo.describe(changeId: at, description: description);
      return at;
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_rebase_test_');
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

    test('rebase_source_onto_crosses_the_buffer', () async {
      final MutationResult result = await repo.rebase(source: [ids[2]], onto: [ids[0]]);

      expect(result.newOpId, await headOp());
      expect(await parents(ids[2]), [ids[0]]);
      expect(result.workingCopyChangeId, ids[2]);
    });

    test('every_rebase_field_crosses_the_buffer', () async {
      // `-r C -B B`: C moves between A and B.
      await repo.rebase(revisions: [ids[2]], insertBefore: [ids[1]]);
      expect(await parents(ids[1]), [ids[2]]);
      // `-r B -A A` with the three flags: B moves back between A and C.
      await repo.rebase(
        revisions: [ids[1]],
        insertAfter: [ids[0]],
        skipEmptied: true,
        keepDivergent: true,
        simplifyParents: true,
      );
      expect(await parents(ids[2]), [ids[1]]);
      // `-b C -o A`: roots(A..C) is B, already on A — no operation.
      final String before = await headOp();
      final MutationResult noOp = await repo.rebase(branch: [ids[2]], onto: [ids[0]]);
      expect(noOp.newOpId, before);
    });

    test('skip_emptied_crosses_the_buffer', () async {
      // Both re-add B's b.txt on A: onto B they are empty.
      final String kept = await add([ids[0]], const {'b.txt': 'x\n'}, 'D1\n');
      final String skipped = await add([ids[0]], const {'b.txt': 'x\n'}, 'D2\n');

      final MutationResult keep = await repo.rebase(revisions: [kept], onto: [ids[1]]);
      expect(keep.abandonedChangeIds, isEmpty);
      expect(await parents(kept), [ids[1]]);

      final MutationResult skip = await repo.rebase(revisions: [skipped], onto: [ids[1]], skipEmptied: true);
      expect(skip.abandonedChangeIds, [skipped]);
      expect(skip.newChangeIds, [skip.workingCopyChangeId], reason: 'the emptied commit was @');
    });

    test('simplify_parents_crosses_the_buffer', () async {
      // M = merge(C, B), X on the root: `-s A -o X` leaves M's parent B
      // redundant (B is C's ancestor); only --simplify-parents drops it.
      final String m = await add([ids[2], ids[1]], const {}, 'M\n');
      final String x = await add(['z' * 32], const {'x.txt': 'x\n'}, 'X\n');

      await repo.rebase(source: [ids[0]], onto: [x], simplifyParents: true);

      expect(await parents(m), [ids[2]]);
      expect(await parents(ids[0]), [x]);
    });

    test('branch_crosses_the_buffer_and_moves_the_roots_of_the_branch', () async {
      final String x = await add(['z' * 32], const {'x.txt': 'x\n'}, 'X\n');

      // `-b C -o X` with `@` on X: roots(X..C) is A.
      await repo.rebase(branch: [ids[2]], onto: [x]);

      expect(await parents(ids[0]), [x]);
      expect(await parents(ids[2]), [ids[1]]);
    });

    test('rebase_refusals_surface_their_codes', () async {
      await expectLater(
        repo.rebase(source: [ids[0]], onto: [ids[1]]),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', startsWith('Cannot rebase ')),
        ),
      );
      await expectLater(
        repo.rebase(revisions: [ids[1]]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('parallelize_makes_siblings', () async {
      final MutationResult result = await repo.parallelize([ids[1], ids[2]]);

      expect(result.newOpId, await headOp());
      expect(await parents(ids[2]), [ids[0]]);
      await expectLater(
        repo.parallelize(['k' * 32]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.change_not_found')),
      );
    });

    test('arrange_replays_every_action_kind', () async {
      // Swap C down, swap it back up, abandon B and keep it again, then abandon B.
      final MutationResult result = await repo.arrange(
        revisions: [ids[1], ids[2]],
        actions: [
          SwapDownAction(ids[2]),
          SwapUpAction(ids[2]),
          AbandonAction(ids[1]),
          KeepAction(ids[1]),
          AbandonAction(ids[1]),
        ],
      );

      expect(result.abandonedChangeIds, [ids[1]]);
      expect(await parents(ids[2]), [ids[0]]);
    });

    test('arrange_swap_down_alone_swaps_with_the_parent', () async {
      await repo.arrange(revisions: [ids[1], ids[2]], actions: [SwapDownAction(ids[2])]);
      expect(await parents(ids[2]), [ids[0]]);
      expect(await parents(ids[1]), [ids[2]]);
    });

    test('arrange_swap_up_alone_swaps_with_the_child', () async {
      await repo.arrange(revisions: [ids[1], ids[2]], actions: [SwapUpAction(ids[1])]);
      expect(await parents(ids[2]), [ids[0]]);
      expect(await parents(ids[1]), [ids[2]]);
    });

    test('arrange_abandon_then_keep_writes_no_operation', () async {
      final String before = await headOp();
      final MutationResult result = await repo.arrange(
        revisions: [ids[1], ids[2]],
        actions: [AbandonAction(ids[1]), KeepAction(ids[1])],
      );
      expect(result.newOpId, before);
      expect(result.abandonedChangeIds, isEmpty);
    });

    test('arrange_a_gap_refuses_with_the_clis_hint', () async {
      await expectLater(
        repo.arrange(revisions: [ids[0], ids[2]]),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Cannot arrange revset with gaps in.')
              .having((e) => e.hints.single, 'hint', endsWith(' would need to be in the set.')),
        ),
      );
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      await expectLater(repo.rebase(onto: const ['a\u0000b']), throwsArgumentError);
      await expectLater(repo.parallelize(const ['a\u0000b']), throwsArgumentError);
      await expectLater(repo.arrange(actions: const [KeepAction('a\u0000b')]), throwsArgumentError);
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(other.rebase, throwsStateError);
      expect(() => other.parallelize(const []), throwsStateError);
      expect(other.arrange, throwsStateError);
    });
  });
}
