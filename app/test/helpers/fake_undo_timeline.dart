// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/undo_timeline/undo_timeline_model.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// The root operation's id.
final String rootOpId = '0' * 128;

/// The id of operation [i] of a test log: `1a2b3c4d5e6f` plus [i], padded to 128 hex digits.
String opId(int i) => (0x1a2b3c4d5e6f + i).toRadixString(16).padRight(128, '0');

/// Operation [i] of a test log, newest first, its parent operation `i + 1` (or [parent]).
Operation testOperation(
  int i, {
  required DateTime now,
  String? parent,
  String? description,
  String? args,
  bool snapshot = false,
  String? workspace = 'default',
}) => Operation(
  id: opId(i),
  parentIds: <String>[parent ?? opId(i + 1)],
  timestampMillis: now.subtract(Duration(hours: i)).millisecondsSinceEpoch,
  tzOffsetMinutes: 0,
  user: 'ralph',
  host: 'mac',
  description: description ?? 'operation $i',
  rootOp: false,
  isSnapshot: snapshot,
  workspaceName: workspace,
  tags: <OperationTag>[if (args != null) OperationTag(key: 'args', value: args)],
);

/// The root operation.
Operation testRoot() => Operation(
  id: rootOpId,
  parentIds: const <String>[],
  timestampMillis: 0,
  tzOffsetMinutes: 0,
  user: '',
  host: '',
  description: '',
  rootOp: true,
  isSnapshot: false,
);

/// An [UndoTimelineSource] over [operations]: the limits asked in [limits], a refusal while [refuse] is set, a wait on
/// [gate], events through [emit].
class FakeTimelineSource implements UndoTimelineSource {
  /// A source over [operations].
  FakeTimelineSource(this.operations);

  /// The log, newest first.
  List<Operation> operations;

  /// Every limit asked for, in order.
  final limits = <int>[];

  /// While set, a read throws it.
  ZanshinFfiException? refuse;

  /// While set, a read waits for it.
  Completer<void>? gate;

  final _events = StreamController<RepoEvent>.broadcast(sync: true);

  /// Emits [event].
  void emit(RepoEvent event) => _events.add(event);

  /// Whether anyone listens to [events].
  bool get listened => _events.hasListener;

  @override
  Future<List<Operation>> opLog({required int limit}) async {
    limits.add(limit);
    await gate?.future;
    if (refuse case final error?) {
      throw error;
    }
    return operations.take(limit).toList();
  }

  @override
  Stream<RepoEvent> get events => _events.stream;
}

/// A runner recording its calls: idle unless [enabled] is false, [redoable] as set.
class FakeTimelineActions extends ChangeNotifier implements UndoTimelineActions {
  /// Each undoOperation's expected head and named operation.
  final undone = <(String, GraphLoggedOperation)>[];

  /// Each redoOperation's expected head and named operation.
  final redone = <(String, GraphLoggedOperation)>[];

  /// The restored operations.
  final restored = <String>[];

  /// How often redoLast ran.
  var redos = 0;

  /// Whether triggers may run.
  var enabled = true;

  @override
  GraphOutcome? redoable;

  @override
  bool get actionsEnabled => enabled;

  @override
  Future<GraphActionResult> undoOperation(String head, GraphLoggedOperation of) async {
    undone.add((head, of));
    return const GraphActionDisabled(GraphDisabledReason.busy);
  }

  @override
  Future<GraphActionResult> redoOperation(String head, GraphLoggedOperation of) async {
    redone.add((head, of));
    return const GraphActionDisabled(GraphDisabledReason.busy);
  }

  @override
  Future<GraphActionResult> redoLast() async {
    redos++;
    return const GraphActionDisabled(GraphDisabledReason.busy);
  }

  @override
  Future<GraphActionResult> restoreOperation(String operation) async {
    restored.add(operation);
    return const GraphActionDisabled(GraphDisabledReason.busy);
  }
}
