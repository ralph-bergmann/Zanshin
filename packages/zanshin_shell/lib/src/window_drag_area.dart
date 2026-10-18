// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import 'zanshin_shell.dart';

/// Makes its subtree behave like a native macOS titlebar: dragging moves the
/// window and double-clicking performs the system titlebar action.
///
/// Interactive children (buttons etc.) keep working - they win the gesture
/// arena for taps, while an actual drag movement starts the window drag.
///
/// Implements [PreferredSizeWidget] so it can wrap an app bar in a scaffold's
/// app-bar slot directly; outside that slot the preferred size is ignored.
class WindowDragArea extends StatelessWidget implements PreferredSizeWidget {
  const WindowDragArea({required this.child, super.key});

  /// The preferred height without a [PreferredSizeWidget] child: Material's
  /// toolbar height, kept as a constant so this package needs no Material
  /// import (the house rule takes Material types from `material_ui` only).
  static const double _toolbarHeight = 56;

  final Widget child;

  @override
  Size get preferredSize => child is PreferredSizeWidget
      ? (child as PreferredSizeWidget).preferredSize
      : const Size.fromHeight(_toolbarHeight);

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => ZanshinShell.startWindowDrag(),
    onDoubleTap: ZanshinShell.performTitlebarDoubleClickAction,
    child: child,
  );
}
