// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card.dart';
import 'graph_content.dart';
import 'graph_inspector.dart';
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_view_model.dart';
import 'hatch_swatch.dart';

final _log = Logger('zanshin.graph.menu');

/// jj's mirror of the colocated Git refs (`default_ignored_remote_name`, `../jj` v0.46.0 cli/src/cli_util.rs): no
/// remote to track.
const _gitRemote = 'git'; // l10n-ignore: jj's remote name

/// The widest a menu row's command gets (Claude's proposal; the Project menu's limit is 130): Revert's
/// `jj revert -r <8-char id> -B @` fits whole, a long bookmark name still ends in an ellipsis.
const double _cmdMaxWidth = 200;

/// The widest the card and bookmark menus grow: the DS 320 fits commands without ids (`menus.css:6`), these show
/// the short id (Story 10.15).
const double _menuMaxWidth = 360;

/// What the name sheet asks for (Story 10.15): its [title], the field's [label], the [confirm] verb, and the [action]
/// the typed text makes on a change id (the short id for the shown command, the node key to run).
@immutable
class GraphNameRequest {
  /// A sheet titled [title].
  const GraphNameRequest({required this.title, required this.label, required this.confirm, required this.action});

  /// The sheet's title.
  final String title;

  /// The field's accessible name.
  final String label;

  /// The confirm button's verb.
  final String confirm;

  /// The action for the typed text on the change `id`.
  final GraphAction Function(String text, String id) action;
}

/// Whether [node] is an ancestor of [of] through the layout's edges (an indirect edge is ancestry through hidden
/// commits).
bool _isAncestor(GraphLayout layout, int node, {required int of}) {
  final seen = <int>{of};
  final pending = <int>[of];
  while (pending.isNotEmpty) {
    final ({int start, int end}) edges = layout.parentEdges(pending.removeLast());
    for (int e = edges.start; e < edges.end; e++) {
      final int parent = layout.parentOf(e);
      if (parent == node) {
        return true;
      }
      if (seen.add(parent)) {
        pending.add(parent);
      }
    }
  }
  return false;
}

/// Whether one of [node]'s direct parents in the layout is immutable.
bool _parentImmutable(GraphLayout layout, int node) {
  final ({int start, int end}) edges = layout.parentEdges(node);
  for (int e = edges.start; e < edges.end; e++) {
    if (layout.kindOf(e) == GraphEdgeKind.direct && layout.isImmutable(layout.parentOf(e))) {
      return true;
    }
  }
  return false;
}

/// Whether one of [node]'s direct children in the layout is immutable.
bool _childImmutable(GraphLayout layout, int node) {
  final ({int start, int end}) slots = layout.childEdges(node);
  for (int s = slots.start; s < slots.end; s++) {
    final int e = layout.childEdgeAt(s);
    if (layout.kindOf(e) == GraphEdgeKind.direct && layout.isImmutable(layout.childOf(e))) {
      return true;
    }
  }
  return false;
}

