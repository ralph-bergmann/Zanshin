// SPDX-License-Identifier: MIT

// The adapter against the REAL worker isolate and cdylib (project-context "Worker / isolate testing"): temp
// repositories made with the native backend; JJ_CONFIG and GIT_CONFIG_GLOBAL are pinned by Makefile.toml's
// test-flutter, and no test here calls a jj config verb.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

TopologyRef _ref(String name, {String? remote, TopologyRefKind kind = TopologyRefKind.bookmark}) =>
    TopologyRef(node: 0, kind: kind, name: name, remote: remote, synced: true, conflicted: false);

void main() {
  group('helpers', () {
    test('the dot: conflict before dirty before clean', () {
      expect(statusOf(conflict: ConflictState.conflicted, hasFileChanges: true), ProjectStatus.conflict);
      expect(statusOf(conflict: ConflictState.conflicted, hasFileChanges: false), ProjectStatus.conflict);
      expect(statusOf(conflict: ConflictState.clean, hasFileChanges: true), ProjectStatus.dirty);
      expect(statusOf(conflict: ConflictState.clean, hasFileChanges: false), ProjectStatus.clean);
    });

    test('the label: the first local bookmark by name; remote bookmarks and tags never count', () {
      expect(
        bookmarkLabel(<TopologyRef>[
          _ref('zeta'),
          _ref('main', remote: 'origin'),
          _ref('a-tag', kind: TopologyRefKind.tag),
          _ref('alpha'),
        ]),
        'alpha',
      );
      expect(
        bookmarkLabel(<TopologyRef>[_ref('main', remote: 'origin'), _ref('v1', kind: TopologyRefKind.tag)]),
        isNull,
      );
      expect(bookmarkLabel(const <TopologyRef>[]), isNull);
    });

    test('only jj.stale_working_copy is the stale state', () {
      expect(isStale(const ZanshinFfiException('jj.stale_working_copy', 'cause\nwc_op\nrepo_op')), isTrue);
      expect(isStale(const ZanshinFfiException('jj.jj_lib_error')), isFalse);
    });
  });

  group('WorkerProjectRepos (real worker)', () {
    late ZanshinWorker worker;
    late WorkerProjectRepos repos;
    late Directory temp;

    setUpAll(() async {
      worker = await ZanshinWorker.start();
      repos = WorkerProjectRepos(Future<ZanshinWorker>.value(worker));
    });

    tearDownAll(() => worker.close());

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('worker_project_repos_test');
    });

    tearDown(() => temp.delete(recursive: true));

    /// A new native-backend repository in a fresh folder, and a handle on it that is not the adapter's.
    Future<(String, RepoHandle)> initRepo(String name) async {
      final path = '${temp.resolveSymbolicLinksSync()}/$name';
      await Directory(path).create();
      final RepoHandle handle = await worker.initRepo(path, backend: 0);
      addTearDown(handle.close);
      return (path, handle);
    }

    test('detect passes through: a workspace is jj, a path that is gone is pathNotFound', () async {
      final (String path, _) = await initRepo('detect');

      expect((await repos.detect(path)).kind, RepoKind.jj);
      expect((await repos.detect('$path/gone')).kind, RepoKind.pathNotFound);
    });

    test('a working copy rewritten from a second workspace reads stale until it is updated', () async {
      // Story 9.23 (I3): a real stale working copy, made the way a user makes one — a second workspace,
      // created through `workspaceAdd`, restores its own `@` (which lacks f.txt) into this workspace's `@`.
      final (String path, RepoHandle a) = await initRepo('stale');
      File('$path/f.txt').writeAsStringSync('f\n');
      final WorkingCopyStatus status = await a.status();
      final WorkspaceAddResult added = await a.workspaceAdd(destination: '../stale-ws2');
      final RepoHandle b = await worker.openRepo(added.workspaceRoot);
      addTearDown(b.close);
      await b.restore(into: status.workingCopyChangeId);
      final ProjectRepo repo = await repos.open(path);
      addTearDown(repo.close);

      expect((await repo.read()).status, ProjectStatus.stale);

      expect((await a.workspaceUpdateStale()).outcome, StaleRecoveryOutcome.updated);
      expect((await repo.read()).status, isNot(ProjectStatus.stale));
    });

    test('an empty @ reads clean with no bookmark; a file edit reads dirty', () async {
      final (String path, _) = await initRepo('dirty');
      final ProjectRepo repo = await repos.open(path);
      addTearDown(repo.close);

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.clean));

      File('$path/a.txt').writeAsStringSync('a\n');
      expect(await repo.read(), const ProjectReading(status: ProjectStatus.dirty));
    });

    test('a conflicted merge @ reads conflict', () async {
      final (String path, RepoHandle handle) = await initRepo('conflict');
      // Two siblings off root write `c.txt` differently; the merge of both is @, conflicted there.
      File('$path/c.txt').writeAsStringSync('left\n');
      final WorkingCopyStatus left = await handle.status();
      await handle.newChange(<String>[left.parentChangeId]);
      File('$path/c.txt').writeAsStringSync('right\n');
      final WorkingCopyStatus right = await handle.status();
      await handle.newChange(<String>[left.workingCopyChangeId, right.workingCopyChangeId]);
      final ProjectRepo repo = await repos.open(path);
      addTearDown(repo.close);

      expect((await repo.read()).status, ProjectStatus.conflict);
    });

    test("the label is the first by name of the local bookmarks on @'s closest bookmarked ancestor", () async {
      final (String path, RepoHandle handle) = await initRepo('bookmark');
      File('$path/a.txt').writeAsStringSync('a\n');
      final WorkingCopyStatus first = await handle.status();
      await handle.bookmarkCreate(<String>['zeta', 'alpha'], revision: first.workingCopyChangeId);
      await handle.newChange(<String>[first.workingCopyChangeId]);
      final ProjectRepo repo = await repos.open(path);
      addTearDown(repo.close);

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.clean, bookmark: 'alpha'));
    });

    test('an operation by another handle raises changes; the repository closes its handle', () async {
      final (String path, RepoHandle other) = await initRepo('changes');
      final ProjectRepo repo = await repos.open(path);
      expect(repo.handle.handleId, isNot(other.handleId));
      final Future<void> changed = repo.changes.first.timeout(const Duration(seconds: 10));

      final WorkingCopyStatus status = await other.status();
      await other.newChange(<String>[status.workingCopyChangeId]);

      await changed;
      await repo.close();
      expect(repo.handle.status, throwsStateError);
    });

    test("a repository's changes carry only its own handle's operations", () async {
      final (String pathA, _) = await initRepo('a');
      final (String pathB, RepoHandle otherB) = await initRepo('b');
      final ProjectRepo repoA = await repos.open(pathA);
      final ProjectRepo repoB = await repos.open(pathB);
      addTearDown(repoA.close);
      addTearDown(repoB.close);
      var changesA = 0;
      final StreamSubscription<void> subscription = repoA.changes.listen((_) => changesA++);
      addTearDown(subscription.cancel);
      final Future<void> changedB = repoB.changes.first.timeout(const Duration(seconds: 10));

      final WorkingCopyStatus status = await otherB.status();
      await otherB.newChange(<String>[status.workingCopyChangeId]);

      // Both repositories' events arrive in order on the worker's one event stream.
      await changedB;
      expect(changesA, 0);
    });

    /// Makes [path] a Git repository with one commit on `main` (packages/zanshin_core/test/worker/creation_test.dart's
    /// recipe).
    Future<void> gitWithCommit(String path) async {
      Future<void> git(List<String> args) async {
        final ProcessResult result = await Process.run('git', <String>['-C', path, ...args]);
        if (result.exitCode != 0) {
          fail('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      await git(<String>['init', '-b', 'main']);
      await git(<String>['config', 'user.email', 'test@test.invalid']);
      await git(<String>['config', 'user.name', 'Test']);
      File('$path/README.md').writeAsStringSync('hello');
      await git(<String>['add', '.']);
      await git(<String>['commit', '-m', 'init', '--no-gpg-sign']);
    }

    test(
      'convert makes a Git repository a colocated workspace: a created handle, its warnings, .jj beside .git',
      () async {
        final path = '${temp.resolveSymbolicLinksSync()}/git';
        await Directory(path).create();
        await gitWithCommit(path);

        final ProjectCreation creation = await repos.convert(path);
        addTearDown(creation.repo.close);

        expect(creation.repo.handle, isA<CreatedRepoHandle>());
        expect(creation.warnings, (creation.repo.handle as CreatedRepoHandle).warnings);
        expect(Directory('$path/.jj').existsSync(), isTrue);
        expect(Directory('$path/.git').existsSync(), isTrue);
        expect((await creation.repo.read()).status, ProjectStatus.clean);
        expect((await repos.detect(path)).kind, RepoKind.jj);
      },
    );

    test('init creates a Git-backed workspace whose Git store stays inside .jj', () async {
      final path = '${temp.resolveSymbolicLinksSync()}/plain';
      await Directory(path).create();

      final ProjectCreation creation = await repos.init(path);
      addTearDown(creation.repo.close);

      expect(creation.warnings, isEmpty);
      expect(Directory('$path/.jj').existsSync(), isTrue);
      expect(Directory('$path/.git').existsSync(), isFalse);
      expect(File('$path/.jj/repo/store/type').readAsStringSync(), 'git');
      expect(await creation.repo.read(), const ProjectReading(status: ProjectStatus.clean));
    });

    test('a clone into a target that does not exist is refused with jj.jj_lib_error', () async {
      await expectLater(
        repos.clone(url: 'file:///nowhere', destination: '${temp.path}/missing'),
        throwsA(isA<ZanshinFfiException>().having((error) => error.code, 'code', 'jj.jj_lib_error')),
      );
    });

    test('a working-copy heartbeat is no change: only op-heads events count', () async {
      final (String path, _) = await initRepo('heartbeat');
      final ProjectRepo repo = await repos.open(path);
      addTearDown(repo.close);
      var changes = 0;
      final StreamSubscription<void> subscription = repo.changes.listen((_) => changes++);
      addTearDown(subscription.cancel);
      final Future<RepoEvent> heartbeat = worker.events
          .firstWhere((event) => event.handleId == repo.handle.handleId && event is WorkingCopyHeartbeatEvent)
          .timeout(const Duration(seconds: 10));

      // Re-write the checkout file (same bytes): a modify event on the heartbeat path only (the recipe of
      // packages/zanshin_core/test/worker/events_test.dart).
      final checkout = File('$path/.jj/working_copy/checkout');
      checkout.writeAsBytesSync(checkout.readAsBytesSync());

      await heartbeat;
      expect(changes, 0);
    });
  });
}
