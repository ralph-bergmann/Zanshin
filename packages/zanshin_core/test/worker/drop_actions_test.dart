// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.31's two queries, drop actions and change
// actions, on [RepoHandle].
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). Mirrors
// test/worker/squash_split_test.dart. They are also what credits the
// zanshin_drop_actions / zanshin_change_actions extern "C" functions in the
// coverage ratchet's extern-fn guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// What these tests own is the DART half of the chain — that the source and the
// locations cross the request buffer, that both envelopes decode with the verb,
// location index, status, refusal code/context and both flags, and that a
// malformed location surfaces as a ZanshinFfiException. The rows' semantics are
// witnessed by the Rust suite (crates/zanshin-jj/tests/it/drop_actions.rs).
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/drop_actions.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

typedef Row = (DropVerb, int, ActionStatus, String?, String?, bool, bool);

Row row(DropAction a) => (
  a.verb,
  a.location,
  a.outcome.status,
  a.outcome.refusal?.code,
  a.outcome.refusal?.context,
  a.outcome.combinedDescriptionNeeded,
  a.outcome.allowBackwardsNeeded,
);

const unknown = 'qpvuntsmwlqtpvuntsmwlqtpvuntsm';

void main() {
  group('RepoHandle drop actions / change actions round-trips (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;
    late RepoHandle repo;

    /// Change ids of `A (a.txt) → B (b.txt) → C (c.txt, c2.txt) = @`.
    late List<String> ids;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_drop_actions_test_');
      worker = await ZanshinWorker.start();
      repo = await worker.initRepo(tempDir.path, backend: 0);
      ids = [];
      for (final (files, description) in [
        (const {'a.txt': 'a\n'}, 'A\n'),
        (const {'b.txt': 'b\n'}, 'B\n'),
        (const {'c.txt': 'c\n', 'c2.txt': 'c2\n'}, 'C\n'),
      ]) {
        if (ids.isNotEmpty) {
          await repo.newChange([ids.last]);
        }
        files.forEach((path, text) => File('${tempDir.path}/$path').writeAsStringSync(text));
        final String at = (await repo.status()).workingCopyChangeId!;
        await repo.describe(changeId: at, description: description);
        ids.add(at);
      }
      await repo.bookmarkCreate(const ['mark'], revision: ids[1]);
    });

    tearDown(() async {
      await repo.close();
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a_change_source_answers_every_row_of_every_location', () async {
      final DropActions actions = await repo.dropActions(ChangeDropSource(ids[2]), [
        DropLocation(onto: [ids[1]]),
        DropLocation(onto: [ids[2]]),
        DropLocation(insertAfter: [ids[0]]),
      ]);

      expect(actions.warnings, isEmpty);
      final List<Row> rows = actions.actions.map(row).toList();
      expect(rows.sublist(0, 10), [
        (DropVerb.rebaseSource, 0, ActionStatus.noOp, null, null, false, false),
        (DropVerb.rebaseRevisions, 0, ActionStatus.noOp, null, null, false, false),
        (DropVerb.squash, 0, ActionStatus.available, null, null, true, false),
        (DropVerb.newMerge, 0, ActionStatus.available, null, null, false, false),
        (DropVerb.duplicate, 0, ActionStatus.available, null, null, false, false),
        (DropVerb.rebaseBranch, 0, ActionStatus.noOp, null, null, false, false),
        (DropVerb.revert, 0, ActionStatus.available, null, null, false, false),
        (DropVerb.restore, 0, ActionStatus.available, null, null, false, false),
        (DropVerb.absorb, 0, ActionStatus.noOp, null, null, false, false),
        (DropVerb.interdiff, 0, ActionStatus.available, null, null, false, false),
      ]);
      expect(rows[10].$1, DropVerb.rebaseSource);
      expect(rows[10].$2, 1);
      expect(rows[10].$3, ActionStatus.refused);
      expect(rows[10].$4, 'jj.invalid_input');
      expect(rows[10].$5, matches(RegExp(r'^Cannot rebase [0-9a-f]{12} onto itself$')));
      expect(rows[12], (DropVerb.squash, 1, ActionStatus.noOp, null, null, false, false));
      expect(rows.sublist(15, 20), [
        (DropVerb.rebaseBranch, 1, ActionStatus.noOp, null, null, false, false),
        (DropVerb.revert, 1, ActionStatus.available, null, null, false, false),
        (DropVerb.restore, 1, ActionStatus.noOp, null, null, false, false),
        (DropVerb.absorb, 1, ActionStatus.noOp, null, null, false, false),
        (DropVerb.interdiff, 1, ActionStatus.available, null, null, false, false),
      ]);
      expect(rows.sublist(20), [
        (DropVerb.rebaseRevisions, 2, ActionStatus.available, null, null, false, false),
        (DropVerb.revert, 2, ActionStatus.available, null, null, false, false),
      ]);
      expect(rows, hasLength(22));
    });

    test('selection_and_bookmark_sources_cross_the_buffer', () async {
      final DropActions selection = await repo.dropActions(SelectionDropSource(ids[2], const ['c.txt']), [
        DropLocation(onto: [ids[1]]),
        DropLocation(insertBefore: [ids[1]]),
      ]);
      expect(selection.actions.map(row), [
        (DropVerb.squash, 0, ActionStatus.available, null, null, false, false),
        (DropVerb.split, 1, ActionStatus.available, null, null, false, false),
      ]);

      final DropActions bookmark = await repo.dropActions(const BookmarkDropSource('mark'), [
        DropLocation(onto: [ids[2]]),
        DropLocation(onto: [ids[0]]),
        DropLocation(onto: [ids[1]]),
      ]);
      expect(bookmark.actions.map(row), [
        (DropVerb.bookmarkMove, 0, ActionStatus.available, null, null, false, false),
        (DropVerb.bookmarkMove, 1, ActionStatus.available, null, null, false, true),
        (DropVerb.bookmarkMove, 2, ActionStatus.noOp, null, null, false, false),
      ]);

      final DropActions missing = await repo.dropActions(const ChangeDropSource(unknown), [
        DropLocation(insertAfter: [ids[0]]),
      ]);
      expect(missing.actions.map(row), [
        (DropVerb.rebaseRevisions, 0, ActionStatus.refused, 'jj.change_not_found', unknown, false, false),
        (DropVerb.revert, 0, ActionStatus.refused, 'jj.change_not_found', unknown, false, false),
      ]);
    });

    test('a_malformed_location_refuses_the_whole_call', () async {
      await expectLater(
        repo.dropActions(ChangeDropSource(ids[2]), [
          DropLocation(onto: [ids[1]], insertAfter: [ids[0]]),
        ]),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.invalid_input')
              .having(
                (e) => e.context,
                'context',
                '--onto cannot be combined with -A/--insert-after or -B/--insert-before',
              ),
        ),
      );
      await expectLater(
        repo.dropActions(ChangeDropSource(ids[2]), const [DropLocation()]),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.invalid_input')),
      );
    });

    test('change_actions_answers_the_seven_card_rows', () async {
      final ChangeActions card = await repo.changeActions(ids[1]);
      final List<ActionOutcome> all = [
        card.newOnto,
        card.newInsertAfter,
        card.newInsertBefore,
        card.edit,
        card.describe,
        card.squashIntoParent,
        card.abandon,
      ];
      expect(all.map((o) => o.status), everyElement(ActionStatus.available));
      expect(all.map((o) => o.combinedDescriptionNeeded), [false, false, false, false, false, true, false]);
      expect(card.warnings, isEmpty);

      final ChangeActions missing = await repo.changeActions(unknown);
      expect(missing.edit.status, ActionStatus.refused);
      expect(missing.edit.refusal?.code, 'jj.change_not_found');
      expect(missing.edit.refusal?.context, unknown);
    });

    test('interior_nuls_are_refused_on_the_calling_side', () async {
      await expectLater(repo.dropActions(const ChangeDropSource('a\u0000b'), const []), throwsArgumentError);
      await expectLater(repo.changeActions('a\u0000b'), throwsArgumentError);
    });

    test('a_closed_handle_refuses_synchronously', () async {
      final RepoHandle other = await worker.openRepo(tempDir.path);
      await other.close();
      expect(() => other.dropActions(ChangeDropSource(ids[2]), const []), throwsStateError);
      expect(() => other.changeActions(ids[2]), throwsStateError);
    });
  });
}
