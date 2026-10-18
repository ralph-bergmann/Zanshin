// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show ProjectEntry;
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../bootstrap/boot_window_host.dart' show mainWindowTitle;
import '../projects/project_capsule.dart';
import '../projects/project_session.dart';
import '../projects/project_window_title.dart';
import '../shell/floating_shell.dart';
import '../shell/floating_shell_view_model.dart';
import '../shell/top_bar.dart';

part 'home_page.factory.dart';

/// The project window's content: the floating shell (Story 11.3) on the window canvas, `ZsCanvas` (Story 11.4).
///
/// PLACE holds the open project's capsule (Story 11.5), the empty island while none is open; the window takes the
/// project's name as its title, "Zanshin" without one. Every other slot stays empty until its story fills it
/// (Claude's proposal). The bar's row is the window's drag region (design question (a), decision (g); Story 11.4):
/// from the window's top edge down to the content top, the part the islands leave empty moves the window on a drag
/// and runs the system's titlebar action on a double-click.
@immutable
class HomePage extends StatelessWidget {
  @assistedInject
  const HomePage({
    required this.viewModelFactory,
    required this.projects,
    @assisted super.key,
  });

  /// Binds the shell's view model to this page.
  final ViewModelFactory<FloatingShellViewModel> viewModelFactory;

  /// The open project.
  final ProjectSession projects;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: projects,
    builder: (context, shell) => ProjectWindowTitle(title: projects.current?.name ?? mainWindowTitle, child: shell!),
    child: viewModelFactory(
      builder: (context, vm, _) => FloatingShell(
        controller: vm.shell,
        canvas: const ZsCanvas(),
        // An opaque target, so a press in the bar's row moves the window and never reaches the graph below.
        barRow: const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
        projectCapsule: ListenableBuilder(listenable: projects, builder: (context, _) => _place()),
      ),
    ),
  );

  /// PLACE: the capsule of the open project, else the empty island. All Projects… stays disabled until 11.12 opens the
  /// Projects window (11.6 built its content), Project Settings… and Settings… until 11.7 passes their actions.
  Widget _place() {
    final ProjectEntry? project = projects.current;
    if (project == null) {
      return const ShellEmptyIsland();
    }
    return ProjectCapsule(project: project, recent: projects.recent, onOpen: (path) => unawaited(projects.open(path)));
  }
}
