// SPDX-License-Identifier: MIT

// BackendGraphLayout against the REAL worker isolate and cdylib (Story 10.12): extracted copies of the committed
// fixtures and an in-test repository, in temp folders. The view reads every value from the grid and the topology; these
// tests hold it to both, and the real layouts to the hard invariants.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/backend_graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_gaps.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/layout_invariants.dart';
import 'package:zanshin_core/zanshin_core.dart';

typedef _Reply = ({GraphTopologyView topology, GraphGridView grid});

const _utcOffset = 120;

/// Lays out [revset] on [handle] with the effective defaults.
Future<BackendGraphLayout> _layout(
  RepoHandle handle,
  String revset, {
  required LayoutMode mode,
  bool stacks = false,
  List<String> expanded = const <String>[],
}) async {
  final LogDefaults defaults = await handle.logDefaults();
  final _Reply reply = await handle.graphLayout(
    revset: revset,
    anchors: defaultGraphAnchors,
    utcOffsetMin: _utcOffset,
    prioritize: defaults.logGraphPrioritize,
    shortPrefixes: defaults.shortPrefixes,
    mode: mode,
    stacks: stacks,
    expandedKeys: expanded,
  );
  return BackendGraphLayout(reply.topology, reply.grid, utcOffsetMinutes: _utcOffset);
}

/// The view equals its grid and topology: counts, then every node's key, row and column, every edge's ends, and the
/// edge index's ranges.
void _expectMirrors(BackendGraphLayout layout) {
  final GraphTopologyView t = layout.topology;
  final GraphGridView g = layout.grid;
  final int n = t.nodeCount;
  expect(layout.nodeCount, n + g.stackCount);
  expect(layout.shownCount, n);
  expect(layout.edgeCount, g.edgeCount);
  expect(layout.totalCount, t.allCount);
  expect(layout.operationId, t.operationId);
  expect(layout.rows, g.rows);
  expect(layout.colCount, g.lanes);
  expect(layout.unit, g.unit);
  expect(layout.bucketCount, g.bucketCount);
  expect(layout.runCount, g.runCount);
  for (var i = 0; i < layout.nodeCount; i++) {
    expect(layout.rowOf(i), g.nodeRows[i]);
    expect(layout.colOf(i), g.nodeCols[i]);
    final String key = layout.keyOf(i);
    expect(layout.indexOfKey(key), i);
    if (i < n) {
      expect(key, t.isHidden(i) || t.isDivergent(i) ? t.commitId(i) : t.changeId(i));
      expect(layout.parentCountOf(i), t.parentCount(i));
      expect(layout.isImmutable(i), t.isImmutable(i));
    } else {
      expect(layout.isStackNode(i), isTrue);
      final List<int> members = layout.runMembersOf(layout.runOf(i)!);
      expect(key, graphStackKey(layout.keyOf(members.first)));
    }
  }
  for (var k = 0; k < layout.edgeCount; k++) {
    expect(layout.childOf(k), g.edgeTos[k]);
    expect(layout.parentOf(k), g.edgeFroms[k]);
    expect(
      layout.kindOf(k),
      g.edgeKinds[k] == GraphGridView.edgeKindIndirect ? GraphEdgeKind.indirect : GraphEdgeKind.direct,
    );
  }
  for (var b = 0; b < layout.bucketCount; b++) {
    expect(layout.bucketValueOf(b), g.bucketValues[b]);
    expect(layout.bucketFirstRowOf(b), g.bucketStarts[b]);
    expect(layout.bucketLastRowOf(b), g.bucketEnds[b]);
  }
  for (var i = 0; i < layout.nodeCount; i++) {
    final ({int start, int end}) parents = layout.parentEdges(i);
    for (int k = parents.start; k < parents.end; k++) {
      expect(layout.childOf(k), i);
    }
    final ({int start, int end}) children = layout.childEdges(i);
    for (int s = children.start; s < children.end; s++) {
      expect(layout.parentOf(layout.childEdgeAt(s)), i);
    }
  }
  if (layout.rootIndex case final int root) {
    expect(t.isRoot(root), isTrue);
  }
  if (layout.workingCopyIndex case final int at) {
    expect(t.isWorkingCopy(at), isTrue);
  }
}

Future<RouteReport> _routes(GraphLayout layout) async {
  final RouteGeometry geometry = await routeGraph(layout, GraphMetrics());
  return checkRoutes(geometry, gate: layout.mode == GraphMode.compact);
}

