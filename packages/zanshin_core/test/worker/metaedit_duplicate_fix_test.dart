// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.9's three calls: metaedit, duplicate and
// fix, on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/rebase_test.dart. They are also what credits each
// zanshin_metaedit / zanshin_duplicate / zanshin_fix extern "C" function in
// the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelopes decode, and that a
// refusal surfaces as a ZanshinFfiException. The verbs' semantics are witnessed
// by the Rust suites (crates/zanshin-jj/tests/it/metaedit.rs, duplicate.rs,
// fix.rs) and against the stock CLI by the parity oracle
// (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart' show Change;
import 'package:zanshin_core/src/ffi/metaedit_duplicate_fix.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle metaedit / duplicate / fix round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change ids of `A (a.txt) → B (b.txt) → C (c.txt) = @`, each file `x`.
    late List<String> ids;

    Future<Change> change(String changeId) => repo.getChange(changeId);

    Future<String> headOp() async => (await repo.opLog(limit: 1)).single.id;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_metaedit_duplicate_fix_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync(
        "[fix.tools.upper]\ncommand = ['tr', 'a-z', 'A-Z']\npatterns = [\"glob:'*.txt'\"]\n",
      );
      ids = [];
      for (final (path, description) in [('a.txt', 'A\n'), ('b.txt', 'B\n'), ('c.txt', 'C\n')]) {
        if (ids.isNotEmpty) {
          await repo.newChange([ids.last]);
        }
        File('${tempDir.path}/$path').writeAsStringSync('x\n');
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

    test('every_metaedit_field_crosses_the_buffer', () async {
      final MutationResult described = await repo.metaedit(revisions: [ids[1]], message: ['X']);
      expect(described.newOpId, await headOp());
      expect((await change(ids[1])).description, 'X\n');

      await repo.metaedit(
        revisions: [ids[1]],
        author: 'Foo Bar <foo@bar>',
        authorTimestamp: '2000-01-23T01:23:45-08:00',
      );
      Change b = await change(ids[1]);
      expect((b.author.name, b.author.email), ('Foo Bar', 'foo@bar'));
      expect(b.author.timestampMillis, DateTime.parse('2000-01-23T01:23:45-08:00').millisecondsSinceEpoch);

      await repo.metaedit(revisions: [ids[1]], updateAuthor: true, updateAuthorTimestamp: true);
      b = await change(ids[1]);
      expect(b.author.email, b.committer.email);
      expect(b.author.timestampMillis, b.committer.timestampMillis);

      final String before = await headOp();
      final MutationResult forced = await repo.metaedit(forceRewrite: true);
      expect(forced.newOpId, isNot(before), reason: '--force-rewrite rewrites @ with nothing else changed');

      final MutationResult minted = await repo.metaedit(revisions: [ids[0]], updateChangeId: true);
      expect(minted.newChangeIds, hasLength(1));
      expect(minted.newChangeIds.single, isNot(ids[0]));
    });

    test('a_metaedit_clap_refusal_surfaces_as_invalid_input', () async {
      final String before = await headOp();
      await expectLater(
        repo.metaedit(author: 'Foo <foo@bar>', updateAuthor: true),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      expect(await headOp(), before);
    });

    test('every_duplicate_field_crosses_the_buffer', () async {
      final MutationResult plain = await repo.duplicate(revisions: [ids[1]]);
      expect(plain.newOpId, await headOp());
      expect((await change(plain.newChangeIds.single)).parents, [ids[0]]);

      final MutationResult onto = await repo.duplicate(revisions: [ids[0]], onto: [ids[2]]);
      expect((await change(onto.newChangeIds.single)).parents, [ids[2]]);
      expect(onto.warnings.map((w) => w.code), [ZanshinWarningCode.duplicateAsOwnDescendant]);

      final MutationResult after = await repo.duplicate(revisions: [ids[2]], insertAfter: [ids[0]]);
      expect((await change(after.newChangeIds.single)).parents, [ids[0]]);
      expect((await change(ids[1])).parents, [after.newChangeIds.single]);

      final MutationResult before = await repo.duplicate(revisions: [ids[2]], insertBefore: [ids[1]]);
      expect((await change(ids[1])).parents, [before.newChangeIds.single]);
      expect(before.warnings.map((w) => w.code), [ZanshinWarningCode.duplicateAsOwnAncestor]);
    });

    // The fix tool here can never start, so every run warns
    // `jj.fix_tool_start_failed` deterministically. A tool that does run is
    // witnessed by the Rust suites only: under `dart test` the VM reaps child
    // processes it did not start (its exit-code handler waits on any pid while
    // a Dart-started process — the test runner's — is alive), so a tool's exit
    // status is lost at random and the CLI's runner then keeps the old content.
    test('every_fix_field_crosses_the_buffer', () async {
      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync(
        "[fix.tools.gone]\ncommand = ['/nonexistent']\npatterns = [\"glob:'*.txt'\"]\n",
      );
      final String before = await headOp();
      final FixResult c = await repo.fix(source: [ids[2]], includeUnchangedFiles: true, allLines: true);
      expect((c.numFixedCommits, c.numCheckedCommits), (0, 1));
      expect(c.mutation.newOpId, before, reason: 'nothing fixed: no operation');
      expect(c.toolStderr, isEmpty);
      expect(
        c.warnings.map((w) => w.code),
        List.filled(3, ZanshinWarningCode.fixToolStartFailed),
        reason: 'with unchanged files, C hands all three of its files to the tool',
      );

      final FixResult paths = await repo.fix(paths: ['b.txt', 'nope.txt']);
      expect(paths.numCheckedCommits, 3);
      expect(paths.warnings.map((w) => w.code), [
        ZanshinWarningCode.pathsUnmatched,
        ZanshinWarningCode.fixToolStartFailed,
      ], reason: "b.txt's one content, run once");
      expect(await headOp(), before);
    });

    test('a_fix_refusal_surfaces_as_a_ffi_exception', () async {
      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync('');
      await expectLater(
        repo.fix(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_error')),
      );
    });

    test('the_three_calls_refuse_a_closed_handle_synchronously', () async {
      await repo.close();
      expect(() => repo.metaedit(), throwsStateError);
      expect(() => repo.duplicate(), throwsStateError);
      expect(() => repo.fix(), throwsStateError);
    });
  });
}
