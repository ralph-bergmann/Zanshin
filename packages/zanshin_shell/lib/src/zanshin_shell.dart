// SPDX-License-Identifier: MIT

import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// App-facing API of the zanshin_shell plugin.
// WHY: the static facade is the intended shape — `ZanshinShell.getTheme()` is
// the plugin's namespace over the single `ZanshinShellPlatform.instance`, and
// there is nothing to construct, so top-level functions would only lose the
// grouping the call sites rely on.
// ignore: avoid_classes_with_only_static_members
abstract final class ZanshinShell {
  static ZanshinShellPlatform get _platform => ZanshinShellPlatform.instance;

  /// The current system theme: day/night mode, the accent, the text-selection colours, the accessibility display
  /// options (reduce motion, reduce transparency, increase contrast) and the scroll bar preferences.
  static Future<ShellTheme> getTheme() => _platform.getTheme();

  /// Emits whenever any part of [getTheme]'s answer changes.
  static Stream<ShellTheme> get onThemeChanged => _platform.onThemeChanged;

  /// Forces the window chrome (background, traffic lights and their rings) to
  /// the given appearance - use this when the in-app theme mode overrides the
  /// system.
  static Future<void> setWindowAppearance(WindowAppearance appearance) => _platform.setWindowAppearance(appearance);

  /// Starts a native window drag; call from an active drag gesture.
  static Future<void> startWindowDrag() => _platform.startWindowDrag();

  /// Performs the user-configured titlebar double-click action.
  static Future<void> performTitlebarDoubleClickAction() => _platform.performTitlebarDoubleClickAction();

  /// Starts reporting the chrome (full screen, the standard window buttons' block) of the window that hosts the
  /// Flutter view [viewId] on [onWindowChromeChanged] and answers its current chrome. Listen first, so no change
  /// between the answer and the subscription is lost.
  static Future<WindowChrome> watchWindowChrome(int viewId) => _platform.watchWindowChrome(viewId);

  /// Stops reporting the chrome of [viewId].
  static Future<void> unwatchWindowChrome(int viewId) => _platform.unwatchWindowChrome(viewId);

  /// Emits a watched view's chrome whenever it changes.
  static Stream<WindowChromeChange> get onWindowChromeChanged => _platform.onWindowChromeChanged;
}
