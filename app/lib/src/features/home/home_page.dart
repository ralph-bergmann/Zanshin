// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:inject_flutter/inject_flutter.dart';
import 'package:zanshin_core/zanshin_core.dart' show ZanshinFfiException;
import 'package:zanshin_settings/zanshin_settings.dart' show ProjectEntry;
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../bookmarks/bookmark_list_view.dart';
import '../graph/active_graph.dart';
import '../graph/graph_search_field.dart' show GraphSearchShortcuts;
import '../projects/project_capsule.dart';
import '../projects/project_repos.dart' show ProjectRepo;
import '../projects/project_session.dart';
import '../projects/project_window_title.dart';
import '../shell/floating_shell.dart';
import '../shell/floating_shell_view_model.dart';
import '../shell/shell_controller.dart' show ShellRailItem;
import '../shell/shell_toast.dart';
import '../shell/top_bar.dart';
import '../undo_timeline/undo_timeline_view.dart';
import '../window/app_window_actions.dart';
import '../window/app_windows.dart' show mainWindowTitle;
import 'open_report_toast.dart';
import 'project_graph_host.dart';
import 'project_scope.dart';

part 'home_page.factory.dart';

/// The project window's content: the floating shell (Story 11.3) on the window canvas, `ZsCanvas` (Story 11.4).
///
/// PLACE holds the open project's capsule (Story 11.5), the empty island while none is open; the window takes the
/// project's name as its title, "Zanshin" without one. The toast slot hosts the view model's [ShellToasts] while one
/// shows or leaves, a creation's warnings and the graph's toasts among them (Story 10.23).
///
/// Story 10.12: while a project is open the shell holds its commit graph ([ProjectGraphHost]): the graph, VIEW's
/// controls and search, New change, the inspector, the @ pill and the stale notice; the graph is published to
/// [activeGraph], and the rail's Undo Timeline runs through its model. ACTION's sync island is Reload (⌘R's tooltip):
/// one [ProjectSession.refresh] and one graph reload per press, each coalesced; disabled without a project — then
/// Fetch and Push… (Story 11.8). Without
/// one VIEW and New change stay empty islands. The bar's row is the window's drag region (design question (a),
/// decision (g); Story 11.4): from the window's top edge down to the content top, the part the islands leave empty
/// moves the window on a drag and runs the system's titlebar action on a double-click.
@immutable
class HomePage extends StatelessWidget {
  @assistedInject
  const HomePage({
    required this.viewModelFactory,
    required this.projects,
    required this.scopes,
    required this.activeGraph,
    @assisted super.key,
  });

  /// Binds the shell's view model to this page.
  final ViewModelFactory<FloatingShellViewModel> viewModelFactory;

  /// The open project.
  final ProjectSession projects;

  /// Creates the graph of the open repository.
  final ProjectComponentFactory scopes;

  /// The project window's graph, which the page's graph host publishes.
  final ActiveGraph activeGraph;

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
            builder: (context, _) => ProjectGraphHost(
              session: projects,
              scopes: scopes,
              activeGraph: activeGraph,
              toasts: vm.toasts,
              builder: (context, graph) {
                final ProjectScope? scope = graph.scope;
                // One ListenableBuilder either way, so nothing below remounts when a project opens or closes. The
                // bookmark and tag lists' rail items show their counts, so it rebuilds with the lists.
                return ListenableBuilder(
                  listenable: Listenable.merge(<Listenable?>[scope?.bookmarks, scope?.tags]),
                  builder: (context, _) {
                    final shell = FloatingShell(
                      controller: vm.shell,
                      railItems: <ShellRailItem>[
                        if (scope != null) ...<ShellRailItem>[
                          bookmarksRailItem(context.l10n, scope.bookmarks),
                          tagsRailItem(context.l10n, scope.tags),
                          undoTimelineRailItem(
                            context.l10n,
                            scope.undoTimeline,
                            changes: scope.operationChanges,
                            actions: scope.model,
                          ),
                        ],
                      ],
                      canvas: const ZsCanvas(),
                      graph: graph.graph,
                      // An opaque target, so a press in the bar's row moves the window and never reaches the graph below.
                      barRow: const WindowDragArea(child: ColoredBox(color: Color(0x00000000))),
                      projectCapsule: ListenableBuilder(listenable: projects, builder: (context, _) => _place(context)),
                      view: graph.view,
                      syncGroup: graph.sync,
                      newChange: graph.newChange,
                      inspector: graph.inspector,
                      minimap: graph.minimap,
                      minimapWidth: scope?.model.minimapSource.cardWidth,
                      atPill: graph.atPill,
                      staleNotice: graph.staleNotice,
                      toast: vm.toasts.occupied ? ShellToastView(toasts: vm.toasts) : null,
                    );
                    return GraphSearchShortcuts(search: scope?.search, child: shell);
                  },
                );
              },
            ),
          ),
        ),
      ),
    ),
  );

  /// PLACE: the capsule of the open project, else the empty island. All Projects… opens or brings forward the Projects
  /// window through the window's [AppWindowActionsScope] (Story 11.12) and stays disabled without one (a catalogue
  /// preview), and so do Project Settings… (the Project tab) and Settings… (the tab shown last; Story 11.7).
  Widget _place(BuildContext context) {
    final ProjectEntry? project = projects.current;
    if (project == null) {
      return const ShellEmptyIsland();
    }
    final AppWindowActions? windows = AppWindowActionsScope.maybeOf(context);
    return ProjectCapsule(
      project: project,
      recent: projects.recent,
      onOpen: (path) => unawaited(openRecentProject(projects, windows, path)),
      onAllProjects: windows == null ? null : () => unawaited(windows.openProjects()),
      onProjectSettings: windows == null ? null : () => unawaited(windows.openSettings(target: SettingsTarget.project)),
      onSettings: windows == null ? null : () => unawaited(windows.openSettings()),
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
    // Story 11.22: Track acts in the repository the report is about, even after a later switch.
    final ProjectRepo? repo = widget.session.repo;
    widget.toasts.show(
      ShellToastEntry(
        tone: report.trackableRemoteBookmarks.isEmpty ? ZsToastTone.success : ZsToastTone.warn,
        build: (context, dismiss) => openReportToast(
          context,
          report,
          onTrack: () {
            dismiss();
            unawaited(_track(repo, report.trackableRemoteBookmarks));
          },
          onDismiss: dismiss,
        ),
      ),
    );
  }

  /// `jj bookmark track` of [symbols] in [repo]; a failure shows jj's text (else the error) as an error toast.
  Future<void> _track(ProjectRepo? repo, List<String> symbols) async {
    try {
      await repo?.trackBookmarks(symbols);
    } on Object catch (error) {
      final String text = error is ZanshinFfiException
          ? <String>[error.context ?? error.code, ...error.hints].join('\n')
          : '$error';
      widget.toasts.show(
        ShellToastEntry(
          tone: ZsToastTone.error,
          build: (context, dismiss) => ZsToast(
            tone: ZsToastTone.error,
            message: TextSpan(text: text),
            // The toast draws one line: jj's further lines show in its tooltip, in mono.
            tooltip: text.contains('\n') ? text : null,
            tooltipMono: true,
            onDismiss: dismiss,
            identifier: 'project-toast-track-error',
          ),
        ),
      );
    }
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
