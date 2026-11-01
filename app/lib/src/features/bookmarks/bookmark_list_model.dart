// SPDX-License-Identifier: MIT

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:zanshin_core/zanshin_core.dart';

import '../graph/graph_layout.dart';
import '../graph/graph_ports.dart';
import '../graph/graph_search_controller.dart';
import '../graph/graph_view_model.dart';
import '../projects/project_repos.dart';

final _log = Logger('zanshin.bookmarks');

/// jj's mirror of the colocated Git refs (`default_ignored_remote_name`, `../jj` v0.46.0 cli/src/cli_util.rs): not a
/// remote, so its rows are left out, as the CLI's `--tracked` leaves them out.
const _gitRemote = 'git'; // l10n-ignore: jj's remote name

/// How many commits one lookup of the rows' targets asks for.
// shortcut: targets beyond 1000 commits get no subject or commit id; page the lookup if a repository needs more.
const _findLimit = 1000;

/// What the bookmark list reads (Story 10.14). A failed call throws [ZanshinFfiException].
abstract interface class BookmarkListSource {
  /// `jj bookmark list --all-remotes`: every row, in the CLI's order.
  Future<List<Bookmark>> bookmarks();

  /// At most [limit] commits [expression] denotes at [operationId] (9.25).
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  });

  /// The content of [commitIds] at [operationId], keyed by commit id.
  Future<Map<String, GraphCommitContent>> content(String operationId, List<String> commitIds);
}

/// [BookmarkListSource] over an open [ProjectRepo]'s handle.
class RepoBookmarkListSource implements BookmarkListSource {
  /// The bookmark reads of [_repo].
  RepoBookmarkListSource(this._repo);

  final ProjectRepo _repo;

  @override
  Future<List<Bookmark>> bookmarks() => _repo.handle.bookmarks(allRemotes: true);

  @override
  Future<FoundChanges> findChanges(
    String operationId,
    String expression, {
    required int limit,
    required String shortPrefixes,
  }) => _repo.handle.findChanges(operationId, expression, limit: limit, shortPrefixes: shortPrefixes);

  @override
  Future<Map<String, GraphCommitContent>> content(String operationId, List<String> commitIds) async =>
      <String, GraphCommitContent>{
        for (final CommitContent c in await _repo.handle.commitContents(operationId: operationId, commitIds: commitIds))
          c.commitId: graphCommitContentOf(c),
      };
}

/// A bookmark row's state column (DS ui_kits/desktop/chrome.jsx:13-14), from 9.29's flags and distances only.
enum BookmarkRowState {
  /// "✓": the same target as its counterpart.
  synced,

  /// "↑N": it has commits its counterpart lacks.
  ahead,

  /// "↓N": its counterpart has commits it lacks.
  behind,

  /// "↕": both have commits the other lacks.
  diverged,

  /// "↑": a local bookmark whose tracked remote bookmark is not created yet.
  notPushed,

  /// A local bookmark no remote tracks.
  local,

  /// An untracked remote bookmark.
  remote,

  /// jj's `(deleted)`: a local row without a target.
  deleted,

  /// jj's `(not created yet)`: a remote row without a target.
  notCreated,

  /// The target is a conflict.
  conflicted,

  /// The target change is divergent.
  divergent,
}

/// One row of the list (Story 10.14), resolved against the graph's shown layout.
@immutable
class BookmarkRow {
  /// A row of [bookmark].
  const BookmarkRow({
    required this.bookmark,
    required this.state,
    required this.prefix,
    this.key,
    this.commitId,
    this.subject,
    this.count,
    this.other,
  });

  /// jj's row.
  final Bookmark bookmark;

  /// The layout key of the target's first node, or null when the layout lacks it (the row is dimmed).
  final String? key;

  /// The target's first commit at the read's operation, when found.
  final String? commitId;

  /// The length of the target's shortest unique change-id prefix.
  final int prefix;

