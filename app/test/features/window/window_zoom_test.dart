// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/window_zoom.dart';
import 'package:zanshin_settings/zanshin_settings.dart';

import '../../helpers/fake_windows.dart';

void main() {
  test('the steps, the snap (a tie goes to the lower step) and the moves, which stop at the ends', () {
    expect(zoomSteps, <int>[90, 100, 110, 125, 150]);
    expect(
      <int>[
        for (final p in <int>[50, 90, 95, 104, 105, 117, 118, 137, 200]) zoomStepOf(p),
      ],
      <int>[
        90,
        90,
        90,
        100,
        100,
        110,
        125,
        125,
        150,
      ],
    );
    expect(zoomInFrom(100), 110);
    expect(zoomInFrom(150), 150);
    expect(zoomOutFrom(100), 90);
    expect(zoomOutFrom(90), 90);
    expect(zoomInFrom(95), 100, reason: 'from the snapped step');
    expect(zoomScaleOf(125), 1.25);
  });

  testWidgets('the box lays its child out at the constraints ÷ zoom and draws and hit-tests it scaled', (tester) async {
    final taps = <Offset>[];
    late Size laidOut;
    await tester.pumpWidget(
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 500,
          height: 400,
          child: WindowZoomBox(
            scale: 1.25,
            child: LayoutBuilder(
              builder: (context, constraints) {
                laidOut = constraints.biggest;
                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (details) => taps.add(details.localPosition),
                  child: const SizedBox.expand(),
                );
              },
            ),
          ),
        ),
      ),
    );

    expect(laidOut, const Size(400, 320));
    expect(tester.getSize(find.byType(WindowZoomBox)), const Size(500, 400));
    expect(tester.getRect(find.byType(GestureDetector)), const Rect.fromLTWH(0, 0, 500, 400), reason: 'drawn scaled');
    await tester.tapAt(const Offset(250, 125));
    expect(taps, <Offset>[const Offset(200, 100)]);
    final RenderBox inner = tester.renderObject(find.byType(GestureDetector));
    expect(inner.localToGlobal(const Offset(40, 40)), const Offset(50, 50));
  });

  testWidgets('a content-sized child: the box reports the child size × zoom', (tester) async {
    await tester.pumpWidget(
      const Align(
        alignment: Alignment.topLeft,
        child: WindowZoomBox(scale: 1.5, child: SizedBox(width: 200, height: 100)),
      ),
    );
    expect(tester.getSize(find.byType(WindowZoomBox)), const Size(300, 150));
  });

  testWidgets('zoomedMediaQuery divides the size and insets and multiplies the device pixel ratio', (tester) async {
    const data = MediaQueryData(
      size: Size(1000, 500),
      padding: EdgeInsets.all(10),
      viewPadding: EdgeInsets.all(20),
      viewInsets: EdgeInsets.only(bottom: 40),
      devicePixelRatio: 2,
    );
    final MediaQueryData zoomed = zoomedMediaQuery(data, 1.25);
    expect(zoomed.size, const Size(800, 400));
    expect(zoomed.padding, const EdgeInsets.all(8));
    expect(zoomed.viewPadding, const EdgeInsets.all(16));
    expect(zoomed.viewInsets, const EdgeInsets.only(bottom: 32));
    expect(zoomed.devicePixelRatio, 2.5);
    expect(zoomedMediaQuery(data, 1), same(data));
  });

  group('bindWindowZoom', () {
    late bool windowingWasEnabled;
    setUp(() {
      windowingWasEnabled = isWindowingEnabled;
      isWindowingEnabled = true;
    });
    tearDown(() => isWindowingEnabled = windowingWasEnabled);

    testWidgets('sets the windows\' zoom from the settings now and on every change, until disposed', (tester) async {
      final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('window_zoom_test')))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final SettingsStore store = (await tester.runAsync(() async {
        final file = File('${dir.path}/settings.json');
        await file.writeAsString('{"appearance": {"zoom": 95}}');
        return SettingsStore.load(file);
      }))!;
      final windows = AppWindows(createController: FakeWindowFactory().call, exitProcess: () async {})
        ..attach(WindowRegistry());
      final VoidCallback dispose = bindWindowZoom(store, windows);
      expect(windows.zoom, .9, reason: 'a stored 95 is 90');

      await tester.runAsync(() => store.update((s) => s.copyWith.appearance(zoom: 125)));
      expect(windows.zoom, 1.25);

      dispose();
      await tester.runAsync(() => store.update((s) => s.copyWith.appearance(zoom: 150)));
      expect(windows.zoom, 1.25);
    });

    testWidgets('⌘= zooms in with nothing focused; ⇧⌘= does not; after dispose ⌘= does nothing', (tester) async {
      final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('window_zoom_test')))!;
      addTearDown(() => dir.deleteSync(recursive: true));
      final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/s.json'))))!;
      final windows = AppWindows(createController: FakeWindowFactory().call, exitProcess: () async {})
        ..attach(WindowRegistry());
      final VoidCallback dispose = bindWindowZoom(store, windows);
      await tester.pumpWidget(const SizedBox());
      expect(
        FocusManager.instance.primaryFocus,
        anyOf(isNull, same(FocusManager.instance.rootScope)),
        reason: 'nothing focused',
      );

      Future<void> press({bool shift = false}) async {
        await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
        if (shift) {
          await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        }
        await tester.sendKeyEvent(LogicalKeyboardKey.equal);
        if (shift) {
          await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        }
        await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      }

      await press();
      expect(store.value.appearance.zoom, 110);
      await press(shift: true);
      expect(store.value.appearance.zoom, 110);
      dispose();
      await press();
      expect(store.value.appearance.zoom, 110);
    });
  });
}
