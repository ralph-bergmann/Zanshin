// SPDX-License-Identifier: MIT

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_content.dart';
import 'graph_layout.dart';
import 'graph_search_model.dart';

// The graph search's candidates and its suggestions (Story 10.21 item 4; DS design/graph-search.jsx:94-172): the
// index gathers what is in memory — the shown topology, the content cache, `bookmarks()`, @'s paths and the changes
// `findChanges` found beyond the view — and [suggestGraphSearch] scores and groups the rows as the design does.

/// One change a go-to can reach.
@immutable
class GraphSearchChange {
  /// A change.
  const GraphSearchChange({
    required this.key,
    required this.commitId,
    required this.prefixLength,
    this.subject,
    this.authorName = '',
    this.authorEmail = '',
    this.inView = true,
    this.workingCopy = false,
    this.timestampMs,
    this.symbolMatch = false,
    this.bodyMatch = false,
  });

  /// The node key: the change id, or the commit id of a hidden or divergent commit.
  final String key;

  /// The full commit id.
  final String commitId;

  /// jj's shortest unique change-id prefix length.
  final int prefixLength;

  /// The description's first line; null while its content is not loaded.
  final String? subject;

  /// The author's name.
  final String authorName;

  /// The author's email.
  final String authorEmail;

  /// Whether the shown layout has it.
  final bool inView;

  /// Whether it is @.
  final bool workingCopy;

  /// The committer timestamp, when known.
  final int? timestampMs;

  /// `findChanges` resolved the input as a revset symbol to it.
  final bool symbolMatch;

  /// `findChanges` found it by its description (subject or body).
  final bool bodyMatch;
}

/// What the suggestions search (Story 10.21 item 4).
@immutable
class GraphSearchIndex {
  /// An index.
  const GraphSearchIndex({
    this.changes = const <GraphSearchChange>[],
    this.bookmarks = const <({String name, String key})>[],
    this.authors = const <String, String>{},
    this.paths = const <String>[],
    this.userEmail,
  });

  /// The index of [layout] (its non-stack, non-root nodes, their content from [content]), [bookmarks] (local rows by
  /// name, remote rows as `name@remote`), [paths] (@'s files) and the [found] changes beyond the view.
  factory GraphSearchIndex.build({
    GraphLayout? layout,
    GraphContent? content,
    List<Bookmark> bookmarks = const <Bookmark>[],
    List<String> paths = const <String>[],
    List<GraphSearchChange> found = const <GraphSearchChange>[],
    String? userEmail,
  }) {
    final changes = <String, GraphSearchChange>{};
    final authors = <String, String>{};
    if (layout != null) {
      for (var node = 0; node < layout.nodeCount; node++) {
        if (layout.isStackNode(node) || node == layout.rootIndex) {
          continue;
        }
        final GraphCommitContent? c = content?.of(layout, node) ?? layout.contentOf(node);
        final String key = layout.keyOf(node);
        changes[key] = GraphSearchChange(
          key: key,
          commitId: layout.commitIdOf(node),
          prefixLength: layout.changeIdPrefixLengthOf(node),
          subject: c?.subject,
          authorName: c?.authorName ?? '',
          authorEmail: c?.authorEmail ?? '',
          workingCopy: node == layout.workingCopyIndex,
          timestampMs: layout.timestampOf(node) ?? c?.timestampMs,
        );
      }
    }
    for (final change in found) {
      final GraphSearchChange? shown = changes[change.key];
      changes[change.key] = shown == null
          ? change
          : GraphSearchChange(
              key: shown.key,
              commitId: shown.commitId,
              prefixLength: shown.prefixLength,
              subject: shown.subject ?? change.subject,
              authorName: shown.authorName,
              authorEmail: shown.authorEmail,
              workingCopy: shown.workingCopy,
              timestampMs: shown.timestampMs,
              symbolMatch: change.symbolMatch,
              bodyMatch: change.bodyMatch,
            );
    }
    for (final GraphSearchChange change in changes.values) {
      if (change.authorName.isNotEmpty) {
        authors.putIfAbsent(change.authorName, () => change.authorEmail);
      }
    }
    final names = <String>{};
    return GraphSearchIndex(
      changes: changes.values.toList(),
      bookmarks: <({String name, String key})>[
        for (final Bookmark b in bookmarks)
          if (b.target case final String target)
            if (names.add(_bookmarkName(b))) (name: _bookmarkName(b), key: target),
      ],
      authors: authors,
      paths: paths,
      userEmail: userEmail,
    );
  }

  static String _bookmarkName(Bookmark b) => switch (b.kind) {
    RemoteBookmark(:final String remoteName) => '${b.name}@$remoteName',
    LocalBookmark() => b.name,
  };

