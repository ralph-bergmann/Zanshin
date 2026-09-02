// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

final class RecordingPlatform extends ZanshinShellPlatform
    with MockPlatformInterfaceMixin {
  RecordingPlatform() : super.forTesting();

  final calls = <String>[];
  final themeController = StreamController<ShellTheme>.broadcast();

  static const theme = ShellTheme(
    brightness: Brightness.dark,
    accentColor: Color(0xFFBF5AF2),
  );

  @override
  Future<ShellTheme> getTheme() async {
    calls.add('getTheme');
    return theme;
  }

  @override
  Stream<ShellTheme> get onThemeChanged => themeController.stream;

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
}

void main() {
  late RecordingPlatform platform;

  setUp(() {
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  test('ZanshinShell delegates to the platform instance', () async {
    expect(await ZanshinShell.getTheme(), RecordingPlatform.theme);
    await ZanshinShell.setWindowAppearance(WindowAppearance.light);
    await ZanshinShell.startWindowDrag();
    await ZanshinShell.performTitlebarDoubleClickAction();
    expect(platform.calls, [
      'getTheme',
      'setWindowAppearance:light',
      'startWindowDrag',
      'performTitlebarDoubleClickAction',
    ]);
  });

  test('onThemeChanged forwards the platform stream', () async {
    final future = ZanshinShell.onThemeChanged.first;
    platform.themeController.add(RecordingPlatform.theme);
    expect(await future, RecordingPlatform.theme);
  });
}
