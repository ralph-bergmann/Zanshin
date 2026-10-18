// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show DefaultMaterialLocalizations;
import 'package:zanshin/src/features/shell/shell_controller.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'icon_registry.dart';

/// The project window's size in the shell tests.
const shellWindow = Size(1440, 900);

/// Sizes the test surface to [size] (1440 × 900 by default) at device pixel ratio 1.
void useShellWindow(WidgetTester tester, [Size size = shellWindow]) {
  tester.view
    ..physicalSize = size
    ..devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// A window root for the shell tests: [ZsRoot] for [appearance], the icons ([testIconRegistry]; load it with
/// `setUpIconRegistry`), the localizations, the default key bindings with a traversal policy, a `TapRegionSurface` and
/// an `Overlay` whose one entry shows [child] — what the app's `MaterialApp` gives the home page.
Widget shellHost(Widget child, {ZsAppearance appearance = const ZsAppearance()}) => Localizations(
  locale: const Locale('en'),
  delegates: const <LocalizationsDelegate<Object>>[
    DefaultWidgetsLocalizations.delegate,
    DefaultMaterialLocalizations.delegate,
  ],
  child: Directionality(
    textDirection: TextDirection.ltr,
    child: IconRegistryScope(
      registry: testIconRegistry,
      child: ZsRoot(
        appearance: appearance,
        child: TapRegionSurface(
          child: Shortcuts(
            shortcuts: WidgetsApp.defaultShortcuts,
            child: Actions(
              actions: WidgetsApp.defaultActions,
              child: FocusTraversalGroup(child: _OverlayHost(child: child)),
            ),
          ),
        ),
      ),
    ),
  ),
);

/// Two rail items, as the kit has them (DS ui_kits/desktop/chrome.jsx:7-11): Bookmarks and the Undo Timeline.
const demoRailItems = <ShellRailItem>[
  ShellRailItem(
    id: 'bookmarks',
    label: 'Bookmarks',
    icon: ZI.branch,
    count: '3',
    preview: Text('main · feat/x · fix/y'),
    panel: Text('The bookmark list'),
  ),
  ShellRailItem(
    id: 'undo',
    label: 'Undo Timeline',
    icon: ZI.undo,
    count: '12 ops',
    preview: Text('jj new · jj squash'),
    panel: Text('The operation log'),
  ),
];

/// An `Overlay` whose one entry shows [child], rebuilt when [child] changes.
class _OverlayHost extends StatefulWidget {
  const _OverlayHost({required this.child});

  final Widget child;

  @override
  State<_OverlayHost> createState() => _OverlayHostState();
}

class _OverlayHostState extends State<_OverlayHost> {
  late final _entry = OverlayEntry(builder: (_) => widget.child);

  @override
  void didUpdateWidget(_OverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    _entry.markNeedsBuild();
  }

  @override
  void dispose() {
    _entry
      ..remove()
      ..dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Overlay(initialEntries: <OverlayEntry>[_entry]);
}
