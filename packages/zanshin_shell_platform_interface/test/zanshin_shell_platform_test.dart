// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

final class _FakePlatform extends ZanshinShellPlatform {
  _FakePlatform() : super.forTesting();
}

final class _NotMockPlatform extends ZanshinShellPlatform with MockPlatformInterfaceMixin {
  _NotMockPlatform() : super.forTesting();
}

void main() {
  test('ShellTheme value equality and toString', () {
    const a = ShellTheme(
      brightness: Brightness.dark,
      accentColor: Color(0xFF007AFF),
    );
    const b = ShellTheme(
      brightness: Brightness.dark,
      accentColor: Color(0xFF007AFF),
    );
    const c = ShellTheme(
      brightness: Brightness.light,
      accentColor: Color(0xFF007AFF),
    );
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(c)));
    expect(a.toString(), contains('dark'));
  });

  test('ShellTheme defaults the accessibility, accent and selection state', () {
    const theme = ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF));
    expect(theme.appleAccentColor, isNull);
    expect(theme.reduceMotion, isFalse);
    expect(theme.reduceTransparency, isFalse);
    expect(theme.increaseContrast, isFalse);
    expect(theme.selectedTextBackgroundDark, isNull);
    expect(theme.selectedTextBackgroundLight, isNull);
    expect(theme.unemphasizedSelectedTextBackgroundDark, isNull);
    expect(theme.unemphasizedSelectedTextBackgroundLight, isNull);
    expect(theme.scrollerStyle, ScrollerStyle.overlay);
    expect(theme.jumpToClickedSpot, isFalse);
  });

  test('every ShellTheme field takes part in equality, hashCode and toString', () {
    const base = ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF));
    const variants = <ShellTheme>[
      ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), appleAccentColor: 4),
      ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), reduceMotion: true),
      ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), reduceTransparency: true),
      ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), increaseContrast: true),
      ShellTheme(
        brightness: Brightness.dark,
        accentColor: Color(0xFF007AFF),
        selectedTextBackgroundDark: Color(0xFF3F638B),
      ),
      ShellTheme(
        brightness: Brightness.dark,
        accentColor: Color(0xFF007AFF),
        selectedTextBackgroundLight: Color(0xFFB3D7FF),
      ),
      ShellTheme(
        brightness: Brightness.dark,
        accentColor: Color(0xFF007AFF),
        unemphasizedSelectedTextBackgroundDark: Color(0xFF464646),
      ),
      ShellTheme(
        brightness: Brightness.dark,
        accentColor: Color(0xFF007AFF),
        unemphasizedSelectedTextBackgroundLight: Color(0xFFDCDCDC),
      ),
      ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), scrollerStyle: ScrollerStyle.legacy),
      ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF007AFF), jumpToClickedSpot: true),
    ];
    for (final variant in variants) {
      expect(variant, isNot(equals(base)), reason: '$variant');
      expect(variant.hashCode, isNot(equals(base.hashCode)), reason: '$variant');
      expect(variant.toString(), isNot(equals(base.toString())));
    }
  });

  test('default methods throw UnimplementedError', () {
    final platform = _FakePlatform();
    expect(platform.getTheme, throwsUnimplementedError);
    expect(() => platform.onThemeChanged, throwsUnimplementedError);
    expect(
      () => platform.setWindowAppearance(WindowAppearance.dark),
      throwsUnimplementedError,
    );
    expect(platform.startWindowDrag, throwsUnimplementedError);
    expect(
      platform.performTitlebarDoubleClickAction,
      throwsUnimplementedError,
    );
    expect(() => platform.setFolderDragHandler(null), throwsUnimplementedError);
    expect(() => platform.enableFolderDrops(1), throwsUnimplementedError);
    expect(() => platform.disableFolderDrops(1), throwsUnimplementedError);
    expect(() => platform.watchWindowChrome(1), throwsUnimplementedError);
    expect(() => platform.unwatchWindowChrome(1), throwsUnimplementedError);
    expect(() => platform.onWindowChromeChanged, throwsUnimplementedError);
    expect(() => platform.chooseDirectory(viewId: 1), throwsUnimplementedError);
    expect(() => platform.revealInFinder('/tmp'), throwsUnimplementedError);
  });

  test('WindowChrome defaults to a window out of full screen without a block', () {
    const chrome = WindowChrome();
    expect(chrome.fullScreen, isFalse);
    expect(chrome.trafficLights, isNull);
  });

  test('every WindowChrome field takes part in equality, hashCode and toString', () {
    const block = Rect.fromLTWH(19, 19, 60, 14);
    const base = WindowChrome(trafficLights: block);
    expect(base, const WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14)));
    expect(base.hashCode, const WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14)).hashCode);
    expect(base.toString(), 'WindowChrome(fullScreen: false, trafficLights: $block)');
    for (final variant in const <WindowChrome>[
      WindowChrome(),
      WindowChrome(fullScreen: true, trafficLights: block),
      WindowChrome(trafficLights: Rect.fromLTWH(20, 20, 60, 14)),
    ]) {
      expect(variant, isNot(equals(base)), reason: '$variant');
      expect(variant.hashCode, isNot(equals(base.hashCode)), reason: '$variant');
      expect(variant.toString(), isNot(equals(base.toString())));
    }
  });

  test('instance setter verifies the token', () {
    final mock = _NotMockPlatform();
    ZanshinShellPlatform.instance = mock;
    expect(ZanshinShellPlatform.instance, same(mock));
  });
}
