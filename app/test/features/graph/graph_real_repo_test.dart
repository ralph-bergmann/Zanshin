// SPDX-License-Identifier: MIT

// The story's witnesses (Story 10.12): GraphView and GraphViewModel over RepoGraphSource on the REAL worker isolate and
// cdylib, an in-test native-backend repository in a temp folder. Worker I/O runs in `tester.runAsync`; what the view
// starts in the fake zone settles by alternating real time and pumps.

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_card.dart';
import 'package:zanshin/src/features/graph/graph_edges.dart';
import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_metrics.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/worker_project_repos.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

Finder _cardOf(String key) =>
    find.byWidgetPredicate((w) => w is GraphCard && w.layout.keyOf(w.node) == key, skipOffstage: false);

/// Alternates real time and pumps until [done] holds, at most 15 s of real time.
Future<void> _settle(WidgetTester tester, bool Function() done) async {
  final watch = Stopwatch()..start();
  while (!done() && watch.elapsed < const Duration(seconds: 15)) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    // Fake time too: the content pages wait for the scroll to settle.
    await tester.pump(const Duration(milliseconds: 20));
  }
  expect(done(), isTrue);
  await tester.pump();
}

void main() {
  setUpIconRegistry();

  testWidgets('a describe reloads in place, a double-click edit moves @ and its lineage, all() shows more', (
    tester,
  ) async {
    useShellWindow(tester);
    final (ZanshinWorker worker, Directory dir, ProjectRepo repo) = (await tester.runAsync(() async {
      final ZanshinWorker worker = await ZanshinWorker.start();
      final Directory dir = Directory.systemTemp.createTempSync('zanshin_graph_real_repo_');
      final String path = dir.resolveSymbolicLinksSync();
      await (await worker.initRepo(path, backend: 0)).close();
      return (worker, dir, await WorkerProjectRepos(Future<ZanshinWorker>.value(worker)).open(path));
    }))!;
    final (String first, String second) = (await tester.runAsync(() async {
      final RepoHandle handle = repo.handle;
      final String first = (await handle.status()).workingCopyChangeId!;
      await handle.describe(changeId: first, description: 'first');
      final String second = (await handle.newChange(<String>[first])).newChangeIds.single;
      await handle.describe(changeId: second, description: 'second');
      return (first, second);
    }))!;
    final model = GraphViewModel();
    await tester.runAsync(() async => model.init(RepoGraphSource(repo), actions: RepoGraphActions(repo)));
    await tester.pumpWidget(shellHost(GraphView(model: model)));
    await _settle(tester, () => model.layout != null);
    await _settle(tester, () => _cardOf(second).evaluate().isNotEmpty);

    // A describe through the handle: the watcher's event reloads, the anchored (selected) card keeps its place.
    model.select(first);
    await tester.pump();
    final Offset before = tester.getTopLeft(_cardOf(first));
    final int version = model.layout!.version;
    await tester.runAsync(() => repo.handle.describe(changeId: first, description: 'first, described again'));
    await _settle(tester, () => model.layout!.version != version && !model.loading);
    expect(tester.getTopLeft(_cardOf(first)), before, reason: 'the anchored node keeps its place');
    final int node = model.layout!.indexOfKey(first)!;
    await _settle(tester, () => model.content.of(model.layout!, node)?.subject == 'first, described again');

    // A double-click on first runs `jj edit` through the model: @ moves there, and so does the gold lineage.
    model.select(null);
    await tester.pump();
    final Offset at = tester.getCenter(_cardOf(first));
    await tester.tapAt(at);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(at);
    await tester.pump();
    await _settle(tester, () {
      final GraphLayout? layout = model.layout;
      return layout != null && layout.workingCopyIndex != null && layout.keyOf(layout.workingCopyIndex!) == first;
    });
    final String? workingCopy = (await tester.runAsync(() => repo.handle.status()))!.workingCopyChangeId;
    expect(workingCopy, first);
    final GraphLayout edited = model.layout!;
    final RouteGeometry geometry = (await tester.runAsync(() async => routeGraph(edited, GraphMetrics())))!;
    final painter = GraphEdgePainter(layout: edited, geometry: geometry, theme: GraphTheme.night);
    expect(painter.inLineage(edited.indexOfKey(first)!), isTrue);
    expect(
      painter.inLineage(edited.indexOfKey(second)!),
      isFalse,
      reason: "second is first's child, outside @'s lineage now",
    );

    // From `@` alone to all(): more nodes, and shown of total right in both.
    model.setRevset('@');
    await _settle(tester, () => model.request?.revset == '@' && model.shown == 1);
    final int total = model.total!;
    expect(total, greaterThan(1));
    model.setRevset('all()');
    await _settle(tester, () => model.request?.revset == 'all()' && model.shown! > 1);
    expect(model.shown, total, reason: 'all() shows every visible commit');
    expect(model.total, total);

    await tester.pumpWidget(const SizedBox.shrink());
    model.dispose();
    await tester.runAsync(() async {
      await repo.close();
      await worker.close();
      dir.deleteSync(recursive: true);
    });
  });
}
