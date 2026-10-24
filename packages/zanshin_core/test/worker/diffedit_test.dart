// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.17's `diffedit` (and `selectTree(from:)`,
// `ShowEntry.treeIds`) on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits the
// zanshin_diffedit extern "C" function in the coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain; the semantics are
// witnessed by the Rust suites (crates/zanshin-jj/tests/it/diffedit.rs) and
// against the stock CLI by the parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart' show ShowEntry;
import 'package:zanshin_core/src/ffi/file.dart' show FileContents;
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/select_tree.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

const fLeft = 'a\nb\nc\nd\ne\n';
const fRight = 'A\nb\nC\nd\nE\n';
const fOneAndThree = 'A\nb\nc\nd\nE\n';
const section1 = HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1);
const section3 = HunkKey(oldStart: 4, oldCount: 1, newStart: 4, newCount: 1);

void main() {
  group('RepoHandle diffedit round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change id of `a`, which holds f.txt's left side.
    late String a;

    /// Change id of `@` on `a`, which changes f.txt in three sections.
    late String at;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_diffedit_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/f.txt').writeAsStringSync(fLeft);
      a = (await repo.status()).workingCopyChangeId!;
      await repo.newChange([a]);
      File('${tempDir.path}/f.txt').writeAsStringSync(fRight);
      at = (await repo.status()).workingCopyChangeId!;
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<ShowEntry> show(String revision) async => (await repo.show(revset: revision)).single;

    Future<String> fileAt(String revision) async {
      final FileContents shown = await repo.fileShow(revision: revision, paths: const ['f.txt']);
      return utf8.decode(shown.files.single.content);
    }

    test('diffedit_with_sections_one_and_three_keeps_only_them', () async {
      final List<String> left = (await show(at)).parentTreeIds;
      final SelectedTree tree = await repo.selectTree(
        left: left,
        files: const [
          FileSelection.hunks('f.txt', [section1, section3]),
        ],
      );
      final MutationResult result = await repo.diffedit(tree: TreeSelection.of(tree, left: left));
      expect(result.workingCopyChangeId, at);
      expect(await fileAt(at), fOneAndThree);
    });

    /// A child `c` of `at` (g.txt), which becomes `@` — or, with [editBack],
    /// `@` goes back to `at`. Returns `c`.
    Future<String> childOfAt({bool editBack = false}) async {
      await repo.newChange([at]);
      File('${tempDir.path}/g.txt').writeAsStringSync('g\n');
      final String c = (await repo.status()).workingCopyChangeId!;
      if (editBack) {
        await repo.edit(at);
      }
      return c;
    }

    test('from_to_selects_against_a_grandparents_own_tree', () async {
      final String c = await childOfAt(editBack: true);
      final ShowEntry from = await show(a);
      expect(from.treeIds, hasLength(1));
      expect(from.treeIds, isNot((await show(c)).parentTreeIds), reason: "a is c's grandparent");
      final SelectedTree tree = await repo.selectTree(
        revision: c,
        from: a,
        left: from.treeIds,
        files: const [
          FileSelection.hunks('f.txt', [section3]),
          FileSelection.whole('g.txt'),
        ],
      );
      await repo.diffedit(
        tree: TreeSelection.of(tree, left: from.treeIds),
        from: a,
        to: c,
      );
      expect(await fileAt(c), 'a\nb\nc\nd\nE\n');
      expect(await fileAt(at), fRight, reason: 'only `to` is edited');
    });

    Future<void> diffeditAtKeepingSectionsOneAndThree({required bool restoreDescendants}) async {
      final List<String> left = (await show(at)).parentTreeIds;
      final SelectedTree tree = await repo.selectTree(
        revision: at,
        left: left,
        files: const [
          FileSelection.hunks('f.txt', [section1, section3]),
        ],
      );
      await repo.diffedit(
        tree: TreeSelection.of(tree, left: left),
        revision: at,
        restoreDescendants: restoreDescendants,
      );
    }

    test('a_child_is_rebased_by_default', () async {
      final String c = await childOfAt();
      await diffeditAtKeepingSectionsOneAndThree(restoreDescendants: false);
      expect(await fileAt(at), fOneAndThree);
      expect(await fileAt(c), fOneAndThree, reason: 'the child keeps its diff');
    });

    test('restore_descendants_keeps_the_childs_content', () async {
      final String c = await childOfAt();
      await diffeditAtKeepingSectionsOneAndThree(restoreDescendants: true);
      expect(await fileAt(at), fOneAndThree);
      expect(await fileAt(c), fRight, reason: 'the child keeps its content');
    });

    test('a_stale_left_and_revision_with_from_are_refused', () async {
      final List<String> left = (await show(at)).parentTreeIds;
      final SelectedTree tree = await repo.selectTree(left: left, files: const [FileSelection.whole('f.txt')]);
      await expectLater(
        repo.diffedit(tree: TreeSelection.of(tree, left: tree.treeIds)),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.stale_selection')),
      );
      await expectLater(
        repo.diffedit(
          tree: TreeSelection.of(tree, left: left),
          revision: at,
          from: a,
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });
  });
}
