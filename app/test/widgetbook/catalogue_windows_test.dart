// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/shell/floating_shell.dart';
import 'package:zanshin/src/features/shell/rail.dart';
import 'package:zanshin/src/features/shell/top_bar.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_shell_platform_interface/zanshin_shell_platform_interface.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../widgetbook/catalogue.dart';
import '../../widgetbook/folders/shell.dart';
import '../../widgetbook/folders/windows.dart';
import '../helpers/catalogue.dart';
import '../helpers/icon_registry.dart';
import '../helpers/recording_shell.dart';

/// A measured block one point off the DS reference (19, 19, 60, 14).
const _block = WindowChrome(trafficLights: Rect.fromLTWH(20, 20, 60, 14));

/// Records the builder of every window the catalogue opens instead of opening one.
class _RecordingWindows extends AppWindows {
  _RecordingWindows() : super(exitProcess: () async {});

  /// The builders handed to [openOrActivate], by window key.
  final opened = <String, WidgetBuilder>{};

  @override
  Future<void> openOrActivate({
    required String key,
    required String title,
    required WidgetBuilder builder,
    Size size = defaultWindowSize,
    BoxConstraints constraints = defaultWindowConstraints,
  }) async {
    opened[key] = builder;
  }
}

void main() {
  setUpIconRegistry();
  late RecordingShell shell;
  setUp(() => ZanshinShellPlatform.instance = shell = RecordingShell());
  tearDown(() => shell.close());

  /// The chrome watches recorded so far.
  Iterable<String> watches() => shell.calls.where((call) => call.startsWith('watchWindowChrome'));

  /// Shows the catalogue at the Windows use case [path], presses its [button] and pumps the builder it hands to
  /// `openOrActivate` as the new window's content, in a 1440 × 900 window.
  Future<void> openWindow(WidgetTester tester, String path, String button) async {
    useCatalogueWindow(tester);
    final windows = _RecordingWindows();
    await tester.pumpWidget(catalogueAt('/?path=$path', windows: windows));
    await tester.pump();
    await tester.tap(find.bySemanticsIdentifier(button));
    await tester.pump();
    expect(watches(), isEmpty, reason: 'nothing watches the chrome before the window root builds');
    final WidgetBuilder builder = windows.opened.values.single;
    await tester.pumpWidget(
      IconRegistryScope(
        registry: testIconRegistry,
        child: Builder(builder: builder),
      ),
    );
  }

  /// Opens Windows › Floating shell's window.
  Future<void> openFloatingShell(WidgetTester tester) =>
      openWindow(tester, 'windows/floating-shell/floating-shell', 'open-floating-shell');

  /// The shell's chrome metrics: the first island's x, the bar's y and the content top.
  List<double> chromeOf(WidgetTester tester) {
    final metrics = ZsMetrics.of(tester.element(find.byType(FloatingShell)));
    return <double>[metrics.chromeFirstX, metrics.chromeBarY, metrics.chromeTop];
  }

  /// Where the bar starts and where the rail's top is.
  (Offset, double) shellLayout(WidgetTester tester) =>
      (tester.getTopLeft(find.byType(ShellTopBar)), tester.getTopLeft(find.byType(ShellRail)).dy);

  testWidgets(
    "Windows › Floating shell's window is a CatalogueWindowRoot over the demo, laid out on the measured block",
    (tester) async {
      shell.chrome = _block;
      await openFloatingShell(tester);
      await tester.pumpAndSettle();

      expect(
        find.descendant(of: find.byType(CatalogueWindowRoot), matching: find.byType(FloatingShellDemo)),
        findsOneWidget,
      );
      expect(watches(), <String>['watchWindowChrome:${tester.view.viewId}']);
      expect(ZsAppearance.of(tester.element(find.byType(FloatingShell))).trafficLights, _block.trafficLights);
      expect(chromeOf(tester), <double>[92, 5, 61]);
      expect(shellLayout(tester), (const Offset(92, 5), 61.0));
    },
  );

  testWidgets("full screen reaches the window's shell; leaving it brings the block back", (tester) async {
    shell.chrome = _block;
    await openFloatingShell(tester);
    await tester.pumpAndSettle();
    final int viewId = tester.view.viewId;

    shell.chromeChanges.add((viewId: viewId, chrome: const WindowChrome(fullScreen: true)));
    await tester.pumpAndSettle();
    expect(ZsAppearance.of(tester.element(find.byType(FloatingShell))).fullScreen, isTrue);
    expect(shellLayout(tester), (const Offset(12, 12), 68.0));

    shell.chromeChanges.add((viewId: viewId, chrome: _block));
    await tester.pumpAndSettle();
    expect(ZsAppearance.of(tester.element(find.byType(FloatingShell))).fullScreen, isFalse);
    expect(chromeOf(tester), <double>[92, 5, 61]);
    expect(shellLayout(tester), (const Offset(92, 5), 61.0));
  });

  testWidgets('while the watch is unanswered the window keeps the reference geometry', (tester) async {
    shell.chromeAnswer = Completer<WindowChrome>();
    await openFloatingShell(tester);
    await tester.pumpAndSettle();

    expect(watches(), <String>['watchWindowChrome:${tester.view.viewId}']);
    expect(shellLayout(tester), (const Offset(91, 4), 60.0));
  });

  testWidgets('the window root leaving the tree unwatches its view', (tester) async {
    await openFloatingShell(tester);
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());

    expect(
      shell.calls.where((call) => call.startsWith('unwatchWindowChrome')),
      <String>['unwatchWindowChrome:${tester.view.viewId}'],
    );
  });

  testWidgets('the window takes the shell theme the catalogue had when the button was pressed', (tester) async {
    // A shell made inside the test body answers on the fake clock's microtasks; setUp's answers would never arrive.
    final outside = shell;
    addTearDown(outside.close);
    ZanshinShellPlatform.instance = shell = RecordingShell();
    const theme = ShellTheme(brightness: Brightness.light, accentColor: Color(0xFF4757A1));
    shell.theme.complete(theme);
    await openFloatingShell(tester);
    await tester.pumpAndSettle();

    final Element probe = tester.element(find.byType(FloatingShell));
    expect(ZsShellScope.maybeOf(probe), theme);
    expect(ZsAppearance.of(probe).theme, ZsTheme.paper);
  });

  testWidgets("Windows › Window fill's window is a CatalogueWindowRoot over a ZsWindowFill that watches its view", (
    tester,
  ) async {
    await openWindow(tester, 'windows/window-fill/window-fill', 'open-window-fill');
    await tester.pumpAndSettle();

    expect(
      find.descendant(of: find.byType(CatalogueWindowRoot), matching: find.byType(ZsWindowFill)),
      findsOneWidget,
    );
    expect(watches(), <String>['watchWindowChrome:${tester.view.viewId}']);
  });

  for (final (String path, String? button) in const <(String, String?)>[
    ('shell/floating-shell/slots', null),
    ('windows/floating-shell/floating-shell', 'open-floating-shell'),
    ('windows/window-fill/window-fill', 'open-window-fill'),
  ]) {
    testWidgets('the preview $path watches no chrome', (tester) async {
      useCatalogueWindow(tester);
      await tester.pumpWidget(catalogueAt('/?path=$path'));
      await tester.pumpAndSettle();

      expect(watches(), isEmpty);
      if (button == null) {
        expect(chromeOf(tester), <double>[91, 4, 60], reason: "the preview's shell keeps the reference metrics");
      } else {
        expect(find.bySemanticsIdentifier(button), findsOneWidget, reason: 'the use case shows its button');
      }
    });
  }

  testWidgets("the Shell folder's full-screen knob lays the demo out in full screen without a report", (tester) async {
    useCatalogueWindow(tester);
    await tester.pumpWidget(
      IconRegistryScope(
        registry: testIconRegistry,
        child: Builder(
          builder: (context) =>
              catalogueAppBuilder(context, const FloatingShellDemo(state: ShellDemoState.layout, fullScreen: true)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(watches(), isEmpty);
    expect(tester.getTopLeft(find.byType(ShellTopBar)), const Offset(12, 12));
  });
}
