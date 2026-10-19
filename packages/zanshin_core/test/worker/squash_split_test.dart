// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.15's three calls: squash, squash plan
// and split, on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/workspace_test.dart. They are also what credits each
// zanshin_squash / zanshin_squash_plan / zanshin_split extern "C" function in
// the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the three envelopes decode, and that a
// refusal surfaces as a ZanshinFfiException. The verbs' semantics are witnessed
// by the Rust suites (crates/zanshin-jj/tests/squash_split.rs) and against the
// stock CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/squash_split.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle squash / split round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change ids of `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`.
    late List<String> ids;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_squash_split_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      ids = [];
      for (final (files, description) in [
        (const {'a.txt': 'a\n'}, 'A\n'),
        (const {'b.txt': 'b\n'}, 'B\n'),
        (const {'c.txt': 'c\n', 'c2.txt': 'c2\n'}, 'C\n'),
      ]) {
        if (ids.isNotEmpty) {
          await repo.newChange([ids.last]);
        }
        files.forEach((path, text) => File('${tempDir.path}/$path').writeAsStringSync(text));
        final String at = (await repo.status()).workingCopyChangeId;
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

    test('squash_plan_then_squash_with_its_text_as_message', () async {
      final SquashPlan plan = await repo.squashPlan();
      expect(plan.combinedDescription, 'B\n\nC\n');
      expect(plan.warnings, isEmpty);

      final MutationResult result = await repo.squash(message: [plan.combinedDescription!]);

      expect(result.abandonedChangeIds, [ids[2]]);
      expect(result.newChangeIds, [result.workingCopyChangeId]);
      expect((await repo.getChange(ids[1])).description, 'B\n\nC\n');
    });

    test('every_squash_field_crosses_the_buffer', () async {
      // `from` + `into` + `paths` + `-u` + `-k`: c.txt of C moves into A, C stays.
      final SquashPlan plan = await repo.squashPlan(
        from: [ids[2]],
        into: ids[0],
        paths: const ['c.txt', 'nope.txt'],
        useDestinationMessage: true,
        keepEmptied: true,
      );
      expect(plan.combinedDescription, isNull);
      expect(plan.warnings.map((w) => w.code), ['jj.paths_unmatched']);

      final MutationResult result = await repo.squash(
        from: [ids[2]],
        into: ids[0],
        paths: const ['c.txt'],
        useDestinationMessage: true,
        keepEmptied: true,
      );
      expect(result.abandonedChangeIds, isEmpty);
      expect((await repo.getChange(ids[0])).description, 'A\n');
      expect(result.workingCopyChangeId, ids[2]);

      // `-r` with a merge-free revision and `-m`.
      await repo.squash(revision: ids[1], message: const ['T', 'U']);
      expect((await repo.getChange(ids[0])).description, 'T\n\nU\n');
    });

    test('squash_refusals_surface_their_codes', () async {
      await expectLater(
        repo.squash(revision: ids[2], into: ids[0]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      await expectLater(
        repo.squashPlan(message: const ['m'], useDestinationMessage: true),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('split_names_both_parts_and_carries_its_warnings', () async {
      final SplitResult result = await repo.split(paths: const ['c.txt'], message: const ['first']);

      expect(result.selectedChangeId, ids[2]);
      expect(result.mutation.newChangeIds, [result.remainingChangeId]);
      expect(result.mutation.workingCopyChangeId, result.remainingChangeId);
      expect(result.warnings, isEmpty);
      expect((await repo.getChange(ids[2])).description, 'first\n');

      final SplitResult none = await repo.split(revision: ids[1], paths: const ['nope.txt']);
      expect(none.warnings.map((w) => w.code), ['jj.paths_unmatched', 'jj.split_none_selected']);
    });

    test('every_split_location_crosses_the_buffer', () async {
      final SplitResult before = await repo.split(paths: const ['c.txt'], insertBefore: [ids[1]]);
      expect(before.remainingChangeId, ids[2], reason: 'with a location the remaining part keeps the id');
      expect(before.mutation.newChangeIds, [before.selectedChangeId]);

      final SplitResult after = await repo.split(paths: const ['c2.txt'], insertAfter: [ids[0]], message: const ['m']);
      expect(after.remainingChangeId, ids[2]);

      await expectLater(
        repo.split(paths: const ['c.txt'], onto: const []),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'No revisions found to use as parent'),
        ),
      );
      await expectLater(
        repo.split(paths: const ['c.txt'], parallel: true, onto: [ids[0]]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('split_without_paths_is_refused', () async {
      await expectLater(
        repo.split(paths: const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('split_parallel_puts_both_parts_on_the_parents', () async {
      final SplitResult result = await repo.split(paths: const ['c.txt'], parallel: true);

      expect(result.selectedChangeId, ids[2]);
      expect((await repo.getChange(result.remainingChangeId)).description, 'C\n');
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      await expectLater(repo.squash(paths: const ['a\u0000b']), throwsArgumentError);
      await expectLater(repo.squashPlan(message: const ['a\u0000b']), throwsArgumentError);
      await expectLater(repo.split(paths: const ['c.txt'], insertBefore: const ['a\u0000b']), throwsArgumentError);
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(other.squash, throwsStateError);
      expect(other.squashPlan, throwsStateError);
      expect(() => other.split(paths: const ['c.txt']), throwsStateError);
    });
  });
}
