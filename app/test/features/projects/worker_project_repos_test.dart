// SPDX-License-Identifier: MIT

// The adapter against the REAL worker isolate and cdylib (project-context "Worker / isolate testing"): temp
// repositories made with the native backend; JJ_CONFIG, GIT_CONFIG_GLOBAL and XDG_CONFIG_HOME are pinned by
// Makefile.toml's test-flutter. The tracking tests (Story 9.29) write repo-scope jj config, which jj keeps under
// XDG_CONFIG_HOME, so they fail before any write when it is not pinned.

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

TopologyRef _ref(String name, {String? remote, TopologyRefKind kind = TopologyRefKind.bookmark}) =>
    TopologyRef(node: 0, kind: kind, name: name, remote: remote, synced: true, conflicted: false);

Bookmark _local(String name) =>
    Bookmark(name: name, target: 'k', kind: const LocalBookmark(), conflicted: false, synced: true);

/// A remote row the bookmark was never pushed to: tracked, no target (the CLI's `(not created yet)`).
Bookmark _notCreatedYet(String name, {String remote = 'origin', bool tracked = true}) => Bookmark(
  name: name,
  target: null,
  kind: RemoteBookmark(remote, tracked: tracked),
  conflicted: false,
  synced: false,
);

Bookmark _remote(String name, {required int ahead, required int behind, String remote = 'origin'}) => Bookmark(
  name: name,
  target: 'k',
  kind: RemoteBookmark(
    remote,
    tracked: true,
    ahead: RefDistance(lower: ahead, upper: ahead),
    behind: RefDistance(lower: behind, upper: behind),
  ),
  conflicted: false,
  synced: ahead == 0 && behind == 0,
);

/// [trackingStatusOf] with `origin` as the only push target unless [pushRemotes] says otherwise (Story 9.54).
ProjectStatus? _tracking(
  Iterable<TopologyRef> headRefs,
  Iterable<Bookmark> bookmarks, {
  Set<String> pushRemotes = const {'origin'},
}) => trackingStatusOf(headRefs, bookmarks, pushRemotes: pushRemotes);

