// SPDX-License-Identifier: MIT

// Worker round-trip witnesses for Story 9.35: a failed command's error envelope
// keeps its report on the Dart side — the thrown [ZanshinFfiException] carries
// the envelope's `precondition` and `warnings`. Each test drives the REAL
// Isolate.spawn flow against the REAL compiled cdylib, one per command family
// (handle-scoped, handle-less config, creation) plus an error Rust stamps no
// report on. The recipes mirror the Rust witnesses in crates/zanshin-ffi/tests/
// (snapshot_ffi.rs, config_ffi.rs, repo_ffi.rs).
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml, so the repo-scope config files these tests write
// land there — never in the developer's real ~/.config/jj.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// Makes [dir] a Git repository with one commit on `main` — the input `convert`
/// turns into a colocated workspace.
Future<void> _gitWithCommit(Directory dir) async {
  await _git(dir, ['init', '-b', 'main']);
  await _git(dir, ['config', 'user.email', 'test@test.invalid']);
  await _git(dir, ['config', 'user.name', 'Test']);
  File('${dir.path}/README').writeAsStringSync('init');
  await _git(dir, ['add', '.']);
  await _git(dir, ['commit', '-m', 'init', '--no-gpg-sign']);
}

Future<void> _git(Directory dir, List<String> args) async {
  final ProcessResult result = await Process.run('git', ['-C', dir.path, ...args]);
  if (result.exitCode != 0) {
    throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
  }
}

Future<void> _chmod(String mode, String path) async {
  final ProcessResult result = await Process.run('chmod', [mode, path]);
  if (result.exitCode != 0) {
    throw StateError('chmod $mode failed: ${result.stderr}');
  }
}

/// The [ZanshinFfiException] [call] fails with.
Future<ZanshinFfiException> _thrown(Future<Object?> call) async {
  try {
    await call;
  } on ZanshinFfiException catch (e) {
    return e;
  }
  fail('the call must fail with a ZanshinFfiException');
}

List<String> _codes(List<ZanshinWarning> warnings) => [for (final ZanshinWarning w in warnings) w.code];

