// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/rendering.dart' show SemanticsProperties;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'project_registry.dart';
import 'project_session.dart';
import 'projects_environment.dart';
import 'projects_tree.dart';
import 'projects_tree_model.dart';
import 'relative_time.dart';

part 'projects_window.factory.dart';

final _log = Logger('zanshin.projects');

/// The Projects window's content (epics.md Story 11.6 with its design update 2026-10-16; DS
/// components/window/Window.prompt.md:14-23, window.css:26-43; ui_kits/desktop/dialogs.jsx:13-58, kit.css:192-202).
/// It assumes no window: it fills what it is given (a catalogue panel, a catalogue window, the app's `projects` dialog
/// window of Story 11.12) and lays itself out on [ZsWindowScaffold]'s sidebar form, titled "Projects": the scaffold
/// paints the window fill, the 52 pt header row on the traffic-light block's centre line with its hairline, the
/// sidebar's `--fl-border` hairline on its right and its empty 52 pt top, where a window's traffic lights sit; the
/// header's empty space and that top drag the window. Tab runs through the main column — the header's controls, then
/// the body — before the sidebar.
///
/// **Sidebar** (200): the brand — the 32 px Nami chip, "Zanshin", the version line "‹version› · Build ‹build›" (the
/// splash's) and below it "jj-lib ‹version›" (Claude's proposal) —, the navigation — Projects (current, `--fl-on`) and
/// Settings…, which runs [onSettings] and is disabled without it — and the identity footer: `user.name` and
/// `user.email` with an avatar, or the jj CLI's phrase for what is missing with "Set identity…" when
/// [onIdentitySettings] is given (Claude's proposal). A failed read hides the footer.
///
/// **Header** (the scaffold's): "Projects" at sidebar + 12 (600 13/1.2, `--text-dim` in an inactive window), then the
/// controls — the search (230; focused on open; Esc clears it and never closes; ↓ moves into the tree), Add directory
/// (the gold primary), Clone… and New group (ghost, icon-only). Below 800 wide the search is 120 and Clone… icon-only
/// (Claude's proposal from the floating export's `geo.w < 800`, design/windows.jsx:149).
///
/// **Adding** (CLI parity, FR-JJ-17): Add directory, a Finder drop and the tree's Open detect first. A jj workspace is
/// registered (canonical path) and opened; a Git repository gets the offer to convert it (`jj git init --colocate`), a
/// plain folder the offer to create one (`jj git init --no-colocate`), a folder inside a repository the offer to add
/// that repository — sheets (`ZsConfirmDialog`, tone standard) showing the exact command; Cancel changes nothing. A
/// creation's warnings show verbatim in the notice under the header. New projects land in the selected group, else at
/// the top level (Claude's proposal); a drop lands where `tree_drop.dart` places it. Several dropped folders register
/// their jj workspaces without opening them and skip what the list holds; one dropped folder opens.
///
/// **Clone…** opens an inline form under the header: the URL, the destination (mono; pre-filled
/// `‹last parent or ~›/‹name›` by the CLI's rule), Choose…, Cancel and Clone (gold, busy while it runs; its tooltip the
/// `jj git clone --no-colocate` command). **New group** names a group inline, inside the selected group or at the top
/// level.
///
/// Every successful open reaches [onOpened] (11.12's window coordinator closes the `projects` dialog window there, or
/// keeps it with a creation's warnings). The identity is read again whenever the window becomes key. Identifiers:
/// `projects-window` (also the root's key), `projects-search`, `projects-add-directory`, `projects-clone`,
/// `projects-new-group`, `projects-settings`, `projects-identity-settings`, `projects-notice`, `projects-offer`,
/// `projects-clone-url`, `projects-clone-destination`, `projects-clone-choose`, `projects-clone-submit`,
/// `projects-clone-cancel`, `projects-drop-hint`, and the tree's.
class ProjectsWindow extends StatefulWidget {
  /// The content over [session], [registry] and [environment].
  @assistedInject
  const ProjectsWindow({
    required this.session,
    required this.registry,
    required this.environment,
    @assisted this.onOpened,
    @assisted this.onSettings,
    @assisted this.onIdentitySettings,
    @assisted super.key,
  });

  /// Opens, creates and closes projects.
  final ProjectSession session;

  /// The projects and groups the tree shows.
  final ProjectRegistry registry;

  /// The version, the identity, the folder picker and Reveal in Finder.
  final ProjectsEnvironment environment;

  /// Runs after every successful open or creation, with its outcome.
  final ValueChanged<ProjectOpened>? onOpened;

  /// Settings… in the sidebar (11.7, the tab shown last); null disables the row.
  final VoidCallback? onSettings;

  /// "Set identity…" in the footer (11.7's Identity rows); null leaves the link out.
  final VoidCallback? onIdentitySettings;

  /// The sidebar's width (Window.prompt.md:23).
  static const double sidebarWidth = 200;

