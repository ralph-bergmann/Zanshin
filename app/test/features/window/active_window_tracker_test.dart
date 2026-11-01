// SPDX-License-Identifier: MIT

import 'dart:ui' show ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';

ViewFocusEvent _focus(int viewId, ViewFocusState state) =>
    ViewFocusEvent(viewId: viewId, state: state, direction: ViewFocusDirection.undefined);

void main() {
  testWidgets('before any focus event every window is active', (tester) async {
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);

    expect(tracker.isActive(1), isTrue);
    expect(tracker.isActive(2), isTrue);
    expect(tracker.keyView, isNull);
  });

  testWidgets("the binding's focus events reach it: only the focused view is active, a later one takes over", (
    tester,
  ) async {
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);
    var notified = 0;
    tracker.addListener(() => notified++);

    WidgetsBinding.instance.handleViewFocusChanged(_focus(1, ViewFocusState.focused));
    expect((tracker.isActive(1), tracker.isActive(2)), (true, false));

    // AppKit resigns the old key window first, then makes the new one key.
    WidgetsBinding.instance
      ..handleViewFocusChanged(_focus(1, ViewFocusState.unfocused))
      ..handleViewFocusChanged(_focus(2, ViewFocusState.focused));
    expect((tracker.isActive(1), tracker.isActive(2)), (false, true));
    expect(tracker.keyView, 2);
    expect(notified, 3);
  });

  testWidgets('the key view losing focus leaves every window inactive; another view losing it changes nothing', (
    tester,
  ) async {
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);
    tracker.didChangeViewFocus(_focus(1, ViewFocusState.focused));
    var notified = 0;
    tracker
      ..addListener(() => notified++)
      ..didChangeViewFocus(_focus(2, ViewFocusState.unfocused));
    expect(tracker.isActive(1), isTrue);
    expect(notified, 0);

    tracker.didChangeViewFocus(_focus(1, ViewFocusState.unfocused));
    expect((tracker.isActive(1), tracker.isActive(2)), (false, false));
    expect(notified, 1);

    tracker.didChangeViewFocus(_focus(1, ViewFocusState.focused));
    expect(tracker.isActive(1), isTrue);
    tracker.didChangeViewFocus(_focus(1, ViewFocusState.focused));
    expect(notified, 2, reason: 'a repeated focus changes nothing');
  });

  testWidgets('a first event that unfocuses a view leaves no window active', (tester) async {
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);

    tracker.didChangeViewFocus(_focus(3, ViewFocusState.unfocused));

    expect((tracker.isActive(3), tracker.isActive(1)), (false, false));
  });

  testWidgets('a disposed tracker hears no more events', (tester) async {
    final tracker = ActiveWindowTracker()..dispose();

    WidgetsBinding.instance.handleViewFocusChanged(_focus(1, ViewFocusState.focused));

    expect(tracker.isActive(2), isTrue, reason: 'still before its first event');
  });
}
