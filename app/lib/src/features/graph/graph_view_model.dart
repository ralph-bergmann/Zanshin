// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../undo_timeline/undo_timeline_model.dart' show UndoTimelineActions;
import 'graph_content.dart';
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_viewport.dart' show GraphReveal, GraphRevealAlignment, GraphTransition;

final _log = Logger('zanshin.graph');

const _minuteMs = 60000;

/// Why the working copy is stale (`jj.stale_working_copy`'s `<cause>`, docs/rust-error-codes.md).
enum GraphStaleCause {
  /// `@` was rewritten by an operation the working copy was never updated to.
  stale,

  /// The repo was loaded at a sibling of the working copy's operation.
  siblingOperation,

  /// The working copy's recorded operation does not exist.
  operationNotFound,
}

/// The project-level stale state (Story 10.5 item 9, 2026-10-16): jj's message for the [cause] and the command its
/// hint names, both as Rust sent them (cli_util.rs:3040-3075 @ v0.46.0).
@immutable
class GraphStale {
  /// A stale state.
  const GraphStale({required this.cause, required this.message, required this.command});

  /// Reads a `jj.stale_working_copy` refusal: the cause from its context's first line
  /// (`<cause>\n<working_copy_op_id>\n<repo_op_id>\n<message>`, docs/rust-error-codes.md; an unknown cause reads as
  /// [GraphStaleCause.stale]), the message from its fourth, the command from the first backticked span of its first
  /// hint.
  factory GraphStale.fromError(ZanshinFfiException error) {
    final List<String> lines = (error.context ?? '').split('\n');
    final String? hint = error.hints.firstOrNull;
    return GraphStale(
      cause: switch (lines.first) {
        'sibling_operation' => GraphStaleCause.siblingOperation,
        'operation_not_found' => GraphStaleCause.operationNotFound,
        _ => GraphStaleCause.stale,
      },
      message: lines.length > 3 ? lines[3] : null,
      command: hint == null ? '' : (RegExp('`([^`]*)`').firstMatch(hint)?.group(1) ?? ''),
    );
  }

  /// The cause.
  final GraphStaleCause cause;

  /// jj's message, null when the error carries none.
  final String? message;

  /// The command jj's hint names, empty when the error has no hint.
  final String command;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphStale && other.cause == cause && other.message == message && other.command == command;

  @override
  int get hashCode => Object.hash(cause, message, command);
}

/// Where the working copy lies outside the unobscured area (Story 10.6 item 6).
enum GraphDirection {
  /// Wholly above it.
  up,

  /// Wholly below it.
  down,

  /// Beside it, to the left.
  left,

  /// Beside it, to the right.
  right,
}

/// A go-to's pulse (Story 10.6 item 12): its [key] and a [serial] that tells a repeat onto the same card apart.
@immutable
class GraphPulse {
  /// A pulse on [key].
  const GraphPulse(this.key, this.serial);

  /// The pulsing card's key.
  final String key;

  /// Increases with every go-to.
  final int serial;

  @override
  bool operator ==(Object other) => other is GraphPulse && other.key == key && other.serial == serial;

  @override
  int get hashCode => Object.hash(key, serial);
}

/// One gap's "Show in `all()`" (Story 10.19): the gap's [child] key, its [commitId] (the one `show`), and the shown
/// ancestors its dashed edges reach ([targets]; empty for a Missing edge's stub).
@immutable
class GraphGapTarget {
  /// The gap below [child].
  const GraphGapTarget({required this.child, required this.commitId, this.targets = const <String>[]});

  /// The gap's child (a stack's oldest member, never a stack key).
  final String child;

  /// The child's commit id.
  final String commitId;

  /// The keys of the visible ancestors its dashed edges reach (a stack's newest member, never a stack key); empty
  /// for a Missing edge.
  final List<String> targets;

  /// Whether the gap is a Missing edge's.
  bool get missing => targets.isEmpty;
}

/// A gap reveal's flash (Story 10.19): every commit the gap hid, and a [serial] that tells a repeat apart.
@immutable
class GraphFlash {
  /// A flash of [keys].
  const GraphFlash(this.keys, this.serial);

  /// The flashed keys (a folded member flashes its stack card).
  final Set<String> keys;

  /// Increases with every flash.
  final int serial;

  @override
  bool operator ==(Object other) => other is GraphFlash && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}

/// The cap of a gap's flash (Story 10.19): the walk over the hidden commits stops there, so at most this many flash.
const graphGapFlashCap = 10000;

