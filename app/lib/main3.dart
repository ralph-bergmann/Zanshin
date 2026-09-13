// SPDX-License-Identifier: MIT

// Folder drop proof of concept: drag folders from Finder into a TreeSliver and
// drop them before, into or after a row. The drop plumbing is production code
// in the zanshin_shell plugin (FolderDropTarget); the placement logic lives in
// src/features/projects/tree_drop.dart. Not wired into the real boot.
//
//   flutter run -d macos -t lib/main3.dart      (from `app/`)
//
// The windowing API is experimental and only reachable through implementation
// imports; see https://github.com/flutter/flutter/issues/30701.
// ignore_for_file: invalid_use_of_internal_member, implementation_imports

import 'dart:async';

import 'package:flutter/rendering.dart' show TreeSliverIndentationType;
import 'package:flutter/src/widgets/_window.dart';
import 'package:material_ui/material_ui.dart';
import 'package:yaru/yaru.dart';
import 'package:zanshin_shell/zanshin_shell.dart';

import 'src/features/projects/tree_drop.dart';
import 'src/features/window/app_windows.dart';

/// Content size of every demo window.
const _windowSize = Size(900, 640);

/// Height of a tree row.
const double _rowExtent = 32;

/// Horizontal indent per tree level.
const double _indent = 20;

/// Whether a drop skips folders that are already in the tree. With `false`
/// the same folder can be added any number of times.
const _skipListedFolders = true;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final windows = _DemoWindows(AppWindows());
  // The first window has to be part of the warm-up frame (see
  // AppWindows.create); later ones go through the registry its build attaches.
  runWidget(WindowManager(initialWindows: <WindowEntry>[await windows.createFirst()]));
}

/// Opens the numbered demo windows; each gets its own key and its own tree.
class _DemoWindows {
  _DemoWindows(this._windows);

  final AppWindows _windows;
  var _opened = 0;

  /// Creates the first window, before `runWidget`.
  Future<WindowEntry> createFirst() {
    final int number = ++_opened;
    return _windows.create(key: _key(number), title: _title(number), size: _windowSize, builder: _builder(number));
  }

  /// Opens one more window through the registry.
  Future<void> openAnother() {
    final int number = ++_opened;
    return _windows.openOrActivate(
      key: _key(number),
      title: _title(number),
      size: _windowSize,
      builder: _builder(number),
    );
  }

  WidgetBuilder _builder(int number) =>
      (_) => _DemoApp(number: number, windows: this);

  static String _key(int number) => 'folder-drop-$number';

  static String _title(int number) => 'Folder drop POC $number';
}

class _DemoApp extends StatelessWidget {
  const _DemoApp({required this.number, required this.windows});

  final int number;
  final _DemoWindows windows;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Folder drop POC',
    debugShowCheckedModeBanner: false,
    theme: yaruLight,
    darkTheme: yaruDark,
    home: _FolderTreePage(number: number, onNewWindow: windows.openAnother),
  );
}

/// A tree entry: a group of projects, or a project folder.
sealed class _Entry {
  _Entry(this.name);

  final String name;
}

class _Group extends _Entry {
  _Group(super.name);
}

class _Project extends _Entry {
  _Project(this.path) : super(_folderName(path));

  final String path;
}

String _folderName(String path) => path.split('/').lastWhere((part) => part.isNotEmpty, orElse: () => path);

/// What a drag points at: a row with a placement, or the end of the list
/// (`node` and `placement` null).
typedef _Hover = ({
  TreeSliverNode<_Entry>? node,
  TreeDropPlacement? placement,
  TreeInsertionPoint<_Entry> point,
  int count,
});

class _FolderTreePage extends StatefulWidget {
  const _FolderTreePage({required this.number, required this.onNewWindow});

  final int number;
  final Future<void> Function() onNewWindow;

  @override
  State<_FolderTreePage> createState() => _FolderTreePageState();
}

