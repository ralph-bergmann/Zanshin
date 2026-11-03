// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/graph/graph_minimap.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart' show GraphLoad;
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/home/project_graph_host.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/shell/app_menu.dart';
import 'package:zanshin/src/features/shell/shell_toast.dart';
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_projects_environment.dart';
import '../../helpers/fake_remote_sync.dart';
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
    ProjectGraphSlots? lastSlots;
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
          builder: (context, slots) {
            lastSlots = slots;
            return Stack(
              fit: StackFit.expand,
              children: <Widget>[
                ?slots.graph,
                Align(alignment: Alignment.topRight, child: slots.sync),
              ],
            );
          },
        ),
      ),
    );
    await tester.pump();
    expect(source.requests, hasLength(1));
    expect(appMenu.graph.value?.model.layout, isNotNull);
    final GraphView view = tester.widget<GraphView>(find.byType(GraphView));
    expect(view.inspectorModel, isNotNull, reason: "the card menu's Describe… opens the inspector");
    expect(view.bookmarks, isNotNull, reason: "the bookmark popover's Track / Untrack read");

    // Story 10.16: the minimap slot follows View › Show Minimap (default on).
    expect(lastSlots?.minimap, isA<GraphMinimap>());
    appMenu.graph.value!.preferences.setShowMinimap(false);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();
    expect(lastSlots?.minimap, isNull);
    appMenu.graph.value!.preferences.setShowMinimap(true);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump();

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

  group('sync wiring (Story 11.8)', () {
    /// The host over an open `/r/zanshin` at [poll], its sync over [remotes].
    Future<(ProjectSession, AppMenuModel)> mount(
      WidgetTester tester,
      FakeRemoteSync remotes, {
      RemotePollSetting poll = RemotePollSetting.fiveMinutes,
    }) async {
      useShellWindow(tester);
      final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('project_graph_host_test')))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
      final registry = ProjectRegistry(store);
      final session = ProjectSession(registry: registry, repos: FakeProjectRepos());
      addTearDown(session.dispose);
      final appMenu = AppMenuModel(ActiveWindowTracker(), session);
      addTearDown(appMenu.dispose);
      final toasts = ShellToasts();
      addTearDown(toasts.dispose);
      await tester.runAsync(() => session.open('/r/zanshin'));
      await tester.runAsync(() => registry.setRemotePoll('/r/zanshin', poll));
      final source = ScriptedGraphSource()..respond = (_) => keysLayout(<String>['a', 'b', 'c'], at: 'a');
      await tester.pumpWidget(
        shellHost(
          ProjectGraphHost(
            session: session,
            settings: store,
            environment: FakeProjectsEnvironment(),
            appMenu: appMenu,
            toasts: toasts,
            sourceOf: (_) => source,
            syncOf: (_) => remotes,
            builder: (context, slots) => Stack(fit: StackFit.expand, children: <Widget>[?slots.graph, slots.sync]),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      return (session, appMenu);
    }

    Future<void> unmount(WidgetTester tester) => tester.pumpWidget(const SizedBox.shrink());

    testWidgets('a running fetch puts the dot on syncing; the reading after it writes the real state', (tester) async {
      final remotes = FakeRemoteSync()..fetchGate = Completer<void>();
      final (ProjectSession session, AppMenuModel appMenu) = await mount(tester, remotes);
      final SyncModel sync = appMenu.graph.value!.sync!;
      // The store's writes started in the fake zone: alternate real time and pumps until [done].
      Future<void> settle(bool Function() done) async {
        final watch = Stopwatch()..start();
        while (!done() && watch.elapsed < const Duration(seconds: 10)) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
          await tester.pump();
        }
      }

      expect(sync.canFetch, isTrue);
      unawaited(sync.fetch());
      await settle(() => session.current?.status == ProjectStatus.syncing);
      expect(session.current?.status, ProjectStatus.syncing);
      remotes.fetchGate!.complete();
      await settle(() => !sync.fetching && session.current?.status == ProjectStatus.clean);
      expect(sync.fetching, isFalse);
      expect(session.current?.status, ProjectStatus.clean);
      await unmount(tester);
    });

    testWidgets('the app turning active polls once; with the poll Off it does not', (tester) async {
      final remotes = FakeRemoteSync();
      await mount(tester, remotes);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(remotes.log, <String>['changes origin']);
      await unmount(tester);

      final off = FakeRemoteSync();
      await mount(tester, off, poll: RemotePollSetting.off);
      tester.binding
        ..handleAppLifecycleStateChanged(AppLifecycleState.inactive)
        ..handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(hours: 1));
      expect(off.log, isEmpty);
      await unmount(tester);
    });

    testWidgets("the sheet's change row is the selected change, else @", (tester) async {
      final remotes = FakeRemoteSync();
      final (_, AppMenuModel appMenu) = await mount(tester, remotes, poll: RemotePollSetting.off);
      final SyncModel sync = appMenu.graph.value!.sync!;
      final GraphViewModel model = appMenu.graph.value!.model;

      sync.openPush();
      expect(sync.pushSheet?.change, (id: 'a', rev: '@'));
      sync.pushSheetClosed();

      model.select('b');
      sync.openPush();
      expect(sync.pushSheet?.change, (id: 'b', rev: 'b'));
      sync.pushSheetClosed();
      await unmount(tester);
    });
  });
}
