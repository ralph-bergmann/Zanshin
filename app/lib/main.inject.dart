// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes

import 'dart:async' as _i10;

import 'package:flutter/src/foundation/key.dart' as _i15;
import 'package:flutter/src/widgets/framework.dart' as _i20;
import 'package:inject_annotation/inject_annotation.dart' as _i12;
import 'package:inject_annotation/src/api/provision_listener.dart' as _i17;
import 'package:inject_flutter/src/view_model_factory.dart' as _i19;
import 'package:zanshin_core/src/ffi/diagnostics.dart' as _i2;
import 'package:zanshin_core/src/worker/isolate.dart' as _i11;
import 'package:zanshin_core/src/worker/worker_module.dart' as _i3;
import 'package:zanshin_settings/src/settings_module.dart' as _i5;
import 'package:zanshin_settings/src/settings_store.dart' as _i18;
import 'package:zanshin_ui/src/icons/icon_registry.dart' as _i16;

import 'main.dart' as _i1;
import 'src/app/worker_lifecycle_module.dart' as _i4;
import 'src/features/app/zanshin_app.dart' as _i9;
import 'src/features/app/zanshin_app_view_model.dart' as _i21;
import 'src/features/bootstrap/icon_module.dart' as _i6;
import 'src/features/home/home_page.dart' as _i14;
import 'src/features/projects/project_session.dart' as _i8;
import 'src/features/projects/projects_module.dart' as _i7;
import 'src/features/shell/floating_shell_view_model.dart' as _i13;

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
    _projectSession$Provider = _ProjectSession$Provider(
      settingsStore$Provider,
      projectsModule,
    );
    final homePageFactory$Provider = _HomePageFactory$Provider(
      viewModelFactoryOfFloatingShellViewModel$Provider,
      _projectSession$Provider,
    );
    final iconRegistry$Provider = _IconRegistry$Provider(iconModule);
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

  late final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  late final _ZanshinWorker$Provider _zanshinWorker$Provider;

  @override
  _i8.ProjectSession get projectSession => _projectSession$Provider.get();

  @override
  _i9.ZanshinAppFactory get zanshinAppFactory =>
      _zanshinAppFactory$Provider.get();

  @override
  _i10.Future<_i11.ZanshinWorker> get worker => _zanshinWorker$Provider.get();
}

class _FloatingShellViewModel$Provider
    implements _i12.Provider<_i13.FloatingShellViewModel> {
  const _FloatingShellViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i13.FloatingShellViewModel get() =>
      _i13.FloatingShellViewModel(_settingsStore$Provider.get());
}

