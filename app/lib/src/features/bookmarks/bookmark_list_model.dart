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
import 'ref_delete.dart';

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
  RepoBookmarkListSource(ProjectRepo repo) : _repo = repo;

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

/// Which refs a list shows (Story 10.44): the verbs, labels and drag follow it.
enum RefKind {
  /// jj's bookmarks.
  bookmark,

  /// jj's tags.
  tag,
}

/// [BookmarkListSource] over an open [ProjectRepo]'s tags (Story 10.44): `jj tag list --all-remotes` (9.59), each
/// [Tag] as a [Bookmark] row with no distances, so the list's rows, states and picks serve tags too.
class RepoTagListSource extends RepoBookmarkListSource {
  /// The tag reads of [repo].
  RepoTagListSource(super.repo);

  @override
  Future<List<Bookmark>> bookmarks() async => <Bookmark>[for (final Tag tag in await _repo.handle.tags()) tagRow(tag)];
}

/// [tag] as a list row: a remote tag is a remote row without distances.
Bookmark tagRow(Tag tag) => Bookmark(
  name: tag.name,
  target: tag.target,
  conflicted: tag.conflicted,
  synced: tag.synced,
  kind: switch (tag.kind) {
    LocalTag() => const LocalBookmark(),
    RemoteTag(:final String remoteName, :final bool tracked) => RemoteBookmark(remoteName, tracked: tracked),
  },
);

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
    this.kind = RefKind.bookmark,
    this.key,
    this.commitId,
    this.subject,
    this.count,
    this.other,
  });

  /// jj's row (a tag's too, as [tagRow] maps it).
  final Bookmark bookmark;

  /// A bookmark's or a tag's row.
  final RefKind kind;

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

  /// Track for an untracked remote row, Untrack for a tracked one (`jj bookmark|tag track|untrack`); null on a local
  /// row.
  GraphAction? get trackAction => switch ((bookmark.kind, kind)) {
    (RemoteBookmark(:final String remoteName, tracked: true), RefKind.bookmark) => GraphBookmarkUntrack(
      bookmark.name,
      remoteName,
    ),
    (RemoteBookmark(:final String remoteName), RefKind.bookmark) => GraphBookmarkTrack(bookmark.name, remoteName),
    (RemoteBookmark(:final String remoteName, tracked: true), RefKind.tag) => GraphTagUntrack(
      bookmark.name,
      remoteName,
    ),
    (RemoteBookmark(:final String remoteName), RefKind.tag) => GraphTagTrack(bookmark.name, remoteName),
    (LocalBookmark(), _) => null,
  };

  /// Whether Delete… applies: a local row with a target.
  bool get deletable => remote == null && bookmark.target != null;

  /// Whether Rename… applies: a local bookmark with a target.
  bool get renamable => deletable && kind == RefKind.bookmark;

  /// The row's buttons and menu verbs, in order (Story 10.44): New and Delete… on a local row with a target; Track or
  /// Untrack, then New, on a remote row (New only with a target).
  List<RefRowAction> get actions => <RefRowAction>[
    if (trackAction != null) RefRowAction.track,
    if (bookmark.target != null) RefRowAction.newHere,
    if (deletable) RefRowAction.delete,
  ];
}

/// A row's verb (Story 10.44).
enum RefRowAction {
  /// `jj new <name>`.
  newHere,

  /// Delete…: at once, or through the delete sheet when a remote tracks it.
  delete,

  /// `jj bookmark|tag track|untrack <name>@<remote>`.
  track,
}

/// One row of the views' tree (Story 10.44): a folder or a leaf, [depth] folders deep.
@immutable
sealed class RefTreeRow {
  const RefTreeRow(this.depth);

  /// How many folders contain it.
  final int depth;
}

/// A folder: the names' common `path` up to one `/`.
final class RefFolderRow extends RefTreeRow {
  /// The folder [path] (with its trailing `/`), shown as [name].
  const RefFolderRow({required this.path, required this.name, required this.open, required int depth}) : super(depth);

  /// The full path, `a/b/`: the folder's identity.
  final String path;

  /// Its last segment with a trailing `/`.
  final String name;

  /// Whether its rows show.
  final bool open;
}

/// A leaf: one row of the list.
final class RefLeafRow extends RefTreeRow {
  /// The [index]th row of the list, labelled [label].
  const RefLeafRow({required this.row, required this.index, required this.label, required int depth}) : super(depth);

  /// The list's row.
  final BookmarkRow row;

  /// Its index in the flat list ([BookmarkListModel.rows]): the identifiers' number.
  final int index;

  /// The name's last segment (the whole name when that segment is empty).
  final String label;
}