/// The graph's view model (Story 10.5): it requests layouts through a [GraphSource] and keeps the view coherent while
/// jj re-derives the graph after every operation (ADR-0002).
///
/// - **Requests** pre-fill the revset (`revsets.log` until [setRevset]), `prioritize` and `shortPrefixes` from
///   `logDefaults()` and `anchors` from [defaultGraphAnchors], all passed explicitly. Reloads come on every
///   [OpHeadsChangedEvent], on [reload], [retry] and [configChanged], and — only while [stale] — on
///   [WorkingCopyHeartbeatEvent]. At most one request runs plus one queued, built when it starts; a result whose
///   request a queued one superseded is dropped.
/// - **Scroll precedence**, resolved as one [reveal] that lands with its layout: an explicit reveal ([revealKey],
///   [setRevset]'s `reveal`, [scrollToWorkingCopy], [scrollToSelection]) beats the re-centre on @ of the first layout
///   and after a revset, mode or lane-order switch, which beats the viewport's anchor. Pending ones survive a
///   superseded request and are cleared when a layout lands; an explicit reveal with no request pending applies at
///   once (animated).
/// - **States**: [loading], [empty], [revsetError] and [error] (the last layout kept), [stale], [degraded].
/// - **One "now"** ([now]): fresh on every landed layout and on [refreshNow], ticked on each minute boundary.
/// - **Story 10.6**: [edit] runs `jj edit` for a double-click, [goTo] selects, reveals and [pulse]s a change (10.21),
///   and the view publishes where @ lies off screen as [workingCopyDirection] for the @ pill.
/// - **Story 10.9, the action runner**: [run] runs one action at a time through [GraphActions] — while one runs, or
///   while [stale], a trigger gets [GraphActionDisabled] and nothing is called. The action's cards are [pendingKeys];
///   the reload after a success holds [anchorHint] and sets the selection and the reveal per verb from the
///   `MutationResult`. Every outcome, refusals included, is published as [outcome]; [undoLast] / [redoLast] take back
///   Zanshin's own latest operation only while it is the op-log head ([undoable], [redoable]).
/// - **Story 10.20**: a landed layout whose operation differs from the shown one's (both known) and that no revset,
///   mode or lane-order switch asked for is a [transition] when a node's key, column or row changed or a change was
///   born — Zanshin's verbs, an external `jj`, undo, redo and op restore alike. Every new operation takes the anchor,
///   the born change and the flash of the last own operation's outcome not yet landed; without a transition its flash
///   goes out as [flash]. The born change is revealed by the canvas after the glide, not with the layout. A later
///   layout of the same operation that no switch asked for (the watcher's reload after Zanshin's own verb) is the
///   last transition [GraphTransition.continued] onto it, so a running one keeps going.
/// - **Story 11.9**: the Undo Timeline's runner — [undoOperation] undoes any op-log head, [restoreOperation] restores.
@inject
class GraphViewModel extends ChangeNotifier implements UndoTimelineActions {
  /// A view model; [init] connects it.
  GraphViewModel();

  late GraphSource _source;
  GraphContent? _content;
  GraphActions? _actions;
  DateTime Function() _clock = DateTime.now;
  StreamSubscription<RepoEvent>? _events;
  Timer? _tick;
  final _now = ValueNotifier<int>(0);
  final _workingCopyDirection = ValueNotifier<GraphDirection?>(null);
  final _pulse = ValueNotifier<GraphPulse?>(null);
  var _pulseSerial = 0;
  final _flash = ValueNotifier<GraphFlash?>(null);
  var _flashSerial = 0;

  // Story 10.19: a gap's "Show in all()" until its layout lands: the layout it was shown in, the gap, and the child's
  // real parents that layout lacks.
  ({GraphLayout old, GraphGapTarget gap, List<String> hidden})? _gap;
  var _disposed = false;

  LogDefaults? _defaults;
  String? _revset;
  GraphMode _mode = GraphMode.free;
  GraphLaneOrder _order = GraphLaneOrder.compact;
  var _stacks = false;
  String? _selected;

  // Story 10.17: the stack toggles (oldest member keys), their store, an expand's entering keys for the layout it
  // requests, and a go-to's pulse waiting for a folded key to land.
  GraphStackStore? _stackStore;
  final _expanded = <String>{};
  final _collapsed = <String>{};
  Set<String>? _enteringNext;
  Set<String>? _entering;
  String? _pulseOnLand;

  var _inFlight = false;
  var _queued = false;
  GraphRequest? _request;

  // A pending explicit reveal: its key, or @ when the key is null.
  ({String? key, GraphRevealAlignment alignment})? _explicit;

  GraphAction? _running;
  String? _anchorHint;
  final _outcome = ValueNotifier<GraphOutcome?>(null);
  GraphOutcome? _undoable;
  GraphOutcome? _redoable;
  var _recentre = true;

  GraphLayout? _layout;
  GraphReveal? _reveal;

  // Story 10.20: the last landed operation's transition, and an own operation's outcome until its layout lands.
  GraphTransition? _transition;
  GraphOutcome? _landing;
  var _warnings = const <ZanshinWarning>[];
  Precondition? _precondition;
  ZanshinFfiException? _revsetError;
  ZanshinFfiException? _error;
  GraphStale? _stale;
  String? _degraded;
  var _staleUpdating = false;
  StaleRecovery? _lastStaleRecovery;
  ZanshinFfiException? _staleUpdateError;

