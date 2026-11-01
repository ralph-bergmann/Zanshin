// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:logging/logging.dart';
import 'package:zanshin/l10n/app_localizations_en.dart';
import 'package:zanshin/main.dart' show MainComponent;
import 'package:zanshin/src/app/worker_lifecycle_module.dart';
import 'package:zanshin/src/features/bootstrap/icon_module.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_repos.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/projects/projects_environment.dart';
import 'package:zanshin/src/features/projects/projects_module.dart';
import 'package:zanshin/src/features/projects/projects_tree.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin/src/features/projects/tree_drop.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_projects_environment.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/recording_shell.dart';
import '../../helpers/shell_host.dart';

const ZsMotion _m = ZsMotion.full;

final _en = AppLocalizationsEn();

/// How long `_Rig.settle` waits, in real time, for work started in the fake zone.
const _settleBudget = Duration(seconds: 10);

/// Work › (Mobile › MyApp, design-kit), api-server · top · gone (missing): the floating export's shape.
ProjectsSettings _demo(String home) {
  final now = DateTime.now();
  return ProjectsSettings(
    groups: const <ProjectGroup>[
      ProjectGroup(id: 'g1', name: 'Work'),
      ProjectGroup(id: 'g2', name: 'Mobile', parent: 'g1'),
    ],
    projects: <ProjectEntry>[
      ProjectEntry(
        path: '$home/code/work/mobile/myapp',
        name: 'MyApp',
        group: 'g2',
        status: ProjectStatus.dirty,
        bookmark: 'feature/new-ui',
        lastOpened: now.subtract(const Duration(hours: 2)),
      ),
      ProjectEntry(
        path: '$home/code/work/mobile/design-kit',
        name: 'design-kit',
        group: 'g2',
        order: 1,
        status: ProjectStatus.clean,
      ),
      ProjectEntry(
        path: '$home/code/work/api-server',
        name: 'api-server',
        group: 'g1',
        order: 1,
        status: ProjectStatus.conflict,
        bookmark: 'develop',
      ),
      ProjectEntry(path: '$home/code/top', name: 'top', order: 1, status: ProjectStatus.clean),
      ProjectEntry(path: '$home/code/gone', name: 'gone', order: 2, status: ProjectStatus.missing),
    ],
  );
}

/// The window content over a fresh settings store, a session on fake repositories and a fake environment.
class _Rig {
  _Rig(this.tester);

  final WidgetTester tester;
  late Directory dir;
  late SettingsStore store;
  late ProjectRegistry registry;
  late ProjectSession session;
  final repos = FakeProjectRepos();
  final env = FakeProjectsEnvironment();
  final opened = <ProjectOpened>[];

  /// Runs when the content reports an open, after it is recorded in [opened].
  void Function(ProjectOpened outcome)? whenOpened;
  var settings = 0;
  var identitySettings = 0;

  String get home => env.home;

  Future<void> pump({
    Size size = const Size(900, 640),
    bool demo = true,
    String? openUnderHome,
    bool callbacks = true,
    ZsAppearance appearance = const ZsAppearance(),
  }) async {
    useShellWindow(tester, size);
    final Directory created = (await tester.runAsync(() => Directory.systemTemp.createTemp('projects_window_test')))!;
    dir = created;
    addTearDown(() => created.deleteSync(recursive: true));
    env.home = dir.resolveSymbolicLinksSync();
    store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    if (demo) {
      await tester.runAsync(() => store.update((settings) => settings.copyWith(projects: _demo(home))));
    }
    registry = ProjectRegistry(store);
    session = ProjectSession(registry: registry, repos: repos);
    addTearDown(session.dispose);
    if (openUnderHome != null) {
      final path = '$home/$openUnderHome';
      // The reading keeps what the demo stores for it.
      final ProjectEntry? stored = registry.entry(path);
      repos.readings[path] = ProjectReading(status: stored?.status ?? ProjectStatus.clean, bookmark: stored?.bookmark);
      await tester.runAsync(() => session.open(path));
    }
    _content = ProjectsWindow(
      key: UniqueKey(),
      session: session,
      registry: registry,
      environment: env,
      onOpened: callbacks
          ? (outcome) {
              opened.add(outcome);
              whenOpened?.call(outcome);
            }
          : null,
      onSettings: callbacks ? () => settings++ : null,
      onIdentitySettings: callbacks ? () => identitySettings++ : null,
    );
    await tester.pumpWidget(shellHost(_content, appearance: appearance));
    await tester.pump();
    await tester.pump();
  }

  late Widget _content;

  /// Shows the same content under [appearance], as the window's key status changing does.
  Future<void> showIn(ZsAppearance appearance) async {
    await tester.pumpWidget(shellHost(_content, appearance: appearance));
    await tester.pump();
    await tester.pump();
  }

  /// Lets work started in the fake zone finish its settings writes (real file IO) until [done].
  ///
  /// The wait is bounded by [_settleBudget] of real time, not by a number of polls: each write
  /// is fsync'd and chained, so under the full gate's parallel load one can take seconds.
  /// The dart:core `Stopwatch` reads real time here: fake_async fakes timers, microtasks and
  /// `package:clock`, not `Stopwatch` (a `clock.stopwatch()` would never advance in this loop).
  Future<void> settle(bool Function() done) async {
    final watch = Stopwatch()..start();
    while (!done() && watch.elapsed < _settleBudget) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(
      done(),
      isTrue,
      reason:
          'settings writes not done after ${watch.elapsedMilliseconds} ms of real time '
          '(budget ${_settleBudget.inSeconds} s)',
    );
    await tester.pump();
  }

  /// The sheet's entrance and exit.
  Future<void> sheetIn() async {
    await tester.pump();
    await tester.pump(_m.durDialog);
  }

  Future<void> sheetOut() async {
    await tester.pump();
    await tester.pump(_m.durExitLg + const Duration(milliseconds: 1));
    await tester.pump();
  }

  /// Puts focus in the search, where a keyboard user starts (nothing is focused on open; Ralph, 2026-10-29).
  Future<void> focusSearch() async {
    await tester.showKeyboard(find.descendant(of: id('projects-search'), matching: find.byType(EditableText)));
    await tester.pump();
  }

  /// Presses [label] in the list-edit question once its sheet is in, and lets the sheet go.
  Future<void> answer(String label) async {
    await sheetIn();
    await tester.tap(find.descendant(of: id('projects-question'), matching: find.text(label)));
    await sheetOut();
  }

  /// Confirms the list-edit question by ⌘↩ once its sheet is in, and lets the sheet go.
  Future<void> confirmByKeys() async {
    await sheetIn();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await key(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await sheetOut();
  }

  Finder id(String identifier) => find.bySemanticsIdentifier(identifier);

  /// The visible row named [name].
  Finder row(String name) => find.ancestor(of: find.text(name), matching: find.byType(ZsControlCore)).first;

  String? get focused => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> key(LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pump();
  }
}

void main() {
  setUpIconRegistry();
  late RecordingShell shell;
  setUp(() {
    ZanshinShellPlatform.instance = shell = RecordingShell();
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  });
  tearDown(() async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    ZsTooltip.resetWarmWindow();
    await shell.close();
  });

