// SPDX-License-Identifier: MIT

import 'dart:io';
import 'dart:ui' show Scene, SemanticsUpdate, ViewFocusDirection, ViewFocusEvent, ViewFocusState;

import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:zanshin/src/features/app/zanshin_app_view_model.dart';
import 'package:zanshin/src/features/window/active_window_tracker.dart';
import 'package:zanshin/src/features/window/zanshin_window_root.dart';
import 'package:zanshin/src/l10n/strings.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
import '../../helpers/recording_shell.dart';

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

class _Provider<T> implements Provider<T> {
  _Provider(this._create);

  final T Function() _create;

  @override
  T get() => _create();
}

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
  late RecordingShell shell;
  late Directory dir;

  setUp(() async {
    ZanshinShellPlatform.instance = shell = RecordingShell();
    dir = await Directory.systemTemp.createTemp('zanshin_window_root_test');
    // macOS's highlight mode is always "traditional" (RC §4), whatever input the test sends.
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.alwaysTraditional;
  });

  tearDown(() async {
    FocusManager.instance.highlightStrategy = FocusHighlightStrategy.automatic;
    await shell.close();
    await dir.delete(recursive: true);
  });

  /// The project window (the test view) and the Projects window (a second view), each under its own root over one
  /// settings store and one tracker; answers the tracker, the view models the roots made, the content's statuses and
  /// the two text fields.
  Future<_TwoWindows> pumpTwoWindows(WidgetTester tester, {String settingsJson = '{}'}) async {
    tester.view
      ..physicalSize = const Size(900, 640)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SettingsStore store = (await tester.runAsync(() async {
      final file = File('${dir.path}/settings.json');
      await file.writeAsString(settingsJson);
      return SettingsStore.load(file);
    }))!;
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);
    final viewModels = <ZanshinAppViewModel>[];
    final statuses = <String, ZsControlStatus>{};
    final main = ZsTextEditingController();
    final projects = ZsTextEditingController();
    addTearDown(main.dispose);
    addTearDown(projects.dispose);
    final second = _SecondView(tester.view);
    ZanshinWindowRoot root(String windowKey, ZsTextEditingController field) => ZanshinWindowRoot(
      viewModelFactory: _viewModels(() {
        final viewModel = ZanshinAppViewModel(store);
        viewModels.add(viewModel);
        return viewModel;
      }),
      tracker: tracker,
      windowKey: windowKey,
      child: _Content(name: windowKey, statuses: statuses, field: field),
    );
    await tester.pumpWidget(
      IconRegistryScope(
        registry: testIconRegistry,
        child: ViewCollection(
          views: <Widget>[
            View(view: tester.view, child: root('main', main)),
            View(view: second, child: root('projects', projects)),
          ],
        ),
      ),
      wrapWithView: false,
    );
    shell.theme.complete(const ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF4757A1)));
    await tester.pumpAndSettle();
    return _TwoWindows(viewModels: viewModels, statuses: statuses, main: main, projects: projects, second: second);
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

  testWidgets(
    'a theme switch from either window restyles both roots and asks the shell to restyle the native windows',
    (
      tester,
    ) async {
      final _TwoWindows windows = await pumpTwoWindows(
        tester,
        settingsJson: '{"appearance": {"themeMode": "dark"}}',
      );
      expect(windows.viewModels, hasLength(2), reason: 'one view model per window');
      expect(appearanceIn(tester, 'main').theme, ZsTheme.night);
      expect(appearanceIn(tester, 'projects').theme, ZsTheme.night);

      // From the Projects window's root.
      await tester.runAsync(() => windows.viewModels.last.setThemeMode(ThemeMode.light));
      await tester.pumpAndSettle();

      expect(appearanceIn(tester, 'main').theme, ZsTheme.paper);
      expect(appearanceIn(tester, 'projects').theme, ZsTheme.paper);
      expect(shell.calls, contains('setWindowAppearance:light'), reason: 'the shell applies it to every app window');
    },
  );

  testWidgets('a content-sized root has no navigator and takes its content size; the density scales its text', (
    tester,
  ) async {
    final SettingsStore store = (await tester.runAsync(() async {
      final file = File('${dir.path}/settings.json');
      await file.writeAsString('{"appearance": {"density": "comfy"}}');
      return SettingsStore.load(file);
    }))!;
    final tracker = ActiveWindowTracker();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(
      IconRegistryScope(
        registry: testIconRegistry,
        child: Center(
          child: ZanshinWindowRoot(
            viewModelFactory: _viewModels(() => ZanshinAppViewModel(store)),
            tracker: tracker,
            windowKey: 'settings',
            sizeToContent: true,
            child: const SizedBox(key: ValueKey<String>('content'), width: 300, height: 200),
          ),
        ),
      ),
    );
    shell.theme.complete(const ShellTheme(brightness: Brightness.dark, accentColor: Color(0xFF4757A1)));
    await tester.pumpAndSettle();

    expect(find.byType(Navigator), findsNothing);
    expect(find.byKey(const ValueKey<String>('window:settings')), findsOneWidget);
    expect(tester.getSize(find.byKey(const ValueKey<String>('window:settings'))), const Size(300, 200));
    final BuildContext content = tester.element(find.byKey(const ValueKey<String>('content')));
    expect(MediaQuery.textScalerOf(content).scale(12.5), moreOrLessEquals(13.5));
    expect(ZanshinWindowRoot.textScaleOf(DensitySetting.compact), 1);
    expect(ZanshinWindowRoot.textScaleOf(DensitySetting.balanced) * 12.5, moreOrLessEquals(13));
  });
}

/// What `pumpTwoWindows` set up: the view models the roots made, the content's statuses, the two text fields and the
/// second window's view.
class _TwoWindows {
  _TwoWindows({
    required this.viewModels,
    required this.statuses,
    required this.main,
    required this.projects,
    required this.second,
  });

  final List<ZanshinAppViewModel> viewModels;
  final Map<String, ZsControlStatus> statuses;
  final ZsTextEditingController main;
  final ZsTextEditingController projects;
  final FlutterView second;
}
