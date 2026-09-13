// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// macOS implementation of [ZanshinShellPlatform] over two [MethodChannel]s:
/// `zanshin_shell` (theme + window commands; also carries the Swift side's
/// `onThemeChanged` calls back to Dart) and `zanshin_shell/folder_drop`
/// (folder drags).
class ZanshinShellMacOS extends ZanshinShellPlatform {
  static void registerWith() {
    ZanshinShellPlatform.instance = ZanshinShellMacOS();
  }

  static const _channel = MethodChannel('zanshin_shell');
  static const _folderDropChannel = MethodChannel('zanshin_shell/folder_drop');

  /// The host→Dart handler is installed on the first listener, not in the
  /// constructor: the engine runs the generated registrant before `main`,
  /// where no binding (and so no binary messenger) exists yet.
  late final _themeChanges = StreamController<ShellTheme>.broadcast(
    onListen: () => _channel.setMethodCallHandler(_handleMethodCall),
  );

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
    final Map<String, Object?> map = (arguments! as Map).cast<String, Object?>();
    return ShellTheme(
      brightness: map['brightness'] == 'dark' ? Brightness.dark : Brightness.light,
      accentColor: Color(map['accentColor']! as int),
    );
  }

  @override
  Future<ShellTheme> getTheme() async {
    final Map<String, Object?>? map = await _channel.invokeMapMethod<String, Object?>('getTheme');
    return _themeFromMap(map);
  }

  @override
  Stream<ShellTheme> get onThemeChanged => _themeChanges.stream;

  @override
  Future<void> setWindowAppearance(WindowAppearance appearance) =>
      _channel.invokeMethod<void>('setWindowAppearance', appearance.name);

  @override
  Future<void> startWindowDrag() => _channel.invokeMethod<void>('startWindowDrag');

  @override
  Future<void> performTitlebarDoubleClickAction() => _channel.invokeMethod<void>('performTitlebarDoubleClickAction');

  /// Installs the host→Dart handler only when asked, never in the
  /// constructor: the engine runs the generated registrant before `main`,
  /// where no binding (and so no binary messenger) exists yet.
  @override
  void setFolderDragHandler(FolderDragHandler? handler) => _folderDropChannel.setMethodCallHandler(
    handler == null ? null : (call) async => handler(_folderDragEventFrom(call)),
  );

  /// Decodes a native folder drag call. Anything malformed becomes a
  /// `bad-args` error reply, which the native side treats as a rejection.
  static FolderDragEvent _folderDragEventFrom(MethodCall call) => switch ((call.method, call.arguments)) {
    (
      'dragEntered',
      {'viewId': final int viewId, 'x': final double x, 'y': final double y, 'paths': final List<Object?> paths},
    )
        when paths.isNotEmpty =>
      FolderDragEntered(viewId: viewId, position: Offset(x, y), paths: List<String>.unmodifiable(paths)),
    ('dragUpdated', {'viewId': final int viewId, 'x': final double x, 'y': final double y}) => FolderDragUpdated(
      viewId: viewId,
      position: Offset(x, y),
    ),
    ('dragExited', {'viewId': final int viewId}) => FolderDragExited(viewId: viewId),
    (
      'dropped',
      {'viewId': final int viewId, 'x': final double x, 'y': final double y, 'paths': final List<Object?> paths},
    )
        when paths.isNotEmpty =>
      FolderDropped(viewId: viewId, position: Offset(x, y), paths: List<String>.unmodifiable(paths)),
    _ => throw PlatformException(code: 'bad-args', message: 'Malformed folder drag call: ${call.method}'),
  };

  @override
  Future<void> enableFolderDrops(int viewId) =>
      _folderDropChannel.invokeMethod<void>('attach', <String, Object?>{'viewId': viewId});

  @override
  Future<void> disableFolderDrops(int viewId) =>
      _folderDropChannel.invokeMethod<void>('detach', <String, Object?>{'viewId': viewId});
}
