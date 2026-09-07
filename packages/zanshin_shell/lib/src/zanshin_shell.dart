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

  /// The current system theme (day/night mode + accent color).
  static Future<ShellTheme> getTheme() => _platform.getTheme();

  /// Emits whenever the system brightness or accent color changes.
  static Stream<ShellTheme> get onThemeChanged => _platform.onThemeChanged;

  /// Forces the window chrome (blur background, traffic lights) to the given
  /// appearance - use this when the in-app theme mode overrides the system.
  static Future<void> setWindowAppearance(WindowAppearance appearance) => _platform.setWindowAppearance(appearance);

  /// Starts a native window drag; call from an active drag gesture.
  static Future<void> startWindowDrag() => _platform.startWindowDrag();

  /// Performs the user-configured titlebar double-click action.
  static Future<void> performTitlebarDoubleClickAction() => _platform.performTitlebarDoubleClickAction();
}
