// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:zanshin/src/app/app_module.dart';
import 'package:zanshin/src/app/app_window_coordinator.dart';
import 'package:zanshin/src/app/boot/boot_module.dart';
import 'package:zanshin/src/app/zanshin_app.dart';
import 'package:zanshin/src/app/zanshin_application.dart';
import 'package:zanshin/src/features/graph/active_graph.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart' show RepoGraphSource;
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/home/project_scope.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin/src/features/projects/projects_module.dart';
import 'package:zanshin/src/features/projects/projects_search_focus.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin/src/features/settings/settings_window.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/zanshin_window_root.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import 'fake_projects.dart';
import 'fake_projects_environment.dart';
import 'fake_windows.dart';
import 'icon_registry.dart';
import 'test_component.inject.dart' as g;

/// The test bindings that win over the app's: the repositories and the Projects environment, fakes unless given, and
/// what an open repository's graph and sync read through, the app's unless given.
@module
class TestModule {
  /// The bindings over [repos] and [environment]; a [FakeProjectRepos] and a [FakeProjectsEnvironment] when null.
  TestModule({
    ProjectRepos? repos,
    ProjectsEnvironment? environment,
    this.graphSources,
    this.remoteSyncs,
  }) : repos = repos ?? FakeProjectRepos(),
       environment = environment ?? FakeProjectsEnvironment();

  /// The repositories the graph's session opens.
  final ProjectRepos repos;

  /// The jj config, versions and pickers the graph's windows read.
  final ProjectsEnvironment environment;

  /// What an open repository's graph reads from; null is the app's.
  final GraphSourceOf? graphSources;

  /// What an open repository's sync runs through; null is the app's.
  final RemoteSyncOf? remoteSyncs;

  /// Provides [repos].
  @provides
  @singleton
  ProjectRepos projectRepos() => repos;

  /// Provides [environment].
  @provides
  @singleton
  ProjectsEnvironment projectsEnvironment() => environment;

  /// Provides [graphSources].
  @provides
  GraphSourceOf graphSourceOf() => graphSources ?? RepoGraphSource.new;

  /// Provides [remoteSyncs].
  @provides
  RemoteSyncOf remoteSyncOf(ProjectsEnvironment environment) => remoteSyncs ?? repoRemoteSyncOf(environment);
}

/// main.dart's graph, with [TestModule] last so its bindings win; every app module's provider is still checked, so
/// the boot's values carry a real worker ([testWorker]), which the fakes keep from being called.
@Component([ZanshinDiagnosticsModule, BootModule, ProjectsModule, AppModule, TestModule])
abstract class TestComponent {
  // ignore: specify_nonobvious_property_types
  static const create = g.TestComponent$Component.create;

  /// The window coordinator.
  @inject
  AppWindowCoordinator get coordinator;

  /// The project window's content.
  @inject
  ZanshinAppFactory get appFactory;

  /// The project window's page.
  @inject
  HomePageFactory get homePageFactory;

  /// The graph of an open repository.
  @inject
  ProjectComponentFactory get projectScopes;

  /// The window roots.
  @inject
  ZanshinWindowRootFactory get rootFactory;

  /// The Projects window's content.
  @inject
  ProjectsWindowFactory get projectsWindowFactory;

  /// The jj log Configurations window's content.
  @inject
  RevsetConfigsWindowFactory get revsetConfigsWindowFactory;

  /// The Settings window's content.
  @inject
  SettingsWindowFactory get settingsWindowFactory;

  /// The open project.
  @inject
  ProjectSession get session;

  /// The settings.
  @inject
  SettingsStore get settings;

  /// The project window's graph.
  @inject
  ActiveGraph get activeGraph;

  /// The project registry.
  @inject
  ProjectRegistry get registry;

  /// The Projects environment.
  @inject
  ProjectsEnvironment get environment;

  /// The diagnostics read, which the app's Projects environment takes.
  @inject
  GetDiagnostics get diagnostics;

  /// The Projects content's search focus.
  @inject
  ProjectsSearchFocus get searchFocus;

  /// The key-window tracker.
  @inject
  ActiveWindowTracker get tracker;

  /// The app's windows.
  @inject
  AppWindows get windows;

  /// The app.
  @inject
  ZanshinApplication get application;
}

/// The test file's real worker, started by [setUpTestWorker].
late ZanshinWorker testWorker;

/// Starts [testWorker] once for the test file (a `setUpAll`) and closes it after the file (a `tearDownAll`). Load
/// [testIconRegistry] with `setUpIconRegistry` as well: [testComponent] hands both to the graph.
void setUpTestWorker() {
  setUpAll(() async => testWorker = await ZanshinWorker.start());
  tearDownAll(() => testWorker.close());
}

/// A [TestComponent] over the boot's values — a settings store in a fresh temporary folder holding [settingsJson]
/// (none: the defaults), [testIconRegistry] and [testWorker] — and [windows] (default: windows over a
/// [FakeWindowFactory] whose exit does nothing); [testModule] binds the repositories and the Projects environment
/// (default: fakes). The file IO runs in `runAsync`.
Future<TestComponent> testComponent(
  WidgetTester tester, {
  String? settingsJson,
  AppWindows? windows,
  TestModule? testModule,
}) async {
  final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('test_component')))!;
  addTearDown(() => dir.deleteSync(recursive: true));
  final SettingsStore settings = (await tester.runAsync(() async {
    final file = File('${dir.path}/settings.json');
    if (settingsJson != null) {
      await file.writeAsString(settingsJson);
    }
    return SettingsStore.load(file);
  }))!;
  final BootValues boot = (settings: settings, icons: testIconRegistry, worker: testWorker);
  return TestComponent.create(
    bootModule: BootModule(
      boot,
      windows ?? AppWindows(createController: FakeWindowFactory().call, exitProcess: () async {}),
    ),
    testModule: testModule,
  );
}
