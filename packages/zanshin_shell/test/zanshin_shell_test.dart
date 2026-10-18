// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

final class RecordingPlatform extends ZanshinShellPlatform with MockPlatformInterfaceMixin {
  RecordingPlatform() : super.forTesting();

  final calls = <String>[];
  final themeController = StreamController<ShellTheme>.broadcast();
  final chromeController = StreamController<WindowChromeChange>.broadcast();

  Future<void> close() async {
    await themeController.close();
    await chromeController.close();
  }

  static const chrome = WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14));

  static const theme = ShellTheme(
    brightness: Brightness.dark,
    accentColor: Color(0xFFBF5AF2),
    appleAccentColor: 5,
    reduceMotion: true,
    scrollerStyle: ScrollerStyle.legacy,
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

  /// The folder drag handler the dispatcher installed, if any.
  FolderDragHandler? folderDragHandler;

  /// When set, [enableFolderDrops] fails with this error.
  Object? enableError;

  @override
  void setFolderDragHandler(FolderDragHandler? handler) {
    calls.add('setFolderDragHandler:${handler == null ? 'null' : 'set'}');
    folderDragHandler = handler;
  }

  @override
  Future<void> enableFolderDrops(int viewId) async {
    calls.add('enableFolderDrops:$viewId');
    if (enableError case final Object error) {
      throw error;
    }
  }

  @override
  Future<void> disableFolderDrops(int viewId) async {
    calls.add('disableFolderDrops:$viewId');
  }

  @override
  Future<WindowChrome> watchWindowChrome(int viewId) async {
    calls.add('watchWindowChrome:$viewId');
    return chrome;
  }

  @override
  Future<void> unwatchWindowChrome(int viewId) async {
    calls.add('unwatchWindowChrome:$viewId');
  }

  @override
  Stream<WindowChromeChange> get onWindowChromeChanged => chromeController.stream;

  @override
  Future<String?> chooseDirectory({required int viewId, String? initialDirectory, String? prompt}) async {
    calls.add('chooseDirectory:$viewId:$initialDirectory:$prompt');
    return '/Users/me/code/api';
  }

  @override
  Future<void> revealInFinder(String path) async {
    calls.add('revealInFinder:$path');
  }
}

void main() {
  late RecordingPlatform platform;

  setUp(() {
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  tearDown(() => platform.close());

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
    final Future<ShellTheme> future = ZanshinShell.onThemeChanged.first;
    platform.themeController.add(RecordingPlatform.theme);
    expect(await future, RecordingPlatform.theme);
  });

  test('the window chrome calls and changes pass through to the platform', () async {
    final Future<WindowChromeChange> change = ZanshinShell.onWindowChromeChanged.first;
    expect(await ZanshinShell.watchWindowChrome(3), RecordingPlatform.chrome);
    await ZanshinShell.unwatchWindowChrome(3);
    platform.chromeController.add((viewId: 3, chrome: const WindowChrome(fullScreen: true)));
    expect(await change, (viewId: 3, chrome: const WindowChrome(fullScreen: true)));
    expect(platform.calls, ['watchWindowChrome:3', 'unwatchWindowChrome:3']);
  });

  test('the folder picker and Reveal in Finder pass through to the platform', () async {
    expect(
      await ZanshinShell.chooseDirectory(viewId: 2, initialDirectory: '/Users/me', prompt: 'Add'),
      '/Users/me/code/api',
    );
    expect(await ZanshinShell.chooseDirectory(viewId: 4), '/Users/me/code/api');
    await ZanshinShell.revealInFinder('/Users/me/code/api');
    expect(platform.calls, [
      'chooseDirectory:2:/Users/me:Add',
      'chooseDirectory:4:null:null',
      'revealInFinder:/Users/me/code/api',
    ]);
  });

  test('the accessibility, accent and scroll bar state reaches the app unchanged', () async {
    final ShellTheme theme = await ZanshinShell.getTheme();
    expect(theme.appleAccentColor, 5);
    expect(theme.reduceMotion, isTrue);
    expect(theme.scrollerStyle, ScrollerStyle.legacy);
  });
}
