// SPDX-License-Identifier: MIT

import 'dart:ui' show ImageFilter;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_colors.dart';
import 'package:zanshin/src/shared/design/zs_elevation.dart';
import 'package:zanshin/src/shared/design/zs_motion.dart';
import 'package:zanshin/src/shared/design/zs_root.dart';
import 'package:zanshin/src/shared/design/zs_values.dart';
import 'package:zanshin/src/shared/materials/zs_glass.dart';
import 'package:zanshin/src/shared/materials/zs_sheet.dart';
import 'package:zanshin/src/shared/materials/zs_surface.dart';
import 'package:zanshin/src/shared/materials/zs_surface_transition.dart';

import '../../helpers/material_paints.dart';
import '../../helpers/zs_host.dart';

/// A sheet over [beneath] (or nothing), filling the test surface.
Widget _window(
  Widget? sheet, {
  List<Widget> beneath = const <Widget>[],
  ZsAppearance appearance = const ZsAppearance(),
}) => zsHost(
  SizedBox.expand(
    child: Stack(children: <Widget>[...beneath, ?sheet]),
  ),
  appearance: appearance,
);

/// A focusable control, 40 × 20.
Widget _control(FocusNode node) => Focus(focusNode: node, child: const SizedBox(width: 40, height: 20));

Widget _controls(List<FocusNode> nodes) =>
    Row(mainAxisSize: MainAxisSize.min, children: <Widget>[for (final FocusNode node in nodes) _control(node)]);

/// The scrim's fade: the outermost `FadeTransition` of the sheet.
double _scrimOpacity(WidgetTester tester) => tester
    .widget<FadeTransition>(find.descendant(of: find.byType(ZsSheet), matching: find.byType(FadeTransition)).first)
    .opacity
    .value;

Future<void> _pumpMs(WidgetTester tester, int ms) => tester.pump(Duration(milliseconds: ms));

List<FocusNode> _nodes(int count) {
  final nodes = <FocusNode>[for (var i = 0; i < count; i++) FocusNode(debugLabel: 'control $i')];
  addTearDown(() {
    for (final node in nodes) {
      node.dispose();
    }
  });
  return nodes;
}

