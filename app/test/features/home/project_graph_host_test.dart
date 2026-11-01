// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart' show GraphLoad;
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/home/project_graph_host.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/shell/app_menu.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_projects_environment.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/scripted_graph_source.dart';
import '../../helpers/shell_host.dart';

void main() {
  setUpIconRegistry();

  testWidgets('Reload pressed three times while a layout is in flight: one more request runs after it, not two', (
    tester,
  ) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    useShellWindow(tester);
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('project_graph_host_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    final repos = FakeProjectRepos();
    final session = ProjectSession(registry: ProjectRegistry(store), repos: repos);
    addTearDown(session.dispose);
    final appMenu = AppMenuModel(ActiveWindowTracker(), session);
    addTearDown(appMenu.dispose);
    final toasts = ShellToasts();
    addTearDown(toasts.dispose);
    final source = ScriptedGraphSource();
    await tester.runAsync(() => session.open('/r/zanshin'));

    await tester.pumpWidget(
      shellHost(
        ProjectGraphHost(
          session: session,
          settings: store,
          environment: FakeProjectsEnvironment(),
          appMenu: appMenu,
          toasts: toasts,
          sourceOf: (_) => source,
          builder: (context, slots) => Stack(
            fit: StackFit.expand,
            children: <Widget>[
              ?slots.graph,
              Align(alignment: Alignment.topRight, child: slots.reload),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(source.requests, hasLength(1));
    expect(appMenu.graph.value?.model.layout, isNotNull);
    final GraphView view = tester.widget<GraphView>(find.byType(GraphView));
    expect(view.inspectorModel, isNotNull, reason: "the card menu's Describe… opens the inspector");
    expect(view.bookmarks, isNotNull, reason: "the bookmark popover's Track / Untrack read");

    source.hold = true;
    final int reads = repos.repoAt('/r/zanshin').reads;
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.bySemanticsIdentifier('graph.reload'));
      await tester.pump();
    }
    expect(source.requests, hasLength(2), reason: 'one in flight, the others coalesced into one queued');
    source.hold = false;
    source.held.single.complete(GraphLoad(keysLayout(<String>['a', 'b', 'c'], at: 'a')));
    await tester.pump();
    await tester.pump();
    expect(source.requests, hasLength(3), reason: 'the queued one');

    // The session's queued work started in the fake zone: alternate real time and pumps until it is done.
    var closed = false;
    unawaited(session.closeProject().then((_) => closed = true));
    final watch = Stopwatch()..start();
    while (!closed && watch.elapsed < const Duration(seconds: 10)) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(closed, isTrue);
    expect(repos.repoAt('/r/zanshin').reads, greaterThan(reads), reason: 'the presses refreshed the session');
    expect(appMenu.graph.value, isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    semantics.dispose();
  });
}
