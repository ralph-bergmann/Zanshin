// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/settings_window_sizer.dart';

/// A follower over a recorded window: every size and constraints it asks for.
class _Window {
  _Window({this.zoom = 1});

  final double zoom;
  final sizes = <Size>[];
  final constraints = <BoxConstraints>[];
  late final follower = SettingsHeightFollower(setSize: sizes.add, setConstraints: constraints.add, zoom: zoom);
}

void main() {
  group('SettingsHeightFollower', () {
    test('nothing happens before the first frame; then the minimum is set and the height follows the content', () {
      final window = _Window();
      addTearDown(window.follower.dispose);

      window.follower.contentHeight(530);
      expect(window.sizes, isEmpty, reason: 'no window size yet');
      expect(window.follower.ready, isFalse);

      window.follower.windowSized(const Size(620, 520));
      expect(window.constraints, <BoxConstraints>[const BoxConstraints(minWidth: 620, minHeight: 420)]);
      expect(window.sizes, <Size>[const Size(620, 530)], reason: 'the content measured meanwhile');

      window.follower.windowSized(const Size(620, 530));
      window.follower.contentHeight(900);
      window.follower.windowSized(const Size(620, 740));
      window.follower.contentHeight(300);
      window.follower.windowSized(const Size(620, 420));
      window.follower.contentHeight(300.4);
      expect(window.sizes, <Size>[const Size(620, 530), const Size(620, 740), const Size(620, 420)]);
      expect(window.follower.following, isTrue);
    });

    test('a first frame below the minimum is lifted to it without reading as a resize', () {
      final window = _Window();
      addTearDown(window.follower.dispose);

      window.follower.windowSized(const Size(620, 380));
      expect(window.sizes, <Size>[const Size(620, 420)]);
      window.follower.windowSized(const Size(620, 420));
      expect(window.follower.following, isTrue);
    });

    test('a size it did not ask for is the user: it stops following for good and notifies once', () {
      final window = _Window();
      addTearDown(window.follower.dispose);
      var notified = 0;
      window.follower.addListener(() => notified++);
      window.follower
        ..windowSized(const Size(620, 600))
        ..windowSized(const Size(700, 640));

      expect(window.follower.following, isFalse);
      expect(notified, 1);

      window.follower
        ..contentHeight(500)
        ..windowSized(const Size(800, 700));
      expect(window.sizes, isEmpty, reason: 'the size is kept');
      expect(notified, 1);
    });

    test('at zoom 125 the minimum is 775 × 525, the cap 925 and the content height × 1.25 (Story 11.20)', () {
      final window = _Window(zoom: 1.25);
      addTearDown(window.follower.dispose);

      window.follower.windowSized(const Size(775, 600));
      expect(window.constraints, <BoxConstraints>[const BoxConstraints(minWidth: 775, minHeight: 525)]);
      window.follower.contentHeight(500);
      expect(window.sizes, <Size>[const Size(775, 625)]);
      window.follower
        ..windowSized(const Size(775, 625))
        ..contentHeight(900);
      expect(window.sizes.last, const Size(775, 925), reason: 'capped at 740 × 1.25');
      expect(window.follower.following, isTrue);
    });

    test('a zoom change while following scales the width and the height; the size it causes is not a resize', () {
      final window = _Window();
      addTearDown(window.follower.dispose);
      window.follower
        ..windowSized(const Size(620, 500))
        ..contentHeight(500)
        ..windowSized(const Size(620, 500));
      expect(window.sizes, isEmpty);

      window.follower.zoom = 1.25;
      expect(window.constraints.last, const BoxConstraints(minWidth: 775, minHeight: 525));
      expect(window.sizes.last, const Size(775, 625));
      window.follower.windowSized(const Size(775, 625));
      expect(window.follower.following, isTrue);

      window.follower.zoom = .9;
      expect(window.constraints.last, const BoxConstraints(minWidth: 558, minHeight: 378));
      expect(window.sizes.last, const Size(558, 450));
      window.follower.windowSized(const Size(558, 450));
      expect(window.follower.following, isTrue);
    });

    test('a zoom change after a resize keeps the frame, growing it only to a larger minimum', () {
      final window = _Window();
      addTearDown(window.follower.dispose);
      window.follower
        ..windowSized(const Size(620, 500))
        ..windowSized(const Size(700, 450));
      expect(window.follower.following, isFalse);

      window.follower.zoom = 1.25;
      expect(window.constraints.last, const BoxConstraints(minWidth: 775, minHeight: 525));
      expect(window.sizes.last, const Size(775, 525), reason: 'grown to the zoomed minimum');
      window.follower.windowSized(const Size(775, 525));
      final int asked = window.sizes.length;
      window.follower.zoom = 1;
      expect(window.sizes, hasLength(asked), reason: 'a larger frame is kept');
    });
  });

  group('NaturalHeight', () {
    testWidgets("reports the child's natural height under the width, capped, and lays it out to the constraints", (
      tester,
    ) async {
      final heights = <double>[];
      var content = 300.0;
      late StateSetter setContent;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: SizedBox(
              width: 620,
              height: 500,
              child: NaturalHeight(
                onHeight: heights.add,
                child: StatefulBuilder(
                  builder: (context, setState) {
                    setContent = setState;
                    return SizedBox(height: content);
                  },
                ),
              ),
            ),
          ),
        ),
      );

      expect(heights, <double>[300]);
      expect(tester.getSize(find.byType(NaturalHeight)), const Size(620, 500), reason: 'laid out to the constraints');

      setContent(() => content = 1000);
      await tester.pump();
      expect(heights, <double>[300, 740], reason: 'capped at the maximum');

      setContent(() => content = 1200);
      await tester.pump();
      expect(heights, <double>[300, 740], reason: 'reported only when it changed');
    });

    testWidgets('without measuring it reports nothing', (tester) async {
      final heights = <double>[];
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: NaturalHeight(onHeight: heights.add, measuring: false, child: const SizedBox(height: 10)),
        ),
      );

      expect(heights, isEmpty);
    });
  });
}