void main() {
  testWidgets('the scrim fades in over 160 ms and out over 180 ms, and the sheet takes 220 and 180', (tester) async {
    var closed = 0;
    Widget sheet({bool closing = false}) => _window(
      ZsSheet(
        semanticLabel: 'Sheet',
        onCancel: () {},
        closing: closing,
        onClosed: () => closed++,
        child: const SizedBox(width: 300, height: 200),
      ),
    );
    await tester.pumpWidget(sheet());
    expect(_scrimOpacity(tester), 0);
    await _pumpMs(tester, 80);
    expect(_scrimOpacity(tester), closeTo(ZsMotion.full.easeState.transform(.5), 1e-6), reason: 'the state curve');
    await _pumpMs(tester, 79);
    expect(_scrimOpacity(tester), lessThan(1));
    await _pumpMs(tester, 1);
    expect(_scrimOpacity(tester), 1);
    final ZsSurfaceTransition transition = tester.widget<ZsSurfaceTransition>(find.byType(ZsSurfaceTransition));
    expect(transition.motion, ZsSurfaceMotion.sheet, reason: 'the sheet enters as the sheet motion (220 ms)');
    await _pumpMs(tester, 60);

    await tester.pumpWidget(sheet(closing: true));
    expect(_scrimOpacity(tester), 1);
    await _pumpMs(tester, 90);
    expect(_scrimOpacity(tester), closeTo(1 - ZsMotion.full.easeExit.transform(.5), 1e-6), reason: 'the exit curve');
    await _pumpMs(tester, 89);
    expect(_scrimOpacity(tester), greaterThan(0));
    expect(closed, 0);
    await _pumpMs(tester, 1);
    expect(_scrimOpacity(tester), 0);
    expect(closed, 1);
  });

  testWidgets('under reduce motion the scrim still fades over 160 and 180 ms', (tester) async {
    Widget sheet({bool closing = false}) => _window(
      ZsSheet(
        semanticLabel: 'Sheet',
        onCancel: () {},
        closing: closing,
        child: const SizedBox(width: 300, height: 200),
      ),
      appearance: const ZsAppearance(reduceMotion: true),
    );
    await tester.pumpWidget(sheet());
    await _pumpMs(tester, 80);
    expect(_scrimOpacity(tester), allOf(greaterThan(0), lessThan(1)));
    await _pumpMs(tester, 80);
    expect(_scrimOpacity(tester), 1);
    await tester.pumpWidget(sheet(closing: true));
    await _pumpMs(tester, 90);
    expect(_scrimOpacity(tester), allOf(greaterThan(0), lessThan(1)));
    await _pumpMs(tester, 90);
    expect(_scrimOpacity(tester), 0);
  });

  testWidgets('over grouped islands the scrim blurs in a group of its own, its alpha following the fade', (
    tester,
  ) async {
    await tester.pumpWidget(
      _window(
        ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: const SizedBox(width: 300, height: 200)),
        beneath: const <Widget>[ZsIsland(child: SizedBox(width: 100, height: 20))],
      ),
    );
    final Finder scrim = find.descendant(of: find.byType(ZsSheet), matching: find.byType(BackdropFilter));
    final Finder island = find.descendant(of: find.byType(ZsIsland), matching: find.byType(BackdropFilter));
    const blur = ZsGlassFilter(blur: 12, saturate: 1.2);

    await _pumpMs(tester, 80);
    final double fade = _scrimOpacity(tester);
    expect(fade, allOf(greaterThan(0), lessThan(1)));
    // CSS opacity over the whole scrim: the blur's share is a·(1 − Lα) / (1 − a·Lα).
    final double scrimAlpha = ZsColors.night.scrim.a;
    expect(
      tester.widget<BackdropFilter>(scrim).filter,
      blur.toImageFilter(alpha: fade * (1 - scrimAlpha) / (1 - fade * scrimAlpha)),
    );
    expect(find.ancestor(of: scrim, matching: find.byType(FadeTransition)), findsNothing);
    expect(find.ancestor(of: scrim, matching: find.byType(Opacity)), findsNothing);

    await tester.pumpAndSettle();
    expect(
      tester.widget<BackdropFilter>(scrim).filter,
      ImageFilter.compose(
        outer: ColorFilter.matrix(ZsGlassFilter.saturateMatrix(1.2)),
        inner: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      ),
    );
    final BackdropKey? scrimKey = tester.renderObject<RenderBackdropFilter>(scrim).backdropKey;
    final BackdropKey? islandKey = tester.renderObject<RenderBackdropFilter>(island).backdropKey;
    expect(scrimKey, isNotNull);
    expect(islandKey, isNotNull);
    expect(scrimKey, isNot(islandKey));
  });

  testWidgets('a tap on the scrim does nothing and reaches nothing beneath', (tester) async {
    var taps = 0;
    var cancels = 0;
    await tester.pumpWidget(
      _window(
        ZsSheet(semanticLabel: 'Sheet', onCancel: () => cancels++, child: const SizedBox(width: 300, height: 200)),
        beneath: <Widget>[
          Positioned.fill(
            child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++),
          ),
        ],
      ),
    );
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(taps, 0);
    expect(cancels, 0);
    expect(find.byType(ZsSheet), findsOneWidget);
  });

  for (final (String state, bool busy, bool closing, int expected) in <(String, bool, bool, int)>[
    ('open', false, false, 1),
    ('busy', true, false, 0),
    ('closing', false, true, 0),
  ]) {
    testWidgets('Esc on a $state sheet cancels $expected times', (tester) async {
      final [FocusNode a] = _nodes(1);
      var cancels = 0;
      Widget sheet({required bool closing}) => _window(
        ZsSheet(
          semanticLabel: 'Sheet',
          onCancel: () => cancels++,
          busy: busy,
          closing: closing,
          child: _controls(<FocusNode>[a]),
        ),
      );
      await tester.pumpWidget(sheet(closing: false));
      await tester.pumpAndSettle();
      expect(a.hasPrimaryFocus, isTrue);
      if (closing) {
        await tester.pumpWidget(sheet(closing: true));
        await tester.pump();
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(cancels, expected);
    });
  }

  testWidgets('focus starts on the initial focus after the first frame', (tester) async {
    final [FocusNode a, FocusNode b, FocusNode c] = _nodes(3);
    await tester.pumpWidget(
      _window(
        ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, initialFocus: b, child: _controls(<FocusNode>[a, b, c])),
      ),
    );
    await tester.pump();
    expect(b.hasPrimaryFocus, isTrue);
  });

  testWidgets('without an initial focus, focus starts on the first control, and Tab loops inside', (tester) async {
    final [FocusNode a, FocusNode b, FocusNode c] = _nodes(3);
    final [FocusNode outside] = _nodes(1);
    await tester.pumpWidget(
      _window(
        ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: _controls(<FocusNode>[a, b, c])),
        beneath: <Widget>[_control(outside)],
      ),
    );
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    c.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue, reason: 'Tab from the last control reaches the first');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(c.hasPrimaryFocus, isTrue, reason: 'Shift+Tab from the first control reaches the last');
    expect(outside.hasFocus, isFalse);
  });

  testWidgets('a sheet without a control holds focus itself, and Shift+Tab from there lands inside', (tester) async {
    final [FocusNode a, FocusNode b] = _nodes(2);
    Widget sheet(List<FocusNode> nodes) =>
        _window(ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: _controls(nodes)));
    await tester.pumpWidget(sheet(const <FocusNode>[]));
    await tester.pump();
    final FocusNode? scope = FocusManager.instance.primaryFocus;
    expect(scope, isA<FocusScopeNode>());
    expect(find.descendant(of: find.byType(ZsSheet), matching: find.byWidget(scope!.context!.widget)), findsOne);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, scope, reason: 'Tab stays on the sheet');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(FocusManager.instance.primaryFocus, scope, reason: 'Shift+Tab stays on the sheet');

    await tester.pumpWidget(sheet(<FocusNode>[a, b]));
    expect(FocusManager.instance.primaryFocus, scope);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
    await tester.pump();
    expect(a.hasPrimaryFocus || b.hasPrimaryFocus, isTrue);
  });

  /// The opener in one focus scope, the sheet in another that last focused [other]: there, Flutter's own fallback
  /// would focus [other], so only the sheet's own return reaches the opener (11.3 mounts sheets in its own layer).
  Widget scopes({required FocusNode opener, required FocusNode other, Widget? sheet}) => zsHost(
    SizedBox.expand(
      child: Row(
        children: <Widget>[
          FocusScope(child: _control(opener)),
          Expanded(
            child: FocusScope(
              child: Stack(children: <Widget>[_control(other), ?sheet]),
            ),
          ),
        ],
      ),
    ),
  );

  Future<void> focusOtherThenOpener(WidgetTester tester, FocusNode other, FocusNode opener) async {
    await tester.pumpWidget(scopes(opener: opener, other: other));
    other.requestFocus();
    await tester.pump();
    opener.requestFocus();
    await tester.pump();
  }

  testWidgets('focus returns to the opener when the sheet starts closing', (tester) async {
    final [FocusNode opener, FocusNode other, FocusNode a] = _nodes(3);
    Widget sheet({bool closing = false}) =>
        ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, closing: closing, child: _control(a));
    await focusOtherThenOpener(tester, other, opener);
    await tester.pumpWidget(scopes(opener: opener, other: other, sheet: sheet()));
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(scopes(opener: opener, other: other, sheet: sheet(closing: true)));
    await tester.pump();
    expect(opener.hasPrimaryFocus, isTrue);
  });

  testWidgets('a sheet removed without closing returns focus at dispose', (tester) async {
    final [FocusNode opener, FocusNode other, FocusNode a] = _nodes(3);
    await focusOtherThenOpener(tester, other, opener);
    await tester.pumpWidget(
      scopes(
        opener: opener,
        other: other,
        sheet: ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: _control(a)),
      ),
    );
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(scopes(opener: opener, other: other));
    await tester.pump();
    expect(opener.hasPrimaryFocus, isTrue);
  });

  testWidgets('an opener that is gone gets no focus back, and nothing throws', (tester) async {
    final [FocusNode opener, FocusNode a] = _nodes(2);
    Widget window({required bool withOpener, bool open = true, bool closing = false}) => _window(
      open ? ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, closing: closing, child: _control(a)) : null,
      beneath: <Widget>[if (withOpener) _control(opener)],
    );
    await tester.pumpWidget(window(withOpener: true, open: false));
    opener.requestFocus();
    await tester.pump();
    await tester.pumpWidget(window(withOpener: true));
    await tester.pump();
    await tester.pumpWidget(window(withOpener: false));
    await tester.pump();
    await tester.pumpWidget(window(withOpener: false, closing: true));
    await tester.pump();
    await tester.pumpWidget(window(withOpener: false, open: false));
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(opener.hasFocus, isFalse);
  });

  testWidgets('VoiceOver reads the sheet as a named route and nothing beneath the scrim', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _window(
        ZsSheet(
          semanticLabel: 'Discard changes?',
          onCancel: () {},
          child: Semantics(label: 'Inside', container: true, child: const SizedBox(width: 300, height: 200)),
        ),
        beneath: <Widget>[
          Semantics(label: 'Beneath', container: true, child: const SizedBox(width: 100, height: 100)),
        ],
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester.getSemantics(find.bySemanticsLabel('Discard changes?')),
      isSemantics(label: 'Discard changes?', scopesRoute: true, namesRoute: true),
    );
    final labels = <String>[
      for (final SemanticsNode node in tester.semantics.simulatedAccessibilityTraversal()) node.label,
    ];
    expect(labels, contains('Inside'));
    expect(labels, isNot(contains('Beneath')));
    semantics.dispose();
  });

  testWidgets('the sheet paints the DS sheet, centred and clamped to its parent less 48', (tester) async {
    await tester.pumpWidget(
      _window(
        ZsSheet(
          semanticLabel: 'Sheet',
          onCancel: () {},
          width: 900,
          height: 300,
          child: const SizedBox.expand(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final Finder surface = find.descendant(of: find.byType(ZsSheet), matching: find.byType(ZsSurface));
    expect(tester.getRect(surface), const Rect.fromLTWH(24, 150, 752, 300));
    expectWithShadows(
      surface,
      surfacePaints(
        outer: outerShape(const Size(752, 300), 18),
        fill: ZsColors.night.flBgSolid,
        border: ZsColors.night.flBorder,
        drops: ZsElevation.night.shadowDialog.parts,
      ),
    );
    expect(
      surface,
      paints
        ..drrect()
        ..clipRRect(rrect: outerShape(const Size(752, 300), 18).deflate(1)),
    );
  });

  testWidgets('a closing sheet takes no focus, and a tap on the fading scrim reaches what lies beneath', (
    tester,
  ) async {
    final [FocusNode a] = _nodes(1);
    var taps = 0;
    Widget window({bool closing = false}) => _window(
      ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, closing: closing, child: _control(a)),
      beneath: <Widget>[
        Positioned.fill(
          child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => taps++),
        ),
      ],
    );
    await tester.pumpWidget(window());
    await tester.pumpAndSettle();
    expect(a.hasPrimaryFocus, isTrue);
    await tester.pumpWidget(window(closing: true));
    await _pumpMs(tester, 30);
    expect(a.hasFocus, isFalse);
    a.requestFocus();
    await tester.pump();
    expect(a.hasFocus, isFalse, reason: 'the leaving sheet takes no focus');
    await tester.tapAt(const Offset(10, 10));
    expect(taps, 1);
  });

  testWidgets('Esc cancels through the sheet own binding, without a host that maps Esc', (tester) async {
    final [FocusNode a] = _nodes(1);
    var cancels = 0;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ZsRoot(
          appearance: const ZsAppearance(),
          child: ZsSheet(semanticLabel: 'Sheet', onCancel: () => cancels++, child: _control(a)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(a.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(cancels, 1);
  });

  testWidgets('reopening a sheet during its exit moves focus back inside and reports no close', (tester) async {
    final [FocusNode opener, FocusNode a] = _nodes(2);
    var closed = 0;
    Widget window({bool closing = false}) => _window(
      ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, closing: closing, onClosed: () => closed++, child: _control(a)),
      beneath: <Widget>[_control(opener)],
    );
    await tester.pumpWidget(window());
    await tester.pumpAndSettle();
    await tester.pumpWidget(window(closing: true));
    await _pumpMs(tester, 60);
    expect(a.hasFocus, isFalse);
    await tester.pumpWidget(window());
    await tester.pump();
    expect(a.hasPrimaryFocus, isTrue);
    await tester.pumpAndSettle();
    expect(_scrimOpacity(tester), 1);
    expect(closed, 0);
  });

  testWidgets('a sheet removed during its exit never reports closed', (tester) async {
    var closed = 0;
    Widget window({required bool closing}) => _window(
      ZsSheet(
        semanticLabel: 'Sheet',
        onCancel: () {},
        closing: closing,
        onClosed: () => closed++,
        child: const SizedBox(width: 300, height: 200),
      ),
    );
    await tester.pumpWidget(window(closing: false));
    await tester.pumpAndSettle();
    await tester.pumpWidget(window(closing: true));
    await _pumpMs(tester, 60);
    await tester.pumpWidget(_window(null));
    await _pumpMs(tester, 500);
    expect(closed, 0);
  });

  testWidgets('a sheet reports closed once per exit, over two close and reopen cycles', (tester) async {
    var closed = 0;
    Widget window({required bool closing}) => _window(
      ZsSheet(
        semanticLabel: 'Sheet',
        onCancel: () {},
        closing: closing,
        onClosed: () => closed++,
        child: const SizedBox(width: 300, height: 200),
      ),
    );
    await tester.pumpWidget(window(closing: false));
    await tester.pumpAndSettle();
    for (var cycle = 1; cycle <= 2; cycle++) {
      await tester.pumpWidget(window(closing: true));
      await _pumpMs(tester, 180);
      expect(closed, cycle);
      await _pumpMs(tester, 500);
      expect(closed, cycle, reason: 'once per exit');
      await tester.pumpWidget(window(closing: false));
      await tester.pumpAndSettle();
      expect(closed, cycle, reason: 'reopening reports nothing');
    }
  });

  testWidgets('once the sheet starts closing, VoiceOver reaches what lies beneath again', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    Widget window({bool closing = false}) => _window(
      ZsSheet(
        semanticLabel: 'Discard changes?',
        onCancel: () {},
        closing: closing,
        child: Semantics(label: 'Inside', container: true, child: const SizedBox(width: 300, height: 200)),
      ),
      beneath: <Widget>[
        Semantics(label: 'Opener', container: true, child: const SizedBox(width: 100, height: 100)),
      ],
    );
    List<String> labels() => <String>[
      for (final SemanticsNode node in tester.semantics.simulatedAccessibilityTraversal()) node.label,
    ];
    await tester.pumpWidget(window());
    await tester.pumpAndSettle();
    expect(labels(), isNot(contains('Opener')));
    await tester.pumpWidget(window(closing: true));
    await tester.pump();
    expect(labels(), contains('Opener'));
    expect(labels(), isNot(contains('Inside')));
    expect(labels(), isNot(contains('Discard changes?')));
    semantics.dispose();
  });

  testWidgets('the scrim and the sheet show the arrow cursor over a grab region', (tester) async {
    await tester.pumpWidget(
      zsHost(
        MouseRegion(
          cursor: SystemMouseCursors.grab,
          child: SizedBox.expand(
            child: ZsSheet(semanticLabel: 'Sheet', onCancel: () {}, child: const SizedBox(width: 300, height: 200)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final TestGesture gesture = await tester.createGesture(kind: PointerDeviceKind.mouse, pointer: 1);
    await gesture.addPointer(location: const Offset(10, 10));
    addTearDown(gesture.removePointer);
    await tester.pump();
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.basic);
    await gesture.moveTo(tester.getCenter(find.byType(ZsSurface)));
    expect(RendererBinding.instance.mouseTracker.debugDeviceActiveCursor(1), SystemMouseCursors.basic);
  });
}
