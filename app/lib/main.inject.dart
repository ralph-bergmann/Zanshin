// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:flutter/src/foundation/basic_types.dart' as _i39;
import 'package:flutter/src/foundation/key.dart' as _i20;
import 'package:flutter/src/widgets/framework.dart' as _i46;
import 'package:inject_annotation/inject_annotation.dart' as _i10;
import 'package:inject_flutter/src/view_model_factory.dart' as _i45;
import 'package:zanshin_core/src/ffi/diagnostics.dart' as _i2;
import 'package:zanshin_core/src/worker/isolate.dart' as _i51;
import 'package:zanshin_settings/src/settings_store.dart' as _i41;
import 'package:zanshin_ui/src/icons/icon_registry.dart' as _i21;

import 'main.dart' as _i1;
import 'src/app/app_exit_handler.dart' as _i13;
import 'src/app/app_module.dart' as _i5;
import 'src/app/app_window_coordinator.dart' as _i16;
import 'src/app/boot/boot_module.dart' as _i3;
import 'src/app/menu/app_menu.dart' as _i14;
import 'src/app/zanshin_app.dart' as _i49;
import 'src/app/zanshin_application.dart' as _i6;
import 'src/features/bookmarks/bookmark_list_model.dart' as _i23;
import 'src/features/graph/active_graph.dart' as _i11;
import 'src/features/graph/graph_inspector.dart' as _i30;
import 'src/features/graph/graph_ports.dart' as _i26;
import 'src/features/graph/graph_preferences.dart' as _i24;
import 'src/features/graph/graph_search_controller.dart' as _i25;
import 'src/features/graph/graph_toasts.dart' as _i27;
import 'src/features/graph/graph_view_model.dart' as _i28;
import 'src/features/graph/immutable_reasons.dart' as _i29;
import 'src/features/graph/revset_configs/revset_configs_window.dart' as _i40;
import 'src/features/home/home_page.dart' as _i19;
import 'src/features/home/project_scope.dart' as _i7;
import 'src/features/projects/project_registry.dart' as _i34;
import 'src/features/projects/project_repos.dart' as _i8;
import 'src/features/projects/project_session.dart' as _i35;
import 'src/features/projects/projects_environment.dart' as _i36;
import 'src/features/projects/projects_module.dart' as _i4;
import 'src/features/projects/projects_search_focus.dart' as _i37;
import 'src/features/projects/projects_window.dart' as _i38;
import 'src/features/settings/settings_view_model.dart' as _i42;
import 'src/features/settings/settings_window.dart' as _i43;
import 'src/features/settings/settings_window_state.dart' as _i44;
import 'src/features/shell/floating_shell_view_model.dart' as _i18;
import 'src/features/shell/shell_toast.dart' as _i9;
import 'src/features/sync/sync_model.dart' as _i32;
import 'src/features/undo_timeline/operation_changes.dart' as _i31;
import 'src/features/undo_timeline/undo_timeline_model.dart' as _i33;
import 'src/features/window/active_window_tracker.dart' as _i12;
import 'src/features/window/app_window_actions.dart' as _i15;
import 'src/features/window/app_windows.dart' as _i17;
import 'src/features/window/window_appearance_sync.dart' as _i48;
import 'src/features/window/zanshin_app_view_model.dart' as _i47;
import 'src/features/window/zanshin_window_root.dart' as _i50;
import 'src/links.dart' as _i22;

class MainComponent$Component implements _i1.MainComponent {
  factory MainComponent$Component.create({
    _i2.ZanshinDiagnosticsModule? zanshinDiagnosticsModule,
    required _i3.BootModule bootModule,
    _i4.ProjectsModule? projectsModule,
    _i5.AppModule? appModule,
  }) => MainComponent$Component._(
    zanshinDiagnosticsModule ?? _i2.ZanshinDiagnosticsModule(),
    bootModule,
    projectsModule ?? _i4.ProjectsModule(),
    appModule ?? _i5.AppModule(),
  );

