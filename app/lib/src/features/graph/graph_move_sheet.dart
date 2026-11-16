// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart';

import '../../l10n/strings.dart';
import 'graph_card_menu.dart';
import 'graph_content.dart';
import 'graph_inspector.dart' show graphShortId;
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_search_field.dart' show graphSearchHighlight;

final _log = Logger('zanshin.graph.move');

/// jj's mirror of the colocated Git refs: not a remote a tag is published on.
const _gitRemote = 'git'; // l10n-ignore: jj's remote name

const _allowBackwards = '--allow-backwards'; // l10n-ignore: jj's flag
const _allowMove = '--allow-move'; // l10n-ignore: jj's flag

/// The move picker's action (Story 10.46): `jj tag set <name> -r <id> --allow-move` for a [tag], else
/// `jj bookmark move <name> --to <id> [--allow-backwards]`.
GraphAction graphMoveAction({
  required bool tag,
  required String name,
  required String id,
  bool allowBackwards = false,
}) => tag
    ? GraphTagSet(<String>[name], revision: id, allowMove: true)
    : GraphBookmarkMove(<String>[name], to: id, allowBackwards: allowBackwards);

/// A check per bookmark name: `done` once the preview answered, `check` its answer (null: unknown).
typedef _CheckState = ({bool done, GraphMoveCheck? check});

/// The move picker of "Move existing here…" (Story 10.46): a [ZsSheet] 500 wide with a mono field that filters the
/// existing local bookmarks (or tags when [tag]) read through [read], each row with its current change; ↑ ↓ move the
/// keyboard row, ↩ confirms. A bookmark row that is not a fast-forward ([drops]' preview, [graphBookmarkMoveCheck])
/// carries a backwards or sideways pill and needs the `--allow-backwards` switch; a refused one shows jj's reason. A tag
/// on a remote warns that it is published. [onConfirm] gets the action on [targetKey]; the command line shows it on
/// [short].
class GraphMoveSheet extends StatefulWidget {
  /// The picker moving a bookmark (or a tag when [tag]) to [targetKey].
  const GraphMoveSheet({
    required this.tag,
    required this.targetKey,
    required this.short,
    required this.onConfirm,
    required this.onCancel,
    this.layout,
    this.content,
    this.drops,
    this.read,
    this.closing = false,
    this.onClosed,
    super.key,
  });

  /// Whether it moves a tag.
  final bool tag;

  /// The node key of the change the ref moves to.
  final String targetKey;

  /// That change's id as a command shows it.
  final String short;

  /// The graph's layout, for the rows' current changes and the moves' direction.
  final GraphLayout? layout;

  /// The card content, for the rows' subjects.
  final GraphContent? content;

  /// The bookmark move preview; without it no move is checked.
  final GraphDrops? drops;

  /// `jj bookmark list --all-remotes` (or the tags in its shape); without it the list stays reading.
  final Future<List<Bookmark>> Function()? read;

  /// Runs with the picked move.
  final ValueChanged<GraphAction> onConfirm;

  /// Runs on Cancel and Esc.
  final VoidCallback onCancel;

  /// Whether the sheet leaves.
  final bool closing;

  /// Runs once the exit completes.
  final VoidCallback? onClosed;

  @override
  State<GraphMoveSheet> createState() => _GraphMoveSheetState();
}

class _GraphMoveSheetState extends State<GraphMoveSheet> {
  final _text = ZsTextEditingController();
  final _focus = FocusNode(debugLabel: 'move sheet');
  final _list = ZsFieldListController();
  final _scroll = ScrollController();
  final _checks = <String, _CheckState>{};
  final _rowKeys = <String, GlobalKey>{};
  List<Bookmark>? _rows;
  var _failed = false;
  var _allow = false;

  @override
  void initState() {
    super.initState();
    _attach();
    _list.addListener(_listChanged);
    unawaited(_load());
  }

  @override
  void dispose() {
    _list.removeListener(_listChanged);
    _list.dispose();
    _scroll.dispose();
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final Future<List<Bookmark>> Function()? read = widget.read;
    if (read == null) {
      return;
    }
    try {
      final List<Bookmark> rows = await read();
      if (mounted) {
        setState(() => _rows = rows);
        _attach();
      }
    } on Object catch (error, stack) {
      final String reason = error is ZanshinFfiException ? error.code : error.runtimeType.toString();
      _log.warning('${widget.tag ? 'tags' : 'bookmarks'} read for the move picker failed: $reason', error, stack);
      if (mounted) {
        setState(() => _failed = true);
      }
    }
  }

