// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin/src/features/graph/graph_controls.dart';
import 'package:zanshin/src/features/graph/graph_search_field.dart';
import 'package:zanshin/src/features/graph/graph_view.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/projects/project_capsule.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/shell/app_menu.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_view.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_window_actions.dart';
import 'package:zanshin_core/zanshin_core.dart'
    show RepoDetectResult, RepoKind, ZanshinFfiException, ZanshinWarning, ZanshinWarningCode;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart' show ZanshinShellPlatform;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_projects_environment.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/recording_shell.dart';
import '../../helpers/shell_host.dart';

/// How long `settle` waits, in real time, for work started in the fake zone.
const _settleBudget = Duration(seconds: 10);

/// Counts the windows the page asks for.
class _Actions implements AppWindowActions {
  var projects = 0;

  @override
  Future<void> openProjects() async => projects++;

  var configurations = 0;

  @override
  Future<void> openRevsetConfigs() async => configurations++;

  final settings = <SettingsTarget?>[];

  @override
  Future<void> openSettings({SettingsTarget? target}) async => settings.add(target);
}

class _ViewModels implements Provider<FloatingShellViewModel> {
  _ViewModels(this._store);

  final SettingsStore _store;

  @override
  FloatingShellViewModel get() => FloatingShellViewModel(_store);
}

ViewModelFactory<FloatingShellViewModel> _factory(SettingsStore store) =>
    ({
      required builder,
      child,
      error,
      init,
      key,
      loading,
    }) => ViewModelBuilder<FloatingShellViewModel>(
      key: key,
      viewModelProvider: _ViewModels(store),
      init: init,
      loading: loading,
      error: error,
      builder: builder,
      child: child,
    );

