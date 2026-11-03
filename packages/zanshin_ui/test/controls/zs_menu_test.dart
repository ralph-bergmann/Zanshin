// SPDX-License-Identifier: MIT

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin_ui/src/controls/zs_button.dart';
import 'package:zanshin_ui/src/controls/zs_confirm_dialog.dart';
import 'package:zanshin_ui/src/controls/zs_menu.dart';
import 'package:zanshin_ui/src/controls/zs_tooltip.dart';
import 'package:zanshin_ui/src/design/zs_colors.dart';
import 'package:zanshin_ui/src/design/zs_motion.dart';
import 'package:zanshin_ui/src/design/zs_type.dart';
import 'package:zanshin_ui/src/materials/zs_menu_material.dart';

import '../helpers/controls.dart';
import '../helpers/icon_registry.dart';
import '../helpers/zs_host.dart';

const ZsMotion _m = ZsMotion.full;

List<ZsMenuEntry> _entries({VoidCallback? onCommit, List<ZsMenuEntry>? submenu}) => <ZsMenuEntry>[
  const ZsMenuItem(label: 'New change', cmd: 'jj new'),
  const ZsMenuItem(label: 'Copy id'),
  const ZsMenuItem(label: 'Cut', enabled: false),
  const ZsMenuSeparator(),
  const ZsMenuHeader('Show'),
  const ZsMenuItem(label: 'Compare', checked: true),
  ZsMenuItem(
    label: 'More',
    submenu:
        submenu ??
        const <ZsMenuEntry>[
          ZsMenuItem(label: 'Change id'),
          ZsMenuItem(label: 'Description'),
        ],
  ),
  ZsMenuItem(label: 'Commit', danger: true, onSelected: onCommit),
];

const _subject = 'feat(onboarding): swipe gestures';

/// A button that opens the menu, with a focusable neighbour before it.
Widget _host({
  required FocusNode button,
  List<ZsMenuEntry>? entries,
  ZsMenuController? controller,
  Alignment alignment = Alignment.center,
  Widget? extra,
  String? semanticLabel,
  double maxWidth = ZsMenuPanel.defaultMaxWidth,
  double? cmdMaxWidth,
}) => zsHost(
  // An opaque window background, as the app's window fill is: an outside click needs something to hit.
  ColoredBox(
    color: const Color(0x00000000),
    child: SizedBox.expand(
      child: Stack(
        children: <Widget>[
          Align(
            alignment: alignment,
            child: ZsMenuAnchor(
              controller: controller,
              entries: entries ?? _entries(),
              subject: _subject,
              semanticLabel: semanticLabel,
              maxWidth: maxWidth,
              cmdMaxWidth: cmdMaxWidth,
              identifier: 'menu',
              builder: (context, controller) =>
                  ZsButton(label: 'Actions', focusNode: button, onPressed: controller.open),
            ),
          ),
          ?extra,
        ],
      ),
    ),
  ),
  overlay: true,
  icons: true,
);

/// Whether the row labelled [label] is the highlighted one (VoiceOver reads it selected and focused).
bool _highlighted(WidgetTester tester, String label) => isSemantics(
  isSelected: true,
  isFocused: true,
).matches(tester.getSemantics(find.bySemanticsLabel(label)), <dynamic, dynamic>{});

Future<void> _openByKey(WidgetTester tester, FocusNode button) async {
  button.requestFocus();
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  await tester.pump(_m.durMenu);
}

/// Opens the menu by a click and its "More" submenu by resting the pointer on that row; returns the mouse, which
/// stays on the row's label.
Future<TestGesture> _openSubmenuByPointer(WidgetTester tester) async {
  await tester.tap(find.text('Actions'));
  await tester.pump();
  await tester.pump(_m.durMenu);
  final TestGesture mouse = await hover(tester, find.text('More'));
  await tester.pump(_m.delaySubmenu);
  await tester.pump();
  await tester.pump(_m.durMenu);
  expect(find.text('Change id'), findsOneWidget);
  return mouse;
}

