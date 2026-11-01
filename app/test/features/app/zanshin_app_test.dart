// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/main.dart' show MainComponent, appWindowCoordinator;
import 'package:zanshin/src/app/worker_lifecycle_module.dart';
import 'package:zanshin/src/features/app/zanshin_app.dart';
import 'package:zanshin/src/features/app/zanshin_app_view_model.dart';
import 'package:zanshin/src/features/bootstrap/icon_module.dart';
import 'package:zanshin/src/features/graph/revset_configs/revset_configs_window.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/projects/project_registry.dart';
import 'package:zanshin/src/features/projects/project_session.dart';
import 'package:zanshin/src/features/projects/projects_module.dart';
import 'package:zanshin/src/features/projects/projects_window.dart';
import 'package:zanshin/src/features/shell/app_menu.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/zanshin_window_root.dart';
import 'package:zanshin_core/zanshin_core.dart' show ZanshinWorker;
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart' show WindowDragArea;
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/fake_projects.dart';
import '../../helpers/fake_projects_environment.dart';
import '../../helpers/recording_shell.dart';

/// The home page the DI graph would build, over [_store].
class _HomePageFactory implements HomePageFactory {
  _HomePageFactory(this._store);

  final SettingsStore _store;

  /// The app's one session, as the DI graph's singleton.
  late final _projects = ProjectSession(registry: ProjectRegistry(_store), repos: FakeProjectRepos());

  /// The menu bar's model, as the DI graph's singleton.
  late final _appMenu = AppMenuModel(ActiveWindowTracker(), _projects);

  @override
  HomePage create({Key? key}) => HomePage(
    key: key,
    viewModelFactory: _viewModels(() => FloatingShellViewModel(_store)),
    projects: _projects,
    environment: FakeProjectsEnvironment(),
    appMenu: _appMenu,
  );
}

/// The window roots the DI graph would build, over [_store] and [_tracker].
class _RootFactory implements ZanshinWindowRootFactory {
  _RootFactory(this._store, this._tracker);

  final SettingsStore _store;
  final ActiveWindowTracker _tracker;

  @override
  ZanshinWindowRoot create({required String windowKey, required Widget child, Key? key}) => ZanshinWindowRoot(
    key: key,
    viewModelFactory: _viewModels(() => ZanshinAppViewModel(_store)),
    tracker: _tracker,
    windowKey: windowKey,
    child: child,
  );
}

class _Provider<T> implements Provider<T> {
  _Provider(this._create);

  final T Function() _create;

  @override
  T get() => _create();
}

/// The view-model factory the DI graph would hand over, creating each view model with [create].
ViewModelFactory<T> _viewModels<T extends ChangeNotifier>(T Function() create) =>
    ({
      required builder,
      child,
      error,
      init,
      key,
      loading,
    }) => ViewModelBuilder<T>(
      key: key,
      viewModelProvider: _Provider<T>(create),
      init: init,
      loading: loading,
      error: error,
      builder: builder,
      child: child,
    );

/// A dark shell; by default macOS on Multicolor with Zanshin's app accent (`--accent-native`) as the reported colour.
ShellTheme _shell({bool reduceMotion = false, int? appleAccentColor, Color accentColor = const Color(0xFF4757A1)}) =>
    ShellTheme(
      brightness: Brightness.dark,
      accentColor: accentColor,
      appleAccentColor: appleAccentColor,
      reduceMotion: reduceMotion,
    );

