// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:flutter/src/foundation/basic_types.dart' as _i31;
import 'package:flutter/src/foundation/key.dart' as _i27;
import 'package:flutter/src/widgets/framework.dart' as _i35;
import 'package:inject_annotation/inject_annotation.dart' as _i22;
import 'package:inject_flutter/src/view_model_factory.dart' as _i34;
import 'package:zanshin/src/app/app_exit_handler.dart' as _i23;
import 'package:zanshin/src/app/app_module.dart' as _i5;
import 'package:zanshin/src/app/app_window_coordinator.dart' as _i20;
import 'package:zanshin/src/app/boot/boot_module.dart' as _i3;
import 'package:zanshin/src/app/menu/app_menu.dart' as _i24;
import 'package:zanshin/src/app/zanshin_app.dart' as _i16;
import 'package:zanshin/src/app/zanshin_application.dart' as _i21;
import 'package:zanshin/src/features/graph/active_graph.dart' as _i6;
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart'
    as _i18;
import 'package:zanshin/src/features/home/home_page.dart' as _i14;
import 'package:zanshin/src/features/projects/project_registry.dart' as _i10;
import 'package:zanshin/src/features/projects/project_repos.dart' as _i30;
import 'package:zanshin/src/features/projects/project_session.dart' as _i11;
import 'package:zanshin/src/features/projects/projects_environment.dart'
    as _i13;
import 'package:zanshin/src/features/projects/projects_module.dart' as _i4;
import 'package:zanshin/src/features/projects/projects_search_focus.dart'
    as _i12;
import 'package:zanshin/src/features/projects/projects_window.dart' as _i17;
import 'package:zanshin/src/features/settings/settings_view_model.dart' as _i33;
import 'package:zanshin/src/features/settings/settings_window.dart' as _i19;
import 'package:zanshin/src/features/settings/settings_window_state.dart'
    as _i32;
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart'
    as _i26;
import 'package:zanshin/src/features/window/active_window_tracker.dart' as _i7;
import 'package:zanshin/src/features/window/app_window_actions.dart' as _i25;
import 'package:zanshin/src/features/window/app_windows.dart' as _i8;
import 'package:zanshin/src/features/window/window_appearance_sync.dart'
    as _i37;
import 'package:zanshin/src/features/window/zanshin_app_view_model.dart'
    as _i36;
