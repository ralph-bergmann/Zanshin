// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member

import 'dart:io';

import 'package:flutter/src/foundation/_features.dart';
import 'package:flutter/src/widgets/_window.dart';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/projects/project_capsule.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart' show ZanshinShellPlatform;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/icon_registry.dart';
import '../../helpers/recording_shell.dart';
import '../../helpers/shell_host.dart';

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

  /// Pumps the home page over a fresh settings store and a project session on fake repositories in a 1440 × 900
  /// window showing [appearance], wrapped by [wrap]; returns the session.
  Future<ProjectSession> pumpHome(
    WidgetTester tester, {
    ZsAppearance appearance = const ZsAppearance(),
    Widget Function(Widget home)? wrap,
  }) async {
    useShellWindow(tester);
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('home_page_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    final session = ProjectSession(registry: ProjectRegistry(store), repos: FakeProjectRepos());
    addTearDown(session.dispose);
    final Widget home = shellHost(
      HomePage(viewModelFactory: _factory(store), projects: session),
      appearance: appearance,
    );
    await tester.pumpWidget(wrap?.call(home) ?? home);
    return session;
  }

  /// Lets an open the page started in the fake zone finish its settings writes (real file IO) until [done].
  Future<void> settle(WidgetTester tester, bool Function() done) async {
    for (var i = 0; i < 100 && !done(); i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      await tester.pump();
    }
    expect(done(), isTrue);
  }

  Finder capsuleName(String name) => find.descendant(of: find.byType(ProjectCapsule), matching: find.text(name));

  testWidgets(
    'the home is the floating shell: the window canvas, a drag row over the bar, four empty islands, no rail',
    (
      tester,
    ) async {
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
      expect(empty, findsNWidgets(4));
      for (var i = 0; i < 4; i++) {
        expect(tester.getSize(empty.at(i)), const Size.square(44));
      }
      expect(tester.getTopLeft(empty.first), const Offset(91, 4));
      expect(find.byType(ShellRail), findsNothing);
      expect(find.byType(PinnedPanel), findsNothing);
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

  testWidgets('with a project open PLACE is its capsule at 91, 4, the others stay empty; closing it empties PLACE', (
    tester,
  ) async {
    final ProjectSession session = await pumpHome(tester);
    expect(find.byType(ProjectCapsule), findsNothing);

    await tester.runAsync(() => session.open('/r/zanshin'));
    await tester.pump();

    expect(find.byType(ProjectCapsule), findsOneWidget);
    expect(tester.getTopLeft(find.byType(ProjectCapsule)), const Offset(91, 4));
    expect(find.descendant(of: find.byType(ProjectCapsule), matching: find.text('zanshin')), findsOneWidget);
    expect(find.byType(ShellEmptyIsland), findsNWidgets(3));
    expect(session.current?.status, ProjectStatus.clean);

    await tester.runAsync(session.closeProject);
    await tester.pump();
    expect(find.byType(ProjectCapsule), findsNothing);
    expect(find.byType(ShellEmptyIsland), findsNWidgets(4));
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
