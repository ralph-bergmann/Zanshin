// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';
import 'package:zanshin_ui/zanshin_ui.dart' show ZI;

import '../../l10n/strings.dart';
import 'graph_ports.dart';

final _log = Logger('zanshin.graph.drag');

/// A drag starts after this much travel from a press (Story 10.10); the 4 px tap slop has swallowed the click by then.
const double graphDropDragThreshold = 5;

/// The preview query waits this long after the target changes (Story 10.10).
const graphDropDebounce = Duration(milliseconds: 60);

/// A rest on a target this long opens the drop menu (Story 10.10; epics.md, the 2026-10-14 note).
const graphDropMenuDelay = Duration(milliseconds: 260);

/// The dragged card's opacity while the drag runs (Story 10.10).
const graphDragSourceOpacity = .35;

/// The ghost's offset from the pointer (DS components/overlays/DragGhost.prompt.md:10).
const graphGhostOffset = Offset(14, 12);

/// What is dragged (Story 10.10).
@immutable
sealed class GraphDragPayload {
  const GraphDragPayload();

  /// The preview's source.
  DropSource get source;

  /// The dragged card's key; null for a bookmark.
  String? get key;
}

/// A change card: its [key] (the change id, a hidden or divergent one's commit id), what the ghost shows, and the
/// [short] id a command shows.
final class GraphChangeDrag extends GraphDragPayload {
  /// A dragged change.
  const GraphChangeDrag({
    required this.key,
    required this.changeId,
    required this.prefix,
    required this.short,
    this.subject = '',
    this.workingCopy = false,
  });

  @override
  final String key;

  /// The full change id.
  final String changeId;

  /// jj's shortest unique prefix length.
  final int prefix;

  /// The id as a command shows it (`graphShortId`).
  final String short;

  /// The subject, '' while unknown.
  final String subject;

  /// Whether it is the working copy.
  final bool workingCopy;

  @override
  DropSource get source => ChangeDropSource(key);

  @override
  bool operator ==(Object other) => other is GraphChangeDrag && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

/// A local bookmark, by [name].
final class GraphBookmarkDrag extends GraphDragPayload {
  /// A dragged bookmark.
  const GraphBookmarkDrag(this.name);

  /// The bookmark's name.
  final String name;

  @override
  String? get key => null;

  @override
  DropSource get source => BookmarkDropSource(name);

  @override
  bool operator ==(Object other) => other is GraphBookmarkDrag && other.name == name;

  @override
  int get hashCode => name.hashCode;
}

/// Whether a bookmark ref drags (Story 10.10): local, its name without `@`.
bool graphBookmarkDraggable(String name, {String? remote}) => remote == null && !name.contains('@');

/// One of the drop menu's eight rows, in their fixed order.
enum GraphDropKind {
  /// `jj rebase -s S -o T`.
  moveHere,

  /// `jj rebase -r S -o T`.
  moveOnly,

  /// `jj rebase -r S -A T`.
  insertAfter,

  /// `jj rebase -r S -B T`.
  insertBefore,

  /// `jj squash --from S --into T`.
  squash,

  /// `jj new T S`.
  newMerge,

  /// `jj duplicate S -o T`.
  duplicate,

  /// `jj bookmark move N --to T`.
  bookmark,
}

/// The drop menu's groups, separated by hairlines.
enum GraphDropGroup {
  /// Move here, Move only this change.
  move,

  /// Insert after, Insert before.
  place,

  /// Squash, New merge change.
  combine,

  /// Duplicate here.
  copy,

  /// Move N here.
  bookmark,
}

/// One Available row of the drop menu (Story 10.10): its [kind], the full [command] (short ids) and the [action]
/// (node keys) it runs; a bookmark row's [name] and its [backwards] note.
@immutable
class GraphDropRow {
  /// A row.
  const GraphDropRow({
    required this.kind,
    required this.command,
    required this.action,
    this.name,
    this.backwards = false,
  });

  /// Which row.
  final GraphDropKind kind;