import 'package:zanshin/src/features/window/zanshin_window_root.dart' as _i15;
import 'package:zanshin/src/links.dart' as _i29;
import 'package:zanshin_core/src/ffi/diagnostics.dart' as _i2;
import 'package:zanshin_core/src/worker/isolate.dart' as _i38;
import 'package:zanshin_settings/src/settings_store.dart' as _i9;
import 'package:zanshin_ui/src/icons/icon_registry.dart' as _i28;

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
    final floatingShellViewModel$Provider = _FloatingShellViewModel$Provider(
      _settingsStore$Provider,
    );
    final viewModelFactoryOfFloatingShellViewModel$Provider =
        _ViewModelFactoryOfFloatingShellViewModel$Provider(
          floatingShellViewModel$Provider,
        );
    _projectsEnvironment$Provider = _ProjectsEnvironment$Provider(testModule);
    _homePageFactory$Provider = _HomePageFactory$Provider(
      viewModelFactoryOfFloatingShellViewModel$Provider,
      _projectSession$Provider,
      _projectsEnvironment$Provider,
      _settingsStore$Provider,
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
    _projectsWindowFactory$Provider = _ProjectsWindowFactory$Provider(
      _projectSession$Provider,
      _projectRegistry$Provider,
      _projectsEnvironment$Provider,
      _projectsSearchFocus$Provider,
    );
    _revsetConfigsWindowFactory$Provider = _RevsetConfigsWindowFactory$Provider(
      _settingsStore$Provider,
      _activeGraph$Provider,
      _appWindows$Provider,
    );
    _settingsWindowFactory$Provider = _SettingsWindowFactory$Provider(
      _appWindows$Provider,
      _settingsStore$Provider,
      _projectsEnvironment$Provider,
      _projectSession$Provider,
      _activeGraph$Provider,
    );
    final openUrl$Provider = _OpenUrl$Provider(appModule);
    _appWindowCoordinator$Provider = _AppWindowCoordinator$Provider(
      _appWindows$Provider,
      _projectSession$Provider,
      _zanshinAppFactory$Provider,
      _zanshinWindowRootFactory$Provider,
      _projectsWindowFactory$Provider,
      _revsetConfigsWindowFactory$Provider,
      _settingsWindowFactory$Provider,
      openUrl$Provider,
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

  late final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  late final _HomePageFactory$Provider _homePageFactory$Provider;

  late final _ZanshinWindowRootFactory$Provider
  _zanshinWindowRootFactory$Provider;

  late final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  late final _ProjectsWindowFactory$Provider _projectsWindowFactory$Provider;

  late final _RevsetConfigsWindowFactory$Provider
  _revsetConfigsWindowFactory$Provider;

  late final _SettingsWindowFactory$Provider _settingsWindowFactory$Provider;

  late final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  late final _GetDiagnostics$Provider _getDiagnostics$Provider;

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
  _i13.ProjectsEnvironment get environment =>
      _projectsEnvironment$Provider.get();

  @override
  _i14.HomePageFactory get homePageFactory => _homePageFactory$Provider.get();

  @override
  _i15.ZanshinWindowRootFactory get rootFactory =>
      _zanshinWindowRootFactory$Provider.get();

  @override
  _i16.ZanshinAppFactory get appFactory => _zanshinAppFactory$Provider.get();

  @override
  _i17.ProjectsWindowFactory get projectsWindowFactory =>
      _projectsWindowFactory$Provider.get();

  @override
  _i18.RevsetConfigsWindowFactory get revsetConfigsWindowFactory =>
      _revsetConfigsWindowFactory$Provider.get();

  @override
  _i19.SettingsWindowFactory get settingsWindowFactory =>
      _settingsWindowFactory$Provider.get();

  @override
  _i20.AppWindowCoordinator get coordinator =>
      _appWindowCoordinator$Provider.get();

  @override
  _i2.GetDiagnostics get diagnostics => _getDiagnostics$Provider.get();

  @override
  _i21.ZanshinApplication get application => _zanshinApplication$Provider.get();
}

class _ActiveGraph$Provider implements _i22.Provider<_i6.ActiveGraph> {
  _ActiveGraph$Provider();

  late final _i6.ActiveGraph _singleton = _create();

  _i6.ActiveGraph _create() => _i6.ActiveGraph();

  @override
  _i6.ActiveGraph get() => _singleton;
}

class _ActiveWindowTracker$Provider
    implements _i22.Provider<_i7.ActiveWindowTracker> {
  _ActiveWindowTracker$Provider();

  late final _i7.ActiveWindowTracker _singleton = _create();

  _i7.ActiveWindowTracker _create() => _i7.ActiveWindowTracker();

  @override
  _i7.ActiveWindowTracker get() => _singleton;
}

class _AppExitHandler$Provider implements _i22.Provider<_i23.AppExitHandler> {
  _AppExitHandler$Provider(
    this._appWindows$Provider,
    this._zanshinWorker$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  late final _i23.AppExitHandler _singleton = _create();

  _i23.AppExitHandler _create() => _i23.AppExitHandler(
    _appWindows$Provider.get(),
    _zanshinWorker$Provider.get(),
  );

  @override
  _i23.AppExitHandler get() => _singleton;
}

class _AppMenuModel$Provider implements _i22.Provider<_i24.AppMenuModel> {
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

  late final _i24.AppMenuModel _singleton = _create();

  _i24.AppMenuModel _create() => _i24.AppMenuModel(
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
  _i24.AppMenuModel get() => _singleton;
}

class _AppWindowActions$Provider
    implements _i22.Provider<_i25.AppWindowActions> {
  const _AppWindowActions$Provider(
    this._appWindowCoordinator$Provider,
    this._module,
  );

  final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  final _i5.AppModule _module;

  @override
  _i25.AppWindowActions get() =>
      _module.windowActions(_appWindowCoordinator$Provider.get());
}

class _AppWindowCoordinator$Provider
    implements _i22.Provider<_i20.AppWindowCoordinator> {
  _AppWindowCoordinator$Provider(
    this._appWindows$Provider,
    this._projectSession$Provider,
    this._zanshinAppFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
    this._projectsWindowFactory$Provider,
    this._revsetConfigsWindowFactory$Provider,
    this._settingsWindowFactory$Provider,
    this._openUrl$Provider,
    this._module,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  final _ProjectsWindowFactory$Provider _projectsWindowFactory$Provider;

  final _RevsetConfigsWindowFactory$Provider
  _revsetConfigsWindowFactory$Provider;

  final _SettingsWindowFactory$Provider _settingsWindowFactory$Provider;

  final _OpenUrl$Provider _openUrl$Provider;

  final _i5.AppModule _module;

  late final _i20.AppWindowCoordinator _singleton = _create();

  _i20.AppWindowCoordinator _create() => _module.coordinator(
    _appWindows$Provider.get(),
    _projectSession$Provider.get(),
    _zanshinAppFactory$Provider.get(),
    _zanshinWindowRootFactory$Provider.get(),
    _projectsWindowFactory$Provider.get(),
    _revsetConfigsWindowFactory$Provider.get(),
    _settingsWindowFactory$Provider.get(),
    _openUrl$Provider.get(),
  );

  @override
  _i20.AppWindowCoordinator get() => _singleton;
}

class _AppWindows$Provider implements _i22.Provider<_i8.AppWindows> {
  _AppWindows$Provider(this._module);

  final _i3.BootModule _module;

  late final _i8.AppWindows _singleton = _create();

  _i8.AppWindows _create() => _module.appWindows();

  @override
  _i8.AppWindows get() => _singleton;
}

class _FloatingShellViewModel$Provider
    implements _i22.Provider<_i26.FloatingShellViewModel> {
  const _FloatingShellViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i26.FloatingShellViewModel get() =>
      _i26.FloatingShellViewModel(_settingsStore$Provider.get());
}

class _GetDiagnostics$Provider implements _i22.Provider<_i2.GetDiagnostics> {
  _GetDiagnostics$Provider(this._module);

  final _i2.ZanshinDiagnosticsModule _module;

  late final _i2.GetDiagnostics _singleton = _create();

  _i2.GetDiagnostics _create() => _module.zanshinDiagnostics();

  @override
  _i2.GetDiagnostics get() => _singleton;
}

class _HomePageFactory$Factory implements _i14.HomePageFactory {
  const _HomePageFactory$Factory(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
    this._projectsEnvironment$Provider,
    this._settingsStore$Provider,
    this._activeGraph$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  @override
  _i14.HomePage create({_i27.Key? key}) => _i14.HomePage(
    viewModelFactory: _viewModelFactoryOfFloatingShellViewModel$Provider.get(),
    projects: _projectSession$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    settings: _settingsStore$Provider.get(),
    activeGraph: _activeGraph$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i22.Provider<_i14.HomePageFactory> {
  _HomePageFactory$Provider(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
    this._projectsEnvironment$Provider,
    this._settingsStore$Provider,
    this._activeGraph$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  late final _i14.HomePageFactory _factory = _HomePageFactory$Factory(
    _viewModelFactoryOfFloatingShellViewModel$Provider,
    _projectSession$Provider,
    _projectsEnvironment$Provider,
    _settingsStore$Provider,
    _activeGraph$Provider,
  );

  @override
  _i14.HomePageFactory get() => _factory;
}

class _IconRegistry$Provider implements _i22.Provider<_i28.IconRegistry> {
  _IconRegistry$Provider(this._module);

  final _i3.BootModule _module;

  late final _i28.IconRegistry _singleton = _create();

  _i28.IconRegistry _create() => _module.icons();

  @override
  _i28.IconRegistry get() => _singleton;
}

class _OpenUrl$Provider implements _i22.Provider<_i29.OpenUrl> {
  const _OpenUrl$Provider(this._module);

  final _i5.AppModule _module;

  @override
  _i29.OpenUrl get() => _module.openUrl();
}

class _ProjectRegistry$Provider implements _i22.Provider<_i10.ProjectRegistry> {
  _ProjectRegistry$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i10.ProjectRegistry _singleton = _create();

  _i10.ProjectRegistry _create() =>
      _i10.ProjectRegistry(_settingsStore$Provider.get());

  @override
  _i10.ProjectRegistry get() => _singleton;
}

class _ProjectRepos$Provider implements _i22.Provider<_i30.ProjectRepos> {
  _ProjectRepos$Provider(this._module);

  final _i1.TestModule _module;

  late final _i30.ProjectRepos _singleton = _create();

  _i30.ProjectRepos _create() => _module.projectRepos();

  @override
  _i30.ProjectRepos get() => _singleton;
}

class _ProjectSession$Provider implements _i22.Provider<_i11.ProjectSession> {
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
    implements _i22.Provider<_i13.ProjectsEnvironment> {
  _ProjectsEnvironment$Provider(this._module);

  final _i1.TestModule _module;

  late final _i13.ProjectsEnvironment _singleton = _create();

  _i13.ProjectsEnvironment _create() => _module.projectsEnvironment();

  @override
  _i13.ProjectsEnvironment get() => _singleton;
}

class _ProjectsSearchFocus$Provider
    implements _i22.Provider<_i12.ProjectsSearchFocus> {
  _ProjectsSearchFocus$Provider();

  late final _i12.ProjectsSearchFocus _singleton = _create();

  _i12.ProjectsSearchFocus _create() => _i12.ProjectsSearchFocus();

  @override
  _i12.ProjectsSearchFocus get() => _singleton;
}

class _ProjectsWindowFactory$Factory implements _i17.ProjectsWindowFactory {
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
  _i17.ProjectsWindow create({
    _i31.ValueChanged<_i11.ProjectOpened>? onOpened,
    _i27.Key? key,
  }) => _i17.ProjectsWindow(
    session: _projectSession$Provider.get(),
    registry: _projectRegistry$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    searchFocus: _projectsSearchFocus$Provider.get(),
    onOpened: onOpened,
    key: key,
  );
}

class _ProjectsWindowFactory$Provider
    implements _i22.Provider<_i17.ProjectsWindowFactory> {
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

  late final _i17.ProjectsWindowFactory _factory =
      _ProjectsWindowFactory$Factory(
        _projectSession$Provider,
        _projectRegistry$Provider,
        _projectsEnvironment$Provider,
        _projectsSearchFocus$Provider,
      );

  @override
  _i17.ProjectsWindowFactory get() => _factory;
}

class _RevsetConfigsWindowFactory$Factory
    implements _i18.RevsetConfigsWindowFactory {
  const _RevsetConfigsWindowFactory$Factory(
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._appWindows$Provider,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  @override
  _i18.RevsetConfigsWindow create({
    required _i29.OpenUrl openUrl,
    String? windowKey,
    _i27.Key? key,
  }) => _i18.RevsetConfigsWindow(
    settings: _settingsStore$Provider.get(),
    graph: _activeGraph$Provider.get(),
    windows: _appWindows$Provider.get(),
    openUrl: openUrl,
    windowKey: windowKey,
    key: key,
  );
}

class _RevsetConfigsWindowFactory$Provider
    implements _i22.Provider<_i18.RevsetConfigsWindowFactory> {
  _RevsetConfigsWindowFactory$Provider(
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._appWindows$Provider,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  late final _i18.RevsetConfigsWindowFactory _factory =
      _RevsetConfigsWindowFactory$Factory(
        _settingsStore$Provider,
        _activeGraph$Provider,
        _appWindows$Provider,
      );

  @override
  _i18.RevsetConfigsWindowFactory get() => _factory;
}

class _SettingsStore$Provider implements _i22.Provider<_i9.SettingsStore> {
  _SettingsStore$Provider(this._module);

  final _i3.BootModule _module;

  late final _i9.SettingsStore _singleton = _create();

  _i9.SettingsStore _create() => _module.settings();

  @override
  _i9.SettingsStore get() => _singleton;
}

class _SettingsWindowFactory$Factory implements _i19.SettingsWindowFactory {
  const _SettingsWindowFactory$Factory(
    this._appWindows$Provider,
    this._settingsStore$Provider,
    this._projectsEnvironment$Provider,
    this._projectSession$Provider,
    this._activeGraph$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  @override
  _i19.SettingsWindow create({
    required _i32.SettingsWindowState state,
    String? windowKey,
    _i33.SettingsReadsOf? readsOf,
    _i27.Key? key,
  }) => _i19.SettingsWindow(
    windows: _appWindows$Provider.get(),
    store: _settingsStore$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    session: _projectSession$Provider.get(),
    graph: _activeGraph$Provider.get(),
    state: state,
    windowKey: windowKey,
    readsOf: readsOf,
    key: key,
  );
}

class _SettingsWindowFactory$Provider
    implements _i22.Provider<_i19.SettingsWindowFactory> {
  _SettingsWindowFactory$Provider(
    this._appWindows$Provider,
    this._settingsStore$Provider,
    this._projectsEnvironment$Provider,
    this._projectSession$Provider,
    this._activeGraph$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  late final _i19.SettingsWindowFactory _factory =
      _SettingsWindowFactory$Factory(
        _appWindows$Provider,
        _settingsStore$Provider,
        _projectsEnvironment$Provider,
        _projectSession$Provider,
        _activeGraph$Provider,
      );

  @override
  _i19.SettingsWindowFactory get() => _factory;
}

class _ViewModelFactoryOfFloatingShellViewModel$Provider
    implements
        _i22.Provider<_i34.ViewModelFactory<_i26.FloatingShellViewModel>> {
  const _ViewModelFactoryOfFloatingShellViewModel$Provider(
    this._floatingShellViewModel$Provider,
  );

  final _FloatingShellViewModel$Provider _floatingShellViewModel$Provider;

  @override
  _i34.ViewModelFactory<_i26.FloatingShellViewModel> get() =>
      ({
        required _i34.ViewModelWidgetBuilder<_i26.FloatingShellViewModel>
        builder,
        _i35.Widget? child,
        _i34.ViewModelErrorBuilder? error,
        _i34.ViewModelInitializer<_i26.FloatingShellViewModel>? init,
        _i27.Key? key,
        _i35.Widget? loading,
      }) => _i34.ViewModelBuilder<_i26.FloatingShellViewModel>(
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
    implements _i22.Provider<_i34.ViewModelFactory<_i36.ZanshinAppViewModel>> {
  const _ViewModelFactoryOfZanshinAppViewModel$Provider(
    this._zanshinAppViewModel$Provider,
  );

  final _ZanshinAppViewModel$Provider _zanshinAppViewModel$Provider;

  @override
  _i34.ViewModelFactory<_i36.ZanshinAppViewModel> get() =>
      ({
        required _i34.ViewModelWidgetBuilder<_i36.ZanshinAppViewModel> builder,
        _i35.Widget? child,
        _i34.ViewModelErrorBuilder? error,
        _i34.ViewModelInitializer<_i36.ZanshinAppViewModel>? init,
        _i27.Key? key,
        _i35.Widget? loading,
      }) => _i34.ViewModelBuilder<_i36.ZanshinAppViewModel>(
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
    implements _i22.Provider<_i37.WindowAppearanceSync> {
  _WindowAppearanceSync$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i37.WindowAppearanceSync _singleton = _create();

  _i37.WindowAppearanceSync _create() =>
      _i37.WindowAppearanceSync(_settingsStore$Provider.get());

  @override
  _i37.WindowAppearanceSync get() => _singleton;
}

class _ZanshinAppFactory$Factory implements _i16.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  @override
  _i16.ZanshinApp create({_i27.Key? key}) => _i16.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    rootFactory: _zanshinWindowRootFactory$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i22.Provider<_i16.ZanshinAppFactory> {
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
    implements _i22.Provider<_i36.ZanshinAppViewModel> {
  const _ZanshinAppViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i36.ZanshinAppViewModel get() =>
      _i36.ZanshinAppViewModel(_settingsStore$Provider.get());
}

class _ZanshinApplication$Provider
    implements _i22.Provider<_i21.ZanshinApplication> {
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

  late final _i21.ZanshinApplication _singleton = _create();

  _i21.ZanshinApplication _create() => _i21.ZanshinApplication(
    _appWindowCoordinator$Provider.get(),
    _appMenuModel$Provider.get(),
    _settingsStore$Provider.get(),
    _appWindows$Provider.get(),
    _appExitHandler$Provider.get(),
    _windowAppearanceSync$Provider.get(),
  );

  @override
  _i21.ZanshinApplication get() => _singleton;
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
    required _i35.Widget child,
    bool? sizeToContent,
    _i27.Key? key,
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
    implements _i22.Provider<_i15.ZanshinWindowRootFactory> {
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

class _ZanshinWorker$Provider implements _i22.Provider<_i38.ZanshinWorker> {
  _ZanshinWorker$Provider(this._module);

  final _i3.BootModule _module;

  late final _i38.ZanshinWorker _singleton = _create();

  _i38.ZanshinWorker _create() => _module.worker();

  @override
  _i38.ZanshinWorker get() => _singleton;
}