  /// The target's subject (`''` = no description), null while unknown.
  final String? subject;

  /// The state column.
  final BookmarkRowState state;

  /// The distance of [BookmarkRowState.ahead] / [BookmarkRowState.behind]: `N`, or `N+` when jj could not bound it.
  final String? count;

  /// What the state compares with: the remote of a local row, the local bookmark of a remote row.
  final String? other;

  /// The remote of a remote row.
  String? get remote => switch (bookmark.kind) {
    RemoteBookmark(:final String remoteName) => remoteName,
    LocalBookmark() => null,
  };

  /// How the row names itself: `name`, or `name@remote` for a remote row.
  String get display => switch (remote) {
    final String remote => '${bookmark.name}@$remote', // l10n-ignore: jj's symbol
    null => bookmark.name,
  };

  /// Whether the target is in the shown layout.
  bool get visible => key != null;

  /// Whether a pick can go anywhere: the row has a target.
  bool get pickable => bookmark.target != null;

  /// Track for an untracked remote row, Untrack for a tracked one; null on a local row.
  GraphAction? get trackAction => switch (bookmark.kind) {
    RemoteBookmark(:final String remoteName, tracked: true) => GraphBookmarkUntrack(bookmark.name, remoteName),
    RemoteBookmark(:final String remoteName) => GraphBookmarkTrack(bookmark.name, remoteName),
    LocalBookmark() => null,
  };
}

/// The bookmark list's state (Story 10.14): `bookmarks()` re-read whenever the graph's landed layout moves to another
/// operation (and when a stale state cleared), at most one read plus one queued; the targets' commit ids, prefixes and
/// subjects are looked up at that operation (one `findChanges`, one `content`). [rows] resolve against the shown
/// layout, so they follow it without a read. A failed read keeps the rows; jj's refusal of a stale working copy sets
/// [stale].
class BookmarkListModel extends ChangeNotifier {
  /// The list of [_source], picking through [search].
  BookmarkListModel(this._source, {required this.search}) {
    graph.addListener(_graphChanged);
    _graphChanged();
  }

  final BookmarkListSource _source;

  /// The graph search a pick goes through.
  final GraphSearchController search;

  /// The graph's view model: the shown layout, the stale state and the runner of Track and Untrack.
  GraphViewModel get graph => search.model;

  var _bookmarks = const <Bookmark>[];
  var _found = const <String, List<FoundChange>>{};
  var _subjects = const <String, String>{};
  var _loaded = false;
  var _stale = false;
  ZanshinFfiException? _error;
  String? _readOp;
  var _inFlight = false;
  var _queued = false;
  var _disposed = false;

  GraphLayout? _layout;
  List<BookmarkRow>? _rows;
  var _graphStale = false;

  /// Whether a read succeeded once.
  bool get loaded => _loaded;

  /// Whether jj refused the last read for a stale working copy.
  bool get stale => _stale;

  /// The last read's error other than [stale]; null after a read succeeded.
  ZanshinFfiException? get error => _error;

  /// The rows in `jj bookmark list --all-remotes` order, the `git` remote's left out.
  List<BookmarkRow> get rows => _rows ??= _build();

  /// Whether picking [row] is disabled: it needs `all()` while the graph is stale.
  bool pickBlocked(BookmarkRow row) => !row.visible && graph.stale != null;

  /// Goes to [row]'s target: a shown one is selected, revealed and pulsed; one beyond the view switches to `all()`. A
  /// rail pick does not enter Recent.
  void pick(BookmarkRow row) {
    final String? target = row.bookmark.target;
    if (target == null || pickBlocked(row)) {
      return;
    }
    if (row.key case final String key) {
      search.goTo(key, bookmark: row.display, recent: false);
    } else {
      search.goTo(target, commitId: row.commitId, recent: false);
    }
  }

