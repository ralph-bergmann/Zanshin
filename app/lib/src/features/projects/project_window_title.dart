// SPDX-License-Identifier: MIT

// WHY: the windowing API is experimental and only reachable through implementation imports
// (https://github.com/flutter/flutter/issues/30701): the feature flag, `WindowScope`, the window controllers and their
// `title` / `setTitle` are all its internal members.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
import 'package:flutter/src/widgets/_window.dart'
    show BaseWindowController, DialogWindowController, WindowController, WindowScope;
import 'package:flutter/widgets.dart';

/// Gives the window around [child] the title [title] (epics.md Story 11.5 item 8, Claude's proposal): the project's
/// name, for the Window menu and Mission Control; the bar itself shows no title. A dialog window (Settings, Story 11.7)
/// is titled the same way. It sets the enclosing window's title when it differs, after the frame (setting a title
/// notifies the window); without a window it does nothing.
class ProjectWindowTitle extends StatefulWidget {
  /// Titles the window around [child] [title].
  const ProjectWindowTitle({required this.title, required this.child, super.key});

  /// The window's title.
  final String title;

  /// The window's content.
  final Widget child;

  @override
  State<ProjectWindowTitle> createState() => _ProjectWindowTitleState();
}

class _ProjectWindowTitleState extends State<ProjectWindowTitle> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(ProjectWindowTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    _sync();
  }

  void _sync() {
    // Without the windowing feature flag `WindowScope.maybeOf` throws instead of answering.
    if (!isWindowingEnabled) {
      return;
    }
    final BaseWindowController? window = WindowScope.maybeOf(context);
    if (window is! WindowController && window is! DialogWindowController) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String title = widget.title;
      if (!mounted) {
        return;
      }
      if (window case final WindowController regular when regular.title != title) {
        regular.setTitle(title);
      } else if (window case final DialogWindowController dialog when dialog.title != title) {
        dialog.setTitle(title);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
