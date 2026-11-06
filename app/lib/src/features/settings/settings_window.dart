// SPDX-License-Identifier: MIT

// The windowing API is experimental and only reachable through implementation imports
// (https://github.com/flutter/flutter/issues/30701): the dialog controller's size, constraints and activation.
// ignore_for_file: implementation_imports, invalid_use_of_internal_member

import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/foundation.dart';
import 'package:flutter/src/widgets/_window.dart' show DialogWindowController;
import 'package:flutter/src/widgets/_window_macos.dart' show BaseWindowControllerMacOS;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show ThemeMode;
import 'package:zanshin_core/zanshin_core.dart' show ConfigScope;
import 'package:zanshin_settings/zanshin_settings.dart' show SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_layout.dart' show jjRefSymbol;
import '../projects/project_repos.dart' show ProjectRepo;
import '../projects/project_session.dart';
import '../projects/project_window_title.dart';
import '../projects/projects_environment.dart';
import '../shell/app_menu.dart' show GraphMenuBinding;
import '../shell/shell_toast.dart' show toastSlot, toastSpan;
import '../window/app_windows.dart';
import '../window/window_zoom.dart';
import 'config_file_page.dart';
import 'general_tab.dart';
import 'immutable_page.dart';
import 'project_tab.dart';
import 'settings_view_model.dart';
import 'settings_window_sizer.dart';
import 'settings_window_state.dart';

/// The Settings window's content (Story 11.7; DS ui_kits/desktop/dialogs.jsx:206-261, components/window): window-agnostic,
/// hosted by the coordinator in the parentless, content-sized `settings` dialog window.
///
/// - **Header:** the tabs `[⚙ General | <project>]` centred, the title hidden; the window's title (Window menu,
///   Mission Control) is "General", the project's name, or the page's name. Project is disabled with "Open a project
///   first" while no project is open.
/// - **Body:** the scope line (where the tab's jj settings go, from `jj config path`, and " · Edit…" opening the tab's
///   Config file page, Story 11.19), the tab's groups — or its page — scrolling, then the footer pointing at View
///   options. The Config file page takes the window's height and scrolls inside its editor.
/// - **Size** (Story 11.19): the window is resizable; until the user resizes or zooms it, its height follows the shown
///   tab (at most 740, at least 420; [SettingsHeightFollower]); afterwards it keeps its size and the body fills it.
/// - **Leaving:** the red button and ⌘W run the close handler, which asks first while the Config file page has edits
///   (the Discard sheet; also on closing the project or quitting, an [AppWindows] close guard), then writes a pending
///   valid text field; Esc does nothing (changes apply at once).
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
class SettingsWindowContentState extends State<SettingsWindow> with WidgetsBindingObserver {
  late final viewModel = SettingsViewModel(
    store: widget.store,
    environment: widget.environment,
    session: widget.session,
    graph: widget.graph,
    setThemeMode: widget.setThemeMode,
    readsOf: widget.readsOf,
  );
  final _scroll = ScrollController();
  VoidCallback? _removeGuard;

  /// The Discard sheet's question while it shows.
  _Discard? _asking;

  /// The window (null without one, as in tests) and its height follower, bound after the first frame.
  DialogWindowController? _window;
  SettingsHeightFollower? _follower;

  @override
  void initState() {
    super.initState();
    viewModel.init();
    widget.session.addListener(_sessionChanged);
    _sessionChanged();
    widget.windows.setCloseHandler(widget.windowKey, close);
    widget.state.confirmDiscard = _confirmDiscard;
    _removeGuard = widget.windows.addCloseGuard(_guard);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bindWindow());
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    widget.windows.setCloseHandler(widget.windowKey, null);
    if (widget.state.confirmDiscard == _confirmDiscard) {
      widget.state.confirmDiscard = null;
    }
    _removeGuard?.call();
    if (_asking case final _Discard asking when !asking.result.isCompleted) {
      asking.result.complete(true);
    }
    _unbindWindow();
    viewModel.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _sessionChanged() => widget.state.projectOpen = widget.session.repo != null;

  /// The red button and ⌘W: a config page with edits asks first; then a pending valid field is written, and the
  /// window goes and its pages with it.
  Future<void> close() async {
    if (!await widget.state.mayLeave()) {
      return;
    }
    await viewModel.flushPending();
    widget.state.windowClosed();
    _unbindWindow();
    widget.windows.close(widget.windowKey);
  }

  /// Closing the project or quitting: the window comes forward and asks while a config page has edits.
  Future<bool> _guard() async {
    if (!widget.state.asksBeforeLeaving) {
      return true;
    }
    widget.windows.activate(widget.windowKey);
    return widget.state.mayLeave();
  }

