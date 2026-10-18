// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'dart:async' as _i11;
import 'dart:ui' as _i21;

import 'package:flutter/src/foundation/basic_types.dart' as _i20;
import 'package:flutter/src/foundation/key.dart' as _i16;
import 'package:flutter/src/widgets/framework.dart' as _i25;
import 'package:inject_annotation/inject_annotation.dart' as _i13;
import 'package:inject_annotation/src/api/provision_listener.dart' as _i22;
import 'package:inject_flutter/src/view_model_factory.dart' as _i24;
import 'package:zanshin_core/src/ffi/diagnostics.dart' as _i2;
import 'package:zanshin_core/src/worker/isolate.dart' as _i12;
import 'package:zanshin_core/src/worker/worker_module.dart' as _i3;
import 'package:zanshin_settings/src/settings_module.dart' as _i5;
import 'package:zanshin_settings/src/settings_store.dart' as _i23;
import 'package:zanshin_ui/src/icons/icon_registry.dart' as _i17;

import 'main.dart' as _i1;
import 'src/app/worker_lifecycle_module.dart' as _i4;
import 'src/features/app/zanshin_app.dart' as _i10;
import 'src/features/app/zanshin_app_view_model.dart' as _i26;
import 'src/features/bootstrap/icon_module.dart' as _i6;
import 'src/features/home/home_page.dart' as _i15;
import 'src/features/projects/project_registry.dart' as _i18;
import 'src/features/projects/project_session.dart' as _i8;
import 'src/features/projects/projects_environment.dart' as _i19;
import 'src/features/projects/projects_module.dart' as _i7;
import 'src/features/projects/projects_window.dart' as _i9;
import 'src/features/shell/floating_shell_view_model.dart' as _i14;

class MainComponent$Component implements _i1.MainComponent {
  factory MainComponent$Component.create({
    _i2.ZanshinDiagnosticsModule? zanshinDiagnosticsModule,
    _i3.WorkerModule? workerModule,
    _i4.WorkerLifecycleModule? workerLifecycleModule,
    required _i5.SettingsModule settingsModule,
    required _i6.IconModule iconModule,
    required _i7.ProjectsModule projectsModule,
  }) => MainComponent$Component._(
    zanshinDiagnosticsModule ?? _i2.ZanshinDiagnosticsModule(),
    workerModule ?? _i3.WorkerModule(),
    workerLifecycleModule ?? _i4.WorkerLifecycleModule(),
    settingsModule,
    iconModule,
    projectsModule,
  );

  MainComponent$Component._(
    _i2.ZanshinDiagnosticsModule zanshinDiagnosticsModule,
    _i3.WorkerModule workerModule,
    _i4.WorkerLifecycleModule workerLifecycleModule,
    _i5.SettingsModule settingsModule,
    _i6.IconModule iconModule,
    _i7.ProjectsModule projectsModule,
  ) {
    final settingsStore$Provider = _SettingsStore$Provider(settingsModule);
    final floatingShellViewModel$Provider = _FloatingShellViewModel$Provider(
      settingsStore$Provider,
    );
    final getDiagnostics$Provider = _GetDiagnostics$Provider(
      zanshinDiagnosticsModule,
    );
    final viewModelFactoryOfFloatingShellViewModel$Provider =
        _ViewModelFactoryOfFloatingShellViewModel$Provider(
          floatingShellViewModel$Provider,
        );
    final projectRegistry$Provider = _ProjectRegistry$Provider(
      settingsStore$Provider,
      projectsModule,
    );
    _projectSession$Provider = _ProjectSession$Provider(
      projectRegistry$Provider,
      projectsModule,
    );
    final homePageFactory$Provider = _HomePageFactory$Provider(
      viewModelFactoryOfFloatingShellViewModel$Provider,
      _projectSession$Provider,
    );
    final iconRegistry$Provider = _IconRegistry$Provider(iconModule);
    final projectsEnvironment$Provider = _ProjectsEnvironment$Provider(
      getDiagnostics$Provider,
      projectsModule,
    );
    _projectsWindowFactory$Provider = _ProjectsWindowFactory$Provider(
      _projectSession$Provider,
      projectRegistry$Provider,
      projectsEnvironment$Provider,
    );
    final provisionListenerOfZanshinWorker$Provider =
        _ProvisionListenerOfZanshinWorker$Provider(workerLifecycleModule);
    final zanshinAppViewModel$Provider = _ZanshinAppViewModel$Provider(
      settingsStore$Provider,
    );
    final viewModelFactoryOfZanshinAppViewModel$Provider =
        _ViewModelFactoryOfZanshinAppViewModel$Provider(
          zanshinAppViewModel$Provider,
        );
    _zanshinAppFactory$Provider = _ZanshinAppFactory$Provider(
      homePageFactory$Provider,
      viewModelFactoryOfZanshinAppViewModel$Provider,
    );
    _zanshinWorker$Provider = _ZanshinWorker$Provider(
      provisionListenerOfZanshinWorker$Provider,
      workerModule,
    );
  }

  late final _ProjectSession$Provider _projectSession$Provider;

