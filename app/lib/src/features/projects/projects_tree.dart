// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart' show kDoubleTapTimeout;
import 'package:flutter/rendering.dart' show SemanticsProperties, TreeSliverIndentationType;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_settings/zanshin_settings.dart';
import 'package:zanshin_shell/zanshin_shell.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import 'project_status_style.dart';
import 'projects_tree_model.dart';
import 'relative_time.dart';
import 'tree_drop.dart';

/// The Projects window's tree (epics.md Story 11.6 item 4 and design update item 4, Story 11.15; DS
/// components/content/ProjectRow.{jsx,prompt.md}; content.css:66-95), over [projects] as [projectsTree] projects it.
///
/// **Rows.** 28 high for a group, 44 for a project, 1 apart, indented 16 per level from 8; radius `--radius-md`. A group
/// shows the chevron (sm in a 14 box, turning on `--dur-expand`), the folder (open while expanded), its name in caps
/// (`--fs-sm` 600, tracked .08em, `--text-muted`) and the count mono `--fs-xs` `--text-faint`. A project shows its 7 px
/// status dot (none before its first reading; Claude's proposal), its name (13/500), the saffron caps OPEN on the open
/// project, its bookmark label (mono `--fs-xs` `--text-dim` after the xs `branch` glyph, ProjectRow.jsx:66; none
/// without one), then its path with `~` and when it was last opened. Both end in the 22 px ••• that shows on hover and
/// with focus inside the row. A missing project strikes its name and path through in `--text-faint`, its dot at half.
///
/// **States.** Hover `--fl-hover`, pressed `--fl-on`; selected `--accent-soft` (also on hover), pressed
/// `--accent-soft-hi`; secondary text takes the next rung on a fill; under increased contrast a selected row has a 1 px
/// `--accent-line` edge inside (DS tokens/contrast.css:26). A click selects (a group also toggles); a double-click
/// opens a project; a click on the empty tree below the rows clears the selection (Story 11.15 item 1).
///
/// **The row menu** (••• below the button, a right-click at the pointer; either selects the row): a project — Open,
/// Reveal in Finder, Move to group › and Remove from list (Claude's proposal), Open and Reveal disabled for a missing
/// project, Remove for the open one; a group — Rename… · Move to group › · — · Delete group (Story 11.15 item 3).
/// Move to group › lists Top level and every group by its path ("Work / Mobile"), sorted, radio-checked where the row
/// is — a group's never itself or a group inside it — then — · New group… (item 6).
///
/// **Naming** (item 4; DS ProjectRow.prompt.md:17): New group's field and Rename…'s are one field (TextField sm in a
/// 34 row, the chevron slot and the folder before it). ↩ commits, Esc cancels; focus leaving keeps a rename and cancels
/// a new group; an empty name cancels (a rename keeps its old name).
///
/// **Keys** (decision 16.43; DS ProjectRow.prompt.md:11): one Tab stop — the selected row, else the first; focus that
/// arrives selects its row. ↑ ↓ Home End move and select, → expands a group or steps into it, ← collapses one or steps
/// to the parent, ↩ opens a project (a group toggles), typing selects the next row whose name starts with the letters
/// typed within `--dur-typeahead`. Tab from the selected row reaches its ••• and no other. When the name field closes
/// on ↩ or Esc, or a row (or its •••) leaves the tree holding focus, focus goes back to the Tab stop without selecting
/// it (a focused row that moves gets it back itself); while it stays there, it follows the selection (New group's
/// group, selected once it exists).
///
/// **Drops.** A row dragged onto another row, or a Finder folder dragged over one, lands where `tree_drop.dart` places
/// it — a group's middle half is inside it; for a dragged row an expanded group with children takes its whole lower
/// part as inside (item 7) — shown as the `--accent-soft` fill with a 1 px `--accent-live-line` border, or a 2 px
/// `--accent-live-line` line 2 above or below the row from the insertion depth's indent to 8 from the right (DS
/// content.css:71-79; the live copies: a Finder drop lands in a window that is not key). Below the last row is the end
/// of the top level, shown as that line under the last row at indent 0. A group never moves into itself. No row drags
/// while searching; Esc cancels a drag; the row in hand stays at 40 %; the pointer carries a [ZsDragGhost] 14 / 12 from
/// it, naming where a drop lands ("Into ‹group›", "To the top level") or giving the hint (item 8).
///
/// VoiceOver: a region "Projects"; each row a node named by its name, its value the dot's label (and "open"), with its
/// selected and expanded state. Identifiers: `projects-tree`, `projects-row-<i>`, `projects-row-<i>-more` in visible
/// order, `projects-menu` (entries `projects-menu-*`), `projects-new-group-name`, `projects-rename-group-name`.
class ProjectsTree extends StatefulWidget {
  /// The tree of [projects].
  const ProjectsTree({
    required this.projects,
    required this.home,
    required this.now,
    required this.onSelect,
    required this.onDeselect,
    required this.onToggle,
    required this.onOpen,
    required this.onReveal,
    required this.onMoveToGroup,
    required this.onNewGroupFor,
    required this.onRemove,
    required this.onRename,
    required this.onDeleteGroup,
    required this.onMoveItem,
    required this.onDropFolders,
    required this.onDropHover,
    required this.onNewGroupCommit,
    required this.onNewGroupCancel,
    required this.onRenameCommit,
    required this.onRenameCancel,
    this.openPath,
    this.query = '',
    this.collapsed = const <String>{},
    this.selected,
    this.newGroup,
    this.renaming,
    super.key,
  });

  /// The registry.
  final ProjectsSettings projects;

  /// The open project's path, which carries OPEN.
  final String? openPath;

  /// The search; empty shows every row.
  final String query;

  /// The collapsed groups' ids.
  final Set<String> collapsed;

  /// The selected row's [ProjectsItem.id].
  final String? selected;

  /// The new group's field, while one is being named.
  final ProjectsNewGroupItem? newGroup;

  /// The id of the group whose row is its name field, while it is being renamed.
  final String? renaming;

  /// The home folder paths abbreviate to `~`.
  final String home;

  /// The time last-opened labels count from.
  final DateTime now;

  /// Selects the row with the given id.
  final ValueChanged<String> onSelect;

  /// Clears the selection (a click below the rows).
  final VoidCallback onDeselect;

  /// Expands or collapses the group with the given id.
  final ValueChanged<String> onToggle;

  /// Opens a project (↩, a double-click, Open).
  final ValueChanged<ProjectEntry> onOpen;

  /// Reveals a project in Finder.
  final ValueChanged<ProjectEntry> onReveal;

  /// Moves a row into a group (null: the top level), last there (Move to group ›).
  final void Function(ProjectsItem item, String? group) onMoveToGroup;

  /// Starts naming a new group for the row to move into (Move to group › New group…).
  final ValueChanged<ProjectsItem> onNewGroupFor;

  /// Removes a project from the list.
  final ValueChanged<ProjectEntry> onRemove;

