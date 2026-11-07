// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'package:flutter/src/foundation/basic_types.dart' as _i26;
import 'package:flutter/src/foundation/key.dart' as _i17;
import 'package:flutter/src/widgets/framework.dart' as _i33;
import 'package:inject_annotation/inject_annotation.dart' as _i7;
import 'package:inject_flutter/src/view_model_factory.dart' as _i32;
import 'package:zanshin_core/src/ffi/diagnostics.dart' as _i2;
import 'package:zanshin_core/src/worker/isolate.dart' as _i38;
import 'package:zanshin_settings/src/settings_store.dart' as _i28;
import 'package:zanshin_ui/src/icons/icon_registry.dart' as _i18;

import 'main.dart' as _i1;
import 'src/app/app_exit_handler.dart' as _i10;
import 'src/app/app_module.dart' as _i5;
import 'src/app/app_window_coordinator.dart' as _i13;
import 'src/app/boot/boot_module.dart' as _i3;
import 'src/app/menu/app_menu.dart' as _i11;
import 'src/app/zanshin_app.dart' as _i36;
import 'src/app/zanshin_application.dart' as _i6;
import 'src/features/graph/active_graph.dart' as _i8;
import 'src/features/graph/revset_configs/revset_configs_window.dart' as _i27;
import 'src/features/home/home_page.dart' as _i16;
import 'src/features/projects/project_registry.dart' as _i20;
import 'src/features/projects/project_repos.dart' as _i21;
import 'src/features/projects/project_session.dart' as _i22;
import 'src/features/projects/projects_environment.dart' as _i23;
import 'src/features/projects/projects_module.dart' as _i4;
import 'src/features/projects/projects_search_focus.dart' as _i24;
import 'src/features/projects/projects_window.dart' as _i25;
import 'src/features/settings/settings_view_model.dart' as _i31;
import 'src/features/settings/settings_window.dart' as _i29;
import 'src/features/settings/settings_window_state.dart' as _i30;
import 'src/features/shell/floating_shell_view_model.dart' as _i15;
import 'src/features/window/active_window_tracker.dart' as _i9;
import 'src/features/window/app_window_actions.dart' as _i12;
import 'src/features/window/app_windows.dart' as _i14;
import 'src/features/window/window_appearance_sync.dart' as _i35;
import 'src/features/window/zanshin_app_view_model.dart' as _i34;
import 'src/features/window/zanshin_window_root.dart' as _i37;
import 'src/links.dart' as _i19;

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
    final settingsStore$Provider = _SettingsStore$Provider(bootModule);
    final projectRegistry$Provider = _ProjectRegistry$Provider(
      settingsStore$Provider,
    );
    final projectRepos$Provider = _ProjectRepos$Provider(
      zanshinWorker$Provider,
      projectsModule,
    );
    final projectSession$Provider = _ProjectSession$Provider(
      projectRegistry$Provider,
      projectRepos$Provider,
      appWindows$Provider,
      projectsModule,
    );
    final projectsSearchFocus$Provider = _ProjectsSearchFocus$Provider();
    final floatingShellViewModel$Provider = _FloatingShellViewModel$Provider(
      settingsStore$Provider,
    );
    final viewModelFactoryOfFloatingShellViewModel$Provider =
        _ViewModelFactoryOfFloatingShellViewModel$Provider(
          floatingShellViewModel$Provider,
        );
    final getDiagnostics$Provider = _GetDiagnostics$Provider(
      zanshinDiagnosticsModule,
    );
    final projectsEnvironment$Provider = _ProjectsEnvironment$Provider(
      zanshinWorker$Provider,
      getDiagnostics$Provider,
      projectsModule,
    );
    final homePageFactory$Provider = _HomePageFactory$Provider(
      viewModelFactoryOfFloatingShellViewModel$Provider,
      projectSession$Provider,
      projectsEnvironment$Provider,
      settingsStore$Provider,
      activeGraph$Provider,
    );
    final zanshinAppViewModel$Provider = _ZanshinAppViewModel$Provider(
      settingsStore$Provider,
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
    final projectsWindowFactory$Provider = _ProjectsWindowFactory$Provider(
      projectSession$Provider,
      projectRegistry$Provider,
      projectsEnvironment$Provider,
      projectsSearchFocus$Provider,
    );
    final revsetConfigsWindowFactory$Provider =
        _RevsetConfigsWindowFactory$Provider(
          settingsStore$Provider,
          activeGraph$Provider,
          appWindows$Provider,
        );
    final settingsWindowFactory$Provider = _SettingsWindowFactory$Provider(
      appWindows$Provider,
      settingsStore$Provider,
      projectsEnvironment$Provider,
      projectSession$Provider,
      activeGraph$Provider,
    );
    final openUrl$Provider = _OpenUrl$Provider(appModule);
    final appWindowCoordinator$Provider = _AppWindowCoordinator$Provider(
      appWindows$Provider,
      projectSession$Provider,
      zanshinAppFactory$Provider,
      zanshinWindowRootFactory$Provider,
      projectsWindowFactory$Provider,
      revsetConfigsWindowFactory$Provider,
      settingsWindowFactory$Provider,
      openUrl$Provider,
      appModule,
    );
    final appWindowActions$Provider = _AppWindowActions$Provider(
      appWindowCoordinator$Provider,
      appModule,
    );
    final appMenuModel$Provider = _AppMenuModel$Provider(
      activeWindowTracker$Provider,
      projectSession$Provider,
      settingsStore$Provider,
      activeGraph$Provider,
      projectsSearchFocus$Provider,
      appWindows$Provider,
      appWindowActions$Provider,
      openUrl$Provider,
    );
    final windowAppearanceSync$Provider = _WindowAppearanceSync$Provider(
      settingsStore$Provider,
    );
    _zanshinApplication$Provider = _ZanshinApplication$Provider(
      appWindowCoordinator$Provider,
      appMenuModel$Provider,
      settingsStore$Provider,
      appWindows$Provider,
      appExitHandler$Provider,
      windowAppearanceSync$Provider,
    );
  }

  late final _ZanshinApplication$Provider _zanshinApplication$Provider;

  @override
  _i6.ZanshinApplication get application => _zanshinApplication$Provider.get();
}

