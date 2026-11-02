// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../projects/project_repos.dart' show ProjectRepo;
import '../projects/project_session.dart';
import '../projects/project_window_title.dart';
import '../projects/projects_environment.dart';
import '../shell/app_menu.dart' show GraphMenuBinding;
import '../window/app_windows.dart';
import 'general_tab.dart';
import 'immutable_page.dart';
import 'project_tab.dart';
import 'settings_view_model.dart';
import 'settings_window_state.dart';

/// The Settings window's content (Story 11.7; DS ui_kits/desktop/dialogs.jsx:206-261, components/window): window-agnostic,
/// hosted by the coordinator in the parentless, content-sized `settings` dialog window.
///
/// - **Header:** the tabs `[⚙ General | <project>]` centred, the title hidden; the window's title (Window menu,
///   Mission Control) is "General", the project's name, or the page's name. Project is disabled with "Open a project
///   first" while no project is open.
/// - **Body:** the scope line (where the tab's jj settings go, from `jj config path`), the tab's groups — or the
///   Project tab's page — scrolling inside the window's 740 maximum, then the footer pointing at View options.
/// - **Leaving:** the red button and ⌘W run the close handler, which writes a pending valid text field first; Esc does
///   nothing (changes apply at once).
///
/// Identifiers: `settings-window` (also the content's key), `settings-tabs`, and the rows' `settings-*`.
class SettingsWindow extends StatefulWidget {
  /// The content showing [state] over its ports.
  const SettingsWindow({
    required this.state,
    required this.windows,
    required this.store,
    required this.environment,
    required this.session,
    required this.graph,
    required this.setThemeMode,
    this.windowKey = settingsWindowKey,
    this.readsOf,
    super.key,
  });

  /// The tab and page shown.
  final SettingsWindowState state;

  /// The app's windows (the close handler).
  final AppWindows windows;

  /// The window's key.
  final String windowKey;

  /// The app preferences.
  final SettingsStore store;

  /// The jj config.
  final ProjectsEnvironment environment;

  /// The open project.
  final ProjectSession session;

  /// The project window's graph.
  final ValueListenable<GraphMenuBinding?> graph;

  /// Sets the theme.
  final Future<void> Function(ThemeMode mode) setThemeMode;

  /// The repository reads; [RepoSettingsReads] when null.
  final SettingsRepoReads Function(ProjectRepo repo)? readsOf;

  @override
  State<SettingsWindow> createState() => SettingsWindowContentState();
}

/// The content's state; [viewModel] for tests.
class SettingsWindowContentState extends State<SettingsWindow> {
  late final viewModel = SettingsViewModel(
    store: widget.store,
    environment: widget.environment,
    session: widget.session,
    graph: widget.graph,
    setThemeMode: widget.setThemeMode,
    readsOf: widget.readsOf,
  );
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    viewModel.init();
    widget.session.addListener(_sessionChanged);
    _sessionChanged();
    widget.windows.setCloseHandler(widget.windowKey, close);
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    widget.windows.setCloseHandler(widget.windowKey, null);
    viewModel.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _sessionChanged() => widget.state.projectOpen = widget.session.repo != null;

  /// The red button and ⌘W: a pending valid field is written, then the window goes and its page with it.
  Future<void> close() async {
    await viewModel.flushPending();
    widget.state.windowClosed();
    widget.windows.close(widget.windowKey);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[widget.state, viewModel]),
    builder: (context, _) {
      final AppLocalizations s = context.l10n;
      final SettingsWindowState state = widget.state;
      final SettingsViewModel vm = viewModel;
      final String? project = vm.projectName;
      final bool onProject = state.tab == SettingsTab.project && project != null;
      final bool onPage = onProject && state.page == SettingsPage.immutableCommits;
      final String title = !onProject
          ? s.settingsTabGeneral
          : onPage
          ? s.settingsImmutableTitle
          : project;
      final Widget content = !onProject
          ? SettingsGeneralTab(vm: vm)
          : onPage
          ? SettingsImmutablePage(vm: vm, project: project, onBack: state.closePage)
          : SettingsProjectTab(vm: vm, onImmutableCommits: () => state.openPage(SettingsPage.immutableCommits));
      return ProjectWindowTitle(
        title: title,
        child: Semantics(
          identifier: 'settings-window',
          container: true,
          child: KeyedSubtree(
            key: const ValueKey<String>('settings-window'),
            child: ZsWindowScaffold(
              title: title,
              titleHidden: true,
              align: ZsWindowHeaderAlign.center,
              header: <Widget>[
                ZsSegmented<SettingsTab>(
                  variant: ZsSegmentedVariant.tabs,
                  label: s.settingsTabsLabel,
                  identifier: 'settings-tabs',
                  segments: <ZsSegment<SettingsTab>>[
                    ZsSegment<SettingsTab>(value: SettingsTab.general, label: s.settingsTabGeneral, icon: ZI.settings),
                    ZsSegment<SettingsTab>(
                      value: SettingsTab.project,
                      label: project ?? s.settingsTabProject,
                      leading: const ZsNamiMark(size: 14),
                      disabledReason: state.projectOpen ? null : s.settingsOpenProjectFirst,
                    ),
                  ],
                  value: onProject ? SettingsTab.project : SettingsTab.general,
                  onChanged: state.selectTab,
                ),
              ],
              body: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _ScopeLine(
                    lead: onProject ? s.settingsScopeProject(project) : s.settingsScopeGeneral,
                    path: onProject ? vm.repoPath : vm.userPath,
                  ),
                  Flexible(
                    child: ZsScrollArea(
                      controller: _scroll,
                      child: SingleChildScrollView(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
                        // Keyed by the project too: a switch disposes the old project's fields, pending edits
                        // included, so none writes into the new project's config.
                        child: KeyedSubtree(
                          key: ValueKey<Object>((state.tab, state.page, vm.root)),
                          child: content,
                        ),
                      ),
                    ),
                  ),
                  const _Footer(),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// The scope line (DS kit.css:213-214): centred 12 `--text-dim`, the path in mono `--text-muted`.
class _ScopeLine extends StatelessWidget {
  const _ScopeLine({required this.lead, required this.path});

  final String lead;
  final String? path;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? path = this.path;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 4),
      child: Text.rich(
        key: const ValueKey<String>('settings-scope'),
        TextSpan(
          text: lead,
          children: <InlineSpan>[
            if (path != null) ...<InlineSpan>[
              const TextSpan(text: ' '),
              TextSpan(
                text: path,
                style: ZsType.id.copyWith(color: colors.textMuted),
              ),
            ],
          ],
        ),
        textAlign: TextAlign.center,
        style: ZsType.secondary.copyWith(color: colors.textDim),
      ),
    );
  }
}

/// The footer (DS kit.css:216-217): "How the graph looks lives with the graph: **View options** in the toolbar."
class _Footer extends StatelessWidget {
  const _Footer();

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final AppLocalizations s = context.l10n;
    final String bold = s.settingsFooterViewOptions;
    final List<String> parts = s.settingsFooter(bold).split(bold);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.flBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 15),
        child: Text.rich(
          TextSpan(
            children: <InlineSpan>[
              for (var i = 0; i < parts.length; i++) ...<InlineSpan>[
                if (i > 0)
                  TextSpan(
                    text: bold,
                    style: TextStyle(color: colors.textMuted, fontWeight: FontWeight.w500),
                  ),
                TextSpan(text: parts[i]),
              ],
            ],
          ),
          textAlign: TextAlign.center,
          style: ZsType.meta.copyWith(fontSize: ZsType.fsId, color: colors.textDim),
        ),
      ),
    );
  }
}
