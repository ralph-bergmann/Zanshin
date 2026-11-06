// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_settings/zanshin_settings.dart' show ProjectEntry, SettingsStore;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../bootstrap/boot_window_host.dart' show mainWindowTitle;
import '../graph/graph_layout.dart';
import '../graph/graph_ports.dart';
import '../graph/graph_preferences.dart';
import '../graph/graph_search_controller.dart';
import '../graph/graph_view_model.dart';
import '../home/home_page.dart' show openRecentProject;
import '../projects/project_session.dart';
import '../projects/projects_window.dart';
import '../sync/sync_model.dart';
import '../window/active_window_tracker.dart';
import '../window/app_window_actions.dart';
import '../window/app_windows.dart';
import '../window/window_zoom.dart';

final _log = Logger('zanshin.menu');

/// The channel the menu bar sends what the engine cannot express over (Story 11.17): checkmarks and the system items'
/// enabled state; the runner applies it to `NSApp.mainMenu`.
const menuStateChannel = MethodChannel('zanshin/menu_state');

/// The AppKit selectors of Window › Minimize, Window › Zoom and View › Enter Full Screen.
const _minimize = 'performMiniaturize:'; // l10n-ignore: an AppKit selector
const _zoom = 'performZoom:'; // l10n-ignore: an AppKit selector
const _fullScreen = 'toggleFullScreen:'; // l10n-ignore: an AppKit selector

/// jj's documentation at the pinned jj-lib version.
final Uri jjDocumentationUrl = Uri.parse('https://docs.jj-vcs.dev/v0.46.0/'); // l10n-ignore: a URL

Future<void> _openInBrowser(Uri url) async {
  // Detached: a non-detached Dart child lets the VM reap the cdylib's children (project-context.md § Dart).
  await Process.start('/usr/bin/open', <String>[url.toString()], mode: ProcessStartMode.detached);
}

/// What the project window publishes for the menu bar once its graph is mounted (10.12): the graph's view model, its
/// View preferences and the search's focus.
@immutable
class GraphMenuBinding {
  /// The binding of [model] and [preferences].
  const GraphMenuBinding({
    required this.model,
    required this.preferences,
    this.search,
    this.focusSearch,
    this.squash,
    this.sync,
  });

  /// The graph's view model: the Change, Go and Undo items act on it.
  final GraphViewModel model;

  /// The View items' setters.
  final GraphPreferences preferences;

  /// The graph search: the jj log Configurations window counts, shows and redraws through it (Story 10.22).
  final GraphSearchController? search;

  /// Focuses the graph search (Edit › Find); null while there is none.
  final VoidCallback? focusSearch;

  /// Change › Squash into Parent through the inspector (`InspectorViewModel.squash`, Story 10.25), which asks for the
  /// combined description; null runs `jj squash -r` directly.
  final ValueChanged<String>? squash;

  /// Change › Fetch and Push… (Story 11.8); null leaves them grey.
  final SyncModel? sync;
}

