// SPDX-License-Identifier: MIT

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:zanshin_core/zanshin_core.dart';

import 'graph_ports.dart';

// The graph search's view state (Story 10.21 item 1): the scopes and their prefixes, a typed filter, what the graph
// shows and the Recent entries — with the revset and the command each derives, all through zanshin_core's builder.

/// A search scope (DS design/graph-search.jsx:42-50): Any, the go-to scopes (Change, Bookmark) and the filter scopes
/// (Author, File, Description).
enum GraphSearchScope {
  /// Every scope at once.
  any,

  /// Change ids, commit ids and descriptions: selects a change.
  change,

  /// Bookmark names: selects a change.
  bookmark,

  /// `author()`: redraws the graph.
  author,

  /// `files()`: redraws the graph.
  file,

  /// `description()`: redraws the graph.
  description;

  /// Whether the scope selects a change and leaves the graph as it is.
  bool get isGoTo => this == change || this == bookmark;

  /// Whether the scope redraws the graph.
  bool get isFilter => this == author || this == file || this == description;

  /// The short prefix that switches to the scope, or null for Any.
  String? get prefix => switch (this) {
    any => null,
    change => 'c:',
    bookmark => 'b:',
    author => 'a:',
    file => 'f:',
    description => 'd:',
  };
}

// SR:51-52: the prefixes and their long forms.
final _prefix = RegExp(r'^(c|change|commit|b|bookmark|a|author|f|files?|d|desc|description):\s*', caseSensitive: false);

/// [text]'s leading scope prefix (`c:`, `author:`, …) and the text after it; null when it starts with none.
({GraphSearchScope scope, String rest})? parseGraphSearchPrefix(String text) {
  final RegExpMatch? match = _prefix.firstMatch(text);
  if (match == null) {
    return null;
  }
  final GraphSearchScope scope = switch (match[1]!.toLowerCase()) {
    'c' || 'change' || 'commit' => GraphSearchScope.change,
    'b' || 'bookmark' => GraphSearchScope.bookmark,
    'a' || 'author' => GraphSearchScope.author,
    'f' || 'file' || 'files' => GraphSearchScope.file,
    _ => GraphSearchScope.description,
  };
  return (scope: scope, rest: text.substring(match.end));
}

/// A typed filter (Story 10.21 items 1 and 7): its [scope] (author, file or description), its pattern [kind] (a
/// [RevsetTextPattern] name, a [RevsetPathPattern] name for files, or `mine` for "you"), its [value] and whether it is
/// case-insensitive ([ci]).
@immutable
class GraphFilter {
  /// An author filter.
  GraphFilter.author(this.value, {RevsetTextPattern pattern = RevsetTextPattern.exact, this.ci = false})
    : scope = GraphSearchScope.author,
      kind = pattern.name;

  /// "You": `mine()`, the author whose email is [email] (the shown value).
  const GraphFilter.mine(String email) : scope = GraphSearchScope.author, kind = _mine, value = email, ci = true;

  /// A description filter; case-insensitive substring by default, as the design's.
  GraphFilter.description(this.value, {RevsetTextPattern pattern = RevsetTextPattern.substring, this.ci = true})
    : scope = GraphSearchScope.description,
      kind = pattern.name;

  /// A files filter.
  GraphFilter.files(this.value, {RevsetPathPattern pattern = RevsetPathPattern.prefix})
    : scope = GraphSearchScope.file,
      kind = pattern.name,
      ci = false;

  const GraphFilter._(this.scope, this.kind, this.value, this.ci);

  static const _mine = 'mine';

  /// The scope: author, file or description.
  final GraphSearchScope scope;

  /// The pattern kind.
  final String kind;

  /// The value.
  final String value;

  /// Case-insensitive.
  final bool ci;

  /// Whether this is "you" (`mine()`).
  bool get isMine => kind == _mine;

  /// The revset zanshin_core's builder writes; the UI shows and sends it verbatim.
  String get revset => switch (scope) {
    _ when isMine => mineRevset(),
    GraphSearchScope.file => filesRevset(value, pattern: RevsetPathPattern.values.byName(kind)),
    GraphSearchScope.description => descriptionRevset(
      value,
      pattern: RevsetTextPattern.values.byName(kind),
      caseInsensitive: ci,
    ),
    _ => authorRevset(value, pattern: RevsetTextPattern.values.byName(kind), caseInsensitive: ci),
  };

  /// The command Enter runs: `jj log -r '<revset>'`.
  String get command => jjLogCommand(revset);

  /// The JSON form.
  Map<String, Object?> toJson() => <String, Object?>{
    'scope': scope.name,
    'kind': kind,
    'value': value,
    if (ci) 'ci': true,
  };

  /// Reads [json]; null when it is no filter this version knows.
  static GraphFilter? fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      return null;
    }
    final Object? scope = json['scope'];
    final Object? kind = json['kind'];
    final Object? value = json['value'];
    if (scope is! String || kind is! String || value is! String) {
      return null;
    }
    final GraphSearchScope? s = GraphSearchScope.values.asNameMap()[scope];
    final bool known = switch (s) {
      GraphSearchScope.author => kind == _mine || RevsetTextPattern.values.asNameMap().containsKey(kind),
      GraphSearchScope.description => RevsetTextPattern.values.asNameMap().containsKey(kind),
      GraphSearchScope.file => RevsetPathPattern.values.asNameMap().containsKey(kind),
      _ => false,
    };
    return known ? GraphFilter._(s!, kind, value, json['ci'] == true) : null;
  }

  @override
  bool operator ==(Object other) =>
      other is GraphFilter && other.scope == scope && other.kind == kind && other.value == value && other.ci == ci;

  @override
  int get hashCode => Object.hash(scope, kind, value, ci);

  @override
  String toString() => 'GraphFilter($revset)';
}