  MainComponent$Component._(
    _i2.ZanshinDiagnosticsModule zanshinDiagnosticsModule,
    _i3.BootModule bootModule,
    _i4.ProjectsModule projectsModule,
    _i5.AppModule appModule,
  ) {
    final activeGraph$Provider = _ActiveGraph$Provider();
    final activeWindowTracker$Provider = _ActiveWindowTracker$Provider();
    final appWindows$Provider = _AppWindows$Provider(bootModule);
    final zanshinWorker$Provider = _ZanshinWorker$Provider(bootModule);
    final appExitHandler$Provider = _AppExitHandler$Provider(
      appWindows$Provider,
      zanshinWorker$Provider,
    );
    _settingsStore$Provider = _SettingsStore$Provider(bootModule);
    final projectRegistry$Provider = _ProjectRegistry$Provider(
      _settingsStore$Provider,
    );
    final projectRepos$Provider = _ProjectRepos$Provider(
      zanshinWorker$Provider,
      projectsModule,
    );
    _projectSession$Provider = _ProjectSession$Provider(
      projectRegistry$Provider,
      projectRepos$Provider,
      appWindows$Provider,
      projectsModule,
    );
    final projectsSearchFocus$Provider = _ProjectsSearchFocus$Provider();
    final settingsWindowState$Provider = _SettingsWindowState$Provider();
    final floatingShellViewModel$Provider = _FloatingShellViewModel$Provider(
      _settingsStore$Provider,
    );
    final viewModelFactoryOfFloatingShellViewModel$Provider =
        _ViewModelFactoryOfFloatingShellViewModel$Provider(
          floatingShellViewModel$Provider,
        );
    final projectComponentFactory$Provider = _ProjectComponentFactory$Provider(
      this,
    );
    final homePageFactory$Provider = _HomePageFactory$Provider(
      viewModelFactoryOfFloatingShellViewModel$Provider,
      _projectSession$Provider,
      projectComponentFactory$Provider,
      activeGraph$Provider,
    );
    final zanshinAppViewModel$Provider = _ZanshinAppViewModel$Provider(
      _settingsStore$Provider,
    );
    final viewModelFactoryOfZanshinAppViewModel$Provider =
        _ViewModelFactoryOfZanshinAppViewModel$Provider(
          zanshinAppViewModel$Provider,
        );
    final iconRegistry$Provider = _IconRegistry$Provider(bootModule);
    final zanshinWindowRootFactory$Provider =
        _ZanshinWindowRootFactory$Provider(
          viewModelFactoryOfZanshinAppViewModel$Provider,
          activeWindowTracker$Provider,
          iconRegistry$Provider,
        );
    final zanshinAppFactory$Provider = _ZanshinAppFactory$Provider(
      homePageFactory$Provider,
      zanshinWindowRootFactory$Provider,
    );
    final getDiagnostics$Provider = _GetDiagnostics$Provider(
      zanshinDiagnosticsModule,
    );
    _projectsEnvironment$Provider = _ProjectsEnvironment$Provider(
      zanshinWorker$Provider,
      getDiagnostics$Provider,
      projectsModule,
    );
    final projectsWindowFactory$Provider = _ProjectsWindowFactory$Provider(
      _projectSession$Provider,
      projectRegistry$Provider,
      _projectsEnvironment$Provider,
      projectsSearchFocus$Provider,
    );
    final openUrl$Provider = _OpenUrl$Provider(appModule);
    final revsetConfigsWindowFactory$Provider =
        _RevsetConfigsWindowFactory$Provider(
          _settingsStore$Provider,
          activeGraph$Provider,
          appWindows$Provider,
          openUrl$Provider,
        );
    final settingsViewModel$Provider = _SettingsViewModel$Provider(
      _settingsStore$Provider,
      _projectsEnvironment$Provider,
      _projectSession$Provider,
      activeGraph$Provider,
      appModule,
    );
    final settingsWindowFactory$Provider = _SettingsWindowFactory$Provider(
      appWindows$Provider,
      settingsWindowState$Provider,
      settingsViewModel$Provider,
    );
    final appWindowCoordinator$Provider = _AppWindowCoordinator$Provider(
      appWindows$Provider,
      _projectSession$Provider,
      settingsWindowState$Provider,
      zanshinAppFactory$Provider,
      zanshinWindowRootFactory$Provider,
      projectsWindowFactory$Provider,
      revsetConfigsWindowFactory$Provider,
      settingsWindowFactory$Provider,
      appModule,
    );
    final appWindowActions$Provider = _AppWindowActions$Provider(
      appWindowCoordinator$Provider,
      appModule,
    );
    final appMenuModel$Provider = _AppMenuModel$Provider(
      activeWindowTracker$Provider,
      _projectSession$Provider,
      _settingsStore$Provider,
      activeGraph$Provider,
      projectsSearchFocus$Provider,
      appWindows$Provider,
      appWindowActions$Provider,
      openUrl$Provider,
    );
    _graphSourceOf$Provider = _GraphSourceOf$Provider(appModule);
    _remoteSyncOf$Provider = _RemoteSyncOf$Provider(
      _projectsEnvironment$Provider,
      appModule,
    );
    final windowAppearanceSync$Provider = _WindowAppearanceSync$Provider(
      _settingsStore$Provider,
    );
    _zanshinApplication$Provider = _ZanshinApplication$Provider(
      appWindowCoordinator$Provider,
      appMenuModel$Provider,
      _settingsStore$Provider,
      appWindows$Provider,
      appExitHandler$Provider,
      windowAppearanceSync$Provider,
    );
  }

  late final _SettingsStore$Provider _settingsStore$Provider;

  late final _ProjectSession$Provider _projectSession$Provider;

  late final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  late final _GraphSourceOf$Provider _graphSourceOf$Provider;

  late final _RemoteSyncOf$Provider _remoteSyncOf$Provider;

  late final _ZanshinApplication$Provider _zanshinApplication$Provider;

  @override
  _i6.ZanshinApplication get application => _zanshinApplication$Provider.get();
}

class ProjectComponent$Subcomponent implements _i7.ProjectComponent {
  factory ProjectComponent$Subcomponent.create(
    MainComponent$Component parent, {
    _i7.ProjectModule? projectModule,
    required _i8.ProjectRepo repo,
    required String root,
    required _i9.ShellToasts toasts,
  }) => ProjectComponent$Subcomponent._(
    parent,
    projectModule ?? _i7.ProjectModule(),
    repo,
    root,
    toasts,
  );