  /// The full jj command, shell-quoted.
  final String command;

  /// What the runner runs.
  final GraphAction action;

  /// A bookmark row's bookmark.
  final String? name;

  /// A bookmark row whose move is not a fast-forward (`--allow-backwards`): the ghost's warning names its effect.
  final bool backwards;

  /// Its group.
  GraphDropGroup get group => switch (kind) {
    GraphDropKind.moveHere || GraphDropKind.moveOnly => GraphDropGroup.move,
    GraphDropKind.insertAfter || GraphDropKind.insertBefore => GraphDropGroup.place,
    GraphDropKind.squash || GraphDropKind.newMerge => GraphDropGroup.combine,
    GraphDropKind.duplicate => GraphDropGroup.copy,
    GraphDropKind.bookmark => GraphDropGroup.bookmark,
  };

  /// Its glyph (a `ZI` name).
  String get glyph => switch (kind) {
    GraphDropKind.moveHere => ZI.moveOnto,
    GraphDropKind.moveOnly => ZI.moveOnly,
    GraphDropKind.insertAfter => ZI.insertAfter,
    GraphDropKind.insertBefore => ZI.insertBefore,
    GraphDropKind.squash => ZI.squashInto,
    GraphDropKind.newMerge => ZI.merge,
    GraphDropKind.duplicate => ZI.duplicate,
    GraphDropKind.bookmark => ZI.bookmark,
  };

  /// The short verb in the right column (DS DropMenu.prompt.md:5-7).
  String get short => switch (kind) {
    GraphDropKind.moveHere => 'rebase -s', // l10n-ignore: jj command
    GraphDropKind.moveOnly => 'rebase -r', // l10n-ignore: jj command
    GraphDropKind.insertAfter => 'rebase -A', // l10n-ignore: jj command
    GraphDropKind.insertBefore => 'rebase -B', // l10n-ignore: jj command
    GraphDropKind.squash => 'squash', // l10n-ignore: jj command
    GraphDropKind.newMerge => 'new', // l10n-ignore: jj command
    GraphDropKind.duplicate => 'duplicate', // l10n-ignore: jj command
    GraphDropKind.bookmark => 'bookmark move', // l10n-ignore: jj command
  };