class _ActiveGraph$Provider implements _i7.Provider<_i8.ActiveGraph> {
  _ActiveGraph$Provider();

  late final _i8.ActiveGraph _singleton = _create();

  _i8.ActiveGraph _create() => _i8.ActiveGraph();

  @override
  _i8.ActiveGraph get() => _singleton;
}

class _ActiveWindowTracker$Provider
    implements _i7.Provider<_i9.ActiveWindowTracker> {
  _ActiveWindowTracker$Provider();

  late final _i9.ActiveWindowTracker _singleton = _create();

  _i9.ActiveWindowTracker _create() => _i9.ActiveWindowTracker();

  @override
  _i9.ActiveWindowTracker get() => _singleton;
}

class _AppExitHandler$Provider implements _i7.Provider<_i10.AppExitHandler> {
  _AppExitHandler$Provider(
    this._appWindows$Provider,
    this._zanshinWorker$Provider,
  );

  final _AppWindows$Provider _appWindows$Provider;

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  late final _i10.AppExitHandler _singleton = _create();

  _i10.AppExitHandler _create() => _i10.AppExitHandler(
    _appWindows$Provider.get(),
    _zanshinWorker$Provider.get(),
  );

  @override
  _i10.AppExitHandler get() => _singleton;
}

class _AppMenuModel$Provider implements _i7.Provider<_i11.AppMenuModel> {
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

  late final _i11.AppMenuModel _singleton = _create();

