// SPDX-License-Identifier: MIT

// Worker round-trip tests for Story 9.25's op-pinned graph searches, on both
// [ZanshinWorker] (through [RepoHandle]) and the real cdylib.
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI. They are
// also what credits the zanshin_revset_counts and zanshin_find_changes extern
// "C" functions in the coverage ratchet's extern-fn guard.
//
// The full I/O matrix lives in the Rust suites
// (crates/zanshin-jj/tests/it/revset_search.rs,
// crates/zanshin-ffi/tests/it/revset_search_ffi.rs). What these tests own is
// the DART half: the request fields cross the buffer, the payloads decode, a
// failed count carries its own exception with its revsetError, call-level
// errors throw with the warnings collected before them, and lastPrecondition
// stays unchanged.

import 'dart:io';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/precondition.dart';
import 'package:zanshin_core/src/ffi/revset_search.dart';
import 'package:zanshin_core/src/ffi/warning.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

void main() {
  group('ZanshinWorker revset searches (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_revset_search_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<RepoHandle> medium() async {
      final ProcessResult tar = await Process.run('tar', [
        '-xf',
        '../../test-fixtures/repos/medium-1k-commits.tar.zst',
        '-C',
        tempDir.path,
      ]);
      expect(tar.exitCode, 0, reason: '${tar.stderr}');
      return worker.openRepo(tempDir.path);
    }

    test('revset_counts_answer_per_entry_and_leave_last_precondition_unchanged', () async {
      final RepoHandle handle = await medium();
      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        anchors: const [],
        withTimestamps: false,
      );
      final Precondition? before = handle.lastPrecondition;
      File('${tempDir.path}/edited.txt').writeAsStringSync('not yet snapshotted');
      List<String> listing(String dir) =>
          Directory('${tempDir.path}/.jj/repo/$dir').listSync().map((e) => e.path).toList()..sort();
      final List<String> opsBefore = listing('op_store/operations');
      final List<String> headsBefore = listing('op_heads/heads');

      final RevsetCounts counts = await handle.revsetCounts(view.operationId, [
        'all()',
        'all()',
        'nonexistent_bookmark',
        'fooo()',
        'description("x',
        'description(regex:"(")',
      ], cap: 5);

      expect(counts.map((c) => (c.n, c.capped)).take(2), [(5, true), (5, true)]);
      expect(counts[0].error, isNull);
      expect(counts[2].error?.code, 'jj.revset_resolution_error');
      expect(counts[2].error?.revsetError?.kind, RevsetErrorKind.noSuchRevision);
      expect(counts[2].error?.revsetError?.symbol, 'nonexistent_bookmark');
      final ZanshinFfiException? parse = counts[3].error;
      expect(parse?.code, 'jj.revset_parse_error');
      expect(parse?.revsetError?.kind, RevsetErrorKind.noSuchFunction);
      expect(parse?.revsetError?.span?.offset, 0);
      expect(parse?.revsetError?.span?.length, 4);
      final RevsetErrorDetail? unclosed = counts[4].error?.revsetError;
      expect(unclosed?.kind, RevsetErrorKind.syntaxError);
      expect((unclosed?.span?.offset, unclosed?.span?.length), (14, 0), reason: 'a position');
      final RevsetErrorDetail? regex = counts[5].error?.revsetError;
      expect(regex?.kind, RevsetErrorKind.expression);
      expect((regex?.span?.offset, regex?.span?.length), (12, 9), reason: 'the pattern argument');
      expect(counts.warnings, isEmpty);
      expect(handle.lastPrecondition, same(before), reason: 'the pinned read runs no precondition');

      final RevsetCounts all = await handle.revsetCounts(view.operationId, ['all()'], cap: 100000);
      expect(all.single.n, view.nodeCount);
      expect(all.single.capped, isFalse);
      await handle.findChanges(view.operationId, 'all()', limit: 3, shortPrefixes: '');
      expect(listing('op_store/operations'), opsBefore, reason: 'no operation written');
      expect(listing('op_heads/heads'), headsBefore, reason: 'op heads untouched');
      expect(handle.lastPrecondition, same(before));

      // The next topology call still snapshots the edit.
      await handle.graphTopology(revset: 'all()', anchors: const [], withTimestamps: false);
      expect(handle.lastPrecondition?.wasSnapshotTaken, isTrue);
      await handle.close();
    });

    test('find_changes_answers_in_order_truncates_and_refuses_an_ambiguous_prefix', () async {
      final RepoHandle handle = await medium();
      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        anchors: const [],
        withTimestamps: false,
        shortPrefixes: '',
      );
      final Precondition? before = handle.lastPrecondition;

      final FoundChanges found = await handle.findChanges(view.operationId, 'all()', limit: 3, shortPrefixes: '');

      expect(found.truncated, isTrue);
      expect(found.entries, hasLength(3));
      expect(found.warnings, isEmpty);
      final Map<String, int> nodeOf = {for (var i = 0; i < view.nodeCount; i++) view.commitId(i): i};
      for (final FoundChange entry in found.entries) {
        final int i = nodeOf[entry.commitId]!;
        expect(entry.changeId, view.changeId(i));
        expect(entry.commitPrefixLen, view.commitIdPrefixLength(i));
        expect(entry.changePrefixLen, view.changeIdPrefixLength(i));
      }
      expect(handle.lastPrecondition, same(before));

      await expectLater(
        handle.findChanges(view.operationId, 'change_id(k)', limit: 3, shortPrefixes: ''),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_resolution_error')
              .having((e) => e.context, 'context', 'Change ID prefix `k` is ambiguous')
              .having((e) => e.revsetError?.kind, 'kind', RevsetErrorKind.ambiguousChangeIdPrefix)
              .having((e) => e.revsetError?.symbol, 'symbol', 'k')
              .having((e) => e.revsetError?.span, 'span', isNull)
              .having((e) => e.precondition, 'precondition', isNull),
        ),
      );
      await expectLater(
        handle.findChanges('f' * view.operationId.length, 'all()', limit: 3, shortPrefixes: ''),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.operation_not_found')),
      );
      await handle.close();
    });

    test('find_changes_passes_its_short_prefixes_through', () async {
      final RepoHandle handle = await medium();
      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        anchors: const [],
        withTimestamps: false,
      );
      final FoundChange tip = (await handle.findChanges(
        view.operationId,
        'tip',
        limit: 1,
        shortPrefixes: '',
      )).entries.single;
      final String prefix = tip.changeId.substring(0, 1);

      await expectLater(
        handle.findChanges(view.operationId, prefix, limit: 10, shortPrefixes: ''),
        throwsA(
          isA<ZanshinFfiException>().having(
            (e) => e.revsetError?.kind,
            'kind',
            RevsetErrorKind.ambiguousChangeIdPrefix,
          ),
        ),
      );
      final FoundChanges found = await handle.findChanges(view.operationId, prefix, limit: 10, shortPrefixes: 'tip');
      expect(found.entries.map((e) => (e.commitId, e.changePrefixLen)), [(tip.commitId, 1)]);
      await handle.close();
    });

    test('a_call_level_failure_keeps_the_warnings_collected_before_it', () async {
      final RepoHandle handle = await medium();
      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        anchors: const [],
        withTimestamps: false,
      );

      await expectLater(
        handle.findChanges(view.operationId, 'bogus(', limit: 1, shortPrefixes: 'diff_contains("x")'),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.revsetError?.kind, 'kind', RevsetErrorKind.syntaxError)
              .having((e) => e.warnings.map((w) => w.code), 'warnings', [ZanshinWarningCode.revsetDiagnostic])
              .having((e) => e.warnings.single.message, 'message', startsWith('In `revsets.short-prefixes`\n')),
        ),
      );

      File('${tempDir.path}/.jj/repo/config.toml').writeAsStringSync(
        "[revset-aliases]\n'bad(' = 'x'\n[revsets]\nshort-prefixes = \"bogus(\"\n",
      );
      await expectLater(
        handle.revsetCounts(view.operationId, const ['all()'], cap: 1),
        throwsA(
          isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.config_error').having(
            (e) => e.warnings.map((w) => w.code),
            'warnings',
            [ZanshinWarningCode.configAliasInvalid],
          ),
        ),
      );
      await handle.close();
    });

    test('the_calling_side_guards_fire_before_the_worker', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(handle.revsetCounts('a\u0000b', const [], cap: 1), throwsArgumentError);
      await expectLater(handle.revsetCounts('ab', const ['x\u0000'], cap: 1), throwsArgumentError);
      await expectLater(handle.revsetCounts('ab', const [], cap: -1), throwsArgumentError);
      await expectLater(handle.findChanges('ab', 'x\u0000', limit: 1, shortPrefixes: ''), throwsArgumentError);
      await expectLater(handle.findChanges('ab', 'x', limit: -1, shortPrefixes: ''), throwsArgumentError);
      await handle.close();
      expect(() => handle.revsetCounts('ab', const [], cap: 1), throwsStateError);
      expect(() => handle.findChanges('ab', 'x', limit: 1, shortPrefixes: ''), throwsStateError);
    });
  });
}
