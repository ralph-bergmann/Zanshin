// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:zanshin/src/features/graph/graph_layout.dart';
import 'package:zanshin/src/features/graph/graph_ports.dart';
import 'package:zanshin_core/zanshin_core.dart';

/// The catalogue's [GraphSource] (Story 10.5): [layoutOf] answers each request (the recordings), jj's builtin `jj log`
/// defaults, no events; while [staleCause] is set every layout refuses `jj.stale_working_copy` with it, and
/// [updateStale] clears it after a short wait.
class FakeGraphSource implements GraphSource {
  /// A source answering with [layoutOf].
  FakeGraphSource(this.layoutOf, {this.staleCause});

  /// The layout of a request.
  final GraphLayout Function(GraphRequest request) layoutOf;

  /// `stale`, `sibling_operation` or `operation_not_found`; null answers.
  String? staleCause;

  /// jj's builtin defaults (v0.46.0 `revsets.toml`).
  static const defaults = LogDefaults(
    log: 'builtin_log()',
    logGraphPrioritize: 'present(@)',
    shortPrefixes: 'builtin_log()',
    syntheticElided: false,
  );

  @override
  Future<GraphLoad> layout(GraphRequest request) async {
    final String? cause = staleCause;
    if (cause != null) {
      throw ZanshinFfiException('jj.stale_working_copy', '$cause\n${'3f9a2c71d0e4' * 2}\n${'b81e6d09c5a7' * 2}');
    }
    return GraphLoad(layoutOf(request));
  }

  @override
  Stream<RepoEvent> get events => const Stream<RepoEvent>.empty();

  @override
  Future<LogDefaults> logDefaults() async => defaults;

  @override
  Future<StaleRecovery> updateStale() async {
    await Future<void>.delayed(const Duration(milliseconds: 800));
    staleCause = null;
    return const StaleRecovery(
      outcome: StaleRecoveryOutcome.updated,
      commitId: null,
      checkout: null,
      gitHeadResetOpId: null,
      snapshotStats: SnapshotStats(untracked: <UntrackedPath>[], invalidUtf8Paths: <String>[]),
      opId: '',
    );
  }
}