  /// The changes.
  final List<GraphSearchChange> changes;

  /// The bookmarks: name and target key.
  final List<({String name, String key})> bookmarks;

  /// The authors: name → email.
  final Map<String, String> authors;

  /// @'s paths.
  final List<String> paths;

  /// `user.email`.
  final String? userEmail;

  /// The change carrying [key], or null.
  GraphSearchChange? change(String key) => changes.where((c) => c.key == key).firstOrNull;
}

/// How a change row matched.
enum GraphChangeMatch {
  /// Its change id starts with the input.
  id,

  /// Its commit id starts with the input.
  hash,

  /// Its subject contains the input.
  subject,

  /// `findChanges` found it by its description.
  body,

  /// `findChanges` resolved the input to it as a revset symbol.
  symbol,

  /// A Recent go-to.
  recent,
}

/// What a filter row says.
enum GraphFilterRowKind {
  /// An author by name ("you" when the filter is `mine()`).
  author,

  /// "Authors containing …".
  contains,

  /// A file.
  path,

  /// A folder.
  dir,

  /// A glob.
  glob,

  /// "Descriptions containing …".
  description,

  /// A Recent filter.
  recent,
}

/// One suggestion row.
@immutable
sealed class GraphSearchRow {
  const GraphSearchRow({required this.score});

  /// Orders rows and, in Any, the groups.
  final double score;
}

/// A go-to of [change].
final class GraphChangeRow extends GraphSearchRow {
  /// A change row.
  const GraphChangeRow(this.change, this.how, {required super.score, this.match});

  /// The change.
  final GraphSearchChange change;

  /// How it matched.
  final GraphChangeMatch how;

  /// The input's range in the subject (subject matches).
  final (int, int)? match;
}

/// A go-to of the bookmark [name], on [key].
final class GraphBookmarkRow extends GraphSearchRow {
  /// A bookmark row.
  const GraphBookmarkRow(this.name, this.key, {required super.score, this.change, this.match});

  /// The bookmark's name.
  final String name;

  /// Its target's key.
  final String key;

  /// The target, when the index has it.
  final GraphSearchChange? change;

  /// The input's range in [name].
  final (int, int)? match;
}

/// A filter.
final class GraphFilterRow extends GraphSearchRow {
  /// A filter row.
  const GraphFilterRow(this.filter, this.kind, this.text, {required super.score, this.match, this.split = 0});

  /// The filter Enter applies.
  final GraphFilter filter;

  /// What the row says.
  final GraphFilterRowKind kind;

  /// The row's text: a name, a path, the typed value.
  final String text;

  /// The input's range in [text].
  final (int, int)? match;

  /// The text before [split] is dimmed (a path's folders).
  final int split;
}

/// "N more in `scope`": narrows the search to [scope].
final class GraphMoreRow extends GraphSearchRow {
  /// A more row.
  const GraphMoreRow(this.scope, this.count) : super(score: 0);

  /// The scope it narrows to.
  final GraphSearchScope scope;

  /// How many more rows.
  final int count;
}

/// jj's refusal of the input as a revset symbol (an ambiguous prefix), verbatim; Enter does nothing.
final class GraphRefusalRow extends GraphSearchRow {
  /// A refusal.
  const GraphRefusalRow(this.message) : super(score: 200);

  /// jj's message.
  final String message;
}

/// One group of suggestions; [scope] names its label.
@immutable
class GraphSearchGroup {
  /// A group.
  const GraphSearchGroup(this.scope, this.rows, {this.labelled = true});

  /// The scope its rows belong to.
  final GraphSearchScope scope;

  /// The rows.
  final List<GraphSearchRow> rows;

  /// Whether it shows its label.
  final bool labelled;
}

/// The suggestions for one input: [groups], and whether they were [fallback] matches found in any scope.
@immutable
class GraphSuggestions {
  /// Suggestions.
  const GraphSuggestions(this.groups, {this.fallback = false});

  /// The groups.
  final List<GraphSearchGroup> groups;

  /// No match in the scope: these are Any's.
  final bool fallback;

  /// The rows, in order.
  List<GraphSearchRow> get rows => <GraphSearchRow>[for (final GraphSearchGroup g in groups) ...g.rows];
}

/// Any's per-scope limits (SR:157).
const graphSearchAnyLimits = <GraphSearchScope, int>{
  GraphSearchScope.change: 3,
  GraphSearchScope.bookmark: 2,
  GraphSearchScope.author: 2,
  GraphSearchScope.file: 3,
  GraphSearchScope.description: 1,
};

/// A single scope's limit (SR:170).
const graphSearchScopeLimit = 8;

/// Description's changes (SR:166-168).
const graphSearchDescriptionChanges = 6;