  _i11.AppMenuModel _create() => _i11.AppMenuModel(
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
  _i11.AppMenuModel get() => _singleton;
}

class _AppWindowActions$Provider
    implements _i7.Provider<_i12.AppWindowActions> {
  const _AppWindowActions$Provider(
    this._appWindowCoordinator$Provider,
    this._module,
  );

  final _AppWindowCoordinator$Provider _appWindowCoordinator$Provider;

  final _i5.AppModule _module;

  @override
  _i12.AppWindowActions get() =>
      _module.windowActions(_appWindowCoordinator$Provider.get());
}

class _AppWindowCoordinator$Provider
    implements _i7.Provider<_i13.AppWindowCoordinator> {
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

  late final _i13.AppWindowCoordinator _singleton = _create();

  _i13.AppWindowCoordinator _create() => _module.coordinator(
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
  _i13.AppWindowCoordinator get() => _singleton;
}

class _AppWindows$Provider implements _i7.Provider<_i14.AppWindows> {
  _AppWindows$Provider(this._module);

  final _i3.BootModule _module;

  late final _i14.AppWindows _singleton = _create();

  _i14.AppWindows _create() => _module.appWindows();

  @override
  _i14.AppWindows get() => _singleton;
}

class _FloatingShellViewModel$Provider
    implements _i7.Provider<_i15.FloatingShellViewModel> {
  const _FloatingShellViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i15.FloatingShellViewModel get() =>
      _i15.FloatingShellViewModel(_settingsStore$Provider.get());
}

class _GetDiagnostics$Provider implements _i7.Provider<_i2.GetDiagnostics> {
  _GetDiagnostics$Provider(this._module);

  final _i2.ZanshinDiagnosticsModule _module;

  late final _i2.GetDiagnostics _singleton = _create();

  _i2.GetDiagnostics _create() => _module.zanshinDiagnostics();

  @override
  _i2.GetDiagnostics get() => _singleton;
}

class _HomePageFactory$Factory implements _i16.HomePageFactory {
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
  _i16.HomePage create({_i17.Key? key}) => _i16.HomePage(
    viewModelFactory: _viewModelFactoryOfFloatingShellViewModel$Provider.get(),
    projects: _projectSession$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    settings: _settingsStore$Provider.get(),
    activeGraph: _activeGraph$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i7.Provider<_i16.HomePageFactory> {
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

  late final _i16.HomePageFactory _factory = _HomePageFactory$Factory(
    _viewModelFactoryOfFloatingShellViewModel$Provider,
    _projectSession$Provider,
    _projectsEnvironment$Provider,
    _settingsStore$Provider,
    _activeGraph$Provider,
  );

  @override
  _i16.HomePageFactory get() => _factory;
}

class _IconRegistry$Provider implements _i7.Provider<_i18.IconRegistry> {
  _IconRegistry$Provider(this._module);

  final _i3.BootModule _module;

  late final _i18.IconRegistry _singleton = _create();

  _i18.IconRegistry _create() => _module.icons();

  @override
  _i18.IconRegistry get() => _singleton;
}

class _OpenUrl$Provider implements _i7.Provider<_i19.OpenUrl> {
  const _OpenUrl$Provider(this._module);

  final _i5.AppModule _module;

  @override
  _i19.OpenUrl get() => _module.openUrl();
}

class _ProjectRegistry$Provider implements _i7.Provider<_i20.ProjectRegistry> {
  _ProjectRegistry$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i20.ProjectRegistry _singleton = _create();

  _i20.ProjectRegistry _create() =>
      _i20.ProjectRegistry(_settingsStore$Provider.get());

  @override
  _i20.ProjectRegistry get() => _singleton;
}

class _ProjectRepos$Provider implements _i7.Provider<_i21.ProjectRepos> {
  _ProjectRepos$Provider(this._zanshinWorker$Provider, this._module);

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  final _i4.ProjectsModule _module;

  late final _i21.ProjectRepos _singleton = _create();

  _i21.ProjectRepos _create() =>
      _module.projectRepos(_zanshinWorker$Provider.get());

  @override
  _i21.ProjectRepos get() => _singleton;
}

class _ProjectSession$Provider implements _i7.Provider<_i22.ProjectSession> {
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

  late final _i22.ProjectSession _singleton = _create();

  _i22.ProjectSession _create() => _module.projectSession(
    _projectRegistry$Provider.get(),
    _projectRepos$Provider.get(),
    _appWindows$Provider.get(),
  );

  @override
  _i22.ProjectSession get() => _singleton;
}

class _ProjectsEnvironment$Provider
    implements _i7.Provider<_i23.ProjectsEnvironment> {
  _ProjectsEnvironment$Provider(
    this._zanshinWorker$Provider,
    this._getDiagnostics$Provider,
    this._module,
  );

  final _ZanshinWorker$Provider _zanshinWorker$Provider;

  final _GetDiagnostics$Provider _getDiagnostics$Provider;

  final _i4.ProjectsModule _module;

  late final _i23.ProjectsEnvironment _singleton = _create();

  _i23.ProjectsEnvironment _create() => _module.projectsEnvironment(
    _zanshinWorker$Provider.get(),
    _getDiagnostics$Provider.get(),
  );

  @override
  _i23.ProjectsEnvironment get() => _singleton;
}

class _ProjectsSearchFocus$Provider
    implements _i7.Provider<_i24.ProjectsSearchFocus> {
  _ProjectsSearchFocus$Provider();

  late final _i24.ProjectsSearchFocus _singleton = _create();

  _i24.ProjectsSearchFocus _create() => _i24.ProjectsSearchFocus();

  @override
  _i24.ProjectsSearchFocus get() => _singleton;
}

class _ProjectsWindowFactory$Factory implements _i25.ProjectsWindowFactory {
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
  _i25.ProjectsWindow create({
    _i26.ValueChanged<_i22.ProjectOpened>? onOpened,
    _i17.Key? key,
  }) => _i25.ProjectsWindow(
    session: _projectSession$Provider.get(),
    registry: _projectRegistry$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    searchFocus: _projectsSearchFocus$Provider.get(),
    onOpened: onOpened,
    key: key,
  );
}

class _ProjectsWindowFactory$Provider
    implements _i7.Provider<_i25.ProjectsWindowFactory> {
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

  late final _i25.ProjectsWindowFactory _factory =
      _ProjectsWindowFactory$Factory(
        _projectSession$Provider,
        _projectRegistry$Provider,
        _projectsEnvironment$Provider,
        _projectsSearchFocus$Provider,
      );

  @override
  _i25.ProjectsWindowFactory get() => _factory;
}

class _RevsetConfigsWindowFactory$Factory
    implements _i27.RevsetConfigsWindowFactory {
  const _RevsetConfigsWindowFactory$Factory(
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._appWindows$Provider,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  @override
  _i27.RevsetConfigsWindow create({
    required _i19.OpenUrl openUrl,
    String? windowKey,
    _i17.Key? key,
  }) => _i27.RevsetConfigsWindow(
    settings: _settingsStore$Provider.get(),
    graph: _activeGraph$Provider.get(),
    windows: _appWindows$Provider.get(),
    openUrl: openUrl,
    windowKey: windowKey,
    key: key,
  );
}

class _RevsetConfigsWindowFactory$Provider
    implements _i7.Provider<_i27.RevsetConfigsWindowFactory> {
  _RevsetConfigsWindowFactory$Provider(
    this._settingsStore$Provider,
    this._activeGraph$Provider,
    this._appWindows$Provider,
  );

  final _SettingsStore$Provider _settingsStore$Provider;

  final _ActiveGraph$Provider _activeGraph$Provider;

  final _AppWindows$Provider _appWindows$Provider;

  late final _i27.RevsetConfigsWindowFactory _factory =
      _RevsetConfigsWindowFactory$Factory(
        _settingsStore$Provider,
        _activeGraph$Provider,
        _appWindows$Provider,
      );

  @override
  _i27.RevsetConfigsWindowFactory get() => _factory;
}

class _SettingsStore$Provider implements _i7.Provider<_i28.SettingsStore> {
  _SettingsStore$Provider(this._module);

  final _i3.BootModule _module;

  late final _i28.SettingsStore _singleton = _create();

  _i28.SettingsStore _create() => _module.settings();

  @override
  _i28.SettingsStore get() => _singleton;
}

class _SettingsWindowFactory$Factory implements _i29.SettingsWindowFactory {
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
  _i29.SettingsWindow create({
    required _i30.SettingsWindowState state,
    String? windowKey,
    _i31.SettingsReadsOf? readsOf,
    _i17.Key? key,
  }) => _i29.SettingsWindow(
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
    implements _i7.Provider<_i29.SettingsWindowFactory> {
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

  late final _i29.SettingsWindowFactory _factory =
      _SettingsWindowFactory$Factory(
        _appWindows$Provider,
        _settingsStore$Provider,
        _projectsEnvironment$Provider,
        _projectSession$Provider,
        _activeGraph$Provider,
      );

  @override
  _i29.SettingsWindowFactory get() => _factory;
}

class _ViewModelFactoryOfFloatingShellViewModel$Provider
    implements
        _i7.Provider<_i32.ViewModelFactory<_i15.FloatingShellViewModel>> {
  const _ViewModelFactoryOfFloatingShellViewModel$Provider(
    this._floatingShellViewModel$Provider,
  );

  final _FloatingShellViewModel$Provider _floatingShellViewModel$Provider;

  @override
  _i32.ViewModelFactory<_i15.FloatingShellViewModel> get() =>
      ({
        required _i32.ViewModelWidgetBuilder<_i15.FloatingShellViewModel>
        builder,
        _i33.Widget? child,
        _i32.ViewModelErrorBuilder? error,
        _i32.ViewModelInitializer<_i15.FloatingShellViewModel>? init,
        _i17.Key? key,
        _i33.Widget? loading,
      }) => _i32.ViewModelBuilder<_i15.FloatingShellViewModel>(
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
    implements _i7.Provider<_i32.ViewModelFactory<_i34.ZanshinAppViewModel>> {
  const _ViewModelFactoryOfZanshinAppViewModel$Provider(
    this._zanshinAppViewModel$Provider,
  );

  final _ZanshinAppViewModel$Provider _zanshinAppViewModel$Provider;

  @override
  _i32.ViewModelFactory<_i34.ZanshinAppViewModel> get() =>
      ({
        required _i32.ViewModelWidgetBuilder<_i34.ZanshinAppViewModel> builder,
        _i33.Widget? child,
        _i32.ViewModelErrorBuilder? error,
        _i32.ViewModelInitializer<_i34.ZanshinAppViewModel>? init,
        _i17.Key? key,
        _i33.Widget? loading,
      }) => _i32.ViewModelBuilder<_i34.ZanshinAppViewModel>(
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
    implements _i7.Provider<_i35.WindowAppearanceSync> {
  _WindowAppearanceSync$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  late final _i35.WindowAppearanceSync _singleton = _create();

  _i35.WindowAppearanceSync _create() =>
      _i35.WindowAppearanceSync(_settingsStore$Provider.get());

  @override
  _i35.WindowAppearanceSync get() => _singleton;
}

class _ZanshinAppFactory$Factory implements _i36.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  @override
  _i36.ZanshinApp create({_i17.Key? key}) => _i36.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    rootFactory: _zanshinWindowRootFactory$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i7.Provider<_i36.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(
    this._homePageFactory$Provider,
    this._zanshinWindowRootFactory$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ZanshinWindowRootFactory$Provider _zanshinWindowRootFactory$Provider;

  late final _i36.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
    _zanshinWindowRootFactory$Provider,
  );

  @override
  _i36.ZanshinAppFactory get() => _factory;
}

class _ZanshinAppViewModel$Provider
    implements _i7.Provider<_i34.ZanshinAppViewModel> {
  const _ZanshinAppViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i34.ZanshinAppViewModel get() =>
      _i34.ZanshinAppViewModel(_settingsStore$Provider.get());
}

class _ZanshinApplication$Provider
    implements _i7.Provider<_i6.ZanshinApplication> {
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
    implements _i37.ZanshinWindowRootFactory {
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
  _i37.ZanshinWindowRoot create({
    required String windowKey,
    required _i33.Widget child,
    bool? sizeToContent,
    _i17.Key? key,
  }) => _i37.ZanshinWindowRoot(
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
    implements _i7.Provider<_i37.ZanshinWindowRootFactory> {
  _ZanshinWindowRootFactory$Provider(
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
    this._activeWindowTracker$Provider,
    this._iconRegistry$Provider,
  );

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  final _ActiveWindowTracker$Provider _activeWindowTracker$Provider;

  final _IconRegistry$Provider _iconRegistry$Provider;

  late final _i37.ZanshinWindowRootFactory _factory =
      _ZanshinWindowRootFactory$Factory(
        _viewModelFactoryOfZanshinAppViewModel$Provider,
        _activeWindowTracker$Provider,
        _iconRegistry$Provider,
      );

  @override
  _i37.ZanshinWindowRootFactory get() => _factory;
}

class _ZanshinWorker$Provider implements _i7.Provider<_i38.ZanshinWorker> {
  _ZanshinWorker$Provider(this._module);

  final _i3.BootModule _module;

  late final _i38.ZanshinWorker _singleton = _create();

  _i38.ZanshinWorker _create() => _module.worker();

  @override
  _i38.ZanshinWorker get() => _singleton;
}
