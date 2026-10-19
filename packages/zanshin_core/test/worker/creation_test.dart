// SPDX-License-Identifier: MIT

// Worker round-trip witnesses for Story 9.33: the creations — `initRepo`,
// `cloneRepo`, `convert` — return a `CreatedRepoHandle` carrying what the
// creating call reported, driven through the REAL Isolate.spawn flow against the
// REAL compiled cdylib. No mocked isolates, no mocked FFI.
//
// `jj.identity_missing` has no witness here: Makefile.toml pins `JJ_USER` /
// `JJ_EMAIL` (EnvOverrides), so no creation this suite runs has an empty
// identity — it is witnessed in Rust (`crates/zanshin-jj/tests/creation_warnings.rs`).
//
// JJ_CONFIG="" and XDG_CONFIG_HOME (a throwaway dir under target/) are pinned
// externally by Makefile.toml.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/file_ops.dart';
import 'package:zanshin_core/src/ffi/precondition.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

/// Makes [dir] a Git repository with one commit on `main` holding `README.md`.
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
  File('${dir.path}/README.md').writeAsStringSync('hello');
  await git(['add', '.']);
  await git(['commit', '-m', 'init', '--no-gpg-sign']);
}

void main() {
  group('Story 9.33 creation reports (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUpAll(() {
      Platform.environment['XDG_CONFIG_HOME'] ?? fail('XDG_CONFIG_HOME is not pinned — run via cargo make');
    });

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_creation_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('init_reports_nothing_and_open_stays_a_plain_handle', () async {
      final String root = tempDir.resolveSymbolicLinksSync();

      final CreatedRepoHandle created = await worker.initRepo(root, backend: 1, noColocate: true);

      expect(created.warnings, isEmpty);
      expect(created.precondition, isNull);
      expect(created.lastPrecondition, isNull, reason: 'a creation is not a verb on the handle');
      await created.close();

      final RepoHandle opened = await worker.openRepo(root);
      expect(opened, isNot(isA<CreatedRepoHandle>()), reason: 'open carries no creation report');
      await opened.close();
    });

    // WHY no successful clone here: a clone's fetch runs a real `git` subprocess, and
    // `Child::wait()` on it fails ("Failed to wait for the git process") inside any
    // `dart test` process — the Dart VM reaps its children (see `mutate_test.dart`'s
    // `gitFetch` note). The clone itself is witnessed in Rust
    // (`crates/zanshin-jj/tests/clone_init.rs`, `crates/zanshin-ffi/tests/push_ffi.rs`);
    // this covers the refusal arm of `cloneRepo`'s return path on a destination that
    // is not empty, which Story 9.20 refuses before anything — and any git — runs.
    test('clone_refusal_arrives_as_an_exception', () async {
      File('${tempDir.path}/keep.txt').writeAsStringSync('mine');

      await expectLater(
        worker.cloneRepo(source: 'file:///nowhere', destination: tempDir.path),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.destination_not_empty')),
      );
      expect(Directory('${tempDir.path}/.jj').existsSync(), isFalse, reason: 'nothing was created');
      expect(File('${tempDir.path}/keep.txt').readAsStringSync(), 'mine');
    });

    // Story 9.20: `depth` crosses as a uint32 — a value outside it is refused on the
    // calling side instead of wrapping on the wire.
    test('clone_refuses_a_depth_beyond_32_bits', () async {
      await expectLater(
        worker.cloneRepo(source: 'file:///nowhere', destination: tempDir.path, depth: 0x100000000),
        throwsArgumentError,
      );
      expect(Directory('${tempDir.path}/.jj').existsSync(), isFalse, reason: 'nothing was sent');
    });

    // Story 9.20: `jj git init`'s two colocation flags reach the Rust verb.
    test('init_colocate_creates_a_git_dir_and_no_colocate_does_not', () async {
      final colocated = '${tempDir.resolveSymbolicLinksSync()}/colocated';
      final internal = '${tempDir.resolveSymbolicLinksSync()}/internal';

      final CreatedRepoHandle a = await worker.initRepo(colocated, backend: 1, colocate: true);
      final CreatedRepoHandle b = await worker.initRepo(internal, backend: 1, noColocate: true);
      await a.close();
      await b.close();

      expect(Directory('$colocated/.git').existsSync(), isTrue, reason: 'a missing path is created, colocated');
      expect(File('$colocated/.jj/.gitignore').existsSync(), isTrue);
      expect(Directory('$internal/.git').existsSync(), isFalse);
      expect(Directory('$internal/.jj/repo/store/git').existsSync(), isTrue);
    });

    test('init_with_both_colocation_flags_is_refused', () async {
      await expectLater(
        worker.initRepo('${tempDir.path}/both', backend: 1, colocate: true, noColocate: true),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      expect(Directory('${tempDir.path}/both').existsSync(), isFalse);
    });

    test('init_no_colocate_over_a_git_dir_is_refused', () async {
      Directory('${tempDir.path}/.git').createSync();

      await expectLater(
        worker.initRepo(tempDir.path, backend: 1, noColocate: true),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.git_repo_exists')),
      );
      expect(Directory('${tempDir.path}/.jj').existsSync(), isFalse);
    });

    test('convert_with_a_big_new_file_reports_the_snapshot_and_the_refusal', () async {
      await _gitWithCommit(tempDir);
      // Twice the builtin `snapshot.max-new-file-size` (1 MiB).
      File('${tempDir.path}/big.bin').writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x61));

      final CreatedRepoHandle converted = await worker.convert(tempDir.resolveSymbolicLinksSync());

      expect(converted.warnings, const [
        ZanshinWarning(
          code: ZanshinWarningCode.snapshotFilesRefused,
          message:
              'Refused to snapshot some files:\n'
              '  big.bin: 2.0MiB (2097152 bytes); the maximum size allowed is 1.0MiB (1048576 bytes)',
        ),
      ]);
      final Precondition report = converted.precondition!;
      expect(report.gitHeadImported, isTrue);
      final UntrackedPath refused = report.snapshotStats.untracked.single;
      expect(refused.path, 'big.bin');
      expect(
        refused.reason,
        isA<FileTooLarge>().having((r) => r.size, 'size', 2097152).having((r) => r.maxSize, 'maxSize', 1048576),
      );
      await converted.close();
    });
  });
}