  /// One-shot setup for `ViewModelBuilder`'s `init`: reads from [source], runs verbs through [actions] (10.9), takes
  /// "now" from [clock], and sends [mode] and [stacks] (the stored preferences, 10.7), [stackStore]'s toggles (10.17)
  /// and [revset] (the search's shown view, 10.21; null = `revsets.log`) with the first request.
  void init(
    GraphSource source, {
    GraphActions? actions,
    DateTime Function()? clock,
    GraphMode mode = GraphMode.free,
    bool stacks = false,
    GraphStackStore? stackStore,
    String? revset,
  }) {
    _revset = revset;
    _mode = mode;
    _stacks = stacks;
    _stackStore = stackStore;
    if (stackStore?.load() case final GraphStackToggles toggles) {
      _expanded.addAll(toggles.expanded);
      _collapsed.addAll(toggles.collapsed);
    }
    _source = source;
    _content = GraphContent(source.content);
    _actions = actions;
    _clock = clock ?? DateTime.now;
    _now.value = _nowMs;
    _scheduleTick();
    _events = source.events.listen(_onEvent);
    _requestLayout();
  }

  /// The last landed layout; null before the first.
  GraphLayout? get layout => _layout;

  /// The card content cache and loader (Story 10.11); the view loads what is on screen.
  GraphContent get content => _content!;

  /// The reveal the viewport applies with [layout], by identity.
  GraphReveal? get reveal => _reveal;

  /// The operation [layout] landed with, animated by the canvas (Story 10.20); null when it brought none.
  GraphTransition? get transition => _transition;

  /// The last request issued.
  GraphRequest? get request => _request;

  /// The effective `jj log` defaults, once read.
  LogDefaults? get logDefaults => _defaults;

  /// The revset requested; null until `logDefaults()` answered.
  String? get revset => _revset ?? _defaults?.log;

  /// The layout mode.
  GraphMode get mode => _mode;

  /// The lane order.
  GraphLaneOrder get laneOrder => _order;

  /// Whether linear runs group into stacks (Story 10.7's Group stacks).
  bool get stacks => _stacks;

  /// The selected node's key; null when none, or when a landed layout lacks it.
  String? get selected => _selected;

  /// Whether the first layout is still being requested.
  bool get loading => _layout == null && _inFlight;

  /// Whether the revset matched nothing (not an error).
  bool get empty => _layout?.shownCount == 0;

  /// A `jj.revset_parse_error` / `jj.revset_resolution_error` of the last request; the last layout stays.
  ZanshinFfiException? get revsetError => _revsetError;

  /// Any other failure of the last request; the last layout stays, [retry] requests again.
  ZanshinFfiException? get error => _error;

  /// The stale working copy, while jj refuses for it.
  GraphStale? get stale => _stale;

  /// A watcher error's message: live updates are degraded.
  String? get degraded => _degraded;

  /// The last landed load's warnings.
  List<ZanshinWarning> get warnings => _warnings;

  /// The last landed load's snapshot report.
  Precondition? get lastPrecondition => _precondition;

  /// The commits shown.
  int? get shown => _layout?.shownCount;

  /// `|all()|`, when the source provides it.
  int? get total => _layout?.totalCount;

  /// Whether [updateStale] runs.
  bool get staleUpdating => _staleUpdating;

  /// The last [updateStale] result.
  StaleRecovery? get lastStaleRecovery => _lastStaleRecovery;

  /// The last [updateStale] failure, until one succeeds.
  ZanshinFfiException? get staleUpdateError => _staleUpdateError;

  /// "Now" for the cards and the day axis, in epoch ms.
  ValueListenable<int> get now => _now;

  /// Where @ lies outside the unobscured area, as the view last measured it; null while any part of it shows (or
  /// there is no @).
  ValueListenable<GraphDirection?> get workingCopyDirection => _workingCopyDirection;

  /// The view's measurement of [workingCopyDirection].
  void setWorkingCopyDirection(GraphDirection? direction) {
    if (!_disposed) {
      _workingCopyDirection.value = direction;
    }
  }

  /// The last go-to's pulse; the canvas runs it once per instance.
  ValueListenable<GraphPulse?> get pulse => _pulse;

  /// The last gap reveal's flash (Story 10.19); the canvas runs it once per instance.
  ValueListenable<GraphFlash?> get flash => _flash;

  /// `jj show <commitId>` through the source: the gap callout's hidden parents (Story 10.19).
  Future<ShowEntry> showChange(String commitId) => _source.show(commitId);

  /// "Show in `all()`" of [gap] (Story 10.19): one `show` of its child for the real parents, then one request for
  /// `all()` carrying the parents the shown layout lacks in `keepOpenKeys`. When it lands, the real parent from which
  /// the gap's targets are reached through commits the old layout lacked (for a Missing edge, the hidden parent) is
  /// revealed centred (its stack card while folded), and every commit the gap hid flashes. A failed `show` issues no
  /// request and answers false.
  Future<bool> showGap(GraphGapTarget gap) async {
    final GraphLayout? old = _layout;
    if (old == null) {
      return false;
    }
    final ShowEntry entry;
    try {
      entry = await _source.show(gap.commitId);
    } on ZanshinFfiException catch (error) {
      _log.warning('reading a gap\'s parents failed: ${error.code}');
      return false;
    }
    if (_disposed) {
      return false;
    }
    final hidden = <String>[
      for (final String parent in entry.change.parents)
        if (old.indexOfKey(parent) == null) parent,
    ];
    _revset = 'all()'; // l10n-ignore: jj revset
    _recentre = false;
    _gap = (old: old, gap: gap, hidden: hidden);
    _explicit = (key: hidden.firstOrNull ?? gap.child, alignment: GraphRevealAlignment.centre);
    _requestLayout();
    return true;
  }

