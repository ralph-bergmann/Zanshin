// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:inject_annotation/inject_annotation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_layout.dart';
import 'graph_ports.dart';
import 'graph_viewport.dart' show GraphReveal;

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
/// hint names (cli_util.rs:3040-3075 @ v0.46.0).
@immutable
class GraphStale {
  /// A stale state.
  const GraphStale({required this.cause, required this.message, required this.command});

  /// Parses `jj.stale_working_copy`'s context, `<cause>\n<working_copy_op_id>\n<repo_op_id>`; an unknown cause reads
  /// as [GraphStaleCause.stale].
  factory GraphStale.fromContext(String? context) {
    final List<String> parts = (context ?? '').split('\n');
    // jj's `short_operation_hash`: the first 12 hex.
    String op(int i) => i < parts.length ? (parts[i].length > 12 ? parts[i].substring(0, 12) : parts[i]) : '';
    final String wc = op(1);
    return switch (parts.first) {
      'sibling_operation' => GraphStale(
        cause: GraphStaleCause.siblingOperation,
        message:
            "The repo was loaded at operation ${op(2)}, which seems to be a sibling of the working copy's operation $wc",
        command: 'jj op integrate $wc',
      ),
      'operation_not_found' => const GraphStale(
        cause: GraphStaleCause.operationNotFound,
        message: "Could not read working copy's operation.",
        command: updateStaleCommand,
      ),
      _ => GraphStale(
        cause: GraphStaleCause.stale,
        message: 'The working copy is stale (not updated since operation $wc).',
        command: updateStaleCommand,
      ),
    };
  }

  /// The command 9.23's action runs; it recovers all three causes.
  static const updateStaleCommand = 'jj workspace update-stale';

  /// The cause.
  final GraphStaleCause cause;

  /// jj's message.
  final String message;

  /// The command jj's hint names.
  final String command;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphStale && other.cause == cause && other.message == message && other.command == command;

  @override
  int get hashCode => Object.hash(cause, message, command);
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
@inject
class GraphViewModel extends ChangeNotifier {
  /// A view model; [init] connects it.
  GraphViewModel();

  late GraphSource _source;
  GraphActions? _actions;
  DateTime Function() _clock = DateTime.now;
  StreamSubscription<RepoEvent>? _events;
  Timer? _tick;
  final _now = ValueNotifier<int>(0);
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
  ({String? key})? _explicit;
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
    _actions = actions;
    _clock = clock ?? DateTime.now;
    _now.value = _nowMs;
    _scheduleTick();
    _events = source.events.listen(_onEvent);
    _requestLayout();
  }

  /// The last landed layout; null before the first.
  GraphLayout? get layout => _layout;

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

  /// Shows [revset] and re-centres on @ — or reveals [reveal] instead (the precedence).
  void setRevset(String revset, {String? reveal}) {
    _revset = revset;
    _recentre = true;
    if (reveal != null) {
      _explicit = (key: reveal);
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

  /// Runs [action] (10.9) and reloads after it ran.
  Future<GraphActionResult> run(GraphAction action) async {
    final GraphActions? actions = _actions;
    if (actions == null) {
      throw StateError('GraphViewModel.init was given no GraphActions');
    }
    final GraphActionResult result = await actions.run(action);
    if (result is GraphActionDone) {
      reload();
    }
    return result;
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
      _explicit = (key: key);
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
    final ({String? key})? explicit = _explicit;
    final String? target = explicit != null
        ? explicit.key ?? _workingCopyKey(layout)
        : (_recentre ? _workingCopyKey(layout) : null);
    _reveal = target == null ? null : GraphReveal(target);
    _explicit = null;
    _recentre = false;
    _now.value = _nowMs;
  }

  void _fail(ZanshinFfiException error) {
    _revsetError = null;
    _error = null;
    _stale = null;
    switch (error.code) {
      case 'jj.revset_parse_error' || 'jj.revset_resolution_error':
        _revsetError = error;
      case 'jj.stale_working_copy':
        _stale = GraphStale.fromContext(error.context);
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
    super.dispose();
  }
}
