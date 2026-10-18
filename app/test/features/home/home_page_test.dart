// SPDX-License-Identifier: MIT

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:inject_annotation/inject_annotation.dart' show Provider;
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin/src/features/home/home_page.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/floating_shell_view_model.dart';
import 'package:zanshin/src/features/shell/pinned_panel.dart';
import 'package:zanshin/src/features/shell/rail.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart' show ZanshinShellPlatform;
import 'package:zanshin_ui/zanshin_ui.dart';

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

  /// Pumps the home page over a fresh settings store in a 1440 × 900 window showing [appearance].
  Future<void> pumpHome(WidgetTester tester, {ZsAppearance appearance = const ZsAppearance()}) async {
    useShellWindow(tester);
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('home_page_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;
    await tester.pumpWidget(shellHost(HomePage(viewModelFactory: _factory(store)), appearance: appearance));
  }

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

  testWidgets('in full screen the drag row ends at 68 and the first island sits at 12, 12', (tester) async {
    await pumpHome(tester, appearance: const ZsAppearance(fullScreen: true));

    expect(tester.getRect(find.byType(WindowDragArea)), const Rect.fromLTWH(0, 0, 1440, 68));
    expect(tester.getTopLeft(find.byType(ShellEmptyIsland).first), const Offset(12, 12));
  });
}