  late final _ProjectsWindowFactory$Provider _projectsWindowFactory$Provider;

  late final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  late final _ZanshinWorker$Provider _zanshinWorker$Provider;

  @override
  _i8.ProjectSession get projectSession => _projectSession$Provider.get();

  @override
  _i9.ProjectsWindowFactory get projectsWindowFactory =>
      _projectsWindowFactory$Provider.get();

  @override
  _i10.ZanshinAppFactory get zanshinAppFactory =>
      _zanshinAppFactory$Provider.get();

  @override
  _i11.Future<_i12.ZanshinWorker> get worker => _zanshinWorker$Provider.get();
}

class _FloatingShellViewModel$Provider
    implements _i13.Provider<_i14.FloatingShellViewModel> {
  const _FloatingShellViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i14.FloatingShellViewModel get() =>
      _i14.FloatingShellViewModel(_settingsStore$Provider.get());
}

class _GetDiagnostics$Provider implements _i13.Provider<_i2.GetDiagnostics> {
  _GetDiagnostics$Provider(this._module);

  final _i2.ZanshinDiagnosticsModule _module;

  late final _i2.GetDiagnostics _singleton = _create();

  _i2.GetDiagnostics _create() => _module.zanshinDiagnostics();

  @override
  _i2.GetDiagnostics get() => _singleton;
}

