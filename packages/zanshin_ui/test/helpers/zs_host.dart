// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show DefaultMaterialLocalizations;
import 'package:zanshin_ui/src/design/zs_appearance.dart';
import 'package:zanshin_ui/src/design/zs_root.dart';
import 'package:zanshin_ui/src/icons/icon_registry.dart';

import 'icon_registry.dart';

/// A window root for material and control tests: [ZsRoot] for [appearance], the widgets and material localizations
/// (the radio's and the text field's), the default key bindings of a `WidgetsApp` (Tab and Shift+Tab traversal, Esc)
/// with a traversal policy, a [BackdropGroup] unless [group] is false (11.3's per-window group), and [child] centred
/// on the test surface.
///
/// [overlay] puts everything in an `Overlay` with one entry under a `TapRegionSurface` (both a `WidgetsApp`'s), for
/// the controls that float something (menus, the select, tooltips); [icons] provides [testIconRegistry] (load it with `setUpIconRegistry`).
Widget zsHost(
  Widget child, {
  ZsAppearance appearance = const ZsAppearance(),
  bool group = true,
  bool overlay = false,
  bool icons = false,
}) {
  final Widget centred = Center(child: child);
  final Widget keys = Shortcuts(
    shortcuts: WidgetsApp.defaultShortcuts,
    child: Actions(
      actions: WidgetsApp.defaultActions,
      child: FocusTraversalGroup(child: group ? BackdropGroup(child: centred) : centred),
    ),
  );
  final Widget content = overlay ? TapRegionSurface(child: _OverlayHost(child: keys)) : keys;
  Widget root = ZsRoot(appearance: appearance, child: content);
  if (icons) {
    root = IconRegistryScope(registry: testIconRegistry, child: root);
  }
  return Localizations(
    locale: const Locale('en'),
    delegates: const <LocalizationsDelegate<Object>>[
      DefaultWidgetsLocalizations.delegate,
      DefaultMaterialLocalizations.delegate,
    ],
    child: Directionality(textDirection: TextDirection.ltr, child: root),
  );
}

/// An `Overlay` whose one entry shows [child], rebuilt when [child] changes (an `Overlay`'s initial entries are read
/// only once).
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
