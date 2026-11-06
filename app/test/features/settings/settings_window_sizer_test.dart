// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/settings/settings_window_sizer.dart';

/// A follower over a recorded window: every size and constraints it asks for.
class _Window {
  final sizes = <Size>[];
  final constraints = <BoxConstraints>[];
  late final follower = SettingsHeightFollower(setSize: sizes.add, setConstraints: constraints.add);
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