  /// [gap]'s reveal key and flashed keys on [layout].
  (String?, Set<String>) _gapLanding(
    ({GraphLayout old, GraphGapTarget gap, List<String> hidden}) gap,
    GraphLayout layout,
  ) {
    bool isNew(int node) => gap.old.indexOfKey(layout.keyOf(node)) == null;
    final starts = <int>[for (final String key in gap.hidden) ?layout.indexOfKey(key)];
    // The new nodes reached from the hidden parents through new nodes only.
    final reached = <int>{};
    final work = <int>[
      for (final int start in starts)
        if (isNew(start) && reached.add(start)) start,
    ];
    while (work.isNotEmpty && reached.length < graphGapFlashCap) {
      final (:int start, :int end) = layout.parentEdges(work.removeLast());
      for (var e = start; e < end && reached.length < graphGapFlashCap; e++) {
        final int parent = layout.parentOf(e);
        if (isNew(parent) && reached.add(parent)) {
          work.add(parent);
        }
      }
    }
    var flashed = reached;
    if (!gap.gap.missing) {
      // Those of them from which a target is reached through them.
      flashed = <int>{};
      // A target folded in all() is reached through its stack card.
      final back = <int>[for (final String key in gap.gap.targets) ?layout.placeOfKey(key)];
      while (back.isNotEmpty) {
        final (:int start, :int end) = layout.childEdges(back.removeLast());
        for (var slot = start; slot < end; slot++) {
          final int child = layout.childOf(layout.childEdgeAt(slot));
          if (reached.contains(child) && flashed.add(child)) {
            back.add(child);
          }
        }
      }
    }
    final int? reveal = starts.where(flashed.contains).firstOrNull ?? starts.firstOrNull;
    final int? place = reveal == null ? null : layout.placeOfKey(layout.keyOf(reveal));
    return (place == null ? null : layout.keyOf(place), <String>{for (final int node in flashed) layout.keyOf(node)});
  }

  /// Go-to-change (Story 10.6 items 11–12; 10.21 calls it): selects [key], reveals it centred and pulses it; nothing
  /// when the shown layout lacks it.
  void goTo(String key) {
    final GraphLayout? layout = _layout;
    final int? node = layout?.indexOfKey(key);
    if (node == null) {
      return;
    }
    select(key);
    _revealExplicit(key);
    // A folded key pulses once its stack opened (Story 10.17).
    if (layout!.isFolded(node)) {
      _pulseOnLand = key;
    } else {
      _pulse.value = GraphPulse(key, ++_pulseSerial);
    }
  }

  /// The keys that fade in with the current layout (an expand's members but the anchor), once per instance; null
  /// otherwise (Story 10.17).
  Set<String>? get entering => _entering;

  /// Expands the run of [key] (a member's key or the stack's): one request keeping the run's anchor member in place;
  /// the members but the anchor fade in when it lands. The toggle persists (Story 10.17).
  void expandStack(String key) => _toggleStack(key, expand: true);

  /// Collapses the run of [key] (a member's key): one request, the stack taking the anchor member's place; a selection
  /// inside the run clears. The toggle persists (Story 10.17).
  void collapseStack(String key) => _toggleStack(key, expand: false);

  void _toggleStack(String key, {required bool expand}) {
    final GraphLayout? layout = _layout;
    final int? node = layout?.indexOfKey(key);
    final int? run = node == null ? null : layout!.runOf(node);
    if (run == null) {
      return;
    }
    final List<int> members = layout!.runMembersOf(run);
    final String oldest = layout.keyOf(members.first);
    final String anchor = graphStackAnchorKey(layout, run);
    (expand ? _expanded : _collapsed).add(oldest);
    (expand ? _collapsed : _expanded).remove(oldest);
    _stackStore?.save(GraphStackToggles(expanded: <String>{..._expanded}, collapsed: <String>{..._collapsed}));
    _anchorHint = anchor;
    if (expand) {
      _enteringNext = <String>{
        for (final int member in members)
          if (layout.keyOf(member) != anchor) layout.keyOf(member),
      };
    } else {
      _enteringNext = null;
      final String? selected = _selected;
      if (selected != null && members.any((member) => layout.keyOf(member) == selected)) {
        _selected = null;
        // A request in flight notifies only when it finishes: the inspector closes now.
        _notify();
      }
    }
    _requestLayout();
  }

  /// Runs `jj edit` on [key] through [run] (a double-click, no confirmation); null when [init] was given no
  /// [GraphActions].
  Future<GraphActionResult?> edit(String key) async => _actions == null ? null : run(GraphEdit(key));

  /// Whether [init] was given [GraphActions].
  bool get hasActions => _actions != null;

  /// Whether a trigger may run an action now: none runs and the working copy is not stale.
  @override
  bool get actionsEnabled => _running == null && _stale == null;

  /// The cards of the running action.
  Set<String> get pendingKeys => _running?.pendingKeys ?? const <String>{};

  /// The card the running action's reload is anchored on; cleared when that layout lands.
  String? get anchorHint => _anchorHint;

  /// The latest outcome, refusals included.
  ValueListenable<GraphOutcome?> get outcome => _outcome;