void main() {
  late Directory dir;
  late File file;
  late RecordingShell shell;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('zanshin_app_test');
    file = File('${dir.path}/settings.json');
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  /// Pumps the app over persisted [settingsJson] in a 1440 × 900 window, answers the shell with [theme] (or leaves it
  /// pending when null) and the window's chrome watch with [chrome], and returns a context below the app root (the
  /// home page's floating shell). File IO runs outside the fake-async zone; the shell is made inside it, so its
  /// answers arrive on the fake clock's microtasks.
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
    final SettingsStore? store = await tester.runAsync(() async {
      await file.writeAsString(settingsJson);
      return SettingsStore.load(file);
    });
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(
      ZanshinApp(homePageFactory: _HomePageFactory(store!), rootFactory: _RootFactory(store, tracker)),
    );
    if (theme == null) {
      // The shell has not answered yet: the first frame.
      await tester.pump();
    } else {
      shell.theme.complete(theme);
      await tester.pumpAndSettle();
    }
    return tester.element(find.byType(FloatingShell));
  }

  /// main.dart's component over a fresh settings store, its worker never started.
  Future<MainComponent> mainComponent(WidgetTester tester) async {
    final (SettingsStore store, IconRegistry icons) = (await tester.runAsync(
      () async => (await SettingsStore.load(file), await IconRegistry.load()),
    ))!;
    return MainComponent.create(
      settingsModule: SettingsModule(store: store),
      iconModule: IconModule(registry: icons),
      // Never completed: the graph is built without starting a worker, and nothing here opens a project.
      projectsModule: ProjectsModule(worker: Completer<ZanshinWorker>().future),
      workerLifecycleModule: WorkerLifecycleModule(mayQuit: () async => true),
    );
  }

  testWidgets("the DI graph hands HomePage the one session the boot reopens (main.dart's component)", (tester) async {
    tester.view
      ..physicalSize = const Size(1440, 900)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    shell = RecordingShell();
    ZanshinShellPlatform.instance = shell;
    addTearDown(shell.close);
    final MainComponent component = await mainComponent(tester);

    // The project window's content as main.dart's coordinator builds it.
    await tester.pumpWidget(appWindowCoordinator(component, AppWindows(exitProcess: () async {})).buildProject());
    shell.theme.complete(_shell());
    await tester.pumpAndSettle();

    final ProjectSession session = component.projectSession;
    expect(tester.widget<HomePage>(find.byType(HomePage)).projects, same(session));
    expect(component.projectSession, same(session), reason: 'a singleton');
    expect(find.byKey(const ValueKey<String>('window:main')), findsOneWidget, reason: "the project window's root key");
    expect(
      find.descendant(of: find.byKey(const ValueKey<String>('window:main')), matching: find.byType(HomePage)),
      findsOneWidget,
    );
  });

  testWidgets("main.dart's coordinator builds Projects under the window:projects root, onOpened handed through", (
    tester,
  ) async {
    final MainComponent component = await mainComponent(tester);
    void onOpened(ProjectOpened outcome) {}

    final Widget root = appWindowCoordinator(component, AppWindows(exitProcess: () async {})).buildProjects(onOpened);

    expect(root, isA<ZanshinWindowRoot>().having((root) => root.windowKey, 'windowKey', projectsWindowKey));
    final Widget content = (root as ZanshinWindowRoot).child;
    expect(content, isA<ProjectsWindow>());
    expect((content as ProjectsWindow).onOpened, same(onOpened));
    expect(content.session, same(component.projectSession));
    expect(content.key, same(component.appMenu.projectsKey), reason: "the menu bar's Find reaches Projects' search");
  });

  testWidgets("main.dart's coordinator builds jj log Configurations under its root over the settings and the graph", (
    tester,
  ) async {
    final MainComponent component = await mainComponent(tester);
    final windows = AppWindows(exitProcess: () async {});

    final Widget root = appWindowCoordinator(component, windows).buildRevsetConfigs();

    expect(root, isA<ZanshinWindowRoot>().having((root) => root.windowKey, 'windowKey', revsetConfigsWindowKey));
    final Widget content = (root as ZanshinWindowRoot).child;
    expect(content, isA<RevsetConfigsWindow>());
    expect((content as RevsetConfigsWindow).settings, same(component.settings));
    expect(content.graph, same(component.appMenu.graph));
    expect(content.windows, same(windows));
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
    expect(firstIsland(tester).topLeft, const Offset(91, 4));
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