/// The card menu's rows for [node] (Story 10.15), a pure function of the layout: on a mutable change New change on
/// top, Insert after, Insert before · Edit, Describe…, Squash into parent, Copy › · Revert, Abandon; on an immutable
/// one New change on top, Insert after (not when a child is immutable), Revert · the "Immutable" note, Immutable
/// commits…; on the root New change on top. Each row's command is its action's with the short id; [run] gets the
/// action with the node key. While [blocked] names a reason every row is disabled with it as its tooltip.
List<ZsMenuEntry> graphCardMenuEntries(
  AppLocalizations strings,
  GraphLayout layout,
  int node, {
  required String? blocked,
  required ValueChanged<GraphAction> run,
  GraphContent? content,
  ValueChanged<String>? onDescribe,
  ValueChanged<String>? onSquash,
}) {
  final data = GraphCardData.of(layout, node, content: content);
  final String key = data.key;
  final String short = graphShortId(layout, node);

  ZsMenuItem verb(
    String label,
    String icon,
    GraphAction Function(String id) action, {
    required String identifier,
    String? reason,
    bool danger = false,
    ValueChanged<String>? select,
  }) {
    final String? why = blocked ?? reason;
    return ZsMenuItem(
      label: label,
      icon: icon,
      cmd: action(short).command,
      danger: danger,
      enabled: why == null,
      tooltip: why,
      identifier: identifier,
      onSelected: select == null ? () => run(action(key)) : () => select(key),
    );
  }

  final ZsMenuItem newOnTop = verb(
    strings.cardMenuNewOnTop,
    ZI.newOnTop,
    (id) => GraphNew(parents: <String>[id]),
    identifier: 'card-menu-new',
  );
  if (data.isRoot) {
    return <ZsMenuEntry>[newOnTop];
  }
  final ZsMenuItem insertAfter = verb(
    strings.cardMenuInsertAfter,
    ZI.insertAfter,
    (id) => GraphNew(insertAfter: <String>[id]),
    identifier: 'card-menu-insert-after',
  );
  final int? at = layout.workingCopyIndex;
  final ZsMenuItem revert = verb(
    strings.cardMenuRevert,
    ZI.revert,
    GraphRevert.new,
    identifier: 'card-menu-revert',
    reason: data.isWorkingCopy
        ? strings.cardMenuRevertAt
        : at != null && !_isAncestor(layout, node, of: at)
        ? strings.cardMenuRevertNotAncestor
        : (data.content?.empty ?? false)
        ? strings.cardMenuRevertEmpty
        : null,
  );
  if (data.immutable) {
    return <ZsMenuEntry>[
      newOnTop,
      if (!_childImmutable(layout, node)) insertAfter,
      revert,
      const ZsMenuSeparator(),
      ZsMenuNote(strings.cardMenuImmutable, leading: const HatchSwatch()),
      ZsMenuItem(
        label: strings.cardMenuImmutableCommits,
        icon: ZI.settings,
        enabled: false,
        tooltip: blocked ?? strings.cardMenuSettingsLater,
        identifier: 'card-menu-immutable-commits',
      ),
    ];
  }
  final GraphCommitContent? loaded = data.content;
  void copy(String text) => unawaited(Clipboard.setData(ClipboardData(text: text)));
  return <ZsMenuEntry>[
    newOnTop,
    insertAfter,
    verb(
      strings.cardMenuInsertBefore,
      ZI.insertBefore,
      (id) => GraphNew(insertBefore: <String>[id]),
      identifier: 'card-menu-insert-before',
    ),
    const ZsMenuSeparator(),
    verb(
      strings.cardMenuEdit,
      ZI.workingCopyAt,
      GraphEdit.new,
      identifier: 'card-menu-edit',
      reason: data.isWorkingCopy ? strings.cardMenuEditAlready : null,
    ),
    ZsMenuItem(
      label: strings.cardMenuDescribe,
      icon: ZI.describe,
      cmd: GraphDescribe.fromParagraphs(short, const <String>[]).command,
      enabled: blocked == null && onDescribe != null,
      tooltip: blocked,
      identifier: 'card-menu-describe',
      onSelected: onDescribe == null ? null : () => onDescribe(key),
    ),
    verb(
      strings.cardMenuSquash,
      ZI.squash,
      (id) => GraphSquash(revision: id),
      identifier: 'card-menu-squash',
      // Through the inspector, which asks for a combined description as the CLI's editor does (Story 10.25).
      select: onSquash,
      reason: data.merge
          ? strings.cardMenuSquashMerge
          : _parentImmutable(layout, node)
          ? strings.cardMenuSquashParentImmutable
          : null,
    ),
    ZsMenuItem(
      label: strings.cardMenuCopy,
      icon: ZI.copy,
      // Read-only: it runs no jj, so a busy or stale graph leaves it on.
      identifier: 'card-menu-copy',
      submenu: <ZsMenuEntry>[
        ZsMenuItem(
          label: strings.cardMenuCopyChangeId,
          identifier: 'card-menu-copy-change-id',
          onSelected: () => copy(data.changeId),
        ),
        ZsMenuItem(
          label: strings.cardMenuCopyDescription,
          enabled: loaded != null,
          identifier: 'card-menu-copy-description',
          onSelected: loaded == null ? null : () => copy(loaded.description),
        ),
      ],
    ),
    const ZsMenuSeparator(),
    revert,
    verb(
      strings.cardMenuAbandon,
      ZI.abandon,
      (id) => GraphAbandon(<String>[id]),
      identifier: 'card-menu-abandon',
      danger: true,
    ),
  ];
}