class _FolderTreePageState extends State<_FolderTreePage> {
  final _controller = TreeSliverController();
  final List<TreeSliverNode<_Entry>> _tree = [
    TreeSliverNode(
      _Group('Work'),
      expanded: true,
      children: [TreeSliverNode(_Project('~/work/api-gateway')), TreeSliverNode(_Project('~/work/dashboard'))],
    ),
    TreeSliverNode(_Group('Private'), expanded: true, children: [TreeSliverNode(_Project('~/projects/zanshin'))]),
    TreeSliverNode(_Group('Archive')),
  ];
  _Hover? _hover;
  var _status = 'Drag folders from Finder onto the tree.';

  @override
  Widget build(BuildContext context) {
    final _Hover? hover = _hover;
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 52,
            child: Row(
              children: [
                Expanded(
                  child: WindowDragArea(
                    child: Padding(
                      // Leaves room for the traffic lights.
                      padding: const EdgeInsets.only(left: 84),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          'Folder drop POC · window ${widget.number}',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: OutlinedButton.icon(
                    onPressed: () => unawaited(widget.onNewWindow()),
                    icon: const Icon(Icons.add),
                    label: const Text('New window'),
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: FolderDropTarget(
              onDragUpdate: _hoverEnd,
              onDragExit: () => _leave(null),
              onDrop: _dropAtEnd,
              child: CustomScrollView(
                slivers: [
                  TreeSliver<_Entry>(
                    tree: _tree,
                    controller: _controller,
                    indentation: TreeSliverIndentationType.none,
                    treeRowExtentBuilder: (_, _) => _rowExtent,
                    treeNodeBuilder: (context, node, _) => _buildRow(context, node as TreeSliverNode<_Entry>),
                  ),
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EndOfList(active: hover != null && hover.node == null),
                  ),
                ],
              ),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Text(hover == null ? _status : _describe(hover)),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(BuildContext context, TreeSliverNode<_Entry> entry) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    final _Hover? hover = _hover;
    final TreeDropPlacement? placement = hover != null && identical(hover.node, entry) ? hover.placement : null;
    return FolderDropTarget(
      onDragUpdate: (details) => _hoverRow(entry, details),
      onDragExit: () => _leave(entry),
      onDrop: (details) => _dropOnRow(entry, details),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => _controller.toggleNode(entry),
        child: CustomPaint(
          foregroundPainter: hover == null || placement == null || placement == TreeDropPlacement.inside
              ? null
              : _InsertionLinePainter(
                  atTop: placement == TreeDropPlacement.before,
                  depth: hover.point.depth,
                  color: colors.primary,
                ),
          child: ColoredBox(
            color: placement == TreeDropPlacement.inside ? colors.primary.withValues(alpha: 0.16) : Colors.transparent,
            child: Padding(
              padding: EdgeInsets.only(left: 12 + (entry.depth ?? 0) * _indent, right: 12),
              child: Row(
                spacing: 8,
                children: [
                  Icon(_iconFor(entry), size: 18, color: colors.onSurfaceVariant),
                  Text(entry.content.name),
                  if (entry.content case _Project(:final path))
                    Expanded(
                      child: Text(
                        path,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    )
                  else if (entry.children.isEmpty)
                    Text('empty', style: TextStyle(color: colors.onSurfaceVariant)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  bool _hoverRow(TreeSliverNode<_Entry> entry, FolderDragDetails details) {
    final TreeDropPlacement placement = _placementIn(entry, details);
    _showHover((
      node: entry,
      placement: placement,
      point: treeInsertionPoint(_tree, entry, placement),
      count: details.paths.length,
    ));
    return true;
  }

  bool _hoverEnd(FolderDragDetails details) {
    _showHover((node: null, placement: null, point: treeAppendPoint(_tree), count: details.paths.length));
    return true;
  }

  /// Clears the hover state if it still belongs to [node] (`null`: the end of
  /// the list).
  void _leave(TreeSliverNode<_Entry>? node) {
    final _Hover? hover = _hover;
    if (hover != null && identical(hover.node, node)) {
      _showHover(null);
    }
  }

  void _showHover(_Hover? hover) {
    if (hover != _hover) {
      setState(() => _hover = hover);
    }
  }

  void _dropOnRow(TreeSliverNode<_Entry> entry, FolderDragDetails details) =>
      _insert(details.paths, treeInsertionPoint(_tree, entry, _placementIn(entry, details)));

  void _dropAtEnd(FolderDragDetails details) => _insert(details.paths, treeAppendPoint(_tree));

  TreeDropPlacement _placementIn(TreeSliverNode<_Entry> entry, FolderDragDetails details) => treeDropPlacement(
    dy: details.localPosition.dy,
    rowExtent: _rowExtent,
    canHaveChildren: entry.content is _Group,
  );

  /// Adds the dropped folders at [point]; with [_skipListedFolders], folders
  /// already in the tree are skipped.
  void _insert(List<String> paths, TreeInsertionPoint<_Entry> point) {
    final Set<String> listed = _projectPaths(_tree).toSet();
    final List<String> added = [
      for (final path in paths)
        if (!_skipListedFolders || listed.add(path)) path,
    ];
    final TreeSliverNode<_Entry>? parent = point.parent;
    setState(() {
      _hover = null;
      insertTreeNodes(_tree, point, [for (final path in added) TreeSliverNode<_Entry>(_Project(path))]);
      _status = [
        'Added ${added.length} to ${parent == null ? 'the top level' : "'${parent.content.name}'"}',
        if (added.length < paths.length) '${paths.length - added.length} already listed',
      ].join(' · ');
    });
    // A group that just got its first child cannot have been expanded yet.
    if (parent != null && added.isNotEmpty && !parent.isExpanded) {
      _controller.expandNode(parent);
    }
  }
}

IconData _iconFor(TreeSliverNode<_Entry> entry) => switch (entry.content) {
  _Group() => entry.isExpanded ? Icons.folder_open : Icons.folder,
  _Project() => Icons.source,
};

/// The paths of all projects in [nodes], at any depth.
Iterable<String> _projectPaths(List<TreeSliverNode<_Entry>> nodes) sync* {
  for (final node in nodes) {
    if (node.content case _Project(:final path)) {
      yield path;
    }
    yield* _projectPaths(node.children);
  }
}

/// The live status line while a drag is over the tree.
String _describe(_Hover hover) {
  final folders = hover.count == 1 ? '1 folder' : '${hover.count} folders';
  final TreeSliverNode<_Entry>? node = hover.node;
  if (node == null) {
    return '$folders · at the end';
  }
  final name = "'${node.content.name}'";
  return switch (hover.placement) {
    TreeDropPlacement.before => '$folders · before $name',
    TreeDropPlacement.inside => '$folders · into $name',
    TreeDropPlacement.after when identical(hover.point.parent, node) => '$folders · first in $name',
    TreeDropPlacement.after || null => '$folders · after $name',
  };
}

/// The empty area below the tree, which adds dropped folders at the end.
class _EndOfList extends StatelessWidget {
  const _EndOfList({required this.active});

  final bool active;

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: active ? colors.primary.withValues(alpha: 0.08) : Colors.transparent,
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            active ? 'Drop to add at the end' : 'Drop folders here to add them at the end',
            style: TextStyle(color: colors.onSurfaceVariant),
          ),
        ),
      ),
    );
  }
}

/// Paints a before/after insertion line: 2 px on the row's top or bottom edge,
/// indented to [depth], with a dot where it starts.
class _InsertionLinePainter extends CustomPainter {
  const _InsertionLinePainter({required this.atTop, required this.depth, required this.color});

  final bool atTop;
  final int depth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final double y = atTop ? 1 : size.height - 1;
    final double x = 12 + depth * _indent;
    final paint = Paint()
      ..color = color
      ..strokeWidth = 2;
    canvas
      ..drawLine(Offset(x + 3, y), Offset(size.width - 12, y), paint)
      ..drawCircle(Offset(x, y), 3, paint);
  }

  @override
  bool shouldRepaint(_InsertionLinePainter oldDelegate) =>
      oldDelegate.atTop != atTop || oldDelegate.depth != depth || oldDelegate.color != color;
}