(int, int)? _at(String text, String q, [int from = 0]) {
  final int i = text.toLowerCase().indexOf(q, from);
  return i < 0 ? null : (i, i + q.length);
}

bool _wordAt(String s, int i) => i == 0 || RegExp('[^a-z0-9]', caseSensitive: false).hasMatch(s[i - 1]);

/// The suggestions for [raw] in [scope] (SR:110-172); with no match in a single scope, Any's, as `GraphSuggestions.fallback`.
GraphSuggestions suggestGraphSearch(GraphSearchIndex index, GraphSearchScope scope, String raw, {String? refusal}) {
  final GraphSuggestions own = _compose(_suggest(index, scope, raw, refusal), scope);
  if (own.groups.isEmpty && scope != GraphSearchScope.any) {
    final GraphSuggestions any = _compose(_suggest(index, GraphSearchScope.any, raw, refusal), GraphSearchScope.any);
    // Any always offers "Descriptions containing …": with nothing else found the scope shows the empty text instead.
    final bool found = any.groups.any((g) => g.scope != GraphSearchScope.description);
    return found ? GraphSuggestions(any.groups, fallback: true) : const GraphSuggestions(<GraphSearchGroup>[]);
  }
  return own;
}

Map<GraphSearchScope, List<GraphSearchRow>> _suggest(
  GraphSearchIndex ix,
  GraphSearchScope scope,
  String raw,
  String? refusal,
) {
  final String v = raw.trim();
  final String q = v.toLowerCase();
  final g = <GraphSearchScope, List<GraphSearchRow>>{
    for (final GraphSearchScope s in graphSearchAnyLimits.keys) s: <GraphSearchRow>[],
  };
  if (q.isEmpty) {
    return g;
  }
  bool want(GraphSearchScope s) => scope == GraphSearchScope.any || scope == s;
  final bool idLike = RegExp(r'^[k-z]{3,}$').hasMatch(q);
  final bool hashLike = RegExp(r'^[0-9a-f]{4,}$').hasMatch(q);
  final bool pathLike = RegExp(r'[/*?]|\.\w+$').hasMatch(q);
  if (want(GraphSearchScope.change) || scope == GraphSearchScope.description) {
    final List<GraphSearchRow> rows = g[GraphSearchScope.change]!;
    if (refusal != null && scope != GraphSearchScope.description) {
      rows.add(GraphRefusalRow(refusal));
    }
    for (final GraphSearchChange c in ix.changes) {
      (int, int)? r;
      final GraphChangeMatch how;
      final double score;
      final String subject = c.subject ?? '';
      if (c.key.startsWith(q)) {
        (how, score) = (GraphChangeMatch.id, 100);
      } else if (q.length >= 3 && c.commitId.startsWith(q)) {
        (how, score) = (GraphChangeMatch.hash, 96);
      } else if ((r = _at(subject, q)) != null) {
        (how, score) = (GraphChangeMatch.subject, _wordAt(subject, r!.$1) ? 58 : 46);
      } else if (c.symbolMatch) {
        (how, score) = (GraphChangeMatch.symbol, 90);
      } else if (c.bodyMatch) {
        (how, score) = (GraphChangeMatch.body, 36);
      } else {
        continue;
      }
      rows.add(GraphChangeRow(c, how, match: r, score: score + (idLike || hashLike ? 20 : 0)));
    }
    rows.sort((a, b) {
      final int byScore = b.score.compareTo(a.score);
      if (byScore != 0 || a is! GraphChangeRow || b is! GraphChangeRow) {
        return byScore;
      }
      return (b.change.timestampMs ?? 0).compareTo(a.change.timestampMs ?? 0);
    });
  }
  if (want(GraphSearchScope.bookmark)) {
    final List<GraphSearchRow> rows = g[GraphSearchScope.bookmark]!;
    for (final (:String name, :String key) in ix.bookmarks) {
      final (int, int)? r = _at(name, q);
      if (r != null) {
        final double score = r.$1 == 0 ? 86 : (_wordAt(name, r.$1) ? 74 : 60);
        rows.add(GraphBookmarkRow(name, key, change: ix.change(key), match: r, score: score));
      }
    }
    rows.sort((a, b) {
      final int byScore = b.score.compareTo(a.score);
      return byScore != 0
          ? byScore
          : (a as GraphBookmarkRow).name.length.compareTo((b as GraphBookmarkRow).name.length);
    });
  }
  if (want(GraphSearchScope.author)) {
    final List<GraphSearchRow> rows = g[GraphSearchScope.author]!;
    final String? me = ix.userEmail?.toLowerCase();
    ix.authors.forEach((name, email) {
      final (int, int)? r = _at(name, q);
      if (r != null) {
        final bool mine = me != null && email.toLowerCase() == me;
        rows.add(
          GraphFilterRow(
            mine ? GraphFilter.mine(email) : GraphFilter.author(name),
            GraphFilterRowKind.author,
            name,
            match: r,
            score: _wordAt(name, r.$1) ? 84 : 62,
          ),
        );
      }
    });
    rows.sort((a, b) => b.score.compareTo(a.score));
    if (scope == GraphSearchScope.author && rows.length != 1) {
      rows.add(
        GraphFilterRow(
          GraphFilter.author(v, pattern: RevsetTextPattern.substring, ci: true),
          GraphFilterRowKind.contains,
          v,
          score: 10,
        ),
      );
    }
  }
  if (want(GraphSearchScope.file)) {
    final List<GraphSearchRow> rows = g[GraphSearchScope.file]!;
    if (RegExp('[*?]').hasMatch(q)) {
      rows.add(
        GraphFilterRow(GraphFilter.files(v, pattern: RevsetPathPattern.glob), GraphFilterRowKind.glob, v, score: 90),
      );
    } else {
      void add(String p, {required bool dir}) {
        final int base = (p.endsWith('/') ? p.substring(0, p.length - 1) : p).lastIndexOf('/') + 1;
        final (int, int)? r = _at(p, q, base) ?? _at(p, q);
        if (r == null) {
          return;
        }
        double score = r.$1 >= base ? (r.$1 == base ? 82 : 64) : (_wordAt(p, r.$1) ? 60 : 48);
        if (dir && r.$1 >= base) {
          score += 4;
        }
        rows.add(
          GraphFilterRow(
            GraphFilter.files(p, pattern: dir ? RevsetPathPattern.prefix : RevsetPathPattern.file),
            dir ? GraphFilterRowKind.dir : GraphFilterRowKind.path,
            p,
            match: r,
            split: base,
            score: score + (pathLike ? 20 : 0) - p.length / 400,
          ),
        );
      }

      final dirs = <String>{};
      for (final String path in ix.paths) {
        final List<String> seg = path.split('/');
        for (var i = 1; i < seg.length; i++) {
          dirs.add('${seg.sublist(0, i).join('/')}/');
        }
      }
      for (final d in dirs) {
        add(d, dir: true);
      }
      for (final String p in ix.paths) {
        add(p, dir: false);
      }
      rows.sort((a, b) => b.score.compareTo(a.score));
    }
  }
  if (want(GraphSearchScope.description)) {
    g[GraphSearchScope.description]!.add(
      GraphFilterRow(GraphFilter.description(v), GraphFilterRowKind.description, v, score: 24),
    );
  }
  return g;
}