  /// Starts renaming the group with the given id (Rename…).
  final ValueChanged<String> onRename;

  /// Deletes the group with the given id, keeping what it holds (Delete group).
  final ValueChanged<String> onDeleteGroup;

  /// Moves a dragged row to a placement.
  final void Function(ProjectsItem item, ProjectsPlacement placement) onMoveItem;

  /// Adds folders dropped from Finder at a placement.
  final void Function(List<String> paths, ProjectsPlacement placement) onDropFolders;

  /// Whether a Finder drag hovers a row.
  final ValueChanged<bool> onDropHover;

  /// Creates the new group with the name typed.
  final ValueChanged<String> onNewGroupCommit;

  /// Drops the new group's field.
  final VoidCallback onNewGroupCancel;

  /// Renames the group (its id) to the name typed.
  final void Function(String group, String name) onRenameCommit;

  /// Ends renaming without a change.
  final VoidCallback onRenameCancel;

  /// A group row's height (Story 11.6 design note "Window").
  static const double groupHeight = 28;

  /// A project row's height.
  static const double projectHeight = 44;

  /// The name field's row: its 30 px field with 2 above and below (Claude's proposal; DS content.css:81).
  static const double newGroupHeight = 34;

  /// The gap below every row (`.zk-tree{gap:1px}`, DS ui_kits/desktop/kit.css:200).
  static const double gap = 1;

  /// The indent per level (`calc(8px + var(--depth) * 16px)`, DS components/content/content.css:67).
  static const double indent = 16;

  /// The tree's padding (`.zk-tree{padding:8px 10px 12px}`, DS ui_kits/desktop/kit.css:200).
  static const padding = EdgeInsets.fromLTRB(10, 8, 10, 12);

  /// The empty registry's sentence (Claude's proposal).
  static const emptyText = 'No projects yet. Add a directory or drop a folder here.';

  /// The ghost's hint while nothing valid is under the pointer (DS components/overlays/DragGhost.prompt.md:12).
  static const dropHint = 'Drop between rows or on a group';

  /// The ghost's words for a drop at the top level (DragGhost.prompt.md:12).
  static const topLevelWords = 'To the top level';

  /// The ghost's words for a drop into the group named [name] (DragGhost.prompt.md:12).
  static String intoWords(String name) => 'Into $name';

  /// The search's empty result (DS ui_kits/desktop/dialogs.jsx:51).
  static String noResultsText(String query) => 'No projects match “$query”';

  /// A row's height for [item].
  static double heightOf(ProjectsItem item) => switch (item) {
    ProjectsGroupItem() => groupHeight,
    ProjectsProjectItem() => projectHeight,
    ProjectsNewGroupItem() => newGroupHeight,
  };

  @override
  State<ProjectsTree> createState() => ProjectsTreeState();
}

/// Where a drag would land: on the row `id` at `placement`, the line indented to `depth`.
typedef _Hover = ({String id, TreeDropPlacement placement, int depth});

/// A drop's look and its place in the registry.
typedef _Landing = ({_Hover hover, ProjectsPlacement placement});

/// What the ghost shows: the drop's words (null: the hint), or nothing once Esc cancelled the drag.
typedef _Ghost = ({String? target, bool hidden});

/// The tree's state; [focusTabStop] moves the keyboard into the tree (↓ from the search).
class ProjectsTreeState extends State<ProjectsTree> {
  final _scroll = ScrollController();
  final _rowFocus = <String, FocusNode>{};
  final _moreFocus = <String, FocusNode>{};
  final _name = ZsTextEditingController();
  final _nameFocus = FocusNode(debugLabel: 'projects group name');
  final _ghost = ValueNotifier<_Ghost>((target: null, hidden: false));

  var _roots = const <TreeSliverNode<ProjectsItem>>[];
  var _rows = const <ProjectsRow>[];

  /// Every row the tree builds, in order: [_rows] with the new group's field in its place.
  var _slots = const <String>[];
  final _indexOf = <String, int>{};
  String? _tabStop;

  String? _lastTap;
  Timer? _tapTimer;
  var _typed = '';
  Timer? _typeTimer;
  _Hover? _hover;
  var _finderHover = false;
  String? _dragging;
  var _dragCancelled = false;
  var _keysHooked = false;

  /// Whether ↩ or Esc is closing the name field (a blur closing it leaves focus where it went).
  var _fieldKeyed = false;

  /// The row focus was handed back to; while it keeps primary focus, focus follows the selection.
  String? _following;

  /// The row a hand-back focuses without selecting it, until it arrives.
  String? _quiet;

  /// Where a row drag would land now, as the drop look shows it.
  @visibleForTesting
  ({String id, TreeDropPlacement placement, int depth})? get dropHover => _hover;

  @override
  void initState() {
    super.initState();
    _nameFocus.addListener(_nameFocusChanged);
    if (_fieldOf(widget) != null) {
      _startField();
    }
  }

