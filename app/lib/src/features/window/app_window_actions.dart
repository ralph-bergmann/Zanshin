// SPDX-License-Identifier: MIT

import 'package:flutter/widgets.dart';

/// What a window's content may ask of the app's windows (Story 11.12): opening the other windows, so the content
/// itself stays window-agnostic. 11.7 adds Settings, 11.13 binds the shortcuts.
abstract interface class AppWindowActions {
  /// Opens the Projects window, or brings it to the front (All Projects…, ⇧⌘O).
  Future<void> openProjects();

  /// Opens the jj log Configurations window, or brings it forward with its edits kept (Edit Configurations…, ⌥⌘L;
  /// Story 10.22).
  Future<void> openRevsetConfigs();
}

/// Provides the [AppWindowActions] to a window's content; the window coordinator places one in each root it builds.
/// Outside one (a catalogue preview, a test) there are none, and the rows that need them stay disabled.
class AppWindowActionsScope extends InheritedWidget {
  /// Provides [actions] to [child].
  const AppWindowActionsScope({required this.actions, required super.child, super.key});

  /// The app's window actions.
  final AppWindowActions actions;

  /// The nearest actions, or null outside a window the coordinator built.
  static AppWindowActions? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppWindowActionsScope>()?.actions;

  @override
  bool updateShouldNotify(AppWindowActionsScope oldWidget) => !identical(actions, oldWidget.actions);
}
