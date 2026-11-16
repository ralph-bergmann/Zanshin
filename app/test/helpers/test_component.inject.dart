// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:flutter/src/foundation/basic_types.dart' as _i48;
import 'package:flutter/src/foundation/key.dart' as _i30;
import 'package:flutter/src/widgets/framework.dart' as _i52;
import 'package:inject_annotation/inject_annotation.dart' as _i25;
import 'package:inject_flutter/src/view_model_factory.dart' as _i51;
import 'package:zanshin/src/app/app_exit_handler.dart' as _i26;
import 'package:zanshin/src/app/app_module.dart' as _i5;
import 'package:zanshin/src/app/app_window_coordinator.dart' as _i21;
import 'package:zanshin/src/app/boot/boot_module.dart' as _i3;
import 'package:zanshin/src/app/menu/app_menu.dart' as _i27;
import 'package:zanshin/src/app/zanshin_app.dart' as _i16;
import 'package:zanshin/src/app/zanshin_application.dart' as _i22;
import 'package:zanshin/src/features/bookmarks/bookmark_list_model.dart'
    as _i33;
import 'package:zanshin/src/features/bookmarks/ref_delete.dart' as _i44;
import 'package:zanshin/src/features/graph/active_graph.dart' as _i6;
import 'package:zanshin/src/features/graph/graph_inspector.dart' as _i40;
import 'package:zanshin/src/features/graph/graph_ports.dart' as _i36;
import 'package:zanshin/src/features/graph/graph_preferences.dart' as _i34;
import 'package:zanshin/src/features/graph/graph_search_controller.dart'
    as _i35;
import 'package:zanshin/src/features/graph/graph_toasts.dart' as _i37;
import 'package:zanshin/src/features/graph/graph_view_model.dart' as _i38;
import 'package:zanshin/src/features/graph/immutable_reasons.dart' as _i39;
import 'package:zanshin/src/features/graph/inspector_viewed_store.dart' as _i41;
import 'package:zanshin/src/features/graph/project_files.dart' as _i43;
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart'
    as _i19;
import 'package:zanshin/src/features/graph/view_state_cleanup.dart' as _i47;
import 'package:zanshin/src/features/home/home_page.dart' as _i14;
import 'package:zanshin/src/features/home/project_scope.dart' as _i13;
import 'package:zanshin/src/features/projects/project_registry.dart' as _i10;
import 'package:zanshin/src/features/projects/project_repos.dart' as _i23;
import 'package:zanshin/src/features/projects/project_session.dart' as _i11;
import 'package:zanshin/src/features/projects/projects_environment.dart'
    as _i17;
import 'package:zanshin/src/features/projects/projects_module.dart' as _i4;
import 'package:zanshin/src/features/projects/projects_search_focus.dart'
    as _i12;
import 'package:zanshin/src/features/projects/projects_window.dart' as _i18;
import 'package:zanshin/src/features/settings/settings_view_model.dart' as _i49;
import 'package:zanshin/src/features/settings/settings_window.dart' as _i20;
import 'package:zanshin/src/features/settings/settings_window_state.dart'
    as _i50;
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart'
    as _i29;
import 'package:zanshin/src/features/shell/shell_toast.dart' as _i24;
import 'package:zanshin/src/features/sync/sync_model.dart' as _i45;
import 'package:zanshin/src/features/undo_timeline/operation_changes.dart'
    as _i42;
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart'
    as _i46;
import 'package:zanshin/src/features/window/active_window_tracker.dart' as _i7;
import 'package:zanshin/src/features/window/app_window_actions.dart' as _i28;
import 'package:zanshin/src/features/window/app_windows.dart' as _i8;
import 'package:zanshin/src/features/window/window_appearance_sync.dart'
    as _i54;
import 'package:zanshin/src/features/window/zanshin_app_view_model.dart'
    as _i53;
import 'package:zanshin/src/features/window/zanshin_window_root.dart' as _i15;
import 'package:zanshin/src/links.dart' as _i32;
import 'package:zanshin_core/src/ffi/diagnostics.dart' as _i2;
import 'package:zanshin_core/src/worker/isolate.dart' as _i55;
import 'package:zanshin_settings/src/settings_store.dart' as _i9;
import 'package:zanshin_ui/src/icons/icon_registry.dart' as _i31;

import 'test_component.dart' as _i1;

class TestComponent$Component implements _i1.TestComponent {
  factory TestComponent$Component.create({
    _i2.ZanshinDiagnosticsModule? zanshinDiagnosticsModule,
    required _i3.BootModule bootModule,
    _i4.ProjectsModule? projectsModule,
    _i5.AppModule? appModule,
    _i1.TestModule? testModule,
  }) => TestComponent$Component._(
    zanshinDiagnosticsModule ?? _i2.ZanshinDiagnosticsModule(),
    bootModule,
    projectsModule ?? _i4.ProjectsModule(),
    appModule ?? _i5.AppModule(),
    testModule ?? _i1.TestModule(),
  );

