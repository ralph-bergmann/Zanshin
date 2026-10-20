// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.graphTopology] and
// [RepoHandle.graphTopology] (Story 4.12).
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib
// via @ffi.Native native assets. No mocked isolates, no mocked FFI
// (project-context: "Worker / isolate testing"). They are also what credits
// `zanshin_graph_topology` in the extern-coverage guard
// (mem:project-coverage-extern-fn-needs-zanshin-core-test).
//
// The wire's every row and the jj error ladder live in the Rust suites
// (crates/zanshin-ffi/src/graph.rs, crates/zanshin-ffi/tests/it/graph_ffi.rs). What
// these tests own is the DART half: the request crosses the buffer, the reply
// crosses the isolate boundary as ONE copy (a TransferResult) and reads through
// the lazy view, the topology continues into the op-pinned content call, the
// precondition is recorded, and the calling-side guards fire.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core]
// in Makefile.toml (project-context "Property of every test suite").

import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/change.dart' show Change;
import 'package:zanshin_core/src/ffi/commit_contents.dart' show CommitContent;
import 'package:zanshin_core/src/ffi/ffi_buffer.dart';
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/op_log.dart' show Operation;
import 'package:zanshin_core/src/ffi/warning.dart' show WarnedList;
import 'package:zanshin_core/src/worker/commands.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

const _nul = '\u0000';

