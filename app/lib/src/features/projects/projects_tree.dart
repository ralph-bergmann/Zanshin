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

/// The Projects window's tree (epics.md Story 11.6 item 4 and design update item 4; DS
/// components/content/ProjectRow.{jsx,prompt.md}; content.css:66-95), over [projects] as [projectsTree] projects it.
///
/// **Rows.** 28 high for a group, 44 for a project, 1 apart, indented 16 per level from 8; radius `--radius-md`. A group
/// shows the chevron (sm in a 14 box, turning on `--dur-expand`), the folder (open while expanded), its name in caps
/// (`--fs-sm` 600, tracked .08em, `--text-muted`) and the count mono `--fs-xs` `--text-faint`. A project shows its 7 px
/// status dot (none before its first reading; Claude's proposal), its name (13/500), the saffron caps OPEN on the open
/// project, its bookmark label (mono `--fs-xs` `--text-dim` after the xs `branch` glyph, ProjectRow.jsx:66; none
/// without one), then its path with `~` and when it was last opened, and the 22 px ••• that shows on hover and with focus inside the row. A missing
/// project strikes its name and path through in `--text-faint`, its dot at half.
///
/// **States.** Hover `--fl-hover`, pressed `--fl-on`; selected `--accent-soft` (also on hover), pressed
/// `--accent-soft-hi`; secondary text takes the next rung on a fill; under increased contrast a selected row has a 1 px
/// `--accent-line` edge inside (DS tokens/contrast.css:26). A click selects (a group also toggles); a double-click
/// opens a project; a right-click opens the ••• menu at the pointer: Open, Reveal in Finder, Move to group › and
/// Remove from list (Claude's proposal), Open and Reveal disabled for a missing project, Remove for the open one.
///
/// **Keys** (decision 16.43; DS ProjectRow.prompt.md:11): one Tab stop — the selected row, else the first; focus that
/// arrives selects its row. ↑ ↓ Home End move and select, → expands a group or steps into it, ← collapses one or steps
/// to the parent, ↩ opens a project (a group toggles), typing selects the next row whose name starts with the letters
/// typed within `--dur-typeahead`. Tab from the selected row reaches its ••• and no other.
///
/// **Drops.** A row dragged onto another row, or a Finder folder dragged over one, lands where `tree_drop.dart` places
/// it — a group's middle half is inside it — shown as a 1 px `--accent-live-line` edge with the 4 px
/// `--accent-live-ring` around the row, or a 2 px `--accent-live-line` line on its edge indented to the insertion
/// depth (the live copies: a Finder drop lands in a window that is not key). A group never moves into itself.
///
/// VoiceOver: a region "Projects"; each row a node named by its name, its value the dot's label (and "open"), with its
/// selected and expanded state. Identifiers: `projects-tree`, `projects-row-<i>`, `projects-row-<i>-more` in visible
/// order, `projects-menu`, `projects-new-group-name`.
class ProjectsTree extends StatefulWidget {
  /// The tree of [projects].
  const ProjectsTree({
    required this.projects,
    required this.home,
    required this.now,
    required this.onSelect,
    required this.onToggle,
    required this.onOpen,
    required this.onReveal,
    required this.onMoveToGroup,
    required this.onRemove,
    required this.onMoveItem,
    required this.onDropFolders,
    required this.onDropHover,
    required this.onNewGroupCommit,
    required this.onNewGroupCancel,
    this.openPath,
    this.query = '',
    this.collapsed = const <String>{},
    this.selected,
    this.newGroup,
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

  /// The home folder paths abbreviate to `~`.
  final String home;

  /// The time last-opened labels count from.
  final DateTime now;

  /// Selects the row with the given id.
  final ValueChanged<String> onSelect;

  /// Expands or collapses the group with the given id.
  final ValueChanged<String> onToggle;

  /// Opens a project (↩, a double-click, Open).
  final ValueChanged<ProjectEntry> onOpen;

  /// Reveals a project in Finder.
  final ValueChanged<ProjectEntry> onReveal;

  /// Moves a project into a group (null: the top level), last there.
  final void Function(ProjectEntry project, String? group) onMoveToGroup;

  /// Removes a project from the list.
  final ValueChanged<ProjectEntry> onRemove;

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

  /// A group row's height (Story 11.6 design note "Window").
  static const double groupHeight = 28;

  /// A project row's height.
  static const double projectHeight = 44;

  /// The new group's row: its 30 px field with 2 above and below (Claude's proposal).
  static const double newGroupHeight = 34;

  /// The gap below every row (`.zk-tree{gap:1px}`, DS ui_kits/desktop/kit.css:200).
  static const double gap = 1;

  /// The indent per level (`calc(8px + var(--depth) * 16px)`, DS components/content/content.css:67).
  static const double indent = 16;

  /// The tree's padding (`.zk-tree{padding:8px 10px 12px}`, DS ui_kits/desktop/kit.css:200).
  static const padding = EdgeInsets.fromLTRB(10, 8, 10, 12);

  /// The empty registry's sentence (Claude's proposal).
  static const emptyText = 'No projects yet. Add a directory or drop a folder here.';

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

/// The tree's state; [focusTabStop] moves the keyboard into the tree (↓ from the search).
class ProjectsTreeState extends State<ProjectsTree> {
  final _scroll = ScrollController();
  final _rowFocus = <String, FocusNode>{};
  final _moreFocus = <String, FocusNode>{};
  final _newGroupName = ZsTextEditingController();
  final _newGroupFocus = FocusNode(debugLabel: 'projects new group');

  var _roots = const <TreeSliverNode<ProjectsItem>>[];
  var _rows = const <ProjectsRow>[];
  final _indexOf = <String, int>{};
  String? _tabStop;

  String? _lastTap;
  Timer? _tapTimer;
  var _typed = '';
  Timer? _typeTimer;
  _Hover? _hover;
  var _finderHover = false;
  String? _dragging;

  @override
  void initState() {
    super.initState();
    _newGroupFocus.addListener(_newGroupFocusChanged);
  }

  @override
  void didUpdateWidget(ProjectsTree oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.newGroup == null && widget.newGroup != null) {
      _newGroupName.clear();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && widget.newGroup != null) {
          _newGroupFocus.requestFocus();
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    for (final node in <FocusNode>[..._rowFocus.values, ..._moreFocus.values]) {
      node.dispose();
    }
    _newGroupFocus
      ..removeListener(_newGroupFocusChanged)
      ..dispose();
    _newGroupName.dispose();
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

  FocusNode _focusFor(String id) => _rowFocus.putIfAbsent(id, () {
    final node = FocusNode(debugLabel: 'projects row $id');
    node.addListener(() {
      if (node.hasPrimaryFocus && widget.selected != id) {
        widget.onSelect(id);
      }
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

  /// Focus leaving the field cancels it — except while the app is not active: Flutter parks focus at the root while
  /// another app is in front and gives it back on return, so switching apps keeps the name being typed.
  void _newGroupFocusChanged() {
    final AppLifecycleState? lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    if (!_newGroupFocus.hasFocus && widget.newGroup != null && mounted) {
      widget.onNewGroupCancel();
    }
  }

  void _commitNewGroup(String name) {
    final String trimmed = name.trim();
    _newGroupFocus.removeListener(_newGroupFocusChanged);
    if (trimmed.isEmpty) {
      widget.onNewGroupCancel();
    } else {
      widget.onNewGroupCommit(trimmed);
    }
    _newGroupFocus.addListener(_newGroupFocusChanged);
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
      if (row.node.isExpanded) {
        _go(current + 1);
      } else {
        widget.onToggle(item.group.id);
      }
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      if (item is ProjectsGroupItem && row.node.isExpanded) {
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
      top += ProjectsTree.heightOf(_rows[i].node.content) + ProjectsTree.gap;
    }
    final double bottom = top + ProjectsTree.heightOf(_rows[index].node.content);
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

  TreeDropPlacement _placementIn(ProjectsItem item, double dy) => treeDropPlacement(
    dy: dy,
    rowExtent: ProjectsTree.heightOf(item),
    canHaveChildren: item is ProjectsGroupItem,
  );

  /// Where [moving] (null for Finder folders) would land at [placement] on [node], or null where it cannot go: onto
  /// itself, or a group into itself.
  ({_Hover hover, ProjectsPlacement placement})? _landing(
    TreeSliverNode<ProjectsItem> node,
    TreeDropPlacement placement,
    ProjectsItem? moving,
  ) {
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

  void _showHover(_Hover? hover, {bool finder = false}) {
    final bool finderHover = hover != null && finder;
    if (hover != _hover) {
      setState(() => _hover = hover);
    }
    if (finderHover != _finderHover) {
      _finderHover = finderHover;
      widget.onDropHover(finderHover);
    }
  }

  void _leave(String id) {
    if (_hover?.id == id) {
      _showHover(null);
    }
  }

  double _localDy(BuildContext context, Offset global) =>
      (context.findRenderObject()! as RenderBox).globalToLocal(global).dy;

  // ---- build ----

  @override
  Widget build(BuildContext context) {
    _roots = projectsTree(
      widget.projects,
      collapsed: widget.collapsed,
      query: widget.query,
      newGroup: widget.newGroup,
    );
    _rows = <ProjectsRow>[
      for (final ProjectsRow row in visibleRows(_roots))
        if (row.node.content is! ProjectsNewGroupItem) row,
    ];
    _indexOf
      ..clear()
      ..addAll(<String, int>{for (final (int i, ProjectsRow row) in _rows.indexed) row.node.content.id: i});
    final String? selected = widget.selected;
    _tabStop = selected != null && _indexOf.containsKey(selected) ? selected : _rows.firstOrNull?.node.content.id;
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
            treeRowExtentBuilder: (node, _) => ProjectsTree.heightOf(node.content! as ProjectsItem) + ProjectsTree.gap,
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

  /// The empty space below the rows: a row dropped there goes last at the top level.
  Widget _endTarget() => DragTarget<ProjectsItem>(
    onAcceptWithDetails: (details) => widget.onMoveItem(details.data, (
      group: null,
      index: (registryMembers(widget.projects, null)..remove(details.data.id)).length,
    )),
    // At least 24 high (Claude's proposal), so a list taller than the window keeps a place to drop at its end.
    builder: (context, _, _) => ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 24),
      child: const SizedBox.expand(),
    ),
  );

  Widget _row(TreeSliverNode<ProjectsItem> node) {
    final ProjectsItem item = node.content;
    final Widget content = switch (item) {
      ProjectsNewGroupItem() => _NewGroupField(
        depth: node.depth ?? 0,
        controller: _newGroupName,
        focusNode: _newGroupFocus,
        onSubmitted: _commitNewGroup,
        onCancel: widget.onNewGroupCancel,
      ),
      _ => _itemRow(node, item),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: ProjectsTree.gap),
      child: SizedBox(height: ProjectsTree.heightOf(item), child: content),
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
    Widget core(ZsMenuController? menu, BuildContext? anchor) => Focus(
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
          expanded: item is ProjectsGroupItem ? node.isExpanded : null,
        ),
        ring: ZsRingPlacement.inside,
        ringRadius: metrics.radiusMd,
        builder: (context, status) => ListenableBuilder(
          listenable: focus,
          builder: (context, _) => CustomPaint(
            foregroundPainter: hover == null ? null : _DropPainter(hover, ZsColors.of(context), metrics.radiusMd),
            child: switch (item) {
              ProjectsGroupItem() => _GroupFace(item: item, depth: depth, expanded: node.isExpanded, status: status),
              ProjectsProjectItem() => _ProjectFace(
                item: item,
                depth: depth,
                status: status,
                open: item.entry.path == widget.openPath,
                home: widget.home,
                now: widget.now,
                more: _MoreButton(
                  focusNode: _moreFocusFor(item.id)..skipTraversal = !selected,
                  identifier: 'projects-row-$index-more',
                  visible: status.hovered || focus.hasFocus,
                  onPressed: (button) => _openMenu(button, anchor, menu),
                ),
              ),
              ProjectsNewGroupItem() => const SizedBox.shrink(),
            },
          ),
        ),
      ),
    );

    Widget row;
    if (item is ProjectsProjectItem) {
      row = ZsMenuAnchor(
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
    } else {
      row = _draggable(item, core(null, null));
    }
    final dragged = row;
    // The row's own context places a drag over it (the tree's would measure from the tree's top).
    row = Builder(
      builder: (rowContext) => DragTarget<ProjectsItem>(
        onWillAcceptWithDetails: (details) =>
            details.data.id != item.id &&
            !(details.data is ProjectsGroupItem &&
                item is ProjectsGroupItem &&
                _isWithin(item.group.id, (details.data as ProjectsGroupItem).group.id)),
        onMove: (details) => _showHover(
          _landing(node, _placementIn(item, _localDy(rowContext, details.offset)), details.data)?.hover,
        ),
        onLeave: (_) => _leave(item.id),
        onAcceptWithDetails: (details) {
          _showHover(null);
          final ({_Hover hover, ProjectsPlacement placement})? landing = _landing(
            node,
            _placementIn(item, _localDy(rowContext, details.offset)),
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
        _showHover(_landing(node, _placementIn(item, details.localPosition.dy), null)?.hover, finder: true);
        return true;
      },
      onDragExit: () => _leave(item.id),
      onDrop: (details) {
        _showHover(null);
        final ({_Hover hover, ProjectsPlacement placement})? landing = _landing(
          node,
          _placementIn(item, details.localPosition.dy),
          null,
        );
        if (landing != null) {
          widget.onDropFolders(details.paths, landing.placement);
        }
      },
      child: row,
    );
  }

  /// [child] as a drag source; while it is dragged it shows at half opacity (Claude's proposal) — through an [Opacity]
  /// that is always there, so the row under the pointer is never rebuilt into another element mid-drag.
  Widget _draggable(ProjectsItem item, Widget child) => Draggable<ProjectsItem>(
    data: item,
    dragAnchorStrategy: pointerDragAnchorStrategy,
    feedback: _DragFeedback(name: item.name),
    onDragStarted: () => setState(() => _dragging = item.id),
    onDragEnd: (_) {
      _showHover(null);
      if (mounted) {
        setState(() => _dragging = null);
      }
    },
    child: Opacity(opacity: _dragging == item.id ? .5 : 1, child: child),
  );

  /// Opens [menu] 4 below the ••• at [button], from its left edge (Claude's proposal), in [anchor]'s coordinates.
  void _openMenu(BuildContext button, BuildContext? anchor, ZsMenuController? menu) {
    final RenderObject? box = button.findRenderObject();
    final RenderObject? row = anchor?.findRenderObject();
    if (menu == null || box is! RenderBox || row is! RenderBox) {
      return;
    }
    menu.open(position: box.localToGlobal(Offset(0, box.size.height + 4), ancestor: row));
  }

  List<ZsMenuEntry> _menuEntries(ProjectsProjectItem item) {
    final ProjectEntry entry = item.entry;
    final ProjectsSettings projects = widget.projects;
    final names = <String, String>{for (final ProjectGroup g in projects.groups) g.id: g.name};
    final parents = <String, String?>{for (final ProjectGroup g in projects.groups) g.id: g.parent};
    String pathOf(String id) {
      final segments = <String>[];
      final visited = <String>{};
      for (String? current = id; current != null && visited.add(current); current = parents[current]) {
        segments.insert(0, names[current] ?? current);
      }
      return segments.join(' / ');
    }

    final groups = <(String, String)>[for (final ProjectGroup g in projects.groups) (g.id, pathOf(g.id))]
      ..sort((a, b) => a.$2.toLowerCase().compareTo(b.$2.toLowerCase()));
    return <ZsMenuEntry>[
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
      ZsMenuItem(
        label: 'Move to group',
        identifier: 'projects-menu-move',
        submenu: <ZsMenuEntry>[
          ZsMenuItem(
            label: 'Top level',
            checked: entry.group == null,
            radio: true,
            onSelected: () => widget.onMoveToGroup(entry, null),
            identifier: 'projects-menu-move-top',
          ),
          for (final (String id, String label) in groups)
            ZsMenuItem(
              label: label,
              checked: entry.group == id,
              radio: true,
              onSelected: () => widget.onMoveToGroup(entry, id),
              identifier: 'projects-menu-move-$id',
            ),
        ],
      ),
      const ZsMenuSeparator(),
      ZsMenuItem(
        label: 'Remove from list',
        enabled: entry.path != widget.openPath,
        onSelected: () => widget.onRemove(entry),
        identifier: 'projects-menu-remove',
      ),
    ];
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
/// content padded 8 + 16 per level on the left and 8 on the right.
class _RowBox extends StatelessWidget {
  const _RowBox({required this.status, required this.depth, required this.child});

  final ZsControlStatus status;
  final int depth;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final metrics = ZsMetrics.of(context);
    final ZsMotion motion = ZsMotion.of(context);
    final bool edge = status.selected && ZsAppearance.of(context).increasedContrast;
    return TweenAnimationBuilder<Color?>(
      tween: ColorTween(end: _fill(colors, status)),
      duration: status.pressed ? motion.durInstant : motion.durHover,
      curve: motion.easeState,
      builder: (context, fill, child) => DecoratedBox(
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(metrics.radiusMd),
          border: edge ? Border.all(color: colors.accentLine) : null,
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
  const _GroupFace({required this.item, required this.depth, required this.expanded, required this.status});

  final ProjectsGroupItem item;
  final int depth;
  final bool expanded;
  final ZsControlStatus status;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final rung = ZsTextRung.of(colors, hovered: status.hovered, raised: status.selected || status.pressed);
    return _RowBox(
      status: status,
      depth: depth,
      child: ExcludeSemantics(
        child: Row(
          spacing: 8,
          children: <Widget>[
            _Chevron(expanded: expanded),
            ZanshinIcon(expanded ? ZI.folderOpen : ZI.folder, size: ZsIconSize.md, color: colors.textDim),
            // The count sits at the row's end (`.zs-proj-count{margin-left:auto}`, DS content.css:74).
            Expanded(
              child: Text(
                ZsType.caps(item.name),
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                // `font-size:var(--fs-sm);font-weight:600;letter-spacing:var(--tracking-pill)` (DS content.css:73).
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

  /// `.zs-proj-dot{width:7px;height:7px;margin-right:2px}` (DS components/content/content.css:76).
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
            opacity: visible || status.focusVisible || focusNode.hasFocus ? 1 : 0,
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

/// The inline field naming a new group: in the row's place, ↩ creates the group, Esc cancels.
class _NewGroupField extends StatelessWidget {
  const _NewGroupField({
    required this.depth,
    required this.controller,
    required this.focusNode,
    required this.onSubmitted,
    required this.onCancel,
  });

  final int depth;
  final ZsTextEditingController controller;
  final FocusNode focusNode;
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
                label: 'New group',
                identifier: 'projects-new-group-name',
                onSubmitted: onSubmitted,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// What follows the pointer while a row is dragged: its name on the menu material (Claude's proposal).
class _DragFeedback extends StatelessWidget {
  const _DragFeedback({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return IgnorePointer(
      child: ZsMenuMaterial(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Text(name, style: ZsType.cardSubject.copyWith(color: colors.text)),
        ),
      ),
    );
  }
}

/// Paints where a drag would land on a row (Story 11.6 design note "Window"): inside — a 1 px `--accent-live-line`
/// edge with a 4 px `--accent-live-ring` around it; before or after — a 2 px `--accent-live-line` line on the row's
/// edge, from the insertion depth's indent.
class _DropPainter extends CustomPainter {
  _DropPainter(this.hover, this.colors, this.radius);

  final _Hover hover;
  final ZsColors colors;
  final double radius;

  static const double _ring = 4;
  static const double _line = 2;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect box = Offset.zero & size;
    if (hover.placement == TreeDropPlacement.inside) {
      final rrect = RRect.fromRectAndRadius(box, Radius.circular(radius));
      canvas
        ..drawDRRect(rrect.inflate(_ring), rrect, Paint()..color = colors.accentLiveRing)
        ..drawDRRect(rrect, rrect.deflate(1), Paint()..color = colors.accentLiveLine);
      return;
    }
    final double left = 8 + ProjectsTree.indent * hover.depth;
    final double top = hover.placement == TreeDropPlacement.before ? 0 : size.height - _line;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(left, top, size.width - left, _line), const Radius.circular(_line / 2)),
      Paint()..color = colors.accentLiveLine,
    );
  }

  @override
  bool shouldRepaint(_DropPainter oldDelegate) =>
      oldDelegate.hover != hover || oldDelegate.colors != colors || oldDelegate.radius != radius;
}