/// The menu bar's state (Story 11.13; DS readme.md:196–209): the menus follow the key window, the open project, the
/// sheets ([ZsSheet.openViews]), the focused text field and the [graph] the project window publishes. Every item runs
/// its handler or is grey (`onSelected == null`) when none is reachable.
///
/// - **Key window** ([ActiveWindowTracker.keyView] through [AppWindows.keyOfView]): Close Window asks it to close as
///   its red button does ([AppWindows.requestClose]); grey before the first focus event and while a sheet shows there.
/// - **Project window items** (Close Window there, Open Recent, Reload, Find there, Undo/Redo, View-graph, Change, Go)
///   are grey while a sheet shows in the project window (I3). The graph items are also grey while no graph is bound,
///   while the runner is busy and while the working copy is stale ([GraphViewModel.actionsEnabled]).
/// - **Change items** act on [GraphViewModel.actionTarget] (the selection, else @), pass its id in full and name it:
///   "@", else max(prefix, 8) characters of the change id. Edit and Revert are grey while the target is @.
/// - **Text first:** Undo and Redo act on a focused text field before the graph; Cut, Copy, Paste and Select All send
///   their text intents to the focused text field and are grey without one.
/// - Items whose handler story has not landed stay grey: Describe… and the app's Help. Edit Configurations… opens the
///   jj log Configurations window (Story 10.22). Change › Fetch and Push… run the bound graph's sync (Story 11.8) while
///   it allows them.
///
/// Its listeners hear a change after the current frame's work (a microtask): sheets come and go while the tree builds.
@inject
@singleton
class AppMenuModel extends ChangeNotifier {
  /// The model over [_tracker] and [_session]; [attach] hands it the windows.
  AppMenuModel(this._tracker, this._session) {
    _tracker.addListener(_changed);
    _session.addListener(_changed);
    ZsSheet.openViews.addListener(_changed);
    graph.addListener(_graphChanged);
    FocusManager.instance.addListener(_changed);
  }

  final ActiveWindowTracker _tracker;
  final ProjectSession _session;
  AppWindows? _windows;
  AppWindowActions? _actions;

  /// The Projects window content's key, for Edit › Find while Projects is key.
  final projectsKey = GlobalKey<ProjectsWindowState>();

  /// The project window's graph, once it publishes one.
  final graph = ValueNotifier<GraphMenuBinding?>(null);
  GraphMenuBinding? _bound;

  /// Opens a URL in the browser (Help › jj Documentation, the Configurations window's Revset reference); a seam for
  /// tests.
  Future<void> Function(Uri url) openUrl = _openInBrowser;

  var _scheduled = false;
  var _disposed = false;

  /// Hands over the app's [windows], the window [actions] (the coordinator) and the [settings], whose
  /// `appearance.zoom` View › Zoom In, Zoom Out and Actual Size read and write (Story 11.20).
  void attach(AppWindows windows, AppWindowActions actions, SettingsStore settings) {
    _windows = windows;
    _actions = actions;
    _settings?.removeListener(_changed);
    _settings = settings..addListener(_changed);
    _changed();
  }

  SettingsStore? _settings;

  /// Sets the zoom to [percent]; null (grey) without settings or when [percent] is the zoom already.
  VoidCallback? _zoomTo(int percent) {
    final SettingsStore? settings = _settings;
    if (settings == null || percent == zoomStepOf(settings.value.appearance.zoom)) {
      return null;
    }
    return () => unawaited(settings.update((s) => s.copyWith.appearance(zoom: percent)));
  }

  void _graphChanged() {
    _bound?.model.removeListener(_changed);
    _bound?.preferences.removeListener(_changed);
    _bound?.sync?.removeListener(_changed);
    _bound = graph.value;
    _bound?.model.addListener(_changed);
    _bound?.preferences.addListener(_changed);
    _bound?.sync?.addListener(_changed);
    _changed();
  }