  ProjectComponent$Subcomponent._(
    this._parent,
    _i7.ProjectModule projectModule,
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
    final projectComponent$bookmarkListModel$Provider =
        _ProjectComponent$BookmarkListModel$Provider(
          _projectComponent$projectRepo$Provider,
          projectComponent$graphSearchController$Provider,
          projectModule,
        );
    final projectComponent$graphPreferences$Provider =
        _ProjectComponent$GraphPreferences$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$graphSource$Provider,
          projectComponent$graphSearchController$Provider,
          _projectComponent$projectRepo$Provider,
          _parent._settingsStore$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    _projectComponent$shellToasts$Provider =
        _ProjectComponent$ShellToasts$Provider(toasts);
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
    final projectComponent$inspectorViewModel$Provider =
        _ProjectComponent$InspectorViewModel$Provider(
          projectComponent$graphViewModel$Provider,
          _projectComponent$projectRepo$Provider,
          _parent._settingsStore$Provider,
          _projectComponent$stringProjectRoot$Provider,
          projectModule,
        );
    final projectComponent$operationChangesSource$Provider =
        _ProjectComponent$OperationChangesSource$Provider(
          _projectComponent$projectRepo$Provider,
          _parent._projectsEnvironment$Provider,
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
    final projectComponent$undoTimelineModel$Provider =
        _ProjectComponent$UndoTimelineModel$Provider(
          _projectComponent$projectRepo$Provider,
          projectModule,
        );
    _projectComponent$projectScope$Provider =
        _ProjectComponent$ProjectScope$Provider(
          projectComponent$graphViewModel$Provider,
          projectComponent$graphPreferences$Provider,
          projectComponent$graphSearchController$Provider,
          projectComponent$inspectorViewModel$Provider,
          projectComponent$immutableReasons$Provider,
          projectComponent$graphToasts$Provider,
          projectComponent$syncModel$Provider,
          projectComponent$bookmarkListModel$Provider,
          projectComponent$undoTimelineModel$Provider,
          projectComponent$operationChangesOf$Provider,
          _parent._projectsEnvironment$Provider,
          _projectComponent$projectRepo$Provider,
        );
  }

  final MainComponent$Component _parent;

  final _i8.ProjectRepo repo;

  final String root;

  final _i9.ShellToasts toasts;

  late final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  late final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  late final _ProjectComponent$ShellToasts$Provider
  _projectComponent$shellToasts$Provider;

  late final _ProjectComponent$ProjectScope$Provider
  _projectComponent$projectScope$Provider;

  @override
  _i7.ProjectScope get scope => _projectComponent$projectScope$Provider.get();
}

class _ProjectComponentFactory$Factory implements _i7.ProjectComponentFactory {
  const _ProjectComponentFactory$Factory(this._parent);

  final MainComponent$Component _parent;

  @override
  _i7.ProjectComponent create(
    _i8.ProjectRepo repo,
    String root,
    _i9.ShellToasts toasts,
  ) => ProjectComponent$Subcomponent.create(
    _parent,
    repo: repo,
    root: root,
    toasts: toasts,
  );
}

class _ActiveGraph$Provider implements _i10.Provider<_i11.ActiveGraph> {
  _ActiveGraph$Provider();

  late final _i11.ActiveGraph _singleton = _create();

  _i11.ActiveGraph _create() => _i11.ActiveGraph();

  @override
  _i11.ActiveGraph get() => _singleton;
}

class _ActiveWindowTracker$Provider
    implements _i10.Provider<_i12.ActiveWindowTracker> {
  _ActiveWindowTracker$Provider();

  late final _i12.ActiveWindowTracker _singleton = _create();

  _i12.ActiveWindowTracker _create() => _i12.ActiveWindowTracker();

  @override
  _i12.ActiveWindowTracker get() => _singleton;
}

class _AppExitHandler$Provider implements _i10.Provider<_i13.AppExitHandler> {
  _AppExitHandler$Provider(
    this._appWindows$Provider,
    this._zanshinWorker$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  late final _i13.AppExitHandler _singleton = _create();

  _i13.AppExitHandler _create() => _i13.AppExitHandler(
    _appWindows$Provider.get(),
    _zanshinWorker$Provider.get(),
  );

  @override
  _i13.AppExitHandler get() => _singleton;
}

class _AppMenuModel$Provider implements _i10.Provider<_i14.AppMenuModel> {
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

  late final _i14.AppMenuModel _singleton = _create();

