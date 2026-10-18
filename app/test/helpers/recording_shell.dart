// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// A fake shell: records the calls, answers `getTheme` when the test completes [theme], and emits what the test
/// adds to [changes]. Install it with `ZanshinShellPlatform.instance = shell`.
///
/// The window chrome: `watchWindowChrome` answers [chrome] (or [chromeAnswer]'s future while one is set, which the
/// test completes or fails), and [chromeChanges] carries what the test pushes.
final class RecordingShell extends ZanshinShellPlatform with MockPlatformInterfaceMixin {
  RecordingShell() : super.forTesting();

  final List<String> calls = [];
  final theme = Completer<ShellTheme>();
  final changes = StreamController<ShellTheme>.broadcast();

  /// What `watchWindowChrome` answers while [chromeAnswer] is null.
  var chrome = const WindowChrome();

  /// A pending answer to `watchWindowChrome`; set it for a late or failing watch.
  Completer<WindowChrome>? chromeAnswer;

  final chromeChanges = StreamController<WindowChromeChange>.broadcast();

  Future<void> close() async {
    await changes.close();
    await chromeChanges.close();
  }

  @override
  Future<ShellTheme> getTheme() {
    calls.add('getTheme');
    return theme.future;
  }

  @override
  Stream<ShellTheme> get onThemeChanged => changes.stream;

  @override
  Future<void> setWindowAppearance(WindowAppearance appearance) async {
    calls.add('setWindowAppearance:${appearance.name}');
  }

  @override
  Future<void> startWindowDrag() async {
    calls.add('startWindowDrag');
  }

  @override
  Future<void> performTitlebarDoubleClickAction() async {
    calls.add('performTitlebarDoubleClickAction');
  }

  @override
  Future<WindowChrome> watchWindowChrome(int viewId) {
    calls.add('watchWindowChrome:$viewId');
    return chromeAnswer?.future ?? Future<WindowChrome>.value(chrome);
  }

  @override
  Future<void> unwatchWindowChrome(int viewId) async {
    calls.add('unwatchWindowChrome:$viewId');
  }

  @override
  Stream<WindowChromeChange> get onWindowChromeChanged => chromeChanges.stream;
}