void main() {
  setUpIconRegistry();
  late RecordingShell shell;
  setUp(() => ZanshinShellPlatform.instance = shell = RecordingShell());
  tearDown(() => shell.close());

  late AppMenuModel appMenu;

  /// Pumps the home page over a fresh settings store and a project session on fake repositories in a 1440 × 900
  /// window showing [appearance], wrapped by [wrap]; returns the session. The menu bar's model is [appMenu].
  Future<ProjectSession> pumpHome(
    WidgetTester tester, {
    ZsAppearance appearance = const ZsAppearance(),
    Widget Function(Widget home)? wrap,
    FakeProjectRepos? repos,
    Future<void> Function(ProjectSession session)? before,
  }) async {
    useShellWindow(tester);
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('home_page_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    final session = ProjectSession(registry: ProjectRegistry(store), repos: repos ?? FakeProjectRepos());
    addTearDown(session.dispose);
    if (before != null) {
      await tester.runAsync(() => before(session));
    }
    appMenu = AppMenuModel(ActiveWindowTracker(), session);
    addTearDown(appMenu.dispose);
    final Widget home = shellHost(
      HomePage(
        viewModelFactory: _factory(store),
        projects: session,
        environment: FakeProjectsEnvironment(),
        appMenu: appMenu,
      ),
      appearance: appearance,
    );
    await tester.pumpWidget(wrap?.call(home) ?? home);
    return session;
  }

  /// Lets an open the page started in the fake zone finish its settings writes (real file IO) until [done].
  ///
  /// The wait is bounded by [_settleBudget] of real time, not by a number of polls: each write is fsync'd and
  /// chained, so under the full gate's parallel load one can take seconds. The dart:core `Stopwatch` reads real
  /// time here: fake_async fakes timers, microtasks and `package:clock`, not `Stopwatch`.
  Future<void> settle(WidgetTester tester, bool Function() done) async {
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
  }

  Finder capsuleName(String name) => find.descendant(of: find.byType(ProjectCapsule), matching: find.text(name));

  testWidgets(
    'the home is the floating shell: the window canvas, a drag row over the bar, three empty islands and a disabled '
    'Reload, no rail',
    (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpHome(tester);

      expect(find.byType(FloatingShell), findsOneWidget);
      final Finder canvas = find.byType(ZsCanvas);
      expect(canvas, findsOneWidget);
      expect(tester.getRect(canvas), const Rect.fromLTWH(0, 0, 1440, 900));
      expect(tester.getRect(find.byType(WindowDragArea)), const Rect.fromLTWH(0, 0, 1440, 60));
      final RenderObject canvasBox = tester.renderObject(canvas);
      bool reachesCanvas(Offset at) => tester.hitTestOnBinding(at).path.any((entry) => entry.target == canvasBox);
      expect(reachesCanvas(const Offset(600, 30)), isFalse, reason: 'a press in the bar row moves the window only');
      expect(reachesCanvas(const Offset(600, 400)), isTrue, reason: 'below it the canvas (the graph) takes it');
      final Finder empty = find.byType(ShellEmptyIsland);
      expect(empty, findsNWidgets(3));
      for (var i = 0; i < 3; i++) {
        expect(tester.getSize(empty.at(i)), const Size.square(44));
      }
      expect(tester.getTopLeft(empty.first), const Offset(91, 4));
      expect(
        tester.getSemantics(find.bySemanticsIdentifier('graph.reload')),
        isSemantics(isButton: true, hasEnabledState: true, isEnabled: false),
        reason: 'no project open: nothing to reload',
      );
      expect(find.byType(GraphView), findsNothing);
      expect(find.byType(ShellRail), findsNothing);
      expect(find.byType(PinnedPanel), findsNothing);
      handle.dispose();
    },
  );

  for (final (ZsTheme theme, ZsColors colors) in <(ZsTheme, ZsColors)>[
    (ZsTheme.night, ZsColors.night),
    (ZsTheme.paper, ZsColors.paper),
  ]) {
    testWidgets('in ${theme.name} the canvas sits under the theme whose --canvas it paints', (tester) async {
      await pumpHome(tester, appearance: ZsAppearance(theme: theme));
      expect(ZsColors.of(tester.element(find.byType(ZsCanvas))).canvas, colors.canvas);
    });
  }

  testWidgets('a pan in the bar row starts a window drag; a double tap runs the titlebar action', (tester) async {
    await pumpHome(tester);

    await tester.dragFrom(const Offset(600, 30), const Offset(80, 20));
    expect(shell.calls, <String>['startWindowDrag']);

    await tester.tapAt(const Offset(600, 30));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(600, 30));
    await tester.pumpAndSettle();
    expect(shell.calls, <String>['startWindowDrag', 'performTitlebarDoubleClickAction']);

    await tester.dragFrom(const Offset(600, 400), const Offset(80, 20));
    expect(shell.calls, hasLength(2), reason: 'below the row a pan reaches the canvas, not the window');
  });

  testWidgets('with a project open PLACE is its capsule at 91, 4 and the graph fills VIEW and ACTION; closing it '
      'empties them', (
    tester,
  ) async {
    final ProjectSession session = await pumpHome(tester);
    expect(find.byType(ProjectCapsule), findsNothing);
    final State shellState = tester.state(find.byType(FloatingShell));

    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();

    expect(find.byType(ProjectCapsule), findsOneWidget);
    expect(tester.getTopLeft(find.byType(ProjectCapsule)), const Offset(91, 4));
    expect(find.descendant(of: find.byType(ProjectCapsule), matching: find.text('zanshin')), findsOneWidget);
    expect(find.byType(ShellEmptyIsland), findsNothing);
    expect(find.byType(GraphView), findsOneWidget);
    expect(find.byType(GraphViewControls), findsOneWidget);
    expect(find.byType(NewChangeButton), findsOneWidget);
    expect(tester.widget<GraphSearchShortcuts>(find.byType(GraphSearchShortcuts)).search, isNotNull);
    expect(session.current?.status, ProjectStatus.clean);
    expect(tester.state(find.byType(FloatingShell)), same(shellState), reason: 'opening remounts no shell');

    await tester.runAsync(session.closeProject);
    await tester.pump();
    expect(find.byType(ProjectCapsule), findsNothing);
    expect(find.byType(GraphView), findsNothing);
    expect(tester.widget<GraphSearchShortcuts>(find.byType(GraphSearchShortcuts)).search, isNull);
    expect(find.byType(ShellEmptyIsland), findsNWidgets(3));
    expect(tester.state(find.byType(FloatingShell)), same(shellState), reason: 'closing remounts no shell');
  });

  testWidgets("Edit › Find's binding focuses the graph search field", (tester) async {
    final ProjectSession session = await pumpHome(tester);
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();
    final Finder field = find.descendant(of: find.byType(GraphSearchField), matching: find.byType(EditableText));
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isFalse);

    appMenu.graph.value!.focusSearch!();
    await tester.pump();
    expect(tester.widget<EditableText>(field).focusNode.hasFocus, isTrue);
  });

  testWidgets('the graph is published to the menu bar per repository and cleared when the project switches or closes', (
    tester,
  ) async {
    final ProjectSession session = await pumpHome(tester);
    expect(appMenu.graph.value, isNull);

    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();
    final GraphMenuBinding? first = appMenu.graph.value;
    expect(first, isNotNull);
    expect(tester.widget<GraphView>(find.byType(GraphView)).model, same(first!.model));
    expect(first.focusSearch, isNotNull);
    expect(first.search, isNotNull, reason: 'the Configurations window counts through it (Story 10.22)');
    final State graphState = tester.state(find.byType(GraphView));
    final State searchState = tester.state(find.byType(GraphSearchField));

    await tester.runAsync(() => session.open('/r/jj'));
    await tester.pump();
    expect(tester.state(find.byType(GraphView)), isNot(same(graphState)), reason: 'a fresh graph state');
    expect(tester.state(find.byType(GraphSearchField)), isNot(same(searchState)), reason: 'no old search text');
    final GraphMenuBinding? second = appMenu.graph.value;
    expect(second, isNotNull);
    expect(second!.model, isNot(same(first.model)), reason: 'a new set of graph objects for the new repository');
    expect(tester.widget<GraphView>(find.byType(GraphView)).model, same(second.model));
    expect(() => first.model.addListener(() {}), throwsFlutterError, reason: 'the old model is disposed');

    await tester.runAsync(session.closeProject);
    await tester.pump();
    expect(appMenu.graph.value, isNull);
  });

  testWidgets('the Undo Timeline runs through the graph model; Reload refreshes the session and reloads the graph', (
    tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final repos = FakeProjectRepos();
    final ProjectSession session = await pumpHome(tester, repos: repos);
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();

    final FloatingShell shell = tester.widget<FloatingShell>(find.byType(FloatingShell));
    final panel = shell.railItems.singleWhere((item) => item.id == 'undo').panel as UndoTimelinePanel;
    expect(panel.actions, same(appMenu.graph.value!.model));

    final FakeProjectRepo repo = repos.repoAt('/r/zanshin');
    expect(
      tester.getSemantics(find.bySemanticsIdentifier('graph.reload')),
      isSemantics(isButton: true, hasEnabledState: true, isEnabled: true),
    );
    final int reads = repo.reads;
    final int handleReads = repo.handleReads;
    await tester.tap(find.bySemanticsIdentifier('graph.reload'));
    var drained = false;
    unawaited(session.open('/r/zanshin').then((_) => drained = true));
    await settle(tester, () => drained);
    expect(repo.reads, reads + 1, reason: 'one ProjectSession.refresh');
    expect(
      repo.handleReads,
      handleReads + 4,
      reason: "one layout request, reading the handle's logDefaults; the sync's three remote reads (Story 11.8)",
    );
    handle.dispose();
  });

  testWidgets("the shell's minimap card width is the open graph's minimapSource.cardWidth", (tester) async {
    FloatingShell shell() => tester.widget<FloatingShell>(find.byType(FloatingShell));
    final ProjectSession session = await pumpHome(tester, repos: FakeProjectRepos());
    expect(shell().minimapWidth, isNull, reason: 'no project, no graph');

    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();
    final ValueListenable<double> first = appMenu.graph.value!.model.minimapSource.cardWidth;
    expect(shell().minimap, isNotNull, reason: 'the shell only sizes a shown minimap');
    expect(shell().minimapWidth, same(first));

    await tester.runAsync(() => session.open('/r/jj'));
    await tester.pump();
    expect(shell().minimapWidth, same(appMenu.graph.value!.model.minimapSource.cardWidth));
    expect(shell().minimapWidth, isNot(same(first)), reason: "the old project's model is disposed");
  });

  testWidgets("a creation's warnings show as the toast \"Opened ‹name›\" with a warn clause, reported once", (
    tester,
  ) async {
    const warning = ZanshinWarning(code: ZanshinWarningCode.identityMissing, message: 'Name and email not configured.');
    final repos = FakeProjectRepos()..creationWarnings['/r/fresh'] = const <ZanshinWarning>[warning];
    final ProjectSession session = await pumpHome(tester, repos: repos);

    await tester.runAsync(() => session.initRepo('/r/fresh'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final ZsToast toast = tester.widget(find.byType(ZsToast));
    expect(toast.message.toPlainText(), 'Opened fresh · Name and email not configured.');
    expect(toast.tooltip, 'Name and email not configured.');
    expect(toast.actions, isEmpty);
    expect(session.openReport.value, isNull, reason: 'taken');

    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(ZsToast), findsNothing);
  });

  testWidgets('Story 11.22: a conversion that left main@origin untracked names it, warns and offers Track', (
    tester,
  ) async {
    final repos = FakeProjectRepos()
      ..creationTrackable['/r/git'] = const <String>['main@origin']
      ..creationTrackable['/r/two'] = const <String>['main@origin', 'dev@origin'];
    final ProjectSession session = await pumpHome(tester, repos: repos);

    await tester.runAsync(() => session.convert('/r/git'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    ZsToast toast = tester.widget(find.byType(ZsToast));
    expect(toast.message.toPlainText(), "Opened git · main@origin isn't tracked");
    expect(toast.tone, ZsToastTone.warn);
    expect(toast.actions.single.label, 'Track');
    expect(toast.actions.single.tooltip, 'jj bookmark track main@origin');
    expect(
      toast.tooltip,
      contains("The following remote bookmarks aren't associated with the existing local bookmarks:\n  main@origin"),
    );
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));

    await tester.runAsync(() => session.convert('/r/two'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    toast = tester.widget(find.byType(ZsToast));
    expect(toast.message.toPlainText(), "Opened two · 2 remote bookmarks aren't tracked");
    expect(toast.actions.single.label, 'Track all');
    expect(toast.actions.single.tooltip, 'jj bookmark track main@origin dev@origin');
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets("Story 11.22 closing: the linked-worktree warning follows jj's trackable hint in the tooltip", (
    tester,
  ) async {
    const identity = ZanshinWarning(
      code: ZanshinWarningCode.identityMissing,
      message: 'Name and email not configured.',
    );
    const worktree = ZanshinWarning(
      code: ZanshinWarningCode.colocatedInGitWorktree,
      message: 'This is a linked Git worktree.',
    );
    final repos = FakeProjectRepos()
      ..creationWarnings['/r/wt'] = const <ZanshinWarning>[identity, worktree]
      ..creationTrackable['/r/wt'] = const <String>['main@origin'];
    final ProjectSession session = await pumpHome(tester, repos: repos);

    await tester.runAsync(() => session.convert('/r/wt'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final ZsToast toast = tester.widget(find.byType(ZsToast));
    expect(
      toast.tooltip,
      <String>[
        'Name and email not configured.',
        "Hint: The following remote bookmarks aren't associated with the existing local bookmarks:",
        '  main@origin',
        'Hint: Run the following command to keep local bookmarks updated on future pulls:',
        '  jj bookmark track main@origin',
        ('In Git a branch follows its remote counterpart; jj links a local bookmark to its remote one only once you '
            'track it — then fetches and pushes keep them together.'),
        'This is a linked Git worktree.',
      ].join('\n'),
    );
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('Story 11.22: Track all tracks every symbol in one call and dismisses; a refusal shows an error toast', (
    tester,
  ) async {
    final repos = FakeProjectRepos()..creationTrackable['/r/two'] = const <String>['main@origin', 'dev@origin'];
    final ProjectSession session = await pumpHome(tester, repos: repos);

    await tester.runAsync(() => session.convert('/r/two'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    tester.widget<ZsToast>(find.byType(ZsToast)).actions.single.onPressed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repos.log.where((entry) => entry.startsWith('track')), <String>['track /r/two main@origin dev@origin']);
    expect(find.bySemanticsIdentifier('project-toast'), findsNothing, reason: 'dismissed');
    expect(find.byType(ZsToast), findsNothing);

    repos.creationTrackable['/r/bad'] = const <String>['main@origin'];
    await tester.runAsync(() => session.convert('/r/bad'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    repos.repoAt('/r/bad').trackError = const ZanshinFfiException('jj.invalid_input', 'No such remote bookmark');
    tester.widget<ZsToast>(find.byType(ZsToast)).actions.single.onPressed();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final ZsToast error = tester.widget(find.byType(ZsToast));
    expect(error.identifier, 'project-toast-track-error');
    expect(error.message.toPlainText(), 'No such remote bookmark');
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('Story 11.22: Track acts on the converted repository even after a switch to another one', (tester) async {
    final repos = FakeProjectRepos()..creationTrackable['/r/two'] = const <String>['main@origin'];
    final ProjectSession session = await pumpHome(tester, repos: repos);

    await tester.runAsync(() => session.convert('/r/two'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    final VoidCallback track = tester.widget<ZsToast>(find.byType(ZsToast)).actions.single.onPressed;

    await tester.runAsync(() => session.open('/r/other'));
    await tester.pump();
    track();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(repos.log.where((entry) => entry.startsWith('track')), <String>['track /r/two main@origin']);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('a report the session holds before the window mounts shows once it mounts, and is taken', (tester) async {
    const warning = ZanshinWarning(code: ZanshinWarningCode.identityMissing, message: 'Name and email not configured.');
    final repos = FakeProjectRepos()..creationWarnings['/r/fresh'] = const <ZanshinWarning>[warning];
    final ProjectSession session = await pumpHome(
      tester,
      repos: repos,
      before: (session) async {
        await session.initRepo('/r/fresh');
        expect(session.openReport.value, isNotNull);
      },
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));

    final ZsToast toast = tester.widget(find.byType(ZsToast));
    expect(toast.message.toPlainText(), 'Opened fresh · Name and email not configured.');
    expect(session.openReport.value, isNull);
    await tester.pump(const Duration(seconds: 7));
    await tester.pump(const Duration(milliseconds: 300));
  });

  testWidgets('the window turning active again reads the open project once; turning inactive reads nothing', (
    tester,
  ) async {
    final ProjectSession session = await pumpHome(tester);
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();
    final repo = session.repo! as FakeProjectRepo;
    expect(repo.reads, 1);
    final HomePage home = tester.widget<HomePage>(find.byType(HomePage));

    /// Shows [appearance], then waits for everything the session queued (opening the open project only takes its turn).
    Future<void> show(ZsAppearance appearance) async {
      await tester.pumpWidget(shellHost(home, appearance: appearance));
      var drained = false;
      unawaited(session.open('/r/zanshin').then((_) => drained = true));
      await settle(tester, () => drained);
    }

    await show(const ZsAppearance(inactive: true));
    expect(repo.reads, 1);
    await show(const ZsAppearance());
    expect(repo.reads, 2);
  });

  testWidgets('the rail has the Undo Timeline while a project is open, reading the open repository', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final repos = FakeProjectRepos();
    final ProjectSession session = await pumpHome(tester, repos: repos);
    expect(find.bySemanticsIdentifier('rail-undo'), findsNothing);

    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();
    expect(find.bySemanticsIdentifier('rail-undo'), findsOneWidget);
    // Story 10.14: Bookmarks first, then the Undo Timeline (DS chrome.jsx:7-11).
    expect(tester.widget<FloatingShell>(find.byType(FloatingShell)).railItems.map((item) => item.id), <String>[
      'bookmarks',
      'undo',
    ]);
    // The op log and the graph's logDefaults.
    final int first = repos.repoAt('/r/zanshin').handleReads;
    expect(first, greaterThan(0), reason: 'its op log was read');

    await tester.runAsync(() => session.open('/r/jj'));
    await tester.pump();
    expect(find.bySemanticsIdentifier('rail-undo'), findsOneWidget);
    expect(repos.repoAt('/r/jj').handleReads, greaterThan(0), reason: 'the switch reads the new repository');
    expect(repos.repoAt('/r/zanshin').handleReads, first);

    await tester.runAsync(session.closeProject);
    await tester.pump();
    expect(find.bySemanticsIdentifier('rail-undo'), findsNothing);
    expect(find.bySemanticsIdentifier('rail-bookmarks'), findsNothing);
    handle.dispose();
  });

  testWidgets("a Recent row of the capsule's menu switches the project; the capsule shows the new one", (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final ProjectSession session = await pumpHome(tester);
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.runAsync(() => session.open('/r/jj'));
    await tester.pump();
    expect(capsuleName('jj'), findsOneWidget);

    await tester.tap(find.bySemanticsIdentifier('project-capsule'));
    await tester.pump();
    await tester.pump(ZsMotion.full.durMenu);
    await tester.tap(find.bySemanticsIdentifier('project-menu-recent-1'));
    await tester.pump(ZsMotion.full.durBlink * 2);
    await settle(tester, () => session.current?.path == '/r/zanshin');
    await tester.pump(ZsMotion.full.durExit);
    await tester.pump();

    expect(capsuleName('zanshin'), findsOneWidget);
    expect(capsuleName('jj'), findsNothing);
    handle.dispose();
  });

  for (final failing in <bool>[true, false]) {
    testWidgets(
      failing
          ? 'a Recent row whose open fails shows Projects with the failure; the open project stays'
          : 'a Recent row whose folder is gone shows Projects with that; the open project stays',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final actions = _Actions();
        final repos = FakeProjectRepos();
        final ProjectSession session = await pumpHome(
          tester,
          repos: repos,
          wrap: (home) => AppWindowActionsScope(actions: actions, child: home),
        );
        await tester.runAsync(() => session.open('/r/zanshin'));
        await tester.runAsync(() => session.open('/r/jj'));
        await tester.pump();
        if (failing) {
          repos.openFailures['/r/zanshin'] = const ZanshinFfiException('jj.jj_lib_error', 'the store is broken');
        } else {
          repos.detections['/r/zanshin'] = const RepoDetectResult(kind: RepoKind.pathNotFound);
        }

        await tester.tap(find.bySemanticsIdentifier('project-capsule'));
        await tester.pump();
        await tester.pump(ZsMotion.full.durMenu);
        await tester.tap(find.bySemanticsIdentifier('project-menu-recent-1'));
        await tester.pump(ZsMotion.full.durBlink * 2);
        await settle(tester, () => actions.projects == 1);
        await tester.pump(ZsMotion.full.durExit);
        await tester.pump();

        expect(session.current?.path, '/r/jj');
        final ProjectFailedOpen? failed = session.failedOpen.value;
        expect(failed?.path, '/r/zanshin');
        expect(
          failed?.outcome,
          failing
              ? isA<ProjectOpenFailed>().having((f) => f.context, 'context', 'the store is broken')
              : isA<ProjectNotARepo>().having((f) => f.kind, 'kind', RepoKind.pathNotFound),
        );
        handle.dispose();
      },
    );
  }

  testWidgets("the search menu's Edit Configurations… opens the Configurations window (Story 10.22)", (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final actions = _Actions();
    final ProjectSession session = await pumpHome(
      tester,
      wrap: (home) => AppWindowActionsScope(actions: actions, child: home),
    );
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();

    await tester.tap(find.bySemanticsIdentifier('graph-search-pill'));
    await tester.pump();
    await tester.tap(find.bySemanticsIdentifier('graph-search-menu-edit'));
    await tester.pump();

    expect(actions.configurations, 1);
    handle.dispose();
  });

  testWidgets('a Recent row that opens shows no Projects', (tester) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    final actions = _Actions();
    final ProjectSession session = await pumpHome(
      tester,
      wrap: (home) => AppWindowActionsScope(actions: actions, child: home),
    );
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.runAsync(() => session.open('/r/jj'));
    await tester.pump();

    await tester.tap(find.bySemanticsIdentifier('project-capsule'));
    await tester.pump();
    await tester.pump(ZsMotion.full.durMenu);
    await tester.tap(find.bySemanticsIdentifier('project-menu-recent-1'));
    await tester.pump(ZsMotion.full.durBlink * 2);
    await settle(tester, () => session.current?.path == '/r/zanshin');
    await tester.pump(ZsMotion.full.durExit);
    await tester.pump();

    expect(actions.projects, 0);
    expect(session.failedOpen.value, isNull);
    handle.dispose();
  });

  for (final scoped in <bool>[true, false]) {
    testWidgets(
      scoped
          ? "under the coordinator's actions scope All Projects… is enabled and opens Projects"
          : 'without the actions scope All Projects… stays disabled',
      (tester) async {
        final SemanticsHandle handle = tester.ensureSemantics();
        final actions = _Actions();
        final ProjectSession session = await pumpHome(
          tester,
          wrap: scoped ? (home) => AppWindowActionsScope(actions: actions, child: home) : null,
        );
        await tester.runAsync(() => session.open('/r/zanshin'));
        await tester.pump();

        await tester.tap(find.bySemanticsIdentifier('project-capsule'));
        await tester.pump();
        await tester.pump(ZsMotion.full.durMenu);
        expect(
          tester.getSemantics(find.bySemanticsIdentifier('project-menu-all')),
          isSemantics(isButton: true, hasEnabledState: true, isEnabled: scoped),
        );

        await tester.tap(find.bySemanticsIdentifier('project-menu-all'), warnIfMissed: false);
        await tester.pump(ZsMotion.full.durBlink * 2);
        await tester.pump(ZsMotion.full.durExit);
        await tester.pump();

        expect(actions.projects, scoped ? 1 : 0);
        handle.dispose();
      },
    );
  }

  testWidgets("under the actions scope the capsule's Project Settings… and Settings… open Settings (Story 11.7)", (
    tester,
  ) async {
    final actions = _Actions();
    final ProjectSession session = await pumpHome(
      tester,
      wrap: (home) => AppWindowActionsScope(actions: actions, child: home),
    );
    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();

    for (final identifier in <String>['project-menu-project-settings', 'project-menu-settings']) {
      await tester.tap(find.bySemanticsIdentifier('project-capsule'));
      await tester.pump();
      await tester.pump(ZsMotion.full.durMenu);
      await tester.tap(find.bySemanticsIdentifier(identifier), warnIfMissed: false);
      await tester.pump(ZsMotion.full.durBlink * 2);
      await tester.pump(ZsMotion.full.durExit);
      await tester.pump();
    }

    expect(actions.settings, <SettingsTarget?>[SettingsTarget.project, null]);
  });

  testWidgets("the window takes the open project's name and returns to Zanshin when it closes", (tester) async {
    final bool windowingWasEnabled = isWindowingEnabled;
    isWindowingEnabled = true;
    addTearDown(() => isWindowingEnabled = windowingWasEnabled);
    final window = WindowController(
      size: const Size(1440, 900),
      title: 'Zanshin',
      delegate: WindowControllerDelegate(),
    );
    addTearDown(window.destroy);
    final ProjectSession session = await pumpHome(
      tester,
      wrap: (home) => WindowScope(controller: window, child: home),
    );
    expect(window.title, 'Zanshin');

    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();
    await tester.pump();
    expect(window.title, 'zanshin');

    await tester.runAsync(session.closeProject);
    await tester.pump();
    await tester.pump();
    expect(window.title, 'Zanshin');
  });

  testWidgets('in full screen the drag row ends at 68 and the first island sits at 12, 12', (tester) async {
    await pumpHome(tester, appearance: const ZsAppearance(fullScreen: true));

    expect(tester.getRect(find.byType(WindowDragArea)), const Rect.fromLTWH(0, 0, 1440, 68));
    expect(tester.getTopLeft(find.byType(ShellEmptyIsland).first), const Offset(12, 12));
  });
}