  /// Runs [row]'s [BookmarkRow.trackAction] through the graph's runner; null on a local row.
  Future<GraphActionResult>? track(BookmarkRow row) => switch (row.trackAction) {
    final GraphAction action => graph.run(action),
    null => null,
  };

  void _graphChanged() {
    final GraphLayout? layout = graph.layout;
    final String? op = layout?.operationId;
    // Once per stale → fresh change of the graph, never on every notify (selection, pulse, reveal).
    final graphStale = graph.stale != null;
    final bool cleared = _graphStale && !graphStale;
    _graphStale = graphStale;
    if (op != null && (op != _readOp || cleared)) {
      _readOp = op;
      _load();
    }
    if (!identical(layout, _layout)) {
      _layout = layout;
      _rows = null;
      notifyListeners();
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
    final String op = _readOp!;
    try {
      final List<Bookmark> bookmarks = (await _source.bookmarks())
          .where((b) => b.kind is! RemoteBookmark || (b.kind as RemoteBookmark).remoteName != _gitRemote)
          .toList();
      final (Map<String, List<FoundChange>> found, Map<String, String> subjects) = await _targets(op, bookmarks);
      _bookmarks = List<Bookmark>.unmodifiable(bookmarks);
      _found = found;
      _subjects = subjects;
      _loaded = true;
      _stale = false;
      _error = null;
    } on ZanshinFfiException catch (error) {
      if (isStale(error)) {
        _stale = true;
        _error = null;
      } else {
        _error = error;
        _log.warning('reading the bookmarks failed: ${error.code}');
      }
    } catch (error) {
      // Not jj's refusal (a closed handle): the read is unawaited, so it is logged here and the rows stay.
      _error = ZanshinFfiException('ffi.unknown', '$error');
      _log.warning('reading the bookmarks failed: ${error.runtimeType}');
    } finally {
      _inFlight = false;
    }
    if (_disposed) {
      return;
    }
    _rows = null;
    if (_queued) {
      _queued = false;
      _load();
    }
    notifyListeners();
  }

  /// The targets' commits by change id and their subjects by commit id, at [op]; a failure leaves them empty (the
  /// rows show the id only).
  Future<(Map<String, List<FoundChange>>, Map<String, String>)> _targets(String op, List<Bookmark> bookmarks) async {
    final targets = <String>{for (final Bookmark b in bookmarks) ?b.target};
    final found = <String, List<FoundChange>>{};
    if (targets.isEmpty) {
      return (found, const <String, String>{});
    }
    try {
      final FoundChanges changes = await _source.findChanges(
        op,
        targets.map((t) => 'change_id($t)').join(' | '), // l10n-ignore: jj revset
        limit: _findLimit,
        shortPrefixes: graph.logDefaults?.shortPrefixes ?? '',
      );
      for (final FoundChange change in changes.entries) {
        found.putIfAbsent(change.changeId, () => <FoundChange>[]).add(change);
      }
      final Map<String, GraphCommitContent> content = await _source.content(op, <String>[
        for (final List<FoundChange> commits in found.values) commits.first.commitId,
      ]);
      return (found, <String, String>{for (final MapEntry(:key, :value) in content.entries) key: value.subject});
    } on ZanshinFfiException catch (error) {
      _log.warning('looking up the bookmark targets failed: ${error.code}');
      return (found, const <String, String>{});
    } catch (error) {
      // Not jj's refusal (a closed handle): the bookmarks read still lands, without subjects.
      _log.warning('looking up the bookmark targets failed: ${error.runtimeType}');
      return (found, const <String, String>{});
    }
  }

  List<BookmarkRow> _build() {
    final GraphLayout? layout = graph.layout;
    final firstNode = <String, int>{};
    if (layout != null) {
      for (var node = 0; node < layout.nodeCount; node++) {
        if (!layout.isStackNode(node)) {
          firstNode.putIfAbsent(layout.changeIdOf(node), () => node);
        }
      }
    }
    return <BookmarkRow>[
      for (final Bookmark bookmark in _bookmarks) _row(bookmark, layout, firstNode),
    ];
  }

  BookmarkRow _row(Bookmark bookmark, GraphLayout? layout, Map<String, int> firstNode) {
    final String? target = bookmark.target;
    final int? node = target == null ? null : firstNode[target];
    final List<FoundChange>? found = target == null ? null : _found[target];
    final FoundChange? first = found?.first;
    final bool divergent = (found?.length ?? 0) > 1 || (node != null && layout!.isDivergent(node));
    final String? subject =
        _subjects[first?.commitId] ?? (node == null ? null : graph.content.of(layout!, node)?.subject);
    final (BookmarkRowState state, String? count, String? other) = bookmarkRowState(
      bookmark,
      _bookmarks,
      divergent: divergent,
    );
    return BookmarkRow(
      bookmark: bookmark,
      key: node == null ? null : layout!.keyOf(node),
      commitId: first?.commitId,
      prefix: node != null ? layout!.changeIdPrefixLengthOf(node) : first?.changePrefixLen ?? 2,
      subject: subject,
      state: state,
      count: count,
      other: other,
    );
  }

  @override
  void dispose() {
    _disposed = true;
    graph.removeListener(_graphChanged);
    super.dispose();
  }
}

/// [bookmark]'s state among [rows] (the list it came in), from 9.29's flags and distances only — never by comparing
/// a local and a remote target: the state, the distance of an arrow and what it compares with.
@visibleForTesting
(BookmarkRowState, String?, String?) bookmarkRowState(
  Bookmark bookmark,
  List<Bookmark> rows, {
  required bool divergent,
}) {
  final String name = bookmark.name;
  switch (bookmark.kind) {
    case LocalBookmark():
      if (bookmark.target == null) {
        return (BookmarkRowState.deleted, null, null);
      }
      if (bookmark.conflicted) {
        return (BookmarkRowState.conflicted, null, null);
      }
      if (divergent) {
        return (BookmarkRowState.divergent, null, null);
      }
      final Bookmark? tracked = rows
          .where((r) => r.name == name && r.kind is RemoteBookmark && (r.kind as RemoteBookmark).tracked)
          .firstOrNull;
      if (tracked == null) {
        return (BookmarkRowState.local, null, null);
      }
      final remote = tracked.kind as RemoteBookmark;
      if (bookmark.synced) {
        return (BookmarkRowState.synced, null, remote.remoteName);
      }
      if (tracked.target == null) {
        return (BookmarkRowState.notPushed, null, remote.remoteName);
      }
      // The remote's `behind` is what the local bookmark has more.
      return _arrows(up: remote.behind, down: remote.ahead, other: remote.remoteName);
    case RemoteBookmark(:final bool tracked):
      if (bookmark.target == null) {
        return (BookmarkRowState.notCreated, null, null);
      }
      if (bookmark.conflicted) {
        return (BookmarkRowState.conflicted, null, null);
      }
      if (divergent) {
        return (BookmarkRowState.divergent, null, null);
      }
      if (!tracked) {
        return (BookmarkRowState.remote, null, null);
      }
      if (bookmark.synced) {
        return (BookmarkRowState.synced, null, name);
      }
      final remote = bookmark.kind as RemoteBookmark;
      return _arrows(up: remote.ahead, down: remote.behind, other: name);
  }
}

(BookmarkRowState, String?, String?) _arrows({
  required RefDistance? up,
  required RefDistance? down,
  required String other,
}) {
  final bool more = (up?.lower ?? 0) > 0;
  final bool less = (down?.lower ?? 0) > 0;
  if (more && !less) {
    return (BookmarkRowState.ahead, _count(up!), other);
  }
  if (less && !more) {
    return (BookmarkRowState.behind, _count(down!), other);
  }
  return (BookmarkRowState.diverged, null, other);
}

String _count(RefDistance distance) => distance.upper == null ? '${distance.lower}+' : '${distance.lower}';
