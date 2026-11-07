// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';

import '../features/graph/revset_configs/revset_configs_window.dart';
import '../features/projects/project_session.dart';
import '../features/projects/projects_window.dart';
import '../features/settings/settings_window.dart';
import '../features/window/app_window_actions.dart';
import '../features/window/app_windows.dart';
import '../features/window/zanshin_window_root.dart';
import '../links.dart';
import 'app_window_coordinator.dart';
import 'zanshin_app.dart';

/// DI module of the app's frame: the window coordinator over the window contents, the window actions it answers and
/// the browser opener.
@module
class AppModule {
  /// Provides the window coordinator (Story 11.12) over the session and the app's [windows]: the project window shows
  /// [project] (its `window:main` root over `HomePage`), Projects the [projects] content under the `window:projects`
  /// root, its `onOpened` handed through, and jj log Configurations (Story 10.22) its window under the
  /// `window:revset-configs` root, its Revset reference opening through [openUrl].
  ///
  /// Settings (Story 11.7) shows its window under the content-sized `window:settings` root; the Projects window's
  /// Settings… and Set identity… open it through the coordinator's window actions.
  @provides
  @singleton
  AppWindowCoordinator coordinator(
    AppWindows windows,
    ProjectSession session,
    ZanshinAppFactory project,
    ZanshinWindowRootFactory roots,
    ProjectsWindowFactory projects,
    RevsetConfigsWindowFactory revsetConfigs,
    SettingsWindowFactory settings,
    OpenUrl openUrl,
  ) => AppWindowCoordinator(
    windows: windows,
    session: session,
    buildProject: project.create,
    buildProjects: (onOpened) => roots.create(
      windowKey: projectsWindowKey,
      child: projects.create(onOpened: onOpened),
    ),
    buildRevsetConfigs: () => roots.create(
      windowKey: revsetConfigsWindowKey,
      child: revsetConfigs.create(openUrl: openUrl),
    ),
    buildSettings: (state) => roots.create(
      windowKey: settingsWindowKey,
      sizeToContent: true,
      child: settings.create(state: state),
    ),
  );

  /// Provides the window actions: the coordinator.
  @provides
  AppWindowActions windowActions(AppWindowCoordinator coordinator) => coordinator;

  /// Provides the browser opener (Help › jj Documentation, the Configurations window's Revset reference).
  @provides
  OpenUrl openUrl() => openInBrowser;
}
