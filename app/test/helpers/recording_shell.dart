// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

/// A fake shell: records the calls, answers `getTheme` when the test completes [theme], and emits what the test
/// adds to [changes]. Install it with `ZanshinShellPlatform.instance = shell`.
final class RecordingShell extends ZanshinShellPlatform with MockPlatformInterfaceMixin {
  RecordingShell() : super.forTesting();

  final List<String> calls = [];
  final theme = Completer<ShellTheme>();
  final changes = StreamController<ShellTheme>.broadcast();

  Future<void> close() => changes.close();

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
  Future<void> startWindowDrag() async {}

  @override
  Future<void> performTitlebarDoubleClickAction() async {}
}