  void _changed() {
    if (_scheduled || _disposed) {
      return;
    }
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      if (!_disposed) {
        notifyListeners();
      }
    });
  }

  /// The key of the key window, or null.
  String? get _keyWindow => switch (_tracker.keyView) {
    final int view => _windows?.keyOfView(view),
    null => null,
  };

  bool _sheetIn(String? key) {
    final int? view = key == null ? null : _windows?.viewIdOf(key);
    return view != null && ZsSheet.openViews.value.contains(view);
  }

  bool get _projectSheet => _sheetIn(mainWindowKey);

  /// The bound graph while its items may act: no sheet in the project window, no action running, not stale.
  GraphMenuBinding? get _ready {
    final GraphMenuBinding? bound = graph.value;
    return bound != null && !_projectSheet && bound.model.actionsEnabled ? bound : null;
  }

  /// The primary focus's context while it is inside a text field.
  static BuildContext? get _textField {
    final BuildContext? focus = FocusManager.instance.primaryFocus?.context;
    return focus?.findAncestorStateOfType<EditableTextState>() == null ? null : focus;
  }

  /// Sends [intent] to the focused text field; grey without one.
  static VoidCallback? _intent(Intent intent) {
    final BuildContext? focus = _textField;
    return focus == null ? null : () => Actions.maybeInvoke(focus, intent);
  }

  static VoidCallback _run(Future<Object?> Function() action) =>
      () => unawaited(
        action().catchError((Object error, StackTrace stackTrace) {
          _log.severe('A menu command failed', error, stackTrace);
          return null;
        }),
      );

  /// How a menu names [id]: "@" for the working copy, else max(prefix, 8) characters (decision 16.35).
  static String targetName(GraphViewModel model, String id) {
    final GraphLayout? layout = model.layout;
    final int? at = layout?.workingCopyIndex;
    if (at != null && layout!.keyOf(at) == id) {
      return '@'; // l10n-ignore: jj's symbol
    }
    final int? node = layout?.indexOfKey(id);
    final int prefix = node == null ? 2 : layout!.changeIdPrefixLengthOf(node);
    return id.substring(0, math.min(id.length, math.max(prefix, 8)));
  }

  /// "‹verb› ‹target›" of [action], for Undo and Redo.
  static String actionName(AppLocalizations s, GraphViewModel model, GraphAction action) {
    String name(String id) => targetName(model, id);
    String names(List<String> ids) => ids.map(name).join(', ');
    return switch (action) {
      GraphAbandon(:final ids) => s.menuAbandonTarget(names(ids)),
      GraphEdit(:final id) => s.menuChangeEditTarget(name(id)),
      GraphDescribe(:final id) => s.menuDescribeTarget(name(id)),
      GraphNew(:final parents) when parents.length > 1 => s.menuNewMerge(
        name(parents.last),
        names(parents.sublist(0, parents.length - 1)),
      ),
      GraphNew() => s.menuNewChange,
      GraphRebase(:final source, :final revisions, :final onto, :final insertAfter, :final insertBefore) =>
        insertAfter.isNotEmpty
            ? s.menuRebaseAfter(names(<String>[...source, ...revisions]), names(insertAfter))
            : insertBefore.isNotEmpty
            ? s.menuRebaseBefore(names(<String>[...source, ...revisions]), names(insertBefore))
            : s.menuRebaseOnto(names(<String>[...source, ...revisions]), names(onto)),
      GraphDuplicate(:final revisions, :final onto) => s.menuDuplicateOnto(names(revisions), names(onto)),
      GraphRevert(:final id) => s.menuRevertTarget(name(id)),
      GraphSquash(:final revision, :final from) => s.menuSquashTarget(
        revision != null
            ? name(revision)
            : from.isNotEmpty
            ? names(from)
            : '@', // l10n-ignore: jj's symbol
      ),
      GraphCommit(:final id) => s.menuCommitTarget(name(id)),
      GraphSplit(:final id) => s.menuSplitTarget(name(id)),
      GraphBookmarkCreate(:final names) => s.menuBookmarkCreate(names.join(', ')),
      GraphBookmarkDelete(:final names) => s.menuBookmarkDelete(names.join(', ')),
      GraphBookmarkMove(:final names) => s.menuBookmarkMove(names.join(', ')),
      GraphBookmarkRename(:final oldName) => s.menuBookmarkRename(oldName),
      GraphBookmarkTrack(:final name, :final remote) => s.menuBookmarkTrack('$name@$remote'), // l10n-ignore: symbol
      GraphBookmarkUntrack(:final name, :final remote) => s.menuBookmarkUntrack('$name@$remote'), // l10n-ignore: symbol
      GraphUndo(:final of) || GraphRedo(:final of) => actionName(s, model, of),
      GraphLoggedOperation(:final command) => command,
      GraphOpRestore(:final operation) => s.menuRestoreOperation(operation),
    };
  }

  /// The menus before the model is attached (the boot): the system's items only.
  static List<PlatformMenuItem> bootMenus(AppLocalizations s) => <PlatformMenuItem>[
    _appMenu(s, onSettings: null),
    PlatformMenu(
      label: s.menuWindow,
      menus: const <PlatformMenuItem>[
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
        PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
      ],
    ),
  ];

  static PlatformMenu _appMenu(AppLocalizations s, {required VoidCallback? onSettings}) => PlatformMenu(
    label: mainWindowTitle,
    menus: <PlatformMenuItem>[
      const PlatformMenuItemGroup(
        members: <PlatformMenuItem>[PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about)],
      ),
      PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformMenuItem(
            label: s.settingsEllipsis,
            shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
            onSelected: onSettings,
          ),
        ],
      ),
      const PlatformMenuItemGroup(
        members: <PlatformMenuItem>[PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu)],
      ),
      const PlatformMenuItemGroup(
        members: <PlatformMenuItem>[
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
          PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
        ],
      ),
      const PlatformMenuItemGroup(
        members: <PlatformMenuItem>[PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit)],
      ),
    ],
  );

  /// The eight top menus in [s]'s strings.
  List<PlatformMenuItem> menus(AppLocalizations s) {
    final AppWindows? windows = _windows;
    final AppWindowActions? actions = _actions;
    final String? key = _keyWindow;
    final bool projectSheet = _projectSheet;
    final GraphMenuBinding? ready = _ready;
    final GraphViewModel? model = ready?.model;
    final GraphLayout? layout = model?.layout;
    final BuildContext? text = _textField;

    // Change: the target, and whether it is @.
    final String? target = model != null && model.hasActions ? model.actionTarget : null;
    final int? atNode = layout?.workingCopyIndex;
    final bool targetIsAt = target != null && atNode != null && layout!.keyOf(atNode) == target;
    final String? named = target == null ? null : targetName(model!, target);
    VoidCallback? change(GraphAction Function(String id) action, {bool notOnAt = false}) =>
        target == null || (notOnAt && targetIsAt) ? null : _run(() => model!.run(action(target)));

    // Undo and Redo: a text field first, else Zanshin's own operation.
    final GraphOutcome? undoable = model != null && model.hasActions ? model.undoable : null;
    final GraphOutcome? redoable = model != null && model.hasActions ? model.redoable : null;

    // Go: the selection's first parent and first child.
    final String? selected = model?.selected;
    final int? selectedNode = selected == null ? null : layout?.indexOfKey(selected);
    String? parent;
    String? child;
    if (selectedNode != null) {
      final ({int start, int end}) parents = layout!.parentEdges(selectedNode);
      // A folded stack's node has a synthetic key no jj verb may get: it counts as none.
      String? real(int node) => layout.isStackNode(node) ? null : layout.keyOf(node);
      if (parents.start < parents.end) {
        parent = real(layout.parentOf(parents.start));
      }
      final ({int start, int end}) children = layout.childEdges(selectedNode);
      if (children.start < children.end) {
        child = real(layout.childOf(layout.childEdgeAt(children.start)));
      }
    }
    VoidCallback? goTo(String? key) => key == null
        ? null
        : () {
            model!
              ..select(key)
              ..revealKey(key);
          };

    // Find: Projects' own search while it is key, else the graph search in the project window.
    final ProjectsWindowState? projects = key == projectsWindowKey ? projectsKey.currentState : null;
    final VoidCallback? focusSearch = ready?.focusSearch;
    final VoidCallback? find = projects != null
        ? (_sheetIn(projectsWindowKey) ? null : projects.focusSearch)
        : focusSearch == null
        ? null
        : () {
            windows?.activate(mainWindowKey);
            focusSearch();
          };

    final GraphPreferences? preferences = ready?.preferences;
    final bool canReload = (_session.repo != null || graph.value != null) && !projectSheet;
    final int zoom = zoomStepOf(_settings?.value.appearance.zoom ?? zoomActualSize);

    return <PlatformMenuItem>[
      _appMenu(s, onSettings: actions == null ? null : _run(actions.openSettings)),
      PlatformMenu(
        label: s.menuFile,
        menus: <PlatformMenuItem>[
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.capsuleAllProjects,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyO, meta: true, shift: true),
                onSelected: actions == null ? null : _run(actions.openProjects),
              ),
              _openRecent(s, actions == null || projectSheet ? null : actions),
              PlatformMenuItem(
                label: s.capsuleProjectSettings,
                onSelected: actions == null || _session.repo == null
                    ? null
                    : _run(() => actions.openSettings(target: SettingsTarget.project)),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuCloseWindow,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyW, meta: true),
                onSelected: windows == null || key == null || _sheetIn(key) ? null : () => windows.requestClose(key),
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: s.menuEdit,
        menus: <PlatformMenuItem>[
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: text != null || undoable == null
                    ? s.menuUndoPlain
                    : s.menuUndo(actionName(s, model!, undoable.action)),
                shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true),
                onSelected: text != null
                    ? () => Actions.maybeInvoke(text, const UndoTextIntent(SelectionChangedCause.keyboard))
                    : undoable == null
                    ? null
                    : _run(model!.undoLast),
              ),
              PlatformMenuItem(
                label: text != null || redoable == null
                    ? s.menuRedoPlain
                    : s.menuRedo(actionName(s, model!, redoable.action)),
                shortcut: const SingleActivator(LogicalKeyboardKey.keyZ, meta: true, shift: true),
                onSelected: text != null
                    ? () => Actions.maybeInvoke(text, const RedoTextIntent(SelectionChangedCause.keyboard))
                    : redoable == null
                    ? null
                    : _run(model!.redoLast),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuCut,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyX, meta: true),
                onSelected: _intent(const CopySelectionTextIntent.cut(SelectionChangedCause.keyboard)),
              ),
              PlatformMenuItem(
                label: s.menuCopy,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyC, meta: true),
                onSelected: _intent(CopySelectionTextIntent.copy),
              ),
              PlatformMenuItem(
                label: s.menuPaste,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyV, meta: true),
                onSelected: _intent(const PasteTextIntent(SelectionChangedCause.keyboard)),
              ),
              PlatformMenuItem(
                label: s.menuSelectAll,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyA, meta: true),
                onSelected: _intent(const SelectAllTextIntent(SelectionChangedCause.keyboard)),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuFind,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyF, meta: true),
                onSelected: find,
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: s.menuView,
        menus: <PlatformMenuItem>[
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuFree,
                shortcut: const SingleActivator(LogicalKeyboardKey.digit1, meta: true),
                onSelected: preferences == null ? null : () => preferences.setLayout(GraphMode.free),
              ),
              PlatformMenuItem(
                label: s.menuCompact,
                shortcut: const SingleActivator(LogicalKeyboardKey.digit2, meta: true),
                onSelected: preferences == null ? null : () => preferences.setLayout(GraphMode.compact),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuDetailedCards,
                onSelected: preferences == null
                    ? null
                    : () => preferences.setDetailedCards(!preferences.options.detailedCards),
              ),
              PlatformMenuItem(
                label: s.menuGroupStacks,
                onSelected: preferences == null ? null : () => preferences.setGroupStacks(!preferences.groupStacks),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuEditConfigurations,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyL, meta: true, alt: true),
                onSelected: actions == null ? null : _run(actions.openRevsetConfigs),
              ),
              PlatformMenuItem(
                label: s.menuShowMinimap,
                onSelected: preferences == null ? null : () => preferences.setShowMinimap(!preferences.showMinimap),
              ),
              PlatformMenuItem(
                label: s.menuReload,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyR, meta: true),
                onSelected: canReload
                    ? () {
                        _session.refresh();
                        graph.value?.model.reload();
                      }
                    : null,
              ),
            ],
          ),
          // Zoom (Story 11.20; DS readme › View): Settings › General › Zoom's steps, in every window; each item grey
          // at its end.
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuZoomIn,
                shortcut: const CharacterActivator('+', meta: true),
                onSelected: _zoomTo(zoomInFrom(zoom)),
              ),
              PlatformMenuItem(
                label: s.menuZoomOut,
                shortcut: const SingleActivator(LogicalKeyboardKey.minus, meta: true),
                onSelected: _zoomTo(zoomOutFrom(zoom)),
              ),
              PlatformMenuItem(
                label: s.menuActualSize,
                shortcut: const SingleActivator(LogicalKeyboardKey.digit0, meta: true),
                onSelected: _zoomTo(zoomActualSize),
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: <PlatformMenuItem>[PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.toggleFullScreen)],
          ),
        ],
      ),
      PlatformMenu(
        label: s.menuChange,
        menus: <PlatformMenuItem>[
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuNewChange,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
                onSelected: change((id) => GraphNew(parents: <String>[id])),
              ),
              PlatformMenuItem(label: s.menuDescribe),
              PlatformMenuItem(
                label: named == null || targetIsAt ? s.menuChangeEdit : s.menuChangeEditTarget(named),
                onSelected: change(GraphEdit.new, notOnAt: true),
              ),
              PlatformMenuItem(
                label: named == null ? s.menuSquash : s.menuSquashTarget(named),
                onSelected: switch (ready?.squash) {
                  final ValueChanged<String> squash when target != null => () => squash(target),
                  _ => change((id) => GraphSquash(revision: id)),
                },
              ),
              PlatformMenuItem(
                label: named == null || targetIsAt ? s.menuRevert : s.menuRevertTarget(named),
                onSelected: change(GraphRevert.new, notOnAt: true),
              ),
              PlatformMenuItem(
                label: named == null ? s.menuAbandon : s.menuAbandonTarget(named),
                shortcut: const SingleActivator(LogicalKeyboardKey.backspace, meta: true),
                onSelected: change((id) => GraphAbandon(<String>[id])),
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuFetch,
                onSelected: switch (ready?.sync) {
                  final SyncModel sync when sync.canFetch => _run(sync.fetch),
                  _ => null,
                },
              ),
              PlatformMenuItem(
                label: s.menuPush,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true),
                onSelected: switch (ready?.sync) {
                  final SyncModel sync when sync.canPush => sync.openPush,
                  _ => null,
                },
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: s.menuGo,
        menus: <PlatformMenuItem>[
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.menuGoSelection,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true),
                onSelected: selected == null ? null : model!.scrollToSelection,
              ),
              PlatformMenuItem(
                label: s.menuGoWorkingCopy,
                shortcut: const SingleActivator(LogicalKeyboardKey.keyJ, meta: true, shift: true),
                onSelected: atNode == null ? null : model!.scrollToWorkingCopy,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(label: s.menuGoParent, onSelected: goTo(parent)),
              PlatformMenuItem(label: s.menuGoChild, onSelected: goTo(child)),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: s.menuWindow,
        menus: <PlatformMenuItem>[
          const PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.minimizeWindow),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.zoomWindow),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: s.projectsTitle,
                onSelected: actions == null ? null : _run(actions.openProjects),
              ),
            ],
          ),
          const PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.arrangeWindowsInFront),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: s.menuHelp,
        menus: <PlatformMenuItem>[
          PlatformMenuItem(label: s.menuAppHelp(mainWindowTitle)),
          PlatformMenuItem(
            label: s.menuToolDocumentation('jj'), // l10n-ignore: jj's name
            onSelected: _run(() => openUrl(jjDocumentationUrl)),
          ),
        ],
      ),
    ];
  }

  /// Whether Minimize, Zoom and Enter Full Screen act on the window [key] (epics.md 11.13 scope 3), by selector: all
  /// grey with no key window and for Settings, Zoom only for Projects and Configurations, all for the project window.
  static Map<String, bool> windowItemsEnabled(String? key) {
    final bool all = key != null && key != settingsWindowKey;
    final bool resizableDialog = key == projectsWindowKey || key == revsetConfigsWindowKey;
    return <String, bool>{_minimize: all && !resizableDialog, _zoom: all, _fullScreen: all && !resizableDialog};
  }

  /// What `zanshin/menu_state`'s `apply` gets: the toggles' checked state, by top-menu and item title in [s]'s strings,
  /// and [windowItemsEnabled] of the key window.
  Map<String, Object> nativeState(AppLocalizations s) {
    final GraphPreferences? preferences = graph.value?.preferences;
    Map<String, Object> toggle(String item, bool checked) => <String, Object>{
      'menu': s.menuView,
      'item': item,
      'checked': checked,
    };
    return <String, Object>{
      'checked': <Map<String, Object>>[
        toggle(s.menuDetailedCards, preferences?.options.detailedCards ?? false),
        toggle(s.menuGroupStacks, preferences?.groupStacks ?? false),
        toggle(s.menuShowMinimap, preferences?.showMinimap ?? false),
      ],
      'enabled': windowItemsEnabled(_keyWindow),
    };
  }

  /// File › Open Recent: the session's Recent, each opening as the capsule's row does; grey without [actions] or
  /// without a recent project.
  PlatformMenuItem _openRecent(AppLocalizations s, AppWindowActions? actions) {
    final List<ProjectEntry> recent = _session.recent;
    if (actions == null || recent.isEmpty) {
      return PlatformMenuItem(label: s.menuOpenRecent);
    }
    return PlatformMenu(
      label: s.menuOpenRecent,
      menus: <PlatformMenuItem>[
        for (final ProjectEntry project in recent)
          PlatformMenuItem(
            label: project.name,
            onSelected: _run(() => openRecentProject(_session, actions, project.path)),
          ),
      ],
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _tracker.removeListener(_changed);
    _session.removeListener(_changed);
    ZsSheet.openViews.removeListener(_changed);
    FocusManager.instance.removeListener(_changed);
    _settings?.removeListener(_changed);
    _bound?.model.removeListener(_changed);
    _bound?.preferences.removeListener(_changed);
    _bound?.sync?.removeListener(_changed);
    graph.dispose();
    super.dispose();
  }
}

/// The native menu bar over [child]: [model]'s menus, or the boot's system items until it arrives. Its shape stays the
/// same either way, so [child] (the window manager) is never rebuilt from scratch.
class AppMenuBar extends StatelessWidget {
  /// The menu bar of [model] above [child].
  const AppMenuBar({required this.model, required this.child, super.key});

  /// The menus' state; null during the boot.
  final AppMenuModel? model;

  /// The windows.
  final Widget child;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable?>[model]),
    builder: (context, child) {
      final AppLocalizations strings = platformStrings();
      if (model case final AppMenuModel model) {
        final Map<String, Object> state = model.nativeState(strings);
        // After the frame: behind the engine's `Menu.setMenus` of this build on the same messenger.
        WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_apply(state)));
      }
      return PlatformMenuBar(
        menus: model?.menus(strings) ?? AppMenuModel.bootMenus(strings),
        child: child,
      );
    },
    child: child,
  );

  static Future<void> _apply(Map<String, Object> state) async {
    try {
      await menuStateChannel.invokeMethod<void>('apply', state);
    } on MissingPluginException {
      // No runner handler: tests and other platforms.
    } on PlatformException catch (error) {
      _log.warning('The menu state was not applied', error);
    }
  }
}
