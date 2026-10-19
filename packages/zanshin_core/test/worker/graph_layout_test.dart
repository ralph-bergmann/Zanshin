// SPDX-License-Identifier: MIT

// Worker round-trip tests for [ZanshinWorker.graphLayout] and [RepoHandle.graphLayout]
// (Story 4.11): the topology call and the Dart layout engine on the worker isolate, end to end.
//
// These tests boot the REAL Isolate.spawn flow against the REAL compiled cdylib (no mocked
// isolates, no mocked FFI; project-context "Worker / isolate testing"). On the committed fixtures
// the grid equals the goldens tools/goldens.mjs wrote from the spike's references, and the input
// the builder makes of the topology equals the spike dumper's input — the same jj facts through
// Repo::graph_topology on both sides. The engine itself is tested in test/graph_layout/.
//
// JJ_CONFIG / GIT_CONFIG_GLOBAL are pinned externally by [tasks.test-core] in Makefile.toml
// (project-context "Property of every test suite").

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:zanshin_core/src/ffi/graph.dart';
import 'package:zanshin_core/src/ffi/mutate.dart' show MutationResult;
import 'package:zanshin_core/src/ffi/warning.dart' show ZanshinWarningCode;
import 'package:zanshin_core/src/graph_layout/graph_grid_view.dart';
import 'package:zanshin_core/src/graph_layout/input_builder.dart';
import 'package:zanshin_core/src/graph_layout/layout_engine.dart';
import 'package:zanshin_core/src/graph_layout/layout_request.dart';
import 'package:zanshin_core/src/worker/commands.dart';
import 'package:zanshin_core/src/worker/handle.dart';
import 'package:zanshin_core/src/worker/isolate.dart';
import 'package:zanshin_core/src/worker/responses.dart';

import '../graph_layout/support/spec_json.dart';

const _nul = '\u0000';
const _goldens = 'test/graph_layout/goldens';

/// The fixture dumps' revset over medium-1k-commits (the spike dumper's NARROW_REVSET).
const _narrow = r'(description(glob:"Branch[AB]-*") | merge::) ~ description(glob:"*[37]")';

typedef Layout = ({GraphTopologyView topology, GraphGridView grid});

/// Builds the DAG [commits] — each `(name, parent names)`, oldest first, `root` the root
/// commit — in [handle]'s repo: one `newChange` per commit, described with its name so moving `@`
/// on does not abandon it. `@` ends on the last commit.
Future<void> buildDag(RepoHandle handle, List<(String, List<String>)> commits) async {
  final GraphTopologyView root = await handle.graphTopology(revset: 'root()', anchors: const [], withTimestamps: false);
  final ids = <String, String>{'root': root.changeId(0)};
  for (final (String name, List<String> parents) in commits) {
    final MutationResult created = await handle.newChange([for (final p in parents) ids[p]!]);
    await handle.describe(changeId: created.workingCopyChangeId, description: name);
    ids[name] = created.workingCopyChangeId;
  }
}

