// SPDX-License-Identifier: MIT

import 'dart:ui' show Scene, SemanticsUpdate, ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin/src/features/window/code_font.dart';
import 'package:zanshin/src/features/window/window_zoom.dart';
import 'package:zanshin/src/features/window/zanshin_app_view_model.dart';
import 'package:zanshin/src/features/window/zanshin_window_root.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/recording_shell.dart';
import '../../helpers/test_component.dart';

/// A second window's view: renders nothing to the engine, which only knows the test view (Flutter's own multi-view
/// tests do the same).
class _SecondView extends TestFlutterView {
  _SecondView(FlutterView view)
    : super(
        view: view,
        platformDispatcher: view.platformDispatcher as TestPlatformDispatcher,
        display: view.display as TestDisplay,
      );

  @override
  int get viewId => 100;

  @override
  void render(Scene scene, {Size? size}) {}

  @override
  void updateSemantics(SemanticsUpdate update) {}
}

/// A control on the state core that reports its status, and a text field: a window's content.
class _Content extends StatelessWidget {
  const _Content({required this.name, required this.statuses, required this.field});

  final String name;
  final Map<String, ZsControlStatus> statuses;
  final ZsTextEditingController field;

  @override
  Widget build(BuildContext context) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ZsControlCore(
          identifier: 'probe-$name',
          semantics: SemanticsProperties(button: true, label: name),
          onActivate: () {},
          builder: (context, status) {
            statuses[name] = status;
            return const SizedBox(width: 80, height: 30);
          },
        ),
        SizedBox(
          width: 200,
          child: ZsTextField(controller: field, identifier: 'field-$name'),
        ),
      ],
    ),
  );
}

ViewFocusEvent _focus(int viewId, ViewFocusState state) =>
    ViewFocusEvent(viewId: viewId, state: state, direction: ViewFocusDirection.undefined);

