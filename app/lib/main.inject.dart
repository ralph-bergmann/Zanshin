// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'dart:async' as _i6;

import 'package:flutter/src/foundation/key.dart' as _i10;
import 'package:inject_annotation/inject_annotation.dart' as _i8;
import 'package:inject_annotation/src/api/provision_listener.dart' as _i11;

import 'main.dart' as _i1;
import 'src/features/app/zanshin_app.dart' as _i5;
import 'src/features/home/home_page.dart' as _i9;
import 'src/ffi/diagnostics.dart' as _i3;
import 'src/ffi/zanshin_version.dart' as _i2;
import 'src/worker/isolate.dart' as _i7;
import 'src/worker/worker_module.dart' as _i4;

class MainComponent$Component implements _i1.MainComponent {
  factory MainComponent$Component.create({
    _i2.ZanshinFfiModule? zanshinFfiModule,
    _i3.ZanshinDiagnosticsModule? zanshinDiagnosticsModule,
    _i4.WorkerModule? workerModule,
  }) => MainComponent$Component._(
    zanshinFfiModule ?? _i2.ZanshinFfiModule(),
    zanshinDiagnosticsModule ?? _i3.ZanshinDiagnosticsModule(),
    workerModule ?? _i4.WorkerModule(),
  );

  MainComponent$Component._(
    _i2.ZanshinFfiModule zanshinFfiModule,
    _i3.ZanshinDiagnosticsModule zanshinDiagnosticsModule,
    _i4.WorkerModule workerModule,
  ) {
    final getDiagnostics$Provider = _GetDiagnostics$Provider(
      zanshinDiagnosticsModule,
    );
    final zanshinFfiVersion$Provider = _ZanshinFfiVersion$Provider(
      zanshinFfiModule,
    );
    final homePageFactory$Provider = _HomePageFactory$Provider(
      zanshinFfiVersion$Provider,
    );
    final provisionListenerOfZanshinWorker$Provider =
        _ProvisionListenerOfZanshinWorker$Provider(workerModule);
    _zanshinAppFactory$Provider = _ZanshinAppFactory$Provider(
      homePageFactory$Provider,
    );
    _zanshinWorker$Provider = _ZanshinWorker$Provider(
      provisionListenerOfZanshinWorker$Provider,
      workerModule,
    );
  }

  late final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  late final _ZanshinWorker$Provider _zanshinWorker$Provider;

  @override
  _i5.ZanshinAppFactory get zanshinAppFactory =>
      _zanshinAppFactory$Provider.get();

  @override
  _i6.Future<_i7.ZanshinWorker> get worker => _zanshinWorker$Provider.get();
}

class _GetDiagnostics$Provider implements _i8.Provider<_i3.GetDiagnostics> {
  _GetDiagnostics$Provider(this._module);

  final _i3.ZanshinDiagnosticsModule _module;

  late final _i3.GetDiagnostics _singleton = _create();

  _i3.GetDiagnostics _create() => _module.zanshinDiagnostics();

  @override
  _i3.GetDiagnostics get() => _singleton;
}

class _HomePageFactory$Factory implements _i9.HomePageFactory {
  const _HomePageFactory$Factory(this._zanshinFfiVersion$Provider);

  final _ZanshinFfiVersion$Provider _zanshinFfiVersion$Provider;

  @override
  _i9.HomePage create({_i10.Key? key}) => _i9.HomePage(
    zanshinFfiVersion: _zanshinFfiVersion$Provider.get(),
    key: key,
  );
}

class _HomePageFactory$Provider implements _i8.Provider<_i9.HomePageFactory> {
  _HomePageFactory$Provider(this._zanshinFfiVersion$Provider);

  final _ZanshinFfiVersion$Provider _zanshinFfiVersion$Provider;

  late final _i9.HomePageFactory _factory = _HomePageFactory$Factory(
    _zanshinFfiVersion$Provider,
  );

  @override
  _i9.HomePageFactory get() => _factory;
}

class _ProvisionListenerOfZanshinWorker$Provider
    implements _i8.Provider<_i11.ProvisionListener<_i7.ZanshinWorker>> {
  _ProvisionListenerOfZanshinWorker$Provider(this._module);

  final _i4.WorkerModule _module;

  late final _i11.ProvisionListener<_i7.ZanshinWorker> _singleton = _create();

  _i11.ProvisionListener<_i7.ZanshinWorker> _create() =>
      _module.workerLifecycle();

  @override
  _i11.ProvisionListener<_i7.ZanshinWorker> get() => _singleton;
}

class _ZanshinAppFactory$Factory implements _i5.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(this._homePageFactory$Provider);

  final _HomePageFactory$Provider _homePageFactory$Provider;

  @override
  _i5.ZanshinApp create({_i10.Key? key}) => _i5.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i8.Provider<_i5.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(this._homePageFactory$Provider);

  final _HomePageFactory$Provider _homePageFactory$Provider;

  late final _i5.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
  );

  @override
  _i5.ZanshinAppFactory get() => _factory;
}

class _ZanshinFfiVersion$Provider
    implements _i8.Provider<_i2.ZanshinFfiVersion> {
  _ZanshinFfiVersion$Provider(this._module);

  final _i2.ZanshinFfiModule _module;

  late final _i2.ZanshinFfiVersion _singleton = _create();

  _i2.ZanshinFfiVersion _create() => _module.zanshinFfiVersion();

  @override
  _i2.ZanshinFfiVersion get() => _singleton;
}

class _ZanshinWorker$Provider
    implements _i8.Provider<_i6.Future<_i7.ZanshinWorker>> {
  _ZanshinWorker$Provider(
    this._provisionListenerOfZanshinWorker$Provider,
    this._module,
  );

  final _ProvisionListenerOfZanshinWorker$Provider
  _provisionListenerOfZanshinWorker$Provider;

  final _i4.WorkerModule _module;

  _i6.Future<_i7.ZanshinWorker>? _singletonFuture;

  _i6.Future<_i7.ZanshinWorker> _create() async {
    final instance = await _module.worker();
    _provisionListenerOfZanshinWorker$Provider.get().onProvision(instance);
    return instance;
  }

  @override
  _i6.Future<_i7.ZanshinWorker> get() => _singletonFuture ??= _create();
}
