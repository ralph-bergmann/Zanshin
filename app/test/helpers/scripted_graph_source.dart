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
}

/// `jj.stale_working_copy` for [cause] with full 40-hex op ids `aaaa…` (working copy) and `bbbb…` (repo).
ZanshinFfiException staleError(String cause) =>
    ZanshinFfiException('jj.stale_working_copy', '$cause\n${'a' * 40}\n${'b' * 40}');
