// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zanshin/src/features/window/app_windows.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../widgetbook/catalogue.dart';
import '../../widgetbook/folders/windows.dart';
import 'icon_registry.dart';

/// The catalogue window's content at [route], as `widgetbook/main.dart` builds it (no window is opened), over
/// [windows] (by default ones that never exit the process).
Widget catalogueAt(String route, {GlobalKey<ZanshinCatalogueState>? key, AppWindows? windows}) => IconRegistryScope(
  registry: testIconRegistry,
  child: CatalogueWindows(
    windows: windows ?? AppWindows(exitProcess: () async {}),
    child: ZanshinCatalogue(key: key, initialRoute: route),
  ),
);

/// The catalogue window's size.
void useCatalogueWindow(WidgetTester tester) {
  tester.view
    ..physicalSize = const Size(1440, 900)
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// Whether the Appearance addon's canvas in [theme] is on screen.
Finder canvasOf(ZsTheme theme) {
  final Color canvas = ZsColors.resolve(ZsAppearance(theme: theme)).canvasBase;
  return find.byWidgetPredicate((widget) => widget is ColoredBox && widget.color == canvas);
}