  group('layout', () {
    testWidgets('at 900 × 640: the 200 px sidebar, the 52 px header, the toolbar and the tree in registry order', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(openUnderHome: 'code/work/mobile/myapp');

      expect(tester.getRect(rig.id('projects-window')), const Rect.fromLTWH(0, 0, 900, 640));
      expect(tester.getTopLeft(find.text('Projects').last).dx, 212, reason: 'the title at sidebar + 12');
      expect(tester.getCenter(find.text('Projects').last).dy, moreOrLessEquals(26), reason: 'on the block line');
      expect(tester.getSize(rig.id('projects-search')).width, 230);
      expect(tester.getRect(rig.id('projects-search')).center.dy, 26, reason: 'centred in the 52 pt header row');
      expect(tester.getCenter(rig.id('projects-add-directory')).dy, moreOrLessEquals(26));
      expect(find.text('Add directory'), findsOneWidget);
      expect(find.text('Clone…'), findsOneWidget);
      expect(find.text('New group'), findsNothing, reason: 'New group is icon-only');
      expect(find.byType(ZsNamiMark), findsOneWidget);
      expect(find.text('Zanshin'), findsOneWidget);
      expect(find.text('2026.9.1 · Build 1'), findsOneWidget);
      expect(find.text('Ralph Stein'), findsOneWidget);
      expect(find.text('ralph@example.com'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('Zanshin')).dy,
        greaterThan(52),
        reason: 'the brand sits below the header row',
      );

      final order = <String>[
        for (final String name in <String>['WORK', 'MOBILE', 'MyApp', 'design-kit', 'api-server', 'top', 'gone']) name,
      ]..sort((a, b) => tester.getTopLeft(find.text(a)).dy.compareTo(tester.getTopLeft(find.text(b)).dy));
      expect(order, <String>['WORK', 'MOBILE', 'MyApp', 'design-kit', 'api-server', 'top', 'gone']);
      expect(find.text('1 · 1 group'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
      expect(find.text('OPEN'), findsOneWidget);
      expect(tester.getSemantics(rig.row('MyApp')), isSemantics(label: 'MyApp', value: 'uncommitted changes, open'));
      expect(find.text('feature/new-ui'), findsOneWidget);
      expect(find.text('~/code/work/mobile/myapp'), findsOneWidget);
      expect(find.text('now'), findsOneWidget, reason: 'opened just now');
      expect(tester.getSize(rig.row('MyApp')).height, ProjectsTree.projectHeight);
      expect(tester.getSize(rig.row('WORK')).height, ProjectsTree.groupHeight);
      expect(tester.getTopLeft(rig.row('MyApp')).dx - tester.getTopLeft(rig.row('WORK')).dx, 0);
      expect(
        tester.getTopLeft(find.text('MOBILE')).dx - tester.getTopLeft(find.text('WORK')).dx,
        ProjectsTree.indent,
        reason: '16 per level',
      );
      final Text gone = tester.widget<Text>(find.text('gone'));
      expect(gone.style?.decoration, TextDecoration.lineThrough);
      expect(gone.style?.color, ZsColors.night.textFaint);
    });

    testWidgets("at a measured traffic-light block (centre y 27) the header centres on the block's line", (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(appearance: const ZsAppearance(trafficLights: Rect.fromLTWH(20, 20, 60, 14)));
      final ZsColors colors = ZsColors.of(tester.element(find.text('Projects').last));
      final Finder header = find.byWidgetPredicate(
        (widget) =>
            widget is DecoratedBox &&
            widget.decoration is BoxDecoration &&
            (widget.decoration as BoxDecoration).border == Border(bottom: BorderSide(color: colors.flBorder)),
      );

      expect(tester.getTopLeft(find.text('Projects').last).dx, 212, reason: 'the title still at sidebar + 12');
      expect(tester.getRect(header.first), const Rect.fromLTWH(200, 0, 700, 52), reason: 'the header still 52');
      for (final (String label, Finder item) in <(String, Finder)>[
        ('the title', find.text('Projects').last),
        ('the search', rig.id('projects-search')),
        ('Add directory', rig.id('projects-add-directory')),
        ('Clone…', rig.id('projects-clone')),
        ('New group', rig.id('projects-new-group')),
      ]) {
        expect(tester.getCenter(item).dy, moreOrLessEquals(27), reason: '$label on the block line');
      }
    });

    testWidgets('at 680 × 440 the search is 120 and Clone… is icon-only', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(size: const Size(680, 440));

      expect(tester.getSize(rig.id('projects-search')).width, 120);
      expect(find.text('Clone…'), findsNothing);
      expect(find.text('Add directory'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an empty registry says how to add one', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(demo: false);

      expect(find.text(_en.treeEmpty), findsOneWidget);
    });
  });

  group('keys', () {
    testWidgets('nothing has focus on open; ↓ from the search moves into the tree at the open project; ↑ ↓ Home End', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(openUnderHome: 'code/work/api-server');
      expect(rig.focused, isNot('projects search'), reason: 'Ralph, 2026-10-29: a focused search on open looks odd');
      await rig.focusSearch();
      expect(rig.focused, 'projects search');

      await rig.key(LogicalKeyboardKey.arrowDown);
      expect(rig.focused, 'projects row project:${rig.home}/code/work/api-server');

      await rig.key(LogicalKeyboardKey.arrowDown);
      expect(rig.focused, 'projects row project:${rig.home}/code/top');
      await rig.key(LogicalKeyboardKey.home);
      expect(rig.focused, 'projects row group:g1');
      await rig.key(LogicalKeyboardKey.end);
      expect(rig.focused, 'projects row project:${rig.home}/code/gone');
      await rig.key(LogicalKeyboardKey.arrowUp);
      expect(rig.focused, 'projects row project:${rig.home}/code/top');
      expect(
        tester.getSemantics(rig.row('top')),
        isSemantics(isSelected: true, isFocused: true, label: 'top', value: 'clean'),
      );
    });

    testWidgets('← collapses a group or steps to the parent; → expands or steps in; ↩ toggles a group', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await rig.focusSearch();
      await rig.key(LogicalKeyboardKey.arrowDown);
      expect(rig.focused, 'projects row group:g1', reason: 'without a selection the first row');

      await rig.key(LogicalKeyboardKey.arrowRight);
      expect(rig.focused, 'projects row group:g2', reason: 'expanded: → steps in');
      await rig.key(LogicalKeyboardKey.arrowLeft);
      expect(find.text('MyApp'), findsNothing, reason: '← collapses Mobile');
      expect(tester.getSemantics(rig.row('MOBILE')), isSemantics(isExpanded: false, hasExpandedState: true));
      await rig.key(LogicalKeyboardKey.arrowLeft);
      expect(rig.focused, 'projects row group:g1', reason: 'collapsed: ← steps to the parent');
      await rig.key(LogicalKeyboardKey.arrowDown);
      await rig.key(LogicalKeyboardKey.arrowRight);
      expect(find.text('MyApp'), findsOneWidget, reason: '→ expands');
      await rig.key(LogicalKeyboardKey.enter);
      expect(find.text('MyApp'), findsNothing, reason: '↩ toggles a group');
      await rig.key(LogicalKeyboardKey.arrowDown);
      await rig.key(LogicalKeyboardKey.arrowLeft);
      expect(rig.focused, 'projects row group:g1', reason: 'from a project, ← steps to its group');
    });

    testWidgets('↩ opens a project; a missing one does not open', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await rig.focusSearch();
      await rig.key(LogicalKeyboardKey.arrowDown);
      await rig.key(LogicalKeyboardKey.end);

      await rig.key(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(rig.repos.log, isEmpty, reason: 'gone is missing');

      await rig.key(LogicalKeyboardKey.arrowUp);
      await rig.key(LogicalKeyboardKey.enter);
      await rig.settle(() => rig.session.current != null);
      expect(rig.session.current?.path, '${rig.home}/code/top');
      expect(rig.opened, hasLength(1));
      expect(find.text('OPEN'), findsOneWidget);
    });

    testWidgets('typing a prefix within --dur-typeahead selects the next row starting with it', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await rig.focusSearch();
      await rig.key(LogicalKeyboardKey.arrowDown);

      await rig.key(LogicalKeyboardKey.keyD);
      expect(rig.focused, 'projects row project:${rig.home}/code/work/mobile/design-kit');
      await tester.pump(_m.durTypeahead);
      await rig.key(LogicalKeyboardKey.keyT);
      await rig.key(LogicalKeyboardKey.keyO);
      expect(rig.focused, 'projects row project:${rig.home}/code/top');
    });

    testWidgets('the tree is one Tab stop; Tab from the selected row reaches its ••• and then leaves the tree', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump(callbacks: false);
      final Finder newGroupButton = find.byWidgetPredicate(
        (widget) => widget is ZsButton && widget.label == 'New group',
      );
      Focus.of(tester.element(find.descendant(of: newGroupButton, matching: find.byType(CustomPaint)).first))
          .requestFocus();
      await tester.pump();

      await rig.key(LogicalKeyboardKey.tab);
      expect(rig.focused, 'projects row group:g1', reason: 'no selection: the first row');
      await rig.key(LogicalKeyboardKey.arrowDown);
      await rig.key(LogicalKeyboardKey.arrowDown);
      expect(rig.focused, 'projects row project:${rig.home}/code/work/mobile/myapp');
      await rig.key(LogicalKeyboardKey.tab);
      expect(rig.focused, 'projects more project:${rig.home}/code/work/mobile/myapp');
      await rig.key(LogicalKeyboardKey.tab);
      expect(
        rig.focused,
        isNot(anyOf(startsWith('projects row'), startsWith('projects more'))),
        reason: 'no other row or ••• is a Tab stop',
      );
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shift);
      await rig.key(LogicalKeyboardKey.tab);
      await rig.key(LogicalKeyboardKey.tab);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shift);
      expect(rig.focused, 'projects row project:${rig.home}/code/work/mobile/myapp');
    });

    testWidgets('Tab runs through the header, then the tree, then the sidebar', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Finder newGroupButton = find.byWidgetPredicate(
        (widget) => widget is ZsButton && widget.label == 'New group',
      );
      Focus.of(tester.element(find.descendant(of: newGroupButton, matching: find.byType(CustomPaint)).first))
          .requestFocus();
      await tester.pump();

      await rig.key(LogicalKeyboardKey.tab);
      expect(rig.focused, 'projects row group:g1', reason: 'from the header into the body');
      // The selected group row's ••• (Story 11.15 item 3), then the next Tab leaves the tree.
      await rig.key(LogicalKeyboardKey.tab);
      expect(rig.focused, 'projects more group:g1');
      await rig.key(LogicalKeyboardKey.tab);
      final BuildContext? focused = FocusManager.instance.primaryFocus?.context;
      expect(
        find.ancestor(
          of: find.byElementPredicate((element) => identical(element, focused)),
          matching: rig.id('projects-settings'),
        ),
        findsOneWidget,
        reason: 'from the body into the sidebar: Settings…',
      );
    });

    testWidgets('typeahead continues across a space in a name', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.runAsync(() => rig.registry.add('${rig.home}/code/my-project', name: 'my project'));
      await tester.pump();
      await rig.focusSearch();
      await rig.key(LogicalKeyboardKey.arrowDown);
      expect(rig.focused, 'projects row group:g1');

      for (final key in <LogicalKeyboardKey>[
        LogicalKeyboardKey.keyM,
        LogicalKeyboardKey.keyY,
        LogicalKeyboardKey.space,
        LogicalKeyboardKey.keyP,
      ]) {
        await rig.key(key);
      }
      expect(rig.focused, 'projects row project:${rig.home}/code/my-project', reason: '"my p", not "myp"');
    });
  });

  group('search', () {
    testWidgets('filters by name and path across groups; no match says so; Esc clears it', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Finder field = find.descendant(of: rig.id('projects-search'), matching: find.byType(EditableText));

      await tester.enterText(field, 'mobile/d');
      await tester.pump();
      expect(find.text('design-kit'), findsOneWidget);
      expect(find.text('MyApp'), findsNothing);
      expect(find.text('WORK'), findsOneWidget, reason: 'its groups stay, expanded');
      expect(find.text('top'), findsNothing);

      await tester.enterText(field, 'zzz');
      await tester.pump();
      expect(find.text('No projects match “zzz”'), findsOneWidget);

      await rig.key(LogicalKeyboardKey.escape);
      expect(find.text('top'), findsOneWidget);
      expect(rig.focused, 'projects search', reason: 'Esc clears and keeps focus; it closes nothing');
    });

    testWidgets('a group toggled during a search keeps its state for when the search is cleared', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Finder field = find.descendant(of: rig.id('projects-search'), matching: find.byType(EditableText));

      await tester.enterText(field, 'design');
      await tester.pump();
      await tester.tap(find.text('MOBILE'));
      await tester.pump();
      expect(find.text('design-kit'), findsOneWidget, reason: 'a search shows its groups open');

      await tester.enterText(field, '');
      await tester.pump();
      expect(find.text('MyApp'), findsOneWidget, reason: 'Mobile is still expanded');
    });
  });

  group('Add directory', () {
    testWidgets('a jj workspace is registered in the selected group and opened', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(find.text('MOBILE'));
      await tester.pump();
      rig.env.pickerAnswers.add('${rig.home}/new-repo');

      await tester.tap(rig.id('projects-add-directory'));
      await rig.settle(() => rig.session.current != null);

      expect(rig.repos.log, <String>[
        'detect ${rig.home}/new-repo',
        'open ${rig.home}/new-repo',
        'read ${rig.home}/new-repo',
      ]);
      expect(rig.registry.entry('${rig.home}/new-repo')!.group, 'g2');
      expect(rig.opened.single.warnings, isEmpty);
      expect(rig.env.pickerCalls.single, '${tester.view.viewId} null Add', reason: 'the panel button reads Add');
    });

    testWidgets('a cancelled picker does nothing', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      expect(rig.repos.log, isEmpty);
    });

    testWidgets('a Git repository gets the conversion sheet; Cancel changes nothing; Convert converts and opens', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final git = '${rig.home}/legacy';
      rig.repos.detections[git] = const RepoDetectResult(kind: RepoKind.git);
      rig.repos.creationWarnings[git] = const <ZanshinWarning>[
        ZanshinWarning(code: ZanshinWarningCode.identityMissing, message: 'Name and email not configured.'),
      ];
      final ProjectsSettings before = rig.registry.value;

      rig.env.pickerAnswers.add(git);
      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await rig.sheetIn();
      expect(find.text('Convert legacy to a jj repository?'), findsOneWidget);
      expect(find.text("jj git init --colocate '$git'"), findsOneWidget);
      expect(
        find.text('~/legacy stays a Git repository; jj joins it and shares its working copy.', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await rig.sheetOut();
      expect(rig.id('projects-offer'), findsNothing);
      expect(rig.registry.value, before);
      expect(rig.repos.log, <String>['detect $git']);

      rig.env.pickerAnswers.add(git);
      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await rig.sheetIn();
      await tester.tap(find.text('Convert'));
      await rig.settle(() => rig.session.current != null);
      await rig.sheetOut();
      expect(rig.repos.log.sublist(1), <String>['detect $git', 'convert $git', 'read $git']);
      expect(rig.registry.entry(git), isNotNull);
      expect(find.text('Converted legacy'), findsOneWidget);
      expect(find.text('Name and email not configured.'), findsOneWidget, reason: 'warnings verbatim');
    });

    testWidgets('a plain folder gets the init sheet with jj git init --no-colocate', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final plain = '${rig.home}/plain';
      rig.repos.detections[plain] = const RepoDetectResult(kind: RepoKind.neither);
      rig.env.pickerAnswers.add(plain);

      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await rig.sheetIn();
      expect(find.text('Create a jj repository in plain?'), findsOneWidget);
      expect(find.text("jj git init --no-colocate '$plain'"), findsOneWidget);
      expect(
        find.text('~/plain becomes a jj repository, its Git store inside .jj.', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Create'));
      await rig.settle(() => rig.session.current != null);
      expect(rig.repos.log, <String>['detect $plain', 'init $plain', 'read $plain']);
    });

    testWidgets('a folder inside a repository gets the enclosing sheet; Add opens the repository', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final root = '${rig.home}/root';
      rig.repos.detections['$root/src'] = RepoDetectResult(
        kind: RepoKind.neither,
        suggestedRoot: root,
        suggestedKind: RepoKind.jj,
      );
      rig.env.pickerAnswers.add('$root/src');

      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await rig.sheetIn();
      expect(find.text('Add the enclosing repository root?'), findsOneWidget);
      expect(
        find.text('~/root/src lies inside the jj repository at ~/root.', findRichText: true),
        findsOneWidget,
        reason: 'the chosen folder first, then the repository',
      );
      await tester.tap(find.text('Add'));
      await rig.settle(() => rig.session.current != null);
      expect(rig.session.current?.path, root);
    });

    testWidgets('a folder inside a Git repository gets the conversion sheet for that repository', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final root = '${rig.home}/legacy';
      rig.repos.detections['$root/src'] = RepoDetectResult(
        kind: RepoKind.neither,
        suggestedRoot: root,
        suggestedKind: RepoKind.git,
      );
      rig.env.pickerAnswers.add('$root/src');

      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await rig.sheetIn();
      expect(find.text('Convert legacy to a jj repository?'), findsOneWidget);
      expect(find.text("jj git init --colocate '$root'"), findsOneWidget);
      expect(find.textContaining('lies inside the Git repository at'), findsOneWidget, reason: 'the sheet says why');
      expect(
        find.text(
          '~/legacy/src lies inside the Git repository at ~/legacy. It stays a Git repository; jj joins it and shares '
          'its working copy.',
          findRichText: true,
        ),
        findsOneWidget,
        reason: 'the chosen folder first, then the repository',
      );
      await tester.tap(find.text('Convert'));
      await rig.settle(() => rig.session.current != null);
      expect(rig.repos.log, <String>['detect $root/src', 'convert $root', 'read $root']);
      expect(rig.session.current?.path, root);
    });

    testWidgets('a path that is gone says so; a failed conversion shows its context and warnings', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      rig.repos.detections['${rig.home}/gone2'] = const RepoDetectResult(kind: RepoKind.pathNotFound);
      rig.env.pickerAnswers.add('${rig.home}/gone2');
      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await tester.pump();
      expect(find.text('${rig.home}/gone2 does not exist.'), findsOneWidget);

      final git = '${rig.home}/broken';
      rig.repos.detections[git] = const RepoDetectResult(kind: RepoKind.git);
      rig.repos.creationFailures[git] = const ZanshinFfiException.withReport(
        'jj.convert_failed',
        'the import failed',
        precondition: null,
        warnings: <ZanshinWarning>[ZanshinWarning(code: 'jj.git_import_failed', message: 'Failed to import refs.')],
      );
      rig.env.pickerAnswers.add(git);
      await tester.tap(rig.id('projects-add-directory'));
      await tester.pump();
      await rig.sheetIn();
      await tester.tap(find.text('Convert'));
      await tester.pump();
      await rig.sheetOut();
      expect(find.text('Conversion failed'), findsOneWidget);
      expect(find.text('the import failed'), findsOneWidget);
      expect(find.text('Failed to import refs.'), findsOneWidget);
      expect(rig.registry.entry(git), isNull);
    });
  });

  group('failed opens made outside Projects (Ralph, 2026-11-01)', () {
    testWidgets('one reported while the window is up shows as its notice, with the reason and warnings', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      rig.session.reportFailedOpen(
        '${rig.home}/code/top',
        const ProjectOpenFailed(
          'jj.jj_lib_error',
          'the store is broken',
          warnings: <ZanshinWarning>[
            ZanshinWarning(code: 'jj.git_import_failed', message: 'Failed to import refs.'),
          ],
        ),
      );
      await tester.pump();
      expect(find.text('Could not open top'), findsOneWidget);
      expect(find.text('the store is broken'), findsOneWidget);
      expect(find.text('Failed to import refs.'), findsOneWidget);
      expect(rig.session.failedOpen.value, isNull, reason: 'taken: shown once');
    });

    testWidgets('a pending one shows when the window mounts; a missing folder says so', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.pumpWidget(const SizedBox());
      rig.session.reportFailedOpen('${rig.home}/code/gone', const ProjectNotARepo(RepoKind.pathNotFound));
      await rig.showIn(const ZsAppearance());
      expect(find.text('${rig.home}/code/gone does not exist.'), findsOneWidget);
      expect(rig.session.failedOpen.value, isNull);
    });
  });

  group('drops', () {
    testWidgets(
      'folders dropped on a group: the jj one registered inside, the Git one offered, the listed one skipped',
      (
        tester,
      ) async {
        final rig = _Rig(tester);
        await rig.pump();
        final jj = '${rig.home}/dropped-jj';
        final git = '${rig.home}/dropped-git';
        final listed = '${rig.home}/code/top';
        rig.repos.detections[git] = const RepoDetectResult(kind: RepoKind.git);
        final Offset mobile = tester.getCenter(rig.row('MOBILE'));
        final int view = tester.view.viewId;

        expect(find.text('Drop to add directory'), findsNothing);
        shell.folderDragHandler!(FolderDragEntered(viewId: view, position: mobile, paths: <String>[jj, git, listed]));
        await tester.pump();
        expect(find.text('Drop to add directory'), findsOneWidget, reason: 'the hint shows only during a drag');
        expect(rig.row('MOBILE'), paints..drrect(color: ZsColors.of(tester.element(rig.row('MOBILE'))).accentLiveLine));

        shell.folderDragHandler!(FolderDropped(viewId: view, position: mobile, paths: <String>[jj, git, listed]));
        await rig.settle(() => find.text('Convert dropped-git to a jj repository?').evaluate().isNotEmpty);
        await rig.sheetIn();
        expect(find.text('Drop to add directory'), findsNothing);
        expect(rig.registry.entry(jj)!.group, 'g2');
        expect(rig.session.current, isNull, reason: 'several folders are registered, not opened');
        expect(find.text('Convert dropped-git to a jj repository?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await rig.sheetOut();
        expect(rig.repos.log, <String>['detect $jj', 'detect $git'], reason: 'the listed folder is skipped');
        expect(rig.registry.value.projects.where((project) => project.path == listed), hasLength(1));
      },
    );

    testWidgets('one jj folder dropped between rows opens there; a drag that leaves hides the hint', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final jj = '${rig.home}/one';
      final Rect top = tester.getRect(rig.row('top'));
      final int view = tester.view.viewId;

      shell.folderDragHandler!(
        FolderDragEntered(viewId: view, position: top.topCenter + const Offset(0, 2), paths: <String>[jj]),
      );
      await tester.pump();
      final Color line = ZsColors.of(tester.element(rig.row('top'))).accentLiveLine;
      expect(
        rig.row('top'),
        paints..something(
          (method, arguments) => method == #drawRRect && (arguments[1] as Paint).color.toARGB32() == line.toARGB32(),
        ),
      );
      shell.folderDragHandler!(FolderDragExited(viewId: view));
      await tester.pump();
      expect(find.text('Drop to add directory'), findsNothing);

      shell.folderDragHandler!(
        FolderDropped(viewId: view, position: top.topCenter + const Offset(0, 2), paths: <String>[jj]),
      );
      await rig.settle(() => rig.session.current != null);
      expect(rig.session.current?.path, jj);
      expect(rig.registry.entry(jj)!.order, 1, reason: 'before top at the top level');
      expect(rig.registry.entry('${rig.home}/code/top')!.order, 2);
    });

    testWidgets('a row dragged onto a group moves into it; a group never moves into itself', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();

      await tester.timedDragFrom(
        tester.getCenter(rig.row('top')),
        tester.getCenter(rig.row('MOBILE')) - tester.getCenter(rig.row('top')),
        const Duration(milliseconds: 300),
      );
      await rig.settle(() => rig.registry.entry('${rig.home}/code/top')!.group == 'g2');
      expect(rig.registry.entry('${rig.home}/code/top')!.order, 2, reason: 'last inside Mobile');

      final ProjectsSettings before = rig.registry.value;
      await tester.timedDragFrom(
        tester.getCenter(rig.row('WORK')),
        tester.getCenter(rig.row('MOBILE')) - tester.getCenter(rig.row('WORK')),
        const Duration(milliseconds: 300),
      );
      await tester.pump();
      expect(rig.registry.value, before);
    });

    testWidgets('folders dropped together keep their order; a confirmed offer reports its open after the batch', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final a = '${rig.home}/a';
      final git = '${rig.home}/git';
      final b = '${rig.home}/b';
      rig.repos.detections[git] = const RepoDetectResult(kind: RepoKind.git);
      bool? bRegisteredAtOpen;
      rig.whenOpened = (_) => bRegisteredAtOpen = rig.registry.entry(b) != null;
      final Offset beforeTop = tester.getRect(rig.row('top')).topCenter + const Offset(0, 2);
      final int view = tester.view.viewId;

      shell.folderDragHandler!(FolderDragEntered(viewId: view, position: beforeTop, paths: <String>[a, git, b]));
      await tester.pump();
      shell.folderDragHandler!(FolderDropped(viewId: view, position: beforeTop, paths: <String>[a, git, b]));
      await rig.settle(() => find.text('Convert git to a jj repository?').evaluate().isNotEmpty);
      await rig.sheetIn();
      expect(rig.opened, isEmpty);
      await tester.tap(find.text('Convert'));
      await rig.settle(() => rig.session.current != null);
      await rig.sheetOut();
      await rig.settle(() => rig.registry.entry(b) != null && rig.opened.isNotEmpty);

      expect(
        <String, int>{
          for (final String path in <String>[a, git, b, '${rig.home}/code/top'])
            path.substring(rig.home.length + 1): rig.registry.entry(path)!.order,
        },
        <String, int>{'a': 1, 'git': 2, 'b': 3, 'code/top': 4},
      );
      expect(rig.opened, hasLength(1));
      expect(bRegisteredAtOpen, isTrue, reason: 'onOpened runs once the whole batch is through');
      expect(rig.session.current?.path, git, reason: 'the converted repository opens, as Convert always does');
    });

    testWidgets('a folder dropped on an empty Projects window lands at the top level and opens', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(demo: false);
      final path = '${rig.home}/first';
      final Offset middle = tester.getCenter(rig.id('projects-tree'));
      final int view = tester.view.viewId;

      shell.folderDragHandler!(FolderDragEntered(viewId: view, position: middle, paths: <String>[path]));
      await tester.pump();
      expect(find.text('Drop to add directory'), findsOneWidget);
      shell.folderDragHandler!(FolderDropped(viewId: view, position: middle, paths: <String>[path]));
      await rig.settle(() => rig.session.current != null);

      expect(rig.repos.log, <String>['detect $path', 'open $path', 'read $path']);
      expect(rig.registry.entry(path), isA<ProjectEntry>().having((e) => e.group, 'group', isNull));
      expect(find.text('Drop to add directory'), findsNothing);
    });

    testWidgets('a row dragged before another takes its place; below the last row it goes last at the top level', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final top = '${rig.home}/code/top';
      final gone = '${rig.home}/code/gone';
      final myApp = '${rig.home}/code/work/mobile/myapp';

      await tester.timedDragFrom(
        tester.getCenter(rig.row('gone')),
        tester.getRect(rig.row('top')).topCenter + const Offset(0, 6) - tester.getCenter(rig.row('gone')),
        const Duration(milliseconds: 300),
      );
      await rig.settle(() => rig.registry.entry(gone)!.order == 1);
      expect(rig.registry.entry(top)!.order, 2);

      final Offset below = tester.getRect(rig.row('top')).bottomCenter + const Offset(0, 20);
      await tester.timedDragFrom(
        tester.getCenter(rig.row('MyApp')),
        below - tester.getCenter(rig.row('MyApp')),
        const Duration(milliseconds: 300),
      );
      await rig.settle(() => rig.registry.entry(myApp)!.group == null);
      expect(rig.registry.entry(myApp)!.order, 3, reason: 'after Work, gone and top');
    });
  });

  group('the ••• menu', () {
    Future<void> openMenu(WidgetTester tester, _Rig rig, int row) async {
      await tester.tap(rig.id('projects-row-$row-more'));
      await tester.pump();
      await tester.pump(_m.durMenu);
    }

    Future<void> choose(WidgetTester tester, String identifier) async {
      await tester.tap(find.bySemanticsIdentifier(identifier));
      await tester.pump(_m.durBlink * 2);
      await tester.pump(_m.durExit);
      await tester.pump();
    }

    testWidgets('Reveal in Finder asks the environment; Remove from list takes only the entry out', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final path = '${rig.home}/code/top';

      await openMenu(tester, rig, 5);
      await choose(tester, 'projects-menu-reveal');
      expect(rig.env.revealed, <String>[path]);

      await openMenu(tester, rig, 5);
      await choose(tester, 'projects-menu-remove');
      await rig.sheetIn();
      expect(find.text('Remove top from the list?'), findsOneWidget);
      final Finder body = find.text('~/code/top stays on disk; only the list forgets it.', findRichText: true);
      expect(body, findsOneWidget);
      TextSpan? pathSpan;
      tester.widget<RichText>(body).text.visitChildren((span) {
        if (span is TextSpan && span.text == '~/code/top') {
          pathSpan = span;
        }
        return pathSpan == null;
      });
      expect(pathSpan?.style?.fontFamily, ZsType.id.fontFamily, reason: 'the path stays mono');
      await tester.tap(find.descendant(of: rig.id('projects-question'), matching: find.text('Cancel')));
      await rig.sheetOut();
      expect(rig.registry.entry(path), isNotNull, reason: 'Cancel changes nothing');

      await openMenu(tester, rig, 5);
      await choose(tester, 'projects-menu-remove');
      await rig.answer('Remove');
      await rig.settle(() => rig.registry.entry(path) == null);
      expect(find.text('top'), findsNothing);
      expect(rig.registry.entry('${rig.home}/code/gone')!.order, 1, reason: 'its siblings renumbered');
    });

    testWidgets('Move to group › moves the project; Open opens it', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final path = '${rig.home}/code/top';

      await openMenu(tester, rig, 5);
      await tester.tap(find.bySemanticsIdentifier('projects-menu-move'));
      await tester.pump();
      await tester.pump(_m.durMenu);
      expect(find.text('Work / Mobile'), findsOneWidget);
      await choose(tester, 'projects-menu-move-g1');
      await rig.settle(() => rig.registry.entry(path)!.group == 'g1');

      final int index = rig.repos.log.length;
      await tester.tap(find.text('top'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(_m.durMenu);
      await choose(tester, 'projects-menu-open');
      await rig.settle(() => rig.session.current?.path == path);
      expect(rig.repos.log.sublist(index).first, 'detect $path');
    });

    testWidgets('Open and Reveal are disabled for a missing project, Remove for the open one', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.runAsync(() => rig.session.open('${rig.home}/code/top'));
      await tester.pump();

      await openMenu(tester, rig, 6);
      expect(tester.getSemantics(find.bySemanticsIdentifier('projects-menu-open')), isSemantics(isEnabled: false));
      expect(tester.getSemantics(find.bySemanticsIdentifier('projects-menu-reveal')), isSemantics(isEnabled: false));
      expect(tester.getSemantics(find.bySemanticsIdentifier('projects-menu-remove')), isSemantics(isEnabled: true));
      await rig.key(LogicalKeyboardKey.escape);
      await tester.pump(_m.durExit);

      await openMenu(tester, rig, 5);
      expect(tester.getSemantics(find.bySemanticsIdentifier('projects-menu-remove')), isSemantics(isEnabled: false));
    });

    testWidgets('a double-click opens a project; a missing one does not', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();

      await tester.tap(find.text('gone'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('gone'));
      await tester.pump();
      expect(rig.repos.log, isEmpty);

      await tester.pump(kDoubleTapTimeout);
      await tester.tap(find.text('top'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('top'));
      await rig.settle(() => rig.session.current != null);
      expect(rig.session.current?.path, '${rig.home}/code/top');
    });
  });

  group('New group', () {
    testWidgets('↩ creates the group inside the selected group; Esc or an empty name cancels', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Finder field = find.descendant(of: rig.id('projects-new-group-name'), matching: find.byType(EditableText));

      await tester.tap(rig.id('projects-new-group'));
      await tester.pump();
      await tester.pump();
      expect(field, findsOneWidget);
      await rig.key(LogicalKeyboardKey.escape);
      expect(field, findsNothing);

      await tester.tap(rig.id('projects-new-group'));
      await tester.pump();
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(field, findsNothing, reason: 'an empty name cancels');
      expect(rig.registry.value.groups, hasLength(2));

      await tester.tap(find.text('WORK'));
      await tester.pump();
      await tester.tap(rig.id('projects-new-group'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(field, 'Clients');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await rig.settle(() => rig.registry.value.groups.length == 3);
      expect(rig.registry.value.groups.last, const ProjectGroup(id: 'g3', name: 'Clients', parent: 'g1', order: 2));
      expect(find.text('CLIENTS'), findsOneWidget);
    });

    testWidgets('switching to another app keeps the name being typed', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      addTearDown(() => tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
      final Finder field = find.descendant(of: rig.id('projects-new-group-name'), matching: find.byType(EditableText));

      await tester.tap(rig.id('projects-new-group'));
      await tester.pump();
      await tester.pump();
      await tester.enterText(field, 'Clients');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(field, findsOneWidget, reason: 'the field stays while the app is in the background');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(field, findsOneWidget);
      expect(tester.widget<EditableText>(field).controller.text, 'Clients');
      expect(FocusManager.instance.primaryFocus?.debugLabel, 'projects group name', reason: 'focus came back to it');
      // macOS: Flutter's FocusManager parks focus at the root while the app is inactive (focus_manager.dart).
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));
  });

  group('Story 11.15', () {
    Future<void> openMenu(WidgetTester tester, _Rig rig, int row) async {
      await tester.tap(rig.id('projects-row-$row-more'));
      await tester.pump();
      await tester.pump(_m.durMenu);
    }

    Future<void> openSubmenu(WidgetTester tester) async {
      await tester.tap(find.bySemanticsIdentifier('projects-menu-move'));
      await tester.pump();
      await tester.pump(_m.durMenu);
    }

    Future<void> choose(WidgetTester tester, String identifier) async {
      await tester.tap(find.bySemanticsIdentifier(identifier));
      await tester.pump(_m.durBlink * 2);
      await tester.pump(_m.durExit);
      await tester.pump();
    }

    Matcher selected(bool value) => isSemantics(isSelected: value);

    ProjectsTreeState tree(WidgetTester tester) => tester.state<ProjectsTreeState>(find.byType(ProjectsTree));

    /// Presses a mouse on [from] and moves it a little, so the row's drag starts.
    Future<TestGesture> grab(WidgetTester tester, Offset from) async {
      final TestGesture gesture = await tester.startGesture(from, kind: PointerDeviceKind.mouse);
      await gesture.moveBy(const Offset(0, 4));
      await tester.pump();
      return gesture;
    }

    Future<void> hoverAt(WidgetTester tester, TestGesture gesture, Offset to) async {
      await gesture.moveTo(to);
      await tester.pump();
      await gesture.moveTo(to + const Offset(1, 0));
      await tester.pump();
    }

    String? ghostText(WidgetTester tester) {
      final Finder text = find.descendant(of: find.byType(ZsDragGhost), matching: find.byType(Text));
      return text.evaluate().length < 2 ? null : tester.widget<Text>(text.last).data;
    }

    testWidgets('a click below the last row deselects; New group then lands at the end of the top level', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(find.text('top'));
      await tester.pump(kDoubleTapTimeout);
      expect(tester.getSemantics(rig.id('projects-row-5')), selected(true));

      await tester.tapAt(tester.getRect(rig.row('gone')).bottomCenter + const Offset(0, 30));
      await tester.pump();
      expect(tester.getSemantics(rig.id('projects-row-5')), selected(false));
      tree(tester).focusTabStop();
      await tester.pump();
      expect(rig.focused, 'projects row group:g1', reason: 'the Tab stop is the first row');

      await tester.tap(find.text('gone'));
      await tester.pump(kDoubleTapTimeout);
      await tester.tapAt(tester.getRect(rig.row('gone')).bottomCenter + const Offset(0, 30));
      await tester.pump();
      await tester.tap(rig.id('projects-new-group'));
      await tester.pump();
      await tester.pump();
      final Finder field = find.descendant(of: rig.id('projects-new-group-name'), matching: find.byType(EditableText));
      expect(tester.getTopLeft(field).dy, greaterThan(tester.getBottomLeft(rig.row('gone')).dy));
      await tester.enterText(field, 'Last');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await rig.settle(() => rig.registry.value.groups.length == 3);
      expect(rig.registry.value.groups.last, const ProjectGroup(id: 'g3', name: 'Last', order: 3));
    });

    testWidgets('with a project inside a group selected, New group goes into that group', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(find.text('MyApp'));
      await tester.pump(kDoubleTapTimeout);
      await tester.tap(rig.id('projects-new-group'));
      await tester.pump();
      await tester.pump();
      final Finder field = find.descendant(of: rig.id('projects-new-group-name'), matching: find.byType(EditableText));
      expect(tester.getTopLeft(field).dy, greaterThan(tester.getBottomLeft(rig.row('design-kit')).dy));
      expect(tester.getTopLeft(field).dy, lessThan(tester.getTopLeft(rig.row('api-server')).dy));
      await tester.enterText(field, 'X');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await rig.settle(
        () =>
            find.ancestor(of: find.text('X'), matching: find.byType(ZsControlCore)).evaluate().isNotEmpty &&
            selected(true).matches(tester.getSemantics(rig.row('X')), <Object?, Object?>{}),
      );
      expect(rig.registry.value.groups.last, const ProjectGroup(id: 'g3', name: 'X', parent: 'g2', order: 2));
    });

    testWidgets('a group row shows ••• on hover; a right-click selects it and opens its menu', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      double more() => tester
          .widget<AnimatedOpacity>(
            find.descendant(of: rig.id('projects-row-1-more'), matching: find.byType(AnimatedOpacity)),
          )
          .opacity;
      expect(more(), 0);
      final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(rig.row('MOBILE')));
      await tester.pump();
      expect(more(), 1);
      await mouse.moveTo(Offset.zero);
      await tester.pump();

      await tester.tap(find.text('MOBILE'), buttons: kSecondaryButton);
      await tester.pump();
      await tester.pump(_m.durMenu);
      expect(tester.getSemantics(rig.id('projects-row-1')), selected(true));
      expect(find.bySemanticsIdentifier('projects-menu-rename'), findsOneWidget);
      expect(find.bySemanticsIdentifier('projects-menu-delete'), findsOneWidget);
      expect(find.bySemanticsIdentifier('projects-menu-open'), findsNothing);
    });

    testWidgets('Rename…: ↩ and a click elsewhere keep the new name; Esc and an empty name keep the old one', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Finder field = find.descendant(
        of: rig.id('projects-rename-group-name'),
        matching: find.byType(EditableText),
      );
      Future<void> rename() async {
        await openMenu(tester, rig, 0);
        await choose(tester, 'projects-menu-rename');
        await tester.pump();
      }

      final double mobileTop = tester.getTopLeft(rig.row('MOBILE')).dy;
      await rename();
      expect(field, findsOneWidget);
      expect(
        tester.getTopLeft(rig.row('MOBILE')).dy - mobileTop,
        ProjectsTree.newGroupHeight - ProjectsTree.groupHeight,
        reason: 'the row is the 34 high field row',
      );
      final TextEditingValue value = tester.widget<EditableText>(field).controller.value;
      expect(value.text, 'Work');
      expect(value.selection, const TextSelection(baseOffset: 0, extentOffset: 4), reason: 'the name selected');
      await rig.key(LogicalKeyboardKey.escape);
      expect(field, findsNothing);
      expect(rig.registry.group('g1')!.name, 'Work');

      await rename();
      await tester.enterText(field, '  ');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(field, findsNothing);
      expect(rig.registry.group('g1')!.name, 'Work', reason: 'an empty name keeps the old one');

      await rename();
      await tester.enterText(field, 'Clients');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await rig.settle(() => rig.registry.group('g1')!.name == 'Clients');
      expect(find.text('CLIENTS'), findsOneWidget);

      await rename();
      await tester.enterText(field, 'Agency');
      // A mouse click outside a text field unfocuses it (EditableText's tap-outside action).
      await tester.tap(find.text('top'), kind: PointerDeviceKind.mouse);
      await rig.settle(() => rig.registry.group('g1')!.name == 'Agency');
      expect(field, findsNothing, reason: 'a click elsewhere keeps what was typed');
    });

    testWidgets('Delete group puts what it holds in its place, in order, and clears the selection', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Set<String> paths = rig.registry.value.projects.map((project) => project.path).toSet();
      await openMenu(tester, rig, 0);
      await choose(tester, 'projects-menu-delete');
      await rig.sheetIn();
      expect(find.text('Delete the group Work?'), findsOneWidget);
      await tester.tap(find.descendant(of: rig.id('projects-question'), matching: find.text('Cancel')));
      await rig.sheetOut();
      expect(rig.registry.group('g1'), isNotNull, reason: 'Cancel changes nothing');

      await openMenu(tester, rig, 0);
      await choose(tester, 'projects-menu-delete');
      await rig.answer('Delete group');
      await rig.settle(() => rig.registry.group('g1') == null);

      final ProjectsSettings value = rig.registry.value;
      expect(rig.registry.group('g2')!.parent, isNull);
      expect(rig.registry.group('g2')!.order, 0);
      expect(
        rig.registry.entry('${rig.home}/code/work/api-server'),
        isA<ProjectEntry>().having((e) => e.order, 'order', 1),
      );
      expect(rig.registry.entry('${rig.home}/code/top')!.order, 2);
      expect(rig.registry.entry('${rig.home}/code/gone')!.order, 3);
      expect(value.projects.map((project) => project.path).toSet(), paths);
      for (var i = 0; i < 6; i++) {
        expect(tester.getSemantics(rig.id('projects-row-$i')), selected(false));
      }
    });

    testWidgets('an empty group opens and closes like any other (Ralph, 2026-10-29)', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.runAsync(() => rig.registry.addGroup('Empty'));
      await tester.pump();
      Matcher open(bool expanded) => isSemantics(isExpanded: expanded, hasExpandedState: true);
      expect(tester.getSemantics(rig.row('EMPTY')), open(true), reason: 'open by default, showing it holds nothing');
      await tester.tap(rig.row('EMPTY'));
      await tester.pump();
      expect(tester.getSemantics(rig.row('EMPTY')), open(false));
      await tester.tap(rig.row('EMPTY'));
      await tester.pump();
      expect(tester.getSemantics(rig.row('EMPTY')), open(true));
    });

    testWidgets('Move to group › of a group lists neither itself nor what it holds; its place is checked', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      await openMenu(tester, rig, 1);
      await openSubmenu(tester);
      expect(find.text('Work / Mobile'), findsNothing);
      expect(tester.getSemantics(find.bySemanticsIdentifier('projects-menu-move-top')), isSemantics(isChecked: false));
      expect(tester.getSemantics(find.bySemanticsIdentifier('projects-menu-move-g1')), isSemantics(isChecked: true));
      expect(find.bySemanticsIdentifier('projects-menu-move-new'), findsOneWidget);

      final ProjectsSettings before = rig.registry.value;
      await choose(tester, 'projects-menu-move-g1');
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(rig.registry.value, before, reason: 'the current place changes nothing');

      await openMenu(tester, rig, 1);
      await openSubmenu(tester);
      await choose(tester, 'projects-menu-move-top');
      await rig.settle(() => rig.registry.group('g2')!.parent == null);
      expect(tester.getSemantics(rig.row('MOBILE')), selected(true), reason: 'the moved row ends selected');
    });

    testWidgets('New group… on a project: Esc changes nothing; ↩ creates the group around it, selected', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final top = '${rig.home}/code/top';
      final Finder field = find.descendant(of: rig.id('projects-new-group-name'), matching: find.byType(EditableText));
      final ProjectsSettings before = rig.registry.value;

      await openMenu(tester, rig, 5);
      await openSubmenu(tester);
      await choose(tester, 'projects-menu-move-new');
      await tester.pump();
      expect(field, findsOneWidget);
      expect(tester.getTopLeft(field).dy, greaterThan(tester.getBottomLeft(rig.row('gone')).dy));
      await rig.key(LogicalKeyboardKey.escape);
      expect(field, findsNothing);
      expect(rig.registry.value, before);

      await openMenu(tester, rig, 5);
      await openSubmenu(tester);
      await choose(tester, 'projects-menu-move-new');
      await tester.pump();
      await tester.enterText(field, 'Mobile2');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await rig.settle(() => rig.registry.entry(top)!.group == 'g3');
      expect(rig.registry.group('g3'), const ProjectGroup(id: 'g3', name: 'Mobile2', order: 2));
      expect(rig.registry.entry(top)!.order, 0);
      expect(tester.getSemantics(rig.row('top')), selected(true));
    });

    testWidgets('no drag starts while searching', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.enterText(find.descendant(of: rig.id('projects-search'), matching: find.byType(EditableText)), 'o');
      await tester.pump();
      final ProjectsSettings before = rig.registry.value;
      final TestGesture gesture = await grab(tester, tester.getCenter(rig.row('top')));
      await hoverAt(tester, gesture, tester.getCenter(rig.row('MOBILE')));
      expect(find.byType(ZsDragGhost), findsNothing);
      await gesture.up();
      await tester.pump();
      expect(rig.registry.value, before);
    });

    testWidgets('Esc during a drag hides the ghost and the drop look and keeps the order', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final ProjectsSettings before = rig.registry.value;
      final TestGesture gesture = await grab(tester, tester.getCenter(rig.row('gone')));
      await hoverAt(tester, gesture, tester.getRect(rig.row('top')).topCenter + const Offset(0, 6));
      expect(ghostText(tester), _en.treeTopLevel);
      expect(tree(tester).dropHover?.placement, TreeDropPlacement.before);
      final String? focusedBefore = rig.focused;

      double goneOpacity() => tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.descendant(of: find.byType(ProjectsTree), matching: find.text('gone')),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      expect(goneOpacity(), .4);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(ZsDragGhost), findsNothing);
      expect(tree(tester).dropHover, isNull);
      expect(rig.focused, focusedBefore);
      expect(goneOpacity(), 1, reason: 'the row in hand is back once Esc cancelled the drag');
      await hoverAt(tester, gesture, tester.getRect(rig.row('top')).topCenter + const Offset(0, 8));
      expect(tree(tester).dropHover, isNull);
      await gesture.up();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(rig.registry.value, before);
    });

    testWidgets('the ghost names the destination; below the last row is the end of the top level', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final myApp = '${rig.home}/code/work/mobile/myapp';
      final gone = '${rig.home}/code/gone';
      final TestGesture gesture = await grab(tester, tester.getCenter(rig.row('MyApp')));
      expect(find.byType(ZsDragGhost), findsOneWidget);
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.descendant(of: find.byType(ProjectsTree), matching: find.text('MyApp')),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        .4,
      );

      final Rect work = tester.getRect(rig.row('WORK'));
      await hoverAt(tester, gesture, Offset(work.center.dx, work.top + work.height * .85));
      expect(ghostText(tester), 'Into Work', reason: 'an expanded group with children: its lower part is inside');
      expect(tree(tester).dropHover?.placement, TreeDropPlacement.inside);
      expect(
        rig.row('WORK'),
        paints..drrect(color: ZsColors.of(tester.element(rig.row('WORK'))).accentLiveLine),
      );

      await hoverAt(tester, gesture, tester.getRect(rig.row('gone')).topCenter + const Offset(0, 6));
      expect(ghostText(tester), _en.treeTopLevel, reason: 'between top and gone');

      await hoverAt(tester, gesture, tester.getRect(rig.row('gone')).bottomCenter + const Offset(0, 30));
      expect(ghostText(tester), _en.treeTopLevel, reason: 'below the last row');
      expect(tree(tester).dropHover, (id: 'project:$gone', placement: TreeDropPlacement.after, depth: 0));
      await gesture.up();
      await rig.settle(() => rig.registry.entry(myApp)!.group == null);
      expect(rig.registry.entry(myApp)!.order, 3, reason: 'last at the top level');
      expect(tester.getSemantics(rig.row('MyApp')), selected(true), reason: 'the moved row ends selected');
    });

    testWidgets('over the dragged group’s own subtree the ghost gives the hint and a drop changes nothing', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final ProjectsSettings before = rig.registry.value;
      final TestGesture gesture = await grab(tester, tester.getCenter(rig.row('WORK')));
      await hoverAt(tester, gesture, tester.getCenter(rig.row('MyApp')));
      expect(ghostText(tester), _en.treeDropHint);
      expect(tree(tester).dropHover, isNull);
      await gesture.up();
      await tester.pump();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump();
      expect(rig.registry.value, before);
    });

    testWidgets('the top quarter of an expanded group with children drops before it', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final gone = '${rig.home}/code/gone';
      final TestGesture gesture = await grab(tester, tester.getCenter(rig.row('gone')));
      await hoverAt(tester, gesture, tester.getRect(rig.row('WORK')).topCenter + const Offset(0, 4));
      expect(tree(tester).dropHover?.placement, TreeDropPlacement.before);
      expect(ghostText(tester), _en.treeTopLevel);
      await gesture.up();
      await rig.settle(() => rig.registry.entry(gone)!.group == null && rig.registry.entry(gone)!.order == 0);
    });

    testWidgets('a row moved into a collapsed group expands it and ends selected', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final top = '${rig.home}/code/top';
      await tester.tap(find.text('MOBILE'));
      await tester.pump();
      expect(find.text('MyApp'), findsNothing, reason: 'Mobile collapsed');

      await openMenu(tester, rig, 3);
      await openSubmenu(tester);
      await choose(tester, 'projects-menu-move-g2');
      await rig.settle(() => rig.registry.entry(top)!.group == 'g2');
      expect(find.text('MyApp'), findsOneWidget, reason: 'Mobile expanded');
      expect(tester.getSemantics(rig.row('top')), selected(true));
    });

    testWidgets('New group… on a group: the field last in its group; ↩ puts the group into the new one', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      final Finder field = find.descendant(of: rig.id('projects-new-group-name'), matching: find.byType(EditableText));
      await openMenu(tester, rig, 1);
      await openSubmenu(tester);
      await choose(tester, 'projects-menu-move-new');
      await tester.pump();
      expect(tester.getTopLeft(field).dy, greaterThan(tester.getBottomLeft(rig.row('api-server')).dy));
      expect(tester.getTopLeft(field).dy, lessThan(tester.getTopLeft(rig.row('top')).dy));

      await tester.enterText(field, 'Phones');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await rig.settle(() => rig.registry.group('g2')!.parent == 'g3');
      // Last in Work (after api-server, once Mobile has left it).
      expect(rig.registry.group('g3'), const ProjectGroup(id: 'g3', name: 'Phones', parent: 'g1', order: 1));
      expect(rig.registry.group('g2')!.order, 0);
      expect(tester.getSemantics(rig.row('MOBILE')), selected(true));
    });

    testWidgets('a drag released on a group does not toggle it; the moved row is selected', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      final top = '${rig.home}/code/top';
      final TestGesture gesture = await grab(tester, tester.getCenter(rig.row('top')));
      await hoverAt(tester, gesture, tester.getCenter(rig.row('MOBILE')));
      expect(ghostText(tester), 'Into Mobile');
      await gesture.up();
      await rig.settle(() => rig.registry.entry(top)!.group == 'g2');
      expect(find.text('MyApp'), findsOneWidget, reason: 'Mobile stays expanded');
      expect(tester.getSemantics(rig.row('top')), selected(true));
    });

    group('closing — focus', () {
      Finder nameField(_Rig rig, String identifier) =>
          find.descendant(of: rig.id(identifier), matching: find.byType(EditableText));

      void expectNothingSelected(WidgetTester tester, _Rig rig) {
        var checked = 0;
        for (var i = 0; i < rig.registry.value.groups.length + rig.registry.value.projects.length; i++) {
          if (rig.id('projects-row-$i').evaluate().isNotEmpty) {
            expect(tester.getSemantics(rig.id('projects-row-$i')), selected(false), reason: 'row $i');
            checked++;
          }
        }
        expect(checked, greaterThan(0), reason: 'no row was checked');
        expect(tester.widget<ProjectsTree>(find.byType(ProjectsTree)).selected, isNull, reason: 'rows not built too');
      }

      testWidgets('Rename… ↩: focus on the renamed row, still selected', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await openMenu(tester, rig, 0);
        await choose(tester, 'projects-menu-rename');
        await tester.pump();
        expect(rig.focused, 'projects group name');
        await tester.enterText(nameField(rig, 'projects-rename-group-name'), 'Clients');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await rig.settle(() => rig.registry.group('g1')!.name == 'Clients');
        await tester.pump();
        expect(rig.focused, 'projects row group:g1');
        expect(tester.getSemantics(rig.row('CLIENTS')), selected(true));
      });

      testWidgets('Rename… Esc: focus on the row, its name kept', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await openMenu(tester, rig, 0);
        await choose(tester, 'projects-menu-rename');
        await tester.pump();
        await rig.key(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(rig.focused, 'projects row group:g1');
        expect(rig.registry.group('g1')!.name, 'Work');
        expect(tester.getSemantics(rig.row('WORK')), selected(true));
      });

      testWidgets('New group ↩: focus follows the selection to the new group once it exists', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.tap(find.text('MyApp'));
        await tester.pump(kDoubleTapTimeout);
        await tester.tap(rig.id('projects-new-group'));
        await tester.pump();
        await tester.pump();
        expect(rig.focused, 'projects group name');
        await tester.enterText(nameField(rig, 'projects-new-group-name'), 'X');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await rig.settle(
          () =>
              find.ancestor(of: find.text('X'), matching: find.byType(ZsControlCore)).evaluate().isNotEmpty &&
              selected(true).matches(tester.getSemantics(rig.row('X')), <Object?, Object?>{}),
        );
        await tester.pump();
        expect(rig.focused, 'projects row group:g3');
        expect(tester.getSemantics(rig.row('MyApp')), selected(false));
      });

      testWidgets('New group Esc without a selection: focus on the first row, nothing selected', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.tapAt(tester.getRect(rig.row('gone')).bottomCenter + const Offset(0, 30));
        await tester.pump();
        await tester.tap(rig.id('projects-new-group'));
        await tester.pump();
        await tester.pump();
        expect(rig.focused, 'projects group name');
        await rig.key(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(nameField(rig, 'projects-new-group-name'), findsNothing);
        expect(rig.focused, 'projects row group:g1');
        expectNothingSelected(tester, rig);
      });

      testWidgets('New group… ↩: focus and selection on the moved row inside the new group', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        final top = '${rig.home}/code/top';
        await openMenu(tester, rig, 5);
        await openSubmenu(tester);
        await choose(tester, 'projects-menu-move-new');
        await tester.pump();
        expect(rig.focused, 'projects group name');
        await tester.enterText(nameField(rig, 'projects-new-group-name'), 'Mobile2');
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await rig.settle(() => rig.registry.entry(top)!.group == 'g3');
        await tester.pump();
        expect(rig.focused, 'projects row project:$top');
        expect(tester.getSemantics(rig.row('top')), selected(true));
      });

      testWidgets('Delete group by keyboard: focus on the first row, nothing selected on the way', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await rig.focusSearch();
        await rig.key(LogicalKeyboardKey.arrowDown);
        await rig.key(LogicalKeyboardKey.arrowDown);
        await rig.key(LogicalKeyboardKey.arrowDown);
        await rig.key(LogicalKeyboardKey.arrowUp);
        await rig.key(LogicalKeyboardKey.arrowUp);
        expect(rig.focused, 'projects row group:g1');
        await rig.key(LogicalKeyboardKey.tab);
        expect(rig.focused, 'projects more group:g1');
        await rig.key(LogicalKeyboardKey.enter);
        await tester.pump(_m.durMenu);
        expect(find.bySemanticsIdentifier('projects-menu-delete'), findsOneWidget);
        await rig.key(LogicalKeyboardKey.end);
        await rig.key(LogicalKeyboardKey.enter);
        await tester.pump(_m.durBlink * 2);
        await tester.pump(_m.durExit);
        await rig.confirmByKeys();
        await rig.settle(() => rig.registry.group('g1') == null);
        await tester.pump();
        expect(rig.focused, 'projects row group:g2');
        expectNothingSelected(tester, rig);
      });

      testWidgets('a click into the search closing New group keeps focus in the search', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.tap(rig.id('projects-new-group'));
        await tester.pump();
        await tester.pump();
        expect(rig.focused, 'projects group name');
        await tester.tap(nameField(rig, 'projects-search'), kind: PointerDeviceKind.mouse);
        await tester.pump();
        await tester.pump();
        expect(nameField(rig, 'projects-new-group-name'), findsNothing);
        expect(rig.focused, 'projects search');
      });

      testWidgets('a hand-back to a row scrolled out of the built range does not select it', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            await rig.registry.add('${rig.home}/code/extra$i');
          }
        });
        await tester.pump();
        final pointer = TestPointer(1, PointerDeviceKind.mouse);
        await tester.sendEventToBinding(pointer.hover(tester.getCenter(rig.row('top'))));
        await tester.sendEventToBinding(pointer.scroll(const Offset(0, 5000)));
        await tester.pump();
        expect(find.text('WORK'), findsNothing, reason: 'Work is not built');
        await tester.tap(rig.id('projects-new-group'));
        await tester.pump();
        await tester.pump();
        expect(rig.focused, 'projects group name');

        await rig.key(LogicalKeyboardKey.escape);
        await tester.pump();
        await tester.pump();
        expect(rig.focused, 'projects row group:g1');
        expectNothingSelected(tester, rig);
      });

      testWidgets('New group… chosen by keyboard during a search keeps focus in the new field', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.enterText(
          find.descendant(of: rig.id('projects-search'), matching: find.byType(EditableText)),
          'top',
        );
        await tester.pump();
        await rig.key(LogicalKeyboardKey.arrowDown);
        expect(rig.focused, 'projects row project:${rig.home}/code/top');
        await rig.key(LogicalKeyboardKey.tab);
        await rig.key(LogicalKeyboardKey.enter);
        await tester.pump(_m.durMenu);
        await rig.key(LogicalKeyboardKey.keyM);
        await rig.key(LogicalKeyboardKey.arrowRight);
        await tester.pump(_m.durMenu);
        await rig.key(LogicalKeyboardKey.end);
        await rig.key(LogicalKeyboardKey.enter);
        await tester.pump(_m.durBlink * 2);
        await tester.pump(_m.durExit);
        await tester.pump();
        expect(nameField(rig, 'projects-new-group-name'), findsOneWidget);
        expect(rig.focused, 'projects group name');
      });

      testWidgets('focus moved off the handed-back row does not follow a later selection', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.tap(rig.id('projects-new-group'));
        await tester.pump();
        await tester.pump();
        await rig.key(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(rig.focused, 'projects row group:g1');

        await tester.tap(nameField(rig, 'projects-search'), kind: PointerDeviceKind.mouse);
        await tester.pump();
        expect(rig.focused, 'projects search');
        final top = '${rig.home}/code/top';
        await tester.runAsync(() => rig.session.open(top));
        await rig.settle(() => selected(true).matches(tester.getSemantics(rig.row('top')), <Object?, Object?>{}));
        await tester.pump();
        expect(rig.focused, 'projects search');
      });

      testWidgets('Delete group far down a long list: focus on the first row, no row arrowed through selected', (
        tester,
      ) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            await rig.registry.add('${rig.home}/code/extra$i');
          }
          await rig.registry.addGroup('Last');
        });
        await tester.pump();
        await rig.focusSearch();
        await rig.key(LogicalKeyboardKey.arrowDown);
        await rig.key(LogicalKeyboardKey.end);
        await rig.key(LogicalKeyboardKey.arrowUp);
        await rig.key(LogicalKeyboardKey.arrowDown);
        expect(rig.focused, 'projects row group:g3');
        expect(find.text('WORK'), findsNothing, reason: 'the first row is not built');
        await rig.key(LogicalKeyboardKey.tab);
        await rig.key(LogicalKeyboardKey.enter);
        await tester.pump(_m.durMenu);
        await rig.key(LogicalKeyboardKey.end);
        await rig.key(LogicalKeyboardKey.enter);
        await tester.pump(_m.durBlink * 2);
        await tester.pump(_m.durExit);
        await rig.confirmByKeys();
        await rig.settle(() => rig.registry.group('g3') == null);
        await tester.pump();
        await tester.pump();
        expect(rig.focused, 'projects row group:g1');
        expectNothingSelected(tester, rig);
      });

      testWidgets('a focused row that is not selected keeps focus when a row lands above it', (tester) async {
        final rig = _Rig(tester);
        await rig.pump();
        await tester.tap(rig.id('projects-new-group'));
        await tester.pump();
        await tester.pump();
        await rig.key(LogicalKeyboardKey.escape);
        await tester.pump();
        expect(rig.focused, 'projects row group:g1');
        expectNothingSelected(tester, rig);

        final top = '${rig.home}/code/top';
        await tester.runAsync(() => rig.registry.move(top, index: 0));
        await tester.pump();
        await tester.pump();
        expect(rig.id('projects-row-0'), findsOneWidget);
        expect(find.descendant(of: rig.id('projects-row-0'), matching: find.text('top')), findsOneWidget);
        expect(rig.focused, 'projects row group:g1');
        expectNothingSelected(tester, rig);
      });
    });
  });

  group('Clone', () {
    testWidgets('the form pre-fills the destination; Clone is busy until the clone opens; its tooltip is the command', (
      tester,
    ) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(rig.id('projects-clone'));
      await tester.pump();
      final Finder url = find.descendant(of: rig.id('projects-clone-url'), matching: find.byType(EditableText));
      final Finder destination = find.descendant(
        of: rig.id('projects-clone-destination'),
        matching: find.byType(EditableText),
      );

      await tester.enterText(url, 'https://example.com/team/repo.git');
      await tester.pump();
      expect(tester.widget<EditableText>(destination).controller.text, '${rig.home}/repo');
      final ZsTooltip tooltip = tester.widget<ZsTooltip>(
        find.ancestor(of: rig.id('projects-clone-submit'), matching: find.byType(ZsTooltip)).first,
      );
      expect(tooltip.cmd, "jj git clone --no-colocate 'https://example.com/team/repo.git' '${rig.home}/repo'");

      rig.repos.cloneGate = Completer<void>();
      await tester.tap(rig.id('projects-clone-submit'));
      await tester.pump();
      expect(tester.widget<ZsButton>(find.widgetWithText(ZsButton, 'Clone')).busy, isTrue);
      expect(tester.widget<ZsTextField>(find.ancestor(of: url, matching: find.byType(ZsTextField))).enabled, isFalse);
      rig.repos.cloneGate!.complete();
      await rig.settle(() => rig.session.current != null);
      expect(rig.session.current?.path, '${rig.home}/repo');
      expect(Directory('${rig.home}/repo').existsSync(), isTrue);
      expect(rig.id('projects-clone-url'), findsNothing, reason: 'the form closes');
    });

    testWidgets('a destination that is not empty is refused with the CLI text, before any jj call', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      Directory('${rig.home}/repo').createSync();
      File('${rig.home}/repo/file').writeAsStringSync('');
      await tester.tap(rig.id('projects-clone'));
      await tester.pump();

      await tester.enterText(
        find.descendant(of: rig.id('projects-clone-url'), matching: find.byType(EditableText)),
        'https://example.com/repo',
      );
      await tester.pump();
      await tester.tap(rig.id('projects-clone-submit'));
      await tester.pump();
      await tester.pump();

      expect(find.text('Clone failed'), findsOneWidget);
      expect(find.text('Destination path exists and is not an empty directory'), findsOneWidget);
      expect(rig.repos.log, isEmpty);
      expect(rig.id('projects-clone-url'), findsOneWidget, reason: 'the form stays');
    });

    testWidgets('a URL without a name leaves the destination empty; ~ is the home folder', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(rig.id('projects-clone'));
      await tester.pump();
      final Finder url = find.descendant(of: rig.id('projects-clone-url'), matching: find.byType(EditableText));
      final Finder destination = find.descendant(
        of: rig.id('projects-clone-destination'),
        matching: find.byType(EditableText),
      );

      await tester.enterText(url, 'plain');
      await tester.pump();
      expect(tester.widget<EditableText>(destination).controller.text, isEmpty);
      expect(tester.widget<ZsButton>(find.widgetWithText(ZsButton, 'Clone')).onPressed, isNull);

      await tester.enterText(destination, '~/elsewhere/repo');
      await tester.enterText(url, 'https://example.com/repo.git');
      await tester.pump();
      final ZsTooltip tooltip = tester.widget<ZsTooltip>(
        find.ancestor(of: rig.id('projects-clone-submit'), matching: find.byType(ZsTooltip)).first,
      );
      expect(tooltip.cmd, "jj git clone --no-colocate 'https://example.com/repo.git' '${rig.home}/elsewhere/repo'");
      await tester.tap(rig.id('projects-clone-submit'));
      await rig.settle(() => rig.session.current != null);
      expect(rig.repos.log.first, 'clone https://example.com/repo.git ${rig.home}/elsewhere/repo');
    });

    testWidgets('a clone lands in the selected group; Clone… is disabled while it runs', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.tap(find.text('MOBILE'));
      await tester.pump();
      await tester.tap(rig.id('projects-clone'));
      await tester.pump();
      await tester.enterText(
        find.descendant(of: rig.id('projects-clone-url'), matching: find.byType(EditableText)),
        'https://example.com/repo.git',
      );
      await tester.pump();

      rig.repos.cloneGate = Completer<void>();
      await tester.tap(rig.id('projects-clone-submit'));
      await tester.pump();
      expect(tester.getSemantics(rig.id('projects-clone')), isSemantics(isEnabled: false));
      await tester.tap(rig.id('projects-clone'), warnIfMissed: false);
      await tester.pump();
      expect(rig.id('projects-clone-url'), findsOneWidget, reason: 'the running clone keeps its form');

      rig.repos.cloneGate!.complete();
      await rig.settle(() => rig.session.current != null);
      expect(rig.registry.entry('${rig.home}/repo')!.group, 'g2');
    });
  });

  group('sidebar', () {
    testWidgets("the brand shows Zanshin, the app's version line and jj-lib's, top to bottom", (tester) async {
      final rig = _Rig(tester);
      await rig.pump();

      final Rect zanshin = tester.getRect(find.text('Zanshin'));
      final Rect app = tester.getRect(find.text('2026.9.1 · Build 1'));
      final Rect jjLib = tester.getRect(find.text('jj-lib 0.46.0'));
      expect(app.top - zanshin.bottom, moreOrLessEquals(1));
      expect(jjLib.top - app.bottom, moreOrLessEquals(1));
      expect(jjLib.left, app.left);
    });

    testWidgets('a version that cannot be read leaves its line out', (tester) async {
      final rig = _Rig(tester);
      rig.env.jjLib = null;
      await rig.pump();
      expect(find.text('2026.9.1 · Build 1'), findsOneWidget);
      expect(find.textContaining('jj-lib'), findsNothing);

      final rig2 = _Rig(tester);
      rig2.env.version = null;
      await rig2.pump();
      expect(find.text('2026.9.1 · Build 1'), findsNothing);
      expect(
        tester.getRect(find.text('jj-lib 0.46.0')).top - tester.getRect(find.text('Zanshin')).bottom,
        moreOrLessEquals(1),
        reason: 'directly under "Zanshin"',
      );
    });

    testWidgets('without callbacks Settings… is disabled and no link shows; with them both run', (tester) async {
      final rig = _Rig(tester);
      rig.env.identityAnswer = JjIdentity(name: '', email: '');
      await rig.pump(callbacks: false);

      expect(tester.getSemantics(rig.id('projects-settings')), isSemantics(isEnabled: false, label: 'Settings…'));
      expect(find.text('Name and email not configured.'), findsOneWidget);
      expect(find.text('Set identity…'), findsNothing);

      await rig.pump();
      await tester.tap(rig.id('projects-settings'));
      await tester.tap(find.text('Set identity…'));
      await tester.pump();
      expect((rig.settings, rig.identitySettings), (1, 1));
    });

    testWidgets("the identity footer gives the CLI's phrase for what is missing; a failed read hides it", (
      tester,
    ) async {
      final rig = _Rig(tester);
      rig.env.identityAnswer = JjIdentity(name: 'Ralph', email: '');
      await rig.pump();
      expect(find.text('Email not configured.'), findsOneWidget);

      final records = <LogRecord>[];
      final StreamSubscription<LogRecord> logs = Logger.root.onRecord.listen(records.add);
      addTearDown(logs.cancel);
      final rig2 = _Rig(tester);
      rig2.env.identityFailure = const ZanshinFfiException('jj.config_error', '/Users/me/.config/jj/config.toml');
      await rig2.pump();
      expect(find.text('IDENTITY'), findsNothing);
      final LogRecord warning = records.singleWhere((record) => record.level == Level.WARNING);
      expect(warning.message, 'reading the identity failed: jj.config_error');
    });

    testWidgets('the identity is read for the open project and again when it changes', (tester) async {
      final rig = _Rig(tester);
      await rig.pump();
      await tester.runAsync(() => rig.session.open('${rig.home}/code/top'));
      await tester.pump();
      expect(rig.env.identityReads, <String?>[null, '${rig.home}/code/top']);
    });

    testWidgets('the identity is read again when the window becomes key, and only then', (tester) async {
      final rig = _Rig(tester);
      await rig.pump(openUnderHome: 'code/top', appearance: const ZsAppearance(inactive: true));
      final top = '${rig.home}/code/top';
      expect(rig.env.identityReads, <String?>[top]);

      rig.env.identityAnswer = JjIdentity(name: 'Ralph', email: 'ralph@elsewhere.example');
      await rig.showIn(const ZsAppearance());
      expect(rig.env.identityReads, <String?>[top, top], reason: 'inactive → active: the window became key');
      expect(find.text('ralph@elsewhere.example'), findsOneWidget);

      await rig.showIn(const ZsAppearance(inactive: true));
      await rig.showIn(const ZsAppearance(theme: ZsTheme.paper));
      expect(rig.env.identityReads, <String?>[top, top, top]);

      await rig.showIn(const ZsAppearance(theme: ZsTheme.paper, increasedContrast: true));
      expect(rig.env.identityReads, hasLength(3), reason: 'another appearance change, still key');
    });

    test('JjIdentity: an empty value is null; the phrases are the CLI\'s', () {
      expect(JjIdentity(name: '', email: '').missingPhrase, 'Name and email not configured.');
      expect(JjIdentity(email: 'a@b').missingPhrase, 'Name not configured.');
      expect(JjIdentity(name: 'A', email: '').missingPhrase, 'Email not configured.');
      expect(JjIdentity(name: 'A', email: 'a@b').missingPhrase, isNull);
      expect(JjIdentity(name: 'A', email: 'a@b'), JjIdentity(name: 'A', email: 'a@b'));
    });
  });

  testWidgets('the inactive window dims the title and neutralises the selection', (tester) async {
    final rig = _Rig(tester);
    await rig.pump(openUnderHome: 'code/top', appearance: const ZsAppearance(inactive: true));

    final Text title = tester.widget<Text>(find.text('Projects').last);
    final ZsColors colors = ZsColors.of(tester.element(find.text('Projects').last));
    expect(title.style?.color, colors.textDim);
    expect(colors.accentSoft, isNot(ZsColors.night.accentSoft), reason: 'the inactive delta');
  });

  testWidgets("the DI graph builds the content over the component's one session and registry", (tester) async {
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('projects_window_di')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    final MainComponent component = MainComponent.create(
      settingsModule: SettingsModule(store: store),
      iconModule: IconModule(registry: testIconRegistry),
      // Never completed: the graph is built without starting a worker.
      projectsModule: ProjectsModule(worker: Completer<ZanshinWorker>().future),
      workerLifecycleModule: WorkerLifecycleModule(mayQuit: () async => true),
    );

    final ProjectsWindow window = component.projectsWindowFactory.create();

    expect(window.session, same(component.projectSession));
    expect(window.registry, same(component.projectSession.registry));
    expect(window.environment, isA<DesktopProjectsEnvironment>());
    expect(component.projectsWindowFactory.create().session, same(window.session), reason: 'singletons');
  });
}