/// The thin bookmark popover's rows for [node] (Story 10.15): per local bookmark a submenu Rename…, Move to…,
/// Delete; per remote bookmark (not `git`) a submenu with Track or Untrack as [bookmarks] (jj's live `bookmark list
/// --all-remotes`) says, disabled "Reading bookmarks…" while it is null (or with the failure when [readFailed]);
/// then Create bookmark here… and Move existing here…, which [ask] for a name. While [blocked] names a reason every
/// row is disabled with it.
List<ZsMenuEntry> graphBookmarkMenuEntries(
  AppLocalizations strings,
  GraphLayout layout,
  int node, {
  required String? blocked,
  required ValueChanged<GraphAction> run,
  required List<Bookmark>? bookmarks,
  required ValueChanged<GraphNameRequest> ask,
  bool readFailed = false,
}) {
  final List<GraphRef> refs = layout.refsOf(node);

  ZsMenuItem item(
    String label, {
    required String identifier,
    GraphAction? action,
    VoidCallback? onSelected,
    String? reason,
    bool mono = false,
    bool danger = false,
    List<ZsMenuEntry>? submenu,
  }) {
    final String? why = blocked ?? reason;
    return ZsMenuItem(
      label: label,
      cmd: action?.command,
      mono: mono,
      danger: danger,
      enabled: why == null,
      tooltip: why,
      identifier: identifier,
      submenu: submenu,
      onSelected: onSelected ?? (action == null ? null : () => run(action)),
    );
  }

  bool? tracked(String name, String remote) {
    for (final Bookmark bookmark in bookmarks ?? const <Bookmark>[]) {
      if (bookmark.kind case RemoteBookmark(:final String remoteName, :final bool tracked)
          when bookmark.name == name && remoteName == remote) {
        return tracked;
      }
    }
    return null;
  }

  final rows = <ZsMenuEntry>[];
  for (final ref in refs) {
    final String name = ref.name;
    final String? remote = ref.remote;
    if (remote == null) {
      rows.add(
        item(
          name,
          mono: true,
          identifier: 'bookmark-menu-$name',
          submenu: <ZsMenuEntry>[
            item(
              strings.bookmarkMenuRename,
              identifier: 'bookmark-menu-rename',
              onSelected: () => ask(
                GraphNameRequest(
                  title: strings.nameSheetRenameTitle(name),
                  label: strings.nameSheetNameLabel,
                  confirm: strings.nameSheetRename,
                  action: (text, _) => GraphBookmarkRename(name, text),
                ),
              ),
            ),
            item(
              strings.bookmarkMenuMoveTo,
              identifier: 'bookmark-menu-move-to',
              onSelected: () => ask(
                GraphNameRequest(
                  title: strings.nameSheetMoveToTitle(name),
                  label: strings.nameSheetRevisionLabel,
                  confirm: strings.nameSheetMove,
                  action: (text, _) => GraphBookmarkMove(<String>[name], to: text),
                ),
              ),
            ),
            item(
              strings.bookmarkMenuDelete,
              identifier: 'bookmark-menu-delete',
              action: GraphBookmarkDelete(<String>[name]),
              danger: true,
            ),
          ],
        ),
      );
      continue;
    }
    if (remote == _gitRemote) {
      continue;
    }
    final bool? isTracked = bookmarks == null ? null : tracked(name, remote);
    if (bookmarks != null && isTracked == null) {
      // The read no longer knows it: nothing to track.
      continue;
    }
    final display = '$name@$remote'; // l10n-ignore: jj's symbol
    rows.add(
      item(
        display,
        mono: true,
        identifier: 'bookmark-menu-$display',
        reason: isTracked != null
            ? null
            : readFailed
            ? strings.bookmarkMenuReadFailed
            : strings.bookmarkMenuReading,
        submenu: <ZsMenuEntry>[
          if (isTracked ?? false)
            item(
              strings.bookmarksUntrack,
              identifier: 'bookmark-menu-untrack',
              action: GraphBookmarkUntrack(name, remote),
            )
          else
            item(strings.bookmarksTrack, identifier: 'bookmark-menu-track', action: GraphBookmarkTrack(name, remote)),
        ],
      ),
    );
  }
  return <ZsMenuEntry>[
    ...rows,
    if (rows.isNotEmpty) const ZsMenuSeparator(),
    item(
      strings.bookmarkMenuCreate,
      identifier: 'bookmark-menu-create',
      onSelected: () => ask(
        GraphNameRequest(
          title: strings.nameSheetCreateTitle,
          label: strings.nameSheetNameLabel,
          confirm: strings.nameSheetCreate,
          action: (text, id) => GraphBookmarkCreate(<String>[text], revision: id),
        ),
      ),
    ),
    item(
      strings.bookmarkMenuMoveHere,
      identifier: 'bookmark-menu-move-here',
      onSelected: () => ask(
        GraphNameRequest(
          title: strings.nameSheetMoveHereTitle,
          label: strings.nameSheetNameLabel,
          confirm: strings.nameSheetMove,
          action: (text, id) => GraphBookmarkMove(<String>[text], to: id),
        ),
      ),
    ),
  ];
}