  /// Below this width the search narrows and Clone… loses its label (Claude's proposal; design/windows.jsx:149).
  static const double narrowWidth = 800;

  /// The search's width, and its width below [narrowWidth] (`flex:0 1 230px;min-width:120px`, design/windows.css:61).
  static const double searchWidth = 230;

  /// The narrow search's width.
  static const double searchNarrowWidth = 120;

  /// The Settings… row's tooltip (DS ui_kits/desktop/dialogs.jsx:39).
  static const settingsTooltip = 'Settings — ⌘, (the tab shown last)';

  @override
  State<ProjectsWindow> createState() => ProjectsWindowState();
}

enum _OfferKind { convert, init, enclosing, clone, open }

/// An offer sheet waiting for the user: create or add [path] at [placement]; [inside] is the folder that was chosen
/// when [path] is the repository around it.
class _Offer {
  _Offer(this.kind, this.path, this.placement, {this.inside});

  final _OfferKind kind;
  final String path;
  final String? inside;
  final ProjectsPlacement placement;

  /// Completes once the sheet is gone: with what confirming ran into, or null when it was cancelled.
  final result = Completer<ProjectOpenOutcome?>();
  ProjectOpenOutcome? outcome;
  var busy = false;
  var closing = false;
}

/// The notice under the header: a `title` and `lines`, shown verbatim.
typedef _Notice = ({String title, List<String> lines});

/// The window content's state. [search], [addDirectory], [openCloneForm], [submitClone] and [previewDrop] are how the
/// catalogue shows its states.
class ProjectsWindowState extends State<ProjectsWindow> {
  final _search = ZsTextEditingController();
  final _searchFocus = FocusNode(debugLabel: 'projects search');
  final _tree = GlobalKey<ProjectsTreeState>();
  final _cloneUrl = ZsTextEditingController();
  final _cloneDestination = ZsTextEditingController();

  String? _selected;
  final _collapsed = <String>{};
  ProjectsNewGroupItem? _newGroup;
  _Notice? _notice;
  _Offer? _offer;

  var _cloneOpen = false;
  var _cloneBusy = false;
  var _destinationEdited = false;
  String? _lastParent;

  var _outerDrop = false;
  var _rowDrop = false;

  String? _version;
  String? _jjLibVersion;
  JjIdentity? _identity;
  String? _identityRoot;
  var _identityRead = 0;

  /// Whether the window was inactive at the last dependency change; null before the first.
  bool? _inactive;

