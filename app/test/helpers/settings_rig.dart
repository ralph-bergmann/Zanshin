// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin/src/features/graph/graph_preferences.dart';
import 'package:zanshin/src/features/graph/graph_view_model.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/settings/settings_window.dart';
import 'package:zanshin/src/features/settings/settings_window_state.dart';
import 'package:zanshin/src/features/shell/app_menu.dart' show GraphMenuBinding;
import 'package:zanshin/src/features/sync/sync_model.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'fake_projects.dart';
import 'fake_projects_environment.dart';
import 'fake_settings_reads.dart';
import 'fake_windows.dart';
import 'recording_shell.dart';
import 'shell_host.dart';

/// The project the rig opens.
const settingsRigProject = '/r/zanshin';

/// A graph view model counting `configChanged`.
class SettingsRigGraph extends GraphViewModel {
  var configChanges = 0;

  @override
  void configChanged() => configChanges++;
}

/// The Settings window over fakes: a jj config ([env]), the repository reads ([reads]), a graph binding with an
/// optional [sync].
class SettingsRig {
  SettingsRig(this.tester);

  final WidgetTester tester;
  final env = FakeProjectsEnvironment();
  final reads = FakeSettingsReads();
  final state = SettingsWindowState();
  final graph = ValueNotifier<GraphMenuBinding?>(null);
  final themes = <ThemeMode>[];
  final model = SettingsRigGraph();

  /// The app's windows the content registers its close handler and close guard with.
  final windows = AppWindows(createController: FakeWindowFactory().call, exitProcess: () async {});

  /// The project window's sync the remote verbs reload; set before [pump].
  SyncModel? sync;
  late SettingsStore store;
  late ProjectSession session;

  SettingsWindowContentState get content => tester.state<SettingsWindowContentState>(find.byType(SettingsWindow));

  List<String> get calls => env.configCalls;

  Future<void> pump({bool project = true, SettingsTarget? target}) async {
    // Taller than the window's 740, so every row is on screen without scrolling.
    useShellWindow(tester, const Size(620, 1600));
    ZanshinShellPlatform.instance = RecordingShell();
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('settings_window_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    session = ProjectSession(registry: ProjectRegistry(store), repos: FakeProjectRepos());
    addTearDown(session.dispose);
    addTearDown(state.dispose);
    final preferences = GraphPreferences(store);
    addTearDown(preferences.dispose);
    addTearDown(model.dispose);
    graph.value = GraphMenuBinding(model: model, preferences: preferences, sync: sync);
    if (project) {
      await tester.runAsync(() => session.open(settingsRigProject));
    }
    state.projectOpen = project;
    if (target != null) {
      state.show(target);
    }
    await tester.pumpWidget(
      shellHost(
        SettingsWindow(
          state: state,
          windows: windows,
          store: store,
          environment: env,
          session: session,
          graph: graph,
          setThemeMode: (mode) async => themes.add(mode),
          readsOf: (_) => reads,
        ),
      ),
    );
    await settle();
  }

  Future<void> settle() async {
    for (var i = 0; i < 4; i++) {
      await tester.pump();
    }
  }

  Finder id(String identifier) => find.bySemanticsIdentifier(identifier);

  Finder field(String identifier) => find.descendant(of: id(identifier), matching: find.byType(EditableText));

  Future<void> submit(String identifier, String text) async {
    await tester.enterText(field(identifier), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle();
  }

  Future<void> tap(String identifier) async {
    await tester.tap(id(identifier));
    await settle();
  }
}