  /// Shows "Discard your edits to …?" (or joins the one showing); true once Discard let the edits go.
  Future<bool> _confirmDiscard() {
    final _Discard asking = _asking ??= _Discard();
    if (mounted) {
      setState(() {});
    }
    return asking.result.future;
  }

  void _answered(_Discard asking, {required bool discard}) => setState(() {
    asking
      ..confirmed = discard
      ..closing = true;
  });

  void _askClosed(_Discard asking) {
    if (identical(_asking, asking)) {
      setState(() => _asking = null);
    }
    if (!asking.result.isCompleted) {
      asking.result.complete(asking.confirmed);
    }
  }

  // ---- the window's height (Story 11.19) ----

  void _bindWindow() {
    if (!mounted || _window != null) {
      return;
    }
    if (widget.windows.controllerOf(widget.windowKey) case final DialogWindowController window) {
      _window = window..addListener(_windowChanged);
      _follower = SettingsHeightFollower(
        setSize: window.setSize,
        setConstraints: window.setConstraints,
        zoom: _zoom,
      )..addListener(_followingChanged);
      // The window is sized to its content, so its minimum scales here, not in AppWindows (Story 11.20).
      widget.store.addListener(_zoomChanged);
      WidgetsBinding.instance.addObserver(this);
      _windowChanged();
    }
  }

  double get _zoom => zoomScaleOf(widget.store.value.appearance.zoom);

  void _zoomChanged() => _follower?.zoom = _zoom;

