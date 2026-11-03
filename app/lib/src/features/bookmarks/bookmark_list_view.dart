// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:zanshin_core/zanshin_core.dart' show LocalBookmark;
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import '../graph/graph_drag.dart';
import '../graph/graph_ports.dart';
import '../shell/shell_controller.dart';
import '../shell/shell_scope.dart';
import 'bookmark_list_model.dart';

/// The rail item's id.
const bookmarksRailId = 'bookmarks';

/// The jj command the empty list names (decision 16.44).
const _createCommand = 'jj bookmark create <name>'; // l10n-ignore: jj command

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
  panel: BookmarkListPanel(model: model),
);

/// The bookmarks' hover preview (DS chrome.jsx:112-131, `ZKBookmarkList` with `limit` 5): the first 5 rows and "+N
/// more", which pins the panel; a row click closes the preview, then picks.
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
                onTap: () => ShellScope.maybeOf(context)?.activate(bookmarksRailId),
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

/// The bookmarks' pinned panel (Story 10.14): every row as a lazy list (the panel's scroll area); the stale notice or a
/// failed read's note above them, the DS empty sentence without any. It stays pinned after a pick.
class BookmarkListPanel extends StatelessWidget {
  /// The panel of [model].
  const BookmarkListPanel({required this.model, super.key});

  /// The list's state.
  final BookmarkListModel model;

  /// The list's padding: `.zk-bl` 0 6, the panel body's 10 at the bottom (DS kit.css:73, 87).
  static const _padding = EdgeInsets.fromLTRB(6, 0, 6, 10);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge(<Listenable>[model, model.graph]),
    builder: (context, _) {
      final List<String> notes = _notes(context.l10n, model);
      final List<BookmarkRow> rows = model.rows;
      return ListView.builder(
        primary: true,
        padding: _padding,
        itemCount: notes.length + rows.length,
        itemBuilder: (context, index) {
          if (index < notes.length) {
            return _Note(notes[index]);
          }
          final int i = index - notes.length;
          return BookmarkRowTile(key: _keyOf(rows[i]), row: rows[i], index: i, model: model);
        },
      );
    },
  );
}

/// A row's key: (name, remote) — a local `x@origin` and the remote row `x@origin` read the same.
Key _keyOf(BookmarkRow row) => ValueKey<(String, String?)>((row.bookmark.name, row.remote));

/// The lines above the rows: "Working copy is stale" (the rows stay), a failed read, or the empty sentence.
List<String> _notes(AppLocalizations strings, BookmarkListModel model) => <String>[
  if (model.stale) strings.staleTitle,
  if (model.error case final error?) strings.bookmarksLoadFailed(error.context ?? error.code),
  if (model.loaded && model.rows.isEmpty && !model.stale && model.error == null) strings.bookmarksEmpty(_createCommand),
];

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

/// The short state (DS chrome.jsx:14, `zkBmShort`), or null for the conflict mark.
String? bookmarkStateShort(AppLocalizations strings, BookmarkRow row) => switch (row.state) {
  BookmarkRowState.synced => '✓', // l10n-ignore: symbol
  BookmarkRowState.ahead => '↑${row.count}', // l10n-ignore: symbol
  BookmarkRowState.behind => '↓${row.count}', // l10n-ignore: symbol
  BookmarkRowState.diverged => '↕', // l10n-ignore: symbol
  BookmarkRowState.notPushed => '↑', // l10n-ignore: symbol
  BookmarkRowState.local => strings.bookmarksStateLocalShort,
  BookmarkRowState.remote => strings.bookmarksStateRemoteShort,
  BookmarkRowState.deleted => strings.bookmarksStateDeletedShort,
  BookmarkRowState.notCreated => strings.bookmarksStateNotCreatedShort,
  BookmarkRowState.divergent => strings.bookmarksStateDivergentShort,
  BookmarkRowState.conflicted => null,
};

/// The long state (DS chrome.jsx:13, `ZK_BM_STATE`): the row's tooltip and VoiceOver text.
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

/// One bookmark row (DS kit.css:73-81, `.zk-bl-row`): the filled bookmark glyph in `--text-dim`, the name (mono 12)
/// over "id · subject", and the state (graph.css:56-57); a target outside the layout at .55. A click, ↩ or Space picks
/// it. In the panel a remote row shows Track or Untrack on hover or keyboard focus.
class BookmarkRowTile extends StatefulWidget {
  /// The row [row], the [index]th; [preview] rows take no focus and show no button.
  const BookmarkRowTile({required this.row, required this.index, required this.model, this.preview = false, super.key});

  /// The row.
  final BookmarkRow row;

  /// Its position, for its identifier.
  final int index;

  /// The list's state.
  final BookmarkListModel model;

