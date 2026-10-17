// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';
import 'package:zanshin/src/shared/design/zs_appearance.dart';
import 'package:zanshin/src/shared/design/zs_root.dart';

/// A window root for material tests: [ZsRoot] for [appearance], the default key bindings of a `WidgetsApp` (Tab and
/// Shift+Tab traversal, Esc) with a traversal policy, a [BackdropGroup] unless [group] is false (11.3's per-window
/// group), and [child] centred on the test surface.
Widget zsHost(Widget child, {ZsAppearance appearance = const ZsAppearance(), bool group = true}) {
  final Widget centred = Center(child: child);
  return Directionality(
    textDirection: TextDirection.ltr,
    child: ZsRoot(
      appearance: appearance,
      child: Shortcuts(
        shortcuts: WidgetsApp.defaultShortcuts,
        child: Actions(
          actions: WidgetsApp.defaultActions,
          child: FocusTraversalGroup(child: group ? BackdropGroup(child: centred) : centred),
        ),
      ),
    ),
  );
}
