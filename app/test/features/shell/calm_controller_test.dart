// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/calm_controller.dart';

/// Advances the fake clock by [ms] milliseconds (timers made in a `testWidgets` body run on it).
Future<void> _ms(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

CalmController _calm({bool hideControls = true, bool Function()? pinned}) {
  final controller = CalmController(hideControls: hideControls, decideInspectorPinned: pinned);
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  testWidgets('nothing at 30 px, calm at 31', (tester) async {
    final CalmController calm = _calm()..addUserScroll(30);
    expect(calm.value.calm, isFalse);
    calm.addUserScroll(1);
    expect(calm.value, const CalmPhase(calm: true));
    await _ms(tester, 700);
  });

  testWidgets('calm ends 650 ms after the last counted event; a new event restarts the wait', (tester) async {
    final CalmController calm = _calm();
    final phases = <CalmPhase>[];
    calm
      ..addListener(() => phases.add(calm.value))
      ..addUserScroll(31);
    await _ms(tester, 600);
    calm.addUserScroll(2);
    await _ms(tester, 649);
    expect(calm.value.calm, isTrue);
    await _ms(tester, 1);
    expect(calm.value, CalmPhase.rest);
    expect(phases, <CalmPhase>[const CalmPhase(calm: true), CalmPhase.rest]);
  });

  testWidgets('the sum starts again when the wait runs out without a phase', (tester) async {
    final CalmController calm = _calm()..addUserScroll(20);
    await _ms(tester, 650);
    calm.addUserScroll(20);
    expect(calm.value.calm, isFalse, reason: '20 + 20 across two waits never reaches the threshold');
    await _ms(tester, 650);
  });

  testWidgets('a hold blocks counting; a hold taken during a phase ends it at once', (tester) async {
    final CalmController calm = _calm();
    final CalmHold hold = calm.hold();
    expect(calm.held, isTrue);
    calm.addUserScroll(100);
    expect(calm.value.calm, isFalse);
    hold
      ..release()
      ..release();
    expect(calm.held, isFalse);
    calm.addUserScroll(31);
    expect(calm.value.calm, isTrue);
    final phases = <CalmPhase>[];
    calm.addListener(() => phases.add(calm.value));
    final CalmHold during = calm.hold();
    expect(calm.value, CalmPhase.rest);
    expect(phases, <CalmPhase>[CalmPhase.rest]);
    calm.addUserScroll(50);
    expect(calm.value.calm, isFalse, reason: 'the held event is not counted');
    await _ms(tester, 650);
    expect(phases, <CalmPhase>[CalmPhase.rest], reason: 'the cancelled wait does not fire');
    during.release();
    expect(during.released, isTrue);
    calm.addUserScroll(31);
    expect(calm.value.calm, isTrue, reason: 'counting resumes once released');
    await _ms(tester, 650);
  });

  testWidgets('a hold outside a phase keeps the scroll counted so far', (tester) async {
    final CalmController calm = _calm()..addUserScroll(20);
    calm.hold().release();
    calm.addUserScroll(15);
    expect(calm.value.calm, isTrue);
    await _ms(tester, 650);
  });

  testWidgets('Hide controls off ignores scrolling; switching it off ends a phase', (tester) async {
    final CalmController calm = _calm(hideControls: false)..addUserScroll(100);
    expect(calm.value.calm, isFalse);
    calm
      ..hideControls = true
      ..addUserScroll(31);
    expect(calm.value.calm, isTrue);
    calm.hideControls = false;
    expect(calm.value, CalmPhase.rest);
    expect(calm.hideControls, isFalse);
  });

  testWidgets('the inspector pin is decided once, at the phase start', (tester) async {
    var typing = true;
    var asked = 0;
    final CalmController calm = _calm(
      pinned: () {
        asked++;
        return typing;
      },
    )..addUserScroll(31);
    expect(calm.value, const CalmPhase(calm: true, inspectorPinned: true));
    typing = false;
    calm.addUserScroll(40);
    expect(calm.value.inspectorPinned, isTrue, reason: 'focus leaving mid-phase changes nothing');
    expect(asked, 1);
    await _ms(tester, 650);
  });

  test('a phase prints its flags', () {
    expect(const CalmPhase(calm: true).toString(), 'CalmPhase(calm: true, inspectorPinned: false)');
    expect(const CalmPhase(calm: true).hashCode, const CalmPhase(calm: true).hashCode);
  });
}