  @override
  void initState() {
    super.initState();
    final String? open = widget.session.current?.path;
    _selected = open == null ? null : 'project:$open';
    widget.session.addListener(_sessionChanged);
    unawaited(_readVersions());
    unawaited(_readIdentity(open));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _searchFocus.requestFocus();
      }
    });
  }

  /// The window became key again (its appearance turned active): the identity is read once more, so an edit made
  /// meanwhile — in another window or by the CLI — shows (Story 11.12; there is no config-change event).
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final bool inactive = ZsAppearance.of(context).inactive;
    final bool? wasInactive = _inactive;
    _inactive = inactive;
    if (wasInactive == true && !inactive) {
      unawaited(_readIdentity(widget.session.current?.path));
    }
  }

  @override
  void didUpdateWidget(ProjectsWindow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.session, widget.session)) {
      oldWidget.session.removeListener(_sessionChanged);
      widget.session.addListener(_sessionChanged);
    }
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    _search.dispose();
    _searchFocus.dispose();
    _cloneUrl.dispose();
    _cloneDestination.dispose();
    super.dispose();
  }

  // ---- catalogue hooks ----

  /// Shows the tree filtered by [query], as if it were typed.
  void search(String query) {
    _search.text = query;
    setState(() {});
  }

  /// Runs Add directory's flow for [path], as if the folder picker had answered it.
  Future<void> addDirectory(String path) => _addFolders(<String>[path], (group: _targetGroup, index: null));

  /// Opens the clone form, its URL [url] when given.
  void openCloneForm({String? url}) {
    setState(() => _cloneOpen = true);
    if (url != null) {
      _cloneUrl.text = url;
      _urlChanged(url);
    }
  }

  /// Presses the clone form's Clone.
  Future<void> submitClone() => _submitClone();

  /// Shows the drop hint as a Finder drag over the window does.
  void previewDrop() => setState(() => _outerDrop = true);

  // ---- reads ----

  Future<void> _readVersions() async {
    final (String? version, String? jjLibVersion) = await (
      widget.environment.appVersion(),
      widget.environment.jjLibVersion(),
    ).wait;
    if (mounted) {
      setState(() {
        _version = version;
        _jjLibVersion = jjLibVersion;
      });
    }
  }

  Future<void> _readIdentity(String? root) async {
    _identityRoot = root;
    final int read = ++_identityRead;
    JjIdentity? identity;
    try {
      identity = await widget.environment.identity(workspaceRoot: root);
    } on ZanshinFfiException catch (error, stack) {
      _log
        ..warning('reading the identity failed: ${error.code}')
        ..fine('identity failure', error, stack);
    }
    if (mounted && read == _identityRead) {
      setState(() => _identity = identity);
    }
  }

  /// The open project changed: the identity is read for it, and it is selected while nothing is (the initial selection
  /// is the open project, also when it opens after the content showed; Claude's proposal).
  void _sessionChanged() {
    final String? root = widget.session.current?.path;
    if (root != _identityRoot) {
      unawaited(_readIdentity(root));
    }
    if (root != null && _selected == null) {
      setState(() => _selected = 'project:$root');
    }
  }

  // ---- helpers ----

  /// The group the selection names, which new projects and groups go into; null for the top level.
  String? get _targetGroup {
    final String? selected = _selected;
    return selected != null && selected.startsWith('group:') ? selected.substring('group:'.length) : null;
  }

  static String _nameOf(String path) {
    final List<String> segments = path.split('/').where((segment) => segment.isNotEmpty).toList();
    return segments.isEmpty ? path : segments.last;
  }

  static String _parentOf(String path) {
    final int cut = path.lastIndexOf('/');
    return cut <= 0 ? '/' : path.substring(0, cut);
  }

  void _note(String title, [List<String?> lines = const <String?>[]]) =>
      setState(() => _notice = (title: title, lines: lines.nonNulls.where((line) => line.isNotEmpty).toList()));

  // ---- flows ----

  /// While several dropped folders run their flows: the opens a confirmed offer made, which [ProjectsWindow.onOpened]
  /// hears once the whole batch is through, so a host that closes the window there never cuts it short.
  List<ProjectOpened>? _batchOpened;

  Future<void> _addFolders(List<String> paths, ProjectsPlacement placement) async {
    final single = paths.length == 1;
    int? index = placement.index;
    final List<ProjectOpened>? batch = single ? null : <ProjectOpened>[];
    _batchOpened = batch;
    try {
      for (final path in paths) {
        if (!single && widget.registry.registered(path) != null) {
          _log.fine('$path is listed already');
          continue;
        }
        final ProjectsPlacement place = (group: placement.group, index: index);
        final ProjectOpenOutcome outcome = single
            ? await widget.session.open(path, group: place.group, index: place.index)
            : await widget.session.add(path, group: place.group, index: place.index);
        if (!mounted) {
          return;
        }
        if (await _handle(outcome, path, place) && index != null) {
          index++;
        }
      }
    } finally {
      if (identical(_batchOpened, batch)) {
        _batchOpened = null;
      }
    }
    if (batch != null && batch.isNotEmpty && mounted) {
      widget.onOpened?.call(batch.last);
    }
  }

  /// Acts on [outcome] for [path] at [placement]; [made] is the offer that ran it. Answers whether [path] (or the
  /// repository around it) is now in the registry.
  Future<bool> _handle(
    ProjectOpenOutcome outcome,
    String path,
    ProjectsPlacement placement, {
    _OfferKind made = _OfferKind.open,
  }) async {
    switch (outcome) {
      case ProjectOpened():
        _opened(outcome, made: made, path: path);
        return true;
      case ProjectAdded(path: final String added):
        setState(() => _selected = 'project:$added');
        return true;
      case ProjectNotARepo(kind: RepoKind.pathNotFound):
        _note('$path does not exist.');
        return false;
      case ProjectNotARepo(kind: RepoKind.git):
        return _ask(_Offer(_OfferKind.convert, path, placement));
      case ProjectNotARepo():
        return _ask(_Offer(_OfferKind.init, path, placement));
      case ProjectInsideRepo(:final String root, kind: RepoKind.git):
        return _ask(_Offer(_OfferKind.convert, root, placement, inside: path));
      case ProjectInsideRepo(:final String root):
        return _ask(_Offer(_OfferKind.enclosing, root, placement, inside: path));
      case ProjectOpenFailed(:final String? context, :final List<ZanshinWarning> warnings):
        _note(
          switch (made) {
            _OfferKind.convert => 'Conversion failed',
            _OfferKind.init => 'Creating a repository failed',
            _OfferKind.clone => 'Clone failed',
            _OfferKind.enclosing || _OfferKind.open => 'Could not open ${_nameOf(path)}',
          },
          <String?>[context, for (final ZanshinWarning warning in warnings) warning.message],
        );
        return false;
      case ProjectRefused(:final String message):
        _note(made == _OfferKind.clone ? 'Clone failed' : message, <String?>[if (made == _OfferKind.clone) message]);
        return false;
    }
  }

  /// A project opened: it is selected, a creation's warnings show in the notice (an earlier notice goes), and
  /// [ProjectsWindow.onOpened] hears it — at the end of a batch of dropped folders.
  void _opened(ProjectOpened outcome, {required _OfferKind made, required String path}) {
    final String? open = widget.session.current?.path;
    final String name = widget.session.current?.name ?? _nameOf(path);
    setState(() {
      if (open != null) {
        _selected = 'project:$open';
      }
      _notice = outcome.warnings.isEmpty
          ? null
          : (
              title: switch (made) {
                _OfferKind.convert => 'Converted $name',
                _OfferKind.init => 'Created a repository in $name',
                _OfferKind.clone => 'Cloned $name',
                _OfferKind.enclosing || _OfferKind.open => 'Opened $name',
              },
              lines: <String>[for (final ZanshinWarning warning in outcome.warnings) warning.message],
            );
    });
    final List<ProjectOpened>? batch = _batchOpened;
    if (batch != null) {
      batch.add(outcome);
    } else {
      widget.onOpened?.call(outcome);
    }
  }

  /// Shows [offer]'s sheet and acts on what confirming it ran into; false when it was cancelled.
  Future<bool> _ask(_Offer offer) async {
    setState(() => _offer = offer);
    final ProjectOpenOutcome? outcome = await offer.result.future;
    if (outcome == null || !mounted) {
      return false;
    }
    return _handle(outcome, offer.path, offer.placement, made: offer.kind);
  }

  Future<void> _confirm(_Offer offer) async {
    setState(() => offer.busy = true);
    final ProjectsPlacement place = offer.placement;
    final ProjectOpenOutcome outcome = switch (offer.kind) {
      _OfferKind.convert => await widget.session.convert(offer.path, group: place.group, index: place.index),
      _OfferKind.init => await widget.session.initRepo(offer.path, group: place.group, index: place.index),
      _ => await widget.session.open(offer.path, group: place.group, index: place.index),
    };
    if (!mounted) {
      return;
    }
    setState(() {
      offer
        ..outcome = outcome
        ..busy = false
        ..closing = true;
    });
  }

  void _cancel(_Offer offer) => setState(() => offer.closing = true);

  void _closed(_Offer offer) {
    if (identical(_offer, offer)) {
      setState(() => _offer = null);
    }
    offer.result.complete(offer.outcome);
  }

  Future<void> _chooseDirectory() async {
    final String? path = await widget.environment.chooseDirectory(
      viewId: View.of(context).viewId,
      initialDirectory: _lastParent,
      prompt: 'Add',
    );
    if (path == null || !mounted) {
      return;
    }
    _lastParent = _parentOf(path);
    await addDirectory(path);
  }

  Future<void> _openEntry(ProjectEntry entry) async {
    final ProjectOpenOutcome outcome = await widget.session.open(entry.path);
    if (mounted) {
      await _handle(outcome, entry.path, (group: entry.group, index: null));
    }
  }

  void _startNewGroup() {
    final String? parent = _targetGroup;
    setState(() {
      _search.clear();
      if (parent != null) {
        _collapsed.remove(parent);
      }
      _newGroup = ProjectsNewGroupItem(parent);
    });
  }

  Future<void> _commitNewGroup(String name) async {
    final ProjectsNewGroupItem? adding = _newGroup;
    if (adding == null) {
      return;
    }
    setState(() => _newGroup = null);
    final String id = await widget.registry.addGroup(name, parent: adding.parent);
    if (mounted) {
      setState(() => _selected = 'group:$id');
    }
  }

  /// The end of every parent: past the last member.
  int get _end => widget.registry.value.projects.length + widget.registry.value.groups.length;

  Future<void> _moveItem(ProjectsItem item, ProjectsPlacement placement) async {
    switch (item) {
      case ProjectsProjectItem(:final ProjectEntry entry):
        await widget.registry.move(entry.path, group: placement.group, index: placement.index ?? _end);
      case ProjectsGroupItem(:final ProjectGroup group):
        await widget.registry.moveGroup(group.id, parent: placement.group, index: placement.index ?? _end);
      case ProjectsNewGroupItem():
        break;
    }
  }

  // ---- clone ----

  void _urlChanged(String url) {
    if (_destinationEdited) {
      return;
    }
    _cloneDestination.text = _destinationIn(_lastParent ?? widget.environment.home);
  }

  /// The clone's destination in [parent]: the folder the CLI names after the URL, or empty while the URL names none
  /// (the CLI refuses then, "No destination specified and wasn't able to guess it"), so the form waits for one.
  String _destinationIn(String parent) {
    final String? name = cloneDestinationFor(_cloneUrl.text.trim());
    if (name == null || name.isEmpty) {
      return '';
    }
    return parent.endsWith('/') ? '$parent$name' : '$parent/$name';
  }

  /// The destination as typed, made absolute (Claude's proposal; the window has no working directory a shell would
  /// resolve it against): a leading `~` is the home folder, and a relative path lies in the home folder.
  String get _destination {
    final String typed = _cloneDestination.text.trim();
    final String home = widget.environment.home;
    if (typed.isEmpty || typed.startsWith('/')) {
      return typed;
    }
    if (typed == '~') {
      return home;
    }
    final String rest = typed.startsWith('~/') ? typed.substring(2) : typed;
    return home.endsWith('/') ? '$home$rest' : '$home/$rest';
  }

  Future<void> _chooseCloneParent() async {
    final String? parent = await widget.environment.chooseDirectory(
      viewId: View.of(context).viewId,
      initialDirectory: _lastParent ?? widget.environment.home,
      prompt: 'Choose',
    );
    if (parent == null || !mounted) {
      return;
    }
    _lastParent = parent;
    setState(() => _cloneDestination.text = _destinationIn(parent));
  }

  void _closeCloneForm() => setState(() {
    _cloneOpen = false;
    _destinationEdited = false;
    _cloneUrl.clear();
    _cloneDestination.clear();
  });

  String get _cloneCommand =>
      'jj git clone --no-colocate ${shellQuote(_cloneUrl.text.trim())} ${shellQuote(_destination)}';

  Future<void> _submitClone() async {
    final String url = _cloneUrl.text.trim();
    final String destination = _destination;
    if (url.isEmpty || destination.isEmpty || _cloneBusy) {
      return;
    }
    setState(() => _cloneBusy = true);
    final ProjectOpenOutcome outcome = await widget.session.clone(
      url: url,
      destination: destination,
      group: _targetGroup,
    );
    if (!mounted) {
      return;
    }
    setState(() => _cloneBusy = false);
    if (outcome is ProjectOpened) {
      _closeCloneForm();
    }
    await _handle(outcome, destination, (group: _targetGroup, index: null), made: _OfferKind.clone);
  }

  // ---- build ----

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: 'projects-window',
    container: true,
    explicitChildNodes: true,
    child: KeyedSubtree(
      key: const ValueKey<String>('projects-window'),
      child: FolderDropTarget(
        // While an offer sheet is up the drop waits: the sheet answers first (Claude's proposal).
        onDragUpdate: (_) {
          if (_offer != null) {
            return false;
          }
          if (!_outerDrop) {
            setState(() => _outerDrop = true);
          }
          return true;
        },
        onDragExit: () => setState(() => _outerDrop = false),
        onDrop: (details) {
          setState(() => _outerDrop = false);
          unawaited(_addFolders(details.paths, (group: null, index: null)));
        },
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool narrow = constraints.maxWidth < ProjectsWindow.narrowWidth;
            final _Offer? offer = _offer;
            return Stack(
              children: <Widget>[
                Positioned.fill(
                  // Every group carries an order: the policy puts unordered members after the ordered ones.
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: ZsWindowScaffold(
                      title: 'Projects',
                      header: <Widget>[
                        FocusTraversalOrder(
                          order: const NumericFocusOrder(1),
                          child: FocusTraversalGroup(child: _header(narrow: narrow)),
                        ),
                      ],
                      body: FocusTraversalOrder(
                        order: const NumericFocusOrder(2),
                        child: FocusTraversalGroup(child: _main(context)),
                      ),
                      sidebar: FocusTraversalOrder(
                        order: const NumericFocusOrder(3),
                        child: FocusTraversalGroup(child: _sidebar()),
                      ),
                    ),
                  ),
                ),
                if (offer != null) Positioned.fill(child: _sheet(context, offer)),
              ],
            );
          },
        ),
      ),
    ),
  );

  /// The sidebar's column; [ZsWindowScaffold] draws its hairline and its empty top.
  Widget _sidebar() => SizedBox(
    width: ProjectsWindow.sidebarWidth,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _Brand(version: _version, jjLibVersion: _jjLibVersion),
        Padding(
          // `.zk-side-nav{padding:0 10px;gap:1px}` (DS ui_kits/desktop/kit.css:194).
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 1,
            children: <Widget>[
              const _NavRow(icon: ZI.folderOpen, label: 'Projects', current: true),
              ZsTooltip(
                message: ProjectsWindow.settingsTooltip,
                child: _NavRow(
                  icon: ZI.settings,
                  label: 'Settings…',
                  onPressed: widget.onSettings,
                  identifier: 'projects-settings',
                ),
              ),
            ],
          ),
        ),
        const Spacer(),
        if (_identity case final JjIdentity identity)
          _IdentityFooter(identity: identity, onSettings: widget.onIdentitySettings),
      ],
    ),
  );

  /// The body under the header: the notice, the clone form, the tree and the drop hint.
  Widget _main(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final _Notice? notice = _notice;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (notice != null) _NoticeBlock(notice: notice, onDismiss: () => setState(() => _notice = null)),
        if (_cloneOpen) _cloneForm(context),
        Expanded(
          child: ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[widget.registry, widget.session]),
            builder: (context, _) => ProjectsTree(
              key: _tree,
              projects: widget.registry.value,
              openPath: widget.session.current?.path,
              query: _search.text,
              collapsed: _collapsed,
              selected: _selected,
              newGroup: _newGroup,
              home: widget.environment.home,
              now: DateTime.now(),
              onSelect: (id) => setState(() => _selected = id),
              // A search shows every group open; a toggle then would flip a state nobody sees until it is cleared.
              onToggle: (group) => _search.text.trim().isNotEmpty
                  ? null
                  : setState(() {
                      if (!_collapsed.remove(group)) {
                        _collapsed.add(group);
                      }
                    }),
              onOpen: (entry) => unawaited(_openEntry(entry)),
              onReveal: (entry) => unawaited(widget.environment.revealInFinder(entry.path)),
              onMoveToGroup: (entry, group) => unawaited(widget.registry.move(entry.path, group: group, index: _end)),
              onRemove: (entry) {
                if (_selected == 'project:${entry.path}') {
                  setState(() => _selected = null);
                }
                unawaited(widget.registry.remove(entry.path));
              },
              onMoveItem: (item, placement) => unawaited(_moveItem(item, placement)),
              onDropFolders: (paths, placement) => unawaited(_addFolders(paths, placement)),
              onDropHover: (hovering) => setState(() => _rowDrop = hovering),
              onNewGroupCommit: (name) => unawaited(_commitNewGroup(name)),
              onNewGroupCancel: () => setState(() => _newGroup = null),
            ),
          ),
        ),
        if (_outerDrop || _rowDrop) _DropHint(colors: colors),
      ],
    );
  }

  /// The header's controls, 12 apart; [ZsWindowScaffold] puts them after the title and centres them on the
  /// traffic-light block's line.
  Widget _header({required bool narrow}) => Row(
    mainAxisSize: MainAxisSize.min,
    spacing: 12,
    children: <Widget>[
      SizedBox(
        width: narrow ? ProjectsWindow.searchNarrowWidth : ProjectsWindow.searchWidth,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          onKeyEvent: (node, event) {
            if (event is! KeyUpEvent && event.logicalKey == LogicalKeyboardKey.arrowDown) {
              _tree.currentState?.focusTabStop();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: ZsSearchField(
            controller: _search,
            focusNode: _searchFocus,
            placeholder: 'Search projects, paths…',
            identifier: 'projects-search',
            onChanged: (_) => setState(() {}),
          ),
        ),
      ),
      ZsButton(
        label: 'Add directory',
        variant: ZsButtonVariant.primary,
        size: ZsButtonSize.md,
        icon: ZI.plus,
        identifier: 'projects-add-directory',
        onPressed: () => unawaited(_chooseDirectory()),
      ),
      ZsButton(
        label: 'Clone…',
        size: ZsButtonSize.md,
        icon: ZI.cloud,
        iconOnly: narrow,
        identifier: 'projects-clone',
        // While a clone runs its form stays as it is.
        onPressed: _cloneBusy ? null : () => _cloneOpen ? _closeCloneForm() : openCloneForm(),
      ),
      ZsButton(
        label: 'New group',
        variant: ZsButtonVariant.ghost,
        size: ZsButtonSize.md,
        icon: ZI.folderPlus,
        iconOnly: true,
        identifier: 'projects-new-group',
        onPressed: _startNewGroup,
      ),
    ],
  );

  Widget _cloneForm(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final bool ready = _cloneUrl.text.trim().isNotEmpty && _cloneDestination.text.trim().isNotEmpty;
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.flBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 8,
          children: <Widget>[
            ZsTextField(
              controller: _cloneUrl,
              placeholder: 'Repository URL',
              label: 'Repository URL',
              enabled: !_cloneBusy,
              identifier: 'projects-clone-url',
              onChanged: (url) => setState(() => _urlChanged(url)),
              onSubmitted: (_) => unawaited(_submitClone()),
            ),
            Row(
              spacing: 8,
              children: <Widget>[
                Expanded(
                  child: ZsTextField(
                    controller: _cloneDestination,
                    mono: true,
                    placeholder: 'Destination',
                    label: 'Destination',
                    enabled: !_cloneBusy,
                    identifier: 'projects-clone-destination',
                    onChanged: (_) => setState(() => _destinationEdited = true),
                    onSubmitted: (_) => unawaited(_submitClone()),
                  ),
                ),
                ZsButton(
                  label: 'Choose…',
                  size: ZsButtonSize.md,
                  identifier: 'projects-clone-choose',
                  onPressed: _cloneBusy ? null : () => unawaited(_chooseCloneParent()),
                ),
                ZsButton(
                  label: 'Cancel',
                  size: ZsButtonSize.md,
                  identifier: 'projects-clone-cancel',
                  onPressed: _cloneBusy ? null : _closeCloneForm,
                ),
                ZsTooltip(
                  message: 'Clone',
                  cmd: _cloneCommand,
                  child: ZsButton(
                    label: 'Clone',
                    variant: ZsButtonVariant.primary,
                    size: ZsButtonSize.md,
                    busy: _cloneBusy,
                    identifier: 'projects-clone-submit',
                    onPressed: ready ? () => unawaited(_submitClone()) : null,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheet(BuildContext context, _Offer offer) {
    final String name = _nameOf(offer.path);
    const TextStyle mono = ZsType.id;
    // The body names the folder as the tree does (`~` for home); the well shows the command with the full path.
    String shown(String path) => displayPath(path, widget.environment.home);
    final (String title, String confirm, String? cmd, List<InlineSpan> body) = switch (offer.kind) {
      _OfferKind.convert => (
        'Convert $name to a jj repository?',
        'Convert',
        'jj git init --colocate ${shellQuote(offer.path)}',
        <InlineSpan>[
          if (offer.inside case final String inside) ...<InlineSpan>[
            TextSpan(text: shown(inside), style: mono),
            const TextSpan(text: ' lies inside the Git repository at '),
            TextSpan(text: shown(offer.path), style: mono),
            const TextSpan(text: '. It stays a Git repository; jj joins it and shares its working copy.'),
          ] else ...<InlineSpan>[
            TextSpan(text: shown(offer.path), style: mono),
            const TextSpan(text: ' stays a Git repository; jj joins it and shares its working copy.'),
          ],
        ],
      ),
      _OfferKind.init => (
        'Create a jj repository in $name?',
        'Create',
        'jj git init --no-colocate ${shellQuote(offer.path)}',
        <InlineSpan>[
          TextSpan(text: shown(offer.path), style: mono),
          const TextSpan(text: ' becomes a jj repository, its Git store inside .jj.'),
        ],
      ),
      _ => (
        'Add the enclosing repository $name?',
        'Add',
        null,
        <InlineSpan>[
          TextSpan(text: shown(offer.inside ?? offer.path), style: mono),
          const TextSpan(text: ' lies inside the jj repository at '),
          TextSpan(text: shown(offer.path), style: mono),
          const TextSpan(text: '.'),
        ],
      ),
    };
    return ZsConfirmDialog(
      title: title,
      confirmLabel: confirm,
      tone: ZsConfirmTone.standard,
      cmd: cmd,
      body: Text.rich(TextSpan(children: body)),
      busy: offer.busy,
      closing: offer.closing,
      onConfirm: () => unawaited(_confirm(offer)),
      onCancel: () => _cancel(offer),
      onClosed: () => _closed(offer),
      identifier: 'projects-offer',
    );
  }
}

/// The sidebar's brand block (DS ui_kits/desktop/kit.css:192-194): padding 6 14 12, gap 9 — the 32 px Nami chip,
/// "Zanshin" (`--fs-lg` 600, tracked .02em) and the version lines (mono `--fs-xs` `--text-dim`, one line each, 1
/// apart): the app's [version], then "jj-lib ‹version›" for [jjLibVersion] — a line of its own, as both would not fit
/// one 131 px line (Claude's proposal). A null version leaves its line out.
class _Brand extends StatelessWidget {
  const _Brand({required this.version, required this.jjLibVersion});

  final String? version;
  final String? jjLibVersion;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? version = this.version;
    final String? jjLibVersion = this.jjLibVersion;
    Text line(String text) => Text(
      text,
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.ellipsis,
      style: ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.textDim),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 12),
      child: Row(
        spacing: 9,
        children: <Widget>[
          const ZsNamiMark(size: 32, chip: true),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              spacing: 1,
              children: <Widget>[
                Text(
                  'Zanshin',
                  style: ZsType.panelTitle.copyWith(letterSpacing: .02 * ZsType.fsLg, color: colors.text),
                ),
                if (version != null) line(version),
                if (jjLibVersion != null) line('jj-lib $jjLibVersion'),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A sidebar navigation row (DS components/surfaces/surfaces.css:33-39): 30 high, padding 0 9, radius `--radius-btn`,
/// gap 8, `--fs-control` in `--text-muted` with the md icon in `--text-dim`; hover `--fl-hover`, pressed `--fl-on`,
/// both turning the text `--text`; the [current] row `--fl-on` in `--text`, no control (the section shown).
class _NavRow extends StatelessWidget {
  const _NavRow({required this.icon, required this.label, this.current = false, this.onPressed, this.identifier});

  final String icon;
  final String label;
  final bool current;
  final VoidCallback? onPressed;
  final String? identifier;

  Widget _face(BuildContext context, {required bool hovered, required bool pressed}) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final Color fill = current
        ? colors.flOn
        : (pressed ? colors.flOn : (hovered ? colors.flHover : const Color(0x00000000)));
    final bool lit = current || hovered || pressed;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: fill),
      duration: pressed ? motion.durInstant : motion.durHover,
      curve: motion.easeState,
      builder: (context, color, child) => DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(metrics.radiusBtn)),
        child: child,
      ),
      child: SizedBox(
        height: metrics.controlMd,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Row(
            spacing: 8,
            children: <Widget>[
              ZanshinIcon(icon, size: ZsIconSize.md, color: colors.textDim),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  softWrap: false,
                  overflow: TextOverflow.ellipsis,
                  style: ZsType.secondary.copyWith(
                    fontSize: ZsType.fsControl,
                    height: 1.2,
                    color: lit ? colors.text : colors.textMuted,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (current) {
      return Semantics(
        selected: true,
        label: label,
        child: ExcludeSemantics(child: _face(context, hovered: false, pressed: false)),
      );
    }
    return ZsControlCore(
      identifier: identifier,
      onActivate: onPressed,
      enabled: onPressed != null,
      semantics: SemanticsProperties(button: true, label: label),
      ring: ZsRingPlacement.inside,
      ringRadius: ZsMetrics.of(context).radiusBtn,
      builder: (context, status) => _face(context, hovered: status.hovered, pressed: status.pressed),
    );
  }
}

/// The identity footer (DS ui_kits/desktop/kit.css:195-200, its "Signed in" block): a `--fl-border` hairline above,
/// padding 10 14 14, the caps label "Identity" 6 above the avatar (24, `--fl-on`, the initial in `--fs-sm` 600) with the
/// name (`--fs-id` `--text-muted`) over the email (mono `--fs-xs` `--text-dim`); without a full identity the CLI's
/// phrase and, with [onSettings], "Set identity…".
class _IdentityFooter extends StatelessWidget {
  const _IdentityFooter({required this.identity, required this.onSettings});

  final JjIdentity identity;
  final VoidCallback? onSettings;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final String? missing = identity.missingPhrase;
    final String? name = identity.name;
    final String? email = identity.email;
    final TextStyle text = ZsType.meta.copyWith(fontSize: ZsType.fsId, color: colors.textMuted);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: colors.flBorder)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
        child: Semantics(
          identifier: 'projects-identity',
          container: true,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 6,
            children: <Widget>[
              Text(ZsType.caps('Identity'), style: ZsType.capsLabel.copyWith(color: colors.textDim)),
              if (missing == null && name != null && email != null)
                Row(
                  spacing: 8,
                  children: <Widget>[
                    ExcludeSemantics(
                      child: DecoratedBox(
                        decoration: BoxDecoration(color: colors.flOn, shape: BoxShape.circle),
                        child: SizedBox.square(
                          dimension: 24,
                          child: Center(
                            child: Text(
                              name.characters.first.toUpperCase(),
                              style: ZsType.meta.copyWith(
                                fontWeight: FontWeight.w600,
                                fontVariations: const <FontVariation>[FontVariation.weight(600)],
                                color: colors.text,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        spacing: 1,
                        children: <Widget>[
                          Text(name, maxLines: 1, softWrap: false, overflow: TextOverflow.ellipsis, style: text),
                          Text(
                            email,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: ZsType.id.copyWith(fontSize: ZsType.fsXs, color: colors.textDim),
                          ),
                        ],
                      ),
                    ),
                  ],
                )
              else ...<Widget>[
                Text(missing ?? '', style: text),
                if (onSettings case final VoidCallback open)
                  ZsLink(label: 'Set identity…', onPressed: open, identifier: 'projects-identity-settings'),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// The notice under the header (Claude's proposal): padding 8 12, `--fs-control`; the title in `--text`, then each line
/// verbatim in `--text-muted`; a hairline below; dismissed by its ✕.
class _NoticeBlock extends StatelessWidget {
  const _NoticeBlock({required this.notice, required this.onDismiss});

  final _Notice notice;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final TextStyle style = ZsType.secondary.copyWith(fontSize: ZsType.fsControl, color: colors.textMuted);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.flBorder)),
      ),
      child: Semantics(
        identifier: 'projects-notice',
        container: true,
        liveRegion: true,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  spacing: 2,
                  children: <Widget>[
                    Text(
                      notice.title,
                      style: style.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w500,
                        fontVariations: const <FontVariation>[FontVariation.weight(500)],
                      ),
                    ),
                    for (final String line in notice.lines) Text(line, style: style),
                  ],
                ),
              ),
              ZsIconButton(
                icon: ZI.close,
                label: 'Dismiss',
                size: ZsIconButtonSize.sm,
                identifier: 'projects-notice-dismiss',
                onPressed: onDismiss,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The drop hint, shown only during a Finder drag (the floating export's `.home-drop-hint.active`, app.css:2345-2362;
/// its `download` glyph retired for `fetch`): margin 0 12 12, padding 9 12, gap 7, `--fs-id`, a 1 px line — in the
/// live accent copies, since a Finder drop lands in a window that is not key.
class _DropHint extends StatelessWidget {
  const _DropHint({required this.colors});

  final ZsColors colors;

  @override
  Widget build(BuildContext context) => Semantics(
    identifier: 'projects-drop-hint',
    container: true,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: colors.accentLiveLine),
          borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusSm),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            spacing: 7,
            children: <Widget>[
              ZanshinIcon(ZI.fetch, size: ZsIconSize.md, color: colors.accentLiveText),
              Text(
                'Drop to add directory',
                style: ZsType.meta.copyWith(fontSize: ZsType.fsId, color: colors.accentLiveText),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