/// A menu head's change id (decision 16.35): max(jj's unique prefix, 8) characters, the prefix bold, one `Text.rich`.
class GraphMenuId extends StatelessWidget {
  /// The id of [changeId] with its unique [prefix] length.
  const GraphMenuId({required this.changeId, required this.prefix, super.key});

  /// The full change id.
  final String changeId;

  /// jj's shortest unique prefix length.
  final int prefix;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    final int bold = prefix.clamp(0, changeId.length);
    final int shown = (bold > 8 ? bold : 8).clamp(0, changeId.length);
    final TextStyle style = ZsType.id.copyWith(fontSize: ZsType.fsMd, color: colors.textFaint);
    return Text.rich(
      TextSpan(
        style: style,
        children: <InlineSpan>[
          TextSpan(
            text: changeId.substring(0, bold),
            style: style.copyWith(
              fontWeight: FontWeight.w600,
              fontVariations: const <FontVariation>[FontVariation.weight(600)],
              color: colors.text,
            ),
          ),
          TextSpan(text: changeId.substring(bold, shown)),
        ],
      ),
      maxLines: 1,
    );
  }
}

/// Shows a [ZsMenuAnchor] at a card's anchor box while [open] names a key: the shared part of the card menu and the
/// bookmark popover hosts. The box comes from [anchor] (global), a zero-size one opening at the pointer; the menu's own
/// close (outside press, Esc, a row) clears [open], and [open] turning null closes the menu.
class _MenuHost extends StatefulWidget {
  const _MenuHost({
    required this.open,
    required this.anchor,
    required this.model,
    required this.build,
    required this.identifier,
    required this.semanticLabel,
    this.subject,
    this.onOpened,
  });

