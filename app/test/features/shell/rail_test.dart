// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail_preview.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

Finder _button(String id) =>
    find.byWidgetPredicate((widget) => widget is ZsIconButton && widget.identifier == 'rail-$id');

ZsIconButton _buttonOf(WidgetTester tester, String id) => tester.widget<ZsIconButton>(_button(id));

Finder get _preview => find.byType(RailPreview);

Future<void> _ms(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

Future<ShellController> _pump(WidgetTester tester, {ZsAppearance appearance = const ZsAppearance()}) async {
  useShellWindow(tester);
  final controller = ShellController();
  addTearDown(controller.dispose);
  await tester.pumpWidget(
    shellHost(
      FloatingShell(controller: controller, railItems: demoRailItems),
      appearance: appearance,
    ),
  );
  return controller;
}

/// A mouse resting in the empty middle of the window.
Future<TestGesture> _mouse(WidgetTester tester) async {
  final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: const Offset(700, 500));
  addTearDown(mouse.removePointer);
  await tester.pump();
  return mouse;
}

void main() {
  setUpIconRegistry();
  setUp(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional);
  tearDown(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic);

  testWidgets('the rail is a 52 wide rail island at (12, 60), its buttons 40 wide with no tooltip', (tester) async {
    await _pump(tester);
    final Rect rail = tester.getRect(
      find.byWidgetPredicate((widget) => widget is ZsIsland && widget.shape == ZsIslandShape.rail),
    );
    expect(rail.topLeft, const Offset(12, 60));
    expect(rail.width, 52);
    expect(tester.getSize(_button('bookmarks')), const Size.square(40));
    expect(find.byType(ZsTooltip), findsNothing);
    expect(_buttonOf(tester, 'bookmarks').size, ZsIconButtonSize.lg);
  });

  testWidgets('a preview opens 90 ms into a hover (not at 89) at x 76, its arrow on the button, 290 wide', (
    tester,
  ) async {
    await _pump(tester);
    final TestGesture mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_button('bookmarks')));
    await _ms(tester, 89);
    expect(_preview, findsNothing);
    await _ms(tester, 1);
    expect(_preview, findsOneWidget);
    await tester.pumpAndSettle();
    final Rect callout = tester.getRect(find.descendant(of: _preview, matching: find.byType(ZsMenuMaterial)));
    expect(callout.left, 76);
    expect(callout.width, 290);
    expect(callout.top + 22, tester.getCenter(_button('bookmarks')).dy, reason: 'the arrow tip is 22 below the top');
    final Finder header = find.descendant(of: _preview, matching: find.byType(ZanshinIcon));
    expect(tester.widget<ZanshinIcon>(header).name, ZI.branch);
    expect(tester.widget<ZanshinIcon>(header).size, ZsIconSize.md);
    expect(find.descendant(of: _preview, matching: find.text('Bookmarks')), findsOneWidget);
    expect(find.descendant(of: _preview, matching: find.text('3')), findsOneWidget);
  });

  testWidgets('moving to the other button switches at once; leaving both closes it 200 ms later', (tester) async {
    await _pump(tester);
    final TestGesture mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_button('bookmarks')));
    await _ms(tester, 90);
    await mouse.moveTo(tester.getCenter(_button('undo')));
    await tester.pump();
    expect(tester.widget<RailPreview>(_preview).item.id, 'undo');
    final double undoCentre = tester.getCenter(_button('undo')).dy;
    await tester.pumpAndSettle();
    expect(tester.getRect(find.descendant(of: _preview, matching: find.byType(ZsMenuMaterial))).top + 22, undoCentre);
    await mouse.moveTo(const Offset(700, 500));
    await _ms(tester, 199);
    expect(tester.widget<RailPreview>(_preview).closing, isFalse);
    await _ms(tester, 1);
    expect(tester.widget<RailPreview>(_preview).closing, isTrue);
    await tester.pumpAndSettle();
    expect(_preview, findsNothing);
  });

  testWidgets('entering the preview cancels its close', (tester) async {
    await _pump(tester);
    final TestGesture mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_button('bookmarks')));
    await _ms(tester, 90);
    await tester.pumpAndSettle();
    await mouse.moveTo(tester.getCenter(find.descendant(of: _preview, matching: find.byType(ZsMenuMaterial))));
    await _ms(tester, 400);
    expect(tester.widget<RailPreview>(_preview).closing, isFalse);
    await mouse.moveTo(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(_preview, findsNothing);
  });

  testWidgets('a click pins (active, panel shown, preview closed), another moves the pin, the pinned one unpins', (
    tester,
  ) async {
    final ShellController controller = await _pump(tester);
    final TestGesture mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_button('bookmarks')));
    await _ms(tester, 90);
    await tester.tap(_button('bookmarks'));
    await tester.pumpAndSettle();
    expect(_buttonOf(tester, 'bookmarks').active, isTrue);
    expect(find.byType(PinnedPanel), findsOneWidget);
    expect(_preview, findsNothing);
    await mouse.moveTo(tester.getCenter(_button('undo')));
    await mouse.moveTo(tester.getCenter(_button('bookmarks')));
    await _ms(tester, 300);
    expect(_preview, findsNothing, reason: 'the pinned item shows no preview');
    await tester.tap(_button('undo'));
    await tester.pumpAndSettle();
    expect(controller.pinnedId, 'undo');
    expect(_buttonOf(tester, 'bookmarks').active, isFalse);
    expect(_buttonOf(tester, 'undo').active, isTrue);
    await tester.tap(_button('undo'));
    await tester.pumpAndSettle();
    expect(controller.pinnedId, isNull);
    expect(find.byType(PinnedPanel), findsNothing);
  });

  testWidgets('Tab reaches each button with its ring inside and opens no preview; ↩ and Space toggle the pin', (
    tester,
  ) async {
    final ShellController controller = await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final Finder ring = find.descendant(of: _button('bookmarks'), matching: find.byType(ZsFocusRing));
    expect(tester.widget<ZsFocusRing>(ring).visible, isTrue);
    expect(tester.widget<ZsFocusRing>(ring).placement, ZsRingPlacement.inside);
    await _ms(tester, 300);
    expect(_preview, findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.pinnedId, 'bookmarks');
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(controller.pinnedId, isNull);
    await tester.pumpAndSettle();
  });

  testWidgets('VoiceOver: the rail is the group Panels, the pinned panel a live region, the preview is not read', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final ShellController controller = await _pump(tester);
    expect(find.bySemanticsLabel('Panels'), findsOneWidget);
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('rail-bookmarks')),
      isSemantics(label: 'Bookmarks', isButton: true),
    );
    final TestGesture mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_button('undo')));
    await _ms(tester, 90);
    await tester.pumpAndSettle();
    expect(find.descendant(of: _preview, matching: find.text('jj new · jj squash')), findsOneWidget);
    expect(find.bySemanticsLabel('jj new · jj squash'), findsNothing);
    controller.activate('bookmarks');
    await tester.pumpAndSettle();
    expect(tester.getSemantics(find.byType(PinnedPanel)), isSemantics(label: 'Bookmarks', isLiveRegion: true));
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('rail-bookmarks')),
      isSemantics(label: 'Bookmarks', isButton: true, hasToggledState: true, isToggled: true),
    );
    handle.dispose();
  });

  testWidgets('an inactive window opens no preview; an open one closes when the window turns inactive', (
    tester,
  ) async {
    useShellWindow(tester);
    final controller = ShellController();
    addTearDown(controller.dispose);
    Widget shell({required bool inactive}) => shellHost(
      FloatingShell(controller: controller, railItems: demoRailItems),
      appearance: ZsAppearance(inactive: inactive),
    );
    await tester.pumpWidget(shell(inactive: true));
    final TestGesture mouse = await _mouse(tester);
    await mouse.moveTo(tester.getCenter(_button('bookmarks')));
    await _ms(tester, 300);
    expect(_preview, findsNothing);
    await tester.pumpWidget(shell(inactive: false));
    await mouse.moveTo(tester.getCenter(_button('undo')));
    await _ms(tester, 90);
    expect(_preview, findsOneWidget);
    await tester.pumpWidget(shell(inactive: true));
    await tester.pumpAndSettle();
    expect(_preview, findsNothing);
  });

  testWidgets('without items there is no rail island', (tester) async {
    useShellWindow(tester);
    final controller = ShellController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(shellHost(FloatingShell(controller: controller)));
    expect(find.bySemanticsLabel('Panels'), findsNothing);
    expect(find.byWidgetPredicate((widget) => widget is ZsIsland && widget.shape == ZsIslandShape.rail), findsNothing);
  });
}
