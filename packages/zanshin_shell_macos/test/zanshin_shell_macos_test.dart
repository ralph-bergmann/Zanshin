// SPDX-License-Identifier: MIT

import 'dart:async';

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

  test('a theme map without the accessibility, accent and selection keys decodes to the defaults', () async {
    final ShellTheme theme = await shell.getTheme();
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

  test('a theme map with every key decodes the sent values', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      channel,
      (call) async => <String, Object?>{
        'brightness': 'light',
        'accentColor': 0xFF4757A1,
        'appleAccentColor': -1,
        'reduceMotion': true,
        'reduceTransparency': true,
        'increaseContrast': true,
        'selectedTextBackgroundDark': 0xFF3F638B,
        'selectedTextBackgroundLight': 0xFFB3D7FF,
        'unemphasizedSelectedTextBackgroundDark': 0xFF464646,
        'unemphasizedSelectedTextBackgroundLight': 0xFFDCDCDC,
        'scrollerStyle': 'legacy',
        'jumpToClickedSpot': true,
      },
    );
    expect(
      await shell.getTheme(),
      const ShellTheme(
        brightness: Brightness.light,
        accentColor: Color(0xFF4757A1),
        appleAccentColor: -1,
        reduceMotion: true,
        reduceTransparency: true,
        increaseContrast: true,
        selectedTextBackgroundDark: Color(0xFF3F638B),
        selectedTextBackgroundLight: Color(0xFFB3D7FF),
        unemphasizedSelectedTextBackgroundDark: Color(0xFF464646),
        unemphasizedSelectedTextBackgroundLight: Color(0xFFDCDCDC),
        scrollerStyle: ScrollerStyle.legacy,
        jumpToClickedSpot: true,
      ),
    );
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

  group('folder drops', () {
    const folderChannel = MethodChannel('zanshin_shell/folder_drop');
    const codec = StandardMethodCodec();
    final folderLog = <MethodCall>[];

    TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// Delivers a native folder drag call to Dart and decodes the reply.
    Future<Object?> nativeCall(String method, Map<String, Object?> arguments) => messenger()
        .handlePlatformMessage(folderChannel.name, codec.encodeMethodCall(MethodCall(method, arguments)), null)
        .then((reply) => codec.decodeEnvelope(reply!));

    setUp(() {
      folderLog.clear();
      messenger().setMockMethodCallHandler(folderChannel, (call) async {
        folderLog.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger().setMockMethodCallHandler(folderChannel, null);
      shell.setFolderDragHandler(null);
    });

    test('enableFolderDrops and disableFolderDrops attach and detach the view', () async {
      await shell.enableFolderDrops(7);
      await shell.disableFolderDrops(7);
      expect(folderLog.map((call) => call.method), ['attach', 'detach']);
      expect(folderLog.map((call) => call.arguments), [
        {'viewId': 7},
        {'viewId': 7},
      ]);
    });

    test('native drag calls reach the handler as events and return its answer', () async {
      final events = <FolderDragEvent>[];
      shell.setFolderDragHandler((event) {
        events.add(event);
        return event is! FolderDragUpdated;
      });

      expect(
        await nativeCall('dragEntered', {
          'viewId': 1,
          'x': 10.0,
          'y': 20.0,
          'paths': ['/a', '/b'],
        }),
        isTrue,
      );
      expect(await nativeCall('dragUpdated', {'viewId': 1, 'x': 11.0, 'y': 21.0}), isFalse);
      expect(await nativeCall('dragExited', {'viewId': 1}), isTrue);
      expect(
        await nativeCall('dropped', {
          'viewId': 2,
          'x': 12.0,
          'y': 22.0,
          'paths': ['/c'],
        }),
        isTrue,
      );

      expect(events, [
        isA<FolderDragEntered>()
            .having((event) => event.viewId, 'viewId', 1)
            .having((event) => event.position, 'position', const Offset(10, 20))
            .having((event) => event.paths, 'paths', ['/a', '/b']),
        isA<FolderDragUpdated>()
            .having((event) => event.viewId, 'viewId', 1)
            .having((event) => event.position, 'position', const Offset(11, 21)),
        isA<FolderDragExited>().having((event) => event.viewId, 'viewId', 1),
        isA<FolderDropped>()
            .having((event) => event.viewId, 'viewId', 2)
            .having((event) => event.position, 'position', const Offset(12, 22))
            .having((event) => event.paths, 'paths', ['/c']),
      ]);
    });

    test('malformed native calls answer with a bad-args error', () async {
      shell.setFolderDragHandler((_) => true);
      final Matcher badArgs = throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'bad-args'));
      await expectLater(nativeCall('dragUpdated', {'viewId': 1, 'x': 'left', 'y': 2.0}), badArgs);
      await expectLater(
        nativeCall('dragEntered', {'viewId': 1, 'x': 1.0, 'y': 2.0, 'paths': <String>[]}),
        badArgs,
      );
      await expectLater(nativeCall('dragWiggled', {'viewId': 1}), badArgs);
    });

    test('clearing the handler stops answering native calls', () async {
      shell
        ..setFolderDragHandler((_) => true)
        ..setFolderDragHandler(null);
      expect(
        await messenger().handlePlatformMessage(
          folderChannel.name,
          codec.encodeMethodCall(const MethodCall('dragExited', {'viewId': 1})),
          null,
        ),
        isNull,
      );
    });
  });

  group('window chrome', () {
    const chromeChannel = MethodChannel('zanshin_shell/window_chrome');
    const codec = StandardMethodCodec();
    final chromeLog = <MethodCall>[];
    Object? watchAnswer;

    TestDefaultBinaryMessenger messenger() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    /// Delivers a native window chrome call to Dart and decodes the reply.
    Future<Object?> nativeCall(String method, Object? arguments) => messenger()
        .handlePlatformMessage(chromeChannel.name, codec.encodeMethodCall(MethodCall(method, arguments)), null)
        .then((reply) => codec.decodeEnvelope(reply!));

    setUp(() {
      chromeLog.clear();
      watchAnswer = <String, Object?>{'fullScreen': false};
      messenger().setMockMethodCallHandler(chromeChannel, (call) async {
        chromeLog.add(call);
        return call.method == 'watch' ? watchAnswer : null;
      });
    });

    tearDown(() {
      messenger().setMockMethodCallHandler(chromeChannel, null);
    });

    test('watchWindowChrome and unwatchWindowChrome send the view id', () async {
      await shell.watchWindowChrome(7);
      await shell.unwatchWindowChrome(7);
      expect(chromeLog.map((call) => call.method), ['watch', 'unwatch']);
      expect(chromeLog.map((call) => call.arguments), [
        {'viewId': 7},
        {'viewId': 7},
      ]);
    });

    test('a watch answer decodes with and without the traffic-light block', () async {
      watchAnswer = <String, Object?>{
        'fullScreen': false,
        'trafficLights': <String, Object?>{'x': 19.0, 'y': 19.0, 'width': 60.0, 'height': 14.0},
      };
      expect(
        await shell.watchWindowChrome(1),
        const WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14)),
      );
      watchAnswer = <String, Object?>{'fullScreen': true};
      expect(await shell.watchWindowChrome(1), const WindowChrome(fullScreen: true));
    });

    test('a malformed watch answer fails with bad-args', () async {
      final Matcher badArgs = throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'bad-args'));
      watchAnswer = null;
      await expectLater(shell.watchWindowChrome(1), badArgs);
      watchAnswer = <String, Object?>{
        'fullScreen': false,
        'trafficLights': <String, Object?>{'x': 19.0, 'y': 19.0},
      };
      await expectLater(shell.watchWindowChrome(1), badArgs);
    });

    test('pushed changes reach the stream with their view id', () async {
      final changes = <WindowChromeChange>[];
      final StreamSubscription<WindowChromeChange> subscription = shell.onWindowChromeChanged.listen(changes.add);
      addTearDown(subscription.cancel);

      expect(
        await nativeCall('changed', <String, Object?>{
          'viewId': 3,
          'fullScreen': false,
          'trafficLights': <String, Object?>{'x': 20.0, 'y': 20.0, 'width': 60.0, 'height': 14.0},
        }),
        isNull,
      );
      expect(await nativeCall('changed', <String, Object?>{'viewId': 4, 'fullScreen': true}), isNull);
      await pumpEventQueue();

      expect(changes, [
        (viewId: 3, chrome: const WindowChrome(trafficLights: Rect.fromLTWH(20, 20, 60, 14))),
        (viewId: 4, chrome: const WindowChrome(fullScreen: true)),
      ]);
    });

    test('malformed pushes answer with a bad-args error', () async {
      final StreamSubscription<WindowChromeChange> subscription = shell.onWindowChromeChanged.listen((_) {});
      addTearDown(subscription.cancel);
      final Matcher badArgs = throwsA(isA<PlatformException>().having((error) => error.code, 'code', 'bad-args'));
      await expectLater(nativeCall('changed', <String, Object?>{'fullScreen': false}), badArgs);
      await expectLater(nativeCall('changed', <String, Object?>{'viewId': 1, 'fullScreen': 'no'}), badArgs);
      await expectLater(
        nativeCall('changed', <String, Object?>{'viewId': 1, 'fullScreen': false, 'trafficLights': 'top left'}),
        badArgs,
      );
      await expectLater(nativeCall('resized', <String, Object?>{'viewId': 1, 'fullScreen': false}), badArgs);
    });
  });
}
