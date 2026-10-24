// SPDX-License-Identifier: MIT

// Story 9.52 witnesses: the network verbs run on a helper isolate and return a
// `NetworkOperation` — live progress, per-handle serialization, Cancel — driven
// through the REAL Isolate.spawn flow against the REAL compiled cdylib.
//
// A slow `git` is a wrapper script set as the repo's `git.executable-path` through
// the REPO-scope config verb (never the shared user config: the XDG dir is one per
// suite). It runs the real `git` from PATH, then holds its pipes open, so the verb
// is still running when the test acts.
//
// The Dart VM reaps its child processes, so jj-lib's `Child::wait()` on a git that
// exited on its own fails inside `dart test` ("Failed to wait for the git
// process", deferred-work.md). The witnesses below do not depend on that wait:
// a cancelled call maps any git failure to the cancel, and the clone accepts the
// reaping outcome.
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/ffi/fetch.dart' show NamedFetchRemotes, PatternFetchRefs;
import 'package:zanshin_core/src/ffi/push.dart';
import 'package:zanshin_core/src/worker/events.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/network_operation.dart';
import 'package:zanshin_core/src/worker/responses.dart';

Matcher ffiError(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));

const ConfigTarget repoScope = ConfigScopeTarget(ConfigScope.repo);

/// Fetches go to the real git, then the wrapper holds git's pipes for 30 s.
const slowAfterGit = r'"$GIT" "$@"; s=$?; sleep 30; exit $s';

