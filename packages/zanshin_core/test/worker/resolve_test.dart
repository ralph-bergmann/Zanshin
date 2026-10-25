// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.17's `resolveList` and `resolve` on
// [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits the
// zanshin_resolve_list and zanshin_resolve extern "C" functions in the coverage
// ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — every request field
// crosses the buffer, the envelopes decode, refusals surface as
// ZanshinFfiException. The semantics are witnessed by the Rust suites
// (crates/zanshin-jj/tests/it/resolve.rs) and against the stock CLI by the
// parity oracle (crates/zanshin-parity).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/commit_views.dart' show ShowEntry;
import 'package:zanshin_core/src/ffi/file.dart' show FileContents;
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/resolve.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('RepoHandle resolveList / resolve round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change id of `@`, the merge of `x` and `y`, conflicted on c.txt.
    late String at;

    /// Change ids of the merge's sides and their base.
    late String a;
    late String x;
    late String y;

    /// A new change on [parents] holding [files], described [description].
    Future<String> add(List<String> parents, Map<String, String> files, String description) async {
      await repo.newChange(parents);
      files.forEach((path, text) => File('${tempDir.path}/$path').writeAsStringSync(text));
      final String id = (await repo.status()).workingCopyChangeId!;
      await repo.describe(changeId: id, description: description);
      return id;
    }

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_resolve_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/a.txt').writeAsStringSync('a\n');
      a = (await repo.status()).workingCopyChangeId!;
      await repo.describe(changeId: a, description: 'A\n');
      x = await add([a], {'c.txt': 'c from C\n'}, 'X\n');
      y = await add([a], {'c.txt': 'c from D\n'}, 'Y\n');
      at = await add([x, y], {}, 'M\n');
    });

    /// jj's conflict label of [changeId]: short change id, short commit id,
    /// quoted first description line.
    Future<String> label(String changeId) async {
      final ShowEntry entry = (await repo.show(revset: changeId)).single;
      final String line = entry.change.description.split('\n').first;
      return '${changeId.substring(0, 8)} ${entry.change.commitId.substring(0, 8)} "$line"';
    }

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<String> cAt(String revision) async {
      final FileContents shown = await repo.fileShow(revision: revision, paths: const ['c.txt']);
      return utf8.decode(shown.files.single.content);
    }

    test('resolve_list_returns_the_conflict_hunks_three_terms', () async {
      final ResolveList listed = await repo.resolveList();
      final ConflictedFile file = listed.files.single;
      expect(file.path, 'c.txt');
      expect(file.description, '2-sided conflict');
      expect(file.numSides, 2);
      expect(file.unresolvable, isNull);
      expect(file.labels, [await label(x), await label(a), await label(y)]);
      expect(file.hunks.single.terms.map(utf8.decode), ['c from C\n', '', 'c from D\n']);
      expect(file.termIds, hasLength(3));
      expect(file.termIds[0], isNotNull);
      expect(file.termIds[1], isNull, reason: 'the base has no c.txt');
      expect(file.termIds[2], isNotNull);
    });

    test('a_modify_delete_conflict_lists_the_deleted_side_as_null', () async {
      final String modify = await add([a], {'a.txt': 'x\n'}, 'MOD\n');
      await repo.newChange([a]);
      File('${tempDir.path}/a.txt').deleteSync();
      final String delete = (await repo.status()).workingCopyChangeId!;
      await add([modify, delete], {}, 'MD\n');
      final ConflictedFile file = (await repo.resolveList(paths: const ['a.txt'])).files.single;
      expect(file.description, '2-sided conflict including 1 deletion');
      expect(file.termIds, hasLength(3));
      expect(file.termIds[0], isNotNull, reason: 'the modifying side');
      expect(file.termIds[1], isNotNull, reason: "the base's a.txt");
      expect(file.termIds[2], isNull, reason: 'the deleting side');
    });

    test('a_conflict_changed_since_the_list_is_stale_and_empty_term_ids_are_invalid', () async {
      final List<String?> old = (await repo.resolveList()).files.single.termIds;
      await repo.edit(x);
      File('${tempDir.path}/c.txt').writeAsStringSync('c from E\n');
      await repo.edit(at);
      final merged = Uint8List.fromList(utf8.encode('merged\n'));
      await expectLater(
        repo.resolve(
          tool: ResolveFiles([ResolvedFile(path: 'c.txt', content: merged, termIds: old)]),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.stale_selection')),
      );
      expect((await repo.resolveList()).files.single.path, 'c.txt', reason: 'still conflicted: nothing written');
      await expectLater(
        repo.resolve(
          tool: ResolveFiles([ResolvedFile(path: 'c.txt', content: merged, termIds: const [])]),
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('revision_and_paths_cross_the_buffer_for_a_merge_that_is_not_at', () async {
      final String child = await add([at], {'n.txt': 'n\n'}, 'N\n');
      final ResolveList listed = await repo.resolveList(revision: at, paths: const ['c.txt']);
      expect(listed.files.single.path, 'c.txt');
      await expectLater(
        repo.resolveList(revision: at, paths: const ['a.txt']),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.no_conflicts')),
      );
      final MutationResult result = await repo.resolve(
        tool: const ResolveTheirs(),
        revision: at,
        paths: const ['c.txt'],
      );
      expect(result.workingCopyChangeId, child);
      expect(await cAt(at), 'c from D\n');
      expect(await cAt(child), 'c from D\n');
    });

    test('a_three_sided_conflict_is_unresolvable', () async {
      final String z = await add([a], {'c.txt': 'c from Z\n'}, 'Z\n');
      await add([x, y, z], {}, 'N\n');
      final ConflictedFile file = (await repo.resolveList()).files.single;
      expect(file.numSides, 3);
      expect(file.description, '3-sided conflict');
      expect(file.unresolvable, 'The conflict at "c.txt" has 3 sides. At most 2 sides are supported.');
      await expectLater(
        repo.resolve(tool: const ResolveOurs()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.conflict_not_resolvable')),
      );
    });

    test('resolve_ours_clears_the_conflict', () async {
      final MutationResult result = await repo.resolve(tool: const ResolveOurs(), paths: const ['c.txt']);
      expect(result.workingCopyChangeId, at);
      expect(await cAt(at), 'c from C\n');
      await expectLater(
        repo.resolveList(),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.no_conflicts')),
      );
    });

    test('resolve_theirs_and_files_cross_the_buffer', () async {
      final List<String?> termIds = (await repo.resolveList(revision: at)).files.single.termIds;
      await repo.resolve(
        tool: ResolveFiles([
          ResolvedFile(path: 'c.txt', content: Uint8List.fromList(utf8.encode('merged\n')), termIds: termIds),
        ]),
        revision: at,
      );
      expect(await cAt(at), 'merged\n');
      await expectLater(
        repo.resolve(tool: const ResolveTheirs()),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.no_conflicts')),
      );
    });

    test('files_with_paths_refuse_with_jj_invalid_input', () async {
      await expectLater(
        repo.resolve(
          tool: ResolveFiles([
            ResolvedFile(path: 'c.txt', content: Uint8List(0), termIds: const ['00']),
          ]),
          paths: const ['c.txt'],
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });
  });
}
