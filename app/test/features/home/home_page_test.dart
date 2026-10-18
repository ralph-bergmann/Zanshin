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
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../helpers/icon_registry.dart';
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

  testWidgets('the home is the floating shell: canvas fill, a drag row over the bar, four empty islands, no rail', (
    tester,
  ) async {
    useShellWindow(tester);
    final Directory dir = (await tester.runAsync(() => Directory.systemTemp.createTemp('home_page_test')))!;
    addTearDown(() => dir.deleteSync(recursive: true));
    final SettingsStore store = (await tester.runAsync(() => SettingsStore.load(File('${dir.path}/settings.json'))))!;

    await tester.pumpWidget(shellHost(HomePage(zanshinFfiVersion: () => 'test', viewModelFactory: _factory(store))));

    expect(find.byType(FloatingShell), findsOneWidget);
    final Color canvas = ZsColors.night.canvasBase;
    expect(find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color == canvas), findsOneWidget);
    expect(tester.getRect(find.byType(WindowDragArea)), const Rect.fromLTWH(0, 0, 1440, 60));
    final RenderObject canvasBox = tester.renderObject(
      find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color == canvas),
    );
    bool reachesCanvas(Offset at) => tester.hitTestOnBinding(at).path.any((entry) => entry.target == canvasBox);
    expect(reachesCanvas(const Offset(600, 30)), isFalse, reason: 'a press in the bar row moves the window only');
    expect(reachesCanvas(const Offset(600, 400)), isTrue, reason: 'below it the canvas (the graph) takes it');
    final Finder empty = find.byType(ShellEmptyIsland);
    expect(empty, findsNWidgets(4));
    for (var i = 0; i < 4; i++) {
      expect(tester.getSize(empty.at(i)), const Size.square(44));
    }
    expect(find.byType(ShellRail), findsNothing);
    expect(find.byType(PinnedPanel), findsNothing);
  });
}
