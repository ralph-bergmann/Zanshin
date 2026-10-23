// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.50's `selectTree` and the tree arms of
// `commit`, `split` and `squash` on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/commit_test.dart. They are also what credits the
// zanshin_select_tree extern "C" function in the coverage ratchet's extern-fn
// guard (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that every request field
// is built and crosses the buffer, that the envelopes decode, and that a stale
// selection surfaces as a ZanshinFfiException. The semantics are witnessed by
// the Rust suites (crates/zanshin-jj/tests/it/select_tree.rs) and against the
// stock CLI by the parity oracle (crates/zanshin-parity).
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
import 'package:zanshin_core/src/ffi/squash_split.dart' show SplitResult;
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

const fLeft = 'a\nb\nc\nd\ne\n';
const fRight = 'A\nb\nC\nd\nE\n';
const fOneAndThree = 'A\nb\nc\nd\nE\n';
const section1 = HunkKey(oldStart: 0, oldCount: 1, newStart: 0, newCount: 1);
const section3 = HunkKey(oldStart: 4, oldCount: 1, newStart: 4, newCount: 1);

void main() {
  group('RepoHandle selectTree round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change id of `@`, which changes f.txt in three sections over its parent `a`.
    late String at;

    /// Change id of `@`'s parent, which holds f.txt's left side.
    late String a;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_select_tree_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/f.txt').writeAsStringSync(fLeft);
      a = (await repo.status()).workingCopyChangeId;
      await repo.describe(changeId: a, description: 'A\n');
      await repo.newChange([a]);
      File('${tempDir.path}/f.txt').writeAsStringSync(fRight);
      at = (await repo.status()).workingCopyChangeId;
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<List<String>> leftOf(String revision) async {
      final List<ShowEntry> entries = await repo.show(revset: revision);
      return entries.single.parentTreeIds;
    }

    Future<String> fileAt(String revision) async {
      final FileContents shown = await repo.fileShow(revision: revision, paths: const ['f.txt']);
      return utf8.decode(shown.files.single.content);
    }

    Future<SelectedTree> selectOneAndThree(List<String> left) => repo.selectTree(
      left: left,
      files: const [
        FileSelection.hunks('f.txt', [section1, section3]),
      ],
    );

    test('commit_with_sections_one_and_three_leaves_section_two_in_the_new_at', () async {
      final List<String> left = await leftOf(at);
      expect(left, hasLength(1));
      final SelectedTree tree = await selectOneAndThree(left);
      expect(tree.treeIds, hasLength(1));
      expect(tree.labels, isEmpty);

      final MutationResult result = await repo.commit(
        message: const ['first'],
        tree: TreeSelection.of(tree, left: left),
      );

      expect(await fileAt(at), fOneAndThree);
      expect(await fileAt(result.workingCopyChangeId), fRight, reason: 'hunk 2 remains in the new @');
    });

    test('a_stale_left_is_refused_with_jj_stale_selection', () async {
      final List<String> left = await leftOf(at);
      final SelectedTree tree = await selectOneAndThree(left);
      // The selected tree is not @'s parent tree: as `left` it is stale.
      final List<String> stale = tree.treeIds;

      await expectLater(
        repo.selectTree(left: stale, files: const [FileSelection.whole('f.txt')]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.stale_selection')),
      );
      await expectLater(
        repo.commit(
          message: const ['first'],
          tree: TreeSelection.of(tree, left: stale),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.stale_selection')),
      );
    });

    test('split_and_squash_take_the_tree_arm', () async {
      final List<String> left = await leftOf(at);
      final SelectedTree tree = await selectOneAndThree(left);
      final SplitResult split = await repo.split(
        message: const ['first'],
        tree: TreeSelection.of(tree, left: left),
      );
      expect(await fileAt(split.selectedChangeId), fOneAndThree);
      expect(await fileAt(split.remainingChangeId), fRight);

      // Squash the selected commit's sections 1 and 3 — all it holds — into `a`.
      final String selected = split.selectedChangeId;
      final List<String> selectedLeft = await leftOf(selected);
      final SelectedTree all = await repo.selectTree(
        revision: selected,
        left: selectedLeft,
        files: const [
          FileSelection.hunks('f.txt', [section1, section3]),
        ],
      );
      final MutationResult squashed = await repo.squash(
        from: [selected],
        into: a,
        message: const ['A\n'],
        trees: [
          SourceTree(
            source: selected,
            tree: TreeSelection.of(all, left: selectedLeft),
          ),
        ],
      );
      expect(await fileAt(a), fOneAndThree);
      expect(squashed.abandonedChangeIds, [selected]);
    });

    test('a_partial_squash_tree_leaves_the_unselected_section_in_the_source', () async {
      final List<String> left = await leftOf(at);
      final SelectedTree tree = await selectOneAndThree(left);
      final MutationResult squashed = await repo.squash(
        from: [at],
        into: a,
        message: const ['A\n'],
        trees: [
          SourceTree(
            source: at,
            tree: TreeSelection.of(tree, left: left),
          ),
        ],
      );
      expect(await fileAt(a), fOneAndThree);
      expect(await fileAt(at), fRight, reason: 'section 2 stays in the source');
      expect(squashed.abandonedChangeIds, isEmpty);
    });

    test('a_conflicted_trees_ids_and_labels_survive_select_tree_and_commit', () async {
      Future<String> side(String content, String message) async {
        await repo.newChange([a]);
        File('${tempDir.path}/c.txt').writeAsStringSync(content);
        final String id = (await repo.status()).workingCopyChangeId;
        await repo.describe(changeId: id, description: message);
        return id;
      }

      final String x = await side('x\n', 'X\n');
      final String y = await side('y\n', 'Y\n');
      await repo.newChange([x, y]);
      File('${tempDir.path}/other.txt').writeAsStringSync('o\n');
      final String merge = (await repo.status()).workingCopyChangeId;
      final List<String> left = await leftOf(merge);
      expect(left, hasLength(3), reason: 'the merge parents form a conflicted tree');

      const files = [FileSelection.whole('other.txt')];
      final SelectedTree tree = await repo.selectTree(left: left, files: files);
      expect(tree.treeIds, hasLength(3));
      expect(tree.labels, hasLength(3));
      expect(tree.labels.any((l) => l.isNotEmpty), isTrue);

      await repo.commit(
        message: const ['c'],
        tree: TreeSelection.of(tree, left: left),
      );
      // A whole-file pick on the committed revision rebuilds its own tree.
      final SelectedTree committed = await repo.selectTree(revision: merge, left: left, files: files);
      expect(committed.treeIds, tree.treeIds);
      expect(committed.labels, tree.labels);
    });

    test('a_squash_plan_carries_the_trees_through', () async {
      final List<String> left = await leftOf(at);
      final SelectedTree tree = await selectOneAndThree(left);
      // Trees together with paths are refused: proof the trees crossed the buffer.
      await expectLater(
        repo.squashPlan(
          trees: [
            SourceTree(
              source: at,
              tree: TreeSelection.of(tree, left: left),
            ),
          ],
          paths: const ['f.txt'],
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      await expectLater(repo.selectTree(left: const ['a\u0000b'], files: const []), throwsArgumentError);
      await expectLater(
        repo.selectTree(left: const ['x'], files: const [FileSelection.whole('a\u0000b')]),
        throwsArgumentError,
      );
      await expectLater(
        repo.commit(
          message: const ['m'],
          tree: const TreeSelection(treeIds: ['a\u0000b'], labels: [], left: ['x']),
        ),
        throwsArgumentError,
      );
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(() => other.selectTree(left: const [], files: const []), throwsStateError);
    });
  });
}
