// SPDX-License-Identifier: MIT

// Worker round-trip witnesses for Story 9.32's warning channel: each test drives
// the REAL Isolate.spawn flow against the REAL compiled cdylib into a jj CLI
// @ v0.44.0 warning and asserts it arrives on the Dart result as a coded
// [ZanshinWarning] with the CLI's text — one witness per registered code a worker
// fixture can produce (20 of 23). The three it cannot, witnessed in Rust and by
// the synthetic decode tests (`test/ffi/warning_test.dart`) only:
// - `jj.identity_missing`: Makefile.toml pins `JJ_USER` / `JJ_EMAIL`, which are
//   EnvOverrides — no repo or user config the test writes can empty them.
// - `jj.snapshot_paths_not_utf8`: APFS refuses file names that are not valid
//   UTF-8, so no such path can reach a snapshot on macOS.
// - `jj.path_access_denied`: only jj-lib's `testing`-gated `SecretBackend` raises
//   `AccessDenied`, and the worker opens repos with the default backends only.
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml, so the repo-scope config files these tests write
// land there — never in the developer's real ~/.config/jj.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart';
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/ffi/file.dart';
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/mutate.dart';
import 'package:zanshin_core/src/ffi/precondition.dart';
import 'package:zanshin_core/src/ffi/status.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';

/// Makes [dir] a Git repository with one commit on `main` — the input `convert`
/// turns into a colocated workspace.
Future<void> _gitWithCommit(Directory dir) async {
  Future<void> git(List<String> args) async {
    final ProcessResult result = await Process.run('git', ['-C', dir.path, ...args]);
    if (result.exitCode != 0) {
      throw StateError('git ${args.join(' ')} failed: ${result.stderr}');
    }
  }

  await git(['init', '-b', 'main']);
  await git(['config', 'user.email', 'test@test.invalid']);
  await git(['config', 'user.name', 'Test']);
  File('${dir.path}/README').writeAsStringSync('init');
  await git(['add', '.']);
  await git(['commit', '-m', 'init', '--no-gpg-sign']);
}

List<String> _codes(List<ZanshinWarning> warnings) => [for (final ZanshinWarning w in warnings) w.code];

