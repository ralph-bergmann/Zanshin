// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// macOS implementation of [ZanshinShellPlatform] over three [MethodChannel]s:
/// `zanshin_shell` (theme + window commands, the folder picker and Reveal in
/// Finder; also carries the Swift side's `onThemeChanged` calls back to Dart),
/// `zanshin_shell/folder_drop` (folder
/// drags) and `zanshin_shell/window_chrome` (each watched view's full screen
/// and traffic-light block).
class ZanshinShellMacOS extends ZanshinShellPlatform {
  static void registerWith() {
    ZanshinShellPlatform.instance = ZanshinShellMacOS();
  }

  static const _channel = MethodChannel('zanshin_shell');
  static const _folderDropChannel = MethodChannel('zanshin_shell/folder_drop');
  static const _windowChromeChannel = MethodChannel('zanshin_shell/window_chrome');

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

  /// Decodes a theme map. `brightness` and `accentColor` are required; every later key is optional, so a native
  /// side that does not send one yields the constructor's default (or null), never an error.
  static ShellTheme _themeFromMap(Object? arguments) {
    final Map<String, Object?> map = (arguments! as Map).cast<String, Object?>();
    return ShellTheme(
      brightness: map['brightness'] == 'dark' ? Brightness.dark : Brightness.light,
      accentColor: Color(map['accentColor']! as int),
      appleAccentColor: map['appleAccentColor'] as int?,
      reduceMotion: map['reduceMotion'] as bool? ?? false,
      reduceTransparency: map['reduceTransparency'] as bool? ?? false,
      increaseContrast: map['increaseContrast'] as bool? ?? false,
      selectedTextBackgroundDark: _color(map['selectedTextBackgroundDark']),
      selectedTextBackgroundLight: _color(map['selectedTextBackgroundLight']),
      unemphasizedSelectedTextBackgroundDark: _color(map['unemphasizedSelectedTextBackgroundDark']),
      unemphasizedSelectedTextBackgroundLight: _color(map['unemphasizedSelectedTextBackgroundLight']),
      scrollerStyle: map['scrollerStyle'] == 'legacy' ? ScrollerStyle.legacy : ScrollerStyle.overlay,
      jumpToClickedSpot: map['jumpToClickedSpot'] as bool? ?? false,
    );
  }

  /// An ARGB int as a colour, like `accentColor`; absent stays null.
  static Color? _color(Object? argb) => argb == null ? null : Color(argb as int);

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

  /// Like the theme stream, the host→Dart handler is installed on the first listener.
  late final _windowChromeChanges = StreamController<WindowChromeChange>.broadcast(
    onListen: () => _windowChromeChannel.setMethodCallHandler(_handleWindowChromeCall),
  );

  /// Decodes a native `changed` call onto [onWindowChromeChanged]. Anything malformed becomes a `bad-args` error
  /// reply, which the native side ignores.
  Future<Object?> _handleWindowChromeCall(MethodCall call) async {
    final WindowChromeChange change = switch ((call.method, call.arguments)) {
      ('changed', final Map<Object?, Object?> map) when map['viewId'] is int => (
        viewId: map['viewId']! as int,
        chrome: _windowChromeFrom(map),
      ),
      _ => throw PlatformException(code: 'bad-args', message: 'Malformed window chrome call: ${call.method}'),
    };
    _windowChromeChanges.add(change);
    return null;
  }

  /// Decodes a report `{fullScreen, trafficLights?: {x, y, width, height}}`; an absent block is null.
  static WindowChrome _windowChromeFrom(Object? arguments) => switch (arguments) {
    final Map<Object?, Object?> map when map['fullScreen'] is bool => WindowChrome(
      fullScreen: map['fullScreen']! as bool,
      trafficLights: switch (map['trafficLights']) {
        null => null,
        {'x': final double x, 'y': final double y, 'width': final double width, 'height': final double height} =>
          Rect.fromLTWH(x, y, width, height),
        _ => throw PlatformException(code: 'bad-args', message: 'Malformed traffic-light block'),
      },
    ),
    _ => throw PlatformException(code: 'bad-args', message: 'Malformed window chrome report'),
  };

  @override
  Future<WindowChrome> watchWindowChrome(int viewId) async => _windowChromeFrom(
    await _windowChromeChannel.invokeMethod<Object?>('watch', <String, Object?>{'viewId': viewId}),
  );

  @override
  Future<void> unwatchWindowChrome(int viewId) =>
      _windowChromeChannel.invokeMethod<void>('unwatch', <String, Object?>{'viewId': viewId});

  @override
  Stream<WindowChromeChange> get onWindowChromeChanged => _windowChromeChanges.stream;

  @override
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt}) =>
      _channel.invokeMethod<String>('chooseDirectory', <String, Object?>{
        'viewId': viewId,
        'initialDirectory': ?initialDirectory,
        'prompt': ?prompt,
      });

  @override
  Future<void> revealInFinder(String path) =>
      _channel.invokeMethod<void>('revealInFinder', <String, Object?>{'path': path});
}
