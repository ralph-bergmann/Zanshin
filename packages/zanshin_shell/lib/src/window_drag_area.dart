// SPDX-License-Identifier: MIT

import 'package:flutter/material.dart';

import 'zanshin_shell.dart';

/// Makes its subtree behave like a native macOS titlebar: dragging moves the
/// window and double-clicking performs the system titlebar action.
///
/// Interactive children (buttons etc.) keep working - they win the gesture
/// arena for taps, while an actual drag movement starts the window drag.
///
/// Implements [PreferredSizeWidget] so it can wrap an [AppBar] directly in
/// `Scaffold.appBar`; outside that slot the preferred size is ignored.
class WindowDragArea extends StatelessWidget implements PreferredSizeWidget {
  const WindowDragArea({required this.child, super.key});

  final Widget child;

  @override
  Size get preferredSize => child is PreferredSizeWidget
      ? (child as PreferredSizeWidget).preferredSize
      : const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onPanStart: (_) => ZanshinShell.startWindowDrag(),
    onDoubleTap: ZanshinShell.performTitlebarDoubleClickAction,
    child: child,
  );
}