  /// Its label.
  String label(AppLocalizations s) => switch (kind) {
    GraphDropKind.moveHere => s.dropMoveHere,
    GraphDropKind.moveOnly => s.dropMoveOnly,
    GraphDropKind.insertAfter => s.dropInsertAfter,
    GraphDropKind.insertBefore => s.dropInsertBefore,
    GraphDropKind.squash => s.dropSquash,
    GraphDropKind.newMerge => s.dropNewMerge,
    GraphDropKind.duplicate => s.dropDuplicate,
    GraphDropKind.bookmark => s.dropMoveBookmark(name ?? ''),
  };
}

/// The preview of one target: its Available rows in the fixed order, and the first refusal's text (`context ?? code`)
/// among the eight when none is Available.
typedef GraphDropPreview = ({List<GraphDropRow> rows, String? refusal});

/// The location indices of the one query per target.
const _onto = 0;
const _after = 1;
const _before = 2;

/// The locations of the one query per target [t]: `-o T`, `-A T`, `-B T`.
List<DropLocation> graphDropLocations(String t) => <DropLocation>[
  DropLocation(onto: <String>[t]),
  DropLocation(insertAfter: <String>[t]),
  DropLocation(insertBefore: <String>[t]),
];

/// [actions]' rows for [payload] dropped on [targetKey] (shown as [targetShort]): only the eight drop rows, only the
/// Available ones, in the fixed order (Story 10.10).
GraphDropPreview graphDropRows(
  GraphDragPayload payload, {
  required String targetKey,
  required String targetShort,
  required DropActions actions,
}) {
  final outcomes = <GraphDropKind, ActionOutcome>{};
  for (final DropAction a in actions.actions) {
    final GraphDropKind? kind = switch ((payload, a.verb, a.location)) {
      (GraphChangeDrag(), DropVerb.rebaseSource, _onto) => GraphDropKind.moveHere,
      (GraphChangeDrag(), DropVerb.rebaseRevisions, _onto) => GraphDropKind.moveOnly,
      (GraphChangeDrag(), DropVerb.rebaseRevisions, _after) => GraphDropKind.insertAfter,
      (GraphChangeDrag(), DropVerb.rebaseRevisions, _before) => GraphDropKind.insertBefore,
      (GraphChangeDrag(), DropVerb.squash, _onto) => GraphDropKind.squash,
      (GraphChangeDrag(), DropVerb.newMerge, _onto) => GraphDropKind.newMerge,
      (GraphChangeDrag(), DropVerb.duplicate, _onto) => GraphDropKind.duplicate,
      (GraphBookmarkDrag(), DropVerb.bookmarkMove, _onto) => GraphDropKind.bookmark,
      _ => null,
    };
    if (kind != null) {
      outcomes.putIfAbsent(kind, () => a.outcome);
    }
  }
  final rows = <GraphDropRow>[];
  String? refusal;
  for (final GraphDropKind kind in GraphDropKind.values) {
    final ActionOutcome? outcome = outcomes[kind];
    if (outcome == null) {
      continue;
    }
    if (outcome.status == ActionStatus.refused) {
      final ActionRefusal? r = outcome.refusal;
      refusal ??= r == null ? null : r.context ?? r.code;
      continue;
    }
    if (outcome.status != ActionStatus.available) {
      continue;
    }
    final ({GraphAction run, GraphAction shown}) action = switch (payload) {
      GraphChangeDrag(:final key, :final short) => _changeAction(kind, key, targetKey, short, targetShort),
      GraphBookmarkDrag(:final name) => (
        run: GraphBookmarkMove(<String>[name], to: targetKey, allowBackwards: outcome.allowBackwardsNeeded),
        shown: GraphBookmarkMove(<String>[name], to: targetShort, allowBackwards: outcome.allowBackwardsNeeded),
      ),
    };
    rows.add(
      GraphDropRow(
        kind: kind,
        command: action.shown.command,
        action: action.run,
        name: payload is GraphBookmarkDrag ? payload.name : null,
        backwards: outcome.allowBackwardsNeeded,
      ),
    );
  }
  return (rows: rows, refusal: rows.isEmpty ? refusal : null);
}

({GraphAction run, GraphAction shown}) _changeAction(
  GraphDropKind kind,
  String s,
  String t,
  String sShort,
  String tShort,
) {
  GraphAction of(String s, String t) => switch (kind) {
    GraphDropKind.moveHere => GraphRebase(source: <String>[s], onto: <String>[t]),
    GraphDropKind.moveOnly => GraphRebase(revisions: <String>[s], onto: <String>[t]),
    GraphDropKind.insertAfter => GraphRebase(revisions: <String>[s], insertAfter: <String>[t]),
    GraphDropKind.insertBefore => GraphRebase(revisions: <String>[s], insertBefore: <String>[t]),
    GraphDropKind.squash => GraphSquash(from: <String>[s], into: t),
    GraphDropKind.newMerge => GraphNew(parents: <String>[t, s]),
    GraphDropKind.duplicate => GraphDuplicate(revisions: <String>[s], onto: <String>[t]),
    GraphDropKind.bookmark => throw StateError('a change drag has no bookmark row'),
  };
  return (run: of(s, t), shown: of(sShort, tShort));
}

/// The index of the default row of [rows]: the first, or "Move only this change" while [alt] holds and it is there.
int graphDropDefault(List<GraphDropRow> rows, {required bool alt}) {
  if (alt) {
    final int only = rows.indexWhere((r) => r.kind == GraphDropKind.moveOnly);
    if (only >= 0) {
      return only;
    }
  }
  return 0;
}

/// Where a dropped change came from, viewport-local: the card `key` that glides from `rect` (null: none glides), and
/// the rect a born change grows from (Story 10.10).
typedef GraphDropOrigin = ({String? key, Rect rect});

/// One graph drag (Story 10.10): the [payload] under the pointer, the target card and its previewed rows, the drop
/// menu, ⌥ and ↑/↓, Esc, and the drop's verb.
///
/// The preview is one `dropActions` query per target ([graphDropLocations]), debounced [graphDropDebounce] after the
/// target changes, at most one in flight, cached per (source, target) for the layout's operation. For a change drag the
/// menu opens after [graphDropMenuDelay] on a target with rows; a bookmark drag never opens it (its one row runs, a
/// backwards one too). A bookmark release on a target runs its row; a change release runs the highlighted row (the
/// default — ⌥'s state when the menu opens picks it — unless ↑/↓ or the menu's pointer moved it) only once the menu is
/// open; any other release cancels. [holding] stays true while the drag runs and until its verb finished: the view
/// model holds reloads meanwhile.
class GraphDrag extends ChangeNotifier {
  /// A drag controller; the view model wires it in `init`.
  GraphDrag();

