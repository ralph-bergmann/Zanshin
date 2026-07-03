// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.detect] and [ZanshinWorker.convert].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI.
// They are the authoritative coverage source for the two new extern fn bodies
// (zanshin_repo_detect, zanshin_repo_convert) — cargo-llvm-cov cannot credit
// those bodies from cargo integration tests; only the Dart cdylib path does.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/repo_detect.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// Creates a git repository at [dir] with a single commit on `main`.
///
/// Required by convert_colocated (must have a HEAD to import).
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

void main() {
  // ── detect round-trip ─────────────────────────────────────────────────────

  group('ZanshinWorker.detect round-trip (real cdylib)', () {
    late ZanshinWorker worker;

    setUp(() async {
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
    });

    test('detect_jj_repo_returns_jj_kind', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_detect_jj_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Init a jj repo so detect has something to find.
      final RepoHandle handle = await worker.initRepo(tmp.path, backend: 0);
      await handle.close();

      final RepoDetectResult result = await worker.detect(tmp.path);

      expect(result.kind, equals(RepoKind.jj), reason: 'jj repo must classify as jj');
      expect(result.suggestedRoot, isNull, reason: 'no suggestion for a direct jj hit');
    });

    test('detect_empty_dir_returns_neither', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_detect_neither_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final RepoDetectResult result = await worker.detect(tmp.path);

      expect(result.kind, equals(RepoKind.neither), reason: 'empty dir must classify as neither');
    });

    test('detect_nonexistent_path_returns_path_not_found', () async {
      final missing = '${Directory.systemTemp.path}/zanshin_detect_DOES_NOT_EXIST_xyzzy';

      final RepoDetectResult result = await worker.detect(missing);

      expect(result.kind, equals(RepoKind.pathNotFound));
    });

    test('detect_subdir_of_jj_repo_returns_neither_with_jj_suggestion', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_detect_suggest_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // Init a jj repo at tmp, then create a subdir to classify.
      final RepoHandle handle = await worker.initRepo(tmp.path, backend: 0);
      await handle.close();

      final subdir = Directory('${tmp.path}/subdir')..createSync();

      final RepoDetectResult result = await worker.detect(subdir.path);

      expect(result.kind, equals(RepoKind.neither), reason: 'empty subdir classifies as neither');
      expect(result.suggestedRoot, isNotNull, reason: 'enclosing jj repo must be suggested');
      expect(
        result.suggestedKind,
        equals(RepoKind.jj),
        reason: 'suggested kind must be jj for an enclosing jj workspace',
      );
    });

    test('detect_subdir_of_git_repo_returns_neither_with_git_suggestion', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_detect_git_suggest_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      // A plain Git repo (no .jj), then an empty subdir to classify.
      await _gitWithCommit(tmp);
      final subdir = Directory('${tmp.path}/subdir')..createSync();

      final RepoDetectResult result = await worker.detect(subdir.path);

      expect(result.kind, equals(RepoKind.neither), reason: 'empty subdir classifies as neither');
      expect(result.suggestedRoot, isNotNull, reason: 'enclosing git repo must be suggested');
      expect(
        result.suggestedKind,
        equals(RepoKind.git),
        reason: 'suggested kind must be git for an enclosing git repo (Git crosses the wire)',
      );
    });
  });

  // ── convert round-trip ────────────────────────────────────────────────────

  group('ZanshinWorker.convert round-trip (real cdylib)', () {
    late ZanshinWorker worker;

    setUp(() async {
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
    });

    test('convert_git_repo_returns_handle_and_detect_returns_jj', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_convert_git_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      await _gitWithCommit(tmp);

      // Pre-condition: git repo is classified as Git before convert.
      final RepoDetectResult before = await worker.detect(tmp.path);
      expect(before.kind, equals(RepoKind.git), reason: 'must be git before convert');

      // Convert → should return a usable handle.
      final RepoHandle handle = await worker.convert(tmp.path);

      // Post-condition: same path is now classified as jj.
      final RepoDetectResult after = await worker.detect(tmp.path);
      expect(after.kind, equals(RepoKind.jj), reason: 'must be jj after convert');

      // `handleId` is a 0-based dense worker id (the first handle is 0), so a
      // numeric bound proves nothing. Prove the handle is a live, registered repo
      // instead: closing it must succeed — a bogus/unregistered handle would throw
      // ffi.invalid_handle.
      await expectLater(
        handle.close(),
        completes,
        reason: 'converted handle must be live and registered',
      );
    });

    test('convert_already_jj_repo_throws_already_jj_repo', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_convert_jj_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      final RepoHandle handle = await worker.initRepo(tmp.path, backend: 0);
      await handle.close();

      await expectLater(
        worker.convert(tmp.path),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.already_jj_repo',
          ),
        ),
      );
    });

    test('convert_empty_dir_throws_not_a_git_repo', () async {
      final Directory tmp = Directory.systemTemp.createTempSync('zanshin_convert_empty_');
      addTearDown(() => tmp.deleteSync(recursive: true));

      await expectLater(
        worker.convert(tmp.path),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.code,
            'code',
            'jj.not_a_git_repo',
          ),
        ),
      );
    });
  });
}