/// [rows] as a tree (Story 10.44): names split at `/`, every segment but the last a folder; folders first (by name),
/// then the leaves in the list's order. A non-empty [filter] keeps the leaves whose display name contains it (case
/// insensitive) and every folder on their path, all open; otherwise a folder in [collapsed] hides its rows.
List<RefTreeRow> refTree(List<BookmarkRow> rows, {String filter = '', Set<String> collapsed = const <String>{}}) {
  final String query = filter.toLowerCase();
  final root = _Folder('');
  for (var i = 0; i < rows.length; i++) {
    final BookmarkRow row = rows[i];
    if (query.isNotEmpty && !row.display.toLowerCase().contains(query)) {
      continue;
    }
    final List<String> segments = row.bookmark.name.split('/');
    var folder = root;
    for (final String segment in segments.sublist(0, segments.length - 1)) {
      folder = folder.folders.putIfAbsent(segment, () => _Folder('${folder.path}$segment/'));
    }
    final String last = segments.last;
    folder.leaves.add((index: i, label: last.isEmpty ? row.bookmark.name : last));
  }
  final out = <RefTreeRow>[];
  void walk(_Folder folder, int depth) {
    for (final String name in folder.folders.keys.toList()..sort()) {
      final _Folder child = folder.folders[name]!;
      final bool open = query.isNotEmpty || !collapsed.contains(child.path);
      out.add(RefFolderRow(path: child.path, name: '$name/', open: open, depth: depth));
      if (open) {
        walk(child, depth + 1);
      }
    }
    for (final (:int index, :String label) in folder.leaves) {
      out.add(RefLeafRow(row: rows[index], index: index, label: label, depth: depth));
    }
  }

  walk(root, 0);
  return out;
}

/// A folder while [refTree] builds; it exists only when a kept leaf lies below it.
class _Folder {
  _Folder(this.path);

  final String path;
  final folders = <String, _Folder>{};
  final leaves = <({int index, String label})>[];
}

/// The bookmark list's state (Story 10.14): `bookmarks()` re-read whenever the graph's landed layout moves to another
/// operation (and when a stale state cleared), at most one read plus one queued; the targets' commit ids, prefixes and
/// subjects are looked up at that operation (one `findChanges`, one `content`). [rows] resolve against the shown
/// layout, so they follow it without a read. A failed read keeps the rows; jj's refusal of a stale working copy sets
/// [stale].
///
/// Story 10.44: the [kind] of its refs ([TagListModel] lists tags), the views' [filter] and folded folders
/// ([collapsed]) — both session-only — and the rows' verbs: [newHere], [track] and [delete] (through [deletes]).
class BookmarkListModel extends ChangeNotifier {
  /// The list of [_source], picking through [search]; Delete… goes through [deletes].
  BookmarkListModel(BookmarkListSource source, {required this.search, this.kind = RefKind.bookmark, this.deletes})
    : _source = source {
    graph.addListener(_graphChanged);
    _graphChanged();
  }

  final BookmarkListSource _source;

  /// Bookmarks or tags.
  final RefKind kind;

  /// The shared delete flow; without it Delete… is not offered.
  final RefDeleteFlow? deletes;

  /// The graph search a pick goes through.
  final GraphSearchController search;

  var _filter = '';
  var _collapsed = const <String>{};
  List<RefTreeRow>? _tree;

  /// The view's filter text.
  String get filter => _filter;

  set filter(String value) {
    if (value != _filter) {
      _filter = value;
      _tree = null;
      notifyListeners();
    }
  }

  /// The folders the view folded, by path.
  Set<String> get collapsed => _collapsed;

  /// Folds the folder [path], or unfolds it.
  void toggleFolder(String path) {
    final next = <String>{..._collapsed};
    if (!next.remove(path)) {
      next.add(path);
    }
    _collapsed = next;
    _tree = null;
    notifyListeners();
  }

  /// [rows] as the view's tree, filtered by [filter] ([refTree]).
  List<RefTreeRow> get tree => _tree ??= refTree(rows, filter: _filter, collapsed: _collapsed);

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

  /// The command [newHere] runs on [row], as its button and menu row show it: `jj new <name>` or
  /// `jj new <name>@<remote>`.
  static String newCommand(BookmarkRow row) => _newAction(row, row.bookmark.target!).command;

  /// A new change on [row]'s ref through the graph's runner — jj resolves the name, as `jj new <name>` does, so a
  /// divergent target works and a conflicted ref refuses; null without a target.
  Future<GraphActionResult>? newHere(BookmarkRow row) => switch (row.bookmark.target) {
    final String target => graph.run(_newAction(row, target)),
    null => null,
  };

  static GraphNew _newAction(BookmarkRow row, String target) => GraphNew(
    revsets: <String>[
      switch (row.remote) {
        final String remote => remoteBookmarkSymbol(row.bookmark.name, remote),
        null => revsetSymbol(row.bookmark.name),
      },
    ],
    // The layout key: a divergent change's nodes are keyed by commit id, not by the change id.
    revsetTarget: row.key ?? target,
  );

  /// Delete… of [row] through [deletes]: at once without a tracked remote, else the delete sheet.
  void delete(BookmarkRow row) {
    if (row.deletable) {
      deletes?.delete(RefDeleteRequest.of(kind, row.bookmark.name, _bookmarks));
    }
  }

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
      _tree = null;
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
        _log.warning('reading the ${kind.name}s failed: ${error.code}');
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
    _tree = null;
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
      kind: kind,
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

/// The rail's tag list (Story 10.44): [BookmarkListModel] over [RepoTagListSource]'s rows, a type of its own so the
/// project graph provides both lists.
class TagListModel extends BookmarkListModel {
  /// The tags of [source], picking through [search]; Delete… goes through [deletes].
  TagListModel(super.source, {required super.search, super.deletes}) : super(kind: RefKind.tag);
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
