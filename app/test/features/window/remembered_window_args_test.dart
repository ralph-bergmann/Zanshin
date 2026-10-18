// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/remembered_window_controller.dart';

void main() {
  test("the project window's restore: the main chrome, the full frame, the normal level", () {
    expect(
      restoreArguments(
        window: 42,
        key: 'main',
        chrome: WindowChromeKind.main,
        frame: WindowFrameMode.full,
        level: WindowLevel.normal,
      ),
      <String, Object>{'window': 42, 'key': 'main', 'chrome': 'main', 'frame': 'full', 'level': 'normal'},
    );
  });

  test("a dialog window's restore names the secondary chrome, the position-only frame and the floating level", () {
    expect(
      restoreArguments(
        window: 7,
        key: 'settings',
        chrome: WindowChromeKind.secondary,
        frame: WindowFrameMode.position,
        level: WindowLevel.normal,
      ),
      <String, Object>{'window': 7, 'key': 'settings', 'chrome': 'secondary', 'frame': 'position', 'level': 'normal'},
    );
    expect(
      restoreArguments(
        window: 8,
        key: 'revset-configs',
        chrome: WindowChromeKind.secondary,
        frame: WindowFrameMode.full,
        level: WindowLevel.floatingWhileActive,
      )['level'],
      'floating',
    );
  });

  test('every value is one of the names the runner parses (WindowFrameStore.swift)', () {
    // `flutter test` runs in `app/`.
    final String swift = File('macos/Runner/WindowFrameStore.swift').readAsStringSync();
    Set<String> casesOf(String swiftEnum) {
      final RegExpMatch body = RegExp('enum $swiftEnum: String \\{([^}]*)\\}').firstMatch(swift)!;
      return <String>{
        for (final RegExpMatch match in RegExp(r'case (\w+)').allMatches(body.group(1)!)) match.group(1)!,
      };
    }

    expect(casesOf('WindowChromeKind'), <String>{
      for (final WindowChromeKind kind in WindowChromeKind.values) kind.name,
    });
    expect(casesOf('WindowFrameMode'), <String>{for (final WindowFrameMode mode in WindowFrameMode.values) mode.name});
    expect(casesOf('WindowLevelMode'), <String>{
      for (final WindowLevel level in WindowLevel.values)
        restoreArguments(
              window: 0,
              key: '',
              chrome: WindowChromeKind.main,
              frame: WindowFrameMode.full,
              level: level,
            )['level']!
            as String,
    });
    expect(swift, contains('FlutterMethodChannel(name: "${windowFramesChannel.name}"'));
  });
}