void main() {
  setUpIconRegistry();
  setUpTestWorker();
  late RecordingShell shell;

  setUp(() {
    ZanshinShellPlatform.instance = shell = RecordingShell();
    // macOS's highlight mode is always "traditional" (RC §4), whatever input the test sends.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    await shell.close();
  });

  /// A component over the settings [json]; its tracker is disposed after the test.
  Future<TestComponent> component(WidgetTester tester, String json) async {
    final TestComponent component = await testComponent(tester, settingsJson: json);
    addTearDown(component.tracker.dispose);
    return component;
  }

  /// The project window (the test view) and the Projects window (a second view), each under its own root from the
  /// component's factory, over one settings store and one tracker; answers the store, the content's statuses and the
  /// two text fields.
  Future<_TwoWindows> pumpTwoWindows(WidgetTester tester, {String settingsJson = '{}'}) async {
    tester.view
      ..physicalSize = const Size(900, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final TestComponent graph = await component(tester, settingsJson);
    final statuses = <String, ZsControlStatus>{};
    final main = ZsTextEditingController();
    final projects = ZsTextEditingController();
    addTearDown(main.dispose);
    addTearDown(projects.dispose);
    final second = _SecondView(tester.view);
    ZanshinWindowRoot root(String windowKey, ZsTextEditingController field) => graph.rootFactory.create(
      windowKey: windowKey,
      child: _Content(name: windowKey, statuses: statuses, field: field),
    );
    await tester.pumpWidget(
      ViewCollection(
        views: <Widget>[
          View(view: tester.view, child: root('main', main)),
          View(view: second, child: root('projects', projects)),
        ],
      ),
      wrapWithView: false,
    );
    shell.theme.complete(const ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF4757A1)));
    await tester.pumpAndSettle();
    return _TwoWindows(store: graph.settings, statuses: statuses, main: main, projects: projects, second: second);
  }

  ZsAppearance appearanceIn(WidgetTester tester, String windowKey) =>
      ZsAppearance.of(tester.element(find.bySemanticsIdentifier('probe-$windowKey')));

  testWidgets('each window root carries its key, and before any focus event both windows are active', (tester) async {
    await pumpTwoWindows(tester);

    for (final key in <String>['main', 'projects']) {
      expect(
        find.descendant(
          of: find.byKey(ValueKey<String>('window:$key')),
          matching: find.bySemanticsIdentifier('probe-$key'),
        ),
        findsOneWidget,
      );
      expect(appearanceIn(tester, key).inactive, isFalse);
    }
  });

  testWidgets('only the key window is active; a hovered control in the other paints no hover', (tester) async {
    final _TwoWindows windows = await pumpTwoWindows(tester);

    WidgetsBinding.instance.handleViewFocusChanged(_focus(tester.view.viewId, ViewFocusState.focused));
    await tester.pump();
    expect((appearanceIn(tester, 'main').inactive, appearanceIn(tester, 'projects').inactive), (false, true));

    WidgetsBinding.instance
      ..handleViewFocusChanged(_focus(tester.view.viewId, ViewFocusState.unfocused))
      ..handleViewFocusChanged(_focus(windows.second.viewId, ViewFocusState.focused));
    await tester.pump();
    expect((appearanceIn(tester, 'main').inactive, appearanceIn(tester, 'projects').inactive), (true, false));

    final TestGesture mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.bySemanticsIdentifier('probe-main')));
    await tester.pump();
    expect(windows.statuses['main']!.hovered, isFalse, reason: 'the project window is not key');
    expect(windows.statuses['main']!.inactive, isTrue);

    // The test gesture adds its pointer to the test view; a mouse over the second view is a device of its own there.
    final Offset over = tester.getCenter(find.bySemanticsIdentifier('probe-projects'));
    void secondMouse(PointerEvent event) => tester.binding.handlePointerEvent(event);
    secondMouse(PointerAddedEvent(viewId: windows.second.viewId, kind: PointerDeviceKind.mouse, device: 7));
    addTearDown(
      () => secondMouse(
        PointerRemovedEvent(viewId: windows.second.viewId, kind: PointerDeviceKind.mouse, device: 7, position: over),
      ),
    );
    secondMouse(
      PointerHoverEvent(viewId: windows.second.viewId, kind: PointerDeviceKind.mouse, device: 7, position: over),
    );
    await tester.pump();
    expect(windows.statuses['projects']!.hovered, isTrue, reason: 'Projects is key');

    WidgetsBinding.instance.handleViewFocusChanged(_focus(windows.second.viewId, ViewFocusState.unfocused));
    await tester.pump();
    expect((appearanceIn(tester, 'main').inactive, appearanceIn(tester, 'projects').inactive), (true, true));
    expect(windows.statuses['projects']!.hovered, isFalse, reason: 'the hover goes with the key status');
  });

  testWidgets('each root registers the app\'s and zanshin_ui\'s strings (Story 11.16)', (tester) async {
    await pumpTwoWindows(tester);

    for (final key in <String>['main', 'projects']) {
      final BuildContext content = tester.element(find.bySemanticsIdentifier('probe-$key'));
      expect(AppLocalizations.of(content)?.projectsTitle, 'Projects', reason: key);
      expect(ZsLocalizations.of(content)?.confirmCancel, 'Cancel', reason: key);
    }
  });

  testWidgets("each root provides the graph's one icon registry to its window", (tester) async {
    await pumpTwoWindows(tester);

    for (final key in <String>['main', 'projects']) {
      final BuildContext content = tester.element(find.bySemanticsIdentifier('probe-$key'));
      expect(IconRegistryScope.maybeOf(content), same(testIconRegistry), reason: key);
    }
  });

  testWidgets('a text field in the dialog window takes typed input', (tester) async {
    final _TwoWindows windows = await pumpTwoWindows(tester);
    WidgetsBinding.instance.handleViewFocusChanged(_focus(windows.second.viewId, ViewFocusState.focused));
    await tester.pump();

    await tester.enterText(
      find.descendant(of: find.byKey(const ValueKey<String>('window:projects')), matching: find.byType(EditableText)),
      'zanshin',
    );
    await tester.pump();

    expect(windows.projects.text, 'zanshin');
    expect(windows.main.text, isEmpty);
  });

  testWidgets('a theme switch through the store restyles both roots, each over its own view model', (tester) async {
    final _TwoWindows windows = await pumpTwoWindows(tester, settingsJson: '{"appearance": {"themeMode": "dark"}}');
    expect(find.byType(ViewModelBuilder<ZanshinAppViewModel>), findsNWidgets(2), reason: 'one view model per window');
    expect(appearanceIn(tester, 'main').theme, ZsTheme.night);
    expect(appearanceIn(tester, 'projects').theme, ZsTheme.night);

    // Settings › Theme writes the store; every window's root follows it (the native chrome: WindowAppearanceSync).
    await tester.runAsync(() => windows.store.update((s) => s.copyWith.appearance(themeMode: ThemeMode.light)));
    await tester.pumpAndSettle();

    expect(appearanceIn(tester, 'main').theme, ZsTheme.paper);
    expect(appearanceIn(tester, 'projects').theme, ZsTheme.paper);
  });

  /// A content-sized root from the component's factory over a 300 × 200 box (key `content`), over the settings [json];
  /// answers the store.
  Future<SettingsStore> pumpContentSized(WidgetTester tester, String json) async {
    final TestComponent graph = await component(tester, json);
    await tester.pumpWidget(
      Align(
        alignment: Alignment.topLeft,
        child: graph.rootFactory.create(
          windowKey: 'settings',
          sizeToContent: true,
          child: const SizedBox(key: ValueKey<String>('content'), width: 300, height: 200),
        ),
      ),
    );
    shell.theme.complete(const ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF4757A1)));
    await tester.pumpAndSettle();
    return graph.settings;
  }

  BuildContext content(WidgetTester tester) => tester.element(find.byKey(const ValueKey<String>('content')));

  testWidgets('a content-sized root has no navigator and takes its content size; the density reaches the tokens, '
      'not the text (Story 11.20)', (tester) async {
    final SettingsStore store = await pumpContentSized(tester, '{"appearance": {"density": "comfy"}}');

    expect(find.byType(Navigator), findsNothing);
    expect(find.byKey(const ValueKey<String>('window:settings')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey<String>('window:settings'))), const Size(300, 200));
    expect(MediaQuery.textScalerOf(content(tester)).scale(12.5), 12.5, reason: 'text keeps its size');
    final metrics = ZsMetrics.of(content(tester));
    expect((metrics.rowStep, metrics.cardHDetailed, metrics.graphGapY), (6, 74, 60));

    // Live: back to Compact restores the standard tokens.
    await tester.runAsync(() => store.update((s) => s.copyWith.appearance(density: DensitySetting.compact)));
    await tester.pumpAndSettle();
    expect(ZsMetrics.of(content(tester)), ZsMetrics.standard);
  });

  testWidgets('the root provides the saved code style and follows the store (Story 10.50)', (tester) async {
    final SettingsStore store = await pumpContentSized(tester, '{"general": {"codeSize": 14}}');
    expect(CodeStyleScope.of(content(tester)).fontSize, 14);
    expect(CodeStyleScope.of(content(tester)).fontFamily, ZsType.monoFamily);

    await tester.runAsync(() => store.update((s) => s.copyWith.general(codeSize: 12)));
    await tester.pumpAndSettle();
    expect(CodeStyleScope.of(content(tester)).fontSize, 12);
  });

  testWidgets('the zoom scales the content and its MediaQuery, and divides the traffic-light block (Story 11.20)', (
    tester,
  ) async {
    shell.chrome = const WindowChrome(trafficLights: Rect.fromLTWH(20, 20, 60, 15));
    final SettingsStore store = await pumpContentSized(tester, '{"appearance": {"zoom": 125}}');
    final MediaQueryData window = MediaQuery.of(tester.element(find.byType(ZanshinWindowRoot)));

    // Drawn 1.25 × larger: the window takes 375 × 250 for the 300 × 200 content.
    expect(tester.getSize(find.byType(WindowZoomBox)), const Size(375, 250));
    expect(tester.getSize(find.byKey(const ValueKey<String>('content'))), const Size(300, 200));
    expect(tester.getBottomRight(find.byKey(const ValueKey<String>('content'))), const Offset(375, 250));
    final MediaQueryData zoomed = MediaQuery.of(content(tester));
    expect(zoomed.size, window.size / 1.25);
    expect(zoomed.devicePixelRatio, window.devicePixelRatio * 1.25);
    expect(ZsAppearance.of(content(tester)).trafficLights, const Rect.fromLTWH(16, 16, 48, 12));
    // The bar's rule in zoomed units: the first island at the block's end + 12.
    final metrics = ZsMetrics.of(content(tester));
    expect(metrics.chromeFirstX, 16 + 48 + 12);
    // Whatever the block's y, the bar stays 12 and the content 68 in zoomed units, centred on the line the runner puts
    // the project window's lights on: 42.5 native at 125 % (Story 11.27).
    expect((metrics.chromeBarY, metrics.chromeTop), (12, 68));
    expect((metrics.chromeBarY + metrics.chromeH / 2) * 1.25, projectButtonMidY(1.25));
    expect(projectButtonMidY(1.25), 42.5);

    // A stored value off the steps snaps; 95 is a tie and goes to 90.
    await tester.runAsync(() => store.update((s) => s.copyWith.appearance(zoom: 95)));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(WindowZoomBox)), const Size(270, 180));
  });
}

/// What `pumpTwoWindows` set up: the settings store, the content's statuses, the two text fields and the second
/// window's view.
class _TwoWindows {
  _TwoWindows({
    required this.store,
    required this.statuses,
    required this.main,
    required this.projects,
    required this.second,
  });

  final SettingsStore store;
  final Map<String, ZsControlStatus> statuses;
  final ZsTextEditingController main;
  final ZsTextEditingController projects;
  final FlutterView second;
}
