// SPDX-License-Identifier: MIT

// Worker round-trip tests for the bookmark mutations (Story 9.8's bookmarkCreate /
// bookmarkDelete, Story 9.19's bookmarkMove / bookmarkAdvance / bookmarkRename,
// Story 9.11's bookmarkSet / bookmarkForget / bookmarkTrack / bookmarkUntrack) on
// both [ZanshinWorker] and [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits
// zanshin_bookmark_create and zanshin_bookmark_delete in the coverage ratchet's
// extern-fn guard: cargo-llvm-cov does not attribute a #[no_mangle] extern fn
// hit from a Rust integration test to the cdylib, so each extern fn needs a
// packages/zanshin_core test calling it through the library
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-flutter]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart' show Bookmark, LocalBookmark, RemoteBookmark;
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// The three [MutationResult] fields neither bookmark verb ever fills, checked all the way
/// through the decoder — `newOpId` is otherwise the only one any test in this suite reads.
void expectNoChangeChurn(MutationResult result, String expectedWc) {
  expect(result.newChangeIds, isEmpty, reason: 'a bookmark verb mints no change');
  expect(result.abandonedChangeIds, isEmpty, reason: 'a bookmark verb abandons no change');
  // The decoder null-coalesces an absent id to '' on BOTH sides of the next comparison, so
  // without this guard a dropped field would satisfy it vacuously.
  expect(expectedWc, isNotEmpty, reason: 'the oracle itself must be a real change id');
  expect(result.workingCopyChangeId, expectedWc, reason: '`@` does not move');
}