class _HomePageFactory$Factory implements _i15.HomePageFactory {
  const _HomePageFactory$Factory(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  @override
  _i15.HomePage create({_i16.Key? key}) => _i15.HomePage(
    viewModelFactory: _viewModelFactoryOfFloatingShellViewModel$Provider.get(),
    projects: _projectSession$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i13.Provider<_i15.HomePageFactory> {
  _HomePageFactory$Provider(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  late final _i15.HomePageFactory _factory = _HomePageFactory$Factory(
    _viewModelFactoryOfFloatingShellViewModel$Provider,
    _projectSession$Provider,
  );

  @override
  _i15.HomePageFactory get() => _factory;
}

class _IconRegistry$Provider implements _i13.Provider<_i17.IconRegistry> {
  _IconRegistry$Provider(this._module);

  final _i6.IconModule _module;

  late final _i17.IconRegistry _singleton = _create();

  _i17.IconRegistry _create() => _module.iconRegistry();

  @override
  _i17.IconRegistry get() => _singleton;
}

class _ProjectRegistry$Provider implements _i13.Provider<_i18.ProjectRegistry> {
  _ProjectRegistry$Provider(this._settingsStore$Provider, this._module);

  final _SettingsStore$Provider _settingsStore$Provider;

  final _i7.ProjectsModule _module;

  late final _i18.ProjectRegistry _singleton = _create();

  _i18.ProjectRegistry _create() =>
      _module.projectRegistry(_settingsStore$Provider.get());

  @override
  _i18.ProjectRegistry get() => _singleton;
}

class _ProjectSession$Provider implements _i13.Provider<_i8.ProjectSession> {
  _ProjectSession$Provider(this._projectRegistry$Provider, this._module);

  final _ProjectRegistry$Provider _projectRegistry$Provider;

  final _i7.ProjectsModule _module;

  late final _i8.ProjectSession _singleton = _create();

  _i8.ProjectSession _create() =>
      _module.projectSession(_projectRegistry$Provider.get());

  @override
  _i8.ProjectSession get() => _singleton;
}

class _ProjectsEnvironment$Provider
    implements _i13.Provider<_i19.ProjectsEnvironment> {
  _ProjectsEnvironment$Provider(this._getDiagnostics$Provider, this._module);

  final _GetDiagnostics$Provider _getDiagnostics$Provider;

  final _i7.ProjectsModule _module;

  late final _i19.ProjectsEnvironment _singleton = _create();

  _i19.ProjectsEnvironment _create() =>
      _module.projectsEnvironment(_getDiagnostics$Provider.get());

  @override
  _i19.ProjectsEnvironment get() => _singleton;
}

class _ProjectsWindowFactory$Factory implements _i9.ProjectsWindowFactory {
  const _ProjectsWindowFactory$Factory(
    this._projectSession$Provider,
    this._projectRegistry$Provider,
    this._projectsEnvironment$Provider,
  );

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectRegistry$Provider _projectRegistry$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  @override
  _i9.ProjectsWindow create({
    _i20.ValueChanged<_i8.ProjectOpened>? onOpened,
    _i21.VoidCallback? onSettings,
    _i21.VoidCallback? onIdentitySettings,
    _i16.Key? key,
  }) => _i9.ProjectsWindow(
    session: _projectSession$Provider.get(),
    registry: _projectRegistry$Provider.get(),
    environment: _projectsEnvironment$Provider.get(),
    onOpened: onOpened,
    onSettings: onSettings,
    onIdentitySettings: onIdentitySettings,
    key: key,
  );
}

class _ProjectsWindowFactory$Provider
    implements _i13.Provider<_i9.ProjectsWindowFactory> {
  _ProjectsWindowFactory$Provider(
    this._projectSession$Provider,
    this._projectRegistry$Provider,
    this._projectsEnvironment$Provider,
  );

  final _ProjectSession$Provider _projectSession$Provider;

  final _ProjectRegistry$Provider _projectRegistry$Provider;

  final _ProjectsEnvironment$Provider _projectsEnvironment$Provider;

  late final _i9.ProjectsWindowFactory _factory =
      _ProjectsWindowFactory$Factory(
        _projectSession$Provider,
        _projectRegistry$Provider,
        _projectsEnvironment$Provider,
      );

  @override
  _i9.ProjectsWindowFactory get() => _factory;
}

class _ProvisionListenerOfZanshinWorker$Provider
    implements _i13.Provider<_i22.ProvisionListener<_i12.ZanshinWorker>> {
  _ProvisionListenerOfZanshinWorker$Provider(this._module);

  final _i4.WorkerLifecycleModule _module;

  late final _i22.ProvisionListener<_i12.ZanshinWorker> _singleton = _create();

  _i22.ProvisionListener<_i12.ZanshinWorker> _create() =>
      _module.workerLifecycle();

  @override
  _i22.ProvisionListener<_i12.ZanshinWorker> get() => _singleton;
}

class _SettingsStore$Provider implements _i13.Provider<_i23.SettingsStore> {
  _SettingsStore$Provider(this._module);

  final _i5.SettingsModule _module;

  late final _i23.SettingsStore _singleton = _create();

  _i23.SettingsStore _create() => _module.settingsStore();

  @override
  _i23.SettingsStore get() => _singleton;
}

class _ViewModelFactoryOfFloatingShellViewModel$Provider
    implements
        _i13.Provider<_i24.ViewModelFactory<_i14.FloatingShellViewModel>> {
  const _ViewModelFactoryOfFloatingShellViewModel$Provider(
    this._floatingShellViewModel$Provider,
  );

  final _FloatingShellViewModel$Provider _floatingShellViewModel$Provider;

  @override
  _i24.ViewModelFactory<_i14.FloatingShellViewModel> get() =>
      ({
        required _i24.ViewModelWidgetBuilder<_i14.FloatingShellViewModel>
        builder,
        _i25.Widget? child,
        _i24.ViewModelErrorBuilder? error,
        _i24.ViewModelInitializer<_i14.FloatingShellViewModel>? init,
        _i16.Key? key,
        _i25.Widget? loading,
      }) => _i24.ViewModelBuilder<_i14.FloatingShellViewModel>(
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
    implements _i13.Provider<_i24.ViewModelFactory<_i26.ZanshinAppViewModel>> {
  const _ViewModelFactoryOfZanshinAppViewModel$Provider(
    this._zanshinAppViewModel$Provider,
  );

  final _ZanshinAppViewModel$Provider _zanshinAppViewModel$Provider;

  @override
  _i24.ViewModelFactory<_i26.ZanshinAppViewModel> get() =>
      ({
        required _i24.ViewModelWidgetBuilder<_i26.ZanshinAppViewModel> builder,
        _i25.Widget? child,
        _i24.ViewModelErrorBuilder? error,
        _i24.ViewModelInitializer<_i26.ZanshinAppViewModel>? init,
        _i16.Key? key,
        _i25.Widget? loading,
      }) => _i24.ViewModelBuilder<_i26.ZanshinAppViewModel>(
        key: key,
        viewModelProvider: _zanshinAppViewModel$Provider,
        init: init,
        loading: loading,
        error: error,
        builder: builder,
        child: child,
      );
}

class _ZanshinAppFactory$Factory implements _i10.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(
    this._homePageFactory$Provider,
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  @override
  _i10.ZanshinApp create({_i16.Key? key}) => _i10.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    viewModelFactory: _viewModelFactoryOfZanshinAppViewModel$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i13.Provider<_i10.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(
    this._homePageFactory$Provider,
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  late final _i10.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
    _viewModelFactoryOfZanshinAppViewModel$Provider,
  );

  @override
  _i10.ZanshinAppFactory get() => _factory;
}

class _ZanshinAppViewModel$Provider
    implements _i13.Provider<_i26.ZanshinAppViewModel> {
  const _ZanshinAppViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i26.ZanshinAppViewModel get() =>
      _i26.ZanshinAppViewModel(_settingsStore$Provider.get());
}

class _ZanshinWorker$Provider
    implements _i13.Provider<_i11.Future<_i12.ZanshinWorker>> {
  _ZanshinWorker$Provider(
    this._provisionListenerOfZanshinWorker$Provider,
    this._module,
  );

  final _ProvisionListenerOfZanshinWorker$Provider
  _provisionListenerOfZanshinWorker$Provider;

  final _i3.WorkerModule _module;

  _i11.Future<_i12.ZanshinWorker>? _singletonFuture;

  _i11.Future<_i12.ZanshinWorker> _create() async {
    final instance = await _module.worker();
    _provisionListenerOfZanshinWorker$Provider.get().onProvision(instance);
    return instance;
  }

  @override
  _i11.Future<_i12.ZanshinWorker> get() => _singletonFuture ??= _create();
}