  final ValueNotifier<String?> open;
  final Rect? Function() anchor;
  final GraphViewModel model;
  final List<ZsMenuEntry> Function(BuildContext context, GraphLayout layout, int node) build;
  final String? Function(BuildContext context, GraphLayout layout, int node)? subject;
  final String identifier;
  final String semanticLabel;
  final ValueChanged<String>? onOpened;

  @override
  State<_MenuHost> createState() => _MenuHostState();
}

class _MenuHostState extends State<_MenuHost> {
  final _menu = ZsMenuController();
  String? _key;
  Rect? _box;
  var _atPointer = false;

  @override
  void initState() {
    super.initState();
    widget.open.addListener(_changed);
    if (widget.open.value != null) {
      // Remounted (the layout went and came back) while a menu was open: its anchor is gone.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _key == null) {
          widget.open.value = null;
        }
      });
    }
  }

  @override
  void didUpdateWidget(_MenuHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.open, widget.open)) {
      oldWidget.open.removeListener(_changed);
      widget.open.addListener(_changed);
    }
  }

  @override
  void dispose() {
    widget.open.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    final String? key = widget.open.value;
    if (key == null) {
      if (_menu.isOpen) {
        _menu.close();
      } else if (_key != null) {
        setState(() => _key = null);
      }
      return;
    }
    final Rect? anchor = widget.anchor();
    if (anchor == null) {
      // A key set without `openMenu` / `openBookmarks` (a test, the graph's own Esc state): nothing to show.
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      // Not laid out yet: try once more after this frame, so the controller never thinks a menu shows that does not.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || widget.open.value != key) {
          return;
        }
        final box = context.findRenderObject() as RenderBox?;
        if (box == null || !box.hasSize) {
          widget.open.value = null;
        } else {
          _changed();
        }
      });
      return;
    }
    setState(() {
      _key = key;
      _box = Rect.fromPoints(box.globalToLocal(anchor.topLeft), box.globalToLocal(anchor.bottomRight));
      _atPointer = anchor.isEmpty;
    });
    widget.onOpened?.call(key);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && widget.open.value == key) {
        _menu.open(position: _atPointer ? Offset.zero : null);
      }
    });
  }

  void _closed() {
    if (widget.open.value == _key) {
      widget.open.value = null;
    }
    if (mounted) {
      setState(() => _key = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final String? key = _key;
    final Rect? box = _box;
    return Stack(
      children: <Widget>[
        if (key != null && box != null)
          Positioned.fromRect(
            rect: box,
            child: ListenableBuilder(
              listenable: widget.model,
              builder: (context, _) {
                final GraphLayout? layout = widget.model.layout;
                final int? node = layout?.indexOfKey(key);
                if (node == null) {
                  // The change left the layout: nothing to act on.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (widget.open.value == key) {
                      widget.open.value = null;
                    }
                  });
                }
                return ListenableBuilder(
                  listenable: widget.model.content,
                  builder: (context, _) => ZsMenuAnchor(
                    controller: _menu,
                    entries: node == null ? const <ZsMenuEntry>[] : widget.build(context, layout!, node),
                    subject: node == null ? null : widget.subject?.call(context, layout!, node),
                    headLeading: node == null
                        ? null
                        : GraphMenuId(changeId: layout!.changeIdOf(node), prefix: layout.changeIdPrefixLengthOf(node)),
                    semanticLabel: widget.semanticLabel,
                    identifier: widget.identifier,
                    // A long id or bookmark name ends in an ellipsis rather than pushing the label out.
                    cmdMaxWidth: _cmdMaxWidth,
                    maxWidth: _menuMaxWidth,
                    onClose: _closed,
                    builder: (context, controller) => const SizedBox.expand(),
                  ),
                );
              },
            ),
          ),
      ],
    );
  }
}

/// The card menu (Story 10.15): `GraphCardController.menuOpen` and its anchor as a [ZsMenuAnchor] with
/// [graphCardMenuEntries]; every row runs through [model]'s runner, Describe… and Squash into parent through
/// [inspector].
class GraphCardMenuHost extends StatelessWidget {
  /// The menu of [cards]' open card in [model].
  const GraphCardMenuHost({required this.cards, required this.model, this.inspector, super.key});

