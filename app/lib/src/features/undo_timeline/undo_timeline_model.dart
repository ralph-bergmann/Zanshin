// SPDX-License-Identifier: MIT

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../graph/graph_ports.dart';
import '../projects/project_repos.dart';

final _log = Logger('zanshin.undo_timeline');

/// What the Undo Timeline reads (Story 11.9). A failed call throws [ZanshinFfiException].
abstract interface class UndoTimelineSource {
  /// The [limit] newest operations, newest first (`jj op log -n <limit>`, which snapshots first).
  Future<List<Operation>> opLog({required int limit});

  /// The repository's watcher events.
  Stream<RepoEvent> get events;
}

/// [UndoTimelineSource] over an open [ProjectRepo].
class RepoUndoTimelineSource implements UndoTimelineSource {
  /// The op log of [_repo].
  RepoUndoTimelineSource(this._repo);

  final ProjectRepo _repo;

  @override
  Future<List<Operation>> opLog({required int limit}) => _repo.handle.opLog(limit: limit);

  @override
  Stream<RepoEvent> get events => _repo.events;
}

/// The runner the Undo Timeline's actions go through: 10.9's `GraphViewModel` (busy, stale, the expect-head check, the
/// published outcome the toast shows, Zanshin's own undo/redo state). It notifies when any of these change.
abstract interface class UndoTimelineActions implements Listenable {
  /// Whether a trigger may run an action now.
  bool get actionsEnabled;

  /// Zanshin's own latest undo while it is the op-log head; [redoLast] takes it back.
  GraphOutcome? get redoable;

  /// `jj undo` while [head] (an id) is still the op-log head; [of] names the operation it takes back.
  Future<GraphActionResult> undoOperation(String head, GraphLoggedOperation of);

  /// `jj redo` of [redoable].
  Future<GraphActionResult> redoLast();

  /// `jj redo` while [head] (an id) is still the op-log head; [of] names the operation it brings back.
  Future<GraphActionResult> redoOperation(String head, GraphLoggedOperation of);

  /// `jj op restore <operation>`.
  Future<GraphActionResult> restoreOperation(String operation);
}

/// [id] as jj shows and takes an operation id: its first 12 hex digits (`format_short_operation_id`).
String shortOperationId(String id) => id.substring(0, math.min(12, id.length));

/// The value of [operation]'s `args` tag (the command line that wrote it), or null.
String? operationArgs(Operation operation) {
  for (final OperationTag tag in operation.tags) {
    if (tag.key == 'args') {
      return tag.value;
    }
  }
  return null;
}

/// [operation] as a [GraphUndo] names what it undid.
GraphLoggedOperation loggedOperation(Operation operation) =>
    GraphLoggedOperation(operation.id, operation.description.split('\n').first, args: operationArgs(operation));

// `UNDO_OP_DESC_PREFIX` / `REDO_OP_DESC_PREFIX`, `../jj` v0.46.0 cli/src/commands/{undo,redo}.rs.
const _undoPrefix = 'undo: restore to operation '; // l10n-ignore: jj's description
const _redoPrefix = 'redo: restore to operation '; // l10n-ignore: jj's description