  @override
  void didUpdateWidget(ProjectsTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    final Object? field = _fieldOf(widget);
    // New group taking the field from a rename keeps what was typed, as a click elsewhere does.
    final String? renamed = oldWidget.renaming;
    if (renamed != null && widget.renaming == null && widget.newGroup != null) {
      final String typed = _name.text.trim();
      if (typed.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            widget.onRenameCommit(renamed, typed);
          }
        });
      }
    }
    if (field != null && field != _fieldOf(oldWidget)) {
      _startField();
    } else if (field == null && _fieldOf(oldWidget) != null) {
      if (_fieldKeyed || _nameFocus.hasFocus) {
        _handBack();
      }
      _fieldKeyed = false;
    }
    final String? selected = widget.selected;
    final String? following = _following;
    if (following != null && selected != null && selected != oldWidget.selected && selected != following) {
      if (_rowFocus[following]?.hasPrimaryFocus ?? false) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _following == following && _indexOf.containsKey(selected)) {
            _following = selected;
            _reveal(_indexOf[selected]!);
            _focusFor(selected).requestFocus();
          }
        });
      } else {
        _following = null;
      }
    }
  }

  /// Gives focus to the row [id] (else the Tab stop) after this frame, without selecting it, and follows the selection
  /// from there. After the frame: a focused node that unmounts makes Flutter focus the scope's previously focused row
  /// in a microtask, and this request replaces that before it applies.
  void _handBack([String? id]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final String? stop = id ?? _tabStop;
      if (!mounted || stop == null || !_indexOf.containsKey(stop)) {
        return;
      }
      _reveal(_indexOf[stop]!);
      _quiet = stop;
      _following = stop;
      _focusFor(stop).requestFocus();
    });
  }

  @override
  void dispose() {
    _unhookKeys();
    _scroll.dispose();
    for (final node in <FocusNode>[..._rowFocus.values, ..._moreFocus.values]) {
      node.dispose();
    }
    _nameFocus
      ..removeListener(_nameFocusChanged)
      ..dispose();
    _name.dispose();
    _ghost.dispose();
    _tapTimer?.cancel();
    _typeTimer?.cancel();
    super.dispose();
  }

  /// Focuses the Tab stop — the selected row, else the first — which selects it.
  void focusTabStop() {
    final String? stop = _tabStop;
    if (stop != null) {
      _go(_indexOf[stop]!);
    }
  }

  /// The row's focus node; focus arriving selects the row. Only arriving: a node also notifies when its traversal
  /// changes, which must not select a focused row again after a click below the rows cleared the selection. A
  /// hand-back's arrival does not select either, nor does Flutter's fallback while a hand-back waits for its row.
  FocusNode _focusFor(String id) => _rowFocus.putIfAbsent(id, () {
    final node = FocusNode(debugLabel: 'projects row $id');
    var had = false;
    node.addListener(() {
      final bool has = node.hasPrimaryFocus;
      if (has && !had) {
        // Cleared on arrival, not before: a row not built yet takes the focus a frame later. Until then its request
        // waits unattached (no parent), and the fallback Flutter applies meanwhile is no user move.
        final String? quiet = _quiet;
        final bool waiting = _rowFocus[quiet]?.parent == null && _rowFocus.containsKey(quiet);
        if (quiet == id) {
          _quiet = null;
        } else if (!waiting) {
          _quiet = null;
          if (widget.selected != id) {
            widget.onSelect(id);
          }
        }
      }
      had = has;
    });
    return node;
  });

  FocusNode _moreFocusFor(String id) => _moreFocus.putIfAbsent(id, () => FocusNode(debugLabel: 'projects more $id'));

  /// Disposes the focus nodes of rows that left the tree, after the frame that unmounts them.
  void _prune(Set<String> ids) {
    final gone = <String>[
      for (final String id in <String>{..._rowFocus.keys, ..._moreFocus.keys})
        if (!ids.contains(id)) id,
    ];
    if (gone.isEmpty) {
      return;
    }
    final nodes = <FocusNode>[
      for (final String id in gone) ...<FocusNode?>[_rowFocus.remove(id), _moreFocus.remove(id)].nonNulls,
    ];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final node in nodes) {
        node.dispose();
      }
    });
  }

  // ---- the name field ----

  /// What the name field names: a rename (`rename:<id>`), a new group, or nothing.
  static Object? _fieldOf(ProjectsTree tree) => tree.renaming != null ? 'rename:${tree.renaming}' : tree.newGroup;

  String? _groupName(String id) {
    for (final ProjectGroup group in widget.projects.groups) {
      if (group.id == id) {
        return group.name;
      }
    }
    return null;
  }

  /// Fills the field for what it now names — a rename's name, selected; a new group's nothing — and focuses it after
  /// the frame that mounts it. The blur rule is off until then: the one field moving from one row to another must not
  /// read as focus leaving it.
  void _startField() {
    _following = null;
    final String? renaming = widget.renaming;
    final String name = renaming == null ? '' : _groupName(renaming) ?? '';
    _name.value = TextEditingValue(
      text: name,
      selection: TextSelection(baseOffset: 0, extentOffset: name.length),
    );
    _nameFocus.removeListener(_nameFocusChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _nameFocus
        ..removeListener(_nameFocusChanged)
        ..addListener(_nameFocusChanged);
      if (_fieldOf(widget) != null) {
        _nameFocus.requestFocus();
      }
    });
  }

  /// Focus leaving the field keeps a rename and cancels a new group — except while the app is not active: Flutter
  /// parks focus at the root while another app is in front and gives it back on return, so switching apps keeps the
  /// name being typed.
  void _nameFocusChanged() {
    final AppLifecycleState? lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    if (_nameFocus.hasFocus || !mounted) {
      return;
    }
    if (widget.renaming case final String id) {
      _commitRename(id, _name.text);
    } else if (widget.newGroup != null) {
      widget.onNewGroupCancel();
    }
  }

  void _commitNewGroup(String name) {
    final String trimmed = name.trim();
    _nameFocus.removeListener(_nameFocusChanged);
    if (trimmed.isEmpty) {
      widget.onNewGroupCancel();
    } else {
      widget.onNewGroupCommit(trimmed);
    }
    _nameFocus.addListener(_nameFocusChanged);
  }

  void _commitRename(String id, String name) {
    final String trimmed = name.trim();
    _nameFocus.removeListener(_nameFocusChanged);
    if (trimmed.isEmpty) {
      widget.onRenameCancel();
    } else {
      widget.onRenameCommit(id, trimmed);
    }
    _nameFocus.addListener(_nameFocusChanged);
  }

  // ---- pointer ----

  void _tapped(ProjectsItem item) {
    if (item is ProjectsGroupItem) {
      widget
        ..onSelect(item.id)
        ..onToggle(item.group.id);
      return;
    }
    final bool second = _lastTap == item.id && (_tapTimer?.isActive ?? false);
    _tapTimer?.cancel();
    if (second) {
      _lastTap = null;
      _open(item);
      return;
    }
    _lastTap = item.id;
    _tapTimer = Timer(kDoubleTapTimeout, () => _lastTap = null);
    widget.onSelect(item.id);
  }

  void _open(ProjectsItem item) {
    if (item is ProjectsProjectItem && !item.missing) {
      widget.onOpen(item.entry);
    }
  }

  // ---- keys ----

  int? get _focusedRow {
    for (final (int i, ProjectsRow row) in _rows.indexed) {
      if (_rowFocus[row.node.content.id]?.hasPrimaryFocus ?? false) {
        return i;
      }
    }
    return null;
  }

  KeyEventResult _keys(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }
    final int? current = _focusedRow;
    if (current == null) {
      return KeyEventResult.ignored;
    }
    final ProjectsRow row = _rows[current];
    final ProjectsItem item = row.node.content;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _go(current + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _go(current - 1);
    } else if (key == LogicalKeyboardKey.home) {
      _go(0);
    } else if (key == LogicalKeyboardKey.end) {
      _go(_rows.length - 1);
    } else if (key == LogicalKeyboardKey.arrowRight) {
      if (item is! ProjectsGroupItem) {
        return KeyEventResult.ignored;
      }
      if (!item.expanded) {
        widget.onToggle(item.group.id);
      } else if (row.node.children.isNotEmpty) {
        _go(current + 1);
      }
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (item is ProjectsGroupItem && item.expanded) {
        widget.onToggle(item.group.id);
      } else {
        final TreeSliverNode<ProjectsItem>? parent = row.parent;
        if (parent != null) {
          _go(_indexOf[parent.content.id]!);
        }
      }
    } else if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) {
      if (event is KeyRepeatEvent) {
        return KeyEventResult.handled;
      }
      if (item is ProjectsGroupItem) {
        widget.onToggle(item.group.id);
      } else {
        _open(item);
      }
    } else {
      return _typeahead(event, current);
    }
    return KeyEventResult.handled;
  }

  KeyEventResult _typeahead(KeyEvent event, int current) {
    final String? character = event.character;
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    // A space continues a name being typed ("my p"); it never starts one.
    if (character == null ||
        character.isEmpty ||
        (character.trim().isEmpty && (character != ' ' || _typed.isEmpty)) ||
        character.codeUnitAt(0) < 0x20 ||
        keyboard.isMetaPressed ||
        keyboard.isControlPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    _typed += character.toLowerCase();
    _typeTimer?.cancel();
    _typeTimer = Timer(ZsMotion.of(context).durTypeahead, () => _typed = '');
    // A first letter looks past the current row; more letters extend the match, which may still be the current row.
    final int start = _typed.length == 1 ? current + 1 : current;
    for (var step = 0; step < _rows.length; step++) {
      final int i = (start + step) % _rows.length;
      if (_rows[i].node.content.name.toLowerCase().startsWith(_typed)) {
        _go(i);
        break;
      }
    }
    return KeyEventResult.handled;
  }

  /// Selects the row at [index] (clamped), scrolls it into view and gives it focus.
  void _go(int index) {
    if (_rows.isEmpty) {
      return;
    }
    final int i = index.clamp(0, _rows.length - 1);
    final String id = _rows[i].node.content.id;
    _following = null;
    _quiet = null;
    widget.onSelect(id);
    _reveal(i);
    final FocusNode focus = _focusFor(id);
    if (focus.context != null) {
      focus.requestFocus();
    } else {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          focus.requestFocus();
        }
      });
    }
  }

  /// Scrolls so the row at [index] is in view.
  void _reveal(int index) {
    if (!_scroll.hasClients) {
      return;
    }
    double top = ProjectsTree.padding.top;
    for (var i = 0; i < index; i++) {
      top += _heightOf(_rows[i].node.content) + ProjectsTree.gap;
    }
    final double bottom = top + _heightOf(_rows[index].node.content);
    final ScrollPosition position = _scroll.position;
    final double viewport = position.viewportDimension;
    double? to;
    if (top - ProjectsTree.padding.top < position.pixels) {
      to = top - ProjectsTree.padding.top;
    } else if (bottom + ProjectsTree.padding.bottom > position.pixels + viewport) {
      to = bottom + ProjectsTree.padding.bottom - viewport;
    }
    if (to != null) {
      _scroll.jumpTo(to.clamp(position.minScrollExtent, position.maxScrollExtent));
    }
  }

  /// [item]'s row height: a group being renamed is its name field's row.
  double _heightOf(ProjectsItem item) => item is ProjectsGroupItem && item.group.id == widget.renaming
      ? ProjectsTree.newGroupHeight
      : ProjectsTree.heightOf(item);

  // ---- drops ----

  bool _isWithin(String? group, String ancestor) {
    final parents = <String, String?>{for (final ProjectGroup g in widget.projects.groups) g.id: g.parent};
    final visited = <String>{};
    for (var current = group; current != null && visited.add(current); current = parents[current]) {
      if (current == ancestor) {
        return true;
      }
    }
    return false;
  }

  /// Where a pointer at [dy] over [node] drops; for a dragged [row], an expanded group with children takes everything
  /// below its top quarter as inside (DS ProjectRow.prompt.md:11).
  TreeDropPlacement _placementIn(TreeSliverNode<ProjectsItem> node, double dy, {bool row = false}) {
    final ProjectsItem item = node.content;
    final double extent = _heightOf(item);
    if (row && item is ProjectsGroupItem && node.isExpanded && node.children.isNotEmpty) {
      return dy < extent / 4 ? TreeDropPlacement.before : TreeDropPlacement.inside;
    }
    return treeDropPlacement(dy: dy, rowExtent: extent, canHaveChildren: item is ProjectsGroupItem);
  }

  /// Where [moving] (null for Finder folders) would land at [placement] on [node], or null where it cannot go: onto
  /// itself, or a group into itself.
  _Landing? _landing(TreeSliverNode<ProjectsItem> node, TreeDropPlacement placement, ProjectsItem? moving) {
    if (moving != null && moving.id == node.content.id) {
      return null;
    }
    final TreeInsertionPoint<ProjectsItem> point = treeInsertionPoint(_roots, node, placement);
    final ProjectsPlacement target = registryPlacement(point, _roots, widget.projects, moving: moving);
    if (moving is ProjectsGroupItem && (target.group == moving.group.id || _isWithin(target.group, moving.group.id))) {
      return null;
    }
    return (hover: (id: node.content.id, placement: placement, depth: point.depth), placement: target);
  }

  /// The end of the top level for [moving]: last there, shown as the line under the last row at indent 0.
  _Landing _endLanding(ProjectsItem moving) => (
    hover: (
      id: _rows.isEmpty ? '' : _rows.last.node.content.id,
      placement: TreeDropPlacement.after,
      depth: 0,
    ),
    placement: (group: null, index: (registryMembers(widget.projects, null)..remove(moving.id)).length),
  );

  /// The ghost's words for a drop into [group] (the top level when null): its stored name (Design note "Ghost words").
  String _wordsFor(String? group) =>
      group == null ? ProjectsTree.topLevelWords : ProjectsTree.intoWords(_groupName(group) ?? group);

  void _showLanding(_Landing? landing, {bool finder = false}) {
    final _Hover? hover = landing?.hover;
    if (!finder && _dragging != null) {
      _ghost.value = (target: landing == null ? null : _wordsFor(landing.placement.group), hidden: _dragCancelled);
    }
    if (hover != _hover) {
      setState(() => _hover = hover);
    }
    final bool finderHover = hover != null && finder;
    if (finderHover != _finderHover) {
      _finderHover = finderHover;
      widget.onDropHover(finderHover);
    }
  }

  void _leave(String id) {
    if (_hover?.id == id) {
      _showLanding(null);
    }
  }

  double _localDy(BuildContext context, Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global).dy;

  // ---- dragging ----

  void _dragStarted(ProjectsItem item) {
    _dragCancelled = false;
    _ghost.value = (target: null, hidden: false);
    if (!_keysHooked) {
      _keysHooked = true;
      FocusManager.instance.addEarlyKeyEventHandler(_earlyKey);
      HardwareKeyboard.instance.addHandler(_hardwareKey);
    }
    setState(() => _dragging = item.id);
  }

  /// Runs from `onDragCompleted` / `onDraggableCanceled`, which fire even when the row unmounted mid-drag (unlike
  /// `onDragEnd`), so the key handlers never stay hooked.
  void _dragEnded() {
    _unhookKeys();
    if (!mounted) {
      return;
    }
    _showLanding(null);
    setState(() => _dragging = null);
  }

  void _unhookKeys() {
    if (_keysHooked) {
      _keysHooked = false;
      FocusManager.instance.removeEarlyKeyEventHandler(_earlyKey);
      HardwareKeyboard.instance.removeHandler(_hardwareKey);
    }
  }

  /// Esc during a drag cancels it (DS DragGhost.prompt.md:14): no drop look, no ghost, no drop. Flutter's `Draggable`
  /// cannot be ended from outside, so the (invisible) drag lasts until the button is released (Design note "Esc
  /// during a drag").
  bool _cancelDragOn(KeyEvent event) {
    if (_dragging == null || event is! KeyDownEvent || event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }
    setState(() => _dragCancelled = true);
    _showLanding(null);
    _ghost.value = (target: null, hidden: true);
    return true;
  }

  /// Before the focus tree, so the Esc reaches no other handler (the search's clear, a window's close).
  KeyEventResult _earlyKey(KeyEvent event) => _cancelDragOn(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// Without a primary focus the focus manager hears no key; the keyboard's own handlers still do.
  bool _hardwareKey(KeyEvent event) => FocusManager.instance.primaryFocus == null && _cancelDragOn(event);

  // ---- build ----

  /// The row whose row or ••• holds focus.
  String? get _held {
    for (final String id in _slots) {
      if ((_rowFocus[id]?.hasFocus ?? false) || (_moreFocus[id]?.hasFocus ?? false)) {
        return id;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final String? held = _held;
    final int heldSlot = held == null ? -1 : _slots.indexOf(held);
    _roots = projectsTree(
      widget.projects,
      collapsed: widget.collapsed,
      query: widget.query,
      newGroup: widget.newGroup,
    );
    final List<ProjectsRow> visible = visibleRows(_roots);
    _slots = <String>[for (final ProjectsRow row in visible) row.node.content.id];
    _rows = <ProjectsRow>[
      for (final ProjectsRow row in visible)
        if (row.node.content is! ProjectsNewGroupItem) row,
    ];
    _indexOf
      ..clear()
      ..addAll(<String, int>{for (final (int i, ProjectsRow row) in _rows.indexed) row.node.content.id: i});
    final String? selected = widget.selected;
    _tabStop = selected != null && _indexOf.containsKey(selected) ? selected : _rows.firstOrNull?.node.content.id;
    // A focused row that leaves, or moves to another slot (whose element then builds another row), loses its focus:
    // it goes back to the Tab stop, or to the row where it is now — unless a name field opening takes it.
    if (held != null && _fieldOf(widget) == null && _slots.indexOf(held) != heldSlot) {
      _handBack(_indexOf.containsKey(held) ? held : null);
    }
    _prune(_indexOf.keys.toSet());
    final ZsColors colors = ZsColors.of(context);
    final Widget body = _roots.isEmpty
        ? SliverToBoxAdapter(
            child: Padding(
              // `.zk-empty{padding:30px 16px}` (DS ui_kits/desktop/kit.css:201).
              padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 16),
              child: Text(
                widget.query.trim().isEmpty ? ProjectsTree.emptyText : ProjectsTree.noResultsText(widget.query),
                textAlign: TextAlign.center,
                style: ZsType.secondary.copyWith(fontSize: ZsType.fsMd, color: colors.textDim),
              ),
            ),
          )
        : TreeSliver<ProjectsItem>(
            tree: _roots,
            indentation: TreeSliverIndentationType.none,
            toggleAnimationStyle: AnimationStyle.noAnimation,
            treeRowExtentBuilder: (node, _) => _heightOf(node.content! as ProjectsItem) + ProjectsTree.gap,
            treeNodeBuilder: (context, node, _) => _row(node as TreeSliverNode<ProjectsItem>),
          );
    return Semantics(
      identifier: 'projects-tree',
      container: true,
      explicitChildNodes: true,
      label: 'Projects',
      child: ZsScrollArea(
        controller: _scroll,
        label: 'Projects',
        child: CustomScrollView(
          controller: _scroll,
          slivers: <Widget>[
            SliverPadding(padding: ProjectsTree.padding, sliver: body),
            SliverFillRemaining(hasScrollBody: false, child: _endTarget()),
          ],
        ),
      ),
    );
  }

  /// The empty space below the rows: a click clears the selection (Finder); a row dropped there goes last at the top
  /// level.
  Widget _endTarget() => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onTap: widget.onDeselect,
    child: DragTarget<ProjectsItem>(
      onWillAcceptWithDetails: (_) => !_dragCancelled,
      onMove: (details) {
        if (!_dragCancelled) {
          _showLanding(_endLanding(details.data));
        }
      },
      onLeave: (data) {
        if (data != null) {
          _leave(_endLanding(data).hover.id);
        }
      },
      onAcceptWithDetails: (details) {
        _showLanding(null);
        if (!_dragCancelled) {
          widget.onMoveItem(details.data, _endLanding(details.data).placement);
        }
      },
      // At least 24 high (Claude's proposal), so a list taller than the window keeps a place to drop at its end.
      builder: (context, _, _) => ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 24),
        child: const SizedBox.expand(),
      ),
    ),
  );

  Widget _row(TreeSliverNode<ProjectsItem> node) {
    final ProjectsItem item = node.content;
    final Widget content = switch (item) {
      ProjectsNewGroupItem() => _NameField(
        depth: node.depth ?? 0,
        controller: _name,
        focusNode: _nameFocus,
        label: 'New group',
        identifier: 'projects-new-group-name',
        onSubmitted: (name) {
          _fieldKeyed = true;
          _commitNewGroup(name);
        },
        onCancel: () {
          _fieldKeyed = true;
          widget.onNewGroupCancel();
        },
      ),
      ProjectsGroupItem(:final ProjectGroup group) when group.id == widget.renaming => _NameField(
        depth: node.depth ?? 0,
        controller: _name,
        focusNode: _nameFocus,
        label: 'Rename group',
        identifier: 'projects-rename-group-name',
        onSubmitted: (name) {
          _fieldKeyed = true;
          _commitRename(group.id, name);
        },
        onCancel: () {
          _fieldKeyed = true;
          widget.onRenameCancel();
        },
      ),
      _ => _itemRow(node, item),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: ProjectsTree.gap),
      child: SizedBox(height: _heightOf(item), child: content),
    );
  }

  Widget _itemRow(TreeSliverNode<ProjectsItem> node, ProjectsItem item) {
    final int index = _indexOf[item.id] ?? 0;
    final int depth = node.depth ?? 0;
    final selected = widget.selected == item.id;
    final FocusNode focus = _focusFor(item.id)..skipTraversal = item.id != _tabStop;
    final _Hover? hover = _hover?.id == item.id ? _hover : null;
    final metrics = ZsMetrics.of(context);
    final String? value = switch (item) {
      ProjectsProjectItem(:final ProjectEntry entry) => <String>[
        ?entry.status?.label,
        if (entry.path == widget.openPath) 'open',
      ].join(', '),
      ProjectsGroupItem(:final String count) => count,
      ProjectsNewGroupItem() => null,
    };
    // The keys are handled at the row, inside the ••• menu's anchor, which would take the arrow keys otherwise.
    Widget core(ZsMenuController menu, BuildContext anchor) => Focus(
      canRequestFocus: false,
      skipTraversal: true,
      includeSemantics: false,
      onKeyEvent: _keys,
      child: ZsControlCore(
        focusNode: focus,
        identifier: 'projects-row-$index',
        onActivate: () => _tapped(item),
        activateOnKeys: false,
        selected: selected,
        excludeChildSemantics: false,
        semantics: SemanticsProperties(
          label: item.name,
          value: value == null || value.isEmpty ? null : value,
          selected: selected,
          expanded: item is ProjectsGroupItem ? item.expanded : null,
        ),
        ring: ZsRingPlacement.inside,
        ringRadius: metrics.radiusMd,
        builder: (context, status) => ListenableBuilder(
          listenable: focus,
          builder: (context, _) {
            final Widget more = _MoreButton(
              focusNode: _moreFocusFor(item.id)..skipTraversal = !selected,
              identifier: 'projects-row-$index-more',
              // Keyboard focus (the ring's rule), not focus a click left behind (Ralph, 2026-10-29).
              visible: status.hovered || status.focusVisible,
              onPressed: (button) {
                widget.onSelect(item.id);
                _openMenu(button, anchor, menu);
              },
            );
            return CustomPaint(
              foregroundPainter: hover == null ? null : _DropPainter(hover, ZsColors.of(context)),
              child: switch (item) {
                ProjectsGroupItem() => _GroupFace(
                  item: item,
                  depth: depth,
                  expanded: item.expanded,
                  status: status,
                  dropInto: hover?.placement == TreeDropPlacement.inside,
                  more: more,
                ),
                ProjectsProjectItem() => _ProjectFace(
                  item: item,
                  depth: depth,
                  status: status,
                  open: item.entry.path == widget.openPath,
                  home: widget.home,
                  now: widget.now,
                  more: more,
                ),
                ProjectsNewGroupItem() => const SizedBox.shrink(),
              },
            );
          },
        ),
      ),
    );

    Widget row = ZsMenuAnchor(
      entries: _menuEntries(item),
      semanticLabel: item.name,
      identifier: 'projects-menu',
      builder: (anchor, menu) => GestureDetector(
        onSecondaryTapUp: (details) {
          widget.onSelect(item.id);
          menu.open(position: details.localPosition);
        },
        child: _draggable(item, core(menu, anchor)),
      ),
    );
    final dragged = row;
    // The row's own context places a drag over it (the tree's would measure from the tree's top).
    row = Builder(
      builder: (rowContext) => DragTarget<ProjectsItem>(
        onWillAcceptWithDetails: (details) =>
            !_dragCancelled &&
            details.data.id != item.id &&
            !(details.data is ProjectsGroupItem &&
                item is ProjectsGroupItem &&
                _isWithin(item.group.id, (details.data as ProjectsGroupItem).group.id)),
        onMove: (details) {
          if (!_dragCancelled) {
            _showLanding(
              _landing(node, _placementIn(node, _localDy(rowContext, details.offset), row: true), details.data),
            );
          }
        },
        onLeave: (_) => _leave(item.id),
        onAcceptWithDetails: (details) {
          _showLanding(null);
          if (_dragCancelled) {
            return;
          }
          final _Landing? landing = _landing(
            node,
            _placementIn(node, _localDy(rowContext, details.offset), row: true),
            details.data,
          );
          if (landing != null) {
            widget.onMoveItem(details.data, landing.placement);
          }
        },
        builder: (context, _, _) => dragged,
      ),
    );
    return FolderDropTarget(
      onDragUpdate: (details) {
        _showLanding(_landing(node, _placementIn(node, details.localPosition.dy), null), finder: true);
        return true;
      },
      onDragExit: () => _leave(item.id),
      onDrop: (details) {
        _showLanding(null);
        final _Landing? landing = _landing(node, _placementIn(node, details.localPosition.dy), null);
        if (landing != null) {
          widget.onDropFolders(details.paths, landing.placement);
        }
      },
      child: row,
    );
  }

  /// [child] as a drag source — none while searching (the results are flat) — carrying the [ZsDragGhost] 14 / 12 from
  /// the pointer (DS DragGhost.prompt.md:10). While it is dragged it shows at 40 % (DS content.css:73) — through an
  /// [Opacity] that is always there, so the row under the pointer is never rebuilt into another element mid-drag.
  Widget _draggable(ProjectsItem item, Widget child) => Draggable<ProjectsItem>(
    data: item,
    maxSimultaneousDrags: widget.query.trim().isEmpty ? null : 0,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: Padding(
      padding: const EdgeInsets.only(left: 14, top: 12),
      child: ValueListenableBuilder<_Ghost>(
        valueListenable: _ghost,
        builder: (context, ghost, _) {
          if (ghost.hidden) {
            return const SizedBox.shrink();
          }
          final String? target = ghost.target;
          return ZsDragGhost(
            kind: item is ProjectsGroupItem ? ZsDragGhostKind.group : ZsDragGhostKind.project,
            label: item.name,
            dot: item is ProjectsProjectItem ? item.entry.status?.colorIn(ZsColors.of(context)) : null,
            target: target,
            hint: target == null ? ProjectsTree.dropHint : null,
          );
        },
      ),
    ),
    onDragStarted: () => _dragStarted(item),
    onDragCompleted: _dragEnded,
    onDraggableCanceled: (_, _) => _dragEnded(),
    child: Opacity(opacity: _dragging == item.id && !_dragCancelled ? .4 : 1, child: child),
  );

  /// Opens [menu] 4 below the ••• at [button], from its left edge (Claude's proposal), in [anchor]'s coordinates.
  void _openMenu(BuildContext button, BuildContext anchor, ZsMenuController menu) {
    final RenderObject? box = button.findRenderObject();
    final RenderObject? row = anchor.findRenderObject();
    if (box is! RenderBox || row is! RenderBox) {
      return;
    }
    menu.open(position: box.localToGlobal(Offset(0, box.size.height + 4), ancestor: row));
  }

  List<ZsMenuEntry> _menuEntries(ProjectsItem item) => switch (item) {
    ProjectsProjectItem(:final ProjectEntry entry) => <ZsMenuEntry>[
      ZsMenuItem(
        label: 'Open',
        enabled: !item.missing,
        onSelected: () => widget.onOpen(entry),
        identifier: 'projects-menu-open',
      ),
      ZsMenuItem(
        label: 'Reveal in Finder',
        enabled: !item.missing,
        onSelected: () => widget.onReveal(entry),
        identifier: 'projects-menu-reveal',
      ),
      _moveTo(item, entry.group),
      const ZsMenuSeparator(),
      ZsMenuItem(
        label: 'Remove from list',
        enabled: entry.path != widget.openPath,
        onSelected: () => widget.onRemove(entry),
        identifier: 'projects-menu-remove',
      ),
    ],
    ProjectsGroupItem(:final ProjectGroup group) => <ZsMenuEntry>[
      ZsMenuItem(label: 'Rename…', onSelected: () => widget.onRename(group.id), identifier: 'projects-menu-rename'),
      _moveTo(item, group.parent),
      const ZsMenuSeparator(),
      ZsMenuItem(
        label: 'Delete group',
        onSelected: () => widget.onDeleteGroup(group.id),
        identifier: 'projects-menu-delete',
      ),
    ],
    ProjectsNewGroupItem() => const <ZsMenuEntry>[],
  };

  /// Move to group › for [item], now in [current] (the top level when null): Top level, then every group by its path,
  /// sorted, the current place checked — a group's never itself or a group inside it — then — · New group… (DS
  /// ProjectRow.prompt.md:21).
  ZsMenuItem _moveTo(ProjectsItem item, String? current) {
    final ProjectsSettings projects = widget.projects;
    final names = <String, String>{for (final ProjectGroup g in projects.groups) g.id: g.name};
    final parents = <String, String?>{for (final ProjectGroup g in projects.groups) g.id: g.parent};
    String pathOf(String id) {
      final segments = <String>[];
      final visited = <String>{};
      for (String? at = id; at != null && visited.add(at); at = parents[at]) {
        segments.insert(0, names[at] ?? at);
      }
      return segments.join(' / ');
    }

    final String? self = item is ProjectsGroupItem ? item.group.id : null;
    final groups = <(String, String)>[
      for (final ProjectGroup g in projects.groups)
        if (self == null || !_isWithin(g.id, self)) (g.id, pathOf(g.id)),
    ]..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    return ZsMenuItem(
      label: 'Move to group',
      identifier: 'projects-menu-move',
      submenu: <ZsMenuEntry>[
        ZsMenuItem(
          label: 'Top level',
          checked: current == null,
          radio: true,
          onSelected: () => widget.onMoveToGroup(item, null),
          identifier: 'projects-menu-move-top',
        ),
        for (final (String id, String label) in groups)
          ZsMenuItem(
            label: label,
            checked: current == id,
            radio: true,
            onSelected: () => widget.onMoveToGroup(item, id),
            identifier: 'projects-menu-move-$id',
          ),
        const ZsMenuSeparator(),
        ZsMenuItem(
          label: 'New group…',
          onSelected: () => widget.onNewGroupFor(item),
          identifier: 'projects-menu-move-new',
        ),
      ],
    );
  }
}

