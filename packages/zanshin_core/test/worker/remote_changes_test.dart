// SPDX-License-Identifier: MIT

// Story 9.24 witnesses: `RepoHandle.remoteChanges`, the `git ls-remote` poll,
// driven through the REAL Isolate.spawn flow against the REAL compiled cdylib.
//
// The workspace is a colocated jj init over a `git clone` of a local bare
// remote, so its view holds `main@origin` and `x@origin` without a jj fetch.
// Upstream changes are pushed from the source repo.
//
// The Dart VM reaps its child processes inside `dart test` (its resident
// frontend-server child keeps the VM's `wait()` loop running), so the poll's
// `Child::wait()` on a git that exited on its own fails with `jj.network_error:
// Failed to wait for the git process` — the same limit `network_operation_test`
// and `mutate_test` record for fetch and clone. The success rows therefore
// accept that one outcome and check the result whenever the wait wins; the
// moved/new/deleted diff itself is witnessed in Rust
// (`crates/zanshin-jj/tests/it/remote_changes.rs`,
// `crates/zanshin-ffi/tests/it/remote_changes_ffi.rs`) and the decoder by
// `test/ffi/remotes_test.dart`.
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/remotes.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/events.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/network_operation.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// The poll's result, or `null` when the VM's child reaping failed git's wait
/// (see the file comment) — the one failure the success rows accept.
Future<List<RemoteRefChange>?> resultOrReaped(NetworkOperation<WarnedList<RemoteRefChange>> poll) async {
  try {
    return await poll.result;
  } on ZanshinFfiException catch (e) {
    expect((e.code, e.context), ('jj.network_error', 'Failed to wait for the git process'));
    return null;
  }
}

Future<String> git(List<String> args, String dir) async {
  final ProcessResult result = await Process.run('git', ['-C', dir, ...args]);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

void main() {
  group('Story 9.24 remote-change poll (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late String source;
    late String bare;
    late String root;

    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_remote_changes_test_');
      final String base = tempDir.resolveSymbolicLinksSync();
      source = '$base/src';
      Directory(source).createSync();
      await git(['init', '-b', 'main'], source);
      await git(['config', 'user.email', 'test@test.invalid'], source);
      await git(['config', 'user.name', 'Test'], source);
      File('$source/README.md').writeAsStringSync('hello\n');
      await git(['add', '.'], source);
      await git(['commit', '-m', 'initial', '--no-gpg-sign'], source);
      await git(['branch', 'x'], source);
      bare = '$base/remote.git';
      await git(['clone', '--bare', source, bare], base);
      await git(['remote', 'add', 'origin', bare], source);
      root = '$base/ws';
      await git(['clone', bare, root], base);
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<RepoHandle> openRepo() => worker.initRepo(root, backend: 1, colocate: true);

    Future<String> commitUpstream(String file) async {
      File('$source/$file').writeAsStringSync('$file\n');
      await git(['add', '.'], source);
      await git(['commit', '-m', file, '--no-gpg-sign'], source);
      return git(['rev-parse', 'HEAD'], source);
    }

    test('nothing new right after the view learnt the remote; no progress events', () async {
      final RepoHandle repo = await openRepo();
      final NetworkOperation<WarnedList<RemoteRefChange>> poll = repo.remoteChanges('origin');
      final List<ProgressEvent> events = [];
      poll.progress.listen(events.add);
      final List<RemoteRefChange>? changes = await resultOrReaped(poll);
      if (changes != null) {
        expect(changes, isEmpty);
      }
      expect(events, isEmpty, reason: 'git sends no progress for ls-remote');
    });

    test('moved, created and deleted upstream refs; the op log is unchanged', () async {
      final RepoHandle repo = await openRepo();
      final String oldMain = await git(['rev-parse', 'main'], bare);
      final String newMain = await commitUpstream('second.txt');
      await git(['tag', '-a', 'v1', '-m', 'release'], source);
      await git(['push', 'origin', 'main', '--tags'], source);
      await git(['push', 'origin', '--delete', 'x'], source);
      final int opsBefore = (await repo.opLog()).length;

      final List<RemoteRefChange>? changes = await resultOrReaped(repo.remoteChanges('origin'));

      if (changes != null) {
        expect(
          changes.map((c) => (c.kind, c.name, c.change, c.oldCommitIds.join(','), c.newCommitId)).toList(),
          [
            (RemoteRefKind.bookmark, 'main', RemoteRefChangeKind.moved, oldMain, newMain),
            (RemoteRefKind.bookmark, 'x', RemoteRefChangeKind.deleted, oldMain, null),
            (RemoteRefKind.tag, 'v1', RemoteRefChangeKind.created, '', newMain),
          ],
        );
      }
      expect((await repo.opLog()).length, opsBefore, reason: 'the poll writes no operation');
    });

    test('an unknown remote is jj.remote_not_found', () async {
      final RepoHandle repo = await openRepo();
      await expectLater(
        repo.remoteChanges('nope').result,
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.remote_not_found')
              .having((e) => e.context, 'context', 'nope'),
        ),
      );
    });
  });
}
