// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format width=80

// **************************************************************************
// Generator: inject.dart
// https://pub.dev/packages/inject_annotation
// **************************************************************************

// ignore_for_file: type=lint, type=warning
// ignore_for_file: no_leading_underscores_for_library_prefixes
import 'package:flutter/src/foundation/key.dart' as _i5;
import 'package:inject_annotation/inject_annotation.dart' as _i6;

import 'main.dart' as _i1;
import 'src/features/app/zanshin_app.dart' as _i3;
import 'src/features/home/home_page.dart' as _i4;
import 'src/ffi/zanshin_version.dart' as _i2;

class MainComponent$Component implements _i1.MainComponent {
  factory MainComponent$Component.create({
    _i2.ZanshinFfiModule? zanshinFfiModule,
  }) => MainComponent$Component._(zanshinFfiModule ?? _i2.ZanshinFfiModule());

  MainComponent$Component._(_i2.ZanshinFfiModule zanshinFfiModule) {
    final zanshinFfiVersion$Provider = _ZanshinFfiVersion$Provider(
      zanshinFfiModule,
    );
    final homePageFactory$Provider = _HomePageFactory$Provider(
      zanshinFfiVersion$Provider,
    );
    _zanshinAppFactory$Provider = _ZanshinAppFactory$Provider(
      homePageFactory$Provider,
    );
  }

  late final _ZanshinAppFactory$Provider _zanshinAppFactory$Provider;

  @override
  _i3.ZanshinAppFactory get zanshinAppFactory =>
      _zanshinAppFactory$Provider.get();
}

class _HomePageFactory$Factory implements _i4.HomePageFactory {
  const _HomePageFactory$Factory(this._zanshinFfiVersion$Provider);

  final _ZanshinFfiVersion$Provider _zanshinFfiVersion$Provider;

  @override
  _i4.HomePage create({_i5.Key? key}) => _i4.HomePage(
    key: key,
    zanshinFfiVersion: _zanshinFfiVersion$Provider.get(),
  );
}

class _HomePageFactory$Provider implements _i6.Provider<_i4.HomePageFactory> {
  _HomePageFactory$Provider(this._zanshinFfiVersion$Provider);

  final _ZanshinFfiVersion$Provider _zanshinFfiVersion$Provider;

  late final _i4.HomePageFactory _factory = _HomePageFactory$Factory(
    _zanshinFfiVersion$Provider,
  );

  @override
  _i4.HomePageFactory get() => _factory;
}

class _ZanshinAppFactory$Factory implements _i3.ZanshinAppFactory {
  const _ZanshinAppFactory$Factory(this._homePageFactory$Provider);

  final _HomePageFactory$Provider _homePageFactory$Provider;

  @override
  _i3.ZanshinApp create({_i5.Key? key}) => _i3.ZanshinApp(
    homePageFactory: _homePageFactory$Provider.get(),
    key: key,
  );
}

class _ZanshinAppFactory$Provider
    implements _i6.Provider<_i3.ZanshinAppFactory> {
  _ZanshinAppFactory$Provider(this._homePageFactory$Provider);

  final _HomePageFactory$Provider _homePageFactory$Provider;

  late final _i3.ZanshinAppFactory _factory = _ZanshinAppFactory$Factory(
    _homePageFactory$Provider,
  );

  @override
  _i3.ZanshinAppFactory get() => _factory;
}

class _ZanshinFfiVersion$Provider
    implements _i6.Provider<_i2.ZanshinFfiVersion> {
  _ZanshinFfiVersion$Provider(this._module);

  final _i2.ZanshinFfiModule _module;

  late final _i2.ZanshinFfiVersion _singleton = _create();

  _i2.ZanshinFfiVersion _create() => _module.zanshinFfiVersion();

  @override
  _i2.ZanshinFfiVersion get() => _singleton;
}
