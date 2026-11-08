// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;

import '../features/graph/active_graph.dart';
import '../features/graph/graph_ports.dart' show RepoGraphSource;
import '../features/graph/revset_configs/revset_configs_window.dart';
import '../features/home/project_scope.dart';
import '../features/projects/project_session.dart';
import '../features/projects/projects_environment.dart';
import '../features/projects/projects_window.dart';
import '../features/settings/settings_view_model.dart';
import '../features/settings/settings_window.dart';
import '../features/settings/settings_window_state.dart';
import '../features/window/app_window_actions.dart';
import '../features/window/app_windows.dart';
import '../features/window/zanshin_window_root.dart';
import '../links.dart';
import 'app_window_coordinator.dart';
import 'zanshin_app.dart';

/// DI module of the app's frame: the window coordinator over the window contents, the window actions it answers, the
/// browser opener, the Settings window's view model and what each open repository's graph reads through. It installs
/// the graph of an open repository ([ProjectComponent]).
@Module(subcomponents: <Type>[ProjectComponent])
class AppModule {
  /// Provides the window coordinator (Story 11.12) over the session and the app's [windows]: the project window shows
  /// [project] (its `window:main` root over `HomePage`), Projects the [projects] content under the `window:projects`
  /// root, its `onOpened` handed through, and jj log Configurations (Story 10.22) its window under the
  /// `window:revset-configs` root.
  ///
  /// Settings (Story 11.7) shows its window under the content-sized `window:settings` root; the Projects window's
  /// Settings… and Set identity… open it through the coordinator's window actions.
  @provides
  @singleton
  AppWindowCoordinator coordinator(
    AppWindows windows,
    ProjectSession session,
    SettingsWindowState settingsState,
    ZanshinAppFactory project,
    ZanshinWindowRootFactory roots,
    ProjectsWindowFactory projects,
    RevsetConfigsWindowFactory revsetConfigs,
    SettingsWindowFactory settings,
  ) => AppWindowCoordinator(
    windows: windows,
    session: session,
    settingsState: settingsState,
    buildProject: project.create,
    buildProjects: (onOpened) => roots.create(
      windowKey: projectsWindowKey,
      child: projects.create(onOpened: onOpened),
    ),
    buildRevsetConfigs: () => roots.create(
      windowKey: revsetConfigsWindowKey,
      child: revsetConfigs.create(),
    ),
    buildSettings: () => roots.create(
      windowKey: settingsWindowKey,
      sizeToContent: true,
      child: settings.create(),
    ),
  );

  /// Provides the window actions: the coordinator.
  @provides
  AppWindowActions windowActions(AppWindowCoordinator coordinator) => coordinator;

  /// Provides the browser opener (Help › jj Documentation, the Configurations window's Revset reference).
  @provides
  OpenUrl openUrl() => openInBrowser;

  /// Provides a new view model for each Settings window. The window owns it.
  @provides
  SettingsViewModel settingsViewModel(
    SettingsStore store,
    ProjectsEnvironment environment,
    ProjectSession session,
    ActiveGraph graph,
  ) => SettingsViewModel(store: store, environment: environment, session: session, graph: graph);

  /// Provides what an open repository's graph reads from.
  @provides
  GraphSourceOf graphSourceOf() => RepoGraphSource.new;

  /// Provides what an open repository's Fetch, Push and poll run through.
  @provides
  RemoteSyncOf remoteSyncOf(ProjectsEnvironment environment) => repoRemoteSyncOf(environment);
}