/// The point at weights [a], [b], [c] (summing to 1) of the safe triangle: the pointer's last spot [last] and the
/// open submenu's near corners (DS components/menus/Menu.jsx:48-53).
Offset _inTriangle(WidgetTester tester, Offset last, double a, double b, double c) {
  final Rect sub = tester.getRect(find.ancestor(of: find.text('Change id'), matching: find.byType(ZsMenuPanel)).first);
  final double nearX = sub.left >= last.dx ? sub.left : sub.right;
  return last * a + Offset(nearX, sub.top) * b + Offset(nearX, sub.bottom) * c;
}

/// The Project menu's shape (DS components/menus/ProjectMenu.jsx:9-23): fixed width, a command limit, an open project
/// in semibold with a status dot, a row without a dot.
const _dirty = Color(0xFFFACC15);
const _longBookmark = 'feature/a-bookmark-name-long-enough-to-pass-the-limit';

Widget _projectHost({required FocusNode button, String? semanticLabel}) => zsHost(
  ColoredBox(
    color: const Color(0x00000000),
    child: SizedBox.expand(
      child: Align(
        child: ZsMenuAnchor(
          width: 300,
          cmdMaxWidth: 130,
          semanticLabel: semanticLabel,
          entries: const <ZsMenuEntry>[
            ZsMenuHeader('Recent'),
            ZsMenuItem(
              label: 'MyApp',
              checked: true,
              radio: true,
              strong: true,
              dot: _dirty,
              dotLabel: 'uncommitted changes',
              cmd: _longBookmark,
            ),
            ZsMenuItem(label: 'api-server', checked: false, radio: true, cmd: '—'),
          ],
          builder: (context, controller) => ZsButton(label: 'Project', focusNode: button, onPressed: controller.open),
        ),
      ),
    ),
  ),
  overlay: true,
  icons: true,
);