class _GetDiagnostics$Provider implements _i12.Provider<_i2.GetDiagnostics> {
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
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  @override
  _i14.HomePage create({_i15.Key? key}) => _i14.HomePage(
    viewModelFactory: _viewModelFactoryOfFloatingShellViewModel$Provider.get(),
    projects: _projectSession$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i12.Provider<_i14.HomePageFactory> {
  _HomePageFactory$Provider(
    this._viewModelFactoryOfFloatingShellViewModel$Provider,
    this._projectSession$Provider,
  );

  final _ViewModelFactoryOfFloatingShellViewModel$Provider
  _viewModelFactoryOfFloatingShellViewModel$Provider;

  final _ProjectSession$Provider _projectSession$Provider;

  late final _i14.HomePageFactory _factory = _HomePageFactory$Factory(
    _viewModelFactoryOfFloatingShellViewModel$Provider,
    _projectSession$Provider,
  );

  @override
  _i14.HomePageFactory get() => _factory;
}

class _IconRegistry$Provider implements _i12.Provider<_i16.IconRegistry> {
  _IconRegistry$Provider(this._module);

  final _i6.IconModule _module;

  late final _i16.IconRegistry _singleton = _create();

  _i16.IconRegistry _create() => _module.iconRegistry();

  @override
  _i16.IconRegistry get() => _singleton;
}

class _ProjectSession$Provider implements _i12.Provider<_i8.ProjectSession> {
  _ProjectSession$Provider(this._settingsStore$Provider, this._module);

  final _SettingsStore$Provider _settingsStore$Provider;

  final _i7.ProjectsModule _module;

  late final _i8.ProjectSession _singleton = _create();

  _i8.ProjectSession _create() =>
      _module.projectSession(_settingsStore$Provider.get());

  @override
  _i8.ProjectSession get() => _singleton;
}

class _ProvisionListenerOfZanshinWorker$Provider
    implements _i12.Provider<_i17.ProvisionListener<_i11.ZanshinWorker>> {
  _ProvisionListenerOfZanshinWorker$Provider(this._module);

  final _i4.WorkerLifecycleModule _module;

  late final _i17.ProvisionListener<_i11.ZanshinWorker> _singleton = _create();

  _i17.ProvisionListener<_i11.ZanshinWorker> _create() =>
      _module.workerLifecycle();

  @override
  _i17.ProvisionListener<_i11.ZanshinWorker> get() => _singleton;
}

class _SettingsStore$Provider implements _i12.Provider<_i18.SettingsStore> {
  _SettingsStore$Provider(this._module);

  final _i5.SettingsModule _module;

  late final _i18.SettingsStore _singleton = _create();

  _i18.SettingsStore _create() => _module.settingsStore();

  @override
  _i18.SettingsStore get() => _singleton;
}

class _ViewModelFactoryOfFloatingShellViewModel$Provider
    implements
        _i12.Provider<_i19.ViewModelFactory<_i13.FloatingShellViewModel>> {
  const _ViewModelFactoryOfFloatingShellViewModel$Provider(
    this._floatingShellViewModel$Provider,
  );

  final _FloatingShellViewModel$Provider _floatingShellViewModel$Provider;

  @override
  _i19.ViewModelFactory<_i13.FloatingShellViewModel> get() =>
      ({
        required _i19.ViewModelWidgetBuilder<_i13.FloatingShellViewModel>
        builder,
        _i20.Widget? child,
        _i19.ViewModelErrorBuilder? error,
        _i19.ViewModelInitializer<_i13.FloatingShellViewModel>? init,
        _i15.Key? key,
        _i20.Widget? loading,
      }) => _i19.ViewModelBuilder<_i13.FloatingShellViewModel>(
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
    implements _i12.Provider<_i19.ViewModelFactory<_i21.ZanshinAppViewModel>> {
  const _ViewModelFactoryOfZanshinAppViewModel$Provider(
    this._zanshinAppViewModel$Provider,
  );

  final _ZanshinAppViewModel$Provider _zanshinAppViewModel$Provider;

  @override
  _i19.ViewModelFactory<_i21.ZanshinAppViewModel> get() =>
      ({
        required _i19.ViewModelWidgetBuilder<_i21.ZanshinAppViewModel> builder,
        _i20.Widget? child,
        _i19.ViewModelErrorBuilder? error,
        _i19.ViewModelInitializer<_i21.ZanshinAppViewModel>? init,
        _i15.Key? key,
        _i20.Widget? loading,
      }) => _i19.ViewModelBuilder<_i21.ZanshinAppViewModel>(
        key: key,
        viewModelProvider: _zanshinAppViewModel$Provider,
        init: init,
        loading: loading,
        error: error,
        builder: builder,
        child: child,
      );
}

class _ZanshinAppFactory$Factory implements _i9.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(
    this._homePageFactory$Provider,
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  @override
  _i9.ZanshinApp create({_i15.Key? key}) => _i9.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    viewModelFactory: _viewModelFactoryOfZanshinAppViewModel$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i12.Provider<_i9.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(
    this._homePageFactory$Provider,
    this._viewModelFactoryOfZanshinAppViewModel$Provider,
  );

  final _HomePageFactory$Provider _homePageFactory$Provider;

  final _ViewModelFactoryOfZanshinAppViewModel$Provider
  _viewModelFactoryOfZanshinAppViewModel$Provider;

  late final _i9.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
    _viewModelFactoryOfZanshinAppViewModel$Provider,
  );

  @override
  _i9.ZanshinAppFactory get() => _factory;
}

class _ZanshinAppViewModel$Provider
    implements _i12.Provider<_i21.ZanshinAppViewModel> {
  const _ZanshinAppViewModel$Provider(this._settingsStore$Provider);

  final _SettingsStore$Provider _settingsStore$Provider;

  @override
  _i21.ZanshinAppViewModel get() =>
      _i21.ZanshinAppViewModel(_settingsStore$Provider.get());
}

class _ZanshinWorker$Provider
    implements _i12.Provider<_i10.Future<_i11.ZanshinWorker>> {
  _ZanshinWorker$Provider(
    this._provisionListenerOfZanshinWorker$Provider,
    this._module,
  );

  final _ProvisionListenerOfZanshinWorker$Provider
  _provisionListenerOfZanshinWorker$Provider;

  final _i3.WorkerModule _module;

  _i10.Future<_i11.ZanshinWorker>? _singletonFuture;

  _i10.Future<_i11.ZanshinWorker> _create() async {
    final instance = await _module.worker();
    _provisionListenerOfZanshinWorker$Provider.get().onProvision(instance);
    return instance;
  }

  @override
  _i10.Future<_i11.ZanshinWorker> get() => _singletonFuture ??= _create();
}
