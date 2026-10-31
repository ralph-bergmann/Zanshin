// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_content.dart';
import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_viewport.dart' show GraphReveal, GraphRevealAlignment;

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
@inject
class GraphViewModel extends ChangeNotifier {
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
  var _disposed = false;

  LogDefaults? _defaults;
  var _rereadDefaults = false;
  String? _revset;
  GraphMode _mode = GraphMode.free;
  GraphLaneOrder _order = GraphLaneOrder.compact;
  String? _selected;

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
  var _warnings = const <ZanshinWarning>[];
  Precondition? _precondition;
  ZanshinFfiException? _revsetError;
  ZanshinFfiException? _error;
  GraphStale? _stale;
  String? _degraded;
  var _staleUpdating = false;
  StaleRecovery? _lastStaleRecovery;
  ZanshinFfiException? _staleUpdateError;

  /// One-shot setup for `ViewModelBuilder`'s `init`: reads from [source], runs verbs through [actions] (10.9) and
  /// takes "now" from [clock].
  void init(GraphSource source, {GraphActions? actions, DateTime Function()? clock}) {
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

  /// Go-to-change (Story 10.6 items 11–12; 10.21 calls it): selects [key], reveals it centred and pulses it; nothing
  /// when the shown layout lacks it.
  void goTo(String key) {
    if (_layout?.indexOfKey(key) == null) {
      return;
    }
    select(key);
    _revealExplicit(key);
    _pulse.value = GraphPulse(key, ++_pulseSerial);
  }

  /// Runs `jj edit` on [key] through [run] (a double-click, no confirmation); null when [init] was given no
  /// [GraphActions].
  Future<GraphActionResult?> edit(String key) async => _actions == null ? null : run(GraphEdit(key));

  /// Whether a trigger may run an action now: none runs and the working copy is not stale.
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
  GraphOutcome? get redoable => _redoable;

  /// The change a menu verb acts on: the selection, else @ (11.13).
  String? get actionTarget =>
      _selected ??
      switch (_layout) {
        final GraphLayout layout => _workingCopyKey(layout),
        null => null,
      };

  /// Shows [revset] and re-centres on @ — or reveals [reveal] instead (the precedence).
  void setRevset(String revset, {String? reveal}) {
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

  /// The effective config changed without an operation (item 16): re-reads `logDefaults()` — a revset still on the
  /// old `revsets.log` follows the new one — and requests under the anchor.
  void configChanged() {
    _rereadDefaults = true;
    _requestLayout();
  }

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
  Future<GraphActionResult> redoLast() async {
    final GraphOutcome? own = _redoable;
    if (_disabled ?? (own == null ? GraphDisabledReason.nothingToUndo : null) case final reason?) {
      return GraphActionDisabled(reason);
    }
    return _execute(GraphRedo((own!.action as GraphUndo).of), expectHead: own.result!.newOpId);
  }

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
      case GraphRevert(:final id):
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
      case GraphAbandon():
        _selected = null;
      case GraphSquash():
        if (plan.destination != null && result.abandonedChangeIds.contains(selected)) {
          _selected = plan.destination;
        }
      default:
        break;
    }
    if (born != null && (action is GraphNew || action is GraphRevert)) {
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
    if (_inFlight || layout == null) {
      _explicit = (key: key, alignment: GraphRevealAlignment.centre);
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
      if (_defaults == null || _rereadDefaults) {
        final String? old = _defaults?.log;
        final LogDefaults fresh = await _source.logDefaults();
        if (_disposed) {
          return;
        }
        _rereadDefaults = false;
        if (_revset == old) {
          _revset = null;
        }
        _defaults = fresh;
      }
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
    prioritize: defaults.logGraphPrioritize,
    shortPrefixes: defaults.shortPrefixes,
    anchors: defaultGraphAnchors,
    utcOffsetMin: _clock().timeZoneOffset.inMinutes,
    keepOpenKeys: <String>{?_selected, ?_explicit?.key},
  );

  void _land(GraphLoad load) {
    final GraphLayout layout = load.layout;
    _layout = layout;
    _warnings = load.warnings;
    _precondition = load.precondition;
    _revsetError = null;
    _error = null;
    _stale = null;
    final String? selected = _selected;
    if (selected != null && layout.indexOfKey(selected) == null) {
      _selected = null;
    }
    final ({String? key, GraphRevealAlignment alignment})? explicit = _explicit;
    final String? target = explicit != null
        ? explicit.key ?? _workingCopyKey(layout)
        : (_recentre ? _workingCopyKey(layout) : null);
    _reveal = target == null
        ? null
        : GraphReveal(target, alignment: explicit?.alignment ?? GraphRevealAlignment.centre);
    _explicit = null;
    _recentre = false;
    // A layout landing while the action still runs keeps its anchor for the reload after it.
    if (_running == null) {
      _anchorHint = null;
    }
    _now.value = _nowMs;
  }

  void _fail(ZanshinFfiException error) {
    if (_running == null) {
      _anchorHint = null;
    }
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
    _outcome.dispose();
    _content?.dispose();
    super.dispose();
  }
}
