// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';

import 'zanshin_shell_test.dart' show RecordingPlatform;

void main() {
  late RecordingPlatform platform;

  setUp(() {
    platform = RecordingPlatform();
    ZanshinShellPlatform.instance = platform;
  });

  Widget harness(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('pan start triggers a native window drag', (tester) async {
    await tester.pumpWidget(
      harness(const WindowDragArea(child: SizedBox(width: 300, height: 44))),
    );
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.byType(WindowDragArea)),
    );
    await gesture.moveBy(const Offset(30, 0));
    await gesture.up();
    // The double-tap recognizer arms a timer on the first tap-down; advance
    // past its window so no timer outlives the widget tree.
    await tester.pump(kDoubleTapTimeout);
    expect(platform.calls, ['startWindowDrag']);
  });

  testWidgets('double tap performs the titlebar double-click action', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(const WindowDragArea(child: SizedBox(width: 300, height: 44))),
    );
    await tester.tap(find.byType(WindowDragArea));
    await tester.pump(kDoubleTapMinTime);
    await tester.tap(find.byType(WindowDragArea));
    await tester.pumpAndSettle();
    expect(platform.calls, ['performTitlebarDoubleClickAction']);
  });

  testWidgets('preferredSize delegates to a PreferredSizeWidget child', (
    tester,
  ) async {
    const area = WindowDragArea(
      child: PreferredSize(
        preferredSize: Size.fromHeight(44),
        child: SizedBox(),
      ),
    );
    expect(area.preferredSize, const Size.fromHeight(44));
    const plain = WindowDragArea(child: SizedBox());
    // The package keeps its own 56 (no Material import); it must stay Material's toolbar height.
    expect(plain.preferredSize, const Size.fromHeight(56));
    expect(plain.preferredSize, const Size.fromHeight(kToolbarHeight));
  });
}