void main() {
  group('helpers', () {
    test('the dot: conflict before dirty before clean', () {
      expect(statusOf(conflict: ConflictState.conflicted, hasFileChanges: true), ProjectStatus.conflict);
      expect(statusOf(conflict: ConflictState.conflicted, hasFileChanges: false), ProjectStatus.conflict);
      expect(statusOf(conflict: ConflictState.clean, hasFileChanges: true), ProjectStatus.dirty);
      expect(statusOf(conflict: ConflictState.clean, hasFileChanges: false), ProjectStatus.clean);
    });

    test('the dot: dirty beats the tracking state, which beats clean', () {
      expect(
        statusOf(conflict: ConflictState.clean, hasFileChanges: true, tracking: ProjectStatus.diverged),
        ProjectStatus.dirty,
      );
      expect(
        statusOf(conflict: ConflictState.conflicted, hasFileChanges: false, tracking: ProjectStatus.ahead),
        ProjectStatus.conflict,
      );
      expect(
        statusOf(conflict: ConflictState.clean, hasFileChanges: false, tracking: ProjectStatus.behind),
        ProjectStatus.behind,
      );
    });

    group('the tracking state (Story 9.29)', () {
      final heads = <TopologyRef>[_ref('main'), _ref('main', remote: 'origin')];

      test('no remote rows, or only synced ones: none', () {
        expect(_tracking(heads, <Bookmark>[_local('main')]), isNull);
        expect(_tracking(heads, <Bookmark>[_local('main'), _remote('main', ahead: 0, behind: 0)]), isNull);
      });

      test("a remote row's behind is the local side ahead; its ahead is the local side behind", () {
        expect(_tracking(heads, <Bookmark>[_remote('main', ahead: 0, behind: 2)]), ProjectStatus.ahead);
        expect(_tracking(heads, <Bookmark>[_remote('main', ahead: 3, behind: 0)]), ProjectStatus.behind);
      });

      test('both on one row, or split across two rows: diverged', () {
        expect(_tracking(heads, <Bookmark>[_remote('main', ahead: 1, behind: 1)]), ProjectStatus.diverged);
        expect(
          _tracking(heads, <Bookmark>[
            _remote('main', ahead: 1, behind: 0),
            _remote('main', remote: 'upstream', ahead: 0, behind: 1),
          ]),
          ProjectStatus.diverged,
        );
        final twoNames = <TopologyRef>[_ref('main'), _ref('next')];
        expect(
          _tracking(twoNames, <Bookmark>[
            _remote('main', ahead: 1, behind: 0),
            _remote('next', ahead: 0, behind: 2),
          ]),
          ProjectStatus.diverged,
        );
      });

      test('an open upper bound still counts by its lower bound', () {
        const atLeastTen = RemoteBookmark(
          'origin',
          tracked: true,
          ahead: RefDistance(lower: 10),
          behind: RefDistance(lower: 0, upper: 0),
        );
        expect(
          _tracking(heads, const <Bookmark>[
            Bookmark(name: 'main', target: 'k', kind: atLeastTen, conflicted: false, synced: false),
          ]),
          ProjectStatus.behind,
        );
      });

      test('the git remote, untracked rows and targeted rows without distances never count', () {
        expect(_tracking(heads, <Bookmark>[_remote('main', remote: 'git', ahead: 1, behind: 1)]), isNull);
        expect(_tracking(heads, <Bookmark>[_notCreatedYet('main', remote: 'git')]), isNull);
        expect(_tracking(heads, <Bookmark>[_notCreatedYet('main', tracked: false)]), isNull);
        expect(
          _tracking(heads, const <Bookmark>[
            Bookmark(
              name: 'main',
              target: 'k',
              kind: RemoteBookmark('origin', tracked: false),
              conflicted: false,
              synced: false,
            ),
            Bookmark(
              name: 'main',
              target: 'k',
              kind: RemoteBookmark('upstream', tracked: true),
              conflicted: false,
              synced: false,
            ),
          ]),
          isNull,
        );
      });

      test('a push-target remote the bookmark was never pushed to reads ahead (Stories 9.53, 9.54)', () {
        expect(_tracking(heads, <Bookmark>[_notCreatedYet('main')]), ProjectStatus.ahead);
        expect(
          _tracking(heads, <Bookmark>[_notCreatedYet('main', remote: 'upstream')], pushRemotes: {'upstream'}),
          ProjectStatus.ahead,
        );
        expect(
          _tracking(heads, <Bookmark>[
            _notCreatedYet('main'),
            _remote('main', ahead: 1, behind: 0),
          ]),
          ProjectStatus.diverged,
        );
        expect(_tracking(heads, <Bookmark>[_notCreatedYet('other')]), isNull);
      });

      test('a remote that is no push target never reads ahead for a missing bookmark (Story 9.54)', () {
        expect(_tracking(heads, <Bookmark>[_notCreatedYet('main', remote: 'upstream')]), isNull);
        expect(_tracking(heads, <Bookmark>[_notCreatedYet('main')], pushRemotes: const {}), isNull);
        expect(
          _tracking(heads, <Bookmark>[
            _notCreatedYet('main', remote: 'upstream'),
            _remote('main', ahead: 1, behind: 0),
          ]),
          ProjectStatus.behind,
        );
        expect(
          _tracking(heads, <Bookmark>[_remote('main', remote: 'upstream', ahead: 0, behind: 2)]),
          ProjectStatus.ahead,
          reason: 'the distances count for every tracked remote',
        );
      });

      test('only local bookmark names on the heads count: remote-only refs and other names are ignored', () {
        expect(
          _tracking(
            <TopologyRef>[_ref('main', remote: 'origin')],
            <Bookmark>[_remote('main', ahead: 1, behind: 1)],
          ),
          isNull,
        );
        expect(_tracking(heads, <Bookmark>[_remote('other', ahead: 1, behind: 1)]), isNull);
        expect(
          _tracking(
            <TopologyRef>[_ref('main', kind: TopologyRefKind.tag)],
            <Bookmark>[
              _remote('main', ahead: 1, behind: 1),
            ],
          ),
          isNull,
        );
      });
    });

    group('statusFrom: what read() composes', () {
      final heads = <TopologyRef>[_ref('main')];
      Future<ProjectStatus> clean(List<Bookmark> rows, {List<String> pushRemotes = const ['origin']}) => statusFrom(
        conflict: ConflictState.clean,
        hasFileChanges: false,
        headRefs: heads,
        bookmarks: () async => rows,
        pushRemotes: () async => pushRemotes,
      );

      test('a clean @ takes the tracking state of its bookmarks, else clean', () async {
        expect(await clean(<Bookmark>[_remote('main', ahead: 1, behind: 1)]), ProjectStatus.diverged);
        expect(await clean(<Bookmark>[_remote('main', ahead: 0, behind: 1)]), ProjectStatus.ahead);
        expect(await clean(<Bookmark>[_remote('main', ahead: 1, behind: 0)]), ProjectStatus.behind);
        expect(await clean(<Bookmark>[_local('main')]), ProjectStatus.clean);
        expect(await clean(<Bookmark>[_local('main'), _notCreatedYet('main')]), ProjectStatus.ahead);
      });

      test('only a push target makes a missing remote bookmark ahead (Story 9.54)', () async {
        final rows = <Bookmark>[_local('main'), _notCreatedYet('main', remote: 'upstream')];
        expect(await clean(rows), ProjectStatus.clean);
        expect(await clean(rows, pushRemotes: const ['upstream']), ProjectStatus.ahead);
      });

      test('a conflicted or dirty @ never reads the bookmarks or the push remotes', () async {
        Future<Iterable<Bookmark>> unread() => fail('bookmarks must not be read');
        Future<Iterable<String>> unreadRemotes() => fail('push remotes must not be read');
        expect(
          await statusFrom(
            conflict: ConflictState.conflicted,
            hasFileChanges: false,
            headRefs: heads,
            bookmarks: unread,
            pushRemotes: unreadRemotes,
          ),
          ProjectStatus.conflict,
        );
        expect(
          await statusFrom(
            conflict: ConflictState.clean,
            hasFileChanges: true,
            headRefs: heads,
            bookmarks: unread,
            pushRemotes: unreadRemotes,
          ),
          ProjectStatus.dirty,
        );
      });
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

    // Story 9.29. A TRACKED non-`git` remote needs a fetch, a clone or `remotes.<name>.auto-track-bookmarks`: the first
    // two cannot run under a Dart test (the VM reaps jj-lib's git child, zanshin_core's mutate_test.dart `gitFetch`
    // note), so the tracking tests below set the third. Here the read runs over remote rows that must NOT count — the
    // colocated `@git` row and an untracked `main@origin` the local `main` is ahead of.
    /// Runs `git -C [path]` and returns its trimmed stdout.
    Future<String> Function(List<String>) gitAt(String path) => (args) async {
      final ProcessResult result = await Process.run('git', <String>['-C', path, ...args]);
      if (result.exitCode != 0) {
        fail('git ${args.join(' ')} failed: ${result.stderr}');
      }
      return (result.stdout as String).trim();
    };

    test('the read over an untracked remote and the @git row stays clean', () async {
      final path = '${temp.resolveSymbolicLinksSync()}/remotes';
      await Directory(path).create();
      await gitWithCommit(path);
      final Future<String> Function(List<String>) git = gitAt(path);

      await git(<String>['update-ref', 'refs/remotes/origin/main', 'HEAD']);
      File('$path/second.txt').writeAsStringSync('second');
      await git(<String>['add', '.']);
      await git(<String>['commit', '-m', 'second', '--no-gpg-sign']);

      final ProjectCreation creation = await repos.convert(path);
      addTearDown(creation.repo.close);
      final List<Bookmark> bookmarks = await creation.repo.handle.bookmarks(allRemotes: true);
      expect(
        <(String, String?, bool)>[
          for (final b in bookmarks)
            switch (b.kind) {
              LocalBookmark() => (b.name, null, b.synced),
              RemoteBookmark(:final String remoteName, :final bool tracked) => (b.name, remoteName, tracked),
            },
        ],
        <(String, String?, bool)>[('main', null, true), ('main', 'git', true), ('main', 'origin', false)],
      );

      expect(await creation.repo.read(), const ProjectReading(status: ProjectStatus.clean, bookmark: 'main'));
    });

    /// Story 9.29's tracked start: a Git repository with A0 → A on `main`, converted, and `main@origin` at A tracked
    /// through repo-scope `remotes.origin.auto-track-bookmarks` (zanshin_core's test/worker/bookmarks_test.dart recipe);
    /// the git remote-tracking ref is imported by the next verb's precondition.
    Future<(ProjectRepo, Future<String> Function(List<String>))> trackedMain(String name) async {
      // The repo-scope write lands in jj's secure store under XDG_CONFIG_HOME, so it must be the gate's throwaway dir
      // (Makefile.toml test-flutter), never the developer's own config.
      final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
      if (xdg == null || !xdg.endsWith('/target/test-xdg-config')) {
        fail('XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make');
      }
      final path = '${temp.resolveSymbolicLinksSync()}/$name';
      await Directory(path).create();
      await gitWithCommit(path);
      final Future<String> Function(List<String>) git = gitAt(path);
      File('$path/second.txt').writeAsStringSync('second');
      await git(<String>['add', '.']);
      await git(<String>['commit', '-m', 'second', '--no-gpg-sign']);

      final ProjectCreation creation = await repos.convert(path);
      addTearDown(creation.repo.close);
      await worker.configSet(
        const ConfigScopeTarget(ConfigScope.repo),
        'remotes.origin.auto-track-bookmarks',
        'glob:*',
        workspaceRoot: path,
      );
      await git(<String>['update-ref', 'refs/remotes/origin/main', 'HEAD']);

      final Bookmark origin = (await creation.repo.handle.bookmarks(allRemotes: true)).singleWhere(
        (b) => switch (b.kind) {
          RemoteBookmark(remoteName: 'origin') => true,
          _ => false,
        },
      );
      expect(((origin.kind as RemoteBookmark).tracked, origin.synced), (true, true));
      expect(await creation.repo.read(), const ProjectReading(status: ProjectStatus.clean, bookmark: 'main'));
      return (creation.repo, git);
    }

    /// Moves the local `main` to the commit [rev] names on the git side (imported by the next verb as the local bookmark, while
    /// `main@origin` stays at A) and starts a new @ on it. A tracked import would resync an unmoved local `main`, so the
    /// local side moves. Git HEAD follows `main` after `convert`, so the import also moves @ onto [rev] with the old
    /// files still on disk; the new change checks out that commit's tree, which leaves @ empty with `main` on its
    /// ancestry.
    Future<void> moveLocalMain(ProjectRepo repo, Future<String> Function(List<String>) git, String rev) async {
      await git(<String>['update-ref', 'refs/heads/main', rev]);
      final String main = (await repo.handle.bookmarks(allRemotes: true))
          .singleWhere((b) => b.kind is LocalBookmark)
          .target!;
      await repo.handle.newChange(<String>[main]);
    }

    /// A new commit with A's tree on [parent].
    Future<String> commitOn(Future<String> Function(List<String>) git, String parent) => git(<String>[
      'commit-tree',
      'refs/remotes/origin/main^{tree}',
      '-p',
      parent,
      '-m',
      'moved',
      '--no-gpg-sign',
    ]);

    // Not a `describe` of A: jj's default `trunk()` is `main@origin`, so A is immutable and the rewrite is refused
    // (jj.immutable), as by the CLI. A sibling of A gives the same two-sided distance.
    test('a local main moved to a sibling of the tracked commit reads diverged', () async {
      final (ProjectRepo repo, Future<String> Function(List<String>) git) = await trackedMain('diverged');

      await moveLocalMain(repo, git, await commitOn(git, 'refs/remotes/origin/main~1'));

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.diverged, bookmark: 'main'));
    });

    test('a local main moved to a child of the tracked commit reads ahead', () async {
      final (ProjectRepo repo, Future<String> Function(List<String>) git) = await trackedMain('ahead');

      await moveLocalMain(repo, git, await commitOn(git, 'refs/remotes/origin/main'));

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.ahead, bookmark: 'main'));
    });

    test('a local main moved back to the parent of the tracked commit reads behind', () async {
      final (ProjectRepo repo, Future<String> Function(List<String>) git) = await trackedMain('behind');

      await moveLocalMain(repo, git, 'refs/remotes/origin/main~1');

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.behind, bookmark: 'main'));
    });

    /// Story 9.54's closing run: a Git-backed workspace with remotes `origin` and `upstream` (so `origin` is the default
    /// push target, `RepoHandle.gitPushRemotes`), repo-scope `remotes.<[autoTrackOn]>.auto-track-created-bookmarks`, and
    /// `feature` created on a commit with a file, under a new empty @. `bookmark create` auto-tracks it on
    /// [autoTrackOn] as a target-less row — the CLI's `(not created yet)`.
    Future<ProjectRepo> autoTrackedFeature(String name, String autoTrackOn) async {
      // The repo-scope write lands in jj's secure store under XDG_CONFIG_HOME, so it must be the gate's throwaway dir
      // (Makefile.toml test-flutter), never the developer's own config.
      final String? xdg = Platform.environment['XDG_CONFIG_HOME'];
      if (xdg == null || !xdg.endsWith('/target/test-xdg-config')) {
        fail('XDG_CONFIG_HOME is not pinned to target/test-xdg-config — run via cargo make');
      }
      final path = '${temp.resolveSymbolicLinksSync()}/$name';
      await Directory(path).create();
      final ProjectCreation creation = await repos.init(path);
      addTearDown(creation.repo.close);
      final RepoHandle handle = creation.repo.handle;
      for (final remote in <String>['origin', 'upstream']) {
        await handle.gitRemoteAdd(name: remote, url: '${temp.path}/$remote.git');
      }
      await worker.configSet(
        const ConfigScopeTarget(ConfigScope.repo),
        'remotes.$autoTrackOn.auto-track-created-bookmarks',
        '"*"',
        workspaceRoot: path,
      );
      File('$path/a.txt').writeAsStringSync('a\n');
      final WorkingCopyStatus first = await handle.status();
      await handle.bookmarkCreate(<String>['feature'], revision: first.workingCopyChangeId);
      await handle.newChange(<String>[first.workingCopyChangeId]);

      final remoteRows = <(String, String, bool, String?)>[
        for (final b in await handle.bookmarks(allRemotes: true))
          if (b.kind case RemoteBookmark(:final String remoteName, :final bool tracked))
            (b.name, remoteName, tracked, b.target),
      ];
      expect(remoteRows, <(String, String, bool, String?)>[('feature', autoTrackOn, true, null)]);
      return creation.repo;
    }

    test('a bookmark auto-tracked on the default push target but never pushed reads ahead', () async {
      final ProjectRepo repo = await autoTrackedFeature('auto-track-origin', 'origin');

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.ahead, bookmark: 'feature'));
    });

    test('a bookmark auto-tracked only on a remote that is not a push target reads clean', () async {
      final ProjectRepo repo = await autoTrackedFeature('auto-track-upstream', 'upstream');

      expect(await repo.read(), const ProjectReading(status: ProjectStatus.clean, bookmark: 'feature'));
    });

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

    // Story 9.20: a non-empty destination is refused before anything — and any git — runs.
    test('a clone into a non-empty target is refused with jj.destination_not_empty', () async {
      final destination = '${temp.path}/full';
      File('$destination/keep.txt').createSync(recursive: true);

      await expectLater(
        repos.clone(url: 'file:///nowhere', destination: destination),
        throwsA(isA<ZanshinFfiException>().having((error) => error.code, 'code', 'jj.destination_not_empty')),
      );
      expect(Directory('$destination/.jj').existsSync(), isFalse);
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