/// The Undo Timeline's state (Story 11.9): the newest [operations] of the op log, read in pages of [pageSize] — the
/// bridge has no offset, so [loadMore] re-reads from the head with a larger limit — and reloaded with the current limit
/// on every `OpHeadsChangedEvent` (and, while [stale], every `WorkingCopyHeartbeatEvent`). At most one read runs; a
/// read asked for meanwhile runs once after it. A failed read keeps the rows shown; jj's refusal of a stale working
/// copy sets [stale]. [now] is fresh on every read and ticks each minute, for the relative times.
class UndoTimelineModel extends ChangeNotifier {
  /// A model over [_source]; [clock] gives "now".
  UndoTimelineModel(this._source, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now {
    _now = _clock();
    _events = _source.events.listen(_event);
    _tick = Timer.periodic(const Duration(minutes: 1), (_) {
      _now = _clock();
      notifyListeners();
    });
    _load();
  }

  /// The rows one page adds.
  static const pageSize = 50;

  final UndoTimelineSource _source;
  final DateTime Function() _clock;
  late final StreamSubscription<RepoEvent> _events;
  late final Timer _tick;

  var _operations = const <Operation>[];
  late DateTime _now;
  var _loading = true;
  var _stale = false;
  ZanshinFfiException? _error;

  /// The limit of the rows shown.
  int _limit = pageSize;

  /// The limit the next read asks for.
  int _wanted = pageSize;
  var _inFlight = false;
  var _queued = false;
  var _disposed = false;

  /// The newest operations, newest first; the first is the current operation.
  List<Operation> get operations => _operations;

  /// Whether a read runs.
  bool get loading => _loading;

  /// Whether jj refused the last read for a stale working copy.
  bool get stale => _stale;

  /// The last read's error other than [stale]; null after a read succeeded.
  ZanshinFfiException? get error => _error;

  /// "Now", for the relative times.
  DateTime get now => _now;

  /// Whether the newest operation cannot be undone: what `jj undo` would take back ([undoTarget]) is the root
  /// operation, or its parent is (9.21 item 2).
  bool get headOnRoot {
    final Operation? head = _operations.firstOrNull;
    if (head == null) {
      return true;
    }
    final Operation target = undoTarget(head);
    return target.rootOp || _operations.any((op) => op.rootOp && target.parentIds.contains(op.id));
  }

  /// The operation `jj undo` takes back while [head] is current (`cli/src/commands/undo.rs:106-118` @ v0.46.0): an
  /// undo-operation's own target, else [head]; [head] when the target is not among [operations].
  Operation undoTarget(Operation head) => _restoredBy(head, _undoPrefix) ?? head;

  /// The operation `jj redo` brings back while [head] is current (`cli/src/commands/redo.rs:108-129` @ v0.46.0), or
  /// null when jj has nothing to redo: a redo-operation is followed to its target, which must be an undo-operation;
  /// its parent is restored — or, when that parent is a redo-operation, the operation it restored. A target or parent
  /// not among [operations] falls back to [head].
  Operation? redoTarget(Operation head) {
    final Operation target = head.description.startsWith(_redoPrefix) ? _restoredBy(head, _redoPrefix) ?? head : head;
    if (!target.description.startsWith(_undoPrefix)) {
      return null;
    }
    final Operation? parent = _byId(target.parentIds.firstOrNull);
    return parent == null ? head : _restoredBy(parent, _redoPrefix) ?? parent;
  }

  /// The operation [operation]'s description after [prefix] names.
  Operation? _restoredBy(Operation operation, String prefix) =>
      operation.description.startsWith(prefix) ? _byId(operation.description.substring(prefix.length).trim()) : null;

  Operation? _byId(String? id) {
    for (final Operation operation in _operations) {
      if (operation.id == id) {
        return operation;
      }
    }
    return null;
  }

  /// Reads one more page, unless every operation is shown, a larger page is already asked for, or the last read
  /// failed (the next event retries).
  void loadMore() {
    if (_disposed || _error != null || _operations.length < _limit || _wanted > _limit) {
      return;
    }
    _wanted = _limit + pageSize;
    _load();
  }

  void _event(RepoEvent event) {
    if (event is OpHeadsChangedEvent || (event is WorkingCopyHeartbeatEvent && _stale)) {
      _load();
    }
  }

  void _load() {
    if (_inFlight) {
      _queued = true;
      return;
    }
    unawaited(_read());
  }

  Future<void> _read() async {
    _inFlight = true;
    if (!_loading) {
      _loading = true;
      notifyListeners();
    }
    final int limit = _wanted;
    try {
      final List<Operation> operations = await _source.opLog(limit: limit);
      _operations = List<Operation>.unmodifiable(operations);
      _limit = limit;
      _stale = false;
      _error = null;
    } on ZanshinFfiException catch (error) {
      _wanted = _limit;
      if (isStale(error)) {
        _stale = true;
        _error = null;
      } else {
        _error = error;
      }
    } catch (error) {
      // Not jj's refusal (a closed handle): the read is unawaited, so it is logged here and the rows stay.
      _wanted = _limit;
      _error = ZanshinFfiException('ffi.unknown', '$error');
      _log.warning('reading the op log failed: ${error.runtimeType}');
    } finally {
      _inFlight = false;
    }
    if (_disposed) {
      return;
    }
    _now = _clock();
    if (_queued) {
      _queued = false;
      _load();
    } else {
      _loading = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _tick.cancel();
    unawaited(_events.cancel());
    super.dispose();
  }
}