/// A row's fill in [status]: selected `--accent-soft` (pressed `--accent-soft-hi`), else hover `--fl-hover`, pressed
/// `--fl-on` (DS components/content/content.css:68-71).
Color _fill(ZsColors colors, ZsControlStatus status) {
  if (status.selected) {
    return status.pressed ? colors.accentSoftHi : colors.accentSoft;
  }
  if (status.pressed) {
    return colors.flOn;
  }
  return status.hovered ? colors.flHover : const Color(0x00000000);
}

/// The row's box: its fill fading on `--dur-hover`, radius `--radius-md`, the contrast edge when selected, and its
/// content padded 8 + 16 per level on the left and 8 on the right. A drop into it ([dropInto]) is the `--accent-soft`
/// fill with a 1 px `--accent-live-line` border (`.zs-proj.is-drop-into`, DS content.css:79).
class _RowBox extends StatelessWidget {
  const _RowBox({required this.status, required this.depth, required this.child, this.dropInto = false});

  final ZsControlStatus status;
  final int depth;
  final bool dropInto;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool edge = status.selected && ZsAppearance.of(context).increasedContrast;
    final Color? border = dropInto ? colors.accentLiveLine : (edge ? colors.accentLine : null);
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: dropInto ? colors.accentSoft : _fill(colors, status)),
      duration: status.pressed ? motion.durInstant : motion.durHover,
      curve: motion.easeState,
      builder: (context, fill, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(metrics.radiusMd),
          border: border == null ? null : Border.all(color: border),
        ),
        child: child,
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(8 + ProjectsTree.indent * depth, 0, 8, 0),
        child: child,
      ),
    );
  }
}