  /// The preview port; null previews nothing (every target stays un-highlighted).
  GraphDrops? drops;

  /// The shown layout's operation id: the cache key.
  String? Function() operationId = () => null;

  /// The short id of a target key as a command shows it.
  String Function(String key) shortOf = (key) => key;

  /// Whether a drag may start (the actions are enabled).
  bool Function() enabled = () => true;

  /// Runs a row's action with the drop origin.
  Future<GraphActionResult> Function(GraphAction action, GraphDropOrigin? origin)? run;

  /// Called each time the pointer settles on a target whose bookmark row is backwards: the ghost's warning is
  /// excluded from semantics, so the canvas announces it; set by the canvas.
  void Function()? onBackwards;

  /// Maps a global rect into the graph viewport's coordinates; set by the canvas, null outside one.
  Rect? Function(Rect global)? toViewport;

  /// The ghost chip's key (`ZsDragGhost.chipKey`, the chip without its words): its rect is the drop origin.
  final GlobalKey ghostKey = GlobalKey(debugLabel: 'graph-drag-ghost');

  GraphDragPayload? _payload;
  Offset _pointer = Offset.zero;
  String? _target;
  GraphDropPreview? _preview;
  var _menu = false;
  var _highlight = 0;
  var _arrowed = false;
  var _alt = false;
  var _overMenu = false;
  var _running = false;
  Offset? _dropPoint;
  Timer? _debounce;
  Timer? _menuTimer;
  var _inFlight = false;
  var _disposed = false;
  final _cache = <(GraphDragPayload, String), GraphDropPreview>{};
  String? _cacheOperation;

  /// What is dragged; null without a drag (also while the verb shows its ghost).
  GraphDragPayload? get payload => _payload;

  /// Whether a pointer drag is in progress.
  bool get active => _payload != null && !_running;

  /// Whether the drag or its verb runs: reloads wait.
  bool get holding => _payload != null || _running;

  /// Whether the drop's verb runs.
  bool get running => _running;

  /// The pointer, global.
  Offset get pointer => _pointer;

  /// Where the ghost stays while the verb runs; null otherwise.
  Offset? get dropPoint => _dropPoint;

  /// What the ghost shows: the payload during the drag and while the drop's verb runs (at [dropPoint]); null hides it.
  GraphDragPayload? get ghost => _payload ?? _dropped;
  GraphDragPayload? _dropped;

  /// The card under the pointer that takes the drag (stays while the pointer is over the open menu).
  String? get target => _target;

  /// The highlighted target: a target whose rows are known and not empty.
  String? get highlightedTarget => (_preview?.rows.isNotEmpty ?? false) ? _target : null;

  /// The target's Available rows; null while unknown.
  List<GraphDropRow>? get rows => _preview?.rows;

  /// The target's first refusal when it has no Available row.
  String? get refusal => _preview?.refusal;

  /// Whether the drop menu shows.
  bool get menuOpen => _menu;

