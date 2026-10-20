// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.bookmarks] and [RepoHandle.bookmarks].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI.
//
// A freshly-init'd jj repo has NO bookmarks; the test asserts bookmarks.isEmpty
// (the real expected shape, F20 oracle-equality rule — not vacuous isNotEmpty).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/bookmarks.dart';
import 'package:zanshin_core/src/ffi/config.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// The one row on [remote] (null: the local row).
Bookmark _row(List<Bookmark> rows, String? remote) => rows.singleWhere(
  (b) => switch (b.kind) {
    LocalBookmark() => remote == null,
    RemoteBookmark(:final String remoteName) => remoteName == remote,
  },
);

void main() {
  // ── Round-trip ────────────────────────────────────────────────────────────

  group('ZanshinWorker.bookmarks round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmarks_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('bookmarks_on_fresh_init_returns_empty_list', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final List<Bookmark> bms = await handle.bookmarks();

      // A freshly initialised repo has no bookmarks — isEmpty is the real
      // expected shape (F20 oracle-equality rule).
      expect(bms, isEmpty, reason: 'fresh init repo must have no bookmarks');

      await handle.close();
    });

    test('bookmarks_stable_across_two_calls_on_fresh_repo', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // A fresh repo has no bookmarks, and this read-only slice exposes no
      // bookmark-mutation FFI, so both calls must return the real expected shape
      // (empty) — asserted concretely, not via a vacuous per-element loop (F20).
      // Populated per-field equality is covered Rust-side
      // (bookmarks_medium_returns_29_local_entries) and by the synthetic decode
      // contract test (test/ffi/bookmarks_test.dart).
      final List<Bookmark> first = await handle.bookmarks();
      final List<Bookmark> second = await handle.bookmarks();
      expect(first, isEmpty, reason: 'fresh repo: first call must be empty');
      expect(second, isEmpty, reason: 'fresh repo: second call must be empty');

      await handle.close();
    });

    test('a_created_bookmark_carries_its_tracking_facts_through_the_real_cdylib', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final String wc = (await handle.status()).workingCopyChangeId;
      await handle.bookmarkCreate(['feature']);

      final Bookmark bm = (await handle.bookmarks()).single;

      // Story 9.29: a local-only bookmark is vacuously synced, resolved, and points at `@`.
      expect(bm.name, 'feature');
      expect(bm.kind, isA<LocalBookmark>());
      expect(bm.target, wc);
      expect(bm.synced, isTrue);
      expect(bm.conflicted, isFalse);

      await handle.close();
    });

    // Story 9.29, the session's case (I1) through the real worker: a tracked `feature@origin`
    // (a git remote-tracking ref imported under `remotes.origin.auto-track-bookmarks`, since a
    // fetch cannot run under `dart test` — see mutate_test.dart's `gitFetch` note), then a
    // local rewrite keeps the change id while both sides gain a commit the other lacks.
    test('a_local_rewrite_reads_ahead_one_behind_one_under_the_same_change_id', () async {
      // The Makefile's XDG_CONFIG_HOME pin: without it the repo-scope write below would create
      // secure config under the developer's real ~/.config/jj — refuse before the first call.
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

      final List<Bookmark> synced = await handle.bookmarks();
      final origin = _row(synced, 'origin').kind as RemoteBookmark;
      expect(origin.tracked, isTrue, reason: 'auto-tracked on import');
      expect((origin.ahead?.lower, origin.ahead?.upper, origin.behind?.lower), (0, 0, 0));
      final String change = synced.first.target!;

      await handle.describe(changeId: change, description: 'rewritten');
      final List<Bookmark> rows = await handle.bookmarks();

      final Bookmark local = _row(rows, null);
      final Bookmark remote = _row(rows, 'origin');
      expect((local.target, remote.target), (change, change), reason: 'one change id on both sides');
      expect((local.synced, remote.synced, local.conflicted), (false, false, false));
      final kind = remote.kind as RemoteBookmark;
      expect((kind.tracked, kind.ahead?.lower, kind.ahead?.upper), (true, 1, 1));
      expect((kind.behind?.lower, kind.behind?.upper), (1, 1));
      expect(_row(rows, 'git').synced, isTrue, reason: 'the colocated export moved @git with the rewrite');

      // Deleting the local bookmark leaves the CLI's `(deleted)` row next to the still-tracked origin.
      await handle.bookmarkDelete(['exact:feature']);
      final List<Bookmark> deleted = await handle.bookmarks();
      final Bookmark gone = _row(deleted, null);
      expect((gone.target, gone.synced), (null, false));
      final stillTracked = _row(deleted, 'origin').kind as RemoteBookmark;
      expect((stillTracked.tracked, stillTracked.ahead, stillTracked.behind), (true, null, null));

      await handle.close();
    });

    test('bookmarks_on_closed_handle_surfaces_ffi_invalid_handle', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // Direct worker call with the now-unknown handleId bypasses the closed guard.
      //
      // `context` is pinned here and nowhere else: since the 2026-09-05 dedupe all 33
      // worker arms synthesize this envelope through the single
      // `_invalidHandleEnvelope(handleId)` helper, so this is the only assertion in the
      // suite that would notice the id being dropped from the message or the wording
      // drifting. Every other closed-handle test asserts `code` alone.
      await expectLater(
        worker.bookmarks(handle.handleId),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'ffi.invalid_handle')
              .having((e) => e.context, 'context', 'unknown or closed handleId: ${handle.handleId}'),
        ),
      );
    });
  });

  // ── RepoHandle.bookmarks guard ────────────────────────────────────────────

  group('RepoHandle.bookmarks closed-handle guard', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_bookmarks_guard_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('bookmarks_on_explicitly_closed_handle_throws_state_error_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      // RepoHandle.bookmarks() must throw StateError synchronously before reaching the worker.
      expect(
        handle.bookmarks,
        throwsA(isA<StateError>()),
      );
    });
  });
}