  TestComponent$Component._(
    _i2.ZanshinDiagnosticsModule zanshinDiagnosticsModule,
    _i3.BootModule bootModule,
    _i4.ProjectsModule projectsModule,
    _i5.AppModule appModule,
    _i1.TestModule testModule,
  ) {
    _activeGraph$Provider = _ActiveGraph$Provider();
    _activeWindowTracker$Provider = _ActiveWindowTracker$Provider();
    _appWindows$Provider = _AppWindows$Provider(bootModule);
    final zanshinWorker$Provider = _ZanshinWorker$Provider(bootModule);
    final appExitHandler$Provider = _AppExitHandler$Provider(
      _appWindows$Provider,
      zanshinWorker$Provider,
    );
    _settingsStore$Provider = _SettingsStore$Provider(bootModule);
    _projectRegistry$Provider = _ProjectRegistry$Provider(
      _settingsStore$Provider,
    );
    final projectRepos$Provider = _ProjectRepos$Provider(testModule);
    _projectSession$Provider = _ProjectSession$Provider(
      _projectRegistry$Provider,
      projectRepos$Provider,
      _appWindows$Provider,
      projectsModule,
    );
    _projectsSearchFocus$Provider = _ProjectsSearchFocus$Provider();
    final settingsWindowState$Provider = _SettingsWindowState$Provider();
    final floatingShellViewModel$Provider = _FloatingShellViewModel$Provider(
      _settingsStore$Provider,
    );
    final viewModelFactoryOfFloatingShellViewModel$Provider =
        _ViewModelFactoryOfFloatingShellViewModel$Provider(
          floatingShellViewModel$Provider,
        );
    _projectComponentFactory$Provider = _ProjectComponentFactory$Provider(this);
    _homePageFactory$Provider = _HomePageFactory$Provider(
      viewModelFactoryOfFloatingShellViewModel$Provider,
      _projectSession$Provider,
      _projectComponentFactory$Provider,
      _activeGraph$Provider,
    );
    final zanshinAppViewModel$Provider = _ZanshinAppViewModel$Provider(
      _settingsStore$Provider,
    );
    final viewModelFactoryOfZanshinAppViewModel$Provider =
        _ViewModelFactoryOfZanshinAppViewModel$Provider(
          zanshinAppViewModel$Provider,
        );
    final iconRegistry$Provider = _IconRegistry$Provider(bootModule);
    _zanshinWindowRootFactory$Provider = _ZanshinWindowRootFactory$Provider(
      viewModelFactoryOfZanshinAppViewModel$Provider,
      _activeWindowTracker$Provider,
      iconRegistry$Provider,
    );
    _zanshinAppFactory$Provider = _ZanshinAppFactory$Provider(
      _homePageFactory$Provider,
      _zanshinWindowRootFactory$Provider,
    );
    _projectsEnvironment$Provider = _ProjectsEnvironment$Provider(testModule);
    _projectsWindowFactory$Provider = _ProjectsWindowFactory$Provider(
      _projectSession$Provider,
      _projectRegistry$Provider,
      _projectsEnvironment$Provider,
      _projectsSearchFocus$Provider,
    );
    final openUrl$Provider = _OpenUrl$Provider(appModule);
    _revsetConfigsWindowFactory$Provider = _RevsetConfigsWindowFactory$Provider(
      _settingsStore$Provider,
      _activeGraph$Provider,
      _appWindows$Provider,
      openUrl$Provider,
    );
    final settingsViewModel$Provider = _SettingsViewModel$Provider(
      _settingsStore$Provider,
      _projectsEnvironment$Provider,
      _projectSession$Provider,
      _activeGraph$Provider,
      appModule,
    );
    _settingsWindowFactory$Provider = _SettingsWindowFactory$Provider(
      _appWindows$Provider,
      settingsWindowState$Provider,
      settingsViewModel$Provider,
    );
    _appWindowCoordinator$Provider = _AppWindowCoordinator$Provider(
      _appWindows$Provider,
      _projectSession$Provider,
      settingsWindowState$Provider,
      _zanshinAppFactory$Provider,
      _zanshinWindowRootFactory$Provider,
      _projectsWindowFactory$Provider,
      _revsetConfigsWindowFactory$Provider,
      _settingsWindowFactory$Provider,
      appModule,
    );
    final appWindowActions$Provider = _AppWindowActions$Provider(
      _appWindowCoordinator$Provider,
      appModule,
    );
    final appMenuModel$Provider = _AppMenuModel$Provider(
      _activeWindowTracker$Provider,
      _projectSession$Provider,
      _settingsStore$Provider,
      _activeGraph$Provider,
      _projectsSearchFocus$Provider,
      _appWindows$Provider,
      appWindowActions$Provider,
      openUrl$Provider,
    );
    _getDiagnostics$Provider = _GetDiagnostics$Provider(
      zanshinDiagnosticsModule,
    );
    _graphSourceOf$Provider = _GraphSourceOf$Provider(testModule);
    _refListSourceOf$Provider = _RefListSourceOf$Provider(testModule);
    _remoteSyncOf$Provider = _RemoteSyncOf$Provider(
      _projectsEnvironment$Provider,
      testModule,
    );
    final windowAppearanceSync$Provider = _WindowAppearanceSync$Provider(
      _settingsStore$Provider,
    );
    _zanshinApplication$Provider = _ZanshinApplication$Provider(
      _appWindowCoordinator$Provider,
      appMenuModel$Provider,
      _settingsStore$Provider,
      _appWindows$Provider,
      appExitHandler$Provider,
      windowAppearanceSync$Provider,
    );
  }

  late final _ActiveGraph$Provider _activeGraph$Provider;

  late final _ActiveWindowTracker$Provider _activeWindowTracker$Provider;

  late final _AppWindows$Provider _appWindows$Provider;

  late final _SettingsStore$Provider _settingsStore$Provider;

  late final _ProjectRegistry$Provider _projectRegistry$Provider;

  late final _ProjectSession$Provider _projectSession$Provider;

  late final _ProjectsSearchFocus$Provider _projectsSearchFocus$Provider;

  late final _ProjectComponentFactory$Provider
  _projectComponentFactory$Provider;

  late final _HomePageFactory$Provider _homePageFactory$Provider;

  late final _ZanshinWindowRootFactory$Provider
  _zanshinWindowRootFactory$Provider;

  late final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  late final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  late final _ProjectsWindowFactory$Provider _projectsWindowFactory$Provider;

  late final _RevsetConfigsWindowFactory$Provider
  _revsetConfigsWindowFactory$Provider;

  late final _SettingsWindowFactory$Provider _settingsWindowFactory$Provider;

  late final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  late final _GetDiagnostics$Provider _getDiagnostics$Provider;

  late final _GraphSourceOf$Provider _graphSourceOf$Provider;

  late final _RefListSourceOf$Provider _refListSourceOf$Provider;

  late final _RemoteSyncOf$Provider _remoteSyncOf$Provider;

  late final _ZanshinApplication$Provider _zanshinApplication$Provider;

  @override
  _i6.ActiveGraph get activeGraph => _activeGraph$Provider.get();

  @override
  _i7.ActiveWindowTracker get tracker => _activeWindowTracker$Provider.get();

  @override
  _i8.AppWindows get windows => _appWindows$Provider.get();

  @override
  _i9.SettingsStore get settings => _settingsStore$Provider.get();

  @override
  _i10.ProjectRegistry get registry => _projectRegistry$Provider.get();

  @override
  _i11.ProjectSession get session => _projectSession$Provider.get();

  @override
  _i12.ProjectsSearchFocus get searchFocus =>
      _projectsSearchFocus$Provider.get();

  @override
  _i13.ProjectComponentFactory get projectScopes =>
      _projectComponentFactory$Provider.get();

  @override
  _i14.HomePageFactory get homePageFactory => _homePageFactory$Provider.get();

  @override
  _i15.ZanshinWindowRootFactory get rootFactory =>
      _zanshinWindowRootFactory$Provider.get();

  @override
  _i16.ZanshinAppFactory get appFactory => _zanshinAppFactory$Provider.get();

  @override
  _i17.ProjectsEnvironment get environment =>
      _projectsEnvironment$Provider.get();

  @override
  _i18.ProjectsWindowFactory get projectsWindowFactory =>
      _projectsWindowFactory$Provider.get();

  @override
  _i19.RevsetConfigsWindowFactory get revsetConfigsWindowFactory =>
      _revsetConfigsWindowFactory$Provider.get();

  @override
  _i20.SettingsWindowFactory get settingsWindowFactory =>
      _settingsWindowFactory$Provider.get();

  @override
  _i21.AppWindowCoordinator get coordinator =>
      _appWindowCoordinator$Provider.get();

  @override
  _i2.GetDiagnostics get diagnostics => _getDiagnostics$Provider.get();

  @override
  _i22.ZanshinApplication get application => _zanshinApplication$Provider.get();
}

class ProjectComponent$Subcomponent implements _i13.ProjectComponent {
  factory ProjectComponent$Subcomponent.create(
    TestComponent$Component parent, {
    _i13.ProjectModule? projectModule,
    required _i23.ProjectRepo repo,
    required String root,
    required _i24.ShellToasts toasts,
  }) => ProjectComponent$Subcomponent._(
    parent,
    projectModule ?? _i13.ProjectModule(),
    repo,
    root,
    toasts,
  );

