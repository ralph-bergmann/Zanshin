// SPDX-License-Identifier: MIT

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

const _place = Key('place');
const _view = Key('view');
const _sync = Key('sync');
const _newChange = Key('new-change');

/// The shell with demo slots of max-content 200 (PLACE), 500 (VIEW: 490 inside the island's padding and border) and
/// 238 (ACTION: 115 + 8 + 115).
Widget _shell(ShellController controller, {ZsAppearance appearance = const ZsAppearance()}) => shellHost(
  FloatingShell(
    controller: controller,
    projectCapsule: const SizedBox(key: _place, width: 200, height: 44),
    view: const SizedBox(key: _view, width: 490, height: 20),
    syncGroup: const SizedBox(key: _sync, width: 115, height: 44),
    newChange: const SizedBox(key: _newChange, width: 115, height: 44),
  ),
  appearance: appearance,
);

Rect _viewIsland(WidgetTester tester) =>
    tester.getRect(find.ancestor(of: find.byKey(_view), matching: find.byType(ZsIsland)).first);

ShellController _controller() {
  final controller = ShellController();
  addTearDown(controller.dispose);
  return controller;
}

void main() {
  setUpIconRegistry();

  for (final (double width, double viewWidth) in const <(double, double)>[
    (1440, 500),
    (1100, 500),
    (1000, 435),
    (920, 355),
    (880, 315),
  ]) {
    testWidgets('at $width px the bar lays out Place · View · Action with VIEW $viewWidth wide', (tester) async {
      useShellWindow(tester, Size(width, 900));
      await tester.pumpWidget(_shell(_controller()));

      final Rect place = tester.getRect(find.byKey(_place));
      final Rect view = _viewIsland(tester);
      final Rect action = tester.getRect(find.byKey(_sync)).expandToInclude(tester.getRect(find.byKey(_newChange)));
      expect(place.top, 4);
      expect(place.left, 91);
      expect(place.width, 200, reason: 'PLACE keeps its width');
      expect(action.right, width - 12);
      expect(action.width, 238, reason: 'ACTION keeps its width');
      expect(tester.getRect(find.byKey(_newChange)).left - tester.getRect(find.byKey(_sync)).right, 8);
      expect(view.width, viewWidth);
      expect(view.top, 4);
      expect(view.left - place.right, greaterThanOrEqualTo(12));
      expect(action.left - view.right, greaterThanOrEqualTo(12));
      // VIEW is centred in its track, which the two max-content-or-1fr tracks frame (CSS grid).
      final double box = width - 91 - 12;
      final double col2 = math.min(box - 24 - 200 - 238, 500);
      final double s = box - 24 - col2;
      final double col1 = 238 > s / 2 ? s - 238 : math.max(200, s / 2);
      expect(view.left, 91 + col1 + 12 + (col2 - view.width) / 2);
      if (viewWidth < 500) {
        expect(view.left - place.right, 12, reason: 'the islands are 12 apart once VIEW gives way');
        expect(action.left - view.right, 12);
      }
    });
  }

  testWidgets('in full screen the bar starts at 12 and its top is 12', (tester) async {
    useShellWindow(tester);
    await tester.pumpWidget(_shell(_controller(), appearance: const ZsAppearance(fullScreen: true)));
    expect(tester.getRect(find.byKey(_place)).topLeft, const Offset(12, 12));
    expect(_viewIsland(tester).top, 12);
  });

  testWidgets('sides wider than the bar overflow to the right without an exception', (tester) async {
    useShellWindow(tester, const Size(480, 600));
    await tester.pumpWidget(_shell(_controller()));
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byKey(_sync)).left, 91 + 200 + 24);
  });

  testWidgets('empty slots show empty 44 × 44 islands that VoiceOver skips', (tester) async {
    useShellWindow(tester);
    await tester.pumpWidget(shellHost(FloatingShell(controller: _controller())));
    final Finder empty = find.byType(ShellEmptyIsland);
    expect(empty, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      expect(tester.getSize(empty.at(i)), const Size.square(44));
    }
    expect(find.descendant(of: empty.first, matching: find.byType(ExcludeSemantics)), findsWidgets);
  });

  testWidgets('the View island is a labelled group around its content', (tester) async {
    useShellWindow(tester);
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_shell(_controller()));
    expect(find.bySemanticsLabel('View'), findsOneWidget);
    handle.dispose();
  });
}