/// Text in [style] at [weight] on both `fontWeight` and the variable fonts' `wght` axis.
TextStyle _weighted(TextStyle style, FontWeight weight) =>
    style.copyWith(fontWeight: weight, fontVariations: <FontVariation>[FontVariation.weight(weight.value.toDouble())]);

/// The chevron box: 14 × 14, the sm chevron turning a quarter on `--dur-expand` (`--ease-glide`).
class _Chevron extends StatelessWidget {
  const _Chevron({required this.expanded});

  final bool? expanded;

  @override
  Widget build(BuildContext context) {
    final bool? open = expanded;
    if (open == null) {
      return const SizedBox.square(dimension: 14);
    }
    final ZsMotion motion = ZsMotion.of(context);
    return SizedBox.square(
      dimension: 14,
      child: AnimatedRotation(
        turns: open ? .25 : 0,
        duration: motion.durExpand,
        curve: motion.easeGlide,
        child: Center(
          child: ZanshinIcon(ZI.chevronRight, size: ZsIconSize.sm, color: ZsColors.of(context).textDim),
        ),
      ),
    );
  }
}

/// A group row's content.
class _GroupFace extends StatelessWidget {
  const _GroupFace({
    required this.item,
    required this.depth,
    required this.expanded,
    required this.status,
    required this.dropInto,
    required this.more,
  });

