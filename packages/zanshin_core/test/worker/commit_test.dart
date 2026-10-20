// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.49's `commit` on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/squash_split_test.dart. They are also what credits the
// zanshin_commit extern "C" function in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelope decodes, and that a
// refusal surfaces as a ZanshinFfiException. The verb's semantics are witnessed
// by the Rust suites (crates/zanshin-jj/tests/it/commit.rs) and against the stock
// CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle commit round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change id of `@`, which adds a.txt and b.txt on the root.
    late String at;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_commit_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/a.txt').writeAsStringSync('a\n');
      File('${tempDir.path}/b.txt').writeAsStringSync('b\n');
      at = (await repo.status()).workingCopyChangeId;
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('commit_everything_describes_at_and_answers_the_new_at', () async {
      final MutationResult result = await repo.commit(message: const ['subject', 'body']);

      expect(result.newChangeIds, [result.workingCopyChangeId]);
      expect(result.workingCopyChangeId, isNot(at));
      expect(result.warnings, isEmpty);
      expect((await repo.getChange(at)).description, 'subject\n\nbody\n');
      expect((await repo.status()).files, isEmpty, reason: 'the new @ is empty');
    });

    test('commit_paths_cross_the_buffer_and_the_rest_stays_in_the_new_at', () async {
      final MutationResult result = await repo.commit(message: const ['first'], paths: const ['a.txt']);

      // The new @ shows only b.txt, so a.txt sits unchanged in its parent, the committed @.
      expect((await repo.status()).files.map((f) => f.path), ['b.txt']);
      expect(result.workingCopyChangeId, isNot(at));
      expect((await repo.getChange(at)).description, 'first\n');
    });

    test('unmatched_paths_carry_their_warning', () async {
      final MutationResult result = await repo.commit(message: const ['first'], paths: const ['nope.txt']);

      expect(result.warnings.map((w) => w.code), ['jj.commit_paths_unmatched']);
      expect(result.warnings.single.message, 'The given paths do not match any file: nope.txt');
    });

    test('an_invalid_path_is_refused', () async {
      await expectLater(
        repo.commit(message: const ['first'], paths: const ['/x']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      await expectLater(repo.commit(message: const ['a\u0000b']), throwsArgumentError);
      await expectLater(repo.commit(message: const ['m'], paths: const ['a\u0000b']), throwsArgumentError);
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(() => other.commit(message: const ['m']), throwsStateError);
    });
  });
}