  _i14.AppMenuModel _create() => _i14.AppMenuModel(
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
  _i14.AppMenuModel get() => _singleton;
}

class _AppWindowActions$Provider
    implements _i10.Provider<_i15.AppWindowActions> {
  const _AppWindowActions$Provider(
    this._appWindowCoordinator$Provider,
    this._module,
  );

  final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  final _i5.AppModule _module;

  @override
  _i15.AppWindowActions get() =>
      _module.windowActions(_appWindowCoordinator$Provider.get());
}

class _AppWindowCoordinator$Provider
    implements _i10.Provider<_i16.AppWindowCoordinator> {
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

  late final _i16.AppWindowCoordinator _singleton = _create();

  _i16.AppWindowCoordinator _create() => _module.coordinator(
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
  _i16.AppWindowCoordinator get() => _singleton;
}

class _AppWindows$Provider implements _i10.Provider<_i17.AppWindows> {
  _AppWindows$Provider(this._module);

  final _i3.BootModule _module;

  late final _i17.AppWindows _singleton = _create();

  _i17.AppWindows _create() => _module.appWindows();

  @override
  _i17.AppWindows get() => _singleton;
}

class _FloatingShellViewModel$Provider
    implements _i10.Provider<_i18.FloatingShellViewModel> {
  const _FloatingShellViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i18.FloatingShellViewModel get() =>
      _i18.FloatingShellViewModel(_settingsStore$Provider.get());
}

class _GetDiagnostics$Provider implements _i10.Provider<_i2.GetDiagnostics> {
  _GetDiagnostics$Provider(this._module);

  final _i2.ZanshinDiagnosticsModule _module;

  late final _i2.GetDiagnostics _singleton = _create();

  _i2.GetDiagnostics _create() => _module.zanshinDiagnostics();

  @override
  _i2.GetDiagnostics get() => _singleton;
}

class _GraphSourceOf$Provider implements _i10.Provider<_i7.GraphSourceOf> {
  const _GraphSourceOf$Provider(this._module);

  final _i5.AppModule _module;

  @override
  _i7.GraphSourceOf get() => _module.graphSourceOf();
}

class _HomePageFactory$Factory implements _i19.HomePageFactory {
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
  _i19.HomePage create({_i20.Key? key}) => _i19.HomePage(
    viewModelFactory: _viewModelFactoryOfFloatingShellViewModel$Provider.get(),
    projects: _projectSession$Provider.get(),
    scopes: _projectComponentFactory$Provider.get(),
    activeGraph: _activeGraph$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i10.Provider<_i19.HomePageFactory> {
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

  late final _i19.HomePageFactory _factory = _HomePageFactory$Factory(
    _viewModelFactoryOfFloatingShellViewModel$Provider,
    _projectSession$Provider,
    _projectComponentFactory$Provider,
    _activeGraph$Provider,
  );

  @override
  _i19.HomePageFactory get() => _factory;
}

class _IconRegistry$Provider implements _i10.Provider<_i21.IconRegistry> {
  _IconRegistry$Provider(this._module);

  final _i3.BootModule _module;

  late final _i21.IconRegistry _singleton = _create();

  _i21.IconRegistry _create() => _module.icons();

  @override
  _i21.IconRegistry get() => _singleton;
}

class _OpenUrl$Provider implements _i10.Provider<_i22.OpenUrl> {
  const _OpenUrl$Provider(this._module);

  final _i5.AppModule _module;

  @override
  _i22.OpenUrl get() => _module.openUrl();
}

class _ProjectComponent$BookmarkListModel$Provider
    implements _i10.Provider<_i23.BookmarkListModel> {
  _ProjectComponent$BookmarkListModel$Provider(
    this._projectComponent$projectRepo$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._module,
  );

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectComponent$GraphSearchController$Provider
  _projectComponent$graphSearchController$Provider;

  final _i7.ProjectModule _module;

  late final _i23.BookmarkListModel _singleton = _create();

  _i23.BookmarkListModel _create() => _module.bookmarkList(
    _projectComponent$projectRepo$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
  );

  @override
  _i23.BookmarkListModel get() => _singleton;
}

class _ProjectComponent$GraphPreferences$Provider
    implements _i10.Provider<_i24.GraphPreferences> {
  _ProjectComponent$GraphPreferences$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$graphSource$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._projectComponent$projectRepo$Provider,
    this._settingsStore$Provider,
    this._projectComponent$stringProjectRoot$Provider,
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

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i7.ProjectModule _module;

  late final _i24.GraphPreferences _singleton = _create();

  _i24.GraphPreferences _create() => _module.graphPreferences(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphSource$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i24.GraphPreferences get() => _singleton;
}

class _ProjectComponent$GraphSearchController$Provider
    implements _i10.Provider<_i25.GraphSearchController> {
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

  final _i7.ProjectModule _module;

  late final _i25.GraphSearchController _singleton = _create();

  _i25.GraphSearchController _create() => _module.graphSearch(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphSource$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i25.GraphSearchController get() => _singleton;
}

class _ProjectComponent$GraphSource$Provider
    implements _i10.Provider<_i26.GraphSource> {
  _ProjectComponent$GraphSource$Provider(
    this._graphSourceOf$Provider,
    this._projectComponent$projectRepo$Provider,
    this._module,
  );

  final _GraphSourceOf$Provider _graphSourceOf$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _i7.ProjectModule _module;

  late final _i26.GraphSource _singleton = _create();

  _i26.GraphSource _create() => _module.graphSource(
    _graphSourceOf$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
  );

  @override
  _i26.GraphSource get() => _singleton;
}

class _ProjectComponent$GraphToasts$Provider
    implements _i10.Provider<_i27.GraphToasts> {
  _ProjectComponent$GraphToasts$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$shellToasts$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$ShellToasts$Provider
  _projectComponent$shellToasts$Provider;

  final _i7.ProjectModule _module;

  late final _i27.GraphToasts _singleton = _create();

  _i27.GraphToasts _create() => _module.graphToasts(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$shellToasts$Provider.get(),
  );

  @override
  _i27.GraphToasts get() => _singleton;
}

class _ProjectComponent$GraphViewModel$Provider
    implements _i10.Provider<_i28.GraphViewModel> {
  _ProjectComponent$GraphViewModel$Provider(this._module);

  final _i7.ProjectModule _module;

  late final _i28.GraphViewModel _singleton = _create();

  _i28.GraphViewModel _create() => _module.graphViewModel();

  @override
  _i28.GraphViewModel get() => _singleton;
}

class _ProjectComponent$ImmutableReasons$Provider
    implements _i10.Provider<_i29.ImmutableReasons> {
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

  final _i7.ProjectModule _module;

  late final _i29.ImmutableReasons _singleton = _create();

  _i29.ImmutableReasons _create() => _module.immutableReasons(
    _projectComponent$projectRepo$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i29.ImmutableReasons get() => _singleton;
}

class _ProjectComponent$InspectorViewModel$Provider
    implements _i10.Provider<_i30.InspectorViewModel> {
  _ProjectComponent$InspectorViewModel$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$projectRepo$Provider,
    this._settingsStore$Provider,
    this._projectComponent$stringProjectRoot$Provider,
    this._module,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectComponent$StringProjectRoot$Provider
  _projectComponent$stringProjectRoot$Provider;

  final _i7.ProjectModule _module;

  late final _i30.InspectorViewModel _singleton = _create();

  _i30.InspectorViewModel _create() => _module.inspector(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _settingsStore$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i30.InspectorViewModel get() => _singleton;
}

class _ProjectComponent$OperationChangesModelFactory$Factory
    implements _i31.OperationChangesModelFactory {
  const _ProjectComponent$OperationChangesModelFactory$Factory(
    this._projectComponent$operationChangesSource$Provider,
    this._settingsStore$Provider,
  );

  final _ProjectComponent$OperationChangesSource$Provider
  _projectComponent$operationChangesSource$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i31.OperationChangesModel create({required String operation}) =>
      _i31.OperationChangesModel(
        _projectComponent$operationChangesSource$Provider.get(),
        operation: operation,
        settings: _settingsStore$Provider.get(),
      );
}

class _ProjectComponent$OperationChangesModelFactory$Provider
    implements _i10.Provider<_i31.OperationChangesModelFactory> {
  _ProjectComponent$OperationChangesModelFactory$Provider(
    this._projectComponent$operationChangesSource$Provider,
    this._settingsStore$Provider,
  );

  final _ProjectComponent$OperationChangesSource$Provider
  _projectComponent$operationChangesSource$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i31.OperationChangesModelFactory _factory =
      _ProjectComponent$OperationChangesModelFactory$Factory(
        _projectComponent$operationChangesSource$Provider,
        _settingsStore$Provider,
      );

  @override
  _i31.OperationChangesModelFactory get() => _factory;
}

class _ProjectComponent$OperationChangesOf$Provider
    implements _i10.Provider<_i31.OperationChangesOf> {
  const _ProjectComponent$OperationChangesOf$Provider(
    this._projectComponent$operationChangesModelFactory$Provider,
    this._module,
  );

  final _ProjectComponent$OperationChangesModelFactory$Provider
  _projectComponent$operationChangesModelFactory$Provider;

  final _i7.ProjectModule _module;

  @override
  _i31.OperationChangesOf get() => _module.operationChanges(
    _projectComponent$operationChangesModelFactory$Provider.get(),
  );
}

class _ProjectComponent$OperationChangesSource$Provider
    implements _i10.Provider<_i31.OperationChangesSource> {
  const _ProjectComponent$OperationChangesSource$Provider(
    this._projectComponent$projectRepo$Provider,
    this._projectsEnvironment$Provider,
    this._module,
  );

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _i7.ProjectModule _module;

  @override
  _i31.OperationChangesSource get() => _module.operationChangesSource(
    _projectComponent$projectRepo$Provider.get(),
    _projectsEnvironment$Provider.get(),
  );
}

class _ProjectComponent$ProjectRepo$Provider
    implements _i10.Provider<_i8.ProjectRepo> {
  const _ProjectComponent$ProjectRepo$Provider(this._value);

  final _i8.ProjectRepo _value;

  @override
  _i8.ProjectRepo get() => _value;
}

class _ProjectComponent$ProjectScope$Provider
    implements _i10.Provider<_i7.ProjectScope> {
  _ProjectComponent$ProjectScope$Provider(
    this._projectComponent$graphViewModel$Provider,
    this._projectComponent$graphPreferences$Provider,
    this._projectComponent$graphSearchController$Provider,
    this._projectComponent$inspectorViewModel$Provider,
    this._projectComponent$immutableReasons$Provider,
    this._projectComponent$graphToasts$Provider,
    this._projectComponent$syncModel$Provider,
    this._projectComponent$bookmarkListModel$Provider,
    this._projectComponent$undoTimelineModel$Provider,
    this._projectComponent$operationChangesOf$Provider,
    this._projectsEnvironment$Provider,
    this._projectComponent$projectRepo$Provider,
  );

  final _ProjectComponent$GraphViewModel$Provider
  _projectComponent$graphViewModel$Provider;

  final _ProjectComponent$GraphPreferences$Provider
  _projectComponent$graphPreferences$Provider;

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

  final _ProjectComponent$BookmarkListModel$Provider
  _projectComponent$bookmarkListModel$Provider;

  final _ProjectComponent$UndoTimelineModel$Provider
  _projectComponent$undoTimelineModel$Provider;

  final _ProjectComponent$OperationChangesOf$Provider
  _projectComponent$operationChangesOf$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  late final _i7.ProjectScope _singleton = _create();

  _i7.ProjectScope _create() => _i7.ProjectScope(
    _projectComponent$graphViewModel$Provider.get(),
    _projectComponent$graphPreferences$Provider.get(),
    _projectComponent$graphSearchController$Provider.get(),
    _projectComponent$inspectorViewModel$Provider.get(),
    _projectComponent$immutableReasons$Provider.get(),
    _projectComponent$graphToasts$Provider.get(),
    _projectComponent$syncModel$Provider.get(),
    _projectComponent$bookmarkListModel$Provider.get(),
    _projectComponent$undoTimelineModel$Provider.get(),
    _projectComponent$operationChangesOf$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
  );

  @override
  _i7.ProjectScope get() => _singleton;
}

class _ProjectComponent$ShellToasts$Provider
    implements _i10.Provider<_i9.ShellToasts> {
  const _ProjectComponent$ShellToasts$Provider(this._value);

  final _i9.ShellToasts _value;

  @override
  _i9.ShellToasts get() => _value;
}

class _ProjectComponent$StringProjectRoot$Provider
    implements _i10.Provider<String> {
  const _ProjectComponent$StringProjectRoot$Provider(this._value);

  final String _value;

  @override
  String get() => _value;
}

class _ProjectComponent$SyncModel$Provider
    implements _i10.Provider<_i32.SyncModel> {
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

  final _i7.ProjectModule _module;

  late final _i32.SyncModel _singleton = _create();

  _i32.SyncModel _create() => _module.syncModel(
    _projectComponent$graphViewModel$Provider.get(),
    _remoteSyncOf$Provider.get(),
    _projectComponent$projectRepo$Provider.get(),
    _projectComponent$shellToasts$Provider.get(),
    _projectSession$Provider.get(),
    _projectComponent$stringProjectRoot$Provider.get(),
  );

  @override
  _i32.SyncModel get() => _singleton;
}

class _ProjectComponent$UndoTimelineModel$Provider
    implements _i10.Provider<_i33.UndoTimelineModel> {
  _ProjectComponent$UndoTimelineModel$Provider(
    this._projectComponent$projectRepo$Provider,
    this._module,
  );

  final _ProjectComponent$ProjectRepo$Provider
  _projectComponent$projectRepo$Provider;

  final _i7.ProjectModule _module;

  late final _i33.UndoTimelineModel _singleton = _create();

  _i33.UndoTimelineModel _create() =>
      _module.undoTimeline(_projectComponent$projectRepo$Provider.get());

  @override
  _i33.UndoTimelineModel get() => _singleton;
}

class _ProjectComponentFactory$Provider
    implements _i10.Provider<_i7.ProjectComponentFactory> {
  _ProjectComponentFactory$Provider(this._parent);

  final MainComponent$Component _parent;

  late final _i7.ProjectComponentFactory _factory =
      _ProjectComponentFactory$Factory(_parent);

  @override
  _i7.ProjectComponentFactory get() => _factory;
}

class _ProjectRegistry$Provider implements _i10.Provider<_i34.ProjectRegistry> {
  _ProjectRegistry$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i34.ProjectRegistry _singleton = _create();

  _i34.ProjectRegistry _create() =>
      _i34.ProjectRegistry(_settingsStore$Provider.get());

  @override
  _i34.ProjectRegistry get() => _singleton;
}

class _ProjectRepos$Provider implements _i10.Provider<_i8.ProjectRepos> {
  _ProjectRepos$Provider(this._zanshinWorker$Provider, this._module);

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  final _i4.ProjectsModule _module;

  late final _i8.ProjectRepos _singleton = _create();

  _i8.ProjectRepos _create() =>
      _module.projectRepos(_zanshinWorker$Provider.get());

  @override
  _i8.ProjectRepos get() => _singleton;
}

class _ProjectSession$Provider implements _i10.Provider<_i35.ProjectSession> {
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

  late final _i35.ProjectSession _singleton = _create();

  _i35.ProjectSession _create() => _module.projectSession(
    _projectRegistry$Provider.get(),
    _projectRepos$Provider.get(),
    _appWindows$Provider.get(),
  );

  @override
  _i35.ProjectSession get() => _singleton;
}

class _ProjectsEnvironment$Provider
    implements _i10.Provider<_i36.ProjectsEnvironment> {
  _ProjectsEnvironment$Provider(
    this._zanshinWorker$Provider,
    this._getDiagnostics$Provider,
    this._module,
  );

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  final _GetDiagnostics$Provider _getDiagnostics$Provider;

  final _i4.ProjectsModule _module;

  late final _i36.ProjectsEnvironment _singleton = _create();

  _i36.ProjectsEnvironment _create() => _module.projectsEnvironment(
    _zanshinWorker$Provider.get(),
    _getDiagnostics$Provider.get(),
  );

  @override
  _i36.ProjectsEnvironment get() => _singleton;
}

class _ProjectsSearchFocus$Provider
    implements _i10.Provider<_i37.ProjectsSearchFocus> {
  _ProjectsSearchFocus$Provider();

  late final _i37.ProjectsSearchFocus _singleton = _create();

  _i37.ProjectsSearchFocus _create() => _i37.ProjectsSearchFocus();

  @override
  _i37.ProjectsSearchFocus get() => _singleton;
}

class _ProjectsWindowFactory$Factory implements _i38.ProjectsWindowFactory {
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
  _i38.ProjectsWindow create({
    _i39.ValueChanged<_i35.ProjectOpened>? onOpened,
    _i20.Key? key,
  }) => _i38.ProjectsWindow(
    session: _projectSession$Provider.get(),
    registry: _projectRegistry$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    searchFocus: _projectsSearchFocus$Provider.get(),
    onOpened: onOpened,
    key: key,
  );
}

class _ProjectsWindowFactory$Provider
    implements _i10.Provider<_i38.ProjectsWindowFactory> {
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

  late final _i38.ProjectsWindowFactory _factory =
      _ProjectsWindowFactory$Factory(
        _projectSession$Provider,
        _projectRegistry$Provider,
        _projectsEnvironment$Provider,
        _projectsSearchFocus$Provider,
      );

  @override
  _i38.ProjectsWindowFactory get() => _factory;
}

class _RemoteSyncOf$Provider implements _i10.Provider<_i7.RemoteSyncOf> {
  const _RemoteSyncOf$Provider(
    this._projectsEnvironment$Provider,
    this._module,
  );

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _i5.AppModule _module;

  @override
  _i7.RemoteSyncOf get() =>
      _module.remoteSyncOf(_projectsEnvironment$Provider.get());
}

class _RevsetConfigsWindowFactory$Factory
    implements _i40.RevsetConfigsWindowFactory {
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
  _i40.RevsetConfigsWindow create({String? windowKey, _i20.Key? key}) =>
      _i40.RevsetConfigsWindow(
        settings: _settingsStore$Provider.get(),
        graph: _activeGraph$Provider.get(),
        windows: _appWindows$Provider.get(),
        openUrl: _openUrl$Provider.get(),
        windowKey: windowKey,
        key: key,
      );
}

class _RevsetConfigsWindowFactory$Provider
    implements _i10.Provider<_i40.RevsetConfigsWindowFactory> {
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

  late final _i40.RevsetConfigsWindowFactory _factory =
      _RevsetConfigsWindowFactory$Factory(
        _settingsStore$Provider,
        _activeGraph$Provider,
        _appWindows$Provider,
        _openUrl$Provider,
      );

  @override
  _i40.RevsetConfigsWindowFactory get() => _factory;
}

class _SettingsStore$Provider implements _i10.Provider<_i41.SettingsStore> {
  _SettingsStore$Provider(this._module);

  final _i3.BootModule _module;

  late final _i41.SettingsStore _singleton = _create();

  _i41.SettingsStore _create() => _module.settings();

  @override
  _i41.SettingsStore get() => _singleton;
}

class _SettingsViewModel$Provider
    implements _i10.Provider<_i42.SettingsViewModel> {
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
  _i42.SettingsViewModel get() => _module.settingsViewModel(
    _settingsStore$Provider.get(),
    _projectsEnvironment$Provider.get(),
    _projectSession$Provider.get(),
    _activeGraph$Provider.get(),
  );
}

class _SettingsWindowFactory$Factory implements _i43.SettingsWindowFactory {
  const _SettingsWindowFactory$Factory(
    this._appWindows$Provider,
    this._settingsWindowState$Provider,
    this._settingsViewModel$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _SettingsWindowState$Provider _settingsWindowState$Provider;

  final _SettingsViewModel$Provider _settingsViewModel$Provider;

  @override
  _i43.SettingsWindow create({String? windowKey, _i20.Key? key}) =>
      _i43.SettingsWindow(
        windows: _appWindows$Provider.get(),
        state: _settingsWindowState$Provider.get(),
        viewModel: _settingsViewModel$Provider.get(),
        windowKey: windowKey,
        key: key,
      );
}

class _SettingsWindowFactory$Provider
    implements _i10.Provider<_i43.SettingsWindowFactory> {
  _SettingsWindowFactory$Provider(
    this._appWindows$Provider,
    this._settingsWindowState$Provider,
    this._settingsViewModel$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _SettingsWindowState$Provider _settingsWindowState$Provider;

  final _SettingsViewModel$Provider _settingsViewModel$Provider;

  late final _i43.SettingsWindowFactory _factory =
      _SettingsWindowFactory$Factory(
        _appWindows$Provider,
        _settingsWindowState$Provider,
        _settingsViewModel$Provider,
      );

  @override
  _i43.SettingsWindowFactory get() => _factory;
}

class _SettingsWindowState$Provider
    implements _i10.Provider<_i44.SettingsWindowState> {
  _SettingsWindowState$Provider();

  late final _i44.SettingsWindowState _singleton = _create();

  _i44.SettingsWindowState _create() => _i44.SettingsWindowState();

  @override
  _i44.SettingsWindowState get() => _singleton;
}

class _ViewModelFactoryOfFloatingShellViewModel$Provider
    implements
        _i10.Provider<_i45.ViewModelFactory<_i18.FloatingShellViewModel>> {
  const _ViewModelFactoryOfFloatingShellViewModel$Provider(
    this._floatingShellViewModel$Provider,
  );

  final _FloatingShellViewModel$Provider _floatingShellViewModel$Provider;

  @override
  _i45.ViewModelFactory<_i18.FloatingShellViewModel> get() =>
      ({
        required _i45.ViewModelWidgetBuilder<_i18.FloatingShellViewModel>
        builder,
        _i46.Widget? child,
        _i45.ViewModelErrorBuilder? error,
        _i45.ViewModelInitializer<_i18.FloatingShellViewModel>? init,
        _i20.Key? key,
        _i46.Widget? loading,
      }) => _i45.ViewModelBuilder<_i18.FloatingShellViewModel>(
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
    implements _i10.Provider<_i45.ViewModelFactory<_i47.ZanshinAppViewModel>> {
  const _ViewModelFactoryOfZanshinAppViewModel$Provider(
    this._zanshinAppViewModel$Provider,
  );

  final _ZanshinAppViewModel$Provider _zanshinAppViewModel$Provider;

  @override
  _i45.ViewModelFactory<_i47.ZanshinAppViewModel> get() =>
      ({
        required _i45.ViewModelWidgetBuilder<_i47.ZanshinAppViewModel> builder,
        _i46.Widget? child,
        _i45.ViewModelErrorBuilder? error,
        _i45.ViewModelInitializer<_i47.ZanshinAppViewModel>? init,
        _i20.Key? key,
        _i46.Widget? loading,
      }) => _i45.ViewModelBuilder<_i47.ZanshinAppViewModel>(
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
    implements _i10.Provider<_i48.WindowAppearanceSync> {
  _WindowAppearanceSync$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i48.WindowAppearanceSync _singleton = _create();

  _i48.WindowAppearanceSync _create() =>
      _i48.WindowAppearanceSync(_settingsStore$Provider.get());

  @override
  _i48.WindowAppearanceSync get() => _singleton;
}

class _ZanshinAppFactory$Factory implements _i49.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  @override
  _i49.ZanshinApp create({_i20.Key? key}) => _i49.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    rootFactory: _zanshinWindowRootFactory$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i10.Provider<_i49.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  late final _i49.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
    _zanshinWindowRootFactory$Provider,
  );

  @override
  _i49.ZanshinAppFactory get() => _factory;
}

class _ZanshinAppViewModel$Provider
    implements _i10.Provider<_i47.ZanshinAppViewModel> {
  const _ZanshinAppViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i47.ZanshinAppViewModel get() =>
      _i47.ZanshinAppViewModel(_settingsStore$Provider.get());
}

class _ZanshinApplication$Provider
    implements _i10.Provider<_i6.ZanshinApplication> {
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

  late final _i6.ZanshinApplication _singleton = _create();

  _i6.ZanshinApplication _create() => _i6.ZanshinApplication(
    _appWindowCoordinator$Provider.get(),
    _appMenuModel$Provider.get(),
    _settingsStore$Provider.get(),
    _appWindows$Provider.get(),
    _appExitHandler$Provider.get(),
    _windowAppearanceSync$Provider.get(),
  );

  @override
  _i6.ZanshinApplication get() => _singleton;
}

class _ZanshinWindowRootFactory$Factory
    implements _i50.ZanshinWindowRootFactory {
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
  _i50.ZanshinWindowRoot create({
    required String windowKey,
    required _i46.Widget child,
    bool? sizeToContent,
    _i20.Key? key,
  }) => _i50.ZanshinWindowRoot(
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
    implements _i10.Provider<_i50.ZanshinWindowRootFactory> {
  _ZanshinWindowRootFactory$Provider(
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
    this._activeWindowTracker$Provider,
    this._iconRegistry$Provider,
  );

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  final _ActiveWindowTracker$Provider _activeWindowTracker$Provider;

  final _IconRegistry$Provider _iconRegistry$Provider;

  late final _i50.ZanshinWindowRootFactory _factory =
      _ZanshinWindowRootFactory$Factory(
        _viewModelFactoryOfZanshinAppViewModel$Provider,
        _activeWindowTracker$Provider,
        _iconRegistry$Provider,
      );

  @override
  _i50.ZanshinWindowRootFactory get() => _factory;
}

class _ZanshinWorker$Provider implements _i10.Provider<_i51.ZanshinWorker> {
  _ZanshinWorker$Provider(this._module);

  final _i3.BootModule _module;

  late final _i51.ZanshinWorker _singleton = _create();

  _i51.ZanshinWorker _create() => _module.worker();

  @override
  _i51.ZanshinWorker get() => _singleton;
}