Future<void> git(List<String> args, String dir) async {
  final ProcessResult result = await Process.run('git', ['-C', dir, ...args]);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

void main() {
  group('Story 9.52 network operations (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late String bare;
    late String source;

    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_network_test_');
      source = '${tempDir.resolveSymbolicLinksSync()}/src';
      Directory(source).createSync();
      await git(['init', '-b', 'main'], source);
      await git(['config', 'user.email', 'test@test.invalid'], source);
      await git(['config', 'user.name', 'Test'], source);
      for (var i = 0; i < 3; i++) {
        File('$source/file$i.txt').writeAsStringSync('content $i\n' * 200);
        await git(['add', '.'], source);
        await git(['commit', '-m', 'commit $i', '--no-gpg-sign'], source);
      }
      bare = '${tempDir.resolveSymbolicLinksSync()}/remote.git';
      await git(['clone', '--bare', source, bare], tempDir.path);
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// A git-backed jj workspace at `<temp>/<name>` with `origin` = the bare remote.
    Future<RepoHandle> repoWithOrigin(String name) async {
      final root = '${tempDir.resolveSymbolicLinksSync()}/$name';
      final RepoHandle repo = await worker.initRepo(root, backend: 1, noColocate: true);
      await repo.gitRemoteAdd(name: 'origin', url: bare);
      return repo;
    }

    /// Sets the repo's `git.executable-path` to a wrapper running [body]; `$GIT` is
    /// the real git.
    Future<void> slowGit(String name, String body) async {
      final root = '${tempDir.resolveSymbolicLinksSync()}/$name';
      final String realGit = (Process.runSync('/bin/sh', ['-c', 'command -v git']).stdout as String).trim();
      final wrapper = File('${tempDir.path}/slow-git-$name')..writeAsStringSync("#!/bin/sh\nGIT='$realGit'\n$body\n");
      Process.runSync('chmod', ['755', wrapper.path]);
      await worker.configSet(repoScope, 'git.executable-path', wrapper.path, workspaceRoot: root);
    }

    Future<String> headOp(RepoHandle repo) async => (await repo.opLog(limit: 1)).single.id;

    test('a fetch reports progress while it runs, and its cancel refuses with nothing imported', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      await slowGit('a', slowAfterGit);
      final String before = await headOp(repo);

      final NetworkOperation<Object?> fetch = repo.gitFetch();
      var resultDone = false;
      unawaited(fetch.result.then((_) => resultDone = true, onError: (Object _) => resultDone = true));
      final ProgressEvent first = await fetch.progress.first.timeout(const Duration(seconds: 20));

      expect(resultDone, isFalse, reason: 'progress arrives while the fetch still runs');
      expect(first.handleId, repo.handleId);
      expect(first.operation, 'fetch');
      final stopwatch = Stopwatch()..start();
      await fetch.cancel();
      await expectLater(fetch.result, ffiError('jj.cancelled'));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)), reason: 'the cancel killed the slow git');
      expect(await headOp(repo), before, reason: 'a cancelled fetch imports nothing');
      await fetch.cancel();
    });

    test('a call on another repo does not wait for a fetch; one on the same repo does', () async {
      final RepoHandle a = await repoWithOrigin('a');
      final RepoHandle b = await worker.initRepo('${tempDir.resolveSymbolicLinksSync()}/b', backend: 1);
      await slowGit('a', slowAfterGit);

      final order = <String>[];
      final NetworkOperation<Object?> fetch = a.gitFetch();
      final Future<void> fetched = fetch.result.then(
        (_) => order.add('fetch'),
        onError: (Object _) => order.add('fetch'),
      );
      await fetch.progress.first.timeout(const Duration(seconds: 20));
      final Future<void> sameRepo = a.status().then((_) => order.add('status a'));
      await b.status().then((_) => order.add('status b'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(order, ['status b'], reason: 'the other repo answered; the same repo waits for the fetch');

      await fetch.cancel();
      await Future.wait([fetched, sameRepo]);
      expect(order, ['status b', 'fetch', 'status a']);
    });

    test('closing the worker during a fetch cancels it and a queued one, and acks within its window', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      await slowGit('a', slowAfterGit);
      final NetworkOperation<Object?> fetch = repo.gitFetch();
      final Future<Object?> outcome = fetch.result.then<Object?>((value) => value, onError: (Object e) => e);
      await fetch.progress.first.timeout(const Duration(seconds: 20));
      final NetworkOperation<Object?> queued = repo.gitFetch();
      final Future<Object?> queuedOutcome = queued.result.then<Object?>((value) => value, onError: (Object e) => e);
      final Future<void> closed = repo.close();

      final stopwatch = Stopwatch()..start();
      await worker.close();
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 5)), reason: 'acked, not killed by the backstop');
      final TypeMatcher<ZanshinFfiException> cancelled = isA<ZanshinFfiException>().having(
        (e) => e.code,
        'code',
        'jj.cancelled',
      );
      expect(await outcome, cancelled, reason: 'the shutdown cancelled the fetch before it closed the session');
      expect(await queuedOutcome, cancelled, reason: 'the queued fetch started cancelled');
      await closed.catchError((Object _) {});
      await fetch.cancel();
    });

    test('a fetch queued behind another on the same handle takes none of its events', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      await slowGit('a', slowAfterGit);
      final NetworkOperation<Object?> first = repo.gitFetch();
      final NetworkOperation<Object?> second = repo.gitFetch();
      var firstDone = false;
      final Future<void> firstSettled = first.result.then(
        (_) => firstDone = true,
        onError: (Object _) => firstDone = true,
      );
      final secondEvents = <bool>[];
      second.progress.listen((_) => secondEvents.add(firstDone));

      await first.progress.first.timeout(const Duration(seconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(secondEvents, isEmpty, reason: 'the queued fetch has not started');
      await first.cancel();
      await firstSettled;
      // The second fetch runs now (its git finds nothing new, so it may report nothing).
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(secondEvents, everyElement(isTrue), reason: 'none of the first fetch\'s events are its own');
      await second.cancel();
      await expectLater(second.result, ffiError('jj.cancelled'));
    });

    test('a fetch queued behind another and cancelled starts cancelled', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      await slowGit('a', slowAfterGit);
      final NetworkOperation<Object?> first = repo.gitFetch();
      await first.progress.first.timeout(const Duration(seconds: 20));
      final NetworkOperation<Object?> queued = repo.gitFetch();
      await queued.cancel();
      await first.cancel();
      await expectLater(first.result, ffiError('jj.cancelled'));
      await expectLater(queued.result, ffiError('jj.cancelled'));
    });

    test('a remote-change poll queued behind a fetch and cancelled starts cancelled (Story 9.24)', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      await slowGit('a', slowAfterGit);
      final NetworkOperation<Object?> fetch = repo.gitFetch();
      await fetch.progress.first.timeout(const Duration(seconds: 20));
      final NetworkOperation<Object?> queued = repo.remoteChanges('origin');
      await queued.cancel();
      await fetch.cancel();
      await expectLater(fetch.result, ffiError('jj.cancelled'));
      await expectLater(queued.result, ffiError('jj.cancelled'));
    });

    test('a remote-change poll cancelled while its git runs is killed and refuses (Story 9.24)', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      final marker = File('${tempDir.path}/listed');
      // ls-remote sends no progress: the wrapper's marker says git is running.
      await slowGit('a', '"\$GIT" "\$@"; s=\$?; touch \'${marker.path}\'; sleep 30; exit \$s');
      final NetworkOperation<Object?> poll = repo.remoteChanges('origin');
      final DateTime deadline = DateTime.now().add(const Duration(seconds: 20));
      while (!marker.existsSync() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(marker.existsSync(), isTrue, reason: 'the poll reached git');
      final stopwatch = Stopwatch()..start();
      await poll.cancel();
      await expectLater(poll.result, ffiError('jj.cancelled'));
      expect(stopwatch.elapsed, lessThan(const Duration(seconds: 10)), reason: 'the cancel killed the slow git');
    });

    test('a network call whose helper throws answers internal.dispatch_error and frees its handle', () async {
      final RepoHandle repo = await worker.initRepo('${tempDir.path}/plain', backend: 1, noColocate: true);
      // The interior NUL is refused inside the helper isolate (the FFI adapter's guard).
      await expectLater(
        repo.gitFetch(remotes: const NamedFetchRemotes(['a\u0000b'])).result,
        ffiError('internal.dispatch_error'),
      );
      await repo.status();
    });

    test('a fetch carries its refs through the worker to the helper', () async {
      final RepoHandle repo = await worker.initRepo('${tempDir.path}/plain', backend: 1, noColocate: true);
      // Only the branch pattern holds the NUL: a dropped `refs` would reach Rust and refuse
      // `jj.invalid_input` (the repo has no remote) instead of the helper's guard.
      await expectLater(
        repo.gitFetch(refs: const PatternFetchRefs(branches: ['a\u0000b'])).result,
        ffiError('internal.dispatch_error'),
      );
      await repo.status();
    });

    test('a push queued behind a fetch and cancelled starts cancelled and reports it as data', () async {
      final RepoHandle repo = await repoWithOrigin('a');
      final String at = (await repo.status()).workingCopyChangeId!;
      await repo.describe(changeId: at, description: 'A\n');
      await repo.bookmarkCreate(const ['main']);
      await slowGit('a', slowAfterGit);

      final NetworkOperation<Object?> fetch = repo.gitFetch();
      await fetch.progress.first.timeout(const Duration(seconds: 20));
      final NetworkOperation<GitPushResult> push = repo.gitPush(bookmarks: const ['main']);
      await push.cancel();
      await fetch.cancel();
      await expectLater(fetch.result, ffiError('jj.cancelled'));

      final GitPushResult result = await push.result;
      expect(result.failure?.kind, PushFailureKind.cancelled);
      expect(result.failure?.message, 'Cancelled');
      expect(result.recorded, isFalse);
      expect(result.remotes.single.finished, isFalse, reason: 'no git push ran');
    });

    test('a clone reports progress under the handle it gets before its result', () async {
      final events = <ProgressEvent>[];
      var resultDone = false;
      final NetworkOperation<CreatedRepoHandle> clone = worker.cloneRepo(
        source: 'file://$source',
        destination: '${tempDir.path}/cloned',
        noColocate: true,
      );
      final StreamSubscription<ProgressEvent> listening = clone.progress.listen((event) {
        expect(resultDone, isFalse, reason: 'progress arrives before the result');
        events.add(event);
      });
      Object? outcome;
      try {
        outcome = await clone.result;
      } on ZanshinFfiException catch (e) {
        // The VM's child reaping can fail jj-lib's wait on a git that exited
        // on its own (see the file comment).
        outcome = e;
      }
      resultDone = true;
      await listening.cancel();

      expect(events, isNotEmpty, reason: 'a local clone reports progress while it runs');
      expect(events.map((e) => e.operation), everyElement('clone'));
      expect(events.map((e) => e.handleId).toSet(), hasLength(1));
      switch (outcome) {
        case final CreatedRepoHandle handle:
          expect(events.first.handleId, handle.handleId, reason: 'the reserved handle id is the clone handle');
          await handle.close();
        case ZanshinFfiException(:final String code):
          expect(code, 'jj.network_error');
        default:
          fail('unexpected clone outcome $outcome');
      }
    });

    test('a clone cancelled right after it starts refuses and leaves no folder', () async {
      final destination = '${tempDir.path}/cancelled';
      final NetworkOperation<CreatedRepoHandle> clone = worker.cloneRepo(
        source: 'file://$source',
        destination: destination,
        noColocate: true,
      );
      await clone.cancel();
      await expectLater(clone.result, ffiError('jj.cancelled'));
      expect(Directory(destination).existsSync(), isFalse, reason: 'the folder the clone created is gone');
    });

    test('a cancel after the call completed, or after the worker closed, is a no-op', () async {
      final RepoHandle repo = await worker.initRepo('${tempDir.path}/plain', backend: 1, noColocate: true);
      final NetworkOperation<Object?> fetch = repo.gitFetch(remotes: const NamedFetchRemotes(['nonexistent']));
      await expectLater(fetch.result, ffiError('jj.invalid_input'));
      await fetch.cancel();
      await expectLater(fetch.progress.toList(), completion(isEmpty), reason: 'progress closed with the result');

      final NetworkOperation<GitPushResult> push = repo.gitPush(remotes: const []);
      await expectLater(push.result, ffiError('jj.invalid_input'));
      final RepoHandle other = await worker.initRepo('${tempDir.path}/other', backend: 1, noColocate: true);
      await other.close();
      expect(other.gitFetch, throwsStateError, reason: 'the closed-handle guard stays synchronous');
      await worker.close();
      await push.cancel();
      await expectLater(repo.gitFetch().result, throwsStateError, reason: 'a closed worker fails the result');
    });
  });
}
