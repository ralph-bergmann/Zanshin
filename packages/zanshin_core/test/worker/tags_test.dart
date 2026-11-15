// SPDX-License-Identifier: MIT

// Worker round-trip tests for the tag list and the tag verbs (Story 9.59) on
// both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib.
// They are also what credits zanshin_tags, zanshin_tag_set, zanshin_tag_delete,
// zanshin_tag_track and zanshin_tag_untrack in the coverage ratchet: a
// #[no_mangle] extern fn hit from a Rust integration test is not attributed to
// the cdylib, so each extern fn needs a test calling it through this library.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/tags.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

Future<String> head(RepoHandle handle) async => (await handle.opLog(limit: 1)).single.id;

Future<String> headDescription(RepoHandle handle) async => (await handle.opLog(limit: 1)).single.description;

void main() {
  group('ZanshinWorker tags (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_tags_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('tagSet_on_at_then_tags_lists_a_local_row_and_the_op_reads_set_tag', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      expect(await handle.tags(), isEmpty);
      final String at = (await handle.status()).workingCopyChangeId!;

      final MutationResult set = await handle.tagSet(['v1']);
      expect(set.newOpId, await head(handle));
      expect(await headDescription(handle), startsWith('set tag v1 to commit '));
      final List<Tag> rows = await handle.tags();
      expect(rows, hasLength(1));
      expect((rows.single.name, rows.single.target, rows.single.synced), ('v1', at, true));
      expect(rows.single.kind, isA<LocalTag>());

      // A second set without allowMove refuses with the CLI's hint and writes nothing.
      final String before = await head(handle);
      await expectLater(
        handle.tagSet(['v1'], revision: at),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Refusing to move tag: v1')
              .having((e) => e.hints, 'hints', ['Use --allow-move to update existing tags.']),
        ),
      );
      expect(await head(handle), before);

      // allowMove to the same target changes nothing: no operation.
      expect((await handle.tagSet(['v1'], revision: at, allowMove: true)).newOpId, before);

      // Delete by glob; an unmatched exact name warns and writes nothing.
      await handle.tagDelete(['v*']);
      expect(await headDescription(handle), 'delete tag v1');
      expect(await handle.tags(), isEmpty);
      final String afterDelete = await head(handle);
      final MutationResult none = await handle.tagDelete(['nope']);
      expect(none.newOpId, afterDelete);
      expect(none.warnings.map((w) => w.code), ['jj.tag_names_unmatched']);

      await expectLater(
        handle.tagSet(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      await handle.close();
    });

    test('a_colocated_repo_lists_no_git_row_and_git_tags_warn_on_track_and_untrack', () async {
      final String root = tempDir.resolveSymbolicLinksSync();
      Future<void> git(List<String> args) async {
        final ProcessResult result = await Process.run('git', ['-C', root, ...args]);
        if (result.exitCode != 0) {
          fail('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      await git(['init', '-b', 'main']);
      await git(['config', 'user.email', 'test@test.invalid']);
      await git(['config', 'user.name', 'Test']);
      File('$root/README.md').writeAsStringSync('hello');
      await git(['add', '.']);
      await git(['commit', '-m', 'init', '--no-gpg-sign']);
      // A user's `tag.gpgSign` would make this an annotated tag that needs a message.
      await git(['-c', 'tag.gpgSign=false', 'tag', 'v1']);
      final RepoHandle handle = await worker.convert(root);

      final List<Tag> rows = await handle.tags();
      expect(rows.map((t) => t.name), ['v1']);
      expect(rows.single.kind, isA<LocalTag>(), reason: 'no `git` remote row');

      final String before = await head(handle);
      final MutationResult tracked = await handle.tagTrack(['v1@git']);
      expect(tracked.newOpId, before);
      expect(tracked.warnings.map((w) => w.code), ['jj.tag_already_tracked']);
      final MutationResult untracked = await handle.tagUntrack(['v1@git']);
      expect(untracked.newOpId, before);
      expect(untracked.warnings.map((w) => w.code), ['jj.tag_git_tracking_untrack']);

      // `remotes` crosses: an unknown remote matches nothing.
      final MutationResult noRemote = await handle.tagTrack(['v1'], remotes: ['nope']);
      expect(noRemote.newOpId, before);
      expect(noRemote.warnings.map((w) => w.code), ['jj.tag_remotes_unmatched']);

      await expectLater(
        handle.tagUntrack(['v1', 'v1@origin']),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Cannot specify both <tag> patterns and <tag>@<remote> symbols'),
        ),
      );
      await handle.close();
    });
  });

  group('RepoHandle tag methods closed-handle and argument guards', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_tags_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('the_five_tag_calls_on_a_closed_handle_throw_state_error_or_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(handle.tags, throwsA(isA<StateError>()));
      expect(() => handle.tagSet(['v1']), throwsA(isA<StateError>()));
      expect(() => handle.tagDelete(['v1']), throwsA(isA<StateError>()));
      expect(() => handle.tagTrack(['v1']), throwsA(isA<StateError>()));
      expect(() => handle.tagUntrack(['v1']), throwsA(isA<StateError>()));

      final Matcher invalid = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle'));
      await expectLater(worker.tags(handle.handleId), invalid);
      await expectLater(worker.tagSet(handle.handleId, ['v1']), invalid);
      await expectLater(worker.tagDelete(handle.handleId, ['v1']), invalid);
      await expectLater(worker.tagTrack(handle.handleId, ['v1']), invalid);
      await expectLater(worker.tagUntrack(handle.handleId, ['v1']), invalid);
    });

    test('interior_NUL_in_the_tag_verbs_is_an_ArgumentError', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);
      Matcher argument(String name) => throwsA(isA<ArgumentError>().having((e) => e.name, 'name', name));

      expect(() => handle.tagSet(['v${nul}1']), argument('names'));
      expect(() => handle.tagSet(['v1'], revision: 'q$nul'), argument('revision'));
      expect(() => handle.tagDelete(['v${nul}1']), argument('names'));
      expect(() => handle.tagTrack(['v${nul}1']), argument('names'));
      expect(() => handle.tagTrack(['v1'], remotes: ['o$nul']), argument('remotes'));
      expect(() => handle.tagUntrack(['v${nul}1']), argument('names'));
      expect(() => handle.tagUntrack(['v1'], remotes: ['o$nul']), argument('remotes'));

      await handle.close();
    });
  });
}