void main() {
  group('Story 9.35 error reports (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late String root;

    // The Makefile's XDG_CONFIG_HOME pin: without it the repo-scope writes below would create
    // secure config under the developer's real ~/.config/jj — refuse before the first call.
    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_error_reports_test_');
      root = tempDir.resolveSymbolicLinksSync();
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// A fresh Git-backend workspace at [root], closed again.
    Future<void> initGit() async => (await worker.initRepo(root, backend: 1, noColocate: true)).close();

    /// Replace the repo-scope config file of the workspace at [root] with [toml].
    Future<void> writeRepoConfig(String toml) async {
      final ConfigFileText file = await worker.configFileRead(
        const ConfigScopeTarget(ConfigScope.repo),
        workspaceRoot: root,
      );
      await worker.configFileWrite(file.path, toml, workspaceRoot: root);
    }

    test('a_handle_scoped_refusal_keeps_the_precondition_and_its_warnings', () async {
      await initGit();
      await writeRepoConfig("[revset-aliases]\n'bad(' = 'x'\n");
      final RepoHandle handle = await worker.openRepo(root);
      // A new file, so the pre-verb snapshot takes one — a report that differs from a stale one.
      File('$root/new.txt').writeAsStringSync('new');

      // The root change: the pre-verb snapshot runs (and records the alias warning), then
      // `describe` refuses to rewrite the root commit.
      final ZanshinFfiException e = await _thrown(handle.describe(changeId: 'z' * 32, description: 'x'));

      expect(e.code, 'jj.invalid_input');
      expect(_codes(e.warnings), [ZanshinWarningCode.configAliasInvalid]);
      expect(e.warnings.single.message, startsWith('Failed to load `revset-aliases.bad(`: '));
      expect(e.precondition, isNotNull, reason: 'the report rides the error arm');
      expect(e.precondition!.wasSnapshotTaken, isTrue, reason: 'the snapshot recorded new.txt before the refusal');
      expect(e.precondition!.warnings, isEmpty, reason: "the call's warnings live on the exception");
      expect(handle.lastPrecondition, isNotNull, reason: 'the choke point still records it');
      expect(handle.lastPrecondition!.wasSnapshotTaken, isTrue, reason: 'the same report as the exception');
      await handle.close();
    });

    test('a_failed_identity_set_keeps_its_check_report', () async {
      await initGit();
      // `user.name` is a TABLE in the repo file (the pinned `JJ_USER` keeps the start-up stack
      // valid), so the write fails AFTER the identity check snapshotted and warned.
      await writeRepoConfig('[user.name]\nx = 1\n');

      final ZanshinFfiException e = await _thrown(
        worker.configSet(const ConfigScopeTarget(ConfigScope.repo), 'user.name', 'x', workspaceRoot: root),
      );

      expect(e.code, 'jj.config_would_overwrite');
      expect(e.precondition, isNotNull, reason: 'the identity check ran before the write failed');
      expect(_codes(e.warnings), [ZanshinWarningCode.configWorkingCopyAuthor]);
      expect(e.warnings.single.message, startsWith('This setting will only impact future commits.'));
    });

    test('a_failed_conversion_keeps_its_warnings_and_partial_snapshot_report', () async {
      await _gitWithCommit(tempDir);
      // A ref in the reserved `refs/remotes/git/` namespace — the refs import refuses it.
      await _git(tempDir, ['update-ref', 'refs/remotes/git/stolen', 'HEAD']);
      // A new file the conversion's snapshot cannot open.
      final String locked = (File('$root/locked.txt')..writeAsStringSync('unreadable')).path;
      await _chmod('000', locked);

      final ZanshinFfiException e;
      try {
        e = await _thrown(worker.convert(root));
      } finally {
        await _chmod('644', locked);
      }

      expect(e.code, 'jj.convert_failed');
      expect(e.warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.gitImportFailed,
          message: 'Failed to import some Git refs:\n  refs/remotes/git/stolen',
        ),
      ]);
      expect(e.precondition, isNotNull, reason: 'the partial snapshot report rides the error envelope');
      expect(e.precondition!.gitHeadImported, isTrue, reason: 'the head import ran before the snapshot failed');
      // Story 9.57: nothing is rolled back — the disk is as `jj git init` leaves it — and the
      // exception names the `.jj/` the failure left, at the canonical root.
      expect(Directory('$root/.jj').existsSync(), isTrue, reason: 'the failed conversion leaves its .jj/');
      expect(e.leftBehind, ['$root/.jj']);
      expect(() => e.leftBehind.add('x'), throwsUnsupportedError, reason: 'decoded lists are unmodifiable');
    });

    test('an_error_without_a_report_carries_none', () async {
      // An existing directory that is not a jj repo: Rust stamps no report on open.
      final ZanshinFfiException e = await _thrown(worker.openRepo(root));

      expect(e.code, 'jj.repo_not_found');
      expect(e.precondition, isNull);
      expect(e.warnings, isEmpty);
      expect(e.hints, isEmpty, reason: 'a hint-less error carries no hints (Story 9.56)');
      expect(e.leftBehind, isEmpty, reason: 'only a failed conversion leaves something behind (Story 9.57)');
    });

    // Story 9.56: the CLI's hint lines ride the error envelope's `FfiError.hints` through the
    // worker onto the thrown exception — never inside its context.
    test('a_refusal_carries_the_clis_hints', () async {
      await initGit();
      final RepoHandle handle = await worker.openRepo(root);
      await handle.bookmarkCreate(['taken']);

      final ZanshinFfiException e = await _thrown(handle.bookmarkCreate(['taken']));

      expect(e.code, 'jj.bookmark_exists');
      expect(e.context, 'taken');
      expect(e.hints, ['Use `jj bookmark set` to update it.']);
      await handle.close();
    });
  });
}