/// What the graph shows (Story 10.21 item 1; 10.22): the default search, the built-ins `jj log` and `all()`, a jj log
/// configuration, or a typed filter run in `all()`. The default search and a configuration resolve their revset
/// through the stored configurations (`GraphSearchController.revsetOf`).
@immutable
sealed class GraphShownView {
  const GraphShownView();

  /// The default search: `jj log`, `all()` or a configuration, as the settings say.
  static const GraphShownView defaultSearch = GraphDefaultSearch();

  /// The stored form; null for the default search.
  String? encode();

  /// Reads [text] (from [encode]); anything unknown reads as the default search.
  static GraphShownView decode(String? text) {
    if (text == null) {
      return defaultSearch;
    }
    try {
      final Object? json = jsonDecode(text);
      if (json is Map<String, Object?>) {
        if (json['view'] == 'all') {
          return const GraphAllView();
        }
        if (json['view'] == 'log') {
          return const GraphLogView();
        }
        if (json['config'] case final String id) {
          return GraphConfigView(id);
        }
        if (GraphFilter.fromJson(json['filter']) case final GraphFilter filter) {
          return GraphFilterView(filter);
        }
      }
    } on FormatException {
      // A hand-edited file: the default search.
    }
    return defaultSearch;
  }
}

/// The default search, whichever variant the settings make it.
final class GraphDefaultSearch extends GraphShownView {
  /// The default search.
  const GraphDefaultSearch();

  @override
  String? encode() => null;

  @override
  bool operator ==(Object other) => other is GraphDefaultSearch;

  @override
  int get hashCode => 0;
}

/// The built-in `jj log`: the effective `revsets.log` (the request's null revset).
final class GraphLogView extends GraphShownView {
  /// `jj log`.
  const GraphLogView();

  @override
  String encode() => jsonEncode(<String, Object?>{'view': 'log'});

  @override
  bool operator ==(Object other) => other is GraphLogView;

  @override
  int get hashCode => 2;
}

/// The built-in `all()`.
final class GraphAllView extends GraphShownView {
  /// `all()`.
  const GraphAllView();

  /// `all()`.
  static const expression = 'all()'; // l10n-ignore: jj revset

  @override
  String encode() => jsonEncode(<String, Object?>{'view': 'all'});

  @override
  bool operator ==(Object other) => other is GraphAllView;

  @override
  int get hashCode => 1;
}

/// The jj log configuration [id] (Story 10.22).
final class GraphConfigView extends GraphShownView {
  /// A view of configuration [id].
  const GraphConfigView(this.id);

  /// The configuration's id.
  final String id;

  @override
  String encode() => jsonEncode(<String, Object?>{'config': id});

  @override
  bool operator ==(Object other) => other is GraphConfigView && other.id == id;

  @override
  int get hashCode => Object.hash(3, id);
}

/// A typed [filter].
final class GraphFilterView extends GraphShownView {
  /// A view of [filter].
  const GraphFilterView(this.filter);

  /// The filter.
  final GraphFilter filter;

  @override
  String encode() => jsonEncode(<String, Object?>{'filter': filter.toJson()});

  @override
  bool operator ==(Object other) => other is GraphFilterView && other.filter == filter;

  @override
  int get hashCode => filter.hashCode;
}

/// One Recent entry (Story 10.21 item 6): a go-to or a filter.
@immutable
sealed class GraphRecent {
  const GraphRecent();

  /// The stored form.
  String encode();

  /// Reads [text]; null for an entry this version does not know.
  static GraphRecent? decode(String text) {
    try {
      final Object? json = jsonDecode(text);
      if (json is! Map<String, Object?>) {
        return null;
      }
      if (json['change'] case final String change) {
        final Object? bookmark = json['bookmark'];
        return GraphRecentGoTo(change, bookmark: bookmark is String ? bookmark : null);
      }
      if (GraphFilter.fromJson(json['filter']) case final GraphFilter filter) {
        return GraphRecentFilter(filter);
      }
    } on FormatException {
      // Unknown: dropped.
    }
    return null;
  }
}

/// A go-to of [changeId] (the node key); a bookmark go-to keeps the bookmark's [bookmark] name.
final class GraphRecentGoTo extends GraphRecent {
  /// A go-to.
  const GraphRecentGoTo(this.changeId, {this.bookmark});

  /// The change's key.
  final String changeId;

  /// The bookmark it went to, or null.
  final String? bookmark;

  @override
  String encode() => jsonEncode(<String, Object?>{'change': changeId, 'bookmark': ?bookmark});

  @override
  bool operator ==(Object other) =>
      other is GraphRecentGoTo && other.changeId == changeId && other.bookmark == bookmark;

  @override
  int get hashCode => Object.hash(changeId, bookmark);
}

/// An applied [filter].
final class GraphRecentFilter extends GraphRecent {
  /// A filter.
  const GraphRecentFilter(this.filter);

  /// The filter.
  final GraphFilter filter;

  @override
  String encode() => jsonEncode(<String, Object?>{'filter': filter.toJson()});

  @override
  bool operator ==(Object other) => other is GraphRecentFilter && other.filter == filter;

  @override
  int get hashCode => filter.hashCode;
}
