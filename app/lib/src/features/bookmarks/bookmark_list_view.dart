// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show LocalBookmark, RemoteBookmark, ZanshinFfiException;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_card_menu.dart' show GraphNameRequest, GraphNameSheet;
import '../graph/graph_drag.dart';
import '../graph/graph_ports.dart';
import '../graph/project_files.dart' show announceCopied;
import '../shell/shell_controller.dart';
import '../shell/shell_scope.dart';
import 'bookmark_list_model.dart';

/// The Bookmarks rail item's id.
const bookmarksRailId = 'bookmarks';

/// The Tags rail item's id (Story 10.44).
const tagsRailId = 'tags';

/// The jj command the empty list names (decision 16.44).
const _createCommand = 'jj bookmark create <name>'; // l10n-ignore: jj command

/// The jj command the empty tag list names.
const _createTagCommand = 'jj tag set <name>'; // l10n-ignore: jj command

const _noDescription = '(no description set)'; // l10n-ignore: jj's text

/// The rail's "Bookmarks" item (Story 10.14; DS chrome.jsx:8): [model]'s hover preview and pinned panel, the row count
/// in the preview's header once the first read landed.
ShellRailItem bookmarksRailItem(AppLocalizations strings, BookmarkListModel model) => ShellRailItem(
  id: bookmarksRailId,
  label: strings.bookmarksTitle,
  icon: ZI.branch,
  count: model.loaded ? '${model.rows.length}' : null,
  scrolls: true,
  preview: BookmarkListPreview(model: model),
  // Keyed by the model: a project switch starts a fresh filter field and closes a rename sheet.
  panel: BookmarkListPanel(key: ObjectKey(model), model: model),
);

/// The rail's "Tags" item (Story 10.44), right after Bookmarks: [model]'s preview and panel, as the bookmarks'.
ShellRailItem tagsRailItem(AppLocalizations strings, TagListModel model) => ShellRailItem(
  id: tagsRailId,
  label: strings.tagsTitle,
  icon: ZI.tag,
  count: model.loaded ? '${model.rows.length}' : null,
  scrolls: true,
  preview: BookmarkListPreview(model: model),
  panel: BookmarkListPanel(key: ObjectKey(model), model: model),
);

/// The list's rail id.
String _railId(BookmarkListModel model) => model.kind == RefKind.tag ? tagsRailId : bookmarksRailId;

/// The bookmarks' (or tags') hover preview (DS chrome.jsx:112-131, `ZKBookmarkList` with `limit` 5): the first 5 rows
/// and "+N more", which pins the panel; a row click closes the preview, then picks.
class BookmarkListPreview extends StatelessWidget {
  /// The preview of [model].
  const BookmarkListPreview({required this.model, super.key});

  /// The list's state.
  final BookmarkListModel model;

