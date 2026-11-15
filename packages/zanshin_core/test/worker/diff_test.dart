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
import 'package:zanshin_core/src/ffi/status.dart' show FileChangeKind;
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
      expect(diff.commitIds.single, isNotEmpty);
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
      expect(defaulted.commitIds, diff.commitIds, reason: 'no revision = @');
    });

    test('every_line_carries_its_word_level_segments', () async {
      final Diff diff = await repo.diff(revision: at);
      final List<HunkLine> lines = [
        for (final FileDiff file in diff.files)
          for (final Hunk hunk in file.hunks) ...hunk.lines,
      ];
      expect(lines, isNotEmpty);
      for (final line in lines) {
        expect(line.segments, isNotEmpty, reason: line.text);
        expect(line.segments.map((s) => s.text).join(), line.text);
      }

      List<(SegmentKind, String)> segmentsOf(String path, String text) {
        final HunkLine line = fileOf(diff, path).hunks.expand((h) => h.lines).singleWhere((l) => l.text == text);
        return [for (final Segment s in line.segments) (s.kind, s.text)];
      }

      // `a` → `A` is one inlined line holding both words, with both line numbers.
      expect(segmentsOf('f.txt', 'aA\n'), [
        (SegmentKind.removed, 'a'),
        (SegmentKind.added, 'A'),
        (SegmentKind.equal, '\n'),
      ]);
      final HunkLine changed = fileOf(diff, 'f.txt').hunks.first.lines.first;
      expect((changed.kind, changed.left, changed.right), (HunkLineKind.changed, 1, 1));
      expect(segmentsOf('f.txt', 'b\n'), [(SegmentKind.equal, 'b\n')]);
      // jj compares spaces one by one: one space is added to the line.
      expect(segmentsOf('w.txt', 'x  y\n').where((s) => s.$1 != SegmentKind.equal), [(SegmentKind.added, ' ')]);
    });

    test('a_range_diffs_as_one_and_pins_its_heads', () async {
      final Diff range = await repo.diff(revision: '$a::$at');
      expect(range.commitIds, (await repo.diff(revision: at)).commitIds, reason: 'one head: @');
      expect(range.files.map((f) => f.path), ['f.txt', 'w.txt'], reason: 'from the empty tree');
      expect(range.files.map((f) => f.kind), everyElement(FileChangeKind.added));
      expect((await repo.diff(revision: 'none()')).commitIds, isEmpty);
      await expectLater(
        repo.diff(revision: 'root() | $at'),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('from_and_to_select_the_from_to_form', () async {
      final Diff revision = await repo.diff(revision: at);
      final Diff fromTo = await repo.diff(from: a, to: at);
      expect(fromTo.fromCommitId, isNotNull);
      expect(fromTo.commitIds, revision.commitIds);
      expect(fileOf(fromTo, 'f.txt').sections, fileOf(revision, 'f.txt').sections);
      final Diff fromOnly = await repo.diff(from: a);
      expect(fromOnly.commitIds, revision.commitIds, reason: 'an absent to is @');
      expect(fromTo.fromCommitId, (await repo.diff(revision: a)).commitIds.single);

      // Move `@` off `at`, so `to: at` differs from an absent `to`.
      await repo.newChange([at]);
      final Diff moved = await repo.diff(from: a, to: at);
      expect(moved.commitIds, (await repo.diff(revision: at)).commitIds);
      expect(moved.commitIds, isNot((await repo.diff()).commitIds));
    });

    test('paths_context_whitespace_and_summary_cross_the_buffer', () async {
      final Diff onlyF = await repo.diff(revision: at, paths: const ['f.txt'], context: 0);
      expect(onlyF.files.map((f) => f.path), ['f.txt']);
      // At context 0 the one-line gaps are shown whole, as the CLI does: one hunk.
      expect(onlyF.files.single.hunks, hasLength(1));

      final Diff exact = await repo.diff(revision: at, paths: const ['w.txt']);
      expect(exact.files.single.hunks.single.lines.single.kind, HunkLineKind.changed);
      for (final DiffWhitespace ws in [DiffWhitespace.ignoreAllSpace, DiffWhitespace.ignoreSpaceChange]) {
        final Diff ignoring = await repo.diff(revision: at, paths: const ['w.txt'], whitespace: ws);
        expect(
          ignoring.files.expand((f) => f.hunks).expand((h) => h.lines).map((l) => l.kind),
          everyElement(HunkLineKind.context),
          reason: '$ws shows a whitespace-only change as context',
        );
        // Story 10.41: the whitespace-only pair with jj's marks.
        final HunkLine pair = ignoring.files.single.whitespaceLines.single;
        expect((pair.kind, pair.left, pair.right, pair.text), (HunkLineKind.context, 1, 1, 'x  y\n'));
        expect(pair.segments.map((s) => (s.kind, s.text)), [
          (SegmentKind.equal, 'x '),
          (SegmentKind.added, ' '),
          (SegmentKind.equal, 'y\n'),
        ]);
      }
      expect(exact.files.single.whitespaceLines, isEmpty);

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

    test('interdiff_crosses_the_buffer_and_shows_only_the_rebased_change', () async {
      final String before = (await repo.diff(revision: at)).commitIds.single;
      // Rewrite `a` under `@`: `at` is rebased, its own change untouched.
      await repo.edit(a);
      File('${tempDir.path}/g.txt').writeAsStringSync('g\n');
      final Diff fromTo = await repo.diff(from: before, to: at);
      expect(fromTo.files.map((f) => f.path), ['g.txt']);
      final Diff inter = await repo.diff(from: before, to: at, interdiff: true);
      expect(inter.files, isEmpty, reason: 'only the rebase changed it');
      expect(inter.fromCommitId, before);
      expect(inter.commitIds, fromTo.commitIds);
      expect(inter.description, isNull, reason: 'the rebase kept the description');
      await expectLater(
        repo.diff(interdiff: true),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having((e) => e.context, 'context', contains('at least one of `from` or `to` is required')),
        ),
      );
      await expectLater(
        repo.diff(revision: at, from: a, interdiff: true),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('a_created_commit_crosses_the_buffer_with_its_description', () async {
      final Diff created = await repo.diff(revision: a, interdiff: true);
      final Diff revision = await repo.diff(revision: a);
      expect(created.commitIds, revision.commitIds);
      expect(created.fromCommitId, isNull);
      expect(created.files.map((f) => f.path), revision.files.map((f) => f.path));
      final FileDiff description = created.description!;
      expect(description.path, 'JJ-COMMIT-DESCRIPTION');
      expect(description.kind, FileChangeKind.modified);
      expect(description.hunks.single.lines.map((l) => (l.kind, l.text)), [(HunkLineKind.added, 'A\n')]);
      expect(revision.description, isNull, reason: 'jj diff has no description block');
      expect((await repo.diff(revision: at, interdiff: true)).description, isNull, reason: 'no description');
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

    test('a_context_beyond_32_bits_is_refused_on_the_calling_side', () async {
      await expectLater(repo.diff(context: 1 << 32), throwsArgumentError);
      expect(() => zanshinDiff(0, context: 1 << 32), throwsArgumentError);
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(other.diff, throwsStateError);
      expect(() => other.diffLines(path: 'f.txt', start: 0, end: 1), throwsStateError);
    });

    // Story 10.43: the left side's line count and the on-demand read of unchanged lines.

    test('left_line_count_crosses_the_buffer', () async {
      final Diff diff = await repo.diff(revision: at, summary: true);
      expect(fileOf(diff, 'f.txt').leftLineCount, 5);
      expect(fileOf(diff, 'w.txt').leftLineCount, 1);
    });

    test('diff_lines_return_the_unchanged_lines_in_the_left_range', () async {
      final List<HunkLine> lines = await repo.diffLines(revision: at, path: 'f.txt', start: 0, end: 5);
      expect(lines.map((l) => (l.kind, l.left, l.right, l.text)), [
        (HunkLineKind.context, 2, 2, 'b\n'),
        (HunkLineKind.context, 4, 4, 'd\n'),
      ]);
      expect(lines.first.segments.map((s) => (s.kind, s.text)), [(SegmentKind.equal, 'b\n')]);
      final List<HunkLine> fromTo = await repo.diffLines(from: a, to: at, path: 'f.txt', start: 3, end: 100);
      expect(fromTo.map((l) => l.left), [4], reason: 'from / to cross; the range is clipped');
      final List<HunkLine> created = await repo.diffLines(
        revision: at,
        interdiff: true,
        path: 'f.txt',
        start: 0,
        end: 2,
      );
      expect(created.map((l) => l.left), [2]);

      // `-w`: the whitespace-only pair is a context line with jj's marks; exact has none.
      final List<HunkLine> ignoring = await repo.diffLines(
        revision: at,
        path: 'w.txt',
        whitespace: DiffWhitespace.ignoreAllSpace,
        start: 0,
        end: 1,
      );
      expect(ignoring.single.segments.map((s) => (s.kind, s.text)), [
        (SegmentKind.equal, 'x '),
        (SegmentKind.added, ' '),
        (SegmentKind.equal, 'y\n'),
      ]);
      expect(await repo.diffLines(revision: at, path: 'w.txt', start: 0, end: 1), isEmpty);
    });

    test('diff_lines_refusals', () async {
      await expectLater(
        repo.diffLines(revision: at, from: a, path: 'f.txt', start: 0, end: 1),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
      await expectLater(repo.diffLines(path: 'a\u0000b', start: 0, end: 1), throwsArgumentError);
      await expectLater(repo.diffLines(path: 'f.txt', start: -1, end: 1), throwsArgumentError);
      await expectLater(repo.diffLines(path: 'f.txt', start: 0, end: 1 << 32), throwsArgumentError);
      expect(() => zanshinDiffLines(0, path: 'a\u0000b', start: 0, end: 1), throwsArgumentError);
      expect(() => zanshinDiffLines(0, path: 'f.txt', start: -1, end: 1), throwsArgumentError);
    });
  });
}