  final ProjectsGroupItem item;
  final int depth;
  final bool expanded;
  final ZsControlStatus status;
  final bool dropInto;
  final Widget more;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final rung = ZsTextRung.of(colors, hovered: status.hovered, raised: status.selected || status.pressed);
    return _RowBox(
      status: status,
      depth: depth,
      dropInto: dropInto,
      child: Row(
        spacing: 8,
        children: <Widget>[
          Expanded(
            child: ExcludeSemantics(
              child: Row(
                spacing: 8,
                children: <Widget>[
                  _Chevron(expanded: expanded),
                  ZanshinIcon(expanded ? ZI.folderOpen : ZI.folder, size: ZsIconSize.md, color: colors.textDim),
                  // The count sits at the row's end (`.zs-proj-count{margin-left:auto}`, DS content.css:87).
                  Expanded(
                    child: Text(
                      ZsType.caps(item.name),
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.ellipsis,
                      // `font-size:var(--fs-sm);font-weight:600;letter-spacing:var(--tracking-pill)` (DS
                      // content.css:86).
                      style: _weighted(ZsType.meta, FontWeight.w600).copyWith(
                        letterSpacing: ZsType.trackingPill * ZsType.fsSm,
                        color: colors.textMuted,
                      ),
                    ),
                  ),
                  Text(
                    item.count,
                    maxLines: 1,
                    softWrap: false,
                    style: ZsType.id.copyWith(fontSize: ZsType.fsXs, color: rung.faint),
                  ),
                ],
              ),
            ),
          ),
          more,
        ],
      ),
    );
  }
}