void main() {
  group('ZanshinWorker.graphTopology round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_graph_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('graph_topology_on_fresh_init_returns_wc_then_root_and_continues_into_commit_contents', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      final Change wc = await handle.getChange((await handle.status()).workingCopyChangeId);

      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        anchors: defaultGraphAnchors,
        withTimestamps: false,
      );

      expect(view.nodeCount, 2, reason: 'fresh init = @ + root');
      expect(view.commitId(0), wc.commitId, reason: 'the working copy leads');
      expect(view.changeId(0), wc.id);
      expect(view.isWorkingCopy(0), isTrue);
      expect(view.isRoot(1), isTrue);
      expect(
        [view.anchorNodes(0), view.anchorNodes(1)],
        [
          [1],
          [0],
        ],
        reason: 'trunk() = root, present(@) = @',
      );
      expect(view.allCount, 2);
      final List<Operation> head = await handle.opLog(limit: 1);
      expect(view.operationId, head.single.id);
      expect([view.edgeStart(0), view.edgeEnd(0)], [0, 1]);
      expect(view.edgeTarget(0), 1);
      expect(view.edgeKind(0), GraphEdgeKind.direct);
      expect([view.parentCount(0), view.parentCount(1)], [1, 0]);
      expect(view.hasTimestamps, isFalse);
      expect(view.indexOfCommitId(wc.commitId), 0);
      expect(view.indicesOfChangeId(view.changeId(1)), [1]);
      expect(view.indexOfCommitId('f' * 40), isNull, reason: 'a commit id no node carries');
      expect(view.indicesOfChangeId('k' * 32), isEmpty, reason: 'a change id no node carries');

      final WarnedList<CommitContent> contents = await handle.commitContents(
        operationId: view.operationId,
        commitIds: [view.commitId(0)],
      );
      expect(contents.single.commitId, view.commitId(0), reason: 'the continuation at the topology operation');

      await handle.close();
    });

    test('graph_topology_with_timestamps_reads_every_non_root_timestamp', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final GraphTopologyView view = await handle.graphTopology(
        revset: 'all()',
        anchors: const [],
        withTimestamps: true,
      );

      expect(view.hasTimestamps, isTrue);
      expect(view.timestamp(0), greaterThan(0));
      expect(view.timestamp(1), isNull, reason: 'the root carries none');
      expect(view.anchorCount, 0);

      await handle.close();
    });

    test('graph_topology_reply_crosses_the_isolate_boundary_as_one_transferable_copy', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final WorkerResponse response = await worker.sendRaw(
        (id) => GraphTopologyCommand(
          commandId: id,
          handleId: handle.handleId,
          revset: 'all()',
          prioritize: defaultGraphPrioritize,
          shortPrefixes: defaultShortPrefixes,
          anchors: defaultGraphAnchors,
          withTimestamps: true,
        ),
      );

      expect(response, isA<TransferResult>());
      final Uint8List bytes = (response as TransferResult).data.materialize().asUint8List();
      final view = GraphTopologyView.fromEnvelope(bytes);
      expect(view.copiedVectorCount, 0, reason: 'the materialized bytes back the view directly');
      expect(view.nodeCount, 2);

      await handle.close();
    });

    test('graph_topology_records_the_precondition_of_its_snapshot', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      File('${tempDir.path}/edited.txt').writeAsStringSync('a working-copy edit');

      await handle.graphTopology(revset: 'all()', anchors: defaultGraphAnchors, withTimestamps: false);

      expect(handle.lastPrecondition?.wasSnapshotTaken, isTrue);
      await handle.close();
    });

    test('graph_topology_with_an_empty_revset_has_no_node', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final GraphTopologyView view = await handle.graphTopology(
        revset: 'none()',
        prioritize: 'none()',
        anchors: defaultGraphAnchors,
        withTimestamps: false,
      );

      expect(view.nodeCount, 0);
      expect(view.allCount, 2);
      expect(view.anchorNodes(0), isEmpty);
      await handle.close();
    });

    test('graph_topology_surfaces_each_jj_error_with_its_precondition', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphTopology(revset: 'bogus_function()', anchors: defaultGraphAnchors, withTimestamps: false),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.precondition, 'precondition', isNotNull),
        ),
      );
      await expectLater(
        handle.graphTopology(revset: 'all()', anchors: ['nonexistent-bookmark-xyz'], withTimestamps: false),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_resolution_error')),
      );
      await expectLater(
        handle.graphTopology(
          revset: 'all()',
          shortPrefixes: 'bogus_function()',
          anchors: const [],
          withTimestamps: false,
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_parse_error')),
      );
      // A valid revset with a bad `prioritize` proves the second string reaches
      // Rust as itself, not as a default or as another argument.
      await expectLater(
        handle.graphTopology(
          revset: 'all()',
          prioritize: 'bogus_function()',
          anchors: const [],
          withTimestamps: false,
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_parse_error')),
      );
      await expectLater(
        handle.graphTopology(
          revset: 'all()',
          prioritize: 'nonexistent-bookmark-xyz',
          anchors: const [],
          withTimestamps: false,
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_resolution_error')),
      );

      await handle.close();
    });

    test('graph_topology_rejects_interior_nuls_on_the_calling_side', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      Future<GraphTopologyView> call({
        String revset = 'all()',
        String prioritize = defaultGraphPrioritize,
        String shortPrefixes = defaultShortPrefixes,
        List<String> anchors = defaultGraphAnchors,
      }) => worker.graphTopology(
        handle.handleId,
        revset: revset,
        prioritize: prioritize,
        shortPrefixes: shortPrefixes,
        anchors: anchors,
        withTimestamps: false,
      );

      await expectLater(call(revset: 'a${_nul}b'), throwsArgumentError);
      await expectLater(call(prioritize: 'a${_nul}b'), throwsArgumentError);
      await expectLater(call(shortPrefixes: 'a${_nul}b'), throwsArgumentError);
      await expectLater(call(anchors: ['trunk()', 'a${_nul}b']), throwsArgumentError);
      expect(handle.lastPrecondition, isNull, reason: 'nothing reached the worker');

      await handle.close();
    });

    test('unknown_handle_id_surfaces_ffi_invalid_handle', () async {
      await expectLater(
        worker.graphTopology(
          9999,
          revset: 'all()',
          prioritize: defaultGraphPrioritize,
          shortPrefixes: defaultShortPrefixes,
          anchors: defaultGraphAnchors,
          withTimestamps: false,
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
    });

    test('graph_topology_on_a_closed_handle_throws_state_error_synchronously', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();

      expect(
        () => handle.graphTopology(revset: 'all()', anchors: defaultGraphAnchors, withTimestamps: false),
        throwsStateError,
      );
    });
  });

  group('zanshinGraphTopology adapter (direct, no worker)', () {
    test('rejects an interior NUL in every expression before calling Rust', () {
      FfiBuffer call({
        String revset = 'all()',
        String prioritize = defaultGraphPrioritize,
        String shortPrefixes = defaultShortPrefixes,
        List<String> anchors = defaultGraphAnchors,
      }) => zanshinGraphTopology(
        0,
        revset: revset,
        prioritize: prioritize,
        shortPrefixes: shortPrefixes,
        anchors: anchors,
        withTimestamps: false,
      );

      expect(() => call(revset: 'a${_nul}b'), throwsArgumentError);
      expect(() => call(prioritize: 'a${_nul}b'), throwsArgumentError);
      expect(() => call(shortPrefixes: 'a${_nul}b'), throwsArgumentError);
      expect(() => call(anchors: ['a${_nul}b']), throwsArgumentError);
    });

    test('a view over the native reply of a zero handle throws ffi.invalid_handle', () {
      final FfiBuffer buf = zanshinGraphTopology(
        0,
        revset: 'all()',
        prioritize: defaultGraphPrioritize,
        shortPrefixes: defaultShortPrefixes,
        anchors: defaultGraphAnchors,
        withTimestamps: false,
      );
      try {
        expect(
          () => GraphTopologyView.fromEnvelope(buf.bytes),
          throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
        );
      } finally {
        buf.dispose();
      }
    });
  });
}
