// SPDX-License-Identifier: MIT

// RepoGraphSource's layout and content, and RepoGraphSearchSource's live reads, against the REAL worker isolate and
// cdylib (Story 10.12) on an in-test native-backend repository in a temp folder.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/backend_graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
import 'package:zanshin_core/zanshin_core.dart';

void main() {
  late ZanshinWorker worker;
  late Directory dir;
  late String path;
  late ProjectRepo repo;
  late RepoGraphSource source;
  late String first;
  late String second;
  late String third;

  setUpAll(() async {
    worker = await ZanshinWorker.start();
    dir = Directory.systemTemp.createTempSync('zanshin_repo_graph_source_');
    path = dir.resolveSymbolicLinksSync();
    await (await worker.initRepo(path, backend: 0)).close();
    repo = await WorkerProjectRepos(Future<ZanshinWorker>.value(worker)).open(path);
    final RepoHandle handle = repo.handle;
    first = (await handle.status()).workingCopyChangeId!;
    await handle.describe(changeId: first, description: 'Subject line\n\nThe body,\nover two lines.\n');
    second = (await handle.newChange(<String>[first])).newChangeIds.single;
    await handle.describe(changeId: second, description: 'two');
    third = (await handle.newChange(<String>[second])).newChangeIds.single;
    await handle.describe(changeId: third, description: 'three');
    // @ on first, so second–third is a collapsible run (its newest member needs a child: four).
    final String fourth = (await handle.newChange(<String>[third])).newChangeIds.single;
    await handle.describe(changeId: fourth, description: 'four');
    await handle.newChange(<String>[first]);
    File('$path/a.txt').writeAsStringSync('a\n');
    await handle.bookmarkCreate(<String>['feat'], revision: first);
    source = RepoGraphSource(repo);
  });

  tearDownAll(() async {
    await repo.close();
    await worker.close();
    dir.deleteSync(recursive: true);
  });

  Future<GraphRequest> request({
    String revset = 'all()',
    GraphMode mode = GraphMode.free,
    GraphLaneOrder order = GraphLaneOrder.compact,
    bool stacks = false,
    Set<String> expanded = const <String>{},
    Set<String> collapsed = const <String>{},
    Set<String> keepOpen = const <String>{},
  }) async {
    final LogDefaults defaults = await source.logDefaults();
    return GraphRequest(
      revset: revset,
      prioritize: defaults.logGraphPrioritize,
      shortPrefixes: defaults.shortPrefixes,
      anchors: defaultGraphAnchors,
      utcOffsetMin: 60,
      mode: mode,
      order: order,
      stacks: stacks,
      expandedKeys: expanded,
      collapsedKeys: collapsed,
      keepOpenKeys: keepOpen,
    );
  }

  Future<BackendGraphLayout> layoutOf(GraphRequest request) async =>
      (await source.layout(request)).layout as BackendGraphLayout;

  test('the request reaches the worker: mode, order, offset and the stack keys', () async {
    final BackendGraphLayout free = await layoutOf(await request());
    expect(free.mode, GraphMode.free);
    expect(free.unit, 16);
    expect(free.utcOffsetMinutes, 60);
    expect(free.grid.order, LaneOrder.compact);
    expect(free.runCount, 0, reason: 'no stack request');

    final BackendGraphLayout compact = await layoutOf(
      await request(mode: GraphMode.compact, order: GraphLaneOrder.greedy),
    );
    expect(compact.mode, GraphMode.compact);
    expect(compact.unit, 1);
    expect(compact.grid.order, LaneOrder.greedy);

    final BackendGraphLayout stacked = await layoutOf(await request(stacks: true));
    final int run = stacked.runOf(stacked.indexOfKey(second)!)!;
    expect(stacked.stackNodeOf(run), isNotNull, reason: 'collapsed by default: off @');

    final BackendGraphLayout expanded = await layoutOf(await request(stacks: true, expanded: <String>{second}));
    expect(expanded.stackNodeOf(expanded.runOf(expanded.indexOfKey(second)!)!), isNull);

    final BackendGraphLayout keptOpen = await layoutOf(await request(stacks: true, keepOpen: <String>{third}));
    expect(keptOpen.stackNodeOf(keptOpen.runOf(keptOpen.indexOfKey(second)!)!), isNull);

    final BackendGraphLayout collapsed = await layoutOf(await request(stacks: true, collapsed: <String>{second}));
    expect(collapsed.stackNodeOf(collapsed.runOf(collapsed.indexOfKey(second)!)!), isNotNull);
  });

  test("the load carries the topology's warnings and the handle's precondition", () async {
    final GraphLoad load = await source.layout(await request());
    final layout = load.layout as BackendGraphLayout;
    expect(load.warnings, layout.topology.warnings);
    expect(load.precondition, same(repo.handle.lastPrecondition));
    expect(load.precondition, isNotNull, reason: 'the layout call snapshots first');
  });

  test('content maps every field at the layout operation; the subject is the first line', () async {
    final BackendGraphLayout layout = await layoutOf(await request());
    final String commit = layout.commitIdOf(layout.indexOfKey(first)!);
    final String other = layout.commitIdOf(layout.indexOfKey(second)!);
    final Map<String, GraphCommitContent> page = await source.content(layout.operationId, <String>[commit, other]);
    expect(page.keys, unorderedEquals(<String>[commit, other]));
    final GraphCommitContent c = page[commit]!;
    expect(c.subject, 'Subject line');
    expect(c.description, 'Subject line\n\nThe body,\nover two lines.\n');
    expect(c.authorName, isNotEmpty);
    expect(c.authorEmail, isNotEmpty);
    expect(c.empty, isTrue, reason: 'first changes no file');
    expect(c.conflict, isFalse);
    expect(c.timestampMs, greaterThan(0));
    expect(page[other]!.subject, 'two');
  });

  test('content without an operation (a recording) asks nothing and answers empty', () async {
    final ProjectRepo closed = await WorkerProjectRepos(Future<ZanshinWorker>.value(worker)).open(path);
    await closed.close();
    // A call on the closed handle would throw: none is made.
    expect(await RepoGraphSource(closed).content(null, <String>['00']), isEmpty);
  });

  test("a broken layout-input rule is the model's ffi.unknown, the rule first", () {
    final ZanshinFfiException error = layoutContractFailure(const LayoutContractException('V3', 'node 4 repeats 7'));
    expect(error.code, 'ffi.unknown');
    expect(error.context, 'V3: node 4 repeats 7');
  });

  test('the search source reads files, bookmarks and pinned counts of the same repository', () async {
    final search = RepoGraphSearchSource(
      repo,
      userEmail: () async => 'me@example.com',
      content: source.content,
    );
    expect(await search.files(), contains('a.txt'));
    expect((await search.bookmarks()).map((b) => b.name), contains('feat'));
    final BackendGraphLayout layout = await layoutOf(await request());
    final RevsetCounts counts = await search.revsetCounts(layout.operationId!, <String>['all()'], cap: 100);
    expect(counts.single.n, layout.shownCount, reason: 'the shown all() at its operation');
    expect(await search.userEmail(), 'me@example.com');
  });

  test("a CRLF description's subject drops the \\r, as jj's first_line() does", () {
    const content = CommitContent(
      commitId: 'ab',
      authorName: 'A',
      authorEmail: 'a@x',
      committerTimestampMillis: 1,
      committerTzOffsetMinutes: 0,
      description: 'Windows line\r\nbody\r\n',
      conflict: false,
      empty: null,
    );
    final GraphCommitContent c = graphCommitContentOf(content);
    expect(c.subject, 'Windows line');
    expect(c.description, 'Windows line\r\nbody\r\n');
    expect(c.empty, isFalse, reason: 'undecidable reads as not empty');
  });

  // Last: it rewrites third.
  test("at_operation(): content reads pass the layout's extra operations, so a commit only there loads", () async {
    final BackendGraphLayout before = await layoutOf(await request());
    final String oldCommit = before.commitIdOf(before.indexOfKey(third)!);
    final String earlier = (await repo.handle.opLog(limit: 1)).first.id;
    await repo.handle.describe(changeId: third, description: 'three, rewritten');

    final GraphLoad load = await source.layout(await request(revset: 'at_operation($earlier, $oldCommit)'));
    final layout = load.layout as BackendGraphLayout;
    expect(layout.topology.extraOperationIds, isNotEmpty);
    // A later layout at the same operation without at_operation() keeps the extras of the shown one.
    await source.layout(await request());
    final Map<String, GraphCommitContent> page = await source.content(layout.operationId, <String>[oldCommit]);
    expect(page[oldCommit]?.subject, 'three');
  });
}