  /// The rows it shows.
  static const shown = 5;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[model, model.graph]),
    builder: (context, _) {
      final AppLocalizations strings = context.l10n;
      final List<BookmarkRow> rows = model.rows;
      final int more = rows.length - shown;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ..._notes(strings, model).map(_Note.new),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                for (var i = 0; i < math.min(shown, rows.length); i++)
                  BookmarkRowTile(
                    key: _keyOf(rows[i]),
                    row: rows[i],
                    index: i,
                    model: model,
                    preview: true,
                  ),
              ],
            ),
          ),
          if (more > 0)
            MouseRegion(
              cursor: SystemMouseCursors.click,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => ShellScope.maybeOf(context)?.activate(_railId(model)),
                // `.zk-co-more`: padding 2 14 4, 11.5 in `--text-dim` (DS kit.css:68).
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 2, 14, 4),
                  child: Text(
                    strings.bookmarksMore(more),
                    style: ZsType.meta.copyWith(fontSize: ZsType.fsId, color: ZsColors.of(context).textDim),
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

/// The bookmarks' (or tags') pinned panel (Stories 10.14, 10.44): the filter on top, then the stale notice or a failed
/// read's note and the tree as a lazy list (the panel's scroll area); the DS empty sentence without rows, the no-match
/// sentence when the filter keeps none. It stays pinned after a pick. It hosts the rename sheet of its row menus.
class BookmarkListPanel extends StatefulWidget {
  /// The panel of [model].
  const BookmarkListPanel({required this.model, super.key});

  /// The list's state.
  final BookmarkListModel model;

  @override
  State<BookmarkListPanel> createState() => _BookmarkListPanelState();
}

class _BookmarkListPanelState extends State<BookmarkListPanel> {
  /// The tree's padding: `.zk-bl` 0 6, the panel body's 10 at the bottom (DS kit.css:73, 87).
  static const _padding = EdgeInsets.fromLTRB(6, 0, 6, 10);

  late final _filter = ZsTextEditingController(text: widget.model.filter);
  final _portal = OverlayPortalController();
  String? _renaming;
  var _closing = false;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _rename(BookmarkRow row) {
    setState(() {
      _renaming = row.bookmark.name;
      _closing = false;
    });
    _portal.show();
  }

  void _close() => setState(() => _closing = true);

  void _closed() {
    _portal.hide();
    setState(() => _renaming = null);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final BookmarkListModel model = widget.model;
    final tag = model.kind == RefKind.tag;
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) {
        final String? name = _renaming;
        if (name == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: GraphNameSheet(
            request: GraphNameRequest(
              title: strings.nameSheetRenameTitle(name),
              label: strings.nameSheetNameLabel,
              confirm: strings.nameSheetRename,
              action: (text, _) => GraphBookmarkRename(name, text),
            ),
            id: name,
            closing: _closing,
            onClosed: _closed,
            onCancel: _close,
            onConfirm: (text) {
              unawaited(model.graph.run(GraphBookmarkRename(name, text)));
              _close();
            },
          ),
        );
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            // The Refs Study's `.rs-filter`: margin 2 10 6.
            padding: const EdgeInsets.fromLTRB(10, 2, 10, 6),
            child: ZsSearchField(
              controller: _filter,
              placeholder: tag ? strings.tagsFilter : strings.bookmarksFilter,
              identifier: '${model.kind.name}-filter',
              onChanged: (text) => model.filter = text,
              onClear: () => model.filter = '',
            ),
          ),
          Expanded(
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[model, model.graph]),
              builder: (context, _) {
                final bool noMatch = model.rows.isNotEmpty && model.tree.isEmpty;
                final notes = <String>[
                  ..._notes(strings, model),
                  if (noMatch && tag) strings.tagsNoMatch(model.filter),
                  if (noMatch && !tag) strings.bookmarksNoMatch(model.filter),
                ];
                final List<RefTreeRow> tree = model.tree;
                return ListView.builder(
                  primary: true,
                  padding: _padding,
                  itemCount: notes.length + tree.length,
                  itemBuilder: (context, index) {
                    if (index < notes.length) {
                      return _Note(notes[index]);
                    }
                    return switch (tree[index - notes.length]) {
                      final RefFolderRow folder => _FolderRow(
                        key: ValueKey<String>('folder:${folder.path}'),
                        folder: folder,
                        query: model.filter,
                        onToggle: () => model.toggleFolder(folder.path),
                      ),
                      final RefLeafRow leaf => BookmarkRowTile(
                        key: _keyOf(leaf.row),
                        row: leaf.row,
                        index: leaf.index,
                        model: model,
                        label: leaf.label,
                        depth: leaf.depth,
                        query: model.filter,
                        onRename: _rename,
                      ),
                    };
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// A row's key: (name, remote) — a local `x@origin` and the remote row `x@origin` read the same.
Key _keyOf(BookmarkRow row) => ValueKey<(String, String?)>((row.bookmark.name, row.remote));

/// The lines above the rows: "Working copy is stale" (the rows stay), a failed read, or the empty sentence.
List<String> _notes(AppLocalizations strings, BookmarkListModel model) {
  final tag = model.kind == RefKind.tag;
  final ZanshinFfiException? error = model.error;
  final String? failed = error == null ? null : error.context ?? error.code;
  final bool empty = model.loaded && model.rows.isEmpty && !model.stale && model.error == null;
  return <String>[
    if (model.stale) strings.staleTitle,
    if (failed != null && tag) strings.tagsLoadFailed(failed),
    if (failed != null && !tag) strings.bookmarksLoadFailed(failed),
    if (empty && tag) strings.tagsEmpty(_createTagCommand),
    if (empty && !tag) strings.bookmarksEmpty(_createCommand),
  ];
}

/// A line of `--fs-sm` text in `--text-dim` (DS kit.css:68, `.zk-co-more`'s look).
class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
    // One line: jj's error context may span several.
    child: Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: ZsType.meta.copyWith(color: ZsColors.of(context).textDim),
    ),
  );
}

/// [text] with every case-insensitive match of [query] in 600 and underlined in `--accent` (Story 10.44's filter).
List<InlineSpan> _highlighted(String text, String query, Color accent) {
  if (query.isEmpty) {
    return <InlineSpan>[TextSpan(text: text)];
  }
  final String lower = text.toLowerCase();
  final String q = query.toLowerCase();
  final spans = <InlineSpan>[];
  var at = 0;
  for (int hit = lower.indexOf(q); hit >= 0; hit = lower.indexOf(q, at)) {
    if (hit > at) {
      spans.add(TextSpan(text: text.substring(at, hit)));
    }
    at = hit + q.length;
    spans.add(
      TextSpan(
        text: text.substring(hit, at),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontVariations: const <FontVariation>[FontVariation.weight(600)],
          decoration: TextDecoration.underline,
          decorationColor: accent,
          color: accent,
        ),
      ),
    );
  }
  if (at < text.length) {
    spans.add(TextSpan(text: text.substring(at)));
  }
  return spans;
}

/// A folder of the tree (Refs Study `.rs-dir`): 28 high, indent 8 + 14 × depth, the open or closed folder glyph in
/// `--text-faint`, the name with its `/` in mono 11.5 `--text-muted`, no chevron. Click, ↩ and Space fold it.
class _FolderRow extends StatefulWidget {
  const _FolderRow({required this.folder, required this.query, required this.onToggle, super.key});

  final RefFolderRow folder;
  final String query;
  final VoidCallback onToggle;

  @override
  State<_FolderRow> createState() => _FolderRowState();
}

class _FolderRowState extends State<_FolderRow> {
  final _focus = FocusNode(debugLabel: 'ref folder');
  var _hovered = false;
  var _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.space)) {
      widget.onToggle();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final bool inactive = ZsAppearance.of(context).inactive;
    final RefFolderRow folder = widget.folder;
    return Semantics(
      container: true,
      identifier: 'ref-folder-${folder.path}',
      label: folder.name,
      button: true,
      expanded: folder.open,
      onTap: widget.onToggle,
      child: ExcludeSemantics(
        child: MouseRegion(
          onEnter: (_) => setState(() => _hovered = true),
          onExit: (_) => setState(() => _hovered = false),
          child: Focus(
            focusNode: _focus,
            includeSemantics: false,
            onKeyEvent: _key,
            onFocusChange: (focused) => setState(() => _focused = focused),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: widget.onToggle,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: _hovered && !inactive ? colors.flHover : null,
                  borderRadius: BorderRadius.circular(7),
                  border: _focused && !inactive ? Border.all(color: colors.focusRing, width: 2) : null,
                ),
                child: SizedBox(
                  height: 28,
                  child: Padding(
                    padding: EdgeInsets.only(left: 8 + 14.0 * folder.depth, right: 8),
                    child: Row(
                      spacing: 6,
                      children: <Widget>[
                        ZanshinIcon(
                          folder.open ? ZI.folderOpen : ZI.folder,
                          size: ZsIconSize.md,
                          color: colors.textFaint,
                        ),
                        Expanded(
                          child: Text.rich(
                            TextSpan(children: _highlighted(folder.name, widget.query, colors.accent)),
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.ellipsis,
                            style: ZsType.id.copyWith(color: colors.textMuted),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The short state (DS chrome.jsx:14, `zkBmShort`), or null for the conflict mark. A local-only row shows no mark, and
/// an untracked remote row is marked by its dim text alone (Story 10.44).
String? bookmarkStateShort(AppLocalizations strings, BookmarkRow row) => switch (row.state) {
  BookmarkRowState.synced => '✓', // l10n-ignore: symbol
  BookmarkRowState.ahead => '↑${row.count}', // l10n-ignore: symbol
  BookmarkRowState.behind => '↓${row.count}', // l10n-ignore: symbol
  BookmarkRowState.diverged => '↕', // l10n-ignore: symbol
  BookmarkRowState.notPushed => '↑', // l10n-ignore: symbol
  BookmarkRowState.local || BookmarkRowState.remote => '',
  BookmarkRowState.deleted => strings.bookmarksStateDeletedShort,
  BookmarkRowState.notCreated => strings.bookmarksStateNotCreatedShort,
  BookmarkRowState.divergent => strings.bookmarksStateDivergentShort,
  BookmarkRowState.conflicted => null,
};

/// The long state (DS chrome.jsx:13, `ZK_BM_STATE`): the row's VoiceOver text (and the preview row's tooltip).
String bookmarkStateLong(AppLocalizations strings, BookmarkRow row) {
  final String other = row.other ?? '';
  final String count = row.count ?? '';
  return switch (row.state) {
    BookmarkRowState.synced => strings.bookmarksStateSynced(other),
    BookmarkRowState.ahead => strings.bookmarksStateAhead(other, count),
    BookmarkRowState.behind => strings.bookmarksStateBehind(other, count),
    BookmarkRowState.diverged => strings.bookmarksStateDiverged(other),
    BookmarkRowState.notPushed => strings.bookmarksStateNotPushed(other),
    BookmarkRowState.local => strings.bookmarksStateLocal,
    BookmarkRowState.remote => strings.bookmarksStateRemote,
    BookmarkRowState.deleted => strings.bookmarksStateDeleted,
    BookmarkRowState.notCreated => strings.bookmarksStateNotCreated,
    BookmarkRowState.conflicted => strings.bookmarksStateConflicted,
    BookmarkRowState.divergent => strings.bookmarksStateDivergent,
  };
}

/// One bookmark or tag row (DS kit.css:73-81, `.zk-bl-row`): the name (mono 12) over "id · subject", and the state
/// (graph.css:56-57); a target outside the layout at .55. A click, ↩ or Space picks it.
///
/// A preview row leads with the filled bookmark glyph (a tag's glyph for tags) in `--text-dim` and shows the whole
/// name. A panel row (Story 10.44) is a tree leaf: no glyph, indent 8 + 14 × [depth] + 20, min height 40, its [label]
/// (a remote row adds a dim `@remote`, its text at .6 while untracked) with [query] highlighted, the full name as
/// its tooltip; on hover or keyboard focus its buttons ([BookmarkRow.actions]) replace the state, and a right-click
/// opens its menu (the actions, Rename… for a local bookmark, Copy name).
class BookmarkRowTile extends StatefulWidget {
  /// The row [row], the [index]th; [preview] rows take no focus and show no button.
  const BookmarkRowTile({
    required this.row,
    required this.index,
    required this.model,
    this.preview = false,
    this.label,
    this.depth = 0,
    this.query = '',
    this.onRename,
    this.showActions = false,
    super.key,
  });

  /// The row.
  final BookmarkRow row;

  /// Its position in the flat list, for its identifiers.
  final int index;

  /// The list's state.
  final BookmarkListModel model;

  /// Whether it is a hover preview's row.
  final bool preview;

  /// The tree leaf's label; null shows the whole name.
  final String? label;

  /// How many folders contain it.
  final int depth;

  /// The filter text highlighted in the label.
  final String query;

  /// Opens the rename sheet of a local bookmark.
  final ValueChanged<BookmarkRow>? onRename;

  /// Shows a panel row's buttons without hover or focus: the catalogue's view of a hover-only surface.
  final bool showActions;

  @override
  State<BookmarkRowTile> createState() => _BookmarkRowTileState();
}

class _BookmarkRowTileState extends State<BookmarkRowTile> {
  final _focus = FocusNode(debugLabel: 'bookmark row');
  var _hovered = false;
  var _focused = false;

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  bool get _pickable => widget.row.pickable && !widget.model.pickBlocked(widget.row);

  String get _kind => widget.model.kind.name;

  /// The row's verbs; Delete… only where the model has a delete flow.
  List<RefRowAction> get _actions => <RefRowAction>[
    for (final RefRowAction action in widget.row.actions)
      if (action != RefRowAction.delete || widget.model.deletes != null) action,
  ];

  void _pick() {
    if (widget.preview) {
      ShellScope.maybeOf(context)?.closePreview();
    }
    widget.model.pick(widget.row);
  }

  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        _focus.hasPrimaryFocus &&
        _pickable &&
        (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.space)) {
      _pick();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// Why the verbs cannot run, or null.
  String? _reason(AppLocalizations strings) => widget.model.graph.actionsEnabled
      ? null
      : widget.model.graph.stale != null
      ? strings.staleTitle
      : strings.bookmarksBusy;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final bool inactive = ZsAppearance.of(context).inactive;
    final BookmarkRow row = widget.row;
    final bool pickable = _pickable;
    final bool blocked = row.pickable && !pickable;
    final String label = strings.bookmarksRow(row.display, bookmarkStateLong(strings, row));
    final bool ring = _focused && _focus.hasPrimaryFocus && !inactive;
    final bool tree = !widget.preview;
    final bool untracked = switch (row.bookmark.kind) {
      RemoteBookmark(:final bool tracked) => !tracked,
      LocalBookmark() => false,
    };
    final double opacity = (row.visible ? 1 : .55) * (tree && untracked ? .6 : 1);
    final Widget body = Semantics(
      container: true,
      identifier: '$_kind-row-${widget.index}',
      label: blocked ? '$label, ${strings.staleTitle}' : label,
      button: true,
      enabled: pickable,
      onTap: pickable ? _pick : null,
      child: ExcludeSemantics(
        child: ZsTooltip(
          message: blocked
              ? strings.staleTitle
              : tree
              ? row.display
              : label,
          child: Opacity(opacity: opacity, child: _text(colors, row)),
        ),
      ),
    );
    final bool showActions = tree && (_hovered || _focused || widget.showActions) && _actions.isNotEmpty;
    final Widget trailing = showActions
        ? Row(mainAxisSize: MainAxisSize.min, spacing: 2, children: _buttons(strings))
        : Opacity(opacity: row.visible ? 1 : .55, child: _state(colors, strings, row));
    final Widget content = Row(
      spacing: 8,
      children: <Widget>[
        if (!tree)
          SizedBox(
            width: 14,
            child: ZanshinIcon(
              widget.model.kind == RefKind.tag ? ZI.tag : ZI.bookmarkFilled,
              size: ZsIconSize.sm,
              color: colors.textDim,
            ),
          ),
        Expanded(child: body),
        trailing,
      ],
    );
    final String name = row.bookmark.name;
    // Story 10.10: a local bookmark drags onto the change it should point to (not while the actions are disabled; the
    // stale tooltip stays). Tags never drag.
    final Widget tile = GraphDragSource(
      drag: widget.model.graph.drag,
      payload: GraphBookmarkDrag(name),
      enabled:
          widget.model.kind == RefKind.bookmark &&
          row.bookmark.kind is LocalBookmark &&
          graphBookmarkDraggable(name) &&
          widget.model.graph.actionsEnabled,
      child: _tile(colors, inactive, pickable, ring, content),
    );
    if (!tree) {
      return tile;
    }
    return ZsMenuAnchor(
      entries: _menu(strings),
      semanticLabel: strings.refsActions,
      identifier: '$_kind-row-menu',
      // The card menus' limits: a long name's command ends in an ellipsis rather than pushing the label out.
      cmdMaxWidth: 200,
      maxWidth: 360,
      builder: (context, menu) => GestureDetector(
        onSecondaryTapUp: (details) => menu.open(position: details.localPosition),
        child: tile,
      ),
    );
  }

  Widget _tile(ZsColors colors, bool inactive, bool pickable, bool ring, Widget content) {
    final bool tree = !widget.preview;
    return MouseRegion(
      cursor: pickable ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Focus(
        focusNode: _focus,
        canRequestFocus: tree,
        skipTraversal: !tree,
        includeSemantics: false,
        onKeyEvent: _key,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: pickable ? _pick : null,
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: (_hovered || (tree && (_focused || widget.showActions))) && !inactive ? colors.flHover : null,
              borderRadius: BorderRadius.circular(6),
              border: ring ? Border.all(color: colors.focusRing, width: 2) : null,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(minHeight: tree ? 40 : 0),
              child: Padding(
                padding: tree
                    ? EdgeInsets.only(left: 8 + 14.0 * widget.depth + 20, right: 8, top: 4, bottom: 4)
                    : const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
                child: Align(alignment: Alignment.centerLeft, widthFactor: 1, child: content),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The name over "id · subject".
  Widget _text(ZsColors colors, BookmarkRow row) {
    final TextStyle mono = ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textDim);
    final String? label = widget.label;
    final String? remote = row.remote;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text.rich(
          TextSpan(
            children: label == null
                ? <InlineSpan>[TextSpan(text: row.display)]
                : <InlineSpan>[
                    ..._highlighted(label, widget.query, colors.accent),
                    if (remote != null)
                      TextSpan(
                        text: '@$remote', // l10n-ignore: jj's symbol
                        style: TextStyle(color: colors.textFaint),
                      ),
                  ],
          ),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: ZsType.id.copyWith(fontSize: ZsType.fsMd, color: colors.text),
        ),
        Text.rich(
          _sub(colors, row, mono),
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: ZsType.meta.copyWith(color: colors.textDim),
        ),
      ],
    );
  }

  /// The state mark: `.zs-bm-state`, mono `--fs-xs`, `--add` ahead, `--rem` behind (DS graph.css:56-57); the
  /// conflict glyph for a conflict.
  Widget _state(ZsColors colors, AppLocalizations strings, BookmarkRow row) {
    final String? short = bookmarkStateShort(strings, row);
    if (short == null) {
      return ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.conflict);
    }
    return Text(
      short,
      style: ZsType.id.copyWith(
        fontSize: ZsType.fsXs,
        color: switch (row.state) {
          BookmarkRowState.ahead || BookmarkRowState.notPushed => colors.add,
          BookmarkRowState.behind => colors.rem,
          _ => colors.textDim,
        },
      ),
    );
  }

  /// "id · subject": the change id with jj's shortest prefix bold, max(prefix, 8) characters (decision 16.35), then
  /// the subject or jj's "(no description set)"; the id alone while the subject is unknown.
  static InlineSpan _sub(ZsColors colors, BookmarkRow row, TextStyle mono) {
    final String? target = row.bookmark.target;
    if (target == null) {
      return const TextSpan();
    }
    final int shown = math.min(target.length, math.max(row.prefix, 8));
    final int bold = math.min(row.prefix, shown);
    final String? subject = row.subject;
    return TextSpan(
      children: <InlineSpan>[
        TextSpan(
          text: target.substring(0, bold),
          style: mono.copyWith(
            fontWeight: FontWeight.w600,
            fontVariations: const <FontVariation>[FontVariation.weight(600)],
            color: colors.textMuted,
          ),
        ),
        TextSpan(text: target.substring(bold, shown), style: mono),
        if (subject != null) TextSpan(text: ' · ${subject.isEmpty ? _noDescription : subject}'),
      ],
    );
  }

  /// The command [action] of the row runs, as its tooltip and menu row show it.
  String _command(RefRowAction action) => switch (action) {
    RefRowAction.newHere => BookmarkListModel.newCommand(widget.row),
    RefRowAction.track => widget.row.trackAction!.command,
    RefRowAction.delete => switch (widget.model.kind) {
      RefKind.bookmark => GraphBookmarkDelete(<String>[widget.row.bookmark.name]).command,
      RefKind.tag => GraphTagDelete(<String>[widget.row.bookmark.name]).command,
    },
  };

  String _actionLabel(AppLocalizations strings, RefRowAction action) => switch (action) {
    RefRowAction.newHere => strings.refsNewHere,
    RefRowAction.delete => strings.refsDelete,
    RefRowAction.track =>
      widget.row.trackAction is GraphBookmarkUntrack || widget.row.trackAction is GraphTagUntrack
          ? strings.bookmarksUntrack
          : strings.bookmarksTrack,
  };

  void _runAction(RefRowAction action) {
    switch (action) {
      case RefRowAction.newHere:
        unawaited(widget.model.newHere(widget.row));
      case RefRowAction.delete:
        widget.model.delete(widget.row);
      case RefRowAction.track:
        unawaited(widget.model.track(widget.row));
    }
  }

  /// The row's buttons, in place of the state: icon buttons for New and Delete…, text buttons for Track and Untrack;
  /// each tooltip carries its command, and while the runner cannot run they are disabled with the reason.
  List<Widget> _buttons(AppLocalizations strings) {
    final String? reason = _reason(strings);
    final int i = widget.index;
    return <Widget>[
      for (final RefRowAction action in _actions)
        ZsTooltip(
          message: reason ?? _actionLabel(strings, action),
          cmd: _command(action),
          child: switch (action) {
            RefRowAction.track => ZsButton(
              label: _actionLabel(strings, action),
              onPressed: reason == null ? () => _runAction(action) : null,
              disabledReason: reason,
              identifier: '$_kind-track-$i',
            ),
            RefRowAction.newHere || RefRowAction.delete => ZsIconButton(
              icon: action == RefRowAction.newHere ? ZI.plus : ZI.abandon,
              label: _actionLabel(strings, action),
              size: ZsIconButtonSize.sm,
              tooltip: false,
              onPressed: reason == null ? () => _runAction(action) : null,
              disabledReason: reason,
              identifier: action == RefRowAction.newHere ? '$_kind-row-new-$i' : '$_kind-row-delete-$i',
            ),
          },
        ),
    ];
  }

  /// The right-click menu: the row's actions, Rename… for a local bookmark, Copy name.
  List<ZsMenuEntry> _menu(AppLocalizations strings) {
    final String? reason = _reason(strings);
    final BookmarkRow row = widget.row;
    final ValueChanged<BookmarkRow>? rename = widget.onRename;
    return <ZsMenuEntry>[
      for (final RefRowAction action in _actions)
        ZsMenuItem(
          label: _actionLabel(strings, action),
          icon: switch (action) {
            RefRowAction.newHere => ZI.plus,
            RefRowAction.delete => ZI.abandon,
            RefRowAction.track => null,
          },
          cmd: _command(action),
          danger: action == RefRowAction.delete,
          enabled: reason == null,
          tooltip: reason,
          identifier: '$_kind-menu-${action.name}',
          onSelected: () => _runAction(action),
        ),
      if (row.renamable)
        ZsMenuItem(
          label: strings.refsRename,
          icon: ZI.describe,
          enabled: reason == null && rename != null,
          tooltip: reason,
          identifier: '$_kind-menu-rename',
          onSelected: rename == null ? null : () => rename(row),
        ),
      if (_actions.isNotEmpty || row.renamable) const ZsMenuSeparator(),
      ZsMenuItem(
        label: strings.refsCopyName,
        icon: ZI.copy,
        identifier: '$_kind-menu-copy',
        onSelected: () {
          unawaited(Clipboard.setData(ClipboardData(text: row.display)));
          announceCopied(context);
        },
      ),
    ];
  }
}