  /// The graph's card controller.
  final GraphCardController cards;

  /// The graph's model.
  final GraphViewModel model;

  /// The inspector Describe… opens; without it the row is disabled.
  final InspectorViewModel? inspector;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    return _MenuHost(
      open: cards.menuOpen,
      anchor: () => cards.menuAnchor,
      model: model,
      identifier: 'card-menu',
      semanticLabel: strings.cardActions,
      subject: (context, layout, node) {
        if (node == layout.rootIndex) {
          return 'root()'; // l10n-ignore: jj's text
        }
        final GraphCommitContent? content = model.content.of(layout, node) ?? layout.contentOf(node);
        return content == null
            ? null
            : content.subject.isEmpty
            ? strings.cardMenuNoDescription
            : content.subject;
      },
      build: (context, layout, node) => graphCardMenuEntries(
        strings,
        layout,
        node,
        blocked: graphBlockedReason(strings, model),
        run: (action) => unawaited(model.run(action)),
        content: model.content,
        onDescribe: inspector?.describe,
        onSquash: inspector?.squash,
      ),
    );
  }
}

/// The thin bookmark popover (Story 10.15): `GraphCardController.bookmarksOpen` as a menu in the same material, with
/// [graphBookmarkMenuEntries]; each opening reads [bookmarks] for Track / Untrack, and Create / Rename / Move ask for a
/// name in a [GraphNameSheet] in the root overlay.
class GraphBookmarkMenuHost extends StatefulWidget {
  /// The popover of [cards]' open card in [model].
  const GraphBookmarkMenuHost({required this.cards, required this.model, this.bookmarks, super.key});

  /// The graph's card controller.
  final GraphCardController cards;

  /// The graph's model.
  final GraphViewModel model;

  /// `jj bookmark list --all-remotes`; without it remote rows stay "Reading bookmarks…".
  final Future<List<Bookmark>> Function()? bookmarks;

  @override
  State<GraphBookmarkMenuHost> createState() => _GraphBookmarkMenuHostState();
}

class _GraphBookmarkMenuHostState extends State<GraphBookmarkMenuHost> {
  final _portal = OverlayPortalController();
  List<Bookmark>? _read;
  var _readFailed = false;
  var _serial = 0;

  /// The sheet's request and the change it acts on, while it shows.
  ({GraphNameRequest request, String key, String short})? _ask;
  var _closing = false;

  Future<void> _load(String _) async {
    final int serial = ++_serial;
    setState(() {
      _read = null;
      _readFailed = false;
    });
    final Future<List<Bookmark>> Function()? read = widget.bookmarks;
    if (read == null) {
      return;
    }
    try {
      final List<Bookmark> rows = await read();
      if (mounted && serial == _serial) {
        setState(() => _read = rows);
      }
    } on Object catch (error, stack) {
      final String reason = error is ZanshinFfiException ? error.code : error.runtimeType.toString();
      _log.warning('bookmarks read failed: $reason', error, stack);
      if (mounted && serial == _serial) {
        setState(() => _readFailed = true);
      }
    }
  }

  void _askFor(String key, String short, GraphNameRequest request) {
    setState(() {
      _ask = (request: request, key: key, short: short);
      _closing = false;
    });
    _portal.show();
  }

  void _close() => setState(() => _closing = true);