void main() {
  group('ZanshinWorker bookmark mutations (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmark_ops_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('create_then_delete_round_trips_through_the_real_cdylib', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // The oracle for `workingCopyChangeId`: neither verb ever moves `@`, so both results
      // must report exactly what `status()` does.
      final String expectedWc = (await handle.status()).workingCopyChangeId!;

      final MutationResult created = await handle.bookmarkCreate(['feature']);
      expect(created.newOpId, isNotEmpty);
      expectNoChangeChurn(created, expectedWc);
      final List<Bookmark> afterCreate = await handle.bookmarks();
      expect(afterCreate.map((b) => b.name), ['feature']);

      final MutationResult deleted = await handle.bookmarkDelete(['exact:feature']);
      expect(deleted.newOpId, isNot(created.newOpId), reason: 'the delete writes its own operation');
      expectNoChangeChurn(deleted, expectedWc);
      expect(await handle.bookmarks(), isEmpty);

      await handle.close();
    });

    test('delete_matching_nothing_succeeds_and_writes_no_operation', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // A create first, so there IS a recent operation whose id can be compared.
      final MutationResult created = await handle.bookmarkCreate(['feature']);
      // Read PRE-CALL: an oracle read after the mutation would move with a regression that moved
      // `@`, so both sides of the comparison would shift together and the assertion would hold.
      final String expectedWc = (await handle.status()).workingCopyChangeId!;

      final MutationResult noop = await handle.bookmarkDelete(['nosuch']);

      expect(
        noop.newOpId,
        created.newOpId,
        reason: 'matching nothing returns the PRE-CALL head, the wire form of "No bookmarks to delete."',
      );
      // The no-op exit is supposed to report the same three fields as the committed one, so it
      // is asserted through the decoder here as well.
      expectNoChangeChurn(noop, expectedWc);
      expect(await handle.bookmarks(), hasLength(1), reason: 'nothing was deleted');

      await handle.close();
    });

    test('create_on_an_existing_name_surfaces_jj_bookmark_exists', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.bookmarkCreate(['feature']);

      await expectLater(
        handle.bookmarkCreate(['feature']),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.bookmark_exists')
              .having((e) => e.context, 'context', 'feature'),
        ),
      );

      await handle.close();
    });

    // Without this, `revision` never crosses the seam in a PASSING test: every other
    // create here either omits it or carries an interior NUL, which the calling-side
    // guard rejects before a buffer exists. Dropping `revision:` from the dispatch arm,
    // the command, or the ObjectBuilder would leave the whole gate green while a GUI
    // asking for `bookmark create v1 -r <commit>` silently got a bookmark on `@`.
    test('create_carries_revision_across_the_seam_and_refuses_a_bogus_one', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      const bogus = 'not-reverse-hex!';

      await expectLater(
        handle.bookmarkCreate(['feature'], revision: bogus),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.change_not_found')
              .having((e) => e.context, 'context', bogus),
        ),
      );
      expect(await handle.bookmarks(), isEmpty, reason: 'the refused create wrote nothing');

      await handle.close();
    });

    test('create_with_an_empty_name_list_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.bookmarkCreate(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('delete_with_an_empty_pattern_list_surfaces_jj_invalid_input', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.bookmarkDelete(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );

      await handle.close();
    });

    test('both_verbs_on_a_closed_handle_surface_ffi_invalid_handle_through_the_worker', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.bookmarkCreate(handle.handleId, ['feature']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      await expectLater(
        worker.bookmarkDelete(handle.handleId, ['feature']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    // The interior-NUL guard lives on the CALLING side precisely so it throws an
    // ArgumentError here rather than coming back as `internal.dispatch_error`
    // from inside the worker isolate.
    test('interior_NUL_is_rejected_as_an_ArgumentError_not_a_dispatch_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);

      expect(
        () => handle.bookmarkCreate(['fea${nul}ture']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => handle.bookmarkCreate(['feature'], revision: 'qpv${nul}untsm'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'revision')),
      );
      expect(
        () => handle.bookmarkDelete(['fo${nul}o']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );

      await handle.close();
    });
  });

  // ── Story 9.19: move / advance / rename ─────────────────────────────────────

  group('ZanshinWorker bookmark move / advance / rename (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmark_move_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    /// The local target of [name].
    Future<String?> target(RepoHandle handle, String name) async =>
        (await handle.bookmarks()).singleWhere((b) => b.name == name && b.kind is LocalBookmark).target;

    test('advance_move_and_rename_round_trip_through_the_real_cdylib', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final String a = (await handle.status()).workingCopyChangeId!;
      await handle.describe(changeId: a, description: 'A');
      await handle.bookmarkCreate(['feature']);
      await handle.newChange([a]);
      final String b = (await handle.status()).workingCopyChangeId!;

      // Advance by name, `to` absent: the default target `@`.
      final MutationResult advanced = await handle.bookmarkAdvance(names: ['feature']);
      expect(advanced.newOpId, (await handle.opLog(limit: 1)).single.id);
      expect(await target(handle, 'feature'), b);

      // Backwards: refused with the CLI's hint, nothing written.
      final String before = (await handle.opLog(limit: 1)).single.id;
      await expectLater(
        handle.bookmarkMove(['feature'], to: a),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Refusing to move bookmark backwards or sideways: feature')
              .having((e) => e.hints, 'hints', ['Use --allow-backwards to allow it.']),
        ),
      );
      expect((await handle.opLog(limit: 1)).single.id, before);

      await handle.bookmarkMove(['feature'], to: a, allowBackwards: true);
      expect(await target(handle, 'feature'), a);

      // Advance with the default candidates: `heads(::@ & bookmarks())`.
      await handle.bookmarkAdvance();
      expect(await target(handle, 'feature'), b);

      // Nothing to move is a success that writes no operation.
      final String head = (await handle.opLog(limit: 1)).single.id;
      final MutationResult noOp = await handle.bookmarkMove(['feature'], from: ['@']);
      expect(noOp.newOpId, head);

      await handle.bookmarkRename('feature', 'renamed');
      expect((await handle.bookmarks()).map((bm) => bm.name), ['renamed']);
      expect((await handle.opLog(limit: 1)).single.description, 'rename bookmark feature to renamed');

      await expectLater(
        handle.bookmarkRename('nope', 'x'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'No such bookmark: nope'),
        ),
      );

      await handle.close();
    });

    test('from_advance_to_and_overwrite_cross_through_the_real_cdylib', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final String a = (await handle.status()).workingCopyChangeId!;
      await handle.describe(changeId: a, description: 'A');
      await handle.bookmarkCreate(['one']);
      await handle.newChange([a]);
      final String b = (await handle.status()).workingCopyChangeId!;
      await handle.describe(changeId: b, description: 'B');
      await handle.bookmarkCreate(['two']);
      await handle.newChange([b]);
      final String c = (await handle.status()).workingCopyChangeId!;

      // `from` alone: only the bookmark on A moves; `two` (on B) stays.
      await handle.bookmarkMove(const [], from: [a], to: c);
      expect((await target(handle, 'one'), await target(handle, 'two')), (c, b));

      // Advance with an explicit `to`.
      await handle.bookmarkAdvance(names: ['two'], to: c);
      expect(await target(handle, 'two'), c);

      // Overwrite onto an existing name.
      await handle.bookmarkRename('two', 'one', overwriteExisting: true);
      expect((await handle.bookmarks()).map((bm) => bm.name), ['one']);

      await handle.close();
    });

    test('a_rename_warning_arrives_in_the_result', () async {
      // The Makefile's XDG_CONFIG_HOME pin keeps the repo-scope write below out of ~/.config/jj.
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
      final String root = tempDir.resolveSymbolicLinksSync();
      Future<void> git(List<String> args) async {
        final ProcessResult result = await Process.run('git', ['-C', root, ...args]);
        if (result.exitCode != 0) {
          fail('git ${args.join(' ')} failed: ${result.stderr}');
        }
      }

      await git(['init', '-b', 'feature']);
      await git(['config', 'user.email', 'test@test.invalid']);
      await git(['config', 'user.name', 'Test']);
      File('$root/README.md').writeAsStringSync('hello');
      await git(['add', '.']);
      await git(['commit', '-m', 'init', '--no-gpg-sign']);
      final RepoHandle handle = await worker.convert(root);
      await worker.configSet(
        const ConfigScopeTarget(ConfigScope.repo),
        'remotes.origin.auto-track-bookmarks',
        'glob:*',
        workspaceRoot: root,
      );
      await git(['update-ref', 'refs/remotes/origin/feature', 'HEAD']);

      final MutationResult renamed = await handle.bookmarkRename('feature', 'renamed');
      expect(renamed.warnings.map((w) => w.code), contains('jj.bookmark_remotes_not_renamed'));

      await handle.close();
    });

    test('the_three_verbs_on_a_closed_handle_surface_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      final Matcher matcher = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle'));
      await expectLater(worker.bookmarkMove(handle.handleId, ['feature']), matcher);
      await expectLater(worker.bookmarkAdvance(handle.handleId), matcher);
      await expectLater(worker.bookmarkRename(handle.handleId, 'a', 'b'), matcher);
    });

    test('interior_NUL_in_the_three_verbs_is_an_ArgumentError', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);

      expect(
        () => handle.bookmarkMove(['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => handle.bookmarkMove(const [], from: ['@$nul-']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'from')),
      );
      expect(
        () => handle.bookmarkMove(['a'], to: 'q$nul'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'to')),
      );
      expect(
        () => handle.bookmarkAdvance(names: ['a${nul}b']),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'names')),
      );
      expect(
        () => handle.bookmarkAdvance(to: 'q$nul'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'to')),
      );
      expect(
        () => handle.bookmarkRename('o$nul', 'n'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'oldName')),
      );
      expect(
        () => handle.bookmarkRename('o', 'n$nul'),
        throwsA(isA<ArgumentError>().having((e) => e.name, 'name', 'newName')),
      );

      await handle.close();
    });
  });

  group('ZanshinWorker bookmark set / forget / track / untrack (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmark_tracking_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<String> head(RepoHandle handle) async => (await handle.opLog(limit: 1)).single.id;

    test('set_round_trips_revision_and_allow_backwards', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final String a = (await handle.status()).workingCopyChangeId!;
      await handle.describe(changeId: a, description: 'A');
      await handle.newChange([a]);
      final String b = (await handle.status()).workingCopyChangeId!;

      // `revision` absent: the default `@`.
      final MutationResult created = await handle.bookmarkSet(['feature']);
      expect(created.newOpId, await head(handle));
      Future<String?> target() async => (await handle.bookmarks()).singleWhere((bm) => bm.kind is LocalBookmark).target;
      expect(await target(), b);

      // Backwards to `a`: refused with the hint, nothing written; allowed with the flag.
      final String before = await head(handle);
      await expectLater(
        handle.bookmarkSet(['feature'], revision: a),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', 'Refusing to move bookmark backwards or sideways: feature')
              .having((e) => e.hints, 'hints', ['Use --allow-backwards to allow it.']),
        ),
      );
      expect(await head(handle), before);
      await handle.bookmarkSet(['feature'], revision: a, allowBackwards: true);
      expect(await target(), a);

      await expectLater(
        handle.bookmarkSet(const []),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      await handle.close();
    });

    test('forget_track_and_untrack_round_trip_on_a_colocated_repo', () async {
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
      // Untracked remote bookmarks, imported by the conversion.
      await git(['update-ref', 'refs/remotes/origin/other', 'HEAD']);
      await git(['update-ref', 'refs/remotes/origin/third', 'HEAD']);
      final RepoHandle handle = await worker.convert(root);

      Future<bool?> tracked(String name) async {
        final Bookmark? row = (await handle.bookmarks(allRemotes: true))
            .where((bm) => bm.name == name && bm.kind is RemoteBookmark)
            .where((bm) => (bm.kind as RemoteBookmark).remoteName == 'origin')
            .firstOrNull;
        return row == null ? null : (row.kind as RemoteBookmark).tracked;
      }

      final MutationResult trackedOp = await handle.bookmarkTrack(['other@origin']);
      expect(trackedOp.newOpId, await head(handle));
      expect((await handle.opLog(limit: 1)).single.description, 'track remote bookmark other@origin');
      expect(await tracked('other'), isTrue);

      // Already tracked: a warning and no operation.
      String before = await head(handle);
      final MutationResult again = await handle.bookmarkTrack(['other@origin']);
      expect(again.newOpId, before);
      expect(again.warnings.map((w) => w.code), ['jj.bookmark_already_tracked']);

      // `remotes` crosses: an unknown remote matches nothing.
      final MutationResult none = await handle.bookmarkUntrack(['other'], remotes: ['nope']);
      expect(none.newOpId, before);
      expect(none.warnings.map((w) => w.code), ['jj.bookmark_remotes_unmatched']);
      await handle.bookmarkUntrack(['other'], remotes: ['origin']);
      expect((await handle.opLog(limit: 1)).single.description, 'untrack remote bookmark other@origin');
      expect(await tracked('other'), isFalse);

      await expectLater(
        handle.bookmarkTrack(['a', 'b@origin']),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having(
                (e) => e.context,
                'context',
                'Cannot specify both <bookmark> patterns and <bookmark>@<remote> symbols',
              ),
        ),
      );

      // `includeRemotes` crosses: forgetting the untracked remote-only `third` is a no-op without
      // it (the pre-call head comes back) and writes `forget bookmark third` with it. Only the
      // operation is asserted: this colocated repo re-imports `refs/remotes/origin/third` on the
      // next call, so the row itself is checked in the Rust tests and the parity oracle.
      before = await head(handle);
      expect((await handle.bookmarkForget(['third'])).newOpId, before);
      final MutationResult forgotten = await handle.bookmarkForget(['third'], includeRemotes: true);
      expect(forgotten.newOpId, isNot(before));
      expect((await handle.opLog(limit: 1)).single.description, 'forget bookmark third');
      await handle.close();
    });
  });

  // ── RepoHandle closed-handle guards ───────────────────────────────────────

  group('RepoHandle bookmark mutation methods closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmark_ops_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('bookmarkCreate_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.bookmarkCreate(['feature']), throwsA(isA<StateError>()));
    });

    test('bookmarkDelete_on_explicitly_closed_handle_throws_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.bookmarkDelete(['feature']), throwsA(isA<StateError>()));
    });

    test('the_three_story_9_19_verbs_on_an_explicitly_closed_handle_throw_state_error', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.bookmarkMove(['feature']), throwsA(isA<StateError>()));
      expect(handle.bookmarkAdvance, throwsA(isA<StateError>()));
      expect(() => handle.bookmarkRename('a', 'b'), throwsA(isA<StateError>()));
    });

    test('the_four_story_9_11_verbs_on_a_closed_handle_throw_state_error_or_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(() => handle.bookmarkSet(['feature']), throwsA(isA<StateError>()));
      expect(() => handle.bookmarkForget(['feature']), throwsA(isA<StateError>()));
      expect(() => handle.bookmarkTrack(['feature']), throwsA(isA<StateError>()));
      expect(() => handle.bookmarkUntrack(['feature']), throwsA(isA<StateError>()));

      final Matcher invalid = throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle'));
      await expectLater(worker.bookmarkSet(handle.handleId, ['feature']), invalid);
      await expectLater(worker.bookmarkForget(handle.handleId, ['feature']), invalid);
      await expectLater(worker.bookmarkTrack(handle.handleId, ['feature']), invalid);
      await expectLater(worker.bookmarkUntrack(handle.handleId, ['feature']), invalid);
    });

    test('interior_NUL_in_the_four_story_9_11_verbs_is_an_ArgumentError', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final nul = String.fromCharCode(0);
      Matcher argument(String name) => throwsA(isA<ArgumentError>().having((e) => e.name, 'name', name));

      expect(() => handle.bookmarkSet(['a${nul}b']), argument('names'));
      expect(() => handle.bookmarkSet(['a'], revision: 'q$nul'), argument('revision'));
      expect(() => handle.bookmarkForget(['a${nul}b']), argument('names'));
      expect(() => handle.bookmarkTrack(['a${nul}b']), argument('names'));
      expect(() => handle.bookmarkTrack(['a'], remotes: ['o$nul']), argument('remotes'));
      expect(() => handle.bookmarkUntrack(['a${nul}b']), argument('names'));
      expect(() => handle.bookmarkUntrack(['a'], remotes: ['o$nul']), argument('remotes'));

      await handle.close();
    });
  });
}