/// A project row's content.
class _ProjectFace extends StatelessWidget {
  const _ProjectFace({
    required this.item,
    required this.depth,
    required this.status,
    required this.open,
    required this.home,
    required this.now,
    required this.more,
  });

  final ProjectsProjectItem item;
  final int depth;
  final ZsControlStatus status;
  final bool open;
  final String home;
  final DateTime now;
  final Widget more;

  /// `.zs-proj-dot{width:7px;height:7px;margin-right:2px}` (DS components/content/content.css:88).
  static const double _dot = 7;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final rung = ZsTextRung.of(colors, hovered: status.hovered, raised: status.selected || status.pressed);
    final ProjectEntry entry = item.entry;
    final bool missing = item.missing;
    final ProjectStatus? projectStatus = entry.status;
    final DateTime? lastOpened = entry.lastOpened;
    final String? bookmark = entry.bookmark;
    final strike = TextStyle(
      decoration: missing ? TextDecoration.lineThrough : TextDecoration.none,
      decorationThickness: .5,
      decorationColor: rung.faint,
    );
    final TextStyle mono = ZsType.id.copyWith(fontSize: ZsType.fsXs);
    return _RowBox(
      status: status,
      depth: depth,
      child: Row(
        spacing: 8,
        children: <Widget>[
          const _Chevron(expanded: null),
          Padding(
            padding: const EdgeInsets.only(right: 2),
            child: projectStatus == null
                ? const SizedBox.square(dimension: _dot)
                : ZsTooltip(
                    message: projectStatus.label,
                    child: Opacity(
                      opacity: missing ? .5 : 1,
                      child: SizedBox.square(
                        dimension: _dot,
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: projectStatus.colorIn(colors), shape: BoxShape.circle),
                        ),
                      ),
                    ),
                  ),
          ),
          Expanded(
            child: ExcludeSemantics(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 1,
                children: <Widget>[
                  Row(
                    spacing: 7,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: ZsType.cardSubject.merge(strike).copyWith(color: missing ? rung.faint : colors.text),
                        ),
                      ),
                      if (open)
                        Text(
                          ZsType.caps('open'),
                          style: _weighted(ZsType.meta, FontWeight.w600).copyWith(
                            fontSize: ZsType.fs2xs,
                            letterSpacing: ZsType.trackingPill * ZsType.fs2xs,
                            color: colors.coText,
                          ),
                        ),
                      if (bookmark != null)
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          spacing: 3,
                          children: <Widget>[
                            ZanshinIcon(ZI.branch, size: ZsIconSize.xs, color: rung.dim),
                            ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 160),
                              child: Text(
                                bookmark,
                                maxLines: 1,
                                softWrap: false,
                                overflow: TextOverflow.ellipsis,
                                style: mono.copyWith(color: rung.dim),
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                  Row(
                    spacing: 5,
                    children: <Widget>[
                      Flexible(
                        child: Text(
                          displayPath(entry.path, home),
                          maxLines: 1,
                          softWrap: false,
                          overflow: TextOverflow.ellipsis,
                          style: mono.merge(strike).copyWith(color: missing ? rung.faint : rung.dim),
                        ),
                      ),
                      if (lastOpened != null) ...<Widget>[
                        Text('·', style: mono.copyWith(color: rung.faint)),
                        Text(
                          lastOpenedLabel(lastOpened, now),
                          maxLines: 1,
                          softWrap: false,
                          style: ZsType.meta.copyWith(fontSize: ZsType.fsXs, color: rung.dim),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          more,
        ],
      ),
    );
  }
}

/// The row's ••• (DS components/content/content.css:88-93): 22 × 22, radius `--radius-sm`, the md `more` glyph in
/// `--text-dim`; hover `--fl-on` and pressed `--fl-press`, both in `--text`. It shows (fading on `--dur-hover`) while
/// [visible], and always while it has focus.
class _MoreButton extends StatelessWidget {
  const _MoreButton({
    required this.focusNode,
    required this.identifier,
    required this.visible,
    required this.onPressed,
  });

  final FocusNode focusNode;
  final String identifier;
  final bool visible;

  /// Runs with the button's context, which places the menu.
  final ValueChanged<BuildContext> onPressed;

  static const double _side = 22;

  @override
  Widget build(BuildContext context) {
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    return ZsTooltip(
      message: 'More…',
      child: ZsControlCore(
        focusNode: focusNode,
        identifier: identifier,
        onActivate: () => onPressed(context),
        semantics: const SemanticsProperties(button: true, label: 'More'),
        ring: ZsRingPlacement.inside,
        ringRadius: metrics.radiusSm,
        builder: (context, status) {
          final ZsColors colors = ZsColors.of(context);
          final bool lit = status.hovered || status.pressed;
          return AnimatedOpacity(
            opacity: visible || status.focusVisible ? 1 : 0,
            duration: motion.durHover,
            curve: motion.easeState,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: status.pressed ? colors.flPress : (status.hovered ? colors.flOn : const Color(0x00000000)),
                borderRadius: BorderRadius.circular(metrics.radiusSm),
              ),
              child: SizedBox.square(
                dimension: _side,
                child: Center(
                  child: ZanshinIcon(ZI.more, size: ZsIconSize.md, color: lit ? colors.text : colors.textDim),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// The inline field naming a group — a new one, or Rename…'s in the group's own row — in the row's place (DS
/// content.css:80-82): ↩ submits, Esc cancels.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.depth,
    required this.controller,
    required this.focusNode,
    required this.label,
    required this.identifier,
    required this.onSubmitted,
    required this.onCancel,
  });

  final int depth;
  final ZsTextEditingController controller;
  final FocusNode focusNode;
  final String label;
  final String identifier;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return Padding(
      padding: EdgeInsets.fromLTRB(8 + ProjectsTree.indent * depth, 2, 8, 2),
      child: Row(
        spacing: 8,
        children: <Widget>[
          const _Chevron(expanded: null),
          ZanshinIcon(ZI.folder, size: ZsIconSize.md, color: colors.textDim),
          Expanded(
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              includeSemantics: false,
              onKeyEvent: (node, event) {
                if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape) {
                  onCancel();
                  return KeyEventResult.handled;
                }
                return KeyEventResult.ignored;
              },
              child: ZsTextField(
                controller: controller,
                focusNode: focusNode,
                placeholder: 'Group name',
                label: label,
                identifier: identifier,
                onSubmitted: onSubmitted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints the line where a drag would land before or after a row (`.zs-proj.is-drop-before/after/end::before`, DS
/// content.css:74-78): 2 px `--accent-live-line`, radius 1, from the insertion depth's indent (8 + 16 per level) to 8
/// from the right, 2 above the row (before) or 2 below it (after, end). A drop into a group is its row box's look.
class _DropPainter extends CustomPainter {
  _DropPainter(this.hover, this.colors);

  final _Hover hover;
  final ZsColors colors;

  static const double _line = 2;

  @override
  void paint(Canvas canvas, Size size) {
    if (hover.placement == TreeDropPlacement.inside) {
      return;
    }
    final double left = 8 + ProjectsTree.indent * hover.depth;
    final double top = hover.placement == TreeDropPlacement.before ? -_line : size.height;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTRB(left, top, size.width - 8, top + _line), const Radius.circular(1)),
      Paint()..color = colors.accentLiveLine,
    );
  }

  @override
  bool shouldRepaint(_DropPainter oldDelegate) => oldDelegate.hover != hover || oldDelegate.colors != colors;
}