  void _unbindWindow() {
    widget.store.removeListener(_zoomChanged);
    _window?.removeListener(_windowChanged);
    _window = null;
    _follower?.dispose();
    _follower = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// The window notified (a resize, a title, its first frame): the follower learns its size — from its first frame
  /// on, which is when it first became key.
  void _windowChanged() {
    final DialogWindowController? window = _window;
    final SettingsHeightFollower? follower = _follower;
    if (window == null || follower == null || (window is BaseWindowControllerMacOS && window.isDestroyed)) {
      return;
    }
    if (!follower.ready && !window.isActivated) {
      return;
    }
    follower.windowSized(window.contentSize);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (event.viewId == _window?.rootView.viewId && event.state == ViewFocusState.focused) {
      _windowChanged();
    }
  }

  void _followingChanged() => setState(() {});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[widget.state, viewModel]),
    builder: (context, _) {
      final AppLocalizations s = context.l10n;
      final SettingsWindowState state = widget.state;
      final SettingsViewModel vm = viewModel;
      final String? project = vm.projectName;
      final bool onProject = state.tab == SettingsTab.project && project != null;
      final onConfig = state.page == SettingsPage.configFile;
      final bool onPage = onProject && state.page == SettingsPage.immutableCommits;
      final String title = onConfig
          ? s.settingsConfigTitle
          : !onProject
          ? s.settingsTabGeneral
          : onPage
          ? s.settingsImmutableTitle
          : project;
      final Widget content = onConfig
          ? SettingsConfigFilePage(
              vm: vm,
              scope: onProject ? ConfigScope.repo : ConfigScope.user,
              back: onProject ? project : s.settingsTabGeneral,
              onBack: state.closePage,
              onEditing: (editing) => state.editing = editing,
            )
          : !onProject
          ? SettingsGeneralTab(vm: vm)
          : onPage
          ? SettingsImmutablePage(vm: vm, project: project, onBack: state.closePage)
          : SettingsProjectTab(vm: vm, onImmutableCommits: () => state.openPage(SettingsPage.immutableCommits));
      final String? removing = vm.removing;
      final _Discard? asking = _asking;
      final String? filePath = onProject ? vm.repoPath : vm.userPath;
      // Until the user resizes the window its height follows the tab; afterwards the body fills it.
      final bool following = _follower?.following ?? true;
      // Keyed by the project too: a switch disposes the old project's fields, pending edits included, so none
      // writes into the new project's config.
      final Widget page = KeyedSubtree(key: ValueKey<Object>((state.tab, state.page, vm.root)), child: content);
      return ProjectWindowTitle(
        title: title,
        child: Semantics(
          identifier: 'settings-window',
          container: true,
          child: KeyedSubtree(
            key: const ValueKey<String>('settings-window'),
            child: NaturalHeight(
              measuring: _follower != null && following,
              onHeight: (height) => _follower?.contentHeight(height),
              child: Stack(
                children: <Widget>[
                  ZsWindowScaffold(
                    title: title,
                    titleHidden: true,
                    align: ZsWindowHeaderAlign.center,
                    header: <Widget>[
                      ZsSegmented<SettingsTab>(
                        variant: ZsSegmentedVariant.tabs,
                        label: s.settingsTabsLabel,
                        identifier: 'settings-tabs',
                        segments: <ZsSegment<SettingsTab>>[
                          ZsSegment<SettingsTab>(
                            value: SettingsTab.general,
                            label: s.settingsTabGeneral,
                            icon: ZI.settings,
                          ),
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
                      mainAxisSize: following ? MainAxisSize.min : MainAxisSize.max,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        _ScopeLine(
                          lead: onProject ? s.settingsScopeProject(project) : s.settingsScopeGeneral,
                          path: filePath,
                          onEdit: onConfig ? null : () => state.openPage(SettingsPage.configFile),
                        ),
                        // The config page takes the window's height and scrolls inside its editor.
                        if (onConfig)
                          Expanded(
                            child: Padding(padding: const EdgeInsets.fromLTRB(24, 12, 24, 18), child: page),
                          )
                        else
                          Flexible(
                            fit: following ? FlexFit.loose : FlexFit.tight,
                            child: ZsScrollArea(
                              controller: _scroll,
                              child: SingleChildScrollView(
                                controller: _scroll,
                                padding: const EdgeInsets.fromLTRB(24, 12, 24, 18),
                                child: page,
                              ),
                            ),
                          ),
                        const _Footer(),
                      ],
                    ),
                  ),
                  if (removing != null) Positioned.fill(child: _removeSheet(context, s, vm, removing)),
                  if (asking != null) Positioned.fill(child: _discardSheet(s, asking, filePath)),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  /// Leaving the config page with edits (DS ConfigFilePage.prompt.md): a destructive sheet over the window.
  Widget _discardSheet(AppLocalizations s, _Discard asking, String? path) => ZsConfirmDialog(
    title: s.settingsConfigDiscardTitle(path == null ? s.settingsConfigTitle : path.split('/').last),
    body: Text(s.settingsConfigDiscardBody),
    confirmLabel: s.settingsConfigDiscardConfirm,
    closing: asking.closing,
    onConfirm: () => _answered(asking, discard: true),
    onCancel: () => _answered(asking, discard: false),
    onClosed: () => _askClosed(asking),
    identifier: 'settings-config-discard',
  );

  /// Remove…'s question (DS RemotesGroup.jsx:149-153): a destructive sheet over the window.
  Widget _removeSheet(BuildContext context, AppLocalizations s, SettingsViewModel vm, String name) {
    final ZsColors colors = ZsColors.of(context);
    final TextStyle mono = ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.text);
    return ZsConfirmDialog(
      title: s.settingsRemoteRemoveTitle(name),
      confirmLabel: s.settingsRemoteRemoveConfirm,
      body: Text.rich(
        toastSpan(s.settingsRemoteRemoveBody(toastSlot(0), toastSlot(1)), <InlineSpan>[
          TextSpan(text: 'main@${jjRefSymbol(name)}', style: mono), // l10n-ignore: example bookmark
          TextSpan(text: 'jj undo', style: mono), // l10n-ignore: jj command
        ]),
      ),
      cmd: RemoteRemove(name).command,
      closing: vm.removeClosing,
      onConfirm: () => vm.answerRemove(confirm: true),
      onCancel: () => vm.answerRemove(confirm: false),
      onClosed: vm.removeClosed,
      identifier: 'settings-remote-remove',
    );
  }
}

/// The Discard sheet's question: its answer, once the sheet has left.
class _Discard {
  final result = Completer<bool>();
  var confirmed = false;
  var closing = false;
}

/// The scope line (DS kit.css:213-214): centred 12 `--text-dim`, the path in mono `--text-muted`, then " · Edit…"
/// opening the Config file page ([onEdit]; none on that page).
class _ScopeLine extends StatelessWidget {
  const _ScopeLine({required this.lead, required this.path, required this.onEdit});

  final String lead;
  final String? path;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? path = this.path;
    final VoidCallback? onEdit = this.onEdit;
    final TextStyle style = ZsType.secondary.copyWith(color: colors.textDim);
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
              if (onEdit != null) ...<InlineSpan>[
                const TextSpan(text: ' · '),
                WidgetSpan(
                  alignment: PlaceholderAlignment.baseline,
                  baseline: TextBaseline.alphabetic,
                  child: DefaultTextStyle(
                    style: style,
                    child: ZsLink(
                      label: context.l10n.settingsConfigEdit,
                      onPressed: onEdit,
                      identifier: 'settings-config-edit',
                    ),
                  ),
                ),
              ],
            ],
          ],
        ),
        textAlign: TextAlign.center,
        style: style,
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
