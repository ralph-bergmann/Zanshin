// SPDX-License-Identifier: MIT

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show ScrollerStyle, ShellTheme;
import 'package:zanshin_ui/src/controls/zs_scroll_area.dart';
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/design/zs_root.dart';

import '../helpers/controls.dart';
import '../helpers/zs_host.dart';

const ZsColors _c = ZsColors.night;

/// The area: 300 × 200 over 1000 px of content (or [content]), after a focusable neighbour, under [shell], in
/// [appearance].
Widget _area(
  ScrollController controller, {
  FocusNode? before,
  double content = 1000,
  bool focusableContent = false,
  bool? jumpToClickedSpot,
  ShellTheme? shell,
  ZsAppearance appearance = const ZsAppearance(),
}) => zsHost(
  appearance: appearance,
  ZsShellScope(
    shellTheme: shell,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Focus(focusNode: before, child: const SizedBox(width: 10, height: 10)),
        SizedBox(
          width: 300,
          height: 200,
          child: ZsScrollArea(
            controller: controller,
            label: 'Files',
            jumpToClickedSpot: jumpToClickedSpot,
            identifier: 'area',
            child: SingleChildScrollView(
              controller: controller,
              child: SizedBox(
                height: content,
                child: focusableContent ? const Focus(child: SizedBox.expand()) : null,
              ),
            ),
          ),
        ),
      ],
    ),
  ),
);

ShellTheme _shell({ScrollerStyle style = ScrollerStyle.overlay, bool jump = false}) => ShellTheme(
  brightness: Brightness.dark,
  accentColor: const Color(0xFF0A84FF),
  scrollerStyle: style,
  jumpToClickedSpot: jump,
);

/// Whether the vertical thumb shows in [color] (a pill 6 wide).
PaintPattern _thumb(Color color) => paints
  ..something(
    (method, arguments) =>
        method == #drawRRect && (arguments[0] as RRect).width == 6 && sameColor((arguments[1] as Paint).color, color),
  );