  /// The highlighted row's index.
  int get highlight => _highlight;

  /// Whether ⌥ is held.
  bool get alt => _alt;

  /// Whether the pointer is over the open menu.
  bool get overMenu => _overMenu;

  /// The default row's index.
  int get defaultIndex => graphDropDefault(_preview?.rows ?? const <GraphDropRow>[], alt: _alt);

  /// The row a release would run, or null.
  GraphDropRow? get highlightedRow {
    final List<GraphDropRow>? rows = _preview?.rows;
    return rows == null || rows.isEmpty ? null : rows[_highlight.clamp(0, rows.length - 1)];
  }

  /// Starts a drag of [payload] at [global]; false (and nothing starts) while the actions are disabled or another drag
  /// runs.
  bool start(GraphDragPayload payload, Offset global) {
    if (_payload != null || _running || !enabled()) {
      return false;
    }
    _payload = payload;
    _pointer = global;
    _alt = HardwareKeyboard.instance.isAltPressed;
    HardwareKeyboard.instance.addHandler(_onKey);
    // The mouse's moves and release reach the drag whatever happens to its source (a popover row closes at the start).
    GestureBinding.instance.pointerRouter.addGlobalRoute(_onPointer);
    _routed = true;
    notifyListeners();
    return true;
  }

  var _routed = false;

  void _onPointer(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) {
      return;
    }
    switch (event) {
      case PointerMoveEvent():
        move(event.position);
      case PointerUpEvent():
        unawaited(drop());
      case PointerCancelEvent():
        cancel();
      default:
        break;
    }
  }

  void _unroute() {
    if (_routed) {
      _routed = false;
      GestureBinding.instance.pointerRouter.removeGlobalRoute(_onPointer);
    }
  }

  /// The pointer moved to [global]; the canvas resolves the target from it.
  void move(Offset global) {
    if (!active) {
      return;
    }
    _pointer = global;
    notifyListeners();
  }

  /// The canvas's target resolution: [key] under the pointer (null for none), [menuRow] the open menu's row under it
  /// (-1 over the menu but between rows, null outside the menu).
  void hover(String? key, {int? menuRow}) {
    if (!active) {
      return;
    }
    final bool overMenu = _menu && menuRow != null;
    var changed = overMenu != _overMenu;
    if (overMenu) {
      if (menuRow >= 0 && menuRow != _highlight) {
        _highlight = menuRow;
        _arrowed = true;
        changed = true;
      }
    } else if (key != _target) {
      _setTarget(key);
      changed = true;
    }
    _overMenu = overMenu;
    if (changed) {
      notifyListeners();
    }
  }

  void _setTarget(String? key) {
    _target = key;
    _menu = false;
    _overMenu = false;
    _arrowed = false;
    _menuTimer?.cancel();
    _menuTimer = null;
    _debounce?.cancel();
    _debounce = null;
    _preview = key == null ? null : _cached(key);
    _highlight = defaultIndex;
    if (key == null) {
      return;
    }
    if (_preview == null) {
      _debounce = Timer(graphDropDebounce, _fetch);
    } else {
      _armMenu();
      _warnBackwards();
    }
  }

  // A target's preview becomes known once per target (cached above or fetched), so this fires once per arrival on a target.
  void _warnBackwards() {
    if (_payload is GraphBookmarkDrag && (highlightedRow?.backwards ?? false)) {
      onBackwards?.call();
    }
  }

  GraphDropPreview? _cached(String key) {
    final String? op = operationId();
    if (op != _cacheOperation) {
      _cache.clear();
      _cacheOperation = op;
    }
    return _cache[(_payload!, key)];
  }

  void _armMenu() {
    // A bookmark target has one row: the release runs it, no menu.
    if (_payload is GraphChangeDrag && (_preview?.rows.isNotEmpty ?? false)) {
      _menuTimer = Timer(graphDropMenuDelay, () {
        _menuTimer = null;
        if (active && _target != null) {
          _menu = true;
          _highlight = _arrowed ? _highlight : defaultIndex;
          notifyListeners();
        }
      });
    }
  }