  /// Zanshin's own latest operation while it is the op-log head; [undoLast] takes it back.
  GraphOutcome? get undoable => _undoable;

  /// Zanshin's own latest undo while it is the op-log head; [redoLast] takes it back.
  @override
  GraphOutcome? get redoable => _redoable;

  /// The change a menu verb acts on: the selection, else @ (11.13).
  String? get actionTarget =>
      _selected ??
      switch (_layout) {
        final GraphLayout layout => _workingCopyKey(layout),
        null => null,
      };

  /// Go-to-change for a key the shown layout lacks (Story 10.21 item 5): one request for `all()` that selects
  /// [key], reveals it and pulses it when it lands — no re-centre on @. `all()` keys a hidden or divergent commit by
  /// its [commitId]: when the landed layout lacks [key] but has [commitId], that key is the target.
  void goToHidden(String key, {String? commitId}) {
    _revset = 'all()'; // l10n-ignore: jj revset
    _recentre = false;
    _selected = key;
    _explicit = (key: key, alignment: GraphRevealAlignment.centre);
    _pulseOnLand = key;
    _hiddenCommitId = commitId == null ? null : (key: key, commitId: commitId);
    _requestLayout();
  }

  // A hidden go-to's change id and commit id, until its layout lands.
  ({String key, String commitId})? _hiddenCommitId;

  /// Shows [revset] — null for the effective `revsets.log` — and re-centres on @, or reveals [reveal] instead (the
  /// precedence).
  void setRevset(String? revset, {String? reveal}) {
    _revset = revset;
    _recentre = true;
    if (reveal != null) {
      _explicit = (key: reveal, alignment: GraphRevealAlignment.centre);
    }
    _requestLayout();
  }

  /// Switches the layout mode and re-centres on @.
  void setMode(GraphMode mode) {
    if (mode == _mode) {
      return;
    }
    _mode = mode;
    _recentre = true;
    _requestLayout();
  }

  /// Switches the lane order and re-centres on @.
  void setLaneOrder(GraphLaneOrder order) {
    if (order == _order) {
      return;
    }
    _order = order;
    _recentre = true;
    _requestLayout();
  }

  /// Groups linear runs into stacks, or not, under the anchor (no re-centre on @).
  void setStacks(bool stacks) {
    if (stacks == _stacks) {
      return;
    }
    _stacks = stacks;
    _requestLayout();
  }

  /// Selects [key], or clears the selection.
  void select(String? key) {
    if (key == _selected) {
      return;
    }
    _selected = key;
    _notify();
  }

  /// Reveals [key] (a bookmark pick, go-to-change).
  void revealKey(String key) => _revealExplicit(key);

  /// Scrolls to @ (Go › Working Copy); the selection stays.
  void scrollToWorkingCopy() => _revealExplicit(null);

  /// Scrolls to the selection (Go › Selection); nothing without one.
  void scrollToSelection() {
    final String? selected = _selected;
    if (selected != null) {
      _revealExplicit(selected);
    }
  }

  /// Requests the layout again (10.9 after a mutation).
  void reload() => _requestLayout();

  /// Requests again after an [error].
  void retry() => _requestLayout();

  /// The effective config changed without an operation (item 16): re-reads `logDefaults()` — the default search
  /// follows the new `revsets.log` — and requests under the anchor.
  void configChanged() => _requestLayout();

  /// Sets [now] fresh (the window turned active).
  void refreshNow() => _now.value = _nowMs;

  /// Runs `jj workspace update-stale`, then reloads; a failure is kept as [staleUpdateError]. No Undo is offered.
  Future<void> updateStale() async {
    if (_staleUpdating) {
      return;
    }
    _staleUpdating = true;
    _notify();
    // It usually writes no operation of its own: an undo would take back a foreign one.
    _undoable = _redoable = null;
    try {
      _lastStaleRecovery = await _source.updateStale();
      _staleUpdateError = null;
    } on ZanshinFfiException catch (error) {
      _staleUpdateError = error;
      _log.warning('updating the stale working copy failed: ${error.code}');
      return;
    } finally {
      _staleUpdating = false;
      _notify();
    }
    _requestLayout();
  }

  /// Runs [action] (Story 10.9) and reloads after it ran; a refusal reloads only for a stale working copy.
  Future<GraphActionResult> run(GraphAction action) => _execute(action);

  /// Undoes [undoable]'s action, when the op-log head is still its operation.
  Future<GraphActionResult> undoLast() async {
    final GraphOutcome? own = _undoable;
    if (_disabled ?? (own == null ? GraphDisabledReason.nothingToUndo : null) case final reason?) {
      return GraphActionDisabled(reason);
    }
    final GraphAction action = own!.action;
    final GraphAction undone = action is GraphRedo ? action.of : action;
    return _execute(GraphUndo(undone), expectHead: own.result!.newOpId);
  }

  /// Redoes [redoable]'s undo, when the op-log head is still its operation.
  @override
  Future<GraphActionResult> redoLast() async {
    final GraphOutcome? own = _redoable;
    if (_disabled ?? (own == null ? GraphDisabledReason.nothingToUndo : null) case final reason?) {
      return GraphActionDisabled(reason);
    }
    return _execute(GraphRedo((own!.action as GraphUndo).of), expectHead: own.result!.newOpId);
  }