/// Whether a pill [width] wide is painted (the thumb; the track is the 14 px gutter).
PaintPattern _thumbOfWidth(double width) =>
    paints..something((method, arguments) => method == #drawRRect && (arguments[0] as RRect).width == width);

ScrollController _controller() {
  final controller = ScrollController();
  addTearDown(controller.dispose);
  return controller;
}

FocusNode _node() {
  final node = FocusNode();
  addTearDown(node.dispose);
  return node;
}

/// A press in the vertical track at [y] (from the area's top), 7 px in from the right edge.
Future<void> _pressTrack(WidgetTester tester, double y) async {
  final Rect area = tester.getRect(find.byType(ZsScrollArea));
  final TestGesture gesture = await tester.startGesture(Offset(area.right - 7, area.top + y));
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  useMacFocus();

  group('Tab stop', () {
    testWidgets('the viewport is one while it scrolls and holds nothing focusable, with the ring inside', (
      tester,
    ) async {
      final ScrollController controller = _controller();
      final FocusNode before = _node();
      await tester.pumpWidget(_area(controller, before: before));
      await tester.pump();
      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(Focus.of(tester.element(find.byType(SingleChildScrollView))).hasPrimaryFocus, isTrue);
      await tester.pumpAndSettle();
      expect(find.byType(ZsScrollArea), paints..something(ringOf(color: _c.focusRing)));
    });

    testWidgets('not while the content fits', (tester) async {
      final ScrollController controller = _controller();
      final FocusNode before = _node();
      await tester.pumpWidget(_area(controller, before: before, content: 100));
      await tester.pump();
      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(Focus.of(tester.element(find.byType(SingleChildScrollView))).hasPrimaryFocus, isFalse);
    });

    testWidgets('not while it holds something focusable', (tester) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller, focusableContent: true));
      await tester.pump();
      final Focus area = tester.widget<Focus>(
        find.descendant(of: find.byType(ZsScrollArea), matching: find.byType(Focus)).first,
      );
      expect(area.canRequestFocus, isFalse);
    });
  });

  testWidgets('keys: ↓ 40, Page Down and Space a page less 40, ⇧Space back, End and Home the ends', (tester) async {
    final ScrollController controller = _controller();
    final FocusNode before = _node();
    await tester.pumpWidget(_area(controller, before: before));
    await tester.pump();
    before.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    expect(controller.offset, 40);
    await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
    expect(controller.offset, 200);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    expect(controller.offset, 360);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(controller.offset, 200);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    expect(controller.offset, 800);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    expect(controller.offset, 760);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    expect(controller.offset, 0);
  });

  group('the bar', () {
    testWidgets('hidden at rest; in --scroll-thumb while scrolling; gone again --delay-scroll-hide later', (
      tester,
    ) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller));
      await tester.pump();
      expect(find.byType(ZsScrollArea), isNot(_thumb(_c.scrollThumb)));
      controller.jumpTo(100);
      await tester.pump();
      await tester.pump(ZsMotion.full.durHover + const Duration(milliseconds: 1));
      expect(find.byType(ZsScrollArea), _thumb(_c.scrollThumb));
      await tester.pump(ZsMotion.full.delayScrollHide);
      await tester.pump();
      await tester.pump(ZsMotion.full.durExitLg + const Duration(milliseconds: 1));
      expect(find.byType(ZsScrollArea), isNot(_thumb(_c.scrollThumb)));
    });

    testWidgets('the legacy scroller style ("Show scroll bars: Always") shows it at rest', (tester) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller, shell: _shell(style: ScrollerStyle.legacy)));
      await tester.pump();
      await tester.pump();
      expect(find.byType(ZsScrollArea), _thumb(_c.scrollThumb));
    });

    testWidgets('under reduce motion the gutter widens the thumb to --scroll-w-hover on the next frame', (
      tester,
    ) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(
        _area(
          controller,
          shell: _shell(style: ScrollerStyle.legacy),
          appearance: const ZsAppearance(reduceMotion: true),
        ),
      );
      await tester.pump();
      expect(find.byType(ZsScrollArea), _thumbOfWidth(6));
      final Rect area = tester.getRect(find.byType(ZsScrollArea));
      await hover(tester, find.byType(ZsScrollArea), at: Offset(area.right - 7, area.center.dy));
      expect(find.byType(ZsScrollArea), _thumbOfWidth(10));
    });
  });

  group('a track press', () {
    testWidgets('pages toward the press (the viewport less 40); ⌥ jumps to the spot instead', (tester) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller));
      await tester.pump();
      await _pressTrack(tester, 150);
      expect(controller.offset, 160);
      controller.jumpTo(0);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.altLeft);
      await _pressTrack(tester, 98);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.altLeft);
      // Track 196 long, thumb 39.2: centred on 96 from the track's top, the travel 156.8.
      expect(controller.offset, closeTo((96 - 19.6) / 156.8 * 800, .01));
    });

    testWidgets('with "Jump to the spot that\'s clicked" it centres the thumb on the press', (tester) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller, jumpToClickedSpot: true));
      await tester.pump();
      await _pressTrack(tester, 98);
      expect(controller.offset, closeTo((96 - 19.6) / 156.8 * 800, .01));
    });

    testWidgets('I2: a paging preference that changes after the build applies to the next press', (tester) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller, shell: _shell()));
      await tester.pump();
      await _pressTrack(tester, 150);
      expect(controller.offset, 160, reason: 'paging');
      controller.jumpTo(0);
      await tester.pumpWidget(_area(controller, shell: _shell(jump: true)));
      await _pressTrack(tester, 98);
      expect(controller.offset, closeTo((96 - 19.6) / 156.8 * 800, .01), reason: 'jumping');
    });

    testWidgets('continues as a thumb drag', (tester) async {
      final ScrollController controller = _controller();
      await tester.pumpWidget(_area(controller, jumpToClickedSpot: true));
      await tester.pump();
      final Rect area = tester.getRect(find.byType(ZsScrollArea));
      final TestGesture gesture = await tester.startGesture(Offset(area.right - 7, area.top + 2 + 19.6));
      await tester.pump();
      expect(controller.offset, 0);
      await gesture.moveBy(const Offset(0, 78.4));
      await tester.pump();
      expect(controller.offset, closeTo(400, .01));
      await gesture.up();
    });

    testWidgets('while the content fits there is no bar: the gutter\'s clicks reach the content', (tester) async {
      final ScrollController controller = _controller();
      var taps = 0;
      await tester.pumpWidget(
        zsHost(
          SizedBox(
            width: 300,
            height: 200,
            child: ZsScrollArea(
              controller: controller,
              child: SingleChildScrollView(
                controller: controller,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => taps++,
                  child: const SizedBox(width: 300, height: 100),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Rect area = tester.getRect(find.byType(ZsScrollArea));
      await tester.tapAt(Offset(area.right - 5, area.top + 50));
      expect(taps, 1);
    });
  });

  testWidgets(
    'the only bar is its own: the platform\'s scrollbar is off for the content',
    (tester) async {
      await tester.pumpWidget(_area(_controller()));
      expect(find.byType(RawScrollbar), findsNothing);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.macOS),
  );

  testWidgets('VoiceOver: a region named by its label', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_area(_controller()));
    expect(tester.getSemantics(find.bySemanticsIdentifier('area')), isSemantics(label: 'Files'));
    handle.dispose();
  });
}
