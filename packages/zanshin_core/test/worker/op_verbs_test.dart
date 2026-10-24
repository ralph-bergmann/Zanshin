// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.21's operation verbs — redo, opShow,
// opDiff, opAbandon — and the op log's workspace name, and Story 9.12's
// opRestore, opRevert and opIntegrate, against the REAL compiled cdylib through
// the REAL worker isolate (no mocks; project-context "Worker / isolate
// testing"). They also credit `zanshin_redo`, `zanshin_op_show`,
// `zanshin_op_diff`, `zanshin_op_abandon`, `zanshin_op_restore`,
// `zanshin_op_revert` and `zanshin_op_integrate` in the coverage ratchet's
// extern-fn guard (mem:project-coverage-extern-fn-needs-zanshin-core-test).

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/op_log.dart';
import 'package:zanshin_core/src/ffi/warning.dart' show ZanshinWarningCode;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('operation verbs (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle handle;
    late String wc;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_op_verbs_test_');
      worker = await ZanshinWorker.start();
      handle = await worker.initRepo(tempDir.path, backend: 0);
      wc = (await handle.status()).workingCopyChangeId;
      await handle.describe(changeId: wc, description: 'A');
      await handle.describe(changeId: wc, description: 'B');
    });

    tearDown(() async {
      await handle.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('the op log names the workspace of each operation', () async {
      final List<Operation> ops = await handle.opLog();

      expect(ops.first.workspaceName, 'default');
      expect(ops.last.rootOp, isTrue);
      expect(ops.last.workspaceName, isNull);
    });

    test('redo after undo restores the undone describe; then nothing to redo', () async {
      final String describeB = (await handle.opLog(limit: 1)).single.id;
      await handle.undo();
      expect((await handle.getChange(wc)).description, 'A');

      final MutationResult result = await handle.redo();

      expect((await handle.getChange(wc)).description, 'B');
      final Operation head = (await handle.opLog(limit: 1)).single;
      expect(head.id, result.newOpId);
      expect(head.description, 'redo: restore to operation $describeB');
      await expectLater(
        handle.redo(allowCrossWorkspace: true),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.nothing_to_redo')
              .having((e) => e.context, 'context', 'Nothing to redo'),
        ),
      );
    });

    test('opShow of the head describe and of its parent by expression', () async {
      final OpShow show = await handle.opShow();

      expect(show.operation.workspaceName, 'default');
      final OpCommitsDiff commits = show.diff!.commits!;
      expect(commits.changes.single.removedCommitIds, hasLength(1), reason: 'the rewritten @ and its predecessor');
      expect(commits.elidedNewlyVisible.lower, 0);

      final OpShow parent = await handle.opShow(operation: '@-', showChangesIn: 'all()');
      expect(parent.operation.id, show.operation.parentIds.single);

      await expectLater(
        handle.opShow(operation: 'ffffffffffff'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.operation_not_found')),
      );
    });

    test('opDiff compares two operations; operation with from is refused', () async {
      final OpDiffResult result = await handle.opDiff(from: '@-');

      expect(result.from, hasLength(1));
      expect(result.to.id, (await handle.opLog(limit: 1)).single.id);
      expect(result.diff.commits!.changes, hasLength(1));

      await expectLater(
        handle.opDiff(operation: '@', to: '@-'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', "the argument '--operation' cannot be used with '--to'"),
        ),
      );
    });

    test('showChangesIn crosses the seam: none() elides every changed commit', () async {
      final OpShow show = await handle.opShow(showChangesIn: 'none()');
      expect(show.diff!.commits!.changes, isEmpty);
      expect(show.diff!.commits!.elidedNewlyVisible.lower, greaterThan(0));

      final OpDiffResult diff = await handle.opDiff(from: '@-', showChangesIn: 'none()');
      expect(diff.diff.commits!.changes, isEmpty);
      expect(diff.diff.commits!.elidedNewlyVisible.lower, greaterThan(0));
    });

    test('opAbandon of the history below the head reparents it onto the root', () async {
      await expectLater(
        handle.opAbandon('@'),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input').having((e) => e.hints, 'hints', [
            'Run `jj undo` to revert the current operation, then use `jj op abandon`',
          ]),
        ),
      );

      final OpAbandonResult result = await handle.opAbandon('..@-');

      expect(result.nothingChanged, isFalse);
      expect(result.reparentedCount, 1);
      final List<Operation> ops = await handle.opLog();
      expect(ops, hasLength(2));
      expect(ops.first.parentIds, [ops.last.id], reason: "the newest entry's parent is the root operation");
      expect(result.headOpIds, [ops.first.id]);
      expect((await handle.opAbandon('..@-')).nothingChanged, isTrue);
    });

    test('opRestore to before the second describe brings A back', () async {
      final String describeA = (await handle.opLog(limit: 2)).last.id;

      final MutationResult result = await handle.opRestore('@-', what: const [RestoreWhat.repo]);

      expect((await handle.getChange(wc)).description, 'A');
      final Operation head = (await handle.opLog(limit: 1)).single;
      expect(head.id, result.newOpId);
      expect(head.description, 'restore to operation $describeA');
      expect(result.workingCopyChangeId, wc);
      final MutationResult again = await handle.opRestore('@');
      expect(again.newOpId, result.newOpId, reason: 'an equal view writes nothing');
    });

    test('opRestore of the root operation leaves no working copy and warns', () async {
      final MutationResult result = await handle.opRestore('000000000000');

      expect(result.workingCopyChangeId, isNull);
      expect(result.warnings.map((w) => w.code), [ZanshinWarningCode.workspaceNoLongerExists]);
      expect((await handle.opLog(limit: 1)).single.id, result.newOpId);
    });

    test('opRevert of the head undoes the describe; the root is refused', () async {
      final String describeB = (await handle.opLog(limit: 1)).single.id;

      await handle.opRevert();

      expect((await handle.getChange(wc)).description, 'A');
      expect((await handle.opLog(limit: 1)).single.description, 'revert operation $describeB');
      await expectLater(
        handle.opRevert(operation: '000000000000'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Cannot revert root operation'),
        ),
      );
    });

    test('the chosen --what portion reaches restore and revert', () async {
      final String head = (await handle.opLog(limit: 1)).single.id;

      // Only the remote-tracking portion — equal here (no remotes): nothing is
      // written and `B` stays. Both portions would bring `A` back.
      final MutationResult restored = await handle.opRestore('@-', what: const [RestoreWhat.remoteTracking]);
      expect(restored.newOpId, head, reason: 'the remote-tracking view is unchanged');
      expect((await handle.getChange(wc)).description, 'B');

      // A bookmark create is a repo-portion change with no rewrite: reverting
      // only the remote-tracking portion is "Nothing changed." (as the CLI),
      // the repo portion removes the bookmark.
      final String created = (await handle.bookmarkCreate(const ['m'])).newOpId;
      final MutationResult remoteOnly = await handle.opRevert(what: const [RestoreWhat.remoteTracking]);
      expect(remoteOnly.newOpId, created, reason: 'no remote-tracking bookmark changed');
      expect((await handle.bookmarks()).map((b) => b.name), contains('m'));
      final MutationResult repoOnly = await handle.opRevert(what: const [RestoreWhat.repo]);
      expect(repoOnly.newOpId, isNot(created));
      expect((await handle.bookmarks()).map((b) => b.name), isNot(contains('m')));
    });

    test('opIntegrate of an operation in the log changes nothing', () async {
      final String head = (await handle.opLog(limit: 1)).single.id;

      final OpIntegrateResult result = await handle.opIntegrate('@-');

      expect(result.headOpId, head);
      expect(result.reconciled, isFalse);
      await expectLater(
        handle.opIntegrate('ffffffffffff'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.operation_not_found')),
      );
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      const nul = 'a\u0000b';
      await expectLater(handle.opShow(operation: nul), throwsArgumentError);
      await expectLater(handle.opShow(showChangesIn: nul), throwsArgumentError);
      await expectLater(handle.opDiff(operation: nul), throwsArgumentError);
      await expectLater(handle.opDiff(from: nul), throwsArgumentError);
      await expectLater(handle.opDiff(to: nul), throwsArgumentError);
      await expectLater(handle.opDiff(showChangesIn: nul), throwsArgumentError);
      await expectLater(handle.opAbandon(nul), throwsArgumentError);
      await expectLater(handle.opRestore(nul), throwsArgumentError);
      await expectLater(handle.opRevert(operation: nul), throwsArgumentError);
      await expectLater(handle.opIntegrate(nul), throwsArgumentError);
    });

    test('the seven verbs refuse on a closed handle', () async {
      final Directory otherDir = Directory.systemTemp.createTempSync('zanshin_op_closed_');
      addTearDown(() => otherDir.deleteSync(recursive: true));
      final RepoHandle other = await worker.initRepo(otherDir.path, backend: 0);
      final int id = other.handleId;
      await other.close();

      for (final Future<Object?> Function() call in [
        () => worker.redo(id),
        () => worker.opShow(id),
        () => worker.opDiff(id),
        () => worker.opAbandon(id, '..@-'),
        () => worker.opRestore(id, '@-'),
        () => worker.opRevert(id),
        () => worker.opIntegrate(id, '@-'),
      ]) {
        await expectLater(
          call(),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
        );
      }
      expect(other.redo, throwsA(isA<StateError>()));
      expect(other.opShow, throwsA(isA<StateError>()));
      expect(other.opDiff, throwsA(isA<StateError>()));
      expect(() => other.opAbandon('..@-'), throwsA(isA<StateError>()));
      expect(() => other.opRestore('@-'), throwsA(isA<StateError>()));
      expect(other.opRevert, throwsA(isA<StateError>()));
      expect(() => other.opIntegrate('@-'), throwsA(isA<StateError>()));
    });
  });
}
