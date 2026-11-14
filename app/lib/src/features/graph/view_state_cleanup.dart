// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_ports.dart';
import 'graph_view_model.dart';
import 'inspector_viewed_store.dart';

final _log = Logger('zanshin.graph');

/// `RepoHandle.findChanges`: at most `limit` commits `expression` denotes at `operationId`.
typedef ViewStateFind = Future<FoundChanges> Function(
  String operationId,
  String expression, {
  required int limit,
  required String shortPrefixes,
});

// jj's change ids are reverse hex, its commit ids hex: disjoint alphabets.
final _changeId = RegExp(r'^[k-z]+$');
final _commitId = RegExp(r'^[0-9a-f]+$');

/// Drops the view state of changes that are gone (Story 10.37): once [graph]'s first layout lands, one [find] of
/// `(change_id(a) | commit_id(b) | …) & ::visible_heads()` at its operation over the ids of [viewed]'s keys and [stacks]'
/// toggles; the queried ids it does not find are dropped from both. It goes by existence in the repository, never by
/// what the graph shows. A key whose id is neither a change nor a commit id stays, and a truncated result or a failed
/// query drops nothing.
class ViewStateCleanup {
  /// The cleanup of [stacks] and [viewed] against [graph]'s repository.
  ViewStateCleanup({required this.graph, required this.stacks, required this.viewed, required this.find}) {
    graph.addListener(_graphChanged);
    _graphChanged();
  }

  /// The graph whose first layout starts the pass.
  final GraphViewModel graph;

  /// The stack toggles.
  final GraphStackStore stacks;

  /// The Viewed marks.
  final InspectorViewedStore viewed;

  /// The existence query.
  final ViewStateFind find;

  var _started = false;
  var _disposed = false;

  static String _idOf(String viewedKey) {
    final int colon = viewedKey.indexOf(':');
    return colon < 0 ? viewedKey : viewedKey.substring(0, colon);
  }

  void _graphChanged() {
    final String? operationId = graph.layout?.operationId;
    if (_started || operationId == null) {
      return;
    }
    _started = true;
    graph.removeListener(_graphChanged);
    unawaited(_run(operationId));
  }

  Future<void> _run(String operationId) async {
    final GraphStackToggles toggles = stacks.load();
    final ids = <String>{for (final String key in viewed.load()) _idOf(key), ...toggles.expanded, ...toggles.collapsed};
    final queried = <String>{};
    final terms = <String>[];
    for (final id in ids) {
      final String? term = _changeId.hasMatch(id)
          ? 'change_id($id)'
          : (_commitId.hasMatch(id) ? 'commit_id($id)' : null);
      if (term != null) {
        queried.add(id);
        terms.add(term);
      }
    }
    if (terms.isEmpty) {
      return;
    }
    final FoundChanges found;
    try {
      found = await find(
        operationId,
        // `visible()` is a user-overridable alias; its builtin definition is not.
        '(${terms.join(' | ')}) & ::visible_heads()',
        limit: 4 * terms.length,
        shortPrefixes: '',
      );
    } on ZanshinFfiException catch (error) {
      _log.warning('the view state cleanup query failed: ${error.code}');
      return;
    } on Object catch (error, stack) {
      // A closed handle (the project closed mid-query) throws a StateError: nothing is dropped either way.
      _log.warning('the view state cleanup query failed: ${error.runtimeType}', error, stack);
      return;
    }
    if (_disposed || found.truncated) {
      return;
    }
    final Set<String> gone = queried.difference(<String>{
      for (final FoundChange change in found.entries) ...<String>[change.changeId, change.commitId],
    });
    if (gone.isEmpty) {
      return;
    }
    // Read again: a toggle or a mark may have landed while the query ran.
    final Set<String> keys = viewed.load();
    final Set<String> keptKeys = keys.where((key) => !gone.contains(_idOf(key))).toSet();
    if (keptKeys.length != keys.length) {
      viewed.save(keptKeys);
    }
    final GraphStackToggles current = stacks.load();
    final kept = GraphStackToggles(
      expanded: current.expanded.where((key) => !gone.contains(key)).toSet(),
      collapsed: current.collapsed.where((key) => !gone.contains(key)).toSet(),
    );
    if (kept != current) {
      stacks.save(kept);
    }
  }

  /// Stops the pass: a reply after this writes nothing.
  void dispose() {
    _disposed = true;
    graph.removeListener(_graphChanged);
  }
}
