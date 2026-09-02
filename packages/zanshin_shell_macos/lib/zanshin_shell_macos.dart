// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// macOS implementation of [ZanshinShellPlatform] over a single bidirectional
/// [MethodChannel]: this side calls into Swift, and the Swift side pushes
/// `onThemeChanged` calls back through the same channel.
class ZanshinShellMacOS extends ZanshinShellPlatform {
  ZanshinShellMacOS() {
    _channel.setMethodCallHandler(_handleMethodCall);
  }

  static void registerWith() {
    ZanshinShellPlatform.instance = ZanshinShellMacOS();
  }

  static const MethodChannel _channel = MethodChannel('zanshin_shell');

  final StreamController<ShellTheme> _themeChanges =
      StreamController<ShellTheme>.broadcast();

  Future<Object?> _handleMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onThemeChanged':
        _themeChanges.add(_themeFromMap(call.arguments));
      default:
        throw MissingPluginException('Unknown method ${call.method}');
    }
    return null;
  }

  static ShellTheme _themeFromMap(Object? arguments) {
    final map = (arguments! as Map).cast<String, Object?>();
    return ShellTheme(
      brightness: map['brightness'] == 'dark'
          ? Brightness.dark
          : Brightness.light,
      accentColor: Color(map['accentColor']! as int),
    );
  }

  @override
  Future<ShellTheme> getTheme() async {
    final map = await _channel.invokeMapMethod<String, Object?>('getTheme');
    return _themeFromMap(map);
  }

  @override
  Stream<ShellTheme> get onThemeChanged => _themeChanges.stream;

  @override
  Future<void> setWindowAppearance(WindowAppearance appearance) =>
      _channel.invokeMethod<void>('setWindowAppearance', appearance.name);

  @override
  Future<void> startWindowDrag() =>
      _channel.invokeMethod<void>('startWindowDrag');

  @override
  Future<void> performTitlebarDoubleClickAction() =>
      _channel.invokeMethod<void>('performTitlebarDoubleClickAction');
}
