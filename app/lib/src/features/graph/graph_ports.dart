// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../projects/project_repos.dart';
import 'graph_layout.dart';

/// One layout request (Story 10.5 item 2): the revset and the view's mode and lane order, plus the jj parameters
/// passed through explicitly (FR-JJ-17) — `prioritize` and `shortPrefixes` pre-filled from `logDefaults()`, `anchors`
/// from zanshin_core's [defaultGraphAnchors] — and the stack state (10.17). It carries no card size and no "now".
@immutable
class GraphRequest {
  /// A request for [revset].
  const GraphRequest({
    required this.revset,
    required this.prioritize,
    required this.shortPrefixes,
    required this.anchors,
    required this.utcOffsetMin,
    this.mode = GraphMode.free,
    this.order = GraphLaneOrder.compact,
    this.stacks = false,
    this.expandedKeys = const <String>{},
    this.collapsedKeys = const <String>{},
    this.keepOpenKeys = const <String>{},
  });

  /// The revset shown.
  final String revset;

  /// The layout mode.
  final GraphMode mode;

  /// The lane order.
  final GraphLaneOrder order;

  /// `revsets.log-graph-prioritize`.
  final String prioritize;

  /// `revsets.short-prefixes`.
  final String shortPrefixes;

  /// The priority anchors.
  final List<String> anchors;

  /// The fixed UTC offset, in minutes, the day buckets are cut at.
  final int utcOffsetMin;

  /// Whether linear runs group into stacks (10.17).
  final bool stacks;

  /// The stacks the user expanded.
  final Set<String> expandedKeys;

  /// The stacks the user collapsed.
  final Set<String> collapsedKeys;

  /// The keys whose stack stays open: the selection and a pending reveal target.
  final Set<String> keepOpenKeys;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is GraphRequest &&
          other.revset == revset &&
          other.mode == mode &&
          other.order == order &&
          other.prioritize == prioritize &&
          other.shortPrefixes == shortPrefixes &&
          listEquals(other.anchors, anchors) &&
          other.utcOffsetMin == utcOffsetMin &&
          other.stacks == stacks &&
          setEquals(other.expandedKeys, expandedKeys) &&
          setEquals(other.collapsedKeys, collapsedKeys) &&
          setEquals(other.keepOpenKeys, keepOpenKeys);

  @override
  int get hashCode => Object.hash(
    revset,
    mode,
    order,
    prioritize,
    shortPrefixes,
    Object.hashAll(anchors),
    utcOffsetMin,
    stacks,
    Object.hashAllUnordered(expandedKeys),
    Object.hashAllUnordered(collapsedKeys),
    Object.hashAllUnordered(keepOpenKeys),
  );

  @override
  String toString() => 'GraphRequest($revset, ${mode.name}, ${order.name}, keepOpen: $keepOpenKeys)';
}

/// What one layout call returned: the [layout], the call's [warnings] in the CLI's print order, and its pre-verb
/// snapshot report.
@immutable
class GraphLoad {
  /// A load of [layout].
  const GraphLoad(this.layout, {this.warnings = const <ZanshinWarning>[], this.precondition});

  /// The layout.
  final GraphLayout layout;

  /// The call's warnings.
  final List<ZanshinWarning> warnings;

  /// The call's snapshot report, when it ran one.
  final Precondition? precondition;
}

/// What the graph reads (Story 10.5 item 1). A failed call throws [ZanshinFfiException].
abstract interface class GraphSource {
  /// Lays out [request].
  Future<GraphLoad> layout(GraphRequest request);

  /// The repository's watcher events.
  Stream<RepoEvent> get events;

  /// The effective `jj log` defaults.
  Future<LogDefaults> logDefaults();

  /// `jj workspace update-stale` (Story 9.23).
  Future<StaleRecovery> updateStale();
}

/// One verb with its change ids and parameters.
@immutable
class GraphAction {
  /// Runs [verb] on [ids].
  const GraphAction(this.verb, {this.ids = const <String>[], this.parameters = const <String, Object?>{}});

  /// The jj verb.
  final String verb;

  /// The change ids it acts on.
  final List<String> ids;

  /// Its CLI parameters, passed through.
  final Map<String, Object?> parameters;
}

/// How a [GraphAction] ended.
sealed class GraphActionResult {
  const GraphActionResult();
}

/// The verb ran.
final class GraphActionDone extends GraphActionResult {
  /// A finished action.
  const GraphActionDone();
}

/// The verb refused, as jj would.
final class GraphActionRefused extends GraphActionResult {
  /// A refusal for [reason].
  const GraphActionRefused(this.reason);

  /// Why it refused.
  final String reason;
}

/// Runs verbs on the graph's changes; Story 10.9 implements it.
abstract interface class GraphActions {
  /// Runs [action].
  Future<GraphActionResult> run(GraphAction action);
}

/// [GraphSource] over an open [ProjectRepo] (`ProjectSession.repo`): its handle's events, `logDefaults` and
/// `workspaceUpdateStale`; the layout is the passed [layout] function until 10.12 adopts the backend layout.
class RepoGraphSource implements GraphSource {
  /// The source of [_repo], laying out with [layout].
  RepoGraphSource(this._repo, {required this._layout});

  final ProjectRepo _repo;
  final Future<GraphLoad> Function(GraphRequest request) _layout;

  @override
  Future<GraphLoad> layout(GraphRequest request) => _layout(request);

  @override
  Stream<RepoEvent> get events => _repo.events;

  @override
  Future<LogDefaults> logDefaults() => _repo.handle.logDefaults();

  @override
  Future<StaleRecovery> updateStale() => _repo.handle.workspaceUpdateStale();
}