  /// `jj undo` while [head] is still the op-log head (Story 11.9's Undo Timeline, any head); [of] is what it undoes.
  @override
  Future<GraphActionResult> undoOperation(String head, GraphLoggedOperation of) =>
      _execute(GraphUndo(of), expectHead: head);

  /// `jj redo` while [head] is still the op-log head (Story 11.9, an undo the CLI made too); [of] is what it redoes.
  @override
  Future<GraphActionResult> redoOperation(String head, GraphLoggedOperation of) =>
      _execute(GraphRedo(of), expectHead: head);

  /// `jj op restore <operation>` (Story 11.9's Restore to here).
  @override
  Future<GraphActionResult> restoreOperation(String operation) => _execute(GraphOpRestore(operation));

  GraphDisabledReason? get _disabled => _stale != null
      ? GraphDisabledReason.stale
      : _running != null
      ? GraphDisabledReason.busy
      : null;

  /// One action: the head before it (an undo or redo needs [expectHead] there), the verb, then the outcome.
  Future<GraphActionResult> _execute(GraphAction action, {String? expectHead}) async {
    final GraphActions? actions = _actions;
    if (actions == null) {
      throw StateError('GraphViewModel.init was given no GraphActions');
    }
    if (_disabled case final reason?) {
      return GraphActionDisabled(reason);
    }
    final ({String? anchor, String? destination}) plan = _plan(action);
    _running = action;
    _anchorHint = plan.anchor;
    _notify();
    try {
      final String head = await actions.headOpId();
      if (expectHead != null && head != expectHead) {
        _undoable = _redoable = null;
        _finish();
        return const GraphActionDisabled(GraphDisabledReason.foreignOperation);
      }
      final MutationResult result = await actions.run(action);
      _running = null;
      final GraphOutcome outcome = _succeeded(action, result, wrote: result.newOpId != head, plan: plan);
      if (outcome.undoable) {
        // Its hints ride with the first layout of a new operation.
        _landing = outcome;
      }
      _publish(outcome);
      _requestLayout();
      _notify();
      return GraphActionDone(outcome);
    } on ZanshinFfiException catch (error) {
      _log.warning('${action.runtimeType} refused: ${error.code}');
      _finish();
      _publish(GraphOutcome(action, error: error));
      if (error.code == 'jj.stale_working_copy') {
        _requestLayout();
      }
      return GraphActionRefused(error);
    } catch (_) {
      // A programming error (a closed handle, an interior NUL) must not leave the runner busy forever.
      _finish();
      rethrow;
    }
  }

  /// Ends a run that reloads nothing.
  void _finish() {
    _running = null;
    _anchorHint = null;
    _notify();
  }

  void _publish(GraphOutcome outcome) {
    if (!_disposed) {
      _outcome.value = outcome;
    }
  }

  /// The anchor (and a squash's destination) of [action], from the layout before it runs.
  ({String? anchor, String? destination}) _plan(GraphAction action) {
    switch (action) {
      case GraphNew(:final parents, :final insertAfter, :final insertBefore):
        return (anchor: <String>[...parents, ...insertAfter, ...insertBefore].firstOrNull, destination: null);
      case GraphAbandon(:final ids):
        return (anchor: _firstParent(ids.firstOrNull), destination: null);
      case GraphRevert(:final id) || GraphCommit(:final id) || GraphSplit(:final id):
        return (anchor: id, destination: null);
      case GraphSquash(:final revision, :final from, :final into):
        final GraphLayout? layout = _layout;
        final String? at = layout == null ? null : _workingCopyKey(layout);
        // jj's defaults: `--from` without `--into` goes into @, `-r` (default @) into its parent.
        final String? destination = into ?? (from.isNotEmpty ? at : _firstParent(revision ?? at));
        return (anchor: destination, destination: destination);
      default:
        return (anchor: null, destination: null);
    }
  }

  /// [key]'s first shown parent.
  String? _firstParent(String? key) {
    final GraphLayout? layout = _layout;
    final int? node = key == null ? null : layout?.indexOfKey(key);
    if (node == null) {
      return null;
    }
    final ({int start, int end}) edges = layout!.parentEdges(node);
    return edges.start < edges.end ? layout.keyOf(layout.parentOf(edges.start)) : null;
  }

