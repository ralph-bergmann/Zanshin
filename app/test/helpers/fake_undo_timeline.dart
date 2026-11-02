// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/undo_timeline/operation_changes.dart';
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

/// One [FakeOperationChangesSource.diff] call.
typedef DiffCall = ({String? revision, String? from, String? to, bool interdiff, bool summary, List<String> paths});

/// An [OperationChangesSource] answering [opShowReply], [entries] and [diffReply], recording every call; a set
/// [refuseOpShow] / [refuseShow] / [refuseDiff] is thrown instead.
class FakeOperationChangesSource implements OperationChangesSource {
  /// A source answering [opShowReply].
  FakeOperationChangesSource(this.opShowReply, {this.entries = const <ShowEntry>[], Diff Function(DiffCall)? diff})
    : diffReply = diff ?? ((_) => testDiff(const <String>[]));

  /// The `opShow` reply.
  OpShow opShowReply;

  /// The `show` reply.
  List<ShowEntry> entries;

  /// The `diff` reply per call.
  Diff Function(DiffCall call) diffReply;

  /// Thrown by `opShow` while set.
  ZanshinFfiException? refuseOpShow;

  /// Thrown by `show` while set.
  ZanshinFfiException? refuseShow;

  /// Thrown by `diff` while set.
  ZanshinFfiException? refuseDiff;

  /// While set, a `diff` (recorded first) waits for it.
  Completer<void>? diffGate;

  /// Every `opShow` operation asked for.
  final opShows = <String>[];

  /// Every `show` revset asked for.
  final shows = <String>[];

  /// Every `diff` call.
  final diffs = <DiffCall>[];

  @override
  Future<OpShow> opShow(String operation) async {
    opShows.add(operation);
    if (refuseOpShow case final error?) {
      throw error;
    }
    return opShowReply;
  }

  @override
  Future<List<ShowEntry>> show(String revset) async {
    shows.add(revset);
    if (refuseShow case final error?) {
      throw error;
    }
    return entries;
  }

  @override
  Future<Diff> diff({
    String? revision,
    String? from,
    String? to,
    bool interdiff = false,
    bool summary = false,
    List<String> paths = const <String>[],
  }) async {
    final DiffCall call = (
      revision: revision,
      from: from,
      to: to,
      interdiff: interdiff,
      summary: summary,
      paths: paths,
    );
    diffs.add(call);
    await diffGate?.future;
    if (refuseDiff case final error?) {
      throw error;
    }
    return diffReply(call);
  }
}

/// A one-hunk file diff of [path]: `-old` / `+new`.
FileDiff testFileDiff(String path, {FileChangeKind kind = FileChangeKind.modified}) => FileDiff(
  path: path,
  kind: kind,
  fromPath: null,
  binary: false,
  modeChange: false,
  sections: const <HunkKey>[],
  hunks: const <Hunk>[
    Hunk(
      before: (start: 0, end: 1),
      after: (start: 0, end: 1),
      symbol: null,
      sections: <HunkKey>[],
      removed: 1,
      added: 1,
      lines: <HunkLine>[
        HunkLine(kind: HunkLineKind.removed, text: 'old\n'),
        HunkLine(kind: HunkLineKind.added, text: 'new\n'),
      ],
    ),
  ],
  removed: 1,
  added: 1,
  fingerprint: 'f-$path',
);

/// A diff of [paths].
Diff testDiff(List<String> paths) => Diff(
  files: <FileDiff>[for (final path in paths) testFileDiff(path)],
  operationId: 'op',
  commitIds: const <String>[],
);

/// A `jj op show` reply for [operation] with [changes] (no ref changes).
OpShow testOpShow(
  Operation operation,
  List<OpChangedCommit> changes, {
  List<OpWorkingCopyChange> workingCopies = const [],
}) => OpShow(
  operation: operation,
  diff: OpDiff(
    commits: OpCommitsDiff(
      changes: changes,
      elidedNewlyVisible: const RefDistance(lower: 0, upper: 0),
      elidedNewlyHidden: const RefDistance(lower: 0, upper: 0),
    ),
    workingCopies: workingCopies,
    localBookmarks: const <OpRefChange>[],
    localTags: const <OpRefChange>[],
    remoteBookmarks: const <OpRemoteRefChange>[],
    remoteTags: const <OpRemoteRefChange>[],
  ),
);

/// The `show` entry of commit [commitId] of change [changeId], described [description].
ShowEntry testShowEntry(String changeId, String commitId, String description) {
  const signature = Signature(name: 'r', email: 'r@example.com', timestampMillis: 0, tzOffsetMinutes: 0);
  return ShowEntry(
    change: Change(
      id: changeId,
      commitId: commitId,
      parents: const <String>[],
      description: description,
      author: signature,
      committer: signature,
      isSigned: false,
      conflict: ConflictState.clean,
      conflictedPaths: const <String>[],
      isAnonymous: false,
      divergent: false,
    ),
    fileChanges: const <FileChange>[],
  );
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
