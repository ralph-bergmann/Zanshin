// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../window/app_windows.dart';
import 'project_registry.dart';
import 'project_repos.dart';
import 'project_session.dart';
import 'projects_environment.dart';
import 'worker_project_repos.dart';

/// DI module providing the app's repositories, its one [ProjectSession] (Story 11.5) and the Projects window's
/// [ProjectsEnvironment] (Story 11.6): the repositories and the identity over the boot's worker, jj-lib's version over
/// the diagnostics. The registry is an `@inject` singleton over the settings store.
@module
class ProjectsModule {
  /// Provides the repositories over the boot's [worker]: one [WorkerProjectRepos] for the app.
  @provides
  @singleton
  ProjectRepos projectRepos(ZanshinWorker worker) => WorkerProjectRepos(worker);

  /// Provides the app-wide [ProjectSession] over [registry] and [repos]; a switch away from the open project asks
  /// [windows]' close guards first, as closing and quitting do (Story 10.22).
  @provides
  @singleton
  ProjectSession projectSession(ProjectRegistry registry, ProjectRepos repos, AppWindows windows) =>
      ProjectSession(registry: registry, repos: repos, mayLeave: windows.mayClose);

  /// Provides the Projects window's [ProjectsEnvironment] over the boot's [worker] and [diagnostics].
  @provides
  @singleton
  ProjectsEnvironment projectsEnvironment(ZanshinWorker worker, GetDiagnostics diagnostics) =>
      DesktopProjectsEnvironment(worker, diagnostics: diagnostics);
}