  void _closed() {
    _portal.hide();
    setState(() => _ask = null);
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final GraphViewModel model = widget.model;
    return OverlayPortal(
      controller: _portal,
      overlayLocation: OverlayChildLocation.rootOverlay,
      overlayChildBuilder: (context) {
        final ({GraphNameRequest request, String key, String short})? ask = _ask;
        if (ask == null) {
          return const SizedBox.shrink();
        }
        return Positioned.fill(
          child: GraphNameSheet(
            request: ask.request,
            id: ask.short,
            closing: _closing,
            onClosed: _closed,
            onCancel: _close,
            onConfirm: (text) {
              unawaited(model.run(ask.request.action(text, ask.key)));
              _close();
            },
          ),
        );
      },
      child: _MenuHost(
        open: widget.cards.bookmarksOpen,
        anchor: () => widget.cards.bookmarksAnchor,
        model: model,
        identifier: 'bookmark-menu',
        semanticLabel: strings.bookmarkMenuLabel,
        onOpened: (key) => unawaited(_load(key)),
        build: (context, layout, node) => graphBookmarkMenuEntries(
          strings,
          layout,
          node,
          blocked: graphBlockedReason(strings, model),
          run: (action) => unawaited(model.run(action)),
          bookmarks: _read,
          readFailed: _readFailed,
          ask: (request) => _askFor(layout.keyOf(node), graphShortId(layout, node), request),
        ),
      ),
    );
  }
}

/// The name sheet (Story 10.15): a [ZsSheet] with the [request]'s title, one mono field focused at open, the live jj
/// command on [id] in a mono line, Cancel and the gold confirm (disabled while the field is empty); ↩ confirms, Esc
/// cancels.
class GraphNameSheet extends StatefulWidget {
  /// The sheet of [request].
  const GraphNameSheet({
    required this.request,
    required this.id,
    required this.onConfirm,
    required this.onCancel,
    this.closing = false,
    this.onClosed,
    super.key,
  });

  /// What the sheet asks for.
  final GraphNameRequest request;

  /// The change id the shown command names (the short id).
  final String id;

  /// Runs with the typed text.
  final ValueChanged<String> onConfirm;

  /// Runs on Cancel and Esc.
  final VoidCallback onCancel;

  /// Whether the sheet leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  @override
  State<GraphNameSheet> createState() => _GraphNameSheetState();
}

class _GraphNameSheetState extends State<GraphNameSheet> {
  final _text = ZsTextEditingController();
  final _focus = FocusNode(debugLabel: 'name sheet');

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _confirm() {
    final String text = _text.text.trim();
    if (text.isNotEmpty && !widget.closing) {
      widget.onConfirm(text);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final String text = _text.text.trim();
    return ZsSheet(
      semanticLabel: widget.request.title,
      onCancel: widget.onCancel,
      closing: widget.closing,
      onClosed: widget.onClosed,
      initialFocus: _focus,
      width: 420,
      child: Semantics(
        identifier: 'name-sheet',
        child: Padding(
          // ConfirmDialog's padding and rhythm (DS components/controls/controls.css:127).
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: <Widget>[
              Text(
                widget.request.title,
                style: ZsType.control.copyWith(
                  fontSize: ZsType.fsLg,
                  fontWeight: FontWeight.w600,
                  fontVariations: const <FontVariation>[FontVariation.weight(600)],
                  color: colors.text,
                ),
              ),
              ZsTextField(
                controller: _text,
                focusNode: _focus,
                mono: true,
                label: widget.request.label,
                identifier: 'name-sheet-field',
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _confirm(),
              ),
              Text(
                text.isEmpty ? ' ' : widget.request.action(text, widget.id).command,
                key: const ValueKey<String>('name-sheet-command'),
                style: ZsType.id.copyWith(color: colors.textMuted),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  spacing: 8,
                  children: <Widget>[
                    ZsButton(
                      label: strings.nameSheetCancel,
                      size: ZsButtonSize.md,
                      identifier: 'name-sheet-cancel',
                      onPressed: widget.onCancel,
                    ),
                    ZsButton(
                      label: widget.request.confirm,
                      size: ZsButtonSize.md,
                      variant: ZsButtonVariant.primary,
                      identifier: 'name-sheet-confirm',
                      onPressed: text.isEmpty ? null : _confirm,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