  /// Whether it is a hover preview's row.
  final bool preview;

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

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final bool inactive = ZsAppearance.of(context).inactive;
    final BookmarkRow row = widget.row;
    final bool pickable = _pickable;
    final bool blocked = row.pickable && !pickable;
    final String label = strings.bookmarksRow(row.display, bookmarkStateLong(strings, row));
    final GraphAction? track = widget.preview ? null : row.trackAction;
    final bool ring = _focused && _focus.hasPrimaryFocus && !inactive;
    final Widget body = Semantics(
      container: true,
      identifier: 'bookmark-row-${widget.index}',
      label: blocked ? '$label, ${strings.staleTitle}' : label,
      button: true,
      enabled: pickable,
      onTap: pickable ? _pick : null,
      child: ExcludeSemantics(
        child: ZsTooltip(
          message: blocked ? strings.staleTitle : label,
          child: Opacity(opacity: row.visible ? 1 : .55, child: _content(colors, strings, row)),
        ),
      ),
    );
    final String name = row.bookmark.name;
    // Story 10.10: a local bookmark drags onto the change it should point to (not while the actions are disabled; the
    // stale tooltip stays).
    return GraphDragSource(
      drag: widget.model.graph.drag,
      payload: GraphBookmarkDrag(name),
      enabled: row.bookmark.kind is LocalBookmark && graphBookmarkDraggable(name) && widget.model.graph.actionsEnabled,
      child: _tile(colors, inactive, pickable, ring, track, strings, body),
    );
  }

  Widget _tile(
    ZsColors colors,
    bool inactive,
    bool pickable,
    bool ring,
    GraphAction? track,
    AppLocalizations strings,
    Widget body,
  ) => MouseRegion(
    cursor: pickable ? SystemMouseCursors.click : MouseCursor.defer,
    onEnter: (_) => setState(() => _hovered = true),
    onExit: (_) => setState(() => _hovered = false),
    child: Focus(
      focusNode: _focus,
      canRequestFocus: !widget.preview,
      skipTraversal: widget.preview,
      includeSemantics: false,
      onKeyEvent: _key,
      onFocusChange: (focused) => setState(() => _focused = focused),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: pickable ? _pick : null,
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: _hovered && !inactive ? colors.flHover : null,
            borderRadius: BorderRadius.circular(6),
            border: ring ? Border.all(color: colors.focusRing, width: 2) : null,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                body,
                if (track != null && (_hovered || _focused))
                  Padding(
                    padding: const EdgeInsets.only(top: 6, left: 22),
                    child: Align(alignment: Alignment.centerLeft, child: _trackButton(strings, track)),
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  /// `grid-template-columns:14px minmax(0,1fr) auto; gap:8px` (DS kit.css:74).
  Widget _content(ZsColors colors, AppLocalizations strings, BookmarkRow row) {
    final String? short = bookmarkStateShort(strings, row);
    final TextStyle mono = ZsType.id.copyWith(fontSize: ZsType.fsSm, color: colors.textDim);
    return Row(
      spacing: 8,
      children: <Widget>[
        SizedBox(
          width: 14,
          child: ZanshinIcon(ZI.bookmarkFilled, size: ZsIconSize.sm, color: colors.textDim),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                row.display,
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
          ),
        ),
        if (short == null)
          ZanshinIcon(ZI.conflict, size: ZsIconSize.sm, color: colors.conflict)
        else
          // `.zs-bm-state`: mono `--fs-xs`, `--add` ahead, `--rem` behind, `--remote` remote (DS graph.css:56-57).
          Text(
            short,
            style: ZsType.id.copyWith(
              fontSize: ZsType.fsXs,
              color: switch (row.state) {
                BookmarkRowState.ahead || BookmarkRowState.notPushed => colors.add,
                BookmarkRowState.behind => colors.rem,
                BookmarkRowState.remote => colors.remote,
                _ => colors.textDim,
              },
            ),
          ),
      ],
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

  /// Track or Untrack; disabled with its reason while the runner cannot run, its tooltip the jj command.
  Widget _trackButton(AppLocalizations strings, GraphAction action) {
    final bool enabled = widget.model.graph.actionsEnabled;
    final String? reason = enabled
        ? null
        : widget.model.graph.stale != null
        ? strings.staleTitle
        : strings.bookmarksBusy;
    return ZsTooltip(
      message: reason ?? action.command,
      cmd: reason == null ? null : action.command,
      child: ZsButton(
        label: action is GraphBookmarkUntrack ? strings.bookmarksUntrack : strings.bookmarksTrack,
        onPressed: reason == null ? () => unawaited(widget.model.track(widget.row)) : null,
        disabledReason: reason,
        identifier: 'bookmark-track-${widget.index}',
      ),
    );
  }
}
