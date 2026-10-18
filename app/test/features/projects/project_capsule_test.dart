// SPDX-License-Identifier: MIT

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/projects/project_capsule.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/shell_host.dart';

const ZsMotion _m = ZsMotion.full;
const _longBookmark = 'feature/a-bookmark-name-long-enough-to-pass-the-limit';

final _open = ProjectEntry(
  path: '/Users/me/code/zanshin',
  name: 'zanshin',
  status: ProjectStatus.dirty,
  bookmark: 'main',
  lastOpened: DateTime.utc(2026, 10, 18),
);

final _recent = <ProjectEntry>[
  _open,
  ProjectEntry(
    path: '/r/api',
    name: 'api-server',
    status: ProjectStatus.clean,
    bookmark: 'develop',
    lastOpened: DateTime.utc(2026, 10, 17),
  ),
  ProjectEntry(
    path: '/r/web',
    name: 'web',
    status: ProjectStatus.conflict,
    bookmark: _longBookmark,
    lastOpened: DateTime.utc(2026, 10, 16),
  ),
  ProjectEntry(path: '/r/docs', name: 'docs', status: ProjectStatus.stale, lastOpened: DateTime.utc(2026, 10, 15)),
  ProjectEntry(path: '/r/tools', name: 'tools', bookmark: 'trunk', lastOpened: DateTime.utc(2026, 10, 14)),
];

/// The capsule at the bar's PLACE position (91, 4), under a focus node that counts the Esc presses that reach it.
class _Rig {
  final opened = <String>[];
  var escapes = 0;
  var allProjects = 0;
  var projectSettings = 0;
  var settings = 0;

