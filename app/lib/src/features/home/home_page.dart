// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show ProjectEntry;
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../bootstrap/boot_window_host.dart' show mainWindowTitle;
import '../projects/project_capsule.dart';
import '../projects/project_session.dart';
import '../projects/project_window_title.dart';
import '../shell/floating_shell.dart';
import '../shell/floating_shell_view_model.dart';
import '../shell/shell_toast.dart';
import '../shell/top_bar.dart';
import '../window/app_window_actions.dart';

part 'home_page.factory.dart';

/// The project window's content: the floating shell (Story 11.3) on the window canvas, `ZsCanvas` (Story 11.4).
///
/// PLACE holds the open project's capsule (Story 11.5), the empty island while none is open; the window takes the
/// project's name as its title, "Zanshin" without one. The toast slot hosts the view model's [ShellToasts] while one
/// shows or leaves, a creation's warnings among them (Story 10.23). Every other slot stays empty until its story fills it
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
  Widget build(BuildContext context) => _OnWindowActive(
    // What other apps changed in the working copy meanwhile.
    onActive: projects.refresh,
    child: ListenableBuilder(
      listenable: projects,
      builder: (context, shell) => ProjectWindowTitle(title: projects.current?.name ?? mainWindowTitle, child: shell!),
      child: viewModelFactory(
        builder: (context, vm, _) => _OpenReportToast(
          session: projects,
          toasts: vm.toasts,
          child: ListenableBuilder(
            listenable: vm.toasts,
            builder: (context, _) => FloatingShell(
              controller: vm.shell,
              canvas: const ZsCanvas(),
              // An opaque target, so a press in the bar's row moves the window and never reaches the graph below.
              barRow: const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
              projectCapsule: ListenableBuilder(listenable: projects, builder: (context, _) => _place(context)),
              toast: vm.toasts.occupied ? ShellToastView(toasts: vm.toasts) : null,
            ),
          ),
        ),
      ),
    ),
  );

  /// PLACE: the capsule of the open project, else the empty island. All Projects… opens or brings forward the Projects
  /// window through the window's [AppWindowActionsScope] (Story 11.12) and stays disabled without one (a catalogue
  /// preview); Project Settings… and Settings… stay disabled until 11.7 passes their actions.
  Widget _place(BuildContext context) {
    final ProjectEntry? project = projects.current;
    if (project == null) {
      return const ShellEmptyIsland();
    }
    final AppWindowActions? windows = AppWindowActionsScope.maybeOf(context);
    return ProjectCapsule(
      project: project,
      recent: projects.recent,
      onOpen: (path) => unawaited(projects.open(path)),
      onAllProjects: windows == null ? null : () => unawaited(windows.openProjects()),
    );
  }
}

/// Shows the [session]'s creation report in [toasts] — at mount and whenever one arrives — and takes it (Story 10.23,
/// I2): "Opened ‹name›" with each warning as a warn clause, every line in the tooltip, no Undo.
class _OpenReportToast extends StatefulWidget {
  const _OpenReportToast({required this.session, required this.toasts, required this.child});

  final ProjectSession session;
  final ShellToasts toasts;
  final Widget child;

  @override
  State<_OpenReportToast> createState() => _OpenReportToastState();
}

class _OpenReportToastState extends State<_OpenReportToast> {
  @override
  void initState() {
    super.initState();
    widget.session.openReport.addListener(_report);
    // After this frame: showing notifies the toast slot's builder, which may not build during this one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _report();
      }
    });
  }

  @override
  void dispose() {
    widget.session.openReport.removeListener(_report);
    super.dispose();
  }

  void _report() {
    if (widget.session.openReport.value == null) {
      return;
    }
    final ProjectOpenReport report = widget.session.takeOpenReport()!;
    widget.toasts.show(
      ShellToastEntry(
        tone: ZsToastTone.success,
        build: (context, dismiss) => ZsToast(
          message: toastWithWarnings(
            ZsColors.of(context),
            toastSpan(context.l10n.toastOpened(toastSlot(0)), <InlineSpan>[TextSpan(text: report.name)]),
            report.warnings,
          ),
          tooltip: report.warnings.map((w) => w.message).join('\n'),
          onDismiss: dismiss,
          identifier: 'project-toast',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Runs [onActive] each time the window turns active again ([ZsAppearance.inactive] true → false).
class _OnWindowActive extends StatefulWidget {
  const _OnWindowActive({required this.onActive, required this.child});

  final VoidCallback onActive;

  final Widget child;

  @override
  State<_OnWindowActive> createState() => _OnWindowActiveState();
}

class _OnWindowActiveState extends State<_OnWindowActive> {
  bool? _inactive;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool inactive = ZsAppearance.of(context).inactive;
    if (_inactive == true && !inactive) {
      widget.onActive();
    }
    _inactive = inactive;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
