// SPDX-License-Identifier: MIT

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin/src/features/settings/settings_window.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/zanshin_window_root.dart';
import 'package:zanshin/src/links.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show WindowDragArea;
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';
import '../helpers/test_component.dart';

/// A dark shell; by default macOS on Multicolor with Zanshin's app accent (`--accent-native`) as the reported colour.
ShellTheme _shell({bool reduceMotion = false, int? appleAccentColor, Color accentColor = const Color(0xFF4757A1)}) =>
    ShellTheme(
      brightness: Brightness.dark,
      accentColor: accentColor,
      appleAccentColor: appleAccentColor,
      reduceMotion: reduceMotion,
    );

void main() {
  setUpIconRegistry();
  setUpTestWorker();
  late RecordingShell shell;

  /// Pumps the app over persisted [settingsJson] in a 1440 × 900 window, answers the shell with [theme] (or leaves it
  /// pending when null) and the window's chrome watch with [chrome], and returns a context below the app root (the
  /// home page's floating shell). The project window's content is the DI graph's ([TestComponent.appFactory]). File IO
  /// runs outside the fake-async zone; the shell is made inside it, so its answers arrive on the fake clock's
  /// microtasks.
  Future<BuildContext> pumpApp(
    WidgetTester tester,
    String settingsJson,
    ShellTheme? theme, {
    WindowChrome chrome = const WindowChrome(),
  }) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    shell = RecordingShell()..chrome = chrome;
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final TestComponent component = await testComponent(tester, settingsJson: settingsJson);
    addTearDown(component.tracker.dispose);
    await tester.pumpWidget(component.appFactory.create());
    if (theme == null) {
      // The shell has not answered yet: the first frame.
      await tester.pump();
    } else {
      shell.theme.complete(theme);
      await tester.pumpAndSettle();
    }
    return tester.element(find.byType(FloatingShell));
  }

  /// A test component whose tracker and menu are disposed after the test.
  Future<TestComponent> component(WidgetTester tester, {AppWindows? windows}) async {
    final TestComponent component = await testComponent(tester, windows: windows);
    addTearDown(component.tracker.dispose);
    addTearDown(component.application.menu.dispose);
    return component;
  }

  testWidgets("the graph builds the project window's content: HomePage under the window:main root, over the one "
      'session, store and graph', (tester) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final TestComponent graph = await component(tester);

    await tester.pumpWidget(graph.coordinator.buildProject());
    shell.theme.complete(_shell());
    await tester.pumpAndSettle();

    final ProjectSession session = graph.session;
    final HomePage home = tester.widget<HomePage>(find.byType(HomePage));
    expect(home.projects, same(session));
    expect(graph.session, same(session), reason: 'a singleton');
    expect(home.activeGraph, same(graph.activeGraph));
    expect(
      home.activeGraph,
      same(graph.application.menu.graph),
      reason: 'the menu bar reads the graph the page publishes',
    );
    expect(find.byKey(const ValueKey<String>('window:main')), findsOneWidget, reason: "the project window's root key");
    expect(
      find.descendant(of: find.byKey(const ValueKey<String>('window:main')), matching: find.byType(HomePage)),
      findsOneWidget,
    );
  });

  testWidgets('the graph builds Projects under the window:projects root, onOpened handed through', (tester) async {
    final TestComponent graph = await component(tester);
    void onOpened(ProjectOpened outcome) {}

    final Widget root = graph.coordinator.buildProjects(onOpened);

    expect(root, isA<ZanshinWindowRoot>().having((root) => root.windowKey, 'windowKey', projectsWindowKey));
    final Widget content = (root as ZanshinWindowRoot).child;
    expect(content, isA<ProjectsWindow>());
    expect((content as ProjectsWindow).onOpened, same(onOpened));
    expect(content.session, same(graph.session));
    expect(content.registry, same(graph.registry));
    expect(content.environment, same(graph.environment));
    final next = (graph.coordinator.buildProjects(onOpened) as ZanshinWindowRoot).child as ProjectsWindow;
    expect(next.searchFocus, same(content.searchFocus), reason: "one ProjectsSearchFocus: the menu bar's Find");
    expect(content.searchFocus, same(graph.searchFocus));
  });

  testWidgets('the graph builds jj log Configurations under its root over the settings, the graph and the opener', (
    tester,
  ) async {
    final windows = AppWindows(exitProcess: () async {});
    final TestComponent graph = await component(tester, windows: windows);

    final Widget root = graph.coordinator.buildRevsetConfigs();

    expect(root, isA<ZanshinWindowRoot>().having((root) => root.windowKey, 'windowKey', revsetConfigsWindowKey));
    final Widget content = (root as ZanshinWindowRoot).child;
    expect(content, isA<RevsetConfigsWindow>());
    expect((content as RevsetConfigsWindow).settings, same(graph.settings));
    expect(content.graph, same(graph.activeGraph));
    expect(content.windows, same(windows));
    expect(content.windowKey, revsetConfigsWindowKey);
    expect(content.openUrl, same(openInBrowser), reason: 'the Revset reference opens in the browser');
  });

  testWidgets('the graph builds Settings under its content-sized root over the session and the graph', (tester) async {
    final windows = AppWindows(exitProcess: () async {});
    final TestComponent graph = await component(tester, windows: windows);

    final Widget root = graph.coordinator.buildSettings();

    expect(root, isA<ZanshinWindowRoot>().having((root) => root.windowKey, 'windowKey', settingsWindowKey));
    expect((root as ZanshinWindowRoot).sizeToContent, isTrue);
    final Widget content = root.child;
    expect(content, isA<SettingsWindow>());
    expect((content as SettingsWindow).state, same(graph.coordinator.settingsState));
    expect(content.viewModel.store, same(graph.settings));
    expect(content.viewModel.session, same(graph.session));
    expect(content.viewModel.environment, same(graph.environment));
    expect(content.viewModel.graph, same(graph.activeGraph));
    expect(content.windows, same(windows));
    expect(content.windowKey, settingsWindowKey);
    final next = (graph.coordinator.buildSettings() as ZanshinWindowRoot).child as SettingsWindow;
    expect(next.viewModel, isNot(same(content.viewModel)), reason: 'each window owns its view model');
    expect(next.state, same(content.state), reason: 'the tab survives a close');
  });

  testWidgets('the four window contents the coordinator builds share one session, one store and one graph', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final TestComponent graph = await component(tester);

    await tester.pumpWidget(graph.coordinator.buildProject());
    shell.theme.complete(_shell());
    await tester.pumpAndSettle();
    final HomePage home = tester.widget<HomePage>(find.byType(HomePage));
    final projects = (graph.coordinator.buildProjects((_) {}) as ZanshinWindowRoot).child as ProjectsWindow;
    final configurations = (graph.coordinator.buildRevsetConfigs() as ZanshinWindowRoot).child as RevsetConfigsWindow;
    final settingsRoot = graph.coordinator.buildSettings() as ZanshinWindowRoot;
    final settings = settingsRoot.child as SettingsWindow;

    expect(<Object>{home.projects, projects.session, settings.viewModel.session}, <Object>{graph.session});
    expect(<Object>{configurations.settings, settings.viewModel.store}, <Object>{graph.settings});
    expect(projects.registry, same(graph.session.registry), reason: "the Projects content's registry over that store");
    expect(<Object>{home.activeGraph, configurations.graph, settings.viewModel.graph}, <Object>{graph.activeGraph});
    expect((settingsRoot.windowKey, settingsRoot.sizeToContent), (settingsWindowKey, true));
  });

  testWidgets("a switch away from the open project asks the windows' close guards: refused, the project stays", (
    tester,
  ) async {
    final TestComponent graph = await component(tester);
    final ProjectSession session = graph.session;
    addTearDown(session.dispose);
    var asked = 0;
    graph.windows.addCloseGuard(() async {
      asked++;
      return false;
    });

    expect(await tester.runAsync(() => session.open('/r/zanshin')), isA<ProjectOpened>());
    expect(asked, 0, reason: 'nothing to leave yet');

    expect(await tester.runAsync(() => session.open('/r/other')), isA<ProjectSwitchCancelled>());
    expect(asked, 1);
    expect(session.current?.path, '/r/zanshin');
  });

  testWidgets('the home is HomePage over the floating shell, titled Zanshin; the Yaru test page is gone', (
    tester,
  ) async {
    await pumpApp(tester, '{}', _shell());

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.descendant(of: find.byType(HomePage), matching: find.byType(FloatingShell)), findsOneWidget);
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).title, 'Zanshin');
    expect(find.byType(Scaffold), findsNothing);
    expect(find.byType(AppBar), findsNothing);
  });

  for (final (String mode, ZsTheme expected) in const <(String, ZsTheme)>[
    ('light', ZsTheme.paper),
    ('dark', ZsTheme.night),
    ('system', ZsTheme.night),
  ]) {
    testWidgets('the setting $mode with the shell in dark shows ${expected.name}, with the token extensions', (
      tester,
    ) async {
      final BuildContext probe = await pumpApp(tester, '{"appearance": {"themeMode": "$mode"}}', _shell());

      expect(ZsAppearance.of(probe).theme, expected);
      final ZsColors? colors = Theme.of(probe).extension<ZsColors>();
      expect(colors, expected == ZsTheme.paper ? ZsColors.paper : ZsColors.night);
      expect(Theme.of(probe).extension<ZsElevation>(), isNotNull);
      expect(Theme.of(probe).brightness, expected.brightness);
    });
  }

  testWidgets('before the shell answers, setting system follows the platform brightness', (tester) async {
    // The test platform's brightness is light.
    final BuildContext probe = await pumpApp(tester, '{"appearance": {"themeMode": "system"}}', null);

    expect(shell.calls, contains('getTheme'));
    expect(ZsAppearance.of(probe).theme, ZsTheme.paper);
    expect(ZsColors.of(probe), ZsColors.paper);
  });

  testWidgets("the shell's text selection colour reaches the window root", (tester) async {
    const selection = Color(0xFF3F638B);
    final BuildContext probe = await pumpApp(
      tester,
      '{"appearance": {"themeMode": "dark"}}',
      const ShellTheme(
        brightness: Brightness.dark,
        accentColor: Color(0xFF4757A1),
        selectedTextBackgroundDark: selection,
      ),
    );

    expect(DefaultSelectionStyle.of(probe).selectionColor, selection);
  });

  testWidgets('a shell reporting reduce motion disables animations below the app root, live', (tester) async {
    final BuildContext probe = await pumpApp(
      tester,
      '{"appearance": {"themeMode": "dark"}}',
      _shell(reduceMotion: true),
    );

    expect(MediaQuery.disableAnimationsOf(probe), isTrue);
    final ZsMotion reduced = ZsMotion.of(probe);
    expect(reduced.motion, 0);
    expect(
      <Duration>[reduced.durNudge, reduced.durToggle, reduced.durExpand, reduced.durMove, reduced.durFlip],
      <Duration>[
        Duration.zero,
        Duration.zero,
        Duration.zero,
        Duration.zero,
        Duration.zero,
      ],
    );
    expect(reduced.durHover, ZsMotion.full.durHover);
    expect(reduced.durFlash, ZsMotion.full.durFlash);

    shell.changes.add(_shell());
    await tester.pumpAndSettle();

    final BuildContext after = tester.element(find.byType(FloatingShell));
    expect(MediaQuery.disableAnimationsOf(after), isFalse);
    expect(ZsMotion.of(after), ZsMotion.full);
  });

  /// The first island's rect, the bar's top-left island (PLACE's empty island).
  Rect firstIsland(WidgetTester tester) => tester.getRect(find.byType(ShellEmptyIsland).first);

  for (final (WindowChrome chrome, double firstX, double barY, double top)
      in const <(WindowChrome, double, double, double)>[
        // Where the runner moves the project window's buttons (Story 11.26): the bar 12 from the top.
        (WindowChrome(trafficLights: Rect.fromLTWH(19, 27, 60, 14)), 91, 12, 68),
        (WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14)), 91, 4, 60),
        (WindowChrome(trafficLights: Rect.fromLTWH(20, 20, 60, 14)), 92, 5, 61),
      ]) {
    testWidgets(
      'the block ${chrome.trafficLights} reaches the window root: first island $firstX, bar $barY, top $top',
      (
        tester,
      ) async {
        final BuildContext probe = await pumpApp(tester, '{}', _shell(), chrome: chrome);
        final Rect block = chrome.trafficLights!;

        expect(shell.calls, contains('watchWindowChrome:${tester.view.viewId}'));
        expect(ZsAppearance.of(probe).trafficLights, block);
        final metrics = ZsMetrics.of(probe);
        expect(<double>[metrics.chromeFirstX, metrics.chromeBarY, metrics.chromeTop], <double>[firstX, barY, top]);
        final Rect island = firstIsland(tester);
        expect(island.topLeft, Offset(firstX, barY));
        expect(island.left, block.right + 12, reason: 'the first island starts at block end + 12');
        expect(island.center.dy, moreOrLessEquals(block.center.dy, epsilon: 1), reason: 'the bar centres on the block');
        expect(tester.getRect(find.byType(WindowDragArea)), Rect.fromLTWH(0, 0, 1440, top));
        expect(top, island.bottom + 12, reason: 'the content starts at bar bottom + 12');
      },
    );
  }

  testWidgets('full screen reaches the window root and moves the chrome; leaving it brings the block back', (
    tester,
  ) async {
    const block = WindowChrome(trafficLights: Rect.fromLTWH(19, 19, 60, 14));
    await pumpApp(tester, '{}', _shell(), chrome: const WindowChrome(fullScreen: true));
    BuildContext probe() => tester.element(find.byType(FloatingShell));

    expect(ZsAppearance.of(probe()).fullScreen, isTrue);
    expect(firstIsland(tester).topLeft, const Offset(12, 12));
    expect(tester.getRect(find.byType(WindowDragArea)), const Rect.fromLTWH(0, 0, 1440, 68));

    final int viewId = tester.view.viewId;
    shell.chromeChanges.add((viewId: viewId, chrome: block));
    await tester.pumpAndSettle();
    expect(ZsAppearance.of(probe()).fullScreen, isFalse);
    expect(firstIsland(tester).topLeft, const Offset(91, 4));
    expect(tester.getRect(find.byType(WindowDragArea)), const Rect.fromLTWH(0, 0, 1440, 60));

    shell.chromeChanges.add((viewId: viewId, chrome: const WindowChrome(fullScreen: true)));
    await tester.pumpAndSettle();
    expect(ZsAppearance.of(probe()).fullScreen, isTrue);
    expect(firstIsland(tester).topLeft, const Offset(12, 12));
  });

  testWidgets('a chrome report for another view changes nothing in this window', (tester) async {
    await pumpApp(tester, '{}', _shell());
    BuildContext probe() => tester.element(find.byType(FloatingShell));
    expect(ZsAppearance.of(probe()).fullScreen, isFalse);

    shell.chromeChanges.add((viewId: tester.view.viewId + 1, chrome: const WindowChrome(fullScreen: true)));
    await tester.pumpAndSettle();

    expect(ZsAppearance.of(probe()).fullScreen, isFalse);
    expect(firstIsland(tester).topLeft, const Offset(91, 12));
  });

  for (final (String label, String settingsJson, ShellTheme theme, Color accent)
      in <(String, String, ShellTheme, Color)>[
        ('AppleAccentColor 4 shows Blue', '{}', _shell(appleAccentColor: 4), const Color(0xFF67AFFD)),
        (
          'no key and the app accent shows moon',
          '{}',
          _shell(),
          const Color(0xFFAEBCEC),
        ),
        (
          'no key and an iMac orange shows Orange',
          '{}',
          _shell(accentColor: const Color(0xFFF7821B)),
          const Color(0xFFFE8954),
        ),
        (
          'the setting Zanshin shows moon whatever the shell reports',
          '{"appearance": {"accentSource": "zanshin"}}',
          _shell(appleAccentColor: 4),
          const Color(0xFFAEBCEC),
        ),
      ]) {
    testWidgets('accent: $label', (tester) async {
      final BuildContext probe = await pumpApp(tester, settingsJson, theme);
      expect(ZsColors.of(probe).accent, accent);
      expect(Theme.of(probe).colorScheme.primary, accent);
    });
  }
}