  ProjectComponent$Subcomponent._(
    this._parent,
    _i13.ProjectModule projectModule,
    this.repo,
    this.root,
    this.toasts,
  ) {
    _projectComponent$projectRepo$Provider =
        _ProjectComponent$ProjectRepo$Provider(repo);
    final projectComponent$graphViewModel$Provider =
        _ProjectComponent$GraphViewModel$Provider(projectModule);
    final projectComponent$graphSource$Provider =
        _ProjectComponent$GraphSource$Provider(
          _parent._graphSourceOf$Provider,
          _projectComponent$projectRepo$Provider,
          projectModule,
        );
    _projectComponent$stringProjectRoot$Provider =
        _ProjectComponent$StringProjectRoot$Provider(root);
    final projectComponent$graphSearchController$Provider =
        _ProjectComponent$GraphSearchController$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$graphSource$Provider,
          _projectComponent$projectRepo$Provider,
          _parent._projectsEnvironment$Provider,
          _parent._settingsStore$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    _projectComponent$shellToasts$Provider =
        _ProjectComponent$ShellToasts$Provider(toasts);
    final projectComponent$syncModel$Provider =
        _ProjectComponent$SyncModel$Provider(
          projectComponent$graphViewModel$Provider,
          _parent._remoteSyncOf$Provider,
          _projectComponent$projectRepo$Provider,
          _projectComponent$shellToasts$Provider,
          _parent._projectSession$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    final projectComponent$refDeleteFlow$Provider =
        _ProjectComponent$RefDeleteFlow$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$syncModel$Provider,
          projectModule,
        );
    final projectComponent$bookmarkListModel$Provider =
        _ProjectComponent$BookmarkListModel$Provider(
          _parent._refListSourceOf$Provider,
          _projectComponent$projectRepo$Provider,
          projectComponent$graphSearchController$Provider,
          projectComponent$refDeleteFlow$Provider,
          projectModule,
        );
    final projectComponent$graphStackStore$Provider =
        _ProjectComponent$GraphStackStore$Provider(
          _parent._settingsStore$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    final projectComponent$graphPreferences$Provider =
        _ProjectComponent$GraphPreferences$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$graphSource$Provider,
          projectComponent$graphSearchController$Provider,
          _projectComponent$projectRepo$Provider,
          _parent._settingsStore$Provider,
          projectComponent$graphStackStore$Provider,
          projectModule,
        );
    final projectComponent$graphToasts$Provider =
        _ProjectComponent$GraphToasts$Provider(
          projectComponent$graphViewModel$Provider,
          _projectComponent$shellToasts$Provider,
          projectModule,
        );
    final projectComponent$immutableReasons$Provider =
        _ProjectComponent$ImmutableReasons$Provider(
          _projectComponent$projectRepo$Provider,
          _parent._projectsEnvironment$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    final projectComponent$inspectorViewedStore$Provider =
        _ProjectComponent$InspectorViewedStore$Provider(
          _parent._settingsStore$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    final projectComponent$projectFiles$Provider =
        _ProjectComponent$ProjectFiles$Provider(
          _projectComponent$stringProjectRoot$Provider,
          _parent._settingsStore$Provider,
          _projectComponent$shellToasts$Provider,
          projectModule,
        );
    final projectComponent$inspectorViewModel$Provider =
        _ProjectComponent$InspectorViewModel$Provider(
          projectComponent$graphViewModel$Provider,
          _projectComponent$projectRepo$Provider,
          _parent._settingsStore$Provider,
          projectComponent$inspectorViewedStore$Provider,
          _parent._projectsEnvironment$Provider,
          projectComponent$projectFiles$Provider,
          projectModule,
        );
    final projectComponent$operationChangesSource$Provider =
        _ProjectComponent$OperationChangesSource$Provider(
          _projectComponent$projectRepo$Provider,
          _parent._projectsEnvironment$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    final projectComponent$operationChangesModelFactory$Provider =
        _ProjectComponent$OperationChangesModelFactory$Provider(
          projectComponent$operationChangesSource$Provider,
          _parent._settingsStore$Provider,
        );
    final projectComponent$operationChangesOf$Provider =
        _ProjectComponent$OperationChangesOf$Provider(
          projectComponent$operationChangesModelFactory$Provider,
          projectModule,
        );
    final projectComponent$viewStateCleanup$Provider =
        _ProjectComponent$ViewStateCleanup$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$graphStackStore$Provider,
          projectComponent$inspectorViewedStore$Provider,
          _projectComponent$projectRepo$Provider,
          projectModule,
        );
    final projectComponent$tagListModel$Provider =
        _ProjectComponent$TagListModel$Provider(
          _parent._refListSourceOf$Provider,
          _projectComponent$projectRepo$Provider,
          projectComponent$graphSearchController$Provider,
          projectComponent$refDeleteFlow$Provider,
          projectModule,
        );
    final projectComponent$undoTimelineModel$Provider =
        _ProjectComponent$UndoTimelineModel$Provider(
          _projectComponent$projectRepo$Provider,
          projectModule,
        );
    _projectComponent$projectScope$Provider =
        _ProjectComponent$ProjectScope$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$graphPreferences$Provider,
          projectComponent$viewStateCleanup$Provider,
          projectComponent$graphSearchController$Provider,
          projectComponent$inspectorViewModel$Provider,
          projectComponent$immutableReasons$Provider,
          projectComponent$graphToasts$Provider,
          projectComponent$syncModel$Provider,
          projectComponent$refDeleteFlow$Provider,
          projectComponent$bookmarkListModel$Provider,
          projectComponent$tagListModel$Provider,
          projectComponent$undoTimelineModel$Provider,
          projectComponent$operationChangesOf$Provider,
          _parent._projectsEnvironment$Provider,
          _projectComponent$projectRepo$Provider,
        );
  }

  final TestComponent$Component _parent;

  final _i23.ProjectRepo repo;

  final String root;

  final _i24.ShellToasts toasts;

  late final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  late final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  late final _ProjectComponent$ShellToasts$Provider
  _projectComponent$shellToasts$Provider;

  late final _ProjectComponent$ProjectScope$Provider
  _projectComponent$projectScope$Provider;

  @override
  _i13.ProjectScope get scope => _projectComponent$projectScope$Provider.get();
}

class _ProjectComponentFactory$Factory implements _i13.ProjectComponentFactory {
  const _ProjectComponentFactory$Factory(this._parent);

  final TestComponent$Component _parent;

  @override
  _i13.ProjectComponent create(
    _i23.ProjectRepo repo,
    String root,
    _i24.ShellToasts toasts,
  ) => ProjectComponent$Subcomponent.create(
    _parent,
    repo: repo,
    root: root,
    toasts: toasts,
  );
}

class _ActiveGraph$Provider implements _i25.Provider<_i6.ActiveGraph> {
  _ActiveGraph$Provider();

  late final _i6.ActiveGraph _singleton = _create();

  _i6.ActiveGraph _create() => _i6.ActiveGraph();

  @override
  _i6.ActiveGraph get() => _singleton;
}

class _ActiveWindowTracker$Provider
    implements _i25.Provider<_i7.ActiveWindowTracker> {
  _ActiveWindowTracker$Provider();

  late final _i7.ActiveWindowTracker _singleton = _create();

  _i7.ActiveWindowTracker _create() => _i7.ActiveWindowTracker();

  @override
  _i7.ActiveWindowTracker get() => _singleton;
}

class _AppExitHandler$Provider implements _i25.Provider<_i26.AppExitHandler> {
  _AppExitHandler$Provider(
    this._appWindows$Provider,
    this._zanshinWorker$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  late final _i26.AppExitHandler _singleton = _create();

  _i26.AppExitHandler _create() => _i26.AppExitHandler(
    _appWindows$Provider.get(),
    _zanshinWorker$Provider.get(),
  );

  @override
  _i26.AppExitHandler get() => _singleton;
}

class _AppMenuModel$Provider implements _i25.Provider<_i27.AppMenuModel> {
  _AppMenuModel$Provider(
    this._activeWindowTracker$Provider,
    this._projectSession$Provider,
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._projectsSearchFocus$Provider,
    this._appWindows$Provider,
    this._appWindowActions$Provider,
    this._openUrl$Provider,
  );