  Future<void> _fetch() async {
    _debounce = null;
    final GraphDrops? drops = this.drops;
    final GraphDragPayload? payload = _payload;
    final String? key = _target;
    if (drops == null || payload == null || key == null || _preview != null || _inFlight) {
      return;
    }
    _inFlight = true;
    final String? op = operationId();
    GraphDropPreview? preview;
    try {
      final DropActions actions = await drops.dropActions(payload.source, graphDropLocations(key));
      preview = graphDropRows(payload, targetKey: key, targetShort: shortOf(key), actions: actions);
      if (op == operationId()) {
        if (op != _cacheOperation) {
          _cache.clear();
          _cacheOperation = op;
        }
        _cache[(payload, key)] = preview;
      }
    } on Object catch (error) {
      // Swallowed: the target stays un-highlighted and the words keep the hint.
      _log.fine('drop preview failed: ${error is ZanshinFfiException ? error.code : error.runtimeType}');
      preview = (rows: const <GraphDropRow>[], refusal: null);
    } finally {
      _inFlight = false;
    }
    if (_disposed) {
      return;
    }
    if (identical(payload, _payload) && _target == key) {
      if (op != operationId()) {
        // Answered for an older operation: ask again for the current one.
        _debounce = Timer(graphDropDebounce, _fetch);
        return;
      }
      _preview = preview;
      _highlight = defaultIndex;
      _armMenu();
      _warnBackwards();
      notifyListeners();
    } else if (_payload != null && _target != null && _preview == null && _debounce == null) {
      // The target (or the whole drag) moved on while this one was in flight, and its own query found one in
      // flight: it is next.
      unawaited(_fetch());
    }
  }

  /// The pointer was released at its last position: a bookmark drag runs its row on a target; a change drag runs the
  /// highlighted row once the menu is open (before it, nothing runs); else cancels.
  Future<void> drop() async {
    if (!active) {
      return;
    }
    final List<GraphDropRow>? rows = _preview?.rows;
    if (_target == null || rows == null || rows.isEmpty || (_payload is GraphChangeDrag && !_menu)) {
      cancel();
      return;
    }
    await _runRow(rows[_highlight.clamp(0, rows.length - 1)]);
  }

  Future<void> _runRow(GraphDropRow row) async {
    final Rect? rect = _ghostRect();
    final Rect? local = rect == null ? null : toViewport?.call(rect);
    final GraphDropOrigin? origin = local == null
        ? null
        : switch (row.action) {
            GraphRebase(:final List<String> source, :final List<String> revisions) => (
              key: <String>[...source, ...revisions].first,
              rect: local,
            ),
            GraphDuplicate() => (key: null, rect: local),
            _ => null,
          };
    _dropPoint = _pointer;
    _dropped = _payload;
    _running = true;
    _end(notify: true);
    try {
      await run?.call(row.action, origin);
    } finally {
      _running = false;
      _dropPoint = null;
      _dropped = null;
      if (!_disposed) {
        notifyListeners();
      }
    }
  }

  Rect? _ghostRect() {
    final RenderObject? box = ghostKey.currentContext?.findRenderObject();
    if (box is RenderBox && box.attached && box.hasSize) {
      // Through the transform: a zoomed window scales the ghost.
      return MatrixUtils.transformRect(box.getTransformTo(null), Offset.zero & box.size);
    }
    return null;
  }

  /// Esc or a release on nothing: nothing runs.
  void cancel() {
    if (_payload == null) {
      return;
    }
    _end(notify: true);
  }

  void _end({required bool notify}) {
    if (_payload != null) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    _unroute();
    _debounce?.cancel();
    _menuTimer?.cancel();
    _debounce = _menuTimer = null;
    _payload = null;
    _target = null;
    _preview = null;
    _menu = _overMenu = _arrowed = false;
    _highlight = 0;
    if (notify && !_disposed) {
      notifyListeners();
    }
  }