  /// The selection, the reveal and the undo state after [action] succeeded; [wrote] is whether it wrote an operation.
  GraphOutcome _succeeded(
    GraphAction action,
    MutationResult result, {
    required bool wrote,
    required ({String? anchor, String? destination}) plan,
  }) {
    final String? born = result.newChangeIds.firstOrNull;
    final String? selected = _selected;
    switch (action) {
      case GraphNew(:final parents, :final insertAfter):
        if (born != null && selected != null && (parents.contains(selected) || insertAfter.contains(selected))) {
          _selected = born;
        }
      case GraphRevert():
        // The inspector is open exactly while something is selected: it follows the revert to the born change.
        if (born != null && selected != null) {
          _selected = born;
        }
      case GraphCommit(:final id):
        // The new @ is the working change now: the inspector follows it.
        if (born != null && selected == id) {
          _selected = born;
        }
      case GraphAbandon():
        _selected = null;
      case GraphSquash():
        if (plan.destination != null && result.abandonedChangeIds.contains(selected)) {
          _selected = plan.destination;
        }
      default:
        break;
    }
    if (born != null && (action is GraphNew || action is GraphRevert || action is GraphCommit)) {
      _explicit = (key: born, alignment: GraphRevealAlignment.covered);
    }
    final outcome = GraphOutcome(
      action,
      result: result,
      undoable: wrote,
      anchor: plan.anchor,
      flash: <String>[
        if (action is GraphSquash) ?plan.destination,
        if (action is GraphBookmarkMove) ?action.to,
        if (action is GraphCommit) action.id,
        if (action is GraphSplit) action.id,
      ],
    );
    switch (action) {
      case GraphUndo():
        _undoable = null;
        _redoable = wrote ? outcome : null;
      case GraphRedo():
        _redoable = null;
        _undoable = wrote ? outcome : null;
      default:
        // A verb that wrote nothing leaves the head, and so the last own operation, as it was.
        if (wrote) {
          _undoable = outcome;
          _redoable = null;
        }
    }
    return outcome;
  }

  /// Drops [undoable] and [redoable] once the op-log head is no longer their operation.
  Future<void> _checkHead() async {
    final GraphActions? actions = _actions;
    final GraphOutcome? undo = _undoable;
    final GraphOutcome? redo = _redoable;
    if (actions == null || _running != null || (undo == null && redo == null)) {
      return;
    }
    final String head;
    try {
      head = await actions.headOpId();
    } on ZanshinFfiException catch (error) {
      _log.warning('reading the op-log head failed: ${error.code}');
      return;
    }
    var dropped = false;
    if (undo != null && identical(undo, _undoable) && undo.result?.newOpId != head) {
      _undoable = null;
      dropped = true;
    }
    if (redo != null && identical(redo, _redoable) && redo.result?.newOpId != head) {
      _redoable = null;
      dropped = true;
    }
    if (dropped) {
      _notify();
    }
  }

  int get _nowMs => _clock().millisecondsSinceEpoch;

  void _scheduleTick() {
    _tick = Timer(Duration(milliseconds: _minuteMs - _nowMs % _minuteMs), () {
      _now.value = _nowMs;
      _scheduleTick();
    });
  }

  void _onEvent(RepoEvent event) {
    switch (event) {
      case OpHeadsChangedEvent():
        _requestLayout();
        unawaited(_checkHead());
      case WorkingCopyHeartbeatEvent():
        // A heartbeat fires on any jj activity, our own reads included: outside the stale state it would double every
        // reload, so it only lifts a stale state.
        if (_stale != null) {
          _requestLayout();
        }
      case WatchErrorEvent(:final String message):
        _degraded = message;
        _notify();
      case ProgressEvent():
        break;
    }
  }

  void _revealExplicit(String? key) {
    final GraphLayout? layout = _layout;
    final int? node = key == null ? null : layout?.indexOfKey(key);
    if (_inFlight || layout == null) {
      _explicit = (key: key, alignment: GraphRevealAlignment.centre);
      // The request in flight was built without a folded key in keepOpenKeys: queue one that keeps it open.
      if (node != null && layout!.isFolded(node)) {
        _requestLayout();
      }
      return;
    }
    if (node != null && layout.isFolded(node)) {
      // Story 10.17: a folded key opens its stack (it rides in keepOpenKeys) and is revealed when that layout lands.
      _explicit = (key: key, alignment: GraphRevealAlignment.centre);
      _requestLayout();
      return;
    }
    final String? target = key ?? _workingCopyKey(layout);
    if (target != null) {
      _reveal = GraphReveal(target, animate: true);
      _notify();
    }
  }

  static String? _workingCopyKey(GraphLayout layout) {
    final int? at = layout.workingCopyIndex;
    return at == null ? null : layout.keyOf(at);
  }

  void _requestLayout() {
    if (_disposed) {
      return;
    }
    if (_inFlight) {
      _queued = true;
      return;
    }
    unawaited(_run());
  }

  Future<void> _run() async {
    _inFlight = true;
    _queued = false;
    _notify();
    try {
      // Re-read with every request (Story 10.21): a config edit writes no operation.
      final LogDefaults? cached = _defaults;
      LogDefaults fresh;
      try {
        fresh = await _source.logDefaults();
      } on ZanshinFfiException catch (error) {
        // Read before: a transient failure keeps the cached defaults.
        if (cached == null) {
          rethrow;
        }
        _log.warning('re-reading logDefaults failed: ${error.code}');
        fresh = cached;
      }
      if (_disposed) {
        return;
      }
      // The default search is the null revset, so it follows `revsets.log`; an explicit one stays as sent.
      _defaults = fresh;
      final GraphRequest request = _request = _build(_defaults!);
      final GraphLoad load = await _source.layout(request);
      if (!_disposed && !_queued) {
        _land(load);
      }
    } on ZanshinFfiException catch (error) {
      if (!_disposed && !_queued) {
        _fail(error);
      }
    } finally {
      _inFlight = false;
      if (_queued) {
        _requestLayout();
      } else {
        _notify();
      }
    }
  }

