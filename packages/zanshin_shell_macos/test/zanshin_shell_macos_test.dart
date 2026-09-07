// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell_macos/zanshin_shell_macos.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('zanshin_shell');
  final log = <MethodCall>[];

  late ZanshinShellMacOS shell;

  setUp(() {
    log.clear();
    shell = ZanshinShellMacOS();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      if (call.method == 'getTheme') {
        return <String, Object?>{
          'brightness': 'dark',
          'accentColor': 0xFFFF453A,
        };
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
  });

  test('registerWith installs the macOS implementation', () {
    ZanshinShellMacOS.registerWith();
    expect(ZanshinShellPlatform.instance, isA<ZanshinShellMacOS>());
  });

  test('getTheme parses brightness and accent color', () async {
    final ShellTheme theme = await shell.getTheme();
    expect(theme.brightness, Brightness.dark);
    expect(theme.accentColor, const Color(0xFFFF453A));
    expect(log.single.method, 'getTheme');
  });

  test('setWindowAppearance sends the enum name', () async {
    await shell.setWindowAppearance(WindowAppearance.dark);
    expect(log.single.method, 'setWindowAppearance');
    expect(log.single.arguments, 'dark');
  });

  test(
    'startWindowDrag and double-click action invoke their methods',
    () async {
      await shell.startWindowDrag();
      await shell.performTitlebarDoubleClickAction();
      expect(log.map((c) => c.method), [
        'startWindowDrag',
        'performTitlebarDoubleClickAction',
      ]);
    },
  );

  test('onThemeChanged emits when the native side pushes a theme', () async {
    final Future<ShellTheme> future = shell.onThemeChanged.first;
    final TestDefaultBinaryMessenger messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    await messenger.handlePlatformMessage(
      'zanshin_shell',
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('onThemeChanged', <String, Object?>{
          'brightness': 'light',
          'accentColor': 0xFF32D74B,
        }),
      ),
      (_) {},
    );
    final ShellTheme theme = await future;
    expect(theme.brightness, Brightness.light);
    expect(theme.accentColor, const Color(0xFF32D74B));
  });
}
