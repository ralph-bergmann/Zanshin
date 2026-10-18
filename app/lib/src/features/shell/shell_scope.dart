// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

import 'graph_insets.dart';
import 'shell_controller.dart';
import 'shell_layout.dart';

/// Hands the floating shell's [layout] and [controller] to its slots (10.5 item 14-15, the other side of the
/// contract): the graph reads its [GraphInsets] through [insetsOf] and rebuilds when they change — every frame of an
/// edge drag — and every slot reaches the controller through [of] to hold calm while a surface is open
/// (`openSurface`), start an item drag (`startItemDrag`), report pans, flings and minimap scrolling
/// (`reportUserScroll`) and read the phase (`calm`). The inspector's resize edge (10.8) binds to the controller's
/// `inspectorWidth`, `commitInspectorWidth` and `edgeDragStarted`/`edgeDragEnded` and to [layoutOf]'s
/// `inspectorMax`; it sits in the shell beside the inspector slot (see `FloatingShell`).
class ShellScope extends InheritedWidget {
  /// Provides [layout] and [controller] to [child].
  const ShellScope({required this.controller, required this.layout, required super.child, super.key});

  /// The shell's controller.
  final ShellController controller;

  /// The shell's current layout.
  final ShellLayout layout;

  /// The insets of the nearest shell; the caller rebuilds when they change.
  static GraphInsets insetsOf(BuildContext context) => layoutOf(context).insets;

  /// The layout of the nearest shell (the inspector edge's drag limit, 10.8); the caller rebuilds when it changes.
  static ShellLayout layoutOf(BuildContext context) {
    final ShellScope? scope = context.dependOnInheritedWidgetOfExactType<ShellScope>();
    assert(scope != null, 'No ShellScope above this widget: it must sit in a FloatingShell slot.');
    return scope!.layout;
  }

  /// The controller of the nearest shell. It does not register a dependency: call it from callbacks, or listen to
  /// the controller.
  static ShellController of(BuildContext context) {
    final ShellScope? scope = context.getInheritedWidgetOfExactType<ShellScope>();
    assert(scope != null, 'No ShellScope above this widget: it must sit in a FloatingShell slot.');
    return scope!.controller;
  }

  @override
  bool updateShouldNotify(ShellScope oldWidget) => layout != oldWidget.layout || controller != oldWidget.controller;
}