  GraphRequest _build(LogDefaults defaults) => GraphRequest(
    revset: _revset ?? defaults.log,
    mode: _mode,
    order: _order,
    stacks: _stacks,
    expandedKeys: <String>{..._expanded},
    collapsedKeys: <String>{..._collapsed},
    prioritize: defaults.logGraphPrioritize,
    shortPrefixes: defaults.shortPrefixes,
    anchors: defaultGraphAnchors,
    utcOffsetMin: _clock().timeZoneOffset.inMinutes,
    keepOpenKeys: <String>{?_selected, ?_explicit?.key, ...?_gap?.hidden},
  );

  void _land(GraphLoad load) {
    final GraphLayout layout = load.layout;
    final GraphLayout? previous = _layout;
    final String? op = layout.operationId;
    final String? was = previous?.operationId;
    final GraphTransition? last = _transition;
    _transition = null;
    if (last != null && op != null && op == was && !_recentre) {
      _transition = GraphTransition.continued(last, layout);
    } else if (previous != null && op != null && was != null && op != was) {
      // A new operation takes the pending hints, whether it animates or not.
      final GraphOutcome? hints = _landing;
      _landing = null;
      final String? born = hints?.born.firstOrNull;
      final List<String> flash = hints?.flash ?? const <String>[];
      // It animates when the user did not switch away and something moves or is born (Story 10.20).
      if (!_recentre && (born != null || _moved(previous, layout))) {
        _transition = GraphTransition(
          from: previous,
          to: layout,
          anchor: hints?.anchor,
          born: born,
          flash: <String>{...flash},
        );
      } else if (flash.isNotEmpty) {
        _flash.value = GraphFlash(<String>{...flash}, ++_flashSerial);
      }
    }
    _layout = layout;
    _warnings = load.warnings;
    _precondition = load.precondition;
    _revsetError = null;
    _error = null;
    _stale = null;
    if (_hiddenCommitId case (:final String key, :final String commitId)
        when layout.indexOfKey(key) == null && layout.indexOfKey(commitId) != null) {
      if (_selected == key) {
        _selected = commitId;
      }
      if (_explicit?.key == key) {
        _explicit = (key: commitId, alignment: _explicit!.alignment);
      }
      if (_pulseOnLand == key) {
        _pulseOnLand = commitId;
      }
    }
    _hiddenCommitId = null;
    if (_gap case final gap?) {
      _gap = null;
      final (String? reveal, Set<String> flashed) = _gapLanding(gap, layout);
      if (reveal != null) {
        _explicit = (key: reveal, alignment: GraphRevealAlignment.centre);
      }
      if (flashed.isNotEmpty) {
        _flash.value = GraphFlash(flashed, ++_flashSerial);
      }
    }
    final String? selected = _selected;
    if (selected != null && layout.indexOfKey(selected) == null) {
      _selected = null;
    }
    final ({String? key, GraphRevealAlignment alignment})? explicit = _explicit;
    String? target = explicit != null
        ? explicit.key ?? _workingCopyKey(layout)
        : (_recentre ? _workingCopyKey(layout) : null);
    if (target != null && target == _transition?.born && !_transition!.isContinued) {
      // The canvas reveals it after the glide.
      target = null;
    }
    _reveal = target == null
        ? null
        : GraphReveal(target, alignment: explicit?.alignment ?? GraphRevealAlignment.centre);
    _explicit = null;
    _recentre = false;
    // An expand's members fade in once, with the layout its request brought.
    _entering = _enteringNext;
    _enteringNext = null;
    if (_pulseOnLand case final String key? when layout.indexOfKey(key) != null) {
      _pulse.value = GraphPulse(key, ++_pulseSerial);
    }
    _pulseOnLand = null;
    // A layout landing while the action still runs keeps its anchor for the reload after it.
    if (_running == null) {
      _anchorHint = null;
    }
    _now.value = _nowMs;
  }

  /// Whether any node's key, column or row differs between [a] and [b].
  static bool _moved(GraphLayout a, GraphLayout b) {
    if (a.nodeCount != b.nodeCount) {
      return true;
    }
    for (var node = 0; node < a.nodeCount; node++) {
      if (a.keyOf(node) != b.keyOf(node) || a.colOf(node) != b.colOf(node) || a.rowOf(node) != b.rowOf(node)) {
        return true;
      }
    }
    return false;
  }

  void _fail(ZanshinFfiException error) {
    if (_running == null) {
      _anchorHint = null;
    }
    // A failed expand or go-to must not fade or pulse with a later, unrelated layout.
    _enteringNext = null;
    _pulseOnLand = null;
    _hiddenCommitId = null;
    _gap = null;
    _revsetError = null;
    _error = null;
    _stale = null;
    switch (error.code) {
      case 'jj.revset_parse_error' || 'jj.revset_resolution_error':
        _revsetError = error;
      case 'jj.stale_working_copy':
        _stale = GraphStale.fromError(error);
      default:
        _error = error;
        _log.warning('loading the graph failed: ${error.code}');
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_events?.cancel());
    _tick?.cancel();
    _now.dispose();
    _workingCopyDirection.dispose();
    _pulse.dispose();
    _flash.dispose();
    _outcome.dispose();
    _content?.dispose();
    super.dispose();
  }
}