  final _ActiveWindowTracker$Provider _activeWindowTracker$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _ProjectsSearchFocus$Provider _projectsSearchFocus$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  final _AppWindowActions$Provider _appWindowActions$Provider;

  final _OpenUrl$Provider _openUrl$Provider;

  late final _i27.AppMenuModel _singleton = _create();

  _i27.AppMenuModel _create() => _i27.AppMenuModel(
    _activeWindowTracker$Provider.get(),
    _projectSession$Provider.get(),
    _settingsStore$Provider.get(),
    _activeGraph$Provider.get(),
    _projectsSearchFocus$Provider.get(),
    _appWindows$Provider.get(),
    _appWindowActions$Provider.get(),
    _openUrl$Provider.get(),
  );

  @override
  _i27.AppMenuModel get() => _singleton;
}

class _AppWindowActions$Provider
    implements _i25.Provider<_i28.AppWindowActions> {
  const _AppWindowActions$Provider(
    this._appWindowCoordinator$Provider,
    this._module,
  );

  final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  final _i5.AppModule _module;

  @override
  _i28.AppWindowActions get() =>
      _module.windowActions(_appWindowCoordinator$Provider.get());
}

class _AppWindowCoordinator$Provider
    implements _i25.Provider<_i21.AppWindowCoordinator> {
  _AppWindowCoordinator$Provider(
    this._appWindows$Provider,
    this._projectSession$Provider,
    this._settingsWindowState$Provider,
    this._zanshinAppFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
    this._projectsWindowFactory$Provider,
    this._revsetConfigsWindowFactory$Provider,
    this._settingsWindowFactory$Provider,
    this._module,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _SettingsWindowState$Provider _settingsWindowState$Provider;

  final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  final _ProjectsWindowFactory$Provider _projectsWindowFactory$Provider;

  final _RevsetConfigsWindowFactory$Provider
  _revsetConfigsWindowFactory$Provider;

  final _SettingsWindowFactory$Provider _settingsWindowFactory$Provider;

  final _i5.AppModule _module;

  late final _i21.AppWindowCoordinator _singleton = _create();

  _i21.AppWindowCoordinator _create() => _module.coordinator(
    _appWindows$Provider.get(),
    _projectSession$Provider.get(),
    _settingsWindowState$Provider.get(),
    _zanshinAppFactory$Provider.get(),
    _zanshinWindowRootFactory$Provider.get(),
    _projectsWindowFactory$Provider.get(),
    _revsetConfigsWindowFactory$Provider.get(),
    _settingsWindowFactory$Provider.get(),
  );

  @override
  _i21.AppWindowCoordinator get() => _singleton;
}

class _AppWindows$Provider implements _i25.Provider<_i8.AppWindows> {
  _AppWindows$Provider(this._module);

  final _i3.BootModule _module;

  late final _i8.AppWindows _singleton = _create();

  _i8.AppWindows _create() => _module.appWindows();

  @override
  _i8.AppWindows get() => _singleton;
}

class _FloatingShellViewModel$Provider
    implements _i25.Provider<_i29.FloatingShellViewModel> {
  const _FloatingShellViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i29.FloatingShellViewModel get() =>
      _i29.FloatingShellViewModel(_settingsStore$Provider.get());
}

class _GetDiagnostics$Provider implements _i25.Provider<_i2.GetDiagnostics> {
  _GetDiagnostics$Provider(this._module);

  final _i2.ZanshinDiagnosticsModule _module;

  late final _i2.GetDiagnostics _singleton = _create();

  _i2.GetDiagnostics _create() => _module.zanshinDiagnostics();

  @override
  _i2.GetDiagnostics get() => _singleton;
}

class _GraphSourceOf$Provider implements _i25.Provider<_i13.GraphSourceOf> {
  const _GraphSourceOf$Provider(this._module);

  final _i1.TestModule _module;

  @override
  _i13.GraphSourceOf get() => _module.graphSourceOf();
}

class _HomePageFactory$Factory implements _i14.HomePageFactory {
  const _HomePageFactory$Factory(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
    this._projectComponentFactory$Provider,
    this._activeGraph$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectComponentFactory$Provider _projectComponentFactory$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  @override
  _i14.HomePage create({_i30.Key? key}) => _i14.HomePage(
    viewModelFactory: _viewModelFactoryOfFloatingShellViewModel$Provider.get(),
    projects: _projectSession$Provider.get(),
    scopes: _projectComponentFactory$Provider.get(),
    activeGraph: _activeGraph$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i25.Provider<_i14.HomePageFactory> {
  _HomePageFactory$Provider(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
    this._projectComponentFactory$Provider,
    this._activeGraph$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectComponentFactory$Provider _projectComponentFactory$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  late final _i14.HomePageFactory _factory = _HomePageFactory$Factory(
    _viewModelFactoryOfFloatingShellViewModel$Provider,
    _projectSession$Provider,
    _projectComponentFactory$Provider,
    _activeGraph$Provider,
  );

  @override
  _i14.HomePageFactory get() => _factory;
}

class _IconRegistry$Provider implements _i25.Provider<_i31.IconRegistry> {
  _IconRegistry$Provider(this._module);

  final _i3.BootModule _module;

  late final _i31.IconRegistry _singleton = _create();

  _i31.IconRegistry _create() => _module.icons();

  @override
  _i31.IconRegistry get() => _singleton;
}

class _OpenUrl$Provider implements _i25.Provider<_i32.OpenUrl> {
  const _OpenUrl$Provider(this._module);

  final _i5.AppModule _module;

  @override
  _i32.OpenUrl get() => _module.openUrl();
}

class _ProjectComponent$BookmarkListModel$Provider
    implements _i25.Provider<_i33.BookmarkListModel> {
  _ProjectComponent$BookmarkListModel$Provider(
    this._refListSourceOf$Provider,
    this._projectComponent$projectRepo$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._projectComponent$refDeleteFlow$Provider,
    this._module,
  );

  final _RefListSourceOf$Provider _refListSourceOf$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectComponent$GraphSearchController$Provider
  _projectComponent$graphSearchController$Provider;

  final _ProjectComponent$RefDeleteFlow$Provider
  _projectComponent$refDeleteFlow$Provider;

  final _i13.ProjectModule _module;

  late final _i33.BookmarkListModel _singleton = _create();

  _i33.BookmarkListModel _create() => _module.bookmarkList(
    _refListSourceOf$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
    _projectComponent$refDeleteFlow$Provider.get(),
  );

  @override
  _i33.BookmarkListModel get() => _singleton;
}

class _ProjectComponent$GraphPreferences$Provider
    implements _i25.Provider<_i34.GraphPreferences> {
  _ProjectComponent$GraphPreferences$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$graphSource$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._projectComponent$projectRepo$Provider,
    this._settingsStore$Provider,
    this._projectComponent$graphStackStore$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$GraphSource$Provider
  _projectComponent$graphSource$Provider;

  final _ProjectComponent$GraphSearchController$Provider
  _projectComponent$graphSearchController$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$GraphStackStore$Provider
  _projectComponent$graphStackStore$Provider;

  final _i13.ProjectModule _module;

  late final _i34.GraphPreferences _singleton = _create();

  _i34.GraphPreferences _create() => _module.graphPreferences(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphSource$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$graphStackStore$Provider.get(),
  );

  @override
  _i34.GraphPreferences get() => _singleton;
}

class _ProjectComponent$GraphSearchController$Provider
    implements _i25.Provider<_i35.GraphSearchController> {
  _ProjectComponent$GraphSearchController$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$graphSource$Provider,
    this._projectComponent$projectRepo$Provider,
    this._projectsEnvironment$Provider,
    this._settingsStore$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$GraphSource$Provider
  _projectComponent$graphSource$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i13.ProjectModule _module;

  late final _i35.GraphSearchController _singleton = _create();

  _i35.GraphSearchController _create() => _module.graphSearch(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphSource$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i35.GraphSearchController get() => _singleton;
}

class _ProjectComponent$GraphSource$Provider
    implements _i25.Provider<_i36.GraphSource> {
  _ProjectComponent$GraphSource$Provider(
    this._graphSourceOf$Provider,
    this._projectComponent$projectRepo$Provider,
    this._module,
  );

  final _GraphSourceOf$Provider _graphSourceOf$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _i13.ProjectModule _module;

  late final _i36.GraphSource _singleton = _create();

  _i36.GraphSource _create() => _module.graphSource(
    _graphSourceOf$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
  );

  @override
  _i36.GraphSource get() => _singleton;
}

class _ProjectComponent$GraphStackStore$Provider
    implements _i25.Provider<_i36.GraphStackStore> {
  _ProjectComponent$GraphStackStore$Provider(
    this._settingsStore$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i13.ProjectModule _module;

  late final _i36.GraphStackStore _singleton = _create();

  _i36.GraphStackStore _create() => _module.stackStore(
    _settingsStore$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i36.GraphStackStore get() => _singleton;
}

class _ProjectComponent$GraphToasts$Provider
    implements _i25.Provider<_i37.GraphToasts> {
  _ProjectComponent$GraphToasts$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$shellToasts$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$ShellToasts$Provider
  _projectComponent$shellToasts$Provider;

  final _i13.ProjectModule _module;

  late final _i37.GraphToasts _singleton = _create();

  _i37.GraphToasts _create() => _module.graphToasts(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$shellToasts$Provider.get(),
  );

  @override
  _i37.GraphToasts get() => _singleton;
}

class _ProjectComponent$GraphViewModel$Provider
    implements _i25.Provider<_i38.GraphViewModel> {
  _ProjectComponent$GraphViewModel$Provider(this._module);

  final _i13.ProjectModule _module;

  late final _i38.GraphViewModel _singleton = _create();

  _i38.GraphViewModel _create() => _module.graphViewModel();

  @override
  _i38.GraphViewModel get() => _singleton;
}

class _ProjectComponent$ImmutableReasons$Provider
    implements _i25.Provider<_i39.ImmutableReasons> {
  _ProjectComponent$ImmutableReasons$Provider(
    this._projectComponent$projectRepo$Provider,
    this._projectsEnvironment$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i13.ProjectModule _module;

  late final _i39.ImmutableReasons _singleton = _create();

  _i39.ImmutableReasons _create() => _module.immutableReasons(
    _projectComponent$projectRepo$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i39.ImmutableReasons get() => _singleton;
}

class _ProjectComponent$InspectorViewModel$Provider
    implements _i25.Provider<_i40.InspectorViewModel> {
  _ProjectComponent$InspectorViewModel$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$projectRepo$Provider,
    this._settingsStore$Provider,
    this._projectComponent$inspectorViewedStore$Provider,
    this._projectsEnvironment$Provider,
    this._projectComponent$projectFiles$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$InspectorViewedStore$Provider
  _projectComponent$inspectorViewedStore$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectComponent$ProjectFiles$Provider
  _projectComponent$projectFiles$Provider;

  final _i13.ProjectModule _module;

  late final _i40.InspectorViewModel _singleton = _create();

  _i40.InspectorViewModel _create() => _module.inspector(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$inspectorViewedStore$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectComponent$projectFiles$Provider.get(),
  );

  @override
  _i40.InspectorViewModel get() => _singleton;
}

class _ProjectComponent$InspectorViewedStore$Provider
    implements _i25.Provider<_i41.InspectorViewedStore> {
  _ProjectComponent$InspectorViewedStore$Provider(
    this._settingsStore$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i13.ProjectModule _module;

  late final _i41.InspectorViewedStore _singleton = _create();

  _i41.InspectorViewedStore _create() => _module.viewedStore(
    _settingsStore$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i41.InspectorViewedStore get() => _singleton;
}

class _ProjectComponent$OperationChangesModelFactory$Factory
    implements _i42.OperationChangesModelFactory {
  const _ProjectComponent$OperationChangesModelFactory$Factory(
    this._projectComponent$operationChangesSource$Provider,
    this._settingsStore$Provider,
  );

  final _ProjectComponent$OperationChangesSource$Provider
  _projectComponent$operationChangesSource$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i42.OperationChangesModel create({required String operation}) =>
      _i42.OperationChangesModel(
        _projectComponent$operationChangesSource$Provider.get(),
        operation: operation,
        settings: _settingsStore$Provider.get(),
      );
}

class _ProjectComponent$OperationChangesModelFactory$Provider
    implements _i25.Provider<_i42.OperationChangesModelFactory> {
  _ProjectComponent$OperationChangesModelFactory$Provider(
    this._projectComponent$operationChangesSource$Provider,
    this._settingsStore$Provider,
  );

  final _ProjectComponent$OperationChangesSource$Provider
  _projectComponent$operationChangesSource$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i42.OperationChangesModelFactory _factory =
      _ProjectComponent$OperationChangesModelFactory$Factory(
        _projectComponent$operationChangesSource$Provider,
        _settingsStore$Provider,
      );

  @override
  _i42.OperationChangesModelFactory get() => _factory;
}

class _ProjectComponent$OperationChangesOf$Provider
    implements _i25.Provider<_i42.OperationChangesOf> {
  const _ProjectComponent$OperationChangesOf$Provider(
    this._projectComponent$operationChangesModelFactory$Provider,
    this._module,
  );

  final _ProjectComponent$OperationChangesModelFactory$Provider
  _projectComponent$operationChangesModelFactory$Provider;

  final _i13.ProjectModule _module;

  @override
  _i42.OperationChangesOf get() => _module.operationChanges(
    _projectComponent$operationChangesModelFactory$Provider.get(),
  );
}

class _ProjectComponent$OperationChangesSource$Provider
    implements _i25.Provider<_i42.OperationChangesSource> {
  const _ProjectComponent$OperationChangesSource$Provider(
    this._projectComponent$projectRepo$Provider,
    this._projectsEnvironment$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i13.ProjectModule _module;

  @override
  _i42.OperationChangesSource get() => _module.operationChangesSource(
    _projectComponent$projectRepo$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );
}

class _ProjectComponent$ProjectFiles$Provider
    implements _i25.Provider<_i43.ProjectFiles> {
  _ProjectComponent$ProjectFiles$Provider(
    this._projectComponent$stringProjectRoot$Provider,
    this._settingsStore$Provider,
    this._projectComponent$shellToasts$Provider,
    this._module,
  );

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$ShellToasts$Provider
  _projectComponent$shellToasts$Provider;

  final _i13.ProjectModule _module;

  late final _i43.ProjectFiles _singleton = _create();

  _i43.ProjectFiles _create() => _module.projectFiles(
    _projectComponent$stringProjectRoot$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$shellToasts$Provider.get(),
  );

  @override
  _i43.ProjectFiles get() => _singleton;
}

class _ProjectComponent$ProjectRepo$Provider
    implements _i25.Provider<_i23.ProjectRepo> {
  const _ProjectComponent$ProjectRepo$Provider(this._value);

  final _i23.ProjectRepo _value;

  @override
  _i23.ProjectRepo get() => _value;
}

class _ProjectComponent$ProjectScope$Provider
    implements _i25.Provider<_i13.ProjectScope> {
  _ProjectComponent$ProjectScope$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$graphPreferences$Provider,
    this._projectComponent$viewStateCleanup$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._projectComponent$inspectorViewModel$Provider,
    this._projectComponent$immutableReasons$Provider,
    this._projectComponent$graphToasts$Provider,
    this._projectComponent$syncModel$Provider,
    this._projectComponent$refDeleteFlow$Provider,
    this._projectComponent$bookmarkListModel$Provider,
    this._projectComponent$tagListModel$Provider,
    this._projectComponent$undoTimelineModel$Provider,
    this._projectComponent$operationChangesOf$Provider,
    this._projectsEnvironment$Provider,
    this._projectComponent$projectRepo$Provider,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$GraphPreferences$Provider
  _projectComponent$graphPreferences$Provider;

  final _ProjectComponent$ViewStateCleanup$Provider
  _projectComponent$viewStateCleanup$Provider;

  final _ProjectComponent$GraphSearchController$Provider
  _projectComponent$graphSearchController$Provider;

  final _ProjectComponent$InspectorViewModel$Provider
  _projectComponent$inspectorViewModel$Provider;

  final _ProjectComponent$ImmutableReasons$Provider
  _projectComponent$immutableReasons$Provider;

  final _ProjectComponent$GraphToasts$Provider
  _projectComponent$graphToasts$Provider;

  final _ProjectComponent$SyncModel$Provider
  _projectComponent$syncModel$Provider;

  final _ProjectComponent$RefDeleteFlow$Provider
  _projectComponent$refDeleteFlow$Provider;

  final _ProjectComponent$BookmarkListModel$Provider
  _projectComponent$bookmarkListModel$Provider;

  final _ProjectComponent$TagListModel$Provider
  _projectComponent$tagListModel$Provider;

  final _ProjectComponent$UndoTimelineModel$Provider
  _projectComponent$undoTimelineModel$Provider;

  final _ProjectComponent$OperationChangesOf$Provider
  _projectComponent$operationChangesOf$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  late final _i13.ProjectScope _singleton = _create();

  _i13.ProjectScope _create() => _i13.ProjectScope(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphPreferences$Provider.get(),
    _projectComponent$viewStateCleanup$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
    _projectComponent$inspectorViewModel$Provider.get(),
    _projectComponent$immutableReasons$Provider.get(),
    _projectComponent$graphToasts$Provider.get(),
    _projectComponent$syncModel$Provider.get(),
    _projectComponent$refDeleteFlow$Provider.get(),
    _projectComponent$bookmarkListModel$Provider.get(),
    _projectComponent$tagListModel$Provider.get(),
    _projectComponent$undoTimelineModel$Provider.get(),
    _projectComponent$operationChangesOf$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
  );

  @override
  _i13.ProjectScope get() => _singleton;
}

class _ProjectComponent$RefDeleteFlow$Provider
    implements _i25.Provider<_i44.RefDeleteFlow> {
  _ProjectComponent$RefDeleteFlow$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$syncModel$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$SyncModel$Provider
  _projectComponent$syncModel$Provider;

  final _i13.ProjectModule _module;

  late final _i44.RefDeleteFlow _singleton = _create();

  _i44.RefDeleteFlow _create() => _module.refDelete(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$syncModel$Provider.get(),
  );

  @override
  _i44.RefDeleteFlow get() => _singleton;
}

class _ProjectComponent$ShellToasts$Provider
    implements _i25.Provider<_i24.ShellToasts> {
  const _ProjectComponent$ShellToasts$Provider(this._value);

  final _i24.ShellToasts _value;

  @override
  _i24.ShellToasts get() => _value;
}

class _ProjectComponent$StringProjectRoot$Provider
    implements _i25.Provider<String> {
  const _ProjectComponent$StringProjectRoot$Provider(this._value);

  final String _value;

  @override
  String get() => _value;
}

class _ProjectComponent$SyncModel$Provider
    implements _i25.Provider<_i45.SyncModel> {
  _ProjectComponent$SyncModel$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._remoteSyncOf$Provider,
    this._projectComponent$projectRepo$Provider,
    this._projectComponent$shellToasts$Provider,
    this._projectSession$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _RemoteSyncOf$Provider _remoteSyncOf$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectComponent$ShellToasts$Provider
  _projectComponent$shellToasts$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i13.ProjectModule _module;

  late final _i45.SyncModel _singleton = _create();

  _i45.SyncModel _create() => _module.syncModel(
    _projectComponent$graphViewModel$Provider.get(),
    _remoteSyncOf$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _projectComponent$shellToasts$Provider.get(),
    _projectSession$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i45.SyncModel get() => _singleton;
}

class _ProjectComponent$TagListModel$Provider
    implements _i25.Provider<_i33.TagListModel> {
  _ProjectComponent$TagListModel$Provider(
    this._refListSourceOf$Provider,
    this._projectComponent$projectRepo$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._projectComponent$refDeleteFlow$Provider,
    this._module,
  );

  final _RefListSourceOf$Provider _refListSourceOf$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectComponent$GraphSearchController$Provider
  _projectComponent$graphSearchController$Provider;

  final _ProjectComponent$RefDeleteFlow$Provider
  _projectComponent$refDeleteFlow$Provider;

  final _i13.ProjectModule _module;

  late final _i33.TagListModel _singleton = _create();

  _i33.TagListModel _create() => _module.tagList(
    _refListSourceOf$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
    _projectComponent$refDeleteFlow$Provider.get(),
  );

  @override
  _i33.TagListModel get() => _singleton;
}

class _ProjectComponent$UndoTimelineModel$Provider
    implements _i25.Provider<_i46.UndoTimelineModel> {
  _ProjectComponent$UndoTimelineModel$Provider(
    this._projectComponent$projectRepo$Provider,
    this._module,
  );

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _i13.ProjectModule _module;

  late final _i46.UndoTimelineModel _singleton = _create();

  _i46.UndoTimelineModel _create() =>
      _module.undoTimeline(_projectComponent$projectRepo$Provider.get());

  @override
  _i46.UndoTimelineModel get() => _singleton;
}

class _ProjectComponent$ViewStateCleanup$Provider
    implements _i25.Provider<_i47.ViewStateCleanup> {
  _ProjectComponent$ViewStateCleanup$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$graphStackStore$Provider,
    this._projectComponent$inspectorViewedStore$Provider,
    this._projectComponent$projectRepo$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$GraphStackStore$Provider
  _projectComponent$graphStackStore$Provider;

  final _ProjectComponent$InspectorViewedStore$Provider
  _projectComponent$inspectorViewedStore$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _i13.ProjectModule _module;

  late final _i47.ViewStateCleanup _singleton = _create();

  _i47.ViewStateCleanup _create() => _module.viewStateCleanup(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphStackStore$Provider.get(),
    _projectComponent$inspectorViewedStore$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
  );

  @override
  _i47.ViewStateCleanup get() => _singleton;
}

class _ProjectComponentFactory$Provider
    implements _i25.Provider<_i13.ProjectComponentFactory> {
  _ProjectComponentFactory$Provider(this._parent);

  final TestComponent$Component _parent;

  late final _i13.ProjectComponentFactory _factory =
      _ProjectComponentFactory$Factory(_parent);

  @override
  _i13.ProjectComponentFactory get() => _factory;
}

class _ProjectRegistry$Provider implements _i25.Provider<_i10.ProjectRegistry> {
  _ProjectRegistry$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i10.ProjectRegistry _singleton = _create();

  _i10.ProjectRegistry _create() =>
      _i10.ProjectRegistry(_settingsStore$Provider.get());

  @override
  _i10.ProjectRegistry get() => _singleton;
}

class _ProjectRepos$Provider implements _i25.Provider<_i23.ProjectRepos> {
  _ProjectRepos$Provider(this._module);

  final _i1.TestModule _module;

  late final _i23.ProjectRepos _singleton = _create();

  _i23.ProjectRepos _create() => _module.projectRepos();

  @override
  _i23.ProjectRepos get() => _singleton;
}

class _ProjectSession$Provider implements _i25.Provider<_i11.ProjectSession> {
  _ProjectSession$Provider(
    this._projectRegistry$Provider,
    this._projectRepos$Provider,
    this._appWindows$Provider,
    this._module,
  );

  final _ProjectRegistry$Provider _projectRegistry$Provider;

  final _ProjectRepos$Provider _projectRepos$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  final _i4.ProjectsModule _module;

  late final _i11.ProjectSession _singleton = _create();

  _i11.ProjectSession _create() => _module.projectSession(
    _projectRegistry$Provider.get(),
    _projectRepos$Provider.get(),
    _appWindows$Provider.get(),
  );

  @override
  _i11.ProjectSession get() => _singleton;
}

class _ProjectsEnvironment$Provider
    implements _i25.Provider<_i17.ProjectsEnvironment> {
  _ProjectsEnvironment$Provider(this._module);

  final _i1.TestModule _module;

  late final _i17.ProjectsEnvironment _singleton = _create();

  _i17.ProjectsEnvironment _create() => _module.projectsEnvironment();

  @override
  _i17.ProjectsEnvironment get() => _singleton;
}

class _ProjectsSearchFocus$Provider
    implements _i25.Provider<_i12.ProjectsSearchFocus> {
  _ProjectsSearchFocus$Provider();

  late final _i12.ProjectsSearchFocus _singleton = _create();

  _i12.ProjectsSearchFocus _create() => _i12.ProjectsSearchFocus();

  @override
  _i12.ProjectsSearchFocus get() => _singleton;
}

class _ProjectsWindowFactory$Factory implements _i18.ProjectsWindowFactory {
  const _ProjectsWindowFactory$Factory(
    this._projectSession$Provider,
    this._projectRegistry$Provider,
    this._projectsEnvironment$Provider,
    this._projectsSearchFocus$Provider,
  );

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectRegistry$Provider _projectRegistry$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectsSearchFocus$Provider _projectsSearchFocus$Provider;

  @override
  _i18.ProjectsWindow create({
    _i48.ValueChanged<_i11.ProjectOpened>? onOpened,
    _i30.Key? key,
  }) => _i18.ProjectsWindow(
    session: _projectSession$Provider.get(),
    registry: _projectRegistry$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    searchFocus: _projectsSearchFocus$Provider.get(),
    onOpened: onOpened,
    key: key,
  );
}

class _ProjectsWindowFactory$Provider
    implements _i25.Provider<_i18.ProjectsWindowFactory> {
  _ProjectsWindowFactory$Provider(
    this._projectSession$Provider,
    this._projectRegistry$Provider,
    this._projectsEnvironment$Provider,
    this._projectsSearchFocus$Provider,
  );

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectRegistry$Provider _projectRegistry$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectsSearchFocus$Provider _projectsSearchFocus$Provider;

  late final _i18.ProjectsWindowFactory _factory =
      _ProjectsWindowFactory$Factory(
        _projectSession$Provider,
        _projectRegistry$Provider,
        _projectsEnvironment$Provider,
        _projectsSearchFocus$Provider,
      );

  @override
  _i18.ProjectsWindowFactory get() => _factory;
}

class _RefListSourceOf$Provider implements _i25.Provider<_i13.RefListSourceOf> {
  const _RefListSourceOf$Provider(this._module);

  final _i1.TestModule _module;

  @override
  _i13.RefListSourceOf get() => _module.refListSourceOf();
}

class _RemoteSyncOf$Provider implements _i25.Provider<_i13.RemoteSyncOf> {
  const _RemoteSyncOf$Provider(
    this._projectsEnvironment$Provider,
    this._module,
  );

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _i1.TestModule _module;

  @override
  _i13.RemoteSyncOf get() =>
      _module.remoteSyncOf(_projectsEnvironment$Provider.get());
}

class _RevsetConfigsWindowFactory$Factory
    implements _i19.RevsetConfigsWindowFactory {
  const _RevsetConfigsWindowFactory$Factory(
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._appWindows$Provider,
    this._openUrl$Provider,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  final _OpenUrl$Provider _openUrl$Provider;

  @override
  _i19.RevsetConfigsWindow create({String? windowKey, _i30.Key? key}) =>
      _i19.RevsetConfigsWindow(
        settings: _settingsStore$Provider.get(),
        graph: _activeGraph$Provider.get(),
        windows: _appWindows$Provider.get(),
        openUrl: _openUrl$Provider.get(),
        windowKey: windowKey,
        key: key,
      );
}

class _RevsetConfigsWindowFactory$Provider
    implements _i25.Provider<_i19.RevsetConfigsWindowFactory> {
  _RevsetConfigsWindowFactory$Provider(
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._appWindows$Provider,
    this._openUrl$Provider,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  final _OpenUrl$Provider _openUrl$Provider;

  late final _i19.RevsetConfigsWindowFactory _factory =
      _RevsetConfigsWindowFactory$Factory(
        _settingsStore$Provider,
        _activeGraph$Provider,
        _appWindows$Provider,
        _openUrl$Provider,
      );

  @override
  _i19.RevsetConfigsWindowFactory get() => _factory;
}

class _SettingsStore$Provider implements _i25.Provider<_i9.SettingsStore> {
  _SettingsStore$Provider(this._module);

  final _i3.BootModule _module;

  late final _i9.SettingsStore _singleton = _create();

  _i9.SettingsStore _create() => _module.settings();

  @override
  _i9.SettingsStore get() => _singleton;
}

class _SettingsViewModel$Provider
    implements _i25.Provider<_i49.SettingsViewModel> {
  const _SettingsViewModel$Provider(
    this._settingsStore$Provider,
    this._projectsEnvironment$Provider,
    this._projectSession$Provider,
    this._activeGraph$Provider,
    this._module,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _i5.AppModule _module;

  @override
  _i49.SettingsViewModel get() => _module.settingsViewModel(
    _settingsStore$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectSession$Provider.get(),
    _activeGraph$Provider.get(),
  );
}

class _SettingsWindowFactory$Factory implements _i20.SettingsWindowFactory {
  const _SettingsWindowFactory$Factory(
    this._appWindows$Provider,
    this._settingsWindowState$Provider,
    this._settingsViewModel$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _SettingsWindowState$Provider _settingsWindowState$Provider;

  final _SettingsViewModel$Provider _settingsViewModel$Provider;

  @override
  _i20.SettingsWindow create({String? windowKey, _i30.Key? key}) =>
      _i20.SettingsWindow(
        windows: _appWindows$Provider.get(),
        state: _settingsWindowState$Provider.get(),
        viewModel: _settingsViewModel$Provider.get(),
        windowKey: windowKey,
        key: key,
      );
}

class _SettingsWindowFactory$Provider
    implements _i25.Provider<_i20.SettingsWindowFactory> {
  _SettingsWindowFactory$Provider(
    this._appWindows$Provider,
    this._settingsWindowState$Provider,
    this._settingsViewModel$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _SettingsWindowState$Provider _settingsWindowState$Provider;

  final _SettingsViewModel$Provider _settingsViewModel$Provider;

  late final _i20.SettingsWindowFactory _factory =
      _SettingsWindowFactory$Factory(
        _appWindows$Provider,
        _settingsWindowState$Provider,
        _settingsViewModel$Provider,
      );

  @override
  _i20.SettingsWindowFactory get() => _factory;
}

class _SettingsWindowState$Provider
    implements _i25.Provider<_i50.SettingsWindowState> {
  _SettingsWindowState$Provider();

  late final _i50.SettingsWindowState _singleton = _create();

  _i50.SettingsWindowState _create() => _i50.SettingsWindowState();

  @override
  _i50.SettingsWindowState get() => _singleton;
}

class _ViewModelFactoryOfFloatingShellViewModel$Provider
    implements
        _i25.Provider<_i51.ViewModelFactory<_i29.FloatingShellViewModel>> {
  const _ViewModelFactoryOfFloatingShellViewModel$Provider(
    this._floatingShellViewModel$Provider,
  );

  final _FloatingShellViewModel$Provider _floatingShellViewModel$Provider;

  @override
  _i51.ViewModelFactory<_i29.FloatingShellViewModel> get() =>
      ({
        required _i51.ViewModelWidgetBuilder<_i29.FloatingShellViewModel>
        builder,
        _i52.Widget? child,
        _i51.ViewModelErrorBuilder? error,
        _i51.ViewModelInitializer<_i29.FloatingShellViewModel>? init,
        _i30.Key? key,
        _i52.Widget? loading,
      }) => _i51.ViewModelBuilder<_i29.FloatingShellViewModel>(
        key: key,
        viewModelProvider: _floatingShellViewModel$Provider,
        init: init,
        loading: loading,
        error: error,
        builder: builder,
        child: child,
      );
}

class _ViewModelFactoryOfZanshinAppViewModel$Provider
    implements _i25.Provider<_i51.ViewModelFactory<_i53.ZanshinAppViewModel>> {
  const _ViewModelFactoryOfZanshinAppViewModel$Provider(
    this._zanshinAppViewModel$Provider,
  );

  final _ZanshinAppViewModel$Provider _zanshinAppViewModel$Provider;

  @override
  _i51.ViewModelFactory<_i53.ZanshinAppViewModel> get() =>
      ({
        required _i51.ViewModelWidgetBuilder<_i53.ZanshinAppViewModel> builder,
        _i52.Widget? child,
        _i51.ViewModelErrorBuilder? error,
        _i51.ViewModelInitializer<_i53.ZanshinAppViewModel>? init,
        _i30.Key? key,
        _i52.Widget? loading,
      }) => _i51.ViewModelBuilder<_i53.ZanshinAppViewModel>(
        key: key,
        viewModelProvider: _zanshinAppViewModel$Provider,
        init: init,
        loading: loading,
        error: error,
        builder: builder,
        child: child,
      );
}

class _WindowAppearanceSync$Provider
    implements _i25.Provider<_i54.WindowAppearanceSync> {
  _WindowAppearanceSync$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i54.WindowAppearanceSync _singleton = _create();

  _i54.WindowAppearanceSync _create() =>
      _i54.WindowAppearanceSync(_settingsStore$Provider.get());

  @override
  _i54.WindowAppearanceSync get() => _singleton;
}

class _ZanshinAppFactory$Factory implements _i16.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  @override
  _i16.ZanshinApp create({_i30.Key? key}) => _i16.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    rootFactory: _zanshinWindowRootFactory$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i25.Provider<_i16.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  late final _i16.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
    _zanshinWindowRootFactory$Provider,
  );

  @override
  _i16.ZanshinAppFactory get() => _factory;
}

class _ZanshinAppViewModel$Provider
    implements _i25.Provider<_i53.ZanshinAppViewModel> {
  const _ZanshinAppViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i53.ZanshinAppViewModel get() =>
      _i53.ZanshinAppViewModel(_settingsStore$Provider.get());
}

class _ZanshinApplication$Provider
    implements _i25.Provider<_i22.ZanshinApplication> {
  _ZanshinApplication$Provider(
    this._appWindowCoordinator$Provider,
    this._appMenuModel$Provider,
    this._settingsStore$Provider,
    this._appWindows$Provider,
    this._appExitHandler$Provider,
    this._windowAppearanceSync$Provider,
  );

  final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  final _AppMenuModel$Provider _appMenuModel$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  final _AppExitHandler$Provider _appExitHandler$Provider;

  final _WindowAppearanceSync$Provider _windowAppearanceSync$Provider;

  late final _i22.ZanshinApplication _singleton = _create();

  _i22.ZanshinApplication _create() => _i22.ZanshinApplication(
    _appWindowCoordinator$Provider.get(),
    _appMenuModel$Provider.get(),
    _settingsStore$Provider.get(),
    _appWindows$Provider.get(),
    _appExitHandler$Provider.get(),
    _windowAppearanceSync$Provider.get(),
  );

  @override
  _i22.ZanshinApplication get() => _singleton;
}

class _ZanshinWindowRootFactory$Factory
    implements _i15.ZanshinWindowRootFactory {
  const _ZanshinWindowRootFactory$Factory(
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
    this._activeWindowTracker$Provider,
    this._iconRegistry$Provider,
  );

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  final _ActiveWindowTracker$Provider _activeWindowTracker$Provider;

  final _IconRegistry$Provider _iconRegistry$Provider;

  @override
  _i15.ZanshinWindowRoot create({
    required String windowKey,
    required _i52.Widget child,
    bool? sizeToContent,
    _i30.Key? key,
  }) => _i15.ZanshinWindowRoot(
    viewModelFactory: _viewModelFactoryOfZanshinAppViewModel$Provider.get(),
    tracker: _activeWindowTracker$Provider.get(),
    icons: _iconRegistry$Provider.get(),
    windowKey: windowKey,
    child: child,
    sizeToContent: sizeToContent,
    key: key,
  );
}

class _ZanshinWindowRootFactory$Provider
    implements _i25.Provider<_i15.ZanshinWindowRootFactory> {
  _ZanshinWindowRootFactory$Provider(
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
    this._activeWindowTracker$Provider,
    this._iconRegistry$Provider,
  );

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  final _ActiveWindowTracker$Provider _activeWindowTracker$Provider;

  final _IconRegistry$Provider _iconRegistry$Provider;

  late final _i15.ZanshinWindowRootFactory _factory =
      _ZanshinWindowRootFactory$Factory(
        _viewModelFactoryOfZanshinAppViewModel$Provider,
        _activeWindowTracker$Provider,
        _iconRegistry$Provider,
      );

  @override
  _i15.ZanshinWindowRootFactory get() => _factory;
}

class _ZanshinWorker$Provider implements _i25.Provider<_i55.ZanshinWorker> {
  _ZanshinWorker$Provider(this._module);

  final _i3.BootModule _module;

  late final _i55.ZanshinWorker _singleton = _create();

  _i55.ZanshinWorker _create() => _module.worker();

  @override
  _i55.ZanshinWorker get() => _singleton;
}
