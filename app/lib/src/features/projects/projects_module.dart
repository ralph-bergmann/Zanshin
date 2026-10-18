// SPDX-License-Identifier: MIT

import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'project_registry.dart';
import 'project_session.dart';
import 'worker_project_repos.dart';

/// DI module providing the app's one [ProjectSession] (Story 11.5): the registry over the settings store, the
/// repositories over the boot's worker.
///
/// The worker arrives as a constructor argument, like `SettingsModule(store:)`: inject_generator binds an
/// `@asynchronous` provider only as its resolved value, and a provider taking that value turns asynchronous itself —
/// and with it every page that injects the session. The boot completes [worker] once the component's worker has
/// started (`main.dart`), so the graph stays synchronous.
@module
class ProjectsModule {
  /// The module over the boot's [worker].
  ProjectsModule({required this.worker});

  /// The boot's worker, once it has started.
  final Future<ZanshinWorker> worker;

  /// Provides the app-wide [ProjectSession].
  @provides
  @singleton
  ProjectSession projectSession(SettingsStore settings) =>
      ProjectSession(registry: ProjectRegistry(settings), repos: WorkerProjectRepos(worker));
}