void main() {
  group('RepoHandle.graphLayout round-trip (real cdylib)', () {
    late ZanshinWorker worker;
    late Directory tempDir;

    setUp(() async {
      tempDir = Directory.systemTemp.createTempSync('zanshin_graph_layout_test_');
      worker = await ZanshinWorker.start();
    });

    tearDown(() async {
      await worker.close();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('a_fresh_init_lays_out_at_above_the_root_with_one_day_bucket', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final Layout layout = await handle.graphLayout(revset: 'all()', anchors: defaultGraphAnchors, utcOffsetMin: 0);

      final GraphTopologyView topology = layout.topology;
      final GraphGridView grid = layout.grid;
      expect(topology.nodeCount, 2, reason: 'fresh init = @ + root');
      expect(topology.hasTimestamps, isTrue, reason: 'free, the default, needs the timestamps');
      expect([grid.mode, grid.order, grid.nodeCount, grid.lanes], [LayoutMode.free, LaneOrder.compact, 2, 1]);
      expect(grid.bucketCount, 1);
      expect(grid.bucketKinds[0], GraphGridView.bucketKindDay);
      final int at = grid.nodeRows[0];
      final int root = grid.nodeRows[1];
      expect(grid.bucketStarts[0] <= at && at <= grid.bucketEnds[0], isTrue, reason: "@'s row is in its day");
      expect(grid.bucketStarts[0] <= root && root <= grid.bucketEnds[0], isFalse, reason: 'the root is in none');
      expect(handle.lastPrecondition, isNotNull, reason: "the topology call's snapshot report");

      await handle.close();
    });

    test('an_empty_revset_lays_out_nothing_in_every_mode_and_order', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          final Layout layout = await handle.graphLayout(
            revset: 'none()',
            anchors: defaultGraphAnchors,
            utcOffsetMin: 0,
            mode: mode,
            order: order,
          );
          final GraphGridView grid = layout.grid;
          expect(
            [grid.nodeCount, grid.rows, grid.lanes, grid.edgeCount, grid.bucketCount],
            [0, 0, 0, 0, 0],
            reason: '${mode.name} ${order.name}',
          );
        }
      }

      await handle.close();
    });

    test('the_reply_crosses_as_two_transferables_and_repeats_byte_for_byte', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      final WorkerResponse response = await worker.sendRaw(
        (id) => GraphLayoutCommand(
          commandId: id,
          handleId: handle.handleId,
          revset: 'all()',
          prioritize: defaultGraphPrioritize,
          shortPrefixes: defaultShortPrefixes,
          anchors: defaultGraphAnchors,
          mode: LayoutMode.free,
          order: LaneOrder.compact,
          utcOffsetMin: 60,
          budget: defaultLayoutBudget,
          stacks: false,
          expandedKeys: const [],
          collapsedKeys: const [],
          keepOpenKeys: const [],
        ),
      );

      expect(response, isA<GraphLayoutResult>());
      final reply = response as GraphLayoutResult;
      expect(reply.violation, isNull);
      final topology = GraphTopologyView.fromEnvelope(reply.topology.materialize().asUint8List());
      expect(topology.copiedVectorCount, 0, reason: 'the materialized bytes back the view directly');
      final grid = GraphGridView.fromBytes(reply.grid!.materialize().asUint8List());
      expect(grid.copied, isFalse, reason: 'the materialized grid backs the view without a copy');
      expect(grid.nodeCount, 2);

      final Layout first = await handle.graphLayout(revset: 'all()', anchors: defaultGraphAnchors, utcOffsetMin: 60);
      final Layout second = await handle.graphLayout(revset: 'all()', anchors: defaultGraphAnchors, utcOffsetMin: 60);
      expect(second.grid.bytes, first.grid.bytes, reason: 'no state between commands, a deterministic layout');
      expect(first.grid.bytes, grid.bytes);

      await handle.close();
    });

    test('a_jj_error_surfaces_with_its_precondition', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      await expectLater(
        handle.graphLayout(revset: '(', anchors: defaultGraphAnchors, utcOffsetMin: 0),
        throwsA(
          isA<ZanshinFfiException>()
              .having((e) => e.code, 'code', 'jj.revset_parse_error')
              .having((e) => e.precondition, 'precondition', isNotNull),
        ),
      );
      expect(handle.lastPrecondition, isNotNull, reason: 'the failed call still recorded its report');

      await handle.close();
    });

    test('prioritize_and_short_prefixes_reach_the_topology_call', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      Matcher fails(String code) => throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', code));
      // A valid revset with a bad `prioritize` / `shortPrefixes` proves each string reaches Rust
      // as itself, not as a default or as another argument (test/worker/graph_test.dart's cases).
      await expectLater(
        handle.graphLayout(revset: 'all()', shortPrefixes: 'bogus_function()', anchors: const [], utcOffsetMin: 0),
        fails('jj.revset_parse_error'),
      );
      await expectLater(
        handle.graphLayout(revset: 'all()', prioritize: 'bogus_function()', anchors: const [], utcOffsetMin: 0),
        fails('jj.revset_parse_error'),
      );
      await expectLater(
        handle.graphLayout(revset: 'all()', prioritize: 'nonexistent-bookmark-xyz', anchors: const [], utcOffsetMin: 0),
        fails('jj.revset_resolution_error'),
      );

      await handle.close();
    });

    test('the_anchors_reach_the_topology_call_as_given', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      // One anchor instead of the default two: @ and its chain to the root take class 0 (the
      // defaults give [1, 0]); an unresolvable anchor fails in Rust (test/worker/graph_test.dart).
      final Layout layout = await handle.graphLayout(revset: 'all()', anchors: const ['present(@)'], utcOffsetMin: 0);
      expect(layout.topology.anchorCount, 1);
      expect(buildLayoutInput(layout.topology, utcOffsetMin: 0).priority, [0, 0]);
      await expectLater(
        handle.graphLayout(revset: 'all()', anchors: const ['nonexistent-bookmark-xyz'], utcOffsetMin: 0),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'jj.revset_resolution_error')),
      );

      await handle.close();
    });

    test('the_topology_calls_warnings_reach_the_caller', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 1, noColocate: true);

      // An unresolvable short-prefixes set only warns and degrades (test/worker/warnings_test.dart).
      final Layout layout = await handle.graphLayout(
        revset: 'all()',
        shortPrefixes: 'nonexistent-bookmark-xyz',
        anchors: defaultGraphAnchors,
        utcOffsetMin: 0,
      );

      expect(layout.topology.warnings.map((w) => w.code), [ZanshinWarningCode.shortPrefixesFailed]);
      expect(layout.grid.nodeCount, layout.topology.nodeCount);
      await handle.close();
    });

    test('a_non_default_budget_reaches_the_engine_and_cuts_the_compact_search', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // Two copies of engine_test's nested pattern on one trunk (a branch L merging back, a short
      // branch S nested inside it): the `compact` order improves both windows, but with budget 0
      // its search stops after the first one (docs/graph-layout.md §4.7, "stop the search").
      await buildDag(handle, const [
        ('A1', ['root']),
        ('L1', ['A1']),
        ('A2', ['A1']),
        ('L2', ['L1']),
        ('S1', ['A2']),
        ('A3', ['A2']),
        ('L3', ['L2']),
        ('A4', ['A3', 'S1']),
        ('L4', ['L3']),
        ('A5', ['A4', 'L4']),
        ('A6', ['A5']),
        ('M1', ['A6']),
        ('A7', ['A6']),
        ('M2', ['M1']),
        ('T1', ['A7']),
        ('A8', ['A7']),
        ('M3', ['M2']),
        ('A9', ['A8', 'T1']),
        ('M4', ['M3']),
        ('A10', ['A9', 'M4']),
      ]);

      Future<Layout> layOut(int budget) => handle.graphLayout(
        revset: 'all()',
        anchors: defaultGraphAnchors,
        utcOffsetMin: 0,
        mode: LayoutMode.compact,
        budget: budget,
      );
      final Layout cut = await layOut(0);
      final Layout full = await layOut(defaultLayoutBudget);

      expect(cut.grid.bytes, isNot(full.grid.bytes), reason: 'the budget changed the layout');
      final Uint8List local = computeGraphGrid(
        buildLayoutInput(cut.topology, utcOffsetMin: 0),
        mode: LayoutMode.compact,
        order: LaneOrder.compact,
        budget: 0,
      );
      expect(cut.grid.bytes, local, reason: "the worker's grid is the engine's at budget 0");
      await handle.close();
    });

    test('a_stack_toggles_through_the_request_and_off_is_the_version_1_grid', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      // The run a ← b ← c under the head x; @ on the sibling s.
      await buildDag(handle, const [
        ('a', ['root']),
        ('b', ['a']),
        ('c', ['b']),
        ('x', ['c']),
        ('s', ['root']),
      ]);
      Future<Layout> layOut({
        bool stacks = true,
        LayoutMode mode = LayoutMode.compact,
        List<String> expandedKeys = const [],
        List<String> collapsedKeys = const [],
        List<String> keepOpenKeys = const [],
      }) => handle.graphLayout(
        revset: 'all()',
        anchors: defaultGraphAnchors,
        utcOffsetMin: 0,
        mode: mode,
        stacks: stacks,
        expandedKeys: expandedKeys,
        collapsedKeys: collapsedKeys,
        keepOpenKeys: keepOpenKeys,
      );

      final Layout off = await layOut(stacks: false);
      expect(off.grid.hasStacks, isFalse);
      expect(ByteData.sublistView(off.grid.bytes).getInt32(0, Endian.little), GraphGridView.formatVersion);

      final Layout collapsed = await layOut();
      final GraphGridView grid = collapsed.grid;
      final int n = collapsed.topology.nodeCount;
      expect([grid.hasStacks, grid.stackCount, grid.runCount, grid.nodeCount], [true, 1, 1, n]);
      final List<int> members = grid.runMembers!.toList();
      expect(members, hasLength(3), reason: 'a, b, c — oldest first');
      expect([grid.runStates![0], grid.runNodes![0]], [GraphGridView.runCollapsed, n], reason: 'the stack node is n');
      for (final m in members) {
        expect([grid.isHidden(m), grid.nodeRows[m], grid.nodeRuns![m]], [true, -1, 0]);
      }
      expect(grid.nodeRows[n], 1, reason: 'one row above the root, where a was');
      expect(grid.nodeCols[n], off.grid.nodeCols[members.last], reason: "the stack sits in c's column");
      expect(grid.rows, off.grid.rows - 2, reason: 'three cards become one');

      final String a = collapsed.topology.changeId(members.first);
      final String b = collapsed.topology.changeId(members[1]);
      for (final Layout open in [
        await layOut(expandedKeys: [a]),
        await layOut(keepOpenKeys: [b]),
      ]) {
        expect(
          [open.grid.stackCount, open.grid.runStates![0], open.grid.runNodes![0]],
          [0, GraphGridView.runExpanded, -1],
        );
        expect(open.grid.nodeRows.toList(), off.grid.nodeRows.toList(), reason: 'expanded = ungrouped rows');
      }
      expect((await layOut(expandedKeys: [b])).grid.stackCount, 1, reason: 'b is no run key: ignored');

      // The default mode, `free`, end to end: the same stack, in c's column, rows never grow.
      final Layout freeOff = await layOut(stacks: false, mode: LayoutMode.free);
      final GraphGridView free = (await layOut(mode: LayoutMode.free)).grid;
      expect([free.stackCount, free.runNodes![0]], [1, n]);
      expect([for (final m in members) free.isHidden(m)], [true, true, true]);
      expect(free.nodeCols[n], freeOff.grid.nodeCols[members.last], reason: "the stack sits in c's column");
      expect(free.rows, lessThanOrEqualTo(freeOff.grid.rows));

      // @ on top of the run: its mutable ancestors start expanded, and a collapse request beats that.
      final GraphTopologyView t = collapsed.topology;
      final int x = [
        for (var i = 0; i < n; i++)
          if (t.edgeEnd(i) > t.edgeStart(i) && t.edgeTarget(t.edgeStart(i)) == members.last) i,
      ].single;
      await handle.edit(t.changeId(x));
      final Layout atop = await layOut();
      expect([atop.grid.stackCount, atop.grid.runStates![0]], [0, GraphGridView.runExpanded], reason: '@ on x');
      final Layout shut = await layOut(collapsedKeys: [a]);
      expect([shut.grid.stackCount, shut.grid.runStates![0]], [1, GraphGridView.runCollapsed], reason: 'collapsed a');

      // A bookmark on b breaks the run: a and c alone are no runs.
      await handle.bookmarkCreate(['mark'], revision: b);
      expect((await layOut()).grid.runCount, 0, reason: 'a ref breaks a run');
      await handle.close();
    });

    test('the_calling_side_rejects_bad_arguments_before_sending', () async {
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);

      Future<Layout> call({
        String revset = 'all()',
        String prioritize = defaultGraphPrioritize,
        String shortPrefixes = defaultShortPrefixes,
        List<String> anchors = defaultGraphAnchors,
        int utcOffsetMin = 0,
        int budget = defaultLayoutBudget,
      }) => worker.graphLayout(
        handle.handleId,
        revset: revset,
        prioritize: prioritize,
        shortPrefixes: shortPrefixes,
        anchors: anchors,
        mode: LayoutMode.free,
        order: LaneOrder.compact,
        utcOffsetMin: utcOffsetMin,
        budget: budget,
        stacks: false,
        expandedKeys: const [],
        collapsedKeys: const [],
        keepOpenKeys: const [],
      );

      await expectLater(call(revset: 'a${_nul}b'), throwsArgumentError);
      await expectLater(call(prioritize: 'a${_nul}b'), throwsArgumentError);
      await expectLater(call(shortPrefixes: 'a${_nul}b'), throwsArgumentError);
      await expectLater(call(anchors: ['trunk()', 'a${_nul}b']), throwsArgumentError);
      await expectLater(call(utcOffsetMin: 1441), throwsArgumentError);
      await expectLater(call(utcOffsetMin: -1441), throwsArgumentError);
      await expectLater(call(budget: -1), throwsArgumentError);
      expect(handle.lastPrecondition, isNull, reason: 'nothing reached the worker');

      await handle.close();
    });

    test('an_unknown_handle_is_ffi_invalid_handle_and_a_closed_one_a_state_error', () async {
      await expectLater(
        worker.graphLayout(
          9999,
          revset: 'all()',
          prioritize: defaultGraphPrioritize,
          shortPrefixes: defaultShortPrefixes,
          anchors: defaultGraphAnchors,
          mode: defaultLayoutMode,
          order: defaultLaneOrder,
          utcOffsetMin: 0,
          budget: defaultLayoutBudget,
          stacks: false,
          expandedKeys: const [],
          collapsedKeys: const [],
          keepOpenKeys: const [],
        ),
        throwsA(isA<ZanshinFfiException>().having((e) => e.code, 'code', 'ffi.invalid_handle')),
      );
      final RepoHandle handle = await worker.initRepo(tempDir.path, backend: 0);
      await handle.close();
      expect(
        () => handle.graphLayout(revset: 'all()', anchors: defaultGraphAnchors, utcOffsetMin: 0),
        throwsStateError,
      );
    });

    test('a_graph_layout_after_the_worker_closes_is_a_state_error', () async {
      final ZanshinWorker closed = await ZanshinWorker.start();
      await closed.close();

      await expectLater(
        closed.graphLayout(
          1,
          revset: 'all()',
          prioritize: defaultGraphPrioritize,
          shortPrefixes: defaultShortPrefixes,
          anchors: defaultGraphAnchors,
          mode: defaultLayoutMode,
          order: defaultLaneOrder,
          utcOffsetMin: 0,
          budget: defaultLayoutBudget,
          stacks: false,
          expandedKeys: const [],
          collapsedKeys: const [],
          keepOpenKeys: const [],
        ),
        throwsStateError,
      );
    });
  });

  // Fixture parity: one extraction and one worker per fixture; the dumps' parameters (prioritize
  // present(@), short prefixes '', the default anchors, utc_offset_min 120).
  final hashes = jsonDecode(File('$_goldens/fixtures/hashes.json').readAsStringSync()) as Map<String, Object?>;
  for (final (String name, String fixture, String revset, bool full) in const [
    ('tiny-all', 'tiny-3-commits', 'all()', true),
    ('medium-narrow', 'medium-1k-commits', _narrow, true),
    ('medium-all', 'medium-1k-commits', 'all()', false),
    ('large-all', 'large-10k-commits', 'all()', false),
  ]) {
    group('$name equals the spike references', () {
      late ZanshinWorker worker;
      late Directory tempDir;
      late RepoHandle handle;
      final record = hashes[name]! as Map<String, Object?>;

      setUpAll(() async {
        tempDir = Directory.systemTemp.createTempSync('zanshin_graph_layout_fixture_');
        final ProcessResult tar = await Process.run('tar', [
          '-xf',
          '../../test-fixtures/repos/$fixture.tar.zst',
          '-C',
          tempDir.path,
        ]);
        expect(tar.exitCode, 0, reason: '${tar.stderr}');
        worker = await ZanshinWorker.start();
        handle = await worker.openRepo(tempDir.path);
      });

      tearDownAll(() async {
        await handle.close();
        await worker.close();
        if (tempDir.existsSync()) {
          tempDir.deleteSync(recursive: true);
        }
      });

      /// [actual] against the golden `<name>.<suffix>` (a file, or a hash and a byte length).
      void expectGolden(String actual, String suffix, String fileSuffix) {
        if (full) {
          expect(actual, File('$_goldens/fixtures/$name.$fileSuffix').readAsStringSync(), reason: suffix);
        } else {
          final Uint8List bytes = utf8.encode(actual);
          final digest = record[suffix]! as Map<String, Object?>;
          expect([fnv1a64Hex(bytes), bytes.length], [digest['fnv1a64'], digest['bytes']], reason: suffix);
        }
      }

      test('${name}_golden_record_names_this_fixture_and_revset', () {
        // A dumper revset change shows up here, not as an opaque hash mismatch below.
        expect([record['fixture'], record['revset']], [fixture, revset]);
      });

      for (final LayoutMode mode in LayoutMode.values) {
        for (final LaneOrder order in LaneOrder.values) {
          test(
            '${name}_${mode.name}_${order.name}_grid_equals_the_golden',
            () async {
              final Layout layout = await handle.graphLayout(
                revset: revset,
                anchors: defaultGraphAnchors,
                utcOffsetMin: 120,
                shortPrefixes: '',
                mode: mode,
                order: order,
              );
              expect(layout.topology.hasTimestamps, mode == LayoutMode.free, reason: 'timestamps iff free');
              final key = '${mode.name}.${order.name}';
              expectGolden(canonicalOutput(layout.grid), key, '$key.json');
              if (mode == LayoutMode.free) {
                // The builder's input is the dumper's: same jj facts, rules and canonical form.
                final GraphTopologyView topology = layout.topology;
                final String input = canonicalInput(
                  buildLayoutInput(topology, utcOffsetMin: 120),
                  nowMs: record['now_ms']! as int,
                  ids: [for (var i = 0; i < topology.nodeCount; i++) topology.commitId(i)],
                );
                expectGolden(input, 'input', 'input.json');
              }
            },
            // WHY 10 minutes: the large fixture's loose store loads ~10k commit objects for the
            // timestamps, slower under the coverage instrumentation.
            timeout: const Timeout(Duration(minutes: 10)),
          );
        }
      }
    });
  }
}