  void _listChanged() {
    if (!_list.attached) {
      // The field's first Esc detaches the list; for a sheet it is the cancel.
      widget.onCancel();
      return;
    }
    setState(() {});
    final int active = _list.active;
    final List<Bookmark> rows = _matches();
    if (active < 0 || active >= rows.length) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) {
        return;
      }
      final BuildContext? row = _rowKeys[rows[active].name]?.currentContext;
      if (row != null) {
        Scrollable.ensureVisible(row, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtEnd);
        Scrollable.ensureVisible(row, alignmentPolicy: ScrollPositionAlignmentPolicy.keepVisibleAtStart);
      } else {
        // Not built (a wrap or Home / End far away): the list's ends are the only rows that far.
        _scroll.jumpTo(active == 0 ? 0 : _scroll.position.maxScrollExtent);
      }
    });
  }

  /// (Re)attaches the list with the keyboard row on [active] (the first row by default).
  void _attach({int active = 0}) {
    final int count = _matches().length;
    _list.attach(count: count, active: count == 0 ? -1 : active, onActivate: (_) => _confirm());
  }

  /// This change's change id: a ref already on it moves nowhere.
  String get _ownChangeId {
    final GraphLayout? layout = widget.layout;
    final int? node = layout?.indexOfKey(widget.targetKey);
    return layout == null || node == null ? widget.targetKey : layout.changeIdOf(node);
  }

  /// The local refs that could move here, in the read's order.
  List<Bookmark> _candidates() {
    final String own = _ownChangeId;
    return <Bookmark>[
      for (final Bookmark row in _rows ?? const <Bookmark>[])
        if (row.kind is LocalBookmark && row.target != null && row.target != own) row,
    ];
  }

  List<Bookmark> _matches() {
    final String query = _text.text.toLowerCase();
    return <Bookmark>[
      for (final Bookmark row in _candidates())
        if (row.name.toLowerCase().contains(query)) row,
    ];
  }

  Bookmark? _picked() {
    final List<Bookmark> rows = _matches();
    final int active = _list.active;
    return active >= 0 && active < rows.length ? rows[active] : null;
  }

  /// The bookmark [row]'s check, asked once per name for the sheet's life; null without [GraphMoveSheet.drops].
  _CheckState? _checkOf(Bookmark row) {
    final GraphDrops? drops = widget.drops;
    if (widget.tag || drops == null) {
      return null;
    }
    final String name = row.name;
    final _CheckState? known = _checks[name];
    if (known != null) {
      return known;
    }
    const _CheckState pending = (done: false, check: null);
    _checks[name] = pending;
    unawaited(
      graphBookmarkMoveCheck(drops, widget.layout, name: name, from: row.target!, to: widget.targetKey).then((check) {
        if (mounted) {
          setState(() => _checks[name] = (done: true, check: check));
        }
      }),
    );
    return pending;
  }

  /// Whether the move a check [state] answered needs `--allow-backwards`.
  bool _needed(_CheckState? state) {
    final GraphMoveCheck? check = state?.check;
    return check != null && check.refusal == null && check.direction != GraphMoveDirection.forward;
  }

  GraphAction _action(Bookmark row, String id) => graphMoveAction(
    tag: widget.tag,
    name: row.name,
    id: id,
    allowBackwards: !widget.tag && _needed(_checkOf(row)) && _allow,
  );

  /// Why Move is off for [row], as `(text, warn)`; null when it may run.
  ({String text, bool warn})? _blocked(AppLocalizations strings, Bookmark row) {
    if (widget.tag) {
      return null;
    }
    final _CheckState? state = _checkOf(row);
    if (state == null) {
      return null;
    }
    if (!state.done) {
      return (text: '', warn: false);
    }
    final GraphMoveCheck? check = state.check;
    if (check?.refusal case final String refusal) {
      return (text: refusal, warn: false);
    }
    if (_needed(state) && !_allow) {
      return (text: strings.moveSheetBlocked(strings.moveSheetDirection(check!.direction.name)), warn: true);
    }
    return null;
  }

  void _confirm() {
    final Bookmark? row = _picked();
    if (row == null || widget.closing || _blocked(context.l10n, row) != null) {
      return;
    }
    widget.onConfirm(_action(row, widget.targetKey));
  }

  /// The first remote (not `git`) that holds the tag [name].
  String? _publishedOn(String name) {
    for (final Bookmark row in _rows ?? const <Bookmark>[]) {
      if (row.kind case RemoteBookmark(:final String remoteName)
          when row.name == name && remoteName != _gitRemote && row.target != null) {
        return remoteName;
      }
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final AppLocalizations strings = context.l10n;
    final ZsColors colors = ZsColors.of(context);
    final List<Bookmark> rows = _matches();
    final Bookmark? picked = _picked();
    final ({String text, bool warn})? blocked = picked == null ? null : _blocked(strings, picked);
    final String title = widget.tag ? strings.nameSheetMoveTagHereTitle : strings.nameSheetMoveHereTitle;
    final String label = widget.tag ? strings.nameSheetTagNameLabel : strings.nameSheetNameLabel;
    final TextStyle note = ZsType.body.copyWith(fontSize: ZsType.fsSm, height: 1.4, color: colors.textDim);
    final String? publishedOn = widget.tag && picked != null ? _publishedOn(picked.name) : null;
    return ZsSheet(
      semanticLabel: title,
      onCancel: widget.onCancel,
      closing: widget.closing,
      onClosed: widget.onClosed,
      initialFocus: _focus,
      width: 500,
      child: Semantics(
        identifier: 'move-sheet',
        child: Padding(
          // The name sheet's padding and rhythm.
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 10,
            children: <Widget>[
              Text(
                title,
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
                label: label,
                placeholder: label,
                fieldList: _list,
                identifier: 'move-sheet-field',
                // The keyboard row starts on the first row after every query change.
                onChanged: (_) => _attach(),
                onSubmitted: (_) => _confirm(),
              ),
              _listWell(context, strings, rows),
              if (!widget.tag)
                Row(
                  spacing: 10,
                  children: <Widget>[
                    ZsSwitch(
                      value: _allow,
                      label: strings.moveSheetAllowBackwards,
                      identifier: 'move-sheet-allow',
                      onChanged: (value) => setState(() => _allow = value),
                    ),
                    // The switch's visible label: a click toggles it; VoiceOver reads the switch's own label.
                    Flexible(
                      child: ExcludeSemantics(
                        child: GestureDetector(
                          key: const ValueKey<String>('move-sheet-allow-label'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => setState(() => _allow = !_allow),
                          child: Row(
                            spacing: 10,
                            children: <Widget>[
                              Flexible(
                                child: Text(
                                  strings.moveSheetAllowBackwards,
                                  style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.textMuted),
                                ),
                              ),
                              Text(_allowBackwards, style: ZsType.id.copyWith(color: colors.textMuted)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              else if (picked != null && publishedOn != null)
                Text(
                  strings.moveSheetPublished(picked.name, publishedOn),
                  key: const ValueKey<String>('move-sheet-published'),
                  style: note.copyWith(color: colors.warn),
                )
              else
                Text(
                  strings.moveSheetTagNote(_allowMove),
                  key: const ValueKey<String>('move-sheet-note'),
                  style: note,
                ),
              Text(
                picked == null ? ' ' : _action(picked, widget.short).command,
                key: const ValueKey<String>('move-sheet-command'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ZsType.id.copyWith(color: colors.textMuted),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Row(
                  spacing: 8,
                  children: <Widget>[
                    Expanded(
                      child: blocked == null || blocked.text.isEmpty
                          ? const SizedBox.shrink()
                          : Text(
                              blocked.text,
                              key: const ValueKey<String>('move-sheet-reason'),
                              style: note.copyWith(color: blocked.warn ? colors.warn : colors.rem),
                            ),
                    ),
                    ZsButton(
                      label: strings.nameSheetCancel,
                      size: ZsButtonSize.md,
                      identifier: 'move-sheet-cancel',
                      onPressed: widget.onCancel,
                    ),
                    ZsButton(
                      label: strings.nameSheetMove,
                      size: ZsButtonSize.md,
                      variant: ZsButtonVariant.primary,
                      identifier: 'move-sheet-confirm',
                      onPressed: picked == null || blocked != null ? null : _confirm,
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

  /// The rows in a quiet well (DS search rows; the study's `.rs-plist`), or the one line saying why there are none.
  Widget _listWell(BuildContext context, AppLocalizations strings, List<Bookmark> rows) {
    final ZsColors colors = ZsColors.of(context);
    final String? empty = rows.isNotEmpty
        ? null
        : _failed
        ? (widget.tag ? strings.tagMenuReadFailed : strings.bookmarkMenuReadFailed)
        : _rows == null
        ? (widget.tag ? strings.tagMenuReading : strings.bookmarkMenuReading)
        : _candidates().isEmpty
        ? strings.moveSheetNothing(widget.tag ? 'tag' : 'bookmark') // l10n-ignore: select keys
        : (widget.tag ? strings.tagsNoMatch(_text.text) : strings.bookmarksNoMatch(_text.text));
    return DecoratedBox(
      decoration: BoxDecoration(color: colors.flHover, borderRadius: BorderRadius.circular(10)),
      child: Padding(
        padding: const EdgeInsets.all(4),
        child: empty != null
            ? Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                child: Text(
                  empty,
                  key: const ValueKey<String>('move-sheet-empty'),
                  style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.textDim),
                ),
              )
            : ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 200),
                child: ListView.builder(
                  controller: _scroll,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  itemCount: rows.length,
                  itemBuilder: (context, i) => _row(context, strings, rows[i], active: i == _list.active, index: i),
                ),
              ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    AppLocalizations strings,
    Bookmark row, {
    required bool active,
    required int index,
  }) {
    final ZsColors colors = ZsColors.of(context);
    final String query = _text.text;
    final int at = query.isEmpty ? -1 : row.name.toLowerCase().indexOf(query.toLowerCase());
    final GraphMoveCheck? check = _checkOf(row)?.check;
    final GraphLayout? layout = widget.layout;
    final String target = row.target!;
    final int? node = layout?.indexOfKey(target);
    final String id = layout != null && node != null
        ? graphShortId(layout, node)
        : target.substring(0, target.length < 8 ? target.length : 8);
    final String subject = layout != null && node != null
        ? (widget.content?.of(layout, node) ?? layout.contentOf(node))?.subject ?? ''
        : '';
    return ZsFieldListRow(
      key: _rowKeys.putIfAbsent(row.name, GlobalKey.new),
      active: active,
      icon: widget.tag ? ZI.tag : ZI.bookmark,
      identifier: 'move-sheet-row-${row.name}',
      onPressed: () => _attach(active: index),
      child: Row(
        spacing: 10,
        children: <Widget>[
          Expanded(
            child: graphSearchHighlight(
              colors,
              row.name,
              at < 0 ? null : (at, at + query.length),
              ZsType.id.copyWith(fontSize: ZsType.fsMd, color: colors.text),
            ),
          ),
          if (check != null && check.refusal == null && check.direction != GraphMoveDirection.forward)
            ZsTooltip(
              message: strings.moveSheetDirectionTooltip(_allowBackwards),
              child: _WarnPill(strings.moveSheetDirection(check.direction.name)),
            ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(
              strings.moveSheetNowOn(id, subject).trimRight(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: ZsType.body.copyWith(fontSize: ZsType.fsMd, color: colors.textFaint),
            ),
          ),
        ],
      ),
    );
  }
}

/// The search's small tag (DS search.css:72) in the warn colours: a move that needs `--allow-backwards`.
class _WarnPill extends StatelessWidget {
  const _WarnPill(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    final ZsColors colors = ZsColors.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.warnBg,
        borderRadius: BorderRadius.circular(ZsMetrics.of(context).radiusTag),
      ),
      child: SizedBox(
        height: 18,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Center(
            widthFactor: 1,
            child: Text(
              label,
              style: ZsType.body.copyWith(fontSize: ZsType.fsSm, height: 1, color: colors.warn),
            ),
          ),
        ),
      ),
    );
  }
}
