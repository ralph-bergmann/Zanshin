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
      throw staleError(cause);
    }
    return GraphLoad(layoutOf(request));
  }

  /// `jj.stale_working_copy` for [cause] as Rust sends it (docs/rust-error-codes.md): the op ids, jj's message as the
  /// context's fourth line, jj's hint.
  static ZanshinFfiException staleError(String cause) {
    const wc = '3f9a2c71d0e4';
    const repo = 'b81e6d09c5a7';
    const see = 'See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.';
    final (String message, String hint) = switch (cause) {
      'sibling_operation' => (
        "The repo was loaded at operation $repo, which seems to be a sibling of the working copy's operation $wc",
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
      '$cause\n${wc * 2}\n${repo * 2}\n$message',
      precondition: null,
      warnings: const <ZanshinWarning>[],
      hints: <String>[hint],
    );
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