GraphSuggestions _compose(Map<GraphSearchScope, List<GraphSearchRow>> g, GraphSearchScope scope) {
  if (scope == GraphSearchScope.any) {
    final groups = <GraphSearchGroup>[
      for (final MapEntry(key: GraphSearchScope s, value: int limit) in graphSearchAnyLimits.entries)
        if (g[s]!.isNotEmpty)
          GraphSearchGroup(s, <GraphSearchRow>[
            ...g[s]!.take(limit),
            if (g[s]!.length > limit) GraphMoreRow(s, g[s]!.length - limit),
          ]),
    ];
    // Dart's sort is not stable: keep the scope order between equal first scores.
    final order = <GraphSearchGroup, int>{for (var i = 0; i < groups.length; i++) groups[i]: i};
    groups.sort((a, b) {
      final int byScore = b.rows.first.score.compareTo(a.rows.first.score);
      return byScore != 0 ? byScore : order[a]!.compareTo(order[b]!);
    });
    return GraphSuggestions(groups);
  }
  if (scope == GraphSearchScope.description) {
    final List<GraphSearchRow> changes = g[GraphSearchScope.change]!
        .where((r) => r is GraphChangeRow && (r.how == GraphChangeMatch.subject || r.how == GraphChangeMatch.body))
        .take(graphSearchDescriptionChanges)
        .toList();
    return GraphSuggestions(<GraphSearchGroup>[
      if (g[GraphSearchScope.description]!.isNotEmpty)
        GraphSearchGroup(GraphSearchScope.description, g[GraphSearchScope.description]!, labelled: false),
      if (changes.isNotEmpty) GraphSearchGroup(GraphSearchScope.change, changes),
    ]);
  }
  final List<GraphSearchRow> rows = g[scope]!.take(graphSearchScopeLimit).toList();
  return GraphSuggestions(<GraphSearchGroup>[
    if (rows.isNotEmpty) GraphSearchGroup(scope, rows, labelled: false),
  ]);
}