void main() {
  group('Story 9.32 warnings (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late String root;

    // The Makefile's XDG_CONFIG_HOME pin: without it the repo-scope writes below would create
    // secure config under the developer's real ~/.config/jj — refuse before the first call.
    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_warnings_test_');
      root = tempDir.resolveSymbolicLinksSync();
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// A fresh Git-backend workspace at [root].
    Future<RepoHandle> initGit() => worker.initRepo(root, backend: 1);

    /// A fresh Git-backend workspace whose repo-scope config file holds [toml],
    /// opened AFTER the write so the handle's config stack sees it.
    Future<RepoHandle> initWithRepoConfig(String toml) async {
      await (await initGit()).close();
      final ConfigFileText file = await worker.configFileRead(
        const ConfigScopeTarget(ConfigScope.repo),
        workspaceRoot: root,
      );
      await worker.configFileWrite(file.path, toml, workspaceRoot: root);
      return worker.openRepo(root);
    }

    // ── Verb-body warnings ────────────────────────────────────────────────────

    test('file_list_reports_an_unmatched_path', () async {
      final RepoHandle handle = await initGit();
      File('$root/a.txt').writeAsStringSync('a');

      final WarnedList<FileEntry> listed = await handle.fileList(paths: ['a.txt', 'nope.txt']);

      expect(listed.map((e) => e.path), ['a.txt'], reason: 'the result is still the list of entries');
      expect(listed.warnings, const [
        ZanshinWarning(code: ZanshinWarningCode.pathsUnmatched, message: 'No matching entries for paths: nope.txt'),
      ]);
      await handle.close();
    });

    test('bookmark_create_on_an_empty_revision_and_delete_of_an_unknown_name', () async {
      final RepoHandle handle = await initGit();

      final MutationResult created = await handle.bookmarkCreate(['b']);
      expect(created.warnings, const [
        ZanshinWarning(code: ZanshinWarningCode.bookmarkTargetEmpty, message: 'Target revision is empty.'),
      ]);

      final MutationResult deleted = await handle.bookmarkDelete(['nope']);
      expect(deleted.warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.bookmarkNamesUnmatched,
          message: 'No matching bookmarks for names: nope',
        ),
      ]);
      await handle.close();
    });

    test('git_remote_add_with_a_url_another_remote_uses', () async {
      final RepoHandle handle = await initGit();
      const url = 'https://example.com/project.git';

      final MutationResult first = await handle.gitRemoteAdd(name: 'first', url: url);
      expect(first.warnings, isEmpty, reason: 'no other remote yet');
      final MutationResult second = await handle.gitRemoteAdd(name: 'second', url: url);

      expect(second.warnings, const [
        ZanshinWarning(code: ZanshinWarningCode.remoteUrlDuplicate, message: 'Remote first already uses the same URL.'),
      ]);
      await handle.close();
    });

    test('show_reports_a_revset_diagnostic', () async {
      final RepoHandle handle = await initGit();

      final WarnedList<ShowEntry> shown = await handle.show(revset: 'diff_contains("x")');

      expect(_codes(shown.warnings), [ZanshinWarningCode.revsetDiagnostic]);
      expect(shown.warnings.single.message, startsWith('In revset expression\n'));
      expect(shown.warnings.single.message, contains('diff_contains() is deprecated; use diff_lines() instead'));
      await handle.close();
    });

    test('graph_topology_reports_a_short_prefixes_index_that_does_not_load', () async {
      final RepoHandle handle = await initGit();

      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        shortPrefixes: 'nonexistent-bookmark-xyz',
        anchors: defaultGraphAnchors,
        withTimestamps: false,
      );

      expect(_codes(view.warnings), [ZanshinWarningCode.shortPrefixesFailed]);
      expect(
        view.warnings.single.message,
        startsWith('In template expression\nFailed to load short-prefixes index\n'),
      );
      expect(view.warnings.single.message, contains('nonexistent-bookmark-xyz'));
      await handle.close();
    });

    test('file_show_skips_a_symlink_as_not_a_file', () async {
      final RepoHandle handle = await initGit();
      File('$root/a.txt').writeAsStringSync('a');
      Link('$root/link').createSync('a.txt');

      final FileContents shown = await handle.fileShow(paths: ['a.txt', 'link']);

      expect(shown.files.map((f) => f.path), ['a.txt']);
      expect(shown.warnings, const [
        ZanshinWarning(code: ZanshinWarningCode.pathNotAFile, message: "Path 'link' exists but is not a file."),
      ]);
      await handle.close();
    });

    test('absorb_skips_a_path_whose_parent_side_is_conflicted', () async {
      final RepoHandle handle = await initGit();
      // Two siblings off root write `c.txt` differently; their merge conflicts there.
      File('$root/c.txt').writeAsStringSync('left\n');
      final WorkingCopyStatus left = await handle.status();
      await handle.newChange([left.parentChangeId]);
      File('$root/c.txt').writeAsStringSync('right\n');
      final WorkingCopyStatus right = await handle.status();
      await handle.newChange([left.workingCopyChangeId, right.workingCopyChangeId]);
      // The merge `@` resolves the file, so its diff against the conflicted parent side is one
      // jj-lib refuses to split.
      File('$root/c.txt').writeAsStringSync('resolved\n');

      final AbsorbResult result = await handle.absorb();

      expect(result.skippedPaths.map((p) => p.path), ['c.txt']);
      expect(result.warnings, const [
        ZanshinWarning(code: ZanshinWarningCode.absorbPathSkipped, message: 'Skipping c.txt: Is a conflict'),
      ]);
      await handle.close();
    });

    test('a_checkout_over_an_untracked_file_is_skipped', () async {
      final RepoHandle handle = await initWithRepoConfig('snapshot.auto-track = "none()"\n');
      File('$root/a.txt').writeAsStringSync('from the commit\n');
      await handle.fileTrack(['a.txt']);
      // The next snapshot records the tracked file into `@` — the edit target.
      final WorkingCopyStatus tracked = await handle.status();
      final String target = tracked.workingCopyChangeId;
      // Moving off the target removes `a.txt`; the same name then reappears UNTRACKED on disk.
      await handle.newChange([tracked.parentChangeId]);
      File('$root/a.txt').writeAsStringSync('untracked on disk\n');

      final MutationResult edited = await handle.edit(target);

      expect(edited.warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.checkoutFilesSkipped,
          message: '1 of those updates were skipped because there were conflicting changes in the working copy.',
        ),
      ]);
      expect(File('$root/a.txt').readAsStringSync(), 'untracked on disk\n', reason: 'the on-disk file is left alone');
      await handle.close();
    });

    // ── The config verbs ──────────────────────────────────────────────────────

    test('config_list_with_nothing_to_list', () async {
      await (await initGit()).close();

      final WarnedList<ConfigEntry> rows = await worker.configList(workspaceRoot: root, name: 'nope');

      expect(rows, isEmpty);
      expect(rows.warnings, const [
        ZanshinWarning(code: ZanshinWarningCode.configNothingListed, message: 'No matching config key for: nope'),
      ]);
    });

    test('config_set_of_user_name_keeps_the_working_copy_author', () async {
      await (await initGit()).close();

      final ConfigSetResult result = await worker.configSet(
        const ConfigScopeTarget(ConfigScope.repo),
        'user.name',
        'Somebody Else',
        workspaceRoot: root,
      );

      expect(result.warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.configWorkingCopyAuthor,
          message:
              'This setting will only impact future commits.\n'
              'The author of the working copy will stay "Zanshin <zanshin@localhost>".\n'
              'To change the working copy author, use "jj metaedit --update-author".',
        ),
      ]);
    });

    test('config_gc_delete_warns_about_a_directory_it_cannot_delete', () async {
      await (await initGit()).close();
      final String dir = File((await worker.configPath(ConfigScope.repo, workspaceRoot: root)).single).parent.path;
      // The repo goes away; a file jj did not write keeps its config directory from being removed.
      tempDir.deleteSync(recursive: true);
      File('$dir/user-note.txt').writeAsStringSync('keep me');

      final ConfigGcResult result = await worker.configGcDelete([dir]);

      expect(result.failed.single.configDir, dir);
      expect(result.warnings, [
        ZanshinWarning(
          code: ZanshinWarningCode.configGcDeleteFailed,
          message: 'Failed to delete $dir: ${result.failed.single.reason}',
        ),
      ]);
      Directory(dir).deleteSync(recursive: true);
    });

    // ── Config-load and snapshot warnings ─────────────────────────────────────

    test('a_bad_alias_entry_warns_and_is_skipped', () async {
      final RepoHandle handle = await initWithRepoConfig("[revset-aliases]\n'bad(' = 'x'\n");

      final List<ZanshinWarning> warnings = (await handle.status()).warnings;

      expect(_codes(warnings), [ZanshinWarningCode.configAliasInvalid]);
      expect(warnings.single.message, startsWith('Failed to load `revset-aliases.bad(`: '));
      await handle.close();
    });

    test('redefining_a_mutability_builtin_warns', () async {
      final RepoHandle handle = await initWithRepoConfig("[revset-aliases]\n'mutable()' = '~immutable()'\n");

      expect((await handle.status()).warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.configAliasRedefined,
          message: 'Redefining `revset-aliases.mutable()` is not recommended; redefine `immutable_heads()` instead.',
        ),
      ]);
      await handle.close();
    });

    test('a_new_file_over_the_size_limit_is_refused', () async {
      final RepoHandle handle = await initWithRepoConfig('snapshot.max-new-file-size = 1024\n');
      File('$root/big.bin').writeAsBytesSync(List<int>.filled(2048, 0x61));

      expect((await handle.status()).warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.snapshotFilesRefused,
          message:
              'Refused to snapshot some files:\n'
              '  big.bin: 2.0KiB (2048 bytes); the maximum size allowed is 1.0KiB (1024 bytes)',
        ),
      ]);
      await handle.close();
    });

    test('an_immutable_at_gets_a_new_commit_and_snapshot_reports_it', () async {
      final RepoHandle handle = await initWithRepoConfig("[revset-aliases]\n'immutable_heads()' = '@'\n");
      File('$root/a.txt').writeAsStringSync('edited');

      final Precondition report = await handle.snapshot();

      expect(report.wasSnapshotTaken, isTrue);
      expect(report.warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.workingCopyImmutable,
          message: 'The working-copy commit is immutable; a new commit has been created on top of it.',
        ),
      ]);
      expect(handle.lastPrecondition?.warnings, isEmpty, reason: 'lastPrecondition is unchanged by Story 9.32');
      await handle.close();
    });

    // ── Colocated workspace ───────────────────────────────────────────────────

    test('colocated_jjconflict_entries_and_a_failed_bookmark_export', () async {
      await _gitWithCommit(tempDir);
      final RepoHandle handle = await worker.convert(root);

      File('$root/.jjconflict-base-0').writeAsStringSync('left behind by a plain git checkout\n');
      expect((await handle.snapshot()).warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.jjconflictFilesPresent,
          message:
              "The working copy contains '.jjconflict' files. These files are used by `jj` internally and should "
              'not be present in the working copy.',
        ),
      ]);

      // Git cannot hold `foo` and `foo/bar` at once: the finish's export fails for one.
      final List<Bookmark> bookmarks = await handle.bookmarks();
      final String main = bookmarks.singleWhere((b) => b.name == 'main' && b.kind is LocalBookmark).target!;
      final MutationResult created = await handle.bookmarkCreate(['foo', 'foo/bar'], revision: main);

      // The CLI's print order: the pre-verb snapshot still sees the `.jjconflict` entry and
      // warns again, THEN the finish reports its export failure.
      expect(_codes(created.warnings), [ZanshinWarningCode.jjconflictFilesPresent, ZanshinWarningCode.gitExportFailed]);
      final String reason = created.finish!.exportFailedBookmarks.single.reason;
      expect(created.warnings.last.message, 'Failed to export some bookmarks:\n  foo/bar@git: $reason');
      await handle.close();
    });

    test('colocated_refs_import_reports_a_ref_it_cannot_import', () async {
      await _gitWithCommit(tempDir);
      final RepoHandle handle = await worker.convert(root);
      // A ref in the reserved `refs/remotes/git/` namespace — the pre-verb refs import refuses it.
      final ProcessResult updated = await Process.run('git', [
        '-C',
        root,
        'update-ref',
        'refs/remotes/git/stolen',
        'HEAD',
      ]);
      expect(updated.exitCode, 0, reason: '${updated.stderr}');

      expect((await handle.status()).warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.gitImportFailed,
          message: 'Failed to import some Git refs:\n  refs/remotes/git/stolen',
        ),
      ]);
      await handle.close();
    });

    test('colocated_finish_reports_a_git_head_it_cannot_move', () async {
      await _gitWithCommit(tempDir);
      final RepoHandle handle = await worker.convert(root);
      // A new change on top of `@` moves `@-`, so the finish must move Git HEAD — held locked.
      final String at = (await handle.status()).workingCopyChangeId;
      final headLock = File('$root/.git/HEAD.lock')..writeAsStringSync('');

      final MutationResult result;
      try {
        result = await handle.newChange([at]);
      } finally {
        headLock.deleteSync();
      }

      expect(_codes(result.warnings), [ZanshinWarningCode.gitHeadUpdateFailed]);
      expect(result.warnings.single.message, startsWith('Failed to update Git HEAD ref\nCaused by'));
      await handle.close();
    });
  });
}