void main() {
  setUpIconRegistry();
  useMacFocus();

  late FocusNode button;
  late SemanticsHandle handle;
  setUp(() => button = FocusNode(debugLabel: 'opener'));
  tearDown(() => button.dispose());

  testWidgets('wrap wraps the built row (Story 10.10); the row still activates', (tester) async {
    var ran = 0;
    await tester.pumpWidget(
      _host(
        button: button,
        entries: <ZsMenuEntry>[
          ZsMenuItem(
            label: 'main',
            onSelected: () => ran++,
            wrap: (row) => KeyedSubtree(key: const ValueKey<String>('wrapped'), child: row),
          ),
        ],
      ),
    );
    await _openByKey(tester, button);
    expect(find.descendant(of: find.byKey(const ValueKey<String>('wrapped')), matching: find.text('main')), findsOne);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(ran, 1);
  });

  testWidgets('↑ ↓ move and wrap, skipping disabled rows; Home End', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    expect(find.text('New change'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlighted(tester, 'New change, jj new'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlighted(tester, 'Compare'), isTrue, reason: 'Cut is disabled');
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(_highlighted(tester, 'Commit'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlighted(tester, 'New change, jj new'), isTrue, reason: 'wrapping');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_highlighted(tester, 'Commit'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(_highlighted(tester, 'New change, jj new'), isTrue);
    handle.dispose();
  });

  testWidgets('typeahead: "co" within --dur-typeahead; a late "c" searches on from the next row', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyO);
    await tester.pump();
    expect(_highlighted(tester, 'Copy id'), isTrue);
    await tester.pump(_m.durTypeahead);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
    await tester.pump();
    expect(_highlighted(tester, 'Compare'), isTrue, reason: 'Cut is disabled and skipped');
    await tester.pump(_m.durTypeahead);
    handle.dispose();
  });

  testWidgets('→ opens a submenu with its first row highlighted; ← and Esc close only the submenu', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_highlighted(tester, 'More'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.pump(_m.durMenu);
    expect(find.text('Change id'), findsOneWidget);
    expect(_highlighted(tester, 'Change id'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    await tester.pump(_m.durExit);
    expect(find.text('Change id'), findsNothing);
    expect(find.text('New change'), findsOneWidget, reason: 'the top level stays open');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(_m.durExit);
    expect(find.text('Change id'), findsNothing);
    expect(find.text('New change'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('← on the top level does nothing; Esc closes it and focus returns to the opener', (tester) async {
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    expect(button.hasPrimaryFocus, isFalse, reason: 'focus moved into the menu');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump(_m.durExit);
    expect(find.text('New change'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('New change'), findsNothing);
    expect(button.hasPrimaryFocus, isTrue);
  });

  testWidgets('a click outside closes it', (tester) async {
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    await tester.tapAt(const Offset(10, 10));
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('New change'), findsNothing);
  });

  testWidgets('I3: ↩ blinks the row, refocuses the opener, then runs the command; the dialog it shows returns to the '
      'opener after Cancel', (tester) async {
    handle = tester.ensureSemantics();
    final showDialog = ValueNotifier<bool>(false);
    addTearDown(showDialog.dispose);
    FocusNode? focusAtDialog;
    await tester.pumpWidget(
      _host(
        button: button,
        entries: _entries(onCommit: () => showDialog.value = true),
        extra: ValueListenableBuilder<bool>(
          valueListenable: showDialog,
          builder: (context, open, _) => open
              ? Positioned.fill(
                  child: _FocusProbe(
                    onInit: () => focusAtDialog = FocusManager.instance.primaryFocus,
                    child: ZsConfirmDialog(
                      title: 'Commit?',
                      confirmLabel: 'Commit',
                      tone: ZsConfirmTone.standard,
                      onConfirm: () {},
                      onCancel: () => showDialog.value = false,
                    ),
                  ),
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
    await _openByKey(tester, button);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(_highlighted(tester, 'Commit'), isFalse, reason: 'the highlight is off for --dur-blink');
    await tester.pump(_m.durBlink);
    expect(_highlighted(tester, 'Commit'), isTrue, reason: 'then on for --dur-blink');
    expect(showDialog.value, isFalse);
    await tester.pump(_m.durBlink);
    expect(showDialog.value, isTrue);
    await tester.pump();
    expect(focusAtDialog, same(button), reason: 'the opener holds focus before the dialog first builds');
    await tester.pump(_m.durExit);
    await tester.pump(_m.durDialog);
    expect(find.text('New change'), findsNothing, reason: 'the menu faded out');
    expect(button.hasPrimaryFocus, isFalse, reason: 'the dialog took focus');
    await tester.tap(find.text('Cancel'));
    await tester.pump();
    expect(showDialog.value, isFalse);
    expect(button.hasPrimaryFocus, isTrue, reason: 'after Cancel focus is on the opener');
    handle.dispose();
  });

  testWidgets('opened again while it is open, the menu keeps its opener', (tester) async {
    final controller = ZsMenuController();
    await tester.pumpWidget(_host(button: button, controller: controller));
    await _openByKey(tester, button);
    controller.open();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('New change'), findsNothing);
    expect(button.hasPrimaryFocus, isTrue);
  });

  testWidgets('without an actionable row, End and then → do nothing', (tester) async {
    await tester.pumpWidget(
      _host(
        button: button,
        entries: const <ZsMenuEntry>[ZsMenuItem(label: 'Undo', enabled: false)],
      ),
    );
    await _openByKey(tester, button);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Undo'), findsOneWidget);
  });

  testWidgets('an opener that is gone gets no focus request and nothing throws', (tester) async {
    final controller = ZsMenuController();
    final other = FocusNode();
    addTearDown(other.dispose);
    await tester.pumpWidget(_host(button: button, controller: controller));
    await _openByKey(tester, button);
    // Replace the opener: the button leaves the tree while the menu shows.
    await tester.pumpWidget(
      zsHost(
        SizedBox.expand(
          child: ZsMenuAnchor(
            controller: controller,
            entries: _entries(),
            builder: (context, controller) => Focus(focusNode: other, child: const SizedBox(width: 20, height: 20)),
          ),
        ),
        overlay: true,
        icons: true,
      ),
    );
    controller.close();
    await tester.pump();
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a submenu opens after --delay-submenu on hover', (tester) async {
    await tester.pumpWidget(_host(button: button));
    await tester.tap(find.text('Actions'));
    await tester.pump();
    await tester.pump(_m.durMenu);
    await hover(tester, find.text('More'));
    await tester.pump(_m.delaySubmenu - const Duration(milliseconds: 10));
    expect(find.text('Change id'), findsNothing);
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(find.text('Change id'), findsOneWidget);
  });

  testWidgets('inside the safe triangle the rows the pointer crosses take no highlight; the submenu stays open', (
    tester,
  ) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button, alignment: Alignment.topLeft));
    final TestGesture mouse = await _openSubmenuByPointer(tester);
    final Offset last = tester.getCenter(find.text('More'));
    final Rect commit = tester.getRect(find.bySemanticsLabel('Commit'));
    for (final (double a, double b, double c) in const <(double, double, double)>[(.3, .1, .6), (.15, .1, .75)]) {
      final Offset point = _inTriangle(tester, last, a, b, c);
      expect(commit.contains(point), isTrue, reason: 'the way to the submenu crosses Commit');
      await mouse.moveTo(point);
      await tester.pump();
      expect(_highlighted(tester, 'Commit'), isFalse);
      expect(_highlighted(tester, 'More'), isTrue);
      expect(find.text('Change id'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(_highlighted(tester, 'Commit'), isFalse);
    expect(find.text('Change id'), findsOneWidget);
    handle.dispose();
  });

  testWidgets('reaching the submenu cancels the pending switch to the row crossed on the way', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button, alignment: Alignment.topLeft));
    final TestGesture mouse = await _openSubmenuByPointer(tester);
    final Offset point = _inTriangle(tester, tester.getCenter(find.text('More')), .3, .1, .6);
    expect(tester.getRect(find.bySemanticsLabel('Commit')).contains(point), isTrue);
    await mouse.moveTo(point);
    await tester.pump(const Duration(milliseconds: 100));
    await mouse.moveTo(tester.getCenter(find.text('Change id')));
    await tester.pump();
    await tester.pump(_m.delaySubmenuOut);
    await tester.pump();
    expect(find.text('Change id'), findsOneWidget, reason: 'the submenu stays open');
    expect(_highlighted(tester, 'More'), isTrue, reason: 'its row keeps the highlight');
    expect(_highlighted(tester, 'Commit'), isFalse);
    handle.dispose();
  });

  testWidgets('leaving row and triangle for another row closes the submenu after --delay-submenu-out', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button, alignment: Alignment.topLeft));
    final TestGesture mouse = await _openSubmenuByPointer(tester);
    // Left of the pointer's last spot: outside the triangle, which opens toward the submenu on the right.
    final Rect compare = tester.getRect(find.bySemanticsLabel('Compare'));
    await mouse.moveTo(compare.centerLeft + const Offset(4, 0));
    await tester.pump();
    expect(_highlighted(tester, 'Compare'), isTrue);
    await tester.pump(_m.delaySubmenuOut - const Duration(milliseconds: 1));
    expect(find.text('Change id'), findsOneWidget, reason: 'still open 1 ms before --delay-submenu-out');
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump();
    expect(find.text('Change id'), findsNothing);
    handle.dispose();
  });

  testWidgets('without room on the right the submenu opens to the left, 8 px inside the window', (tester) async {
    await tester.pumpWidget(_host(button: button, alignment: Alignment.topRight));
    await tester.tap(find.text('Actions'));
    await tester.pump();
    await tester.pump(_m.durMenu);
    await hover(tester, find.text('More'));
    await tester.pump(_m.delaySubmenu);
    await tester.pump();
    await tester.pump(_m.durMenu);
    final Rect more = tester.getRect(find.text('More'));
    final Rect sub = tester.getRect(find.text('Change id'));
    expect(sub.left, lessThan(more.left), reason: 'flipped left');
    expect(sub.left, greaterThanOrEqualTo(8));
  });

  testWidgets('the highlight is solid --accent with --accent-ink; a danger row tints --danger-hover', (tester) async {
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(find.byType(ZsMenuPanel), paints..something(rrectOf(color: ZsColors.night.accent)));
    expect(tester.widget<Text>(find.text('New change')).style?.color, ZsColors.night.accentInk);
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(find.byType(ZsMenuPanel), paints..something(rrectOf(color: ZsColors.night.dangerHover)));
    expect(tester.widget<Text>(find.text('Commit')).style?.color, ZsColors.night.rem);
  });

  testWidgets('VoiceOver: the menu is named by its subject; a check row is checked', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    expect(find.bySemanticsLabel(_subject), findsWidgets);
    expect(find.bySemanticsLabel('New change, jj new'), findsOneWidget, reason: 'a row with a command reads it last');
    expect(
      tester.getSemantics(find.bySemanticsLabel('Compare')),
      isSemantics(isButton: true, hasCheckedState: true, isChecked: true),
    );
    handle.dispose();
  });

  testWidgets('VoiceOver: semanticLabel names a menu without a subject, which shows no head', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_projectHost(button: button, semanticLabel: 'Project'));
    await _openByKey(tester, button);
    expect(tester.getSemantics(find.byType(ZsMenuPanel)), isSemantics(label: 'Project'));
    expect(find.descendant(of: find.byType(ZsMenuPanel), matching: find.text('Project')), findsNothing);
    handle.dispose();
  });

  testWidgets('VoiceOver: semanticLabel names a menu instead of its subject; the head still shows the subject', (
    tester,
  ) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button, semanticLabel: 'Change menu'));
    await _openByKey(tester, button);
    expect(tester.getSemantics(find.byType(ZsMenuPanel)), isSemantics(label: 'Change menu'));
    expect(find.descendant(of: find.byType(ZsMenuPanel), matching: find.text(_subject)), findsOneWidget);
    handle.dispose();
  });

  testWidgets('VoiceOver: without semanticLabel the subject names the menu and fills its head', (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    expect(tester.getSemantics(find.byType(ZsMenuPanel)), isSemantics(label: _subject));
    expect(find.descendant(of: find.byType(ZsMenuPanel), matching: find.text(_subject)), findsOneWidget);
    handle.dispose();
  });

  testWidgets("VoiceOver: a submenu does not take its menu's semanticLabel", (tester) async {
    handle = tester.ensureSemantics();
    await tester.pumpWidget(_host(button: button, semanticLabel: 'Change menu'));
    await _openSubmenuByPointer(tester);
    final Finder submenu = find.ancestor(of: find.text('Change id'), matching: find.byType(ZsMenuPanel)).first;
    expect(tester.getSemantics(submenu).label, isEmpty);
    expect(find.bySemanticsLabel('Change menu'), findsOneWidget, reason: 'only the top-level menu is named');
    handle.dispose();
  });

  testWidgets('without a width the menu is 250–320 wide; with one it is exactly that wide', (tester) async {
    await tester.pumpWidget(_host(button: button));
    await _openByKey(tester, button);
    final double free = tester.getSize(find.byType(ZsMenuMaterial)).width;
    expect(free, inInclusiveRange(250, 320));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();

    await tester.pumpWidget(_projectHost(button: button));
    await _openByKey(tester, button);
    expect(tester.getSize(find.byType(ZsMenuMaterial)).width, 300);
  });

  testWidgets('a row wider than 320 stops at 320 by default and grows up to a given maxWidth', (tester) async {
    const wide = <ZsMenuEntry>[
      ZsMenuItem(label: 'Revert', cmd: 'jj revert -r kxwsnptm -B @ --and-a-long-tail-of-flags'),
    ];
    await tester.pumpWidget(_host(button: button, entries: wide, cmdMaxWidth: 250));
    await _openByKey(tester, button);
    expect(tester.getSize(find.byType(ZsMenuMaterial)).width, ZsMenuPanel.defaultMaxWidth);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump(_m.durExit + const Duration(milliseconds: 1));
    await tester.pump();

    await tester.pumpWidget(_host(button: button, entries: wide, cmdMaxWidth: 250, maxWidth: 360));
    await _openByKey(tester, button);
    expect(tester.getSize(find.byType(ZsMenuMaterial)).width, 360);
  });

  testWidgets('a command longer than cmdMaxWidth ends in an ellipsis at 130; a short one is whole', (tester) async {
    await tester.pumpWidget(_projectHost(button: button));
    await _openByKey(tester, button);
    expect(tester.getSize(find.text(_longBookmark)).width, lessThanOrEqualTo(130));
    expect(tester.renderObject<RenderParagraph>(find.text(_longBookmark)).didExceedMaxLines, isTrue);
    expect(tester.renderObject<RenderParagraph>(find.text('—')).didExceedMaxLines, isFalse);
  });

  testWidgets('a strong row is semibold, the others regular', (tester) async {
    await tester.pumpWidget(_projectHost(button: button));
    await _openByKey(tester, button);
    expect(tester.widget<Text>(find.text('MyApp')).style?.fontWeight, ZsType.fwSemibold);
    expect(tester.widget<Text>(find.text('api-server')).style?.fontWeight, FontWeight.w400);
  });

  testWidgets('the dot paints 6 px 8 after the label; its --accent-ink ring shows only while the row is highlighted', (
    tester,
  ) async {
    await tester.pumpWidget(_projectHost(button: button));
    await _openByKey(tester, button);
    final Finder panel = find.byType(ZsMenuPanel);
    expect(panel, paints..something(circleOf(radius: 3, color: _dirty)));
    expect(panel, isNot(paints..something(circleOf(radius: 3.5, color: ZsColors.night.accentInk))));
    final Rect label = tester.getRect(find.text('MyApp'));
    final Finder dot = find.descendant(
      of: find.byType(ZsMenuPanel),
      matching: find.byWidgetPredicate((widget) => '${widget.runtimeType}' == '_MenuDot'),
    );
    expect(tester.getSize(dot), const Size.square(6));
    expect(tester.getTopLeft(dot).dx - label.right, closeTo(8, .01));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(panel, paints..something(circleOf(radius: 3.5, color: ZsColors.night.accentInk)));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(panel, isNot(paints..something(circleOf(radius: 3.5, color: ZsColors.night.accentInk))));
  });

  testWidgets(
    "VoiceOver reads the label, the dot's meaning and the command; the rows are radio items, the open one checked",
    (tester) async {
      handle = tester.ensureSemantics();
      await tester.pumpWidget(_projectHost(button: button));
      await _openByKey(tester, button);
      expect(
        tester.getSemantics(find.bySemanticsLabel('MyApp, uncommitted changes, $_longBookmark')),
        isSemantics(isButton: true, hasCheckedState: true, isChecked: true, isInMutuallyExclusiveGroup: true),
      );
      expect(
        tester.getSemantics(find.bySemanticsLabel('api-server, —')),
        isSemantics(isButton: true, hasCheckedState: true, isChecked: false, isInMutuallyExclusiveGroup: true),
      );
      handle.dispose();
    },
  );

  testWidgets('a note is passed by ↓; a disabled row shows its tooltip on hover and reads it as its hint', (
    tester,
  ) async {
    ZsTooltip.resetWarmWindow();
    handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _host(
        button: button,
        entries: const <ZsMenuEntry>[
          ZsMenuItem(label: 'New change'),
          ZsMenuNote('Immutable'),
          ZsMenuItem(label: 'Edit'),
          ZsMenuItem(label: 'Revert', enabled: false, tooltip: 'Nothing to revert'),
        ],
      ),
    );
    await _openByKey(tester, button);
    expect(find.text('Immutable'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlighted(tester, 'Edit'), isTrue, reason: 'the note is skipped');
    expect(tester.getSemantics(find.bySemanticsLabel('Revert')), isSemantics(hint: 'Nothing to revert'));
    final TestGesture mouse = await hover(tester, find.text('Revert'));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(find.byType(ZsTooltipBubble), findsOneWidget);
    expect(find.text('Nothing to revert'), findsOneWidget);
    await mouse.removePointer();
    await tester.pump(_m.durExit);
    ZsTooltip.resetWarmWindow();
    handle.dispose();
  });
}

/// Records the focus at the moment it is first built.
class _FocusProbe extends StatefulWidget {
  const _FocusProbe({required this.onInit, required this.child});

  final VoidCallback onInit;
  final Widget child;

  @override
  State<_FocusProbe> createState() => _FocusProbeState();
}

class _FocusProbeState extends State<_FocusProbe> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
