// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/graph_insets.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin/src/features/shell/shell_scope.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

Future<void> _ms(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

Finder _button(String id) =>
    find.byWidgetPredicate((widget) => widget is ZsIconButton && widget.identifier == 'rail-$id');

Finder get _edge => find.byType(ZsResizeEdge);

Finder get _motion => find.byType(ShellPanelMotion);

double _opacity(WidgetTester tester) =>
    tester.widget<ZsFade>(find.descendant(of: _motion, matching: find.byType(ZsFade)).first).opacity;

double _dx(WidgetTester tester) => tester
    .widget<Transform>(find.descendant(of: _motion, matching: find.byType(Transform)).first)
    .transform
    .getTranslation()
    .x;

/// The panel island's rect.
Rect _panel(WidgetTester tester, {String identifier = 'panel'}) => tester.getRect(
  find.descendant(
    of: find.byWidgetPredicate((widget) => widget is PinnedPanel && widget.identifier == identifier),
    matching: find.byType(ZsIsland),
  ),
);

/// The shell's test rig: the demo rail items, a graph slot that records the insets it reads, an inspector slot on
/// request, the committed panel widths in [commits].
class _Rig {
  _Rig() {
    controller = ShellController(onPanelWidthCommitted: commits.add);
  }

  late final ShellController controller;
  final commits = <double>[];
  final insets = <GraphInsets>[];

  Widget shell({bool inspector = false, ZsAppearance appearance = const ZsAppearance()}) => shellHost(
    FloatingShell(
      controller: controller,
      railItems: demoRailItems,
      graph: Builder(
        builder: (context) {
          insets.add(ShellScope.insetsOf(context));
          return const SizedBox.expand();
        },
      ),
      inspector: inspector ? const SizedBox.expand(key: Key('inspector')) : null,
    ),
    appearance: appearance,
  );
}

Future<_Rig> _pump(
  WidgetTester tester, {
  Size window = shellWindow,
  bool inspector = false,
  ZsAppearance appearance = const ZsAppearance(),
}) async {
  useShellWindow(tester, window);
  final rig = _Rig();
  addTearDown(rig.controller.dispose);
  await tester.pumpWidget(rig.shell(inspector: inspector, appearance: appearance));
  return rig;
}

void main() {
  setUpIconRegistry();

  testWidgets('the panel enters over 200 ms: a fade and a slide from −8 px on the glide curve', (tester) async {
    final _Rig rig = await _pump(tester);
    rig.controller.activate('bookmarks');
    await tester.pump();
    expect(_opacity(tester), 0);
    expect(_dx(tester), -8);
    await _ms(tester, 100);
    final double half = ZsMotion.full.easeGlide.transform(.5);
    expect(_opacity(tester), closeTo(half, 1e-6));
    expect(_dx(tester), closeTo(-8 * (1 - half), 1e-6));
    await _ms(tester, 100);
    expect(_opacity(tester), 1);
    expect(_dx(tester), 0);
    expect(_panel(tester), const Rect.fromLTWH(76, 60, 300, 900 - 60 - 12));
    expect(find.descendant(of: find.byType(PinnedPanel), matching: find.text('Bookmarks')), findsOneWidget);
    final TextStyle? title = tester
        .widget<Text>(find.descendant(of: find.byType(PinnedPanel), matching: find.text('Bookmarks')))
        .style;
    expect(title?.fontSize, ZsType.panelTitle.fontSize);
  });

  testWidgets('under reduce motion the panel only fades, on the same timing', (tester) async {
    final _Rig rig = await _pump(tester, appearance: const ZsAppearance(reduceMotion: true));
    rig.controller.activate('bookmarks');
    await tester.pump();
    expect(_dx(tester), 0);
    await _ms(tester, 100);
    expect(_opacity(tester), closeTo(ZsMotion.full.easeGlide.transform(.5), 1e-6));
    expect(_dx(tester), 0);
    await tester.pumpAndSettle();
  });

  testWidgets('its close button unpins; it leaves over 180 ms drifting −8 px; switching the pin replays the entrance', (
    tester,
  ) async {
    final _Rig rig = await _pump(tester);
    rig.controller.activate('bookmarks');
    await tester.pumpAndSettle();
    await tester.tap(find.bySemanticsIdentifier('panel-close'));
    await tester.pump();
    expect(rig.controller.pinnedId, isNull);
    await _ms(tester, 90);
    final double left = ZsMotion.full.easeExit.flipped.transform(.5);
    expect(_opacity(tester), closeTo(left, 1e-6));
    expect(_dx(tester), closeTo(-8 * (1 - left), 1e-6));
    await _ms(tester, 90);
    await tester.pump();
    expect(find.byType(PinnedPanel), findsNothing);

    rig.controller.activate('bookmarks');
    await tester.pumpAndSettle();
    rig.controller.activate('undo');
    await tester.pump();
    expect(_opacity(tester), 0, reason: 'a new panel replaces the old one and enters again');
    await tester.pumpAndSettle();
    expect(find.descendant(of: find.byType(PinnedPanel), matching: find.text('Undo Timeline')), findsOneWidget);
  });

  testWidgets(
    'the edge: the width follows the drag live with the left inset, stops at 440, is stored once on release',
    (tester) async {
      final _Rig rig = await _pump(tester);
      rig.controller.activate('bookmarks');
      await tester.pumpAndSettle();
      expect(tester.getRect(_edge), const Rect.fromLTRB(76 + 300 - 3, 60 + 16, 76 + 300 + 7, 900 - 12 - 16));
      expect(rig.insets.last.left, 76 + 300 + 12);
      final TestGesture drag = await tester.startGesture(tester.getCenter(_edge), kind: PointerDeviceKind.mouse);
      await drag.moveBy(const Offset(25, 0));
      await tester.pump();
      expect(_panel(tester).width, 325);
      expect(rig.insets.last.left, 76 + 325 + 12, reason: 'the inset follows in the same frame');
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.resizeColumn);
      await drag.moveBy(const Offset(500, 0));
      await tester.pump();
      expect(_panel(tester).width, 440);
      expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.resizeLeft);
      expect(rig.commits, isEmpty, reason: 'nothing is stored during the drag');
      await drag.up();
      await tester.pump(const Duration(milliseconds: 500));
      expect(rig.commits, <double>[440]);
      expect(rig.controller.panelWidth, 440);
    },
  );

  testWidgets('with the inspector open the drag stops where 320 px of graph would remain', (tester) async {
    final _Rig rig = await _pump(tester, window: const Size(1250, 900), inspector: true);
    rig.controller.activate('bookmarks');
    await tester.pumpAndSettle();
    final TestGesture drag = await tester.startGesture(tester.getCenter(_edge), kind: PointerDeviceKind.mouse);
    await drag.moveBy(const Offset(300, 0));
    await tester.pump();
    expect(_panel(tester).width, 1250 - 88 - 484 - 320);
    expect(1250 - rig.insets.last.left - rig.insets.last.right, 320);
    await drag.up();
    await tester.pump(const Duration(milliseconds: 500));
  });

  testWidgets('a double-click resets to 300 over 200 ms; VoiceOver reads the edge as Panel width in points', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final _Rig rig = await _pump(tester);
    rig.controller
      ..panelWidth = 400
      ..activate('bookmarks');
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('panel-edge')),
      isSemantics(label: 'Panel width', value: '400 points', isSlider: true),
    );
    await tester.tap(_edge);
    await _ms(tester, 50);
    await tester.tap(_edge);
    await tester.pump();
    await _ms(tester, 100);
    expect(_panel(tester).width, allOf(greaterThan(300), lessThan(400)));
    await _ms(tester, 120);
    expect(_panel(tester).width, 300);
    expect(rig.commits, <double>[300]);
    await tester.pump(const Duration(milliseconds: 500));
    handle.dispose();
  });

  testWidgets('the collapse rule in the window: 1192 · 1112 · 1052, collapsed at 1051 keeping the pin, back at 1112', (
    tester,
  ) async {
    final _Rig rig = await _pump(tester, window: const Size(1192, 900), inspector: true);
    rig.controller.activate('bookmarks');
    await tester.pumpAndSettle();
    for (final (double width, double panel, double inspector) in const <(double, double, double)>[
      (1192, 300, 460),
      (1112, 300, 380),
      (1052, 240, 380),
    ]) {
      useShellWindow(tester, Size(width, 900));
      await tester.pumpAndSettle();
      expect(_panel(tester).width, panel, reason: '$width');
      expect(tester.getSize(find.byKey(const Key('inspector'))).width, inspector, reason: '$width');
    }
    useShellWindow(tester, const Size(1051, 900));
    await tester.pumpAndSettle();
    expect(find.byType(PinnedPanel), findsNothing);
    expect(_edge, findsNothing);
    expect(rig.insets.last.left, 76);
    expect(rig.controller.pinnedId, 'bookmarks');
    expect(tester.widget<ZsIconButton>(_button('bookmarks')).active, isTrue);
    useShellWindow(tester, const Size(1111, 900));
    await tester.pumpAndSettle();
    expect(find.byType(PinnedPanel), findsNothing);
    useShellWindow(tester, const Size(1112, 900));
    await tester.pumpAndSettle();
    expect(_panel(tester).width, 300);
    expect(rig.controller.panelWidth, 300, reason: 'a narrow window never changes the stored width');
    expect(rig.commits, isEmpty);
  });

  testWidgets(
    'at 1000 px a click on an unpinned item shows the flyout; Esc and a click outside close it, the pin stays',
    (tester) async {
      final _Rig rig = await _pump(tester, window: const Size(1000, 900), inspector: true);
      rig.controller.activate('undo');
      await tester.pumpAndSettle();
      expect(rig.controller.flyoutOpen, isTrue, reason: 'a pin without room shows as the flyout');
      rig.controller.closeFlyout();
      await tester.pumpAndSettle();
      expect(find.byType(PinnedPanel), findsNothing);
      final GraphInsets before = rig.insets.last;

      await tester.tap(_button('bookmarks'));
      await tester.pumpAndSettle();
      expect(rig.controller.pinnedId, 'bookmarks');
      expect(_panel(tester, identifier: 'flyout'), const Rect.fromLTWH(76, 60, 300, 900 - 72));
      expect(rig.insets.last, before, reason: 'the flyout changes no inset');
      expect(_edge, findsNothing);
      expect(
        find.ancestor(
          of: find.byWidgetPredicate((widget) => widget is PinnedPanel && widget.identifier == 'flyout'),
          matching: find.byType(BackdropGroup),
        ),
        findsNWidgets(2),
        reason: 'a backdrop group of its own inside the window group',
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(PinnedPanel), findsNothing);
      expect(rig.controller.pinnedId, 'bookmarks');

      await tester.tap(_button('bookmarks'));
      await tester.pumpAndSettle();
      expect(find.byType(PinnedPanel), findsOneWidget);
      await tester.tapAt(const Offset(600, 500));
      await tester.pumpAndSettle();
      expect(find.byType(PinnedPanel), findsNothing);
      expect(rig.controller.pinnedId, 'bookmarks');

      await tester.tap(_button('bookmarks'));
      await tester.pumpAndSettle();
      await tester.tap(_button('bookmarks'));
      await tester.pumpAndSettle();
      expect(find.byType(PinnedPanel), findsNothing);
      expect(rig.controller.pinnedId, isNull, reason: 'a click on its button while it shows closes it and unpins');
    },
  );

  testWidgets('the flyout takes the remembered width clamped to 240–440', (tester) async {
    final _Rig rig = await _pump(tester, window: const Size(1000, 900), inspector: true);
    for (final (double remembered, double shown) in const <(double, double)>[(900, 440), (100, 240)]) {
      rig.controller
        ..panelWidth = remembered
        ..activate('undo');
      await tester.pumpAndSettle();
      expect(rig.controller.flyoutOpen, isTrue);
      expect(_panel(tester, identifier: 'flyout').width, shown, reason: 'remembered $remembered');
      rig.controller.unpin();
      await tester.pumpAndSettle();
    }
  });

  testWidgets("Tab reaches the panel's own controls, then its edge", (tester) async {
    final _Rig rig = await _pump(tester);
    rig.controller.activate('bookmarks');
    await tester.pumpAndSettle();
    String? focused() {
      String? identifier;
      FocusManager.instance.primaryFocus?.context?.visitAncestorElements((element) {
        final Widget widget = element.widget;
        // The first control that names itself (a tooltip around a button is a control without a name).
        final String? id = widget is ZsControl ? (widget as ZsControl).identifier : null;
        if (id != null) {
          identifier = id;
          return false;
        }
        return true;
      });
      return identifier;
    }

    final stops = <String?>[];
    for (var i = 0; i < 12; i++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      stops.add(focused());
    }
    final int close = stops.indexOf('panel-close');
    final int edge = stops.indexOf('panel-edge');
    expect(close, greaterThanOrEqualTo(0), reason: '$stops');
    expect(edge, greaterThan(close), reason: '$stops');
    expect(stops.sublist(close, edge).every((id) => id != null && id.startsWith('panel-')), isTrue, reason: '$stops');
  });

  testWidgets('Esc with nothing open is not handled', (tester) async {
    await _pump(tester);
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.escape), isFalse);
  });
}