  Widget host({ProjectEntry? project, bool actions = false}) => shellHost(
    Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
          escapes++;
        }
        return KeyEventResult.ignored;
      },
      child: ColoredBox(
        color: const Color(0x00000000),
        child: Stack(
          children: <Widget>[
            Positioned(
              left: 91,
              top: 4,
              child: ProjectCapsule(
                project: project ?? _open,
                recent: _recent,
                onOpen: opened.add,
                onAllProjects: actions ? () => allProjects++ : null,
                onProjectSettings: actions ? () => projectSettings++ : null,
                onSettings: actions ? () => settings++ : null,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

Finder _menu() => find.byType(ZsMenuMaterial);

Finder _dot() => find.descendant(
  of: find.byType(ProjectCapsule),
  matching: find.byWidgetPredicate(
    (widget) =>
        widget is DecoratedBox &&
        widget.decoration is BoxDecoration &&
        (widget.decoration as BoxDecoration).shape == BoxShape.circle,
  ),
);

/// Matches a `drawRRect` filled with [color].
PaintPatternPredicate _fill(Color color) =>
    (method, arguments) => method == #drawRRect && (arguments[1] as Paint).color.toARGB32() == color.toARGB32();

Future<void> _openByClick(WidgetTester tester) async {
  await tester.tap(find.text('zanshin'));
  await tester.pump();
  await tester.pump(_m.durMenu);
}

/// Gives the capsule keyboard focus, as Tab would, and returns its node.
Future<FocusNode> _focusCapsule(WidgetTester tester) async {
  final FocusNode node = Focus.of(tester.element(find.byType(ZsGlass)))..requestFocus();
  await tester.pump();
  return node;
}

Future<void> _settleClose(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(_m.durExit + const Duration(milliseconds: 1));
  await tester.pump();
}

bool _highlighted(WidgetTester tester, String label) => isSemantics(
  isSelected: true,
  isFocused: true,
).matches(tester.getSemantics(find.bySemanticsLabel(label)), <dynamic, dynamic>{});

Future<void> _wheel(WidgetTester tester, double dy) async {
  final pointer = TestPointer(9, PointerDeviceKind.mouse, 9);
  await tester.sendEventToBinding(pointer.addPointer(location: const Offset(700, 500)));
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.sendEventToBinding(pointer.removePointer());
  await tester.pump();
}

void main() {
  setUpIconRegistry();
  setUp(() => FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional);
  tearDown(() {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    ZsTooltip.resetWarmWindow();
  });

  testWidgets('the capsule: a 44 px island at radius 14 — chip, name, dot and chevron 10 apart, padded 8 and 12', (
    tester,
  ) async {
    useShellWindow(tester);
    await tester.pumpWidget(_Rig().host());
    final Rect capsule = tester.getRect(find.byType(ZsGlass));
    expect(capsule.topLeft, const Offset(91, 4));
    expect(capsule.height, 44);
    expect(tester.widget<ZsGlass>(find.byType(ZsGlass)).radius, 14);

    final Rect mark = tester.getRect(find.byType(ZsNamiMark));
    expect(mark.size, const Size.square(28));
    expect(mark.left, capsule.left + ZsSurface.borderWidth + 8);
    expect(mark.center.dy, capsule.center.dy);
    expect(tester.widget<ZsNamiMark>(find.byType(ZsNamiMark)).chip, isTrue);

    final Rect name = tester.getRect(find.text('zanshin'));
    expect(name.left, mark.right + 10);
    final TextStyle style = tester.widget<Text>(find.text('zanshin')).style!;
    expect(style.fontSize, 13);
    expect(style.fontWeight, FontWeight.w600);

    final Rect dot = tester.getRect(_dot());
    expect(dot.size, const Size.square(7));
    expect(dot.left, name.right + 10);
    expect((tester.widget<DecoratedBox>(_dot()).decoration as BoxDecoration).color, ZsColors.night.projDirty);

    final Finder chevron = find.byWidgetPredicate((widget) => widget is ZanshinIcon && widget.name == ZI.chevronDown);
    final Rect chevronRect = tester.getRect(chevron);
    expect(chevronRect.left, dot.right + 10);
    expect(chevronRect.right, capsule.right - ZsSurface.borderWidth - 12);
    expect(tester.widget<ZanshinIcon>(chevron).color, ZsColors.night.textDim);
    expect(tester.widget<ZanshinIcon>(chevron).size, ZsIconSize.md);
  });

  testWidgets('a long name ends in an ellipsis at 220; without a status there is no dot', (tester) async {
    useShellWindow(tester);
    const long = 'a-project-with-a-name-far-too-long-for-the-capsule-to-show-in-full';
    await tester.pumpWidget(
      _Rig().host(
        project: const ProjectEntry(path: '/r/long', name: long),
      ),
    );
    expect(tester.getSize(find.text(long)).width, 220);
    expect(tester.renderObject<RenderParagraph>(find.text(long)).didExceedMaxLines, isTrue);
    expect(_dot(), findsNothing);
  });

  testWidgets('the tooltip is the path, the dot\'s the status label; VoiceOver reads name, status and expanded', (
    tester,
  ) async {
    useShellWindow(tester);
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_Rig().host());
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('project-capsule')),
      isSemantics(
        isButton: true,
        label: 'zanshin',
        value: 'uncommitted changes',
        tooltip: '/Users/me/code/zanshin',
        hasExpandedState: true,
        isExpanded: false,
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );

    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('zanshin')));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(find.text('/Users/me/code/zanshin'), findsOneWidget);
    await mouse.moveTo(tester.getCenter(_dot()));
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(find.text('uncommitted changes'), findsOneWidget);
    await mouse.moveTo(const Offset(700, 700));
    await tester.pumpAndSettle();

    await _openByClick(tester);
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('project-capsule')),
      isSemantics(
        hasExpandedState: true,
        isExpanded: true,
        isButton: true,
        label: 'zanshin',
        value: 'uncommitted changes',
        tooltip: '/Users/me/code/zanshin',
        hasEnabledState: true,
        isEnabled: true,
        isFocusable: true,
        hasTapAction: true,
        hasFocusAction: true,
      ),
    );
    // The tooltips' shared warm window runs out.
    await tester.pump(_m.durTooltipWarm);
    handle.dispose();
  });

  testWidgets('a click opens the 300 px menu 10 below the capsule\'s left edge in --fl-on; a second click closes it', (
    tester,
  ) async {
    useShellWindow(tester);
    await tester.pumpWidget(_Rig().host());
    final Rect capsule = tester.getRect(find.byType(ZsGlass));
    expect(find.byType(ProjectCapsule), isNot(paints..something(_fill(ZsColors.night.flOn))));

    await _openByClick(tester);
    final Rect menu = tester.getRect(_menu());
    expect(menu.width, 300);
    expect(menu.left, capsule.left);
    expect(menu.top, capsule.bottom + 10);
    await tester.pump(_m.durHover);
    expect(find.byType(ProjectCapsule), paints..something(_fill(ZsColors.night.flOn)));

    await tester.tap(find.text('zanshin').first);
    await _settleClose(tester);
    expect(_menu(), findsNothing);
    await tester.pump(_m.durHover);
    expect(find.byType(ProjectCapsule), isNot(paints..something(_fill(ZsColors.night.flOn))));
  });

  testWidgets('focus inside the open menu never shows the path tooltip over it', (tester) async {
    useShellWindow(tester);
    await tester.pumpWidget(_Rig().host());
    await _openByClick(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump(_m.delayTooltip);
    await tester.pump(_m.durHover);
    expect(_menu(), findsOneWidget);
    expect(find.text('/Users/me/code/zanshin'), findsNothing);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleClose(tester);
    await tester.pump(_m.durTooltipWarm);
  });

  testWidgets(
    'the menu: RECENT, five radio rows (the open one checked and semibold, a dot after the name, the bookmark or —, '
    'cut at 130), All Projects… ⇧⌘O, Project Settings…, Settings… ⌘, — the last three disabled without actions',
    (tester) async {
      useShellWindow(tester);
      final SemanticsHandle handle = tester.ensureSemantics();
      await tester.pumpWidget(_Rig().host());
      await _openByClick(tester);

      final List<double> tops =
          <String>[
                'RECENT',
                'zanshin, uncommitted changes, main',
                'api-server, clean, develop',
                'web, conflict, $_longBookmark',
                'docs, working copy is stale, —',
                'tools, trunk',
                'All Projects…',
                'Project Settings…',
                'Settings…',
              ]
              .map((label) => tester.getRect(find.descendant(of: _menu(), matching: find.bySemanticsLabel(label))).top)
              .toList();
      expect(tops, List<double>.of(tops)..sort(), reason: 'in this order');

      for (var i = 0; i < 5; i++) {
        expect(find.bySemanticsIdentifier('project-menu-recent-$i'), findsOneWidget);
      }
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('project-menu-recent-0')),
        isSemantics(
          isButton: true,
          hasCheckedState: true,
          isChecked: true,
          isInMutuallyExclusiveGroup: true,
          label: 'zanshin, uncommitted changes, main',
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('project-menu-recent-1')),
        isSemantics(
          isButton: true,
          hasCheckedState: true,
          isChecked: false,
          isInMutuallyExclusiveGroup: true,
          label: 'api-server, clean, develop',
          hasEnabledState: true,
          isEnabled: true,
          hasTapAction: true,
        ),
      );
      final Finder openName = find.descendant(of: _menu(), matching: find.text('zanshin'));
      expect(tester.widget<Text>(openName).style!.fontWeight, ZsType.fwSemibold);
      expect(tester.widget<Text>(find.text('api-server')).style!.fontWeight, FontWeight.w400);
      expect(find.text('main'), findsOneWidget);
      expect(find.text('develop'), findsOneWidget);
      expect(find.text('—'), findsOneWidget);
      expect(tester.getSize(find.text(_longBookmark)).width, lessThanOrEqualTo(130));
      expect(tester.renderObject<RenderParagraph>(find.text(_longBookmark)).didExceedMaxLines, isTrue);
      expect(find.text('⇧⌘O'), findsOneWidget);
      expect(find.text('⌘,'), findsOneWidget);
      for (final id in <String>['project-menu-all', 'project-menu-project-settings', 'project-menu-settings']) {
        expect(
          tester.getSemantics(find.bySemanticsIdentifier(id)),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
          reason: id,
        );
      }
      expect(
        _menu(),
        paints..something(
          (method, arguments) =>
              method == #drawCircle &&
              (arguments[2] as Paint).color.toARGB32() == ZsColors.night.projConflict.toARGB32(),
        ),
      );
      handle.dispose();
    },
  );

  testWidgets('VoiceOver reads the open menu as "Project"; it shows no head, RECENT stays its first row', (
    tester,
  ) async {
    useShellWindow(tester);
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(_Rig().host());
    await _openByClick(tester);

    expect(find.ancestor(of: _menu(), matching: find.bySemanticsLabel('Project')), findsOneWidget);
    expect(find.descendant(of: _menu(), matching: find.text('Project')), findsNothing);
    final double recent = tester.getTopLeft(find.descendant(of: _menu(), matching: find.text('RECENT'))).dy;
    final above = <String>[
      for (final Element text in find.descendant(of: _menu(), matching: find.byType(RichText)).evaluate())
        if ((text.renderObject! as RenderBox).localToGlobal(Offset.zero).dy < recent)
          (text.widget as RichText).text.toPlainText(),
    ];
    expect(above, isEmpty, reason: 'no text sits above RECENT');
    handle.dispose();
  });

  testWidgets('with actions the three rows are enabled and run them', (tester) async {
    useShellWindow(tester);
    final rig = _Rig();
    await tester.pumpWidget(rig.host(actions: true));
    for (final row in <String>['All Projects…', 'Project Settings…', 'Settings…']) {
      await _openByClick(tester);
      await tester.tap(find.text(row));
      await tester.pump(_m.durBlink * 2);
      await _settleClose(tester);
    }
    expect((rig.allProjects, rig.projectSettings, rig.settings), (1, 1, 1));
  });

  for (final (String name, LogicalKeyboardKey key) in <(String, LogicalKeyboardKey)>[
    ('↩', LogicalKeyboardKey.enter),
    ('Space', LogicalKeyboardKey.space),
    ('↓', LogicalKeyboardKey.arrowDown),
  ]) {
    testWidgets('$name on the capsule opens the menu; Esc closes it, focus returns and the Esc goes no further', (
      tester,
    ) async {
      useShellWindow(tester);
      final rig = _Rig();
      await tester.pumpWidget(rig.host());
      final FocusNode capsule = await _focusCapsule(tester);

      await tester.sendKeyEvent(key);
      await tester.pump();
      await tester.pump(_m.durMenu);
      expect(_menu(), findsOneWidget);
      expect(capsule.hasPrimaryFocus, isFalse, reason: 'focus moved into the menu');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _settleClose(tester);
      expect(_menu(), findsNothing);
      expect(capsule.hasPrimaryFocus, isTrue);
      expect(rig.escapes, 0);
    });
  }

  testWidgets('↑ ↓ Home End and typing move the highlight; a highlighted row\'s dot takes the --accent-ink ring; ↩ '
      'on another project opens it', (tester) async {
    useShellWindow(tester);
    final SemanticsHandle handle = tester.ensureSemantics();
    final rig = _Rig();
    await tester.pumpWidget(rig.host());
    await _focusCapsule(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    await tester.pump(_m.durMenu);

    PaintPattern ring() => paints
      ..something(
        (method, arguments) =>
            method == #drawCircle &&
            (arguments[2] as Paint).style == PaintingStyle.stroke &&
            (arguments[2] as Paint).color.toARGB32() == ZsColors.night.accentInk.toARGB32(),
      );

    expect(_menu(), isNot(ring()));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(_highlighted(tester, 'zanshin, uncommitted changes, main'), isTrue);
    expect(_menu(), ring());
    await tester.sendKeyEvent(LogicalKeyboardKey.end);
    await tester.pump();
    expect(_highlighted(tester, 'tools, trunk'), isTrue, reason: 'the three window rows are disabled');
    expect(_menu(), isNot(ring()), reason: 'tools has no dot');
    await tester.sendKeyEvent(LogicalKeyboardKey.home);
    await tester.pump();
    expect(_highlighted(tester, 'zanshin, uncommitted changes, main'), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(_highlighted(tester, 'tools, trunk'), isTrue, reason: 'wrapping');
    await tester.sendKeyEvent(LogicalKeyboardKey.keyW);
    await tester.pump();
    expect(_highlighted(tester, 'web, conflict, $_longBookmark'), isTrue);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(_m.durBlink * 2);
    await _settleClose(tester);
    expect(rig.opened, <String>['/r/web']);
    expect(_menu(), findsNothing);
    await tester.pump(_m.durTypeahead);
    handle.dispose();
  });

  testWidgets('I1: while the menu is open calm scrolling does not start; once it has closed, it does', (tester) async {
    useShellWindow(tester);
    final controller = ShellController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      shellHost(
        FloatingShell(
          controller: controller,
          graph: ListView.builder(itemCount: 200, itemExtent: 40, itemBuilder: (context, i) => Text('row $i')),
          projectCapsule: ProjectCapsule(project: _open, recent: _recent, onOpen: (_) {}),
        ),
      ),
    );
    expect(tester.getTopLeft(find.byType(ZsGlass).first), const Offset(91, 4));

    await _openByClick(tester);
    expect(controller.calm.held, isTrue);
    await _wheel(tester, 100);
    await tester.pump(const Duration(milliseconds: 100));
    expect(controller.calm.value.calm, isFalse, reason: 'the open menu holds calm');

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _settleClose(tester);
    await tester.pump(const Duration(seconds: 1));
    expect(controller.calm.held, isFalse);
    await _wheel(tester, 31);
    expect(controller.calm.value.calm, isTrue);
    await tester.pump(const Duration(seconds: 2));
  });
}
