// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin/src/features/graph/recorded_graph_layout.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../features/graph/graph_harness.dart';

/// A layout of [keys], newest first, one per row in column 0; [at] is @'s key.
RecordedGraphLayout keysLayout(List<String> keys, {String? at}) {
  final int? wc = at == null ? null : keys.indexOf(at);
  return handLayout(
    <(String, int, int)>[for (var i = 0; i < keys.length; i++) (keys[i], keys.length - 1 - i, 0)],
    edges: <(int, int)>[for (var i = 0; i + 1 < keys.length; i++) (i, i + 1)],
    workingCopy: wc,
  );
}

/// A [GraphSource] a test scripts: [respond] answers each layout request (it may throw), or every request waits on
/// a completer in [held] while [hold] is set; [requests] records them.
class ScriptedGraphSource implements GraphSource {
  ScriptedGraphSource({GraphLayout Function(GraphRequest request)? respond})
    : respond = respond ?? ((_) => keysLayout(<String>['a', 'b', 'c'], at: 'a'));

  /// The answer to a request.
  GraphLayout Function(GraphRequest request) respond;

  /// The `logDefaults()` answer.
  var defaults = const LogDefaults(
    log: 'L',
    logGraphPrioritize: 'P',
    shortPrefixes: 'S',
    syntheticElided: false,
  );

  /// While set, `logDefaults()` waits on it.
  Completer<LogDefaults>? defaultsGate;

  /// Holds every layout request on a completer in [held].
  var hold = false;

  /// The held requests' completers, oldest first.
  final held = <Completer<GraphLoad>>[];

  /// Every layout request, oldest first.
  final requests = <GraphRequest>[];

  /// How many times `logDefaults()` was read.
  var defaultsReads = 0;

  /// Called on each layout request, before it is answered.
  void Function(GraphRequest request)? onLayout;

  /// The `updateStale()` answer.
  Future<StaleRecovery> Function() update = () async => const StaleRecovery(
    outcome: StaleRecoveryOutcome.updated,
    commitId: null,
    checkout: null,
    gitHeadResetOpId: null,
    snapshotStats: SnapshotStats(untracked: <UntrackedPath>[], invalidUtf8Paths: <String>[]),
    opId: 'op',
  );

  var updates = 0;

  /// The answer to a content page (it may throw); the default gives each id a subject naming it, so a view's cards
  /// fill before any skeleton shows.
  Map<String, GraphCommitContent> Function(String? operationId, List<String> commitIds) contentRespond = (_, ids) =>
      <String, GraphCommitContent>{for (final String id in ids) id: GraphCommitContent(subject: 'about $id')};

  /// Holds every content page on a completer in [heldContent].
  var holdContent = false;

  /// The held content pages' completers, oldest first.
  final heldContent = <Completer<Map<String, GraphCommitContent>>>[];

  /// Every content page, oldest first.
  final contentRequests = <({String? operationId, List<String> commitIds})>[];

  @override
  Future<Map<String, GraphCommitContent>> content(String? operationId, List<String> commitIds) {
    contentRequests.add((operationId: operationId, commitIds: commitIds));
    if (holdContent) {
      final completer = Completer<Map<String, GraphCommitContent>>();
      heldContent.add(completer);
      return completer.future;
    }
    return Future<Map<String, GraphCommitContent>>.sync(() => contentRespond(operationId, commitIds));
  }

  final _events = StreamController<RepoEvent>.broadcast(sync: true);

  /// Emits [event] on [events].
  void emit(RepoEvent event) => _events.add(event);

  @override
  Future<GraphLoad> layout(GraphRequest request) {
    requests.add(request);
    onLayout?.call(request);
    if (hold) {
      final completer = Completer<GraphLoad>();
      held.add(completer);
      return completer.future;
    }
    return Future<GraphLoad>.sync(() => GraphLoad(respond(request)));
  }

  @override
  Stream<RepoEvent> get events => _events.stream;

  @override
  Future<LogDefaults> logDefaults() async {
    defaultsReads++;
    return defaultsGate?.future ?? defaults;
  }

  @override
  Future<StaleRecovery> updateStale() {
    updates++;
    return update();
  }

  /// The real parents (change ids) `show` answers per commit id; an id without an entry throws `jj.not_found`.
  var parentsOf = <String, List<String>>{};

  /// Every `show`, oldest first.
  final shows = <String>[];

  @override
  Future<ShowEntry> show(String commitId) async {
    shows.add(commitId);
    final List<String>? parents = parentsOf[commitId];
    if (parents == null) {
      throw const ZanshinFfiException('jj.not_found');
    }
    return showEntryOf(commitId, parents);
  }
}

/// A `show` answer for [commitId] with [parents] and nothing else.
ShowEntry showEntryOf(String commitId, List<String> parents) {
  const nobody = Signature(name: '', email: '', timestampMillis: 0, tzOffsetMinutes: 0);
  return ShowEntry(
    change: Change(
      id: commitId,
      commitId: commitId,
      parents: parents,
      description: '',
      author: nobody,
      committer: nobody,
      isSigned: false,
      conflict: ConflictState.clean,
      conflictedPaths: const <String>[],
      isAnonymous: true,
      divergent: false,
    ),
    fileChanges: const <FileChange>[],
  );
}

/// `jj.stale_working_copy` for [cause] shaped as Rust sends it (docs/rust-error-codes.md): 40-hex stand-ins `aaaa…`
/// (working copy) and `bbbb…` (repo) for the 128-hex op ids, jj's message as the context's fourth line, jj's hint.
ZanshinFfiException staleError(String cause) {
  const wc = 'aaaaaaaaaaaa';
  const see = 'See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.';
  final (String message, String hint) = switch (cause) {
    'sibling_operation' => (
      "The repo was loaded at operation bbbbbbbbbbbb, which seems to be a sibling of the working copy's operation $wc",
      "Run `jj op integrate $wc` to add the working copy's operation to the operation log.",
    ),
    'operation_not_found' => (
      "Could not read working copy's operation.",
      'Run `jj workspace update-stale` to recover.\n$see',
    ),
    _ => (
      'The working copy is stale (not updated since operation $wc).',
      'Run `jj workspace update-stale` to update it.\n$see',
    ),
  };
  return ZanshinFfiException.withReport(
    'jj.stale_working_copy',
    '$cause\n${'a' * 40}\n${'b' * 40}\n$message',
    precondition: null,
    warnings: const <ZanshinWarning>[],
    hints: <String>[hint],
  );
}
