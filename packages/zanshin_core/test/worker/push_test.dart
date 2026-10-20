// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.20's `gitPush` on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits
// `zanshin_git_push` in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// WHY no real push here: a push runs a real `git` subprocess, and
// `Child::wait()` on it fails inside any `dart test` process — the Dart VM reaps
// its children (see `mutate_test.dart`'s `gitFetch` note). These tests stay on
// the paths that spawn no git: a dry run (planning only) and the refusals
// before the network. The push itself is witnessed in Rust
// (crates/zanshin-jj/tests/push.rs, crates/zanshin-ffi/tests/push_ffi.rs) and
// against the stock CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/push.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle.gitPush round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_push_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a push with no remote is the CLI refusal', () async {
      await expectLater(
        repo.gitPush(remotes: const []).result,
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'No git remotes to push to'),
        ),
      );
    });

    test('conflicting modes are refused before anything runs', () async {
      await expectLater(
        repo.gitPush(all: true, tracked: true).result,
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    /// A remote written straight into the internal git store's config: no `git`
    /// runs, and a dry run never reaches the URL. The handle is reopened because
    /// the git backend reads that config once, when the repo loads.
    Future<void> addRemote() async {
      await repo.close();
      File(
        '${tempDir.path}/.jj/repo/store/git/config',
      ).writeAsStringSync('\n[remote "origin"]\n\turl = /nowhere\n', mode: FileMode.append);
      repo = await worker.openRepo(tempDir.path);
    }

    test('named, changes and allowEmptyDescription reach the plan', () async {
      await addRemote();
      // `@` is undescribed: without the override both explicit refs abort.
      final GitPushResult refused = await repo.gitPush(named: const ['x=@'], changes: const ['@'], dryRun: true).result;
      expect(refused.failure?.kind, PushFailureKind.commitRejected);
      expect(refused.remotes.single.refs.map((r) => r.path), contains(PushPath.abort));

      final GitPushResult plan = await repo
          .gitPush(
            named: const ['x=@'],
            changes: const ['@'],
            allowEmptyDescription: true,
            dryRun: true,
          )
          .result;

      expect(plan.failure, isNull);
      final List<PushRef> refs = plan.remotes.single.refs;
      expect(refs, hasLength(2));
      expect(refs.map((r) => r.path), everyElement(PushPath.push));
      // Only `--change` reports "Creating bookmark" (`create_change_bookmarks`).
      final String created = plan.createdBookmarks.single.name;
      expect(created, startsWith('push-'));
      expect(refs.map((r) => r.name), unorderedEquals(['x', created]));
    });

    test('revisions select the bookmarks they carry', () async {
      await addRemote();
      final String at = (await repo.status()).workingCopyChangeId;
      await repo.describe(changeId: at, description: 'A\n');
      await repo.bookmarkCreate(const ['main']);

      final GitPushResult plan = await repo.gitPush(revisions: const ['@'], dryRun: true).result;
      final GitPushResult none = await repo.gitPush(revisions: const ['root()'], dryRun: true).result;

      // `-r` never creates a remote bookmark (`allow_new = false`): skipped, warned.
      final PushRef main = plan.remotes.single.refs.single;
      expect(main.name, 'main');
      expect(main.path, PushPath.skip);
      expect(main.refusal?.message, contains('Refusing to create new remote bookmark main@origin'));
      // A bare push would select `main` too; `root()` carries no bookmark.
      expect(none.nothingChanged, isTrue);
      expect(none.remotes.expand((r) => r.refs), isEmpty);
    });

    test('a dry run plans the push without touching the network', () async {
      await addRemote();
      File('${tempDir.path}/a.txt').writeAsStringSync('a\n');
      final String at = (await repo.status()).workingCopyChangeId;
      await repo.describe(changeId: at, description: 'A\n');
      await repo.bookmarkCreate(const ['main']);

      final GitPushResult plan = await repo.gitPush(bookmarks: const ['main'], dryRun: true).result;

      expect(plan.dryRun, isTrue);
      expect(plan.recorded, isFalse);
      expect(plan.failure, isNull);
      final PushRemote origin = plan.remotes.single;
      expect(origin.name, 'origin');
      expect(origin.finished, isFalse);
      final PushRef main = origin.refs.single;
      expect(main.kind, PushRefKind.bookmark);
      expect(main.name, 'main');
      expect(main.path, PushPath.push);
      expect(main.before, isNull);
      expect(main.after, isNotNull);
      expect(main.action, startsWith('add to '));
      expect(main.status, PushRefStatus.notReached);
      expect(plan.description, contains('main'));
    });

    test('a closed handle throws synchronously', () async {
      final RepoHandle other = await worker.initRepo('${tempDir.path}/other', backend: 1, noColocate: true);
      await other.close();
      expect(other.gitPush, throwsStateError);
    });
  });
}
