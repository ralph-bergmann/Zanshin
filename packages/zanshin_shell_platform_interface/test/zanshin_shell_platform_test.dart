// SPDX-License-Identifier: MIT

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

final class _FakePlatform extends ZanshinShellPlatform {
  _FakePlatform() : super.forTesting();
}

final class _NotMockPlatform extends ZanshinShellPlatform
    with MockPlatformInterfaceMixin {
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

  test('default methods throw UnimplementedError', () {
    final platform = _FakePlatform();
    expect(() => platform.getTheme(), throwsUnimplementedError);
    expect(() => platform.onThemeChanged, throwsUnimplementedError);
    expect(
      () => platform.setWindowAppearance(WindowAppearance.dark),
      throwsUnimplementedError,
    );
    expect(() => platform.startWindowDrag(), throwsUnimplementedError);
    expect(
      () => platform.performTitlebarDoubleClickAction(),
      throwsUnimplementedError,
    );
  });

  test('instance setter verifies the token', () {
    final mock = _NotMockPlatform();
    ZanshinShellPlatform.instance = mock;
    expect(ZanshinShellPlatform.instance, same(mock));
  });
}