void main() {
  late ZanshinWorker worker;

  setUpAll(() async {
    worker = await ZanshinWorker.start();
  });

  tearDownAll(() => worker.close());

  for (final (String fixture, bool every) in const <(String, bool)>[
    ('tiny-3-commits', true),
    ('medium-1k-commits', true),
    // 10k: the default revset and all() in free only (the time budget).
    ('large-10k-commits', false),
  ]) {
    group(fixture, () {
      late Directory dir;
      late RepoHandle handle;
      late String log;

      setUpAll(() async {
        dir = Directory.systemTemp.createTempSync('zanshin_backend_layout_');
        final ProcessResult tar = await Process.run('tar', <String>[
          '-xf',
          '../test-fixtures/repos/$fixture.tar.zst',
          '-C',
          dir.path,
        ]);
        expect(tar.exitCode, 0, reason: '${tar.stderr}');
        handle = await worker.openRepo(dir.path);
        log = (await handle.logDefaults()).log;
      });

      tearDownAll(() async {
        await handle.close();
        dir.deleteSync(recursive: true);
      });

      for (final all in <bool>[false, true]) {
        final name = all ? 'all()' : 'revsets.log';
        for (final stacks in every ? <bool>[false, true] : <bool>[false]) {
          test('$name, stacks ${stacks ? 'on' : 'off'}: both modes hold the invariants, mirror the view and keep '
              'every column', () async {
            final revset = all ? 'all()' : log;
            final BackendGraphLayout free = await _layout(handle, revset, mode: LayoutMode.free, stacks: stacks);
            final BackendGraphLayout? compact = every
                ? await _layout(handle, revset, mode: LayoutMode.compact, stacks: stacks)
                : null;
            for (final layout in <BackendGraphLayout>[free, ?compact]) {
              expect(checkLayoutInvariants(layout), isEmpty, reason: layout.mode.name);
              _expectMirrors(layout);
              final RouteReport report = await _routes(layout);
              // The route report is recorded, not gated, on real data (spec-10-12 § Verification).
              // ignore: avoid_print
              print('route report $fixture $name ${layout.mode.name} stacks $stacks n ${layout.nodeCount}: $report');
            }
            if (compact != null) {
              expect(compact.nodeCount, free.nodeCount);
              for (var i = 0; i < free.nodeCount; i++) {
                expect(compact.keyOf(i), free.keyOf(i));
                expect(compact.colOf(i), free.colOf(i), reason: 'Free ↔ Compact keeps every column (4.14 I8)');
              }
              expect(compact.version, isNot(free.version));
            }
          }, timeout: const Timeout(Duration(minutes: 2)));
        }
      }
    });
  }

  group('a hand-made repository', () {
    late Directory dir;
    late RepoHandle handle;
    late String first;
    late String second;
    late String third;
    late String merge;
    late String rewrittenCommit;

    setUpAll(() async {
      dir = Directory.systemTemp.createTempSync('zanshin_backend_layout_repo_');
      final String path = dir.resolveSymbolicLinksSync();
      await (await worker.initRepo(path, backend: 0)).close();
      handle = await worker.openRepo(path);
      first = (await handle.status()).workingCopyChangeId!;
      await handle.describe(changeId: first, description: 'one');
      second = (await handle.newChange(<String>[first])).newChangeIds.single;
      third = (await handle.newChange(<String>[second])).newChangeIds.single;
      // A run member has one child (docs/graph-layout.md §4.8): fourth closes the run second–third, which ends off
      // @'s line — @ moves to a new change on first.
      final String fourth = (await handle.newChange(<String>[third])).newChangeIds.single;
      // Described, so leaving it does not abandon it (an empty, undescribed @ goes when @ moves).
      await handle.describe(changeId: fourth, description: 'four');
      // Story 10.19: a merge of first and the root, described so leaving it keeps it.
      merge = (await handle.newChange(<String>[first, 'z' * 32])).newChangeIds.single;
      await handle.describe(changeId: merge, description: 'merge');
      await handle.newChange(<String>[first]);
      await handle.bookmarkCreate(<String>['feat'], revision: first);
      final BackendGraphLayout before = await _layout(handle, 'all()', mode: LayoutMode.free);
      rewrittenCommit = before.commitIdOf(before.indexOfKey(second)!);
      // The describe rewrites second: its old commit is hidden.
      await handle.describe(changeId: second, description: 'two');
    });

    tearDownAll(() async {
      await handle.close();
      dir.deleteSync(recursive: true);
    });

    test('a hidden commit is keyed by its commit id and carries its change offset', () async {
      final BackendGraphLayout layout = await _layout(handle, 'all() | $rewrittenCommit', mode: LayoutMode.compact);
      final int hidden = layout.indexOfKey(rewrittenCommit)!;
      expect(layout.isHidden(hidden), isTrue);
      expect(layout.changeIdOf(hidden), second);
      expect(layout.changeOffsetOf(hidden), isNotNull);
      final int visible = layout.indexOfKey(second)!;
      expect(layout.changeOffsetOf(visible), isNull, reason: 'only a hidden or divergent node has one');
      expect(layout.commitIdPrefixLengthOf(visible), greaterThan(0));
    });

    test('a parent outside the revset is a Missing edge: elided, still counted', () async {
      final BackendGraphLayout layout = await _layout(handle, second, mode: LayoutMode.compact);
      expect(layout.shownCount, 1);
      expect(layout.elidedOf(0), isTrue);
      expect(layout.parentCountOf(0), 1);
      expect(layout.edgeCount, 0);
      expect(layout.missingCountOf(0), 1);
    });

    test('Story 10.19: a merge shown alone has two Missing parents', () async {
      final BackendGraphLayout layout = await _layout(handle, merge, mode: LayoutMode.compact);
      expect(layout.shownCount, 1);
      expect(layout.missingCountOf(0), 2);
      expect(graphGapCounts(layout).ends, 2);
    });

    test('bookmarks are its refs; one workspace names none', () async {
      final BackendGraphLayout layout = await _layout(handle, 'all()', mode: LayoutMode.free);
      expect(layout.refsOf(layout.indexOfKey(first)!), const <GraphRef>[GraphRef('feat')]);
      expect(layout.refsOf(layout.indexOfKey(second)!), isEmpty);
      expect(layout.workingCopiesOf(layout.workingCopyIndex!), isEmpty);
      expect(layout.workspaceName, isNull);
      expect(layout.isImmutable(layout.rootIndex!), isTrue);
    });

    test("a collapsed run's stack node: its oldest member's stack key, its newest member's time, one parent", () async {
      final BackendGraphLayout layout = await _layout(handle, 'all()', mode: LayoutMode.free, stacks: true);
      final int member = layout.indexOfKey(second)!;
      final int run = layout.runOf(member)!;
      final int stack = layout.stackNodeOf(run)!;
      expect(layout.isFolded(member), isTrue);
      expect(layout.rowOf(member), -1);
      expect(layout.colOf(member), -1);
      expect(stack, greaterThanOrEqualTo(layout.shownCount));
      final List<int> members = layout.runMembersOf(run);
      expect(<String>[for (final m in members) layout.keyOf(m)], <String>[second, third]);
      expect(layout.keyOf(stack), graphStackKey(second));
      expect(layout.placeOfKey(third), stack);
      expect(layout.timestampOf(stack), layout.timestampOf(members.last));
      expect(layout.parentCountOf(stack), 1);
      expect(layout.isImmutable(stack), isFalse);
      expect(layout.refsOf(stack), isEmpty);
      // The card data the peek reads: a real node's commit id and prefix, none for the stack node.
      final real = GraphCardData.of(layout, layout.indexOfKey(first)!);
      expect(real.commitId, layout.commitIdOf(layout.indexOfKey(first)!));
      expect(real.commitPrefixLength, greaterThan(0));
      expect(GraphCardData.of(layout, stack).commitId, isNull);
      expect(checkLayoutInvariants(layout), isEmpty);

      final BackendGraphLayout expanded = await _layout(
        handle,
        'all()',
        mode: LayoutMode.free,
        stacks: true,
        expanded: <String>[second],
      );
      expect(expanded.stackNodeOf(expanded.runOf(expanded.indexOfKey(second)!)!), isNull);
      expect(expanded.nodeCount, expanded.shownCount);
    });

    // Last in the group: it adds a workspace the tests above do not expect.
    test("with two workspaces each @ names its workspace, and @'s single name is ours", () async {
      final second = Directory('${dir.path}-ws2');
      addTearDown(() {
        if (second.existsSync()) {
          second.deleteSync(recursive: true);
        }
      });
      await handle.workspaceAdd(destination: second.path, name: 'ws2');
      final BackendGraphLayout layout = await _layout(handle, 'all()', mode: LayoutMode.free);
      final int at = layout.workingCopyIndex!;
      expect(layout.workingCopiesOf(at), <String>['default']);
      expect(layout.workspaceName, 'default');
      final int other = <int>[
        for (var i = 0; i < layout.nodeCount; i++)
          if (i != at && layout.workingCopiesOf(i).isNotEmpty) i,
      ].single;
      expect(layout.workingCopiesOf(other), <String>['ws2']);

      // ws2 edits our @: both workspaces sit on one commit, and the topology cannot say which is ours.
      final RepoHandle ws2 = await worker.openRepo(second.path);
      addTearDown(ws2.close);
      await ws2.edit(layout.changeIdOf(at));
      final BackendGraphLayout shared = await _layout(handle, 'all()', mode: LayoutMode.free);
      expect(shared.workingCopiesOf(shared.workingCopyIndex!), unorderedEquals(<String>['default', 'ws2']));
      expect(shared.workspaceName, isNull);
    });
  });
}
