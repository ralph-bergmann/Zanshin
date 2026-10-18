// SPDX-License-Identifier: MIT

// WHY: the windowing API is experimental and only reachable through implementation imports
// (https://github.com/flutter/flutter/issues/30701).
// ignore: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/src/foundation/_features.dart' show isWindowingEnabled;
// WHY: as above — `WindowScope` and the window controllers live in the experimental windowing library.
// ignore: implementation_imports, invalid_use_of_internal_member
import 'package:flutter/src/widgets/_window.dart' show BaseWindowController, WindowController, WindowScope;
import 'package:flutter/widgets.dart';

/// Gives the window around [child] the title [title] (epics.md Story 11.5 item 8, Claude's proposal): the project's
/// name, for the Window menu and Mission Control; the bar itself shows no title. It sets the enclosing window's title
/// when it differs, after the frame (setting a title notifies the window); without a window it does nothing.
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
    // WHY: the windowing feature flag is internal API; without it `WindowScope.maybeOf` throws instead of answering.
    // ignore: invalid_use_of_internal_member
    if (!isWindowingEnabled) {
      return;
    }
    // WHY: `WindowScope.maybeOf` is the windowing API's internal lookup of the window around a context.
    // ignore: invalid_use_of_internal_member
    final BaseWindowController? window = WindowScope.maybeOf(context);
    // WHY: the regular window's controller, which has a title, is internal API too.
    // ignore: invalid_use_of_internal_member
    if (window is! WindowController) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String title = widget.title;
      // WHY: `WindowController.title` and `setTitle` are the windowing API's internal members.
      // ignore: invalid_use_of_internal_member
      if (mounted && window.title != title) {
        // WHY: as above.
        // ignore: invalid_use_of_internal_member
        window.setTitle(title);
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
