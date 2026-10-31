// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_layout.dart';

final _log = Logger('zanshin.graph');

/// The card content cache and its page loader (Story 10.11), keyed by commit id so it survives reloads: a commit's
/// content never changes, only which commits a layout shows.
///
/// [load] asks for the given nodes' missing content at the layout's operation. One page is in flight at a time; loads
/// arriving meanwhile replace one queued load, computed when it starts, and a page that returns while a load is queued
/// is dropped (10.5's coalescing rule). A failed page is logged and caches nothing, so the next load asks again.
class GraphContent extends ChangeNotifier {
  /// A cache filled through `fetch` (`GraphSource.content`).
  GraphContent(this._fetch);

  final Future<Map<String, GraphCommitContent>> Function(String? operationId, List<String> commitIds) _fetch;

  // shortcut: unbounded — 100k small entries are fine for one session; bound it if sessions grow past that.
  final _cache = <String, GraphCommitContent>{};
  ({GraphLayout layout, List<int> nodes})? _queued;
  var _running = false;
  var _disposed = false;

  /// The cached content of [commitId].
  GraphCommitContent? operator [](String commitId) => _cache[commitId];

  /// [node]'s content: the cache entry, else the layout's own (recordings and fixtures carry it inline).
  GraphCommitContent? of(GraphLayout layout, int node) => _cache[layout.commitIdOf(node)] ?? layout.contentOf(node);

  /// Loads the content of [nodes] of [layout] that is neither cached nor inline; nothing missing asks nothing. A stack
  /// node stands for its members (Story 10.17): their content is what its card and its list show.
  void load(GraphLayout layout, Iterable<int> nodes) {
    if (_disposed) {
      return;
    }
    _queued = (
      layout: layout,
      nodes: <int>[
        for (final int node in nodes)
          if (layout.isStackNode(node)) ...layout.runMembersOf(layout.runOf(node)!) else node,
      ],
    );
    if (!_running) {
      unawaited(_drain());
    }
  }

  Future<void> _drain() async {
    _running = true;
    try {
      while (!_disposed) {
        final ({GraphLayout layout, List<int> nodes})? next = _queued;
        if (next == null) {
          return;
        }
        _queued = null;
        final ids = <String>{
          for (final int node in next.nodes)
            // The root card shows `root()` and never waits for content.
            if (node != next.layout.rootIndex &&
                next.layout.contentOf(node) == null &&
                !_cache.containsKey(next.layout.commitIdOf(node)))
              next.layout.commitIdOf(node),
        };
        if (ids.isEmpty) {
          continue;
        }
        try {
          final Map<String, GraphCommitContent> page = await _fetch(next.layout.operationId, ids.toList());
          if (!_disposed && _queued == null) {
            _cache.addAll(page);
            notifyListeners();
          }
        } on ZanshinFfiException catch (error) {
          _log.warning('loading card content failed: ${error.code}');
        } catch (error, stack) {
          // A programming error must not strand the queued load.
          _log.severe('loading card content threw', error, stack);
        }
      }
    } finally {
      _running = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
