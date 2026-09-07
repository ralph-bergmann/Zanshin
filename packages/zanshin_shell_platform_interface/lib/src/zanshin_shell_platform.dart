// SPDX-License-Identifier: MIT

import 'package:meta/meta.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'shell_theme.dart';

/// The interface that platform implementations of zanshin_shell must extend.
abstract class ZanshinShellPlatform extends PlatformInterface {
  ZanshinShellPlatform() : super(token: _token);

  /// Test-only constructor so tests can subclass without holding the token.
  @protected
  ZanshinShellPlatform.forTesting() : super(token: _token);

  static final _token = Object();

  static ZanshinShellPlatform? _instance;

  /// The platform implementation in use.
  ///
  /// Unset until a platform registers itself (`registerWith`); accessing it
  /// then is a wiring error, so it throws instead of returning a stub.
  static ZanshinShellPlatform get instance {
    final ZanshinShellPlatform? instance = _instance;
    if (instance == null) {
      throw StateError(
        'No ZanshinShellPlatform registered. Is the app running on a '
        'supported platform with the endorsed implementation?',
      );
    }
    return instance;
  }

  static set instance(ZanshinShellPlatform value) {
    PlatformInterface.verify(value, _token);
    _instance = value;
  }

  /// The current system theme.
  Future<ShellTheme> getTheme() => throw UnimplementedError();

  /// Emits whenever the system brightness or accent color changes.
  Stream<ShellTheme> get onThemeChanged => throw UnimplementedError();

  /// Forces the window (blur background + traffic lights) to the given
  /// appearance, or back to following the system.
  Future<void> setWindowAppearance(WindowAppearance appearance) =>
      throw UnimplementedError();

  /// Starts a native window drag. Must be called from within an active
  /// pointer-down gesture (the native side reuses the current mouse event).
  Future<void> startWindowDrag() => throw UnimplementedError();

  /// Performs the system titlebar double-click action (zoom/minimize/none,
  /// per the user's "double-click a window's title bar to" setting).
  Future<void> performTitlebarDoubleClickAction() => throw UnimplementedError();
}
