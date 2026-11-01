// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 5.8's `diff` on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/select_tree_test.dart. They are also what credits the
// zanshin_diff extern "C" function in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelope decodes, and that a key it
// reports is one `selectTree` accepts. The semantics are witnessed by the Rust
// suites (crates/zanshin-jj/tests/it/hunks.rs, crates/zanshin-ffi/tests/it/diff_ffi.rs).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart' show ShowEntry;
import 'package:zanshin_core/src/ffi/diff.dart';
import 'package:zanshin_core/src/ffi/select_tree.dart';
import 'package:zanshin_core/src/ffi/warning.dart' show ZanshinWarningCode;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle diff round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change id of `@`, which changes f.txt in three sections (and w.txt in
    /// whitespace only) over its parent `a`.
    late String at;

    /// Change id of `@`'s parent.
    late String a;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_diff_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/f.txt').writeAsStringSync('a\nb\nc\nd\ne\n');
      File('${tempDir.path}/w.txt').writeAsStringSync('x y\n');
      a = (await repo.status()).workingCopyChangeId!;
      await repo.describe(changeId: a, description: 'A\n');
      await repo.newChange([a]);
      File('${tempDir.path}/f.txt').writeAsStringSync('A\nb\nC\nd\nE\n');
      File('${tempDir.path}/w.txt').writeAsStringSync('x  y\n');
      at = (await repo.status()).workingCopyChangeId!;
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    FileDiff fileOf(Diff diff, String path) => diff.files.singleWhere((f) => f.path == path);

    test('a_revision_diff_carries_files_hunks_keys_and_pins_and_its_keys_select', () async {
      final Diff diff = await repo.diff(revision: at);
      expect(diff.operationId, isNotEmpty);
      expect(diff.commitId, isNotEmpty);
      expect(diff.fromCommitId, isNull);
      final FileDiff f = fileOf(diff, 'f.txt');
      expect(f.sections, hasLength(3));
      expect(f.hunks, isNotEmpty);
      expect((f.removed, f.added), (3, 3));
      expect(f.fingerprint, isNotEmpty);
      expect(f.hunks.expand((h) => h.lines).map((l) => l.kind), contains(HunkLineKind.context));

      final List<ShowEntry> shown = await repo.show(revset: at);
      final SelectedTree tree = await repo.selectTree(
        left: shown.single.parentTreeIds,
        files: [FileSelection.hunks('f.txt', f.hunks.first.sections)],
      );
      expect(tree.treeIds, hasLength(1), reason: 'the reported key is accepted');

      final Diff defaulted = await repo.diff();
      expect(defaulted.commitId, diff.commitId, reason: 'no revision = @');
    });

    test('from_and_to_select_the_from_to_form', () async {
      final Diff revision = await repo.diff(revision: at);
      final Diff fromTo = await repo.diff(from: a, to: at);
      expect(fromTo.fromCommitId, isNotNull);
      expect(fromTo.commitId, revision.commitId);
      expect(fileOf(fromTo, 'f.txt').sections, fileOf(revision, 'f.txt').sections);
      final Diff fromOnly = await repo.diff(from: a);
      expect(fromOnly.commitId, revision.commitId, reason: 'an absent to is @');
      expect(fromTo.fromCommitId, (await repo.diff(revision: a)).commitId);

      // Move `@` off `at`, so `to: at` differs from an absent `to`.
      await repo.newChange([at]);
      final Diff moved = await repo.diff(from: a, to: at);
      expect(moved.commitId, (await repo.diff(revision: at)).commitId);
      expect(moved.commitId, isNot((await repo.diff()).commitId));
    });

    test('paths_context_whitespace_and_summary_cross_the_buffer', () async {
      final Diff onlyF = await repo.diff(revision: at, paths: const ['f.txt'], context: 0);
      expect(onlyF.files.map((f) => f.path), ['f.txt']);
      expect(onlyF.files.single.hunks.expand((h) => h.lines).map((l) => l.kind), isNot(contains(HunkLineKind.context)));

      final Diff exact = await repo.diff(revision: at, paths: const ['w.txt']);
      expect(exact.files.single.hunks, isNotEmpty);
      for (final DiffWhitespace ws in [DiffWhitespace.ignoreAllSpace, DiffWhitespace.ignoreSpaceChange]) {
        final Diff ignoring = await repo.diff(revision: at, paths: const ['w.txt'], whitespace: ws);
        expect(ignoring.files.expand((f) => f.hunks), isEmpty, reason: '$ws hides a whitespace-only change');
      }

      final Diff summary = await repo.diff(revision: at, summary: true);
      final FileDiff f = fileOf(summary, 'f.txt');
      expect(f.hunks, isEmpty);
      expect((f.sections.length, f.removed, f.added), (3, 3, 3));
    });

    test('an_unmatched_path_is_a_warning', () async {
      final Diff diff = await repo.diff(revision: at, paths: const ['nope']);
      expect(diff.files, isEmpty);
      expect(diff.warnings.map((w) => w.code), [ZanshinWarningCode.pathsUnmatched]);
    });

    test('a_revision_with_from_is_refused', () async {
      await expectLater(
        repo.diff(revision: at, from: a),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      await expectLater(repo.diff(revision: 'a\u0000b'), throwsArgumentError);
      await expectLater(repo.diff(paths: const ['a\u0000b']), throwsArgumentError);
      expect(() => zanshinDiff(0, to: 'a\u0000b'), throwsArgumentError);
    });

    test('a_negative_context_is_refused_on_the_calling_side', () async {
      await expectLater(repo.diff(context: -1), throwsArgumentError);
      expect(() => zanshinDiff(0, context: -1), throwsArgumentError);
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(other.diff, throwsStateError);
    });
  });
}