  bool _onKey(KeyEvent event) {
    if (_payload == null) {
      return false;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.altLeft || key == LogicalKeyboardKey.altRight) {
      final bool alt = HardwareKeyboard.instance.isAltPressed;
      if (alt != _alt) {
        _alt = alt;
        // Once the menu is open its row stays: ⌥ picked it when the menu opened.
        if (!_arrowed && !_menu) {
          _highlight = defaultIndex;
        }
        notifyListeners();
      }
      return false;
    }
    if (event is KeyUpEvent) {
      return false;
    }
    if (key == LogicalKeyboardKey.escape) {
      cancel();
      return true;
    }
    final int count = _preview?.rows.length ?? 0;
    if (count > 0 && (key == LogicalKeyboardKey.arrowDown || key == LogicalKeyboardKey.arrowUp)) {
      _highlight = (_highlight + (key == LogicalKeyboardKey.arrowDown ? 1 : -1)) % count;
      _arrowed = true;
      notifyListeners();
      return true;
    }
    return false;
  }

  @override
  void dispose() {
    _disposed = true;
    if (_payload != null) {
      HardwareKeyboard.instance.removeHandler(_onKey);
    }
    _unroute();
    _debounce?.cancel();
    _menuTimer?.cancel();
    super.dispose();
  }
}

/// A drag recognizer for the graph's drag sources (Story 10.10): it calls [onBegin] once the pointer travelled more
/// than [graphDropDragThreshold] from the press — even when it won the arena earlier, as the last member after the tap
/// gave up at its 4 px slop.
class GraphDragRecognizer extends PanGestureRecognizer {
  /// A recognizer for primary-button mouse drags.
  GraphDragRecognizer({super.debugOwner})
    : super(
        supportedDevices: const <PointerDeviceKind>{PointerDeviceKind.mouse},
        allowedButtonsFilter: (buttons) => buttons == kPrimaryMouseButton,
      ) {
    onDown = (details) {
      _down = details.globalPosition;
      _begun = false;
    };
    onStart = (details) => _travelled(details.globalPosition);
    onUpdate = (details) => _travelled(details.globalPosition);
  }

  /// The drag begins at this global position.
  ValueChanged<Offset>? onBegin;

  Offset? _down;
  var _begun = false;

  void _travelled(Offset at) {
    final Offset? down = _down;
    if (!_begun && down != null && (at - down).distance > graphDropDragThreshold) {
      _begun = true;
      onBegin?.call(at);
    }
  }

  @override
  bool hasSufficientGlobalDistanceToAccept(PointerDeviceKind pointerDeviceKind, double? deviceTouchSlop) =>
      globalDistanceMoved.abs() > graphDropDragThreshold;
}

/// A Flutter-widget drag source (Story 10.10): a bookmark row of the popover, the Bookmarks panel or the inspector's
/// chips. Past [graphDropDragThreshold] it starts [drag] with [payload] (the drag follows the mouse itself from then
/// on, even when the source closes); while [enabled] is false (or [drag] is null) a drag does not begin.
class GraphDragSource extends StatelessWidget {
  /// A source of [payload].
  const GraphDragSource({
    required this.drag,
    required this.payload,
    required this.child,
    this.enabled = true,
    super.key,
  });

  /// The graph's drag; null drags nothing.
  final GraphDrag? drag;

  /// What a drag carries.
  final GraphDragPayload payload;

  /// Whether it drags.
  final bool enabled;

  /// The source.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    // Always the same tree, whatever [enabled] says: a flip must not remount the row (and drop its focus).
    final GraphDrag? drag = this.drag;
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        GraphDragRecognizer: GestureRecognizerFactoryWithHandlers<GraphDragRecognizer>(
          () => GraphDragRecognizer(debugOwner: this),
          (recognizer) => recognizer.onBegin = (at) {
            if (drag != null && enabled) {
              drag.start(payload, at);
            }
          },
        ),
      },
      child: child,
    );
  }
}
